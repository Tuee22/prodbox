{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.56: the typed component dependency/readiness graph that makes the
-- class of bootstrap readiness races __unrepresentable__
-- ([bootstrap_readiness_doctrine.md](../../documents/engineering/bootstrap_readiness_doctrine.md)).
--
-- This module is the M2/M3 foundation the later phases project reconcile
-- ordering from (Sprint `3.23` chart edges, Sprint `4.43` reconcile ordering +
-- the deep registry→MinIO gate, Sprint `7.31` AWS parity). It carries __only
-- non-secret data__ and sits below "Prodbox.Settings" as a leaf so the Tier-0
-- config surface can host the graph without an import cycle.
--
-- The three doctrine mechanisms this module realizes:
--
--   * __M1 (ordering is derived, not hand-written).__ 'componentReconcileOrder'
--     is a pure topological projection over the declared edges, reusing
--     'Prodbox.EffectDAG.acyclicTopologicalOrder' — the same back-edge cycle
--     rejection and missing-node rejection as the prerequisite DAG.
--   * __M2 (the graph is Dhall-sourced).__ The graph is a field of the Tier-0
--     @parameters@ ('Prodbox.Settings.ConfigFile' /
--     'Prodbox.Config.Tier0.ProdboxParameters'); graph validity is checked by the
--     pure 'validateComponentGraph' when the config is projected, so a
--     configuration that expresses a consumer→dependency edge without a matching
--     readiness barrier does not expand to a valid graph.
--   * __M3 (the probe must match the edge kind).__ 'ReadinessProbe' is a closed
--     ADT whose constructors are ranked by the interface they exercise
--     ('probeDepth'). A 'BackendWriteEdge' — a consumer that writes through its
--     own interface to a dependency's backend, e.g. registry → MinIO S3 — is
--     satisfiable only by a __deep__ probe that round-trips through that exact
--     dependency; a proxy probe (front-door HTTP, resource-exists) is a distinct,
--     weaker value that cannot type-satisfy it.
--
-- Readiness is __externally-authoritative state__ (doctrine Statement 3): the
-- probe constructors describe __which interface__ proves a component ready, and
-- observation obeys the @Unreachable → refuse@ soundness rule at the point of
-- observation (owned by the reconcile driver in Sprint `4.43`); this module is
-- the pure, flat, exhaustively-matched projection, never a GADT phantom-state
-- machine.
module Prodbox.Config.ComponentGraph
  ( -- * Component identity
    ComponentId (..)
  , componentIdText
  , componentIdForChartName
  , chartNameForComponent

    -- * Readiness probes (M3)
  , ReadinessProbe (..)
  , ProbeDepth (..)
  , probeDepth
  , probeSatisfiesBackendWrite

    -- * Dependency edges
  , EdgeKind (..)
  , ComponentDependency (..)
  , ComponentNode (..)

    -- * Graph validity + projection (M1/M2)
  , ComponentGraphError (..)
  , renderComponentGraphError
  , ComponentDag
  , componentDagNodes
  , componentDagOrder
  , validateComponentGraph
  , componentReconcileOrder
  , lookupComponentNode
  , componentDependencyIds
  , componentDagEdges
  , chartComponentDeployOrder
  , directChartDependencies
  , operatorAvailableGates

    -- * Capability lowering (Sprint 1.61 Increment B)
  , componentDagRequirements
  , componentCapabilityRequirement
  , componentCapabilityOp
  , componentRequirementSpec
  , componentProvisionSpec
  , resolveCapabilityProviders
  , edgeKindOf

    -- * The default bootstrap graph
  , defaultComponentGraph
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityOp (..)
  , PermitTier (..)
  , permitTier
  , requiresRoundTripEvidence
  )
import Prodbox.ControlPlane.CapabilityRequirement
  ( CapabilityProvisionSpec (..)
  , CapabilityRequirementSpec (..)
  , SomeCapabilityProvision
  , SomeCapabilityRequirement
  , matchesProvision
  , provisionCoordinate'
  , provisionOp
  , renderRequirementError
  , requirementCoordinate'
  , requirementOp
  , requirementTier
  , resolveProvision
  , resolveRequirement
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , authorityScopeText
  , coordAuthority
  , coordService
  , serviceIdentityText
  )
import Prodbox.EffectDAG (acyclicTopologicalOrder)

-- | Every bootstrap/platform component the dependency/readiness graph can name.
-- The set spans the base infrastructure the reconcile driver brings up (Sprint
-- `4.43`) and the public workload charts the chart platform orders (Sprint
-- `3.23`). It is a closed enum so every id is exhaustively matched
-- (CLAUDE.md "ADTs over strings"); the historical string identity is owned by
-- 'componentIdText'.
data ComponentId
  = -- Base infrastructure
    ComponentClusterBase
  | ComponentMinio
  | ComponentVaultWorkload
  | ComponentVaultUnsealed
  | ComponentRegistry
  | ComponentMetalLB
  | ComponentEnvoyGateway
  | ComponentCertManager
  | ComponentPerconaPostgresOperator
  | ComponentGatewayDaemonPreVault
  | ComponentGatewayDaemonFull
  | -- Public workload charts
    ComponentChartPulsar
  | ComponentChartRedis
  | ComponentChartKeycloakPostgres
  | ComponentChartKeycloak
  | ComponentChartVscode
  | ComponentChartApi
  | ComponentChartWebsocket
  | ComponentChartGateway
  deriving (Eq, Ord, Show, Enum, Bounded, Generic, FromDhall, ToDhall)

-- | The stable display/wire string for a 'ComponentId'. This is the SSoT for the
-- snake_case identity so renaming a constructor cannot silently change the
-- surfaced id (mirrors 'Prodbox.PrerequisiteId.prerequisiteIdText').
componentIdText :: ComponentId -> String
componentIdText = \case
  ComponentClusterBase -> "cluster_base"
  ComponentMinio -> "minio"
  ComponentVaultWorkload -> "vault_workload"
  ComponentVaultUnsealed -> "vault_unsealed"
  ComponentRegistry -> "registry"
  ComponentMetalLB -> "metallb"
  ComponentEnvoyGateway -> "envoy_gateway"
  ComponentCertManager -> "cert_manager"
  ComponentPerconaPostgresOperator -> "percona_postgres_operator"
  ComponentGatewayDaemonPreVault -> "gateway_daemon_pre_vault"
  ComponentGatewayDaemonFull -> "gateway_daemon_full"
  ComponentChartPulsar -> "chart_pulsar"
  ComponentChartRedis -> "chart_redis"
  ComponentChartKeycloakPostgres -> "chart_keycloak_postgres"
  ComponentChartKeycloak -> "chart_keycloak"
  ComponentChartVscode -> "chart_vscode"
  ComponentChartApi -> "chart_api"
  ComponentChartWebsocket -> "chart_websocket"
  ComponentChartGateway -> "chart_gateway"

-- | Map a chart's on-disk name ("keycloak-postgres", …) to its 'ComponentId'.
-- The chart platform (Sprint `3.23`) uses this to source chart dependency
-- ordering from the component graph rather than the retired hardcoded
-- @chartDefinitionDependencies@ literals.
componentIdForChartName :: String -> Maybe ComponentId
componentIdForChartName = \case
  "pulsar" -> Just ComponentChartPulsar
  "redis" -> Just ComponentChartRedis
  "keycloak-postgres" -> Just ComponentChartKeycloakPostgres
  "keycloak" -> Just ComponentChartKeycloak
  "vscode" -> Just ComponentChartVscode
  "api" -> Just ComponentChartApi
  "websocket" -> Just ComponentChartWebsocket
  "gateway" -> Just ComponentChartGateway
  _ -> Nothing

-- | The inverse of 'componentIdForChartName': the chart's on-disk name for a
-- chart component, or @Nothing@ for a non-chart infrastructure component.
chartNameForComponent :: ComponentId -> Maybe String
chartNameForComponent = \case
  ComponentChartPulsar -> Just "pulsar"
  ComponentChartRedis -> Just "redis"
  ComponentChartKeycloakPostgres -> Just "keycloak-postgres"
  ComponentChartKeycloak -> Just "keycloak"
  ComponentChartVscode -> Just "vscode"
  ComponentChartApi -> Just "api"
  ComponentChartWebsocket -> Just "websocket"
  ComponentChartGateway -> Just "gateway"
  _ -> Nothing

-- | The depth rank of a readiness probe — how strong an interface it exercises.
-- @ProxyProbe < DeepProbe@ (doctrine §0.1: a proxy signal does not satisfy a
-- deep dependency edge).
data ProbeDepth
  = ProxyProbe
  | DeepProbe
  deriving (Eq, Ord, Show)

-- | The closed readiness-probe ADT (M3). Constructors are ranked by the
-- interface they exercise via 'probeDepth':
--
--   * __proxy__ constructors prove a strictly weaker resource than the
--     consumer's real call path;
--   * __deep__ constructors exercise the consumer's own call path end to end.
--
-- A 'BackendWriteEdge' is satisfiable only by a deep probe. 'ProbeBackendRoundTrip'
-- additionally names the dependency the round-trip passes through, so the graph
-- can check that a claimed backend round-trip matches a declared backend-write
-- edge — the registry's readiness is @'ProbeBackendRoundTrip' 'ComponentMinio'@
-- (a canary blob push that streams to MinIO S3), never the front-door @GET /v2/@
-- proxy.
data ReadinessProbe
  = -- Proxy probes (weaker): a strictly weaker resource than the call path.
    ProbeResourceExists
  | ProbeFrontDoorHttp
  | -- Deep probes: exercise the consumer's own call path.
    ProbeServiceActive
  | ProbeRolloutComplete
  | ProbeOperatorAvailable
  | ProbeVaultUnsealed
  | ProbeBackendRoundTrip ComponentId
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The depth rank of a probe. Rollout waits, operator @Available@ gates, and
-- backend round-trips are __deep__ (doctrine §2 lists StatefulSet/Deployment
-- rollout waits among the ~15 correct deep edges); front-door HTTP and
-- resource-exists are __proxy__.
probeDepth :: ReadinessProbe -> ProbeDepth
probeDepth = \case
  ProbeResourceExists -> ProxyProbe
  ProbeFrontDoorHttp -> ProxyProbe
  ProbeServiceActive -> DeepProbe
  ProbeRolloutComplete -> DeepProbe
  ProbeOperatorAvailable -> DeepProbe
  ProbeVaultUnsealed -> DeepProbe
  ProbeBackendRoundTrip _ -> DeepProbe

-- | Whether a probe can satisfy a 'BackendWriteEdge' to the given dependency:
-- it must be a __deep__ round-trip __through that exact dependency__. A proxy
-- probe, or a deep probe that round-trips through a different backend, cannot
-- satisfy it — this is the ADT-ranking obligation of M3, checked purely rather
-- than surfacing as a runtime surprise.
probeSatisfiesBackendWrite :: ComponentId -> ReadinessProbe -> Bool
probeSatisfiesBackendWrite backend probe =
  case probe of
    ProbeBackendRoundTrip target -> target == backend
    _ -> False

-- | The kind of a dependency edge — how the consumer exercises the dependency.
data EdgeKind
  = -- | A plain ordering edge: the dependency must be ready before the consumer
    -- starts, and the dependency's own deep readiness (rollout, operator
    -- @Available@) is a sufficient barrier.
    OrderingEdge
  | -- | A backend-write edge: the consumer writes __through its own interface__
    -- to the dependency's backend (registry → MinIO S3). The consumer's own
    -- readiness probe must therefore be a deep round-trip through this
    -- dependency; a proxy front-door gate on the consumer is racy (doctrine §1).
    BackendWriteEdge
  deriving (Eq, Ord, Show, Enum, Bounded, Generic, FromDhall, ToDhall)

