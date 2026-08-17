{-# LANGUAGE LambdaCase #-}

-- | Pure projection of the smallest control plane that can resume ordinary
-- desired-absence reconciliation.  The projection deliberately has no
-- interpreter: Phase 4 consumes this plan and owns repair/reinstall effects.
--
-- Workload identity and readiness come from the normal component registry.
-- Recovery supplies only the narrower dependency relation needed after
-- Gateway and application teardown, plus the bootstrap-core external caller
-- resource that is rendered by the Bootstrap Broker chart.
module Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (..)
  , OrdinaryTeardownCapability (..)
  , OrdinaryTeardownRecoveryComponent (..)
  , OrdinaryTeardownRecovery
  , ordinaryTeardownRequestedCapabilities
  , ordinaryTeardownRecoveryComponents
  , ordinaryTeardownRecoveryDag
  , ordinaryTeardownRecoveryComponentIds
  , ordinaryTeardownRecoveryChartNames
  , OrdinaryTeardownRecoveryError (..)
  , renderOrdinaryTeardownRecoveryError
  , ordinaryTeardownRecovery
  , projectOrdinaryTeardownRecovery
  )
where

import Control.Monad (foldM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Prodbox.Config.ComponentGraph
  ( ComponentDag
  , ComponentDependency (..)
  , ComponentGraphError
  , ComponentId (..)
  , ComponentNode (..)
  , EdgeKind (OrderingEdge)
  , chartNameForComponent
  , componentIdText
  , defaultComponentGraph
  , renderComponentGraphError
  , validateComponentGraph
  )
import Prodbox.EffectDAG (acyclicTopologicalOrder)

-- | Whether an exact nonterminal cleanup obligation requires the Target Agent.
-- The baseline profile cannot accidentally acquire it: the caller must choose
-- the positive constructor from exact cleanup state.
data OrdinaryTeardownTargetAgent
  = OrdinaryTeardownWithoutTargetAgent
  | OrdinaryTeardownWithTargetAgent
  deriving (Eq, Ord, Show)

-- | Requested capabilities are retained in the resulting plan so the derived
-- closure can be audited without reconstructing the caller's decision.
data OrdinaryTeardownCapability
  = ResumeOrdinaryCleanup
  | ResolveExactTargetCleanup
  deriving (Eq, Ord, Show)

-- | A recovery-closure member.  Almost every member is an existing component
-- registry identity.  The sole exception is the non-workload, bootstrap-core
-- external CLI identity: it is a ServiceAccount/RBAC resource rendered in the
-- Bootstrap Broker release and therefore must not become an RKE2 executor step.
data OrdinaryTeardownRecoveryComponent
  = RecoveryGraphComponent ComponentId
  | RecoveryBootstrapCoreExternalCli
  deriving (Eq, Ord, Show)

-- | Opaque, validated recovery projection.  Construction proves that every
-- required normal-registry component exists exactly once and that the narrowed
-- recovery graph is acyclic and dependency-complete.
data OrdinaryTeardownRecovery = OrdinaryTeardownRecovery
  { ordinaryTeardownRequestedCapabilities :: [OrdinaryTeardownCapability]
  , ordinaryTeardownRecoveryComponents :: [OrdinaryTeardownRecoveryComponent]
  , ordinaryTeardownRecoveryDag :: ComponentDag
  }
  deriving (Eq, Show)

data OrdinaryTeardownRecoveryError
  = OrdinaryTeardownRecoveryDuplicateSource ComponentId
  | OrdinaryTeardownRecoveryMissingSource ComponentId
  | OrdinaryTeardownRecoveryClosureInvalid String
  | OrdinaryTeardownRecoveryGraphInvalid ComponentGraphError
  deriving (Eq, Show)

renderOrdinaryTeardownRecoveryError :: OrdinaryTeardownRecoveryError -> String
renderOrdinaryTeardownRecoveryError = \case
  OrdinaryTeardownRecoveryDuplicateSource component ->
    "Ordinary teardown recovery source contains duplicate component `"
      ++ componentIdText component
      ++ "`."
  OrdinaryTeardownRecoveryMissingSource component ->
    "Ordinary teardown recovery requires component `"
      ++ componentIdText component
      ++ "`, but the normal component registry does not contain it."
  OrdinaryTeardownRecoveryClosureInvalid detail -> detail
  OrdinaryTeardownRecoveryGraphInvalid err -> renderComponentGraphError err

-- | Project from the compiled normal component registry.
ordinaryTeardownRecovery
  :: OrdinaryTeardownTargetAgent
  -> Either OrdinaryTeardownRecoveryError OrdinaryTeardownRecovery
ordinaryTeardownRecovery =
  projectOrdinaryTeardownRecovery defaultComponentGraph

-- | Pure testable seam: project the recovery closure from a supplied normal
-- registry.  This is intentionally a projection rather than an independently
-- authored set of readiness identities.  Dependencies are recovery-specific:
-- image Registry, Gateway, public applications, TLS serving, generic
-- object-store access, and host/provider credentials cannot enter the closure.
projectOrdinaryTeardownRecovery
  :: [ComponentNode]
  -> OrdinaryTeardownTargetAgent
  -> Either OrdinaryTeardownRecoveryError OrdinaryTeardownRecovery
projectOrdinaryTeardownRecovery source targetRequirement = do
  sourceIndex <- indexSourceComponents source
  componentOrder <-
    either
      (Left . OrdinaryTeardownRecoveryClosureInvalid)
      Right
      (recoveryClosure targetRequirement)
  projectedNodes <-
    traverse
      (projectGraphNode sourceIndex targetRequirement)
      [ component
      | RecoveryGraphComponent component <- componentOrder
      ]
  dag <-
    either
      (Left . OrdinaryTeardownRecoveryGraphInvalid)
      Right
      (validateComponentGraph projectedNodes)
  pure
    OrdinaryTeardownRecovery
      { ordinaryTeardownRequestedCapabilities = requestedCapabilities targetRequirement
      , ordinaryTeardownRecoveryComponents = componentOrder
      , ordinaryTeardownRecoveryDag = dag
      }

-- | Existing component identities in dependency order.  The bootstrap caller
-- stays visible through 'ordinaryTeardownRecoveryComponents' but is omitted
-- here because it is a chart resource, not an RKE2 component executor.
ordinaryTeardownRecoveryComponentIds :: OrdinaryTeardownRecovery -> [ComponentId]
ordinaryTeardownRecoveryComponentIds recovery =
  [ component
  | RecoveryGraphComponent component <- ordinaryTeardownRecoveryComponents recovery
  ]

-- | Internal chart releases required by the profile, in derived dependency
-- order.  Non-chart infrastructure and the bootstrap caller resource are
-- filtered out through the canonical chart-name registry.
ordinaryTeardownRecoveryChartNames :: OrdinaryTeardownRecovery -> [String]
ordinaryTeardownRecoveryChartNames recovery =
  [ chartName
  | component <- ordinaryTeardownRecoveryComponentIds recovery
  , Just chartName <- [chartNameForComponent component]
  ]

requestedCapabilities
  :: OrdinaryTeardownTargetAgent -> [OrdinaryTeardownCapability]
requestedCapabilities targetRequirement =
  ResumeOrdinaryCleanup : case targetRequirement of
    OrdinaryTeardownWithoutTargetAgent -> []
    OrdinaryTeardownWithTargetAgent -> [ResolveExactTargetCleanup]

indexSourceComponents
  :: [ComponentNode]
  -> Either OrdinaryTeardownRecoveryError (Map ComponentId ComponentNode)
indexSourceComponents = foldM insertSource Map.empty
 where
  insertSource indexed component
    | Map.member (component_id component) indexed =
        Left (OrdinaryTeardownRecoveryDuplicateSource (component_id component))
    | otherwise = Right (Map.insert (component_id component) component indexed)

projectGraphNode
  :: Map ComponentId ComponentNode
  -> OrdinaryTeardownTargetAgent
  -> ComponentId
  -> Either OrdinaryTeardownRecoveryError ComponentNode
projectGraphNode sourceIndex targetRequirement component = do
  sourceNode <-
    maybe
      (Left (OrdinaryTeardownRecoveryMissingSource component))
      Right
      (Map.lookup component sourceIndex)
  pure
    sourceNode
      { depends_on =
          fmap orderingOn (recoveryGraphDependencies targetRequirement component)
      }
 where
  orderingOn dependency =
    ComponentDependency
      { dependency_on = dependency
      , dependency_edge = OrderingEdge
      }

recoveryClosure
  :: OrdinaryTeardownTargetAgent
  -> Either String [OrdinaryTeardownRecoveryComponent]
recoveryClosure targetRequirement =
  acyclicTopologicalOrder
    renderRecoveryComponent
    recoveryComponentRank
    (recoveryDependencies targetRequirement)
    [ RecoveryBootstrapCoreExternalCli
    , RecoveryGraphComponent ComponentChartProviderWorker
    ]

recoveryDependencies
  :: OrdinaryTeardownTargetAgent
  -> OrdinaryTeardownRecoveryComponent
  -> Maybe [OrdinaryTeardownRecoveryComponent]
recoveryDependencies targetRequirement component = case component of
  RecoveryBootstrapCoreExternalCli ->
    Just [RecoveryGraphComponent ComponentChartBootstrapBroker]
  RecoveryGraphComponent graphComponent ->
    fmap (fmap RecoveryGraphComponent) (recoveryGraphDependenciesMaybe targetRequirement graphComponent)

recoveryGraphDependencies
  :: OrdinaryTeardownTargetAgent -> ComponentId -> [ComponentId]
recoveryGraphDependencies targetRequirement component =
  fromMaybe [] (recoveryGraphDependenciesMaybe targetRequirement component)

-- | Recovery-only dependency policy.  Returning 'Nothing' for every other
-- normal component makes Gateway/application inclusion unavailable to the
-- closure expansion rather than relying on a post-hoc filter.
recoveryGraphDependenciesMaybe
  :: OrdinaryTeardownTargetAgent -> ComponentId -> Maybe [ComponentId]
recoveryGraphDependenciesMaybe targetRequirement component = case component of
  ComponentClusterBase -> Just []
  ComponentMinio -> Just [ComponentClusterBase]
  ComponentVaultWorkload -> Just [ComponentClusterBase]
  ComponentChartBootstrapBroker ->
    Just [ComponentMinio, ComponentVaultWorkload]
  ComponentVaultUnsealed ->
    Just [ComponentVaultWorkload, ComponentChartBootstrapBroker]
  ComponentChartTargetSecretAgent ->
    Just [ComponentVaultUnsealed]
  ComponentChartLifecycleAuthority ->
    Just
      ( [ComponentVaultUnsealed, ComponentMinio]
          ++ case targetRequirement of
            OrdinaryTeardownWithoutTargetAgent -> []
            OrdinaryTeardownWithTargetAgent -> [ComponentChartTargetSecretAgent]
      )
  ComponentChartAuthorityBackup ->
    Just [ComponentChartLifecycleAuthority]
  ComponentChartProviderWorker ->
    Just [ComponentChartLifecycleAuthority, ComponentChartAuthorityBackup]
  _ -> Nothing

renderRecoveryComponent :: OrdinaryTeardownRecoveryComponent -> String
renderRecoveryComponent = \case
  RecoveryGraphComponent component -> componentIdText component
  RecoveryBootstrapCoreExternalCli -> "bootstrap_core_external_cli"

recoveryComponentRank :: OrdinaryTeardownRecoveryComponent -> Int
recoveryComponentRank = \case
  RecoveryGraphComponent component -> fromEnum component
  -- The identity is rendered by the Bootstrap Broker release, so it becomes
  -- available at that chart step rather than after the standing roles.
  RecoveryBootstrapCoreExternalCli -> fromEnum ComponentChartBootstrapBroker
