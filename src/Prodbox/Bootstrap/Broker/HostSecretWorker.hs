{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated host delivery of one operator secret to the exact attested
-- one-shot worker. The long-lived Broker never receives these bytes.
module Prodbox.Bootstrap.Broker.HostSecretWorker
  ( HostSecretWorkerConnection (..)
  , HostSecretWorkerExpectation
  , mkHostSecretWorkerExpectation
  , HostSecretWorkerError (..)
  , renderHostSecretWorkerError
  , deliverHostSecretWorkerPayload
  , deliverHostSecretWorkerPayloadAfter
  , hostSecretWorkerGetSubprocess
  , hostSecretWorkerAttachSubprocess
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad qualified
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.KubernetesAttestation
  ( bootstrapSecretWorkerPodName
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( workerContainerName
  , workerRequestFromRunningResponse
  )
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , SecretPayload
  )
import Prodbox.Bootstrap.Broker.SecretIngress
  ( SecretIngressError
  , encodeSecretIngressFrame
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretFreeWorkerRequest
  , SecretWorkerOperation
  , WorkerPodUid
  , secretWorkerRequestPodUid
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  )
import Prodbox.Error (errorMsg)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))

data HostSecretWorkerConnection = HostSecretWorkerConnection
  { hostSecretWorkerEnvironment :: !(Maybe [(String, String)])
  , hostSecretWorkerWorkingDirectory :: !FilePath
  }
  deriving stock (Eq, Show)

data HostSecretWorkerExpectation = HostSecretWorkerExpectation
  { expectedWorkerOperation :: !SecretWorkerOperation
  , expectedWorkerActionDigest :: !ArtifactDigest
  , expectedWorkerRequestDigest :: !RequestDigest
  , expectedWorkerStorageGeneration :: !VaultStorageGeneration
  }
  deriving stock (Eq, Show)

mkHostSecretWorkerExpectation
  :: SecretWorkerOperation
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> HostSecretWorkerExpectation
mkHostSecretWorkerExpectation = HostSecretWorkerExpectation

data HostSecretWorkerError
  = HostSecretWorkerObservationFailed !Text
  | HostSecretWorkerAttestationFailed !Text
  | HostSecretWorkerIngressEncodingFailed !SecretIngressError
  | HostSecretWorkerAttachFailed !Text
  | HostSecretWorkerAttachRefused
  deriving stock (Eq, Show)

renderHostSecretWorkerError :: HostSecretWorkerError -> String
renderHostSecretWorkerError err = case err of
  HostSecretWorkerObservationFailed detail ->
    "observe Bootstrap secret worker: " ++ show detail
  HostSecretWorkerAttestationFailed detail ->
    "attest Bootstrap secret worker: " ++ show detail
  HostSecretWorkerIngressEncodingFailed detail ->
    "encode bounded Bootstrap secret ingress: " ++ show detail
  HostSecretWorkerAttachFailed detail ->
    "attach Bootstrap secret worker stdin: " ++ show detail
  HostSecretWorkerAttachRefused ->
    "Bootstrap secret worker refused or failed the attached ingress"

bootstrapBrokerNamespace :: String
bootstrapBrokerNamespace = "bootstrap-broker"

maximumHostSecretPayloadBytes :: Natural
maximumHostSecretPayloadBytes = 64 * 1024

hostSecretWorkerGetSubprocess :: HostSecretWorkerConnection -> Subprocess
hostSecretWorkerGetSubprocess connection =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        [ "--namespace"
        , bootstrapBrokerNamespace
        , "get"
        , "pod/" ++ showText bootstrapSecretWorkerPodName
        , "--output=json"
        ]
    , subprocessEnvironment = hostSecretWorkerEnvironment connection
    , subprocessWorkingDirectory = Just (hostSecretWorkerWorkingDirectory connection)
    }

hostSecretWorkerAttachSubprocess :: HostSecretWorkerConnection -> Subprocess
hostSecretWorkerAttachSubprocess connection =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        [ "--namespace"
        , bootstrapBrokerNamespace
        , "attach"
        , "--pod-running-timeout=10s"
        , "-i"
        , "pod/" ++ showText bootstrapSecretWorkerPodName
        , "--container"
        , showText workerContainerName
        ]
    , subprocessEnvironment = hostSecretWorkerEnvironment connection
    , subprocessWorkingDirectory = Just (hostSecretWorkerWorkingDirectory connection)
    }

