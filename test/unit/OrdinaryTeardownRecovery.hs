{-# LANGUAGE ImportQualifiedPost #-}

module OrdinaryTeardownRecovery
  ( ordinaryTeardownRecoverySuite
  )
where

import Data.List (elemIndex)
import Prodbox.Config.ComponentGraph
  ( ComponentDependency (..)
  , ComponentId (..)
  , ComponentNode (..)
  , defaultComponentGraph
  , lookupComponentNode
  )
import Prodbox.Config.OrdinaryTeardownRecovery
import TestSupport

ordinaryTeardownRecoverySuite :: SuiteBuilder ()
ordinaryTeardownRecoverySuite =
  describe "Sprint 3.41 ordinary teardown recovery topology" $ do
    it "derives the exact baseline closure without Gateway, applications, or Target Agent" $ do
      recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
      ordinaryTeardownRequestedCapabilities recovery
        `shouldBe` [ResumeOrdinaryCleanup]
      ordinaryTeardownRecoveryComponents recovery
        `shouldBe` baselineRecoveryComponents
      ordinaryTeardownRecoveryComponentIds recovery
        `shouldBe` baselineRecoveryComponentIds
      ordinaryTeardownRecoveryChartNames recovery
        `shouldBe` [ "bootstrap-broker"
                   , "lifecycle-authority"
                   , "authority-backup"
                   , "provider-worker"
                   ]

    it "adds the Target Agent only for an exact target-cleanup obligation" $ do
      recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
      ordinaryTeardownRequestedCapabilities recovery
        `shouldBe` [ResumeOrdinaryCleanup, ResolveExactTargetCleanup]
      ordinaryTeardownRecoveryComponents recovery
        `shouldBe` targetRecoveryComponents
      ordinaryTeardownRecoveryChartNames recovery
        `shouldBe` [ "bootstrap-broker"
                   , "target-secret-agent"
                   , "lifecycle-authority"
                   , "authority-backup"
                   , "provider-worker"
                   ]

    it "uses recovery-only dependencies while retaining normal readiness identities" $ do
      recovery <- requireRecovery OrdinaryTeardownWithTargetAgent
      let recoveryDag = ordinaryTeardownRecoveryDag recovery
          dependencies component =
            fmap (fmap dependency_on . depends_on) (lookupComponentNode component recoveryDag)
          sourceReadiness component =
            readiness <$> findSourceNode component defaultComponentGraph
          projectedReadiness component =
            readiness <$> lookupComponentNode component recoveryDag
      dependencies ComponentChartBootstrapBroker
        `shouldBe` Just [ComponentMinio, ComponentVaultWorkload]
      dependencies ComponentChartLifecycleAuthority
        `shouldBe` Just
          [ ComponentVaultUnsealed
          , ComponentMinio
          , ComponentChartTargetSecretAgent
          ]
      dependencies ComponentChartProviderWorker
        `shouldBe` Just
          [ComponentChartLifecycleAuthority, ComponentChartAuthorityBackup]
      map projectedReadiness targetRecoveryComponentIds
        `shouldBe` map sourceReadiness targetRecoveryComponentIds

    it "keeps the bootstrap caller explicit but outside RKE2 component execution" $ do
      recovery <- requireRecovery OrdinaryTeardownWithoutTargetAgent
      let closure = ordinaryTeardownRecoveryComponents recovery
      length (filter (== RecoveryBootstrapCoreExternalCli) closure) `shouldBe` 1
      precedes
        (elemIndex (RecoveryGraphComponent ComponentChartBootstrapBroker) closure)
        (elemIndex RecoveryBootstrapCoreExternalCli closure)
        `shouldBe` True

    it "cannot admit any normal-only platform, Gateway, or application component" $ do
      withoutTarget <- requireRecovery OrdinaryTeardownWithoutTargetAgent
      withTarget <- requireRecovery OrdinaryTeardownWithTargetAgent
      let admittedWithoutTarget = ordinaryTeardownRecoveryComponentIds withoutTarget
          admittedWithTarget = ordinaryTeardownRecoveryComponentIds withTarget
          forbiddenWithoutTarget =
            filter (`notElem` baselineRecoveryComponentIds) [minBound .. maxBound]
          forbiddenWithTarget =
            filter (`notElem` targetRecoveryComponentIds) [minBound .. maxBound]
      all (`notElem` admittedWithoutTarget) forbiddenWithoutTarget `shouldBe` True
      all (`notElem` admittedWithTarget) forbiddenWithTarget `shouldBe` True
      ComponentRegistry `shouldSatisfy` (`notElem` admittedWithTarget)
      ComponentGatewayDaemonFull `shouldSatisfy` (`notElem` admittedWithTarget)
      ComponentChartGateway `shouldSatisfy` (`notElem` admittedWithTarget)
      ComponentChartTlsRetention `shouldSatisfy` (`notElem` admittedWithTarget)

    it "refuses a missing recovery dependency in the normal component registry" $ do
      let withoutMinio =
            filter ((/= ComponentMinio) . component_id) defaultComponentGraph
      projectOrdinaryTeardownRecovery
        withoutMinio
        OrdinaryTeardownWithoutTargetAgent
        `shouldBe` Left (OrdinaryTeardownRecoveryMissingSource ComponentMinio)

    it "refuses duplicate normal-registry component identities" $ do
      case defaultComponentGraph of
        [] -> expectationFailure "default component graph must not be empty"
        firstNode : _ ->
          projectOrdinaryTeardownRecovery
            (firstNode : defaultComponentGraph)
            OrdinaryTeardownWithoutTargetAgent
            `shouldBe` Left
              (OrdinaryTeardownRecoveryDuplicateSource (component_id firstNode))

baselineRecoveryComponents :: [OrdinaryTeardownRecoveryComponent]
baselineRecoveryComponents =
  [ RecoveryGraphComponent ComponentClusterBase
  , RecoveryGraphComponent ComponentMinio
  , RecoveryGraphComponent ComponentVaultWorkload
  , RecoveryGraphComponent ComponentChartBootstrapBroker
  , RecoveryBootstrapCoreExternalCli
  , RecoveryGraphComponent ComponentVaultUnsealed
  , RecoveryGraphComponent ComponentChartLifecycleAuthority
  , RecoveryGraphComponent ComponentChartAuthorityBackup
  , RecoveryGraphComponent ComponentChartProviderWorker
  ]

baselineRecoveryComponentIds :: [ComponentId]
baselineRecoveryComponentIds =
  [ ComponentClusterBase
  , ComponentMinio
  , ComponentVaultWorkload
  , ComponentChartBootstrapBroker
  , ComponentVaultUnsealed
  , ComponentChartLifecycleAuthority
  , ComponentChartAuthorityBackup
  , ComponentChartProviderWorker
  ]

targetRecoveryComponents :: [OrdinaryTeardownRecoveryComponent]
targetRecoveryComponents =
  [ RecoveryGraphComponent ComponentClusterBase
  , RecoveryGraphComponent ComponentMinio
  , RecoveryGraphComponent ComponentVaultWorkload
  , RecoveryGraphComponent ComponentChartBootstrapBroker
  , RecoveryBootstrapCoreExternalCli
  , RecoveryGraphComponent ComponentVaultUnsealed
  , RecoveryGraphComponent ComponentChartTargetSecretAgent
  , RecoveryGraphComponent ComponentChartLifecycleAuthority
  , RecoveryGraphComponent ComponentChartAuthorityBackup
  , RecoveryGraphComponent ComponentChartProviderWorker
  ]

targetRecoveryComponentIds :: [ComponentId]
targetRecoveryComponentIds =
  [ ComponentClusterBase
  , ComponentMinio
  , ComponentVaultWorkload
  , ComponentChartBootstrapBroker
  , ComponentVaultUnsealed
  , ComponentChartTargetSecretAgent
  , ComponentChartLifecycleAuthority
  , ComponentChartAuthorityBackup
  , ComponentChartProviderWorker
  ]

requireRecovery
  :: OrdinaryTeardownTargetAgent -> IO OrdinaryTeardownRecovery
requireRecovery targetRequirement =
  case ordinaryTeardownRecovery targetRequirement of
    Left err ->
      expectationFailure (renderOrdinaryTeardownRecoveryError err)
        >> fail "unreachable"
    Right recovery -> pure recovery

findSourceNode :: ComponentId -> [ComponentNode] -> Maybe ComponentNode
findSourceNode component = go
 where
  go nodes = case nodes of
    [] -> Nothing
    node : remaining
      | component_id node == component -> Just node
      | otherwise -> go remaining

precedes :: Maybe Int -> Maybe Int -> Bool
precedes left right = case (left, right) of
  (Just leftIndex, Just rightIndex) -> leftIndex < rightIndex
  _ -> False
