# Resource Scaling Doctrine

**Status**: Authoritative source
**Supersedes**: the scaling prose in [envoy_gateway_edge_doctrine.md § 8](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine) (Envoy / application / Keycloak / Redis "may scale horizontally" statements) — that section now points here for the typed capacity, policy, and placement model; it retains only per-component availability notes.
**Referenced by**: [documents/engineering/README.md](./README.md), [DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md), [DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md), [documents/engineering/cluster_topology_doctrine.md](./cluster_topology_doctrine.md), [documents/engineering/tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md)
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox sizes, scales, and places workloads against a typed capacity budget — the `fitsWithin` lemmas that make over-committed nodes, clusters, and AWS regions unrepresentable, the substrate-indexed `ScalingPolicy`, the spot-price and region-quota gates, and federation-scoped placement — with prodbox acting as its own autoscaler.

> **Scheduling honesty.** Everything here is written as present-tense doctrine per
> [development_plan_standards § D](../../DEVELOPMENT_PLAN/README.md), but the capability is
> **scheduled, not built**: the capacity/scaling Dhall schema and config land in **Sprint 1.51**
> (Phase 1), the autoscaler + multi-cluster placement reconciler in **Sprint 4.34** (Phase 4), and
> the spot-economics gate in **Sprint 7.27** (Phase 7). Status is owned only by
> [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md); this doc never restates it.

## 1. Prodbox Is Its Own Autoscaler

`~/amoebius` expresses *dynamic node provisioning driven by load, spot-instance cost, and workflow
completion* as a deployment-rules concern of its recursive cluster forest
(`/home/matthewnowak/amoebius/documents/engineering/cluster_lifecycle_doctrine.md § 8`). prodbox is
the **proven single-node root-control-plane specialization** amoebius cites and generalizes: it does
not delegate elasticity to an in-cluster HPA/Cluster-Autoscaler it merely configures — **prodbox
itself computes the desired node and workload set** and reconciles the world toward it, the same way
it owns the full local-cluster and AWS-substrate lifecycle
([lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md)).

The capacity vocabulary **mirrors in kind** (no code dependency; mirror-now, refactor-onto-hostbootstrap-later)
`~/hostbootstrap`'s `Budget{cpu,memory,storage}` + `fitsWithin` "hard ceiling, not advice" model and
`~/jitML`'s `assert`-carried-budget-lemma idiom (`jitML dhall/project/Schema.dhall`).

## 2. The Capacity Budget and the `fitsWithin` Lemmas

A `Budget` is a monotone `{cpu, memory, storage}` triple. One relation — `fitsWithin inner outer`
(componentwise `≤`) — is the whole safety algebra. Three over-commitment classes are made
**unrepresentable** at Dhall typecheck time, not caught at runtime:

| Rule | Statement | The illegal state it forbids |
|------|-----------|------------------------------|
| **g** | `node.demand ⊆ node.machine` | A cluster **node** requesting more cpu/ram/storage than the machine hosting it physically has. |
| **h** | `cluster.workload ⊆ Σ nodes.machine` | A **workload** needing more than the cluster's summed node capacity. |
| **o** | `Σ nodes.machine ⊆ region.quota` | An **AWS deploy** whose provisioned footprint exceeds the region service quota (§5). |

The canonical schema is the scheduled `dhall/CapacitySchema.dhall` (Sprint 1.51, mirroring
`jitML dhall/project/Schema.dhall`); this fragment teaches the shape and is **not** the SSoT:

