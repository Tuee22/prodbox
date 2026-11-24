# Phase 02: Real Vault, MinIO, and Bootstrap Recovery

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target implementation contract; documentation adoption does not certify runtime behavior.

> **Purpose**: Actual Vault/MinIO/Broker services boot and recover from retained artifacts; test-only MinIO self-unseal and protected production unlock behave distinctly and preserve the same Vault identity.

**Phase**: 2
**State**: Active
**Prerequisites**: Phase 1 complete. No registry service, AWS, public DNS, SES, application platform or later Authority implementation is needed for this bootstrap-owned scope.
**Acceptance**: A02-01, A02-02, A02-03, A02-04, A02-05, A02-06 in [acceptance_cases.md](acceptance_cases.md).
**Critical mutations**: M03 in [mutation_cases.md](mutation_cases.md).
**Owned removals**: L06, L07 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Inherited removals**: B026, B041, B053, B054 in [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md).
**Evidence**: Acceptance, mutation (M03) and cleanup observations are bound in [evidence/phase_02_validation.md](evidence/phase_02_validation.md); L06, L07, B026, B041, B053 and B054 are closed for the new bootstrap path, with original-install residuals under L18.

[Resume from the numerical queue](README.md#resume-here). Follow [development_plan_standards.md](development_plan_standards.md); this file owns its tasks and closure, not another queue.

## Public outcome and scope

Actual Vault/MinIO/Broker services boot and recover from retained artifacts; test-only MinIO self-unseal and protected production unlock behave distinctly and preserve the same Vault identity.

Only capabilities delivered through this phase may be active in its public commands. Later capabilities stay explicitly unavailable; do not add successful stubs or private-only replacements and postpone public use to Phase 10.

## Implementation tasks

Entry check corrected 2026-11-20 (nothing implemented yet). An earlier note here
reported the MinIO artifact as unobtainable because `quay.io/minio/minio` and
`docker.io/minio/minio` no longer serve the old tag; that was the wrong
artifact. The repository's pinned bootstrap artifacts are built from source by
`Prodbox.Infra.BootstrapImageSource`/`BootstrapImageSourceNative` (pinned
GitHub source archive digests, the Go 1.23.4 SDK, `proxy.golang.org`, a pinned
BusyBox base and a pinned golang image), producing
`docker.io/prodbox/minio-bootstrap:RELEASE.2024-12-18T13-15-44Z-source-v1` and
`docker.io/prodbox/mc-bootstrap:RELEASE.2024-11-21T17-21-54Z-source-v1`. All of
those inputs resolve today, and running `ensureBootstrapSourceArtifacts` for
amd64 completed (exit 0) with image identities
`sha256:cae6705a9b5637230a245c43349f023322df0f765e7656afdc567742a1133395`
(server) and
`sha256:82b3d3213fdce09a64f6dbe0560cf1f869b7ea6ee6106c1cc39a01696e21ffa7`
(client), retained under `.build/bootstrap-images-v1`. So P02-T01 is not
blocked on an external artifact. Vault is `docker.io/hashicorp/vault:1.18.3`.
The Phase 2 services, policies, `test run phase-02` scenario and its negative
controls are still unimplemented.

Measured before encoding (2026-11-20, hand probe on a throwaway Phase 1 cluster,
not qualifying evidence; the cluster was removed through public `control delete`
and its scratch root removed without elevation). (1) Both source-built
archives and the Vault image import into the node's containerd with
`docker exec -i <node> ctr --namespace k8s.io images import --all-platforms -`
fed on stdin (MinIO 2 s, Vault 7 s, the node needs no registry). Pull by
digest then `docker save` produced an archive with no tag that `ctr` imported
silently as nothing, so Pods got `ErrImageNeverPull`; the image must carry a
tag (`docker tag` the digest reference to `docker.io/hashicorp/vault:1.18.3`)
and the pin is then verified from the Pod's reported `imageID`. Vault 1.18.3
index digest `sha256:8f1ba670da547c6af67be55609bd285c3ee3d8b73f88021adbfc43c82ca409e8`
(amd64 manifest `sha256:29643552...becf`). (2) The source-built MinIO (entrypoint
`/usr/bin/minio`, user 1000) runs with `imagePullPolicy: Never`, `server /data`
and a hostPath under the retained root, reaches `Ready` on
`/minio/health/ready` and writes `.minio.sys` as the operator's uid 1000, so
the data is removable without elevation. (3) Vault 1.18.3 as uid 1000 with the
file backend on a retained hostPath, `disable_mlock`, and a ConfigMap `vault.hcl`
starts sealed and uninitialised; `operator init -key-shares=1 -key-threshold=1`,
`operator unseal`, enabling `secret/` (kv-v2) and a put/get round trip returned
the marker, and every file in the retained directory was operator-owned. The
operator created each hostPath directory beforehand (`type: Directory`). The
init output (unseal key and root token) was written to a private scratch file
and shredded; no secret value was recorded. None of this is the Phase 2
implementation: there is no public command, no write-ahead record, no pinned
archive verification, no MinIO-backed unlock object, no policy separation and
no scenario yet.

First public slice of P02-T01 (2026-11-20). `prodbox control services` (new leaf,
disposition C149, test identities only) deploys the pinned MinIO and Vault into
a created Phase 1 environment from local artifacts, in this order: (1) prove the
pinned management policy is enforced by real sockets before any secret exists
(`observeNetworkEnforcement`; refuse and create nothing otherwise); (2) take
the source-built MinIO archive from `ensureBootstrapSourceArtifacts` and save
the digest-pinned Vault image to `<root>/service-images/` with its SHA-256;
(3) import both into the node's containerd and require the reference to be
listed; (4) create the operator-owned `minio-data` and `vault-data` directories,
the random MinIO bootstrap credential (a cluster Secret plus a 0600 file under
`<root>/control/`, never printed) and apply the management namespace, the
pinned policy and the two Pods with pull policy Never; (5) wait for Ready and
read both directly through the API server's pod proxy. Real run on a throwaway
environment: all twelve steps ok in about 76 s, the pinned policy's default-deny
did not break the kubelet probes or the proxy reads, MinIO answered
`/minio/health/ready`, Vault answered `initialized=false sealed=true`, the
MinIO Pod's reported `imageID` equals the source-built archive identity
`sha256:cae6705a...3395`, a second run was idempotent (12 ok), and the
environment and its scratch root were removed without elevation. First-run
defects: the bounded subprocess input ceiling (256 MiB) refused the 486 MB Vault
archive silently as "not listed" (now 1 GiB, and the refusal is reported);
HLint caught a needless concatenation. Gate green (10,064 plus 935 tests) after
accepting the regenerated command goldens. Not yet done for T01: the Bootstrap
Broker and bounded workers, write-ahead records beyond a single attempt/result
pair, pinned-archive verification of the Vault archive against a recorded
digest, status through `control status`, and the `test run phase-02` scenario
with its adverse controls, so no box is checked and no A02 case has evidence.

Second slice, test self-unseal and the first scenario (2026-11-20). New public
leaf `prodbox control unlock` (disposition C150) and `prodbox test run phase-02`.
`control services` now also imports the pinned MinIO client archive, creates
the `minio` and `vault` Services and an `mc` client Pod labelled as a
management client. `control unlock` selects its policy from the environment
alone (`unlockPolicyFor`: test environment -> `TestSelfUnseal`, anything else
-> `ProtectedProduction`, which refuses before reading any unlock material),
then: reads Vault's state through the API server pod proxy, creates the
`prodbox-bootstrap` bucket through `mc`, and either (uninitialized, no object,
no pending record) initializes Vault once with one key share, writes the
unlock bundle (scope, root generation, unseal key, root token) first to a
private 0600 pending file and then to `vault-unlock-test.json` in this
environment's MinIO with a read-back comparison before clearing the pending
file, unseals, and proves an authenticated KV write and read of a fresh
marker; or (initialized, sealed, matching object) self-unseals from the
object; or refuses. `initialisationAllowed` is the single pure rule: only an
uninitialized Vault with no object and no pending record may be initialized,
so an initialized Vault with no object is reported as a data-loss condition and
an object naming another environment or root generation is refused, never
re-initialized over. Secrets are bytes in memory and stdin only (Vault's CLI
refuses stdin for `operator unseal`, measured, so the key goes to
`vault write sys/unseal key=-`); nothing is printed, logged or in an argument
vector. Defects found by the real runs: no Services existed so `mc` could not
resolve `minio` (fixed); `vault operator unseal -` treated `-` as the key (a
400 "must be a valid hex or base64 string"); a first scenario counted a
per-run marker as a persistent secret (the fixture now writes a separate
persistent secret). Real scenario result (`test run phase-02`, fresh
environment, exit 0, four reports `EvidenceChecksSatisfied`, Docker
inventories identical, scratch root removed without elevation): case 1 services
Ready, Vault initialized exactly once, the unlock object present in MinIO and a
direct KV read by the runner using the token it read from the object; case 2
the Vault Pod replaced, observed sealed through the proxy, self-unsealed, the
same Vault cluster id and the runner-written persistent secret intact; case 4
with the Vault sealed, (a) the unlock object removed -> refused as
data-loss and nothing initialized, (b) the object's root generation tampered
-> refused, (c) the MinIO Pod removed -> refused with Vault unchanged, (d) a
production-declared configuration -> refused before any read, and after
restoring the object unlock succeeds with the same cluster id; case 5 the whole
environment deleted and recreated, the Vault came back sealed over its retained
host data, self-unsealed from the retained MinIO data with the same cluster id
and the persistent secret intact, and exact cleanup left the host data. Unit
tests pin `bootstrap.production_rejects_test_unlock` and
`bootstrap.preserves_vault_incarnation` (the M03 assertions); the gate is green
(10,068 plus 935 tests). Not done, so no task or A02 box is checked: the
Bootstrap Broker and bounded workers (T01, T05), a MinIO credential scoped to
the unlock object separate from the bootstrap root credential (T02), direct
status in `control status` (T03), protected-production interactive unlock
and wrong-key/interrupted-initialization/Broker-outage/wrong-password cases
(T03, T04, A02-03, A02-04), local backup and restore (T04), concurrent secret
workers and management-policy traffic across recreation (T05, A02-05), and M03
through the mutation executor (T06). The MinIO bootstrap root credential still
reaches the `mc` Pod through a Secret in the management namespace, which the
default-deny policy protects only at the network layer.

Third slice, scoped unlock capability, status, wrong-key/interrupted cases and
M03 (2026-11-20). (1) T02: `control services` creates a second MinIO user whose
policy allows exactly `s3:GetObject` on `prodbox-bootstrap/vault-unlock-test.json`
(random credential, 0600 file plus Secret, never printed) and self-unseal now
reads the unlock object only with that user; the bootstrap root credential
writes it. The runner checks the reader can read the object but cannot write
another object or list the bucket. (2) T03: `control status` now prints direct
service status read through the API server pod proxy (`Services: MinIO ready;
Vault initialized=true sealed=false.`), unobservable services are reported as
such. (3) Case 4 gained a well-formed but wrong stored unseal key (refused,
Vault stays sealed and initialized, nothing re-initialized) and an interrupted
upload (object removed, private pending record holding the bundle: the next
unlock continued it, read it back, removed the record and unsealed with the
same cluster id). Real `test run phase-02` result on a fresh environment, exit 0:
case 1 six observations, case 2 four, case 4 seven, case 5 four, all
`EvidenceChecksSatisfied`, inventories identical, scratch removed without
elevation. An intermediate run exposed a fixture mistake worth keeping: I
extended the claim and independent lists but not the name list, and `zipWith`
silently truncated the two new observations, so case 1 reported only four; the
report was not counted until its observation count matched. (4) T06/M03: two
reviewed candidates in `Prodbox.Test.ReviewedMutation` (source digest of
`Unlock.hs` `29374f1c...f5f07`, bindings recorded in `mutation_cases.md`, an
alignment unit test): M03a makes `unlockPolicyFor` select the test policy for
every environment and M03b makes `initialisationAllowed` ignore a recorded
unlock object. Through the bounded mutation executor in its no-network
container both were Killed by their designated assertions
(`bootstrap.production_rejects_test_unlock` and
`bootstrap.preserves_vault_incarnation`), alongside the Phase 1 cases (M01, M02
Killed; survivor Survived; invalid Invalid; timeout Inconclusive). Still not
done, so no box is checked: the Bootstrap Broker and bounded workers (T01,
T05), protected-production unlock with an interactive prompt and a NeedsInput
result (T03, A02-03), the wrong-password and Broker-outage cases, local
backup and restore (T04), concurrent secret workers and policy traffic across
recreation (T05, A02-05).

Fourth slice, protected unlock (2026-11-20). New leaf `prodbox control protected-unlock`
(disposition C151, test identities only): read Vault's state through the pod
proxy first; for an initialized, sealed Vault ask for the unseal key at a hidden
prompt (terminal) or one line of standard input, send it with `vault write
sys/unseal key=-`, and never read the environment's MinIO or unlock object.
Absent or empty input is the distinct result `Needs input: ...` that changes
nothing (the prompt only appears when Vault needs a key); a wrong key is
refused; an uninitialized Vault is refused, not initialized. Real
`test run phase-02` result (exit 0, five reports `EvidenceChecksSatisfied`,
inventories identical, scratch removed): the new case 3 observed, with the
Vault replaced and sealed, that empty standard input gives `Needs input` and
leaves it sealed, a well-formed wrong key is refused and leaves it sealed, and
with the MinIO Pod deleted the operator's key (read by the runner from the
bundle, acting as the operator) unseals it with the same cluster id, which
also shows the path does not depend on the test self-unseal material; MinIO was
restored afterwards through `control services`. Case 4 already carries the
"test policy in production" refusal. Limits: the terminal prompt branch
(`hSetEcho`, hidden input) is implemented but exercised only through the
non-terminal standard-input branch, since the runner has no pseudo-terminal;
there is no production environment to run this against in Phase 1's
admission, so protected unlock is exercised on a test identity; no `protected`
bundle custody or rotation exists (Phase 3). Still open, no box checked: the
Bootstrap Broker and bounded workers, wrong-password and Broker-outage cases,
local backup and restore, concurrent secret workers and policy traffic across
recreation.

