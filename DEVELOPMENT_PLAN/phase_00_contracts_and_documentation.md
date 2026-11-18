# Phase 00: Contracts, Documentation, and Tooling Adoption

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: A fresh session can select work from one numerical queue and the real checker enforces the adopted Markdown phase, command, acceptance, mutation, and removal contracts.

**Phase**: 0
**State**: Complete
**Prerequisites**: Current checkout, existing Haskell build/test tooling, and the accepted Markdown contracts. No cluster, AWS credential, public DNS, or later phase is required.
**Acceptance**: A00-01, A00-02, A00-03, A00-04 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M00 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L01, L02, L03 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B071, B072, B073 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: [Phase 0 validation](evidence/phase_00_validation.md); historical results remain revision-bound regression inputs.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

A fresh session can select work from one numerical queue and the real checker enforces the adopted Markdown phase, command, acceptance, mutation, and removal contracts.

The code-side checker now enforces the adopted numerical plan and the obsolete
forwarding stubs have been removed. This completion concerns the checker and
documentation contract; it does not claim the later runtime refactor is done.

The [documentation adoption verification](evidence/documentation_adoption.md) records structural checks and the actual unchanged doc-lint failure. It does not close A00/M00. The first observed mismatch is the old generated resource-lifecycle marker in `substrates.md`; audit all old hardcoded assumptions during P00-T01.

## Implementation tasks

The following implementation log is chronological; statements about work being
open describe the point at which they were recorded. The completion record and
linked validation evidence below give the final disposition.

In progress: the checker includes initial canonical removal-row owner, state,
and duplicate-ID validation, numerical prerequisite direction checks, and
registry-to-command-leaf and option-name comparisons, numerical queue/document
consistency, and initial phase-to-manifest ID/owner binding checks, with unit
cases. Initial objective-row validation is present, and obsolete generated
sections targeting the adopted target documents have been unregistered. Initial
closure checks require available evidence, declared IDs, completed checkboxes
and removed owned rows, including an explicit matching evidence phase; these
structural checks do not prove execution. An
initial short-alias comparison has scratch positive and negative controls.
The command manifest now records registry requiredness per leaf, and the
checker compares it; independent parser behavior and execution evidence binding
remain open. Numerical queue,
phase-contract and ownership checks now replace the old sprint-queue checks in
the gate; obsolete sprint helper and fixture retirement is in progress. The
shared-file generated-artifact fixture now exercises the two retained gateway
sections. This partial work has not passed the Phase 0 acceptance or mutation
gate.

A scratch run of extracted pure numerical checks reported no findings for the
current manifests and rejected future dependency, invalid owner and missing ID
controls. It used a simplified link parser and is not integrated checker or
mutation evidence; the scratch file was removed.

An unmodified built binary was also run against a disposable tracked-file copy
with an empty environment and no credentials. The future-dependency diagnostic
was absent in the baseline and present after changing Phase 3 to depend on
Phase 9. Both lint runs failed overall on existing citation findings, so this is
diagnostic evidence only, not A00-02 or a passing mutation baseline. The scratch
copy was removed.

The same diagnostic method also distinguished a missing command, invalid
removal owner, broken relative link and a foreign-phase evidence record. Each
control was absent in the unchanged fixture and present after its change; both
baseline and adverse lint runs still exited nonzero. The disposable copies were
removed, and these observations do not replace a passing baseline or M00.

The initial Cabal executable build finished successfully. A subsequent
prerequisite-parser edit exposed an ambiguous type on incremental rebuild; it
was corrected and the next build passed. Its `dev lint docs` reached the
obsolete AWS remedy marker in the deprecated AWS test document. The remedy
registration now targets neither that stub nor a second owner; its policy
baseline reads the preserved `583443f` historical publication. A further build
passed and `dev lint docs` then reported historical citation/link mismatches
and an alias mismatch; the non-secret output is available locally at
`.build/phase0-doc-lint-before-citation-migration.log` (not portable evidence).
Six broken historical relative links and the absent cleanup-report link were
corrected, and the `--yes` and `--substrate` inventory issues were addressed.
The updated checker needs a new build and validation.

