# Lifecycle Control-Plane Architecture

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md,
documents/engineering/bootstrap_readiness_doctrine.md,
documents/engineering/aws_account_setup_guide.md,
documents/engineering/aws_admin_credentials.md,
documents/engineering/aws_test_environment.md,
documents/engineering/chaos_hardening_doctrine.md,
documents/engineering/cli_command_surface.md,
documents/engineering/cluster_federation_doctrine.md,
documents/engineering/config_doctrine.md,
documents/engineering/distributed_gateway_architecture.md,
documents/engineering/helm_chart_platform_doctrine.md,
documents/engineering/haskell_code_guide.md,
documents/engineering/integration_fixture_doctrine.md,
documents/engineering/lifecycle_reconciliation_doctrine.md,
documents/engineering/local_registry_pipeline.md,
documents/engineering/prerequisite_doctrine.md,
documents/engineering/prerequisite_dag_system.md,
documents/engineering/pure_fp_standards.md,
documents/engineering/resource_scaling_doctrine.md,
documents/engineering/secret_derivation_doctrine.md,
documents/engineering/storage_lifecycle_doctrine.md,
documents/engineering/test_topology_doctrine.md,
documents/engineering/unit_testing_policy.md,
documents/engineering/vault_doctrine.md,
documents/engineering/aws_integration_environment_doctrine.md,
DEVELOPMENT_PLAN/development_plan_standards.md, DEVELOPMENT_PLAN/README.md,
DEVELOPMENT_PLAN/00-overview.md, DEVELOPMENT_PLAN/system-components.md,
DEVELOPMENT_PLAN/substrates.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md,
DEVELOPMENT_PLAN/phase-0-planning-documentation.md,
DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md,
DEVELOPMENT_PLAN/phase-2-gateway-dns.md,
DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md,
DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md,
DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md,
DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md,
DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md,
DEVELOPMENT_PLAN/phase-8-email-invite-auth.md
**Generated sections**: none

> **Purpose**: Define the pure-functional component, capability, authority, and interpreter
> boundaries that isolate bootstrap and lifecycle control-plane work from the distributed gateway
> runtime.

Implementation status, sprint order, blockers, cutover ownership, and deployment qualification are
tracked only in the [Development Plan](../../DEVELOPMENT_PLAN/README.md). This document owns the
target topology and invariants; it is not a migration-status ledger.

## 1. Boundary Ownership

The lifecycle control plane is divided into the independently scheduled capabilities below. A
logical capability may pair a steady controller with an isolated one-shot secret worker; that does
not merge its authority with another row. Gateway Runtime remains the separate
distributed data-plane boundary described below; the post-export Decommission Runner is a
standalone terminal authority after Lifecycle Authority has stopped and is not a control-plane
workload.

| Component | Sole authority | Explicit non-authority |
|-----------|----------------|------------------------|
| Bootstrap Broker | Bounded Vault initialization/unlock/seal, allowlisted baseline mount/auth/policy/role reconciliation, exact genesis-signing Transit key/public trust, key rotation, and PKI administrative requests | Generic Vault KV, gateway mesh, lifecycle records, checkpoints, SES, target secrets |
| Lifecycle Authority | Authority epoch/time, durable operations/fences, Model-B CAS, immutable checkpoint and in-force-config references, provider revisions, encrypted operator-material intents, and delivery outbox | AWS credentials/S3 calls, Gateway leadership, peer repair, public DNS election, direct target Vault mutation |
| Credential Provisioner | One indexed-permit-bounded deterministic IAM/S3 identity create/observe/repair-delete/remint transaction, including SMTP IAM identity/policy/access-key install, rotation, and repair, plus direct plaintext handoff to the selected Target Secret Agent | Explicit terminal SMTP-family destroy, Authority decisions/state writes, Pulumi/provider work, arbitrary IAM/S3, config, Gateway/DNS, persisted credentials |
| Admin Action Runner | One backup-receipted `AdminActionPermit` for explicit registered SES/S3 plus SMTP IAM destroy, legacy backend migration/retained-store compatibility, or quota request/status read-back | Credential creation/delivery, normal provider work, generic shell/AWS, Authority state writes, nuke/decommission |
| Fenced Provider Worker | Closed normal provider intents, including registered stack-owned non-credential IAM roles, bounded scratch checkpoint execution, authoritative observation, and read-back under one narrow session | Credential IAM identity/access-key create/delete/remint, any prompt/credential permit, Authority state writes, backup/TLS identity, target secrets, Gateway/DNS election |
| Authority Backup Adapter | Closed prepare/blob/commit-receipt/restore/GC protocol for the independently backed Authority namespace | Provider/AWS-resource mutation, generic S3, Authority decisions, config projection, target secrets, Gateway/DNS |
| TLS Retention Adapter | Closed ciphertext-byte retain/read-back and restore-envelope-byte protocol for exact `public-edge-tls/<substrate>/<fqdn>` objects | Plaintext certificate/key material, backup/provider credentials, generic S3, Authority decisions, target mutation, Gateway routing |
| Target Secret Agent | Allowlisted payload sealing plus generation-checked Vault KV observe/CAS/read-back for one substrate; retained home Agent also owns closed SMTP/EAB custody and rewrap | Global lease, provider mutation, checkpoints, gateway mesh, arbitrary KV or generic secret export |

Deployment cardinality is explicit: there is exactly one logical Lifecycle Authority in the
retained home/control-plane substrate for an authority epoch, with one separately deployed Authority
Backup Adapter bound to that logical writer. Every substrate that owns a Vault
deploys its own Bootstrap Broker and Target Secret Agent; every participating cluster deploys its
own Gateway Runtime replicas. The ephemeral AWS substrate receives an authority client reference,
never a second authority writer. Replica failover for the retained authority is leader/fence
coordination inside that one logical identity. It tolerates process or Pod loss while the retained
authority store is intact; it is not falsely described as storage-disaster HA. Every transition
uses an encrypted prepare record plus commit receipt in the registered backup before its external
effect may run, and every referenced blob is digest-verified there. Store-loss recovery restores
only receipt-committed transitions while all writers are frozen, re-observes external effects, and
activates a strictly greater authority epoch.

Here “store loss” means loss/corruption of the Authority primary MinIO namespace while the retained
home Vault/Transit keys, `secret/aws/authority-backup-store` generation, and long-lived S3 backup
remain intact. Loss of the whole home `.data` trust root, including Vault custody/Transit keys, is
not recoverable from ciphertext backup and is not described as disaster recovery or HA.

The distributed Gateway Runtime owns peer membership, bounded signed state, ownership projection,
and, on home only, the registered public DNS effect. The EKS Gateway has no DNS-mutation capability.
Gateway is neither a bootstrap service nor a generic object-store, lifecycle, or secret-management
proxy. Its architecture remains canonical in
[Distributed Gateway Architecture](./distributed_gateway_architecture.md).

The physical dependency order is:

```text
MinIO + Vault workload -> Bootstrap Broker
                       -> Vault unsealed + baseline provisioned
                       -> genesis-signing Transit key + Agent public trust
                       -> retained-home TLS-envelope Transit key/lane
                       -> per-substrate Target-Agent commitment-HMAC key

Vault + primary MinIO -> Lifecycle Authority (GenesisFrozen)
                     -> signed one-time GenesisBackupPermit
                     -> ephemeral Credential Provisioner Job (raw admin prompt)
                     -> home Target Secret Agent (consumed marker + seal receipt)
                     -> Authority Backup Adapter -> long-lived S3 receipts/blobs
                     -> normal AdmissionOpen
                     -> in-force config generation/reference
                                    -> fenced Provider Worker
                                    -> on-demand Admin Action Runner (explicit admin commands only)
                                    -> TLS retention outbox -> TLS Retention Adapter
                                    -> encrypted target-delivery outbox
                                    -> Target Secret Agent on each substrate

Vault baseline + role-scoped config -> Gateway Runtime
                                    -> encrypted identity-bound emitter journal
                                    -> bounded peer mesh and owned DNS effects
```

`prodbox config setup` only authors and validates Tier-0; it performs no IAM, S3, Vault, or
Authority mutation. `prodbox cluster reconcile` first deploys bootstrap MinIO, the Vault workload,
and Bootstrap Broker, then performs the visible initialize/unseal/baseline actions. It next deploys
the home Target Secret Agent, Lifecycle Authority, and separate Authority Backup Adapter with
Authority in `GenesisFrozen`. The normal Provider Worker exists as a separate Deployment/SA/queue
but is not admitted while genesis is active. The plan then narrates the visible
`EstablishAuthorityBackup` action. Before creating the Job, the pure planner compiles a bounded
secret-free `FirstReconcileProvisioningPlan` from Tier-0 plus the managed identity registry: exact
ordered action indices, identity/target/coordinate bindings, maximum count, and session deadline.
Authority primary-journals the intent and issues a signed
one-time `GenesisBackupPermit`, after which a separately resourced Credential Provisioner Job alone receives
the ephemeral operator-admin prompt (or test-only automation fixture), performs the permit-bounded
AWS work, and hands the credential directly to the home Agent. The genesis arm is permanently
revoked after its typed receipts are read back; the prompt session may remain only while the same
verified Pod/attach session, absolute deadline, host heartbeat, attestation, exact next plan member,
and durable prior-member receipt remain valid for the separately permitted normal setup phase. The
Job never forwards raw admin or any created credential to Authority or the normal Provider Worker.
Initial backup receipt and permanent Agent genesis-disable read-back complete before normal
admission opens. Only afterward does the plan submit the Tier-0 in-force-config proposal and
backup-receipted
`OperatorMaterialPermit 'AwsAdminProvisioningIngress`s for the remaining registered AWS
identity/store actions. The still-valid Job may reuse
its mlocked prompt buffer only for an unconsumed member of the Genesis-permit-bound provisioning-
plan digest, and only after the preceding action receipt is durable. Each action still needs its
own permit; the plan is a bound, not authority. After the final plan member, the Job revokes its
session, best-effort zeroizes owned mutable buffers, exits, and is observed absent before
platform/application deployment continues. ACME EAB, when required, uses a separate
`ExternalAcmeEabIngress` Job/frame and is never a member of that AWS plan. A broken attach/session
requires re-prompt but resumes the same permits and inventories. No IAM/S3 create is hidden inside
readiness or a prerequisite.

The steady capabilities are distinct Deployments, Services, ServiceAccounts, Vault policies,
resource envelopes, queues, and readiness identities. Credential Provisioner and Admin Action
Runner are distinct separately resourced, attested, one-shot Job/ServiceAccount roles with no
steady Service or reusable queue. A Gateway
Runtime outage or CPU saturation cannot consume the
Lifecycle Authority's admission budget or prevent a lifecycle operation from being observed,
resumed, or closed.

### 1.1 Credential identities and writers

The pre-cutover shared `secret/gateway/gateway/aws` object is forbidden in the target topology.
AWS power is split into separately minted identities and Vault coordinates:

| Identity | Sole consumer | Scope |
|----------|---------------|-------|
| Lifecycle provider bootstrap | Fenced provider worker only | Assume only the operation-specific Pulumi, non-credential SES/S3, or AWS-edge role named by a committed provider intent |
| Authority backup-store bootstrap admin | Ephemeral Credential Provisioner Job only | One signed `GenesisBackupPermit`'s deterministic bucket/prefix/IAM create/observe/delete/remint set; raw material is memory-only and cannot authorize normal provider work |
| Authority backup store | Credential Provisioner only until direct Agent sealing, then the separately deployed Authority Backup Adapter only through the `LongLived` generation at `secret/aws/authority-backup-store` | Get/put/version/read-back and fenced GC only under the exact long-lived backup bucket/prefix; no provider, DNS, IAM, or arbitrary target-Vault power |
| TLS retention store | Separately deployed TLS Retention Adapter only, using the `LongLived` generation at `secret/aws/tls-retention-store` | Ciphertext get/put/version/read-back only under exact `public-edge-tls/<substrate>/<fqdn>` prefixes; no Authority-backup, provider, DNS, IAM, or target-Vault power |
| SMTP credential family | Credential Provisioner for install/rotate/remint and repair-time deletion; Admin Action Runner only for exact `DestroyAwsSes` teardown | Deterministic SMTP IAM identity/path/policy/access-key inventory plus Authority key-ID/opaque Agent receipts; no raw IAM secret persists |
| Retained operator-material custody | Retained home Target Secret Agent one-shot custody/rewrap lane only | Closed `SesSmtpMaterial` and `AcmeEabMaterial` Transit-ciphertext receipts; rewrap only to an attested selected Agent for exact `secret/keycloak/smtp` or `secret/acme/eab` generation-CAS materialization |
| Gateway DNS | The Gateway Runtime configured as writer for the exact home public record | Observe/change only the registered zone/name/type record; no SES, EKS, IAM, S3, or cert-manager power |
| cert-manager DNS01 | cert-manager on one substrate | DNS01 TXT operations only in that substrate's configured zone |

The explicit AWS edge reconciler is a Lifecycle Authority provider intent and receives a narrow
provider session; it does not borrow Gateway DNS credentials. `AuthorityBackupStore` has its own
identity/generation and closed internal client; only the Authority Backup Adapter can read it, and
core Lifecycle Authority never receives AWS secret material or uses the Lifecycle-provider
credential. Each identity has a separate IAM user or workload role, access-key lifecycle, Vault
path, Kubernetes-auth policy, generation, and cleanup node. The backup resources are `LongLived`,
retained across suite cleanup and `aws teardown`, and removable only by the frozen `nuke` plan;
the TLS-retention-store, home Gateway-DNS, and home cert-manager-DNS01 generations are likewise
`LongLived` with their
restored live consumers and are removed only by explicit consumer decommission or `nuke`. The AWS
cert-manager-DNS01 generation is run-scoped and is deleted only after EKS
Certificates/Challenges and their exact TXT records are absent. Lifecycle-provider may be
`Operational` and is removed only after every provider operation is quiescent.
Sharing one base access key across the provider worker, backup adapter, TLS adapter, Gateway, or
cert-manager is not permitted.

Operator-minted credentials, the SMTP IAM identity/policy/access-key family, and ACME EAB material enter through a closed
`OperatorMaterialRequest`. Authority-backup-store installation is owned only by
`EstablishAuthorityBackup`; its raw admin prompt and newly created key exist only in the ephemeral
Credential Provisioner's bounded memory until direct Agent handoff. After establishment, the same
sealed-receipt machinery supports continuity-safe rotation, while revocation is owned only by
exported total decommission. For normal material, the Lifecycle Authority assigns an operation ID
and receipt-commits a seal intent. The selected
Target Secret Agent seals the bounded payload with target Vault Transit, CAS-stores/read-backs the
opaque `TargetSealReceipt`, and returns that receipt reference. The Authority commits only its
ciphertext reference and ciphertext digest, opaque `SecretCommitmentRef`, generation, and outbox
intent; delivery then performs the allowlisted generation CAS/read-back and returns the exact Vault
version. Install, rotate, and revoke are
explicit commands; IAM/key deletion must succeed before cleanup commits the corresponding Vault
tombstone. Gateway and host-direct generic secret-write routes are absent.

## 2. Non-Negotiable Invariants

1. A capability is identified by operation, service identity, and authority scope. A component
   label or backend name alone is not evidence.
2. Operational-capability observation, admission, and execution of one requested program use the
   same opaque reference. Callers cannot provide a probe endpoint separately from the execution
   handle; a read-only domain observation is not mutation admission.
3. Dependency graph values contain pure capability requirements, never injected `IO` actions.
4. One authority epoch has exactly one supported logical writer. Shadow readers are permitted;
   dual writers are forbidden.
5. The Lifecycle Authority commits a durable operation transition and outbox intent before an
   external effect begins. Completion is a new fenced transition, never an in-memory assumption.
6. A lost response is resolved by operation ID and authority observation. It is never guessed from
   a transport timeout.
7. Queue wait, credential refresh, external I/O, read-back, and response serialization consume one
   absolute end-to-end deadline.
8. Every queue is bounded. Saturation returns a typed refusal immediately; it does not create an
   unbounded waiter or hidden retry loop.
9. The gateway emitter has one transition owner. Its substrate-specific volume fence, OS lock,
   durable incarnation, and Lease make stage, re-observation, publication, and commit unavailable to
   a second local transition owner.
10. Cleanup obligations are backup-receipt-registered before mutation and interpreted from a
    durable, fenced, restart-resumable DAG. Independent cleanup continues after sibling failure and
    all failures are aggregated.
11. Operational cutover is incomplete until the old writer/routes are removed and the current
    revision is deployment-qualified under
    [Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).
12. In-force configuration is an immutable encrypted blob referenced by a generation in the
    Lifecycle Authority aggregate. Components never fetch it through a host or Gateway MinIO proxy.
13. Every Route 53 record has one registered exact owner and typed observe/ensure/delete/read-back
    operations. Cleanup cannot fall back to a content guess or best-effort untracked CLI call.
14. Provider, Authority-backup-store, TLS-retention-store, Gateway DNS, and cert-manager credentials are distinct
    identities, generations, Vault paths, policies, and cleanup resources. No shared operational
    AWS secret crosses those roles.
15. Before Vault `/sys/init`, the Broker stores/read-backs a password-AEAD-sealed
    `PreparedInitEnvelope` containing the recovery-recipient private key plus transaction/storage
    generation and fingerprints. It stores/read-backs the PGP-encrypted share response and
    burn-recipient-encrypted initial token, atomically promotes/read-backs the final password-AEAD
    unlock bundle, and only then deletes/read-backs the prepared envelope. Applied init without an
    encrypted response is ambiguous and recoverable only through proven-pristine reset. The burn
    public key and fingerprint are compiled, pinned, and provenance-audited; prodbox never
    generates, stores, accepts, or has access to its private key, and never decrypts or uses the
    initial-token ciphertext. Baseline uses a separately generated short-lived root session only after recovery-share
    custody is durable; baseline read-back, revocation, and accessor-absence read-back precede
    completion.
16. A current authority envelope or blob is promotable only after its canonical encrypted bytes are
    read back from a separately credentialed, non-aliased long-lived backup failure domain. Restore
    never activates a dangling reference.

## 3. Pure Capability Algebra

> **Implementation status (2026-07-14, Sprint `1.61`)**: the pure foundation of this algebra has
> landed additively as `src/Prodbox/ControlPlane/{CapabilityKind,Coordinate,CapabilityRef,
> Observation,Permit,Program}.hs` (umbrella `src/Prodbox/ControlPlane.hs`). The landed layout
> refines the illustrative `Capability.hs`/`Program.hs`/`Interpreter.hs` target shapes below:
> `CapabilityKind.hs` owns the kind universe, `CapabilityOp` value mirror, `KnownCapability`
> witnesses, and the `MutatingKind`/`InternalCasKind`/`ExternalIntentKind` markers; `Coordinate.hs`
> the coordinate + digest; `CapabilityRef.hs` the nominal-role opaque reference; `Observation.hs`
> the flat evidence, `classifyEvidence`, and the fail-closed `AdmissionTicket`; `Permit.hs` the
> opaque `WriterPermit` and the signed committed-intent chain; `Program.hs` the closed
> `CapabilityProgram` GADT. The interpreter (§3 below) and the component-graph lowering remain a
> scheduled follow-up cutover; the shapes below are the target the migration lands against.

