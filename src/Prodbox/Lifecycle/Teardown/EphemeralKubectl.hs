{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the one ephemeral Kubernetes client the teardown paths run
-- @kubectl@ through.
--
-- It was written once, inside
-- 'Prodbox.Lifecycle.Teardown.EksDrainInterpreter', because the drain was the
-- only teardown path that reached Kubernetes at all.  The DNS01 challenge
-- family is the second: its record is removed by deleting the cert-manager
-- object that owns it, because a provider delete would race the solver into
-- rewriting the record.  Two statements of this machinery would be two
-- statements of a __security__ property — the private kubeconfig, the private
-- credential beside it, and the ambient-credential scrub — so the second caller
-- gets the first one's implementation rather than a copy.
--
-- What it guarantees, and why each part is here rather than at a call site:
--
--   * The kubeconfig and the bearer credential are both written into a private
--     temporary directory with @O_EXCL@, @O_NOFOLLOW@, @CLOEXEC@ and owner-only
--     mode, so a pre-placed path cannot capture either.
--   * The credential is read back and compared before the client value exists,
--     so \"client alive, credential unreadable\" is not a reachable state.
--   * The subprocess environment is scrubbed of @KUBECONFIG@ and every ambient
--     AWS credential variable, so the only reachable identity is the projection
--     this client was built from.
--   * Operation-owned clients close command admission and join admitted uses
--     before removing the private directory. An escaped client refuses work.
--     The legacy constructors retain their continuation-scoped file lifetime.
--
-- __Sprint 7.39: why the credential is a file, measured rather than assumed.__
-- It was a FIFO, on the argument that a credential should have no on-disk
-- representation for its lifetime. That argument cost a total outage: GHC opens
-- files non-blocking, so the writer's first write-open of a readerless FIFO
-- failed with @ENXIO@ before @kubectl@ started, and every invocation then
-- blocked in @open@ until its wall clock killed it. The client had never
-- authenticated on any live run.
--
-- The replacement rests on a measurement the design question could not be
-- decided without. Under @strace@, @kubectl@ v1.35.8 opens @users[0].user.tokenFile@
-- __exactly twice per invocation and independently of how many API requests it
-- makes__: twice for @version@, which makes none; twice for a @--raw@ read,
-- which makes one; twice for a discovery-bearing @get@ against an unreachable
-- endpoint, which makes six. A rendezvous therefore has to serve the credential
-- at least twice per invocation, to a reader whose arrival it cannot observe and
-- whose count it cannot know — and a FIFO served once was measured blocking on
-- the second open until the outer bound expired.
--
-- Against a same-uid attacker the marginal exposure of the token beside the
-- kubeconfig is small: the cluster CA and endpoint are already there, the
-- directory is owner-only, the file is owner-only and @O_NOFOLLOW@, and both die
-- with the continuation. That is the trade this sprint took, and it is a trade
-- rather than a free win — what it buys is an EKS teardown path that
-- authenticates at all.
module Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EmbeddedHomeKubeconfig
  , EmbeddedHomeKubeconfigError (..)
  , prepareEmbeddedHomeKubeconfig
  , embeddedHomeKubeconfigBytes
  , writeEmbeddedHomeKubeconfig
  , EphemeralKubectl
  , runEphemeralKubectl
  , OperationHomeKubectl
  , withOperationHomeKubectl
  , withNativeOperationHomeKubectl
  , operationHomeKubectlMatches
  , runOperationHomeKubectlWithInput
  , runOperationHomeKubectlBytesWithInput
  , pauseOperationHomeKubectl
  , EphemeralKubectlUnavailable (..)
  , withEphemeralKubectlForProjection
  , withEphemeralKubectlForProjectionInOperation
  , withNativeEphemeralKubectlForProjectionInOperation
  , withHomeCleanupKubectl
  , withHomeCleanupKubectlInOperation
  , withNativeHomeCleanupKubectlInOperation
  , withEphemeralKubeconfigPath
  , replaceEphemeralBearer
  , ephemeralKubectlLimits
  , ephemeralKubectlRequestTimeoutSeconds
  , ephemeralKubectlDiscoveryAttempts
  , ephemeralKubectlWallClockSeconds
  , ephemeralKubectlRequestTimeoutArgument
  , forbiddenKubectlEnvironmentKey
  , forbiddenKubectlEnvironmentKeyBytes
  , ephemeralKubeconfig
  , writePrivateFile
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (unless, (>=>))
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  )
import Prodbox.ControlPlane.OperationUse
  ( OperationUses
  , withOperationParentUses
  , withOperationUse
  )
import Prodbox.Infra.EphemeralKubeconfigPath
  ( ephemeralKubeconfigFileName
  , ephemeralKubectlDirectoryPrefix
  )
