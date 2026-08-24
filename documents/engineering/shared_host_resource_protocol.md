# Shared Host Resource Protocol

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define the topology by which prodbox and the other participating projects coordinate finite
> resources on one host without a shared scheduler, a new seed-to-seed dependency, or an early
> seed-to-amoebius dependency.
> **Read this if**: a prodbox workload, resource-family extension, mechanism provider, project adapter, or
> substrate interpreter has to participate in shared-host admission.
>
> **Target.** This proposal describes target behavior only. Implementation and qualification status remain
> owned by [Development Plan → Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here).

This repository copy records only prodbox metadata, navigation, and its proposed adoption boundary. It does
not establish implementation status or semantic release authority. The proposed protocol would be Haskell-owned
in a standalone neutral release and independently re-derived by amoebius.

## Contents

- [TL;DR](#tldr)
- [1. Decision drivers](#1-decision-drivers)
- [2. Goals and non-goals](#2-goals-and-non-goals)
- [3. Ownership topology](#3-ownership-topology)
- [4. Four semantic layers](#4-four-semantic-layers)
- [5. Guarantee scopes and assurance profiles](#5-guarantee-scopes-and-assurance-profiles)
- [6. Host and resource model](#6-host-and-resource-model)
- [7. Hardware and substrate extensibility](#7-hardware-and-substrate-extensibility)
- [8. Daemonless host coordination](#8-daemonless-host-coordination)
- [9. Admission and acquisition](#9-admission-and-acquisition)
- [10. Project-local anchors and lifecycle](#10-project-local-anchors-and-lifecycle)
- [11. Durable state and recovery](#11-durable-state-and-recovery)
- [12. Bounded idempotency and protocol storage](#12-bounded-idempotency-and-protocol-storage)
- [13. MISU boundary](#13-misu-boundary)
- [14. Versioning, governance, and DRYness](#14-versioning-governance-and-dryness)
- [15. Project adoption boundaries](#15-project-adoption-boundaries)
- [16. Adoption profiles and ownership cutover](#16-adoption-profiles-and-ownership-cutover)
- [17. Conformance](#17-conformance)
- [18. Rationale for rejected topologies](#18-rationale-for-rejected-topologies)
- [19. Core-freeze governance record](#19-core-freeze-governance-record)
- [20. Proposal disposition](#20-proposal-disposition)

## TL;DR

The topology has five moving parts: an operator-installed catalog, a small neutral kernel, independently
versioned resource and mechanism releases, project-local adapters and anchors, and an independent amoebius
re-derivation. The diagram shows where they meet without a service dependency.

~~~mermaid
flowchart TB
  %% register: orientation
    O["Human operator"] -->|"installs signed catalog"| R["Fixed host root"]
    S["Seed projects"] -->|"pin neutral release"| K["Interoperability kernel"]
    A["amoebius DSL"] -->|"re-derives and validates"| AK["Independent amoebius kernel"]
    K -->|"opens permanent objects"| R
    AK -->|"opens the same objects"| R
    R -->|"guards"| L["Base and turn leases"]
    L -->|"enables after wall readback"| E["Execution authority"]
    E -->|"launches through"| P["Project-local lifecycle"]
    P -->|"terminates with"| Q["Receipt or quarantine"]
~~~
*Orientation.* Design intent; the diagram summarizes the proposed dependency topology in [§3](#3-ownership-topology).

There is no host-global scheduling daemon. A short admission critical section joins nonblocking kernel locks.
A finite foreground operation retains its own locks. A persistent project effect uses a project-local,
workload-lifetime anchor whose cross-project role is limited to lock and enforcement-domain custody.

The shared boundary is intentionally small:

- a rarely changing interoperability kernel owns identifiers, encoding, cells, locks, ordering, bounded
  records, lease states, quarantine, and core refusals;
- independently versioned resource families describe CPU, memory, storage, CUDA, Metal, and future
  accelerators such as a Neural Engine;
- separately versioned mechanism profiles bind cgroups, Windows Job Objects, filesystem quotas, device
  exclusivity, MIG partitioning, or MPS sharing to a kernel backend and resource family; and
- each project retains its own workload derivation, closed launch vocabulary, lifecycle, recovery interpreter,
  and result semantics.

Under this proposal, the four seeds would pin one Haskell kernel released from a separately governed,
product-neutral repository. No participating product repository would own that package, so protocol adoption
would add neither a new seed-to-seed dependency nor a seed-to-amoebius dependency. A seed whose build boundary
cannot consume it could temporarily implement a narrow compatibility port.

amoebius would independently re-derive the kernel and its laws rather than import the neutral implementation.
After the amoebius gates and an explicit migration were accepted, lifted seed workflows would retire their
seed adapters. A seed that must remain operational after that cutover would acquire a deliberate runtime
dependency on the amoebius-owned surface; the transition would never introduce it early or implicitly.

## 1. Decision drivers

The topology balances four requirements.

### 1.1 amoebius must not freeze seed design

This proposal assumes the seed projects will continue discovering demand, lifecycle, recovery, and enforcement
details. They must not import amoebius, wait for an amoebius phase, or encode a current workflow in an amoebius
interface. They would pin a stable interoperability release and continue evolving behind their own adapters.

### 1.2 Participating projects need real host-global exclusion

Repository-local locks, Kubernetes requests, VM sizes, container limits, and instantaneous
free-memory observations cannot arbitrate with another project using the same physical host. The
shared boundary must name the same permanent cell and physical-domain lock objects in every
participant.

### 1.3 Coordination must not require a master service

A shared daemon would combine policy, scheduling, lifecycle, and protocol upgrade into one
fast-changing privileged process. The protocol instead uses an operator-installed catalog,
nonblocking kernel locks, a short admission lock, and project-local anchors. Waiting, retry,
backoff, and user-facing scheduling remain client policy.

### 1.4 The result must be DRY and hardware-extensible

Darwin, Linux, and Windows differ in lock and containment mechanisms, not in the meaning of a cell,
lease, transition, or receipt. CUDA, Metal, and future accelerators differ in resource families;
MIG and MPS differ in mechanism profiles. Neither changes the core lifecycle. Project-specific
demand is derived once in the owning project and converted once at the adapter boundary.

## 2. Goals and non-goals

The protocol aims to ensure that:

- participating projects cannot spend the same logical cell twice;
- exact exclusive physical domains cannot have overlapping live participating holders;
- a stronger execution authority cannot exist before its required walls are applied and read back;
- a crash cannot make an uncertain persistent effect silently reusable;
- adding a resource family does not require another copy of the host lifecycle;
- seed projects have no source, build, package, or runtime dependency on amoebius during the seed
  period; and
- the eventual amoebius implementation can replace the provisional kernel behind the same narrow
  boundary.

The protocol does not promise that:

- an administrator, hostile same-identity process, or nonparticipating binary obeys advisory locks;
- an open workstation is immune to every out-of-memory or performance event;
- CPU caches, memory bandwidth, PCIe, storage latency, thermal behavior, or power are partitioned
  unless an admitted family and mechanism pair supplies that guarantee;
- one project's lifecycle authority may generically reconcile another project's resources;
- all projects must advertise every operating system or accelerator family; or
- a Markdown copy, matching self-reported digest, green local test, or project-authored receipt
  proves conformance.

## 3. Ownership topology

| Layer | Proposed seed-period owner | Proposed later owner | Responsibility |
|-------|---------------|-----------------|----------------|
| Repository proposal copy | Each repository during review | Each repository as a short adoption view after the first neutral release | Pre-release rationale; afterward only local metadata, adoption boundary, release coordinates, and catalog compatibility |
| Neutral protocol repository | Separate human-governed product-neutral repository | Archived only after no seed relies on it | Canonical Haskell core package, release manifests, registries, and conformance declarations |
| Core application binary interface (ABI) release | Neutral protocol repository | amoebius-generated release | Core version, encoding, object grammar, lock order, bounded records, transitions, and refusals |
| Seed kernel | Version-pinned neutral package or narrow compatibility port | Retired | Pure core, lock access, dual-page journal access, and common kernel backends |
| amoebius kernel | amoebius alone | amoebius | Independent model, formal refinement, generated interpreters, and eventual runtime |
| Resource-family release | Neutral family release process | amoebius extension algebra | Physical identities, capacity dimensions, aliases, conflicts, and invalidators |
| Mechanism-profile release | Neutral mechanism release process | amoebius extension algebra | Backend pairing, exclusivity or containment, readback, cleanup, and recovery semantics |
| Project adapter | Each project | amoebius as each workflow is lifted | Total demand conversion, project identity, closed launch vocabulary, and receipt projection |
| Host catalog | Human operator | Human operator through amoebius tooling | Signed cells, reserves, enrollments, admission slots, family and mechanism revisions, and bounds |
| Live custody | Foreground process or project-local anchor | Same shape | Kernel handles and exact enclosing enforcement domains |
| Inner lifecycle | Each project | amoebius after explicit workflow migration | Desired resources, workflow transitions, provider effects, cleanup, and application evidence |

The neutral protocol repository would be a dependency island, not a sixth product and not a service. It would
import no participating lifecycle, command, plan, or provider type. Hosting it inside hostbootstrap, another
seed, or amoebius before cutover would create the dependency edge this topology forbids.

The five full Markdown copies are temporary review views. Before the neutral release exists, they confer no
semantic compatibility. At the first neutral release, each copy must shrink to a short local adoption record
that pins exact core, family, and mechanism releases plus catalog schema and profile compatibility. The Haskell
release manifest then becomes the single semantic authority; host-catalog identities remain operator-owned.

## 4. Four semantic layers

### 4.1 Interoperability kernel

The frozen core contains only facts every participant must interpret identically:

- one exact core major version;
- bounded integers, units, canonical encoding, digest separation, and catalog-signature verification;
- encodings for project, admission-slot, attempt, cell, family, mechanism, and physical-domain identities;
- fixed host-root resolution and permanent object grammar;
- catalog and epoch identity;
- cell, ancestor, and leaf lock modes plus total acquisition order;
- minimal and recoverable lease transitions;
- bounded dual-page journal, receipt-window, and saturation rules;
- assurance-strength and outcome tags; and
- compatibility refusal, recovery, and quarantine behavior.

The core owns the encoding of a namespaced ProjectId, not a closed participant list. Project enrollment is
finite host-catalog data, so adding a project does not change CoreMajor. The core contains no project phase
directed acyclic graphs (DAGs), command registries, provider workflows, model formulas, cluster topology, or
product receipts.

### 4.2 Resource-family declaration

A resource family projects physical capacity into the generic core algebra. Each independently
content-addressed release supplies:

- a namespaced family identifier and semantic digest;
- a stable observation procedure and opaque physical-domain identity;
- bounded capacity dimensions in canonical units;
- parent, child, alias, and conflict projection;
- exclusive identity sets and scalar quantities;
- boot, driver, service, partition, and topology invalidators; and
- pure laws and negative cases for its generic projection.

CPU, memory, storage, CUDA compute and device memory, Metal, and a Neural Engine are resource families.
An operating-system containment tool is not.

### 4.3 Mechanism-profile declaration

A mechanism profile pairs one family with a kernel or hardware backend. Each independently
content-addressed release supplies:

- exact family, backend, and mechanism identifiers;
- offered mechanism strengths and their resource-indexed satisfaction relation;
- empty-domain or partition creation;
- application and effective-value readback;
- process attachment and handle rules;
- cleanup, drain, absence, and quarantine semantics; and
- negative, crash, and live conformance obligations.

Cgroups, Windows Job Objects, filesystem quotas, whole-device locks, MIG partition creation, and MPS servers
are mechanism providers. A MIG instance produced by an admitted partition profile becomes a physical child
domain; MPS remains a bounded-sharing mechanism over a CUDA domain.

A client links finite Haskell FamilyRegistry and MechanismRegistry values. Their constructors are private,
lookup is total by exact identifier and digest, and duplicate or shadowed declarations refuse. Unknown catalog
rows decode only to an opaque unavailable value. There is no runtime plugin loading or wildcard interpreter.

### 4.4 Project adapter

The project adapter owns the only conversion from local meaning to the kernel:

~~~text
validated project plan
  -> complete local workload requirement
  -> normalized generic requirement
  -> closed project operation identity
~~~

It also owns the one conversion back:

~~~text
kernel resource receipt
  + project lifecycle receipt
  -> project terminal result
~~~

There must not be several hand-maintained encoders of the same requirement or receipt. A conversion that
discards a brand, resource identity, mechanism strength, or failure case is a protocol defect.

## 5. Guarantee scopes and assurance profiles

### 5.1 Participating projects

The initial claim covers enrolled artifacts whose closed adapter paths use the exact core major and every
family and mechanism revision selected by their cell. A nonparticipant, stale binary, direct container
command, or ungoverned process is a foreign claimant.

Enrollment binds ProjectId and an operating-system principal to either an exact artifact digest or a trusted
build-signing and provenance policy. A pathname, argument vector, or self-reported digest is never artifact
identity. A development catalog may trust a project-local signer so ordinary rebuilds do not require catalog
migration; a production catalog may pin exact digests.

Foreign and permanently unmanaged demand is conservatively charged to the host reserve or causes admission
to refuse. Partial adoption is never described as whole-host control.

### 5.2 Whole host

Whole-host authority additionally requires evidence that every material claimant is contained or physically
partitioned. It refuses on an open workstation or whenever a foreign claimant can grow without an admitted
wall.

### 5.3 Progressive assurance

The authority type records the assurance actually established:

| Profile | What it establishes | What it cannot establish |
|---------|----------------------|--------------------------|
| CooperativeCellLease | Participating-project ownership of an exact cell and exclusive domains | Hard CPU, RAM, storage, or device-memory containment |
| EnforcedCellLease | Cooperative ownership plus every declared wall applied and read back | Automatic recovery of a persistent effect after holder failure |
| RecoverableExecutionAuthority | Enforced lease plus closed workload, durable intent, operation fencing, recovery, quarantine, and terminal cleanup evidence | Control over foreign or hostile host processes |

A lower profile cannot be relabelled or projected as a higher one. The cooperative profile is useful because
its weaker claim is explicit.

### 5.4 Resource-indexed mechanism strength

Mechanism strength is not one total ladder. A requirement names the acceptable mechanism set for each
resource dimension, and the registered satisfaction relation is total for that family.

| Strength | Honest claim |
|----------|--------------|
| AdmissionOnly | Capacity arithmetic and cooperative cell admission; no physical exclusion or wall |
| Exclusive | Kernel or hardware exclusion for one named domain; no scalar ceiling implied |
| Reactive | A bounded observer can detect and terminate after a breach; prevention is not claimed |
| HardCeiling | A native limit covers the named charged dimension before work starts and is read back |
| HardwarePartitioned | A disjoint physical child domain exists and conflicts with its registered ancestors |
| BoundedShared | One admitted aggregate mechanism enforces a finite shared cap and failure domain |

Exclusive, Reactive, and HardCeiling may be incomparable for different resources. An assurance profile joins
the complete set of required resource-specific mechanisms; no single mechanism name determines the profile.

## 6. Host and resource model

### 6.1 Observed host

An observed host joins independent axes:

- kernel backend: Darwin, Linux, or Windows;
- architecture;
- boot identity;
- root file identity;
- signed catalog identity and trusted signer;
- physical CPU and memory topology;
- storage domains;
- present resource families and their stable identities; and
- available enforcement and observation mechanisms.

Operating-system selection does not imply accelerator presence. Linux and Windows may be CPU-only
or expose CUDA-family domains. Apple hardware may expose Metal or a future Neural Engine family.
An absent family cannot yield a physical domain, lock key, lease, or authority.

### 6.2 Generic resource graph

Physical identities form a finite graph. A whole device conflicts with its partitions. Unified or
managed memory aliases every pool it can charge. A VM or container is an enforcement domain, not a
new physical resource.

Only real or installer-defined allocation identities have lock objects:

- logical cells have cell locks;
- physical parents and leaves have domain locks;
- scalar quantities such as memory bytes or IOPS are capacity supplied by a domain, not lock names.

### 6.3 Base cells

A base cell is a long-lived offer for persistent or ordinary project operation. It may contain CPU,
RAM, storage stock, process and descriptor slots, and project-owned service overhead. A base lease
can outlive the CLI only through a project-local anchor.

### 6.4 Turn cells

A turn cell is a predeclared, normally short-lived offer for a burst or exclusive family domain:

- a whole CUDA device;
- a MIG GPU Instance;
- one Metal device;
- a future Neural Engine allocation;
- or a conservatively serialized build/test burst.

The same anchor may acquire a turn while retaining its base. This is a distinct typed operation,
not arbitrary live growth. The catalog declares the legal base-plus-turn combinations, lock order,
and maximum number of turns. A multi-domain turn is acquired atomically.

### 6.5 Capacity law

For every legal concurrency epoch E:

~~~text
host reserve
  + sum(base offers live in E)
  + sum(turn offers live in E)
  <= observed physical capacity
~~~

Alias projection occurs before this inequality. Apple unified accelerator memory is charged once to
host memory. Persistent storage is a stock-flow quantity:

~~~text
current retained stock
  + maximum reachable net production
  + transient scratch
  <= reserved backing capacity
~~~

Ending compute does not release storage capacity for bytes that remain.

### 6.6 Admission slots and retry identity

A namespaced ProjectId is enrolled in the signed host catalog. Enrollment adds data, not a core constructor or
CoreMajor revision.

An admission slot is a finite operator-reviewed concurrency right. One default base slot per project is
conservative, but project cardinality is policy rather than the universal safety invariant. Additional slots
require catalog arithmetic for their possible concurrency.

An attempt key identifies one logical use of a slot. It can attach to or recover that use; it can never create
another slot, cell, or schedulable position.

## 7. Hardware and substrate extensibility

A resource-family projection is host-coordination metadata, not a replacement for a project's substrate
taxonomy. Each adapter maps its local substrate meaning into the generic projection once.

The reusable shape is:

~~~text
kernel lock and containment backend
  x architecture
  x resource-family declarations
  x mechanism-profile declarations
  x project demand adapter
~~~

It is not a closed sum of Apple Silicon, Linux CPU, Linux CUDA, and Windows products.

### 7.1 Unknown families and mechanisms

A client may use a cell only when it understands every family and mechanism selected by that cell. Unknown
rows are never ignored, wildcard-decoded, or downgraded.

An unknown row defaults to whole-catalog refusal whenever it may alias host memory, storage, a known device,
or an ancestor of an eligible cell. Cell-local refusal is permitted only when the signed catalog carries an
IsolationCertificate that the old CoreMajor can verify without unknown code. The certificate proves, using
only the generic graph, that the unavailable domains share no ancestor, alias, conflict edge, or capacity
dimension with any eligible known cell.

The catalog signer authenticates the projection and certificate. A family self-report does not. An unknown
unified-memory or shared-storage family therefore normally refuses the catalog; a physically disjoint child
may remain cell-local when the core-verifiable certificate establishes that fact.

### 7.2 Neural Engine example

A future Neural Engine family release supplies observed identity, unified-memory alias charge, physical
conflicts, invalidators, and generic projection laws. A separate Darwin mechanism profile states whether the
platform offers only admission, reactive observation, exact exclusivity, or a stronger partition.

If the platform exposes neither a hard wall nor a stable partition, the mechanism cannot advertise
HardCeiling or HardwarePartitioned merely because the device is present. A cooperative lease may still use
the exact domain lock at the weaker registered strength.

### 7.3 Initial resource and mechanism posture

- CPU, memory, storage, CUDA, and Metal form the initial family set.
- Linux cgroups may supply CPU and RAM HardCeiling rows after their hierarchy and effective values obtain the
  required live evidence.
- Darwin may supply cooperative CPU and RAM admission, exclusive Metal turns, unified-memory accounting, and
  honest reactive handling. Native hard descendant-memory claims refuse.
- Windows lock objects and Job Objects are mechanism profiles paired with CPU, memory, process, and handle
  resources. Creation-before-run, no-breakaway, nesting, and commit charge remain conformance obligations.
- Whole CUDA devices use Exclusive turns in the immediate profile.
- An admitted MIG partition profile may create HardwarePartitioned child domains.
- MPS remains a BoundedShared mechanism and is deferred until server generation, aggregate slots, crash
  failure domain, and quarantine are closed.
- Storage remains AdmissionOnly until reserved backing and an enforced quota or extent are both present.

## 8. Daemonless host coordination

### 8.1 Fixed root

Each kernel resolves one fixed local-machine root:

~~~text
Linux:  /var/lib/shared-host-resource-protocol
Darwin: /Library/Application Support/SharedHostResourceProtocol
Windows: FOLDERID_ProgramData/SharedHostResourceProtocol
~~~

The root is never repository-local, version-suffixed, path-search-derived, environment-selected, or created
as an ordinary runtime fallback. A container, WSL guest, or VM cannot substitute a guest-local file with the
same pathname for the host object.

### 8.2 Installed layout

~~~text
catalog.cbor
catalog.sig
locks/
  epoch.lock
  admission.lock
  slots/<id>.lock
  cells/<id>.lock
  resources/<family>/<domain>.lock
records/
  cells/<id>/page-{0,1}.cbor
  projects/<project>/<slot>/page-{0,1}.cbor
  receipts/<project>/<slot>/page-{0,1}.cbor
~~~

The installer creates every directory, lock, and fixed-size record page. The signed catalog binds its content
digest, core major, signer, enrollments, cells, resource and mechanism revisions, finite bounds, and every
permanent identity. A retired identity is never rebound to different semantics.

Each record is a bounded dual-page journal. A writer holding the required locks writes the inactive fixed
page, synchronizes it, and advances the monotonic generation by publishing a valid checksummed page. Readers
select the highest valid linked generation. A torn, conflicting, noncanonical, or generation-skipping pair
does not fall back to free state; it quarantines the cell.

Exhausted catalog slots or record generations produce a typed refusal and require an offline migration. No
runtime creates a new lock pathname or journal file.

### 8.3 Permissions

Catalog and lock directories are administrator-owned and participant-nonwritable. Participants may open the
exact precreated lock objects but cannot rename, unlink, replace, or privately shadow them. Workload
descendants receive neither protocol-group membership nor inherited handles.

Shared cell pages grant bounded write access to the exact enrolled operating-system principals because every
project must publish cell custody without a broker. Project, slot, and receipt pages are principal-isolated.
A conforming writer updates a cell page only while holding its cell lock; invalid bytes or a writer identity
mismatch fail closed to quarantine. The participating-project guarantee excludes a hostile process running as
an enrolled principal.

Windows uses the corresponding closed discretionary access-control list. Every platform validates each path
component, local filesystem, root identity, leaf identity, owner, and access profile. No privileged
host-global writer service is part of the protocol.

### 8.4 Kernel lifetime

Locks have no timeout lease. Process exit and reboot release kernel custody, but release authorizes recovery
or quarantine only. It never establishes that a cgroup, Job Object, VM, mount, container, service, storage
stock, or device context is absent.

## 9. Admission and acquisition

Every acquisition is nonblocking. Live lock upgrades and unplanned bundle expansion are forbidden.

1. Resolve and validate the fixed root.
2. Verify the signed catalog, enrollment policy, and exact client core major.
3. Take the permanent epoch object shared and retain it for the complete lease.
4. Decode the catalog and bind catalog generation, boot identity, root identity, family revisions, mechanism
   revisions, and ephemeral hardware or service identities into the effective epoch.
5. Derive the normalized requirement, closed workload identity, registered admission slot, stable attempt
   generation, and pure nonempty eligible-cell set.
6. Try the admission-slot lock. If it is busy, a matching attempt may attach through the authenticated
   project anchor or return a retained terminal outcome; another live attempt reports SlotBusy.
7. Take the short admission lock and rescan all cell records. A stale Held record may be changed only after
   the exact cell and domain locks are reacquired; it becomes Quarantined and remains unavailable. Subtract
   every held, nonterminal, or quarantined allocation before selecting an available eligible cell.
8. Acquire the cell lock and every required physical ancestor and leaf lock in one canonical all-or-nothing
   order. Release the partial set on contention.
9. Reobserve capacity, identities, foreign claimants, and mechanism availability.
10. Synchronize the record required by the requested assurance. Cooperative and finite enforced operations
    publish Held; recoverable operations publish Prepared with every planned external operation identity.
11. Release the short admission lock while retaining epoch, slot, cell, and domain locks.
12. For an enforced profile, create empty enforcement domains, apply every wall, and read back effective
    values. Refuse a value outside the admitted offer or below the requested strength.
13. Mint only the assurance value established by the preceding steps. The closed project interpreter consumes
    that value.
14. On clean terminal outcome, stop and reap owned work, establish the enclosing domains empty, settle retained
    storage ownership, synchronize the terminal record, and release locks in reverse order.
15. On unexpected holder loss, a later admission or recovery attempt converts stale Held to Quarantined
    under the exact locks before any launch. A recoverable record follows the recovery machine instead.

Pure planning returns eligible alternatives, not an already selected cell. Selection under the admission lock
produces fresh cell and offer brands for the continuation.

Busy diagnostics name the contended slot, cell, or domain where disclosure policy permits. A client may
perform bounded backoff or prompt the operator. Waiting never becomes lease expiry, fairness authority, or
permission to steal.

## 10. Project-local anchors and lifecycle

A Kind cluster, RKE2 control plane, VM, daemon, persistent service, or retained turn cannot borrow an
invoking CLI's lifetime. Its project anchor:

- is part of that project's own executable, not a shared scheduler;
- acquires its own handles before creating the effect;
- never receives transferred lock custody from another process;
- records exact project, slot, attempt, epoch, cell, process-birth, and endpoint identities;
- authenticates later clients through OS peer identity plus a claim-bound nonce;
- accepts closed project operations, never arbitrary executables, arguments, callbacks, manifests,
  or device names;
- keeps handles noninheritable by workload children; and
- remains until project cleanup establishes through runtime readback that the enclosing enforcement domain is empty.

Anchor IPC, UI, and supervision may evolve within a project. The shared ABI needs only the durable
identity, attachment outcomes, custody invariants, and recovery behavior necessary for another
participant to treat the cell as occupied.

The outer protocol is an admission and custody fence, not a second product lifecycle:

- it may stop and empty only the exact enclosing domain it created and owns;
- it invokes the project's authenticated inner recovery path when project resources need
  reconciliation;
- it never invents desired state or generic provider cleanup from descriptive records; and
- it quarantines when the inner result or external effect cannot be established.

## 11. Durable state and recovery

### 11.1 Cooperative and finite enforced records

The immediate machine is deliberately small:

~~~text
Free -> Held -> Free
          |
          +-> Quarantined
~~~

Clean terminal release is the only Held-to-Free transition. Process death, reboot, a torn record, an
unreconciled child, or uncertain retained output takes the cell to Quarantined before reuse. A cooperative
implementation does not claim automatic recovery.

A cooperative or finite enforced workload is foreground, non-detaching, and closed under one supervised
process or enforcement domain. Any retained output is precharged to a project storage reserve and is not
treated as released when compute ends. Asynchronous provider operations, persistent clusters, services, VMs,
mounts, and restartable containers require the recoverable machine.

### 11.2 Recoverable authority records

The recoverable cell-owned machine is:

~~~text
Prepared -> Applied -> Running -> Releasing -> Retired
     \          \          \           \
      +----------+----------+------------> Recovering
                                             |
                                      Retired or Quarantined
~~~

The cell current record is the machine-global recovery source. Project and slot records point to it; they do
not replace it. Admission treats every Prepared, Applied, Running, Releasing, Recovering, or Quarantined cell
as unavailable regardless of whether its old kernel holder remains live.

### 11.3 Delayed external effects

Observing an object absent is insufficient when an earlier asynchronous request may still complete. Every
such operation needs a durable identity and at least one of:

- a provider-enforced monotonic fence;
- a queryable operation established terminal or cancelled; or
- a barrier establishing that all earlier requests drained.

If the adapter cannot establish that the effect cannot materialize later, recovery quarantines the cell.

### 11.4 Reboot and restart

After reboot, stale numeric process identifiers are not probed as live ownership. Recovery still observes
persistent VMs, containers, services, mounts, quotas, partitions, retained storage, and device contexts.
Auto-restart must reacquire the same slot, attempt, epoch, cell, and domain locks before the consumer resumes.

### 11.5 Quarantine

Quarantine is a global admission fence for the cell and every overlapping physical domain. It has no time to
live (TTL). Clearing it is a privileged audited operation after exact absence or a controlled reprovisioning
boundary has been established.

## 12. Bounded idempotency and protocol storage

Attempt identity is a monotonic generation within a finite admission slot. The protocol retains:

- the current generation;
- a high-water floor below which every generation is permanently spent;
- a fixed-size recent receipt window;
- one bounded cell current record; and
- finite preallocated lock and journal slots.

Compaction may replace detailed old receipts with the high-water result. It cannot make an old
attempt fresh. Catalog-slot exhaustion, generation exhaustion, receipt saturation, or storage-budget
exhaustion refuses deterministically and names the required offline maintenance action.

Protocol metadata, anchors, observers, runtime overhead, and worst-case journal growth are charged
exactly once to the host reserve.

## 13. MISU boundary

The make-illegal-states-unrepresentable (MISU) target has this construction:

~~~text
Requirement + ClosedWorkload
  -> EligibleCells
  -> live BaseLease
  -> optional live TurnLease
  -> AppliedEnvelope
  -> ExecutionAuthority
  -> RunningAuthority
  -> ResourceReceipt
~~~

The target Haskell API specifies private constructors. Project, host, boot, epoch, slot, attempt, cell,
domain, requirement, offered profile, mechanism, and lifetime-region roles are nominal. Live capabilities are
specified as linear or otherwise single-consumption values inside a rank-bounded region. Child authorities
are checked splits of an already held parent and receive no host-lock constructor.

| Invalid state | Target foreclosure |
|---------------|--------------------|
| Project code forges or substitutes host, cell, epoch, or mechanism authority | Opaque generative nominal capabilities |
| Demand exceeds the cell or aliases are double charged | Total checked admission returns no Admitted value |
| Unknown family is treated as supported | No matching family witness; cell or catalog refuses |
| Two participants own the same cell or exclusive domain | Permanent kernel cell and domain locks |
| Work starts before required walls | Closed launcher requires the matching authority profile |
| A weaker mechanism is relabelled as stronger | Resource-specific satisfaction plus effective readback |
| Retry creates another schedulable slot | Attempt identity is subordinate to a finite installed admission slot |
| Child grows the live host bundle | Child has no host-lock constructor or interpreter route |
| Uncertain crashed state becomes reusable | Nonterminal or quarantined cell record globally fences admission |
| Receipt is reused as live authority | Receipt carries observations but no live capability |

These are specification claims until the owning project plan assigns the corresponding Haskell declarations,
compile-fail fixtures, changed-subject negatives, and runtime evidence. Kernel locks, operating-system
observations, walls, and recovery establish mutable external facts at runtime. Foreign-process behavior and
physical failure remain explicit limitations rather than type claims.

## 14. Versioning, governance, and DRYness

### 14.1 Core and family versions are separate

The root has one exact CoreMajor. Incompatible core majors contend on the same permanent epoch object and
cannot operate concurrently. The root path is never split into versioned namespaces.

Each cell separately pins exact resource-family and mechanism-profile digests. Adding a family or mechanism
does not change CoreMajor when its complete generic projection obeys the existing kernel. A client may refuse
only the unavailable cells when a signed core-verifiable isolation certificate separates them from every
eligible cell.

### 14.2 Independent semantic releases

The rare core release publishes:

- Haskell-owned protocol constants and types;
- canonical core encodings and positive and negative vectors;
- lock, dual-page record, and transition tables;
- core crash schedules; and
- the core release digest.

Each family and mechanism release is separately content-addressed. It publishes its Haskell declaration,
generic projection, interpreter pairing, laws, vectors, and release digest. Adding a Neural Engine family
therefore does not republish CPU, CUDA, Windows, or the core.

Canonical declarations, laws, and vectors are Haskell source. Serialized vectors and rendered protocol
artifacts are generated lazily beneath ignored `.build/**` paths and are never tracked behavioral inputs.

### 14.3 One governance authority

Before cutover, the standalone neutral repository is the only semantic release authority. The five project
documents carry local metadata, adoption notes, and exact release coordinates; synchronizing prose or its
digest is an editorial drift check, not an ABI.

After accepted amoebius cutover, amoebius generates and owns new core, family, and mechanism releases. The
neutral repository becomes an archived compatibility source only after no operational seed depends on it.

### 14.4 Seed reuse and amoebius independence

The default seed implementation is the neutral version-pinned Haskell kernel. It avoids one routine
implementation per seed for encoding, filesystem hardening, lock order, native object handling, journals, and
crash quarantine. Project-specific calculus and lifecycle do not enter that package.

amoebius does not import the neutral kernel. Its clean-room implementation supplies a differential boundary
and prevents the formal model from inheriting an implementation bug as an axiom. This bounded duplication is
intentional at the trust boundary.

### 14.5 Offline upgrade

A core or catalog migration:

1. stops new admission;
2. takes the permanent epoch lock exclusively;
3. establishes every current and delayed old effect absent or quarantined;
4. verifies every enrolled artifact needed after cutover;
5. records a durable migration intent;
6. applies one exact old-to-new schema transformation;
7. publishes a fresh non-ABA catalog epoch; and
8. makes old clients refuse deterministically.

No live lease is reparented, no lock object is replaced, and rollback is claimed only before the first
irreversible new-revision effect.

## 15. Project adoption boundaries

| Project | Retains during transition | Shared-protocol adapter responsibility |
|---------|---------------------------|----------------------------------------|
| amoebius | Global resource/workflow calculus, finite extension link-set, formal model, interpreters, and evidence laws | Re-derive the kernel independently; route adoption and evidence through its development plan; eventually generate and own releases |
| prodbox | Lifecycle Authority, Provider Worker, cleanup graph, local RKE2, and AWS desired state | Compile complete local-host demand; keep the anchor outside Lifecycle Authority; treat remote Elastic Kubernetes Service (EKS) nodes as foreign unless separately enrolled |
| hostbootstrap | ProjectPlan, Chain, HostCommand interpreter, ownership, prepared lifecycle, and bounded Python-to-Haskell handoff | Consume the neutral kernel behind a lifecycle-independent port; treat initial bootstrap as a weaker or excluded stage until separately governed |
| infernix | Artifact-derived demand, toolchain arithmetic, cluster ownership, typed plans, and capped engine launch | Make toolchain, platform, and engine authorities children of base or turn leases; use a host-native anchor across container boundaries; bind exact device identity |
| jitML | Compiled run graph, training, inference, tuning formulas, cluster/result lifecycle, and JIT device execution | Derive physical and storage demand; use a persistent base plus accelerator turns; remove all-device and raw-launch bypasses before conformance |

One project's diagnostic, receipt, or candidate evidence never validates another project's implementation or
promotes its plan status.

## 16. Adoption profiles and ownership cutover

### 16.1 Governance prerequisite

- Create a standalone product-neutral Haskell repository and package for the kernel.
- Assign human reviewers, release keys, identifier namespaces, and an offline decommission path.
- Freeze only the minimal core.
- Keep ProjectId enrollment in signed host-catalog data.
- Install a conservative signed catalog and permanent object namespace.
- Keep implementation order and status in each project's development plan.

The full repository copies remain proposals until this prerequisite yields a release. That release replaces
them with short pinned adoption views; no repository copy is a fallback semantic authority.

### 16.2 Immediate cooperative profile

- Enroll exact digests or trusted development signers and operating-system principals.
- Register the initial CPU, memory, storage-accounting, CUDA, and Metal families.
- Use direct cell and physical-domain locks with the minimal Held dual-page record.
- Serialize whole CUDA and Metal domains.
- Admit only foreground, supervised, non-detaching work with no asynchronous provider effect.
- Charge retained outputs to static project storage reserve rather than treating them as released.
- Convert unexpected holder loss or uncertain cleanup to global quarantine.
- Return typed Busy, Unsupported, and Quarantined outcomes.

This profile improves coexistence immediately. It claims participating-project exclusion, not hard
containment or automatic crash recovery.

### 16.3 Enforced local-host profile

- Compile complete local demand.
- Create empty enforcement domains.
- Apply and read back Linux CPU and RAM walls and any supported storage or process walls.
- Add Darwin and Windows profiles at their actual registered strengths.
- Issue EnforcedCellLease only when every requested mechanism row carries its required evidence.

Unexpected holder loss still quarantines. A finite enforced lease does not become recoverable authority.

### 16.4 Recoverable persistent profile

- Add authenticated project-local anchors.
- Use Prepared through Recovering cell records.
- Fence delayed operations.
- Reconcile reboot and service restart.
- Track bounded receipts and storage stock-flow.
- Reject raw governed-effect bypasses mechanically.

Only this profile issues RecoverableExecutionAuthority for a persistent cluster, VM, service, mount,
provider-mediated host effect, restartable container, or retained device turn.

### 16.5 Extension growth

The initial family set already supports whole-device CUDA and Metal exclusion. Later releases may add MIG
partition profiles, MPS bounded sharing, Neural Engine families, new storage mechanisms, or new hardware.
Each addition is independently content-addressed and leaves the core lifecycle unchanged.

### 16.6 amoebius ownership cutover

amoebius first completes its independent model and the validation ordered by its development plan. It then
publishes a compatible or explicitly migrated release. Seeds remain pinned to the final neutral compatibility
release until their workflows have been lifted.

As each workflow moves, its seed adapter retires and amoebius becomes its sole implementation owner. A seed
that must remain independently runnable after this point receives a deliberate seed-to-amoebius runtime
migration with its own plan and review. The neutral repository is archived only when no live seed relies on
it.

## 17. Conformance

### 17.1 Pure and serialization evidence

- bounded positive arithmetic and overflow;
- base and turn concurrency epochs;
- host reserve and storage stock-flow;
- alias closure and ancestor or child conflicts;
- exact family, mechanism, and strength satisfaction;
- finite-registry duplicate, shadow, and unknown-row refusal;
- deterministic encoding and noncanonical rejection;
- signed catalog and isolation-certificate verification;
- eligible-cell selection; and
- bounded generation and saturation behavior.

### 17.2 Compile-fail and repository-boundary evidence

- authority construction without observed identities;
- host, boot, epoch, project, slot, cell, domain, family, or mechanism substitution;
- region escape, authority reuse, and transition skipping;
- child self-acquisition or live bundle growth;
- weaker-strength relabelling;
- unrestricted effect lifting; and
- imports of private kernel, registry, backend, journal, or launcher constructors.

### 17.3 Lock, record, crash, and recovery evidence

- exact-object contention between independently built participants;
- signer or operating-system-principal mismatch;
- slot, cell, ancestor, and leaf ordering;
- partial acquisition rollback;
- replaced root, link, mount, file, endpoint, process, wall, device, or service identity;
- torn, conflicting, stale, wrapped, and generation-skipping dual pages;
- stale Held becoming Quarantined before reuse;
- every recoverable crash prefix around Prepared, Applied, Running, Releasing, and migration;
- provider completion after a premature absence observation;
- anchor death, reboot, and auto-restart;
- bounded metadata after many attempts; and
- quarantine whenever absence or terminal operation state cannot be established.

### 17.4 Live mechanism evidence

Every advertised kernel, family, and mechanism row needs external readback and a changed-subject negative:

- Linux cgroup and storage mechanisms;
- Darwin locks, exact Metal identity, unified-memory accounting, and reactive behavior;
- Windows locks, Job Objects, creation, breakaway, nesting, and handle behavior;
- exact CUDA identity exposure and empty-state evidence;
- exact MIG partition concurrency and ancestor conflict; and
- MPS server, slot, aggregate-cap, crash, and quarantine behavior.

Absent hardware means no claim for that row, not a vacuous pass and not a blocker for unrelated families.

### 17.5 Cross-project evidence

Exact artifacts from two or more implementation islands contend on the same real host objects:

- same cell refuses;
- disjoint cells may proceed;
- whole-device and descendant partition conflict;
- compatible partitions may proceed;
- same attempt attaches or returns its outcome;
- another attempt in the same finite slot reports busy;
- holder death leads to quarantine or qualified recovery before reuse; and
- incompatible CoreMajor clients contend on the permanent epoch object and refuse.

Each repository keeps its own oracle, candidate evidence, and human promotion authority.

## 18. Rationale for rejected topologies

### 18.1 Host-global daemon

**The problem.** Participating projects need one host-wide exclusion boundary.

**Why the obvious alternative fails.** A master process would become the mutable owner of fairness,
policy, lifecycle, recovery, upgrades, availability, and every project's release cadence.

**The rule.** Processes take permanent kernel objects directly; project-local anchors exist only
where a workload lifetime requires custody.

**What it forecloses.** No conforming design may require a shared scheduler or let one project's
anchor schedule, reconcile, or interpret another project's lifecycle.

### 18.2 Five full implementations

**The problem.** All participants must encode and recover the small interoperability boundary
identically without turning incidental duplication into policy drift.

**Why the obvious alternative fails.** Five copies of encoding, filesystem security, lock ordering,
Windows semantics, journal transitions, and crash recovery are neither DRY nor useful independence.

**The rule.** Seeds pin a kernel from one standalone neutral repository; amoebius maintains one deliberately
independent clean-room implementation.

**What it forecloses.** No seed owns another seed's protocol dependency. amoebius does not import the neutral
implementation or treat it as a proof oracle.

### 18.3 Present-day seed dependency on amoebius

**The problem.** amoebius must learn from evolving seed behavior without freezing that behavior
behind an incomplete abstraction.

**Why the obvious alternative fails.** A seed import from amoebius would make unfinished formal work
a prerequisite and feed the emerging abstraction back into the evidence from which it is derived.

**The rule.** Seeds pin a neutral release behind project-local adapters while amoebius independently
converges on the same observable protocol.

**What it forecloses.** No seed has a present source, build, package, runtime, or phase-order
dependency on amoebius; any later runtime cutover is an explicit migration.

### 18.4 Monolithic project cell

**The problem.** Persistent base capacity and short resource-heavy turns have different lifetimes.

**Why the obvious alternative fails.** One cell either monopolizes a GPU for the life of a cluster
or permits ungoverned mid-flight expansion when the GPU is acquired later.

**The rule.** A BaseLease retains persistent capacity and a nested TurnLease temporarily acquires
the additional compatible cell and domains.

**What it forecloses.** A live workload cannot expand outside its declared catalog graph or retain a
turn-only accelerator after the turn terminates.

### 18.5 Closed device union

**The problem.** New accelerators must join without editing the core lifecycle or making existing
clients reinterpret unknown hardware.

**Why the obvious alternative fails.** A closed CPU/CUDA/Metal union forces lock-step releases and
duplicates lifecycle logic for each operating system and accelerator.

**The rule.** A finite family projects physical capacity, while a separately registered mechanism profile
pairs enforcement and readback with that family and backend.

**What it forecloses.** No runtime plugin, stringly fallback, wildcard decoder, unknown-family downgrade, or
operating-system mechanism disguised as a resource family may manufacture support.

### 18.6 Progressive assurance

**The problem.** Immediate cooperative exclusion is useful, but it is weaker than containment and
durable recovery.

**Why the obvious alternative fails.** Calling a file lock complete authority overstates the
guarantee; requiring the final recoverable model before any sharing delays a safe incremental gain.

**The rule.** CooperativeCellLease, EnforcedCellLease, and RecoverableExecutionAuthority remain
distinct capabilities with monotone construction requirements.

**What it forecloses.** A project cannot relabel exclusion as a wall, a wall as crash recovery, or a
weaker receipt as a stronger authority.

### 18.7 Five synchronized policy authorities

**The problem.** Five explanatory copies can drift and cannot collectively own one release decision.

**Why the obvious alternative fails.** Treating byte-identical Markdown as authority makes an editorial digest
an executable policy source and leaves conflict resolution undefined.

**The rule.** One standalone neutral repository owns releases before cutover. Repository copies are
non-authoritative adoption views that record exact release coordinates.

**What it forecloses.** No project copy may mint a protocol revision, override another copy, or substitute its
prose digest for the Haskell release manifest.

## 19. Core-freeze governance record

The first core release record fixes:

1. the exact standalone repository, package identity, maintainers, and archival owner;
2. the human reviewers, release keys, signature algorithm, and key-rotation process;
3. the identifier-allocation rules for families and mechanisms;
4. the catalog enrollment rules for namespaced ProjectId values;
5. the exact native lock primitives and permanent path grammar;
6. the privileged installation, status, migration, quarantine-clear, and decommission commands;
7. the first conservative host reserve, admission slots, base cells, and turn cells;
8. the initial family and mechanism releases plus every unsupported row;
9. the finite dual-page sizes, generation bounds, receipt window, and saturation actions;
10. the project-anchor attachment rules for persistent effects; and
11. the offline transition from existing persistent state into anchored cells.

None requires a master daemon, a product-to-product package import, or an early seed dependency on amoebius.

## 20. Proposal disposition

The recommended policy is:

> Freeze a minimal kernel in a standalone neutral Haskell release. Keep project demand and lifecycle local.
> Coordinate through direct kernel locks and project-local anchors. Separate persistent base capacity from
> short resource turns. Add hardware through independent family and mechanism releases. Transfer ownership to
> amoebius only through an explicit validated cutover.

Until the core release, signed host catalog, implementation, and conformance evidence exist, these documents
remain proposals. Unsupported or unobserved claims fail closed.
