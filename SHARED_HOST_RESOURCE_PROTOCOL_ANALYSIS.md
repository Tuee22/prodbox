# Shared Host Resource Protocol — Analysis

**Working file.** Not a governed document. Delete after the findings land in their owning surfaces.

Analysis target: `documents/engineering/shared_host_resource_protocol.md` at HEAD (`35e1e5c`).
Date: 2026-08-25. Every load-bearing claim below was read from source and put through an
adversarial refutation pass; where a claim was corrected, the correction is recorded in place.

---

## 0. Verdict

The document is honest, well-argued, and correctly classified as not-adopted. Its diagnosis of
prodbox is right. As a *proposal* it fits this repository poorly:

- most of it restates existing prodbox doctrine in a third vocabulary;
- two of its core rules contradict `config_doctrine.md`;
- its central mechanism is **advisory** in a codebase whose entire posture is to make the illegal
  state unconstructible — it offers prodbox a weaker instrument than the ones prodbox already holds;
- it has zero participants: `$HOME/.hostclaim` does not exist, and none of the eleven sibling
  projects on this machine reference it.

Its real value is **diagnostic**. Reading it surfaces a genuine unsoundness in
`Prodbox.Capacity.HostProbe` — the admission proof is free-blind — that needs no protocol, no peer,
and no installed root to fix, and that the document's own superseded revision described before HEAD
deleted the passage.

---

## 1. What the document gets right

- **§ 3 and § 5 are unusually honest about scope.** "That is a statement about **declarations**, not
  about behaviour"; "This is a real limit, not a gap awaiting a patch." That is exactly the
  discipline `documents/documentation_standards.md:258-266` demands and calls "the most common
  defect in this repository's governed documents, and the only one that reads as correct to every
  reviewer who does not check the source."
- **§ 4 (release-directed work is always admissible) is a correct, non-obvious invariant.** The
  deadlock it names is real, and it agrees with `pure_fp_standards.md:254-257`: cleanup is a DAG
  result fold, never fail-fast.
- **§ 2's five properties are a competent design** — single-writer records, fail-closed decoding,
  one critical section, frozen dimensions, prefix-disjoint conflict domains.
- **Its § 3 diagnosis applies to prodbox.** See § 4 below.

---

## 2. Where it does not fit this repository

### 2.1 Advisory admission in an unrepresentable-states codebase

| | |
|---|---|
| Document `:53-57` | "No limit is applied and no device is fenced. A participant that declares four gibibytes and then allocates twelve is not detected." |
| Prodbox | `compileResourcePlan` builds an opaque `AllocatedResourcePlan` (hidden constructor) that is a **required field** of `ValidatedSettings` — `src/Prodbox/Settings.hs:524`, `:1135`. No proof ⇒ no settings ⇒ no renderer input. `AbsenceEvidence` constructors are opaque outside the registered observer modules (`lifecycle_reconciliation_doctrine.md:567-569`). |

Prodbox also already **fences**, which the ledger explicitly does not: `CPUQuota`, `MemoryHigh`,
`MemoryMax`, `TasksMax` on the RKE2 process tree (`src/Prodbox/CLI/Rke2.hs:8626-8628`), plus kubelet
`system-reserved` / `kube-reserved` / `eviction-hard` (`:8601-8613`, `:8643-8656`).

This is a fit problem, not a dishonesty problem — the document says so itself. But it means adoption
would add a weaker ring beside stronger ones.

### 2.2 `$HOME/.hostclaim` contradicts `config_doctrine.md` twice

The document forbids environment-selected paths (`:21-23`) and then specifies a path resolved
through the `HOME` environment variable.

- `config_doctrine.md:629` — the binary "never falls back to `~/.config/prodbox.dhall` or
  `/etc/prodbox/...`". `:41-44` — "BINARY-SIBLING, ONE FILENAME EVERYWHERE … never a `--config`
  flag, never `/etc/prodbox/...`". A home-directory config root is exactly the class prodbox ruled
  out.
- `config_doctrine.md:1237-1241` — `lookupEnv` / `getEnv` / `getEnvironment` are linted out of the
  supported config-loading paths. `src/Prodbox/CheckCode.hs:8307` classifies `getHomeDirectory` /
  `getEnv` / `getCurrentDirectory` as a forbidden "environment-dependent-paths" input class.