Fifth slice, limits and concurrency, backup and restore (2026-11-20). (1) The three
service Pods now carry requests and limits (Vault 128Mi/512Mi, MinIO
256Mi/1Gi, mc 32Mi/512Mi since the thirteenth slice). New case 6 of `test run phase-02` runs eight
concurrent authenticated KV writers and eight concurrent readers against the
real Vault (each fetching the token from the unlock object through MinIO) and
every value reads back; afterwards no service Pod had restarted or been
OOM-killed and the declared limits were read back from the API server. This is
concurrent clients through the real services, not the separate bounded worker
Pods the plan describes, so the worker half of T05 stays open. (2) T04: new
leaves `control backup` and `control restore BACKUP --yes` (dispositions C152,
C153, test identities only). Backup stops the Vault and MinIO Pods, copies both
data directories with `cp -a` into `<root>/backups/<name>/`, writes a manifest
(scope, root generation, SHA-256 over the sorted file list and sizes) and
starts the Pods; restore verifies the manifest against this scope, generation
and the files, stops the Pods, moves the current data aside as
`replaced-<name>-*` (nothing is deleted), copies the backup in and starts the
Pods, and Vault comes back sealed. Real result in case 7: a secret written
before the backup was read back after a later overwrite and a restore (the
overwrite was gone), the Vault came back sealed then self-unsealed with the same
cluster id, a copy of the backup with a wrong manifest digest was refused with
the live data and secret untouched, and the replaced vault data was kept.
Whole scenario: seven reports (cases 1, 2, 3, 6, 7, 4, 5) `EvidenceChecksSatisfied`,
exit 0, inventories identical, scratch root (backups and replaced data
included) removed without elevation. One earlier full run failed two case-4
observations (the bucket step could not reach MinIO around the generation
tamper step) while a full `cabal build` was compiling on the same host; two
later runs without concurrent builds passed, so this is recorded as an
unexplained intermittent that correlates with host load, not as fixed. Still
open, no box checked: the Bootstrap Broker and separate bounded worker Pods
(T01, T05), the wrong-password and Broker-outage cases, management-policy
traffic across recreation with real workers (A02-05), and a hidden-terminal
prompt exercise.