### 3.1 Operation-indexed references

The operation kind is promoted to the type level. A reference capable only of observing an object
cannot be passed to code requiring conditional write plus read-back.

```haskell
-- Example: target shape for src/Prodbox/ControlPlane/Capability.hs
data CapabilityKind
  = ProcessServiceActive
  | KubernetesWorkloadAvailable
  | KubernetesOperatorAvailable
  | VaultBootstrapObserve
  | VaultBootstrapMutate
  | VaultBaselineReconcile
  | VaultPkiOperate
  | LifecycleObserve
  | LifecycleCasReadBack
  | LifecycleSubmit
  | LifecycleCancel
  | AuthorityEpochCutover
  | AuthorityDecommissionExport
  | AuthorityBackupEstablish
  | AuthorityBackupRepair
  | AuthorityBackupGenesisCleanup
  | CredentialProvisionReadBack
  | AdminActionReadBack
  | AuthorityBackupCommitReadBack
  | TlsRetentionCommitReadBack
  | TlsEnvelopeKeyExchange
  | TlsRestoreDeliverReadBack
  | TlsSecretObserve
  | TlsSecretSeal
  | TlsSecretMaterializeReadBack
  | RetainedMaterialCustodyObserve
  | RetainedMaterialCustodySealReadBack
  | RetainedMaterialCustodyRewrapReadBack
  | RetainedMaterialTargetMaterializeReadBack
  | RetainedMaterialCustodyTombstoneReadBack
  | ConfigObserve
  | ConfigProposeCas
  | OperatorMaterialSubmit
  | TargetSecretObserve
  | TargetSecretSeal
  | TargetSecretProvisionSeal
  | TargetSecretCasReadBack
  | TargetSecretReceiptGcReadBack
  | TargetSecretDecommissionTombstoneReadBack
  | ChildRecoveryCustody
  | ChildRecoveryDeliver
  | GatewayPeerExchange
  | GatewayEmitterRetire
  | GatewayDnsReconcileReadBack
  | RegistryPublishReadBack
  | ProviderApplyReadBack
  | ManagedResourceObserve
  | ManagedResourceEnsureReadBack
  | ManagedResourceDestroyReadBack

data SCapability (kind :: CapabilityKind) where
  SProcessServiceActive :: SCapability 'ProcessServiceActive
  SKubernetesWorkloadAvailable :: SCapability 'KubernetesWorkloadAvailable
  SKubernetesOperatorAvailable :: SCapability 'KubernetesOperatorAvailable
  SVaultBootstrapObserve :: SCapability 'VaultBootstrapObserve
  SVaultBootstrapMutate :: SCapability 'VaultBootstrapMutate
  SVaultBaselineReconcile :: SCapability 'VaultBaselineReconcile
  SVaultPkiOperate :: SCapability 'VaultPkiOperate
  SLifecycleObserve :: SCapability 'LifecycleObserve
  SLifecycleCasReadBack :: SCapability 'LifecycleCasReadBack
  SLifecycleSubmit :: SCapability 'LifecycleSubmit
  SLifecycleCancel :: SCapability 'LifecycleCancel
  SAuthorityEpochCutover :: SCapability 'AuthorityEpochCutover
  SAuthorityDecommissionExport :: SCapability 'AuthorityDecommissionExport
  SAuthorityBackupEstablish :: SCapability 'AuthorityBackupEstablish
  SAuthorityBackupRepair :: SCapability 'AuthorityBackupRepair
  SAuthorityBackupGenesisCleanup :: SCapability 'AuthorityBackupGenesisCleanup
  SCredentialProvisionReadBack :: SCapability 'CredentialProvisionReadBack
  SAdminActionReadBack :: SCapability 'AdminActionReadBack
  SAuthorityBackupCommitReadBack :: SCapability 'AuthorityBackupCommitReadBack
  STlsRetentionCommitReadBack :: SCapability 'TlsRetentionCommitReadBack
  STlsEnvelopeKeyExchange :: SCapability 'TlsEnvelopeKeyExchange
  STlsRestoreDeliverReadBack :: SCapability 'TlsRestoreDeliverReadBack
  STlsSecretObserve :: SCapability 'TlsSecretObserve
  STlsSecretSeal :: SCapability 'TlsSecretSeal
  STlsSecretMaterializeReadBack :: SCapability 'TlsSecretMaterializeReadBack
  SRetainedMaterialCustodyObserve :: SCapability 'RetainedMaterialCustodyObserve
  SRetainedMaterialCustodySealReadBack :: SCapability 'RetainedMaterialCustodySealReadBack
  SRetainedMaterialCustodyRewrapReadBack :: SCapability 'RetainedMaterialCustodyRewrapReadBack
  SRetainedMaterialTargetMaterializeReadBack
    :: SCapability 'RetainedMaterialTargetMaterializeReadBack
  SRetainedMaterialCustodyTombstoneReadBack
    :: SCapability 'RetainedMaterialCustodyTombstoneReadBack
  SConfigObserve :: SCapability 'ConfigObserve
  SConfigProposeCas :: SCapability 'ConfigProposeCas
  SOperatorMaterialSubmit :: SCapability 'OperatorMaterialSubmit
  STargetSecretObserve :: SCapability 'TargetSecretObserve
  STargetSecretSeal :: SCapability 'TargetSecretSeal
  STargetSecretProvisionSeal :: SCapability 'TargetSecretProvisionSeal
  STargetSecretCasReadBack :: SCapability 'TargetSecretCasReadBack
  STargetSecretReceiptGcReadBack :: SCapability 'TargetSecretReceiptGcReadBack
  STargetSecretDecommissionTombstoneReadBack
    :: SCapability 'TargetSecretDecommissionTombstoneReadBack
  SChildRecoveryCustody :: SCapability 'ChildRecoveryCustody
  SChildRecoveryDeliver :: SCapability 'ChildRecoveryDeliver
  SGatewayPeerExchange :: SCapability 'GatewayPeerExchange
  SGatewayEmitterRetire :: SCapability 'GatewayEmitterRetire
  SGatewayDnsReconcileReadBack :: SCapability 'GatewayDnsReconcileReadBack
  SRegistryPublishReadBack :: SCapability 'RegistryPublishReadBack
  SProviderApplyReadBack :: SCapability 'ProviderApplyReadBack
  SManagedResourceObserve :: SCapability 'ManagedResourceObserve
  SManagedResourceEnsureReadBack :: SCapability 'ManagedResourceEnsureReadBack
  SManagedResourceDestroyReadBack :: SCapability 'ManagedResourceDestroyReadBack

data CapabilityRef (kind :: CapabilityKind) = CapabilityRef
  { capabilityService :: ServiceIdentity
  , capabilityScope :: AuthorityScope
  , capabilityCoordinate :: CapabilityCoordinate kind
  , capabilityBindingDigest :: CapabilityBindingDigest
  }
```

Constructors remain private. Smart constructors validate service identity, substrate, authority
epoch, transport binding, and coordinate bounds before returning a `CapabilityRef kind`.
`LongLivedCheckpointAuthority` becomes an authority identity and object namespace; it does not
contain a gateway URL. `TargetSecretSink` becomes a substrate identity and allowlisted KV
coordinate; it does not contain a transport URL. `TargetClusterSecretSink` is the pre-cutover type
name and is removed rather than retained as an alias.

The same-reference rule is per requested `CapabilityProgram`. A program carries only operation
payload; the exact target coordinate lives once, in `CapabilityRef`. `runCapability` hashes the
kind, binding, and canonical payload, admits that exact request digest, and executes it through the
same private client/session/queue. The resulting ticket binds the capability-binding digest and
request digest, so it cannot be replayed for another coordinate or payload. A `*Observe` kind is a
read-only diagnostic/recovery authority and can never be reused as proof that a different mutation
kind is admissible. A mutation constructor owns any required domain pre-observation, conditional
effect, and mandatory read-back inside its operation boundary; callers cannot splice an
observation from one reference into execution on another.

This is the minimum closed operation universe for the target control plane and component graph,
not an illustrative subset. Adding a supported operation requires a new kind, singleton,
compatible program constructor, provider mapping, exhaustive tests, policy entry, and doctrine
update in the same change. A generic HTTP, Vault, MinIO, AWS, or subprocess escape constructor is
forbidden.

### 3.2 Programs are data

Requests are a closed GADT interpreted only at the effect boundary:

```haskell
-- Example: target shape for src/Prodbox/ControlPlane/Program.hs
data MutationClass
  = TargetSealMutation
  | TargetGenerationMutation
  | TargetSealReceiptGcMutation
  | ChildCustodyMutation
  | ChildRecoveryDeliveryMutation
  | EmitterRetirementMutation
  | GatewayDnsMutation
  | RegistryPublicationMutation
  | TlsRetentionMutation
  | TlsRestoreMaterializationMutation
  | RetainedMaterialCustodyMutation
  | RetainedMaterialDeliveryMutation
  | RetainedMaterialCustodyTombstoneMutation
  | ProviderMutation
  | ManagedResourceEnsureMutation
  | ManagedResourceDestroyMutation

data CommittedIntentRef (mutation :: MutationClass)
data AuthorityWriterPermit

data OperatorMaterialIngressSchema
  = AwsAdminProvisioningIngress
  | ExternalAcmeEabIngress

data SOperatorMaterialIngressSchema
  (schema :: OperatorMaterialIngressSchema) where
  SAwsAdminProvisioningIngress
    :: SOperatorMaterialIngressSchema 'AwsAdminProvisioningIngress
  SExternalAcmeEabIngress
    :: SOperatorMaterialIngressSchema 'ExternalAcmeEabIngress

data OperatorMaterialPermit (schema :: OperatorMaterialIngressSchema)

data CredentialProvisionMode
  = GenesisBackupProvision
  | GenesisCleanupProvision
  | BackupRepairProvision
  | OperatorMaterialProvision OperatorMaterialIngressSchema

data CredentialProvisionPermit (mode :: CredentialProvisionMode) where
  GenesisBackupProvisionPermit
    :: GenesisBackupPermit
    -> CredentialProvisionPermit 'GenesisBackupProvision
  GenesisCleanupProvisionPermit
    :: GenesisCleanupPermit
    -> CredentialProvisionPermit 'GenesisCleanupProvision
  RepairProvisionPermit
    :: RepairPermit
    -> CredentialProvisionPermit 'BackupRepairProvision
  OperatorMaterialProvisionPermit
    :: OperatorMaterialPermit schema
    -> CredentialProvisionPermit ('OperatorMaterialProvision schema)

data AdminAction
  = DestroyAwsSes
  | MigrateLegacyBackend
  | UseRetainedBucketCompatibility
  | ReconcileAwsQuotaRequest

data AdminActionPermit (action :: AdminAction)

type family AdminActionResult (action :: AdminAction) where
  AdminActionResult 'DestroyAwsSes = AwsSesAndSmtpDestroyReadBack
  AdminActionResult 'MigrateLegacyBackend = LegacyMigrationReadBack
  AdminActionResult 'UseRetainedBucketCompatibility = CompatibilityActionReadBack
  AdminActionResult 'ReconcileAwsQuotaRequest =
    (AwsQuotaRequestIdentity, AwsQuotaStatusReadBack)

data DestroyStageResult readBack
  = DestroyStageCompleted readBack
  | DestroyStageFailed AdminDestroyFailure
  | DestroyStageBlocked DependencyBlockedReason

data AwsSesAndSmtpDestroyReadBack = AwsSesAndSmtpDestroyReadBack
  { smtpConsumersStopped :: DestroyStageResult ConsumerAbsenceReadBack
  , smtpIamFamilyAbsent :: DestroyStageResult SmtpIamFamilyAbsenceReadBack
  , nonCredentialSesS3Absent :: DestroyStageResult SesS3FamilyAbsenceReadBack
  , smtpTargetGenerationsAbsent
      :: BoundedTargetMap (DestroyStageResult TargetDecommissionTombstoneReadBack)
  , smtpCustodyAbsent :: DestroyStageResult RetainedMaterialAbsenceReadBack
  }

data RetainedMaterialSchema
  = SesSmtpMaterial
  | AcmeEabMaterial

data SRetainedMaterialSchema (schema :: RetainedMaterialSchema) where
  SSesSmtpMaterial :: SRetainedMaterialSchema 'SesSmtpMaterial
  SAcmeEabMaterial :: SRetainedMaterialSchema 'AcmeEabMaterial

type family IngressSchemaFor
  (schema :: RetainedMaterialSchema) :: OperatorMaterialIngressSchema where
  IngressSchemaFor 'SesSmtpMaterial = 'AwsAdminProvisioningIngress
  IngressSchemaFor 'AcmeEabMaterial = 'ExternalAcmeEabIngress

data RetainedMaterialPermit (schema :: RetainedMaterialSchema)
data RetainedMaterialReceiptRef (schema :: RetainedMaterialSchema)

data RetainedMaterialCustodyTombstoneProof
  (schema :: RetainedMaterialSchema) where
  RetireSupersededRetainedMaterial
    :: CommittedIntentRef 'RetainedMaterialCustodyTombstoneMutation
    -> RetainedMaterialCustodyTombstoneProof schema
  DestroySesSmtpCustody
    :: AdminActionPermit 'DestroyAwsSes
    -> RetainedMaterialCustodyTombstoneProof 'SesSmtpMaterial
  DecommissionSesSmtpCustodyProof
    :: VerifiedDecommissionPermit 'DecommissionSesSmtpCustody
    -> RetainedMaterialCustodyTombstoneProof 'SesSmtpMaterial
  DecommissionAcmeEabCustodyProof
    :: VerifiedDecommissionPermit 'DecommissionAcmeEabCustody
    -> RetainedMaterialCustodyTombstoneProof 'AcmeEabMaterial

data RetainedMaterialCustodyObservation
  (schema :: RetainedMaterialSchema)
  = RetainedMaterialCustodyPresent (RetainedMaterialSealReceipt schema)
  | RetainedMaterialCustodyPositivelyAbsent RetainedMaterialAbsenceReadBack
  | RetainedMaterialCustodyCorrupt RetainedMaterialCorruption
  | RetainedMaterialCustodyDigestMismatch ExpectedDigest ObservedDigest
  | RetainedMaterialCustodyUnobservable RetainedMaterialObservationFailure

data DecommissionProgramTag
  = DecommissionRegisteredManagedResource
  | DecommissionTargetVaultGeneration
  | DecommissionSesSmtpCustody
  | DecommissionAcmeEabCustody
  | DecommissionTlsRetentionTail
  | DecommissionAuthorityBackupTail

data VerifiedDecommissionPermit (tag :: DecommissionProgramTag)

data DecommissionProgram (tag :: DecommissionProgramTag) result where
  DestroyRegisteredManagedResource
    :: VerifiedDecommissionPermit 'DecommissionRegisteredManagedResource
    -> DecommissionProgram
         'DecommissionRegisteredManagedResource
         ManagedResourceDestroyResult
  TombstoneRegisteredTargetVaultGeneration
    :: VerifiedDecommissionPermit 'DecommissionTargetVaultGeneration
    -> DecommissionProgram
         'DecommissionTargetVaultGeneration
         TargetDecommissionTombstoneReadBack
  TombstoneDecommissionSesSmtpCustody
    :: VerifiedDecommissionPermit 'DecommissionSesSmtpCustody
    -> DecommissionProgram
         'DecommissionSesSmtpCustody
         RetainedMaterialAbsenceReadBack
  TombstoneDecommissionAcmeEabCustody
    :: VerifiedDecommissionPermit 'DecommissionAcmeEabCustody
    -> DecommissionProgram
         'DecommissionAcmeEabCustody
         RetainedMaterialAbsenceReadBack
  DeleteRegisteredTlsRetentionTail
    :: VerifiedDecommissionPermit 'DecommissionTlsRetentionTail
    -> DecommissionProgram
         'DecommissionTlsRetentionTail
         TlsRetentionDecommissionReadBack
  DeleteRegisteredAuthorityBackupTail
    :: VerifiedDecommissionPermit 'DecommissionAuthorityBackupTail
    -> DecommissionProgram
         'DecommissionAuthorityBackupTail
         AuthorityBackupDecommissionReadBack

data CapabilityProgram (kind :: CapabilityKind) result where
  ObserveProcessService
    :: CapabilityProgram 'ProcessServiceActive ServiceObservation
  ObserveKubernetesWorkload
    :: CapabilityProgram 'KubernetesWorkloadAvailable WorkloadObservation
  ObserveKubernetesOperator
    :: CapabilityProgram 'KubernetesOperatorAvailable OperatorObservation
  ObserveVaultBootstrap
    :: CapabilityProgram 'VaultBootstrapObserve VaultBootstrapObservation
  EnsureVaultInitialized
    :: VaultInitializeRequest
    -> CapabilityProgram 'VaultBootstrapMutate VaultInitializeResult
  EnsureVaultUnsealed
    :: VaultUnsealRequest
    -> CapabilityProgram 'VaultBootstrapMutate VaultUnsealResult
  SealVault
    :: VaultSealRequest
    -> CapabilityProgram 'VaultBootstrapMutate VaultSealResult
  RotateVaultUnlockBundle
    :: UnlockBundleRotation
    -> CapabilityProgram 'VaultBootstrapMutate UnlockBundleRotationResult
  RotateVaultTransitKey
    :: TransitKeyRotation
    -> CapabilityProgram 'VaultBootstrapMutate TransitKeyRotationResult
  RecoverAmbiguousVaultInitialization
    :: PristineStorageResetProof
    -> CapabilityProgram 'VaultBootstrapMutate VaultInitializeResult
  ReconcileVaultBaseline
    :: VaultBaselineRequest
    -> CapabilityProgram 'VaultBaselineReconcile VaultBaselineResult
  RunVaultPkiOperation
    :: VaultPkiRequest
    -> CapabilityProgram 'VaultPkiOperate VaultPkiResult
  ObserveLifecycleRecord
    :: CapabilityProgram 'LifecycleObserve LifecycleObservation
  CompareAndSwapLifecycleRecord
    :: AuthorityWriterPermit
    -> LifecycleCas
    -> CapabilityProgram 'LifecycleCasReadBack LifecycleCasResult
  SubmitLifecycleOperation
    :: OperationRequest
    -> CapabilityProgram 'LifecycleSubmit OperationAccepted
  CancelLifecycleOperation
    :: OperationCancellation
    -> CapabilityProgram 'LifecycleCancel OperationCancellationResult
  CutoverAuthorityEpoch
    :: AuthorityCutoverRequest
    -> CapabilityProgram 'AuthorityEpochCutover AuthorityCutoverResult
  ExportAuthorityDecommission
    :: DecommissionExportRequest
    -> CapabilityProgram 'AuthorityDecommissionExport DecommissionExportResult
  EstablishAuthorityBackup
    :: AuthorityBackupGenesisRequest
    -> CapabilityProgram 'AuthorityBackupEstablish GenesisBackupPermit
  BeginAuthorityBackupRepair
    :: PositivePermanentBackupLoss
    -> AuthorityBackupRepairRequest
    -> CapabilityProgram 'AuthorityBackupRepair RepairPermit
  BeginAuthorityBackupGenesisCleanup
    :: GenesisCleanupRequest
    -> CapabilityProgram 'AuthorityBackupGenesisCleanup GenesisCleanupPermit
  RunCredentialProvisioner
    :: CredentialProvisionPermit mode
    -> CapabilityProgram 'CredentialProvisionReadBack (CredentialProvisionResult mode)
  RunAdminAction
    :: AdminActionPermit action
    -> CapabilityProgram 'AdminActionReadBack (AdminActionResult action)
  ReconcileAuthorityBackup
    :: AuthorityWriterPermit
    -> AuthorityBackupProgram
    -> CapabilityProgram 'AuthorityBackupCommitReadBack AuthorityBackupResult
  RetainTlsCiphertext
    :: CommittedIntentRef 'TlsRetentionMutation
    -> TlsSealedEnvelopeBytes
    -> CapabilityProgram 'TlsRetentionCommitReadBack TlsRetentionReadBack
  IssueTlsEnvelopeDek
    :: CommittedIntentRef 'TlsRetentionMutation
    -> SelectedAgentAttestation
    -> CapabilityProgram 'TlsEnvelopeKeyExchange EncryptedDekForSelectedAgent
  RewrapTlsEnvelopeDek
    :: CommittedIntentRef 'TlsRestoreMaterializationMutation
    -> WrappedHomeTransitDek
    -> SelectedAgentAttestation
    -> CapabilityProgram 'TlsEnvelopeKeyExchange EncryptedDekForSelectedAgent
  RestoreTlsCiphertext
    :: CommittedIntentRef 'TlsRestoreMaterializationMutation
    -> TlsRestoreRequest
    -> CapabilityProgram 'TlsRestoreDeliverReadBack TlsRestoreObservation
  ObserveTlsSecret
    :: CapabilityProgram 'TlsSecretObserve TlsSecretObservation
  SealTlsSecret
    :: CommittedIntentRef 'TlsRetentionMutation
    -> EncryptedDekForSelectedAgent
    -> TlsSealMetadata
    -> CapabilityProgram 'TlsSecretSeal TlsSealedEnvelopeBytes
  MaterializeTlsSecret
    :: CommittedIntentRef 'TlsRestoreMaterializationMutation
    -> TlsRestoreEnvelopeBytes
    -> EncryptedDekForSelectedAgent
    -> TlsTargetCas
    -> CapabilityProgram 'TlsSecretMaterializeReadBack TlsTargetReadBack
  ObserveRetainedMaterialCustody
    :: RetainedMaterialReceiptRef schema
    -> CapabilityProgram
         'RetainedMaterialCustodyObserve
         (RetainedMaterialCustodyObservation schema)
  SealRetainedMaterialCustody
    :: RetainedMaterialPermit schema
    -> RetainedMaterialIngressMetadata schema
    -> CapabilityProgram
         'RetainedMaterialCustodySealReadBack
         (RetainedMaterialSealReceipt schema)
  RewrapRetainedMaterialForTarget
    :: CommittedIntentRef 'RetainedMaterialDeliveryMutation
    -> RetainedMaterialReceiptRef schema
    -> SelectedAgentAttestation
    -> CapabilityProgram
         'RetainedMaterialCustodyRewrapReadBack
         (RetainedMaterialTargetEnvelope schema)
  MaterializeRetainedMaterialTarget
    :: CommittedIntentRef 'RetainedMaterialDeliveryMutation
    -> RetainedMaterialTargetEnvelope schema
    -> RetainedMaterialTargetCas schema
    -> CapabilityProgram
         'RetainedMaterialTargetMaterializeReadBack
         (RetainedMaterialTargetReadBack schema)
  TombstoneRetainedMaterialCustody
    :: RetainedMaterialCustodyTombstoneProof schema
    -> RetainedMaterialReceiptRef schema
    -> CapabilityProgram
         'RetainedMaterialCustodyTombstoneReadBack
         RetainedMaterialAbsenceReadBack
  ObserveInForceConfig
    :: CapabilityProgram 'ConfigObserve ConfigObservation
  ProposeInForceConfig
    :: ConfigProposal
    -> CapabilityProgram 'ConfigProposeCas ConfigCasResult
  SubmitOperatorMaterial
    :: OperatorMaterialRequest
    -> CapabilityProgram 'OperatorMaterialSubmit OperationAccepted
  ObserveOperatorMaterialPermit
    :: OperationId
    -> CapabilityProgram 'OperatorMaterialSubmit OperatorMaterialPermitObservation
  ObserveTargetGeneration
    :: CapabilityProgram 'TargetSecretObserve TargetObservation
  SealTargetPayload
    :: CommittedIntentRef 'TargetSealMutation
    -> TargetSealMetadata
    -> CapabilityProgram 'TargetSecretSeal TargetSealReceipt
  ObserveTargetSealReceipt
    :: TargetSealReceiptKey
    -> CapabilityProgram 'TargetSecretSeal TargetSealObservation
  ConsumeProvisionedCredential
    :: CredentialProvisionPermit mode
    -> ProvisionedCredentialIngressMetadata mode
    -> CapabilityProgram 'TargetSecretProvisionSeal (CredentialSealReceipt mode)
  DisableGenesisSealArm
    :: GenesisBackupPermitRef
    -> BackupCommitReceiptRef
    -> CapabilityProgram 'TargetSecretProvisionSeal GenesisDisableReadBack
  CompareAndSwapTargetGeneration
    :: CommittedIntentRef 'TargetGenerationMutation
    -> TargetSealReceiptRef
    -> TargetCas
    -> CapabilityProgram 'TargetSecretCasReadBack TargetCasResult
  GarbageCollectTargetSealReceipt
    :: CommittedIntentRef 'TargetSealReceiptGcMutation
    -> TargetSealReceiptRef
    -> CapabilityProgram 'TargetSecretReceiptGcReadBack TargetSealReceiptGcReadBack
  ExecuteTargetDecommissionTombstone
    :: VerifiedDecommissionPermit 'DecommissionTargetVaultGeneration
    -> CapabilityProgram
         'TargetSecretDecommissionTombstoneReadBack
         TargetDecommissionTombstoneReadBack
  CommitChildRecoveryCustody
    :: CommittedIntentRef 'ChildCustodyMutation
    -> ChildCustodyCas
    -> CapabilityProgram 'ChildRecoveryCustody ChildCustodyResult
  DeliverChildRecoveryShares
    :: CommittedIntentRef 'ChildRecoveryDeliveryMutation
    -> ChildRecoveryDeliveryRequest
    -> CapabilityProgram 'ChildRecoveryDeliver ChildRecoveryDeliveryResult
  ObserveChildRecoveryDelivery
    :: ChildRecoveryDeliveryKey
    -> CapabilityProgram 'ChildRecoveryDeliver ChildRecoveryDeliveryObservation
  ExchangeGatewayPeerFrame
    :: GatewayPeerFrame
    -> CapabilityProgram 'GatewayPeerExchange GatewayPeerResult
  RetireGatewayEmitter
    :: CommittedIntentRef 'EmitterRetirementMutation
    -> EmitterRetirementRequest
    -> CapabilityProgram 'GatewayEmitterRetire EmitterRetirementResult
  ReconcileGatewayDnsRecord
    :: CommittedIntentRef 'GatewayDnsMutation
    -> GatewayDnsIntent
    -> CapabilityProgram 'GatewayDnsReconcileReadBack GatewayDnsResult
  PublishRegistryBlob
    :: CommittedIntentRef 'RegistryPublicationMutation
    -> RegistryPublishIntent
    -> CapabilityProgram 'RegistryPublishReadBack RegistryPublishResult
  ApplyProviderIntent
    :: CommittedIntentRef 'ProviderMutation
    -> ProviderPayload
    -> CapabilityProgram 'ProviderApplyReadBack ProviderApplyResult
  ObserveManagedResource
    :: CapabilityProgram 'ManagedResourceObserve ManagedResourceObservation
  ReconcileManagedResourcePresent
    :: CommittedIntentRef 'ManagedResourceEnsureMutation
    -> CapabilityProgram 'ManagedResourceEnsureReadBack ManagedResourceEnsureResult
  ReconcileManagedResourceAbsent
    :: CommittedIntentRef 'ManagedResourceDestroyMutation
    -> CapabilityProgram 'ManagedResourceDestroyReadBack ManagedResourceDestroyResult
```

