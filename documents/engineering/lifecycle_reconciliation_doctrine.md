# Lifecycle Reconciliation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../CLAUDE.md](../../CLAUDE.md),
[../../README.md](../../README.md), [the engineering doctrine docs](../../documents/engineering/README.md),
[acme_provider_guide.md](acme_provider_guide.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[README.md](README.md),
[aws_admin_credentials.md](aws_admin_credentials.md),
[aws_integration_environment_doctrine.md](aws_integration_environment_doctrine.md),
[cli_command_surface.md](cli_command_surface.md),
[integration_fixture_doctrine.md](integration_fixture_doctrine.md),
[prerequisite_doctrine.md](prerequisite_doctrine.md),
[pure_fp_standards.md](pure_fp_standards.md),
[secret_derivation_doctrine.md](secret_derivation_doctrine.md),
[storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md),
[unit_testing_policy.md](unit_testing_policy.md),
[vault_doctrine.md](vault_doctrine.md),
[resource_scaling_doctrine.md](resource_scaling_doctrine.md),
[pulsar_topic_lifecycle_doctrine.md](pulsar_topic_lifecycle_doctrine.md),
[host_platform_doctrine.md](host_platform_doctrine.md),
[cluster_topology_doctrine.md](cluster_topology_doctrine.md),
[test_topology_doctrine.md](test_topology_doctrine.md),
[bootstrap_readiness_doctrine.md](bootstrap_readiness_doctrine.md),
[lifecycle_control_plane_architecture.md](lifecycle_control_plane_architecture.md)
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox lifecycle commands reconcile required
> resource presence and prevent AWS resource leaks. Names the resource classes, sets the rule that
> Pulumi state lifetime must match resource lifetime per class, and defines desired-presence,
> durable-operation, fencing, recovery, target-delivery, and desired-absence semantics.

This document owns lifecycle meaning. The independently scheduled Bootstrap Broker, Lifecycle
Authority, Credential Provisioner, Admin Action Runner, fenced Provider Worker, Authority Backup
Adapter, TLS Retention Adapter, Target Secret Agent, and Gateway Runtime boundaries are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); no service or
transport named here may acquire authority merely because it is reachable or happens to share a
Deployment with an older implementation.

## 1. Leak Classes

Every AWS resource any prodbox flow may create or destroy belongs to
exactly one of these classes. Cleanup ownership is defined per class.

| Class | Examples | Tracked by | Cluster-tag signature | Cleanup owner |
|---|---|---|---|---|
| 1. Pulumi-tracked stack resources | `aws-eks` VPC, EKS cluster, node group; `aws-test` EC2 nodes; `aws-eks-subzone` Route 53 records; `aws-ses` non-credential SES identity, DKIM, receipt rules, and S3 capture resources | Lifecycle Authority operation/provider revision plus immutable encrypted checkpoint reference (see §2) | Stack-name tag and `pulumi:project` tag | Per-run stack destroy submits the registered provider-destroy intent. Explicit `aws-ses` destroy instead uses `DestroyAwsSes`, whose Admin Action Runner result aggregates this provider family with the SMTP credential family and requires authoritative absence read-back for both. |
| 2. Pre-created retained EBS volumes (static `Retain` PVs) | The durable EBS volumes lifted in as static `Retain` PVs on EKS (MinIO, Vault, `keycloak-postgres`/Patroni, `vscode`); **no dynamic provisioning** | Registered managed-resource with typed `discover`/`destroy` (Sprint `4.39`); the retained set is the EBS analog of `.data/` | `prodbox.io/managed-by: prodbox` plus a retain-vs-test-scoped role marker; test volumes additionally carry `kubernetes.io/cluster/<cluster-name>: owned` | Retained by **all** cluster/stack teardown (they are `Retain` and not Pulumi-owned); test-scoped volumes deleted only by the suite postflight reaper, `cluster delete --cascade` reaper hook, or `prodbox aws ebs reap-test --yes` (Sprint `4.40`). See [storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) § 1, § 5 |
| 3. AWS Load Balancer Controller resources | ALBs, NLBs, target groups, listeners/rules, ENIs, and security groups created in response to `Service type=LoadBalancer` and `Ingress` resources | A registered bounded `ControllerResourceFamily` keyed before Kubernetes mutation by account, cluster UID, Kubernetes owner UID, namespace/name/kind, controller generation, and operation ID; discovered child AWS IDs are CAS-appended as exact descriptors | Exact controller/cluster/owner tags and Kubernetes status/annotation IDs are joint evidence; neither a broad tag guess nor name prefix is sufficient | Delete the Kubernetes owner while the controller is live, observe the exact family, and use a fenced Lifecycle-provider absence intent for any verified surviving child; every child requires authoritative absence read-back before the family closes |
| 4. cert-manager Certificate/Challenge and DNS01 records | Home `Certificate`/`Challenge` plus `_acme-challenge.<host>` TXT ownership; run-scoped AWS counterparts | Certificate/Challenge UID plus typed exact account/zone/name/type observation registered before issuance | Exact coordinate; no wildcard name or tag substitute | Home ownership is `LongLived` with restored home cert-manager and is absent only on explicit consumer decommission/nuke. AWS ownership is run-scoped: delete Certificate/Challenge while AWS cert-manager is live, prove every TXT absent, then delete its DNS01 generation. Unobservability fails cleanup. |
| 5. Registered public Route 53 records | `LongLived` home public A record and run-scoped AWS-substrate public A record | Typed managed resource keyed by account/zone/name/type/ownership epoch with observe/ensure/delete/read-back | Exact coordinate; no content guess or tag substitute | Home A record: elected Gateway DNS capability, retained during ordinary postflight. AWS A record: Lifecycle Authority provider intent, destroyed/read-back with EKS. The former direct `aws route53` call sites are pending removal. |
| 6. Operational IAM identities and access keys | Lifecycle-provider and run-scoped AWS cert-manager-DNS01 users/roles/keys; SMTP IAM identity/path/policy/access key | Typed identity/key resources plus authority operation, committed credential generation, retained-home custody receipt where required, Target-Agent version, and Vault tombstone | Exact account/ARN/key ID/role/generation; never a shared-key guess | Credential Provisioner owns create/rotate/remint and repair-time deletion. Delete only after every exact consumer is quiescent and absent, then read back IAM absence before target/custody tombstones. `DestroyAwsSes` alone gives Admin Action Runner terminal delete/read-back authority for the registered SMTP family. Applied-but-response-lost key creation uses finite-inventory delete/remint recovery. |
| 7. TLS retention store | Retained public-edge certificate ciphertext objects, independently scoped IAM identity/key, and `secret/aws/tls-retention-store` generation | Registered `LongLived` resource plus exact `public-edge-tls/<substrate>/<fqdn>` object bytes/digest/version and Authority outbox receipt | Exact account/region/bucket/prefix/identity/key/generation/object-version evidence | Retained across ordinary postflight and `aws teardown`; TLS Retention Adapter alone accesses ciphertext. Explicit consumer decommission/nuke tombstones the generation while home Agent/Vault remain live and deletes all TLS prefix versions plus IAM identity, but never the shared bucket; the final Authority-backup node owns bucket deletion. |
| 8. Authority backup store | Long-lived backup bucket/prefix, independently scoped IAM identity/key, `secret/aws/authority-backup-store` generation, transition receipts, and replicated immutable blobs | Registered `LongLived` resources plus `BackupEstablished` generation/read-back in the Authority aggregate | Exact account/region/bucket/prefix/identity/key/generation and backup receipt; never Lifecycle-provider identity or a tag guess | Retained across suite cleanup and `aws teardown`; rotation preserves a continuously readable generation; only `nuke` may delete it, after Authority freeze plus complete backup-object/IAM/Vault absence read-back |
| 9. Retained home consumer identities | Home Gateway-DNS and home cert-manager-DNS01 IAM identities/keys plus exact Vault generations | Registered `LongLived` identity/key/generation resources bound to restored home Gateway/cert-manager consumers | Exact account/ARN/key ID/role/generation and consumer identity | Ordinary postflight restores/observes and retains them. Explicit consumer decommission/nuke removes owned record/Certificate/Challenge/TXT effects first, then tombstones generations through the still-live home Agent; no ordinary IAM harness teardown may strand them. |

Typed family/record cleanup, K8s drain, authoritative absence read-back, and the scoped postflight
tag sweep make classes 3–9 leak-safe. The sweep is an independent diagnostic on its owning command
surfaces; it cannot substitute for exact controller-child, DNS, IAM, key, object, or bucket absence.
Class 2 is made leak-safe instead by the
retained-EBS managed-resource contract. The drain runs **before** any
Pulumi destroy so the controllers are still alive to unwind their
AWS-side state (see §5b for the canonical cascade order); the sweep
runs **after** the destroys and fails the command with the leak list
when anything cluster-tagged survives. Class 2 EBS volumes are
deliberately **not** unwound by the drain: they are static `Retain`
PVs, preserved across teardown exactly like `.data/`, and are deleted
only by the test-suite postflight reaper, cascade reaper hook, or
`prodbox aws ebs reap-test --yes` for test-scoped volumes
(Sprints `4.39`, `4.40`; the legacy dynamic `gp2` path that this
supersedes is tracked in
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)).
On the AWS substrate the drain must target the EKS API server, not the
local RKE2 cluster — see §5b "Substrate-aware drain". A drain that runs
against the wrong cluster silently skips the in-cluster controller
cleanup, and the subsequent Pulumi destroy fails with
`DependencyViolation` on subnet deletion as ENIs / ALBs block the
underlying network teardown.

The same registry also contains non-AWS retained control-plane resources: every Gateway emitter
journal PV/PVC, admission marker, and Lease; every Bootstrap session fence; the fixed-capacity
Lifecycle Authority primary/backup stores; registered client-recovery journals; and durable
`CleanupRun` journals/reports. Their lifecycle class and exact substrate/storage binding are data,
not inferred from a mounted path. Creating the workload or storage object without those descriptors
is rejected by the same totality check.

## 2. State-Lifetime Rule

**Pulumi state lifetime must match resource lifetime per class.**

| Class | Checkpoint store | Runtime backend URL shape | Lifetime |
|---|---|---|---|
| Per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) | Immutable encrypted checkpoint blobs referenced from the retained Lifecycle Authority aggregate in primary `prodbox-state` and read-back in the independently registered backup store before promotion | Scratch `file://<tmp>` backend hydrated by `Prodbox.Pulumi.EncryptedBackend` inside the fenced provider worker | Auto-managed by the harness; operation/checkpoint evidence remains queryable through cleanup and primary-store recovery |
| Long-lived shared stacks (`aws-ses`, and any future cross-substrate long-lived stack) | The same receipt-backed primary/independent-backup blob pair | Scratch `file://<tmp>` backend hydrated by `Prodbox.Pulumi.EncryptedBackend` inside the fenced provider worker | Long-lived resource class; destroyed only by explicit long-lived teardown |

`LifecycleClass` controls **cleanup ownership**, not whether setup may depend on ambient state.
`LongLived` means that ordinary suite postflight retains the resource; it does not mean that a
suite which requires the resource may assume an operator created it earlier. A selected suite
capability that requires a registered long-lived resource must put an explicit desired-present
reconcile into its preparation plan, and must never put that resource into ordinary postflight
cleanup. The generic desired-present contract and the `aws-ses` specialization are defined in
§3.1 and
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

**Cross-substrate authority split.** Long-lived lifecycle state and a selected workload substrate
are different authorities even when both happen to run on the home cluster. The pure lifecycle
plan receives two non-interchangeable coordinates:

- `LongLivedCheckpointAuthority` identifies an authority epoch, the retained lifecycle aggregate,
  and the immutable checkpoint-blob namespace owned by the Lifecycle Authority. It contains no
  gateway URL.
- `TargetSecretSink` identifies one substrate, one allowlisted KV coordinate, and the
  generation contract interpreted by that substrate's Target Secret Agent. It contains no gateway
  URL and grants no global lifecycle authority.

An AWS-targeted suite still submits `aws-ses` work to the retained home/control-plane Lifecycle
Authority; it must not redirect long-lived state to the active EKS cluster. Only a durable target
delivery intent may address the selected substrate's Target Secret Agent. Authority coordinates,
target coordinates, service identities, and client bindings are decoded and validated plan inputs,
never ambient kubeconfig, current context, process environment, port-forward, or “active gateway”
fallback. The two coordinate types have no shared constructor or implicit conversion.