The subsequent executable rebuild passed. Its documentation lint no longer
reports the broken relative links or option-alias mismatch, but still reports
246 section citations against rewritten historical/current documents. The
non-secret output is `.build/phase0-doc-lint-current.log` and is local only.
Those references require explicit migration; the check has not been suppressed.
The first unit-target build failed after concurrent edits left its test source
importing a checker export absent from the older library snapshot. A coordinated
executable/unit rebuild passed. The selected plan-check group passed 19 tests
and the generated-section shared-file group passed 2 tests. The historical
citation group failed one of eight tests because its expected diagnostic still
named the old numbered documentation section; that expectation was updated.
These selections do not constitute the full gate. A fresh build is running.

The ordinary build reported partial-list and unused-wrapper warnings in the
new/retired checker paths. Those calls and obsolete IO wrappers have been
reworked, and the new Markdown-row checks now use total cell lookup; a fresh
`-Werror` build is still required to verify the canonical gate's compiler
settings. A subsequent extracted numerical-check scratch run passed under
`runghc -Werror` with the same simplified link parser; it is not an integrated
gate result and the scratch file was removed.

All 246 reported section numbers were independently found in the preserved
`583443f` documents. Four citations in the historical pending-obligation record
now state that revision explicitly; the next lint reports 242 remaining source
citations. The revised non-secret output is local at
`.build/phase0-doc-lint-historical-record.log`.

Five source comments in `App.hs` and `Aws.hs` now identify their historical
revision explicitly. The next lint reports 237 section findings, recorded
locally at `.build/phase0-doc-lint-citation-migration.log`; remaining source
references span 90 files, including diagnostics and test strings as well as
comments. A read-only inventory found 164 directly matchable source-comment
citations across 79 files; link destinations and non-comment strings require
separate review. For the chaos-hardening family, 50 direct comment lines across
33 files have verified historical section targets; the other forms remain for
individual review. `dev lint files` exited zero on the then-built binary; it does not
qualify the newer checker source or the full gate. The checker now includes explicit historical-section
resolution against `583443f`, with unit cases for missing documents and section
numbers. An extracted pure-function scratch check passed positive and negative
controls under `runghc -Wall -Werror`; it does not validate the integrated Git
lookup. The scratch file was removed. The first integrated lint exposed quoted
test strings as false citations; parsing was corrected and now also rejects
unsupported explicit revisions. The revised change still needs rebuilding and
validation.

Six broker comments now identify the historical revision explicitly. The
previously built checker reports 231 ordinary citation findings and three
quoted-string false positives addressed by the pending parser fix. The local
output is `.build/phase0-doc-lint-broker-citations.log`.

The subsequently linked checker reports no historical-reference errors and
still reports 231 ordinary section findings; its local output is
`.build/phase0-doc-lint-stable-build.log`. A suspected escaped-quote parsing
issue did not reproduce in this integrated run. The unit build remains open.

An integrated disposable-copy control exposed a remaining parser defect: an
explicit `583443f` citation to a nonexistent four-digit section is silently
ignored by the inherited section-number heuristic. The intended assertion did
not fire. The scratch copy was removed; fix the explicit-citation grammar and
rerun both this case and the unsupported-revision control after the active build
settles. This failure is not a mutation kill or acceptance result.

A scratch candidate that accepts an explicitly declared numeric section
regardless of digit count passed the four-digit pure negative control under
`runghc -Wall -Werror`. The candidate has now been applied with a unit case;
an integrated disposable-copy rerun now distinguishes the nonexistent
four-digit section and unsupported-revision controls from the unchanged copy.
The baseline and adverse runs all exited nonzero because other lint findings
remain, so this is diagnostic evidence only. The scratch files were removed.

A later disposable-copy control with a passing documentation-lint baseline
found another explicit-history gap: a `config_doctrine.md` citation at revision
`583443f` with a nonnumeric section was silently ignored and lint still exited
zero. The copy was removed.
The parser must reject malformed explicit sections, with a corresponding
unchanged assertion and integrated rerun; this is not a mutation kill.
A scratch candidate passed malformed, missing and numeric-section controls.
One existing synthetic test string must be split before integration so the
source scanner does not mistake Haskell concatenation for a real citation.

