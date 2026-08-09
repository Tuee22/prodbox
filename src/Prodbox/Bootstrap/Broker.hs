{-# LANGUAGE OverloadedStrings #-}

-- | Executable facade for the dedicated pre-Vault Bootstrap Broker role.
--
-- Kubernetes TokenReview authentication is installed before the listener is
-- opened. The mutation engine remains deliberately unready until its durable
-- store, worker, OpenPGP, and Vault effect adapters are all constructible;
-- liveness stays observable and no production request can select a test fake.
module Prodbox.Bootstrap.Broker
  ( runBootstrapBrokerCommand
  , renderBootstrapBrokerStartPlan
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forever)
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.EngineAdapter (engineBrokerInterpreter)
import Prodbox.Bootstrap.Broker.ProductionEngine
  ( BrokerReadinessCache
  , brokerReadinessCacheRefresh
  , productionBrokerEngine
  )
import Prodbox.Bootstrap.Broker.ProductionSecretWorker
  ( runProductionSecretWorker
  )
import Prodbox.Bootstrap.Broker.Readiness
  ( brokerReadinessSchedule
  , observerPeriodMicros
  )
import Prodbox.Bootstrap.Broker.Server
  ( renderBrokerServerError
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
  , loadBootstrapBrokerConfig
  , loopbackAddressText
  , renderBootstrapBrokerSettingsError
  )
import Prodbox.Bootstrap.Broker.TokenReview
  ( productionBrokerAuthenticator
  )
import Prodbox.CLI.Command
  ( BootstrapBrokerCommand (..)
  , BrokerLaunchOptions (..)
  , Plan
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output (writeError)
import Prodbox.Error (fatalError)
import System.Exit (ExitCode (..))

runBootstrapBrokerCommand :: FilePath -> BootstrapBrokerCommand -> IO ExitCode
runBootstrapBrokerCommand _repoRoot command = case command of
  BootstrapBrokerStart options -> runBootstrapBrokerStart options
  BootstrapBrokerSecretWorker operation configPath ->
    runProductionSecretWorker configPath operation

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
    , "AUTHENTICATOR=kubernetes-tokenreview"
    , "MUTATION_ENGINE=production"
    ]
 where
  listener = brokerListener settings
  bootstrapStore = brokerBootstrapStore settings
  limits = brokerLimits settings

applyBootstrapBrokerStart :: BootstrapBrokerSettings -> IO ExitCode
applyBootstrapBrokerStart settings = do
  engineResult <- productionBrokerEngine settings
  case engineResult of
    Left err -> failWith err
    Right (engine, readinessCache) -> do
      authenticatorResult <- productionBrokerAuthenticator settings
      case authenticatorResult of
        Left err -> failWith err
        Right authenticator -> do
          -- One synchronous pass before the listener opens, so the very first
          -- probe reads a real observation rather than the fail-closed
          -- placeholder.  The startup probe targets the constant-time health
          -- route, so a slow first pass delays readiness, never liveness.
          brokerReadinessCacheRefresh readinessCache
          result <-
            withAsync (readinessObserverLoop readinessCache) $ \_ ->
              runBrokerServer
                settings
                authenticator
                (engineBrokerInterpreter engine)
          case result of
            Left err -> failWith (renderBrokerServerError err)
            Right () -> pure ExitSuccess

-- | Refresh the latched readiness facts forever. Its lifetime is exactly the
-- server call it brackets, so a returning or failing server reclaims it.
readinessObserverLoop :: BrokerReadinessCache -> IO ()
readinessObserverLoop cache = forever $ do
  threadDelay (fromIntegral (observerPeriodMicros brokerReadinessSchedule))
  brokerReadinessCacheRefresh cache

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
