# Resource Scaling Doctrine

**Status**: Authoritative source
**Supersedes**: the scaling prose in [envoy_gateway_edge_doctrine.md § 8](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine) (Envoy / application / Keycloak / Redis "may scale horizontally" statements) — that section now points here for the typed capacity, policy, and placement model; it retains only per-component availability notes.
**Referenced by**: [documents/engineering/README.md](./README.md), [DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md), [DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md), [documents/engineering/cluster_topology_doctrine.md](./cluster_topology_doctrine.md), [documents/engineering/tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md)
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox sizes, scales, and places workloads against a typed capacity budget — the `fitsWithin` lemmas that make over-committed nodes, clusters, and AWS regions unrepresentable, the substrate-indexed `ScalingPolicy`, the spot-price and region-quota gates, and federation-scoped placement — with prodbox acting as its own autoscaler.

> **Scheduling honesty.** Everything here is written as present-tense doctrine per
> [development_plan_standards § D](../../DEVELOPMENT_PLAN/README.md), but the capability is
> split across sprints: the capacity/scaling Dhall schema and config surface landed in **Sprint
> 1.51** (Phase 1), the pure autoscaler + federation-scoped placement planner landed in
> **Sprint 4.34** (Phase 4), the storage/region-quota preflight adapter landed in **Sprint 4.36**
> (Phase 4), and the spot-economics gate plus AWS observer surface landed in **Sprint 7.27**
> (Phase 7). Status is owned only by
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

The canonical schema is `dhall/capacity/Schema.dhall` (Sprint 1.51, mirroring `jitML
dhall/project/Schema.dhall`); this fragment teaches the shape and is **not** the SSoT:

```dhall
-- Example: the capacity-budget facet — mirrors jitML dhall/project/Schema.dhall IN KIND.
-- Canonical schema: dhall/capacity/Schema.dhall. NOT the SSoT.
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

`src/Prodbox/Settings.hs` no longer carries unbounded replica knobs. The former
`envoy_gateway_controller_replicas`, `envoy_gateway_data_plane_replicas`, `api_replicas`, and
`websocket_replicas` fields are replaced by substrate-indexed policy fields:
`envoy_gateway_controller_scaling`, `envoy_gateway_data_plane_scaling`, `api_scaling`, and
`websocket_scaling`.

The landed Sprint 1.51 shape is a Dhall/Haskell union plus an explicit substrate map. `Fixed` is legal
on every substrate. `Elastic { min, max }` is legal only in the `aws` slot; `home_local` must remain
`Fixed`. The config validator rejects `min = 0`, `min > max`, and `home_local = Elastic ...` at the
decode boundary, so there is no admitted validated config value for "scale out on fixed metal."

```haskell
-- File: src/Prodbox/Substrate.hs
data ElasticScalingBounds = ElasticScalingBounds
  { elasticMin :: Natural
  , elasticMax :: Natural
  }

data ScalingPolicy
  = ScalingPolicyFixed Natural
  | ScalingPolicyElastic ElasticScalingBounds

data ScalingPolicyBySubstrate = ScalingPolicyBySubstrate
  { scalingHomeLocal :: ScalingPolicy
  , scalingAws :: ScalingPolicy
  }
```

Until the live interpreter consumes the Sprint 4.34 autoscaler planner, renderers use
`replicasForSubstrate`: fixed policies render their count, and elastic AWS policies render their lower
bound as a stable replica count. `Prodbox.Scaling.Autoscaler` owns the pure check-before-mutate plan
shape that turns scaling intents into trusted, capacity-checked, leader-preserving actions.

## 4. The Spot-Price Gate (Managed-Cloud Only)

A `SpotPriceThreshold` is a per-workload USD/hour ceiling that is **meaningful only on
`SubstrateAws`** — the home-local substrate has no node market, so `spotGateForScalingPolicy` makes
that substrate a structural no-op. On the cloud substrate a spot-elastic workload deploys or moves
onto spot capacity **only when the observed price is below its threshold**. Price observation is
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
admitSpotDeploy (SpotPriceThreshold priceCeiling) obs = case obs of
  SpotObserved price
    | price < priceCeiling -> SpotAdmit
    | otherwise            -> SpotDefer PriceAboveThreshold
  SpotUnobservable r  -> SpotRefuse r                  -- fail closed, never "deploy anyway"
```

`SpotRefuse` is the `Unreachable → refuse` soundness rule of
[lifecycle_reconciliation_doctrine § 3.1 invariant 2](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
applied to placement economics. `src/Prodbox/Scaling/Spot.hs` owns the pure gate and
`src/Prodbox/Aws.hs` owns the live credential-region `ec2 describe-spot-price-history` observer.

## 5. The Region Service-Quota Preflight (Rule o)

Rule **o** — `Σ nodes.machine ⊆ region.quota` — is enforced by **reusing the existing quota
machinery**, not a parallel one. `src/Prodbox/Aws.hs` already carries `QuotaSpec` (line 234), the
per-tier `quotaSpecsForTier` / `fullQuotaSpecs` spec sets, `ensureServiceQuota` (line 2589), and
`applyAwsCheckQuotas` (line 2143); the region is the **credential region** projected by
`src/Prodbox/AwsEnvironment.hs` (`AWS_REGION` / `AWS_DEFAULT_REGION` overlay), never a separate flag.

Sprint 4.36 exposes this as a quota preflight adapter over the existing `QuotaStatus` values: before
any AWS scaling deploy grows a node group, the desired `Σ nodes.machine` footprint is checked against
the credential region's observed quota statuses, and a shortfall refuses the deploy with the
structured per-quota remedy (the same `ensureServiceQuota` output an operator would see) **before**
any AWS mutation. The live observer remains the canonical `applyAwsCheckQuotas` /
`ensureServiceQuota` boundary; local validation stubs `QuotaStatus` so the refusal fold is pure. The
storage axis of the region budget is cross-owned by
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
- **Linked dependents** (the modules Sprints 1.51 / 4.34 / 4.36 / 7.27 implement this in):
  `dhall/capacity/Schema.dhall` and `src/Prodbox/Capacity/Config.hs` (the shared `Budget` /
  `fitsWithin` / `storageFitsWithin` algebra), `src/Prodbox/Settings.hs` (`DeploymentSection`
  scaling fields plus the binary-sibling `capacity` block), `src/Prodbox/Substrate.hs`
  (`ScalingPolicy`, `ScalingPolicyBySubstrate`, and substrate validation),
  `src/Prodbox/Capacity/Storage.hs` (storage-capacity drawdown, ML storage totals, and
  region-quota preflight refusal fold),
  `src/Prodbox/Scaling/Autoscaler.hs` (pure trusted-placement, capacity-check, and
  gateway-leader-preserving action planner),
  `src/Prodbox/Aws.hs` (`QuotaSpec` / `ensureServiceQuota` / `applyAwsCheckQuotas` region-quota
  preflight), `src/Prodbox/AwsEnvironment.hs` (credential-region projection),
  `src/Prodbox/Lifecycle/ResidueStatus.hs` (the three-valued observation pattern the spot/quota gates
  mirror), `src/Prodbox/Lifecycle/ResourceRegistry.hs` (the `reconcileAbsent` substrate scaling
  reuses), and `src/Prodbox/Gateway/Types.hs` (`Disposition` — leadership the scaler must not
  perturb).

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
