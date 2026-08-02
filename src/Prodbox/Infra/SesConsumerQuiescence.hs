{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact Keycloak SMTP-consumer quiescence for total decommission.
--
-- Keycloak is the compiled SES SMTP consumer.  The production boundary binds
-- the home kubeconfig plus the exact namespace/deployment before effects are
-- exposed.  A scale response is never trusted by itself: the operation polls
-- the Deployment's desired/current/ready replica counts and returns success
-- only after all are zero (or the exact Deployment is absent).  Thus an
-- applied-but-response-lost scale converges through read-back.
module Prodbox.Infra.SesConsumerQuiescence
  ( SesConsumerObservation (..)
  , SesConsumerQuiescenceBoundary
  , mkSesConsumerQuiescenceBoundary
  , sesConsumerQuiescenceCapability
  , loadProductionSesConsumerQuiescenceCapability
  )
where

import Control.Concurrent (threadDelay)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error (errorMsg)
import Prodbox.Infra.MinioBackend (resolveLocalKubeconfig)
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , SesConsumerQuiescenceCapability (..)
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Text.Read (readMaybe)

data SesConsumerObservation
  = SesConsumersQuiescent
  | SesConsumersRunning !Int !Int !Int
  | SesConsumersUnobservable !Text
  deriving stock (Eq, Show)

data SesConsumerQuiescenceBoundary m = SesConsumerQuiescenceBoundary
  { stopExactSesConsumers :: m (Either Text ())
  , observeExactSesConsumers :: m SesConsumerObservation
  }

mkSesConsumerQuiescenceBoundary
  :: m (Either Text ())
  -> m SesConsumerObservation
  -> SesConsumerQuiescenceBoundary m
mkSesConsumerQuiescenceBoundary stop observe =
  SesConsumerQuiescenceBoundary
    { stopExactSesConsumers = stop
    , observeExactSesConsumers = observe
    }

sesConsumerQuiescenceCapability
  :: SesConsumerQuiescenceBoundary IO
  -> SesConsumerQuiescenceCapability IO
sesConsumerQuiescenceCapability boundary =
  SesConsumerQuiescenceCapability $
    NodeOperation
      { nodeDestroy = \_ _ -> do
          attempted <- stopExactSesConsumers boundary
          confirmed <- awaitQuiescence quiescenceReadBackAttempts Nothing
          pure $ case confirmed of
            SesConsumersQuiescent -> Right ()
            SesConsumersRunning desired current ready ->
              Left
                ( attemptDetail attempted
                    <> runningDetail desired current ready
                )
            SesConsumersUnobservable detail ->
              Left (attemptDetail attempted <> detail)
      , nodeReadBack = \_ _ -> do
          observed <- observeExactSesConsumers boundary
          pure (residueOf observed)
      }
 where
  awaitQuiescence remaining lastUnavailable = do
    observed <- observeExactSesConsumers boundary
    case observed of
      SesConsumersQuiescent -> pure SesConsumersQuiescent
      SesConsumersRunning {}
        | remaining <= 1 -> pure observed
        | otherwise -> waitAndRetry remaining lastUnavailable
      SesConsumersUnobservable detail
        | remaining <= 1 ->
            pure
              ( SesConsumersUnobservable
                  (maybe detail (<> "; " <> detail) lastUnavailable)
              )
        | otherwise -> waitAndRetry remaining (Just detail)

  waitAndRetry remaining lastUnavailable = do
    threadDelay quiescenceReadBackDelayMicros
    awaitQuiescence (remaining - 1) lastUnavailable

  attemptDetail attempted = case attempted of
    Right () -> ""
    Left detail -> "scale response unavailable: " <> detail <> "; "

loadProductionSesConsumerQuiescenceCapability
  :: FilePath
  -> IO (Either Text (SesConsumerQuiescenceCapability IO))
loadProductionSesConsumerQuiescenceCapability repoRoot = do
  kubeconfigResult <- resolveLocalKubeconfig
  pure $ do
    kubeconfig <- first Text.pack kubeconfigResult
    Right
      ( sesConsumerQuiescenceCapability
          ( mkSesConsumerQuiescenceBoundary
              (scaleKeycloakToZero repoRoot kubeconfig)
              (observeKeycloakDeployment repoRoot kubeconfig)
          )
      )

scaleKeycloakToZero :: FilePath -> FilePath -> IO (Either Text ())
scaleKeycloakToZero repoRoot kubeconfig = do
  captured <-
    captureSubprocessBounded
      kubectlLimits
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            kubectlPrefix kubeconfig
              <> [ "--namespace"
                 , keycloakNamespace
                 , "scale"
                 , "deployment/" <> keycloakDeployment
                 , "--replicas=0"
                 ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ do
    output <- first errorMsg captured
    case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure code ->
        Left
          ( "kubectl scale exited "
              <> Text.pack (show code)
              <> boundedStderr output
          )

observeKeycloakDeployment
  :: FilePath
  -> FilePath
  -> IO SesConsumerObservation
observeKeycloakDeployment repoRoot kubeconfig = do
  captured <-
    captureSubprocessBounded
      kubectlLimits
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            kubectlPrefix kubeconfig
              <> [ "--namespace"
                 , keycloakNamespace
                 , "get"
                 , "deployment/" <> keycloakDeployment
                 , "--ignore-not-found"
                 , "-o=jsonpath={.spec.replicas},{.status.replicas},{.status.readyReplicas}"
                 ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case captured of
    Left err -> SesConsumersUnobservable (errorMsg err)
    Right output -> case processExitCode output of
      ExitFailure code ->
        SesConsumersUnobservable
          ( "kubectl get exited "
              <> Text.pack (show code)
              <> boundedStderr output
          )
      ExitSuccess -> decodeReplicaObservation (Text.strip (Text.pack (processStdout output)))

decodeReplicaObservation :: Text -> SesConsumerObservation
decodeReplicaObservation raw
  | Text.null raw = SesConsumersQuiescent
  | otherwise = case Text.splitOn "," raw of
      [desiredRaw, currentRaw, readyRaw] ->
        case traverse decodeCount [desiredRaw, currentRaw, readyRaw] of
          Just [desired, current, ready]
            | desired == 0 && current == 0 && ready == 0 -> SesConsumersQuiescent
            | otherwise -> SesConsumersRunning desired current ready
          _ -> SesConsumersUnobservable "Keycloak Deployment replica observation is malformed"
      _ -> SesConsumersUnobservable "Keycloak Deployment replica observation is malformed"
 where
  decodeCount value
    | Text.null (Text.strip value) = Just 0
    | otherwise = readMaybe (Text.unpack (Text.strip value))

residueOf :: SesConsumerObservation -> ResidueStatus
residueOf observation = case observation of
  SesConsumersQuiescent -> ResidueAbsent
  SesConsumersRunning desired current ready ->
    ResiduePresent
      ResidueDetails
        { residueEvidence = Text.unpack (runningDetail desired current ready)
        , residueStackName = "ses-consumer:keycloak"
        }
  SesConsumersUnobservable detail ->
    ResidueUnreachable (ResidueQueryFailed (Text.unpack detail))

runningDetail :: Int -> Int -> Int -> Text
runningDetail desired current ready =
  "Keycloak SMTP consumer replicas remain desired/current/ready="
    <> Text.intercalate "/" (map (Text.pack . show) [desired, current, ready])

boundedStderr :: ProcessOutput -> Text
boundedStderr output =
  let detail = Text.strip (Text.pack (processStderr output))
   in if Text.null detail then "" else ": " <> detail

kubectlPrefix :: FilePath -> [String]
kubectlPrefix kubeconfig =
  [ "--kubeconfig"
  , kubeconfig
  , "--request-timeout=3s"
  ]

keycloakNamespace :: String
keycloakNamespace = "keycloak"

keycloakDeployment :: String
keycloakDeployment = "keycloak"

quiescenceReadBackAttempts :: Int
quiescenceReadBackAttempts = 8

quiescenceReadBackDelayMicros :: Int
quiescenceReadBackDelayMicros = 500000

kubectlLimits :: BoundedSubprocessLimits
kubectlLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 16 * 1024
    , boundedSubprocessMaximumStderrBytes = 16 * 1024
    , boundedSubprocessTimeoutMicros = 5 * 1000000
    }
