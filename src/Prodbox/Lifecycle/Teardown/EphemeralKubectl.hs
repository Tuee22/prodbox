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
--   * The client is universally quantified by the continuation it is handed to,
--     so it cannot outlive the temporary directory that backs it, and the
--     credential dies with that directory.
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
  ( EphemeralKubectl
  , runEphemeralKubectl
  , EphemeralKubectlUnavailable (..)
  , withEphemeralKubectlForProjection
  , withEphemeralKubeconfigPath
  , ephemeralKubectlLimits
  , ephemeralKubectlRequestTimeoutSeconds
  , ephemeralKubectlDiscoveryAttempts
  , ephemeralKubectlWallClockSeconds
  , ephemeralKubectlRequestTimeoutArgument
  , forbiddenKubectlEnvironmentKey
  , ephemeralKubeconfig
  , writePrivateFile
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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

-- | One bounded @kubectl@ invocation against the ephemeral kubeconfig.
--
-- Deliberately a record of one function rather than an exported runner: the
-- kubeconfig path, environment, and working directory are captured when the
-- client is created and cannot be substituted by a caller afterwards.
newtype EphemeralKubectl = EphemeralKubectl
  { runEphemeralKubectl
      :: [String] -> IO (Either (NonEmpty ObservationFailure) String)
  }

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
  withSystemTempDirectory "prodbox-ephemeral-kubectl-" $ \directory -> do
    let kubeconfigPath = directory </> "kubeconfig.json"
        tokenPath = directory </> "bearer-token"
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
    case prepared of
      Left err ->
        consume
          ( Left
              ( EphemeralKubectlUnavailable
                  ( ObservationFailure
                      ( "could not prepare ephemeral Kubernetes client: "
                          <> Text.pack (show err)
                      )
                  )
              )
          )
      Right () -> consume (Right kubeconfigPath)

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
    Right output -> case processExitCode output of
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
  key == "KUBECONFIG"
    || key == "AWS_ACCESS_KEY_ID"
    || key == "AWS_SECRET_ACCESS_KEY"
    || key == "AWS_SESSION_TOKEN"
    || key == "AWS_PROFILE"
    || key == "AWS_DEFAULT_PROFILE"
    || key == "AWS_SHARED_CREDENTIALS_FILE"
    || key == "AWS_CONFIG_FILE"

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
