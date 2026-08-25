# Shared Host Resource Protocol — Critical Analysis

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: A falsification-first review of
> [shared_host_resource_protocol.md](./documents/engineering/shared_host_resource_protocol.md) as it
> relates to prodbox — which of its claims survive independent re-measurement on this project's own
> host, which of its normative rules are falsified by its own evidence, whether prodbox has the
> problem it solves, and what adopting it would cost.

> **Not adopted; not owned.** This file is a review artifact. No sprint owns it, no gate reads it, and
> it changes no doctrine. Status for the protocol itself is owned by
> [Development Plan → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here) — see § 3.5, which is
> about the fact that the protocol document no longer says so.

---

## 0. Method and measurement environment

Every empirical claim below was re-derived on this project's primary host rather than taken from the
document. Where a cell could be measured, it was measured, with a negative control run before the
contended case.

| | |
|---|---|
| Host | `bathurst` |
| Kernel | `Linux 7.0.0-28-generic #28~24.04.1-Ubuntu SMP PREEMPT_DYNAMIC x86_64` |
| libc | glibc 2.39 (Ubuntu GLIBC 2.39-0ubuntu8.8) |
| Filesystem | ext4 (`/dev/sda2`) |
| Toolchain | GHC 9.12.4, `base ^>=4.21.2.0`, `unix ^>=2.8.8.0`, `typed-process ^>=0.2.13.0` |
| Document revision | `a83c0b5`, 362 lines |

This differs from the environment the document measured on (`Linux 6.8.0-100-generic aarch64`,
Ubuntu 24.04.4, ext4, and `Darwin 25.5.0 arm64`) in both kernel major version and architecture, which
makes the reproduction below a stronger result than a re-run would have been.

The review ran as a fan-out over seven independent lenses — doctrine overlap, adoption cost, real
contention evidence, documentation governance, protocol correctness, security, and operability —
followed by an adversarial verification pass in which every fatal/major candidate was handed to a
separate reviewer instructed to refute it and to default to refuted when it could not independently
re-derive the evidence. Seventy-three candidate findings were produced; twenty-four were material
enough to verify; **twelve survived and twelve were killed.** The twelve that were killed are recorded
in § 8, in the same spirit as the document's own § 1, so the same ground is not re-argued.

---

## 1. Verdict

**The document's physics is right and its governance is broken.**

Its load-bearing empirical claim — the § 6.2 lock-family matrix — reproduces cell-for-cell on a
different kernel and a different architecture from the one it was taken on. A design document whose
central measurement survives independent re-derivation is rare and should be credited plainly. The
OFD mandate that rests on it is correct, and correct for the reason the document gives.

Against that: two of its normative rules are falsified by measurements the document itself publishes
three sections earlier; the reserve/grant dichotomy has no representation for the resource prodbox
most needs to arbitrate; the one genuinely contended shared resource this project has is placed out
of scope by definition; and at `HEAD` the file violates the engineering index's own Roadmap rule as a
two-day-old regression, having carried a compliant delegation two commits ago.

The honest summary of fit is narrower than either "adopt" or "reject": **adoption is cheap and buys
prodbox almost nothing today**, because prodbox has already built both coordination shapes the
protocol offers, and every shared-host failure it has actually recorded falls in the class § 10
excludes.

---

## 2. What holds up

These were checked by running them, not by reading them. They are listed first because the defects in
§ 3 are corrections to a document that is substantially right, not a rejection of it.

### 2.1 The § 6.2 Linux matrix reproduces exactly

Three POSIX mechanisms, nine cells, negative control (`ACQUIRED` on an unheld file) before every one:

```
holder=flock  prober=flock  control=ACQUIRED  contended=BLOCKED 11
holder=flock  prober=fcntl  control=ACQUIRED  contended=ACQUIRED
holder=flock  prober=ofd    control=ACQUIRED  contended=ACQUIRED
holder=fcntl  prober=flock  control=ACQUIRED  contended=ACQUIRED
holder=fcntl  prober=fcntl  control=ACQUIRED  contended=BLOCKED 11
holder=fcntl  prober=ofd    control=ACQUIRED  contended=BLOCKED 11
holder=ofd    prober=flock  control=ACQUIRED  contended=ACQUIRED
holder=ofd    prober=fcntl  control=ACQUIRED  contended=BLOCKED 11
holder=ofd    prober=ofd    control=ACQUIRED  contended=BLOCKED 11
```

Identical to the document's table. The two-family conclusion — `{flock}` and `{fcntl, OFD}` — holds on
this architecture. `F_OFD_SETLK = 37` and the `struct.pack("hhqqi", ...)` field layout are both
correct for x86_64.

### 2.2 The lifetime table reproduces exactly

```
flock  second-fd-close       -> SURVIVED
flock  fork-parent-drops-fd  -> SURVIVED
fcntl  second-fd-close       -> LOST
fcntl  fork-parent-drops-fd  -> LOST
ofd    second-fd-close       -> SURVIVED
ofd    fork-parent-drops-fd  -> SURVIVED
```

OFD really is the only mechanism with both properties, which is the whole argument for the mandate.

### 2.3 The adoption-cost asymmetry is true for prodbox specifically

§ 6.2's strongest paragraph argues that moving an `fcntl` participant to OFD keeps it inside the
family — so an un-migrated participant is *blocked rather than ignored* — whereas moving it to `flock`
would silently remove it. This is not a generic claim here; it was measured against prodbox's own code.

