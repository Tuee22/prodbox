# Shared Host Resource Protocol Analysis

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Evaluate the proposed finite-resource execution-authority protocol for adoption by
> prodbox and recommend the changes, rollout, and evidence required before adoption.

> **Review posture.** This document analyzes
> [Finite Resource Execution Authority Protocol](documents/engineering/shared_host_resource_protocol.md).
> It does not establish architecture, implementation status, or conformance. Current work and
> resumption status remain solely in
> [Development Plan -> Resume Here](DEVELOPMENT_PLAN/README.md#resume-here).

## 1. Executive conclusion

The proposal addresses a real gap and its central approach makes sense for prodbox: a
machine-global layer should admit a complete workload into a finite host cell, retain
kernel-backed custody of the claimed identities, apply and read back the required walls, and only
then issue a capability that a closed launcher can consume. That is a good outer fence for several
cooperating projects that otherwise cannot see one another's Kubernetes schedulers, VMs, build
processes, or accelerator use.

The proposal is not ready to become authoritative prodbox doctrine or a frozen cross-project ABI.
It currently omits prodbox from its adoption model, conflicts with existing lifecycle and retained
state ownership, promises a per-cell lifetime lock that its concrete ABI does not contain, gives
POSIX participants enough directory permission to replace supposedly permanent lock objects, and
contains several Haskell API and recovery paths that cannot express the promised behavior. Its
unbounded tombstones also conflict with prodbox's bounded-state doctrine, while several Darwin,
Windows, Linux, and GPU mechanism claims need narrower classifications or more evidence.

The recommended disposition is therefore:

1. **Accept the architectural direction.** Preserve the physical-domain model, permanent lock
   namespace, prepared-before-effect journal, read-back gate, linear execution capability, and
   quarantine-on-ambiguity rules.
2. **Keep the proposal `Reference only` while it is revised.** It should not be indexed as accepted
   prodbox doctrine or described as an implemented guarantee.
3. **Define prodbox composition before implementation.** The shared-host layer must be an outer
   local-host execution fence, not a second Lifecycle Authority or cleanup owner.
4. **Repair the protocol at the model level.** Add cell ownership, safe namespace permissions,
   bounded idempotency, a type-correct recovery-only path, and a compiling reference API before
   freezing canonical bytes.
5. **Roll out Linux first.** Begin with a deliberately narrow, explicitly qualified Linux profile;
   leave Darwin, Windows, MIG, and MPS rows unsupported or weaker until each advertised mechanism
   has matching live evidence.

| Question | Assessment |
|----------|------------|
| Does the problem apply to prodbox? | Yes. Current prodbox capacity proof is project- and scheduler-local, not cross-project machine-global ownership. |
| Is the conceptual chain useful? | Yes. `Requirement -> Admitted -> Lease -> AppliedEnvelope -> ExecutionAuthority -> ResourceReceipt` is the right general shape. |
| Can the proposal be adopted unchanged? | No. There are protocol-safety, ownership, boundedness, and API blockers. |
| Should all three operating systems block initial value? | No. Unsupported profiles can refuse authority; Linux-first adoption is the credible path. |
| Final recommendation | Revise substantially, prototype and qualify the narrow profile, then promote through the Development Plan. |

## 2. Review basis and decision boundary

The review compares the proposal with these existing authorities:

- [Resource Scaling Doctrine](documents/engineering/resource_scaling_doctrine.md#2a-resource-requirements-are-mandatory-and-capped),
  including the request-based cluster allocation proof and observed-host reconciliation.
- [Lifecycle Control-Plane Architecture](documents/engineering/lifecycle_control_plane_architecture.md#1-boundary-ownership),
  including the retained local Lifecycle Authority, bounded idempotency, and ordinary recovery
  profile.
- [Lifecycle Reconciliation Doctrine](documents/engineering/lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation),
  including exact managed-resource identity and the durable cleanup graph.
- [Pure FP Standards](documents/engineering/pure_fp_standards.md#3-state-decisions-and-evolution),
  including external-state observations, total decisions, indexed programs, Plan/Apply, and one
  absolute deadline.
- [Retained Storage Lifecycle Doctrine](documents/engineering/storage_lifecycle_doctrine.md#7-the-single-retained-operator-host-root)
  and [Config Doctrine](documents/engineering/config_doctrine.md#compiled-protocol-constants-versus-operator-supplied-deployment-values).
- [Host Platform Doctrine](documents/engineering/host_platform_doctrine.md#4-the-lift-everything-docker-inward-is-os-agnostic-linux),
  [Prerequisite Doctrine](documents/engineering/prerequisite_doctrine.md#4a-prerequisitepreparation-boundary),
  and [Streaming Doctrine](documents/engineering/streaming_doctrine.md#6a-a-narrated-skip-is-not-a-narrated-absence-sprint-476).
- [Documentation Standards](documents/documentation_standards.md) and
  [Development Plan Standards](DEVELOPMENT_PLAN/development_plan_standards.md).

The protocol should be judged against its stated scope. It can govern cooperating project binaries
and the closed launch paths they own; advisory locks and Haskell types cannot constrain an
administrator, a same-privilege program that deliberately bypasses the protocol, or a remote EKS
node with no participating agent. This honest boundary is a strength. The analysis does not require
the protocol to solve hostile multi-tenancy, but it does require it to prevent accidental or stale
double allocation among conforming participants and to keep privileged workloads from corrupting
the coordination mechanism.

## 3. The gap this proposal correctly identifies

Prodbox already has a substantial resource model. It derives finite CPU, memory, ephemeral-storage,
and durable-storage envelopes; proves nested plan inequalities; renders Kubernetes requests,
limits, quotas, and host reservations; and rechecks the plan against an observed host. The current
implementation is visible in
[`Prodbox.Capacity.Types`](src/Prodbox/Capacity/Types.hs),
[`Prodbox.Capacity.Placement`](src/Prodbox/Capacity/Placement.hs), and
[`Prodbox.Capacity.HostProbe`](src/Prodbox/Capacity/HostProbe.hs).

That proof does not reserve a slice of the physical machine against another repository. In
particular:

- Kubernetes scheduler requests coordinate pods within one cluster, not a sibling project's host
  compiler, VM, local cluster, or GPU process.
- Container limits are containment maxima, not host-global reservations.
- A CLI lifetime is too short to own a long-lived RKE2 cluster, VM, daemon, or model service.
- A GPU UUID selected by a runtime does not by itself prove exclusive use, device-memory capacity,
  or a hardware partition.
- Lima and WSL2 introduce a guest boundary, but a guest-local lock cannot arbitrate the physical
  host with native participants.

A host-global admission and custody protocol is therefore a sensible layer. The proposal is
especially useful because it distinguishes three facts that are often conflated:

1. the requirement fits a catalog cell;
2. the cell and its physical identities are still owned by this operation; and
3. the operating-system or hardware mechanism actually enforces the requested strength.

The proposal is right that no one of those facts implies the other two.

## 4. Strong ideas to preserve

### 4.1 Physical domains and alias-aware conflict

Locks should name stable physical domains, not scalar quantities. The proposal correctly treats a
whole GPU as conflicting with all of its MIG descendants, a MIG GPU Instance as the memory and
compute isolation boundary, and Apple unified GPU memory as an alias of host memory rather than an
invented second pool. It also correctly states that a VM does not manufacture accelerator
isolation.

This graph is a better foundation than a flat record containing numbers such as `gpu_count = 1`.
Exact device and partition identity is necessary both for admission and for post-crash recovery.

### 4.2 Permanent kernel lock identity

One permanent epoch object across protocol revisions is a strong design. It prevents old and new
binaries from silently using parallel `/v1` and `/v2` namespaces. Nonblocking acquisition,
canonical ordering, no lock upgrades, all-or-nothing rollback, and lifetime custody in a project
anchor are also appropriate.

The no-TTL rule is particularly sound: process exit or reboot may release a kernel lock, but that
only makes recovery eligible. It does not prove that a persistent VM, cgroup, mount, quota, service,
or device context is gone.

### 4.3 Prepared-before-effect recovery

The `Prepared -> Applied -> Running -> Releasing -> Retired` model follows the right durability
shape. Recording the intended identities before the first wall mutation, then re-observing before
settling the next state, gives recovery something exact to inspect after a lost response or crash.
Quarantining an ambiguous cell is safer than timeout stealing, PID-only signaling, or deleting a
lock file.

### 4.4 Honest enforcement strength

The separation among admission, ceiling, exclusivity, hardware partitioning, and reactive
enforcement should remain. The proposal appropriately refuses to describe an Apple working-set
recommendation, a sparse-disk maximum, ordinary GPU time sharing, or an MPS percentage as a hard
physical reservation.

This explicit strength relation fits prodbox's existing distinction between arithmetic admission,
containment, measurement certification, and runtime observation.

### 4.5 Closed execution authority

The rank-2 region, linear capability, hidden constructors, no unrestricted `LiftIO`, and closed
launcher algebra are all directionally right. Prodbox already uses opaque capability and indexed
program patterns; an outer capability that can only launch the workload jointly branded with its
derived requirement is a natural extension.

### 4.6 Validation posture

The proposed pure vectors, property tests, compile-fail cases, crash schedules, replaced-root
tests, same-key retry tests, and live cross-project contention cases are the right evidence classes.
The test list is ambitious, but that is appropriate for a protocol whose failure mode is concurrent
double allocation or unsafe recovery.

## 5. Findings that must be resolved before adoption

The following table separates protocol blockers from issues that can be handled by staging a
narrower supported profile.

| Priority | Finding | Why it matters | Required disposition |
|----------|---------|----------------|----------------------|
| Blocker | Prodbox is absent from the scope and adoption tables | The document assigns work to other repositories and foreign phases, so it defines no prodbox composition or rollout | Add a prodbox adoption contract and schedule it only through this repository's plan |
| Blocker | The concrete ABI has no per-cell lifetime lock | Two scopes can select the same scalar cell after the short admission lock is released | Add an immutable cell lock and `CellLockKey`, or radically narrow what a cell can mean |
| Blocker | POSIX directory mode `0770` permits lock-object replacement | A participant can create old-inode/new-inode split brain | Make layout/lock namespaces non-writable to participants and isolate mutable journals |
| Blocker | Anchor recovery overlaps Lifecycle Authority ownership | A second process could stop or settle resources owned by the registered lifecycle graph | Define a strict ownership split and bootstrap/recovery handshake |
| Blocker | The Haskell sketch cannot express several promised outcomes | Same-key receipt replay, runtime cell selection, recovery across epochs, and existential mechanisms are not type-correct as shown | Land a compiling reference model before ABI freeze |
| High | Current prodbox capacity proof is not the proposal's complete-maxima proof | Reusing `AllocatedResourcePlan` directly would overstate the guarantee | Add an explicit checked prodbox-to-host requirement compiler |
| High | Claim and topology tombstones grow without a bound | Permanent safety metadata eventually exhausts retained storage | Use generations, high-water floors, bounded windows, and saturation refusal |
| High | The fixed host root and `layout.cbor` conflict with current retention/config doctrine | The proposal silently creates a second durable root and policy authority | Classify and govern this external shared-host state explicitly |
| High | Several substrate claims are stronger than their mechanisms | A type could advertise containment or recovery that the platform did not supply | Narrow/refuse rows until mechanism-specific live evidence exists |
| High | ABI ownership is circular | Four independent implementations cannot derive one exact byte contract from four separately owned copies | Name a release authority and versioned canonical conformance artifact |
| Medium | Plan/Apply, prerequisites, deadlines, narration, and decommission are unspecified | The protocol would not compose with the supported prodbox command/evidence contract | Define these surfaces as part of adoption, not interpreter folklore |

### 5.1 The proposal does not yet adopt prodbox

The proposal's purpose, demand derivation,
[doctrine comparison](documents/engineering/shared_host_resource_protocol.md#project-doctrine-comparison),
[adoption boundaries](documents/engineering/shared_host_resource_protocol.md#project-adoption-boundaries),
and validation gate list name `amoebius`, `infernix`, `jitML`, and `hostbootstrap`, but not prodbox.
It also assigns work to phases that do not exist in prodbox. The only current execution queue is
[Development Plan -> Resume Here](DEVELOPMENT_PLAN/README.md#resume-here), and it currently contains
Sprints `2.75` and `6.5`.

Before adoption, the proposal needs a prodbox row that identifies:

- the local operator host as the shared-host scope;
- the retained RKE2 control plane and its pre-RKE2 host anchor;
- the transformation from prodbox's current resource plan into a host-cell requirement;
- the treatment of Lima and WSL2 host/guest boundaries;
- the treatment of long-lived baseline work versus transient validation, build, reconcile, and
  cleanup work;
- the exact local GPU observer and device-exposure path;
- the fact that EKS nodes are out of scope unless separately deployed node agents participate; and
- the command, recovery, test-isolation, cascade, and total-decommission boundaries.

The proposal also fails current documentation conventions: header metadata is hidden in a
`details` block instead of following the title, it carries the retired `Referenced by` field, its
claimed engineering-index backlink does not exist, and target claims point at foreign phase IDs
rather than the sole local status ledger. These are easy to repair, but they reflect the deeper
problem that the document has not yet been integrated into this repository's authority graph.

The immediate document correction should move the required metadata below the title, set status to
`Reference only`, remove `Referenced by`, add a document-wide `> **Target.**` declaration pointing
only to Resume Here, and remove foreign phase/sprint status. The engineering index should add a
normal forward link only if and when the proposal's SSoT boundaries are accepted.

If the proposal is accepted, the same change that promotes it must add a Development Plan sprint,
update the system-component inventory, assign migration/removal ownership, and mark deployment
qualification pending. The proposal itself must not become a competing status ledger.

### 5.2 The host anchor must not become a second lifecycle authority

The proposal's
[daemonless host protocol](documents/engineering/shared_host_resource_protocol.md#daemonless-host-protocol)
requires a project-owned anchor to acquire the cell before creating a VM, cluster, or daemon and to
retain the locks after the CLI exits. That is correct for lock custody. The problem is that its
generic recovery and catalog-mutation paths may also stop or settle cgroups, VMs, mounts, services,
quotas, and device use.

Prodbox already assigns desired mutation, exact resource identity, recovery decisions, and cleanup
to its registered lifecycle graph. The mandatory Lifecycle Authority runs inside retained local
RKE2, and the ordinary teardown profile explicitly exists to recover that authority without
creating a second host-direct authority. A generic host anchor that independently destroys the
same objects would violate this ownership.

There is also a bootstrap cycle: the anchor must hold a cell before RKE2 starts, but the in-RKE2
Lifecycle Authority cannot authorize the host action needed to start itself.

The revised design should use this split:

| Owner | May own | Must not own |
|-------|---------|--------------|
| Shared-host anchor | Host lock handles, cell/physical-domain custody, root envelope identity, exact wall read-back, a narrow local claim journal, quarantine, and mechanism-local fail-stop/emptying of the exact descendants bound to its wall | Desired managed-resource state, provider effects, generic cleanup decisions, lifecycle convergence, or a second cleanup DAG |
| Lifecycle Authority | Operation registration, desired state, exact managed-resource registry, cleanup graph, provider permits, recovery decisions, and terminal convergence | Raw possession or transfer of the anchor's kernel lock handles |
| Prodbox adapter | Pure demand projection, parent-incarnation and child-ticket binding, closed launch plans, observations, and typed translation between the two authorities | Caller-selected raw resources, arbitrary cleanup callbacks, or an unfenced host-direct fallback |
| Operator/installer | Installation and reviewed mutation of the finite catalog and trusted namespace | Routine per-operation allocation or silent repair of ambiguous effects |

The pre-RKE2 anchor must be an explicit installed component, such as a narrowly privileged system
service, with its own identity, restart ordering, upgrade rule, and total-decommission owner.
"Daemonless" should mean no shared scheduling daemon; it cannot mean that no persistent service is
required.

The retained parent claim should not be one claim per Lifecycle Authority operation. Version one
should use fixed adapter identities such as `ProjectId = prodbox` and
`ParentScopeId = prodbox.retained-home-plane`. Its `ClaimKey` should bind the project, parent scope,
installed-machine identity, and an anchor-journal-allocated parent incarnation. CLI retries attach
to that same incarnation; they cannot mint another parent reservation.

Pre-Authority bootstrap uses an anchor-owned, bounded `BootstrapAttemptId` whose closed workload
can start only the retained bootstrap/recovery profile. Once the Lifecycle Authority is healthy,
its `OperationId`s bind checked child tickets and receipts inside the already held parent rather
than replacing the parent claim. The bootstrap identity must not become a generic host-direct
mutation permit. Local delete retires the parent only after exact envelope emptiness and durable
settlement; a later reconcile obtains the next journal-allocated incarnation rather than reusing a
spent claim key.

Recovery should then follow an explicit handshake:

1. the anchor reacquires or re-observes only the local envelope needed to make the retained recovery
   profile available;
2. when needed to preserve the wall, the anchor may fail-stop and empty only the exact descendants
   bound to its own cgroup, VM, Job, or equivalent enforcement domain;
3. the Lifecycle Authority resumes the registered operation and remains the owner of desired-state
   and managed-resource cleanup decisions;
4. mechanism-local emptiness is joined with lifecycle terminal evidence and never narrated as
   lifecycle convergence by itself;
5. the anchor releases the cell only after the parent has no live child tickets, exact envelope
   emptiness is read back, and retirement is durably settled; and
6. either side quarantines on an unobservable or identity-mismatched state rather than taking over
   the other's authority.

This preserves the proposal's lock-custody benefit without creating a second cleanup owner.

### 5.3 Prodbox's current capacity proof cannot be reused directly

The proposal's [guarantee](documents/engineering/shared_host_resource_protocol.md#the-guarantee)
requires the complete peak requirement to fit one cell and says admitted maxima do not oversubscribe
host RAM, storage, or device memory. Prodbox's current proof deliberately uses the sum of Kubernetes
scheduler **requests** for cluster placement while retaining finite limits as containment maxima.
The distinction is explicit in
[Resource Scaling Doctrine section 2B](documents/engineering/resource_scaling_doctrine.md#2b-host-rke2-cluster-namespace-and-pod-lemmas)
and implemented by `profileRequestDraw` in
[`Prodbox.Capacity.Placement`](src/Prodbox/Capacity/Placement.hs).

Other mismatches are material:

- `config generate` currently sizes CPU and memory against the whole observed host, not an offered
  outer cell.
- `ResourceVector` uses unbounded `Natural` values and MiB for several axes, whereas the proposed
  ABI requires bounded integers, canonical base units, and checked conversion.
- `WorkloadConcurrency` is currently only `Steady` or a named `ExclusiveWindow`; it is not the
  proposed complete phase-DAG peak calculus.
- The current host-substrate GPU observation is the presence of `nvidia-smi`, not proof of an exact
  CUDA device, MIG partition, service generation, or enforcement mechanism.
- Current topology can say `manages_all_local_devices`; that must not be reinterpreted as exact
  device authority.

Adoption therefore needs a new pure adapter, conceptually
`compileProdboxHostRequirement`, that consumes already validated prodbox demand facts and returns a
checked protocol requirement. It should:

- convert `Natural` MiB and millicpu values into bounded ABI units with explicit overflow refusal;
- distinguish scheduler request, containment maximum, persistent baseline, transient maximum, and
  exclusive identities;
- include RKE2, kubelet, container-runtime, VM, cleanup, evidence-retention, and recovery overhead
  rather than counting only chart containers;
- charge every potentially concurrent local operation; and
- reject any axis or strength that the current model cannot derive.

The operating system plus the protocol's admission observer and anchor overhead belong to the
catalog's machine-global host reserve, outside every project cell. They must be charged exactly once
there, not again inside the prodbox requirement.

For CPU, RAM, and ephemeral storage, a conservative version-one requirement should use this shape:

```text
RKE2/kubelet/container-runtime margin
+ sum(limit draws for Steady profiles)
+ sum(maximum limit draw within each ExclusiveWindow)
+ maximum(closed host-transient alternatives)
```

Replica and surge terms use checked multiplication. Durable storage is a separately summed
persistent baseline and is not reduced by transient `ExclusiveWindow` maxima. MiB-to-byte and
`Natural`-to-fixed-width conversion must refuse overflow; the ABI path cannot reuse unchecked
addition or scaling helpers.

There is a current coexistence ambiguity to resolve before freezing this equation. The comment in
[`Prodbox.Capacity.Placement`](src/Prodbox/Capacity/Placement.hs) says workloads sharing one named
window coexist while different windows are mutually exclusive, but the implementation takes a
component-wise maximum within one label and later sums the different labels. The host-protocol
compiler must not guess which meaning is intended; current doctrine, code, and tests need one exact
semantics first.

A paired `compileResourcePlanAgainstCell` should validate and brand the internal prodbox plan
against the assigned cell, not silently truncate or resize it and not treat the catalog host reserve
as part of the cell. Participating-mode `config generate` must author against the offered cell
rather than the entire observed host. The first implementation should not claim a precise phase-DAG
theorem until that calculus exists.

For version one, long-lived RKE2 should use exactly one `'ParticipatingProjects` parent scope whose
cell covers every local prodbox lane for the parent lifetime. That deliberately trades idle-headroom
utilization for the proposal's strongest one-parent rule. Additional independently reserving parent
scopes should require a later operator-reviewed catalog mutation with disjoint or jointly charged
capacity.

### 5.4 The promised cell lock is absent

The proposal says per-cell locks carry lifetime ownership in its
[daemonless host protocol](documents/engineering/shared_host_resource_protocol.md#daemonless-host-protocol).
Its fixed object inventory, acquisition types, and Haskell sketch contain only epoch, admission,
parent-scope, and physical-resource locks. There is no cell lock object or `CellLockKey`.

That omission is a safety defect, not a naming issue. Two logical cells may share the same host,
CPU topology, memory domain, or quota-backed storage domain while offering disjoint scalar
quantities. Parent locks serialize only within one registered parent scope, and the global
admission lock is released while work runs. Without a cell lock, two project scopes can select the
same logical scalar cell and then retain no object that represents exclusive ownership of it.

The preferred correction is to add:

- an immutable `locks/cells/<digest>.lock` installed with each catalog cell;
- an opaque `CellLockKey` derived only from the validated layout;
- exclusive acquisition under the admission lock in a fixed order relative to ancestor and leaf
  physical locks;
- lifetime retention by the anchor;
- prepared-record, recovery, and tombstone rules for the cell object; and
- contention, partial-acquisition, replacement, retirement, and cross-project tests.

The alternative is to define every cell as an independently exclusive physical leaf. That would
eliminate many CPU/RAM/quota and bounded-sharing layouts the proposal otherwise intends to support,
so adding the cell lock is the more coherent fix.

MPS needs a parallel correction. A bounded MPS lane requires explicit service-generation,
partition, and client-slot identities and locks; a vague later reference to a "service lock" is
not enough.

### 5.5 Namespace permissions and the privilege boundary are unsafe as written

On POSIX systems, directory write permission controls rename and unlink of entries. A
`root:finite-resource-authority` directory with mode `0770` lets any group participant rename,
unlink, or replace an allegedly permanent lock entry. One anchor can remain locked on the old inode
while a later participant opens the replacement, producing two lock namespaces despite leaf
identity checks.

The coordination layout needs separate trust zones:

- root-owned, participant-non-writable root, catalog, and lock directories;
- precreated immutable lock objects with the minimum access needed to acquire locks, not to replace
  or rewrite them;
- narrowly writable per-project or per-scope journal directories, or a small privileged journal
  writer;
- validation of every traversed path component from retained directory handles, not only the leaf;
- a trusted anchor for expected root and file identities; and
- equivalent Windows DACL rules that deny deletion, replacement, and cross-project journal access.

The proposal must also name its trusted computing base. Applying delegated cgroups, device access
controls, quotas, Job Objects, VM walls, and some GPU changes requires privileges that ordinary
workloads must not retain. A credible design uses dedicated anchor identities or narrow privileged
helpers, root-owned upper walls, per-project ACLs, and credential/group/capability dropping before
launch. The governed workload must not be able to mutate the catalog, protocol journal, lock
namespace, or its own upper wall.

### 5.6 The Haskell API needs a compiling reference model

The type-level direction is good, but the displayed
[Haskell capability shape](documents/engineering/shared_host_resource_protocol.md#haskell-capability-shape)
has several semantic and type-shape holes:

1. `PhysicalDomain` is indexed by a `DomainKind` but not by a fresh identity for the exact observed
   device. Two CUDA devices of the same kind therefore do not acquire distinct type identities.
   The model needs separate generative domain identity and kind indices.
2. `withDerivedWorkload` permits the caller to choose `scope` without supplying the closed-world
   witness required for `WholeHost`. Use distinct constructors or an explicit scope witness.
3. `withAdmitted` yields one existential cell, while live acquisition later re-evaluates a set of
   eligible alternatives and chooses a free one. The pure value should represent the ordered,
   nonempty alternatives and the exact deterministic selection rule consumed by the interpreter.
4. `withExecutionSession` returns `Either ProtocolFailure result`, but same-key retry may need to
   return `AlreadyActive` or a retained prior receipt. It cannot manufacture an arbitrary
   caller-selected `result`. The return type needs an explicit closed session outcome.
5. `applyEnvelope` quantifies over a fresh mechanism bundle while `finish` returns a receipt whose
   type mentions that bundle. The bundle cannot escape the continuation as shown. Use a
   continuation-based terminal fold or an existentially erased, canonically encoded receipt.
6. Current-epoch `LockKey` values cannot express recovery of an old recorded bundle after reboot or
   topology change, while an inert tombstone explicitly cannot mint current execution authority.
   Add a recovery-only key/capability derived from an authenticated durable record. It may acquire
   old lock objects for reconciliation but can never authorize launch.
7. Changing the epoch digest does not revoke an already minted in-memory authority. Every service
   or topology mutation must take the relevant epoch/service locks, and long-lived leases need
   health monitoring that stops and quarantines work on identity drift.

Prodbox's pure-functional rules add another important distinction: GADT indices may enforce legal
program sequencing, but they should not stand alone as timeless proof that external locks, durable
records, or walls remain true. The reference model should expose flat exhaustive
`LockObservation`, `AllocationRecordObservation`, and `EnvelopeObservation` values, feed them
through total pure `decide`/`evolve` functions, and mint short-lived opaque capabilities only after
the exact successful read-back. This follows
[Pure FP Standards section 3.3](documents/engineering/pure_fp_standards.md#33-external-authority-uses-decide-and-evolve)
while retaining a GADT for program-owned phase legality.

No semantic ABI should freeze until these declarations compile, the eliminators compose on the
happy path, and the negative paths typecheck into explicit outcomes.

### 5.7 Idempotency and topology history are not bounded

The proposal's
[claim idempotency and recovery](documents/engineering/shared_host_resource_protocol.md#claim-idempotency-and-recovery)
permits an unbounded sequence of intentional reruns, assigns each one a new claim key, and requires
every completed key to remain permanently spent. Discarding receipt detail while keeping a
tombstone does not make the number of tombstones finite. Repeated catalog changes can likewise
append retired lock objects forever.

Prodbox already documents a suitable bounded pattern in
[Lifecycle Control-Plane Architecture section 5.2](documents/engineering/lifecycle_control_plane_architecture.md#52-one-cas-aggregate-and-immutable-blobs):

- fixed client or parent slots;
- generation-scoped monotonic sequences;
- durable high-water and compacted floors;
- a configured bounded idempotency window;
- bounded retained terminal projections or immutable receipt references;
- saturation refusal before capacity is exceeded; and
- an expired/spent result for an old sequence that can never become a fresh operation.

The host protocol should adopt the same shape. Returning the original detailed receipt forever is
not necessary for safety; after the retention window, returning `ClaimExpired` or `ClaimSpent`
while preserving an irreversible floor is sufficient to prevent replay as new work.

Permanent cell/resource lock identities also need a finite catalog capacity. The installer can
preallocate a bounded namespace or the catalog can have an explicit maximum number of append-only
slots and refuse mutation when exhausted. Calling the installed set finite while permitting
unbounded append is not an operational bound.

### 5.8 The durable root and catalog need explicit authority

The fixed coordination root in the
[daemonless host protocol](documents/engineering/shared_host_resource_protocol.md#daemonless-host-protocol)
contains a deployment-varying catalog, allocation records, receipts, and tombstones. Prodbox
currently says the operator host retains one durable root, `.data/`, and that ordinary cluster
teardown preserves it. The proposal therefore introduces a second durable host-state surface unless
the doctrine is amended.

Putting a cross-project lock root under the prodbox repository would undermine the proposal's host
identity, so the coherent solution is to classify it explicitly as machine-global,
operator-installed shared-host infrastructure outside prodbox's managed retained root. That
requires corresponding updates to the one-root wording and an exact lifecycle:

- installation and initial catalog publication;
- ordinary prodbox reconcile and local delete;
- cascade and test isolation;
- prodbox uninstall while sibling projects remain;
- protocol upgrade and catalog mutation;
- retirement of one project or parent scope; and
- machine-wide total decommission after every participant and effect is settled.

Prodbox must not delete this shared root during ordinary teardown.

`layout.cbor` is also operator-varying policy, not merely a protocol constant. The revised design
must distinguish:

- compiled ABI facts such as tags, units, digest domains, path grammar, and state-transition rules;
- operator-supplied cell policy such as capacities, allowlists, parent scopes, reserves, and
  mechanism selection; and
- observed host identities and effective mechanism state.

The shared-host catalog may be its own external authority, but prodbox must treat it as a validated
prerequisite/observation whose exact revision and digest are bound into the Lifecycle Authority
operation. It must not silently become a competing source for prodbox's in-force application
configuration. The catalog mutator, authentication policy, review process, and rollback/recovery
rules must be named.

### 5.9 Substrate claims need a staged and narrower posture

The following issues in the proposed
[substrate profiles](documents/engineering/shared_host_resource_protocol.md#substrate-profiles) do
not all have to block a useful Linux implementation. They do block freezing the advertised
cross-platform strengths unless the affected profile refuses authority.

| Area | Concern | Required posture |
|------|---------|------------------|
| Linux cgroup topology | `rke2-server.service` and kubelet-created pods are not automatically one descendant cgroup; daemon-mediated Docker/Kubernetes/VM work may escape the caller tree | Prove the exact runtime-created cgroup/domain topology, or apply and read back a multi-domain envelope that covers service, pods, runtime, and charged overhead |
| Linux memory | `memory.max` is a strong kernel limit but can be exceeded transiently and does not automatically cover HugeTLB, pinned/device memory, or every relevant pool | Define enforcement slack, reserve/health policy, relevant controllers, and empty-state counters; do not claim instantaneous physical-RAM reservation |
| Linux exclusive CPU | Cpuset exclusivity depends on a valid partition root and effective read-back; hotplug and kernel/IRQ work narrow the claim | Read back `cpuset.cpus.exclusive.effective`, monitor invalidation, and call the guarantee scheduler exclusion among governed work unless housekeeping evidence is included |
| Darwin process tree | A descendant can call `setsid()` and leave its process group; post-crash numeric PID/PGID recovery is not an atomic pinned handle | Native Darwin advertises admission/detection or narrowly reactive live supervision; crash recovery quarantines. Use an accepted VM for hard containment |
| Darwin durability | Ordinary `fsync` is not the strongest power-loss flush exposed by Apple | Specify `F_FULLFSYNC`/barrier behavior and crash model before claiming power-loss durability |
| Windows process tree | Suspended creation is not the same as assignment before all allocation; breakaway, nested jobs, WMI/SCM brokers, and handle custody matter | Prefer creation-time job-list assignment, forbid breakaway, qualify broker paths, verify nesting, and test kill-on-close/read-back behavior |
| Windows memory | Job memory limits concern committed virtual memory, not a proof of bounded physical RAM | Model commit charge as a distinct resource and never let it satisfy a physical-host-memory demand |
| CUDA device exposure | An environment variable containing a UUID selects a device but is not access control | Enforce exact device nodes/partitions through the runtime and OS device-control mechanism, then read back the effective exposure |
| MIG | Support and isolation depend on exact NVIDIA platform and GPU capability | Advertise only on supported Linux systems with live GI/CI identity and ancestor-conflict evidence |
| MPS | Service generation, slots, static SM partitions, client caps, and multi-user isolation are incomplete | Add exact service/partition/slot locks; retain `BoundedShared`; qualify only supported platforms and hardware |
| POSIX descriptor inheritance | `O_CLOEXEC` closes on exec, not immediately after fork | Use child-side close actions or an equivalent safe spawn path and test anchor death in the fork/exec window |
| Live epoch changes | A service restart or remap can invalidate the mechanism while a typed authority remains live | Fence all reconfiguration through epoch/service locks and monitor long-lived leases for identity drift |

Primary mechanism references supporting these constraints include
[Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html),
[Apple `setsid`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsid.2.html),
[Apple `fsync`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html),
[NVIDIA MIG deployment considerations](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/deployment-considerations.html),
[NVIDIA MPS guidance](https://docs.nvidia.com/deploy/mps/latest/when-to-use-mps.html),
[Microsoft Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
[Windows process-creation attributes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute),
and
[Windows Job memory limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information).

### 5.10 ABI governance is circular as written

The proposal's
[interoperability freeze](documents/engineering/shared_host_resource_protocol.md#interoperability-freeze)
reasonably avoids a common runtime library or central scheduler. Requiring every repository to own
its Haskell declarations independently is also compatible with fault isolation. It does not,
however, identify which artifact decides the exact canonical bytes when implementations disagree.
Four separately pinned copies and a non-normative Markdown document do not form one semantic SSoT.

The protocol needs a named release authority and a versioned, language-neutral conformance bundle
containing:

- assigned protocol and project identifiers;
- exact integer widths, unit conversions, field tags, enum tags, ordering, and path grammar;
- digest algorithms and domain-separation strings;
- canonical CBOR positive and negative bytes plus expected digests;
- state-transition, lock-order, alias, fit, strength, and recovery vectors;
- a release identity and review/signing procedure; and
- a compatibility rule that refuses anything except the exact supported release.

Sharing that immutable test artifact does not require a runtime dependency or a shared Haskell
package. Each repository can still reimplement the protocol and prove that its independently built
binary reproduces the release corpus.

The proposal also says implementations must never depend on `hostbootstrap-core`, while current
prodbox doctrine describes a "mirror now, refactor onto hostbootstrap later" posture. That is a
real architecture choice and should be resolved explicitly rather than letting the two documents
quietly disagree.

### 5.11 The prodbox command and evidence contract is missing

Host-resource admission is an effectful prerequisite for many existing commands, but the proposal
does not define how it appears in prodbox's Plan/Apply, prerequisite, deadline, narration, or
cleanup contracts.

An adoption design must specify:

- read-only prerequisites for root identity, ABI compatibility, catalog validity, exact host
  inventory, required mechanisms, and anchor health;
- visible preparation actions for installation, privilege setup, catalog publication/mutation, or
  envelope repair;
- pure dry-run plans that name the intended claim and required strengths without pretending that a
  cell is currently held;
- one non-resettable absolute deadline for each finite submission, admission, status observation,
  worker, cleanup, or recovery attempt, covering its queue wait, I/O, read-back, persistence,
  retry, and response;
- separate durable operation and stage deadlines for long-running work, without applying one
  process-local deadline to the indefinite lifetime of the retained parent or RKE2 cluster;
- bounded admission/recovery queues and budgets;
- explicit outcomes for `AlreadyActive`, `ParentScopeBusy`, contention, unsupported capability,
  mechanism too weak, receipt replay, recovery, quarantine, unobservable state, clean retirement,
  and deadline exhaustion;
- narration derived from those outcomes, with no claim of clean release based only on process exit
  or lock release; and
- exact behavior during cluster reconcile, local delete, cascade, validation cleanup, reinstall,
  and total decommission.

These are part of the protocol's semantic integration, not presentation details to invent after
the ABI is frozen.

## 6. Recommended prodbox composition

The shared-host protocol should sit outside prodbox's existing capacity and lifecycle layers while
remaining subordinate to their ownership rules:

```text
observed physical operator host
  -> shared-host catalog, cell admission, locks, and applied/read-back wall
  -> pre-RKE2 prodbox anchor holding the local cell capability
  -> retained local RKE2 foundation
  -> Lifecycle Authority operation and durable cleanup graph
  -> AllocatedResourcePlan compiled against the leased cell
  -> Kubernetes/systemd/VM/device child envelopes
  -> exact terminal observation and ResourceReceipt
```

This layering gives each proof one job:

| Proof or record | Meaning in prodbox |
|-----------------|--------------------|
| Shared-host `Requirement` | Complete local-host demand projected from validated prodbox plans and operation shape |
| `Admitted` alternatives | Pure evidence that one or more catalog cells could satisfy that demand and strength |
| Live `Lease` plus applied envelope | Machine-global custody and effective outer wall for this claim |
| Parent-incarnation `ClaimKey` | Stable identity of the one retained prodbox reservation; retries attach and retirement spends it |
| Bootstrap attempt or lifecycle `OperationId` child ticket | Checked child use inside the held parent; it cannot reserve or enlarge another host cell |
| `AllocatedResourcePlan` | Internal RKE2/Kubernetes allocation proof compiled within the outer cell |
| Rendered requests/limits/quotas | Child scheduler and containment projections, not host-global authority |
| Shared-host receipt | Exact outer-envelope terminal state, joined to but not replacing lifecycle terminal evidence |

### 6.1 Proposed adapter contract

A prodbox adapter should own four transformations:

1. **Demand compilation:** validated settings, operation shape, host-lift topology, and exact device
   needs become a bounded `Requirement` or a structured refusal.
2. **Cell-relative compilation:** the selected cell becomes the physical upper bound used to
   validate and brand the internal resource plan; the catalog's machine-global host reserve remains
   outside the cell, and whole-host generation is unavailable in participating mode.
3. **Closed execution projection:** every governed subprocess, systemd unit, RKE2/kubelet cgroup,
   Lima/WSL VM, container, mount, quota, and device exposure is rendered only from authority-bound
   data.
4. **Evidence join:** the parent incarnation, bootstrap or Lifecycle Authority child ticket, anchor
   identity, layout digest, exact wall identities, lifecycle terminal projection, and resource
   receipt are checked together before success narration or parent retirement.

A compiling target should make the fixed project/scope, closed requirement, parent submission
outcomes, and existentially hidden mechanism receipt explicit. The exact final declarations belong
in code and the versioned ABI; this sketch illustrates the required shape:

```haskell
-- Example: Hypothetical prodbox adapter target; these are not current source declarations.
data ProdboxProject

prodboxProjectId :: ProjectId ProdboxProject
retainedHomeScope :: ParentScopeId ProdboxProject

data SomeProdboxRequirement where
  SomeProdboxRequirement
    :: Requirement 'ParticipatingProjects ProdboxProject workload required
    -> ClosedWorkload ProdboxProject workload required
    -> SomeProdboxRequirement

compileProdboxParentRequirement
  :: ProdboxParentInputs
  -> Either ProdboxDemandError SomeProdboxRequirement

data ParentSubmissionOutcome receipt
  = ParentAccepted ParentRef
  | ParentAttached ParentRef
  | ParentReceiptReplayed receipt
  | ParentScopeBusy ActiveClaim
  | ParentQuarantined QuarantineReceipt

data SomeResourceReceipt base where
  SomeResourceReceipt
    :: SMechanismProfile mechanisms
    -> ResourceReceipt base mechanisms
    -> SomeResourceReceipt base
```

A separate `ChildGrantOutcome`, keyed by `BootstrapAttemptId` or Lifecycle Authority `OperationId`,
must describe checked child admission inside `ParentRef`. This closes the arbitrary-callback-result
and escaping-mechanism holes without making each operation a separately reserving parent.

The adapter must never treat current `HostSubstrate` GPU detection or
`manages_all_local_devices` as presence/ownership evidence. It needs a new exact observer and an
authority-derived device projection.

### 6.2 Recommended version-one parent and child model

Version one should expose exactly one `'ParticipatingProjects` prodbox parent scope,
`prodbox.retained-home-plane`, covering the retained local foundation and every local prodbox lane.
`WholeHost` is unavailable because foreign workstation processes are not closed by this protocol.

The anchor splits its one held offer into checked children such as:

- `Rke2Foundation`;
- `StandingRole role`;
- `TransientLane lane`; and
- `HostResidentWorker machineId`.

The sum and identities of all live children must fit the already-held offer. A validation retry or
new Lifecycle Authority `OperationId` requests a child ticket; it cannot mint another parent claim,
acquire new host locks, or grow the live bundle. A second independently reserving prodbox parent is
allowed only in a later catalog revision after an operator-reviewed proof that its capacity is
disjoint or jointly charged with the retained parent.

This version-one choice intentionally reserves the parent's maximum bundle while retained RKE2 is
live. It is less utilization-efficient than multiple dynamic parents, but it preserves the
proposal's strongest single-parent rule and makes retries, recovery, and lifecycle ownership much
clearer.

AWS provider quotas and EKS node capacity remain existing prodbox concerns. A local host lease may
bound the local Lifecycle Authority and Provider Worker that drive AWS operations; it cannot prove
resource walls on remote EKS nodes.

### 6.3 Configuration evolution while the parent is live

A new validated settings generation may replace the current generation without retiring the
parent only when its requirement and every possible child split fit the already-held offer, use no
new physical domain, and require no stronger mechanism. The adapter must recompile and rebrand the
plan against that same cell; it may not silently truncate demand.

A larger requirement, new device identity, new independently reserving scope, or stronger wall
requires an admission freeze, exact parent retirement, any required epoch/catalog mutation, and a
new anchor-journal-allocated parent incarnation. Live lock-bundle expansion remains forbidden.

### 6.4 Current implementation seams

The first implementation plan should name these existing seams rather than treating adoption as a
new isolated library:

| Concern | Current seam and required change |
|---------|----------------------------------|
| Validated demand input | [`Prodbox.Settings`](src/Prodbox/Settings.hs): `ValidatedSettings`, `validatedAllocatedPlan`, and `validateConfigWithContext` are the input boundary for the new parent-requirement compiler |
| Request-based allocation | [`Prodbox.Capacity.Placement`](src/Prodbox/Capacity/Placement.hs) and [`Prodbox.Capacity.Allocation`](src/Prodbox/Capacity/Allocation.hs): keep the existing child proof, resolve `ExclusiveWindow` semantics, and add the distinct complete-max parent projection |
| Whole-host generation | [`Prodbox.Capacity.HostProbe`](src/Prodbox/Capacity/HostProbe.hs): participating-mode generation must use a validated cell offer instead of declaring observed whole-host CPU/RAM |
| Cluster Plan/Apply | [`Prodbox.CLI.Rke2`](src/Prodbox/CLI/Rke2.hs): `buildNativeInstallExecutionPlan` and `applyNativeInstallPlan` are the insertion points for visible admission/cutover actions |
| Runtime observed-host gate | [`Prodbox.CLI.Rke2`](src/Prodbox/CLI/Rke2.hs): `ensureRke2ResourceGuardrails` currently proves the plan against the host and renders RKE2/kubelet settings; it must consume the cell-bound proof and verify the outer cgroup topology |
| Native guest lift | [`Prodbox.Host.Lift`](src/Prodbox/Host/Lift.hs): `clusterFrame` and `foldHostLift` show why Lima/WSL leasing must occur at the physical-host anchor before guest dispatch |
| Retained Authority placement | [Lifecycle Control-Plane Architecture boundary ownership](documents/engineering/lifecycle_control_plane_architecture.md#1-boundary-ownership): fixes the pre-RKE2 bootstrap and Authority handshake |
| Long-running client rule | [Pure FP Standards Plan/Apply](documents/engineering/pure_fp_standards.md#8-plan--apply): the host CLI observes a durable operation rather than staying alive as lock custodian |
| Shared-root conflict | [Retained Storage Lifecycle Doctrine section 7](documents/engineering/storage_lifecycle_doctrine.md#7-the-single-retained-operator-host-root): must explicitly classify the external coordination root |
| Raw subprocess migration | [Host Platform Doctrine section 3](documents/engineering/host_platform_doctrine.md#3-host-tools-are-a-closed-enum-resolved-to-absolute-paths--target-not-in-force): adoption must gate all governed spawn sites, not only add one wrapper |
| Compile-fail evidence | [Phase 3's recorded harness gap](DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md#validation-as-run): a real compile-fail harness must be added before the proposal's negative type claims count as evidence |
| Rollout/status | [Development Plan -> Resume Here](DEVELOPMENT_PLAN/README.md#resume-here): the only place an accepted implementation may enter the execution queue |

## 7. Recommended supported-profile sequence

### 7.1 First qualified profile

Start with a narrow Linux profile:

- local ext4 or XFS coordination root;
- root-owned immutable layout and lock namespace;
- dedicated prodbox anchor identity with minimal delegated privileges;
- cgroup v2 beneath an explicitly owned/delegated systemd hierarchy;
- an explicit lifetime cell lock;
- CPU bandwidth and RAM ceilings with exact effective read-back and documented slack;
- storage classified as admission-only until a real reserved extent/quota is installed and read
  back;
- exact RKE2/kubelet/container-runtime cgroup topology; and
- GPUs explicitly unsupported in the first qualified profile.

This is enough to prove the cross-project protocol without making three operating systems and every
accelerator mode a prerequisite for the first useful result.

### 7.2 Later profiles

- Add whole-GPU exclusive use only after exact CUDA-device observation, access enforcement, and
  empty-state evidence replace the current executable-presence and all-local-devices hints.
- Add Linux MIG only on qualifying hardware and only after whole-GPU/GI ancestor conflicts and
  exact device exposure pass live tests.
- Add MPS only after the service-generation, static-partition, client-slot, aggregate-admission,
  restart-fencing, and multi-user security model is complete. Keep it `BoundedShared`.
- Add native Darwin only at the strength its supervisor and recovery mechanics can prove; use a
  separately accepted Lima/VM envelope for hard containment.
- Add Windows after creation-time Job assignment, no-breakaway, nested-job, broker, commit-charge,
  root-DACL, and crash-recovery cases are qualified.

An unsupported row should return a typed refusal. It should never inherit a stronger conformance
label merely because the common algebra has a constructor for it.

## 8. Recommended rollout

The rollout should be entered into the Development Plan only after the proposal revision is
accepted. A safe sequence is:

1. **Correct proposal governance and ownership.** Normalize metadata, mark the document as target
   or reference, add the prodbox boundary, define the shared root and anchor, and reconcile
   lifecycle/config/storage ownership.
2. **Build a compiling pure reference model.** Repair the API, add cell/service/slot and
   recovery-only keys, bound every retained collection, and publish the exact version-one
   conformance bundle.
3. **Build fake interpreters and model tests.** Cover arithmetic, alias closure, lock ordering,
   partial rollback, state evolution, lost responses, saturation, expiry, and compile-fail cases.
   Add a real compile-fail harness rather than treating type examples as evidence.
4. **Add the prodbox adapter in shadow mode.** Compute the requirement and proposed outcome, but do
   not mint execution authority or claim safety. Compare it with current observed workloads and
   refine the conservative peak.
5. **Perform an offline existing-cluster cutover.** Do not attempt to reparent a running RKE2
   process tree. Freeze new local admission; stop RKE2; prove the service, runtime, pod cgroups,
   VMs, mounts, and host workers empty; acquire the fixed parent, cell, and domain locks; persist
   `Prepared`; create and read back the empty outer wall; install native-anchor-before-RKE2 boot
   ordering; restart RKE2 only through the anchor; and verify every RKE2, runtime, and pod PID is
   beneath the outer wall before settling `Running`. Rollback is available only before the first
   applied external effect; later failure enters recovery or quarantine.
6. **Gate the governed launch surface.** Route RKE2, systemd, VM, container, process, mount, quota,
   and device operations through the closed authority program. A repository check should reject
   bypasses.
7. **Qualify Linux composition.** Run cross-project contention, every journal crash prefix, anchor
   death, reboot, root replacement, device removal, RKE2 recovery, cascade, and test-isolation
   cases. Record Standard-P old/new topology and resource-envelope evidence.
8. **Add platform and accelerator rows independently.** Each row is promoted only with its own live
   mechanism evidence; absence of hardware means absence of that conformance claim, not a blocked
   core implementation.

Because this changes process topology, resource envelopes, persistence, recovery, and cleanup,
existing deployment qualification cannot automatically carry across the cutover.

## 9. Recommended decision matrix

These choices remove the remaining version-one ambiguity while leaving later extensions possible:

| Decision | Recommended version one | Acceptance gate |
|----------|-------------------------|-----------------|
| Proposal status | `Reference only` with an explicit target declaration | Model repairs and a Development Plan entry precede promotion |
| Scope | `'ParticipatingProjects` on the local operator host | The prodbox adapter cannot construct `WholeHost`; remote EKS nodes are excluded |
| Parent scopes | One `prodbox.retained-home-plane` parent | Any extra parent requires a later reviewed catalog revision and concurrency proof |
| Parent identity | Installed-machine identity plus anchor-allocated incarnation | Retry, reboot, retirement, and spent-key tests |
| Child identity | `BootstrapAttemptId` before Authority; `OperationId`/cleanup identity afterward | Child tickets cannot acquire or enlarge host locks |
| Authority split | Anchor owns lock/wall custody and mechanism-local fail-stop; Lifecycle Authority owns desired lifecycle and convergence | Bootstrap, anchor-crash, Authority-loss, and cleanup-handshake tests |
| Capacity proof | New complete-max parent compiler; current allocation proof remains a cell-bound child proof | Overflow, unit, reserve, and coexistence vectors agree |
| Initial platform | Native Linux CPU/RAM | Live cgroup containment, identity, pressure, and empty-state read-back |
| Storage | `AdmissionOnly` | Upgrade only after reserved-backing plus quota/extent evidence |
| GPU | Unsupported initially | Upgrade only after exact device identity, access enforcement, locking, and empty-state evidence |
| Shared root | External operator-owned machine infrastructure | Prodbox delete/cascade never removes it; machine-wide decommission is separately proven |
| ABI freeze | Deferred | Compiling model plus released canonical corpus and two independent reproductions |
| Existing-cluster adoption | Offline stop/verify/wall/restart cutover | Crash-tested cutover receipt; no live reparenting claim |
| Live configuration growth | Fit within the held offer only | Larger/stronger/new-domain changes require parent retirement and a new incarnation |

## 10. Acceptance criteria

The proposal is ready for authoritative prodbox adoption only when all cross-cutting criteria below
are satisfied. Platform-specific criteria may remain unsupported only if the corresponding profile
refuses authority.

### 10.1 Scope and ownership

- [ ] Prodbox has an explicit adoption row and exhaustive local-host scope.
- [ ] Version one exposes one fixed `'ParticipatingProjects` parent; `WholeHost` and remote-node
  authority are unconstructible.
- [ ] Covered child lanes and excluded remote substrates are named.
- [ ] The shared-host anchor, Lifecycle Authority, Provider Worker, Kubernetes, installer, and
  operator have non-overlapping responsibilities.
- [ ] The pre-RKE2 anchor's identity, privileges, boot order, restart, upgrade, rollback, and
  decommission owners are declared.
- [ ] The anchor allocates parent incarnations durably; retries attach, retirement spends the key,
  and later reconcile cannot reuse it.
- [ ] The pre-Authority path has one closed bootstrap child identity, and every ordinary child is
  bound to durable lifecycle operation and cleanup identity.
- [ ] The Lifecycle Authority durably binds the active parent incarnation before any non-bootstrap
  child mutation is admitted.
- [ ] Mechanism-local fail-stop cannot be narrated as managed-resource convergence.
- [ ] No host-protocol recovery path bypasses registered lifecycle cleanup.

### 10.2 Demand and type model

- [ ] A checked prodbox demand compiler distinguishes requests, maxima, baseline, transient peaks,
  reserves, and exact identities.
- [ ] All unit conversion and arithmetic are bounded and overflow-checked.
- [ ] `ExclusiveWindow` doctrine, comments, implementation, and vectors agree on which workloads
  coexist.
- [ ] Operating-system and protocol observer/anchor overhead is charged once in the catalog host
  reserve, outside the prodbox cell.
- [ ] Participating-mode resource plans compile against the cell rather than the whole host.
- [ ] A live settings update fits the same offer without new domains or stronger mechanisms, or it
  freezes admission and replaces the retired parent with a new incarnation.
- [ ] External lock, record, domain, and envelope states use flat exhaustive observations and total
  pure decisions.
- [ ] GADT indices enforce program legality without pretending to make mutable external facts
  timeless.
- [ ] Same-key active/replay, different-key busy, terminal receipt, and failure outcomes are
  representable without manufacturing an arbitrary callback result.
- [ ] Reboot/topology recovery has a non-launching, type-correct old-record path.
- [ ] Every finite submission, observation, execution attempt, and recovery attempt consumes one
  absolute deadline and a bounded budget; persistent work uses separate durable operation/stage
  deadlines that restart cannot extend.

### 10.3 Lock, filesystem, and privilege safety

- [ ] Every logical cell has an exclusive lifetime ownership object.
- [ ] MPS service and client-slot ownership are modeled before MPS is advertised.
- [ ] Whole-resource/partition ancestor conflicts and canonical acquisition are property-tested.
- [ ] POSIX participants cannot rename, unlink, replace, rewrite, or privately shadow catalog/lock
  objects.
- [ ] Expected root and object identities are anchored in trusted state and every path component is
  validated.
- [ ] Mutable journal access is isolated per project/scope.
- [ ] Workloads lose protocol filesystem access and wall-changing privileges before launch.
- [ ] Partial acquisition releases safely, and removed-device tombstones cannot mint execution
  authority.

### 10.4 Retention, configuration, and boundedness

- [ ] The shared root has an accepted lifecycle for install, reconcile, local delete, cascade,
  tests, reinstall, project retirement, protocol upgrade, and machine-wide decommission.
- [ ] Retained Storage Doctrine explicitly classifies the extra machine-global root.
- [ ] Every catalog field is classified as protocol-fixed, operator-supplied policy, or observed
  state.
- [ ] The exact layout revision/digest is bound to the deployment and lifecycle operation without
  becoming a competing prodbox in-force config.
- [ ] Claims, receipts, tombstones, catalog slots, and recovery work all have validated finite
  bounds plus saturation behavior.
- [ ] Old compacted identities return spent/expired and can never become fresh.

### 10.5 Command and evidence contract

- [ ] Setup, status, catalog mutation, admission, recovery, and decommission have documented
  supported prodbox surfaces or an explicitly external installer boundary.
- [ ] Prerequisite observations are read-only and preparation mutations are visible plan actions.
- [ ] Dry-run renders the complete intended plan without claiming a live lease.
- [ ] Terminal narration distinguishes busy, active, unsupported, weak, unobservable, recovering,
  quarantined, retired, and replayed-receipt outcomes.
- [ ] Success requires exact empty/absent read-back and durable receipt settlement; exit code or
  kernel lock release alone is insufficient.
- [ ] Test claims cannot collide with, corrupt, or silently reuse production state.

### 10.6 ABI, validation, and qualification

- [ ] A named release authority publishes exact versioned constants and canonical corpus bytes.
- [ ] Every repository's independent implementation reproduces the same positive and negative
  vectors without importing another repository's runtime code.
- [ ] Compile-fail cases cover illegal key, proof, brand, region, phase, and linear reuse.
- [ ] Crash tests cover every durable transition and response-loss boundary.
- [ ] Cross-project tests prove contention for a shared cell/whole device and concurrency only for
  disjoint cells/partitions.
- [ ] Anchor death, reboot, root replacement, catalog upgrade, service restart, and removed-device
  cases are exercised.
- [ ] Prodbox composition tests cover RKE2 bootstrap, Lifecycle Authority recovery, cascade, and
  validation isolation.
- [ ] Every advertised substrate/mechanism has matching live evidence; unsupported rows refuse.
- [ ] The canonical `prodbox dev check` and relevant unit/integration suites pass.
- [ ] Development Plan Standard-P qualification records the old/new topology and resource-envelope
  mapping before cutover is called complete.

## 11. Final recommendation

Proceed with the idea, but revise the proposal before adopting it.

The proposal's essential insight is correct: prodbox and sibling projects need one host-global
admission/custody layer outside their private schedulers, and execution authority should require the
intersection of complete demand, live ownership, and read-back enforcement. The permanent lock
identity, physical-domain graph, prepared journal, no-TTL recovery, honest strength types, and
closed linear launcher are worth preserving.

The current draft nevertheless crosses too many authority boundaries and leaves too many safety
claims unrepresented to serve as an ABI. The minimum next revision should add prodbox composition,
make the anchor an execution fence rather than a lifecycle owner, introduce a real cell lock,
secure the namespace, bound all retained history, reconcile the shared root/catalog with existing
doctrine, and provide a compiling recovery-capable API plus canonical version-one vectors.

After that revision, a Linux-first shadow implementation and live cross-project qualification are
reasonable. Darwin, Windows, MIG, and MPS should be promoted independently from typed refusal only
when their actual mechanisms justify the advertised strength. This path preserves the value of the
proposal without turning an attractive type sketch into a stronger guarantee than the host can
enforce.

The requested all-caps filename is intentionally retained for this review artifact. If this
analysis becomes permanent governed documentation, it should be renamed to `snake_case.md` or be
given an explicit exception to
[Documentation Standards section 2](documents/documentation_standards.md#2-naming-conventions).