Sixth slice, the real Bootstrap Broker (2026-11-20). `control services` now also
deploys the repository's own Bootstrap Broker (`bootstrap-broker start`) next to
MinIO and Vault and waits for the Broker's own loopback `/readyz` to answer
`ready:true`; `control status` prints `Broker ready` or `Broker unobservable`
next to the MinIO and Vault facts. Measured by probing a hand deployment first:
the Broker enforces its prerequisites one readiness refusal at a time, in this
order: the OpenPGP boundary needs `/usr/bin/gpg`; a Lease read needs a
namespaced Role (pods create/list, the fence Lease get/update/create) plus a
TokenReview ClusterRole and the ServiceAccount `prodbox-bootstrap-broker`; its
own Pod observation needs the chart identity (labels
`app.kubernetes.io/name=prodbox-bootstrap-broker` and
`app.kubernetes.io/instance=<namespace>`, the container named
`bootstrap-broker`); and the Pod image repository must be
`127.0.0.1:30080/prodbox/prodbox-runtime`. Its store reaches MinIO under the
compiled bootstrap-floor credential (`minioRootUser`/`minioRootPassword`), so
MinIO's root credential in `control services` is now that constant instead of
the per-environment random one I used before (the unlock-object reader stays
random and scoped); this is the only way the unchanged Broker code can use the
store and it weakens the earlier credential hygiene, to be revisited by the
removal rows that retire the static credential. The runtime image is built
locally by `docker build` from this binary, the host's gpg and its libraries
on the digest-pinned Ubuntu base, saved under `<root>/service-images/` and
imported into the node (not re-imported when already registered); it is not a
reproducible pinned artifact and needs the host's gnupg. Real
`test run phase-02` result on a fresh environment, exit 0, eight reports
`EvidenceChecksSatisfied` (cases 1, 2, 3, 6, 7, 8, 4, 5), inventories identical,
scratch removed without elevation: case 1 now also observes the Broker ready
by the runner's own read of its readiness route, and the new case 8 deletes the
Broker Pod and shows `control status` naming the Broker unobservable while
Vault (read directly) and MinIO are still reported, then `control services`
restores it. Defects found by the real runs: `docker build` failed with
`mkdir /nonexistent` under the restricted environment (it now gets a private
writable home and DOCKER_CONFIG); one run failed a case-4 observation with
`container not found ("mc")` after repeated image imports under running Pods,
which the skip-if-already-registered check removed in the next run (not proven
to be the cause). Not done, so no box is checked: the Broker does not yet
mediate initialization or unseal (`control unlock` still runs its own
test-environment path beside it), no one-shot worker Pod has been created or
exercised, and management-policy traffic between real workers across recreation
(A02-05) remains open, as do the hidden-terminal prompt and Vault Kubernetes
auth for the Broker.