**This is also a defect in the protocol on its own terms**, not only a prodbox-fit issue. `$HOME` is
per-process and settable. A participant launched from a systemd unit, a container, a cron job, or
under `sudo` resolves a different root than one launched from a login shell — verified on this host:

```
$ sudo printenv HOME
/root
$ echo $HOME
/home/matthewnowak
```

The document names that precise outcome as "the one failure the ledger exists to prevent" (`:21-23`).
An environment-independent resolution — `getpwuid(getuid())->pw_dir` — would not have this property.
`$HOME` is a configuration knob wearing the costume of a fixed path.

### 2.3 The authority claim contradicts the in-force-config model

Document `:18-19`: the ledger's authority "is that installed root and the `spec-version` the root
carries, never a copy of a document in any repository."

- `config_doctrine.md:1305-1310` — "no on-disk or ConfigMap-mounted Dhall file is authoritative";
  the in-force SSoT is the Lifecycle Authority aggregate's generation/digest/reference.
- `config_doctrine.md:1321-1325` — "A provisioning input fetched at run time from a third-party
  endpoint, **inferred from ambient host state**, or replaced by a placeholder on one code path is
  not configuration."
- `config_doctrine.md:203-230` — the four-reason compiled/operator partition. The ledger's `budget`,
  reserve, and `spec-version` match none of the four, so they would be deployment-varying values
  with no operator-authorable Tier-0 home.

### 2.4 Most of it restates doctrine, and the repo already classifies the mechanism

`chaos_hardening_doctrine.md:883-921` already names this exact construction: **case (ii)**,
non-confluent invariant held by bounded authority, combining **escrow/reservation** for the numeric
budget, **disjoint-namespace allocation** for the conflict domains, and a **single lock** (sub-form
S4). The overlap ledger:

| Document concept | Existing doctrine | Verdict |
|---|---|---|
| Release evidence for `Persistent` claims (`:106-108`) | `lifecycle_reconciliation_doctrine.md:727-728`, `:1724-1727`; `AGENTS.md:170-171` | Restates — **weaker** |
| Release-directed work never refused (`:65-70`) | `pure_fp_standards.md:254-257`, `:427`; `lifecycle_control_plane_architecture.md:211-213` | Restates |
| No env-var path selection (`:21-23`) | `config_doctrine.md:1237-1241`, `:1212` | Restates |
| Path is `$HOME/.hostclaim` (`:17-19`) | `config_doctrine.md:629`, `:41-44` | **Contradicts** |
| Installed root is its own authority (`:18-19`) | `config_doctrine.md:1305-1310`, `:1321-1325` | **Contradicts** |
| Budget + operator reserve fits (`:52`) | `resource_scaling_doctrine.md:202`, `:163-167` | **Contradicts** — no foreign-tenant term exists in the algebra |
| Advisory; declarations not behaviour (`:53-61`) | `chaos_hardening_doctrine.md:1120-1134` | Restates |
| One-shot admission can't see progressive use (`:74-80`) | `chaos_hardening_doctrine.md:1126-1130`, `:696` | Restates |
| Escrow budget + prefix-disjoint domains + one lock (`:37-42`) | `chaos_hardening_doctrine.md:883-916` | Restates |
| Every decode failure reads as occupied (`:35-36`) | `pure_fp_standards.md:388`; `lifecycle_reconciliation_doctrine.md:723` | Restates (licensed coercion) |
| One writer per directory (`:33-34`) | `lifecycle_control_plane_architecture.md:198-199`; `lifecycle_reconciliation_doctrine.md:2384-2388` | Restates |
| Filesystem lock serializing admission (`:27-28`) | `lifecycle_control_plane_architecture.md:2278-2284` | Restates — mechanism already in-tree |
| "Name the seams" (`:101-104`) | `lifecycle_reconciliation_doctrine.md:721-722` (Coverage) | Restates |
| "Derive the charge once" (`:104-105`) | `pure_fp_standards.md:92-99`, `:149-152` | Restates |
| `Transient` / `Persistent` kinds (`:44-47`) | Adjacent to `LifecycleClass` (`PerRun`/`LongLived`/`Operational`) and `StoreLifetime` | **New axis** — but a *third* lifetime vocabulary |
| Observing foreign work at point of use (`:82-94`) | Nothing observes foreign processes except one port check | **New** |
| Cross-project claim ledger | No existing position | **New** |

