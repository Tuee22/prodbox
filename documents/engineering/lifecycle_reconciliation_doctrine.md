# Lifecycle Reconciliation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Single Source of Truth for how prodbox reconciles resource presence, recovers
> teardown authority, and proves desired absence across local, Kubernetes, and AWS boundaries.

This doctrine names the resource classes, sets the rule that Pulumi state lifetime must match
resource lifetime per class, and defines desired-presence, durable-operation, fencing, recovery,
target-delivery, and desired-absence semantics.

This document owns lifecycle meaning. The independently scheduled Bootstrap Broker, Lifecycle
Authority, Credential Provisioner, Admin Action Runner, fenced Provider Worker, Authority Backup
Adapter, TLS Retention Adapter, Target Secret Agent, and Gateway Runtime boundaries are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); no service or
transport named here may acquire authority merely because it is reachable or happens to share a
Deployment with an older implementation.

This is target-state doctrine. Implementation status, migration order, active sprints, legacy
removal ownership, and deployment qualification live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md) and its
[deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). Present-tense normative
language below specifies the accepted end state; it is not a claim that the pre-cutover cascade
already implements it.

## 1. Leak Classes

The concrete resource inventory and each resource's assigned `LifecycleClass` are owned by the
registry-generated
[Development Plan substrate inventory](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
This doctrine owns the meaning of those classes and must not restate that changing inventory:

| Lifecycle class | Cleanup meaning |
|---|---|
| `PerRun` | Eligible for the aggregate cascade and for its exact explicit per-run surface; scheduling occurs on every owning run exit, but only exact absence evidence closes the obligation. |
| `LongLived` | Excluded from ordinary cascade by type. Desired presence may still be required. Destruction needs the exact explicit-long-lived aggregate permit or the external total-decommission permit. |
| `Operational` | Not a per-run resource. It is selectable by operational teardown and, for the exact credential/lease dependencies used by a cascade, by the cascade only after every registered consumer is terminal. It never enters explicit stack cleanup merely because that stack used it. |

Lifecycle class is orthogonal to `ResourceKind`: stacks, bounded controller families, singletons,
topics, and credentials all use the same keyed observation/desired-absence/read-back contract.
`LocalSubstrate` is deliberately outside `ManagedResource` and has separate local-only,
cascade-final, and externally permitted total-decommission targets in §3.1. Tags, names, checkpoint
contents, backend locations, and discovery rows never choose either axis.

Typed family/record cleanup, EKS drain, authoritative absence read-back, and the scoped terminal
audit make it impossible to report clean while an observed obligation remains. Partial or
unobservable cleanup remains explicitly incomplete. The audit cannot substitute for exact
controller-child, DNS, IAM, key, object, bucket, EBS, or stack absence. Production-retained EBS is
excluded from ordinary desired absence by its `LongLived` index; registered test-scoped EBS is
selected by the matching `PerRun` projections and closes only on exact read-back. The exact storage
policy is owned by [Retained Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md).

The EKS drain attempt precedes provider stack destruction so live controllers can unwind children;
failure still opens only the registered `RequiresAttempt` backstops. The terminal audit follows
exact cleanup and reports unexpected resources or incomplete observation. Neither phase manufactures
an owner or changes lifecycle class.

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
| Per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) | Immutable encrypted checkpoint blobs referenced from the retained Lifecycle Authority aggregate in primary `prodbox-state` and read-back in the independently registered backup store before promotion | Scratch `file://<tmp>` backend hydrated by `Prodbox.Pulumi.EncryptedBackend` inside the fenced provider worker | Selected for lifecycle-owned always-run cleanup; operation/checkpoint evidence remains queryable until exact absence or an explicit incomplete result |
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
are different authorities even when both happen to run on the home cluster. The retained local
RKE2 control plane is mandatory; AWS is an optional target selected by the
plan, not an alternate authority. Every AWS effect follows an authenticated CLI submission to the
retained Lifecycle Authority and its exact worker/adapter interpreter. Failure to establish that
path is an `Unobservable`/incomplete outcome, never permission for host-direct mutation.

The pure lifecycle plan receives two non-interchangeable coordinates:

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
`public-edge-tls/<substrate>/<canonical-scope-key>` ciphertext objects; it cannot reach Authority backup bytes.
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
--cascade`) can resume cleanup from the retained state once the recovery capabilities are
available. Preservation keeps recovery possible; it is not evidence that cleanup completed, and
an unobservable authority or provider remains an explicit incomplete result.

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
dereferenceable by the other. Each `(substrate, canonical scope set)` has one fenced
pending/current fold binding
Secret UID/resourceVersion equality witness, cert serial/validity/SPKI, Authority sequence, immutable
S3 object version, and byte/digest read-back. Promotion re-observes the exact source Secret; stale,
out-of-order, validity-regressing, or unpermitted different-key candidates refuse. Restore uses the
receipt-committed current immutable version for that exact canonical scope set, never S3
latest/list order and never a merely covering `impliedBy` coordinate. A different
`Certificate.spec.dnsNames` set is a distinct cert-manager issuance specification and therefore a
distinct retention key. The restore fold is total:
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
| TLS ciphertext retention/restore | TLS-retention-store generation | The separate TLS Retention Adapter alone reads `secret/aws/tls-retention-store` and accesses exact `public-edge-tls/<substrate>/<canonical-scope-key>` objects. It sees only ciphertext/wrapped-DEK bytes; home Target Agent's dedicated Transit lane owns DEK issue/unwrap. |
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
encrypted `LogicalPulumiStack <stack-id>` object is absent, that Job may log into only the permit's
exact `legacy-pulumi/aws-ses` source and export its raw checkpoint into bounded scratch. The Runner
does not open an Authority object store. It sends the permit and source bytes through the
runner-only authenticated Authority execution route; Authority first CAS-persists the prepared
migration, canonicalizes the checkpoint in RAM scratch, submits the registered `aws-ses` checkpoint
operation, and confirms both primary and backup read-back before returning the destination
reference. Only then may the Runner delete the legacy stack and submit exact source-absence
evidence, which Authority CAS-commits as completion. Stable operation ID and permit-bound source
digest resume response loss; no host-direct login or object-store fallback exists.

**Quota request journal.** `RequestServiceQuotaIncrease` has no provider client token. Authority
therefore CAS-persists the exact service/quota/region/desired-value attempt and absolute time window
before the Runner may dispatch it. Recovery reads current quota plus the complete paginated request
history. An exact tuple inside that attempt window completes the journal; otherwise two consecutive
authoritative absence scans are required before the sole retry is armed. A second attempt is the
maximum, and another stable absence refuses rather than widening or looping the request.

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

## 3. Exact-Keyed Desired-Absence Reconciliation

Resource truth is never inferred from the continued existence, readability, or contents of a
checkpoint. A checkpoint is authoritative only for whether a provider operation can be resumed.
AWS, Kubernetes, Vault, and the other managed systems remain authoritative for the resources they
hold. Teardown observes those facts separately, joins them only by an exact registered resource key,
and makes every mutation decision in a total pure function.

This is a recover-to-clean reconciler, not a best-effort phase list. The effectful boundary may
observe external systems and interpret a closed program, but it may not decide resource identity,
scope, cardinality, lifecycle class, dependency order, or what constitutes completion.

### Why not a global state machine

AWS, Kubernetes, Vault, checkpoint storage, and the retained Authority are independent external
authorities observed at different revisions and failure boundaries. Indexing one value by a single
global “world state” would claim that those observations are simultaneous and complete when no
interpreter can establish that fact. External state therefore stays in separate flat exhaustive
ADTs, each carrying its authority, exact key, scope, revision, and partial/unobservable arms.

GADTs and type indices are used only for program-owned facts: lifecycle class, cleanup surface,
the legal input witness for an operation, and the evidence its result must return. A pure decision
joins external observations by exact registered keys; it never promotes them into an indexed claim
about the world. This is the boundary between making illegal *program transitions*
unrepresentable and honestly modelling a fallible external system.

### 3.1 The managed-resource registry and exact observation boundary

The registry is a pure, closed inventory of everything prodbox may create directly or through a
controller. Static facts that govern which operations are legal are indexed; facts observed from an
external system are not.

```haskell
-- Example: hypothetical lifecycle teardown registry
data LifecycleClass = PerRun | LongLived | Operational
data ResourceKind = Stack | ControllerFamily | Singleton | Topic | Credential | LocalSubstrate

data PresenceProgram resource
  = ObserveOnly
  | EnsureCapable (EnsureProgramTag resource)

data RegistryResourceKind (kind :: ResourceKind) where
  StackResource :: RegistryResourceKind 'Stack
  ControllerFamilyResource :: RegistryResourceKind 'ControllerFamily
  SingletonResource :: RegistryResourceKind 'Singleton
  TopicResource :: RegistryResourceKind 'Topic
  CredentialResource :: RegistryResourceKind 'Credential

data ManagedResource resource (life :: LifecycleClass) (kind :: ResourceKind) = ManagedResource
  { resourceRef :: RegisteredResourceRef resource kind
  , resourceKind :: RegistryResourceKind kind
  , resourceCoordinate :: ManagedResourceCoordinate
  , resourceOwner :: ServiceIdentity
  , resourceScope :: AuthorityScope
  , resourcePresenceProgram :: PresenceProgram resource
  , resourceObserver :: ObserverProgramTag resource kind
  , resourceDestroyer :: DestroyProgramTag resource kind
  }

data CleanupSurface
  = LocalOnly
  | Cascade
  | ExplicitPerRun
  | OperationalTeardown
  | ExplicitLongLived
  | TotalDecommission

data DirectCleanupKind (kind :: ResourceKind) where
  CleanupControllerFamily :: DirectCleanupKind 'ControllerFamily
  CleanupSingleton :: DirectCleanupKind 'Singleton
  CleanupTopic :: DirectCleanupKind 'Topic
  CleanupCredential :: DirectCleanupKind 'Credential

data CascadeOperationalDependency resource kind -- abstract

