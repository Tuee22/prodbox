# Phase 0 Validation Evidence

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Phase 0 checker migration and owned documentation removals.
**Phase**: 0

> **Purpose**: Bind Phase 0 acceptance and mutation observations to tested inputs and preserve their limitations.

## Scope and identity

This work admits no provider or runtime resources. Its isolated compiler and
test workspaces contain non-secret tracked inputs; `test-secrets.dhall`, runtime
data roots, and `.build` are excluded from the source manifest. The applied
non-Markdown source projection, excluding the scratch-specific `cabal.project`,
has SHA-256 `5cc3e7424d5e62fd9a3f1df1e648d39e30322285fb350759d58337d7192e238c`
across 1,741 tracked paths. This is not a digest of the Markdown contracts or
of any secret. The checker source SHA-256 is
`2eef04e221c26d84c8794c4cf986c8b3c06b59d6d6981c357d8275c39b8d6464`;
the public binary SHA-256 is
`c382fda7155ce7f0cb68d677b355f8295798789828df6865bbec090fbcd49e61`.
That untracked binary was subsequently replaced by the Phase 1 build and is
not currently available at its former local path; its digest and gate output
identify the observed run but do not make the old binary recoverable.
The non-secret closure projection of the queue, phases 0–1, plan standards,
and canonical command/objective/acceptance/mutation/removal manifests is
`.build/phase0-closure-contract-manifest.txt`, with SHA-256
`ae1d58b7103ca1912a53c4cbe514f47a5cb35ff56a15ebc2869bb7805d475785`.
This evidence record is excluded to avoid a self-referential digest; future
phase edits will intentionally supersede individual entries.

The output paths below are local ignored build artifacts, not portable evidence.
Their availability was checked locally; another checkout must re-establish it.
On 2026-11-16, the seven gate, fixture, baseline, campaign, and independent
registry-review artifacts named below were present and nonempty locally. The
campaign log is retained after process settlement. L20 in the removal ledger
owns eventual scratch/evidence-alias retirement; required reproduction inputs
must remain available until their replacement and availability are established.

The mutation campaign compiles one source variant at a time with offline Cabal
and selects the unchanged numerical-plan or source-citation test group. Each
variant has a 2,400-second limit, a 2 GiB per-file limit, and a 10 GiB total
scratch limit. The isolated baseline used the same selected groups. The outer
runner probes foreign-file and IPv4/Unix socket denial before each variant;
all five probes passed. No cloud endpoint or credential is in scope.

## Acceptance observations

- **A00-01**: The public `dev check` exited zero on the identified checker;
  its local output is `.build/phase0-gate-source-evidence.log` (last modified
  2026-11-16 02:59:14 -0500). It ran the formatter, HLint, warning-clean build,
  and four gated unit suites. After the forwarding-file removals, the same
  public command exited zero again; `.build/phase0-gate-post-removal.log`
  contains the formatter, no-hint HLint, warning-clean build, and passing unit
  suites of 9,961, 27, 35, and 935 tests.
- **A00-02**: The public documentation fixture passed on the identified public
  binary, including separate malformed repositories and a post-cleanup absence
  check. Its local output is `.build/phase0-public-fixtures-evidence-final.log`
  (last modified 2026-11-16 02:34:29 -0500). The unchanged fixture requires a
  clean baseline, then independently removes a command disposition, adds a
  future dependency, adds a broken link, and replaces L01's owner with an
  invalid value. It also prepares a clearly synthetic complete-phase copy,
  verifies that copy is clean, and removes A00-02 from its linked evidence.
  Each adverse copy must exit 1 with its named finding and no unrelated
  findings. Additional cases cover missing, escaping and revision-qualified
  source paths. The temporary directory must be absent after cleanup. This
  observation precedes this working record and the final removal snapshot. A
  rerun after the command-inventory correction passed in 137.85 seconds,
  including the temporary-directory absence assertion; its local output is
  `.build/phase0-public-fixtures-corrected-docs.log`. A post-removal rerun
  passed in 140.45 seconds, including its cleanup assertion; the local output
  is `.build/phase0-public-fixtures-post-removal.log`. The canonical gate
  subsequently ran the same fixture as part of its unit suite. A further
  closed-phase-state run passed in 123.11 seconds and cleaned its temporary
  directory; its output is `.build/phase0-public-fixtures-closed-phase.log`.