One place it is *weaker* than doctrine rather than merely different: **"What counts as established
is the participant's business"** (`:107`). Prodbox denies that a participant may choose.
`lifecycle_control_plane_architecture.md:987-991` requires a four-constructor custodial disposition
and states "**Silence is not a disposition, and neither is an exit code.**"

### 2.5 Adoption costs more than § 7 admits

§ 7 lists three obligations (name the seams, derive the charge once, establish release evidence).
Prodbox's own doctrine makes two more **mandatory** for a take-then-act primitive of this class:

- `chaos_hardening_doctrine.md:994` — a **TLA+ model** of the budget/namespace partition is
  *required*, plus a fail-closed exhaustion assertion under partition.
- `chaos_hardening_doctrine.md:794`, `:809-811` — a **contention + async-exception test** is
  *required*: "A take-then-act primitive with **zero** contention test is the most common and most
  glaring instance: its entire reason to exist is correct behaviour under concurrent modification,
  and it is 'verified' by code review alone."

The document's own § 2 qualification criteria (decisions under concurrency; coordination through a
named shared substrate; a safety invariant no single process can enforce alone) match
`chaos_hardening_doctrine.md:63-77` exactly, so those obligations attach by the doctrine's own terms.

### 2.6 The dimensions that actually contend on this host are not in the frozen set

**A permanent host-global sysctl mutation with no release.**
`src/Prodbox/CLI/Rke2.hs:563` persists `/etc/sysctl.d/99-prodbox-inotify.conf`
(`fs.inotify.max_user_instances = 8192`, `fs.inotify.max_user_watches = 1048576`, `:8592-8593`),
deliberately sorting after `/usr/lib/sysctl.d/30-tracker.conf` to override it
(`lifecycle_reconciliation_doctrine.md:1590-1600`). The write is drift-gated (`:8760-8770` compares
byte-for-byte first), and on the delete path only the two install-present arms reach it. But **no
path removes it** — absent from `deleteRke2ClusterSubstrate`'s removal list (`Rke2.hs:8845-8852`)
and from `loadNukeDeletionRoots` (`Nuke.hs:621-628`). It is root-owned and outside `$HOME`, so a
per-user ledger cannot name it, and inotify is not a cpu/memory/storage dimension. Practical impact
is low — raising a limit starves nobody — but it is an unreleased host-global claim, and it is the
only place any prodbox doctrine acknowledges other software writing the same host surface.

**Three unarbitrated host ports.**

| Port | Site | Arbitration |
|---|---|---|
| `30080` | registry NodePort, `src/Prodbox/DockerConfig.hs:8` | none |
| `39000` | MinIO port-forward, `src/Prodbox/Infra/MinioBackend.hs:74` | none — two prodbox runs collide |
| `30443` | `defaultGatewayNodePort`, `src/Prodbox/Gateway/Client.hs:107` | iptables INPUT DROP |

`reserveLocalTcpPort` (bind-to-port-0, `src/Prodbox/TestValidation.hs:5821`) is the only dynamic
allocation in the tree and is test-only.

**The gateway firewall rule has a release path, but a conditional one.** Argv is
`-A INPUT ! -i lo -p tcp --dport 30443 -j DROP` (`src/Prodbox/Host.hs:1388-1404`) — appended, not
inserted, so operator rules keep precedence; IPv4 filter INPUT only, so DNAT'd/forwarded traffic is
untouched (blast radius genuinely small). Install: `CLI/Charts.hs:182`, `CLI/Rke2.hs:5969`. Release:
`CLI/Charts.hs:195`, `CLI/Rke2.hs:3220`, `:3446`, `CLI/Spec.hs:432`. **But** the cluster-delete
release sits 4th in a `runSequentially` list that short-circuits on the first `ExitFailure`
(`Rke2.hs:9010-9015`), and an EPERM `iptables -C` prints "not-present" and exits 0
(`Host.hs:1560-1566`) — so teardown can report success while the DROP survives until reboot.

### 2.7 It does not cover the failure mode prodbox actually has

