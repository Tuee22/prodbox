# Phase 01: CLI Contexts, Retained kind Storage, and Evidence

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: The real public control/context slice creates and diagnoses isolated kind environments whose host-backed data survives node loss, and a bounded evidence/mutation runner detects fabricated results.

**Phase**: 1
**State**: Complete
**Prerequisites**: Phase 0 complete; supported Linux host and pinned container-runtime/kind prerequisites. No Vault, cloud account, SES, public domain, or later runtime adapter is required.
**Acceptance**: A01-01, A01-02, A01-03, A01-04, A01-05, A01-06, A01-07, A01-08 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M00, M01, M02 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L04, L05 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B020, B021, B039, B055 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: [Closure evidence](evidence/phase_01_closure_2026_11_25.md) indexes the current acceptance, mutations and cleanup. [Earlier validation](evidence/phase_01_validation.md) remains attributable to its original builds. L04 and L05 are closed for their new-install scope, and L14, L16 and L18 own the legacy routes.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

The real public control/context slice creates and diagnoses isolated kind environments whose host-backed data survives node loss, and a bounded evidence/mutation runner detects fabricated results.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

Verifier memory follow-up (2026-11-24): the retained scale fixture's Docker
response still used the former fixed volume name, so exact node inspection
refused before it reached the read-back. The fixture now reports the
generation- and operation-bound volume. With the prior implementation
(`79c1807e0fd9869a0e5e6c71847496890def9c20`), the corrected 11-link
fixture then reproduced status 251 with an explicit GHC "Heap exhausted"
message at `+RTS -M64m -N1`. A second run with the field-selector check
reproduced that outcome and reported 28,529,992 bytes maximum residency.
The runs used a disposable Docker socket and loopback TLS API with a
non-secret generated kubeconfig. They exercised the node and CA readers and
the real `kubectl` client. Their logs are
`.build/phase1-rts-probe-docker-family-20261124.log` and
`.build/phase1-rts-probe-baseline-20261124.log`; the second fixture binary
SHA-256 is `aab5cb3f3f256366ebda93ce01d374df30fe3a33ca015111787140195c57ed03`.
The live worker's exact failure stage remains unknown.

The public `control delete --yes` managed-scale fixture subsequently
reproduced manager exit 251 with neither a read-back nor a usable cleanup
result (`.build/phase1-rts-probe-managed-traced-20261124.log`). It observed
the exact successor retire. The binary SHA-256 was
`041e443538ef039d53ac2de8f57833f92f9bed0e9edea80e5a8ff3dd5e70a7fe`.
This run submitted only the fixture's managed observer. Its provider and
Kubernetes endpoints were disposable fixtures.

Decision (2026-11-24): bracket the read-only node, CA and kubeconfig
observation with the held operation admission, while preserving root,
record, and Docker-peer checks inside the snapshot. This follows the
independent read-back and exact identity requirements in
[control_plane.md:50](../documents/engineering/control_plane.md#recovery-and-local-removal)
and the same-budget regression requirement in
[resource_governance.md:30](../documents/engineering/resource_governance.md#runtime-sufficiency-and-boundedness).
The old implementation repeated the complete predecessor admission inside
each component read. Recheck the corrected fixture at 64 MiB and exercise
the public managed successor with the disposable endpoints before resuming
live recovery. Controlled runs may leave publication metadata after input
retirement. Scope and account for these exact fixture publications before
claiming cleanup.

The first change reduced allocated bytes from about 37.4 GB to 24.9 GB,
but the traced standalone case still exhausted its 64 MiB heap after the
namespace observation entered the record writer
(`.build/phase1-rts-probe-traced-20261124.log`). The writer now rechecks
the held admission before the prerequisite snapshot, immediately before the
exclusive write and after independent read-back. Root and intent are checked
during the local read-back. The resulting standalone 11-link case passed at
64 MiB with 4,876,672 bytes maximum residency and 18 MiB total memory in use
(`.build/phase1-rts-probe-writer-scale-20261124.log`). The post-write
admission control initially used a wrong diagnostic path and was corrected
to observe the actual scoped record. The revised ordinary fixture passed
the slow admission, pre-write change and post-write incomplete-record
controls at the same heap cap
(`.build/phase1-rts-probe-recheck-regression-20261124.log`). The fixture
SHA-256 is `307abcffc1ce912479ade9598217a70196da3ab50dfa4c8e91103afa7b18c878`.

The rebuilt public managed fixture passed at the same controller cap
(`.build/phase1-rts-probe-managed-fixed-20261124.log`). The focused integration
case also passed its matching CA, mismatched CA, and changed admission
controls. The public binary SHA-256 was
`7e8a9b9f2b31700c121de4ac3d96abf7d9df61c35f182c6fd6d8666ce8d8a726`.
This authorized resuming the in-hand test operation, without starting a new
kind environment or changing the controller envelope.

Retained test recovery (2026-11-24): the same binary submitted successor
`f189ba6d044b6043e40960b38c07a435` for operation
`e69453b00acc4c3133b7e9730a381844`. Its live Kubernetes read-back was
recorded and the public command independently observed its retirement. The
subsequent node-removal phase returned
`NodeRemoveActionResultRefused NodeRemoveResultUnobservable` with a
durable removal attempt and no result. Independent Docker inspection still
found the original node `68fec6d8c89cb4cd246be1fbe261a9faa3b37c78034cb536c4246c46f32b0598`
running. The primary operation remains incomplete. Output and preceding
read-only status are `.build/phase1-retained-recovery-20261124.log` and
`.build/phase1-retained-status-before-20261124.log`. Preserve the exact
attempt and successor chain. The new failure needs a bounded offline
reproducer and a supported recovery disposition before a further live
removal attempt.

The slow-settlement integration control reproduced the same refusal without
a real Docker effect (`.build/phase1-node-removal-baseline-20261124.log`).
It introduces a 1.3-second settlement check only after the durable attempt
is written. The implementation now brackets the local result read and
receipt write with physical admission checks, keeping the repeated
predecessor verification outside nested record reads. The same fixture is
being rerun. This change applies to a fresh removal attempt and leaves the
already recorded, unconfirmed live attempt open for exact recovery.

Decision (2026-11-24): node removal can attempt one linked retry only after
the held operation has re-observed its original removal attempt, a missing
result, the same daemon, and the exact still-present container. Both attempts
target the same full Docker container ID. The retry must have its own durable
attempt and result and must never overwrite or recode the original attempt.
Observed absence and an unknown provider state need the existing independent
absence path. This follows the intent and observation requirements in
[lifecycle.md:20](../documents/engineering/lifecycle.md#identity-intent-and-observations).

The fresh-removal regression passed with the same injected delay
(`.build/phase1-node-removal-fixed-20261124.log`). The linked-retry fixture
then passed with an independent positive Docker inventory and one recorded
204 response under the distinct retry attempt. It preserved the original
missing result and refused both a second retry and an invalid original
result, with no extra simulated DELETE
(`.build/phase1-node-retry-integration-20261124.log`). A new public
`control delete --yes` on the same retained operation is in progress with
binary SHA-256
`e9dcf3d1d99b5f827f968ab3ae10086785ad2491e14f0e6958635a8450907c13`.
The live retry returned a recorded node 204, then timed out closing the
volume step before it reached the network. The bound volume journal also
records a 204. Independent Docker inspections returned no such container
for the exact old ID and no such volume for
`prodbox-t-run-7ae426bc5f920fb9fb91a516f104e4f7-var-54f9a9f687914eaafa45d34d34646c4e-e69453b00acc4c3133b7e9730a381844`.
The exact network
`5ba4194ec86a4afba110455b3e203a6eaea6ca42bab11ad08572e5b36846d910`
remains present. Output is `.build/phase1-retained-node-retry-20261124.log`.
The root, removal records and publication metadata are retained. These
point observations do not establish terminal Phase 1 cleanup. A
continuation must settle the volume and the exact remaining network with
the control API no longer available. No hand cleanup was used.

The read-only `control lifecycle-status` call now reports recovery required
because it cannot observe the Authority deployment
(`.build/phase1-retained-admission-after-20261124.log`). The original
node and volume receipts cannot supply that admission decision. A
resumable teardown needs a durable, scoped admission checkpoint and a
fence against later Authority admission before node removal, or a supported
recovery of the original authority under the same identity. An absent
API or a missing Authority directory does not establish NeverAdmitted
under [lifecycle.md:32](../documents/engineering/lifecycle.md#identity-intent-and-observations).

The volume implementation now brackets the removal record and receipt
reads with the held admission. If the bounded transport wrapper still
returns incomplete, a separate check under the same operation can require
the exact bound 204 receipt and a matching-daemon observation of the
derived volume before deciding whether to continue. The focused integration
fixture passed with a 900 ms check after the simulated removal response,
including retained node retry and refusal controls
(`.build/phase1-volume-closing-integration-20261124.log`). The public binary
used by the fixture has SHA-256
`8f9f6e8f7e674b6584c23fe6b16fa2a3d47a9daabce51c91584dd455193da835`.
This does not establish a fresh admission decision for the earlier retained
operation. The retained network independently reports zero endpoints. Its
recorded identity and absence of attached endpoints scope the residue and
do not stand in for admission.

A read-only inventory enumerated the nine publication paths derived from
the retained operation and its cleanup, verifier, and six successor
identities. Each held birth, send, submission, and retirement metadata.
The two published input payload names were absent from those directories.
The user manager returned no units matching the exact operation ID pattern.
The inventory records path contents and matched unit names, with no implied
result for a static slice or an unrelated fixture. Logs are
`.build/phase1-retained-publications-20261124.log` and
`.build/phase1-retained-family-units-20261124.log`. The metadata remains
available to the retained operation.

The canonical gate stopped at existing Haskell policy violations before the
warning-clean build or suites (`.build/phase1-canonical-20261124.log`).
The repairs in progress name the flagged callbacks, route mutation status
through the existing test runner, and document the kind entrypoint's
kind-specific publication paths at its wire-fidelity exemption. The worker
identity remains bound to its exact request and the corresponding
publication namespace.
The rerun reached the formatter, which reported inherited drift across the
kind and qualification sources. The canonical formatter is being applied
before another gate run. An earlier gate launch overlapped a binary copy and
failed with `Text file busy`; it supplied no check result.

The repository-wide pinned formatter and documentation check subsequently
passed. All 74 focused preparation tests passed on the formatted recovery
build. The mutation manifest check first refused an inherited stale
overlapping-root preimage hash. The intervening DeploymentScope change
exported the project-anchor accessor and left the mutation site unchanged.
Refreshing that binding and the two Delete bindings restored the focused
manifest check. The owner-first external-family variant has since been
registered with a designated unchanged assertion. Isolated mutation
execution and classification still need evidence.
The focused manifest and owner-family assertion both passed after the
registration (`.build/phase1-owner-mutation-validation-corrected-20261124.log`).
The repository linter identified four inherited hints. After correcting the
three affected files, the same pinned linter found no hints in those files.
The focused scenario-evidence and wire-fidelity groups passed 42 and 17
tests respectively. The corrected `prodbox dev check` completed with exit
zero. The warning-clean build passed, and the gated suites passed 10,209
general, 27 Authority admission, 35 control-plane authentication, and 935
authenticated transport tests. Binary SHA-256:
`f4b1beb5c39d268757f2ad97e8bafa201ffc7830ff717a1fed987bb4e45fe5fb`.
Output is `.build/phase1-canonical-after-hints-20261124.log`. The live
cleanup, full real acceptance set, and isolated source-mutation evidence
remain open.

Early teardown admission checkpoint (2026-11-24). Public `control delete`
records a fresh local `NeverAdmitted` decision for the exact owner-family
test operation under its scope lease. The record binds the selected
configuration, root identity, generation, runtime socket and operation.
The supported Authority deployment entrypoint takes the same lease and
refuses an existing or unobservable fence. Before it applies the Authority,
it confirms and synchronizes the retained journal directory. On resume,
delete requires the same root and owner operation and observed absence of
both the retained Authority journal and the legacy local journal root. A
dangling link at either location refuses. These conditions follow the early
removal boundary and the retained identity and
observation rules. [Control plane](../documents/engineering/control_plane.md#recovery-and-local-removal)
[Lifecycle](../documents/engineering/lifecycle.md#identity-intent-and-observations)

The original live operation `e69453b00acc4c3133b7e9730a381844` predates the
checkpoint. Its missing API cannot authorize writing one. The exact recorded
network still has zero endpoints and remains in place. Positive-control-backed
node absence for a node lost outside supported removal, independent
control-container retirement and the real interruption acceptance remain open.

Read-back after an owned removal (2026-11-24). The supported delete path
requires a bound successful node removal receipt and the recorded positive
pre-removal control, two agreeing scoped Docker inventories, and a framed
not-found response naming the exact node from the recorded daemon before
continuing. It checks the bound volume receipt against a separate exact
volume observation. A network removal receipt requires both the exact-ID
inventory with Docker's built-in bridge as its positive control and a
separate scoped name inventory. These read-backs also handle a lost wrapper
result when the exact receipt was already committed. The Docker 29.9.2
read-only probe of the old node returned the expected 404 body
(`.build/phase1-retained-node-http-observation-20261124.log`). That point
observation leaves the earlier admission and network unresolved.

The warning-clean executable, unit and integration builds passed after
removing an unused import from the first build. The rebuilt public command
then refused `control delete --yes` for the earlier operation before any
removal. Independent network inspections before and after returned the same
ID and zero endpoints. The admission file remained absent. This is the
real missing-admission negative case only. The logs are
`.build/phase1-retained-public-admission-refusal-20261124.log` and
`.build/phase1-retained-network-{before,after}-refusal-20261124.log`.
Binary SHA-256:
`e0bec365b3bf5f73fb79baec1a4340ceaafff249a4a529b68fb744800cb6933a`.
All 75 preparation and 42 evidence tests passed on that source. The
admission fixture covered scope-lease contention, an unavailable API
before admission, API loss after the checkpoint, a dangling legacy journal,
retained Authority state, a wrong-purpose record, and a dangling checkpoint.
The focused connected-Docker case accepted the exact 404 response and
refused a foreign ID, an empty response body, and a successful HTTP status.
All 60 connected Docker integration tests passed. The formatter, HLint,
documentation check and `git diff --check` passed.

A bounded local canary started at 13:00 Toronto time with fresh scope
`run-f6e0119d7aaa44d63aa19bbbe846a4e5` and the same executable. Public
`config setup --fresh-test` and both `control import-artifact` calls
completed using the declared node archive and kind tool from the earlier
scope. The canary runs public reconcile, status, delete and, after a
successful first delete, a second delete following API loss. Reconcile
and each delete have a 12-minute command limit. The test uses one local
kind environment and no AWS resources. Its log is
`.build/phase1-receipt-canary-20261124.log`. This canary does not exercise a
deliberate interruption or two-environment acceptance.

The canary stopped at operation `4678a52fbe9517219ede48b1d362f0d4` before
network, volume or node creation. The real managed family retired with
controller exit 1 and no durable family result. The image transport record
has a 200 reply with one stream message, and independent Docker inspect
found the exact configuration image ID without tags. These observations
leave the image-read-back and family-result closing boundary unresolved.
Public delete and repeat both exited zero with no node, volume or network
create intent. Independent scoped Docker queries returned no node or
network match, the exact user-manager unit query returned no units, and the
retirement metadata remained while its published input payloads were absent.
There was no API to interrupt. This is a real pre-node failure and teardown
of its attempted scope, with the image and operation records retained.
Review the image/result boundary with a bounded reproducer before another
live canary. The independent inventory and terminal controller observation
are in `.build/phase1-receipt-canary-independent-20261124.log`. The public
archive inspection matched the selected manifest, blob configuration ID and
configuration image on the daemon. The manifest reference was unobservable.
That evidence is in `.build/phase1-receipt-canary-image-20261124.log`.

A bounded contention reproducer held the recovered scope lease across the
same family-result writer. The dispatcher's one-shot lease acquisition
returned `KindLeaseBusy` and wrote no result. The existing bounded retry
acquired the lease after release and independently reread the exact result.
The public completion observer also takes this lease during its retirement
poll. This establishes a code-path counterexample compatible with the live
missing result. The live invocation's exact refusal remains unobserved.
Output is `.build/phase1-family-result-contention-20261124.log`. The fixture
source SHA-256 is
`a8115afad070602d696ea9644749bebf74d311e38522ba2461448e44165dd3d9` and its
binary SHA-256 is
`d0b73be34d50e84768805ecc9a22113a23e0ba470605494723f3a48a2f963631`.

The admission and removal-read-back build above passed `prodbox dev check`
with 10,210 general, 27 Authority admission, 35 authentication, and 935
authenticated transport tests. The executable digest remained
`e0bec365b3bf5f73fb79baec1a4340ceaafff249a4a529b68fb744800cb6933a`.
The log is `.build/phase1-teardown-canonical-20261124.log`. This result
precedes the following dispatcher change and does not close live acceptance.

The dispatcher now uses the existing bounded operation lease retry while
recording its summary. The original request's outer deadline and ten-second
recording limit still bound the write. Only pre-callback lease contention
retries, preserving the single write and its exact read-back. A controlled
regression now drives this actual writer behind a temporarily held scope
lease. The test refused an expired deadline, waited through temporary
contention, and independently reread the one recorded result. The
warning-clean build, formatter, HLint, documentation check and
`git diff --check` passed. Binary SHA-256:
`e5bdf4950ecebb0a2610d795fc47dfdbbeb15df2e26594b94047dc953d95e14a`.
The focused result is `.build/phase1-family-result-bounded-test-20261124.log`.
A second fresh local canary is in progress with this build and the same
artifact coordinates. It compares exact scoped Docker inventories before
and after public delete, then checks repeated delete if the first returns
success. Scope `run-6ae661747edbf3e87c27e46e34824b80` and operation
`f0b7d22a042e45a7acae2735aa720b78` have recorded image, network, node volume,
node create and node start results. Its log is
`.build/phase1-bounded-result-canary-20261124.log`.
All 76 current preparation tests passed
(`.build/phase1-family-result-bounded-preparation-20261124.log`).

The second canary reached Kubernetes readiness. An independent `kubectl`
read returned `ok` for `/readyz` and Ready for the exact selected node
(`.build/phase1-bounded-result-canary-ready-20261124.log`). `control reconcile`
exited 1 with a durable `FamilyPostProbeFailed` result and completed
worker, parent, input and post-lease observations. The probe namespace UID
was recorded and its removal receipt matched the same UID. The primary
network-policy enforcement failure remains open.

`control delete --yes` exited zero at 13:35:40 and repeat delete exited
zero at 13:35:43 with the API unavailable. The repeated command re-observed
absence of the recorded node, named volume and network. Independent exact
Docker API reads returned 404 for all three resources, with a visible
built-in bridge positive control. The scope root, admission checkpoint,
obsolete kubeconfig and operation evidence remain. The exact unit query
returned no units and the publication metadata remains without its input
payloads. See `.build/phase1-bounded-result-canary-independent-20261124.log`.
This validates owned resource teardown and repeat on one real scope. The
interruption before teardown completion, network-policy enforcement,
same-root recreation, the earlier unresolved network and mutation closure
still prevent Phase 1 completion.

Probe timing review (2026-11-24). The canary retained only the aggregate
probe failure after the namespace was created and removed. The probe
previously read both short-lived client logs after a fixed nine-second
delay, which can expire while a client is still scheduling or running.
The public adapter now waits up to 30 seconds for both exact Pods to reach
`Succeeded` before reading their logs. A pending or failed wait yields an
unobservable connection result and follows the existing UID-bound cleanup.
The controlled regression covers a delayed success, the allowed and denied
observations, and a timeout that skips client log reads. This addresses a
timing counterexample compatible with the canary. It does not identify
that live invocation's primary probe failure.

The warning-clean build and targeted client-wait regression passed. The
binary SHA-256 is
`a5e88db7c53c1889b4559c3a6b747da2ee89b717c5da7618a4184d673470199d`.
A third bounded local canary is in progress with a separate read-only
observer of exact Pod phases and result tokens in its operation-bound probe
namespace. Its logs are `.build/phase1-probe-wait-canary-20261124.log` and
`.build/phase1-probe-wait-canary-20261124-pods.log`.

The third canary, scope `run-962e83599fea5b22c3335ed84242516a` and operation
`336538a767659c3b0e0ad544cf104dc1`, reached a Running probe server and both
baseline Pods `Succeeded`. Each emitted `OBSERVER_UNAVAILABLE`. The
aggregate reconcile result was again `FamilyPostProbeFailed`. The exact
helper image's upstream build stages Bash as `sh`, `rm`, and `mkdir` into
the distroless runtime. It does not stage the probe's required `timeout`
executable. The Pod observer distinguishes this dependency problem from
unfinished clients. [Pinned helper image build](https://raw.githubusercontent.com/kubernetes-sigs/kind/7181c60a/images/local-path-helper/Dockerfile)

Public delete and repeat both returned zero and the scoped inventories
were empty after teardown. The canary command remained unsuccessful
because the primary network-policy probe failed. All 77 current
preparation tests passed. The next change must run a finite connection
observer with the helper's actual executable set and preserve the
distinction between denial and observer failure.

The probe client now uses Bash builtins from the same pinned helper image.
The child acknowledges the connection attempt and reports a successful or
refused socket open. The parent waits within its own deadline and counts a
timed connection as refused only after observing cancellation of that exact
child. Unexpected replies and unconfirmed cancellation are unobservable.
The 12-second Pod deadline remains an independent upper bound on a wedged
client. A loopback reproducer with an empty command search path observed a
successful connection, an immediate refusal and a five-second deadline
with a full accept queue. The public binary SHA-256 is
`5deb9521f1d92aa8d0b99c5eed80453bf843b6019f1cfb8ded416bab097e203d`.
The focused real follow-up used separate observer logs
`.build/phase1-probe-bash-canary-20261124.log` and
`.build/phase1-probe-bash-canary-20261124-pods.log`.

The real follow-up completed in scope `run-13efef0da3f956807982ab5d8f938e02`
and operation `072cbe3d94c060ea134a77e58b49a658`. The public command exited
zero with `Network policy enforcement: PROVEN`. The independent observer
recorded both baseline connections, allowed/denied connections under the
policy, and both connections restored after removal. Public delete and
repeat both exited zero with the API gone by the repeat. Independent
exact Docker requests returned 404 for the node, named volume and network
with a visible bridge control. The exact manager-unit inventory was empty
and the retired publication still held metadata without input payloads.
The retained root, configuration, image and operation records remain.
See `.build/phase1-probe-bash-canary-independent-20261124.log`.

The warning-clean executable, unit and integration builds passed. All 77
preparation tests and both Bash client integration tests passed
(`.build/phase1-probe-bash-preparation-20261124.log` and
`.build/phase1-probe-bash-loopback-final-20261124.log`). This canary proves
one real scoped reconcile, policy probe, owned teardown and repeat. It
does not exercise two simultaneous scopes, deliberate interruption before
teardown completion, same-root recreation, or source mutation kills.

Same-root recreation preparation (2026-11-24). The exact recorded node,
volume and network absence checks now live in their resource read-back
modules. Public delete still supplies its held operation and retirement
checks. Recreation can reuse the same observations before archiving the
old eligibility checkpoint, operation records and kubeconfig. The archive
now has a public owner-family path for an exact operation with a matching
teardown checkpoint, independently retired family, known original probe
cleanup, and confirmed resource absence. It rechecks the resource and
admission observations under the scope lease before moving only the known
operation records and credential. The move uses no-overwrite renames and
keeps the Authority fence until after the former intent is durably moved.
A reserved history directory fences an incomplete move. Its supported
recovery path and live same-root acceptance are still pending.

The shared read-back build passed a real repeat delete and 42 evidence
tests. After archive activation, the warning-clean build and the controlled
refusals for admission without settled removal and a reserved archive both
passed. The archive test executable SHA-256 is
`57c787be0330a0a768bdb32da31ea8e6b0e7bacb306218f49035eb5085639c41`.
The real same-root canary ran on the already cleaned scope from
operation `072cbe3d94c060ea134a77e58b49a658`. The observer checks the same
root and generation, unchanged artifact digests, retired kubeconfig inode,
a different operation ID and independent readiness. It then follows public
cleanup for any new operation. Output is
`.build/phase1-same-root-canary-20261124.log`.

The canary verified the old archive and unchanged root, generation,
artifact digests and archived credential inode. The new operation
`8f6ab513fbdf3e60ecd8bef6d961522f` recorded a network intent and no attempt.
Reconcile exited 1 with `FamilyPostNetworkFailed`. Public cleanup also
exited 1, even though independent inventories showed no matching node,
named volume or network. This is verified archive activation and a failed
recreation. The evidence runner now requires a successful replacement
reconcile and the exact original intent inode in the old operation's
archive, with a different live operation ID. An incomplete response or an
arbitrary history entry can no longer satisfy the recreation case.

The managed prerequisite path now uses the proven bounded lease retry
at each operation boundary under the original work deadline. A retry is
eligible only when the lease refused before entering the callback. The
same-root canary's precise pre-attempt refusal is unobserved. Delete also
now distinguishes a bound network intent with no recorded attempt or
results. It checks the selected Docker daemon and checks the scoped name
inventory with Docker's built-in bridge as a positive control before
reporting that no network was created.

Recovered the `8f6ab513fbdf3e60ecd8bef6d961522f` teardown on the same
retained root with the public `control delete --yes`. The initial and
repeated calls exited 0. Independent Docker CLI observations before and
after each pair saw the built-in bridge and returned no matching network,
node or volume. The original admission and network intent remained present
and no network attempt or removal records appeared. Evidence
`.build/phase1-unused-network-cleanup-20261124.log` has SHA-256
`6e7c19e5a7991dbaaa57f14bd8d5efaf104b53f65bc40a0c7bcfc3b105382d88`;
operator SHA-256
`5025a441563841ec9bbbaa47c18d334f40f39463c5b4fe1528072b47aa8ef4f1`.
The pre-attempt operation is settled for teardown. The replacement
cluster, host marker round-trip and recreation from this early-stop
state remain unproven.

The 78 preparation tests passed, including a held-lease case that
observes no admission callback before release and no provider record
after refusal. All 42 evidence comparison tests passed. The connected
Docker case rejected an invisible bridge and distinguished a positive
bridge with an empty scoped inventory from a positive bridge with a
visible scoped network. Logs are
`.build/phase1-recreation-preparation-20261124.log`,
`.build/phase1-recreation-evidence-20261124.log` and
`.build/phase1-network-name-controlled-20261124.log`. The broader
connected-suite run overlapped source edits and three tests failed while
rebuilding the operator from intermediate source. Rerun that suite
against the completed slice before using it as current evidence.

Decision (2026-11-24): exercise deliberate interruption and simultaneous
local scopes in the registered Phase 1 workflow, following
[A01-01](acceptance_cases.md) and the requirement for observations to bind
the actual operation in
[the plan standards](development_plan_standards.md#evidence-and-live-campaigns).
The runner now binds the reports to the observed owner-family operation,
and the recreation report to the replacement operation when observed.
The second scope uses the public setup, imports, reconcile and delete.
Its observer requires both Kubernetes Nodes to be Ready at the same
time, distinct Docker node IDs, different expected contexts and API
ports, and each node's exact retained mount. After the sibling delete it
checks sibling absence and the first node's unchanged identity and
readiness. The interruption schedule stops the bounded public delete
after a valid node removal receipt, then requires a bound Docker 404 and
an independently visible original volume before resuming and repeating
the same scoped teardown. A missing interruption observation fails
lifecycle acceptance.

The registered `test run phase-01` run at 14:34–14:49 America/Toronto
reported `EvidenceChecksSatisfied` for A01-01, A01-02, A01-03, A01-04 and
A01-06. Its operator SHA-256 is
`2d129fca369db5d37119829d9e14b546fb7f6caad9fd652d5f441f3d9772274e`
and the source manifest SHA-256 is
`a3e7ab3a7394ba93d2b7c8658abf97701c4052fcb1cf19acbea6dc5bc0e9f134`
on `79c1807e0fd9869a0e5e6c71847496890def9c20`. The seven case reports
are in `.build/scenario-evidence/22be3e3e2e12f5e5408f8108c75013ee/`.
The command log `.build/phase1-registered-lifecycle-20261124.log` has
SHA-256 `2b1a3d746529d37e2c1ffe0b45b65638d7236e9d355682afc593883b354efa0e`.

The first scope was `run-d01b37d751edf9dc76a37e6a3cff685c`, operation
`e88ed0fe0dfc4163f2b67fe13aa20e61`. The simultaneous sibling was
`run-f0c9bbe80ac0b30b811341bcf18b7175`, operation
`5478d6fa13c3178e08baba824ef650ed`. The independent observation at
14:42:05 saw both Kubernetes Nodes Ready, separate Docker node IDs, exact
retained mounts and API endpoints on ports 53114 and 58489. After sibling
cleanup the registered observer still saw the first node Ready with its
original ID. The public runner confirmed it interrupted the first delete.
The independent observation at 14:44:18 captured the first operation's
durable admission and a node-removal receipt with status 204. Docker
returned 404 for that exact node and 200 twice for its exact original
volume, before a volume-removal receipt appeared. Public resume and
repeat completed. Another observer read exact 404s for the original node,
volume and network with a positive built-in bridge.

Reconcile moved the first intent into its exact archive and created
replacement operation `1fadcce423dcbee55da75e50cd04d466`. The registered
reader Pods returned both original markers. The second claim was Bound
to `pv-a01-02` by name and the validator accepted the replacement report.
The outer host observer verified both marker digests after final public
delete, and the root remained device:inode `2050:3161856` at generation
`436f4e943783a1e740ba358f8106ac2d`. Exact node, volume and network 404s
and the matching worker-unit observations are in
`.build/phase1-registered-sibling-removal-final-20261124.log`,
`.build/phase1-registered-original-removal-20261124.log` and
`.build/phase1-registered-replacement-removal-20261124.log`.
The simultaneous and interruption observers are
`.build/phase1-registered-scope-ready-observer-20261124.log` and
`.build/phase1-registered-teardown-observer-20261124.log`.
The additional replacement observer missed the interval when both reader
Pods were observable. The validator used the registered Pod logs, exact
host reads and the archived inode, and the outer observer confirmed the
retained marker hashes independently after removal.

The command exited 1. A01-05 had a missing slice sample even though the
64 MiB Pod completed and the 16 MiB Pod was OOMKilled. The sampler still
used a fixed UID and the retired `prodboxkind.slice` path. It now resolves
the manager path from the effective UID and the active slice and controller
names through
[HostOperationFamily.hs](../src/Prodbox/Subprocess/HostOperationFamily.hs).
It requires the exact controller cgroup to survive the kernel counter read.
The capacity case requires that sample for success. A01-08 imported and
checked the inputs, created and replaced the node, and confirmed cleanup.
The pinned image was already present at the start, so clean-image
acceptance remains open. The report now records that actual observation
on both sides instead of claiming the image was absent.

Mutation retirement work (2026-11-24): all seven exact unmodified Phase 1
assertions were uniquely selected and passed
(`.build/phase1-reviewed-baselines-20261124.log`). The active Phase 1
catalog now runs those mutations and the executor calibrations.
Later-phase declarations remain available to campaign status readers.
For an observed command exit, the outer executor now requires the full
container ID from the bound receipt and an independent Docker 404 from
the same daemon before it advances to the next stage. Label inventory
remains diagnostic when exact retirement is unconfirmed. Validation of
that read-back, prepared offline dependencies, workspace cleanup and
compiled mutation results is pending.

The real mutation canary on operator SHA-256
`fdbd47519f0dbeb1cfe3ae2ecc4752a50da1dbb448f8e1e68a0e4660ed1858f1`
advanced through the isolation stage and recorded independent retirement
for the isolation and baseline-build containers. Exact outer Docker reads
returned 404 for both with a positive bridge. The baseline exited 1 in
its empty isolated Cabal directory while attempting to resolve the
Hackage index. The campaign `1773464124434203` remains Inconclusive
with its workspace retained. Evidence is
`.build/phase1-exact-mutation-retirement-live-20261124.log` and
`.build/phase1-exact-mutation-retirement-independent-20261124.log`.
A separate offline dry run with no repositories could not resolve
`yaml`. Copying only the public Hackage index and its metadata to a
private scratch cache was sufficient for the dry-run solver. Artifact
custody for the selected compiled dependencies and full workspace
retirement remain open.

The real capacity rerun with that same operator stopped at
`69e451f63d4caf97cf9c1c497cdd4c44` in
`run-74f4ec1a1eb989a429ddb87ed61023ec`. The node proposal exists and
the record set lacks a node attempt or result. The family summary
reported `FamilyWorkerUnconfirmed` before post-worker work. Public
delete retained the recorded volume and network because it could not
prove the node disposition. No provider mutations were attempted by hand.
The exact node name returned Docker 404. The bound network
`e76a77b24ca82afa2ed7d807769bb2f7bfa82562d7858dba0c9d6b92e237baba`
and generation-bound volume remained visible. See
`.build/phase1-registered-capacity-20261124.log`.

Decision (2026-11-24): follow the same settlement boundary for a
never-attempted node proposal as for a never-attempted network, under
[independent postcondition requirements](development_plan_standards.md#real-acceptance-requirements).
The node result reader requires an attempt, so it cannot distinguish this
early state on its own. Delete now checks the bound attempt reader and
the exact result path under its held lease. It requires the authenticated
daemon's matching name 404 and an empty scoped label inventory before
advancing to volume or network. The managed worker admission, root
handoff and post-worker paths also use the deadline-bounded lease retry.
The original worker refusal is still imprecise. Live capacity measurement
remains open.

The rebuilt public `control delete --yes` and its repeat exited 0 for
`69e451f63d4caf97cf9c1c497cdd4c44`. The admission inode was unchanged
and no node attempt, create result or removal records were written.
Docker's exact name read returned 404 before and after, with the bridge
visible. The recorded network and volume each returned 200 before and
404 after, alongside bound status 204 removal receipts. The operator
SHA-256 is
`608fd7dabc517fe7a4fecc4fe7bdcca754592a5a846c58a92cfdf05b2b3ba669`.
The log `.build/phase1-unattempted-node-cleanup-20261124.log` has SHA-256
`11082eebba6ec4518a30f6d6f43916c2754b4be4860542746af705428e636ce8`.
The exact response fixture rejected wrong subjects, malformed 404s and
non-404 responses when querying by ID and by the scoped name. The
admission regression also refused a checkpoint changed to another
operation without changing the current owner. The 78 preparation and 42
evidence tests passed on this snapshot.

Offline dependency custody narrowed further. A private curated copy of
the public index plus the 171 installed units for the selected test and
Cabal's setup closure let `cabal build --offline --dry-run` select only
the local library and unit-test target for rebuilding. The experiment
used a clean command environment and a scratch store, with no home cache
mounted into a mutation child. It exercised dependency planning only.
Production integration, content custody and isolated compilation remain
open.

Capacity sampler follow-up (2026-11-24): the independent reader found the
exact controller cgroup for `44bd7cec80b2c3ba5bad8aa7b53bfc78`. The shared
slice reported peak memory 445403136 of 805306368 bytes and peak 29 of 96
tasks. Reconcile exited 1 before any provider attempt; the recorded summary
was `FamilyParentKernelUnconfirmed` and `FamilyInputChanged`. Public
delete and repeat exited 0 with empty scoped Docker inventories.
The connected integration fixtures were running during that canary.
The shared placement verifier requires only the controller and its exact
children in the slice, so overlapping fixtures can invalidate both the
placement and aggregate measurements. The revised scenario sampler
requires the expected cgroup names on both sides of the counter reads.
The recorded measurement locates the live cgroup and leaves A01-05 open.
Run placement validation serially with the manager-backed fixtures.
Evidence is `.build/phase1-bound-cgroup-canary-20261124.log` and
`.build/phase1-bound-cgroup-observer-20261124.log`.

The 61-case connected run completed with one failure in the legacy
preflight fixture. Selecting the retry policy forced legacy launch
capabilities before preflight validation. The constructor now defers
those capabilities until launch. The exact integration case passed on
rerun (`.build/phase1-legacy-preflight-regression-20261124.log`).

Private mutation dependencies (2026-11-24): the public runner now selects
the canonical unit test and Cabal setup closure from the local build plan.
It copies the exact installed package entries, package registrations and
public index files into a new private campaign directory using held
descriptors and bounded copies. It verifies source and campaign identity
around preparation. The worker receives the copied store and index as
read-only mounts and a separate writable output. Build command identity
is preserved for older campaign records.

The real campaign `1774771874504831` began an offline unmodified baseline
compile with operator SHA-256
`ce64e8a4bf05b913871b7d18d97d1e9bc7644a2d6af8d471db0ebf86f6f24121`.
The unmodified Docker observer confirmed network mode `none`, non-root
UID/GID, read-only dependency and source mounts, and one writable output
mount for the bound baseline container. Three inherited proxy variables
had empty values. The runner now starts the case shell with an explicit
environment. The active campaign snapshot predates that change. Evidence
is `.build/phase1-private-dependencies-live-20261124.log` and
`.build/phase1-private-dependencies-isolated-observer-20261124.log`.

The campaign compiled the unmodified baseline offline, passed its selected
assertion, and compiled the reviewed M01 mutation. The rebuilt test
executable had SHA-256
`4f7834aea6ce3e79a55160708e834f15ff8985833fc07ac7205746d8d0b37753`.
The selected mutant test returned exactly
`TestAssertionFailures 1 ["context.rejects_root_alias"]`. An independent
Docker observer read a 404 for each of the seven receipt-bound containers
and a 200 for the bridge. This older build reported the provisional kill
as `MutationInconclusive` and retained the workspace because retirement
was unconfirmed. The command log SHA-256 is
`4cff4ed2253724c4927e1e9ec3860975adb949c25599b9e930e3855a8059467e`.
The independent evidence is
`.build/phase1-private-dependencies-exact-retirement-20261124.log`.

The executor now reads compiler diagnostics and binary bytes through
bounded no-follow descriptors on the held output mount. A case can
qualify after exact worker retirement, matched outcome, bounded
unchanged-inventory cleanup and a synced case receipt. The invalid
calibration checks a parser diagnostic for its target file. The timeout
calibration checks the selected test's typed timeout. Actual compiled
mutation outcomes and the revised workspace retirement remain under
validation.

Decision (2026-11-24) for recreation after a pre-node stop. Follow the
same retained-root and independent read-back contract in
[control_plane.md](../documents/engineering/control_plane.md#recovery-and-local-removal).
An owner-family operation with a bound node proposal can pass archive
admission after exact volume and network removal, a verified missing node
attempt, and an independent Docker name and label check. The probe and
cleanup publications must be empty and the retained kubeconfig must be
absent. A completed cluster still requires its retired credential. On
2026-11-24 the public branch archived `69e451f63d4caf97cf9c1c497cdd4c44`
and created `3640d3a06bfc984900283a3f55730f81` on the same root and
generation. It retained the original intent inode and artifact digests.
The replacement returned Kubernetes `/readyz` and verified network policy.
Public delete exited zero. Exact independent node, volume and network reads
returned 404, the bridge returned 200, and the operation's worker-unit
inventory was empty. Operator SHA-256
`67853790c3e06238964a6e761f5a505e3f211a8e48c6e9ba46a22a149352293b`.
Evidence is `.build/phase1-pre-node-archive-20261124.log` and
`.build/phase1-pre-node-archive-exact-removal-20261124.log`.

Serial capacity validation (2026-11-24). The registered run at
15:25–15:43 America/Toronto passed A01-01, A01-02, A01-03, A01-04, A01-05
and A01-06 with operator SHA-256
`3e4b68fe3df45895d1e19eced2b493aedbaffdbe995fd496d865c51ac146b3a4`
and source manifest SHA-256
`eeb32b713e4625e426060f74c1b70916a3e437ba321ea5b463470e3964d4aa9a`.
The independent cgroup and registered case agreed on a peak of
452308992 of 805306368 bytes and 34 of 96 tasks for
`38900b153328d617fafbda2b751f91b1`. The 64 MiB Pod completed and the
16 MiB case was OOMKilled. The unchanged insufficient-capacity control
and quota observations passed. The run stopped the first teardown after
exact node removal, resumed it and verified the repeat. Both scopes
coexisted. The outer Kubernetes observer read both markers from
replacement operation `ae506c3db9e42e06fcf15fdf1fafc702` and confirmed
the PVC bound to `pv-a01-02`. Exact Docker read-back returned 404 for
the node, volume and network for all three operations, with a positive
bridge. Their worker-unit listings were empty and both host marker
hashes survived final teardown.

A01-08 reported `EvidenceChecksUnmet` for the single preloaded-image
observation. All other A01-08 observations matched and cleanup was
confirmed. The command exited 1. The reports are in
`.build/scenario-evidence/47cdc6e2232f41ea45e829dd9092caba/`. The command
log `.build/phase1-registered-serial-capacity-20261124.log` has SHA-256
`04e44098c24ef3727ad92dc25e1017cd797465d54092928172b8305cd0a19761`.
Independent logs are `.build/phase1-registered-serial-cgroup-observer-20261124.log`,
`.build/phase1-registered-serial-marker-observer-20261124.log` and
`.build/phase1-registered-serial-removal-20261124.log`.

Canonical validation (2026-11-24). The pre-node archive canary operator
completed `prodbox dev check` with 10,214 main unit tests and gated suites
of 27, 35 and 935 tests. The log
`.build/phase1-current-canonical-20261124.log` has SHA-256
`b7675f1bb30265d373a0d495107c03b64b87d2facc641316e3234053e309fc7b`.
This run preceded the archive transaction, quota and socket changes.

Isolated mutation recheck (2026-11-24). Campaign `1776734605361095` used
the same operator and source manifest
`a9b95bc920f3e98466671300e3c9442f2496be89813febad93aa3b24ab5cc4fd`.
The baseline compiled offline to an owner-private executable with SHA-256
`dd2ecbb2ef4d6361f5caf4b8b1730519a66954a2875e2463082d8f8c26852239`.
Cabal created `0755` intermediate directories within the `0700` output
root. The member reader refused those directories, so baseline selection was
unbound and the result was `MutationInconclusive`. All three exact workers
returned 404 with a 200 bridge control. The independently observed worker
had network mode `none`, non-root UID/GID, read-only source and dependency
mounts and the five declared environment variables. Evidence is
`.build/phase1-qualified-mutation-20261124.log`,
`.build/phase1-qualified-mutation-running-observer-20261124.log` and
`.build/phase1-inconclusive-mutation-permissions-20261124.log`.

Decision (2026-11-24) for fixed mutation storage. The contract requires a
disk bound during execution. A disposable Docker protocol fixture rejected
a write beyond the shared tmpfs limit and allowed the outer process to read
the result through its read-only keeper. The native adapter fixture observed
the intended 3 GiB capacity and 32,768 inodes. The keeper and exact volume
returned 404 after cleanup. The executor now takes one immutable campaign
snapshot, mounts one bounded volume per case, and requires exact keeper,
volume and workspace retirement. The member reader accepts `0755`
directories under the private root and refuses group-writable intermediates.
The integrated command needs validation. See [mutation execution rules](mutation_cases.md#execution-and-isolation).

Decision (2026-11-24) for interrupted archival. Persist a scope-bound
inventory before moving any retired records. Lease-held recovery restores
exact original inodes from incomplete staging and reruns teardown
observations. The final archive appears in one rename after complete staging
read-back. Authority deployment checks the staging fence. A filesystem
interruption fixture restored the original inodes, refused a foreign staged
entry, and completed publication. Public-path recovery and the earlier
network-proposal-only root are queued for validation.
See [recovery and local removal](../documents/engineering/control_plane.md#recovery-and-local-removal).

Clean-runtime preflight (2026-11-24). A disposable rootless daemon reported
Docker ID `94e65c97-bac6-4218-be53-7b3bce1d4c63`, systemd cgroup v2 and
an empty image inventory before shutting down. The shell fixture probed the
runtime only. The fresh public scenario accepts an explicit absolute Unix
socket with `--runtime-socket`. Actual A01-08 validation is pending.
Evidence is `.build/phase1-clean-engine-protocol-retry-20261124.log`.

Explicit clean-runtime run (2026-11-24). Operator SHA-256
`5c59ef7ba66307dd18875bc45e02b98cfa42f835ebfeab4c89d6606c8d4a7360`
selected Docker daemon `66b3eb1b-129b-4adf-8749-49fe717e2263`.
The independent pinned image read changed from 404 to 200 on that daemon.
Operation `ded644f0aab136b041a9a41693d1bbd8` stopped before the node
create attempt. Supported teardown confirmed scoped node absence and
removed the exact network and volume. The outer inventory found only
built-in networks, and the disposable daemon socket stopped answering.
The retained root is `run-7cfedfef95b5e0b57e6ffc95fdeb3756` and the
disposable daemon files are under `/tmp/prodbox-clean-engine.sgHYoSWw`.
The input preparation and cleanup observations are recorded; Kubernetes
creation, recreation and the full A01-08 case remain open. The log
`.build/phase1-clean-runtime-20261124.log` has SHA-256
`49c7755c8aeb74344d2cb1d5e08a6e13f4dd200980f3c1e8286123edba401f5d`.

Quota launch and recovery (2026-11-24). Campaign `1779052358050524`
recorded and created its case volume. The initial executor launch guard
refused the keeper stage before writing a launch record. The command
reported `MutationInconclusive`. The keeper is now admitted by the same
launch guard as the worker stages. `test cleanup 1779052358050524` and
its repeat both exited zero with operator SHA-256
`9cd2b4fad10584d18c9f67cef9ea0c94b7784dc7d1a3921a9a39277f66b7a4fd`.
The independent exact volume read changed from 200 to 404 with a 200
bridge control, and the cleanup receipt was retained. The initial failure
and recovery are in `.build/phase1-kernel-bounded-mutation-20261124.log`
and `.build/phase1-unused-mutation-disk-recovery-20261124.log`.
The corrected public campaign `1779537769813259` reached offline baseline
compilation. Independent Docker and filesystem reads confirmed a read-only
keeper on the recorded volume, a single writable volume mount in the
worker, a read-only worker root, no network, a memory and swap ceiling
of 8 GiB, and a 3 GiB tmpfs with 32,768 inodes.
Evidence is `.build/phase1-kernel-bounded-mutation-active-observer-20261124.log`.
The baseline exited 1 after about 343 seconds. The isolation and build
workers, keeper and exact volume retired. The compiler log was on the
retired tmpfs, so the build cause is unconfirmed. The command reported
`MutationInconclusive` and retained the source and local records. A bounded
private baseline diagnostic is now captured before the volume retires.
The command log `.build/phase1-kernel-bounded-mutation-retry-20261124.log`
has SHA-256 `a27652019b5d5878f3f748b2dbf623592cbc9ebdaa75b56253184359d186a628`.

Network-proposal recovery (2026-11-24). The public archive canary used
the `5c59ef7b` operator above and archived operation
`8f6ab513fbdf3e60ecd8bef6d961522f` after an independent 404 for the
unattempted network name with a visible bridge. The published transaction
record matched all nine entries. Replacement operation
`02a5799c106a249206fed71380be269a` reached Kubernetes readiness and
verified network policy. Public delete exited zero. Independent reads
returned 404 for the exact node, volume and network, returned 200 for
the bridge and found no matching worker units. Evidence is
`.build/phase1-network-proposal-archive-20261124.log` and
`.build/phase1-network-proposal-archive-exact-removal-20261124.log`.

Interrupted archive recovery (2026-11-24). The same operator stopped
while archiving `3640d3a06bfc984900283a3f55730f81`. The independent
observer found one moved entry and the bound manifest in staging before
terminating the exact reconcile process. A new public reconcile restored
and republished the old archive, preserving the original intent inode
and root generation. Replacement `9d9f5ec2b9ceacc4198bcb223460a4cf`
passed Kubernetes readiness and verified network policy. The supported
delete exited zero, exact independent node, network and volume reads
returned 404, and the operation's worker-unit inventory was empty.
Evidence is `.build/phase1-interrupted-archive-live-20261124.log`.
The warning-clean build for the archive and quota recovery slice passed,
as did 45 focused evidence fixtures and 354 CLI parser tests.

Phase 0 checker replay through the Phase 1 executor now binds the
five reviewed M00 source changes to their unchanged assertion semantics.
The plan records the new exact candidate digests. The compiled isolated
replay remains open. See [M00 replay](mutation_cases.md#phase-1-executor-replay-of-m00).

Rootless node diagnostic (2026-11-24). A second clean daemon under a
delegated systemd scope independently reported cgroup v2 with memory, PID
and CPU support. The pinned image again moved from 404 to 200. Operation
`04649f7451b6e50c32160aa4ea8f077a` stopped before sending a node create
request. Supported teardown removed the scoped volume and network. A
read-only fixture for the pinned kind executable then captured the exact
extra `--device /dev/fuse` request on the rootless branch. The recorded
proposal had the rootful vector, so the bridge could not admit that request.
The adapter now binds the daemon's observed mode to the exact argv and
permits only the pinned rootless FUSE device. Read-back checks the complete
device list and retains the original rootful record format. Evidence is
`.build/phase1-clean-runtime-debug-20261124.log` and
`.build/phase1-upstream-rootless-arguments-20261124.log`.
See [pinned kind Docker provisioning](https://github.com/kubernetes-sigs/kind/blob/v0.32.0/pkg/cluster/internal/providers/docker/provision.go).

Clean rootless startup (2026-11-24). Operator SHA-256
`ebad412d22027ad94527c76bce8b849604b422cfbb88224334917d54812ac56e`
imported the pinned image on daemon `ee79d7a1-1c7b-44b2-a422-b9d0008a2cf1`.
The independent observer saw exact node
`7080d8816fca845191be30777d3bf6eb6b78d765717fdc3123935eac7c5cb9d3`
with only the recorded FUSE device. Docker returned 204 to the start
request. Operation `690674698ea8ae28fe0bcde6bc207664` stopped in the worker
before installation of the kubeconfig. Kubernetes readiness remained
unconfirmed. Public cleanup removed the exact node, volume and network,
and the disposable daemon ended with the three built-in networks. This
confirms the device transition and leaves A01-08 open. Evidence is
`.build/phase1-clean-rootless-device-20261124.log` and
`.build/phase1-clean-rootless-device-independent-20261124.log`.

Decision (2026-11-24) for the A01-08 runtime. The [acceptance case at line 37](acceptance_cases.md#required-cases)
requires a clean Docker runtime and real preparation through supported
commands. Select a separate empty rootful daemon for the same public path
used in the passing A01-01 through A01-06 campaign. Bank the distinct
rootless startup result above. The fixture owns only the daemon and its
default bridge. The public workflow owns node image preparation and all
deployment resources and retirement.

Mutation compile diagnostic (2026-11-24). M01 campaign
`1780316149064117` reached the offline baseline compiler and exited 1 under
operator SHA-256 `0d24651b73b3f8c0d916108343aa13ad2a640efba85724926291bd80ae838aaf`.
The exact three workers and quota volume independently returned 404,
with a 200 bridge. The private compiler record exceeded the established
4096-byte record limit and its tail only identified Cabal's aggregate build
failure. The next runner writes a bounded excerpt of compiler error lines
or its captured process output and verifies the resulting record within
the same limit. The assertion did not run. Evidence is
`.build/phase1-m01-compiler-diagnostic-live-20261124.log` and
`.build/phase1-m01-compiler-diagnostic-exact-removal-20261124.log`.

Compiler temporary filesystem (2026-11-24). The independent observer for
campaign `1781121574517477` found GHC loading a temporary Template Haskell
shared object from Docker's `noexec` `/tmp`. The exact worker had more
than 3 GB available on its output mount when the diagnostic first appeared.
An offline two-module splice reproduced the same mapping refusal on a
private `noexec` mount and passed when GHC used an executable temporary
directory. The build command now sets `TMPDIR` to a private member of the
same kernel-bounded output volume. The generic `/tmp` retains `noexec`.
Evidence is `.build/phase1-m01-bounded-diagnostic-observer-20261124.log`
and `.build/phase1-ghc-private-noexec-local-splice-20261124.log`. The prior
campaign exited 1 before the assertion. The exact three worker IDs and
volume returned 404 with a 200 bridge in
`.build/phase1-m01-noexec-exact-removal-20261124.log`.

Rootful fixture isolation (2026-11-24). The first rootful test used an empty
Docker daemon and returned HTTP 200 to the archive load, followed by exact
image read-back 404. The daemon was using a containerd snapshotter and its
diagnostic stream exposed task events from the other daemon's namespace.
Reconcile stopped before node, volume or network proposals. Supported
cleanup returned zero and the fixture stopped. A second fixture preflight
confirmed the private containerd socket and classic `overlay2` on an empty
daemon, matching the successful rootful runtime's image store. Evidence is
`.build/phase1-clean-rootful-live-20261124.log` and
`.build/phase1-clean-rootful-isolated-preflight-20261124.log`.
Independent read-back additionally found one dangling image record for the
loaded manifest `29f6cdcc91e8f78bd09d879d72210d6c04db5b976921af338c07580aaab5bf1a`
in the shared containerd `moby` namespace. The original Docker daemon
still reported the expected pinned config image. The dangling record
remains accounted for at `.build/phase1-first-rootful-containerd-observation-20261124.log`.
At 19:45 America/Toronto, an exact read-only query reconfirmed the shared
entry, the original Docker daemon identity, its bridge ID, and its pinned
config image. The entry remains in the shared namespace. Exclusive ownership
of its backing content and snapshots remains unverified.
See `.build/phase1-first-rootful-containerd-repeat-observation-20261124.log`.

Reviewed mutation coverage (2026-11-24). Registered Phase 1 variants for
foreign Docker scope and network, forbidden pull requests, foreign control
and namespace cleanup, replaced namespaces, controller receipt and node
binding, unbound removal receipts, unavailable Authority admission, the
Authority deployment fence and independent node-removal read-back. The M02
set now includes stale-source, wrong-scope and fabricated-success reports.
Test selectors and exact source and candidate digests are in
[mutation_cases.md](mutation_cases.md#phase-1-preliminary-assertion-binding).
The in-hand campaign `1781529353439883` captured its source and started M01
before those bindings were added. Each added variant needs its own isolated
execution evidence.

Clean-runtime acceptance (2026-11-24). From 17:07 to 17:24 America/Toronto,
`test run phase-01 --runtime-socket PATH` exited zero on the private rootful
Docker and containerd instance `30fe838a-2a90-4ea7-8e33-76075fbb8f23`.
A01-01 through A01-06 and A01-08 each recorded `EvidenceChecksSatisfied`,
successful primary work and confirmed cleanup. The source manifest SHA-256
was `641def6ec50869a224e2b2668cfa3c234f751275ebdb18c4ce5ffdbafa4a7074`,
operator file SHA-256 `06aa18dc35973816bd47bec1788ee9ad8ebc12895ef229b928dbb422f6b83ca3`,
and the case 8 public configuration evidence digest was
`bc5af79358a3be1f8d6968be3dd0ca2bddf77403b35f05420e802d022e0657e2`.
The pinned Docker config image returned 404 before preparation and 200
after it. Independent file SHA-256 observations were
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`
for kind and `14bb2d45444f0ece9bb26daadc440f4ca59d51ef64b8782fd5c9c6839efc4a07`
for the archive. Reports are under
`.build/scenario-evidence/f0d4fa82d6cf765c4407d1bdae6c6e5d/`.

The original and replacement operations `ddef7cfee55e6171ce5d7062cd587cb8`
and `52f557b1a2a1bec183eff2eef17772b7` used scope
`run-d5ab0d26ed71a15ba11f75f994cafe4f` and root generation
`91c4de47a7d72fa78381e68b8c871ac1`. Sibling operation
`553d8bdeb807fac52ed231b827f3b45d` used
`run-4ea1598e450d84170abc66ab687b5fbe`. Independent `/readyz` reads passed
for all three nodes. Both replacement Pods read their original markers and
the PVC bound to `pv-a01-02`. The 64 MiB workload completed and the 16 MiB
workload was OOMKilled in the public scenario. Independent exact reads
returned 404 for all three containers, volumes and networks, with a 200
bridge. The exact worker-unit lists were empty after cleanup. The fixture's
two sockets and default bridge retired. The command log SHA-256 was
`cece4024fe323c14a19c681e06067305415e56e1f8ad79828f29e7566d246859`.
Evidence is `.build/phase1-clean-rootful-isolated-live-20261124.log`,
`.build/phase1-clean-rootful-isolated-live-20261124-independent.log`,
`.build/phase1-clean-rootful-isolated-marker-20261124.log` and
`.build/phase1-clean-rootful-isolated-closure-20261124.log`.
The three publication directories held only the expected birth, send,
submission and retirement metadata after teardown. Their payload files
were absent. The exact read-back is in
`.build/phase1-clean-rootful-publication-accounting-20261124.log`.

Clean-runtime repeat (2026-11-24). From 19:08 to 19:24 America/Toronto,
the public `test run phase-01 --runtime-socket PATH` exited zero on a second
private Docker and containerd instance, `22d789e5-3f9c-412e-ae95-31af959fb29b`.
A01-01 through A01-06 and A01-08 each recorded `PrimarySucceeded`,
`CleanupConfirmed` and `EvidenceChecksSatisfied`. The exact pinned image
returned 404 before preparation and 200 afterward, and the independently
observed kind and archive hashes matched the first run. The operator SHA-256
was `60cbfaea27e3bb577bc08e9f5184fcf98c1b95d9b56214f6a32cef21855edfc8`,
the source manifest SHA-256 was
`9df901f4c5ddc797137caa85425db02bf7a29d4809444602534438c5d9018ebf`, and the
case 8 public configuration evidence digest was
`9ed8df2166da78b38cf3e75f4197cbda582472d920c986f3288692188331da4f`.
Reports are under `.build/scenario-evidence/7c4a7c3f982cac2bac2a2030c8a1f7ff/`.

Primary operation `4d47cab8d5043ba773c3d934d8b31187` and replacement
`144e502fe3e38a1f9090a5d2525ae365` used scope
`run-b2c7ef9bb3fb85c00ca3367569987550` and generation
`0fd6ff2194831ff8bef76f59a96336dd`. Sibling `c67898c5e263e72a728c85c9cec7aea6`
used scope `run-480e6a9748b8359754ab3a6427a562fb`. An independent observer
bracketed simultaneous Kubernetes readiness on the two live roots. It then
confirmed replacement readiness, both retained markers and PVC binding to
`pv-a01-02`. The public capacity case recorded peak memory of 450,637,824 of
805,306,368 bytes and 34 of 96 tasks. Exact node, volume and network reads
for all three operations returned 404 while the private bridge returned
200. Exact worker-unit lists were empty, both disposable sockets and the
fixture bridge retired, and the original daemon's bridge retained its ID.
The command log `.build/phase1-clean-rootful-repeat-final-20261124.log`
has SHA-256 `4df71ce0ee2e4a3495f885abeec8ba02def4f2535912119a26c254cc760ceb3e`.
The independent logs are
`.build/phase1-clean-rootful-repeat-final-20261124-independent.log` and
`.build/phase1-clean-rootful-repeat-final-closure-20261124.log`.
The three publication directories retained only birth, send, submission and
retirement metadata. The input names were absent in the independent
`.build/phase1-clean-rootful-repeat-final-publication-20261124.log` read-back.

Canonical gate follow-up (2026-11-24). Operator SHA-256
`467c70b351aa852b3a7e87926808d84be52fdd7ad05fdbb90fa65b01c9385871`
failed policy before the build and test gate. The keeper receipt used a
nested `case` in a lambda, and the Docker read-back comment contained a
token reserved by the subprocess checker. The corrected source keeps the
same keeper sequence and adapter behavior. The two Docker mutation preimage
and candidate digests were refreshed. Failed evidence is
`.build/phase1-current-full-catalog-canonical-20261124.log`.
The corrected gate passed policy and then flagged formatting in 14 Haskell
files. The pinned Fourmolu 0.19.0.1 formatted only those paths. All seven
affected mutation sites still occur exactly once. Their source, binding and
candidate digests were refreshed without changing the substitution text.
The second failed gate is `.build/phase1-canonical-style-recheck-20261124.log`.
The version 2 receipt gate required one final layout correction in its write
call. That correction cleared formatting. The full pinned HLint scan then
found one `whenMaybe` hint in the Docker keeper adapter. The adapter now
uses the existing `guard` and `traverse` operations for the same conditional
action. Targeted pinned format and lint checks passed. The failed gate logs
are `.build/phase1-canonical-receipt-v2-20261124.log` and
`.build/phase1-canonical-final-format-20261124.log`.
The next gate passed policy, formatting, lint and the warning-clean build.
It ran 10,221 main unit tests. Three CLI snapshots still omitted
`test cleanup` and `test run --runtime-socket`. The existing CLI renderers
regenerated only the command tree, registry JSON and leaf help snapshots.
The four generated CLI output tests passed against those files. The failed
gate is `.build/phase1-canonical-disk-hint-20261124.log`.
The canonical rerun finished at 19:08 America/Toronto with exit zero and
10,221 main, 27 Authority admission, 35 control-plane authentication and
935 authenticated transport tests passed. Its operator SHA-256 was
`60cbfaea27e3bb577bc08e9f5184fcf98c1b95d9b56214f6a32cef21855edfc8`.
The log `.build/phase1-canonical-cli-golden-20261124.log` has SHA-256
`4f49bdbf9fdcf7a3b6d58bf047a73c0b9fb8748908c5fd5f8a49e12e561496e8`.
The same operator then started a repeat clean-runtime scenario on private
daemon `22d789e5-3f9c-412e-ae95-31af959fb29b`; its initial exact image
lookup returned 404. The repeat log is
`.build/phase1-clean-rootful-repeat-final-20261124.log`.

Isolated M01 baseline (2026-11-24). In campaign `1781529353439883` a
fresh build reached selection and passed its designated test. The held
keeper observer independently read the owner-private baseline executable,
SHA-256 `615153e2162069418217c03e05c7140e7f7de7aa898285f50c958e440cfe608e`.
The baseline container had network mode `none`, an 8 GiB limit for memory
and for combined memory and swap, a four-CPU quota and a 4,096-PID limit.
The observer confirmed read-only bind
mounts, generic `noexec` `/tmp`, and compiler temporary files on the one
bounded output volume. The mutant build has begun. Evidence is
`.build/phase1-mutation-current-baseline-binary-20261124.log` and
`.build/phase1-mutation-campaign-tmpdir-isolation-20261124.log`.

M01 receipt boundary (2026-11-24). The isolated mutant compiled and the
unchanged test returned `TestAssertionFailures 1 ["context.rejects_root_alias"]`.
The outer runner observed workspace and quota retirement. Its final receipt
was 4,186 bytes and exceeded the 4 KiB metadata reader limit. The command
exited 1 with `MutationInconclusive`. The exact eight container IDs and
quota volume independently returned 404, with a 200 bridge and no retained
case directories. The command log SHA-256 was
`144a75531993b33a3fb0534280ae8371e3d6bce84e581cb366a2b1078854e3f4`.
Evidence is `.build/phase1-mutation-campaign-tmpdir-20261124.log` and
`.build/phase1-mutation-receipt-overflow-closure-20261124.log`.

Decision (2026-11-24). The [evidence rule at line 98](development_plan_standards.md#evidence-and-live-campaigns)
requires the source, test, outcome and cleanup binding to survive in the
receipt. Version 2 case receipts use a 16 KiB limit for creation and
read-back. Other metadata and historical version 1 receipts keep their
4 KiB limit. The writer checks the serialized size before creating a file.
Campaign `1781529353439883` remains inconclusive and the original receipt
remains available for diagnosis. Re-run the registered campaign with the
new receipt version.

Version 2 receipt canary (2026-11-24). The 45 focused evidence tests passed,
including a 4,300-byte detail accepted only in the new version and refusal
above the new limit. Public `test status 1781529353439883` refused the old
oversized receipt. Public `test cleanup 1779052358050524` still confirmed
the absence of the previously recovered volume using its valid version 1
record. The full registered campaign `1783840184764378` started at 17:45
America/Toronto using operator SHA-256
`eb417fecb42cd1abcf53142fab728a9411f07c6f31db80c7383d6b4e66350d4b`
and source manifest SHA-256
`51239b38afc0eb68aacd14c9bea09d612553bdd5d69f71d664a16ee6f9e1f1a5`.
It retains the existing per-stage budgets and has a 20-hour outer deadline.
The exact Docker retirement observer follows each case receipt. Evidence is
`.build/phase1-current-full-mutation-catalog-20261124.log` and
`.build/phase1-current-full-mutation-retirement-20261124.log`.

Qualified overlapping-root variant (2026-11-24). Campaign
`1783840184764378` completed `M01` at 18:15 America/Toronto. The baseline
passed and the compiled mutant failed exactly `context.rejects_root_alias`.
The synchronized 4,186-byte version 2 receipt records `MutationKilled`
and `qualified=true`; its SHA-256 is
`4e4983064381d87aa4879b9b7ccb490c3bf95e75540bc15c785ab4bf7b938745`.
The independent observer read exact 404s for eight containers and the
quota volume, a 200 for the bridge, and no retained case workspace. Held
volume reads identified the baseline raw binary SHA-256
`459686808916573a152b1bd0a1d2d2dae553e16f2098ff997f6dbd29d75ab6d8`
and the mutant raw binary SHA-256
`2b648146110aa5555cc262c0f27a228b75446ba6beed6aaca8b3f1bd2e6fda34`.
Public `test status` also read the exact case receipt. The same campaign
has started `M00-future-dependency`. Other variants and calibrations
remain pending. Evidence is `.build/phase1-v2-verified-case-status-20261124.log`,
`.build/phase1-v2-current-case-binary-20261124.log`,
`.build/phase1-v2-current-mutant-binary-20261124.log` and the campaign
retirement observer above.

Qualified future-dependency replay (2026-11-24). In the same campaign,
`M00-future-dependency` finished at 18:40 America/Toronto with a compiled
mutant failure exactly at `plan.rejects_future_dependency`. The 4,283-byte
version 2 receipt records `MutationKilled` and `qualified=true`, SHA-256
`b4e42080089ff8a1ff647b3b7d2802a6cb924be83a6e99782f002e6221ee6308`.
Independent observation confirmed eight exact worker 404s, quota volume
absence, a 200 bridge and no remaining case workspace. The campaign
started `M00-invalid-remover` next.
`M00-invalid-remover` qualified at 19:06 America/Toronto after its compiled
mutant failed only `plan.requires_valid_remover`. Its 4,263-byte receipt
SHA-256 is `4f169abb7eee2ab5adcbfa84c4d253f53671edc71ff2e270695a6d73b259caed`.
Independent read-back confirmed all eight workers and the volume absent,
the positive bridge, and no remaining workspace. Three cases are now
qualified in the active campaign.

Qualified missing-evidence replay (2026-11-24). In campaign
`1783840184764378`, `M00-missing-evidence` qualified at 19:33 America/Toronto
with a compiled mutant failure only at `plan.requires_bound_evidence`.
The 4,279-byte version 2 receipt has SHA-256
`1be6d5d773f38622bb9f8a942afedfcadc7a42487fd86b906bef47ce3ff90017`.
The independent observer confirmed all eight exact worker IDs and the
quota volume absent, the bridge present, and the case workspaces retired.
At 19:59 America/Toronto, `M00-foreign-evidence` also failed only
`plan.requires_bound_evidence` and qualified with the same independently
confirmed cleanup. Its 4,279-byte receipt SHA-256 is
`e986ed0854b8d7fcdfa3bd6bcdd6ec721dc779b3626ec5bad79308d029ca4fcd`.
Five cases are qualified. `M00-missing-current-source` started next.
That case qualified at 20:25 America/Toronto when the compiled mutant
failed only `plan.rejects_missing_source`. The 4,253-byte receipt SHA-256
is `bb9183a6c91bf219b0864cf3874f067a5288ff26fc8fbfd3d63c7a9597f07621`.
The independent observer confirmed eight absent workers, quota volume
absence, the 200 bridge and workspace retirement. All five M00 cases and
the overlapping-root M01 case have qualified in campaign `1783840184764378`.
`M01-artifact` started next.
It qualified at 20:47 America/Toronto when its compiled mutant failed only
`artifact.rejects_changed_bytes`. Its 4,213-byte receipt SHA-256 is
`dd50aa9d3c80afb4d127d080093aa6cb87025b010f2946c825df07226699c762`.
The independent observer confirmed all eight worker IDs and the quota volume
absent, the bridge present and the case workspaces retired.
`M01-unconfirmed-node` advanced next, with seven cases qualified so far.
At 21:12 America/Toronto, its compiled mutant failed only
`delete.rejects_unconfirmed_node`. The 4,247-byte receipt SHA-256 is
`1b27faaf6f336786234235c4093736949fafe6481e985777cd780482fe3d1d49`.
The independent observer confirmed all eight workers and the volume absent,
the bridge present and the workspaces retired. Eight cases are qualified.
At 21:38 America/Toronto, `M01-unknown-recreate` qualified with the sole
compiled assertion failure `recreate.rejects_unknown_intent` and the same
independent cleanup observations. Its 4,237-byte receipt SHA-256 is
`b6947153644bd9aa51594daec8e68412e506a6ea9dd8dcacfa326586a0fce0b5`.
Nine cases are qualified. `M01-external-family` started next.
At 22:03 America/Toronto it qualified with the sole compiled assertion
failure `controller.rejects_external_family`. Its 4,250-byte receipt SHA-256
is `0c63d16a6b285590412656afd7370dc762ec49de411baaf4753f9a65f39a5f6b`.
The independent observer confirmed eight workers and the quota volume
absent, a 200 bridge and workspace retirement. Ten cases are qualified.
`M01-failed-removal` qualified at 22:26 America/Toronto with the sole compiled
assertion failure `delete.rejects_failed_removal`. Its 4,224-byte receipt
SHA-256 is `71ba584ffc5d395747a9033559575823cde097ed5edb6912b5061c8ab5037b3e`.
The independent observer confirmed the same exact cleanup. Eleven cases are
qualified. `M01-foreign-control` started next.
At 22:52 America/Toronto, `M01-foreign-control` qualified with the sole
compiled assertion failure `delete.rejects_foreign_control`. Its 4,234-byte
receipt SHA-256 is
`e97141c3f2a020f353e3dc008b8fc53d9b20445f86c6c1f9c9a8c1caa7c7cf15`.
The independent observer confirmed eight workers and the quota volume absent,
the bridge present and the workspace retired. Twelve cases are qualified.
`M01-unbound-receipt` qualified at 23:15 America/Toronto, with the sole
compiled assertion failure `delete.rejects_unbound_receipt` and the same
independent read-back. Its 4,236-byte receipt SHA-256 is
`65b649e6567fe74370ccc58e351206c91787c4b8c6f729f6ff5e48fa61a16aac`.
Thirteen cases are qualified. `M01-foreign-controller-receipt` started next.
It qualified at 23:37 America/Toronto with the sole compiled assertion
failure `controller.rejects_foreign_receipt`. Its 4,268-byte receipt
SHA-256 is `0c7ccde62489792a5d67610de493b319f12f4997e9dd6581e82f1dd4cb598721`.
The independent observer confirmed exact retirement of eight workers, the
volume and case workspaces while observing the bridge. Fourteen cases are
qualified. `M01-wrong-controller-node` started next.
An additional read-only audit at 23:51 independently matched the 14 durable
case receipts to their launch intents and worker receipts. The original
Docker daemon and exact bridge bracketed 112 worker 404s and 14 quota volume
404s. All 14 case workspace names were absent. See
`.build/phase1-current-full-mutation-bracketed-sample-20261124.log`.

Controller node mutation (2026-11-25). At 00:03 America/Toronto,
`M01-wrong-controller-node` qualified with the sole compiled assertion
failure `controller.rejects_wrong_node`. Its 4,220-byte receipt SHA-256 is
`4c479d3d202b582e0e6b0ad9c15562b6fb227ed68f2cc377c727909eaaff3bbd`.
The independent observer confirmed exact retirement of eight workers, the
quota volume and the case workspace, while observing the bridge. Fifteen
cases are qualified. `M01-foreign-namespace-cleanup` started next.
At 00:26 America/Toronto, it qualified with the sole compiled assertion
failure `network.rejects_foreign_namespace_cleanup`. Its 4,271-byte receipt
SHA-256 is `d92b434d54725c708f8bdfbaafa0c927f1dbbe0f0086283c53bec4e973a3b62f`.
The independent observer confirmed eight exact worker 404s, the quota
volume absent, the bridge present and the workspace retired. Sixteen
cases are qualified. `M01-replaced-namespace` started next.
At 00:49 America/Toronto it qualified with the sole compiled assertion
failure `network.rejects_replaced_namespace`. Its 4,243-byte receipt
SHA-256 is `0c1c9e70c9acb76de2abac8cdf7f67c9afc21180d2d13848533acd8b359d7e61`.
Independent exact cleanup checks passed for all eight workers, the volume
and workspace while the bridge was present. Seventeen cases are
qualified. `M01-foreign-scope` started next.
At 01:12 America/Toronto, that case qualified with the sole compiled
assertion failure `context.rejects_foreign_scope`. Its 4,212-byte receipt
SHA-256 is `ab5642a1c507fed01061ed578a3e660adf6d71e0294646ecb14a63b6a906358c`.
The independent observer repeated the exact worker, quota volume, workspace
and positive bridge checks. Eighteen cases are qualified.
At 01:34 America/Toronto, `M01-foreign-network` qualified with the sole
compiled assertion failure `context.rejects_foreign_network`. Its 4,229-byte
receipt SHA-256 is
`94877b9c41dc2bead5e70b17ca402904737c34fca040287e453e80b25203b908`.
All eight workers and the quota volume independently returned 404. The
workspace was absent and the bridge returned 200. Nineteen cases are
qualified. `M01-unowned-pull` started next.
At 02:00 America/Toronto, it qualified with the sole compiled assertion
failure `context.rejects_unowned_pull`. The 4,223-byte receipt SHA-256 is
`63dbf4be393f60d5d656af834bca429e386376ad40d990ecaea4a6156b7dd7f3`.
The independent observer confirmed the same exact worker, volume and
workspace retirement with the bridge present. Twenty cases are qualified.
`M01-authority-unobservable` started next.
It qualified at 02:23 America/Toronto with the sole compiled assertion
failure `delete.requires_observed_admission`. Its 4,265-byte receipt
SHA-256 is `11774a671adf955c119df5705c16325576101d33217eaac54a9f5716303a245a`.
All eight exact worker and quota volume 404s were independently observed,
with a 200 bridge and the case workspace absent. Twenty-one cases are
qualified. `M01-authority-fence` started next.
It qualified at 02:46 America/Toronto with the sole compiled assertion
failure `delete.fences_authority_deployment`. Its 4,258-byte receipt SHA-256
is `c349fca548d5f351f4df31bf75f3fea68fbfb0b847168091ea57c5149634cef9`.
Independent Docker reads confirmed eight worker IDs and the quota volume
absent with a 200 bridge, and the case workspace names were absent.
Twenty-two cases are qualified. `M01-receipt-only-removal` started next.
It qualified at 03:11 America/Toronto with the sole compiled assertion
failure `delete.requires_independent_removal`. Its 4,254-byte receipt
SHA-256 is `51007e50bedc122f8cfdcc6a3470b064c47865e633e8803241d5dce4c9db22df`.
The independent observer confirmed eight workers and the quota volume absent,
the bridge present and workspace retirement. All 18 kind M01 cases and all
five M00 cases have qualified. The first M02 evidence case started next.
The independent audit at 02:48 also bracketed exact Docker reads for the
first 22 cases with the original daemon and bridge, confirming 176 worker
404s, 22 quota volume 404s and no case workspaces. See
`.build/phase1-current-full-mutation-bracketed-sample-20261125.log`.

Evidence-validation mutations (2026-11-25). At 03:34 America/Toronto, `M02`
qualified with the sole compiled assertion failure
`evidence.rejects_unbound_result`. Its 4,201-byte receipt SHA-256 is
`bf06cc31ef357a6e91f923ef1eb45646d61f6c80999035b4ef8960bd219be032`.
The independent observer confirmed exact Docker absence of eight workers
and the quota volume, a 200 bridge, and workspace retirement. Twenty-four
cases are qualified. `M02-stale-source` started next.
At 03:57 America/Toronto, it qualified with the sole compiled assertion
failure `evidence.rejects_unbound_result`. Its 4,232-byte receipt SHA-256 is
`9e256f62edfc231ef608a935308e629076851e951fdbe2bd68d55ad2415ad70e`.
Independent worker, quota volume and workspace retirement checks passed,
with the exact bridge present. Twenty-five cases are qualified.
`M02-wrong-scope` started next.
It qualified at 04:19 America/Toronto with the sole compiled assertion
failure `evidence.rejects_unbound_result`. Its 4,231-byte receipt SHA-256 is
`d3dd6be2db4c25672e40068091ee57a9febc9daeec3ed1adcbbc6c90c4dde896`.
The independent observer confirmed eight exact worker 404s, the quota
volume absent, the bridge present and the workspace retired. Twenty-six
cases are qualified. `M02-fabricated-success` started next.
At 04:42 America/Toronto, it qualified with the sole compiled assertion
failure `evidence.rejects_unbound_result`. Its 4,244-byte receipt SHA-256 is
`9b3064a8fe00a586c69f6db087411b035d4162d2c113a4bfcb0e2372948e7664`.
All eight worker IDs, the quota volume and the workspace retired under
independent observation with the bridge present. All 27 required source
mutations are killed. The executor's three outcome calibrations remain.

Executor calibration (2026-11-25). At 05:05 America/Toronto,
`calibration-survivor` qualified with `MutationSurvived`. The selected
unchanged assertion passed after the compiled mutation. Its 4,042-byte
receipt SHA-256 is
`2cd512fea0712cf9babc9516cb619c5660e3c0cc0672a3b947ff0ffdff407bf4`.
The independent observer confirmed exact retirement of eight workers, the
quota volume and the case workspace, with the bridge present.
`calibration-invalid` started next.
It qualified at 05:27 America/Toronto with `MutationInvalid`. The mutant
build exited 1 on the seeded syntax fault. Its 3,399-byte receipt SHA-256
is `828d33b637fb5401a4825b447b3374ae5338a91582a2f02f65333dd4766c303e`.
All six launched workers and the quota volume independently returned 404,
the bridge returned 200, and the case workspace was absent.
`calibration-timeout` started last.
At 05:50 America/Toronto it classified `MutationInconclusive` and retained
`qualified=false`. The selected invocation exited 1 with no stdout and 879
stderr bytes, which the typed decoder classified as `TestUnobservable`.
Campaign `1783840184764378` exited 1 after 29 qualified cases. All eight
timeout case workers and the quota volume returned exact 404s with a 200
bridge. The failed run retained the case's two workspace directories and
its 3,966-byte receipt, SHA-256
`db522a08c70ffec6f5b1221736c4b158c5d4d42fe90465b164a471882d2c1705`.

Decision (2026-11-25). The exact unit executable reproduced a Tasty option
parse failure for `--timeout 1ns`. With `--timeout 0ms`, all 64 repetitions
returned exit 1 with only the typed timeout marker for the same exact test.
Use that expired test deadline in the timeout calibration. This follows
the mutation replay requirement at line 80 of
[development_plan_standards.md](development_plan_standards.md). The other
29 cases run unchanged commands and retain their isolated results. The
bounded reproducer is `.build/phase1-timeout-parser-reproducer-20261125.log`.
A corrected, isolated public replay of `calibration-timeout` is required.
The corrected operator SHA-256 is
`72b9ef0c081fd894a6d057cbcbad1361573f3ed1061f5d24903608c658239fc3`.
It began public replay `1827568496146719` at 05:54 America/Toronto with
source manifest `3f8494ed0d3442ca74a7d3b9c604365eceeb4bace02933a29402fc68c93956bf`.
The command log is `.build/phase1-timeout-calibration-replay-20261125.log`.
At 06:18 America/Toronto, the corrected replay exited zero. Its baseline
passed and its compiled mutant returned `TestTimedOut`. The executor
classified it `MutationInconclusive` and retained `qualified=true`. The
4,135-byte receipt has SHA-256
`5023ed05a3ce1fad4e3317bed21ceeb0f7817583357014615d65b82c53c93222`.
The original Docker daemon and exact bridge bracketed eight worker 404s
and the quota volume 404, and the case workspace names were absent. See
`.build/phase1-timeout-calibration-bracketed-20261125.log`.
The same bracketed audit independently reconfirmed 230 exact worker 404s,
29 volume 404s and workspace retirement for the 29 unchanged cases in
`.build/phase1-qualified-mutation-prefix-20261125.log`. Together these
records establish 27 targeted kills and all three expected calibrations.

Canonical gate after the timeout correction (2026-11-25). Operator
SHA-256 `72b9ef0c081fd894a6d057cbcbad1361573f3ed1061f5d24903608c658239fc3`
ran `prodbox dev check` with Fourmolu 0.19.0.1. Policy, formatting, lint,
the warning-clean build and all four gated suites passed. The suites ran
11,218 tests in total. The command exited zero at 06:48 America/Toronto.
Log `.build/phase1-canonical-timeout-calibration-20261125.log`, SHA-256
`2b90dc7debf0d47a1c457b2ff9c54b292f2084d96ace5b8554884629e4dca4c2`.

Historical publication inventory (2026-11-24). A read-only comparison at
17:48 America/Toronto found 28 directories whose keys matched a retained
test operation and whose names and modes matched terminal metadata. Among
unmatched keys, 495 held only the expected terminal metadata names and nine
still had at least one published input filename. This comparison observed
names, modes and operation IDs. It did not open the publication payloads
or establish terminal state or cleanup admission for unmatched keys. The
inventory is `.build/phase1-earlier-publication-shapes-20261124.log`.

Historical fixture provenance (2026-11-24). A follow-up found that eight of
the nine input-bearing keys match the paired operation and cleanup IDs
generated by [ProbeVerifierBudget.hs](../test/qualification/ProbeVerifierBudget.hs)
at line 152.
Each also had the corresponding same-operation family, verifier and
successor publication names. One matched the exact operation in
`.build/phase1-rts-probe-docker-preflight-64m.log`; another matched the
successor ID in `.build/phase1-rts-probe-managed-traced-20261124.log`.
The ninth key had the repeated PID-and-monotonic operation key shape from
[KindControllerInput.hs](../test/qualification/KindControllerInput.hs)
at line 306.
The user manager listed no units matching any of the nine operation IDs.
This scopes the historical fixture investigation. No payload was opened,
and key shape and current unit inventory do not supply a retained retirement
proof for any of the nine. Exact names, ownership, timestamps, and sibling
keys are in `.build/phase1-earlier-publication-fixture-provenance-20261124.log`.
At 19:35 America/Toronto, a read-only observer linked to the current
publication library reopened each exact birth record under its lock and
verified the never-sent fence before and after matching both input inode
identities to that birth. All nine passed. The observer reads birth/send
metadata and file status only. The repeat run's possible-send marker
triggered the expected refusal in the same observer. No payload was opened
or retired. The log
`.build/phase1-earlier-publication-fence-observation-20261124.log` includes
the observer identity and the nine exact results. The named public mutation
cleanup handles an unused quota volume only. The historical standalone
fixtures no longer have a claimed source root to drive registered teardown.

Earlier cleanup disposition (2026-11-25). At 05:29 America/Toronto, a
read-only audit bracketed observations with the original Docker daemon and
bridge. It confirmed the exact old node and volume 404s, no listed operation
units, and the exact scoped network still present with zero endpoints. See
`.build/phase1-earlier-network-bracketed-20261125.log`.
[AGENTS.md](../AGENTS.md) at line 71 requires completing in-hand lifecycle
operations or recording their recovery disposition. Its lines 67 and 77
also require closing the phase's cleanup obligations and getting explicit
authorization for an exceptional manual cleanup. The exact network and
nine historical input pairs remain pending that authorization. Preserve the
original supported-path refusals and the old operation records. A hand
action, if authorized, cannot qualify an acceptance run under the
[campaign standards](development_plan_standards.md#evidence-and-live-campaigns).
The 05:29 publication fence repeat confirmed the nine exact never-sent
births and both bound inputs for each, with the same read-only observer.
See `.build/phase1-earlier-publication-fence-repeat-20261125.log`.

Earlier cleanup settled (2026-11-25). The operator authorized these exact
hand actions and standing local test fallback cleanup under
[AGENTS.md](../AGENTS.md#autonomous-test-cleanup). At 12:13 America/Toronto,
the recorded test root, generation, operation, socket, daemon and creation
receipt matched while the root lease was held. No operation unit or network
endpoint remained, and the exact node and volume returned 404. The exact
network delete returned 204. Independent GET returned 404 with the original
daemon and bridge confirmed before and after. The original scope, intent and
creation receipt retained their digests. The first verifier invocation
stopped before contacting Docker because its connection wrapper lacked a
context-manager interface. The corrected attempt is recorded in
`.build/phase1-detached-network-hand-action-verified-20261125.log`, SHA-256
`99e6fc4dfc75e7973b66608bb97456c16ddcb6ce39c4675b554e63a99cd514f3`.

At 12:14 the existing journaled never-sent retirement routine retired the
nine exact fixture input pairs. Each birth proof matched the original
payload identities and publication directory. Independent no-follow
read-back confirmed all 18 inputs and their quarantine names absent, with
the original birth and submission metadata and the new terminal records
present. See `.build/phase1-publication-cleanup-hand-action-20261125.log`,
SHA-256 `caf605a6149c8e746249daf5123049e6b2e5637f496569b8189cc95c675bf1c5`.
These hand actions settle the failed-run residue. The earlier refusal and
the two supported clean runs retain their original verdicts. The shared
containerd cache observation above carried no exclusive test ownership and
no cleanup claim applies to it.

Verifier isolation work in progress (2026-11-23): the failed probe cleanup
family and original kind family use the same systemd slice, so a successor in
that slice cannot hold their retirement observations while running. The
successor now has a versioned controller identity, publication namespace and
separate slice; version 1 records retain their original interpretation. A
version 2 verifier may inspect a published, retired predecessor without a
removal-attempt record, but only a separately bound, positive-control-bracketed
namespace inventory can establish absence. This follows the independent
read-back and retained-identity requirements in
[control_plane.md](../documents/engineering/control_plane.md) and the live
campaign evidence requirements in [plan standards](development_plan_standards.md#evidence-and-live-campaigns).
The implementation and adversarial qualification are still in progress; no
new live cleanup or phase acceptance is claimed. The retained test node and
its scoped recovery records remain in place. The publication-kind codec and
28 controller-submission controls passed, including the new identity; the
preparation fixture passed both versioned requests and distinct-slice checks.
The longer recovery fixture reached the new missing-attempt controls, then
failed on its own restored fixture file mode; that fixture is being corrected
and rerun. Its next run reached the later pre-publication verifier case but
exhausted the fixture's shared 120-second deadline; the fixture window was
expanded for a fresh run. An initial 660-second fixture window was correctly
refused by the host operation limit, so the retry uses the supported
590-second outer window. A never-sent fallback regression found on the first
run was fixed. The supported-window run passed the new missing-attempt and
legacy verifier cases, then exposed a stale assertion expecting network
failure where the no-intent path now reports no effect planned. The assertion
was corrected. The expanded isolated fixture then reached its public
reconcile assertion with an older copied binary that did not recognize the
version 2 request; the documented operator binary is being refreshed for the
next run. The isolated publication/retirement chain still needs a full pass.
These fixture outcomes do not establish live recovery.

The refreshed-binary run subsequently passed the complete manager-backed
[KindControllerInput fixture](../test/qualification/KindControllerInput.hs),
including isolated publication, missing-attempt readback, refusal of live
predecessors and verifier, retirement, and never-sent recovery. The fixture
SHA-256 was `55c90cc6ca4b5e40a0671e727adaa1c247086ada62028885e606b59b3d84b445`
and the public binary SHA-256 was
`74e6e7f07bad9bfb790fda490eb84600e3e18ac38358e0672ca7ab58229fee73`.
The bounded completion fixture also passed. These controlled results do not
establish real Kubernetes readback or phase acceptance.

Real in-hand recovery continuation (2026-11-23): public `control delete
--yes` on the retained `run-7ae426bc5f920fb9fb91a516f104e4f7` configuration
submitted isolated verifier `a8e26645a5b02fb0b006439e73ecb3c2`. Both
predecessor retirement checks closed and the public command independently
observed the verifier retire, but no probe readback record was written.
The verifier service exited status 1; the manager journal exposed no more
specific worker outcome. Public delete retained the node and returned
incomplete. Exact output is
`.build/phase1-isolated-verifier-recovery-20261123.log`; the verifier locator
and possible-send publication remain durable. A successor must preserve that
identity and establish its retirement rather than replacing it. Diagnose and
reproduce the missing worker outcome offline before any further live send.
The manager service explicitly discards both output streams. A subsequent
implementation in progress records only closed verifier outcome categories
under the scoped operation, after the bound verifier returns; this diagnostic
is non-authorizing and cannot recover an outcome that was not recorded for
the failed run. Its qualification and the successor protocol remain open.
The manager-backed fixture subsequently passed with the diagnostic write and
read-back, including refusal before verifier publication. Fixture SHA-256:
`4078bed39a23415e880bc022db6bc68212ae5dbf96cee9c61f17612903fd2320`;
binary SHA-256:
`68c768d724adfa7eff1cbdeead3822586435e01c4383a8cce117a1bb9be6af12`.
The record is best-effort: an input failure, interruption, or expired window
can leave no category. It is not evidence that a verifier retired or that a
namespace is absent.
An offline slow-admission control reproduced a verifier-locator refusal under
the ten-second writer limit: a 250 ms admission check was repeatedly nested
inside each record read. This is a reproducible timing-class failure, not a
diagnosis of the unrecorded live worker outcome. The writer now brackets its
local prerequisite snapshot with the retained lease/root checks instead of
repeating the external check inside every read; its positive and false-
admission controls are being rerun.
The [slow-admission qualification](../test/qualification/ProbeVerifierBudget.hs)
then recorded and independently read the locator with the same 250 ms check;
false admission and admission changing across the snapshot both refused. The
test does not identify the cause of the unrecorded live verifier failure.
Decision (2026-11-23): a successor chain must retain each verifier's immutable
identity and publication, bind each new request to its predecessor, and hold
the complete predecessor retirement chain while independently observing the
same namespace. A new versioned controller identity may use a per-execution
slice; the existing static-slice identities and wire formats must never be
reinterpreted. This follows the exact-identity and independent-observation
contract in [lifecycle.md:59](../documents/engineering/lifecycle.md) and the
bounded self-heal requirement in [plan standards:94](development_plan_standards.md#evidence-and-live-campaigns).
No successor is authorized merely because a prior outcome is absent.
The new successor identity and key-derived slice are only a foundation; no
successor request or public launch is wired. Native publication codec checks
and all 30 submission controls passed, including old codec round-trips,
wrong-kind rejection and distinct slices for distinct successor keys. The
retained verifier and node remain unchanged.
The successor request now has a canonical predecessor-bound format and a
bounded structural chain check; the manager-backed fixture passed its first
immutable successor locator/publication checks, including refusal to treat an
unpublished link as settled. These checks do not establish physical
retirement of a successor or authorize a public send.
The successor's exact-submission retirement boundary now has a controlled
manager test: a live registered sender was refused, and after that sender
closed, exact family retirement and published-input retirement were observed.
The same fixture passed the one-successor chain boundary with its active
sender refused and its settled owner held and rechecked around the callback.
Fixture SHA-256:
`140aef4b9a8b5f503e78afe98fb11dcb936311cec9a06aecc8fbd02f1a26ebf1`.
Multi-successor evidence and public successor dispatch remain open.
The staged-successor check also passed: an existing unpublished locator was
accepted only as that exact staged identity, and was refused as a fresh
transition. The controlled manager fixture now also passed a two-link chain
containing a retired submitted family and a separately held never-sent
publication proof, including exact input retirement. Fixture SHA-256:
`269ef4780c9dd955ed063d62eb2015bea3eb75e9505b3ef93f0208ff5b23ae56`.
The controlled fixture also passed a third, pre-publication-cancelled link:
its cancellation fenced a later publication and the complete mixed chain was
rechecked. Fixture SHA-256:
`edaa95d0bb0efcd8e964c1b1462bc0b0a6ed9ec6e75f2ab22f41f9997cfed7ba`.
Public cancellation and successor recovery orchestration remain open.
The successor publisher was subsequently changed to establish its durable
publication owner before writing the send-attempt marker. A cancelled staged
link must now also establish exact publication-directory absence or hold a
never-sent owner and retire its inputs. Those new ordering and cleanup checks
are under qualification; they do not alter the retained failed verifier.
The updated manager fixture passed both cancellation cases: an exactly
absent publication directory and a created-but-never-sent publication whose
inputs were retired under a held proof. Fixture SHA-256:
`26c7ece8356eed5753e943e7fbe040e7e4a833f661b3fabc104a0523cb138947`.
The expanded fixture also passed pinned successor input decoding and rejected
the same publication as the older verifier kind. Fixture SHA-256:
`b595711a427539fc8f114f5503b72f02394f01e21a1bfad19ca2e6a500d72fe3`.
Public successor recovery and terminal-readback cleanup have since been wired
for qualification. A controlled public-command fixture is in progress; it
must prove the never-sent, cancellation, active-family refusal and successor
readback cases before a new live recovery is considered.
The first expanded run stopped because the disposable fixture left its prior
readback file in place when switching scenarios; the fixture cleanup was
corrected. This is not a live or acceptance result.
The corrected manager-backed fixture then passed the complete controlled
sequence: wrong-digest publication was proven never sent, a staged successor
was cancelled, a live successor blocked delete, and recorded successor
readback was accepted by public delete only after the full chain settled.
Fixture SHA-256:
`70d12b9d1d0af42f6a6ce6b7e25c7a6b4716c89e1067a82d4d190546bb2744a4`;
the public binary used by the fixture was
`beb922b0665e8da0c585e307d5cd541a74653d44ad09b88ed031e83a3e1bbf88`.
The subsequently built binary
`70201e3c823a6a3af80ce4dbb38db0877035fc0a8238f29406ce2c224f432045`
adds only descriptor-close masking to the exact publication-directory
observation; its focused cancellation fixture also passed. This is controlled
evidence, not real Kubernetes readback or Phase 1 acceptance.
Before the next live recovery, the same nested-admission timing class was
removed from the successor chain and readback snapshots. The focused fixture
passed with a 250 ms admission check and refused admission that changed
across the snapshot; fixture SHA-256:
`2885da13c36eb53240ebf56ce4126abcb7a1d5ae851e5dab4811e1a4a85502b8`.
This does not identify the earlier verifier's unrecorded failure.
The complete public-command fixture then passed again with the timing changes.
The binary SHA-256 was
`d4c5fd554487349ab9510049e6df14b84c09a7f3413facf898a5559ed79d76a4`;
the fixture SHA-256 remained
`70d12b9d1d0af42f6a6ce6b7e25c7a6b4716c89e1067a82d4d190546bb2744a4`.
This still does not prove real Kubernetes readback or close Phase 1.
The next in-hand public delete (2026-11-23), using that binary, submitted
successor `f8dabe12d0e591314c76aaa23aba891a` and independently observed its
retirement. It produced neither a successor readback nor the best-effort
diagnostic record; the manager recorded exit status 1 and 11.594 seconds of
CPU time. Public delete retained the node and returned incomplete. Output:
`.build/phase1-successor-recovery-20261123.log`. The exact failure stage is
unobservable; the prior timing reproducer does not establish its cause.
Preserve both verifier identities and review the repeated missing-diagnostic
class before another live send.
Class review (2026-11-23): both managed observers exited unsuccessfully
without a durable diagnostic, so their exact failure stages are unknown. The
earlier slow-admission reproducer justifies the snapshot timing correction but
does not identify either live failure. Successor controllers now return fixed,
non-secret manager exit categories even when pinned input fails before a
scoped diagnostic can be written; an uncontrolled crash can still be
unclassified. The focused public-entry fixture passed an exact pinned-owner
refusal category and the pure category mapping. Its first run expected a
digest-stage refusal, but actually observed the earlier owner mismatch; the
assertion was corrected. Fixture SHA-256:
`6557664439fc02ad9504da952124b461105a1fa789a50a90e0196db1ddf064c4`;
binary SHA-256:
`b5b48d268603813f196c7212c96f4e8c0f94a0319df9fee11f78c89decc5dd22`.
Sibling state: the original verifier and first successor remain recorded and
retired, with neither readback recorded; the node, network, volume and scoped
root remain in hand. No manual cleanup or successor replacement occurred.
The next in-hand public delete (2026-11-23) submitted successor
`8f6830342fba47eb4f19c4f0f8a99798` and observed it retired. It recorded
`VerifierLeaseUnconfirmed`, and the manager recorded exit category 26; no
readback was written. The node and its test resources remain retained. Output:
`.build/phase1-successor-diagnostic-recovery-20261123.log`. This category
covers more than one lease boundary, so it does not yet establish which lease
failed or why. The original verifier and both successors are immutable chain
members. Review and reproduce the contention class offline before further
live submission.
An offline control held the exact scoped operation lease and reproduced the
nonblocking `KindLeaseBusy` refusal on a competing recovery call. This proves
the contention behavior, not that contention caused the live category 26.
The diagnostic categories are being split by original, cleanup, first
verifier, chain and worker lease boundary before a bounded retry is tested.
The controlled fixture now passes a real manager-backed family-retirement
handoff while the operation lease is briefly busy, plus held-lease deadline,
pre-expired deadline, callback-once and split-category checks. The retry
applies only to a confirmed `KindLeaseBusy` before callback entry; other
refusals and uncertain closing states are not retried as success. Fixture
SHA-256:
`6e841596d5edb19762bb45396e34c23c77c51cd666c77eaa186717c7b4df8701`;
binary SHA-256:
`4def674bd644861fd7de2991f50fb5599a9b9649ef82de849a841f43d8fea367`.
This establishes the controlled contention behavior, not the exact cause of
the earlier live category 26.
Three-attempt recovery class review (2026-11-23): verifier
`a8e26645a5b02fb0b006439e73ecb3c2` and successor
`f8dabe12d0e591314c76aaa23aba891a` retired without a recorded failure stage;
successor `8f6830342fba47eb4f19c4f0f8a99798` retired with the broad
lease-unconfirmed category. None recorded namespace readback. Read-only
manager inventory after the last attempt listed no units matching the
`prodbox-kind-verify*` and `prodbox-kind-successor*` name patterns; it did not
inspect slice names. Exact Docker inspection reported node
`68fec6d8c89cb4cd246be1fbe261a9faa3b37c78034cb536c4246c46f32b0598`
running. These observations do not prove resource absence. The retained
locators and publication records remain chain members; no manual cleanup was
performed. The offline busy-lease reproducer and bounded wait address a
plausible contention class, while the new split categories preserve the
actual failure stage if a future controlled run returns one. The combined
public fixture is being rerun; no next live attempt is qualified until it
finishes.
That combined public fixture subsequently passed with binary SHA-256
`4def674bd644861fd7de2991f50fb5599a9b9649ef82de849a841f43d8fea367`
and fixture SHA-256
`70d12b9d1d0af42f6a6ce6b7e25c7a6b4716c89e1067a82d4d190546bb2744a4`.
The controlled evidence does not establish why the earlier live lease was
unconfirmed or prove any live namespace absence.
The subsequent in-hand public delete (2026-11-23) submitted successor
`4b694442d6294d1e769f5575e7d2bddf`, observed it retired, and recorded
`VerifierAbsenceUnconfirmed` (manager exit category 32). No readback was
written; the node and its test resources remain retained. Output:
`.build/phase1-successor-lease-wait-recovery-20261123.log`. A separate,
read-only `kubectl` observation of the selected kubeconfig obtained matching
`kube-system` UIDs around an empty field-selected namespace inventory, but
the actual client response used `apiVersion: v1`, `kind: List`, while the
current decoder accepts only `NamespaceList`. This independent point
observation is diagnostic only; it is not a managed-family readback or cleanup
proof. A controlled regression is being run before changing the decoder.
The controlled regression first failed on the observed empty `v1 List` shape.
After allowing that shape for the explicitly field-selected namespace query,
the same test passed for both cleanup and successor readback; nonempty lists,
wrong versions, wrong kinds, missing items and unavailable positive controls
were refused. Fixture SHA-256:
`23f44e1f310c99bd2f732aca041dfdaf445824d277da06c3ff7742f7484c318d`;
decoder SHA-256:
`8670b2e318bcfe3e883fb70d779e812a8aca955b170c52c0d30c854fa7b615c5`.
The real worker still must independently perform and record its own readback.
The next in-hand public delete (2026-11-23) submitted successor
`fbb16e4b440edf54413ca0d0b70bf8d7` using binary SHA-256
`6bb7933e4ae34f6416bad945ecc94fd54e122cd1a8a7593e37170165593d4d0f`.
The successor retired and recorded `VerifierRecordRefused`; it did not write
the readback. Public delete retained the node and returned incomplete. Output:
`.build/phase1-successor-list-recovery-20261123.log`. This category does not
yet distinguish refusal, partial write or an existing record. The prior
verifier and all four successor identities remain chain members. Reproduce
and narrow the readback-write failure offline before another live submission.
An offline multi-link fixture reproduced a pre-write `ProbeRefused` with a
two-second admission check under the prior ten-second writer deadline. This
shows a reproducible timing class; it does not establish which write outcome
the live worker saw. The writer and closing read are being bounded at 60 and
30 seconds respectively, with the readback itself bracketed by the retained
operation admission. Separate fixed diagnostic categories now preserve
refused, already-existing and incomplete write outcomes.
The same multi-link control then passed: the two-second admission check wrote
and read back the exact record within the new bounds, and admission changing
after a separate diagnostic write returned `ProbeIncomplete` while preserving
the written record. Fixture SHA-256:
`766bb245b23b62281c19db165292f8432e847ecb8a3ed2b051b3e3e7a9000a36`;
writer SHA-256:
`3a2160e6361682be3565381bb7c7e54a58160f6fe0ba96947d80ca0218e7d9b8`.
This remains a controlled timing-class result, not a reconstruction of the
live worker's unrecorded write disposition.
The complete controlled public-command fixture subsequently passed with the
readback-writer changes. Binary SHA-256:
`0dd2a7de93dee1113114b537d10fb65018794cca69d96f444d626f5e7676ac06`;
fixture SHA-256:
`70d12b9d1d0af42f6a6ce6b7e25c7a6b4716c89e1067a82d4d190546bb2744a4`.
It does not prove the live namespace result or close Phase 1.
The next in-hand public delete (2026-11-23) submitted successor
`184445562ba8b2cfba32ef5b0d456a71`, observed it retired, and found no
readback or diagnostic record. The manager recorded exit status 251; public
delete retained the node. Output:
`.build/phase1-successor-readback-recovery-20261123.log`. A separate,
non-secret synthetic GHC program under an 8 MiB heap limit exited 251 with
`Heap exhausted`. The live controller was configured with a 64 MiB heap cap,
but its stderr was discarded, so status 251 alone does not prove its cause.

Live-campaign class review: the three attempts since the preceding review
reached, respectively, an unconfirmed namespace observation, an unconfirmed
readback write, and an unclassified exit 251. The real `v1 List` mismatch and
a slow readback-writer refusal were each reproduced and corrected offline; the
latest exit has only the synthetic RTS correlation above. The original
verifier and all five successors remain recorded chain members, and the
test node and its network/volume remain in hand. No next live send is
qualified until the memory/runtime class is reproduced against the actual
non-secret composition, its resource envelope and cleanup are reviewed, and
the relevant controlled checks pass.
An optimized synthetic fixture using the same non-secret record and retirement
modules passed under `+RTS -M64m -N1`; its test Docker path was nonexistent,
and its process environment contained only `PATH` and `HOME`. Fixture binary
SHA-256:
`24b7bc6ed53f05ffa24e87afd73195f37963f751eb9a50e89294fc3b863496bd`;
source fixture SHA-256:
`766bb245b23b62281c19db165292f8432e847ecb8a3ed2b051b3e3e7a9000a36`;
output `.build/phase1-rts-probe-64m.log`. This run did not execute the exact
live managed worker and therefore neither reproduces nor rules out its exit.
An exploratory 11-link run under the same heap cap completed, but most links
were synthetic pre-publication cancellations rather than the retained live
chain's submitted families. Its peak GHC residency was about 2.4 MiB. It is
not an exact reproduction; the fixture is being extended to hold multiple
independently retired submitted-family owners before deciding the envelope.
The expanded 11-link fixture with seven submitted-family records and four
never-sent/cancelled dispositions also passed at 64 MiB; maximum GHC residency
was about 2.4 MiB (`.build/phase1-rts-probe-physical-scale-64m.log`). It did
not execute the managed worker's readback writer. The next isolated case adds
that writer while all predecessor owners remain borrowed.
That extended isolated case passed with `+RTS -M64m -N1 -s`, reporting
10,765,664 bytes maximum heap residency and 30 MiB total memory in use; output
is `.build/phase1-rts-probe-readback-scale-64m.log`. Fixture source SHA-256:
`303c0cd90c0fb95373ede023f0f93f3b163c2e05e02ccbb29e5bcc5c68b5f2a6`;
optimized fixture binary SHA-256:
`1a435958ccb792643ca5676d7de831d512f6ae3437454f180dc5b205f7c80b88`.
It holds the synthetic predecessor owners during the actual readback writer,
but does not include the complete original family, Kubernetes subprocess, or
the managed public worker. It therefore does not explain exit 251 or qualify
another live send.
The next isolated case additionally held the original, cleanup and first
verifier retirement owners and rechecked their admissions with every chain
admission. It passed under the same cap with 10,526,608 bytes maximum heap
residency and 29 MiB total memory in use, and retired its synthetic parent and
successor inputs. Output: `.build/phase1-rts-probe-full-family-scale-64m.log`;
fixture source SHA-256:
`392b0e084bf47a8252420cb2cd4eb65908886446cfd23882eb0a26b91d5afe99`;
fixture binary SHA-256:
`1f43ad8dd883473e414fbde7f6b092e5f5ca62f6e2bac8219a0e410117f87769`.
The real managed worker, node/CA binding and Kubernetes subprocesses remain
outside this synthetic case, so the exit remains unclassified and the live
send restriction remains in force.
The same rebuilt fixture's ordinary regression path also passed under the
64 MiB cap (`.build/phase1-rts-probe-regression-20261123.log`), including
bounded lease waiting, slow and changing admission, successor retirement and
input recovery. This is controlled evidence, not a live acceptance result.
An optimized isolated sealed-kubeconfig TLS test also passed at 64 MiB,
including real `kubectl` against a disposable loopback endpoint and rejection
of a different CA (`.build/phase1-rts-tls-64m.log`, source SHA-256
`085fff9da8e73ca14b154db1b029d564ccc6b6db407588755b70e7dc5ac0ad85`,
binary SHA-256
`fdc2bd4b426512b07643eaa6097c37b3daaf9af4b0cb00b5c6eca4f764dc0bc2`).
The expanded parent-and-chain fixture now also takes a sealed kubeconfig
snapshot and makes three bounded real `kubectl` TLS requests to a disposable
loopback server, bracketing them with kubeconfig and retained-family checks.
It passed at 64 MiB with 10,521,104 bytes maximum heap residency and 29 MiB
total memory in use (`.build/phase1-rts-probe-tls-family-scale-64m.log`,
source SHA-256
`24f22a222a9232b731a618618032442a3e809a25a1d42046c39e8e1b545f6915`,
binary SHA-256
`3680403b7ac28d3b35453b91dc28a7834828cfef0db745571de89d32fdeae450`).
These are raw readiness requests, not namespace inventory, and do not exercise
the actual managed subprocess family or Docker node/CA binding. The live
exit therefore remains unclassified and no new live send is qualified.
The subsequent isolated case used a disposable loopback TLS Kubernetes API
fixture and the actual `confirmAttemptedProbeAbsenceWith` sequence: real
`kubectl` performs the two positive-control reads and selected namespace
inventory, then the readback writer runs under all parent and successor
retirement admissions. It passed under `+RTS -M64m -N1 -s` with 18,874,056
bytes maximum heap residency and 43 MiB total memory in use. Output:
`.build/phase1-rts-probe-namespace-family-scale-64m.log`; source SHA-256:
`a751d0ede0e47f71ea5a45fa75270492a90edcbe8ffd27c86a4754435fc88428`;
binary SHA-256:
`a24231edb6e9e4156edf6df9e7e02a79d1d2c7e99a7ae3cb36c9b46c5442fa41`.
It uses the bounded standalone subprocess capture and synthetic API rather
than the managed subprocess family and actual Docker node/CA binding. It is
not a reproduction of the exit or qualification to send another live worker.
The ordinary fixture path also passed after that change under the same heap
cap (`.build/phase1-rts-probe-namespace-regression-64m.log`).
The successor worker and separate readback record are under construction: they
require the complete recorded predecessor prefix, its held retirement owners,
the original node/CA binding and a positive-control-bracketed namespace
inventory. These paths have not yet been qualified through the public
command, and no successor has been sent.
An initial chain-fixture rerun refused an existing synthetic publication
because it reused fixed fixture keys. The test now generates distinct scoped
identities for each run; the earlier terminal fixture publication is
retained. No provider or Kubernetes effect was submitted by that fixture.

2026-11-23: The public family completion path now waits within its existing
bounded observation deadline when the exact recorded family is still present.
Unobservable or changed identity remains a refusal; expiry retains the last
observation. A controlled-clock qualification exercised retry, immediate
refusal, and deadline behavior; it does not establish real family retirement.
The test fixture also has a settled-publication cleanup path gated by exact
scope, retirement and no-effect observations. Its refusal of an unsent
publication was exercised; successful submitted-family cleanup remained
unqualified. At that point the kind submission guard was still active, so
that work did not create a kind node or satisfy phase acceptance. Existing unclassified
runtime publication directories remain untouched.

Subsequent controlled manager attempt (2026-11-23): the bound publication
and manager admission path was enabled for kind. A public reconcile using a
private fake Docker endpoint and deliberately absent artifacts submitted
operation `d1606244f4fe62003f771c4db023940b` to the user manager. The
controller ran and recorded `FamilyPostPreconditionFailed` with
`FamilyWorkerNotStarted`; the fixture timed out before reporting its Docker
request log, so that log is not evidence. The manager retained the original expiry timer after controller
exit, and the old 120-second fixture deadline terminated the caller before
the 510-second hard deadline. The test failed and preserved
`/tmp/prodbox-family-reconcile-b45c2fc7223246b8` and the corresponding
publication for recovery; their presence is not absence or cleanup evidence.
The attempted operator binary SHA-256 was
`301708c5d4e42b86bee298bf86b99bbd7043120ba52649c8afa433702150184a`.
After the original timer elapsed, the manager listed no remaining units for
the operation. Public test-scope delete retired the family inputs and reported
no node or volume attempt, but refused the network step because no network
identity was recorded. The network no-attempt path is being corrected to
require the settled owner-first protocol, stable lease, and independently
read absence of all five network records; that result describes an unstarted
effect, not independent Docker absence. The failed public delete and retained
test root remain evidence until the corrected recovery is exercised.
The corrected public delete subsequently returned success for that same
operation, reporting the node, volume and owner-family network as unstarted.
The original manager roles had already disappeared. The fixture root and
terminal publication metadata remain retained for diagnosis; the fake
Docker request log was lost with the failed fixture, so this is not a real
Docker absence observation or Phase 1 acceptance.
The family definition is being changed to retire its timer when no dependent
family unit remains, and the fixture deadline was lengthened. These changes
are not yet proven by a subsequent manager run. No real kind node was created.
The public completion path has also been connected to its existing positive
family-readiness predicate: success requires the retired family, matching
node and kubeconfig CA, authenticated readiness before and after the recorded
network proof, and stable closing observations. This implementation change is
not a real Docker/TLS or kind acceptance result; those controls and the
public success path still require qualification.
With the timer change, the controlled public-command regression then passed in
5.64 seconds. It observed no fake-Docker POST or DELETE, required exact
manager-family retirement and input teardown, and removed its own publication
metadata; the count of existing runtime publication directories remained
362 before and after. This is a real manager submission with a fake Docker
endpoint, not real kind acceptance. The current operator, family, delete,
app and integration-test source SHA-256s are respectively
`337aa8c6fbc916adf37a8270e5c6c99cb8b3b9f461aad438f2c661b78de03230`,
`5f2684fef7df21b62d5a36dd6878b24d54131b069091b4359acdf56b9c1203cf`,
`7ede4a147f2fad52d8377db58570d3aa7c89856e3edcd44c0eb5a10bd7646594`,
`beb040bb71f148204510daa082f41a2f67f2ca857b88ff0192e37e31d82be083`, and
`2a88b891e81def8db5e2aa42b2d75682ffe8b27f551ad99b11c98008263ecc65`.

Real harness attempt (2026-11-23): `prodbox test run phase-01` prepared
test identity `run-86119e1c087015844638fda514f90e2d`, imported the pinned
image, and submitted operation `5a0fe550233eddfe3e61769053fcb846`. The
family recorded an image load reply but did not reach node creation; its
dispatch summary recorded a prerequisite failure with unconfirmed parent and
input closing. The harness continued into sibling scenarios after the initial
failure and exited with failed acceptance and unconfirmed fixture cleanup.
The complete non-secret output is
`.build/phase1-owner-family-live-20261123.log`; the selected test root and
`.build/phase01-fixtures-fc09de386d0a19f99e09ed2569e2ab9a` remain retained.
Once manager units disappeared, public delete completed for the main and both
sibling operations, reporting no node, volume or network attempt. Read-only
Docker inventory subsequently showed no containers and only the default
networks. The imported pinned image remains present. These observations do
not establish a successful lifecycle, or exact cleanup of all retained fixture
files and publication metadata.

The bounded completion wait now re-observes an unconfirmed operation lease
without treating it as retirement, and the harness is being changed to stop
after an unsuccessful first reconcile rather than launch later scenarios.
The retained dispatch summary is also being extended with bounded prerequisite
stage names so a future failure identifies its stage without recording arbitrary
exception or subprocess text. These changes need validation before another
real attempt.
The controlled-clock qualification passed the live-family, unconfirmed-lease,
deadline and diagnostic-stage cases. The public manager regression passed
again, and a public delete adverse test refused an orphan network-attempt
record. Running the selected-scope harness against the retained failed
operation then stopped after its initial reconcile, reported the original
failure and public cleanup separately, and removed its empty fixture
directory; it did not start sibling scenarios. Its output is
`.build/phase1-early-stop-regression-20261123.log`. These are regression
controls, not a real kind success.

Second real harness attempt (2026-11-23): test identity
`run-bc5bcfb9c7b6a4d6ddda0ea4745ce50f` submitted operation
`dc1729bbbcea61e01be3ce57c1d02ff9`. The public caller remained active until
the family retired, and the early-stop path prevented sibling scenarios. The
bounded result recorded `FamilyPostImageAttemptFailed` with complete parent
and input closing. The retained transport receipt says HTTP 200 with one
progress message; a later read-only public image inspection independently
observed the expected linux/amd64 image through both connected and CLI reads.
Those later reads do not prove the earlier admission or readback. Public
cleanup reported all node, volume and network effects unstarted, and the
empty fixture directory was removed. The root and loaded image remain. The
full output is `.build/phase1-owner-family-live-2-20261123.log`; the clean-image
case was explicitly unproven because the preceding attempt loaded the image.
The image-attempt failure must be classified and reproduced before another
real attempt.

Offline image-result timing control (2026-11-23): a private test scope with a
synthetic daemon identity and no Docker effects supplied a slow, successful
admission recheck. The original ten-second writer returned
`NodeImageResultIncomplete` even though a subsequent normal-speed read found
the exact durable HTTP 200 result. This reproduces a timeout class consistent
with, but not proven to be, the real failure. The writer and nested observer
are being given separately bounded windows so the closing read fits inside
the writer's budget; operation admission remains checked. Positive and changed
admission controls and a real regression remain required.
With the revised 60-second writer and 30-second nested observer budgets,
the same controlled slow-admission case confirmed its durable result, and a
false admission was refused. The family result now distinguishes bounded
image result, readback, transport and closing failure categories for a future
attempt. This does not prove that the timeout was the real cause.
The rebuilt executable and integration suite passed, as did the controlled
manager regression and bounded wait/diagnostic qualification. The current
operator, image-result recorder, reconcile module and timing-control source
SHA-256s are respectively
`46859bb27cb1e49f7e1b9d3b4e29e78cea1f9abe48254a7ca93dffa219529ed0`,
`c67f9c0611dbb9f81fd84f7554cb65dfb7741ab9a7ada4495d7e832f030cf87c`,
`da2f45fca4e572512b63ab42e61f7e33b3040fffa0bb9d1d08090cbbebabf10f`, and
`acff33ab6048da132d85ab44bf99c6e6e8430d75f866253700e7eea37dc0eef5`.

Third real harness attempt (2026-11-23): test identity
`run-c76b2e9a5abb136795ab95c24eac4720`, operation
`ddbc58a0c2a369da496f588ce3fc619f`, passed image preparation and created
and started the exact scoped kind node. Its worker completed, the independent
readiness check returned true, but the family recorded `FamilyPostProbeFailed`.
The harness stopped at that first failure; public cleanup timed out in its
connected node-removal callback and retained the root. A node-removal positive
control was recorded; no removal-attempt record was observed. The node remains
running and the network and volume remain in scope. Output is
`.build/phase1-owner-family-live-3-20261123.log`. This is not acceptance or
cleanup proof. Recovery is being amended to revalidate the exact existing
positive control and use a larger bounded connected cleanup window; the
exclusive attempt marker still precedes any delete. The in-hand operation must
be driven to a verified recovery disposition before another live attempt.
The first public recovery retry revalidated the existing control but refused
before recording a removal attempt. A subsequent read-only check under the
retired family and recovered operation lease observed the exact control,
missing attempt and a matching positive node sample, including on the held
Docker peer. Those are point observations, not a delete authorization or an
absence proof. The refusal is being split into bounded prior-record,
positive-control and attempt-write dispositions to identify the failing
boundary; the node remains in scope.
The next recovery attempt returned `NodeRemoveAttemptWriteUnconfirmed` before
writing an attempt. Review found that the empty-probe admission repeatedly
rechecked the complete family retirement inside each nested local journal
read. The implementation now brackets the local snapshot with the retained
family/lease proof instead. With that change, public delete recorded and
received 204 replies for the exact node, named volume and network. Separate
Docker inspections by the recorded container ID, network ID and volume name
then returned not found; label-filtered inventories were empty. The loaded
image, test root and terminal records remain, and these point observations do
not establish anonymous-volume cleanup or Phase 1 acceptance. The connected
Docker controlled regression passed (one test, 112.34 seconds).
Before removal, a separate read-only diagnostic observed the exact recorded
daemon, running-node configuration and matching CA archive. Its full binding
predicate was false because the removal positive-control record had already
been written; this later sample cannot establish the earlier probe failure.
The probe had not recorded a namespace intent. A controlled slow-admission
check against an isolated Docker fixture reproduced a five-second node
observation timeout and a false CA-binding result despite matching inputs.
The node and CA observation budgets have been increased, and the full
API/node binding now brackets probe journal writes while the family admission
remains checked inside them. The node's local record snapshot is likewise
bracketed by the held lease and Docker peer rather than recursively repeating
the full family proof for every journal read. A changed closing admission
still refuses further work. These changes are awaiting their post-change regression; the controlled
timeout is consistent with, but does not prove, the original probe cause.
The post-change connected-Docker regression passed (one test, 99.93 seconds):
the slow valid node and CA observations succeeded, a changed closing
admission was refused, and the existing conflicting-CA control still failed.
The injected probe-record admission control also passed its initial-refusal,
changed-closing and stable cases. The public success message now exposes the
network-policy proof only when the complete readiness predicate succeeds.
Real probe behavior remains unqualified on this build.
The rebuilt operator also passed the controlled managed-family regression.
The operator, node-status, network-enforcement and integration-test source
SHA-256s are respectively
`5afbc72b7b7e7d6a0bc954be3bf2db9c2c0138437f43d5797458cd4a10e4cbc2`,
`a99f5a6357f6cd5117a45a629953cd368b2c3dee3cc343bd92fe9204542bf066`,
`a897f7300cfc6deeccd1688167e3a7601b521464f0ee6f489483486cb8dbbf39`, and
`f7255bb7e392c5c5ee3c01c2cd364ef2f177cfc01e32b2663b81afdfbc0e135c`.

Fourth real harness attempt (2026-11-23): test identity
`run-8ed37a47517681445196124f548a187b`, operation
`c53cc7b94a8c91c5e4532ab30ac497a2`, passed image, network and named-volume
creation but reported `FamilyPostNodeIntentFailed` before a node intent was
recorded. The harness stopped at the initial lifecycle and public cleanup
received successful volume and network removal replies. Separate Docker
inspection of the exact recorded network ID and volume name returned not
found; a scoped container inventory was empty. The test root and loaded image
remain. Output is `.build/phase1-owner-family-live-4-20261123.log`. This is
not an acceptance pass. The node-intent failure requires class review and an
offline reproducer before another real lifecycle attempt.
A read-only reconstruction using the retained configuration, image ID,
network ID and currently observed daemon successfully constructed the node
intent. This rules out a permanently invalid retained input, not a transient
daemon or admission failure at the original time. The intent writer also has
the same nested ten-second admission/read-back budget pattern as the earlier
image-result failure; that timing class is being tested independently.
Class review after the last three real runs: the second stopped during image
result confirmation, the third reached node readiness but failed before probe
intent, and the fourth stopped before recording node intent. The latter two
performed their own failure cleanup; exact node/network/named-volume read-back
for the third and exact network/named-volume read-back for the fourth found
those recorded resources absent. Their roots and the shared loaded image remain.
The common concern is nested, bounded admission work rather than a proven
single cause. Sibling node, network, volume and probe recorders still have
their own deadlines and remain subject to their own tests; they have not been
globally relaxed. The managed prerequisite call is being changed to avoid
wrapping the owner-first protocol check twice, while retaining that check in
the prerequisite coordinator and node worker. No further live lifecycle is
qualified until these changes pass their controlled checks.
The private slow-admission node-intent control reproduced a pre-write refusal
under the original ten-second limit. With a 60-second writer and a 30-second
closing reader, the same control recorded and read back the exact intent;
false admission still refused the write. This is an offline timing-class
reproducer, not proof of the precise fourth-run cause.
The executable and integration suite rebuilt, the controlled managed-family
regression passed, and the bounded wait/diagnostic qualification passed. The
operator, controller, node-intent and timing-control source SHA-256s were
`1f94fedf8ebc815c48be7355fc446e0c52285ac0c1cd4eb536e40348ed54b6e4`,
`32012fb43105e72e5bdfabad9a98afd2c4f4c049a872cc698a0994e51d63c50c`,
`4ef58ee637a1a185dbc77c0bd4d6da27995cd236e5a97edc08c044b2585151a5`, and
`2506e837796bdf4a2a20792e283bf06af04b6358b324f18186af0eaf4fb04e55`.

Fifth real harness attempt (2026-11-23): test identity
`run-7ae426bc5f920fb9fb91a516f104e4f7`, operation
`e69453b00acc4c3133b7e9730a381844`, passed the node-intent boundary,
created and started the node, and reached the probe namespace creation record
for UID `4c58a565-fc9e-460f-9dd8-6b29ecfc6afb`. The probe did not record
removal; public delete retained the node and refused cleanup. Read-only
diagnostics later found the exact node running, its recorded Docker identity
and CA binding matching, the `kube-system` positive control reachable, and
the probe namespace name not found. That individual lookup is not a recorded
absence proof. The full harness output is
`.build/phase1-owner-family-live-5-20261123.log`. The node, network, volume,
test root and records remain in hand; no manual cleanup is authorized or used.

The public delete path is being extended to launch or resume the separately
identified managed probe-recovery family only after its existing retirement
and journal checks. For a namespace already absent, the worker must obtain a
structured empty inventory bracketed by the same live API positive control,
record the exact UID's cleanup, and itself retire before node removal. These
changes and their negative controls are under validation; the live operation
must be driven to a confirmed recovery disposition before another lifecycle.
The controlled absent-namespace case recorded cleanup only after a matching
positive-control-bracketed empty inventory; unavailable inventory refused and
issued no delete. The executable/integration build, managed-family regression,
bounded qualification and HLint passed. The current operator, delete and
network-enforcement source SHA-256s are
`a2486e954e25201d4322ad81d81a26de47d6d1222a051749b97520912c265f36`,
`fd85b1a3b73c15c26ac53ef7b8f46ada15a3bd6600751523eabc57ec134847ca`, and
`e277992410cba9de5e6c0ea5d77e16080db72715f402e05bda9c3daa877352a4`.
The public delete recovery submitted distinct cleanup identity
`490f6edcb91dff3bea7d8991930f5cc2`, but its original-family closing check
reported `RetirementRolePresent OperationSlice`: both families currently use
the same kind slice. The manager subsequently listed no remaining kind-family
units. No probe removal receipt or recovery-attempt marker was recorded, and
the node remains running. The recovery locator and possible-send publication
are retained; they cannot be treated as never sent or replaced. Output is
`.build/phase1-probe-recovery-20261123.log`. Slice isolation and a safe
successor rule for this already-submitted recovery must be implemented and
validated before cleanup can continue.
Subsequent public delete observed the cleanup family retired and retired its
exact published inputs; its terminal metadata and locator remain. The public
path now refuses new cleanup sends while the shared-slice defect remains.
The node and the recorded namespace cleanup remain unresolved.
The bounded-wait qualification executable returned success; HLint and
`git diff --check` passed. The rebuilt focused unit group passed 73 tests;
the public owner-first refusal regression passed one test against the rebuilt
operator (the integration executable predated the wait change). The operator
binary, recovery module, app module,
fixture cleanup module and wait qualification source SHA-256s were
`189341e7f346cdf5ba78286948366bbe22231601a4e0c947f4b8aa34da9264fe`,
`f1e654a0a1f176441c6992b1060ce30a21ff58c121e8a55c5c0379b4fb6d9cf7`,
`6ac537e967f68732aae99435439ee366b56e3dcdabe89c6d4dc4ed384500b524`,
`c8cc93fc7a68c595f8fd8bcc00d6919dccbb908e9abba1ec94527ab98261ea8d`, and
`f3b4751701b1e5b6aff5a38161eddcc9ce6a53c031b7a3e380df692565fb60bd`.

`control status` now provides a partial public read-only diagnostic using the
selected bootstrap projection and its explicit Docker socket. It observes the
candidate root and generation record, queries both the expected control-plane
name and kind cluster label, and checks the named container's label and bind
mount when present. A mismatch is reported as foreign or multiple; runtime
query errors do not become absence. The output explicitly leaves Docker executable identity, Kubernetes
readiness, network policy, image provenance and cloud resources unchecked. It
does not create or repair a cluster, establish ownership, or prove full status.
The selected bootstrap setup path described below can author a new production
or test root record; status can also read an explicitly authored bootstrap record. The
generated structural schema described below remains an authoring reference.

The public binary was exercised against the real local Docker socket with a
disposable test identity and no cluster creation. Independent before/after
label inventory stayed empty; an unrelated marker remained unchanged; no run
root was created; deliberately invalid ambient Docker/kubeconfig settings did
not select the target; a selected non-socket was refused. The scoped fixture
and output are `.build/phase1-control-status-live.py` and
`.build/phase1-control-status-live-reviewed.log`. A synthetic Docker-inspect
fixture checked matching, foreign-label and wrong-mount interpretation. All 13
scope/bootstrap/status cases passed in `.build/phase1-control-status-unit-reviewed.log`;
348 parser checks passed in `.build/phase1-control-status-parser-reviewed.log`.
An initial build found an ambiguous test-fixture type, which was corrected;
the final build passed in `.build/phase1-control-status-build-reviewed.log`.
The generated CLI reference and command disposition manifest were updated.

The tested status, bootstrap, CLI command, registry, app, scope-test and
parser-test source SHA-256s are respectively
`734dab03cb948ced0ff750bd57549c71b690ae6e05ee58150971fb0e1df99e0f`,
`c96546ddcd1dbb2b1d4547fe9d12ae2be29cbc5b2756a2c70bcb5f94fa835a96`,
`eb38d380af8156885c13c8ce83966dd2fe023f84c5243ae3cfc48f5c92de2899`,
`2ec85d08f6d31d073c6d9722f4029d0ab37f0457a5588b53dbbdd10482e35f20`,
`077ca0e8ff6b700852248488c68b8c52b6624eb9066eb0ed21b1f2a67f0c16d3`,
`b862242434af5b616c72bb478e4fd91160f1231099a7fa0f45215dd58d22fd3f`, and
`32a045f8eea73bdaeb322328c32f995ebce78cd8325f83faf89c6b33f3b169d9`.
The retained operator, unit binary, and live fixture SHA-256s are respectively
`4af8f637d234bdf6d182ccea995a7a84e2624e197e69591f3de416879419197b`,
`adc8ef30b7708c4fb71644f898f1687371e78c616c40b8e454353c9cb9b9fe50`, and
`53e15a1202adf31a5d5227d007d974a6547bd03744ccc50e8d20b37e101de912`.
This is not A01-01 or Phase 1 acceptance: no real kind node, mount recreation,
enforcing CNI, capacity envelope, removal or mutation calibration was proven.
After that reviewed build, the status output was tightened to name Docker
executable identity among the unchecked observations. The 13 unit cases, 348
parser checks, and real read-only probe were rerun in
`.build/phase1-control-status-unit-final.log`,
`.build/phase1-control-status-parser-final.log`, and
`.build/phase1-control-status-live-scoped.log`. The final status-source,
retained `.build/phase1-control-status-scoped-operator`, and retained
`.build/phase1-control-status-scoped-unit` SHA-256s are respectively
`3cd3556a46cbb847f7cb863a70bdca7847b327a63055a3af7ba2b0958179c173`,
`83e5b536da1441f52c9f61ffccda8bd0cda296b3052a4c50acccd912fd4bddf7`, and
`c15b82849abd19bad5baa882eb4904abcbfdf42050d2247df6ae3db92805d837`.

The status inventory no longer presents two separate empty Docker queries as
resource absence. It repeats both name and label filters, reports a change
between observations, and explicitly labels empty results as unverified
absence. Fourteen scope/bootstrap/status unit cases passed in
`.build/phase1-control-inventory-unit.log`. A real local read-only probe passed
in `.build/phase1-control-inventory-live-final.log`; its separate `execve`
trace, `.build/phase1-control-inventory-exec.trace`, records four Docker `ps`
invocations on the selected socket. The unrelated marker survived, no run
root was created, and the non-socket refusal remained effective. This trace
does not prove a real kind lifecycle or complete A01-01.

The status source and scope-test SHA-256s were
`cd38b1984c813c2fbd58fe9552664d0c0a23371a0dc97d77b3f395661e614cf0` and
`5700775b11f59ce05add27cd65ee5b8d3dc702b05178498648612103fcfb1bd2`.
The retained operator, unit binary, live fixture and trace SHA-256s were
`89305262b2cf169b5a73bc9241489e0fe01d6af21e798d225793b6de1e6d191f`,
`4e1f87fec92585110fc61318dd99565d46da83f212440edb65c2aaf0a0d518e8`,
`3ab6af6f8f8c70468fdc3247f835f1b5a1b3f5095a7f689e881afbe5257de2e4`, and
`3f36a53521ed46789f8a0b81993b6fe7226cafa77d18b6418a3638949c1c9bec`.

The container observation now requires the expected bind source and target and
Docker's configured writable flag. A read-only bind is reported as different;
missing `Mounts` or `RW` data is an invalid response instead of an inferred
empty or matching mount. This is a configuration observation, not proof that
a Pod can write. Fourteen scope/bootstrap/status unit cases passed in
`.build/phase1-control-mount-writable-tests.log`, including controlled
read-only and missing-field inspect records. The real local read-only probe
passed in `.build/phase1-control-mount-live.log`; the daemon had no matching
node, so that probe did not exercise a real mount. Its separate `execve` trace
is `.build/phase1-control-mount-exec.trace`. An intermediate build was stopped
to include the missing-field refusal; the final build passed in
`.build/phase1-control-mount-writable-build-final.log`.

The tested status source, scope-test source, retained operator, unit binary,
live fixture and trace SHA-256s were respectively
`7ba5bf608a45dea86ef7872e0a16efb8d944c87c26c0f76b0044800a523575b9`,
`754a6fb0781fe8dfcd24b6b16df380c719999d4bf3542eadc379145692806a9c`,
`de2789321d9915367b30d8c3108aea1bcca9991cfc4fc9cf50323b9eddd07cb9`,
`6568389d21c46fd21c3f2125a068fd1221f7d7a761c9ee734ae2ecfc280d2081`,
`fe239171053a61aa0fe0920a20ae478eea138fce82b949a5663e9753712df621`, and
`6ba8f699578d01dcc8c239588735f72690ce2d0c87699cd45e339e8692e290a4`.
Pinned artifact custody, actual Pod writes and node recreation remain open.

Legacy Tier-0 authoring previously reconstructed only the old three-field
record, which could discard an authored `bootstrap` field. The writer now
refuses an observed top-level field it cannot preserve and type-checks the
existing context from the same resolved Dhall value before rewriting. Two
fixtures confirm that bootstrap and unknown context fields remain byte-for-byte
unchanged; the existing incompatible-parameter repair case still passes. All
39 Tier-0 publication cases passed in
`.build/phase1-bootstrap-preservation-tests.log`, and the public status probe
passed in `.build/phase1-bootstrap-preservation-public-status.log`. An
intermediate build was stopped to add exact context type-checking; the final
build passed in `.build/phase1-bootstrap-preservation-build-final.log`.

The tested source SHA-256s for the Dhall helper, Tier-0 writer and fixture are
`8717a568977fea716f3df7abbffaf8262eac7aeedac6f70ae5a259371bd655c4`,
`34179caa294b375adc759300b9d8348c4524ed116cab43508de8e8d704464522`, and
`22c35602c3a4cf34040ec2fc5f2ce09c50792bb8dc63c31ac444c8852ed6c02b`.
The retained `.build/phase1-bootstrap-preservation-operator` and
`.build/phase1-bootstrap-preservation-unit` SHA-256s are
`405200653f00f2ed9fc0fdb56f818df5897b033a70a4f31e298498d6c490a964` and
`c8a420eb789fad96c6bb2d8d421fba3b5d4bc04376476529e444cb334c6fced7`.
This is a refusal, not the replacement authoring implementation. The guard
observes one resolved value; independently changing legacy import dependencies
are not descriptor-bound to the later file publication. The current selected
bootstrap diagnostic refuses imports, and the general publication/import
boundary remains open.

P01-T01 has an initial public selected-source validation lane:
`prodbox --config PATH config validate` reads one bounded, owner-safe,
no-follow snapshot and validates its authored parameters, context, and any present bootstrap field. It
rejects Dhall imports and reports that deployment-root and runtime checks were
not performed. Apart from the control status lane recorded below, other commands reject a selected global path instead of silently
using the binary sibling. Local role-specific `--config` options remain
separate. The lane still requires the legacy full parameters projection; the
minimal bootstrap projection, validated project anchor, safe import policy,
and propagation through lifecycle and test handlers remain open.

The first public fixture exposed a conflict between an initial absolute-root
restriction and the legacy relative-root schema; the lane was corrected to
validate without resolving a root. The final public fixture passed for a
selected configuration, unsupported-command refusal, import and symlink
refusal, and preservation of a separate production marker. Its output is
`.build/phase1-selected-config-public-test-final.log`. The tested operator and
integration binaries are retained as `.build/phase1-selected-config-operator`
and `.build/phase1-selected-config-integration`, with SHA-256s
`5544b625d9199d2b7a816d8750936f99b319403a247c9b06e08b4c3c706b2e85` and
`a71bbd0a57336e6cd836bd8b50bfc70cba5c3b791d9ad92ee64ade4b2a2dd4f5`.
The tested settings, descriptor-reader, dispatch, parser, registry, and
fixture source SHA-256s were respectively
`2547225ce4ed4e29f4e374f784e00ad3f91252184d90da94ab3ed2ce58ec96bd`,
`2252e83581f9d6c40581e268d2320368dacda6694a053453cf42083a4dd9ae46`,
`5f5a341113d1478d6a2b066398f004ce4dcf33f612777cb5cb27df034fb7a772`,
`22d1ce0ec83be0854adca0d386ced79b11d76edaa605e45502ae8688553c854e`,
`1a1e03b7d7f61ceff972a0ff92069cc3966adaa9c97f3eed642cc29a8ee873de`, and
`8203f047a8b9f2dfb40057fcfe162ea45f5b8f2ac029657304f19f17a308ce16`.
The existing public test-runner refusal also passed with this operator in
`.build/phase1-selected-config-runner-guard.log`; documentation lint passed
after the inherited option occurrences were reconciled in the manifest.
These checks do not close P01-T01 or any Phase 1 acceptance case.

Selected-source validation now distinguishes a missing bootstrap field from a
present malformed one and validates the latter from the same source snapshot.
The public fixture accepts both a legacy file and a valid bootstrap extension,
then verifies that `config validate` and `control status` reject the same bad
generation before creating a run root. It passed in
`.build/phase1-bootstrap-validation-public.log`; 13 scope/bootstrap/status
unit cases and 39 Tier-0 publication cases also passed in
`.build/phase1-bootstrap-validation-unit.log` and
`.build/phase1-bootstrap-validation-tier0.log`. The separate real local Docker
status regression passed in `.build/phase1-bootstrap-validation-control-live.log`.

The selected-source reader, bootstrap decoder, settings validator and public
fixture SHA-256s were respectively
`d43bdd833e63a9507fba0ebc023d5618b7515923f95539948f43e037247009a6`,
`8c43ba5c4d690a15ee056795144c281ede8d63f7b675954378163d5ed78ea23f`,
`841753f9e67e1db1de1f146b7ee9f38dddb51b9b7c9048985e334d8b2466f5d1`, and
`f3f5289c5c1c8cdef82f423bf8e715ee777487117864dc4cf7b10ddd78bb6d6e`.
The retained operator, unit and integration binaries have SHA-256s
`0ce57b93e7abc4034fb769ac46bc73d8bf1ed3bde540d67a1d6e2f1d77840ab5`,
`e100af9d8e702802a1b05446dbc200adb77b26b72347f6b1ca8197cf97a12358`, and
`0bf2e491867a48250d03de5d9ccc2a2a9da6194f3c62f247e6b95e57569216f9`.
This is input validation only; it does not bind root ownership, resolve all
cross-context relationships, publish a configuration, or close P01-T01.

The selected `config validate` path now accepts an exact bootstrap-only
document without requiring legacy parameters and context. Its output names the
unvalidated application, root and runtime scope. Additional top-level fields
still enter the full legacy validation path, so a partial legacy document is
not accepted as minimal. The public integration case passed for valid and
invalid bootstrap-only input, partial legacy input, full legacy input, invalid
generation, conflicting identity, unsupported commands, imports and a symlink;
the separate production marker survived and no test root was created. The
result is `.build/phase1-minimal-config-public.log`. Settings, application and
integration-test source SHA-256s were respectively
`8eb05f8f8eda3183841fc498a968e738d14fab1b5de827b445cf8322b16b736a`,
`1f31d3eb9a7276c3cddd05e480435461174c758e052dbe62ac91187548069772` and
`91c441e892035b25ccacfaffb96eeb4ff01e3e8c67925a58cb4c6c40c5296243`.
The retained operator and integration binary SHA-256s were
`2268dd8dbe65ddeac44876515b51fdd9bef3cf125decd0da920041846c5b86c9` and
`c30cfb7f4f320983ba011632118a0acd546fdf20ba2929258a50aa224ee40a92`.
This public read-only validation does not create a kind environment, publish a
configuration, or complete P01-T01.

`config schema` now publishes `prodbox-bootstrap-types.dhall`, deriving the
three structural types from the same versioned decoders used by selected
validation. Semantic limits remain the validator's responsibility, and the
selected reader still refuses imports. The public integration case in
`.build/phase1-bootstrap-schema-public.log` validated each generated type as
an inline annotation, then checked that a schema-path symlink could not
overwrite a separate production marker. The first build reported a fixture
numeric-default warning; an explicit fixture type was added before the final
build and run. Bootstrap decoder, schema writer, native handler and integration
source SHA-256s were respectively
`7d1b5dc093f9540c0bc8bc5b4c4ea7c3b0a5731b1b16c6fdbfcbb761f824b326`,
`2838fec0a5b9978007d8684fc167403c9556f7cb025beca947b9444dc295a747`,
`beccca0e86604f0b04a879f50cdaed373dadf107e8d684f0cc562c3209f07945` and
`d078f9de3369247276509aa4e5821c9097fc91aaec5ce3570ee8d21493f78357`.
The retained operator and integration binary SHA-256s were
`6e4eafc8d998f1977f4c384aee930f37f16cce54b7a84b6f6db53df0e160d000` and
`d09d77e617b91b5659ee8330ee4413cf054e1591a02ceb51778db0ff8e624ea2`.
This is schema publication, not bootstrap configuration generation or kind
reconciliation; P01-T01 remains open.

When a selected source contains both bootstrap and legacy context, their
`deployment_id` and `cluster_id` must now match. Bootstrap-only status remains
available; a present but unreadable context or a different ID is refused before
runtime observation. The public validation fixture passed matching, malformed,
and foreign-ID cases in `.build/phase1-bootstrap-context-public.log`; 13 related
unit cases passed in `.build/phase1-bootstrap-context-unit.log`. A separate
public-binary probe used `strace -f` restricted to `connect` calls: its foreign
and malformed cases returned the intended refusals with no captured `connect`
syscall, while a matching minimal context completed status. The marker remained
unchanged and no run root was created. The fixture and output are
`.build/phase1-bootstrap-context-negative.py` and
`.build/phase1-bootstrap-context-negative-retained.log`; the two empty traces
are `.build/phase1-context-foreign.trace` and
`.build/phase1-context-malformed.trace`. This trace covers `connect` only and
does not qualify Phase 1 isolation acceptance.

The tested bootstrap model and public fixture SHA-256s were
`fa3c49934321c75d8ead9dfa724a063c359ccbe121c6aaafe1ab7a57f8d5c947` and
`636687cd8e097dfdc113b6fcdc0e9991097e23bbdf331892cf43c0c2d53c4b28`.
The retained operator, unit, integration and trace-fixture SHA-256s were
`c2e64c3e339e49f27ff391fbcc7e0b0a9c2d5f4039c5568a896e4eb8a701872a`,
`79c0eb999220da3552a7e70fc2bd4c37f107cbbbe3481e7a451cf93e4304a412`,
`dc751e1bca3b1599a45be3bf4360946f716b10c37d478758714e4d6b0f03d113`, and
`497cf2e913bbba4b17d1ed80896021ad6e9133151c2c8ec1d83580f2d60be6ac`.
Each empty trace has SHA-256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
This does not establish root ownership or complete P01-T02.

An initial versioned bootstrap projection now decodes an explicit project
anchor, environment, deployment ID, root generation, pinned node image and
ports without decoding application or cloud fields. It reuses the bounded,
import-free selected-source reader and produces only candidate scope and kind
coordinates. At that point the authored-schema writer and public control handler
did not yet use this projection; it did not check the on-disk generation or authorize
effects. Two bootstrap cases and the related scope/kind cases passed in
`.build/phase1-bootstrap-projection-tests-final.log` (11 tests). The parser
regression passed 346 checks in `.build/phase1-selected-parser-tests-final.log`,
and the selected-config public regression passed in
`.build/phase1-bootstrap-selected-public-regression-final.log`.

The broader initial build exposed stale `Options` constructors in parser tests
after the global flag change. Those expectations were updated, and the final
executable/unit build passed in `.build/phase1-bootstrap-formatted-build.log`;
the preceding combined executable/unit/integration build also passed before a
format-only second pass. The bootstrap source, shared reader, settings, app,
scope tests, parser tests, and unit-main SHA-256s were respectively
`31c7d9efe547533f9770b08cad12ae27ce609b0659023f8836c3eaf450f2ab68`,
`b57c8bef606d4d8a87c0b6f0af68f918c423a51f629ca0fb90d81e192b1c409c`,
`54c3f478a94754a8df72aab793f0a1a8f00711c2dcd46bfe09128a143da9e545`,
`0f50881f26adab81edc135bdb2867139f5a862ae35916677185b792ca1a107eb`,
`014e238a701115a9833a0f16bd94f2b2e4eab09fb29c74a0cd7f4a44ef638a4d`,
`25d95e4a14e1af20d3a4e8717f88629dd66bbcdcade5fbd332434fdf5b4fcd6d`, and
`65858256d025dfa2238b439bf7455f48a8364f5c3ff8d6529664388a9b645ad7`.
The retained `.build/phase1-bootstrap-projection-operator` and
`.build/phase1-bootstrap-projection-unit` binaries have SHA-256s
`7f5cfc87cbea4ad9223b542d0b9a7ab8add9f546f9ce93ded35671d11d34188f` and
`434b9f8cf5933f4d057c96423fcd8ab127488444209f050c5e322218415edc8e`.
The earlier selected-config source identities above are historical after the
shared-reader refactor. These results do not close a Phase 1 task or acceptance.

Initial B020 audit: the two exported component-fragment helpers and their
handwritten Dhall node type had no callers outside their definitions. They have
been removed from test support, as has their sole schema renderer. The first
partial test build was interrupted before its result when the remaining renderer
was found. The complete executable and unit-test build then passed, with output
in `.build/phase1-b020-complete-build.log`; the installed local binary SHA-256 is
`5807c967770a4a1d636471228a34a5fa464a683619f22d2734daa4ec5407cd8f`.
That binary is retained locally as `.build/phase1-b020-operator` before later
Phase 1 builds replace the ordinary `.build/prodbox` path.
The nine generated-Dhall-schema regression tests passed; output is
`.build/phase1-b020-schema-tests.log`. This is not Phase 1 acceptance.
The full Phase 1 replacement acceptance remains pending, so B020 stays Pending.

B021 implementation in progress: the authority fixture carries config decode,
TLS preparation, and cleanup encoding failures as values to its HTTP response
boundary; the exception obligation remains a backstop. A loopback integration
test passed for malformed config on both config endpoints, checked that the
reason came through without the former `user error` wrapper, and confirmed the
server continued to answer readiness. Its warning-clean focused build/test log
is `.build/phase1-b021-fixture-settlement.log`; the test helper also waits for
its listener worker to settle. This does not close the Phase 1 acceptance or the
B021 ledger row.
The tested fixture-server, CLI-suite, and integration-binary SHA-256 identities
were respectively
`e89212adf8f45a76117a809e47beca6ac0865ad889652c56d2ea91c472beb8fd`,
`260beac57da691934cbe2af8de072e429fae26003b26c07b01f0a5d138d4c398`, and
`319d40b54384d729cf211c91d00e7ce8eb3d7963ca4bf51271fbe4f4092bdffb`.
The integration binary was subsequently rebuilt for the test-config guard; the
earlier untracked binary is no longer available at that path.

P01-T02 has an initial non-authorizing deployment-scope model for explicit
production/test root, kind-name, kubeconfig and API-port coordinates. Its
initial lexical tests passed, with a redundant-import warning subsequently
removed. A local root observer now checks existing path components for symlinks,
directory type, and ownership of the scoped parent/root; its focused tests are
passing for five cases in `.build/phase1-deployment-scope-observer-tests.log`.
An additional input-length bound and foreign-marker preservation assertion also
passed in `.build/phase1-deployment-scope-bound-tests.log`; all five focused
tests passed without a reported compiler warning. The tested model, test source,
and unit-binary SHA-256 identities were respectively
`a1422d662bf8a14a20a73d1c646f6c473267bb6dbad99867693c34d99ceb34b8`,
`130867c95734804592812215e76b6c569fdc66c59525d988d0c13c85155b81e7`, and
`72554ff8c0f47fe6d4e4b411761628d87a1c2219ac034da68db5543c9c875b45`.
The test source and untracked unit binary were subsequently rebuilt for the
kind-plan tests; those earlier identities are historical, not current files.
It is an observation rather than mutation authority: descriptor-
bound effect checks, generation markers, occupied ports, existing clusters,
and public command wiring remain open.

The scope model now also supports holding an open root descriptor while a
fresh descriptor-relative walk compares every path component. A focused test
detects replacement of the held root, refuses a symlinked replacement, and
checks that caller I/O failures propagate. The nine scope and kind-plan tests
passed in `.build/phase1-scope-descriptor-tests-final.log`; the model, test
source, and retained `.build/phase1-scope-descriptor-unit` binary SHA-256s are
`1cae007774b2fd7eb802a8cb4a1c505ff867fce98730239fb639c90e3fc5be47`,
`e60db4341a98fc45e6ebb9dae389648b6f6451810f5690e825491c0ab030f7e7`, and
`9128039da6fade4eb62db21b5346415b8fa92fe4968b34dbc992f8ff983efe49`.
The initial build failed on an ambiguous exception type, and an intermediate
build was interrupted to include the corrected error propagation. The next
build succeeded but its attempted test invocation used an unsupported flag;
the retained binary was then run with its supported pattern option. Targeted
HLint and formatting checks passed. This observation does not prove generation
ownership or eliminate the race between a comparison and a later effect; it
is not wired to a lifecycle command and does not close P01-T02.

The scope model now has a descriptor-relative local generation-record observer.
It distinguishes a missing, matching, foreign, invalid, unobservable, or
path-changed record and rechecks the held path and record metadata. A match is
not mutation authority, and a missing record is not evidence of cloud absence.
The focused test checks missing and matching records, a different generation,
unsafe permissions, malformed content, a symlink, and a record copied to a new
root. All 12 related scope/bootstrap/kind cases passed in
`.build/phase1-generation-observer-tests.log`; targeted HLint and formatting
checks passed. An intermediate build was interrupted to batch generation-syntax
and re-observation changes; the final executable/unit build passed in
`.build/phase1-generation-observer-build-final.log`.

The tested scope model, bootstrap model, and test-source SHA-256s are
`494f8b9362c4c8afaa02510c7bfdf2b202ce36085df1fa601ed2ce28b3f1c37a`,
`838edd9957563914577385781ac9e0df21b48837bafa32e194ac19e659e35d65`, and
`bd33864c949f225b7d0a875463f816959c2417c093dac1dc48abfafb3ded2ad6`.
The retained `.build/phase1-generation-observer-unit` SHA-256 is
`42641b0dbdd5a42b30912a891a4aec43f06f7492d8788ee81ba56f43cc5401dd`.
The operator SHA-256 remained
`7f5cfc87cbea4ad9223b542d0b9a7ab8add9f546f9ce93ded35671d11d34188f`:
no public command used the observer in that build. A durable writer, admission and actual
kind read-back remain open; these results do not close P01-T02.

P01-T03 has an initial non-authorizing kind configuration plan that binds the
candidate scope to a digest-pinned node image, loopback API, retained host mount,
and explicit publication ports. Two builds were interrupted before results to
batch registry-port, IP-literal and hostname-case validation fixes; the three
focused tests then passed without a reported compiler warning. The local output
is `.build/phase1-kind-plan-tests-reviewed.log`; the model, test-source, and
unit-binary SHA-256 identities were respectively
`8129f549b791d8cdf470397187a8e7de6a68761fd5b62b0818fad04c9f6254f7`,
`3f50dbdeb7e697b2b0886a7c0743c9f181dd054b247e4e4dc9cdf722d029cc0f`, and
`2c927a0e6259f2226e487ebcf9b8867beb554e3f01002049d98f987535cc4763`.
The unit binary is retained locally as `.build/phase1-kind-plan-unit`.
It does not
verify retained image bytes, create a cluster, install an enforcing CNI, bind
PVs, or read back runtime resources; those requirements remain open.

L04 remains open: legacy native suites can regenerate the executable-sibling
production config, and the topology route has not propagated its run config to
every consumer. The topology branch now selects `prodbox.dhall` beneath its
run data directory and passes that explicit path to the shared Tier-0 writer.
This path has not yet acquired descriptor-bound ownership. The source refuses
unverified generated config before variant
directory creation, secret loading, config writes, cleanup, or native-suite
setup. Config-free unit and delegated CLI/environment suites retain their
existing routes. This intentionally makes those guarded routes unavailable until test
configuration is bound to a verified run-owned root and the same path reaches
every invoked handler. Phase 1 acceptance must use that completed isolated
route, not the refusal as evidence of a working runner. A public-binary fixture
passed for both guarded routes, confirmed that neither created a sibling config
or run root, and verified a separate production-config marker survived. The
warning-clean focused log is `.build/phase1-test-config-public-guard-final.log`;
the tested operator SHA-256 was
`fa72d6cc0f7bd512d5fff815b7f3d100fc311d9fc5446d5c3f8b19c5d727ea95`.
The focused generated-config refusal unit test also passed; its local output is
`.build/phase1-test-config-guard-verified.log`.
Local copies are retained as `.build/phase1-test-config-guard-operator` and
`.build/phase1-test-config-guard-integration`; the integration binary SHA-256 is
`17613c8bf5c9452342b31d65ec282a2085b5f93ef3397758aa84b231b55ed3f7`.

The legacy cleanup guard also refuses every unverified run-data root, including
the shared `.test-data` directory. A lexical path under that directory alone
does not establish ownership or authorize recursive deletion. The focused unit
case passed in `.build/phase1-test-root-guard-unit.log`; the public isolation
regression passed with the rebuilt operator in
`.build/phase1-test-root-guard-public.log`, retaining the independent
production marker and creating no test root. The runner and unit-source
SHA-256s were
`9eb45133f402f17de705e47879b957efbb1860138ea8e29b1c4204e0e94e8c02` and
`c37934c8faba286ca4081db9bee0a5daa185aa6d424c2807a595f925956d3d84`;
the retained operator and unit binary SHA-256s were
`e2c259483cefe7730054c4fb8433a461f79ab0baa58033906c4cceeb7d062f9a` and
`aa6b0ba5318a8349644730e5f91799a85cae4d7d81f6be254fb056c0c02a9a16`.
This refusal does not implement run-owned cleanup, identity, or acceptance.

The canonical `dev check` attempted after these changes stopped in file-policy
lint because its harness ownership witness still required the retired
binary-sibling writer; the failure is retained in
`.build/phase1-current-dev-check.log`. The checker now requires the explicit
run path, its current refusal guard and the selected-path writer, and rejects
the old sibling writer in the test runner. The corrected file-policy check
passed in `.build/phase1-selected-checker-file-lint.log`; all three ownership
checker tests passed in `.build/phase1-selected-checker-tests.log`, including
missing selected-path and reintroduced sibling-writer controls. Checker,
test-runner and unit-test source SHA-256s were respectively
`11d2dbc30a9848e91cf2fd21538a1ec6eaabbae542b0b71a35aabe4d4ef921d6`,
`408e52c1f4514afabe1957c7ae0ecc9df91f4d31c96ce28a47e5f5bbaeef817b` and
`e6992cbacbd777a3104831efc0dbdd52723bf127dac98d25cd3a89c4de9f3107`.
The retained operator and unit binary SHA-256s were
`5ea4c20a9bde22ec5652ed8f69314b7c4964009c16d80754cdc323ecb0d68bbf` and
`d7cd16c1dd2912df4bfff7bfd527e4d16811f91bcaac33d2bf936aa8b96d7177`.
The failed full gate is not a passing gate; the corrected full gate and Phase 1
acceptance remain required.

The next gate attempt passed file-policy and documentation checks, then stopped
at Haskell style checks; its output is `.build/phase1-corrected-dev-check.log`.
The reported issues were a nested-case style violation, a planner comment
mistaken for a subprocess token, and hand-authored Tier-0 test data without the
repository's reasoned raw-fixture wrapper. Those sites were corrected without
removing the checks. The standalone pinned HLint run before those corrections
reported no hints; the full gate must still pass on the corrected source.
The next attempt, `.build/phase1-style-corrected-dev-check.log`, passed the
style policy and formatter but was deliberately interrupted during HLint when
the foreign-marker fixture reason was found to describe existence rather than
its intentionally invalid contents. The reason was corrected; that interrupted
attempt is not a completed gate.

The selected-path writer was exercised with synthetic inputs: its output was
decoded from the run directory, and a separate production-config marker stayed
unchanged. The focused result is `.build/phase1-topology-selected-path-test.log`.
The public refusal regression also passed against the rebuilt operator, in
`.build/phase1-topology-selected-path-public-guard.log`. The tested runner and
unit-source SHA-256s are
`a229df74a123f85b0d0d71e7b648712bccba9e468f0b63934548bce47943caed` and
`f522c40673dfd719ed2125c4f70bbc83db146c1651f17b397a54091cb31c3094`.
The retained `.build/phase1-topology-selected-path-unit` and
`.build/phase1-topology-selected-path-operator` SHA-256s are respectively
`c0417a8e1f44b26c9132588c85745729c936274c2c41ea4bc2cb61bfc3a3a7f3` and
`3acd29b595435ab0672df1075652d04080d148efd80dadb088667ee7792c845a`.
The public test uses the retained integration binary identified above. These
checks do not establish exclusive run identity, safe cleanup or end-to-end
config propagation, and the runner remains deliberately guarded.

The internal retained-artifact observer now hashes a declared, size-limited
file through the held scope root, refuses unsafe ownership, permissions, links
and paths, and checks file and root stability. It reports observations only;
it is not yet connected to a public lifecycle or selected artifact declaration.
The 15 focused scope tests passed, including matching, mismatching, missing,
oversized, linked and unsafe artifact cases
(`.build/phase1-artifact-observation-tests.log`). A read-only public status
regression used the actual selected Docker socket and preserved the independent
marker (`.build/phase1-artifact-status-live.log` and
`.build/phase1-artifact-status-exec.trace`). Source SHA-256s for
`DeploymentScope.hs` and `DeploymentScopeTests.hs` are respectively
`beab106dfaca3a2997aae62564a3d4e9e85bcc8926152a9443805a3a192cb420` and
`11313986870f7e40fb981b37563a4637b69b990f1c523b4eeb0ba773842ceaf6`.
The retained operator and unit binary SHA-256s are respectively
`1f1cd7ca9d706584caea78856c5bbfd6182f0c466be0c04ce85d10934a556ca4` and
`13290e24166dd0c6a750953b823c9ae24f06c06bfc108c2c57f01520004d4f71`.
This does not prove archive structure, image identity, architecture, provenance,
kind recreation or authority to load an artifact. The hash timeout is not a
guarantee against uninterruptible kernel I/O. All phase tasks remain open.

Subsequently, the selected bootstrap version 2 gained a required retained
node-file declaration, and public `control status` gained the corresponding
read-only observation. Version 1 rejects a declaration instead of ignoring it.
The 16 focused tests pass (`.build/phase1-artifact-public-tests.log`); the
public probe against the real Docker socket exercised missing, matching,
mismatching and symlinked local files while preserving a foreign marker
(`.build/phase1-artifact-public-probe.py` and `.log`). The first probe exposed
an extended-record decoding failure; the versioned decoder was corrected and
the recorded probe passed on the rebuilt operator. The scope, bootstrap,
status and test source SHA-256s are respectively
`c38e9e438ea1c15daaa19ff356bc12181ef24c3414d6d6b389d3dfea6df5cc08`,
`aa8b1efc64aac40e0bd7ee39ad6755432786400f30e6e505125a2b1d9aa62c04`,
`e3ad51be65d7df332bce2a55df33e9a87a8e76fdfab6948a37eb67e818f1f626`, and
`61e85417786c1683820826d8b76f6b7f3ab2d72f0634c6f0479572288cc46ebf`.
The retained operator and unit binary SHA-256s are
`87413e29a2de2b3d1cc3f1ddddd6c6a3037df4a1e3a7d07dbb61309ef20cb62e` and
`1d5f432ec6ee4dee9dcc90660acfcf1e14713d1a3b905ac4ec3a2092664a4b1a`.
The file digest is separate from the pinned image reference; no actual image
archive or its architecture, provenance, loading or recreation is qualified.
All phase tasks remain open.

Status now separately inspects daemon metadata for the selected pinned node
image and reports its image ID, OS, architecture and whether the requested
digest appears in `RepoDigests`. Failed or malformed inspection is reported as
unobservable, not absence, and this observation does not bind the daemon image
to the retained archive. Seventeen focused tests passed
(`.build/phase1-image-observation-tests.log`), including controlled matching,
mismatching and malformed metadata. A public read-only probe against the real
Docker socket exercised the unobservable branch, with five Docker invocations
recorded in `.build/phase1-image-observation-exec.trace`; its output and fixture
are `.build/phase1-image-observation-live.log` and `.py`. The daemon had no
local images, so positive metadata was not observed on a real image. The first
build exposed an ambiguous parser type; the corrected build passed. Kind-plan,
status and test source SHA-256s are respectively
`39f4feef30c95e0077f5c0960a8ea47595b400226ff71205db04dd68f7fac88c`,
`84a73f5b36863bccf3aeb4fcb93b58aa555e9611a1a7db257f5db148a1faa223` and
`1c68adfdb8dcecaae03e9bf1e97c259c5e54e9cb6cb7fb7049722994f540b7f3`.
Retained operator and unit binary SHA-256s are
`3fe0d4d87443c82089c0cf8382bcbddbf9d5d94f52a22ce097ea4a605a974fe3` and
`996db3234688b0234b4eec49ec4db68b6a650f8e63787519a275d9687c1b2b4b`.
This is not image acquisition, loading, provenance, kind reconciliation or
phase acceptance; those obligations remain open.

An internal fresh-scope preparation primitive now stages a generation record
under an existing owner-safe parent, syncs the file and directories, publishes
with a no-replace directory rename, and compares the published inode with the
held staging descriptor before observing the record. Existing roots and staged
leftovers are refused and preserved. A publication error may leave either the
staging directory or the target root; the incomplete result is not authority
to retry enrollment or remove either. Twenty focused tests passed in
`.build/phase1-fresh-root-tests.log`, including competing generations,
existing/staged preservation and symlinked/writable-parent refusal. The source
and test SHA-256s were
`c0aa133765bc3b30a606fb2c7f47cd125bb2970bfd04ff29f17ce1f266ef4527` and
`7e0d3afa2efd98e7506ddadea8022d0f58212a3f0dfd277ca84de9ad9f08de77`;
the retained operator and unit binary SHA-256s were
`b9f31f969714f7deafa21232707bb9424f36a3614733808f43b2584cd97d66fe` and
`992e40910d48a6f3a9ab2cacfe3cb9350dbef08d6da7e2d1549e18376678f59e`.
This primitive is not yet wired to a public command, does not create the shared
parent, and does not provide recovery for interrupted publication or prove
never-admitted cloud history. The actual operation journal, reconciliation,
resource read-back and cleanup remain required before phase acceptance.

An internal kind-intent writer now exclusively creates and syncs a bounded
non-secret operation record in a generation-matched root. It binds the
operation ID, root device/inode and generation, cluster, selected runtime
socket, rendered kind-configuration digest and optional retained-artifact
declaration. Read-back checks the file descriptor, name and root stability;
an existing or interrupted record is not treated as an admitted operation.
Twenty-one focused tests passed (`.build/phase1-kind-intent-tests.log`),
including competing writers, wrong generation, selected-field read-back and
preservation of a foreign symlink target. A public read-only status regression
passed in `.build/phase1-kind-intent-status-live.log`. Intent, scope, test and
package source SHA-256s were respectively
`c7911b1d44cf9f5222ec91f3aa89e16a8a01f978e219f5c2e61740f23efce65c`,
`6add135690a2ee7e022fd351bb5cbbddb79dda0b25ccc08e1efa404b1100cde2`,
`5ec60166c5309af66831cbaa7deb012967e888147f3535edbdd2db8d0a18f289` and
`b3f64b24826456ba8525f0aa93e85542bc5a11379ca7d6ea001046abf71ddbe9`.
The retained operator and unit binary SHA-256s were
`cd2d34740f588393502d9ae7531a3f3551adcc901c81ba968aa3147d7049b57e` and
`4a8eeccca974a6649c9d35dbbda7795a7468e6cbffa5e0bb663027d1a2ce04c0`.
The writer is not a public handler or an admission authority. Execution
serialization, cancellation settlement, interrupted-record recovery,
resource read-back, cleanup and actual kind effects remain unimplemented.

Public `control status` now observes a stored kind-operation record against
the selected root generation and exact configuration. It distinguishes a
matching operation ID, conflict, invalid record, unavailable generation and
unobservable file; a missing record is not reported as proof of absence.
The 21 focused tests passed in `.build/phase1-intent-readback-tests.log`, with
record-present cases on disposable filesystem fixtures. The real Docker status
probe in `.build/phase1-intent-readback-final-live.log` covered the absent-root
branch only. Intent, status and test source SHA-256s were respectively
`85a7b393514aaeb449401b85b9bf5c1490deecd2982655762da711696a5f026b`,
`fc4199baa3e4d97b073ac51fb9386b50b9f14cb886ef0b5347fce6f48940aaa7` and
`a9a490ef47b0418a6d48c479b6b9ac6be911bf7b349b4e49aef8c860160d6226`.
Retained operator and unit binary SHA-256s were
`af3f35fc1ef69ee9cc8aa19b802c9ec2ec839b90f906018b64f567ba24a20ce2` and
`906738016ad6b8a0831510a7559da3200445fb3ac34aac7148e189fe4184a8df`.
The observation is not admission, completion, a public recovery handler or
real kind acceptance; those obligations remain open.

A non-authorizing kind lease now takes a nonblocking OS lock on the held,
generation-checked root and releases it on callback cancellation. It rechecks
the root and returns the callback result even if the root changes. The 22
focused tests passed (`.build/phase1-kind-lease-tests.log`), including a
separate `/usr/bin/flock` process that was excluded while the lease was held,
successful reacquisition after cancellation, and root replacement. A public
read-only status regression passed in `.build/phase1-kind-lease-status-live.log`.
Lease, test and package source SHA-256s were respectively
`927bc6fd1c57f85efde8108ec680b8b4da74aa39a4654ea1b54bbc9b1eeb3073`,
`3cfa0924cbf30528d081d326496721a3ff3d77e929d0e8b35f4117453453bafb` and
`31d178126f859ee6dde028bb2f9300c14b9dee110ee533d8f9b4af8e6bc53c67`.
Retained operator and unit binary SHA-256s were
`af3f35fc1ef69ee9cc8aa19b802c9ec2ec839b90f906018b64f567ba24a20ce2` and
`92b0629012d82a2fe44f0a685c57cf57b86ef9b0e6fd94a2650c73874165c03e`.
The lease only excludes cooperating users of the held inode; it does not
establish admission or settle detached workers. It is not yet used by a public
mutation handler, so actual kind operations and phase acceptance remain open.

The internal new-operation boundary now composes the root lease, exclusive
intent publication, independent intent read-back and a final root check before
calling its next step. An interrupted callback leaves its operation record for
recovery; a second attempt refuses the existing record without calling the
callback. Intent file acquisition is masked until its descriptor is bracketed
for closure. All 23 focused tests passed in `.build/phase1-kind-operation-tests.log`;
the interruption case observed the record before cancellation and verified
the refused replay. Intent, lease and test source SHA-256s were respectively
`78b83cb3562b482c1d4fe049ee86ca6d99296ebc44ff574651f0bbb89212c5d4`,
`6c7e926aba4ae5c8772feedd6ad194756f6a4360a628e36d8e3ca8cb173fadf5` and
`f6b2b39c3b1848fbd1bfb31a9d59f91b01d328181be35f1c9282b11e0368e665`.
Retained operator and unit binary SHA-256s were
`457c3fb0a9390a0e84bfb6e0e363b371323381815d902b978e9c35282e01f07e` and
`4b705d3d9bea9942c21256e794fcb644bfcce5ca5982ee3fe9221008b4c7d411`.
The boundary does not authorize or launch kind and does not settle a spawned
child. In particular, the existing generic bounded capture only kills its
direct child, so it cannot by itself qualify kind mutation cancellation.
Public reconciliation, recovery, owned subprocess settlement and real
acceptance remain open.

The internal boundary can now reacquire a matching recorded operation under
the same root lease without replacing its intent. Both new and recovered
callbacks receive a recheck that observes the root and matching intent again.
The 25 scope tests in `.build/phase1-kind-recovery-unit.log` passed, including
missing and wrong operation refusal, reacquisition after cancellation,
concurrent lease refusal, unchanged intent bytes and a changed-intent recheck.
The lease and test source SHA-256s were
`ac3c0abc95aa8962dba22de871a30805223c19b1bea388fb8cead244f5f345ea` and
`12463e6c8c785516491b9f54bc16fb33f084a96f1a97755e0fe92a561526491f`.
The retained operator and unit binary SHA-256s were
`52829f82361638b2a2bcaa06c2f21650982241ec34d5887c1a63ae72e8721f15` and
`896a0b2d6b5db529b1d8dcb09244f6f9542d5a533bd4826a0c0c29b5b192162f`.
This is not public recovery or effect admission. It does not prove an earlier
worker settled, prevent a change after a recheck, or authorize a retry.

The existing cgroup-owned subprocess executor now accepts up to 64 KiB of
bounded binary input after scope admission, using the existing gated input
transport and the same work, shutdown and settlement deadlines. Three native
tests passed against the local user manager: exact binary delivery, oversized
input refused before process start, and settlement when a child does not
consume input (`.build/phase1-owned-input-tests.log`). Three existing
closed-input regressions also passed, including cancellation and a separately
grouped descendant with an unrelated process preserved
(`.build/phase1-owned-input-regressions.log`). The manager reported a degraded
overall state, but the tested scopes completed and settled. The subprocess and
test source SHA-256s were
`7dc4bec4c308a2a639e115a64d62e0052b292066c30f5ff19db573b6e8136b1d` and
`7dfc58636dffbd62ac007ef0594a753d2453d54fd50daab48e40ce16ab5e05af`;
retained operator and daemon-test binary SHA-256s were
`a8e3727d21556b58da481b7b2805661f2c1998d6d5f9b99655a1c6495a64e92a` and
`9fece39f1f774115fee5a501300c835ebdbe13e7bb27f7e9abebc947d608d80d`.
This is not yet connected to kind, and its standalone error path still needs
to preserve primary and cleanup failures together before qualifying kind
mutation. Host capacity admission, actual reconciliation, read-back and
cleanup remain open.

Subsequently, owned subprocess results were extended to preserve separate
primary and cleanup failures, including a process exit alongside cleanup
refusal. An interruption now retains its original exception when cleanup is
unconfirmed; cleanup I/O exceptions become structured cleanup failures. The
13 selected executor tests passed in `.build/phase1-owned-failures-tests.log`.
They include controlled dual-failure and interruption/cleanup-failure cases,
plus real local input, timeout, cancellation, overflow and descendant cleanup
regressions. The controlled cases do not prove a real cgroup cleanup failure.
The subprocess and daemon-test source SHA-256s were
`7b43524e97e634699316386ab69545bd45bdb359df89ad5efe936aead53153de` and
`e6cccfa8e2b788bca5b9a90adad11a86f7cd4c3fffcc9ec9404c0e75e39b3475`;
the retained operator and daemon-test binary SHA-256s were
`700e2822911ed22aac3e175b2a393d2aacc3e6f26ea87d61236ad3fb17bc4f73` and
`ec797c126005d5edd4130c0373ff8a62c6f61b900c777ecdf9966b8311c13068`.
The 2048-child stress case and full gate were not run in this focused check.
The executor remains unconnected to kind reconciliation, which still requires
admission, host capacity, independent resource read-back and exact cleanup.

Public status now uses the existing bounded native host probe when the
selected root is present. It reports CPU affinity, total host memory, total
root/retained filesystem sizes and whether their device identities coincide;
it explicitly does not report free space or workload fit. A disposable
selected-root probe independently compared the public output with Linux
affinity, `/proc/meminfo`, `statvfs` and device observations, refused an ambient
test-capacity override, and preserved an unrelated marker
(`.build/phase1-host-capacity-live.py` and `.log`). The absent-root status
probe created no root (`.build/phase1-host-capacity-absent-live.log`). The
status source, retained operator and probe SHA-256s were respectively
`08c65407ce552e980ecaeb33e69b37b54d2a00d9af60631f7b3e35f8319db86b`,
`16ee927fe5a8f51a9e9b7d9f6884a5077df9354fc31afb2ce0d0c1d6ac12e733` and
`6459b44145ce06a2a37735b1d320ca8fc271ba075ec67a85bd76840e725263d2`.
The 23 focused scope regressions passed in `.build/phase1-host-capacity-unit.log`;
the retained unit binary SHA-256 was
`925283bf7164357777a56b3ece205ba71c73e97e43a6261b9079058d818f7730`.
This diagnostic does not establish node allocation, quotas, measured worker
completion, available capacity or kind reconciliation; P01-T04 remains open.

Bootstrap version 3 now declares a distinct retained kind executable with a
bounded size and digest, and new operation records bind that declaration.
The retained-artifact reader can hold a verified descriptor across a callback
and report changes without discarding the callback result. The native test in
`.build/phase1-kind-tool-native-final.log` copied the installed kind binary
into a disposable selected root, observed its version through the cgroup-owned
executor and held descriptor, checked the operation-record binding, and
refused a wrong digest. A later read-only inspection of the installed binary
reported kind v0.32.0 and SHA-256
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`;
the earlier test did not retain the digest derived from its copy. A repeated
identified run in `.build/phase1-kind-tool-native-identified.log` retained
that same digest for its copied fixture and passed.
Public status independently reported matching and changed tool bytes in
`.build/phase1-kind-tool-public-trace.log`; its exec trace
`.build/phase1-kind-tool-public-digest.trace` showed no tool execution. The
scope, bootstrap, intent, tool and status source SHA-256s were respectively
`de3e9b7d19cf80be297f8925063a3f7f4551c287e1ad842ca43fb3dbe06aec45`,
`cb757a38d99872e800b27216c419451146cd8a01ccea7c11aad8f8f7740036ee`,
`d71b63cf2c12d0d63eabd08aa556e8e28ed118f61c7d65ee9e764b80c06537a9`,
`b2a4be471e5b389273ea6f4364a92df636ec6d8e5615bd28b14895bb7256ebec` and
`eabe79d1a9f90590c6b2aa487d5df7863e0104feec5d5ab9b8e1f5bc411c32a4`.
The retained operator and daemon-test binary SHA-256s were
`3b856d3cc3689a34576260066f2eab81ca5c2d479be41f7cc05d48c96f814330` and
`3496bc3faa3692d398dee710ce619467074c38cfa9add619019a6a264ab7dd20`.
All 25 focused scope tests passed in `.build/phase1-kind-tool-unit.log`. The
identified daemon-test source, daemon binary and unit binary SHA-256s were
respectively
`fe6b3ed6615511dd7b1a7adf99b77a49b3ce5a3f569b8cf7db4ea73ee44bcaa2`,
`0a07671c427bf5ceac5ba454d8a67aaa6d39dcfa96862d675f845a5cafd21307` and
`da4b456c3bbd68841a2682338459ffa714832eb06925312090e670f73b0a8a08`.
The retained executable is not sealed against same-owner modification; the
version attempt and before/after observations do not authorize a kind effect.
No image load, cluster creation, recreation, cleanup or phase acceptance was
performed.

The internal version observer now copies the held executable into a bounded
Linux memory file, applies and reads back write/grow/shrink/seal protections,
then hashes the sealed bytes before invoking `kind version` through the owned
executor. The two tests in `.build/phase1-sealed-kind-tool-final.log` passed:
the controlled case refused a wrong digest and oversize copy, preserved the
sealed bytes after changing the source, and observed write, shrink and growth
refusals; the native case ran the selected kind v0.32.0 copy in an owned scope
with fixture SHA-256
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
Sealed-tool, kind-tool, test and package source SHA-256s were respectively
`339667eb27e7c8f855e49d169cdcbf4a15e65a1cd6edec819650ada0db1e8832`,
`42dae98adca7eeb1cf8cdbdf9dfbff92d65cde9ae4d951395beeb1e49f1c73a1`,
`b8585d8161928b65128f8b2be071ebedb081cd115274f4a27cf8dd9fb6c186b0` and
`973e6d73c5415d69789669fc5cd4def1f3eb1d5c6f1c07e83da5b4a6faae8e6e`.
The retained operator and daemon-test SHA-256s were
`3b856d3cc3689a34576260066f2eab81ca5c2d479be41f7cc05d48c96f814330` and
`04712be6aa4c71e8190ae5a62f3d2836e47d813103f1d13de2db4914dd171a2f`.
This is a read-only version observation, not admission to run kind effects.
The snapshot's host memory charge is not yet included in an admitted capacity
envelope; unavailable sealing or executable-memory support refuses rather than
falling back. Image loading, cluster lifecycle, independent read-back and
cleanup remain open.

The internal snapshot now requires a checked planning budget before allocation.
Its declared maximum is rounded to 2 MiB, the caller's declared kernel overhead
is added to the kernel reserve, and 163840 bytes of copy/hash scratch are added
to the heap reserve. The adjusted plan is revalidated against both limits.
The three tests in `.build/phase1-sealed-budget-tests.log` passed, including an
over-budget refusal and the real retained kind version observation. Runtime
memory, sealed-tool, kind-tool and test source SHA-256s were respectively
`4169044404e10ab7d6328401d1f87e50ee0961cdd2e1881b70b841421ae3917b`,
`3cb85001db5ca4aa23f97ea6511a63d28a97b2fc82b72d00dfef2e7fc34261f7`,
`398c31b07b154cee7478b44faff89c4753b365f9ce72a48ef800663af723ecf1` and
`bee3cb48bc53e8b8056d77b61a192509f92a673a4cb0f3471e58e40ed361a4be`.
The retained operator and daemon-test SHA-256s were
`cef6c087936a9e297e5b77b3cea7d23677c4f2fa1fb381d07a3c5b77d71c6661` and
`cfeb3d35efb0c568362c0603d3ad3da61aeedcd932233fa742ef34a4e6f49ea6`.
This arithmetic is not physical admission: measured overhead, host placement,
available headroom and concurrent allocation enforcement remain unproven.

The internal kind version observer can now hold a sealed snapshot while using
an observed host placement with the exact adjusted runtime plan and its single
child slot. The prepared callback's child invocation is single-use and tied to
its calling thread; a plan mismatch refuses before preparation. The existing
placement observes parent and child cgroups, but this composition is not an
Authority permit and does not establish measured snapshot overhead or global
exclusion between independently observed placements. Sixteen owned-subprocess
regressions passed in `.build/phase1-placement-owned-regression.log`; all 36
host-budget cases passed in `.build/phase1-placement-host-unit.log`, including
refusal before prepared work from an unmanaged process. The initial unit
invocation used an unsupported option and was corrected. These results do not
exercise a successfully managed placement or prove a cluster effect. The
existing placement additionally requires the RPC-birth controller's fixed
manager identity; a kind controller cannot borrow that unrelated identity as
its lifecycle authority. At that revision, a kind-owned managed controller and
its real placement/settlement proof remained to be implemented. The
subprocess, kind-tool and host-budget-test source SHA-256s were respectively
`030b659653a10955e79601d7e585c33d705d2ae309380d553a2cb605e8422647`,
`717e3d3ce933c4b5c07a2d75b209266b18f21430b5bf400a49db2be76671d3b7` and
`0fb2effd2629692ec563865cd2b5e3492f4a17a366091d8c6c1ddecb00f18df5`.
The retained operator, daemon-test and unit binary SHA-256s were
`a535a955555c55c3d310bd22d8d9b9e1c66e20aa63104961c7b927e32161c877`,
`774e9b4b1e2839cd1556d54c1d9f777a19110025043e7c7faa7701d59ad6f372` and
`31eeaf77d8a80a37d15f372e028cf3f36c66e22c59d5d492ffc670aad8d41b55`.

The placement observer now has distinct closed RPC-birth and kind profiles:
the kind profile checks its own manager unit, slice, runtime directory,
description and cgroup path. The kind version observer requires an opaque kind
placement, so an RPC-birth placement cannot be passed to it. Existing RPC-birth
names and description remain the default for its callers. All 36 host-budget
cases passed in `.build/phase1-kind-placement-unit.log`, including unmanaged
parent refusal for both profiles; 16 owned-subprocess regressions passed in
`.build/phase1-kind-placement-daemon.log`. Kernel-scope, subprocess,
kind-tool and unit-test source SHA-256s were respectively
`27734adf3eaf9460ebcb8383c16a794beecc4430df00f961b50df2f8e1fb8e85`,
`e9c2037420cbdd4e8b8b479739096e2dae0ab5f75b5ef3e5bfa8ecb33e51f270`,
`b19f20daab5f5b2314158f34d4cea33c51c368ba348f86b20a90f3ce60ae4b4d` and
`960ddf0c2e1a8321a1118f326d7705d1006df533d03e895e06e201f9817765c6`.
The retained operator, daemon and unit binary SHA-256s were
`52829f82361638b2a2bcaa06c2f21650982241ec34d5887c1a63ae72e8721f15`,
`9ea13397a1c5ecc97a4b43d972e9dd6b102b11a41be7384f9bdfc8bf530489f3` and
`126363c5c1d99a718345b8845db7fb462bed79cf364f0819fe883b10626627d1`.
This adds an observation profile, not a launched kind controller, lifecycle
admission, globally exclusive reservation, or measured capacity proof. A real
managed-controller success/settlement test and public lifecycle remain open.

The native fixture `test/qualification/KindHostPlacement.hs` subsequently
started the exact temporary kind controller and slice through the real user
manager, used the kind-only placement to execute the retained kind v0.32.0
version command, and observed the expected version. Its adverse controls
required refusal when the same controller selected the RPC-birth profile and
when preparation supplied a different runtime plan. It observed its exact
controller, slice and child-family units absent, plus runtime-directory and
cgroup absence, before removing its disposable scratch root. A separate
read-only `systemctl --user list-units` and filesystem check also found those
fields and the scratch root absent after the run. The fixture uses a synthetic
host capacity vector and therefore does not establish host headroom or actual
workload fit. It is a native fixture, not a public kind lifecycle, cluster
creation, recovery or phase acceptance.

The positive run is `.build/phase1-kind-host-placement-native.log`; its fixture
binary SHA-256 was
`5f319ef00006d8d2c392d6aa1af03d1f461f6be2ad3279f8b5112e0e89125f03`.
The subsequent run with both adverse controls is
`.build/phase1-kind-host-placement-adverse.log`, with fixture source, package
definition and fixture binary SHA-256s respectively
`600af155bd426c4ee6ef4ecb3f04cc987a674f289cb9175bf0a671a922210499`,
`3cc0407e5928b4e23524894d27c0d87fd0c83a9c9bf26b4ec11e945bd0b969a8` and
`becf21f8a8d1af77fd26fea8f1f5c37705891917eaa7c3da796249f5d506fcf1`.
Both runs used retained kind fixture SHA-256
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
The first fixture compile had an incorrect import and a partial-list warning;
both were corrected before either run. The public controller, operation
admission, recovery, measured capacity and real cluster lifecycle remain open.

The same managed-controller fixture now builds its host plan from a native
observation of the real retained-root filesystem and requires the controller's
independent native observation to equal the launcher's before using the plan.
A reduced-memory negative control refuses before manager submission. The run
in `.build/phase1-kind-host-capacity-native.log` passed the version, wrong
profile, wrong plan and exact cleanup checks. Its host observation was 8000
millicores of affinity, 15930 MiB host memory and 238220 MiB on each of the
root and retained filesystem coordinates, with the same device. The separate
kernel and filesystem read in `.build/phase1-kind-host-capacity-independent.log`
matched those values; `.build/phase1-kind-host-capacity-cleanup.log` records the
independent absent runtime directory, cgroup and disposable root, while a
separate `systemctl --user list-units` found no named fixture units. The tested
fixture source and binary SHA-256s were
`69521f11b7320622531a29230a67510859ae7136954aafd8c2fbac4aedea287a` and
`a2d82f7daedd8752ed137651deee7aab858f50b7440d7a9ea7011408a817cb28`.
These are total-geometry observations for a bounded version fixture: they do
not measure free headroom, snapshot overhead or the management worker peak,
and do not qualify cluster creation, lifecycle admission or Phase 1 acceptance.

The managed fixture now also records a kind intent before starting a bounded
disposable child, interrupts that child, verifies its exact manager family and
PID are absent, and reacquires the same operation ID before executing the
retained kind version command. The run in
`.build/phase1-kind-interruption-pid-recovery.log` passed; an independent
manager listing and `.build/phase1-kind-interruption-cleanup.log` found child
PID `2100944`, the fixture units, cgroup, runtime directory and disposable root
absent afterward. The fixture source, recovery boundary and fixture binary
SHA-256s were respectively
`730e2e37c5e283614a8c2451842ab2b133d45dd9fba2a08267eb6890fe5d5f44`,
`ac3c0abc95aa8962dba22de871a30805223c19b1bea388fb8cead244f5f345ea` and
`f19f97928be38b7bbc00abd3e4a69fe7fed6792e9d913acd6244cece679ce424`.
The preceding run without the PID check is preserved in
`.build/phase1-kind-interruption-recovery.log`, with fixture binary SHA-256
`1abb762a9d1764355d78f3c053150add8a122312056a56be3f7bee1acf095d6d`.
This controlled child is not a kind cluster mutation; public controller
launch, interruption recovery for real kind effects and acceptance remain open.

The canonical check in `.build/phase1-raw-fixture-dev-check.log` passed file
policy, documentation, formatting, HLint and the warning-clean build, then
failed three of 9,994 unit cases because the CLI golden files did not yet
include the selected `--config` option and `control status` command. The other
9,991 cases passed. The golden projections were regenerated and the three
checks passed without acceptance mode. Their JSON byte conversion also exposed
an existing test-fixture encoding defect: `Char8` truncated non-ASCII text.
The CLI golden tests now encode UTF-8 and independently decode the JSON. All
four cases passed without acceptance mode in
`.build/phase1-cli-utf8-golden-tests.log`, and an independent JSON parser
accepted the regenerated JSON file. The interim rerun in
`.build/phase1-utf8-golden-dev-check.log` was interrupted during style checks
to continue Phase 1 implementation; it did not pass. A subsequent canonical
gate remains pending. This check is not Phase 1 acceptance.

The public status observer now repeats both exact name and cluster-label
inventories after inspecting a candidate. A replacement or disappearance
during inspection is reported as an inventory change, and a failed final
read remains an error. All 26 scope and status cases passed in
`.build/phase1-inventory-bracket-unit.log`, including controlled replacement,
removal and final-read failure. The real-socket probe in
`.build/phase1-inventory-bracket-live-final.log` observed an empty disposable
identity, preserved an unrelated marker and created no test root; it did not
exercise a real candidate or kind lifecycle. Two older probe versions failed
because their expected status text or Docker call count was stale, recorded in
`.build/phase1-inventory-bracket-live.log` and
`.build/phase1-inventory-bracket-live-reviewed.log`; the corrected probe and
its independent execution trace are retained under the same prefix.

The status source, scope tests, built operator, unit binary, live probe and
execution trace SHA-256s were respectively
`272611093b67b93d84c14034045af47b9e22f6af88752a5ac236b649055f30b6`,
`4adc92f882b558ca90593eccad592842273b97a4183883cdfa7b4e6a00ff2e91`,
`148696bda6a1b1a1d0bab328e35f71bb8a1fb0c52a31f608bc026dde0a61341e`,
`98dd81647232badaae3b39ab76753a703f1c0dfc33a40109f18a9b8ecc4ace07`,
`535a982392d51512ab288070fc285ec0b0edad6701dce794a48a58d38c0170a4`, and
`4af82859e0573df45e55f087d3046b669bdc368c925ac58f6a5841db1d5006cf`.
This improves observation only: it does not establish mutation admission,
resource absence, or any Phase 1 acceptance case.

The final targeted rerun also covers label-only and name-only replacement;
all 26 cases passed in `.build/phase1-inventory-bracket-unit-final.log`. Its
scope-test source and unit binary SHA-256s are respectively
`ba9171a73195270db664a352eb2d0f30eb340a033922b08d9da58b1c99edf038` and
`14f6eae0959bc957c101d4d4a9e231301d96e8628600f2a32dd4f7f3092e3147`.
The operator above was copied to `.build/prodbox` with the same digest.

The public `test run unit` route now selects the existing six unit components
without authoring a deployment topology or configuration. It refuses a present
binary-sibling production config, unsupported coverage, and an AWS substrate;
other topology runs retain their existing isolation refusal. The initial
public run, `.build/phase1-public-named-unit.log`, failed four of 9,996 cases
in its first component and did not run the other five. Those chart-rendering
unit cases used the production EKS image observer and attempted to consult the
ambient kubeconfig; the run deliberately supplied `/dev/null` as kubeconfig.
They now use the existing explicit chart-observer seam for deterministic
projection tests. A corrected public run and the full Phase 1 runner, real
kind lifecycle and acceptance remain pending. The first isolation regression
also exposed a stale topology fixture assumption and failed in
`.build/phase1-named-unit-isolation.log`; the corrected regression passed in
`.build/phase1-named-unit-isolation-final.log`.

The four chart cases passed with the explicit observer in
`.build/phase1-named-unit-chart-isolation.log`. The public retry
`.build/phase1-public-named-unit-retry.log` passed all six components: 9,996,
27, 35, 935, 17 and 4 cases respectively. It ran with a clean environment,
`KUBECONFIG=/dev/null`, an unavailable Docker endpoint and empty AWS
configuration/credential files; the operator's binary-sibling configuration
remained absent. The runner source, CLI registry source, unit test source,
integration test source, operator and public-run log SHA-256s were respectively
`791719c85f47667be1c0991078dbbaa78d52e5d7e7493bf2702b8eb1ded07d2b`,
`a9cef345d3b3104b14fd6222ee457d89eaf103edd6a7ef81665c03fb3589a479`,
`3e34f1c1633bd8996f77b4ab5937ced7c0e07065ba44193170e04a488321a7d1`,
`af9b33aad61d9b14170e5ddd67344830b1f4d56d84e431da2281ffe7b57b4ac9`,
`675899f9a0e8160c578daebbd439f833d04a4db9429106febe91bd0ff56d4d74`, and
`073953516a32bd95a3b85d36fe43f891a79527a59565992b999b9b8140239af6`.
The named unit route does not yet accept `--config`, coverage or an AWS
substrate; the scenario/evidence runner and canonical gate remain open.

The named unit runner now supplies its own limited child environment: it keeps
the compiler path and home, clears other inherited settings, disables ambient
AWS credential/configuration selection and metadata, and selects an empty
kubeconfig and unavailable Docker endpoint. This is environment isolation, not
an OS sandbox or the stronger mutation boundary. The public CLI fixture in
`.build/phase1-named-unit-environment-isolation.log` verifies that poisoned
AWS, kubeconfig, Docker and generator settings do not reach its controlled
child and that all six suites are selected. The real public run in
`.build/phase1-public-named-unit-environment.log` passed all six components
with those ambient settings deliberately poisoned; its component counts were
9,996, 27, 35, 935, 17 and 4. The runner source, CLI integration source,
operator, real-run log and controlled-fixture log SHA-256s were respectively
`2ddedc0bf634665529b32210b6a8dee369412e995dedaeeb58cc631f7aa29fc5`,
`08794cf07e98f24371a9b39908821df81cae7948a4fbc610fc6b3bb583c2938e`,
`f4d9debc50ec34a6fa7fcc61f505543ab31e55a5c801d6df7ab2b9d1927777e6`,
`0a35d8f9ec0983196bd0237759e97ededbb65273da1de822dee784901d912068`, and
`41a4d86c370c86a4ec00ba2f6e6703dc7a314822f444dbefc26623bb4190f333`.

The public `test run env` route now selects the existing five local
environment integration cases through a dedicated suite selector, without a
deployment topology or generated configuration. It shares the named unit
runner's production-sibling guard, limited child environment and explicit
coverage/AWS-substrate refusals. The controlled isolation and selector cases
passed in `.build/phase1-named-env-isolation.log`; the actual public run
passed all five cases in `.build/phase1-public-named-env.log` with poisoned
ambient AWS, kubeconfig and Docker settings. The binary-sibling configuration
remained absent. An initial integration build failed on a fixture expression
precedence error in `.build/phase1-named-env-build.log`; the corrected build
passed in `.build/phase1-named-env-build-final.log`.

The runner source, CLI registry, integration entrypoint, CLI fixture source,
operator, public-run log and controlled-fixture log SHA-256s were respectively
`497941966515bdd4ed716e04cc10e0831629f932f6d1f6885279b846b200fae7`,
`5bd50971a50a96576394906b1a1cad8ad7472c4e3afab165302d5591b09c9ee2`,
`2953baa96939f635edd73053a402dfcd173308d715c53bddf34c5f6126e2aa53`,
`f090d23e9de18a40eca93d82f97e71bddf75ba6d626a27a4c28a56e3fe444cf1`,
`5a84bd55155ca374287fc0d0599357232174366c66be381c917e30d011ad1493`,
`894cb463326b0a6ccf2b2f23cfbcd0721bde2afe0c6fd566d953537b364d77da`, and
`00a7ac735d8d9f710f05d990290c801d0fe4f489f50e2b75acbf63e8ae79ff6f`.
These are local integration checks, not kind acceptance or the required
scenario/evidence runner. The named route still refuses `--config`, coverage
and AWS substrate; the corresponding legacy command remains until its owned
removal conditions pass.

For the pending mutation executor, this host's unprivileged namespace
capability was probed without creating a cluster or using credentials.
`bwrap` with a private network failed setting loopback, and with the network
shared it failed writing the user mapping; the exact outputs are
`.build/phase1-bwrap-network-probe.log` and
`.build/phase1-bwrap-userns-probe.log`. A separate disposable-child probe
observed Landlock ABI 8, allowed a file under its test directory, denied an
outside file read, and used a seccomp rule to deny creation of an IPv4 socket.
The unrestricted parent removed the temporary directory. The probe source and
output are `.build/phase1-isolation-primitives.py` and
`.build/phase1-isolation-primitives.log`, with SHA-256s respectively
`4d52cad38a8ea01009cf7719ecda0f7f2dc4fb8d791939d9b81a0f8517a2cc01` and
`4c176c9036b469f50224355dfccc926f8b86b28f2532d30aa11d42b76a3def74`.
This is an x86-64 primitive feasibility probe, not a mutation sandbox: it did
not test inherited descriptors, other socket syscalls, io_uring, filesystem
aliases, toolchain access, descendant settlement, or a mutant. The supported
executor must enforce and independently test the whole boundary before use.

Fresh scope preparation now creates a missing selected `.data` or `.test-data`
parent under a descriptor-verified caller-owned project anchor that is not
group- or other-writable.
It opens the parent without following links, synchronizes its creation, and
reopens the existing parent without creating it during the pre-publication
identity check. Existing unsafe parents, symlinks, stages and roots still
refuse. The other environment's sibling is not changed. All 30 scope cases
passed in `.build/phase1-auto-scope-parent-unit.log`; the distinct-scope
concurrent-parent case passed 30 repetitions in
`.build/phase1-auto-scope-parent-race.log`. The initial build was interrupted
to add the opposite-environment sibling case; the final build passed in
`.build/phase1-auto-scope-parent-build-final.log`.

The scope source, scope test source, operator, unit binary, focused log and
race log SHA-256s were respectively
`003dc9199dfd27428b347378cd4b0daf54feb2d40eb303dfbd7aa0cfc2195e30`,
`3d102c5d41c2f1d9999f01280cc87f5930717ba38c2a32eed7a440ef852b4ba3`,
`710fe2d6f96fb766ee58eec25a625ac5123d980f3a8735c6bffd85e525137b89`,
`f28332438183abd3d939d8ae6ee09c4193439626d47413ebe7a2eace7221a985`,
`a1bda0ffe1b0f5309693f2959ac96cdf47c492671e1c728f9ec1b58b681a782c`, and
`283bb824dd80259ed2438bdbb3e5bae8ae2a39ba87856512a1cde67d83721414`.
The writer is not yet activated by a public lifecycle handler and does not
establish cluster ownership, effect admission or Phase 1 acceptance.

The existing source-manifest recorder now reads admitted worktree files through
descriptor-opened, non-symlinked parents and a no-follow final descriptor. It
refuses hard links, oversized files and private runtime directory components,
then checks the held file, named file and parent identities after reading.
Historical committed capture also refuses admitted paths through private
runtime directory components before opening their Git objects. The version-1
source-policy bytes remain unchanged for historical reproduction; a future
scenario record must separately bind the recorder's safety implementation.

The 27 source-identity and cycle-identity cases passed in
`.build/phase1-source-capture-tests.log`, including private hard links,
symlinked parents, leaf links and a 200-iteration replacement race. Eight
historical counterexample cases passed in
`.build/phase1-source-capture-historical.log`. A real worktree capture read
1,762 admitted entries in `.build/phase1-source-capture-worktree-final.log`;
the earlier probe in `.build/phase1-source-capture-worktree.log` correctly
refused an invalid duplicate excluded-root declaration. Intermediate builds
were interrupted to add the private-directory guard and race case; the final
build passed in `.build/phase1-source-capture-build-reviewed.log`.

The recorder source, focused test source, operator, unit binary, worktree
probe and its final log SHA-256s were respectively
`581d0e7c90e16520ea616670c86652de37f4a17648afddbf0257bb6f165af30b`,
`dd2a84426926ed85326e34523b5feda701536e189a964676fa24cc149222e55b`,
`b760306d47e8d3f09723ec6a832793fe388a0d9b9e46ae85f2f65849394fc85b`,
`4a490ab666d3be0b8c787b608717a67178c266133376d680862d36572b79d9a0`,
`e653a5cbafccb4ea02ee278fde585e095aa271eca4a843aabed422c93147df56`, and
`b63e1af6d322b70da968c6f33138aac0e20fa5a5735c44bd7ad75d944470d1eb`.
These are recorder checks; they do not implement the independent scenario
validator, mutation executor, or any Phase 1 acceptance case.

An initial scenario-evidence comparison boundary now binds a report and a
separately supplied observation to the expected phase/case, deployment scope,
generation, run and operation IDs, source identity, binary, named artifact,
public configuration and command digests, and declared time/resource/spend
budgets. It requires a bounded, unique expected observation set and compares
primary outcome, cleanup disposition and observed results. Missing, stale,
foreign and claims that disagree with the supplied observation refuse; matching failures and
unobservable cleanup remain unmet rather than satisfied. Its five controlled
test groups passed in `.build/phase1-scenario-evidence-tests-final.log`.

The comparison does not create or authenticate an observer, enforce budgets,
decode an external report, fix the required observations for each acceptance
case, or prove a real effect. It is not yet used by a public command. The
independent outer runner and real observers must supply and authenticate those
inputs, preserve failed records, and prove A01-06 and M02 before this phase
can close. Intermediate builds were interrupted to include timing, budget and
artifact bindings; the completed source build and final test build are
`.build/phase1-scenario-evidence-build-complete.log` and
`.build/phase1-scenario-evidence-build-final-tests.log`.

The comparison source, test source, unit entrypoint, package file, unit binary
and focused test log SHA-256s were respectively
`1476b93cd4e247038a53f1a8c206e978b6fba31929e2da7f864512240dc555f7`,
`883452cfca7ede387c405620dc016d77376ec437b9baed38e0b87fd8f07a3971`,
`f830d640b48f2b5564d112364f850dc904799252640ef285ab49c8e790227f92`,
`a6b9746e568436305836c54c9fd6a86254032d035680c73b6ea6154bdda51051`,
`7b2e7daf720f27ff7cb34aee9404a12a2aef91e2872a540bf143db53fa6947e3`, and
`fb222128d0d3b75d4b81ca245490d386231b054864bdab2df650b5823d13d1b0`.

The comparison boundary now has a 64-KiB canonical JSON codec and a combined
decode-and-compare entrypoint. The decoder checks the complete serialized
binding against an independently supplied expected binding, rejects duplicate
or noncanonical fields and refuses missing, malformed, oversized, stale and
foreign reports. Incomplete reports can retain an empty observation list,
but cannot satisfy a nonempty required set. A boot-specific clock epoch is
also bound to the monotonic deadlines; the future runner must independently
observe that epoch. Eight controlled test groups passed in
`.build/phase1-scenario-report-codec-tests-final.log`. The earlier seven-group
run passed before the combined entrypoint and epoch were added; its build was
interrupted to add those checks. The final build passed in
`.build/phase1-scenario-report-codec-final-build.log`.

The codec source, focused test source, unit binary and final test log SHA-256s
were respectively
`e5090202591a2184af9a74483ce68158661db3ffb9e8b09627a607320057f0b7`,
`ecd245775406d3c364e042c5bcac14b078032064191e0fe3abaa486161532df4`,
`f8140bd6478789e392cc23202793eef4d414be6c3fd81186918c72fa8ec70e35`, and
`26b5400eca9af244db295ac325104f143391b11a18cc2cad91fdb41f5151822e`.
This internal codec does not read reports safely from a filesystem, authenticate
observations, enforce budgets or run a scenario. It is not yet connected to a
public command and does not establish A01-06, M02 or Phase 1 completion.

An internal report store now creates bounded, exclusive pending files under a
scoped run directory, synchronizes them, publishes without replacement and
reopens the published file for a descriptor-bound read-back. It rejects unsafe
file identities, foreign directory links, noncanonical roots and private roots;
an incomplete pending file is retained. A read-and-compare entrypoint obtains
a separately supplied observation after reading the report. Fourteen focused
controlled test groups passed in `.build/phase1-scenario-store-tests-reviewed.log`;
the concurrent-publication case also passed 30 repetitions in
`.build/phase1-scenario-store-race-reviewed.log`. The build passed in
`.build/phase1-scenario-store-build-final.log`.

The store source, focused test source, package file, operator binary, unit
binary, focused test log and race log SHA-256s were respectively
`ff8cfdb0ec2e36e8dbb4299a83b9744f155a99bc0c5a6b76e95818ff2573f450`,
`ed0d2570b67e720eb46c0a9b514e55b74a69a11fd48f5d31a47bb691d9896871`,
`2284c534039b6ff70ce352c2229d9a25f3cd6442f6d59ad3afe2e0b005ab4195`,
`b760306d47e8d3f09723ec6a832793fe388a0d9b9e46ae85f2f65849394fc85b`,
`10d8a601e915e3fed032804b70811917feef8c8f70702829ed6dfe66b308b33f`,
`a62256b9931dc297bdde77352ce6e93f0537a27fa336fa8b1bba5457c18a72ee`, and
`4461821633a37fdeab7dabedfb786a8c4728c3149127029171b45a8c587482a7`.
The store is not connected to a public scenario command and does not authenticate
the supplied observation or prove real effects. Its timeout is in-process, not
the independently enforced worker settlement required by this phase. Pending
file recovery, the real runner and observers, acceptance cases, mutation
calibration and the full gate remain open.

The public test dispatcher now reserves `all` and `phase-*` for the future
cumulative scenario runner and explicitly refuses them while it is absent,
before loading legacy topology or creating a run root. A public-binary
integration case exercised `all`, `phase-01` and `phase-10` against a disposable
project with a legacy topology and confirmed the refusal and unchanged sibling
configuration and test-root state. It passed in
`.build/phase1-reserved-scenarios-tests.log`; the build passed in
`.build/phase1-reserved-scenarios-build.log`. The dispatcher source, integration
test source, operator binary, integration binary and test log SHA-256s were
respectively
`4e5a6d1f177e0444b9a037fb2346bfa35967f8f37b504e4ebe623fb3ca159054`,
`e1743fe47c9b4003daa2f8d66046a7853d5a33806c5c50f938aa552854fd63e0`,
`e80cbbaf23cf8e24bd41e044711811c254378660e2d8e8a2d93d6b03732135fe`,
`23f3f0ab178ab7aa95cb5e8d990ef98cdc966772e13f73b4c80140eaea2aa352`, and
`6d1848cb6f734b380e771be4e80fa600bf4f689080f8bb5b838be4b3db5697eb`.
This refusal does not deliver the runner or any phase acceptance.

The legacy CLI integration suite cannot yet be activated as `test run cli`:
`test/integration/CliSuite.hs` contains two cases that invoke the operator-only
`nuke` confirmation ceremony with `PRODBOX_ALLOW_NON_TTY_INTERACTIVE`, one
supplying the destructive confirmation literal. The repository's operating
boundary forbids automating that ceremony, including in fixtures. The existing
suite was not run. A proposed named selector and its build were stopped and
the selector was removed before activation; the interrupted build log is
`.build/phase1-named-cli-build.log`. Replace those cases with appropriate
non-ceremony assertions and audit the remaining legacy suite's isolation
before the public CLI suite is enabled. This is an implementation obligation,
not evidence of Phase 1 acceptance or a reason to change the operator's
original-install recovery route.

One of those two cases now tests the same confirmation decision as a pure
function without invoking the ceremony; the actual handler uses that function.
The focused test checks invalid input, case sensitivity and the existing
trailing-space behavior. It passed in `.build/phase1-nuke-predicate-test.log`;
the build passed in `.build/phase1-nuke-predicate-build.log`. The handler
source, integration test source, operator, integration binary and focused log
SHA-256s were respectively
`53838011286faf675da4c85dc21e5308d60de9dc0527c80fe047ade2cf4798ad`,
`795bd9d6f8af1415411cdd9c74368fb75447db9e4c74df4e5acf74f619b8c10c`,
`2a28769ff0aef7a0dbb9a9ddbcaca1eccaeff6345358e75d96c69e4ce557d8a6`,
`2d396a8860fbfe9acfff7e702b97ecc4c3183c7d9c7df5dad75aea5cfdc237f8`, and
`22b3ab7d99b82434e375113d990e0f608b506c73d845480a7f2282b9cfeba68e`.
The other ceremony case remains. An attempted direct preparation fixture was
withdrawn because the legacy authentication path gives an ambient RKE2
kubeconfig priority over the fixture's selected kubeconfig. An explicitly
bound authentication/fixture boundary is needed before replacing that case.
The full CLI suite was not run or activated, and this check does not close any
Phase 1 acceptance case.

The second ceremony invocation has since been replaced with a direct selected
Authority-authentication fixture. The authentication module now exposes an
entrypoint that passes a caller-selected kubeconfig without ambient discovery;
the existing legacy entrypoint retains its existing resolution. In a disposable
fixture, the fake Kubernetes client recorded the selected file despite a
different ambient kubeconfig, and the unavailable signer caused refusal. The
first attempt failed because the basics loader looked beside the uninstalled
test executable; the corrected fixture installs that executable in its own
temporary project. The failure and corrected test are recorded in
`.build/phase1-explicit-auth-test.log` and
`.build/phase1-explicit-auth-test-final.log`; the completed builds are
`.build/phase1-explicit-auth-build.log` and
`.build/phase1-explicit-auth-build-final.log`. The pure confirmation case
also passed in `.build/phase1-explicit-auth-confirmation.log`.

The authentication source, integration fixture, integration entrypoint,
operator, integration binary and final selected-authentication test log
SHA-256s were respectively
`3aa3dfa586950477c8cac2b751a0f2e67eb176b2bce9b98935c46bb848845fdd`,
`fea47600a8312ee5dc3268c92434c73bdaa31d8b24870733f9a3e2bb516fd510`,
`a773b320d193010e1b9c8e435a18d7d31cb09b9cbe021572560edb388124baa0`,
`6edc0300f28e87d7f491724c47e65e513146256a50f885030ef30e0716ab9ba0`,
`ccd27a70edd822584be30f40cda7993c8c5aaaa63aaceee27d61a95b25f50b63`, and
`cc4857db188bc58c9823c145a389f3a5d14f0af487eaa55dd43336d3bb80f36d`.
The selected-path entrypoint requires its caller to establish scope and path
custody. This controlled authentication test does not establish the full
decommission composition or public lifecycle, and the full CLI suite still
requires an isolation audit before activation. No Phase 1 acceptance is
claimed.

Test deployment scope construction now refuses a project anchor containing a
`.data` path component, preventing the selected test root from being nested
lexically inside a production-data root. Explicit production-policy fixtures
under a test root remain constructible. The 30 scope cases passed in
`.build/phase1-production-anchor-unit.log`; the public selected-config fixture
in `.build/phase1-production-anchor-public.log` also checked that both
`config validate` and `control status` refuse the nested test anchor while
preserving a marker in its disposable production-shaped directory. The build
passed in `.build/phase1-production-anchor-build.log`.

The scope source, unit test, integration test, operator, unit binary and two
test logs SHA-256s were respectively
`3018610f5f11098db800f33c3e6953cbb5bab895e8037d39bf7d9a894ba8d24f`,
`5ed0447ae04bc7885ac17a43edd95a033bd0616731875ed51db6da6839e0d49b`,
`0ded981adcf9c397e2f3fe2570e4189666df17b0e222b9e2fbf35009a88c62c1`,
`9ef0cb0115c2c8636640204f7eb09e1b488c85e66cb13eaad8fd076c17eaa265`,
`c0cdb47ed650a05cc14cf5c47be4e99fb30724b352e6ab2593c76b9a118b8351`,
`8516ba500edc0286e4293a5a9abb79f9cf21b3d814980da1d423aebb1c152789`, and
`979495a981d3e9581dc3e0f6d1e57bc004ad9220b94ae286715c499d1a786741`.
This lexical guard does not establish filesystem mount-alias isolation,
ownership of a nested policy fixture, or the real kind acceptance cases.

The held scope-root walk now requires the selected project anchor, shared
scope parent and root to be caller-owned and not group- or world-writable.
Rechecks apply the same rule, so a parent becoming writable during a held kind
lease yields a changed-root outcome rather than a stable one. Fresh-root
preparation also synchronizes the anchor when the shared parent already
exists, including the concurrent-creation case. All 31 controlled scope tests
passed in `.build/phase1-scope-custody-tests.log`; the build passed in
`.build/phase1-scope-custody-build.log`.

The scope source, scope test source, operator, unit binary and focused test
log SHA-256s were respectively
`f8e7f62b28c7a84b09154e36de3b9e90ca1230ba335f1138d1b0f8b54d05165d`,
`d3752fb3b36754261c0eb3c1edb2cc3f557d14f1e04e76caca8f5d25a26d2db1`,
`689fcba327bc7218384f6996d997b59187b7de1af01e7b4db5176e40a3b651d4`,
`0667ae751bd18d44a292b87f737d63ea47cbed5371803520528c492fedce3e49`, and
`f7774b29671bbf93b9a5a33b5149ce3d5518feddce0ea188805a262de01030c7`.
These checks do not close the race after a recheck, prove power-loss durability,
detect mount aliases, authorize a kind effect or satisfy phase acceptance.

The named local `unit` and `env` runners now give their child tests an empty
temporary home while retaining the caller's Cabal store. They refuse to start
when the system RKE2 kubeconfig is readable or the access check throws. This
closes a gap in the earlier environment check: setting `KUBECONFIG` alone did
not prevent legacy code from trying the caller's `~/.kube/config` first. The
controlled public-runner fixture passed with a foreign home-kubeconfig marker
in `.build/phase1-local-test-home-isolation.log`; the actual public `env` run
passed all five cases in `.build/phase1-local-test-home-public-env.log`. The
build passed in `.build/phase1-local-test-home-build.log`.

The public unit run was interrupted and is incomplete in
`.build/phase1-local-test-home-public-unit.log`: its SSH retry fixture printed
simulated connection-refused messages, which were initially mistaken for real
egress. Source inspection showed that case uses its own fake SSH executable;
it passed before interruption. No unit-suite completion is claimed. No matching
unit processes or temporary test-home directories remained after interruption.
The runner source, integration fixture, operator, controlled test log, public
env log and interrupted unit log SHA-256s were respectively
`f66e84f6c1c6d0d0fbe92a8074eca59472a636513529f7eb951e793ac75bdb6c`,
`662386027718f612756ba76b0dd179059db8a374a3dcf659a118b72fba7be743`,
`838fd50a20177f8446d533200371bfd5d6acdfc28a6f950ccdd79edbdddb50ff`,
`d06007deb5c3c0fc133488337867d0cd4d4d775578a9043d04a18519b69a53c7`,
`08ca5ed150204e8a05f795f26b71f8997b821d781279783d069e6693fe2b7509`, and
`ae1bdeff548aab0717729089e5c658344518400fa19de2ede4d6d417f136e1bf`.
The environment is not an OS sandbox, the system-path check is not a held
descriptor or prevention of later replacement, and the stronger mutation and
full legacy CLI isolation obligations remain open.

The public unit rerun in `.build/phase1-local-test-home-public-unit-complete.log`
passed its first four components (10,017, 27, 35 and 935 tests) but failed two
of 17 style assertions on the same nested `case` in the scenario-evidence
parser; it therefore did not run its final Pulumi component. The failed log
SHA-256 is `86f7819d0082c19729d496f12d0270729ed5a7c93ac10f2491a2ccd05d831181`.
After extracting the parser decision into a named helper, all 14 focused
scenario-evidence tests, all 17 style tests and all four Pulumi component
tests passed separately in `.build/phase1-evidence-style-regression.log`,
`.build/phase1-evidence-style-repair-test.log` and
`.build/phase1-evidence-style-pulumi.log`. The repaired build passed in
`.build/phase1-evidence-style-repair-build.log`.

The repaired evidence source and the three successful logs had SHA-256s
respectively
`554b475df2105bef77a5914871b1f753dbae492a87010506b8d9a366187863c1`,
`770b139cf55195ef81b1618280c56a3df67d51599a0658fca65413a41480d886`,
`f576da40efa46901067f1112f9a3276d1ff671bd5623048cabcb43b671b30063`, and
`22360098dff0ad11339e471dc34c49a26d2c359079f728048457d4d78927e046`.
These separate results do not turn the earlier public command into a pass or
replace the required Phase 1 acceptance and mutation evidence.

The public unit command was subsequently rerun against the repaired source
and passed all six components: 10,017, 27, 35, 935, 17 and 4 tests. The log
is `.build/phase1-local-test-home-public-unit-repaired.log`, SHA-256
`d0daf1c06b948559aa1ac369cfa049f26814880b57bd643f271948a49880621a`.
The evidence parser, named-runner source and operator SHA-256s were
`554b475df2105bef77a5914871b1f753dbae492a87010506b8d9a366187863c1`,
`f66e84f6c1c6d0d0fbe92a8074eca59472a636513529f7eb951e793ac75bdb6c`, and
`838fd50a20177f8446d533200371bfd5d6acdfc28a6f950ccdd79edbdddb50ff`.
This is the named unit route, not the canonical full gate, the real kind
scenario or mutation calibration.

The selected Dhall reader now walks parent components and the final file using
no-follow descriptors, bounds the read, and reopens the path to compare parent
and file identities after reading. The public fixture first validated a direct
configuration, then confirmed that both final-file and parent-directory
symlinks are refused by the selected validation lane and that the parent link
is refused by `control status`. It passed in
`.build/phase1-selected-path-custody-public.log`; the repository style
assertion passed in `.build/phase1-selected-path-style-final.log`. The final
build is `.build/phase1-selected-path-custody-build-final.log`. An earlier
style probe was interrupted before completing when the fixture was corrected
to establish a valid target baseline.

The reader source, integration fixture, operator, integration binary, public
test log and style log SHA-256s were respectively
`1ee11fc3f930699b23288b4680904eb6b4c390ca3d5a7bfcf21b22a0f2dbd278`,
`cd77dc46838623bdab2d605c66eabbe39a3d55ebf7f7bde8c7f3453794d7246e`,
`21d01e0bfced8e25afdd2862ffad3321fa9b88a3beb578e5f2fdb2771565379f`,
`69bc8eea22a89b36dd3105747ec312e77090a85cde3830cd609c5e4a6db8444c`,
`89fb589257d53df68e7af848b17b4bb8771974b6ca83f2ea2d46d1a927a24dc1`, and
`cf6d620eea44cf698ed8a89fa83bef558bbc48ef5a3c047ae20f616f47e7be20`.
The read does not bind the document to a deployment, authorize a later effect,
or prevent replacement after the final observation. The public bootstrap
authoring and real Phase 1 acceptance remain open.

An internal selected-document publisher now validates bounded import-free
syntax, creates an exclusive pending file in an owned non-writable parent,
synchronizes the file and parent, publishes without replacing a destination,
and reopens the published path for read-back. It preserves an existing target,
pending file or uncertain publication. All 33 controlled scope/publication
tests passed in `.build/phase1-selected-publication-tests.log`; the concurrent
publication case passed 30 repetitions in
`.build/phase1-selected-publication-race.log`. The build and repository style
assertion passed in `.build/phase1-selected-publication-build.log` and
`.build/phase1-selected-publication-style.log`.

The selected-file source, unit fixture, operator, unit binary, test log, race
log and style log SHA-256s were respectively
`495a4bf293a857373980f9aeb8b10843140f178a2b6d10c678e9519f99acdfba`,
`507103394effb73e582423125169652d2159e18e90b635de36f2335b02089f5a`,
`814cb52e0316cfce5ac6181f5ea58ac430e6378226f2daf9fae37ad3983b1013`,
`47b5bce904669ff38fef4aa399c1e7ff7103da9dfd561b05fd939a6f29d11c5d`,
`1f7873c42ee7de7a3957facd0c4df4437a0b942d079b74b267ce4d92fa6b96c8`,
`0daeea92ab0520394ae4a6c8733c9edc44e0c5fd94d3c538c2e3de18bedd5a5a`, and
`fb383f4a2fc6952bbad0d042c9cb9109b18de250348d6288545e46c7f9077ff9`.
This internal publisher does not validate document semantics or destination
scope, supply bounded worker settlement, recover pending files, or implement
the public bootstrap setup command. Those remain required before use; this
controlled test is not Phase 1 acceptance.

The selected `--config PATH config setup` route now authors a validated,
import-free version 3 bootstrap document from bounded interactive input and
publishes it without replacing an existing file. For a test deployment the
destination must be its existing generation-bound root's `config/prodbox.dhall`;
the generation is observed before and after publication. The route does not
create or enroll that root, verify artifact bytes, start a cluster, or support
selected-source dry runs and plan files. The pending-file recovery command,
bounded worker settlement and protection against underlying mount aliases
remain open. An uncertain publication retains its outcome for recovery; it is
not evidence of successful setup.

The public binary fixture passed in
`.build/phase1-bootstrap-setup-public-final-reviewed.log`, covering destination
scope, existing-file preservation, validation, incomplete input and unsupported
options. The 34 controlled scope tests passed on an intermediate build in
`.build/phase1-bootstrap-setup-unit-reviewed.log`; subsequent changes concerned
help text and prompt output. The final repository style assertion and four CLI
golden checks passed in `.build/phase1-bootstrap-setup-style-fixed.log` and
`.build/phase1-bootstrap-setup-golden-final.log`. Earlier build and style
failures remain in their respective `.build/phase1-bootstrap-setup-*` logs.
The final setup source, projection source, integration fixture, operator and
public fixture log SHA-256s are respectively
`851ab1b04351cd9ecf326fa960bb9989adec85ffd34a0c2b2ca66a05cba09b6b`,
`a922a317d85cdce0d8078f255744569cda9b26282d1572269e5da4ffe49ef96c`,
`a65a6c1524099f2a5c2f87623313e83962c54b3fbe53014d1f6de11c2d1f4746`,
`088a27fc727b33d34b5ebe282042fd6ae6e6fff9a1f239ce25a40091feb3d052`, and
`0f6b3b7649e9e992fc553245ddb58845e6ac898680c16cf49db43485ab3cea4c`.
These controlled fixtures do not close P01-T01 or real acceptance.

Selected setup now also offers explicit fresh test-root enrollment when the
specified generation is unavailable. It validates the complete draft and exact
destination before this offer, creates the private configuration directory in
the same exclusive staged root as the generation record, and preserves an
existing or incomplete root. If publication subsequently fails, the enrolled
root remains for recovery. This adds no cluster operation or artifact
verification; bounded worker settlement, mount-alias isolation and a public
recovery procedure are still required. Validation for this newer path is
limited to controlled local fixtures: the public binary test passed in
`.build/phase1-fresh-setup-public.log` and checks explicit decline, successful
fresh enrollment, selected document validation, and refusal to adopt a foreign
root. All 34 scope tests passed in `.build/phase1-fresh-setup-unit.log`; the
repository style assertion passed in `.build/phase1-fresh-setup-style.log`.
The scope source, projection source, setup source, public fixture, operator and
public test log SHA-256s were respectively
`a32f27a7b04e3d40ab15da2e9d5c8f5f3afbea31e5431f6c4d52291f3b6b2a1f`,
`a8a223984ee026d35ff3ed195132d95f6a3964dea5deb794129594f38e86cc14`,
`8f66335f574ef3476af57ec6e7834362d9237a4183cb03e9f273b00ae395d60d`,
`02e02b80ca21c2f8e690e3216f50486d55dcb1630a0627fd7b7bf31fcf135e7c`,
`0787ae39b3ad9f2f5c19b6b09b39c6691d15edb649e73324408b3cb2bfa0cd48`, and
`01529cb30831ed6b240c6be6acf7741587c6bd443fff107e73dbf03ca430ae8c`.
These fixtures do not establish real Phase 1 acceptance.

Selected-document publication now acquires a nonblocking exclusive lease on
the verified parent directory before inspecting or creating names. Cooperating
publishers report contention without writing; other lock errors remain
unobservable. The descriptor lease is released after the publication attempt,
including exceptions. The lease is only a cooperation mechanism: existing
pending files can have been created by an older writer that did not acquire it,
so they still cannot be recovered automatically or treated as settled. A
durable protocol identity and bounded worker settlement remain necessary.
The 35 controlled scope cases, including an independently held lease, passed
in `.build/phase1-selected-lease-unit.log`; the competing-publication case
passed 20 repetitions in `.build/phase1-selected-lease-race.log`. The public
setup fixture passed in `.build/phase1-selected-lease-public.log`, and the
repository style assertion passed in `.build/phase1-selected-lease-style.log`.
The publisher source, scope fixture, operator, unit log and public fixture log
SHA-256s were respectively
`13bc8a8b0a1e10f367d0099f3cdc117eacb993f07d14c513fbe68c37f752dd4d`,
`5896b08c32506837ef15bb1911f02d1be6fa598e60d8620e1b5dc9febcce878d`,
`0963d3b5ef147d71bba000e4a612dcfe242a21bcc7b77000afb1b1ce93d3d915`,
`8b2f2ffc4c111eb776a30d16430ea668ec92c3bd221ac11d523167259c1efef8`, and
`a12450063b7c11b014a048d126cf291cc6a9f161d3afb9d0039dfdd6e0a792f6`.
This is not recovery or real Phase 1 acceptance.

The selected publisher now writes a distinct v2 pending name under the
cooperating parent lease. Setup can offer recovery after the operator supplies
the exact validated draft again. Recovery retains legacy pending names,
mismatched bytes and existing destinations; it checks the held file and parent
before a no-replace publication and observes the resulting bytes. This is a
limited local recovery path, not proof that uncooperative writers, bind-mount
aliases or interrupted post-rename outcomes have settled. Bounded execution,
durable lifecycle operation identity and real Phase 1 acceptance remain open.
The 36 controlled scope cases passed in
`.build/phase1-selected-recovery-unit.log`; the public setup fixture, which
simulates an interrupted v2 file, passed in
`.build/phase1-selected-recovery-public.log`. The initial style failure is
retained in `.build/phase1-selected-recovery-style.log`; after changing the
controlled fixture filename the style assertion passed in
`.build/phase1-selected-recovery-style-final.log`. Publisher, projection,
setup, unit fixture, public fixture, operator and public log SHA-256s were
respectively
`6620101536ad9f447f7b9e8505190e4cf55a8f640821f8d556b9285eeb11a600`,
`eb75e1dc05c6b22f7001575564ce5046de5b13715fcc981fbc66f869de64d3b7`,
`b7c1bbd894fcdd70021e15e84fc4121bdaaff9d5dfb31688fc752de983bfa505`,
`f43ce2f4276fe7a231031dd2db9d4ccfd1bb1475132c89b37dafedb3b6ef3fac`,
`ea8ba31cbcf5b7a4c9627083e80559578b773b7d960c948b6c59763aa4d32518`,
`508ee0b3ebcf80026e017606fc491c65c6f250c0638f1f4bd8d2740d2b0c8276`, and
`79a46fa48d9b381caa8285cbdd39098ecb7eace1abd563e061449d459a968dd8`.
These fixtures do not close any phase acceptance case.

`control status` now samples host `MemAvailable` and unprivileged-available
filesystem space at `/` and the retained root, separately from total capacity.
The bounded probe rejects malformed memory metadata and unstable root identity;
zero available space remains a valid observation. The displayed measurements
are volatile host values, not a cgroup budget, quota calculation, reservation
or proof of workload fit. In `.build/phase1-headroom-public.log`, the public
setup/status fixture reported 9313 MiB available host memory and 128257 MiB
on each filesystem; independent readings bracketing the call agreed within a
128 MiB tolerance for changing host use. This is a disposable local diagnostic,
not a real kind lifecycle or Phase 1 acceptance. All 37 scope cases, including
missing, duplicate, zero and overflow memory metadata, passed in
`.build/phase1-headroom-unit.log`; the setup CLI fixture and repository style
check passed in `.build/phase1-headroom-cli.log` and
`.build/phase1-headroom-style.log`.

The native probe, status source, scope fixture, operator, public probe source
and public probe log SHA-256s were respectively
`f3f916b7714749dc57419142123ae4315bfbcf6b71464fe6ccddd862b7be9dc8`,
`db79bbd38d873b6d04a30ecb37f308b7af4c8f39d451007ab8304d9aa8f35a22`,
`7d6b3430e5a9ed30ab83cd7b5c2f00007f6838e83cb0d06b4510f89503d2dc2d`,
`f8efdd25cdc9171818eda94d38beeac1b5243c66b81467f42d3af0bc769cdcce`,
`5e049a27b673a3a322fd76f70d367d3d6638f99fe3fcfde19ea7286be5821a0c`, and
`8efb7469832121c8dd9f4683289aa85abe4952465b8146e6a9081693fd2f1df2`.
Measured worker peaks, admission and real workload capacity remain open.

Selected setup now offers a read-only exact comparison when its destination
already exists. Under the cooperating parent lease, the comparison refuses if
a pending name remains, the destination differs, or its identity cannot be
observed safely. A match reports the currently observed bytes with publication
origin unverified; it does not assert that a previous writer settled or that
kind resources exist. Artifact ingress, bounded settlement and Phase 1 real
acceptance remain open.
The 37 scope cases and public setup fixture passed in
`.build/phase1-postrename-observation-unit.log` and
`.build/phase1-postrename-observation-public.log`; the repository style check
passed in `.build/phase1-postrename-observation-style-final.log`. An initial
build failed on an ambiguous local type in
`.build/phase1-postrename-observation-build.log`; the explicit type and final
build corrected it. Publisher, projection, setup, scope fixture, public
fixture, operator and public test log SHA-256s were respectively
`0f86d5ab3d69750842ff7d7ea747279c32bede528e79b6ca858b04ec59d20ed5`,
`d37eb3f476165de3ba15d947dd1b21dbdb676a182238995a2eed81f7de4ae602`,
`3de6746f62b49f08a8976e2a1aba22d6b59d6c119b0e04ff317e6fa275a4aa61`,
`278861069bfe3090193fa44b31e4ea9a09c49bf18e0ef9ab63d97ac6586e2491`,
`f777ffcb4a81fddf4249855a69adfdb8590009cf40270accd40bd4861405f2d3`,
`89803dec583f494e74acd735ae0c4bc32065cdd29f31a48dbbc14bd056e3a65e`, and
`624d74bc78d56c36f5078aaa5ac9a349acec5c99b136d6e2edd7dcd6bf496b68`.

The canonical `./.build/prodbox dev check` initially stopped at formatter
drift in seven Phase 1 source and fixture files; that failure is retained in
`.build/phase1-current-dev-check.log`. After applying the repository formatter,
the full gate passed in `.build/phase1-formatted-dev-check.log`: policy,
documentation, formatting, HLint and the warning-clean build succeeded, then
the four gated suites passed 10023, 27, 35 and 935 tests respectively. This
gate is regression evidence, not any real kind, mutation, isolation or cleanup
acceptance. It ran before this evidence paragraph was appended.

The formatted native probe, status, bootstrap setup, projection, selected
publisher, scope fixture, CLI fixture, operator and passing gate log SHA-256s
were respectively
`8a0cf35438b14c7acfcf10126147c9d140c39572a47c1aef1e404a411586579e`,
`8e23c6db4b5f7f782e8be58d6b62535114e2175059c7ba09b96f4d6cdcbdcb6b`,
`59616b4e0fbc5335e12ae3a20e8a2815fec0acc52374767dbc57a0a32b9a653f`,
`c813a7a982ad1c80fbed21a61f181af1b0edd5f0a2c3fce210c4bb2eda0cf336`,
`b20ea37f0ab23bb808f7c41fa2ccb1886b0e2e9562a6092e2ff864ff80ed41c0`,
`6cdcc17f93eeb9013cef17e6108a856dbaa4c60faaeb94fd2727b5da9df8e8f4`,
`b76e8666b88a20dce6ff27e0f104c02b72426fcc00d3a169d4261cdbbdf54645`,
`9aba0aa08fc671ed373e1fe683439a82bee507087d2df41f1af9accf9c909865`, and
`3cb1be15e3580f84eed689bbf12b25b8edb27ccb64e6a4b83250dc0ce13492a1`.

The public `control plan` command now renders the selected bootstrap's kind
configuration from the same structured projection used by the kind intent.
It reports that root ownership, artifacts, ports, runtime, CNI and cluster
state were not checked; it performs no kind or Docker operation. The selected
setup fixture checked the resulting cluster name and host root and confirmed
that no artifacts directory was created, in
`.build/phase1-control-plan-public.log`. All 350 parser cases passed in
`.build/phase1-control-plan-parser.log`; regenerated CLI goldens passed
without update mode in `.build/phase1-control-plan-golden-check.log` and the
repository style assertion passed in `.build/phase1-control-plan-style.log`.
The command registry, CLI entrypoint, public fixture, operator and public
fixture log SHA-256s were respectively
`b9efe94aba1f2139cbc834b6c3eae4a92dee8278fb605e20006480a4c004e119`,
`0d4452e55c5e3b18fdecdc02ec113bbbb69665f9f0c56b417d973d738152aa60`,
`b4df39f5b27fb7c17409e1ce6da61671174b0b8f27a9a293a727771cda011ed9`,
`b8bb5bdf0e24854dafdf4505eec640da6414e07f754ad6464fcfe2aed1384e72`, and
`0f6b3b7649e9e992fc553245ddb58845e6ac898680c16cf49db43485ab3cea4c`.
Planning is not admission or real kind acceptance. Artifact ingress, actual
reconcile/removal, CNI enforcement, measured capacity and mutation evidence
remain open.

The evidence layer now has a typed mutation-outcome classifier. It requires
a matching source, baseline binary, patch and test-selection binding, a
nonempty passing baseline, confirmed isolation and cleanup, and a distinct
compiled mutant before it can classify a test result. Only the designated
assertion failure without unrelated failures yields `Killed`; zero tests,
timeouts, crashes, stale identity, failed cleanup and unobservable isolation
remain `Inconclusive`. Patch precondition and compile rejection are `Invalid`
only when later stages did not run. The classifier does not authenticate
observations, run mutants, enforce budgets, prove isolation or infer reviewed
equivalence. It is an internal component, not the public mutation runner or
M00/M01/M02 evidence.

All 15 controlled scenario-evidence cases passed in
`.build/phase1-mutation-classifier-tests.log`; style and HLint passed in
`.build/phase1-mutation-classifier-style-final.log` and
`.build/phase1-mutation-classifier-hlint-final.log`. An earlier build was
interrupted to add the identical-binary and empty-baseline refusals; its log
is `.build/phase1-mutation-classifier-build.log`. The classifier source, test
source, package definition, operator and test log SHA-256s were respectively
`4fccefe5be7f2af5f46788e89ac9081cce294c9186c6603842e108eefaf46e5e`,
`9f544f93740b99718adb1d8636d8095599390ee2171ea8fdcee56c11cb967480`,
`6fc361967d8bb8f059b12da1f305b470264001ef951a92ae8beb01b0595bda50`,
`b8bb5bdf0e24854dafdf4505eec640da6414e07f754ad6464fcfe2aed1384e72`, and
`2a50fcf627b65f8b8550750b03428854a0e7b672d7521400b4c6dc98ae844789`.

The shared Tasty harness now has an opt-in single-test outcome transport. It
requires one selected test and an exact marked assertion, emits a fixed
outcome without test failure details, and distinguishes passing, designated
failure, other failure, exception, timeout and invalid selection. The evidence
layer decodes only the exact transport with the expected exit status and empty
stdout. This transport is not authenticated: an outer runner must bind the
actual selector, source and test binary, enforce isolation and budgets, and
independently observe cleanup. The missing-report M02 assertion now has a
preliminary source/test binding in the mutation manifest; no mutant has been
run through this transport.

The selected unmodified assertion appeared exactly once in
`.build/phase1-mutation-reporter-selection-final.log` and returned the fixed
passing outcome in `.build/phase1-mutation-reporter-baseline-err-final.log`,
with empty stdout. A compiled controlled reporter probe exercised pass,
designated failure, unrelated failure, exception, timeout, zero and multiple
selections, plus the unchanged ordinary reporter, in
`.build/phase1-mutation-reporter-probe-reviewed.log`. All 17 scenario-evidence
tests and the normal selected-setup integration fixture passed in
`.build/phase1-mutation-reporter-unit-final.log` and
`.build/phase1-mutation-reporter-normal-cli.log`. The initial integration build
failed because the reporter imported a package not declared by that suite;
the reviewed build uses the base `Foldable` interface. An initial style
failure and its corrected run are retained in
`.build/phase1-mutation-reporter-style.log` and
`.build/phase1-mutation-reporter-style-reviewed.log`.

The evidence decoder, shared test harness, scenario fixture, controlled probe
source, probe binary and probe log SHA-256s were respectively
`bd0ce7c4f0614b233dc074632d44101529e74cee16a673e9e327a213e8809750`,
`c6f1dc43a8b49e11d3ead20a9eab9fa3ea49f226615c75a1343c8b45bd9075bc`,
`48edcc90128f7e0d90e414042342046a4736a6603726e7749eacc7e80b4a3923`,
`deb9081c83c0480220ae35351513af3ab1d8173a9ac877aa4456433c5703e3ed`,
`2b3d72261cb8841ac459af7708604706b39c64fdc0bfd4dcd524cbe9c419c41f`, and
`1700cf73cc1abfbafd6af0a30ff79ca48c4270f9877f92257e1f7c55af005f91`.
These controlled observations do not close M02 or A01-07.

Mutation outcome classification now requires separately parsed baseline and
mutant test listings for the same reviewed full test path, each bound to its
respective observed binary digest. The parser accepts exactly one matching
line, successful exit and empty stderr; it refuses missing, additional,
different or contaminated output. The classifier requires exactly one
baseline and mutant test and treats missing or foreign-binary selection as
inconclusive. This binds supplied observations only: the future outer runner
must independently verify the binaries and selector and prevent a child from
forging the transport.

All 18 evidence cases passed in `.build/phase1-mutation-selection-unit.log`;
style and HLint passed in `.build/phase1-mutation-selection-style.log` and
`.build/phase1-mutation-selection-hlint.log`. The real unmodified Tasty listing
and fixed passing transport are in `.build/phase1-mutation-selection-list.log`
and `.build/phase1-mutation-selection-err.log`, with empty stderr and stdout
respectively. A separate local probe decoded those bytes and rejected an added
test in `.build/phase1-mutation-selection-probe.log`. The retained unit binary
is `.build/phase1-mutation-selection-unit-bin`. The classifier source, test
source, retained unit binary, selection log, probe source, probe binary and
probe log SHA-256s were respectively
`94004fa069c5592d9491cfa5664612e1ab1d5c1e5955d09da913d6f650e22b96`,
`da447f608225d7ad616392d4279c13944f0574d03a9754faf373cb470ee62d4d`,
`b2a85977516be94c3fb42f703748f30098c23ababb8797647f7dd70b0175ce68`,
`1c49bdc1ee63e747eed72e18755112ec1f4e3fa581479d07cb6fa07aa3e16d3d`,
`710a99a5404e5a290842b111c27865acab99d5968637a814edf7882a7e5f77dd`,
`a715ae2cb5cbcd5ebeedc10fef574e83ad61294837c7d8b24eb68121e7aa60ca`, and
`5a9d76c6ad6a61d0839c0125363b073223d6c9e1d2ad05bc4be47357c0fe703f`.
No source mutant or isolated executor was run in this check.

One M02 missing-report variant now has a closed implementation binding in
`Prodbox.Test.ReviewedMutation` and the mutation manifest. It accepts only the
reviewed source SHA-256 and one exact replacement site, then prepares candidate
bytes in memory. It identifies the unchanged marked assertion and a
domain-separated patch digest; it does not create a snapshot, compile or
execute a mutant. An independent in-memory calculation and the Haskell probe
agreed on the source, patch and candidate digests in
`.build/phase1-reviewed-m02-independent.log` and
`.build/phase1-reviewed-m02-digest-probe.log`. All 19 controlled
scenario-evidence cases passed in `.build/phase1-reviewed-m02-unit.log`;
style and HLint passed in `.build/phase1-reviewed-m02-style.log` and
`.build/phase1-reviewed-m02-hlint.log`. The reviewed-binding source, target
source, unit fixture, package definition, unit log and independent digest log
SHA-256s were respectively
`c64f414621e465fb3a964ba895a77fc8f307a5d9503f8824afff267e44dc016a`,
`554b475df2105bef77a5914871b1f753dbae492a87010506b8d9a366187863c1`,
`d10daf378e843a4173b0053777a5579f3a85bc5efea534eb749ab684e47aa8b7`,
`76fdf202e5226becab2fa0d3352f7521b32bc872467ebf99d6019b93845c4e4a`,
`0b6dd29158759a8aaa5cf6825bc763e9f403d890d3c56d3be92336f8af710a18`, and
`a8ba877e0aa0dd57aed618bbc4656b7205c23f2c900e83f1cfa056ccb2374c88`.
Compile validity, isolation, actual assertion failure, independent observer
meta-tests and cleanup remain unproven; M02 and A01-07 stay open.

The mutation worker boundary now has an internal x86-64 Linux seccomp network
filter. It sets no-new-privileges, applies the filter with thread synchronization,
denies native socket operations and the listed io_uring/cross-process routes,
and refuses unsupported hosts. It is irreversible and is not wired to the
public runner. In `.build/phase1-mutation-network-probe-observed.log`, an outer
observer saw the filter count rise from zero to one across eight child threads;
the child observed denied fresh IPv4 and Unix sockets, including an IPv4
attempt from a second bound OS thread. A positive pre-filter IPv4 socket and
the outer-created Unix socket pair established those paths were available
before restriction. The adverse control then successfully sent a byte through
the inherited socket using `write`. Thus the filter is explicitly insufficient
for mutant execution: descriptor custody, filesystem isolation, process-family
settlement, syscall coverage review, other supported architectures and the
complete outer isolation proof remain open. No mutant ran in this probe.

The library and unit suite built in `.build/phase1-mutation-network-build.log`;
style and HLint passed in `.build/phase1-mutation-network-style.log` and
`.build/phase1-mutation-network-hlint.log`. The filter source, package
definition, child probe source, outer probe source, child binary and observed
probe log SHA-256s were respectively
`9afb3316017deab292bcf25f3b048879662937593fe8ba0e54d202b8a1931ff4`,
`da613f8b80bfa6eab9a01c53606d3ba5ca09e969244004d1e05265fa827536ee`,
`f86bbc2cba44a5c654c35254c5132758b63eaaffd914dbf27bd2f1f4cff05588`,
`fcdf9003b9a3099aa7ee7d6ec41c585a01b324a56ffb29dbf42687cf9eb1b69e`,
`3a4292aa6dcbb44a9de1930dd9770c8e281db5541e2ffdc3dd8be30e3fd16d75`, and
`b787c4febefc1bcb67a39720877729afacd83fd6c3968fa64ceb63ff7c67f969`.

The internal x86-64 mutation worker preparation now offers a bound-thread
descriptor step: `close_range` unshares the calling OS thread's descriptor
table and marks descriptors above stderr close-on-exec. It refuses an unbound
thread and standard descriptors that are neither regular files nor pipes.
This operation is irreversible for that thread and must be followed immediately
by exec or worker termination. It does not authenticate the standard streams,
prove the descriptor table's origin, isolate filesystems, or authorize a
mutant. The future outer runner must own the standard-stream endpoints, prevent
new descriptor ingress before exec, enforce the filesystem/network boundary,
and independently establish process-family settlement.

In the controlled probe `.build/phase1-mutation-descriptors-probe-reviewed.log`,
an inherited Unix socket survived the unfenced positive control. With the
network filter and descriptor step, an outer observer saw that socket close at
exec and the child observed that a new IPv4 socket was denied. A second bound
OS thread observed and cleared close-on-exec in its own original descriptor
table after preparation; the exec thread's unshared table still closed the
socket. The probe also confirmed that an unbound caller and socket standard
input were refused. This is one host/ABI and one descriptor family, not a
complete isolation proof; no mutant was executed. The build, style, HLint and
19 scenario-evidence cases passed in `.build/phase1-mutation-descriptors-build.log`,
`.build/phase1-mutation-descriptors-style.log`,
`.build/phase1-mutation-descriptors-hlint.log` and
`.build/phase1-mutation-descriptors-unit.log`.
An intermediate probe build used an incorrect POSIX query name and failed in
`.build/phase1-mutation-descriptors-probe-build-reviewed.log`; the corrected
probe build and result are recorded separately.

The descriptor source, network-filter source, package definition, child probe
source, outer probe source, child binary and probe log SHA-256s were respectively
`8bc85375a4a5311789ad4aaa0f1501f445288352ae1dbee60ed76a7c7db77e5f`,
`9afb3316017deab292bcf25f3b048879662937593fe8ba0e54d202b8a1931ff4`,
`9c5eeff9acf762a17aa1fe7d7dfb60a5e407aaae2eb09f372c3681139a584488`,
`3dff2587ebbda12b131782d0794c918ffefa3185736f961a4614e7f9e3a2c7a6`,
`b4a602513fc058a3538187bd87599c3aed96d33ca5ec0d83649bf96b4250018d`,
`3fb401d19cbc1776b3ab7191f8323cded2fd797e9be8c678236186cc4c870c7b`, and
`53762db7e98905aa8b3ceae0efd7a89e9a620e33b2755944d2a250466cd334e4`.

The initial internal x86-64 mutation worker Landlock file-access step used a
caller-supplied writable directory and bounded read/execute roots. It requires
a bound OS thread, Landlock ABI 5 or newer, valid descriptors and distinct
exact inode identities. It is irreversible for that thread and is not wired to
the public mutation runner. It does not authenticate roots or aliases, revoke
open descriptors, mediate all metadata operations, or authorize a mutant.

In `.build/phase1-mutation-filesystem-probe.log`, a controlled worker applied
the network, Landlock and descriptor steps and then execed a test program. It
could read a designated dependency and write the designated workspace; direct
and symlinked outside reads, a dependency write and a fresh socket were denied.
The outer fixture independently verified unchanged dependency and marker bytes.
Two adverse controls remained possible: a pre-existing hard link in the
workspace exposed the outside synthetic marker, and `chmod` changed that
outside marker from mode 0600 to 0644. The outer process removed the disposable
fixture. These observed gaps require verified alias-free snapshot creation and
additional metadata-syscall controls before any mutant may run. The probe
also refused an unbound thread and duplicate root identity. It is not full
filesystem isolation or M02/A01-07 evidence.

The library/unit build and 19 scenario-evidence cases passed in
`.build/phase1-mutation-filesystem-build.log` and
`.build/phase1-mutation-filesystem-unit.log`; style and HLint passed in
`.build/phase1-mutation-filesystem-style.log` and
`.build/phase1-mutation-filesystem-hlint.log`. The Landlock source, network
filter, descriptor step, package definition, child probe source, outer probe
source, child binary and probe log SHA-256s were respectively
`e56ba9b06673b8072eda785a4fc8f145837492bd5b85754b3e9a61c464d5c481`,
`9afb3316017deab292bcf25f3b048879662937593fe8ba0e54d202b8a1931ff4`,
`8bc85375a4a5311789ad4aaa0f1501f445288352ae1dbee60ed76a7c7db77e5f`,
`e0a2ce2c1089f1d0f6b96470f5b0d4ed2b6b13187aff137c6c42ce0d222bf229`,
`746067b9d2baeb567f1ad10485e59479f1d33ee97d69c22a358d5c70c66b5d32`,
`bebff066a495893602dc06042b0872d5ccdb93226a3e715c5db915f6205bab62`,
`66b537ad6175855252107fa0f229c1257c77a5815284a1e2ebb6367371e718fe`, and
`5e53f5da9a3d0359b2e523d18134f5acdb3ada1b4b4285a283e422d396a31891`.

After that probe, the implementation was tightened to accept only reviewed
Landlock ABIs 5 through 8 and to refuse unknown later versions. The final
build, style, HLint and 19 evidence cases passed in
`.build/phase1-mutation-filesystem-build-final.log`,
`.build/phase1-mutation-filesystem-style-final.log`,
`.build/phase1-mutation-filesystem-hlint-final.log` and
`.build/phase1-mutation-filesystem-unit-final.log`. The controlled probe was
rebuilt against the tightened source and produced the same allow/deny and
adverse-control observations in `.build/phase1-mutation-filesystem-probe-final.log`.
The final Landlock source, final child binary, final outer probe source and
final probe log SHA-256s were respectively
`d843b906b89d02357204cda144fabc6d71fc3d6960dc81adf1ea1d2e75421341`,
`082f24468ba025533930f671ee71f44e8160f5c04d01d8c87bd9a4fcd6776bd8`,
`0e0af48534153f3b98c02b7c8bdb01e91ac23e84e3cfbcebf925fca456144c9f`, and
`5e53f5da9a3d0359b2e523d18134f5acdb3ada1b4b4285a283e422d396a31891`.

An additional internal seccomp metadata filter now denies an initial set of
metadata and namespace syscalls. It is not connected to a public runner and
its syscall coverage and compatibility with a real build remain unproven.
The controlled combined-filter probe in
`.build/phase1-mutation-metadata-probe.log` first confirmed that the outer
process could chmod the synthetic marker. After filtering, the worker could
not chmod either the outside marker or its own workspace file; the outer
process observed the marker still at mode 0600. Workspace writes and dependency
reads succeeded, and direct outside reads, symlinked outside reads, dependency
writes and fresh sockets were denied. The pre-existing workspace hard link
still exposed the outside synthetic marker. The outer process removed the
fixture. This is a partial control, not a mutant execution or phase evidence.
An authenticated alias-free snapshot, complete syscall and descriptor review,
process settlement, standard-stream provenance and build compatibility remain
open before running a mutant.

The library and unit build, style, HLint and 19 scenario-evidence cases passed
in `.build/phase1-mutation-metadata-build.log`,
`.build/phase1-mutation-metadata-style.log`,
`.build/phase1-mutation-metadata-hlint.log` and
`.build/phase1-mutation-metadata-unit.log`. The network-only probe was rebuilt
after the filter refactor and retained its observed behavior in
`.build/phase1-mutation-network-rerun.log`, including its inherited-socket
limitation. The filter source, child probe source, outer probe source, child
binary, combined probe log and network rerun log SHA-256s were respectively
`5f1f4fc926f92c193e4529d25a1f3894b3164b40a3b763acdf5fae4d3ff5a618`,
`96299cd20cd1f04dabe40523b35ec7368efde16b977be81037addffb5c9abe33`,
`992ae6fe9cff382233ad935c727ddcff43c6b630ed2d0d4bb6205d3217616511`,
`95b94aa8e055204ca4ee38290d88ed4fc5e1d0bad852f5f1aab25e559f4aad48`,
`40b88f496fd82d848d46d42cb60ff937ba1e26e7cf588c1ca5541c3190d8337c`, and
`b787c4febefc1bcb67a39720877729afacd83fd6c3968fa64ceb63ff7c67f969`.

The selected kind plan now rejects publication node ports outside Kubernetes'
default 30000–32767 NodePort range, which the rendered kind configuration does
not change. The bootstrap decoder reports the specific invalid kind-plan error.
The executable and unit suite built in `.build/phase1-nodeport-validation-build.log`;
all 37 deployment-scope cases passed in `.build/phase1-nodeport-validation-unit.log`,
including both range boundaries and an invalid authored bootstrap. Style,
HLint and the documentation check also passed. The kind-plan and scope-test
source SHA-256s were respectively
`f16f8d9656a56eccf81fd2979c725fb17cab37ea67424af527ab13103dff56d3` and
`e8974551dc5553c84c814fd410f29aa78e8d07e4a276393634ac663a4a3bdbdb`.
This validates the declaration; it does not reserve ports or prove ingress,
kind reconciliation, or any Phase 1 acceptance case.

Kind intent observation now treats a failure to reopen an already-read
record as unobservable instead of classifying an ENOENT from that second open
as an initially missing record. The executable and unit suite built in
`.build/phase1-intent-reopen-build.log`, and all 37 deployment-scope cases
passed in `.build/phase1-intent-reopen-unit.log`. A controlled `strace`
injection forced ENOENT on the second open during the existing matching-record
test; its trace confirms the selected syscall and the expected test failure
reported `KindIntentObservationUnobservable` rather than a match
(`.build/phase1-intent-reopen-injected-observe.trace` and `.log`). An earlier
injection hit record creation's read-back and caused the creation assertion to
fail (`.build/phase1-intent-reopen-injected.trace` and `.log`); it is not the
matching-record observation. These are controlled syscall faults, not a real
concurrent replacement test or kind lifecycle acceptance. The intent source
SHA-256 was
`a48a2624c4e29f57faae36a5350031c81998debb3557c3d2956a66cbee55455e`.

The intent and generation observers now classify ENOENT as missing only when
the initial record open returns it; later read, status, reopen or close errors
are unobservable. Descriptor acquisition remains masked until closure is
bracketed. The executable/unit build and all 37 deployment-scope cases passed
in `.build/phase1-record-open-boundary-build.log` and
`.build/phase1-record-open-boundary-unit.log`; style and HLint passed. A
disposable generation-record probe observed a match normally, then forced
ENOENT on the record's read using a path-filtered syscall injection and
observed `ScopeGenerationUnobservable`; both traces and results are in
`.build/phase1-generation-read-probe.log`. An earlier unfiltered injection
instead hit the dynamic loader and is retained as
`.build/phase1-generation-read-old-injected.log`; it is not evidence for the
record behavior. Repeating the intent reopen injection produced the expected
unobservable result and matching-record assertion failure in
`.build/phase1-intent-boundary-injected.log` and `.trace`. These controlled
faults do not establish kind lifecycle acceptance. The intent source,
deployment-scope source, generation probe source, outer probe source and
probe log SHA-256s were respectively
`df402a03b377ee23dd0abc6ff8e17d32c160c2f62bf3424aea54e56982d867d6`,
`b7de5521d47e6ccf790b12d659782d4b65f2c658f74cbbc0d7a7a9241988cd8b`,
`b09d4baebb1b4576597d461cbf7063d3d96a61ccc10ecbfd38beb5e45ee6e1ee`,
`06b60a10ea549ae2a79cfca3fb7ac65db5d12b58fb945130c8e29897179c1e9`, and
`cadd0026d14ad9806d6905d86b1e32b2e67e9a2af84de8f58a26b62c37214eec`.

Retained-artifact path traversal now classifies a missing path only at the
individual component open; a later I/O error is unobservable. Both the
read-only observer and the held-artifact path use that traversal. The
executable/unit build and all 37 deployment-scope cases passed in
`.build/phase1-artifact-open-boundary-build.log` and
`.build/phase1-artifact-open-boundary-unit.log`, including an ordinary missing
artifact. Style and HLint passed. A disposable synthetic-artifact probe in
`.build/phase1-artifact-read-probe.log` confirmed a normal digest match and a
held callback, then injected ENOENT on the artifact read: the two paths
returned `ScopeArtifactUnobservable` and
`HeldArtifactRefused ScopeArtifactUnobservable`, respectively. This does not
prove cluster effects or phase acceptance. In particular, preserving an
already-returned callback value if descriptor cleanup itself fails remains
open. The scope source, child probe, outer probe and probe log SHA-256s were
respectively
`3b6444899dfa062b03a7e08ef60e47e32e437d9ed50f262923e93f57d19f32a1`,
`9512d9760da2bead338c0babb0b10edce894b773c2ea6703c992c9fbab06230d`,
`7e044a1399ab728755d59abc11db5559be9a41eb9f2349a18ad3122ba9f1124a`, and
`19418b21b3ae5b639d4aa3a85a7839a4f76f453d4433e9f7cb475b6acf5c7cdb`.

The kind-specific prepared host placement now supports one child with bounded
exact binary stdin using the existing owned input transport and placement
deadlines. The caller must fund the input and transport in its runtime plan;
this boundary does not itself admit a kind effect. The native managed fixture
passed binary delivery through `/bin/cat`, over-limit refusal before child
start, a second-child refusal, interruption settlement and the existing kind
version observation in `.build/phase1-kind-prepared-input-native.log`. Its
own exact manager-family and runtime-directory checks passed; a separate
manager listing and scratch-root/PID check also observed those fixture fields
absent. The first standalone fixture compilation could not import a hidden
library module; the reviewed build used scratch copies of that module and its
two private dependencies, with the tested production library, as recorded in
`.build/phase1-kind-prepared-input-fixture-build-final.log`. An initial
`systemctl` check lacked the user-bus address and was repeated successfully
with the explicit user socket. The executable build, style and HLint passed.
The subprocess source, fixture source, fixture binary and native log SHA-256s
were respectively
`dddbd940fbc4e4daa5613f3d5147a876f34c64f1d2e10719c5f6905342d14164`,
`621e9499a1a1e63f9d30124330a36bd5a3948582fcdd52e060ee68ab007cf7b8`,
`5b623ec62db28bda0e2e20a176d4ae55f1fd93b26a692d51b887a14773519624`, and
`28471d9584b972857c3612ac0404503be6e060d1c40c0bff16b17f72c7c47430`.
This is a transport prerequisite, not public reconciliation, real kind
mutation, measured input-budget admission or phase acceptance.
The rebuilt daemon lifecycle suite also passed all 17 owned-subprocess cases,
including its 2,048-child settlement stress case, in
`.build/phase1-kind-prepared-input-daemon.log`.

The managed fixture now additionally sends the selected bootstrap's rendered
kind configuration through that input boundary to a disposable `cat` child
and compares the exact returned bytes. The identified run in
`.build/phase1-kind-config-input-native.log` passed this comparison and the
existing bounded-input, interruption, version and cleanup checks. A separate
manager listing and scratch-root/PID observation found the fixture absent in
`.build/phase1-kind-config-input-cleanup.log`. The first standalone build did
not expose the intended local package; the retry explicitly selected it and
passed with `-Wall -Werror`. Fixture source, binary and native log SHA-256s
were respectively
`1de0a818083750dd29ffdce5ba95abd486488e9d3ef29460d8985550763c6b8e`,
`36ee20363018cdbaded0ccb622586ab04f31f6c196fb19db291289673f4c8c9e`, and
`07367aa9c467cc6c0c81aa36fa79ff416c58da3d4aeb72bb820f3a1e2175424c`.
No kind create command or public lifecycle was exercised; resource admission,
configuration-input memory funding and cluster read-back remain open.

The sealed-tool planner now offers a combined input plan that adds two declared
input copies to heap requirements and a caller-supplied positive kernel
transport reserve before planning the executable snapshot. It rejects input
bounds above 64 KiB and zero kernel reserve. The focused arithmetic case passed
in `.build/phase1-kind-input-budget-unit.log`; the native kind-host fixture
used this combined plan and passed its input, configuration-byte, interruption,
version and cleanup checks in `.build/phase1-kind-input-budget-native.log`.
An independent manager listing and scratch-root/PID check found the fixture
absent. The executable/daemon build, style and HLint passed. The sealed-tool
source, daemon test, fixture source, fixture binary and native log SHA-256s
were respectively
`58587a099db4c37270c376fee6c567d9d4a89c028b222e775a450a12002b29b5`,
`e1d6209e69281df81a842fda963a240115b5f12d9d75ed209fcc8021e8848b21`,
`855262d6767d8ec1342660852c1d63d9e24dfe91beab7c8fbca0c9146dc89636`,
`e1b28827678bc5bad1c214c6391c63b619412a89ef0e8663058e69f1352df07d`, and
`c9c8a875e7905c14703a9363228572d7ad3b9ada8186cb0d06c7bb8274e736e3`.
The transport API does not yet require this planner, and the supplied charges
are estimates rather than measured peak usage. Public admission, reconciliation
and phase acceptance remain open.

The kind prepared-input transport now requires an opaque combined sealed-tool
budget and uses its exact runtime plan and input maximum. A plain tool budget
is refused before preparation, and a combined budget for a different plan is
refused by the placement. The native manager fixture passed both refusals,
bounded binary and selected-kind-config delivery, single-child enforcement,
interruption and exact fixture cleanup in
`.build/phase1-kind-funded-input-native-final.log`. A separate manager listing
and scratch-root/PID check found its fixture absent. Four input-focused daemon
regressions passed in `.build/phase1-kind-funded-input-regression.log`; the
executable/daemon build, style and HLint passed. The sealed-tool source,
subprocess source, daemon test, fixture source, fixture binary and native log
SHA-256s were respectively
`aaa836edc746adbda23a058d3eef89aefbe22fffc66e470c36e6064f44e67d31`,
`37e0ddfea7ca7f84eb4f933a27a6d6ce4a16cbaa85a90f1b72a7fd0aeddcf21a`,
`3aba5f9a2efcc8a01867d0c47324335006577202f3a2ccd68a83b38425faca69`,
`26af102a4f249f43187f05fccb82393f15818c8c0c9280f59d5f0a5946a8479e`,
`48f340a82bc5edfbef36254222842f4b1a890ac95e5c0583f8862dbd4e5fe29d`, and
`3858015b27a8b2ebf767a815465043ce9dea74bcb81ad5c3a870fa8704782220`.
This enforces the declared planning relationship, not measured peak usage,
public reconciliation, a real kind effect or phase acceptance.

The retained kind-tool interpreter can now run a read-only cluster inventory
inside its managed placement with the selected Docker socket and provider
explicitly set. It validates the returned names, refuses duplicates and
malformed output, and returns only whether the selected name was listed. A
negative result is an observation, not proof of absence. The native fixture in
`.build/phase1-kind-inventory-native-final.log` observed its selected name not
listed and confirmed that an unavailable socket yields a failed observation.
Independent Docker label reads before and after found the same empty selected
inventory; no positive real-cluster control was exercised. The fixture's
manager units, scratch root and interrupted worker were observed absent after
the run. The parser regression, executable/daemon build, style and HLint
passed. The kind-tool source, daemon test, fixture source, fixture binary and
native log SHA-256s were respectively
`0528f3ab461cc58524bf2adb91f70ad30f5e1a22b4bf996604c9e8ced01cce70`,
`b31f0eab22c8e9821bbb24a52681eb4c6a479123a17ac8d6eb0719c0abd934c7`,
`3fe9eb53c9a0478b45b9c6ebc85c8f85094c10bda2a2c4054a61c2e886d85aca`,
`f8c3e65e0cf5d882d8414897230d9d1eea86e32ef8d3daff5af03e8b963193dd`, and
`510b13c6701037d5737ce1999254412fda05e63b9d8db09ed5efa4e3f6a70282`.
This internal read-only adapter is not public reconciliation, independent
proof of absence, a kind mutation, or Phase 1 acceptance.

An initial control-root volume model derives a PV/PVC identity from the
selected root, cluster, generation, namespace, service and volume. It renders
an explicit prebound claim, a `Retain` PV, and a required-existing hostPath
under the generation-specific mounted control root. Invalid coordinates,
generation and capacity refuse before rendering. The executable/unit build,
style and HLint passed; all 38 deployment-scope cases passed in
`.build/phase1-kind-volume-unit.log`, including scope/generation separation and
the PV/PVC pairing. The volume source, scope-test source and package definition
SHA-256s were respectively
`b058c8c64b7b51675afbab39f6877a455de1092798ebf1908e0966d4ca03c6bc`,
`4656f8e4f70c38929f0ea3debf1b8e015884257ef032cc7f51b79478855747e5`, and
`864fe000fb1008d2c5a796afff3620a686b70f04ee356015b21242f26de47eb2`.
This model is not yet used by a public command, does not prepare or validate
the host directory, and does not cover Vault or application roots. No PV, PVC
or Pod was applied; real binding, changed-generation refusal, recreation and
cleanup remain open.

The control-volume model now has a descriptor-relative host-directory observer.
It checks the selected root generation, holds a no-follow first path walk while
reopening and comparing the directory identities, and rechecks the root and
generation. A controlled filesystem case covers missing and matching paths,
wrong generation, unsafe permissions and a symlinked path. All 39
deployment-scope cases passed in `.build/phase1-kind-volume-observe-unit.log`;
the executable/unit build, style and HLint passed. Volume source and scope-test
source SHA-256s were respectively
`1b598ed1a345e93df9b93dea7c765d2daae45f131b8eb935a52332d9640376c9` and
`0b419e3b0d51baadb237659e4b3ed293a861803a1a085df8668e75119f4a179a`.
This is a local observation, not directory creation, a durable volume identity,
bind-mount authentication, authority to attach, a public operation, or a real
node/Pod observation. Path replacement after a check and bind aliases still need
the lifecycle boundary and independent read-back.

An initial separate PV/PVC read-back classifier now checks the candidate names,
namespace, storage configuration, hostPath, claim reference and claim UID,
binding phases, object identities and resource versions. Terminating objects
are not classified bound. A controlled object fixture passed matching, wrong
UID, foreign path, unbound, terminating and malformed cases in
`.build/phase1-kind-volume-readback-unit-final.log`. The executable and daemon
suite built, and style and HLint passed. An earlier build exposed shadowing
warnings; they were corrected before the final focused test. The volume model,
read-back source, daemon test and package definition SHA-256s were respectively
`885ed75c36b036a34bcdbac193211499b08331524cccf2b13dfa87fe5a2ea4ed`,
`32551e1c228e1ace3c27675506ec95dc1878ef97d409cb4f2d54e9bf8481e7d8`,
`052c32f13f97530ad6692b2d33eda3642fa2fa20efb5a4eb2b9b95ecf754353b`, and
`1427e46118925c0f7c4b993b4658d608725b5a00f0d3cb02d9ccbf54652bedd3`.
The classifier consumes supplied objects; it does not fetch or bracket API
reads, authenticate their cluster, prove a Pod mount, or authorize an effect.
No real Kubernetes binding or Phase 1 acceptance is claimed.

The PV/PVC classifier now has a bounded-by-caller read bracket: for a matching
bound pair it reads both objects again and reports stable only if both object
identities and resource versions still match. A non-bound first pair remains
unconfirmed; changed pairs, staged reader failures and malformed input remain
distinct. Controlled cases passed for stable and changed observations, denied
second read, malformed first object and an I/O exception in
`.build/phase1-kind-volume-bracket-unit.log`; the executable/daemon build,
style and HLint passed. The read-back and daemon-test source SHA-256s were
respectively
`780bbc2da2398a8b53b4808e1d18e636794811d8b025c7bca8fd1b09bff8d1b2` and
`88e0db69ce651b91fb3fb93f38459c29d107c94b6cc496b9cec67cc17041745c`.
The caller must still provide bounded readers authenticated to the selected
cluster; no such production adapter, real Kubernetes binding, mount proof or
Phase 1 acceptance was exercised.

An initial kind-kubeconfig semantic projection now accepts only one selected
kind context, the selected loopback API endpoint, and bounded canonical
embedded CA/client certificate/private-key bytes. It refuses extra fields such
as exec plugins, external key paths and insecure TLS flags; the projected type
has no `Show` instance. Controlled synthetic fixtures cover the matching shape,
wrong endpoint/context, malformed or oversized material, extra credential and
TLS fields, and multiple entries. The focused case passed in
`.build/phase1-kind-kubeconfig-projection-unit-final.log`; the executable/daemon
build, style and HLint passed. Projection source, daemon-test source and
package definition SHA-256s were respectively
`192c0f4e525ff8e7d2b574b6c5c0cd48f75ac69987426664e97acd5020f3c0fc`,
`c1519f622b539ec9fd94bbab38f4e4f0bb849e22224d188ae2e6aa134c6b834c`, and
`a08aeccf6dfe9bec7b94dade13e40eb02411b4fd695547dd347b6e718fbfc02d`.
The caller must still supply a bounded duplicate-key-rejecting decoder and
authenticate the file and cluster. Certificate parsing, TLS peer verification,
secret lifetime, actual client wiring and public lifecycle remain open; this
is not a real Kubernetes read or Phase 1 acceptance.

The kind-kubeconfig projection now has a bounded YAML decoding path. It limits
input bytes, event count and nesting; rejects invalid UTF-8, aliases, anchors,
explicit tags and merge keys; and rejects duplicate-key warnings before
semantic validation. Controlled cases passed for the selected synthetic
document and for duplicate top-level/nested keys, alias, tag, merge, invalid
UTF-8, oversized, deeply nested, excessive-event and multi-document inputs in
`.build/phase1-kind-kubeconfig-yaml-unit-final.log`. The executable/daemon
build, style and HLint passed. The YAML decoder, semantic projection,
daemon-test source and package definition SHA-256s were respectively
`dd754a1eb2da7b43810a8a714baed13260a1dd6654124270ed08f3fef126eaa0`,
`192c0f4e525ff8e7d2b574b6c5c0cd48f75ac69987426664e97acd5020f3c0fc`,
`41c18b92b94414cf368421255f6370d51ec10f9f58538bddd572615ad3280dd4`, and
`fab64af371ef95f270c35cb4a0b1c76fa9169ce0a1c808b6f9b2905f6b28f188`.
This accepts bytes supplied by a caller; safe file acquisition, authenticated
cluster identity, certificate parsing, TLS peer verification, client wiring and
real lifecycle evidence remain open. No secret kubeconfig was used in the
fixture or included in evidence.

The selected kubeconfig now has an initial descriptor-relative file reader.
It requires the selected root generation, private owner-controlled `control`
directory and regular single-link private file, bounds bytes and applies a
five-second cancellation deadline, holds descriptors through YAML decoding,
and rechecks file identity, root and generation before returning the
projection. All 40 deployment-scope cases passed in
`.build/phase1-kind-kubeconfig-file-unit.log`, including synthetic matching
input, unsafe file/directory permissions, hard link, symlink, oversized file
and wrong generation. The executable/unit build, style and HLint passed. The
file-reader source, scope-test source and package definition SHA-256s were
respectively
`4a0c7958a106e434db9b9db85e49b214849cb90eecd51ac1f8eddc790800f817`,
`f7ca72fbd89ab1162b6bdefa4795594850b9cb570568ea5cefaf5c600b3c9b42`, and
`3f717ba4c5e4254f44d0b1d04b40c549681adc9de5cda07df06671b878ca82b1`.
Only synthetic key material was used. This local snapshot is not authenticated
cluster identity or authority; certificate and TLS validation, use by a real
client, a stalled-filesystem deadline proof and real acceptance remain open.

An initial in-memory TLS-material parser accepts one PEM CA, one PEM client
certificate and one unencrypted private-key block without exposing a `Show`
instance. A disposable synthetic OpenSSL fixture in
`.build/phase1-kind-tls-material-probe.log` passed valid parsing and refused
malformed CA, client certificate and key. Its adverse mismatch case showed
that a different private key still parses successfully: the underlying parser
does not establish key/certificate correspondence. The fixture removed its
temporary files and did not record key bytes. The focused invalid-material unit
case, executable/daemon build, style and HLint passed. TLS source, daemon-test
source, probe source, outer probe source, probe log and package definition
SHA-256s were respectively
`766eaed854dd54e0ca7d0cfd0ba985c4c390e09d17447c56207f0ed4b0b0a650`,
`11d236fcafcdae3bbeef2e6afc0486937888d067f586d8a90dd04ade6a1ed766`,
`b21ce350d4120bee92308323d05d018aae5f2668deb844fbaabe54b237741221`,
`0f71a2b0d9df5bf75af58452a53249a02fad7a9ef859c45cdc4fd5cf4e3d31a5`,
`204103011d646a957e3eb274e27ce3306a79e0bc72ac7603cc9eb7b357a2fd2b`, and
`497724e26e24c720399e7fde5c487a0c3f98820ed58982c688eb7a899ddf962b`.
Key matching, certificate validity and trust, authenticated peer identity,
secret lifetime and any real client request remain open. Parsing is not
authorization or Phase 1 acceptance.

An initial internal kind Kubernetes volume reader now composes the scoped
kubeconfig projection, in-memory client credentials, a loopback-only mutual
TLS connection, bounded JSON responses and the PV/PVC read bracket. It binds
the volume to the same declared deployment scope, disables ambient proxies,
redirects and TLS key logging, checks the configured CA chain, server-auth
purpose and exact loopback IP SAN, and exposes only read-only named PV/PVC
requests. The CA comes from the local kubeconfig and is not yet independently
bound to an owned cluster.

The local synthetic mTLS fixture in `.build/phase1-kind-mtls-reader-probe-final2.log`
passed a stable four-read binding, changed resource version, foreign-scope
refusal, denied/not-found responses, redirect refusal, duplicate-key/non-JSON
and oversized response refusal, wrong CA, mismatched client key, wrong IP SAN,
wrong server purpose, expired server certificate and slow response. It poisoned
proxy and TLS key-log settings, checked exact request counts/paths, and removed
its temporary synthetic certificates and server. The initial IP-only SAN
case failed in `.build/phase1-kind-mtls-reader-probe.log`: the library's
default name check rejected it. The final reader retains the library's chain
and validity checks while requiring the exact IP SAN explicitly; the original
failure and diagnostic are retained. Three relevant pure regressions, the
executable/daemon build, style and HLint passed. Volume model, kubeconfig,
YAML decoder, reader, child probe, outer probe, child binary, probe log and
package definition SHA-256s were respectively
`edeea2baf4c9c936fc55e5c717fb953f0dbf69a179eb31bd69c2b0c07dd298ba`,
`cb0831d80eb3089ead76fa1ef34d1b51d326f5235b46c47beedf4c4715b8b5d7`,
`b9d284be31121cf1c0038bab126a55481a1c448330ab58f39daa7259edd8237e`,
`c9d912bc4cc4f602d359d81097a183e64929b34714f8410f36c202f3da0f103b`,
`68d4da9bae864f8c0a9a3c2d21dfd57f8b99fe1f83da11c868424f4d9fd76dda`,
`a87b1a5bc2c0ba0d17dd7a1baab70e4342713fd4a12c70a27c411135c8100f70`,
`ba908f7ec811f4a008a4684ce55ddcebd3950775c25a076a844ae267f9673349`,
`c7a9847efe5caab3a22c3b891961e9fadd347ab38d04cb2bc0dfe52206f587bc`, and
`feb368d4b8dd37ff571b158bed17680e858521b50e20457148731394a00b48a2`.
This is a controlled loopback protocol test, not a real Kubernetes cluster,
independent CA ownership proof, Pod mount proof, public operation or Phase 1
acceptance. At that revision each network read had its own deadline, while a
whole-operation budget, credential erasure and recovery remained open.

The internal reader now also applies a ten-second deadline to the complete
TLS setup and PV/PVC read bracket. The controlled synthetic mTLS fixture in
`.build/phase1-kind-mtls-reader-probe-deadline.log` repeated the above cases
and paced four otherwise individually timely requests: the complete read
returned the explicit deadline error after 10.01 seconds. A separately slow
first request returned its existing read failure after 3.02 seconds. The
executable and daemon test target built, three focused regressions passed,
and Fourmolu and HLint passed. Reader, child probe, fixture, child executable
and fixture log SHA-256s respectively were
`fbd8508ef2e35b2383d5720adfd5572435947fa0e765d2dbd5458345a3adf7e0`,
`9ae5f9fbd6df7c84bb2214fa96a4dd53134321a42b97c23ce4f4a0b6c209b480`,
`db3542e6643f51538b16ec6e65a4d03ac303d839071f1ad6d8bd393f7610ca1d`,
`e3d0194acaa5793957f5e9dfba558cb1a55ba96591040cb16a8394950176a8e7` and
`f565a13e91ef743a06724d5a1abca97be4e9814792c41e32e6ef8b0b15b055a1`.
This cooperative deadline does not establish a hard bound on uninterruptible
foreign or kernel operations. The preceding ownership, real-cluster, public
operation, credential-erasure and recovery limitations still apply.

The public `control status` now also reports the selected local kubeconfig's
descriptor-bound structural validation, without displaying its material. It
continues to state that cluster identity and certificates are unverified. A
public-command probe with a freshly enrolled disposable test root checked a
missing file, a selected structurally valid file, a foreign context, unsafe
file permissions and a symlink; it checked that a synthetic key marker was not
printed, that the symlink target remained unchanged, and that poisoned ambient
Docker and kubeconfig selectors did not select the target. The fixture and
result are `.build/phase1-kubeconfig-public-status.py` and
`.build/phase1-kubeconfig-public-status-final.log`. All 40 deployment-scope
unit cases passed in `.build/phase1-kubeconfig-status-unit.log`; the executable
and unit targets built, and Fourmolu, HLint and documentation check passed.
Status source, kubeconfig file
reader, executable, fixture and result SHA-256s respectively were
`6e5a1f80db8f493a45a28f6c1c6507d735e922731546b6f6189f30e088ad2ea0`,
`4a0c7958a106e434db9b9db85e49b214849cb90eecd51ac1f8eddc790800f817`,
`33b0e7f8137916291c44ec4aadc025f70a543b563a95d7cad7d861fdbd8b751b`,
`1e5a27832ace7f3547edc230e3d7f926b2fb3922fb96f3a1e404880ad167391b` and
`c7da9e1f160976429273c9e18ce03a755c3bdf844eda5ba7f8c23158375f643a`.
This is a read-only local diagnostic, not a real cluster, ownership proof,
lifecycle operation or Phase 1 acceptance.

Selected bootstrap setup now uses the same fresh-root enrollment and generation
checks for production and test. In both cases the selected destination must be
the selected root's `config/prodbox.dhall`; an existing or incomplete root is
not adopted. The public CLI fixture in
`.build/phase1-production-enrollment-cli.log` exercised decline and enrollment
for a production-shaped root under a disposable project, checked its planned
kind identity and mount, and confirmed the separate test document and sibling
marker survived. Five bootstrap projection unit cases passed in
`.build/phase1-production-enrollment-unit.log`, including wrong generation,
cross-root destination refusal and existing-root refusal. The executable, unit
and integration targets built; Fourmolu and HLint passed. Projection, setup,
unit test, CLI test, executable and CLI-result SHA-256s respectively were
`1e99654355513e74ab47d36a8607c692b1af9af203c393483457150355dc9a92`,
`b1d4f1c35d32f5e0e0014d3e1831a4baae92541263a75e8d128890a715b73b5d`,
`2ebec6f552c80bbf005f4a77acffdcc1845331050132bac9ff2393500ee14489`,
`c1f9176f68cfdd1fa4fb96729c7a40942bc4d8a8d2a068b433444b6b78908b16`,
`e9efc014cc4489dd6b97dd07512f58fa3a1c973e865a617890a99d6f98e691f7` and
`326cfd3555fd0f71fc6e8edae41050883db1c6ce1d73d9d9ea9e9eb573d94d6e`.
This tests enrollment and configuration only. It does not establish physical
mount-alias exclusion, lifecycle admission, cluster creation or acceptance.

The retained-volume model now has an internal bounded directory preparation
step. It checks the selected bootstrap scope and generation, rechecks the
caller's operation boundary, creates descriptor-relative private directories,
syncs them, refuses existing leaves, and preserves partial work as incomplete.
The focused unit case in `.build/phase1-volume-prepare-tests.log` used a
recorded operation and checked foreign-scope refusal, an existing leaf, a
symlink and retained markers. The controlled interruption probe in
`.build/phase1-volume-partial-probe.log` stopped after a parent was created,
observed incomplete work and resumed the same intent to create the leaf. The
initial build failed on an ambiguous exception type in
`.build/phase1-volume-prepare-build.log`; the corrected executable and unit
targets built in `.build/phase1-volume-prepare-build-final.log`. Fourmolu and
HLint passed after formatting the test; the tested pre-format test SHA-256 was
`722e76568812147dca25a39a03747620b5e61cc45899ca2bf7d511d53a00650d`.
Volume source, formatted test, interruption probe source, probe binary, probe
log and unit log SHA-256s respectively were
`d7d8110645ab0107d8788f9ea8e5169e16911049f16c6d5aab57e4f9e740cda5`,
`e82c7998688fa317a9eee1aa3cede4025373306f54c75d6a0d1a269cc323a6f7`,
`7e9fd9274e19b9c017d41b804bd56d9cabb706060534086b7e3e138e3c30640f`,
`239af060c9f22e6c2f00fd1df9de64b1e2c7ad5befcb469ff164c20e2a0d340d`,
`d2274229b0440eb2288bac8c739e774b6f6b524fcbaa343451b6adbb11776051` and
`67b21a14e5d4aecd6e3acb7c80bc512681f0d819ada7189fec2154518bdbe5cc`.
At that revision the helper relied on a caller-held lease and intent but did
not bind volume coordinates into the durable record. It did not grant
admission, prove mount-alias exclusion, expose public recovery, or prove a Pod
mount.

Volume-specific operation records now bind the selected volume name, namespace,
node path and capacity alongside the existing scope, generation and cluster
plan. Volume-specific recovery checks those coordinates before invoking its
callback; a generic cluster-only recovery does not accept such a record.
Generic status labels the record as requiring volume-specific verification.
The three focused old-intent and volume-operation cases passed in
`.build/phase1-volume-intent-unit.log`, including different volume and capacity
refusals. The controlled partial-directory probe passed using the new record
in `.build/phase1-volume-bound-partial-probe.log`. The executable, unit and
daemon targets built, and Fourmolu and HLint passed. A daemon test selection
matched zero cases and is not counted as evidence. Intent, lease, volume,
status, unit test, probe source, probe binary and probe log SHA-256s were
respectively
`381dd89419312139f8cb9438d5269ab10bb2e58683ec8c0d4ab90e5c9b2ac345`,
`f4f0e0292776888b01182c57739f15e99661fd3ed918870e9023c10e59648627`,
`9c0f399a7700d6563556e73649294b6886e7fe3702976114ab9330ba59a5ec47`,
`f290288738deda115c28e52b20a1aaad6a2899d090f467ee59bbf3eb1e7838e8`,
`47a487e6b38fa49c17c26740f4c18a436192bf094cfe1afb5e8c2b272728173d`,
`a4931b5be2eb29bbcd1e053bec896b8e412f18ca4096876c698e718e8ecb1db5`,
`b8efcd79b6c1f1449459ea801d47a8ff0ea0a346ecc5e0cfa5d268f429da5bc1` and
`d2274229b0440eb2288bac8c739e774b6f6b524fcbaa343451b6adbb11776051`.
At that revision the directory helper still relied on its caller to use the
volume checked by the operation boundary. No public lifecycle, worker
settlement, physical mount-alias proof, real Pod mount or Phase 1 acceptance
was established.

The directory writer is now a hidden package module. Its exposed new and
recovered preparation operations check and record the volume and pass that
same value directly to the writer while holding the operation lease. Three
focused intent and volume cases passed in `.build/phase1-volume-action-unit.log`,
covering foreign scope, changed volume/capacity, existing data and a symlink.
The controlled fixture in `.build/phase1-volume-action-recovery.log` staged a
partial parent and record, then resumed through the combined boundary. The
package consumer check in `.build/phase1-volume-hidden-check.log` confirmed
that the raw writer module is hidden. The executable and unit targets built;
Fourmolu and HLint passed. Volume model, internal writer, lease, unit test,
package definition, recovery fixture source, binary and log SHA-256s were
respectively
`64206fecdc7e95a71650a3dac597f1c5d49829ed0e3c4d3ad1f4dca0f9dc63ac`,
`adac64be33b32dc65080a22e95495ca0e753d29472f0137269073b7c877f075d`,
`928af2330c69c21a5afe5aa1228ea8aa1e95ef79acb99d32f98b40c63c2a0a0e`,
`5f842b278bf89173c8000fa36adf426110ab150e071c8f8ea1d42b463c51317e`,
`5951b88ff29b997e112ac3f628045f57ee2262c81856f908dad8be24e52e685a`,
`a12d4f4feb6ef66538e85043575b387c4cdaefbf48944acd776586ae3e2c96e0`,
`6641ba14c55d5c586fca26f3c7c5297d8569492fc81789180e1f098e2c4c75c5` and
`e8a8ffe964335fde8dd42675852bc7b7ca73036477b1eb201d9c9be58d95265e`.
This boundary is not lifecycle admission or worker settlement. Real cluster
effects, public recovery, physical mount-alias proof and Phase 1 acceptance
remain open.

Public `control status` now reconstructs the volume coordinates from a
matching volume-specific intent, compares the full record with the selected
scope and canonical projection, observes that host directory, and rechecks the
record. Altered coordinates conflict instead of selecting another path. The
public binary probe in `.build/phase1-volume-public-status-probe.log` observed
a disposable recorded directory present and then missing; both messages retain
the limits on node/Pod and resource-absence claims. Three focused intent and
volume cases passed in `.build/phase1-volume-public-status-unit.log`, including
altered-record refusal. The executable and unit targets built; Fourmolu and
HLint passed. Intent, status, test, public probe source, probe binary and log
SHA-256s respectively were
`9ec3d9c75c790d53c863f551006f588b47f2ed78ccd84f86565c0c8f7c5e1ed4`,
`d6b709e5c216d1a8efb4a93fc79188e607b113296f069f82a6194063de43bbd7`,
`d8b5ce01182ec41bc12a189bbe37091311be18341ff7ac88536d2a83bc3dc799`,
`8b7b1087fa8ab0cb742ae898b373c5e7a531ed6768a5337f7decfbd9b304545c`,
`da862be1f5a4478467bf9a413fad5c8224d92743d83d627dfe3488e06aacb740` and
`bffc2cdb0e32ceb0c9e62ff5d3438085c84b07ca96bea9b66000571bbf0e259e`.
This is a local read-only diagnostic, not a public creation or recovery path,
real mount proof, lifecycle admission or Phase 1 acceptance.

The previous intent reader accepted a duplicate JSON namespace key when the
last value matched. The controlled old-build probe recorded that result in
`.build/phase1-volume-duplicate-baseline.log`. Intent observation now requires
bounded duplicate-free decoding to agree with the JSON decoder before it can
match a record. The same probe against the corrected build returned invalid in
`.build/phase1-volume-duplicate-fixed.log`; the public status fixture in
`.build/phase1-volume-duplicate-public.log` also observed no directory from an
ambiguous record. Three focused unit cases passed in
`.build/phase1-intent-duplicate-unit.log`, covering duplicate keys in both
cluster and volume records and refusal by volume recovery. The first unit
build found a missing test import in `.build/phase1-intent-duplicate-build.log`;
the corrected executable and unit build, Fourmolu and HLint passed. Intent
source, unit source, shared before/after probe source, old probe binary, fixed
probe binary, public probe source, binary and log SHA-256s respectively were
`8ca61b8611bcf1128180284b4d79bd5b0f77a71db550639ddd3b2aa213e0a7a9`,
`d59ab21beec310382592e58e3a21e3306ef68a98ce2197fd232c177131fbe949`,
`321e4568bd947409876695cf7ec5838dc035c904f1f6718603a8f6636d2c80df`,
`336cc269f120b77e0e7da52b3e1e93eb784f8cd42f38e1c5c603c19d13e17215`,
`48dcba2a62e7c846a85f9b587cd6277edf88c98591386999f36537632d4d02b6`,
`a8c47d7f5a4464fe799d4193a53e4aa9d033dde408ef02501961156ebf0216aa`,
`f1029ada6cc2e998d9782c53a5f65d7b3ffd172ec8af74dbf801cae5361f8728` and
`94ea18180c79da8aa92295e5c48e2f7b15f66391898372ced554a4b9a2cb7747`.
This local parser regression is not a real cluster lifecycle or phase acceptance.

For a matching volume intent and readable selected kubeconfig, `control status`
now reads the exact PV/PVC pair through the configured loopback endpoint. It
rechecks the intent and compares kubeconfig material in memory after the read;
changed inputs are reported without a binding claim. The configured CA is not
independently tied to an owned cluster, and node/Pod mounts remain unverified.
The controlled mTLS public-binary fixture in
`.build/phase1-kube-volume-public-probe-final.log` covered stable and changing
bindings, denied access, wrong CA, and record or kubeconfig changes during
the request. It checked request counts and paths, poisoned ambient proxy and
kubeconfig selectors, checked that no TLS key log or synthetic key appeared in
output, and removed its temporary test root and certificates. All 41 scope
unit cases passed in `.build/phase1-kube-volume-status-unit.log`; three
kubeconfig/PV regression cases passed in
`.build/phase1-kube-volume-status-daemon.log`. The executable and unit targets
built; Fourmolu and HLint passed. Status source, public executable, fixture
setup source and binary, outer fixture source and result SHA-256s respectively
were
`bfca93a7257fba1db5d147dc1406b3adbe996b508ddfe7e613c87edfa06b428c`,
`5d47ba366fd47abdbdba8f8e4d792ab97e9f5019a9c78f784faba05974ec2fcf`,
`0c5de64cfa521d706bc8a109c294a24ce4e88d12a96cdb17daa9f7ceceebc630`,
`cd934363663f521b771c72b10624a35840c6759c87fb4064977e7e31a8b6cf87`,
`26c45cbed10440d50e2b2be7cb761c82b306e7959f95714f901783c87cbbc064` and
`926891a7dd75c298ca920f88e5e9e5bafd65c9f82b39caea39c2fe573a368551`.
This is a controlled loopback protocol fixture, not a real cluster, independent
CA ownership proof, lifecycle admission, Pod mount or Phase 1 acceptance. The
two input observations do not prove that no intervening replacement occurred.

The public `control import-artifact` path now ingresses the declared kind tool
or node archive into the selected root. It verifies the bounded source before
creating staging, resumes only an exact staged prefix, publishes without
replacing an existing destination, and independently rereads the declared
digest. A matching kind tool must also have its owner-executable bit. The
public fixture in `.build/phase1-artifact-public-probe-final.log` imported the
local kind executable into a disposable test root, resumed a synthetic archive
prefix, refused a wrong digest and symlink, and preserved a conflicting
destination and unrelated marker. The repository integration case passed in
`.build/phase1-artifact-import-integration.log`; 391 parser-related cases and
four regenerated CLI golden cases passed in
`.build/phase1-artifact-import-parser.log` and
`.build/phase1-artifact-golden-check.log`. The initial executable build found
a dispatch type error; the corrected executable, unit and integration targets
built, and Fourmolu, HLint and documentation checks passed. Import source,
dispatch, registry, integration test, executable, public fixture and fixture
log SHA-256s respectively were
`ac7351d56a67cc5c7f7568eb202601223df621b717a8f1cc73db5d34ac6aeae0`,
`376e7ce4c4f0e0a2b0c2e0bf0c6f5db41c45bd66c7a61914d6750f877884e606`,
`2089cd32c533212ad77c623b7d6fbe1519f4e213dbe139aa5f3e7c2ebb62bd14`,
`8f28ea2a11610408a1cc98c19b58e07253877a9bf70390d2089f444ba3a94983`,
`fc5450a9614d286d9bcffa9dad448b8b85b34fbd6f25e0953924225e7be95cb4`,
`2fb72e19285cd6842e71e447b9ac582403746a7cca1e0e62e12415c5ef222b8b` and
`81433353b35a7f8bfd9a09a1dbc35c25843807b2e78a7819ce746672293903cf`.
At that revision conflicting staging remained retained without a supported
discard operation. Archive content/image identity, provenance, actual kind
creation, physical mount aliases and Phase 1 acceptance remained unproven.

`control discard-artifact-staging ROLE` now explicitly removes only the
selected declaration's staged file while holding the selected root lease. It
quarantines the file before deletion and can resume an interrupted quarantine;
unsafe files and symlinks refuse. The public fixture in
`.build/phase1-artifact-discard-public-probe-final.log` imported the local kind
executable, preserved a conflicting prefix until explicit discard, resumed a
staged quarantine and a matching archive prefix, and retained the already
published executable and unrelated marker. The repository integration case in
`.build/phase1-artifact-discard-integration.log` also checked symlink refusal.
The executable, unit and integration targets built; 393 parser-related cases,
four regenerated CLI golden cases, Fourmolu and HLint passed. The first
discard build found a Haskell layout error; the reviewed build passed in
`.build/phase1-artifact-discard-build-reviewed.log`. Import/recovery source,
dispatch, registry, integration test, executable, public fixture and fixture
log SHA-256s respectively were
`54c4939e12dc4f1d36358deb5055e682532c6680b3839262d0148f722ecc0090`,
`00686549604f4c1d577005f3ed7bedf574e89207a244632956ad93f514ede9ba`,
`442b173ff758d4a72eaf7e051b80ad1e51d6a27af28dcf5c5e0e6d2cd617e267`,
`89e36c97657316abf0d8c35314a6c8efbc89729c15ee6ef776fb0a508526947a`,
`a64311069863b1d1117f2cd905fa58e8dc15f6364555cc47085a77ff98965520`,
`da48403ebf64029f867282d2466ddf3234fa9ba4426f1447ab51eac6d8bd3f84` and
`ace507e7c290a0f02f8d865af4b9a560763ca7b658f4b5b52980747df6c72821`.
The cleanup proof covers disposable local files, not uncooperative same-user
races or mount aliases. Archive content/image identity, provenance, actual
kind creation and Phase 1 acceptance remain unproven.

A later review found that an interrupted discard could leave a quarantine file
while import published a new artifact. Import now refuses while that quarantine
exists. If both pending and quarantine files exist, explicit discard removes the
quarantine but reports incomplete; a second invocation removes the pending
file. The public fixture in `.build/phase1-artifact-quarantine-public-probe.log`
and the repository integration case in
`.build/phase1-artifact-quarantine-integration.log` passed these cases alongside
the original import, prefix, conflict and cleanup assertions. The executable
and integration target built; the pinned formatter and targeted pinned HLint
passed. Import/recovery source, integration test, executable, public fixture
and log SHA-256s respectively were
`bbd4ec48bd2b1bca6a6553af76b79d44eb94183b2e23799e3f046a409424b967`,
`dd01752b94fa437210574b3ee92cdeeb049466b67223e99602053c58b2c387cf`,
`8446d44461935a668abab0b959965fe240e68145f6a18aee46b84250babcd0ec`,
`21e248b31d0693a9c3c1f73bb6997c480c91e29b2eba7464c35e0aeec79bf89d` and
`fc24bbdaad2002d6f5e243d4350beeef54dae721ab1294962ae002d70e8adf01`.
The canonical gate first stopped at two style findings, then at formatter
drift, then at one pinned HLint hint; those findings were corrected. The next
run was deliberately stopped when the quarantine edge case was identified,
so none of those runs is a full passing gate. Uncooperative same-user races,
mount aliases, archive/image identity and real kind lifecycle remain open.

After the quarantine correction, the canonical `dev check` passed in
`.build/phase1-artifact-quarantine-dev-check.log`: policy, documentation,
pinned formatting and HLint, and the warning-clean build passed, followed by
gated suites of 10038, 27, 35 and 935 tests. The run used empty AWS credential
files with ambient AWS credentials, kubeconfig and Docker target removed.
Import/recovery source, volume model, dispatch, registry, integration test,
scope test, daemon test, synchronized executable and gate log SHA-256s were
respectively
`bbd4ec48bd2b1bca6a6553af76b79d44eb94183b2e23799e3f046a409424b967`,
`c65556f1e3cf464e20df223d86f947ecdf1290e519af43af60829b58ccdc20be`,
`31200ae459cb43ab9a09e078b2d6bb5f937fd5bd69acaeee7cec8a4b45346f15`,
`8c6499cf5202d2cee3cdcdd7d52e12a42c839cbd336f1de88fb4ea7877779637`,
`dd01752b94fa437210574b3ee92cdeeb049466b67223e99602053c58b2c387cf`,
`a57db5778d2b2c93c7d35b7caa1d47f920dfbd2555cfa9c473e0a9ca5293f195`,
`3a650065b955e5ff31e54546be0e20813beaa9db34dab3526629bea6198f44b7`,
`8446d44461935a668abab0b959965fe240e68145f6a18aee46b84250babcd0ec` and
`877ca80e7d005725df57d05fcd9252eb9433e31c10e7fca0e997b13fa65c4211`.
This gate ran before this evidence paragraph and is regression evidence, not
the real kind, network, capacity or mutation acceptance required to close
Phase 1.

Artifact ingress now refuses a source named `test-secrets.dhall` before opening
it and refuses hard-linked sources after descriptor metadata inspection, before
hashing or staging. The public integration case in
`.build/phase1-artifact-source-isolation-integration.log` passed those controls
alongside the import, discard and recovery checks. A separate public fixture in
`.build/phase1-artifact-source-isolation-public.log` used an open-call trace
with an independent positive control and observed no open of a synthetic
protected-name fixture. No protected fixture contents appeared in the result
log, and no secret-file hash was recorded.
The executable and integration target built; pinned formatting, targeted pinned
HLint and documentation checks passed. Import source, integration test,
executable, public fixture source and log SHA-256s respectively were
`b6dd862c722eb89e94218ae6010507c0d2c6be5886f0b9c6f4ae62c9d584bc23`,
`c35434e2a6e2ee14f7d9684a47af539ed155a6d37e6a6d533e645ec38c9324d5`,
`68ebaee9e53c6fde35b5a7e536df6b942834d2ef41bacf36bca9b541edf191c7`,
`52b7f08ea0b3075a9d64797d58ba2a486b9574383e3ca6eb3b8b2b004ffbb59b` and
`50dc97f03e490929b7dc27607e892ea61419a42c913f30242ec096e932749c57`.
This safeguard cannot identify arbitrary secret content renamed to an unrelated
single-link file. The previously passing full gate predates this change; node
archive/image identity and Phase 1 acceptance remain open.

A further disposable public-command trace checked the hard-link guard before
content reads. A separate `cat` positive control demonstrated that the trace
observed reads from the same synthetic linked source. The guarded import
refused it without a traced read, and the unrelated marker survived. Fixture
source and result are `.build/phase1-artifact-hardlink-trace.py` and
`.build/phase1-artifact-hardlink-trace.log`, with SHA-256s respectively
`04da4c0cea92b7432999fd86dc673c816d807974a291fb0da9bf92f37c07ca9f` and
`8c53cb2cd2ed213d3c2a4d793d19d3a68a250067563ff927357cad95e4e5e6e3`.
This observes the synthetic fixture only; it does not qualify the kind
lifecycle or close a Phase 1 acceptance case.

The subsequent `dev check` process ended after its log reported 10,038, 27,
35 and 935 passing gated unit tests in
`.build/phase1-ingress-isolation-dev-check.log`. The executable and import
source matched the identities recorded above; the log SHA-256 was
`d67c08f298b52d2b06e46208edc109a00637ab38aa94b16fd2ac6d0b2ef9d860`.
The invoking tool's exit status was not retained, so this record does not
certify a successful overall gate. The documentation evidence paragraph was
added after that run's documentation stage and separately passed
`.build/phase1-hardlink-trace-docs.log`. Neither result closes Phase 1.

`control inspect-node-archive` now checks a retained uncompressed OCI layout
against the configured image digest, current Linux architecture and the
referenced config and layer blob digests and sizes. It brackets inspection
with the retained root generation and artifact stability checks. Unsupported
layouts and malformed or missing content remain explicit refusals. The public
integration case passed in `.build/phase1-node-archive-generation-integration.log`;
separate synthetic public fixtures in `.build/phase1-node-archive-public-final.log`
also refused wrong architecture, damaged blobs and links. Additional duplicate
JSON, traversal and trailing-data controls passed in
`.build/phase1-node-archive-public-adverse.log`. A 128 MiB synthetic
blob matched with a measured 53,384 KiB peak RSS in
`.build/phase1-node-archive-large-final.log`; that one measurement does not
establish a general memory bound. The inspector source, integration source and
operator SHA-256s were respectively
`a70ba8e6353cf447c9dcaccb36a5b4e14d4b552391d75ef872b40a4b35d4eeb6`,
`66768406abc9871f40b23984588684ff35649dbc73f12075d5d2c3bf908fff63` and
`4225e02642f95d7e59437509ed7768411c409529b77072926003dd2a8bc0fed5`.
The persistent public integration case was then extended for a selected OCI
index and a foreign platform and passed in
`.build/phase1-node-archive-index-integration.log`; its final test source
SHA-256 was `675ee1bd3ec67f2b77837f25f8f9c1017d11ba4b2b9bca331f94563049e9bff9`.
This is not publisher authentication, daemon loadability or real kind
acceptance. It does not yet implement image loading, reconciliation, recovery,
removal or the Phase 1 scenario runner; those obligations remain open.

The archive command now also compares its verified config digest and platform
with separately observed metadata from the selected Docker socket. A missing,
non-socket or symlinked socket is unobservable. The comparison is not atomic
and is not lifecycle admission. Forty-two scope unit cases passed in
`.build/phase1-image-comparison-unit.log` using the build before the socket
guard; the comparison logic was unchanged by that guard. The archive integration case
passed with a scoped unavailable socket in
`.build/phase1-image-comparison-integration.log`. The public protocol probe in
`.build/phase1-image-comparison-probe-reviewed.log` used a disposable fake
daemon socket: matching and different config IDs were distinguished, and a
symlinked socket caused no request even though a direct Docker positive
control could reach it. Only ping and image-inspect requests were observed.
The probe source and log SHA-256s were respectively
`83941b9d06bb57c706b1a93e76f6112a39e34494ece2a6043857762c4de4dab2` and
`8e322a3d77bbc3b19a5e207071167088c533692477795e72eb713c9f2a73349b`.
The inspector, status, app and operator SHA-256s were respectively
`4a04d3b1605fab2623169223459ced1cc82f56994f85b005e4e8d26f84d9e4ba`,
`64fa519dbc587cc805ec7ac285eb4ed0480d1837d8c182c51a502e970d4f4db5`,
`f291f999c451617655e4f36d8e27d54aeea836f796ea7bc9ef6c7f70aa270154` and
`e1002ab299d6d2e9980ea6b117e94add5af93d0d010e65df9abe6edd12941b44`.
The first binary copy failed while a documentation check held the executable;
the subsequent copy and tests completed. These controlled observations do not
prove a real daemon image load or kind lifecycle.
[Docker image loading](https://docs.docker.com/reference/cli/docker/image/load/)
can restore archive tags, so the load adapter still needs
to bind or refuse every affected reference, retain interrupted-operation
identity, and independently observe the exact result before any kind effect.
The current archive inspection is not authority to load an archive.

The earlier metadata comparison treated every Docker image ID as a config
digest. That was too restrictive for the containerd image store, whose
[inspect implementation](https://github.com/moby/moby/blob/master/daemon/containerd/image_inspect.go)
can report the target descriptor digest instead. The diagnostic now separates
a config-ID match from an index or manifest descriptor match, and explicitly
states that the latter does not independently observe the daemon config.
The updated 42 scope cases and public archive integration case passed in
`.build/phase1-image-stores-unit.log` and
`.build/phase1-image-stores-integration.log`. A controlled multi-platform
protocol fixture in `.build/phase1-image-comparison-stores-index.log` checked
config, index, manifest and foreign IDs and the static symlink refusal; it is
not a real daemon or lifecycle qualification. The status, app, unit source
and binary SHA-256s were respectively
`ef26187b69e750d83cca64bd8429779a0b0971b03dce2c71ef18adf5ef4a8cdf`,
`74357a622e5c685b828f59920372e890d32854c7d361e9223b76abfbf0fb73c9`,
`b2a4fbe884cdc37188355e26779c5f0f4fcadf1ada4a4c01b2141fc8ab6b125b` and
`eb66bb41676f55f1ed490ff92becc58264bf3ec9e2700462f3ef75d30e6b5bf5`.

A read-only registry metadata check of the node digest published for the
installed kind v0.32.0 found a Docker schema-2 manifest list and manifest,
with Docker config and gzip layer media types. The reader's earlier OCI-only
media restriction therefore excluded that real published node image. The
bounded metadata probe and result are `.build/phase1-kind-manifest-metadata.py`
and `.build/phase1-kind-manifest-metadata.log`, with SHA-256s respectively
`5aa2042de516db55c20f6eb15894fd5ba8fb8bf70034e77ee375d6e932b356c3` and
`2c20f935da02331dfee7827459a3e3baf7cac5bf377b5450085b4bad043d731c`.
Only public manifest metadata was read; no image layers were downloaded and
no daemon or cluster operation was performed.

The retained-layout inspector now accepts Docker schema-2 manifest lists,
manifests, config and layer descriptors as well as OCI equivalents, while
requiring the referenced content locally. The public integration case in
`.build/phase1-docker-manifest-integration.log` passed direct and indexed
Docker-shaped fixtures and rejected a mixed-media manifest. A separate
diagnostic assembled an OCI layout from both architectures of the published
node image, independently checked each downloaded blob digest, and then used
the public setup, import and inspection commands. The reviewed run matched
the selected published manifest, recorded archive, config and binary
identities, and removed its disposable file fixture in 32.76 seconds. Its
source and result are `.build/phase1-real-kind-archive-reviewed.py` and
`.build/phase1-real-kind-archive-reviewed.log`, with SHA-256s respectively
`e1014a60570abe434570386c2f77412cecb12db258b3b6fd0c31ae0f11541c54` and
`44e0c3b093d9ea288f41099f08aa1a95264c5e024f3f2a157b1ae52c2e35803a`.
The inspector, integration test and operator SHA-256s were respectively
`374c43d97d2e3b35358e994375ee589a708e88c249dcfba384d5399f2bdb7286`,
`1a940978913ed9ef1ad73b6c1b9016246cc5e71842a4dc1153c88e8b69fc03ac` and
`174196e1f2ae1ff88221e3fbc22a7b19a5d5d84b4f323ef3b78573e56570e24c`.
This file-only diagnostic did not load an image, create a cluster or qualify
any Phase 1 acceptance case.

The pinned kind v0.32.0 Docker provider has effect paths that cannot be
admitted merely by checking the selected root. Its
[network preparation](https://github.com/kubernetes-sigs/kind/blob/v0.32.0/pkg/cluster/internal/providers/docker/network.go)
can delete duplicate networks by name, and its
[image preparation](https://github.com/kubernetes-sigs/kind/blob/v0.32.0/pkg/cluster/internal/providers/docker/images.go)
can pull after an image-inspect failure. The Phase 1 adapter must prevent
foreign network deletion and unowned pulls at the actual effect boundary,
including races and interruption; preflight alone does not establish that
property. A01-03 now explicitly exercises both cases. No kind effect was run
for this source review, and it is not acceptance evidence. The reviewed
v0.32.0 provider, network and image source copies are under
`.build/kind-v032-source/`, with SHA-256s respectively
`41e8e28780fecd901eb2e55e6f607a67c3cbf0b85dd0cf051a3d2f5ab7de21b0`,
`e6b3edc4d00e10a284e2b21ba29ea4fbebcb71ea72c78a07a97f49b8249358f4` and
`4a79ffdac0c6a7ddf9e8ba96e42ae8a38c0e15f14ed360b6bfd954312ba25fb2`.

Archive inspection now also reports the count of top-level descriptors and
how many carry either recognized image-name annotation, without emitting the
annotation values. The count is explicitly not a complete load-effect
inventory and does not authorize a load. The public integration case in
`.build/phase1-archive-footprint-integration.log` passed named, extra-entry
and malformed-annotation cases and checked that synthetic annotation values
were not printed. The controlled daemon comparison also passed in
`.build/phase1-archive-footprint-comparison.log`. The inspector, app,
integration source and operator SHA-256s were respectively
`18a3231a7cbcf095c27397118a71e9a2ea68549c60e6ade98029ba9dc53fb66e`,
`90bc5bcae0c0455cc3ca083e6c267a6f9b7d7cd2abe80a6a1d8f3295d7cae1b7`,
`cfd60a95c8f4f8546698ea677f26143b3d453f4fbd17937d1f59253f6ac73027` and
`57ec2e4bbbfbaa3b5837564cd4dd589380ddda3d044831b666584ebc7ede7c8e`.
This does not implement image loading, kind effect admission or cleanup.

The archive descriptor is now held and the selected generation is rechecked
while the public command obtains daemon metadata. A completed callback's
result is retained if the archive subsequently changes; a timeout remains
unconfirmed and is not admission. The integration case in
`.build/phase1-held-archive-outcome-integration.log` checked the descriptor
position, detected a changed archive and retained the callback result. A
controlled socket probe in `.build/phase1-held-archive-outcome-probe.log`
changed the archive during the daemon read and observed refusal instead of a
combined success. The inspector, app, integration source and operator
SHA-256s were respectively
`befea05922508936ed5bffd8ed465871f76f3b8bb298308d2817b4e0184e0e4e`,
`e6d947cf26b65b03b9077fadfe0cae14baf13f13261a9b460fc4cf87ba9c25f5`,
`f4aef1531abf5a3b5756f33e8566953f4a05454b5bbdc43f965e6bd21b7de1c6` and
`4bca5d6cff0f31fec37c0a2e1b80b00c2028160d1a63c365252a3d7c43d855a7`.
The initial warning-clean test build in
`.build/phase1-held-archive-offset-build.log` failed on a shadowed test name;
the corrected build and tests passed. These fixtures do not establish an
image load, kind effect boundary or Phase 1 acceptance.

The held-archive callback now distinguishes refusal before invocation from an
unconfirmed interruption after invocation, and retains a returned callback
value if a later check is interrupted. The public integration case in
`.build/phase1-held-archive-progress-integration.log` exercised a callback
exception, archive and generation changes, pre-invocation refusal, descriptor
position and retained callback values. It also checked interruption
classification with synthetic states; it did not prove a real timed-out
effect or its settlement. The controlled daemon probe in
`.build/phase1-held-archive-progress-probe.log` again refused combined success
when the archive changed during observation. The warning-clean build passed;
inspector, app, integration source and operator SHA-256s were respectively
`c2ca36f6fa7a0ef8957f24b4d4afbe53d7724679377298c64f4bf044c8cd3515`,
`ba6b1ca3131defcd418372f86dfd3d7f23d7ac259748a4bad749bc1535a1d0a8`,
`0932f2ad2408b7dd2fcd89626294d2a2afce4b8d820718d02035fd8dde393c82` and
`f3a7c87d67798685f71ea549b322c4d0525a7d395f1d099dfa277b038fd0f0f3`.
Image loading, durable effect intent and settlement remain unimplemented.
The first final formatting check, `.build/phase1-docker-manifest-format.log`,
failed because a second Fourmolu pass was needed for the expanded fixture.
After that pass, the formatting and HLint checks passed and the public
integration case passed again in
`.build/phase1-docker-manifest-integration-reviewed.log`. The final test
source SHA-256 was
`12a89d599e4da1549a341e0826085932bb191739da0271bc0c4bf718dec27e1f`.

An internal streaming converter can now project the held, inspected archive's
selected config and layers into a Docker archive with an empty `RepoTags` list.
It verifies blob sizes and digests while copying, rejects inconsistent plans,
and distinguishes a refusal before output from incomplete output after a
stability failure. It does not authorize or perform a daemon load, verify
decompressed layer identities, or provide effect admission or settlement.
The synthetic integration fixture checks selected contents, output identity,
omission of foreign reference metadata, unsupported-config refusal and an
interrupted stability check. The warning-clean build and focused fixture passed
in `.build/phase1-docker-export-fault-reviewed-build.log` and
`.build/phase1-docker-export-fault-reviewed-integration.log`; formatting and
HLint passed in the corresponding `-format.log` and `-hlint.log` files. Earlier
build attempts in `.build/phase1-docker-export-integration-build.log` and
`.build/phase1-docker-export-fault-build.log` failed on shadowed fixture names,
which were corrected. Inspector, converter, fixture and operator SHA-256s for
the reviewed run were respectively
`031d2405114788da784f960f67e8b488c5809055a4f5647d7012a461e123619b`,
`43572c42fe43d8fc9d48aa1ccfefa2bdfb8dcb81e736dedcd4e38c441d3398ac`,
`0bd6c4874879cf6471ecd0e601c389054999400b13a4aec75686d684370364ae` and
`ab158240ea101ce71518c3d17436d87c12b967a227599ab73d9ec3e82bc047ad`.
This is protocol fixture evidence only; no real image load, phase acceptance,
mutation kill or current full quality gate is claimed.

The converter was also exercised against the published pinned kind node
manifest `sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5`.
After public setup, artifact import and inspection, an internal diagnostic
converted the held archive. An independent Python tar reader checked the
selected config and layer entries, the empty tag list, the output digest and
the two decompressed layer diff IDs. The selected output was 383,242,240 bytes;
the disposable file fixture was removed. Probe, helper source, helper binary
and result are `.build/phase1-real-kind-export-reviewed.py`,
`.build/phase1-real-kind-export.hs`, `.build/phase1-real-kind-export` and
`.build/phase1-real-kind-export-reviewed.log`, with SHA-256s respectively
`80d4400187d2d5cc101abc41ef31871ff333f67e67481f41686637e5c92db7e0`,
`696273b9dd379edd8faf01bd874cdce6a4ded4048576c5493f253e6ae9cfb8cd`,
`6ab482e3bf2d2979166769f29aba89e08009c6eb80ba46ce1fc8bb782c45f350` and
`071d87e1c20bc88e795b4c730e17b5deff17aba822fca668da517431f642a667`.
The operator identity is the one recorded above. This read-only diagnostic did
not submit the archive to Docker, exercise interruption recovery, or qualify
any Phase 1 acceptance case.

The focused fixture now also forges an invalid config media type, malformed
diff ID and conflicting config digest, checking each is refused before output.
The warning-clean build, fixture, formatting and HLint passed in the
`.build/phase1-export-invalid-plan-*` logs; fixture source SHA-256 was
`0c4b38fbb90fda5bc5e6c0949f6a8ed32a1cd6e9e36eb45a1bc60124b8ca5053`
and the operator identity remains the one recorded above. At that point the
owned subprocess input interfaces accepted strict in-memory bytes, so the
383 MB real archive needed a bounded held-file or streaming input path before
it could be fed to an owned loader. That path must retain input identity and
settlement; this fixture does not exercise either or authorize a daemon effect.

The owned subprocess boundary now has a held regular-file input path. It reads
at most a caller-declared size in bounded chunks into the existing owned pipe,
and separately reports the child result and the file's post-run metadata
observation. The real kernel-owned child fixture streamed 200,000 bytes,
refused an over-limit file before child start, preserved a nonzero exit when
the file changed, and observed a non-consuming child gone after its deadline.
Existing bounded-input and cancellation cases also passed. The warning-clean
build and tests are in `.build/phase1-owned-file-input-final-build.log`,
`.build/phase1-owned-file-input-stream.log`,
`.build/phase1-owned-file-input-lifecycle.log` and
`.build/phase1-owned-file-input-regression.log`. Two earlier builds were
deliberately stopped while the result model was corrected. Formatting and
HLint passed in the `-reviewed-format.log` and `-reviewed-hlint.log` files.
Subprocess source, fixture and operator SHA-256s were respectively
`b2b51f0ed0215aa1a44a435e888586c7912d1d637a49ca1dcd3fa0a6930754b1`,
`279c8ceab1375c5acbfeebbebb5aa8cb87fcb53d8744cc6d39462a97c3b746b9` and
`61b320d02fd627579ffa757ba9acd46b4f71835b7db4e2da21e37b3b12cba411`.
This path does not bind file content cryptographically, admit a daemon effect,
or establish recovery of daemon-side work. The host-placement variant has
not yet been exercised with the archive, and no Phase 1 acceptance is claimed.
The first canonical check in `.build/phase1-owned-file-input-dev-check.log`
failed on two repository-specific style findings in the earlier node archive
code. Those were corrected; the warning-clean rebuild and selected archive
regression passed in `.build/phase1-owned-file-input-style-fix-build.log` and
`.build/phase1-owned-file-input-style-fix-integration.log`. The updated archive
source and operator SHA-256s were
`a6793c67c135012f13e4e4257d2775c162beef69b1956ba817a80cdef895bb3a` and
`784cc29288fa8deb9aff3f201d7682448c6954d68a2ab2cc7a6807706d0670cd`.
The canonical retry completed successfully in
`.build/phase1-owned-file-input-dev-check-retry.log` (SHA-256
`4af687400e24798ac7285d2c71edb8a9158ebe3e126ad39dccb562d5553f9f28`).
Its gated unit suites passed 10,041, 27, 35 and 935 tests respectively.
This gate does not close the real kind acceptance or mutation obligations.

After that gate, the native kind-host placement fixture was extended to stream
200,000 bytes through the new file-input variant and compare the child digest.
The corrected threaded fixture passed in
`.build/phase1-owned-file-host-placement-ready.log`; the fixture source,
binary and log SHA-256s were respectively
`20759d1b02bb7fd6f4409f61e0677b7f86b108aeb591334ed381126d78f390b5`,
`6e57113068159e50541e15535e608d149adf85b6e21f7206df2470c881eb5053` and
`e4f0b1dfdfbc928a2f2c6ca64951fc602c0e46fe45210c2537527ef0ff82ade8`.
Formatting and HLint passed for the changed fixture. Earlier fixture build
attempts failed while arranging a disposable package view of hidden modules;
the three managed attempts in the `-native.log`, `-diagnostic.log` and
`-threaded.log` files failed before the controller published a result. The
threaded attempt's missing `-rtsopts` was reproduced offline, and the final
build used both `-threaded` and `-rtsopts`. The failed fixture roots remain at
`/tmp/prodbox-kind-host-placement--11597e6f483a9faa`,
`/tmp/prodbox-kind-host-placement--c9b1d0f4387fc29a` and
`/tmp/prodbox-kind-host-placement--7528c78d80b25143`; each launcher observed its
exact managed units and runtime paths absent before reporting the missing
result. The successful fixture removed its own scratch root after its cleanup
observations. The full gate above predates this fixture-source change; this is
not a daemon load, archive-sized resource measurement or phase acceptance.

The selected archive can now be converted into an anonymous file held beneath
the selected root for a callback. The staging path independently hashes the
completed file, checks its size and unlinked identity, rechecks the selected
root and original archive, and preserves a returned callback value if the
staged file changes. The focused fixture checks those observations and that
the file descriptor closes. The first fixture failed because the POSIX reader
reports EOF as an exception; `.build/phase1-anonymous-node-stage-read.trace`
captured the successful last read followed by EOF. The corrected warning-clean
build and fixture passed in `.build/phase1-anonymous-node-stage-reviewed-build.log`
and `.build/phase1-anonymous-node-stage-reviewed-integration.log`; formatting
and HLint passed in the corresponding reviewed logs. Stage source, fixture,
package definition and operator SHA-256s were respectively
`dd77dd4e4a752252b765224f3db0b9584907ba062c024f594416de43a38f5416`,
`2b9a095e2fc4fb43703bd866291fe841199e70d8f7893e971d362d6c77500a4a`,
`a6a75468ebf6aa5120b559f738fe7d28ace241fead0ad4d98cfec8858f95f12a` and
`784cc29288fa8deb9aff3f201d7682448c6954d68a2ab2cc7a6807706d0670cd`.

A read-only diagnostic then staged the published pinned kind node archive and
independently verified the selected 383,242,240-byte Docker archive and both
uncompressed layer diff IDs. The helper source, helper binary, fixture and log
are `.build/phase1-real-kind-stage.hs`, `.build/phase1-real-kind-stage`,
`.build/phase1-real-kind-stage-reviewed.py` and
`.build/phase1-real-kind-stage-reviewed.log`, with SHA-256s respectively
`2164e45fe804686c7b94b4816c8750cdf302afeaf22dc87e1ad849e122d25fb7`,
`6a924166fc8948cc03b8620e0d203daaf79cc543f88007dca0f06ded3a9a9089`,
`2f2386b1054bf65c78b60b66f1d0dfecd973f16c6264a50e295de20801f4782e` and
`d2e5be91c652db066d095ce50862410e38dc1e63a32c2ed21ff6487c6b992827`.
The disposable fixture removed its own file root. The stage is not a durable
operation record or effect permit; this diagnostic did not feed it to Docker,
measure an owned load, or establish phase acceptance. The earlier full gate
predates these source changes.

The anonymous stage and owned file-input path were composed in a further
read-only diagnostic using the same published node archive. A kernel-owned
`sha256sum` child consumed the full 383,242,240-byte stage and returned the
independently verified archive digest; both the file-input and stage checks
reported stable. During the run the child was independently observed in
`prodbox-owned-bc577a359250f7f0e239e558b32a85ae.scope`; afterward its PID
3316125 and that exact cgroup were absent, as recorded in
`.build/phase1-real-kind-owned-stage-independent.log` (SHA-256
`3d1c831a7ac7c74bc960a4583e0f78c5a36a560a6b2fa406f0e476f85510aaba`).
The helper source, binary, fixture and output are
`.build/phase1-real-kind-owned-stage.hs`, `.build/phase1-real-kind-owned-stage`,
`.build/phase1-real-kind-owned-stage-reviewed.py` and
`.build/phase1-real-kind-owned-stage-reviewed.log`, with SHA-256s respectively
`f5921d6467345c6b34d23fc5177f9c3f58bee0e08632ffbc08f118b72ccc20cf`,
`9583dc2843b757d3a3a70a78d0fc3612f0fac0c8932e452b8c770f0056b7808e`,
`0be2c241503df1b1c8d4901a73b611200587b12b31a137d73e87159db76cff28` and
`aebd1692d831dadf18b1d8d9312c86b948ccc8c7232a5bb4d5965479b141cd74`.
The complete diagnostic, including public download and verification, took
144.08 seconds; it used a 130-second owned-child limit inside the existing
180-second held-archive timeout. This is one observed run, not a justified
production deadline or resource envelope. It did not submit a Docker effect,
prove daemon settlement, or complete any Phase 1 acceptance case.

The owned input writer now waits for pipe readiness under the existing work
deadline instead of polling every millisecond. The warning-clean build and
focused stream, blocked-input, and cancellation tests passed in the
`.build/phase1-owned-input-readiness-*` logs. A separate non-threaded program,
matching the operator's runtime mode, also verified the input digest, deadline
and child absence in `.build/phase1-owned-input-nonthreaded.log`. Its source,
binary and log SHA-256s were respectively
`b28319adc2f2d108359e419e370825c702f0ccf261cb3998d6c8a9c25c247c1f`,
`eb1f632706985defb3a4770af016bc6b3ea87ac3ecdce64f6c33b2b0a808c762` and
`3ea6f194dc1088ab3120701f27cfc799f6aa0e5c2abfe805409f87da4f2c1398`.
The source, lifecycle fixture and operator SHA-256s were respectively
`78ad58f2e5f7face4fa42cc913d664d59dd9ac96bf5b63fe5ece6bcf9ae77d26`,
`d43c6a79ade266f1ee52bb42d827f757dd740e6b47f357fe5e8e98905b35cd34` and
`8fe5607ee4a262a0003f0393d465d7a0b1cf869293489c95b18c2a393429eab5`.

The non-threaded real-image diagnostic also streamed the complete staged
archive to the owned digest child successfully. Its total elapsed time,
including download and verification, was 42.41 seconds. Fixture, binary and
log are `.build/phase1-real-kind-ready-stage-reviewed.py`,
`.build/phase1-real-kind-ready-stage` and
`.build/phase1-real-kind-ready-stage-reviewed.log`, with SHA-256s respectively
`cf37de77bcf77b1c70ca63ce942adc848c6b3f74fe6e312b8907135dc2f26755`,
`663a899a1dcffdee42eb3e6c03009a857008380c5572b464ca56ed5b5233d364` and
`78d5d61bfd4766c8d7362daf17882a3c71ee5c04c8cd504b884dee8f45f451d6`.
These two single-run elapsed times include variable external work and do not
establish a controlled benchmark or production resource envelope. No Docker
load or Phase 1 acceptance is claimed, and the full gate predates this change.
The native kind-host placement fixture also passed with the updated writer;
its binary and output are `.build/phase1-owned-readiness-host` and
`.build/phase1-owned-readiness-host.log`, with SHA-256s respectively
`94675b7ddd5ae4f766e5b0c5c674957b5b7694db61313c183057feec02188cd4` and
`88e65ff4776f7770f72b9b0c97803bf92d5d1180044d5698c30777684895be87`.

The public node-archive diagnostic now separately inspects the exact config
and selected manifest image IDs. It reports platform and tag count only for
an exact returned ID, does not print tag values, and treats failed or malformed
lookups as unobservable rather than absence. This is a non-atomic daemon
observation, not proof of image ownership, provenance, or permission to load or
delete. Six unit checks and the selected archive integration case passed in
`.build/phase1-exact-image-observation-repaired-unit.log` and
`.build/phase1-exact-image-observation-repaired-integration.log`. The synthetic
socket probe `.build/phase1-exact-image-observation-probe.py` exercised both
candidate IDs, mismatches, tag redaction and symlinked-socket refusal; its log
is `.build/phase1-exact-image-observation-probe.log` (SHA-256
`e83fa8419fa531a6a2565f25eebf1d6108d841e9be6b009db83ac03a1cf1ac55`).
Status, app, unit fixture, integration fixture and operator SHA-256s were
respectively
`c5a622b06ecf8606e8136ed077487ef7dc1e2cb99bdf5447cc092be2da897fea`,
`bc716831850c996cc982f7ea021ab3104fac0a5294ed16948f03c62807dfc7f3`,
`15ab43aca4e663f7d0aec2e2d35cda19002538c66725c261e5ee0a1effb29f5f`,
`e2c44386b1a8f9a967b01a389ce786553209b7e57a3a36feff2fd5bbf12eaff5` and
`7595bead72c9a75d772d053c286a1d39441f86ac49960c9cde12b11224dafa77`.
The first build failed on an ambiguous fixture type; an intermediate build
was stopped for a second formatter pass. An early integration invocation
started a competing Cabal build and was stopped; the shared build library was
subsequently found corrupt and retained as `.build/phase1-exact-image-corrupt-library.so`.
The library was rebuilt and the sequential warning-clean build passed in
`.build/phase1-exact-image-observation-repaired-build.log`. Formatting and
HLint passed in the final targeted logs. No Docker load or phase acceptance
was exercised, and the earlier full gate predates these changes. Documentation
lint passed in `.build/phase1-exact-image-observation-docs.log`.

An image-load intent can now be durably written under an existing exact kind
operation. It binds the selected root generation and inode, runtime socket
path, selected image and source artifact, manifest and config digests, and the
staged archive digest and length. Exclusive creation, file and directory sync,
read-back, no-follow checks, operation rechecks and bounded failure reporting
distinguish a refusal from an incomplete write. The focused unit fixture checks
missing parent operation, matching read-back, conflicting identity, invalid
content and a symlinked record in
`.build/phase1-node-image-intent-reviewed-unit.log`; the warning-clean build
is `.build/phase1-node-image-intent-reviewed-build.log`. An intermediate build
was intentionally stopped while the masked write boundary was restructured.

The new preparation composition holds the parent operation and verified
anonymous stage, records the exact image intent, and rechecks both before
entering its callback. The selected archive integration fixture independently
observed the matching record from inside that callback and checked the held
file digest; it passed in `.build/phase1-node-image-preparation-integration.log`
after the warning-clean build in `.build/phase1-node-image-preparation-build.log`.
Formatting and HLint passed for the affected sources and fixtures. Intent,
composition, stage, unit fixture, integration fixture, package definition and
operator SHA-256s were respectively
`150809ce93c7a0cd13e3a5bb59b2d01b660fdd4b7f49aa3cc82cc084c8001165`,
`f721ece8bc361a3548400c6d5de87a15b8188904f633fb6f9a0ab89327557acf`,
`ee199f4210333ffd5d7b9561d8c7c281f353ae86bc332fb9212603c19ff4122a`,
`0978a5367b7b0aca374522c57cea45426676ac8e6c30c5e3d44ac8e46f9a2be5`,
`171d03ad99908b856adacde24b79397693e4a97de8a98f977ca3e4c32a6fe9af`,
`9c49e05216f159383ce63f04b9cb98bba19ec052f51f52d1c0dcb3f1a7c26cef` and
`7595bead72c9a75d772d053c286a1d39441f86ac49960c9cde12b11224dafa77`.
These internal records and composition do not identify the daemon, authorize
or settle an effect, expose supported recovery or cleanup, or complete a real
kind acceptance case. Those obligations remain open; the full gate predates
this work.

The existing operation can now be reacquired for a read-only recovery
comparison: it regenerates the held stage and compares its exact identity with
the retained image intent. The selected archive fixture checked both a match
and an incomplete record in `.build/phase1-node-image-status-integration.log`.
This comparison has no effect callback and does not establish that an earlier
daemon worker settled or authorize a retry.

`control status` now reports the local image-intent record when its parent
operation matches. It distinguishes a matching record, missing local file,
conflict, invalid content and unobservable state; none is treated as a daemon
absence or settlement proof. The focused unit case passed in
`.build/phase1-node-image-status-unit.log`. The public diagnostic in
`.build/phase1-node-image-status-public.log` used the real local Docker socket
and a synthetic retained intent, observed matching and deliberately incomplete
records, and confirmed its exact Docker inventory was unchanged before its
disposable file root was removed. The warning-clean build passed in
`.build/phase1-node-image-status-build.log`; targeted formatting and HLint also
passed. Intent, recovery composition, status, unit fixture, integration
fixture and operator SHA-256s were respectively
`e918749ba99021754033d16c4880a708ed8220afa0cec534d976021b80b58a45`,
`4e2f15ed659e5af1bd3b0dcfa0fad6d39e143fef1afa36dfc2f97962f0fa8df7`,
`41501fe2734778240d756e7708b25bc8d37e9b31434e06dd0df6f92fddff491e`,
`db5d50a45a554f904ca32d3b8f377b9e434dca708d91c1e40c5951249edad950`,
`6cb5f029ab59c284821c0b50b2249422d20af00d78bb8746015f1123795ed3d2` and
`316bca5291ecadd1cf072cfd31fbf9b43b12c203182701b784e2f88282095568`.
Public diagnostic script, fixture binary and log SHA-256s were respectively
`5f4211c115f1ae7d6e5949783659ce0f95f14ba6b0380594bd81429531b0bdb6`,
`07e9a5f7599ea9474a7b269b48309ca29e88d2283021507206c78352bc096c75` and
`bf8db29a91093417c11740344e8827ee84a19b4a64e3be30f97366d09e44d70e`.
These checks do not perform a Docker load or complete Phase 1 acceptance; the
earlier full gate predates this work.

`control status` now observes the selected Docker socket identity before,
between and after two daemon-ID reads. It reports matching IDs, a changed
observation, or an unobservable result. This is not daemon authentication:
the ID can be cloned and a replacement between samples can be missed. The
seven focused control-observer unit cases passed in
`.build/phase1-docker-daemon-identity-unit.log`; the archive integration
regression passed in `.build/phase1-docker-daemon-identity-integration.log`.
The controlled socket probe detected a changed daemon ID and refused a
symlink before contacting the server; the real-socket public diagnostic
matched an independently read daemon ID and observed its exact inventory
unchanged. Those results are in `.build/phase1-docker-daemon-socket-probe.log`
and `.build/phase1-docker-daemon-status-public.log`. The warning-clean build,
targeted formatting, HLint and documentation lint passed in the corresponding
`.build/phase1-docker-daemon-identity-*` logs. Observer source, status source,
unit fixture, package definition and operator SHA-256s were respectively
`472ac807d2a740b9675f922475fa61988c87701536dcbfafa70384fa16cdf3eb`,
`87ae278a4e71ba855040b76dd81ca0653281298a9d52e76e8fb718572223ee9f`,
`e6240cbc3e120326ce8a625781fab994a9882f26f0fd1d697f11181df193440b`,
`a69e2ca3a163c0d054ad3f65fdaef29c78af177c0f9358ae93e4a8b5eb8e1eeb` and
`4a24ae2d71308af14e6fd1b1acdaeccde565f951bb46d28e82573fcf7ccfceb7`.
At that point the image intent recorded only the socket path; it did not bind
the daemon observation or authorize a load. The full gate predates this change.

The image-intent format now also supports a daemon-bound version containing
the repeated daemon ID and socket device, inode, owner and mode. Existing
unbound records remain readable. Bound preparation rechecks the observation
around its record write and callback, and read-only recovery compares a newly
sampled daemon and regenerated stage with the record. Public status reports
whether a bound local record matches, differs from, or cannot be compared with
the separately sampled daemon; none of these observations authenticates the
daemon or settles an effect. The unit and selected-archive integration cases
passed in `.build/phase1-daemon-bound-status-unit.log` and
`.build/phase1-daemon-bound-status-integration.log` after the warning-clean
build in `.build/phase1-daemon-bound-status-build.log`. Targeted formatting
and HLint passed.

The controlled socket probe in `.build/phase1-daemon-bound-status-probe.log`
checked bound preparation, matching recovery, changed-ID recovery conflict,
public matching and differing status, and refusal before the image-intent
write and callback when the ID changed during observation. The separate
`.build/phase1-daemon-bound-real-socket.log` diagnostic used a synthetic
archive and the real local Docker socket: preparation and recovery matched,
public status reported the matching bound record, and the exact container
inventory remained unchanged before fixture cleanup. Intent, composition,
status, unit fixture and operator SHA-256s were respectively
`425ac6581a2ce5b308fc00429169d6dc8fd7c085255ec0a72d112f09717f3ae8`,
`6c2b959722995fd55fe5ce054f5218cc264c500e6b2ee1da0c079e2c8ef3573f`,
`6d0a3f08f1157001f2f7fce5597ecc4bf62f5fa05d859168bf04f6a8b921c380`,
`dbf3fe8739a26a28802019b515625e51f3151ad3c1e99b0ebc426ff05cb8f937` and
`b357c283d79d3c4d5795d478c5d7e04678554792587694a34546123045f0abb0`.
Controlled probe source and log SHA-256s were
`19cb2e59a74380aac5760bde7a35389fa01fe05ab05d1249d74831eb23b6267e` and
`ae9d1f271de42dea82cb50e2195043fbcbe0529f7c6c989e4d9e576812bfa085`;
real-socket diagnostic source and log SHA-256s were
`609b01177e5aeb3d158455a4caae6d42621751fadc6bcfbf9f65eb94c078ee22` and
`701a9203feda13ae559d27653db9bb3778f956a9d479128f98850c5205e4b3c1`.
No Docker load was performed. Authentication, daemon-side settlement,
resource ownership and cleanup, full-gate rerun and Phase 1 acceptance remain
open.

The Docker socket can now be held for a bounded callback while its kernel peer
credentials and selected path identity are rechecked. Results distinguish
refusal, a completed callback, changed observations, and interruption before
or after a returned value. This is not an effect permit or daemon
authentication: socket activation or a proxy can make the reported peer a
different process from the HTTP handler, and a later connection is separate.
`control status` reports the peer observed on its own read-only connection.
On this host an independent socket read reported PID 1, UID 0 and GID 0,
illustrating that limit; `.build/phase1-docker-peer-independent.log` records
the sample (SHA-256
`486ea033e1a2939d20a3a4a66148edd6e1473b0b4680df1c966d8a52890bf872`).

The controlled Unix-socket fixture in
`.build/phase1-docker-peer-return-integration.log` checked the peer IDs,
invalid input, a timed-out callback, retention of a returned receipt after a
peer-check failure, socket replacement and symlink refusal. The archive
regression and controlled status-socket probe passed in
`.build/phase1-docker-peer-reviewed-archive.log` and
`.build/phase1-docker-peer-reviewed-socket.log`. The public real-socket
diagnostic `.build/phase1-docker-peer-status-public.log` independently sampled
the daemon ID and peer credentials, checked status and confirmed the selected
Docker inventory unchanged. Its source and log SHA-256s were
`1bc6744a18c3e245987802e0ff9b41f0a669b16b8d83fa56422cebd7393f00bf` and
`dc5eec01313690431e73adcd0d72e81fd75fc025e286e1826af398e190fc88bd`.
The warning-clean build passed in `.build/phase1-docker-peer-return-build.log`;
targeted formatting and HLint passed. Peer, daemon observer, status, integration
fixture, package definition and operator SHA-256s were respectively
`ec41c8955d4c3b076e8daa267a017b172f716f2e360284f374d0841143fcd4f6`,
`6dc02a8bc30e1a564f2c4c6bdc77857240d4bf7922d5c622f7b10300ee96aa5c`,
`e3cd593018ca4b698ed8c14a4d3380e854e6a285860e5b151ceaf3e7c78aa6e5`,
`fb8a4cd568df784b944f31456746cce87929d8a949c9e76d25d0c58f2032d948`,
`17f07c853644dba3aafad4216fa04d15a59e916a135e7b6bdb786f245655d85b` and
`90c6184ddbfba9463f042d7cdfac85c429d5c336958b83b2e73983c1c9c4423d`.
The first build was intentionally stopped to restructure the socket callback.
No Docker load or Phase 1 acceptance was performed; the full gate predates this
work.

`control status` now also reads bounded Docker `/info` on the same held Unix
connection from which kernel peer credentials are sampled. The response has
bounded headers and body and rejects duplicate keys. This is a read-only point
observation: the peer may be a socket activator or proxy, the daemon is not
authenticated, and neither a later connection nor daemon-side effect settlement
is established. A successful read is not permission to load an image.

The controlled status probe `.build/phase1-connected-docker-info-probe.log`
covered a valid response, duplicate keys, oversized input, changed daemon ID
and symlink refusal. The public real-socket diagnostic
`.build/phase1-connected-docker-info-real.log` independently compared the
daemon ID and peer, observed the local incomplete intent, and found the selected
container inventory unchanged. The separate same-connection fixture
`.build/phase1-connected-docker-info-same-socket.log` carried `/info` and a
subsequent read-only request over one held connection. This demonstrates the
cooperative fixture, not that arbitrary HTTP peers leave a safe stream for an
effect. Existing peer and archive tests passed in
`.build/phase1-connected-docker-info-peer.log` and
`.build/phase1-connected-docker-info-archive.log`. Earlier failed builds and
style checks remain in `.build/phase1-connected-docker-info-*-build.log` and
the corresponding format and HLint logs; the reviewed build and style checks
are recorded separately. After the style-only corrections, the controlled and
real-socket probes passed again in the corresponding `-reviewed.log` files.
The connected-info source, status source, package definition and reviewed
operator SHA-256s were respectively
`a91453da797af4aeb90a82eadac5ed68d1cef6ae0e5755c30372df347262a229`,
`941c5120dafc0ce78dd022878ca0a235661cfaec4faff7b9f4829414548539e2`,
`6b69ccd26fd31158898f16cee42be0cf740dcdbb41eeb2c64795dc9313749969` and
`e19720cf76bd167dd145f0bc67a3e5d8c74e33dffb178a0926ea96a5687b7806`.
No Docker load or Phase 1 acceptance was performed, and the full gate predates
these changes.

The repository integration suite now retains a controlled Unix-socket fixture
for the connected info boundary. It checks the same connection and peer, a
second read-only request, duplicate JSON keys, excessive response size and an
invalid daemon ID. Both selected cases passed in
`.build/phase1-connected-info-maintained-tests.log`; its SHA-256 is
`5628c0aa244d2b67f8738c14ff0362857b616454db6f56f4faeabb3168ea797d`.
The test source SHA-256 is
`b3046af7a6a33ea55647aa937ce721157ea1edad7634eba6b7e9e0ad5ebaab0f`.
The reviewed test build and targeted formatting and HLint checks passed. An
earlier test build enabled overloaded literals across the entire integration
module and produced defaulting warnings; the fixture now converts its own
byte strings explicitly. This controlled test does not qualify daemon effects
or substitute for the real Phase 1 scenarios.

The image-operation boundary can now compare its durable image record with
the daemon ID and socket identity observed on a held connection under the
operation's recheck, and can compose that observation with new staged image
preparation. A mismatch refuses the callback; a record that changes after a
callback returns retains its receipt as changed. This is still an internal,
non-authorizing preparation boundary. It does not authenticate the daemon,
prove a previous daemon-side worker settled, or implement a public image load.
Real daemon effects are not qualified by this change.
The controlled integration case records a bound intent under the lease, then
checks matching and mismatching daemon IDs and changes to the record after the
callback starts. The selected tests and reviewed build are recorded in
`.build/phase1-connected-image-record-final-tests.log` and
`.build/phase1-connected-image-record-final-build.log`; targeted formatting and
HLint are recorded separately. The operation source, integration source and
test log SHA-256s were respectively
`ebcbbd4656439ce9bfcb41102c760bff36299c8ca9663f4ad4a6ce1fba8445a9`,
`85917f26405ae3bd4c34b65f4c4695ed824f5cc6963dae991c91df7e20047f4f` and
`16579ee888139fff59c229b539ac2fe310f2cd989253a96c5daa565acc860a0c`.
Phase 1 acceptance and the full gate remain open.

The archive integration fixture now exercises the full staged preparation
composition with a disposable Unix-socket Docker protocol fixture. The public
binary imports and inspects the synthetic archive; the internal preparation
holds the verified stage, operation record and observed connection together.
A second case returns a different ID on the held connection and confirms that
the callback is not invoked. The fixture records only read-only `/info` and
`/_ping` requests. Both cases passed within the existing archive integration
case in `.build/phase1-image-composition-conflict-test.log`, whose SHA-256 is
`f72e98f4fec4c63f1efb4789cbc7e9a6607399bb71d764ed433a5dd8cd1e1b30`.
The test source SHA-256 is
`c7c610a0cf2f99b49e9ca570fe7a026d0926ea0968abeaf282f8d45e7aaca694`;
the build, targeted formatting and HLint passed. This is controlled protocol
evidence, not a real Docker load, recovery, cleanup or Phase 1 acceptance.

The earlier composed fixture declared `Connection: close`, so its success did
not demonstrate that its callback could use the connection. The reusable
connection path now refuses explicit close, non-HTTP/1.1 and responses without
unambiguous length or chunked framing before invoking a callback. The separate
read-only status observation can still report an explicitly closing response.
The revised composed fixture performs a second read-only request on its held
connection, and controlled cases refuse explicit close and EOF framing. A
separate real-socket diagnostic completed `/info` and `/_ping` on the same
connection in `.build/phase1-connected-framing-real.log`; no image or cluster
effect was requested. The public read-only status diagnostic separately
matched the sampled daemon and peer and preserved its selected Docker
inventory in `.build/phase1-connected-framing-public-real.log`. The five
focused connection tests and archive case
passed in `.build/phase1-connected-framing-final-info.log` and
`.build/phase1-connected-framing-final-archive.log`. The initial concurrent
build `.build/phase1-connected-framing-reviewed-build.log` failed when a
fixture's own build collided on a temporary object; the sequential final build
passed. The source, fixture, operator and real-socket log SHA-256s were
`00cd6db0102c8c1c542e89a25b738f008d428178969722440aa86d68221e844e`,
`c7010d5b5f77e658707cc527c6030a91b64671029644689db1a79e92084a9e15`,
`a4b22bad101c7b901aa74855398cda0caa52d548fa898d150b6c6c70ae79a890` and
`33d9522daf9f4514a0170c3b78efbc6b77c5c49805af18aafa350af56b5ad913`.
The framing check does not guarantee future liveness, authenticate the daemon,
or certify that buffered bytes are safe for an effect.

The connected preparation callback now receives an opaque borrowed HTTP
session rather than the raw socket. Its bounded read-only ping uses the same
HTTP manager as `/info`, preserving the client's connection and buffered input;
the manager refuses to open a second connection. No mutation operation is
exposed by this session. The six controlled connection cases passed in
`.build/phase1-docker-session-reviewed-info.log`, including a response with
trailing unexpected bytes that makes the subsequent ping fail in that fixture.
The staged archive composition passed in `.build/phase1-docker-session-archive.log`.
The fixture does not prove where the unexpected bytes were buffered or that an
untrusted daemon cannot fabricate a response. A separate real-socket probe
completed `/info` and `/_ping` in the same session; its first compilation
failed because the package was hidden, and the explicitly selected package
build and result are `.build/phase1-docker-session-real-reviewed-build.log`
and `.build/phase1-docker-session-real-reviewed.log`. The public read-only
status diagnostic and selected Docker inventory check passed in
`.build/phase1-docker-session-public-real.log`. No Docker load occurred.

The session source, operation source, integration fixture, operator, and
real-probe source SHA-256s were respectively
`7a24f7ff6f357d74b60f530eec26134091eea1f6e2204ef71d3a902954ac7665`,
`f4f64ef3ca723e9cba39f00f3f314be323518156883acebdbb04f4a39bb8ac84`,
`08e6f38eb338d16a904d940ca2fedb096c21f4c540fa7d7063489cdefae5a42f`,
`283333daf837c56dd174f6e60ff99071073fca2fe47822dae67f71a0b0f9b6d8` and
`98e4b0cd0e3646b2bf0ae9719c455709b6e61e13986254e34cc5689711dcc9ec`.
Authentication, admission, prior worker settlement, actual effect recovery and
Phase 1 acceptance remain open.

The borrowed session can now inspect an exact validated image ID on its held
connection, using the same metadata parser as the public status diagnostic.
The bounded response rejects malformed or mismatched IDs and duplicate JSON
keys. A failed lookup, including a 404, remains an error rather than proof of
absence, ownership or settlement. The seven controlled connection cases
passed in `.build/phase1-session-image-reviewed-info.log`, covering a matching
fixture, mismatched ID, duplicate keys, failed query and a malformed identifier
that was not sent. The existing archive integration case passed before the
last fixture-only duplicate-key addition in `.build/phase1-session-image-archive.log`.
The real-socket read-only lookup returned an error for the diagnostic ID in
`.build/phase1-session-image-real.log`; it did not provide positive real image
metadata. The public status and selected inventory check passed in
`.build/phase1-session-image-public-real.log`. No image was loaded.

The shared parser, session, status, integration fixture, package definition,
operator and real-probe source SHA-256s were respectively
`73f0c71847b5dd62ce3b52a2d4354973ff6aa6de956591d244e9a93efc304a9b`,
`7ed02f5badba75f032ac8104bc321d9d8cc074136d5ef701a8b5f9766a820c00`,
`3a5c39e0373e6e2417c51d91124766f0da5bf29bfd80912f95073f9f4139d3ab`,
`32501464c1ef6fc8476dffb47d6f20723a853803a20ca7a496b03671bc066c77`,
`8b85c21f87f1c13a50912750bfb03afd84ad92fab4ef716dfd4a937ab54a8ea9`,
`c02f67cd49ff449875814a3481854454c9ad034fa74db430a09f8669802dec01` and
`e002ba48ad16e2a59cddd82f78d43fd6269fcbb8f409f3902034aa4ce8d44494`.
This read-only component is not real effect or cleanup qualification.

An image lookup now consumes a bounded, framed error response before returning
its error, so a subsequent read-only request can use the same held session.
The result still does not establish image absence or worker settlement. The
controlled suite passed a failed lookup followed by a ping and rejected an
oversized error body in `.build/phase1-session-image-drain-reviewed-info.log`.
The staged archive fixture also read its exact config ID through the held
session and passed in `.build/phase1-session-image-drain-archive.log` before
the final fixture-only large-error addition. A separate real-socket probe
observed a failed lookup and completed a subsequent ping on the same session
in `.build/phase1-session-image-drain-real.log`. The public status and selected
inventory check passed in `.build/phase1-session-image-drain-public.log`.
These are read-only observations, not Docker load, absence, ownership or Phase
1 acceptance evidence.

The session source, integration fixture, operator, and real-probe source
SHA-256s were respectively
`5d7906c5e956e898b45874e9fe3aa9061bcd209651652d5dec0ff222711b6064`,
`7470943c069dc947e1929b5caf6249e1d51c384a1bb89d2edf8923a89eb04d9f`,
`142c1f8fb1ec2617ed95ec3ffb2cf630fe4ea17571cc6a21f482d2486c8fba3c` and
`ce3d03ce3ca5d8861bc4e523244f3a3847c3866217e5445d13ba218389d76f64`.

An existing image-intent binding is now immutable: repeating the exact daemon
and socket binding is allowed, while a different ID or socket identity is
refused. This closes a case where the connection comparison could otherwise
replace the caller's prior binding before checking the retained record. The
controlled connection test includes that case, with no callback on refusal;
the unit fixture also exercises both changed-ID and changed-socket bindings.
The focused unit and controlled integration cases passed in
`.build/phase1-image-binding-immutable-unit.log` and
`.build/phase1-image-binding-immutable-final-integration.log`; the build,
targeted formatting, HLint and documentation lint also passed. The image
intent source, unit fixture and integration fixture SHA-256s were
`9ce64b3781d408157a0fdbb5358584b2e9d04fa2105d0d9cf8968c21ab05af79`,
`872571df012e550f36cccefc499177f4383585797fc650a41f3ffc022cdc740c` and
`07bf1475498bcfe9494376133a00dbcd253b95841c2e1f466b17c1355d8481bc`.
These checks do not authenticate the daemon or admit Docker effects.

A separate write-once local node-image attempt marker can now bind the exact
existing daemon-bound image intent under the parent operation lease. Creation
uses exclusive no-follow open, file and directory synchronization, bounded
read-back, and before/after intent and root checks. A partial write remains an
incomplete record. The marker records only that an effect may have been
attempted: neither its presence nor absence proves whether a daemon worker ran
or settled, and it is not an admission permit. No public path writes it yet.
The controlled integration fixture checked refusal without a bound matching
intent, write-once behavior, matching recovery after reacquiring the lease,
malformed and conflicting records, and symlink refusal. The eight connection
cases and archive regression passed in
`.build/phase1-node-image-attempt-reviewed-info.log` and
`.build/phase1-node-image-attempt-archive.log`; the public read-only status and
inventory check passed in `.build/phase1-node-image-attempt-public.log`.
The intent source, integration fixture and operator SHA-256s were respectively
`6b412d8ec65a37f442c94022d52dd39f9f6717131bbbf7a0bae42e0d9481094e`,
`956d707f5b355ec2f8addebc34dd10513cfdd1eb3b4ac40225affb5bf8d3358f` and
`3a5bb36613d35b9d0c6bcfe5a41d448e62c1f82611da6589ee4bdfceafcb3889`.
Actual submission, daemon-side settlement, exact cleanup and Phase 1
acceptance remain open.

The attempt-record fixture now also forces loss of the final stability check
after the file is written and separately delays that check beyond the record
operation's deadline. Both return `NodeImageAttemptIncomplete` and leave a
matching marker observable afterward. The timeout case reacquires the parent
lease and observes the marker again; the changed-parent case remains
unobservable. The eight controlled connection cases passed in
`.build/phase1-attempt-interruption-reviewed-tests.log`, with targeted
formatting and HLint passing. The initial formatting pass required a second
pass; both logs are retained. The intent source, fixture and reviewed test log
SHA-256s were respectively
`431653feef621784d6e28f69d6a153f071e523c16c4f0bf5995a768b840d98dc`,
`04fe8e8c74b498b2ba93e53c5b8e83ff03d18b971b9810286f8d939d829fb582` and
`735a46b608b64f865a6301a90acf9476e2fb2a8418b96320a18db6cbfb065533`.
This tests local record interruption; no daemon request, worker settlement or
real-effect recovery is established by these cases.

The retained image recovery observation now regenerates the stage under the
existing operation, verifies the recorded intent on a held daemon session,
and brackets one exact image-ID query with two attempt-marker observations.
It keeps both marker samples and the image-query result separate; none is a
retry permit, proof of image absence, daemon authentication or worker
settlement. The controlled archive fixture covered matching, missing and
invalid markers, a marker changed during the image read, and a different
daemon ID that prevented the image query.

An initial real-socket diagnostic with a synthetic archive returned an
unconfirmed connection result after writing its local attempt marker, in
`.build/phase1-connected-recovery-real-reviewed.log`. Its root remains at
`.build/phase1-recovery-observe-a2foip75`; public status and a read-only
recovery observation found the marker matching, and an independent query of
the selected Docker container label found no matches. The helper did not retain
the specific callback error, so the precise cause of that result is not
directly established. On that retained scope a read-only measurement observed
16 nested stability checks in about 7.0 seconds. A controlled slow-check
reproducer then returned `NodeImageAttemptIncomplete` at its ten-second
deadline in `.build/phase1-attempt-slow-reproducer.log`.

The attempt reader now brackets the existing intent reader with the caller's
full recheck instead of recursively repeating that recheck within it. The
intent reader still checks its root, generation and parent operation; the
controlled test also refuses a stability change across that read. The same
retained-scope measurement reported four checks in about 1.75 seconds in
`.build/phase1-recovery-recheck-measure-reviewed.log`. The corrected
controlled cases and archive regression passed in
`.build/phase1-attempt-recheck-reviewed-tests.log` and
`.build/phase1-attempt-recheck-reviewed-archive.log`. A fresh read-only
real-socket diagnostic then completed the synthetic marker and recovery
observation, with its selected Docker container inventory unchanged, in
`.build/phase1-connected-recovery-real-fixed.log`. Its disposable files were
removed; the original failed root was not removed. No Docker load or cluster
effect occurred, and these diagnostics do not close Phase 1 acceptance.

The recovery observation is also exposed by `control inspect-image-attempt
OPERATION`. It regenerates an anonymous stage, which can use several GiB of
temporary storage, and reports the exact image ID and separately sampled
marker states. The public diagnostic against the retained synthetic scope in
`.build/phase1-inspect-image-attempt-real.log` observed matching marker samples
and an unobservable image query; the retained records and selected Docker
container inventory were unchanged. This observation neither submits a load
nor proves resource absence, ownership, daemon authentication or worker
settlement. The retained original root remains available for recovery.
The expanded public archive fixture passed, including a marker change during
the image read, invalid operation refusal and different-daemon refusal, in
`.build/phase1-inspect-final-archive.log`; CLI parser and generated-output
checks passed in `.build/phase1-inspect-final-parser.log` and
`.build/phase1-inspect-final-golden.log`. The recovery source, dispatch,
integration fixture, rebuilt operator and archive log SHA-256s are respectively
`2809c5cc6fa00350b9d2fbaf4c51dc569039f673979b2bac06adfb9b8fccd684`,
`308b8ae4d845f1fadab8bdb7e39fcc4aac2714f67760d553969f2acc34cfda0f`,
`ec1662160e723737c7e6c52f658ae44e2382a4b4105ac5bc8641925656a03add`,
`d202be882b63872a449f3bc1aae79c2c1f163773954766fbb64b3a99887e1804` and
`695d7c14ca1db760e7cbe5f16c57826af4feffe91a1a3d6b65ba5848468bbeb9`.
The real-socket log predates the final help-text change and has SHA-256
`59d3ae331f52284780d9788d05e2a887b041629d5897cfc4c09abc431315c7d0`.

Anonymous image staging now refuses a projected Docker archive larger than
4 GiB before writing, including the generated manifest, tar headers, padding
and terminator in that calculation. Each streaming write also checks the same
limit before writing; the post-write stage check shares the limit. This is a
size ceiling, not a reservation or proof of available filesystem capacity.
The controlled archive fixture declared a blob total at the ceiling and
verified that tar overhead caused a refusal with an empty output; ordinary
archive and recovery cases also passed in `.build/phase1-stage-bound-archive.log`.
The export source, stage source, fixture, rebuilt operator and test log
SHA-256s are respectively
`f09bd63e8e63c4fd0c2f8187a572bfcdbf65ed1db6e639bcbc48ec42c73b32c7`,
`69a0194ddd97bd5a3e347d060f28e095c080612fd6078d16b33c8f9f90070d32`,
`4c2c03b58444be050c3ed4e390bc6217279b296471ebd38ad5d398b0c6e766ca`,
`aef70f292fc82d24fec0d17426dd05050a12a24df4c0d9abb7cce53697fb227b` and
`b8d9d80cc2dab8e842419607b66dc3e30d3bdd2b6685ffba5cfcfa471c8d1a42`.
This does not establish daemon admission, image loading or Phase 1 acceptance.

The held anonymous stage now reserves the calculated output size with
`posix_fallocate` before conversion; invalid sizes and failed reservations
refuse the stage. Reservation and export share one plan/size calculation, and
the reserved file remains held only for the callback lifetime. This funds the
archive's own file range, not Docker's image store or the broader management
capacity envelope. The controlled fixture passed real temporary-file staging,
checked the resulting length and descriptor closure, and exercised reservation
refusal on a read-only descriptor and invalid sizes in
`.build/phase1-stage-reservation-final-archive.log`. The export source, stage
source, fixture, rebuilt operator and log SHA-256s are respectively
`34f22cfb175185d527eb5b26d1b96fb4080bbbd4034330c0d8a597f5dec0c788`,
`13d7280320c4c08e77fe9ecd4c9dfe52ed980a7a95f99066f8dff12b7a6ad58c`,
`c4526cac84874899ea12c70e214170020415bdac93dea5ae3acced3d96af953d`,
`20d537682cd74844d5cca81b6c69b82693ed4e03dc10f6586f0c6565377082a2` and
`0db1491f9702eeedb979a01b4e92225dda06ef67f0283a87da4033dc79ca731c`.
No out-of-space or unsupported-filesystem condition was simulated, and this
does not establish a daemon effect, recovery or Phase 1 acceptance.
The public diagnostic also passed against the retained synthetic scope and
selected real Docker socket in `.build/phase1-stage-reservation-real.log`:
its marker and intent bytes and selected container inventory were unchanged;
the image lookup remained unobservable. The log SHA-256 is
`59d3ae331f52284780d9788d05e2a887b041629d5897cfc4c09abc431315c7d0`.

A held Docker session can now stream a bounded fixed-length image archive once
to the image-load endpoint. The transport rejects invalid lengths, non-regular
or mismatched descriptors and failed preflight checks before requesting; it
limits response capture and preserves transport failure, short writes and
failed postchecks as unconfirmed. A response is retained as raw transport
evidence, not interpreted as image success or daemon-worker settlement. There
is no public mutation handler using this primitive: admission, the durable
attempt marker, daemon identity, actual effect recovery, read-back and cleanup
remain to be composed. The controlled Unix-socket fixture verified exact
archive bytes, refused preflight cases and a deliberately lost reply; all nine
connected-session cases passed in `.build/phase1-load-transport-fixture.log`.
The transport source, fixture, operator and fixture log SHA-256s are
respectively
`068b925089d96f154225439d528afe202160889ab35b633c958c8fd2ba00009f`,
`9f5f9731bc0dd00eedd53d4492ddaeb93b86ca3617eee48aff8cead750496075`,
`ee63e0134a8142b76623bcf44386886a59560611a35944e32aa7ccd8826f07ae` and
`3e937b9371237d2c7d4070b218a255870c232f5ccd5f7b6b2819eecb5f8c05ad`.
No real Docker load or Phase 1 acceptance was attempted by this fixture.

The new connected-attempt composition now writes and reads back the exact
daemon-bound attempt marker before entering its callback; existing or
incomplete markers refuse entry. It rechecks the marker around the callback
and retains a returned value separately if the marker changed afterward.
The controlled archive fixture composed the held stage and socket with the
transport, verified the marker before sending, observed one fixture request,
and refused a duplicate operation and a pre-existing marker without a second
request. A changed post-callback marker preserved the callback result as
changed. The selected archive and connected-session regressions passed in
`.build/phase1-attempt-composed-final-archive.log` and
`.build/phase1-attempt-composed-final-info.log`. The composition source,
fixture, operator and two logs have SHA-256s respectively
`c0e1ebb29b3551b9d693268270d0a724c5b5c76e461fe4c5d261fc607771853c`,
`c6d28e53a3374f33f2ea69c426d3bbdf1e9e5ad1052e12f310d829070ff426de`,
`0c1e480a088cca040c1965fb72cecf46019b7e4c063abeb6a23c8e19e3a70034`,
`080e77a98c11568511eeb821a55c7db3fb3db78e9bd346e83182058a99acc6f2` and
`a4d4999ecb31156b1510c1520b9f583e3b129c5f6e0a85252e2f1e1ed236602d`.
The callback still requires separate admission and daemon authentication,
settlement, real-effect recovery and exact cleanup. It is not a public load
command or Phase 1 acceptance.

The load transport now classifies bounded line-delimited progress responses
instead of retaining their provider-supplied text. It distinguishes embedded
`error` or `errorDetail` values from parsed progress and refuses malformed,
duplicate-key, empty, unknown and over-limit streams as unobservable. A parsed
progress stream is not a success receipt: Docker's
[API changelog](https://github.com/moby/moby/blob/master/api/docs/CHANGELOG.md)
describes JSON progress streams and their embedded error fields. The composed
fixture also sends a separate exact-image-ID query on the held connection after
the load and preserves both results; this is a same-session observation, not
an independent observer or settlement proof. Invalid image IDs refuse before
submission, and a lost reply followed by an unavailable image query remains
two separate failures. Eleven connected-session cases and the composed archive
fixture passed in `.build/phase1-load-observation-final-info.log` and
`.build/phase1-load-observation-final-archive.log`. Their transport source,
fixture, operator and log SHA-256s are respectively
`24efc26cfc0df3ac7e112f61fe6ed6e6c04a604488766b05a5dcfe1b794be8de`,
`5a4b489b73837f55702288ceeeebe2c4dc2e4cb8cd16870e281a34d28ab70470`,
`ff956974508a47b56574af433172bbdd0cc67158d5e09b83d194478a15da6b8f`,
`ca3fd649bc2130bbf46203990baaa62442fd747fe73723119a98cb9c4d20ffb1` and
`8657197a421cca43539304992b519f491e546504e333730be9f44b699a12a3ca`.
No real image load or Phase 1 acceptance was performed in these fixtures.

The same-session image read-back now rechecks the supplied operation/marker
boundary after the query. Its result distinguishes a skipped read, a stable
sample and a changed sample, preserving the actual response or query failure
when the boundary changed. The controlled socket fixture changed the supplied
scope check during the image query and observed the changed sample; it also
retained the separate failed-query result after a lost load reply. Twelve
connected-session cases and the composed archive fixture passed in
`.build/phase1-image-readback-info.log` and
`.build/phase1-image-readback-archive.log`. The source, fixture, operator and
two log SHA-256s are respectively
`c3b0457d55993464dc270abcec3fb79db8cd136f146f614b9a817e5ef9ffaed2`,
`44f3755584686532178c481be789d663e81b52f23063f596db9edd7c57183e75`,
`a7a8c2b1a7c0b0f34acf655ec101ce68e03c5059ec70d1ab17613555edbc77a7`,
`6a299d9a10ab972d2f984dce5de38e801967f4da27bdddbc0537e4fdf028343d` and
`23d8f4cbaee98cfef2790e6ea7860c4e1d16a3d9015b373acb9f1cbb791c848e`.
These samples still do not authenticate the daemon, establish independent
resource observation or settle an earlier worker.

A write-once local result record can now retain the bounded image-load
transport outcome for the exact daemon-bound attempt. The composed attempt
records its callback's transport result and reports a record failure separately;
an existing or unreadable result refuses callback entry. The public
`control inspect-image-attempt` diagnostic samples that local result alongside
the attempt and image observations. The result is not a daemon receipt,
resource ownership proof or worker-settlement proof. The controlled fixture
passed creation, read-back, invalid outcome refusal, existing attempt/result
refusal, missing, corrupt, conflicting and symlinked result observations,
changed-marker handling and public diagnostic output in
`.build/phase1-image-result-final-archive.log`; the connected-session cases
passed in `.build/phase1-image-result-final-info.log`. An earlier run in
`.build/phase1-image-result-composed-archive.log` correctly classified a
world-readable planted result as unobservable; the fixture was corrected to
mode 0600 for the separate corrupt-record assertion. The public real-socket
diagnostic reported no result record on the retained synthetic scope and left
its records and selected Docker inventory unchanged in
`.build/phase1-image-result-real-reviewed.log`. No real load was submitted.
The result source, composition source, dispatch source, fixture, operator,
fixture log, real diagnostic source and real diagnostic log SHA-256s are
respectively
`405c033c8ddb150760074883abd2a49052cf2d104094a904e652432cf18af792`,
`143a337040cfa8ab2e1e9bee3993f8b32d8d6110db89b28be61a45e5d668b1fa`,
`89785e304fe316d256aa9fe859a27288d7316c4aa9b2d68e794a41242e272982`,
`913ee83df9c92b01371483b79c27ea2aec4e35f8c11cd313e6f5da3d89b893dd`,
`76b43fdda38789ccc2cb93c0e7cb0896449906d93fd0437ae37d4cf07cb727ed`,
`821e6d69cede78c866e36ee9355eccfafc71bfc3e3a4cd010ef9df4352dff37a`,
`e490412eb3a02c28ea1602238395b29b62a269c377b7f0c695dab28b8c10973b` and
`59d3ae331f52284780d9788d05e2a887b041629d5897cfc4c09abc431315c7d0`.
Public mutation admission, actual recovery and Phase 1 acceptance remain open.

The public recovery diagnostic now adds an exact-ID observation through a
separate Docker CLI request. It compares repeated selected-daemon observations
with the recorded daemon and rechecks the operation around that request. The
result is a point sample from a second client, not daemon authentication,
resource ownership or daemon-worker settlement. The controlled socket fixture
observed the expected image through both clients and changed the daemon ID
during the separate request; the latter sample was retained as changed in
`.build/phase1-image-independent-format-archive.log`. The real-socket
diagnostic in `.build/phase1-image-independent-real.log` found the CLI image
query unobservable on the retained synthetic scope and left its records and
selected container inventory unchanged. An initial build failed on an
ambiguous rendering type in `.build/phase1-image-independent-build.log`;
the type was fixed and the final fixture passed. The recovery source, dispatch
source, fixture, operator, final fixture log, real diagnostic source and real
diagnostic log SHA-256s are respectively
`474b87a242a7da0d1a1c3de98cd17cd4a1b54fcfab0a4f0382445cfcaf5b1944`,
`e926590221291f0028603adfb2631c74cba52fa51443bf7349fcdcec7c61e898`,
`05b343009c540929e38e3d035f0ff3f325f4c6253a84d75f78eaeead91132900`,
`596f8c86cdc82139b39aca372052c6443c2ec5e327adcec29c1a0231af2e67af`,
`d548248e26ada5449b25a67ac16f8df3b45abcca6774618333c483623859a740`,
`deeb748c79219535a3858b0e73b6a9568b3f767edf87a0fe815e004ada54ebdd` and
`59d3ae331f52284780d9788d05e2a887b041629d5897cfc4c09abc431315c7d0`.
No real load, cleanup or Phase 1 acceptance was performed.

The canonical `dev check` found three fixture style violations in
`.build/phase1-canonical-gate-current.log`; after those were corrected, its
bundled formatter found source formatting drift in
`.build/phase1-canonical-gate-style-reviewed.log`. The bundled formatter then
passed repository-wide, and its HLint pass found two conditional-style hints
in `.build/phase1-canonical-gate-final.log`. Those patterns now share an
explicit optional-daemon helper. The bundled formatter and HLint rule set
passed on the affected files, and the rebuilt connected-session and archive
fixtures passed in `.build/phase1-canonical-fixes-info.log` and
`.build/phase1-canonical-fixes-archive.log`. The operation source, intent
source, dispatch source, fixture, operator and archive log SHA-256s are
respectively
`43369d8854e69028a9c583968839f01a786a882eb88ed250732ff2687a53bcad`,
`9a1f6d600b2119739122e1390649e68dc0a643d9928c7270e4d6c290e4b48662`,
`af1d5d3ba4812c4f492366149858b87ffeaaffdfee9113dc693758f0434a840a`,
`74a79a1af3f60643070f2601a0cc1207dd8702d50583578ff967956125918c72`,
`35168bb4b95ef6c104a706d56d2b5682b3f5a70b83499cfff7d3a09d3c630a17` and
`52d6d7135f70f6442ed6e2f4ed39d7f7470fcd85263961399aadaacf055be169`.
The earlier gate runs did not reach the warning-clean build or gated suites.

A read-only positive-control probe queried the explicitly selected local
Docker daemon's visible image inventory, then inspected the retained synthetic
image ID and attempted to select a distinct existing image for a positive
control. The synthetic inspection returned nonzero and no distinct control
was available. The inventory, sampled daemon and socket identities, and
retained records were unchanged; no image IDs or metadata were retained in
the log. The nonzero inspection is not proof of absence. The probe source and
reviewed log are `.build/phase1-image-positive-control.py` and
`.build/phase1-image-positive-control-reviewed.log`, with SHA-256s
`6e3595859a85adec50591c42ee275b5fad010d772cc3b6c01c418a22e4a114ad` and
`76420ff08567eafa8170048bfb40c3bf9294852b4696770131895ba3f2f26224`.
This does not establish a real image load or Phase 1 acceptance.

The installed kind reports `v0.32.0` and its executable SHA-256 is
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
The corresponding upstream
[Docker image preparation code](https://github.com/kubernetes-sigs/kind/blob/v0.32.0/pkg/cluster/internal/providers/docker/images.go)
inspects the configured image reference and attempts a pull after any inspect
failure. The current kind plan supplies the configured named digest, while
the staged Docker archive deliberately contains no repository tags. Whether
the real daemon resolves that named digest after this load has not been
established. The adapter must bind a usable verified local image reference and
constrain kind's Docker interface so an inspect failure cannot trigger an
unowned pull; a precheck alone is insufficient. This source review and
`kind create cluster --help` were read-only and did not create a cluster or
qualify acceptance.

A controlled test of the installed kind executable used a fake `docker`
executable, a nonexistent selected socket and synthetic coordinates. After
one failed exact image inspection, kind requested five pulls; the fake refused
each. The source, result, network-syscall trace and synthetic request transcript
are `.build/phase1-kind-pull-fault-evidence.py`,
`.build/phase1-kind-pull-fault-evidence.log`,
`.build/phase1-kind-pull-fault-evidence.trace` and
`.build/phase1-kind-pull-fault-evidence-requests.jsonl`, with SHA-256s
`bbbaf9c44f1251ff2eb8c9a821885aae5c1f6916aaa7b7489c6f93c79eaf2614`,
`67e40e81ffb460788d404d3fcf0bd1a7856e5710234252214369fa0ae85e4176`,
`83e9077ad192cf0889086d3679ce4b6d1da4fb385d2d4280f056ba95d66f247a` and
`cd6dad43b15fea9e9281e54732e5304a0d1ffeb7e58c56ff5722619a89a82272`.
The initial fixture in `.build/phase1-kind-pull-fault.log` stopped at an
unimplemented fake `ps` response; that fixture was corrected before this run.

A second controlled fixture supplied two synthetic same-name networks. Kind
requested removal of the second ID; when the fake returned a silent failure,
kind continued to request a container run. The explicit-denial control emitted
an `Error:` line and kind stopped before that run. The respective sources,
logs, traces and request transcripts use the prefixes
`.build/phase1-kind-network-fault` and `.build/phase1-kind-network-denial`.
The fault artifacts' SHA-256s in source, log, trace, transcript order are
`3a3c7d74dc3956e97d09e3bb803eb78b9e842cad2a91868a582beeab5619d861`,
`dac602b83ccf82c4abd5328de9421f2abe837c50bd1970543431ffbbe9b80563`,
`e71790c8f827004430274f6ffbf7d837a87c69cda37f507c348da754a6fcff34` and
`56a1413a3916910b6173a731861ee98b23f5d9436276d606dabd9a6269751a4b`;
the denial artifacts' corresponding SHA-256s are
`8ce89b013d2a62f101351710716896dc1f718eb76167d1ce1563d086d556a0e8`,
`c6c43ff7b2d1d2663bd7b2f243797b3f9090c227a57815f21118283de1908ac3`,
`a720e13af51687cebe0eec453399797f3dcc38bef381c18aab569ec35465c58e` and
`3359506abadc4782e9adba4b6992a7237b754082931e2186d7886f2dd645615c`.
These fixtures did not enforce an OS-level socket sandbox; the retained traces
observed no network `connect` calls. Earlier untraced fixture wording that the
real socket was unavailable was too strong. No real network removal, container
creation, or Phase 1 acceptance was performed. The eventual guard must prevent
foreign removal and prevent any subsequent effect after a refusal.

An additional controlled fixture supplied a single-node kind configuration
with a test-root bind, a distinct network, a pinned synthetic image and fixed
API/HTTP/HTTPS mappings. After the fake's silent duplicate-network refusal,
the installed kind requested a container run containing those coordinates;
the fake refused that run. The fixture source, log, network trace and request
transcript are `.build/phase1-kind-run-shape.py`,
`.build/phase1-kind-run-shape.log`, `.build/phase1-kind-run-shape.trace` and
`.build/phase1-kind-run-shape-requests.jsonl`, with SHA-256s respectively
`63ee37542afeca5c559bca453e435c6a8cc1847d0e43d65c16a0809b7e8742ce`,
`119ac15ef125c1343d0580e87e279db0e025ae3b163399bd14337698a211e31b`,
`f30d35962062068694d9fc5cb919a92dee6a4c043ece616d89b8fd2c874b2e27` and
`e8942fcef7e2e72dcce07bec2c1d6afdb809dbed44b43024b1a31ffcb92bf3f9`.
The trace observed no network `connect` calls; the fixture was not OS-sandboxed
and did not create a real node. These arguments are an input to the future
guard, not evidence that its full allowed command set or resource limits have
been implemented.

The canonical gate subsequently passed full-tree formatter and HLint checks
and the warning-clean build, then failed two of 10,046 unit cases because the
generated CLI JSON and help goldens lacked the current staging-space text.
The failure is `.build/phase1-canonical-gate-after-fixes.log`, SHA-256
`751f9c345724dfe679b5e68c5a30854b2a775dd7d88b29a76213c21c55fe2de2`.
The goldens were regenerated from the current unit executable; all four
generated-output tests passed in `.build/phase1-cli-golden-current-test.log`,
SHA-256 `356f0e770c6426be66910051ce212fd2d8768aa272ecc448daceed5b504b7cbc`.
The updated `commands.json` and `help-all.txt` SHA-256s are respectively
`a3510ab8bb9e0d300776df2b12677cdcd8eca7a23b22ed83ab4c5989dd77d0b5` and
`33e9f17c7fee82fa7971e343560e4845f9991ebb255d2c4f4a1b397d7cc9d0d8`.
The full gate has not passed on the updated goldens; the other gated suites
were not run by that failed invocation.

The host reports Landlock ABI 8. A disposable local probe applied Landlock
file rules that denied an outside regular-file read, then successfully
connected the same restricted child to a pathname UNIX socket outside its
allowed workspace. The source and log are
`.build/phase1-landlock-unix-probe.py` and
`.build/phase1-landlock-unix-probe.log`, SHA-256s
`fc011412c4ff9d46d126658f6add54e59ffc43171f674b0d18f5581223c0976e` and
`3c3c03572672ac8350fe5b42311d5a8247b5e89608af8daf6db4f9a0486407aa`.
The [Linux Landlock documentation](https://docs.kernel.org/userspace-api/landlock.html)
identifies pathname UNIX-socket resolution control as an ABI 9 feature.
Consequently the future kind guard cannot rely on this host's file rules to
block access to the real Docker socket while allowing a separate proxy socket;
it needs an independently enforced socket boundary and an exact permitted
communication path. This is isolation evidence, not a provider operation or
Phase 1 acceptance.

The intent source, recovery source, integration fixture and operator
SHA-256s were respectively
`63151e41a436ee6a500ed4d8243518580d12bb124466bae18e64e5ce09a390d4`,
`0c350cc34b8827b6119647549e2d89ec729998208224f86cc76c318efbf1920d`,
`b281ec9e8c10c9b5a39443e396d65b442a6dc0d5569df4aeb371e9bf6e09d5e6` and
`757896e4c68b52f6d7c41eec830109ba48e384e2586831211b725923c793454a`.

`control status` now reports the local image-attempt marker after independently
re-reading the exact parent image intent. It distinguishes a missing, matching,
conflicting, invalid or unobservable marker, while leaving daemon effect and
worker settlement unverified. If the parent intent cannot be validated, the
attempt state is unobservable; a missing local marker is not resource absence.
The public binary exercised those states against a disposable socket and test
root in `.build/phase1-attempt-status-reviewed-public.log`. The connected-info
and archive regressions passed in `.build/phase1-attempt-status-info.log` and
`.build/phase1-attempt-status-archive.log` before the last fixture-only
missing-parent assertion. A separate real-socket diagnostic wrote a synthetic
local intent and marker, independently compared the sampled daemon ID and
selected Docker inventory, and checked matching and corrupted public status in
`.build/phase1-attempt-status-real.log`. Its disposable files were removed; no
Docker or cluster mutation was requested. This is diagnostic evidence, not a
real submission, worker settlement or Phase 1 acceptance.

The intent source, status source, integration fixture, operator, and two
real-diagnostic sources had SHA-256s respectively
`431653feef621784d6e28f69d6a153f071e523c16c4f0bf5995a768b840d98dc`,
`e239a78482a16f8c707d9211293f70f04afd96d2a12149fc5c8a540b13004dda`,
`6f9f341552836758ceb222df21715c18055389e705a9e4a9ee1972b24f8a2e6d`,
`32853a08bbc02fc5dc684636f4ca2775999895a6c0d8f2f262ebbc7f7a7018`,
`67922bf8d49297e1d7f343c0925060ba5aad5975f0b405d596744dcb35e90886` and
`1ecee492264afab3d148fa58a7085e9c3213d8c65e12a6408e2c776380e4d7e7`.

The public `test run cli` route now selects the CLI integration suite directly
instead of requiring a legacy test topology. It shares the local runners'
limited child environment and option refusals. Because that suite still
exercises legacy lifecycle fixtures, the route refuses existing or
unobservable RKE2 installation markers; the host check does not honor the
legacy test override. The selected host-guard fixture covers absent markers,
files and dangling symlinks. On this host the public command refused the real
RKE2 installation even with the legacy override set to absent; no complete CLI
suite was run here. The selector and existing unit/env routing were checked
separately. This route is not the Phase 1 cumulative scenario/evidence runner,
and no acceptance case is closed by these checks.

The host refusal, guard fixture, selector list, existing-route regression and
generated CLI golden tests are respectively recorded in
`.build/phase1-named-cli-host-refusal.log`,
`.build/phase1-named-cli-guard-tests.log`,
`.build/phase1-named-cli-selector.log`,
`.build/phase1-named-cli-existing-local-routes.log` and
`.build/phase1-named-cli-golden-tests.log`. Coverage and AWS-substrate refusal
checks, generated-document check, documentation lint, targeted formatting and
HLint also passed. The runner, legacy marker catalog, CLI registry, integration
entrypoint, fixture and operator SHA-256s were respectively
`f8435dab132747e6a6a5b6c4d4b391bdf284b9607b411f41a13b183e7dd4de31`,
`5c0a0544a3835920aa006a611c54f90cad3473a1cfa7e159dccd9703e45b7930`,
`c06cb8824984495650f0c9b474a74b2bb3378895260a050b7ea0a1cd44b63f4b`,
`d5809e35da21f3518d801da43043c40ef55fdbe8429316c4866fbcc0f24944f2`,
`579062645b6eacf2374b9a98ae1c59b13db5ebf6536e880850af2157be141001` and
`c68318f2dcc686b8da09fd5785b123093ccc2a0944ef853af749d960438bca0f`.

A further disposable probe ran the installed kind binary under the existing
x86-64 mutation network filter and routed fake Docker requests through a
test-only FIFO broker. Each fake Docker child observed that a fresh Unix socket
was denied; the broker observed one missing-image inspection and refused five
pull attempts, with no container run requested. The traced child tree made no
network connect call. This fixture did not use the real Docker daemon and does
not establish filesystem confinement, concurrency safety, cancellation or
settlement, or a production admission boundary. Those remain implementation
and acceptance work for P01-T03.

The launcher source and binary, probe source, log, trace and request transcript
are `.build/phase1-kind-seccomp-launcher.hs`,
`.build/phase1-kind-seccomp-launcher`, `.build/phase1-kind-fifo-broker-probe.py`,
`.build/phase1-kind-fifo-broker-probe.log`,
`.build/phase1-kind-fifo-broker-probe.trace` and
`.build/phase1-kind-fifo-broker-probe-requests.json`, with SHA-256s respectively
`80fbba78c7d6fa9ab800b1acee53305e19a92a7d32c5a9cdc069eb7bbd61b8bc`,
`89a24e59f19f033c3af239624730d6996c26e5c606acec3eb4a75c6eb4e55d31`,
`98c33102181426c6e194fb2fb767bceecf4778af1cb49d057a50c973fa77f774`,
`fa57eac82d49a0250efe5a05c81422d638a2777d90c8569ce3f909083f16bd64`,
`c12eb6b8562591a408633ca946fbfc4166b9027ed7bf3fcc07c82deeaa9c4f7a` and
`66a0c7686942b0523255366d5ead0bcbe21d4da2db7965ededa607866f8296f3`.
The network filter source SHA-256 is
`5f1f4fc926f92c193e4529d25a1f3894b3164b40a3b763acdf5fae4d3ff5a618`.

A separate seccomp-filtered kind fixture supplied a local `sha256:` image ID
in the configuration. Installed kind requested inspection of that exact ID and,
after the fake inspection succeeded, passed the same ID to its control-plane
container run without requesting a pull. It also continued after the fake
duplicate-network removal failed silently, as observed above. This suggests
that an admitted runtime configuration can use the independently verified
config ID rather than relying on a tag in the staged archive. The fixture used
synthetic image responses and no real Docker daemon; it does not establish
daemon acceptance, image provenance, network ownership, or authorization.
The probe, log, trace and request transcript are
`.build/phase1-kind-image-id.py`, `.build/phase1-kind-image-id.log`,
`.build/phase1-kind-image-id.trace` and
`.build/phase1-kind-image-id-requests.jsonl`, with SHA-256s respectively
`f987ecd1735319a83d1da1b147399b0cbfb1a39e5af5c9934b2d9457e5396989`,
`d641b3429a564b26b5baccf04c273c1e3041579de8fba12ca40faf969b36d8fb`,
`335f4ff5f07af56bfb8a7906b77c3b5fc61a9a4fee50e94a6a13863f48b5277c` and
`4c36fbb7b824c78698e2c408db5e225b9b6fed7f65180f8ca0d4e6286c833e8b`.

The archive observation now retains both the configured selection digest and
the selected platform manifest digest. A pure runtime-config projection checks
the selected digest and renders the observed config digest as the local image
ID; the existing archive diagnostic reports whether that projection is
available. This is not mutation admission or a real daemon observation. The
canonical gate passed before these source changes; the new source requires its
own validation and eventual phase gate. The focused archive fixture passed
after the change for direct and nested OCI/Docker manifests and rejected a
foreign selection digest and malformed config digest. Its build and result are
`.build/phase1-kind-runtime-adverse-build.log` and
`.build/phase1-kind-runtime-adverse-integration.log`, SHA-256 respectively
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66` and
`1cd90f7746d32b6f3dceaaf47a43cded51f0dc944401aa11f10d65444e67d4f6`.
The kind execution boundary and real acceptance remain open.

A serialized internal read gate now recognizes only the selected cluster's
container listing, Docker information and exact local image-ID inspection. An
unknown request, reported read failure or exception closes it before any
later request runs. A deferred-result fault initially showed the gate reopening;
forcing the callback result inside the guarded region repaired that case.
Focused source tests passed for those cases, concurrent queued reads and
cancellation. The test ran the repository test module with a byte-identical
copy of the gate; `.build/phase1-kind-read-gate-focused.log` has SHA-256
`d4f0a181cb557e0301abf67d3bdba2624f228b90023f270218166e070c6ed735`.
The gate source and test source SHA-256s were respectively
`9a066b18ce5f361e27b6fdb3c3c3fb993ecc3278e0606a126190bc3542d980a1` and
`315d35b8482579ea6a6bfae919e2900259a780ec06c3c6eb4d68ccda78f124ed`.
This gate alone neither intercepts kind's requests nor enforces a sandbox,
authenticates a daemon, admits mutations, settles workers or cleans resources.

The public image-attempt diagnostic now uses the gate for its exact image-ID
read on the held Docker session. A local socket fixture observed one allowed
image query, then verified that a foreign image request and a subsequent valid
request were both refused without reaching the fixture. The archive fixture
also passed with the diagnostic change. The focused result is
`.build/phase1-gated-connected-read-test.log`, SHA-256
`3584aac04e50d844bfdc8fe1d546f8d4f9c5e6e209479e2f960b9587ba28b162`.
The gate, image-operation and integration-test source SHA-256s were respectively
`e99e7d7bd29234c8f0452ad515308fb868bb1cec9185f4f742fe2da3d9d4c5e8`,
`9680e79893785b111756206ebd56eb843a9025a176912aee90b8b1d0b27f8546` and
`d175477dbde5e067b56f9bcf91700c9c90c1fdbed9ea95ab0ce64789431c124d`.

The held session can now also project the bounded Docker provider fields used
by kind after matching the response's daemon ID to the session's earlier
observation. At that revision the read gate interpreted this provider-info
request and exact image inspection; container inventory was unsupported. A
local socket fixture passed the supported reads and showed that an ID
mismatch closes the gate before a subsequent image request. The focused test
log is `.build/phase1-gated-kind-info-test.log`, SHA-256
`b673b1ad62965086333e0e784c84e356d84c1d1b372133cc02ab54270b9dcc32`.
The connected-info, gate and fixture sources had SHA-256s respectively
`0a2c5a32a99cd8271eab45b63c3ffd7df29d618a98c570c2e646c9038bd4a0ba`,
`a8f9d1e79011415f1f7885fb91dbc94351c897e8fa4ceb3c9c008aa4222a674a` and
`2b6759d57f2a6f1bcd51f0979044b776421c5810472f2df2fceb6bf89f8eee30`.

The gate now also performs a bounded container-list read on the held session,
with an encoded filter for the exact selected cluster label. It accepts the
single expected control-plane name or an empty list and refuses foreign labels,
names, malformed IDs and extra entries. A local socket fixture passed empty and
matching responses and showed that a foreign label closes the gate before a
later image query; the parser's adverse cases also passed. These are provider
observations only, not independent ownership or absence evidence. The socket
and parser logs are `.build/phase1-kind-inventory-adverse-test.log` and
`.build/phase1-gated-kind-inventory-unit.log`, SHA-256 respectively
`21e5037ea6488330d71c30842718089999a63c3f33222e8ea17219beb6855689` and
`2443ef6c5c386ca9bca35c87341b49ca5739bf19a6ab4a4276b3c8ea6da1ba9a`.
The connected-info, gate, unit and integration sources had SHA-256s
respectively `103faeef2e5f5a8f0b88c77b9de20d99625791cf4256506b7f71eda2a431f2b5`,
`29268b0b25546a00220480f0e36b4769570c7c7de90c0e1d470976ff295590c5`,
`07c557f9f8ab908aef5b39b526d81f8b0367e5830252bb21e40860dd1e01c106` and
`7e4277aba38209f07ce5564c03a5c1e907af9e43dace1a3164b08cdafd41fee4`.

The connected read interpreter now projects provider information, selected
container names and image-inspection success into the outputs consumed by the
observed kind provider. Refusal and read failure return a nonzero status and
explicit error; the gate remains closed. Four local socket-fixture cases passed,
including a denied pull followed by another refused image query. The result is
`.build/phase1-kind-reply-test.log`, SHA-256
`f554204daab7c6e8c85a84393598b85310152cefc5e400d0583198e59976449c`;
the gate and integration source SHA-256s were respectively
`9f6003d39440757d21f686f88d6f4c3ba63bc58a38c0506a7ceecdb1cdab557d` and
`7ee37bd40cc46c4b14462bd7b218f38f49478db56425580ce523ba258f8fe0a9`.
This projection is not an installed transport, daemon authentication,
mutation admission, or real kind acceptance.

A bounded single-client framed stream now drives the connected read
interpreter. It closes the gate on EOF, malformed input, refused requests and
transport exceptions. The socket fixture passed a successful info/image
sequence followed by a refused pull, malformed and oversized frames, truncated
input and a closed-output failure; it observed no image query after refusal.
The result is `.build/phase1-kind-read-protocol-io-test.log`, SHA-256
`f4697f19fded9a788eb8261fe280ba610395f56e5120479b3b2f0ad5621046a3`.
The protocol, gate and fixture source SHA-256s were respectively
`abfca8a8bc8f5eb8c69ddbdb86c404f07c941cd9c91af90cc6ede6b803640161`,
`ff5a2e0095395d450c8148398393d8d8220117e63ab591fdd38e981a907fa54a` and
`5420fc2946dbe5e9828ee4010280a8173c80f40cae35b9f3ebd3db1511e4aabd`.
It is not yet a kind process transport: peer confinement, finite lifetime,
worker settlement, mutations, ownership and cleanup remain unimplemented.

The matching framed client now validates response length, JSON uniqueness,
field set, exit/output consistency and ASCII content. A duplex pipe fixture
exchanged provider information and image inspection through the held session,
then observed refusal and server settlement after a pull request. Separate
fixtures rejected malformed, oversized, truncated and ambiguous responses.
The focused result `.build/phase1-kind-duplex-adverse-test.log` has SHA-256
`ced112987f983bd88e718aba1ecc845c129762aed7917e8e5bf15775c4ec7be5`;
the protocol and fixture sources had SHA-256s respectively
`a0fb8a0a7fe779b2d60473f8530036e103948d93cb02594166a62139a399e951` and
`e2ca1082955754b23b7daae48146983be95cbf5fc4a20757b972f9c16d84a20b`.
The caller must still authenticate and isolate the endpoints, impose a
deadline, settle the worker and provide the actual kind process transport.

The framed client also has a bounded serialized exchange using independently
opened lock descriptors. It checks lock ownership, mode and link count, writes
and synchronizes an in-flight marker before sending, and clears it only after
a successful reply. Local fixtures passed contention, cancellation, refusal and
marker-retention cases; later exchanges refuse a retained marker. The result
`.build/phase1-kind-client-marker-test.log` has SHA-256
`9e0da6eb72e3a2e34d10dce83b97ede5bb0e4ccaa560d22c5dbbf40ccb4f8b57`;
protocol and fixture source SHA-256s were respectively
`d93a69c17e6466145aec52133455d75701fe691dca8e86bdb922789db8772adc` and
`4bafcf70312cc63a9f1510d431fd44fd08a93c42c9bfd8a6c32d644ffeacb59c`.
This does not bind independent descriptors to one verified pathname, resolve
storage or peer failures, recover a marker, or settle the other endpoint. It
does not authorize running kind or introduce a supported mutation path.

A separate endpoint observation now opens an existing lock and two FIFOs
relative to a held directory, checks type, owner, mode, link count and device,
and reopens the names to compare identities. It preserves a returned receipt
when a subsequent recheck reports change or fails. A local fixture passed
replacement, symlink, hard-link, unsafe-directory and failed-recheck cases;
the endpoint, fixture and result SHA-256s were respectively
`35fc9eca11bec9055bcf6ea66338c0b67bcfdcb99435328da8585b931e8f23a2`,
`075623b6f9c49b43ea102d7489317058d90acf505e6879300137be37c63d027c` and
`cb48c6626f701cdfcab84b381cafd50166f8b210cd70aa48b14c35d15636d684`,
with result at `.build/phase1-kind-endpoint-test.log`. These rechecks do not
exclude changes between observations: the caller must bind every client to the
same directory, confine writers, own deadlines and settle the endpoint. The
observation is not yet connected to the process transport.

The serialized framed client is now composable with the endpoint observation:
each exchange opens and checks its own lock and FIFO descriptors, and duplicates
borrowed FIFO descriptors atomically close-on-exec. A disposable FIFO/socket
fixture passed provider-info and refused-pull exchanges through the bound
endpoints, while preserving the in-flight marker after refusal. Endpoint
replacement and close-on-exec checks also passed. The endpoint source, fixture
source and `.build/phase1-kind-bound-exchange-test.log` SHA-256s were
respectively `d1009cae7a5de2d5a35bbdeaa99d663af4f2a2e713a17bde920fe287eae2c186`,
`052ca096dbec02c7b02eab1b047d186cbae2ec774a723ba0f0b0b344d7766967` and
`90e7c516df33dac3a5bf5c7df0b4b22d854f4a6f057cfad5df92e05db127dfcd`.
The kind child, endpoint creation and binding, filesystem exclusion, worker
settlement and recovery remain outside this fixture and are not accepted.

The server can now use the same endpoint observation, rechecking it before
reading a frame, before its Docker read and before replying. A local fixture
passed a normal bound exchange and forced the root recheck to fail during an
info read; the server withheld the reply, both sides reported changed state,
and the client's in-flight marker remained. The focused result
`.build/phase1-kind-bound-server-test.log` has SHA-256
`7c948e0abb944b88dedcc88103b45535cfee8f9823622e3b9388b4a7162cfbba`;
the endpoint, protocol and fixture source SHA-256s were respectively
`9e7192d8c149439ef3916244b96d471cd64710fef96426ae47181829a4882e90`,
`03b1920899bdef974a450d218d461bc74be2b3cace0c9468004623af5600e341` and
`1e3b6e224440bb23bf2879bfab035c9e682f794a11f15e1cc6c91fedb11fe899`.
Rechecks do not exclude concurrent writers, and this still does not establish
process confinement, mutation admission, external worker settlement or
recovery.

A dedicated internal Landlock policy now permits a separately supplied
writable scratch directory, read/execute roots, the specific lock and FIFO
inodes, and read-only access to a verified Linux null character device. A
disposable Haskell worker passed on this host: it wrote in scratch and used the
designated lock and FIFOs, while attempts to write another file, open another
FIFO, read an outside file, unlink or rename an endpoint, and write to
`/dev/null` were denied. The outer fixture independently observed the scratch
file and intact FIFO. This follows the [kernel's Landlock access model](https://docs.kernel.org/userspace-api/landlock.html),
but does not itself prove scratch/endpoint disjointness, close inherited
descriptors, prevent socket connects, install metadata restrictions, or settle
workers. It has not been composed with the production kind launcher.

The policy source, worker source and binary, outer fixture and result are
`src/Prodbox/Control/KindDockerFilesystem.hs`,
`.build/phase1-kind-filesystem-worker.hs`, `.build/phase1-kind-filesystem-worker`,
`.build/phase1-kind-filesystem-worker-probe.py` and
`.build/phase1-kind-filesystem-worker-final-probe.log`, with SHA-256s respectively
`94e7929030e1e9c4f9d64bae9115b2a3312050b9d850e49bbc06c9b5b6102e9b`,
`7c99ddd6008061c9f7affba53f4e24ca56eb11625100a040cb3b88017f30e824`,
`57f86ab1fbb96c69728cd991a08c7da6d1d4171a454bd8f705b760ee51d6fc7c`,
`6d0863f03c79f42876b31dc2020393b9dd58c66dc0a1131975a3e2cbbc497d8a` and
`ada15d94d55c052036b98e5cc01cba9f4d695028ce29cae8b63223d96d21fcfe`.

An internal worker preparation primitive now composes that filesystem policy
with the existing network filter, metadata filter and close-on-exec descriptor
preparation on the bound worker thread. In a disposable fixture, installed
kind ran after this composed preparation against the Haskell framed bridge and
a synthetic daemon. An image 404 stopped the broker, retained the in-flight
marker and led to five refused pulls; no container run or network connect was
observed. This negative fixture does not establish production root
disjointness, executable authentication, endpoint binding, worker settlement,
recovery, or real provider acceptance. The worker and filesystem source
SHA-256s were `52925cba705ce7be0f83a680458e56d2253dcab1dfaa9acc9273dfab6b7843c9`
and `94e7929030e1e9c4f9d64bae9115b2a3312050b9d850e49bbc06c9b5b6102e9b`.
The launcher source and binary, fixture, log, trace and request transcript are
`.build/phase1-kind-worker-launcher.hs`, `.build/phase1-kind-worker-launcher`,
`.build/phase1-kind-worker-composition.py`,
`.build/phase1-kind-worker-composition.log`,
`.build/phase1-kind-worker-composition.trace` and
`.build/phase1-kind-worker-composition-requests.json`, with SHA-256s respectively
`76c0c1c47554c9a6885be7433abb1d802be593d5adf9fca3a1d317fb733cd721`,
`2abc37b92b02208c685df7dff6e740c3ffc0ff59519c60232670751972196f95`,
`f8c788f61f504c6c23f3bce4af91b5caa0874bc01e89c44be058d00804c30295`,
`799d7dcd0f7f4b9ddf94d10c29c1ad1009b6d8cf6c641af6bbd708849ef8f737`,
`1997fb38bb7d4c85fee48daf6edead6663811992d6ca7796ee6507954a24adad` and
`3b471d931db2c83b12fd04ea1c641aa58625247533eb5596b0bb7333b3561df1`.
The two last-named trace and request files were accidentally overwritten by a
later fixture run. The request transcript was restored from a byte-identical
copy and its original hash verified. The original trace remains unavailable;
its hash above identifies the missing evidence. The later run is recorded
separately below.

An internal worker-root observer now opens fixed operation-relative scratch
and bridge directories and endpoint O_PATH descriptors beneath a held root. It
checks ownership, modes, identities and observed mount IDs, and delegates
scope, generation and operation-lease rechecks to its caller. A local fixture
passed invalid-operation, unavailable-root, changed-scratch and symlinked-FIFO
cases. The first fixture run returned unconfirmed while using a file rename
operation for a directory; the corrected directory-rename fixture passed. The
initial and corrected logs are `.build/phase1-kind-worker-roots-test.log` and
`.build/phase1-kind-worker-roots-test-fixed.log`, SHA-256 respectively
`3c885bf783470291a6144145e8d5bc01d0d2b44c4d905856238b74eeb0ab19ce` and
`a2e97fa70bf0ee864ec434700c11f473ccfc00c585a71d6e6a17729e11e40f2e`.
The worker-root and fixture source SHA-256s were respectively
`150b0d45d3589fe5deda0d3770f0a8c32a75acede50e581922fac79e9bd92479` and
`24fe89ea63a2e195ceac6bf4c3cdda7e35c57e169f652dd79be942059a663bce`.
At that revision the observer was not connected to a recovered operation. It
does not exclude concurrent writers, create endpoints, authenticate the
executable or settle workers. No live mount mutation was used to qualify its
mount checks.

The observer now has a recovered-operation wrapper that holds the selected
scope root and rechecks the existing operation lease and generation. A fixture
passed missing and foreign operation refusals and preserved a returned receipt
when the generation became unreadable during the callback. The result is
`.build/phase1-kind-scoped-roots-generation-test.log`, SHA-256
`1dd3066da03b1a66faf5059a9a0aef03272b0ed4902f113b6cf1f8dcf9914874`;
the worker-root and fixture source SHA-256s were respectively
`fd7ac04e283eb89e25ca5ef2ce9dc3e03630cc4a60698391010ad7d4b528a2d8` and
`d802e909829609f239dadbd8ee919ce6548b3b675dc2bffd7b65f183734f65f5`.
This is a read-only binding, not mutation admission or worker settlement.

The worker filesystem policy now checks an independently opened scratch
directory stream and refuses a foreign-owned, group/other-accessible or nonempty scratch root
before installing restrictions. Disposable worker cases passed for an empty
root and refused roots containing a file, directory, symlink or FIFO. A second
kind fixture placed its input configuration in the read-only bridge directory
and reached the same synthetic image-failure boundary with scratch initially
empty. This reduces the possible preexisting alias surface but does not exclude
external writers or prove bind-mount, root-generation or endpoint ownership.
The policy source, worker source and binary, outer fixture and result are
`src/Prodbox/Control/KindDockerFilesystem.hs`,
`.build/phase1-kind-filesystem-empty-worker.hs`,
`.build/phase1-kind-filesystem-empty-worker`,
`.build/phase1-kind-empty-scratch-probe.py` and
`.build/phase1-kind-empty-scratch-probe.log`, with SHA-256s respectively
`1fcc571ae957356074eb79f7187ef76973ff99ff2f41f463aa8e471f34431799`,
`d4c7d622c1067e8de67763466d55cd06574109750ad26146e504ee9c9f1a0670`,
`819cd14546c07085394f5261cd07989923e9c6efa5a78a284ac92d7478848164`,
`d67132a1b05d3719a54c9f1c0f5e54d92b9c6b44b826a0c98076dc5c80a40a9c` and
`b782863a4bbe9dd4cc2cc3c675ce16724c4729bdd79153f5f3833bbb6e251c04`.
The launcher binary, composition fixture, log, trace and request transcript
are `.build/phase1-kind-worker-launcher-empty`,
`.build/phase1-kind-empty-composition.py`,
`.build/phase1-kind-empty-composition.log`,
`.build/phase1-kind-empty-composition.trace` and
`.build/phase1-kind-empty-composition-requests.json`, with SHA-256s respectively
`ae65204cb6f4666f1d322c3b701c8119ba4ffdd75dd03fda2ef7840659e8006e`,
`8d2337970b30a38a0ad00dd2873d31bd198d7c11f0bdbe946ee1a57eb3cbd7e2`,
`6cfbee8f99a90ec00053c3f1f265cb217266c4b33137b0211406b91803728152`,
`828630adf4a2016bc1c815edfd86922a83e09b0e6c947b8881850c8b27521bb0` and
`3b471d931db2c83b12fd04ea1c641aa58625247533eb5596b0bb7333b3561df1`.

A disposable composition fixture subsequently ran installed kind under the
existing network filter with a test-only Haskell Docker client and broker
server using the actual framed client, lock marker, read gate and held session.
The session connected only to a synthetic local daemon. After its image 404,
the broker stopped with the in-flight marker retained; kind attempted five
pulls, each refused, and no container run was requested. The traced kind tree
attempted no network connect. This is a controlled negative fixture, not
production endpoint binding, filesystem confinement, daemon authentication,
worker recovery, or real kind/provider acceptance. The client and server
sources and binaries, composition source, log, trace and request transcript
are `.build/phase1-kind-framed-docker-client.hs`,
`.build/phase1-kind-framed-client`, `.build/phase1-kind-framed-broker-server.hs`,
`.build/phase1-kind-framed-server`, `.build/phase1-kind-framed-composition.py`,
`.build/phase1-kind-framed-composition.log`,
`.build/phase1-kind-framed-composition.trace` and
`.build/phase1-kind-framed-composition-requests.json`, with SHA-256s respectively
`f29f299ca0ef498fc5eee727859f38ea2d687a99ecb35a3f3e0ffef3e2e3c993`,
`c87e252b46c486cf6ae31fb57495f3bda4f449ad950c596be65a7f46dec0c7ce`,
`3b96d3845c4495e427df22aeaf64a2d553f9a53a4cd4497c739465816d5df670`,
`2ca585c0da42a98a07bad7fb0898f41218f8bd8e3ee1b934b3f9f07cb478cb3f`,
`898858e54d1b40c99cf142dd179f6487edf14a8d294644ef068401d1109c0af3`,
`e5084c063863bad65c7e2257721eacb709bd96bc3b2253b8def044d1c2a01c9e`,
`bbffce1c898bfb2129c840db132768cd103b3a3f5867d6b164816c49e37e933f` and
`3b471d931db2c83b12fd04ea1c641aa58625247533eb5596b0bb7333b3561df1`.

Disposable namespace probes on this host observed that mapping the operator
UID into a new user namespace failed, as did the default request to make mount
propagation private. With propagation unchanged, an unmapped user/mount/network
namespace process could open a 0600 FIFO for reading and writing under a 0700
operator-owned temporary directory. It received EACCES connecting to a
synthetic parent-namespace pathname Unix socket even when that socket was mode
0777 and its temporary parent was mode 0755; a non-namespaced control connected
successfully. These observations do not identify the enforcement mechanism or
prove denial for other sockets or hosts, so they do not replace the explicit
seccomp, filesystem, broker and settlement requirements. No Docker socket or
provider was contacted. The mapped and propagation-failure logs are
`.build/phase1-kind-userns-mapped-probe.log` and
`.build/phase1-kind-unmapped-userns-probe.log`, SHA-256 respectively
`6b50086233b9e3c0f8f5ac5e8094da06d7a05f1c3be0b88baf49578943392a94` and
`e0f84fd025357672c3a13678305b74a15bcfdd67f33512f0288b3e0649d0f68c`.
The FIFO-write, socket-denial and socket-baseline probe sources and logs are
`.build/phase1-kind-userns-fifo-write.py`,
`.build/phase1-kind-userns-fifo-write.log`,
`.build/phase1-kind-userns-unix-denial.py`,
`.build/phase1-kind-userns-unix-denial.log`,
`.build/phase1-kind-userns-unix-baseline.py` and
`.build/phase1-kind-userns-unix-baseline.log`, with SHA-256s respectively
`67e2351ab5b89f8463f08213dc1e482a9c7501d1465e4ac4f0ce90896e26709f`,
`48099fc73e266d843a7c64f0accbe3494c86057d330c1dcaec2e5a845741b188`,
`39fcb31b0a3ac8734cbcf0ccd7463535c615cb53b4a270cd15a265e952c2b950`,
`8a3fe6c0720de966fab851acefecb744659b6e9d1c71e34887bf4988a9a92d1d`,
`1eb670d7f12cf8568311f2a3d95d25deea4b6dbdf7535bfcf0e62aed997b93c6` and
`80a7739c3d963e23a424c76eb6062731142ec401e4603a60faaeb8ff91f13f96`.

A subsequent disposable fixture connected installed kind to the actual Haskell
read gate through a test-only FIFO bridge. The gate returned two synthetic read
successes, a synthetic image-read failure, then refused all later requests,
including five pull retries. No container run was requested. Fresh Unix sockets
were denied in each fake Docker child and the traced child tree attempted no
network connect. No Docker daemon or real image was used. The bridge itself is
not a production transport and the test does not establish filesystem
confinement, admission, concurrency across broker clients or worker settlement.
The server source and binary, bridge source, log, trace, request transcript and
reply transcript are `.build/phase1-kind-read-gate-server.hs`,
`.build/phase1-kind-read-gate-server`,
`.build/phase1-kind-read-gate-broker-v2.py`,
`.build/phase1-kind-read-gate-broker-v2.log`,
`.build/phase1-kind-read-gate-broker-v2.trace`,
`.build/phase1-kind-read-gate-broker-v2-requests.json` and
`.build/phase1-kind-read-gate-broker-v2-replies.json`, with SHA-256s respectively
`578e41f7df63e6a7f6c10104f5bf59bbf1b6d8b9d86175329686f972c7da2898`,
`9aadb9eb018384a28a95f4ed408975e051004b5c17000c7187786ac4d3bca4ef`,
`35593881f1440ee328b08f26559a8aabbbd69f80f3512909f1dc9de00206c171`,
`4a8b4d0e3d8aff85c530f2f12b228d2cc05fe4276eb0b3b17073f1c076ca4606`,
`f738fcf445ab7e79972e3be080064e4b2ca5b74ad044713c5d549e3ef0e5fd44`,
`50adca0460dad5de26277eff2ae2fd00c085f44257893a43b87042a82a1a9e56` and
`c114ea8786e0f05aaffd63960fb33d13d0d244434aff81a7a506baaade2d3e81`.

The internal worker-path preparation now records a new operation before creating
its exclusive operation directory, scratch and bridge directories, lock and FIFO
endpoints. It verifies the resulting roots through the existing descriptor-bound
observer. A focused local fixture passed both fresh preparation and recovery
binding, and confirmed that an existing directory is left untouched and that a
deliberately interrupted preparation remains visible and cannot be opened as a
complete endpoint. The integration test build and targeted HLint passed. The
preparation source, test source and focused test log have SHA-256 respectively
`34a01f59f3d54672fbd7615b00d2c635d6b717096c1e176f8e3e58054a0bc9ef`,
`82e46f7837e5017e31ae8609fd5867e2c6aefb73ac14b63a29c5dbe343416499` and
`a4b7f78ec8360a8d7ea59cc42218b6b216f9e65e9276cade304624c4bb83ba7d`
(`.build/phase1-kind-worker-prepare-adverse-test.log`). This does not establish
public lifecycle integration, settled-worker cleanup, real kind acceptance or
mutation evidence; those obligations remain open.

In particular, the prepared path set has no durable record of each created
entry's identity. The current recovered-roots observer requires all endpoints
to exist, so it cannot by itself resume cleanup after an interrupted partial
preparation or partial removal. Cleanup must first bind exact identities and
durable removal intent, independently settle the worker, and retain an
unconfirmed result when any required observation is missing. The existing
operation intent and directory name alone do not prove those conditions.

The composed disposable worker was also exercised with a synthetic successful
exact-image inspection. Installed kind then requested `docker network ls` for
the shared name `kind`; the read gate refused it, and kind stopped before any
container run. Repeating with `KIND_EXPERIMENTAL_DOCKER_NETWORK` set to the
fixture's deployment name changed that request to the scoped name; the gate
still refused it. The observed kind version warns that the override is
experimental. In both runs the daemon was a synthetic Unix socket, and the
traced worker tree made no network connect. These observations identify the
next network-adapter requirement; they do not establish network ownership,
duplicate handling, mutation admission, cleanup, or real kind acceptance.
The installed kind SHA-256 was
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
The default and scoped request transcripts are
`.build/phase1-kind-worker-successful-image-requests.json` and
`.build/phase1-kind-worker-scoped-network-requests.json`, with SHA-256s
`c7c96b8efd6f911e0823696900d4098220807cfdce9866bbecc27fe8214796cb` and
`f8fcc8aec611486cc9f000e175d31045cb6b01591fd0539f4f9683408be94070`.
The corresponding fixture sources have SHA-256s
`949785d2607c836a1b8681f42fdb2886b3244976b386f48303fe4a0bed375f62` and
`f6e5a9799949ee8a76093fcdb07fbbbd583361268f0f9526b420f91353f8e107`.

The internal held-session read gate now accepts that exact scoped network-list
request. It validates the complete bounded Docker response and rejects foreign
names, invalid IDs and multiple entries; an empty result remains only a point
observation. A local synthetic daemon fixture exercised empty, matching and
foreign responses, while a pure adverse fixture covered duplicate and invalid
entries. All 29 connected-Docker integration cases passed, as did the build
and targeted HLint. The Docker session source, gate source, fixture source and
`.build/phase1-kind-network-read-test-final.log` have SHA-256s respectively
`f8335f1c6445e339732bef9117fb64f372141a24adf1c41682eb99dc193488ee`,
`ad78a8d231269e71bed880004ff48d63b53de30beb3322af0024ef2d72f1679c`,
`ad573942bb48b2aae6eb07dc6279606d2fc506042bd1b9de4efc9696c99c3316` and
`d94408249eea2ac48bded253ff8d0738b3ce303df51091da72452b30a4bab467`.
The result is not an ownership assertion or mutation permit. Network
creation, duplicate recovery, exact cleanup, real acceptance and the public
lifecycle remain open.

The read gate also handles kind's exact built-in `bridge` MTU request over the
held Docker session. It checks the bridge name and driver, validates a present
decimal MTU, and rejects foreign requests or invalid values. All 30 connected
Docker integration cases, the integration build and targeted HLint passed.
In a separate composed worker fixture, a synthetic MTU of 1500 was reflected
in kind's following scoped network-create request, which the gate refused;
the fixture used a synthetic daemon and the traced worker made no network
connect. This does not authorize network creation or prove ownership, cleanup,
worker settlement or real kind acceptance. The tested Docker session, gate,
fixture and `.build/phase1-bridge-mtu-test.log` SHA-256s were respectively
`807b9a114bd38d1ca962e597791aaf5f8bf38bbd0ddcb00d522d96c4c519b802`,
`ad47edfecd810d040ad9528f1c4ca57e4e816d44783870082ae3b11d75211cfc`,
`2ccf977d4cb31c32f45562de0f044b615fb1a7fd28e0be311e80f05e11446090` and
`d6a85a8cd459a2da5ff52a6d9e98d5cb83118aa46832e26f67dbeb5e8f2d2078`.
The composed fixture source, request transcript and server binary have
SHA-256s `d8bb1d0c358bb64ecd507ac75f79730f9b164aee077ccc9968f614ef3684998c`,
`d5fc627f1121433d2c5d892883c0cd6adc2b99ed3a0957e46361974cf093f84b` and
`ed46ce93894f1e05cb95a613782caecfe1f2409f7a9481a514ddd1dfce16032d`.

An internal durable network proposal now binds the operation, deployment
generation and root identity, scoped network name, runtime socket and observed
daemon/socket identity to the proposed ULA /64 and MTU. The proposal rejects
invalid network addresses and retains an existing or incomplete record. A
focused fixture passed matching, changed-subnet conflict, invalid input,
corrupted record and symlink-refusal cases; the integration build and targeted
HLint passed. The source, fixture and
`.build/phase1-network-intent-test-final2.log` SHA-256s were respectively
`372cd0e9371c4ec8a5365dd2ed2db5750e9b035b1620401d856ab04a252aabc0`,
`b57ef4cdeac80f5ad632c3c0ead33dc5c734766567100137cfc847442f77a3d7` and
`fdb9785bf679329a5e9bbf42b098842ab592da41c8dce64e47bb230de64d5f2f`.
This local record neither reserves a subnet nor proves daemon authentication,
admission, worker settlement, network ownership or absence. Network effect,
recovery, exact cleanup, public lifecycle and real acceptance remain open.

The network proposal can now be reconstructed from the retained record under
the recovered operation lease, without supplying the original subnet or
daemon observation. It validates the candidate, compares the complete record
to the current scoped projection, and checks the held and named file identity.
A focused fixture passed missing-record, wrong-operation, matching recovery,
corrupt-record and symlink-refusal cases, including a fresh recovered lease;
the integration build and targeted HLint passed. The source, fixture and
`.build/phase1-network-recovery-test.log` SHA-256s were respectively
`6f85ad4a07ac784c02ca7afb9df69237adb046c093002fcee0793bc629a7a196`,
`dff773fb5d74af63b1f4df922f88418cbc04548689fbf3206fbccd16be6b4b7c` and
`2db84a01db0c2dd10c5177bc3ebaed8a975908911a49b6e9cc04634b2ab1801d`.
This recovers only the proposed local bytes: daemon read-back, worker
settlement, admitted effect, exact cleanup and real acceptance remain open.

A separate write-once network-attempt marker now binds to the full retained
proposal before a possible create submission. Its observation requires the
matching parent and can be repeated under a recovered operation lease. The
focused fixture passed missing-parent and missing-marker refusals, duplicate
write, mismatched proposal, corrupt parent and marker, conflicting marker,
symlink refusal and recovered-lease cases. The integration build and targeted
HLint passed. The source, fixture and
`.build/phase1-network-attempt-test-final.log` SHA-256s were respectively
`362af01e70e8e9894646d964ddc88b1f35a67d4e26a44143e0b86a1faf25dd7d`,
`dcad16db5b092bde1553bc93e0f3aa0d49a876ec73b9a6907deae34221f8b2ca` and
`fd56a9a2f3e043b6a1c21970c0198a71c7c93392dba4baf66c6bfc2e98b38b3d`.
The marker does not establish that a create happened, that no worker remains,
or that any network is absent or owned. Submission, provider read-back,
cleanup, public activation and real acceptance remain open.

The held Docker session can now inspect one full scoped network ID and retain
bounded driver, IPv6, subnet, option and label observations. It rejects a
foreign name or ID and treats 404 and other transport failures as errors, not
proof of absence. The synthetic connected-session fixture exercised matching
details, foreign values, invalid input and a 404; all 31 connected-Docker
cases, the integration build and targeted HLint passed. The session source,
fixture and `.build/phase1-network-details-test.log` SHA-256s were respectively
`d997cc29803591347ef87f21222156e0850ac6393808cc7a2ea445045c3a1334`,
`3e5ff601d2fac86c3db57257809908791f3ad2cd0b2f53a11dee134e3294384b` and
`2f3381930e25e453b85080ad43775999f3010c860d49778948f7d6ecaadfae20`.
This is a held-session configuration observation, not independent provider
proof, ownership, worker settlement, admission, or cleanup evidence.

The internal recovery observer now composes the recovered operation, durable
network proposal and attempt with a held Docker session. It checks the observed
daemon and socket against the recorded identity, samples the attempt around
scoped inventory and an optional exact-ID detail read, and retains a final
daemon observation and changed-record outcome. A synthetic fixture passed the
matching path and refused a changed daemon before network inventory; the
integration build and targeted HLint passed. The source, fixture and
`.build/phase1-network-reconnect-test.log` SHA-256s were respectively
`152d3ee20915a721df6e065e96e78a6bcd3a2fbdc4793b7f44eb08cf16755a52`,
`30e781157303cb21e87ab7086243d4b8957ca0d2229025694d2ba6cf484f6e3c` and
`39f3f568e88f173eaf90dae15979bd17747175ac65a58dfc9c2cb2f59f30779c`.
The sample is diagnostic: it neither authenticates the daemon nor proves
network ownership, absence, worker settlement, admission, cleanup or real
acceptance. These obligations and the public lifecycle remain open.

The public `control status` handler now reports the retained network recovery
sample for a matching operation, including local attempt states, scoped Docker
inventory, optional detail and daemon recheck. It explicitly leaves daemon
authentication, ownership, absence and settlement unverified. A public-binary
fixture passed missing proposal, missing attempt, recorded attempt and invalid
attempt cases against a synthetic Docker daemon. The executable and integration
build, targeted HLint, and this fixture passed; the status source, recovery
source, fixture, operator and `.build/phase1-network-public-status-test.log`
SHA-256s were respectively
`73c3b02aeaeb42e8de758aeadd3161b591f6e89490efbd701c615afd71ebed48`,
`152d3ee20915a721df6e065e96e78a6bcd3a2fbdc4793b7f44eb08cf16755a52`,
`12f8baa60a6cf7cfee7635cb920752dfc6a0b561746c191febd84453bcfbbd71`,
`2033c72d3422de4c2c359ac2444186ae5ef85902b2b6188da7aaf5d593f48224` and
`9ae8b926bfd69ddba761a6d07387e0b262f858292521f6888429263b83447af1`.
This public diagnostic neither creates a network nor meets the real-system
acceptance, cleanup, mutation, or cumulative gate obligations.

A held-session network-create primitive now constructs one bridge request from
the selected scope and retained proposal, including generation and operation
labels, IPv6 subnet and optional MTU. It reports a lost or ambiguous response
as unconfirmed and treats a reply as transport evidence only. A synthetic
socket fixture checked the request fields, refusal before sending when the
recheck fails, a bounded successful reply and a lost reply. The integration
build and targeted HLint passed. The Docker session source, intent source,
fixture and `.build/phase1-network-create-test.log` SHA-256s were respectively
`8fc958e6cf61900e9b2721090c263d794e57030923a6310fb82fd1f13fd8015f`,
`5f9aadf67d0a9626d9a9c9c6594e84a0790bc761215ac947bb8ab6d8fe4f1811`,
`0b033c70fa36e049b18b27fd03137f850b82956bc550c4d5457aa3b7e46c0220` and
`6e03833729a370398ff6749d62a8a15d1957ea78517947f3e1fbcf77252adf8f`.
This primitive is not publicly activated and does not itself enforce admission,
bind the attempt to the connection, establish daemon authentication, prevent
subnet overlap, settle a daemon worker, verify ownership, or perform cleanup.
Those requirements and real acceptance remain open.

The internal create callback now borrows the recovered operation and held
Docker session, matches the recorded daemon/socket observation, and writes and
rechecks a fresh attempt marker before entering the callback. An existing
marker refuses the callback. Two synthetic-session cases passed: a matching
create request retained its marker for both a reply and lost reply, and a
second callback was refused for an existing marker. The integration build and
targeted HLint passed. The composition source, fixture and
`.build/phase1-network-bound-attempt-test.log` SHA-256s were respectively
`bb60f91788930a8b8f5dac146b4f16a61a58d115f4ab3500527ef0a062d31b48`,
`587a4610a75f098b22b55d16c08e7554b7ccb2164eb982455a8a827d621362bb` and
`251fe1dce75a5a9a69f105f8f8faa6b9760d8473801ead85affd93d5eb346e6d`.
This still does not grant admission, authenticate the daemon, reserve the
subnet, settle the daemon worker, verify ownership or perform cleanup. The
public lifecycle and real-system acceptance remain open.

The network recovery sample and public status now compare a read network's
driver, IPv6 setting, ULA /64, MTU, masquerade setting and scope labels with
the retained proposal. Equivalent IPv6 spellings compare by address; invalid
addresses do not match. A synthetic fixture exercised a match and changed
labels, IPv6 setting, subnet and options, and the public status fixture passed.
The executable and integration build and targeted HLint passed. The intent,
recovery, status, fixture, operator and `.build/phase1-network-config-test.log`
SHA-256s were respectively
`c50758d4d95edd7dc50d5b76e33665263257b1b9976c804835211a3966b604e6`,
`7585617a982aeccab4b2191cb056dfe59c3f8d2bea876d3ebe000eb80336e09d`,
`fd34398f50853b6ede60b889bdcda71f6b8c904a228eed3c7c74386e2db6bea7`,
`af766b5009b3eec1e4297955f8ac5896f2aaf049bd2ebb9208ace34a67138e9b`,
`ca3326def6ccc094469022aafaed51804e5e101a3fb75c3eeebb1671c1e58cbd` and
`d3237cc169e3dde432c27e5f48dd60ca66c1183d6b74238007d93f3167dc079d`.
A matching configuration is not provenance, daemon authentication, worker
settlement, authorization to remove a network, or real acceptance evidence.

The held Docker session now has an exact-full-ID network removal primitive.
It refuses invalid IDs and failed prechecks, sends at most one request, and
retains 204, 404 and interrupted responses as distinct transport outcomes. A
synthetic socket fixture exercised those paths alongside the existing create
fixture; both focused cases, the integration build and targeted HLint passed.
The session source, fixture and `.build/phase1-network-remove-test-final.log`
SHA-256s were respectively
`7cadcbaf5f37684e7e587588725579f5575ca7062731c24600cde81cebec4a52`,
`94730d45ea15a74ff78e482304a9d466059f6b8c216a6eac0c4d8f4c1d90d2c5` and
`1f9ac4922523ea29d2078ebe678ced4d17c9f0769f55dfe5fffbf3899e944dc8`.
This primitive is not a cleanup workflow: it does not establish ownership,
admission, a durable cleanup attempt, daemon or worker settlement, or
independent absence. No real network was removed in this fixture. Those
obligations and Phase 1 acceptance remain open.

A write-once local removal record now binds the exact full network ID to the
retained create attempt before a possible deletion. The focused fixture passed
missing-parent and invalid-ID refusals, matching and conflicting IDs, duplicate
write, corrupt record, symlink refusal and damaged-parent cases. The
integration build and targeted HLint passed. The source, fixture and
`.build/phase1-network-removal-record-test.log` SHA-256s were respectively
`5cfc5eaaf886d2c966a13771aa739a330f1a80104856ddc24031eace83a421ed`,
`9c544b482d35caebe39cbbadd37cbaba67fa444990ab2fd3b846d4da04947821` and
`11cf7653c24b72efc6613d602682cc66116c6dc318f1a82cb5ab2580c70a8aa7`.
The record is not a deletion permit or evidence of ownership, worker
settlement or absence. Recovery without a supplied network ID, connected
cleanup composition, independent postconditions and real acceptance remain
open.

The exact network-removal target can now be recovered from its retained record
under the operation lease, without the caller supplying the ID. The public
status sample reports the local removal record before and after its Docker
observation. Focused fixtures passed missing, matching, invalid, replaced and
damaged-parent records, a recovered lease, and public reporting of the retained
ID. The executable and integration build, targeted HLint and three selected
cases passed. The intent, recovery, status, fixture, operator and
`.build/phase1-network-removal-recovery-test-final.log` SHA-256s were
respectively `e0e06fa3e097c9ee58ca22af1378df9aa0e87512e0f7e59530a74b8c0ef4b56e`,
`d56af37abd6d3cf55692e549fa18df90e57d2a269d06b146461be2e6cabc0d29`,
`064b61b7f0f8ba060309ff565bddc9b26f1e344534aaeb419c76eab7a256a9ed`,
`209bf043a5a467b33304d147ae1d4d3ab110a56a5df90c1cb29a19a34228d2fc`,
`fd5ad79288c5523b14d92c5c25bca5f8549cf01bef4bcee84b32b12598ceb56d` and
`f38586b0ca5789b7c130209e8bf91946d875782b2d174b1fd446e6e7f683f1ad`.
The recovered record does not prove network ownership, deletion, daemon
authentication or worker settlement. Connected cleanup, independent absence,
real acceptance and the full gate remain open.

An internal connected removal boundary now checks the retained operation and
daemon observation, refuses an existing removal marker, inspects the exact
network ID and compares its selected configuration before recording a new
removal marker and entering its callback. A synthetic socket fixture passed
matching and lost-reply removal, foreign-configuration refusal, and refusal of
a repeated callback with an existing marker. Three selected cases, the
integration build and targeted HLint passed. The composition source, fixture
and `.build/phase1-network-bound-removal-test-final.log` SHA-256s were
respectively `d2a2801eabd7641650ea37465b22dd17e3d7651866d36e9ea4ba851fffa9830e`,
`d12ca9b5d27e392c1f8d2b291b227eae637b7d9edafe5b89779d6464e9b84b49` and
`2d36aac315fdf392e18105f7044c28bfe804d6e5464df59b81265f4a38dfa8e6`.
Matching labels and configuration do not establish provenance or authorize
removal. Independent ownership, daemon authentication, admission, worker
settlement, post-delete absence and public lifecycle integration remain open;
the fixture did not remove a real network or satisfy phase acceptance.

For an exact network observed on the held session, recovery now also reads its
details through a separate Docker CLI connection, bracketing that read with
daemon/socket and scope observations. Public status reports agreement,
disagreement, change or an unobservable second read. A synthetic-daemon fixture
observed both clients return matching details, and the public-status fixture
passed; the first run's prior one-query assertion was updated to expect the
second query. The executable and integration build and targeted HLint passed.
The recovery source, status source, fixture, operator and
`.build/phase1-network-independent-test-final.log` SHA-256s were respectively
`3de67921156c546c343cb77072373de0d1b9190529d38ecf04156aa17280a99b`,
`e464dfe315452f98645647ada3765d8f71ed78ce090eb4b36030c4933ae838e4`,
`b4e22d139758dad6e4657d7f2ce579d57cfdb6fca3ed9968bb5f1e262e3f8ac9`,
`1d8331a860e5f81c9a1f4524a3cdbb87280a4db62c3a8cd79e5226b5fd98c89b` and
`60605df1a04b6c0e76b0f368bbf331ba051bf13b6622220f24c667165d1f2445`.
The two clients still depend on the same unauthenticated daemon. This is not
proof of ownership, absence, worker settlement, cleanup or real acceptance.

Network recovery now separately queries Docker inventory by the full ID in a
retained removal record and reports whether that query returned the exact ID,
an empty result, or an error. The parser refuses foreign names, wrong IDs and
ambiguous responses; empty is a point observation, not an absence proof. The
synthetic fixtures covered empty, matching, foreign and invalid ID cases and
public status reporting. Three selected cases, the operator and integration
build, and targeted HLint passed. The Docker session, recovery, status,
fixture, operator and `.build/phase1-network-id-observation-test.log` SHA-256s
were respectively
`afa582879f37a986de74e2e9ff15645ad47039f9008c373cbd278c291258260b`,
`7d783619adfeda92880e587ee96a6140e5258f181907b48ee17f6f863c102f70`,
`ee2243558ec00f1da2ae3d6a94b06d209871a963cc3e9df24d16b47e43785c6d`,
`1508ca93b2d822b82c95276810ce96aac3424fe3d42c70b50512cf08e0e043fd`,
`5a01ca5d90ea2f01bb933bc4ce2d8c3f8388819534df160bdc3fb66c6e9e08d5` and
`fddf608e978b7cbfd31398240d76da756d9e3625a812f53cc7d7d8bc3d3cb075`.
The query does not establish daemon authenticity, observer completeness,
worker settlement, independent absence, cleanup or phase acceptance.

For a retained network-removal target, recovery also performs an exact-ID
inventory query through a separate Docker CLI connection, bracketed by daemon
and scope observations. Public status reports the held-session and separate
client results independently. Synthetic fixtures observed a matching ID in
both queries and an empty result in both; two selected cases, the operator and
integration build, and targeted HLint passed. The recovery source, status
source, fixture, operator and `.build/phase1-network-id-second-client-test.log`
SHA-256s were respectively
`8662e54e82290c8eaad0621a5f429df64ba7d80535f006e19e7a80d68e4dbcfe`,
`3cb56b2f424fa3aa6b60898a1608751c0434b21a9eacd779a64e1dba47c7f4ee`,
`8ddea8ed03f08fce0e6854ed7b5bf5e52d0b39fc22db4083430e28559edb2b07`,
`0f0f9c26b0a11d7ac294e5b1e6bd11dc1c936239b1eebfe74c40345b1c97838f` and
`b8155cb09c232328bebfeef4955e0c63a02512b7dcc6a929e2dbd38626fbc067`.
Both clients depend on the same unauthenticated daemon. Empty observations do
not establish observer completeness, worker settlement, exact absence,
cleanup or phase acceptance.

Both removal-ID inventory paths now first inspect the built-in Docker bridge
and require their respective ID filter to return that exact bridge ID. A blind
control is reported separately, and neither path issues its target query in
that case. A synthetic fixture exercised a visible positive control and then
withheld it, checking both blind outcomes and the absence of target queries.
Three selected cases, the executable and integration build, and targeted
HLint passed. The Docker session, recovery, status, fixture, operator and
`.build/phase1-network-positive-control-test-final.log` SHA-256s were
respectively `1ba50a65fa960a0c835d2b8d82779a355d29b280c37fef78a15af7bd7e73c8fd`,
`400c03f1e33820239babaa5b8a3ac03e4954f67551c5b00a03958c5d6827c2b0`,
`ebcf47dbb12bfc3f849b4a26c303f0d7a80706e03ba8eb106e75858486909648`,
`d216ac19307249fa59e4fc96b136cfc1a7110c7de86d9636ad44e6658bce9a85`,
`ea3c68119f62dffbb1f3485ff066d53138f9439c6a8cae26c85338977c75a027` and
`685570cfb0f1e567f8b2a2e73d75f259b98fafc4d0b9a1ec2d2fe21e95bc9011`.
This control establishes only that the tested query could see the bridge at
that moment. It does not authenticate the daemon, settle workers, establish
exact absence or qualify cleanup or Phase 1 acceptance.

The bound network create and removal callbacks can now write separate,
write-once transport receipts tied to the retained operation, proposal, root,
daemon observation and exact removal target. Their returned transport outcome
and receipt-write result remain separate, including for lost replies. Recovery
and public status report these local receipts without treating them as resource
postconditions. Synthetic fixtures passed create and removal replies, lost
replies, duplicate writes, invalid results, corrupt and symlinked receipts, and
public reporting. Three selected cases, the executable and integration build,
and targeted HLint passed. The receipt, recovery, status, fixture, operator and
`.build/phase1-network-receipt-test-final.log` SHA-256s were respectively
`e06df95fc936b76225094a09f59d70dcd43d2bc3c53c268c16cb2f22896010af`,
`f4c2088cbd955c1641973a70d4feb768aad94ed8ed3907e9f7ccf319c900f8eb`,
`7fd38491eee497030f51648f03414707e5d1527a218adb938266ca3c8a3bd397`,
`f039f256e015210cab117588245f5b3665d44004397f61f6968284c77e423458`,
`321adb118305624d9095a72d1014cd0fbb7ed69cd42c5725c96c19da229d57a0` and
`bfb3e3912fe9d5d42770aa4685c2e2a4e78ed4f51cf8f06bd8ecb2724fb58b7d`.
Receipts do not authenticate the daemon, prove worker settlement, establish
ownership or absence, or complete cleanup or real acceptance.

The network effect boundaries now check for an existing receipt after writing a
new attempt marker and before entering the create or removal callback. A
synthetic fixture placed an invalid receipt before each new marker and
confirmed that neither callback ran, the receipt was preserved, and the
marker remained available for recovery. The existing create and removal
fixtures also passed; the integration build and targeted HLint passed. The
composition source, fixture and `.build/phase1-network-stale-receipt-test.log`
SHA-256s were respectively
`6e75384f3bac8955fa4a48b4609ba69a80a1f76d06bede8c5ed98dcb693f0fe1`,
`bfc50f14e6561c13842bb0cf05ab012a5945fef5b0358939065087ad711bf755` and
`e3f09f17009a20c712f47ab319e851e4756697606c4f6fa70b1df1041211c005`.
These checks do not provide admission, writer exclusion, daemon
authentication, settlement, ownership or cleanup proof. No real Docker
resource was created or removed, and Phase 1 remains open.

The connected removal boundary now refuses a damaged create receipt or a
successful create receipt naming a different target ID before inspecting the
proposed network. It also refuses a recorded not-started create outcome;
missing or unconfirmed outcomes remain uncertain and require independent
ownership and settlement before any effect. Synthetic fixtures passed matching
and unconfirmed paths, contradictory and corrupt receipt refusals, and stale
removal receipt refusal. Three selected cases, the integration build and
targeted HLint passed. The composition source, fixture and
`.build/phase1-network-receipt-target-test-final.log` SHA-256s were respectively
`25059e4554b19ee30cf4af2cb521505b3a9981bb21335c1b626077ff1a6aa046`,
`c14a32e0e8d58493d86adc5bca8c4b6c67f58126f19a771d84aac65d99da5029` and
`29e0f4790f2692dd2d4deb7203ca2ab43266ccb59fbbc67b9270ecb84938ce19`.
The fixtures did not perform real network mutation or prove ownership,
settlement, cleanup or Phase 1 acceptance.

The connected removal boundary now includes the original create-receipt
observation in its repeated stability check. A synthetic fixture changed that
receipt immediately before the removal request; the primitive reported that
the request did not start, preserved the removal marker, and the fixture saw
no delete request. Matching, unconfirmed and stale-receipt cases also passed.
Three selected cases, the integration build and targeted HLint passed. The
composition source, fixture and `.build/phase1-network-receipt-recheck-test.log`
SHA-256s were respectively
`92b9049435a51835e07868439d7dc44d27a6d77399d81b0f9f36cdea1c07f446`,
`389438cdda1550155cbda041219d92dce42a25f0844f0fea5ad70ed6c59bac51` and
`78a3024daa772e78c1ab341ac798340e49c5a445526e9963927e303c97195d21`.
Rechecks do not exclude changes between observations. Independent writer
exclusion, admission, ownership, settlement, cleanup and real acceptance
remain open.

The current canonical gate first stopped on Haskell style and ownership
checks. The shared descriptor and network-filter modules were moved from the
test namespace into `Prodbox.Subprocess`; flagged parser branches and receipt
rendering were corrected, and the affected files were formatted. A subsequent
gate reached the warning-as-error build and found one shadowed fixture
variable; that was corrected. The same all-components warning-as-error build
then passed, and 37 connected-Docker and public-status integration cases
passed. The Docker session, read gate, worker, descriptor, filter, status and
fixture source SHA-256s were respectively
`ca80dfdad0575a7fdcd8af73aa5a088001b612c7958f497eb856d79752fdc145`,
`63fd5e4d908b102a592347237645e728a544c1b2646a7c31e196efc92995851b`,
`31a205810715cd88f9e49cc529518295db7a137b6d79f8872ed68d6e78571650`,
`865d1d473741eddbcea41a661203c4575d1cd5bf6d100a098da2cb21ff363d75`,
`d9e552f0271a6d43af73e1873e8105a8406051afd303274c48f47a5938bd2a74`,
`9fffe5b3525789520bf62bec3c4563bc09c1051ed8b16a7b85b895bdeeff4e92` and
`afce0725c0c20a490c3f1b939a605da522025067d21db3a30c7c11690c213c40`.
The warning-build and selected-test logs are
`.build/phase1-gate-warning-build.log` and
`.build/phase1-gate-repairs-test-final.log`, SHA-256 respectively
`4723dfdae44b5a0c09806f2d1e3e77f0f07fe13b8bd27e77414e87eb07e12c7a` and
`8a39b8738e1b07918ab4787b9a4c4c81b1a387abb2a0688c17bc69e87d48b036`.
The earlier failed gate log originally at `.build/phase1-current-gate.log` was
overwritten by a later gate attempt and is no longer available under that
name. The other cited failed gate logs are `.build/phase1-gate-repaired.log`
and `.build/phase1-gate-repaired-final.log`; none is a passing canonical gate
or real Phase 1 acceptance.

The subsequent canonical `./.build/prodbox dev check` completed successfully.
Its gated unit suites reported 10,049, 27, 35 and 935 passing tests,
respectively. The operator SHA-256 was
`57bac616b4b8773c2b42bb42b78f6829b0c8738a18d5a4ad855b83f84fdda568`;
the complete `.build/phase1-gate-after-repairs.log` SHA-256 was
`dec05ab1ff5f1ead97cb3cccb8155c485ac0c75df993092d46754b9afecab615`.
This gate does not establish the real kind lifecycle, cleanup, independent
acceptance observations or mutation calibration required to close this phase.

`test list` now reports the three built-in local suite names from the same
typed registry used by their dispatcher, and explicitly states that legacy
topology-defined suites are separate. It does not enumerate or run the future
scenario catalog. The public binary fixture verified the list without a
repository, generated configuration or test root; two existing isolation and
host-guard cases also passed. The warning-as-error executable/unit build,
integration build, 316 parser checks, targeted HLint and documentation lint
passed. The operator, integration log and parser log SHA-256s were
`3edf403233d875130847ea59c06ce803e2cbd45688902d1eaa775c5626a62f2f`,
`3bc24c67b2884534248c2bf6825d4ef0b7e85a657205ac61774fa99c862bf314` and
`96cc0b88ca4ed49e8d00bd661532623227148d707f963c7584b48e29b0179073`.
The generated command reference and disposition were updated. This is not a
shared scenario/evidence runner or Phase 1 acceptance.
The existing named-unit/environment dispatch regression also passed after
the registry change, including its poisoned ambient credential and endpoint
settings. Its `.build/phase1-test-list-dispatch-regression.log` SHA-256 is
`8e78deaf88470bbd61899eb23a40c384684b964a22bd9f7fbb431166bf75c636`.
The subsequent full canonical gate passed lint but failed three CLI golden
comparisons because the new leaf had not been included in their expected
outputs; its `.build/phase1-test-list-gate.log` SHA-256 is
`cd4550cfee9ff8148f6dda38693cef56fcd747d30ea8296dbfc3236da5eb4229`.
After regenerating the three CLI goldens, all 320 parser and generated-output
checks passed in `.build/phase1-test-list-goldens-test.log` (SHA-256
`0e17b04b942808af14ad4f882af144e9ff4b70add9619746b245f197f7da8c19`).
The full canonical gate was rerun on the corrected source state and passed;
its main unit suite reported 10,051 passing tests and the additional gated
suites reported 27, 35 and 935. The
`.build/phase1-test-list-gate-final.log` SHA-256 is
`f96887e100ab82c8d3468b0dbb66dbae010bbaf74b4742b7407257e8e56ed2c0`.

The same operator was also checked with read-only local status probes. The
selected Docker socket's independent inventory stayed empty, a separate
marker remained unchanged, and a non-socket selection was refused. Separately,
CPU affinity, host memory and filesystem totals matched independent host
observations, and an ambient capacity override was refused. The reviewed logs
`.build/phase1-test-list-status-regression-reviewed.log` and
`.build/phase1-test-list-capacity-live-reviewed.log` have SHA-256s
`28cfc1f4958ac25138b71c2c1b9b508618e77c38ed72ef57890cd12c1e2f2d06` and
`547de7c8f8e3cdbd5691254898f91f63eea10cf0ee345277d708bbb834bb9f5c`.
Initial attempts used stale fixture expectations, retained in
`.build/phase1-test-list-status-regression.log`,
`.build/phase1-test-list-status-regression-final.log` and
`.build/phase1-test-list-capacity-live.log`. These read-only observations do
not prove kind recreation, policy enforcement or workload capacity.

A transient single-network membership projection passed seven controlled
network cases, but an installed-kind probe with one synthetic scoped network
showed that kind did not request membership inspection: it proceeded to node
preparation and its container request was refused by the read-only broker.
The unused projection was removed; the existing gate continues to refuse
unrecognized or duplicate-network inspection. This probe used a synthetic
Unix-socket daemon, a disposable confined worker, and no real Docker resource.
It does not establish a real cluster, ownership or cleanup. The fixture,
reviewed log, request transcript and trace SHA-256s were respectively
`e283cb31cb2a1d940697ca9eac1a07c1c5d3b2f36b470403378e1d06259ec3aa`,
`2c90f48043719e7c3ee138e1e21671f2b96130168babf89627fb6268a0f4ce32`,
`975647a5494b1c8547f65e4d26ebb0acb854328235d15d8b208d55309e026cf4` and
`69cc73295a2baf93cb131377e12d3dcaf06486c384e8619ecb1341c8c01c6712`.
The artifacts are `.build/phase1-kind-members-provider.py`,
`.build/phase1-kind-members-provider-reviewed.log`,
`.build/phase1-kind-members-provider-requests.json` and
`.build/phase1-kind-members-provider.trace`. The broker was built from the
transient source, and its new membership path was not exercised. Actual node
mutation admission, settlement and cleanup remain open.
After removal, the three affected source files matched their earlier tested
SHA-256s byte for byte. The executable/integration warning-as-error build and
six selected network cases passed. The rebuilt operator and
`.build/phase1-kind-members-removed-test.log` SHA-256s were respectively
`5e3e16cdb8af233128feaddb71ce23481b1950ce365e1e25e5fd26f33bc19218` and
`f7736375932d95f3bf40ae82b6155337158c98caaa3b6daa438ee7db0e40a1cb`.

The installed kind v0.32.0 was also driven with the actual JSON emitted by
public `control plan` for an isolated test configuration. A fake Docker
executable recorded the requested control-plane run: it contained the exact
selected test root mount, scoped network, pinned image, API port and both
publication mappings. The fake returned a duplicate-network removal failure;
kind continued to the node request, which the fake refused. The trace contained
no network connect calls. This fixture did not contact Docker or create a
cluster; it demonstrates why the supported adapter must constrain the kind
worker and cannot rely on kind stopping after a failed duplicate removal.
The fixture, log, request transcript and trace SHA-256s were respectively
`1dd6aab85bf7998da39e68864c5a94a5b2502fc6f45054d52eee13cbb6108d76`,
`119ac15ef125c1343d0580e87e279db0e025ae3b163399bd14337698a211e31b`,
`c279924daa57b98f5774e6f17f16fab146d8e54a19572b4c051986eb0c7e8301` and
`f9140835134123ce7c221b80b8eab6434a79d06a19ce1a2b22daeaac78222100`.
Their paths use the `.build/phase1-kind-public-plan-run-shape` prefix. This is
not real-provider acceptance, node admission, settlement or cleanup proof.

The kind plan now supplies a fail-closed predicate for the exact node-run argv
observed from the pinned kind v0.32.0 tool digest. It derives the node name,
network, retained-root mount and publication mappings from that same plan and
requires the supplied local image ID. It rejects an unknown tool digest, a
noncanonical image ID, an ambiguous colon-bearing host root, or any different
argument. Controlled IPv4 and IPv6 fixtures drove the installed kind binary
with public plan JSON modified only to use the synthetic local image ID; the
predicate matched both captured node requests and rejected removal of every
individual argument. Unit cases also refused foreign mounts, a changed image,
an altered network flag and an extra argument. The executable/unit
warning-as-error build, three selected unit cases, targeted formatting and
HLint passed. The plan source, unit source, operator and selected-unit log
SHA-256s were respectively
`10007fb3cc42a7394ac441d0c16828e6ade5a1fa0cb59945b20d49ed5dfd361a`,
`5424226fa722c2e921e533854e149921ee2dce2b4a93a73aca5f6e0a2a86ceae`,
`689a918b58c59f666c173b5590abc42c5ea8c1180a3add0f61f2fe0b4f1ad0a5` and
`91e52db075ddcc41300026c6fb03c45072e012a771908d7661dc54fd2403a881`.
Captured requests are `.build/phase1-kind-node-local-requests.jsonl` and
`.build/phase1-kind-node-local-ipv6-requests.jsonl` with SHA-256s
`7d937b47a9c863a516407efa8bb34f1199e5a8d25d1e19f5e3342abfbf5c4d2c` and
`04f306f6af1e8ff71becbfc379c97f7d1fe014d26e60f670cb8c2b18cf5e60b9`.
This predicate is not connected to the broker and does not authenticate the
tool, authorize an effect, settle a worker, or verify a real container. Other
provider versions and legitimate request shapes remain unsupported; the
public kind lifecycle and Phase 1 acceptance remain open.

The kind plan can now project a matched node argv into a candidate Docker
create body. It requires canonical image and network IDs, valid generation and
operation IDs, and the pinned observed request shape; the body uses the full
network ID and adds generation and operation labels. A comparison against the
captured synthetic-socket Docker CLI body matched the tested hostname, image,
environment, exposed ports, mounts, bindings and runtime fields. The comparison
explicitly accounted for the additional labels and the ID in place of the
network name. It did not verify omitted Docker defaults, whether the selected
daemon accepts the ID at creation, resource ownership, or any real effect.
The warning-as-error executable/unit build, three selected unit cases,
targeted formatting and HLint passed.

The plan source, unit fixture, operator, unit log, candidate body and
comparison log SHA-256s were respectively
`5e22f6b36ed5b40b10da27de286b48edefd005211a8330f79c4263ec7ed5aa68`,
`e4f9a84f83b9418b489ce6e7717ac8cda9326aba07802460247cdc0915690698`,
`a9bff7b0379fe779cf6859ab25b385389a6d86143f8a3dac64ef161126ea2864`,
`6c71859cc7c36fe4f31ec5479d0f8c7d909bfc94ba444a216e2e7a93c370d908`,
`ae44d53ac95005f11d73408f104cf6ec694ea7157c1bf12b9a73703f6fc6ea03` and
`a02fa1c248389015660508b6c07711c14800af5e722df5730947b9b70588c87d`.
The final three artifacts use the `.build/phase1-kind-node-create-body` prefix.
This is a pure projection, not admission, a broker route, a provider call or
Phase 1 acceptance; the last full canonical gate predates this source change.
That earlier candidate projected an anonymous `/var` volume and provided no
way to register or clean it up after an interrupted create.

The candidate now derives a deterministic `/var` volume name from the scoped
cluster, generation and operation and uses an explicit named-volume bind.
The create body's `Volumes` map is empty. A separate installed-Docker-CLI
capture against a synthetic socket produced the same named bind and empty
map; a comparison matched the tested projected fields, accounting separately
for operation labels and network-ID selection. Docker may create a missing
named volume implicitly, so this is not authorization to submit the body.
Durable volume intent, pre-creation, ownership read-back, node/volume cleanup
and real daemon behavior remain unimplemented and must be proven together.

The plan source, unit fixture, operator, selected-unit log, projected body
and comparison log SHA-256s were respectively
`a7176f4ff585b8cd5754da95e3f1a65843b87516f420efaae1c640d6ded5c234`,
`4e7192fc910bf22d60b831c849a3ee536b9985f69ba19dc4ae750761019aa444`,
`384b8c708f895ebbcb6de3f8032c366756b2fa50fc363c7f7d711050e32eeb99`,
`e68bf955e206dd1b186e09651633f8e7206ce01cc675ebf030c11c3392c1897f`,
`b3f830e28ae2f56904f458eb257922c70b5722aceaf8e0fe92391b37af02066a` and
`1b99d696940cec24232b1b9e1c838422b15029d6134d8d8d7210e3ebf8c43134`.
The last three use the `.build/phase1-kind-node-named-var` prefix. The
synthetic CLI fixture, request transcript and connection trace SHA-256s were
`1d1a4d03abbcdc35af8897344bfa5c01fcb879c8aa834a837ff8ef3cb7ca2d3d`,
`f82e9884ac36df90a085136dd938a9a95cec2ca157194c3880d143e9de4e8f7c` and
`75b4730cb0a4e2344405b824832401454be5722022f02fe0bf825d735780f5a2`.
Their paths use the `.build/phase1-docker-node-named-volume` prefix. The
warning-as-error executable/unit build, three selected unit cases, targeted
formatting and HLint passed. No real Docker resource was created or removed;
the last full canonical gate predates this source change.

For a matching parent operation, public `control status` now reacquires the
operation lease and reads the deterministic candidate node `/var` volume on
the selected Docker connection. The expected name and labels come from the
kind plan. A 404 remains a daemon response, matching configuration remains a
non-provenance observation, and conflicting or unobservable results remain
distinct. The operation and peer are rechecked around the read. There is no
volume-create intent yet, so this candidate read does not establish that a
volume was created or that a worker settled.

Controlled fixtures covered a matching response, 404, foreign name, missing
labels, foreign driver and nonempty driver options. The public binary reported
the matching and 404 cases; after the fixture changed the operation record
during a matching read, it reported the result as changed or unobservable.
An independent read-only probe against the explicit local Docker socket
observed the 404 and compared separate Docker list/inspect results before and
after. Its local root and intent were fixture setup, not a lifecycle journey;
no Docker mutation was issued. The executable/integration warning-as-error
build, targeted formatting and HLint passed. A 39-case connected-Docker and
public-status regression ran before the final fixture-only adverse assertions;
the final race fixture passed separately. An initial build found an ambiguous
label-map type, which was corrected.

The plan, Docker reader, status, final fixture, operator, final race test,
earlier 39-case regression and real-socket probe log SHA-256s were respectively
`f7cb0cc10b2a22d02650c09d35398ebfcc8937a62edd559027eb53aadc5f2e82`,
`3141415947e84a0a5ab0280e8a57dba68a0026bb6635e894fed9c69696a850ed`,
`00d5ecb1c91436886c42b3265671643dafa888d26d5178a1344e774826bf052e`,
`13f1328815765b44197209816d5c0a77e3755d000ca33cc61a675f58a35810af`,
`45140d7c1d7559f715de695dcb6f26519e7fab8e5a484930f13e81620590bf1e`,
`84e0ca09023740e7977c4cdce46c34a267ccf406b5698c18aaa332e836ae9b57`,
`e9b0b4019e73ffb9d9b6e6ae1c7fb2e20efe465f6ab4a3800bd9795031201a24` and
`db046ec6f7b2cd0530e3654b0baa5491bce406a5bda17706b710a84ff90af66b`.
The logs use `.build/phase1-node-var-status` with `-race-test.log`,
`-connected-tests.log` and `-live.log` suffixes. The real probe and its
fixture-only intent preparer are `.build/phase1-node-var-status-live.py` and
`.build/phase1-node-var-status-prepare.hs`, SHA-256 respectively
`6aa8327d639c699830d7dfb751bc3f374b6c42c449cd7577776551087a435e03` and
`151fc19f88bf13499480fa91d32ab2741606d6d49fb470873ee09bb5a458291c`.
No volume was created or removed, and the earlier full canonical gate predates
these source changes. Volume admission, exact recovery and cleanup, real kind
recreation and Phase 1 acceptance remain open.

The scoped node-volume plan now also constructs a local-driver create proposal
with the deterministic name, generation and operation labels, and explicitly
empty driver options. Invalid generation or operation identifiers are refused.
This pure projection grants no admission and does not persist intent or send a
provider request. An installed Docker CLI was run against a disposable synthetic
Unix socket: its captured create request matched the proposal's name, driver and
all labels; the CLI omitted `DriverOpts` where the proposal supplies `{}`. The
fixture's connect trace was restricted to its own socket. It did not establish
provider behavior or create a real resource. The warning-as-error executable and
unit build, three focused kind-plan tests, targeted formatting and HLint passed.
The two initial standalone probe compilations failed due to fixture source errors
and the corrected probe passed. Evidence is under `.build/phase1-docker-node-volume-wire*`
and `.build/phase1-kind-node-volume-body*`; the build log is
`.build/phase1-kind-node-volume-body-build.log`. Source, test, executable,
synthetic fixture and probe SHA-256 values respectively are
`335fab37524cc5a3e25c5bc3b512a92a24435abc3d3532a51bbf9dd95ae278fe`,
`2de514a6f904e1a3ea6f7484f0a314e2d8e658b1d17a7833fb1b089fe9190a9a`,
`a881d5058aca72781e5b9449ee6727766d13e42cb25fd3b950b3b770ac9b9e4a`,
`2c7adc583482822495b736924f8eee55a584fb3e0a284e5e5126ce9dd909ff3c` and
`f8ef67693707f26c1262640ad0a38b6d21c0522c6c76ae812deb59b541b6c88e`.
The earlier full gate predates this change; volume intent, recovery, exact cleanup,
real acceptance and Phase 1 completion remain open.

A node `/var` volume proposal can now be recorded exclusively under the
selected operation lease and read back with root, generation, socket and daemon
identity bindings. It is synchronized to disk and refuses unsafe, malformed,
conflicting or changed records. `control status` compares that proposal while
holding its recovered operation and connected daemon peer, and distinguishes a
missing or conflicting record from a match. Neither the proposal nor matching
labels prove an admitted effect, ownership or worker settlement. The writer is
not yet connected to a public lifecycle operation, and no create, retry or
cleanup is admitted by this work.

The warning-as-error executable, unit and integration build passed; the
record-focused unit case and public status synthetic-daemon case passed,
including duplicate-key and symlink refusal, a different daemon binding, and a
parent-record change during observation. Targeted formatting and HLint passed.
The public test created only local test records against a disposable socket; no
real Docker resource was created or removed. The initial build was interrupted
to apply a HLint suggestion, and the first formatting check found that change
needed formatting; both were corrected. Logs use the
`.build/phase1-node-volume-intent` prefix. The tested KindPlan, intent, status,
unit and integration sources and retained operator SHA-256s are respectively
`d3b758568b055d79c3e5584abeb616733da25556e8642565c840eef3c01ed7f2`,
`6f32e9e53cf3cb45994989fe0fb05fa09eb2f7e80edabba0ef64a0bcd248cb8a`,
`902c1540ad74b3b842b933257fffb81b51bf529113abd46d2a4a41862d6015b2`,
`10458bb6b7b6c648cb9a61712ca01281c68be0646346c3d9decf408c6944bd42`,
`db2d37ff3ec214186b44b9f6ceec58389f5d68771e3d964f50807cdb5174798b` and
`3c92218661e017359fa991480aab5aab23b418d03442d9ade97c35eaf19e03bd`.
The earlier full gate predates this change. Admission, transport, exact recovery
and cleanup, real kind acceptance and Phase 1 completion remain open.

The node-volume proposal now has a distinct durable attempt marker. The marker
requires a matching proposal and is written exclusively, synchronized and read
back under the recovered operation and stable peer checks. Public status reports
missing, matching, conflicting, invalid and unobservable attempts separately
from the candidate volume and proposal. A matching marker is not proof that any
request was sent or settled. The recording primitives remain unconnected to a
public create path; no volume-create or cleanup effect is admitted.

The warning-as-error executable, unit and integration build passed, followed by
the focused record test and public status synthetic-daemon test. The record test
checks missing parent, failed stability, repeat attempt, daemon mismatch,
duplicate keys and a symlink; the public test checks missing and matching attempt
states and parent-record tampering. No real Docker resource was created or
removed. Formatting and HLint passed after an initial HLint suggestion was
corrected. Logs use `.build/phase1-node-volume-attempt` prefix. The intent,
status, unit and integration sources and retained operator SHA-256s respectively
are `47e9e0220e1e99ce2b7c28e4844512fad1ff3b198e3314d1a544fac51e01210f`,
`7d97a9d2aeb44d09e6a53fbd23895f5a14205b229ac8842ab1f26c17eada5893`,
`279accdd42d405b8ecfc6f8a33a5fe9886f6f08bfdf16c70bf1be435b07443de`,
`9a90fcb7d64555f1ec9acc0f2b367ef72ab3ba7b910902513416b66ec0c9c147` and
`482d0ff7da8ac66f1b81a4980663cc4988f6d40ef30a1ad3c33a1e19b0fa8f5c`.
The full gate predates this change. Transport, worker settlement, exact recovery
and cleanup, real kind acceptance and Phase 1 completion remain open.

The held Docker session now has a bounded node-volume create transport whose
body is derived from the selected plan, generation and operation. Invalid inputs
or a failed precheck refuse before sending; transport failure, malformed or
ambiguous replies, and a changed postcheck remain unconfirmed. A response and a
matching configuration are transport observations, not ownership or settlement.
This transport has no public caller and does not itself establish admission,
authenticate the daemon, persist a prior attempt, settle workers or clean up.

The warning-as-error executable/integration build, the focused synthetic-socket
create case and all 39 connected-Docker regression cases passed; formatting and
HLint passed. The case checks the exact request, refusal before sending, a
malformed duplicate-key reply, a dropped connection and a changed postcheck. The
initial test build failed because fixture literals lacked explicit JSON-key and
byte-string conversion; that was corrected. No real Docker resource was created
or removed. Logs use the `.build/phase1-node-volume-create` prefix. The
transport source, integration source and retained operator SHA-256s are
`60b1bb5bebe482470a7d7b7f01f1d5b438fbdbbc4e1c20197e4226b74fe4beda`,
`b39a2a418258698243fa269ad3398f49d5271f98fdb910a95988a719204e93e6` and
`4a908cf7a485789d8033bfbc228fbfb9ad9b18ee77c8c041a77c3890159273cc`.
The earlier full gate predates this change. Admission, durable request outcome,
worker settlement, exact recovery and cleanup, real kind acceptance and Phase 1
completion remain open.

The node-volume request can now be composed under the recovered operation and
connected peer: a matching proposal must precede an exclusively written attempt,
a prior result refuses the callback, and the transport observation is retained
separately in a bound, synchronized result record. Public status reads that
record and distinguishes a daemon reply from an unconfirmed request. A result
or matching configuration does not prove admission, ownership, daemon
authentication, worker settlement or cleanup. This composition has no public
create caller; real provider effects remain unavailable.

The warning-as-error executable/integration build, 39 connected-Docker fixture
cases and the focused result-record adverse case passed; formatting and HLint
passed. The fixture exercised proposal, attempt, request, recorded result and
public status, and refused duplicate-key and symlinked result records. The first
library build failed on a shadowed result variable; it was corrected. Tests
used disposable local roots and synthetic sockets, not real Docker effects. Logs
use `.build/phase1-node-volume-operation` prefix. The intent, operation, status,
integration sources and retained operator SHA-256s are respectively
`5e3c63c835525019e8c53b8064d83a827b2c31351dea9b18ecf0f52c25f33a8e`,
`c6b89badfadd5f92866ea706093323c25e7466cbcf06ada2176d147fac675b3e`,
`09e036507a9fbf0e3fe7f144b443356ba7d32366cbeb3552e7745dcb7af02e96`,
`8cd38a5adb5936c0ffe021c7491b68f3179462fd88006230ee9bdf764896ac5f` and
`bcae250902742a7e6da5ef84f2f3a685fedf2f48f0e10f1f2976210e40698f08`.
The earlier full gate predates this change. Admission, worker settlement,
exact recovery and cleanup, real kind acceptance and Phase 1 completion remain
open.

The held Docker session now supports a bounded, non-forced removal request for
the volume name derived from the selected generation and operation. A separate
synchronized removal marker requires the matching create attempt and is visible
through public status. A 204 or 404 response, matching labels, or a marker do not
prove resource absence, ownership, admission or worker settlement. The marker
and transport are not yet connected to an authorized public cleanup operation;
independent ownership, remaining-user checks, removal outcome, settlement and
postcondition recovery remain necessary.

The warning-as-error executable/integration build and all 39 connected-Docker
fixture cases passed; formatting and HLint passed. The synthetic cases check the
exact DELETE path without force, 204/404, a lost response, a changed postcheck,
repeated markers, duplicate-key and symlink refusal, and status output. The
first integration build found a missing parenthesis in a test assertion; that
was corrected. No real Docker resource was removed. Logs use
`.build/phase1-node-volume-removal` prefix. The transport, intent, status,
integration sources and retained operator SHA-256s respectively are
`29d38d0d4e68f96f3a3698a5071c49ce865c1954f7011b5bbb5e851f3730a7db`,
`f809414799473000233cc722b27fa721c454233ffaccb368970d0064b8cde476`,
`f14165f6e5d53231af093f97b3a5774d031b64c0b2378bc3554dbe0db8b5b899`,
`a4c21d984f42803be90f3d08edc0d611686e4d5e77d4693d334b6e9e096a5da4` and
`1c3540006cec3b70a7253a6f3078542c779962f4a8ff4a9bcfcfdc732b3bdecc`.
The earlier full gate predates this change. Real kind acceptance, exact cleanup
and Phase 1 completion remain open.

A connected node-volume removal composition now checks the candidate's
configuration, requires a caller-supplied admission observation, writes the
removal marker exclusively, rechecks admission and the held operation/peer, and
retains the transport result in a separate synchronized record. Public status
reports the record without interpreting a reply as absence. The supplied
admission is an interface obligation, not an implemented ownership or
settlement proof; the composition has no public caller and cannot qualify real
cleanup. Independent daemon authentication, resource ownership, remaining-user
checks, bounded worker settlement and independent absence read-back remain open.

The warning-as-error executable/integration build and 39 connected-Docker
fixture cases passed, followed by a focused test with an added changing-admission
case. The synthetic fixture tested accepted and refused admissions, preserved a
marker when admission changed, and checked the resulting transport record and
public status. Its admission decisions were controlled test inputs, not real
ownership evidence; no real Docker resource was removed. Formatting and HLint
passed. The first build found an incomplete status pattern, which was corrected;
the final stability recheck was rebuilt. Logs use the
`.build/phase1-node-volume-cleanup` prefix. The intent, operation, status,
integration sources and retained operator SHA-256s respectively are
`410871ec1071b8398fdaf0cd50626714fd58e53c2a8d4e6c93335c8a2c6b5618`,
`366913dfeee470f8178df16795715cb8651792d455ae42ce5c7d372ed8303687`,
`83bbfd817f3a1d25f56f02364bfb5c5eb9480a15b2ebb9db607ebf7a2bef8f26`,
`1b598cb372b2549f03965457d846af44cad9c587a2ff92e5aebc9ca8d8f4a947` and
`325c2c8299d5bafb76095f06552abcdbabe2dfae950de831b5b9bd6b35fce929`.
The full gate predates this change, and Phase 1 acceptance remains open.

For a matching node-volume removal marker, public status now runs a second
Docker client against the selected socket. Under a recovered operation lease it
repeats unfiltered volume inventory and container-by-volume queries, validates
bounded names and full container IDs, and rechecks the recorded proposal,
removal marker and daemon identity. Changed, invalid and unavailable reads do
not become empty results. A repeated empty sample is a point observation on the
same daemon, not proof of absence, daemon authenticity, ownership or settlement.

The warning-as-error executable/integration build, all 40 connected-Docker
fixture cases, focused inventory-validation case, targeted formatting and HLint
passed. The first build found a shadowed status variable; it was corrected. A
separate read-only public status probe against the explicit local Docker socket
reported a 404 and repeated empty inventory for a disposable test identity;
separate Docker list, inspect and container queries agreed before and after.
An unrelated marker remained unchanged. Test code prepared and removed local
fixture records; no Docker volume or container was created or removed, so this
is not real lifecycle or cleanup acceptance. Logs use
`.build/phase1-node-volume-readback` prefix. The readback, status, integration
sources, retained operator, live probe and local fixture preparer SHA-256s are
respectively `cdf349897850e1f73fb24cd8bf56c35000564f94636732387f79a366e9f7df98`,
`3b180f9df5841794669cdf4f7cbd82c90fcb9926917f7447c94585427bab923a`,
`7f30e534c68132e84b09abe2f6988eee6b1e453b01f89a0f11ac833ab49a947f`,
`a347b276323f6f00dceb0249079daca03402d10b4623317abd6402e2de109842`,
`1e889031229907b62071cc03fbdddfbd99a2983d9c6c49c381bbca2fca7de88c` and
`8ba78d6be1a312582fae953bf313400c90a629cf5f52692fa65941623a5b4b7b`.
The full gate predates this change; public lifecycle, independent worker
settlement, exact cleanup and Phase 1 acceptance remain open.

The independent node-volume read-back now distinguishes a definite daemon or
inventory change from an unavailable daemon, failed record recheck or failed
inventory. An unavailable observation no longer becomes a change claim. The
warning-as-error executable/integration build, focused classification cases,
formatting and HLint passed. A repeat read-only public status probe against the
explicit local Docker socket passed for a disposable test identity; separate
list, inspect and container queries agreed. Local test records were prepared and
removed by the fixture; no real Docker volume or container was created or
removed. Logs use `.build/phase1-readback-classification` prefix. The readback
source, integration source and retained operator SHA-256s respectively are
`4235d805e3cba4e6e94a7151143bc1c566b3e2ff980585d03a8f50e20ab0be0a`,
`ec512f5418a602b07cfbe852bde4257db9aa9de5bc805509e315633765d4a96d` and
`90392336ef9ea34335c2ddf817535ae3457e17b5684f05bad3b99605f874169d`.
The full gate, public lifecycle, worker settlement, exact cleanup and Phase 1
acceptance remain open.

The public volume status read-back now has an integration adverse control in
which a disposable Docker socket changes the volume inventory between the two
client reads. The unchanged public status assertion reports the observation as
changed rather than an empty sample. The focused public-command case and all 40
connected-Docker fixture cases passed, as did the warning-as-error integration
build, formatting and HLint after correcting an initial HLint suggestion. A
separate synthetic Unix-socket probe reproduced the same public behavior. No
real Docker resource was touched; these are controlled fault tests, not real
kind or cleanup acceptance. Logs use `.build/phase1-readback-changing` prefix.
The integration source, retained operator and separate probe SHA-256s are
`5e3e579e293e4aa5d33afffab916ea736f2b0b6aaffa1e8d01aaf524ce63b395`,
`90392336ef9ea34335c2ddf817535ae3457e17b5684f05bad3b99605f874169d` and
`7f76f0b8ddcda861486738e2c39a6c11fdde87a82405b109a1df6145119ca9ca`.
The full gate and Phase 1 lifecycle and acceptance obligations remain open.

The held Docker session now has a bounded node-container create transport for
the exact pinned kind request shape. It derives the named container, network,
image, ports and mounts from the selected plan and validates the selected root
generation. Invalid requests and failed prechecks refuse before sending; lost,
malformed, duplicate-key or changed replies remain unconfirmed. A create reply
is not proof of ownership, readiness or worker settlement. This transport has
no public caller and does not establish admission, daemon authentication,
network/image/volume provenance, durable node intent, start, recovery or cleanup.
Docker may implicitly create its named `/var` volume; those prerequisites must
be met before any real container effect.

The warning-as-error executable/integration build, focused synthetic-socket
request case and all 40 connected-Docker regression cases passed, along with
formatting and HLint. The fixture checks the exact image, network and mounts,
foreign generation and argv refusal, lost reply, changed postcheck and malformed
response. No real Docker container or volume was created. Logs use
`.build/phase1-node-create-transport` prefix. The transport source, integration
source and retained operator SHA-256s are respectively
`93cab6ceb26988861ea8f4a6e8653681381fe9356fe6872ea1282fc004b1cec6`,
`85bb13407b30cc2c7beda6bb2ea4a9f55f8a4cb7b2823ec7a0c3cb091c6954c8` and
`2d8800424a79ddd19ee97e362d4698187ac9090538a1e6bb356cc438f472d91e`.
The full gate, public reconciliation, real kind acceptance and Phase 1 completion
remain open.

A durable node-create proposal now binds the selected root generation and inode,
operation, explicit socket and daemon identity, pinned kind request, local image
ID, full network ID, argv and generated create body. The exclusive bounded write
revalidates the proposal against the selected plan before touching the record,
syncs it and reads it back. Recovery rejects invalid, conflicting, changed or
unsafe records; public status checks the proposal against the connected daemon.
A proposal is not admission, daemon authentication, resource provenance, proof
of a request or worker settlement. There is no public create caller yet.

The warning-as-error executable/integration build, focused synthetic-daemon
record/recovery and public-status case, all 40 connected-Docker regressions,
formatting and HLint passed. The case checks wrong generation, different
network, cross-scope write refusal with no record created, duplicate keys and a
symlink. An initial implementation review found the cross-scope revalidation
was missing; it was fixed before the final checks. No real Docker resource was
created or removed. Logs use `.build/phase1-node-create-intent` prefix. The
intent, status, integration sources and retained operator SHA-256s respectively
are `63b1a8bc718f457b8634a68587eb6658c87379688af8ee7cb912b8b8fc573da8`,
`714b08cb3aac644dac500f8e659ee852ea6857feb7a9e07667419d7bed848db1`,
`6efa0ccac0249acedbc5fac2a53159ef34aaedf030e316834b47681bd31b1da1` and
`ad8d1d4c9fca82bf122e41e53700dfa6865124f7894c81e4703e1012bab87460`.
The full gate, effect admission, durable attempt/result, node start and removal,
worker settlement, public reconciliation and Phase 1 acceptance remain open.

A connected node-create composition now recovers the exact proposal, compares
its daemon binding, requires a caller-supplied admission observation, writes a
bounded exclusive attempt, sends the plan-derived request and retains its
transport outcome separately. The admission callback receives the recovered
proposal and is rechecked with the operation and peer. Public status reports
attempt and result states without treating a daemon reply as ownership or worker
settlement. An existing attempt does not submit again. The callback is an
unimplemented obligation on the future lifecycle owner, not ownership,
authentication or prerequisite evidence; this composition has no public caller.

The warning-as-error executable/integration build, all 40 connected-Docker
fixture cases, formatting and HLint passed. Controlled fixture cases exercised
the recorded attempt and response, denied admission, changed admission after the
marker, duplicate-key and symlinked result records, and public status. Fixture
admission decisions and the Docker socket were synthetic; no real Docker
container or volume was created. Logs use `.build/phase1-node-create-operation`
prefix. The intent, operation, status, integration sources and retained operator
SHA-256s respectively are
`061fce1708378e65e22c404ef5151ffa5d74806fed6f53c34959828f95afb52d`,
`ed5605956a2c8600ab2459b0d69bb3a4105e4be97f8e34dc7fef9214a35bc86b`,
`e47256e093e480b03d399e363ce793d098cb4acbb9e304a847f54bf7f6f7f6cd`,
`392590c1fe438adcfeb1a12eadafe505bf992802d3bc99f5ecc0c50b122cdf8b` and
`22425a16379980ef85271d0182f8f69c5bba549acb340a0046f6b38f96e7b747`.
The full gate, real admission and prerequisite proof, node start/removal,
worker settlement, public reconciliation and Phase 1 acceptance remain open.

The node adapter now has a bounded start transport for a full container ID and
a separate synchronized start-attempt marker bound to the exact recorded create
result and ID. Invalid IDs or failed prechecks refuse before sending; lost or
changed replies remain unconfirmed. Public status reports the start marker
without treating it as a started, owned or ready node. This is not yet composed
into a public lifecycle operation: admission, daemon authentication, container
provenance, a retained start result, worker settlement, independent readiness
and cleanup remain open.

The warning-as-error executable/integration build, focused synthetic case and
all 40 connected-Docker regressions passed, along with formatting and HLint.
The fixture covered missing create result, wrong ID, repeated marker,
duplicate-key and symlink refusal, exact start path, 204/304, a lost reply and
changed postcheck. The first formatting check required a second formatter pass.
No real Docker container or volume was created or started. Logs use
`.build/phase1-node-start` prefix. The transport, intent, status, integration
sources and retained operator SHA-256s respectively are
`a5c3aaa8bd78ca52f3bc35f13785aef96115a17c8dc804bbd58df60b693600c6`,
`0120e01e75a2d07faa3186703007e5bdeb3b906003b79e30c1335cf64019e991`,
`e3204333406ef76f2c75e838bf73b77642d942de80bd2a91323bcda048355354`,
`9125dc58d2dd458c5a92013b1970ea10b91e6ec3ffc97d813342944a091637b1` and
`f8981eda46e399a5096d176f94b03a636c082c6230460368f564a3434d0df406`.
The full gate, public reconciliation, exact cleanup and Phase 1 acceptance
remain open.

A connected node-start composition now requires the exact recorded create ID,
a matching daemon binding and a caller-supplied admission observation before
writing an exclusive start marker and sending the start request. The admission
observation receives the retained proposal and ID and is rechecked with the
operation and peer; a separate bounded, synchronized record retains the start
transport result. Public status reports that result without treating it as
readiness, ownership or settlement. The caller's admission is still an
unimplemented obligation, not proof of daemon authentication, provenance or
prerequisite settlement; there is no public caller.

The warning-as-error executable/integration build, focused synthetic case, all
40 connected-Docker regressions, formatting and HLint passed. The fixture covered
accepted and refused admission, admission changing after the marker, public
status, duplicate-key and symlinked result records. An initial build caught an
unused test binding and an initial format check required another pass; both were
corrected. No real Docker container was started. Logs use
`.build/phase1-node-start-operation` prefix. The intent, operation, status,
integration sources and retained operator SHA-256s respectively are
`4af0beff381f97d2cb499950712202fc7549b4313cf2598b7fdc11a2384012c1`,
`224585cbdbb3603315404aa0fdef2ada04a6c54a03fe277fa07796f8fb620880`,
`01ece952e3554e288fd7d9d3b89f90c9e073f43a94a9a5ed11351ebcd490e2c9`,
`3277cc17a93f0f45629932e8cdcfe9dc4d8a735d099dc4ef570d1695ee1b01d6` and
`7d3519cd814d422dc6a5778c7f845d6cdf4c0bd3dfb3aa805a49471ffc4f3cd2`.
The full gate, real admission, readiness, exact node cleanup, worker settlement,
public reconciliation and Phase 1 acceptance remain open.

For a recorded node-create result containing a full container ID, public status
now inspects that exact ID on the held Docker session and compares its name,
image, selected network, generation/operation labels and selected mounts with
the retained proposal. A match, including a running state, is only a daemon
observation; it does not establish ownership, admission or Kubernetes
readiness. A failed or missing inspection remains unobservable.

The warning-as-error executable/integration build, focused synthetic inspection
and public-status case, all 40 connected-Docker regressions, formatting and
HLint passed. Controls covered wrong image, network, generation, volume and
root, empty volume source, missing mount data and a 404. The first build exposed
ambiguous parser types, which were corrected. No real Docker container was
created, inspected or removed for this case. Logs use `.build/phase1-node-inspection`
prefix. The transport, status and integration sources and retained operator
SHA-256s respectively are
`e212c6ffed7d41e33a257d05dd0859f50c05a3ce90b3324154121103dd31696f`,
`23aba494ac5d2be443a67d5061cf963c3a77fb903eb498a269b0f1ed80dd4cec`,
`401067d7d0352aaa90bb7650978ef37e6d399902549d3892a1254b7dca62c6dc` and
`ffb39f1c80b011901c22a751c29b5d530e31ab0c85177ae8a50dce6525350803`.
The full gate, real admission, readiness, cleanup, public reconciliation and
Phase 1 acceptance remain open.

The internal node-start sequence now inspects the recorded container before
writing its start-attempt marker and repeats the inspection while holding that
marker. A mismatch or unobservable inspection refuses the start even when the
caller admits it. This is still partial composition: authentication, ownership,
prerequisite settlement, cleanup and public reconciliation remain open.

The warning-as-error executable/integration build, focused fixture case, all
40 connected-Docker regressions, formatting and HLint passed. The fixture
covered an initially conflicting image, an inspection changing after the
marker, no start request on refusal, and accepted start. An initial fixture
mistake was corrected before the passing run. No real container was started.
Logs use the `.build/phase1-node-start-inspection` prefix. Operation and test
source SHA-256s respectively are
`5d284940a58e91e3053c5ba359dfe9ad666869aa4bc764d474dec901a76d4bb0` and
`bb35ebb82fbd4cbeda0f9f59a3b0081f85e65850a884528cade8f82a80437716`.
This does not satisfy the full gate or Phase 1 acceptance.

Node inspection also refuses any additional Docker-reported mount beyond the
three expected mounts. The warning-as-error executable/integration build,
focused synthetic parser and start-refusal case, formatting and HLint passed;
the foreign bind control verifies that no attempt marker or start request is
issued. No real node was inspected, so the pinned image's real mount inventory
and the effect of Docker's tmpfs representation remain to be checked during
real acceptance. Logs use `.build/phase1-node-extra-mount` as a prefix. The
inspection and integration sources have SHA-256s respectively
`6f47c768214406b53e99fb0145baa573828baa1fa3d57e1893cca10b44909d66` and
`ec2ec219461df25f68271935c0442e4d4f1404b18c0a7057726cc5482f0b0c10`.
The inspection still does not verify every Docker security or port setting, and
public lifecycle, cleanup and Phase 1 acceptance remain open.

Node inspection compares Docker's configured port bindings and exposed-port
set with the recorded create projection, and refuses publish-all. Public status
names port conflicts. The warning-as-error executable/integration build,
focused synthetic parser and start case, formatting and HLint passed. Controls
covered an API binding on all addresses, an added port, publish-all and missing
host configuration; the start control refused the broadened API binding
without a marker or request. An intermediate test mixed a rebuilt operator with
an older fixture and was rerun after aligning the fixture. No real node or host
listener was checked. Logs use `.build/phase1-node-port-inspection` as a prefix.
The inspection, status and integration source SHA-256s respectively are
`cd6109a34cb1695dab0470d7ebd74bfad96d102cfc18b34bed2c848a0f0ec221`,
`55a4ab3e574e2ce3f1bc1512c37686e4712f37b7b186a7551633fefbba255411` and
`e7a7ce3d3c43f37b80725570c43402f0875abc6da71c192328b928b63b85f825`.
Effective listeners, real-provider representation, other security settings,
public lifecycle and Phase 1 acceptance remain open.

The reviewed mutation catalog now includes an M01 root-overlap fault, bound to
its exact source preimage and a single `context.rejects_root_alias` assertion.
The warning-as-error unit build, mutation-preparation test, exact test listing,
unmodified single-assertion reporter, formatting and HLint passed. The fixture
checks source-digest refusal and the prepared bytes; it does not compile or
execute a mutant. Logs use `.build/phase1-m01-reviewed` as a prefix. The
catalog, scope test and preparation test SHA-256s respectively are
`ff638f87a24a579757c4e0b36d69b627da28ecaeaafddc0e5aa25d8e83994783`,
`0d5ed0be6e2629465a4c403711d1db8394451560caed33844dfff5f37c2858eb` and
`1062bd999c4d08e541a310114cfcf13ea1616eacd32e393f474e8de0129efee3`.
The unit binary SHA-256 is
`11f3776e5ab5671d0c432699dcfc7566c8910a295d55e86bead1bcdee5ef5fb2`.
Isolation, compiled mutation execution, independently observed cleanup and
M01 acceptance remain open.

The mutation-worker preparation now composes the existing network, metadata,
filesystem and descriptor restrictions on a bound thread; an unbound caller is
refused before filters are installed. It is not connected to the public runner
and does not authorize a mutant. The warning-as-error library build, formatting
and HLint passed. A disposable combined-filter probe observed the expected
workspace/dependency access and denial of outside reads, chmod and fresh socket
creation; its positive control again showed that a pre-existing hard link can
read an outside synthetic marker. The outer process verified the marker and
dependency and removed its fixture. The first standalone probe build could not
see the local package; the final build selected it explicitly. Logs and probe
sources use `.build/phase1-mutation-worker-composition` as a prefix. The worker
source and probe log SHA-256s respectively are
`5113dc463bef1572c72aefe0b9e225c3abb665c1b66b4365c2b989b5d6695f4b` and
`40b88f496fd82d848d46d42cb60ff937ba1e26e7cf588c1ca5541c3190d8337c`.
Alias-free snapshot provenance, stream custody, build compatibility, process
settlement, mutation execution and Phase 1 acceptance remain open.

Mutation snapshot input preparation now binds one captured worktree inventory
to its source identity and turns admitted relative symlinks into regular-file
bytes from an admitted regular target. It refuses escaping, missing, malformed
or chained links and file/parent collisions. The warning-as-error unit build,
focused unit case, formatting and HLint passed. A separate read-only probe
captured 1,807 current inventory entries and checked that a checked-in link
resolved to its captured target bytes. An intermediate unit build was stopped
to include the collision control; the final build and probe passed. Logs use
`.build/phase1-mutation-snapshot` as a prefix. Snapshot, source recorder and
unit-test SHA-256s respectively are
`cf9a22fffb39c18ebde58452c0011a6e092f109f1945b8fe1abcce721eb61a53`,
`61dfdf0e43270ad0fa2481f3fc9204d2b2c08ee4cbc44eb03482375282f6d3e2` and
`2a4ea7036731086fea985a45ae19a7f9ab041dec5704fa3ca55e96d56fd4eedf`.
This does not create or authenticate a workspace, establish a simultaneous
worktree snapshot, bound the source capture itself, run a mutant, or satisfy
Phase 1 acceptance.

Mutation source capture now uses bounded Git output and an overall timeout,
limits the selected entry count and cumulative source bytes, and checks each
file against the remaining budget before reading it. The warning-as-error unit
build, two focused cases, 12 source-identity regressions, formatting and HLint
passed. Controls exercised entry, byte and Git-output limits; a separate probe
captured 1,807 current inputs under the configured limits. An intermediate
build was stopped after a style correction; the final build passed. Logs use
`.build/phase1-mutation-bounded-capture` as a prefix. Recorder, snapshot and
test source SHA-256s respectively are
`6d698b7640e95f6b39131fd9ba8dafb542c65601c9d40106f4d08e2aa8415ece`,
`7435e6ee408b018dd5ecb137fde6ec3c2465b3ee5562a0082180ef9c61e9b3af` and
`15cee6eb3d0ccb47ada5768e954e32ebecda53125cd0e861d727426d269c6827`.
These limits do not prove a simultaneous worktree snapshot, authenticated
workspace, descendant settlement, isolation or mutation execution. Phase 1
acceptance remains open.

Mutation snapshot inputs can now be written beneath a newly created operation
root using descriptor-relative, exclusive file creation. The writer verifies
individual file bytes, modes and link counts and preserves an incomplete root
for recovery. The warning-as-error unit build, focused creation/refusal cases,
formatting and HLint passed. An independent disposable fixture scanned 1,808
written regular files for single links, private modes and absence of symlinks,
checked a link-derived copy had a distinct inode, preserved an outside marker,
and removed its test directory. An initial unit build exposed a precedence
error in the test and was corrected. Logs and probe sources use
`.build/phase1-mutation-snapshot-write` as a prefix. Writer and test source
SHA-256s respectively are
`42cadeb6d1a041bbad68c565f6a5af7c4f90bc1a993a830e354a62d2c51262d8` and
`decc5201f7dedf7a35d6c1ecf1f1d77cafed66d80afbba3c0865e636c46ac585`.
The caller must authenticate the parent and independently verify the complete
inventory, prevent same-user interference, establish cleanup and settlement,
and enforce the remaining isolation before any mutant may run. Phase 1
acceptance remains open.

A separate read-only mutation snapshot observer now compares each directory's
exact entry set and each file's bytes, owner, mode, link count and descriptor
identity against the captured snapshot. The warning-as-error unit build,
focused positive and extra-file/changed-byte/symlink/hard-link controls,
formatting and HLint passed. A disposable full-inventory fixture observed 1,809
single-link regular files, checked a link-derived copy and unchanged outside
marker, and removed its test directory. The first build caught an unused import
and was corrected. Logs and probe sources use
`.build/phase1-mutation-snapshot-observe` as a prefix. Observer and test source
SHA-256s respectively are
`b44cc217619df734d9b1abab3dceaf09d998670900001ad81c296c7605fd30e9` and
`0f67ecafc0578abf586e025a1a940943cd067d18e798638eb309e0d8983e12c2`.
This point-in-time observation depends on the host `/proc/self/fd` view and
does not authenticate the parent, prevent later same-user changes, establish
worker settlement or cleanup, or authorize mutant execution. Phase 1 remains
open.

One reviewed mutation can now be applied to the captured snapshot inputs,
with the baseline source identity and separate patch and mutant digests. The
transformation preserves every other file and refuses an already-mutated,
stale, missing, linked or aliased target. The warning-as-error unit build,
two focused cases, formatting and HLint passed. A disposable full-snapshot
fixture checked that the M01 source changed, its test file stayed byte-identical,
the observer matched 1,809 single-link files, and an outside marker survived;
the outer process removed the fixture. No mutant was compiled or executed.
Logs and probe sources use `.build/phase1-mutation-snapshot-patch` as a prefix.
Snapshot and test source SHA-256s respectively are
`6acaf42a9baff4cc51fb777dbcc2fbb30981f5952885a59e00abd823dfccae04` and
`a34c9da16de0bd97bc6c662b311b6a12ea15ff7552be437cffc8d9baf9768ace`.
The snapshot's source identity refers to the unmodified baseline, not the
mutant; the separately recorded mutation binding identifies its changed bytes.
Workspace custody, isolation, build and test execution, independent cleanup,
and Phase 1 acceptance remain open.

The internal mutation workspace preparation now walks an explicit project
without following symlinks, creates a fresh operation under its private
`.build/mutation-workspaces` parent, observes the snapshot, and holds the root
while checking path identity around a callback. A returned value is retained
if the path changes afterward. The warning-as-error unit build, two focused
cases, formatting and HLint passed; controls covered an existing operation,
private-root and symlinked-project refusal, and parent replacement. A separate
disposable fixture prepared and observed 1,810 files, preserved an outside
marker and removed its fixture without executing the mutant. Logs and probe
sources use `.build/phase1-mutation-workspace` as a prefix. Workspace and test
source SHA-256s respectively are
`4ec0f0ca9f6eae1f21fccb4cab415abbe8851da62d9678f0d8d1567b3c589073` and
`69f107dcaff25bb56065863dc390b02d484e49e7bb988ffc699ecb857e2a6109`.
This does not isolate against same-user changes, authenticate build tools,
bound or settle the callback, provide supported cleanup, or authorize mutation
execution. Phase 1 and its public acceptance remain open.

Mutation workspace preparation now exclusively records and reads back a
non-secret intent before creating its operation directory. The record binds the
operation, baseline source identity and reviewed patch/mutant digests; its
identity and contents are rechecked around the held-root callback. The
warning-as-error unit build, two focused cases, formatting and HLint passed.
Controls covered existing, conflicting, tampered, symlinked and hard-linked
intents, plus refusal to adopt a pre-existing directory. A disposable full
fixture independently checked the M01 intent hashes and 1,811 single-link
files, preserved an outside marker and removed the fixture. Intermediate unit
builds were stopped to add the link controls; the final build and fixture
passed. Logs and probe sources use `.build/phase1-mutation-workspace-intent`
as a prefix. Intent, workspace and test source SHA-256s respectively are
`c73b7337292283b0e1509bf29e5d29058a30ed0c10424f9f7706a903fffd8a3a`,
`48cddd36f4aa58b99981b43da3ab6029d0d803634afc8054f86fcf17f6ee5f72` and
`5b0195728933e894591fb73af2ec8872ac662e5ec41fe8dbd0b12b222b47c0af`.
A matching intent does not prove original root ownership, worker settlement or
absence. Recovery, supported cleanup, isolation and mutation execution remain
open, as does Phase 1 acceptance.

A successful mutation snapshot write now returns the observed created root
device and inode. Workspace preparation records and reads back a separate birth
record binding that identity to the intent before invoking its callback, and
rechecks both records and the held root afterward. The warning-as-error unit
build, focused cases, formatting and HLint passed. Controls covered a wrong
inode, changed birth record and a foreign pre-existing directory with no birth
record. A disposable full fixture compared the birth record to an independent
filesystem stat, checked 1,811 single-link files and the outside marker, and
removed its fixture without executing a mutant. Logs and probes use
`.build/phase1-mutation-workspace-birth` as a prefix. Writer, record, workspace
and test source SHA-256s respectively are
`5de579c369c889663b3e83cf0a57c9868f1ab131b6e05ccbc3d028e1069aeec1`,
`b2a40377e899a0ab2eff4a04e9f24abda412bc88c53c69685310ecc5b56bdb45`,
`41ba311f43bd8696c2f0f1cc7b7a912b4b0ee06872f495df94cea855f8b154e8` and
`2e44044326597496bb5633223e85833a978b1b6b84f13ea77ef7628d7f2fa638`.
The record alone does not prevent inode reuse or same-user replacement and does
not prove worker settlement, cleanup, or mutation execution. Recovery and
Phase 1 acceptance remain open.

Mutation workspace recovery can now reopen an unchanged snapshot only when
its retained intent, birth identity and complete inventory match. A nonblocking
lease excludes cooperating operations on the same parent inode. The
warning-as-error unit build, focused tests, formatting and HLint passed.
Controls covered lease contention, changed source bytes, a wrong snapshot,
tampered birth and a foreign directory with no birth record. A disposable full
fixture prepared and recovered 1,811 files, independently checked the intent
and root identity, preserved an outside marker and removed its test directory.
No mutant was run. Logs and probe sources use
`.build/phase1-mutation-workspace-recovery` as a prefix. Workspace and test
source SHA-256s respectively are
`3fa54895227f5b8b94fe254104787487af7254140d3bbbfff392c2b7d81744be` and
`cf2b8c0b4ed3e728d033aff896d56e3a0b8150d1e6648450226abcd5f34ce474`.
This lease does not exclude noncooperating users, prove a previous worker has
settled, prevent inode reuse, or authorize cleanup or execution. Phase 1
acceptance remains open.

Mutation workspace recovery now reads and validates the retained birth identity
before opening the root. Missing, conflicting, invalid and unobservable birth
records remain distinct observations. The warning-as-error unit build, focused
case, formatting and HLint passed. Controls recovered the identity while the
root name was missing, refused a replacement root with identical file contents,
and resumed after the original root was restored. A disposable full fixture
prepared and recovered 1,811 files, independently checked the recorded inode,
preserved an outside marker and removed its fixture without running a mutant.
Logs and probe sources use `.build/phase1-mutation-birth-recovery` as a prefix.
Record, workspace and test source SHA-256s respectively are
`e655fdffa2bce0494b4105a843cae4e0ae8a0ae674ad25685d93f4eb406a9468`,
`a92ed2a020fc421f042b82963f1169b44899ff5ae47e6f37b1a7f8797edd2972` and
`87b41fd99257afc6f1dc735083666f11f5d9f0e27458fb0e119f4ddc6797c8db`.
The record does not establish resource absence, prevent inode reuse, prove
worker settlement or authorize cleanup. Mutation execution and Phase 1
acceptance remain open.

An exact unchanged mutation workspace can now record a durable retirement
request bound to its birth record. New and recovered callbacks refuse a
matching or conflicting retirement record; the request itself leaves the root
and earlier evidence intact. The warning-as-error unit build, focused test,
formatting and HLint passed. Controls covered a busy lease, repeat request,
conflicting record and refusal to restart. A disposable full fixture independently
checked the retirement-to-birth binding, retained 1,811 files and the outside
marker, then removed the fixture without running a mutant. Logs and probe
sources use `.build/phase1-mutation-workspace-retirement` as a prefix. Record,
workspace and test source SHA-256s respectively are
`5bcf44644c6c3918b75b9703dd0990c887e327db14f1e9079153b1743644b41a`,
`adffa066eaad626cecf038dd5c36a5642230c8296cf744fbcc348053277b2f76` and
`315158d7011c5ab7d12a668cad7edbdf6c217a7972b1a1ff38350e4f96f67624`.
The request does not prove worker settlement or remove anything. Exact cleanup,
noncooperating-process isolation, mutation execution and Phase 1 acceptance
remain open.

Mutation workspace admission now requires an explicit active marker bound to
the birth record. Retirement atomically renames that marker without replacement
and reads back the same inode under the retirement name. If both markers are
missing, recovery refuses rather than assuming the workspace is active. The
warning-as-error unit build, focused test, formatting and HLint passed; the test
removed a retirement marker and confirmed that neither recovery nor another
retirement request admitted work. A disposable full fixture checked the same
marker inode before and after transition, the retained birth and intent, 1,811
single-link files and an unchanged outside marker, then removed its fixture.
No mutant was run. Logs and probe sources use
`.build/phase1-mutation-admission-transition` as a prefix. Record, workspace
and test source SHA-256s respectively are
`57c87d6de66b178a13bd7fc05bdb66d7215b9d93bbcae9f70b934c74c20007c1`,
`eba86ce0417e965f7439476ef2be7a7a8ec20ba1d5db975b0c82fb7654e1df5d` and
`83a5783784681e2c2aaf29a5d468ed63823d17eb35fbb8f982303b7c743fdbd1`.
This supersedes the earlier fixture's retirement-record format. It does not
prevent same-user forgery or prove worker settlement, exact cleanup, mutation
execution or Phase 1 acceptance.

An unchanged retired mutation workspace can now be reopened for recovery
observation only when its intent, birth identity, snapshot and retirement
marker match and its active marker is absent. The warning-as-error unit build,
focused test, formatting and HLint passed. Controls covered active state, both
markers present, missing retirement, changed files and lease contention. A
disposable full fixture prepared, retired and reopened 1,811 files, checked
its retained records and outside marker, and removed the fixture without
running a mutant. Logs and probes use `.build/phase1-mutation-retiring-recovery`
as a prefix. Workspace and test source SHA-256s respectively are
`9ea9a1513ea49c4d80b91418b5538382e0af4aad845e5853fad7f053be9c4219` and
`f67d3371bbfd8f26c3e20637f6f4f168abf2cb0f8a2b064e6fa29c4a83b3982d`.
This observation does not prove worker settlement or authorize removal;
exact cleanup, mutation execution and Phase 1 acceptance remain open.

A deterministic managed-host key now binds the operation and snapshot birth
(including source, reviewed mutation and root identity). An internal wrapper
checks the exact submission against the existing host-retirement observer and
rechecks that observer after its callback. The warning-as-error unit build and
all 25 scenario evidence tests passed; the key tests cover changed bindings and
invalid input, and the wrapper refuses an invalid binding before touching host
handles. Formatting and HLint passed. Logs use
`.build/phase1-mutation-worker-settlement` as a prefix. Intent, observer and
test source SHA-256s respectively are
`c50ffd1e618af0fe94534ead4e347106a6cbfeaf1718a5d1d51b5e779a244421`,
`a894240ffed8f685730649341a6bdeedc39ca800f4950a1e230d08b8dddf48a7` and
`6f7b887ad7f0419c4f0cf0f117c52f64642b1d9d9a362e6b107b288d1e4a2515`.
The wrapper has not been exercised with a real host owner, and the managed
host controller does not yet launch mutation workers. This observation does
not establish all-worker coverage or authorize cleanup; mutation execution,
cleanup and Phase 1 acceptance remain open.

The read bridge now serves the pinned provider's exact security-options,
storage-driver and storage-status `docker info` formats using bounded reads on
the held daemon connection. Storage replies must contain the expected daemon
ID, an explicit driver-status field and bounded printable values; malformed or
changed observations fail closed. The framed protocol's argument limit was
raised from 32 to 64 while retaining its 16 KiB message limit, because the
observed node request contains 38 arguments. A duplex test verifies that a
38-argument unadmitted request reaches the gate and is refused, and a
65-argument request is rejected by the client.

An isolated fixture ran the installed kind provider through the framed client,
read gate and a synthetic Unix-socket daemon. It served the observed info
requests, then refused the 38-argument node request and settled the broker; the
trace saw no network connect from the kind process tree. The captured node
request also matched the separate plan-derived shape predicate. No real Docker
resource was changed. The warning-as-error executable/integration build,
37 connected-Docker cases, targeted formatting and HLint passed. An initial
fixture build failed on a shadowed variable and was corrected. Before the
framing change, the probe exposed the 32-argument limit and its server required
forced fixture cleanup; those failures remain in
`.build/phase1-kind-provider-info-build.log`,
`.build/phase1-kind-provider-info-probe.log` and
`.build/phase1-kind-provider-info-probe-debug2.log`.

The connected-info, read-gate, framing, integration-test, operator and
`.build/phase1-kind-provider-info-tests-reviewed.log` SHA-256s were respectively
`675463d762ca70b87352bbea35d474cd356c443c704c6238c729e96eb999474d`,
`a4ffe44cacca8fd9a5bfcffaee0ebd978dbbb1a58bd72e22bdb55b0648272165`,
`ef903ec8e493fa06219b2a755c39d41aaea6df37c69bf347d0635812ce7d11cc`,
`2c3a68f4aee4a409b8c920ffb251abdd2d91cdccfddfaad84e656362a2fec5b6`,
`b12d778af49cecb037a27a6e1be8834291224ca6b82187ea6d3707795b0a318d` and
`af0c028a900f61bcc7ded9fd75e29ae771d4dfd627b87ce531162bc2c3452bc9`.
The fixture, reviewed probe, transcript and trace SHA-256s were
`fdd7c8522a3ccfc1f41caba3911a1a6232f0b929830cb0f4440c0930fb018da7`,
`4845eb1b8c55706127c0cc23359fe0fbc21902f4cfe65f39195831b521485b8c`,
`4df2fd82baf97ef8e6010edefe9b7ee1de136187984547f63d8bbea0c139c015` and
`4a10bba0cacfec9844beb8ead9c55e21afe2dd18ff5286783873679f395f2631`.
These results do not authenticate or authorize the daemon, admit a container,
settle a real worker, establish real-provider behavior or close Phase 1. The
earlier canonical gate predates these source changes.
The same three bridge projections were also read from the explicit local
Docker socket and compared byte-for-byte with separate read-only Docker CLI
queries. The live probe source, binary and
`.build/phase1-kind-provider-info-live.log` SHA-256s were respectively
`514c9ff716e13fc74a7eba711c249e690e9d29d863005b6dfa3fd0f6dcbb3adb`,
`a9ac6d5029ecc1d86886fa8d4fa6f793a2500290defdc68c21b5e61ecebaf151` and
`4ca129f094aaefd7e07a5b10c0826a34e564ebfea3da4ea24be2746314711276`.
This is an info-read comparison against one daemon, not independent resource
absence, daemon authentication or lifecycle acceptance.

The installed Docker CLI 29.9.2 was driven with the previously captured kind
node argv against a disposable synthetic Unix-socket server advertising API
1.51. The captured create body contained the expected image, cluster and role
labels, retained-root and module mounts, scoped network, API/publication port
bindings, privilege and runtime flags. With the snapshotter variable absent
from the clean client environment, Docker sent its bare name in `Env`; an
adapter must not silently substitute an empty assignment. The CLI also issued
wait and start requests for the synthetic ID. A connection trace showed only
the synthetic socket, and the fixture server and directory were removed. This
records CLI translation against a fake server, not a real container, provider
acceptance, admission or cleanup proof. Earlier fixture attempts exposed an
incorrect HEAD reply and an incorrect environment expectation; their logs are
`.build/phase1-docker-node-wire.log` and
`.build/phase1-docker-node-wire-reviewed.log`.

The installed Docker CLI, fixture, final log, request transcript and trace
SHA-256s were respectively
`b6f5521ba1c355ea6f8943241435f494963b0840388543b2fca1a4062913da8f`,
`5b3925dc5119f7ed91a3236ffc73060bc3c6111d7788bebc3b48b21b7281d8d5`,
`e1f0c6ab9b72db7061bfc4558e2ee6e94e82da684e0e8e00b8d601d5bb6be932`,
`ada0b4d54931fea6e759002040ca291b8be6c53caa2129d4d252f9af37143f49` and
`e3cc75d6708664b216357edf489c2da88deb7bbef10a68dbad5bd8a141b84425`.
The fixture and evidence paths use `.build/phase1-docker-node-wire` with
`-reviewed-final.log`, `-reviewed-requests.json` and `-verified.trace` for the
three outputs. Node mutation and Phase 1 acceptance remain open.

The node inspect projection now requires the expected hostname, TTY,
privilege, cgroup namespace, restart policy, security options, tmpfs and init
setting in addition to the existing image, labels, mounts, network and port
checks. A mismatched value is a conflict and a missing required value is
invalid. This prevents the existing start sequence from accepting these
particular mismatches as a matching inspection; it does not establish ownership
or authenticate the daemon. The warning-as-error integration build and all 40
connected-Docker info tests passed; controlled fixtures changed each new host
setting and removed the privilege field. Formatting and HLint passed. The
first two build attempts exposed fixture key typing and name shadowing errors
and were corrected; logs use `.build/phase1-node-runtime-inspect` as a prefix.
The inspected source and integration fixture SHA-256s were respectively
`2acf79deb7f2fa4cee9ba177de8b226cfbc3acb991b979abf529a0412f3eb3aa` and
`c7f0eb502987615fc95c055c9ec4fb6f676dad2f9a02c295face7e5a910bca9f`.
These are synthetic Docker observations; real node create, read-back, cleanup
and Phase 1 acceptance remain open.

The internal scenario evidence store now requires its selected project anchor
to derive the exact deployment scope in the report binding. A report bound to
a different project is refused before either store is opened or created.
The warning-as-error unit build and all 26 scenario evidence tests passed,
including the cross-project refusal and existing scoped publication controls;
formatting and HLint passed. Logs use `.build/phase1-evidence-project-binding`
as a prefix. Store and test source SHA-256s were respectively
`3082ebaf2c6808d7f52d903a52440db6fa3073f11e8312132e044fc20374d1fc` and
`6550cfa8f41adab5954c5973d69e4ce5c0c5201e610fc1847e6b51b08f0a3df0`.
This coordinate comparison does not authenticate the root or scenario, and is
not the public scenario runner or A01-06 acceptance.

The internal stored-report validator now rereads the bound report after the
independent observation. A changed second report or an unreadable second read
refuses the comparison. The warning-as-error unit build, all 27 scenario
evidence tests, formatting and HLint passed; a controlled observer changed a
valid report during validation and received `ScenarioStoreChanged`. Logs use
`.build/phase1-evidence-observation-bracket` as a prefix. Store and test source
SHA-256s were respectively
`fe797ee02580dca62d62a7df6c777d7c5182e48109da4bb307bbb9f688a2fdfd` and
`807148e3f5752574923d391b87a7c14abc95e5f9b3f7ccc9b9945f832df48590`.
The reads are samples, not proof that the report stayed unchanged between
them; observer authentication, bounded execution, the public runner and
A01-06 remain open.

A fresh canonical gate attempt stopped at the repository Haskell style rule
for a case expression inside a test lambda. That test predicate was moved to
a named helper; the subsequent full-tree Haskell policy, formatter and HLint
check passed. The failed attempt and successful lint logs are
`.build/phase1-20261117-current-gate-initial.log` and
`.build/phase1-20261117-haskell-lint.log`, with SHA-256s respectively
`fa4294014d280f79b5ad75f18ea281fed5283432ffbd6ce09cb027400f7841a3` and
`b62764783a0004e9ca9cf455f2de37d9ba8b9c3f37056014cc3c5d74bb053b40`.
The corrected test source and rebuilt operator SHA-256s were respectively
`b4150173028a73d618a0052a5dec84b5525931013df261f42073f5b9e17b3bce` and
`654ca5dd7c571108a4f879a82e09a558138d94cc23e6b2764faf89cd6c07a574`.
The subsequent canonical gate completed successfully: its main unit suite
reported 10,062 passing tests and its three additional gated suites reported
27, 35 and 935. The `.build/phase1-20261117-current-gate-final.log` SHA-256 is
`59823ef35717f03f93be30a9daeaf344fbcb847b0769106bde8e949299a8f06b`.
The phase record changed while that gate was running; a separate documentation
lint passed after that update. These checks do not establish Phase 1 acceptance.

The connected node adapter now has a removal sequence for the exact full ID in
a recorded successful create result. It requires a matching node inspection
and caller-supplied admission before a durable exclusive removal attempt;
its Docker request forces removal of that container without requesting volume
removal. The transport result is recorded separately, and start refuses a
recorded or unobservable removal attempt. `control status` reports the removal
attempt and result without claiming absence or worker settlement. Pre-delete
inspection is not repeated after the effect; the post-effect check retains the
marker and daemon/operation observations instead.

The warning-as-error executable/integration build, all 40 connected-Docker
fixture cases, targeted formatting and HLint passed. The fixtures exercised
accepted and denied admission, wrong ID, an existing marker, start after a
removal marker, exact DELETE arguments, lost reply, changed post-effect
observation, and public status of an unconfirmed removal. Logs use
`.build/phase1-node-remove` as a prefix; two initial builds exposed generated
identifier and callback-edit errors, corrected before the final build. The
transport, intent, operation, status, integration-test and operator SHA-256s
were respectively
`d1321cd0c3441de1761d72388005bcb9a6eebb1690cd6b77f061cdb0a9c0e57d`,
`0dcb843ddccdb8207a076716e4c870e439a7f6b3461ab86163a6ee91819379c9`,
`21b7b6c010242d53949e56cdd4fe9bfa4686faeb48664e83ce2f2221fc8b0f32`,
`21ede63267d6a41ab18051fc0924f8b408eb459c991ebac30fd306eca7fb212e`,
`b7c0fa14e06f2ae41e1d358d7a62a9e376a46cb280955474ee6af1a11a8eef97` and
`870bc0fcf0764d2949a1f9019f95f017abbcb20dcacf2604149db9a3b1a701a6`.
These are synthetic observations, not real deletion or proof of exact absence.
The admission callback still requires a real owner, daemon authentication,
worker settlement and retained-data protection. Unconfirmed create recovery,
independent node absence, a public reconcile/remove path and real acceptance
remain open. The preceding full gate predates these source changes.

After a matching removal marker, `control status` now reacquires the operation
and independently samples the exact recorded node ID using the selected Docker
CLI and socket. It repeats an unfiltered container inventory and exact-name and
cluster-label filters, brackets them with daemon and marker observations, and
reports changed, unavailable or sampled results separately. Empty samples are
explicitly not a claim of absence; no mutation or cleanup is authorized.

The warning-as-error executable/integration build, all 41 connected-Docker
fixture cases, targeted formatting and HLint passed. Controlled tests cover
matching and changing samples, foreign daemon, missing and malformed inputs,
and the public status output with a synthetic empty daemon. Logs use
`.build/phase1-node-remove-inventory` as a prefix. Read-back, status,
integration-test, package and operator SHA-256s were respectively
`2c14fa34a4113f5f6559c85e160d5f9b8cf68acf8e7deb56fa67801b4892b1b2`,
`94ee5af106bb64a084166f50a6e87b31987b06c8158c0649068f7c5182a3d4c9`,
`6924ac559926217ff513bfad79f16ee58aeaad10fa8fbc77c97d258b339bbd58`,
`457feaa6ce9263a4b7632ab4284bd64559838289348529293f7f07e86e6eb887` and
`2850068b4e3fc1583517787e92f9fb89c097cf0b6a3a6de3eaa3c529653c0b6c`.
The test log SHA-256 is
`f9de6858807525b8615dfe83d0fb6d996955def75e15d8a7196de217dcf3f887`.
The fixture does not establish real node creation or removal, daemon
truthfulness, all-worker settlement, positive observation controls or terminal
cleanup. The public lifecycle and Phase 1 acceptance remain open; the previous
full gate predates these source changes.

Before recording a node-removal attempt, the connected removal sequence now
requires an independently sampled positive control: the exact recorded ID
must appear in repeated unfiltered inventories, in the exact-name filter and
in the cluster-label filter, with the selected daemon and operation stable.
A blind, changed or unobservable sample refuses before the removal marker or
request. The subsequent inspection and admission checks still apply.

The warning-as-error executable/integration build, all 41 connected-Docker
fixture cases, targeted formatting and HLint passed. A controlled multi-client
socket fixture supplied a visible target or a blind empty inventory; the
visible case reached its exact DELETE and the blind case left no removal
marker or DELETE. The actual installed Docker CLI issued the independent
reads against that fixture. Logs use `.build/phase1-node-positive` as a prefix.
Read-back, operation, integration-test and operator SHA-256s were respectively
`d611fa493911e27ed4e0dca84a483e782b47c87d4eb668633a5bf28e10ed4f64`,
`a0541b97858f89c08133d763e002ef5f1b21a6dda6f34499a1f5613daa644415`,
`e39a18951db53fd21d16a1589ced8e0ae7e192c36c0c4d4360e9072a991c99fa` and
`5a52da459ac6070a0e44184bfdb5bf2e0047780a2200e237033c688051489bd3`.
The final test log SHA-256 is
`e7dcd46c08f13d9e91fdeccb9c58746d154bba4fedc271c2faf4ea5b379b5fe1`.
This pre-effect control is not durably recorded for recovery and does not
prove daemon authenticity, ownership, worker settlement, actual removal or
post-removal absence. The public lifecycle and Phase 1 acceptance remain open;
the preceding canonical gate predates these changes.

The removal-attempt writer now performs the positive inventory control itself
and writes a separate bounded, synchronized record bound to the create result,
operation, selected daemon/socket and root identity before the attempt marker.
It rechecks that record while publishing the attempt; the connected effect
checks it again before and after the request. An incomplete newly written
control remains an incomplete attempt. Existing removal attempt/result records
remain readable when the new control is absent, and status reports that missing
or invalid control rather than inventing one. The record is an observation, not
authentication or a settlement permit.

The warning-as-error executable/integration build, all 41 connected-Docker
fixture cases, targeted formatting and HLint passed. Controlled cases exercised
a blind inventory, retained control, corrupt control, a missing control with a
still-readable earlier result, and public status. The installed Docker CLI used
the synthetic socket; no real node was removed. Logs use
`.build/phase1-node-positive-retention` as a prefix; an intermediate build
caught an incomplete status constructor and was corrected. Sampling,
read-back, intent, operation, status, integration-test, package and operator
SHA-256s were respectively
`f7fea92a289b21b80635a94b31eeae93749801c7d0737f0874c88530ddc7da4b`,
`cf32481b9d7834d0fd782fc770a8d4112f80c2845932a001b1868208a00ceb5b`,
`fae0e656192f34ef395e6510645430693e97ec078d4d52c9c6ef8646159d154f`,
`2584858016bb6919f28ef219931b394790da94dae71516d5d913f7ebfb6c5d88`,
`d7a664f6c4f039b80030340ba645c9ea4a2c55c3a5de00a9bc3da342dfcd9eae`,
`15ab52e2728bf70339722a2e484f6235791743bf81a2f23e2fe4e65b1cdc89a4`,
`1c7f35566d55888912f8f0c2017e35cd937747ccc7bc2ad6b2aa1c0836c63a01` and
`76090532108866b5f840ef561d324b739f7304316eaf892ab43670246754279f`.
The final test log SHA-256 is
`c88414d452e22966aad187412b7595db6f6791794ad87cc2d403128137571941`.
The record does not prove daemon authenticity, same-user integrity, worker
settlement, actual removal or terminal absence. Public lifecycle activation
and Phase 1 acceptance remain open; the earlier full gate predates this change.

For a recorded node-create attempt with a missing or unconfirmed result,
`control status` now independently samples unfiltered, exact-name and
cluster-label inventories twice on the selected daemon. A single consistent
ID is inspected on the held connection and reported as a candidate; mismatched
or multiple IDs are conflicts, changed observations remain changed and
unanswered observations remain unobservable. Empty samples explicitly leave
absence unverified. This is a diagnostic and does not register the ID, prove
ownership or settle the create request.

The warning-as-error executable/integration build, all 42 connected-Docker
fixture cases, targeted formatting and HLint passed. The public status fixture
covered a visible candidate and a blind empty inventory after an unconfirmed
create result; controlled parsing covered malformed, inconsistent and
multiple candidates. Logs use `.build/phase1-node-create-uncertain-readback`
as a prefix; an intermediate build was interrupted to correct classification
of unobservable daemon and result reads. Read-back, status, integration-test,
package, operator and final test log SHA-256s were respectively
`d9c529b0910f936941f7d3e0727071c5fbb74a0fd5ff563d6c9507e69c8861fe`,
`51d9f90a66b7220abb66825865c2cce8426cf23427f98469415da03ab3ad2640`,
`3340d59f9b6bc749cf7f2d10d9469b990c77a29363ac6b3a86e1bb1d48f42c60`,
`929af8dc837bfa79af78b5248ded32ea1ecc07a43b46096a2df554a3a48d6813`,
`82bdcf4b368e786ace34f9b41f2483cd76373c7b2dc0e589eb2c3ba96e82b29d` and
`18cf87a70225127c5c72c2b7b9c86374d24669a57b2f6ebbfa21a8d1c72b4503`.
The fixture is not real create or recovery evidence. Durable candidate
registration, daemon authentication, worker settlement, exact cleanup, the
public lifecycle and Phase 1 acceptance remain open; the previous full gate
predates these changes.

The unconfirmed-create path can now retain a non-authorizing candidate record
bound to the exact recorded attempt, root, daemon/socket and candidate ID. The
writer requires a repeated positive unfiltered/name/cluster inventory for the
ID and writes the record exclusively with read-back; it does not replace the
original create result. `control status` reports a matching, missing, invalid,
conflicting or unobservable candidate record while the create result remains
missing or unconfirmed. A retained candidate is not ownership or settlement.

The warning-as-error executable/integration build, all 42 connected-Docker
fixture cases, targeted formatting and HLint passed. Controlled tests covered
visible and blind inventories, exclusive publication, a corrupt record, public
status and preservation of the original unconfirmed result. The installed
Docker CLI used a synthetic socket; no real node was created or recovered.
Logs use `.build/phase1-node-candidate-record` as a prefix; an intermediate
build exposed a missing status field and was corrected. Intent, status,
integration-test, operator and final test log SHA-256s were respectively
`3f37e07629af714df02f19c12a704c0a2aaceeb4b787f3007a2aab53f89b01c6`,
`c56aefe8563cd1c319074c837df67ae77cd1ca6317db28887483b5d558be63e9`,
`9ef2ccc311c9e250a7145a3740aa76668304404756a4baa1c3968ae01eb6e468`,
`d5338cb61b3d9ddf631e1e8ff2f19ec22fb3691e10b765d125406229c912effb` and
`3f234fc5924310a6e8b6c89d8a5b404094a02c526f4357171bab041fe44326c9`.
This writer is not yet connected to a public lifecycle owner or cleanup. The
record cannot authenticate the daemon, establish provenance, settle the create
request or authorize deletion; Phase 1 acceptance remains open. The earlier
full gate predates these source changes.

The private candidate-recording composition now reacquires the operation lease
and the selected Docker session, checks the retained daemon identity, and
inspects the exact node before and during the independent inventory checks.
It reports a changed observation after publication separately. A different ID
cannot be treated as the existing candidate. The warning-as-error executable
and integration build, HLint, Fourmolu check, and 42 controlled connected-Docker
tests passed; the latter include a foreign-ID refusal and a conflicting record.
The build and test logs are `.build/phase1-node-candidate-held-final-build.log`
and `.build/phase1-node-candidate-held-final-tests.log`. SHA-256: intent source
`1eda8d5776c3dc2ac417e12a49a1759e3a6f158c8aa476d624c491fb47f9bcbe`,
operation source `064b51b7ca148dfa70423e5e14280c40f31455ac8ca40f95288e53babbf2356b`,
integration source `313bec73476cbf60fcb0babf33250255729673549c37539a68e42e0cdbd701dd`,
binary `ccad6a5d33c182ab0768d821635b990e6ea5031dc6bacd44b90bdc500b08fc83`,
and test log `a74cdbd4851bdb5a241ebb67c38e19bc6c2f7261edbabf29dd3f205d010da631`.
This remains private fixture-validated groundwork: worker settlement, public
reconciliation and real lifecycle acceptance remain open, as does Phase 1.
The earlier full gate predates this change.

The evidence comparison now distinguishes an ordered but late observation
from malformed timing. A late primary or cleanup observation is retained as
an unmet check, including when an untrusted report claims earlier completion;
only independently observed completion within both deadlines can satisfy the
check. Invalid timestamp order remains an error. The M02 reviewed source pin
was updated for this change; its actual mutation campaign remains required.
The warning-as-error operator/unit build and all 27 scenario-evidence unit
cases passed in `.build/phase1-evidence-deadline-build-final.log` and
`.build/phase1-evidence-deadline-tests.log`. SHA-256s for the comparison,
reviewed mutation catalog, unit test, operator and test log are respectively
`e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1`,
`f56b9346fe967fc0b9078cf119e4b4f258992989eb1fd31153817beceed31efa`,
`7200d0a76df9763dfda07795071f8601ba31577715dbf5a9cf0e54085df69f24`,
`ccad6a5d33c182ab0768d821635b990e6ea5031dc6bacd44b90bdc500b08fc83`, and
`faf3cf4a8c1f90b35a5aa137ae84411b2fa8ea621b6a1fb5ca6b6e70bc5931e3`.
The comparison still requires the unfinished real runner and independent
observers; this is not A01-06 acceptance or Phase 1 completion.

The inherited B020 and B021 removal rows were re-audited. The B020 fragment
bindings are absent from source, tests and Cabal; the typed Tier-0 fixture uses
`renderProjectConfigDhall`, and nine fixture tests passed. For B021 the named
fixture failure paths return typed replies, and the malformed-config HTTP
regression passed for both config endpoints while the server continued serving.
The results are in `.build/phase1-b020-absence.log`,
`.build/phase1-b020-current-test.log` and `.build/phase1-b021-current-test.log`.
An initial canonical gate failed because two files had been formatted using a
different Fourmolu version; they were reformatted using the repository-pinned
tool. The rerun in `.build/phase1-b020-b021-gate-rerun.log` passed: 10,062
unit, 27 authority-admission, 35 authentication and 935 authenticated-transport
cases. Its SHA-256 is
`3ff46547b0b4edc46264aadb686a091951c9ff8fd4fb4cec88c8e0c71f771074`;
the built operator was
`618b3516e671a1ed66b3fc27547f7be3d96a2b87abb22d800a185c89eb7c6ed5`.
The targeted B020 fixture and B021 HTTP test logs have SHA-256s
`2de76f5561cb36a98f46fc241323061e0f511066ea7ca38f180c19d5faa4a7df` and
`250f470eea0e8dc39ecb157f2a6347491e8d78d844aab5f8ac37a8946c9a5c87`.
The fixture, server and integration sources have SHA-256s
`b6f1d99982d71a0fd7f33c738f84ed0accd835d15e9a8d89bd92bf3568b9dc5a`,
`e89212adf8f45a76117a809e47beca6ac0865ad889652c56d2ea91c472beb8fd`, and
`a97c9b377de4e2d6ffe607103c98b116ede23e83062e4be22eaceea8b8db0979`.
B020 and B021 are removed; these checks do not close Phase 1.

The B039 audit found that the old host-side `Prodbox.Config.InForce` modules,
the `LogicalInForceConfig` constructor and their unit-only consumers still
exist. The current Authority config endpoint and loader have a passing
18-case targeted baseline in `.build/phase1-b039-authority-baseline.log`; that
controlled baseline is not live replacement acceptance. The host-side modules
and object constructor have since been removed, the retained tests repointed to
live interfaces, and a source/path absence guard added. Pinned HLint passed in
`.build/phase1-b039-hlint.log`; the warning-as-error build in
`.build/phase1-b039-build.log` passed, as did 38 targeted Authority,
object-store, config-rendering and negative-guard cases in
`.build/phase1-b039-regressions.log`. The regression-log, checker, encrypted
object, basics, unit test, Cabal and operator SHA-256s are respectively
`7cdb11241dc2a1aa57f927e238c9f46cd28d419aebadbef7f3af5860fb28309f`,
`a6d6f9f6e56c694fa9e6c523e660c13c986550005834ca5ef7ffff229833f554`,
`e8c8d585136353b85981583b1d1e93737fdb48b379df0ee5d7bb00a0f6033415`,
`1dade46ac8cb69a1f76a595907bfde3b3109321a0bb133da3c68005d68f01c41`,
`db9c0f5b704af18aa3ceeed5dcf7ce178f66e8ed036ef9c1895839ec6f7bc3ff`,
`f17c1fd785ce04d1608f01408f7baaec60d1ea2bf452963b856f5d443954fc5f`, and
`fe81413989ef006ea0e8c9045eec2222012f69be0cbecbcd33e23dc937953159`.
The first post-removal canonical gate in
`.build/phase1-b039-post-removal-gate.log` failed documentation lint because
the archive cited the now-removed current paths. Both historical source objects
were verified at `583443f`, the archive citations were revision-qualified, and
documentation lint passed in `.build/phase1-b039-docs-corrected.log`. The
corrected gate passed in `.build/phase1-b039-post-removal-gate-corrected.log`:
10,044 unit, 27 authority-admission, 35 authentication and 935 authenticated
transport cases. Its SHA-256 is
`f842f926ff42cfda00eece911052ac17a8c07c2454e6a5e5f7415993abed42ae`.
The source removal and gate do not establish the real replacement acceptance;
B039 remains pending with Phase 1.

The operator executable can now act as the kind worker's read-only Docker
bridge client when executed as a file named `docker` in its bridge directory.
It derives that directory from the executed file, checks the held and named
directory identity, and uses the existing bounded endpoint exchange. Missing,
changed or unconfirmed endpoints fail closed. This is not a lifecycle owner:
the worker still must be installed, confined and settled by the operation,
and the bridge has no mutation admission or recovery implementation.

The warning-as-error executable/integration build, pinned HLint and formatting,
normal control help and documentation lint passed. The 42 connected-Docker
fixture cases passed in `.build/phase1-kind-executable-client-suite.log`,
including execution of the actual operator as the client, missing-endpoint
refusal, one allowed read and a refused pull against a synthetic daemon. The
build and targeted logs use `.build/phase1-kind-executable-client` as prefix.
SHA-256s for the app, client, integration test, Cabal, operator and suite log
are respectively
`45132ac12af2b0054962b531bd3f64a5d5daa9ca2ca06870e1199b13d4cafc85`,
`a6c519e85e86c151a9873d14303ac0c1a57caa241d5010a929229f53e053150c`,
`16c81e9e153727031136c040ee7b2320723bdda11c32e5f777294f7bb4729245`,
`6d7cdad23b636abdabf4ae125f69abe65f4755ef16cd56b78c5932ed3879c10b`,
`7f5d54af372588bddfd22e805a2be98735e1e30e2604429f7342d4caf3467a7d`, and
`b6e81966cc34d16cddea00c814fb0eb7f60f350759349c42fc567f73eb9ef48f`.
The canonical gate then passed in `.build/phase1-kind-executable-client-gate.log`:
10,044 unit, 27 authority-admission, 35 authentication and 935 authenticated
transport cases; its SHA-256 is
`cbfcb16106eaa4d94b94c5e37e0750e68a9f0b38921546c5a98117d5bfe3a901`.
No real node or recovery was exercised; Phase 1 remains open.

A separate confined fixture ran the installed kind binary with the actual
operator as its `docker` client against a synthetic daemon. The daemon saw
only info, container inventory and an image inspection; after the synthetic
image 404 the bridge retained its in-flight marker. The execution trace shows
five attempted pulls, no container run and no network connect in the confined
kind process tree. This is a negative fixture, not real-provider acceptance or
proof of production worker settlement. Its exercised script (retained as text
to avoid repeating its overwriting paths), log, trace and request transcript are
`.build/phase1-kind-operator-client-composition-exercised.txt`,
`.build/phase1-kind-operator-client-composition.log`,
`.build/phase1-kind-operator-client-composition.trace` and
`.build/phase1-kind-operator-client-composition-requests.json`; their SHA-256s
are `44e59b538f08f6cbecf0de44e4ed7e40cfd7cb4f7f1e49ca8f136212d5e2afb8`,
`635f852a3c1bbc9be6a0bddc4c4f54ef1601f9157295dd8e88e0d932152f57af`,
`ab2bf73ccb052f1189b1b99cf1dd068afca04c7ebf1f7209621e164f9428061d` and
`ad409c45a713a3cc5d6f33d5867d7304db46ce2d4cf41e00fc2017e99e10c1cc`.
The kind binary, operator, fixture launcher and server SHA-256s were
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`,
`7f5d54af372588bddfd22e805a2be98735e1e30e2604429f7342d4caf3467a7d`,
`2abc37b92b02208c685df7dff6e740c3ffc0ff59519c60232670751972196f95` and
`2ca585c0da42a98a07bad7fb0898f41218f8bd8e3ee1b934b3f9f07cb478cb3f`.
The first version of this fixture accidentally overwrote the earlier trace and
request files noted above. The replacement outputs were moved to these unique
names, and the original request transcript was restored from a matching copy;
the earlier trace remains unavailable. The corrected script uses unique names
for any future run.

A subsequent read-only local diagnostic observed `/run/docker.sock` reporting
PID 1, UID 0 as its Unix peer. The effective user could not read that peer's
executable link. A separate manager query reported an active socket unit with
`Accept=no` and a trigger for an active Docker service; root-owned `/run` and
socket metadata were also observed. This is a local snapshot, not authentication
of the daemon or permission for effects. It rules out using direct peer-PID
equality with the Docker service process on this host. The diagnostic source and
log are `.build/phase1-docker-peer-activation-diagnostic.py` and
`.build/phase1-docker-peer-activation-diagnostic.log`, with SHA-256s
`74409407e129e748856f81e9b131264da0c627c8b56a211793d326f696bb6d58` and
`10b3ac6a051469620438c96984da0d103912bb30c56b3001e9124bd644433b82`.
The host-operation bus continues to pin a same-UID user manager. Status now
also has a separate, fixed read-only root system-manager observation for an
explicitly selected `/run/docker.sock`. It checks root-owned bus-directory
metadata, pins a root-owned manager, reads only the Docker socket and service
unit properties, repeats the snapshot and rechecks the manager owner. It does
not expose a root bus capability to callers, bind the selected socket to that
unit or authenticate the daemon. Other selected sockets do not use it.

The warning-as-error executable/integration build, pinned HLint and formatter,
and 42 connected-Docker cases passed. A public status probe against the actual
local socket read the manager state, preserved an unrelated marker and created
no run root. Four direct user-manager transport regressions passed, including
refusal of the root system-bus socket through the same-UID API. Logs are
`.build/phase1-system-manager-stable-build.log`,
`.build/phase1-system-manager-integration-stable.log`,
`.build/phase1-system-manager-live-stable.log`, and
`.build/phase1-system-manager-user-bus-stable.log`. The first live probe used
an obsolete inventory-output assertion and failed; its result is retained in
`.build/phase1-system-manager-live.log`. An initial direct bus-test build used
the wrong Cabal build directory and is retained in
`.build/phase1-system-manager-bus-build.log`. Source SHA-256s for App, the bus
transport and bus qualification fixture are respectively
`882636381faf0c196a715c31f0d1b5e0ff22ad445bb1d1b46e8eac15c7c591b7`,
`eff8990c72cfbc97eab30c6d9b720dcd4423976fc34fd5d01cf4a8be03a12e26`, and
`93f66a42ea570b6809636e5b83f02c3f5d2072ef5ea52ddf60b18294e8b8a45e`.
The operator, real-probe, user-bus and integration-log SHA-256s are
`ddd33cf77c8909e030733f1defd86a0a834a64f0d88069baf4d1d1f0addbc25f`,
`6a368396c82d908766e702a5f79ec6bd8526991d0047ddb7aa3bbb86f2a833d5`,
`db1880b3181ec2c737698e2baebc349f57b06321178de06e21693aed1b11139c`, and
`44f55743575e8aecf312f6f687eca9fb3cdfa84b39709cb77c41e7cfe11bdfe2`.
The subsequent canonical gate passed in `.build/phase1-system-manager-gate.log`:
10,044 unit, 27 authority-admission, 35 authentication and 935 authenticated
transport cases. Its SHA-256 is
`327f864803e29f2e993de80951332bbb0bf764f4f98218e134db73eb6605d9fe`.
An independently verified socket-activation binding remains required before
effects; this diagnostic does not close Phase 1.

While the post-change canonical gate runs, an isolated draft adds bounded
decoding of the systemd socket unit's listener list. Its read-only probe saw
`Stream /run/docker.sock` on the local manager. A private user-owned bus fixture
accepted one, zero and exactly 16 entries and refused a wrong wire type and 17
entries. This draft is not in the executable and does not prove that the named
socket inode is the manager's listener. The draft transport, app, test-export
transport, fixture probe and fixture script have SHA-256s respectively
`724e091ed88f46920125627f094fc74fddf7086df7d18c2992c8a39cf80e4d06`,
`2f83b66dce95893a2feedcdf4c4cb21234ad74ec3a6d4331c88adae1dd0537e0`,
`36d3ae82dd474f3754432f346647652386e88e3f8a51406e3b6428b1bb192196`,
`83ae0550af9cca49cfef83119e7e275924b72ce767db17b0d4ff9037c229c476`, and
`2eca5f23bb25daa7e8a564b7a910db4849fe44e3a1c2338024a7233e0ed54bbc`.
The negative-control and real-probe logs are under
`.build/phase1-docker-listener-draft/` and have SHA-256s
`f661c7335878837b044beb0d33003e1767144bc745ec469e300d2e4a4984cf1d` and
`d8fd25ca964d1bcfa7b022f635314582901860a7b3c34f9f88e09cc68d3e3f59`.
Integration into the public status path and final source/build validation are
outstanding.

A later draft also samples the system manager's PID in both observations. Its
real-manager probe saw PID 1, matching the separately observed socket peer, but
the observations are not held together and this is not authentication. The
updated draft transport, app and probe-log SHA-256s are respectively
`7aee65cd5411a0ab99bd3ca380ccfa5eba0acb022fbff4277179f5b95db4ba2b`,
`6999d3ee71d878be8eced91e94b9b69b3911c83eb58a2b859a834bb587668e71`, and
`733776098c064b267602f95f7b40679cc02ab582148dd15bb921c063159f8a73`.
The earlier draft files were replaced while iterating; their original bytes
were reconstructed and verified against the recorded hashes as
`SystemdBus-v1.hs`, `App-v1.hs`, and `SystemdBus-v1-test-export.hs` in the
same draft directory. The earlier negative controls exercised the v1 decoder;
they were repeated against a v2 test-export copy in a private bus fixture;
the copy, fixture and log SHA-256s are respectively
`be3c2255ce5015aae2949ebbf9de6772cb9ffbd5b79d05b4ee5ddb51ad2a1ede`,
`0c2ed3cf1329722c5ea7d3beaba57b1b408802019c5feb454ebca299b8e03563`, and
`f661c7335878837b044beb0d33003e1767144bc745ec469e300d2e4a4984cf1d`.
They must still be repeated against the final integrated implementation.

A separate read-only probe held an actual connection to `/run/docker.sock`,
bracketed the manager PID queries with peer credentials and pathname metadata,
and observed a stable peer PID and manager PID of 1. This remains a local
snapshot; it does not establish socket-inode ownership, executable identity or
admit any effect. Its source and log SHA-256s are
`78bb79ce9c3cd7c8fe01b469ccbcfb642d1a8ddb88ee1d31d8c83d187b3e67ca` and
`c118f69c71c18cfb4998bab0748d79a3e91c95076ce0cd97fd0b7095f8de6170` in
`.build/phase1-docker-held-peer-manager-probe.py` and its `.log` companion.

The current isolated app draft goes further by sampling the manager while a
`withConnectedDockerPeer` connection is held and reporting a PID comparison
only after the peer and socket recheck completes. A Haskell probe using that
composition observed peer PID 1, manager PID 1 and the expected listener on the
local host. The app draft, probe source and probe log SHA-256s are respectively
`d2f62f86ec9b7fa9b948f0659318cc6bb126da2d4196bb490673b6ee29d49847`,
`6071ccb874523ddba6cf62771d80e6c70a2dbcea68f2e5ee77862f52305fe273`, and
`ef005cbb7fe358b33680f238bf958206b97accec2806b994045e5a3b7dcbc44b`.
This is still not an inode-ownership or daemon-authentication proof. The first
two standalone probe build attempts failed because of package selection; the
corrected isolated build and failure logs are retained under the draft directory.
The callback was then given an explicit socket type. That app draft and
matching held-probe source SHA-256s are
`f747e825802327b66158a1a007cf42bfaa0cb46aae0f5a902d1e14fcd75ec2d7` and
`b1ba51925ccf820041911f4a7e80159c953dc4edf6c3c5006d14db2474865c3d`; the
updated read-only probe passed with the same output hash recorded above. The
previous app bytes remain in `App-v3.hs` in the draft directory. A further app
draft reports the peer UID and labels the comparison specifically as PID
equality; its SHA-256 is
`59cdcf1c23ebbb900a185074e202e83d148a8b8de7b05d926cb29743b0443d51`.
The typed predecessor remains in `App-v4.hs`.
A separate held-connection negative fixture used a disposable socket owned by
the effective user and observed a nonmatching manager PID; the connection
settled and the temporary socket was removed. The fixture's comparison is an
adverse observation, not an authorization test. Its Haskell source, fixture and
log SHA-256s are respectively
`7cd66a2f2ef99e1268f90670e52c1006847579ec21d7bfdbec8f6248156dc6a2`,
`4bb4aad6ded88e699b055068b6c80919bb3ddec786d537df06e05fb974f2e8b3`, and
`54128d11383d7fa0b8de5f1ee51a71f4527f4acf1407522174c2e5b8594d322b`,
under `.build/phase1-docker-listener-draft/`.

The listener decoder and held-peer observation are now integrated into
`control status` for the exact `/run/docker.sock` selection. The manager reads
are repeated while the peer connection is held; changed or unobservable
results do not become matching observations. Status labels PID equality as
such and continues to report daemon authentication as unverified. It does not
prove that the manager owns the selected socket inode or authorize effects.

The warning-as-error executable/integration build, pinned HLint and formatter,
and 42 connected-Docker cases passed. The real read-only public status probe
reported the manager listener and held peer while independent inventory stayed
empty, an unrelated marker survived and no run root was created. A private
bus tested the integrated decoder with one, zero, 16, malformed and 17 entries;
its test copy differs from the integrated transport only by exporting the
decoder. App, bus transport and operator SHA-256s were respectively
`59cdcf1c23ebbb900a185074e202e83d148a8b8de7b05d926cb29743b0443d51`,
`7aee65cd5411a0ab99bd3ca380ccfa5eba0acb022fbff4277179f5b95db4ba2b`, and
`b6e4bde22cbbe465978d6b7355936d4445a6a5f1961c8b30df831b760439fd3e`.
The live fixture, live log and integration-log SHA-256s were
`0536cd6c71c661b02ff9bc1768b516e913345601df3729c81d5aeabd1fb7e6ef`,
`7d5accef37efada6c28a8c57e12de0e3ccf9bfd81974408a8e7c620a11f49971`, and
`a55d15f4534baeb5d6efe3f787c761c0400b8746d89b9afe02c0fd41a0025375`.
The decoder test-export source, private-bus fixture and negative-control log
SHA-256s were
`be3c2255ce5015aae2949ebbf9de6772cb9ffbd5b79d05b4ee5ddb51ad2a1ede`,
`94080532920312ca2bed20fa1806cb0289461d9f63338b622f8d1884c671135d`, and
`f661c7335878837b044beb0d33003e1767144bc745ec469e300d2e4a4984cf1d`.
Evidence paths use `.build/phase1-docker-listener-integrated` as a prefix.
The preceding full gate predates this change; real lifecycle acceptance and
Phase 1 remain open.

An additional read-only local query of systemd's descriptor-store method for
`docker.socket` returned access denied to the effective user. Its result is
`.build/phase1-systemd-docker-fdstore-diagnostic.log`, SHA-256
`20f43106a66e596da5f7f7f3bf28b7e197c8ae53a3563177ad5981771c45e277`.
The query did not establish whether that store represents the listening
descriptor; the denial is not evidence of socket absence. The observed
listener and peer therefore remain diagnostics rather than inode ownership.

A disposable host-kernel probe tested executable staging alternatives for the
kind worker. On this workspace filesystem enabling fs-verity returned
`EOPNOTSUPP`; Landlock ABI 8 rejected a rule for a sealed memfd with `EBADFD`;
and a restricted child executing a path through its parent's held sealed memfd
received `EACCES`. The last result does not rule out other confinement or
descriptor arrangements. These observations do not authenticate an executable
or settle a worker, and no lifecycle effect was attempted. The reproducible
fixture and output are `.build/phase1-worker-executable-kernel-probe.py` and
`.build/phase1-worker-executable-kernel-probe.log`, with SHA-256s
`36509747d2f5a3dc55345ecbd52282e020a8d4aec6fc8ee225c12d604f353853` and
`b187713497ec12ebb61ed1dd0de294d49ca9d64ae2c282bcfa688ac5c28353a1`.

The read-only bridge client can also locate an explicitly supplied bridge
directory when it is running from the fully sealed `prodbox-kind-tool` memfd.
An unconfined fixture ran the installed kind binary with the actual operator
client inherited as a sealed descriptor and served read requests from a
synthetic daemon. Separate negative cases refused an unsealed executable, a
relative bridge path and a differently named memfd. The warning-as-error
executable build and targeted HLint and formatting checks passed. The fixture
does not establish confinement, executable admission, endpoint or daemon
authentication, worker settlement, cleanup, or real provider acceptance; the
public lifecycle does not yet use descriptor retention or the larger client
budget described below. The in-flight canonical gate
began before this source change and cannot establish a clean baseline for it.

The source and retained operator SHA-256s were
`a646b00f213c05e734d7070cf7615adc2499c6f3c2910f7a75d1ba1aeeeabd8e` and
`5fbe2f4b828dee600d82338bf127acb92fb207c4c4fdad771bdd4567c0a50851`.
The composition fixture, output and synthetic request transcript SHA-256s were
`40772e81152da11a90471460f2e15e1112b227be3a32e591ce445e299accf652`,
`5bb64b3e647b14c1dba2451903ca80247675af9f64ff61ac786f5be41fe3f320` and
`ad409c45a713a3cc5d6f33d5867d7304db46ce2d4cf41e00fc2017e99e10c1cc`.
The negative fixture and output SHA-256s were
`4cb4522f3d6465163023201e44b0210fe1d22231bbab97470cc334acc51cce3a` and
`16b67634075c14072756bc333c9ea5fee64afba5c5bd2be974bef3f1feac160c`.
The retained operator and fixture paths use `.build/phase1-kind-sealed-client`
as a prefix.

A further disposable fixture applied the existing filesystem, network and
metadata restrictions and explicitly retained the sealed descriptor after
worker preparation. Real kind then used the operator client against the same
synthetic daemon; the trace recorded no network connection by the confined
process tree. The fixture launcher supplies descriptor retention itself; this
is not yet the production worker's behavior. The first two launcher runs
failed because the fixture lacked threaded RTS support and then supplied a
nonempty scratch directory; after correcting those fixture conditions the run
passed. The launcher source, launcher binary, fixture, final log and trace
SHA-256s were
`43dcbc7dcf6dd706165e7605fa97a3d55235fde131a28c777b46cddf82a478ab`,
`9d57f5d4dc52442d823d30623a8bb07e91e7fea38c0ab6e873d9fe02e97db461`,
`af2e5e0fc2430bb4c8535f1c7b5063638a7c80bd73accace22568e0fae7d6f87`,
`964903954066ba92ebb8f5ce367be594d0ee62c13d44e2ca09c8ce526a7a22d6` and
`2eda0c91b4552a069009baf6dae060ce042963c73fe0b1e40b735c3a21437237`.
Their paths begin `.build/phase1-sealed-kind-launcher` and
`.build/phase1-kind-confined-sealed-client` respectively.

Worker preparation now has an explicit variant that retains one distinct,
fully sealed client descriptor after installing the existing restrictions and
checks its close-on-exec state. It requires the caller to authenticate the
bytes, fund the memory and exclude descriptor races. A disposable launcher
called this variant and repeated the confined kind/synthetic-daemon fixture;
separate cases refused an unsealed descriptor and a sealed descriptor aliased
to a worker root. One checked-in integration regression also refused an
unsealed descriptor. The warning-as-error build, focused regression and
targeted style checks passed. The first regression invocation used the wrong
test-runner flag and failed before running tests; the corrected invocation
passed. This remains an internal building block, not a public lifecycle or
evidence of admission, settlement, cleanup or real provider acceptance.

The worker and integration-test source SHA-256s were
`ae62f4fa25e41fe28c39ae50a3e73aa928b3c0cfd4320fe7b4dbe3529918d115` and
`54db880da48c5b973771ee3fbebec118e958330bcce522643a5ea5218f865676`.
The launcher source and binary SHA-256s were
`678894707c1cde500b0f5372cfb1f7f330ee909dbcd1aca34ed84d416e96c523` and
`76b4dd0d7e16de89ef0b268a587269079e96c7df7908a9e07f543f2cecfe48eb`.
The composition fixture, output and trace SHA-256s were
`cd51b91e40b08825da6f31b649f5376ea811c0c77e241e2188282924d0ddd982`,
`964903954066ba92ebb8f5ce367be594d0ee62c13d44e2ca09c8ce526a7a22d6` and
`5b523d99577aac541be46a41a5ff85ca66907f3e4a318979fd41f44aa199b7b8`.
The negative fixture, its output and the corrected regression log SHA-256s were
`abeecdc62271449bf7d89fc257f47721628ff76ff265e6adba1c687f41aa3b53`,
`9b8d04f79260390d23eb2764fafd1baf270ddd14bdc1d2077363b7ea3116bf15` and
`e72115efed809a688aaa5d0494f87648dfbc89d400b280d371b3a97cc0bfe353`.
Evidence paths use `.build/phase1-sealed-kind-production-launcher`,
`.build/phase1-kind-production-sealed-client`,
`.build/phase1-sealed-kind-worker-negative` and
`.build/phase1-sealed-worker-regression-final.log`.

The snapshot planner now has a separate 256 MiB maximum for the operator
client; the existing general-tool 128 MiB limit remains unchanged. Its plan
charges the rounded declared maximum and kernel overhead against the supplied
runtime plan. The focused warning-as-error test checked the charge, both
limits and insufficient capacity. A separate fixture used the actual planner
and snapshot implementation to copy and seal the 201,163,192-byte retained
operator, verified its digest and observed a refused size change. This is a
planning and snapshot check, not proof of physical reservation, concurrent
worker placement or a public lifecycle. Targeted style checks also passed.

The snapshot source and test source SHA-256s were
`bc5126696bfdfcde2b0dafa64660c52bda21fb7ad890b1f9930591eea8b61fa9` and
`d30716f01d2b6314084cce12f1222bc799b14260742fd1933202aed2b88a6320`.
The focused test log, operator fixture source, fixture binary and output
SHA-256s were
`4aa69f862d119342293be43bd987a57e27a3037c8050960721d4865a4f2b6277`,
`02b385171c9761478c7d298bd92a0f4fc3a7c2f7b86dceed23d95a1a378098c2`,
`e3c060a3f1484b031447f14fe0a2753c4500654423c5880305ab899a59532c6b` and
`1225771065d95d3a08cfdbf166a28b5653e5738c3d2a59ad74777faaf853c228`.
Their paths use `.build/phase1-sealed-client-budget` as a prefix.
The two existing sealed-budget regressions and the exact-byte/digest refusal
regression also passed, with logs
`.build/phase1-sealed-client-budget-regressions.log` and
`.build/phase1-sealed-client-byte-regression.log`, SHA-256s
`7ac3677c24dccc033506687810157e65673c235eeab1388414f5ad21f44dcbbc` and
`497bac4051cdfab232508e84a69ae020cd257a708464f233e110625decc6c643`.

The snapshot planner can now derive one shared runtime plan for the kind tool,
bridge client and bounded kind input. The focused warning-as-error regression
checked both charges, each independent size limit and insufficient capacity.
A separate fixture used the actual snapshot implementation to hold the
10,522,750-byte installed kind binary and 201,163,192-byte retained operator at
the same time, checked their digests and observed that both were sealed against
size changes. Targeted style checks passed. This proves neither a physical
reservation nor public controller admission, worker settlement or Phase 1
acceptance.

The snapshot source, test source and focused test log SHA-256s were
`265a80a4eae347518d36649f969cee1c4a79aaa0ed88960687bcdf6111a9f5d1`,
`771148ab353e909fc33b00e3c33a7527148f3e26a6c0e03b3853094a125d8959` and
`ac2646a0bfb542720e127a1160e2d7e6875d3251a91ae5ec5ef6de1afb2ce890`.
The fixture source, binary and output SHA-256s were
`b7d65b833d8f5d03aab49fb4fc13bc9ce0a009692c28b7ee2a4dfe4992c07981`,
`fc2908ebd123c1623c1965c3cbcbdb23094971986a382a535b265f96d568ed49` and
`dfdd07a403a0ad77680742d4919a28e50108b0d768b216c70cfcbbcf606e1a25`.
Their paths use `.build/phase1-combined-snapshot-budget-test.log` and
`.build/phase1-combined-snapshots-fixture`. The running canonical gate started
before this source change and does not qualify the new source state.

A disposable adaptation of the existing kind-host placement qualification
held both snapshots inside the real user-manager controller cgroup using the
combined plan. Its `memory.current` observation rose from 14,467,072 to
229,797,888 bytes while the snapshots were held. The fixture also observed
its interrupted child, managed units, runtime directory and cgroup absent;
a separate read-only check found the exact unit selection empty and the
fixture root, runtime directory, cgroup and child PID absent. The first fixture
builds failed on ambiguous or hidden package exposure; the corrected build used
the existing isolated qualification package view. This is one physical
snapshot/placement fixture, not the public controller, a real kind lifecycle,
management-plus-secret-worker capacity proof or Phase 1 acceptance.

The adapted fixture source, package environment, binary, output and independent
read-back SHA-256s were
`a3730ee1c1d1bfda3f99857840fbc33e94a03db0c12379dded2e3fc8534d8ba9`,
`b7d55d591d6d279180c59449168659c5e1220a03ffa9a70944817e6469132830`,
`7356e6a3c17a610be3f715fe67cfcc6c83f29132a5d54866a3cceb454819432e`,
`d95475c668c787568b1a05d543b3f73bc36aebc458f5ec4189637f21bc762296` and
`a286354ad614b81ab60e0b600b3dbb2882c09d80f1808faf0b4501b9e3c668a8`.
The evidence paths use `.build/phase1-combined-placement-fixture`,
`.build/phase1-combined-placement.ghc-env` and
`.build/phase1-combined-placement-independent.log`.

The managed kind subprocess path now accepts an opaque combined snapshot plan,
bounded input and one sealed client descriptor. It requires the descriptor to
be close-on-exec in the parent, then clears that flag only in the admitted
child after fork and rechecks its seals. The shared seal observation does not
authenticate bytes or authorize effects; the caller still owns digest,
descriptor stability and lifecycle admission. The general subprocess path
retains its existing behavior.

The reusable `test/qualification/KindHostPlacement.hs` fixture passed under
the real user manager with the retained operator and kind images. It checked
unsealed and already-inheritable refusals, rejected oversized input, delivered
binary stdin, observed the sealed descriptor through a child and its
descendant, and confirmed that the parent retained close-on-exec. While both
snapshots were held, `memory.current` rose from 14,368,768 to 228,679,680
bytes. A separate read-only check found the fixture's exact manager units,
runtime directory, cgroup, root and interrupted child absent. The existing
owned-subprocess parity fixture also passed all 13 cases, including 12 paired
process comparisons. Focused warning-as-error snapshot, seal and alias tests,
plus targeted formatter and HLint checks, passed. This is not a public kind
controller, Docker admission, real cluster lifecycle or Phase 1 acceptance.

The subprocess, snapshot, worker, daemon-test and qualification source
SHA-256s were
`1959b4d244a7a95c9a13294f8497ce7022ecdfc87fc8169cf17a632755353efa`,
`5fd80e417eb60ce9d53b861e36f21696f078849af4253445a11a0d19cb72ce05`,
`2be56e02692c71264ec02bee26d95cd35cf528c4fc6f2c46ccc39c52cfb01ed5`,
`59def97157a075582be400afed29f6d05c6ede8906a808c58896cf8ee17fe449` and
`31b9f37d96289731e44ab7afc5541f5ff867f41f1745bbd3450800c144fe1e51`.
The qualification binary, output and independent read-back SHA-256s were
`7555c5d582c8d20817924e96c538086bf6a99665d99da98aaaee9e9abe350319`,
`3acf10c8a1f0101de0f6b519a451d43af91d0f6b2bd64f3d5ea6358b1fd3ef09` and
`8be88836d26260d15df4a14cb1370d57310717bcdc5f8e49ed4dc0170c8864bd`.
The parity binary and output SHA-256s were
`104844f95e5caa59bab053b205b3d4a2be2ec41ba1bc1bf5abf54aff543bbcbc` and
`31ab1fe2f7df9be12a7a6541a45933a9aa95aaed6e5ca1cf7432df76b6b72f92`.
Evidence paths use `.build/phase1-managed-handoff-qualification`,
`.build/phase1-managed-handoff-qualification-input` and
`.build/phase1-managed-exec-parity`.

An initial focused build collided with the earlier, already stale canonical
gate in the shared build directory and failed while renaming a temporary
object. Its log is `.build/phase1-managed-sealed-handoff-test.log`, SHA-256
`4255fa2b88c9197d6b4642ca83b97ea415db3aee30ad667bc87ae28e244bd58c`.
The stale gate was intentionally stopped to prevent further collisions; its
partial log is `.build/phase1-bridge-env-registry-gate.log`, SHA-256
`4cd51fbd09df98ffc23fc2a7e51322d43d2262d7fca83f75bf963f6d35d3b576`.
The sequential focused rebuild passed; a clean canonical gate remains required.

The managed kind runner can now prepare a child on a bound thread, install the
existing filesystem, network, metadata and descriptor restrictions after the
child's manager admission, and execute a held sealed kind descriptor. It
requires an opaque combined budget, distinct sealed descriptors, bounded argv
and an explicit restricted environment. The caller still owns root
disjointness, endpoint binding, daemon authentication and lifecycle admission.
The focused warning-as-error descriptor test passed. A disposable managed
fixture observed the pinned kind version through this path and checked that an
ambient AWS profile, an escaping kubeconfig and oversized argv were refused
before launch. It does not yet exercise a real Docker broker or cluster.

The first managed run completed the confined-kind step but later returned an
unexplained fixture refusal; its root remains at
`/tmp/prodbox-kind-host-placement--0be3d93ae24bc676`. Independent read-back
found the exact manager fields, runtime directory, cgroup and recorded child
PID absent. The fixture was changed to preserve detailed future failures; a
second diagnostic run passed and its own root and manager fields were observed
absent. The first failure's cause remains unresolved, and the second result
is not a fix or repeated clean-cycle claim. The first fixture binary was not
retained separately before the diagnostic rebuild, so its exact bytes are no
longer available.

Read-only follow-up inspected the first failure's manager journal and retained
fixture files. The combined-snapshot marker and bounded input file were
present, and the journal showed another child-scope start after those files
were written. Given the fixture's sequence, this is consistent with reaching
the later kind inventory observation, but the journal does not identify the
command or explain the refusal. A later explicit read-only `kind get clusters`
query returned exit zero with empty stdout; it does not reconstruct the failed
observation. The controller journal, child-unit journal and later inventory
diagnostic are `.build/phase1-confined-managed-failure-journal.log`,
`.build/phase1-confined-managed-failure-child-journal.log` and
`.build/phase1-confined-kind-inventory-readonly.log`, SHA-256s
`19b2c7eae3ed861166ecee604bf1007029929767e431c0bed159c48d33405367`,
`9361db67d87f028aa8e359eefd980c54aa64f35f87081b4f99afe0c7e1f4e9a9` and
`d4779919b7c7f78d6f2304fd88f5c5e70c53d6e1e2acd174511bc636b48e04b0`.

The subprocess, checker, unit-test, daemon-test and diagnostic qualification
source SHA-256s were
`7ffebefbc48ad2548922e023bcecd6cf70df45223b3a6334ffb073837d72b041`,
`ec05410d4b57117c409a7559da61e054e0368ef90fd43a0773d6f804887f7942`,
`baa23e3cd360da6177d2a2fb6d3f69aee71834d1af749a63246290d60a5d20b6`,
`c9a986178876f460bb63e1bb50e9d4cea054a9d173e31a29d2698f3698c74f20` and
`13fc1779c7d22d1a65d317af51f105b75eb3d60c235cfdc02d483f7aabaae970`.
The retained diagnostic binary, first-run log and read-back, diagnostic log
and read-back, and focused test log SHA-256s were
`f370a0f501de6ade61e9bb7a8f757df16337c310ad15d0621f596bc528b85fb4`,
`08f5305f43e1085fedb39d017e4a4822abca0854a42a8c1c4aa5ea6ef4a03ab7`,
`c29cb4abf767ccc3548f4c4e3d73c24be11fff5051cca8b24790355e40ec3441`,
`de58ea82e6ea135e0362e2797020d56b14324c8e8978e26cfe53dfa82ca2f481`,
`20eaa4d3e79b6ff1362cacee5021cd5e9c5e3604e03b1da11b047175737db11b` and
`4ea517735a867f7c2b3b633d0c7df367cedd12068098ac5f5acc0692cd16de3f`.
Their paths use `.build/phase1-confined-managed-qualification`,
`.build/phase1-confined-managed-failure-readback.log`,
`.build/phase1-confined-managed-diagnostic-readback.log` and
`.build/phase1-managed-confined-worker-test-final.log`.
The earlier full gate was intentionally stopped after this source changed and
before a shared-build collision; its partial log is
`.build/phase1-managed-handoff-canonical-gate.log`, SHA-256
`06f31dab3ab1c9dd5087418f98685099ee2c61e21282e9a603550c4f80ef464c`.
The environment-variable registry was also updated for the confined runner.
The focused warning-as-error registry test passed in
`.build/phase1-confined-worker-env-registry-test.log`, SHA-256
`053493e294e94e0954a0b17034c51d9b0faa684ece65fd800b6d71de17bc0a08`.
A clean canonical gate remains required.

The qualification fixture's diagnostic writer was subsequently tightened to
retain both the original fixture failure and a failure to write its diagnostic.
This source-only adjustment compiled with warnings as errors and passed the
targeted formatter and HLint; it has not been rerun under the manager. The
source, binary and build-log SHA-256s were
`50a8e58a1ad67c2a75c22ad76c1ee466d1e5d103ae7c9c140cd9c870233110ea`,
`4749ede8979d0ba4a6d7e45eafc3745787f1d619fc2b9af535d989561df5050f` and
`99480857b83abb2a26fdfe9e1dea48122284257b19381bc09c655b33248df79f`.
The binary and log use `.build/phase1-confined-managed-qualification-guarded`
as a prefix. This does not explain or repair the earlier live refusal.

The later owned-subprocess parity run passed all 13 cases against the
confined-runner source, with retained binary and output SHA-256s
`2d3d2ae167b63ce1903f1505fd2bfa9048c7c05ea44b1f4cac6f1c0ee645918e` and
`b1dd5947adc19fcf108ab30491468009b1c7df50504f82ef44fa33468ab683b1`.
The preceding managed fixture placed its disposable bridge beneath the
fixture root but outside `.test-data/placement`, so it does not prove scoped
endpoint placement. The fixture source now places those paths under that test
scope; the revised source compiled with warnings as errors and passed
targeted style checks, but has not been rerun under the manager while the
earlier refusal remains unexplained. The revised source, binary and build-log
SHA-256s are
`66f58d9501b6cdc7f210699923a0d9bb9c1f29181d058154c45bb6574e989519`,
`a1a6ee026f507283221563a10b3887def44ef772991ff73151376432860b246e` and
`4395c26d4f963458f7bfb9cac9b5180ec2a4294d09da1b085c258397192cb681`.
The evidence uses `.build/phase1-confined-exec-parity` and
`.build/phase1-confined-scoped-qualification` prefixes. The current canonical
gate began before this fixture-source change and is not a clean gate for it.

That gate subsequently failed the repository's custom Haskell style check on
the qualification fixture's case inside a lambda. Its log is
`.build/phase1-confined-kind-current-gate.log`, SHA-256
`8fe5df6020eac83dd4a302e6c04c63bf5de7a45058de1e1b29612f63bb35c0fb`.
The case is now in a named fixture helper; the revised fixture compiled with
warnings as errors and passed targeted formatter and HLint checks. The revised
source, binary and build log SHA-256s were
`bc4cb0fdb61ccfee25196b553920b0cd39c898337d1b64f54be1411ce6132d4f`,
`b4ee204c3f5c6ed1a10f4fffd04baf809c7f689106f8a6e81856191e73fa10f7` and
`2a4e44d15b5d1368effabbdb409c7b115e1276e12d61f95c494ccfbb3bd0fd4e`.
The binary and build log use `.build/phase1-confined-scoped-style` as a prefix.
This fixture revision has not been rerun under the manager, and a clean full
gate remains required.

The sealed bridge client now rejects a bounded absolute selector containing
`..`, a colon or NUL before opening endpoints, and uses the shared sealed-file
observation. A disposable before/after fixture showed the retained pre-fix
operator marking endpoints selected through traversal and colon-containing
paths; the revised operator refused both without touching the locks. A
separate valid-path kind/client fixture still reached the synthetic read-only
broker. Two focused warning-as-error integration cases and targeted formatter
and HLint checks passed. The valid-path fixture was unconfined and does not
establish endpoint ownership, daemon authentication or a real lifecycle.

The client source, integration-test source, configuration document and retained
operator SHA-256s were
`e7d8848fbdcdea2bfc0918d78dd72ea103b324b9d482b0cd07900d25bc7ba49d`,
`b64b090fee1a819f1e16741b95ea8b22dbf648176f7b612b5960a4a040eeb036`,
`d39560215bf7bf9e7897d9cbba49d290385b423b0f19f5d4288cb284fef7992c` and
`e32fa0e762574e2ea167f14751c117f41a97ca76f9bd5fba09d0d526e31cd091`.
The before/after fixture and its two logs SHA-256s were
`73bac5e41bdcf2851d938ec3b8fb1964a0361940fb94058e28386e0cb052b7e4`,
`f98254642ff66becb3800f79271587fe43879ff729d143235fb0c17dc04b8832` and
`0ea26dc50465fa22eb31f71259fbdcc0788220e7940a7863a6f1a6d32a2fd7c5`.
The valid-path fixture, output, request transcript and focused test log
SHA-256s were
`8d8eaec7aec4aec9aceadce8678c3fe81a214de326000147464c446525e024a6`,
`5bb64b3e647b14c1dba2451903ca80247675af9f64ff61ac786f5be41fe3f320`,
`ad409c45a713a3cc5d6f33d5867d7304db46ce2d4cf41e00fc2017e99e10c1cc` and
`b33cf93fc4f7322027ad64a714409ccadb148d5b8323a2835e1380841276294a`.
The evidence paths use `.build/phase1-bridge-path` as a prefix. The previous
canonical gate was stopped after this source changed and before rebuilding;
its partial log is `.build/phase1-confined-kind-style-gate.log`, SHA-256
`06f31dab3ab1c9dd5087418f98685099ee2c61e21282e9a603550c4f80ef464c`.
A clean canonical gate is still required.

The connected-Docker integration selection passed 43 cases after the sealed
worker changes. Its log is `.build/phase1-sealed-worker-connected-regression.log`,
SHA-256 `9cae3b92d757e9d1e7feb8edfbab425488441d415a757f038ce9af9965a05405`.
The earlier canonical gate completed successfully in
`.build/phase1-docker-listener-integrated-gate.log`, SHA-256
`a71c9f1a5330f2018a01f30467a2afbb1c3441aa39a7522ec2e2ee012401e22a`.
Source changes occurred while that gate was running, so it is not a clean
gate for the current tree and does not close the phase.

The next canonical gate stopped at the doctrine check because the new
`PRODBOX_KIND_BRIDGE` read was missing from the environment-variable registry.
The failure is `.build/phase1-sealed-worker-current-gate.log`, SHA-256
`37b2d6367cf49a2dff8b4348e7c424af43a431b28326a3927be2eb0c710cec62`.
The registry now assigns the non-secret subprocess endpoint selector to its
client module and configuration documentation explains its limited scope. A
warning-as-error focused registry test and targeted style checks passed; the
corrected full gate still needs to run. The checker, unit-test and
configuration-document SHA-256s were
`53d962d4dd7fb1e542c5d73b2f7ab92253a02b8a3cd1950435ad58749525376e`,
`27b7fc036173e0cbf3ddf0a288781c5e247078e7b929a40f45b9322e4c2935a0` and
`2ecadeeaa5e1bcf3ab23994544f70f183eebc26ff46a8001d72ffb9fffd6d870`.
The focused test log is `.build/phase1-bridge-env-registry-test.log`, SHA-256
`f923de6eef417c34dfc72ffa909908e3a1a18673b96a6d7882227de6e8656309`.

The worker's retained-client check now compares file identities as well as
descriptor numbers, so a duplicated descriptor to the same inode is refused
before restrictions are installed. A focused warning-as-error regression
exercised that duplicate; the confined kind/synthetic-daemon fixture also
passed using a launcher rebuilt with this worker change. Targeted style checks
passed. The canonical gate started after the registry fix but before this
change, so its eventual result cannot be a clean gate for this source state.
The worker and test source SHA-256s were
`15b487225e56e74e0a44f076f5f4a6fdf8af735d38bb943a334a95c13096dad9` and
`6b41cd0179e0b742da36bcb353f04fcbf5ce6a7c434deb4764bf1eb3207fcebb`.
The regression log, launcher, composition fixture, output and trace SHA-256s
were `dc61fae0650434297a0b32efa3d858c47b4d2e511dca55ed88cedaa27c0fe284`,
`c1e2539f3f09ea81b57d327ecb18a8849daede8ff0890ad55c6fcd0b60b435ae`,
`10931cdf6b8bb62f0fefa23362901834fa31a75cd093ef29ef613c9d6f85fc44`,
`964903954066ba92ebb8f5ce367be594d0ee62c13d44e2ca09c8ce526a7a22d6` and
`41c250635afa0c640400b4d15140ff8d00054f221aa513642bbdb4d5c6b2f416`.
The evidence paths use `.build/phase1-sealed-client-alias-test.log`,
`.build/phase1-sealed-alias-launcher` and `.build/phase1-kind-alias-client`.

An additional offline fork fixture exercised the confined worker with the real
sealed kind and operator client and a synthetic FIFO server. It observed the
expected Docker inventory request and lock release; its network trace contained
no connect call. This did not exercise managed admission, the real broker or
Docker, and is not lifecycle acceptance. The fixture and output are retained
under `.build/phase1-confined-shim-final*`; the independent read-back reports
the disposable root absent. Their script, log, request record and trace hashes
are `c89a6702d4afead83754ec455910f3a01665c54019ad01e6012fb7bdb3b896f8`,
`12ca6c0124de046b2ccd566a247d7454e3fd9e5d0eac5f67df68ea0fdc30a6a3`,
`22fa6633a96be5ea4f847bc86b10d1309fbb849cd137e027cb78074e1663a55d` and
`6bac2e35f041eb4ead78305c4e203c5e7a623287893fd4cb842da13c89c8b4e7`.

A separate offline boundary probe used the same worker preparation to execute
a sealed Python program. It observed denial of a read outside allowed roots
and `EPERM` on an Internet socket, with no connect call; its disposable root
was absent afterward. The initial fixture used an unavailable Python 3.11
path and was corrected to the installed 3.12 path before this observation.
The probe source, driver, log and trace under `.build/phase1-confined-boundary*`
have hashes `19a1f0d77b8433c6f24a1a4a8c96f145362ae5e17cd6adf322d9481dab31b339`,
`4873cfc288d7990f98c72744fe2a4ec8f2b0e92c6096bcbaaf684be935862a1f`,
`28d3df3779cc789c7c8c2a6f5cadc7ecb58d817693f79733a17978a49a92f1cb` and
`8987b1e42a16492141d17b7a8fd0495ec145bb8a8a932970b569d5cfaf8618cf`.
This controlled negative is not a source mutation or a substitute for the
public scenario and its independent observations.

The read gate now recognizes the exact cluster-label inventory request emitted
by kind and translates it to a query filtered to the selected cluster. It
returns the selected label only after the existing container identity and
label validation succeeds; a foreign response fails closed. This is a scoped
projection for the selected deployment, not a global kind inventory or an
absence proof. The warning-as-error integration build and focused fixture
passed for selected, empty and foreign responses, including an assertion on
the selected Docker filter. Pinned formatter and HLint checks passed. The
first test selector matched zero cases; the final run selected one case in
`.build/phase1-scoped-cluster-inventory-final.log` (SHA-256
`e083b7c5944c1f217845ae540edf7106b76b79b7c741f7edc3f07c35a7102a40`).
The gate and test source hashes were
`f81e249ac7bff8d649bcba34154c01a3deb6d54b1408854fa1be76ded6b18ce1` and
`f017d3d8d0093ea8219011dac0c722cbc716148b3ecbb78953687ee2f5d11e9f`.
This fixture does not connect the confined worker to a real daemon or prove
the public lifecycle path.

The bound FIFO composition fixture now sends kind's cluster-label request
through the actual operator client, read gate and connected synthetic Docker
server, checks the selected filter, and then verifies refusal of a pull and
server settlement. Its run log is `.build/phase1-cluster-bridge-run.log`
(SHA-256 `1f3f0cca30ea2208978836abf94f4efaeb184611037d846c72287e1a78fb8e54`).
This is still a fixture and does not establish real Docker or public lifecycle
behavior.

Worker preparation now has a descriptor-relative client-link operation for an
already bound bridge. It requires a sealed close-on-exec descriptor, refuses
an existing entry, syncs a new link, and distinguishes an incomplete attempt.
The caller must authenticate and retain the client descriptor, exclude other
writers, settle the worker, and recover any retained link. The focused bound
scope fixture checked unsealed and unavailable inputs, creation and existing
link refusal. The warning-as-error build and focused run are
`.build/phase1-client-link-final-build.log` and
`.build/phase1-client-link-final-run.log`, with SHA-256s
`cc54deac402a37b2d4bc29731dfe3ed241363f0760b845beedbc96951cb93053` and
`341e942e9c8e53f7686c77587a7e6ed6050dcedc7ab60b10278a2fb277c51141`.
The implementation and test source hashes were
`8cc1253b3528e87ee133789f2400a130288e9e6a8850091da70a74004954fda7` and
`d5930bfcb78b21bfa7e0f764cf865cbd375cdfe1921883d2a3aab1946fed2752`;
pinned formatting and HLint checks passed. Public integration, recovery and
real-system acceptance remain open.

The bound read broker can now run alongside a worker action, cancel and wait
for the other action when either finishes, and return separate worker and
broker outcomes. A local FIFO and synthetic Docker fixture exercised normal
worker completion and early broker rejection, observing the cleared or
retained in-flight marker respectively. The warning-as-error build, focused
case, pinned formatting and HLint checks passed. The source and test hashes
were `31e5c7d3d23932623f160669b44e557b6ec1ec4671fdb99eba0461ba01363fb4`
and `76805722690b5d34df97ba7fabb51dd9ad36b67086c60ba04712348d35c0f060`;
the build and run logs under `.build/phase1-bound-worker-final-*` have hashes
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81` and
`2b32eb0b1ea82b11aea1b1987c48208951ec63cf383e69438a546ef23c1c00b1`.
The caller remains responsible for deadlines, managed-process settlement,
daemon authentication, effect admission and marker recovery. This composition
is not yet connected to the public lifecycle or real Docker acceptance.

The kind adapter now composes the recovered operation roots, client-link
preparation, scoped read broker and managed confined `kind get clusters`
worker. It returns broker and worker observations separately; callers must
authenticate the held artifacts and Docker session, bind the image, prove
root disjointness, establish admission and recover the retained link and
marker. The warning-as-error executable build passed. A bound-root fixture
verified that invalid sandbox and image inputs refuse before link creation or
use of worker capabilities; it does not execute the successful managed path.
An initial test build failed on assertion precedence; the corrected build and
focused case passed, as did pinned formatter and HLint checks. Evidence uses
`.build/phase1-confined-inventory-*`; the adapter and test source hashes were
`b728551c1819ec8158acd7bf263959cc6123904629a86c7ca1ddffe0a35c1ab2` and
`06d40f7a9389c69009dc2e61b59514840a807629f638c8801ac7ae825392c40d`.
The executable-build, failed-test-build and focused-test logs have hashes
`53152551a4b8f57ccef9f27f255acefbb9fa42c7934ac11099963bb46ba19dd4`,
`6caa39712c9506f451b02f9ca21398378da57896fd340c4f1843b0f3270a60ce` and
`4a640e1c28a6579b30f59c57fe8c1db336cd9379356927268863f3e6833ff557`.
The successful managed composition, public lifecycle, cleanup and phase
acceptance remain unproven.

The confined inventory result now retains whether the read gate successfully
interpreted the selected-cluster inventory request and whether the in-flight
marker was observed clear. Its interpreter accepts a scoped result only when
the operation and endpoint remained stable, the worker succeeded, the broker
was settled by cancellation, the request was observed, the marker was clear,
and output contains only the selected name or no name. It remains a point
observation, not an ownership or absence proof. Focused fixture cases covered
selected, empty and foreign provider responses and rejected missing request,
retained marker, foreign output, failed worker and early broker outcomes.
The warning-as-error integration build, both focused cases, pinned formatter
and HLint checks passed. Source hashes for the read gate, kind adapter and
test were `58a60eb1acfb56e0dfe8c1efaa235170fd367f777ae1c2b0fe7db98dfccf5284`,
`1bc3be29e601448072a7624376fea1ea1ec51c53367b20309ca1dfc5a0dfcacd` and
`940051970a258b6fd697d9649e8944b31b14f000a2a48502f6687f1914c8c4e8`.
The build and test logs under `.build/phase1-inventory-proof-*` have hashes
`852be0f91d35b37a7affac2efc7c145de2cbeb3071d03b83ae4e42fb010e7037`,
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae` and
`8ceeea05213c89e1365f047102a2acd0084b857e6b829661f3e2d14169801498`.
The successful managed path and real provider acceptance remain unproven.

The confined inventory adapter now attempts exact client-link removal only
after the managed worker returns, the broker has settled by cancellation and
the in-flight marker is clear. The link-removal primitive checks the held
sealed descriptor, root recheck, symlink identity and exact target, syncs its
directory and reads absence back; uncertain and foreign entries are retained.
The interpreter also requires successful removal. A bound-root fixture checked
refusal when the recheck fails, removal and absence, and refusal to replace a
foreign link. A separate fixture checked that a missing cleanup result remains
unconfirmed. The warning-as-error integration build and both focused cases
passed, as did pinned formatting and HLint. An initial combined test selector
was rejected by the test runner; the cases were then run separately. Source
hashes for the link helper, adapter and test were
`46e76153a19c68f3b3f38eb979b240393ceadccced4660a8a6e9d19d18997b9e`,
`bd9a1c0cc3967b955dd3a1ecd1835d230fafcedea17eea2ca60ef24274bad250` and
`d6fe49052885f281a36ca999be73488524ef4e4979c8ca28819fbdaed866a2f8`.
The build, rejected selector and two test logs under
`.build/phase1-client-link-cleanup-*` have hashes
`862437adc370ba7c0e4fbb25882b1158f3366c083c24d4b1f81b41b4ea5a8564`,
`e74a9ddc24c17935d647255bf9ee43b502d43c6c12ac443ed60a6ce20ac7ff61`,
`daafe2ed2a66624dcdc87fecf7739df6a4eb688d783b3f6317863f9b48d76462` and
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae`.
This does not recover stale descriptors after a crash or clean the worker
roots, and the complete managed and public paths remain unproven.

The confined inventory adapter now checks the sealed descriptors, inherited
flags and distinct sandbox identities before creating the client link. The
managed launcher repeats the same observation immediately before child
execution; neither check authenticates bytes or excludes concurrent changes.
A bound-root fixture supplied a sealed client and unsealed kind descriptor and
confirmed refusal with no link created. The initial warning-as-error build
failed because the renamed helper still had one child-side caller; after that
caller was corrected, the rebuild and focused fixture passed, as did two
client-descriptor regressions and pinned formatting and HLint. Source hashes
for subprocess, kind adapter and test were
`0637321d1ea077efa122004b542b7385f6d4eb6ab5e6f2c9d8d5a25e75f9c1b0`,
`f1e8654059386c67e503c2e0af093a7eff964dc9cb65fef88fc043051aba6f60` and
`be74d2c762119877481da0bb590b67016e49ac01a0a3ec1b6e4909dff9c0458a`.
The failed build, rebuild and two test logs under
`.build/phase1-worker-preflight-*` have hashes
`211a3a512e46869194be7052b0b21c01fedb6c81b48e5b8a0874fe663005313b`,
`76c271f40642d79e8aa5777ec2830684a0966b2e976ee4dcd1969319f3ff7526`,
`4f55869a7a097fb7a4ff6ce85e5ae98df71029319e8c05987227c054ce4eaa5f` and
`e2a7dd4553f01d6b352d80c24ae206b8f9e61688e13f4599e41d817273819310`.
The successful managed composition and public acceptance remain open.

The read-only managed inventory adapter can now hold and recheck the declared
kind artifact, seal its digest-verified bytes, and separately seal the running
executable against a caller-supplied trusted digest and funded limit. The
verified-result interpreter requires the kind artifact to remain stable across
the operation. The caller must still authenticate the Docker session and image,
bind disjoint roots, establish admission, fund execution and recover retained
state. A local fixture used a pinned kind binary and the test executable to
check both seals, refusal of an invalid client digest, and preservation of the
callback result when the kind artifact changes. It did not run the managed
inventory. A focused interpreter case checked that a changed artifact remains
unconfirmed. Both warning-as-error builds and focused cases passed; pinned
formatting and HLint passed. An initial `--match` selector was rejected and
the fixture was rerun with the supported pattern option.

The kind adapter, daemon fixture and integration test source hashes were
`c8988882f3003a1a7ae8aea00c7b78ce8a51362221731661e5cae59a4f1566f0`,
`89289aa160d5e8563524376843508297ca6023112d52ddf0a670c74014255d28` and
`aeaf5566e61c3ad41d4d624505f78b0dec2b5bc6573737f30e13affe541f94c9`.
The rejected selector, current daemon build and test, and integration build
and test logs under `.build/phase1-verified-*` have hashes
`818cef81d35577c76a5732316c5742f0ffc0204523ea384a1e2a9484ff10269f`,
`dd13ec865c7d5e2bf2e8d7860880f0ccafc5cc11b3bd57e324d2b2717376e542`,
`9ed173cc0e857de7d11514560d1df17221b3175c6dd376e669c56690573536b8`,
`1bb4dc26d3b6bdf1592f556264845c722361affbb5ab8e9ecd75ee5b0729b3b2` and
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae`.
The managed composition, recovery and public acceptance remain open.

The confined inventory adapter can now obtain one held Docker connection,
compare its daemon and socket observations with an expected identity, and
recheck the expected binding around snapshot and worker work. A changed
binding retains the underlying result, and the connected interpreter refuses
changed or unconfirmed peer/binding outcomes. Matching observations are not
daemon authentication, effect admission or proof of prior settlement. A
synthetic local Docker fixture checked mismatch and unavailable-binding
refusals before worker preparation; a separate interpreter case checked
changed peer and binding outcomes. Both focused cases, the warning-as-error
rebuild, pinned formatter and HLint passed. The first test build failed on a
shadowed fixture variable, which was corrected. Adapter and test source hashes
were `8f62ef9d122c615d9e73a11dffe1d471ae3522e2db6cb8b4450a4f1a406f9150`
and `e500b02564eeae7a85d8244eeafc17be2cfa67d1b2f6ceacc5bcef01e604b912`.
The failed build, rebuild and two test logs under
`.build/phase1-connected-inventory-*` have hashes
`40a45f6f9f20d9b8a179b0901ef525059ab5b9331b39836c8e3028b91f28590c`,
`1bb4dc26d3b6bdf1592f556264845c722361affbb5ab8e9ecd75ee5b0729b3b2`,
`c6d8bb24ec0bab8fd7414dfea0d0c42f17ded7a976928cddee0239e742e0db37` and
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae`.
The real managed composition, authentication, recovery and public acceptance
remain open.

An offline composition exercised the real sealed kind executable and current
sealed operator client through the repository's bound FIFO read broker, using
a synthetic local Docker server. The server observed the exact selected
cluster filter; the gate observed the inventory, the client cleared its
marker, both fixture actions settled and the confined worker trace contained
no connect call. This fork fixture does not exercise managed placement,
admission, real Docker or the public lifecycle and cannot close acceptance.
Its first attempt refused before executing kind because the fixture supplied
`/dev/null` rather than the required stdin pipe. The driver was corrected;
the first root remains at `.build/phase1-real-broker-k6fvn52g` with its
synthetic socket and FIFO paths, while read-back found no broker or launcher
process and the successful fixture root absent. The earlier unrelated managed
qualification refusal remains unresolved.

The current operator, broker and worker binaries had SHA-256s
`82f76a9d49e26b0602ed37bbb719fcba38b8bcb32d72a93052789ff705942fb8`,
`5bbc1cdb07c54193f0b4a6b9c0022ac4d31ad3aeaba037954cd3bfb59b5205fb` and
`4b4864b572035c306c6da562c9efb1e0317c26614bbe54b2612fc318abe35234`;
the retained kind executable was
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
The broker fixture source, first driver and failure, corrected driver and
result, request transcript, worker trace and independent read-back are under
`.build/phase1-real-broker-*`, with SHA-256s
`8b0e7d0a1b88ea4a42a5f947c6448f1ca5f6ab431f27b076f88d9abca784cd4a`,
`c13efbb937ff774f269fa4e92662f3120a1a08366c1e684ef00ad618617fef1c`,
`ce7096078d0842a1f1b9d6e539c562ff0c50498d1cc20d4c5ce72fcf934dafaa`,
`aad985adf7d0bd125349c73b5acd6a9001762499ae029e596ad3bd1857014906`,
`e159584d58ac5b8d504b33a6755e7027a7631723d7da250bdad000778970c9eb`,
`f33e88a686bf08d175a235d8538fc327aeb7a0aa83ee18d6941d279bcb03096e`,
`65283dc92ab9154366a1e616d226ec6b09136f50770c857581c0ed33654343d2` and
`e91e023bd46495df517141d4884f4e27cc228a03f816421f6a2d45b45886e2f2`.

The confined inventory worker now uses a gate that accepts only the selected
cluster-label inventory request; other otherwise supported Docker reads close
it. Its recorded path obtains the expected daemon identity from the same
operation's durable node-image intent and rechecks that record through the
connection and worker observation. The caller must still bind the image to
the inspected archive, authenticate the daemon, establish admission and settle
prior work. Focused unit and integration cases passed for the restricted gate,
missing record and a recorded identity mismatching the held synthetic daemon.
Warning-as-error builds and pinned formatter and HLint checks passed.

The real kind and sealed operator client also completed the offline confined
FIFO exchange through the new inventory-only gate against a synthetic local
Docker server. The server saw the exact selected filter, the marker cleared,
the worker trace contained no connect call, and independent read-back found
the fixture root and fixture processes absent. This is not a managed or real
provider acceptance run. The gate, kind adapter, unit and integration sources
had SHA-256s `e6d5e8de5018e6682c007baa317d030dfa12b2736ee93a0d4245f46a495054d3`,
`c07f5bcd08652a953ff0b55654f1f65bc5dc9c5ad99f42221ee523aaed6159f3`,
`9988b79e819a342fed41166bd25ddd2f41f28b559a0df38cfbdcc5ca94d2c08c` and
`52ae4f942726836a11d64313734ab7830cbaffb057d41d854e7f4e41bce37123`.
The focused gate and record logs under `.build/phase1-inventory-record-*`
have hashes `a9d727d2fb7136de8685a505d9cbb554b260292dafbfffc8d5247815d38ea84f`
and `c6d8bb24ec0bab8fd7414dfea0d0c42f17ded7a976928cddee0239e742e0db37`.
The fixture broker, operator, driver, result, request record, trace and
read-back under `.build/phase1-inventory-only-*` had hashes
`d4b4055f8535560104d12c314b95f0f7f1316bb48599b4737d80a9945c2176db`,
`08a247e118ceb8981775c5d5b421f22ff982fa9453920bb90b88deec4fbaca4a`,
`288b6c01e62026e2bc68a11b86e0fb77cbb812bf2f80daa83690a4bb8dfe6c00`,
`ca467aec9f582495a40d17fff34288a5b12365278354bc78678333097fa3fe25`,
`f33e88a686bf08d175a235d8538fc327aeb7a0aa83ee18d6941d279bcb03096e`,
`45705ff5a76a43738967189a150b4624b275e6fe8b2d59567784615975c687c1` and
`23b4d2e08e75994333254a78c9ab9e5155d23f1ba28d68ea4a3169a7491bc4f7`.
The previous managed refusal, public integration and required real acceptance
remain open.

The recorded inventory path now compares its image ID with the durable
node-image intent's configuration digest and rechecks the complete validated
intent, including manifest, staged digest and size, rather than only the
daemon observation. A local fixture changed the recorded manifest while
keeping the daemon identity constant: the full-intent observation changed
while the older daemon-only observation remained equal. The fixture also
checked missing records and mismatched configuration digests without a Docker
request, and retained the existing foreign-daemon refusal. The focused case,
the existing held-record regression, warning-as-error integration build, pinned
formatter and HLint passed. This binds to the record; it does not independently
verify the selected archive, authenticate the daemon, or prove a managed run.
The intent, adapter and test sources had SHA-256s
`2a2b326a9d77c15d8ae0384e7619dbede05a2e33da69c2a733d85f052d66eb3b`,
`b174d89764de87d0ead58d7c5c41d18ffea71c9499a6ec3098d5e434a89d8fa6` and
`b1cf86c6cd3175cce6d9b59c8c44f29f3ea36fd8f5b66f367d6e36db619d9a48`.
The final build, focused test and held-record regression logs under
`.build/phase1-image-intent-identity-*` had hashes
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`fb45489ace37d0c49ebc3e49acdc68c526c6b91c8e463999521caf39af548e30` and
`fc32def00030af0f1d82478cab751c8401abb998ee35df5e0cbf05a71966e13c`.
Public integration, recovery and real acceptance remain open.

The recorded inventory path can now hold the independently inspected selected
OCI archive, compare its manifest and configuration digests to the recorded
image intent, and recheck both the archive and complete record during the
read-only operation. Changed or interrupted archive observations cannot be
interpreted as success. The existing public artifact-import/inspection
fixture checked that a matching archive reached the later kind-artifact
refusal and that a changed recorded manifest refused before a synthetic Docker
request. A separate focused case checked changed and interrupted result
classification. The warning-as-error integration build, both focused cases,
pinned formatter and HLint passed. The fixture did not execute a managed
worker, verify a previous daemon-side load, or authenticate Docker.

The intent, adapter and integration-test source hashes were
`cc0b011cd6907bd32e861eeec64acfff965b90629451028dfdf06ea6b890119a`,
`860859a77fbffc30700182986f1ae2df2185526bf2a4b1824e95deb5141c4c11` and
`8311aecf6463696239ea276ddc0a76b5f7f21d0f82d3a0cadf0961eb96333d18`.
The final build, archive fixture and interpreter logs under
`.build/phase1-archive-bound-inventory-*` had hashes
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`9fc9be44eff770b6b05ef0ebd4867c573aab7c872296ffb405ebb08fbad55574` and
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae`.
Managed composition, staged-load settlement, cleanup and public acceptance
remain open.

The worker-root wrapper now records whether its callback started or returned
before classifying an outer I/O failure. This prevents a descriptor-close
failure after a returned callback from discarding that value as a pre-effect
refusal. A controlled fixture closed the borrowed scratch descriptor inside
the callback and observed the returned value as unconfirmed; a subsequent
root observation remained usable. The warning-as-error integration build,
focused case, pinned formatter and HLint passed. The current result preserves
the value and unconfirmed classification, but does not retain detailed I/O
error information; cleanup/error reporting and real worker settlement remain
open. The source and test hashes were
`9de2176eeacd14c7b0fa1fe1e0192b755e1d0e98461aa9289cde16c982e7b332` and
`5a72996912e7018a15e2c558b8da0b57d2dad8693e40365e12a315e352d9841f`.
The build and test logs under `.build/phase1-worker-root-progress-*` had
SHA-256s `70b9bf7952aff59b686865c292c877343f2e94f4bf8ef06cc19e4803da049aee`
and `30d34ce49111aebb8038e9ab53c6d853cb2b6e66bf34e15e740b74c52458cc59`.

The worker-root wrapper now retains structured I/O error categories for its
callback and descriptor closures, alongside callback progress and any returned
value. It distinguishes refusal before callback from failure after callback
entry, and avoids storing exception text or paths. A controlled fixture checked
both a returned value plus a close failure and a callback I/O failure plus a
close failure. The warning-as-error integration build, focused case, existing
FIFO exchange regression, pinned formatter and HLint passed. This covers the
worker-root wrapper's tracked errors; the surrounding scope-root wrapper can
still lose a returned value on its own cleanup failure, and other untracked
I/O or asynchronous cleanup failures remain unresolved.

The endpoint, worker-root and test source hashes were
`fc0cbb07b44326bd05ea52ed40eb0a9155d362bf5acc8b35a32ae806420e815d`,
`4393b28d62b2126708d1961f811e6219cdadb1fa336d85ad1ed3fe578ae63424` and
`568708d1889caf7070329a5e474e675488d196b230c0a72c93ab6daae89d960c`.
The build, focused test and FIFO regression logs under
`.build/phase1-root-io-detail-*` had SHA-256s
`e026cf529bcd9e2e656e2c17d3f65e6097e48960fad447759e9a28643c122908`,
`cf0dcfe5c828dbdbce4fe1937dafa2bbd18e9695d47c6d80c5f8702985abc6d9` and
`41d440a889360196670e0d2bddc8400e812e749fcf64d6db3f83ea54645ea4d8`.

The scope-root walker now has a preserving outcome that retains a returned
callback value alongside descriptor-close error categories, or retains a
callback I/O category alongside close failures. The existing scope helper uses
the same walker and retains its prior callback-exception behavior. The kind
lease and recovered worker-root path now propagate the preserving result;
operation status distinguishes unconfirmed callbacks and scope cleanup
failures. Controlled descriptor-close fixtures passed for a returned value and
for a callback failure combined with a close failure. The focused integration
case and all 52 deployment-scope unit cases passed with warning-as-error
builds; pinned formatting and HLint passed. The lease-unlock return value,
asynchronous cleanup combinations, and a fault injected specifically into the
outer lease's own scope close are not yet proven. Other callers of the legacy
scope helper have not been migrated to the preserving outcome.

The scope, endpoint, worker-root, lease, status and integration-test source
hashes were `aa0866eec6737917df40e0d8b197c8be1edb1144058ccee09643b6e70cd47a5f`,
`2cf1b34bf95f1750733c50ec2818c78401e94e95425f71ebd6c638ddbc601405`,
`a6f49ca0589dd93a6c94350f1f93f6af3f446aea218620718f4fede1051d8408`,
`ba6d14ea3468e4d03380f94ed66f06e6e59bbc91674c75e13c14833864253170`,
`c07c1e1d8319ebe06e07560436315f9474ce93dab9d68cc3e2dd9e779d829a98` and
`3aeffe614ce0e8c840e44d1300cf0312a6b7e2289379c833d46f0c6e24236a26`.
The final integration build and test and the unit build and test logs under
`.build/phase1-scope-progress-*` had SHA-256s
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`1fbee8bbd8494da8218e27b5850b11b097f47ca8d0d432108f8b46646faa364a`,
`9b2e036851a0bf263ee931ce8bcc5050267657a7311f8ab12e3b2ce4395222ab` and
`7de1a494ed55e993928001e6eb92616b91384d551c4da54bdaf540d673f5e541`.
Managed composition, recovery, public activation and phase acceptance remain
open.

The lease now checks its explicit unlock result and retains an unlock errno
alongside a returned callback value or callback I/O category. Operation status
reports unlock failure as unverified. A controlled descriptor-close fixture
exercised the real failing unlock together with scope-close failure, both after
a returned receipt and after callback I/O failure. The warning-as-error build,
focused integration case and 52 deployment-scope unit cases passed in
`.build/phase1-lease-unlock-build.log`,
`.build/phase1-lease-unlock-integration.log` and
`.build/phase1-lease-unlock-unit.log`; pinned formatting and HLint passed.
The corresponding log SHA-256s are
`b5790994bd2ba150569bc214c7e2c43788bbfde8d0ea8d307c265450477b0c94`,
`30d34ce49111aebb8038e9ab53c6d853cb2b6e66bf34e15e740b74c52458cc59`, and
`ef4a668a5f52f5e2a5243427988ef9472ed9a2440e288510620bc5a95cc5e4b2`.
The lease, status and integration sources have SHA-256s
`43e8a5be434b6df07493e817ae634472c11498bb60ec496dc5bd737a2fc72300`,
`4655dbac442bd12b80a4c15a48e1f7842c4ff0e001c2d26e0d645154c1fca0c5`, and
`2455f4c7b4a24dd2b59ed873512247e3bf62c30120285a83055b19422a494776`.
This fixture does not establish phase acceptance. An asynchronous exception
combined with an outer scope-close failure can still obscure earlier failure
details, and fault injection through the actual outer lease scope remains open.

The preserving scope wrapper now retains a non-I/O callback exception with
descriptor-close failures instead of allowing close to replace it. Its
structured interruption exposes the original exception and sanitized close
categories; its rendering does not expose the original payload. A controlled
fixture threw `ThreadKilled` after closing a borrowed scope descriptor and
verified the nested original exception, failed lease unlock and failed scope
close. It does not inject into the actual outer lease scope or demonstrate
asynchronous delivery during cleanup. The existing real-thread cancellation
regression still passed. The warning-as-error build, focused integration test,
52 deployment-scope tests and pinned HLint passed in
`.build/phase1-scope-interruption-build.log`,
`.build/phase1-scope-interruption-integration.log`,
`.build/phase1-scope-interruption-unit.log` and
`.build/phase1-scope-interruption-hlint.log`, with SHA-256s respectively
`3d5d10e95800d5fb06e3d52c709add630e940a82cd233d8d31c1e868c7f1f4b5`,
`2051e0a6ba092174e5a2f1347097591eb86ab2cd02c300797bb1dc05353135da`,
`3b6b44294686a6592127ebcb8719236deddac57ce1e8661682a63d609b6d94cf` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The scope, lease and integration sources have SHA-256s
`e38d6ca4908cfe91172784dc124fc46777e9ef94a3ff456b88543f28e808515a`,
`cbc970664de1611d02df335ee1b2bc3f62d33e9c60fbb6c1a6e9ef1329d526ec` and
`e1f7cf358eafcc6b68084e52c0e0380f99a774cbefb17f5c6a74229de390d360`.

The composed inventory now preserves worker and broker outcomes if its
subsequent in-flight marker read fails. Marker observations distinguish clear,
retained and unobservable, and only a clear observation permits client-link
removal or an interpreted inventory result. A controlled closed-descriptor
fixture checked the real marker read failure and the unconfirmed interpreter;
it did not inject that failure through a managed worker. The warning-as-error
integration build, focused case, all 45 connected-Docker fixture cases and
pinned HLint passed in `.build/phase1-inventory-marker-build.log`,
`.build/phase1-inventory-marker-test.log`,
`.build/phase1-inventory-marker-regression.log` and
`.build/phase1-inventory-marker-hlint.log`, with SHA-256s respectively
`1bb4dc26d3b6bdf1592f556264845c722361affbb5ab8e9ecd75ee5b0729b3b2`,
`2346fb2bcb49068a331550117c74159144104966e5fdde90d3b63b41074792ae`,
`690ac3394b155b3ca27b762f611f0c200a64e085be724081eee83e477a707115` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The adapter and test source SHA-256s are
`a6165fe16f80417b5e6f03d04110ec50c46a2c944ec968f3d4169601b8b4506c` and
`eaff6dd41eeb2f12b1de43f7743b154bb19d1a845b3fd1bde5520c8af04b7623`.
The earlier managed refusal and public activation remain unresolved.

The current canonical gate first failed because the environment-name registry
omitted the kind adapter that supplies the bridge variable. The registry and
its owner test now include that producer. The rerun passed doctrine, formatting,
HLint and the warning-as-error build, then failed two of 10,045 unit cases:
both rejected the M01 source preimage after the scope-wrapper changes. The
reviewed root-overlap guard and fault remain unchanged; the pinned preimage was
updated to the current scope source. A warning-as-error unit rebuild and all
27 scenario-evidence comparison cases passed. This preparation check is not
execution or a kill of M01. A complete canonical gate rerun remains required.
The first gate's original `.build/phase1-current-canonical-gate.log` was
subsequently overwritten and its original bytes are unavailable; its recorded
historical SHA-256 was
`85bd24d9a397adf7a305c551bc8118a9bbfdeb6ba912ff6253b9697d29518135`.
The replacement log records a later failed check and has SHA-256
`75bf3366075dd0efec7dde8961bc1485209ab4d580d59122bca75dfe1ab215dc`;
it is not evidence of the first gate. The second gate, targeted build and
targeted tests are `.build/phase1-env-owner-canonical-gate.log`,
`.build/phase1-m01-repin-build.log` and `.build/phase1-m01-repin-tests.log`,
with SHA-256s respectively
`107c11b2b0b2fd68763d04242790cceaf20fdee150091dcc2570db729bcd6644`,
`ccb8dbe65bfbe6b061736e5b0e7726e4a2acdd7a32fd7b33a30be6a14aacb99f` and
`1f9682d5e7e4ea6e9b77577511680952ca566f2c02c28f0c2d973fb093ef2770`.
The checker, reviewed mutation catalog and owner-test source SHA-256s are
`d39fe7d16e6b1c2e1cd2815c5fac35a5babec2ea8966bbbb14075c3c2fb36502`,
`cf17c406df5e635835f1040f9af4a7b9def4ab51d60154043371a1e034dd9659` and
`243ec4069537bbdf08845373c10ab14d0acc7f869c79a56416913af40431b752`.

The corrected canonical gate subsequently passed: 10,045 unit, 27 authority
admission, 35 authentication and 935 authenticated transport cases. Its
`.build/phase1-m01-repin-canonical-gate.log` SHA-256 is
`ba698ccf974caaa6adb70de7ed620082720453c137b75d058b4e782c849d1811`;
the operator SHA-256 is
`dc12982019e65182aa1f09f527ee8dfd44eed94379a69e59ca5e36969bbeaa8f`.
The gate preceded this evidence-only paragraph. It does not establish real
kind acceptance, public lifecycle activation or mutation kills.

The canonical mutation manifest still contained older M01 and M02 candidate
identities after their source bindings changed. It now records the source,
domain-separated binding and prepared-mutant digests from the current reviewed
catalog. A unit check compares each Phase 1 manifest section against the actual
prepared candidate, so stale bindings fail the suite. The warning-as-error
unit build, all 28 scenario-evidence comparison cases, documentation lint and
pinned HLint passed in `.build/phase1-mutation-manifest-build.log`,
`.build/phase1-mutation-manifest-test.log`,
`.build/phase1-mutation-manifest-docs.log` and
`.build/phase1-mutation-manifest-hlint.log`; their SHA-256s are respectively
`c3fdbc69b952375dfc1cea41816317ec859f8b15bb49dd10e98c83bb556be3d5`,
`1293a6a2ccf48ab7d86a223ba21b1d875b14e81c5f03c615b0f7e53cef8c1c85`,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The manifest and test source SHA-256s were
`e9681ccfc4422dc76a6dcbc0eab810b15482f1b74ca95556d17138921bb369eb` and
`f5aba0245f908d57e4de57004ad80ec8b6fd1fd5d9e0ba69108aac2a69d16ec5`.
These checks do not compile or execute the candidates. The preceding full gate
predates this manifest and test change.

Node-create submission now has an internal entry point for an already held
Docker session and operation lease. The existing wrapper calls the same
write-before-effect sequence after acquiring its own lease; the held-session
form lets a future broker compose that sequence without trying to acquire the
lease a second time. A controlled Docker fixture exercised the held-session
path under the real operation lease, including durable attempt and result
read-back. The same fixture exercised admission refusal and uncertain result
handling. The warning-as-error integration build, focused fixture and pinned
HLint passed in `.build/phase1-node-create-held-build.log`,
`.build/phase1-node-create-held-test.log` and
`.build/phase1-node-create-held-hlint.log`, with SHA-256s respectively
`625bbd1cad57bdbff33d5c9490d598a7a88e7715ff877a969988a6fabceb740d`,
`2e96587dc55d8c5b58c4c671fdc6c35fb31b85613e1d7fcdf287321db771fc7b` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The operation and integration-test sources have SHA-256s
`d2a794e0ad000c7da00ad68e1d17e5583a9b10720e55206ea95150398f6d705e` and
`706d9ca4ba754d82747330445eef1031804c17e04c4d96fc7d92712101e94049`.
This does not connect node mutation to the kind broker, authenticate Docker,
establish admission or settlement, clean a node, or complete public lifecycle
acceptance. The previous canonical gate predates this source change.

Node start now also has a held-session form, using the same recorded create
result, exact container inspection, removal-marker, admission, start-attempt
and result checks as the original lease-acquiring wrapper. The controlled
fixture ran the held form under the operation lease with matching and
conflicting inspections, admission refusal and result read-back. The first
warning-as-error build failed on shadowed names; the corrected build, focused
fixture and pinned HLint passed. Their logs are
`.build/phase1-node-start-held-build.log`,
`.build/phase1-node-start-held-build-corrected.log`,
`.build/phase1-node-start-held-test.log` and
`.build/phase1-node-start-held-hlint-corrected.log`, with SHA-256s
`e58439cf5b8c0952eae64c5b1456eda543bda9abc143e2f55ec08d0d37ea815d`,
`39467b971a2e0bc8031e72fbe7cd0bc83bd526581da40312d81bebeacacbad53`,
`59e608d263707ca3558ff90550d2d374ea5633b21eab71512907ca321bffb07f` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The operation and integration-test source SHA-256s are
`6149c44f07e28a0ad141dd15e4fcd9374cce75636058c6d34ca0935a051d4327` and
`4ac307df44dee32ef8664ff8dbca96aeb52b71dd7a058be813f8a5721cd630c9`.
The broker still lacks an admitted combined create/start route and recovery;
this fixture is not real kind acceptance or a current full gate.

The held-session node path now interprets the exact recorded kind argv and
sequences start only after a successful create response and recorded create
receipt, retaining both action results. It rechecks the complete recorded
proposal across both effects. A controlled Docker fixture rejected altered
argv, then exercised create, repeated inspection and start under one held
operation lease, with create read-back and a returned start receipt. The warning-as-error
integration build, focused fixture and pinned HLint passed in
`.build/phase1-node-run-held-build.log`, `.build/phase1-node-run-held-test.log`
and `.build/phase1-node-run-held-hlint.log`, with SHA-256s respectively
`01fdebf180e793ef1980b72dbee98697e3a1a1297a5282a7c606bd905f3b6cce`,
`2735123bcb35ae999ea1d933f9561391d73f578d98bab23ca4f2271f095b485b` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The operation and fixture sources have SHA-256s
`9e095b567015fb16496086557205b52842280a0819af1d1a4359f82da0caf9f4` and
`4f7f40fdec21504499659a4c8b35920ba2e47fc6952db199b9ccdeedf74579e2`.
The broker does not yet call this path. Daemon authentication, admission,
settlement, recovery and actual provider acceptance remain open; the fixture
does not qualify a real kind run. The current full gate predates this change.

The bounded framed broker can now dispatch a node `run` through the held
create/start sequence. Its read gate is derived from the recorded scope and
image; the complete proposal is rechecked around each request. Refusal closes
the broker, and the node action remains observable after a later refusal. A
controlled synthetic Docker fixture exercised the framed create/start path,
altered argv, a stale operation binding and a refused pull; the existing framed
read regressions also passed. The warning-as-error build and pinned HLint
passed. Initial builds failed on a missing constructor import, name shadowing,
and a fixture-local pipe helper; those failures are preserved in the
`.build/phase1-node-broker-build*` logs. The final build, focused fixture,
framing and duplex regressions, and HLint logs under
`.build/phase1-node-broker-stale-*` have SHA-256s respectively
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`fac3bc6d062a1c42aed35dcf942bc9bbdc7335cf4084bf5793ad481b2b37450a`,
`7e77ef0367aaa4d6f980d2b467407d04ec87b919af9d92628fe0dec843da4cf8`,
`0047194f8c31c580f245d494c1621d771a8caf81babde84625bf026034e99869` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The protocol, endpoint, node operation and fixture sources have SHA-256s
`b77b3f49f258b9a8b0724912bf927d763e6e9374164d8204e41847ab4e040b36`,
`bb3d8d9fa22f271f5d7d6b8b45c87527bc679670714879714682816e295b0bcc`,
`c999706ebcadee93541e02bac63bfc64c9de916cf32fe57b9d0511e5ac81c2ad` and
`271f25874263ba358de1b74d360345d8a91f4883a25c2cca665c60baefd99c05`.
The endpoint-bound form and managed kind worker have not been exercised with
this broker. A real owner must establish daemon authentication, admission,
worker settlement, exact cleanup and recovery before activation; this is not
public lifecycle or Phase 1 acceptance. The last full gate predates the change.

The synthetic create/start fixture now uses the descriptor-bound worker
directories and FIFO broker endpoints under the held operation lease. It
observed the marker clear after a successful reply, retained after a refused
pull, and the node result still available after broker settlement. The
warning-as-error integration build, focused fixture and pinned HLint passed in
`.build/phase1-node-broker-endpoint-build.log`,
`.build/phase1-node-broker-endpoint-test.log` and
`.build/phase1-node-broker-endpoint-hlint.log`, with SHA-256s respectively
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`a1868d89203a8e778b5fc063ffe4aaf0a1c28ef33d85f8edccfc1b205e7cf327` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The fixture source SHA-256 is
`df9d56a52ff9c0427cb2645ac13b46fe367206b812cfd2a2e005255cccd6a629`.
It does not execute the managed kind worker or contact real Docker; real
admission, worker settlement, recovery, cleanup and acceptance remain open.

The paired broker/worker action is shared by the read-only broker and the new
node broker. Existing cancellation and early-broker-exit fixture cases and the
endpoint-bound node fixture passed after the refactor; the warning-as-error
integration build and pinned HLint passed as well. The build, pairing test,
node fixture and HLint logs under `.build/phase1-node-worker-pair-*` have
SHA-256s respectively
`b7b9c8f21b81982f25ddd0f79de30067c4d4cd69a67871e5e8580514d653bb5b`,
`3d7afcaf1fd49142ceeb49af4a360dc2b964ba0a2f1bdbf77436c598aa97c176`,
`98367c8d734e733cab063fb614a38c57e6ca73b9275779ad45a694ea69a171e7` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The endpoint and node-operation sources have SHA-256s
`3667cc081a44a2a7784d817fd93b98c385650f4b9220147da636a7d895f94951` and
`78d6c6f9b7b712651f98ae1338779714e98b0f6a503d14d2e529509d96047e03`.
Those tests do not pair a managed kind process with the node broker or prove
settlement of a daemon-side effect. The current full gate predates this change.

The retained node proposal and endpoint-bound broker are now paired with the
confined managed kind launcher. The worker receives a plan-derived local-image
configuration on stdin and `--retain`; the result preserves separate broker,
worker, node and marker observations. The client link and worker roots remain
for a separately established recovery path. A controlled preflight fixture
refused a missing kind-tool declaration before using worker capabilities. The
warning-as-error integration build, focused fixture and pinned HLint passed in
`.build/phase1-confined-node-worker-build.log`,
`.build/phase1-confined-node-worker-test.log` and
`.build/phase1-confined-node-worker-hlint.log`, with SHA-256s respectively
`89b86b572f501737b9f61dcd75aaaa854be57aca06dcc64e49f07dd4bec6cb79`,
`d2bd81fa42fe4e3d62f0cecce0ef2711489fb71adc2c577cd621feee8699d8ef` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The worker and fixture source SHA-256s are
`eefd25bf343997a2dbfac0c92e5b33c120f8ec3ed8e60f8568d6d318587a0220` and
`2eefd44ddfe7123a4f33707b0d51ac9ea5212b5bcd866af91430907cc41ad460`.
Separately, the installed kind binary SHA-256
`50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`
accepted a stdin configuration in a temporary fixture with a fake Docker
executable; its image request was refused and a network syscall trace showed
no connect calls. The fixture, log and trace under
`.build/phase1-kind-stdin-preflight.*` have SHA-256s
`530440174cdb32a9ba97a6ca7952ad90ffab2b699e850a53d02933be7ed42b71`,
`2d235f00e78be04c0021ee5b5d5eb65ceea187dffe20bbaf275e00b2eacf7154` and
`07ae6785af5d3de0dbb97d3ba86ba7270e1292d811d1e08423cf64a96514f23b`.
The composed managed path itself has not run. It still requires authenticated
artifacts and daemon, admission, exact cleanup and recovery, and its broker
does not yet cover all kind requests. No real lifecycle acceptance is claimed;
the last full gate predates this change.

The confined node attempt can now hold verified kind and client snapshots and
carry their final artifact-stability observation. A further entry point holds
the inspected node archive, compares its manifest and configuration digests
with the recorded image intent, requires the node proposal to name that image
and daemon observation, and rechecks those records with the held connection.
Controlled fixtures refused an undeclared kind tool, a missing node proposal,
and an archive-record mismatch before a Docker request. The warning-as-error
integration builds, focused node and archive fixtures, and pinned HLint passed
in `.build/phase1-verified-node-worker-*` and
`.build/phase1-node-archive-bound-*`. The final build, archive fixture, node
fixture and HLint log SHA-256s are respectively
`89b86b572f501737b9f61dcd75aaaa854be57aca06dcc64e49f07dd4bec6cb79`,
`70f45dd860b0b6a25c475d734a0a34339e981617c90667cd5491e32afe904356`,
`80bf6e90db919950a37cb7df7ae58ec3fe9436e7a692787324a29126ff88a99c` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The worker and integration-test source SHA-256s are
`679d790c8fc2337d45c291126b89548fcaa74c0d023e3fd83486090e203ea467` and
`c6cbe3b1ab3c058c8c8f527f4552567310489f9fe5d81e878f12cc99314c1c10`.
Matching observations do not authenticate the daemon or prove image loading,
network ownership, admission, settlement or cleanup. The successful managed
composition and real lifecycle acceptance have not run; the full gate
predates this change.

Before entering the verified node worker, the archive-bound path now requires
a matching recorded network proposal, create attempt and exact successful
receipt, no removal marker, and a held-session inventory and configuration
read-back for the node's network ID. It rechecks these observations throughout
the worker. Controlled socket fixtures accepted a matching record and network,
and refused missing or conflicting receipts and changed configuration. The
existing archive-bound refusal fixture also passed. The first two integration
builds failed on fixture JSON key types; the corrected warning-as-error build,
three focused tests and pinned HLint passed. The two failed builds, final
build, ready test, receipt-refusal test, archive test and HLint logs under
`.build/phase1-node-network-binding-*` have SHA-256s respectively
`e3b41270acc41b396993ab0daf78a542ee063ca5317658eacc3230ecefffd047`,
`9a405d243971db0d2502d48b38bbe1e818c4c72456bcff80db3e619f27dd8744`,
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`40f6f7a5718cfb1eeb7b1bb8125c32c98bae07f48f1723b832c9fff8a42e8561`,
`22b1845c84ca1e4e142af1b5a9d26d51628c6cebc826b38cd244c176683a86c8`,
`356dfd0f672d1e93b67b0c39450f634067fa25b63a19ecbe79ab12620c23ea32` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The worker and fixture sources have SHA-256s
`42fc2549c815d07f9f6d45a397b85c2b66d09b3d5a4d345bff4d012eb386c8d5` and
`f63d6bf1b2540f969892079c67ec965481b44bdca1320b55ee8cadfd7e044853`.
These are same-daemon point observations, not daemon authentication,
ownership, prior-worker settlement or permission to mutate. They do not prove
the real managed path or Phase 1 acceptance; the full gate predates them.

The archive-bound node worker now also requires a matching recorded image-load
attempt and successful transport receipt, and reads the exact config image ID
and architecture on its held Docker session. It rechecks the image observation
alongside the network binding during the worker. A synthetic archive and Docker
fixture accepted matching metadata, refused a different architecture, and
confirmed that invalid attempt or result records caused refusal without an
image query. The first integration build failed on a shadowed fixture variable;
the corrected warning-as-error build, archive fixture, network regression and
pinned HLint passed. The failed build, corrected build, archive test, network
test and HLint logs under `.build/phase1-node-image-binding-*` have SHA-256s
respectively
`94d64a5b2af384a38f27fe4283e3df4befdf42cfd1926fed666b6bbd2bed632d`,
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`a1cc7e7e8b586ba72281223d6edf769b5e3fdb292f476e223ac3f2efb37b3d81`,
`2a1921a3afcaef9f68b437764ce229fafe8b7c37286671f356239bfdb872cf7e` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The worker and fixture source SHA-256s are
`c9bb14d752b82a9b3d96de60ca93d8b83fa0da8268eb5d65ce99e8d63d61b2b4` and
`1af9e939e77cb3ecd78eb92ce489b4e4a414c5f9a13b6ba34c74c1176b617465`.
The receipt and same-daemon metadata are point observations; they do not
authenticate the daemon, prove prior-worker settlement or image ownership, or
establish real lifecycle acceptance. The full gate predates this change.

The confined node worker now sets kind's network override to the selected
deployment name; it does not inherit `DOCKER_HOST`. The recorded network
create sequence also has a held-session form so a future owner can use the
same operation lease and Docker connection for prerequisite preparation. A
controlled fixture checked the projected environment and exercised recorded
network creation with both a successful and a lost reply; the node fixture
also passed. The warning-as-error integration build and pinned HLint passed.
The build, network test, node test and HLint logs under
`.build/phase1-held-network-*` have SHA-256s respectively
`4ea3f184a4711855de009863273b499041372b1ce75788cee1e45a08d4a529f9`,
`24d68385924d8db1d716f186a6fd43420630c56356824e0f2997c534adb11122`,
`39e2f283e2c35300bf6f738557cb31d10a91db87d3c07b8d3548036ee7c31b15` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The worker, network adapter and integration-test sources have SHA-256s
`7a3531b37d51abbfbf2022b07da963427c799f72a17f472586dace4bafb14ea4`,
`4cdddeafb1085f481a38b548e5134bf24b6b887c475a29516a4d59982857dce3` and
`f1f569113a7ba444cb4f4933e07be785bf7259c5b332c3097e993e9e08785711`.
This is not a network admission, ownership or cleanup proof, and it did not
run the managed kind worker or a real Docker mutation. The current full gate
predates the change.

An installed-kind diagnostic using a fake Docker executable and denied network
connections observed boot-log and role-inspection requests after node start,
then `exec --privileged ... cat /kind/version`. The broker now handles the
first two requests only for the recorded, running scoped node, rechecking its
intent, receipts and held-session inspection around each observation. Its boot
read polls bounded log snapshots and returns only an observed marker. The
controlled node fixture checked refusal before creation, polling through an
initially absent marker, role inspection and refusal of an unrelated request.
The warning-as-error integration build, this fixture, two framing regressions
and pinned HLint passed. Their logs under `.build/phase1-kind-node-observations-*`
have SHA-256s respectively
`d58d5fa5d005c297d14ac1b85735bb10980da4ca04190d318542d27898eb1300`,
`bae3cbeac589aa69b2485fd47a2d8b2b4afb260608cc3ceccfb49532760b4d14`,
`7e77ef0367aaa4d6f980d2b467407d04ec87b919af9d92628fe0dec843da4cf8`,
`37970e837a6e5231eea9babc90998aca8576a0e4b63872d4c6a6581e645cf44c` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The diagnostic script, request transcript and network trace have SHA-256s
`fc4ccffa4bc790bef5eb18aa5a929465d35a199f34e3970ff07be87c7de40a90`,
`85f20f357c10690ffc4951375ca6a035ab7209ae7018da7da12a6690495c9332` and
`6641c84134202a7db137acd5a8f7f7251628f299a66fa57004d872f95c043fd2`.
The Docker observer, broker and fixture source SHA-256s are
`042e583c55e1cf795e8021084c79c56f308070781f90b14dba6e629c3ed0752e`,
`b0000045f5a86b893702289138cd2e7850823b9ea5807a1363b00474408a5abf` and
`758422630c4a0d05de38348b108b2114cd99c0bd0921598ec879269f8fbda9df`.
The diagnostic did not contact a Docker daemon, and the fixture does not prove
real cluster readiness, daemon authentication, worker settlement or cleanup.
At that point the version request was unsupported; real lifecycle and Phase 1
acceptance remained open. The earlier full gate predates that change.

The broker now answers kind's exact scoped `cat /kind/version` request with a
bounded Docker archive read of that file, without starting an in-container
process. It accepts one regular `version` entry of at most 4096 bytes and
rechecks the recorded running node around the read. The archive test accepted
a regular file and refused a different name, duplicate entries, oversize and
malformed data; the framed node fixture exercised the version request. The
warning-as-error build, archive and broker tests and pinned HLint passed; their
`.build/phase1-kind-version-*` log SHA-256s are respectively
`d58d5fa5d005c297d14ac1b85735bb10980da4ca04190d318542d27898eb1300`,
`908ab22c69fbe4a41dd6252ebb645e6e189e50efbeb1cf26fa15e93c6c6af335`,
`2d9ef3f1f27a4b18f9b7f5b8d5567e824ce7136f23fd18013f5ab3d47f7a656f` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The Docker observer, broker and test source SHA-256s are
`3fbed32e31aace07479fa2776eaa30038db5632a1aa42867073d36f33ecc0ddd`,
`fb050d806be88173891e33693efaa947ae34f0e5685bbfafc1d7ef4d6f84ddc5` and
`12ded4e8cf6a7721c452a333cca38597915ff2560762426c6564c74709e2f642`.
An installed-kind diagnostic with fake Docker and network connects denied
then observed an inspect request for node network addresses; it did not run
the broker or contact a Docker daemon. The diagnostic script, transcript and
network trace SHA-256s are
`11624f2561d5e2ba274e4c33ee28991b4c6b09fb946014b47ef078073608189e`,
`6ecb68881971665818ef25f9238bdf56f0c12867a638e02365b6b0a1ff6511ec` and
`74aba2ddd499ee174e6bfe76adc5d0c65dee2f2613fc20cdebef10584c5ba8fe`.
At that point the address request, managed lifecycle, real acceptance and
cleanup remained open; the earlier full gate predates that implementation.

The broker now answers kind's exact node-address inspection with addresses
from a bounded, duplicate-key-checked Docker inspection that also verifies the
recorded running node and selected network ID. It rejects a pair of empty
addresses, malformed addresses and wrong-family values, and rechecks the node
before and after the read. The
controlled fixture exercised the framed request and refused a conflicting
node, injected newline and wrong-family address. The first integration build
failed because the fixture used an unavailable Aeson function; after fixing
it, the warning-as-error build, node fixture, version regression and pinned
HLint passed. Their `.build/phase1-kind-address-*` log SHA-256s are respectively
`84e468e065959ffc7fb16703d7de61b27c7b9baa27c3482f50ed9e4f08179e99`,
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`6eb708fa7895c393682764a917735c3ee3cea6a331e9d41471e86854cc58ff98`,
`908ab22c69fbe4a41dd6252ebb645e6e189e50efbeb1cf26fa15e93c6c6af335` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The Docker observer, broker and test source SHA-256s are
`b3d937c59ca3c67a85766c78cad0d6cb70224d93aa4b6d2c140efabf5e6e12e5`,
`e8c779f5168f34dea2ba0c15da3fe51a62ed3b8289918c65568ee13509fc5015` and
`32de26f732444679a98589307b0dbc71d7d75e4e925c3d9911507346e7ff19cb`.
Two installed-kind diagnostics with fake Docker and network connects denied
then observed `mkdir -p /kind` and an input-bearing copy to
`/kind/kubeadm.conf`. Their scripts, request transcripts and network traces
under `.build/phase1-kind-{address,mkdir}-continuation-*` have SHA-256s
respectively
`dfbe4394fd964c90c9a619d53d80189d8f0a429e2bc6d4e7e211529d71f7ab2a`,
`b88f18fc4743d914a2d86d3ef27d4032dbc6774a1b318654bcdbc792015367bb`,
`6efba2348b122420de53812bc60b4f1e9515a2d11631192d035e2ad384acd9f1`,
`1eb6b8c6306e6db4ccf4b260a3a9a164947b7b7b7bf4d3fd4bbcb01132306024`,
`78c7eee9bf0199e24c08f074ce44e3e9047be21eb51d6d5608382ef1d4da7eec` and
`e7e8e9fc886344aabcacb5ab74bc6d031ac3244fe893027c9e09442f568f2008`.
These are point observations, not daemon authentication or network ownership;
the diagnostics did not exercise the broker or contact a Docker daemon. The
input-bearing effect and recovery, managed lifecycle, real acceptance and
cleanup remain open. The full gate predates this implementation.

The kind Docker bridge now transports a bounded transient binary input frame;
the client reads stdin only for the observed kubeadm-copy argument shape and
rejects empty, oversized or timed-out input. Argument-only frames retain their
existing bound. The read-only interpreter refuses input frames before dispatch;
this transport does not admit or perform the copy. Controlled tests covered a
64 KiB binary round trip, oversize input, malformed and duplicate-key frames,
read-only refusal, and read, duplex, lock and node-broker regressions. The
first warning-as-error build failed on a shadowed name; the corrected and
final builds, focused tests and pinned HLint passed. Their logs under
`.build/phase1-kind-input-frame-*` have SHA-256s respectively
`4822622fcd7d972f61e8fb69c032de3aa6dc2c0fa44f552f7b0751e00f9f697a`,
`87e60c79c37d022b2060627af35508e4beee0dde5cf767c056e86c44feea853d`,
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`07f2804a91ee75d69d79009d2fc8dcab6bd591ff28d072b36a6d73009dbf59df`,
`d6c855a1ef3d88917d884dc408205c7c8ffa4f71ddc9ae650946211b542a7f76`,
`37970e837a6e5231eea9babc90998aca8576a0e4b63872d4c6a6581e645cf44c`,
`f21fa244989a055f61e6c391336c7d88ff56578cfbd7bfd8dba1d8c2f2e99136`,
`b329e12871f1b6df391ea080118c9705fd64a6a7d11923972937ba5cdc657ae5` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The protocol, endpoint, client and test sources have SHA-256s
`e503939c46d02809fce22a625513a1aa83395ccf034dffae78ad868e51f77375`,
`5429e811d3bb5269966df690a739b455d53a4503cd6203400e3bcfb6df22eb2d`,
`757ca54379c090ad3e81efd28d7d11b43419507febfa69b41bb523a512b67b2d` and
`7ac34eb79d83406ca82b061f82866863c5d9217a734d37e8778ac38d59b7afd9`.
A fake-Docker, network-denied kind diagnostic observed a 1775-byte synthetic
input and the subsequent `kubeadm init` request without recording its input.
Its script, request transcript and network trace SHA-256s are
`aa5b439c4f4fe84e40c7ba2dcf7b736a5a4de5bf06ccba8c46a439b8c3927e60`,
`8d07122edcd283fe55ecca6f6108069feb2b3e4d7be3279b49b6b72a5357dfb3` and
`f892a2567108517f3ff5a2f95b92167f7e22d03a28bfd15cb333ca49fc76b63c`.
The client-to-broker input path has not been exercised by a real managed kind
worker. Node mutation admission, write-before-effect, settlement and recovery,
the kubeadm operation, real acceptance and cleanup remain open. The full gate
predates these changes.

The input-capable frame is now wired through the held endpoint to the node
broker, which still refuses every input-bearing request and closes the gate.
For kind's preceding `mkdir -p /kind`, the broker reports success only when a
bounded archive observation proves the version file already exists under that
directory, bracketed by the recorded running-node checks; it does not create
the directory. The controlled node fixture exercised that observation and an
exact streamed-copy request, which was refused with the in-flight marker
retained. The client fixture checked bounded input capture, overflow refusal
and that ordinary reads do not consume stdin. The warning-as-error build,
input and node fixtures, read regression and pinned HLint passed; their logs
under `.build/phase1-kind-input-broker-*` have SHA-256s respectively
`8905f480eac95a0347aa8e034cdbef42e3e04ea3b3bee01b425903906ea5f419`,
`b4f27fd9ca0faa01722f9c4c4650cdf5a2b16acecf69545ffb3bba1b639ffa3a`,
`be38590ed7c1815416123aa6d0ece77d9f520ad17f9806b850f7862f0861c19b`,
`9611a821e05ca6f7ef03f6274a6015426ead2fef1f288004a25c665686b6ec24` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The endpoint, client, broker and fixture sources have SHA-256s
`5a775fce580c71f7098cdf88aa84b3447c5f81e8b570be725cab39ff3c741723`,
`64cf3da66392188bab126a50a6378b0c57321f32abd1ddaf8cfed85fead92f8b`,
`86e07a9ccdc13f751b8a7ee51d481727f30a200a590a390628f08a9b7cb43f84` and
`20bba02e07986a33668da9532da112dd3064536a79160bb32af9ab988a9b7712`.
The fixture does not run kind or a real daemon. Configuration validation,
write admission and recovery, `kubeadm init`, real acceptance and cleanup
remain open; the full gate predates this implementation.

The node intent store now supports an exclusive, synced configuration-attempt
record bound to the selected node's successful recorded start and the fixed
`/kind/kubeadm.conf` path. It requires the removal-attempt record to be absent
and stores no configuration bytes or digest. The controlled fixture refused an
attempt before node start and one for a different node ID, recorded and read
back the matching attempt, and refused a second creation. The warning-as-error
integration build, node fixture, input-frame regression and pinned HLint
passed; their `.build/phase1-kind-config-attempt-*` log SHA-256s are
respectively
`5b6ea0cca5646aaf07545808556c1a9d9d3339afefaba7f984262e63c6e0cacb`,
`3b7d2228410b3bb7f4ca6e831236c05857555f1e2723cfacd3453eeb53e87655`,
`07f2804a91ee75d69d79009d2fc8dcab6bd591ff28d072b36a6d73009dbf59df` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The intent and integration-test source SHA-256s are
`5816430a967ec3cac322dd22f252a5733cf85da096b4977f3d0c991b52e4dfbd` and
`bda52fc89b14414305a5bc40dcf76df9336f4873a940c94164adc010a36c4c42`.
A fake-Docker, network-denied kind diagnostic recorded only the structural
field paths of its synthetic kubeadm input, including bootstrap-token fields;
it did not save the input values. The script, structural report, request
transcript and network trace SHA-256s are
`fb2c4a34d26079624689ddaf3f96428192d01740994c37bdd55e01f8e3ee29ec`,
`52dd88027a1b89c5568034b837b37e5dc0ee04b711093756896bb933daa0059d`,
`ea5df73750ebe417f03e7563fc9beafc7eaa35102642414d6f9990cd8d5fb488` and
`b2edf7ec962edf06bb92b4f414aee06a05bda578c1ffc043b44a3d8bfc417976`.
The record is not yet connected to the broker or an effect. Configuration
validation, daemon-side write and read-back, uncertain-result recovery,
`kubeadm init`, real acceptance and cleanup remain open. The full gate
predates this implementation.

The configuration attempt now has an exclusive, synced result record that
distinguishes not-started, unconfirmed and received HTTP status without storing
input. Attempt admission still requires no removal marker, while reading the
attempt and result no longer depends on that marker being absent. This keeps
the evidence observable during recovery without authorizing another write.
The controlled node fixture refused a result before its attempt and an invalid
status, recorded and read back an unconfirmed result, refused to replace it,
and checked readability and refusal with a conflicting removal marker. The
warning-as-error integration build, node fixture, transport regression and
pinned HLint passed; their `.build/phase1-kind-config-result-*` log SHA-256s
are respectively
`44e8f03536c31fd0c319da5bb6c1f9f6b909d059f5fc37cdbb13e71f0206f621`,
`0ba5a58f0f4d6f360f1a0af14512b63417ae6c53b52750363bf0bb45f644e9f2`,
`d65b22508c40ad8822851a61e212a77e5588ffdcba5cd03455e97692e053248e` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The intent and fixture source SHA-256s are
`8d08e1b330714f2a73e21b60667aebc8fc6c8959ce39b4fba38abce49f459b02` and
`4e3381c19c7c639c0a9220e64c54fd867ed3fa112207a1a81960905d349e739c`.
These records are not connected to a broker effect, and a received status is
not a write postcondition or settlement proof. Configuration validation,
path provenance, admission, real recovery, `kubeadm init`, real acceptance
and cleanup remain open. The full gate predates this implementation.

The held Docker session now has an unconnected adapter for one bounded
configuration archive submission to the fixed node path and a separate
archive read-back that compares contents in memory without returning them.
The adapter distinguishes not-started, received HTTP status and unconfirmed
submission; a lost response does not become success. A controlled Unix-socket
fixture exercised refusal before submission, a successful synthetic write and
read-back, a lost response, and rejection of malformed or conflicting archive
contents. The first integration build failed on a fixture shadowing warning;
after correction, the warning-as-error builds and transport test passed. A
format check caught a fixture line, which was formatted and checked again;
pinned HLint and the node regression passed. Their logs under
`.build/phase1-kind-config-transport-*` have SHA-256s respectively
`1b1773f6124ba4d9c741eaa940f08da0bb0b75886323f4ce8a1954ddd83b2b07`,
`7194aefe4275eae3fda28c6548ff7669f8a88b6cd5963d2b3ba32575e587ce3c`,
`7a063e3a250a22f0e07be706331d570fd637bac773eeab349b93a8ab9933f302`,
`4bf073e019fef96ad22554b3cee7cccdf12936947024d3a9d252f2af55794aab`,
`47d56618a1f63c58c4d8c89104c49056e065ed80c510e007d6ac585811f665b1`,
`06f31dab3ab1c9dd5087418f98685099ee2c61e21282e9a603550c4f80ef464c`,
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09` and
`794540fc05ed7914455eab02552884769100673b1342d4460b7db485a2cc2fb5`.
The observer and test sources have SHA-256s
`1e734b5db51be5447ebf603b9bc9b8d85f163bcdc523ce706f2716be5134085e` and
`eda253446a5488ec221218dcd878106f4893e36a34cd11c8095b3a241c2d8f4a`.
The node regression ran before a formatting-only fixture change. The fixture
is not real Docker evidence; path provenance, configuration validation,
admission, durable outcome and recovery, managed-worker execution and real
acceptance remain open. The full gate predates this implementation.

The kubeadm input now has a bounded multi-document YAML decoder that rejects
aliases, duplicate keys, invalid UTF-8, oversized input and excessive document
counts without returning document contents in errors. A separate partial scope
comparison checks the five observed document identities, selected cluster and
control-plane endpoint, observed node address and version, and the pinned
default pod and service ranges. It is not complete field validation and is not
connected to write admission. Controlled tests exercised malformed YAML,
foreign cluster, missing or reordered documents, and address and version
mismatches. The first scope integration build failed on a fixture partial-list
warning; the corrected warning-as-error build, YAML and node fixtures, protocol
regression and pinned HLint passed. Their `.build/phase1-kind-config-scope-*`
log SHA-256s are respectively
`54fe8b267bde3814ad4de3782626fb3edebb7d356146bc5529f734a24bbc4815`,
`68dd604247266cd9cbf3a9da7d0f8d8e57b6a8373e7775d27214c85a34f4ed81`,
`7e2900607a3afddebdaed71737e6c21ef84363cf2073b47aa4d9e42dca6309bd`,
`e66fb7d423cf9cebbd555766f47f2cd2163fcb765864515267d6b9cfcc018a00`,
`07f2804a91ee75d69d79009d2fc8dcab6bd591ff28d072b36a6d73009dbf59df` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The decoder and integration-test source SHA-256s are
`5cb4e4c38b710a50390123dbbfa9168dd4017d1dff1cc148115d5aad130e4556` and
`d64115375b6debdc4c80259732c145dae94b0f1678f6fcb665cc4307712e688e`.
An installed-kind diagnostic using fake Docker and denied network connects
passed its synthetic configuration directly in memory to the Haskell decoder,
which reported five documents. The report retains selected non-secret field
paths and identity/network values, not the document or bootstrap-token values.
The Haskell probe source and binary, diagnostic script, report, request
transcript and network trace SHA-256s are respectively
`3ee6e7562da5ca6f9b838a6ac321f21a8cb5297123027b583b8d584bfcf8f061`,
`c9add76f03f0153fd82fed38b61d6956a5ffd4faebd2fa784c1a9e332e4d7158`,
`9c2fc57b5fd3c3cdfa98dbd58c4769f7bfe51ff5ccd1c682d3c8be17f6c192aa`,
`0f9226f8a8d5bf92131093ede8d3aa20af743ac35ceb99ffb5fe180650e55283`,
`62c97aee044c9c131912b9c77630cc5dc634395c988d099ee6b32b8da23a4cbc` and
`031c321a04a7b2f3c4c1bd746117300708f0376de69172eba0c9f307a2c8c68e`.
This diagnostic did not contact Docker or run the managed broker. Complete
field validation, path provenance, write admission and recovery, real
acceptance and cleanup remain open. The full gate predates this work.

For the pinned kind provider's observed default five-document shape, an
additional exact comparison now checks every decoded field against the scoped
cluster, node address, version and cgroup input. It checks the bootstrap-token
syntax and equality in memory without returning either value; unknown fields
are refused. This comparison does not authenticate its observations or admit
an effect, and other provider/configuration shapes have not been qualified.
The controlled fixture accepted a synthetic matching document and refused an
extra field, token mismatch, wrong cgroup, partial shape and scope mismatches.
The warning-as-error integration builds, node and YAML tests, and pinned HLint
passed; their `.build/phase1-kind-config-exact-*` log SHA-256s are respectively
`409ae615a25f87a9f219f2b72818660f28b0a29bb7c2275a6f31618b99fe5e1e`,
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`566efcb0c51796d1d117d052c351b285618bd657a48508828b82a6b3493083df`,
`7e2900607a3afddebdaed71737e6c21ef84363cf2073b47aa4d9e42dca6309bd` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The decoder/comparison and test source SHA-256s are
`2043b053e268e5f7925a79ec719867b1d69de1c8b72e013e7db3e5c63f06b2c4` and
`3c642cb5e6ce3a9d8ec8c18e906729486c29c7edfb10b8e69452b1e695e87fc7`.
An installed-kind diagnostic with fake Docker and network connects denied fed
its synthetic document directly to an in-memory Haskell probe. The matching
document passed; an extra field, token change and wrong cgroup were refused.
The report records selected non-secret fields and Boolean outcomes, not the
document or token values. The Haskell probe source and binary, diagnostic
script, report, request transcript and network trace SHA-256s are respectively
`0720c89b4f405ad796efd26cd3ad04b80034d4e42d98ce4d792ac7ab8623b008`,
`08aae4c830ca9eb0409c592e39230b691a43224bfc8af7dbc776e469f93bace6`,
`7e6dc86814602f67ca05d9db50d2896a712f4a6795b14a5841439b91eb34041c`,
`dc0391976d5576527edd2c39399e9399a91eb81cee2612cfcd4e9d291823e150`,
`ec9ee8b4938a4dcf959f6be4da56881f695d4ffa6049a4eed53238772427cd24` and
`856f009408ff0d7a8575aa1f79efc839e3e1989cb2430dee6f92df0ae2401055`.
No real daemon or managed worker ran. Binding the observations, path
provenance, admission, durable write and recovery, real acceptance and cleanup
remain open; the full gate predates this work.

The node broker now evaluates an input candidate against two equal held-session
observations of the recorded running node, its selected addresses and version,
and the daemon's cgroup information. It records only an in-memory match,
rejection or unobservable classification and still refuses every input write.
The controlled fixture checked a matching candidate over the framed endpoint,
refusal before node creation and refusal of a foreign command shape; the write
remained refused and the in-flight marker retained. The warning-as-error
integration build, node fixture, input-protocol regression and pinned HLint
passed. Their `.build/phase1-kind-config-observation-*` log SHA-256s are
respectively
`6d68af100be6d0bef1fc4ee4684eb127be1dc56151ef3b8a7235801578a7ba70`,
`b21311abe95dff7df1109c3b0e3d4cb03c41282dcc1e0199d065712d738351d9`,
`07f2804a91ee75d69d79009d2fc8dcab6bd591ff28d072b36a6d73009dbf59df` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The broker and test source SHA-256s are
`da76a78dae4e62fe3441cb9cfd25fa1e271aed0b609d1b2f56c38222d786e78a` and
`cdd2ccefd38dff370d89b24451f521d7b553c7a3b4dd4afb5c65ae27b925bcf1`.
These repeated point observations do not authenticate the daemon, establish
path provenance or ownership, settle a worker, or authorize an effect. The
fixture did not run a managed kind worker or real Docker. Write admission,
recovery, real acceptance and cleanup remain open; the full gate predates this
change.

The held Docker session now observes bounded metadata for the exact `/kind`
directory and `/kind/kubeadm.conf` path. It distinguishes directory, regular
file, other type and a 404 response without treating that response as proof of
absence. Candidate comparison includes two matching directory observations and
two file-not-found responses, but still refuses the write. In Moby v28.3.1,
[path stat uses `Lstat`](https://github.com/moby/moby/blob/v28.3.1/daemon/containerfs_linux.go)
while [archive extraction resolves symlinks](https://github.com/moby/moby/blob/v28.3.1/daemon/archive_unix.go);
these source observations are not qualification of the installed daemon or
protection against a concurrent replacement. The controlled fixture checked
directory, regular file, symlink, 404, duplicate metadata keys and duplicate
headers. The first HLint pass flagged a pattern style issue; after correction,
the warning-as-error build, path and broker fixtures and pinned HLint passed.
Their `.build/phase1-kind-config-path-*` log SHA-256s are respectively
`6c258d1d54c8c49741f5f4249b850f2a631d53bdf4aac427bc0493ab914ad5b8`,
`9158cfceac097fbb58f42a6de0bd44570f16898bee44a9c6c414e04113d4db5e`,
`51d4a9175800616c5735df96b7fb38fc4f7bd3211c5192745b7dcf5a2df524e1`,
`454e18cfc9d5a1feec902b6e66c6688bcfe7bd301ba8a7aaf64f3d5bc42f11c9` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The Docker observer, broker and fixture source SHA-256s are
`8c4909a8affe04aa1ce044a583422d662fd42aecd10f6a5de148ded1dbb00aec`,
`35da929cbc02e7b99917cdb84a535e6f5ddae34ca88b3f59b95dcb0f3511eee3` and
`da1992a0b684019df81837406eb3853230a442f8ff4512bbae183623ef4d730c`.
These are synthetic point observations, not path ownership, daemon
authentication, worker settlement, write admission or real lifecycle proof.
Recovery, real acceptance and cleanup remain open; the full gate predates this
change.

A held-session configuration action now composes candidate observation, a
separate owner admission callback, a durable attempt, one archive submission,
an outcome record and conditional in-memory read-back. Existing attempts never
submit again. The callback must independently establish path ownership, writer
exclusion, daemon authentication, settlement and recovery; the broker does
not supply it or invoke this action. A controlled fixture exercised admission
refusal, a successful synthetic submission and matching read-back, refusal of
another attempt despite a stale 404 response, and a lost reply recorded as
unconfirmed. The first composition test timed out at 102 seconds. Reducing
nested rechecks was followed by a passing diagnostic fixture and a passing
final fixture; this correlation does not establish the timeout's root cause.
The initial HLint pass also flagged fixture style; the final warning-as-error
build and pinned HLint passed. The failed and final test, final build, final
HLint and transport regression logs under `.build/phase1-kind-config-action-*`
have SHA-256s respectively
`17c67e20e29e5a551fe7bc6b92c9ab4f754b04f4efa54e3bae1268f9f97764ee`,
`937e1f7ef3e243714f4479760502f6006f71fe0f314c536acc2cccf2bc19ffd0`,
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09` and
`d65b22508c40ad8822851a61e212a77e5588ffdcba5cd03455e97692e053248e`.
The action and fixture source SHA-256s are
`d3b2c2ef9ca4a619a2852b8e59132e2bc23ee9a67c5df16c84736ee244c94a19` and
`2c5a6cfca94b51b9367adf722c634667352a7e39dac796555ec2f59a5a6cd4ac`.
These synthetic cases do not prove real Docker behavior, cancellation
settlement or recovery. An admitted public owner, `kubeadm init`, real
acceptance, mutations and cleanup remain open; the full gate predates this work.

The existing node broker can now be constructed with an explicit separate
configuration admission callback. In that mode it invokes the recorded
configuration action for a matching input and reports success only for a
recorded HTTP 200 plus matching read-back. It retains the action observation
for its owner and refuses other outcomes. The current managed-node constructor
does not supply this capability, so it still refuses the write. Controlled
framed fixtures exercised the default refusal, separately admitted write,
duplicate refusal, lost reply and mismatched read-back; the latter two returned
failure with the durable outcome retained. The first build failed on a
constructor-pattern arity error, which was corrected. The final
warning-as-error build, node fixture, input-protocol regression and pinned
HLint passed; their `.build/phase1-kind-config-broker-*` log SHA-256s are
respectively
`06b729beac050aa60a3ad80efc70cdeccb42799869f10b8c414a5e5a6f98b077`,
`c58971260b21d54d73f040aea66de964a99c4b4a9365dbacb24c9ef00181ce66`,
`321cf5db3a7550b8754f4d74cb3d5d75de8cbcf30747be2030a900249b65757e`,
`b4f27fd9ca0faa01722f9c4c4650cdf5a2b16acecf69545ffb3bba1b639ffa3a` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The broker and fixture source SHA-256s are
`484fed51a1fa558723411a5950263fb70e572483adf4e12053d381fd91f9ac2f` and
`49f2a3ab993ca1e583dc4a98c73c27cf21d24da22306f69a8ae4f58ca60d908c`.
The callback is an owner obligation, not evidence of ownership, exclusion,
daemon authentication, settlement or recovery. No real daemon or managed
kind worker was exercised. Public admission, `kubeadm init`, real acceptance,
mutation execution and cleanup remain open; the full gate predates this work.

`control status` now observes the local node-configuration attempt and result
independently of the Docker connection. If Docker inventory is unavailable,
it prints the available observations, reports the inventory failure and
retains a nonzero exit. A public-binary fixture recorded an unconfirmed result
and checked its reporting with a responding synthetic daemon, a conflicting
removal marker and an absent socket. The warning-as-error executable and
integration build, this fixture, the path regression and pinned HLint passed;
their `.build/phase1-kind-config-status-*` log SHA-256s are respectively
`9a52253cae1769021d9e19238f8ba48b819edca04944a95db9301bf808fc3f76`,
`524eb061208ca52b3d7942db7acaad791a43c2999ac1be64c45d6dc909ed886a`,
`51d4a9175800616c5735df96b7fb38fc4f7bd3211c5192745b7dcf5a2df524e1` and
`3ad781d618c325a4232d57cc2d042c8bc78de184f9fc851181cf789e52f3ef09`.
The status, entrypoint and fixture source SHA-256s are
`fe83051f8653be78163113621cae3a0de936ae276f51ba4eb579a09a84026130`,
`eb679e70c795c00a76988afde91e6fca00064c9890459df6521789a6116f4554` and
`eeabbfe10f0ea805abd1bca30ca78346f6a92f2c1caabe108f69c9f965ecbf2f`.
The local record is not proof of resource ownership, content, worker
settlement or absence. The fixture does not qualify a real kind lifecycle;
admission, recovery, real acceptance, mutations and cleanup remain open. The
full gate predates this change.

The managed host subprocess now retains a reader-settlement failure alongside a
primary child failure and retains a primary failure when the enclosing finish
deadline is exceeded. These results remain errors and do not prove Docker-side
settlement. The warning-as-error executable, integration and daemon lifecycle
build passed, as did the existing focused error-combination test and pinned
HLint. That test exercises the combination helper, not an injected failure in
the managed path. The subprocess source SHA-256 is
`3c660a331e3df56aded103fe7d8d7d1a4d3c4167e1b50a078bd5d8b778239e9f`;
build and focused test logs are `.build/phase1-worker-settlement-build-final.log`
and `.build/phase1-worker-settlement-test.log`. Real managed settlement,
daemon-side recovery, public activation and phase acceptance remain open.
The synthetic broker integration regression also passed in
`.build/phase1-worker-settlement-integration.log` (SHA-256
`ec2cd77430330a2a8a524d80c7804138fed47227093495fe1ee3a0abe6cf8e0d`).
The canonical `prodbox dev check` passed after correcting two nested-case
style violations and a terminal-output checker false positive in a comment;
its log is `.build/phase1-worker-settlement-gate.log` (SHA-256
`d7a2990251de717357f7219fda8310301344bc2bdaa4cdb2e9156d2dc4b24d61`).
The gate does not replace this phase's real lifecycle or mutation evidence.

Node inspection now requires Docker's running, paused, restarting, dead and
status fields to agree before classifying a node as running or stopped. Paused,
restarting, dead, removing and contradictory states are conflicts; missing
fields refuse observation. A synthetic integration fixture checked those
states and a created node, alongside the existing broker regression. The
warning-as-error executable and integration build, fixture, pinned HLint and
formatter passed. Their logs use the `.build/phase1-kind-node-state-` prefix;
the build and test log SHA-256s are
`77c69e6a5d6ac422322da6e49ffc04c38db498722aba48187396b63e48d0ef14` and
`d933f6076be321d8f73e3f414faa1c0405e5115a173d3ba9baf09f655d4f99f7`.
The observer and fixture source SHA-256s are
`5a236685b0daf3c8e696dfe76258a6ecd67ba16ab5175b013f28fd319823d2a4` and
`23ad61cbee95b9ecfad9f06f4b1135719b58f5ca73270ad37670763acd6574db`.
These observations do not authenticate the daemon, exclude writers, settle
effects, or qualify real lifecycle behavior. The canonical gate predates this
change. The proposed interruption journal still needs a bounded settlement
design: extending a timed-out lease to write a receipt would not prove its
original deadline or daemon-side settlement.

The owned subprocess boundary now has a distinct mutation controller profile
and can apply the existing network, metadata, filesystem and descriptor
restrictions inside its admitted child. It requires a bound caller thread, an
explicit small environment allowlist and a pipe for stdin. A real user-manager
fixture in `test/qualification/MutationHostPlacement.hs` exercised the actual
managed child: the child read its fixture workspace, while an outside file,
socket creation and an inherited descriptor were denied. The fixture also
rejected an unbound caller, a synthetic AWS environment variable and the kind
and RPC placement profiles. It cancelled a first child, reacquired placement,
ran a second child and independently observed both PIDs, the exact manager
units, cgroup and runtime directory absent. The successful fixture used a
synthetic capacity plan and did not run a mutant or public scenario. A
subsequent independent `systemctl list-units --all` found neither named unit;
`systemctl show` reported the controller not found and the slice inactive.

An earlier fixture exposed cancellation waiting until the work deadline when
the launcher used a per-call bound-thread wrapper. The trace is retained under
`/tmp/prodbox-mutation-host-placement--cb7572f047d11d97`; the launcher now
requires its caller to be bound. A later attempt returned
`KernelHostPlacementClosed` because it reused the interrupted placement; the
successful fixture instead reacquires it. Its failed root is retained at
`/tmp/prodbox-mutation-host-placement--b9cbc1bde12c539b`. Earlier fixture
builds lacked RTS options; their roots and results remain in
`.build/phase1-mutation-managed-probe-run.log` and
`.build/phase1-mutation-managed-probe-diagnostic.log`. An earlier successful
normal-completion probe printed an incorrect interruption label; it did not
test cancellation. Failed fixture roots have not been removed.

The warning-as-error executable and daemon-lifecycle build, real-manager
fixture, focused subprocess regression, pinned formatter and HLint passed.
The standalone fixture compiled repository sources with two temporary overlay
copies selecting the same `crypton` package as the Cabal library; it did not
run the public operator as its worker. Source SHA-256s for the subprocess,
kernel scope and fixture are
`ca0737467357c49e1cba0efb8d50ff0967cf0af18034decbc185d1f9a9ded689`,
`76d0c66805d0bd0321f3659275b168ff789714c1a1f0b7ff7ce0c331ca3e17fd` and
`e0c97095157719b0259d1cd88e17ce781b4d75db04bed5418d6195e8ee1be6e0`.
The build and fixture logs `.build/phase1-mutation-managed-bound-build.log`
and `.build/phase1-mutation-managed-final-fixture.log` have SHA-256s
`c5ea8cb3d1ad1e49e7db13ed2fee001515aaaab4e7d62593d0ab1e4dfa865306` and
`b1bf82a1238a9891a8b197a8525775104211e73386e20fdb8eb28265b54fe0a5`.
Workspace and dependency authentication, noncooperating writers, complete
worker coverage, supported workspace cleanup, actual mutant execution and
public scenario admission remain open. The canonical gate predates this work.

The managed worker can now reopen an unchanged recorded workspace and compare
the held root's birth-derived worker key with the mutation controller's key.
It requires the command's working directory, home and temporary directory to
be that workspace, and checks an explicit independent admission callback before
launch. The callback is an owner obligation, not proof of admission or
noncooperating-writer exclusion. A real user-manager fixture created two
recorded synthetic snapshots and refused the other snapshot's key, a foreign
working directory and denied admission. It cancelled and settled one confined
fixture child, reacquired placement, and ran another through the recorded
workspace. The outer fixture independently checked both child PIDs, manager
resources, both snapshot inventories and an outside marker. It used a
synthetic capacity plan and a test admission callback; it did not compile or
run a mutant or invoke the public scenario runner.

The warning-as-error executable and daemon-lifecycle build, fixture and pinned
HLint passed. The standalone fixture was compiled from repository sources with
the same two temporary `crypton` package-selection overlays described above;
the operator binary supplied to the fixture was only hashed. The subprocess,
workspace adapter, fixture and package source SHA-256s are respectively
`8c7dad9a1b3a651eb021109cd78d94ba920e6b8454fb5b25e87d1cfe2d5ddbde`,
`1dd70d912024243c5d9c87ee599528760917114ef77b8f06f503f7dc39e930b0`,
`81574cf00add66405ba23a15aa49122f614203d67e7bc68fc051a48c1e5cc986` and
`78d8cac89a57ae87c271889919d688d1276589fb225912c9dbc30317c51ffb73`.
The build and fixture logs are `.build/phase1-mutation-workspace-worker-build.log`
and `.build/phase1-mutation-workspace-worker-final-fixture.log`, with SHA-256s
`70ff7ee30b49d74527f18cea1de22659562bd6e91d6c1d699fd25b3829e6ac12` and
`3f48a8a0e33d990a26f6afe49f219af7da01301c98ef5cfdde066ee1097ce528`.
This adapter supports one worker against an unchanged snapshot. The executor
still needs owned build-output custody and recovery so that compilation and
test execution can be sequenced without treating changed snapshot contents as
an unchanged source tree. Tool authentication, all-worker settlement, exact
cleanup, actual mutant execution and public activation remain open; the
canonical gate predates this change.

The workspace-worker adapter now accepts a separately held writable output
directory and passes the source snapshot as a read-only Landlock root. This
supersedes the earlier requirement that home and temporary files use the source
directory: the working directory remains the source, while `HOME` and
`TMPDIR` must name the supplied output. It checks lexical separation and held
versus named directory identity and brackets the worker with the caller's
output-stability observation. Those checks do not establish output ownership,
prevent mount aliases or exclude noncooperating writers; the caller still owns
those obligations. An output observation failure after a returned worker
retains the worker result as changed, rather than discarding it.

The real user-manager fixture held a separately recorded output workspace
while two sequential fixture workers used the same source snapshot. The first
was denied a source-file write, wrote a non-secret output file, and the second
read it. Controls rejected a source/output alias, an unstable output, a foreign
source key and denied admission. A synthetic post-run output observation error
retained the third worker's result. The outer fixture checked the source
inventories, exact output marker, outside marker, all four child PIDs and the
manager resources. It also confirmed that the existing unchanged-snapshot
recovery path refuses the modified output after the held lease closes. This is
not a supported output-recovery or cleanup path and did not run a mutant.

The warning-as-error executable and daemon-lifecycle build, fixture, focused
subprocess regression, formatter and pinned HLint passed. The standalone
fixture used the same temporary package-selection overlays described above.
The adapter and fixture source SHA-256s are
`6174e16fe3f513f839b56da8f936d7d5872978c864b64ecf78d9628a52a2a587` and
`48f3dade6ee8a3cd0c90260fa172aed1a746ef0f28fec1bed0e9dc184f0ae893`.
The build, fixture build and fixture logs under `.build/phase1-mutation-output-`
have SHA-256s respectively
`93f1e77da4e5f6c301c0eb5837c926f6232017c58c3de82c58ecfafb87b09065`,
`71ba5a42256de02dfaa5fb03b93f105ab352a624d82d4793245773330ec095a5` and
`b3110a46eb43bf54daca5d059ff6303248d8635c44d7121372a41ace89077d24`.
The first fixture build failed on a return-type mismatch; its log is retained
as `.build/phase1-mutation-output-fixture-build.log`. Durable output recovery,
independent alias exclusion, dependency authentication, all-worker settlement,
exact cleanup, actual mutation execution and the public runner remain open.
The canonical gate predates this change.

A held output directory now has a bounded metadata inventory: it checks owner,
private modes, device, names, entry count, aggregate file size, depth and
metadata stability, and refuses symlinks, special files, repeated identities,
hard-linked files and a `test-secrets.dhall` entry. It does not read file
contents. A metadata fingerprint includes paths and stat values, so its caller
must first establish that output names are non-secret; it is not a content hash
or authentication. An exclusive, synchronized checkpoint binds that
fingerprint to the recorded output birth, source worker key, checkpoint ID and
inventory limits. A later reopen freshly inventories the held output, reads the
checkpoint and inventories again. Missing, invalid, conflicting, changed and
unobservable observations remain distinct; none proves worker settlement,
excludes external aliases or authorizes use or cleanup.

The real user-manager fixture checkpointed a synthetic output and reopened it
from the outer process after its controller exited. It exercised entry and
depth limits, changed output, a missing and malformed checkpoint, wrong worker
and limits, duplicate checkpoint creation, symlinks and hard links. The fixture
used 128 entries, 1 MiB, depth eight and a five-second observation limit; it did
not compile or run a mutant. It independently checked fixture child and manager
cleanup and the source and outside markers. It did not test a process crash,
content authentication or same-user adversarial writers. The output fixture's
physical removal is fixture cleanup, not the supported mutation-output cleanup
path.

The warning-as-error executable and unit build, real-manager fixture, all 28
scenario-evidence comparison tests, formatter and pinned HLint passed. The
fixture compiled repository sources with the previously described temporary
`crypton` selection overlays. The inventory, workspace, record, fixture and
package source SHA-256s are respectively
`fea90bccee809738e2d0769b125521a6386d85515cf85ac31e267c7a71149ebc`,
`a4c2831d1debd7b3d34d8db6f897fe9f6eebe4754ca0b4bf976f1e3ad597fbe9`,
`07664df676aa2dd6fe02b3475d0ced2d373d459f090b54490e4840af4ae6e776`,
`b5489d733a72d80b5015fb5fe101500d3ec4ce2c1714c541f0543f2bf9caedec` and
`5c6ddcf5ddd93542372438223dfbe4922f13478612891e0abea9ee7f30db3b01`.
The build, fixture build, fixture and unit logs under
`.build/phase1-mutation-output-distinction-` and
`.build/phase1-mutation-output-readback-unit.log` have SHA-256s respectively
`b0eb944e0ec8c3ab94b266309c23e2a793434efa8a323e5a0494dee7edcb45b7`,
`2591f36cdc65facd09694a7355583b50e2866123e20c393ce9e87f6789f7399c`,
`b2110749c225a649f00d12518600c7c873d16866bc7456a2d7301c0d7065e41f` and
`cc86aa704ea1f04f9c4160fd01195f3dba7515d2e77bb23ffdddae5fc97bc38a`.
The initial checkpoint build failed on a shadowed name; its logs remain under
`.build/phase1-mutation-output-checkpoint-`. Actual mutation execution,
output content verification, retirement and supported cleanup, all-worker
settlement, alias exclusion and public scenario activation remain open. The
canonical gate predates this change.

The managed host family now distinguishes mutation controllers from RPC and
cascade controllers in submission and publication records, systemd identity,
and operation-family placement. The settlement observer requires that exact
mutation kind and birth-derived key. The confined command path also requires a
bound mutation-family parent. Existing record tags remain readable; these
changes do not activate the public mutation runner.

A real user-manager fixture submitted a mutation controller, ran a synthetic
confined child in its operation family, and independently observed retirement
of that recorded family. The child read its source, was denied a source write
and socket creation, and wrote an output marker. A matching-key RPC family was
refused both the mutation command and mutation settlement observation; a
cross-kind publication was refused before submission. The retained fixture
roots are `/tmp/prodbox-mutation-family-final-SsFW8hcF`,
`/tmp/prodbox-mutation-family-guard-rpc-7bWJVVVH`, and
`/tmp/prodbox-mutation-family-cross-ewdyLo5D`. The scoped independent
read-back records absent fixture units, runtime paths and published inputs;
the fixture source and output remain retained. The initial attempt under
`.build` refused before workspace creation. An earlier successful worker
fixture remains at `/tmp/prodbox-mutation-family-worker-rjSOOof3`.

The warning-as-error build, 24 native submission controls, publication codec
controls and selected scenario-evidence tests passed. The standalone native
fixture used temporary overlays selecting `crypton` for two package imports,
as in the Cabal library. Logs are `.build/phase1-mutation-family-final-build.log`,
`.build/phase1-mutation-family-guard-{mutation,rpc,cross}.log`,
`.build/phase1-mutation-submission-fixture.log`,
`.build/phase1-mutation-publication-codec-test.log`, and
`.build/phase1-mutation-family-independent-readback-final.log`. The mutation,
RPC and cross-kind fixture logs have SHA-256s respectively
`a5985f65edf28c500a2bed7a8e2e6d64fe3842d96d4bfa57a68ea2efe3f4e56b`,
`cefc8f88d7a5d05669df6f32db8c1ae455e0fe7b188f2e1afd3cea4a5226b638`, and
`f2f64bed5718c6c014dc4afccc5434d1422a43ad355efea5e3e1a508b96356b2`.
The settlement observer source SHA-256 is
`babeb8cd7fda16900ce1186beaed781288badcf87900265d8adac50adec8b7b2`;
the family fixture source is
`42b8354d28d73c111eb6b26323b9959218d3467191c8dd2292a89d5ef30beda3`.
One incorrectly selected unit invocation ran zero tests; the subsequent
selected invocation is the evidence. This is neither an actual mutant run nor
public lifecycle acceptance. Checkpointed output retirement and supported
cleanup, all-worker settlement, alias exclusion, mutation execution and the
canonical gate remain open.

Checkpointed output can now record its active-to-retired marker transition
while the matching mutation host-family retirement observer is held. The
transition rechecks the output inventory, checkpoint binding and supplied
settlement fence around the atomic marker move. A lost post-move observation
is incomplete and retains the retirement marker for recovery. This is a
recorded transition only: it neither removes output nor proves all-worker
coverage, content authenticity or exclusion of other writers and aliases.

The real user-manager fixture ran a confined synthetic child, checkpointed its
output and retired it under the real matching host observer. Controls refused
an unsettled fence and missing checkpoint. A separate output forced a failed
post-move fence and recovered the already-recorded transition. A matching-key
RPC controller again refused the confined mutation command and settlement
observation. The formatted-source fixture root is
`/tmp/prodbox-output-retirement-formatted-5UjiP6LQ`; the earlier successful
interruption control is retained at
`/tmp/prodbox-output-retirement-interrupted-3HFyTldr`. An additional earlier
successful fixture is identified in `.build/phase1-output-retirement-real.log`.
These are synthetic fixtures, not mutant execution or public acceptance.

Independent read-back found the recorded units absent from the user-manager
listing and the request and configuration files absent. The publication
directory remains under `/run/user/1000/` with terminal records and the
fixture's `controller-kind-observed` marker; its continued existence is not a
cleanup success. Output checkpoint and retirement records, source and worker
output are also retained. The first read-back incorrectly expected the entire
publication directory to be absent and failed; the corrected read-back states
the narrower observation in `.build/phase1-output-retirement-readback-corrected.log`.
No filesystem cleanup was used to manufacture a passing observation.

The warning-as-error build, real fixture, RPC control, 28 scenario-evidence
tests, formatter and HLint passed. The native fixture build used the same two
temporary `crypton` selection overlays noted above. The workspace, settlement
and fixture source SHA-256s are respectively
`6276575316dfae87a51e3c5b5cb8e2bde83755ff49b2b69aa1c7f6c1150e0c1e`,
`e7d33ded0c03e749be6ebbed173105494d400e922f372814c6b6b6ad1e06512a`, and
`e45d812840fd2483bc10de4fbeca3c63ff9a0e04808c1305336ac75fbb2c4daa`.
The real fixture, RPC control and corrected read-back logs under
`.build/phase1-output-retirement-` have SHA-256s respectively
`b12337c7d7ef036bbb8076dd92b49cd498840aa04430cb3dbc4c8c7f19064394`,
`6c066555efabc0ae1400a59d351e7ece5e26202b8a8c0c02a42ddcf99bfd6eb3`, and
`f792ba1ee6a2c3fb8324eb7e490fe70a13c8a655e287e940bc72739213543e26`.
The canonical gate, actual mutation campaign, supported output cleanup and
complete worker/alias ownership remain open.

The publication-kind fixture now writes its observation marker in its own
fixture root instead of inside the managed publication directory. A subsequent
real-manager run also checked that a foreign worker key and output changed
after checkpointing each refuse retirement, then used a new checkpoint to
exercise the interrupted-transition recovery. The fixture and read-back are
`.build/phase1-output-retirement-adverse.log` and
`.build/phase1-output-retirement-adverse-readback.log`; their SHA-256s are
`1dfbfa66bf773950ea5cf465c22d68d4a0a2190ad88f1e253392ab05d141939e` and
`dfc4cd10a024e88328082b94278311d050bfb3222655da1555fb1e93f7223b83`.
The fixture source SHA-256 is
`44606cae22062ba3e937e9688195c7ed58aac29c2d3760c444057089e214b82d`.
The fixture root `/tmp/prodbox-output-adverse-piYo8Evg` and both output
workspaces remain retained. Its manager listing contained none of the
recorded units, and its request and configuration files were absent; its
publication directory remains with its own birth, submission and retirement
records, without the fixture marker. The earlier fixture and its marker remain
as recorded above. The native build, formatter and HLint passed. This does not
establish workspace cleanup or complete worker settlement.

The output inventory now reads the kernel mount ID for the held root and
every opened descendant, refusing a differing mount even when device numbers
match. Missing or malformed descriptor mount information is unobservable.
This narrows mount-crossing exposure but does not establish that the root has
no outside alias or writer, or authorize cleanup. The warning-as-error build,
real-manager fixture, formatter and HLint passed. The final fixture root is
`/tmp/prodbox-output-mount-final-4GBKXocp`; an earlier successful positive
fixture is `/tmp/prodbox-output-mount-2WbtWHed`. Both remain retained.
Independent read-back observed mount ID 33 for the final output root and its
worker file, absence of the recorded units from the user-manager listing, and
absence of request/configuration files; the publication records remain.

The attempt to create a disposable user and mount namespace failed at
`/proc/self/uid_map` with `Operation not permitted`. Consequently no actual
same-device bind-mount adverse case was run and that boundary remains
unvalidated. No host mount or production resource was changed. The inventory
source SHA-256 is
`7116f1434d73e0c53404c577e54f156b79e8fdb38ffc45b06448dab2f489778e`;
the final fixture and read-back logs have SHA-256s respectively
`6e3ee989b1ea2939c55fbef627b89d103ecfd31ae747c567f1e0e12e2439ddc3` and
`ffd58366d3756a4db68d3cc1e3d3b0ad6a37e506f6dc4527f78ca9e1bc47f033`.

Output checkpoint/recovery and retirement now also require the held output
root to share its recorded parent's mount. Their stability fence reopens the
named root and checks that mount again, so a different mount exposing the same
inode does not satisfy that fence. This remains a mount observation, not proof
that no outside alias or writer exists. The managed fixture compared real
descriptors from its output root and `/proc`, requiring same-root equality and
a different mount for `/proc`; it also completed the existing checkpoint and
retirement controls. Independent read-back recorded mount IDs 33, 33, 33 and
29 for the parent, named root, output file and `/proc`, respectively. This
different-device control does not replace the still-unavailable same-device
bind-mount adverse case.

The warning-as-error build, native fixture, 28 selected scenario-evidence
tests, formatter and HLint passed. The fixture root
`/tmp/prodbox-named-root-mount-UBDp7EeT` and its publication records remain;
the scoped manager listing contained none of the recorded units, and request
and configuration files were absent. The inventory, workspace and fixture
source SHA-256s are respectively
`221c941c1e4c896cd6fc54e2e6146520aceb03d5b8db7e300f0762362aa75b40`,
`e7b36dd360567fa67c75ede4d09dc55ed8f274808a264076c9f55c872194ac39`, and
`a722a80fc97a445632e04e80cfe5db5020100d70c9ca2e385b675ea6f81fd92a`.
The fixture and independent read-back logs under
`.build/phase1-named-root-mount-` have SHA-256s respectively
`186ee5fafdcda11512bfdfab7ca7318d0f7632e3dabb9682f3bd1953d9e7e9c7` and
`5fb27f6f8f2352473f42e107d16efd74dc82282cfb4d0009e62c4daf2995ff8c`.

Recovered output callbacks now receive a stability check that re-observes the
expected inventory or checkpoint, in addition to the birth and marker fences.
The inventory is checked before callback admission and after return. A managed
fixture changed output inside a checkpointed callback and observed both a
false stability check and a retained `ChangedAfter` result; a fresh checkpoint
then supported the existing interrupted-retirement recovery control. This
detects observed metadata changes; it does not authenticate contents or
exclude noncooperating writers and aliases.

The warning-as-error build, formatter, HLint and 28 selected scenario-evidence
tests passed. The real-manager family fixture and the broader managed
workspace fixture both passed. The latter exercised checkpoint recovery,
adverse inventory cases and cancellation with synthetic inputs; it reported
its child PIDs and exact manager/runtime fields absent and removed its own
fixture root. It is not public scenario acceptance or supported workspace
cleanup. The family fixture root `/tmp/prodbox-output-callback-HpckNMKO`, its
changed output, retirement marker and publication records remain retained.
Independent read-back found its recorded units absent from the manager listing
and its request/configuration absent. The workspace and family-fixture source
SHA-256s are
`dffc5068839679368369e378d8188c9ec351c4c8f8bbad687bb581cb80a357e3` and
`e1e54c03c89953bf31455cd3e183ad542e75755ced474b70f9d7c1e1dcd165c5`.
The family fixture, independent read-back and broader fixture logs under
`.build/phase1-output-callback-` have SHA-256s respectively
`3c512f04a3783576d68480d0f75e01ab8a8038bd0cb05f10a3bf4f65e089ba4c`,
`c86eba9efbe35c70deb6a74bab371be22f7a191ceae3abf613b17267481a4c00`, and
`a1d5f5900a8ee91425c919811dade6e3ef5058540854dfa952ba9257b837f825`.

Snapshot construction already applies the reviewed patch to the immutable
source inventory before writing it. Its descriptor-relative writer and
reader now compare mount IDs for the source root and every opened file and
directory, including reopened names; workspace stability also compares the
named source root with its parent. An unavailable mount observation refuses
the operation. These checks do not prove outside-alias exclusion, settlement,
safe execution or cleanup, and the actual same-device bind-mount adverse case
remains unvalidated as recorded above.

The warning-as-error build, formatter, HLint, 28 selected scenario-evidence
tests, managed-family fixture and broader managed workspace/cancellation
fixture passed. The latter reported its children and exact manager/runtime
fields absent and removed its own fixture root; that is not the supported
workspace cleanup path. The family fixture root
`/tmp/prodbox-source-mount-WTC6VsQC` and publication records remain retained.
Independent read-back observed mount ID 33 for its source parent, root,
directory and file; its recorded units were absent from the manager listing and
its request/configuration files absent. The inventory, workspace, snapshot
observer and writer source SHA-256s are respectively
`129d9c07505121f51a5ef10a5fc861a2ac7cf66af52d8911b29d96814c1a2340`,
`c4b90b4500d978ef6c7adc33c985c452b48b9db00d4939e12eeb89feeb260542`,
`e87e5646a7727ba77cbcce78b3ff41abb6c5a5042d44a2873ad287104e755259`, and
`63f505d4fbc4c22b26cc9d4e61232c0dcb1adec5bbc03d925e81a8a356bca984`.
The family fixture, broader fixture and read-back logs under
`.build/phase1-source-mount-` have SHA-256s respectively
`28ae92e59191b7d0f3fd48333c849b36ccaa97fc06dff8c70a78f3cbdfa481ba`,
`834985bab56594db38a7302b3d15eb1042ebee02269d690c2515ac567ecf421c`, and
`0c400b107bdb1309c1a90c963c4b8712bcb8a38d7d482244ea8e0f6316a17042`.

Recovered source-workspace callbacks now re-observe the complete recorded
snapshot before admission, whenever their stability check is called, and
after return. A change during the callback preserves its value as
`ChangedAfter`; an already changed snapshot cannot be reopened. Intentionally
mutable output uses a separate, explicitly identity-only lease and still
requires independent writer settlement, output inventory, alias exclusion and
cleanup. Snapshot re-observation is bounded but may add substantial I/O; no
full-size source or latency budget has been established by this fixture.

The warning-as-error build, formatter, HLint, 28 selected scenario-evidence
tests and both real-manager synthetic fixtures passed. The family fixture
changed a source file during a callback, required a false stability result and
`ChangedAfter`, then required a changed-snapshot refusal on reopen. Its root
`/tmp/prodbox-source-callback-zJ3Gl34G`, changed control, original source and
publication records remain retained; independent read-back found the recorded
units absent from the manager listing and request/configuration files absent.
The broader fixture exercised mutable output and cancellation, reported its
child PIDs and exact manager/runtime fields absent, and removed its own fixture
root; this is not supported workspace cleanup or public acceptance.

The workspace, family-fixture and broader-fixture source SHA-256s are
`5ab597503c17b849693632a83a6e0ca5e2005b14aa156ff33a7d9bfe0109066c`,
`49b8f876ad08e3aa34e53ef266cf38e20f339d266c66614a3c6207bdf50e6feb`, and
`9cb18db46860369140e50aad80af8a06f17776553391ea603a3794cf770c6c74`.
The corresponding family fixture, broader fixture and read-back logs under
`.build/phase1-source-callback-` have SHA-256s
`612995eb2995bf28ae5ae0a164b71a2b076e18c18d8d56d8c1abd5419f91a0c1`,
`fef349af3bd0ffc1af3d033448e8730a86c86cda30079c2c0960894a9a4ca89e`, and
`ff4b1c66152b0a3980318d26d244586ababc228af9b5bce4fa08bbc813e16994`.

The managed workspace worker now bounds each full source-snapshot observation
by its placement's original absolute finish deadline. An expired observation
returns a timeout refusal before invoking the callback; a scan that completes
late also remains timed out. This bounds those inventory observations, not
other caller callbacks, all worker effects or cleanup. The real-manager
family fixture checked the expired-deadline refusal, and the broader managed
worker/cancellation fixture passed with the rebuilt operator. Neither fixture
ran a mutant. Those fixtures did not test an in-progress scan crossing its
deadline or full-size source performance; a later observation is recorded
below.

The family fixture root `/tmp/prodbox-source-deadline-tIBU8vdY`, changed
control, original source and publication records remain retained. Independent
read-back found its recorded units absent from the manager listing and
request/configuration files absent. The broader fixture reported its exact
manager/runtime fields and child PIDs absent and removed its own fixture root;
this is not supported workspace cleanup. The subprocess, snapshot observer,
workspace and worker source SHA-256s are respectively
`a487b900e349a18f43c4620776991dc9cba2fa6a36e0e9f9bdce50be1c215f05`,
`e480d9514d54bf2aa8fb6c4e8f29813ecd22a3746e72d8f7310f52e50a0cb34f`,
`d299c4c56b36c01812ba6ca9dd4ac93caa90bb9cb89b8f2deba649cd8d7ffbdb`, and
`ff98b37797febb51a6de9964f58a917454f7d26978dc78c3b458f400d746c52b`.
The family fixture, broader fixture and read-back logs under
`.build/phase1-source-deadline-` have SHA-256s respectively
`19aadc46481ab9a2493d966554ec163aa8a43d10e18b4146b31066e37fa013d1`,
`77706f384c716746052091fa65687e5b149a6889b298617d79423eae0038aea1`, and
`d6dcbaab74c8b1ffa64fff33802aa36f4671f6e5c18739cd91281294aac7271e`.
The warning-as-error executable/unit and standalone fixture builds, formatter,
HLint and 28 selected scenario-evidence tests passed. The full build and unit
logs are `.build/phase1-source-deadline-build.log` and
`.build/phase1-source-deadline-unit.log`, with SHA-256s respectively
`c8ff62984aace8a14de6ba8d7493a85e6de748a93941e8b31e983d84a574eff2` and
`4fa86472e08f22dc065040758412211210b21c9a6f36a85c5deabf0a9f743027`.

An unmodified outer probe captured the current secret-filtered worktree and
prepared the reviewed M01 snapshot without executing it. The captured snapshot
contained 1,817 files and 41,333,825 bytes. Capture took 0.32 seconds,
workspace preparation 19.20 seconds and a deadline-bound recovered callback
0.94 seconds on this host. Independent read-back confirmed the selected source
had exactly the reviewed replacement, the selected test bytes were unchanged,
and no `test-secrets.dhall` pathname appeared in the snapshot. This pathname
check does not independently prove exclusion of every possible secret.

A separate `openat`-only traced probe recaptured the same source and observed
the retained snapshot with a 20 ms deadline. It returned timed out after
approximately 20.8 ms under tracing; the trace records the workspace root and
a descendant opened, and the probe PID was absent afterward. The trace did not
show an open of `test-secrets.dhall`. This is one traced local observation, not
a latency guarantee, full mutation execution or public acceptance. The
workspace `/tmp/prodbox-source-fullsize-RuEkTE7Z` remains retained because the
supported workspace cleanup is not yet implemented.

Probe and evidence files use `.build/phase1-source-fullsize-` and
`.build/phase1-source-deadline-scan` prefixes. The preparation log, independent
read-back, timed scan log, trace and trace read-back have SHA-256s respectively
`b0f0ac4adfc3a8d0ff0444b5d2defc3924ece9167b5532d858a6da157bc5fa59`,
`f5415e25bfa0c2a9d1014dab61280f611103907acfd121d163f69483b14eba7b`,
`4720af543b98eeb3f5a3bc3eb23c74c490abb6ca13b0734ea2df3e410c52ee0e`,
`ee8ec78ea62a0147986e88b5e75be712390f8fe033ab8efc30f6049682689bc7`, and
`c32255ead57ed65bcfe7a30a7706d04a3e114c4812131494a1a8144b8e6dc7bc`.
The probe sources have SHA-256s
`df93a3f05eb9b986487bc068b9be0ce98890fc5d9d648eca8435f71cbe9e4888` and
`a23a56fe2af9d389f7e92d580028e7eae7fc3597625d2fa4f10ef24db0f33f15`.

The retained source-workspace check now composes with the actual mutation
operation-family command slot. It checks the birth-derived operation key,
source and output path/descriptor relationships, command directory and
environment, source/output stability and the supplied admission callback before
the restricted child. The older placement path shares the same binding
checks. The caller still owns output custody, tool authentication,
all-worker settlement, alias exclusion and cleanup; this is not permission to
execute a mutant or the public scenario runner.

Real user-manager fixtures exercised the joined path with synthetic source and
child inputs. A foreign source workspace and a denied admission were refused
before any worker output; the mutation family then ran the confined child.
An RPC family was refused the confined child. Independent read-back found the
two recorded families absent from the manager listing and their request and
configuration files absent; their source/output workspaces and publication
records remain retained under `/tmp/prodbox-operation-workspace-final-wLAM0rJz`
and `/tmp/prodbox-operation-workspace-final-rpc-bVgzRhPh`. The separate managed
placement/cancellation fixture also passed and removed its own fixture root;
that is not supported workspace cleanup.

The warning-as-error build, formatter, HLint and 28 selected scenario-evidence
tests passed. The worker and family fixture source SHA-256s are
`1bbde3dff5556e809fdd4a75ade85eecc60cd36fc27319128066dc01604d8ec5` and
`4aba3cd0c43b04b42dd9adda58aea278149e338bb9613dc95dfafc4ff0d0fb1f`.
The mutation, RPC, placement and independent read-back logs under
`.build/phase1-operation-workspace-` have SHA-256s respectively
`0559c264a61572a19b2e837855f323b22a79bb41ef157331c01ac70bb781370d`,
`7d2b67058dd2b274e8f283c1c656a96c193672661e264a9d5ff006441093bdaf`,
`25e9a78f72b9acb8a21e21c4baae95c3da15431ec7391b3239093345f897b359`, and
`cb63c7ab9adcf078081750adc17c955a0e97ede141225a255cdb9abad1a72410`.

The mutation operation path can now copy a declared executable into a sealed
descriptor, check its digest and execute that held descriptor under the
restricted child profile. It requires the operation parent's runtime plan to
match the funded sealed-tool budget, checks the parent before preparation,
and bounds preparation by the original work deadline. The child rechecks the
seal and close-on-exec state after confinement. The declaration's authority,
dynamic dependencies, output custody, all-worker settlement, alias exclusion
and cleanup remain caller obligations; this is not actual mutant execution.

The first synthetic fixture refused before submission because the 256 MiB
runtime did not fund the snapshot. After declaring a 320 MiB fixture envelope,
a controller was submitted but failed and its request and configuration were
retained. Offline diagnosis showed that adding a Landlock path rule for the
anonymous sealed descriptor failed with `EBADFD`; a confined offline probe
then ran the sealed executable without that path rule and verified its seal
and close-on-exec state. The child setup was corrected accordingly. The
original failed operation was subsequently recovered using the recorded host
retirement observer and input reaper. Independent read-back confirmed its
request and configuration absent and terminal receipt retained; its fixture
root `/tmp/prodbox-sealed-mutation-funded-EzfakbTt` remains. The initial
pre-submission root `/tmp/prodbox-sealed-mutation-dgLK6GYE` also remains.

The corrected real-manager mutation fixture ran a synthetic sealed Python
child and refused an expired preparation, wrong digest and mismatched budget;
the RPC fixture refused the mutation child. Independent read-back found their
recorded units absent from the manager listing and their request/configuration
files absent. Their fixture roots `/tmp/prodbox-sealed-mutation-final-wvdbWQgS`
and `/tmp/prodbox-sealed-mutation-rpc-GushpFRO`, and their publication records,
remain retained. The warning-as-error executable/unit and daemon-lifecycle
builds, fixture builds, formatter, HLint, 28 selected scenario-evidence tests
and the existing sealed-tool regression passed. An initial daemon-test
invocation used the unsupported `--match` option and ran no tests; the
subsequent `--pattern` invocation ran the one intended test. The full build,
unit and selected daemon-test logs under `.build/phase1-sealed-mutation-` have
SHA-256s respectively
`0caa5e7b56b187c5d86aec2e52aa569bc409d572bb72d6524966b0fa07df1ffb`,
`e8ec0cdb3d297e9649a8423ce288eab3524cf908ae8f00e094bf77f73386b506`, and
`2424d5959733f4ae8c276fe2ce84d3a90584ed49b9d32d56987177823bb5bd77`.

The sealed-tool, subprocess, workspace-worker, plan-fixture and family-fixture
source SHA-256s are respectively
`f06c714414e89274a2452873b11381831bc2bb528f4018ff251d70e6f6ac1eb0`,
`fb31af67903c52de7593b05c51e7459425e4baf806f7cce7a966cfa5f1eb902d`,
`0a25d7a827721187464acf4772c953e979f89547731cc5a3c5773e856d0265ea`,
`8596af674eb5106200543784597f302f4a55aa7c68dcd959b1fa078c24785df5`, and
`eab98a3e9f4263d8a0da000a07ce7aefc146112e272b511547466dafe7807129`.
The initial budget refusal, submitted failure, failure read-back, offline
diagnosis, corrected fixture and recovery read-back logs have SHA-256s
`cbb7139deb90e56c62df7b40dfc7f8771ab8b912926ead97484aef8759ac5bdf`,
`a9880c049200c7acc0a4892108049d298d35fa89811348fccc28b4852a380aa2`,
`dfeb04c18def555ec31c28bd65bdae68f9803bca2fbc45d1ec6c36d1d37886ce`,
`d99970f9f0a36b67fc3cc1b94ae53a1b2d15e958db96caa3f6d1b5061b6a06ea`,
`80741cd74c8d2fc46058bff589307ea6d88937c4b1fd843840a002f490516260`, and
`c02cc13b3336ea28cfb48a301b03c557a226827a35d09885d6441b37b5168e7c`.
The plan fixture's comment was subsequently corrected to describe both memory
envelopes; its current source SHA-256 is
`504de3b033814076397cc6723c81e5244b27dc97db6c5aa13a12490576decb5d`.

The managed sealed-operation result can now feed the existing single-test
transport decoder only when the workspace callback and operation both
completed without a changed-after result. Refusals and changed-source or
changed-output results are returned intact. This decoder does not authenticate
the producer or selection and does not decide a mutation outcome.

A real-manager fixture ran a confined sealed synthetic child that deliberately
forged the reporter's assertion-failure message. The decoder accepted that
well-formed transport, demonstrating why producer and selection binding remain
required; it was not counted as a mutation kill. Controlled wrappers around
the captured result confirmed that changed-source and changed-output outcomes
were retained instead of decoded, and the wrong-tool-digest refusal was also
preserved. The fixture itself checked those transport cases; independent
read-back checked the recorded units, input-file absence and synthetic output,
not the contents of the transient reporter pipe. The fixture root
`/tmp/prodbox-managed-reporter-final-EMqHgQEh` and publication records remain.

The warning-as-error executable/unit and fixture builds, formatter, HLint and
28 selected scenario-evidence tests passed. The workspace-worker and fixture
source SHA-256s are
`117f705d9e348d94080c8fc9cca48faa71e061666ccb8bde81e9653ee9c19744` and
`ab2490583f18fe1c8efb68091cd0799f7c906b89a881285eaae0e8bee912c032`.
The fixture and independent read-back logs under
`.build/phase1-managed-reporter-` have SHA-256s
`70e7bc48093bc2fd453a1c9ce0c857a9ed0c11d6a65191afc6fdf7c0f3e4c94b` and
`886014342ffb46ae4cc381ba9ded45eed75ff51d0e52d14ae825e3acede504f8`.
Actual mutant execution, authenticated toolchain and test selection, supported
cleanup and public acceptance remain open.

The current unit-test executable exceeds both the normal 128 MiB sealed-tool
limit and the kind-client 256 MiB limit. A separate mutation-test snapshot
budget now permits a declared maximum up to 512 MiB and charges its rounded
size and overhead to the runtime plan; the existing limits remain unchanged.
The budget is not a physical reservation or toolchain/selection authority.

A read-only outer probe sealed the actual unmodified unit executable built
after this change. It observed 278,190,968 bytes, a 281,018,368-byte kernel
charge and approximately 1.55 seconds for sealing plus an independent hash
read through the held descriptor. The source executable SHA-256 was
`98f2239735610b2dfba99cc1487817ee4f48791cd975d4fd0b185906d0e39a50`;
the external hash matched the sealed snapshot. The probe executed no test or
mutant and did not establish operation-family placement, measured capacity,
or dynamic-dependency authentication. An earlier pre-change executable was
also probed and its result is retained separately.

The first full build failed because the new test mixed `Integer` and `Natural`
units; after correction the warning-as-error executable/unit/daemon builds,
new budget control, existing sealing regression, 28 selected scenario-evidence
tests, formatter and HLint passed. The sealing source and daemon-test source
SHA-256s are
`cfad06405da6d73652d594143ae97296dd596d5e2c4819f7cf3118e47479313b` and
`c8d52992dc394160c93d265e1b4d86f31e57d3646062d5a5dc06a1a0b0cbfb41`.
The failed build, corrected build, final probe and budget-test logs under
`.build/phase1-real-test-seal-` have SHA-256s respectively
`9e7e1c784cef3a72742c85e3df30eded7023276e07e554211ce2ba68c9c74a48`,
`17e3424bc40c36bc06dec37b9ddaf046c9e970ab45e9a4a21fa17573536c57df`,
`9983c09188b59f3503caf43f75853a763a64771a0462921e7b8d21943ef06823`, and
`f582abbd1a3c72207489fa82c63d54f15184c1846b3a972f1b8b5bc5eab4b17e`.

The real unmodified unit-test executable was then exercised through the
managed mutation operation family with a separately funded 1 GiB synthetic
runtime envelope. The fixture sealed its 278,190,968 bytes, checked the
declared digest, required the exact single M01 test listing, and ran that test
with the mutation reporter. It retained the bounded selection and test
streams and exits. Independent read-back confirmed the exact test listing,
empty test stdout, `passed` reporter, successful exits, current binary digest
`98f2239735610b2dfba99cc1487817ee4f48791cd975d4fd0b185906d0e39a50`,
absence of the recorded units from the manager listing, and absence of the
published request/configuration files. Publication records remain retained.

This is a real unmodified test and reporter under the confined managed path,
but the fixture's source workspace is synthetic and is not bound to the
binary's build. Its runtime plan is declared, not a measured production
capacity envelope. Consequently it is neither an authenticated mutation
baseline nor a mutant run, and does not close A01-07. The first successful
root `/tmp/prodbox-managed-realtest-2k7JTSSa` and the final evidence root
`/tmp/prodbox-managed-realtest-final-ENKIkSZd` remain. Synthetic mutation and
RPC fixture regressions also passed and retained roots
`/tmp/prodbox-managed-realtest-synthetic-tMIOls3O` and
`/tmp/prodbox-managed-realtest-rpc-T1bPlw8s`. The native fixture build,
formatter, HLint and 28 selected scenario-evidence tests passed.

The plan and family fixture source SHA-256s are
`30a34ce60e54e08a65de7ab5d95328f19a04b77f7ba3f3bdc12ac7767c7994d3` and
`419c4844ea81609f02bbd6118f977308b0c49c9cb1d01c95f67553ff7a1a876a`.
The final real-test, independent read-back, synthetic and RPC logs under
`.build/phase1-managed-realtest-` have SHA-256s respectively
`c76200e3c3519d24932aa1d9a1726e3de103d433413731eff5c2fab07ae7f94f`,
`a6dd191a7bf30d75ccf226701d6cab14710a746024b32d1015318b7a09df2725`,
`83bc335dc7d6818569cd74e581d52f5118e2bb4578cde3e9c8a84479bb5d6d27`, and
`df125eea4511717efbb7e5b34be899bc6c14a7f7719b1175a77dc4c438ddf6d2`.

`prodbox test run evidence` is now a public named suite. It runs only the 28
scenario-evidence comparison cases of the compiled unit executable (stale,
fabricated, missing, duplicate/oversized and foreign-binding reports, plus the
snapshot/report-store cases) through `cabal test` with the pattern
`/scenario evidence comparison/`, with no deployment, cluster or credentials.
The warning-as-error build passed; the public binary run exited 0 with all 28
cases passing (2026-11-18, log `evidence.log` in the session scratchpad, not
retained in the repository). `test list` and its CLI assertion now include the
suite. This is a partial A01-06 observation only: the validator is exercised at
the library boundary, M02 has not been killed through the bounded executor from
this suite, and no wrong-scope negative control from an outer observer exists.
The canonical `./.build/prodbox dev check` then exited 0 on this change.
A01-06, M02 and Phase 1 remain open.

First `control reconcile` composition slice (private, not yet a public
command). `Prodbox.Control.Reconcile.reconcileNewNetwork` prepares the selected
fresh root, observes the daemon, records the kind intent and network proposal
under the lease, then creates the kind network through the held recorded
Docker session. Its subnet is kind's own first-attempt ULA proposal for the
network name; the unit suite pins it to a value computed independently with
Python `hashlib` (and kind v0.32's `generateULASubnetFromName`). A one-time
probe through `cabal repl` against the real local Docker daemon, with a
throwaway test identity `probe` and an isolated temporary root, returned HTTP
201; an independent `docker network inspect` observed the network
`prodbox-t-probe` with the expected subnet, IPv6 enabled, masquerade option and
the three ownership labels, and the before/after network inventory differed
only by it. The probe network was then removed by a hand `docker network rm`
(a hand action on a disposable probe resource: it does not qualify any
lifecycle run), and read-back showed it absent. Not done: volume, image load,
node create/start (needs the kind-controller placement launcher and the
broker's kubeadm exec route), kubeconfig, readiness, public CLI wiring and a
public remover. Open design points identified for the remaining slices:
admission callback definition, prior-worker settlement and the placement
launcher. T03, A01-01 to A01-05 and Phase 1 remain open.

The same private slice now continues to the node var volume:
`reconcileNewPrerequisites` creates the network and, only after Docker answers
201 with a network id, records the volume proposal under the recovered
operation and creates the volume through the held attempt. A second real-Docker
probe (`cabal repl`, throwaway identity `probetwo`, isolated temporary root)
returned 201 for both; the library's own read-back classified the volume as
matching and recorded its receipt. Independent `docker volume inspect` /
`docker network inspect` observed exactly those two new resources, each labelled
with the deployment, generation and operation, and the network id equalled the
reported one. Both were removed by hand (`docker volume rm`, `docker network rm`;
not qualifying lifecycle evidence) and the volume and network inventories were
read back identical to their before-state. Still not done: image load, node
create/start, kubeadm, kubeconfig, readiness, public wiring and remover.

The private composition now starts with the node image: the image preparation
records the kind intent and stages the retained archive, loads it, and the
orchestrator proceeds to the network and volume only after an independent
daemon lookup of the archive's config ID succeeds. To obtain an archive the
inspector accepts, the pinned `kindest/node` image (kind v0.32.0's default,
`v1.36.1`) was pulled from the public registry by hand, saved with
`docker save`, and repacked without Docker's extra `manifest.json` (the
inspector deliberately accepts only `oci-layout`, `index.json` and `blobs/`);
the archive's root index names the linux/amd64 platform manifest, so the config
pins that manifest digest `sha256:e98b1342...` rather than the multi-platform
index digest. The 918,947,840-byte archive (SHA-256 `2739823a...`) was retained
through the public `control import-artifact node-archive`; the public
`control inspect-node-archive` confirmed manifest/platform blobs for
linux/amd64 and config digest `sha256:152b34af...`. With the image first
removed from the daemon, a real-Docker probe (identity `probefour`, isolated
root) loaded it, created the network and volume, and returned 201 for both;
independent `docker image inspect` found the exact config ID (amd64/linux, no
tags), inventories differed by exactly the network and volume, and the public
`control status` reported the recovered operation, image intent and attempt,
network and volume matches. All probe resources were removed by hand (not
qualifying evidence) and inventories read back as before. Two findings: the
earlier network-first order was wrong because image preparation is the only
entry that records the kind intent; and `control reconcile` still needs the node
create/start launcher and kubeadm exec route before it can be activated.

Node create/start launcher findings (2026-11-18, read-only). The kind
placement profile (`prodbox-kind-controller.service` in `prodboxkind.slice`,
runtime directory `prodbox-kind`) is only observed by
`withKindHostSubprocessPlacement`; nothing in `src/` starts that unit. The
only launcher is the qualification fixture `test/qualification/KindHostPlacement.hs`,
which submits a `StartTransientUnit` over the user bus and re-executes the test
binary as `controller`. It works on this host only with `XDG_RUNTIME_DIR=/run/user/1000`
set (the user manager reports `degraded`; the current shell has no
`XDG_RUNTIME_DIR`). Productionising it needs: (1) a production launcher
and an internal controller entrypoint (`HostControllerKind` has no kind member,
and `HostControllerPublication*` plus its qualification codecs enumerate the
closed kinds, about 75 references in nine files); (2) a real host-capacity plan:
the fixture's `fixture` function compiles `HostExecutionPlan` and the kind
worker snapshot budgets from hand-picked numbers, which T04 must replace with
discovered, funded requests, limits and quotas before secret workers exist; (3)
the node create proposal (`mkKindNodeCreateIntent`) built from the loaded
image ID and created network ID; and (4) the broker's kubeadm/admin.conf exec
route, which the plan records as still open. Until (1)-(4) exist,
`control reconcile` cannot honestly be activated, so it remains unwired.

Managed kind node attempt, first public `control reconcile` (2026-11-18). New
`Prodbox.Control.KindController` productionises the qualification fixture's
launcher: it submits `prodbox-kind-controller.service` in `prodboxkind.slice` to
the user manager over the bus and the same executable re-enters through the new
internal `internal-kind-controller` inside that unit, where it runs the
archive-bound confined worker and writes one result line. `control reconcile`
(test identities only) runs image, network, volume, node proposal and worker
paths, launches the controller, and always ends Incomplete (non-zero) with a
retained-state message; it is the first public command that can create real
resources, with no remover until T06. `prodbox` is now linked `-threaded`
(managed controllers pass `-N1`; kind workers need a bound thread). The image
step now records its load result (`withNewConnectedNodeImageRecordedAttempt`),
the network step records its receipt, and `kindNodeRunArguments` exposes the
node argv that the observed matcher already encoded.

Eleven real runs against the local Docker daemon and user manager, each on a
fresh throwaway test identity, advanced the boundary reached in this order, and
each refusal was a true defect in the composition, not in the host: the `+RTS`
heap cap must equal the plan's heap cap; the unit's runtime cap must exceed the
finish deadline and fit the child budget; the declared envelope needed a larger
container limit (768 MiB for the sealed snapshots), a parent CPU quota of one
core (at 10% the proposal observer's 10-second bound expired), and 65,536-byte
output ceilings; the image result and network receipt records were missing; and
the worker directory tree must be prepared before the broker opens it. The
real kind v0.32.0 then ran confined, reached `docker info` through the bridge,
and the broker's read gate accepted real daemon info (checked directly). Then
the attempt stopped: each broker request evaluates the archive-bound stability
closure several times and each evaluation re-observes the node image and the
network, about 1.4 s, so one request takes more than the bridge client's 5 s
(raised to 60 s here, which is a bound change that needs review); with the
session capped at 180 s the worker never reached node creation. No `run`
attempt was recorded and no node existed. Diagnostic instrumentation used to
find this was removed. Probe resources, retained roots and the loaded image were
removed by hand after each run (hand actions, not qualifying evidence) and the
Docker volume, network, container and image inventories read back as before.
This is not A01-01: no node, mount recreation or kubeconfig exists. Open: make
the per-request stability cost proportionate (cache or narrow the closure, a
design change to the recheck-around-each-request rule), the kubeadm/admin.conf
exec route, a measured capacity envelope replacing the declared one (T04), the
public remover (T06) and the readiness read-back.

Real node create and start through the confined worker (2026-11-18, later
session). Fourteen further real runs on fresh throwaway test identities took
`control reconcile` from "kind cannot finish a Docker read" to a created,
started and booted kind control-plane node. The measured cause of the earlier
stall was the nested stability closure: one evaluation re-observed the image and
network (about 1.2 s), the node-proposal check repeated that five times inside
itself, and each broker action nested the check again, so one request cost
several seconds. Three changes, each needing review before any non-test
admission: the image and network observation inside one evaluation now use the
archive and peer check, with the full record check bracketing the evaluation once
(`networkStable`); the broker's proposal check is one bracket around a single
record read (the read verifies file identity itself); and a passing stability
observation is reused for 400 ms by `recentStable` (a failing one is never
reused, so a change that persists is always detected; one that appears and
reverts inside the window is not). The bridge client's per-request bound is 60 s
instead of 5 s. With these a full attempt takes about 100 s and the Docker
session cap of 180 s is no longer the limit.

Four real-Docker facts the synthetic fixtures did not model, each fixed with a
positive and negative control: a created container reports an empty `NetworkID`
until it starts and `NetworkMode` is normalised to the network ID; Docker appends
`label=disable` to a privileged container's security options; TTY init writes
ANSI colour sequences into the boot line the broker matches; and the archive
endpoint returns gzip because the client advertises it (the strict tar parser
now asks for identity). Config writes reuse the start admission through
`newKindNodeBrokerWithConfig`.

Observed in the last real run: the broker served `info`, `run`, `logs -f`,
`inspect`, `exec cat /kind/version`, `inspect -f` addresses and `mkdir -p /kind`;
the run recorded create (201) and start (204) results; the public
`control status` reported "node daemon replied 201" and "node start daemon
replied 204"; the container was up when read. kind's next request, the kubeadm
configuration copy, was refused: the retained matcher encodes kubeadm v1beta3
and the node image v1.36.1 produces a different shape. That is the start of the
kubeadm gap, so no cluster, kubeconfig or readiness exists and A01-01 is not
met. The probe node, volume, network, image and roots were removed by hand
(hand actions, not qualifying evidence) and the Docker inventories read back as
before. Diagnostic instrumentation was removed. Open: the kubeadm
configuration acceptance and `kubeadm init`/`admin.conf` exec route, the
kubeconfig writer and readiness, a measured capacity envelope (the declared
one is unmeasured: one core, 64 MiB heap, 768 MiB container), the public
remover (T06) and recreation, adverse and policy cases (A01-02 to A01-05).

kubeadm configuration (2026-11-18). A throwaway real kind v0.32.0 cluster on
node image v1.36.1 (hand diagnostic, deleted; Docker containers and networks
read back as before) showed the node's `/kind/kubeadm.conf` is kubeadm v1beta4:
five documents, extra arguments as ordered name/value lists, not the v1beta3
maps the retained matcher encoded. `matchesKindKubeadmScope` and
`matchesPinnedKindKubeadmConfig` now accept exactly the two observed shapes
(v1beta3 map form, v1beta4 list form) and still compare the whole document
set; a unit test pins the real v1beta4 file (cluster name substituted) and
rejects a changed node address, kubernetes version and a flipped
`unsafeSkipCAVerification`. A real `control reconcile` then wrote the
configuration into the node (daemon replied 200, recorded: the public
`control status` reports "node configuration attempt recorded ... daemon
replied 200"). kind's next request, `kubeadm init`, is not served: the broker
has no exec route for it and no design exists in the retained code (the
sequence after the config write is `kubeadm init`, `cat
/etc/kubernetes/admin.conf` which carries cluster credentials, stdin-fed
`kubectl` applies for the CNI and storage manifests, and taint changes).
That route needs attempt/result records, a private admin.conf custody path,
bounded streaming output and its own admission, so it is the next owned work;
until it exists `control reconcile` cannot produce a cluster. The probe node
and roots were removed by hand.

Early control removal, P01-T06 (2026-11-18). `control delete --yes` removes a
new test identity's recorded node, node volume and kind network through the
retained removal operations in that order (`Prodbox.Control.Delete`). The node
step first requires an independent Docker CLI inventory that positively lists the
recorded container, then writes the removal control record and runs the recorded
removal; the volume and network steps use their own write-ahead attempt and
result records; the loop stops at the first step that is not completely
recorded. Production and foreign identities, and identities without an exactly
matching recorded operation, are refused before any effect. Real evidence on a
fresh throwaway identity that `control reconcile` had taken to a running node:
the three removals returned 204 and wrote their results; independent
`docker ps -a` showed zero containers and the volume and network inventories were
identical to their before-state; the public `control status` reported the node
removal inventory "target not listed, 0 name matches, 0 cluster-label matches
in repeated reads"; a second `control delete --yes` refused ("the independent
inventory did not positively list the recorded node") and a production config was
refused with nothing touched; omitting `--yes` prints usage. The loaded node
image, the retained root, artifacts and every record remain by design; the
image and scratch root were removed by hand afterwards. This is a partial T06
slice: it handles only identities that cannot have admitted cloud effects, and
absence is still reported as unverified by the status text (replies are not proof).
Not yet done: kubeadm init route, kubeconfig, readiness, measured capacity,
recreation after node loss, adverse and policy cases.

Cluster initialization through the broker (2026-11-18, latest). A real
`control reconcile` on a fresh throwaway test identity now ends with kind itself
exiting successfully inside the confined worker ("Starting control-plane",
"Installing StorageClass", "Set kubectl context"): a Kubernetes v1.36.1 control
plane is running in the recorded node. Independent checks with the private
(0600) kubeconfig kind wrote in the worker scratch: the API server answered on
the identity's loopback port, the node was listed (NotReady, as expected with
the default CNI disabled by the plan's kind configuration and no platform CNI
yet), the `standard` StorageClass existed, and the control-plane pods were
present. The route is `Prodbox.Control.KindNodeBootstrap`: it recognises only
the exact post-config requests kind v0.32.0 sent in a real run recorded with a
logging wrapper (`kubeadm init`, the node taint and label, the default
manifests, the stdin `kubectl` applies, the cluster-admin credential read, two
port inspects), for the selected node only. Mutating steps need their
prerequisite's recorded success, write an attempt record before the effect and a
result record (exit code, output digests and lengths) after it, and are executed
by the trusted controller through a bounded Docker CLI call on the selected
socket, not by the confined worker; stdin manifests must equal a fresh read of
the node's own file. Real-run findings fixed on the way: the declared controller
task budget (16) made the Go Docker CLI fail on `pthread_create`, now 64
(declared, unmeasured); the config write's read-back and every archive read
needed `Accept-Encoding: identity`; kind installs the CNI and storage steps
concurrently so they depend only on the label step; the bridge client bound is
175 s and the archive wrapper bound 540 s because one attempt now takes about
110 s. The removal also had a leak: container removal used `v=0`, so the node
image's anonymous volume remained; it is `v=1` (only anonymous volumes of that
container; named volumes are never touched) with updated fixtures, and a full
cycle (reconcile, cluster checks, `control delete --yes`) then left the Docker
container, volume and network inventories identical to their before-state. The
classifier has unit tests with negative controls. Admission remains the narrow
test-identity-only local permission; the declared envelope is unmeasured; the
default CNI is out of scope here (T04 owns management policy). Still open:
copying the credential to a validated `control/kubeconfig` under the retained
root (it still lives in the worker scratch), readiness and the status read-back,
measured capacity (T04), recreation after node loss, and the adverse and policy
cases; A01-01 is not yet claimed because no run was recorded through the
evidence runner.

Credential custody (2026-11-19). `Prodbox.Control.KindKubeconfigInstall`
moves the cluster credential kind wrote in the worker scratch into the retained
root's `control/kubeconfig`: the source is read through no-follow descriptors
under the generation-checked root and must be a private (no group/other bits),
single-link regular file owned by the operator and at most 512 KiB; its decoded
document must validate against the selected scope (cluster, context and API
address) before anything is written; the `control` directory is created 0700 if
absent and verified, the destination is created exclusively at 0600 and
synchronised with its directory, and it is read back through the ordinary
reader. An existing destination is never replaced and credential bytes are never
rendered or logged. The managed controller calls it after the attempt; a missing
source is a normal outcome of an unfinished attempt. Real evidence on a fresh
throwaway identity: the install reported `KindKubeconfigInstalled`, `control` was
mode 700 and `kubeconfig` mode 600, `kubectl` listed the control-plane node
through the installed file, the public `control status` reported "selected local
file is structurally valid; cluster identity and certificates unverified", and a
second install reported `KindKubeconfigDestinationExists` without touching the
file. (A first version failed on `fdRead` signalling end-of-file by exception;
fixed.) `control delete --yes` then removed the node, volume and network and the
Docker inventories read back as before; the credential file stays in the retained
root by design. Readiness is not claimed: the node is NotReady until a platform
CNI exists, which T04 owns, so the readiness read-back belongs after T04. Still
open: management CNI policy and capacity discovery (T04), recreation after node
loss (A01-02), cross-environment and adverse cases (A01-03), the evidence
runner and bounded mutation executor wiring (T05, T07), and recorded A01
acceptance runs.

Adverse isolation cases through the public binary, partial A01-03
(2026-11-19). Each case ran the built `prodbox` against throwaway test
identities with an outer observer (Docker inventories, retained-root listings,
host network objects) read before and after. (1) A foreign same-name Docker
network carrying a marker label: `control reconcile` loaded its owned image,
then the network create was answered 409 and recorded, nothing further ran; the
foreign network kept its ID and label and no container or volume appeared.
(2) A declared node archive that was never imported: refused with
`ScopeArtifactMissing`, no image pull, no Docker object created. (3) A root
that is a symlink: `control status` reported the root could not be safely
observed and `control reconcile` was refused at the lease; the link target stayed
empty. (4) A second identity whose anchor lies inside another identity's
retained root: both commands refused (`FreshScopeUnobservable`) and an
independent `find` listing of the foreign root was identical before and after.
(5) `DOCKER_HOST`, `KUBECONFIG` and `DOCKER_CONFIG` set to nonexistent hostile
values: `control status` output was identical to the clean run except one
volatile available-memory reading, so the selected socket and root were used,
not the ambient ones. After the cases the Docker container, volume and network
inventories were identical to their starting state; scratch directories were
removed by hand. Not covered: an actual production root and cross-environment
pair on this host, `.data/` sibling configuration, and the recorded evidence
runner (A01-06 and T05 still own the report binding), so A01-03 stays open.

Observed usage against the declared envelope, partial T04/A01-05
(2026-11-19). One real `control reconcile` that reached a running control plane
was sampled every two seconds from the user manager's cgroup files for the
controller unit and its slice, then `docker stats` read the node. Observed: the
controller unit's `memory.peak` 239 MiB (it holds the sealed kind tool and
client snapshots), the slice peak 246 MiB, at most 21 tasks in the unit (the
first declared limit of 16 was therefore too small, matching the earlier Go
`pthread_create` failure; the declared 64 gives about three times the observed
peak), and the node container 426 MiB with 160 tasks and about 26% of a core
sampled once after start. The declared controller envelope (768 MiB container
limit, 64 tasks, one core, 64 MiB heap cap) is larger than the observed peaks
with margin, so it is supported on this host for this single control plane, but
it is one run on one host: no repeated runs, no load, no simultaneous
management-plus-secret-worker workload (none exists until Phase 2), and no
test that insufficient capacity rejects before work beyond the host-observation
unit cases. The node's own container limits and Kubernetes requests, limits and
quotas are not yet set. A01-05 stays open. The cluster was removed with
`control delete --yes` and the Docker inventories read back identical.

Management CNI and policy enforcement observed, P01-T04 / A01-04
(2026-11-19). The CNI is kindnet from the pinned node image: the plan's kind
configuration no longer disables the default CNI, so no external image is pulled
(every test image also ships in the node and runs with pull policy Never). An
empirical check on a throwaway cluster first showed kindnet enforces
NetworkPolicy with real sockets. The broker now serves the CNI install: kind
renders the node's `/kind/manifests/default-cni.yaml` from a template and a
parsed object model before piping it to `kubectl create`, so the payload is
bound semantically (decoded documents equal the node's file with the pod subnet
substituted and the single `CONTROL_PLANE_ENDPOINT` environment entry kind
appends; the storage manifest stays byte-for-byte). A real run reached a `Ready`
node with kindnet, kube-proxy and both CoreDNS pods `Running`. The product then
runs `Prodbox.Control.NetworkEnforcement` at the end of `control reconcile`: in a
throwaway namespace a CoreDNS pod serves TCP, bash clients connect through
`/dev/tcp`, and four observations are taken. Real result: baseline both clients
connected (the observer works), with the ingress policy applied the allowed
client connected and the other did not, and with the policy deleted the other
connected again; the namespace was removed. `enforcementProven` accepts only that
complete pattern and rejects a blind observer, a lost allow, a missing deny and an
unrestored connection (unit controls). Negative control on a real cluster: with
kindnet stopped and its `kindnet-network-policies` nftables table deleted in the
node, the identical observer saw the forbidden client connect and reported not
proven. So a successful policy apply was never treated as evidence. Limits: the
pinned management policies of later phases do not exist yet (the policy applied
is the observation's own fixture), traffic is node-local on a single-node
cluster (no cross-node path), the check runs after creation and is not yet a
gate before secret handling, and A01-04 is not recorded through the evidence
runner. A01-04 stays open for those reasons; node readiness now holds, so the
readiness read-back can be built.

Recreation after node loss, partial A01-02 (2026-11-19). `control reconcile`
on a retained root whose previous operation was completely removed now archives
that operation first (`Prodbox.Control.Recreate`): only when removal results
are recorded for the node, the volume and the network, and an independent Docker
listing shows no container of the selected cluster, it moves (renameat, nothing
is deleted) the operation's records, its worker directory and the old cluster
credential into `history/<operation>/`, leaving the generation record, the
retained artifacts and all host data in place, and then runs a fresh operation
with its own exclusive records. Real run through the public binary on one
throwaway identity: a first `control reconcile` produced a Ready node (and the
network enforcement observation proven); a real Pod mounting the node's
`/var/lib/prodbox` host path wrote a random 128-bit marker, and the outer observer
read the same bytes on the host as a root-owned file; `control delete --yes`
removed the node (`docker ps -a` empty) and the marker was unchanged; a second
`control reconcile` on the same config archived the first operation under
`history/`, created a new node, a new credential and a new set of records, and
proved enforcement again; a new Pod on the recreated node read back exactly the
original marker. Negative control: the same config with a different
`root_generation` was reported by `control status` as "foreign or different root
generation" and `control reconcile` was refused at the lease
(`KindLeaseGenerationUnavailable`), with no new records and no history entry. A
second delete left the marker intact and the Docker inventories read back as
before. Not covered: the distinct wrong-mount failure (a node whose bind mount
points elsewhere), loss of the node container by an event other than the
adapter's own removal (a killed or missing container with intact records), and a
recorded evidence-runner report, so A01-02 stays open.

Readiness read-back and an unsupported node-loss path (2026-11-19). `control
status` now appends a Kubernetes readiness line from
`Prodbox.Control.KubernetesReadiness`: only when the ordinary reader accepts the
installed kubeconfig for the selected scope it runs three bounded read-only
`kubectl` queries (the API server's `/readyz`, the node Ready conditions, the
kube-system pod phases) and reports one point observation, explicitly not a
certificate or identity check; the status footer no longer claims readiness is
unchecked and says network policy enforcement is observed only by
`control reconcile`. Real run: before any cluster the line says "not observed (no
acceptable installed kubeconfig)"; on a Ready cluster "API /readyz ok; nodes Ready
1 of 1; kube-system pods Running 8 of 8"; with the node container stopped
"unobservable; API readiness: exit ExitFailure 1"; after restarting it the same
Ready line returned within 45 s (kind nodes survive a stop/start). Finding:
force-removing the node container outside the adapter (`docker rm -f`) leaves a
state the public commands do not recover. `control status` shows the node's
create reply as recorded and the independent removal inventory "not observed";
`control reconcile` refuses with `ArchiveNotCompletelyRemoved` (no removal results
were recorded); `control delete --yes` refuses ("the independent inventory did not
positively list the recorded node") because its positive control needs the node.
Records were retained and nothing was changed, which is the safe refusal, but the
node volume and the network had to be removed by hand (a hand action, not
evidence). A supported recovery needs an observer positive control that does not
depend on the missing container and a recorded disposition for a node whose
absence is observed rather than removed; that is open work under A01-02, and the
distinct wrong-mount case is still unexercised.

Node loss outside the adapter, recovery (2026-11-19, A01-02 partial). The
refusal recorded earlier is now followed by a supported disposition.
`control delete --yes`, when the recorded node is not listed, no longer stops: it
first requires the sampled inventory to show no name or cluster-label match,
then creates a never-started control container from the recorded image with a
distinct `io.prodbox.absence-control=<operation>` label, and accepts absence only
if that label filter lists exactly the control container, the node's full ID is
not listed, and the control container is removed again with an empty re-listing;
only then it writes the exclusive record `kind-node-absence-observed.json`
(operation, node ID and control ID) and continues with the volume and network
removals. The record stands in for the node removal result in
`Prodbox.Control.Recreate`'s precondition and for nothing else; a blind or
unlisted control, a failed control removal or a failed record write leaves the
step incomplete with nothing recorded. Real run on one throwaway identity: a
Ready node and a root-owned marker file in the host root; `docker rm -f` of the
node; `control delete --yes` reported the absence disposition and removed the
volume and network (Docker containers, volumes and networks read back as before,
no control container left); a second `control reconcile` archived the first
operation (including the absence record) under `history/`, created a new Ready
node, proved NetworkPolicy enforcement again, and a new Pod on it read back
exactly the marker the host root held (`f8b772ef459f9257`, equal to the host
file). The disposition is a read of one daemon's inventory at one time, not a
settlement of any worker. Still open for A01-02: the distinct wrong-mount case
and a recorded evidence-runner report.

Wrong-mount case, A01-02 partial (2026-11-19). With a first identity's node
running, a second config with the same deployment ID (so the same cluster name)
but a different `project_anchor` (so a different retained root) was prepared and
inspected through the public binary: its `control status` reported "Docker
inventory: control-plane container running; retained bind source, target, or
configured write flag differs", a finding distinct from the generation mismatch
("foreign or different root generation") and the foreign-network refusal;
`control delete --yes` for it refused with `KindIntentMissing` and `control
reconcile` refused at the missing artifact before any Docker effect; an
identity comparison of the first node's ID and start time showed it unchanged,
and the Docker inventories read back identical after the first identity was
removed by `control delete --yes`. Not covered: a node created with a bind mount
that differs after the fact (only the cross-root case), so A01-02 remains open
for the evidence-runner report.

Repeated capacity observation, A01-05 partial (2026-11-19). Three consecutive
full `control reconcile` + `control delete --yes` cycles on fresh throwaway
identities were sampled every two seconds from the user manager's cgroup files:
controller unit `memory.peak` 241, 242 and 242 MiB, slice peak 249, 250 and
250 MiB, at most 20, 20 and 21 tasks, and the node container (read after the
enforcement observation, with its test pods already removed) 527, 529 and 536
MiB with 249 to 255 tasks; each cycle's NetworkPolicy enforcement observation
was proven and the Docker inventories read back identical after the third.
Against the declared envelope (768 MiB container limit, 64 tasks, one core, a
64 MiB heap cap) the controller peaks leave about 3x memory and 3x task
headroom, stable across cycles on this host. Not covered: insufficient
capacity rejected through the public binary before any work (only the
host-observation unit cases), concurrent identities, a workload beyond the
control plane (none exists until Phase 2), and Kubernetes requests, limits and
quotas on the node's own system pods. A01-05 stays open.

Production/test pair, A01-03 partial (2026-11-19). A production-environment
config and a test-environment config with the same deployment ID, anchored in two
separate scratch projects (not this host's real `.data/`), were inspected
through the public binary: the production identity resolved to a `.data/`
root and cluster name `prodbox-p-<id>`, the test identity to a `.test-data/` root
and `prodbox-t-<id>`, so the same ID cannot alias; the production identity's
`control reconcile` was refused ("supports only test identities") and its
`control delete --yes` refused ("only a test identity may use early removal")
before any Docker call; neither project gained a file and the Docker container
inventory stayed empty. Together with the earlier foreign-network, symlink,
nested-root, missing-archive, hostile-ambient and wrong-mount cases this covers
the listed adverse inputs except the unavailable-node-image pull denial through
a network-level observer and a rewritten production sibling config; A01-03
stays open for the evidence-runner report and a real production root.

Scenario runner and recorded evidence, T05 and A01-01/A01-06 partial
(2026-11-19). `prodbox --config <identity> test run phase-01` now runs
`Prodbox.Test.Phase01Runner`: for an explicitly selected, prepared test
identity it drives the built public binary through one lifecycle (`control
reconcile`, `control status`, `control delete --yes`, `control status`),
records four claimed observations from the commands' own output
(`context.scope`, `cluster.ready`, `cleanup.absence`, `host.data-retained`),
then takes the same four with other tools (kubectl through the installed
credential plus the Docker CLI for readiness, Docker container/volume/network
listings for absence, direct reads of the retained root and its generation
record), binds the report to the worktree source identity, the running
binary's digest, the kind-tool and node-archive digests, the selected scope,
generation, a fresh run and operation identity, the boot ID and absolute
monotonic deadlines, publishes it in the append-only store (the runner creates
the private `.build` the store requires) and validates it against the
independent observations. Production identities are refused. A real run
reported claimed = independent = satisfied for all four, primary succeeded,
cleanup confirmed, `EvidenceChecksSatisfied`, exit 0, and the Docker
inventories read back identical. A second concurrent run exposed that the
managed controller has one fixed unit name, so two scenarios cannot run at the
same time: one passed and the other failed honestly (readiness and absence
unsatisfied, primary failed, cleanup failed, `EvidenceChecksUnmet`, exit 1),
and its failure report was kept, not replaced. That failure also exposed two
real defects, fixed: `control delete --yes` and `control reconcile`'s archive
step now treat an operation whose node create attempt was never recorded as
having no node to remove (an attempt without a result still keeps its records
for recovery), and the leftovers were then removed through the public command.
Two environments created one after the other then coexisted Ready with
distinct node names, networks, API ports (26660 and 26661), kubeconfig
contexts and host-mount sources, and were removed with `control delete --yes`
(inventories identical). The unit suite's fabricated, missing, stale and
wrong-scope report cases remain the negative controls of the validator
(`test run evidence`). Still open: the runner covers case 1 only (recreation,
network enforcement and the adverse cases are not yet scenario reports), claims
and observers share one process, only one scenario can run at a time on a host,
and the bounded mutation executor (A01-07, T07) is not wired, so no A01 case is
closed.

Scenario reports for cases 1, 2 and 4 (2026-11-19). `test run phase-01` now
makes one pass of two lifecycles on the same retained root and publishes three
validated reports. Case 1 (lifecycle) as before. Case 4 (network enforcement):
claimed from `control reconcile`'s own "PROVEN" line, with the runner re-running
the real-socket observation in a separate namespace as the independent
observation. Case 2 (recreation): a real Pod writes a random 128-bit marker into
the host root, the first node is removed through `control delete --yes`, a
second `control reconcile` recreates it on the same root and generation, a new
Pod reads the marker back; claimed from the Pod logs and the commands' output,
independently observed by direct reads of the marker file before and after, a
comparison of the two node container IDs (different) and a listing of the
retained `history/` directory (the archived first operation). Real result: all
three reports claimed = independent, primary succeeded, cleanup confirmed,
`EvidenceChecksSatisfied`, exit 0; Docker inventories identical afterwards.
Preceding runs are kept as the record of what failed: a first version's case 2
report was `PrimaryFailed` with an observation mismatch because the Pod helper
reused a one-byte stdin ceiling and never applied its manifest (the diagnostic
`detail:` line the runner now prints named the cause), and its validator returned
`EvidenceObservationMismatch` rather than a pass, which is the validator
doing its job. Limits: claims and observers still share one process, case 4's
independent observation repeats the same real-socket method in another
namespace, the adverse cases (case 3) and capacity (case 5) are not scenario
reports, only one scenario can run per host, and A01-07's bounded mutation
executor remains unwired, so no A01 case is closed.

Bounded mutation executor wired (2026-11-19). `test run phase-01-mutation`
(`Prodbox.Test.MutationExecutor`) snapshots the secret-filtered worktree and the
build objects into a private `.build/mutants/<stamp>/<case>` workspace, probes
the isolation boundary in the very container the build then uses (network `lo`
only, no Docker socket, no `test-secrets.dhall`; the pinned node image supplies
only a root file system, the host toolchain is mounted read-only), builds and
runs the designated test as baseline, applies one patch, rebuilds, requires the
single-test selection to be bound to each binary digest, runs the one test with
`--mutation-assertion`, verifies cleanup by label listing and classifies with
`classifyMutationAttempt`. Unprivileged namespaces, systemd sandboxing and
bubblewrap were each measured on this host and give no network boundary here
(the container does). Real result: M01 Killed (`context.rejects_root_alias`),
M02 Killed (`evidence.rejects_unbound_result`), a compiled change the test
cannot see Survived, a non-compiling source Invalid, a 1 ns test timeout
Inconclusive; exit 0 only when every outcome equals its expectation; workspaces
removed, no containers left. A first run caught a defect in the executor itself:
the build command's status was masked (dash has no PIPESTATUS), so a
non-compiling mutant looked built; the classifier still refused it
(unchanged-binary digest = Inconclusive), and the status is now captured from a
log file. Limits: baseline and mutant builds take about four minutes each per
case, the host `/usr` is mounted read-only into the container, and equivalence
is never inferred. Cases 3 and 5 and the pinned management policies remain open.

Case 3 partial scenario report (2026-11-19). The same `test run phase-01`
pass now also creates a foreign Docker network holding the cluster's network
name (label `owner=foreign-a01-03`), runs `control reconcile` through the public
binary, and publishes a fourth validated report: the command refused (non-zero
with output), an outer `docker network inspect` of id, creation time, labels and
attached-container count is identical before and after, no control-plane node
exists, and after the runner removes only its own foreign network the cluster
absence check passes. Real result: `EvidenceChecksSatisfied`, exit 0, Docker
inventories identical. Covers only the foreign same-name network of A01-03;
cross-environment, overlapping, symlinked and foreign roots, ambient
kubeconfig and the unavailable node image are not yet scenario reports, so
A01-03 stays open (the earlier manual adverse rounds are not evidence for it).

Evidence-validator report, A01-06 (2026-11-19). The same pass drives
`validateStoredScenarioReport` against the real stored case-1 report: the
untampered pair is accepted (positive control) and five tampered variants are
each rejected: a flipped independent observation, a missing independent
observation, a stale independent window (started after the report), a wrong
generation, and a nonexistent operation (missing report). Real result: all five
rejected, control accepted, `EvidenceChecksSatisfied`, exit 0, Docker
inventories identical. A first version of the stale variant widened the
independent window instead, which the validator correctly accepted (an outer
window may be wider); the variant was wrong, not the validator, and was fixed.
The "fabricated, wrong-scope" report shapes beyond these variants, and
validation by a process other than the runner, remain unexercised.

Case 3 extended: ambient kubeconfig (2026-11-19). While the first cluster is
Ready the runner starts an outer listener on a decoy port, writes a decoy
kubeconfig naming it, and runs `control status` with `KUBECONFIG` pointing at
the decoy. Claimed: the public output still reports the real cluster's
`/readyz ok`. Independent: the listener accepted zero connections and the decoy
file is byte-identical. The listener is stopped by a stop file and its exit is
part of the cleanup result. Real result: case 3 now carries four observations,
all satisfied, `EvidenceChecksSatisfied`, exit 0, Docker inventories identical.
A01-03 still lacks cross-environment, overlapping, symlinked and foreign-root
actions and the unavailable node image. A01-05 (insufficient capacity rejects
before work) was investigated and not built: the controller envelope is
compiled from a fixed declared allocation against the observed host, so a real
shortage needs a genuinely small filesystem or exhausted memory. Loop mounts
via udisks are not authorized for this user, `unshare` is blocked by the
unprivileged-namespace restriction, and exhausting host memory with earlyoom
active is unsafe, so no honest negative was produced.

Case 3 extended: symlinked, foreign and wrong-generation roots (2026-11-19).
Three configs are derived from the selected one and run through the public
`control reconcile`: a project whose `.test-data/<id>` is a symlink to a victim
directory, a project whose root is an existing directory holding someone else's
file and no generation record, and the real root with a different generation.
Each was refused (non-zero with output); the symlink victim and the foreign
directory read back byte-identical, the real root's generation record is
unchanged, and no container, network or volume bearing the adverse names
appeared. Case 3 now has seven observations; all satisfied, `EvidenceChecksSatisfied`,
exit 0, Docker inventories identical, derived directories removed. A first run
failed on my own observer (the full-absence check cannot pass while the
case's foreign network, named after the cluster, still exists); the observer
was changed to containers and volumes, not the product. A01-03 still lacks
cross-environment and overlapping-root actions and the unavailable node image.

Case 3 extended: unavailable node image (2026-11-19). A config derived from the
selected one names a node image digest no registry or cache holds, and runs
through the public `control reconcile` on the real retained root. It was
refused; an outer `docker image ls -a --no-trunc` is identical before and after
(no pull, no import) and no container of the cluster exists. Case 3 now has
eight observations, all satisfied, `EvidenceChecksSatisfied`, exit 0, Docker
inventories identical. A01-03 now lacks only cross-environment and
overlapping-root actions, which need a second admitted scope, and independent
validation outside the runner.

Case 3 extended: cross-environment (2026-11-19). The selected identity declared
as `production` in a project with no production root runs through the public
`control reconcile`: refused, and the project directory is still empty, so no
root was created. Case 3 has nine observations, all satisfied,
`EvidenceChecksSatisfied`, exit 0, Docker inventories identical. Overlapping
roots across two admitted scopes remain unexercised through the binary; that
needs a second admitted scope.

Capacity admission before work, A01-05 negative (2026-11-19). The earlier note
that a real shortage could not be produced was wrong about the means: the
admission reads the process's CPU affinity, so `taskset -c 0` on the public
binary is a real, safe, reversible shortage (the declared envelope needs 2000
milli-CPU). Measured first: `control reconcile` under one CPU got as far as
loading the image, creating the network and volume, and only then failed in
the controller with `ObservedHostDimensionInsufficient "milli_cpu" 1000 2000`,
so it refused after work. `reconcileNewPrerequisites` now takes an admission
action that runs after the root exists and before the archive, image, network,
volume or node effect (`kindHostCapacityRefusal`, the same compiled envelope the
controller uses); a refusal leaves only the root and its generation record.
Real result in 38 ms: "Refused before any work ... milli_cpu 1000 2000", root
listing unchanged, no image, container, volume or network. Case 5 is now a
scenario report with a positive control (the unconstrained reconcile of the
same pass was admitted and reached Ready) and the negative; both observations
satisfied, `EvidenceChecksSatisfied`, exit 0, inventories identical. Actual Pods
under real limits and measured usage remain the earlier hand measurements, not
part of the report. A second fixture defect surfaced: the wrong-generation
config and case 6's wrong-scope variant used `ffff...`, which equalled the
probe's real generation, so case 6 correctly failed and case 3 only passed
because the foreign network blocked the run; both now use a generation derived
to differ from the real one.

L04/L05 disposition survey (2026-11-19, no source removed). Exact remaining
ambient-context reads of `KUBECONFIG`, found by grep: `TestValidation.hs`
(`lookupEnv "KUBECONFIG"` in the AWS-substrate overlay near line 1721 and the
`setEnv`/restore pair near 1755), `Infra/MinioBackend.hs:123` and
`Infra/SubstrateKubectl.hs:46` (`lookupEnv` then `setEnv`/restore). Every one
serves the legacy AWS-substrate and harness paths that Phases 5 and 6 replace;
`control reconcile`, `control status`, `control delete` and the kind worker never
read it (case 3 proves the ambient decoy is unused, and the worker sets its own
scratch kubeconfig). Deleting them in Phase 1 would change behaviour no
replacement acceptance covers and that cannot be validated without live AWS, so
L04's absence check ("no new path selects ambient or overwrites production")
holds only for the new surface and the row stays Pending. L05: actual kind
recreation retaining exact host data is proven (case 2) and the new install path
has no RKE2 service dependency (no `rke2` reference in `Control/` except the
declared capacity-vector field name `rke2_reserved`), but the legacy
`CLI/Rke2.hs` command family and 110 other files still reference RKE2, so the
absence check fails and the row stays Pending. Neither row may close until the
later phases that own those legacy surfaces land their replacements.

Pinned management policy, A01-04 (2026-11-19). `Prodbox.Control.ManagementPolicy`
now owns the management network policy as a constant: a default-deny ingress
policy for every pod in the namespace plus one allow, under which pods labelled
`prodbox.io/plane: management` accept ingress only from pods labelled
`prodbox.io/management-client: "true"`; its template digest
`2c1315f28b5af5c7c5353b4e87beaf5931b1b5db32989e2c8ada87529e94dbf3` is pinned by a
unit test, so an edit must be reviewed. The enforcement observation
(case 4) now applies exactly this policy (previously a private fixture policy):
real sockets show the management client still connects, an unlabelled client is
refused, and removing both policies restores the connection. Real result: all
six reports `EvidenceChecksSatisfied`, exit 0, inventories identical. Limits:
it is applied to a throwaway observation namespace, not installed
persistently, and the actual Vault/MinIO/Broker workloads and their roles
arrive in Phase 2, so "the policy protects those services" and the refusal of
secret handling when enforcement is unproven are not yet exercised.

Counterexample found and repaired: nested retained root, A01-03 overlap
(2026-11-19). Probing the overlapping action through the public binary showed
that a config whose project anchor is another scope's retained root was
accepted: `control status` reported a candidate, and `control reconcile` created
`<outer root>/.test-data/<id>/` with `kind-intent.json` and
`scope-generation.json` inside the outer scope's root (measured before the fix:
the outer root's listing gained `.test-data`). `requireDisjointKindPlans` is a
pure function no public path calls, so nothing compared the two scopes. Repair:
`prepareScope` now refuses with `FreshScopeNestedInRetainedRoot <dir>` before
any write when the anchor or any ancestor directory holds a
`scope-generation.json`; a unit test builds a real outer root, then an inner
scope anchored on it, and checks the refusal, that no directory appeared in the
outer root and that the outer generation still matches. The scenario now
includes `adverse.nested-root-refused` (the outer root listing is
byte-identical before and after, no resource bears the inner name): case 3 has
ten observations, all six reports `EvidenceChecksSatisfied`, exit 0, inventories
identical. Limit: the check is a path walk at preparation time, not a
descriptor-held lock, and covers nesting inside a retained root, not two
sibling scopes sharing a port or kind name; those need a registry of admitted
scopes that does not exist yet.

Re-pin and re-run after the nested-root repair (2026-11-19). Editing
`DeploymentScope.hs` changed the reviewed M01 preimage, and the gate correctly
failed three then one test (`MutationSourceDigestChanged`, then the manifest
alignment test) until the pin was reviewed: the source digest is now
`119f96fc...992d`, the binding digest `c9cc0766...3f71` and the candidate
digest `cd21a91e...9444`, updated in `ReviewedMutation.hs` and
`mutation_cases.md` after confirming the mutated line is byte-identical and still
unique. Gate: 10,061 plus 935 tests passed. The mutation executor was re-run on
the new source: M01 Killed by `context.rejects_root_alias`, M02 Killed by
`evidence.rejects_unbound_result`, calibration survivor Survived, invalid
source Invalid, timeout Inconclusive; isolation and cleanup confirmed, no
containers left.

Sibling scope on the same host ports (2026-11-19). `requireDisjointKindPlans` is
pure and uncalled, so the port half of "disjoint scopes" was never observed:
a second scope declaring the API/HTTP/HTTPS host ports a running cluster holds
would only fail at node create, after its image, network and volume effects.
`Prodbox.Control.HostPorts.hostPortRefusal` now reads the kernel's listening
socket tables (an unreadable table is a refusal, not absence) and
`admitReconcile` runs capacity then ports, both before any archive, image,
network, volume or node effect (`kindPlanHostPorts` exports the plan's three
ports). Scenario: while the first cluster is Ready, a derived config with a
different anchor and id but the same ports runs `control reconcile`: refused
with "declared host port already listening", no container, network or volume
bears the sibling's name, the first cluster is still Ready by independent
read-back, the sibling directories are removed. Case 3 now has eleven
observations; all six reports `EvidenceChecksSatisfied`, exit 0, inventories
identical. Not measured: what the pre-change binary left behind in this exact
case. Limit: this is a point-in-time listening check, not a reservation, so a
port taken between admission and node create still fails late; sibling scopes
sharing a kind name across different anchors are caught only by Docker's own
name collision (case 3's foreign network), not by a registry.

Measured usage against the declared budget, A01-05 (2026-11-19). The runner now
samples the controller's transient slice while the public `control reconcile`
works (the slice exists only while its unit runs), reading the kernel's own
peak and limit counters. Real sample: memory peak 260,624,384 bytes (248.5 MiB)
against the plan-set limit 805,306,368 (768 MiB), and 35 tasks peak against 88;
the case-5 report's third observation `capacity.usage-within-declared`
(peak > 0 and peak <= limit for both) is satisfied, `EvidenceChecksSatisfied`,
exit 0, inventories identical. The claim side restates "Ready" and so is weak;
the independent side is the kernel counters. Not covered: the marker Pods of
cases 2 and 4 run with no explicit resource limits or quotas, and node
allocation was not compared, so the "actual Pods under real limits/quotas"
clause of A01-05 is still open and its box stays unchecked.

Counterexample found and repaired: a refused reconcile stranded its root
(2026-11-19). Reconciling the retained root again after the scenario showed
that a reconcile refused at the network step (a foreign network held the name;
create reply 409) left a half-recorded operation with image and network records
but no volume or node intent, and then neither public command could move on:
`control delete --yes` stopped at "node: recorded node identity unavailable"
(it never reached the volume or network steps) and `control reconcile` refused
with `ArchiveNotCompletelyRemoved`. Repair: `Delete` treats an operation with
no node create intent and no attempt as having no node, no volume create intent
as having no volume, and a network create reply that is not 201 and carries no
id as having no network (each is a recorded fact, not an inference from
absence; a present but unreadable record, or an attempt with no result, still
keeps its records); `Recreate` accepts the same three conditions in place of
the missing removal results. Measured on the stranded root: delete reported
all three steps complete, a following reconcile proceeded and archived the old
operation. The scenario now ends case 3 with `adverse.repeat-delete-settles`
(public delete settles the half-recorded operation).

Pods under real limits, A01-05 (2026-11-19). The runner applies two real Pods
with explicit memory requests and limits: one allocating about 4 MiB under a
64 MiB limit finishes `Succeeded`/`Completed` and reports the limit it carries,
one allocating about 134 MB under a 16 MiB limit is `Failed`/`OOMKilled`
(exit 137), so the limit is enforced rather than merely declared. A first
version used `head` and `tr`, which the pinned helper image lacks (measured by
running it), so the "allocation" never happened and both Pods looked fine;
the scripts now use bash arithmetic only. Case 5 has five observations, case 3
twelve; all six reports `EvidenceChecksSatisfied`, exit 0, inventories
identical. With the earlier slice peak (248.5 MiB of 768 MiB; 35 of 88 tasks)
this closes the A01-05 clauses as written; quotas (a `ResourceQuota` object)
were not exercised, only per-container limits.

Same-name sibling, repeat delete, and a masked-fixture correction (2026-11-19).
(1) `dockerNameRefusal` runs after capacity and before the port check: a
container, network or volume already carrying this scope's cluster name at
admission cannot belong to a new operation (the previous one's records are only
archived after its resources are removed), so it refuses before any effect and
reports counts. Scenario: a sibling with the same deployment identity in another
project on shifted ports, while the first cluster is Ready, is refused ("Docker
resources named for ... already exist"), its root holds only
`scope-generation.json`, the image list is unchanged and the first cluster is
Ready. (2) Repeating `control delete --yes` was not idempotent: the node
absence record's exclusive create, the volume and the network removal each
failed on a second pass. Delete now settles a step whose removal result (or
absence record) is already recorded, with the independent absence inventory
still re-run for the node. (3) The earlier case-3 observations were weaker than
reported: the derived configs replaced `deployment_id = "<kind name>"` but the
file holds the short id, so the replacement was a no-op, and a foreign network
named after the cluster was still present, so several refusals (and the
"sibling on the same ports") could have been caused by it rather than by the
rule under test. The runner now replaces the real id, removes the foreign
network immediately after its own case, and the final run shows each refusal for
its stated reason: the port sibling reports "declared host port already
listening: 26709 28349 28709" and the name sibling the Docker-name reason.
Case 3 has thirteen observations, all six reports `EvidenceChecksSatisfied`,
exit 0, inventories identical. The "recoverable" observation is now "repeat
delete settles": the half-recorded-operation strand that motivated the earlier
Delete/Recreate repair can no longer be produced by a name collision (it is
refused before any effect), though that repair stays for other mid-operation
failures. Residual: a name check is point-in-time and does not reserve names.

New-path absence check for L04/L05 (2026-11-19). The unit suite "new management
surface isolation" scans every module under `src/Prodbox/Control/` plus the two
Phase 1 runners (comment lines excluded) and fails if any reads an ambient
`KUBECONFIG` or `DOCKER_HOST`, shells to `systemctl`, or names `rke2-server` or
`/etc/rancher`; it passes (no offender). Together with case 3 (ambient decoy
unused, cross-environment and foreign/nested/sibling roots refused) and case 2
(exact host data retained across recreation) this is the replacement evidence
and the "no new path" absence for both rows. The ledger rows still describe
the legacy routes (`TestValidation.hs`, `Infra/MinioBackend.hs`,
`Infra/SubstrateKubectl.hs` ambient reads; `CLI/Rke2.hs` and its 110 callers),
which Phases 5 and 6 replace, so both rows stay Pending and Phase 1 stays
Active rather than being marked complete on a removal that has not happened.

Inherited removals audited and closed (2026-11-19). B020: `componentsDhallFragment`,
`defaultComponentsDhallFragment`, `componentIdUnionDhall`, `componentNodeTypeDhall`
and `renderDefaultComponentGraphDhall` no longer exist anywhere under `src`,
`test` or `app` (grep empty); the ledger already carried it as `Removed`, and the source
agrees. B039: `Prodbox.Config.InForce` and `.Core` are absent from the tree
and `prodbox.cabal`, `LogicalInForceConfig`, `seedProposeDecision` and
`rootConfigWriteDecision` appear only inside the forbidden-identifier check in
`CheckCode.hs` and its unit cases; `Removed`. B055: renamed the internal
identifiers to match the user-facing surface (`Rke2Command`->`ClusterCommand`,
`NativeRke2`->`NativeCluster`, `PulumiCommand`->`AwsStackCommand`,
`NativePulumi`->`NativeAwsStack`, `K8sCommand`->`ClusterK8sCommand`,
`NativeK8s`->`NativeClusterK8s`, `HostPublicEdge`->`EdgeStatusCommand`,
`NativeCheckCode/TlaCheck/Lint/Docs`->`NativeDevCheck/Tla/Lint/Docs`) and the
modules `CLI/Rke2.hs`->`CLI/Cluster.hs`, `CLI/Pulumi.hs`->`CLI/AwsStack.hs`
(cabal, imports, the `CheckCode` and escape-registry witness paths, and the
unit tests that read those files were updated; historical documents now cite
`583443f:` revisions). No behaviour change: gate green, 10,062 plus 935 tests;
the first gate run failed ten tests that read the old file paths and the docs
lint on the old citations, both corrected, which is the evidence the rename
reached every consumer. `test/qualification/*.json` build listings still name
the old object files; they are dated records and were left unchanged. B021: re-audited and closed. `fixtureConfigBytesAtPath`
returns `Left detail` as a value, so do the `prepareTlsDekExchange` result
(`either (Left . show)`), the `CleanupRunDescriptorBound` arm and
`encodeFixtureCleanupRun`; the only `ioError` left in `FixtureServer.hs` are
the two listener-address checks that are not request handling. The decode
failure is pinned by the CliSuite case at `CliSuite.hs:7137` (both config
routes answer `500` with "fixture handler failed:" and the decode reason, never
"user error (", and `/readyz` still answers). An earlier note here that no such
test existed was wrong; it was added before this audit. `Removed`.

Static PV binding and ResourceQuota (2026-11-19). Auditing T03 and T04 against
the plan text found two stated items unexercised, so the scenario gained them.
T03 deterministic PV binding: a static PersistentVolume on the retained host
root (`/var/lib/prodbox/pv-a01-02`) with a `claimRef`, bound by name to a claim
with no provisioner; a Pod writes through the claim in the first lifecycle, the
same PV and claim are applied again after node recreation and a new Pod reads
the marker back; the claim is `Bound` to `pv-a01-02` both times and the host
file matches by direct read (case 2 gains `pv.bound-deterministically`). T04
quotas: a namespace `ResourceQuota` (requests.memory 32Mi, limits.memory 64Mi,
pods 2) admits a Pod requesting 8Mi, the API server refuses one requesting 64Mi
with "exceeded quota", and the quota's own accounting reads `8Mi` (case 5
gains `capacity.quota-enforced`). Both passed on their first run with all six
reports `EvidenceChecksSatisfied`, exit 0, inventories identical, so there is no
failing-then-fixed record for the logic. They did expose a cleanup defect: with
`type: DirectoryOrCreate` the kubelet created the volume directory as root
inside the retained root, so the scratch root could not be removed without
elevation. The runner now creates the directory as the operator and the PV uses
`type: Directory`; files the container writes are still root-owned but sit in an
operator-owned directory and the root removes normally (checked). A production
volume provisioner must do the same. The Phase 1 validation evidence file and the
six engineering documents' "Implemented through Phase 1" sections were written
at this point; owned removals L04 and L05 are the only open completion item.

- [x] **P01-T01** — Refactor the typed CommandSpec/parser/dispatch boundaries and visibility model. Add explicit --config, minimal bootstrap context and scoped diagnostics; activate only completed commands, without successful future-feature stubs.
- [x] **P01-T02** — Implement production/test identity and safe path construction: distinct project roots, kind names, mounts, kubeconfigs, ports, networks, metadata and resource ownership. Reject overlap, symlink escape, foreign context and ambient target selection before effects.
- [x] **P01-T03** — The kind adapter binds exact host extraMounts, deterministic PV binding, pinned node/bootstrap artifact identity and explicit node port reservations for the accepted MetalLB/Envoy publication contract. It constrains Docker effects to the admitted scope, including duplicate-network removal and image pulls. Both clean-runtime runs passed the public controller completion, interrupted removal and same-root recreation regressions. The earlier failed operation's recovery disposition and the compiled mutation campaign remain open in the evidence record.
- [x] **P01-T04** — Implement management CNI policy enforcement and host/node capacity discovery, real requests/limits/quotas and a funded simultaneous management/secret-worker envelope before later secrets work.
- [x] **P01-T05** — The common scenario runner, independent evidence validator and bounded mutation executor bind outcomes to source, build and test identity. The 27 targeted compiled kills and the three outcome calibrations passed with independent worker and workspace retirement observations for each qualifying case.
- [x] **P01-T06** — Activate early control removal only for exact new identities that cannot have admitted cloud effects. Foreign, existing, and unknown identities refuse. Bind and fence the original teardown admission before removing the control API. Exercise interruption after node or volume removal, exact resource read-back on resume, and missing-admission refusal. Preserve the unconfirmed node-create regression below and the Phase 3 obligation boundary.
- [x] **P01-T07** — The clean kind runs exercised recreation, cross-environment controls, allowed and denied connections, and capacity. The isolated mutation campaign replayed M00, M01 and M02, and the corrected timeout replay completed executor calibration. Independent observations confirmed cleanup for all qualifying scopes.
Decision (2026-11-22): the prior Phase 1 runner explicitly assumed that the
selected root already contained the kind tool and archive
([Phase01Runner.hs](../src/Prodbox/Test/Phase01Runner.hs), lines 150–155), while
the adopted runner is responsible for its registered setup and cleanup
([testing.md](../documents/engineering/testing.md), lines 10–13 and 33–39).
The user has confirmed that the harness should create the kind node and asked
that missing preparation be addressed. Keep public, scoped and digest-bound
artifact import as the only runtime ingress; add supported acquisition and
preparation in Phase 1 before claiming the harness is self-preparing. Existing
Phase 1 observations are historical evidence for their original inputs.

First implementation slice (2026-11-22): `Control/NodeRegistryManifest.hs`
checks the exact manifest digest before decoding a bounded OCI/Docker schema-2
manifest and refuses unsupported media types, nonpositive or excessive blob
sizes, duplicate digests and excessive layer counts. The module is a pure
planning input only: it downloads nothing, does not prepare an archive or
activate a public path, and cannot satisfy A01-08. A standalone typecheck and
synthetic positive parse passed; the new unit suite and executable build are
running. Next implement bounded authenticated registry reads, verify each
content digest and size, assemble an accepted OCI archive, and wire public
preparation and exact cleanup before attempting real qualification.

Registry observation (2026-11-22): the historical retained OCI manifest digest
`sha256:e98b1342735c81a32480dfe017d6b1599bc006d88bf1635255e454d75a60fb28`
returns HTTP 404 when requested as a Docker Hub manifest. A read-only request
for `kindest/node:v1.36.1` returned an amd64 schema-2 descriptor
`sha256:21c46cf61fd45873f89e6a1bfcba4b7904dffa84c2bec88aeeca9a0409af4725`;
its exact response bytes hash to that descriptor and its config digest is the
same pinned image ID `sha256:152b34afd8a2de5c8348a264426bc99b71058ee0e1a15eab9b30849605e4752d`.
`Control/NodeRegistryClient.hs` now performs a bounded anonymous token and
manifest read for the fixed public repository, keeps the token in memory,
disables ambient proxy and redirects, and validates the selected digest using
the pure parser. A direct read of the published descriptor was accepted; the
historical descriptor produced a structured refusal. This is not artifact
acquisition or image-load evidence: no layers were downloaded and no Docker
resource was created. The selected identity must bind the actual published
manifest, and archive inspection must independently establish the expected
config ID before use; do not conflate converted OCI and registry manifest hashes.
The first combined build failed because the registry-client module was added to
the test source while the older library configuration was already building.
Both new source modules typechecked directly and targeted HLint reported no
hints; an incremental rebuild with the current package definition is required.

Blob preparation slice (2026-11-22): `Control/NodeRegistryBlob.hs` verifies a
manifest-declared blob by streaming bounded chunks, checking exact size and
SHA-256 under a deadline; it neither publishes nor loads the blob. Synthetic
cases cover matching content, short and long reads, and changed equal-size
content; the module typechecked but those cases have not yet run. A read-only
anonymous Docker Hub probe of the small public config blob observed a GET
redirect to `production.cloudfront.docker.com`, returned 1,982 bytes and matched
the declared config digest. No token, redirect query or response body was
recorded. The download adapter must validate HTTPS redirect destinations, never
forward registry authorization to the redirected host, enforce the declared
size and digest during staging, and keep any signed URL out of logs or evidence.
No layer or archive was acquired by this probe.
The in-progress registry client now retains the digest-verified manifest bytes
and can stream a declared blob to a caller-owned unpublished handle, checking
the exact byte count and SHA-256 while restricting redirects to the observed
HTTPS CDN without forwarding registry authorization. The caller must discard
partial files on failure. This adapter is not yet connected to the public test
workflow or archive assembly and has not yet been validated end to end.
The client subsequently retrieved the 1,982-byte pinned config blob through
that restricted redirect into a temporary file and returned success after its
size and digest checks; a second probe with a one-byte-short declared size
returned `NodeRegistryReadBlobMismatch`. No layer or Docker effect occurred.
Four focused unit
tests passed for manifest validation, invalid-request refusal and blob byte
verification. `Control/NodeRegistryArchive.hs` is an in-progress streaming
OCI layout writer that rechecks input bytes; its inspector integration and
public workflow use remain open. Its focused synthetic archive test passed,
including rejection of an equal-size source alteration; this is not a real
archive import or lifecycle acceptance. The five registry/assembly unit cases
and the canonical mutation-binding metadata test passed after the complete
executable and unit-suite build; the mutation itself was not executed.
The first canonical `dev check` on this slice failed its Haskell style lint for
a nested response case in the new registry client; that code has been
refactored. A further lint attempt exposed formatting differences from the
shell's formatter version; the repository-pinned formatter was applied and
the reviewed mutation hashes were updated. On 2026-11-22 the canonical
`./.build/prodbox dev check` completed successfully, including the
warning-clean build and gated unit suites; the synced binary SHA-256 was
`7ee02917f591e0e07f81d7689990742a6eb4bd43776775dfc7887af2d24b1b04`.
The mutation-binding metadata test also passed separately. This quality result
does not establish the unrun real or mutation acceptance.
The unavailable-image adverse case in `Test/Phase01Runner.hs` previously
replaced one hard-coded historical digest. It now derives the selected image
from the validated projection and refuses to run if substitution does not
change the document; the unchanged negative case still requires no Docker
effects. This change requires a fresh build and real scenario validation.

Preparation integration slice (2026-11-22): the public Phase 1 runner now
observes its selected test identity's node archive and, only when it is
confirmed missing, invokes `Test/NodeRegistryPreparation.hs` to fetch the
selected pinned manifest and blobs into private staging. It checks the root
generation, exact manifest and blob bytes, generated archive digest and size,
then invokes the public `control import-artifact node-archive` command and
independently observes the retained result. Staging is descriptor-held and
cleanup reports its result and staging path separately from the primary
outcome. A manifest whose blobs plus projected archive would exceed the 1 GiB
staging budget is refused before any blob fetch; this does not bound the
separately retained import or Docker storage. Existing artifacts continue
through their independent observation;
unknown or conflicting artifacts refuse. This path currently requires an
already enrolled test root and a configuration declaring the digest of the
generated archive. A subsequent unvalidated implementation now fetches the
exact pinned Linux amd64 kind release when the declared tool is missing,
verifies the bytes twice, and invokes the public importer. A further
unvalidated default-route integration authors a fresh identity as described
below. The public workflow does not yet satisfy A01-08. Replaced-directory
recovery identity, exact residue read-back, and controlled cancellation
settlement also remain to be proven.
Controlled source and cleanup tests are in progress; no
real kind lifecycle or mutation execution is claimed by this slice.
An initial controlled disappeared-file check failed against a test executable
linked before the source change that requires the complete created-file set.
That is not a mutation kill or passing result. The updated source was rebuilt
for a fresh test run, which passed all eight controlled
preparation cases, including the disappeared-file and replaced-file cases;
the five manifest and archive unit cases also passed. These tests use
controlled sources and do not replace real provider or lifecycle acceptance.
After fresh-route staging and entropy checks were added, the rebuilt focused
preparation suite passed all 12 cases. `test list` reported `phase-01`, and
default `--coverage` and `--substrate aws` requests refused before preparation.
A separate read-only inventory of the explicitly selected Docker daemon did
not list the pinned node image at that observation; it was not a lifecycle run
and does not establish absence at a later time. The operator binary used for
the latest controlled checks had SHA-256
`5340a7f28a9ada6008e8a390ba8bce125adcf38277265b8ebbda6b44e7ccd212`.
The rebuilt operator binary for these checks had SHA-256
`82316493f8f17c0cdf5f2fa543d203bd7894a3ddbb5e850f36fbf680af1eb2d7`;
the earlier complete `dev check` applies to the preceding source slice, not
this subsequent integration.
The default `test run phase-01` route previously fell through to the
unimplemented cumulative-runner error in `TestRunner.runTests`. An
unvalidated implementation now creates a random test scope, stages the pinned
archive, invokes the public fresh-test setup and scoped import commands, and
then enters the selected-identity scenario. It is registered with the named
local suite catalog, so `test list` includes it rather than maintaining a
second default command path. It uses the explicit local
`/run/docker.sock` endpoint and randomly selected disjoint host-port ranges;
provider and port collisions still refuse through the existing adapters. The
automatic preparation case remains open until this route and its owned
resources have real independent observation and cleanup evidence.
An in-progress A01-08 report now attempts public altered-source,
missing-source and wrong-generation imports with separate before/after
observations of both retained artifact digests, the generation and import
staging names. It also binds the initial image inventory, source, binary and
boot observations to the two lifecycle and cleanup observations. The report
and a controlled public-import regression are not yet validated. Its first
warning-clean build reached the test and failed because the new observation
type lacked an equality instance; the type was corrected and needs rebuilding.
The fresh route observes the image inventory on the explicitly selected
daemon and distinguishes absence, presence and unobservable state; an already
cached image is preserved and makes the clean-image case unproven. Until the
automatic-preparation report and adverse controls are delivered, even a pass
of the prior scenario cases returns a non-success status with that limitation,
rather than presenting the complete Phase 1 case set as passed.
The updated `test configuration isolation` CLI case passed. An initial
inventory-case run overlapped another Cabal build and failed while both tried
to create the same package database; after the build completed, the inventory
case and configuration-isolation case both passed sequentially. The first
failure does not count as a code failure or passing result.
The first default-route build failed on the repository-root error branch's
return type; it was corrected to return the scenario's ordinary failure code
and the rebuilt route remains under validation.
Decision (2026-11-22): the default local test selects `/run/docker.sock`
explicitly, consistent with `documents/engineering/configuration.md` lines
89–93; it does not discover an endpoint from an ambient Docker context. The
generated ports are candidates, not reservations, and the public adapter must
still refuse any observed collision.
The shared scenario entropy reader formerly substituted a fixed string when
the random device failed. It now returns a structured refusal for unreadable or
short input, and the Phase 1–3 callers refuse before building scenario IDs.
This is unvalidated until the rebuilt affected runners and tests pass.
The Phase 1 runner also previously hashed the literal `unknown-boot` when its
boot identity could not be read. It now validates the observed UUID and
refuses an unavailable or malformed value before lifecycle effects; this
change likewise awaits the rebuilt tests.
Safety correction (2026-11-22): the pre-existing foreign-network test used the
Docker CLI's default endpoint and unconditionally removed the fixture name,
even if fixture creation failed. The updated runner supplies the selected
runtime socket to every Docker observer and fixture operation, and removes a
network only by the exact ID returned by successful fixture creation after
unchanged label and attachment checks. It reports unconfirmed cleanup and the
observed ID instead of deleting by name. Phase 2 and 3 callers of the shared
observers now supply their selected socket as well. These changes need a fresh
build, targeted adverse controls and real fixture cleanup evidence; no prior
network test is retroactively upgraded.
Decision (2026-11-22): fresh automatic setup must not use the existing setup
recovery prompt to adopt an already-present root. The stricter reading of
`documents/engineering/configuration.md` lines 209–228 and
`documents/engineering/testing.md` lines 10–13 is to expose a fresh-test-only
mode on the existing public setup command: it must first receive
`FreshScopePrepared`, refuse existing or incomplete roots, and only then
publish the new test document. The harness can feed non-secret coordinates
through that public mode without changing a production sibling.
The first documentation-generation attempt correctly refused the unlisted
`--fresh-test` option; after adding its command and option dispositions,
`prodbox dev docs generate` exited successfully. A rebuilt public binary and
controlled temporary-root test then confirmed fresh test creation, refusal of
the second identical setup without changing the marker or configuration, and
refusal of production input without creating a production root. The parser
test and four regenerated CLI golden checks passed. These results do not
establish the fresh `test run phase-01` route or its real cluster lifecycle.
The explicit Phase 1 dispatch previously ignored coverage, substrate and
profile flags. It now rejects unsupported selections before beginning the
scenario. Public `--config /tmp/nonexistent-prodbox-test-config test run
phase-01 --substrate aws` and the equivalent `--coverage` invocation each
exited 1 with the specific unsupported-option diagnostic before trying to read
the selected config; no resource was created. The profile flag remains untested.
Read-only kind-tool source probe (2026-11-22): the public v0.32.0 Linux amd64
release is 10,522,750 bytes and hashes to the provider's pinned executable
digest `sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54`.
An initial HEAD diagnostic inadvertently displayed a short-lived public asset
redirect URL in the session tool output; it contained no user credential.
The later bounded streaming digest probe did not record the redirect or body.
The new Haskell downloader subsequently returned success for the pinned
release and refused a 1,000-byte limit with `NodeRegistryReadBlobMismatch`;
both probes used temporary files, which were removed, without public import or
cluster effects. Full preparation and interruption evidence remain open.
The mutation catalog now requires `artifact.rejects_changed_bytes`; a reviewed
source-bound patch is defined, but its isolated execution and intended-assertion
kill remain to be demonstrated before Phase 1 can close.

Controlled preparation update (2026-11-22): the warning-as-error build passed,
as did 18 preparation tests and five registry/manifest/archive tests. These
include public-binary altered, missing and foreign-generation import refusals
with independently compared retained state. They are controlled tests, not the
real A01-08 acceptance. The fresh report binds the setup and import sequence;
its source and binary comparisons are point-in-time observations. A subsequent
review found that several older adverse fixtures used fixed workspace paths and
recursive deletion. Their paths have been moved under a freshly created,
randomly named scenario directory, but the recursive fixture cleanup still
requires replacement with exact ownership and cleanup read-back before a live
run. The path change compiled with warnings treated as errors, and the 18
controlled preparation tests passed again; those tests do not exercise the
full scenario's scratch cleanup. No new cluster was created for this update.

Fixture-cleanup follow-up (2026-11-22): a bounded private-tree snapshot and
cleanup helper now checks identities and exact contents, refuses changed or
extra entries, and never follows fixture symlinks. A warning-as-error build and
23 preparation tests passed, including nested-state and recovery-config batch
cases. The scenario no longer recursively removes fixtures:
it retains public-created sibling scope records with their config, preflights
captured fixture trees, removes recovery configs last, and reports incomplete
cleanup with paths. Its decoy listener now has a bounded observed process
settlement. The first test build failed on a shadowed test variable and passed
after its rename. Decision: preserve both conflicting sibling scopes and their
selected configs, because `src/Prodbox/Control/Reconcile.hs:145` creates the
fresh generation before admission at line 156 and
`src/Prodbox/Config/DeploymentScope.hs:345` writes its marker. A subsequent
change independently checks the selected identity, generation and exact bare
root before accepting that retention; a warning-as-error build and 24 focused
tests passed, including a wrong-generation and unexpected-operation negative
control. A later warning-as-error build and all 25 focused tests also passed
after the sibling parent observation was extended to reject unexpected staging
entries. A subsequent warning-as-error build and all 26 focused tests passed,
including a check that the overall fixture directory contains only the two
retained scopes and configs. The first build of that check rejected a partial
test helper and passed after it was replaced. Real acceptance and cleanup under
interruption remain open; no live
cluster was started for this change.

Reconcile completion discrepancy (2026-11-22): the A01-08 report requires the
public reconcile calls to return success, but `src/Prodbox/App.hs:701` always
reports `ReconcileNodeReady` as incomplete and exits unsuccessfully. A later
ready status is a separate point observation and cannot erase that primary
result. The existing controller result is an unstructured diagnostic string
(`src/Prodbox/Control/KindController.hs:317` and `:379`), so it must not be
parsed as proof of a completed, settled operation. Resolve the public completion
contract and its independent read-back before claiming the case or starting a
live run whose outcome is already known to be incomplete.

The controller wait had an additional counterexample: reaching its deadline
returned the same value as observing the transient unit absent. The wait now
returns unconfirmed on expiry, including an absence reply received after the
deadline. The warning-as-error build and all 25 focused preparation tests
passed, including an on-time absence, a late reply, an expired deadline and an
unobservable unit. This does not by itself prove controller success.
The public reconcile handler has also been changed to skip the result read and
network-policy probe when controller settlement is unconfirmed; the probe can
create Kubernetes resources and must not run behind an unresolved worker.
The warning-as-error build and all 28 focused tests passed, including the
controlled no-follow-up case. The first test build rejected an ambiguous string
type and passed after it was annotated.

Guarded existing-control cleanup (2026-11-23): the guarded test-identity
delete branch now recovers an existing operation-bound absence-control plan
when the node positive control fails. Under the borrowed family owner it
retains the sample outcome, attempts exact control cleanup even if sampling
fails, and, after a recorded 204 control removal, observes and removes exact
residual volumes with separate results. Interrupted sampling retains the
primary interruption together with the control-cleanup outcome. The branch
still reports the node incomplete and does not advance to node-volume or
network removal: terminal control-container and node absence are not proven.
The synthetic daemon fixture covered successful sampling and cleanup, a blind
sample with control cleanup, a retained residual volume, a lost control
reply, and interruption during sampling with a recorded cleanup outcome.
Warning-as-error executable, unit and integration builds, all 62 preparation
tests, the focused composed fixture, targeted HLint, documentation check and
`git diff --check` passed. The existing static-controller settlement guard
still refuses this branch in the public executable; neither public cleanup nor
real Docker behavior is qualified. The binary SHA-256 remains
`0b2f0bc0ddbdc0533fffcb7b01ffc3ade98864b39cb91dbca87422a20b0a398e`;
recovery source SHA-256:
`dc171c9db143fbfd5d010d5a2356647ad7b336d8c13b47c46711506e5582624e`;
integration test source SHA-256:
`8d4c6b2d8a85cd95ad97235018b1b620425eff03bfbf914daebce46723c4bcd7`.

Absence-control sample composition fixture (2026-11-23): a simulated Docker
daemon supplied distinct unfiltered, name, label and volume-filter inventory
responses while the internal sampler inspected the exact recorded control and
positive node volume. The positive case wrote the sample, removed the exact
control with a simulated 204, and observed its recorded anonymous volume absent
while the node volume remained visible. A blind control-label filter refused
the sample and sent no delete. Create, footprint and node-volume records in
this fixture were synthetic; it does not establish ownership or real cleanup.
The warnings-as-errors integration build, all 57 connected-Docker observation
tests, targeted HLint, documentation check and `git diff --check` passed. The
first HLint run suggested a list construction change; the corrected source
was rebuilt and retested. Integration test source SHA-256:
`3b9d61dd145ca3829e4806d647831340594b3e706b71dc2f953530121a889acd`;
the binary SHA-256 remains
`0b2f0bc0ddbdc0533fffcb7b01ffc3ade98864b39cb91dbca87422a20b0a398e`.
The test does not prove terminal control-container absence, cancellation of the
sample, lost-create ownership or public lifecycle completion.

Public absence-control inventory status (2026-11-23): `control status` now
reports a separately bounded volume inventory alongside the retained local
journal. The inventory uses the selected Docker endpoint, exact recorded
footprint and positive node volume, but holds no controller-retirement owner;
the output labels it unsettled and does not claim cleanup. Its separate time
budget cannot erase the previously collected journal result. The simulated
public-CLI fixture reported a residual volume and preserved the unconfirmed
journal result when the daemon identity changed, without reporting that
residual as an observable result under the changed identity. Warning-as-error
executable, unit and integration builds, all 62 preparation tests, the focused
six-case fixture, targeted HLint, documentation check and `git diff --check`
passed. Binary SHA-256:
`0b2f0bc0ddbdc0533fffcb7b01ffc3ade98864b39cb91dbca87422a20b0a398e`;
status source SHA-256:
`edd65bc689bf4b3dcd8cdb30329928e75638343166b7821f46e9f0071f7b9556`;
integration test source SHA-256:
`8d939726e44f0585b9a6e737ce24ec3aa4a02aab13cfabeccd0875d867ad9adf`.
The fixture does not establish real Docker absence or operation settlement;
public delete and real Phase 1 acceptance remain open.

Public absence-control journal status (2026-11-23): `control status` now
recovers the control plan from its operation-bound attempt record, then reads
the identified control, footprint, sample marker and typed container and
per-volume removal results under the recovered operation lease. Missing,
damaged or unobservable records remain distinct, and the output explicitly
disclaims resource presence, cleanup and worker settlement. A simulated
lost-reply fixture exercised the public binary and observed the retained
unconfirmed volume result; the container fixture checked 204, lost reply and
interruption result recovery. The plan-recovery test refused a damaged
attempt. Warning-as-error executable, unit and integration builds, all 62
preparation tests, the two focused protocol fixtures, targeted HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`224b8cfdb9ec025d8ccc217609293616cf6e9f2b8f67daa7d47ad35127f1b436`;
status source SHA-256:
`ac77ed15a539b86b75334797eebe8dc0813a161d4304141a2fe2b5d8b2af11c8`;
integration test source SHA-256:
`1efae7887a4d3b4130b87b76dade4f985d7bbf68324a0950ae2a3a4b44235658`.
This exposes local recovery information; it does not establish real Docker
absence, settle an earlier request, or complete the public delete path.

Residual volume recovery observation (2026-11-23): recovery can now read the
exact per-volume attempt and bounded transport result without guessing the
status, and independently retain the current positive-controlled volume
inventory and closing owner check. Missing attempt, missing result, observed
result and malformed/unobservable record stay distinct. The journal test
covered those states and a damaged result; the six-case simulated-daemon
fixture matched the retained 204 or unconfirmed result with either absent or
still-present volume readback. The observation does not settle the earlier
request or authorize a retry. Warning-as-error executable, unit and integration
builds, all 62 preparation tests, the focused simulated recovery fixture,
targeted HLint, documentation check and `git diff --check` passed. An earlier
combined build failed after the source changed during compilation; the
subsequent consistent build passed. Binary SHA-256:
`164a5f9bc12079f91fe4f10045e3bd35255cf597e8a68c6b44fd4c0b848414e7`;
recovery source SHA-256:
`6e69d589fbf5a4b5df26f890691761a5c02bc970bb8ec86c4a49681d275aae9e`;
integration test source SHA-256:
`536bde80f980bb2e2eeedd709e558ff63b1294c4dddf59dd7a6d7b0cd8515f52`.
At that revision the observation was not visible through the public CLI; the
later status above adds a separately labeled unsettled inventory observation.
No real Docker result is claimed.

Residual volume interruption fixture (2026-11-23): the composed simulated-daemon
case now covers a dropped reply after a simulated deletion, interruption after
the request arrives, and a dropped reply where the volume remains. Both
uncertain outcomes retained the bound unconfirmed result. In the still-present
case, a subsequent invocation observed the residual and refused a second
delete because the attempt already existed. The focused six-case fixture,
warnings-as-errors integration build, targeted HLint, documentation check and
`git diff --check` passed. Test source SHA-256:
`fc0af81728523ecbfee8818b4893b92ed9ebe95e25780d8ba4366806c55a5048`;
the binary SHA-256 remains
`3f46e22748b114ec767017592b32fb5cb3b8ef674e11f4f4f0c90e905407192e`.
These are controlled protocol results, not real Docker evidence or a complete
resolution for a still-present volume after an uncertain attempt.

Residual volume composed fixture (2026-11-23): the composed internal recovery
path ran against a simulated Docker daemon and its CLI inventory endpoints.
With synthetic retained create, sample and removal records, it observed the
positive node volume and one unattached residual, wrote the exact per-volume
attempt before the simulated delete, retained the 204 result, and observed
the residual absent afterward. Separate fixture cases refused an attached
volume and a missing positive volume without a delete. The warnings-as-errors
integration build, all 56 connected-Docker observation tests, targeted HLint,
documentation check and `git diff --check` passed. The test source SHA-256 is
`4ba5eb78d4b1204369b2231db012bf88b5e154bc37829fd167816c4e11bd89fa`;
the binary SHA-256 remains
`3f46e22748b114ec767017592b32fb5cb3b8ef674e11f4f4f0c90e905407192e`.
This fixture does not prove a real Docker cleanup or the authenticity of its
synthetic sample marker. At that revision lost replies and interruption were
untested; the subsequent fixture above covers simulated cases. Independent
container absence and public lifecycle wiring remain open.

Residual absence-control volume recovery (2026-11-23): repeated post-removal
inventory now distinguishes exact recorded volumes that remain visible and
unattached from an absent footprint or an unobservable/attached one. An
internal non-forced removal path binds each attempt and result to the exact
footprint, a prior control sample and matching create reply, repeats the
positive-controlled residual observation before the effect, and preserves
uncertain results separately from closing ownership. Per-volume journal tests
covered ordering, a foreign ID, duplicate attempts and conflicting results;
the sample in that test was simulated. A controlled socket test checked the
exact non-forced volume request, invalid-ID and admission refusals, 204 and
lost-reply transport. The prior control-removal and node-volume transport
fixtures also passed. Warning-as-error executable, unit and integration builds,
all 62 preparation tests, targeted HLint, documentation check and
`git diff --check` passed. The first build caught a shadowed name in the
transport refactor; the corrected build passed. Binary SHA-256:
`3f46e22748b114ec767017592b32fb5cb3b8ef674e11f4f4f0c90e905407192e`;
volume-removal source SHA-256:
`59f9e4875bd06f619d6769a736209504aa88264d77096e91b3aa744982d1119a`;
integration test source SHA-256:
`47e1b1db2fca9f521667e76987c2ac73ad7846ba0c5a5c896b74e11a546211bc`.
At that revision the composed residual-removal path and postcondition had not
been exercised end to end; the later fixture above covers a simulated daemon.
Real Docker validation and public delete wiring remain open.
Lost-create ownership, terminal container absence, and real cleanup remain
open; no provider reply is counted as absence.

Absence-control removal protocol regression (2026-11-23): a controlled Unix
socket fixture exercised the internal removal boundary with a matching control
and footprint. It observed the exact full-ID delete only after the attempt
file existed, then verified the bound result for a 204 reply, a dropped reply,
and cancellation after the request arrived. The latter two retained an
unconfirmed result; cancellation propagated after the result was readable
under the recovered lease. The warnings-as-errors integration build, all 54
connected-Docker observation tests, targeted HLint, documentation check and
`git diff --check` passed. Integration test source SHA-256:
`e35f51f010ca261dbb1752a87c57e10003764f44cb7008ef6855c7425d6fe9ee`;
the tested binary SHA-256 remains
`627a52606becd4899b36edf1d7698b470e14df721f952e4b6cb58fa89c9c2d00`.
The fixture is not a real Docker cleanup and does not establish independent
volume absence, lost-create ownership, or public lifecycle completion.

Absence-control removal boundary (2026-11-23): an internal recovery adapter
now requires the matching recorded 201 create reply, exact control and
anonymous-volume footprint, matching daemon, held operation/family checks,
and a newly written removal attempt before sending the existing full-ID
container delete with anonymous-volume removal. It reinspects immediately
before the effect and records the transport result separately from its closing
check. On interruption after the attempt it tries to retain an unconfirmed
result before propagating the interruption. A controlled test with an
unconfirmed create reply refused removal and left the attempt absent. The
warnings-as-errors executable and unit build, all 61 preparation tests,
targeted HLint, documentation check and `git diff --check` passed. The
adapter source SHA-256 is
`825431849f9873d077dc4d7f5740b900962fe3840995ea5291defc973d2b2cdd`;
the binary SHA-256 remains
`627a52606becd4899b36edf1d7698b470e14df721f952e4b6cb58fa89c9c2d00`.
This code is not wired into the public lifecycle. A successful delete,
lost-create-reply ownership recovery, independent container and exact volume
absence, orphan volume cleanup, cancellation settlement and real cleanup are
not yet validated; a 204 reply alone is not an absence receipt.

Absence-control sample composition (2026-11-23): an internal sampler holds
one recovered operation lease and the supplied family-retirement check while
it inspects the exact control, samples node absence, samples the control's
volume footprint, repeats the node observation and reinspects the control
before attempting the sample record. The write result and closing stability
remain separate. A test with an explicitly missing socket verified that lost
ownership or unavailable control inspection leaves the sample record absent.
The warnings-as-errors executable and unit build, all 61 preparation tests,
targeted HLint, documentation check and `git diff --check` passed. The first
build caught name shadowing in the extracted lease helpers; the corrected
build passed. Binary SHA-256:
`627a52606becd4899b36edf1d7698b470e14df721f952e4b6cb58fa89c9c2d00`.
No real control was created; the later simulated fixture above covers the
positive sampling path, but exact real control and volume cleanup and the
interruption/recovery disposition remain unproven. In
particular, a readable sample marker alone is not a closing-owner proof; the
public lifecycle must not treat it as terminal absence evidence.

Kind family fresh request and legacy fence (2026-11-23): the family launcher
can now prepare its original bounded window, current manager coordinates and
an incrementally hashed executable candidate without caller-supplied identity.
Its existing held-input owner still rehashes the executable and rechecks the
manager before submission. Under the recovered operation lease, the current
family and legacy submission writers each refuse a present, invalid or
unobservable opposing launch record. The local manager fixture compared the
fresh digest to an independent hash and exercised both record orders; it sent
no controller. This fence applies to the current writers and does not prove
retirement of a previously running older binary or manager job. The
warnings-as-errors executable and unit build, all 60 preparation tests,
targeted HLint, documentation check and `git diff --check` passed. The binary
SHA-256 was
`cd3a5c6b733fb0550a3055f0da2a28e2d135627bf54cb72140dffbca31c8010b`, and the
fixture source SHA-256 was
`209472098f8708bcc9c7cf6ba9a390ab304f95cf4573e1f1fed79ecad2dda9f0`.
The public reconcile route remains on the old guarded path; family submission,
settlement, cleanup and real Phase 1 acceptance remain open.

Kind family non-secret snapshot (2026-11-23): the launcher now derives its
published Dhall from the validated bootstrap projection instead of accepting
caller-supplied selected-file bytes. It refuses projections without both
artifact declarations, renders the scope, networking and artifact coordinates,
and decodes the resulting source back to the same projection before opening
the launch boundary. A synthetic test round-tripped a selection containing an
unrelated secret field and confirmed the generated snapshot omitted it. The
local manager fixture exercised the updated launcher, refused a legacy
projection and a foreign manager, and observed the existing guarded send and
never-sent input retirement; it started no controller or cluster. The
warnings-as-errors executable and unit build, all 60 preparation tests,
targeted HLint, documentation check and `git diff --check` passed. The
executable SHA-256 was
`bdbae11ab045facf0e5884d430f5db3f0042dd25ac37509d23d777cec65cad9f`, and the
fixture source SHA-256 was
`1d97185bef0b6cc3546ef9e235fb9502313193820099e6fbf32b261f84fd6419`.
The public launcher, real family submission, settlement and Phase 1 acceptance
remain open.

Node-absence container readback (2026-11-23): added a bounded independent
inventory observation for the recorded node and separately recorded control.
Two samples require the control in unfiltered, control-name and control-label
queries while the target ID, node name and cluster label are absent; changed
samples, daemon identity, ownership, or invisible control projections refuse
the result. The 59-test synthetic preparation suite passed after tightening
its new positive-path assertion to require a parsed sample, including a run
from the rebuilt unit executable. The warnings-as-errors executable and unit
build, HLint and `prodbox dev docs check` passed.
The executable SHA-256 is
`dbaf9d6d1b5efc9d1855e075e1816cdef76146ece88a2d31681ffcee3084f367`.
This is a
read-only sample, not a terminal absence proof: the exact control must also be
inspected, its volume sample and the node sample must be composed under the
same held operation and retirement owner, and the marker and cleanup must be
recorded and independently verified. No real control was created.

Node-absence control volume readback (2026-11-23): added a bounded,
read-only observer which binds the recorded control and exact anonymous volume
IDs to the retained operation and daemon. It repeats the volume inventory and
per-volume container filters, checks the retained node volume independently as
a positive control, and refuses changed or unobservable results. Before
removal the recorded volumes must be present and attached only to the control;
after removal they must be absent from both inventories. The surrounding node
artifact preparation suite passed 58 tests, including the new adverse-control
case, the warnings-as-errors executable and unit-test build passed, HLint
reported no hints, and `prodbox dev docs check` passed. The tested executable
SHA-256 is `a3358d3124c6bfebf4cfecab7eddd0c5e2377a8877649a837dfc1b9b6380c3a5`.
This is simulated and read-only evidence:
the observer is not yet wired into the public lifecycle, the sampling marker
must be committed by a composed owner after a successful observation, and no
real cleanup or acceptance case is claimed.

Node-absence control create transport (2026-11-23): decision: retain and
record exact anonymous-volume IDs for the canonical node image rather than
assuming that a never-started control has no storage. The earlier real node
cycle above recorded an anonymous-volume leak at lines 8689–8693; the upstream
[Moby create path](https://github.com/moby/moby/blob/master/daemon/create_unix.go)
also creates and populates image-declared volumes during container creation.
That source is not proof of the currently installed daemon's behavior. The
new fixed control body uses the same image, isolated networking, no privileged
mode, a read-only root and a non-executable entrypoint. Its held-session
transport checks the exact image volume declaration and admission before a
bounded create; it retains lost replies as unconfirmed. It is not yet wired
to public delete: the caller must first establish a durable attempt, a
pre-create ownership boundary, a funded storage budget, and complete
container/volume recovery and cleanup. No real create has been attempted.
Warning-as-error executable, unit and integration builds, 57 focused
preparation tests, all 53 connected Docker observation tests, HLint,
documentation check and `git diff --check` passed. The initial integration
build rejected a fixture's shadowed name; the corrected build and tests
passed. The selected create fixture covered success, lost reply, changed image
declarations and denied admission. The binary SHA-256 was
`f026cc80e42d167529e04e2db6024340a996362a8e36b6aa3beb93279aa028e7`, and the
integration test source SHA-256 was
`97d9a71614e7e12d172044941287b5d9046b8730f084d31d646bd0d6e3811be0`.

Node-absence control inspection (2026-11-23): the held Docker session can now
inspect the deterministic control name and compare its actual ID, image,
operation/generation labels, never-started state, network isolation and exact
anonymous volume footprint with the retained plan. A missing response remains
unconfirmed; a matching configuration is a candidate, not proof of ownership
or permission to remove. Synthetic parser controls reject changed identity,
generation, state, network and mounts. A connected Unix-socket fixture checked
the exact inspect request and 404 refusal. No actual Docker control was
created; creation, lost-reply ownership, per-volume cleanup and the terminal
independent absence observation remain open. Warning-as-error executable,
unit and integration builds, all 57 focused preparation tests, the selected
connected inspection test, HLint, documentation check and `git diff --check`
passed. The binary SHA-256 was
`7d2f6263df443cff033927889c507d5726103645dbc1aea78d9f093e611201da`, and the
integration test source SHA-256 was
`929660d397340accd672988b3aa35ca14846ebad137f1de084368e4a5cb2c62f`.

Node-absence control journal (2026-11-23): a scoped, exclusive journal now
binds the control's create attempt and transport result, identified ID,
footprint, sample marker, removal attempt and transport result to the exact
recorded node creation, target,
daemon, root generation, deterministic name and image volume declarations.
The footprint and later records retain a complete destination-to-anonymous-volume
ID mapping, so a later removal does not discard the storage recovery identity.
Removal requires the footprint rather than a successful sample, allowing
cleanup when sampling fails.
The writer requires earlier matching stages, syncs each record and checks it
again; ID recovery refuses damaged or missing provenance. These are local
records, not proof that a control was actually sampled, its volumes were
removed, or the node is absent. A real Docker adapter, observation-backed
sampling, lost-reply recovery, exact volume cleanup and a terminal absence
disposition are still required before delete can use this journal. The prior
revision passed warning-as-error builds, 56 focused preparation tests, HLint,
documentation check and `git diff --check`; the corrected revision passed
the same checks. A synthetic retained-root test exercised
stage ordering, duplicate writes, wrong target and footprint, ID and footprint
recovery, damaged predecessor refusal, cleanup without a sample and refusal
to add a sample after removal begins. An initial focused `runghc`
invocation lacked the package flag and did not run; it passed after the flag
was supplied. An earlier build observed a test/library constructor mismatch
because the source changed during compilation; the consistent rebuild passed.
No Docker control was created. The prior binary SHA-256 was
`1a5e2bc5f323f4bfed986226f7e23587f73d03d43ac515785112b1a01cd50593`.
The corrected binary SHA-256 was
`3a806604793ddd78727de7f392182626caa011c1d3366997077b51a4d1a507f4`.

Node-absence control storage input (2026-11-23): the Docker adapter can now
read the exact image's bounded `Config.Volumes` declaration over its held
session. Missing or malformed configuration, a different image identity and
noncanonical paths refuse the observation rather than becoming an empty list.
This supplies the storage inventory needed to design a journaled positive
control; it does not create a control, prove volume ownership or remove any
storage. The earlier unjournaled control remains removed and a node missing
outside the adapter still fails closed. Warning-as-error builds, all 55 focused
preparation tests, HLint, documentation check and `git diff --check` passed.
The parser cases cover empty and declared volumes, missing fields, wrong image
identity and path aliases; no real image or Docker control was exercised. The
binary SHA-256 was
`11015d5675b4db83e6abf1e64d1ef536900b1fcd957f24c4fa1d9bb75bdb0d60`.

Kind family delete wiring (2026-11-23): the guarded test-identity delete path
now borrows the exact family retirement owner, retires the family's published
inputs, and carries the owner's provenance/physical checks through the node,
volume and network removal interpreters and their durable observations. Its
result preserves any completed steps when the owner or scope closing check is
unconfirmed. The old static-controller settlement guard remains in front of
the path: it still cannot be entered for a recorded operation until the old
controller's independently submitted child scopes are accounted for. The
unrecorded Docker absence-control creation has been removed; a missing node
now requires a journaled independent positive control rather than creating an
unowned control container. Designing and validating that control remains open.
Warning-as-error executable and unit builds, all 54 focused preparation tests,
the synthetic family-owner fixture, HLint, documentation check and
`git diff --check` passed. These checks do not enter the still-guarded delete
effects; live removal and phase acceptance remain open. The binary SHA-256 was
`df6351edb7afd9cbd6e9b2a5f896c72b4dbb3a424a91364aaa3d35ccbdc9f731`.

Kind family borrowed retirement owner (2026-11-23): the recovery path can now
hold the original provider/manager/kernel retirement owner while a callback
acquires its own operation lease. The borrowed verifier rereads the exact
retained launch and submission provenance and checks that lease on both sides
of the physical observation. Input retirement under that owner rechecks the
same provenance at each permission boundary. The synthetic dispatcher fixture
closed its original synthetic sender, borrowed the owner, refused an unstable
lease and a changed launch record, retired the exact published inputs, and
verified that the owner was closed after the callback. No controller job was
sent in that fixture. This owner proves only the family it names; the old
static controller still requires separate settlement, and public delete and
recreate remain guarded until both proofs and all effect-boundary checks are
composed and live-validated. Warning-as-error executable and unit builds,
all 54 focused preparation tests, the fixture, HLint, documentation check
and `git diff --check` passed. The binary SHA-256 was
`8a8dca299ef4328d43b1e76db84a417f6deb33bde3eafb2361a271d071556979`
and the fixture SHA-256 was
`d2359a476d27a2da78b1d296ec305f32088826d71853a840ef206c9437dc777a`.

Kind family recovery composition (2026-11-23): recovery now reads the
retained family request under the recovered operation lease and matches the
original kind, key, window, manager domain and provider-qualified submission
record at the fixed publisher path. Public `control status` reports the
provenance observation without claiming a send or retirement. Exact input
retirement borrows the generic sender/manager/kernel retirement owner and
checks the retained lease around each retirement permission check, preserving
the payload result and the closing physical and lease observations
separately. The [synthetic dispatcher fixture](../test/qualification/KindControllerInput.hs)
verified that missing submission metadata cannot authorize retirement and
that an exact synthetic record is observed while its live sender causes the
specific sender-present retirement refusal. It started no job. The
[native input fixture](../test/qualification/HostControllerInputRetirement.hs)
changed the admission check during retirement, observed refusal before any
payload or journal mutation, and then retired its own fixture. These cases do
not prove a real family send, physical retirement after work, or the public
delete/recreate handoff; those remain open, and family submission is guarded.
Warning-as-error executable and unit builds, all 54 focused preparation tests,
both fixtures, HLint, documentation check and `git diff --check` passed. The
binary SHA-256 was
`270a936cad7e2aa7fadd8019e787d1884efc5861329713092d8a2d04bab826e6`;
the dispatcher and native fixture SHA-256 values were respectively
`f87c47b7fd94dbe044eaabeef2207ce11e66ac6543cfba4a9ef459f4cdc3e8ff` and
`d072e0a3b9d229270cb3699c372274a39b9b92c05881f08eac7fe1105e29ce5f`.

Kind family lease handoff (2026-11-23): before opening worker resources,
the family controller now waits within its original work deadline for the
retained operation lease. Only a busy lease is retried; changed input/parent
ownership, a changed retained root, an uncertain lease close and expiration
refuse worker start. The worker still reacquires the operation lease at its
individual resource effects. This handles the launcher's possible overlap
with worker startup; it is not a live controller or retirement proof. The
shared summary marks a refused handoff as work not started. The focused test
held the real root lease, checked deadline expiry and unstable-owner refusal,
then observed the waiting worker proceed after release. All 54 focused
preparation tests, the synthetic dispatcher fixture, warning-as-error builds,
HLint, documentation check and `git diff --check` passed. The first unit
build failed because a constructor was renamed during compilation; the
consistent rebuild passed. The binary SHA-256 was
`6c4cc03f4e7faa780ac6747c1c90b414a6439651a454033417e86c62bfc8a773`
and the fixture SHA-256 was
`64cbd54de2c9d4828ac7d7ab47957bdb7ac482a354605c1675d8a98e96796e9f`.
Submission remains guarded.

Kind family publication composition (2026-11-23): a new internal launcher
holds the recovered operation lease while it writes the request locator,
publishes the exact configuration and request, verifies the held executable
and inputs, and enters the one-shot publication boundary. Its closing result
distinguishes retained possible sends from confirmed and unconfirmed
never-sent input retirement. The send boundary also requires the original
manager domain and rechecks the lease before and after marking a possible
send. The [synthetic fixture](../test/qualification/KindControllerInput.hs)
exercised publication against the user manager and confirmed the deliberate
submission refusal and never-sent retirement; it created no controller or
cluster. The send-boundary rechecks remain unexercised because the family
submission guard fires first. The launcher is not wired into the public
reconcile command. Before enabling it, validate the lease handoff with a live
controller, wire exact recorded-submission recovery and
physical retirement through cleanup, and validate live acceptance and the
owned mutations. The fixture also refused foreign manager and configuration
inputs before publication. Warning-as-error executable and unit builds, all
53 focused preparation tests, 17 RPC controller CLI tests, HLint,
documentation check and `git diff --check` passed; the binary SHA-256 was
`b6f1aba23893d3d7ed0c64e5784f2c24c454dad28a62fdd30440ace863899055`
and the fixture SHA-256 was
`a1ccab1ff379997b14c2e4740f860662816e3704f0a4c5b7a303d6cae15649c4`.

Kind family launch locator (2026-11-23): the retained test root can now hold
the canonical, non-secret family request under the recovered operation lease.
The exclusive write synchronizes the file and root and independently reads it
back; recovery checks the root generation, operation, manager coordinates,
original window and canonical request. A conflicting, unsafe or incomplete
record cannot establish submission or absence. This primitive is not yet
wired to the public launcher: exact publication provenance, manager settlement
and retirement must be composed before enabling family submission. The focused
fixture checks recovery, duplicate-write refusal, lost lease and tampering;
this is not live kind acceptance. The warning-as-error build, all 53 focused
preparation tests, HLint, documentation check and `git diff --check` passed. The binary SHA-256 was
`e839f53c28b4b7a6b43bbd2a560d47f94d2339c6dd6b66d76150089aa381a60e`.

Kind family result summary (2026-11-23): after a pinned dispatch callback,
the dispatcher now writes an exclusive, generation- and operation-bound local
summary under the recovered lease, reads it back and requires that write for a
successful controller exit. The write is bounded by the original outer
deadline. Its closed fields keep the worker observation, worker closing,
parent closing, input closing, post-write observation and post-lease closing
separate. Public `control status` reports the summary as local evidence and
explicitly says retirement is unobserved. This is a bounded summary, not a
complete serialization of nested error details; resource journals remain
necessary and full durable failure detail is still open.

The [dispatcher fixture](../test/qualification/KindControllerInput.hs)
retained an incomplete result in a synthetic test root and read it through the
public status command; it also checked simultaneous primary/closing outcomes,
wrong digest and unmanaged-parent refusals. The independent
[manager fixture](../test/qualification/KindControllerFreshProvider.hs)
read a synthetic result through public status. Neither submitted a unit or
created a cluster. Their SHA-256 values were
`64c8294e538f45a8b6b58d19fd62fbd3f3a0aeed4ac33e6b7b70d06d1a4ef9b4`
and `92946a2ba3280eb00e369643029ef1c1fa9758bdf6bf282881b90909f908b9ec`.
Warning-as-error builds, 52 focused tests, the reviewed mutation-binding check,
HLint, documentation check and `git diff --check` passed. The binary SHA-256
was `72ce16c24323c9fba99ad188db03106add1aeb5d807c6001baefe108005f5921`.
Family submission, exact failure detail, real worker/retirement and cleanup
remain open.

Kind family dispatcher entrypoint (2026-11-23): the current binary now routes
`internal-kind-family-controller` through the pinned family dispatcher using
the closed original argument envelope. A zero exit denotes the independently
observed worker and recorded receipt only; job processing and physical
retirement remain separate. An expired envelope was refused through the public
binary without starting a unit. The registry-derived command reference,
completion files, man page and CLI goldens were regenerated; the command has
an owned disposition. Warning-as-error builds, 351 parser coverage tests,
four CLI-output tests, 51 focused preparation tests, the mutation-binding
check, HLint, documentation check and `git diff --check` passed. The binary
SHA-256 was `621835c6be41e3bf2a716c373451e6d1b4289898c9563b07a6a478cf188a8cf5`.
This entrypoint supersedes the prior note's private-only state; supported family
submission remains explicitly refused, and durable failure results, live
execution, retirement and cleanup remain open.

Kind family dispatcher composition (2026-11-23): the internal dispatcher now
combines the pinned configuration/request and held executable digest, family
preparation, observed process parent and confined worker. On a confirmed
worker result, the kubeconfig and receipt steps run under the recovered
operation lease with input and parent rechecks; failures and observations stay
distinct. The [synthetic input fixture](../test/qualification/KindControllerInput.hs)
passed missing-root and wrong-digest dispatcher refusals, unmanaged-parent
refusal against the local user manager, and post-callback input-change
reporting; it started no unit or cluster. Its SHA-256 was
`4756c2f9d0f5a8ca533234619c77e17d05b0a8d435ca126e0d10ef1b351aeba4`;
the dispatcher source SHA-256 was
`c94089b1fbca9f423ff4a5e04485f5cb78be58b99eb3af189da98ed6db674f70`.
Warning-as-error builds, 51 focused tests, mutation-binding check, HLint,
documentation check and `git diff --check` passed. This composition is not
wired into the public binary: the binary remained
`82b7793aecb8533708c40528a38341ac77d2384a0bb5ffc6b4380ada92acc9a8`.
Durable primary-result handling, public dispatch, supported family submission,
real worker/retirement proof and cleanup remain open.

Kind family observed-parent boundary (2026-11-23): the held executable is now
hashed from its retained descriptor in bounded chunks, within the original
work window and the declared 256 MiB ceiling. The family input loader holds
the same program object required by the existing observed operation-parent
owner. Before opening that owner, the new boundary compares the executable,
request bytes, bootstrap projection and manager domain with its preparation;
it qualifies and rechecks the manager provider and preserves a returned
primary value when closing observation fails. Read-only program verification
now permits the kind identity, while the actual family submission path still
explicitly refuses it. The [held-input fixture](../test/qualification/KindControllerInput.hs)
passed independent executable-hash comparison, changed digest and domain
refusals, post-callback input change, and an unmanaged-process refusal against
the real local user manager. It submitted no job and touched no cluster. Its
SHA-256 was `e961ff2cb7636cac4469c1e1341368298813b5f1ea5880d8bfebf5b24eeeaaeb`;
the binary SHA-256 was
`82b7793aecb8533708c40528a38341ac77d2384a0bb5ffc6b4380ada92acc9a8`.
Warning-as-error builds, 51 focused tests, the mutation-binding check, HLint,
documentation check and `git diff --check` passed. This is a negative parent
observation only: successful managed placement, closing-fault behavior, the
dispatcher, worker execution and retirement are not yet qualified.

Kind family preparation (2026-11-23): the family now has a transport-capable
declared host plan, funded sealed-worker snapshots, fixed stream limits and an
operation intent bound to the request's scope, key and original window. The
additional role is reserved capacity, not measured usage or evidence that a
transport ran. The same declared plan was produced from two sufficient
synthetic host observations, and an insufficient host was refused. The
[capacity fixture](../test/qualification/KindFamilyCapacity.hs) SHA-256 was
`fa03a00cbf8f5cf711fdf1abf554cf24a3300ccb9fa75ca706b5d5a94eb809e0`.
The [preparation fixture](../test/qualification/KindFamilyPreparation.hs)
passed matching identity, foreign scope, insufficient capacity and expired
original-window controls; its SHA-256 was
`bf92dc377d443d71210dad4036f02da0e8e11a1e57a6456bab8e9451a5d14be7`.
Its first expired-window control had invalidly short stream reserves and was
corrected before the passing run. The warning-as-error builds, 51 focused
tests, reviewed mutation-binding check, HLint, documentation check and `git
diff --check` passed. The binary SHA-256 was
`7656f4ab5b321215c84d47a832a64d5b214949f8c819ea5d7d57e836392c2542`.
These synthetic checks create no manager unit and do not establish live host
capacity, process placement, dispatcher operation or retirement. The family
submission refusal and recovery guard remain in place.

Kind family worker adapter (2026-11-23): the family command slot can now run
the existing confined kind worker using the same sealed descriptors, sandbox,
runtime budget, bounded input and command validation. The archive, Docker
session, image, network and broker checks are shared with the legacy path;
family process failures remain a distinct typed result. The family and its
operation key must match before any Docker or worker action. The
[binding fixture](../test/qualification/KindFamilyBinding.hs) passed matching,
foreign-family, foreign-key and invalid-operation controls without starting a
worker; its SHA-256 was
`940e67463f5fbd1d1c214f20009fd7291bd3e1dffbf70d05dcf0d9f735dcb180`.
Warning-as-error executable and unit builds, 51 focused tests, the reviewed
mutation-binding check, HLint, documentation check and `git diff --check`
passed. The first build found a shadowed name, corrected before the passing
build. The public binary SHA-256 was
`875d76cea9b65fd11a4da878a2f230c1977958cf31478b3fb9f2974a86db8add`.
This is not a real family-worker execution or retirement proof; the dispatcher,
submission guard removal, recovery and live acceptance remain open.

Kind family pinned inputs (2026-11-23): the current launcher now derives its
operation key through the same validated function as the family request. A
new internal loader reads the bootstrap and request from held, fingerprinted
descriptors, rechecks them before and after its callback, and preserves the
callback result when the closing check fails. Its expected manager domain and
executable digest are supplied by its caller and still require independently
verified owners; the loader is not admission and is not yet wired to a
dispatcher. [The synthetic fixture](../test/qualification/KindControllerInput.hs)
passed a valid load, a changed-digest refusal before callback and a changed-file
disposition after callback. It started no controller or infrastructure. Its
SHA-256 was `a5df018538588ca4833b631130a4ce3f4c5f678c8e049ea8d934e787884df4de`;
the loader source SHA-256 was
`25c3fa51654f2abfeed054682703088b5dba1334b93da006aa8cb217b3f3b963`;
the binary SHA-256 was
`7c31f432f5809bdf9a94846f575233c0c1278fb3cf7ef7ef18187f1626c2ca1b`.
The warning-as-error builds, 51 focused tests, mutation-binding check, HLint,
documentation check and `git diff --check` passed. The initial unit fixture
could not import intentionally hidden owner modules; it was moved to the
source-level qualification fixture. The first source-level invocation exposed
two crypto packages with the same module name; the passing run used a temporary
package environment that hid `cryptonite`. Dispatcher, physical placement,
retirement and working recovery remain open.

Kind family request (2026-11-23): added a bounded canonical request codec that
binds the test scope/root/generation/socket to a bootstrap projection and
compares the operation key, original clock window, manager domain and executable
digest with independently supplied expected values. It carries no admission or
live-manager proof. The dispatcher and launcher do not yet use it, and the
temporary recovery refusal remains in place. The warning-as-error library,
executable and unit builds, 51 focused preparation tests, reviewed
mutation-binding check, HLint and `git diff --check` passed. The first unit
build rejected a shadowed local name and passed after correction. No live
resources were used. The request source SHA-256 was
`96316c5ee9b387c2126d23abb14c507c5116060196d2bf06b59675980fc47677` and
the focused test source SHA-256 was
`4f8362717a275301d71b8d5623cbc33adc1050832352f82246ace456bb7ea31a`.
The public binary remained
`c25d480d6c11724d6f8d7b691d334382de5c188882fc2b539a1236a33e93c45f`.

Kind family identity (2026-11-23): the shared operation-family model now has a
separate kind controller identity, keyed unit and runtime names, publication
directory and canonical producer/submission record tags. The generic family
submitter explicitly refuses this identity until its dispatcher is implemented;
the existing static kind controller has not been migrated. The native
publication codec fixture passed all four controller kinds, including malformed
and cross-kind controls and retirement of its synthetic never-sent inputs. The
native submission fixture passed 26 controls, including kind record round-trip,
unknown/nested tag refusal, and distinct unit and runtime names for every other
family. These fixtures submit no systemd job. Their SHA-256 values were
`3cea7e1051d38ecd3bff774d202b868c34d2017cdd679d7f86993e6b597dc80e`
([publication](../test/qualification/HostControllerPublicationKindCodec.hs)) and
`f21f912e75ba313fbf637f0a108e2f708c61db8de64701991a5f8e9946243104`
([submission](../test/qualification/HostControllerSubmission.hs)). The first
attempt to run them as installed-package consumers failed because their modules
are deliberately hidden; the source-module runs passed. The warning-as-error
library, executable and unit builds, HLint, all 50 focused preparation tests,
reviewed mutation-binding check, documentation check and `git diff --check`
passed. The public binary SHA-256 was
`c25d480d6c11724d6f8d7b691d334382de5c188882fc2b539a1236a33e93c45f`.
Dispatcher integration, durable submission and held retirement, recovery
effects and real kind acceptance remain open.

Controller manager read-back (2026-11-23): public status now reads the exact
controller unit after observing the retained sender absent, under a freshly
qualified matching provider and the recovered operation lease. It checks the
retained records and sender again around that read. Present and absent are
point observations only; they do not establish request processing, job
completion or worker settlement, and do not authorize further effects.
[The real-manager fixture](../test/qualification/KindControllerFreshProvider.hs)
passed for sender presence, sender absence followed by an observable unit
read, and a different manager domain. It submitted no job, used an isolated
test scope and a missing Docker socket. The fixture SHA-256 was
`a08d1bd3506bfc164620bd43c78cbe6b947675edf66e54b97fcf4a0403ebc454`;
the public binary SHA-256 was
`a4d3f49b0d86f719d9fff6ee3b6b21f01d5ad93fff9c6c41f48f8b4ed3f92e3b`.
Warning-as-error executable and unit builds passed, as did all 49 focused
preparation tests, the reviewed mutation-binding check, HLint, documentation
check and `git diff --check`. The focused tests include refusing a different
boot before contacting the manager.
Real kind acceptance, physical retirement and the phase's mutation and cleanup
evidence remain open. The existing test-identity removal and completed-operation
archive inventory checks do not independently rule out an outstanding
controller. A temporary fail-closed settlement boundary now refuses both paths
for a recorded operation, preserving their implementations and records until
an operation-scoped retirement owner can hold the required proof throughout
recovery. It does not establish retirement or provide working cleanup. The
no-intent fresh-operation path also needs provenance sufficient to distinguish
a truly fresh scope from a legacy, unrecorded controller; missing records alone
cannot establish that distinction. Do not use these paths to manufacture a
passing live run. The warning-as-error executable and unit builds and all 50
focused preparation tests passed, including refusal by both recovery functions
with the intent retained. The reviewed mutation-binding check initially caught
the changed source and manifest identities; it passed after the reviewed
bindings were refreshed. HLint, the documentation check and `git diff --check`
passed. This is not a mutation campaign or live cleanup proof. The binary
SHA-256 was `ce9b15f0c21b71d2d1ba1a3d88682a79df3d4c435d41f508b9d8f1d19d74026b`;
the focused test source SHA-256 was
`5508d96566612d88a8b90567cbd83a2c3f488abcbb46610c82d86b5156ca2858`.

Controller sender identity (2026-11-23): before the manager request, the
launcher now records the submitting bus connection's validated unique name,
bound to the retained operation, manager domain, original window and provider
binding. It rechecks that name around the send. Public status can read the
record and observe the sender name under a freshly matched provider; changed
boot, domain, binding or unavailable reads remain unconfirmed. Name absence is
only a point observation: it does not prove the request was processed, the job
finished, or a worker retired. The warning-as-error builds, all 49 preparation
tests, reviewed mutation-binding check, HLint, documentation check and `git diff
--check` passed. [The real-manager fixture](../test/qualification/KindControllerFreshProvider.hs)
observed the recorded sender present while its connection was held and absent
after it closed, and rejected a changed manager domain. It submitted no job and
used a missing test Docker socket. The fixture SHA-256 was
`9282821757bed1a53988582c98344a38a910e7a4500b2cdb639b36e64dbd4370` and
`.build/prodbox` SHA-256 was
`ff6f9718f9481c8077671463662221e330b3aa2c556814156a051dd46dfff800`.
Deletion and recreation still require independent settlement and must not
infer it from an absent sender.

Fresh controller provider observation (2026-11-23): `control status` can now
freshly qualify the selected user-manager provider and compare its manager
domain and structured provider binding with the retained records while holding
the operation lease. A missing record or failed qualification stays
unobservable; a different boot or UID is rejected before opening the manager
socket. The original retained records are re-read and the live provider is
rechecked around the comparison. A match is a point observation, not job
processing, physical worker retirement or authority to delete. The
warning-as-error builds, all 49 preparation tests, reviewed mutation-binding
check, HLint, documentation check, isolated public-status fixture and `git diff
--check` passed. Controls cover a different manager, binding and boot; the
synthetic different-boot case refuses before a manager socket. Follow-up
on 2026-11-23: [the real-provider fixture](../test/qualification/KindControllerFreshProvider.hs)
used public `control status`, an isolated temporary scope and a missing test
Docker socket. Against the local systemd 255 user manager, it matched the
fresh qualified provider and rejected a deliberately different recorded
manager domain. It made read-only manager observations and submitted no job.
The fixture SHA-256 was
`7262c7fca704c7fbb42c4ba43f928311fd06cf3f36c5666c5add537c6391a349` and
`.build/prodbox` SHA-256 was
`df894666ec7535f38a327a608d3a6d071ebcf315a490cf05cb88e8d922e68a41`.
The fixture is registered in package sources. This does not establish job or
worker retirement; real lifecycle acceptance remains open.

Controller provider material (2026-11-23): the launcher now writes the
canonical non-secret provider binding as a separate exclusive record after its
digest and before submission. The reader checks canonical base64 and provider
encoding, the digest, the bound manager domain, original window, operation and
root. Status reports only whether the material was observed, not its bytes.
Older digest-only records remain readable but cannot provide the structured
binding needed by the existing retirement machinery. A retained binding does
not qualify a live provider or establish physical retirement. Warning-as-error
builds, all 48 preparation tests, the reviewed mutation-binding check, HLint,
documentation check and `git diff --check` passed. The synthetic controls cover
canonical binding round-trip, exclusive write, duplicate refusal and unsafe
file mode. Both qualification fixtures are registered in package sources.
Actual provider and worker recovery remain open.

Controller provider binding (2026-11-23): the kind launcher now uses the
existing source-reviewed systemd provider qualification and records a digest
of its binding, nested under the retained manager domain and submission
intent, before sending. It rechecks the live provider and manager domain
before and after the call. Status reports the retained digest as local data;
it cannot authenticate a future provider without a fresh qualification and
comparison. Manager job processing, independent worker/kernel retirement,
cleanup and public completion remain open. The warning-as-error builds, all 48
preparation tests, reviewed mutation-binding check, HLint, documentation
check, synthetic public-status fixture and `git diff --check` passed. Controlled
records included missing, mismatched, duplicate and unsafe provider records;
they do not prove live provider qualification. No live controller was
submitted for this slice.

Controller manager-domain record (2026-11-23): the launcher now observes the
systemd manager domain before submission and records its boot ID, bus ID,
manager name, UID, PID, start ticks and the original absolute monotonic
window under the operation lease, bound to the submission digest. It rechecks
the domain and operation before the send, records a returned job, and
rechecks the manager domain afterward. `control status` can read the retained
domain and window without comparing them to today's manager. This is a local
record of a point observation, not provider authentication, an authoritative
job identity, physical retirement, or permission to delete. The warning-as-error
builds, all 48 preparation tests, reviewed mutation-binding check, HLint,
documentation check and `git diff --check` passed. A synthetic public-status
fixture observed the retained domain and job with settlement unobserved. The
first unit build failed because the domain type was package-private; the
validated interface was exposed and the rebuild passed. Real manager and
lifecycle evidence remain open.

Controller job receipt (2026-11-23): when the launcher receives a systemd
job path, it validates the path and records it exclusively under the same
operation lease, bound to the retained submission digest and scope. A missing,
changed, unsafe or mismatched intent refuses the receipt. The public status
reads the retained path as local evidence only. If the manager reply or the
receipt write is uncertain, the operation remains unconfirmed and its intent
is retained. A job path can be reused and does not authenticate the manager or
prove that a job or worker has settled. Independent retirement and safe
cleanup/recreation, including older unrecorded operations, remain open. The
warning-as-error executable and unit builds, all 48 preparation tests, reviewed
mutation-binding check, HLint, documentation check and `git diff --check`
passed. [The isolated public-status fixture](../test/qualification/KindControllerJobStatus.hs)
reported the synthetic job while explicitly leaving settlement unobserved; it
submitted no job and used a missing test Docker socket.

Controller submission status (2026-11-23): `control status` now reads a
retained controller request digest under the recovered operation lease,
validates the record against its scope, generation, operation and held root,
and reports missing, conflicting or unobservable records separately. It
reads the historical digest from the record rather than comparing it with the
current executable. The status output explicitly does not claim a send,
manager state or worker settlement and does not authorize cleanup. The current
warning-as-error build, all 48 preparation tests, reviewed mutation-binding
check, HLint, documentation check and `git diff --check` passed. The public
fixture used a missing test socket and observed a conflicting retained record.
Its first version selected a different socket from the recorded operation and
correctly failed to associate it; aligning the isolated projection resolved
the fixture failure. Actual manager and worker recovery remain open.

Controller submission intent (2026-11-23): before its systemd call, the
public launcher now records an exclusive scope-, generation-, root-inode- and
operation-bound digest of the exact launcher request under the recovered kind
lease. Its digest covers the selected argument vector, executable digest,
unit/slice/socket, description and resource plan. A retained intent refuses a
second submission; an interrupted write or uncertain send stays incomplete.
The lease is released after the manager call before waiting, so the controller
can acquire it; a controller that starts before release can still refuse and
must be recovered. The record is not evidence that a send occurred, does not
authenticate a manager job or provide physical worker retirement. A returned
job path is now recorded separately and public status reports both local
records; deletion/recreation recovery does not yet consume them.
Those recovery paths and the risk of older unrecorded controller attempts
remain open. The
warning-as-error executable and unit build, all 48 focused preparation tests,
reviewed mutation-binding check, HLint, documentation check and `git diff
--check` passed. The controlled cases cover foreign-operation refusal, a single
admitted action, duplicate refusal, mismatched request, unsafe mode and a
malformed record. No live controller was submitted.

Controller settlement correction (2026-11-22): the launcher previously returned
success after a manager `GetUnit` absence response, and the public handler used
that result to permit a Kubernetes probe. Unit absence alone does not establish
that the submitted job was processed or that its physical worker family
settled. Both on-time absence and an unavailable/late absence now remain
unconfirmed, so the probe is not admitted. The managed-host retirement code
currently covers RPC-birth, ordinary-cascade and mutation controllers, not the
kind controller; a durable kind submission identity and independent manager,
worker and kernel retirement observations remain necessary. The warning-as-error
build, all 47 preparation controls, reviewed mutation-binding check, HLint,
documentation check and `git diff --check` passed. The controls confirm both
unit-absence outcomes refuse follow-up. No live controller was submitted for
this correction.

Controller lease composition follow-up (2026-11-22): the public reconcile
handler now keeps one recovered operation lease while it reads the worker
receipt, inspects the exact recorded Docker node, checks readiness and runs the
network probe. It re-reads the receipt and node and checks readiness and lease
stability after the probe. Changed or unavailable binding retains the prior
probe diagnostic as unconfirmed. This does not establish peer authentication,
physical worker settlement or final reconcile success; real composition stays
open. The warning-as-error executable and unit builds, all 47 preparation
controls, reviewed mutation-binding check, real `kubectl` snapshot fixture,
HLint, documentation check and `git diff --check` passed. Controlled tests
cover mismatch before the probe and a retained result after lease instability.

Kubeconfig snapshot follow-up (2026-11-22): the readiness and network-probe
consumers previously reopened the retained path after validating it, leaving a
replacement window in which `kubectl` could consume different configuration.
They now reconstruct the strictly validated configuration into an anonymous
sealed descriptor, read it back, and pass its bounded process descriptor path
to `kubectl`. No secret contents are added to durable files or diagnostics. This binds the
consumers to the snapshot; it does not authenticate the Kubernetes peer or
prove worker settlement. The warning-as-error build, four configuration tests,
46 preparation tests, the reviewed mutation-binding check, HLint, documentation
check and `git diff --check` passed. A real child process read the snapshot;
write and retained-file replacement controls preserved its bytes. A separate
non-secret disposable fixture used the real `/usr/bin/kubectl` v1.35.10 through
the bounded subprocess with its limited environment: `config current-context`
returned the selected context before and after the retained path was replaced.
The reproducible fixture is [KindKubeconfigSnapshot.hs](../test/qualification/KindKubeconfigSnapshot.hs)
(SHA-256 `fe86827054e863344a979466a8e421ef63ee214eefb84049a2a85d3e8de64f4e`);
run it with `cabal exec --builddir=.build -- runghc -package=prodbox
-package=temporary test/qualification/KindKubeconfigSnapshot.hs`. It made no
network request or resource mutation. The fixture used the Cabal-built library,
not the public command. The corresponding `.build/prodbox` SHA-256 was `1f0a69432413a1144ff243a384094f35ce2cdcdaa9c488a86091b762f29a4b7c`;
the snapshot implementation SHA-256 was
`5d244d24a3007232cecbce3ece199a743765084cad0a455c836f2ff7e9b89333`.
Real cluster and Kubernetes composition remain open.

Typed enforcement follow-up (2026-11-22): probe cleanup now has distinct
not-started, unconfirmed and confirmed values. The public reconcile report and
Phase 2 service gate use the same completion predicate, requiring successful
socket observations, no primary probe failure and confirmed cleanup; a message
that happens to say `namespace removed` is not a cleanup result. The Phase 1
scenario consumes the typed cleanup observation. This does not yet complete
public reconcile, settle a worker or qualify a real cluster. The
warning-as-error build, all 46 focused preparation tests, reviewed
mutation-binding check, HLint, documentation check and `git diff --check`
passed. The controls reject unconfirmed cleanup even when its diagnostic text
matches the success message and reject a retained primary failure.

Probe cleanup read-back follow-up (2026-11-22): a successful namespace
removal reply and wait no longer suffice for a removal receipt. The probe now
reads a bounded, structured exact-name Kubernetes inventory and requires it to
be empty between matching live `kube-system` UID observations before recording
removal. Missing controls, malformed or nonempty inventory and failed reads
remain unconfirmed. This is a point-in-time API observation, not atomic
exclusion of a concurrent namespace creation or proof of controller settlement.
The warning-as-error build, all 45 focused preparation tests, reviewed
mutation-binding check, HLint, documentation check and `git diff --check`
passed. The controls cover successful read-back and unavailable, nonempty and
malformed inventory. Real Kubernetes cleanup and Phase 1 acceptance remain open.

Controller receipt binding follow-up (2026-11-22): the worker and network
probe record writers now independently re-read the retained kind intent and
require it to match the record operation while the supplied lease-stability
check is held, including during read-back. A stability callback for a different
operation cannot by itself authorize a new record. This check does not acquire
the lease, establish controller settlement, or prove resource presence or
absence; public reconcile completion remains open. The warning-as-error build,
all 44 focused preparation controls (including both foreign-operation writes),
the reviewed mutation-binding check, HLint, documentation check and `git diff
--check` passed. These controlled tests do not establish a live controller or
Kubernetes result.

Typed worker observation in progress (2026-11-22):
`confirmedKindWorkerNode` recognizes the exact stable archive, peer, scope,
snapshot, broker, subprocess and recorded create/start result shape, while
returning no identity for changed, failed or incomplete shapes. This is only a
worker result, not readiness, ownership or a complete reconcile. Controlled
negative tests covered changed snapshots/archive, failed worker, retained
request marker and refused broker; the warning-as-error build and all 27 focused
preparation tests passed. The interpreter is not yet connected to a scoped
controller-result channel or the public completion handler. A scoped receipt
implementation is now in progress: it binds the operation, generation, root
identity and node ID, writes exclusively, and reads the exact private file back
under the recovered lease. A warning-as-error build and all 36 focused tests
passed, including duplicate, foreign-operation, unsafe-mode and altered-record
controls. The controller entry now records the receipt only after the typed
worker result and kubeconfig installation succeed, and its diagnostic path is
validated and created exclusively under the selected root. The warning-as-error
build and all 38 focused tests passed, including the named receipt assertion;
the managed controller was not run in this controlled suite. The public
handler now reads the scoped receipt after settlement, compares its node ID
with the recorded create/start and a fresh running-container observation, and
requires a ready single-node observation before the network probe. It still
reports the operation incomplete. A warning-as-error build and 39 focused
tests passed, including receipt/path rejection and the namespace controls;
the running-container composition was not exercised against Docker. A later
warning-as-error build and all 40 focused tests passed after the diagnostic
correction and namespace replacement control. Public completion and reviewed
isolated mutants remain open. A subsequent controlled node-status test now
checks the receipt ID, running state and removal-attempt state; the
warning-as-error build and all 41 focused tests passed. Its reviewed isolated
mutation and real Docker read-back remain open.
The focused HLint run, `dev docs check` and `git diff --check` also passed for
this slice. These are not the canonical `dev check` or real acceptance.

Recreation audit (2026-11-22): `src/Prodbox/Control/Recreate.hs:105` uses
file-existence results to decide whether missing create and removal records can
stand in for completed removal, but its `exists` helper maps every IO error to
`False` at line 156. An unreadable record must not be treated as absent. The
same archive preflight lists only cluster-labelled containers, so it must also
check the exact selected name and preserve unknown inventory as unconfirmed.
It also maps every non-`KindIntentMatches` observation to `ArchiveNothingRecorded`,
including conflicting/unobservable records and a valid volume-bound intent;
only a confirmed missing intent can mean nothing was recorded.
The implementation now retains conflicting, unreadable and volume-bound
intents as unconfirmed, checks both exact-name and label inventories under the
operation lease, and distinguishes missing records from unsafe or unreadable
ones. The refused-network exception now reads the bound typed receipt and
accepts only its 409 conflict response. A warning-as-error build and all 31
focused tests passed, including missing versus unsafe record paths and invalid
or unobservable intent. These controlled tests do not qualify a real provider
run. The archive path now additionally asks the existing typed observers for
the bound node, volume and network removal receipts, or a verified never-started
disposition, before moving records. A subsequent incremental warning-as-error
build and all 35 focused tests passed; the archive entrypoint itself refused
orphaned and invalid records while retaining their contents. These tests do
not exercise the typed receipt composition with Docker. Independent resource
read-back and real recreation remain required; the earlier accepted report
remains historical evidence.

Deletion audit (2026-11-22): a missing node-create result previously took a
success branch without checking whether a create attempt had been recorded;
an invalid result could also be treated as unstarted when the attempt file was
missing. The code now requires both an explicitly missing result and a
generation-bound, stably observed missing attempt under the operation lease;
unknown and invalid results retain recovery state. The warning-as-error build
and all 29 focused tests passed, including missing, present and unobservable
attempts and invalid/unobservable results. The first build caught an unused
import, removed before the passing build. A real interrupted-create regression
and the required source mutation remain open.

Further deletion review found that `Delete.hs:292`, `:303` and `:317` accept
returned removal actions or the mere presence of a prior receipt without
checking the transport outcome and bound receipt. New-action classification now
requires a 204 response and a successfully recorded receipt for each resource;
the foreign-network refusal case accepts only a bound 409 response. A
warning-as-error build and all 32 focused tests passed, including failed,
unconfirmed and unrecorded replies. A mutation assertion is bound but its
reviewed mutant and isolated run remain pending. The prior volume and network
branches now read their operation-bound typed receipts and refuse invalid or
unobservable results; volume-with-no-intent also requires no create attempt.
The warning-as-error build and all 34 focused tests passed, including the
invalid and unobservable receipt decisions. Independent resource read-back,
the actual public repeat-delete path and its mutation remain open.

Build provenance correction (2026-11-22): an earlier incremental Cabal build
was still running while the subsequent build and 34-test run completed. Both
builds were allowed to finish; a later sequential `-Werror` build reported the
tree up to date and the same 34 focused tests passed again. That is incremental
evidence, not a clean rebuild or the canonical gate. The subsequent direct
orphaned-record regression passed as described above.
The positive-control path also removes the ID returned by `docker create`
before verifying the ID, name and label of the created container, and treats
an existing absence-record filename as a valid matching record. Both need
exact-identity and typed-record handling before this path is used live. The
implementation now checks the exact created ID, name, label, stopped state and
`none` network before removal, disables image pulling for control creation,
and no longer treats an existing filename as a valid absence receipt. Its new
identity test passed with the warning-as-error build and all 33 focused tests.
A durable pre-effect intent, interruption recovery and a typed read-back for
repeat deletion are still needed; until then the path is not qualified for a
live run.

Namespace fixture audit (2026-11-22): the network-enforcement probe previously
issued a namespace delete even if creation failed. It now accepts only the UID
returned by a successful create, skips cleanup entirely if that identity is
unconfirmed, and submits a raw deletion with a UID precondition before waiting
for removal. Kubernetes documents [DeleteOptions preconditions](https://kubernetes.io/docs/reference/kubernetes-api/definitions/delete-options-v1-meta/),
and the [kubectl v1.35.10 delete implementation](https://raw.githubusercontent.com/kubernetes/kubectl/v0.35.10/pkg/cmd/delete/delete.go)
accepts a raw delete body from stdin; `kubectl version --client` identified that
client version locally. Controlled creation-failure and UID-body tests passed
with the 38-test focused suite; the reviewed isolated mutant remains pending.
The probe now rechecks the namespace UID before each namespaced mutation and
stops if baseline connections fail; the controlled replacement test passed in
the 40-test focused suite. These are point checks, not exclusion: they do not establish a
durable pre-effect intent or prevent replacement between a check and an effect.
Those obligations remain open before a live qualification run.

Probe identity work (2026-11-22): the public reconcile, service gate and
Phase 1 runner now use a recovered operation lease and write an exclusive,
scope- and generation-bound intent before namespace creation. The returned UID
must be durably recorded and read back before subsequent probe effects; a
confirmed cleanup also records its UID. A missing response or failed UID write
retains the intent and does not start another effect. These records are not a
recovery command: interrupted creation with an unknown UID, safe resumption,
independent cleanup, and exclusion of namespace replacement between checks and
effects still require implementation and validation. The client now bounds its
connection attempt and reports an explicit result; failed, empty or ambiguous
logs are unavailable rather than a denial. Its pod address is validated before
being embedded in the client command. This revised observer still needs the
real allowed/denied/restored traffic case against the pinned node image. The
warning-as-error executable and unit build passed, as did all 44 focused node
artifact/preparation tests, including the unavailable-log and probe-record
controls. These controlled tests are not real cluster or mutation evidence.

Probe recovery visibility (2026-11-22): `control status` now reads the
deterministically named reconcile probe's intent, creation UID and removal
receipt under the recovered operation lease. UID extraction validates the
entire retained record against deployment, generation, operation, namespace
and held root identity. The output explicitly says that neither worker
settlement nor namespace state was observed; it does not authorize removal.
The same record observation is included when Docker observation fails so that
that failure does not hide the retained recovery identity.
`captureSubprocessWithInputBounded` documents direct-child cleanup only, so a
released operation lease cannot establish that an interrupted kubectl and its
descendants have settled. A durable managed-worker identity and independent
settlement/read-back remain necessary before resuming effects.
The warning-as-error build and 44 focused tests passed with the UID extraction
checks; targeted HLint and the documentation check also passed. These results
do not validate worker settlement or the public status against a live cluster.

Mutation catalog work (2026-11-22): registered source-bound M01 variants for
the unconfirmed node-create disposition, unobservable recreation intent and
failed node-removal reply. Their designated assertion markers now precede the
ordinary checks in the same unchanged tests, so an ordinary assertion cannot
mask the intended mutation result. Source, binding and candidate digests are
listed in [the mutation manifest](mutation_cases.md). Isolated builds and
designated-assertion kills remain required; registration is not execution.
The warning-as-error executable and unit build passed, the 44 focused
preparation tests passed, and the manifest-binding test prepared all three new
variants and verified their recorded digests. Targeted HLint, the documentation
check and `git diff --check` passed.
Executor audit and partial correction (2026-11-22): the previous runner
recursively removed the campaign directory even after an unconfirmed worker,
mounted the host Cabal directory writable, and copied prior build outputs into
mutant workspaces. It now retains the campaign directory, treats results as
inconclusive until workspace cleanup is proven, stops after the first
incomplete case, creates a fresh private campaign root, and uses the bounded
secret-filtered source snapshot writer without copying build artifacts. The
host Cabal home is no longer mounted; the isolated Cabal home builds offline.
This intentionally does not yet provide an authenticated dependency store, so
a clean offline build may be unavailable. Container label inventory is still a
point observation without the positive control and managed-worker settlement
needed to authorize a successor, and exact workspace cleanup remains open.
The container now mounts captured source read-only and uses a separate private
output root for the build, home and Cabal state. It rejects ambiguous bind
syntax and lexical overlap with its source or toolchain paths. These lexical
checks do not establish filesystem identity or exclude mount aliases; source
and output now have no-follow descriptors held across each Docker invocation,
with parent/name, ownership, private mode, distinct inode and same-mount
observations before and after. If a binding changes after a subprocess returns,
the case result remains inconclusive and records its stage, exit status,
bounded output lengths and, for a selected test, decoded assertion outcome.
Failed or unobservable container-inventory observations are retained alongside
that primary outcome; arbitrary subprocess text is not written to diagnostics.
An I/O failure after a bound action starts is recorded as unconfirmed, not as
a refusal before effects; a failed inventory command retains its exit status.
The warning-as-error build, outcome-preservation and action-exception controls,
mutation-manifest binding test, targeted HLint and documentation check passed.
These controls do not establish actual container settlement or cleanup.
These checks do not
make Docker's path-based bind atomic, exclude all mount aliases or other writers,
or establish worker settlement; those remain necessary before qualification.
The warning-as-error build passed. Controlled checks passed for a stable pair,
replacement after a callback with its result retained, symlink refusal before
the callback, and the bind-argument/lexical controls; targeted HLint and the
documentation check passed. No Docker invocation qualified these checks.
The warning-as-error build and the mount-argument/overlap control passed, as
did both campaign-root controls and the mutation-manifest binding test. The
targeted HLint and documentation checks passed. No container was run for this
change, so these results do not prove the effective runtime mounts.
These boundaries require correction and independent validation before a
qualifying campaign; no mutation kill is claimed from this registration.
The mutant build and selection now stop on failed or unconfirmed outcomes
before starting the next test step, and container labels include the campaign
identity. Before each Docker request the executor now writes and reads back an
exclusive launch intent under the held campaign directory, binding the label,
stage, command digest, timeout, image, explicit socket, and source/output
device and inode identities. A missing or conflicting intent refuses the
request. The intent also names an exclusive Docker `--cidfile`; the runner
refuses a pre-existing or unobservable file and reads a returned 64-hex ID
through the held directory without following links. Docker documents the
[cidfile creation and existing-file refusal](https://docs.docker.com/reference/cli/docker/container/run/#capture-container-id---cidfile).
The command also uses `--pull=never` so a missing image is not silently pulled.
2026-11-22 campaign binding follow-up: snapshot creation now uses the held
campaign descriptor, and each container request checks that its workspace
parent is the same held campaign before launch and after the action. A changed
binding preserves a returned action result as unconfirmed; a replacement seen
before launch is refused. These checks do not make Docker pathname mounts
atomic or exclude aliases and concurrent writers. The actual worker-retirement,
cleanup, isolation and real mutation evidence remain open. Later patch and
binary reads also remain pathname-based; they must be bound before mutation
execution can be admitted. The warning-as-error executable and unit build,
four focused campaign and replacement controls, HLint, documentation check
and `git diff --check` passed. No Docker container was launched for this slice.

2026-11-22 campaign recovery slice: a newly created mutation campaign now
holds its original directory chain while writing and syncing an exclusive
source-manifest and root-inode creation record before snapshot or container
work. `test status` reads the record as unauthenticated local evidence and
reports missing, unsafe or mismatched records without inferring worker absence.
This does not establish daemon identity, worker retirement, safe deletion or
qualifying mutation evidence; those requirements remain open. Holding the original
root alone does not make subsequent pathname mounts atomic or prove that later
work is bound to that inode. The warning-as-error executable and unit build passed;
three focused campaign controls passed, including the public status fixture,
exclusive-record refusal and tamper detection. Targeted HLint, `git diff
--check` and `prodbox dev docs check` passed. No container was launched for
this slice.

The runner now writes and reads back an exclusive private receipt of an observed
ID, bound to the exact launch intent and held directory identities. The receipt
observer can read that ID even if the CID file later disappears; neither file proves
container ownership, daemon authentication, resource absence or worker
retirement. Integration of the receipt into a supported recovery operation
remains open. `test status RUN_ID` now provides a read-only view of the exact
retained mutation campaign, validates recognized launch and receipt bindings,
reports unrecognized records, and explicitly leaves Docker state, worker
retirement and cleanup unobserved. It does not resume or delete a worker.
Status reads the retained command digest, timeout, image and socket from the
bound launch record, and reports whether they match the current implementation;
a difference alone is not recoded as a corrupt receipt or authenticated as a
particular historical revision.
The warning-as-error build, public status fixture with a self-consistent older
binding and a tampered record, 349 parser-coverage tests, generated CLI goldens,
targeted HLint and documentation check passed. The fixture uses local synthetic
records and does not establish Docker state or recovery completion.
The current warning-as-error build passed; a private fixture exercised the
public status command and rejected tampered and symlinked campaign records,
an invalid run ID exited 2, all 349 parser-coverage tests and the generated
CLI goldens passed. The documentation generator initially rejected the new
leaf until its Phase 1 command-disposition row was added; regeneration and the
subsequent documentation check passed. This is local record evidence only.
The current warning-as-error build and four focused controls
passed, including changed-command refusal, hard-linked receipt refusal, and
reading the retained receipt after CID-file removal; the manifest-binding test,
targeted HLint and documentation check passed. No container was launched.
The earlier warning-as-error build and
four focused controls passed, including malformed, symlinked and pre-existing
ID files; the pre-existing file was retained and no action ran. Targeted HLint
and the documentation check passed. No Docker container was launched for these
controls. An empty label inventory is explicitly recorded as unconfirmed
retirement and does not admit the next step. The intent does not authenticate
the daemon, identify a returned container, or prove a request settled; those
recovery and managed-worker obligations remain open. The warning-as-error
build and controlled launch-intent/empty-inventory tests passed, along with the
manifest-binding test, targeted HLint and documentation check. No container
launch or mutation result was used as evidence. Campaign-root
creation now uses no-follow directory descriptors, exclusive `mkdirat`, and
held-versus-named identity checks; a failed preparation reports the possible
retained path. The warning-as-error build and both campaign-root controls
passed, including the substituted `.build` symlink case; the mutation-manifest
binding test, targeted HLint and documentation check also passed. This does not
by itself prove worker or mount isolation.
The warning-as-error build passed; a controlled campaign-root test verified
exclusive creation, preservation of an existing root, and refusal of an
unsafe parent without changing its permissions. The 44 preparation tests and
the reviewed-manifest binding test also passed, as did targeted HLint, the
documentation check and `git diff --check`. No container or mutant was run.

- [x] **P01-T08** — Provide supported test preparation for the pinned kind executable and node OCI archive, including bounded acquisition, digest/read-back verification and exact scoped import; the public harness prepares its own declared prerequisites without hand-created Docker images. Both clean A01-08 runs verified retained artifacts through recreation and exercised changed, missing and foreign inputs before effects.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-01`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [x] **A01-01** — two ready scopes, interrupted teardown, repeat and independent exact cleanup passed in clean-runtime evidence `f0d4fa82d6cf765c4407d1bdae6c6e5d`.
- [x] **A01-02** — same root and generation, retired original operation, and independently matched host and PV markers on the replacement passed in the clean-runtime run.
- [x] **A01-03** — foreign scope, network, context, image and artifact adverse controls passed with exact fixture cleanup in the clean-runtime run.
- [x] **A01-04** — real allowed and forbidden connections and the disabled-policy control passed in the clean-runtime run.
- [x] **A01-05** — capacity admission, kernel peaks, the 64 MiB and 16 MiB cases and quota adverse controls passed in the clean-runtime run.
- [x] **A01-06** — the retained ordinary report and the fabricated, missing, stale and wrong-scope controls passed in the clean-runtime run.
- [x] **A01-07** — Campaign `1783840184764378` supplied 27 intended compiled kills, the survivor and the invalid-build control. Replay `1827568496146719` supplied the typed timeout calibration. Independent read-backs confirmed worker, quota volume and workspace retirement for all 30 qualifying cases.
- [x] **A01-08** — empty-runtime preparation, exact pinned artifacts, adverse inputs, replacement and independently observed removal passed in clean-runtime evidence `f0d4fa82d6cf765c4407d1bdae6c6e5d`.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M00, M01, M02 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

Image admission correction (2026-11-23): prerequisite preparation now
requires a completed, unchanged image attempt, a recorded successful Docker
load response and a stable same-session image read-back before the separate
image observation can admit network creation. A previously present image no
longer masks an unconfirmed or failed load. The focused fixture suite passed
63 tests, including refusal of an unconfirmed transport, an error response,
an incomplete result record and skipped read-back; the executable build and
HLint passed. Binary SHA-256:
`410cf66a2fb0b19b7abb5879be85ca4aa6e4977aff09a7c7ac3548d0ddd23ed3`.
These fixtures do not establish daemon-side worker settlement or complete the
real kind acceptance and cleanup obligations. The static controller guard
still refuses recovery, and the public controller still reports incomplete.

Controller protocol origin (2026-11-23): the new family preparation boundary
creates a schema-3 `family-v1` intent exclusively while holding the initial
operation lease, before image submission. The normal intent observer accepts
that exact document, while the family-specific observer rejects older intents.
Legacy submission requires the older intent; family launch and family
retirement provenance require the new intent. Neither choice can be added to
an existing intent. The earlier reader compared the complete intent document
against its own schema ([KindIntent.hs](../src/Prodbox/Control/KindIntent.hs)
around line 190), so an older reader cannot interpret the new document as its
legacy intent. This choice follows the write-before-effect and no-inferred-
absence rule ([standards](development_plan_standards.md) line 88); it is not
proof that a family was sent or retired. The new image preparation entrypoint
is staged but is not selected by the public command. The static controller
guard and the family-send prohibition remain in place pending public
completion, recovery composition and real validation.

The executable build, 65 focused preparation tests, HLint, documentation
check and `git diff --check` passed. The focused cases cover exclusive intent
creation, rejection of a legacy intent as family provenance, and rejection
of a legacy submission for a family intent. Binary SHA-256:
`148e7102ee32175d09c38a00d56ac3069d4f2bbeb3678814bb9c5832e09f8189`.
The standalone qualification fixture was updated for the new intent but its
first compile through the ordinary package interface failed because it imports
hidden modules. A subsequent isolated source build and run passed the
dispatcher input, missing-root, unmanaged-parent and post-callback-change
fixture; it sent no controller job. Fixture SHA-256:
`c9a35cbcc812bc3fa9008b89523a232b203c180cd7d3377175ad82cecf8a4ea4`.
No live controller or real kind acceptance was attempted, and Phase 1 remains
open.

Family deletion admission (2026-11-23): `control delete` now routes a
positively identified family intent to its existing family-retirement owner;
legacy intents still encounter the static controller guard. The family path
rechecks the protocol and exact submission under the lease, holds physical
retirement across resource removal and retires the published inputs first.
The new controlled refusal test confirmed that missing family submission
provenance stops before resource removal and preserves the intent. The build,
66 focused preparation tests, HLint, documentation check and `git diff
--check` passed. Binary SHA-256:
`941c5a6dfa8253a20a9de45c3d35c6b4bc792953f171490aba1b40f868f96f69`.
No public reconcile creates this family intent yet; successful real family
submission, removal and independent postconditions remain unproven. The
initial build caught a layout error; the corrected rebuild passed.

Family worker admission (2026-11-23): the family worker now verifies the
family intent and exact retained launch request under the operation lease
before starting work and at each node create, start and configuration-write
admission, as well as before and after kubeconfig installation and receipt
recording. Missing, different, changed or unobservable requests and an
unstable lease refuse admission. The dispatcher summary preserves that
refusal as work not started. The executable build, 66 focused tests,
standalone synthetic dispatcher fixture, HLint, documentation check and
`git diff --check` passed. Binary SHA-256:
`03913678648dc40cb6fafaa39b8213833e4e585b171cade7a2bb32c85b929ad2`;
fixture source SHA-256:
`9ae27d98e6b36a56b166ceee29f5a16c417e2bcad966b3654fa18f475e8bff83`.
These controlled observations neither send a family job nor prove its
retirement; public activation, interruption-safe archive, and real acceptance
and cleanup remain open.

Family completion boundary (2026-11-23): a new completion observer borrows
the exact family retirement owner and reacquires the operation lease. It
requires the retained family request and its matching request digest in a
fully successful worker, parent, input and post-action summary before
entering a caller-supplied observation. The supplied recheck retains the
retirement, protocol, request and result across the caller's effect
boundaries; a change after the callback preserves its result as unconfirmed.
This is not itself Kubernetes readiness or a public completion command.

The synthetic dispatcher fixture refused a missing result without entering
the callback, accepted an exact synthetic result under the retirement owner,
and preserved the callback value after the result was changed. Its first
compile exposed a missing test import; the corrected isolated source build and
run passed. The executable build, 66 focused tests, HLint, documentation
check and `git diff --check` passed. Binary SHA-256:
`b7307c4e0750d442951c6d0e4ebc99f7812d6ba55a1038ffd66cb234af8468f3`;
fixture source SHA-256:
`b969b08f8f0563a1ccf7a837c3600f71c579314a9277d422dc5febcfd445a4d9`.
No job was sent in that fixture. The public command, real readiness and
network observations, interruption-safe archive and real acceptance remain
open.

Family readiness composition (2026-11-23): the completion owner now has an
observer that reads the bound worker receipt and matching running node,
observes Kubernetes readiness, runs the real network enforcement probe under
the same retirement and lease recheck, and repeats the node and readiness
observations. Completion requires the probe's independent cleanup receipt as
well as the expected network observations. Controlled callback fixtures
exercised success, missing node, unconfirmed probe cleanup and ownership
change; these do not constitute real Kubernetes or network acceptance. The
public reconcile path does not yet invoke this composition.

The executable build, 66 focused tests, standalone synthetic dispatcher
fixture, HLint, documentation check and `git diff --check` passed. Binary
SHA-256:
`c69d6eb113981034a3c3234f5a9f2d238b15f9235d496d8ec6b9a22909501921`;
fixture source SHA-256:
`649de47dc5a29f89d0b8b9e0ce35088f2ebc64c7497e593d6d9c79d135be0a5a`.
Family send, public activation, interruption-safe archive and real cleanup
and acceptance remain open.

Public family completion route (2026-11-23): `control reconcile` now routes
an existing family intent through the bound retirement and readiness
composition. It reports completion only when the family result, retirement
closing checks, bound node, readiness and network probe including cleanup
all pass. A public-binary fixture with a family intent but no launch record
refused before probing and preserved the intent. The fixture's first run
used a different socket in its selected configuration and failed its
assertion; after using the same projection as the intent, the targeted and
complete 66-test focused suite passed. The executable build, HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`0663ef14326f8c238226d5f2603ef669b7bc79e06700407283c9d687d146fac6`.

Fresh reconcile still selects the legacy controller and cannot create a
family operation. The policy probe has a single fixed recorded attempt per
operation; repeating or interrupting it can leave reconciliation incomplete,
so bounded probe recovery and repeatability are required before phase
closure. No successful public family reconciliation or real kind acceptance
was run. Family send, recreation and real cleanup remain open.

Probe worker settlement correction (2026-11-23): review of the new public
family completion route found that the earlier readiness composition could
start the policy probe while holding proof only for the retired kind
controller. The probe's `captureSubprocessWithInputBounded` settles only its
direct child, so that proof does not cover interrupted probe descendants or
their requests. The public family completion observer now refuses to start
the probe and cannot report successful completion until a managed probe worker
and its recovery are delivered. This supersedes the earlier claim that the
public completion route can run the real network probe. No live run was made
through the unsafe route.

Probe status now derives an explicit scope-bound journal observation for no
records, unknown UID, missing or recorded removal, and conflicting or
unobservable records. An orphan removal record is a conflict. These are local
record observations only; they do not establish namespace state or worker
settlement and do not authorize another probe. The executable build, all 66
focused tests, HLint, documentation check and `git diff --check` passed.
Binary SHA-256:
`0f5c8fcf222fa501721b7afaeda48fa7f9f5be3753cdd5c227b873e4e4b533ae`.
The managed probe, interrupted cleanup, repeatability, family activation and
real Phase 1 acceptance remain open.

Family-bound probe command adapter (2026-11-23): the network probe now has a
staged adapter that accepts only the matching kind operation family and uses
its owned, bounded command runner for `kubectl`, including stdin and the
original work deadline. The same retained-lease admission remains in front of
each command and journal write. A completed child command is not family
retirement; this adapter is not yet invoked by the controller and does not
authorize the guarded public probe. The controller's result recording,
interrupted namespace recovery, family retirement and real qualification
remain necessary.

The executable build, 66 focused tests, existing family/key binding fixture,
HLint, documentation check and `git diff --check` passed. The binding
fixture checks matching, foreign and invalid keys; it did not run a managed
probe. Binary SHA-256:
`1190c97806291ec43a6eb8d195eb0ecd82fb6cf6e3f9c68a8cf8c2b824e1d382`;
fixture source SHA-256:
`940e67463f5fbd1d1c214f20009fd7291bd3e1dffbf70d05dcf0d9f735dcb180`.

Managed probe controller composition (2026-11-23): after the node receipt,
the staged family worker now invokes the family-bound policy probe under its
retained operation and parent checks. Its result distinguishes a complete
probe, including confirmed cleanup, from an incomplete probe. Family
completion now requires the new probe-complete disposition; an earlier
receipt-only result cannot satisfy it. The public post-retirement probe guard
remains in place, and family submission remains disabled pending exact
interrupted namespace recovery and real qualification.

The synthetic dispatcher fixture checked the completed and failed-cleanup
result mappings and the retirement-bound completion record; it did not run a
managed probe. The executable build, 66 focused tests, fixture, HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`8d24beb409448cce07f5dddd1c5e247486b1d4bb0e1b635167283979e80b7414`;
fixture source SHA-256:
`2b3fca565e663a9af52df1ad6f49d7d6d5339533d41d5facd6b4e5a33617375e`.
Real node, policy and cleanup evidence remains open.

Recorded probe completion (2026-11-23): family completion now requires both
the exact request-bound probe-complete summary and a matching intent, creation
UID and removal journal under the held operation lease and family retirement
owner. It rechecks the same UID and records across the readiness observation.
The public path uses that recorded probe evidence and fresh node/readiness
observations; it does not start an unmanaged post-retirement probe. This
supersedes the prior unconditional post-retirement probe refusal, but does not
make family submission or interrupted probe cleanup available.

The synthetic retirement fixture refused completion with a missing result or
missing cleanup journal, accepted its exact synthetic journal and result, and
preserved an observation after a changed result. No controller job or real
probe was run. The executable build, 66 focused tests, fixture, HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`448e900ac772a3dcd2bcf25b28607514e2104c0a1d0270c315077827fe065644`;
fixture source SHA-256:
`3f5adea744965a8ddffc9d110533ca4f58f424634c91dabc5636d7cee8713e70`.
Family activation, interrupted cleanup, recreation and real acceptance remain
open.

Node CA identity prerequisite (2026-11-23): the existing Kubernetes reader
explicitly leaves the selected CA unbound to the owned cluster
([KindKubernetesRead.hs](../src/Prodbox/Control/KindKubernetesRead.hs), lines
3 and 84–87), while readiness reports certificate and cluster identity as
unverified ([KubernetesReadiness.hs](../src/Prodbox/Control/KubernetesReadiness.hs),
lines 113–116). In accordance with the same-Authority and fail-closed
requirements, public family reconciliation now remains incomplete even if
its other observations succeed, until this identity is independently bound.

An exact Docker container CA-archive comparison is available as a building
block. It accepts one bounded regular `ca.crt` entry and compares bytes in
memory; wrong path, extra entry, different bytes and oversized content were
refused or distinguished in the focused fixture. This point read does not
bind the Docker daemon, running node, selected kubeconfig or TLS peer and is
not yet used for recovery. The earlier 67-test focused run passed against the
CA adapter; after adding the public refusal, the rebuilt executable and the
targeted public refusal test passed. HLint, documentation check and `git diff
--check` passed. Final binary SHA-256:
`56bb60f586e13c6be72d4be3f8592ad3de620dbab9e1afd77eee8e981f93f9db`.
No real CA read-back, family submission, interrupted cleanup or kind
acceptance was run.

Node CA binding observation (2026-11-23): under the recovered operation
lease, a new observation brackets the selected container's CA archive with
matching running-node observations, checks the recorded daemon against the
held Docker peer, and compares the complete selected kubeconfig before and
after. CA and credential bytes remain in memory. This is a point observation,
not proof that a TLS peer is the node: the readiness requests must still use
the same pinned kubeconfig and authenticate their TLS connection. It is not
yet used to authorize recovery or lift the public incomplete disposition.

The executable and integration suite built, and the targeted controlled
Docker-socket fixture passed a CA archive read on the exact requested path.
The fixture is not a real Docker or TLS qualification of the full binding
observation. HLint, documentation check and `git diff --check` passed. Binary
SHA-256:
`2229966da4a2c865e0b9c6506809482558986b62fa77b552a9f822938f2be6c4`;
integration binary SHA-256:
`f6e3654584bbc8e2fbbedd906b1a467d3a669afd946b91a37d63404394b17898`.
Pinned TLS composition, interrupted probe cleanup, public completion and
real kind acceptance remain open.

Pinned readiness composition (2026-11-23): family readiness now holds one
sealed kubeconfig snapshot and the validated projection from which it was
created. It compares that projection's CA with the selected running node
under the daemon and operation checks, before and after readiness, and invokes
`kubectl` with the same held snapshot. The result remains a point observation;
the public incomplete guard remains until the complete Docker/TLS composition
and its adverse controls are qualified against the real target.

The executable build, 67 focused tests, HLint, documentation check and `git
diff --check` passed. A disposable, non-secret snapshot fixture used the real
`kubectl config current-context` command and confirmed that both the bound
projection and sealed snapshot remained unchanged when the retained file was
replaced. It did not contact a Kubernetes API or validate TLS. Binary SHA-256:
`4f962b6ae093bc66d0eab239fdc3f90dad28d7d6f816e1897681f4a2fb8cf8fa`;
fixture source SHA-256:
`8d314f6e0c33c5d718689d5585fc9c60f60a514baf796bb0ce650523492cc395`.
Interrupted probe cleanup, family activation, recreation and real acceptance
remain open.

Readiness closing check (2026-11-23): after the final readiness request, the
family composition now repeats the bound node and CA observation before
returning. The synthetic dispatcher fixture refused completion when that
closing observation changed. The rebuilt executable, fixture, HLint,
documentation check and `git diff --check` passed. The preceding 67-test
focused suite exercised the snapshot composition before this closing-check
change; it was not rerun for this final change. Final binary SHA-256:
`258b1896090f7f9464ae39f544d30eb566526bf633dacfb2531daebff19f4ed3`;
dispatcher fixture source SHA-256:
`0bce2bdabf29af530d20cb594578e8bfdbb97551afcf7dbf23aa9f3939193bb6`.
The public completion guard, real TLS and kind qualification, interrupted
cleanup and family activation remain open.

Loopback TLS control (2026-11-23): the disposable
[TLS fixture](../test/qualification/KindKubeconfigTlsEndpoint.hs) generated
its own non-secret certificates, started an OpenSSL server on loopback, and
used the real `kubectl` with the sealed kubeconfig snapshot. The matching CA
was accepted; a different CA failed with the expected unknown-authority error;
restoring the matching CA succeeded. The fixture owns and removes its temporary
files and server. Its first invocation exposed two installed `network`
package versions; using the project environment without adding a second
`network` package resolved the ambiguity. This qualifies the client TLS
control only, not the Docker node-to-CA binding or a Kubernetes cluster.

The executable build, fixture, HLint, documentation check and `git diff
--check` passed. Binary SHA-256:
`258b1896090f7f9464ae39f544d30eb566526bf633dacfb2531daebff19f4ed3`;
fixture source SHA-256:
`085fff9da8e73ca14b154db1b029d564ccc6b6db407588755b70e7dc5ac0ad85`.
Public completion remains guarded; full node/daemon/TLS binding, interrupted
probe recovery, family activation and real kind acceptance remain open.

Controlled node CA binding (2026-11-23): the connected Docker fixture now
serves a synthetic running node and CA archive. With the recorded node intent,
create/start receipts and selected kubeconfig, the actual CA-binding observer
accepted the matching CA and refused a different selected CA. The fixture also
retained the existing node protocol checks. The first integration build found
a fixture bytestring type error; the corrected test passed. A subsequent
warning-only variable rename was rebuilt and the same test passed again.

The integration build, targeted scenario, HLint, documentation check and
`git diff --check` passed. Binary SHA-256:
`258b1896090f7f9464ae39f544d30eb566526bf633dacfb2531daebff19f4ed3`;
integration binary SHA-256:
`e4fa74206ef8c4560d8ede92eea286896d2fbebc10f035c3e7ecb38b91eca45d`.
This controlled socket does not qualify a real daemon, cluster, TLS chain or
interruption recovery. The public completion guard and Phase 1 remain open.

Interrupted probe cleanup protocol (2026-11-23): a staged cleanup protocol
now restricts the namespace to the operation-derived name, requires the
recorded UID to match a fresh observation, writes an exclusive UID-bound
removal-attempt record before delete, submits a UID precondition, and records
removal only after a positive-control-bracketed empty inventory. The journal
distinguishes a removal attempt from a completed receipt. A lost delete
reply, unavailable inventory, mismatched UID or changed admission remains
unconfirmed; an existing attempt is not retried by this protocol.

Controlled tests covered those refusals, the exact delete body, ordering and
the recorded-attempt state. The executable build, 68 focused tests, HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`e34437cf81384ff97c67b31d3e328708cab659ada5f1077038b8c3d29d2c282b`.
This protocol is not connected to a public command: the caller still needs an
authenticated API, the original family retirement, a managed cleanup worker
and that worker's settlement. No real namespace cleanup or kind acceptance
was run.

Cleanup worker boundary (2026-11-23): a staged recovery worker now requires a
distinct recovery execution key, the original family's retained retirement,
its operation lease and receipt, and a kubeconfig snapshot repeatedly bound to
the recorded node CA. The pre-delete attempt records both namespace UID and
recovery ID. Family deletion refuses to remove the node while the probe journal
lacks a removal receipt, including an empty journal; a positively evidenced
never-started path remains to be designed. The managed initial probe also
checks the node CA against its exact snapshot around probe actions.

The 68 focused tests passed for the worker-boundary and journal changes; they
do not establish real worker submission, API authentication or retirement.
The initial run exposed a missing test-helper import, which was corrected.
Before any cleanup worker can be submitted, its recovery identity and launch
coordinates must be durably published before send, and its own retirement
must be recovered after a possible send. The public family send remains blocked;
no real cleanup or kind acceptance was performed. The subsequent node-CA
probe connection builds, and the 68 focused tests, HLint, documentation
check and `git diff --check` passed again. Those tests do not exercise its
managed composition or real API path, which still require qualification.
Binary SHA-256:
`3ce7632e7fe1c8dbb174dcf131ba16866dcec4c6f3b5e3cf95127ab5c600be7d`.

Recovery launch locator (2026-11-23): a scope-bound exclusive record now
retains the cleanup family's separate recovery ID, exact namespace UID,
manager domain, executable digest and execution window before a future send.
The writer requires the family intent and matching probe intent and creation
record, with no removal attempt or receipt. The staged cleanup worker checks
the retained request, execution key and window and rechecks the locator around
effects. The locator alone is not evidence of submission or retirement.

The executable build, 69 focused tests and HLint passed. The tests exercise
canonical request decoding, scope and UID refusals, exclusive recording and a
corrupted locator; they do not exercise a real manager, worker or Kubernetes
API. Binary SHA-256:
`de5f1fa360f2135ba3bad1bf81c5c3ef81d646a7cda3182138d3c100fbc2fbaa`.
The sender, its exact publication and possible-send recovery, worker retirement,
and real kind acceptance remain open. Repeated CA and locator admission checks
also require a real bounded-time qualification before activation.

Cleanup family preparation and dispatch (2026-11-23): the cleanup request can
now prepare the bounded family with its distinct execution key and original
window. Pinned input decoding checks that key, the held executable digest and
the independently observed manager. The internal recovery composition joins
that input and managed parent to the staged cleanup worker and rechecks input
stability while holding the original family retirement owner. A returned
callback does not establish retirement of the cleanup family.

The executable build, 69 focused tests, HLint and two controlled qualification
fixtures passed. The preparation fixture checked the distinct key, foreign
scope and capacity refusal; the held-input fixture checked a matching request,
foreign key and manager refusals, and refusal of an unmanaged process before
the callback. The initial fixture command failed because the installed package
hides internal modules; the passing run used a temporary package database
exposing those already-built modules, without changing the repository package.
Fixture SHA-256 values: preparation
`6187e3277794fbb0c3261536beb15026d3fea7b9cf1a08fb1112f519de45a103`;
held input `54fe746c5b97c5a28907dc410112030923fb390a295568c38707cc6671f4de22`.
Binary SHA-256:
`4772a5f8b329c7ba08b82166c3b98e98c42a95c9b9880295acdf186ee00c569b`.
No unit or cluster was started by these fixtures. The internal composition is
not connected to a sender or public route; publication, possible-send recovery,
cleanup-family settlement, and real acceptance remain open.

Staged cleanup publication (2026-11-23): the cleanup sender now borrows the
original family's retirement owner and operation lease, records the matching
cleanup locator, and uses the existing publication owner and bounded manager
submission boundary. Admission rechecks the original retirement, locator and
unresolved exact probe UID. The cleanup dispatcher waits for lease handoff
while its input and process parent remain stable. The sender preserves a
possible-send outcome; it does not establish cleanup-family settlement.

The held-input fixture refused a cleanup launch when original-family
submission/retirement was unobservable and verified that no cleanup locator
was written. It also rechecked the existing guarded original launch. This is a
negative control only: the positive retirement-to-publication path, cleanup
worker dispatch, lost replies, post-send recovery and input retirement have not
been exercised. Deletion now refuses node removal whenever a cleanup locator
exists or is unobservable, even with a removal receipt, until independent
cleanup-family settlement is implemented. A crash after writing the locator
but before publication also needs an evidenced never-sent recovery path.
The kind family send guard remains active; no unit or cluster was started.
The executable build, 69 focused tests, held-input fixture and HLint passed.
Binary SHA-256:
`0f7d1aa5210c791a2ddafd77973c7d5075f7fcabc17aa592cb540a1169f08659`;
held-input fixture SHA-256:
`239e368054550435e66f16137a86b19021895264c2ec56deac0af61e2e19da75`.

Cleanup-family retirement (2026-11-23): a separate borrowed retirement owner
now matches the recovery locator to the cleanup family's submission key,
window, manager and provider record. It rechecks provenance and physical
retirement and retires only that family's exact published inputs. The family
delete path now requires matching namespace UID and recovery-attempt ID, then
holds and rechecks both retirement owners around resource effects. A missing
locator is accepted only for an original probe with no recovery attempt.

The controlled held-input fixture refused missing locator or submission, a
live sender and a changed locator; it exercised exact input retirement with
synthetic registration and verified an escaped retirement owner was closed.
The first fixture compile exposed ambiguous test callback types; those were
corrected before the passing run. This fixture starts no unit and cannot prove
actual submission, worker processing or physical retirement after real work.
The connected delete path, interrupted cleanup, never-sent recovery, real
kind acceptance and required mutations remain open. The executable build,
69 focused tests, HLint, documentation check and `git diff --check` passed;
the focused tests include mismatched UID and recovery-ID controls but do not
exercise the connected delete path. Binary SHA-256:
`a1a7866023fe5a3a1b60e2e54b9506324347b84e1865a588d89e307338a57d88`;
held-input fixture SHA-256:
`55cfb762172ba3902ba61199436b6fbbbbcf1492106fb0b7f88ef55853bc76e1`.

Cleanup controller entry (2026-11-23): the existing internal family command
now routes a distinct recovery key to the cleanup dispatcher. A successful
worker return requires complete parent and original-family closing outcomes;
it still does not prove retirement of the cleanup family. Pinned request
decoding independently checks the key, manager, executable and window.

The executable build, 69 focused tests, held-input fixture, HLint,
documentation check and `git diff --check` passed. The fixture tested
node/recovery key selection, complete versus unconfirmed outcome projection,
and the actual binary's refusal of a recovery request bound to a different
executable. It started no unit or cluster. The send guard remains in place;
no real cleanup, submission recovery, deletion or kind acceptance is claimed.
Binary SHA-256:
`0ab0e08b6a6b6fc830adee3e09f363b1cc35a045231fa2b54822303edf8c3d30`;
fixture SHA-256:
`2a6562230c8a8361e581b193056d7db4eb80ba6a9dadc88084fab2f4b94e56bc`.

Never-sent cleanup publication (2026-11-23): a recovery composition now
borrows the original family's retirement and operation lease before recovering
the cleanup publication's durable never-sent proof and retiring its exact
inputs. Missing publication is an error, not evidence of no send. The
cleanup locator remains retained; the outcome does not authorize a replacement
worker. Original-family completion also refuses a cleanup locator, preventing a
potentially separate worker from being ignored.

The controlled held-input fixture refused a missing publication, retired and
resumed a synthetic never-sent publication, and refused original completion
while the cleanup locator existed. It reset that synthetic locator only to
exercise its separate original-only positive control. No unit or cluster was
started. The executable build, 69 focused tests, fixture, HLint, documentation
check and `git diff --check` passed. The path is not yet
connected to a public recovery command, and crash-before-publication disposition,
replacement worker identity, actual submission and interruption recovery remain
open. Binary SHA-256:
`7508d2691a3914894c0d3f5f20eaeac6d68078f453b43631b05ba73a804d8a9b`;
fixture SHA-256:
`b2c94a345d776a4a9e83ad0707e049c875aa4603c83edbaee1b2ed01c095e345`.

Never-sent recovery entry (2026-11-23): incomplete family `control reconcile`
now invokes the bounded never-sent cleanup publication recovery and preserves
its outcome in the incomplete response. Family delete also tries that recovery
for a recorded cleanup launch with no removal attempt, then stops with the
namespace cleanup unconfirmed; it does not remove the node or discard the
locator. Neither path infers no send from a missing publication.

The controlled fixture exercised the actual reconcile binary against synthetic
retained records and checked its incomplete never-sent result. It also invoked
the delete composition against those records and checked that it stopped
incomplete. No unit or cluster was started. The executable build, 69 focused
tests, fixture, HLint, documentation check and `git diff --check` passed.
Crash-before-publication disposition, replacement worker identity,
actual submission, real delete and kind acceptance remain open. Binary SHA-256:
`2f3f4c40fb4022669294850d5f4d4d5cd2131e877ece6850f2dba5717ab04da7`;
fixture SHA-256:
`c6e2d68f8ebf0d0e3b929a6a341e87577a6d2e583202a1fb7ba64292e1c3d4ba`.

Cleanup publication barrier (2026-11-23): new cleanup locators declare a
versioned protocol requiring an exclusive, request-bound publication-attempt
record before publication. With the original family retirement and operation
lease held, recovery distinguishes an observably absent marker from an
attempted publication. Once the marker exists, missing publication remains
unconfirmed and only the publisher's own never-sent proof can retire inputs.
An orphan or unobservable marker also prevents original completion and node
removal. Earlier staged locator records lack this declaration and are refused;
they are not retroactively treated as pre-publication evidence.

The controlled fixture exercised the pre-marker state, a marker followed by
missing publication, and retirement of a synthetic never-sent publication.
It started no unit or cluster. The executable build, 69 focused tests, fixture,
HLint, documentation check and `git diff --check` passed.
This does not yet authorize replacement attempts or qualify real interruption,
submission, deletion or kind acceptance. Binary SHA-256:
`a663910a21ef01ef88ec3ae1843fa204398d3a2d30f1d86355fc516142cb66c5`;
fixture SHA-256:
`0130db5db510b43820b0e8258001c5a66e8dd031d795b27304eb921990dff25e`.

Connected delete control (2026-11-23): the held-input fixture now constructs
separate synthetic original and cleanup submission records and exercises the
connected delete composition. It refused a foreign cleanup-attempt ID, a
missing cleanup submission and a live cleanup sender. After both synthetic
families were observed retired, it retired the cleanup inputs and advanced
through the fixture's never-planned node and volume cases, then stopped at the
missing network identity. The actual `control delete --yes` binary repeated
that incomplete result through its admission path. The fixture resets isolated
synthetic records between controls; no worker, node or network was started or
removed.

The fixture and HLint passed. This establishes the controlled composition,
not actual worker execution, provider retirement, independent namespace
absence or real delete acceptance. Binary SHA-256:
`a663910a21ef01ef88ec3ae1843fa204398d3a2d30f1d86355fc516142cb66c5`;
fixture SHA-256:
`a63cbe9ad1dd161b617b05418a12c7f933d8cbefcbe369018f27e2b6137cc537`.

Cleanup publication status (2026-11-23): `control status` now distinguishes
no local cleanup records, a locator without an attempt, a matching publication
attempt and conflicting or unobservable records. It explicitly leaves send,
worker settlement and namespace state unestablished. Classification controls
include foreign requests and orphan markers. The controlled fixture checked
the actual status binary against a synthetic recorded attempt; no unit or
cluster was started. The executable build, 69 focused tests, fixture, HLint,
documentation check and `git diff --check` passed. Binary
SHA-256:
`4672339493b07f4bb4b292864b0848a4cdb134c43d419607e8c622232f26b5b8`;
fixture SHA-256:
`16d44dd88a88040ed42fa14d264993f7e0828a541ec6353d8e252d2f027343cf`.
Replacement attempts and real interruption and lifecycle acceptance remain
open.

Orphan marker control (2026-11-23): the controlled held-input fixture now
removes a synthetic cleanup locator while retaining its publication-attempt
record. Both family completion and the connected delete composition refused
to proceed. It then reset the isolated synthetic marker to exercise the
separate original-only control. The fixture and HLint passed; no worker,
node or network was started or removed. This is not real interruption or
kind acceptance. Binary SHA-256:
`4672339493b07f4bb4b292864b0848a4cdb134c43d419607e8c622232f26b5b8`;
fixture SHA-256:
`403de65e091cdd94a529e7b1568b8125a9a0d677083c1666626f8622e1867996`.

Original-family never-sent inputs (2026-11-23): incomplete family reconcile
and delete can now recover the original publisher's durable never-sent proof
and retire its exact inputs under the retained operation lease. The family
request and absence of legacy submission are rechecked; missing metadata is
not treated as no send. Both public paths remain incomplete and retain the
operation and dependent resources. The proof does not establish node or
resource absence and does not yet permit a new family attempt.

The controlled fixture checked missing-request refusal, repeat retirement of
the guarded never-sent launch, refusal while a publication was held, and the
actual `control delete --yes` incomplete report. No unit or cluster was
started. The executable build, 69 focused tests, fixture and HLint passed.
Real submission, successor identity, resource cleanup and kind acceptance
remain open. Binary SHA-256:
`72b17d6d861db1a574b96f26c6b16c9f91efa2558ae1d2369902ecd575b06b34`;
fixture SHA-256:
`4ec04d49df112ab134e8adfc8b1044fcb42a2ca256395abdcaaac8138dd0c027`.

Original-family publication barrier (2026-11-23): new family launch locators
declare a request-bound publication protocol, and an exclusive attempt record
is written before publication. Under the operation lease, recovery distinguishes
the absence of that record from a missing publication after an attempt. The
worker and retirement observer require the matching record. Earlier staged
family locators without the declaration are refused rather than treated as
proof of a pre-publication state; legacy controller recovery is separate.

The executable build, 69 focused tests, controlled fixture, HLint,
documentation check and `git diff --check` passed. The fixture covered
pre-publication, missing attempted publication, held publisher and the
guarded never-sent path. It started no unit or cluster. This does not authorize
a successor or establish node and resource absence; real submission, cleanup
and kind acceptance remain open. Binary SHA-256:
`e6748084e8ae61dd8aad88661b42252a442bf20fcba2c5808020bf24fa8f3db0`;
fixture SHA-256:
`92d8eae38d60639de62d7ec1f0997d0766e58e3493d8fb984a6d750ca64d658d`.

Pre-publication family resume (2026-11-23): the staged launcher can resume an
exact retained request only while its operation lease is held, the original
manager and work window remain valid, and the publication-attempt record is
absent. A different retained request and a repeat after the marker are refused.
The controlled fixture exercised those cases up to the existing guarded send;
no unit or cluster was started. This resume is not yet connected to public
reconcile and does not cover an expired window or a possible send. The build,
69 focused tests, fixture, HLint, documentation check and `git diff --check`
passed. Binary SHA-256 remains
`e6748084e8ae61dd8aad88661b42252a442bf20fcba2c5808020bf24fa8f3db0`;
fixture SHA-256:
`ceadb5abfeb5a5370e5a0cff65836ed10091df784dd9dbd856e8c2fcfc13a5a9`.

Never-sent family cleanup owner (2026-11-23): family delete can now borrow the
original publisher's durable never-sent proof across recorded prerequisite
cleanup. It requires an empty probe journal and no cleanup publication records,
retires exact publication inputs, and rechecks the borrowed proof and operation
lease at effect boundaries. The primary resource results and a failed closing
observation remain separate. This does not establish independent resource
absence or authorize a successor family.

The controlled fixture checked a live publisher refusal, lease rechecks, a
closed escaped owner, an uncertain-probe refusal, and the public delete path
through synthetic never-planned node and volume cases to an incomplete network
result. It started no unit or cluster and removed no real resources. The build,
69 focused tests, fixture and HLint passed. Real prerequisite cleanup, worker
submission and kind acceptance remain open. Binary SHA-256:
`bc6752787b4c263115c6d9b74208f586c25dd51d0ca21da72ddf2ef97555760d`;
fixture SHA-256:
`592ff3bddfe3575ba7c5269ad77e28c3fde669f24ab3778157896d6d58ed590d`.

Pre-publication cancellation (2026-11-23): family delete now records a
request-bound exclusive cancellation before using pre-publication evidence for
prerequisite cleanup. Publication and cancellation records exclude each other
under the operation lease; the launcher, worker and submitted-family observer
refuse contradictory state. Delete rechecks cancellation and the empty probe
state, and retains incomplete resource and closing outcomes separately.

The controlled fixture exercised the actual public delete against synthetic
pre-publication records, observed the incomplete network result, and confirmed
that a later launch and publication marker were refused. It also refused
cancellation after an attempted publication. No unit or cluster was started,
and no real resource was removed. The executable build, 69 focused tests,
fixture, HLint, documentation check and `git diff --check` passed. Real
prerequisite cleanup, family submission, interruption and kind
acceptance remain open. Binary SHA-256:
`6f81d006b105cb07105b1eeba2ef3d3fbd3c4f948d49246e73ad445d9587e1f1`;
fixture SHA-256:
`830d03017d2d3d4cb5f6d9d5077a628474b66c5087c093a98cdc3fef893eb95d`.

Original-family cancellation status (2026-11-23): `control status` now
classifies a matching pre-publication cancellation separately from a launch
without an attempt and a recorded publication attempt. Orphaned, conflicting
or unobservable records remain unconfirmed; status does not infer send,
retirement or resource absence. The controlled fixture checks conflicting
records and the actual status binary after synthetic cancellation. No unit or
cluster was started. The executable build, 69 focused tests, fixture, HLint,
documentation check and `git diff --check` passed. Binary SHA-256:
`eea0060afc88a8085e6ea67ed688781b3cb0ae11557cbd5cc607e177b451499e`;
fixture SHA-256:
`b8508bef5362aacdd880981b9afbaeb172267b1b4d853487834543f391c8145e`.
Real cleanup, family submission and kind acceptance remain open.

Settled cleanup delete failure (2026-11-23): when the managed delete command
returns a nonzero exit with subprocess settlement confirmed, recovery records
that exit against the exact namespace UID and recovery ID before independently
checking namespace absence. A positive-control-bracketed empty inventory can
then produce a removal receipt without erasing the primary failure. Transport
or subprocess-settlement failures remain unconfirmed. The journal distinguishes
the failure with and without a removal receipt; deletion still requires the
matching cleanup family retirement and input retirement.

The controlled protocol tests cover ordering, failed failure-record writes,
unavailable inventory and a settled nonzero exit with independent absence.
The controlled delete fixture uses synthetic records to exercise the
failure-plus-receipt branch. These checks do not establish a real Kubernetes
outcome or recover an unobservable subprocess. The executable build, fixture,
69 focused tests, HLint, documentation check and `git diff --check` passed;
no real resource was removed. Binary SHA-256:
`96a152ea537503c15373dc0361662cd236e275a0b6640c66b9fb62c9e928997d`;
fixture SHA-256:
`3c2819843e70b856afc31bd20d9fab5654388770b15d682e70ab4eac715ed532`.

Unconfirmed-attempt readback protocol (2026-11-23): a staged read-only
protocol brackets an empty namespace inventory with a stable positive control
and records the original recovery ID and a distinct verifier ID without
issuing another delete. The journal keeps the original attempt unconfirmed and
reports the separate readback; deletion does not accept that record as a
settled verifier. The protocol requires its caller to hold both prior family
retirement owners, the operation lease and an authenticated API snapshot.

Controlled tests cover invalid identity, unavailable inventory, record refusal,
changed identity and a read-only successful observation. The executable build,
70 focused tests, fixture, HLint, documentation check and `git diff --check`
passed. The verifier's durable launch, managed execution,
independent retirement, public activation and real Kubernetes behavior remain
open; this record alone is not cleanup or kind acceptance. Binary SHA-256:
`b5bfaf127f47d5cd9444142235ded5363f75293a34e1944d7b347752bea9a6c8`.

Unconfirmed-attempt verifier locator (2026-11-23): a canonical verifier
request now binds a distinct verifier identity and its own manager, executable
and window to the original cleanup ID and namespace UID. Exclusive verifier
launch and publication-attempt records require the matching prior request and
uncertain attempt. The readback record requires those verifier records; the
journal treats orphaned or conflicting records as unconfirmed. These records
are provenance only and do not establish prior or verifier retirement.

The controlled tests exercise identity binding, record order, pending and
recorded readback, and orphan refusal. The executable build, 71 focused tests,
controlled fixture, HLint, documentation check and `git diff --check` passed.
Managed verifier launch, both predecessor retirement
owners, verifier retirement, public activation and real Kubernetes acceptance
remain open. No unit or cluster was started. Binary SHA-256:
`bf560c393155704f77168fc40ecd6b73f7457a210a4a7200568b23daaebb9b68`.

Verifier managed boundary (2026-11-23): verifier preparation now binds the
distinct execution key, scope and original verifier window to the bounded
family envelope. Pinned input decoding checks the key, manager, executable
and request kind. A staged read-only worker boundary borrows both predecessor
retirement owners and the operation lease, binds the API snapshot to the
recorded node CA, and rechecks its verifier records around reads. Its return
does not establish retirement of the verifier family.

The controlled preparation and held-input fixtures test key, scope, capacity,
manager, request-kind and unmanaged-parent refusals. The executable build,
71 focused tests, both fixtures and HLint passed. The actual two-owner
worker composition, verifier publication and settlement, public activation,
and real Kubernetes behavior remain unqualified. No unit or cluster was
started. Binary SHA-256:
`48c3398bbb14d5d39d8afbd6c0d777a0ef1571684185abe7789c85eac628c757`;
preparation fixture SHA-256:
`12a6a731b07f75b095da2b61017ab3b1441e1b8d3f4e210c93c55a00c085034a`;
held-input fixture SHA-256:
`e5d98fa973206c0e5aa1e7294fd63be6b0d3fc53e18a1c73a2589defcf5b5572`.

Verifier staged publication and dispatch (2026-11-23): the publisher now
holds and rechecks both predecessor retirement owners while recording the
verifier locator and publication attempt and submitting the bound request.
The internal family dispatcher distinguishes cleanup and verifier requests
from canonical pinned bytes, then reacquires both owners for verifier work.
A returned verifier callback does not establish verifier-family retirement.
The family submission guard remains in place: interruption recovery for its
publication, verifier retirement, public activation and real kind acceptance
remain open.

The executable build, HLint and isolated preparation and held-input fixtures
passed. The held-input fixture also checked selection of both request kinds,
public refusal of a foreign executable, and refusal to launch a verifier while
the cleanup sender remained live. These are controlled observations, not a
real managed verifier or Kubernetes acceptance. Binary SHA-256:
`fa94e1b50fda786c5f995375f513aa937d3e5d48e85a15fc024c9b5808f1b2a2`;
held-input fixture SHA-256:
`0412ba0237522231dab8fbbeccd8edb7dba0eb08bf6e0b05b2db4f36d603780a`.

Verifier retirement boundary (2026-11-23): a separate owner now matches the
verifier locator, publication marker and submission identity before borrowing
physical retirement, and can retire the exact published inputs under that
owner. The isolated held-input fixture confirms a missing verifier locator is
refused. It does not yet exercise a registered verifier through this boundary,
and delete does not consume it; interruption recovery, integrated settlement,
real managed execution and Phase 1 acceptance remain open. The rebuilt
executable and HLint passed, as did the updated held-input fixture. Binary
SHA-256: `a0c198993f716ce17891c566a318c5a3a19ebd9a0e66ac5a935ada360a9ec54e`;
held-input fixture SHA-256:
`cfef5e3be4c35043681baaed1799b204d41035b013bfba7685a65917dd50d0df`.

The expanded synthetic registration fixture then passed: a live verifier
sender was refused, and after that sender closed the exact verifier owner
verified retirement and retired its published inputs. Its first run failed
with `ControllerPublicationExists` because the fixture reused another
synthetic recovery key; the rerun used a distinct key. This does not prove a
real verifier launch or integrated delete. Updated fixture SHA-256:
`808d195d269ea2d77fa6b9fa80f6d751946c62a9978a53d0df514e42e8b67dce`.

Delete settlement after verifier readback (2026-11-23): delete now borrows
the original, cleanup and verifier retirement owners, retires the latter two
published inputs, and rechecks all three owners and the exact readback journal
before each removal. The controlled fixture refused both an unregistered
verifier and a live verifier sender, then advanced after synthetic settlement;
its independent network observation remained incomplete. The executable build,
HLint and fixture passed. Binary SHA-256:
`a022e4d0aa99a0075a990e852b0583be5a38fb9726585cab1a2a348e44ab5a21`;
fixture SHA-256:
`8c5726cf2edc8f716d32fa71d0bbb0d40d84cd450a5249427fc49a3b7e5ed342`.
This is not real managed execution, interrupted-publication recovery or Phase
1 acceptance; the send guard remains in place.

Verifier never-sent observation (2026-11-23): while holding both predecessor
retirement owners, the recovery boundary distinguishes a retained verifier
locator before publication from an attempted publication whose durable send
latch can be inspected for exact input retirement. The former passed in the
controlled fixture; the attempted-publication branch and a safe replacement
protocol remain unproven. Neither outcome independently authorizes another
verifier. Build, HLint and the held-input fixture passed. Binary SHA-256:
`9d232c4f07c65a0d1901f7b804906b2e756ddc9dd226d7274bdcb91169087389`;
fixture SHA-256:
`23c31b77a63ea0cf74b20f333e86eef15bce284ca2aac196e39e93bedb23ae48`.
The expanded fixture also passed the missing-publication refusal after the
attempt marker; it did not infer never-sent from a missing publication.
Fixture SHA-256:
`ded732985e436eeb02d4dab459de39f723d71c94f6463395a7e2d5565835e320`.
Public `control reconcile` now reports this bounded verifier recovery
disposition when its retained journal is pending; it still reports the
operation incomplete. The controlled fixture exercised that public command
for the pre-publication state. Build, HLint and fixture passed. Binary SHA-256:
`c357ee7c84db9041c0f6a9db910400fe31590ac42f74ddcc587f1ebf2d46efd8`;
fixture SHA-256:
`b8e5d8530d38983e32207319ea467ce1b83e82d04c175ec62998ef366db45a87`.
An additional isolated journal with a distinct verifier key exercised the
durably never-sent publication and exact input retirement successfully. This
fixture changes only its own synthetic records and is not a replacement or
real manager send. Fixture SHA-256:
`3edd27313744379a31d7d4967843f668b95f32db18020b930abfd01d878f4fd4`.
The same controlled retirement was then repeated successfully to check
resumption. Updated fixture SHA-256:
`2c7096c9120a29047c143465923126d457776808d7dce105afae7b01a3f9dbee`.
The fixture also verified that verifier never-sent recovery refuses while the
cleanup sender remains live. Updated fixture SHA-256:
`dbab02fe09950396f48fc713dd04db6e3c1c5e9030c5646f7c3bde286b063387`.

Verifier pre-publication resume (2026-11-23): the staged verifier launcher
can now resume the exact retained request while its original execution window
is valid, both predecessor retirement owners are held and the publication
marker is absent. A changed request or an existing publication attempt is
refused. The controlled fixture exercised all three cases; the send remained
guarded and its never-sent inputs were retired. The executable build, HLint
and fixture passed. This staged launcher is not called by the public reconcile
path, so it does not resolve an expired request, authorize a replacement or
qualify real execution. Binary SHA-256:
`c357ee7c84db9041c0f6a9db910400fe31590ac42f74ddcc587f1ebf2d46efd8`;
fixture SHA-256:
`1c1b39c4dd46cbe1cabe44c98800dc8b928af7210e3ac3ba94043d688cb151b9`.
The cleanup launcher now likewise resumes only its exact retained request
before publication while the original family remains retired. The controlled
fixture passed changed-request, resume and post-attempt refusal checks for
both launchers. Build and HLint passed; the staged launchers remain outside
the public reconcile path and the family-send guard remains in place. Binary
SHA-256: `c357ee7c84db9041c0f6a9db910400fe31590ac42f74ddcc587f1ebf2d46efd8`;
fixture SHA-256:
`5fbe874a8be021674b9084bf1a2559ad95e46903bf05b642f81fd91107fe9157`.

Rejected unlaunched-family cancellation (2026-11-23): a trial allowed public
test-identity delete to create and cancel a missing launch locator. The build,
HLint and controlled fixture passed, but review found that cancellation only
fenced the launcher: a prerequisite creator could still run between its own
lease acquisitions. The trial was removed. This controlled pass does not
establish worker settlement or authorize cleanup. The prerequisite creator
must be fenced and settled before an unlaunched family can be cleaned up.
Trial binary SHA-256:
`dfb9e4fde778e6fc2a530a2cc48d7084ebe19e227c2f7c4b04dcfca0f487f987`;
fixture SHA-256:
`08b82df84e344f063fd038e12093c68e3b7ce59f583834b90d1443c008fa42f2`.
After removal, a public-command regression fixture passed: delete refused the
missing locator and did not manufacture one. The build and `git diff --check`
passed. Binary SHA-256:
`71573c20731578c5c2bf46bb789ffe808fc461fac736ef333bcc25214b2121a6`;
fixture SHA-256:
`70a45880e8ef9167bc49122380ae8c11d121bb236119ba767e7f975de92e58ca`.

Managed prerequisite composition (2026-11-23): the staged kind family worker
now prepares the image, network, volume and node intent before starting kind.
The recovered image path requires the family protocol and borrowed admission;
network and volume creation recheck that admission with the operation lease
and Docker peer around their attempts and effects. Lost admission refuses
before image intent, network or volume attempt, and the controlled Docker
fixture observed no create request. The guarded network fixture also passed
its successful and lost-reply cases. The executable and integration suite
built; 71 focused preparation tests, the pinned-input fixture, HLint and
`git diff --check` passed. These controlled checks do not prove real managed
execution, interruption settlement, partial-resource cleanup or the public
cutover. The family-send guard remains in place and Phase 1 remains open.
Binary SHA-256:
`ac3c4ee58e15460484222c84393ac0a47d3dc55d8c0b046bc92f7121fad7b41c`;
integration binary SHA-256:
`360791addefdc2cc979658b494f92bd325cedd999baf0e8c4f4102c6088004af`;
integration fixture SHA-256:
`739b459a6bdc53f4cd88f2381bbf0ea40ae33df0c23b39c9a4fe3aea96671f71`;
pinned-input fixture SHA-256:
`4892d8c27583e749e20faa3dd94c10c254475176e50a45fbfc77e60834d6eb69`.
The expanded OCI fixture also passed a recovered family image attempt using
a staged archive, connected fake daemon, recorded load response and read-back.
This is controlled adapter evidence, not a managed systemd family or real
daemon proof. Updated integration binary SHA-256:
`0d786d3ab0ba66bfc08ece9c7f711f440a56745d75f875ae77194ef40a082885`;
integration fixture SHA-256:
`3f95e6b65208d8230a5731ca094a10743499c9f00dda0bcefd0134d4eb4d6c29`.

Owner-first family protocol (2026-11-23): the initial intent now distinguishes
`family-v2`, whose prerequisite effects belong to its submitted family, from
the older `family-v1` protocol, which did not establish that ownership. Both
remain readable as family records; the managed worker retains the older path
for v1 and rechecks the exact protocol throughout v2 work. This decision
follows the write-before-effect and no-inferred-absence requirements in
[plan standards](development_plan_standards.md#resource-and-credential-lifecycle)
and preserves the older intent's meaning. The staged preparation creates a v2
intent before any image, network, volume or node intent.

For v2 only, delete can fence a missing launch locator by recording a matching
locator and cancellation under the operation lease. Older v1 missing-locator
state remains refused. After a physically settled v2 family, an empty probe
journal can admit recorded prerequisite cleanup while the exact protocol and
retirement owner remain stable; this is not a claim of resource absence.
Controlled tests refused a live sender, verified the cancellation fences a
later launch, rejected a changed protocol and stopped at unconfirmed network
read-back. No real family or partial-resource cleanup was exercised. The
build, HLint, 73 focused tests and the controlled qualification fixture
passed. One intermediate unit run failed to compile because it imported a
hidden module; that control was moved to the qualification fixture and the
unit suite passed afterward. Binary SHA-256:
`e406c64f78534407d66522fd57eed75e39d9bfe7bce6def4eba5f35e6ec9dcfc`;
unit source SHA-256:
`c2b2f89b2d22653c23b3527df183bb9c62353aabf4a9945001a924f2eb4c5e84`;
qualification fixture SHA-256:
`ac327223097e81a584d03038c2162585e87a9b2e78472bfb29e9ac2f91f319fe`.
The v2 preparation remains staged; public launch and the family-send guard,
interrupted execution recovery, real acceptance and source mutations remain
open.

Fresh public family routing (2026-11-23): `control reconcile` now prepares an
owner-first operation and invokes its family launcher, rather than creating
image, network and volume prerequisites in the CLI process. A bootstrap that
cannot be rendered and decoded as the controller's complete projection is
refused before the operation intent. A controlled public-command test against
a disposable fake Docker endpoint passed: it observed the v2 intent, the
guarded never-sent disposition and no Docker create or delete request. The
first test fixture omitted the required kind-tool declaration and exposed the
preflight gap; its initial run stopped at configuration refusal. A subsequent
fixture compile found a `Text` type mismatch, corrected before the passing
run. The executable and integration suite built, HLint and 73 focused tests
passed, and the controlled controller-input fixture passed. Family submission,
the kind node, worker settlement and real acceptance remain unqualified.
Binary SHA-256:
`5023c7aaf0aa228e535840103bc2dcd141617978e87866536fa6022a7fdc465c`;
integration fixture SHA-256:
`580fa2ee180318810296564cd0d403eed6fcefbe5be7d723b9cfde32b0501c08`;
controller-input fixture SHA-256:
`ac327223097e81a584d03038c2162585e87a9b2e78472bfb29e9ac2f91f319fe`.

Controlled-run residue observation (2026-11-23): at 15:54:11 UTC a read-only
count found 361 `prodbox-kind-family-inputs-*` directories directly under the
current user's runtime directory, compared with 358 in a preceding count.
The count does not establish ownership or classify any individual directory.
Controlled fixtures use this namespace and retain publication metadata after
never-sent payload retirement; the public-route fixture did not preserve its
generated operation ID after its temporary scope was removed. No unclassified
directory was removed. Exact fixture-publication accounting and a safe scoped
retirement/cleanup path remain open; these controlled runs do not qualify the
phase's cleanup requirement.

Controlled public-route fixture teardown (2026-11-23): the fixture now claims
its empty private root and snapshots existing kind-publication names before
running the public command. After the command reports a never-sent retirement,
teardown requires the same test scope and owner-first operation, matching
launch and publication records, a durable never-sent proof, terminal input
retirement, exactly the expected regular metadata files and an unchanged
captured tree. It refuses another operation, another fixture root and an
unexpected entry. A failed test retains its fixture root and reports its path.
The controlled public-command case passed and its exact publication tree was
removed; the read-only runtime-directory count was 361 both before and after.
That count is not ownership proof for the earlier entries, which remain
unclassified and untouched. Build, HLint, `git diff --check` and 73 focused
tests passed. Binary SHA-256:
`e61ed88af483de1d083048b63ca10614f8b366672e34bc1a8541bacff09c05c4`;
integration binary SHA-256:
`cd02269fe474914f14bd6936d63b3544267395b04a71b3fd0bc6a7e3e882bb62`;
integration fixture SHA-256:
`54a7d7d96a6b8ff0345365541584c7b63c78c38fc7cb1bd5cb1ce7d056c09f13`;
fixture teardown source SHA-256:
`ffabda1834742ec93f39b6595bf86c64de0f28088b0b55d1761318896b4b9d61`.
The fixture claim was then tightened to hold and recheck the runtime
directory while taking its pre-command inventory. The captured publication
tree is now also rechecked while the never-sent owner is held before teardown.
The public-route fixture, including foreign-root and unexpected-entry
refusals, passed again; the runtime-directory count remained 361 before and
after. Build, HLint and `git diff --check` passed. Binary SHA-256:
`68ed93967e4c6b4e0f541a0eab6fca6228ef8df64d8cd6ea418b3a687be9dfdd`;
integration binary SHA-256:
`a3f71891be692ca21884767b8dc466015d18c67d2b8623e84f2e4d28c9ba0d42`;
fixture teardown source SHA-256:
`0ef500e0cf314d94bf4c512c165fbdc9a42dddbb6648c1fc44ae54db7343b063`.
The teardown now stops before retirement recovery if its exact fixture-tree
snapshot is unavailable. The controlled public-route fixture passed again,
including its adverse controls, and the runtime count remained 361 before and
after. Build, HLint and `git diff --check` passed. Binary SHA-256:
`a3377234cc80a2d15c0b4237255a812b23add1f17af3df526b270bae6523f67e`;
integration binary SHA-256:
`0f48ce3ad553c97b1065978b8f60c1be2d4d12084ce88efc39e4f7e5759a6b56`;
fixture teardown source SHA-256:
`e0679ab470b02351ce0793d73e021a49606a106dd97525f8351c713efa63b7dc`.

## Resource scope and cleanup

Two real disposable kind environments, owned host volumes, ports/networks and marker Pods. Cleanup uses exact identities; preserve original host markers through node recreation, then remove only the run-owned disposable scope. Mutation children lack production roots, provider credentials, current kubeconfig and unrestricted runtime/publication access.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/configuration.md](../documents/engineering/configuration.md)
- [documents/engineering/resource_governance.md](../documents/engineering/resource_governance.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [x] All implementation tasks and owned acceptance cases passed.
- [x] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values for the current implementation.
- [x] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [x] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope. The earlier failed-run hand actions and independent read-backs are recorded above.
- [x] Owned legacy removals and documentation/generated-reference updates are complete.
- [x] Canonical gate and cumulative relevant regressions pass for the current implementation; no hand action is used as qualifying evidence.

Closure requires real kind/control/context behavior and all owned evidence and mutation cases. Cloud admission is impossible; storage retention and actual management isolation/capacity must be proven before secret workers are introduced.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
