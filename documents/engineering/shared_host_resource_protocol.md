# Shared Host Resource Protocol

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Record what participation in the shared host claim ledger would mean for prodbox, and what
> adopting it would require.

## 1. What this records

No code in this repository reads or writes the ledger, and no command depends on it. This file records what
participation would mean, so that a later decision starts from a written position rather than from nothing.
Writing it creates no dependency on another project.

The ledger is host configuration owned by the machine's operator, in the same category as an `/etc` file or a
port assignment. Every participant resolves one fixed path and no other: `$HOME/.hostclaim` on Linux and
Darwin, `%UserProfile%\.hostclaim` on Windows. Its authority is that installed root and the `spec-version`
the root carries, never a copy of a document in any repository, including this one.

The path is never repository-relative, never version-suffixed, and never selected by an environment
variable. Two participants that resolve different paths silently fail to coordinate, which is the one
failure the ledger exists to prevent, so the resolution rule admits no configuration.

## 2. What the ledger is

A per-user root holding one fixed-size record per claim, plus a budget the operator edits and a single lock
that serializes admission. Installation is creating a directory. Enrolling a participant is creating one
directory named after it. There is no privileged installer, no signing ceremony, and no key custody.

Five properties carry the design:

- **A participant writes only beneath its own directory.** Every record has exactly one writer, so a torn
  write is the only reachable corruption and its cost falls on its own author.
- **Free is a positive value a writer must deliberately produce.** A truncated file, an unfamiliar revision,
  and a corrupted byte all decode as occupied, so no failure of the encoding can release capacity.
- **Every claim is created inside one short critical section.** Participants never hold a partial set of
  objects and never acquire objects in different orders, so no ordering rule is needed.
- **Charges are declared in a frozen set of dimensions**, so two participants that have never heard of each
  other still add their consumption the same way.
- **Conflicts are a prefix test over opaque identifiers.** A participant that has never heard of a hardware
  family still refuses to double-book its domains, so adding hardware costs no revision.

Each claim declares one of two kinds, and the kind is a statement about what the holder's death proves.
`Transient` means the operating system has reclaimed everything charged. `Persistent` means the holder's
death proves nothing, and is required for anything that outlives a process — a container, a cluster, a
virtual machine, a mount, retained bytes, or a request to an external system that may still complete.

## 3. What a granted claim establishes, and what it does not

A granted claim establishes two things: no other conforming participant holds a conflicting domain, and the
sum of declared charges plus the operator's reserve fits the budget.

That is a statement about **declarations**, not about behaviour. No limit is applied and no device is
fenced. A participant that declares four gibibytes and then allocates twelve is not detected. The ledger is
advisory between cooperating programs on one machine, offers no defence against a program that does not
participate, and none against a hostile process running as the same operating-system user.

Stating this plainly is the design rather than an apology for it. The failure the ledger actually prevents
is the common one: two programs that each observed the machine correctly, and each then started work the
machine cannot hold together.

## 4. Release-directed work is always admissible

Work directed at releasing a claim the participant already holds is never refused.

Without that rule the protocol deadlocks against itself, because tearing something down is also a mutation
of the host. A refused admission would prevent cleanup; absent cleanup there is no evidence the effect is
gone; absent that evidence the claim cannot be released; and the contention persists. A participant must
therefore never make its own cleanup path conditional on an admission it could be refused.

## 5. What the ledger does not cover

Admission is taken once, when the claim is made. It cannot observe a participant that declares honestly and
then consumes progressively — a store that fills during a long run, a cache that grows, an image set that
accumulates. Contention of that shape is the kind a shared development machine produces most often, and it
is outside what a one-shot admission decision can see.

This is a real limit, not a gap awaiting a patch. A participant that needs a bound on progressive
consumption applies its own mechanism and does not expect the ledger to supply one.

## 6. The complementary mechanism

Observing foreign work at the point of use is a different mechanism with a different reach, and the two are
complementary rather than alternatives.

Observation binds a peer that never opted in, needs no installed root and no agreement, and is available to
any participant unilaterally. What it cannot see is capacity with no process to observe: an idle cluster, a
stopped virtual machine, a registered guest, or retained bytes on disk. It also does not reach across
language ecosystems, because it must already know what a peer's processes are called.

The ledger covers exactly what observation cannot — persistent, processless, cross-language capacity — and
observation covers what a one-shot declaration cannot. Neither subsumes the other, and a participant may
adopt either without the other.

## 7. What adoption would require

Adoption is not a document change, and the work is a participant's own. Three obligations hold for any
participant, and none of them is stated here for any particular one:

- **Name the seams.** Every path that acquires capacity needs a claim, and every path that releases it needs
  a release. A participant that names one seam covers one seam; the paths it did not name stay uncovered,
  and a claim taken on one of them says nothing about the others.
- **Derive the charge once.** A participant that already computes what it needs converts that figure rather
  than authoring a second one. Two independently authored figures drift, and the drift is silent.
- **Establish release evidence.** A claim is only as good as its release. What counts as established is the
  participant's business, but a `Persistent` claim released without evidence is worse than no claim, because
  it reports capacity that is still spent.

A participant that cannot meet these keeps observing the machine and says so, rather than writing a record
nothing consults.
