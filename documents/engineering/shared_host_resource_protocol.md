# Shared Host Resource Protocol

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: The host resource coordination policy prodbox would implement, why it has the shape it has, and
> what adopting it would require.

## 1. Why this document changed

Earlier revisions described a *mechanism* — a per-user root under the home directory, fixed-size checksummed
records, a "claim ledger" vocabulary — and asked each project to adopt it. Independent review in each project
falsified it on four counts, and measurement then falsified two of my own corrections. Recorded so the same
ground is not re-argued:

| Claim | Outcome |
|---|---|
| A root under the home directory, "never selected by an environment variable" | **Contradictory.** `$HOME` *is* an environment variable; it differs under `sudo`, service managers, and every container |
| `%ProgramData%` as the Windows root | **Same defect.** Also an environment variable |
| A machine is one coordination domain | **False.** A single developer machine runs several kernels at once |
| "`flock` and `fcntl` do not interoperate on Linux **or macOS**" | **Half wrong.** True on Linux, false on Darwin — measured, §6.2 |
| Atomic rename for record content | **A bug.** `rename(2)` repoints the name at a new inode, orphaning the lock held on the old one |
| Two grant kinds, one proved by re-observation | **Unnecessary.** A resource only contends while something runs, and whatever runs can hold the lock |

The conclusion is the change: **a mechanism cannot be universal, because it is per-kernel and per-language.
A policy can.**

## 2. Terms

- **Participant** — a program that implements this policy.
- **Scope** — one kernel. A lock arbitrates inside one scope and across none.
- **Domain** — an opaque identifier for a thing that can be contended.
- **Grant** — a held lock naming the domains a participant occupies, for as long as it occupies them.
- **Reserve** — standing capacity, declared once by the operator, held by nobody.
- **Rendezvous** — the fixed location where grants are taken.

MUST / MUST NOT / SHOULD carry their usual force.

## 3. Scopes

**The unit of coordination is a kernel, not a machine.**

| Machine | Scopes |
|---|---|
| Linux | The host. Its containers share that kernel, so they are the same scope |
| Darwin | The host, **plus one per virtual machine** used for containers |
| Windows | The Windows kernel, **plus one** shared by all WSL2 distributions |

Measured on a Darwin host: `Darwin 25.5.0 arm64` alongside a Colima guest running `Linux 6.8.0-100-generic`
— two kernels, one machine, before Windows is involved.

**A participant MUST take its grant in the scope where the resource lives**, not where the process runs. Work
inside a guest that creates something on the host consumes host capacity. A participant that cannot reach the
scope owning the resource MUST report `Unsupported` — it MUST NOT take a guest-local lock and treat that as
coordination, because admission against an empty guest-local rendezvous succeeds every time.

**Crossing scopes is nesting, never a shared lock.** A guest's whole capacity is one domain in its parent
scope. Nothing spans two kernels because nothing attempts to.

## 4. Grants and reserves

| | Reserve | Grant |
|---|---|---|
| For | Standing capacity expected to persist — a continuously-running cluster, a VM's memory pledge | Per-run contention — a build, a test run, a foreground workload |
| Expressed as | A domain listed in `<root>/reserved` | A domain in a held slot |
| Holder | **None** — it is permanently held by declaration | The live process doing the work |

`<root>/reserved` is a line-oriented list of domains, edited by the operator and by nobody else. **Admission
treats every domain listed there as permanently held**, so a reserve conflicts exactly as a grant does. This
is what lets a continuously-running cluster or a VM pledge be expressed without a holder, and it works at
version 1 because a reserve is a *domain*, not a quantity.

**If it outlives the session and is expected to persist, it is a reserve; if it is per-run, it is a grant.**

This is why there is one grant kind rather than two. A resource only contends while something runs; whatever
runs can hold the lock; and anything standing is declared instead. No record outlives its holder, so there is
no reclaim rule, no time-to-live, no boot identity and no operator escape hatch.

**A participant MUST NOT rely on inheriting a grant across process creation.** Every process that consumes
capacity acquires its own. This is stricter than POSIX permits, and deliberately so — see §11.

## 5. The domain algebra

Pure, total, and identical in every participant. No I/O, no syscall, no platform.

```
domain   = family ":" segment *( "/" segment )
family   = 1*( ALPHA / DIGIT / "-" )
segment  = 1*( ALPHA / DIGIT / "-" / "." / "_" )
```

Two domains **conflict** when either segment list is a prefix of the other, splitting on both `:` and `/`:

```python
def segments(d):        # "gpu:0/part1" -> ["gpu", "0", "part1"]
    head, _, rest = d.partition(":")
    return [head] + [s for s in rest.split("/") if s]

def conflicts(a, b):
    x, y = segments(a), segments(b)
    n = min(len(x), len(y))
    return x[:n] == y[:n]

assert     conflicts("gpu:0", "gpu:0/part1")   # a device and its partition
assert not conflicts("gpu:0", "gpu:01")        # segment boundary, not string prefix
assert not conflicts("gpu:0", "gpu:1")
```

Domains are compared **byte for byte and are case-sensitive**: `GPU:0` and `gpu:0` are different domains.
A participant MUST reject a domain that does not match the grammar rather than parse it loosely — an empty
segment, a missing `:`, or trailing whitespace is a malformed domain, not a domain that conflicts with
nothing. Two participants that disagree about well-formedness disagree about conflict, which is the failure
this policy exists to prevent.

```python
import re
_DOMAIN = re.compile(r"^[A-Za-z0-9-]+:[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")

def valid(d):
    return bool(_DOMAIN.match(d))

assert     valid("gpu:0/part1")
assert not valid("gpu:")        # empty segment
assert not valid("hostmemory")  # no family separator
assert not valid("gpu:0 ")      # trailing space
```

Reserved families at version 1: `host:memory`, `host:cpu`, `gpu:<id>`, `disk:<fs-id>`, `vm:<name>`. Every
other family is open.

**The extension asymmetry is the point.** A new device family — a new accelerator, a neural engine, anything
not yet imagined — costs **nothing**: no revision, no agreement, no change in any other participant, because
the only operations on a domain are equality and prefix. A new *quantity* costs a revision.

## 6. The rendezvous and the mechanism

### 6.1 Location

| Scope | Root | Mechanism |
|---|---|---|
| Linux host, and its containers | `/var/lib/hostgrant` | **OFD lock** |
| Darwin host | `/var/lib/hostgrant` | **OFD lock** |
| Guest kernel used for containers | `/var/lib/hostgrant` inside the guest | **OFD lock** |
| Windows host | `SHGetKnownFolderPath(FOLDERID_ProgramData)` + `hostgrant` | `LockFileEx`, **one byte** |

Established once per machine by the operator. Measured on Darwin under SIP:

```console
$ sudo mkdir -p -m 1777 /var/lib/hostgrant      # exit 0 — SIP does not protect /private/var/lib
$ ls -ld /var/lib/hostgrant
drwxrwxrwt  2 root  wheel  64 /var/lib/hostgrant
```

A non-root participant can then create its own directory inside, and the sticky bit stops one user removing
another's. The root MUST be on a **local** filesystem: `flock` over NFS is emulated as `fcntl`, which would
silently merge two families that are otherwise distinct.

Containers participate by bind-mounting the root at the same absolute path — the same pattern both projects
already use for the Docker socket. **A path that is not a bind mount is a different inode and arbitrates with
nobody**, so a participant that cannot prove its root is shared MUST report `Unsupported`.

### 6.2 Why OFD, measured

Three POSIX mechanisms exist, not two. Full 3×3 matrix, negative control before every cell:

**Linux** — `Linux 6.8.0-100-generic aarch64`, Ubuntu 24.04.4, glibc 2.39, ext4:

| holder \ prober | `flock` | `fcntl` | **OFD** |
|---|---|---|---|
| **`flock`** | BLOCKED | ACQUIRED | ACQUIRED |
| **`fcntl`** | ACQUIRED | BLOCKED | BLOCKED |
| **OFD** | ACQUIRED | BLOCKED | BLOCKED |

**Darwin** — `Darwin 25.5.0 arm64`, APFS: **all nine cells BLOCKED.** One family.

So Linux has **two families, `{flock}` and `{fcntl, OFD}`**, and Darwin has one. A mixed deployment works by
accident on a Mac and fails silently on Linux — invisible on the platform people develop on, catastrophic on
the platform things deploy to.

Lifetime, measured identically on **both** platforms:

| | `flock` | `fcntl` | **OFD** |
|---|---|---|---|
| Process opens a second descriptor to the same file and closes it | SURVIVED | **LOST** | SURVIVED |
| `fork`, parent exits, child keeps the descriptor | SURVIVED | **LOST** | SURVIVED |

**OFD is mandated because it is the only mechanism with both properties**: it has `flock`'s
open-file-description lifetime — so an unrelated `close()` cannot silently drop it — *and* it arbitrates with
`fcntl`, so a participant that has not migrated yet is **blocked rather than ignored**. Migration is therefore
incremental and safe.