The coordinated pre-change build passed, followed by selected historical
citation, plan-check and generated-section groups (8, 19 and 2 tests). Fifty
verified chaos-hardening comment citations now name `583443f` explicitly.
The prior binary's documentation lint reports 181 ordinary section findings
and no historical lookup errors on the edited tree; the local output is
`.build/phase0-doc-lint-chaos-migration.log`. A fresh executable/unit build is
running for the parser and comment changes.

A disposable-copy preview of the next direct-comment batch converted 114
references and reduced ordinary citation findings from 181 to 54, but produced
one malformed bracketed historical citation. A corrected second preview again
reported 54 ordinary findings and no historical lookup errors. Both copies were
removed. After the coordinated build passed and selected 8, 19 and 2 test
groups passed, the 114-reference batch was applied. The built checker's lint
on the edited tree reports 54 ordinary findings and no historical lookup
errors; this is not a fresh-build gate result. The local output is
`.build/phase0-doc-lint-direct-citations.log`. The 54
remaining preview findings span 15 files, including 37 in `CheckCode.hs`; their
diagnostic and test-string semantics were reviewed against the adopted owners
or explicitly marked historical. The local preview output is
`.build/phase0-citation-preview-remaining.log`.

Fourteen secondary references on multi-section comment lines were also made
explicit historical citations, so the historical lookup can verify each one.
The then-built checker still reports 54 ordinary findings and no historical
lookup failures; see the local `.build/phase0-doc-lint-multi-section.log`.

After the remaining diagnostics and test references were migrated, the
then-built executable's `dev lint docs` exited zero on the edited tree. Its
local output is `.build/phase0-doc-lint-reviewed-citations.log`. A fresh
executable/unit build is running because source, including a generated-config
header, changed; this is not yet the canonical gate or closure evidence.

An initial L03 audit found ten forwarding files and old path references in
eleven Haskell source/test files, including historical checker helpers and an
operator diagnostic. The historical proposal's active ledger link has been
redirected; the forwarding files remain until the source and test references
are migrated and their removal proof passes.

The audit also found 34 deprecated engineering-document stubs. The new
historical-section checker currently discovers a Git object path through the
present-day stub, so deleting that stub would break validation. The checker
must resolve paths from the preserved Git revision itself before any such stub
is removed. A read-only `git ls-tree` audit found 60 historical Markdown objects
and one duplicate basename (`README.md`); all 212 explicitly matched historical
section references resolved across 15 distinct documents using only that tree.
An extracted resolver candidate passed positive, missing and ambiguous-name
controls under `runghc -Wall -Werror`; it was not integrated at that point. The scratch
files were removed. A second scratch candidate read the preserved Git tree and
object directly and passed known, missing and ambiguous-basename controls; it
was not integrated at that point. Exact incoming links and removal ownership still
need reconciliation.

The two remaining Markdown links from outside the deprecated engineering stubs
were historical quotations; they now name their recorded revision rather than
linking to the forwarding files. A direct Markdown-link scan found no remaining
links from outside those stubs to them. Source links and generated references
still require separate inspection before removal.

A source/test text inventory of the 34 engineering forwarding basenames found
14 names on at least one Haskell or Markdown line without an explicit revision
on that same line; the other 20 had no such line in that limited scan. The
remaining matches require contextual review, including multiline citations and
generated strings. This inventory is not an absence proof and does not include
every generated or non-Haskell artifact.
The 34 forwarding documents now name L02 as their removal owner, matching the
canonical ledger; their source-reference migration remains Phase 0 work.
Thirty-eight single-line links in Haskell comments were converted to explicit
references to their preserved historical revision. Subsequent changes bound 26
section references, migrated 15 diagnostic/fixture references, marked 31 more
historical comments and two multiline links, and marked 18 non-Haskell source
comments. A disposable preview passed documentation lint before application.
The remaining unmarked Haskell basename matches in that preview were synthetic
historical-parser test inputs; historical qualification records were retained.
The applied result still needs current-source validation and an absence audit.

An independent ledger inventory found 81 distinct B001–B081 rows, each linked
to its matching historical heading, and 102 L/B rows with valid numerical
owners and states; six rows are owned by Phase 0. The current objective table
contains O00–O45 exactly once. For B071, `Prodbox.Capacity.Storage` contains
`ScalingPolicyWitness` and `MlEngineStorageBudget`; the accepted resource
contract does not make speculative ML/cache services prerequisites. A scan of
the accepted engineering documents and plan README found none of B072's old
correspondence-marker forms. These are inventory observations, not completion
evidence for B071–B073 or proof of all runtime capacity behavior.