import Prodbox.Infra.MinioBackend (resolveLocalKubeconfig)
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , NativeSubprocess (..)
  , OperationProcessOutput
  , OperationSubprocessError
  , OperationSubprocesses
  , ProcessOutput (..)
  , Subprocess (..)
  , captureOperationCommandWithCeilingsBefore
  , captureOperationCommandWithInputBefore
  , captureOperationNativeCommandWithCeilingsBefore
  , captureOperationNativeCommandWithInputBefore
  , captureSubprocessBounded
  , operationProcessExitCode
  , operationProcessStderr
  , operationProcessStdout
  , operationSubprocessExecutionKey
  , operationSubprocessRuntimeDirectory
  , operationSubprocessWindow
  , verifyOperationSubprocessesBeforeEffect
  )
import Prodbox.Subprocess.ProcessEnvironment qualified as Environment
import Prodbox.Subprocess.SystemdIdentity (hostExecutionWorkEnd)
import System.Directory (removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Posix.Files
  ( ownerReadMode
  , ownerWriteMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

-- A validated, closed embedded-certificate projection. No Show instance can
-- accidentally put the retained client key into an error or log.
newtype EmbeddedHomeKubeconfig = EmbeddedHomeKubeconfig ByteString

data EmbeddedHomeKubeconfigError = EmbeddedHomeKubeconfigInvalid
  deriving (Eq, Show)

prepareEmbeddedHomeKubeconfig
  :: ByteString -> Either EmbeddedHomeKubeconfigError EmbeddedHomeKubeconfig
prepareEmbeddedHomeKubeconfig bytes = EmbeddedHomeKubeconfig <$> normalizeEmbeddedHomeKubeconfig bytes

embeddedHomeKubeconfigBytes :: EmbeddedHomeKubeconfig -> ByteString
embeddedHomeKubeconfigBytes (EmbeddedHomeKubeconfig bytes) = bytes

-- The caller owns this private directory's lifecycle. File creation and
-- readback remain with the same credential owner as projected bearer clients.
writeEmbeddedHomeKubeconfig
  :: FilePath -> EmbeddedHomeKubeconfig -> IO (Either EphemeralKubectlUnavailable FilePath)
writeEmbeddedHomeKubeconfig directory (EmbeddedHomeKubeconfig bytes) = do
  let path = directory </> "kubeconfig.json"
  attempted <- try (writePrivateFile path bytes >> ByteString.readFile path)
  pure $ case attempted :: Either IOException ByteString of
    Right observed | observed == bytes -> Right path
    _ ->
      Left
        ( EphemeralKubectlUnavailable
            (ObservationFailure "embedded home kubeconfig private write/readback refused")
        )

-- A minified, flattened home configuration may not acquire an exec/auth-provider
-- child or reload a credential/CA file after preparation. Explicit loopback
-- selection also prevents an ambient EKS context from becoming the control plane.
normalizeEmbeddedHomeKubeconfig :: ByteString -> Either EmbeddedHomeKubeconfigError ByteString
normalizeEmbeddedHomeKubeconfig bytes = do
  unless (ByteString.length bytes <= 64 * 1024) invalid
  value <- first (const EmbeddedHomeKubeconfigInvalid) (eitherDecodeStrict' bytes)
  cluster <- singletonAt "clusters" value
  context <- singletonAt "contexts" value
  user <- singletonAt "users" value
  clusterConfig <- embeddedConfigObjectAt ["cluster"] cluster
  contextConfig <- embeddedConfigObjectAt ["context"] context
  userConfig <- embeddedConfigObjectAt ["user"] user
  current <- embeddedConfigTextAt ["current-context"] value
  clusterName <- embeddedConfigTextAt ["name"] cluster
  contextName <- embeddedConfigTextAt ["name"] context
  userName <- embeddedConfigTextAt ["name"] user
  unless
    ( current == contextName
        && embeddedConfigField ["cluster"] contextConfig == Just (String clusterName)
        && embeddedConfigField ["user"] contextConfig == Just (String userName)
        && embeddedConfigField ["server"] clusterConfig == Just (String "https://127.0.0.1:6443")
        && embeddedConfigField ["insecure-skip-tls-verify"] clusterConfig `elem` [Nothing, Just (Bool False)]
        && all
          (\name -> embeddedConfigField [name] clusterConfig == Nothing)
          ["certificate-authority", "proxy-url", "tls-server-name"]
        && all
          (\name -> embeddedConfigField [name] userConfig == Nothing)
          ["exec", "auth-provider", "tokenFile", "client-certificate", "client-key"]
    )
    invalid
  mapM_ (requireText clusterConfig) ["certificate-authority-data"]
  mapM_ (requireText userConfig) ["client-certificate-data", "client-key-data"]
  -- Only the selected embedded certificate identity is handed to the tools.
  -- Unrelated preferences or future user fields cannot add another mechanism.
  certificate <- embeddedConfigTextAt ["certificate-authority-data"] clusterConfig
  clientCertificate <- embeddedConfigTextAt ["client-certificate-data"] userConfig
  clientKey <- embeddedConfigTextAt ["client-key-data"] userConfig
  pure $
    LazyByteString.toStrict $
      encode $
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("Config" :: Text)
          , "current-context" .= current
          , "clusters"
              .= [ object
                     [ "name" .= clusterName
                     , "cluster"
                         .= object ["server" .= ("https://127.0.0.1:6443" :: Text), "certificate-authority-data" .= certificate]
                     ]
                 ]
          , "contexts"
              .= [object ["name" .= contextName, "context" .= object ["cluster" .= clusterName, "user" .= userName]]]
          , "users"
              .= [ object
                     [ "name" .= userName
                     , "user" .= object ["client-certificate-data" .= clientCertificate, "client-key-data" .= clientKey]
                     ]
                 ]
          ]
 where
  invalid :: Either EmbeddedHomeKubeconfigError result
  invalid = Left EmbeddedHomeKubeconfigInvalid
  singletonAt name value = case embeddedConfigField [name] value of
    Just (Array entries) -> case Vector.toList entries of
      [entry] -> Right entry
      _ -> invalid
    _ -> invalid
  requireText value name = do
    actual <- embeddedConfigTextAt [name] value
    unless (not (Text.null actual)) invalid

embeddedConfigField :: [Text.Text] -> Value -> Maybe Value
embeddedConfigField path value = case path of
  [] -> Just value
  name : rest -> case value of
    Object fields -> KeyMap.lookup (Key.fromText name) fields >>= embeddedConfigField rest
    _ -> Nothing

embeddedConfigTextAt :: [Text.Text] -> Value -> Either EmbeddedHomeKubeconfigError Text.Text
embeddedConfigTextAt path value = case embeddedConfigField path value of
  Just (String text) -> Right text
  _ -> Left EmbeddedHomeKubeconfigInvalid

embeddedConfigObjectAt :: [Text.Text] -> Value -> Either EmbeddedHomeKubeconfigError Value
embeddedConfigObjectAt path value = case embeddedConfigField path value of
  Just jsonObject@(Object _) -> Right jsonObject
  _ -> Left EmbeddedHomeKubeconfigInvalid

-- | One bounded @kubectl@ invocation against the ephemeral kubeconfig.
--
-- The owned form retains the captured projection and joined original parent.
-- The legacy form has no stdin or owned-wait capability.
data EphemeralKubectl
  = EphemeralKubectl !([String] -> IO (Either (NonEmpty ObservationFailure) String))
  | OperationEphemeralKubectl
      !OperationSubprocesses
      !OperationUses
      !FilePath
      !OperationKubectlEnvironment
      !(Maybe FilePath)
      !FilePath

data OperationKubectlEnvironment
  = OperationKubectlStrings ![(String, String)]
  | OperationKubectlNative !Environment.ProcessEnvironment

-- Only the embedded-home constructor below can make this capability. An EKS
-- projection and a legacy client cannot be supplied to the Provisioner path.
newtype OperationHomeKubectl = OperationHomeKubectl EphemeralKubectl

withOperationHomeKubectl
  :: OperationSubprocesses
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EmbeddedHomeKubeconfig
  -> (Either EphemeralKubectlUnavailable OperationHomeKubectl -> IO result)
  -> IO result
withOperationHomeKubectl processes kubectl environment directory projection consume =
  withHomeCleanupKubectlInOperation
    processes
    kubectl
    environment
    directory
    projection
    (consume . fmap OperationHomeKubectl)

withNativeOperationHomeKubectl
  :: OperationSubprocesses
  -> FilePath
  -> Environment.ProcessEnvironment
  -> Maybe FilePath
  -> EmbeddedHomeKubeconfig
  -> (Either EphemeralKubectlUnavailable OperationHomeKubectl -> IO result)
  -> IO result
withNativeOperationHomeKubectl processes kubectl environment directory projection consume =
  withNativeHomeCleanupKubectlInOperation
    processes
    kubectl
    environment
    directory
    projection
    (consume . fmap OperationHomeKubectl)

operationHomeKubectlMatches :: OperationSubprocesses -> OperationHomeKubectl -> Bool
operationHomeKubectlMatches original (OperationHomeKubectl client) = case client of
  EphemeralKubectl _ -> False
  OperationEphemeralKubectl held _ _ _ _ _ ->
    operationSubprocessExecutionKey original == operationSubprocessExecutionKey held
      && operationSubprocessWindow original == operationSubprocessWindow held
      && operationSubprocessRuntimeDirectory original == operationSubprocessRuntimeDirectory held

runOperationHomeKubectlWithInput
  :: OperationHomeKubectl
  -> BoundedSubprocessLimits
  -> ByteString
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) ProcessOutput)
runOperationHomeKubectlWithInput (OperationHomeKubectl client) = runEphemeralKubectlWithInput client