data CleanupTarget
  (surface :: CleanupSurface)
  resource
  (kind :: ResourceKind) where
  LocalOnlyTarget
    :: RegisteredLocalSubstrate
    -> CleanupTarget 'LocalOnly LocalRke2 'LocalSubstrate
  CascadeTarget
    :: ManagedResource resource 'PerRun kind
    -> CleanupTarget 'Cascade resource kind
  CascadeOperationalTarget
    :: CascadeOperationalDependency resource kind
    -> ManagedResource resource 'Operational kind
    -> CleanupTarget 'Cascade resource kind
  CascadeLocalTarget
    :: RegisteredLocalSubstrate
    -> CleanupTarget 'Cascade LocalRke2 'LocalSubstrate
  ExplicitPerRunTarget
    :: ManagedResource resource 'PerRun kind
    -> CleanupTarget 'ExplicitPerRun resource kind
  OperationalTarget
    :: ManagedResource resource 'Operational kind
    -> CleanupTarget 'OperationalTeardown resource kind
  ExplicitLongLivedTarget
    :: LongLivedDestroyPermit resource kind
    -> ManagedResource resource 'LongLived kind
    -> CleanupTarget 'ExplicitLongLived resource kind
  TotalDecommissionTarget
    :: ExternalDecommissionPermit resource kind
    -> ManagedResource resource life kind
    -> CleanupTarget 'TotalDecommission resource kind
  TotalDecommissionLocalTarget
    :: ExternalDecommissionLocalPermit
    -> RegisteredLocalSubstrate
    -> CleanupTarget 'TotalDecommission LocalRke2 'LocalSubstrate

data SomeCleanupTarget (surface :: CleanupSurface) where
  SomeCleanupTarget :: CleanupTarget surface resource kind -> SomeCleanupTarget surface

data LegacyAdoptionTarget surface stack where
  AdoptCascadeStack
    :: CleanupTarget 'Cascade stack 'Stack
    -> LegacyAdoptionTarget 'Cascade stack
  AdoptExplicitPerRunStack
    :: CleanupTarget 'ExplicitPerRun stack 'Stack
    -> LegacyAdoptionTarget 'ExplicitPerRun stack
```

A registry entry contains data and closed program tags only. It contains no `IO`, subprocess,
client, endpoint, credential, callback, or caller-supplied action. Constructors are private; smart
constructors reject duplicate keys, overlapping exact coordinates, unbounded families, lifecycle
class disagreement, and a family with no exact observation and destroy/read-back program.
`RegistryResourceKind` deliberately has no `LocalSubstrate` constructor: the host substrate has its
own registered type and can enter only `LocalOnlyTarget`, `CascadeLocalTarget`, or the externally
permitted `TotalDecommissionLocalTarget`.

The type index is valid here because lifecycle class and cleanup surface are program-owned facts.
It makes a long-lived state bucket impossible to pass to the cascade target constructor while
allowing only `PerRun` obligations and their exact `Operational` credentials to enter that graph.
`CascadeOperationalDependency` is projectable only from the complete selected graph's registered
consumer edges and is bound to the same resource key; dependency edges keep each operational
identity live until its final consumer is terminal. The
index keeps single-stack, aggregate-cascade, operational, local-only, explicit-long-lived, and
externally decommissioned authority distinct. `LongLivedDestroyPermit` is itself
registry/aggregate-specific:
for `aws-ses` it is projectable only from the backup-receipted `DestroyAwsSesPermit`, so an
individual provider or SMTP child cannot bypass the aggregate. `ExternalDecommissionPermit` is
minted only by the exported-receipt runner. These indices are not used to claim anything about AWS
or Kubernetes reality.

External observations stay flat, exhaustive ADTs. They carry the exact key and coordinate digest
whose fact was observed:

```haskell
-- Example: hypothetical exact observation model
data LifecycleProgramScope
  = ProvisioningScope
  | CleanupScope CleanupSurface

data ObservationEvidenceScope (scope :: LifecycleProgramScope)
  -- abstract; binds run, registry revision, substrate, account, region, and operation

data ObservationResult resource kind a
  = ObservedAbsent (AbsenceEvidence resource kind)
  | ObservedPresent a
  | ObservationPartial PartialEvidence (NonEmpty ObservationFailure)
  | ObservationUnobservable (NonEmpty ObservationFailure)

data ExactResourceObservation scope resource kind = ExactResourceObservation
  { observedResourceRef :: RegisteredResourceRef resource kind
  , observedCoordinateDigest :: ManagedResourceCoordinateDigest
  , observedAuthority :: ObservationAuthority
  , observedRevision :: ObservationRevision
  , observedEvidenceScope :: ObservationEvidenceScope scope
  , observedResult :: ObservationResult resource kind (ExactResourceInventory resource kind)
  }