This matters for adoption cost. A survey of the programs sharing a development host found most of them
already taking classic `fcntl` record locks at the call sites that arbitrate host capacity — that is, already
inside the `{fcntl, OFD}` family. Moving such a participant to OFD is a change of one call, and until it is
made the participant is still excluded correctly. Moving it to `flock` would instead take it *out* of the
family and make it invisible to everyone else. That asymmetry, not tidiness, is why the mandate is OFD.

Where a participant reaches locking through a runtime library rather than a direct syscall, the family it
lands in is a property of that library's build and MUST be established by measurement rather than assumed —
see the conformance test.

```python
import fcntl, os, struct, sys

if sys.platform == "darwin":
    F_OFD_SETLK = 90
    _lk = lambda: struct.pack("qqihh", 0, 0, 0, fcntl.F_WRLCK, 0)   # start,len,pid,type,whence
else:
    F_OFD_SETLK = 37
    _lk = lambda: struct.pack("hhqqi", fcntl.F_WRLCK, 0, 0, 0, 0)   # type,whence,start,len,pid

def take_grant(fd):
    """Raises OSError if another participant holds it."""
    fcntl.fcntl(fd, F_OFD_SETLK, _lk())
```

`FD_CLOEXEC` MUST be clear on the grant descriptor. Measured on Linux: with it set, the lock is **released at
`exec`** and the workload runs ungranted while appearing granted.

On Windows the lock is **mandatory rather than advisory**, and enforcement is confined to the locked range.
Measured: locking byte 0 leaves bytes 1..EOF readable, while locking the whole file makes **every** read fail
with `ERROR_LOCK_VIOLATION` (33). **Windows scopes MUST lock exactly one byte, byte 0.** Byte 0 is reserved on **every** platform and the
domain list starts at offset 1 everywhere, so the slot format is identical across scopes even though POSIX
does not need the reservation. `msvcrt.locking` and `LockFileEx` arbitrate with each other, so Windows has one family.

## 7. Slots and admission

Slots are **pre-created and never unlinked at runtime**, so nothing is left over after a crash or a reboot —
the files are permanent fixtures.

```
<root>/protocol-version                 one integer
<root>/reserved                         operator-declared domains, permanently held
<root>/admission.lock                   serializes decide-and-write; held for milliseconds
<root>/slots/<participant>/<n>          a slot: OFD lock + domain list as content
```

Content is written **in place while `admission.lock` is held**, never by rename — a rename would repoint the
name at a new inode and orphan the lock. Because every reader takes `admission.lock` first, no reader can
observe a partial write, which is why no checksum and no fixed-size padding are needed.

**A participant MUST NOT create a slot at runtime.** Its slot count is fixed when it is registered; needing
more concurrency than it has slots is a `NoSlot` refusal, never a new file. This is the rule that keeps the
pool bounded, and it is the one an implementation could plausibly get wrong.

**Zero files are created per run**, so nothing can be orphaned. Measured on Linux — 300 acquire/release
cycles across two participants with three slots each, including **76 simulated hard crashes** where the
descriptor was dropped with no cleanup whatsoever:

```console
  files after install:     8
  cycles=300 grants=300 simulated-crashes=76
  files after 300 cycles:  8
  RESULT: file count CONSTANT (8 -> 8)
```

The pool is bounded by `participants x slots-per-participant`, fixed at registration. There are exactly two
ways the file set changes at all, and neither is a runtime event:

| Vector | Bound |
|---|---|
| Registering a new participant | One directory plus its fixed slots, once. Bounded by the number of projects on the machine |
| Retiring a participant | Its directory remains until an **operator** removes it. Bounded by the number of projects that have ever existed |

No temporary files exist at any point, because content is written in place rather than renamed into position.

```
acquire(demand):
    lock admission.lock                      # non-blocking; on failure -> Busy
    if any domain in <root>/reserved conflicts with demand: unlock; return Conflicted
    for each slot s in <root>/slots/*/*:
        if grant-lock on s is free: continue          # dead holder, or never used
        if any domain in s conflicts with demand: unlock; return Conflicted
    pick a free slot of my own; take its OFD lock     # MUST precede publishing
    write my domain list in place
    unlock admission.lock
    return Grant(fd)                          # released by the kernel when this process dies
```

