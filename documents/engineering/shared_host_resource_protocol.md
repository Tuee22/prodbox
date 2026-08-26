# Shared Host Resource Protocol

**Status**: Reference only
**Supersedes**: Finite Resource Execution Authority Protocol — the document that occupied this path until 2026-08-24. If you find it in this repository's history, it is superseded and MUST NOT be implemented.
**Generated sections**: none

> **Purpose**: The host resource coordination policy for programs that share one host — what it guarantees,
> why it has the shape it has, and what adopting it requires. **Not adopted here; see [§1](#1-status-and-why-this-document-changed).**

## 1. Status, and why this document changed

> **Not adopted.** No code in this repository reads or writes the rendezvous, no command depends on it,
> and no phase owns the work. This document declares a target; it is not a description of current
> behaviour. Adoption status is owned by the development plan, not by this file.

Version 1 described a *mechanism* — a per-user root under the home directory, fixed-size checksummed
records, a "claim ledger" vocabulary. Independent review in each project falsified it, and measurement
falsified two of the corrections. Version 2 is the result of a second review round in which four projects
re-measured every load-bearing claim on their own hardware rather than reading it.

Recorded so the same ground is not re-argued:

| Claim | Outcome |
|---|---|
| A root under the home directory, "never selected by an environment variable" | **Contradictory.** `$HOME` *is* an environment variable; it differs under `sudo`, service managers, and every container |
| `%ProgramData%` as the Windows root | **Same defect.** Also an environment variable |
| A machine is one coordination domain | **False.** A single developer machine runs several kernels at once |
| "`flock` and `fcntl` do not interoperate on Linux **or** macOS" | **Half wrong.** True on Linux, false on Darwin — measured, [§6.2](#62-why-ofd-measured) |
| Atomic rename for record content | **A bug** *for a lock-bearing file.* `rename(2)` repoints the name at a new inode, orphaning the lock. It remains correct for files that carry no lock — see [§7](#7-slots-and-admission) |
| Two grant kinds, one proved by re-observation — "unnecessary, because whatever runs can hold the lock" | **The falsification was wrong.** Measured: a command that creates a standing resource returns, the resource keeps running, and nothing holds a lock. Re-observation is reinstated in [§4](#4-grants-standing-claims-and-reserves) |
| `FD_CLOEXEC` MUST be **clear** on the grant descriptor | **Inverted.** Measured on two kernels: clearing it is what lets a grant outlive its holder indefinitely. [§6.2](#62-why-ofd-measured) now mandates the opposite |
| A boolean domain is enough for version 1's reserved families | **False.** Three of the five are divisible quantities, which a prefix algebra can only model as machine-wide mutexes. [§5](#5-the-claim-algebra) gains an amount |
| "Content is written in place, so no framing is needed" | **Incomplete.** It establishes the absence of torn reads and says nothing about stale tails. [§7](#7-slots-and-admission) now mandates truncation and framing |

**The conclusion is unchanged: a mechanism cannot be universal, because it is per-kernel and per-language.
A policy can.**

## 2. Terms

- **Participant** — a program that implements this policy.
- **Scope** — one kernel. A lock arbitrates inside one scope and across none.
- **Domain** — an opaque identifier for a thing that can be contended.
- **Amount** — what a claim takes of a domain: exclusive, or a count.
- **Claim** — a domain and an amount, together.
- **Grant** — held claims, alive for exactly as long as the holding process.
- **Standing claim** — claims that outlive the process that made them, valid only while a **witness** holds.
- **Witness** — a process whose death proves a standing claim's resource is gone.
- **Reserve** — standing capacity declared by the operator, held by nobody.
- **Slot** — a pre-created file in which a participant records a grant or a standing claim.
- **Admission** — the decision to grant or refuse, taken under `admission.lock`.
- **Rendezvous** — the fixed location where all of this happens.

MUST / MUST NOT / SHOULD carry their usual force.

## 3. Scopes

**The unit of coordination is a kernel, not a machine.**

| Machine | Scopes |
|---|---|
| Linux | The host, **plus one per virtual machine** it runs. Containers share the host kernel and are the same scope |
| Darwin | The host, **plus one per virtual machine** used for containers |
| Windows | The Windows kernel, **plus one** shared by all WSL2 distributions |

Measured on a Darwin host: `Darwin 25.5.0 arm64` alongside a Colima guest running
`Linux 6.8.0-100-generic aarch64` — two kernels, one machine, before Windows is involved. A Linux host
running a VM has the same two-kernel structure; version 1's Linux row omitted it, which invited a
participant to take a guest-local grant while believing it was on the host.

**A participant MUST take its claim in the scope where the resource lives**, not where the process runs.
Work inside a guest that creates something on the host consumes host capacity. A participant that cannot
reach the scope owning the resource MUST report `Unsupported` — it MUST NOT take a guest-local lock and
treat that as coordination, because admission against an empty guest-local rendezvous succeeds every time.

**Crossing scopes is nesting, never a shared lock.** A guest's whole capacity is one domain in its parent
scope. A participant that needs claims in two scopes MUST acquire them **outermost scope first**, and MUST
release both if either is refused. Nothing spans two kernels because nothing attempts to.

## 4. Grants, standing claims, and reserves

| | Grant | Standing claim | Reserve |
|---|---|---|---|
| For | Per-run contention — a build, a test run, a foreground workload | A resource a participant creates that outlives the creating process — a cluster, a VM | Standing capacity the operator declares — a pledge, a permanent allocation |
| Written | Into a held slot | Into the owner's slot, **lock not held** | A line in `<root>/reserved` |
| Alive while | The holder lives | Its **witness** lives, in this boot | Always |
| Removed by | The kernel, when the holder dies | The witness dying — automatically | The operator |

**Every claim's validity is decided by observation, never by a clock.** There is no time-to-live, no
reclaim rule, and no operator cleanup step, because there is nothing whose staleness has to be guessed at.

### 4.1 The witness

A standing claim records `boot | pid | process-start-time`. Admission honours it only if **all three**
still hold: the boot identity matches this scope's current boot, the process exists, and its start time is
the recorded one. A pid alone would not do — pids are reused — but a reused pid belongs to a process that
started later, so the pair is sound. Measured on both platforms, [§11](#11-conformance-and-what-is-not-verified).

This makes a standing claim self-clearing in every failure:

| Event | Outcome |
|---|---|
| Crash after writing the claim, before the resource exists | Witness never started, or already gone → **claim ignored** |
| Crash while the resource is genuinely running | Witness lives → **claim stands**, which is correct |
| Resource torn down | Witness exits → **claim ignored** |
| Reboot | Boot identity differs → **claim ignored** |
| PID reuse | Start time differs → **claim ignored** |

**The witness MUST be the narrowest process whose death implies the resource is gone.** A claim witnessed
by a shared daemon rather than by the resource's own supervising process is honoured for longer than the
resource exists. That failure is over-conservative rather than an admission of a second claimant, but it is
a defect and this policy cannot detect it.

**The participant that owns a standing claim is the only party that inspects its substrate**, and it does
so once, when the claim is written. Admission never learns what a cluster or a VM is: it checks a pid and a
start time. Without that split every participant would need to understand every other participant's
substrate, and no cross-project protocol could be implemented.

### 4.2 Reserves

`<root>/reserved` is a line-oriented list of claims, edited by the operator and by nobody else. Admission
treats every claim there as permanently held. A reserve is for capacity **no participant manages** — a
pledge made to a virtual machine, a slice held back for the operator's own use. Anything a participant
creates and destroys is a standing claim, not a reserve, so that no participant is ever barred from
releasing capacity it owns.

### 4.3 Inheritance

**A participant MUST NOT let a grant descriptor be inherited by a process it spawns.** `FD_CLOEXEC` MUST be
set on it; see [§6.2](#62-why-ofd-measured), where measurement shows that clearing it is exactly what lets a grant outlive its
holder. A participant that replaces itself with `exec` MUST close the descriptor explicitly first rather
than relying on the flag, so that release is asserted rather than inherited.

## 5. The claim algebra

Pure, total, and identical in every participant. No I/O, no syscall, no platform.

```
claim    = domain SP amount
domain   = family ":" segment *( "/" segment )
family   = 1*( ALPHA / DIGIT / "-" )
segment  = 1*( ALPHA / DIGIT / "-" / "." / "_" )
amount   = "*" / 1*DIGIT              ; "*" is exclusive; digits are a count
```

### 5.1 Exclusive claims conflict by prefix at a segment boundary

```python
import re

_DOMAIN = re.compile(r"\A[A-Za-z0-9-]+:[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*\Z")

def valid(d):
    return bool(_DOMAIN.match(d))       # \A..\Z, never ^..$: "$" also matches before a final newline

def segments(d):                        # "gpu:0/part1" -> ["gpu", "0", "part1"]
    head, _, rest = d.partition(":")
    return [head] + rest.split("/")

def conflicts(a, b):
    x, y = segments(a), segments(b)
    n = min(len(x), len(y))
    return x[:n] == y[:n]

assert     conflicts("gpu:0", "gpu:0/part1")   # a device and its partition
assert not conflicts("gpu:0", "gpu:01")        # segment boundary, not string prefix
assert not conflicts("gpu:0", "gpu:1")
assert not valid("gpu:0\n")                    # the trailing-newline trap
assert not valid("gpu:0 ") and not valid("gpu:") and not valid("hostmemory")
```

Domains are compared **byte for byte and are case-sensitive**: `GPU:0` and `gpu:0` are different domains.
A participant MUST reject a domain that does not match the grammar rather than parse it loosely, and MUST
NOT normalise one — an empty segment, a missing `:`, or any surrounding whitespace is a malformed domain,
not a domain that conflicts with nothing. **A participant reading a line from `<root>/reserved` or from a
peer's slot MUST strip exactly one trailing `LF` and then validate**; anything else is malformed. Two
participants that disagree about well-formedness disagree about conflict, which is the failure this policy
exists to prevent.

### 5.2 Measured claims are arithmetic, not exclusion

Some resources divide and some do not. A GPU is taken or not; host memory is taken *in an amount*. A prefix
algebra can only model an amount as a machine-wide mutex, which is why version 1's reserved list — which
included three divisible families — promised what its algebra could not deliver.

A domain is **measured** in a scope if, and only if, `<root>/capacity` declares a capacity for it.
Otherwise it is **exclusive**. Admission for a measured domain is arithmetic on an **exact domain match**,
never a prefix sum:

```
held(d) + reserved(d) + demand(d)  <=  capacity(d)
```

- A measured domain MUST be claimed exactly as declared. `host:memory/build` is not a sub-share of
  `host:memory`; it is a different, exclusive domain.
- An exclusive claim on a measured domain, or a counted claim on an exclusive one, is malformed.
- `<root>/capacity` is line-oriented, `<domain> SP <integer>`, operator-owned, and read under
  `admission.lock` like everything else.

**Units are fixed by family and never appear in the file**, so no participant parses a unit string and
`GiB`/`GB` cannot be confused: `host:memory` and `disk:<fs-id>` are **bytes**, `host:cpu` is
**thousandths of a core**. A family whose unit this document does not fix MUST NOT be measured.

### 5.3 Extension

Reserved families at version 1 remain reserved: `host:memory`, `host:cpu`, `gpu:<id>`, `disk:<fs-id>`,
`vm:<name>`. Every other family is open.

**A new family costs nothing** — the only operations are equality and prefix, so a participant that has
never heard of a hardware family still refuses to double-book its domains. Making a family *measured*
costs exactly one operator line, and that cost is real rather than incidental: a capacity is a fact about
one machine, and it has to come from somewhere.

**What a family name does not fix is how its identifiers are spelled**, and two participants naming one
device differently do not conflict. Within the reserved families this policy therefore fixes the spelling:

| Family | Identifier |
|---|---|
| `gpu:<id>` | The vendor's stable device identifier, lower-cased, with `:` replaced by `-`: an NVIDIA `GPU-<uuid>`, a PCI address `0000-01-00.0`, a Metal `registryID` in lower-case hex |
| `disk:<fs-id>` | The filesystem UUID, lower-cased. Not a mount path — a mount path is not stable and is not the same string in a guest |
| `vm:<name>` | The managing tool's own name for the instance, prefixed by that tool: `vm:colima-default`, `vm:incus-mycluster`. A bare name collides between projects |

An open family may spell its identifiers however its users agree. This table is the price of a family being
reserved, and a participant that cannot derive the fixed spelling MUST report `Unsupported` rather than
invent one.

## 6. The rendezvous and the mechanism

### 6.1 Location

| Scope | Root | Mechanism |
|---|---|---|
| Linux host, and its containers | `/var/lib/hostgrant` | **OFD lock** |
| Darwin host | `/var/lib/hostgrant` | **OFD lock** |
| Guest kernel used for containers | `/var/lib/hostgrant` inside the guest | **OFD lock** |
| Windows host | `SHGetKnownFolderPath(FOLDERID_ProgramData)` + `hostgrant` | `LockFileEx`, **one byte** |

Established once per scope by the operator. Measured on Darwin under SIP, 2026-08-25:

```console
$ sudo mkdir -p /var/lib/hostgrant            # exit 0 — SIP does not protect /private/var/lib
$ sudo chmod 1777 /var/lib/hostgrant          # chmod separately: mkdir -m is a no-op if it exists
$ ls -ld /var/lib/hostgrant
drwxrwxrwt  2 root  wheel  64 /var/lib/hostgrant
```

`mkdir -m` applies its mode only when it creates the directory, so a root already made by another project
keeps whatever mode it had and every later participant silently fails to register. The `chmod` is therefore
a separate MUST, and it is idempotent.

**The sticky bit is not inherited.** It stops one user removing another's entry in the root itself, and
does nothing for `<root>/slots/<participant>/`. A participant's own directory MUST be created `1777` by the
same operator step, or a second user cannot register at all.

Every participant needs to write `admission.lock` — an exclusive record lock requires a writable
descriptor, measured — so **any local user who can reach the rendezvous can hold admission, publish a
domain, or wedge the scope.** This is a cooperation protocol between programs run by one operator, and it
is not a security boundary. A scope shared by mutually untrusting users MUST NOT use one rendezvous.

The root MUST be on a **local** filesystem: `flock` over NFS is emulated as `fcntl`, which would silently
merge two families that are otherwise distinct.

Containers participate by bind-mounting the root at the same absolute path. **A path that is not a bind
mount is a different inode and arbitrates with nobody** — and a container runtime that auto-creates a
missing bind-mount source turns an unestablished rendezvous into an ordinary empty directory that succeeds
every time. A participant MUST verify that `<root>/protocol-version` exists and is readable before taking
any claim, and MUST report `Unsupported` if it does not.

### 6.2 Why OFD, measured

Three POSIX mechanisms exist, not two. Full 3×3 matrix, negative control before every cell.

**Linux** — `Linux 6.8.0-100-generic aarch64`, 2026-08-25:

| holder \ prober | `flock` | `fcntl` | **OFD** |
|---|---|---|---|
| **`flock`** | BLOCKED | ACQUIRED | ACQUIRED |
| **`fcntl`** | ACQUIRED | BLOCKED | BLOCKED |
| **OFD** | ACQUIRED | BLOCKED | BLOCKED |

Two families: `{flock}` and `{fcntl, OFD}`. Independently reproduced on `Linux 7.0.0-28 x86_64` — a
different kernel major version and a different architecture — cell for cell.

**Darwin** — `Darwin 25.5.0 arm64`, 2026-08-25: **all nine cells BLOCKED.** One family. This is the
asymmetry that matters most: *a participant using the wrong mechanism works perfectly on the platform
people develop on and fails silently where things deploy.*

Lifetime, both platforms:

| | `flock` | `fcntl` | **OFD** |
|---|---|---|---|
| An unrelated descriptor to the same file is closed | survived | **LOST** | survived |
| `fork`, parent exits, child keeps the descriptor | survived | **LOST** | survived |

OFD is the only mechanism with both `flock`'s open-file-description lifetime and `fcntl`'s arbitration, so
**OFD is mandated**. The migration argument is the reason it is the right mandate rather than merely a
workable one: a participant still taking classic `fcntl` record locks is inside `{fcntl, OFD}` already, so
until it migrates it is **blocked rather than ignored**. Moving it to `flock` would instead take it *out*
of the family and make it invisible to everyone else.

```python
import fcntl, os, struct, sys

DARWIN = sys.platform == "darwin"
F_OFD_SETLK = 90 if DARWIN else 37

def _lk():
    # Pad to sizeof(struct flock), NOT to the pack width: on Linux the natural
    # pack is 28 bytes where the kernel reads 32.
    return (struct.pack("qqihh",   0, 0, 0, fcntl.F_WRLCK, 0) if DARWIN     # 24 == sizeof
            else struct.pack("hhqqi4x", fcntl.F_WRLCK, 0, 0, 0, 0))         # 32 == sizeof

def take_grant(path):
    fd = os.open(path, os.O_RDWR)                     # O_CREAT never: slots are pre-created
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)   # see below — MUST be set
    fcntl.fcntl(fd, F_OFD_SETLK, _lk())               # raises OSError if held
    return fd
```

`l_len = 0` locks the whole file, which is correct on POSIX and is what the sample does. Windows scopes
MUST lock exactly **byte 0**, which is reserved on every platform so that the byte offsets of slot content
are identical everywhere; the domain list starts at offset 1.

**`FD_CLOEXEC` MUST be set on the grant descriptor.** Version 1 mandated the opposite, on the strength of a
single measurement — that with the flag set, the lock is released when the holder `exec`s. That is true and
it is the wrong rule, because the common shape is not exec-replacement but *spawn a child and keep running*.
Measured 2026-08-25, holder spawns `/bin/sleep` with `close_fds` false, then is SIGKILLed:

```console
FD_CLOEXEC=clear | holder alive: BLOCKED | holder SIGKILLed: BLOCKED  <- grant leaked to the child
FD_CLOEXEC=set   | holder alive: BLOCKED | holder SIGKILLed: ACQUIRED <- released, as [§9](#9-crash-reboot-and-non-graceful-shutdown) promises
```

Darwin errno 35, Linux errno 11, identical on both. With the flag clear, the surviving holder is an
ordinary tool that knows nothing about this policy, and `F_OFD_GETLK` reports the owning pid as `-1`, so it
cannot even be named. Clearing the flag is what falsified version 1's crash guarantees.

A participant that reaches locking through a language runtime rather than a syscall **MUST establish its
family by measurement** — see [§11](#11-conformance-and-what-is-not-verified). The family is a property of how that runtime was built and cannot be
read off its documentation.

## 7. Slots and admission

Slots are **pre-created and never unlinked at runtime**, so nothing is left over after a crash or a reboot.

```
<root>/protocol-version                 one integer, `2` at this revision; operator-written
<root>/capacity                         operator-declared capacities, "<domain> SP <integer>"
<root>/reserved                         operator-declared claims, permanently held
<root>/admission.lock                   serializes decide-and-write; held for milliseconds
<root>/slots/<participant>/<n>          a slot: OFD lock + claims as content
```

### 7.1 Slot content

```
byte 0        reserved, value 0
offset 1      "<kind> <boot> <pid> <starttime>\n"   kind = "grant" | "standing"
              then one "<domain> <amount>\n" per claim
```

UTF-8; `LF` between lines and after the last; no other separator. After writing, the participant **MUST
`ftruncate` the slot to `1 + len(payload)`**. Slots are permanent and reused, so without truncation a
shorter claim list leaves the previous holder's tail readable — measured to produce both phantom claims
charged to the new holder and, on a mid-line boundary, fabricated domains that pass `valid()`.

The `pid`/`starttime` of a **grant** are diagnostic only: liveness is the held lock, never a recorded pid.
For a **standing claim** they are the witness, and they are the liveness test. A refusal MUST name the
domain it refused on and the pid recorded in the conflicting slot, so that an operator is told who is
holding what rather than only that something is.

Content is written **in place while `admission.lock` is held**, never by rename — a rename would repoint
the name at a new inode and orphan the lock. `<root>/reserved`, `<root>/capacity` and
`<root>/protocol-version` carry no lock, are written by the operator, and MUST be installed **by rename**,
so that a reader never sees a half-written file; the no-rename rule applies to lock-bearing files only.

### 7.2 Admission

```text
def acquire(demand, me):          # pseudocode: helper names are illustrative
    if read(root/"protocol-version") != PROTOCOL_VERSION:  return VersionMismatch
    if not try_lock(root/"admission.lock"):                return Busy      # non-blocking
    try:
        reserved = parse(root/"reserved")                  # malformed -> Malformed
        capacity = parse(root/"capacity")                  # malformed -> Malformed
        if not all(valid(d) for d, _ in demand):           return Malformed

        held = []
        for s in slots(root):
            if s.participant == me and s.index in my_own_process_slots:  continue  # no self-conflict
            content = read(s)                              # malformed -> Malformed
            if content.kind == "grant"    and lock_is_free(s):           continue
            if content.kind == "standing" and not witness_holds(content): continue
            held += content.claims

        for d, a in demand:
            if a == EXCLUSIVE:
                if any(conflicts(d, e) for e, _ in reserved):           return Reserved
                if any(conflicts(d, e) for e, _ in held):               return Conflicted
            else:
                if total(held, d) + total(reserved, d) + a > capacity[d]: return Exhausted

        s = free_slot_of_mine()
        if s is None:                                                    return NoSlot
        take_ofd_lock(s)                                   # MUST precede publishing
        write_and_truncate(s, demand)
        return Grant(s)
    finally:
        unlock(root/"admission.lock")                      # on EVERY path, including errors
```

Every non-`Grant` exit releases `admission.lock`. **A participant MUST NOT create a slot at runtime**; its
slot count is fixed when it is registered, and needing more concurrency than it has slots is a `NoSlot`
refusal, never a new file.

**A participant MUST NOT count its own live slots as conflicting**, or a program that spawns a second image
of itself blocks on itself with no way to discover that it is its own blocker.

The seven refusals are kept distinct because collapsing them produces either a retry loop that cannot
terminate or a terminal failure that should have been retried:

| Refusal | Meaning | Retry |
|---|---|---|
| `Busy` | Another participant holds `admission.lock` | Yes, with backoff |
| `Conflicted` | A live claim conflicts | Yes — it ends when that holder does |
| `Exhausted` | A measured domain has insufficient remaining capacity | Yes |
| `Reserved` | The operator has declared this permanently held | **No** — never resolves without an operator |
| `NoSlot` | This participant's slots are all in use | Yes — by its own work finishing |
| `Malformed` | A peer's slot, `reserved`, or `capacity` did not parse | **No** — fail closed, report the file and the line |
| `Unsupported` | The rendezvous is unreachable or unestablished in this scope | **No** |

**The version is bumped by the operator, and only when every registered participant in that scope already
implements the new one.** A participant MUST declare the versions it implements when it registers, MUST
refuse every operation on mismatch, and MUST NOT write to a rendezvous whose version it does not implement.
There is no negotiation and no forward compatibility, because a participant that guesses at a format it
does not implement is exactly the failure this policy exists to prevent.

`Busy` MUST use randomised exponential backoff and MUST have a caller-supplied bound, after which it is
reported rather than retried forever. `admission.lock` is held for the duration of one scan and one write,
never across a workload — but a stopped process is indistinguishable from a running one, so an unbounded
wait is a wedge with no diagnostic.

### 7.3 The file set never grows

**Zero files are created per run.** Measured 2026-08-25 on both platforms — 300 acquire/release cycles
across two participants with three slots each, mixing grants and standing claims, including simulated hard
crashes where the descriptor was dropped with no cleanup whatsoever. The installed set is the four metadata
files plus `participants x slots`, so ten here:

```console
  files after install:     10
  cycles=300 grants=300 standing-claims=64 simulated-crashes=80
  files after 300 cycles:  10
  RESULT: file count CONSTANT (10 -> 10)
```

Identical on `Darwin 25.5.0 arm64` and `Linux 6.8.0-100-generic aarch64`. The harness is committed beside
this document as `crash_harness.py` on the same terms, so the number can be re-derived rather than trusted.

The pool is bounded by `participants x slots-per-participant`, fixed at registration. Standing claims do
not change this: a standing claim is content in an already-existing slot, not a file. There are exactly two
ways the file set changes at all, and neither is a runtime event:

| Vector | Bound |
|---|---|
| Registering a new participant | One directory plus its fixed slots, once. Bounded by the number of projects on the machine |
| Retiring a participant | Its directory remains until an **operator** removes it. Bounded by the number of projects that have ever existed |

An operator MUST NOT remove a participant's directory while any of its slots is locked: unlinking a slot
does not release its lock, but admission enumerates by path, so the claim would vanish while the resource
is still held.

## 8. The obligation

> **A function that starts governed host work MUST NOT be callable without a grant, and the grant MUST NOT
> be constructible outside the module that obtained it under `admission.lock`.**

**Governed host work** is work that consumes a resource in a reserved family, or in any family this
participant declares. Reading a file, compiling, and linting are not governed; starting a build that
saturates the machine, starting a cluster, starting a VM, and taking a device are. Each participant decides
where its own boundary falls and states it; this policy cannot check that decision, and [§10](#10-what-this-policy-does-not-do) says so.

Each project discharges the obligation in its own idiom — a hidden constructor, an opaque newtype, a rank-2
region. The technique is not the point; a path that starts host work without a grant should fail to compile
rather than fail a check, because a check that can be forgotten is not a boundary.

A granted lock is **coordination, not evidence**. It is not typed evidence for any state transition, it
applies no limit, and it fences no device. Existing enforcement is unaffected and is not replaced.

## 9. Crash, reboot and non-graceful shutdown

| Event | Outcome |
|---|---|
| `SIGKILL` of a grant holder | **No leak.** The kernel releases the lock; its domains are free immediately. This holds because [§4.3](#43-inheritance) forbids the inherited descriptor that would otherwise keep it alive |
| A grant holder's spawned child outlives it | **No leak**, because `FD_CLOEXEC` is set. With it clear — version 1's rule — the grant survives; measured, [§6.2](#62-why-ofd-measured) |
| `SIGKILL` holding `admission.lock` | **No wedge.** Kernel-released |
| Crash mid-write | **No torn read.** Content is written under `admission.lock`, which every reader holds first |
| Crash after a standing claim is written, before its resource exists | **Self-clearing.** The witness never started |
| A standing claim's resource is destroyed | **Self-clearing.** The witness exits |
| **Reboot** | **Nothing held.** No process survives, so no grant does; every standing claim's boot identity now differs. Slots are pre-created fixtures, so nothing is left to clean |
| PID reuse | **Not relied on for a grant** — liveness is the held lock. **For a standing claim** the witness is a pid *and* its start time, and a reused pid has a later start time; measured, [§11](#11-conformance-and-what-is-not-verified) |

Nothing here requires an operator to delete a file, at any point, for any reason.

## 10. What this policy does not do

- **Progressive consumption is invisible.** A store that fills during a long run, a cache that grows, an
  image set that accumulates: none is caught by a decision taken once, and a measured claim admits a build
  rather than bounding it. **This is the only shared-host failure these projects have actually recorded**,
  and it stays out of scope. A participant that needs a bound on its own growth applies one.
- **Non-participants are unconstrained**, and on POSIX the lock is advisory.
- **A declaration is not behaviour.** A participant that declares one domain and touches another is not
  detected, and neither is a boundary drawn too narrowly under [§8](#8-the-obligation).
- **A witness cannot be validated.** A claim witnessed by too broad a process is honoured too long.
- **No limit is applied and no device is fenced.**
- **This is not a security boundary.** See [§6.1](#61-location).

## 11. Conformance, and what is not verified

Conformance is behavioural: two independently built participants contending on one real rendezvous either
serialize or do not. Matching prose and matching digests establish nothing.

**The conformance test is only meaningful on Linux, on a local filesystem.** Darwin arbitrates all three
mechanisms against each other, so a non-conforming participant **passes there** — the platform everyone
develops on cannot detect the defect. Over NFS `flock` is emulated as `fcntl`, merging the families the
same way.

**The diagonal cell establishes nothing.** Every mechanism excludes itself, so a `flock` participant — the
one family that is invisible to everyone else — passes a same-mechanism test. The discriminating cells are
the off-diagonal ones, and this is the pass criterion:

```sh
# A conforming participant's holder MUST BLOCK an OFD prober and an fcntl prober.
# Run on Linux, on a local filesystem. Control first, then the contended case.
slot=$(mktemp)
for prober in ofd fcntl; do
  python3 hostgrant_probe.py try "$slot" "$prober"     # control  -> MUST print ACQUIRED
  <the participant under test> hold "$slot" &          # take a grant on $slot
  sleep 0.5
  python3 hostgrant_probe.py try "$slot" "$prober"     # contended -> MUST print BLOCKED
  kill %1
done
# A flock participant prints ACQUIRED for both and FAILS. That is the whole point of the test.
```

`hostgrant_probe.py` accompanies this document. A repository whose source policy forbids a tracked artifact
in that language generates it instead; the cells above are the contract either way, and a participant that
cannot run them has not established its family. The algebra is conformed separately, by asserting
[§5.1](#51-exclusive-claims-conflict-by-prefix-at-a-segment-boundary)'s vectors verbatim — a naive string-prefix `conflicts` fails `("gpu:0", "gpu:01")`, and a `^…$`
validator fails `valid("gpu:0\n")`.

The witness is conformed by measurement, not assumption:

```console
while alive -> LIVE | wrong start time -> GONE | after SIGKILL -> GONE | never-started pid -> GONE
```

Resolution measured 2026-08-25: microseconds on Darwin (`proc_pidinfo`), 10 ms on Linux (`CLK_TCK` 100).
Two processes 50 ms apart are distinguishable on both.

**Not verified, and treated as unknown rather than assumed:**

- **That a container runtime's init process is a usable witness** for a cluster created through it. The
  narrowest-process rule of [§4.1](#41-the-witness) assumes one exists and is discoverable; that has not been measured.
- **Every Windows claim** — `LockFileEx`, `msvcrt.locking`, `ERROR_LOCK_VIOLATION`, `FOLDERID_ProgramData`,
  `CreateProcess` handle inheritance, cross-user delete denial. No Windows host was available. [§6.2](#62-why-ofd-measured)'s
  byte-0 result is the sole basis for the byte-0 reservation that shapes the slot format on every platform.
- **`\\wsl.localhost`** — the mirror of the measured `/mnt/c` direction — untested.
- **Windows shared locks.** `msvcrt.locking` has no shared mode. Unused here; exclusive only.
- **Windows containers.** No analogue of the bind-mount test was run.
- **NFS `flock` emulation**, which [§6.1](#61-location)'s local-filesystem MUST is written against.
- **Runtime lock backends.** One widely used Haskell runtime selects OFD on Linux through its standard
  library and exposes no OFD call at all through its POSIX binding — two different answers in one
  toolchain. This affects migration cost rather than the correctness of the mandate, and is why [§6.2](#62-why-ofd-measured)
  requires the family to be measured rather than read off documentation.
- **Whether any second participant exists.** At the time of writing, no project on the machines these
  measurements were taken on implements this policy. A mutual-exclusion protocol's value is proportional to
  participants minus one, and this one currently has none.

## Related Documents

- [Engineering documentation index](./README.md) — where this document sits in the suite
- [Development Plan](../../DEVELOPMENT_PLAN/README.md) — the owner of adoption status; this document declares a target and does not record one