After the checker and old-path migrations, the rebuilt public documentation
lint passed both an unchanged disposable-copy baseline and the same copy after
removing all 44 deprecated plan and engineering forwarding files (both exit 0,
no findings). The copy was removed. This demonstrates the lint no longer needs
the files; it does not establish absence of unparsed source or generated
references, satisfy replacement acceptance, or authorize closing L02/L03.

An integrated disposable-copy control confirmed the current stub dependency:
documentation lint passed unchanged (exit 0), then failed with the expected
historical-resolution error after removing only the copied `config_doctrine.md`
stub (exit 1). Source references also remain to be migrated. The copy was
removed; rerun this control after the resolver change rather than treating the
current failure as removal evidence.

The checker has since been changed to discover historical paths from the
preserved Git tree, and its parser now retains malformed or missing section
numbers for rejection. Focused regression assertions were added. A freshly built
public binary passed documentation lint (exit 0); in a disposable repository
copy, its baseline and the same copy without the `config_doctrine.md` forwarding
stub both passed (exit 0), while an added historical citation with section
`bogus` failed (exit 1) with the expected historical-resolution finding. The
copy was removed. The checker source SHA-256 was
`9a74c4ee204418368233bca4bca8f049b162fe57851e14d0ca4fd77d932ece19` and
the binary SHA-256 was
`1c282f39326684d389fb29eba8193b72bec5604443c077c4ca5fe35ee44fa5ae`.
These controls do not establish removal of all stub dependencies. The previous canonical gate was interrupted after reaching
the unit suite because it exercised the superseded checker; it is not a pass.
The proposed M00 patch hashes were regenerated for that checker revision; later
source edits required rebinding them to the final checker. The variants had not
executed at that point; the later campaign and its review are recorded below.

An independent comparison of the current built binary's `commands --json`
against the baseline command table found 138 leaves and 138 unique rows, with
no inherited-option or required-option mismatches. Its 65 distinct registry
options also matched the option table's short-alias dispositions. The separate
parser-only additions remain outside that registry comparison; this inventory
does not by itself establish parser behavior or close A00-03.

On the same freshly built binary, a separate disposable-copy control passed its
unaltered baseline (exit 0), then separately rejected a missing command row, a
broken relative link, and removal row L01 with owner 99 (each exit 1 with its
corresponding diagnostic). The copy was removed. The focused historical-citation
unit group also passed all eight tests. These are partial A00-02 controls, not a
completed acceptance case or mutation result; complete phase evidence remains
outstanding.
The selected plan-checker group also passed all 19 tests on the revised source;
this ordinary local test is separate from the required isolated mutation baseline.

A further disposable-copy control constructed a synthetic coherent completed
Phase 0 and linked record solely to exercise closure validation. The public
checker accepted that fixture (exit 0, no findings). Removing only `A00-02`
from its linked record produced exactly one finding, the expected missing-ID
diagnostic (exit 1). The copy was removed. This is an adverse checker control,
not evidence that Phase 0 actually completed. It used the binary identity
recorded above; the full A00-02 evidence record remains to be assembled.

A durable unit-suite fixture has now been added to run the built public
documentation command against repository copies for the five adverse cases.
The repository path scanner was also changed to exclude `.test-data` and the
root `test-secrets.dhall` fixture, with a synthetic exclusion test. On the
first fresh build, both focused tests passed: the public fixture completed in
66.81 seconds, and the scanner exclusion test in 0.13 seconds. The tested public
binary SHA-256 was
`7089f0bcfa8e48fc54acab1be203f886bbab85f14f60f11fed462a5664a77225`.
That build reported a partial-function warning in the test helper; the helper
has been changed to pattern matching and requires a warning-clean rebuild and
rerun. The complete phase evidence and current-source gate remain open.

