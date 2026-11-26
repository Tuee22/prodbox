# Phase 03: Retained Authority and Shared Local Lifecycle

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: One retained Authority drives public status/plan/delete/resume. A never-admitted deployment deletes as a truthful no-op while management survives, and missing existing history cannot be relabeled fresh.

**Phase**: 3
**State**: Active
**Prerequisites**: Phases 1–2 complete. No AWS account/domain, remote backup bucket, EKS or future cloud adapter is required.
**Acceptance**: A03-01, A03-02, A03-03, A03-04, A03-05, A03-06 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M04, M05 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L08, L09 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B018, B022, B029, B042, B049, B050, B051, B057, B058, B059, B060, B066, B074, B077 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: A03-01 and A03-02 are qualified. Dated implementation and validation records below identify the operator builds, real observations, and cleanup. Native Authority operation recovery, audited ambiguous-init recovery, owned removals, and the current cumulative gate remain open.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

One retained Authority drives public status/plan/delete/resume. A never-admitted deployment deletes as a truthful no-op while management survives, and missing existing history cannot be relabeled fresh.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Design resolutions already settled by the documents

Do not stop to ask about these; build to them and record any residual choice as a dated note.

- **Sealed-Vault read (A03-02).** The same Authority serves a narrow, non-secret journal read from its mounted journal, available before Vault unlock, authenticated by the local/control identity independently of Vault Kubernetes login or Transit signing, bound to the selected kind/deployment, granting no cloud mutation or secret read, and refused for a foreign caller ([lifecycle.md](../documents/engineering/lifecycle.md) "Identity, intent and observations"; [control_plane.md](../documents/engineering/control_plane.md) dependency graph; [storage.md](../documents/engineering/storage.md) "Journal, checkpoints and backups"). A locally readable projection is diagnostic only and can never establish NeverAdmitted. A file projection, a Broker route and a separate pre-Vault store credential are therefore not the design.
- **The journal** is the Authority's durable operation log: an armed intent registered before any external effect, then one terminal result (`OperationRecord`, `Lifecycle/Authority/Operation.hs`). It is mounted retained storage under the retained root, not the Vault-keyed object store. `Control/JournalStore.hs` is a test double for the verdict rule, not the Authority's journal. Pulumi state is resume material only, and the Dhall specification is desired state; neither can license NeverAdmitted ([lifecycle.md](../documents/engineering/lifecycle.md), [configuration.md](../documents/engineering/configuration.md)).
- **Unsealing.** Agents may unseal Vault only through the explicit test self-unseal policy in a test environment; production needs protected custody or input within the operation ([AGENTS.md](../AGENTS.md), [security_and_credentials.md](../documents/engineering/security_and_credentials.md)).

## Implementation tasks

Entry (2026-11-25). Phase 2 closed after two clean local cycles, the current
canonical gate, critical mutations and exact fixture settlement. The
existing `test run phase-03` baseline is running against that operator
in an explicitly enrolled fresh test scope. It revalidates the available
public paths and will preserve any current failures. The existing
historical observations below remain regression material. The installed
help exposes `delete`, `control lifecycle-status` and
`control authority-deploy`. Phase 3 still owns the public plan and
operation resume gaps. See `.build/phase3-entry-authority-baseline-20261125.log`.

The four existing reviewed Phase 3 source bindings match the current
checkout. The bounded executor now exposes them through
`test run mutations:phase-03` and by individual case. Their source-bound
execution and independent cleanup remain to be verified.

Decision (2026-11-25). The mounted read currently treats any path that
passes a file-existence check as valid genesis. The identity-bound
admission rule at line 25 of [lifecycle.md](../documents/engineering/lifecycle.md)
requires a positive retained observation. The first journal repair will
validate the genesis bytes and read the mounted records through bounded,
non-following descriptors. Missing, substituted and unreadable records
remain recovery observations. This slice does not yet settle a lost
write-ahead guard or supply Authority backup and restore.

The entry run exited 1 at 15:57 under test scope
`run-cc0ef9a5365429d9f2ca95728a2a948a`. It reached the first kind
operation and tore it down. The next bootstrap did not publish a
readable Authority genesis and the existing test runner raised a
filesystem exception when starting the missing-genesis control. The
independent observer confirmed exact node, volume and network absence
for operation `4a51f9e26e1fec3f493a6d3a9e34f835`. This run has no
qualifying reports. Preserve the local adverse fixture and logs. The
runner now preserves the replacement reconcile diagnostic, records
failure if the genesis control cannot be set up, skips a readiness
retry when bootstrap failed and proceeds to its supported cleanup.
See `.build/phase3-entry-authority-baseline-20261125.log` and
`.build/phase3-entry-authority-baseline-independent-20261125.log`.

The pre-Authority case inserted its simulated journal into the same root
that it later tried to recreate. The current kind archive uses the early
fence's eligibility check, which requires the local journal path absent
in `src/Prodbox/Control/AuthorityJournalClient.hs`. The runner now retires
that exact private fixture after the adverse observations and before
the next reconcile. It uses the existing checked fixture cleanup and
records failure if custody changes. This fixture remains a regression
probe. A03-03 and A03-04 still need the real Authority operation path.

