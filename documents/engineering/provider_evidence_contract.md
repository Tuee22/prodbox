# Provider Evidence Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Own the value a fenced Provider Worker capability returns — its grammar, character
> rule, derived bounds, escaping, and the byte-exact persistence the Lifecycle Authority replays it
> against.

Three documents each own a neighbouring piece of this subject and every one of them stops short of
it. [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) owns the
fenced Provider Worker boundary and its stage vocabulary; [Lifecycle Reconciliation
Doctrine](./lifecycle_reconciliation_doctrine.md) owns what an observation licenses;
[Pure FP Standards § 2.3a](./pure_fp_standards.md) owns the one-encoder rule. None owned the value
that crosses between them, which is why six encoders could disagree with one validator without any
document becoming visibly wrong.

## 1. What provider evidence is

Provider evidence is the text a `ProviderReadOnly` or `ProviderMutation` capability returns to
describe what it observed or did. It is the only channel by which a fenced Provider Worker's
findings reach the Lifecycle Authority, and the Authority retains it and compares it on replay, so
it is a durable wire format and not a diagnostic string.

Evidence answers exactly one registered provider intent. It never carries a credential, a session
projection, or a bearer token: an `IssueEksClientAuth` observation is a sealed capability projection
and its evidence says that it issued, never what it issued.

`ProviderReadOnly` (`src/Prodbox/ControlPlane/ProviderNarrowSession.hs`) returns a sealed
`ProviderEvidence` and is handed the bound for the intent it is serving, so an encoder has exactly
one bound available and cannot return a bare `Text` at all. Every value is minted by the canonical
encoder in `src/Prodbox/Lifecycle/ProviderWorker/Evidence.hs`, whose constructors live in a leaf
module that only that codec and
`src/Prodbox/Lifecycle/ProviderWorker/ProviderWork.hs` may import.

**How it was before, because the shape of the defect is the argument for the rules below.** Evidence
was typed as bare `Text` on the capability signatures, so every `Text` was a legal answer and the
rule an encoder had to satisfy lived in a function the author never had to name. Six producers in
three modules each wrote their own wire format and all six emitted a character at or below `0x1f`.
Three failed unconditionally — including the wired desired-absence observation and the cascade's
terminal audit — and three failed only when they had something to report, so those settled exactly
when they found nothing. The same absence explains the private bounds: one encoder declared a
128 KiB maximum and a 4,096-identity maximum on a wire carrying 4,096 characters, two numbers that
were mutually unreachable as well as both wrong, and nothing compared them because nothing had to.
Adoption status lives only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

## 2. Grammar

One canonical encoder renders every family, and its parser is derived from the same description, so
a writer and a reader that could drift do not exist. Two arms:

```text
<prefix>/v2:absent
<prefix>/v2:present:<row>[,<row>]*        row = <field>[|<field>]*
```

