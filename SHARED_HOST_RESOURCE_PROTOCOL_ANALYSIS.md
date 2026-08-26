# Shared Host Resource Protocol — Critical Analysis

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: A review of [documents/engineering/shared_host_resource_protocol.md](./documents/engineering/shared_host_resource_protocol.md)
> — which of its empirical claims reproduce on this host, how it fits prodbox, what is defective in
> the protocol itself, and what is worth extracting from it. Analysis only; it decides nothing and
> owns no status.

---

## 0. Scope, method, and limits

Reviewed at revision `fe3ed61` (583 lines). The document's own measurements were **re-run on this
host** rather than read: `Linux 7.0.0-28-generic x86_64`, `python3.12.3`, `ghc 9.12.4` /
`base-4.21.2.0`, `unix-2.8.8.0`. Both committed harnesses
(`documents/engineering/crash_harness.py`, `documents/engineering/hostgrant_probe.py`) were copied
to a scratch directory and executed there; nothing in the repository was modified during the review.

Findings were produced by parallel investigation and then put through an adversarial refutation pass.
Four candidate findings did not survive it and are recorded in [§7](#7-candidate-findings-discarded-on-verification)
rather than dropped silently.

**Not verifiable from here, and treated as unknown:**

- The document's Darwin measurements. No Darwin host was available.
- The claim that "four projects re-measured every load-bearing claim on their own hardware." The
  other projects on this machine were checked only for whether they implement the policy (none does);
  their review records were not inspected.
- Every Windows claim, which the document itself already registers as unverified in § 11.

---

## 1. Verdict

The document is the most epistemically disciplined artifact in `documents/engineering/`, and it is a
poor fit for prodbox. Those are not in tension. It is a careful protocol for a problem this project
does not have, which explicitly excludes the problems it does have.

| Dimension | Assessment |
|---|---|
| Empirical rigor | **High.** Every load-bearing Linux measurement reproduces cell for cell on this host |
| Cited evidence for § 7.3 | **Fails.** The harness is true by construction; see [§2.2](#22-what-does-not-hold-73s-evidence) |
| Fit to prodbox's contention surface | **Poor.** The premise has no producer here; the expensive contention is out of the protocol's reach |
| Internal specification completeness | **Incomplete.** Six defects that would cause two implementers to diverge; see [§4](#4-defects-in-the-protocol-itself) |
| Repository integration | **Unowned.** No Development Plan row, a mis-signalling index entry, a term collision, and two tracked `.py` files |
| Extractable value | **Real but small, and independent of adoption.** See [§6](#6-recommendations) |

**Recommendation: do not adopt. Extract three specific things. Fix the document's own defects before
anyone implements it anywhere.**

---

## 2. Reproduction of the document's empirical claims

### 2.1 What holds

**The § 6.2 Linux 3×3 lock matrix reproduces cell for cell**, with a negative control on an unheld
file before every contended cell. Two families, `{flock}` and `{fcntl, OFD}`, exactly as tabulated.
The document claims independent reproduction on "`Linux 7.0.0-28 x86_64`" — that is this host, and
the claim is confirmed rather than merely restated.

**The § 6.2 `FD_CLOEXEC` four-cell result reproduces verbatim, including errno.** With the flag
clear, a spawned `/bin/sleep` inherits the descriptor and the grant survives `SIGKILL` of the holder;
with it set, the grant is released. Linux errno 11.

**The § 6.2 lifetime table reproduces.** Classic `fcntl` loses its lock when an unrelated descriptor
to the same file is closed; OFD does not. This is the row that matters most for prodbox — see
[§3.7](#37-the-one-defect-the-document-would-actually-fix-in-existing-code).

**§ 5.1's algebra assertions pass verbatim** on python3.12, including the two traps the document
calls out (`conflicts("gpu:0", "gpu:01")` is false; `valid("gpu:0\n")` is false).

**The § 11 witness cells reproduce**: live witness `LIVE`; wrong start time `GONE`; post-`SIGKILL`
`GONE`; never-started pid `GONE`. `getconf CLK_TCK` is 100, so Linux start-time resolution is 10 ms
as stated.

### 2.2 What does not hold: § 7.3's evidence

§ 7.3 offers a console block as measured proof that "Zero files are created per run," and invites the
reader to re-derive it: "The harness is committed beside this document … so the number can be
re-derived rather than trusted." The harness cannot produce any other answer.

**It never creates a file.** `crash_harness.py:35` is `fd = os.open(path, os.O_RDWR)` — the only
`os.open` in the loop, with no `O_CREAT` — and there is no `os.unlink` anywhere. `count()`
(`:25-26`) walks a tree whose file set is fixed by `install()` before the loop begins. Instrumented,
loop-only:

```
INSTRUMENT loop-only: OSError-continue path taken: 0
INSTRUMENT loop-only: os.unlink calls: 0
INSTRUMENT loop-only: os.open count: 300 distinct flags: [2] O_CREAT bit set in any: False
```

A null control — every lock, payload, `ftruncate` and crash branch deleted, the loop reduced to
`os.open(...O_RDWR); os.close(fd)` — prints the identical result:

```
files after install:     10
files after 300 cycles:  10
RESULT: file count CONSTANT (10 -> 10)
```

**The "simulated hard crash" branch is the normal branch.** `crash_harness.py:49-52`:

```python
    if random.random() < 0.25:                      # simulated hard crash: drop the fd, no cleanup
        os.close(fd); crashes += 1
    else:
        os.close(fd)
```

`os.close` *is* the cleanup — it releases the OFD lock. An AST comparison of the two branch bodies
with the counter removed returns identical statement lists. `simulated-crashes=80` in § 7.3's console
block is a count of coin flips, not of crashes.

**Consequence.** § 9's central operational promise — "Nothing here requires an operator to delete a
file, at any point, for any reason" — rests on § 7.3, and § 7.3's cited artifact does not exercise
it. The property is probably still true of a correct implementation; it is simply unmeasured. If
prodbox ever adopts this, **`crash_harness.py` must not be reused as an acceptance test**: it would
pass against an implementation that creates a slot per run, because it never calls the
implementation.

---

## 3. Fit against prodbox

This is the substance of the review. The protocol coordinates concurrent programs contending for a
finite host resource on one kernel. Each premise was tested against the source tree.

### 3.1 The premise has no producer in this repository

Every concurrency knob prodbox owns is pinned to one:

| Evidence | Effect |
|---|---|
| `prodbox.cabal:757` — `executable prodbox` has `-Wall -rtsopts -with-rtsopts=-T` | Not built `-threaded` |
| `prodbox.cabal:1052` — integration suite `-with-rtsopts=-N1` | One capability |
| `test/unit/Main.hs:1999`, `test/integration/Main.hs:26` — `--num-threads=1` | Both tasty suites serial |
| `src/Prodbox/TestRunner.hs:735` — `foldM runSuite ExitSuccess suites` | Sequential, short-circuits |
| No `*.sh` in the tree; `AGENTS.md:262` forbids `.github/` workflows during active development | No external parallel driver |

§ 11 concedes the general case: "A mutual-exclusion protocol's value is proportional to participants
minus one, and this one currently has none." Inside prodbox the situation is worse than none. It is
not one participant that might one day meet another; it is one participant that structurally cannot
meet itself.

### 3.2 The intuitive case for adoption is false

The obvious argument — "two runs will collide on port 30443" — does not hold in this codebase. Every
host-side listener reserves an ephemeral loopback port by binding `SockAddrInet 0`:

- `src/Prodbox/ControlPlane/LocalClient.hs:721-731` (`reserveLoopbackPort`)
- `src/Prodbox/Gateway/PortForward.hs:214-227` (`reserveLoopbackTcpPort`)
- `src/Prodbox/Bootstrap/Broker/PortForward.hs:274-283`
- `test/integration/FixtureServer.hs:213`

The fixed numbers in source (30080, 30443, 39000, 31820) are Kubernetes NodePorts and port-forward
*targets* on the single cluster, not ports a prodbox process binds. The only fixed bind in the tree
is the in-cluster control plane on 8600 (`ControlPlane/Runtime.hs:3452-3456`,
`ControlPlane/ListenPort.hs:42`). Host-port contention was designed out years ago.

### 3.3 Three of the five reserved families are empty or mis-spelled here

§ 5.3 spends its strongest argument on the reserved list and fixes an identifier spelling for each at
the cost of a MUST. For prodbox:

| Family | Status in prodbox |
|---|---|
| `gpu:<id>` | **No producers.** Only enum tags (`Cluster/Substrate.hs:19-21`, `DockerConfig.hs:135`). No `nvidia`, CUDA device, or `/dev/dri` access in `src/` |
| `vm:<name>` | **No producers.** `Host/Ensure.hs:88-125` emits `ProbeTool` / `InstallHint` / `VerifyTool`; the only importer of `Prodbox.Host.Ensure` anywhere is `test/unit/Main.hs:980`. Nothing runs `limactl start` or `incus launch` |
| `disk:<fs-id>` | **Mis-spelled for prodbox.** § 5.3 mandates the filesystem UUID and rejects a mount path; `Capacity/HostProbe.hs:230-236` keys `StorageDeviceId` on the `df -Pm` device column. § 5.3 then requires `Unsupported` rather than inventing a spelling |
| `host:memory`, `host:cpu` | Producible, but land squarely in § 10's excluded case — see [§3.6](#36-10s-load-bearing-sentence-is-false-for-this-repository) |

The `disk:` mismatch is not cosmetic: `host_platform_doctrine.md` § 8's shared-device joint-budget
collapse keys on that exact `StorageDeviceId`, so adoption means either a second differently-keyed
disk identity inside one binary, or migrating the identity the device-collapse comparison uses.

### 3.4 Units do not line up

§ 5.2 fixes `host:memory` and `disk:<fs-id>` in **bytes**. Every prodbox surface is in **MiB**:

- `src/Prodbox/Capacity/Types.hs:20-25` — `memory_mib`, `ephemeral_storage_mib`, `durable_storage_mib`
- `dhall/capacity/Schema.dhall:14-15` — `milli_cpu`, `memory_mib`
- `src/Prodbox/Capacity/HostProbe.hs:202,214` — the probe deliberately divides KiB down to MiB
- `src/Prodbox/Capacity/Config.hs:183` — `host_capacity = ResourceVector 8000 15872 100000 180000`
- `documents/engineering/resource_scaling_doctrine.md:108-111` — "memory, in MiB"

CPU matches (both millicores; `HostProbe.hs:195-200` computes `nproc * 1000`). Memory and storage do
not. The one measured host memory number, `15872`, becomes `16642998272` hand-typed into an untyped
operator-edited text file, with no compiler or Dhall assertion on either side of the conversion —
and `resource_scaling_doctrine.md:122` records that the `MebiBytes`/`MilliCpu` newtypes that would
have caught it were **retired**. The whole point of that area is that over-commit is unrepresentable;
`<root>/capacity` is the one place it becomes representable again, and a 1024× slip reads as
headroom.

### 3.5 The witness is unsound for both of prodbox's standing resources

§ 4.1 requires "the narrowest process whose death implies the resource is gone." prodbox has two
standing resources and neither has one:

- **Local RKE2** is a systemd unit (`CLI/Rke2.hs:569` — `rke2-server.service`), supervised by pid 1,
  which never exits. The claim would never clear. § 4.1 names this failure ("honoured for longer than
  the resource exists … this policy cannot detect it") but treats it as an edge case; for prodbox it
  is the only available answer.
- **AWS EKS** is created by a `pulumi` process (`ControlPlane/ProviderProduction.hs:535`) that returns
  while the cluster keeps running. There is no local witness at all.

**Worse, § 4.1's boot-identity rule gives the wrong answer here.** prodbox `systemctl enable`s the
service (`CLI/Rke2.hs:2036-2042`), so the cluster returns after reboot while § 4.1 and § 9 both
discard the claim ("Boot identity differs → claim ignored"). § 4.1 presents its table as exhaustive —
"This makes a standing claim self-clearing in every failure" — and for prodbox it produces a live
cluster with no claim: a silent false-free that would admit a second participant onto a machine whose
cluster is already up.

**And the witness model inverts prodbox's actual leak class.** § 10 concedes only the
over-conservative direction. prodbox's recorded leaks are the opposite: the process died and the
resource persisted. `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md:1560` records three
`aws-test-node-*` instances, two VPCs and an orphan ENI stranded by a killed
`prodbox test all --substrate aws`, where "the file-existence residue predicate then reported
'nothing to destroy' while the AWS resources persisted." Declaring that footprint a standing claim
means a `SIGKILL`ed run prints "claim ignored" while billable resources run on — manufacturing a
false absence signal, and repeating a defect this repository has already diagnosed and fixed once.

### 3.6 § 10's load-bearing sentence is false for this repository

> "**This is the only shared-host failure these projects have actually recorded**, and it stays out
> of scope." (§ 10, on progressive consumption)

That sentence is what makes § 10 read as honest scoping. At least three recorded prodbox failures are
categorically not progressive consumption:

1. **inotify instance-cap exhaustion.** `src/Prodbox/CLI/Rke2.hs:8752-8756`: the kernel default
   `fs.inotify.max_user_instances = 128` is too low for RKE2 + containerd + kubelet alongside
   journald and developer tooling. The fix is code-owned — `Rke2.hs:563`
   (`99-prodbox-inotify.conf`), wired as `StepHostInotifyLimits` at `:1693`, `:2032`, `:3176`. This
   is a divisible, counted, per-uid host-kernel resource exhausted by concurrent programs — exactly
   the protocol's shape, and § 5.2 forbids measuring it because the document fixes no unit for it.
2. **A shared build directory collided between two writers** — see [§3.8](#38-the-one-genuine-local-collision).
3. **An authored host capacity exceeded the physical machine.** `DEVELOPMENT_PLAN/README.md:4066`
   records the fix: `config generate` now "observes the host (`nproc` / `/proc/meminfo` / `df -Pm`)
   and derives a `host_capacity` that covers demand and fits the device … This closes the live
   incident where a fixed 280 GiB default `host_capacity` exceeded the 238 GiB machine."

That third one indicts § 5.2 directly. `<root>/capacity` is an operator-declared line with no
cross-check against the machine, and nothing in § 5, § 6 or § 7 permits deriving it from the kernel.
prodbox hit precisely that defect class and fixed it by **observing** the host
(`src/Prodbox/Capacity/HostProbe.hs`, a first-class module per
`DEVELOPMENT_PLAN/system-components.md:85`). Adopting § 5.2 as written reintroduces the
unobserved-declaration shape one layer up, against a doctrine built on the opposite principle.

Separately, the failures that *did* dominate — the gateway OOM-cycling on a ~460 MiB pod cgroup limit
(`DEVELOPMENT_PLAN/README.md:4063`), the 750m CPU limit at ~93% throttle with periodic RTS
heap-overflow that "passed every capacity validation yet still failed at runtime"
(`DEVELOPMENT_PLAN/00-overview.md:200-203`), and the July 4 host OOM (`00-overview.md:183`) — all sit
on the far side of the protocol's boundary. § 3 puts containers in the host scope, so a pod's memory
limit has no representation at all, and § 8 disposes of the rest: "it applies no limit, and it fences
no device."

### 3.7 The one defect the document would actually fix in existing code

prodbox holds four cross-process POSIX record locks, all classic `fcntl`:

- `src/Prodbox/Config/LocalRetainedRoot/Internal.hs:938`
- `src/Prodbox/Gateway/Emitter/Journal.hs:424`
- `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:1963`
- `src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs:734`

`unix-2.8.8.0/System/Posix/IO/Common.hsc:441-443` implements `setLock` as
`c_fcntl_lock fd (#const F_SETLK) p_flock` — the family § 6.2's lifetime table marks **LOST** on both
the unrelated-close and fork-parent-exits tests. Measured on this host:

```
fcntl holder, after unrelated close -> prober says: ACQUIRED   <- lock lost
ofd   holder, after unrelated close -> prober says: BLOCKED 11 <- lock held
```

The current mitigation is process-local and does not address it: `Journal.hs:373-374`,
`HostCleanupIntent/Internal.hs:1885-1886`, `LocalRetainedRoot/Internal.hs:895`. In particular
`HostCleanupIntent/Internal.hs:1885-1887` hand-rolls

```haskell
{-# NOINLINE processIntentLocks #-}
processIntentLocks :: MVar (Set FilePath)
processIntentLocks = unsafePerformIO (newMVar Set.empty)
```

purely because classic POSIX record locks do not conflict with the same process. That is an
`unsafePerformIO` global in a repository whose `pure_fp_standards.md` § 3.1 is titled "No hidden
mutable control flow" — a standing doctrine violation that exists only because the lock primitive is
wrong. **Migrating to OFD deletes it.** This is the highest-value, lowest-blast-radius item in the
document, and it is extractable without adopting anything else.

**The migration is not a one-line change, and the naive path is wrong.** `grep -rn "F_OFD"` over
`unix-2.8.8.0/` returns nothing, and the repository has zero FFI (`grep -rn 'foreign import'` over
`src/ test/ app/` is empty; `prodbox.cabal` has no `c-sources` or `extra-libraries`). OFD *is*
reachable through `GHC.IO.Handle.Lock.hLock` — verified on this toolchain: `nm -u Lock.o` resolves to
`GHCziInternalziIOziHandleziLockziLinuxOFD_lockImpl1`, whose own `nm -u` shows `fcntl64` while the
unused `Flock.o` shows `flock`. But the obvious Haskell translation leaks. Measured, ghc 9.12.4 /
base-4.21.2.0, holder = `openFile p ReadWriteMode; hLock h ExclusiveLock; spawnProcess "/bin/sleep"`:

```
holder pid 2640700 ... 6 -> .../lockfile
child  pid 2640704 ... 6 -> .../lockfile
after SIGKILL of holder (child alive? yes): ofd BLOCKED errno=11   <- grant leaked
with handleToFd h >>= \fd -> setFdOption fd CloseOnExec True:
child fds on lockfile: (none - CLOEXEC worked)
after SIGKILL: ACQUIRED
```

`openFile` does not set `FD_CLOEXEC`, so a participant that follows § 6.2's Python sample in the
obvious way passes every same-mechanism conformance cell and still leaks grants on crash — the exact
failure § 4.3 forbids and § 9 promises cannot happen. The required recipe is
`openFile` → `hLock` → `handleToFd` → `setFdOption CloseOnExec`, which also forfeits buffered
`Handle` IO and forces `fdWrite`/`fdSeek`/`setFdSize` for § 7.1's write-and-truncate. **§ 11 should
name this.**

### 3.8 The one genuine local collision

`--builddir=.build` is a fixed repo-relative path shared by four independent commands:

- `src/Prodbox/CheckCode.hs:636` — `["build","--builddir=.build","all","--enable-tests","--ghc-options=-Werror"]`
- `src/Prodbox/TestRunner.hs:727` — `["build","--builddir=.build","all","--enable-tests"]`
- `src/Prodbox/TestRunner.hs:744-748` — `["test","--builddir=.build",…]`
- `src/Prodbox/BuildSupport.hs:60` — `["list-bin","--builddir=.build","exe:prodbox"]`

and `BuildSupport.hs:50-51,75` copies over `.build/prodbox`, a single canonical path that may be
mid-execution (`ETXTBSY`). There is no guard: `grep -rniE 'already running|single-instance|pid ?file'`
over `src/` returns nothing relevant, and the four `setLock` sites are all per-store, not per-host.

This is the only local double-booking hazard evidenced in the tree, and the protocol does not reach
it. It is not a `host:`/`gpu:`/`disk:`/`vm:` domain, so it needs an open family for which § 5.3 fixes
no spelling — meaning a second checkout naming it differently would not conflict. Worse, § 8's own
boundary reads it out of scope: "Reading a file, compiling, and linting are not governed." The
recorded instance also had a bare `cabal build` on one side, which § 10 leaves unconstrained.

### 3.9 The expensive contention is out of reach by construction

prodbox's genuinely scarce resources are AWS-account-wide, not host-local:

- `src/Prodbox/Aws.hs:574-586` — seven hard-coded account quota codes (vCPU `L-1216C47A`, VPCs
  `L-F678F1CE`, IGWs, EIPs, security groups, hosted zones `L-4EA4796A`, subnets)
- `src/Prodbox/Aws.hs:518` — four fixed stack names: `aws-eks-subzone`, `aws-eks`, `aws-test`, `aws-ses`
- `src/Prodbox/Aws.hs:566-567` — `prodboxIamUserName = "prodbox"`, a fixed account-global identity
- 45 Pulumi-managed AWS resources across those stacks, including `aws:eks:Cluster` and `aws:eks:NodeGroup`

§ 3 requires a claim "in the scope where the resource lives" and mandates `Unsupported` when that
scope is unreachable, adding "Nothing spans two kernels because nothing attempts to." A per-kernel
rendezvous cannot arbitrate any of these. Two operators on two machines sharing the account collide
on `aws-eks` and the `prodbox` IAM user with no protection, and a `/var/lib/hostgrant` grant on
either machine is invisible to the other. The protocol addresses the cheap, single-tenant half of
prodbox's contention surface and is structurally incapable of touching the expensive half.

### 3.10 prodbox already has a stronger guard for the one domain that matters

The two host-global resources a second prodbox run would actually destroy — the one RKE2 install and
the binary-sibling production config — are already guarded by a typed refusal that runs before any
test entrypoint:

- `src/Prodbox/TestRunner.hs:278-296` — `data TestGate = TestGateClear | TestGateRefuse TestRefusal`;
  `TestRefusal = ProductionConfigPresent FilePath | ProductionClusterRunning ClusterEvidence | …`
- `src/Prodbox/TestRunner.hs:441-451` — `testProductionClusterGate`, driven at `:437` by
  `clusterPresent <- rke2InstallPresent`

It refuses by **observing the resource**, not by consulting a peer ledger, so it also catches a
cluster a human created outside prodbox entirely. § 10 states the protocol explicitly cannot do that:
"Non-participants are unconstrained, and on POSIX the lock is advisory." For the domain the protocol
would most plausibly govern here, the existing gate is strictly stronger, and cannot be defeated by a
peer that forgot to declare or by a `Malformed` slot.

### 3.11 Adoption cost

**Surface.** Applying § 8's own boundary examples plus device and host-port use, `src/Prodbox`
contains **53 executed call sites** of governed host work in six categories (local RKE2 lifecycle,
Pulumi stack mutation, docker, host-saturating `cabal`, elevated host repair, host sysctl/dropin
writes). Two of § 8's named categories — VM/substrate lift and device use — have **zero** executed
sites. The 53 are not 53 independent problems: they funnel through roughly six helpers
(`Rke2.hs:9770` `runCommand`, `Rke2.hs:2029` `bootstrapStepAction`,
`ProviderProduction.hs:655-664` `runPulumi`, `Rke2.hs:9468/9481` docker). The real cost is token
plumbing from entrypoint down to those helpers.

**No ambient environment to hang a grant on.** `src/Prodbox/App.hs:59` defines
`newtype App a = App {unApp :: ReaderT Env IO a}`, but production dispatch is
`App.hs:129-131` → `runNativeCommand repoRoot command`, and `Native.hs:104` types that as
`FilePath -> NativeCommand -> IO ExitCode` — plain IO. Outside `App.hs`, the only `runApp` reference
in the tree is `test/unit/Main.hs:9241`. Either revive `App`/`Env` across the whole command tree, or
thread a `Grant` argument explicitly.

**The natural chokepoint exists but is fenced.** `CLI/Command.hs:475` `runPlanWithOptions` is a
lint-enforced funnel (`CheckCode.hs:4685`) with 28 real call sites, and changing the apply closure to
`Grant -> payload -> IO ExitCode` would discharge § 8 for every Plan/Apply command. But
`Native.hs:196-201` states the prohibition in prose: "Deliberately NOT wired into a universal
dispatch-level gate … A dispatch-level gate would break the Plan/Apply dry-run contract." And it
would not cover `prodbox test` / `dev check` — `TestRunner.hs` and `CheckCode.hs` are absent from the
funnel, so the three host-saturating `cabal` sites need separate handling.

**Windows.** prodbox's Windows support is a classification and an argv builder with no production
caller. `Host/Substrate.hs:30` classifies `mingw32`; `Host/Lift.hs:45-46` folds to `ViaWsl2VM`; but
the only importers of `Prodbox.Host.Lift` are `DockerConfig.hs:45` and `test/unit/Main.hs:981`, the
WSL2 "install" step is an `InstallHint` string (`Host/Ensure.hs:106-108`), ten RKE2 paths hard-refuse
off-Linux (`CLI/Rke2.hs:9777-9781`), and `prodbox.cabal` has no `os()` conditional while depending
unconditionally on the POSIX-only `unix`. prodbox therefore never executes in the Windows-kernel
scope. That makes § 11's entire unverified-Windows register unreachable for prodbox — but § 6.2's
byte-0 reservation, justified solely by that unrun measurement, would still shape prodbox's on-disk
slot format permanently.

**Net benefit today.** `/var/lib/hostgrant` does not exist on this machine, and no other project on
it implements the policy. Per § 6.1 a conforming prodbox would report `Unsupported` for every claim
today. With participants = 1, admission reduces to self-exclusion, and everything prodbox would gain
a single lock file delivers. The only genuinely extra capability is the standing claim, which
[§3.5](#35-the-witness-is-unsound-for-both-of-prodboxs-standing-resources) shows prodbox cannot
construct soundly for either substrate.

---

## 4. Defects in the protocol itself

These are worth fixing regardless of whether prodbox adopts, because § 11 makes the pseudocode the
contract ("Matching prose and matching digests establish nothing").

1. **§ 7.2's `acquire()` does not implement § 5.2's malformed rule.** § 5.2 says "An exclusive claim
   on a measured domain, or a counted claim on an exclusive one, is malformed." `acquire()` validates
   only the grammar (`valid` is the regex), then the counted branch indexes `capacity[d]`
   unconditionally. One implementer raises a missing-key exception; another returns `Malformed`. That
   is precisely the disagreement § 5.1 says the policy exists to prevent.
2. **`free_slot_of_mine()` can overwrite a live standing claim.** § 4's table specifies that a
   standing claim is written "Into the owner's slot, **lock not held**." A lock-based free test
   therefore reports that slot free, and the participant would take the lock and `ftruncate` over its
   own live claim. The rule that would prevent this is never stated.
3. **The self-conflict exemption has two incompatible readings.** The prose says a participant must
   not count *its own live slots*; the pseudocode guards `s.participant == me and s.index in
   my_own_process_slots` — per-process. Under the per-process reading a participant conflicts with
   its own standing claim and can never re-acquire the domain to tear the resource down, which
   contradicts § 4.2's promise that "no participant is ever barred from releasing capacity it owns."
4. **`acquire()` is the only specified operation.** Release, and promotion of a grant to a standing
   claim, are unspecified — yet § 4 requires both to exist.
5. **`Malformed` has scope-wide blast radius with no repair path.** It is triggered by any peer's
   slot, `reserved`, or `capacity`, and is explicitly non-retryable. One buggy participant writing
   one bad byte is a permanent outage for every participant in the scope — and § 6.1's sticky-bit
   rule means the victim cannot remove the offending entry. Combined with the 1777 world-writable
   root and the "not a security boundary" disclaimer, the denial-of-service surface is larger than
   § 10 discloses.
6. **`protocol-version` is read outside `admission.lock`,** and `VersionMismatch` — an eighth return
   value — is missing from § 7.2's seven-refusal table and its retry semantics.

Additionally, **§ 4.1's "self-clearing in every failure" is not exhaustive** (see
[§3.5](#35-the-witness-is-unsound-for-both-of-prodboxs-standing-resources)), and **§ 10's
"only shared-host failure" sentence is false** (see
[§3.6](#36-10s-load-bearing-sentence-is-false-for-this-repository)). Both are single-sentence fixes.

Minor: there is no fairness or anti-starvation property at all — admission is non-blocking `try_lock`
plus randomised backoff, and `Conflicted` "ends when that holder does." A multi-hour `test all` would
starve a short competitor indefinitely. § 10 does not disclose this.

---

## 5. Repository integration

### 5.1 The delegation dangles

`documents/engineering/README.md:21` sets the rule:

> "A document may define a target before cutover only when it says so explicitly **and** delegates
> implementation and qualification status to the Development Plan."

The document satisfies the first half ("**Not adopted.**") and the second half in form ("Adoption
status is owned by the development plan, not by this file"). But the entire `DEVELOPMENT_PLAN/` tree
contains no sprint, phase, ledger row, or backlog entry that owns it. The delegate never accepted, so
the document is currently unownable: no one is responsible for deciding it, and no surface records
that it is undecided.

### 5.2 The index entry mis-signals

`documents/engineering/README.md:78` describes the content but omits the not-adopted caveat that its
peers carry — `pulsar_topic_lifecycle_doctrine.md` is indexed as "a target contract rather than a
current-source guarantee," `host_platform_doctrine.md` as "an explicitly marked target." It is also
filed under the **Resource Governance** heading (`README.md:185`) beside adopted doctrine. A reader
of the index alone would take it as current.

### 5.3 Term collision

"shared-host" already means the shared-**hostname** public edge in this repository — Sprints
`5.1`–`5.4` in `DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md`, `prodbox edge status`,
`src/Prodbox/Host.hs`'s route classification, and `envoy_gateway_edge_doctrine.md`. It appears in
that sense in roughly 90 places. A document titled "Shared Host Resource Protocol" in the same
directory overloads a load-bearing project term with an unrelated meaning.

### 5.4 Tracked Python

`git ls-files | grep '\.py$'` returns exactly `documents/engineering/crash_harness.py` and
`documents/engineering/hostgrant_probe.py`. `AGENTS.md:22` states "The repository is Haskell-only on
the supported path," and `AGENTS.md:66-77`'s worktree structure lists no such location. The document
anticipated this and offered an escape hatch in § 11 — "A repository whose source policy forbids a
tracked artifact in that language generates it instead" — which was not taken.

Neither file is scanned by any gate: `isGovernedDocPath` (`CheckCode.hs:5014-5019`) covers only
`documents/`+`DEVELOPMENT_PLAN/` markdown and the three root ALL-CAPS files, and the
subprocess-boundary policy scans Haskell under `src/Prodbox`. So they are inert with respect to
`dev check`, and equally unmaintained by it.

### 5.5 A fifth admission vocabulary

`resource_scaling_doctrine.md:39-40` already calls `fitsWithin` "the authored admission algebra," and
the source carries three more live `Admission` namespaces with their own refusal taxonomies:
`Lifecycle/Authority/Admission.hs:14`, `ControlPlane/Capacity.hs:228-241` (`AdmissionQueue`,
`RejectionReason`), `Lifecycle/DependencyAdmission.hs:72`. The protocol's words —
`admission`, `capacity`, `reserved` — collide with existing ones meaning something else
(`Capacity/Config.hs:102-104` `host_capacity`).

In fairness, § 8 defuses the *authority* conflict explicitly: "A granted lock is **coordination, not
evidence**. It is not typed evidence for any state transition … Existing enforcement is unaffected
and is not replaced." The problem is nomenclature, not semantics — but a `Prodbox.HostGrant.Admission`
sitting beside three other `Admission` modules guarantees a reader will conflate them.

### 5.6 Churn

The file has been rewritten seven times in two days: `869 → 1032 → 83 → 111 → 357 → 362 → 583` lines
(`b0804fa`, `cea6305`, `2acb2c4`, `35e1e5c`, `7d8e8ed`, `a83c0b5`, `fe3ed61`), in a directory whose
README describes its contents as "stable doctrine and architecture references."

---

## 6. What the document gets right

This section is not balance for its own sake. Several criticisms that look obvious are wrong, and the
document contains work worth copying.

**§ 1's falsification table is auditable against this repository's own git history.** v1 is at
`b0804fa` titled `# Finite Resource Execution Authority Protocol`, exactly as the Supersedes line
claims; `a83c0b5` line 218 carries the inverted `FD_CLOEXEC` MUST that § 1 records reversing. Only
four other documents in `documents/engineering/` carry a non-`N/A` Supersedes line, and **none
records what its predecessor got wrong**. Deleting § 1 as throat-clearing would delete the only
auditable record of why the current mandates point the way they do — including one that was reversed
180 degrees.

**The reversed `FD_CLOEXEC` rule is independently corroborated by prodbox's own code.**
`Gateway/Emitter/Journal.hs:400-406` opens its lock file with `cloexec = True` (recurring at `:630`,
`:734`, `:748`); `Config/LocalRetainedRoot/Internal.hs:911` does the same. The document arrived by
measurement at the rule prodbox arrived at by construction. A critic reading § 1's inverted MUST as
evidence of unreliability has the inference backwards.

**§ 11's unverified register has no counterpart in the suite.** Across the engineering documents,
`grep -i "not verified|unverified|treated as unknown"` returns this file, one inline aside in
`acme_provider_guide.md:237`, and `chaos_hardening_doctrine.md:299,481,813` — where the usage is a
*prescription* telling other work to keep such a register. This is the first document in the suite to
apply that discipline reflexively, including "Whether any second participant exists." If the
chaos-doctrine posture is meant to become normal rather than aspirational, this file is the working
exemplar.

**§ 11's most hedged item is exactly right about prodbox's toolchain** — see
[§3.7](#37-the-one-defect-the-document-would-actually-fix-in-existing-code). It is a disclosure of
adoption cost that a document arguing for adoption had every incentive to omit.

**The OFD migration argument is sound in both directions, and prodbox is already inside the family.**
Measured here: an OFD holder blocks an `fcntl` prober *and* an `fcntl` holder blocks an OFD prober,
both errno 11 — so safety holds throughout a partial migration. A `flock` holder is acquired by both
others and vice versa. Had the document mandated `flock` — the mechanism most people reach for —
prodbox's existing journal lock would have become invisible to the new protocol on the day of
adoption, silently.

**"Validity decided by observation, never by a clock" is the right design, and prodbox's history
proves it.** `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md:1384` records a durable bootstrap
session fence that no supported command could clear, where "**Seven prescribed remedies were refuted
by measurement across this row's life**" across Sprints `2.47`/`2.48`/`2.49`; `:1382` records an
expired Kubernetes Lease that "read as still live" **1h44m** after expiry, permanently refusing
retirement. Both are the class the witness design forgoes. The honest boundary, which the document
draws itself: prodbox's leases are cross-node, where no pid+start-time witness is observable and a
clock is unavoidable. § 2's "Scope — one kernel" is precisely the restriction that *buys* the
no-clock property. The transferable rule is narrower and still valuable.

**§ 10 is the load-bearing section, not the concession.** Declaring the protocol useless against the
failure class the author believes is most common is the same move as
`chaos_hardening_doctrine.md:1105` ("What a ring-2 gate does and does not prove"),
`config_doctrine.md:712` ("What decoding does and does not validate"), and
`development_plan_standards.md:378`. The sentence inside it is wrong for this repository
([§3.6](#36-10s-load-bearing-sentence-is-false-for-this-repository)); the section's existence is
correct.

**Two ideas generalize past the protocol**, and both have bitten prodbox in recognizable form:

- *An unestablished coordination surface reads as an empty one and succeeds every time* (§ 6.1's
  auto-created bind-mount). prodbox instances: a no-cluster `--cascade` returning exit 0 proves
  nothing about AWS; `legacy-tracking-for-deletion.md:1377` records a helm filter that "returned only
  releases whose `helm list` status was not `deployed`, so an all-`deployed` chart root produced the
  empty list and `deployChartPlan` returned **a success report with no helm invocation behind it**";
  and `PRODBOX_TEST_HOST_CAPACITY` is a path where an unestablished observation can read as an
  established one.
- *The diagonal cell establishes nothing; every mechanism excludes itself* (§ 11). Applies to any
  integration assertion where fixture and system under test share an implementation.

**One thing prodbox could contribute back.** § 11's first unverified item is whether a container
runtime's init process is a usable witness. prodbox's standing local resource is not a
container-runtime cluster but a systemd unit at a fixed name (`CLI/Rke2.hs:569`), which has a
well-defined, narrow MainPID and start time — § 4.1's "narrowest process" with none of the ambiguity
the register worries about. That is a measurement this project could supply rather than consume.

---

## 7. Candidate findings discarded on verification

Recorded so they are not re-raised. Each was produced during review and then refuted on direct
re-checking.

| Candidate | Why it was dropped |
|---|---|
| "§ 11's pass-criterion shell snippet is a syntax error and fails open with exit 0" | The syntax error came from including the closing markdown fence in the extraction. The snippet's `<the participant under test>` is a placeholder for the reader's own implementation, not for `hostgrant_probe.py` — which is the *prober*, and is used correctly. § 11 states the cells, not the script, are the contract |
| "`hostgrant_probe.py` violates § 6.2's `O_CREAT never` MUST" | There is no such MUST. The real rule (§ 7.2) forbids a **participant** creating a **slot** at runtime; the probe is not a participant and § 11 points it at `mktemp`. `crash_harness.py`, the participant-shaped artifact, does obey. `O_CREAT` can only turn a control-cell `ENOENT` into the ACQUIRED that cell must print anyway — it cannot produce a false PASS |
| "§ 5.2's 'different, exclusive domain' contradicts § 7.2's prefix refusal" | Not a contradiction. § 5.2's sentence is scoped to the arithmetic ("exact domain match, never a prefix sum") and classifies the domain as *exclusive*, which places it under § 5.1's prefix rule by construction. Reaching the refusal requires violating § 5.2's own MUST, and the resulting `Conflicted` is retryable. A real but minor completeness gap remains: § 7.2 resolves the exclusive-vs-counted prefix case asymmetrically depending on which arrives first |
| "The fixed PRNG seed makes § 7.3's cross-platform identity a property of `random`, not a measurement" | True of the counters, but not of the load-bearing claim. The file-count result holds under any seed — and holds for a stronger reason, given in [§2.2](#22-what-does-not-hold-73s-evidence) |

---

## 8. Recommendations

**Do not adopt.** The protocol would prevent a class of contention prodbox has never hit, cannot
express the class it has hit, cannot arbitrate the resources it actually pays for, and cannot
construct a sound witness for either of its standing resources. Any adoption case should rest on a
**named second participant**, not on prodbox's own incident history.

Three things are worth extracting, and none of them requires the protocol:

1. **Migrate the four `setLock` sites to OFD.** This is a real, currently-latent correctness defect
   in shipped code, and it deletes the `unsafePerformIO` global at
   `HostCleanupIntent/Internal.hs:1885`. Use `handleToFd` + `setFdOption CloseOnExec` — the naive
   path leaks, measured. See [§3.7](#37-the-one-defect-the-document-would-actually-fix-in-existing-code).
2. **Put a single-instance guard on `.build/`.** The only local double-booking hazard in the tree,
   closable with `withMarkerLock`-shaped code the repository already owns. See
   [§3.8](#38-the-one-genuine-local-collision).
3. **Keep the two transferable rules** from [§6](#6-what-the-document-gets-right) — vacuous success
   from an unestablished surface, and the diagonal-cell rule — and apply them to the `--cascade`
   teardown paths, `PRODBOX_TEST_HOST_CAPACITY`, and shared-implementation integration assertions.

For the document itself, in descending order of value:

- Fix the six § 4 defects, especially the § 7.2 pseudocode gap, before anyone implements it anywhere.
- Correct § 10's "only shared-host failure" sentence and § 4.1's "self-clearing in every failure".
- Replace § 7.3's console block, or state plainly that the harness demonstrates the file-set property
  by construction rather than measuring it.
- Add the Haskell `FD_CLOEXEC` recipe to § 11's runtime-lock-backends item.

For repository integration:

- Either open a Development Plan row that owns the decision, or record in the document that no plan
  surface owns it — the current state satisfies `README.md:21` in form only.
- Add the not-adopted caveat to the `README.md:78` index entry, matching how its peers are indexed.
- Rename off "shared-host" to avoid the collision with the shared-hostname edge doctrine.
- Decide the two tracked `.py` files: take § 11's generate-instead branch, or record an explicit
  exception to `AGENTS.md:22`.

---

## Related Documents

- [Shared Host Resource Protocol](./documents/engineering/shared_host_resource_protocol.md) — the document under review
- [Engineering documentation index](./documents/engineering/README.md) — the target-before-cutover rule (§ Roadmap)
- [Resource Scaling Doctrine](./documents/engineering/resource_scaling_doctrine.md) — the existing admission algebra and capacity units
- [Host Platform Doctrine](./documents/engineering/host_platform_doctrine.md) — substrate frames, and the storage-device identity the `disk:` family would collide with
- [Chaos Hardening Doctrine](./documents/engineering/chaos_hardening_doctrine.md) — the evidence-strength discipline § 11 applies reflexively
- [Development Plan](./DEVELOPMENT_PLAN/README.md) — the owner of adoption status, which currently holds no row for this