§ 5 excludes progressive consumption by design: "a store that fills during a long run, a cache that
grows, an image set that accumulates … This is a real limit, not a gap awaiting a patch."

Every host-resource incident this project has recorded is that shape — the gateway heap-leak OOM
cycle, object stores filling during long runs, accumulating image layers. **The ledger, by its own
admission, would not have prevented any of them.**

---

## 3. Zero participants, and a stricter sibling

- `$HOME/.hostclaim` does not exist on this machine.
- None of the eleven sibling projects (`amoebius`, `BBY`, `daemon-substrate`, `effectful`,
  `hostbootstrap`, `infernix`, `jitML`, `mattandjames`, `MCTS`, `shipnorth`, `SpectralMC`)
  references `hostclaim`, `spec-version`, `claim ledger`, or `HostClaim`.
- The only two references to the document anywhere in prodbox are the index rows at
  `documents/engineering/README.md:78` and `:193`.

The document's **original** title (`b0804fa`) was *Finite Resource Execution Authority Protocol*,
`Status: Authoritative source`, 869 lines, describing "amoebius and its seed projects", Phases 29 /
32 / 51 / 52–54, and `hostbootstrap-core`. So it is an umbrella-family protocol prodbox would be a
*participant* in, not the author of. `DEVELOPMENT_PLAN/00-overview.md:180` corroborates: "prodbox as
the proven single-node specialization the `~/amoebius` umbrella generalizes."

Meanwhile the natural operator project already does the job more carefully.
`~/hostbootstrap/documents/engineering/resource_budgeting.md` implements
`preflightHostBudget` / `verifyHostBudget` with **a ~4 GiB host-OS reserve** and reads
**`MemAvailable`** on Linux. On the shared-host question, prodbox is measurably less careful than
its own sibling.

---

## 4. The finding: prodbox's admission proof is free-blind

### 4.1 The mechanism

`Prodbox.Capacity.HostProbe` observes four axes and takes the **total** on every one:

| Axis | file:line | Reads |
|---|---|---|
| CPU | `HostProbe.hs:193-200` | `nproc` × 1000 |
| Memory | `HostProbe.hs:202-214` | **`MemTotal`** — `MemAvailable`/`MemFree` appear nowhere in the repository |
| Ephemeral storage | `HostProbe.hs:216-241` | `df -Pm` field 2 = **1M-blocks total**; the `Available` column (field 4) is parsed past and discarded |
| Durable storage | same, on the retained-PV path | same |

`deriveHostFittingCapacity` then sets `host_capacity` **to** the observed total — `fitAxis` returns
`available`, not `required`:

```haskell
-- HostProbe.hs:135-136
fitAxis label available required
  | required <= available = Right available
```

confirmed by its own Haddock (`:87-90`) and by `resource_scaling_doctrine.md:236-238`: "CPU and
memory are declared at the observed capacity."

Ring 3 (`compileResourcePlanAgainstObserved`, `Capacity/Allocation.hs:511-545`) then re-proves
`authored <= actual` against a fresh probe through the **same total-based reader**. Because the
authored figure was *derived from* that reader, the Ring-3 memory/CPU check is close to an identity
rather than a check.

The only allowance for co-resident software is a **flat authored constant**, machine-size
independent — `Capacity/Config.hs:183-185`:

```haskell
host_capacity  = ResourceVector 8000 15872 100000 180000
rke2_reserved  = ResourceVector 1000  2048  10240   1024
eviction_floor = ResourceVector  500  1024  10240   1024
```

Half of `rke2_reserved` is rendered as kubelet `system-reserved`
(`splitReservedVector`, `Rke2.hs:8601-8613`) — which *is* by definition the reserve for
non-Kubernetes host daemons. So the correct statement is not "prodbox assumes the whole machine is
free":

> **prodbox substitutes a static reservation for a live-usage observation.**

Note also that the committed default `memory_mib = 15872` is essentially this machine's `MemTotal` —
the repo carries a host-fitted figure as its portable default — while its
`100000 + 180000 = 280 GiB` of storage exceeds this host's 238 GiB device, which is why default-mode
`config generate` must re-fit.

### 4.2 Measured on this host