Seventh slice, the Broker in the chart's own layout and its authenticated route
(2026-11-20). The Broker is no longer a bare Pod in the management namespace:
`control services` now deploys it as the chart does (namespace
`bootstrap-broker`, Deployment and Service `bootstrap-broker` with the named
port `broker`, the three ServiceAccounts, the TokenReview ClusterRole, the
worker-observer and worker-self-observer Roles) because the repository's host
client (`withBrokerHostConnection`) is hardwired to that namespace, Deployment
and Service. Two more of the Broker's own decoder requirements surfaced and are
recorded: its Pod observation requires `metadata.annotations` to exist (a bare
Pod got one from `kubectl apply`, a Deployment template does not), so the
template carries `prodbox.io/image-build-id`; and the pinned management policy
now also admits ingress from the `bootstrap-broker` namespace so the Broker can
reach MinIO and Vault (digest re-pinned in the unit test:
`7aa5663a...28c3`). New leaf `prodbox control vault-status` (C154, test
identities only) makes the real authenticated host call end to end: a
custom-audience TokenRequest for the secret-free client ServiceAccount, the
bracketed loopback port-forward, the Broker's TokenReview of that token and the
closed read-only `vault/status` route, with `KUBECONFIG` pinned to the
environment's installed credential. The same call also works through the
legacy `prodbox vault status` when `KUBECONFIG` is pinned the same way. Case 1
of `test run phase-02` gained `broker.authenticated-vault-status` and case 8
now takes the Broker down by scaling the Deployment to zero (the Deployment
would otherwise recreate a deleted Pod at once) and waits for its Pod to go
before reading status. Real result, exit 0, eight reports
`EvidenceChecksSatisfied` (cases 1, 2, 3, 6, 7, 8, 4, 5, case 1 with eight
observations), inventories identical, scratch removed without elevation. Found
on the way: the legacy `prodbox vault init` refuses to run because
`test-secrets.dhall` is mode 0644 and it requires 0600; that file is the
user's and was not changed, so the legacy Broker-mediated initialization path
cannot be driven until the user runs `chmod 600 test-secrets.dhall` (or a
different password source is designed). Still open, no box checked: Broker-
mediated initialization and unseal (the test self-unseal in `control unlock`
still runs beside the Broker), one-shot worker Pods, Vault Kubernetes auth
for the Broker's roles, management-policy traffic between real workers
across recreation (A02-05), and the hidden-terminal prompt exercise.

Eighth slice, Broker-mediated initialization attempt (2026-11-20, not working yet).
New leaves `control broker-init` and `control broker-unseal` (C155, C156, test
identities only): read the operator password at a hidden prompt or one line of
standard input (absent input is `Needs input`, nothing changes), then call new
`brokerInitializeSelected`/`brokerUnsealSelected` in `Prodbox.CLI.Vault`, which
are the legacy init/unseal sequences with the cluster selected by an explicit
environment and the password supplied by the caller instead of read from
`test-secrets.dhall` (that file is untouched). The shared hidden-prompt reader
moved to `Prodbox.Control.OperatorInput`. Real measurements on a throwaway
environment: with no input the command refuses without touching anything; with
a password the Broker launches its one-shot secret workers. First failure:
`Compiled burn recipient verification failed` because `gpg` starts `gpg-agent`
and exits non-zero when it is absent, so the runtime image now carries
`gpg-agent` and `gpgconf` and the union of their libraries (gpg imported the
compiled burn key fine from the shell once the agent was reachable). Second
run: the prepare-initialization worker succeeded (the store now holds
`prepared-init-envelope`, `root-init-journal`, the worker checkpoint and result
objects, and `vault-status` through the Broker reports
`initialization_phase: init-call-pending`), then the resume-initialization
worker terminated with `Bootstrap secret-worker result publication failed`, which
the worker deliberately reports without a cause. A redeploy in between left the
Broker's session fence held (`BootstrapFenceAcquireOverlap`, HTTP 409), so each
retry started from a fresh environment. Cause of the publication failure not
found: the worker's store write and fence authorization are the suspects
(`publishProductionSecretWorkerResult`), and diagnosing it needs the worker's
own error, which the design hides. So Broker-mediated initialization does not
yet complete; nothing in the passing scenario depends on it. Open, no box
checked: finishing the initialization sequence, Broker-mediated unseal
(and the wrong-password refusal), Vault Kubernetes auth for the Broker's
roles, management-policy traffic between real workers across recreation
(A02-05) and the hidden-terminal prompt exercise.

