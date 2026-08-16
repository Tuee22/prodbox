# Resource Scaling Doctrine

**Status**: Authoritative source
**Supersedes**: the scaling prose in [envoy_gateway_edge_doctrine.md § 8](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine) (Envoy / application / Keycloak / Redis "may scale horizontally" statements) — that section now points here for the typed capacity, policy, and placement model; it retains only per-component availability notes.
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox sizes, caps, scales, and places workloads
> against typed cpu, memory, ephemeral-storage, and durable-storage budgets — the `fitsWithin`
> lemmas that make over-committed **authored admission plans** for hosts, RKE2 clusters, pods,
> namespaces, clusters, and AWS regions unrepresentable; the separate memory, CPU, service-rate,
> queue, deadline, and runtime-observation boundaries; the substrate-indexed `ScalingPolicy`; the spot-price and region-quota
> gates; and federation-scoped placement — with prodbox acting as its own autoscaler and resource
> governor.

Architecture doctrine is stated in target form. Implementation status, migration ownership, and
current-revision deployment qualification are owned only by the
[Development Plan](../../DEVELOPMENT_PLAN/README.md). The lifecycle services and their independent
resource envelopes, queues, and admission lanes are defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); this document
owns the capacity algebra they must satisfy.

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
(componentwise `≤`) — is the authored admission algebra. Three classes of over-committed desired
footprint are made **unrepresentable in a validated capacity document** at Dhall typecheck time,
rather than first being discovered by a scheduler:

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

An over-budget authored `self` makes `contractOK self === True` fail to typecheck — the decode aborts
before any Haskell planner runs. This is the compile ring of hostbootstrap's three-ring ceiling; the
`fitsWithin` preflight is the bring-up ring, and the substrate cordon is the runtime ring. The
**storage** axis of every `Budget` (per-PV / per-region storage-quota-as-budget) is owned by
[tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md); this doc treats storage
only as the third axis of the shared `fitsWithin` relation.

`demand` in these lemmas means a declared request/limit or desired provisioned footprint. It is not
a theorem about every allocation a general program may perform after admission. Static types can
exclude missing limits and arithmetic overcommitment in authored plans; they cannot prove an
arbitrary Haskell process's maximum resident set, foreign/runtime allocation, parser scratch, or
child-process peak. That separate proof boundary is §2D.

## 2A. Resource Requirements Are Mandatory and Capped

The aggregate `Budget` relation is strengthened into an admitted-resource contract for every
runtime surface that can consume host resources. A decoded, validated prodbox configuration has no
value that means "use whatever the host has." Every consumer declares both a **request** and a
**limit** for:

- cpu, in millicores
- memory, in MiB
- ephemeral storage, in MiB
- durable storage, in MiB, for PVC/PV-backed claims

`Request <= Limit` is a constructor invariant, not a convention. A missing limit, a zero limit, or a
container without an authored envelope is not representable in the validated type. This guarantees
that Kubernetes receives a finite admission/containment boundary; it does not guarantee that the
program will remain below that boundary without a runtime design and observation contract. The 4-axis
`ResourceVector` (below) is the admission/containment surface; the separate 3-axis aggregate
`Budget {cpu,memory,storage}` (`CapacityBudget`) is a **distinct, live** concern owned by
[tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md) — the durable-byte totals
in `src/Prodbox/Capacity/Storage.hs` and the placement math in `src/Prodbox/Scaling/Autoscaler.hs` — and
the two are never interchanged. The over-commit guarantee comes from the 4-axis nesting *proof*, not
from per-axis newtypes (the unwired `MilliCpu`/`MebiBytes` are retired).

### Derived workload contract

A `ResourceEnvelope` is an output, never an independent configuration input. The pure derivation
owned by `Prodbox.Capacity.Derivation` combines the compiled `RuntimeMemoryPlan`, a
`ServiceCapacityPlan` plus a calibrated service-cost basis, bounded ephemeral scratch, the
durable-storage plan used by the real PVC, replicas, Kubernetes scheduling-unit composition,
concurrency, surge, and `WorkloadQoS`.

The result is an opaque `DerivedResourceEnvelope` carrying both the projected envelope and its input
identity. `ValidatedSettings` can contain only that proof; raw Dhall cannot provide
`resources.request` or `resources.limit`.