-- The coordinator consumes captured bytes directly. This borrows the same
-- original client/use/command owner as the compatibility String API.
runOperationHomeKubectlBytesWithInput
  :: OperationHomeKubectl
  -> BoundedSubprocessLimits
  -> ByteString
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) OperationProcessOutput)
runOperationHomeKubectlBytesWithInput (OperationHomeKubectl client) = runEphemeralKubectlBytesWithInput client

pauseOperationHomeKubectl
  :: OperationHomeKubectl -> Int -> IO (Either (NonEmpty ObservationFailure) ())
pauseOperationHomeKubectl (OperationHomeKubectl client) = pauseEphemeralKubectl client

runEphemeralKubectl
  :: EphemeralKubectl -> [String] -> IO (Either (NonEmpty ObservationFailure) String)
runEphemeralKubectl client = case client of
  EphemeralKubectl run -> run
  OperationEphemeralKubectl processes uses kubectl environment directory configuration ->
    runOperationKubectl processes uses kubectl environment directory configuration

-- Provisioner ingress preserves raw binary stdin and the exit/status streams.
-- The legacy path cannot be selected as a fallback for an owned invocation.
runEphemeralKubectlWithInput
  :: EphemeralKubectl
  -> BoundedSubprocessLimits
  -> ByteString
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) ProcessOutput)
runEphemeralKubectlWithInput client limits input arguments =
  fmap compatibilityOutput <$> runEphemeralKubectlBytesWithInput client limits input arguments
 where
  compatibilityOutput captured =
    ProcessOutput
      (operationProcessExitCode captured)
      (ByteStringChar8.unpack (operationProcessStdout captured))
      (ByteStringChar8.unpack (operationProcessStderr captured))