Ninth slice, Broker-mediated initialization and unseal now work (2026-11-20).
Root cause of the eighth slice's resume-worker failure: the worker's GET of
`secret-worker-checkpoint.result-v1` failed with http-client's
`NoResponseDataReceived`, a pooled keep-alive connection that MinIO had already
closed while the worker spent seconds in its password KDF between requests; the
store boundary collapses every such transport error into the opaque
`BootstrapStoreUnavailable`. Found by temporarily instrumenting the worker (the
instrumentation was removed; a direct probe had first shown MinIO's `If-None-Match`
and `If-Match` conditional puts behave correctly). Repair: every object-store
request now carries `Connection: close` (`ObjectStoreNative.performS3WithDeadline`).
Result on a fresh environment through the unchanged Broker and its one-shot
workers: `control broker-init` completes in about 27 s (status then reports
`initialized: true`, `initialization_phase: custody-durable`,
`recovery_custody_durable: true`), `control broker-unseal` with a wrong
password is refused by the worker and Vault stays sealed, and with the right
password it unseals once the failed session's 300 s fence lease has lapsed (an
immediate retry gets HTTP 409 `boundary-refused`, the Broker's designed
crash-safety). New scenario `test run phase-02-broker` (a fresh Vault is needed,
so it is separate from `phase-02`): four reports `EvidenceChecksSatisfied`, exit
0, inventories identical, scratch removed without elevation. Case 1: no input
gives `Needs input` and Vault stays uninitialized; the Broker initializes it and
Vault's own health (read through the pod proxy by the runner) agrees; custody is
durable. Case 2: a wrong operator password is refused, Vault sealed. Case 3: the
right password unseals (`changed: true`, health unsealed) and a repeat is
`already unsealed`. Case 4: the Vault Pod is replaced, comes up sealed over its
retained data and the Broker unseals it with the same cluster id; neither
password appears in any command output (checked by the runner), and cleanup
leaves the host data. Limits: the operator password is generated by the runner
and passed on standard input (the hidden terminal prompt branch is still not
exercised); the wait for the fence lease makes the scenario about eight
minutes; Vault Kubernetes auth for the Broker's roles, the Broker's post-unseal
handoff and baseline reconcile, management-policy traffic between real workers
across recreation (A02-05) and the TTY prompt exercise remain open, and
`control unlock`'s own test self-unseal still runs beside the Broker path. No
box is checked.

Tenth slice, the Broker's baseline and Vault Kubernetes auth (2026-11-20). New
leaf `control broker-baseline` (C157): operator password on standard input or
the hidden prompt, then the Broker's closed baseline-reconcile sequence
(`brokerBaselineSelected`: a one-shot worker completes the generated root under
the password and the Broker applies Vault's authentication and policy
baseline). First attempt failed with `EngineBaselinePhysicalCallRefused
(baseline-stage=prove-current-root-accessor-absent; ... auditor-login/status-403)`:
the Broker logs in to Vault's Kubernetes auth as its own ServiceAccount, and
Vault could not validate the token because its Pod ran as the default
ServiceAccount, which may not call TokenReview. The legacy chart gives Vault its
own ServiceAccount and the `system:auth-delegator` ClusterRoleBinding, so
`control services` now creates ServiceAccount `vault` and ClusterRoleBinding
`<namespace>-vault-token-reviewer` and runs the Vault Pod as it. After that the
baseline completes in about 8 s. Independent check (case 5 of
`test run phase-02-broker`, five reports `EvidenceChecksSatisfied`, exit 0,
inventories identical): before the baseline a Kubernetes-auth login as the
Broker's ServiceAccount is refused; after it, the login for role
`prodbox-token-accessor-auditor` succeeds (policies `default` and
`prodbox-token-accessor-auditor`, 300 s TTL, token never printed) while the same
login as the namespace's default ServiceAccount is refused. The Vault role named
`prodbox-bootstrap-broker` still answers 403 for the Broker's own ServiceAccount;
that is by design (see the thirteenth slice).
The post-unseal handoff reconcile was tried through the Broker and answers
`EnginePhysicalCallRefused (boundary-unavailable)` because its target is the
control plane's Authority, which does not exist before Phase 3, so no public
command was kept for it. `control services` changed (Vault ServiceAccount), so
the main `phase-02` scenario was re-run twice: the first run failed one case-4
observation again with `kubectl exec ... container not found ("mc")` at the
generation-tamper step, the second (with a diagnostic added) passed all eight
reports and showed the `mc` Pod with restart count 0, so this recurring
intermittent (three failures in about eight full runs) is not a restart or
OOM of that container and remains unexplained; it looks like an exec race
against the container runtime. Still
open, no box checked: management-policy traffic between real workers across
recreation (A02-05), the hidden-terminal prompt exercise, the Vault secret
round trip through the Broker-issued path (the current `control unlock` test
path remains separate), and the Phase 2 removal rows.

Eleventh slice, the hidden-terminal prompt (2026-11-20). Case 3 of
`test run phase-02` now also runs `control protected-unlock` on a real
pseudo-terminal (python3 `pty`, isolated mode, no secret on the command line):
it waits for the prompt, types a synthetic wrong key, and the independent
observations are that the prompt appeared, the typed text was never echoed into
the terminal transcript, Vault refused the key and stayed sealed. The scenario
passed with all eight reports `EvidenceChecksSatisfied` (exit 0, inventories
identical). Residual: the right-key path is still exercised only through
standard input, and the check depends on `/usr/bin/python3` in the harness
host.

Twelfth slice, management-policy traffic (A02-05 in part, 2026-11-20). Case 6
of `test run phase-02` now runs two throwaway client Pods from the local Vault
image (never pulled) in the management namespace after the earlier recreation
and the concurrent workers: one labelled `prodbox.io/management-client=true`
fetches Vault's health over the Service and receives the real answer; one
without the label is refused by the pinned NetworkPolicy (non-zero exit, no
answer). Eight reports passed, exit 0, inventories identical. Limits: the
refusal is observed as a failed fetch from an otherwise identical Pod, not
as a packet trace, and the traffic probe runs after the first recreation only,
not again after the final one.

Thirteenth slice, the 403 explained (2026-11-20). `Vault/Reconcile.hs` binds
the Vault role `prodbox-bootstrap-broker` to ServiceAccount
`prodbox-bootstrap-secret-worker` (the one-shot worker), not to the Broker's own
`prodbox-bootstrap-broker` account, so the earlier 403 was the intended
refusal, not a defect. Case 5 of `test run phase-02-broker` now observes both
sides: after the baseline the worker's ServiceAccount logs in under that role
and the Broker's own account is refused (four observations, exit 0,
inventories identical). A first run of this change passed with only three
observations because a name list was not extended and `zipWith` truncated the
fourth; caught by reading the report's observation count.

