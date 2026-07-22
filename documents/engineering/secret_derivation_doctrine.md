# Vault-Backed Secret Management Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
[lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md),
[cli_command_surface.md](./cli_command_surface.md),
[local_registry_pipeline.md](./local_registry_pipeline.md),
[vault_doctrine.md](./vault_doctrine.md),
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md)
**Generated sections**: none

> **Purpose**: Single source of truth for how prodbox stores and serves post-unseal operational
> secrets as scoped Vault objects, the password-gated Tier-1 recovery exception, and the
> host↔cluster boundary across which operational secrets are fetched.
>
> **Filename note.** This file is named `secret_derivation_doctrine.md` for link
> stability only. The HMAC master-seed *derivation* model it once described is retired;
> the document now describes the Vault-KV secret-management model. The filename is
> retained so the docs that already reference it keep working — see
> [vault_doctrine.md](./vault_doctrine.md) for the finalized Vault-root statement.

Secret access is capability-scoped, not daemon-scoped. Bootstrap Broker, Lifecycle Authority,
fenced Provider Worker, Authority Backup Adapter, TLS Retention Adapter, each Target Secret Agent,
and Gateway Runtime use distinct service identities and Vault policies. The mode-indexed
Credential Provisioner and Admin Action Runner are separately attested one-shot Job roles, not
shared daemon modes, as defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); the Gateway
Runtime is not a generic bootstrap, lifecycle, object-store, or target-secret proxy.
Implementation and deployment-qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md); dated removal notes are historical provenance.

## 1. Why this doctrine exists