runEphemeralKubectlBytesWithInput
  :: EphemeralKubectl
  -> BoundedSubprocessLimits
  -> ByteString
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) OperationProcessOutput)
runEphemeralKubectlBytesWithInput client limits input arguments = case client of
  EphemeralKubectl _ -> pure (Left (operationFailure "binary ingress requires an operation-owned client"))
  OperationEphemeralKubectl processes uses kubectl environment directory configuration -> do
    attempted <- withOperationUse uses $ do
      now <- getMonotonicTimeNSec
      let micros = boundedSubprocessTimeoutMicros limits
          requested = fromInteger (min (toInteger (maxBound :: Word64)) (toInteger now + toInteger micros * 1000))
      if micros <= 0
        then pure (Left (operationFailure "command time must be positive"))
        else do
          output <-
            captureOperationKubectlCommandBefore
              limits
              requested
              processes
              kubectl
              environment
              directory
              (["--kubeconfig", configuration] <> arguments)
              (Just input)
          pure (first (operationFailure . Text.pack . show) output)
    pure (either (Left . operationFailure . Text.pack . show) id attempted)

-- A wait must fit entirely before the original work end. It grants no next
-- effect; both the wake and the next command independently recheck the owner.
pauseEphemeralKubectl :: EphemeralKubectl -> Int -> IO (Either (NonEmpty ObservationFailure) ())
pauseEphemeralKubectl client micros = case client of
  EphemeralKubectl _ -> pure (Left (operationFailure "owned wait requires an operation-owned client"))
  OperationEphemeralKubectl processes uses _ _ _ _ -> do
    attempted <- withOperationUse uses $ do
      now <- getMonotonicTimeNSec
      let ending = hostExecutionWorkEnd (operationSubprocessWindow processes)
      if micros < 0 || toInteger now + toInteger micros * 1000 >= toInteger ending
        then pure (Left (operationFailure "owned wait exceeds original work"))
        else do
          before <- verifyOperationSubprocessesBeforeEffect processes
          case before of
            Left cause -> pure (Left (operationFailure (Text.pack (show cause))))
            Right () -> do
              threadDelay micros
              closing <- verifyOperationSubprocessesBeforeEffect processes
              pure (either (Left . operationFailure . Text.pack . show) Right closing)
    pure (either (Left . operationFailure . Text.pack . show) id attempted)

operationFailure :: Text -> NonEmpty ObservationFailure
operationFailure detail = ObservationFailure ("operation kubectl refused: " <> detail) :| []

-- | The client could not be created at all, which is never evidence about the
-- cluster.
newtype EphemeralKubectlUnavailable = EphemeralKubectlUnavailable ObservationFailure
  deriving (Eq, Show)

-- | Create the ephemeral client for one authenticated projection and run the
-- continuation with it.
--
-- The continuation's result is returned unchanged, including when the client
-- could not be created: an inability to build a client says nothing about the
-- resources it would have observed, and the caller is the surface that knows
-- how to classify that.
withEphemeralKubectlForProjection
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksClientAuthProjection
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withEphemeralKubectlForProjection kubectl environment workingDirectory projection consume =
  withEphemeralKubeconfigPath
    projection
    ( consume
        . fmap
          ( \kubeconfigPath ->
              EphemeralKubectl
                (runBoundedKubectl kubectl safeEnvironment workingDirectory kubeconfigPath)
          )
    )
 where
  safeEnvironment = filter (not . forbiddenKubectlEnvironmentKey . fst) environment

-- The supplied observed parent owns every command. Preparation uses its private
-- runtime directory, and joined uses end before the credential files disappear.
withEphemeralKubectlForProjectionInOperation
  :: OperationSubprocesses
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksClientAuthProjection
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withEphemeralKubectlForProjectionInOperation processes kubectl environment workingDirectory projection =
  withOperationKubectl
    processes
    kubectl
    (OperationKubectlStrings environment)
    workingDirectory
    (prepareEphemeralKubeconfigPath projection)