Separate disposable controls for missing `src/` and `test/` modules each
produced exactly the intended missing-source finding. A further adverse control
showed that an absent module on the old retirement allowlist was wrongly
accepted as current evidence (exit 0); the copy was removed. The blanket
exemption has been removed, current citations are constrained to files inside
the repository rather than private or foreign symlink targets, and
revision-qualified citations are checked against Git objects. Durable controls
for these cases and for available/unavailable historical objects have been
added. The revised executable and unit suite built; the source-citation group,
guard-to-ledger test and documentation lint passed. The expanded public-binary
fixture passed in 124.06 seconds on that build. Its invalid-object control was
then changed to use the Git null object ID deterministically; the rebuilt
public fixture passed again in 139.64 seconds, including an explicit post-cleanup
directory-absence check. The current full gate and mutation results remain open.
For that run the checker, unit source, unit binary and public binary SHA-256
identities were respectively
`2eef04e221c26d84c8794c4cf986c8b3c06b59d6d6981c357d8275c39b8d6464`,
`5b116cf4a50752c5f3a29b163ae3905c31d0219c27a230aef87fc1a2af889a9f`,
`b5dbac17a898f3c11be52b8a17905b3ca611cc0b450c6d9c3880756bc9cf7b14`, and
`c382fda7155ce7f0cb68d677b355f8295798789828df6865bbec090fbcd49e61`.

The unconsumed-guard registry's active ownership descriptions now name B047,
B046 and B056 in the numerical ledger rather than future fractional sprints;
an added test checks that every registry entry has exactly one open ledger row.
This metadata migration is not evidence that the guarded lifecycle work is done.

The broader historical resume-projection group exposed an additional mismatch:
its current-repository test still passed the numerical plan to the retired
fractional-sprint parser, failing with the old table and ledger expectations.
Moving the current-repository assertion to the numerical queue checker made
that ten-test group pass. The unused fractional-sprint parsing helpers and
their fixture-only tests have now been retired, retaining the current numerical
queue assertion and adding numerical ordering, duplicate, next-phase and state
controls. The revised source still needs a fresh build, tests and canonical gate;
the forwarding files have not been removed. Remaining active old-path source
references were moved to the canonical ledger or marked as historical. The
legacy migration prompt and the initial AWS-remedy fallback now identify the
preserved Git revision directly instead of depending on a current forwarding
path. Those changes also require fresh executable and lint validation.

The revised executable and unit suite subsequently built without reported
warnings. The ten numerical-plan contract tests and the current-queue
projection test passed, and the rebuilt executable's documentation lint
exited zero. Checker, unit source and executable SHA-256 identities were
`0e700afd766042ab36e922691b06f7ccc70c6c4f08d1843565e202f4ffde2155`,
`eef38dfa1229ef4420cbe55da7149e7cfa31798cece4bb7a39750c8ab21be1c5`, and
`21cdb1804033bc9ad2b4e244377a8c74d439ee528ff8987d733f5976c3588050`
respectively. These focused checks do not replace the canonical gate, source
mutation runs, or complete removal proof.

An offline isolated unmodified build completed the selected plan-checker group:
19 tests passed, exit 0, without timeout. Its tracked-source manifest SHA-256
was `59fe76e8ba3dd1b94b9ff0a87b40c212d520fc5f5910165a39b427f2dff3bf78`;
the harness did not capture a unit-binary hash. Its temporary workspace was
removed. This run preceded the historical-checker change and does not satisfy
the same-source mutation baseline or demonstrate any mutation kill.

A second isolated baseline passed all 19 then-selected tests, exit 0, in
1,252.8 seconds under the filesystem/socket-denial boundary. Its unit-binary
SHA-256 was `0bcf0431eb4808c04bb53cddd123ea105011c6dc1dccaaeaa26c4f4d215e06c1`;
its tracked-source manifest was
`32216cae684dbad484bd299d5e60ad8c3e58beaa59a6f91f3c736209c8abe486`.
Its scratch and foreign sentinel were removed. This snapshot also predates the
subsequent checker retirement and does not qualify the current mutation run.