prodbox takes classic `fcntl` write locks at exactly four sites:

| Site | Guards |
|---|---|
| `src/Prodbox/Config/LocalRetainedRoot/Internal.hs:938` | `.cluster-established.lock` |
| `src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs:734` | test-artifact intent journal |
| `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:1963` | `.host-cleanup-intent.lock` |
| `src/Prodbox/Gateway/Emitter/Journal.hs:424` | `.emitter.journal.lock` |

All four are `setLock fd (WriteLock, AbsoluteSeek, 0, 0)`. A Haskell holder built against those exact
APIs (`unix-2.8.8.0`, GHC 9.12.4) blocks both an `fcntl` prober and an OFD prober and admits only a
`flock` prober. prodbox is already inside `{fcntl, OFD}`. A conforming OFD participant would correctly
exclude un-migrated prodbox today.

### 2.4 The mechanism costs near zero in Haskell — contrary to the obvious assumption

The natural objection is that `unix-2.8.8.0` exposes only `getLock`/`setLock`/`waitToSetLock` — no OFD
entry point — and that prodbox has zero `foreign import` and declares no `c-sources`, so OFD would be
the repository's first FFI plus a hand-laid, arch-dependent `struct flock`. All of that is true and
was verified.

It is also not the only path. `base ^>=4.21.2.0` — already pinned — ships `GHC.IO.Handle.Lock`, and on
this host that backend **is** OFD: `ghc-internal-9.1204.0` contains `Handle.Lock.LinuxOFD`, and
behaviourally a `hTryLock ExclusiveLock` holder blocks an `fcntl` prober and an OFD prober while
admitting a `flock` prober. That is the `{fcntl, OFD}` family, with no FFI. The FFI cost would only
bite on Windows, where § 6.2's one-byte rule diverges from base's whole-file `LockFileEx`.

### 2.5 The `rename(2)` retraction is correct, and prodbox arrived at it independently

§ 1 row 5 retracts atomic rename for record content because "`rename(2)` repoints the name at a new
inode, orphaning the lock held on the old one". prodbox discovered the adjacent hazard on its own and
wrote it down at `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:1261-1264`:

> POSIX record locks are process-scoped: closing another descriptor for the locked inode can
> otherwise drop the active lock. The lock therefore has its own inode, and aliases share this one
> process-local reservation key.

That is the document's `fcntl` **LOST** cell, found independently. Two independent arrivals at the
same correction is real corroboration. It also means the OFD mandate would let prodbox retire the
`retainedRootProcessLock :: MVar ()` / `reserveProcessIntentLock` workaround table
(`src/Prodbox/Config/LocalRetainedRoot/Internal.hs:895`) that exists only because classic `fcntl` does
not self-conflict.

### 2.6 § 8's disclaimer prevents a hard SSoT collision

> A granted lock is **coordination, not evidence**. It is not typed evidence for any state
> transition, it applies no limit, and it fences no device. Existing enforcement is unaffected and is
> not replaced.

Without that sentence this would be a second admission authority standing beside
`resource_scaling_doctrine.md`'s opaque proof-carrying `AllocatedResourcePlan` (`:257-258`), and the
seam would need adjudicating. With it, the two are conjunctive refusals and need no precedence rule.
§ 8's obligation — "the grant MUST NOT be constructible outside the module that obtained it" — is also
already prodbox's idiom (hidden constructors behind `.../Internal.hs`), so discharging it would be
routine rather than novel.

### 2.7 The domain algebra is correct, and the honesty registers are exemplary

All of the document's own assertions hold when executed verbatim, including the one that matters most:
`conflicts("gpu:0", "gpu:01")` is `False` — prefix conflict at a **segment boundary**, not string
prefix. `valid()` correctly rejects `gpu:`, `hostmemory`, and `gpu:0 `. The extension-asymmetry
argument (a new family costs nothing because the only operations are equality and prefix) is sound.

§ 1's self-falsification table, § 10's "what this policy does not do", and § 11's eight-item
not-verified register are unusually honest — closer to `chaos_hardening_doctrine.md`'s
proven/tested/assumed ledger than to typical RFC prose. § 11 in particular records that the
conformance test is meaningless on the platform most people develop on, which the author had no
incentive to write down. Several findings below are extensions of gaps § 11 half-identified rather
than contradictions of it.

---

## 3. Confirmed defects

Each survived an adversarial verification pass whose default was refutation.

### 3.1 The `FD_CLOEXEC` mandate falsifies § 9's crash-safety table — MAJOR

**The claim.** § 6.2 states flatly: "`FD_CLOEXEC` MUST be clear on the grant descriptor," justified by
one measurement — that with the flag set, the lock is released when the holder `exec`s. § 9 row 1
promises "**No resource leaks.** The kernel releases the lock; domains are free immediately". § 4
removes every recovery mechanism on the strength of that promise: "No record outlives its holder, so
there is no reclaim rule, no time-to-live, no boot identity and no operator escape hatch."

Those cannot all be true, and the document already published the measurement that breaks them. Its own
lifetime table scores `fork`, parent exits, child keeps the descriptor as OFD **SURVIVED** — and makes
that survival the stated reason OFD is mandated.