withNativeEphemeralKubectlForProjectionInOperation
  :: OperationSubprocesses
  -> FilePath
  -> Environment.ProcessEnvironment
  -> Maybe FilePath
  -> EksClientAuthProjection
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withNativeEphemeralKubectlForProjectionInOperation processes kubectl environment workingDirectory projection =
  withOperationKubectl
    processes
    kubectl
    (OperationKubectlNative environment)
    workingDirectory
    (prepareEphemeralKubeconfigPath projection)

-- Home cleanup consumes the already captured embedded projection. It cannot
-- resolve another host context or add an exec/auth-provider credential child.
withHomeCleanupKubectlInOperation
  :: OperationSubprocesses
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EmbeddedHomeKubeconfig
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withHomeCleanupKubectlInOperation processes kubectl environment workingDirectory projection =
  withOperationKubectl
    processes
    kubectl
    (OperationKubectlStrings environment)
    workingDirectory
    (`writeEmbeddedHomeKubeconfig` projection)

withNativeHomeCleanupKubectlInOperation
  :: OperationSubprocesses
  -> FilePath
  -> Environment.ProcessEnvironment
  -> Maybe FilePath
  -> EmbeddedHomeKubeconfig
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withNativeHomeCleanupKubectlInOperation processes kubectl environment workingDirectory projection =
  withOperationKubectl
    processes
    kubectl
    (OperationKubectlNative environment)
    workingDirectory
    (`writeEmbeddedHomeKubeconfig` projection)

withOperationKubectl
  :: OperationSubprocesses
  -> FilePath
  -> OperationKubectlEnvironment
  -> Maybe FilePath
  -> (FilePath -> IO (Either EphemeralKubectlUnavailable FilePath))
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withOperationKubectl processes kubectl environment workingDirectory prepare consume
  | not (isAbsolute kubectl) =
      consume (Left (operationClientUnavailable "kubectl path must be absolute"))
  | otherwise = do
      verified <- verifyOperationSubprocessesBeforeEffect processes
      case verified of
        Left cause -> consume (Left (operationClientUnavailable (Text.pack (show cause))))
        Right () ->
          withTempDirectory (operationSubprocessRuntimeDirectory processes) ephemeralKubectlDirectoryPrefix $ \directory ->
            withOperationParentUses processes $ \uses -> do
              prepared <- withOperationUse uses (prepare directory)
              consume $ case prepared of
                Left cause -> Left (operationClientUnavailable (Text.pack (show cause)))
                Right path ->
                  fmap
                    (OperationEphemeralKubectl processes uses kubectl safeEnvironment workingDirectory)
                    path
 where
  safeEnvironment = case environment of
    OperationKubectlStrings inherited ->
      OperationKubectlStrings (filter (not . forbiddenKubectlEnvironmentKey . fst) inherited)
    OperationKubectlNative inherited ->
      OperationKubectlNative
        (Environment.filterProcessEnvironment (not . forbiddenKubectlEnvironmentKeyBytes) inherited)

operationClientUnavailable :: Text -> EphemeralKubectlUnavailable
operationClientUnavailable detail =
  EphemeralKubectlUnavailable (ObservationFailure ("operation Kubernetes client refused: " <> detail))

-- | Sprint 7.40: the same preparation, for a caller that needs the kubeconfig
-- __path__ rather than a bounded runner.
--
-- `src/Prodbox/Infra/AwsEksTestStack.hs` carried a third statement of this
-- machinery — its own named pipe, its own unsupervised writer, and a kubeconfig
-- written with none of the protections this module exists to guarantee. It
-- existed because its callers export @KUBECONFIG@ into an ambient environment
-- and therefore need a path, which the 'EphemeralKubectl' record deliberately
-- hides. Giving the owning module that entry point is what makes one statement
-- serve both shapes; the alternative was a fourth.
--
-- The path's lifetime is the continuation's, exactly as the client's is, and the
-- credential beside it dies with the same directory. A caller that exports it
-- into a child's environment therefore exports a path that stops existing when
-- this call returns, which is the property the ambient-@KUBECONFIG@ shape needs
-- and cannot give itself.
withEphemeralKubeconfigPath
  :: EksClientAuthProjection
  -> (Either EphemeralKubectlUnavailable FilePath -> IO result)
  -> IO result
withEphemeralKubeconfigPath projection consume =
  withSystemTempDirectory
    ephemeralKubectlDirectoryPrefix
    (prepareEphemeralKubeconfigPath projection >=> consume)

prepareEphemeralKubeconfigPath
  :: EksClientAuthProjection
  -> FilePath
  -> IO (Either EphemeralKubectlUnavailable FilePath)