- **A00-03**: An independent comparison of the built registry's
  `commands --json` output with the command disposition table found 138
  matching leaves, including inherited and required options, and 65 matching
  distinct option names and short-alias dispositions. The separately listed
  parser and helper cases are outside that comparison. The objective inventory has O00–O45
  once each, and the ledger has 81 distinct B rows linked to matching historical
  headings. These inventory observations do not prove parser behavior or final
  removal; these are not claims about later target-parser behavior.
  A fresh independent leaf, inherited-option, requiredness, and short-alias
  comparison on the public binary named above found zero missing, extra, or
  mismatched rows, including both alias and no-alias uses of `--yes`. The alias
  comparison aggregates by long name; it does not verify per-leaf alias scope.
  Its local script is `.build/phase0-registry-independent-review.py` (SHA-256
  `92c03eda99cd19ff559921cb340c06998b19d9cb8e0643ef8f4ca54e29e6a669`),
  with output at `.build/phase0-registry-independent-review.log`. In a
  temporary manifest copy, the independent review accepted the baseline,
  rejected a missing C001 row with exactly one missing leaf, and rejected an
  altered `--verbose` alias with one alias mismatch. The copy was absent after
  cleanup; `.build/phase0-registry-independent-controls.log` records the
  outcomes.
  Source inspection found no caller of `outputOptionsParser`. The identified
  public binary rejected `commands --format plain`, `commands --color never`,
  and `commands --no-color` with invalid-option errors; help for
  `config generate` displayed `--portable` and `--help`. The command manifest now
  distinguishes the unwired output helper from the accepted parser cases. This
  correction postdates the isolated mutation workspace snapshot; the
  post-removal public fixture and gate used the corrected documents.
- **A00-04 / M00**: Both unmodified isolated baseline selections passed; their
  local output is `.build/phase0-isolated-evidence-baseline.log` (last modified
  2026-11-16 02:50:34 -0500), and the isolated unit binary SHA-256 was
  `782ff589c68c0b1d3a393e54a65a7e0393e6049e6ec2c05391004c077cd930ab`.
  The future-dependency mutant compiled and failed its intended unchanged
  assertion for a phase 4 prerequisite on phase 3 while its other nine selected
  tests passed. Its patch SHA-256 was
  `6b8b4b8b01b3c240db252e1203eb3c7a7052b810dbd96350962ae551746e8a40` and
  its unit binary SHA-256 was
  `e0a316d8efb7b6523910d61f99252a20e5df440e94142b22c1e890af021e1080`.
  Its elapsed time was 1,202.4 seconds, without timeout or disk-budget
  exhaustion. The removal-owner mutant's patch SHA-256 was
  `ca951983a39edd484e4b520566f257a851278f8fdae3f9edfd500182c4089abe`.
  It compiled and failed the unchanged assertion rejecting a B071 owner of
  phase 11; its other nine selected tests passed. That build's unit binary
  SHA-256 was `7673c50d3703fb160f2202bdf3b792db64ed6cd42d9a7825d5f277e12e0ce268`;
  it exited 1 in 1,166.9 seconds without timeout or disk-budget exhaustion.
  The missing-evidence mutation, patch SHA-256
  `7e0f9923877daf9af1ab68b987852dd5ff54fd00c29dc3a418f14327b2f84d42`,
  compiled and failed the unchanged assertion requiring an available record;
  the other nine selected tests passed. Its unit binary SHA-256 was
  `d42af15eb923f50a64b2b4234b0e511e589e2d96e921d18b1720b6cf7a1f51cc`;
  it exited 1 in 1,166.9 seconds without timeout or disk-budget exhaustion.
  The foreign-phase evidence mutation, patch SHA-256
  `9e792e8e979f4f8851fc49411a40df57a9777585545ff2bab86e162f8ef13abf`,
  compiled and failed the unchanged assertion requiring evidence bound to the
  correct phase; the other nine selected tests passed. Its unit binary SHA-256
  was `b0e173e35909b9833e41e796a6f5ef3a1786ed132ae6085bee486624574e8b46`;
  it exited 1 in 1,177.9 seconds without timeout or disk-budget exhaustion.
  The final source-citation mutation, patch SHA-256
  `aeba094c1f58ba0e97fbc97a714cf9be679784c331d426b43ac99be8608c4505`,
  compiled and failed the unchanged assertion that the absent Host/Tool module
  is not current source. The other two selected
  citation tests passed. Its unit binary SHA-256 was
  `854344bc97f5b892013ba917b5c0f13a0f408365c26a8b092bf1c46139211722`;
  it exited 1 in 1,166.9 seconds without timeout or disk-budget exhaustion.
  Each of the five selected failures was reviewed at its exact assertion.
  The campaign output is `.build/phase0-mutant-campaign-evidence.log`. The
  runner reported scratch and sentinel cleanup, and an independent check found
  no campaign or foreign-sentinel temporary directories and no campaign workers.