Every persisted post-unseal operational-secret source of truth is a **Vault object**. There is no
second plaintext operational store, host-side cache, or fallback. Exact cert-manager public-edge
TLS Secrets are bounded materializations and their retained S3 objects are Agent-encrypted
ciphertext with a retained-home-Transit-wrapped DEK, not another plaintext secret root. The
password-AEAD-sealed Tier-1 Vault recovery bundle is the deliberate pre-unseal exception and is governed by
[Vault Doctrine §6](./vault_doctrine.md#6-the-unlock-bundle-root-cluster). The earlier two-class
split — "data-bound" secrets derived from a master seed
versus "non-data-bound" chart-generated values — is retired. Both classes now resolve the
same way: a Vault KV v2 secret, a Vault Transit key (encryption-as-a-service), or a Vault
PKI-issued certificate, fetched by each in-cluster consumer via Vault Kubernetes auth.

The durability concern that motivated the master-seed model is unchanged but solved
differently. Secrets that bind to state surviving cluster wipes — Patroni/Postgres
passwords whose hashes live in the preserved PostgreSQL datadir under
`.data/<ns>/prodbox-<root-chart>-pg/<ordinal>`, the Keycloak admin password, gateway
peer-event keys — are **generated once and persisted on Vault's durable storage**, not
re-derived each cycle. Vault's storage backend lives on the retained PV
`.data/vault/vault/0` (preserved across `cluster delete` exactly like MinIO's PV), so a
Vault KV object is as durable across cluster rebuilds as any retained PV. A cluster rebuild
is **not** a fresh Vault: `vault init` runs exactly once ever, and every subsequent
`cluster reconcile` only **unseals** the existing data (init-once / unseal-on-rebuild).
See [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md §5](./vault_doctrine.md#5-vault-deployment-model).

For workload data-bound secrets, the secret and data it protects share the retained home trust
root: wiping all `.data/` removes both Vault storage and those protected local datastores, and a
fresh `vault init` mints a fresh KV tree against fresh PVs. This does not erase the independent
Authority-backup contract. The Backup Adapter copies Authority ciphertext/receipts to retained S3
so a lost primary Authority namespace can be restored while the home Vault/Transit root remains;
it is not a second workload-secret SSoT and cannot recover a lost home Vault. Public-edge TLS uses
its separate ciphertext-retention path and retained-home Transit wrapping key. Cross-substrate SMTP
and ACME EAB use retained-home payload-specific Transit custody: selected-target Vault objects are
bounded materializations, so recreating AWS Vault/EBS does not force secret re-entry or SMTP-key
rotation.

## 2. Vault is the only secrets backend

Every persisted **post-unseal operational-secret source of truth** is one of three Vault object
shapes:

| Shape | Vault subsystem | Used for |
|---|---|---|
| KV v2 secret | `secret/` KV engine | passwords, API keys, OIDC client secrets, SMTP creds, AWS IAM creds, ACME EAB material |
| Transit key | `transit/` engine | envelope encryption of authority-selected config/checkpoint/index blobs and the separate keying of each Gateway identity-bound local journal |
| PKI certificate | `pki/` engine | internal TLS leaf/intermediate certs; public ZeroSSL key material is Vault-protected |

The password-AEAD Tier-1 unlock bundle, its crash-safe pre-init `PreparedInitEnvelope`, and the
memory-only operator prompt are the narrow pre-/outside-Vault exceptions. Retained Authority backups and TLS envelopes contain only ciphertext, receipts,
and wrapped-key metadata; they are not alternate plaintext secret stores. There is no
`master-seed` object in MinIO and no HMAC derivation. A secret that was
previously derived (Patroni/Postgres passwords, Keycloak admin, OIDC client secrets,
gateway event keys) is generated once and written to a Vault KV path; a secret that was
previously chart-generated behind a `lookup`-guarded `randAlphaNum` (MinIO root, internal
TLS) is generated once into Vault KV/PKI. Each in-cluster consumer authenticates to Vault
with its Kubernetes service account and reads the object it is authorized for — no chart
Helm template generates or stores a secret value.

The retirement of the master-seed/HMAC mechanism (the `Prodbox.Secret.{Derive,MasterSeed,
Inventory}` modules, the gateway daemon `/v1/secret/derive` + `/v1/secret/ensure-namespace`
RPC, the `checkRawMasterSeedReadScope` daemon-only-seed lint, and `selfBootstrapOwnSecrets`)
landed in Sprint `3.19`. See
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).
This doctrine describes the current Vault-only supported path.

## 3. Fail-closed is absolute

A sealed, unreachable, or uninitialized Vault means **no secret resolves**: no KV read, no
Transit unwrap, no PKI issuance. New pods must not reconstruct any secret from a non-Vault
source, because no such source exists. Already-running pods may continue only while they
need no new Vault op; any consumer that reaches Vault for a secret, a cert, or a Transit
unwrap when Vault is sealed fails its readiness gate rather than serving a partial or
seedless answer. There is no degraded mode that leaks. The full fail-closed matrix lives in
[vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix); the
federation-wide unseal cascade (a sealed parent bricks every downstream child) lives in
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

## 4. Removed: the daemon-only master-seed boundary and HMAC derivation

The model this doctrine once described — a single 256-bit `master-seed` object in MinIO,
read only by the in-cluster gateway daemon via `Prodbox.Secret.MasterSeed`, with
HMAC-SHA-256 derivation of per-context data-bound secrets served over
`/v1/secret/derive` and `/v1/secret/ensure-namespace` — is **removed**, not wrapped or
bridged.

| Removed element | Replacement |
|---|---|
| The `master-seed` MinIO object | none — there is no seed; secrets are Vault KV objects |
| `Prodbox.Secret.MasterSeed` (raw-seed reader) | Vault KV read via Vault Kubernetes auth |
| `Prodbox.Secret.Derive` (HMAC-SHA-256 derivation + context ADT) | none — secrets are generated once and stored, not derived |
| `Prodbox.Secret.Inventory` | the Vault path/policy/service-account inventory in §5 |
| `checkRawMasterSeedReadScope` daemon-only-seed lint | Vault policy scoping (each service account reads only its own paths) |
| Gateway daemon `/v1/secret/derive` + `/v1/secret/ensure-namespace` RPC | in-cluster consumers read Vault directly via k8s auth |
| `selfBootstrapOwnSecrets` | secrets are minted once into Vault KV/PKI at install |

The daemon-only-seed boundary is therefore gone: there is no privileged raw-seed reader to
lint-guard, because there is no raw seed. Authorization is enforced by Vault policy — each
consuming service account binds to a Vault Kubernetes-auth role whose policy grants read on
exactly its own KV paths and nothing else. Removal landed in Sprint `3.19`; the ledger rows are in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## 5. Secret inventory: Vault path, owning policy, consuming service account

This table is the authoritative inventory of every post-unseal operational secret prodbox manages.
Tier-1 recovery and the ephemeral prompt are the explicit exceptions above. Each maps to a Vault
object (KV path, Transit key, or PKI role), the Vault policy that grants access
to it, and the Kubernetes service account that consumes it via Vault Kubernetes auth.

| Secret | Vault object | Owning Vault policy | Consuming service account |
|---|---|---|---|
| Patroni application role | `secret/<ns>/<release>/patroni/app` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<ns>-pg` materializer hook |
| Patroni superuser role | `secret/<ns>/<release>/patroni/superuser` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<ns>-pg` materializer hook |
| Patroni standby role | `secret/<ns>/<release>/patroni/standby` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<ns>-pg` materializer hook |
| Keycloak admin password | `secret/keycloak/admin` (KV) | `policy/keycloak` | `keycloak:keycloak` |
| Keycloak DB credentials | `secret/<ns>/keycloak-postgres/patroni/app` (KV) | `policy/keycloak` | `<ns>:keycloak` |
| OIDC client secrets | `secret/<ns>/oidc/<client>` (KV) | `policy/<ns>-oidc` | `<ns>:<consumer>` |
| Keycloak SMTP target generation | `secret/keycloak/smtp` (KV) | separate target-write and workload-read policies | selected-substrate one-shot Target Secret Agent worker (closed-schema generation-CAS writer/read-back); `keycloak:keycloak`, `vscode:keycloak` (readers) |
| Retained SMTP source custody | retained-home payload-specific Transit-sealed `SesSmtpSource` plus typed source receipt | home Agent SMTP-custody/rewrap policy only | retained-home one-shot Agent worker; selected workers receive only attestation-encrypted rewrap, and Authority/outbox sees ciphertext/receipts |
| Gateway peer-event key | `secret/<ns>/gateway/<node-id>/event-key` (KV) | `policy/<ns>-gateway` | `<ns>:prodbox-gateway` |
| MinIO root credentials | `secret/minio/root` (KV) | `policy/minio` | `minio:minio` |
| ACME EAB target generation | `secret/acme/eab` (KV) | target-agent generation-write + cert-manager read policies | selected one-shot Target Secret Agent worker (closed-schema generation-CAS writer/read-back); `cert-manager:cert-manager` (reader) |
| Retained ACME EAB source custody | retained-home payload-specific Transit-sealed `AcmeEabSource` plus typed source receipt | home Agent EAB-custody/rewrap policy only | retained-home one-shot Agent worker; selected workers receive only attestation-encrypted rewrap, and Authority/outbox sees ciphertext/receipts |
| Lifecycle-provider AWS identity | `secret/aws/lifecycle-provider` (KV) | `policy/aws-lifecycle-provider` | fenced Provider Worker only; `Operational`, and may assume only the role named by its committed intent |
| Authority-backup-store AWS identity | `secret/aws/authority-backup-store` (KV) | `policy/aws-authority-backup` | separately deployed home Authority Backup Adapter only; LongLived with its S3 coordinate |
| TLS-retention-store AWS identity | `secret/aws/tls-retention-store` (KV) | `policy/aws-tls-retention` | separately deployed TLS Retention Adapter only; `LongLived`, ciphertext-only, and restricted to exact `public-edge-tls/<substrate>/<canonical-scope-key>` prefixes |
| Gateway-DNS AWS identity | `secret/aws/gateway-dns` (KV) | `policy/aws-gateway-dns` | configured home Gateway DNS writer only; `LongLived` and scoped to the exact registered A record |
| cert-manager DNS01 AWS identity | `secret/aws/cert-manager/<substrate>/dns01` (KV) | `policy/aws-cert-manager-<substrate>` | that substrate's `cert-manager:cert-manager`, scoped to DNS01 TXT operations; home is `LongLived`, AWS is `Operational` |
| Internal TLS certs (any chart) | `pki/issue/<role>` (PKI) | `policy/pki-<role>` | per-chart workload SA |
| Retained public-edge TLS wrapping key | `transit/keys/prodbox-tls-envelope` | home Target Agent TLS-envelope policy only | retained home Target Secret Agent's separate one-shot DEK lane; never the TLS Adapter or selected substrate's long-lived controller |
| Object-store envelope DEKs | per-domain Transit keys, including lifecycle aggregate/checkpoint and gateway-runtime domains | one policy per capability domain | Lifecycle Authority or Gateway Runtime only for its own domain; never a shared generic accessor |
| Target seal receipts | target-scoped receipt KV plus assigned Transit key | per-target receipt/materialization policy | selected Target Secret Agent only; ciphertext-to-bounded-memory materialization/read-back, then idempotency-window GC |
| Service-account tokens | n/a — Kubernetes-managed | n/a | k8s generates and rotates automatically |

The Authority-backup and TLS-retention identities may use one long-lived S3 bucket only through
disjoint registered prefixes. TLS deletion removes/read-backs its exact prefix objects/versions and
TLS identity/policy; it never deletes that bucket. Bucket deletion is the final Authority-backup
decommission tail after every registered prefix is authoritatively absent.

Adding a new secret to any chart or code path requires a same-change row in this table,
naming its Vault object, owning policy, and consuming service account. There is no
chart-template `lookup`+`randAlphaNum` path and no gateway-derived path; the only sanctioned
persisted consumer surface is a Vault object fetched via Vault Kubernetes auth. An attested
one-shot linear ingress may introduce externally minted material directly to a Target Agent for
sealing, but it is never a readable store or workload fallback. Storing secrets on the operator
host is forbidden; the `forbidDotProdboxState` lint in `prodbox dev check` enforces
this. The password-gated Tier-1 recovery bundle is the persistent pre-unseal exception. The
elevated operator AWS admin credential is the separate ephemeral exception: it is prompted via
`SecretRef.Prompt`, admitted only to a genesis/backup-repair/operator-material Credential
Provisioner, an explicit Admin Action Runner, or the post-export Decommission Runner, and
discarded. It is never written
to `prodbox.dhall` and never persisted; its test-simulation counterpart
`aws_admin_for_test_simulation.*` is a `test-secrets.dhall` TestPlaintext fixture that drives
that prompt in tests and is never a Vault object (see
[aws_admin_credentials.md](./aws_admin_credentials.md)). See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and
[aws_admin_credentials.md](./aws_admin_credentials.md).

`Prodbox.Secret.VaultInventory` is the typed KV-path, policy, ServiceAccount, and Kubernetes-auth
role inventory. The Bootstrap Broker's bounded baseline capability reconciles its mounts,
policies, and roles; it is not a generic KV writer. Generated static seed objects use explicit
generation-preserving materialization, while externally owned credentials are never synthesized.
Workloads and chart materializers authenticate with their own roles rather than borrowing a
control-plane identity.

An externally owned target secret is delivered only from a Lifecycle Authority durable outbox.
Ordinary single-target material may cross authenticated linear ingress directly from Credential
Provisioner to its exact Agent/Vault consumer. Cross-substrate SMTP and ACME EAB instead require a
retained source receipt first. Credential Provisioner derives region-bound `SesSmtpSource` in
bounded memory from a one-time IAM secret, discards the raw AWS secret-access-key bytes, and sends
only the closed payload to the retained-home Agent. EAB arrives through its own schema-indexed
external linear ingress under a distinct `OperatorMaterialPermit`, never the AWS admin prompt or
`config setup`, and likewise sends only closed `AcmeEabSource` to that Agent. The home worker
Transit-seals/read-backs the source; later attested home/selected one-shot workers rewrap it to the
selected target. Authority/outbox persists only ciphertext, typed opaque receipts/commitments,
generation, and intent—never plaintext, a credential hash, or a generic export coordinate.

The retained-home and selected Target Secret Agent references are operation-indexed separately;
each uses the same reference for its own observation, admission, execution, and mandatory read-back
under one absolute deadline. A lost response is recovered by durable operation ID, source receipt,
and target generation. Install, rotate, and revoke are closed operations. For SMTP destroy,
consumers quiesce and external IAM key/identity/policy deletion is read back before target and source
custody cleanup runs while both Agents remain live: physically destroy every owned KV-v2 version,
delete/read back metadata, and prove absence. Soft delete or a new logical tombstone is not cleanup;
rotation keeps the current generation and physically destroys only dependency-free superseded
versions. Bootstrap Broker has no
steady-state KV access, and Gateway Runtime has no target-write or lifecycle policy. Implementation
and deployment-qualification status live only in the Development Plan.

## 6. Host↔cluster boundary

In-cluster consumers authenticate to Vault directly with their Kubernetes service account —
no gateway derive RPC, no Secret-mounted plaintext Dhall fragment, no
`/etc/gateway/secrets/*.dhall` mount. The `SecretRef.Vault` reference names the Vault mount,
path, and field; the consumer's Vault Kubernetes-auth role and policy decide what it may
read.

The host CLI never holds a raw seed (there is none) and never reads in-cluster workload
secrets. It reads only the unencrypted Tier-0 boot projection needed to locate the Bootstrap
Broker or retained Lifecycle Authority. The Authority alone fetches the encrypted in-force config
blob and serves validated role-scoped projections through `ConfigObserve`; the host and Gateway
never fetch or decrypt that object directly. Nothing about workloads, downstream clusters, or
credentials is legible from Tier 0. See
[config_doctrine.md](./config_doctrine.md) and
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

Loopback firewalling does not merge authorities. Any host-reachable Bootstrap Broker, Lifecycle
Authority, or Gateway Runtime Service has a distinct typed binding and service identity; Target
Secret Agent is substrate-scoped. The operation-indexed `CapabilityRef` used to observe a service
is the same reference used to admit and execute the request. Gateway Runtime routes remain limited
to gateway state/peer surfaces and never front `/v1/secret/*`, bootstrap, lifecycle CAS, or target
delivery.

## 7. Bootstrap order

Vault must be reachable, initialized, and unsealed before any secret resolves. The reconcile
order follows a non-mutating `prodbox config setup`, which only writes/validates Tier-0 and may do
read-only AWS discovery:

1. `prodbox cluster reconcile` brings the cluster and retained PV bindings up.
2. MinIO becomes bootstrap-readable with the root cluster's static bootstrap credential; this
   exposes only the bounded prepared/encrypted-response/final password-gated bootstrap transaction
   and grants no Tier-2 object authority.
3. The Vault chart deploys on its retained PV and the dedicated Bootstrap Broker performs the
   bounded init-if-empty/unseal request. On a fresh PV, `vault init` runs exactly once; on every
   subsequent reconcile, the existing data is only unsealed. A root cluster uses the
   password-AEAD unlock bundle; a child cluster auto-unseals against its parent's Vault Transit
   seal — see
   [cluster_federation_doctrine.md](./cluster_federation_doctrine.md).
4. The Bootstrap Broker reconciles and reads back the allowlisted KV/Transit/PKI engines,
   policies, Kubernetes-auth roles, the genesis-signing key, and the retained-home
   `prodbox-tls-envelope` key. Initial root use is revoked; no generic root/provisioner role remains.
5. The home Target Secret Agent, Lifecycle Authority, and Authority Backup Adapter start with
   Authority in `GenesisFrozen`; the physically separate Provider Worker exists but cannot admit
   normal work. Authority journals `EstablishAuthorityBackup` and signs a one-time
   `GenesisBackupPermit`. Only an attested mode-indexed Credential Provisioner receives the raw
   admin prompt, creates/observes the deterministic S3 backup prefix and IAM identity, and hands the
   returned key directly to the home Agent. The Agent seals and generation-CAS read-backs it; the
   Backup Adapter copies/read-backs the initial Authority state in S3. Normal admission opens only
   after the receipt and permanent genesis-arm disable are read back.
6. The Tier-0 payload is then submitted as a visible config proposal. Normal backup-receipted
   `OperatorMaterialPermit`s establish or rotate the remaining role-specific identities:
   Operational Lifecycle-provider/AWS-DNS01 and LongLived TLS-retention/home Gateway-DNS/home
   DNS01, plus the deterministic SMTP IAM family. SMTP material commits only after retained-home
   `SesSmtpSource` custody; separately externally supplied EAB uses its own permit/linear ingress to
   establish `AcmeEabSource` custody. Attested home/selected Agent workers restore those closed
   payloads into each selected target before dependent charts. The TLS Retention Adapter, substrate
   Target Agents, Gateway Runtime, and chart deploys proceed with distinct identities. Each
   workload's service account authenticates to Vault via
   Kubernetes auth and reads exactly the Vault objects its policy grants (§5). Chart materializer
   Jobs may create Kubernetes Secret objects required by third-party APIs only after reading Vault;
   no chart Job derives or generates secret values, and no Helm `lookup` resolves a secret value.

**Ordering constraint: only Bootstrap Broker runs pre-unseal.** Every steady-state secret consumer
waits until Vault reports reachable, initialized, and unsealed. Backup genesis and a later explicit
`BackupRepairFrozen` repair are narrowly scoped exceptions to normal backup-receipted mutation;
temporary or unobservable S3/IAM failure merely keeps the gate closed and never authorizes repair.
Vault is the sole secrets authority; a consumer that reaches it early fails closed rather than
racing it. Exact physical and readiness edges are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md) and
[Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md).

[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) §5 is the
authoritative reference for the inverse (teardown) order.

## 8. Failure modes

| Failure | Surface | Response |
|---|---|---|
| Vault sealed / unreachable / uninitialized | not yet unsealed after bring-up, re-sealed mid-flight, or a sealed parent for a child cluster | no secret resolves, no cert issues, no Transit unwrap; consumers fail their readiness gate and report a waiting-for-Vault reason (fail closed). See [vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix) |
| Vault KV path missing | first-ever bring-up before the secret is minted, or a misconfigured policy | the platform install mints the object once into the path under a read-then-write guard; a consumer reaching an unminted path before install completes fails closed and retries after install |
| Vault policy denies the read | service account bound to the wrong Vault role, or a path typo | the consumer receives a permission-denied from Vault and fails its readiness gate; never a silent fallback to a non-Vault source (none exists) |
| Authority backup unavailable | transient/unobservable Backup Adapter, S3, or IAM state | keep normal Authority admission frozen and report the exact observation. Only positive permanent backup loss may enter explicit `BackupRepairFrozen`; no check or retry silently recreates the identity/prefix |
| Retained TLS observation is corrupt or unobservable | TLS Secret, retained S3 envelope, home Transit lane, or identity metadata cannot be proved | fail closed before restore or issuance. Only authoritative absence or policy-valid expiry may select issuance; unobservable is never treated as missing |
| Retained SMTP/EAB source custody is corrupt, rolled back, mismatched, or unobservable | source receipt, home Transit lane, payload schema/generation, or Agent attestation cannot be proved | fail closed before target materialization. Never re-prompt, rotate/remint SMTP, accept config plaintext, choose another target, or expose a generic export as recovery |
| Generated secret mismatches preserved `pg_authid` | preserved `.data/` whose Postgres hash was written under a different Vault KV value (e.g., Vault re-initialized while the PG datadir was preserved) | a loud failure naming the namespace/role pair: the operator must either restore the matching `.data/` or wipe the affected `.data/<ns>/prodbox-<root-chart>-pg/` subtree. Authoritative fresh absence may proceed. An unobservable probe remains gate-closed and never licenses a reset or a claim of mismatch |
| Target-secret capability unobservable | selected Agent/Vault service down, sealed, or not attestable | the caller receives a structured capability error; it never opens a host-direct Vault route or falls back to a host cache |

The `pg_authid` mismatch row is a load-bearing failure case. It is loud by design: silent data reset on
a secret mismatch is precisely the failure mode the pre-doctrine
`.prodbox-state/<ns>/.secrets.json` cache used to hide. The mismatch is detected up-front and
reported; the pure decision (loud-failure policy) is kept separate from the boundary probe. A
definite `pg_authid` rejection is the only mismatch path; authoritative fresh absence admits first
install; unobservable remains a distinct waiting/refusal state rather than being promoted to either.
Implementation and qualification evidence are recorded in the Development Plan.

## Cross-References

- [vault_doctrine.md](./vault_doctrine.md) — the finalized Vault-root statement: SecretRef
  model, fail-closed invariant, Transit envelopes, MinIO ciphertext store, sealed-state
  matrix
- [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) — the root/child
  Vault transit-seal trust tree, parent custody of encrypted child recovery material and
  revocation attestations, and the fail-closed
  unseal cascade
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained
  `.data/vault/vault/0` PV, init-once / unseal-on-rebuild, and Vault state surviving teardown
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — chart/workload
  secrets come only from Vault via Vault Kubernetes auth
- [config_doctrine.md](./config_doctrine.md) — the unencrypted-basics local surface, immutable
  Vault-encrypted config blobs, and the Lifecycle Authority generation/reference that makes one
  blob current
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — gateway
  daemon endpoint surface (the `/v1/secret/*` routes are removed)
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — the
  cascade order that releases MinIO-tracked AWS resources before cluster uninstall
- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) — dedicated
  Bootstrap Broker, Lifecycle Authority, Provider Worker, Backup/TLS Adapters, Target Secret Agent,
  one-shot Credential Provisioner/Admin Action Runner, and Gateway Runtime identities
- [cli_command_surface.md](./cli_command_surface.md) — the `host firewall` subcommand that
  installs the iptables rule
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — the retired master-seed/HMAC derivation modules + daemon RPC and the
  `.prodbox-state/<ns>/.secrets.json` host cache on the cleanup ledger