**The measurement.** Controlled pair, one ordinary spawned tool (`sleep`), `close_fds = False`, SIGKILL
of the holder. The only variable changed between runs is the bit § 6.2 mandates:

```
=== FD_CLOEXEC clear (the document's mandate) ===
control (holder alive):            BLOCKED 11
after SIGKILL of grant holder:     BLOCKED 11
child fds pointing at slot:        1          (cmd: sleep 30)
/proc/locks:                       OFDLCK ADVISORY WRITE -1 08:02:14295903 0 EOF
after killing the inheriting child: ACQUIRED

=== FD_CLOEXEC set (negative control, forbidden by the document) ===
control (holder alive):            BLOCKED 11
after SIGKILL of grant holder:     ACQUIRED
child fds pointing at slot:        0
```

The grant outlives its holder **if and only if the mandate is obeyed**, and the surviving holder is a
non-participant that knows nothing about the protocol. `/proc/locks` reports owner PID `-1`, so there
is not even a process to blame — consistent with § 9's own renunciation of PID-based liveness, and
fatal to recovery.

Independently reproduced a second way, from a Haskell binary built against prodbox's own pinned
dependencies (`openFile` + raw `F_OFD_SETLK` + `Typed.startProcess (proc "/bin/sleep" ["6"])` +
immediate exit), with the same result.

**Why the flat MUST is the wrong shape.** The exec-replacement case it was measured against occurs at
exactly one site in this repository — `src/Prodbox/Lifecycle/Decommission/Verifier.hs:802` — and that
site holds no lock. prodbox is the other shape: a supervisor that spawns and outlives its children,
through `src/Prodbox/Subprocess.hs` on `typed-process` (`pcCloseFds = False`), imported by 74 modules
across `src/`, `app/` and `test/`. Measured directly:

```
FD_CLOEXEC=set   case=exec-replace     -> lock LOST
FD_CLOEXEC=clear case=exec-replace     -> lock SURVIVED
FD_CLOEXEC=set   case=fork-exec-child  -> lock SURVIVED
FD_CLOEXEC=clear case=fork-exec-child  -> lock SURVIVED
```

For prodbox's actual process model the mandate buys nothing and leaks a writable descriptor to the
rendezvous into every `kind`, `kubectl`, `aws`, `vault`, `pulumi` and `helm` invocation.

**Consequence for prodbox.** A `kubectl port-forward` orphaned by an aborted `prodbox test all` would
hold its inherited grant until reboot. § 7's four refusal classes offer a permanent `Conflicted` and
no command to clear it. prodbox already fights orphaned port-forwards; this converts one into a
machine-wide admission deadlock.

**Also note the direction of travel.** prodbox sets `cloexec = True` at all 32 `openFd` sites today —
it already does the safe thing the document forbids. Adoption means flipping 32 deliberate settings to
the unsafe one.

**Fix.** Make the rule conditional — clear `FD_CLOEXEC` only immediately before an intentional
exec-replacement of the holder — or pair it with a spawn-side `close_fds` MUST. Note that `close_fds`
closes in the child *after* fork and therefore satisfies § 6.2 as written, which is why this is a
missing-rule defect rather than a forced dilemma.

**One accidental mitigation, worth recording because the document neither knows about it nor requires
it.** `sudo` on this host closes descriptors ≥ 3 before exec (measured: the child gets `EBADF`), which
would cover the subset of prodbox's exec sites that route through `sudo`. That is a sudoers-configurable
default, not a protocol property.

### 3.2 The mandated in-place slot write corrupts a slot on a normal, successful write — MAJOR

**The claim.** § 7 mandates that slot content is "written **in place while `admission.lock` is held**,
never by rename", and deletes fixed-size padding and checksums on the grounds that "Because every
reader takes `admission.lock` first, no reader can observe a partial write." That argument establishes
the absence of *torn* reads. It says nothing about *stale tails*, and the document never specifies
truncation. Slots are "pre-created and never unlinked at runtime", so every slot is permanently reused.

**The measurement.** Run with the document's own rules and its verbatim algebra — pre-created slot,
byte 0 reserved with the domain list at offset 1, real `F_OFD_SETLK` with the § 6.2 struct layout, and
`segments`/`conflicts`/`valid` copied unmodified. Run 1 takes the slot and writes four domains, then
exits. Run 2 takes the same slot, writes **one** domain in place, and holds its lock. A conforming
reader then observes:

```
raw slot bytes   : b'\x00host:cpu\nhost:memory\ngpu:0\ndisk:8f2a-b1\n'
reader parses    : ['host:cpu', 'host:memory', 'gpu:0', 'disk:8f2a-b1']
valid() per line : all True
acquire(['gpu:0']) sees conflict? True
```

Run 2 declared one domain and is advertised as holding four. Every residual line is well-formed, so no
`valid()` check fires and no refusal class is reached. Because § 7's admission loop skips only
*unlocked* slots, the residue is read while the new holder's lock is held and is charged to it.

A byte-misaligned shorter write produces `b'\x00host:cpu\nry\nhost:cpu\n...'`, whose `ry` line is
`valid() == False` — which § 5 obliges the reader to reject, under a refusal none of the four classes
at § 7 defines.

