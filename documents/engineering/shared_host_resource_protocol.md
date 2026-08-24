# Finite Resource Execution Authority Protocol

> **Purpose**: Define the dependency-free host resource-cell, epoch-lock, idempotency, and recovery
> semantics that amoebius and its seed projects independently implement.
> **Read this if**: a host workload, resource-capacity projection, substrate interpreter, or
> accelerator extension needs authority to reserve and consume finite physical resources.

This document owns the outer cross-project execution-authority protocol and its universal semantic ABI.
Project-specific demand remains owned by the resource and workflow calculi routed through the
[engineering doctrine index](./README.md). The protocol is re-derived independently in amoebius and each seed;
neither the prose nor another repository's code is executable input. Every amoebius foreclosure below is a
target specification rather than validation evidence: Phases 29 and 32 owe the absent-accelerator and
capability-binding compile-fail declarations, Phase 51 owns the portable fake-boundary interpreter, and Phases
52–54 own the Linux, Darwin, and Windows live kernel-mechanism evidence. Phase and sprint status remain
unchanged until their existing human promotion gates are satisfied.

<details>
<summary>Link-graph metadata</summary>

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md
**Generated sections**: none

</details>

## TL;DR

- The four projects implement the same semantic protocol independently. There is no common package,
  service, daemon, executable policy document, or dependency on `hostbootstrap-core`.
- One algebra covers Darwin, Linux, and Windows. Kernel-specific lock and containment backends are
  closed interpreters beneath that algebra; accelerator presence is observed independently of the
  kernel, so a CPU-only host and a GPU host do not require duplicated lifecycle types.
- An operator installs one immutable host layout made of disjoint **resource cells**. A cell bundles
  CPU, RAM, storage, and accelerator resources; the sum of the cells plus the host reserve must fit
  the observed hardware.
- Locks name observed physical domains, never scalar quantities. CUDA device memory is capacity
  provided by an observed CUDA device or MIG GPU Instance, not a lockable object of its own; a host
  with no such domain cannot produce a CUDA lock key, lease, or execution authority.
- A project may launch governed work only after it holds the cell's kernel-backed locks and has
  applied and read back every required OS or hardware wall. A reservation without a wall and a wall
  without a reservation are both insufficient.
- There is no scheduling daemon. A short-held host-global admission lock makes multi-resource
  acquisition atomic; per-cell locks and project-owned lease anchors remain live for the workload.
- Concurrent use of one CUDA GPU is strict only through distinct hardware partitions, preferably
  MIG instances. A non-partitioned GPU is shared safely by taking turns under a whole-device lock.
  MPS is a separately typed bounded-sharing mode, not a synonym for contention-free execution.
- VMs are an optional realization of CPU, RAM, and storage cells. A VM does not manufacture a GPU
  partition; whole-device passthrough remains exclusive unless the virtualization stack supports
  the exact mediated or MIG-backed device.
- Each catalog registers a finite set of immutable parent scopes under a project; the default is
  one. One permanent, lifetime-exclusive parent-scope lock admits at most one live parent
  reservation in that scope. `ClaimKey` is recorded identity, not a lock pathname, so inventing a
  retry key cannot reserve a second cell. Parallel work splits the one held parent capability.
- Kernel locks have no timeout lease. Process death and reboot release them; the next acquirer
  reconciles the exact durable domain record before reuse, so recovery never waits for a TTL.

## Contents