A candidate baseline and four separate unmutated candidate workspaces were
prepared for the same restricted boundary. Their common non-Markdown,
non-`cabal.project` source manifest is
`c0bac9af0d5d72728c5b913fb3170b346edbb08e9f03af698eebc662cbc885ff`.
The waiting campaign was interrupted and its unmutated workspaces removed when
the need for durable public-binary fixture tests was identified; no variant ran.
The candidate baseline subsequently passed all ten selected tests, exit 0, in
1,240.2 seconds. Its tracked-source manifest was
`3ef42580d0f07c132c8e1ca580b187b1b4a67ac50c9e6f3783f5d417c187ef54`
and its unit binary SHA-256 was
`fad20b3082bf57628c564e6fde015483073eb8b7918232e433b276553bc5d0f5`;
scratch and the foreign sentinel were removed. The later durable fixtures and
repository-scope fix supersede that candidate and require a newly bound
baseline. Each planned variant has a
2,400-second limit and 2 GiB
per-file limit; the outer runner checks a 10 GiB scratch budget during execution
and runs variants sequentially. It stops for review on a timeout, disk-budget
breach, survivor, compilation failure or unrelated assertion failure. A
candidate remains unqualified until its source is applied and matched to the
recorded snapshot, its exact assertion failures are reviewed and its scratch
cleanup is confirmed.

A replacement baseline and four separate, still-unmutated workspaces have
been started for the later scanner and durable-fixture source. Their shared
non-Markdown, non-`cabal.project` manifest is
`0ce5d69e6d220f419ef67ce340ab8b709a37e49a78e2e9970f8640a819636b4b`;
the selected unit source SHA-256 is
`527170c92609a70536368ba1e083b27470f68a5f6d5a1bc9924dd1a173499126`.
The campaign waits for its own passing unmodified baseline before applying any
variant and uses the budgets above. No current mutation result is available.
The current canonical gate then exited 1 on an HLint redundant-conditional
finding in the new path-scanner exclusion branch. The waiting campaign was
stopped before applying mutations and its workspaces were removed. The branch
has been simplified; its build, gate and a newly bound mutation baseline remain
to be rerun. The prior baseline passed its ten selected tests in 1,281.7
seconds, with unit-binary SHA-256
`03d78f8712268287076a199241bd5bc96441017963f37b36588bbbba15fe58d8`;
its scratch was removed. It is historical diagnostic data for the earlier
checker, not the baseline for the corrected branch.

A corrected-source baseline and four separate unmutated workspaces have now
been prepared. Their non-Markdown, non-`cabal.project` manifest is
`fe5ed27635228fb4aced591843ef6dfe3dd6f915221e8aba8e4cef117475d981`.
The same bounded campaign will apply its variants only after this baseline
passes; no result is available yet.
That waiting campaign was stopped with all workspaces still unmutated and
removed when review found the fixture needed an explicit post-cleanup absence
observation. The fixture change requires another matching baseline before M00.

The later source-citation fix expanded M00 to five variants. A fresh two-group
isolated baseline and five separate unmutated workspaces have been prepared for
the current code; their non-Markdown, non-`cabal.project` manifest is
`5cc3e7424d5e62fd9a3f1df1e648d39e30322285fb350759d58337d7192e238c`.
The workspaces could not be mutated until both baseline groups passed and the
applied source was independently matched. No variant had run at preparation.

Both current isolated baseline groups subsequently passed: the ten numerical
plan tests completed after a 1,273.7-second build/run, and the three source
citation tests completed in 11.8 seconds. The isolated unit-binary SHA-256 was
`782ff589c68c0b1d3a393e54a65a7e0393e6049e6ec2c05391004c077cd930ab`, and
the baseline scratch and foreign sentinel were removed. The applied non-secret
source manifest matched the prepared workspaces. The future-dependency variant
compiled and exited 1 in 1,202.4 seconds without a timeout or disk-budget
failure. Its unchanged phase-4 dependency assertion failed, and the other nine
selected tests passed. The removal-owner variant subsequently compiled and
exited 1 in 1,166.9 seconds without timeout or disk-budget failure. Its unchanged
assertion rejecting phase 11 as B071's owner failed, with the other nine selected
tests passing. The missing-evidence variant compiled and exited 1 in 1,166.9
seconds without timeout or disk-budget failure. Its unchanged missing-record
assertion failed, with the other nine selected tests passing. The foreign-phase
variant compiled and exited 1 in 1,177.9 seconds without timeout or disk-budget
failure. Its unchanged wrong-phase evidence assertion failed, with the other
nine selected tests passing. The source-citation variant compiled and exited 1
in 1,166.9 seconds without timeout or disk-budget failure; its unchanged
assertion rejecting the absent Host/Tool module failed, and the other two
selected tests passed. The runner reported scratch and sentinel cleanup; an
independent check found no matching temporary directories or campaign workers.
Final Phase 0 acceptance and owned removals remain open.

