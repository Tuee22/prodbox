# Resource Governance

**Status**: Authoritative source
**Supersedes**: Pre-refactor resource scaling and tiered-storage capacity doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; measurement and enforcement remain phase-owned implementation

> **Purpose**: Define finite admission, actual runtime sufficiency, storage budgets and scoped scaling.

## Typed finite plans

Every runtime/worker/subprocess surface has explicit CPU, memory, ephemeral-disk, durable-storage and concurrency bounds. Decode validated ADTs/smart constructors before rendering; reject missing/zero limits, arithmetic underflow/overflow and impossible placement. Requests do not exceed limits; any Guaranteed-QoS policy derives equal request/limit fields from one admitted envelope.

Keep declared admission separate from observed external capacity and from measured demand. A static plan can rule out arithmetic overcommit; it cannot prove an arbitrary program's peak RSS, parser/FFI allocation, child process demand or service rate. Dhall validation and Haskell types cannot replace runtime evidence.

## Hierarchy and projection

Account for host OS/container overhead, kind node/control overhead, management services, application services, storage and transient worker concurrency exactly once. Cluster allocation fits observed host/container limits; workload draw fits allocatable capacity with reserves. Namespace quota/LimitRange and Pod requests/limits derive from that same plan, not independent editable numbers.

Every durable volume's declared capacity drives its PV/PVC, placement and quota. Separate ephemeral scratch from durable data and actually distinct device capacity. Static EBS is AZ-bound and pre-created; do not silently switch to dynamic provisioning when an adapter fails. [Storage](storage.md)

The management steady-state plus allowed simultaneous secret/admin workers must fit and actually schedule before handling secrets/AWS. Phase 1 establishes enforcement, Phase 2 measures real bootstrap concurrency, Phase 4 includes elevated workers, and Phase 6 adds the application projection. A planned reserve is not current available headroom until rendered and observed.

## Runtime sufficiency and boundedness

Fund parser/body/frame limits, immutable/captured input, queues, concurrent requests, replay windows, process/runtime overhead and child-process trees. Bound work at ingress before accumulation and bound concurrency in the owning interpreter. An execution timeout without byte/memory limits is not a memory budget.

Service capacity relates admitted concurrency/arrival/load, CPU service demand, queue dwell and deadline composition. Establish deadlines from monotonic elapsed time within an invocation; retain exact operation ownership across restart. Expired time does not prove an earlier process/worker cannot act. Do not assert sub-millisecond cross-node time trust from API resolution or NTP status alone.

Generate runtime heap settings and Kubernetes limits from one validated profile; no independent hand-entered heap ceiling. Observe actual cgroup high-water, OOM/restart counters, saturation/throughput and scratch/durable use under the declared load and fault schedule. Preserve causal old/new comparisons when fixing a reproduced resource failure; do not call an increased envelope proof of the same-budget repair.

## Storage and elasticity

No topic/store is implicitly infinite. Retention, partitions, offload and copies consume finite byte capacity with independently observed quotas. An autoscaling claim requires a real supported expansion mechanism, finite maximum and explicit spend/quota admission, not the word unlimited.

Prodbox computes desired supported node/workload changes through registered lifecycle operations. Preserve implemented scaling/resource-governance objectives identified by the inventory; do not make generic future ML/cache scenarios mandatory service prerequisites. Local fixed capacity and EKS elasticity are explicit target policy differences, not hidden HPA fallback.

AWS desired footprint fits declared region quotas and spend policy before provisioning. Quota reads/requests and price-sensitive choices have explicit source/time/scope; a stale sample cannot authorize arbitrary future spend. [AWS](aws_resources.md#quotas-spend-and-operational-evidence)

## Evidence and failure

Read resource requests, actual allocatable capacity, Pod scheduling and worker completion from the running target. Compare with declared profiles; distinguish unavailable metrics from a passing plan. Test enforcement by an actually refused over-budget case and a deliberately disabled/missing-limit negative control where safe.

Preserve the original failure and eligible cleanup results. OOM, failed scheduling or missing observation cannot be converted into successful teardown. [Testing](testing.md) owns real case evidence; pure properties and targeted mutations guard the arithmetic/admission decisions.

## Existing scaling foundations and accepted scope

Current source contains fixed/elastic policies in `Prodbox.Substrate`, Spot eligibility in `Prodbox.Scaling.Spot`, pure `autoscalerPlan` in `Prodbox.Scaling.Autoscaler`, and a capacity-scaled resource facade. These are real planning foundations, not evidence of a production autoscaler loop. They are separate from speculative ML/autoscaling prose.

Retain fixed local replica selection and capacity admission in Phase 6. Local Elastic is rejected rather than silently rendered at its minimum as if a controller existed. Phase 8 retains explicit bounded AWS workload/node counts and Spot price/quota planning, validating provider reads and the actual selected count on reconcile. A policy named Elastic cannot imply an autonomous scaling controller that is not running; present its bounded-planning scope clearly or version its representation accordingly. Live Spot/autonomous scaling is advertised only if a separately declared real acceptance proves its actual behavior and cleanup, not from a pure constructor.

Phase 9 retains useful trust-tree/leader-preservation constraints with real federation/HA evidence, then integrates or removes unwired helper/facade residue under L21. No earlier phase depends on a future federation controller to validate its single-cluster scope. A06-07 and A08-06 own the real fixed/bounded reconciliation cases.

## Implemented through Phase 1

The kind controller envelope (64 MiB heap, 768 MiB container limit) is compiled against the observed host before any effect; under a one-CPU affinity the real command refused with `milli_cpu 1000 2000` and changed nothing. Measured during a real reconcile: slice memory peak about 248.5 MiB of the 768 MiB limit and 35 of 88 tasks. Real Pods with explicit memory limits complete under the limit and are `OOMKilled` over it, and a namespace `ResourceQuota` admits a Pod within it, refuses one over it and accounts the admitted request. The funded simultaneous secret-worker envelope is Phase 2. Evidence: [Phase 1 validation](../../DEVELOPMENT_PLAN/evidence/phase_01_validation.md).