prepareEphemeralKubeconfigPath projection directory = do
  let kubeconfigPath = directory </> ephemeralKubeconfigFileName
      tokenPath = directory </> ephemeralBearerFileName
      tokenBytes = TextEncoding.encodeUtf8 (eksClientAuthBearerToken projection)
  prepared <-
    try
      ( do
          writePrivateFile tokenPath tokenBytes
          writePrivateFile
            kubeconfigPath
            ( LazyByteString.toStrict
                (encode (ephemeralKubeconfig projection tokenPath))
            )
          -- The credential is read back before the caller receives anything,
          -- so "kubeconfig handed out, credential unreadable" is not a state a
          -- caller can reach. The FIFO this replaces had exactly that state
          -- and nothing could observe it.
          readBack <- ByteString.readFile tokenPath
          if readBack == tokenBytes
            then pure ()
            else ioError (userError "ephemeral bearer credential did not read back")
      )
      :: IO (Either IOException ())
  pure $ case prepared of
    Left err ->
      Left
        ( EphemeralKubectlUnavailable
            ( ObservationFailure
                ( "could not prepare ephemeral Kubernetes client: "
                    <> Text.pack (show err)
                )
            )
        )
    Right () -> Right kubeconfigPath

-- | The credential's name inside an ephemeral directory, shared by the creator
-- and the replacer so the two cannot disagree about where the credential lives.
-- The kubeconfig's own name and the directory's prefix are defined in
-- "Prodbox.Infra.EphemeralKubeconfigPath", because the resolvers that must leave
-- such a path out of a fallback need them too.
ephemeralBearerFileName :: FilePath
ephemeralBearerFileName = "bearer-token"

-- | Replace the bearer credential beside a live ephemeral kubeconfig with a
-- newly issued one, atomically.
--
-- A projection's bearer lasts at most the Provider's short lifetime, and a
-- caller that holds one kubeconfig across a long bracket outlives it: every
-- invocation after expiry is then rejected as unauthorized. The kubeconfig
-- names its credential by path and @kubectl@ reads that path afresh on every
-- invocation (twice, measured above), so replacing the file is enough and no
-- invocation needs to be restarted.
--
-- The replacement is written beside the credential with the same
-- exclusive-create, no-follow, owner-only protections the first write had,
-- read back, and then renamed over it. A rename within one directory is atomic,
-- so a concurrent invocation reads either the old complete bearer or the new
-- one, never a partial file. The kubeconfig document itself is untouched: the
-- endpoint and the cluster authority do not change for the same cluster.
--
-- The path guard is only the file name: a path whose last component is not the
-- name the creator gives its kubeconfig is refused, which stops a caller
-- passing some other file by mistake. It does not prove the directory was made
-- by the creator, so the caller must pass the path it was handed.
replaceEphemeralBearer
  :: FilePath
  -> EksClientAuthProjection
  -> IO (Either EphemeralKubectlUnavailable ())
replaceEphemeralBearer kubeconfigPath projection
  | takeFileName kubeconfigPath /= ephemeralKubeconfigFileName =
      pure (Left (unavailable "not an ephemeral kubeconfig path"))
  | otherwise = do
      let directory = takeDirectory kubeconfigPath
          tokenPath = directory </> ephemeralBearerFileName
          replacementPath = tokenPath <> ".next"
          tokenBytes = TextEncoding.encodeUtf8 (eksClientAuthBearerToken projection)
      replaced <-
        try
          ( do
              _ <- try (removeFile replacementPath) :: IO (Either IOException ())
              writePrivateFile replacementPath tokenBytes
              readBack <- ByteString.readFile replacementPath
              if readBack == tokenBytes
                then renameFile replacementPath tokenPath
                else ioError (userError "replacement bearer credential did not read back")
          )
          :: IO (Either IOException ())
      pure $ case replaced of
        Left err ->
          Left (unavailable ("could not replace the ephemeral bearer: " <> Text.pack (show err)))
        Right () -> Right ()
 where
  unavailable detail = EphemeralKubectlUnavailable (ObservationFailure detail)

runBoundedKubectl
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> FilePath
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) String)
runBoundedKubectl kubectl environment workingDirectory kubeconfigPath arguments = do
  result <-
    captureSubprocessBounded
      ephemeralKubectlLimits
      Subprocess
        { subprocessPath = kubectl
        , subprocessArguments = ["--kubeconfig", kubeconfigPath] <> arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = workingDirectory
        }
  pure $ case result of
    Left err ->
      Left
        ( ObservationFailure
            ("failed to execute bounded kubectl: " <> Text.pack (show err))
            :| []
        )
    Right output -> classifyKubectlOutput output

runOperationKubectl
  :: OperationSubprocesses
  -> OperationUses
  -> FilePath
  -> OperationKubectlEnvironment
  -> Maybe FilePath
  -> FilePath
  -> [String]
  -> IO (Either (NonEmpty ObservationFailure) String)