Core Lifecycle Authority persists exactly one bounded CAS aggregate for lifecycle metadata in its
primary store. Through the typed closed protocol, the separately deployed Authority Backup Adapter
persists the canonical encrypted envelope/commit receipt in a separately registered backup failure
domain. Core Authority never receives the backup AWS secret, and configuration validation rejects
primary/backup aliasing. The
aggregate contains the authority epoch, active mutation fences, provider revision and readiness,
committed SMTP generation, bounded per-target delivery state, and durable outbox state. Large
Pulumi checkpoint bytes are immutable encrypted, content-addressed blobs referenced by verified
primary/backup pairs from that aggregate; they are not additional mutable lifecycle records. Initialization uses
put-if-absent, replacement uses the observed opaque storage version, and a CAS conflict returns a
fresh observation that is fed through the pure transition again. The storage version is a CAS
precondition, never a lifecycle fencing token. Vault envelope/HMAC rules remain canonical in
[Vault Secret-Management Doctrine](./vault_doctrine.md); physical service and client placement
remain canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

Backup restore is scoped to loss/corruption of the Authority primary MinIO namespace while the home
Vault/Transit keys, `secret/aws/authority-backup-store` custody, and long-lived S3 backup remain
intact. Losing the whole home `.data` trust root, including Vault, makes those ciphertexts
undecryptable and is explicitly outside this recovery claim.

The long-lived S3 coordinate configured by `pulumi_state_backend` is the independently credentialed
`AuthorityBackupStore`, not the mutable primary Pulumi backend. Its exact authority-backup prefix
stores encrypted transition prepares/receipts and replicated immutable config/checkpoint/result
blobs. Separate registered prefixes retain public-edge TLS material and the optional first-touch
legacy `aws-ses` import source. The authority-backup identity can reach only its prefix. The
separate TLS Retention Adapter identity at `secret/aws/tls-retention-store` can reach only exact
`public-edge-tls/<substrate>/<fqdn>` ciphertext objects; it cannot reach Authority backup bytes.
Bucket lifecycle and compatibility import remain separately authorized admin actions.

**Per-run state survives cluster wipes via `.data/` preservation.** MinIO runs from a
host-pathed PV under `.data/prodbox/minio/0`
([storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) §1, §7). Whenever
`.data/` is preserved (the default for both `prodbox cluster delete --yes` and
`prodbox cluster delete --cascade --yes`), MinIO's bucket contents — including encrypted Pulumi
checkpoint blobs and other service-owned encrypted objects — persist across the cluster cycle. This
is exactly why the **default `prodbox cluster delete` is a pure local
uninstall** that never touches the per-run AWS backend: abandoning the cluster leaves the
state intact in MinIO; rebuild RKE2 on the same `.data/`; MinIO returns with the same
bucket data; `prodbox aws stack <stack> destroy --yes` (or `prodbox cluster delete
--cascade`) releases the AWS resources cleanly. No permanent leak even under abnormal
teardown sequences.

**Retained S3 compatibility store.** The `pulumi_state_backend` block in
`prodbox.dhall` declares the long-lived S3 bucket still used for public-edge TLS retention
and as the optional first-touch source for old `aws-ses` Pulumi checkpoints. The schema lives in
`prodbox-config-types.dhall` (record type `PulumiStateBackend` with `bucket_name : Text`,
`region : Text`, `key_prefix : Text`). Empty defaults force the operator to set `bucket_name` and
`region` before a command that still touches that retained S3 store can succeed; the
`ensureLongLivedPulumiStateBucket` precondition returns a structured error pointing at the config
keys when either is empty.

