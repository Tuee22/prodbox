# Storage and State Ownership

**Status**: Authoritative source
**Supersedes**: Pre-refactor storage lifecycle doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; existing roots are not moved by this documentation change

> **Purpose**: Define production/test isolation, persistent mounts, resource state, retention, and destruction.

## Roots and identity

Production state lives at `.data/<installation-id>/`; each test deployment lives at `.test-data/<run-id>/`. Resolve both from the explicit context/project anchor rather than process working directory. Every root binds environment, deployment/run ID, schema and storage generation before consumers mount it.

| Logical subdirectory | Owner/content |
|---|---|
| `identity/` | Non-secret bootstrap identity and mount generation |
| `control/` | Authority journal, management volumes and local backups |
| `vault/` | Vault secret/KMS/PKI storage |
| `minio/` | MinIO retained objects, checkpoints and scoped test unlock object |
| `applications/` | Local application persistent volumes |
| `artifacts/` | Pinned recovery images/manifests |
| `reports/` | Secret-free operation/evidence summaries |
| Test `config/` | Run-generated config; never the operator's production sibling |

This is a target logical layout. Importing old roots requires a recorded migration; decoding configuration never moves/deletes data. Reject root overlap, symlink escapes, foreign ownership and mismatched mount generations before effects. A lost existing identity is not a new empty deployment.

## kind persistence

Mount exact absolute host roots into disposable kind nodes. Static PV coordinates bind environment, namespace/service, volume identity and generation; PVC reattachment preserves those coordinates. Retain data outside node container writable layers. Validate host path plus Pod-observed content after actual node destruction/recreation, not only a Pod restart.

MinIO, Vault and Authority backup locations cannot alias an unrelated environment. A test cleanup operation has authority only over its registered run, including nested production-policy fixtures owned by that run. It cannot sweep all `.test-data` or touch the operator's `.data`.

## Application volumes and AWS

Use static `Retain` PVs for persistent services: host-backed volumes locally and pre-created, AZ-pinned EBS on EKS. Volume capacity, replicas, scheduling constraints, PVC binding and namespace quota derive from one typed resource plan. Data policy is declared before provider observation.

`Retain` is Kubernetes behavior, not an exemption from an explicit deployment delete. Ordinary AWS delete includes production-owned EBS, snapshots/buckets declared in its scope, and all test-owned storage. Its plan clearly states this data loss and requires the normal destructive confirmation. Parent resources owned outside the deployment are preserved; deployment-owned object versions inside them are not silently retained.

## Journal, checkpoints and backups

Keep non-secret admission/operation metadata usable while Vault is sealed. Protect sensitive checkpoint payloads and operational secrets with Vault. A checkpoint is resume material, not proof that its provider resources exist or are absent.

Local backups and restart recovery work before AWS exists. Name each supported failure model; a copy on the same disk does not prove disk-loss recovery. Optional remote backups have exact resource/credential ownership and complete delete/read-back behavior when introduced. Commit final/recovery information locally before removing the remote store.

Never hash plaintext secrets into public evidence. Retain source/config projections without secret bytes and use opaque generation identifiers for secret-dependent observations. Historical artifacts have an availability/retention owner; deleting an old scratch directory is not lifecycle completion evidence.

## Retention and destruction

| Operation | State consequence |
|---|---|
| Ordinary cloud `delete` | Remove owned AWS, retire obsolete cloud checkpoints/credentials, record target absent; retain kind, local applications/data, trust and bounded reports |
| Component desired-state delete | Change the selected specification, reconcile exact component absence; apply its explicit local-data policy |
| `control delete` | Require clean/NeverAdmitted cloud obligations, remove kind, retain host roots and completion identity |
| Test cleanup | Complete exact cloud deletion, retire test control resources and scoped unlock material, then remove the run's disposable root under its registered contract |
| `admin control purge-data` | Operator-only exact-root destruction after cloud retirement, no mounted consumers and typed confirmation |

A failed or unobservable cleanup preserves its journal and required credentials. Only exact read-back can retire the corresponding obligation. [Lifecycle](lifecycle.md#deletion-order-and-completion)

## Implemented through Phase 1

A new test identity's retained root holds the generation record, imported artifacts, one operation's write-ahead records and a `history/` directory; a completed operation's records are moved (never deleted) into `history/<operation>/` before the next reconcile. Host-backed data (a marker written by a real Pod directly on the host root, and through a static PersistentVolume bound by name to a claim) survives node removal and recreation on the same root and generation, observed by direct reads. A root nested inside another scope's retained root, a symlinked or foreign root and a different generation are refused before any write. Evidence: [Phase 1 validation](../../DEVELOPMENT_PLAN/evidence/phase_01_validation.md).

## Implemented through Phase 2

Vault and MinIO data live in `vault-data` and `minio-data` under the retained root and survive kind recreation unchanged. `control backup` binds copies of both trees to the selected root generation, directory entries, and file contents with a private keyed commitment. `control restore BACKUP --yes` verifies that commitment and retains the previous directories at `replaced-<name>-*`. The test unlock object is the only unlock material in MinIO and holds the unseal key and a limited client token. The initial root token is never stored there.

## Authority-bound storage maintenance

Once the Authority journal is bound, a backup includes its journal and independent custody directories under the same journal lease. Management storage restore requires the current Authority journal, Vault data, durable MinIO buckets for the Broker and Authority, and MinIO configuration to match that copy. The verification keeps a historical backup from rewinding newer operation or credential state. The copied management directories are verified and synchronized before a durable restore intent binds them to the original root, backup commitment, and directory identities. If a process stops during the swap, repeat `control restore BACKUP --yes` in the original scope. Each move resumes from observed directory identities. Service reconciliation and control removal require settlement of the active restore before proceeding.

The Phase 3 scenario registers its disposable root after publishing successful reports and confirming exact control removal. `test cleanup RUN_ID` repeats the supported control read-back before retiring that registered root. The command records the run, root generation, kind operation and evidence location outside the root. If interrupted after quarantining the root, repeat `test cleanup RUN_ID` from the original repository. The custody records identify the original root after its configuration and disposable data have been retired.

`operations list` reports the active restore ID. `operations resume ID` continues that restore with its original verified backup. After settlement, `operations show ID` and `operations resume ID` report the retained result for the same operation.
