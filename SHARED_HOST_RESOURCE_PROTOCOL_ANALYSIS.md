# Shared Host Resource Protocol Analysis

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Record a critical project-specific assessment of the proposed
> [Shared Host Resource Protocol](./documents/engineering/shared_host_resource_protocol.md), including
> its strengths, its relationship to existing prodbox doctrine, the unresolved adoption boundaries,
> and the evidence required before it can govern a supported prodbox path.

## 1. Executive Summary

The Shared Host Resource Protocol is a strong proposal for conservative coordination between otherwise
independent projects on one physical machine. Its most important design choice is to keep the shared layer
small: permanent host objects, exact identities, capacity cells, lock ordering, bounded journals, progressive
assurance, and quarantine are shared, while workload meaning and lifecycle recovery remain project-local.
That is the correct general separation for prodbox. A cross-project resource protocol should not become a
second owner of RKE2, AWS, Vault, Kubernetes, provider operations, or cleanup.

The proposal is nevertheless not ready to become prodbox architecture or a prerequisite of any supported
`prodbox` command. The missing work is concentrated at the boundary where generic host admission must be
composed with prodbox's already substantial resource and lifecycle systems:

1. The proposed project-local anchor has no concrete boot, restart, failure, cgroup, IPC, or teardown
   topology for the mandatory retained RKE2 control plane.
2. The host catalog's cells and reserves are not yet joined by one proof to prodbox's operator-authored
   `capacity.resource_plan`, `AllocatedResourcePlan`, observed-host gate, Kubernetes quotas, systemd limits,
   and retained-storage budgets.
3. The recoverable cell record is not yet typed so that it can never substitute for the separate exact
   observations from Lifecycle Authority, Kubernetes, Vault, AWS, storage, and provider systems.
4. Accelerator turn leases do not yet have a mechanically closed path through Kubernetes scheduling,
   device assignment, container identity, cgroup attachment, and exact empty-state read-back.
5. The proposal has no current prodbox sprint, component-inventory row, cutover owner, formal protocol model,
   or neutral release to which its `Reference only` status can refer.

The recommended disposition is therefore:

> Retain the document as an exploratory design proposal. Do not make a supported prodbox command depend on
> it until a prodbox integration design, a neutral release and governance process, an explicit development-plan
> adoption sequence, a machine-checked protocol model, and current-revision live conformance evidence exist.

This conclusion is not a rejection of the protocol. It is a boundary judgment: the neutral core direction is
sound, while the prodbox adoption contract is not yet complete enough to preserve the guarantees the project
already makes.

## 2. Status and Scope of This Analysis

The protocol document explicitly describes target behavior and delegates implementation and qualification
status to [Development Plan → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here). This analysis likewise
makes no implementation-status claim beyond the current repository evidence it cites. It does not supersede:

- the protocol proposal;
- the authoritative lifecycle, configuration, resource, storage, testing, or command doctrines;
- the system-component inventory;
- the development-plan sprint ledger; or
- a future neutral protocol release manifest.

The assessment asks one question: **what would have to be true for prodbox to adopt the protocol without
weakening its current architecture and evidence rules?**

The principal comparison sources are:

- [Lifecycle Reconciliation Doctrine](./documents/engineering/lifecycle_reconciliation_doctrine.md),
  especially its exact-keyed observation boundary;
- [Resource Scaling Doctrine](./documents/engineering/resource_scaling_doctrine.md), especially its
  proof-carrying plan and enforcement rings;
- [Config Doctrine](./documents/engineering/config_doctrine.md), especially Tier-0 resource ownership;
- [Retained Storage Lifecycle Doctrine](./documents/engineering/storage_lifecycle_doctrine.md), especially
  the single repository-local retained root and capability-disposition rule;
- [Pure FP Standards](./documents/engineering/pure_fp_standards.md), especially external-authority folds,
  GADT limits, and Plan / Apply;
- [Chaos Hardening Doctrine](./documents/engineering/chaos_hardening_doctrine.md), especially the distinction
  between decision, protocol, and runtime evidence;
- [CLI Command Surface](./documents/engineering/cli_command_surface.md);
- [System Components](./DEVELOPMENT_PLAN/system-components.md); and
- [Development Plan → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here).

No source code or infrastructure was changed or exercised for the original review. The findings come from a
read-only comparison of the proposal, authoritative doctrine, current component inventory, current sprint
ledger, and the existing Haskell resource-boundary correspondence.

## 3. What the Proposal Is Actually Building

The proposal is not a general-purpose scheduler. It is a static, safety-first admission and custody protocol
with these principal elements:

1. A privileged operator installs a signed host catalog and a finite permanent object namespace.
2. A neutral Haskell interoperability kernel defines canonical identities, encodings, lock order, journal
   layout, bounded generations, lease states, refusals, and quarantine.
3. Independently versioned resource-family declarations describe physical capacity and alias/conflict graphs.
4. Independently versioned mechanism profiles describe how a particular operating-system or hardware
   mechanism establishes exclusion, containment, observation, cleanup, or partitioning.