The canonical `./.build/prodbox dev check` subsequently exited 0 on checker
source SHA-256
`2eef04e221c26d84c8794c4cf986c8b3c06b59d6d6981c357d8275c39b8d6464`.
Formatting, HLint and the warning-clean build passed, followed by four gated
unit suites with 9,961, 27, 35 and 935 passing tests. Its local transcript is
`.build/phase0-gate-source-evidence.log`; later Markdown evidence edits still
require documentation lint. This gate does not establish M00 or removal
completion.

The numerical prerequisite parser had a defect for a list such as
`Phases 1, 9`: it read only the token immediately after the label.
An actual disposable-copy lint control confirmed the defect: both the unchanged
plan and a Phase 3 fixture declaring `Phases 1, 9` exited zero, and neither
reported the Phase 9 dependency. The copy was removed. This is not an M00 kill. A scratch candidate for list
and range parsing passed positive and negative controls under `runghc -Wall
-Werror` after correcting an initial scratch compilation error. A further scratch pass
covered semicolon and backtick punctuation and an unrelated later number. A
subsequent candidate also stops list parsing at clause boundaries, avoiding a
false dependency on a number in the next clause; its scratch controls passed.
The candidate and corresponding unit assertions were applied. The newly linked
public checker then passed the unchanged documentation-lint baseline (exit 0)
and rejected the Phase 3 `Phases 1, 9` fixture (exit 1) with the intended Phase
9 finding; the disposable copy was removed. The diagnostic binary SHA-256 was
`666eb9eb31a9173c7fb610bc836eb5c92f36b973144764f3946a2ee1454e4abc`, and
the checker source SHA-256 was
`e0b43d27a04cc9f454b27e4467e91d08d8bb0ed8f8f78e697f2884d08a748c36`.
This is one control, not a full phase or mutation result. The coordinated
build passed and selected citation, plan-check and generated-section groups
passed 8, 19 and 2 tests.
At that point the old pure sprint-grammar helpers and their tests were still
present. Their subsequent retirement is recorded above; L01 and L03 remain
open until the revised checker, old paths and removal obligations are validated.

For M00 isolation, Bubblewrap's network namespace and an unprivileged user/network
namespace both returned permission errors on this host. Landlock ABI 8 and
`libseccomp` are present; their combined filesystem and socket restrictions
were probed in a disposable process: an allowed fixture was readable, a sibling
fixture was denied, and IPv4 and Unix socket creation were denied. That probe
was extended to compile and link a trivial Haskell program using a restricted
toolchain allowlist while the same denials held. A second probe compiled against
the package store with read-only and socket-denial controls, and an offline
Cabal probe built a minimal project. These probes do not yet prove the actual
project allowlist or complete mutant isolation. No mutant has been run under an
unverified boundary.

A read-only offline Cabal dry run resolved the actual project targets in a
disposable restricted snapshot after replacing its absolute support path with
a scratch-local path. Socket creation and access to a foreign fixture were
denied. This proves dependency planning only, not a full isolated project build
or a mutation result; the snapshot was removed.

An unmodified isolated project build and selected plan-check run completed
under that restricted boundary. Its tracked-source snapshot manifest
SHA-256 is `59fe76e8ba3dd1b94b9ff0a87b40c212d520fc5f5910165a39b427f2dff3bf78`;
the scratch-only support-path projection is separate. The result and its
prior-source limitation are recorded above.
The three M00 assertion IDs are now bound to their existing descriptive test
names in the mutation catalog; the catalog change requires a new snapshot before
it can be part of a final bound result.
An independent comparison found all 1,741 tracked non-Markdown paths other
than `cabal.project` byte-identical between that snapshot and the checkout;
the digest was `9858572ed840e17c7a74521293a20dc7dab1f155b9add611ddbedcdc50d227a5`.
The scratch project file differs only in its verified scratch-local support
path. This excludes secret fixture/data roots and does not replace the required
binding to the changed Markdown catalog.
During the run, read-only process inspection observed `NoNewPrivs: 1`, seccomp
filter mode, no open socket descriptors and no AWS, kubeconfig or Docker-host
environment variable names in the isolated Cabal process. This observation is
not by itself proof of the full boundary or a test result.