runOperationKubectl processes uses kubectl environment workingDirectory kubeconfigPath arguments = do
  attempted <- withOperationUse uses $ do
    now <- getMonotonicTimeNSec
    let requestedEnd =
          fromInteger
            ( min
                (toInteger (maxBound :: Word64))
                (toInteger now + toInteger ephemeralKubectlWallClockSeconds * 1000000000)
            )
    result <-
      captureOperationKubectlCommandBefore
        ephemeralKubectlLimits
        requestedEnd
        processes
        kubectl
        environment
        workingDirectory
        (["--kubeconfig", kubeconfigPath] <> arguments)
        Nothing
    pure $ case result of
      Left cause -> Left (failure (Text.pack (show cause)))
      Right output ->
        classifyKubectlOutput
          ( ProcessOutput
              (operationProcessExitCode output)
              (ByteStringChar8.unpack (operationProcessStdout output))
              (ByteStringChar8.unpack (operationProcessStderr output))
          )
  pure $ case attempted of
    Left cause -> Left (failure (Text.pack (show cause)))
    Right result -> result
 where
  failure detail = ObservationFailure ("operation kubectl refused: " <> detail) :| []

captureOperationKubectlCommandBefore
  :: BoundedSubprocessLimits
  -> Word64
  -> OperationSubprocesses
  -> FilePath
  -> OperationKubectlEnvironment
  -> Maybe FilePath
  -> [String]
  -> Maybe ByteString
  -> IO (Either OperationSubprocessError OperationProcessOutput)
captureOperationKubectlCommandBefore limits requested processes kubectl environment directory arguments input =
  case (environment, input) of
    (OperationKubectlStrings inherited, Nothing) ->
      captureOperationCommandWithCeilingsBefore
        out
        err
        requested
        processes
        (Subprocess kubectl arguments (Just inherited) directory)
    (OperationKubectlStrings inherited, Just bytes) ->
      captureOperationCommandWithInputBefore
        maximumInput
        out
        err
        requested
        processes
        bytes
        (Subprocess kubectl arguments (Just inherited) directory)
    (OperationKubectlNative inherited, Nothing) ->
      captureOperationNativeCommandWithCeilingsBefore
        out
        err
        requested
        processes
        (NativeSubprocess kubectl arguments inherited directory)
    (OperationKubectlNative inherited, Just bytes) ->
      captureOperationNativeCommandWithInputBefore
        maximumInput
        out
        err
        requested
        processes
        bytes
        (NativeSubprocess kubectl arguments inherited directory)
 where
  out = boundedSubprocessMaximumStdoutBytes limits
  err = boundedSubprocessMaximumStderrBytes limits
  maximumInput = boundedSubprocessMaximumInputBytes limits

classifyKubectlOutput :: ProcessOutput -> Either (NonEmpty ObservationFailure) String
classifyKubectlOutput output = case processExitCode output of
  ExitSuccess -> Right (processStdout output)
  ExitFailure code ->
    Left
      ( ObservationFailure
          ( Text.take
              4096
              ( "bounded kubectl exited with code "
                  <> Text.pack (show code)
                  <> ": "
                  <> Text.pack (processStderr output <> processStdout output)
              )
          )
          :| []
      )

-- | Sprint 6.5: the per-request bound every ephemeral @kubectl@ call carries.
--
-- It bounds one HTTP request, not one invocation, which is the distinction the
-- outer wall clock below is derived from.
ephemeralKubectlRequestTimeoutSeconds :: Int
ephemeralKubectlRequestTimeoutSeconds = 5

-- | Sprint 6.5: how many API-group discovery requests @kubectl@ issues before
-- it gives up, measured rather than assumed.
--
-- A discovery-bearing @kubectl get@ against an unreachable endpoint took
-- 10.04 s at a 2-second request timeout, 15.04 s at 3 seconds, and 25.05 s at
-- 5 seconds, emitting exactly five @couldn't get current server API group list@
-- errors each time. The multiplier is the retry count, and it is fixed.
ephemeralKubectlDiscoveryAttempts :: Int
ephemeralKubectlDiscoveryAttempts = 5

-- | Sprint 6.5: the wall clock one ephemeral @kubectl@ invocation may take.
--
-- Derived, not chosen. A discovery-bearing call can spend
-- 'ephemeralKubectlDiscoveryAttempts' request timeouts on discovery and one
-- more on the resource itself, so the outer bound must exceed that sum or it
-- fires first and replaces @kubectl@'s own exact error with an opaque
-- "bounded subprocess exceeded its wall-clock timeout". A live EKS drain
-- selection did exactly that on 2026-09-11 under a flat 30-second bound, which
-- is precisely the six-request worst case and therefore guaranteed to race it.
--
-- __Margin re-derived on the shipped mechanism (Sprint 7.39, 2026-09-11).__ It
-- was justified by a measurement that included \"the FIFO token rendezvous\" —
-- a rendezvous that never occurred, because the writer died before any reader
-- arrived. What the margin actually has to cover is process spawn, two token-file
-- opens, and TLS. Spawn plus both credential reads, measured over five runs with
-- no API call at all, is 32-45 ms; the same client against an unreachable
-- endpoint returns in 39 ms. Ten seconds is two orders of magnitude above that
-- and is kept deliberately generous, because the margin exists to stop the outer
-- bound racing @kubectl@'s own error rather than to be tight.
ephemeralKubectlWallClockMarginSeconds :: Int
ephemeralKubectlWallClockMarginSeconds = 10