5. Each participating project maps its validated local demand into the neutral requirement algebra and maps
   protocol and project receipts back into its own terminal result.
6. Foreground work retains its own kernel handles. Persistent work uses a project-local anchor that retains
   handles and the exact enclosing enforcement domain for the workload lifetime.
7. A base cell supplies persistent or ordinary capacity. A separately declared turn cell supplies bounded
   burst or exclusive capacity without permitting arbitrary live growth.
8. Uncertain state does not expire into free capacity. It becomes quarantined until exact absence or a
   controlled reprovisioning boundary is established.

This is a useful and important scope. It solves **cross-project double allocation among participating
artifacts**, not whole-machine scheduling, service-rate sufficiency, lifecycle cleanup, or protection from an
administrator, hostile same-principal process, or unmanaged workload.

The distinction matters operationally. A long-lived prodbox base lease will reserve its catalog offer for the
life of the retained local control plane, even when the cluster is lightly loaded. Turn cells can improve use of
selected burst or exclusive resources, but there is deliberately no fairness owner, preemption authority, or
dynamic global scheduler. The expected benefits are safety, boundedness, and honest refusal, not maximum host
utilization.

## 4. Architectural Alignment with Prodbox

### 4.1 The neutral kernel is appropriately narrow

The proposal correctly keeps project phase DAGs, provider workflows, cluster topology, model formulas, and
project receipts out of the kernel. That is compatible with prodbox's rule that resource identity, lifecycle
class, desired state, cleanup order, and completion remain in closed project-owned registries and programs.

The resource-family/mechanism-profile split is also correct. CPU, RAM, storage, CUDA, and Metal are resources;
cgroups, filesystem quotas, whole-device exclusion, MIG, and MPS are mechanisms with different strengths.
Keeping those dimensions independent avoids pretending that device presence implies a hard ceiling or that an
operating system is itself a resource family.

### 4.2 Progressive assurance matches prodbox's evidence posture

The distinction between `CooperativeCellLease`, `EnforcedCellLease`, and
`RecoverableExecutionAuthority` is one of the proposal's strongest features. It prevents three common forms of
claim inflation:

- treating capacity arithmetic or an advisory lock as a physical wall;
- treating a wall as recovery after holder failure; and
- treating a terminal receipt as reusable live authority.

This is consistent with prodbox doctrine, which distinguishes type-level operation legality, current external
observation, authoritative read-back, and deployment qualification.

### 4.3 Failure does not silently release capacity

The protocol does not use timeout leases. Process exit or reboot releases kernel handles but does not establish
that a cgroup, service, mount, VM, container, retained output, or device context is absent. A stale or uncertain
finite workload is quarantined; a recoverable workload must execute its recovery machine. This aligns closely
with prodbox's rule that invocation or provider exit is not resource-absence evidence.

### 4.4 Hardware aliasing and retained storage are treated as real capacity concerns

The physical graph models whole devices, partitions, ancestors, aliases, and conflicting domains. Unified or
managed memory is charged through its aliases before capacity is checked. Persistent storage is treated as a
stock-flow quantity rather than capacity automatically released when compute ends.

That is materially better than a CPU/RAM-only lock protocol and aligns with prodbox's finite durable-storage
and retained-state doctrine.

### 4.5 The AWS authority boundary is preserved

The prodbox adoption row retains Lifecycle Authority, Provider Worker, cleanup graph, local RKE2, and AWS desired
state. Remote EKS nodes are foreign unless separately enrolled. This is the right boundary:

- the shared-host protocol may admit local host capacity;
- it does not move lifecycle authority to EKS;
- it does not authorize host-direct AWS mutation;
- it does not interpret Pulumi or provider cleanup; and
- it does not let another project reconcile prodbox resources.

### 4.6 The fixed machine-global root is not inherently inconsistent with `.data/`