The separate `DecommissionProgram` is equally closed and exhaustive. Its permit constructor is
private and can be projected only by verifying the exported manifest, external receipt, compiled
registry digest, exact registered coordinate, dependency node, and action tag. The target-tombstone
constructor delegates to `ExecuteTargetDecommissionTombstone` on the still-live selected Agent;
every remaining constructor resolves only its tag-indexed registry coordinate. No constructor
accepts a URL, command, bucket/prefix, Vault path, AWS request, shell fragment, or caller-selected
coordinate, and there is no generic decommission escape interpreter.

The GADT indexes operation legality; it does not claim ownership of externally authoritative
state. Every `CapabilityProgram` value is canonically serializable and secret-free. Prompt bytes,
newly returned access-key bytes, plaintext DEKs, and decrypted payloads are never constructor
fields and therefore never enter request hashing, journals, `Show`, logs, or retry serialization.
After validating and hashing the permit/program, a runner interpreter separately acquires an opaque
linear prompt or credential-ingress handle whose type has no `Show`, `Eq`, serialization, or
duplication instance. The handle is consumed in the one-shot boundary and cannot be returned to the
pure layer. `TargetSealMetadata` and `ProvisionedCredentialIngressMetadata` contain only
IDs/schema/bounds; the corresponding plaintext arrives over that separate authenticated
linear ingress. `VaultInitializeRequest` and `VaultUnsealRequest` likewise contain only transaction,
storage-generation, schema, and bound metadata. After program validation, only the verified
one-shot Broker secret worker for that request acquires operator-password/share bytes through its
separate linear ingress; the long-lived Broker controller receives metadata and typed receipts
only.

`OperatorMaterialPermit schema` and its one-shot ingress are schema-indexed. A private smart
projection can construct `RetainedMaterialPermit schema` only when the permit schema equals
`IngressSchemaFor schema`. `AwsAdminProvisioningIngress` carries a bounded AWS administrator frame
that can authorize only deterministic registered identity/key work; it is not operator-material
content. `ExternalAcmeEabIngress` carries the externally supplied EAB key ID/HMAC frame (or its
test-only fixture projection) and authorizes no AWS administrator action. A Job/session cannot
change schemas, and the first-reconcile AWS-admin plan contains no EAB member. `prodbox config
setup` remains secret-free and non-mutating.

Unkeyed secret hashes are forbidden control-plane data. `SecretCommitment` has a private
constructor and is produced only inside the Target Agent by an exact Vault keyed-HMAC operation
domain-separated by `(operation ID, action index, target schema, target generation)`. The Agent
persists it inside the sealed receipt and exposes only an opaque `SecretCommitmentRef`; Authority,
Provisioner, and clients never receive an unkeyed secret hash. Duplicate same-ID
comparison recomputes and compares the commitment inside the Agent receipt fold and returns only
same/refuse, preventing an offline equality oracle.

`AuthorityWriterPermit` and `CommittedIntentRef` constructors are private. A committed-intent
reference binds its authenticated issuer, operation ID, action index, durable commit-receipt digest,
current authority or emitter epoch, writer/mutation fence, action digest, capability-binding digest,
deadline, target generation when applicable, idempotency key, and the required durable
`CleanupObligationRef` for validation-owned work. Every external mutation above
requires either that proof, the Bootstrap Broker's storage-generation-bound bootstrap permit, or a
signed one-time indexed `CredentialProvisionPermit`, except the explicitly separate
`AdminActionPermit` and verified post-export `DecommissionProgram` families below.
`GenesisBackupPermit` is accepted only while `GenesisFrozen`; `GenesisCleanupPermit` is accepted
only by a new frozen Authority after positive primary-loss classification and binds the old permit,
signed Agent marker, complete deterministic cleanup inventory, storage generations, Job
attestation, and expiry; `RepairPermit` is accepted only while `BackupRepairFrozen`; and
`OperatorMaterialPermit` is projected only from a normally backup-receipted operator-material
intent. None can be converted to another mode or projected into a Pulumi/provider, DNS-record,
registry, config, or ordinary target-delivery proof.

