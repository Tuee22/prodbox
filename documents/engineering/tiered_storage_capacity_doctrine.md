# Tiered Storage Capacity Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, documents/engineering/pulsar_topic_lifecycle_doctrine.md, documents/engineering/resource_scaling_doctrine.md
**Generated sections**: none

> **Purpose**: Single Source of Truth for *how much* durable data prodbox may hold — a finite-budget capacity DSL in which storing more bytes than declared capacity, naming a sizeless durable claim, or calling a sink "unlimited" without an autoscaling witness are all Dhall typecheck failures.

## What this owns

[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) owns **where** durable
bytes live (`.data/` retained root, `.test-data/` test root, the `manual`
no-provisioner StorageClass, deterministic PVC↔PV rebinding, the MinIO `prodbox-state`
bucket) and the rule that clusters are cattle while storage is land. This doctrine owns
the orthogonal axis: **how much** may be stored, expressed as a closed, self-validating
capacity DSL where over-quota is unrepresentable.

The capacity DSL is the prodbox specialization — a proven single-node instance — of the
umbrella storage-capacity question amoebius records as open in
`amoebius/notes.txt:3` ("no way to represent keeping more storage than you have room for;
unbounded MinIO only possible if there are autoscaling"). It mirrors, **in kind and with no
code dependency**, jitML's durable-state budget vocabulary
(`jitML/dhall/project/Schema.dhall` `Budget` / `storageFitsWithin`) and hostbootstrap's
per-substrate disk cordon (`hostbootstrap` `Core.dhall` `KindNode.storage`); the schema
itself is a **scheduled** code artifact, `dhall/capacity/Schema.dhall` with the Haskell
mirror `src/Prodbox/Capacity/Config.hs`, exactly as jitML pairs `Schema.dhall` with
`JitML.Project.Config`. This document describes facets and shows teaching fragments; it is
not the schema SSoT.

## Rule r — a finite budget with no `Infinite` constructor

A declared capacity is a **hard ceiling**, and every durable claim carries a size. Two
facts are made structurally unrepresentable:

1. **Sizeless durable claims.** A store entry's byte size is a mandatory field, so a
   claim without a declared size is a Dhall typecheck error (missing field) — never a
   silent "unbounded by omission".
2. **Over-quota topologies.** The sum of declared store sizes must fit the declared
   storage budget; a `Budget` has no `Infinite` arm to escape the sum.

The teaching fragment mirrors jitML's `Budget` + `storageFitsWithin` + `assert`:

```dhall
-- Example: the durable-state budget vocabulary has NO Infinite arm
let Budget = { cpu : Natural, memory : Natural, storage : Natural }

let StoreEntry =
      { logicalName  : Text
      , physicalName : Text
      , quotaBytes   : Natural   -- mandatory: a sizeless claim fails to typecheck
      , retention    : RetentionPolicy
      }

let totalQuota =
      \(stores : List StoreEntry) ->
        sumNat (mapNat StoreEntry (\(e : StoreEntry) -> e.quotaBytes) stores)

let storageFitsWithin =
      \(b : Budget) ->
      \(stores : List StoreEntry) ->
        lessThanEqual (totalQuota stores) b.storage

-- the generated capacity.dhall inlines the data and this lemma, so typechecking
-- the file IS its validation:
in  assert : storageFitsWithin config.budget config.stores === True
```

`RetentionPolicy` is the same closed union prodbox shares with jitML — `KeepAll | LastN |
MaxAgeSeconds | MaxBytes | LastNWithinAge` — owned by
[pulsar_topic_lifecycle_doctrine.md](./pulsar_topic_lifecycle_doctrine.md); this doctrine
consumes it only as the per-store draw-down policy, never redefines it.

## The unbounded-sink witness — "unlimited only when it can autoscale"

MinIO is an unlimited sink **only when backed by its own autoscaling strategy**. The DSL
encodes this so an unbounded capacity is *unconstructible without a witness that only an
autoscaling policy can mint*. Bounded is the default; unbounded requires positive evidence.

```haskell
-- Example: capacity is a concrete ceiling unless an autoscaling policy witnesses otherwise
newtype StorageBytes = StorageBytes Natural            -- typed newtype smart constructor

-- Only Prodbox.Scaling can construct a ScalingWitness (its constructor is not exported);
-- an operator cannot forge one in the capacity layer.
newtype ScalingWitness = ScalingWitness ScalingPolicyId

data Capacity
  = Bounded   !StorageBytes     -- a finite byte ceiling (rule r)
  | Autoscaled !ScalingWitness  -- unbounded, but ONLY with a policy witness present
```

Because `ScalingWitness` has no capacity-layer constructor, `Autoscaled` cannot be written
without a declared `ScalingPolicy`; a "just call it unlimited" claim is not
representable. In Dhall the witness is the closed, exhaustive-`merge` reference to a
declared scaling policy — the same **undeclared-is-unnameable** device jitML uses for
`StoreId` (`jitML/dhall/project/Schema.dhall`): an `Autoscaled` sink that names a policy
outside the declared set has no `merge` arm and fails to typecheck. The `ScalingPolicy`
type and the policies themselves are owned by
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md); this doctrine only requires
that its witness be present before capacity may drop its finite ceiling.