## Removal review

The current ledger has 102 distinct L/B rows with owners in phases 0–10 and
recognized states. Its six Phase 0 rows—L01–L03 and B071–B073—are Removed.
For B071, the preserved historical concern was unscheduled capacity type
families in a deprecated doctrine; `src/Prodbox/Capacity/Storage.hs` contains
the current scaling witness and ML-engine storage budget types. For B072, a
scan of accepted engineering documents and the plan README found none of the
four historical marker forms quoted in the B072 baseline. For B073, the
numerical owner inventory above replaces the old unscheduled-sprint accounting.
These inventory observations are supplemented by the acceptance, mutation,
and removal checks recorded here.

A pre-removal search of non-Markdown, non-JSON tracked worktree content for
the old hyphenated ledger and phase-file names found two explicit Git-revision
references to the old phase 4 document and one historical comment in the
Keycloak capture fixture. The Git references read the preserved object, and the
fixture comment describes the origin of that captured HTML; none requires a
working-tree forwarding file. Markdown and JSON were reviewed separately below.

A separate JSON inventory found 50 old plan/ledger path-and-hash entries in 26
historical qualification records. None of the current forwarding files matches
the recorded hash. Of the 50 entries, 25 name explicit scratch snapshots, none
of which is currently present; the other 25 have no snapshot field. Comparing
the recorded Git head where recognizable recovered the exact recorded bytes
for 10 entries; the other 40 did not match or were unavailable by that check.
These historical records include dirty source identities, so a Git revision
alone is not proof that its bytes match the run. This is an existing evidence
availability limitation, not a reason to rewrite the records or count the
forwarding stubs as original inputs. Preserve the records and audit any needed
reproduction inputs under L20 before their remaining evidence is retired.
Across all reachable Git history for these ten historical paths, 828 blobs were
checked: 8 of the 38 distinct recorded path-and-hash pairs matched, while 30
did not. This search does not establish whether another local or external copy
of the missing bytes exists. The local reproducer is
`.build/phase0-historical-input-audit.py` (SHA-256
`886fd2eae9edd660572a75878220048a7d0377d6ab16db675baab5c5c6b548ce`),
with output at `.build/phase0-historical-input-audit.log`.

A separate pre-removal Markdown link resolution scan covered `documents/`,
`DEVELOPMENT_PLAN/`, and `test/`, excluding the 44 deprecated stubs themselves
and historical material. It found no links from that scope to those stubs. This
does not prove the files were removed and does not replace the final audit.
The candidate inventory has 34 engineering and 10 plan stubs, each with a
corresponding Git object at revision `583443f`. Their current non-secret file
hashes are listed in `.build/phase0-removal-candidates.txt` (inventory SHA-256
`e8f9b427a3474cab0d755ca15441da4f0ce5702569cc3ca5042cd6177357428e`).
The baseline objects do not by themselves reproduce the other dirty historical
snapshots discussed above.
An independent local link audit, `.build/phase0-stub-reference-audit.py`
(SHA-256 `2f5b832e192bf0839857cf665d41fc33413904170292be93e107c8e478fe54e3`),
scanned 60 nonhistorical Markdown documents against those 44 candidate paths;
it found zero links while all candidates remained present. A separately planted
bad link was rejected, and its fixture was removed. Outputs are in
`.build/phase0-stub-reference-audit-before.log` and
`.build/phase0-stub-reference-audit-control.log`. Re-run after removal for the
the absence observation. After verifying every candidate against its recorded
hash, all 44 forwarding stubs were removed. The same audit then found zero
candidate files and zero incoming links in 60 nonhistorical Markdown documents;
the local output is `.build/phase0-stub-reference-audit-after.log`. Public
documentation lint and the canonical gate passed on that worktree.