`AdminActionPermit action` is a disjoint proof family projected only from a normal
primary/backup-receipted explicit admin operation. It binds the closed action tag, stable operation
ID, exact registered coordinates/request identity, Job attestation, inventory/status precondition,
and deadline; it is not a `CredentialProvisionPermit` and is invalid after decommission export.
For `DestroyAwsSes`, the registered coordinates and result cover both the non-credential SES/S3
provider family and the SMTP IAM identity/policy/access-key family, including authoritative
absence read-back for each. No other admin action may delete that credential family.
Interpreters verify the receipt against their owning durable journal, authenticate the issuer, and
reject a stale epoch/fence before any effect; transport possession cannot forge provider, target,
DNS, registry, emitter-retirement, or managed-resource authority. External observations and records
remain flat exhaustive ADTs, as required by
[Pure Functional Programming Standards](./pure_fp_standards.md#gadt-indexed-state-machines).

`AuthorityBackupProgram` is an authority-internal closed sum: prepare canonical envelope, put/read
back content-addressed blob, commit/read back transition receipt, observe restore set, and fenced
delete/read back an already GC-approved blob. It cannot carry an arbitrary bucket/key, generic S3
request, provider action, or credential. Its private interpreter resolves only
`CapabilityRef 'AuthorityBackupCommitReadBack` to the separate Authority Backup Adapter. That
Deployment has its own ServiceAccount, NetworkPolicy, resource envelope, bounded queue, Vault role,
and managed session for `secret/aws/authority-backup-store`; core Authority sends typed ciphertext
bytes/digests
and receives typed read-back receipts, never the AWS credential.

`TlsRetentionProgram` is separately closed over `retain ciphertext bytes/read-back`, `observe exact
version/digest`, and `return restore ciphertext bytes plus read-back receipt`; its coordinate comes only from
`CapabilityRef 'TlsRetentionCommitReadBack` or `CapabilityRef 'TlsRestoreDeliverReadBack` and is
fixed to `public-edge-tls/<substrate>/<fqdn>`. Its interpreter is the TLS Retention Adapter, whose
only secret is `secret/aws/tls-retention-store`. The Adapter cannot decrypt certificate/key bytes,
address the Authority-backup prefix, construct provider requests, or call a target directly.
Authority commits the bounded retention/restore outbox; cross-substrate selection and delivery are
therefore Authority decisions and never Gateway routing. `TlsSealedEnvelopeBytes` and
`TlsRestoreEnvelopeBytes` are bounded digest-bound values containing certificate ciphertext,
home-Transit-wrapped DEK bytes, and validated metadata. Authority explicitly transports those bytes
between the exact Agent and Adapter programs; an object reference from either disjoint store is
never treated as if the other boundary could dereference it.

No `ComponentReadinessTarget`-style value stores
`IO (Either Text ReadinessProbeResult)`. The interpreter is injected separately:

```haskell
-- Example: target shape for src/Prodbox/ControlPlane/Interpreter.hs
runCapability
  :: Monad m
  => CapabilityClient m
  -> CapabilityRef kind
  -> Deadline
  -> CapabilityProgram kind result
  -> m (Either CapabilityFailure result)
```

### 3.3 Capability requirements in the component graph

The component graph carries existentially wrapped requirements as pure data:

```haskell
-- Example: target shape for src/Prodbox/Config/ComponentGraph.hs
data CapabilityRequirement (kind :: CapabilityKind) = CapabilityRequirement
  { requiredService :: ServiceIdentity
  , requiredScope :: AuthorityScope
  , requiredCoordinate :: CapabilityCoordinate kind
  , requiredLatencyBudget :: LatencyBudget
  }

data SomeCapabilityRequirement where
  SomeCapabilityRequirement
    :: SCapability kind
    -> CapabilityRequirement kind
    -> SomeCapabilityRequirement
```

Graph validation proves that a consumer requests an exact operation from the intended service and
scope. Runtime reconnaissance resolves that requirement into the corresponding opaque reference.
The same reference is then used for admission and execution. Readiness details and graph ownership
are canonical in [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md).

## 4. Absolute Deadline and Admission Algebra

Relative nested timeouts are forbidden on supported control-plane paths. The boundary creates one
monotonic absolute `Deadline`; every step consumes its remaining budget.

```haskell
-- Example: target shape for src/Prodbox/ControlPlane/Deadline.hs
newtype Deadline = Deadline MonotonicInstant

data DeadlineObservation
  = DeadlineOpen RemainingDuration
  | DeadlineExpired

data AdmissionObservation kind
  = Admitted (AdmissionTicket kind)
  | AdmissionSaturated RetryAfter
  | AdmissionDegraded CapabilityDegradation
  | AdmissionDeadlineExpired
  | AdmissionUnobservable ObservationFailure
```

An admission ticket is bound to the service identity, capability kind, authority epoch, queue
generation, deadline, capability-binding digest, and canonical request digest. It is short-lived
admission evidence, not proof that external state will remain healthy indefinitely. Admission and
execution are one private interpreter call; callers never receive a ticket they can pair with a
different program.

Long-running lifecycle work does not use a point precheck followed by an unrelated call. The
caller submits an idempotent `OperationRequest`; admission, journaling, and execution occur under
one Lifecycle Authority identity. A repeated submission with the same `OperationId` returns the
same durable operation result.

The submission deadline and the durable operation lifetime are different typed values. Submission,
status observation, cancellation, and each worker attempt have their own non-resettable absolute
request deadline. The accepted operation stores an `OperationDeadline` and stage deadlines in
authority time; restart, retry, or a new observer cannot extend them. A submit call returns after
durable acceptance rather than holding a transport open for provider propagation. Later bounded
observe calls return the current durable state, and cancellation is an idempotent authority command.
Before an interpreter may run an attempt, it converts the stored stage deadline into the local
monotonic domain with the same trusted clock sample used for admission. The conversion subtracts
the sample's upper uncertainty bound, never its midpoint: `remaining = stageDeadline -
(observedAuthorityTime + uncertainty)`. A non-positive result is expired. Otherwise the boundary
adds that remaining duration to the sampled monotonic instant and takes the earlier of that derived
deadline and the request deadline. The conversion is pure, cannot add uncertainty or retry time,
and is repeated from a fresh trusted sample before every attempt.

Request time and durable authority time are distinct. `Deadline` is process-local and monotonic;
it is never serialized. Durable `OperationDeadline` values use a serializable `AuthorityInstant`
obtained from a validated synchronized clock observation. The aggregate stores the greatest
accepted instant. A new leader refuses time-sensitive admission when its clock is unobservable,
outside the documented uncertainty bound, or behind that high-water mark. Downtime therefore
counts against an operation deadline, and a restart cannot reset it. Recovery/cancellation may
record the clock fault, but no successor mutation is admitted until time is trustworthy again.

```haskell
-- Example: target shape for src/Prodbox/Lifecycle/Authority/Time.hs
data AuthorityClockObservation
  = AuthorityTimeTrusted AuthorityInstant ClockUncertainty
  | AuthorityTimeRegressed AuthorityInstant AuthorityInstant
  | AuthorityTimeUnobservable ClockFailure

deriveAttemptDeadline
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> OperationDeadline
  -> Either AttemptDeadlineRefusal Deadline
```

`deriveAttemptDeadline` accepts only `AuthorityTimeTrusted` within the configured uncertainty
bound. This makes the comparison between serialized authority time and process-local monotonic time
an explicit, conservative boundary rather than an implicit comparison between unlike clocks.

**Landed (Sprint `1.62`, 2026-07-18).** This algebra is realized across two disjoint modules. The
process-local monotonic layer is `src/Prodbox/ControlPlane/Deadline.hs`: `Deadline` is opaque and
its only builder consumes a raw monotonic instant plus a budget, `tightenDeadline` is `min`, and
child scopes are minted only through the opaque `DeadlineScope` (`narrowScope`/`narrowScopeToBudget`,
both `min`-against-parent) — so a child can never outlive or extend its parent; deadline extension is
unrepresentable, not merely discouraged. The durable, serializable layer is
`src/Prodbox/ControlPlane/AuthorityClock.hs`: `AuthorityInstant` reuses `Lease.AuthorityTime`
(serialized through its `Natural` projection, no orphan instance); a monotone `AuthorityClockHighWater`
only ever advances; `classifyAuthorityClock` is fail-closed (a reading below the high-water mark is
`AuthorityTimeRegressed`, one wider than the skew bound is `AuthorityTimeUnobservable`); and a stored
`OperationDeadline` is an absolute authority instant whose reload is the identity, so
`deriveAttemptDeadline` charges downtime against the same absolute deadline (remaining = deadline −
(now + uncertainty), only ever shrinking) and cannot be reset by a restart or a rolled-back clock.
The refusal/regression/restart tables are in `test/unit/ControlPlaneAuthorityClock.hs` and the
tighten-only cancellation properties in `test/unit/ControlPlaneDeadline.hs`.

## 5. Lifecycle Authority Aggregate

### 5.0 Closing the backup bootstrap cycle

Normal authority transitions require the independent backup identity, so that identity cannot be
created by pretending the normal receipt rule already holds. A new or migrated authority starts in
`GenesisFrozen`. The Bootstrap Broker baseline first creates the non-exportable Ed25519 Transit key
`transit/keys/prodbox-authority-genesis-signing`, pins its public-key generation into the home
Target Secret Agent trust document, grants Authority only the exact Transit sign endpoint, and
grants neither workload access to the signing private key. Its only exceptional Authority mutation
is `EstablishAuthorityBackup`; raw operator-admin bytes never enter Authority:

```haskell
data AuthorityGenesisState
  = GenesisFrozen GenesisObservation
  | GenesisIntentCommitted AuthorityBackupGenesisIntent GenesisBackupPermitRef
  | GenesisProvisionObserved GenesisProvisioningReadBack GenesisSealReceipt
  | GenesisBackupReadBack AuthorityBackupInitialReadBack
  | BackupEstablished AuthorityBackupGeneration BackupCommitReceipt
  | GenesisPermanentlyDisabled
      AuthorityBackupGeneration
      GenesisDisableReadBack
      FirstReconcileSessionState

data RetainedFirstReconcileSession = RetainedFirstReconcileSession
  { retainedPlanDigest :: FirstReconcileProvisioningPlanDigest
  , retainedNextMember :: FirstReconcilePlanMember
  , retainedPriorReceipt :: FirstReconcilePriorReceipt
  , retainedDeadline :: AbsoluteSessionDeadline
  , retainedHeartbeat :: HostHeartbeatObservation
  , retainedJobAttestation :: CredentialProvisionerJobAttestation
  , retainedAttachWitness :: AuthenticatedAttachWitness
  }

data FirstReconcileSessionState
  = FirstReconcileSessionAbsent
  | FirstReconcileGenesisSessionActive RetainedFirstReconcileSession
  | FirstReconcileGenesisRevoked RetainedFirstReconcileSession
  | FirstReconcileSessionClosed SessionRevocationReadBack JobAbsenceReadBack

data GenesisSealMarkerObservation
  = GenesisSealMarkerPositivelyAbsent SignedAgentAbsenceReadBack
  | GenesisSealMarkerConsumed SignedGenesisConsumedMarker
  | GenesisSealMarkerCorrupt GenesisSealMarkerCorruption
  | GenesisSealMarkerUnobservable GenesisSealMarkerObservationFailure

data GenesisCleanupEvidence
  = GenesisCleanupFromAbsence
      ReconstructedGenesisIntent
      LostAuthorityStorageGeneration
      RegisteredGenesisOwnership
      SignedAgentAbsenceReadBack
  | GenesisCleanupFromConsumed
      ReconstructedGenesisIntent
      LostAuthorityStorageGeneration
      RegisteredGenesisOwnership
      SignedGenesisConsumedMarker

decideGenesis
  :: AuthorityGenesisState
  -> AuthorityGenesisObservation
  -> AuthorityGenesisCommand
  -> Either AuthorityGenesisRefusal (NonEmpty AuthorityGenesisEvent)
```

The bounded transaction is:

1. validate deterministic bucket/prefix, IAM identity/path/policy, target Vault coordinate, and
   primary envelope/blob inventory; CAS-journal that complete genesis intent and cleanup manifest in
   the retained primary store before AWS mutation;
2. after primary CAS read-back, ask Transit to sign a one-time `GenesisBackupPermit` binding the Authority
   service identity and signing-key generation, Provisioner ServiceAccount/image binding, home
   Agent identity and exact `secret/aws/authority-backup-store` path, primary storage generation,
   nonce and intent digest, deterministic bucket/prefix/IAM/policy/Adapter coordinates, the exact
   `FirstReconcileProvisioningPlan` digest, and absolute expiry. Authority stores and returns only
   the permit/reference;
3. create a separately resourced Credential Provisioner Job, then verify its Pod UID, immutable image
   digest, ServiceAccount, and permit binding. The operator CLI or automation harness sends the
   bounded prompt bytes only over authenticated Kubernetes `pods/exec` stdin or attach to that
   verified Pod. They are never placed in argv, environment, ConfigMap, Secret, filesystem, event,
   status, or log. The Job bounds and `mlock`s its owned input buffer, disables core dumps, redacts
   all errors, and returns only a signed typed receipt after each permitted action. On the normal
   path it retains the linear session only while every field of `RetainedFirstReconcileSession`
   re-observes valid. On disconnect, restart, Pod loss, failed attestation, heartbeat loss, deadline,
   plan-cursor mismatch, or final-member completion it revokes the session, best-effort zeroizes
   owned mutable buffers, exits, and is deletion-read-back. Process/Pod termination is the
   enforceable isolation boundary; no claim is made that Haskell, SDK, TLS, or GC copies were
   byte-erased;
4. the Job uses that in-memory admin session to execute only the permit's deterministic S3/IAM
   create/observe/delete/remint algebra. It observes the finite key inventory before creation; an
   applied-but-response-lost key is deleted, observed stably absent, and reminted rather than
   blindly retried. It then presents the permit, its verified workload attestation, and the new
   backup credential directly to the home Agent over the permit-bound channel;
5. the Agent verifies Transit signature/key generation, expiry, Authority and Provisioner
   attestations, primary generation, nonce/intent digest, target identity/path, and deterministic
   AWS/Adapter coordinates. In one CAS/read-back at
   `secret/prodbox/control-plane/authority-backup-permits/<permit-digest>`, it changes absence to a
   consumed marker containing an Agent-internal opaque `SecretCommitment` and ciphertext-only seal
   receipt, then
   generation-CAS materializes `secret/aws/authority-backup-store`. Exact replay returns the same
   receipt; nonce, digest, path, generation, attestation, or expiry mismatch refuses before mutation;
6. have the separately deployed Adapter authenticate its managed session with that generation, then
   run the closed `AuthorityBackupCommitReadBack` program to copy and
   read back the complete canonical initial envelope plus every current immutable blob into the
   long-lived backup prefix, and write the prepared `BackupEstablished` transition;
7. CAS the primary to `BackupEstablished`, write/read back its backup commit receipt, and have the
   Agent CAS the consumed marker to `Disabled <backup-receipt-digest>` with read-back. Transition
   to `GenesisPermanentlyDisabled`; this permanently revokes only the genesis signing/Agent arm and
   projects normal admission open. If the compiled plan has no remaining member, close and delete
   the Job now. Otherwise the pure fold may project `FirstReconcileGenesisRevoked` only from the
   exact plan digest, next member, durable prior receipt, unexpired deadline, current heartbeat,
   unchanged Job attestation, and authenticated attach witness. That retained value grants no
   mutation and cannot reconstruct genesis authority;
8. for each remaining plan member, first commit and backup-read-back its distinct
   `OperatorMaterialPermit`, execute only that exact member, durably read back its receipt, and
   advance the cursor. Any failed session proof closes the Job before a later fresh prompt resumes
   the same committed member/inventory. After the final member receipt, revoke the session,
   best-effort zeroize owned buffers, exit, and prove Job/Pod absence before platform/application
   deployment.

No provider, DNS, suite, config-update, or ordinary outbox effect is admitted in genesis. The
normal Provider Worker has no admitted endpoint. Exec/attach disconnect, Job restart, or Pod loss
loses the bytes and requires a re-prompt, but recovery resumes the same permit and deterministic
inventory; it does not create a new operation or blindly create another key. Exact Agent replay
recovers a consumed receipt. An expired, unused permit may be superseded only by a newly
primary-CAS-read-back permit for the same intent after deterministic inventory observation.

If the primary store is lost before the first `BackupEstablished` receipt, recovery cannot infer
completion from AWS success. A new frozen Authority reconstructs the deterministic Tier-0 intent,
lost Authority/storage generation, exact ownership tags/coordinates, and a flat signed
`GenesisSealMarkerObservation`. `BeginAuthorityBackupGenesisCleanup` can return a signed
`GenesisCleanupPermit` only from `GenesisCleanupEvidence`: positive Agent absence binds the
reconstructed intent/generation/ownership evidence and does not require the permit nonce or digest
that may have existed only in the lost primary; a valid consumed marker additionally binds its
recorded permit digest and target receipt. Corrupt or unobservable marker state refuses cleanup.
The permit binds which case was proved plus the complete deterministic AWS inventory. Under a fresh
prompt, a new Provisioner Job accepts only
`GenesisCleanupProvisionPermit`, deletes and reads back the prefix/key/identity (and the bucket only
when the manifest proves this genesis created it and no other registered prefix exists). In the
consumed case only, the Agent then tombstones/read-backs the consumed marker and target generation;
positive absence has no target mutation to invent. The cleanup Job revokes its session and is
observed absent before genesis restarts. Thus the exceptional primary-only journal can leave only
exact registered, operator-recoverable resources; it cannot authorize production work.

Genesis AWS resources are created with the reconstructable intent digest, lost storage/authority
generation, and exact managed-owner tags wherever AWS supports tags; access keys are confined to
the deterministically named/tagged IAM identity and finite inventory. Cleanup runs under a distinct
greater recovery fence, re-observes every ownership/generation predicate immediately before each
conditional delete, and refuses a missing, newer, or mismatched owner. A new genesis attempt cannot
create or adopt the same coordinate until cleanup absence is read back and the recovery fence is
closed. A later epoch therefore cannot be deleted merely because it reused a deterministic name.

### 5.0.1 Permanent backup loss repair

Post-genesis backup observation is a total classification:

```haskell
data BackupAvailability
  = BackupHealthy AuthorityBackupGeneration BackupCommitReceipt
  | BackupTemporarilyUnavailable RetryAfter
  | BackupPermanentlyAbsent PositiveAbsenceProof
  | BackupPolicyDrift PositivePolicyDriftProof

data BackupRepairState
  = BackupRepairFrozen PositivePermanentBackupLoss
  | BackupRepairIntentCommitted AuthorityBackupRepairIntent RepairPermitRef
  | BackupRepairProvisionObserved RepairProvisioningReadBack RepairSealReceipt
  | BackupRepairFullCopyReadBack AuthorityBackupInitialReadBack
  | BackupRepairReceiptCommitted AuthorityBackupGeneration BackupCommitReceipt
  | BackupRepairEpochOpened AuthorityEpoch

data BackupAvailabilityDecision
  = ContinueWithBackup AuthorityBackupGeneration BackupCommitReceipt
  | WaitForBackup RetryAfter
  | FreezeForRepair PositivePermanentBackupLoss

decideBackupAvailability :: BackupAvailability -> BackupAvailabilityDecision
```

Timeout, network failure, throttling, and otherwise unobservable state are
`BackupTemporarilyUnavailable`: new receipt-requiring transitions wait/refuse without performing
effects, and no primary-only repair intent is legal. Only authoritative key/bucket absence or a
positive exact-policy drift proof constructs `PositivePermanentBackupLoss`. Authority then CASes
`BackupRepairFrozen` in primary storage; this is the sole post-genesis primary-only exception and
immediately freezes all normal external effects.

The frozen Authority primary-CASes a deterministic repair intent and uses the same Transit trust to
sign a one-time `RepairPermit` binding the current and proposed greater epoch, current primary
generation, next `LongLived` credential generation, loss proof, nonce/intent digest, Provisioner
attestation, exact target path, deterministic AWS/Adapter coordinates, and expiry. A fresh
ephemeral Provisioner Job obtains a fresh admin prompt through the verified exec/attach protocol,
exactly recreates or rotates the store/identity/policy with finite-inventory
observe/delete/remint recovery, and hands the permit plus credential directly to the Agent. The
Agent's distinct repair arm accepts only the strictly next generation, CAS-consumes the permit and
seal receipt, and delivers/read-backs that generation; the permanently disabled genesis arm stays
disabled.

The Adapter then full-copies and digest-read-backs the current Authority envelope and every
referenced blob and writes the first new backup receipt. Authority re-observes that receipt, cuts to
the permit's strictly greater epoch while frozen, promotes Agent/Adapter bindings, and opens normal
admission only after every promotion is read back. Crash, response loss, permit replay, expiry, and
partial AWS residue resume by the same repair intent and deterministic inventory; no ordinary
provider/DNS/config/suite effect is legal until the greater-epoch open. Loss of primary storage
while the only backup is permanently absent remains outside the recovery claim.

### 5.1 External authority uses `decide` and `evolve`

The authority record is externally durable and may be observed by a replacement replica. It is a
flat ADT with total pure transitions, not a GADT pretending that an in-process command made a
remote transition happen.

```haskell
-- Example: target shape for src/Prodbox/Lifecycle/Authority/Model.hs
data RetainedMaterialTargetDeliveryState
  (schema :: RetainedMaterialSchema)
  = RetainedMaterialTargetPending
      TargetId
      MaterialGeneration
      RetainedMaterialDeliveryIntentRef
  | RetainedMaterialTargetWorkerBound
      TargetId
      MaterialGeneration
      SelectedAgentAttestation
      WorkerSessionNonce
      AbsoluteSessionDeadline
  | RetainedMaterialTargetEnvelopeReadBack
      TargetId
      MaterialGeneration
      SelectedAgentAttestation
      WorkerSessionNonce
      AbsoluteSessionDeadline
      (RetainedMaterialTargetEnvelope schema)
  | RetainedMaterialTargetCommitted
      TargetId
      MaterialGeneration
      (RetainedMaterialTargetReadBack schema)
  | RetainedMaterialTargetTombstoned
      TargetId
      MaterialGeneration
      TargetDecommissionTombstoneReadBack

data RetainedMaterialGenerationState
  (schema :: RetainedMaterialSchema)
  = RetainedMaterialSealPending
      MaterialGeneration
      RetainedMaterialSealIntentRef
  | RetainedMaterialSealReadBack
      MaterialGeneration
      (RetainedMaterialReceiptRef schema)
      (RetainedMaterialSealReceipt schema)
  | RetainedMaterialCurrent
      MaterialGeneration
      (RetainedMaterialReceiptRef schema)
      (BoundedTargetMap (RetainedMaterialTargetDeliveryState schema))
  | RetainedMaterialSuperseded
      MaterialGeneration
      (RetainedMaterialReceiptRef schema)
      MaterialGeneration
      RetainedMaterialRetentionDeadline
      (BoundedTargetMap (RetainedMaterialTargetRetirementEvidence schema))
      BoundedConsumerRetirementEvidence
  | RetainedMaterialTombstonePending
      MaterialGeneration
      (RetainedMaterialReceiptRef schema)
      RetainedMaterialCustodyTombstoneReason
  | RetainedMaterialTombstoned
      MaterialGeneration
      RetainedMaterialAbsenceReadBack

data SomeRetainedMaterialGenerationState where
  SomeRetainedMaterialGenerationState
    :: SRetainedMaterialSchema schema
    -> RetainedMaterialGenerationState schema
    -> SomeRetainedMaterialGenerationState

data AuthorityCommand
  = ReserveClientSubmission RegisteredClientSlot ClientSubmissionKey RequestDigest
  | BeginOperation OperationRequest
  | RequestOperationCancellation OperationId CancellationReason
  | BeginAuthorityCutover AuthorityCutoverRequest
  | BeginAuthorityDecommission DecommissionExportRequest
  | RecordDecommissionExported DecommissionManifestRef ExternalReceiptReadBack
  | FreezeForBackupRepair PositivePermanentBackupLoss
  | CommitBackupRepairIntent AuthorityBackupRepairIntent
  | RecordBackupRepairProvisioned RepairProvisioningReadBack RepairSealReceipt
  | RecordBackupRepairFullCopy AuthorityBackupInitialReadBack
  | OpenBackupRepairEpoch AuthorityEpoch BackupCommitReceipt
  | CommitExternalIntent OperationId ActionIndex FenceToken ExternalIntent
  | ProposeConfigGeneration OperationId ExpectedConfigGeneration ConfigBlobCandidate
  | RecordPendingBlob OperationId FenceToken PendingBlobRef
  | PromoteBlobReference OperationId FenceToken PendingBlobRef BlobReadBack
  | BeginBlobGc OperationId ExpectedGcEpoch
  | RecordBlobGcScan OperationId GcFence BlobGcScanReceipt
  | CompleteBlobGc OperationId GcFence BlobDeletionReadBack
  | RecordProviderApplied OperationId FenceToken ProviderRevision BlobRef
  | RecordProviderReady OperationId FenceToken ProviderRevision
  | RecordTargetSealReceipt OperationId FenceToken TargetSealReceipt
  | RecordCredentialGeneration OperationId FenceToken CredentialGeneration SecretCommitmentRef
  | RecordTargetDelivered OperationId FenceToken TargetId CredentialGeneration TargetVersion
  | BeginRetainedMaterialSeal OperationId FenceToken SomeRetainedMaterialSealCandidate
  | RecordRetainedMaterialSealed OperationId FenceToken SomeRetainedMaterialSealReadBack
  | PromoteRetainedMaterialCurrent OperationId FenceToken SomeRetainedMaterialCurrentRef
  | BeginRetainedMaterialTargetDelivery
      OperationId FenceToken SomeRetainedMaterialTargetDelivery
  | RecordRetainedMaterialTargetDelivered
      OperationId FenceToken SomeRetainedMaterialTargetReadBack
  | InvalidateRetainedMaterialTargetEnvelope
      OperationId FenceToken SomeRetainedMaterialWorkerLoss
  | MarkRetainedMaterialSuperseded
      OperationId FenceToken SomeRetainedMaterialSupersession
  | BeginRetainedMaterialTombstone
      OperationId FenceToken SomeRetainedMaterialTombstone
  | RecordRetainedMaterialTombstoned
      OperationId FenceToken SomeRetainedMaterialAbsenceReadBack
  | BeginTlsRetention OperationId FenceToken TlsRetentionCandidate
  | RecordTlsRetentionPut OperationId FenceToken TlsObjectReadBack
  | PromoteTlsRetentionCurrent OperationId FenceToken TlsSourceSecretReadBack
  | BeginTlsRestore OperationId FenceToken TlsRetentionCurrentRef
  | RecordTlsMaterialized OperationId FenceToken TlsTargetReadBack
  | RecordChildCustodyDelivered OperationId FenceToken ChildId CustodyGeneration TargetVersion
  | RecordChildRecoveryDelivery OperationId FenceToken ChildRecoveryDeliveryObservation
  | RecordOperationFailed OperationId FenceToken OperationFailure
  | CloseOperation OperationId FenceToken CloseDisposition

data AuthorityEvent
  = ClientSubmissionReserved ClientReservation
  | OperationStarted OperationRecord
  | OperationCancellationRequested CancellationRecord
  | AuthorityCutoverStarted AuthorityCutoverState
  | AuthorityDecommissionStarted DecommissionState
  | AuthorityDecommissionExported DecommissionState
  | AuthorityBackupRepairFrozen BackupRepairState
  | AuthorityBackupRepairIntentCommitted BackupRepairState
  | AuthorityBackupRepairProvisioned BackupRepairState
  | AuthorityBackupRepairCopied BackupRepairState
  | AuthorityBackupRepairEpochOpened BackupRepairState
  | ExternalIntentCommitted ExternalIntentState
  | ConfigGenerationCommitted ConfigState
  | BlobReferencePending PendingBlobState
  | BlobReferencePromoted BlobRef
  | BlobGcStarted BlobGcState
  | BlobGcScanRecorded BlobGcState
  | BlobGcCompleted BlobGcResult
  | ProviderApplied ProviderState
  | ProviderBecameReady ProviderRevision
  | TargetSealReceiptCommitted TargetSealState
  | CredentialGenerationCommitted CredentialState
  | TargetDeliveryCommitted TargetDeliveryState
  | RetainedMaterialSealStarted SomeRetainedMaterialGenerationState
  | RetainedMaterialSealCommitted SomeRetainedMaterialGenerationState
  | RetainedMaterialCurrentPromoted SomeRetainedMaterialGenerationState
  | RetainedMaterialTargetDeliveryStarted SomeRetainedMaterialGenerationState
  | RetainedMaterialTargetDeliveryCommitted SomeRetainedMaterialGenerationState
  | RetainedMaterialTargetRewrapRequired SomeRetainedMaterialGenerationState
  | RetainedMaterialGenerationSuperseded SomeRetainedMaterialGenerationState
  | RetainedMaterialTombstoneStarted SomeRetainedMaterialGenerationState
  | RetainedMaterialTombstoneCommitted SomeRetainedMaterialGenerationState
  | TlsRetentionPending TlsRetentionState
  | TlsRetentionPutReadBack TlsRetentionState
  | TlsRetentionCurrentPromoted TlsRetentionCurrentRef
  | TlsRestoreStarted TlsRestoreState
  | TlsMaterializationCommitted TlsRestoreState
  | ChildCustodyCommitted ChildCustodyState
  | ChildRecoveryDeliveryCommitted ChildRecoveryState
  | OperationFailed OperationFailure
  | OperationClosed CloseDisposition

data RecordedAuthorityEvent = RecordedAuthorityEvent
  { acceptedAuthorityTime :: AcceptedAuthorityTime
  , authorityEvent :: AuthorityEvent
  }

decide
  :: AuthorityClockObservation
  -> AuthorityState
  -> AuthorityCommand
  -> Either AuthorityRefusal (NonEmpty RecordedAuthorityEvent)

evolve :: AuthorityState -> RecordedAuthorityEvent -> AuthorityState
```

Every constructor is handled explicitly. Time is an explicit observed input rather than hidden IO,
and every accepted event serializes the validated instant/uncertainty used by the decision. Replay
therefore advances the high-water mark from recorded data without re-reading a clock. Duplicate
commands are idempotent by operation ID, request digest, fence, provider revision, credential
generation, and target generation.

The retained-material fold is schema-total. It admits exactly one pending seal per
`(schema,generation)`, promotes a current reference only after exact custody seal/read-back, and
admits target delivery only from that current receipt to a registered target whose attestation,
schema, generation, path, and expected prior version match. Response loss resumes from the same
custody or target read-back. A source generation may become `RetainedMaterialSuperseded` only after
its successor is current; it remains readable while any target delivery, rebuild, rollback window,
or outbox references it. Retirement requires the retention deadline plus a complete reference scan.
Explicit teardown first proves external/consumer absence, then records every target-generation
tombstone, and only then may begin the source-custody tombstone while the home Agent/Vault remain
live. An absent, corrupt, digest-mismatched, or unobservable source never authorizes remint,
issuance, target deletion, or promotion.

A target envelope is encrypted to one ephemeral selected-worker key and is not durable recovery
material by itself. Its state binds the exact attestation, worker-session nonce, and absolute
deadline. Worker/Pod/session loss, attestation change, or expiry discards that envelope and evolves
back to the same committed delivery intent as `RetainedMaterialTargetRewrapRequired`; recovery
obtains a fresh attestation and asks home custody to rewrap again. It never attempts to materialize
persisted ciphertext for a missing worker. A superseded source retains bounded per-target and
consumer-retirement evidence (not just a deadline); source tombstone additionally requires the
complete proven-no-dependants scan.

`CommitExternalIntent` does not make its proof usable immediately. Only after the evolved envelope
and outbox are CAS-current and their independent backup commit receipt is read back may the private
proof projector sign `CommittedIntentRef` with that receipt digest and action index. Recovery
reconstructs the same proof from the receipt-committed envelope; no request handler can mint one
from an in-memory plan or an unreceipted prepare.

### 5.2 One CAS aggregate and immutable blobs

One bounded `AuthorityEnvelope` contains:

- authority epoch and trusted serializable authority-time high-water mark;
- backup availability and the optional bounded `BackupRepairState`;
- active mutation fence and clean/ambiguous close disposition;
- provider revision and semantic readiness state;
- in-force config schema version, generation, digest, and immutable blob reference;
- committed SMTP credential generation and opaque Agent commitment reference;
- the closed SMTP/EAB retained-material ledgers: pending seals, current receipt refs, bounded
  per-target envelope/materialization read-backs, superseded generations, retention deadlines, and
  tombstone/absence receipts;
- encrypted operator-material generations and delivery intents;
- bounded per-target delivery states;
- bounded per-`(substrate,FQDN)` TLS pending/current immutable-version states;
- bounded seal-receipt and child-recovery-delivery states;
- durable outbox intents and their attempt/result state;
- bounded active operation records plus terminal idempotency tombstones;
- a fixed-capacity registered-client table with generation-scoped cursors and submission
  reservations;
- pending/current/retired immutable-blob references plus durable GC scan/delete receipts;
- references to immutable content-addressed checkpoint blobs.

Large Pulumi checkpoint bytes are immutable encrypted blobs. The aggregate CAS references their
digest; it does not rewrite them on every workflow transition. `AuthorityPrimaryStore` and
`AuthorityBackupStore` are separately registered, independently credentialed failure-domain
coordinates; configuration validation rejects an alias to the same bucket, volume, storage device,
or availability domain. Blob publication is a receipt-backed protocol:

1. commit a fenced `PendingBlobRef` plus a typed reconstruction source in the aggregate and backup
   receipt;
2. write the exact encrypted ciphertext under its content address to both stores and read back its
   bytes/digest from each;
3. CAS-promote only the pair of verified primary/backup blob references to current; and
4. discard the reconstruction source only after promotion is receipt-committed.

A bounded config proposal is encrypted in the prepared operation input; a provider checkpoint is
reconstructable only from the fenced provider export/read-back named by its operation; a target seal
uses the agent's durable sealed receipt. If the declared reconstruction source is absent or
unobservable after a crash, promotion refuses with a typed nonterminal recovery state. It never
manufactures a reference to missing bytes.

Every authority-namespace object coordinate and CAS adapter is durability-indexed by
`StoreLifetime` — `ChartLifetime`, `ClusterRetained`, or `CrossClusterDurable` — and smart
constructors partition the object namespaces by lifetime class. A retained-or-stronger object
addressed through a chart-lifetime transport is unrepresentable rather than merely forbidden.

> **Implementation status (2026-07-14, Sprint `4.51`)**: Increment A landed the phantom
> `StoreLifetime` index on the Model-B coordinate / request / adapter types with a `nominal` role and
> the full-name-tagging constructors, plus the compile + byte-erasure witness. A lease guard is
> monomorphically `'ClusterRetained'` (not lifetime-indexed) — a lease is always retained — which
> lets a `'ChartLifetime'` checkpoint be guarded by a retained lease. The clause above becomes true in
> production once Increment B retypes the gateway transport to `'ChartLifetime'`-only and cuts the
> retained consumers over to the host-direct `'ClusterRetained'` adapter.

Garbage collection persists its candidate set and both complete scan receipts in the aggregate.
Its GC fence is mutually exclusive with `RecordPendingBlob` and promotion. After the declared grace,
the interpreter re-observes the current aggregate and latest receipt-committed backup envelope under
that same fence immediately before deletion. It may delete a blob from both stores only when the
digest is absent from every pending/current/retained/reconstruction/result set in both observations;
it read-backs absence in both stores and CAS-commits a deletion receipt before releasing the fence.
A writer therefore cannot add a pending reference between the final reference check and deletion.
A transition that changes the permit, provider revision, credential generation, or outbox commits
atomically in the one aggregate.

Operation-ID idempotency is explicitly bounded without permitting reuse after compaction.
`OperationId` contains authority epoch, registered client slot/generation, authority-CAS-allocated
client sequence, and request-digest binding. The fixed client slots and maximum reservations per
slot are part of validated Tier-0 capacity; an arbitrary transport principal cannot allocate a new
map entry. Client retirement advances the slot generation and retains its old sequence floor, so a
reused slot cannot revive an old ID.

Before submission, a client durably records a bounded `ClientSubmissionKey` and request digest in
its declared cursor authority: a service-local retained journal, the suite's durable `CleanupRun`,
or the registered CLI client-recovery journal. The Lifecycle Authority CAS-reserves the next
sequence for that key; duplicate reserve/submit returns the same ID, while a digest mismatch
refuses. The aggregate retains per-slot high-water/floor plus terminal
`(OperationId, request digest, TerminalProjectionOrBlobRef, result digest, closed-at)` tombstones for
the configured `IdempotencyWindow`; nonterminal operations are never evicted. Capacity is derived
from maximum admitted rate times that window, including client reservations, and saturation refuses
new work. A sequence at or below the compacted floor without a tombstone returns
`OperationIdExpired`; it can never become a fresh mutation. Terminal lookup can return the same
bounded projection or immutable result blob, not merely a digest that cannot satisfy the original
query.

The interpreter performs:

1. observe and decode the versioned envelope;
2. run `decide` purely;
3. write and read back an encrypted backup `PreparedTransition` containing the prior version,
   canonical evolved envelope bytes, event/outbox digests, and verified backup-blob references;
4. CAS the primary envelope to that transition digest; on conflict, mark the prepare abandoned,
   re-observe, and re-run `decide`;
5. write and read back the backup commit receipt for the successful primary version;
6. execute only an outbox intent whose commit receipt is durable;
7. re-observe the external result; and
8. submit its fenced completion through the same prepare/CAS/receipt protocol.

A store loss with a prepare but no receipt is safe ambiguity: no external effect was admitted from
that transition, so recovery discards or re-decides it under a greater epoch. A receipt contains the
exact encrypted envelope bytes; every promoted/current blob reference names ciphertext already read
back from the independent backup store, while an unpromoted pending reference retains its typed
reconstruction source and cannot become current during restore. Recovery freezes every writer,
restores that envelope and each current blob, verifies all digests, re-observes pending/external
effects, and only then activates a strictly greater epoch. An absent current backup blob is a hard
recovery failure, never a dangling restored reference. This
is explicit primary-MinIO recovery under the retained Vault/Transit/backup-custody preconditions in
§1, not recovery from total `.data`/Vault loss and not an unsupported claim that one home volume is
physically HA.

Transport ambiguity therefore leaves a queryable operation and intent state. Release is a
latency optimization; correctness comes from the durable fence, close disposition, and recovery
rules.

Cancellation records intent; it does not erase an in-flight effect or assume that a timed-out
provider call did nothing. The recovery worker first resolves any ambiguous intent by operation ID
and read-back, then either advances the compensating/cleanup plan or commits a canceled close.

### 5.3 In-force configuration and operator material

The Lifecycle Authority starts from a bounded Tier-0 boot projection containing only its service
identity, Vault/primary-MinIO coordinates, the exact Authority Backup Adapter capability reference,
trust roots, and authority scope. Core Authority never decodes an S3 credential or constructs an AWS
client. After Vault baseline
provisioning it owns the post-unseal in-force configuration capability.

`ConfigObservation` distinguishes missing, observed generation/digest/schema, corrupt, and
unobservable. A proposal is decoded and validated purely, encrypted as a new immutable blob, read
back, and then installed by CAS against the exact observed config generation in the authority
aggregate. Components observe role-scoped projections through `ConfigObserve`; they never fetch
the blob from MinIO directly and never receive another role's secret references. An absent config
requires a visible seed proposal from operator-authored Tier 0. It is not an ambient fallback.
`GenesisFrozen` and `BackupRepairFrozen` refuse that proposal; the cluster plan submits it only
after the genesis marker is permanently disabled and normal admission has opened.

`OperatorMaterialRequest` is a closed install/rotate/revoke ADT over the registered provider,
SMTP IAM identity/policy/access-key family, Gateway DNS, cert-manager DNS01, TLS-retention, and ACME
EAB material classes, plus rotation-only Authority-backup-store material after genesis. Backup
establishment, permanent-loss repair, and final revocation remain the special protocols in
§5.0/§5.0.1/§11.1. For an admin-minted identity or key, Authority first commits and
backup-read-backs the exact program, deterministic inventory,
selected Agent/path, credential generation, Job attestation, and deadline, then signs a one-time
schema-indexed `OperatorMaterialPermit`. Only the Credential Provisioner accepts that permit and
its matching linear ingress. AWS-minted material goes directly to its named Agent; for SMTP the
Provisioner first derives `SesSmtpSource` and sends only that closed payload to retained-home
custody. ACME EAB requires a different Job and `ExternalAcmeEabIngress` frame. Core Authority,
Provider Worker, Authority Backup Adapter, and TLS Retention Adapter receive only typed
observations, seal receipts, and target read-backs.

During first reconcile, the already attested Job may retain the same bounded mlocked prompt buffer
across `BackupEstablished` only while its original absolute deadline, Pod UID/image digest/SA
binding, authenticated attach, host heartbeat, and Genesis-permit-bound
`FirstReconcileProvisioningPlan` digest all remain valid. Each normal action must be the next
unconsumed exact member, prove the durable prior-member receipt, and still requires a distinct
backup-receipted `OperatorMaterialPermit 'AwsAdminProvisioningIngress` binding that member
index/digest; the provisioning plan itself grants no action and
`GenesisBackupPermit` conveys no normal power. A
disconnect, restart, heartbeat loss, or deadline expiry invalidates the session, best-effort
zeroizes owned mutable buffers, terminates the Pod, and later re-prompts while reusing the committed
permit and finite inventory. After setup, the reconciler verifies session revocation, process exit,
and Job/Pod absence—not byte erasure of possible library/runtime copies. The retained session
cannot accept an EAB permit/frame. Any later rotation or external-material ingress starts a new
schema-bound Job and fresh prompt. The selected Agent
generation-CAS/read-backs each materialized secret, and revocation completes only after the
corresponding external identity/key and Vault generation are authoritatively observed. The
pre-cutover host/gateway operator-write routes and shared AWS KV path are deleted.

Explicit admin-prompted operations use a different one-shot Admin Action Runner. Authority first
commits and backup-read-backs one `AdminActionPermit` for exactly one of: registered `aws-ses`
destroy, legacy backend migration, retained-bucket compatibility, or `aws quotas request`.
`DestroyAwsSes` alone binds both the non-credential SES/S3 provider inventory and the SMTP IAM
identity/policy/access-key inventory and completes only after every registered resource is read back
absent. The Job
is verified by Pod UID/image digest/ServiceAccount/permit binding and receives bounded prompt bytes
only through authenticated exec/attach stdin under the same no-argv/env/ConfigMap/Secret/disk/log,
bounded-lifetime, session-revocation, best-effort owned-buffer-zeroization, and Pod-deletion
read-back rules as the Credential Provisioner. It resumes by stable operation ID plus authoritative
inventory/read-back, never by a new host-direct prompt mutation. Quota submission records the exact
service/quota/region/desired-value request identity and provider request ID, and remains queryable
until authoritative status read-back. Response loss resumes by the same client token/request
identity; later one-shot Jobs may obtain a fresh prompt to observe that exact request but can never
resubmit it or widen the quota coordinate. Core Authority sees typed receipts/status only. The normal
Provider Worker cannot accept an admin permit, and total `nuke` continues to use the distinct
post-export Decommission Runner after Authority stops.

AWS access-key creation is treated as a non-idempotent external effect, not an ordinary retry. The
authority commits a create intent before the Credential Provisioner call and records the finite
key-inventory observation. Credential Provisioner is the sole access-key create/rotate/remint and
repair-time deletion interpreter; the only other key-deletion authority is Admin Action Runner for
the registered SMTP family under exact `DestroyAwsSes`. Provider Worker may only use an already
sealed/read-back Lifecycle-provider generation.
If creation applies but its one-time secret response is lost before target sealing, that key is
unrecoverable: recovery observes its key ID, deletes it under the same identity fence, waits for
stable absence, and only then commits a new create attempt. A successful response is sealed by the
named Agent before the authority commits the credential generation and delivery outbox; SMTP is
first derived to `SesSmtpSource` and sealed by retained-home custody. If the seal response alone is
lost, the Agent's ciphertext receipt recovers it and the key is not reminted.
No retry may blindly create a second key, and no uncommitted key may survive a closed operation.

### 5.4 Retained TLS envelope workflow

TLS retention uses the retained home trust root, never an ephemeral AWS Vault. Bootstrap baseline
creates the non-exportable home Transit key `transit/keys/prodbox-tls-envelope`; only the home
Target Secret Agent's envelope endpoint may request data-key generation or unwrap. The TLS
Retention Adapter sees no Transit token, DEK, certificate plaintext, or private-key plaintext.

For retention after issuance or renewal:

1. Authority commits a bounded retention intent naming the selected substrate, FQDN, exact TLS
   Secret identity/resource version, selected-Agent attestation, and exact
   `public-edge-tls/<substrate>/<fqdn>` coordinate.
2. Under narrow exact-Secret Kubernetes RBAC, the selected substrate Agent starts a one-shot
   secret worker, reads and validates the certificate/key pair, and sends its attested ephemeral
   public key through the Authority-routed intent to the home Agent.
3. The retained home Agent's dedicated TLS-envelope lane starts its own one-shot bounded worker,
   asks retained-home Transit for a fresh plaintext/wrapped DEK pair, and encrypts the plaintext DEK
   to that selected worker's attested public key. Its Vault policy names only
   `prodbox-tls-envelope`; it may briefly see a DEK but can never read a certificate Secret.
   Authority sees only the wrapped DEK, encrypted-to-Agent DEK, attestations, and typed receipt. The
   selected worker decrypts the DEK and encrypts the bounded certificate/key bytes locally.
4. Authority receipt-commits a retention outbox containing only certificate ciphertext, the
   home-Transit-wrapped DEK, certificate/FQDN/expiry metadata, and digests. The TLS Retention Adapter
   receives those exact bounded envelope bytes from Authority, writes that exact object/version,
   reads back bytes and digest, and returns a typed receipt before Authority closes the transition.

Once operator-configurable certificate scope sets land (Sprint
[`2.35`](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md)), the
`public-edge-tls/<substrate>/<fqdn>` coordinate generalizes to a canonical scope-set
serialization key: the exact-prefix TLS-retention IAM contract and per-`(substrate, scope-key)`
serialization are restated over that canonical key, so the retained coordinate stays a total
projection of the one configured scope set rather than a hand-chosen FQDN.

Retention is serialized by the exact `(substrate, FQDN)` key in the Authority aggregate. One
fenced candidate at a time binds the Secret UID/resourceVersion, certificate serial,
`notBefore`/`notAfter`, public-key SPKI fingerprint, selected-Agent attestation, ciphertext digest,
wrapped-DEK digest, and an Authority-CAS sequence. Kubernetes `resourceVersion` is treated as an
opaque equality witness, not parsed as an integer. A candidate must be re-observed as the current
exact Secret immediately before promotion; UID replacement needs an explicit recreate intent,
`notBefore`/`notAfter` regression refuses, and a different SPKI requires an explicit key-rotation
intent rather than being mistaken for renewal.

The Adapter writes immutable versioned objects. Authority first records `TlsRetentionPending`, then
accepts only a byte-for-byte/digest read-back for that candidate's exact object version, re-observes
the source Secret equality witness, and CAS-promotes one `TlsRetentionCurrentRef`. A late or
out-of-order receipt whose sequence/fence is not pending cannot replace current. Applied-but-
response-lost put is recovered by exact object version/digest observation under the same operation;
it is never uploaded again under a new operation. Restore names the receipt-committed current ref
and exact immutable version—not S3 `latest`, list order, or a caller-selected key.

For restore before issuance, Authority commits an exact restore intent and
`RestoreTlsCiphertext` returns one flat Adapter observation: exact present bytes/read-back,
authoritative positive absence, corrupt bytes, digest mismatch, or unobservability. The Adapter does
not classify certificate time. A newly attested selected Agent worker supplies a fresh ephemeral
public key; only after the pure Authority-time decision selects materialization does the home Agent
Transit-unwrap the DEK and re-encrypt it to that key. Authority passes the exact bounded envelope
bytes and encrypted DEK to the selected Agent's TLS-materialize capability. The selected worker
decrypts/validates the retained certificate locally, generation-CAS applies the exact TLS Secret,
and reads back resource version plus opaque Agent commitment before cert-manager may issue. Every
restore outcome follows the total decision below; none becomes an ambient fallback:

```haskell
data TlsRestoreObservation
  = TlsRestorePresent TlsRestoreEnvelopeBytes TlsObjectReadBack
  | TlsRestorePositivelyAbsent TlsObjectAbsenceReadBack
  | TlsRestoreCorrupt TlsCorruption
  | TlsRestoreDigestMismatch ExpectedDigest ObservedDigest
  | TlsRestoreUnobservable TlsRestoreFailure

data TlsRestoreRefusal
  = TlsRestoreNotYetValid CertificateNotBefore AuthorityInstant ClockUncertainty
  | TlsRestoreValidityBoundaryAmbiguous CertificateValidity AuthorityInstant ClockUncertainty
  | TlsRestoreAuthorityTimeRefused AuthorityClockObservation
  | TlsRestoreCorruptRefusal TlsCorruption
  | TlsRestoreDigestMismatchRefusal ExpectedDigest ObservedDigest
  | TlsRestoreUnobservableRefusal TlsRestoreFailure

data TlsRestoreDecision
  = MaterializeRetainedTls TlsRestoreEnvelopeBytes
  | CommitIssuanceAfterAbsence TlsObjectAbsenceReadBack
  | CommitIssuanceAfterExpiry ValidatedExpiry
  | RefuseTlsRestore TlsRestoreRefusal

decideTlsRestore
  :: AuthorityClockObservation
  -> TlsRestoreObservation
  -> TlsRestoreDecision
```

For `TlsRestorePresent`, the pure fold reads the authenticated validity metadata from the envelope
and accepts a time conclusion only from `AuthorityTimeTrusted`. Its conservative interval is
`[now - uncertainty, now + uncertainty]`: materialization requires the whole interval to lie within
the certificate validity window, and expiry requires the whole interval to lie after `notAfter`.
A certificate whose `notBefore` is still in the future, a clock interval crossing either validity
boundary, regressed/unobservable Authority time, corrupt bytes, digest mismatch, or unobservable
store, credential, Adapter, home key lane, selected Agent, target CAS, or read-back always refuses.
Only positive authoritative absence or trusted-time proven expiry can become a separately
primary/backup-receipted issuance intent; none of the refused cases is normalized to missing or
silently reissued.

The enforceable erasure boundary is the one-shot worker process/Pod: no swap, core dump, persistent
volume, argv, environment, ConfigMap, Secret transport, or plaintext logging; bounded lifetime and
memory; revocation of its session; and Pod deletion with absence read-back. Code best-effort
zeroizes only mutable/mlocked buffers it owns. Haskell immutable values, TLS libraries, SDKs, and
the garbage collector may make copies, so the architecture makes no stronger byte-erasure claim.
Home loss including its Vault/Transit key makes retained TLS ciphertext unrecoverable. By contrast,
the AWS rebuild proof destroys and recreates AWS Vault and every AWS EBS volume, starts a newly
attested Agent, restores the exact Secret through the retained-home key, and proves read-back before
issuance. Cross-substrate routing is always the Authority outbox; Gateway is never in this path.

### 5.5 Retained operator-material custody

Non-recoverable cross-substrate operator material has one retained-home source of continuity. The
schema is the closed `RetainedMaterialSchema` sum: `SesSmtpMaterial` targets only
`secret/keycloak/smtp`, and `AcmeEabMaterial` targets only `secret/acme/eab`. Adding another class
requires a new constructor, singleton, exact codec/path mapping, Vault policy, program cases,
destruction case, and qualification proof; no arbitrary secret/path API exists. Retained-material
delivery never includes public-edge certificate private keys — certificate-material handoff is not
a member of the closed `RetainedMaterialSchema`; child clusters self-issue in their own delegated
zone from delivered `AcmeEabMaterial`, and §5.4 owns all cross-substrate certificate movement.

Bootstrap baseline creates a non-exportable retained-home Transit custody key available only to the
home Target Secret Agent's dedicated one-shot custody/rewrap workers. For SMTP, Credential
Provisioner receives the one-time AWS secret-access-key response, derives the region-bound closed
`SesSmtpSource` in its own bounded memory, and hands only that derived source plus key ID/generation
metadata directly to the home custody worker. The home Agent never receives the raw AWS
secret-access-key bytes and performs no AWS derivation. For ACME EAB, a fresh
`ExternalAcmeEabIngress` worker receives the bounded key-ID/HMAC frame from the operator or test-only
fixture; an AWS-admin session cannot supply or authorize it.

The home custody worker validates the schema, operation, generation, key ID, and payload bound,
Transit-encrypts the source, and generation-CAS stores and reads back a ciphertext-only retained
receipt. Authority receives only `RetainedMaterialReceiptRef`, ciphertext digest,
`SecretCommitmentRef`, and typed read-back. The raw IAM secret, derived SMTP password, and EAB HMAC
never enter Authority, MinIO, a checkpoint, a serialized program, or a generic Vault path.

Retained custody storage is durability-indexed. Every receipt, ledger, and custody object in this
lane is addressable only through a coordinate and adapter carrying the `ClusterRetained` or
`CrossClusterDurable` lifetime index; the smart constructors that partition the custody namespaces
refuse a `ChartLifetime` coordinate. A retained receipt reachable through a chart-lifetime
transport — a custodian deleted and recreated with the charts it serves — is unrepresentable.

Delivery always begins from the receipt-committed current source. A newly attested selected-Agent
worker contributes an ephemeral public key; a home one-shot worker Transit-decrypts only that exact
source in bounded memory and re-encrypts it to the selected worker. Authority transports the closed
`RetainedMaterialTargetEnvelope schema` and receives only materialization/read-back receipts. The
target worker validates schema/generation/target binding, generation-CAS materializes the exact
local path, and reads it back. This same flow repopulates a newly created target and restores fresh
AWS Vault/EBS without admin re-prompt, IAM key rotation, or EAB re-entry.

`ObserveRetainedMaterialCustody` is flat and exhaustive: present, positively absent, corrupt,
digest mismatch, or unobservable. Only exact present/read-back can drive rewrap. Rotation keeps the
superseded source through every target delivery, recovery/idempotency window, and retention grace.
`DestroyAwsSes` stops and reads back consumers; deletes and reads back the external SMTP
key/identity/policy and the non-credential SES/S3 family in registered dependency order; tombstones
and reads back every target SMTP generation; and only then tombstones/reads back SMTP custody while
the home Agent/Vault remain live. Total `nuke` applies the corresponding closed SMTP and EAB
decommission tags after target tombstones and before stopping home. The Admin result or external
decommission receipt aggregates every stage and preserves all failures.

### 5.6 Durable SES workflow

The lifecycle mechanism is generic; SES-specific semantics remain canonical in
[Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md).

The durable stages are:

```text
non-credential SES identity/DKIM/receipt-rule/S3 mutation under narrow provider fence
-> committed non-credential provider revision
-> semantic readiness for that exact revision
-> SMTP IAM identity/policy/access-key install or rotation through an OperatorMaterialPermit
-> Provisioner derives region-bound SesSmtpSource and home custody seals/read-backs it
-> committed SMTP credential-family generation + current custody receipt
-> durable per-target delivery outbox
-> home custody rewraps to each attested target; target generation is observed and committed
-> clean quiescent close
```

Provider propagation polling and target delivery do not hold one 70-minute account-wide lease.
Only non-credential SES/S3 provider mutation or a Credential-Provisioner SMTP
install/rotate/remint/repair action obtains the corresponding narrow permit. The Provider Worker
cannot create, modify, or delete the SMTP IAM identity, policy, or access key. A clean, re-observed
close permits immediate successor admission. Canceled, expired, or ambiguous work enters explicit
recovery and grace states. Explicit `DestroyAwsSes` is the separate Admin Action Runner transaction
that removes and reads back absence of both registered families.

## 6. Target Secret Agent

Each substrate runs a Target Secret Agent with:

- one substrate identity and attestation;
- one dedicated Vault Kubernetes-auth role;
- exact HMAC-only access to `prodbox-target-secret-commitment-<substrate>` for opaque commitments;
- an independently scoped one-shot secret-worker ServiceAccount/session for plaintext-bearing
  seal/materialize actions; the long-lived controller receives only metadata and receipts;
- an allowlist of mount/path and payload schema;
- generation/opaque-commitment/version validation;
- read, CAS, and mandatory read-back operations only;
- verification of the signed committed-intent reference, current authority epoch/fence, target
  binding, action digest, and deadline before mutation;
- one genesis-only exact-path sealing arm for `EstablishAuthorityBackup`, disabled permanently after
  the first `BackupEstablished` receipt;
- one distinct repair-only exact-path arm that accepts a signed `RepairPermit` solely while
  `BackupRepairFrozen`, requires the strictly next `LongLived` generation, and cannot re-enable the
  genesis arm;
- one decommission-only exact tombstone arm authorized by
  `VerifiedDecommissionPermit 'DecommissionTargetVaultGeneration` from the externally receipted,
  signed `DecommissionManifest` after Authority has committed `DecommissionExported`; only
  `ExecuteTargetDecommissionTombstone` can use it, and completion requires typed absence read-back;
- separate `TlsSecret*` Kubernetes-RBAC capabilities for enumerated TLS Secret identities, never
  conflated with Vault KV CAS; on home, a separately queued `TlsEnvelopeKeyExchange` lane limited to
  the exact `prodbox-tls-envelope` Transit key;
- on home only, a separately queued one-shot retained-material custody/rewrap lane limited to the
  non-exportable custody Transit key, the two closed SMTP/EAB schemas, exact receipt references, and
  attested target envelopes; it cannot export plaintext or address another Vault path;

`TargetDecommissionTombstoneReadBack`, `RetainedMaterialAbsenceReadBack`, and every credential-
generation tombstone mean physical secret-version destruction, not a KV-v2 soft delete or a newly
written tombstone value. Storage uses an exact per-generation immutable path or enumerates the exact
KV-v2 versions, invokes version destroy, deletes metadata only after all versions are destroyed, and
re-observes metadata/version absence. Rotation may physically destroy only a superseded generation
after its bounded no-dependants proof and retention grace; current or referenced generations refuse.
- no provider, checkpoint, lease, gateway, or arbitrary KV API.

Delivery is at least once. The pure target fold accepts the same generation and opaque commitment
as a duplicate, rejects generation regression or same-generation commitment change, and conditionally
advances to the next permitted generation. The Lifecycle Authority records delivery complete only
after the agent returns and re-observes the exact target version.

Each agent also retains a generation-CAS `AcceptedAuthority` record containing the sole issuer-key
generation, authority epoch, and fence floor admitted for that target. Epoch cutover installs and
reads back this record while both old and new writers remain frozen. The agent verifies a
`CommittedIntentRef` against that local record and its signed commit-receipt digest; it never asks a
possibly stale caller which epoch is current. Epoch regression, an unknown issuer generation, or a
fence below the local floor is terminal before Vault mutation.

The controller may transiently attach a linear secret ingress to an allowlisted one-shot worker for
sealing/materialization; no `CapabilityProgram` contains that payload. The worker cannot use that
credential to call its provider, return plaintext after sealing, or read any path outside the
registered schema. A stale or forged authority cannot advance target generation merely by
possessing transport access.

Sealing itself is response-loss safe. A receipt-committed `TargetSealMutation` authorizes one
secret-free `TargetSealMetadata` value carrying only the operation/action ID, schema, and bound; it
contains no secret-derived hash. The bytes arrive separately through the authenticated linear ingress. The
one-shot worker Transit-encrypts the bounded payload, while the controller generation-CAS stores
only a sealed receipt `(operation ID, action index, opaque SecretCommitment, ciphertext, Transit key
version)`, reads it back, and then replies. On a same-ID replay the Agent recomputes its
domain-separated Vault-HMAC commitment and compares it only inside the receipt fold; mismatch
refuses without exposing either commitment or an unkeyed secret hash. `ObserveTargetSealReceipt` recovers a
lost response without plaintext. If no receipt exists because the effect never happened, the
durable operation enters `OperatorMaterialRequired` and accepts only a resubmission under the same
operation/schema/bound; the Agent alone decides equality. It never creates a new operation or
guesses that sealing occurred.

Materialization is a continuation of that receipt, not a second payload-bearing request.
`CompareAndSwapTargetGeneration` names the exact `TargetSealReceiptRef`; after controller
verification of the committed operation/action/schema binding, a one-shot worker reads that
ciphertext from the exact receipt KV path and Transit-decrypts it only into bounded memory. It then
performs the allowlisted target generation CAS and reads back the exact version and opaque
commitment, then
best-effort zeroizes owned mutable buffers, revokes its session, exits, and is deletion-read-back;
this makes no byte-erasure claim about immutable/runtime/library copies.
Neither the Authority nor its outbox can obtain the plaintext or substitute another receipt. The
receipt remains available through the operation/tombstone idempotency window; only a separately
committed `TargetSealReceiptGcMutation` for the exact receipt reference may invoke
`GarbageCollectTargetSealReceipt` after terminal target read-back and grace. Its
`TargetSealReceiptGcReadBack` must prove absence before the action commits. The Target Secret Agent
Vault role is correspondingly limited to the
exact receipt KV prefix, Transit encrypt/decrypt for its substrate key, and the exact target KV
allowlist plus HMAC-only access to its commitment key; it has no HMAC key export, list,
arbitrary-path, provider, or backup-store permission.

Child recovery delivery uses an equivalent durable nonce fold. Before threshold shares leave parent
custody, the parent agent verifies the receipt-committed `ChildRecoveryDeliveryMutation` and CASes
`DeliveryPrepared custodyGeneration nonce childAttestation`. The child Broker CASes
`DeliveryConsumed` before generating a root session and `DeliveryRevoked accessorAttestation` only
after accessor-absence read-back. `ObserveChildRecoveryDelivery` returns those exact states. A
duplicate nonce resumes or returns the recorded state and can never start a second root session;
same-generation/different-nonce or different-child delivery refuses.

## 7. Bootstrap Broker

The Bootstrap Broker is the only prodbox control-plane service admitted before Vault is unsealed.
Its mutation ADT is bounded and cannot carry observation, baseline, or PKI operations that belong
to other capability indices:

```haskell
-- Example: target shape for src/Prodbox/Bootstrap/Broker/Model.hs
data VaultBootstrapMutation
  = EnsureVaultInitialized VaultInitializeRequest
  | EnsureVaultUnsealed VaultUnsealRequest
  | SealVault ConfirmedSeal
  | RotateUnlockBundle RotationProof
  | RotateTransitKey TransitKeyId RotationProof
  | RecoverAmbiguousInitialization PristineStorageResetProof

data VaultBootstrapObservation
  = VaultUninitialized
  | VaultInitPrepared PreparedInitEnvelopeReadBack
  | VaultInitEncryptedResponseReadBack EncryptedInitResponseReceipt
  | VaultInitCustodyPromoted UnlockBundleReadBack
  | VaultSealed
  | VaultUnsealed
  | VaultInitializationAmbiguous BootstrapInitTransactionId VaultStorageGeneration
  | VaultBootstrapUnobservable BootstrapFailure
```

Read-only observation, bootstrap mutation, baseline reconcile, and PKI programs remain separate
constructors under the distinct indices in §3.2; the wire router cannot place one inside another.
Reconnaissance produces `VaultBootstrapObservation`; a pure planner derives a bounded
`BootstrapPlan`; the broker interpreter alone calls Vault and the bootstrap object store. The
broker exposes no generic MinIO, Vault KV, lifecycle, target-secret, peer, or DNS proxy.

The detailed initialization, encrypted-share receipt, root unlock-bundle, pristine-reset, and child
Transit-seal custody protocol has one SSoT:
[Vault Secret-Management Doctrine §5](./vault_doctrine.md#5-vault-deployment-model-and-durability),
[§6](./vault_doctrine.md#6-the-unlock-bundle-root-cluster), and
[§16](./vault_doctrine.md#16-cluster-federation-a-vault-transit-seal-trust-tree). This architecture
retains only the boundary invariants: the initial root token is encrypted to the compiled/pinned
burn public key, whose private key prodbox never generates, stores, accepts, or accesses, and the
token ciphertext is never decrypted or used; encrypted recovery shares are durably read back before custody advances; an
established Vault generation is never reset; root shares enter only the password-sealed bundle;
child shares enter only generation-checked parent custody; and baseline work uses a separately
generated, short-lived root session that is revoked and observed absent.

Initialization and root unseal use the same one-shot Broker secret-worker boundary. For either
request, the long-lived controller validates secret-free metadata, CAS-acquires the exact storage-
generation-bound fence, creates one worker, and verifies its Pod UID, immutable image digest,
ServiceAccount, request digest, deadline, and storage generation. Only then does the operator CLI
or test harness send prompt bytes through authenticated `pods/exec` stdin or attach directly to the
verified worker. The controller never receives those bytes. Each worker uses no swap/core dump/PV/
argv/env/ConfigMap/Secret/log transport, has a bounded lifetime and managed session, returns only a
typed receipt, revokes the session, best-effort zeroizes owned mutable/mlocked buffers, exits, and
is deletion-read-back. Disconnect, restart, Pod loss, fence loss, attestation mismatch, or deadline
expiry destroys the linear ingress and requires a fresh worker/prompt for the same durable request.
No claim is made about byte erasure of immutable/runtime/library copies.

The crash-safe recovery-recipient transaction is mandatory. Before `/sys/init`, under the exact
bootstrap fence, the long-lived Broker controller starts the verified one-shot initialization
worker described above. The worker generates the recovery PGP
recipient, constructs `PreparedInitEnvelope (transaction ID, Vault storage generation, recipient
private key, recovery/burn public-key fingerprints, schema)`, password-AEAD-seals it, writes it to
bootstrap MinIO, and reads back bytes/digest. Only that read-back authorizes `/sys/init`, whose
recovery shares target the prepared public key and whose initial token targets the compiled/pinned,
provenance-audited burn public key. The worker verifies its fingerprint before `/sys/init`; prodbox
never accepts any corresponding private key.

The Broker then stores and byte-read-backs an `EncryptedInitResponseReceipt` containing only the
Vault-returned PGP-encrypted shares, burn-key-encrypted token, transaction/storage generation, and
fingerprints. On a fresh prompt it opens the prepared envelope, decrypts the recovery shares,
constructs the final password-AEAD unlock bundle, atomically promotes it for that storage
generation, and reads it back. Only final-custody read-back authorizes deletion of the prepared
envelope; deletion requires authoritative absence read-back. A crash before init resumes the same
prepared transaction; after encrypted-response receipt it re-prompts and resumes promotion; after
promotion it re-observes the final bundle and finishes prepared-envelope deletion. The password,
recipient private key, and decrypted shares never enter a journal or `CapabilityProgram`.

For `EnsureVaultUnsealed`, the controller likewise starts a newly verified one-shot unseal worker
for the exact Vault storage generation and fence. After direct prompt ingress, that worker fetches
the fixed-key password-sealed unlock bundle, verifies its generation and digest, decrypts it in
bounded memory, submits only the threshold shares to the exact Vault Service, observes
`VaultUnsealed`, and returns that typed observation. The controller cannot fetch or decrypt the
bundle, receive a share, or reuse an initialization worker session for unseal.

If `/sys/init` applied but no encrypted response was received and read back, the prepared private
key cannot reconstruct the lost response. The state is
`VaultInitializationAmbiguous transaction storageGeneration`; retrying init, generating another
recipient, or guessing success is forbidden. Recovery requires the separately authorized
`PristineStorageResetProof`, which proves that no established Vault generation or dependent state
exists before reset/restart.

Serialization is durable across replicas and rollouts, not an in-process mutex. Before `sys/init`,
share delivery, generate-root, baseline, rotation, seal, or recovery, a Broker must CAS-acquire a
`BootstrapSessionFence` in the bootstrap store for the exact Vault storage generation and hold the
matching Kubernetes Lease. The permit contains a monotonically increasing generation, owner nonce,
operation/action digest, and absolute deadline. A Broker rechecks both observations before every
Vault effect and fails closed if either is stale. Deployment uses a single logical Broker identity;
rollout overlap may serve observations but cannot acquire a second mutation permit.

Lease expiry alone never authorizes a successor root session. Recovery first observes the durable
bootstrap record, cancels any incomplete generate-root attempt, creates one new fenced session,
inventories and revokes every stale root-policy accessor, waits for stable accessor absence, and
only then performs baseline work. The current accessor is journaled before the first privileged
call, revoked after mandatory baseline read-back, and observed absent by the broker-only auditor.
An old replica holding a revoked token cannot continue, and a replica unable to re-observe its fence
cannot call Vault. Normal later reconciliation uses the dedicated least-privilege
`prodbox-bootstrap-provisioner` role.

Child recovery consumes the receipt-committed delivery-nonce protocol in §6. A child Broker records
nonce consumption before generate-root and records the accessor-revocation attestation afterward;
replay of the same nonce resumes that state, while another nonce cannot overlap it. Plaintext shares
and token values never enter Lifecycle Authority or Gateway Runtime.

PKI status and test issuance use the named bounded PKI role through `VaultPkiOperate`; they do not
grant baseline-policy or generic secret access. Every Broker request uses the same exact
operation-indexed reference for admission/execution and one absolute request deadline.

The cryptographic formats, unlock-bundle backend, bootstrap credential, sealed-state behavior, and
Vault policies remain owned only by [Vault Secret-Management Doctrine](./vault_doctrine.md).

## 8. Gateway Emitter Actor

One actor per gateway emitter identity owns the complete local transition. Every emitter is a
stable StatefulSet identity with an exclusive OS filesystem lock, a persisted monotonically
increasing `EmitterIncarnation`, and a renewable Kubernetes Lease whose holder binds emitter,
incarnation, journal digest, and fencing token. On EKS, its static retained CSI volume additionally
uses `ReadWriteOncePod`. On home, where `hostPath`/local PV is not CSI and therefore cannot claim
`ReadWriteOncePod` enforcement, the PV is node-affined to the pinned emitter node; node pinning plus
the OS lock, durable incarnation, and Lease is the supported exclusion mechanism. The background
lease manager renews ahead of expiry and the actor uses only a cached still-valid lease observation
on the heartbeat path. It stops publishing before local lease expiry. A Pod cannot become ready or
publish until every applicable fence is owned; peers reject a lower incarnation. Other workers
submit pure intents to a bounded mailbox:

```haskell
-- Example: target shape for src/Prodbox/Gateway/Emitter/Model.hs
data EmitterIntent
  = EmitHeartbeat GatewayTime
  | EmitClaim ClaimEvidence
  | EmitYield YieldEvidence
  | RotateEmitterEpoch RotationReason

data PendingEmitterIntents = PendingEmitterIntents
  { coalescedHeartbeat :: Maybe GatewayTime
  , orderedAuthorityIntents :: BoundedSeq EmitterIntent
  }

stepEmitter
  :: EmitterState
  -> EmitterInput
  -> Either EmitterRefusal (EmitterState, [EmitterEffect])
```

Heartbeat intents coalesce; claim, yield, and rotation intents never do. Only the actor may stage,
durably re-observe, publish, commit, or recover local continuity. There is no independent
continuity loop that can commit another transition's staged record.

The persistence-first invariant uses an encrypted identity-bound retained journal, not a shared
remote object-store transaction for every heartbeat. The actor owns the complete
`stage -> fsync -> publish -> commit -> fsync` sequence. It obtains its journal key through a
managed renewable Vault session at startup and keeps plaintext only in bounded memory; heartbeat
writes do not call Vault or MinIO. A missing journal after prior admission fails closed and
requires explicit emitter retirement plus a new identity. Each journal volume is a registered
retained resource whose substrate binding is explicit.

First admission is itself a recoverable transaction. Under the volume lock and Lease, the actor
fsyncs `JournalPrepared admissionNonce genesisDigest incarnation`, CAS-writes a Vault
`EmitterAdmissionPrepared` marker carrying the same fields, reads back both, then fsyncs
`JournalActive` and CAS-promotes the marker to `EmitterAdmissionActive`. Publication requires both
active observations. A prepared/prepared pair resumes promotion; a journal without its matching
marker, a marker without its matching journal, or any digest/incarnation disagreement fails closed.
It is never treated as fresh genesis. Retirement requires a receipt-committed
`EmitterRetirementMutation`, a signed peer repair-floor checkpoint, marker revocation read-back, and
journal-resource disposition before a new emitter identity can be admitted.

`GatewayTime` is a gateway-local validated clock/peer-skew value, not Lifecycle Authority time;
heartbeat emission therefore has no authority hot-path dependency. The journal retains the latest
committed signed assertion, its previous anchor, current incarnation, and peer-ack projection.
After restart the actor republishes an unacknowledged assertion. It may compact an ownership
transition only after every currently registered peer acknowledges it or after a signed checkpoint
that includes it becomes the bounded repair floor; an offline peer recovers from that checkpoint.
Commit-before-peer-response can therefore cause a replay, never silent loss.

Remote Model-B continuity may exist only as a migration adapter. While it exists, the actor still
owns the entire transaction and reaches it through a native client; after journal cutover the
adapter is removed. AWS CLI subprocesses are absent from heartbeat and lifecycle Model-B hot paths.

If measured persistence demand cannot satisfy the authored heartbeat rate with required headroom,
the protocol must change rather than hiding the failure with longer timeouts. A permitted future
design durably fences a boot epoch once, uses signed bounded liveness frames inside that epoch, and
persists ownership-changing transitions. Such a change requires updated peer ADTs, restart/replay
rules, doctrine, and TLA correspondence before implementation.

## 9. Interpreter and Runtime Boundaries

The pure modules contain validated inputs, plans, programs, decisions, events, and projections.
Boundary modules contain mutable cells, sockets, clients, workers, and credentials.

| Pure surface | Boundary interpreter |
|--------------|----------------------|
| Capability requirements and programs | Service client/router |
| Deadline and admission decisions | Monotonic clock and bounded queue |
| Bootstrap observation and plan | Bootstrap Broker HTTP/Vault/MinIO adapter |
| Authority `decide`/`evolve` and outbox | Native primary-MinIO/Vault-Transit adapters, typed Backup-Adapter client, and provider-worker client; no admin or backup credential material |
| `CredentialProvisionPermit` plan | Ephemeral, separately resourced Credential Provisioner Job with the sole raw-admin session for identity provisioning and a mode-indexed deterministic identity/store interpreter; first reconcile may retain that bounded session across a finite sequence of separately receipt-backed permits, one active permit at a time |
| `AdminActionPermit` plan | Distinct ephemeral Admin Action Runner with a closed destroy/migrate/compatibility/quota interpreter and stable operation/status read-back |
| `AuthorityBackupProgram` | Separate Authority Backup Adapter Deployment with its own SA/Vault role/session and closed long-lived-S3 interpreter |
| `TlsRetentionProgram` | Separate TLS Retention Adapter Deployment with its own SA/Vault role/session, bounded queue, and exact ciphertext-prefix S3 interpreter |
| In-force config fold | Lifecycle Authority immutable-blob/CAS adapter and role-scoped projection server |
| Operator material fold | Lifecycle Authority target-sealing/outbox adapter |
| Target generation and exceptional permit fold | Target Secret Agent exact receipt/target-KV and Transit adapter |
| `TlsSecret*` programs | Selected Target Agent's exact Kubernetes-Secret lane and one-shot secret worker; never its generic Vault-KV lane |
| `TlsEnvelopeKeyExchange` | Retained home Target Agent's dedicated `prodbox-tls-envelope` Transit lane and one-shot DEK worker |
| Emitter `stepEmitter` | Single actor, native continuity store, peer publisher |
| Registered DNS record plan | Gateway DNS adapter or fenced authority provider worker, as fixed by resource ownership |
| Cleanup DAG | Lifecycle Authority cleanup journal/recovery worker plus substrate/lifecycle node interpreters; TestRunner is a client |

Credential material is acquired and renewed by a dedicated boundary-owned session manager. Request
handlers receive an opaque current generation; they do not parse Dhall, read a service-account
token, log in to Vault, or construct a new HTTP manager per request.

Rare provider tooling that necessarily uses Pulumi or a subprocess runs in a separately resourced,
fenced Provider Worker Deployment/ServiceAccount/queue. It receives a typed `ProviderIntent` and
bounded credential/session permit from the Lifecycle Authority. It cannot write authority state
directly, accept a `GenesisBackupPermit`, `RepairPermit`, `OperatorMaterialPermit`, or
`AdminActionPermit`, receive an admin prompt, or bypass the public `prodbox` harness ownership
rules. The ephemeral Credential Provisioner has the inverse narrow surface: it accepts only an
indexed credential permit and owns no normal provider or admin-action endpoint. The Admin Action
Runner accepts only `AdminActionPermit`; neither Job role shares a ServiceAccount or program
constructor with the other.

## 10. Resource and Scheduling Isolation

Memory containment and service capacity are separate proof obligations. Every component has:

- an independent Guaranteed-QoS request/limit envelope;
- a bounded queue per execution lane;
- reserved admission for authority and recovery work;
- explicit arrival-rate, burst, CPU-demand, service-time, and latency-budget values;
- a saturation refusal and retry-after policy;
- CPU-throttle, queue-wait, deadline-miss, and p95/p99 latency observations.

The pure capacity validator proves the authored service-demand inequality with headroom. The
runtime stability fold proves that deployed behavior remained inside it. The exact algebra and
threshold ownership belong to [Resource Scaling Doctrine](./resource_scaling_doctrine.md).

Every authored envelope is additionally certified against the committed `MeasuredResourceProfile`
for its profile id: authored CPU must sit at or above measured p99 × 4/3, throttle observations
must sit at or below 20000 parts per million while any CPU cap is authored, and a stale profile —
a hot-path source-digest mismatch or a profile older than 30 days — fails the canonical quality
gate. Guaranteed QoS remains mandated; an uncertified authored number is the defect. Profile
artifact shape, certification thresholds, and the recorder gate belong to
[Resource Scaling Doctrine](./resource_scaling_doctrine.md) (§ Measured Resource Profiles).

Health handling is isolated from deep work. Process liveness remains constant time. Operational
readiness is a cached projection of managed sessions, actor state, and queue admission; a replica
that cannot admit its documented capability leaves the corresponding Service endpoints.

Capacity planning treats the Bootstrap one-shot init/unseal secret-worker lane, home TLS-envelope
lane, each selected-Agent TLS-secret lane, Provider Worker, Backup Adapter, TLS Retention Adapter,
home retained-material custody/rewrap lane, each selected-target retained-material materialization
lane, Authority recovery lane, and each on-demand Job role as separate queue/envelope owners.
TLS and retained-material plans independently declare maximum schema/envelope size, concurrent
one-shot workers, Transit/target-Vault latency, attestation cost, absolute deadline, and retry-after;
their reserved worker/session budgets cannot consume normal Target-Agent delivery, Authority
recovery, or provider capacity. TLS-envelope and TLS-secret plans additionally declare maximum envelope size,
concurrent one-shot workers, Transit latency, Kubernetes Secret latency, absolute deadline, and
retry-after; neither can consume the normal target-Vault or lifecycle-provider worker budget.

### 10.1 Registered DNS effects

Every prodbox-created Route 53 record is a managed resource keyed by exact account, zone ID, FQDN,
record type, and ownership epoch. Its closed operations are observe, ensure with authoritative
read-back, and destroy with authoritative absence read-back.

- The home public A record and its Gateway-DNS generation are `LongLived` while the home consumer is
  retained. Ordinary postflight restores/observes that exact Gateway service and desired-present
  record. Only explicit Gateway consumer decommission or `nuke` submits desired absence and
  observes it through the same `CapabilityRef` before deleting the generation.
- The AWS-substrate public A record is owned by an explicit Lifecycle Authority provider intent
  because the EKS Gateway DNS gate is disabled. It uses a narrow AWS-edge session and the same
  operation ID/read-back recovery as other provider work and is run-scoped with EKS.
- cert-manager owns its transient DNS01 TXT records through its separate DNS01 identity. Before
  issuance, the plan registers the exact account/zone/name/type coordinates derived from the
  Certificate DNS names; the Challenge observer confirms those same coordinates. On AWS, the
  run-scoped Certificate/Challenge resources are removed while the controller is live, every TXT
  coordinate is observed absent, and only then may the AWS DNS01 generation be deleted. On home,
  Certificate/Challenge ownership and its DNS01 generation remain `LongLived` with the restored
  cert-manager consumer and are removed only by explicit consumer decommission or `nuke`.

If the owning component is unavailable, cleanup records failure and continues independent nodes;
it does not switch writers. Direct `aws route53` bootstrap calls, content-only discovery, and a tag
sweep as the sole ownership record are pre-cutover legacy. Cutover registers the exact records
before those call sites are deleted.

### 10.2 Compiled Service Boundary

Every kubelet-facing or cross-artifact service contract of a control-plane component — HTTP route
paths and methods, probe endpoints and their semantics class, service ports, and ServiceAccount and
Vault-role identities — exists exactly once, as a compiled closed registry value. The server
dispatcher, client URL construction, chart probe/statics rendering, and response goldens are
projections of that registry. A hand-authored duplicate of a registry value in a template, values
file, or client is a defect caught by the conformance tier of the canonical quality gate, not a
convention.

Readiness is one pure latched projection. Admission requires the first proven object-store round
trip since boot and thereafter does not flap on later transient backend degradation; deep
diagnostics remain a separate route. The scope claim is honest: the kubelet can never hold a
`CapabilityRef`, so Invariant 2 (§2) cannot reach it. Deriving the probe endpoint from the same
compiled registry as the execution handlers is the strongest coupling reachable across the YAML
boundary, and the lifecycle gate retains the capability-scoped deep probe.

## 11. Always-Run Cleanup

Before a suite mutation can obtain its `CommittedIntentRef`, the pure builder CAS-registers its
typed cleanup node in a durable, backup-receipted `CleanupRun` journal and reads back an opaque
`CleanupObligationRef`. The mutation proof binds that obligation. Dynamic child coordinates are
appended and read back before the parent/controller is allowed to create them. The cleanup run has a
monotonic owner fence, node-level operation IDs, durable outcomes, and an independent recovery
worker; TestRunner is a client, not the journal owner. Runner SIGKILL, disconnection, Pod loss, or
authority restart therefore leaves a resumable run rather than erasing an in-memory `finally` plan.

The exact `RequiresSuccess`/`RequiresAttempt` edges, substrate-specific `DrainSkipped` treatment,
canonical cleanup order, resume rules, and aggregate result are owned only by
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-cleanup-failure-handling).
This architecture requires that every ready node continues after sibling failure, credential nodes
remain blocked while their exact dependants need them, and the durable final report retains the
primary suite result plus every cleanup failure and dependency-blocked reason.

Restore and cleanup dependency edges are derived, not authored per-site: the
`RequiresSuccess`/`RequiresAttempt` structure is computed from registered chart-dependency and
storage-lifetime facts, so an independence claim cannot exist only as a comment. The totality
obligations — every long-lived registry entry has a restore node, every per-run entry has a
destroy node, and no node reads retained-or-stronger state through a chart-lifetime transport that
the same graph deletes — are pure checks that run pre-cluster.

### 11.1 Total decommission and the final backup deletion

`prodbox nuke` is the sole exception to retaining Authority backup forever. It cannot require a
backup receipt after deleting the receipt store, so decommission transfers final authority to an
explicit durable receipt outside every resource in the deletion manifest:

```haskell
data DecommissionState
  = DecommissionFrozen DecommissionId
  | DecommissionManifestCommitted
      DecommissionManifestRef
      AuthoritySignerDigest
      DecommissionRunnerArtifactRef
      BackupCommitReceipt
  | DecommissionExported
      DecommissionManifestRef
      AuthoritySignerDigest
      DecommissionRunnerArtifactRef
      ExternalReceiptDigest
  | AuthorityPermanentlyStopped DecommissionId

data DecommissionNodeState
  = DecommissionPending
  | DecommissionRunning DecommissionAttempt
  | DecommissionAbsent AbsenceEvidence
  | DecommissionFailed DecommissionFailure

data DecommissionReceiptFrame = DecommissionReceiptFrame
  { frameSequence :: DecommissionReceiptSequence
  , previousFrameDigest :: Maybe DecommissionReceiptFrameDigest
  , nodeId :: DecommissionNodeId
  , attemptId :: DecommissionAttemptId
  , framePayload :: DecommissionReceiptPayload
  , frameChecksum :: DecommissionReceiptFrameChecksum
  }
```

The protocol is total:

1. Authority freezes normal admission, resolves or records every nonterminal operation, and builds a
   deterministic signed `DecommissionManifest` from the exact managed-resource registry. It contains
   no secret: only topology/config/registry digests, operation IDs, exact coordinates/generations,
   dependency order, expected observations, and constructors from the closed compiled
   `DecommissionProgramTag` universe. A generic command, URL, bucket prefix, shell fragment, or
   caller-supplied coordinate is unrepresentable.
2. Under the normal primary/backup protocol, Authority commits and backup-read-backs the manifest.
   The signature key is pinned by the current build/Tier-0 expected Authority signer plus the
   Bootstrap Broker-attested public-key digest. Before Authority can stop, preflight also proves an
   exact DecommissionRunner artifact whose binary/build/verifier/schema digests equal the manifest
   pins is durably addressable outside every deletion target. If no external immutable artifact
   already satisfies that proof, the CLI exports it beside the receipt, fsyncs file and directory,
   reopens it, and verifies bytes/digests. The CLI then verifies the signer chain, writes the manifest,
   signer digest, Broker attestation, and initial receipt to a required operator-selected or harness
   artifact receipt sink outside the manifest. The receipt is a length-delimited, checksummed,
   hash-chained frame log. Creation/rotation fsyncs the file and containing directory; every append
   fsyncs the file, reopens it, validates the complete chain, and returns its terminal digest. An
   in-memory stdout copy is not a receipt.
3. Authority receipt-commits `DecommissionExported`, returns that evidence, permanently closes every
   admission lane, and stops. Normal operation/status queryability intentionally ends here. If a
   crash occurs before this state, the still-frozen Authority resumes export through the normal
   journal; it does not start deletion.
4. A standalone `DecommissionRunner` accepts only a manifest whose signature matches the exported
   build/Tier-0/Broker-pinned key digest, whose registry/topology digests match the compiled
   verifier, whose own artifact/build/schema digests equal `DecommissionRunnerArtifactRef`, and whose
   nodes decode to closed program tags with exact registered coordinates. It
   rejects a substituted key, tampered manifest/receipt, unknown tag, widened prefix, or unregistered
   coordinate before prompting. It then accepts the same external receipt and a fresh ephemeral
   operator-admin prompt. Its pure planner follows the manifest DAG. Every node and attempt has a
   stable idempotency ID. Before and after each registered destroy it appends a framed
   attempt/result plus authoritative read-back, fsyncs, reopens, and validates the full chain. After
   a crash the parser may discard only an incomplete final frame; checksum/hash/sequence failure or
   a complete conflicting frame refuses recovery. The runner re-observes the exact external effect
   before retrying the same stable attempt. It never skips a complete frame, regenerates an ID, or
   broadens the manifest. Resume under a different runner build or schema refuses rather than
   interpreting the old receipt with new code.
5. The runner deletes ordinary dependants first while the required home controllers remain live:
   home Gateway removes/read-backs its A record, home cert-manager removes/read-backs its
   Certificates/Challenges/TXT records, and run-scoped AWS counterparts are likewise proven absent.
   For SES it stops/read-backs every SMTP consumer, then deletes/read-backs the registered external
   SMTP key/identity/policy and non-credential SES/S3 family in manifest dependency order.
   The signed exported manifest is the one-time decommission authority accepted by the still-live
   home Target Secret Agent for every exact retained-generation tombstone. After every selected
   target's SMTP/EAB generation is tombstoned, the runner executes the distinct
   `DecommissionSesSmtpCustody` and `DecommissionAcmeEabCustody` nodes and reads both retained-home
   source receipts back absent. Home Agent, Vault, Gateway, cert-manager, Bootstrap Broker, and the
   remaining control-plane Pods stay available through those tombstone read-backs.
6. Only after retained-generation tombstones are externally receipted does the runner stop and
   uninstall the home control plane and, when selected, delete/read-back `.data`. Using its fresh
   admin session and no target-cluster dependency, it deletes/read-backs every version under the
   TLS-retention prefixes plus the TLS identity/key/policy, but does not delete their shared bucket.
   The final Authority-backup node deletes/read-backs its objects/versions, access key, IAM
   identity/policy, and prefix, proves every other registered prefix in the shared
   `pulumi_state_backend` bucket absent, and only then deletes/read-backs that bucket last. It
   appends terminal absence evidence and the final scoped tag-sweep result to the external receipt.

The receipt sink must survive the target cluster, `.data`, Vault, primary MinIO, and backup S3
deletion; validation refuses a path inside any registered target. After `DecommissionExported`, loss
of that receipt is an explicit unrecoverable operator-artifact loss, not permission to rediscover by
prefix or restart Authority. This exception preserves the normal backup invariant up to the exact
point at which authority is deliberately and audibly terminated.

## 12. Cutover and Rollback

The migration is an explicit Plan/Apply operation:

1. upgrade every legacy writer to a compatibility revision that checks the durable freeze/epoch
   record and presents an old-epoch writer credential on every mutation; identify external
   controllers that cannot check that record as explicit suspend-and-revoke cutover nodes;
2. introduce typed clients and compatibility interpreters without changing writes;
3. deploy the new components and run read-only shadow observations;
4. prove decoded state, versions, identities, and latency agree, then capture the digest-bound
   superseded-composition counterexample trace/simulator while the old writer is still the sole
   writer;
5. CAS the pre-cutover freeze; withdraw old mutation endpoints; suspend cert-manager and every
   other external old writer; revoke and read back the shared AWS key, old issuer keys, backend
   credentials, and renewable sessions; wait their bounded maximum lifetime; then resolve every
   active or ambiguous operation and prove no in-flight effect remains;
6. migrate the bounded authority aggregate, client/cleanup journals, and independently backed blob
   references while mutation admission remains closed;
7. create `EpochPrepared nextEpoch` without changing the active epoch; install and read back the
   complete typed topology digest: every substrate Agent controller/one-shot-worker and pending
   `AcceptedAuthority` binding; home TLS-envelope lane/key generation; in-force config reference;
   Provider Worker, Authority Backup Adapter, TLS Retention Adapter, Credential Provisioner, and
   Admin Action Runner capability/service/SA/policy bindings; provider, Authority-backup-store,
   TLS-retention-store, Gateway-DNS, and per-substrate cert-manager generations; every committed
   TLS-current immutable ref; exact managed DNS coordinates; and backend issuer bindings. Prepared
   credentials and permit endpoints are not released to writers;
8. re-observe that every backend rejects the old issuer/credential and that every pending new
   binding has the same epoch/topology digest. Any mismatch aborts while both writer sets remain
   unable to mutate;
9. CAS `AuthorityEpoch = nextEpoch` in the frozen aggregate, promote each prepared backend/agent
   binding, read all promotions back, and only then perform one final Authority CAS from
   `EpochFrozen` to `EpochAdmissionOpen`. A partial promotion can serve observations but cannot
   execute an effect because no committed intent is issued before that final CAS;
10. enable the new controller/workload consumers and re-observe their exact capability bindings;
11. run the current-revision post-cutover half of deployment qualification, paired with the frozen
    old counterexample artifact; a failure immediately refreezes admission and is recovered only by
    a greater-epoch forward migration;
12. delete gateway control-plane routes, direct Route 53 calls, compatibility adapters,
    shared-credential paths, and host-direct fallbacks.

Rollback before the `AuthorityEpoch` CAS revokes any prepared new credentials/bindings, reads back
their absence, re-mints an old-epoch credential if revocation consumed the former one, then clears
the freeze and re-enables only the freeze-aware old writer. After the epoch CAS—even before
`EpochAdmissionOpen`—rollback is a new forward migration with a strictly greater epoch; the old
writer is never simply re-enabled. This prevents split authority, stale-fence resurrection, and a
partially wired new writer accepting work.

## 13. Verification Boundary

Pure and model-based validation includes:

- exhaustive capability-kind/operation/provider-policy mismatch rejection, including managed ensure;
- binding/request-digest mismatch and forged/stale committed-intent rejection;
- `decide`/`evolve` laws, event replay, idempotency, and bounded-state properties;
- CAS conflict and applied-but-response-lost simulations;
- authority-clock regression, restart, uncertainty, conservative wall-to-monotonic conversion, and
  deadline-expiry simulations;
- single-writer epoch and stale-fence rejection;
- freeze-aware cutover with old-process restart at every boundary;
- emitter crash points around admission-marker prepare/promote and stage/reobserve/publish/commit,
  with EKS RWOP and home node-pin/OS-lock/Lease overlapping-Pod exclusion plus
  peer-ack/checkpoint compaction;
- deadline monotonicity, admission fairness, bounded queue, and cancellation properties;
- fixed client-slot/reservation saturation, operation-ID tombstone/result lookup/expiry, and
  pending-blob/primary+backup GC interleavings;
- target generation duplication/regression/opaque-commitment-change tables, including proof that no
  unkeyed secret hash or offline equality oracle crosses the Agent boundary;
- config missing/corrupt/CAS-conflict/generation and role-projection tables;
- prepared-init crash points before/after envelope, `/sys/init`, encrypted-response receipt, final
  bundle promotion, and prepared-envelope deletion; re-prompt resume; applied/no-response
  pristine-reset-only ambiguity; normal login, break-glass, orphan-root inventory cleanup,
  token-revocation, and accessor-absence read-back tables;
- init and unseal one-shot Broker-worker Pod UID/image/SA/request/storage-generation attestation,
  direct prompt ingress, disconnect/restart/fence/deadline failure, session revocation, controller
  plaintext exclusion, and Job/Pod absence tables;
- cross-process Bootstrap-fence overlap, root/child encrypted-share receipt, parent custody
  acknowledgment, durable one-time recovery-delivery nonce,
  burn-recipient initial-token non-use, and no-established-Vault-reset tables;
- operator-material install/rotate/revoke, AWS-admin versus external-EAB ingress-schema rejection,
  durable target-seal receipt/re-observation, and role-identity isolation tables;
- SMTP region-bound derivation in Provisioner memory, raw IAM-secret non-custody, closed SMTP/EAB
  retained-home seal/observe/rewrap/materialize/tombstone states, response loss, new-target restore,
  and fresh AWS Vault/EBS repopulation without remint or re-prompt;
- Credential Provisioner Pod UID/image/SA/permit attestation, exec/attach disconnect, deadline/
  heartbeat loss, session revocation, same-permit inventory resume, finite first-reconcile
  AWS-only plan-digest/member/count enforcement, receipt-ordered permit succession, EAB exclusion,
  later-action fresh-prompt enforcement, no secret transport
  surface, and Job/Pod absence proof; Admin Action Runner action/permit separation and quota
  request/status replay;
- `GenesisFrozen` backup establishment crash points, finite key recovery, Adapter-only credential
  access, positive-absent versus consumed-marker cleanup, corrupt/unobservable refusal,
  reconstructed no-permit-digest cleanup, cross-epoch owner mismatch rejection, non-aliased
  primary/backup proof, primary-MinIO restore, and total-`.data` refusal;
- `BackupRepairFrozen` deleted key/bucket/policy drift, temporary-unobservable non-escalation,
  repair-permit crash/replay, full-copy read-back, no-normal-effect, and greater-epoch reopen;
- TLS per-substrate/FQDN serialization, stale/out-of-order put receipts, response loss, Secret
  UID/resourceVersion and cert validity/SPKI regression, committed-current-not-S3-latest restore,
  corrupt/digest-mismatch/unobservable/not-yet-valid and Authority-time-uncertain fail-closed
  decisions, and positive absence/validated-expiry issuance authorization;
- AWS Vault/EBS destroy-recreate followed by retained-home-Transit TLS restore and exact Secret
  read-back before issuance, with Gateway-route absence;
- certificate scope-coverage and narrowing tables — `covers` totality across the apex boundary (a
  wildcard never matches the apex), the multi-label boundary (a wildcard matches exactly one label),
  and the `*.a.z ⋢ *.z` child-wildcard trap, with `mkScopeSet` rejection of undeclared-zone
  wildcards and `bindListener` rejection of uncovered served hosts;
- restore-vs-reissue decision tables keyed by the `impliedBy` narrowing partial order — narrower-or-
  equal reuses retained material, widening triggers one fresh ACME order — under the canonical
  (deduped, ordered) scope-set serialization key;
- IAM create-key applied-response-lost, finite-inventory delete/remint, and no-uncommitted-key
  tables;
- exact DNS owner/epoch, ensure/delete/read-back, owner-unavailable, and no-writer-fallback tables;
- registered controller-child family and deterministic/legacy-import IAM absence tables;
- durable cleanup-run runner-SIGKILL/authority-restart/fence-takeover failure injection at every node;
- decommission export/Authority-stop/standalone-runner crash points, tampered signer/manifest/key/
  receipt/tag/coordinate rejection, torn-tail recovery, complete-frame checksum/hash-chain conflict,
  receipt unobservability, missing/mismatched external runner artifact, cross-build/schema resume
  rejection, stable-attempt re-observation, home-control-plane-live target plus
  SMTP/EAB custody tombstones, TLS prefix deletion without shared-bucket deletion, final all-prefix
  absence, backup/shared-bucket deletion last, and external-receipt resume;
- route-registry non-overlap and round-trip tables;
- deployed-helm-values-versus-compiled-registry/statics equality;
- restore-graph coverage, independence, and orphan-scan tables;
- authored-envelope-versus-measured-profile certification tables;
- updated finite TLA models for continuity and authority cutover.

Deployment qualification additionally exercises the real binary and component topology under the
authored resource envelopes and background rates. The causal counterexample holds a topology-
normalized total resource budget constant before the separate production-envelope profile. It
includes consecutive aggregate runs,
gateway saturation/restart while lifecycle work continues, authority restart at every CAS boundary,
target outage and resume, cancellation during every destructive stage, and residue observation on
both success and failure. The authoritative status and exact evidence live only in the Development
Plan.

## Intent Ownership

This document owns the physical lifecycle-control-plane split, complete initial
capability/reference topology, service and credential isolation, in-force config ownership,
registered DNS-effect ownership, authority-epoch cutover boundary, and pure-functional
implementation shape.

It does not own:

- sprint status or migration progress;
- generic pure-FP coding rules;
- detailed lifecycle/SES business semantics;
- Vault encryption and sealed-state policy;
- gateway peer protocol semantics;
- exact capacity thresholds;
- suite membership or substrate inventory.

Those concerns remain in their linked SSoTs.

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Pure Functional Programming Standards](./pure_fp_standards.md)
- [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- Plan ownership and sequencing: [Overview](../../DEVELOPMENT_PLAN/00-overview.md),
  [Phase 0](../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md),
  [Phase 1](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
  [Phase 2](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md),
  [Phase 3](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
  [Phase 4](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
  [Phase 5](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
  [Phase 6](../../DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md),
  [Phase 7](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
  [Phase 8](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md),
  [Substrates](../../DEVELOPMENT_PLAN/substrates.md), and
  [System Components](../../DEVELOPMENT_PLAN/system-components.md)
- Supporting boundary doctrines: [AWS Admin Credentials](./aws_admin_credentials.md),
  [AWS Integration](./aws_integration_environment_doctrine.md),
  [AWS Test Environment](./aws_test_environment.md),
  [Chaos Hardening](./chaos_hardening_doctrine.md),
  [CLI Command Surface](./cli_command_surface.md),
  [Cluster Federation](./cluster_federation_doctrine.md),
  [Configuration](./config_doctrine.md),
  [Helm Chart Platform](./helm_chart_platform_doctrine.md),
  [Local Registry Pipeline](./local_registry_pipeline.md),
  [Prerequisite Doctrine](./prerequisite_doctrine.md),
  [Secret Derivation](./secret_derivation_doctrine.md),
  [Storage Lifecycle](./storage_lifecycle_doctrine.md),
  [Test Topology](./test_topology_doctrine.md), and
  [Unit Testing Policy](./unit_testing_policy.md)