**Bootstrapping the retained backup.** The Lifecycle Authority starts `GenesisFrozen`; normal
receipt-backed operations cannot bootstrap their own backup credential. The sole allowed mutation
is the closed `EstablishAuthorityBackup` transaction. Bootstrap Broker creates the exact
genesis-signing Transit trust; Authority primary-journals deterministic coordinates and signs a
one-time `GenesisBackupPermit`; and only the attested ephemeral Credential Provisioner Job receives
the operator prompt over verified exec/attach stdin. It performs closed finite-inventory
create/observe/delete/remint and hands plaintext directly to the home Agent, which CAS-consumes the
permit and seal receipt. Authority and both steady adapters see receipts only. Initial full-copy,
backup receipt, and permanent genesis-disable read-back precede normal admission. That transition
revokes only genesis authority. The same prompt session may continue solely as the typed retained
first-reconcile cursor bound to the exact AWS plan digest, next member, durable prior receipt,
deadline, heartbeat, attach witness, and Job attestation; final session revocation and Job/Pod
absence precede platform/application deployment. Primary loss before that receipt triggers the exact permit-bound cleanup protocol;
no provider, DNS, config, or suite effect is legal in genesis. The complete state/crash/prompt
transport protocol is canonical in
[Lifecycle Control-Plane Architecture §5.0](./lifecycle_control_plane_architecture.md#50-closing-the-backup-bootstrap-cycle).

The cleanup fold observes a flat signed genesis marker: positively absent, consumed, corrupt, or
unobservable. Positive absence authorizes only conditional deletion/read-back from reconstructed
Tier-0 intent, lost storage/authority generation, and exact registered ownership; it does not
require a permit digest lost with primary state and performs no target tombstone. A consumed marker
also binds its permit digest/target receipt and requires target tombstone read-back. Corrupt or
unobservable refuses. A greater recovery fence plus immediate owner/generation re-observation
prevents cleanup from deleting a newer epoch that reused a deterministic name.

**Permanent backup loss.** Temporary timeout, throttling, or unobservability waits/refuses new
receipt-requiring effects and cannot construct a repair proof. Positive bucket/key absence or exact
policy drift CAS-freezes Authority in `BackupRepairFrozen`, the sole post-genesis primary-only
exception. A signed one-time `RepairPermit`, fresh ephemeral Credential Provisioner, direct Agent
delivery of the next `LongLived` generation, Adapter full-copy/read-back, and first new receipt must
complete before admission opens under a strictly greater epoch. No normal external effect runs in
repair; partial residue and response loss resume by the same intent and deterministic
observe/delete/remint inventory. See
[Lifecycle Control-Plane Architecture §5.0.1](./lifecycle_control_plane_architecture.md#501-permanent-backup-loss-repair).

**TLS retention and restore.** The TLS Retention Adapter is ciphertext-only and separately
credentialed. Selected Agents use exact Kubernetes-Secret capabilities; retained-home Agent alone
uses the `prodbox-tls-envelope` Transit key to issue/unwrap a DEK and encrypt it to the selected
one-shot worker's attested ephemeral key. Authority explicitly transports the bounded
ciphertext/wrapped-DEK bytes between Agent and Adapter; a reference from one disjoint store is not
dereferenceable by the other. Each `(substrate, FQDN)` has one fenced pending/current fold binding
Secret UID/resourceVersion equality witness, cert serial/validity/SPKI, Authority sequence, immutable
S3 object version, and byte/digest read-back. Promotion re-observes the exact source Secret; stale,
out-of-order, validity-regressing, or unpermitted different-key candidates refuse. Restore uses the
receipt-committed current immutable version, never S3 latest/list order. The restore fold is total:
the Adapter returns flat `TlsRestorePresent | TlsRestorePositivelyAbsent | TlsRestoreCorrupt |
TlsRestoreDigestMismatch | TlsRestoreUnobservable`; it never classifies certificate time. A pure
decision uses the trusted Authority-time uncertainty interval to classify present bytes as usable,
proven expired, not-yet-valid, or boundary-ambiguous. Only positive absence or trusted-time proven
expiry may authorize a separate backup-receipted issuance intent. Not-yet-valid, uncertain time,
integrity failure, or unobservability of store, key, Adapter, Agent, CAS, or read-back fails closed. AWS
qualification destroys/recreates AWS Vault and EBS, then proves a newly attested Agent restores and
read-backs the exact TLS Secret through retained-home Transit before issuance. The canonical byte
flow, process-isolation boundary, and ADT are in
[Lifecycle Control-Plane Architecture §5.4](./lifecycle_control_plane_architecture.md#54-retained-tls-envelope-workflow).

**Retained operator-material custody.** SMTP and ACME EAB are non-recoverable cross-substrate
materials and therefore use the retained home Agent's closed custody/rewrap lane. The schema sum is
exhaustive: `SesSmtpMaterial` may materialize only `secret/keycloak/smtp`, and `AcmeEabMaterial`
only `secret/acme/eab`. Credential Provisioner derives the region-bound `SesSmtpSource` in bounded
memory from the one-time IAM secret and hands only that derived source to home custody; neither home
Agent nor Authority receives raw AWS secret-access-key bytes. EAB arrives through a separate
schema-indexed operator/test-fixture frame, never through an AWS-admin session or config setup.

The Authority aggregate receipt-orders pending custody seal, current source receipt, bounded
per-target rewrap/materialization/read-back, superseded source, retention grace, and tombstone
states. Home Agent Transit-seals the source and later one-shot rewrap workers encrypt only an exact
current receipt to an attested selected Agent; Authority and outbox see ciphertext/receipts only.
The flat custody observation is present, positively absent, corrupt, digest-mismatched, or
unobservable, and only exact present/read-back can drive delivery. This is the mandatory source for
adding a later target and for repopulating a fresh AWS Vault/EBS without admin re-prompt, IAM remint,
or EAB re-entry.

A superseded source remains until every target transition and recovery/idempotency window closes.
Explicit SES teardown stops/read-backs consumers, deletes/read-backs the external SMTP
key/identity/policy and non-credential SES/S3 family in dependency order, tombstones/read-backs all
target SMTP generations, and only then tombstones/read-backs SMTP custody while home Agent/Vault
remain live. Total nuke applies the analogous closed SMTP/EAB target-then-custody sequence before
home shutdown. The authoritative GADT, ledger, and decommission tags are canonical in
[Lifecycle Control-Plane Architecture §5.5](./lifecycle_control_plane_architecture.md#55-retained-operator-material-custody).

Vault teardown evidence is physical. A target/custody `*TombstoneReadBack` is satisfied only when
the exact per-generation immutable path, or every enumerated KV-v2 secret-bearing version, has been
destroyed and its metadata deleted, followed by metadata/version absence read-back. A KV-v2 soft
delete or a new tombstone value is insufficient because historical versions remain recoverable.
Rotation destroys only superseded versions after the Authority no-dependants scan and retention
grace; current or referenced generations refuse.

The pre-cutover bucket interpreter is `ensureLongLivedPulumiStateBucket` in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`. Target bucket properties are versioning enabled,
server-side encryption with AES256, block-all-public-access on, and a lifecycle rule to expire
non-current versions after 90 days. It is tagged `prodbox.io/purpose=authority-backup` and
`prodbox.io/substrate=shared`; prefix-level IAM separates authority receipts/blobs from TLS and
legacy-import objects.

**Credentials per class.** This table is the per-stack credential-class SSoT; the SecretRef
model, the two-file config split, and the test-fixture classification are owned by
[vault_doctrine.md §3, §4, §13](vault_doctrine.md) and the
`aws_admin_for_test_simulation` block specifics by
[aws_admin_credentials.md](aws_admin_credentials.md) — this section only assigns each stack a
class.

| Class | Credential class | How the credential is obtained |
|---|---|---|
| Per-run stacks and EBS | Lifecycle-provider generation narrowed through the role committed by the provider intent | The fenced provider worker alone reads `secret/aws/lifecycle-provider`; a bounded session cannot outlive the mutation permit or absolute deadline. |
| Canonical `aws-ses` desired-present reconcile | Lifecycle-provider session for non-credential SES/S3; schema-indexed AWS-admin Provisioner permit for SMTP IAM | Fenced Provider Worker may reconcile only SES identity/DKIM/receipt-rule/S3 resources. Credential Provisioner alone installs/rotates/remints or repair-deletes the SMTP IAM identity/policy/key, derives `SesSmtpSource`, and hands it to retained-home custody under `OperatorMaterialPermit 'AwsAdminProvisioningIngress`. Readiness and target delivery hold neither session. |
| Lifecycle Authority backup receipts/blobs | Authority-backup-store generation | The separately deployed Authority Backup Adapter alone reads `secret/aws/authority-backup-store` and may access only the configured long-lived backup bucket/prefix through `AuthorityBackupCommitReadBack`. Core Authority has only the typed adapter client; it cannot read that path, construct S3 clients, assume provider roles, or use `secret/aws/lifecycle-provider`. |
| TLS ciphertext retention/restore | TLS-retention-store generation | The separate TLS Retention Adapter alone reads `secret/aws/tls-retention-store` and accesses exact `public-edge-tls/<substrate>/<fqdn>` objects. It sees only ciphertext/wrapped-DEK bytes; home Target Agent's dedicated Transit lane owns DEK issue/unwrap. |
| Home public A record | `LongLived` Gateway-DNS generation | The elected home Gateway DNS writer alone reads `secret/aws/gateway-dns`, scoped to the exact registered account/zone/name/type record. Ordinary postflight retains it with the consumer. |
| Home DNS01 TXT records | `LongLived` home cert-manager-DNS01 generation | Home cert-manager alone reads `secret/aws/cert-manager/home/dns01`; its identity remains with restored home Certificate/Challenge ownership. |
| AWS DNS01 TXT records | Run-scoped AWS cert-manager-DNS01 generation | AWS cert-manager alone reads `secret/aws/cert-manager/aws/dns01`; cleanup deletes it only after AWS Certificates/Challenges and exact TXT coordinates are absent. |
| Explicit SES destroy, legacy migration/retained compatibility, quota request | Ephemeral Admin Action Runner prompt handle | Authority backup-receipts a closed `AdminActionPermit`; exact `DestroyAwsSes` aggregates registered non-credential SES/S3, SMTP IAM key/identity/policy, target-generation, and home-custody absence stages. Only the attested one-shot Runner obtains bounded prompt bytes through verified exec/attach stdin. It records stable operation/inventory/status read-back, revokes its session, and is deletion-read-back. |
| Total nuke after decommission export | Ephemeral Decommission Runner prompt handle | The standalone Runner accepts only the externally fsynced signed manifest/receipt after Authority stops; this permit and interpreter are not an Admin Action Runner fallback. |

Credential class follows operation authority and lifecycle. `prodbox config setup` only
authors/validates Tier-0 and performs no IAM/S3/Vault mutation. Visible cluster/setup reconciliation
uses the indexed Credential Provisioner: primary-only `GenesisBackupPermit` first, then only normal
backup-receipted `OperatorMaterialPermit`s for Lifecycle-provider, home Gateway-DNS, home/AWS
cert-manager-DNS01, TLS-retention, and SMTP IAM identities. The retained AWS-admin session is bound
to the exact plan digest, next member, prior durable receipt, deadline, heartbeat, attach witness,
and Job attestation; it cannot accept ACME EAB. SMTP is derived in Provisioner memory and flows to
retained-home custody; other created plaintext flows directly Job→named Agent. Authority and
adapters see receipts only. Disconnect/restart or any proof failure revokes the session and requires
re-prompt while reusing the committed permit and finite inventory; final member receipt forces
session revocation and Job/Pod absence. EAB uses a separate schema-bound Job/frame, and later
rotation always uses a new Job/prompt. Policies and trust are exact; no
base key, Vault path, ServiceAccount, cleanup node, or permit constructor is shared across roles.
Explicit SES destroy/migration/retained compatibility/quota request uses the separate Admin Action
Runner, and `nuke` uses only its post-export Decommission Runner.

**Legacy checkpoint migration.** First-touch migration is owned by
`Prodbox.Pulumi.EncryptedBackend`, but its admin-authenticated interpreter runs only in the
one-shot Admin Action Runner under a backup-receipted `MigrateLegacyBackend` permit. When the
encrypted `LogicalPulumiStack <stack-id>` object is absent, that Job may log into the exact configured
legacy backend, export the old checkpoint into bounded scratch, hydrate the normal encrypted path,
and remove the legacy stack only after encrypted store/read-back and registered source deletion
succeed. Stable operation ID/inventory resumes response loss; no host-direct login fallback exists.

The operator command `prodbox aws stack aws-ses migrate-backend` is kept as a TTY-only
compatibility entrypoint while old `aws-ses` checkpoints may still exist. It now opens the same
encrypted scratch backend as reconcile/destroy and triggers the first-touch import/delete path; it
does not run raw MinIO-to-S3 `pulumi stack export` / `pulumi stack import`.

**Rule.** No new Pulumi stack may be added to any prodbox code path
without first deciding its lifetime class, selecting the matching
backend, and matching the credential class. The class assignment must
appear in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
and the code-side SSoT in the same change: every Pulumi-managed stack is one
`Prodbox.Infra.StackDescriptor` record (`stackRegistryName` / `stackPulumiStackId` /
`stackProjectSubdir` / `stackCliVerb` / `stackLifecycleClass`, Sprint `4.27`), from which
`Prodbox.Aws.perRunStackNames` and the CLI verbs / project dirs derive; the long-lived
class (which spans more than stacks — it includes the non-stack `public-edge-tls` cert)
is `Prodbox.Aws.longLivedResourceNames`.

## 3. The Reconciler-with-Predicates Pattern

Five layered patterns govern resource reconciliation. Resource truth is never a process-global
in-memory shadow. Multi-stage retained workflows use the externally durable Lifecycle Authority
aggregate and total `decide`/`evolve` folds described in §3.1; ordinary resource discover/diff/enact
still derives every decision from fresh external observations.

1. **Source-of-truth queries.** Each resource class has a `discover` IO
   action that asks the authoritative source. No in-memory shadow
   state. The canonical example for Pulumi residue is the
   `<stack>ResidueStatus :: ... -> IO ResidueStatus` family in
   `src/Prodbox/Infra/Aws*Stack.hs` (introduced in Sprint 4.16): each
   per-run stack and the long-lived `aws-ses` stack query their encrypted Pulumi checkpoints.
   The result ADT is

   ```haskell
   data ResidueStatus
     = ResidueAbsent
     | ResiduePresent ResidueDetails
     | ResidueUnreachable ResidueUnreachableReason
   ```

   `Unreachable` is the credential-free "we cannot tell" signal that
   the pre-Sprint-4.16 file-existence predicate
   (`<stack>HasLiveResources = doesFileExist .prodbox-state/<stack>/
   stack-snapshot.json`) used to approximate. How callers interpret
   `Unreachable` depends on whether they are a **gate** or the
   **cascade orchestration**, and this is deliberate:

   - **Gate callers fail closed.** A residue refuse-path treats
     `Unreachable` as a refusal: "I could not read the Pulumi state" is
     **not** the same as "the resources are gone." This applies to an explicit long-lived
     destroy/migration decision and is honored when the cascade queries per-run residue. Ordinary
     `aws teardown` does not demand long-lived absence: presence is the intended state and is never
     residue for that projection. Note a
     never-created backend bucket or missing encrypted checkpoint is **not**
     `Unreachable` — it is positive evidence of `Absent` (nothing to
     destroy), classified as such for both encrypted checkpoint and retained-bucket reads.
     (Default `prodbox cluster delete` no longer carries a per-run
     refuse-path at all — it is a pure local uninstall — so this
     fail-closed rule is moot there.)
   - **Cleanup continues without lying.** A cascade may continue to independent AWS discovery,
     tag sweeps, EBS reaping, and local restoration after a checkpoint observation is
     `Unreachable`, but it records `CleanupUnobservable` and cannot report authoritative absence.
     A tag sweep that finds nothing is useful independent evidence; it does not rewrite an
     unreadable checkpoint to `Absent`. The always-run cleanup report remains failed/unresolved
     until the owning authority is observed or an explicit operator recovery disposition is
     durably committed.

   Other discoverers added by Sprints
   4.11–4.12: `discoverClusterTaggedAwsResources` (AWS Resource
   Tagging API), `discoverK8sAwsAffectingResources` (kubectl).

   **Control-plane absence is not authoritative-resource absence.** Destructive lifecycle commands
   run against partially- or fully-torn-down infrastructure routinely, so an explicitly scoped
   control-plane cleanup may expose a distinct skipped result. That exception does not collapse an
   AWS/resource-authority transport failure to `Absent`: AWS authentication failure, throttling,
   network failure, and malformed output remain `Unreachable`/`Unobservable` and fail closed. The
   Kubernetes-side drain discoverer is the worked control-plane exception through the `DrainResult`
   ADT in
   `src/Prodbox/Lifecycle/K8sDrain.hs`:

   - **`DrainSucceeded`** — the cluster was reachable, the targeted
     K8s resources were deleted, and the bounded poll loop observed
     them gone before the deadline. No surviving K8s objects.
   - **`DrainSkipped <reason>`** — the selected control plane was unavailable, so no delete was
     attempted. This is an observation, not a universal success value. The pure cleanup fold also
     receives `DrainPolicy`: a positively absent disposable local control plane may classify the
     skip as satisfied-with-reason, while an EKS drain required to release controller-created AWS
     resources classifies the same skip as a cleanup failure. In both cases the provider destroy
     remains eligible through a `RequiresAttempt` edge and its result cannot erase the skip.
   - **`DrainFailed <error>`** — the cluster was reachable and a delete-or-poll step errored. It is
     always a cleanup failure, but independent or attempt-dependent nodes continue.

   Any future skip-on-unreachable exception must identify an ephemeral control plane that is itself
   being removed, preserve a distinct skipped constructor, and name an independent authoritative
   cleanup/backstop. It must not be applied to an operator parent Route 53 zone, an SES resource, a
   Pulumi checkpoint, or another AWS authority merely because the account cannot be observed.
2. **Composable requirement algebra.** Each named requirement is pure data naming the exact
   operation-scoped `CapabilityRef` it needs. An interpreter performs discovery through that same
   reference and returns a flat typed observation; a total pure fold decides admit, refuse, or
   continue-with-recorded-cleanup-failure. No `Precondition` stores arbitrary `IO`, and no
   separately supplied execution endpoint can consume its result.
3. **Reconciler loop**, not strict sequence. `discover → diff → enact
   → re-observe` until stable or timeout. Idempotent by construction.
   Matches the `prodbox cluster reconcile` doctrine for the install path.
4. **Bracket-style ownership** for genuinely transient handles such as a scoped client session or
   scratch directory. Durable lifecycle work is not a long transport bracket: it is submitted by
   operation ID, journaled before effect, and resumed independently. Gateway object-store routes,
   host port-forwards, and ambient backend environments are pre-cutover compatibility paths, not
   target ownership boundaries.
5. **Phase ADT for narration**, not state. A flat ADT names the
   sequential phases for dry-run output and structured error
   reporting. Example shape:
   ```haskell
   data DeletePhase
     = DrainK8s
     | DestroyPulumiPerRun
     | UninstallRke2
     | PostflightTagSweep
     deriving (Eq, Show)
   ```
   This is the `LifecycleAction` pattern from
   [pure_fp_standards.md §2.1](pure_fp_standards.md). The ADT is a
   list of named transitions, not a stateful machine.

### Why not a monolithic world-state machine

A monolithic world-state machine would have to model the cross-product of every
sub-resource's status: rke2 up/down × MinIO up/down × four Pulumi
stacks × three classes of K8s-created AWS resource × operational IAM
user × DNS-bootstrap records. The authoritative state lives in
external systems (AWS, the local filesystem, the kube API) that this
program cannot refresh transactionally. Any in-memory model would go
stale the moment AWS returned eventually-consistent results; crash
recovery would force a rediscover anyway, at which point the machine
adds coupling without adding safety.

The reconciler is "data in, data out": each `discover` is
independently testable, each `Precondition` composes, and the doctrine
generalizes to any new resource class by adding one `discover` and one
`Precondition`. No existing command needs to know about new commands.

The data-oriented strengthening is the managed-resource registry below: it keeps "data in, data
out," adds no shared in-memory world model, and makes the "add one `discover` + one destroy per
resource" rule total and machine-enforced. This is compatible with the bounded externally durable
Lifecycle Authority state machine: that aggregate owns operation/fence/checkpoint/outbox metadata
only and still consumes separately observed provider, Kubernetes, Vault, and AWS truth. It does not
pretend to transactionally contain the world.

### 3.1 The managed-resource registry (the reconciler substrate)

> **Bring-up twin.** The three-valued `ResidueStatus` (`Absent | Present | Unreachable`) and its
> `Unreachable → refuse` soundness rule have an inverse-polarity twin for bring-up:
> `ReadinessObservation` (`ReadyObserved | NotReadyYet | Unreachable`), which opens a bounded gate
> only on `ReadyObserved`. Sprint `1.59` introduced flat observations but allowed caller-injected
> one-shot actions; that binding is historical and superseded. The target graph stores a pure
> `CapabilityRequirement`, resolves one `CapabilityRef kind`, and uses the same reference for
> observation, admission, and execution. Exact semantics live in
> [bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md) and
> [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md).

Every leak we have hit was one of two failures, neither of which a
state machine fixes: (a) a **fail-open predicate** — a `discover` whose
"cannot observe" outcome silently collapsed to "absent/clean" (e.g. the
pre-Sprint-4.19 per-run gate, and the file-existence proxy before
Sprint 4.16); or (b) **incomplete coverage** — a resource the system can
create that has no registered observe/destroy program at all (each role-specific IAM identity/key,
Vault generation/tombstone, the fixed `prodbox-ses-lease-session` role and inline policy, fixed-name
IAM left by a partial `pulumi up`; see §6a). The registry closes both
structurally.

**The registry is a single, pure list of typed managed resources** — the
SSoT for "everything prodbox can create, and how to observe and destroy
it." Conceptual shape (canonical names land with the implementation
sprint):

```haskell
-- Example: the registry entry shape
data LifecycleClass = PerRun | LongLived | Operational
data ResourceCardinality
  = ResourceSingleton
  | ResourceFamily ManagedResourceFamilyKey MaxManagedChildren

data ManagedResource = ManagedResource
  { resourceKey        :: ManagedResourceKey
  , resourceClass      :: LifecycleClass
  , resourceOwner      :: ServiceIdentity
  , resourceScope      :: AuthorityScope
  , resourceCoordinate :: ManagedResourceCoordinate
  , resourceCardinality :: ResourceCardinality
  }

data ManagedResourceObservation
  = ResourceAbsent
  | ResourcePresent ObservedResourceVersion
  | ResourceUnobservable ManagedResourceFailure

data AbsentDecision
  = AlreadyAbsent
  | DestroyThenReadBack ManagedResourceDestroyIntent
  | RefuseAbsentReconcile ManagedResourceFailure

data PresentDecision
  = AlreadyPresent ObservedResourceVersion
  | EnsureThenReadBack ManagedResourceEnsureIntent
  | RefusePresentReconcile ManagedResourceFailure

planAbsent
  :: ManagedResource
  -> ManagedResourceObservation
  -> AbsentDecision

planPresent
  :: ManagedResource
  -> ManagedResourceObservation
  -> PresentDecision

managedResources :: [ManagedResource] -- pure single source of truth
```

The registry contains no `IO`, client, endpoint, credential, or callback. A diagnostic derives a
read-only `ManagedResourceObserve` program. Desired presence derives
`ManagedResourceEnsureReadBack`; desired absence derives `ManagedResourceDestroyReadBack`. Each
mutation interpreter uses the same mutation-capable reference for capability admission, domain
pre-observation, the pure `planPresent`/`planAbsent` decision, conditional effect, and mandatory
read-back under one absolute deadline. A diagnostic observation cannot be reused to admit mutation
on another reference. Both planners are total over the three observation constructors; only the
interpreter performs effects.

A family entry is still bounded pure data. Before a Kubernetes owner/controller mutation, the
durable cleanup run registers the family key and maximum child count. Reconnaissance combines that
exact owner identity with Kubernetes status/annotations and provider observations; each discovered
cloud child is CAS-appended to the cleanup journal and registry projection before another child may
be admitted. Exceeding the family bound or finding a child whose joint ownership evidence does not
match is `ResourceUnobservable`/refusal, never an invitation to widen a tag scan.

It reuses, not replaces, the existing pieces: the three-valued
`ResidueStatus` (§3 layer 1), the composable `Precondition`/`checkAll`
algebra (§3 layer 2), the `Plan`/`Apply` discipline, and the
declare-and-interpret shape of the Effect DAG. The per-class name lists
(`Prodbox.Aws.perRunStackNames`, derived from the `StackDescriptor` SSoT;
`Prodbox.Aws.longLivedResourceNames`, derived from the registry by class so it can
include non-stack resources such as `aws-ebs-volumes` and the `public-edge-tls` cert)
cannot drift from their sources.

Five invariants make the topology leak-proof and idempotent:

1. **Totality.** No prodbox code path may directly create, or create a Kubernetes/controller owner
   that indirectly creates, an AWS or cluster resource not represented by a singleton/family entry
   with `discover`, `ensure` when creatable, and `destroy`. This is enforced in `check-code` (registry ↔
   [`substrates.md` Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
   parity, plus direct create-call-site and Kubernetes-owner/controller coverage scans), the same mechanism
   that already enforces the generated-section registry and the
   subprocess boundary. "A creatable-but-undiscoverable resource" is
   made unrepresentable.
2. **Soundness.** `Unreachable` ("cannot observe") is never silently a
   passing decision. A single combinator maps a `discover` result to a
   gate decision with `Unreachable → refuse` (the Sprint 4.19 rule,
   generalized to every gate). The cascade keeps its documented
   graceful-degradation exception (`perRunCascadeInventory`, §5b).

   **Dependent-resource rule.** Observing an IAM key absent may prove that an unobservable Vault
   generation is inert, but it never proves that Vault resource absent. The cleanup DAG may continue
   independent AWS cleanup, yet final cleanup/qualification remains failed until the Vault
   generation is observed and tombstoned. The pre-cutover
   `refineAwsConfigResidueAgainstIamUser` downgrade is a deletion surface, not a target soundness
   rule.
3. **Idempotent reconciliation.** Teardown is one reconciler,
   `reconcileAbsent`, over a class subset of the registry: for each
   resource `Present → destroy → re-observe`, `Absent → skip`,
   `Unreachable → refuse`. `prodbox cluster delete --cascade` reconciles
   `PerRun` (default `cluster delete` is a pure local uninstall and
   reconciles nothing); `prodbox aws teardown` reconciles `Operational`
   after its exact consumers are quiescent while retaining `LongLived`;
   `prodbox nuke` reconciles all classes. Re-running converges instead
   of erroring; built on `Plan`/`runPlanWithOptions` so `--dry-run`
   works uniformly.

4. **Plan-option totality.** Every destructive command routes its work
   through `runPlanWithOptions`, so `--dry-run` and `--plan-file` are
   honored uniformly — `prodbox cluster delete` (the default local
   uninstall and `--cascade`), `prodbox aws teardown`, and `prodbox nuke`
   included. This is the intended Sprint 4.26 invariant: a `check-code`
   lint, `checkPlanOptionsHonored`, forbids any destructive dispatch arm
   from binding the `PlanOptions` argument to a `_` wildcard (which would
   silently drop `--dry-run` / `--plan-file`). The rule is total — "a
   destructive command that ignores its plan options" is made
   unrepresentable, the same way invariant 1 makes
   "a creatable-but-undiscoverable resource" unrepresentable. The
   cascade's per-run sweep is **derived from** `perRunManagedResources`
   (the registry SSoT for the `PerRun` class) rather than a hand-maintained
   stack list, so the rendered `--dry-run` plan and the executed sweep can
   never omit a per-run stack. The gate's `(stack, destroy-command)` list
   and the destroy actions share one registry-derived source
   (`pairPerRunResidue` / `pairAwsSesResidue` + `residueGateRefusalList`).

5. **Lifecycle-class total verb obligations.** A registry entry's `LifecycleClass` obliges it
   to a total verb in the derived restore/cleanup graph (§3.3): every `LongLived` entry must
   have a restore/ensure node, and every `PerRun` entry must have a destroy node. Coverage is a
   pure fold over the closed registry, checked pre-cluster, so "a long-lived resource with no
   restoration" and "a per-run resource with no destroy" are made unrepresentable — the same
   way invariant 1 makes "creatable-but-undiscoverable" unrepresentable. The invariant 2
   soundness rule carries into this projection unchanged: "cannot observe" is never "absent"
   for a restore/ensure node any more than for a destroy node; an unobservable resource blocks
   its node with a recorded refusal, never a silent skip.

The `Operational` projection registers Lifecycle-provider and AWS cert-manager-DNS01
IAM/key/role/Vault generations. Lifecycle-provider is removed only after every exact provider
operation is quiescent; AWS DNS01 is run-scoped with EKS and follows
Certificate/Challenge/TXT absence. Home Gateway-DNS and
home cert-manager-DNS01 identities are `LongLived` with their restored consumers. Setup
observes/reconciles each exact policy and delivers new generations without rotating unrelated
roles. Teardown follows dependency edges, deletes IAM/key resources before ordinary Vault
tombstones, and re-observes each resource as absent. A missing/incomplete scope defers that role
safely; it does not authorize a wildcard policy or cross-role fallback.

Authority-backup-store and TLS-retention-store bucket/prefix/IAM/key/Vault-generation resources are
separate `LongLived` projections with non-overlapping identities/policies. `aws teardown` and
ordinary suite cleanup observe but retain them; rotation keeps the prior readable generation until
replacement read-back and receipt. Only explicit consumer decommission/`nuke` owns TLS desired
absence; only `nuke` owns Authority-backup absence, after freeze/export preserves the final report
outside the objects it is about to remove.

For validation-owned mutation, registry membership is necessary but not sufficient: the durable
`CleanupRun` must receipt-register the exact singleton or bounded family first. The returned
`CleanupObligationRef` is bound into the mutation's `CommittedIntentRef`. Cleanup ownership
therefore survives TestRunner loss and cannot be reconstructed after creation from a best-effort
tag sweep. The journal/fence/resume and dependency semantics are canonical in
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-cleanup-failure-handling).

#### Desired-Present Reconciliation for Long-Lived Resources

The same registry substrate now includes a bring-up projection for resources which a selected
capability may require. This is not a second registry and not a global state machine. The resource
remains externally authoritative, and one flat observation ADT carries the only three facts
discovery may establish:

```haskell
-- Implemented by Prodbox.Lifecycle.ResidueStatus.
data PresenceObservation a
  = PresenceAbsent
  | PresencePresent a
  | PresenceUnobservable ObservationFailure
```

Checkpoint observation is a separate flat value, because “AWS resources exist” and “their encrypted
checkpoint is usable” are independent external facts:

```haskell
-- Implemented by Prodbox.Lifecycle.ResidueStatus.
data CheckpointObservation a
  = CheckpointMissing
  | CheckpointValid a
  | CheckpointCorrupt CheckpointFailure
  | CheckpointUnobservable ObservationFailure
```

`Prodbox.Lifecycle.DesiredPresence` implements the exhaustive 12-cell decision table as six
explicit mutation constructors:
`CreateFromAbsentMissingCheckpoint`, `CreateFromAbsentValidCheckpoint`,
`CreateFromAbsentCorruptCheckpoint`, `ImportPresentMissingCheckpoint`,
`ReconcilePresentValidCheckpoint`, and `RepairPresentCorruptCheckpoint`. Its
`reconcileDesiredPresence` interpreter performs the single
`observe -> plan -> enact -> re-observe` transaction and carries both fresh observations on an
enactment failure. `Prodbox.Lifecycle.ResourceRegistry` exposes the independent
`resourceEnsureCommand` / `resourceEnsurePresent` projection and currently registers
`desiredPresentManagedResources = [awsSesPulumiResource]`; the existing desired-absence projection
is unchanged. That projection resolves `CapabilityRef 'ManagedResourceEnsureReadBack` and runs
`ReconcileManagedResourcePresent` with the receipt-committed ensure intent; it is not an unindexed
command escape or an implicit use of the destroy reference.

The pure planner is total over presence × checkpoint observation. Positively present fixed-name AWS
resources plus a missing or corrupt checkpoint may plan bounded import/repair; positively absent AWS
may plan creation and checkpoint replacement; either `PresenceUnobservable` or
`CheckpointUnobservable` refuses. Corruption is preserved as evidence and never silently recoded as
missing.

`PresenceUnobservable` is not absence. Authentication failure, throttling, network failure,
malformed output, and any other inability to classify AWS state map to that constructor and fail
closed before mutation. Code must not implement `catchError (const False)` around an existence
probe, and must not perform a separate Boolean check followed by create. The canonical reconciler
owns `observe -> diff -> enact -> re-observe`; a present but drifted resource is just another diff,
and re-running the reconciler against converged state is a no-op.

The selected validation set is reduced purely to a set of required managed-resource capabilities.
For each required long-lived resource, planning emits a visible `EnsurePresent` action. For
`aws-ses`, both `PresenceAbsent` and `PresencePresent snapshot` enter the canonical idempotent
reconcile so missing resources and drift converge through one path; `PresenceUnobservable` emits a
refusal. A resource which no selected validation requires emits no preparation action. No branch
emits an ordinary-suite destroy for a `LongLived` resource.

Concurrent desired-presence work for an account-scoped resource is admitted as a durable operation.
The caller first records a bounded `ClientSubmissionKey`/request digest in its declared durable
cursor authority; the Lifecycle Authority CAS-reserves a sequence in that fixed registered-client
slot and returns the resulting `OperationId`. Submission is asynchronous: duplicate reserve/submit
with the same key/digest observes the existing operation, while a digest mismatch refuses. A caller
that loses either response resolves the same key. It never guesses from a timeout, allocates a fresh
mutation ID, or treats disconnection as rollback.

This guarantee is bounded without allowing state growth or reuse: the Tier-0 client table has fixed
slots/generations and per-slot reservation limits; `OperationId` binds epoch, slot/generation,
authority-allocated sequence, and request digest. Terminal operations compact to a bounded terminal
projection or immutable result-blob reference plus digest; per-client floors remain in the fixed
slot; nonterminals never evict; saturation refuses new IDs; and a compacted sequence returns
`OperationIdExpired`, never a fresh mutation.

The authority journal, fences, checkpoint references, and delivery outbox are projections inside
the one bounded CAS aggregate defined in §2. Every transition follows the same discipline:

1. observe and decode the aggregate;
2. decide the next event purely;
3. write/read back the canonical evolved envelope and any already-verified backup-blob references
   as an encrypted backup prepare;
4. CAS the primary aggregate, write/read back the backup commit receipt, and only then project a
   signed `CommittedIntentRef`;
5. execute only that receipt-committed intent under the current authority epoch;
6. re-observe the external authority; and
7. CAS and backup-receipt a fenced completion, recovery, or failure event.

A checkpoint transition first receipt-commits a fenced pending digest/reference plus typed
reconstruction source, then writes and reads back the identical encrypted blob in primary and
independent backup stores, and finally receipt-CAS-promotes the verified reference pair to current.
Garbage collection durably records its candidate and two primary/backup scan receipts separated by
grace. Its fence excludes pending/promotion; it re-observes the latest primary aggregate and backup
receipt immediately before deleting from both stores, reads back absence, and commits a deletion
receipt. A just-written or disaster-recovery-required blob therefore cannot be collected before
promotion or while referenced. Lifecycle correctness never depends on atomically updating separate
mutable lease/checkpoint/target records: there is one mutable aggregate, its independent receipt,
and immutable replicated blobs.

The durable SES workflow is therefore a stage graph, not one synchronous
`acquire -> reconcile -> await-ready -> sync-target -> release` bracket:

```text
commit operation
  -> commit non-credential SES/S3 provider-mutation intent under a narrow mutation fence
  -> execute provider mutation and commit provider revision + checkpoint blob reference
  -> await semantic readiness for that exact revision without holding the mutation fence
  -> commit backup-receipted SMTP `OperatorMaterialPermit` when rotation is required
  -> Credential Provisioner ensures SMTP IAM identity/policy, observes/repair-deletes/remints key
  -> derive region-bound SesSmtpSource and seal/read back retained-home custody
  -> commit credential generation, current custody receipt, and bounded per-target delivery outbox
  -> home custody rewraps to each selected Agent; materialize/read back target generation
  -> commit clean quiescent operation close
```

Provider propagation may take 5–30 minutes and may outlive one client request. It does not hold a
70-minute account-wide lease, an STS session, or a worker connection. The operation remains
queryable and resumable between stages. An absolute operation deadline bounds admission, queue
wait, credential refresh, external I/O, read-back, and response handling; deadline exhaustion is a
durable disposition, not evidence that an already accepted external request stopped.

Mutation fencing is deliberately narrow:

- CAS acquisition returns the authority epoch, opaque owner nonce, monotonically increasing fencing
  token, and a serializable authority-time safe-use deadline for one non-credential provider
  mutation or one Credential-Provisioner action; process-local request deadlines are never persisted as authority
  time;
- the Vault-resolved Lifecycle-provider generation is used only to assume the exact same-account
  `prodbox-ses-lease-session` role, and the resulting STS session cannot outlive the narrow permit,
  operation deadline, or role maximum;
- the fence is enforced by Lifecycle Authority transitions and referenced checkpoint commits, not
  by AWS. Credential expiry prevents new authorization but cannot revoke an AWS request already
  accepted;
- semantic-readiness polling and target delivery hold no provider mutation fence;
- clean, re-observed completion closes the permit immediately. Cancellation, expiry, authority
  loss, or an applied-but-response-lost result closes it as ambiguous and schedules no new local
  mutation;
- after the declared provider visibility, clock-skew, and cancellation grace, recovery must obtain
  a stable quiescence witness from repeated authoritative observations before resuming the same
  operation. Pending, unbounded, still-changing, or unobservable state refuses a successor
  mutation;
- explicit release is an idempotent latency optimization. Correctness comes from the epoch, fence,
  durable disposition, grace, and re-observation, so losing a release response cannot create a
  second writer.

Target delivery is a separate external authority. Holding a lifecycle fence never grants ambient
Vault access on a target substrate. Before any write, the aggregate commits a bounded outbox item
containing operation ID, target identity, credential generation, opaque Agent commitment reference,
schema, and deadline. The
selected Target Secret Agent validates its substrate identity and allowlist plus the signed
committed-intent reference, authority epoch/fence, target-binding digest, action digest, and
deadline; it performs a generation-checked Vault KV CAS and reads back the exact Vault version and
opaque commitment reference. The Lifecycle Authority then commits delivery only after re-observing
those values. Same-generation/same-commitment delivery is idempotent; generation regression and
same-generation commitment change are hard refusals.

Before the outbox contains credential ciphertext, target sealing is itself idempotent: the Agent
uses Vault keyed-HMAC domain-separated by operation/action/schema/generation, CAS-stores the opaque
commitment plus ciphertext-only receipt under the operation ID, and reads it back before replying.
A same-ID comparison occurs only inside that receipt fold; no unkeyed secret hash is
persisted or exposed. A lost response retrieves the receipt, so Authority never persists plaintext
or asks a provider to remint when sealing already exists.

Target materialization must name that exact durable seal-receipt reference. After the long-lived
Agent controller verifies its operation/action/schema binding, an isolated one-shot worker loads
the ciphertext from its exact receipt KV path and uses Transit decrypt only in bounded memory while
performing the target-generation CAS and mandatory read-back. It best-effort zeroizes only owned
mutable/mlocked buffers, revokes its session, exits, and is deletion-read-back; no byte-erasure claim
is made for Haskell/SDK/TLS/GC copies. The receipt is retained through the
operation/tombstone idempotency window and is removed only by a committed receipt-GC action after
terminal target read-back plus grace. That exact `TargetSealReceiptGcMutation` alone may invoke
`GarbageCollectTargetSealReceipt`, and `TargetSealReceiptGcReadBack` must prove absence before
commit. Consequently the
Agent worker's Vault policy grants only the substrate receipt KV prefix, encrypt/decrypt on the
substrate Transit key, HMAC-only use of
`prodbox-target-secret-commitment-<substrate>`, and the allowlisted target KV paths. The Authority, Provider Worker,
Gateway, Backup Adapter, and TLS Retention Adapter receive none of those permissions.

The outbox is finite: targets come from a bounded registered set, each target has at most one
nonterminal delivery plus its committed generation, and terminal history compacts into that
projection. Before creating a new credential generation, recovery resolves every prior nonterminal
delivery—including one for another substrate—by operation record plus stable target read-back or an
authoritative retired-target observation. A lost Target Secret Agent response is therefore
recovered by operation ID and target generation, never by replaying an untracked write. No gateway
route participates in this protocol.

SMTP access-key repair remains the non-idempotent edge and has the strictest fold. Under a narrow
`OperatorMaterialPermit 'AwsAdminProvisioningIngress`, Credential Provisioner ensures and reads back
the deterministic SMTP IAM identity/path/policy, then reads the finite authoritative key inventory
and compares it with the committed generation and key ID. Every owned key that is
uncommitted or whose material is unrecoverable is deleted first; repair waits through the provider
visibility interval and re-observes stable absence before creating another key. Exactly one
committed key with recoverable material is reused without creation. An unobservable, late-changing,
or out-of-bound inventory refuses rather than blindly deleting or creating. The resulting key ID,
opaque retained-home custody receipt, and delivery outbox are CAS-committed before target rewrap
begins. The one-time AWS secret is converted to region-bound `SesSmtpSource` inside Provisioner
memory; raw secret-access-key bytes never enter home Agent, Authority, or durable custody.
The same rule applies to Lifecycle-provider, Authority-backup-store, TLS-retention-store,
Gateway-DNS, and cert-manager access keys: a Credential-Provisioner create
intent is committed first; if AWS creates a key but its one-time secret response is lost before
target sealing, recovery deletes that observed uncommitted key, proves stable absence, and remints.
Blind `CreateAccessKey` retry and untracked key residue are forbidden.

Provider presence remains a necessary first observation; it is not semantic readiness. Readiness
is evaluated against the exact committed provider revision using the exhaustive
`AwsSesReady | AwsSesPending | AwsSesFailed | AwsSesUnobservable` fold. Each bounded observation
proves the complete provider inventory, sender/DKIM, regional MX, active receipt rule, and capture
canary. `AwsSesPending` persists a waiting observation and may be polled later;
`AwsSesFailed` and `AwsSesUnobservable` fail immediately. Client timeout reports the operation ID
and last observation while retaining the long-lived resource and durable recovery state.

Pulumi/provider state owns no SMTP IAM identity, policy, or access-key resource. Credential
Provisioner is the sole desired-present/repair interpreter for that complete registered family;
Admin Action Runner may delete/read-back it only under exact `DestroyAwsSes`. Recoverable SMTP
material exists only as a retained-home ciphertext custody receipt and its exact target-Vault
projections.

Cutover cannot leave historical SMTP key output in an authoritative provider checkpoint. The new
non-credential SES/S3 checkpoint and current custody/target receipts must be committed first; the
Authority then drops every secret-bearing legacy output from current projection immediately and
marks each old immutable primary/backup checkpoint or history blob retired. Only after the rollback
window and complete no-reference scans may fenced GC delete both copies, read back absence, and
commit the deletion receipt. A deadline, stack-name match, or replacement checkpoint alone never
authorizes that GC.

Prerequisite nodes remain read-only gates. Tool/config/backend reachability is established before
operation submission, while semantic readiness is an observed durable stage after the visible
reconcile action; neither phase hides mutation in a prerequisite. See
[Prerequisite Doctrine §4A](./prerequisite_doctrine.md#4a-prerequisitepreparation-boundary).
The read-only `prodbox host check-ses-readiness` diagnostic exposes one current semantic observation
without submitting or advancing a lifecycle operation.

This is the data-oriented "make illegal states unrepresentable"
answer, not a global state machine: the registry is pure data, every
`discover` queries the appropriate external authority at the moment of use. Crash recovery
re-observes the durable operation ID, aggregate, immutable checkpoint reference, external provider
state, and target-delivery outbox before deciding the next event; it never relies on an in-memory
bracket having returned.

This registry substrate is reused, not re-derived, by later doctrines:
[resource_scaling_doctrine.md § 7](./resource_scaling_doctrine.md#7-scaling-is-a-reconciled-managed-resource)
models a desired scaled shape as a reconciled managed resource with a three-valued `discover`,
[pulsar_topic_lifecycle_doctrine.md § 1](./pulsar_topic_lifecycle_doctrine.md#1-a-topic-is-a-managed-resource)
registers each Pulsar topic as a managed resource with a typed `discover`/`destroy` and a
`LifecycleClass`, and
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-cleanup-failure-handling)
projects the `PerRun` / `LongLived` partition into the suite's always-run cleanup DAG. This
document determines which resources are cleanup-eligible; fixture doctrine owns cleanup scheduling,
dependency blocking, and failure aggregation.

The public-edge **production** certificate is a worked example of this
registration (Sprint 4.24). Its S3-retained material — written to the
substrate-scoped key `public-edge-tls/<substrate>/<fqdn>` in the
long-lived `pulumi_state_backend` S3 bucket and restored before every
issuance — is a registered `LongLived` managed resource with a typed
`discover` (read the retained object) and `destroy`, and
`Unreachable → refuse` gate semantics. That soundness rule (§3.1
invariant 2) is exactly the guarantee restored by closing the
`ChartPlatform.hs` `preservePublicEdgeTlsSecretBeforeDelete`
silent-success gap: an unobservable owned certificate must refuse, never
collapse to "absent/clean." Classified `LongLived` like `aws-ses`, it is
never auto-destroyed by `prodbox cluster delete` or `prodbox aws teardown`
and is removed only by `prodbox nuke`. The certificate lifecycle and the
production-vs-staging two-issuer model live in
[acme_provider_guide.md](./acme_provider_guide.md); its lifecycle-class
row is in
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

The scheduling of this doctrine into code is owned by
[DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
Sprints 4.20–4.22 and
[phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
Sprints 7.8, 7.21, and 7.22.

### 3.2 The destroy-invocation gate and corrupt-checkpoint prune

§3.1's soundness rule classifies a per-run stack's *residue* by observing its
encrypted checkpoint read-only (`observeStackCheckpoint` →
`classifyCheckpointBytes` → `Prodbox.Lifecycle.LiveResidue.queryOne`, Sprint
7.21). That funnel guards the *observation* — the cascade's `reconcileAbsent`,
the teardown gates, and the per-stack residue helpers. It does **not**, by
itself, guard the direct per-run **destroy-invocation** path (`prodbox aws
stack <stack> destroy --yes`, which the harness preflight/postflight also
issues): that path runs `destroy<Stack>Status`, which historically fetched
stack outputs (`pulumi stack output`) and read MinIO credentials before any
residue check, so a corrupt checkpoint crashed it with `unexpected end of JSON
input`, and a substrate without the in-cluster `minio` k8s secret crashed it
with `secrets "minio" not found`.

Sprint 7.22 closes that gap: each `destroy<Stack>Status` consults the same
read-only observation **first**, through the pure
`Prodbox.Lifecycle.LiveResidue.perRunDestroyDecisionFromStatus`:

- **Absent / empty** → skip (`PerRunDestroySkip`): nothing to destroy. This is
  the home-substrate steady state — the per-run AWS stacks were never
  provisioned — so the destroy returns success without touching `pulumi` or
  the in-cluster `minio` secret.
- **Present** → proceed (`PerRunDestroyProceed`) with the real destroy body.
- **Corrupt / unreadable** → refuse (`PerRunDestroyRefuse`), the §3.1
  soundness rule: a corrupt or unobservable checkpoint may hide live AWS
  resources, so it is fail-closed, never a silent skip. The refusal names the
  prune recovery.

The residue observation (and therefore this gate) resolves MinIO credentials
from Vault `secret/minio/root`, not the in-cluster `minio` k8s secret, so the
gate is reachable on any substrate whose Vault is unsealed — eliminating the
`secrets "minio" not found` failure mode on substrates that never provisioned
the per-run stacks.

**Corrupt-checkpoint prune.** A genuinely-corrupt (or empty) per-run checkpoint
— e.g. a truncated Model-B object left by an interrupted run — would otherwise
refuse forever. `prodbox aws stack <stack> prune-corrupt-checkpoint --yes`
(`Prodbox.Lifecycle.LiveResidue.pruneCorruptPerRunCheckpoint`) is the
doctrine-clean recovery: it observes the checkpoint and deletes the opaque
Model-B object **only** when it is corrupt or empty (idempotent no-op when
already absent), and **refuses** to prune a `Present` checkpoint (which may map
to live AWS resources — use `destroy` for that) or an unobservable backend
(fail-closed). Per-run stacks only; a corrupt long-lived `aws-ses` checkpoint
always refuses.

### 3.3 The derived restore/cleanup graph and total executor

Restore and cleanup are one graph of nodes, not a flat ordered step list. Each node names a
registered managed resource (or a registered restoration such as a chart re-reconcile), and its
`RequiresSuccess` / `RequiresAttempt` edges are **derived** from registered fact tables —
chart-dependency facts and storage-lifetime facts — never authored per call site. A dependency
that exists only as a comment, or only as a position in a list, is a defect: list position is
not dependency structure. The §5b/§5c drain-before-destroy `RequiresAttempt` edge is the worked
instance of the same edge algebra.

The executor over that graph is total:

- every node whose dependencies are satisfiable runs; a first failure never discards later
  independent nodes — a fail-fast fold that silently drops restorations independent of the
  failed sibling is a defect, not an acceptable simplification;
- a node whose dependencies cannot be satisfied is recorded as `NodeBlocked` with the offending
  dependency ids; blocked is an explicit outcome, never a silent omission;
- all failures aggregate into one report, the always-run cleanup fold of
  [Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-cleanup-failure-handling).

Three totality obligations are pure checks that run pre-cluster:

1. **Coverage.** The graph's node set equals the expectation derived from the registry under
   §3.1 invariant 5 — every `LongLived` entry a restore/ensure node, every `PerRun` entry a
   destroy node — for every input.
2. **Independence.** No `RequiresSuccess` path runs from the independent chart restorations to
   the retained-SES node; a restoration that merely shares a substrate with a failed sibling
   still runs.
3. **No orphaned retained reads.** No node reads retained-or-stronger state through a
   chart-lifetime transport that the same graph deletes; the storage-lifetime classes are owned
   by [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

Implementation is owned by Sprint `5.20` in
[phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md). This
document owns what the edges and obligations mean; fixture doctrine owns cleanup scheduling,
dependency blocking, and failure aggregation.

## 4. Predicate Library Inventory

Named `Precondition` values every destructive lifecycle command may
compose. The library lives at `src/Prodbox/Lifecycle/Preconditions.hs`
(introduced in Sprint 4.11). Sprints 4.20–4.21 (§3.1) generalize these
into the registry's `reconcileAbsent` reconciler — each predicate
becomes a class subset of the managed-resource registry — so this table
is the per-resource view of one uniform mechanism, not a parallel one.

| Predicate | Returns `Left` when | Used by |
|---|---|---|
| `noLiveLongLivedPulumiStacks` | `aws-ses` or retained TLS evidence is present/unreachable | Pre-cutover compatibility only. Target `aws teardown` deliberately retains these resources, and `nuke` reconciles their exact absence rather than using this refusal predicate. |
| `noLiveClusterTaggedAws` | The AWS Resource Tagging API returns any resource carrying `kubernetes.io/cluster/<cluster-name>` | Postflight of `prodbox cluster delete --cascade` and `prodbox nuke` |
| `noUndrainedK8sAwsResources` | `kubectl` reports any LoadBalancer Service, ALB Ingress, or Delete-reclaim PVC that hasn't been drained, **and** the cluster was reachable on the pre-drain `kubectl cluster-info --request-timeout=5s` probe | Postflight of K8s drain (Sprint 4.12); preflight of per-run Pulumi destroys when `--cascade` is set |
| `noLiveOperationalIamIdentities` | Any registered Lifecycle-provider or run-scoped AWS DNS01 IAM identity/key/role remains after its dependants; retained home Gateway-DNS/home DNS01/TLS/backup identities are excluded from ordinary teardown by class | Postflight of `prodbox aws teardown` and `prodbox nuke` |
| `noLeftoverRegisteredDnsRecords` | Any exact record whose command projection requires absence remains or is unobservable; ordinary cascade includes run-scoped AWS A/TXT records and excludes desired-present home A/TXT ownership | Postflight of `prodbox cluster delete --cascade` and `prodbox nuke` |

`DrainResult` is interpreted with an explicit `DrainPolicy` (see §3 layer 1). `DrainSucceeded`
satisfies the drain node. A positively observed absent disposable home control plane may classify
`DrainSkipped` as `CleanupSatisfiedWithReason`. On AWS, missing kubeconfig, unreachable API,
timeout, or every other skipped/unobservable drain is a cleanup failure, as is `DrainFailed` on
either substrate. The provider destroy still runs through a `RequiresAttempt` edge so a failed AWS
drain does not suppress the last-resort destroy, but destroy or tag-sweep success cannot erase the
drain failure. The durable cleanup fold and exact outcome names are canonical in
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-cleanup-failure-handling).

The singular `noLiveOperationalIamUser` and content-oriented
`noLeftoverDnsBootstrapRecords` helpers are pre-cutover compatibility predicates; they do not satisfy
the target registry contract.

`aws-ses` is **explicitly excluded** from every `cluster delete` path:
its `LongLived` cleanup class is retained across cluster teardown, so `aws-ses` may only be
destroyed by `prodbox aws stack aws-ses destroy --yes` or `prodbox nuke`. Its main checkpoint is
the encrypted Model-B object in MinIO (§2), whose durable bytes survive ordinary cluster deletion
with preserved `.data/`; cleanup classification, not backend location, determines this exclusion.

Default `prodbox cluster delete` carries **no per-run residue preflight at
all** — it is a pure local cluster uninstall that preserves `.data/` (the
MinIO-backed per-run Pulumi state) and never queries, gates on, or
destroys the per-run AWS backend. Deleting the cluster does not affect the
ability to reason about that state (it survives on `.data/`), so there is
nothing to fail closed on. All per-run AWS destruction is `--cascade`'s
job (which reconciles `PerRun` via `reconcileAbsent`, degrading gracefully
on an unreachable backend) or the explicit
`prodbox aws stack <name> destroy --yes`.

## 5. Mandatory Preflight for Destructive Commands

Every command in
`{prodbox cluster delete, prodbox aws teardown, prodbox aws stack
<stack> destroy, prodbox nuke}` must open with `checkAll [...]` over
the appropriate `Precondition` set. Failure renders the structured
leak list and the canonical remedy command per offending class. The
preflight runs **before** any cluster-side or AWS-side work so the
operator-named remedy commands actually still work (the cluster /
backend / credentials are still up at the point of refusal).

| Command | Preflight predicates | Default on residue |
|---|---|---|
| `prodbox cluster delete` | §5a no-install short-circuit, then a pure local uninstall (no per-run residue preflight) | n/a — uninstalls the cluster, preserves `.data/`, leaves per-run AWS stacks untouched |
| `prodbox cluster delete --cascade` | §5a no-install short-circuit, then none at entry — the command **is** the orchestration | Confirm-MinIO → drain → per-run destroys → test-EBS reaper → uninstall → sweep (see §5b) |
| `prodbox aws teardown` | No long-lived-absence predicate; prove exact Operational consumers quiescent, reconcile only Lifecycle-provider + AWS-run DNS01 absence, and observe/retain home Gateway-DNS/home DNS01/TLS/backup generations | Present `LongLived` resources are expected. Unobservable required authority/consumer evidence is a typed failure, never permission to delete or a reason to classify presence as residue. |
| `prodbox aws stack <stack> destroy` | (none beyond Pulumi's own dependency check) | n/a |
| `prodbox nuke` | TTY refusal; typed-confirmation literal `NUKE EVERYTHING`; required external decommission-receipt sink; otherwise no residue refusal — the command **is** the total-teardown orchestration | Freeze/export the backup-receipted signed decommission manifest, stop Authority, then resume the standalone receipt-journaled runner: drain/destroy; stop consumers and remove/read back external SMTP+SES/S3; keep home Agent/Vault live through target generations then SMTP/EAB custody tombstones; stop home; delete TLS prefix versions+identity without the shared bucket; finally prove every prefix absent and delete Authority backup plus the shared bucket last (§6b, §7). |

### 5a. No-Install Short-Circuit (Sprint 4.25)

`prodbox cluster delete` opens — in **both** the default and `--cascade` forms — by
probing whether an RKE2 install is present on the host *before* the preflight
predicate (or, for `--cascade`, the confirm-MinIO phase) runs. When no install is
found it prints `No RKE2 cluster to delete.` and exits `0`.

"Present" is the logical OR of the on-disk install markers (`/usr/local/bin/rke2`,
`/usr/local/bin/rke2-uninstall.sh`, `/var/lib/rancher/rke2`, `/etc/rancher/rke2`),
evaluated by `rke2InstallPresent` in `src/Prodbox/CLI/Rke2.hs`. The probe keys off
**install** state, not **service** state: an installed-but-stopped RKE2 still has a
cluster and per-run state on disk to delete and therefore still flows through the
full gate / cascade.

This is a **no-op short-circuit** ("there is nothing to delete, so I am done"),
categorically distinct from a `Precondition` ("I cannot proceed until X is
satisfied"). It is **not** a relaxation of the Sprint 4.19 fail-closed gate (§4):
the gate's `ResidueUnreachable → refuse` rule still applies in full whenever an
RKE2 install exists. The short-circuit only resolves the degenerate case where the
cluster — and with it the in-cluster MinIO state backend — is already entirely
gone, which the gate alone cannot distinguish from "MinIO is transiently
unreachable while a cluster still exists". Because the short-circuit takes no
destructive action, `.data/` (and any per-run Pulumi state it still holds) is left
untouched.

### 5a.1. Inotify Host-Prep (first host-prep step)

Immediately after the §5a no-install short-circuit confirms an RKE2 install is
present — and **before** the preflight predicate (default form) or the confirm-MinIO
phase (`--cascade`) — both delete forms run `ensureHostInotifyLimits`. It is the same
idempotent host-prep step that opens `prodbox cluster reconcile`: it persists
`/etc/sysctl.d/99-prodbox-inotify.conf` (`fs.inotify.max_user_instances = 8192`,
`fs.inotify.max_user_watches = 1048576`) and applies it via `sysctl --system`, writing
only on drift. The `99-` prefix is deliberate: `sysctl --system` applies drop-ins in
lexicographic filename order (last wins), and `/usr/lib/sysctl.d/30-tracker.conf` pins
`max_user_watches = 65536`, so the drop-in must sort after it to take effect. The kernel
default `max_user_instances = 128` is too low for RKE2 +
containerd + kubelet (all uid 0), so when systemd (PID 1) unwinds the RKE2 units during
teardown it would otherwise log `Failed to allocate directory watch: Too many open files`
to the console. Raising the limit first eliminates that warning at its root rather than
filtering it after the fact (see
[streaming_doctrine.md § 6](./streaming_doctrine.md#6-lifecycle-destructive-success-versus-failure-rule)).
Placing it before the preflight mirrors §5a: it is local-host kernel config, not
cluster-side or AWS-side work, and it is non-destructive and idempotent, so running it
ahead of a possible residue refusal is harmless.

### 5a.2. RKE2 Resource Guardrails (install/reconcile host-prep)

`prodbox cluster reconcile` begins its install/reconcile path by applying the
resource guardrails derived from `capacity.resource_plan`, before installing or
restarting RKE2 and before any chart render can create workloads. The step is
owned by lifecycle because it writes host/RKE2 control-plane files, not chart
manifests:

- `/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml` carries
  kubelet args for `system-reserved`, `kube-reserved`, `eviction-hard`,
  `eviction-soft`, image garbage-collection thresholds, and container log caps.
- `/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf`
  carries accounting plus `CPUQuota`, `MemoryHigh`, `MemoryMax`, and `TasksMax`
  for the RKE2 process tree.

The reconciler observes host cpu, memory, and filesystem capacity first. If the
observed host is smaller than the authored `host_capacity`, it refuses before
mutating these files. This is the runtime counterpart of the static
`rke2.reserved + eviction.floor <= host.physical` lemma in
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md). It bounds
RKE2/kubelet/containerd; pod-level runaway behavior is separately bounded by
the chart-rendered Kubernetes `resources`, `ResourceQuota`, and `LimitRange`.

### 5a.3. Reconcile Bring-Up Order Is a Projection Over the Component Graph (Sprints 4.43/4.45)

`prodbox cluster reconcile`'s bring-up steps are not two hand-written parallel
lists any more. The plan narration and the executor both project from a single
typed projection (`nativeInstallStepOrder` in `src/Prodbox/CLI/Rke2.hs`), so the
`STEP=…` preview and the executed order cannot drift. Sprint `4.45` makes that
projection graph-authoritative:

```haskell
nativeInstallStepOrder dag =
  concatMap stepsForComponent (componentReconcileOrder dag)
```

The plan compiler appends the separately-owned edge tail only when edge reconcile
is requested. It validates the Tier-0 component DAG, native step inventory,
component anchors, dependency order, phase monotonicity, edge placement, and
readiness-target coverage before producing `NativeInstallPayload`. That payload
carries the validated DAG and exact run order consumed by both narration and apply;
an invalid expansion is a fail-closed `StructuredError`, not a test-only warning.

Every native component declares pure operation-scoped capability requirements. After the final
step in its component group, runtime reconnaissance resolves and admits the exact
`CapabilityRef` used by the dependent action; there is no injected one-shot action. Registry
publication uses its exact registry/storage mutation-and-read-back capability immediately before
the first image write. The graph declares
registry dependencies for cert-manager, the Bootstrap Broker, MetalLB, Envoy
Gateway, and Percona. Vault-unsealed depends on the Bootstrap Broker; the Lifecycle Authority and
Target Secret Agent depend on unsealed Vault, and the Lifecycle Authority additionally depends on
steady-state MinIO. Bootstrap baseline also precedes genesis-signing and retained-home TLS-envelope
trust. Authority Backup Adapter, TLS Retention Adapter, and fenced Provider Worker are independent
steady workloads with distinct capability edges. Credential Provisioner and Admin Action Runner are
permit-bound Job nodes, not injected callbacks: genesis admits only the former under
`GenesisBackupPermit`; normal provider/TLS work waits for permanent genesis-disable and
`AdmissionOpen`; admin actions require their own backup-receipted permit. MetalLB, Envoy Gateway,
and Percona also depend on unsealed Vault. The former
aggregate MetalLB/Envoy/Percona runtime action is three
first-class anchored steps, and bootstrap/steady executors are total constructor
matches. The redundant home MinIO steady-state step is removed because it had no
distinct mutation. Exact readiness edges and probe depth belong to
[Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md); physical service placement
belongs to
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

### 5b. Canonical Cascade Order

`prodbox cluster delete --cascade --yes` compiles these phases into the always-run cleanup DAG.
The dependency order is deliberate and matches §1: the K8s drain runs **before** any per-run Pulumi destroy so
the in-cluster controllers (AWS Load Balancer Controller, cert-manager) are still
alive to unwind their AWS-side state. Only then does Pulumi delete the substrate (VPC,
subnets, EKS cluster), at which point the controller-owned ENIs / ALBs are already gone
and Pulumi's deletes have no dependencies to trip on. The pre-created retained EBS
volumes are `Retain` and are deliberately preserved (not drained); a detached `Retain`
volume is not a subnet dependency, so it never blocks teardown.

| # | Phase | What it does | Failure mode |
|---|---|---|---|
| 1 | Confirm encrypted checkpoint reachability | The retained Lifecycle Authority observes each per-run checkpoint/operation through its exact capability. The result remains `ResidueAbsent`, `ResiduePresent`, or `ResidueUnreachable`; inability to read retained state is never absence. | `ResidueUnreachable` records an unresolved cleanup failure. Independent drain, AWS discovery, local restoration, and tag/EBS cleanup still run, but the aggregate cannot report success until authority state is resolved. |
| 2 | K8s drain and controller-family absence | Delete LoadBalancer Services, ALB Ingresses, and any `Delete`-reclaim PVCs while controllers are live; observe each registered `ControllerResourceFamily`; and submit its fenced exact-child absence intent for verified survivors. The pre-created retained EBS PVs are `Retain` and are intentionally not deleted here. On AWS the drain MUST target the EKS API server. If the API is unreachable, the phase emits `DrainSkipped`; the substrate fold retains the AWS failure and satisfies only the `RequiresAttempt` edge to phase 3. | `DrainFailed`, AWS `DrainSkipped`, unbounded/mismatched child inventory, or any child without authoritative absence is a cleanup failure. Home may classify a positively absent disposable control plane as satisfied-with-reason. None suppresses the provider-destroy attempt or becomes success because a later sweep is empty. |
| 3 | Per-run Pulumi destroys | After phase 2 has been attempted, submit or resume the durable fenced destroy operation for each present stack through retained Lifecycle Authority. The provider worker hydrates the immutable checkpoint into bounded scratch even when the drain failed, so last-resort provider cleanup can still make progress. | Missing credentials, unreadable authority state, `DependencyViolation`, response loss, or provider ambiguity remains a typed nonterminal/failure. The DAG continues independent nodes and recovery uses the same operation ID. |
| 4 | RKE2 uninstall | `/usr/local/bin/rke2-uninstall.sh` under the lifecycle-local quiet path. Removes substrate + managed kubeconfig. `.data/` is preserved. | Non-zero uninstall exit is reported through `summarizeRke2DeleteFailure`. |
| 5 | Postflight cluster-tag sweep | On the sweep-owning `cluster delete --cascade` and `nuke` surfaces, run `discoverClusterTaggedAwsResources`; the cascade carves out intentionally retained long-lived classes, while `nuke` does not. | A non-empty escapee list or unobservable required inventory is an aggregated failure for that command. It never becomes warning-only success and never replaces exact family/record absence. |

**Substrate-aware drain.** The drain phase (#2) MUST use the substrate's own
kubeconfig — `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` for `SubstrateHomeLocal`,
`KUBECONFIG=<substrate-kubeconfig-path>` for `SubstrateAws`. The canonical bracket
is `Prodbox.PublicEdge.withSubstrateKubectlEnvironment` which also sets the
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` /
`AWS_SESSION_TOKEN` env vars that `aws eks get-token` (the EKS kubeconfig's exec
provider) needs to authenticate. A drain phase that hard-codes the local-cluster
kubeconfig on the AWS substrate walks the wrong cluster, reports nothing to drain,
and lets phase 3 fail with `DependencyViolation` on subnet deletion.

This is the doctrine-canonical order. The pre-Sprint-4.17.a sequence
(destroys → drain) inverted phases 2 and 3 and was harmless on the home substrate
(no in-cluster controllers create AWS resources) but fatal on the AWS substrate
(the LBC creates ENIs / ALBs; destroying the EKS cluster before draining them produces
orphan resources that block subnet deletion — the pre-created EBS volumes are `Retain`
and are preserved by design, not orphans).
The postflight tag sweep (phase 5) is the backstop for any controller-created AWS
resources that escape the drain, not a substitute for running the drain first.

### 5c. Per-Run EKS Destroy Drains the Cluster First (Sprint 4.23)

The target cleanup DAG preserves the drain-before-destroy dependency but uses an attempt edge for
last-resort provider cleanup: a failed or skipped drain does not suppress the destroy attempt, and
the destroy attempt does not erase the drain failure. Both outcomes remain in the aggregate report.
The Sprint `4.23` detail below is the pre-redesign implementation record consumed by that target.

The drain-before-destroy invariant of §5b applies not only to the `--cascade`
orchestration but to the **per-run `aws-eks-test` Pulumi destroy itself**. As of
Sprint 4.23, `Prodbox.Infra.AwsEksTestStack.destroyAwsEksTestStackStatus` runs a
best-effort K8s drain (LoadBalancer Services, ALB Ingresses, Delete-reclaim PVCs)
against the per-run EKS cluster's own kubeconfig immediately **before** `pulumi
destroy`. Because both the harness postflight (`prodbox aws stack eks destroy --yes`
from `awsPostflightDestroyActions`) and the cascade
(`Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route
through this destroy, the drain covers both paths — closing the gap where the
harness postflight's per-run EKS destroy raced AWS's async ENI cleanup and hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (the May
28/29 incidents). This extends Sprint 4.17.b's substrate-aware cascade drain to the
per-run destroy path, targeting the per-run EKS cluster rather than the host
substrate's cluster.

An absent EKS kubeconfig, unreachable cluster, drain failure, or drain timeout therefore records a
typed cleanup failure and still permits the provider destroy attempt as the last line of defense.
The worst case remains `DependencyViolation`; §5d's credential-preservation and the durable
operation ID make that retryable without misreporting the incomplete cleanup as success.

### 5d. Historical Shared-Credential Postflight Record (Sprint 7.10)

The `prodbox test ...` harness postflight (`Prodbox.TestRunner.runWithAwsHarnessCleanup`)
runs the per-run Pulumi destroys on every exit path (Sprint 7.6 orphan-safety) and
then, historically, always cleared operational `aws.*` and deleted the operational
`prodbox` IAM user via `runManagedAwsHarnessTeardown`. As of Sprint 7.10 the
operational-credential teardown runs **only when the per-run destroy succeeded**
(pure decision `clearOperationalCredsAfterPostflight :: ExitCode -> Bool`, `True`
iff `ExitSuccess`). When a per-run destroy fails (e.g. the §5c
`DependencyViolation` before Sprint 4.23 fully closes it), the orphaned per-run
stacks still hold live AWS resources whose destroy path requires operational creds;
clearing those creds would strand the orphans. The postflight therefore **holds**
the teardown, preserves operational `aws.*` + the operational user, and emits a
diagnostic naming the recovery path: resolve the destroy failure (e.g. wait out /
clean up the orphan ENIs), then `prodbox aws stack <stack> destroy --yes` for each
remaining per-run stack, then `prodbox aws teardown`. The per-run destroy failure is
still surfaced as a non-zero exit.

This is the per-run analog of §5's Sprint 7.9 change: Sprint 7.9 stopped the
teardown from **refusing** on long-lived `aws-ses` residue. Clearing operational
credentials and deleting the registered SES lease role cannot strand retained SES because the
explicit destroy/migration surfaces remain admin-credentialed; a later canonical reconcile first
re-establishes the operational user policy and role through setup. Sprint 7.10 **holds** the
teardown when the per-run auto-destroy — which *does* need operational creds —
failed. The two are complementary safety rules on the same teardown.

The target generalizes the safety property without a shared credential: each IAM/key/Vault
generation cleanup node depends on every resource cleanup that uses that exact identity. A failed
provider destroy preserves the Lifecycle-provider generation. The Authority-backup-store generation
and TLS-retention-store generation are independently `LongLived` and are never ordinary cleanup
nodes. Home Gateway-DNS and home cert-manager-DNS01 generations are also retained while their
restored consumers remain live; AWS cert-manager-DNS01 is run-scoped and is cleaned only after its
AWS Certificate/Challenge/TXT dependants. IAM/key deletion must succeed before the matching
ordinary Vault tombstone; all independent cleanup still runs. The exported `nuke` exception keeps
home Agent/Vault alive through retained-generation tombstones and receipts every later admin-side
deletion externally.

### 5e. Harness Residue Bypass Is Per-Run Only (Sprint 7.34)

The harness preflight/postflight residue policy bypasses **per-run** residue only
(`BypassPerRunResidueForHarnessRefresh`): the refresh clears operational `aws.*` and per-run
stacks unconditionally, but the long-lived `aws-ses` and `public-edge-tls` residue protection of
the lifecycle preconditions is never bypassed by automation. The broader
`BypassAllResidueForHarnessRefresh` arm conflated destroyability with should-destroy — it can
destroy the retained long-lived stack the preconditions otherwise protect — and is superseded by
the narrowed policy. Long-lived destruction remains explicit and operator-driven (§7):
`prodbox aws stack aws-ses destroy --yes` for the `aws-ses` stack, and `prodbox nuke` as the only
total-teardown path; no harness or automation surface acquires that authority through a residue
policy. This narrowing reverses the residue half of the Sprint `7.9` decision recorded in §5d;
the §5d per-run credential-hold rule (Sprint `7.10`) stands unchanged. The narrowing is owned by
Sprint `7.34` in
[phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
the policy history lives in
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md).

## 6. Scoped Mandatory Postflight Tag Sweep

The command matrix in §5 assigns a mandatory cluster-tag sweep only to
`prodbox cluster delete --cascade` and `prodbox nuke`. It is not silently generalized to default
`cluster delete`, `aws teardown`, an individual stack destroy, or every future destructive command;
adding a sweep-owning surface requires an explicit row in that table. On the two owning surfaces, a
non-empty result is a hard failure: the command reports the leak list, the canonical registered
remedy per offending class, and exits non-zero.

The sweep is independent defense-in-depth for a controller/resource that diverged from its exact
registered family. It is not the ownership registry, cleanup interpreter, or sole detector of
operator-created AWS resources. Exact child-family/record observation and destroy/read-back remain
mandatory even when the sweep is empty.

**A required tag sweep is fail-closed.** On either owning surface, a sweep that cannot reach the AWS
Resource Tagging API to confirm the absence of cluster-tagged residue is
a hard failure, never a silent pass — the same soundness rule as §3.1
invariant 2 (`Unreachable → refuse`). This applies in particular to
`prodbox nuke`'s step-4 tag sweep (§5, the nuke total-teardown
orchestration): the final tag sweep must fail closed, so an
unconfirmable sweep stops the command with a non-zero exit and a
diagnostic rather than reporting "clean." "Could not observe the
absence of residue" is treated as "residue may be present," never as
"residue is absent."

The tag sweep lives at `src/Prodbox/Lifecycle/TagSweep.hs` (introduced
in Sprint 4.11; extended for the full cluster-tag scan in Sprint 4.12).

### 6a. IAM Is Registry-Owned, Not Tag-Sweep-Owned

The AWS Resource Groups Tagging API does not enumerate IAM reliably enough to be an ownership
authority. The target therefore has no IAM “blind spot” delegated to §6:

1. Every Lifecycle-provider, Authority-backup-store, Gateway-DNS, cert-manager-DNS01, LBC, EBS-CSI, EKS cluster, and EKS
   node identity/policy/attachment is an exact singleton or bounded family descriptor with typed
   observe/ensure/destroy/read-back operations. Vault generation/tombstone resources remain separate
   descriptors with dependency edges.
2. Provider inputs assign deterministic, operation-bound IAM names and paths before create; they do
   not accept provider-generated `clusterRole-*` or `nodeRole-*` names. The descriptor records
   account, partition, path/name/ARN, trust-policy digest, attachment set, cluster UID, operation ID,
   and provider revision. A create intent and cleanup obligation are receipt-committed before
   Pulumi/AWS sees the request, so checkpoint loss does not erase the coordinate.
3. IAM reconciliation queries IAM directly by those exact coordinates. It refuses a trust/policy/
   attachment mismatch, deletes in dependency order, and read-backs key, attachment, policy, role,
   and Vault-tombstone absence. A broad prefix scan or tag result never authorizes deletion.
4. Pre-cutover auto-named roles are a finite migration input, not a permanent residual. While the
   old checkpoint and stack observations are still readable, migration writes every exact legacy
   If legacy state is already missing, the admin-authorized migration may use read-only IAM/EKS and
   audit-event observations to establish the same exact tuple, but no deletion occurs until the
   operator confirms that bounded manifest through the public plan. Ambiguous candidates block
   cutover. The harness then imports or destroys each registered ARN and proves absence; production
   cutover cannot complete while an auto-named role remains unregistered.

The fixed historical LBC/EBS-CSI names are handled by the same manifest/registry path rather than a
special preflight delete. After cutover, source/plan lint rejects every auto-named IAM create and
every IAM create without its registry descriptor and durable cleanup proof.

### 6b. `nuke` Transfers Authority to an External Decommission Receipt

Ordinary reconciliation cannot delete the store required to receipt its own transition. `nuke`
therefore first freezes Lifecycle Authority and uses `AuthorityDecommissionExport` to commit and
backup-read-back a deterministic signed manifest of every exact singleton/family coordinate,
generation, dependency, and destroy/read-back program. The operator/harness must supply a receipt
sink outside `.data`, the cluster, Vault, primary MinIO, backup S3, and every other manifest target.
Before Authority stops, that sink must also hold or durably address the exact runner artifact whose
build/verifier/schema digests the manifest pins. The CLI writes, fsyncs file+directory, reopens, and
verifies the manifest, receipt, and artifact there; Authority receipt-commits
`DecommissionExported` against that digest and permanently stops before deletion starts.

The standalone `DecommissionRunner`, not stopped Authority, owns the remaining Plan/Apply. It uses a
fresh ephemeral admin prompt only after verifying the build/Tier-0/Broker-pinned Authority signer,
external receipt, closed compiled program tags, and exact registered coordinates. It appends and
read-backs every node attempt/result as length-delimited, checksummed, hash-chained frames with
stable attempt IDs. Torn incomplete tail may be discarded; a complete conflict, corrupt/unobservable
receipt, or different runner build/schema refuses. Crash recovery re-observes an effect before retry.
Tampered manifest/key/receipt, unknown tag, or widened coordinate refuses before prompt. Target Secret Agent
accepts the exported manifest only for named decommission tombstones. The runner stops/read-backs
SMTP consumers and deletes/read-backs the external SMTP key/identity/policy plus non-credential
SES/S3 family before Vault tombstones. Home Agent/Vault/Gateway/cert-manager and required
control-plane Pods remain live through home record/Certificate/Challenge absence, every target
SMTP/EAB generation tombstone, and the distinct retained-home SMTP/EAB custody tombstones; then the
runner stops/uninstalls home control plane and optional `.data`. It deletes every TLS prefix object version and TLS identity/key without deleting
the shared bucket. The final Authority-backup node deletes its objects/versions,
`secret/aws/authority-backup-store` generation, key, identity/policy, proves every registered shared
bucket prefix absent, and deletes the `pulumi_state_backend` bucket last. It then appends terminal
absence and the required scoped tag sweep to the external receipt. It never requires or claims a
backup receipt after backup deletion.
The complete state boundary is canonical in
[Lifecycle Control-Plane Architecture §11.1](./lifecycle_control_plane_architecture.md#111-total-decommission-and-the-final-backup-deletion).

## 7. What Is Out of Scope for `cluster delete`

`aws-ses`, the operator's parent Route 53 zone, the long-lived
`pulumi_state_backend` bucket, and any other long-lived shared
infrastructure never participate in `cluster delete`'s residue policy.
The only sanctioned paths to destroy them are:

- `prodbox aws stack aws-ses destroy --yes` for the `aws-ses` stack
  (operator-driven, explicit, never automatic; submits the backup-receipted `DestroyAwsSes`
  Admin Action Runner program). Its aggregate result stops/read-backs consumers, deletes/read-backs
  the SMTP key/identity/policy and non-credential SES/S3 family in dependency order, then
  tombstones/read-backs every target SMTP generation and retained-home SMTP custody while the home
  Agent/Vault remain live; every stage failure is retained.
- `prodbox nuke` for total teardown of every prodbox-owned AWS
  resource, including long-lived ones. TTY-only, no `--yes`
  shorthand, requires the typed confirmation literal `NUKE EVERYTHING`.
- Manual operator action against the parent Route 53 zone (it is
  operator-managed; the harness does not own it).

The retained long-lived bucket is created idempotently by `ensureLongLivedPulumiStateBucket` and
destroyed only by `prodbox nuke`'s final pass — never by `aws teardown`, never by `cluster delete`,
never as a side effect of any other command.

## Vault in the cluster lifecycle

Vault is the fail-closed secrets / encryption-as-a-service authority layered
*beneath* the existing reconciler model — it extends, and does not replace, the
managed-resource-registry teardown and the canonical cascade order above. The
in-cluster Vault is the single source of truth for the Vault secret model; this
section records only how the lifecycle commands integrate it. See
[vault_doctrine.md](./vault_doctrine.md) for the full model.

- **Reconcile deploys bootstrap MinIO and Vault around the dedicated Bootstrap Broker.**
  `prodbox cluster reconcile` deploys retained storage, brings MinIO to a
  bootstrap-readable state, deploys (or rebinds) Vault on its durable `.data/`-backed PV, and
  submits the bounded init/unseal request to the loopback-restricted Bootstrap Broker. The broker
  controller validates only secret-free metadata/fences and creates a separately attested one-shot
  worker for each init and unseal request; the CLI sends prompt bytes directly to the verified Pod
  over authenticated exec/attach stdin. On first init, the initialization worker password-seals and
  reads back `PreparedInitEnvelope`, calls `/sys/init` only with its committed recovery/burn public
  keys, stores and reads back the encrypted init response, atomically promotes and reads back the
  final unlock bundle, then deletes/read-backs the prepared envelope. Only a distinct unseal worker
  may later fetch/decrypt that final bundle and submit threshold shares. Each worker revokes/exits
  and is observed absent. After
  Vault is unsealed and its policies are reconciled, steady-state MinIO becomes available and the
  independently deployed Lifecycle Authority, Target Secret Agent, Gateway Runtime, and
  secret-dependent charts may become ready. The Gateway Runtime is never a bootstrap fallback.
  See [vault_doctrine.md §7](./vault_doctrine.md#7-vault-lifecycle-commands) for unlock semantics,
  [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md) for the exact dependency graph,
  and [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) for
  physical capability ownership. An `Unreachable` capability observation is bounded and
  gate-closed (§3.1), never treated as ready.
- **Teardown preserves the durable Vault PV.** `prodbox cluster delete --yes` and
  `prodbox cluster delete --cascade --yes` preserve the durable Vault PV exactly
  like the MinIO PV (§2); no `prodbox` command removes it. A wiped-and-rebuilt
  cluster reattaches the same Vault data, mirroring the per-run-state-survives-wipe
  guarantee for MinIO.
- **A sealed Vault is a first-class status line, never hidden.** A sealed or
  unreachable Vault surfaces as an explicit `cluster status` / `edge status` line;
  secret-dependent lifecycle work fails closed behind an explicit readiness gate
  rather than degrading silently. See
  [vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix).
- **Pulumi/AWS operations gate on Vault readiness.** Every real `prodbox aws stack ...`
  apply/destroy/migrate action runs the Sprint `1.37` Vault gate before touching state and
  refuses with a redacted sealed-Vault error **before any AWS mutation** when Vault is
  unreachable, uninitialized, or sealed. Dry-runs render the plan without probing Vault. Sprint
  `7.14` extends the same gate with Transit-key and backend-decryptability checks for the encrypted
  Pulumi checkpoint wrapper. See
  [vault_doctrine.md §10](./vault_doctrine.md#10-pulumi-backend-under-vault).

## Related Documents

- [README.md](README.md)
- [aws_admin_credentials.md](aws_admin_credentials.md)
- [aws_integration_environment_doctrine.md](aws_integration_environment_doctrine.md)
- [cli_command_surface.md](cli_command_surface.md)
- [integration_fixture_doctrine.md](integration_fixture_doctrine.md)
- [prerequisite_doctrine.md](prerequisite_doctrine.md)
- [pure_fp_standards.md](pure_fp_standards.md)
- [unit_testing_policy.md](unit_testing_policy.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../documentation_standards.md](../documentation_standards.md)
- [../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- [../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
- [../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
- [the engineering doctrine docs](../../documents/engineering/README.md)
- [../../CLAUDE.md](../../CLAUDE.md)