**Why it matters here.** prodbox solved § 1's rename objection the other way and would have to abandon
its house pattern to adopt this. It writes durable content by temp-file plus `renameFile`
(`src/Prodbox/Config/LocalRetainedRoot/Internal.hs:972`,
`src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs:930`,
`src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:1231`) while keeping the lock on a **separate
inode** precisely so the rename cannot orphan it — the pairing that preserves write atomicity *and*
lock stability. § 1 rejects rename outright without considering it, and
`resource_scaling_doctrine.md:543-544` makes "same-directory temporary-file rename" the mandated house
write.

**Fix.** One clause: truncate the slot to the written length under `admission.lock` — or restore the
fixed-size record that § 1 discarded.

### 3.3 Reserve/grant has no arm for standing capacity owned by a participant that tears it down — MAJOR

**The claim.** § 4 makes the classification binary and the test explicit: "If it outlives the session
and is expected to persist, it is a reserve; if it is per-run, it is a grant." It then makes
`<root>/reserved` "a line-oriented list of domains, edited by the operator and by nobody else."

prodbox's continuously-running RKE2 cluster is a reserve by that test. But prodbox is a *lifecycle
control plane whose central verb is reconcile-and-teardown of that standing substrate*, and
`prodbox cluster delete --cascade --yes` is a supported routine command. The participant is normatively
barred from editing the only file that can unblock it.

**The algebra offers no escape.** Running § 5's own `conflicts` verbatim:

```
conflicts('cluster:home-rke2', 'host:memory')      = False   # narrow: guards nothing memory-related
conflicts('host:memory',       'host:memory/build') = True    # wide: blocks every peer memory grant
conflicts('host:memory/rke2',  'host:memory')       = True
conflicts('host:memory/build', 'host:memory/test')  = False   # siblings stop conflicting entirely
```

No domain choice both guards the cluster's standing capacity and admits its own teardown. The available
workaround — a manual operator edit of `<root>/reserved` before and after every cascade — is exactly the
out-of-band step § 4 claims to have eliminated.

This is not an edge case for prodbox. It is the main line.

### 3.4 § 3 places prodbox's one genuinely contended resource out of scope by definition — MAJOR

**The claim.** § 4's sole justification for collapsing two grant kinds into one is "A resource only
contends while something runs; whatever runs can hold the lock." That is false for anything delegated
to a daemon, and the reserve/grant pair has no representation for the result.

**The measurement.** Ten seconds, no AWS involved, on this host:

```
$ docker run -d --rm --name gl2 --memory=64m alpine:3 sleep 600
$ bash -c 'sleep 600' &            # the "grant holder"
holder pid=2153654 alive=yes
$ kill -9 $HPID
holder alive after SIGKILL=no
container still running:            gl2  Up 2 seconds
host memory.max still reserved:     67108864
```

The kernel released everything it owned. 64 MiB of host capacity stayed consumed by a holder-less
resource that neither a grant (dies with its holder) nor a reserve (operator-edited only) can name.

**And the shared resource that actually contends here is out of reach entirely.** prodbox shares one
AWS member account across runs *and machines*. § 3's "Nothing spans two kernels because nothing
attempts to" means no rendezvous can ever arbitrate it. prodbox already solved that problem with the
TTL-plus-fencing lease in `LeaseInterpreter.hs` — the second grant kind § 4 declares unnecessary — after
killed runs stranded EC2/VPC/ENI residue.

**Fix.** Either scope the document explicitly to node-local resources, or acknowledge that resources
outliving their creator require the discarded second grant kind.

### 3.5 The target declaration and Development-Plan delegation were deleted two commits ago — MAJOR

`documents/engineering/README.md:20-22` permits a document to define a target before cutover "only when
it says so explicitly and delegates implementation and qualification status to the Development Plan."

At `HEAD` the protocol frames itself as a prodbox target — "the host resource coordination policy
prodbox **would** implement … and what adopting it would require" — carries 11 MUST, 6 MUST NOT and 1
SHOULD, and contains **zero** `DEVELOPMENT_PLAN` references. It is the only one of the 42 documents in
`documents/engineering/` that fails this rule.

It is also a two-day-old regression rather than an oversight at authoring time. The compliant
declaration was written, carried by `cea6305` and `2acb2c4` (2026-08-24), and struck by `35e1e5c`
(2026-08-25) inside a broad rewrite of the file — 105 insertions, 77 deletions — rather than as an
isolated edit, which is presumably how it went unnoticed.
`git show 2acb2c4:documents/engineering/shared_host_resource_protocol.md` still carries it verbatim at
lines 12-14:

> **Not adopted.** No prodbox code reads or writes the ledger, no supported command depends on it, and
> no sprint owns the work. Status remains owned by
> [Development Plan → Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here).

Since that commit, `grep -c 'DEVELOPMENT_PLAN'` on the file returns `0`. Meanwhile `ls -ld
/var/lib/hostgrant` returns "No such file or directory" — the rendezvous § 6.1 describes as
"Established once per machine by the operator" does not exist on this host, and nothing at `HEAD` says
so. `documents/documentation_standards.md` names a target stated as current fact as the most common
defect in this repository's governed documents, and "the only one that reads as correct to every
reviewer who does not check the source."

The document's revision history is consistent with an in-flight external negotiation parked in the
doctrine tree: six revisions across two days, 869 → 1032 → 83 → 111 → 357 → 362 lines, on 2026-08-24
and 2026-08-25.

**Fix.** Restore one blockquote.

### 3.6 § 11's conformance story leaves the domain algebra with no conformance mechanism — MINOR