The proposal's `/var/lib/shared-host-resource-protocol` root is explicitly machine-global and never
repository-local. [Retained Storage Lifecycle Doctrine §7](./documents/engineering/storage_lifecycle_doctrine.md#7-the-single-retained-operator-host-root)
states that `.data/` is the only **repository-local** retained root. The two can coexist if their ownership and
decommission semantics remain distinct:

- `.data/` remains the prodbox capability and workload-data root;
- the shared root remains operator-owned cross-project protocol state;
- `prodbox cluster delete` does not delete the shared root; and
- `prodbox nuke` does not decommission other projects' protocol enrollment or records.

The proposal needs to state this relationship explicitly, but it does not require moving protocol state into
`.data/`.

## 5. Critical Finding: The Persistent Anchor Has No Prodbox Boot Topology

### 5.1 Why the anchor is necessary

An invoking CLI cannot retain a base lease for an RKE2 control plane that outlives it. The protocol therefore
requires a project-local, workload-lifetime anchor. For prodbox that anchor must live outside Lifecycle
Authority because Lifecycle Authority runs inside the RKE2 cluster whose host authority must already exist.

This is logically coherent, but it introduces a new host-resident prodbox component below the mandatory local
control plane.

### 5.2 What is currently missing

The proposal does not define:

- the anchor executable role or exact closed command surface;
- its systemd unit, installation owner, service principal, and executable provenance check;
- ordering against `rke2-server`, containerd, kubelet, and host cleanup;
- whether `rke2-server` is `Requires=`, `After=`, `BindsTo=`, or `PartOf=` the anchor unit;
- the mechanism that prevents a direct `systemctl start rke2-server` or reboot auto-start from bypassing
  protocol admission;
- how anchor death first freezes or stops descendants before losing handles;
- how a restarted anchor distinguishes an already-running old RKE2 effect from an effect safe to resume;
- the IPC endpoint, claim-bound nonce custody, peer identity, deadline, queue, and saturation semantics;
- how the anchor creates or adopts the enclosing systemd/cgroup domain;
- how `prodbox cluster reconcile` attaches to an existing matching attempt;
- how local-only delete, cascade delete, repair, and total decommission drive the anchor; or
- how the anchor is recovered when the shared catalog is readable but `.data/`, Vault, or Lifecycle Authority
  is not.

The protocol states that an auto-restarting consumer must reacquire the same slot, attempt, epoch, cell, and
domain locks before it resumes. On the current prodbox host, that statement is not self-enforcing. The RKE2
systemd service can exist and start independently. Without an explicit boot dependency and fail-closed stop or
freeze path, a reboot can resume RKE2 before the anchor has recovered its lease.

### 5.3 Why this is a release blocker rather than a later enhancement

The cooperative and finite enforced profiles admit only foreground, supervised, non-detaching work. RKE2,
Lifecycle Authority, Vault, MinIO, Kubernetes controllers, restartable containers, mounts, and retained
storage all require the recoverable persistent profile.

Therefore prodbox cannot adopt a weaker profile for its primary supported lifecycle and add anchor recovery
later. It could use the cooperative profile for narrowly scoped foreground build or test operations, but that
would not qualify the retained control plane.

### 5.4 Required resolution

Before prodbox adoption, the authoritative component inventory needs a **Host Resource Custody Anchor** row
with at least:

- one host-native same-binary role;
- a pre-RKE2 systemd unit and exact dependency graph;
- an exact non-inheritable handle and cgroup-custody contract;
- bounded authenticated local IPC;
- a closed project operation GADT rather than arbitrary commands or manifests;
- a proof-carrying shutdown result;
- reboot and anchor-crash recovery tables;
- local-only, cascade, and total-decommission interactions; and
- live qualification that kills the anchor and reboots the host at every durable transition.

## 6. Critical Finding: The Resource Algebras Are Not Yet Composed

### 6.1 Existing prodbox authority

Prodbox already has a multi-layer resource contract:

1. Tier-0 Dhall carries host physical capacity, RKE2 reservation, eviction floor, and workload-demand inputs.
2. Haskell compiles the decoded plan into an opaque `AllocatedResourcePlan` when reservation and concurrent
   demand fit through non-saturating arithmetic.
3. Reconcile rechecks the plan against an `ObservedHostRoot`.
4. Kubernetes requests, limits, namespace quotas, LimitRanges, PVC sizes, and kubelet reservations derive from
   the same inputs.
5. Systemd/cgroups and Kubernetes supply runtime containment.
6. Runtime observation separately evaluates OOM, restart, throttling, queue, deadline, and latency behavior.

The protocol introduces another finite capacity structure: host reserve, base offers, turn offers, physical
domains, aliases, mechanism strengths, and legal concurrency epochs.

### 6.2 The missing theorem

The proposal needs one total prodbox adapter that proves a relationship equivalent to:

```text
protocol host reserve
+ all simultaneously legal foreign/other-project offers
+ selected prodbox base offer
+ all compatible selected prodbox turn offers
<= current observed physical host after alias closure

and

prodbox maximum concurrent local demand
+ prodbox host-native anchor/observer/journal overhead
+ maximum retained-storage stock and reachable production
<= selected prodbox offers and enforcement domains
```

The adapter should have a shape conceptually similar to:

```haskell
compileProdboxHostRequirement
  :: ProtocolCatalogEpoch
  -> ObservedHostRoot
  -> ValidatedSettings
  -> SomeAllocatedPlan
  -> Either ProdboxHostRequirementFailure ProdboxHostRequirement
```

The exact type may differ, but the following properties are required:

- the adapter consumes the existing proof, rather than re-decoding or re-authoring resource values;
- the requirement binds the source-plan digest and validated deployment context;
- the requirement explicitly accounts for host-native work outside Kubernetes;
- units and rounding are canonical and checked once;
- durable and ephemeral storage preserve their distinct physical-device identities;
- shared-device storage uses one joint budget rather than two independent apparent capacities;
- retained `.data/` stock, retained artifacts, provider scratch, protocol metadata, and anchor overhead are
  each charged exactly once;
- base and turn concurrency derives from `WorkloadConcurrency` and closed operation identity rather than a
  second handwritten concurrency table; and
- a catalog cell that is too small produces a typed refusal before any host or cluster mutation.

### 6.3 Why `host_capacity` cannot simply become the cell size

Today `host_capacity` describes the authored/observed physical host boundary used by the resource-plan proof.
Silently redefining it as a project cell would change existing doctrine and may create another mismatch with
host observation and kubelet capacity.

Conversely, leaving it as physical capacity without proving the workload maximum fits inside the selected cell
allows Kubernetes to reason about more host capacity than the outer prodbox allocation permits. A parent hard
ceiling might contain the result, but containment through throttling or OOM is not scheduler sufficiency.

The safer composition is:

- retain physical `host_capacity` as the physical observation boundary;
- retain the existing `AllocatedResourcePlan` as the project-internal demand proof;
- add a protocol-allocation proof that the relevant project demand fits the selected cell; and
- enforce the selected cell as an enclosing parent domain while retaining existing inner Kubernetes and
  per-role enforcement.

This is effectively a fourth, cross-project enforcement ring. It must use the same underlying demand values,
not introduce another operator-authored prodbox budget.

### 6.4 Storage-specific closure

The protocol correctly describes retained storage as stock-flow, but the prodbox adapter must identify all
stock that survives compute:

- MinIO and Vault PV contents;
- PostgreSQL and vscode retained PV contents;
- retained control-plane journals and cleanup reports;
- retained artifacts and staging bounds;
- Pulumi checkpoint blobs and bounded scratch hydration;
- test `.test-data/` roots where applicable; and
- any turn-produced model, image, cache, or result bytes.

PVC request totals alone are not an observation of current bytes and do not account for every host-retained
artifact. The adapter needs a conservative maximum production bound and, where a stronger storage mechanism is
claimed, exact quota/extent application and read-back.

## 7. High Finding: The Outer Recovery Record Must Not Become Lifecycle Truth

### 7.1 Existing prodbox rule

Prodbox deliberately keeps external authorities separate. A checkpoint says whether a provider operation can
be resumed; it does not say whether a resource exists. A Kubernetes observation does not answer for AWS. A
clean aggregate audit does not prove one registered resource absent. Every observation carries its exact key,
coordinate, authority, revision, and partial/unobservable outcomes.

### 7.2 Ambiguity in the proposal

The proposed recoverable cell machine uses:

```text
Prepared -> Applied -> Running -> Releasing -> Retired
     \          \          \           \
      +----------+----------+------------> Recovering
                                             |
                                      Retired or Quarantined
```

It calls the cell current record the machine-global recovery source. Read narrowly, this is acceptable: it is
the recovery source for **host-cell custody**. Read broadly, `Applied`, `Running`, or `Retired` could be mistaken
for authoritative claims about RKE2, Kubernetes, provider operations, retained storage, or AWS resources.

That broader interpretation would conflict with prodbox lifecycle doctrine.

### 7.3 Required typed boundary

The shared record should contain only protocol-owned facts and opaque project bindings, for example:

- project, slot, attempt, catalog epoch, boot, cell, domain, and mechanism identities;
- prepared host-enforcement intent;
- anchor process-birth and endpoint identity;
- an opaque `ProjectRecoveryRef` bound to the project operation;
- the digest and authority revision of the project evidence last verified; and
- whether the host-cell state is held, releasing, recoverable, terminally releasable, or quarantined.

It should not serialize a generic reconstruction of prodbox resource descriptions or decide external desired
state from those descriptions.

The prodbox adapter must define the exact evidence accepted for release. Depending on the operation, that may
include:

- exact RKE2 service/process/cgroup emptiness;
- a Lifecycle Authority terminal operation projection;
- exact registered-resource absence evidence;
- a cleanup-run terminal result;
- retained-storage ownership settlement; and
- proof that delayed operations are terminal, cancelled, fenced, or drained.

If any required authority is unavailable or returns partial/unobservable evidence, the outer protocol must
retain or quarantine the cell. It must never infer absence from anchor death, process exit, a missing
checkpoint, a stale PID, or a command exit code.

## 8. High Finding: Kubernetes Turn Enforcement Is Undefined

### 8.1 The launch-boundary problem

The proposed MISU chain assumes a closed launcher consumes an execution authority. That assumption is direct
for a foreground child process launched by the holder. It is not direct for a Kubernetes workload:

1. The anchor or CLI submits desired Kubernetes state.
2. Controllers and the scheduler act asynchronously.
3. The container runtime creates processes later.
4. A device plugin or runtime exposes the accelerator.
5. The resulting process is not a direct child holding the protocol capability.

An ordinary manifest, Helm hook, Job, controller, or direct `kubectl` path can therefore bypass the turn unless
the Kubernetes admission and device-assignment surfaces are narrowed mechanically.

### 8.2 Evidence required for a prodbox turn

A qualifying prodbox accelerator turn needs at least:

- one closed project operation identity mapping to an exact Kubernetes workload shape;
- a turn-bound admission token that arbitrary manifests cannot forge;
- exact node and physical device identity;
- device-plugin or equivalent assignment restricted to the held turn;
- Pod UID, container ID, cgroup, and device-context read-back;
- no unrestricted all-device exposure;
- a fence against a delayed controller or Pod appearing after apparent absence;
- exact workload deletion and enclosing device-domain emptiness before turn release; and
- crash/reboot recovery that prevents kubelet or the runtime from resuming the consumer first.

Until such a mechanism exists, prodbox should not claim turn-cell enforcement for Kubernetes accelerators.
The protocol could still govern a coarse persistent base envelope or a directly supervised host process, but
not an asynchronous Kubernetes device turn.

## 9. High Finding: Governance and Status Ownership Are Incomplete

### 9.1 Document status mismatch

[Unified Documentation Guide §3](./documents/documentation_standards.md#3-required-header-metadata) defines
`Reference only` as a document that points to authoritative sources. The protocol document instead defines a
large body of new normative behavior and ends with a recommended policy, while also stating that the future
neutral release will be the semantic authority.

Until that release exists, there is no authoritative semantic source to which this repository copy can point.
The current status is honest about non-implementation but structurally ambiguous about design authority.

Two coherent dispositions are available:

1. **Unaccepted proposal**: retain non-authoritative proposal language, ensure no current doctrine or code
   depends on it, and record an explicit human adoption decision before scheduling implementation.
2. **Accepted prodbox target**: give the prodbox adoption boundary an authoritative owner, add the component and
   plan rows, and later shrink the repository copy to release coordinates when the neutral release exists.

The current hybrid should not silently become a supported-path requirement.

### 9.2 No current development-plan owner

The current [Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here) queue contains Sprint `2.75` followed by
the parked Sprint `6.5`. It contains no shared-host protocol adoption row. The authoritative
[System Components](./DEVELOPMENT_PLAN/system-components.md#haskell-only-architecture) inventory contains no
Host Resource Custody Anchor or neutral-kernel adapter row.

That means there is currently no owner for:

- package intake and pinning;
- host-root installation and prerequisites;
- prodbox adapter declarations;
- anchor installation and runtime;
- resource-plan composition;
- migration of an already-running retained RKE2 cluster;
- command integration and Plan / Apply rendering;
- legacy bypass removal;
- cross-project qualification;
- rollback; or
- decommission and quarantine cleanup.

This is acceptable while the document remains a proposal. It becomes a defect the moment another document or
code path treats the protocol as an accepted target.

### 9.3 Neutral release governance is a real dependency

The proposal correctly avoids a seed-to-seed or early seed-to-amoebius package dependency. It still creates a
new external governance and build dependency:

- a neutral repository and package;
- release and catalog signing keys;
- identifier allocation;
- exact GHC/package compatibility;
- release-manifest pinning;
- security response and key rotation;
- archival ownership;
- offline migration tooling; and
- an operator installation and upgrade path.

Calling this repository a dependency island does not make the operational dependency disappear. The trade-off
may be worthwhile, but prodbox dependency doctrine and prerequisite inventory must explicitly admit it.

## 10. High Finding: A Formal Protocol Model Is Missing from the Freeze Gate

The protocol coordinates multiple independently built processes through advisory kernel locks and durable
dual-page records across contention, partial acquisition, process death, reboot, generation exhaustion,
quarantine, and offline migration. Pure functions, property tests, cross-artifact tests, and live crash tests are
all necessary, but they answer different questions.

[Chaos Hardening Doctrine §9](./documents/engineering/chaos_hardening_doctrine.md#9-move-ii--model-prove-the-protocol-not-the-program)
requires cross-actor safety invariants to be checked against a bounded protocol model containing concurrency
and actor crash. The protocol's conformance section currently lists pure tests, compile-fail tests, lock/crash
tests, mechanism tests, and cross-project live tests, but no model or model-to-code correspondence obligation.

Before the first core freeze, a model should cover at minimum:

- at most one live owner of a cell;
- no overlapping live owner of conflicting physical domains;
- no execution authority before every required wall is applied and read back;
- admission-lock and domain-lock interleavings;
- partial acquisition rollback;
- terminal-record publication versus lock release;
- holder death before and after every journal publication;
- stale `Held` conversion to quarantine;
- recoverable `Prepared` through `Recovering` crash prefixes;
- generation and receipt-window saturation;
- reboot with persistent external effects;
- catalog migration versus old and new clients;
- quarantine preservation across migration; and
- a conditional liveness property for an uncontended, observable, non-quarantined eligible request.

The model must state its actor cardinality and limits. A two-participant model cannot qualify a catalog that
admits more concurrent actors without an explicit inductive argument or matching bounded run. The release must
also document the refinement boundary: what remains assumed between the abstract model, native lock semantics,
filesystem durability, the Haskell implementation, and real deployed mechanisms.

## 11. Medium Finding: Global Availability Coupling Is Understated

The proposal rejects a shared daemon, but it still creates a host-global coordination and upgrade boundary:

- one fixed root;
- one exact CoreMajor;
- one epoch lock;
- one signed catalog;
- whole-catalog refusal for unknown potentially aliasing families;
- finite preallocated identities and record generations;
- indefinite quarantine; and
- offline migration under the exclusive epoch lock.

These are defensible safety choices. They also have operational consequences:

- a persistent prodbox base lease may require planned control-plane downtime for a core migration;
- an unknown shared-memory or shared-storage family can make an old prodbox binary refuse the whole catalog;
- a corrupt shared page can remove a cell or overlapping domain from service indefinitely;
- an exhausted generation can halt admission until privileged offline maintenance; and
- an anchor crash can turn a healthy but unproven RKE2 effect into a host-global quarantine obligation.

The protocol should therefore publish explicit operational contracts for:

- compatibility windows;
- planned outage and migration prerequisites;
- quarantine inspection and clear authority;
- preservation of quarantines across schema migration;
- rollback limits;
- installer and root backup/restore boundaries;
- maximum recovery time objectives; and
- failure narration that distinguishes busy, unsupported, unobservable, saturated, and quarantined states.

This is global coordination without a daemon, not coordination without a global failure domain.

## 12. Medium Finding: Trust and Availability Claims Need Tighter Scoping

The proposal explicitly excludes administrators, hostile same-identity processes, and nonparticipants from its
guarantee. That is honest and should remain prominent.

Two implementation details still require precision.

### 12.1 Artifact identity

Enrollment binds a project and operating-system principal to an artifact digest or trusted build provenance,
and rejects pathnames or self-reported digests as identity. The release must define the actual native
attestation mechanism:

- what bytes are measured;
- how dynamic libraries, runtime loading, interpreters, and wrappers are treated;
- how measurement avoids path replacement and time-of-check/time-of-use substitution;
- how development signers differ from production artifact pins; and
- what exact claim can be made when the same OS principal can debug, inject into, or replace another process.

If the platform cannot enforce more, the claim should remain cooperative correctness among conforming
artifacts, not security isolation between mutually hostile programs.

### 12.2 Shared cell-page writes

Every enrolled principal receives bounded write access to shared cell pages. The protocol relies on a conforming
writer holding the exact cell lock before updating the page. A buggy or hostile enrolled principal can corrupt a
page and force global quarantine even if it cannot manufacture a valid lease.

This preserves safety at the cost of availability. That may be the right design without a broker, but it must be
part of the threat model, operator runbook, and conformance evidence rather than an incidental filesystem
permission detail.

## 13. Medium Finding: Whole-Host Authority Is Usually Unavailable

The proposal correctly distinguishes participating-project authority from whole-host authority. Whole-host
authority additionally requires proof that every material claimant is contained or physically partitioned.

An instantaneous process or free-memory scan cannot prove that condition because an unmanaged process can start
or grow immediately after the scan without observing the protocol admission lock. Therefore a prodbox host can
claim whole-host authority only if a separately enforced host policy closes that creation race, for example by:

- placing every material process in an administered containment hierarchy;
- reserving and physically partitioning all unmanaged demand;
- restricting workload creation to trusted launch surfaces; or
- treating all remaining growth as a conservative fixed host reserve with a real enforced upper bound.

On an open workstation, or a server on which arbitrary same-host jobs can start outside those bounds, the only
honest claims are participating-project exclusion and the specific walls applied to the admitted prodbox
domain. This limitation does not make the protocol useless; it prevents overstatement of what it controls.

## 14. Plan / Apply and Command-Surface Integration

The protocol's pure planning rule returns eligible alternatives and performs final selection under the
admission lock. That can be compatible with prodbox Plan / Apply if the deterministic plan describes:

- the exact catalog epoch and requirement digest;
- the finite eligible cell set;
- the deterministic selection policy;
- the required assurance and mechanisms;
- the possible typed contention/refusal outcomes; and
- every project mutation authorized after one selected cell is branded at apply time.

Apply may choose only an alternative already represented by the plan. A changed catalog, root, host identity,
family revision, mechanism revision, or requirement digest must force re-observation and re-planning rather than
letting apply reinterpret an old plan.

Prodbox adoption must also preserve the closed CLI surface:

- `prodbox cluster reconcile` remains the canonical cluster reconciler;
- no `install`, `repair`, `force`, or raw anchor-command sister surface appears;
- protocol-root/catalog installation and privileged quarantine-clear commands belong to the neutral operator
  tooling unless an explicit prodbox command is deliberately registered;
- shared-root readiness, catalog compatibility, principal enrollment, and mechanism availability become typed
  prerequisites before mutation;
- `--dry-run` and `--plan-file` render the protocol acquisition requirements without acquiring locks or writing
  records; and
- Busy, Unsupported, Saturated, and Quarantined results use operator vocabulary and name the canonical remedy.

The anchor's private IPC is not automatically a public CLI surface. It should remain an interpreter boundary
behind the existing registered commands unless an operator-facing command is independently justified and added
to the generated command registry.

## 15. Suggested Prodbox Adoption Profile

If the proposal is accepted, the lowest-risk prodbox profile is narrower than the full document.

### Stage 0: Governance and model only

- Create the neutral repository, package, release manifest, signing policy, and identifier registry.
- Freeze no ABI until the protocol model and native-lock/filesystem assumptions are reviewed.
- Define the Linux-only mechanism subset needed by the current prodbox supported host.
- Create a conservative catalog but do not place current prodbox operation behind it.
- Register the adoption work in the development plan without displacing the current queue implicitly.

### Stage 1: Foreground cross-project conformance

- Use only foreground, supervised, non-detaching test operations.
- Prove independently built artifacts contend on the same permanent objects.
- Exercise busy, unknown, saturation, torn-page, crash, and quarantine cases.
- Make no claim about retained RKE2, automatic recovery, or whole-host containment.

This stage validates the neutral kernel without risking the mandatory control plane.

### Stage 2: Prodbox demand adapter and parent envelope

- Implement the sole `ValidatedSettings`/`AllocatedResourcePlan` to protocol requirement conversion.
- Add an enclosing Linux systemd/cgroup mechanism for a test-only prodbox domain.
- Read back the parent hard ceilings and prove the existing inner plan fits.
- Account for host-native and retained-storage overhead exactly once.
- Qualify changed-subject and boundary-substitution negatives.

### Stage 3: Persistent anchor in shadow mode

- Add the host anchor component and systemd ordering.
- Observe and report the cell that would govern RKE2 without yet making it the sole start gate.
- Compare shadow demand, mechanism read-back, restart, and storage observations against the existing live
  control plane.
- Do not run dual writers for shared protocol records or project lifecycle authority.

Shadowing must remain observation-only; it cannot claim safety or mutate competing custody state.

### Stage 4: Explicit retained-RKE2 cutover

- Stop the existing control plane at a documented boundary.
- Establish exact persistent-state and delayed-effect observations.
- Acquire the installed base cell through the new anchor.
- Start RKE2 only beneath the acquired enforcement domain.
- Prove boot, reboot, anchor death, cluster repair, local delete, cascade recovery, and total decommission.
- Remove every direct RKE2 start/resume bypass mechanically.
- Keep rollback explicit and limited to the last reversible boundary.

This must be a planned migration, not an upgrade that attempts to reparent a live uncontrolled process tree.

### Stage 5: Optional turn mechanisms

- Add direct foreground turns first.
- Add Kubernetes accelerator turns only after the device-plugin/admission/cgroup design is closed.
- Qualify exact whole-device and partition conflicts on real hardware.
- Keep MPS deferred until its aggregate server generation, cap, crash failure domain, and quarantine semantics
  are complete.

## 16. Required Evidence Before Supported-Path Adoption

The following gate should be conjunctive. Missing evidence blocks promotion rather than becoming a caveat
attached to a success claim.

### 16.1 Governance and release evidence

- Exact neutral repository, package, maintainers, review quorum, release keys, and archival owner.
- Exact CoreMajor, family, mechanism, and catalog schema release coordinates.
- Reproducible package pinning under the project's pinned GHC and Cabal versions.
- Installer, status, migration, quarantine-clear, and decommission command ownership.
- Key rotation and compromised-signer recovery.
- Explicit prodbox development-plan sprint and cleanup ownership.

### 16.2 Pure and type evidence

- Total canonical codecs with noncanonical rejection.
- Checked bounded arithmetic and unit conversions.
- One prodbox demand encoder and one receipt projection.
- Private authority constructors and compile-fail substitution/escape fixtures.
- Base/turn compatibility derived without a second concurrency table.
- Exact refusal for unknown families, mechanisms, strengths, cells, or catalog revisions.
- Explicit separation of protocol custody state from external lifecycle observations.

### 16.3 Protocol evidence

- Machine-checked safety model with crash and migration actions.
- Documented actor count, model scope, liveness assumptions, and refinement gaps.
- Deterministic concurrency simulation for implementation interleavings where practical.
- Cross-artifact contention with independently built participants.
- Native lock semantic tests on the exact supported Linux filesystem and kernel mechanisms.
- Dual-page torn-write, conflicting-generation, wrap, and saturation tests.

### 16.4 Prodbox runtime evidence

- Parent cgroup creation, wall application, and effective-value read-back before RKE2 start.
- Existing inner resource-plan proof joined to the selected cell offer.
- No direct RKE2 start or auto-resume bypass.
- Anchor crash before and after every durable publication.
- Host reboot with an existing persistent cluster.
- Lifecycle Authority unavailable, sealed Vault, unreadable `.data/`, corrupt journal, and delayed provider
  operation cases.
- Local-only delete, cascade, repair, and total decommission results with exact retained-root narration.
- Bounded queue, deadline, memory, CPU, process, descriptor, scratch, and journal overhead.
- Current-revision deployment qualification under production composition.

### 16.5 Accelerator evidence, if advertised

- Exact device identity and ancestor/partition conflict.
- No raw all-device or manifest bypass.
- Pod/container/cgroup/device binding read-back.
- Delayed workload appearance after apparent deletion.
- Anchor, kubelet, runtime, and device-plugin crash schedules.
- Exact device-context empty proof before turn release.

## 17. Decision Matrix

| Question | Current assessment | Consequence |
|---|---|---|
| Is there a real cross-project host-resource problem? | Yes | A shared protocol is justified in principle. |
| Is a neutral package better than one seed owning the others? | Yes | Preserve the dependency-island direction. |
| Is the proposed kernel boundary reasonably small? | Yes | Keep project lifecycle and demand outside it. |
| Does the proposal preserve prodbox AWS authority? | Yes | Retain Lifecycle Authority and Provider Worker ownership. |
| Can the cooperative profile govern persistent prodbox RKE2? | No | It is useful only for narrower foreground work. |
| Is the persistent prodbox anchor implementable from the current text? | No | Specify boot, systemd, cgroup, IPC, crash, and teardown topology first. |
| Are catalog cells joined to `AllocatedResourcePlan` by one proof? | No | Add the sole prodbox demand adapter and outer-ring fit proof. |
| Can the cell record prove AWS/Kubernetes/Vault absence? | No | It must accept exact project evidence or quarantine. |
| Are Kubernetes accelerator turns closed against bypass? | No | Defer them pending a concrete admission/device design. |
| Is whole-host authority available on an open workstation? | No | Claim participating-project and exact mechanism guarantees only. |
| Is protocol safety formally modeled? | Not in the proposal's conformance gate | Require a bounded model before core freeze. |
| Is there current sprint and component ownership? | No | The document must remain non-operational until adoption is scheduled. |
| Does the fixed shared root violate the `.data/` rule? | No | Keep machine-global protocol state and repository-local project state distinct. |
| Should current supported commands depend on the proposal? | No | Promotion requires all adoption gates and live qualification. |

## 18. Recommended Amendments to the Protocol Document

The proposal would be materially stronger with the following changes before adoption:

1. Add a dedicated **Prodbox Integration Contract** subsection defining the anchor, systemd ordering, parent
   enforcement domain, resource adapter, lifecycle-evidence boundary, and command interactions.
2. State that the recoverable cell record is authoritative only for shared-host custody and never for project
   resource presence or absence.
3. Define a nominal opaque `ProjectRecoveryRef` and the requirements for a project terminal evidence verifier.
4. Require each project adapter to publish a proof that its complete local demand fits the selected offer,
   bound to the source plan and catalog epoch.
5. Clarify that a project's authored physical-host value is not silently reinterpreted as a cell allocation.
6. State how retained-storage stock and maximum reachable production are observed and charged for prodbox.
7. Add a Kubernetes-specific turn example or explicitly exclude Kubernetes turns from the initial release.
8. Add the protocol model, invariant catalog, actor cardinality, and refinement record to the core-freeze
   governance checklist.
9. Add explicit migration and quarantine-preservation semantics for a persistent base holder.
10. State the machine-global root's relationship to each project's retained roots and total-decommission
    authority.
11. Define what artifact attestation is possible on each supported operating system and narrow the assurance
    claim where it is only cooperative.
12. Add an operational consequences section covering global refusal, outage, saturation, quarantine, and
    privileged recovery.

## 19. Final Assessment

The protocol has the right center of gravity. It refuses to solve cross-project resource coordination by
creating a privileged scheduler that owns every project's policy and lifecycle. It treats exclusion,
containment, recovery, and whole-host authority as different claims. It gives uncertain state a fail-closed
quarantine rather than a timeout. It models physical aliasing and retained stock. It preserves prodbox's local
Lifecycle Authority and AWS mutation boundary.

Its main weakness is not the kernel design. Its weakness is that the prodbox row compresses a major new
host-control-plane layer into two phrases: “compile complete local-host demand” and “keep the anchor outside
Lifecycle Authority.” Those phrases conceal the work that determines whether the protocol actually strengthens
prodbox or creates a second, partially joined authority system.

Until that work is specified and proven, the protocol should be read as:

- a credible neutral safety architecture;
- a useful vocabulary for cells, mechanisms, assurance, and quarantine;
- a candidate outer resource ring for prodbox; and
- a non-operational proposal with no current supported-path authority.

After the anchor topology, resource-algebra composition, lifecycle-evidence bridge, Kubernetes enforcement,
governance, formal model, migration plan, and live qualification are complete, the proposal could become a
sound conservative admission layer for a shared prodbox host. Before then, adopting it would move risk rather
than close it.