## Rule o — cloud storage is finite because of the region service quota

Even an `Autoscaled` sink on the AWS substrate is never truly infinite: it is bounded by
the AWS **region service quota** (quotas, not credits), and that ceiling is checked on
**every** AWS deploy. The check reuses the existing quota surface — the region is always the
credential region:

```haskell
-- File: src/Prodbox/Aws.hs
data QuotaSpec = QuotaSpec
  { quotaDisplayName :: Text
  , quotaServiceCode :: Text
  , quotaCode        :: Text
  , quotaTargetValue :: Double
  }
```

`applyAwsCheckQuotas` folds `ensureServiceQuota` over `fullQuotaSpecs` (EBS vCPU, VPC,
subnet, EIP, security-group, hosted-zone limits) before the substrate is provisioned. The
storage-capacity reading of that gate is simple: the region quota is the *real* ceiling on
the "unlimited" cloud sink — an autoscaled MinIO on EBS scales only until the region's EBS /
EC2 quota is reached, so `Autoscaled` on AWS means "finite at the region quota," not
"infinite." The per-deploy quota-gate **mechanism** (when it runs, how a shortfall refuses
or requests) is owned by [resource_scaling_doctrine.md](./resource_scaling_doctrine.md);
this doctrine records only that the gate is what makes the cloud sink honestly finite.

## Tiered offload draws down the same finite budget

Tiered storage is not free headroom. When a Pulsar topic offloads its aged segments to
MinIO, those bytes land in the **same** `prodbox-state` object-store that Pulumi
checkpoints and the Vault-Transit-enveloped in-force config already occupy
([storage_lifecycle_doctrine.md §1](./storage_lifecycle_doctrine.md), Model-B envelopes).
Offload therefore draws down the one finite prodbox-state storage budget declared under
rule r — a topic's `MaxBytes` / `MaxAgeSeconds` retention plus its offload target are
summed into `storageFitsWithin` alongside every other store, so "offload to MinIO to make
room" cannot silently exceed the declared object-store ceiling. The topic-segment offload
schedule and retention semantics are owned by
[pulsar_topic_lifecycle_doctrine.md](./pulsar_topic_lifecycle_doctrine.md); this doctrine
owns only that its bytes count against the shared budget.

## Rule k — every ML engine carries an explicit JIT + model-cache budget

Every ML-engine binary carries an **explicit, non-optional** storage budget for **both**
JIT-compiled artifacts **and** its model cache, on **both** the host and the cluster. An ML
engine without such a budget is unrepresentable.

```haskell
-- Example: two mandatory byte ceilings, on both host and cluster — a budget-less
-- engine is unconstructible (no field is Maybe)
data MlEngineStorageBudget = MlEngineStorageBudget
  { jitArtifactCacheBytes :: !StorageBytes   -- strengthened: EXPLICIT (jitML leaves this implicit)
  , modelCacheBytes       :: !StorageBytes    -- mirrors jitML Budget.storage (model cache)
  }

data MlEngineCapacity = MlEngineCapacity
  { hostBudget    :: !MlEngineStorageBudget   -- mirrors hostbootstrap host disk cordon
  , clusterBudget :: !MlEngineStorageBudget   -- mirrors hostbootstrap KindNode.storage
  }
```

This mirrors jitML's mandatory `Budget.storage` (which sizes the model cache) and
hostbootstrap's `KindNode.storage` / per-substrate disk cordon (host **and** cluster),
**strengthened** so the JIT-artifact-cache byte budget is explicit too — jitML leaves that
draw implicit inside its single `storage` number. This is forward-looking: prodbox has no
ML engine today. The type is imported from jitML alongside the compute-worker model owned by
[cluster_topology_doctrine.md](./cluster_topology_doctrine.md) ("mirror-now,
refactor-onto-hostbootstrap-later"); both engine caches count against the finite storage
budget of rule r.

## Rule s — no durable-destruction primitive

The capacity DSL exposes **no** `.dhall` value that denotes "destroy these bytes." Lowering
a declared ceiling is a **verified migration**, never an in-place truncation:

- **Grow** is representable in place — a larger `quotaBytes` strictly contains the old
  bytes.
- **Shrink** is `create-new → verified-migrate → retire-old`. The value the operator writes
  denotes the *target smaller ceiling*; the reconciler provisions a correctly-sized store,
  copies the live bytes, verifies the copy, and only then retires the old store. No `.dhall`
  value ever denotes "discard these bytes," so destruction stays unrepresentable even as the
  effective ceiling drops. A shrink that cannot verify its copy leaves both stores intact
  and fails loud.

This aligns with amoebius's storage doctrine §7 (deleting durable data is forbidden under
normal operation) and §8 (shrink-as-verified-migration). The retained roots those bytes
live on — `.data/` and the `.test-data/` test root — and their operator-only deletion are
owned by [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md); this doctrine
owns only the DSL-level guarantee that no capacity value can request destruction.