All four occurrences of "conformance" in the document concern the lock mechanism, and § 11's matrix
cell (`python3 hostgrant_probe.py try "$holder" ofd`) takes a file and a mechanism — never a domain. So
the § 5 algebra that the document calls "identical in every participant" carries no conformance
obligation at all, even though § 5 itself says "Two participants that disagree about well-formedness
disagree about conflict, which is the failure this policy exists to prevent."

The six discriminating vectors § 5 already ships are sufficient — a naive string-prefix `conflicts`
fails on `('gpu:0','gpu:01')` — but § 11 never claims them as a conformance suite.

For prodbox this is doubly awkward: § 11's "Matching prose and matching digests establish nothing"
actively delegitimises the seconds-fast compiled-source-versus-projection check that is this
repository's established and gated method for cross-artifact agreement, and which would have been the
natural way to prove a Haskell `conflicts` equals the normative one. An adopting participant would be
left hand-mirroring a markdown code block with no single compiled source.

**Fix.** Name which artifact is the single compiled source of the domain algebra, and how a second
implementation is proven equal to it.

### 3.7 `Status: Reference only` is factually false — MINOR

`documents/documentation_standards.md:88` glosses `Reference only` as "Points to authoritative
sources". The file contains **zero** outbound citations of any kind across 362 lines —
`grep -cE 'http|\.md|documents/|src/|DEVELOPMENT_PLAN'` returns `0` — while issuing 17 MUST/MUST NOT
directives.

The status field simultaneously understates the document's authority (the body is a specification) and
asserts a pointing relationship it does not have. The gate cannot catch this: `CheckCode.hs:5478` tests
membership in the closed set only. Severity is capped by the fact that
`documents/engineering/README.md:78` and `:193` both link *to* the document, so it is indexed rather
than orphaned — but combined with § 3.5, a reader has no route from this file to any status ledger, any
owning sprint, or any prodbox surface.

### 3.8 The cross-project framing has no antecedent, and prodbox is the only copy — MINOR