A participant MUST read `<root>/protocol-version` before anything else and **refuse every operation** if it
does not implement that exact revision, naming the mismatch. This is the only compatibility mechanism; there
is no negotiation and no forward compatibility.

Four refusal classes, kept distinct because collapsing them produces retry loops that never terminate:
`Busy` (contended; retry may succeed), `Conflicted` (a live grant holds a conflicting domain), `NoSlot`
(this participant's slots are all in use), `Unsupported` (this participant cannot resolve this scope's
rendezvous — reported, never silently treated as success).

## 8. The obligation

> **A function that starts governed host work MUST NOT be callable without a grant, and the grant MUST NOT be
> constructible outside the module that obtained it under `admission.lock`.**

Each project discharges this in its own idiom — a hidden constructor, an opaque newtype, a rank-2 region.
The technique is not the point; a path that starts host work without a grant should fail to compile rather
than fail a check, because a check that can be forgotten is not a boundary.

A granted lock is **coordination, not evidence**. It is not typed evidence for any state transition, it
applies no limit, and it fences no device. Existing enforcement is unaffected and is not replaced.

## 9. Crash, reboot and non-graceful shutdown

| Event | Outcome |
|---|---|
| `SIGKILL` of a grant holder | **No resource leaks.** The kernel releases the lock; domains are free immediately |
| `SIGKILL` holding `admission.lock` | **No wedge.** Kernel-released |
| Crash mid-write | **No torn read.** Content is written under `admission.lock`, which every reader holds first |
| **Reboot** | **Nothing held, by construction.** No process survives. Slots are pre-created fixtures, so nothing is left to clean |
| PID reuse | **Not relied on.** Liveness is the held lock, never a recorded PID |

Measured end to end on the real rendezvous (Darwin, APFS): a second holder is BLOCKED; a reader **succeeds**
while the slot is locked (POSIX locks are advisory); and after the holder is killed the slot is immediately
ACQUIRED by the next taker.

## 10. What this policy does not do

- **Progressive consumption is invisible.** A store that fills during a long run, a cache that grows, an image
  set that accumulates: none is caught by a decision taken once. This is the only shared-host failure two of
  these projects have actually recorded. A participant that needs a bound on its own growth applies one.
- **Non-participants are unconstrained**, and on POSIX the lock is advisory.
- **A declaration is not behaviour.** A participant that declares one domain and touches another is not
  detected.
- **No limit is applied and no device is fenced.**

## 11. Conformance, and what is not verified

Conformance is behavioural: two independently built participants contending on one real rendezvous either
serialize or do not. Matching prose and matching digests establish nothing.

**The conformance test is only meaningful on Linux, on a local filesystem.** Darwin arbitrates all three
mechanisms against each other, so a non-conforming participant **passes there** — the platform everyone
develops on cannot detect the defect. Over NFS `flock` is emulated as `fcntl`, which merges the families the
same way.

```sh
# One cell of the conformance matrix. Control first, then the contended case.
holder=$(mktemp)
python3 hostgrant_probe.py try  "$holder" ofd     # control -> must print ACQUIRED
python3 hostgrant_probe.py hold "$holder" ofd 10 &
sleep 0.5
python3 hostgrant_probe.py try  "$holder" ofd     # contended -> must print BLOCKED
```

**Not verified, and treated as unknown rather than assumed:**

- **Windows `CreateProcess` handle inheritance.** Documented to behave *opposite* to the POSIX `exec` result.
  §4's rule — never rely on inheriting a grant — removes the dependency, so this is recorded rather than
  blocking.
- **`%ProgramData%` divergence.** Three contexts agreed on one default-configured machine, which does not
  show the two *cannot* differ. The Known Folder API is mandated on the same footing as the `$HOME` case.
- **`\\wsl.localhost`** — the mirror of the measured `/mnt/c` direction — untested.
- **Windows shared locks.** `msvcrt.locking` has no shared mode. Unused here; exclusive only.
- **Cross-user delete denial** on Windows is inferred from the ACL, not measured.
- **Windows containers.** No analogue of the bind-mount test was run.
- **Runtime-library lock backends.** A participant that locks through a language runtime rather than a direct
  syscall may land in either family depending on how that runtime was built, and at least one such backend is
  reported to prefer OFD on Linux without that being checkable from compiled artefacts alone. This affects
  migration cost, not the correctness of the mandate, and is why the conformance test measures the family
  rather than trusting a library's documentation.
- **`/mnt/wsl` is tmpfs** and does not survive `wsl --shutdown`. It is a correct arbitration point and a poor
  place for anything expected to persist.