deliverHostSecretWorkerPayload
  :: HostSecretWorkerConnection
  -> HostSecretWorkerExpectation
  -> SecretPayload
  -> IO (Either HostSecretWorkerError ())
deliverHostSecretWorkerPayload connection expected payload = do
  delivered <-
    deliverHostSecretWorkerPayloadAfter
      connection
      Nothing
      [expected]
      payload
  pure (Control.Monad.void delivered)

-- | Deliver to the next exact attested worker among a closed expected set.
-- The optional prior UID prevents a fast polling loop from attaching twice to
-- the same one-shot Pod while the controller is checkpointing its exit/delete.
-- Returning the request gives a multi-stage client the UID it must exclude on
-- its next delivery.
deliverHostSecretWorkerPayloadAfter
  :: HostSecretWorkerConnection
  -> Maybe WorkerPodUid
  -> [HostSecretWorkerExpectation]
  -> SecretPayload
  -> IO (Either HostSecretWorkerError SecretFreeWorkerRequest)
deliverHostSecretWorkerPayloadAfter connection priorUid expected payload = do
  observed <-
    waitForAttestedWorker
      connection
      priorUid
      expected
      workerObservationAttempts
  case observed of
    Left err -> pure (Left err)
    Right request ->
      case encodeSecretIngressFrame
        maximumHostSecretPayloadBytes
        request
        payload of
        Left err -> pure (Left (HostSecretWorkerIngressEncodingFailed err))
        Right frame -> do
          attached <-
            captureSubprocessWithInputBounded
              attachLimits
              frame
              (hostSecretWorkerAttachSubprocess connection)
          pure $ case attached of
            Left err -> Left (HostSecretWorkerAttachFailed (errorMsg err))
            Right output -> case processExitCode output of
              ExitSuccess -> Right request
              ExitFailure _ -> Left HostSecretWorkerAttachRefused

workerObservationAttempts :: Int
workerObservationAttempts = 240

waitForAttestedWorker
  :: HostSecretWorkerConnection
  -> Maybe WorkerPodUid
  -> [HostSecretWorkerExpectation]
  -> Int
  -> IO (Either HostSecretWorkerError SecretFreeWorkerRequest)
waitForAttestedWorker connection priorUid expected remaining = do
  observed <-
    captureSubprocessBounded
      observationLimits
      (hostSecretWorkerGetSubprocess connection)
  case observed of
    Left err -> retryOrFail (HostSecretWorkerObservationFailed (errorMsg err))
    Right output -> case processExitCode output of
      ExitFailure _ -> retryOrFail (HostSecretWorkerObservationFailed "worker Pod is not present")
      ExitSuccess ->
        case firstAttestedRequest expected (ByteString8.pack (processStdout output)) of
          Left detail -> retryOrFail (HostSecretWorkerAttestationFailed detail)
          Right request
            | Just (secretWorkerRequestPodUid request) == priorUid ->
                retryOrFail
                  (HostSecretWorkerObservationFailed "prior worker Pod is still present")
            | otherwise -> pure (Right request)
 where
  retryOrFail err
    | remaining <= 1 = pure (Left err)
    | otherwise = do
        threadDelay 250000
        waitForAttestedWorker connection priorUid expected (remaining - 1)

firstAttestedRequest
  :: [HostSecretWorkerExpectation]
  -> ByteString
  -> Either Text SecretFreeWorkerRequest
firstAttestedRequest expected body = go expected
 where
  go [] = Left "worker Pod does not match any expected closed operation"
  go (candidate : rest) =
    case workerRequestFromRunningResponse
      "bootstrap-broker"
      (expectedWorkerOperation candidate)
      (expectedWorkerActionDigest candidate)
      (expectedWorkerRequestDigest candidate)
      (expectedWorkerStorageGeneration candidate)
      200
      body of
      Right request -> Right request
      Left _ -> go rest

observationLimits :: BoundedSubprocessLimits
observationLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 128 * 1024
    , boundedSubprocessMaximumStderrBytes = 4096
    , boundedSubprocessTimeoutMicros = 5 * 1000 * 1000
    }

attachLimits :: BoundedSubprocessLimits
attachLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 128 * 1024
    , boundedSubprocessMaximumStdoutBytes = 64 * 1024
    , boundedSubprocessMaximumStderrBytes = 4096
    , boundedSubprocessTimeoutMicros = 5 * 60 * 1000 * 1000
    }

showText :: Text -> String
showText = Text.unpack