ephemeralKubectlWallClockSeconds :: Int
ephemeralKubectlWallClockSeconds =
  (ephemeralKubectlDiscoveryAttempts + 1) * ephemeralKubectlRequestTimeoutSeconds
    + ephemeralKubectlWallClockMarginSeconds

-- | The exact @--request-timeout@ argument every call passes.
ephemeralKubectlRequestTimeoutArgument :: String
ephemeralKubectlRequestTimeoutArgument =
  "--request-timeout=" <> show ephemeralKubectlRequestTimeoutSeconds <> "s"

ephemeralKubectlLimits :: BoundedSubprocessLimits
ephemeralKubectlLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 2 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 128 * 1024
    , boundedSubprocessTimeoutMicros =
        ephemeralKubectlWallClockSeconds * 1000 * 1000
    }

-- | Environment keys that would let an ambient identity or kubeconfig reach the
-- subprocess.  Removed rather than overridden, because an override still leaves
-- the value discoverable in the child's environment.
forbiddenKubectlEnvironmentKey :: String -> Bool
forbiddenKubectlEnvironmentKey key =
  any ((== key) . ByteStringChar8.unpack) forbiddenKubectlEnvironmentKeys

forbiddenKubectlEnvironmentKeyBytes :: ByteString -> Bool
forbiddenKubectlEnvironmentKeyBytes key = key `elem` forbiddenKubectlEnvironmentKeys

forbiddenKubectlEnvironmentKeys :: [ByteString]
forbiddenKubectlEnvironmentKeys =
  [ "KUBECONFIG"
  , "AWS_ACCESS_KEY_ID"
  , "AWS_SECRET_ACCESS_KEY"
  , "AWS_SESSION_TOKEN"
  , "AWS_PROFILE"
  , "AWS_DEFAULT_PROFILE"
  , "AWS_SHARED_CREDENTIALS_FILE"
  , "AWS_CONFIG_FILE"
  ]

-- | The kubeconfig document.  The bearer token is referenced by path through
-- @tokenFile@ and never appears in this document, so the rendered kubeconfig
-- carries no credential even though it names where one lives.
ephemeralKubeconfig :: EksClientAuthProjection -> FilePath -> Value
ephemeralKubeconfig projection tokenPath =
  object
    [ "apiVersion" .= ("v1" :: String)
    , "kind" .= ("Config" :: String)
    , "current-context" .= ("prodbox-eks" :: String)
    , "clusters"
        .= [ object
               [ "name" .= eksClientAuthClusterName projection
               , "cluster"
                   .= object
                     [ "server" .= eksClientAuthEndpoint projection
                     , "certificate-authority-data"
                         .= eksClientAuthCertificateAuthorityData projection
                     ]
               ]
           ]
    , "users"
        .= [ object
               [ "name" .= ("prodbox-provider" :: String)
               , "user" .= object ["tokenFile" .= tokenPath]
               ]
           ]
    , "contexts"
        .= [ object
               [ "name" .= ("prodbox-eks" :: String)
               , "context"
                   .= object
                     [ "cluster" .= eksClientAuthClusterName projection
                     , "user" .= ("prodbox-provider" :: String)
                     ]
               ]
           ]
    ]

writePrivateFile :: FilePath -> ByteString -> IO ()
writePrivateFile path bytes = do
  fd <-
    openFd
      path
      WriteOnly
      defaultFileFlags
        { exclusive = True
        , creat = Just privateMode
        , nofollow = True
        , cloexec = True
        }
  written <- try (writeAll fd bytes >> fileSynchronise fd)
  closeFd fd
  either (\err -> ioError (err :: IOException)) pure written
 where
  privateMode = ownerReadMode `unionFileModes` ownerWriteMode

writeAll :: Fd -> ByteString -> IO ()
writeAll fd remaining
  | ByteString.null remaining = pure ()
  | otherwise = do
      written <- PosixByteString.fdWrite fd remaining
      if written <= 0
        then ioError (userError "short write while creating an ephemeral EKS private file")
        else writeAll fd (ByteString.drop (fromIntegral written) remaining)

-- | The home DNS01 owner uses the explicitly resolved retained local RKE2
-- kubeconfig. Ambient contexts and AWS credentials are scrubbed just as for the
-- EKS projection; this constructor never falls back to a remote target.
withHomeCleanupKubectl
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> (Either EphemeralKubectlUnavailable EphemeralKubectl -> IO result)
  -> IO result
withHomeCleanupKubectl kubectl environment workingDirectory consume = do
  resolved <- resolveLocalKubeconfig
  consume $ case resolved of
    Left detail -> Left (EphemeralKubectlUnavailable (ObservationFailure (Text.pack detail)))
    Right path -> Right (EphemeralKubectl (runBoundedKubectl kubectl safeEnvironment workingDirectory path))
 where
  safeEnvironment = filter (not . forbiddenKubectlEnvironmentKey . fst) environment