```dhall
-- Example: the capacity-budget facet — mirrors jitML dhall/project/Schema.dhall IN KIND.
-- Canonical schema: the scheduled dhall/CapacitySchema.dhall (Sprint 1.51). NOT the SSoT.
let Budget = { cpu : Natural, memory : Natural, storage : Natural }
let lessOrEq = \(a : Natural) -> \(b : Natural) -> Natural/isZero (Natural/subtract b a)
let fitsWithin
    : Budget -> Budget -> Bool
    = \(inner : Budget) -> \(outer : Budget) ->
            lessOrEq inner.cpu outer.cpu
        &&  lessOrEq inner.memory outer.memory
        &&  lessOrEq inner.storage outer.storage
let zero = { cpu = 0, memory = 0, storage = 0 }
let plus = \(a : Budget) -> \(b : Budget) ->
        { cpu = a.cpu + b.cpu, memory = a.memory + b.memory, storage = a.storage + b.storage }
let Node    = { nodeName : Text, demand : Budget, machine : Budget }
let Cluster = { nodes : List Node, workload : Budget, regionQuota : Budget }
let sumMachines = \(ns : List Node) ->
        List/fold Node ns Budget (\(n : Node) -> \(acc : Budget) -> plus n.machine acc) zero
let allNodes = \(p : Node -> Bool) -> \(ns : List Node) ->
        List/fold Node ns Bool (\(n : Node) -> \(acc : Bool) -> p n && acc) True
let contractOK
    : Cluster -> Bool
    = \(c : Cluster) ->
            allNodes (\(n : Node) -> fitsWithin n.demand n.machine) c.nodes  -- rule g
        &&  fitsWithin c.workload (sumMachines c.nodes)                       -- rule h
        &&  fitsWithin (sumMachines c.nodes) c.regionQuota                    -- rule o
let self
    : Cluster
    = { nodes = [ { nodeName = "n0"
                  , demand  = { cpu = 4, memory = 8,  storage = 40  }
                  , machine = { cpu = 8, memory = 16, storage = 100 } } ]
      , workload    = { cpu = 4,  memory = 8,  storage = 40  }
      , regionQuota = { cpu = 32, memory = 64, storage = 500 } }
in  assert : contractOK self === True
```

An over-budget `self` makes `contractOK self === True` fail to typecheck — the decode aborts before
any Haskell planner runs. This is the compile ring of hostbootstrap's three-ring ceiling; the
`fitsWithin` preflight is the bring-up ring, and the substrate cordon is the runtime ring. The
**storage** axis of every `Budget` (per-PV / per-region storage-quota-as-budget) is owned by
[tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md); this doc treats storage
only as the third axis of the shared `fitsWithin` relation.

## 3. `ScalingPolicy` Indexed by Substrate Elasticity