## The honest static-vs-runtime boundary

Dhall is pure, total, and IO-free. It makes **over-allocation** (rule r), the
**sizeless durable claim** (rule r), the **witness-free unbounded sink** (unbounded-sink
section), and **naming an undeclared store or scaling policy** unrepresentable, and it keeps
the declared set internally consistent within budget. It **cannot** observe whether a
bucket, topic, or EBS volume actually exists in the live object-store / broker at this
instant, and it cannot read the live region quota. Those stay **runtime reconciler edges**:
the per-deploy region-quota gate (rule o, `ensureServiceQuota`) and the autoscaling policy's
actual scaling action are runtime facts, modelled the prodbox way as explicit typed
projections that carry "cannot observe" as a first-class value — the three-state
`Prodbox.Lifecycle.ResidueStatus` (`ResidueAbsent | ResiduePresent | ResidueUnreachable`)
and the log-reconciled gateway `Disposition`, per
[pure_fp_standards.md](./pure_fp_standards.md) — never collapsed into a passing boolean.

## Status

This capacity DSL is **scheduled, not yet implemented**. The tiered-storage budget DSL, the
MinIO autoscaling-sink witness, the per-deploy region-quota gate binding, and the ML
JIT/model-cache budget land in **Phase 4 Sprint 4.36**
([phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md));
the config surface (`prodbox config generate` emission of `dhall/capacity/Schema.dhall` and
the binary-sibling capacity block) lands in **Phase 1 Sprint 1.51**
([phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md)).
Sprint status is authoritative only in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md); this document describes the
target surface, not the schedule.

## Intent Ownership

This SSoT owns the durable-storage **capacity** contract: finite budgets with no `Infinite`
constructor, sizeless-claim and over-quota unrepresentability, the autoscaling-witness gate
on unbounded sinks, the region-quota ceiling on cloud storage, the shared-budget draw-down
of tiered offload, the mandatory ML JIT + model-cache budget, and the absence of any
durable-destruction primitive.

- **Owned statement**: storing more durable data than declared capacity — or declaring a
  sizeless claim, an unwitnessed unbounded sink, or a destruction of durable bytes — is
  unrepresentable in the prodbox capacity DSL.
- **Linked dependents** (scheduled implementers):
  `dhall/capacity/Schema.dhall` (the closed, self-validating capacity vocabulary),
  `src/Prodbox/Capacity/Config.hs` (the `FromDhall` mirror + `storageFitsWithin` +
  schema-parity constant), `src/Prodbox/Capacity/UnboundedSink.hs` (the `Capacity` /
  `ScalingWitness` types), `src/Prodbox/Capacity/MlEngineBudget.hs` (the `MlEngineCapacity`
  types), and `src/Prodbox/Aws.hs` (the reused `QuotaSpec` / `ensureServiceQuota` /
  `applyAwsCheckQuotas` region-quota surface).

## Cross-References

- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — where durable bytes
  live (`.data/`, `.test-data/`, retained PVs); this doctrine owns how much.
- [pulsar_topic_lifecycle_doctrine.md](./pulsar_topic_lifecycle_doctrine.md) — topic
  retention and MinIO offload schedule; its offloaded bytes draw down this budget.
- [resource_scaling_doctrine.md](./resource_scaling_doctrine.md) — the `ScalingPolicy` that
  mints the unbounded-sink witness and the per-deploy quota-gate mechanism.
- [cluster_topology_doctrine.md](./cluster_topology_doctrine.md) — the compute-worker / ML
  engine model whose storage budget rule k makes mandatory.
- [pure_fp_standards.md](./pure_fp_standards.md) — closed ADTs, typed newtype smart
  constructors, and the "cannot observe" projection pattern this doctrine applies.
- [DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
  [DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md)
  — scheduling.
- Sibling doctrine mirrored in kind (no code dependency):
  `jitML/documents/engineering/durable_state_dsl.md`,
  `hostbootstrap/documents/engineering/resource_budgeting.md`, and the umbrella this feeds,
  `amoebius/documents/engineering/storage_lifecycle_doctrine.md`.
