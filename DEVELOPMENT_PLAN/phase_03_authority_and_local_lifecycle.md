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
**Evidence**: No current implementation/completion evidence recorded. Historical results are regression inputs only.

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

- [ ] **A03-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A03-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
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