Fourteenth slice, the `mc` intermittent explained (2026-11-20). A full run
failed from case 1 on, and the diagnostic added earlier recorded the `mc` Pod's
state: restart count 1, last termination `OOMKilled`, exit 137. So the recurring
`kubectl exec ... container not found ("mc")` was the client container being
OOM-killed at its 256Mi limit, not an exec race (the earlier all-pass run had
shown restart count 0). Measured on a fresh environment: the cold container's
cgroup memory peak is already 145 MB (file cache of the large client binary)
before any command, and six concurrent `mc` invocations did not raise it, so the
margin is about 110 MB and the kill happens under extra pressure that I could
not reproduce on demand. The limit is raised to 512Mi (Vault 512Mi, MinIO 1Gi)
for headroom and the scenario's declared-limit observation now expects it. A
bounded retry (three attempts, 3 s apart, only on `container not found`) was
also added to the unlock exec helper in `Control/Unlock.hs`; that file is pinned
for the M03 mutations, so the pinned source digest is now
`29374f1c...f5f07`, the two candidate source digests and binding digests in
`mutation_cases.md` were recomputed (the computation reproduces the old
digests exactly from the old inputs), and the mutation catalog was re-run:
M01, M02, M03a and M03b are Killed on their intended assertions, the survivor,
invalid and timeout controls behave as expected.