| Axis | prodbox observes | Actually available | Delta |
|---|---|---|---|
| Memory | 15930 MiB (`MemTotal`) | ~12300 MiB (`MemAvailable`) | ~3.6 GiB |
| Disk `/` | 238221 MiB (`df` 1M-blocks) | 136736 MiB (`df` Available) | ~99 GiB (**~74% overstatement**) |

The `df` blocks column is the statvfs total *including root-reserved blocks*. The machine is already
1.5 GiB into swap. The largest single RSS consumer is a `claude` process (~612 MB) — precisely the
foreign work the ledger exists to account for.

### 4.3 What this does and does not cause — corrected after adversarial review

My first framing overstated the consequence. Verification established that **`host_capacity` has no
enforcement path to the machine.** Its only consumers are:

1. the admission proof — `allocatable = host_capacity − (rke2_reserved + eviction_floor)`
   (`Allocation.hs:22`, `:462`);
2. the Ring-3 check (`Allocation.hs:511-545`);
3. three narration sites — `Rke2.hs:1079` (status), `:1839` (reconcile plan), `Settings.hs:938`.

Nothing sizes a workload, replica count, quota, or cgroup from it. Kubelet args come from the fixed
`rke2_reserved`/`eviction_floor`; pod requests from the fixed `workload_profiles` (~8.6 GiB of
memory requests). **So today, on this host, the plan fits and nothing is breaking.**

The defect is that the **proof is unsound**, and it degrades silently in three ways:

1. **Plan growth passes unchecked.** Raise `workload_profiles` by ~4 GiB and `config generate`, the
   `dev check` over-commit gate, and Ring 3 all still pass — every one compares against `MemTotal`.
   Kubelet then advertises ~12.8 GiB allocatable and schedules the pods.
2. **A filled disk is invisible.** The 5% slack in `splitSharedStorage` (`HostProbe.hs:162`,
   `usable = device - device div 20`) is generate-to-reconcile *shrink tolerance* on the
   shared-device path only; the distinct-device path has none, and neither is a used-bytes term.
3. **The co-tenant reserve does not scale** — a flat ~1.5 core / 3 GiB regardless of machine size or
   actual foreign load.

**A genuine mitigating fact:** runtime is not blind. Kubelet's `eviction-hard`/`eviction-soft` are
phrased on `memory.available<1024Mi`, `nodefs.available<…`, `imagefs.available<…`
(`Rke2.hs:8643-8656`), which kubelet evaluates node-wide across *all* processes. So a shortage does
surface — as eviction of prodbox pods. That is a fail-safe direction. The caveat is threshold order:
with earlyoom active on this host at ~1.55 GiB, physical memory can be exhausted before kubelet's
`<1Gi` hard threshold trips, in which case the kernel-side reaper selects by RSS and need not pick a
prodbox pod.

**A second, opposite-direction hazard found in the same pass.** `observedCpuMilli` shells to bare
`nproc` (not `nproc --all`) with an inherited environment (`subprocessEnvironment = Nothing`,
`HostProbe.hs:249`). GNU `nproc` reports processing units *available to the calling process*,
honoring the CPU affinity mask and `OMP_NUM_THREADS`. Verified here: `nproc` = 8,
`taskset -c 0,1 nproc` = 2, `OMP_NUM_THREADS=2 nproc` = 2. A prodbox run inside a restricted cgroup
therefore observes a **smaller** machine — silently, with no diagnostic.

### 4.4 Why this is a doctrine violation, not a preference

`chaos_hardening_doctrine.md § 24` (`:1208+`):

> A derived value is only as correct as the layer at which its source object is authoritative, and
> that layer must match the layer at which the value is enforced. … where any differ, the derivation
> is a defect even though it observed a real thing.

`MemTotal` and `df` total-blocks are authoritative at the layer of *how big is this machine*;
`host_capacity` is enforced at the layer of *can this plan run here*. This is a **third in-tree
instance** of the class § 24 already documents with two worked examples (the `apiEgress`
Service-vs-endpoint NetworkPolicy, 2026-08-10; the cascade's global-audit-as-exact-observation,
2026-08-15).

The superseded revision `2acb2c4` **had this observation** and mis-filed it as a caution about a
future conversion rather than as a defect in current source:

