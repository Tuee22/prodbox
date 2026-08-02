module BootstrapBrokerProductionCapabilities
  ( bootstrapBrokerProductionCapabilitiesSuite
  )
where

import Control.Monad (forM_)
import Data.List (delete)
import Prodbox.Bootstrap.Broker.ProductionCapabilities
  ( ProductionDependencyReadiness (..)
  , productionCapabilityInventoryComplete
  , productionCapabilityRegistrationInventory
  , productionCapabilityUniverse
  , productionReadinessDecision
  )
import TestSupport

bootstrapBrokerProductionCapabilitiesSuite :: SuiteBuilder ()
bootstrapBrokerProductionCapabilitiesSuite =
  describe "Bootstrap Broker production capability readiness" $ do
    it "registers the complete closed production capability universe exactly once" $ do
      productionCapabilityRegistrationInventory
        `shouldBe` productionCapabilityUniverse
      length productionCapabilityRegistrationInventory `shouldBe` 117
      productionCapabilityInventoryComplete productionCapabilityRegistrationInventory
        `shouldBe` True

    it "keeps readiness closed when any single production binding is absent" $ do
      forM_ productionCapabilityUniverse $ \missing ->
        productionReadinessDecision
          (delete missing productionCapabilityRegistrationInventory)
          allDependenciesReady
          `shouldBe` False

    it "keeps readiness closed for duplicate registrations" $ do
      case productionCapabilityRegistrationInventory of
        [] -> expectationFailure "production capability inventory is empty"
        binding : _ ->
          productionReadinessDecision
            (binding : productionCapabilityRegistrationInventory)
            allDependenciesReady
            `shouldBe` False

    it "keeps readiness closed when any live dependency is unavailable" $ do
      forM_
        [ allDependenciesReady {productionStoreDependencyReady = False}
        , allDependenciesReady {productionVaultDependencyReady = False}
        , allDependenciesReady {productionPgpDependencyReady = False}
        , allDependenciesReady {productionLeaseDependencyReady = False}
        , allDependenciesReady {productionControllerImageDependencyReady = False}
        ]
        $ \dependencies ->
          productionReadinessDecision
            productionCapabilityRegistrationInventory
            dependencies
            `shouldBe` False

    it "opens readiness only for the exact registry and all live dependencies" $ do
      productionReadinessDecision
        productionCapabilityRegistrationInventory
        allDependenciesReady
        `shouldBe` True

allDependenciesReady :: ProductionDependencyReadiness
allDependenciesReady =
  ProductionDependencyReadiness
    { productionStoreDependencyReady = True
    , productionVaultDependencyReady = True
    , productionPgpDependencyReady = True
    , productionLeaseDependencyReady = True
    , productionControllerImageDependencyReady = True
    }