Decision (2026-11-25). The selected scope now supplies the expected kind
identity to the authenticated journal reader, and the Authority includes
its mounted role configuration's cluster identity in each reply. The CLI
holds the existing generation-checked kubeconfig snapshot for the read.
This follows the identity rule in [lifecycle.md](../documents/engineering/lifecycle.md#identity-intent-and-observations).
The deployer reserves journal creation under the existing kind lease and
records the retained directory's device and inode before deployment. The
host refuses missing or replaced storage with surviving reservation data,
and existing directories without a recorded binding require recovery.
These records locate the mounted journal. Only its Authority supplies
the deployed scope's admission verdict. This slice leaves recovery of an
ambiguous creation or loss of the contents of an otherwise unchanged
directory, and journal backup and restore, open. The changes affect
`M01-authority-unobservable` and `M01-authority-fence`; their current
bindings require fresh isolated evidence.

Follow-up (2026-11-25). The fresh fixture run under
`run-adfa06a18528b06dca2062660d7d746b` independently reached kind
readiness, proved exact first-operation absence and reached readiness
again for replacement operation `030dc468a84fb46f01b36b4b66a7d615`.
The independent observer then saw the management services, Broker and
Authority Pods. The earlier binary wrote journal members as UID 0
under a UID 1000 retained directory, which the hardened record reader
refuses. The updated deployment runs the Authority with the selected
retained directory owner's UID/GID. The deployer binds both the journal
and a separate custody directory to the same generation. The Authority
durably consumes a genesis reservation in that custody directory
before first initialization, so losing both journal files cannot
authorize reinitialization. Missing or partially published custody
requires recovery. The paired binding addresses loss of a named
directory. The one-time reservation addresses loss of its contents.
See `.build/phase3-authority-fixture-independent-20261125.log`.

The earlier targeted unit run reported five failures. Four test setups
supplied bare artifact digests, which the selected bootstrap decoder
rejected, and the binding check ran after the mounted journal source had
changed. The fixture now uses the digest-qualified form and the changed
mutation sources are repinned. That earlier run is not validation.
See `.build/phase3-retained-binding-build-and-unit-20261125.log`.

The CLI exposes aggregate `status`, `plan delete` and `plan reconcile`
in the new build. The deletion plan uses the same fresh read and
decision as `delete --yes`. The reconcile planner uses the existing
retained-kind operation observation shared with `control reconcile`.
Status also reports independently observed kind/control facts and
Kubernetes readiness. The live runner exercises these paths in the
real Authority scope and both planners while Vault is sealed.
General operation resume, backup and restore, and obligation-aware
control removal remain open.

Canary disposition (2026-11-25 16:26). The 16:07 run produced four
reports. Case 1 passed. Case 2 used the public reader with a retained
kubeconfig for the retired first node. The classifier exercise now reads
its private fixture directly and separately asserts the public refusal
when the real API cannot be observed. Cases 3 and 4 recorded the
initialized journal but the reader rejected the UID 0 files. Both now
share the measured cleanup result and timing. The same unmodified
binary independently refused `control delete --yes` again at 16:22.

Under the standing exact test-cleanup authorization, the failed canary's
replacement runtime was then retired by hand under its original root
lock. Retained creation receipts matched the selected generation,
operation, daemon, socket, node, volume and network. The read-only
inventory verified the bound Kubernetes API and absence of scoped jobs,
workers and host units before stopping the node. Independent reads then
returned HTTP 404 for the exact Docker node, volume and network with the
original daemon and bridge still HTTP 200. Original scope, operation and
journal records and management data remain available for diagnosis.
The canary still has failed acceptance reports. See
`.build/phase3-authority-fixture-hand-action-20261125.log`,
SHA-256 `6cad807873a4c849267c07b8862f00fa49132d9b676a2afb135160c4acd6a33d`.

The corrected parser catalog and targeted journal selection passed
384 tests. The compiled CLI also regenerated its command reference,
manpages, completions and goldens, and `dev docs check` passed.
The 16:27 live status/plan run uses executable SHA-256
`b45f8be9c3d8a40681fb8f8e598a492704575bd2ab4d31e2fe6498e3d3110bc3`.
It observed first kind readiness and exact teardown before starting the
replacement. The following code work is a different candidate.

Decision (2026-11-25). A valid-looking but substituted journal could
otherwise appear empty. Following the positive observation rule in
[lifecycle.md](../documents/engineering/lifecycle.md#identity-intent-and-observations),
the Authority now commits a digest of the non-secret mirror bytes in
the separately bound custody directory under the existing write-ahead
guard. Reads and restarts require matching bytes. Separately, the exact
local removal admission now holds the same custody directory lease as
Authority writes and publishes a durable fence before node effects.
Only a fresh NeverAdmitted verdict can create this fence. Matching
generation and kind operation allow replay while the API is gone.
New Authority admission and deployment refuse while the fence survives.
This follows the removal and recovery boundary in
[control_plane.md](../documents/engineering/control_plane.md#recovery-and-local-removal).
The existing pre-Authority test teardown fence remains separate.
Archiving the exact original operation and releasing its removal fence for retained control
recreation, and positive absence for scopes that admitted cloud effects,
require their own recovery proof. Both remain open.

Real scoped read (2026-11-25 16:42). The 16:27 status/plan canary exited
0 with all four currently registered reports satisfied. On the same
Authority, UID 1000 owned the three protected mounted records. Direct
Vault health observations before and after `control lifecycle-status`,
`plan delete` and `plan reconcile` reported initialized and sealed.
The sealed reads used fresh Authority metadata, and the reconciliation
plan named the actual replacement control operation
`df6b4b2bd522870c0da50b6bcfe22eea`. Both exact kind runtimes reached
independent readiness and Docker node, volume and network absence after
supported removal. The four reports are in
`.build/scenario-evidence/275e90631d77bd2dc0d509ac3c7057ae/`. See
`.build/phase3-status-proof-real-20261125.log`,
`.build/phase3-status-proof-independent-20261125.log` and
`.build/phase3-status-proof-sealed-readback-20261125.log`. The result
validates those paths. The acceptance rows still require their
remaining controls, operation recovery, backup and advanced Vault work.

The subsequent custody candidate was built with executable SHA-256
`0933ee3b450f53d0b58024ab68c70ce6e5a4227fa7f5283c2875a7763798e265`.
Its targeted 385 tests passed, including same-size mirror substitution
and concurrent authority admission being refused during and after a
retained control removal. The M04d source binding now targets the first
of those regressions. Source-bound mutation evidence remains open.

Local operation slice (2026-11-25). The public operation commands expose
the selected kind operation, checked publication and result evidence,
same-operation resume, and recorded cancellation when publication can
be excluded. Resume shares the existing controller launcher and closes
through the same independent completion observer as `control reconcile`.
The launch routine checks the early removal fence under the same kind
lease before recording a new publication. Possible sends require their
original settlement path. The live runner exercises exact ID, wrong ID,
terminal resume and cancellation refusal for a completed publication.
General Authority operation recovery and cancellation after a possible
send remain open.

The 16:46 operation canary uses binary SHA-256
`5c9738d6f029c73074b056e044caee594951435a5015ef87e8823e7a6e75515b`.
Its independent process trace captured two successful ordinary deletes
in the first kind operation `1295b7c93135bfa9c9a5ae66c63e1af6`. Each
process tree made one IP connection attempt, to loopback. The exact
Kubernetes node and operation remained present throughout, and Vault
data and the management namespace were absent before and after. The
public scenario then removed that node, volume and network. See
`.build/phase3-operations-proof-noop-trace-20261125.log`, SHA-256
`2f2879fee9584d083c009a42b833c816897cc3a32832d5e48e04bf2a1c5e82ef`.
The full run exited 0 at 17:02. All four reports passed, stored under
`.build/scenario-evidence/e4748959043315a8cd29c0b730e56a42/`. The
replacement operation `1c5c48042f7f850558132ee5f3b5aabb` reached
independent Kubernetes readiness, retained the same control ID through
`operations resume` and removed its bound resources after publishing
the Authority-backed fence. The public removal replay succeeded with
the API gone, and exact Docker reads confirmed both runtimes absent.
An independent read also matched the retained digest to the journal
bytes while the Authority served its own fresh verdict. See
`.build/phase3-operations-proof-real-20261125.log`,
`.build/phase3-operations-proof-independent-20261125.log` and
`.build/phase3-operations-proof-journal-readback-20261125.log`.

Interruption proof (2026-11-25 16:55). A separately enrolled test
operator was killed after recording control operation
`e67fed2b5b6fe44bebb2de6719885442` and before any publication.
The public operation observation saw no launch. Two cancellations
returned the same durable disposition and resume refused the cancelled
operation. Public control cleanup completed. The independent observer
read the original scope and cancellation, found the exact candidate
node, volume and network absent, and found no worker unit or job for
the identity. See `.build/phase3-cold-cancel-20261125.log` and
`.build/phase3-cold-cancel-independent-verified-20261125.log`.

Interrupted resume proof (2026-11-25 17:07). A second explicit test scope
`run-9634b6d9f310f7e8af34e08e3807266a` was interrupted before publication.
Public `operations show` observed no launch and `operations resume`
completed the original `d112f88dad06568b061b5a10ae581be5`. Independent
Kubernetes readiness confirmed the resumed node. Supported control delete
completed and an independent Docker observer verified the exact node,
volume and network absent with positive daemon and bridge controls. See
`.build/phase3-cold-resume-20261125.log` SHA-256
`56f364931b992df718245c09ec182a83972d66fa5d5613bb91f1aff8a7d3f8eb` and
`.build/phase3-cold-resume-independent-20261125.log` SHA-256
`f45a9a1c3c3a1b52affc815b45e68254fe1115facaf8a636e31a7054a15fd34c`.
This covers the pre-publication kind operation; mounted Authority
operation concurrency remains open.

The previous successful canary's disposable Vault and MinIO directories
and scoped reader credential were retired under its original root lease
after both supported runtime removals and independent absence. The
Authority journal and operation records were verified unchanged. See
`.build/phase3-status-proof-custody-hand-action-20261125.log`, SHA-256
`93acbc5122f77c212ee35375151a7df29945b464ae969e52c4592e2b15edec79`.

Storage slice (2026-11-25). Following
[storage.md](../documents/engineering/storage.md#journal-checkpoints-and-backups),
the scoped local backup adds the settled Authority journal and custody
directories under the kind and journal leases. It checks the copied
trees against quiesced source trees and publishes the bound format-3
manifest only after they match. Format-2 backups retain their
pre-Authority scope. Restoration verifies the closed directory set and
scope/generation, requires the matching retained Authority state, stages
and reads back the management data before the swap, and preserves
original directories for recovery. A focused test caught a regression in
the format-1 recovery guidance. The restore again checks that manifest
before requiring a working kubeconfig. All 400 focused cases passed in
`.build/phase3-storage-pki-restored-unit-direct-20261125.log`.

Interrupted storage restore (2026-11-25 17:16). The durable intent binds
the selected backup commitment, root generation and exact directory
identities before stopping the management Pods. A replay observes the
original and staged directories under the same kind lease before each
move. Services restart only after the installed copy has been verified
and the installed receipt is durable. The control removal and service
reconciliation guards refuse an unresolved restore. Real mid-swap
interruption and recovery, and restoration of missing current Authority
journal members, still need their respective proof. The updated M03c and
two affected M01 mutations require current isolated runs.

Storage canary (2026-11-25 17:19). Scoped test
`run-95fc0aa7ef68fd476cf8c0e349ab084d` verified a real format-3 backup,
copied Authority records and unchanged Vault identity after backup and
unseal. The supplemental driver omitted the `control restore --yes`
confirmation, so the parser refused before restore and PKI was skipped.
The refusal was reproduced offline. Supported control deletion completed,
and exact node, volume and network absence was independently observed
for `672a91983909a42160ba4fc3c47bc45e`. See
`.build/phase3-storage-pki-real-20261125.log`,
`.build/phase3-storage-pki-independent-20261125.log` and
`.build/phase3-storage-pki-missing-confirmation-20261125.log`.
The next driver uses the actual required flag and the interrupted-swap
candidate. Its first build compiled, but the inherited mutation alignment
check caught stale M03a and M03b digests after adding the unlock guard.
Those bindings are updated and await the next coherent build and execution.

Interrupted swap canary (2026-11-25 17:29). In
`run-178c585f0d9e8ba80e400a51fa067291` the unmodified operator was killed
after moving the original Vault directory and before installing its
replacement. Both management Pods were independently absent and control
removal, service reconciliation, and a second backup refused during the
gap. Retrying `control restore` on `backup-5180d1729257` completed the
swap, preserved both original directory inodes, and restarted the
initialized Vault sealed. The actual Authority still reported its own
journal state. The subsequent unseal refused at the next boundary, and
the captured driver output did not distinguish its cause. Supported
control removal completed and the exact node, volume, and network for
`87522c8e13387a4d84413445407353f9` were independently absent. See
`.build/phase3-interrupted-storage-real-20261125.log` and
`.build/phase3-interrupted-storage-independent-20261125.log`. Full
post-restore continuity and PKI stay open.

PKI slice (2026-11-25). The selected `admin vault pki` leaves reuse
the Broker's typed PKI route through the held scoped kubeconfig.
Certificate issuance is limited to a test identity. The Broker reads the
issued public certificate back from Vault by validated serial, verifies its
DER bytes and serial against the issue response, and returns its SHA-256
with the action commitment. The wire, Broker, CLI and admission selection
passed 653 tests in `.build/phase3-pki-readback-fixed-build-and-unit-20261125.log`.
The real canary (2026-11-25 17:39) in
`run-bbeb9802b829b4d5b6e653011fa1e6c5` independently read the same issued
leaf by serial from Vault, matched DER SHA-256
`c98633873d91ac5e257e9b58ea520fd97e9a33d001f50dc6a2c6ffa3fa6f0d8c`,
and verified the issuer and test hostname. The independent Authority read
answered for the selected identity while Vault was sealed and refused
both foreign and anonymous callers. Supported cleanup completed and exact
runtime absence for `1e1661d8e34d487f39af88e7a01b27e9` was independently
confirmed. See `.build/phase3-pki-and-sealed-authority-real-20261125.log`
and `.build/phase3-pki-and-sealed-authority-independent-20261125.log`.

The canary reproduced the post-restore unseal refusal after an initialized,
sealed state was independently observed through the Broker. Comparing the
backed `prodbox-objects` store with the exact original directory preserved
by the swap showed three different stored records at the same names, one
fence and two worker records. An unchanged mounted admission journal alone
therefore cannot establish safe management restore. The private comparison
is recorded in `.build/phase3-storage-history-counterexample-20261125.log`
with public log SHA-256
`51df160121a5ca7545ee243d90f10b701ccc10f0fe92924e707f2b87436a3332`.
Format-3 restore now
compares the backup against current Vault, the durable Broker and Authority
buckets and MinIO configuration before admitting a fresh swap. The
regression fixture models a different same-size fence and unrelated MinIO
temporary files. Real matching-history restore and stale refusal remain
open. The scenario also now includes a stale host projection comparison
during the missing-genesis adverse control.

Vault maintenance slice (2026-11-25 17:35). The scoped status and
maintenance commands use the same selected Broker connection and its
retained operation journal. Rotation and reset require an explicit original
storage generation and operation ID. The reset also requires confirmation.
Confirmed IDs reuse the Broker request identity on retry. The current
ambiguous-init physical interpreter observes a PVC and scales a StatefulSet
in `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`. The implemented kind
Vault uses a host-path Pod in `src/Prodbox/Control/Services.hs`. The local
reset adapter and a real ambiguous-init recovery remain open. This is a
Phase 3 implementation dependency within the selected substrate.
The checked generation/operation parsers and Broker cases passed 661
focused tests and generated reference validation.

Rotation canary (2026-11-25 17:50). The real fixture in
`run-d7862ba7426abe438dfeb631e0074097` refused the foreign generation, and
the independent Transit key observation was unchanged after that refusal.
The valid generation reached the actual secret worker, whose Pod then
failed. The driver's next version check was skipped on the public error,
so the valid request's physical effect is unconfirmed. Supported control
removal completed. Docker independently confirmed all exact runtime
resources absent for `a357185a3f9179535d167dcfce02372e`. See
`.build/phase3-vault-rotation-real-20261125.log` and
`.build/phase3-vault-rotation-independent-20261125.log`.

Review of `src/Prodbox/Bootstrap/Broker/ProductionSecretWorker.hs` found
that the path requires an accessor-free batch token and then tries
`revoke-self`, even after a verified rotation. A Vault batch token has a
fixed lifetime and cannot be manually revoked. This disagrees with the
existing Broker batch-role contract. A candidate correction drops the
impossible revoke for validated batch tokens and preserves unexpected
service-token retirement. The next real observer must record physical
version even if the public mutation returns an error. [Vault token types](https://developer.hashicorp.com/vault/docs/concepts/tokens#token-type-comparison)

Transit receipt counterexample (2026-11-25 18:12). The batch-token candidate
`07e4c7b0dee445b399a0beca8cc11965c420941a717077327aed7de045b06094`
still failed on the valid public call in
`run-93ec076225d0f7055e2f107c5671f468`. An independent Vault read
confirmed version 2 after version 1. The retained Transit journal
contains the completed version pair, while the worker result coordinate
still contains the earlier baseline result. The production store and
controller receipt checks both required an issued service-token accessor
for that result. The worker instead validates Vault's accessor-free batch
login before dispatch. The candidate correction binds the receipt to the
accessor carried by the durable result and retains exact legacy accessor
matching. The scope's supported control deletion passed and Docker read
back the original node, volume and network as absent. See
`.build/phase3-vault-rotation-batch-real-20261125.log` SHA-256
`c84c706607a78eba897037ca2dd7c5906d38aa58ed7f624769b9e4495de72e36`
and `.build/phase3-vault-rotation-batch-independent-20261125.log` SHA-256
`aaaa4de28a138e333c8cb58626069a5f5851089a674a7f54f6455e20132ccd88`.
Decoded retained MinIO records for both failed scopes contained the same
typed completed version pair 1 to 2. Both fixed worker result objects
predated the matching rotation attempt. The non-secret observation is
`.build/phase3-transit-retained-counterexample-20261125.log` SHA-256
`d91885d47e2a7c4c9f49af26df607e79844e8326e538f2e1c7fe6ca42313094e`.
The public receipt and same-ID replay still need real acceptance.

Management restore operation (2026-11-25 17:49). The scope's active
restore exposes a stable, non-secret staging-derived ID through
`operations list` and `operations show`. `operations resume` uses the same
verified backup path. Reconcile's common assessment reports the restore
blocker while the durable intent is active. The stale/no-change guard
passed its 662-case focused gate before adding the operation commands.
The matching-history storage canary (2026-11-25 18:01) passed on the
earlier pre-operation-command binary
`68407378860c0ce0d3b65d0026675d07366095bd180f123f1e63bb1ac98ab854`.
In `run-bd737e4ddcbd15e17a5e5f6b8d98f793`, the operator was interrupted
after the original Vault directory moved. Competing mutations refused;
the original backup `backup-89c6f5004cd7` resumed and preserved both
original directory identities. The initialized Vault returned sealed,
unsealed to its original incarnation, and remained unsealed during the
settled replay. The older separate backup `backup-a742d710c387` refused
without moving either current directory. The fresh Authority records
matched throughout. Supported cleanup completed and an independent
Docker observer verified exact node, volume and network absence for
`fbfeb9f67d454664fcc9ce69dc0c0b20`. Logs are
`.build/phase3-verified-storage-restore-real-20261125.log` SHA-256
`aaa6b9299314b2403fa89e76a49cae4d99604eda8ec2668f2a0c18b6ef8655f5` and
`.build/phase3-verified-storage-restore-independent-20261125.log` SHA-256
`f0d019a40ca6d34a5cdc335f892deaea57c2f596fffc70b0a14184afd1db12c4`.
The new operation-ID resume path still needs its own real proof.

M04d isolated outcome (2026-11-25 17:24). Campaign `1867284175735692`
compiled the baseline and mutant and killed the candidate on the sole
assertion `lifecycle.modified_mirror_requires_recovery`. Its source
manifest SHA-256 is
`7d1954e1332a17f9287b9d184ed9de6d2c3a9a00cdaefaf1fbb2a60f69a801cc`.
Independent reads found all eight exact workers and the quota volume
absent, with the same Docker daemon and bridge on both sides. Campaign
and observer logs are `.build/phase3-M04d-mutation-20261125.log` SHA-256
`ee91717d5c3f69caa04e999ea901b5890a03419ed21ab5417082b9315389f935` and
`.build/phase3-M04d-mutation-independent-20261125.log` SHA-256
`109d28e1958e88f948726f0c8e3ba28937a5f5386588b868607c79987ddbe326`.

M04c isolated outcome (2026-11-25 18:02). Campaign `1869360179899150`
killed the baseline-compiling candidate on the sole assertion
`lifecycle.uninitialized_mirror_is_not_fresh`. Its source manifest SHA-256
is `5b2fb541a5f71ad37847d1a1b30d7b3c67136b5821a62c5801748753ca0bd105`.
All eight exact worker IDs and the quota volume were independently absent
with positive daemon and bridge controls. Campaign and observer logs are
`.build/phase3-M04c-mutation-20261125.log` SHA-256
`e7944db38df56c69faad88700aab470edd98577d0137f1b35b7b820b688d2ec2` and
`.build/phase3-M04c-mutation-independent-20261125.log` SHA-256
`d20ceb98220879717b6b91174fcae5ca00439c632ef1d3bf9768abd1fc76a21a`.

Decision (2026-11-25 18:03). Control recreation uses the existing exact
kind retirement and archive transaction. Its Authority-backed input is
the matched custody fence for the original operation. The host archives
an exact copy of the decision with the original kind records, reopens the
published archive, and only then moves the active fence under the same
custody lease. A retry after archive publication requires that same proof.
The retired fence stays in custody and the mounted journal remains in
place for the replacement node. This follows the retained identity and
resource observations in [Lifecycle](../documents/engineering/lifecycle.md#identity-intent-and-observations).
The archive candidate
`af868d71273873655ec364a14877fdb4a6eda08f3360c69eae794d9a5f6f2d39`
passed 664 focused cases at 18:15. The checks cover wrong published
archive identity, wrong original operation/value, retained fence inode,
and rejection of cascade on the new public deletion routes. The affected
bindings `M01-unknown-recreate` and `M01-authority-unobservable` are
repinned. Real recreation is running under
`run-b2b28da5064997f24935d3bbd5dee532` against the same candidate.
The first canary ended at 18:21 before Authority deployment. The kind
reconcile succeeded. The separate management network enforcement gate
returned a settled `ok: false` service attempt, with its probe namespace
removal recorded and no management Pods observed. The canary captured
the command failure category but omitted the exact gate reason.
Supported control deletion completed. The independent observer confirmed
the original node, volume and network absent for
`6a087e830d8ea0a83d147b7489e7ff06`. Primary evidence
`.build/phase3-authority-recreate-real-20261125.log` SHA-256
`b10a3b6d7335b24ede5264211c5d97bd5c1ff3393a0991ab2639e03f1ca1f878`
and independent evidence
`.build/phase3-authority-recreate-independent-20261125.log` SHA-256
`f91bb6cf82cf37eb1dd3893aa7b34fff7736abacebd30c40d92a055dffb10ebd`.
Recreation still needs real proof.

M04a isolated outcome (2026-11-25 18:23). Campaign `1870490296166714`
compiled the baseline and mutant and killed the candidate on
`lifecycle.unknown_requires_recovery` alone. Source manifest SHA-256
`2df5f427da475c7b825bd8bb9fe37371d52506d497fd308c5e60926f8aa89625`.
The independent observer confirmed all eight exact worker IDs and the
quota volume absent with positive Docker daemon and bridge checks.
Campaign and observer logs are
`.build/phase3-M04a-mutation-20261125.log` SHA-256
`9b90a27e12752d3eb8753ee7ece3082cc90e9b1de6c6816d20e4e061f17106e4`
and `.build/phase3-M04a-mutation-independent-20261125.log` SHA-256
`dc154a9042709564c1ff4213bb8ad68f8a2c7b7060b60a4247e30f2e364fe165`.

The Transit receipt correction passed the 164-case physical Broker and
attested worker gate at 18:23. This includes exact private result
publication/read-back for an accessor-free rotation and a refused
foreign accessor. The real repeat uses immutable operator
`2d9f917aac9c363ae6422f5554b9ea3ab32ce128479903be275fe43bb88e7056`.
The canonical scenario also issues two concurrent public resumes of the
same completed kind operation and compares the original durable result
and independently queried Kubernetes node UID before and after. It still
requires a separate live observation of duplicate admission while an
Authority operation remains unresolved.

Vault rotation canary (2026-11-25 18:33). Operator
`2d9f917aac9c363ae6422f5554b9ea3ab32ce128479903be275fe43bb88e7056`
refused a foreign generation, rotated the real Transit key, and returned
success on same-ID replay. The independent Vault request observed
version 1 before rotation and version 2 after both successful replies.
The same scope returned success for unlock-bundle rotation and same-ID
replay, and refused foreign confirmation and the obsolete password.
The replacement password was tried before independently observing
settlement of the failed obsolete-password worker and was refused.
The existing Phase 2 adverse runner explicitly waits for that lease
before another ingress (`src/Prodbox/Test/Phase02BrokerRunner.hs:200`).
The next proof checks the selected Lease's duration and renewal time
before trying the replacement. The failed combined run is retained.
Supported cleanup and independent exact Docker absence passed for
`43a18673dca3a7c16f0c85d573c6b1fa`. Primary and independent logs are
`.build/phase3-vault-rotation-receipt-real-20261125.log` SHA-256
`a647918dbfe422ebb17a1474ed261db349fd72b061c16658dd8e01ca460bb02e` and
`.build/phase3-vault-rotation-receipt-independent-20261125.log` SHA-256
`d04db0aedbd633519e2d07afef44271804117e5ed985b6539458f5ae23bf9d26`.

Bound Vault maintenance canary (2026-11-25 18:52). The repeat using
`b49bbba3b2a5c74f6dfeb5f47152ab7d5b1b9ec7c82eb5a9f57eeb7c2f000a91`
again confirmed one real Transit increment and idempotent replay.
The replacement password unsealed the original Vault incarnation and
storage generation after independent expiry of the observed 300-second
Broker lease. The obsolete-password request in this repeat was refused
while the predecessor lease was still held. The preceding canary's
actual failed obsolete-password worker supplies the adverse observation.
The repeat also refused resetting the healthy initialized Vault and
independently observed its unchanged identity before supported control
removal. The original node, volume and network were exactly absent for
`82acf2850fa300106750da30486fb3d2` using the same Docker daemon and bridge.
Primary and independent evidence are
`.build/phase3-vault-rotation-lease-real-20261125.log` SHA-256
`9fc7b04f2f06410f2beadc87edb33c728abbff25a96b4a0288cf1326949da27f` and
`.build/phase3-vault-rotation-lease-independent-20261125.log` SHA-256
`bd974a6d17b309712fd6e239088a78b0561b874a48d6eea61e8de71f45dcc81c`.
A positive recovery from a genuinely ambiguous initialization is still open.

M04b isolated outcome (2026-11-25 18:35). Campaign `1871271215949209`
compiled the baseline and mutant and killed the candidate on
`lifecycle.missing_history_is_not_fresh` alone. Source manifest SHA-256
`572c58c1eba9e7fe3df550f500cedbc6ecb88ad123e0abc80c9f6ee1c4383cdb`.
Independent Docker checks observed the eight exact workers and quota
volume absent under the original daemon and bridge. Campaign and
observer logs are `.build/phase3-M04b-mutation-20261125.log` SHA-256
`dc977ad23625e6ea1732375188b1d1152fa97c0c795a75ae8118643a6a847eca`
and `.build/phase3-M04b-mutation-independent-20261125.log` SHA-256
`e525e4847d79d6c9287c3e296961d312d42e2342e58b6bda8e2fe487e1909108`.

Decision (2026-11-25 18:31). The test-run cleanup is separate from
control removal, as specified by [the storage retention table](../documents/engineering/storage.md#retention-and-destruction).
The registered Phase 3 scenario publishes its reports outside the test
root and binds its terminal control operation to the exact root inode
and generation. The public `test cleanup RUN_ID` revalidates that
registration, repeats supported control removal and exact read-back,
then records the original identity outside the root before moving it
under the same scope lease. It verifies and retires the bounded,
same-mount tree from the quarantine. A retry requires the same recorded
root and preserves the external evidence reference. Build, adverse
controls, interrupted replay and real cleanup evidence are pending.

Decision (2026-11-25 18:45). Keep local restore progress distinct from
the fresh Authority admission verdict. The common ordinary-delete
assessment reports the retained restore operation as a blocker even
when the Authority correctly reports no cloud admission. The executing
command rechecks under the selected control lease. This applies the
pending-operation rule in [the lifecycle contract](../documents/engineering/lifecycle.md#identity-intent-and-observations)
without changing the Authority's recorded cloud history. The real
interrupted-restore driver now requires both `plan delete` and
`delete --yes` to report that blocker before same-ID resume.

The first focused test-root build exposed the need to recognize the
exact retired kind bridge FIFOs in a retained run. Its scenario tests
also caught an unnecessary export change to the pinned M01 source.
The current candidate recognizes only the recorded kind bridge pipe
paths within the registered root and reuses the existing scope
constructor for identifier validation. The original M01 preimage is
unchanged. That first run is retained as diagnostic evidence and
does not qualify the cleanup.

Decision (2026-11-25 18:56). Keep the original restore operation ID
usable after its active marker moves to the terminal receipt
(`documents/engineering/lifecycle.md`, Identity, intent and observations).
Before terminal rename, publish the exact operation lookup under the
same scope and backup. `operations show ID` and `operations resume ID`
replay the historical outcome only after the lookup, installed receipt
and completed record agree. The live interrupted-restore proof will
check same-ID replay after unsealing and observe the Vault incarnation
again. The earlier 211-case test-root candidate passed its focused and
generated-reference checks. Its real registered scenario is running.

The cumulative development gate (2026-11-25 19:01) found a direct
dependency from the operator entrypoint into the validation harness
and three nested-case style violations. Test-root retirement now lives
in `Prodbox.Control.TestRunCleanup`. The control layer owns the bounded
tree inventory shared with the mutation harness. The mutation caller
retains its original private-tree policy and evidence encoding.
The operator dispatch uses named, scoped handlers. The current
candidate is rebuilding for the same full gate.

M05 isolated outcome (2026-11-25 18:55). Campaign `1872502208857401`
compiled the baseline and mutant and killed the candidate on the sole
assertion `lifecycle.pending_intent_blocks_noop`. Source manifest
SHA-256 is `5d2f7835b5aefc9bf7be12bdd8e4fab5b1595ff73de9972637eac3307349b1aa`.
Independent reads confirmed eight exact workers and the quota volume
absent, with positive checks on the original Docker daemon and bridge.
Campaign and observer logs are
`.build/phase3-M05-mutation-20261125.log` SHA-256
`cd1617e141f4d574cd34393771dff7fc7737785276816cf97d55068f5a65d96b`
and `.build/phase3-M05-mutation-independent-20261125.log` SHA-256
`71b4ad1c5c2f4b8d5f93c17bff9efd804787c012a028dbb2d06756b5eb3fd48f`.

M01 Authority fence regression (2026-11-25 19:06). Campaign
`1873259133427309` compiled and killed the current
`M01-authority-fence` candidate on `delete.fences_authority_deployment`.
The source manifest SHA-256 is
`79b151c665fa142ac55137f63db8afbf9a0f9ef427e8b4217665030d78e2abd3`.
Independent verification observed all eight exact worker IDs and the
quota volume absent with the original Docker daemon and bridge.
Campaign and observer logs are
`.build/phase3-M01-authority-fence-mutation-20261125.log` SHA-256
`7cb1371e25d8f37521abf3e4d2010104caaeb68733259aa7f70f175255f8cc8a`
and `.build/phase3-M01-authority-fence-mutation-independent-20261125.log`
SHA-256 `54ff12713fcff8ce8e0a85ed68db1d1e6e47400095d595e59eb35349789b5d36`.

Registered scenario counterexample (2026-11-25 19:10). Operator
`af218b33eabd2882a664e87ff1beba96b6954a61f73a48fd0976393508cd3633`
passed cases 1 through 3 in
`run-f6d6742623974f95e60221d60c6c71b2`. The real mounted Authority
refused ordinary and control deletion when its genesis was withdrawn,
despite the readable empty host projection. Two concurrent resumes
returned the original kind operation and left its result and node UID
unchanged. Case 4 still obtained the authenticated journal read,
refused foreign and anonymous callers, and served the read after
Authority restart and with the Broker down. The service attempt that
was meant to restart Vault had a settled `ok: false` enforcement result
with its probe namespace removed. The scenario never observed sealed
Vault, so its aggregate proof and root registration stayed open.
Both exact kind operations were removed independently
(`80ac09bfb28e264a04bac4c831d3d76d`,
`26d7e3bb2e63ad315f272afdc9e4afe2`). The next registered scenario uses
the supported backup cycle for the deliberate seal and requires its
successful result plus independent Vault health.
Primary log `.build/phase3-run-retirement-real-20261125.log` SHA-256
`71d256991d8c209cbc312f5c6d5a2f6f5d664974e02e622147fb46579021ee67`.
Independent log `.build/phase3-run-retirement-independent-20261125.log`
SHA-256 `b5ce1dd25e9a6f8dc735adfeef58bf02651446a764891fdb4d7082c2f1681344`.

Formatter correspondence (2026-11-25 19:15). The canonical gate uses
its pinned Fourmolu 0.19.0.1. Formatting changed five reviewed source
bindings: `M01-unknown-recreate`, `M01-authority-unobservable`, and
`M03a/b/c`. Every mutation site remained unique. The pinned formatter
produced byte-identical normalized preimages and byte-identical
normalized mutant bodies across each change. The current registry
and [mutation manifest](mutation_cases.md) contain the refreshed
digests. Campaigns launched before formatting retain their original
source identities. The correspondence audit is
`.build/phase3-mutation-format-bindings-20261125.log` SHA-256
`3fa45d7b6c6946c8bfe30a334ebaacd4318727e29013b0dbc0a7f27657e06d1b`.

Interrupted restore operation proof (2026-11-25 19:22). Operator
`cfcbbb2ab394293815a0bf0f046489f097b00b191bb7373dc15e04c46034f75e`
settled operation `125ee25fa5670a573b6a7774700125c6` in
`run-edc286ba688ffd67412fbee4f2affbb8`. After an actual process kill
at the first directory move, the scoped commands found the durable
pending ID. The deletion plan named the blocker. Ordinary deletion,
control removal, foreign resume and cancellation refused. A same-ID
resume completed the original backup restore. The two originally
bound inodes survived in their recorded retirement directories.
The Authority's mounted records stayed equal. Vault restarted sealed
and unsealed to incarnation `42d7e88c-8cc8-95fd-8567-918d59851a1e`.
The terminal same-ID show and replay succeeded with that Vault still
unsealed. The older backup was refused before any directory swap.
The original kind operation `8b71648cdd57ae48d262053bf2caf0f9`
completed supported removal and independent exact Docker read-back.
Primary log `.build/phase3-terminal-restore-real-20261125.log` SHA-256
`5a889f5d45d8708b5d592967b548d412c93965901c58b82ec9793050c64f5f90`.
Independent log `.build/phase3-terminal-restore-independent-20261125.log`
SHA-256 `7673317b3db2b32be538d583ff08041bf5c47e7d8baacf6422968dc65e99b0f7`.

M03c regression (2026-11-25 19:28). Campaign `1874476381296207`
compiled the pre-format backup baseline and mutant and killed it on
`backup.rejects_same_size_corruption` alone. Source manifest SHA-256
`60ee7d436358f67253ebea4f7b1881526225119707aaa9ae509a945e803a8123`.
The same daemon and bridge bracketed independent absence of the eight
exact worker IDs and quota volume. The 19:15 normalization audit binds
that source and candidate to the current formatted trees.
Campaign log `.build/phase3-M03c-mutation-20261125.log` SHA-256
`fe8bdc6da33e6b680e0f56747c8c84d07ee5c9c7fe25944f3e955036f10f734b`.
Observer log `.build/phase3-M03c-mutation-independent-20261125.log`
SHA-256 `39014fc2099272fadacdcb3ae307ea3285ca0367593e0041bfc566f0da1f31de`.

Cleanup adverse control (2026-11-25 19:31). Before registration,
the immutable operator
`10ae9c203b55d693c91651eb7835c2c55592ee94f2b8d862a0395ca2de3ebd6e`
refused both a foreign run ID and the active selected run
`run-2d6d0ad4ee40552e132aaab936ece72a`. Direct stat and record reads
confirmed the original inode and kind intent survived both calls.
Evidence `.build/phase3-active-cleanup-refusal-20261125.log` SHA-256
`c4e769a05b7ec2e2c8ed6c84e9847a0c7b466bc7ce382170807a2a18cea1d3d8`.

L09 command-surface check (2026-11-25 19:35). The current immutable
operator's ordinary and control deletion help omit cascade. Both
actual parsers rejected `--yes --cascade` before scoped dispatch.
The generated references passed their matching check. The legacy
ledger retains ownership of original-install cascade separately.
Evidence `.build/phase3-L09-public-cascade-refusal-20261125.log`
SHA-256 `99a42bd7b76fe5b5ef736295af96c48bdda61fff0c4e7b1be408395797d42c05`.

Sealed Authority and registered test cleanup (2026-11-25 19:39).
All four public `test run phase-03` cases passed with operator SHA-256
`10ae9c203b55d693c91651eb7835c2c55592ee94f2b8d862a0395ca2de3ebd6e`,
run `run-2d6d0ad4ee40552e132aaab936ece72a`, generation
`d3681abe98cbcf34b20f8f329bcbda35`. Evidence run
`68e8fe0ae5ad39c84136cb8fa3e7a961` retained all four reports. A supported
management restart sealed Vault. The same Authority continued to serve the
scoped authenticated journal read, including across Authority restart.
Foreign and anonymous reads returned 403 and 401, full readiness refused
while Vault was sealed, and unseal restored full readiness. Fresh journal
loss refused both deletion paths while the exact running node remained.
Concurrent public resume of the exact kind operation preserved its node UID
and dispatch record. This settles A03-02 and the local kind adapter portion
of recovery qualification.

The public cleanup refused a foreign run ID. The first eligible cleanup
was stopped just after moving the original root into its exact quarantine.
Two default public retries succeeded. An independent observer confirmed
absence of the original root and quarantine, equality of both receipts to
the registration, unchanged case reports and Docker 404 for the two
recorded kind runtimes `4c77fd6f4e1a367efa55bc57a7a68d10` and
`cd8d28a7c7496d5b6d0a63059b1146fc` against the original daemon and bridge.
The primary log `.build/phase3-registered-cleanup-real-20261125.log` hashes
to `e1e2c048eef2f07d7b8060a6e55de424ca2735d77f13348095e55dcd3d95c947`.
The observation log `.build/phase3-registered-cleanup-independent-20261125.log`
hashes to `47cc9595416f860228cd2fde6af8d171607338c4edc8ab21a75dc25883a243ba`.

Affecting regression `M01-authority-unobservable` (2026-11-25 19:39).
Campaign `1875125470176424` killed the pre-format binding with the sole
unchanged assertion `delete.requires_observed_admission`, baseline and
mutant builds passed, and an independent observer verified exact cleanup.
The evidence remains tied to its baseline. The current source binding
requires its own run after the lint fix. Primary log
`.build/phase3-M01-authority-unobservable-mutation-20261125.log` hashes
to `08e59c2468d7e1498bfd25fcabb855fe0d4c973bd0aa11c0354b246a2f8da65a`.
Independent log `.build/phase3-M01-authority-unobservable-independent-20261125.log`
hashes to `7d7386f8b401d560a07cd98d34d80e0300945528c31a0469cbe87d139b5c3238`.

Decision (2026-11-25 19:46). The existing write-ahead guard in
`AdmissionJournalMirror.hs` retains recovery state after an ambiguous
aggregate commit, but contains no evidence of the exact attempted aggregate.
The recovery policy in [lifecycle.md](../documents/engineering/lifecycle.md#identity-intent-and-observations)
and the bounded recovery rule in [development_plan_standards.md](development_plan_standards.md#resource-and-credential-lifecycle)
require the original Authority to settle a positively observed, exact applied
commit without another admission. Add a protected armed-commit binding under
the same custody lease and check it against both the retained journal and the
backing Authority read. An observed predecessor alone cannot settle an
ambiguous write because a submitted compare-and-swap may still complete.
Retain recovery-required status when the attempted commit cannot be proved.

Implementation (2026-11-25 19:49). The retained Authority repository
now checks the backing revision before arming a custody-bound commit.
The bounded `OperationRecord` commits both the complete candidate
aggregate and its restricted journal view by digest. The authenticated
read refuses while the receipt is armed. Restart can settle an applied
commit only after it confirms both digests under the original custody
lease. It cannot manufacture a new admission from an observed predecessor,
even when the predecessor projects the same operation labels. The old
guard shape still fails closed if encountered. A focused regression
exercises delayed visibility, competitor refusal and exact read-back.
This addresses interrupted aggregate commits. The native operation
resume and live qualification remain open.

Decision (2026-11-25 19:56). Initializing the mounted journal is a local
Authority operation with an effect and independent read-back. Use this
operation to exercise restart, pending disposition and duplicate admission
in A03-03 and A03-04. Record the operation before publishing genesis, bind
it to the exact retained custody and backing Authority state, and permit
only same-ID recovery against those observations. Phase 3 has no remote
backup or cloud adapter prerequisite. The existing cloud-admission gate
in `Lifecycle/Authority/Genesis.hs` remains closed until its own required
receipts are available. This follows the phase's mounted journal design
and [control_plane.md](../documents/engineering/control_plane.md#recovery-and-local-removal).

Authority-backed kind recreation (2026-11-25 19:57). Operator
`10ae9c203b55d693c91651eb7835c2c55592ee94f2b8d862a0395ca2de3ebd6e`
completed both public removal cycles for `run-19f7c790d053e18e861325ef63ec6c1a`
at generation `9031d05e5125e9cd3aae8d6275ca4333`. The original kind
operation `c3faaeab3ad4cb08825315a703279518` left its scope-bound
Authority removal fence. `control reconcile` published and reopened the
exact archive, retired the active fence and created replacement operation
`d28dbdfdf2c718ff46104e3347351161`. The replacement observed the same Vault
incarnation and the original Authority's exact genesis, mirror and custody
commitment. Fresh `plan delete` read the eligible verdict from that Authority.
Final `control delete --yes` settled. Independent Docker reads confirmed
exact node, volume and network absence for both operations against the
original daemon and each operation's bridge binding. The primary log
`.build/phase3-authority-recreate-repeat-real-20261125.log` hashes to
`8cdffd4e48a24a041217bdce212ee9d6f660302ac75017bccd4e73aed13b98ed`.
The observer log `.build/phase3-authority-recreate-repeat-independent-20261125.log`
hashes to `385a6e442e527ac0728d9d4682d3b9feae1535d791ccf7826909f10072d5fa9b`.
The pending native Authority case for A03-05 remains open.

Affecting regression `M03a` (2026-11-25 20:02). Campaign
`1876475724968585` killed the current unlock source binding via the sole
unchanged assertion `bootstrap.production_rejects_test_unlock`. Both
builds passed and the observer verified exact absence for the workers
and quota volume. The logs `.build/phase3-M03a-mutation-20261125.log`
and `.build/phase3-M03a-mutation-independent-20261125.log` hash to
`ef59f782cf90dd6708b4aa31fba79441002bfb7d742ec6592c474c3c474f662c`
and `f015f2e2e1ed5e4e1fead7f6bb6404a56a2f2eca73e71d991a3291cbcd5ceab5`.

Focused verification (2026-11-25 20:00). The candidate
`caa93da8bca9237b1e7e7a527bacec2c9da1be86f633797fe0a02b4c8f9c5354`
built with no reported GHC warnings and passed `dev docs check`. The
admission-history group passed all 25 cases, including exact interrupted
commit read-back. Two test-run retirement regressions also passed. The
focused log `.build/phase3-armed-admission-focused-20261125.log` hashes to
`ff50b374fca1d75c9237af295b1946cc6970cf86b0a36c4b673884609e690073`.
The cumulative gate and the subsequent native-genesis candidate remain
separate qualification work.

First slice (2026-11-21), the admission verdict rule. A survey of the code found
that no never-admitted classifier exists anywhere in `src` (the term appears only
in plan and engineering documents), that the existing `lifecycle-authority`
runtime has no status, plan, delete or resume route (its routes are operation
submit and observe, authority observe, cleanup run and configuration), and that
it needs an unsealed Vault, the in-cluster MinIO store, the Vault role
`prodbox-lifecycle-authority`, a retained volume and a chart deployment that has
no `BrokerDeploy` analogue. The first slice is therefore the pure rule everything
else depends on, `Prodbox.Lifecycle.AdmissionHistory`: a journal observation is
unobservable, missing (with or without surviving history elsewhere) or read;
only a successful read of nothing, or a missing journal with no history, is
`NeverAdmitted`; an unobservable journal and missing existing history are
`RecoveryRequired`; an unresolved durable operation is `AdmittedPending`; and
`noChangeAllowed`/`mutationAllowed` are false for the last two. Five unit tests
(`admission history`) pin each case. These are the intended assertions for
mutations M04 and M05, whose reviewed source bindings are not yet created, and no
public command uses the rule yet, so no task or acceptance box is checked.
Next: a durable journal store under the retained root for the local scope, a
reader that produces the observation, and the first public read command.

Second slice (2026-11-21), a durable local journal, a public read and the
first guarded delete. `Control/JournalStore.hs` keeps an append-only directory
of small records under the retained root (`authority/journal/`, one file per
record, written to a temporary file and renamed, mode 0600) and a history
marker written with the first record and never removed; a reader returns
`JournalUnobservable` for an unreadable location, a record that cannot be
decoded or an entry that is not a record, `JournalMissing` with or without the
surviving marker, or `JournalRead`. New public leaf `control lifecycle-status`
(C159) prints the verdict and exits non-zero only for recovery-required;
`control delete` now classifies the journal first and refuses (nothing removed)
unless a no-change answer is licensed. New `test run phase-03`: case 1 (a
never-admitted deployment: the independent observers are the cluster-ready
check, the absence of an `authority/` directory after the read, Docker absence
after two deletes and the retained root data) and case 2 (eight observations
read from the journal directory itself: pending after an intent with exactly one
record, settled after a settlement, missing history with the marker surviving,
a corrupt record, a later unresolved record, an unreadable directory, and delete
refused with the root retained while pending and while history is missing). Both
reports validated, exit 0, Docker inventories identical. This is local file
state only: no Authority workload, no operation engine, no `status`/`plan`/
`resume` surface, no Vault-sealed read path and no mutation bindings for M04/M05
yet, so no task or acceptance box is checked.

Third slice (2026-11-21), the M04 and M05 mutation bindings. Three reviewed
source-bound candidates against `Lifecycle/AdmissionHistory.hs` (source SHA-256
`03844695...202da`, bindings in `mutation_cases.md`): M04a recodes an
unobservable journal as `NeverAdmitted` (assertion
`lifecycle.unknown_requires_recovery`), M04b recodes missing existing history as
`NeverAdmitted` (`lifecycle.missing_history_is_not_fresh`) and M05 returns a
no-change answer while an intent is unresolved
(`lifecycle.pending_intent_blocks_noop`). The unit assertions use
`assertMutationInvariant` under `admission history`; an alignment test checks
the three digests against the document. The catalog was run in the isolated
container: M01, M02, M03a, M03b, M04a, M04b and M05 Killed on their intended
assertions, the survivor, invalid and timeout controls as expected. The rule
module is now pinned: any edit to it needs the digests recomputed and the
catalog re-run. The mutations exercise the pure rule only; the journal store,
the public read and the guarded delete are covered by `test run phase-03`, not
by a mutation. No task or acceptance box is checked.

Fourth slice (2026-11-21), a partial absence check for L09. A parser test
(`CLI parser coverage`) asserts that no leaf under `control` accepts
`--cascade` (the new management surface offers none; `control --help` mentions
no cascade). L09 stays Pending on purpose: the ordinary `cluster delete` still
carries `--cascade` and its four help mentions, and the "new deletion contract
for admitted capabilities" it must be replaced by does not exist until the
Authority admits any capability, so removing the flag now would leave no
ordinary delete contract.

Fifth note (2026-11-21), what deploying the Authority on kind needs, measured.
Rendering the existing role values from a repl (`valuesForLifecycleAuthority`)
refuses with "lifecycle-authority chart requires a resolved image reference":
the chart path takes a `ResolvedCustomImage` produced by the registry-based image
machinery, which the new registry-free management path deliberately does not
use. A kind deployment therefore needs, in this order: the runtime image
imported from a local artifact (the Broker's `docker build` and
`ctr import` route already exists); a rendering of the role's Dhall config from
those values without that image resolution; a Vault Kubernetes-auth role and
policy for ServiceAccount `prodbox-lifecycle-authority` in namespace
`lifecycle-authority` (the Broker baseline already creates the role) and the KV
secrets `minio/lifecycle-authority` and `object-store/hmac` that the legacy chart
platform seeds; a MinIO user for the role; a retained volume; and manifests in
the style of `Control/BrokerDeploy.hs`. None of that is started. It is the next
slice and, like the Broker deployment, should be expected to surface several
precondition failures one at a time.

Sixth note (2026-11-21), more of what the Authority deployment must change.
Reading `valuesForControlPlaneRole` (`Lib/ChartPlatform.hs`): the role's Dhall
config is generated with Vault's address fixed to
`http://vault.vault.svc.cluster.local:8200` (the legacy chart's namespace; the new
management Vault answers at `vault.prodbox-management.svc`), it requires an
immutable image rollout token and derives a Target Agent identity from the
resolved image digest, and it validates an RPC birth configuration against the
cluster's authority scope. So a kind deployment is not only a manifest-writing
job: the config generator needs the Vault address (and the store endpoint) as
inputs rather than constants, and the image identity chain (rollout token,
Target Agent identity) must be satisfied from the locally built runtime image
without the registry. Those are source changes to a legacy-shaped generator and
should be made with its existing tests as the regression net.

Seventh note (2026-11-21), the role config is renderable. From a repl, calling
`valuesForLifecycleAuthority` with a locally built image reference (repository,
tag, a `sha256:` rollout token and manifest digest) succeeds and returns the
role's Dhall (`schema_version = 8`, the `Primary` store at the management MinIO
endpoint, the Vault Kubernetes role `prodbox-lifecycle-authority`, and a
`request_authentication` table naming the operator and test-harness callers and
the signing key `prodbox-control-plane-service-lifecycle-authority`). So the
only constant that must change for the new topology is the Vault address, which
can be replaced in the rendered text (`vault.vault.svc.cluster.local` to
`vault.prodbox-management.svc.cluster.local`) rather than by editing the
generator. Still unverified and likely next failures: the signing keys are Vault
Transit keys that something must create, the store credentials must exist in
Vault KV before the Authority starts, and the Authority has not been started at
all in this environment.

Eighth note (2026-11-21), the Authority runtime was deployed on kind and read
to its next precondition. New leaf `control authority-deploy` (C160,
`Control/AuthorityDeploy.hs`) reuses the Broker's locally imported runtime image,
renders the role's Dhall with `valuesForLifecycleAuthority`, replaces the legacy
Vault host with the management Vault's, and applies a namespace, ServiceAccount,
ConfigMap, Deployment and Service; it reports the Pod's state and, on failure,
the container log's tail. Reading those logs gave the failures in order. (1)
Before any Vault initialization the Authority refuses with
`authentication/session-acquire/unavailable` and restarts. (2) After
`broker-init`, `broker-unseal` and `broker-baseline` it still refused with the same
cause, because the pinned management NetworkPolicy admitted only the management
namespace and the Broker's: it now also admits namespace `lifecycle-authority`
(policy digest `01637648...083a7`, pinned by a unit test). (3) With that
allowed the Authority passes the Vault Kubernetes login and refuses at its store
with `registration-unobservable/store-http/authorization/invalid-access-key`:
the MinIO credentials it reads from Vault KV `minio/lifecycle-authority` do not
exist. The next slice is to create a MinIO user and bucket for the role, write
those credentials and the `object-store/hmac` key into Vault KV with the
privileges that only the initialization path holds, and then read the next
refusal. The deployment's readiness check here reports only that the container
runs (no probe is defined yet), so it must be replaced by the Authority's own
`/readyz` before it counts as evidence. No task or acceptance box is checked.

Ninth note (2026-11-21), the Authority runs on kind and its store is seeded.
`control authority-deploy` now also reads the store credentials the baseline
wrote to Vault KV (`secret/minio/lifecycle-authority`) with the Authority's own
Kubernetes identity (a short-lived ServiceAccount token, the credentials held
only in memory) and passes them on standard input to the management client Pod,
which creates the `prodbox-state` bucket, the MinIO user and a policy scoped to
that bucket; it then replaces the Pod and waits for the Authority's own
`/readyz` (the Deployment also defines that readiness probe). The store
refusal of the previous note is gone: the Authority starts, stays running with
zero restarts and answers `HTTP/1.1 200 OK` with body `ready` on its loopback
listener. `test run phase-03` gained case 3: the adverse control first (the
deployment before Vault is initialized does not report success), then the
operator-password init, unseal and baseline through the Broker and the
deployment, with independent observations by kubectl (exactly one Pod, ready,
zero restarts), a direct `/readyz` request inside the Pod and `mc` (bucket
listing and the user list), and exact cleanup (the harness settles its own
unresolved journal record, deletes through the public command and observes Docker
absence and the retained root). Findings recorded honestly: the guarded delete
refused to clean a scenario that left a harness record unresolved (a leaked
cluster that had to be removed by hand and the harness now settles its record
first); the journal store pads sequence numbers to eight digits and orders by
name, so a harness file named `99999999-...` broke ordering (the harness uses
low numbers now); and one of five runs failed the pod-state observation without
a captured cause (three consecutive later runs, and two before it, passed with
`true 0;`). The Authority's journal volume is an emptyDir for now and the
Authority still has no status, plan or resume route, no journal written through
it and no signed caller, so no task or acceptance box is checked.

Tenth note (2026-11-21), what the idle Authority persists. In a running
deployment the Authority's journal directory
(`/var/lib/prodbox/lifecycle-authority-journal`, an `emptyDir` today, the
container runs as uid 0) is empty and the `prodbox-state` bucket holds no object:
the Authority persists nothing until an operation is submitted. So a retained
journal volume is not the next blocker; what the acceptance cases need is an
operation submitted by a signed caller. The Authority authenticates callers by
signed frames (operator CLI and test harness keys named in its
`request_authentication` table, Vault Transit keys), and the repository has host
clients for the cleanup routes (`Test/LifecycleCleanupClient.hs`,
`Lifecycle/HostCleanupCompositionRoot.hs`) but none for operation submit or
authority observe. The next slice is therefore a host-side signed client for
`/v1/authority/observe` and `/v1/operations/submit` against this deployment, with
its Transit signing keys created, so that A03-02 (read admission metadata with
Vault sealed) and A03-03 (submit, kill, restart, resume the same operation id) can
be run against a real journal.

Eleventh note (2026-11-21), why the signed host client is its own slice. Reading
`ControlPlane/LifecycleAuthorityAuthentication.hs`: the only host-side route to
the Authority, `withHostLifecycleAuthorityAuthenticationResolved`, is built from
the legacy home topology. It loads the retained "unencrypted basics" through
`loadUnencryptedBasics repoRoot` (cluster id and Vault address from the legacy
config), builds a kubectl environment for the home cluster
(`homeKubectlEnvironment`), logs in to Vault as the external caller
(`externalCallerLogin`, operator or test harness), resolves that caller's Transit
signing capability and the Authority manifest signer's public key from the
session, and only then opens `withLocalLifecycleAuthorityAuthenticatedTransport`.
Each of those inputs (the basics, the Vault address, the kubeconfig, the caller's
Vault login role and the local transport's port-forward) is a legacy constant or
a home-cluster resolver, so a client for the new kind environment means
parameterizing them by the selected test identity (its kubeconfig under the
retained root, the management Vault address, a Vault login role and Transit keys
for the operator caller created by the baseline, and the cluster id) rather than
adding a few lines. The existing unit and integration suites around that module
are the regression net. This is scoped as the next Phase 3 slice; none of it is
started, and no task or acceptance box is checked.

Twelfth note (2026-11-21), the reachability gap behind the signed client. Two
seams already exist for parameterizing the host authentication
(`withHostLifecycleAuthorityAuthenticationAt` takes an explicit kubeconfig and
`loadUnencryptedBasicsAtPath` takes an explicit Tier-0 path), but the caller's
Vault login (`externalCallerLogin`, `vaultKubernetesLoginWithLease`) is plain
HTTP from the host to a `VaultAddress`. In the legacy topology that address is
the `vault-host` NodePort (`31820`), which is exactly what inherited removal B053
retires, and the new kind environment deliberately exposes no NodePort for
Vault. So the signed client needs a transport for the host-to-Vault and
host-to-Authority hops that the new environment does offer: an authenticated
port-forward to the Pod (the Broker's host connection already does this, with an
audience-bound ServiceAccount token, a TokenReview and a pinned kubeconfig), with
the Vault login role, the operator and test-harness Transit signing keys and the
Authority manifest signer created by the baseline, and the loopback addresses
passed in as the `VaultAddress` and endpoint. That is a design decision as well
as plumbing and is recorded here so the next session starts from it.

Thirteenth note (2026-11-21), the ordinary `delete --yes`, and the pod-state
flake explained. New top-level leaf `prodbox delete --yes` (C161; the target
command surface names it as the ordinary, cloud-scoped delete, separate from
`control delete`). It reads the operation journal directly: a never-admitted
deployment answers "Nothing to delete" (exit 0, no cloud credential, no Vault, no
change, the same on a second run); an unresolved or unreadable journal is refused
with the verdict; an admitted-and-settled deployment is refused because no cloud
capability's deletion is delivered by this binary yet (no successful stub). The
parser test confirms no `control` leaf accepts `--cascade` and the new leaf
defines none. `test run phase-03` case 1 gained the observation that two
`delete --yes` runs both answer "Nothing to delete" while the cluster stays ready
and no `authority/` directory appears, and case 2 that the ordinary delete is
refused while an intent is pending with the journal unchanged (all cases
validated). The unexplained case-3 pod-state failure of an earlier note was a
race: a later run observed `false 0;`, a running Pod whose readiness probe had not
yet passed, because the deploy waited only for the loopback `/readyz`. The deploy
now also waits for the Pod's Ready condition, and three consecutive runs observed
`true 0;`. A03-01 stays unchecked: its catalog row asks for independent request
tracing of "no AWS call" and of no Vault initialization, which this runner does not
yet provide (it shows the cluster ready and no journal written, not an absence of
network requests).

Fourteenth note (2026-11-22), the sealed-Vault baseline, measured. Decision
recorded per the new AGENTS.md blockers rule: the documents settle the A03-02
design (see "Design resolutions already settled by the documents" above), so
the earlier question to the user was withdrawn. Measured on the current
deployment: with Vault sealed under a running Authority, `/readyz` answers
`HTTP/1.1 503 Service Unavailable` (`not-ready`), the Pod is `0/1` Ready, the
process stays up with zero restarts, and there is no narrow read to ask. That is
the gap A03-02 must close; it is not something the running Authority already
provides. `test run phase-03` case 4 records this baseline (Vault sealed by
replacing its Pod; the Authority not ready; a restart of the Authority while
sealed leaves it not ready with a `startup_refused` log; unsealing through the
Broker lets it recover) with all four observations satisfied, and must be
changed to assert the narrow read once it exists. Cases 1 to 4 validated,
exit 0, Docker inventories identical.

Fifteenth note (2026-11-22), what the Authority's journal really is in the code,
and the first slice toward the mounted journal. Reading the Authority: the
`operationRecordCodec` (`Authority/OperationStore.hs`) is not used by any runtime
code, and `Authority/OutboxSim.hs` is a simulation. The retained record of what
was submitted is the `SubmissionLedger` inside `AuthorityAdmissionAggregate`
(`Authority/Admission.hs`): per client, in-flight records (unresolved intents),
settled tombstones, and a compaction floor above which records are retained;
the aggregate is one authority-object compare-and-swap in the Vault-keyed MinIO
store. Decision (recorded per the blockers rule, from lifecycle.md "the
Authority owns the durable journal" and control_plane.md "mounted journal"): the
mounted journal is a write-ahead mirror of the admission-relevant facts of that
ledger, written to the retained volume BEFORE each aggregate commit so the volume
can be ahead of the store (conservative: it may show a pending intent that the
commit never made) and never behind it, plus a genesis record written once at
birth so that "no record" can be told apart from "journal missing". Slices, in
order: S1 the pure projection from the real ledger to the verdict (done below);
S2 the write-ahead mirror at the aggregate commit seam
(`Lifecycle/AuthorityObjectCore.compareAndSwapAuthorityObjectCore`) and the
retained mount; S3 the Authority's narrow pre-Vault read listener (the startup in
`ControlPlane/Runtime.runAuthorityRole` serves it while the Vault-dependent
store and birth steps retry); S4 the TokenReview-bound local/control identity and
the host command; S5 the scenario assertions (the case-4 baseline becomes the
narrow-read assertions) and M04-family mutation. S1 is `Lifecycle/
AdmissionLedgerProjection.hs`: no client at all is NeverAdmitted; an in-flight
record is unresolved; a settled tombstone is settled; a compaction floor above
zero proves history even when every record below it is gone; unit-tested against
real `SubmissionLedger` values. No task or acceptance box is checked.

Sixteenth note (2026-11-22), the exact seam for slice S2. The write-ahead mirror
must wrap the compare-and-swap adapter that persists the admission aggregate:
`ModelBCasAdapter` (`Lifecycle/CheckpointAuthority.hs`) offers
`modelBCompareAndSwap :: ModelBCasRequest l value -> m (ModelBCasResult value)`,
and every request constructor (`ModelBInitialize`, `ModelBReplace`, and the two
guarded forms) carries the new value, so a wrapper can compute
`ledgerJournalObservation` from the value about to be committed, write it to the
mounted journal, and only then call the underlying adapter, refusing the commit if
the write fails. The complication found: in registered-RPC mode the persisted
value is an `RpcBirthRecord` (a birth descriptor and phase around the aggregate;
`ControlPlane/RpcAdmissionBirth.hs`, `rpcBirthRecordCodecFor`), reached through
several codec variants (`authorityAdmissionStateCodec`,
`...WithRegisteredClients`, `...WithRegisteredRpc`) and adapters built in
`RpcAdmissionBirth.hs`/`RpcAdmissionBirthRuntime.hs`, so the wrapper has to be
applied where the live adapter for that record is constructed and must project
the ledger out of both the legacy aggregate and the birth record. That is a
deliberate, bounded change in the Authority's startup code with its existing
birth/admission suites (`test/authority-admission`) as the regression net, and it
is the next slice. No task or acceptance box is checked.

Seventeenth note (2026-11-22), slice S2 landed: the mounted journal exists and
is written ahead of every aggregate commit. `ControlPlane/AdmissionJournalMirror.hs`
wraps `AuthorityAdmissionRepository` (the seam found in note sixteen was one level
simpler than the adapter: `compareAndSwapAuthorityAdmission` receives the
aggregate directly): each commit first writes `admission.json`, the operation
labels and states projected from the aggregate's submission ledger, by temporary
file and rename, and only then performs the compare-and-swap; a failed mirror
write refuses the commit. `initialiseJournalMirror` reads the committed admission,
backfills the mirror from it and writes `genesis.json` once; `observeJournalMirror`
reads the volume back as a `JournalObservation` (no genesis is "never initialized",
not empty; a missing or undecodable mirror is unobservable). The Authority's
startup applies it only when the chart's journal volume
(`/var/lib/prodbox/lifecycle-authority-journal`) exists, and if the mirror cannot
be initialized the repository refuses every read and commit (the existing
admission-read cause). `control authority-deploy` now mounts a hostPath directory
`<root>/authority-journal` (operator-created so cleanup stays unprivileged) instead
of an `emptyDir`. Evidence: unit tests (mirror written before the commit, commit
refused when the mirror cannot be written, uninitialized and corrupt mirrors never
read as never admitted); and `test run phase-03` case 3 gained an independent
host-side observation that `genesis.json` and an empty `admission.json` exist on
the retained root after the Authority starts (cases 1 to 4 validated, exit 0,
Docker inventories identical). Not yet done: the journal directory is not in
`control backup`/`restore`; the narrow pre-Vault read listener (S3); the
TokenReview-bound local identity and the host command (S4); the case-4 baseline
becoming the narrow-read assertions plus the M04-family mutation on the read path
(S5). No task or acceptance box is checked.

Eighteenth note (2026-11-22), slice S3 landed: the Authority serves the admission
read while Vault is sealed. A second, narrow listener of the same Authority
process (`ControlPlane/AuthorityJournalReadServer.hs`, port
`authorityJournalReadPort` 8601, owned by `ControlPlane/ListenPort.hs`) answers
`GET /v1/journal/admission` only, from the mounted journal
(`observeJournalMirror` through `classifyAdmission`), before and independently of
the Vault-dependent startup. The caller presents a projected ServiceAccount
token whose audience is this capability's own (`prodbox-authority-journal-read`,
not the Broker's) and whose identity is exactly ServiceAccount
`prodbox-authority-reader` of the Authority's own namespace; the Authority
verifies it with the Kubernetes TokenReview API (the Broker's in-cluster
reviewer, parameterized by audience; the Authority's ServiceAccount is bound to
`system:auth-delegator`). Minting such a token needs the control kubeconfig and no
Vault login or Transit signing, which is the established local/control identity
of the documents. An unauthenticated token is 401; any other ServiceAccount,
audience or namespace is 403; a non-GET or another path is refused. A first
attempt started the listener inside `runAuthorityRole` and the Authority still
exited with `session-acquire/sealed`, because in the Legacy birth mode the
Vault-dependent trust resolution runs earlier in `runRoleServer`; the listener
and a 5 s retry loop now wrap `runRoleServer` for the Lifecycle Authority, so a
sealed Vault no longer crash-loops the process, which keeps serving the read and
retries until Vault is available. `test run phase-03` case 4 now asserts, with
Vault sealed by replacing its Pod: the full service is not ready (`/readyz` 503);
the reader token gets HTTP 200 with `never-admitted`; a `default`
ServiceAccount token with the right audience gets 403 and no token gets 401;
after replacing the Authority Pod while still sealed the read still answers 200
and `/readyz` is still 503 with a `startup_refused` log; unsealing through the
Broker lets the Authority recover. Cases 1 to 4 validated, exit 0, Docker
inventories identical; unit tests pin the access decision (right/wrong
ServiceAccount, audience, namespace, bearer parsing). Still open for A03-02: the
public host command asking the Authority (S4), the comparison against a stale
projection, and the M04-family mutation on the read path (S5); A03-02 is not
checked.

Nineteenth note (2026-11-22), slice S4 landed: the public commands ask the
Authority. `Control/AuthorityJournalClient.hs` is the host's question: when an
Authority Service is deployed it mints a short-lived reader token for the control
identity (ServiceAccount `prodbox-authority-reader`, the journal-read audience;
Kubernetes enforces a 600 s minimum, which a first attempt at 300 s tripped),
opens a loopback-only `kubectl port-forward` to the Authority's `journal-read`
port, retries the read, and parses the verdict; a deployed Authority that cannot
be asked is recovery-required (never absent, never fresh) and no local file is
substituted for it. Only when no Authority is deployed does it use the local
control journal, and the output says which source answered. `control
lifecycle-status`, `control delete` and the ordinary `delete --yes` all use it.
`test run phase-03` now also observes, with the Authority deployed, that the
public status answers `never-admitted [source: the Authority's journal]`, and,
with Vault sealed, that the same status answers from the Authority, that
`delete --yes` answers "Nothing to delete" and Vault is still sealed afterwards
(no unseal, no initialization). Cases 1 to 4 validated (case 3 six observations,
case 4 nine), exit 0, Docker inventories identical. A first run failed honestly
twice before the fix: an invalid token duration, and an uncaught HTTP exception
while the port-forward was still starting (the retry now covers it). A03-02 is
not yet checked: the catalog row also asks for the Broker and registry being down,
source/age retained on read-only facts, a comparison against a stale projection,
and the M04-family mutation on the read path.

Twentieth note (2026-11-22), Authority discovery fail-closed correction.
`currentAdmission` previously treated every failed Kubernetes Service lookup as
absence and could answer from the local journal, including during a control
cluster outage. It now distinguishes an observed absent Service from a failed
lookup and refuses if the retained Authority journal directory exists while the
Service is absent. This follows A03-02's requirement that a stale projection
cannot authorize mutation or clean completion (acceptance_cases.md, A03-02).
Unit cases cover an invalid kubeconfig and retained journal without a kubeconfig;
the build and real scenario validation remain pending. This does not complete
A03-02 or establish that all lost-history cases are detected.

Twenty-first note (2026-11-22), restart must preserve write-ahead evidence.
The previous initializer rewrote `admission.json` from the committed aggregate
on every restart. A crash between the mirror write and compare-and-swap could
therefore erase an unresolved intent. Initialization now compares an existing
mirror with the committed aggregate and refuses a mismatch or unreadable mirror;
it also refuses a mirror without genesis. A unit case records an interrupted
intent and checks that restart leaves it intact and refuses. Its build and test
are pending, as is rerunning M04 against the updated source binding. This does
not settle concurrent writers: competing mirror writes can still race before
their compare-and-swap, and serialization plus crash-safe recovery and real
concurrency acceptance remain required before the journal can qualify P03-T01
or P03-T02.

Twenty-second note (2026-11-22), concurrent mirror writes. A retained directory
guard is now acquired atomically before a mirror write and removed only after a
successful aggregate commit. Another writer is refused, and reads while the
guard exists are unobservable; a failed or interrupted commit retains the guard
on restart. Unit cases exercise an overlapping writer and an ambiguous failed
commit. The build and these tests are pending. This guard has no supported
reconciliation/removal operation yet, and neither crash durability nor atomic
admission across a subsequent command has been established. Real crash and
concurrency acceptance, recovery, and the updated mutation run remain open.

Twenty-third note (2026-11-22), journal write ordering. Mirror and genesis
writes now sync the temporary file before rename and sync the containing
directory afterward; creation and removal of the write guard also sync that
directory. Failure to sync refuses the write. This is an implementation step,
not proof of power-loss durability: filesystem behavior, interrupted-write
recovery and real failure-domain tests remain unverified. The Authority journal
module compiled as part of the ongoing full build; tests and the complete build
remain pending.

Twenty-fourth note (2026-11-22), guard observation. Guard checks now use a
non-following filesystem observation: a dangling symlink or any other existing
entry counts as a guard, and an observation error does not count as absence.
A unit case covers the dangling-symlink control. The ongoing build compiled the
previous revision of this module, so an incremental rebuild is required after it
finishes. Automatic guard clearing remains unsafe without independent settlement
of the original compare-and-swap; an equality read alone cannot prove that an
earlier request is no longer in flight.

Twenty-fifth note (2026-11-22), host-side Authority discovery. The host now
observes the kubeconfig and retained-journal paths without following links and
refuses observation errors; a dangling retained path cannot be recoded as a
fresh deployment. A unit case covers that control. Build and behavioral proof
are pending, and this does not address loss of all retained identity evidence.

Validation update (2026-11-22): the current executable and unit suite built.
The `admission history` selection passed all 20 unit cases, including the
guard, interrupted write and host discovery controls; the Phase 3 reviewed
mutation-binding alignment test also passed. These are not real concurrent or
crash acceptance, and the mutation execution remains open. Phase 2 has since
been reopened for backup content integrity and must be revalidated first.

- [ ] **P03-T01** — Implement the actual durable Authority journal, public non-secret metadata projection, local backup/restore and validated operation identity. Host bootstrap metadata locates the Authority but is not a competing cloud-state writer.
- [ ] **P03-T02** — Implement shared observe/plan/execute/read-back and operation recovery across CLI/test/maintenance. Keep resource truth, checkpoint usability, credential state and audit evidence distinct; register intent before any future cloud effect can be authorized.
- [ ] **P03-T03** — Activate public delete/status/plan/operations resume for delivered scopes. A never-admitted delete does not call AWS or initialize Vault. An unresolved journal or stale projection cannot license NoChange or mutation.
- [ ] **P03-T04** — Implement obligation-aware control removal and exact test-root cleanup separately from AWS deletion. Preserve required management plane and evidence for pending/unknown cloud obligations.
- [ ] **P03-T05** — Implement advanced audited unlock-bundle/Transit rotation, PKI status/real issuance and bounded ambiguous-init recovery using the retained journal. Bind confirmation to original scope/generation; refuse stale/missing evidence rather than overwrite retained data.
- [ ] **P03-T06** — Run real crash/restart/concurrency/resume, missing/corrupt journal, sealed/unreachable component, no-op and advanced Vault cases. Remove cascade from the new active surface; route any original-install cleanup only through the ledger-bound migration lane.

Fresh admission-history reads authenticate through local/control identity without Vault login/Transit; prove same-Authority metadata startup and read while Vault is sealed. Secret/provider effects remain unavailable without their normal capabilities. A stale projection cannot supply NeverAdmitted.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-03`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [x] **A03-01** — the 16:46 operation canary's two traced no-op deletes, retained live kind identity, independently absent Vault and exact supported first-runtime cleanup are recorded above.
- [x] **A03-02** — sealed-Vault read, restart, adverse identities and exact cleanup qualified in the 19:39 evidence above.
- [ ] **A03-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-06** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M04, M05 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Authority journal and metadata, local backup, advanced Vault key/certificate generations and exact operation records. Preserve management trust, unresolved recovery material and bounded completion reports. No cloud resource family is claimed before its implementation phase.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/lifecycle.md](../documents/engineering/lifecycle.md)
- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
- [documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [ ] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [ ] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

Actual public local/never-admitted and advanced Vault workflows pass, one durable writer survives restart, and all owned legacy routes are retired without depending on later AWS implementation.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