Fifteenth slice, the real cause of the `mc` OOM kills and the registry
observation (2026-11-21). The kernel log showed `mc` itself killed with 522 MB
of anonymous memory (so the node, the Pod limit and a race were all ruled out),
and a host-side watcher that logged any `mc` process above a threshold,
with its full command line, caught `mc pipe local/prodbox-bootstrap/vault-unlock-test.json`
at 394 MB RSS in a run that then failed. `mc pipe` of a stream of unknown length
buffers a part-sized allocation; the Pod's limit (256Mi, then 512Mi) was
sometimes exceeded, which also explains why single operations never reproduced
it. All three `mc pipe` uses (the unlock bundle upload in `Control/Unlock.hs`,
the scenario's object restore and its reader write probe) now copy a file of
known size with `mc cp` (file mode 0600 via `umask 077`, removed afterwards). The
M03 pin moved again (`Unlock.hs` digest `29374f1c...f5f07`, candidate and
binding digests recomputed, unit binding test passing) and the mutation catalog
was re-run: M01, M02, M03a, M03b Killed; survivor, invalid and timeout controls
as expected. After the change `test run phase-02` passed in three consecutive
runs with the watcher armed at 200 MB and no process above it (before the
change it failed in about four of twelve). Case 6 of the scenario also gained
the observation for L06: every container in the management and Broker
namespaces has pull policy `Never` and no registry workload exists there.

Sixteenth slice, root-token custody and the inherited removals (2026-11-21).
B041 named unlock-bundle token fields: the new test bundle stored the initial
root token in MinIO. `control unlock` now stores only the unseal key and a
limited client token: after the first unseal it uses the root token once, in
memory, to enable the test KV mount, write a policy covering only that mount,
mint a periodic orphan token under it and revoke the root token; the bundle
object holds `client_token` and never a root token. The root token survives only
in the private 0600 pending file, under its own `pending_root` field, until that
one use (an interrupted upload still continues from it). Case 1 of
`test run phase-02` gained the observation that the stored object has a client
token and no `root_token`/`pending_root` field (nine observations satisfied; all
eight reports pass, exit 0), the M03 pin moved again (`Unlock.hs`
`29374f1c...f5f07`, digests recomputed, unit binding test passing) and the
mutation catalog was re-run with the same outcomes (M01, M02, M03a, M03b Killed;
the three calibration controls as expected). A recovery limit is recorded
honestly: if the process dies after the bundle upload but before the client
token is minted, the root token is lost with it and a later unlock unseals but
reports "no client token is recorded" for the round trip.

Audit of the other inherited rows against the code on this date. B054: no new
ordinary path uses the MinIO port-forward; the new surface reaches MinIO only
through `kubectl exec` into the management `mc` Pod and the Broker's object
capability. B053: the new services expose no NodePort and no host Vault
transport (ClusterIP Services only; the Broker is reached through the
authenticated port-forward of `withBrokerHostConnection`, whose identity, audience
and namespace are checked). B026: the new bootstrap runs through the Broker
subsystem and `control unlock`/`protected-unlock`; the gateway pre-Vault
loader and unlock endpoints are not used by any new route. The remaining
original-install callers are exact and fenced under ledger row L18 (Phase 10):
`Vault/Host.hs` and `EffectInterpreter.hs` calling `withMinioPortForward`, the
legacy `Vault/BootstrapBundle.hs` bundle, the `vault-host` NodePort `31820` in
`charts/vault`, and the pre-cutover gateway bootstrap topology that Sprint `6.5`
cuts over. Those four B rows are therefore Removed for the ordinary path.

- [x] **P02-T01** — Deploy real MinIO, Vault, Bootstrap Broker and bounded workers from exact pinned local artifacts, independent of the registry and public edge they may later support.
- [x] **P02-T02** — Separate bootstrap MinIO access from steady-state Vault-backed MinIO policy. Define the exact pre-Vault read capability for the test run’s unlock object; never rely on the sealed Vault to decrypt its only unlock key.
- [x] **P02-T03** — Implement explicit protected production and test MinIO self-unseal policies. Expose actual direct component status while Broker/Vault/MinIO availability differs. Production cannot load the test policy.
Regression found 2026-11-22: `Control/Backup.hs` `treeDigest` hashes only the
sorted relative paths and file sizes. A disposable file changed from four bytes
`AAAA` to four bytes `BBBB` produced the same manifest digest, so restore can
accept content corruption. The earlier case 7 changed the manifest digest and
did not exercise changed backup content. P02-T04 is reopened; the previous
Phase 2 evidence remains tied to its original implementation and does not prove
this adverse case. Repair the content integrity boundary without logging or
publicly hashing plaintext secrets, add a same-size corruption control, and run
the real backup/restore scenario, applicable mutations and cumulative gate.
Phase 3's later work remains incomplete and its dependent evidence must be
revalidated after this regression is fixed.

Repair in progress (2026-11-22): backup format 2 uses a fresh random key stored
mode 0600 inside the protected backup and keyed commitments over entry names,
types and streamed contents. Commitments and the key remain in that private
backup and are never emitted as evidence; old format 1 cannot establish content
integrity and restore refuses it without deleting it. The Phase 2 real scenario
now attempts a same-size content change in a separate backup copy and checks
that live data remains unchanged. Both changed modules pass a standalone GHC
typecheck against the installed dependency identities; a complete rebuilt binary
and the scenario have not yet been validated. The
key shares the backup's protection and is intended to detect accidental
corruption, not an attacker able to rewrite both key and backup.
An isolated synthetic-file invocation of the actual `treeDigest` function
changed `AAAA` to `BBBB` at the same size and observed distinct commitments
with the same synthetic key (both invocations exited 0); the commitments were
not printed. This is a focused regression check, not the real restore case.
The initial full build failed when its already-built library did not yet export
the helper imported by the new mutation assertion; an incremental rebuild with
the current library and test package definition is in progress. The M03c source
patch and assertion are bound in the mutation catalog, but have not been run.
The streaming loop was subsequently made strict to avoid accumulating deferred
commitment updates; its source and mutation digests were updated. The running
build started before that last edit and must be followed by another incremental
build before its executable is used as current evidence.
The synthetic commitment check was repeated against the strict-loop revision:
the same-size change produced a different commitment, restoring the original
bytes reproduced the original commitment, and all three invocations exited 0.
The current executable and unit suite built successfully, and the focused
backup-content assertion and Phase 2 mutation-binding alignment test passed.
The implemented `prodbox test init` refused because it observed an RKE2 install
marker and reports a possible production cluster. The marker was not changed;
the real A02-06 run and its cleanup are therefore not established by this
attempt. Investigate the supported isolated test entry and the actual production
state before any live scenario; do not bypass this guard or alter the production
installation to obtain a passing test.
The first current `prodbox dev check` stopped in document lint because this
phase's reopened state was written as `Active — reopened` instead of the
recognized `Active`; the phase state has been corrected and the gate must be
rerun.
The rerun passed document lint but was stopped during Haskell lint after a
separate formatter check identified differences in the edited files. Those files
were formatted and mutation source bindings refreshed; the full gate has not
yet passed on the formatted revision.
The repository formatter and targeted HLint both pass on the changed Haskell
files after formatting. A new full build is running for that revision; earlier
unit results do not by themselves prove the formatted build or the full gate.
The current executable's `prodbox dev lint docs` subsequently exited 0; this
is document lint only, not the full canonical gate.
The formatted executable and unit suite subsequently built. On that revision,
the backup integrity assertion and Phase 2 and Phase 3 mutation-binding
alignment selections passed; all 20 admission-history unit cases also passed.
The next full canonical gate failed Haskell style lint because the new test
runner's `find -print` argument triggered the terminal-output token check. The
runner now uses `find -printf` with the same path output and its formatter check
passes. A separate full Haskell lint then found the new `BackupIntegrityTests`
import out of order in `test/unit/Main.hs`; the import was reordered and that
file's formatter check passed. Rebuild and the full gate must be rerun. Real
A02-06 and the isolated M03c execution remain outstanding.
Read-only Docker inspection also found that the mutation executor's pinned node
image `sha256:152b34af...05e4752d` is absent. No image was imported or pulled;
M03c remains unrun until its required isolated executor environment is available.
The unselected `prodbox test run phase-01-mutation` returned "The cumulative
scenario runner is not implemented yet" rather than invoking the selected
handler, so it provided no mutation result. The ordinary public dispatch now
routes that name to the same isolated catalog and refuses unsupported coverage,
AWS substrate and profile options. The rebuilt public binary refused `--coverage`
and `--substrate aws` with exit 1, and the default invocation reached the
catalog's missing-pinned-image refusal with exit 2. No mutant ran; do not count
either refusal as a kill. The running canonical gate was stopped because its
source revision changed and must be rerun after the rebuild.
The refusal is from the legacy topology-driven initializer; the selected-config
Phase 2 handler is a separate implemented route. Its isolated root, artifact
bindings and interaction with the retained installation still need to be
established before concluding whether that route can run safely here.
Format-1 backups remain retained but need an explicitly scoped recovery or
migration disposition before P02-T04 can close; they must not be silently
declared verified or deleted.
Decision (2026-11-22): the documents require preserving retained recovery
material and never inferring usable state from missing evidence
([storage.md](../documents/engineering/storage.md), lines 39–45;
[lifecycle.md](../documents/engineering/lifecycle.md), lines 16–32). Format 1
has no independent content commitment, so
its own metadata cannot prove its contents intact. Retain it unchanged and
require an independently known-good live source or verified backup for a new
format-2 backup; if neither exists, keep recovery incomplete under the original
scope. A future explicit recovery lane must not call the old backup verified
merely because its paths and sizes match. A real test of this disposition is
still required.

Implementation update (2026-11-22): the public restore refusal now names the
retained format-1 backup and the known-good-source/verified-backup requirement.
The Phase 2 scenario has a separate format-1 refusal and retained-copy control;
that control has not run. A synthetic unit case exercises `restoreServices`
against a format-1 manifest and checks both the refusal's recovery input and
retention. A focused GHC execution against the current library passed both this
case and the same-size corruption assertion; this is not real-system evidence.
The later executable/unit build completed, and the rebuilt unit executable
passed both backup cases and the Phase 2 and 3 mutation-binding alignment
selections. The full Haskell lint then reported a redundant map in the new
format-1 test; it was simplified, and that file's formatter and targeted HLint
checks passed. The canonical binary was refreshed after lint exited. The test
edit requires an affected rebuild; the full gate and real-system evidence
remain open.
The affected unit target was rebuilt after that simplification. Both backup
integrity cases and the Phase 2 mutation-binding alignment selection passed;
the canonical gate was rerun on the current code. On 2026-11-22 it exited 0
with repository documentation/style checks, the warning-clean build and gated
unit suites complete. The operator binary SHA-256 was
`2494debab7257741fdd93f126714e3874ce80f706003c5d633a7fdde05998fd9`.
Its scratch log is `.build/canonical-check-current.log`; it is not durable
qualification evidence. The note was added after the run. This gate does not
replace real A02-06 or the isolated M03c run.
The source and M03c binding changed while an older
full unit and lint run were still in progress, so neither running result can
qualify this revision; rebuild and affected checks must be repeated.
The earlier `prodbox-unit` component reported PASS before the runner continued
to its other suites; its input revision predates the refusal-message change.
The overall `prodbox test unit` command later exited 0, but source changes during
that command mean the result is not attributed to a single current revision.
Targeted HLint on the subsequently changed backup, scenario runner and mutation
binding reports no hints. Both current backup and scenario modules also passed
standalone GHC typechecking against the installed project dependencies; this
does not establish that the scenario ran.

- [ ] **P02-T04** — Implement init/unseal/baseline, retained-generation checks, bounded interruption continuation and local backup/restore for this scope. Do not reinitialize over missing/corrupt/foreign retained identity; report the exact data-loss/recovery condition.
- [ ] **P02-T05** — Exercise actual policy traffic and actual concurrent secret workers within Phase 1’s capacity reservation. Observe workload settlement or durable recoverable ownership on every failure/cancellation. Reopened after review of the service gate. On 2026-11-22 the gate was tightened to skip the probe when its attempt write fails and to refuse secret creation unless typed probe cleanup is confirmed and the probe has no primary failure. The probe now records a scope-bound intent and UID under the recovered operation lease, but the service attempt itself is not yet equivalently bound, the fixed probe name does not support a repeat operation, and interruption recovery remains incomplete. Resolve those contracts and revalidate the complete gate before creating secret workers.
- [x] **P02-T06** — Run secret round-trips, real seal/unseal, wrong input/missing custody/outage cases, kind recreation, direct status and M03. Explicit audited Authority-mediated rotation/PKI/reset features belong to Phase 3 and are not a bootstrap closure dependency.

## Real acceptance and independent observation

After implementing the active slice, run the built operator against explicit owned configs through `prodbox test run phase-02`. This target scenario includes prior accepted cases and the new cases listed below; the runner is delivered in Phase 1. Invoke actual public handlers rather than a second harness-only bring-up/cleanup implementation.

The linked catalog defines the exact real workflow and observer for each case:

- [x] **A02-01** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A02-02** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A02-03** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A02-04** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [x] **A02-05** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.
- [ ] **A02-06** — execute and record the cataloged case, its independent observation, adverse control and exact cleanup result.

A result is incomplete if its independent read-back, scope/source binding, worker settlement, or required cleanup is unavailable. Fixture-only provider behavior, source scans, manifest rendering, process exit and old receipts cannot close a real-system claim. Actual input prerequisites are declared above; no acceptance result depends on an unimplemented larger phase.

## Critical source mutations

Run M03 for this phase’s implemented source and applicable delivered adapters, plus affected earlier critical cases. A passing unmodified baseline is required. The actual mutated implementation must compile and trigger its designated unchanged assertion; compilation errors are Invalid, unrelated failures/timeouts are Inconclusive, and a surviving non-equivalent critical fault blocks closure. Record reviewed equivalence exclusions rather than silent skips.

Dangerous mutants execute offline in an isolated non-secret snapshot. They receive no production roots, real AWS credentials, elevated fixture input, current kubeconfig, unrestricted runtime socket or publication capability. Unmodified outer isolation/cleanup verifies any reviewed disposable local fixture. Real AWS/public-edge evidence uses separately identified unmodified code.

## Resource scope and cleanup

Real management namespaces/PVs, test unlock object/access material and short-lived workers. Never persist AWS elevated input here. Exact test cleanup retires run-owned unlock material and workers after their dependencies settle; production retained volumes are not erased.

Keep a bounded primary result and cleanup result separately. Preserve the run/operation ID and necessary credentials/custody on incomplete cleanup. Do not delete the test root to hide residue and do not repair resources by hand to qualify a run.

## Documentation and removal obligations

- [documents/engineering/control_plane.md](../documents/engineering/control_plane.md)
- [documents/engineering/storage.md](../documents/engineering/storage.md)
- [documents/engineering/security_and_credentials.md](../documents/engineering/security_and_credentials.md)
- [documents/engineering/configuration.md](../documents/engineering/configuration.md)
- [documents/engineering/testing.md](../documents/engineering/testing.md)

Update implemented correspondence and generated references as the active slice changes, while preserving accepted target semantics. Close every owned ledger row only after replacement acceptance and absence of its old active route. Original-install-only residue with a different remover remains explicitly scoped; it cannot serve new ordinary work.

## Completion record

- [ ] All implementation tasks and owned acceptance cases passed.
- [x] Source/binary/image/config identity, independent observations, budgets and evidence availability are recorded without secret values.
- [ ] Required source mutations are killed by intended assertions or carry reviewed equivalence evidence; no invalid/inconclusive substitute is counted for the current scope.
- [ ] Exact resource/credential/worker cleanup and retained-state obligations are terminal for the declared scope.
- [x] Owned legacy removals and documentation/generated-reference updates are complete.
- [ ] Canonical gate and cumulative relevant regressions pass; no hand action is used as qualifying evidence.

Closure requires advertised bootstrap cases against actual services, retained Vault data through kind recreation, and observed policy and capacity evidence without a future cloud/Authority substitute.

Only then change **State** to Complete and update the single README queue with evidence links. If a counterexample appears, preserve it, expand the owned acceptance/mutation case and repair this phase; do not manufacture a future-phase prerequisite or a new decimal queue.