data CheckpointObservation surface stack = CheckpointObservation
  { checkpointStackRef :: RegisteredResourceRef stack 'Stack
  , checkpointCopy :: CheckpointCopy
  , checkpointEvidenceScope :: ObservationEvidenceScope ('CleanupScope surface)
  , checkpointResult :: CheckpointResult stack
  }

data CheckpointPairObservation surface stack = CheckpointPairObservation
  { checkpointPairEvidenceScope :: ObservationEvidenceScope ('CleanupScope surface)
  , primaryCheckpointObservation :: CheckpointObservation surface stack
  , backupCheckpointObservation :: CheckpointObservation surface stack
  }

data OwnershipManifestObservation surface stack = OwnershipManifestObservation
  { ownershipManifestStackRef :: RegisteredResourceRef stack 'Stack
  , ownershipManifestEvidenceScope :: ObservationEvidenceScope ('CleanupScope surface)
  , ownershipManifestResult :: OwnershipManifestResult stack
  }

data EscapeSweepScope (surface :: CleanupSurface) -- abstract

data EscapeSweepReport (surface :: CleanupSurface)
  = EscapeSweepConfirmedClean (EscapeSweepScope surface) (Map Arn AwsResource)
  | EscapeSweepFoundEscapes
      (EscapeSweepScope surface)
      (Map Arn AwsResource)
      (NonEmpty AwsResource)
  | EscapeSweepUnobservable
      (EscapeSweepScope surface)
      (Map Arn AwsResource)
      (NonEmpty ObservationFailure)

data EscapeAuditClean (surface :: CleanupSurface)
  -- abstract outside the audit decision module
```

The report constructors are internal to the audit module. Its total decision exposes an
`EscapeAuditClean surface` witness only for `EscapeSweepConfirmedClean`; neither an escaped nor an
unobservable report can mint it. The surface index prevents a cascade audit—which admits an exact
intentionally retained set—from satisfying total decommission, whose audit admits no retained
carve-out. The witness binds the retained-set digest, query scope, registry revision, and cleanup-run
scope used by completion.

These are deliberately different nominal types. There is no conversion from
`CheckpointObservation` or `EscapeSweepReport` to `ExactResourceObservation`. A checkpoint
absence cannot prove resource absence. A clean global sweep cannot prove one registered stack
absent. An escape found by the sweep creates a diagnostic cleanup obligation; it does not invent a
stack owner. `AbsenceEvidence`, `ExactPresenceEvidence`, and complete-inventory constructors are
opaque outside the registered observer/decision modules; decoding a provider response does not let
a caller manufacture one without the key, coordinate, authority, revision, and scope checks.
`ObservationEvidenceScope` is also opaque: only the durable run descriptor can mint it, and the
exact observer must return the same indexed scope it received. Checkpoint-pair and ownership-
manifest wrappers retain that value rather than relying on an ambient caller or a later string
comparison.

A private `CompleteObservationSet` constructor admits a decision only when all of the following are
true:

1. every selected registry key appears exactly once;
2. every observation carries that key's exact coordinate digest and required authority;
3. no unregistered or wrong-lifecycle key appears;
4. every bounded family reports complete membership or an explicit partial/unobservable result; and
5. the durable run descriptor supplies the substrate, account, region, operation, and ownership
   scope. None is inferred from residue.

AWS discovery normalizes provider responses before cardinality or ownership decisions:

```haskell
-- Example: hypothetical AWS inventory normalization
newtype AwsInventory = AwsInventory (Map Arn AwsResource)

normalizeTagRows
  :: [AwsTagRow]
  -> Either AwsInventoryFailure AwsInventory
```

One ARN is one resource regardless of tag count, query overlap, pagination, or response order.
Conflicting facts for one ARN are a typed failure. Tags remain evidence attached to the normalized
resource; a tag row is never itself counted as a resource.

#### The run-invariant identity of a created resource

A resource's durable identity must not contain a fact about the run that created it. If it does, the
run that later cleans the resource up has no key with which to address it, and selection degrades
into matching whatever residue happens to be visible — the exact composition the 2026-08-15
counterexample exercised.

The identity is therefore split in two:

```haskell
-- Example: hypothetical run-invariant generation identity
data StackGenerationKey -- abstract
  -- registered key, compiled coordinate digest, registry revision,
  -- local foundation, AWS account/region, create/destroy cycle ordinal

data RegisteredStackGeneration = RegisteredStackGeneration
  { generationKey :: StackGenerationKey
  , generationAdmittedOperation :: OperationId
  , generationProviderSession :: ProviderCredentialSession
  , generationCreatingRunScope :: DurableObservationRunScope
  , generationCreatingSurface :: CleanupSurface
  }
```

The key is run-invariant and is the only thing selection consults. Provenance — the admitted create
operation, the exact Provider credential session, and the creating run scope and surface — is
recorded and never consulted during selection. A cycle ordinal distinguishes successive
create/destroy cycles of one registered resource, and the reserved zero ordinal keeps "never
created" and "created once" from sharing a key.

Three components of the key are deliberately not parameters of its constructor: the account and
region come only from an opaque Provider AWS-scope proof, and the coordinate digest and registry
revision come only from the compiled registry. A caller therefore cannot assert an account, a
region, a coordinate the registry does not own, or a revision this binary was not built with — each
of which would mint a key no later run could reproduce.

Because the key is run-invariant, so is its durable address: the canonical NUL-framed key rendering
hashes to one retained slot. The creating run and a later cleanup run compute the same slot without
either knowing the other's scope, and that prefix is distinct from every per-run record's prefix so a
generation-keyed record cannot be mistaken for a run-keyed one. Decoding a retained record
re-derives the coordinate digest and registry revision from the compiled registry and refuses a
stored disagreement, so a record cannot smuggle in a coordinate this binary does not own.

Cleanup selection binds to that record's read-back and to nothing else. The cleanup run derives its
addressing key from the compiled registry and its own exact Provider credential session, reads the
record that key addresses, requires the stored key to equal the addressing key, and only then applies
surface eligibility — so knowing a generation key still cannot widen a surface. An empty slot
refuses; it never authorizes inferring a generation from residue. An unobservable store stays
distinct from an absent record. A record found under a key that is not its own is a slot-collision
refusal, never a successful selection of whatever was there.

The commit obeys the same evidence rule as every other durable write: a lost compare-and-swap
response is neither success nor failure, so the outcome is settled by an independent read-back of the
slot. The exact record repairs the lost response to a commit; an absent slot reports that nothing was
committed and names the lost response; a different record is a conflict.

Which cycle a create owns is a separate durable question, because a generation slot is addressed *by*
its ordinal and so cannot be enumerated without an unbounded probe. The key minus its ordinal is the
resource's *series*, and one retained cursor per series names the current cycle. The cursor's slot
prefix is distinct from every cycle's slot, so the pointer can never be mistaken for a record.
Reserving a cycle is idempotent in the admitted create operation: a retried create whose operation
already advanced the cursor is handed back the same cycle, so a lost response cannot burn a second
ordinal and strand the record the first attempt may already have written. Opening a series requires
no cursor and advancing one requires exactly the version it read; a settled cycle held by another
admitted create refuses rather than proceeding on a cycle this run does not own.

Both directions of that identity are Authority-owned, and neither may fall back. The **producer** is
the admitted-create path: it observes the create operation from the Authority's own admission
aggregate, reads the Provider AWS-scope receipt back from that same aggregate, reserves the cycle,
commits the generation, and only then commits the run-scoped creation binding. That order is chosen
for what a mid-flight failure leaves behind — the addressable record present and the run-scoped one
absent is recoverable, while the reverse leaves a stack whose cycle no later run can name. The
account and region reach the derivation only through an opaque proven-session type whose sole
introductions are the two Provider proofs, so a create request can name the observation operation but
can never state its content; a create whose scope no retained receipt proves is refused rather than
falling back to the scope the request asserted.

The **consumer** is the cleanup path. Because a generation slot is addressed by its ordinal, a run
that knows only the registered key reaches the record through exactly two authoritative reads: the
series cursor, then the generation the cursor's ordinal addresses. An unopened series refuses rather
than inferring a cycle from visible residue, an unobservable store stays distinct from an absent one,
the stored key must equal the key that addressed it, and surface eligibility is re-applied after the
read-back.

Five invariants define the registry boundary:

1. **Coverage.** Every direct creator and every Kubernetes/controller owner maps to one singleton or
   bounded-family entry before mutation.
2. **Soundness.** Partial and unobservable results never become absence or permission to mutate.
3. **Scope.** An observation is consumable only for its exact resource key, coordinate digest,
   authority, account, region, substrate, and operation scope.
4. **Cardinality.** Provider rows are normalized to domain identity before counting or joining.
5. **Completion.** Success is constructible only from complete exact absence evidence, never from
   exit codes, narration, checkpoint state, or a global audit verdict.

The compiled Haskell region makes illegal decisions and transitions unrepresentable. The external
world is still authoritative and fallible, so its states remain explicit data. Constructor privacy,
the sole decoder/encoder, and the interpreter allowlist define the boundary of that claim; repository
lint is a cross-seam parity guard, not the source of the guarantee.

#### Desired-present reconciliation for long-lived resources

`LifecycleClass` decides cleanup, not preparation. When a selected capability requires a
`LongLived` resource, preparation projects its exact registry entry into a desired-present target;
ordinary postflight still cannot project that entry into a cascade cleanup target.

```haskell
-- Example: hypothetical desired-present program
data EnsureableResource resource life kind where
  EnsureableResource
    :: ManagedResource resource life kind
    -> EnsureProgramTag resource
    -> EnsureableResource resource life kind

data EnsurePresentTarget where
  EnsureLongLived
    :: EnsureableResource resource 'LongLived kind
    -> DesiredResourceSpec resource
    -> EnsurePresentTarget

data EnsurePresentDecision resource kind
  = PresentAlreadyMatches (ExactPresenceEvidence resource kind)
  | ReconcilePresent (EnsureProgramTag resource) (DesiredResourceSpec resource)
  | RefusePresent PresenceRefusal
```

`EnsureableResource`, `EnsureProgramTag`, and `DesiredResourceSpec` have private constructors. The
registry projection supplies the only ensure tag accepted for that resource, and the desired-spec
smart constructor binds the same registered key, coordinate digest, lifecycle class, and schema
revision. A caller cannot pair one resource's ensure program or desired payload with another key.

The total decision consumes the resource's exact authoritative observation and desired-spec digest:

- exact present + matching spec is already satisfied;
- exact absent selects the registered ensure program and mandatory read-back;
- present + conflicting ownership/spec refuses rather than adopting;
- partial or unobservable refuses without mutation; and
- checkpoint presence, a clean escape audit, or another resource's status supplies none of these
  arms.

Before an ensure effect, the durable operation records the exact long-lived coordinate, desired
digest, program tag, credential lifetime, and read-back obligation. Applied-without-response resumes
by observing the same coordinate. Completion requires positive matching read-back. Suite failure
does not convert the resource to `PerRun`; ordinary cleanup retains it by construction. Explicit
long-lived teardown and `nuke` use their own cleanup-surface constructors.

The generic rule is specialized for retained SES preparation in
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

### 3.2 Checkpoint recovery and the desired-absence decision

Primary and independent-backup checkpoint observations are retained separately from exact resource
inventory. The pure planner is total over both dimensions:

```haskell
-- Example: hypothetical stack desired-absence decision
data CheckpointRetirementAuthorization surface stack -- abstract

data StackDestroyDecision surface stack
  = StackAlreadyAbsent
      (AbsenceEvidence stack 'Stack)
      (CheckpointRetirementAuthorization surface stack)
  | DestroyFromCheckpoint (CompleteStackInventory stack) (VerifiedCheckpointRef stack)
  | RestorePrimaryThenDestroy (CompleteStackInventory stack) (VerifiedBackupCheckpoint stack)
  | DestroyFromOwnershipManifest
      (CompleteStackInventory stack)
      (CompleteOwnershipManifest surface stack)
  | RefuseStackDestroy StackDestroyRefusal

planStackAbsent
  :: CleanupTarget surface stack 'Stack
  -> ExactResourceObservation ('CleanupScope surface) stack 'Stack
  -> CheckpointPairObservation surface stack
  -> OwnershipManifestObservation surface stack
  -> Either EvidenceBindingFailure (StackDestroyDecision surface stack)
```

The decision table is:

| Exact provider observation | Checkpoint evidence | Decision |
|---|---|---|
| Absent | any checkpoint state | Close the resource obligation from exact absence; retire or quarantine stale checkpoint material only after the absence receipt is durable |
| Present, complete | verified primary | Submit or resume the fenced provider destroy |
| Present, complete | primary unusable; verified independent backup | Restore and read back the primary, then submit or resume the fenced provider destroy |
| Present, complete | both copies unusable; complete write-ahead or confirmed-legacy ownership manifest | Run the closed native desired-absence program for exactly the registered coordinates |
| Present, complete | no usable checkpoint and incomplete manifest | Refuse; preserve required credentials and report the recovery-plane disposition |
| Partial or unobservable | any checkpoint state | Refuse mutation and absence; preserve required credentials and report the recovery-plane disposition |

A `CompleteOwnershipManifest` normally exists because the cleanup obligation was receipt-committed
before the first external mutation. It includes deterministic coordinates known up front, bounded
dynamic families, and exact account/region/run/operation ownership. Dynamic identifiers are
appended and read back before their owner may create another child. Native manifest cleanup is a
registered reconciler, not an ad-hoc AWS fallback.

Manifest purpose is preserved at the type boundary:

```haskell
-- Example: hypothetical cleanup-manifest binding
bindOwnershipManifestForCleanup
  :: CleanupTarget surface stack 'Stack
  -> VerifiedOwnershipManifest purpose stack
  -> Either OwnershipManifestBindingFailure
       (CompleteOwnershipManifest surface stack)
```

A `WriteAheadOwnership` manifest can bind only to the exact registered stack and cleanup scope it
was created to protect. A `LegacyAdoptionOwnership legacySurface` manifest additionally requires
`legacySurface ~ surface` and the same confirmed plan/permit digest. Cleanup can read either
provenance and bind it for desired absence, but `SubmitRegisteredCreate` and
`AppendObservedOwnership` accept only `WriteAheadOwnership`. A cleanup-only legacy receipt therefore
has no type-level path into a future create or write-ahead append. The append constructor also
requires `RegisteredOwnershipEdge stack resource kind`, projected only from the registry dependency
graph, so an observed resource cannot be attached to an unrelated stack's manifest.

Pre-cutover resources created before write-ahead manifests existed use one separately typed legacy
adoption protocol. A provider-native, read-only observer enumerates a closed registry-derived family
set from exact deterministic coordinates and account/region/cluster/run evidence; a broad tag or
name-prefix result cannot enter this set. The planner renders every candidate, ownership proof,
ambiguity, and proposed desired-absence program. Only an explicit admin permit over that exact plan
digest may receipt-commit a `ConfirmedLegacyAdoptionManifest`, and an independent read-back must
verify it before any cleanup mutation. That opaque receipt is one permitted provenance for
`CompleteOwnershipManifest`; it is not forgeable from discovery alone. Missing, extra, ambiguous,
partial, or unobservable candidates refuse adoption and leave cleanup incomplete. This bounded
escape hatch recovers known pre-manifest `aws-eks`, `aws-eks-subzone`, and `aws-test` families; it
does not claim that arbitrary unregistered resources can always be recovered. Observation remains
inside the read-only Provider Worker capability and authorization uses the permit-bounded Admin
Action Runner; neither exposes host AWS credentials or creates a generic provider fallback.

Checkpoint promotion is crash-safe before provider work is acknowledged: immutable encrypted bytes
and their aggregate reference are read back from primary and independent backup under the same
operation. Lost responses resume by operation ID. Pulumi exit zero is not completion; the exact
resource observer must subsequently produce absence evidence.

A `CheckpointRetirementAuthorization` has a private constructor that binds the exact stack absence
evidence, checkpoint-copy inventory, retirement/quarantine policy, and cleanup scope; a raw policy
value cannot mint it. A corrupt-checkpoint prune may therefore run only after exact provider absence has already closed
the resource obligation, or as the retirement tail of a completed desired-absence decision. It may
never erase the last usable destruction mechanism merely because checkpoint decoding failed.
Long-lived checkpoint retirement remains an explicit long-lived operation, never a cascade target.

### 3.3 Result-indexed programs and the durable cleanup graph

Plans contain closed programs, not actions captured from callers. The scope index prevents a
cleanup interpreter from minting a future write-ahead manifest, prevents a provisioning program
from acquiring destructive authority, and preserves the exact cleanup surface through every
destructive program:

```haskell
-- Example: hypothetical result-indexed lifecycle program
data OwnershipManifestPurpose
  = WriteAheadOwnership
  | LegacyAdoptionOwnership CleanupSurface

data RecoveryPlaneAuthority surface where
  CascadeRecoveryPlane
    :: RecoveryPlaneAuthority 'Cascade
  ExplicitPerRunRecoveryPlane
    :: RecoveryPlaneAuthority 'ExplicitPerRun
  OperationalRecoveryPlane
    :: RecoveryPlaneAuthority 'OperationalTeardown
  ExplicitLongLivedRecoveryPlane
    :: RecoveryPlaneAuthority 'ExplicitLongLived

data SurfaceReportAuthority surface where
  ExplicitPerRunReport
    :: SurfaceReportAuthority 'ExplicitPerRun
  OperationalTeardownReport
    :: SurfaceReportAuthority 'OperationalTeardown
  ExplicitLongLivedReport
    :: SurfaceReportAuthority 'ExplicitLongLived

data CompleteCascadeExactConvergence -- abstract

data EscapeAuditAuthority surface where
  CascadeEscapeAudit
    :: CompleteCascadeExactConvergence
    -> EscapeAuditAuthority 'Cascade
  TotalDecommissionEscapeAudit
    :: TotalDecommissionAuditPermit
    -> EscapeAuditAuthority 'TotalDecommission

data LifecycleProgram (scope :: LifecycleProgramScope) result where
  CommitInitialOwnershipManifest
    :: StackCreateIntent stack
    -> LifecycleProgram
         'ProvisioningScope
         (OwnershipManifestWrite 'WriteAheadOwnership stack)
  AppendObservedOwnership
    :: VerifiedOwnershipManifest 'WriteAheadOwnership stack
    -> RegisteredOwnershipEdge stack resource kind
    -> ExactPresenceEvidence resource kind
    -> LifecycleProgram
         'ProvisioningScope
         (OwnershipManifestWrite 'WriteAheadOwnership stack)
  ReadBackOwnershipManifest
    :: OwnershipManifestWrite purpose stack
    -> LifecycleProgram scope (VerifiedOwnershipManifest purpose stack)
  SubmitRegisteredCreate
    :: RegisteredCreatePlan stack resource kind
    -> VerifiedOwnershipManifest 'WriteAheadOwnership stack
    -> LifecycleProgram 'ProvisioningScope (CreateAttempt resource kind)
  ObserveLegacyAdoptionCandidates
    :: ObservationEvidenceScope ('CleanupScope surface)
    -> LegacyAdoptionTarget surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (LegacyAdoptionObservation surface stack)
  AuthorizeLegacyAdoption
    :: DigestBoundLegacyAdoptionRequest surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (ConfirmedLegacyAdoptionPlan surface stack)
  CommitLegacyAdoptionManifest
    :: ConfirmedLegacyAdoptionPlan surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (OwnershipManifestWrite ('LegacyAdoptionOwnership surface) stack)
  EnsureRecoveryPlane
    :: RecoveryPlaneAuthority surface
    -> RecoveryProfile surface
    -> LifecycleProgram
         ('CleanupScope surface)
         (RecoveryPlaneDisposition surface)
  ObserveExactResource
    :: ObservationEvidenceScope scope
    -> RegisteredResourceRef resource kind
    -> LifecycleProgram scope (ExactResourceObservation scope resource kind)
  ObserveCheckpointPair
    :: ObservationEvidenceScope ('CleanupScope surface)
    -> CleanupTarget surface stack 'Stack
    -> LifecycleProgram ('CleanupScope surface) (CheckpointPairObservation surface stack)
  ObserveOwnershipManifest
    :: ObservationEvidenceScope ('CleanupScope surface)
    -> CleanupTarget surface stack 'Stack
    -> LifecycleProgram ('CleanupScope surface) (OwnershipManifestObservation surface stack)
  RestoreCheckpoint
    :: CleanupTarget surface stack 'Stack
    -> CheckpointRestoreOperationRef surface stack
    -> VerifiedBackupCheckpoint stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (CheckpointRestoreOutcome stack)
  ReadBackRestoredCheckpoint
    :: CleanupTarget surface stack 'Stack
    -> CheckpointRestoreOperationRef surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (CheckpointObservation surface stack)
  IssueEksDrainSession
    :: CleanupTarget surface EksCluster 'Stack
    -> ExactPresenceEvidence EksCluster 'Stack
    -> LifecycleProgram ('CleanupScope surface) (EksDrainSession surface)
  DrainEksOwners
    :: EksDrainSession surface
    -> LifecycleProgram ('CleanupScope surface) DrainOutcome
  DestroyWithCheckpoint
    :: CleanupTarget surface stack 'Stack
    -> DesiredAbsenceOperationRef surface stack 'Stack
    -> CompleteStackInventory stack
    -> VerifiedCheckpointRef stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (DesiredAbsenceOutcome stack 'Stack)
  DestroyWithManifest
    :: CleanupTarget surface stack 'Stack
    -> DesiredAbsenceOperationRef surface stack 'Stack
    -> CompleteStackInventory stack
    -> CompleteOwnershipManifest surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (DesiredAbsenceOutcome stack 'Stack)
  DestroyRegisteredResource
    :: DirectCleanupKind kind
    -> CleanupTarget surface resource kind
    -> DesiredAbsenceOperationRef surface resource kind
    -> RegisteredDesiredAbsence resource kind
    -> LifecycleProgram
         ('CleanupScope surface)
         (DesiredAbsenceOutcome resource kind)
  ReadBackExactResource
    :: CleanupTarget surface resource kind
    -> DesiredAbsenceOperationRef surface resource kind
    -> LifecycleProgram
         ('CleanupScope surface)
         (ExactResourceObservation ('CleanupScope surface) resource kind)
  RetireOrQuarantineCheckpoint
    :: CleanupTarget surface stack 'Stack
    -> CheckpointRetirementOperationRef surface stack
    -> CheckpointRetirementAuthorization surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (CheckpointRetirementOutcome stack)
  ReadBackCheckpointRetirement
    :: CleanupTarget surface stack 'Stack
    -> CheckpointRetirementOperationRef surface stack
    -> LifecycleProgram
         ('CleanupScope surface)
         (CheckpointRetirementObservation stack)
  AuditEscapes
    :: EscapeAuditAuthority surface
    -> EscapeSweepScope surface
    -> LifecycleProgram
         ('CleanupScope surface)
         (EscapeSweepReport surface)
  CommitConvergenceReport
    :: ConvergenceReportOperationRef
    -> PreUninstallConvergenceEvidence
    -> LifecycleProgram
         ('CleanupScope 'Cascade)
         ConvergenceReportOutcome
  ReadBackConvergenceReport
    :: ConvergenceReportOperationRef
    -> LifecycleProgram
         ('CleanupScope 'Cascade)
         ConvergenceReportObservation
  CommitSurfaceCompletion
    :: SurfaceReportAuthority surface
    -> SurfaceCompletionOperationRef surface
    -> SurfacePreCompletionEvidence surface
    -> LifecycleProgram
         ('CleanupScope surface)
         (SurfaceCompletionOutcome surface)
  ReadBackSurfaceCompletion
    :: SurfaceReportAuthority surface
    -> SurfaceCompletionOperationRef surface
    -> LifecycleProgram
         ('CleanupScope surface)
         (SurfaceCompletionObservation surface)
  RunLocalUninstall
    :: LocalUninstallAuthority surface
    -> LocalUninstallOperationRef surface
    -> LifecycleProgram ('CleanupScope surface) (LocalUninstallOutcome surface)
  ObserveLocalSubstrate
    :: LocalUninstallAuthority surface
    -> LocalUninstallOperationRef surface
    -> LifecycleProgram
         ('CleanupScope surface)
         (LocalSubstrateObservation surface)
  ApplyDecommissionLocalDataDisposition
    :: CleanupTarget 'TotalDecommission LocalRke2 'LocalSubstrate
    -> LocalUninstallEvidence 'TotalDecommission
    -> DecommissionLocalDataOperationRef
    -> LocalDataDispositionPlan
    -> LifecycleProgram
         ('CleanupScope 'TotalDecommission)
         LocalDataDispositionOutcome
  ReadBackDecommissionLocalDataDisposition
    :: CleanupTarget 'TotalDecommission LocalRke2 'LocalSubstrate
    -> DecommissionLocalDataOperationRef
    -> LifecycleProgram
         ('CleanupScope 'TotalDecommission)
         LocalDataDispositionObservation
  AppendLocalCompletion
    :: LocalCompletionOperationRef
    -> LifecycleProgram ('CleanupScope 'Cascade) LocalCompletionOutcome
  ReadBackLocalCompletion
    :: LocalCompletionOperationRef
    -> LifecycleProgram ('CleanupScope 'Cascade) LocalCompletionObservation
  AppendDecommissionTerminalReceipt
    :: DecommissionTerminalOperationRef
    -> DecommissionTerminalFrameReady
    -> LifecycleProgram
         ('CleanupScope 'TotalDecommission)
         DecommissionTerminalReceiptOutcome
  ReadBackDecommissionTerminalReceipt
    :: DecommissionTerminalOperationRef
    -> LifecycleProgram
         ('CleanupScope 'TotalDecommission)
         DecommissionTerminalReceiptObservation

type ProvisionProgram = LifecycleProgram 'ProvisioningScope
type TeardownProgram surface = LifecycleProgram ('CleanupScope surface)
```

The interpreter is the only effectful boundary and is total over the constructor set. It cannot run
`SubmitRegisteredCreate` without a read-back manifest, `DestroyWithCheckpoint` without a verified
checkpoint, `DestroyWithManifest` without a complete manifest, or `DrainEksOwners` without a
provider-issued, expiring EKS session built from positive cluster evidence. `DirectCleanupKind`
has no `Stack` or `LocalSubstrate` constructor, so `DestroyRegisteredResource` cannot bypass the
checkpoint/manifest stack decision or either local-uninstall contract. The surface-indexed
`CleanupTarget` follows every destroy and read-back; a cascade target cannot enter explicit
long-lived, operational, local-only, explicit-per-run, or total-decommission programs.

Legacy authorization is one opaque value, not two independently composable arguments:

```haskell
-- Example: hypothetical digest-bound legacy authorization
bindLegacyAdoptionPermit
  :: LegacyAdoptionTarget surface stack
  -> CompleteLegacyAdoptionPlan stack
  -> LegacyAdoptionPermit
  -> Either LegacyAdoptionBindingFailure
       (DigestBoundLegacyAdoptionRequest surface stack)
```

The smart constructor checks the rendered-plan digest, exact target, candidate-set digest, admin
permit ID, cleanup scope, and expiry together. Neither a plan nor a permit has a public constructor;
a permit for another plan in the same run cannot inhabit the bound request. Only a confirmed
request can be receipt-committed and independently read back as an ownership manifest.

Checkpoint restoration follows the same effect/read-back split:

```haskell
-- Example: hypothetical restored-checkpoint read-back decision
confirmRestoredCheckpoint
  :: CheckpointRestoreOperationRef surface stack
  -> CheckpointObservation surface stack
  -> Either CheckpointRestoreFailure (VerifiedCheckpointRef stack)
```

The restore interpreter returns only `CheckpointRestoreOutcome`; it cannot mint the verified
primary reference consumed by provider destroy. `ReadBackRestoredCheckpoint` reopens the exact
primary coordinate through the stable precommitted operation reference, and only the pure binding
decision above can produce that reference after key, digest, copy, and cleanup-scope agreement.

Every `*OperationRef` above is an opaque, scope-bound node reference allocated and receipt-committed
in the durable graph *before* the first external call. It is not an effect response. The executor
durably marks the node attempted before invoking its interpreter, so the same reference is
rehydratable after process loss and can drive mandatory read-back even when no effect result was
returned. `DesiredAbsenceOutcome`, `CheckpointRestoreOutcome`, `CheckpointRetirementOutcome`,
`ConvergenceReportOutcome`, `SurfaceCompletionOutcome`, `LocalUninstallOutcome`,
`LocalDataDispositionOutcome`, `LocalCompletionOutcome`, and
`DecommissionTerminalReceiptOutcome` are diagnostic effect results only; none can mint completion
evidence.
Their read-back nodes are `RequiresAttempt` successors over the stable reference, not consumers of
the prior call's return value.

`RecoveryPlaneAuthority` enumerates exactly the ordinary surfaces that may establish or resume the
retained teardown authority. It has no local-only or total-decommission constructor. The explicit
per-run, operational, and explicit-long-lived surfaces therefore observe the same honest
`RecoveryPlaneDisposition` their incomplete results carry instead of borrowing a cascade value.

`SurfaceReportAuthority` likewise has exactly the three non-cascade ordinary cleanup surfaces whose
completion contracts require a report receipt. The stable `SurfaceCompletionOperationRef` is
committed before append; `ReadBackSurfaceCompletion` is a `RequiresAttempt` successor, and the pure
`confirmSurfaceCompletionReceipt` decision mints `SurfaceCompletionReceipt surface` only from a
matching positive observation. Local-only has no report contract, cascade uses its independently
backed-up pre-uninstall report, and total decommission uses the external receipt.

```haskell
-- Example: hypothetical surface-report read-back decision
confirmSurfaceCompletionReceipt
  :: SurfaceReportAuthority surface
  -> SurfaceCompletionOperationRef surface
  -> SurfaceCompletionObservation surface
  -> Either SurfaceCompletionFailure (SurfaceCompletionReceipt surface)
```

The cascade report and total-decommission tails have the same split:

```haskell
-- Example: hypothetical terminal read-back decisions
confirmPreUninstallCommit
  :: ConvergenceReportOperationRef
  -> ConvergenceReportObservation
  -> Either ConvergenceReportFailure PreUninstallCommit

confirmLocalDataDisposition
  :: DecommissionLocalDataOperationRef
  -> LocalDataDispositionObservation
  -> Either DecommissionEvidenceFailure LocalDataDisposition

confirmExternalDecommissionTerminalReceipt
  :: DecommissionTerminalOperationRef
  -> DecommissionTerminalReceiptObservation
  -> Either DecommissionEvidenceFailure ExternalDecommissionTerminalReceipt
```

Each operation reference is committed before its effect. A convergence-report, local-data, or
terminal-frame response can be lost without losing the read-back obligation; only these pure
confirmers mint the evidence consumed by readiness or total completion.

`EscapeAuditAuthority` closes the audit-surface set. Cascade obtains only
`CascadeEscapeAudit`, which cannot be constructed until `CompleteCascadeExactConvergence` binds
exact per-run, dynamic-family, and required operational-credential read-back under one run scope;
its audit scope carries the exact intended-retained registry projection.
`TotalDecommissionEscapeAudit` requires an opaque `TotalDecommissionAuditPermit` minted by the
external receipt fold only after every registered target—including local substrate, retained
prefixes, credentials, checkpoint material, and the final shared bucket—has exact terminal
disposition. Its scope permits no retained carve-out. Local-only, explicit-stack, operational, and
explicit-long-lived programs have no audit-authority constructor, so they cannot accidentally claim
the aggregate terminal audit.

`TeardownProgram 'TotalDecommission` is the lifecycle compiler's surface-indexed plan, not a second
runner vocabulary. Before Authority stops, an exhaustive pure compiler projects each semantic
operation into one signed `DecommissionProgramTag` defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). The Authority's
durable graph represents an effect and its mandatory read-back as distinct nodes; export fuses that
pair and its stable operation reference into the runner's one resumable program for the semantic
tag. The runner program owns effect plus read-back inside its operation boundary and returns the
final observation, so lifecycle graph-node cardinality is deliberately not runner-tag cardinality.
Registered resource destroys select their TLS, Authority-backup, provider, or other tag through the
closed registry program tag, while the explicit local-data and terminal-frame programs select their
corresponding tags directly. Registry/compiler parity rejects a total-decommission source operation
with no exported tag and a runner tag with no source operation, manifest dependency relation,
interpreter, and receipt codec. The standalone runner interprets only that signed projection.

`LocalUninstallAuthority` is a private GADT with two ordinary surfaces and the separately permitted
external-decommission surface:

```haskell
-- Example: hypothetical local-uninstall authority
data ReadyForDecommissionLocalUninstall -- abstract

data LocalUninstallAuthority surface where
  LocalOnlyUninstall
    :: CleanupTarget 'LocalOnly LocalRke2 'LocalSubstrate
    -> LocalUninstallAuthority 'LocalOnly
  CascadeUninstall
    :: ReadyToUninstallEvidence
    -> CleanupTarget 'Cascade LocalRke2 'LocalSubstrate
    -> LocalUninstallAuthority 'Cascade
  TotalDecommissionUninstall
    :: ReadyForDecommissionLocalUninstall
    -> CleanupTarget 'TotalDecommission LocalRke2 'LocalSubstrate
    -> LocalUninstallAuthority 'TotalDecommission

authorizeCascadeUninstall
  :: ReadyToUninstallEvidence
  -> CleanupTarget 'Cascade LocalRke2 'LocalSubstrate
  -> Either EvidenceScopeFailure (LocalUninstallAuthority 'Cascade)

authorizeTotalDecommissionUninstall
  :: ReadyForDecommissionLocalUninstall
  -> CleanupTarget 'TotalDecommission LocalRke2 'LocalSubstrate
  -> Either EvidenceScopeFailure
       (LocalUninstallAuthority 'TotalDecommission)

confirmLocalSubstrateAbsent
  :: LocalUninstallAuthority surface
  -> LocalUninstallOperationRef surface
  -> LocalSubstrateObservation surface
  -> Either LocalAbsenceFailure (LocalUninstallEvidence surface)

prepareLocalCompletion
  :: ReadyToUninstallEvidence
  -> LocalUninstallEvidence 'Cascade
  -> Either EvidenceScopeFailure LocalCompletionOperationRef
```

Thus local-only delete is representable without AWS/recovery evidence but cannot claim cascade
completion, cascade uninstall is unrepresentable without readiness, and total decommission needs
both the external permit sealed into its target and `ReadyForDecommissionLocalUninstall`. That
opaque witness is minted only after the external receipt proves every node that needs a live home
Agent, Vault, Gateway, cert-manager, or control-plane service terminal; final external backup-store
deletion and the no-retention total audit remain later nodes. The GADT constructors are private;
`authorizeCascadeUninstall` and `authorizeTotalDecommissionUninstall` are the sole non-local minters
and reject readiness/target scope mismatches. The pure
`confirmLocalSubstrateAbsent` decision is the only minter of
`LocalUninstallEvidence surface`; it accepts the matching authority/reference and exact absent
`LocalSubstrateObservation surface`, never an uninstall exit code. The same observer is legal
before the effect (to close an already-absent local-only target) and as the `RequiresAttempt`
successor after an uninstall; only the latter edge is required when the first observation is
present. The pure
`prepareLocalCompletion` constructor accepts only `ReadyToUninstallEvidence` plus matching
`LocalUninstallEvidence 'Cascade` and seals their one-shot permit and observed-host digest into
`LocalCompletionOperationRef`. Only exact read-back of that reference can mint the final receipt.
Checkpoint retirement follows the same pattern: its authorization is constructible only from exact
stack absence, and retirement/quarantine has its own effect outcome and mandatory read-back.
Ordinary errors are returned as structured values; `error`, discarded `Left`, wildcarded subprocess
failure, and callback-bearing registry entries are outside the supported path.

The program constructors are exported only to the pure lifecycle compiler. Every registered create
plan, manifest write/read-back, digest-bound legacy-adoption request, recovery profile, operation
reference, checkpoint reference, EKS session, and evidence value carries one opaque
`CleanupEvidenceScope`; smart constructors reject a mismatched run ID, registry revision,
coordinate digest, rendered-plan digest, account, region, substrate, or operation. Thus a valid
witness from a different run or plan cannot authorize this run's effect even when both values refer
to the same stack phantom type.

Restore and teardown are one durable graph. Nodes and
`RequiresSuccess`/`RequiresAttempt` edges derive from registry ownership, dependency,
credential-lifetime, and storage-lifetime facts. They are never authored as a positional list at a
CLI call site. Every ready independent node runs after sibling failure; blocked nodes retain the
exact failed dependency. A cleanup run is receipt-committed before mutation, fenced while owned,
resumable under the same node operation IDs after process or control-plane loss, and closed only
after its final report is backed up and read back.

The lifecycle core owns this graph and its result:

```haskell
-- Example: hypothetical cleanup-run terminal model
data RecoveryPlaneDisposition (surface :: CleanupSurface)
  = RecoveryPlaneEstablished (RecoveryPlaneReady surface)
  | RecoveryPlaneNotEstablished (NonEmpty RecoveryFailure)
  | RecoveryPlaneLost (NonEmpty RecoveryFailure)

data PerRunStackConvergenceEvidence -- abstract
data OperationalConvergenceEvidence -- abstract
data LongLivedAggregateConvergenceEvidence -- abstract
data TotalDecommissionNonLocalAbsence -- abstract
data SurfaceCompletionReceipt (surface :: CleanupSurface) -- abstract
data IncompleteCleanupEvidence (surface :: CleanupSurface) -- abstract
data LocalDeleteIncompleteEvidence -- abstract
data DecommissionIncompleteEvidence -- abstract

data CascadeResult
  = CascadeComplete CascadeCompleteEvidence
  | CascadeIncomplete (IncompleteCleanupEvidence 'Cascade)

data LocalOnlyDeleteResult
  = LocalOnlyDeleteComplete LocalOnlyDeleteEvidence
  | LocalOnlyDeleteIncomplete LocalDeleteIncompleteEvidence

data ExplicitPerRunResult
  = ExplicitPerRunComplete ExplicitPerRunCompleteEvidence
  | ExplicitPerRunIncomplete (IncompleteCleanupEvidence 'ExplicitPerRun)

data OperationalTeardownResult
  = OperationalTeardownComplete OperationalTeardownCompleteEvidence
  | OperationalTeardownIncomplete
      (IncompleteCleanupEvidence 'OperationalTeardown)

data ExplicitLongLivedResult
  = ExplicitLongLivedComplete ExplicitLongLivedCompleteEvidence
  | ExplicitLongLivedIncomplete
      (IncompleteCleanupEvidence 'ExplicitLongLived)

data TotalDecommissionResult
  = TotalDecommissionComplete TotalDecommissionCompleteEvidence
  | TotalDecommissionIncomplete DecommissionIncompleteEvidence

data TerminalAuditEvidence -- abstract

terminalAuditFromAws
  :: CleanupEvidenceScope
  -> EscapeAuditClean 'Cascade
  -> Either EvidenceScopeFailure TerminalAuditEvidence

terminalAuditWithoutAws
  :: CleanupEvidenceScope
  -> CompleteNoAwsTargetProjection
  -> Either EvidenceScopeFailure TerminalAuditEvidence

readyToUninstall
  :: CleanupEvidenceScope
  -> RecoveryPlaneReady 'Cascade
  -> CompletePerRunAbsence
  -> CompleteDynamicFamilyAbsence
  -> CompleteCredentialDisposition
  -> TerminalAuditEvidence
  -> PreUninstallCommit
  -> Either EvidenceScopeFailure ReadyToUninstallEvidence

completeLocalOnlyDelete
  :: LocalUninstallEvidence 'LocalOnly
  -> LocalOnlyDeleteEvidence

completeCascade
  :: ReadyToUninstallEvidence
  -> LocalUninstallEvidence 'Cascade
  -> LocalCompletionReceipt
  -> Either EvidenceScopeFailure CascadeCompleteEvidence

completeExplicitPerRun
  :: PerRunStackConvergenceEvidence
  -> SurfaceCompletionReceipt 'ExplicitPerRun
  -> Either EvidenceScopeFailure ExplicitPerRunCompleteEvidence

completeOperationalTeardown
  :: OperationalConvergenceEvidence
  -> SurfaceCompletionReceipt 'OperationalTeardown
  -> Either EvidenceScopeFailure OperationalTeardownCompleteEvidence

completeExplicitLongLived
  :: LongLivedAggregateConvergenceEvidence
  -> SurfaceCompletionReceipt 'ExplicitLongLived
  -> Either EvidenceScopeFailure ExplicitLongLivedCompleteEvidence

completeTotalDecommission
  :: TotalDecommissionNonLocalAbsence
  -> LocalUninstallEvidence 'TotalDecommission
  -> EscapeAuditClean 'TotalDecommission
  -> ExternalDecommissionTerminalReceipt
  -> LocalDataDisposition
  -> Either DecommissionEvidenceFailure TotalDecommissionCompleteEvidence

mkIncompleteCleanup
  :: RecoveryPlaneAuthority surface
  -> CleanupEvidenceScope
  -> RecoveryPlaneDisposition surface
  -> NonEmpty (ScopedCleanupFailure surface)
  -> Either EvidenceScopeFailure (IncompleteCleanupEvidence surface)

mkIncompleteLocalDelete
  :: LocalDeleteScope
  -> NonEmpty ScopedLocalDeleteFailure
  -> Either EvidenceScopeFailure LocalDeleteIncompleteEvidence

mkIncompleteDecommission
  :: DecommissionEvidenceScope
  -> DecommissionRunnerDisposition
  -> NonEmpty ScopedDecommissionFailure
  -> Either DecommissionEvidenceFailure DecommissionIncompleteEvidence
```

`PreUninstallCommit` is opaque and contains the independently backed-up/read-back cleanup-report
receipt plus the one-shot local-completion permit under one evidence scope.
`ReadyToUninstallEvidence`, every surface-specific complete evidence, `LocalOnlyDeleteEvidence`,
`TerminalAuditEvidence`, and `CascadeCompleteEvidence` have private constructors. The result ADTs
are abstract outside the lifecycle result module; callers receive total read-only folds for exit
status and narration, not their constructors. `mkIncompleteCleanup`, `mkIncompleteLocalDelete`, and
`mkIncompleteDecommission` are the only incomplete minters. Each seals the stable run ID,
surface-indexed authority/runner disposition, and scope-bound nonempty failure set into one opaque
value after checking registry revision, account, region, substrate, operation, and report digest.
Run-A failures therefore cannot be paired with a run-B `Established` disposition, and an ordinary
recovery disposition cannot inhabit total decommission.
`CompleteNoAwsTargetProjection` is mintable
only by the complete exact registry/run-descriptor projection; it is not inferred from missing
credentials, an empty response, local substrate identity, or a failed audit. A run with AWS targets
must supply `terminalAuditFromAws`; a genuinely no-AWS run supplies
`terminalAuditWithoutAws`. The two arms bind the same cleanup scope, so omitting a required audit is
unrepresentable while an empty AWS target set remains completable. A clean resource
report can authorize the cascade local uninstall but cannot claim that uninstall succeeded. Only a
positive `RecoveryPlaneEstablished` arm exposes the surface-indexed `RecoveryPlaneReady 'Cascade`
required by
`readyToUninstall`; `NotEstablished` and `Lost` have no conversion to it. Only a successful exact
host observation after `RunLocalUninstall` yields `LocalUninstallEvidence 'Cascade`
and permits `CascadeComplete`. The constructor checks that every component carries the same
`CleanupRunId`, registry revision, account, region, substrate, operation scope, and report digest;
evidence from another run or authority is not composable. The CLI may map
`CascadeComplete` to exit zero and `CascadeIncomplete` to a non-zero exit, but it cannot construct
either result from a collection of phase exit codes or prose. An incomplete result always carries
the observed recovery-plane disposition; it never promises that a plane which failed to establish
is live. Before uninstall, Authority signs the one-shot local-completion permit carried by
`PreUninstallCommit`. After exact host absence, `prepareLocalCompletion` binds that permit and the
observed uninstall digest to the stable local-completion operation reference. The host interpreter
idempotently appends it to the preserved non-secret cleanup journal, and a separate observation of
the same reference mints `LocalCompletionReceipt`. The host cannot widen the signed scope, and a
rerun can perform that observation after a lost append response without reinstalling a control plane
merely to rewrite history. Local-only delete instead terminates at exact
`LocalUninstallEvidence 'LocalOnly`; its result type has no conversion to `CascadeCompleteEvidence`.

The other destructive surfaces terminate through their own smart constructors, never through a
shared “exit zero” wrapper. Explicit per-run completion requires exact selected-stack and bounded
child-family absence plus checkpoint disposition and a read-back surface report. Operational
completion requires exact consumer quiescence, operational credential/lease absence, and observation
of every retained dependency. Explicit long-lived completion requires the aggregate-specific permit,
exact aggregate/family absence, credential-generation/tombstone disposition, checkpoint disposition,
and report read-back. Total decommission completion requires exact non-local target absence, exact
local absence, the no-retention total-audit witness, explicit `.data` retention/deletion disposition,
and the terminal frame read back from the external receipt. None of those evidence types converts to
another surface's success type; every incomplete arm retains its stable run identity, authority or
runner disposition, and all observed failures.

Validation is one client of this lifecycle core. It registers the originating validation result and
its cleanup obligations, then consumes the same durable graph and report. Validation-specific
failure aggregation belongs to
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-validation-as-a-cleanup-client);
generic teardown semantics live here.

A process-global world-state machine remains prohibited. It would model a stale cross-product of
facts held by different external authorities. The target instead uses small flat observations,
opaque complete keyed sets, total decisions, and a durable operation graph that re-observes reality
at every mutation boundary.


## 4. Pre-Cutover Predicate Migration Inventory

The current worktree still contains callback-era `Precondition` and `reconcileAbsent` paths. They
are migration inputs, not a second normative lifecycle model. Their exact removal owners and source
locations live in the
[deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

| Pre-cutover shape | Target projection |
|---|---|
| `noLiveLongLivedPulumiStacks` | A `LongLived` registry projection retained by ordinary cleanup; explicit long-lived/total-decommission programs require their own exact absence evidence. |
| `noLiveClusterTaggedAws` and raw `TaggedResource` rows | A normalized `EscapeSweepReport` sum used only by the terminal audit; it has no conversion to exact resource inventory. |
| `noUndrainedK8sAwsResources` and boolean reachability | Exact EKS observation, a bound `EksDrainSession`, typed drain outcome, registered family backstops, and exact absence read-back. |
| `noLiveOperationalIamIdentities` | Exact `Operational` IAM/key/generation descriptors with dependency-derived cleanup nodes and credential disposition. |
| `noLeftoverRegisteredDnsRecords` / `noLeftoverDnsBootstrapRecords` | Exact DNS singleton/family references whose desired-presence or desired-absence program is fixed by registry ownership and cleanup surface. |
| positional `reconcileAbsent` batches and manual phase folds | The result-indexed program and durable graph in §3.3. |

Local-only `prodbox cluster delete --yes` remains intentionally outside AWS desired absence: it
preserves `.data/`, does not query or mutate per-run AWS, and makes no AWS-clean claim. Cascade and
explicit stack destroy use the exact program model in §3. A missing/unreadable checkpoint or
unreachable provider is an explicit incomplete result, never graceful absence.

`aws-ses` remains excluded from cascade by its `LongLived` index. It may be targeted only by the
explicit long-lived surface or total decommission; backend location does not change lifecycle
class.

## 5. Mandatory Entry Contracts for Destructive Commands

Every destructive command selects a typed cleanup surface before any effect. The surface determines
which lifecycle classes are legal targets, which recovery capability must remain live, and what
evidence can construct completion.

| Command | Entry contract | Completion contract |
|---|---|---|
| `prodbox cluster delete --yes` | Local-only surface; probe local install state | Uninstall local RKE2 if installed, preserve `.data/`, and make no AWS claim |
| `prodbox cluster delete --cascade --yes` | Acquire or resume a durable cascade run, then ensure the ordinary teardown recovery profile | Exact per-run and dynamic-family absence, credential disposition, terminal audit evidence (clean scoped AWS audit or exact no-AWS projection), backup-receipted convergence report, then exact local-uninstall absence and a scoped local completion receipt |
| `prodbox aws teardown` | Select only `Operational` registry targets and prove their exact consumers quiescent | Operational absence plus explicit observation/retention of every `LongLived` dependency |
| `prodbox aws stack <stack> destroy --yes` | Select the exact registered stack; its lifecycle class projects either the explicit-per-run or permit-bound explicit-long-lived surface | Exact stack/family absence read-back; provider exit alone is insufficient |
| `prodbox nuke` | TTY, typed confirmation, signed manifest, pinned runner, and external receipt sink | The external decommission protocol in §6b; ordinary cascade authority cannot enter this surface |

Preflight is not a bag of boolean predicates. It is pure construction of the selected target set,
complete observation requirements, credential-lifetime dependencies, and durable graph. Failure to
construct that value refuses before mutation and names the missing exact key or capability.

### 5a. Local-only no-install short-circuit

The no-install short-circuit belongs only to `prodbox cluster delete --yes`. When none of the local
RKE2 install markers is present, local-only delete prints `No RKE2 cluster to delete.`, preserves
`.data/`, makes no statement about AWS, and exits zero.

`prodbox cluster delete --cascade --yes` must not take that short-circuit. Local RKE2 absence is not
per-run AWS absence and is not evidence that no nonterminal cleanup run exists. Cascade inspects the
durable cleanup namespace and retained establishment metadata, repairs or reinstalls the minimal
recovery substrate when the preserved trust root makes that legal, and proceeds through §5b. A
matching read-back local-completion receipt may prove that an earlier run already finished; a
missing marker or empty directory cannot. If neither a valid completion receipt nor a recoverable
trust root exists, cascade returns `RecoveryPlaneNotEstablished` and makes no AWS-absence claim. An
installed-but-stopped API is a recovery case, not a terminal unsupported state.

The local-only escape hatch remains intentional. An operator may explicitly uninstall local RKE2
while preserving `.data/` and leaving AWS untouched. That operation cannot be rendered as a
successful cascade and cannot close a durable cleanup obligation.


### 5a.1. Inotify Host-Prep (first host-prep step)

Before local uninstall, and before cascade repairs or starts its minimal recovery substrate, both
delete forms run `ensureHostInotifyLimits`. The local-only no-install arm may return before this
step because it performs no uninstall; cascade never returns merely because RKE2 is absent. It is the same
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
It is local-host kernel configuration, not cluster-side or AWS-side work, and is non-destructive
and idempotent, so running it before recovery or a typed refusal is safe.

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

The reconciler observes host cpu, memory, and filesystem capacity first, then
compiles the opaque proof-carrying `AllocatedResourcePlan`
(`Prodbox.Capacity.Allocation`, built by the total `compileResourcePlan`) against
those observed host facts. Closing invariant (b)
`cluster <= host` this way makes an observed host that cannot cover the plan's
allocatable a `Left` — an over-committed plan is not a constructible value — so
reconcile refuses at compile time, before mutating these files. This supersedes
the authored-only `hostCapacityCoversPlan` boolean (deleted alongside
`clusterAllocatable`): the invariant is now closed against the observed machine,
not merely the authored `host_capacity`. This is the runtime counterpart of the
static `rke2.reserved + eviction.floor <= host.physical` lemma in
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

### 5b. Canonical recover-to-clean cascade

`prodbox cluster delete --cascade --yes` starts or resumes a durable desired-absence operation.
Its graph is derived from the registry and the retained cleanup-run descriptor:

```text
ensure or resume minimal recovery plane
  -> exact keyed reconnaissance
  -> EKS drain attempt
       -> controller-family cleanup       [RequiresAttempt]
       -> per-run stack cleanup            [RequiresAttempt]
  -> exact absence read-back               [RequiresAttempt per mutation]
  -> test-EBS and credential cleanup
  -> terminal audit requirement (AWS clean audit | exact no-AWS projection)
  -> backup-receipted convergence report
  -> local RKE2 uninstall                  [RequiresSuccess]
  -> exact host-absence read-back and local completion receipt
```

The nodes have these contracts:

1. **Ensure or resume the recovery plane.** First accept only a scoped, read-back local-completion
   receipt as evidence that a prior run already finished. Otherwise, if local RKE2 is stopped,
   repair and start it; if RKE2 is absent and the retained trust root is recoverable, install the
   minimal ordinary teardown profile against the preserved `.data/` roots. Restore the Lifecycle
   Authority from its receipt-committed backup when necessary and resume every nonterminal cleanup
   run before new admission. An absent or unrecoverable trust root is a typed refusal, not permission
   to infer that AWS is empty. This is the same control plane and authority model, not a host-direct
   MinIO, Vault, Kubernetes, or AWS bypass.
2. **Observe exact keyed truth.** For each `PerRun` target, observe exact provider inventory,
   primary and backup checkpoint state, ownership-manifest completeness, and every registered
   dynamic family as separate values. The durable run descriptor supplies substrate, account,
   region, cluster identity, and operation scope. A global tag result cannot enter this node.
   Pre-cutover stacks with no write-ahead receipt may enter only the bounded legacy-adoption plan
   from §3.2; discovery alone supplies no destroy permission.
3. **Attempt EKS owner drain.** Positive exact EKS presence admits
   `IssueEksDrainSession`. The Fenced Provider Worker obtains endpoint, CA, cluster identity, and a
   short-lived authentication token from the provider under an account/region/cluster/deadline-bound
   session. It does not materialize the session from Pulumi outputs or from a host kubeconfig.
   Owners are deleted while controllers are live and exact child-family absence is read back.
4. **Run every eligible desired-absence program.** Drain failure or unavailability remains a typed
   failure but opens `RequiresAttempt` edges to exact controller-family backstops and provider
   destroys. Each stack uses the §3.2 decision: verified primary, restored backup, complete
   write-ahead or confirmed-legacy ownership manifest, already absent, or refusal. Independent
   nodes continue.
5. **Re-observe exact absence.** Provider exit zero, deleted Kubernetes owners, and an empty audit
   are not completion. Read-back is a `RequiresAttempt` successor of every mutation, so a reported
   failure or applied-without-response result cannot suppress the observation that disambiguates
   it. Each registered resource and bounded family must produce exact absence evidence under the
   same key and scope. Test-scoped EBS and Operational credential nodes then reconcile absent only
   after their exact dependants are terminal.
6. **Satisfy the terminal-audit requirement.** When the complete run projection contains AWS
   targets, the global cluster/ownership tag audit runs only after exact obligations have been
   re-observed. It reports normalized distinct resources, partitions intentionally retained
   `LongLived` resources, and fails on escapees or incomplete observation. When that projection
   proves there are no AWS targets, no AWS query runs and the scoped no-AWS witness satisfies the
   distinct terminal arm. Neither arm selects a stack, changes a stack decision, proves a stack
   absent, or resolves checkpoint corruption.
7. **Commit convergence before uninstall.** The Lifecycle Authority commits the complete
   pre-uninstall cleanup report and the independent Backup Adapter reads back that exact report.
   Authority also signs the one-shot local-completion permit. Only `ReadyToUninstallEvidence`,
   bound to the same cleanup run and its terminal-audit evidence, admits local RKE2 uninstall.
8. **Observe local absence and complete.** The uninstall preserves `.data/`, removes the managed
   kubeconfig, and is followed by an exact host observation. The host interpreter atomically stores
   and reads back the scoped completion receipt beside the preserved cleanup journal. Only that
   receipt plus the matching absence evidence can construct `CascadeCompleteEvidence` and close
   the durable run.

If any required observation, mutation, read-back, credential disposition, audit, report receipt, or
local-uninstall read-back remains unresolved, the result is `CascadeIncomplete` with the stable
`CleanupRunId`, exact failures, and `RecoveryPlaneDisposition`. The command exits non-zero. When
the minimal plane was established, it and the credentials needed by nonterminal nodes remain live;
if establishment failed or the plane was later lost, the result says so rather than promising a
live recovery transport. A rerun resumes that ID and does not create a new operation for an
ambiguous effect.

The minimal recovery plane and its physical ownership are defined by
[Lifecycle Control-Plane Architecture §11.0](./lifecycle_control_plane_architecture.md#110-ordinary-teardown-recovery-profile).
Total trust-root loss remains a refusal; ordinary cascade does not acquire the external authority of
`nuke`.

The drain-before-network-destroy dependency remains load-bearing, but it is represented as graph
edges and typed outcomes, not positional execution. A positively absent EKS cluster satisfies its
drain obligation from exact provider evidence. An unreachable EKS API does not: the graph attempts
the registered provider backstops, retains the drain failure, and can close only after exact EKS and
controller-family absence.


### 5c. Per-run EKS desired absence drains owners first

Every surface that selects the registered EKS resource consumes the same graph projection. There is
one drain attempt for the exact cluster, one set of controller-family obligations, and one provider
destroy operation ID; the CLI, validation postflight, and recovery worker do not wrap one another's
destroy commands.

Positive exact EKS absence satisfies the drain node without a Kubernetes session. Positive presence
requires the typed expiring session in §5b. API or authentication failure records a typed drain
failure and opens only the `RequiresAttempt` backstop edges. The graph cannot downgrade that failure
because provider destroy succeeded, and it cannot issue two drain attempts under separately
materialized kubeconfigs.


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

## 6. Scoped terminal escape audit

The cluster/ownership tag query is a terminal defense-in-depth audit on
`cluster delete --cascade` and `nuke`. It is not a source of per-stack inventory and has no
conversion to the exact observation types used by §3. It runs after exact cleanup obligations,
never before them as a destroy selector.

Each provider response is normalized into `Map Arn AwsResource`. Multiple tags, filter-set overlap,
pages, and retries merge into one resource per ARN. Conflicting account, region, type, or coordinate
facts for the same ARN make the audit unobservable. The audit then partitions the normalized
inventory against a declared retained catalog, described in §6.0.

### 6.0 The retained catalog is exact identities, not a tag predicate

An audit needs two catalogs, and they answer different questions.

The **query catalog** says what the audit asked for. It is symbolic — tag keys and tag pairs — and
is digested into the audit scope, so a clean verdict claims nothing about anything the queries did
not cover. Naming the queries is what makes the audit's field of view auditable rather than implied.

The query catalog's completeness is a **measured** property, not an authored one. Whether the tag
families it names actually cover the resources this repository provisions is a fact about the
provisioning programs, and an audit whose field of view excludes a resource reports a clean verdict
that reads exactly like a statement that the resource is gone. `prodbox dev check` therefore joins
the compiled query catalog to every resource the programs under `pulumi/` declare: each declared
resource's provider type is classified for Tagging API reach, and every type that accepts tags must
author at least one tag the catalog queries for. An unclassified provider type fails the build rather
than being assumed either reachable or exempt, and the program set is enumerated from disk so a new
provisioning program is covered by existing rather than by being remembered. A tag on a §6a
registry-owned IAM identity is a backstop for this audit, never an ownership authority.

Reach has a **second axis, and it is the audited region**. The Resource Groups Tagging API is
regional: a regional resource is returned by a query issued in the region that holds it, and a
global-service resource — IAM, Route 53 — is returned only from the global-service region. The audit
composes its queries from the audited scope and issues them in that scope's own region, so an audit
taken elsewhere asks about no global-service resource at all. The set of global services this
repository provisions into is derived from the reach classification itself rather than authored
beside it, so a newly classified global-service type widens the bound without a second list.

Two consequences are structural. A declared retained family is discoverable only when its writer
authors a queried tag **and** the audited region answers for its service, so a global-service family
can never be reported permanently absent-declared by an audit that never asked about it. And a clean
witness may not be minted over that blind spot: outside the global-service region a would-be-clean
verdict lowers to `TerminalAuditUnobservable`, naming each unqueried service and the region that
answered. A discovered escapee is unaffected — a blind spot cannot launder one into the retained set —
so only the clean arm is bounded. The superseded executing tag sweep binds no region at all; the
deletion ledger carries that residual until the consumer conversion deletes it.

The **retained-matcher catalog** says which resources this surface intends to keep. Every matcher is
an exact identity: a fully-qualified ARN composed from the audited `AwsScope` plus a validated
operator-name binding, or a registered family whose membership coordinate comes only from the
compiled registry. Four categories are declared — long-lived object storage, the retained SES
sending and receiving configuration, shared IAM identities, and registered `LongLived` families of
unbounded cardinality — and each matcher records its category, its cardinality, and whether the query
catalog can return it at all.

Whether a declared retained family is discoverable at all is **derived**, not authored. Each family
states the tag set its production writer authors, and the matcher is discoverable exactly when the
query catalog covers one of them; a family whose writer stops tagging becomes not-discoverable by
construction rather than continuing to claim otherwise. Writer, read-back, and audit hold one
compiled tag value, so a resource cannot be written with one set and certified against another.

A tag predicate cannot do this job, and the reason is directional. A retained resource whose tag was
removed is classified as an escapee, which is safe; an escapee that *acquires* a retention tag is
classified as retained, which is not. Membership in a registered family is still witnessed by the
family's declared coordinate, which may be a tag pair — but the family's `LifecycleClass` was fixed
statically by the registry before any provider row was read, so the tag chooses nothing. No function
converts tag evidence into a lifecycle class.

Retention is surface-indexed and the catalog carries its index, so one surface's retained set cannot
be presented as another's. Total decommission retains nothing, because destroying the retained set
is what it is for. Operational teardown owns the operational credentials and therefore does not
retain them. A run-scoped credential is retained on no surface, so finding one after a cleanup is an
escape. The retained-set digest is derived from the catalog rather than authored, and a consumer
joins the catalog's AWS scope to its own proof of scope, so a foreign-account retained set cannot be
presented under a matching digest.

The partition separates two failures a tag sweep conflated. An **escapee** is a resource no matcher
names; it makes the surface dirty. A **declared retained resource the query should have returned and
did not** is a retention defect; it is reported separately and does not make the surface dirty.

The audit has three terminal outcomes:

- `EscapeSweepConfirmedClean` — every constituent query completed, intended retained resources match
  their exact registry entries, and no unowned resource escaped;
- `EscapeSweepFoundEscapes (NonEmpty AwsResource)` — normalized resources remain outside the intended
  retained set; or
- `EscapeSweepUnobservable (NonEmpty ObservationFailure)` — credentials, transport, pagination,
  parsing, or a conflicting provider fact prevented a complete answer.

Only the first can mint `EscapeAuditClean surface`. The cascade-indexed witness may mint the
AWS-required arm of `TerminalAuditEvidence`; the total-decommission-indexed witness is consumed only
by `completeTotalDecommission`. Neither can cross surfaces. A clean audit still
cannot prove any exact stack,
IAM identity, DNS record, EBS volume, controller family, checkpoint, or Vault generation absent.
Those obligations close through their own observers.

A missing AWS credential is not a clean audit and is not a reason to infer a home substrate. If the
durable cascade run has no AWS targets and its exact registry projection proves that fact, the graph
contains no AWS audit node; that private `CompleteNoAwsTargetProjection` mints the no-AWS arm of
`TerminalAuditEvidence`. If it has AWS targets, the no-AWS witness is unconstructible and the
required credential remains live until the audit completes or the cascade returns
`CascadeIncomplete`.


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
   coordinate into a bounded ownership manifest and reads it back. If legacy state is already
   missing, the admin-authorized migration may use read-only IAM/EKS and
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
SMTP/EAB generation tombstone, and the distinct retained-home SMTP/EAB custody tombstones. It
deletes every TLS prefix object version and TLS identity/key without deleting the shared bucket. The
final Authority-backup node deletes its objects/versions, `secret/aws/authority-backup-store`
generation, key, identity/policy, proves every registered shared bucket prefix absent, and deletes
the `pulumi_state_backend` bucket last.

An **ordered terminal phase** then follows the last resource deletion, and every node of it is a
node of the signed graph rather than a tail that runs after the runner returns. The required scoped
tag sweep is first: it admits no retained carve-out, so it can only report the whole plan as
converged once the shared bucket it would otherwise name as an escapee is gone. The home substrate
uninstall follows the sweep, because the sweep — like the SMTP quiescence, target-generation, and
retained-custody nodes before it — is answered through the plane the uninstall dismantles. Waiting on
every other node is strictly stronger than requiring only that the home-plane-dependent nodes are
terminal. The operator's explicit `.data` retain-or-delete disposition is last, after the uninstall
that stopped writing to the root; the decision is a parameter of its signed manifest node, so it
enters the manifest digest rather than arriving as a runtime flag, and a receipt opened for one
decision cannot be resumed under the other. The terminal-receipt node closes the phase: it refuses
unless the receipt's own committed frames already record every other plan node as durably terminal,
so its success frame — appended through the same fsync/reopen/validate primitive as every other frame
— is the record's own declaration that the run converged. Its read-back is read-only by construction
and refuses a torn tail rather than repairing it, because it reads the very record it is a node of.
The runner never requires or claims a backup receipt after backup deletion.
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

## 8. Vault in the cluster lifecycle

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
- **Ordinary teardown preserves the durable Vault PV.** `prodbox cluster delete --yes` and
  `prodbox cluster delete --cascade --yes` preserve the durable Vault PV exactly
  like the MinIO PV (§2). Only the separately authorized `prodbox nuke` total-decommission surface
  may remove `.data/` after exporting and verifying its external receipt (§6b). A wiped-and-rebuilt
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

## 9. SES Aggregate Reconciliation

SES reconciliation is a durable staged aggregate rather than one synchronous lease-held request.
It commits the desired contract and provider revision, converges the non-credential Provider
inventory, releases the narrow mutation fence, awaits the exact semantic revision, reconciles a
Credential-Provisioner SMTP generation, and drains one durable delivery per selected target.
Restart resumes the first incomplete committed stage. A newer generation refuses while any target
still records an older or absent receipt.

Legacy credential ownership moves only through `LegacyPulumiWriter`,
`CredentialMigrationFrozen`, and `ProvisionerWriter`. Adoption requires exact checkpoint/IAM/key
evidence, checkpoint release, retained-home custody, and read-back from every current target. There
is never a state with two IAM writers; rollback is a forward migration to a greater epoch.

## Related Documents

- [chaos_hardening_doctrine.md § 21](./chaos_hardening_doctrine.md#21-the-eight-coordinates--where-to-put-the-type) — its *Cardinality* class means
  effect ownership (“who may write”), not normalization of provider rows to domain identity. The
  registry in § 3.1 makes a resource discoverable and destroyable; it does not make an authoritative
  write *entitled*. “At most one writer” asserted in a chart comment plus `replicas: 1` is a
  deployment wish, not a proof. The move is a write permit minted only from a live fenced lease or
  CAS, carrying the token the store checks at apply time — and § 22 records why even that is a
  process property, not a protocol one, until a model exists.
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