The rewrite stripped every project name while keeping six cross-project references — "each project",
"both projects", "two of these projects", "two of my own corrections" — leaving them without any
antecedent in the file. The first revision `b0804fa` named them ("semantics that amoebius and its seed
projects independently implement"; "The four projects implement the same semantic protocol
independently"); `HEAD` mentions `prodbox` exactly once, in the Purpose line.

Checked: none of the four sibling repositories on this host contains a single occurrence of
`hostgrant`, `F_OFD_SETLK`, `rendezvous`, or the pre-rewrite `ExecutionAuthority` / `ParentScopeId`
vocabulary. prodbox is the sole copy of a policy it textually disclaims owning — so the claims that
justify the design ("Independent review in each project falsified it on four counts") are
unfalsifiable from inside this repository, and § 10's scope concession ("the only shared-host failure
two of these projects have actually recorded") cannot be checked either.

`documents/documentation_standards.md:15` — "Every concept has exactly one canonical document. Other
documents may reference but never duplicate." A cross-project RFC is by construction copied into each
participant; the repository's practiced convention is a prodbox-owned document that *cites* the
umbrella rather than restating it.

The concrete cost is § 6.2's docker-socket sentence, which carries an unverified claim about another
project inside a sentence that also asserts something untrue about this one.

### 3.9 Measurement provenance, and a conformance recipe that cannot be run — MINOR

The document's authority rests entirely on the word "measured", and no measurement in it carries a
date (`grep -cE '20[0-9]{2}-[0-9]{2}-[0-9]{2}'` returns `0`), unlike every other measured claim in
`documents/engineering/`.

The environment half of this complaint is **refuted** and should be recorded as such: § 6.2 names
kernel, architecture, distribution, glibc and filesystem in the sentence itself, which is what this
repository's standards require, and both Linux tables reproduce here cell-for-cell (§ 2.1, § 2.2). The
physics is not in question.

What survives is the artifact. § 11 declares behavioural conformance the only thing that establishes
conformance, and then gives a recipe invoking `hostgrant_probe.py` — a file that exists nowhere in the
worktree or on this filesystem (`find / -name 'hostgrant_probe*'` → no output). The mandated
verification procedure is unrunnable as published.

**Fix.** Date each measurement, add the one-line note that the Linux results reproduce on kernel 7.0 /
x86_64, and either commit the probe where the citation gate can see it or stop presenting an
unrunnable recipe as the conformance procedure.

---

## 4. Smaller defects worth one editing pass

These were not put through adversarial verification; each is cheap to check and cheap to fix.

| # | Defect |
|---|---|
| 4.1 | **§ 7's central predicate has no primitive.** The admission loop turns on `if grant-lock on s is free`, but § 6.2 supplies only `take_grant` (`F_OFD_SETLK`). Testing a foreign slot without acquiring it needs `F_OFD_GETLK`, which the document never names; the naive substitute — try-lock-then-unlock on a slot you do not own — is a different operation with different failure modes. |
| 4.2 | **`<root>/reserved` sits outside the no-torn-read argument.** § 7 drops checksums because "every reader takes `admission.lock` first", but that covers only slot content written by participants. § 4 says `reserved` is edited by an operator, with ordinary tools that take no lock — and typically write by rename, which § 1 separately forbids for exactly the reason it gives. Same for `<root>/protocol-version`. |
| 4.3 | **Editing `reserved` is a third file-set vector.** § 7 states "No temporary files exist at any point" and lists exactly two vectors that change the file set. The operator edit § 4 mandates is a third, and leaves residue if the editor is killed. |
| 4.4 | **A malformed foreign domain has no refusal class.** § 5 says a malformed domain "is a malformed domain, not a domain that conflicts with nothing", but § 7's loop reads foreign slot content and `reserved` and offers only `Busy` / `Conflicted` / `NoSlot` / `Unsupported`. None fits. |
| 4.5 | **Registration is honour-system.** § 7: "A participant MUST NOT create a slot at runtime. Its slot count is fixed when it is registered." § 6.1: "A non-root participant can then create its own directory inside." Nothing states where registration happens, who performs it, or what enforces the count — so the pool bound the section rests on is unenforced. |
| 4.6 | **Exact-version lockstep across independently released projects.** § 7 mandates refusing every operation unless the participant implements the exact revision, "no negotiation and no forward compatibility". On a machine whose participants are separate projects with separate cadences, every bump is a flag day, and there is no order in which two participants can be upgraded. |
| 4.7 | **§ 6.2's reference `take_grant` violates § 6.2's own CLOEXEC MUST.** The sample opens nothing and never clears `FD_CLOEXEC`; under PEP 446 CPython sets it by default, so the code as written produces exactly the state the section forbids three lines later. |
| 4.8 | **`take_grant` locks the whole file, two sentences after the byte-0 mandate.** The sample packs `l_start=0, l_len=0` — a whole-file lock — while the prose says "Windows scopes MUST lock exactly one byte, byte 0. Byte 0 is reserved on **every** platform and the domain list starts at offset 1 everywhere." Harmless on POSIX because the lock is advisory, but the stated rationale (identical slot format) is not what the sample implements, and byte 0's contents are never specified. |
| 4.9 | **"Migration is therefore incremental and safe" holds for only half the population.** The document's own matrix shows a `flock` holder is *invisible* to an OFD prober — ignored, not blocked. § 11's conformance sample tests `ofd` against `ofd`, the one cell that cannot fail. |
| 4.10 | **"Nothing spans two kernels because nothing attempts to" contradicts the rule three sentences earlier.** § 3 requires a participant to take its grant "in the scope where the resource lives" and states that guest work creating something on the host consumes host capacity — so a workload consuming guest CPU and host storage must hold grants in two scopes at once. No acquisition order between the two roots is specified. |
| 4.11 | **The engineering README index describes § 4 as the opposite of what § 4 mandates.** `documents/engineering/README.md:78` says "one grant held by the supervising process"; § 4's MUST NOT exists specifically to forbid a supervisor holding a grant on behalf of processes it starts. |
| 4.12 | **The `struct flock` sample under-declares by four bytes.** `struct.calcsize("hhqqi")` is 28 where `sizeof(struct flock)` is 32 on x86_64. It works only because the shortfall lands in trailing padding the kernel ignores and CPython copies the argument into an oversized buffer. Field offsets are correct (`l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24`) and the Darwin `"qqihh"` layout is right, so this is a transcription hazard rather than a bug. |
| 4.13 | **No threat model, and a world-writable rendezvous.** § 6.1 mandates a mode-1777 root at a fixed absolute path from which a participant reads other participants' domain strings and acts on them. The document contains no discussion of ownership, authentication, or hostile or buggy writers. Any local user — or any container carrying the bind mount, including a workload this project deploys — can hold `admission.lock`, declare a broad domain, or wedge admission. Measured mitigation on this host: `fs.protected_symlinks=1` blocks cross-uid symlink follows in the sticky root, but `slots/<participant>/` is not sticky and symlinks there are followed. |
| 4.14 | **§ 11 dismisses the Windows inheritance unknown with a rule addressing the wrong property.** § 4 removes reliance on inheritance *working*; it does nothing about an inherited handle being a write and unlock primitive, which is the actual exposure — and one § 6.2 mandates into existence on POSIX. |
| 4.15 | **Every normative artifact is Python.** § 5's algebra, § 6.2's `take_grant` and § 11's harness are the document's three executable specifications; the repository contains no Python and declares no Python toolchain. |
| 4.16 | **§ 3 restates a topology `host_platform_doctrine.md` already owns**, in prose, with no link, as a second canonical statement of the Linux/Lima/WSL2 kernel-frame model that doctrine holds as a typed, total Haskell fold. |
| 4.17 | **§ 1's revision narration is undated and sprint-less.** In-place correction narration is permitted and practised here, but every practised instance is inline at the corrected claim, dated, and usually names the sprint or Standard. § 1 is a leading numbered section with a six-row table carrying none of those. `Supersedes: N/A` is also inaccurate given that § 1 exists to supersede earlier revisions. |
| 4.18 | **Three of nine code fences declare no language**, more bare fences than the rest of `documents/` combined. |
| 4.19 | **OFD locks self-conflict across two open file descriptions in one process** (measured: `EAGAIN`). Correct and desirable, but it is an intra-process semantics change from prodbox's current classic-`fcntl` code, which relies on the *absence* of self-conflict — and any adoption must retire `retainedRootProcessLock`/`reserveProcessIntentLock` rather than leave them, or risk deadlock. |

---

## 5. The scope premise: a kernel is an over-approximation

§ 3's headline is "**The unit of coordination is a kernel, not a machine.**" That correction is right,
and § 3's Linux row is correct for every configuration prodbox actually runs: RKE2 is a bare-metal
systemd unit here, `kind` nodes are containers in one Docker host, and `ViaContainer` is `docker run` —
all sharing the host kernel.

But the kernel is still coarser than the resources the document invites participants to name. Measured
on this host:

```
host netns holds :30080                                    -> BIND-OK
container in its own netns, same kernel, binds :30080      -> BIND-OK (no conflict)
container kernel == host kernel                            -> 7.0.0-28-generic == 7.0.0-28-generic
```

Ports live in a network namespace; mounts in a mount namespace; memory limits in a cgroup. § 3 says "A
participant MUST take its grant in the scope where the resource lives" and then defines scope as a
kernel — so for namespaced resources the rule cannot be satisfied as stated, and the document gives no
vocabulary for deciding which side of a namespace boundary a claim sits on.

The failure direction is conservative — false `Conflicted`, not missed exclusion — so this is an
expressiveness gap rather than a safety bug. It matters here because prodbox's contention surface is
largely fixed host ports: 35 references to `30080`, plus `30443`, `31820`, `39000`, alongside fixed
singleton names (`prodbox-control-plane`, `prodbox-aws-eks-test`, `prodbox-pulumi-state`) and one
fixed `--builddir=.build`.

It is the same underlying problem as the missing domain registry: the protocol specifies an algebra but
no registry of meanings, concedes that "A declaration is not behaviour", and therefore rests its
correctness on a social convention it declines to specify. Two projects choosing different granularities
for one physical resource either over-serialize or never conflict, and nothing detects either.

---

## 6. Fit for prodbox

**Mechanism cost: near zero.** OFD is available through `base` with no FFI (§ 2.4); prodbox is already
in the correct lock family (§ 2.3); § 8's obligation is already the house idiom; § 5's algebra is a
direct fit for the repository's pure-FP rules — "Pure, total … No I/O, no syscall, no platform" is
almost a quotation of them.

**Benefit today: near zero.** Subtract § 10's four exclusions and ask what remains for this project.

| prodbox's recorded shared-host failures | Class | Arbitrable by this protocol? |
|---|---|---|
| Gateway heap leak, ~100 MB/hr, OOM-cycling a ~460 MB cgroup | progressive consumption | No — § 10 excludes it by name |
| Host inotify limit exhaustion | kernel-wide non-partitionable quantity | No — quantities cost a revision |
| The 2026-08-04 mass-kill of tmux sessions sharing code-server's cgroup | cgroup `KillMode` semantics | No |
| Stranded AWS residue after killed runs | cross-machine, cross-kernel | No — § 3 excludes it by construction |

Genuinely mutual-exclusion-shaped contention does exist here — concurrent `test all` runs colliding on
fixed NodePorts, `dev check` versus `test integration` on one `--builddir=.build`, two cascades on one
`.host-cleanup-intent.lock` — but prodbox already runs *both* coordination shapes the protocol offers:

- a **fixed, non-run-keyed singleton lock** at
  `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:287-289`, funnelling every intent-store mutation
  through one path over one `active-v1.cbor`; and
- a **run-keyed fencing lease** in the same directory, whose digested envelope covers graph digest,
  surface, registry revision, foundation, AWS account/region and terminal permit.

`systemctl show rke2-server -p Type` → `Type=notify`: systemd already single-instances the standing
cluster. Per-run filesystem isolation already exists via `.test-data/<case>/`.

**The residual value is entirely in what other participants do, and there are currently none.** The
protocol's whole thesis is inter-project coordination; on this host no other project takes a
host-capacity lock of any kind, so an adopting prodbox would be arbitrating against itself using a
`/var/lib/hostgrant` rendezvous that does not exist, against a version file no one else reads.

The smallest mechanism that would deliver prodbox's actual near-term benefit is one lock file keyed on
the singleton it protects — the builddir, or the cluster name. That is a few lines against a rendezvous
installed by root, a per-OS mechanism, a domain registry, version lockstep and a conformance harness.

**The steelman, stated fairly.** If a second project ever shares this host and both take real host
capacity, the protocol is the correct shape for that problem and its OFD reasoning is the correct
mechanism choice — and it would be cheaper to adopt *before* a collision than to retrofit after one.
That case is real. It is a case for keeping the document, corrected and honestly marked as unadopted;
it is not a case for implementing it now.

---

## 7. Recommendations

1. **Restore the deleted `Not adopted` blockquote** (§ 3.5). One blockquote, fixes the only
   Roadmap-rule violation in `documents/engineering/`, and it was already written once.
2. **Fix the `FD_CLOEXEC` rule and add a truncation rule** (§ 3.1, § 3.2), regardless of adoption. Both
   are wrong on the document's own published evidence, and both will be transcribed by whoever
   implements first.
3. **Answer the teardown case or scope the document** (§ 3.3, § 3.4). Either add a representation for
   standing capacity a participant owns and removes, or state plainly that the policy covers node-local
   resources whose consumption ends with the process, and that anything outliving its creator needs the
   discarded second grant kind.
4. **Do not adopt until a second participant exists.** Revisit if another project on this host starts
   taking host-capacity locks.
5. **If it is adopted**, the § 4 rule that every process consuming capacity acquires its own grant is
   unimplementable here as written — prodbox's host work is performed almost entirely by third-party
   binaries (`kind`, `kubectl`, `aws`, `vault`, `pulumi`, `helm`) that will never be participants. That
   needs an explicit supervisor rule, which is what `documents/engineering/README.md:78` already
   believes the document says.
6. **Cheap wins available now, independent of the protocol**: the four `setLock` sites can move to
   `base`'s OFD-backed `hLock` with no FFI, retiring the `retainedRootProcessLock` /
   `reserveProcessIntentLock` workaround tables built to survive the classic-`fcntl` lifetime defect
   that § 6.2 documents and `HostCleanupIntent/Internal.hs:1261-1264` independently rediscovered.

---

## 8. Claims examined and rejected

Recorded so the same ground is not re-argued. Each of these was a candidate finding that an
independent reviewer killed, in most cases by measurement.

| Rejected claim | Why it fails |
|---|---|
| "`host:memory` in `<root>/reserved` is a whole-machine mutex" | Misreads § 5. "Reserved families at version 1" is an IANA-style **name registry** ("Every other family is open"), inside a section whose first line is "No I/O, no syscall, no platform". It is not an instruction to write those domains into the operator-edited file. |
| "§ 3's Linux row is false for `ViaVM IncusVM`" | `ViaVM` has zero construction sites in the repository — three hits total, all declarations. `host_platform_doctrine.md` resolves Linux to `clusterFrame LinuxCpu = []`, native and host-direct. The row is true for everything prodbox runs. |
| "On Apple and Windows the protocol yields `Unsupported` for host memory" | The outer prodbox binary is host-native on Darwin/Windows and re-invokes a subcommand of *itself* inside the Linux frame; `Host/Lift.hs` folds the Apple frame into a `limactl` process executing **on Darwin**. That process stands in the Darwin scope, which § 6.1 gives a measured rendezvous. |
| "§ 6.1's WSL2 rendezvous cannot arbitrate across distributions" | The premise is right and the conclusion does not follow: § 6.1's bind-mount rule, in the same paragraph, *is* the remedy, and it is a general MUST about paths, not a container-only clause. Measured: shared inode across two roots → BLOCKED; per-root copies → ACQUIRED. |
| "Two opaque admission proofs over the same host facts, with no seam" | Both gates are refusals, so they are conjunctive and need no precedence rule; § 8 orders them (grant first, arithmetic second). "The grant refuses a plan Ring 3 proved fits" is the mechanism working, not a defect. |
| "fcntl→OFD is a semantic regression at prodbox's four lock sites" | All four descriptors are opened `cloexec = True`, and the repository contains no bare `forkProcess` at all (`CheckCode.hs` bans it). The lifetime change the claim depends on cannot occur at those sites. |
| "No OFD primitive exists in the toolchain prodbox pins" | True of `unix-2.8.8.0` and irrelevant: `base ^>=4.21.2.0` is already pinned and its `GHC.IO.Handle.Lock` backend is `LinuxOFD` on this host, verified behaviourally. |
| "§ 6.2's adoption argument inverts for a Haskell participant" | Measured the opposite: a `System.Posix.IO.setLock` holder blocks an OFD prober and admits a `flock` prober. prodbox is inside `{fcntl, OFD}` and § 6.2's asymmetry argument applies to it as written. |
| "§ 5 ships two mutually inconsistent parsers" | Exhaustive comparison of the document's `segments()` against a strict splitter over the whole language of the grammar — 2,232 exhaustive strings plus 14,970 random valid ones — found **0 disagreements**. The `if s` filter is unreachable on any input the protocol permits. |
| "Every shared-resource failure prodbox has recorded is quantitative — the tally is 0" | Method error: the survey read prose only. `test/unit/Main.hs:1646-1652` records a mutual-exclusion-shaped incident on one kernel with two participants, fixed with an exclusive lock taken once at the start of a bracket. |
| "prodbox deliberately chose run-keyed isolation over serialization" | False on inspection: `HostCleanupIntent/Internal.hs:287-289` is a fixed, non-run-keyed lock over a singleton file. prodbox uses both shapes. |
| "The OFD mandate is violated at four prodbox call sites" | Scope error. The mandate applies to the hostgrant rendezvous slot, and § 2 defines a Participant as a program implementing the policy. `grep -rn hostgrant --include=*.hs src/` returns zero. There is no MUST to violate. |

---

## 9. Reproduction

Probe sources used for §§ 2.1–2.2, 3.1 and 5 are under this session's scratchpad
(`hostgrant/probe.py`, `lifetime.py`, `cloexec.py`, `bindport.py`). Each follows the document's own
discipline of a negative control before every contended cell. The three shapes are:

```sh
# 3x3 family matrix, one cell
f=$(mktemp)
python3 probe.py try  "$f" "$prober"     # control -> must print ACQUIRED
python3 probe.py hold "$f" "$holder" 3 & sleep 0.6
python3 probe.py try  "$f" "$prober"     # contended -> BLOCKED or ACQUIRED

# CLOEXEC x process-shape matrix
python3 cloexec.py "$f" exec-replace|fork-exec-child  set|clear

# namespace scope
python3 bindport.py 6 &                  # host netns holds :30080
docker run --rm --network bridge python:3-alpine python -c "...bind 30080..."
```

The document's § 11 recipe is not reproducible as published: `hostgrant_probe.py` does not exist in
this repository or on this filesystem (§ 3.9).