Absence is stated, never implied by an empty row set — a short listing and a listing of nothing are
different facts, and collapsing them is the failure
[Lifecycle Reconciliation Doctrine § 3.0](./lifecycle_reconciliation_doctrine.md#30-positive-absence)
exists to forbid.

Each family owns one `<prefix>`. The version travels in the evidence rather than beside it, which is
the same rule the repository applies to its other durable wires. `renderEbsObservationBody` and
`parseEbsObservationBody` in `src/Prodbox/Lifecycle/EbsVolume.hs` are the in-repository precedent
this grammar follows: one prefix, one shape, one pair of functions.

## 3. Character rule

Evidence is printable. A character at or below `0x1f`, and `0x7f`, is refused — the predicate is
`character <= '\x1f' || character == '\x7f'` in `validateProviderIntentEvidence`
(`src/Prodbox/Lifecycle/ProviderWorker/ProviderWork.hs`), which is the function that names the
violation on every production path. Empty evidence is refused as its own case, and evidence over the
bound is refused with the measured length and the maximum it exceeded.

**Current revision.** The rule is stated a second time, independently, in `validateEvidence`
(`src/Prodbox/ControlPlane/ProviderWorkerAdapter.hs`), where it hardcodes a 4096 maximum rather than
consulting the per-intent bound and collapses all three causes into one opaque constructor. That
statement has no production importer and is scheduled for removal; it is named here because a rule
stated twice can disagree with itself, and this one already does.

The rule is not decorative. It has stood since 2026-08-02, before the native-family encoder that
violates it was written on 2026-08-24, and it is why a newline- or tab-delimited rendering is not an
option here regardless of how natural it reads in a terminal.

## 4. Bounds

**A codec declares its cardinality maxima and derives its character bound from them.** No codec
authors a size number the wire does not also use, and no codec invents a bound of its own: the
per-intent bound is `providerIntentEvidenceMaximumCharacters`, defaulting to
`maximumProviderIntentEvidenceCharacters` (4,096), and a family that needs a different one changes
that table rather than adding a second number somewhere else.

A listing that cannot fit its bound is not an answer. The terminal audit already refuses above a page
bound rather than returning a prefix; what this rule adds is that the cardinality must be *derived
from* the character bound instead of chosen independently. `maximumTaggedResourcePages` was picked at
100 on its own reasoning, and 100 pages of tagged resources cannot be rendered inside 4,096
characters in any encoding — so the audit could satisfy its own bound and still emit evidence the
wire refuses. A bound that a second bound can veto is not a bound.

The families and their cardinalities are declared together in
`src/Prodbox/Lifecycle/ProviderWorker/ProviderWork.hs`, and a test asserts that none of them can
render past the wire it is answered on. That assertion is the one the superseded encoders needed and
none had. **One of these numbers is arithmetic rather than evidence:** the terminal audit's
cardinality is derived from what the wire can carry, not measured against a real escaping account,
and the audit's normal answer is that nothing escaped. A live measurement is outstanding and is
tracked as a pending live proof in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

This is a different bound from the Provider client's 64 KiB transport maximum, which limits a whole
replay response rather than one intent's evidence. The two are easy to mistake for each other and
have been.

## 5. Escaping

Most families draw their fields from closed alphabets — ARNs, IAM names, DNS names — and need no
escaping. Owned resource tags do not: AWS tag keys and values are arbitrary text in which `,` and
`|` are legal.

That family percent-encodes exactly three characters — `%` as `%25`, `,` as `%2C`, `|` as `%7C` —
using uppercase hexadecimal only, and refuses any field containing a character the rule in Section 3
rejects. Any other `%` sequence is a refusal rather than a passthrough. One spelling per value is
what makes the encoding canonical, and canonicality is load-bearing because of Section 6.

## 6. Persistence and replay

The Lifecycle Authority retains evidence **verbatim** in `AuthorityProviderCompleted`
(`src/Prodbox/Lifecycle/Authority/Admission.hs`) in a cluster-retained object, and a later settlement
of the same operation compares the retained bytes against the new ones by equality, answering
`AuthorityProviderSettlementRefused "provider completion evidence mismatch"` when they differ. The
same settlement independently re-validates the evidence, which is why the character and bound rules
are checked twice: once inside the Worker's `capability-execution` stage, and once at Authority
settlement, which is not a Worker stage at all. A reader tracing a refusal through the Worker's
stage vocabulary will not find the second boundary there.

Two consequences follow, and they are the reason this document exists.

- **An encoder's output shape is a durable compatibility constraint.** Re-rendering the same
  observation differently makes a retained record irreconcilable with a fresh one. This is the
  evidence-wire counterpart of the recorded negative published for the *intent* wire in
  [system-components.md](../../DEVELOPMENT_PLAN/system-components.md), which forbids re-shaping an
  existing provider stack-configuration constructor for the same reason.
- **A canonical form is required, not merely tidy.** Byte equality over a format with two spellings
  for one value refuses correct replays, so Section 5's canonicality rule is what makes Section 6
  safe.

An intent whose evidence has never been admissible has no retained record to be incompatible with,
which is the one respect in which a defect of this shape is cheap to repair.

## 7. Version retirement

A decoder accepts exactly the prefix its own build writes. Older bytes are refused **by name** — the
refusal says which version was found and which was expected — and are never upgraded in place. This
is the rule already stated for the ownership manifest in
`src/Prodbox/Lifecycle/Teardown/OwnershipManifest/Internal.hs`, applied here.

Every family's prefix moves together when the grammar changes, including families whose existing
bytes were already legal. A reader that accepted two spellings of absence would be carrying the
drift this document exists to remove.

## 8. Intent Ownership

This SSoT owns the provider-evidence wire.

- Owned statement: the grammar, character rule, derived bounds, escaping, canonicality, verbatim
  persistence, and version-retirement rules for the value a fenced Provider Worker capability
  returns. Any document describing a provider observation links here for what its evidence looks
  like rather than restating it.
- Linked dependents: `documents/engineering/lifecycle_control_plane_architecture.md`,
  `documents/engineering/lifecycle_reconciliation_doctrine.md`,
  `documents/engineering/pure_fp_standards.md`, `documents/engineering/chaos_hardening_doctrine.md`,
  and `DEVELOPMENT_PLAN/system-components.md`.
- Not owned: which intents exist and what authority they carry
  ([Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)); what an
  observation licenses a caller to conclude
  ([Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)); adoption status
  ([Development Plan → Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here)).

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) — the fenced
  Provider Worker boundary, its capability algebra, and its stage vocabulary.
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md) — positive absence and
  what an observation may license.
- [Pure FP Standards](./pure_fp_standards.md) — the one-decoder/one-encoder rule this document is an
  instance of.
- [Chaos Hardening Doctrine](./chaos_hardening_doctrine.md) — conversions, and why counting encoders
  is the diagnostic.
- [Documentation Standards](../documentation_standards.md) — revision-scoped claims and the target
  declaration used above.
