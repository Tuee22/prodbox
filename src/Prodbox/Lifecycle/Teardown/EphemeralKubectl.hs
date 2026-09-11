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
  , ephemeralKubectlRequestTimeoutSeconds
  , ephemeralKubectlDiscoveryAttempts
  , ephemeralKubectlWallClockSeconds
  , ephemeralKubectlRequestTimeoutArgument
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
        -- Sprint 6.5, PROVEN DEFECT, replacement not yet found. GHC opens a FIFO
        -- with @O_NONBLOCK@, and a non-blocking write-open of a FIFO with no
        -- reader fails with @ENXIO@ rather than waiting. This 'ByteString.writeFile'
        -- therefore throws on its very first attempt, before @kubectl@ has
        -- started; 'forever' propagates, the thread dies, and nothing waits on
        -- it, so the death is silent. Every @kubectl@ invocation then blocks in
        -- @open@ on a FIFO that will never have a writer until the bounded
        -- subprocess wall clock kills it. Measured: the identical call with a
        -- plain token file completes in 54 ms; through this FIFO it consumes the
        -- entire bound, 40.00 s of a 40-second budget, on both a threaded and a
        -- non-threaded runtime, with kernel task state showing @kubectl@ parked
        -- in @wait_for_partner@ and the FIFO absent from its descriptor table.
        --
        -- Two replacements were measured and both refused: retrying the
        -- non-blocking open still lost the race about half the time even
        -- threaded, and a blocking 'openFd' write-open hung indefinitely. The
        -- token must not be written to a regular file, so neither dead end is a
        -- licence to drop the FIFO. Left exactly as it was rather than landing
        -- an unproven replacement for a proven defect.
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
-- The margin covers process spawn, the FIFO token rendezvous, and TLS, measured
-- together at 65 ms against a healthy API server.
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