> "The authored physical-host figure describes the machine, not prodbox's allocation, and
> reinterpreting it as an allocation would let the in-cluster scheduler reason about more capacity
> than the outer claim permits."

HEAD deleted that sentence. Under `CLAUDE.md`'s evidence-class rule — separate what the current
source implements from what the target doctrine requires, and do not promote one into the other —
the document had the right observation in the wrong evidence class.

### 4.5 The strongest counter-argument, and why the fix must respect it

One reviewer argued `MemTotal` is the *correct* input for this function's contract:
`resource_scaling_doctrine.md § 2B` rule (a) is literally
`rke2.reserved + eviction.floor <= host.physical`; Kubernetes derives `Node.status.capacity.memory`
from `MemTotal`; and `Rke2.hs:8600-8613` renders `system-reserved`/`kube-reserved` precisely so
kubelet's allocatable arithmetic matches prodbox's. Substituting `MemAvailable` for `host_capacity`
would (a) desynchronize prodbox's model from kubelet's own capacity figure and (b) make Ring 3
non-deterministic — a plan admitted at generate time would fail at reconcile because a browser
opened.

**That objection is correct, and it shapes the remedy.** The fix is *not* to redefine
`host_capacity`. It is to add a **second, distinct availability gate** beside the existing size
proof — which is exactly what `hostbootstrap` already does.

### 4.6 Both primitives needed already exist in-tree

- **Point-of-use foreign observation.** `loadListeningPorts :: IO (Either String (Set Int))` parses
  `/proc/net/tcp{,6}` for LISTEN state (`src/Prodbox/Host.hs:667-700`). It is the *only* place
  prodbox observes foreign work — and it covers ports 80/443 only, as an operator diagnostic
  (`prodbox host check-ports`), wired into no admission path.
- **POSIX advisory locking.** Five hardened instances, each `setLock (WriteLock, AbsoluteSeek, 0, 0)`
  over a `canonicalizePath`'d path plus a process-local `MVar` reservation set:
  `Config/LocalRetainedRoot/Internal.hs:368`, `Lifecycle/HostCleanupIntent/Internal.hs:291` and
  `:1213`, `Gateway/Emitter/Journal.hs:389`, `TestArtifactIntentJournal.hs:217`.
  **All five are keyed on a retained-root path; none on the host.** `src/Prodbox/App.hs:79-126`
  takes no lock at all. Two prodbox runs from different checkouts therefore share no lock while
  contending for the same RKE2 install, `~/.kube/config`, sysctl drop-in, iptables chain, and ports.

The one host-scoped exclusion that exists is presence-gating in the test harness —
`testProductionClusterGate` and `testProductionConfigGate` (`src/Prodbox/TestRunner.hs:441-451`,
`:361-364`) — which refuses topology tests when a production install or config is present.

### 4.7 The release side is the strong part

Worth recording, because the document's third obligation is the one prodbox is *best* equipped for.
`AbsenceEvidence` (`Lifecycle/Teardown/Observation.hs:67`), the surface-indexed
`LocalUninstallEvidence` GADT with unexported constructors
(`Lifecycle/Teardown/CascadeEvidence/Internal.hs:1331-1398`), the eight-marker three-valued RKE2
install observation (`Lifecycle/HostCleanupRke2.hs:59-109`, presence outranks read failure), the
exclusive-`createLink` completion receipt (`Lifecycle/HostCleanupCompletion.hs:604-660`), and
intent-committed-before-mutation (`Lifecycle/CleanupRunEntry.hs:159-175`) already constitute a
working prove-it-was-released protocol — stronger than what the document asks for.

---

## 5. Documentation-standards regressions introduced by HEAD