The canonical `dev check` reached Haskell lint and exited 100 on formatting;
it did not reach the warning-clean build or full tests. Its local non-secret
output is `.build/phase0-canonical-gate.log`. The two reported Haskell files
were formatted and require a fresh build and gate run.
The next canonical gate was interrupted as recorded above. A subsequent run
was also interrupted before a result; Markdown evidence changed after it began.
Neither run is a passing gate or binds the final document snapshot.
The post-retirement canonical gate then exited 100 at formatting: the shell
formatter was Fourmolu 0.15 while the repository style-tool bundle requires
0.19. The reported files were reformatted with the bundled tool; the gate must
be rerun after the subsequent source-reference edits.
On the next pre-candidate snapshot the canonical gate exited 0: its formatter,
HLint and warning-clean build passed, as did all four gated unit suites
(9,958, 27, 35 and 935 tests). Subsequent reference and checker-test changes
supersede that result; a current-source gate remains required.

The historical-reference unit build failed after concurrent edits caused its
test module to import an export absent from its older library snapshot. A later
coordinated executable/unit build and the focused historical tests passed;
future source edits must not race a build that is used as evidence.

An independent comparison of the built registry with the new required-options
column found no mismatches across 138 leaves; the newly linked executable's
documentation lint likewise reports no command/option inventory mismatch but
still fails on the 242 citations. Its local output is
`.build/phase0-doc-lint-current-registry.log`. Parser behavior remains open.

- [x] **P00-T01** — Update the existing Haskell document/plan checker and its tests to parse the canonical Markdown manifests, numbered phase records and snake_case ledger. Preserve legacy-source discovery only where the migration ledger requires it; remove hardcoded old queue/filename/table assumptions.
- [x] **P00-T02** — Expand and mechanically reconcile every current public/internal command leaf and meaningful option against command_dispositions.md. Reconcile every product objective, old open obligation and pending/unowned legacy row; do not carry historical Done labels as new evidence.
- [x] **P00-T03** — Implement real invalid-plan fixture tests for future dependency, command omission, broken link, missing evidence binding and invalid removal owner. Include source/test existence checks and evidence availability without treating a string-shaped claim as execution.
- [x] **P00-T04** — Build safe scratch variants for M00 using existing tooling, compile the actual changed checker and require the intended unchanged assertions to fail. The automated runner in Phase 1 is not a prerequisite.
- [x] **P00-T05** — Run the canonical gate and actual Phase-0 checker acceptance; record source/binary identity, negative-control outcomes, mutation outcomes and owned removal proofs. Retire the temporary hyphenated ledger forwarding document only when code no longer depends on it.

## Real acceptance and independent observation

The [validation record](evidence/phase_00_validation.md) binds the identities,
observations, negative controls, mutation results, and cleanup scope.

After implementing the checker migration, build the operator with the repository Cabal build path and invoke the real `./.build/prodbox dev check`. Run the actual checker fixtures and scratch source variants using existing compiler/test entrypoints. Do not wait for Phase 1 automation or substitute a Markdown review for execution.

The linked catalog defines the exact real workflow and observer for each case:

- [x] **A00-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A00-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A00-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A00-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M00 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

No runtime/provider resources are admitted. Work uses non-secret owned scratch copies and bounded compiler/test outputs; preserve only evidence inputs still needed to reproduce results.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/documentation_standards.md](../documents/documentation_standards.md)
- [DEVELOPMENT_PLAN/development_plan_standards.md](development_plan_standards.md)
- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/code_quality.md](../documents/engineering/code_quality.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [x] All implementation tasks and owned acceptance cases passed.
- [x] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [x] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [x] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [x] Owned legacy removals and documentation/generated-reference updates are complete.
- [x] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

All four acceptance cases and M00 pass on the actual revised tooling; every active command/objective/removal has one valid owner; no future phase is needed to understand or enforce this plan.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