The current `src/Prodbox/Settings.hs` `DeploymentSection` carries **unbounded** replica knobs —
`envoy_gateway_controller_replicas`, `envoy_gateway_data_plane_replicas`, `api_replicas`,
`websocket_replicas`, each a `Maybe Natural`. A `Maybe Natural` cannot express "this fleet is fixed
metal and may not elastically scale out," so it admits the illegal request structurally. Sprint 1.51
replaces those fields with a `ScalingPolicy` indexed by the substrate's **elasticity**, so
"scale out on a fixed metal fleet" has **no constructible value** (the type-index facet of
[pure_fp_standards § GADT-Indexed State Machines](./pure_fp_standards.md#gadt-indexed-state-machines) —
here used to forbid an illegal arm, not to encode an in-process command sequence):

```haskell
-- Example: scaling policy indexed by substrate elasticity. The illegal state
-- "Elastic on metal" is unconstructible, not runtime-rejected.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

data Elasticity = MetalFixed | CloudElastic

-- | Singleton recovered from the runtime 'Prodbox.Substrate.Substrate'.
data SElasticity (e :: Elasticity) where
  SMetalFixed   :: SElasticity 'MetalFixed     -- SubstrateHomeLocal: MetalLB, no node market
  SCloudElastic :: SElasticity 'CloudElastic   -- SubstrateAws: managed node groups

data ScalingPolicy (e :: Elasticity) where
  Fixed   :: NodeCount            -> ScalingPolicy e              -- admissible on EVERY substrate
  Elastic :: MinNodes -> MaxNodes -> ScalingPolicy 'CloudElastic  -- representable ONLY on cloud
```

`Fixed` is polymorphic in `e`, so a fixed size is legal everywhere. `Elastic` fixes the index to
`'CloudElastic`, so `Elastic lo hi :: ScalingPolicy 'MetalFixed` is a **type error**: home-local /
metal is `Fixed`-only, managed-cloud additionally admits `Elastic`. Bounds are typed newtypes with
total smart constructors — never bare `Natural` — so `min = 0` or `min > max` is rejected once, at
the decode boundary:

```haskell
-- Example: typed bounds + total smart constructor
newtype NodeCount = NodeCount Natural
newtype MinNodes  = MinNodes  Natural
newtype MaxNodes  = MaxNodes  Natural

data ScalingError = ScalingMinZero | ScalingMinExceedsMax Natural Natural

mkElastic :: MinNodes -> MaxNodes -> Either ScalingError (ScalingPolicy 'CloudElastic)
mkElastic lo@(MinNodes a) hi@(MaxNodes b)
  | a == 0    = Left ScalingMinZero
  | a > b     = Left (ScalingMinExceedsMax a b)
  | otherwise = Right (Elastic lo hi)
```

## 4. The Spot-Price Gate (Managed-Cloud Only)

A `SpotPriceThreshold` is a per-workload USD/hour ceiling that is **meaningful only on
`SubstrateAws`** — the home-local substrate has no node market, so the field is not part of a
`ScalingPolicy 'MetalFixed`. On the cloud substrate a spot-elastic workload deploys or moves onto
spot capacity **only when the observed price is below its threshold**. Price observation is
three-valued and fail-closed, exactly mirroring
[`src/Prodbox/Lifecycle/ResidueStatus.hs`](../../src/Prodbox/Lifecycle/ResidueStatus.hs)'s
`ResidueAbsent | ResiduePresent | ResidueUnreachable` discipline: "I could not read the price" is
**never** silently "the price is fine, deploy anyway."

```haskell
-- Example: spot observation is three-valued like ResidueStatus; Unobservable REFUSES.
data SpotObservation
  = SpotObserved     !UsdPerHour        -- authoritative current spot price
  | SpotUnobservable !UnobservableReason  -- pricing API unreachable / undecodable

data SpotDecision = SpotAdmit | SpotDefer DeferReason | SpotRefuse UnobservableReason

admitSpotDeploy :: SpotPriceThreshold -> SpotObservation -> SpotDecision
admitSpotDeploy (SpotPriceThreshold ceiling) obs = case obs of
  SpotObserved price
    | price < ceiling -> SpotAdmit
    | otherwise       -> SpotDefer PriceAboveThreshold
  SpotUnobservable r  -> SpotRefuse r                  -- fail closed, never "deploy anyway"
```

`SpotRefuse` is the `Unreachable → refuse` soundness rule of
[lifecycle_reconciliation_doctrine § 3.1 invariant 2](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
applied to placement economics. Sprint 7.27 owns the live spot-market observer and this gate.

## 5. The Region Service-Quota Preflight (Rule o)

Rule **o** — `Σ nodes.machine ⊆ region.quota` — is enforced by **reusing the existing quota
machinery**, not a parallel one. `src/Prodbox/Aws.hs` already carries `QuotaSpec` (line 234), the
per-tier `quotaSpecsForTier` / `fullQuotaSpecs` spec sets, `ensureServiceQuota` (line 2589), and
`applyAwsCheckQuotas` (line 2143); the region is the **credential region** projected by
`src/Prodbox/AwsEnvironment.hs` (`AWS_REGION` / `AWS_DEFAULT_REGION` overlay), never a separate flag.

Today this runs only when an operator invokes `prodbox aws quotas check`. Sprint 4.34 promotes it to
a **mandatory preflight on every `Substrate == SubstrateAws` scaling deploy**: before any node group
is grown, the desired `Σ nodes.machine` footprint is checked against the live `QuotaStatus` for the
credential region, and a shortfall refuses the deploy with the structured per-quota remedy (the same
`ensureServiceQuota` output an operator would see) **before** any AWS mutation. The storage axis of
the region budget is cross-owned by
[tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md); cpu/network quotas are
this doc's `fitsWithin` obligation. A quota query that cannot reach the Service Quotas API is
`Unreachable → refuse`, identical to §4 and to the lifecycle tag-sweep soundness rule.

## 6. Federation-Scoped Placement (Rule t) and Untouched Gateway Leadership

Cross-cluster placement — moving or spawning a workload onto a **different** cluster — is constrained
to clusters **reachable in the federation trust tree**
([cluster_federation_doctrine.md](./cluster_federation_doctrine.md)):

- **Rule t: a child spec cannot reach beyond its own subtree.** A placement target is drawn only from
  the placing cluster's own subtree projection. A child receives, by construction, `project(subtree)`
  — a typed spec with no field in which a sibling or ancestor-only cluster can appear — so directing a
  workload at a cluster outside that subtree is *unrepresentable*, exactly as a cross-tenant secret is
  ([cluster_federation_doctrine.md § 3–§4](./cluster_federation_doctrine.md#3-parent-custody-of-child-init-keys)).
- **Placement honors the fail-closed unseal cascade.** A target cluster whose Vault is sealed (or
  whose parent is sealed/unreachable) is *not* an eligible placement target: its capacity is opaque
  ciphertext behind a sealed Vault, so its `Budget` is `Unobservable → refuse`, never presumed
  available ([cluster_federation_doctrine.md § 7](./cluster_federation_doctrine.md#7-the-fail-closed-unseal-cascade)).

**Scaling actions never perturb gateway leadership.** In
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md) the gateway `Orders`
`node_count` is the count of **mesh peers** in the control-plane leadership set — *not* workload
replica counts. Growing or draining an elastic worker node, or changing an application's replica
count, does **not** rewrite `Orders.nodes`, does not change any node's
[`src/Prodbox/Gateway/Types.hs`](../../src/Prodbox/Gateway/Types.hs) `Disposition`
(`DispositionOwner | DispositionYielded | DispositionUnknown`), and never triggers a leadership
election or DNS re-point. Peer-set membership is a federation/gateway concern; scaling operates
strictly on the workload and worker-node sets beneath it.

## 7. Scaling Is a Reconciled Managed Resource

Scaling is **not** a bespoke controller loop; it adopts the
[lifecycle_reconciliation_doctrine § 3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
managed-resource-registry discipline wholesale. A desired scaled shape is a typed resource with a
three-valued `discover` and a `reconcileAbsent`-style converge step:

- **`discover → diff → enact → re-observe`, idempotent.** The autoscaler computes the desired
  node/workload set (pure, from `Budget` + `ScalingPolicy` + observed load), diffs the live set,
  enacts the delta, re-observes; crash recovery is "run the reconciler again."
- **`Unreachable → refuse` is total.** Every observation — spot price (§4), region quota (§5), a
  sealed-Vault downstream cluster's capacity (§6) — is three-valued, and "cannot observe" refuses.
  Scaling **up** on unobservable capacity and scaling **down** past an unobservable floor are both
  forbidden.
- **Plan / Apply** ([pure_fp_standards § Plan / Apply](./pure_fp_standards.md#plan--apply)): the
  desired-shape diff is a pure `Plan` value, `--dry-run` renders it without touching AWS or the
  cluster, and `apply` is the only effectful arm.

This is the data-oriented "make illegal states unrepresentable" answer, not a global scaling state
machine: the budget lemmas (§2) forbid over-commit at typecheck, the substrate index (§3) forbids
illegal elasticity, and the fail-closed gates (§4–§6) forbid acting on unobserved capacity.

## Intent Ownership

This SSoT co-owns prodbox resource-scaling and capacity-placement doctrine.

- **Owned statement**: prodbox is its own autoscaler; over-committed nodes/clusters/regions are made
  unrepresentable by the `fitsWithin` budget lemmas, illegal elasticity is unrepresentable by the
  substrate-indexed `ScalingPolicy`, and every scaling gate is `Unreachable → refuse`.
- **Linked dependents** (the modules Sprints 1.51 / 4.34 / 7.27 implement this in):
  `src/Prodbox/Settings.hs` (`DeploymentSection` replica fields → `ScalingPolicy`),
  `src/Prodbox/Substrate.hs` (`SubstrateHomeLocal` / `SubstrateAws` → elasticity index),
  `src/Prodbox/Aws.hs` (`QuotaSpec` / `ensureServiceQuota` / `applyAwsCheckQuotas` region-quota
  preflight), `src/Prodbox/AwsEnvironment.hs` (credential-region projection),
  `src/Prodbox/Lifecycle/ResidueStatus.hs` (the three-valued observation pattern the spot/quota gates
  mirror), `src/Prodbox/Lifecycle/ResourceRegistry.hs` (the `reconcileAbsent` substrate scaling
  reuses), and `src/Prodbox/Gateway/Types.hs` (`Disposition` — leadership the scaler must not
  perturb). The scheduled Dhall schema is `dhall/CapacitySchema.dhall`.

## Cross-References

- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) — managed-resource
  registry, `reconcileAbsent`, `Unreachable → refuse`
- [Cluster Federation Doctrine](./cluster_federation_doctrine.md) — trust tree (rule t), fail-closed
  unseal cascade
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md) — `node_count` = mesh
  peers, the leadership set scaling must not perturb
- [Pure FP Standards](./pure_fp_standards.md) — type-index "illegal states unrepresentable" + Plan/Apply
- [Envoy Gateway Edge Doctrine § 8](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine)
  — the per-component availability notes this typed model supersedes
- [Tiered Storage Capacity Doctrine](./tiered_storage_capacity_doctrine.md) · [Cluster Topology Doctrine](./cluster_topology_doctrine.md) · [Engineering Doctrine Index](./README.md) · [Documentation Standards](../documentation_standards.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md) (status; sprints 1.51 / 4.34 / 7.27) · [substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- Umbrella: `/home/matthewnowak/amoebius/.../cluster_lifecycle_doctrine.md § 8`; mirrored-in-kind
  vocabulary from `~/hostbootstrap resource_budgeting.md` and `~/jitML dhall/project/Schema.dhall`