| # | Finding | Rule |
|---|---|---|
| 1 | `Status: Reference only` means "**Points to authoritative sources**" — the document has **zero markdown links**. One of only two files in `documents/engineering/` with none. | `documentation_standards.md:88` |
| 2 | The `> **Not adopted.**` declaration **and** the `Development Plan → Resume Here` pointer were deleted by HEAD. Revision `2acb2c4` carried both. | `documentation_standards.md:389-406` (§ 12.1): "A document whose entire subject is a target architecture declares once at the top … Every declaration names where status lives … **The defect is a target claim in an undeclared region.**" |
| 3 | `dev check` still passes — § 12.3 gates only that an *existing* declaration carries its pointer. Deleting the declaration **removes the checkable surface** rather than tripping it. | `documentation_standards.md:425-433` |
| 4 | No `## Intent Ownership`, no `## Cross-References`. 12 peers carry the first, 32 the second. | peer convention |
| 5 | No Development-Plan ownership: no sprint, no `Documentation Requirements` entry, no component-inventory row. The only document in the directory whose subject has no module, test, schema, sprint, or inventory row. | `development_plan_standards.md` Standard G (`:118-145`), Standard J (`:207-231`) |
| 6 | `README.md:1079` says `documents/engineering/` holds **40** governed documents; it now holds **41**. | off-by-one introduced when this file landed |

### Revision history

| Commit | Time | State |
|---|---|---|
| `b0804fa` | 08-24 15:27 | Introduced alone. 869 lines, *Finite Resource Execution Authority Protocol*, `Status: Authoritative source`, amoebius/`hostbootstrap-core`/Phase-numbered. Not indexed. |
| `aab2137` | 08-24 17:24 | Root `SHARED_HOST_RESOURCE_PROTOCOL_ANALYSIS.md` added (+994) |
| `cea6305` | 08-24 19:52 | Analysis deleted. Retitled *Shared Host Resource Protocol*, `Reference only`, 1032 lines, gained a `> **Target.**` declaration → Resume Here. **Indexed.** |
| `9f0c9e2` | 08-24 20:25 | Root analysis re-added (+823) |
| `2acb2c4` | 08-24 22:12 | Analysis deleted. Cut to **83 lines**, fully prodbox-scoped (`systemctl start rke2-server`, the observed-host seam, the plan derivation), carrying `> **Not adopted.** … Status remains owned by [Development Plan → Resume Here]` |
| `79e0c10` / `53e3fb5` | 08-24 22:41 / 23:23 | Root analysis re-added (+427), then renamed |
| **`35e1e5c`** | **08-25 07:41 (HEAD)** | Analysis deleted. Rewritten to 111 lines, **project-neutral**. Removed the `Not adopted.` declaration, the Resume Here link, the `Read this if` line, the `## Contents` list, and **all five prodbox-specific sections**. |

**Net: HEAD made the document more general and strictly less useful *here*.** `2acb2c4` was the
better artifact for this repository on every axis except neutrality — it named the gap (no
machine-wide lock; the `systemctl start rke2-server` bypass), named the seam (the observed-host
check, "the one place a refusal is already expected"), named what would not change, and listed what
was open before adoption.

---

## 6. Recommended actions

Three independent tracks. None depends on adopting the ledger.

### A — Make the admission proof free-aware

Do **not** redefine `host_capacity` as availability (see § 4.5). Add a distinct availability gate
beside the existing size proof.

1. `src/Prodbox/Capacity/HostProbe.hs` — read `MemAvailable` and the `df` `Available` column
   **alongside** the existing totals (`observedMemoryMib`, `observedFilesystemMib`). Switch the
   machine-size CPU axis to `nproc --all` so a restricted cgroup cannot silently shrink it, and
   surface a diagnostic when `nproc` and `nproc --all` disagree.
2. `src/Prodbox/Capacity/ObservedHost.hs` — `ObservedHostRoot` gains an availability vector;
   `mkObservedHostRoot`'s existing total-based vector is unchanged, so `host_capacity` and kubelet's
   `Node.status.capacity` stay in sync.
3. Gate reconcile on it at the existing Ring-3 seam, `ensureRke2ResourceGuardrails`
   (`src/Prodbox/CLI/Rke2.hs:8686`), as a **typed refusal distinguishing *momentarily contended*
   from *cannot fit at all***, reusing the `ObservedHostDimensionInsufficient` /
   `ObservedHostSharedStorageInsufficient` shapes (`Capacity/Allocation.hs:380-381`).
4. Make the co-tenant reserve an **explicit declared `ResourcePlan` field** rather than an implicit
   half of `rke2_reserved`, so it is operator-stateable per `config_doctrine.md:203-208` rather than
   ambient, and can scale with the machine.