- [Conformance boundary](#conformance-boundary)
- [The guarantee](#the-guarantee)
- [Contract layers](#contract-layers)
- [Resource graph and arithmetic](#resource-graph-and-arithmetic)
- [Closed workload and live admission](#closed-workload-and-live-admission)
- [Daemonless host protocol](#daemonless-host-protocol)
- [Epoch-lock ABI](#epoch-lock-abi)
- [Claim idempotency and recovery](#claim-idempotency-and-recovery)
- [Substrate profiles](#substrate-profiles)
- [One CUDA GPU shared by participating projects](#one-cuda-gpu-shared-by-participating-projects)
- [Haskell capability shape](#haskell-capability-shape)
- [Project-doctrine comparison](#project-doctrine-comparison)
- [Project adoption boundaries](#project-adoption-boundaries)
- [Interoperability freeze](#interoperability-freeze)
- [Validation](#validation)
- [Primary mechanism references](#primary-mechanism-references)

## Conformance boundary

This document specifies architecture; its Markdown bytes confer no runtime authority and are never
parsed as policy, a generator input, a semantic oracle, or a validation verdict. Cross-project
contention safety applies only to independently implemented adapters that pin the same semantic ABI
and pass the same laws. Repository-local metadata and backlinks may differ. A document-copy digest
may detect prose drift, but only separately reviewed Haskell declarations own protocol constants,
canonical encodings, satisfaction rules, and conformance vectors.

## The guarantee

The strict claim is deliberately narrower than "the host can never run out of resources":

> Participating project code cannot launch a governed operation unless the complete requirement
> fits one unallocated host cell, every lock target is an observed domain of that exact host, and a
> matching enforcement or exclusivity mechanism has been applied and re-observed for every resource
> the operation can consume.

An oversized **request** remains representable so it can produce a useful refusal. What must not be
representable is an `ExecutionAuthority` for a request larger than its leased cell, for a cell that
is not held, for a domain absent from the observed host, or for a resource whose required-strength
mechanism was not applied.

The guarantee has two explicitly indexed scopes. `ParticipatingProjects` covers only descendants of
the closed interpreters. `WholeHost` additionally requires evidence that every material claimant is
contained or that physical partitioning closes the world; it refuses on an open workstation where
foreign processes can grow without a wall. A reactive Apple or other weak lane may launch only when
its requirement explicitly accepts reactive enforcement. It cannot be relabelled as hard-bound, and
a requirement for a hard bound receives a typed refusal.

The guarantee covers cooperating project binaries and the closed launch paths they own. Advisory
file locks do not constrain a same-privilege process that ignores the protocol, and Haskell types do
not constrain an administrator or a foreign container runtime. Each project therefore keeps raw
process, VM, container, Kubernetes, and accelerator launch primitives behind its strict interpreter
and mechanically rejects bypasses.

"Without contention" has a resource-specific meaning:

- no admitted maxima oversubscribe RAM, storage, or device-memory capacity;
- no two leases concurrently own a resource declared exclusive;
- a hardware partition supplies only the isolation its substrate documents;
- shared CPU caches, memory bandwidth, PCIe, storage devices, thermal limits, and power limits are
  not constant-performance guarantees unless the layout gives them their own enforceable resource.

## Contract layers

| Layer | Produced from | What it proves | What it cannot authorize |
|-------|---------------|----------------|--------------------------|
| `ObservedHost kernel arch host capabilities` | Closed kernel backend plus exact CPU, volume, Metal, CUDA, and partition observations | A fresh generative host brand and the only capability-membership witnesses available on that machine | A capability absent from this inventory or reuse after reboot/topology change |
| `PhysicalDomain host capabilities domain` | A stable identity refined through the matching presence witness | The host really has this lockable host, CPU-set, volume, Metal-device, CUDA-device, or MIG-GI domain | A scalar lock or a domain on another host |
| `Requirement project req required` | Project-owned derivation and checked positive quantities | Complete peak and persistent demand, required strengths, and fixed sequential/parallel composition | Host admission or launch |
| `HostLayout host epoch` | Observed inventory, host reserve, disjoint cell catalog, and mechanism capabilities | Every cell is a non-overlapping slice of one physical resource graph | Ownership of a cell |
| `Admitted project req host epoch cell required offered` | Pure project-policy, fit, and strength satisfaction | The requirement is authorized, no larger than the cell, and asks for no stronger guarantee than the cell offers | A claim that the cell is still free |
| `RegisteredParent project host boot epoch parent` | `ProjectId`, validated layout, and finite operator-reviewed `ParentScopeId` registration; one scope per project by default | This parent scope and its permanent lock belong to this project in this exact host epoch | A caller-generated retry scope or ownership of resources |
| `ClaimKey project parent claim` | Stable adapter-derived logical workload identity recorded under its parent scope | Retries can identify the same logical attempt without selecting a lock object | Ownership of physical resources or a second parent slot |
| `Lease s project parent claim req host epoch cell required offered` | Lifetime-held epoch, parent-scope, ancestor, and leaf locks plus exact revalidation | This parent scope owns the cell once inside region `s` | Launch before walls exist, live bundle growth, or a second parent reservation in the scope |
| `AppliedEnvelope s project host epoch cell offered mechanisms` | Empty wall creation, exact identity binding, and effective-limit readback | Every resource has its exact mechanism and strength, including an honest weak classification | Launch without a hidden `Launchable` proof, or use for a different project, cell, epoch, profile, or region |
| `ExecutionAuthority s project parent claim req host epoch cell required offered mechanisms` | Exact admission joined to the exact live lease and envelope | The jointly branded closed workload may start inside this resource envelope | Arbitrary `IO`, raw spawn arguments, another parent scope, or another execution |
| `ResourceReceipt project parent claim req host epoch cell required offered mechanisms` | Terminal observation and release proof | Outcome, measured peaks, effective walls, cleanup, and identities | Reuse as live authority; the same claim key returns this receipt rather than launching again |

The project remains responsible for deriving its requirement. `amoebius` derives provision,
validation, build, deployment, observation, and teardown demand from its global workflow calculus;
`infernix` derives model memory from the artifact and execution shape; `jitML` derives training and
inference demand from the compiled run graph, replica count, and concurrency; `hostbootstrap`
derives bootstrap and lifecycle demand from the validated project plan. The protocol normalizes and
composes those facts but never replaces their domain-specific derivation.

## Resource graph and arithmetic

The host layout is a graph rather than a flat record. Stable physical identities name the roots:
host, filesystem or block device, NUMA/CPU topology, Metal registry identity, CUDA GPU UUID, and
accelerator partition UUID. Children name real partitions. Parent and child capacity cannot both be
allocated: a whole-GPU lease conflicts with every MIG child, and Apple GPU working memory aliases
host unified memory rather than creating a second pool.

Kernel, architecture, and hardware capabilities are independent axes. `Darwin`, `Linux`, and
`Windows` select lock and containment interpreters; observed physical domains select resource
availability. Linux or Windows may therefore be CPU-only or may expose CUDA, while the Apple-Silicon
profile exposes Metal and unified memory but no CUDA domain. A layout decoder resolves every raw
domain reference through the exact `ObservedHost`; one unresolved reference rejects the layout.

Only physical domains have lock keys. Host memory, device-memory bytes, CPU bandwidth, IOPS, and SM
shares are quantities offered by a domain and enforced inside its lease. In particular there is no
`CudaVramLock` constructor: an observed `CudaDevice` or `MigGpuInstance` supplies device-memory
capacity and yields the corresponding domain lock. A raw request may ask for CUDA on Apple and
receive `UnsupportedCapability`; no `PhysicalDomain`, `LockKey`, `Lease`, or authority can inhabit
that request's success path.

Every cell also carries an immutable project-owner or project-allowlist policy. A ring-fenced cell
names one project; a deliberately serialized shared cell may name several. Project identity comes
from an opaque adapter-owned witness, never caller-authored configuration text. Pure admission
checks that policy and brands the resulting cell with the project identity, while the common locks
still exclude two eligible projects from a serialized cell. One registered parent scope is the
default and strongest rule for each project on a host. An additional independently reserving scope
is an explicit operator-reviewed catalog weakening for a demonstrated independent role; its
possible concurrency is charged into the layout and its resource policy is either disjoint or
jointly admitted with every sibling scope. A `ClaimKey` can never create a scope.

All scalar arithmetic uses bounded unsigned integers in canonical base units: bytes, millicpu, CPU
period microseconds, IOPS, bytes per second, and integral accelerator slices. No floating point,
unit-bearing text, or unbounded multiplication appears at the protocol boundary. Provider or
filesystem rounding is pure and deterministic, is charged before admission, and is read back at the
effective rounded value; an adapter that cannot derive the rounding refuses it.

Requirement composition is fixed:

- sequential alternatives use a component-wise maximum;
- concurrent work uses a component-wise sum;
- replicas multiply every transient component with checked overflow;
- persistent baseline plus transient work uses `persistent + maximum concurrent transient`;
- a phase DAG enumerates every dependency-valid concurrency epoch, including separate compile,
  link, test, container, VM, device, recovery, evidence-retention, and cleanup stages;
- every spawned driver, compiler, linker, helper, runtime, and descendant belongs to the derived
  domain; raw caller-selected fan-out never reaches the interpreter;
- a parent grant may be split into children only when a hidden proof establishes that their sum and
  identity sets fit the parent;
- exclusive identities compose by disjoint set union, never by an integer "GPU count".

The layout inequality is checked once per catalog epoch; any unassigned residue joins the host
reserve:

```text
host reserve + sum(disjoint resource cells) <= observed physical capacity
```

The host reserve includes the operating system, the protocol's lease anchors, device/runtime
overhead, and ungoverned administrative work. A cell ceiling does not silently borrow that reserve.
Changing any capacity, partition identity, wall mechanism, or cell membership creates a new epoch.

## Closed workload and live admission

Static fit and live safety are different proofs. `Admitted` proves that a closed workload fits the
installed cell catalog. Immediately before lock acquisition and again after the locks are held, the
interpreter observes physical capacity, VM pledges, foreign claimants, available storage, and the
lane's health interlocks. Swap and compressor pressure are health/refusal evidence, never additional
RAM. Unknown upper bounds or an inventory/layout disagreement produce a typed refusal.

The closed workload and requirement share one generative brand. A parallelism choice is part of that
workload, not a flag detached from its arithmetic. Alternative smaller plans are derived and admitted
as distinct values before acquisition; the interpreter never silently turns an admitted P20 program
into a P1 program. A sampled or reactive mechanism may stop governed descendants on pressure, but
sampling never upgrades an admission-only or reactive profile into a hard ceiling.

## Daemonless host protocol

Each kernel adapter resolves one ABI-fixed host coordination root: Linux uses
`/var/lib/finite-resource-authority`, Darwin uses
`/Library/Application Support/FiniteResourceAuthority`, and Windows resolves
`FOLDERID_ProgramData` through the Known Folder API and appends
`FiniteResourceAuthority`. It is never version-specific, repo-local, PATH-derived, read from an inherited
environment value, or created as a runtime fallback. Installation establishes a local
APFS/ext4/XFS/NTFS/ReFS root. POSIX ownership is `root:finite-resource-authority` with directory
mode `0770` and regular-file mode `0660`; Windows grants the local
`FiniteResourceAuthorityUsers` group the closed DACL needed for protocol I/O and denies replacement
to ordinary participants. Runtime verifies owner, permissions, filesystem locality, root identity,
and every opened leaf identity.

A container, WSL guest, or VM delegates leasing to a host-side project anchor. A bind mount is
accepted only when file identity proves that it exposes the exact host objects. A guest-local file
with the same pathname is never equivalent, and a WSL `flock` cannot arbitrate a Windows
`LockFileEx` resource.

The root contains `layout.cbor`, immutable lock objects under `locks/`, and durable allocation
records under `allocations/`. Each scope has one fixed `allocations/parents/<digest>.cbor` current
record; terminal claim receipts or compacted spent-key tombstones live below `allocations/receipts/`
and are storage-accounted protocol state. Lock objects include `epoch.lock`, `admission.lock`, exactly one
`parents/<digest>.lock` for every catalog-registered `ParentScopeId`, and hierarchical
`resources/<kind>/<digest>.lock` objects for observed physical domains. `ClaimKey` never selects or
creates a pathname. The installer initializes this finite set; a catalog mutation may append a new
object, but every retired object remains an immutable tombstone and is never renamed, unlinked,
truncated into replacement, reused for another identity, or recreated by recovery. These files are
host-local operator/runtime state, never version-controlled repository inputs. Layout and journal
values use deterministic CBOR; their separately pinned Haskell schema and golden vectors, rather
than this Markdown, define field tags and canonical bytes. File identity is observed in addition to
pathname so replacement or a private bind mount fails closed.
The mere existence of an old tombstone does not mint `Present`, `PhysicalDomain`, or `LockKey` and
cannot represent capacity in the current epoch. A never-CUDA Apple host therefore has no CUDA
resource object, while a host from which a device was removed may retain only an inert file identity
that no successful typed path can consume.
Protocol version lives inside the layout and journal, never in the root or lock pathname. An old
and a new binary therefore contend on the same permanent epoch object before either can accept or
refuse a version; a `/v1` versus `/v2` lock-root split is forbidden.

Acquisition follows this order; every lock operation is nonblocking and lock upgrades or expansion
of a live bundle are forbidden:

1. Resolve and validate the coordination root; take `epoch.lock` shared and retain that exact kernel
   object for the complete anchor/lease lifetime.
2. Decode the layout, verify its canonical digest, observe the named hardware identities, and prove
   that the catalog still describes them. The effective host epoch binds the protocol ABI digest,
   root file identity, catalog revision and nonce, boot identity, and ephemeral hardware/service
   identities.
3. Derive the project requirement, catalog-registered `ParentScopeId`, and stable `ClaimKey` from
   adapter-owned witnesses. Normalize an alias-closed nonempty domain set, reject duplicates and
   ancestor/child overlap, and derive eligible `Admitted` alternatives without claiming one is free.
4. Acquire that scope's permanent parent lock exclusively. If it is held, a same-key retry returns
   `AlreadyActive` or authenticates to the existing anchor; a different key returns
   `ParentScopeBusy`. Neither path attempts another cell. After crash release, the next holder must
   reconcile the scope's current-claim record and exact old domain bundle before replacing its key
   or selecting a new cell.
5. Only after the scope record is clean, take `admission.lock` exclusively for the short join,
   re-evaluate the eligible alternatives, select exactly one cell, and acquire it and every
   required ancestor/leaf resource lock in canonical key order, all-or-nothing. A leaf lease takes
   shared ancestor locks and an exclusive exact-leaf lock; a parent-resource lease takes that
   parent's lock exclusively. A strict MIG cell takes a shared physical-GPU ancestor lock and an
   exclusive GI lock; a Compute Instance inside that GI is recorded for exposure but is not a
   cross-project leaf. Release every partial resource set on refusal while retaining the parent
   lock only for the bounded decision or recovery path.
6. Re-observe live capacity and the selected physical identities. An unlocked record is not enough
   to declare a resource free: the bound cgroup, VM, mount, process group, Job Object, or device use
   must be proven absent or empty.
7. Synchronize a prepared intent naming the project, parent scope, claim, cell, epoch, anchor
   identity, complete resource bundle, and planned effects before the first wall mutation, then
   release `admission.lock`. Create the enforcement domains while empty, read every effective wall
   back, and atomically settle the intent into a record bound to their observed identities. Refuse
   upward rounding, missing limits, identity changes, and weaker mechanisms.
8. Mint the execution session and let the closed interpreter start only the workload described by
   the admitted requirement.
9. On terminal outcome, stop and reap owned work, prove each enforcement domain empty, retire the
   durable record, synchronize its directory, then release resource locks, parent-scope lock, and
   epoch lock in that order.

The durable state machine is `Prepared -> Applied -> Running -> Releasing -> Retired`; recovery may
move a nonterminal state to `Recovering` and then `Retired` or `Quarantined`. A crash in any
nonterminal state makes the effect outcome unknown: recovery re-observes every deterministic domain
identity and either completes the transition, cleans it conditionally, or quarantines the cell.
Absence of a settled record never proves absence of an effect. POSIX replacement synchronizes a new
sibling, renames it, and synchronizes the parent directory. Windows flushes the new file and uses a
same-volume write-through replacement before readback.

The admission lock is not held while work runs. It serializes the short mutation that joins several
resource locks and durable state. Per-cell locks carry lifetime ownership, so there is no
protocol-owned host-global admission daemon. Substrate services such as NVIDIA MPS and project-owned
per-lease anchors may still exist.

A Kind cluster, VM, host daemon, validation matrix, or training service cannot borrow the invoking
CLI's lifetime. One project-owned per-parent-scope anchor starts first and acquires every lock
itself before creating a domain; no process unlocks and transfers custody. Lock descriptors and handles are
noninheritable by workload children. The anchor retains them until the domain is empty and cleanup
is proven. A PID file alone is not authority; recovery uses the kernel lock plus boot, process-birth,
namespace, and substrate-object identities. If identity or absence cannot be proved, recovery
quarantines the cell rather than stealing it.

Catalog mutation takes the epoch lock exclusively. Successful acquisition proves that no conforming
parent lease is live, but it does not prove that crash-created effects are absent. The mutator scans
all nonterminal scope, lease, and prior-mutation records; acquires every implicated fixed parent lock
in canonical order; takes the admission lock; acquires the union of recorded resource locks in
canonical order; and proves each exact cgroup, Job Object, process group, VM, mount, quota, and
device effect absent or settles it. Any unexpected lower-lock contention, unknown effect, or
identity mismatch aborts and quarantines rather than publishing a catalog. A topology change such
as MIG reconfiguration also writes and synchronizes a `Prepared` mutation intent, holds the physical
ancestor lock, performs the change, and re-observes it before publishing a fresh non-ABA catalog
revision and epoch. This makes resizing an offline host operation and prevents an old binary from
continuing under a new interpretation of the same cell name.

## Epoch-lock ABI

`epoch.lock` is one permanent object across all catalog revisions. Every workload lease holds a
shared, nonblocking lock for its entire lifetime; layout creation, resizing, mechanism changes, and
hardware repartitioning take an exclusive, nonblocking lock on the same object. Exclusive
acquisition therefore proves that no conforming old-epoch lease remains. Upgrades are forbidden.
Deleting or replacing a lock object is never recovery: an old holder and a new pathname would form
two lock namespaces.

| Host kernel | Exact epoch-lock implementation |
|-------------|---------------------------------|
| Darwin | Open the permanent regular file with `openat`, `O_NOFOLLOW`, `O_CLOEXEC`, and read/write access; verify local APFS plus `(st_dev, st_ino)`; use `flock(fd, LOCK_SH | LOCK_NB)` for a lease and `flock(fd, LOCK_EX | LOCK_NB)` for mutation; retain the descriptor in the anchor and recheck identity after locking. Boot identity is the bounded read-only `kern.bootsessionuuid`. |
| Linux | Use the same no-follow, close-on-exec, `(st_dev, st_ino)`-verified BSD `flock` protocol on local ext4/XFS. The exact open-file description remains in the anchor until release. Boot identity is `/proc/sys/kernel/random/boot_id`; process identity additionally binds PID-namespace device/inode, PID, and `/proc/<pid>/stat` start time. POSIX `fcntl`/`lockf` is a different namespace and is forbidden for protocol locks. |
| Windows | Resolve the permanent NTFS/ReFS object below `FOLDERID_ProgramData`; open it with `CreateFileW(OPEN_EXISTING)` as a noninheritable, non-reparse handle, sharing read/write but not delete; verify `FILE_ID_INFO` volume serial and 128-bit file ID. `LockFileEx` locks byte `[0,1)` with `LOCKFILE_FAIL_IMMEDIATELY`; omit `LOCKFILE_EXCLUSIVE_LOCK` for shared and include it for exclusive. Release the exact range with `UnlockFileEx`, then close. A short bounded retry may cover delayed kernel cleanup after process termination; exhaustion refuses and never replaces the file. Under a separate permanent `boot-init.lock`, the first participant creates/opens ACL-protected `HKLM\\Software\\FiniteResourceAuthority\\BootSession` with `REG_OPTION_VOLATILE` and stores a 256-bit `BCryptGenRandom` nonce; every participant reads back that nonce as boot identity. |

The parent, admission, and resource lock objects reuse this exact kernel backend and identity check;
they do not introduce substrate-specific lifecycle variants. A parent scope and `admission.lock` use
exclusive mode. Resource ancestors use shared or exclusive mode exactly as the hierarchy requires,
and every Windows object uses the same byte `[0,1)`. This is one lock algebra interpreted three
ways, not three independently evolving protocols.

Every acquisition uses one freshly opened private descriptor or handle, and a private in-process
registry keyed by observed file identity rejects reentrant or duplicate acquisition. This closes the
Windows same-handle shared/exclusive overlap rule and the POSIX duplicate-descriptor lifetime trap.
Workload children inherit none of these objects. Normal release explicitly unlocks once and closes;
linear state prevents a second unlock, while crash/reboot cleanup remains kernel-owned.

The epoch value itself is a digest of protocol ABI, root identity, durable catalog revision and
nonce, boot identity, and every ephemeral partition or service identity. Reboot, MIG recreation,
MPS-server replacement, Metal boot-scoped device identity change, root replacement, or catalog
mutation therefore invalidates every old authority even when a display name is reused.

## Claim idempotency and recovery

Each catalog registers a finite set of `ParentScopeId`s beneath a `ProjectId`; one is the default.
Exactly one permanent lock object and current-claim record belong to each registered scope.
`ClaimKey` is stable for one logical workload inside that scope; it does not create a lock path.
`AttemptGeneration` increments while the parent lock is held. The durable scope record maps exactly
one `(ProjectId, ParentScopeId, ClaimKey, generation)` to one cell, anchor, domain set, and lease
nonce. A retry with the same key must observe or authenticate to the live anchor, return its retained
terminal receipt, or reconcile its stale generation before cell selection. Reusing a completed key
returns that receipt and cannot start another reservation; an intentional rerun requires the adapter
to mint the next durable logical-attempt identity before acquisition. Receipt compaction may discard
detail only after retaining a durable spent-key tombstone, so an old key never becomes new again. A different key while the
scope is live returns `ParentScopeBusy`. Inventing either kind of key cannot reserve another parent
cell. Parallel work inside one persistent cell consumes checked child splits from its one anchor;
children inherit no lock handles and never reacquire host locks.

Kernel lock release after exit or reboot authorizes reconciliation, not immediate reuse. The next
acquirer takes epoch and parent locks, reads the exact prior bundle, then under the short-held
admission lock takes those normalized resource locks before following a bounded idempotent path:

1. If the exact recorded anchor identity is live while its locks were acquired, quarantine the
   invariant violation.
2. On the same boot, identify descendants without PID reuse, then stop and reap only the exact owned
   domain. Linux uses namespace/start-time recheck followed by pidfd operations and `cgroup.kill`;
   Darwin uses the boot-scoped process-birth registry and exact process-group pin; Windows relies on
   a noninherited Job Object with `KILL_ON_JOB_CLOSE`, binds every recorded PID to its
   `GetProcessTimes` creation time through a live process handle, and verifies the job's descendants
   gone rather than trusting numeric PID reuse.
3. After a reboot, skip stale PID probing but still observe persistent VMs, containers, quotas,
   mounts, MIG/MPS configuration, device attachment, and retained storage. Reconcile only identities
   named by the record. Governed VM/container restart policies, launchd/systemd tasks, Windows
   services, and MPS clients either disable auto-resume or route it through a boot anchor that
   reacquires the same claim, epoch, and resource locks before starting the consumer.
4. Read back every domain empty/absent, including the exact vendor device/context allocation
   returning to its admitted settled state, settle `Retired`, and only then mint a new generation.
   Recovery never resets a physical GPU while a sibling partition may be live and never replaces an
   MPS server without its service lock plus proof that every slot is idle. An inaccessible
   namespace, changed identity, uncertain effect, or failed cleanup settles
   `Quarantined`; no TTL, lock-file deletion, or PID-only signal may steal it.

Each catalog fixes a small `RecoveryBudget` for bounded observations and conditional cleanup. Kernel
lock release makes recovery eligible immediately, so there is no lease-expiry delay; exceeding the
budget returns an attributed quarantine/refusal and a deterministic operator remedy rather than
spinning, waiting for a TTL, or starting competing work.

## Substrate profiles

| Resource | Strict realization | Weaker realization and required classification |
|----------|--------------------|-----------------------------------------------|
| Linux CPU | Disjoint exclusive cpuset partitions when exclusive cores are required; optionally pair with `cpu.max` | `cpu.max` is a hard bandwidth ceiling, not a reservation of execution time |
| Linux RAM | Static cell tokens whose sum excludes host reserve, plus cgroup-v2 `memory.max` and `memory.swap.max`, read back before launch | `memory.min` or an availability sample is not an independent hard reservation |
| Windows process tree | Create the target suspended into a unique Job Object before its first allocation; apply/read back job committed-virtual-memory, active-process, CPU-rate/affinity limits and `KILL_ON_JOB_CLOSE` | The memory mechanism satisfies only the explicitly charged job-commit profile, not a physical-RAM/working-set bound; ordinary affinity excludes no foreign task; WSL's per-user utility VM is one host-level cell, not one independently bounded cell per distribution |
| Darwin process tree | Exact anchor/process-group birth identities, derived concurrency, live admission, and pressure-triggered supervised termination | Native Darwin has no accepted aggregate descendant-RAM wall; hard-bound requirements refuse or run in a separately accepted bounded substrate |
| Storage capacity | Dedicated thick extent, or a reserved pool paired with an enforced filesystem/project quota | A sparse disk maximum or quota without admitted backing capacity is only a ceiling |
| Storage throughput | Dedicated device/partition or a provider that supplies a reserved share plus an `io.max`-style wall | IOPS/BPS ceilings alone do not reserve throughput |
| Whole CUDA GPU | On any kernel whose closed observer supplies CUDA, use an exclusive physical-GPU UUID lock plus exact device exposure | Default multi-context access, a VRAM estimate, and scheduler time-slicing are access mechanisms, not isolation |
| CUDA MIG | Distinct observed GPU Instance (GI) per project, with its Compute Instance identity, hardware memory/compute partition, and exact device exposure | Sibling Compute Instances inside one GI share that GI's memory and engines; an integer GPU count identifies neither partition nor VRAM |
| CUDA MPS | Finite client-slot set, pre-initialization/read-back memory caps, capability-proven static SM allocation, exact server identity, and aggregate admission including server/device reserve | Dynamic caps or active-thread percentages alone are bounded sharing, not dedicated compute/VRAM |
| Apple Metal | No native hard RAM/Metal wall satisfies the strict consumption profile; an exclusive device token prevents cross-project GPU overlap and charges working memory to unified RAM | Metal working-set and MLX limits are admission/detection guidance; authority requiring a hard wall or strict concurrent sharing is refused |
| VM | Host cell acquired before VM creation, fixed guest RAM, host-side wall, pinned/accounted vCPU plus emulator/vhost threads, no ballooning/dynamic growth, and thick/reserved storage | Guest-visible RAM/vCPU sizing alone does not prove aggregate host admission or dedicated CPU; device passthrough remains a child of the exact host device lease |

Docker, Compose, Kubernetes requests/limits, and device-plugin resources are render targets of an
already admitted cell. They do not become the host-global authority: separate schedulers cannot see
one another, and selecting a device does not by itself reserve its memory or compute.

CUDA managed/unified allocations may migrate or oversubscribe physical device memory. A strict
CUDA profile either forbids them in the closed workload, accounts for every charged host/device
pool with a matching mechanism, or refuses the strict profile.

## One CUDA GPU shared by participating projects

The preferred concurrent layout assigns distinct MIG GPU Instances to participating projects. Each
cell names its exact GI and Compute Instance identities, device-memory capacity, compute slice, host
pinned-memory allowance, and host-side CPU/RAM/storage envelope. Sibling Compute Instances under one
GI are not cross-project VRAM partitions because they share the GI's memory and engines. No child
cell receives the parent GPU device.

Where supported and deliberately accepted, an MPS layout may give each project a static SM
allocation and a finite set of client slots. It must prove:

```text
sum(effective device-memory cap for every configured slot authorized to start concurrently)
  + MPS server/context/device reserve
  <= admitted device-memory capacity
```

Each configured slot authorizes exactly one capped client/context, and dormant authorized slots are
included in the sum. The closed launcher refuses extra clients, configures each limit and static
partition before CUDA initialization, reads back effective values, and excludes foreign or non-MPS
contexts. Driver and
hardware capability, control-server identity, partition identities, and client-slot count are epoch
inputs. If an upstream CUDA runtime exposes a required control only through its child environment,
the project needs a narrow typed construction seam for that fixed upstream interface; a repository
that cannot admit such a seam refuses MPS. MPS remains typed as bounded shared execution because
memory bandwidth, copy engines, PCIe, thermal behavior, and other device-wide facilities may remain
shared. Its control server is a substrate mechanism, not a project admission coordinator; the
static layout and OS locks still own cross-project admission.

On hardware without an accepted partition mechanism, participating projects use the same GPU at
different times. They acquire the physical-GPU lock exclusively while keeping CPU-side clusters or
services alive. The protocol forbids an all-devices launch and passes only the granted UUID to the
closed runtime adapter.

A VM-per-project layout does not change these choices. Concurrent assignment requires a
virtualization-stack-supported MIG-backed vGPU or mediated device for the exact GPU, driver,
hypervisor, product, and licence combination; otherwise pass the whole GPU to exactly one live VM
under the same exclusive device lock.

## Haskell capability shape

The following is a shared interface sketch, not a package that one repository imports. The
`project` brand comes from an adapter-owned `ProjectId`; `requirement` is minted jointly for
derived demand and its closed workload; `required` and `offered` brand complete
per-resource strength profiles; and `mechanisms` brands the exact applied/read-back bundle.
Strengths have a resource-specific satisfaction relation, not a global ordering: exclusivity, a
ceiling, a reservation, and a hardware partition are not generally interchangeable.

```haskell
-- Example: one algebra, with presence and authority indexed by the observed host.
data Kernel = Darwin | Linux | Windows
data Architecture = Arm64 | X86_64
data Scope = ParticipatingProjects | WholeHost

data Capability
  = CpuBandwidth | ExclusiveCpuSet | HostMemory | UnifiedMemory
  | StorageBytes | StorageInodes | StorageIo | ProcessSlots | FileDescriptors
  | MetalExecution | CudaExecution | CudaDeviceMemory | GpuSms | PinnedHostMemory

data DomainKind
  = HostDomain | CpuPartition | StorageVolume
  | MetalDevice | CudaDevice | MigGpuInstance

data Strength
  = DetectionOnly | AdmissionOnly | ReactiveTermination | BoundedShared | HardCeiling
  | ExclusiveUse | ReservedAndCeilinged | HardwarePartitioned

data Phase = Leased | Enforced | Running | Releasing

-- Opaque declarations; every phantom role is nominal.
data ProjectId project
data ParentScopeId project
data RegisteredParent project host boot epoch parent
data ClaimKey project parent claim
data ResourceProfile profile
data MechanismProfile mechanisms
data Requirement (scope :: Scope) project workload required
data ClosedWorkload project workload required

data ObservedHost
  (kernel :: Kernel) (arch :: Architecture) host boot capabilities
data NativeSupport
  (kernel :: Kernel) (arch :: Architecture) (capability :: Capability)
data Present host boot capabilities (capability :: Capability)
data PhysicalDomain
  host boot capabilities (domain :: DomainKind)
data Provides
  host boot capabilities domain (capability :: Capability)
data LockKey host boot epoch capabilities (domain :: DomainKind)
data ParentLockKey host boot epoch project parent

data HostLayout kernel arch host boot epoch capabilities
data Cell project host boot epoch capabilities cell offered
data Satisfies required offered
data Launchable required offered mechanisms
data Admitted
  scope project workload host boot epoch capabilities cell required offered
data Lease
  s scope project parent claim workload host boot epoch capabilities cell required offered
data AppliedMechanism
  s project host boot epoch capabilities cell mechanisms
  (capability :: Capability) (strength :: Strength)
data AppliedEnvelope
  s project host boot epoch capabilities cell offered mechanisms
data ExecutionAuthority
  s scope project parent claim workload host boot epoch capabilities cell required offered mechanisms
data RunningAuthority
  s scope project parent claim workload host boot epoch capabilities cell required offered mechanisms
data Program
  s scope project parent claim workload host boot epoch capabilities cell
  required offered (phase :: Phase) result
data ResourceReceipt
  scope project parent claim workload host boot epoch cell required offered mechanisms
data ResourceBackend kernel arch host boot epoch capabilities cell offered

type role ProjectId nominal
type role ParentScopeId nominal
type role RegisteredParent nominal nominal nominal nominal nominal
type role ClaimKey nominal nominal nominal
type role ResourceProfile nominal
type role MechanismProfile nominal
type role Requirement nominal nominal nominal nominal
type role ClosedWorkload nominal nominal nominal
type role ObservedHost nominal nominal nominal nominal nominal
type role NativeSupport nominal nominal nominal
type role Present nominal nominal nominal nominal
type role PhysicalDomain nominal nominal nominal nominal
type role Provides nominal nominal nominal nominal nominal
type role LockKey nominal nominal nominal nominal nominal
type role ParentLockKey nominal nominal nominal nominal nominal
type role Satisfies nominal nominal
type role Launchable nominal nominal nominal
-- HostLayout, Cell, Admitted, Lease, Applied*, *Authority, Program,
-- ResourceReceipt, and ResourceBackend likewise declare every index nominal.
```

Constructors and existential wrappers remain private. `NativeSupport` is a closed relation with no
Darwin CUDA constructor and no Linux/Windows Metal constructor. Only the closed observer,
jointly consuming the matching `NativeSupport` and a real hardware observation, mints `Present`,
`PhysicalDomain`, and `Provides`; a CPU-only Linux or Windows observation simply lacks GPU presence.
`LockKey` is derived from an exact `PhysicalDomain`, never from a capability tag, quantity, or
caller text. Thus `CudaDeviceMemory` can be named in a raw request but cannot produce an Apple-host
lock or authority. `ParentLockKey` is the distinct, finite catalog identity for a registered
`ParentScopeId`; only a matching `RegisteredParent` can resolve it, and it is never accepted as a
physical-resource lock. `withClaimKey` validates stable logical-attempt bytes but cannot register a
parent. Reboot or topology change also changes the `boot` or `epoch` brand.

An `Admitted` value contains the hidden `Satisfies required offered` proof. A
`MechanismProfile` is a finite bundle of capability-indexed `AppliedMechanism` proofs, so a reactive
Metal observer or MPS cap cannot be coerced into a hard or exclusive mechanism. `Launchable` is a
resource-specific relation to the exact requested strength, not a global strength ordering. An
explicitly reactive requirement may therefore yield only an explicitly reactive authority; a hard
request on that same host refuses. `WholeHost` additionally requires a closed-world witness.

The pure layer jointly brands a demand with the only workload that may consume it, then validates
the immutable project policy and fit:

```haskell
-- Example: pure planning; eliminators preserve fresh brands.
withDerivedWorkload
  :: ProjectId project
  -> RawDerivedWorkload
  -> (forall workload required.
        Requirement scope project workload required
        -> ClosedWorkload project workload required
        -> result)
  -> Either RequirementError result

withPhysicalDomain
  :: ObservedHost kernel arch host boot capabilities
  -> RawDomainRef
  -> (forall domain.
        PhysicalDomain host boot capabilities domain
        -> result)
  -> Either UnsupportedCapability result

withValidatedLayout
  :: ObservedHost kernel arch host boot capabilities
  -> RawLayout
  -> (forall epoch.
        HostLayout kernel arch host boot epoch capabilities
        -> result)
  -> Either LayoutError result

withRegisteredParent
  :: ProjectId project
  -> ParentScopeId project
  -> HostLayout kernel arch host boot epoch capabilities
  -> (forall parent.
        RegisteredParent project host boot epoch parent
        -> result)
  -> Either ParentRegistrationError result

withClaimKey
  :: RegisteredParent project host boot epoch parent
  -> DurableLogicalAttempt
  -> (forall claim. ClaimKey project parent claim -> result)
  -> Either ClaimIdentityError result

withAdmitted
  :: Requirement scope project workload required
  -> HostLayout kernel arch host boot epoch capabilities
  -> (forall cell offered.
        Admitted scope project workload host boot epoch capabilities cell required offered
        -> result)
  -> Either AdmissionRefusal result

concurrent
  :: Requirement scope project left leftRequired
  -> ClosedWorkload project left leftRequired
  -> Requirement scope project right rightRequired
  -> ClosedWorkload project right rightRequired
  -> (forall combined required.
        Requirement scope project combined required
        -> ClosedWorkload project combined required
        -> result)
  -> Either ArithmeticError result
```

The sequential and replica combinators have the same joint-eliminator shape: they mint a fresh
requirement/workload brand while applying component-wise maximum or checked multiplication. No
public existential wrapper exposes a proof constructor, and composition never detaches arithmetic
from executable shape.

The effectful layer interprets a closed, linear program. `ResourceBackend` has no public
constructor and is not a record of caller-supplied callbacks. There is deliberately no `LiftIO`
constructor and no callback that receives raw command, container, VM, or device arguments:

```haskell
-- Example: the sole effect interpreter encloses locks, walls, launch, and cleanup.
withExecutionSession
  :: RegisteredParent project host boot epoch parent
  -> ClaimKey project parent claim
  -> Admitted
       scope project workload host boot epoch capabilities cell required offered
  -> (forall s.
        Lease
          s scope project parent claim workload host boot epoch capabilities cell required offered %1
        -> Program
          s scope project parent claim workload host boot epoch capabilities cell
          required offered 'Leased result)
  -> IO (Either ProtocolFailure result)

applyEnvelope
  :: Lease
       s scope project parent claim workload host boot epoch capabilities cell required offered %1
  -> (forall mechanisms.
        ExecutionAuthority
          s scope project parent claim workload host boot epoch capabilities cell
          required offered mechanisms %1
        -> Program
          s scope project parent claim workload host boot epoch capabilities cell
          required offered 'Enforced result)
  -> Program
       s scope project parent claim workload host boot epoch capabilities cell
       required offered 'Leased result

launchClosed
  :: ClosedWorkload project workload required
  -> ExecutionAuthority
       s scope project parent claim workload host boot epoch capabilities cell
       required offered mechanisms %1
  -> (RunningAuthority
        s scope project parent claim workload host boot epoch capabilities cell
        required offered mechanisms %1
      -> Program
           s scope project parent claim workload host boot epoch capabilities cell
           required offered 'Running result)
  -> Program
       s scope project parent claim workload host boot epoch capabilities cell
       required offered 'Enforced result

finish
  :: RunningAuthority
       s scope project parent claim workload host boot epoch capabilities cell
       required offered mechanisms %1
  -> Program
       s scope project parent claim workload host boot epoch capabilities cell
       required offered 'Running
       (ResourceReceipt
          scope project parent claim workload host boot epoch cell required offered mechanisms)
```

`withExecutionSession` privately resolves a closed
`ResourceBackend kernel arch host boot epoch capabilities cell offered` from the admitted cell and
observed host; no caller may manufacture a value at the fresh
`offered` brand. `applyEnvelope` creates the complete `AppliedEnvelope` and joins it with the exact
admission, lease, and hidden `Launchable required offered mechanisms` proof before minting
`ExecutionAuthority`. A weaker-than-required profile produces a typed refusal without entering the
continuation. The rank-2 `s` prevents a
live lease from escaping; the project, parent scope, claim, requirement, host, epoch, cell,
requested profile, offered profile, and mechanism bundle cannot be substituted. Linear transitions
prevent reuse, live bundle expansion, or skipped phases, and execution consumes the jointly branded
`ClosedWorkload`.

`finish` is the sole terminal form. The interpreter masks asynchronous exceptions around
acquisition, durable transitions, and cleanup, restores them only while supervised work may run,
and returns the indexed `ResourceReceipt` only after the enforcement domain is empty, the
record is retired and synchronized, and every lock is released. Sequential reuse inside one
persistent cell uses a separate closed combinator; parallel reuse requires an explicit proven split
and component-wise sum.

## Project-doctrine comparison

The four project doctrines contribute complementary resource-safety structures but do not make one
another the outer machine-global authority. Their common ground is checked positive arithmetic,
opaque post-validation capabilities, fail-closed admission, explicit cleanup, and an insistence that
a declared bound must not be confused with an observed sample. Their boundaries differ:

| Project | Strongest local doctrine | Outer-protocol obligation |
|---------|------------------------|----------------------------|
| `infernix` | Artifact-derived host/device inference formulas, toolchain claimant arithmetic, matching enforcer evidence, and an opaque executable model capability | Its grants and lifecycle locks are repository-local; development, cluster, and inference claimants do not yet descend from one machine-global cell, and no Windows lane exists |
| `jitML` | Unit-indexed workflow/run arithmetic, jointly validated run plans, persistent evidence/cleanup lifecycle, and substrate-specific codegen placement | Logical counts are not yet folded into one physical CPU/RAM/storage/VRAM peak; local POSIX/CAS locks and Kubernetes values do not arbitrate the host or supply reboot epochs |
| `hostbootstrap` | Broad CPU/RAM/storage provider budgets, pre-creation checks, protected durable ownership, Windows support, and several applied VM/container walls | The full topology-derived fit is incomplete, direct GPU/storage rows remain weaker, and current Haskell/POSIX/guest/Windows locks are not one frozen machine-global hierarchy |
| `amoebius` | Widest pure capacity and workflow calculus, residual-capacity target model, and checked build-stage envelope arithmetic | Live walls, host locks, and crash recovery remain future phased interpreters; current single-use build authority is process-local, and the Mac crash exposed unclosed compile/link fanout plus retained-storage demand |

The difference is therefore emphasis, not incompatible semantics: `amoebius` has the broadest
calculus, `infernix` the strongest resource-indexed launch gate, `jitML` the richest run/evidence
lifecycle, and `hostbootstrap` the broadest host/substrate ownership machinery. The protocol keeps
those inner strengths and adds the one outer chain none currently has:

```text
observed host -> registered parent -> admitted cell -> held physical domains
              -> applied/read-back walls -> one linear execution authority -> retired receipt
```

This section compares doctrine and does not confer conformance. Each repository's development plan
owns its adapter, compile-fail corpus, crash schedule, and live mechanism rows in numerical order.

## Project adoption boundaries

| Project | Keeps ownership of | Protocol adapter must provide |
|---------|--------------------|-------------------------------|
| `amoebius` | Global workflow/resource calculus, extension-total demand derivation, capacity folds, and evidence laws | Re-derive the protocol without importing a seed; wrap validation/build/link/provision/deploy/observe/teardown in one branded demand; use its leased cell as the parent of internal forest budgets; keep Markdown non-executable |
| `infernix` | Artifact-derived inference requirements, toolchain claimant arithmetic, typed execution plans, capped-engine outcomes | Treat every existing internal grant as a child of a host cell; acquire the outer cell before toolchain, cluster, or engine work; bind CUDA execution to the granted UUID/partition; let only the capped closed launcher consume authority |
| `jitML` | Compiled training/inference graph, replica and tuning concurrency, workload/job rendering, result evidence | Derive persistent plus peak-transient requirements; multiply parallel tuning/jobs; keep a lease anchor for persistent clusters; render every CPU/RAM/storage/GPU wall and exact granted device identity from authority rather than free text; advertise Windows only after its native adapter conforms |
| `hostbootstrap` | Host observation, prerequisite reconciliation, provider-specific VM/container/cgroup/Job-Object operations, project-plan derivation | Implement the same client protocol independently; optionally install the static catalog and walls, but never become a runtime dependency, coordinator, or sole grant issuer |

No adapter exports its lease constructor, applied-wall constructor, raw interpreter, or unrestricted
spawn function. A project may keep stronger local types; the common protocol is the outer
interoperability boundary, not a reason to weaken them.

## Interoperability freeze

Independent compatibility is defined only by one semantic ABI frozen and independently pinned by
all four repositories. No repository imports another's implementation. The ABI includes:

- canonical encoding, protocol version, integer widths and bounds, units, field order, digest
  domain separation, path/key grammar, and the fixed host coordination roots;
- project identifiers and cell owner/allowlist encoding;
- shared/exclusive hierarchical lock modes, canonical acquisition order, open-file-description
  lifetime, and the anchor protocol;
- journal states, legal transitions, atomic replacement and synchronization rules, deterministic
  domain identities, recovery authority, and quarantine outcomes;
- hardware and substrate identity tuples, capability/profile satisfaction matrices, and epoch
  invalidation inputs;
- compatibility refusal rules plus independently reviewed Haskell declarations of the same golden
  vectors, crash schedules, and live conformance cases; and
- a repository-local semantic ABI digest gate over those Haskell-owned constants and canonical
  corpus bytes. A Markdown digest is documentation-drift evidence only.

The ABI is a protocol contract, not a runtime coordinator or shared library. A binary without the
matching semantic version/digest and conformance receipts must refuse the coordination root;
similarly named files, copied Markdown, or locks do not establish compatibility. ABI upgrade takes
`epoch.lock` exclusively, proves all cells idle, atomically replaces the layout/journal schema, and
either completes or leaves the old revision recoverable; permissive version ranges are forbidden.

## Validation

The common conformance corpus must contain canonical layout and requirement vectors for positive
fit, project-policy mismatch, every single-dimension overflow, integer overflow, sequential maximum,
parallel sum, replica multiplication, unified-memory aliasing, whole-GPU-versus-MIG conflict,
distinct-GI versus sibling-CI classification, MPS strength/client-slot mismatch, stale epoch,
replaced coordination root, partial lock rollback, crash before and after `Prepared`, same-key retry,
different-key/same-parent contention, spent-key reuse, attempted live bundle growth, and
weaker-than-requested wall readback. Negative vectors request CUDA on Apple, Metal on Linux/Windows,
CUDA on CPU-only Linux/Windows, a missing volume, a stale MIG identity, a scalar-as-lock target, and
an ancestor/child duplicate; each must refuse before any resource lock or wall mutation.

Cross-project live acceptance must prove these interactions against the same host lock objects:

- while one project holds a whole-GPU or resource-cell lease, another receives a typed contention
  refusal without launching;
- two projects may concurrently launch only in disjoint cells, including distinct MIG GI identities;
- killing a CLI does not release a long-lived cluster or VM's cell while its lease anchor or
  enforcement domain remains live;
- recovery reclaims only an unlocked record whose exact bound domain is proven empty;
- a same-key retry observes, attaches, returns a receipt, or reconciles, but never creates a second
  parent reservation; a different key in the same parent scope reports `ParentScopeBusy`; different
  child authorities never sum beyond their one held parent and cannot acquire or grow host locks;
- forced anchor exit releases the kernel lock, then deterministic domain cleanup completes before
  new authority; simulated reboot invalidates the host epoch and rechecks every persistent effect;
- an epoch-exclusive mutation is refused while any parent holds epoch shared; after crash release,
  an exclusive epoch lock still aborts mutation when a stale effect cannot be proved absent;
- retiring a parent scope or resource leaves its lock inode/file ID as an inert tombstone; no
  reinstall, protocol upgrade, or recovery path deletes, replaces, or reuses it;
- a raw all-device, raw process, or raw VM/container launch cannot reach the strict adapter surface;
- compile-fail fixtures reject `LockKey` construction without `PhysicalDomain`, host/boot/capability
  substitution, proof construction, project/profile/mechanism substitution, resource or receipt
  relabeling, region escape, phase skip, linear authority reuse, and duplicate in-process acquisition.

Documentation validation proves structure and links only. The repository-local gates include
`infernix lint docs`, `jitml docs check`, the hostbootstrap documentation tests, and amoebius's
hardware-free documentation component diagnostics. Protocol conformance additionally requires the
Haskell-owned semantic ABI, pure/property/compile-fail corpus, cross-implementation black-box
vectors, crash schedules, and live mechanism gates for every advertised strength. A repository with
no live row for a mechanism advertises no conformance for that row.

## Primary mechanism references

- [Linux cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) — CPU,
  cpuset, memory, process-tree kill/empty readback, and I/O control semantics.
- [Apple `flock`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)
  and [Linux `flock`](https://man7.org/linux/man-pages/man2/flock.2.html) — the fixed shared/exclusive
  advisory-lock namespace and descriptor/open-file-description lifetime rules.
- [Windows `LockFileEx`](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex),
  [`FILE_ID_INFO`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex),
  and [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) — exact
  byte-range locking, held-file identity, process-tree ceilings, and kill-on-last-handle semantics.
- [Windows Job limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information),
  [volatile registry keys](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexa),
  and [`BCryptGenRandom`](https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgenrandom)
  — the committed-memory boundary, reboot-cleared boot-session state, and CSPRNG nonce mechanism.
- [NVIDIA MIG concepts](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/concepts.html) —
  hardware memory and compute partitioning.
- [NVIDIA MPS guidance](https://docs.nvidia.com/deploy/mps/when-to-use-mps.html) — per-client device
  memory limits, active-thread limits, and static SM partition behavior.
- [Kubernetes container resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
  — scheduler-local requests, limits, and extended resources.
- [Docker Compose GPU access](https://docs.docker.com/compose/how-tos/gpu-support/) — device access
  selection rather than fractional GPU enforcement.
- [CUDA unified memory](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/unified-memory.html)
  — managed-memory migration and oversubscription behavior.
- [Apple Metal device identity](https://developer.apple.com/documentation/metal/mtldevice/registryid),
  [unified-memory observation](https://developer.apple.com/documentation/metal/mtldevice/hasunifiedmemory),
  and [recommended working set](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)
  — boot-scoped physical identity, the host-memory alias, and the approximate-guidance boundary.