-- | One declared dependency edge from a component onto another component.
data ComponentDependency = ComponentDependency
  { dependency_on :: ComponentId
  , dependency_edge :: EdgeKind
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | A component node: its id, the edges it depends on, and the typed probe that
-- proves __it__ ready (and therefore gates its consumers).
data ComponentNode = ComponentNode
  { component_id :: ComponentId
  , depends_on :: [ComponentDependency]
  , readiness :: ReadinessProbe
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | The dependency ids a node declares, dropping edge kind.
componentDependencyIds :: ComponentNode -> [ComponentId]
componentDependencyIds = map dependency_on . depends_on

-- | Why a declared component graph is not a well-formed bring-up graph. Each
-- constructor corresponds to one expansion-time rejection (doctrine §3.2).
data ComponentGraphError
  = -- | Two nodes declare the same 'ComponentId'.
    ComponentGraphDuplicate ComponentId
  | -- | A cycle in the dependency edges (rendered path).
    ComponentGraphCycle String
  | -- | A @depends_on@ edge references a component with no declared node.
    ComponentGraphDanglingDependency ComponentId ComponentId
  | -- | A 'BackendWriteEdge' from a consumer onto a dependency whose consumer
    -- carries no matching deep readiness node — the doctrine's
    -- "edge without a readiness node" rejection. The consumer's probe must be a
    -- deep round-trip through the named dependency.
    ComponentGraphBackendEdgeWithoutDeepReadiness ComponentId ComponentId ReadinessProbe
  | -- | A component's capability requirement or provision spec did not resolve
    -- (an invalid coordinate field or generation). Cannot occur for the default
    -- table; kept for totality (Sprint 1.61 Increment B).
    ComponentGraphRequirementInvalid ComponentId String
  | -- | No component provides the capability a consumer requires at its service
    -- and scope (Validation #3: missing provider).
    ComponentGraphNoProvider ComponentId CapabilityOp
  | -- | More than one component provides the same capability at one service and
    -- scope (Validation #3: duplicate exclusive provider).
    ComponentGraphAmbiguousProvider ComponentId CapabilityOp
  | -- | The lone provider of the required operation is at a different coordinate
    -- (endpoint / logical name / generation), so its digest does not reconcile
    -- (Validation #3: scope mismatch).
    ComponentGraphScopeMismatch ComponentId CapabilityOp
  | -- | No provider offers the required operation, but a strictly weaker-tier
    -- capability is offered at the same service and scope — a GET where a write
    -- is required (Validation #3: weaker capability substitution).
    ComponentGraphWeakerCapability ComponentId CapabilityOp
  deriving (Eq, Show)

renderComponentGraphError :: ComponentGraphError -> String
renderComponentGraphError = \case
  ComponentGraphDuplicate cid ->
    "Duplicate component node: " ++ componentIdText cid
  ComponentGraphCycle path -> path
  ComponentGraphDanglingDependency consumer dependency ->
    "Component `"
      ++ componentIdText consumer
      ++ "` depends on `"
      ++ componentIdText dependency
      ++ "`, which has no declared node in the graph."
  ComponentGraphBackendEdgeWithoutDeepReadiness consumer dependency probe ->
    "Component `"
      ++ componentIdText consumer
      ++ "` declares a backend-write edge onto `"
      ++ componentIdText dependency
      ++ "` but its readiness probe ("
      ++ show probe
      ++ ") is not a deep round-trip through `"
      ++ componentIdText dependency
      ++ "`. A backend-write edge is satisfiable only by "
      ++ "ProbeBackendRoundTrip through that exact dependency "
      ++ "(bootstrap_readiness_doctrine.md M3)."
  ComponentGraphRequirementInvalid cid detail ->
    "Component `" ++ componentIdText cid ++ "` capability spec is invalid: " ++ detail
  ComponentGraphNoProvider consumer op ->
    "Component `"
      ++ componentIdText consumer
      ++ "` requires "
      ++ show op
      ++ " but no component provides it at that service and scope."
  ComponentGraphAmbiguousProvider consumer op ->
    "Component `"
      ++ componentIdText consumer
      ++ "` requires "
      ++ show op
      ++ " but more than one component provides it at that service and scope."
  ComponentGraphScopeMismatch consumer op ->
    "Component `"
      ++ componentIdText consumer
      ++ "` requires "
      ++ show op
      ++ " but the sole provider is at a different coordinate (scope mismatch)."
  ComponentGraphWeakerCapability consumer op ->
    "Component `"
      ++ componentIdText consumer
      ++ "` requires "
      ++ show op
      ++ " but only a strictly weaker capability is offered at that service and scope "
      ++ "(a read cannot satisfy a write/CAS requirement)."

-- | A validated component graph: the node map plus the derived
-- dependencies-before-dependents reconcile order. Construct it only through
-- 'validateComponentGraph', so holding a 'ComponentDag' is proof the graph is
-- acyclic, fully-connected, and deep-gated.
data ComponentDag = ComponentDag
  { componentDagNodes :: Map ComponentId ComponentNode
  , componentDagOrder :: [ComponentId]
  , componentDagRequirements :: Map ComponentId SomeCapabilityRequirement
  -- ^ Sprint 1.61 Increment B: the single resolved capability requirement each
  -- node's readiness barrier observes — the "one handle" a consumer receives
  -- instead of separately supplied probe and execution coordinates. Populated
  -- by 'validateComponentGraph' after every node's requirement resolves to a
  -- unique provider.
  }
  deriving (Eq, Show)

-- | The resolved capability requirement whose Ready observation proves the given
-- component ready (its "one handle").
componentCapabilityRequirement :: ComponentId -> ComponentDag -> Maybe SomeCapabilityRequirement
componentCapabilityRequirement cid = Map.lookup cid . componentDagRequirements

lookupComponentNode :: ComponentId -> ComponentDag -> Maybe ComponentNode
lookupComponentNode cid = Map.lookup cid . componentDagNodes

-- | Every @(consumer, dependency)@ edge of the validated graph. Sprint 4.43 uses
-- this to prove the reconcile bring-up order respects the graph — a dependency's
-- bring-up step must precede its consumer's.
componentDagEdges :: ComponentDag -> [(ComponentId, ComponentId)]
componentDagEdges dag =
  [ (component_id node, dep)
  | node <- Map.elems (componentDagNodes dag)
  , dep <- componentDependencyIds node
  ]

-- | Validate a declared component graph and lower it to a 'ComponentDag'
-- (M1/M2/M3). Rejections, in order:
--
--   1. __duplicate__ — two nodes share a 'ComponentId';
--   2. __dangling dependency__ — a @depends_on@ id has no declared node;
--   3. __backend edge without a deep readiness node__ — a 'BackendWriteEdge'
--      whose consumer's probe is not a deep round-trip through that dependency;
--   4. __cycle__ — a back-edge under the shared acyclic expansion.
--
-- A graph that passes all four projects to a deterministic topological order.
validateComponentGraph :: [ComponentNode] -> Either ComponentGraphError ComponentDag
validateComponentGraph nodes = do
  nodeMap <- buildNodeMap nodes
  mapM_ (checkNodeEdges nodeMap) nodes
  order <- topologicalOrderOf nodeMap
  -- Sprint 1.61 Increment B: lower the graph over capabilities, in parallel with
  -- the nominal readiness/edge checks above. Each node resolves to one requirement
  -- backed by a unique provider; the nominal ordering is unaffected.
  let cids = Map.keys nodeMap
  provisions <- mapM resolveComponentProvision cids
  requirements <- mapM resolveComponentRequirement cids
  resolvedRequirements <- resolveCapabilityProviders provisions requirements
  pure
    ComponentDag
      { componentDagNodes = nodeMap
      , componentDagOrder = order
      , componentDagRequirements = resolvedRequirements
      }

-- | Build the id→node map, rejecting duplicate ids.
buildNodeMap :: [ComponentNode] -> Either ComponentGraphError (Map ComponentId ComponentNode)
buildNodeMap = foldr insertUnique (Right Map.empty)
 where
  insertUnique node acc = do
    m <- acc
    let cid = component_id node
    if Map.member cid m
      then Left (ComponentGraphDuplicate cid)
      else Right (Map.insert cid node m)

-- | Check every edge of a node: the dependency must exist (no dangling id), and
-- a backend-write edge must be covered by a deep round-trip probe on the
-- consumer.
checkNodeEdges
  :: Map ComponentId ComponentNode -> ComponentNode -> Either ComponentGraphError ()
checkNodeEdges nodeMap node = mapM_ checkEdge (depends_on node)
 where
  consumer = component_id node
  consumerProbe = readiness node
  checkEdge dep =
    let dependency = dependency_on dep
     in if not (Map.member dependency nodeMap)
          then Left (ComponentGraphDanglingDependency consumer dependency)
          else case dependency_edge dep of
            OrderingEdge -> Right ()
            BackendWriteEdge ->
              if probeSatisfiesBackendWrite dependency consumerProbe
                then Right ()
                else
                  Left
                    ( ComponentGraphBackendEdgeWithoutDeepReadiness
                        consumer
                        dependency
                        consumerProbe
                    )

-- | The topological order over the node map, reusing the shared acyclic
-- expansion. Roots are every declared node (so isolated components still
-- appear); the shared expansion rejects cycles as a 'ComponentGraphCycle'.
topologicalOrderOf
  :: Map ComponentId ComponentNode -> Either ComponentGraphError [ComponentId]
topologicalOrderOf nodeMap =
  case acyclicTopologicalOrder componentIdText fromEnum adjacency roots of
    Left message -> Left (ComponentGraphCycle message)
    Right order -> Right order
 where
  roots = Map.keys nodeMap
  adjacency cid =
    fmap componentDependencyIds (Map.lookup cid nodeMap)

-- | The reconcile bring-up order for a validated graph: the dependencies-before
-- -dependents projection (M1). This is the pure order Sprint `4.43` drives the
-- reconcile driver from and Sprint `3.23` filters for chart ordering.
componentReconcileOrder :: ComponentDag -> [ComponentId]
componentReconcileOrder = componentDagOrder

-- Sprint 1.61 Increment B: capability lowering --------------------------------

-- | The single capability whose Ready observation proves each component ready. A
-- closed-'ComponentId' table (a new id fails the warning-clean build), decoupled
-- from the nominal 'readiness' probe so the Tier-0 wire config is untouched. The
-- two components that prove readiness by a backend round trip map to a mutating
-- operation, so 'edgeKindOf' derives their 'BackendWriteEdge' from the tier.
componentCapabilityOp :: ComponentId -> CapabilityOp
componentCapabilityOp = \case
  ComponentClusterBase -> OpProcessAvailability
  ComponentMinio -> OpManagedObserve
  ComponentVaultWorkload -> OpWorkloadAvailability
  ComponentVaultUnsealed -> OpVaultBootstrapObserve
  ComponentRegistry -> OpRegistryPublication
  ComponentMetalLB -> OpOperatorAvailability
  ComponentEnvoyGateway -> OpOperatorAvailability
  ComponentCertManager -> OpOperatorAvailability
  ComponentPerconaPostgresOperator -> OpOperatorAvailability
  ComponentGatewayDaemonPreVault -> OpGatewayFrontDoor
  ComponentGatewayDaemonFull -> OpLifecycleCas
  ComponentChartPulsar -> OpWorkloadAvailability
  ComponentChartRedis -> OpWorkloadAvailability
  ComponentChartKeycloakPostgres -> OpWorkloadAvailability
  ComponentChartKeycloak -> OpWorkloadAvailability
  ComponentChartVscode -> OpWorkloadAvailability
  ComponentChartApi -> OpWorkloadAvailability
  ComponentChartWebsocket -> OpWorkloadAvailability
  ComponentChartGateway -> OpGatewayFrontDoor

componentServiceText :: ComponentId -> Text
componentServiceText = Text.pack . componentIdText

-- | A component's readiness endpoint text, unique per component so each
-- component self-provides at a distinct coordinate.
componentEndpointText :: ComponentId -> Text
componentEndpointText cid = Text.pack ("component/" <> componentIdText cid)

-- | The single scope every home-substrate component is addressed in. Substrate
-- scoping is a later increment; the graph is single-scope today.
componentScopeText :: Text
componentScopeText = "home/prodbox"

-- | The flat requirement spec for a component's readiness capability.
componentRequirementSpec :: ComponentId -> CapabilityRequirementSpec
componentRequirementSpec cid =
  CapabilityRequirementSpec
    { specRequireCapability = componentCapabilityOp cid
    , specRequireService = componentServiceText cid
    , specRequireScope = componentScopeText
    , specRequireEndpoint = componentEndpointText cid
    , specRequireLogical = "readiness"
    , specRequireGeneration = 1
    , specRequireLatencyMicros = 30_000_000
    }

-- | The flat provision spec for a component's readiness capability — each
-- component self-provides its readiness at its own coordinate.
componentProvisionSpec :: ComponentId -> CapabilityProvisionSpec
componentProvisionSpec cid =
  CapabilityProvisionSpec
    { specProvideCapability = componentCapabilityOp cid
    , specProvideService = componentServiceText cid
    , specProvideScope = componentScopeText
    , specProvideEndpoint = componentEndpointText cid
    , specProvideLogical = "readiness"
    , specProvideGeneration = 1
    }

resolveComponentRequirement
  :: ComponentId -> Either ComponentGraphError (ComponentId, SomeCapabilityRequirement)
resolveComponentRequirement cid =
  case resolveRequirement (componentRequirementSpec cid) of
    Left err -> Left (ComponentGraphRequirementInvalid cid (renderRequirementError err))
    Right requirement -> Right (cid, requirement)

resolveComponentProvision
  :: ComponentId -> Either ComponentGraphError (ComponentId, SomeCapabilityProvision)
resolveComponentProvision cid =
  case resolveProvision (componentProvisionSpec cid) of
    Left err -> Left (ComponentGraphRequirementInvalid cid (renderRequirementError err))
    Right provision -> Right (cid, provision)

-- | The 'EdgeKind' a requirement implies: a round-trip-evidence operation is a
-- backend-write edge, everything else an ordering edge. Derived from the operation
-- tier, so there is no second authored source to drift from the operation kind.
edgeKindOf :: SomeCapabilityRequirement -> EdgeKind
edgeKindOf requirement
  | requiresRoundTripEvidence (requirementOp requirement) = BackendWriteEdge
  | otherwise = OrderingEdge

coordinateServiceScope :: CapabilityCoordinate -> (Text, Text)
coordinateServiceScope coordinate =
  ( serviceIdentityText (coordService coordinate)
  , authorityScopeText (coordAuthority coordinate)
  )

requirementServiceScope :: SomeCapabilityRequirement -> (Text, Text)
requirementServiceScope = coordinateServiceScope . requirementCoordinate'

provisionServiceScope :: SomeCapabilityProvision -> (Text, Text)
provisionServiceScope = coordinateServiceScope . provisionCoordinate'

-- | Resolve every requirement to a unique, exact-coordinate provider, or reject
-- with the first violation. Exposed so the graph tests exercise each rejection
-- directly with constructed provision/requirement sets.
resolveCapabilityProviders
  :: [(ComponentId, SomeCapabilityProvision)]
  -> [(ComponentId, SomeCapabilityRequirement)]
  -> Either ComponentGraphError (Map ComponentId SomeCapabilityRequirement)
resolveCapabilityProviders provisions requirements = do
  let index = foldr indexProvision Map.empty provisions
  mapM_ (checkRequirementProvider index) requirements
  pure (Map.fromList requirements)
 where
  indexProvision entry@(_, provision) =
    Map.insertWith (++) (provisionServiceScope provision) [entry]

checkRequirementProvider
  :: Map (Text, Text) [(ComponentId, SomeCapabilityProvision)]
  -> (ComponentId, SomeCapabilityRequirement)
  -> Either ComponentGraphError ()
checkRequirementProvider index (consumer, requirement) =
  case sameOperationProviders of
    [(_, provision)]
      | matchesProvision requirement provision -> Right ()
      | otherwise -> Left (ComponentGraphScopeMismatch consumer requiredOp)
    [] ->
      if any (provisionWeakerThanRequirement requirement . snd) candidates
        then Left (ComponentGraphWeakerCapability consumer requiredOp)
        else Left (ComponentGraphNoProvider consumer requiredOp)
    _ -> Left (ComponentGraphAmbiguousProvider consumer requiredOp)
 where
  requiredOp = requirementOp requirement
  candidates = Map.findWithDefault [] (requirementServiceScope requirement) index
  sameOperationProviders = filter ((== requiredOp) . provisionOp . snd) candidates

provisionWeakerThanRequirement :: SomeCapabilityRequirement -> SomeCapabilityProvision -> Bool
provisionWeakerThanRequirement requirement provision =
  tierRank (permitTier (provisionOp provision)) < tierRank (requirementTier requirement)

tierRank :: PermitTier -> Int
tierRank tier = case tier of
  TierObserveOnly -> 0
  TierInternalCas -> 1
  TierExternalIntent -> 2

-- | Sprint 3.23: the chart-only deploy order (dependencies-before-dependents)
-- reachable from a given chart component, sourced from the validated graph but
-- keeping only chart→chart edges. Infrastructure dependencies (the registry,
-- the Percona operator) are ordering/gate concerns for the reconcile driver and
-- the operator gate, not the chart deploy list — so they are filtered here,
-- reproducing the historical hardcoded chart dependency order. Reuses the shared
-- acyclic expansion, so a chart cycle is rejected exactly as before.
chartComponentDeployOrder :: ComponentDag -> ComponentId -> Either String [ComponentId]
chartComponentDeployOrder dag root =
  acyclicTopologicalOrder componentIdText fromEnum chartAdjacency [root]
 where
  chartAdjacency cid =
    fmap (filter isChartComponent . componentDependencyIds) (lookupComponentNode cid dag)
  isChartComponent cid = case chartNameForComponent cid of
    Just _ -> True
    Nothing -> False

-- | Sprint 3.23: the direct chart-level dependencies of a chart component (the
-- chart→chart edges only), for the @charts list@ / @charts status@ dependency
-- display that formerly read the hardcoded @chartDefinitionDependencies@ literal.
directChartDependencies :: ComponentDag -> ComponentId -> [ComponentId]
directChartDependencies dag cid =
  case lookupComponentNode cid dag of
    Nothing -> []
    Just node -> filter isChartComponent (componentDependencyIds node)
 where
  isChartComponent c = case chartNameForComponent c of
    Just _ -> True
    Nothing -> False

-- | Sprint 3.23: the distinct operator-gated dependencies (readiness
-- 'ProbeOperatorAvailable') that the given consumer components directly depend
-- on. A chart's dependency on such an operator becomes an "operator must report
-- @Available@" deploy gate, replacing the retired @ChartRequiresPatroniPlatform@
-- external-requirement literal with a graph edge
-- (bootstrap_readiness_doctrine.md M3: presence ≠ readiness).
operatorAvailableGates :: ComponentDag -> [ComponentId] -> [ComponentId]
operatorAvailableGates dag consumers =
  foldr dedup [] gates
 where
  gates =
    [ dep
    | consumer <- consumers
    , Just node <- [lookupComponentNode consumer dag]
    , dep <- componentDependencyIds node
    , Just depNode <- [lookupComponentNode dep dag]
    , readiness depNode == ProbeOperatorAvailable
    ]
  dedup x acc = if x `elem` acc then acc else x : acc

-- | The default bootstrap component dependency/readiness graph — the M2
-- config-sourced default that 'Prodbox.Settings.defaultConfigFile' seeds. It
-- encodes the home-substrate bring-up topology the reconcile driver realizes:
--
--   * MinIO comes up on the cluster base and proves itself by its own rollout.
--   * The registry ("harbor" front door) has a __backend-write__ edge onto MinIO
--     (it streams pushed blobs to MinIO S3), so its readiness is a deep
--     round-trip through MinIO — never the front-door @GET /v2/@ proxy. This is
--     the exact edge whose shallow gate produced the motivating
--     @no such host@ failure (doctrine §1).
--   * Charts order behind their platform dependencies; @keycloak-postgres@ gates
--     on the Percona operator being @Available@ (a deep operator gate), not
--     merely present (Sprint `3.23`).
defaultComponentGraph :: [ComponentNode]
defaultComponentGraph =
  [ node ComponentClusterBase [] ProbeServiceActive
  , node
      ComponentMetalLB
      [ orderingOn ComponentClusterBase
      , orderingOn ComponentRegistry
      , orderingOn ComponentVaultUnsealed
      ]
      ProbeRolloutComplete
  , node
      ComponentEnvoyGateway
      [ orderingOn ComponentClusterBase
      , orderingOn ComponentRegistry
      , orderingOn ComponentVaultUnsealed
      ]
      ProbeRolloutComplete
  , node
      ComponentCertManager
      [orderingOn ComponentClusterBase, orderingOn ComponentRegistry]
      ProbeRolloutComplete
  , node ComponentMinio [orderingOn ComponentClusterBase] ProbeRolloutComplete
  , node ComponentVaultWorkload [orderingOn ComponentClusterBase] ProbeRolloutComplete
  , node
      ComponentVaultUnsealed
      [ orderingOn ComponentVaultWorkload
      , orderingOn ComponentGatewayDaemonPreVault
      ]
      ProbeVaultUnsealed
  , node
      ComponentRegistry
      [orderingOn ComponentClusterBase, backendWriteOn ComponentMinio]
      (ProbeBackendRoundTrip ComponentMinio)
  , node
      ComponentPerconaPostgresOperator
      [ orderingOn ComponentClusterBase
      , orderingOn ComponentRegistry
      , orderingOn ComponentVaultUnsealed
      ]
      ProbeOperatorAvailable
  , node
      ComponentGatewayDaemonPreVault
      [ orderingOn ComponentMinio
      , orderingOn ComponentCertManager
      , orderingOn ComponentVaultWorkload
      , orderingOn ComponentRegistry
      ]
      ProbeRolloutComplete
  , node
      ComponentGatewayDaemonFull
      [ orderingOn ComponentVaultUnsealed
      , orderingOn ComponentGatewayDaemonPreVault
      , backendWriteOn ComponentMinio
      ]
      (ProbeBackendRoundTrip ComponentMinio)
  , -- Charts (deploy behind the registry — their images are mirrored there — and
    -- behind their platform dependencies).
    node ComponentChartPulsar [orderingOn ComponentRegistry] ProbeRolloutComplete
  , node ComponentChartRedis [orderingOn ComponentRegistry] ProbeRolloutComplete
  , node
      ComponentChartKeycloakPostgres
      [orderingOn ComponentRegistry, orderingOn ComponentPerconaPostgresOperator]
      ProbeRolloutComplete
  , node
      ComponentChartKeycloak
      [orderingOn ComponentChartKeycloakPostgres]
      ProbeRolloutComplete
  , node ComponentChartVscode [orderingOn ComponentChartKeycloak] ProbeRolloutComplete
  , node ComponentChartApi [orderingOn ComponentRegistry] ProbeRolloutComplete
  , node ComponentChartWebsocket [orderingOn ComponentChartRedis] ProbeRolloutComplete
  , node ComponentChartGateway [orderingOn ComponentChartPulsar] ProbeRolloutComplete
  ]
 where
  node cid deps probe =
    ComponentNode {component_id = cid, depends_on = deps, readiness = probe}
  orderingOn cid = ComponentDependency {dependency_on = cid, dependency_edge = OrderingEdge}
  backendWriteOn cid =
    ComponentDependency {dependency_on = cid, dependency_edge = BackendWriteEdge}
