{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Executable facade for the dedicated pre-Vault Bootstrap Broker role.
--
-- Sprint 2.33 lands the closed command/config/runtime boundary and its
-- deterministic fake interpreter.  The real Kubernetes TokenReview, Lease,
-- MinIO, and Vault adapters are physical deployment work owned by Sprint
-- 3.26.  Until those adapters are supplied this production facade is
-- deliberately fail closed: liveness is observable, readiness and every RPC
-- refuse, and the test fake can never be selected by the command line.
module Prodbox.Bootstrap.Broker
  ( runBootstrapBrokerCommand
  , renderBootstrapBrokerStartPlan
  )
where

import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerEngine
  , BrokerEngineBoundary (..)
  , BrokerPhysicalCall (..)
  , BrokerProgramEvidenceBoundary (..)
  , EngineBoundaryError (..)
  , mkBrokerEngine
  )
import Prodbox.Bootstrap.Broker.EngineAdapter (engineBrokerInterpreter)
import Prodbox.Bootstrap.Broker.Program
  ( mkBrokerCapabilityRefs
  )
import Prodbox.Bootstrap.Broker.Server
  ( failClosedBrokerAuthenticator
  , renderBrokerServerError
  , runBrokerServer
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , bootstrapStoreBucket
  , bootstrapStoreEndpoint
  , brokerBootstrapStore
  , brokerClusterId
  , brokerDrainDeadlineMilliseconds
  , brokerLimits
  , brokerListenAddress
  , brokerListenPort
  , brokerListener
  , brokerMaximumRequestBodyBytes
  , brokerQueueCapacity
  , brokerRequestDeadlineMilliseconds
  , brokerServiceIdentity
  , brokerVaultAddress
  , loadBootstrapBrokerConfig
  , loopbackAddressText
  , renderBootstrapBrokerSettingsError
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( unavailableBootstrapStoreBoundary
  )
import Prodbox.CLI.Command
  ( BootstrapBrokerCommand (..)
  , BrokerLaunchOptions (..)
  , Plan
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output (writeError)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Error (fatalError)
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import System.Exit (ExitCode (..))

runBootstrapBrokerCommand :: FilePath -> BootstrapBrokerCommand -> IO ExitCode
runBootstrapBrokerCommand _repoRoot command = case command of
  BootstrapBrokerStart options -> runBootstrapBrokerStart options

runBootstrapBrokerStart :: BrokerLaunchOptions -> IO ExitCode
runBootstrapBrokerStart options = do
  loaded <- loadBootstrapBrokerConfig (brokerConfigPath options)
  case loaded of
    Left err -> failWith (renderBootstrapBrokerSettingsError err)
    Right settings ->
      runPlanWithOptions
        (brokerPlanOptions options)
        (bootstrapBrokerStartPlan (brokerConfigPath options) settings)
        applyBootstrapBrokerStart

bootstrapBrokerStartPlan
  :: FilePath
  -> BootstrapBrokerSettings
  -> Plan BootstrapBrokerSettings
bootstrapBrokerStartPlan configPath =
  buildPlan (renderBootstrapBrokerStartPlan configPath)

-- | A deterministic, secret-free rendering of the exact mounted-role plan.
-- No config field capable of carrying a credential exists in the decoded
-- settings type.
renderBootstrapBrokerStartPlan
  :: FilePath
  -> BootstrapBrokerSettings
  -> String
renderBootstrapBrokerStartPlan configPath settings =
  unlines
    [ "BOOTSTRAP_BROKER_START_PLAN"
    , "CONFIG_PATH=" ++ configPath
    , "RUNTIME_ROLE=bootstrap-broker"
    , "CLUSTER_ID=" ++ Text.unpack (brokerClusterId settings)
    , "SERVICE_IDENTITY=" ++ Text.unpack (brokerServiceIdentity settings)
    , "LISTENER="
        ++ Text.unpack (loopbackAddressText (brokerListenAddress listener))
        ++ ":"
        ++ show (brokerListenPort listener)
    , "BOOTSTRAP_STORE_ENDPOINT="
        ++ Text.unpack (bootstrapStoreEndpoint bootstrapStore)
    , "BOOTSTRAP_STORE_BUCKET="
        ++ Text.unpack (bootstrapStoreBucket bootstrapStore)
    , "QUEUE_CAPACITY=" ++ show (brokerQueueCapacity limits)
    , "MAX_REQUEST_BODY_BYTES=" ++ show (brokerMaximumRequestBodyBytes limits)
    , "REQUEST_DEADLINE_MILLISECONDS="
        ++ show (brokerRequestDeadlineMilliseconds limits)
    , "DRAIN_DEADLINE_MILLISECONDS="
        ++ show (brokerDrainDeadlineMilliseconds limits)
    , "BOUNDARY_ADAPTERS=fail-closed"
    ]
 where
  listener = brokerListener settings
  bootstrapStore = brokerBootstrapStore settings
  limits = brokerLimits settings

applyBootstrapBrokerStart :: BootstrapBrokerSettings -> IO ExitCode
applyBootstrapBrokerStart settings =
  case failClosedProductionEngine settings of
    Left err -> failWith err
    Right engine -> do
      result <-
        runBrokerServer
          settings
          failClosedBrokerAuthenticator
          (engineBrokerInterpreter engine)
      case result of
        Left err -> failWith (renderBrokerServerError err)
        Right () -> pure ExitSuccess

-- | Phase 3.26 replaces these categorical physical refusals with deployed
-- adapters.  The executable nevertheless always traverses the typed Engine:
-- probes are real closed programs, while readiness and every physical/store
-- operation refuse without claiming authority.
failClosedProductionEngine
  :: BootstrapBrokerSettings -> Either String (BrokerEngine IO)
failClosedProductionEngine settings = do
  observe <- coordinate "bootstrap-observe"
  mutate <- coordinate "bootstrap-mutate"
  baseline <- coordinate "baseline-reconcile"
  pki <- coordinate "pki-operate"
  mkBrokerEngine
    (mkBrokerCapabilityRefs observe mutate baseline pki)
    64
    failClosedBoundary
 where
  coordinate :: Text.Text -> Either String CapabilityCoordinate
  coordinate logicalName = do
    service <- mapLeft show (mkServiceIdentity (brokerServiceIdentity settings))
    authority <-
      mapLeft show (mkAuthorityScope ("bootstrap/" <> brokerClusterId settings))
    endpoint <- mapLeft show (mkCapabilityEndpoint (brokerVaultAddress settings))
    logical <- mapLeft show (mkLogicalName logicalName)
    generation <- mapLeft show (mkCredentialGeneration 1)
    Right (mkCoordinate service authority endpoint logical generation)

  failClosedBoundary =
    BrokerEngineBoundary
      { engineEvidenceBoundary = unavailableEvidence
      , engineResolveRootInitCryptoParameters = \_ -> unavailable
      , engineAdmitCapability = \_ _ -> pure (Right ())
      , engineBeginCapabilityExecution = \_ _ -> pure (Right ())
      , engineAcquireMutationFence = \_ _ _ _ _ -> unavailable
      , engineObserveFenceUse = \_ -> unavailable
      , engineReleaseMutationFence = \_ _ -> unavailable
      , engineRunPhysicalCall = \call ->
          let physicalCall = call
           in case physicalCall of
                PhysicalHealth _ -> pure (Right True)
                PhysicalReadiness _ -> pure (Right False)
                _ -> unavailable
      , engineRunLocalCall = \_ -> unavailable
      , engineSecretWorkerBoundary = Nothing
      , enginePgpBoundary = Nothing
      , engineInMemoryBoundary = Nothing
      , engineStoreBoundary = unavailableBootstrapStoreBoundary
      }

  unavailableEvidence =
    BrokerProgramEvidenceBoundary
      { resolvePristineStorageProof = \_ -> unavailable
      , resolveUnsealRecoveryCustody = \_ -> unavailable
      , resolveUnlockRotationCustody = \_ -> unavailable
      , resolveBaselineCustodyAndSession = \_ -> unavailable
      , resolveAmbiguousResetEvidence = \_ -> unavailable
      , resolveChildCustodyBinding = \_ -> unavailable
      , resolveChildRecoveryDeliveryEvidence = \_ -> unavailable
      , resolveChildRecoveryObservation = \_ -> unavailable
      }

  unavailable =
    pure (Left (EngineBoundaryUnavailable "physical boundary adapters are unavailable"))

mapLeft :: (error -> mapped) -> Either error value -> Either mapped value
mapLeft render = either (Left . render) Right

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