Pure derivation does not pretend that CPU service cost can be inferred from source code. A healthy,
provenance-bound measurement supplies the empirical coefficient; exact `Natural`/ratio arithmetic
then derives CPU from admitted demand, service cost, workers, and headroom. Measurement is an input
certification boundary, not a second envelope-authoring surface. Memory and storage remain structural
projections. Implementation status belongs to
[Sprint 1.71](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md#sprint-171-derived-workload-resource-contracts--done).

```haskell
-- Raw decode surface in src/Prodbox/Capacity/Config.hs (stays FromDhall/ToDhall).
data ResourceVector = ResourceVector
  { milli_cpu :: Natural, memory_mib :: Natural
  , ephemeral_storage_mib :: Natural, durable_storage_mib :: Natural }

data ResourceEnvelope = ResourceEnvelope { request :: ResourceVector, limit :: ResourceVector }

-- Raw config carries derivation inputs, not an envelope.
data WorkloadDemandSpec = WorkloadDemandSpec
  { runtimeMemoryProfileId :: Text
  , serviceDemand :: ServiceDemandSpec
  , ephemeralScratch :: BoundedScratchSpec
  , durableStorage :: DurableStorageSpec
  , qos :: WorkloadQoS
  }

-- No authored namespace_quotas: namespace admission is derived from workload
-- contracts and Kubernetes scheduling-unit composition.
data ResourcePlan = ResourcePlan
  { host_capacity :: ResourceVector
  , rke2_reserved :: ResourceVector
  , eviction_floor :: ResourceVector
  , workload_profiles :: [WorkloadResourceProfile] }

-- The opaque proof in src/Prodbox/Capacity/Allocation.hs (constructor hidden) is the
-- sole builder, matching ServiceCapacityPlan / RuntimeMemoryPlan. Over-commitment is a
-- Left, never a value: an AllocatedResourcePlan witnesses host >= cluster >= sum(draws).
compileResourcePlan
  :: [MeasuredResourceProfile] -> (Text -> Text) -> Natural
  -> ResourcePlan -> Either CompileError SomeAllocatedPlan
```

Dhall mirrors the raw records with smart-constructor style plus `assert`-carried lemmas in
`dhall/capacity/Schema.dhall`. Haskell then decodes the raw `ResourcePlan`. Sprint `1.68` landed
`compileResourcePlan` as the sole builder of the opaque `AllocatedResourcePlan` and a `dev check`
conformance gate (`runConformanceTier`) that fails the build unless the committed `defaultResourcePlan`
compiles to a proof. Sprint `1.69` makes the proof the **decode gate**: `SomeAllocatedPlan` becomes a
required field of `ValidatedSettings`, built in `validateConfig` over the **decoded in-force** plan, so
an over-committed *authored* config — not merely the compiled-in default — has no `ValidatedSettings`
and therefore no renderer input. The runtime-`Either` `validateResourcePlan` inequality body is retired
in favor of the proof; the slim `validateRawResourcePlanShape` survives as the decode-time shape slice
`compileResourcePlan` reuses. The write-side renderers then consume only the proof — the shared render
module (Sprint `3.28`), namespace `ResourceQuota`s derived from workload draws (Sprint `3.27`), and the
observed-host recompile at reconcile (Sprint `4.52`). The budget draw uses a **non-saturating**
`resourceVectorSubtractChecked`: an over-reservation or an over-committed workload set underflows and
returns `Left`, so it can never silently clamp to zero — an over-committed plan is simply not a
constructible value. This realizes what the enforcement rings below describe; sprint status lives in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

## 2B. Host, RKE2, Cluster, Namespace, and Pod Lemmas

The resource-governor schema has five nested levels. Each lower level must fit in the level above it
after subtracting the reservations that protect the host and Kubernetes control plane:

| Rule | Statement | The illegal state it forbids |
|------|-----------|------------------------------|
| **a** | `rke2.reserved + eviction.floor <= host.physical` | An RKE2 cluster reserving more cpu/ram/storage than the host has. |
| **b** | `cluster.allocatable = host.physical - rke2.reserved - eviction.floor` via a **non-saturating** checked subtraction; re-proved at reconcile against the **observed** host — cpu/memory plus durable and ephemeral storage observed on distinct devices (a single joint budget when they share one filesystem) | Pods scheduled against the host's survival margin, or an authored host figure that exceeds the physical machine or its disks. |
| **c** | `sum(derived scheduler requests) <= cluster.allocatable`; every request is projected from runtime-memory, service-demand/calibration, scratch, durable-storage, topology, and QoS inputs. Limits remain finite per-container containment maxima but are not falsely treated as scheduler reservations. | A fit proof that blesses arbitrary requests disconnected from workload bounds, or that conflates Kubernetes containment limits with reserved host capacity. |
| **d** | Namespace request and limit quota axes are separate derived projections of Kubernetes scheduling units: regular containers sum, init containers peak, replicas/surge scale, and exclusive windows contribute their peak | Pods or hook Jobs that need more than their namespace admits, double-counted init containers, or hand-authored quota drift. |
| **e** | `forall container. request <= limit && limit > 0`; a `GuaranteedEnvelope` witness additionally requires `request == limit` on every axis | Undefined or uncapped declared container envelopes, including Kubernetes `BestEffort` pods, and a workload silently authored `Burstable` where Guaranteed QoS is mandated. |

The subtraction on this budget path is `resourceVectorSubtractChecked` — non-saturating, so an
under-flow is a `Left`, never a clamp-to-zero that would let a later `<=` pass vacuously. Co-location
and mutually-exclusive burst windows are modeled by each workload's `WorkloadConcurrency`
(`Steady | ExclusiveWindow`), so "counted exactly once" and "burst draws its own lane" hold by
construction rather than through an add-here/subtract-there hand fold.

The rendered Kubernetes shape follows directly from these values:

- kubelet args for `system-reserved`, `kube-reserved`, `eviction-hard`, `eviction-soft`,
  image-garbage-collection thresholds, and container log caps
- optional systemd drop-in limits for the `rke2-server` service process tree
- one `ResourceQuota` and `LimitRange` per prodbox-owned namespace, **derived** as the sum of that
  namespace's workload draws rather than authored (Sprint `3.27`)
- one non-empty `resources.requests` and `resources.limits` stanza for every container and init
  container in every repo-owned chart
- explicit PVC sizes **injected from the workload's `durable_storage_mib`** — the *one* durable source
  that simultaneously sizes the PVC, the namespace `requests.storage` quota, and the fit proof, so a
  chart-local PVC-size literal can no longer drift from the quota (Sprint `3.29`). Durable storage is
  non-burstable (`request == limit`) and may be `0` for a stateless workload (no PVC).

No chart template may synthesize these values locally. Chart values consume a `ResourceProfileId`
that resolves through the Haskell/Dhall resource registry. A chart whose profile is absent fails to
render, and `prodbox dev lint chart` rejects any repo-owned workload container without a rendered
`resources` block.

### Host-fitting generation (Sprint `1.73`)

`prodbox config generate` (default mode) observes the deploy host — `nproc`, `/proc/meminfo`, and
`df -Pm` for the kubelet root and the retained-PV path, into an `ObservedHostRoot` — and derives a
`host_capacity` that simultaneously **covers the plan's demand** (`rke2_reserved + eviction_floor +
Σ concurrent draws`, so the Ring-2 proof admits it) and **fits the real device** (so the Ring-3
observed-host check admits it). CPU and memory are declared at the observed capacity; a single shared
storage device is split into an ephemeral slice (its demand plus bounded headroom) and a durable
remainder, leaving ~5% device slack so a small shrink between generate and reconcile does not
immediately fail Ring 3. Generation **fails fast** when the host cannot cover the plan, surfacing rules
(a)/(b) at authoring time instead of at reconcile. `--portable` skips observation and emits the
abstract Haskell-default `host_capacity` for host-agnostic generation (the image build, whose baked
config is overwritten from the ConfigMap at runtime); the derivation lives in
`Prodbox.Capacity.HostProbe`, shared with the reconcile-time Ring-3 reader. Ring 3 remains
authoritative — the host can shrink between generate and deploy.

## 2C. Enforcement Rings

The same resource facts are enforced in three rings. They check the **same inequalities** through the
**same algebra** (DRY), but they do not offer the same *strength* of guarantee — and this doctrine is
deliberate about which ring actually makes over-commitment unrepresentable:

| Ring | Mechanism | Truly unrepresentable? |
|------|-----------|------------------------|
| **1 — Static Dhall (defense-in-depth)** | generated `dhall/capacity/Schema.dhall` exports the constructors, sums, and `assert`-carried `lessThanEqual` lemmas (phrased as `lessOrEq (Σ draws) allocatable`, **never** a saturating `Natural/subtract` that would pass vacuously). The config generator (`renderProjectConfigDhall`, Sprint `1.72`) **implements** the `assertPlanValid` shim by *lean-emit*: it emits the precomputed concurrent draws as data and inlines the `lessOrEq`/`vectorFitsWithin`/`vectorPlus` operators so the file recomputes `allocatable` from its **own** host/reservation numbers and carries `let _ = assert : planFits === True in cfg`. An over-committed emitted file — reservation exceeding host, or Σ draws exceeding allocatable — then fails Dhall type-check and no longer loads through `decodeProjectConfigDhall`; the lemmas and assert normalize away for `Dhall.auto` extraction, so a valid file round-trips unchanged (`test/unit/Tier0PlanAssert.hs`). | **No.** Dhall has no refinement/dependent types and cannot re-derive the draws (no `Natural` division, no `Text` equality) or observe the host, so it *trusts* the emitted draws and only fails a *specific evaluated file*. **Correction (2026-08-07)**: this cell previously added "`prodbox.dhall` is binary-generated (no human Dhall authoring surface)", which is false and contradicted its own next sentence — the value claimed for the shim is catching a *hand-edit*. `prodbox.dhall` is normally binary-generated but **is** a hand-editable surface: `config generate` tells the operator to edit it directly (`src/Prodbox/Native.hs`), and the [authoritative command-selection table](../../AGENTS.md#command-selection-automation-vs-operator-interactive) names direct schema-checked editing as the automation path; the `ses.*` / `pulumi_state_backend.*` / `aws_substrate.*` sections have no generator path at all. Nothing detects drift from what the generator would emit, and a hand edit survives a `config setup` re-run. Value (now realized, and correctly scoped): a baked-in cross-check that catches a host-shrinking hand-edit and a regressed generator's over-committed file, one ring ahead of the Ring-2 gate — over the resource-plan arithmetic **only**, and trusting its own emitted draws. Every other hand-edited field is unguarded until Ring 2 — and unguarded again *after* Ring 2, at every boundary where a typed value is written back out as text ([chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md#23-conversions--where-the-moves-stop)). |
| **2 — Pure Haskell decode gate (the guarantee)** | `compileResourcePlan` builds the opaque `AllocatedResourcePlan` (hidden constructor) only when host reservations, workload draws, and durable claims all fit under a non-saturating budget — a sibling of `ServiceCapacityPlan` (§2E) and `RuntimeMemoryPlan` (§2D). The proof is a **required field of `ValidatedSettings`** (typed `SomeAllocatedPlan`), built in `validateConfig` over the **decoded in-force** plan. Read at its actual strength: `validateConfig` calls `compileResourcePlanUncertified`, so the existential tag on this path is always `UncertifiedUntilFirstProfile` — the *arithmetic fit* is proven, not measured-profile certification — and `ValidatedSettings` exports its constructor, so the gate is a function rather than a type. Precisions and the bypassing construction site are recorded once, in [config_doctrine.md](./config_doctrine.md). | **Yes — within its compiled region** (see "The region of Ring 2" below). No proof ⇒ no `ValidatedSettings` ⇒ no renderer input, so an over-committed *decoded* config has no representation any command in that region can consume. This — not Dhall — is where "unrepresentable" is delivered. A `dev check` gate additionally fails the build if `defaultResourcePlan` over-commits. |
| **3 — Runtime cgroup/Kubernetes (observed host)** | `prodbox cluster reconcile` re-compiles the plan against an `ObservedHostRoot` (`compileResourcePlanAgainstObserved`), closing invariant (b) `cluster <= host` against the **observed** machine across all four axes — durable vs ephemeral observed on distinct devices, with a single shared-device joint budget when they coincide — then writes RKE2/kubelet guardrails, reconciles the derived namespace `ResourceQuota`/`LimitRange`, renders container limits, and verifies no prodbox pod is `BestEffort`. | **No — inherently runtime.** The host is discovered by IO; the strongest achievable is folding the observation into the same opaque proof so no guardrail writes without the observed proof (superseding the late `hostCapacityCoversPlan` boolean). |

This three-ring model is intentionally redundant, but honest about its ceiling: the **Haskell decode
gate** makes an over-committed *decoded* plan unrepresentable, Dhall is a generator cross-check (not a
refinement-type guarantee), and Kubernetes/systemd *contain* runtime runaway within the offending pod
or service instead of letting it consume the host. A cgroup OOM kill is therefore evidence that
containment worked and the workload's runtime contract failed; it is never evidence that the authored
limit proved sufficient.

### The region of Ring 2

A ring is not a property of a type. It is a property of a type **over a set of compiled modules**,
and that set is whatever the build command selects — not the repository. This doctrine owns the ring
vocabulary, so it owns the region too, and every other document citing "Ring 2" inherits the
qualifier from here.

**Measured 2026-08-08; closed by Sprint `5.30`.** The measurement was: `prodbox dev check` ran
`cabal build --builddir=.build all` (`src/Prodbox/CheckCode.hs`), and `cabal.project` sets no
`tests:` stanza, so that command resolved to `lib` and `exe:prodbox` and **no test suite**. The
region of every Ring-2 claim recorded against this repository up to that date was therefore `src/`
and `app/` — never `test/`. Sprint `5.30` added the flag; the invocation is now
`["build", "--builddir=.build", "all", "--enable-tests", "--ghc-options=-Werror"]`, so the region
covers the library, the executable, and all eight suites.

That closes the compile region. It does not make the region self-evident: it is still whatever the
argument list selects on the day of the claim, so **re-measure rather than cite this paragraph**.

The consequence was not hypothetical, and it is why the flag exists. Sprint `1.80` tightened a
config field into a closed union — a Ring-1 win, and a Ring-2 type change — and the integration
fixtures that hand-authored the old shape were outside the region, so what should have been a
compile error was a runtime decode failure in a suite nothing routinely compiled. Twenty cases broke
and the symptom was a network error.

Two rules follow, and they are cheap:

1. **State the region whenever you state the ring.** "Ring 2 delivers unrepresentable" without a
   region is a claim about a different set of files than the reader will assume.
2. **A gate's region must cover the surface that carries its evidence.** A build that omits `test/`
   cannot support a claim whose proof lives in `test/`. See
   [chaos_hardening_doctrine.md § 22](./chaos_hardening_doctrine.md#22-what-a-ring-2-gate-does-and-does-not-prove) for the same point stated as
   the fourth honest consequence of a ring-2 gate, and
   [code_quality.md](./code_quality.md) for the per-command scope of the lint stack.

A cgroup can correctly contain repeated OOMs while a replacement process later appears healthy.
Likewise, a process can remain within its memory ceiling while a CPU cap prevents it from meeting
its service deadline. Containment evidence never upgrades a resource limit into a sufficiency
proof; runtime demand and service capacity require the separate obligations below. Note the split
these obligations enforce: **memory sufficiency-(c) is structural** — `RuntimeMemoryPlan` proves the
heap-sum fits the envelope's container memory limit (an overrun is an OOM, a hard bound) — while
**CPU sufficiency-(c) is not** a limit relation (an overrun throttles, it does not crash) and stays
the measured, recorder-gated seam of §2E/§2F.

## 2D. Runtime Memory Decomposition and Observation

Memory admission and runtime sufficiency are different propositions:

1. The memory component of `ResourceEnvelope.limit` proves that the pod has an explicit cgroup
   ceiling and that its declared footprint fits the enclosing authored budgets.
2. `RuntimeMemoryPlan` proves that explicitly identified bounded consumers fit beneath that ceiling.
3. Live observations determine whether the implementation actually respects the plan over time.

The validated per-process decomposition is:

```text
bounded_application_state
+ bounded_pending_persistence_state
+ bounded_in_heap_transport_and_decode
+ other_heap_reserve
<= heap_cap

heap_cap
+ native_runtime_and_out_of_heap_transport_reserve
+ maximum_serialized_child_process_peak_from_bounded_schedule
+ kernel_and_cgroup_reserve
+ safety_margin
<= container_memory_limit
```

`Prodbox.Capacity.RuntimeMemory` expresses every summand as an opaque positive byte value and
constructs `RuntimeMemoryPlan` only after checking both inequalities. The outer sum contains the
heap cap, not the inner terms again, so callers cannot double-count Haskell-resident state beside
that cap. `Prodbox.Capacity.Config.runtimeMemoryPlanForProfile` resolves the named runtime profile,
rejects duplicate or unknown profile identifiers, and converts the matching
`WorkloadResourceProfile.resources.limit.memory_mib` value to exact bytes as the plan's container
limit. There is no independently authored runtime cgroup ceiling that can drift from the Kubernetes
envelope.

`RuntimeMemory.runtimeMemoryRtsArguments` renders the validated heap cap as the exact argv suffix
`+RTS -M<bytes> -RTS`. `ChartPlatform.valuesForGateway` places that suffix in generated gateway
values, and the gateway Deployment appends it to the union runtime image's arguments. The chart
default contains only an empty argument list; no heap value lives in Cabal, Docker, or Helm
defaults. The heap cap remains deliberately smaller than the cgroup limit because GHC non-heap
memory, linked libraries, thread stacks, kernel-accounted memory, and admitted subprocesses require
explicit headroom.

Every process enumerates its live state, pending intents, queue entries, decoded request scratch,
managed-client pools, native runtime reserve, and any permitted child-process peak. The validator
rejects an unbounded term, missing deadline, zero capacity, or concurrency declaration without a
simultaneous-peak proof. A serialized maximum is valid only for a lane that is actually serialized;
it cannot be reused as evidence for concurrent lanes.

Gateway state/transport bounds remain owned by
[Distributed Gateway Architecture §3.2](./distributed_gateway_architecture.md#32-event-plane-source-of-truth).
Lifecycle-control-plane state, outbox, actor, and queue bounds remain owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Each component
has its own calculation and envelope. A shared execution lane or admission queue is not a
substitute for physical scheduling isolation between Gateway Runtime, Lifecycle Authority,
Bootstrap Broker, and Target Secret Agent.

Static validation ends at the rendered plan. A typed high-water threshold is a pure comparison
input, not evidence that the process stayed below it. Live stability combines a run-wide absorbing
failure fold with a consecutive-success window. At minimum the observer records restart/OOM and
memory high-water evidence. The service-capacity extension in §2E is equally mandatory: a process
that stays below its memory ceiling while being continuously CPU-throttled or queue-saturated has
violated its runtime contract.

## 2E. CPU, Service-Rate, Queue, and Deadline Proof

For each execution lane, the authored plan declares:

```haskell
-- Example: target shape for a pure service-capacity plan.
data ServiceDemand = ServiceDemand
  { arrivalRate :: Positive RequestsPerSecond
  , burstSize :: Positive RequestCount
  , cpuPerRequest :: Positive CpuTime
  , serviceTime :: Positive Duration
  , queueCapacity :: Positive RequestCount
  , latencyBudget :: Positive Duration
  , headroom :: Positive Ratio
  }
```

The exact validated representation may differ, but it must prove all of these propositions:

```text
steady_arrival_rate < measured_service_rate * (1 - headroom)

burst_drain_time
+ maximum_admitted_queue_wait
+ credential_refresh_budget
+ external_io_budget
+ read_back_budget
+ response_budget
<= end_to_end_latency_budget

maximum_live_queue_bytes <= memory_plan.queue_reserve
```

The service rate is established from production-composition measurement under the same binary,
workload mix, resource requests/limits, and background rates as the deployed component. It is not
inferred from requested millicores. The authored CPU request reserves scheduler capacity; a hard
CPU limit contains demand but can introduce CFS throttling and therefore does not prove latency.

That throttling acknowledgment and the Guaranteed-QoS mandate below are reconciled explicitly, by
operator decision (2026-07-12): Guaranteed QoS is retained — the answer to CFS-throttling risk is
never CPU-limit removal. Honesty comes from measured certification instead: an authored CPU value
under a hard cap must be certified against the committed measured profile for its workload (§2F).
Equality `request == limit` remains valid; zero-headroom authoring without certification is the
defect. A `GuaranteedEnvelope`/`mkGuaranteedEnvelope` witness (Sprint `1.68`) makes `request == limit`
a constructor invariant for the workloads that must be Guaranteed, so a workload silently authored
`Burstable` (the gateway's `256 req / 512 limit` memory) is no longer representable. The 2026-07-25
live counterexample — the gateway pinned at its 750m limit, ~93% cgroup throttle — is exactly this
class: a zero-headroom CPU envelope that passed every static check yet throttled at runtime, and the
recorder gate of §2F is what prevents its bug-inflated demand from ever being certified.

Every execution lane has a bounded queue and an explicit saturation result. Admission rejects
immediately when the lane cannot meet the caller's monotonic absolute deadline. Queue wait,
credential refresh, external I/O, read-back, and response serialization consume that one deadline;
no nested timeout restarts it. Retry consumes remaining budget and cannot convert saturation into
an unbounded waiter.

Resource isolation is physical as well as algebraic. Gateway mesh/DNS, lifecycle authority and
recovery, bootstrap, target-secret delivery, and provider workers have independent Deployments,
Guaranteed-QoS envelopes, queues, ServiceAccounts, and metrics. Background heartbeat demand cannot
consume lifecycle admission capacity, and a slow provider worker cannot block constant-time health
or target-secret read-back.

The AWS projection preserves those lanes as distinct EKS Service transports for Broker, Gateway
diagnostics, Target Secret Agent, and Provider Worker; retained Authority traffic remains on its
independent home transport. The pre-mutation topology validator rejects a missing/duplicate role or
shared Service. Fault evidence is therefore evaluated per lane: gateway saturation/loss cannot
consume target or Authority admission, and EKS replacement must refresh the target/provider clients
without changing the retained Authority envelope.

The runtime observation is a flat exhaustive fold over:

- restarts, termination reasons, OOM, and memory working set;
- CPU usage and CFS throttled periods/time;
- queue occupancy, queue wait, saturation refusals, and reserved-lane starvation;
- service time and end-to-end p50/p95/p99 latency;
- deadline misses, cancellation overruns, and work continuing after caller cancellation;
- managed-session refresh failures; and
- missing, malformed, or unreachable required observations.

Restart, OOM, failure-threshold memory or CPU breach, repeated deadline breach, lane starvation,
and unobservable required evidence are absorbing for a deployment qualification run. Warning
evidence resets the consecutive-success window. A replacement Pod or later quiet sample cannot
erase absorbing evidence. Only an explicitly planned rollout may reset the success window, never
the run-wide record.

A topology split cannot claim causal readiness closure merely by adding resources. The named
counterexample profile preserves one topology-normalized total CPU/memory/ephemeral/persistence
budget and identical load/fault schedule; the replacement may repartition that budget across
Gateway, Authority, Broker, and Agent but may not increase it. Qualification also runs a distinct
production profile whose per-role envelopes satisfy the service-demand inequalities above. Both
the normalized mapping and rendered production envelopes are evidence.

The previous restart/OOM/memory-only stability surface is therefore an incomplete compatibility
projection. It cannot qualify the redesigned control plane until CPU, service-rate, queue, deadline,
and latency evidence is present. Qualification uses composition, load, and chaos tests described by
[Unit Testing Policy](./unit_testing_policy.md) and the current-revision gate in
[Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

**Landed (Sprint `1.62`, 2026-07-18).** The pure temporal-capacity algebra of this section is
`src/Prodbox/ControlPlane/Capacity.hs`: an opaque `ServiceCapacityPlan` whose smart constructor
rejects an over-committed lane with exact `Natural` cross-multiplication — utilization ρ ≥ 1
(`ServiceCapacityOverCommitted`) or ρ ≥ 1 − headroom (`ServiceCapacityInsufficientHeadroom`), where
ρ_ppm = arrival × service ÷ workers — so a tiny bounded queue cannot rescue an over-committed lane
("memory containment alone is not a service-capacity proof" is structural, not a runtime check).
Bounded admission is a pure `decide`/`evolve` FIFO `AdmissionQueue`: it rejects immediately with a
structured reason when the lane is at its rejection threshold (`RejectedSaturated` + `RetryAfter`)
or when queue-wait-plus-service cannot fit the caller's remaining monotonic budget
(`RejectedDeadlineUnmeetable`, strict boundary via `deadlineAdmission`), and a timed-out caller
cooperatively frees a queued or in-service slot. Deterministic queue simulations (saturation,
FIFO fairness, cancellation, deadline expiry, recovery) live in `test/unit/ControlPlaneCapacity.hs`.

The Sprint `2.32` gateway emitter is a concrete consumer. `EmitterActorConfig` accepts only a
single-worker `ServiceCapacityPlan`; the actor mints the one absolute deadline before queue admission,
uses that same deadline for stage, both fsync projections, publication, commit, checkpoint install,
recovery, and response, and represents overload/deadline refusal as structured `EmitterActorError`
values. Heartbeat requests may replace the one pending heartbeat in place, but ownership, recovery,
and durable peer-ack operations never coalesce. Interpreter failure leaves the exact durable phase for
recovery only when it is unsigned; every retained signed phase is normalized to the durable-stage
boundary and republishes the exact signed bytes before commit and final fsync. A retained prior-Orders
digest re-arms an interrupted migration before that replay. Failure removes target readiness until a
current-Lease recovery completes; it cannot open a second lane or mint a later deadline for the failed
transition. The old process-global
`ChildSchedule` is not a target-path capacity proof: fixed REST/frame bounds and operation-specific
deadlines contain independent capability lanes, while the actor's validated queue exclusively owns
emitter transitions. The emitter's resident memory is bounded the same way its admission is: the
retained unacknowledged suffix is a hidden-constructor `BoundedUnackedSuffix` whose only growth
operation fails closed at a hard ceiling (the durable `retained_assertion_capacity`), so an
over-retention state is structurally unrepresentable rather than merely rejected — the same
"one value, one proof, unrepresentable over-commit" discipline this doctrine applies to CPU/RAM/storage,
extended to the emitter's retained-assertion chain. A stalled checkpoint signer re-drives its exact
compaction rather than letting the chain grow, closing the retained-assertion memory-leak class.

## 2F. Measured Resource Profiles

Empirical CPU/runtime coefficients used by the pure workload derivation are certified against
**measured demand**, not trusted on authorship. The committed calibration artifact is one per profile id,
living at `dhall/capacity/measured/<profile>.dhall`. Every field is a `Natural` (ratios are
parts-per-million), so certification stays inside the same all-Natural comparison algebra as §2:

- identity and provenance: `profile_id`, `recorded_at`, `hot_path_digest`
- sampling evidence: `sample_window_seconds`, `sample_count`
- CPU demand: `cpu_p95_milli`, `cpu_p99_milli`, `throttled_periods_ppm`
- memory demand: `rss_high_water_mib`, `heap_high_water_bytes`
- backend latency: `object_store_op_p99_millis`

**Certification rules.** A pure reader/validator wired into `prodbox dev check` fails the canonical
quality gate when a calibration is stale, unhealthy, provenance-mismatched, or would derive an
insufficient envelope:

- the derived CPU value is below measured `cpu_p99_milli` × 4/3 headroom;
- `throttled_periods_ppm` exceeds 20000 while any CPU cap is authored; or
- the measured memory high-water × 4/3 exceeds the authored memory limit.

**Staleness.** A profile whose `hot_path_digest` no longer matches the hot-path source, or whose
`recorded_at` is older than 30 days, fails certification. The remedy the failure names is
re-recording the profile from a fresh qualifying run — never hand-editing the committed artifact.

**One-sided comparisons.** A measured improvement never fails certification. It updates a calibrated
input; the pure derivation, rather than a person editing an envelope, determines whether the output
changes.

**Recorder gate.** A profile artifact is written only by the recorder, and only from a healthy
run: the run-wide absorbing failure fold of §2D–§2E clean, a steady window of at least thirty
minutes, and at least 300 samples. An unhealthy run or a short window refuses to record.
The supported live surface is
`prodbox test integration gateway-pods --record-profile`. It samples cumulative cgroup-v2 CPU/CFS
counters by interval (so sampling jitter cannot bias CPU), cgroup memory, GHC live-heap telemetry,
and the gateway's bounded rolling p99 of real encrypted continuity-store operations. A timestamp
regression, counter reset/Pod replacement, unavailable RTS telemetry, incomplete sample, or any
absorbed runtime-stability failure refuses the write. The final Dhall file is written by same-directory
temporary-file rename only after the complete gate succeeds.

**Bootstrap rule.** The certification check activates for a profile id when the first profile for
that id is committed. Until the first committed gateway profile lands, the interim authored
gateway envelope (750m, `request == limit`, Guaranteed QoS retained) is recorded as
uncertified-until-first-profile — an explicitly tracked interim value, not a certified one.

This is the honest ceiling: **memory sufficiency-(c) is already structural** (`RuntimeMemoryPlan`),
while **CPU sufficiency-(c) is not closed** by any static proof — it flips from `uncertified` to
enforced (`authored_cpu >= ceil(p99 x 4/3)` and throttle `<= 20000 ppm`) only when a **healthy** run
commits the first profile. A gateway thrashing at 93% throttle is an *unhealthy* run, so it can never
write a profile, so its bug-inflated demand can never be certified in; certifying against raw current
demand is explicitly refused. Sprint `1.68` adds the sibling **over-commitment compile gate** (a
`dev check` that fails the build if `defaultResourcePlan` over-commits) — an orthogonal (a)/(b)
structural proof, not a demand-(c) certification.

Implementation is owned by Sprints `1.65` and `5.21`; status lives in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

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
an exhaustive two-arm external observation and is fail-closed under the
[Lifecycle Reconciliation Soundness invariant](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary):
"I could not read the price" is never silently "the price is fine, deploy anyway."

```haskell
-- Example: spot observation keeps unobservability explicit
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
[lifecycle_reconciliation_doctrine § 3.1 Soundness invariant](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
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
  ([cluster_federation_doctrine.md § 3–§4](./cluster_federation_doctrine.md#3-parent-custody-of-encrypted-child-recovery-material)).
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
[lifecycle_reconciliation_doctrine § 3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
managed-resource-registry discipline wholesale. A desired scaled shape is a typed resource with a
flat exhaustive observation and a closed observe/decide/enact/read-back program:

- **`observe → diff → enact → re-observe`, idempotent.** The autoscaler computes the desired
  node/workload set (pure, from `Budget` + `ScalingPolicy` + observed load), diffs the live set,
  enacts the delta, re-observes; crash recovery is "run the reconciler again."
- **`Unreachable → refuse` is total.** Every observation — spot price (§4), region quota (§5), a
  sealed-Vault downstream cluster's capacity (§6) — is three-valued, and "cannot observe" refuses.
  Scaling **up** on unobservable capacity and scaling **down** past an unobservable floor are both
  forbidden.
- **Plan / Apply** ([pure_fp_standards § Plan / Apply](./pure_fp_standards.md#8-plan--apply)): the
  desired-shape diff is a pure `Plan` value, `--dry-run` renders it without touching AWS or the
  cluster, and `apply` is the only effectful arm.

This is the data-oriented "make illegal authored states unrepresentable" answer, not a global
scaling state machine: the budget lemmas (§2) forbid authored over-commit at typecheck, the
resource-governor lemmas (§2A–§2C) forbid missing pod envelopes and over-reserved clusters, the
runtime plan and observations (§2D–§2E) bound memory and service demand and detect implementation breach,
the measured profiles (§2F) certify authored Guaranteed-QoS envelopes against recorded demand,
the substrate index (§3) forbids illegal elasticity, and the fail-closed gates (§4–§6) forbid
acting on unobserved capacity.

## Intent Ownership

This SSoT co-owns prodbox resource-scaling, resource-governance, and capacity-placement doctrine.

- **Owned statement**: prodbox is its own autoscaler and resource governor; over-committed authored
  host, RKE2, namespace, pod-envelope, cluster, and region plans are made unrepresentable — the
  host/cluster/workload nesting by the opaque proof-carrying `AllocatedResourcePlan` (Sprint `1.68`: a
  non-saturating budget draw; namespace quotas derived from workload draws; `cluster <= host` re-proved
  at reconcile against the observed host), and region plans by the `fitsWithin` budget lemmas; missing
  cpu/memory/ephemeral-storage envelopes are unrepresentable;
  enumerated runtime consumers must fit separate validated memory and service-capacity
  decompositions and remain healthy under external observation; every execution lane has a bounded
  queue, one absolute deadline, and measured headroom; illegal elasticity is unrepresentable by the substrate-indexed
  `ScalingPolicy`; and every scaling or capacity-observation gate is `Unreachable -> refuse`.
- **Linked dependents** (the modules Sprints 1.51 / 1.55 / 1.68 / 1.69 / 1.70 / 3.22 / 3.27 / 3.28 /
  3.29 / 4.34 / 4.36 / 4.41 / 4.52 / 7.27 implement this in):
  `dhall/capacity/Schema.dhall` and `src/Prodbox/Capacity/Config.hs` (the shared `Budget` /
  `fitsWithin` algebra, the raw `ResourcePlan` decode surface, and the
  non-saturating `resourceVectorSubtractChecked`),
  `src/Prodbox/Capacity/Allocation.hs` (the opaque `AllocatedResourcePlan` proof, `compileResourcePlan`,
  the hidden-constructor `HostCapacity`/`ClusterBudget`/`WorkloadAllocation`/`CertifiedWorkload`, the
  `GuaranteedEnvelope`/`WorkloadQoS` witness, and the observed-host `compileResourcePlanAgainstObserved`),
  `src/Prodbox/Capacity/Render.hs` (the single ResourceQuota, LimitRange, quantity, and runtime-vector
  projection owner),
  `src/Prodbox/Capacity/Render.hs` (the one shared `ResourceQuota`/`LimitRange`/runtime-vector renderer),
  `src/Prodbox/Capacity/Placement.hs` (the substrate `renderedNamespace` resolver, `planNamespaceQuota`,
  and `WorkloadConcurrency`), `src/Prodbox/Capacity/ObservedHost.hs` (the dual-device observed-host root),
  `src/Prodbox/Settings.hs` (`DeploymentSection` scaling fields, the binary-sibling `capacity`
  block, and the `validatedAllocatedPlan` decode-gate proof carried on `ValidatedSettings`), `src/Prodbox/Substrate.hs`
  (`ScalingPolicy`, `ScalingPolicyBySubstrate`, and substrate validation),
  `src/Prodbox/Capacity/Storage.hs` (storage-capacity drawdown, ML storage totals, and
  region-quota preflight refusal fold),
  `src/Prodbox/Scaling/Autoscaler.hs` (pure trusted-placement, capacity-check, and
  gateway-leader-preserving action planner),
  `src/Prodbox/Aws.hs` (`QuotaSpec` / `ensureServiceQuota` / `applyAwsCheckQuotas` region-quota
  preflight), `src/Prodbox/AwsEnvironment.hs` (credential-region projection),
  `src/Prodbox/Lifecycle/ResidueStatus.hs` (the pre-cutover three-valued observation adapter the
  spot/quota gates mirror), `src/Prodbox/Lifecycle/ResourceRegistry.hs` (the callback-era registry
  adapter whose retirement is tracked in the
  [legacy deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)), the capacity and admission modules owned by
  [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md),
  `src/Prodbox/Gateway/Bounds.hs` (the gateway-specific bounded memory projection), and `src/Prodbox/Gateway/Types.hs`
  (`Disposition` — leadership the scaler must not perturb).

## Cross-References

- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) — managed-resource
  registry, exact keyed observations, closed desired-absence programs, and unobservable refusal
- [Cluster Federation Doctrine](./cluster_federation_doctrine.md) — trust tree (rule t), fail-closed
  unseal cascade
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md) — `node_count` = mesh
  peers, bounded gateway memory consumers, and the leadership set scaling must not perturb
- [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md) — point-in-time dependency
  readiness versus time-windowed runtime stability
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) — independently
  resourced components, bounded lanes, admission, and absolute deadlines
- [Unit Testing Policy](./unit_testing_policy.md) — pure capacity folds plus composition, load,
  chaos, and deployment-qualification tests
- [Pure FP Standards](./pure_fp_standards.md) — type-index "illegal states unrepresentable" + Plan/Apply
- [Envoy Gateway Edge Doctrine § 8](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine)
  — the per-component availability notes this typed model supersedes
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md) — chart-side consumption of the
  resource-profile registry and the no-uncapped-container render contract
- [Tiered Storage Capacity Doctrine](./tiered_storage_capacity_doctrine.md) · [Cluster Topology Doctrine](./cluster_topology_doctrine.md) · [Engineering Doctrine Index](./README.md) · [Documentation Standards](../documentation_standards.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md) (status; sprints 1.51 / 3.22 / 4.34 / 4.41 / 5.13 / 7.27) · [substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- Umbrella: `/home/matthewnowak/amoebius/.../cluster_lifecycle_doctrine.md § 8`; mirrored-in-kind
  vocabulary from `~/hostbootstrap resource_budgeting.md` and `~/jitML dhall/project/Schema.dhall`