5. Record it as a § 24 layer-mismatch instance in `chaos_hardening_doctrine.md § 24`, and correct
   `resource_scaling_doctrine.md § 2B` "Host-fitting generation", which currently claims the derived
   capacity "fits the real device."

Note this is unqueued work: `DEVELOPMENT_PLAN/README.md → Resume Here` currently has Sprint `2.75`
as `Next` and `6.5` `Parked`. It should become a sprint row rather than jumping the queue.

### B — Repair the document

Restore what `2acb2c4` had and HEAD removed, keeping HEAD's cleaner protocol prose:

- Reinstate the `> **Not adopted.**` declaration naming
  `[Development Plan → Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here)` (§ 12.1).
- Reinstate the prodbox-scoped sections — what prodbox would claim, where it would attach, what is
  not changed, what is open before adoption — and add to that last list the § 2.2 / § 2.3
  config-doctrine conflicts and the § 2.5 chaos-doctrine conformance obligations.
- Add `## Cross-References` and `## Intent Ownership`. The links also make `Reference only` true.
- Note § 2.6: the sysctl drop-in and the three fixed ports are host claims the ledger's frozen
  dimensions cannot represent.
- Fix `README.md:1079`: 40 → 41.

### C — Host residue

- `/etc/sysctl.d/99-prodbox-inotify.conf` has no removal path anywhere, including `nuke`. Either add
  it to `deleteRke2ClusterSubstrate` (`Rke2.hs:8845-8852`) and `loadNukeDeletionRoots`
  (`Nuke.hs:621-628`), or state in `lifecycle_reconciliation_doctrine.md § 5a.1` that it is
  deliberately permanent, and why.
- The gateway iptables unrestrict sits 4th in a short-circuiting `runSequentially`
  (`Rke2.hs:9010-9015`) and reports "not-present" on EPERM (`Host.hs:1560-1566`). Move it ahead of
  the failure-prone steps, or aggregate its outcome instead of short-circuiting, so teardown cannot
  report success while the DROP survives.

---

## 7. Verification obligations

- **A** — unit coverage beside `test/unit/Tier0PlanAssert.hs`, injecting availability observations
  through the existing `PRODBOX_TEST_HOST_CAPACITY` seam extended with availability fields.
  End-to-end: fill `/` below the plan's storage demand and confirm `cluster reconcile` refuses with
  the new typed refusal rather than proceeding; confirm `config generate --portable` is unaffected.
  Then `prodbox dev check` — run it `nohup`-detached, flags in the exact order
  `all --enable-tests --ghc-options=-Werror` — and `prodbox test integration` separately, because
  `dev check` does not run it.
- **B / C** — `prodbox dev lint docs` exit 0, plus a manual § 12.1 read since the declaration rule is
  a review obligation rather than a gate. For C, exercise a teardown with a deliberately failing
  earlier step and confirm the iptables rule is gone.

---

## Appendix — method and confidence

Three parallel repository explorations (documentation-system fit, host-capacity seam map, doctrine
overlap) plus a 15-agent adversarial workflow: two independent lenses per factual claim — one
instructed to refute from source, one to judge real-world significance — over six load-bearing
claims, followed by standards-conformance and adoption-cost passes.

Outcome: **11 of 12 refutation votes returned "not refuted."** The single refuting vote corrected
*scope*, not substance — it confirmed the mechanism and established § 4.3's crucial qualifier that
`host_capacity` has no enforcement path to the machine. Significance votes ranged **minor to
moderate**, which is why this analysis reports a latent unsoundness rather than an active outage.

Corrections applied from that pass, recorded so they are not silently re-introduced:

- `system-reserved` **is** a reserve for non-Kubernetes host daemons; the earlier claim that
  "nothing reserves capacity for other programs" was wrong. It is a flat constant, not zero.
- `host_capacity` drives only the proof and narration — no quota, cgroup, or workload sizing.
- Kubelet eviction thresholds **are** phrased on `.available` metrics, so runtime is not blind.
- `nproc` is affinity-aware, creating an under-observation hazard in the opposite direction.
- `gatewayNodePortFirewallRuleArgs` is defined in `Host.hs` only; `Rke2.hs` and `Charts.hs` are call
  sites. The iptables rule is appended (`-A`), not inserted.
- The inotify write is drift-gated and, on the delete path, reached only when an install is present.
