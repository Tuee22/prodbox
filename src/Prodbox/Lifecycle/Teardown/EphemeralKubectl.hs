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
-- statements of a __security__ property — the private kubeconfig, the bearer
-- token that never lands on disk, and the ambient-credential scrub — so the
-- second caller gets the first one's implementation rather than a copy.
--
-- What it guarantees, and why each part is here rather than at a call site:
--
--   * The kubeconfig is written into a private temporary directory with
--     @O_EXCL@, @O_NOFOLLOW@, and owner-only mode, so a pre-placed path cannot
--     capture it.
--   * The bearer token is served through a FIFO rather than written to a file,
--     so the credential has no on-disk representation for its lifetime.
--   * The subprocess environment is scrubbed of @KUBECONFIG@ and every ambient
--     AWS credential variable, so the only reachable identity is the projection
--     this client was built from.
--   * The client is universally quantified by the continuation it is handed to,
--     so it cannot outlive the temporary directory that backs it.
module Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EphemeralKubectl
  , runEphemeralKubectl
  , EphemeralKubectlUnavailable (..)
  , withEphemeralKubectlForProjection
  , ephemeralKubectlLimits
  , forbiddenKubectlEnvironmentKey
  , ephemeralKubeconfig
  , writePrivateFile
  )
where

import Control.Concurrent.Async (withAsync)
import Control.Exception (IOException, try)
import Control.Monad (forever)
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
  ( createNamedPipe
  , ownerReadMode
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
  withSystemTempDirectory "prodbox-ephemeral-kubectl-" $ \directory -> do
    let kubeconfigPath = directory </> "kubeconfig.json"
        tokenFifoPath = directory </> "bearer-token"
    prepared <-
      try
        ( do
            createNamedPipe tokenFifoPath privateMode
            writePrivateFile
              kubeconfigPath
              ( LazyByteString.toStrict
                  (encode (ephemeralKubeconfig projection tokenFifoPath))
              )
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
      Right () ->
        withAsync
          ( forever
              ( ByteString.writeFile
                  tokenFifoPath
                  (TextEncoding.encodeUtf8 (eksClientAuthBearerToken projection))
              )
          )
          ( \_ ->
              consume
                ( Right
                    ( EphemeralKubectl
                        ( runBoundedKubectl
                            kubectl
                            safeEnvironment
                            workingDirectory
                            kubeconfigPath
                        )
                    )
                )
          )
 where
  privateMode = ownerReadMode `unionFileModes` ownerWriteMode
  safeEnvironment = filter (not . forbiddenKubectlEnvironmentKey . fst) environment

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

ephemeralKubectlLimits :: BoundedSubprocessLimits
ephemeralKubectlLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 2 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 128 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 1000 * 1000
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

-- | The kubeconfig document.  The bearer token is referenced as a @tokenFile@
-- pointing at a FIFO, so the credential is never written to a regular file.
ephemeralKubeconfig :: EksClientAuthProjection -> FilePath -> Value
ephemeralKubeconfig projection tokenFifoPath =
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
               , "user" .= object ["tokenFile" .= tokenFifoPath]
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
        then ioError (userError "short write while creating ephemeral EKS kubeconfig")
        else writeAll fd (ByteString.drop (fromIntegral written) remaining)
