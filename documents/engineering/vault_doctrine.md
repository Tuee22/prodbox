# Vault Secret-Management Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[../../README.md](../../README.md),
[config_doctrine.md](./config_doctrine.md),
[../cli/commands.md](../cli/commands.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
[lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md),
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[acme_provider_guide.md](./acme_provider_guide.md),
[aws_admin_credentials.md](./aws_admin_credentials.md),
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md),
[cli_command_surface.md](./cli_command_surface.md),
[streaming_doctrine.md](./streaming_doctrine.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md](../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md),
[../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md),
[test_topology_doctrine.md](./test_topology_doctrine.md)
**Generated sections**: none

> **Purpose**: Single source of truth for Vault as the sole, fail-closed secrets,
> key-management, encryption-as-a-service, and PKI root of every prodbox-managed cluster — the
> SecretRef configuration contract, the password-AEAD-sealed unlock bundle in durable MinIO, the
> dedicated Bootstrap Broker path that reaches it before unseal, Vault Transit envelope encryption
> of MinIO and Pulumi state, the init-once / unseal-on-rebuild durability model, the
> cluster-federation transit-seal trust tree, the sealed-state brick invariant, and in-cluster
> Vault Kubernetes auth.

This document owns secret custody, encryption, Vault policy, and sealed-state semantics. It does
not assign those capabilities to the Gateway Runtime. Physical separation of the Bootstrap Broker,
Lifecycle Authority, fenced Provider Worker, Authority Backup Adapter, TLS Retention Adapter,
Target Secret Agent, on-demand Credential Provisioner/Admin Action Runner, and Gateway Runtime is
canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

## 1. Why this doctrine exists

prodbox manages an intentionally ephemeral cluster: the Kubernetes runtime may be destroyed and
recreated while `.data/`-backed persistent volumes survive and rebind on the next spin-up (see
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)). Before this doctrine, secret
material lived in three uneven places: plaintext fields inside the then-operator-authored
`prodbox-config.dhall` (AWS keys, ACME EAB material), plaintext Dhall fragments mounted from
k8s Secrets, and an unencrypted master-seed object in MinIO that any holder of the bucket
credential could read, with every per-namespace secret HMAC-derived from that seed. A `.data/`
snapshot, a MinIO dump, or a Kubernetes Secret export revealed everything prodbox knows —
including the inventory of any downstream cluster prodbox manages.

**Vault is now the sole post-unseal operational-secrets root.** Every steady-state operational
secret source of truth is a Vault object (KV v2 secret, Transit key, or PKI-issued cert), with no
plaintext fallback. Public-edge cert-manager TLS exists transiently in an exact Kubernetes Secret
and durably only as Agent-encrypted S3 ciphertext with a home-Transit-wrapped DEK; neither is an
alternate plaintext secrets root. Two bounded bootstrap exception classes are explicit: the root
bootstrap envelope family (pre-init `PreparedInitEnvelope` and final unlock bundle) is
password-AEAD ciphertext in MinIO so Vault can be safely initialized/opened, and the elevated operator
credential is an ephemeral prompt that is never persisted. Authority config/checkpoint blobs use
Vault-Transit envelopes; each Gateway continuity journal is separately encrypted by its identity-
bound Vault-managed key on its local retained volume. The operator-authored Dhall holds
**references** to operational secrets, never secret values.

This doctrine is the SSoT for that finalized model. It **replaces — it does not extend** — the
prior secret machinery:

- The **master-seed HMAC derivation model** is **retired, not wrapped**. The seed-derivation
  mechanism described historically in
  [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the `master-seed` MinIO
  object, the gateway daemon as the sole derivation authority, the daemon-only-seed boundary —
  is removed (Sprint `3.19`). Every secret that was previously HMAC-derived (Patroni/Postgres
  passwords, Keycloak admin, OIDC client secrets, gateway event keys) is instead a Vault KV
  object: generated once, persisted on Vault's durable storage, and fetched by each in-cluster
  consumer via Vault Kubernetes auth. There is no `master-seed` object in MinIO.
- The **Tier-0 Dhall config contract** ([config_doctrine.md](./config_doctrine.md))
  changes posture: the in-force cluster configuration is an immutable Vault-Transit-enveloped blob
  referenced by generation/digest from the Lifecycle Authority aggregate, and the binary-sibling
  `prodbox.dhall` is the non-secret bootstrap floor plus
  seed/propose payload. Its sensitive fields are typed `SecretRef.Vault` references — no plaintext
  secret value, and no `FileSecret` arm (§3, §4;
  [cluster_federation_doctrine.md](./cluster_federation_doctrine.md)). The retired
  `prodbox-config.dhall` name survives only as a legacy payload/import shape.
- The **Secret-mounted plaintext Dhall fragment** delivery path is **removed, not bridged**.
  There are no `/etc/gateway/secrets/*.dhall` mounts and no `as Text` credential imports; the
  `SecretRefFile` constructor and its resolver arm are deleted from `Prodbox.Settings.SecretRef`
  (Sprints `1.38`, `3.18`). In-cluster consumers authenticate to Vault directly.
- The **retained-PV model** ([storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md))
  gains a second durable PV under `.data/`, preserved across cluster wipes exactly like MinIO's.
  `vault init` runs **exactly once, ever**; every later spin-up only **unseals** an existing
  Vault — a rebuild is not a fresh Vault (§5).
- The **single ACME issuer + S3 retain-restore** ([acme_provider_guide.md](./acme_provider_guide.md))
  stays as the public-cert contract, but Vault holds the ACME EAB material and protects the TLS
  private-key path; Vault PKI is the internal-cert authority (§11).
- The **managed-resource-registry teardown**
  ([lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md)) gains
  reconcile-time deploy/unseal and a preserved Vault PV on teardown.
- **Cluster federation** ([cluster_federation_doctrine.md](./cluster_federation_doctrine.md))
  layers a Vault transit-seal trust tree over this root: a root cluster and zero or more child
  clusters, where a child Vault auto-unseals against its parent and the parent owns encrypted child
  recovery material plus revocation attestations, never a reusable initial root token (§16).

Implementation status, migration order, blockers, and deployment qualification are recorded only
in the [Development Plan](../../DEVELOPMENT_PLAN/README.md). This doctrine states the required
Vault contract without maintaining a parallel completion ledger.

## 2. The fail-closed invariant

The load-bearing requirement of the entire model: **a sealed Vault bricks the cluster.**

> A sealed (or unreachable, or uninitialized) Vault reduces prodbox to an opaque durable-data
> pile. PVs and MinIO objects may still exist, but they reveal no secrets, no in-force config, no
> Pulumi state, and no downstream-cluster inventory until Vault is unsealed.

Stated as hard architectural invariants — not implementation preferences:

1. **Operational-backend invariant.** Every post-unseal operational secret source of truth is a
   Vault object. There is no second plaintext operational store or fallback. Exact cert-manager TLS
   Secrets are bounded materializations; retained public-edge TLS is Agent-encrypted ciphertext
   whose DEK is wrapped by retained-home Transit. The password-AEAD Tier-1 prepared/final recovery
   envelopes and memory-only operator prompt are the only bootstrap exceptions; no workload secret reconstructs
   from either (§3, §6, §9, §11).
2. **Dhall invariant.** `prodbox.dhall` never contains a plaintext secret value; sensitive
   fields are `SecretRef.Vault` references only (§3).
3. **Cluster-metadata-is-secret invariant.** Downstream-cluster names, endpoints, kubeconfigs,
   account IDs, DNS names, Pulumi stack identities, and the in-force config are secret data; a
   sealed Vault makes them unrecoverable from MinIO, Kubernetes Secrets/ConfigMaps, Pulumi
   backends, logs, or generated files (§9, §13, §16).
4. **Sealed-state invariant.** When Vault is sealed, no secret resolves, no cert issues, no MinIO
   object decrypts, no Pulumi op runs, and every secret-dependent component—including the
   Lifecycle Authority, its Backup/TLS Adapters and Provider Worker, each Target Secret Agent,
   Gateway Runtime, and Keycloak—fails its capability gate (§15). There is no degraded mode that
   leaks.
5. **MinIO object invariant.** prodbox-owned MinIO objects are ciphertext unless they are
   explicitly public, non-sensitive artifacts (§8, §9).
6. **Pulumi invariant.** Pulumi cannot preview, update, destroy, or decrypt state while Vault is
   sealed; the readiness check runs before any AWS-side mutation is attempted (§10).
7. **Federation cascade invariant.** A child Vault cannot unseal without a live, unsealed parent;
   the fail-closed brick cascades down the trust tree from the root (§16,
   [cluster_federation_doctrine.md](./cluster_federation_doctrine.md)).

For security-sensitive paths prodbox prefers an explicit fail-closed readiness gate over silent
degraded operation. Already-running workloads may continue only to the extent they need no new
Vault operation; new Pods must NOT reconstruct secrets from any non-Vault source.

## 3. The SecretRef model

Sensitive configuration fields encode a typed **reference** to a secret, never the secret. There
is no plaintext-secret and no file-mounted-secret arm.

Conceptual Dhall union, owned by a shared type module imported by `prodbox-config-types.dhall`:

```dhall
-- Example: shared SecretRef type module
let SecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : { name : Text }
      | Prompt : { name : Text, purpose : Text }
      | TestPlaintext : Text
      >

in  SecretRef
```

Haskell shape (the ADT, Dhall decoder, production plaintext validator, and Vault KV resolver seam
land in `Prodbox.Settings.SecretRef`; AWS provider credential migration is Sprint `7.14`, and ACME
EAB migration is Sprint `7.15`):

```haskell
-- Example: Prodbox.Settings.SecretRef
data SecretRef
  = VaultSecret VaultPath VaultField   -- kv read, resolved only when Vault is unsealed
  | VaultTransitKey TransitKeyName     -- encryption-as-a-service handle
  | PromptedSecret PromptSpec          -- one-off elevated material, CLI prompt only
  | TestPlaintext Text                 -- test harness only; rejected in production mode
```

There is **no `FileSecret` / `SecretRefFile` arm**. In-cluster consumers reach their secrets
through Vault Kubernetes auth (§12), not through a Secret-mounted plaintext Dhall fragment.

Constructor rules:

| Constructor | Production config | Notes |
|---|---|---|
| `VaultSecret` / `VaultTransitKey` | Allowed | The target for every in-cluster-consumed secret. |
| `PromptedSecret` | Allowed (CLI only) | One-off elevated operator material; never written to disk. |
| `TestPlaintext` | **Rejected** | Accepted only by the test harness, only from `test-secrets.dhall` (§4). |

`prodbox config validate` rejects any plaintext secret value in production config and rejects
`TestPlaintext` outside the test harness (Sprint `1.35`). Any secret a deployed
in-cluster component needs must be a `VaultSecret` / `VaultTransitKey` reference before
deployment.

`prodbox.dhall` **may** contain: non-secret topology; public, non-sensitive endpoint
names; Vault mount names; Vault policy intent; logical `SecretRef` values; the unencrypted-basics
bootstrap surface needed to reach and unseal Vault (cluster id, this cluster's Vault address, seal
mode, and — for a child cluster — the parent reference it must contact to auto-unseal; see §16 and
[config_doctrine.md](./config_doctrine.md)).

`prodbox.dhall` **must not** contain: AWS access keys; ACME EAB HMAC material; TLS private
keys; MinIO root credentials; Keycloak admin passwords or client secrets; Pulumi passphrases or
stack secrets; downstream-cluster kubeconfigs; downstream-cluster hostnames, IPs, account IDs, or
identities that reveal managed-cluster inventory; or any plaintext material needed to unseal,
authenticate to, or decrypt Vault-protected state.

## 4. Config split: production references vs test plaintext

Two files, one rule each:

| File | Content | Consumed by |
|---|---|---|
| `prodbox.dhall` | Production-safe topology, the unencrypted basics, and `SecretRef` values only — a binary-sibling Tier-0 bootstrap floor plus seed/propose payload, not the in-force SSoT (§16). NO plaintext secrets; NO `aws_admin_for_test_simulation` block | Host CLI and generated/mounted Dhall config paths |
| `test-secrets.dhall` (Sprint `1.43`; formerly `test-config.dhall`) | All test-only plaintext that simulates operator prompts and seeds fixtures — the Vault unlock-bundle password (simulates the unseal prompt) and the `aws_admin_for_test_simulation.*` elevated-AWS credentials (simulates the elevated-credential prompt) among them | The test harness only |

`test-secrets.dhall` may carry the Vault unlock-bundle password used by tests (which simulates the
operator entering the password at the unseal prompt; §6), the `aws_admin_for_test_simulation.*`
elevated AWS credentials that simulate the operator typing the elevated/admin credential at the
`SecretRef.Prompt` arm, fake ACME/EAB values, fake MinIO credentials, fake Keycloak bootstrap
passwords, and fixtures used to seed Vault in integration tests. None of these testing secrets live
in Vault — Vault holds production secrets only. `test-secrets.dhall` must never be required for
production, imported by `prodbox.dhall`, copied into generated cluster config, stored in
MinIO, mounted into the cluster, or committed with real values; it has no production role. It is the
only cleartext home of the root operator's memorized unseal password (§6, §16) and the only home of
the `aws_admin_for_test_simulation.*` test fixture (a test-harness fixture, not a production-config
section or a Vault object; see [aws_admin_credentials.md](./aws_admin_credentials.md) for the block
specifics).

Generated **test** Dhall surfaces (the executable-sibling `prodbox.test.dhall` and its per-variant
run config) likewise carry secrets only by `SecretRef` name; `test-secrets.dhall` remains the sole
cleartext-secret-at-rest file, accepted only through the `TestPlaintext` arm, per
[test_topology_doctrine.md](./test_topology_doctrine.md).

## 5. Vault deployment model and durability

Vault runs **inside** the prodbox-managed cluster as a platform component, on the same footing as
MinIO, the in-cluster registry (registry:2), MetalLB, Envoy Gateway, cert-manager, and the Percona PostgreSQL operator. It is a
normal in-cluster Helm release (`charts/vault/`) on the same ephemeral-PVC / retained-PV pattern
as everything else, and it appears in the shared `[PlatformComponent]` inventory so **both**
substrates (home + AWS) stand it up identically (substrate equivalence; see
[substrates.md](../../DEVELOPMENT_PLAN/substrates.md) and Sprint `3.17`).

Requirements:

- A single Vault instance per prodbox-managed cluster.
- A durable PV backed by `.data/` (`.data/vault/vault/0`, `manual` StorageClass, `Retain`,
  single-node affinity), preserved across cluster teardown exactly like MinIO's PV. Cluster
  teardown must not destroy Vault state (see
  [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)). On the AWS/EKS substrate
  the same static `Retain` model applies, only backed by a pre-created EBS volume lifted in as a
  static PV (CSI `volumeHandle`, AZ-pinned) instead of a hostPath; the EBS volume is retained
  across teardown exactly like `.data/`, so the same "a cluster rebuild is not a fresh Vault;
  rebuild only unseals" guarantee holds (Sprint `7.28`; see
  [storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md#1-canonical-doctrine-statements)).
- The Vault chart defaults to root Shamir mode. Child clusters set `seal.mode = transit`, render a
  `seal "transit"` stanza pointing at the parent Vault, and source the parent Transit token from
  `VAULT_TOKEN` rather than from the ConfigMap.
- Startup readiness gates that distinguish: not deployed; deployed but uninitialized; initialized
  but sealed; initialized and unsealed; policy reconciled.

### Init-once / unseal-on-rebuild

The cluster is ephemeral; its storage is **not**. Vault KV is therefore as durable across rebuilds
as any retained PV:

- `vault init` runs **exactly once, ever** — the first time the PV is empty. Before root Shamir
  init, the Broker read-backs a password-AEAD-sealed `PreparedInitEnvelope` containing the generated
  PGP recovery-recipient private key and exact transaction/storage-generation fingerprints (§6).
  Root init then uses `secret_shares` / `secret_threshold`, persists and reads back Vault's
  PGP-encrypted response, and atomically promotes the recovered shares into the final
  password-AEAD-sealed unlock bundle in durable MinIO — never host disk. Child
  Transit init uses `recovery_shares` / `recovery_threshold`; its recovery shares and a
  custody receipt are generation-CAS delivered to the parent's Vault KV (§16). Vault encrypts the
  initial root token to the compiled/pinned burn public key. Its fingerprint/provenance is audited;
  prodbox never generates, stores, accepts, or has access to a corresponding private key and never
  decrypts or uses the token ciphertext.
  A separate short-lived generate-root session performs first baseline only after custody is durable.
  Init is never rerun against existing state.
- Every subsequent `cluster reconcile` redeploys the Vault chart against the existing data and
  only **unseals** it. No re-init, no key regeneration. **A cluster rebuild is not a fresh Vault.**

Acceptable storage modes are Vault integrated storage on the retained PV or file storage on the
retained PV for development. The exact backend is not load-bearing; the load-bearing property is
that cluster teardown never destroys Vault state and `init` never reruns.

```text
.data/
  prodbox/
    minio/0/                     durable MinIO StatefulSet PV — ciphertext objects only (§9),
                                 incl. the bounded prepared/encrypted-response/final unlock
                                 transaction — ROOT cluster only (§6, §6.1, §9)
  vault/
    vault/0/                     durable Vault StatefulSet PV, preserved across cluster wipe
```

The unlock bundle is **not** a host-disk file. It is a password-AEAD-sealed object in the durable
MinIO bucket (§6, §9); host disk holds no Vault recovery material. The Vault PV
(`.data/vault/vault/0`, `Retain`) is still preserved across cluster wipe exactly as above —
moving the bundle into MinIO does not change the Vault PV's durability contract.

## 6. The unlock bundle (root cluster)

> **Disk-free (in force, Sprint `7.25`).** The bundle lives ONLY in the durable MinIO bucket — host
> disk holds no Vault recovery material. The init transaction reads back its prepared envelope
> before `/sys/init` and cannot report success until the final bundle is promoted/read back in MinIO;
> `vault unseal` reads it from MinIO with no disk fallback; `rotate-unlock-bundle` rewrites
> it in MinIO. A non-secret `.data/prodbox/.cluster-established` marker (not the bundle) is the only
> on-disk artifact, used solely so the config loader can tell an established cluster from a
> pre-establishment one without a MinIO read. The live wipe-rebuild proof of this path is a
> non-blocking 🧪 axis ([DEVELOPMENT_PLAN](../../DEVELOPMENT_PLAN/README.md) Sprint `7.25`).

The root cluster's Vault uses **Shamir** seal mode: the operator is the only one who can unseal
it. Before initialization, the Broker must make the generated PGP recovery recipient itself
crash-safe. It password-AEAD-seals a `PreparedInitEnvelope` containing the recipient private key,
transaction ID, exact empty Vault storage generation/fingerprint, recipient public-key fingerprint,
burn-recipient fingerprint, and format/version bounds into the bootstrap MinIO namespace. The
Broker reads back and decrypt-verifies that envelope before it may call `/sys/init`; a public-key
fingerprint without durable private-key custody is not sufficient preparation.

The binding uses Vault's official init fields: [`pgp_keys`](https://developer.hashicorp.com/vault/api-docs/system/init)
contains one public key per `secret_shares` output, and
[`root_token_pgp_key`](https://developer.hashicorp.com/vault/api-docs/system/init) names the burn
public key for the initial token. The prepared transaction commits the exact ordered public-key
array and both fingerprints before the API call, so a restart cannot substitute a recipient.

Vault PGP-encrypts every unseal share to that prepared recovery recipient and its initial root token
to the compiled/pinned burn public key. The Broker verifies its audited fingerprint before init,
and prodbox never generates, stores, accepts, or accesses a corresponding private key. Before decrypting any share, the Broker
persists and byte/digest-read-backs the complete encrypted init response under the same transaction
and storage-generation binding. It then decrypts the shares only in bounded memory, constructs the
password-AEAD-sealed **unlock bundle**, writes and reads back the candidate, and atomically promotes
that candidate as the fixed current bundle. Only after the promoted bundle is read back and
decrypt-verified may the Broker delete the `PreparedInitEnvelope`; deletion itself requires
authoritative absence read-back. The unusable initial-token ciphertext is never decrypted and may
be retained only inside the encrypted init-response receipt until its separately fenced GC.

A crash before `/sys/init` resumes the prepared transaction after the operator re-enters the
password. A crash after a durably captured init response resumes decryption and final-bundle
promotion from that response and the prepared envelope; it never reruns init. An init that may have
applied but whose encrypted response was never durably captured is fail-closed ambiguity. It permits
only the separately defined proven-pristine storage-generation reset path; absent that proof, no
reset, re-init, or guessed recovery is allowed. (A child cluster's Vault uses `seal "transit"` against its parent
instead and has no unlock bundle at all; its recovery keys live in the parent's Vault KV — see §16
and [cluster_federation_doctrine.md](./cluster_federation_doctrine.md). The unlock bundle is
Tier-1 bootstrap-secret material per [config_doctrine.md §0](./config_doctrine.md), and Tier 1 is
**root-cluster-only**.)

The unlock bundle is **not** a Vault-Transit envelope: it is precisely the material that *unseals*
Vault, so it cannot depend on an unsealed Vault. Instead it is sealed directly under the operator
password using authenticated encryption with a real password-based key-derivation function —
**never raw SHA-256**, which is a hash, not encryption:

```text
operator password
  -> Argon2id KDF
  -> ChaCha20-Poly1305 AEAD
  -> a password-AEAD-sealed object in the durable MinIO bucket
     (fixed bootstrap key, NOT a Vault-Transit envelope; §6.1, §9)
```

The operator password is the **sole operator-memorized bootstrap secret**: it derives the AEAD key
that seals prepared/final bootstrap bodies. Generated PGP private keys, shares, DEKs, and prompted
AWS admin bytes may exist transiently only inside their separately bounded one-shot flows; none is
another memorized or persisted plaintext root. The MinIO access credential that fetches ciphertext
is static (§6.1) and is not the security boundary. Nothing about the bundle touches host disk.

Conceptual plaintext (before encryption) — the stored bundle object is always ciphertext:

```json
{
  "cluster_id": "...",
  "vault_address_hint": "...",
  "created_at": "...",
  "unseal_keys": ["..."],
  "recovery_keys": ["..."],
  "format_version": 1
}
```

The unlock-bundle backend is the password-AEAD-sealed MinIO object. No initial root-token field
exists. After the share receipt and bundle are durable, the Bootstrap Broker uses the shares to
generate a distinct short-lived root session, inventories stale root-policy accessors, applies and
reads back the allowlisted baseline, creates the dedicated Kubernetes-auth provisioner/PKI and
token-accessor-auditor roles, revokes the session, and proves its accessor absent. Later baseline
work uses the provisioner role; repair of that role uses the same exclusive generate-root/
inventory/read-back/revoke protocol. Vault's
[`operator generate-root`](https://developer.hashicorp.com/vault/docs/commands/operator/generate-root)
flow encrypts the generated token to an operation-specific PGP recipient; the Broker never requests
or emits an unprotected generated root token.

### The unlock chain

The operator's unlock-bundle password is the **single ephemeral root of trust** for the root
cluster — and, through the transit-seal tree, for every cluster beneath it. It is supplied at the
CLI unseal prompt, used in memory, and never persisted:

```text
operator CLI password
  -> host CLI submits secret-free request metadata to the loopback-restricted Broker controller
  -> controller fences the storage generation and verifies a one-shot unseal worker
  -> host CLI sends the password only to that Pod over authenticated exec/attach stdin
  -> one-shot worker uses the static bootstrap MinIO credential to fetch the
     password-AEAD-sealed unlock bundle over in-cluster Service DNS (fixed key; §6.1, §9)
  -> worker performs Argon2id + ChaCha20-Poly1305 decryption in bounded memory
  -> worker recovers the root Vault's unseal/recovery keys only for this request
  -> worker submits the unseal keys to Vault over in-cluster Service DNS
     -> UNSEAL THE ROOT VAULT
  -> worker returns typed read-back, revokes/exits, and is observed absent
  -> the unsealed root Vault's Transit keys decrypt the Lifecycle Authority's in-force config and
     checkpoint envelopes and unwrap the Gateway Runtime's local journal key (§8, §9, §10), and
     serve as the transit-seal authority that
     auto-unseals child clusters (§16)
```

The password therefore does **not** encrypt secrets directly — it decrypts the unlock bundle that
holds the root Vault's unseal keys, and an *unsealed Vault* is what decrypts and serves everything
else. The consequences:

- A **sealed Vault** — no operator password entered this boot — leaves the in-force config,
  lifecycle checkpoints, and Gateway journal key unavailable, and leaves every child cluster unable to
  auto-unseal, exactly per the fail-closed invariant (§2) and the federation cascade (§16).
- The password is the only secret the operator memorizes; Vault's actual unseal keys are
  machine-generated and live only inside the encrypted bundle.
- The password's **only cleartext home is `test-secrets.dhall`**, read solely by the test harness
  to simulate the operator at the unseal prompt (§4); no production path stores or logs it.

### 6.1 Bootstrap MinIO credential

> **Disk-free (in force, Sprint `7.25`).** The bundle lives ENTIRELY in MinIO — no host-disk copy and
> no disk fallback. MinIO is **cluster-only** (its chart `vault-secrets` init container removed, the
> static root cred injected directly by `renderMinioChartArgs`) so it comes up BEFORE Vault and serves
> the bundle pre-unseal. This is safe precisely because MinIO depends only on the cluster — it is
> unreachable only when the cluster is, when there is nothing to unseal. **Accepted edge:** wiping the
> MinIO PV while retaining Vault loses the only unseal source (wipe both or neither — MinIO's PV holds
> the in-force config + Pulumi backends too).

Because the unlock bundle lives in MinIO rather than on host disk (§6), prodbox must reach a MinIO
object *before* Vault is unsealed. The credential it uses is the **static MinIO root credential**
(`Prodbox.Minio.RootCredential`), NOT a password-derived value (operator decision 2026-06-22):

- The MinIO access credential is **not** the security boundary. The Bootstrap Broker uses it
  from inside the cluster through the `minio.prodbox.svc.cluster.local` Service rather than from a
  host-side `kubectl port-forward`. The prepared/final bootstrap bodies are
  **password-AEAD-sealed** (Argon2id + ChaCha20-Poly1305), so reading their ciphertext is useless
  without the operator password; and every Tier-2 operational object is a **Vault-Transit envelope**,
  useless without an unsealed Vault. The access credential only gates ciphertext access; it does
  not grant unseal authority.
- A static credential is trivially **stable across rebuilds**, so a retained MinIO data PV always
  matches Vault (no random/derived drift), and it is a credential MinIO actually **accepts** — so the
  bundle round-trips through MinIO rather than failing `InvalidAccessKeyId`.
- Deriving a key-value pair from a human-memorized password (Argon2id) to gate that ciphertext access
  added machinery without adding real security, so it is removed.

The operator password remains the sole operator-memorized bootstrap secret (§6): it is the AEAD key
for prepared/final bootstrap bodies (the thing that actually protects the share-recipient and
unseal material), nothing more.

**Bootstrap reorder.** Reaching the bundle before unseal means **MinIO must be reachable before
Vault unseal**, which inverts the historical `cluster reconcile` ordering (Vault first, then
MinIO; §7). The reconcile sequence therefore brings MinIO up to a bootstrap-readable state ahead
of the unseal step, then proceeds with Vault deploy → Bootstrap Broker deploy → init-if-empty →
prepare/read back init custody → capture/read back the encrypted init response → atomically promote
the final unlock bundle → fetch/decrypt that bundle → unseal. The broker exposes only the bounded bootstrap request
algebra; it is not a generic Vault, MinIO, lifecycle, target-secret, peer, or DNS proxy. Direct host
bootstrap transport and Gateway Runtime bootstrap routes are unsupported fallbacks. Service
identity, capability binding, and failure-domain ownership are canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

**Child clusters take none of this.** A child Vault uses transit-seal and auto-unseals against its
parent (§16); it has no unlock bundle, no bootstrap MinIO credential, and no password prompt — its
recovery keys live in the parent's Vault KV. Tier 1 (the password-gated bootstrap secret) is
**root-cluster-only** ([config_doctrine.md §0](./config_doctrine.md)).

## 7. Vault lifecycle commands

prodbox adds a `vault` command group (Sprint `1.36`):

```text
prodbox vault status
prodbox vault init
prodbox vault unseal
prodbox vault seal
prodbox vault reconcile
prodbox vault rotate-unlock-bundle
prodbox vault rotate-transit-key <key>
prodbox vault pki status
prodbox vault pki issue-test-cert
```

- `vault init` is the operator-facing init-if-empty surface. The host CLI reaches the
  loopback-restricted Bootstrap Broker controller with secret-free metadata; the controller returns
  success unchanged if already initialized (init-once; §5), otherwise fences and verifies a
  one-shot initialization worker. The CLI sends the password directly to that Pod over
  authenticated exec/attach stdin. The worker connects to Vault over in-cluster Service DNS and
  runs the prepared-init/encrypted-receipt protocol: the initial token is encrypted to
  the burn recipient, the password-AEAD `PreparedInitEnvelope` is read back before the init call,
  Vault's PGP-encrypted response is durably read back, and the final password-AEAD unlock bundle is
  atomically promoted/read back before the prepared envelope is deleted/read back absent (root).
  Child recovery material is generation-CAS delivered to parent Vault KV (§16). Only then does a
  separate PGP-protected short-lived root session establish/read back the baseline and revoke. It
  prints no raw key material.
- `vault unseal` is the operator-facing unseal surface. The host CLI prompts for the bundle password
  unless the test harness supplies it, submits secret-free metadata to the Broker controller, then
  sends password bytes only to its newly verified one-shot unseal worker over authenticated
  exec/attach stdin. The worker reads the unlock bundle from MinIO via in-cluster Service DNS,
  decrypts in bounded memory, submits unseal keys to Vault via in-cluster Service DNS, verifies
  Vault is unsealed, returns a typed receipt, revokes/exits, and is observed absent. The controller
  never receives password/share bytes. Plaintext unseal keys are never persisted. A child cluster
  auto-unseals against its parent's transit key with no human prompt (§16).
- `vault reconcile` binds the exact Bootstrap Broker `VaultBaselineReconcile` capability. It
  requires Vault initialized and unsealed, then idempotently reconciles auth
  mounts, policies, roles, KV mounts, Transit keys, PKI mounts and issuers, Kubernetes
  service-account auth for in-cluster workloads, the MinIO bucket encryption policy metadata, and
  the Pulumi encryption configuration. It is safe to run on every cluster spin-up.
  The bounded Vault reconciliation interpreter applies the baseline `secret` KV v2 / Transit / PKI
  mounts, Kubernetes auth, per-domain Transit keys, and baseline policies/roles through
  `Prodbox.Vault.Reconcile`. It is not a Gateway Runtime or host-root-token route. Normal runs use
  the dedicated provisioner Kubernetes-auth role; generated first-baseline/break-glass root
  sessions are bounded, stale-root accessors are reconciled first, and each current accessor is
  revoked and observed absent inside the Broker transaction.
  Chart-by-chart Vault-auth adoption, PKI issuer generation, and child-custody workflows land in
  their owning later sprints (§12, §16, §18).

**Historical implementation record.** Lifecycle integration into `prodbox cluster reconcile` was
split by cluster role: Sprint `4.29`
lands the root/local deploy, init-if-empty, unseal, and policy reconcile sequence; Sprint `4.32`
adds the child-cluster Transit-seal branch, parent-readiness fail-closed cascade, parent-custodied
child init write, and post-MinIO settings reload through the child root token stored in the parent
KV. The target removes that stored-token reuse: initialization burns the initial token without ever
decrypting it, parent custody retains encrypted recovery material only, config reads use Lifecycle
Authority, and a separate inventoried short-lived root session exists only after durable custody.

Because the root unseal step now fetches the unlock bundle from MinIO (§6, §6.1), MinIO must be
bootstrap-readable **before** Vault unseal — the bootstrap reorder of §6.1, using the static MinIO
root credential (Sprint `7.19`, operator decision 2026-06-22). Only this disk-free reorder remains
last:

```text
prodbox cluster reconcile
  -> reconcile RKE2 + retained PV layer
  -> deploy/rebind MinIO to a bootstrap-readable state (durable bucket present; §6.1)
  -> deploy/rebind Vault on its durable PV
  -> deploy/rebind the Bootstrap Broker and its loopback-restricted capability
  -> host CLI submits secret-free init metadata; controller fences/verifies one-shot init worker
  -> host sends prompt directly to worker; worker performs vault init-if-empty (init-once; §5)
       (root: read back PreparedInitEnvelope; call /sys/init with committed pgp_keys and
        root_token_pgp_key; persist/read back encrypted response; atomically promote/read back
        final bundle; delete/read back prepared envelope. child: parent-custodied init, §16)
  -> controller fences/verifies a distinct one-shot unseal worker; host sends prompt directly
  -> unseal worker performs vault unseal
       (root: fetch fixed-key unlock bundle from MinIO via Service DNS with the static bootstrap
        MinIO credential, password-AEAD-decrypt with the operator password, submit unseal keys to
        Vault via Service DNS; §6.1.
        child: auto-unseal from parent, §16)
  -> workers revoke/exit and are observed absent; Broker runs bounded Vault baseline reconcile
  -> finish MinIO reconcile (steady-state root creds now resolvable; ensure the `prodbox-state`
     object-store bucket and its Vault-Transit encryption path)
  -> deploy home Target Secret Agent, Lifecycle Authority, Authority Backup Adapter, and the
     physically separate Provider Worker; Authority starts GenesisFrozen on first bring-up
  -> EstablishAuthorityBackup through signed GenesisBackupPermit, attested Credential Provisioner,
     direct home-Agent seal/read-back, and Backup Adapter S3 copy/read-back
  -> permanently disable genesis; retain the prompt session only under the exact AWS plan cursor;
     open normal admission; accept one visible generation-CAS config seed proposal on first bring-up
  -> issue schema-indexed AWS-admin OperatorMaterialPermits for remaining exact identities;
     final plan receipt forces session revocation and Job/Pod absence
  -> derive SMTP source in Provisioner memory and seal/read back retained-home custody; use a
     separate external-EAB Job/frame to seal/read back EAB custody
  -> deploy TLS Retention Adapter and each additional substrate Target Secret Agent; rewrap current
     SMTP/EAB custody receipts to each selected target and read back its generation
  -> deploy the Gateway Runtime and reconcile charts that depend on Vault
```

A sealed or unreachable Vault is surfaced as a first-class cluster status, never hidden:

```text
Vault: initialized, sealed
MinIO: reachable, encrypted objects present
In-force config: unavailable; Vault sealed
Pulumi backend: unavailable; Vault sealed
Lifecycle Authority: blocked by Vault
Target Secret Agent: blocked by Vault
Gateway Runtime: blocked by Vault
Keycloak: blocked by Vault
Ingress TLS: blocked by Vault
```

## 8. Envelope encryption with Vault Transit

prodbox encrypts at-rest blobs with Vault Transit envelope encryption:

```text
plaintext object
  -> generate a random data-encryption key (DEK)
  -> encrypt the plaintext locally with an AEAD using the DEK
  -> ask Vault Transit to wrap the DEK
  -> store ciphertext + wrapped DEK + metadata
```

Object envelope format (`Prodbox.Crypto.Envelope`, Sprint `3.17`):

```json
{
  "format": "prodbox-envelope-v2",
  "transit_key": "prodbox-minio-envelope",
  "wrapped_dek": "vault:v1:...",
  "nonce": "...",
  "aad_sha256": "base64(SHA256(aad))",
  "ciphertext": "...",
  "created_at": "...",
  "key_version": 1
}
```

The AAD binds cluster ID, object logical type, object generation, schema version, and the
expected object identity, so an envelope cannot be replayed under a different identity. The
**stored** AAD is hashed — `base64(SHA256(aad))`, never the cleartext binding (`prodbox-envelope-v2`,
Sprint `4.30`). The earlier `prodbox-envelope-v1` persisted the cleartext binding (e.g.
`base64("clusterId|aws-eks")`) in the object body, which leaked a logical name even while the
ciphertext stayed sealed; v2 removes that leak. Open re-supplies the real AAD via `expectedAad`
and checks it against the stored hash, so binding strength is unchanged — only the stored form is
hashed (§9 rule 4).

Transit keys are split by blast-radius domain so a leaked decrypt grant is contained:

```text
transit/prodbox-active-config
transit/prodbox-gateway-journal-wrap
transit/prodbox-pulumi-state
transit/prodbox-minio-envelope
transit/prodbox-downstream-cluster-config
```

Least-privilege policy: the Gateway Runtime may unwrap only its identity-bound local journal key
and reads a role-scoped config projection from Lifecycle Authority; the Lifecycle Authority uses
only active-config and lifecycle aggregate/checkpoint keys; the fenced provider worker receives no
generic Transit grant; the Bootstrap Broker accepts only bounded key-rotation requests; application workloads use
only their assigned Transit keys. The host CLI holds typed capability references and never receives
a generic decrypt grant. The
`prodbox-downstream-cluster-config` key and its policy gate a parent cluster's custody of child
clusters (§16).

The envelope template above pins the format tag (`prodbox-envelope-v2`) and field set; the exact
local AEAD cipher (e.g. AES-256-GCM or ChaCha20-Poly1305), the on-disk serialization, and the AAD
canonicalization are deliberately left to the implementing sprint (`Prodbox.Crypto.Envelope`,
Sprint `3.17`, with the v2 hashed-AAD landing in `4.30`) rather than fixed here, so the wire format
can be chosen against the available crypto libraries without a doctrine change.

## 9. MinIO as a ciphertext store

prodbox's MinIO store is a secret-bearing state store fronted by one application-level **Model B
object-store** (the §8 envelope layer). MinIO itself is just object storage; its
own root credentials come from Vault KV (§5, §13). Every prodbox-owned object is ciphertext (a §8
envelope) unless it is an explicitly public, non-sensitive artifact. Secret-bearing objects
include the in-force cluster configuration, Lifecycle Authority state, downstream cluster configuration
and custody material, Pulumi state and history, generated manifests carrying secret references
plus sensitive topology, bootstrap records, and reconciliation checkpoints that reveal managed
resources. Gateway emitter continuity is instead an encrypted identity-bound local journal and is
not a MinIO object. There is **no `master-seed` object** — the HMAC-derivation model is retired (Sprint
`3.19`; §1).

The same durable bucket also holds the root cluster's **bounded bootstrap transaction** (§6,
§6.1): the password-AEAD `PreparedInitEnvelope` while init is unfinished, Vault's PGP-encrypted init
response receipt, and the promoted password-AEAD unlock bundle. These fixed bootstrap keys are the
deliberate exception to the opaque-name + Vault-Transit rules below: Tier 1 establishes and
*unseals* Vault, so it cannot be a Vault-Transit Tier-2 envelope or hide behind a Vault-keyed-HMAC
name a sealed Vault could not compute. Secret-bearing prepared/final bodies are sealed under the
operator password (Argon2id + ChaCha20-Poly1305; §6), and the response contains only Vault PGP/
burn-recipient ciphertext. Their discoverability is intentional and does not weaken the fail-closed
invariant; operational Tier-2 objects remain opaque-named and Vault-gated. Child clusters carry no
such objects (Tier 1 is
root-only; [config_doctrine.md §0](./config_doctrine.md)).

The encryption strategy is **Model B**: a single prodbox application-level layer that envelopes
logical prodbox objects through Vault Transit (§8). It is not MinIO bucket server-side encryption — content
encryption alone leaves object names, prefixes, counts, sizes, and bucket names as plaintext
metadata, and the fail-closed invariant (§2) is an *existence/metadata* property, not just a
content property. Because prodbox owns this layer, it controls naming, indexing, and padding in
the same trusted, Vault-bound code path that does the encryption. The layer enforces five rules.
Sprint `4.30` implements the shared layer and routes the in-force config read through it; Sprint
`7.14` routes main Pulumi stack cycles and production stack reads through the same layer:

1. **Envelope via Vault Transit.** Each object body is a §8 envelope — local AEAD over a random
   DEK, the DEK wrapped by Vault Transit. A sealed Vault cannot unwrap any DEK, so no object body
   decrypts.
2. **Opaque object names.** Every operational (Tier-2) object is stored at
   `objects/<vault-keyed-HMAC>.enc` under one flat prefix. The opaque ID is a Vault-keyed HMAC of
   the object's logical name (deterministic, directly addressable, and index-loss tolerant); the
   MAC key lives in Vault KV, so a sealed Vault cannot recompute or invert the mapping from a
   logical name to its `objects/<id>.enc` path. The name therefore carries no signal — not the
   object's role, not a downstream cluster, not a Pulumi stack identity. The bounded **root
   bootstrap-key family** (§6.1) is the exception: its prepared/response/final coordinates are
   fixed (not HMAC-opaque) because they must be findable while Vault is sealed. Those slots are
   decoy-padding-counted as part of the constant-count pool (rule 5), so their presence reveals
   nothing beyond "this is the root cluster" and cannot reveal whether initialization is unfinished.
3. **Vault-encrypted indexes.** The id↔logical map lives in `indexes/*.enc`, themselves §8
   envelopes. A sealed Vault reveals only the opaque IDs; the logical meaning behind each ID is
   recoverable only once Vault is unsealed and policy allows the read.
4. **Hashed stored AAD (`prodbox-envelope-v2`).** The AAD persisted in the object body is
   `base64(SHA256(aad))`, never the cleartext binding (§8). The earlier `prodbox-envelope-v1`
   wrote `base64("clusterId|objectName")` — e.g. a literal `aws-eks` — into the object body, a
   metadata leak even while the ciphertext stayed sealed. Open still re-supplies the real AAD via
   `expectedAad`, so binding strength is unchanged; only the *stored* form is hashed.
5. **Decoy-pad to a constant object count + size buckets.** The shared object layer defines a fixed
   decoy key pool so a sealed-Vault `list-objects` can return a **constant** object count carrying
   no signal about how many real objects exist. Sprint `4.33` gates the Haskell-side
   listing/oracle/log renderers behind Vault readiness; Sprint `5.8` owns the deployed
   cross-surface red-team and any remaining size-bucket evidence beyond the object-layer foundation.

**On-disk consequence.** For objects already routed through the Model-B layer, the hostPath PV that
backs MinIO (`.data/prodbox/minio/0`; see
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)) holds opaque-named ciphertext —
`objects/<hmac>.enc` and `indexes/*.enc`. Sprint `7.14` stores main Pulumi stack checkpoints behind
this same layout; first-touch migration/deletion imports any pre-existing raw checkpoint layout into
the encrypted object-store before supported writes continue. Sprint `4.33` gates the Haskell
residue/listing/oracle surfaces and
token-bearing debug rendering behind Vault readiness; Sprint `5.8` proves the deployed
on-disk/k8s/log sweep while Vault is sealed.

**One generically-named bucket.** Prodbox-owned MinIO state uses the **single generic bucket**
`prodbox-state` (Sprint `4.30`). The role-revealing bucket name
`prodbox-test-pulumi-backends` is retired; a bucket-level `s3api ls` no longer advertises the
Pulumi role. The registry's public image layers stay a separate, non-secret store — the §13 public class,
not enveloped. The Sprint `7.14` interposition makes Pulumi see only a scratch `file://` backend on
main stack cycles; persistent checkpoints are opaque `objects/<id>.enc` Model-B objects.

**One encrypted object format, capability-owned access.** The envelope, HMAC-naming, index, and
decoy codec is shared pure code; it is not a generic network proxy and does not make one service
authoritative for every object. Each independently deployed capability binds a native MinIO client
and only the Vault policy, logical coordinates, and operations assigned to that service identity:

- the **Bootstrap Broker** can access only the fixed bounded bootstrap transaction: prepared
  password-AEAD init envelope, Vault-encrypted init response receipt, and current password-AEAD
  unlock bundle. It exposes no Tier-2 object-store API;
- the **Lifecycle Authority** owns the one bounded mutable authority/config CAS aggregate plus
  immutable content-addressed config and checkpoint blobs. Its Transit/HMAC/MinIO identity cannot read gateway journals,
  arbitrary Vault KV, or another substrate's target secrets;
- the **fenced Provider Worker** opens only Authority-selected checkpoint blobs into RAM-tmpfs and
  reads only `secret/aws/lifecycle-provider` for the exact committed provider intent. It cannot
  use a backup/TLS/DNS credential or perform genesis/admin actions;
- the **Authority Backup Adapter** has no MinIO authority and cannot decrypt logical state. It alone
  reads `secret/aws/authority-backup-store` and writes/read-backs exact ciphertext copies at the
  registered S3 coordinate, returning typed receipts to core Authority;
- the **TLS Retention Adapter** receives only bounded TLS envelope ciphertext from Authority. It
  alone reads `secret/aws/tls-retention-store` and may address only the registered
  `public-edge-tls/<substrate>/<fqdn>` prefixes; it has no Transit, plaintext-TLS, provider, or
  Authority-backup access;
- the **Target Secret Agent** has no MinIO authority. It performs only allowlisted,
  generation-checked Vault KV read/CAS/read-back for its substrate. Independently scoped one-shot
  workers own any plaintext-bearing seal/materialize step and exact TLS Secret RBAC; only the home
  Agent has the separately queued `transit/keys/prodbox-tls-envelope` lane;
- the **Gateway Runtime** has no MinIO, lifecycle CAS, checkpoint, bootstrap, config-blob, or
  target-secret authority. It consumes a role-scoped config projection and an encrypted local
  identity-bound journal whose key-wrap policy cannot be used as a general object-store route;
- the **host CLI** binds opaque typed clients to those capabilities. It does not recover a root
  token, open a steady-state MinIO port-forward, or fall back to a Gateway Runtime route after a
  capability failure.

A permitted accessor recovers a logical Tier-2 object only while Vault is unsealed and its policy
allows the exact coordinate: authenticate with the service identity, ask Transit to unwrap the DEK,
then decrypt. Sealed Vault therefore reveals nothing about cluster setup or child clusters beyond
the unencrypted basics (§16). The operator unlock-bundle password remains the ephemeral root that
gates the pre-unseal exception; see [The unlock chain](#the-unlock-chain). Physical service,
client-binding, and failure-domain ownership are defined in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

Two transit/residency hardening rules apply to secret-bearing transfers. **In transit:**
secret-bearing transfers to and from MinIO use TLS; a service-to-MinIO plaintext HTTP hop such as
`http://minio.prodbox.svc.cluster.local:9000` is nonconforming, even inside the cluster.
**At rest on the host:** no recovered plaintext secret lands on a
physical-disk-backed file. A boundary that must materialize bytes uses a small RAM-only Kubernetes
`emptyDir{medium: Memory}` or equivalent tmpfs; native clients keep plaintext in bounded, scrubbed
memory and never hand it through a physical-disk-backed file.

### Whole-system zero-child-info

The fail-closed invariant (§2) is a **whole-system** property, not a MinIO-only one. When the
parent cluster's Vault is sealed, it must be impossible to extract any information about its
children — whether it has any, how many, where, or what, down to object/key names like
`aws`/`aws-eks`. The invariant covers four surfaces, each of which must leak nothing while sealed:

1. **MinIO objects.** Opaque `objects/<hmac>.enc` names, Vault-encrypted `indexes/*.enc`, a
   constant decoy-padded object count, and size-bucketed bodies — no role-revealing bucket name,
   no logical key, no count signal (this §9).
2. **The host disk.** A raw walk of `.data/prodbox/minio/0` reveals only opaque-named ciphertext
   at a constant count; no plaintext name, body, or count, and no recovered plaintext secret on
   any physical-disk-backed path (this §9; [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)).
3. **Kubernetes objects.** No ConfigMap, Secret, namespace name, or other k8s object encodes a
   downstream-cluster name; child-named namespaces use opaque IDs and downstream identity is
   custodied in the parent's Vault KV, not a k8s Secret (§13, §16;
   [cluster_federation_doctrine.md](./cluster_federation_doctrine.md)).
4. **Logs and output.** No structured log, error, or command output emits a child name, opaque-id
   plaintext, or token on a sealed path — including the **exists-vs-`NoSuchKey` oracle**: a query
   for whether a given logical object is present must not distinguish "present" from "absent"
   while Vault is sealed, because presence itself is metadata (§14).

This subsection is enforced cross-surface by Sprints `4.30` (object-store foundation and
in-force-config object read), `4.33` (host disk, k8s, logs, and the oracle), and `7.14` (the Pulumi
backend, §10); the sealed-Vault validation
asserts every surface fails closed (§19; Sprint `5.8`).

## 10. Pulumi backend under Vault

Pulumi backend state reveals AWS resource names, account IDs, cluster names, endpoints, dependency
topology, and provider configuration. Under this doctrine that is secret data, and the leak is not
only the body but the **stack identity** itself — a backend object keyed `aws-eks` advertises a
child cluster's existence by its name alone. So the whole checkpoint is enveloped and the stack
identity is opaque-named through the §9 object-store. Every `prodbox aws stack ...` command
performs the readiness check before touching state (Sprints `1.37`, `7.14`):

```text
check Vault reachable
check Vault initialized
check Vault unsealed
check Transit key available
check Pulumi backend decryptable
only then run Pulumi
```

Sprint `1.37` enforces the host-side apply-path gate for the readiness checks that exist before the
encrypted backend interposition: Vault reachable, initialized, and unsealed. Dry-runs render the
plan without probing Vault. Sprint `7.14` extends the same gate with Transit-key and backend
decryptability checks for the decrypt-to-scratch Pulumi backend.

A sealed Vault produces a clear, safe error before any AWS-side mutation is attempted:

```text
Blocked: Vault is sealed.
Pulumi backend state and AWS deployment credentials are intentionally unavailable.
No preview/update/destroy was started.
Run: prodbox vault unseal
```

### Decrypt-to-scratch interposition

The mechanism is **decrypt-to-scratch interposition**, applied uniformly to every Pulumi backend.
Pulumi never touches MinIO directly. For one provider mutation, the fenced provider worker opens a
bounded scratch scope (`Prodbox.Pulumi.EncryptedBackend.withDecryptedStack`):

1. **Gate** on unsealed Vault (the readiness check above).
2. **Decrypt** — `getLogical (LogicalPulumiStack <id>)` through the §9 object-store, hydrating the
   stack checkpoint into a RAM-tmpfs `file://` local backend
   (`.../.pulumi/stacks/<project>/<id>.json`). The scratch backend lives only in RAM-backed
   tmpfs, never on a physical disk (§9 at-rest rule).
3. **Run** `pulumi login file://…; pulumi <op>` against that decrypted local view, with **no
   passphrase** — Pulumi's own secrets provider is dropped (see below).
4. **Re-envelope** — `putLogical` the resulting checkpoint back through the object-store, so it
   returns to MinIO as an opaque-named §8 envelope (`objects/<hmac>.enc`).
5. **Shred** the scratch.

This local scratch scope encloses only one provider invocation. It is not the lifecycle operation,
does not remain open during semantic propagation or target delivery, and does not provide fencing
outside the Lifecycle Authority aggregate.

Because Pulumi only ever sees the RAM-tmpfs `file://` view, the MinIO PV holds opaque ciphertext
**even mid-run** — there is no window in which a plaintext, stack-named, or unencrypted backend
object exists on disk or in the bucket.

**Pulumi's own secrets provider is dropped.** The §8 envelope *is* the encryption; there is no
Vault-derived Pulumi passphrase and no Pulumi-managed secrets provider layered on top. Running
`pulumi` with no passphrase against the decrypted scratch keeps exactly one encryption boundary —
the prodbox envelope — rather than two competing ones.

### Two layers

Two distinct layers protect a Pulumi operation, and they are not the same concern:

1. **AWS input credentials in Vault KV + the readiness gate.** The AWS deployment credentials a
   Pulumi run consumes are Vault KV objects, obtainable only when Vault is unsealed; the readiness
   check blocks every operation before any AWS-side mutation when Vault is sealed.
2. **The whole checkpoint enveloped + opaque-named through the §9 object-store.** The backend
   state itself — every checkpoint and history object — is a §8 envelope stored at an opaque
   `objects/<hmac>.enc` name via the shared object-store, so the stack identity and body are both
   sealed-opaque.

Runtime AWS identities are split. The fenced provider worker reads only
`secret/aws/lifecycle-provider` and may assume only the operation-specific role named by a
committed intent. The separate Backup Adapter alone reads
`secret/aws/authority-backup-store`; its LongLived identity reaches only the opaque backup prefix.
The TLS Retention Adapter alone reads `secret/aws/tls-retention-store`; its LongLived identity
reaches only exact registered TLS prefixes. Gateway DNS reads only `secret/aws/gateway-dns`, and
cert-manager on each substrate reads only `secret/aws/cert-manager/<substrate>/dns01`. Authority
backup, TLS retention, home Gateway-DNS, and home DNS01 are `LongLived`; Lifecycle-provider and AWS
DNS01 are `Operational` and are removed only after their dependants are absent. These paths have
distinct IAM resources, Vault policies, generations, consumers, and cleanup nodes. The shared
operational `aws.*` field and `secret/gateway/gateway/aws` path are pre-cutover legacy and have no
target consumer. There is no raw-config or cross-role fallback. Elevated/admin bytes enter a
mode-indexed Credential Provisioner, an explicit Admin Action Runner, or the post-export
Decommission Runner only through a separate linear `SecretRef.Prompt` ingress; they are never a
capability-program field or persisted value. Tests may simulate that prompt only with
`aws_admin_for_test_simulation.*` in `test-secrets.dhall`.

For canonical `aws-ses` work, the Lifecycle-provider bootstrap credential is only an AssumeRole source for
the exact-trust `prodbox-ses-lease-session` role. The fenced provider worker receives a session
bounded by one narrow non-credential SES identity/DKIM/receipt-rule/S3 provider mutation and the
absolute operation deadline. It has no SMTP IAM identity/policy/key authority. Schema-indexed
Credential Provisioner owns SMTP identity/policy/key install/rotate/remint and repair-time delete,
derives `SesSmtpSource` from the one-time IAM secret in bounded memory, and sends only that closed
source to retained-home custody. Semantic readiness and target delivery hold neither session.
Exact `DestroyAwsSes` uses Admin Action Runner for registered terminal SES/S3 plus SMTP deletion;
migration/nuke remain separately admin-authorized according to lifecycle doctrine.

First-touch import of a legacy raw checkpoint is confined to a compatibility interpreter. After
import, the provider worker sees only scratch `file://` state; it writes an immutable encrypted
checkpoint blob, and the Lifecycle Authority makes that blob current only by CAS-committing its
digest in the one authority aggregate. A lost response cannot make the scratch directory or blob
authoritative: recovery observes the durable operation ID, aggregate version, referenced digest,
and provider state before deciding whether to resume.

SES cutover additionally renders a new non-credential-only checkpoint and commits its custody and
target receipts before current projection drops all historical SMTP key outputs. Old immutable
primary and backup checkpoint/history blobs become retired, not current. Fenced GC may destroy and
read back both copies only after the rollback window and complete primary/backup no-reference scans;
replacement or elapsed time alone is insufficient.

The target treatment is still **uniform**: per-run and `aws-ses` checkpoints have primary opaque
MinIO bytes and mandatory exact S3 backup copies read back before promotion. Optional S3 first-touch
is legacy import only. There is no AES256-SSE-only carve-out for the
long-lived backend — a sealed Vault yields opaque holds uniformly across every backend. The
operator unlock-bundle password is the ephemeral root that gates the decrypt — see
[The unlock chain](#the-unlock-chain).

Uniform encryption does not mean ambient endpoint selection. The retained home/control-plane
Lifecycle Authority owns the long-lived `aws-ses` aggregate and checkpoint-blob namespace in
`prodbox-state`; no Gateway Runtime, active kube context, or port-forward can become that authority.
The authority commits provider revision, semantic readiness, and the current retained-home SMTP
custody receipt before it commits a bounded target-delivery outbox. A home one-shot custody worker
rewraps only that exact receipt to a newly attested selected-Agent worker; the selected substrate's
Agent alone may perform the allowlisted, generation-checked SMTP KV CAS and mandatory read-back. It
has no checkpoint, provider, or global fence authority. The same closed flow restores SMTP into a
fresh AWS Vault/EBS without IAM remint or admin re-prompt.

Provider mutation and credential rotation use separate narrow fences; the 5–30 minute semantic
readiness wait and target delivery hold neither fence. Operation state and outbox are durable and
identified by `OperationId`, so applied-but-response-lost work is recovered by re-observation rather
than a second synchronous bracket. Detailed lifecycle transitions belong to
[Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md); physical component
placement belongs to
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

## 11. TLS and PKI under Vault

Vault is the TLS authority for the stack, succeeding the prior plaintext ACME-field model and
keeping the single-issuer + S3 retain-restore contract of
[acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md).

Public-edge issuance remains cert-manager/ZeroSSL-owned, but retention has an independent custody
path. The selected substrate's Target Secret Agent starts a one-shot worker with RBAC for the exact
TLS Secret, validates the certificate/key pair, and encrypts those bytes locally. A distinct
one-shot lane in the retained home Agent obtains a fresh data key from the non-exportable
`transit/keys/prodbox-tls-envelope` key and encrypts that data key to the selected worker's attested
ephemeral public key. Authority transports only bounded ciphertext, the home-Transit-wrapped data
key, validated metadata, and ciphertext digests. The TLS Retention Adapter writes/read-backs that
exact envelope at `public-edge-tls/<substrate>/<fqdn>` and never sees certificate plaintext, private
key plaintext, a plaintext DEK, or a Transit token. This retained-home wrapping lane is why an AWS
Vault/EBS teardown does not destroy the ability to restore an AWS-substrate certificate.

Restore precedes issuance. The Adapter returns only flat present/positively-absent/corrupt/digest-
mismatch/unobservable observations; a pure decision classifies present validity against trusted
Authority time and its uncertainty interval. Only positive absence or proven expiry may permit a
separate issuance intent. Not-yet-valid, boundary-ambiguous, regressed/unobservable time, corrupt,
identity-mismatched, rollback, or unobservable Secret/S3/Transit state fails closed and cannot be
collapsed to absence. TLS-retention credentials and exact
registered object versions are `LongLived`. Deleting TLS retention removes only those registered
prefix objects/versions and the TLS identity/policy. It never deletes the shared bucket; bucket
deletion is the final Authority-backup decommission tail after every registered prefix is proved
absent. The complete state machine and one-shot-worker placement are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

In the target path, ACME EAB install/rotation/revocation is an `OperatorMaterialRequest` whose
`ExternalAcmeEabIngress` is distinct from AWS-admin input. The retained home Agent Transit-seals and
reads back the closed EAB custody source; later one-shot workers rewrap that exact current receipt
to each attested selected Agent, which performs the allowlisted `secret/acme/eab` generation CAS and
read-back. Lifecycle Authority persists only custody/target ciphertext digests, opaque Agent/Vault
keyed-HMAC commitment references, generations, and outbox state—never an unkeyed secret hash.
cert-manager reads the HMAC only through its in-cluster role-specific materializer. The non-secret
key ID reaches issuer reconcile only as a typed generation-bound Agent/`ConfigObserve` projection;
no host Vault client reads it. Neither host nor Gateway reads EAB material or writes the
cert-manager Secret directly. A fresh AWS Vault/EBS is repopulated from retained-home custody
without EAB re-entry.

**Historical implementation record (Sprint `7.15`, pre-cutover materialization):**

- ACME EAB material moved from the plaintext `acme.eab_key_id` / `acme.eab_hmac_key` config fields
  into the `secret/acme/eab` Vault KV object (fields `key_id` / `hmac_key`), referenced by
  `Optional SecretRef` (`SecretRef.Vault`). `validateAcmeBinding` rejects plaintext EAB through the
  same `validateVaultRef` discipline used for `aws.*`.
- The non-secret EAB **key ID** is resolved host-side from Vault and rendered inline into the
  `zerossl-dns01` `ClusterIssuer`. The EAB **HMAC key** is materialized into the `cert-manager`
  namespace as the `acme-eab-credentials` Secret by a Vault-login materializer Job (the Sprint
  `3.18` chart-side materialization pattern — init container logs into Vault via Kubernetes auth on
  role/policy `acme`, reads `secret/acme/eab#hmac_key`, the main container creates the Secret). The
  HMAC key never transits the operator host and is never rendered as inline plaintext.
- ZeroSSL remains the sole public ACME provider; the single `zerossl-dns01` issuer and the S3 cert
retain-and-restore flow are unchanged — only the EAB / key material moves behind Vault.

The historical host-side key-ID resolution above is forbidden in the target architecture and is a
cutover-deletion surface; it is not a supported fallback for the typed Agent/config projection.

The required issuer split is recorded in [Vault design decisions](#18-vault-design-decisions):
cert-manager remains the public issuer, Vault sources the EAB/key material, and native Vault PKI is
the internal-cert authority. Implementation and live-issuance evidence belong only to the
Development Plan.

Sealed behavior: the typed key-ID projection is unavailable and the in-cluster materializer cannot
read the HMAC, so new issuance fails closed rather than proceeding. A sealed, unreachable, or
uninitialized selected Vault cannot produce the generation-bound projection/read-back; no host
resolver or cached config substitutes for it. The live "sealed Vault blocks issuance" proof is
operator-driven. This is an explicit availability/security trade-off.

## 12. In-cluster service auth

Each in-cluster component that needs secrets or encryption-as-a-service uses Vault Kubernetes auth
idiomatically: a Kubernetes service account; a Vault role bound to that namespace and service
account; a least-privilege Vault policy; authentication with the service-account JWT; and access
only to assigned KV paths or Transit keys. This is the **only steady-state service secret-retrieval
path**. The explicit Provisioner→Agent and TLS one-shot-worker linear ingresses carry bounded
plaintext only during an attested permit and cannot become config/workload retrieval paths. There
is no Secret-mounted plaintext Dhall fragment and no `FileSecret` reference (§3). Services
that authenticate to Vault include the Lifecycle Authority, Authority Backup Adapter, TLS
Retention Adapter, each Target Secret Agent, Gateway Runtime, Keycloak init/reconcile path,
certificate reconcilers, the fenced Provider Worker, and workloads
that need encryption-as-a-service. The Bootstrap Broker is the pre-unseal exception: it uses the
static bootstrap MinIO credential and only the bounded Vault sys endpoints required by its closed
request algebra. It receives no steady-state KV, generic Transit, lifecycle, or gateway policy.
Workloads use the Vault Agent Injector, CSI Secret Store Vault provider, or direct application-side
Vault auth according to chart ergonomics; see
[Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md).
`Prodbox.Secret.VaultInventory` is the policy/role inventory, and `Prodbox.Vault.Reconcile`
materializes it through Kubernetes auth. The control-plane identities are disjoint:

- the Lifecycle Authority may use only its config/lifecycle aggregate/blob Transit and HMAC keys
  plus its dedicated MinIO credential. It commits provider intents but cannot read an AWS secret;
  the separately resourced fenced provider worker alone reads the Lifecycle-provider identity;
- the separately deployed Authority Backup Adapter alone reads
  `secret/aws/authority-backup-store` and may use only the exact backup-prefix session. It cannot
  decrypt logical state, assume provider roles, or share the Authority/provider ServiceAccount;
- the separately deployed TLS Retention Adapter alone reads `secret/aws/tls-retention-store` and
  may use only exact registered `public-edge-tls/<substrate>/<fqdn>` sessions. It has no
  Authority-backup prefix, target Secret, Transit, DNS, IAM, or provider permission;
- a Target Secret Agent role is bound to one substrate and may read/CAS/read-back only its
  allowlisted schema and path, including `secret/data/keycloak/smtp`. Its exact seal-receipt policy
  may CAS/read receipts and invoke only the assigned Transit encrypt/decrypt key so it can resume
  receipt-named materialization in bounded memory. Plaintext seal/materialize work runs in a
  separately scoped one-shot worker; TLS Secret observe/seal/materialize uses exact Kubernetes RBAC,
  not generic Vault KV. Only the home Agent has a separate
  `transit/keys/prodbox-tls-envelope` generate/unwrap lane and a separately queued non-exportable
  retained-material custody/rewrap Transit lane. The latter accepts only closed `SesSmtpMaterial`
  and `AcmeEabMaterial` receipts and rewraps only to an attested selected Agent for exact
  `secret/keycloak/smtp` or `secret/acme/eab` materialization. An Agent cannot read
  provider/backup/TLS store credentials, lifecycle records, or arbitrary KV;
- the Gateway Runtime role may read only gateway event, journal-key-wrap, role-scoped config, and
  the dedicated Gateway-DNS generation. It
  receives no bootstrap bundle, lifecycle aggregate, Pulumi checkpoint, operator-write, or target
  secret policy;
- chart materializers and workloads retain one role per workload purpose rather than borrowing a
  control-plane role.

The same inventory owns generated/static/external KV seed policy, TokenReview configuration, and
the workload-specific Keycloak, MinIO, VS Code, Patroni, OIDC, certificate, and runtime roles.
Every materializer fails closed on sealed or unreachable Vault; none may widen a control-plane
role to solve a chart-delivery problem.

Authority-backup genesis and repair are the only pre-normal backup exceptions. A mode-indexed
Credential Provisioner accepts only a signed `GenesisBackupPermit`, `GenesisCleanupPermit`,
`RepairPermit`, or normally backup-receipted schema-indexed `OperatorMaterialPermit`; a distinct Admin Action Runner accepts only a committed
permit for explicit SES destroy, legacy backend migration/retained-store compatibility, or quota
request/status read-back. Prompt bytes and newly returned credential bytes arrive through authenticated linear
ingress, remain in bounded memory, and never enter a serializable program, Authority state, Vault,
disk, or logs. AWS-admin and externally supplied EAB frames have different decoders and cannot
share a Job/session. SMTP raw IAM-secret bytes remain only in Provisioner memory long enough to
derive `SesSmtpSource`; only that derived source enters retained-home Transit custody. The normal
Provider Worker accepts neither permit family.

For target-local/remintable operator material, the selected Target Secret Agent seals the bounded
payload and returns a receipt containing ciphertext plus an opaque Vault-keyed, domain-separated
HMAC commitment reference. SMTP and ACME EAB instead first seal a closed retained-home custody
source and rewrap it to selected Agents so a new target/Vault can be populated without re-prompt.
Lifecycle Authority persists only ciphertext digest, generation, that opaque commitment reference,
and outbox intent—never an unkeyed secret hash. Separate
material classes cover Operational Lifecycle-provider, LongLived TLS-retention/home Gateway-DNS/
home DNS01, Operational AWS DNS01, ACME EAB, and SMTP; Authority-backup installation remains on its
dedicated genesis/repair protocol. Install, rotate, and revoke are explicit, response loss is
resolved by operation ID/version, and IAM/key deletion precedes the Vault tombstone. The
pre-cutover `prodbox-operator-write` policy, two-entry Gateway route, shared
`secret/data/gateway/gateway/aws`, and host-root fallback are removed.

Here a Vault tombstone is an Authority lifecycle state, not KV-v2 soft deletion. Revoke,
supersession GC, `DestroyAwsSes`, and nuke enumerate the exact secret-bearing generation versions,
use KV-v2 destroy (or delete the exact per-generation immutable path), delete metadata only after
version destruction, and then prove metadata/version absence. Rotation may destroy only a
superseded generation after the bounded no-dependants proof and retention grace; current or
referenced target/custody generations fail closed.

The `vault_operator_password` needed before unseal and the ephemeral
`aws_admin_for_test_simulation` credential remain host-side and are never stored in Vault.
Physical Deployment, ServiceAccount, and capability-client separation is owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

### 12.1 Cached renewable Kubernetes-auth session (Sprint 1.64)

A component's own service-account Kubernetes-auth token is obtained through a **cached renewable
session** (`src/Prodbox/Vault/Session.hs`), not a fresh login per request. Counterexample
`LCPC-2026-07-11` traced a gateway hot-path CPU driver to exactly that per-request login. The
session:

- holds the token with a monotonic-clock expiry and **renews it single-flight at two-thirds of the
  lease**, so concurrent callers coalesce onto one login rather than stampeding Vault;
- re-reads the current service-account JWT on every refresh, so token/JWT rotation is honored;
- classifies outcomes as structured errors — `503` → sealed, `403` → forbidden/revoked, everything
  else → unavailable — and never widens a fail-closed state into fail-open;
- reacts to a downstream `403` (a server-side-revoked cached token while Vault stays unsealed) with
  **exactly one invalidate-and-relogin** via `withSessionToken`; a burst of concurrent `403`s on the
  same token still produces one relogin.

The token is never `Show`n and the session's diagnostics carry only the non-secret lease shape. This
is a runtime-transport optimization of the Kubernetes-auth path in §12; it changes neither the role
bindings, policies, nor the fail-closed invariant. An operator's per-request JWT exchange (for
example the operator-secret write route) is **not** cached — it is inherently per-request and leaves
the gateway with its authority route, not through this session.

## 13. Config and state classification

Every prodbox datum is classified explicitly.

| Class | Examples | Storage rule |
|---|---|---|
| **Public / non-secret** | Static chart names; non-cluster-revealing feature flags; public docs; non-sensitive local defaults; expected command topology; the unencrypted-basics bootstrap surface (§16) | May live in plain Dhall or logs |
| **Sensitive topology** | Downstream cluster names/endpoints/accounts; Pulumi stack identities (`aws-eks`, `aws-ses`, …) and their existence; the logical names and the *count* of prodbox-owned MinIO objects; the in-force config; generated downstream manifests; resource-graph/checkpoint state | Encrypted at rest; opaque-named + decoy-count-padded in the §9 object-store; unavailable when Vault is sealed |
| **Secret material** | Passwords; access keys; private keys; short-lived tokens; ACME EAB material; Keycloak client secrets; MinIO root credentials; Pulumi passphrases; child-cluster recovery shares; unseal/recovery material | In Vault, or in a Vault-encrypted envelope; retained public-edge TLS is ciphertext plus a retained-home-Transit-wrapped DEK in the exact S3 prefix. The root cluster's unseal/recovery material is in the unlock bundle. The initial root token is encrypted to the compiled/pinned, provenance-audited burn public key; prodbox has no corresponding private key and never decrypts/uses the ciphertext. Generated root sessions are memory-only and accessor-audited. |

## 14. Error model and logging

Typed Vault errors keep ordinary failures as structured control flow (conceptual,
`Prodbox.Vault.Client`):

```haskell
-- Example: Prodbox.Vault.Client
data VaultError
  = VaultUnavailable
  | VaultUninitialized
  | VaultSealed
  | VaultPolicyMissing Text
  | VaultSecretMissing SecretRef
  | VaultDecryptDenied Text
  | UnlockBundleMissing BootstrapObjectKey   -- absent at the fixed MinIO bootstrap key (§6.1)
  | UnlockBundleDecryptFailed                -- wrong operator password / corrupt AEAD body
  | BootstrapMinioUnreachable                -- cannot reach MinIO to fetch the bundle pre-unseal (§6.1)
```

Errors are operator-clear and never include secret values. Logging never emits SecretRef-resolved
values, unlock-bundle plaintext, Vault tokens, child-cluster init keys, Pulumi passphrases, object
plaintext, or downstream-cluster names on sealed-state failure paths when those names are
sensitive. The redaction extends to the §9 object-store and the whole-system surfaces:

- **No logical name on a sealed path.** Logs reference the opaque `objects/<hmac>.enc` layout, not
  the logical object behind it; a sealed-path log line never resolves an opaque ID to its logical
  name, a Pulumi stack identity (`aws-eks`), or a child-cluster name.
- **No object count.** A sealed-state log never emits a real prodbox-owned object count — the
  store is decoy-padded to a constant, and logs do not undo that by reporting the true count.
- **No exists-vs-absent oracle.** A sealed-state query for a logical object never distinguishes
  "present" from "absent" in its output or error — the exists-vs-`NoSuchKey` discriminator is
  itself metadata (§9 whole-system), so the redacted/gated result is identical either way. Sprint
  `4.33` gates the Haskell residue/listing translators and the retained-object `NoSuchKey`
  classifier behind the Vault-readiness check before interpreting a present/absent result.
- **Redacted `Show`.** Opaque-id and token types carry a redacted `Show` so an opaque ID or a
  Vault token never reaches a log through an incidental `show` (Sprint `4.33`). Target federation
  custody shapes contain only encrypted recovery material plus non-secret generation/accessor
  attestations, and redact those fields. Historical child/root-token-shaped records remain
  migration residue; the target never creates or returns them.

Prefer redacted structured logs:

```text
vault_status=sealed component=pulumi operation=preview result=blocked
```

over identifying messages such as `Cannot deploy downstream cluster prod-eu-west-1 …` or
`object aws-eks not found`. The no-name-in-logs and exists-vs-absent-oracle rules are cross-linked
from the output doctrine — see
[streaming_doctrine.md](./streaming_doctrine.md).

## 15. Sealed-state behavior matrix

When Vault is sealed, each surface fails closed:

| Surface | Sealed-Vault behavior |
|---|---|
| In-force config (MinIO envelope) | Unreadable; Lifecycle Authority, Provider Worker, Backup Adapter transition lane, Target Secret Agent, and Gateway Runtime remain blocked; only the unencrypted basics remain legible (§16) |
| Every previously-derived secret (now Vault KV) | Not resolvable; no secret can be produced from any non-Vault source |
| Pulumi (`aws stack ...`) | Refuses before preview/update/destroy; no AWS mutation attempted |
| AWS deployment credentials | Not obtainable |
| Keycloak bootstrap / secret-dependent startup | Init/readiness fail closed; new Pods do not reconstruct secrets from k8s Secret plaintext |
| Ingress/Envoy TLS | Retention/restore/home-DEK exchange and new issuance fail closed; TLS Adapter ciphertext alone cannot reconstruct plaintext |
| Downstream-cluster inventory and custody | Not extractable from MinIO, ConfigMaps, Secrets, Pulumi backends, or logs |
| Child clusters (federation) | Cannot auto-unseal against a sealed parent; the brick cascades down the tree (§16) |

The sealed-Vault canonical validation seals Vault after a full reconcile and proves every row
above fails closed without leaking metadata. The bootstrap-boundary validation additionally proves
that only the Bootstrap Broker can perform pre-unseal requests and rejects Gateway Runtime,
host-direct MinIO/Vault/root-token, lifecycle-CAS, and target-secret fallback traces. Evidence and
deployment-qualification status are tracked only in the Development Plan.

## 16. Cluster federation: a Vault transit-seal trust tree

prodbox manages a hierarchy of clusters — a root cluster and zero or more downstream/child
clusters. Trust, unseal authority, and config authority form a tree. This section summarizes the
contract;
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md) is the SSoT for the topology,
the auto-unseal mechanics, and the custody and config-authority flows.

### The transit-seal trust tree

| Tier | Vault seal mode | Who unseals it | Durable recovery material owned by |
|---|---|---|---|
| **Root cluster** | Shamir | Operator only, via the password-AEAD-sealed unlock bundle in durable MinIO, decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests; §4, §6, §6.1) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

- A child Vault literally cannot unseal without a live, unsealed parent. If any parent is
  sealed/unreachable, its children cannot unseal → the fail-closed brick cascades down from the
  root. Cluster liveness for the whole tree roots in one operator unsealing the root (§2,
  invariant 7).
- **Parents own the recovery material for child clusters.** At child init, the child's recovery
  shares and token-revocation attestation are delivered by generation CAS to the parent's Vault KV
  (under the `transit/prodbox-downstream-cluster-config` blast-radius domain; §8); the initial root
  token is revoked and never stored. The parent's transit key is the child's unseal authority. The
  root cluster's own recovery shares are the only ones held outside
  Vault — in the password-AEAD-sealed unlock bundle in durable MinIO (§6, §6.1, the chicken-and-egg
  floor; §17).
- A cluster's knowledge of its child clusters (their existence, identities, endpoints,
  kubeconfigs, account IDs, Pulumi stacks) is **secret data** — only legible behind an unsealed
  Vault (§13, sensitive topology).

### Config SSoT inversion and generation-CAS authority

- The **in-force cluster configuration** is stored in MinIO as an immutable
  Vault-Transit-enveloped blob (§9). The Lifecycle Authority aggregate's
  schema/generation/digest/reference plus that exact blob are the source of truth. When Vault is sealed it is opaque
  ciphertext: nothing about the cluster's setup or its child clusters is determinable beyond the
  unencrypted basics.
- **Unencrypted basics** = the minimal, non-revealing bootstrap needed only to reach and unseal
  Vault: cluster id, this cluster's Vault address, seal mode, and (for a child) the parent
  reference it must contact to auto-unseal. Nothing about workloads, downstream clusters, or
  credentials. The basics are the only thing legible from `prodbox.dhall` and from a
  sealed cluster.
- The filesystem seed/propose role now lives in the binary-sibling `prodbox.dhall`, not the
  retired repo-root `prodbox-config.dhall` (§4). On first-ever bring-up it submits a visible
  absent-generation proposal; thereafter supplying a file is a *proposed update*. The prior host-CLI model of
  reading repo-root `prodbox-config.dhall` directly as the live config is replaced by "read the
  basics locally, resolve Lifecycle Authority, and observe the role-scoped in-force config
  generation" (the direct MinIO/Vault loader from Sprint `1.38` is pre-cutover legacy), with
  Sprint `1.42` moving the seed/propose payload into Tier-0 `prodbox.dhall`. The Sprint `1.38`
  local foundations and global host-loader switch are landed
  (`loadUnencryptedBasics`, `decodeConfigDhallBytes`, MinIO envelope get/put, injected
  fetch/open/decode + seal/store, and `loadConfigForSettingsWith`).
- Updating the root cluster's in-force config requires a short-lived `prodbox-config-admin`
  TokenRequest proof, the exact Lifecycle Authority `ConfigProposeCas` reference, expected config
  generation, and immutable encrypted blob read-back. Root config governs every downstream
  cluster; no caller receives a root token or MinIO credential, and stale/corrupt/unobservable
  state refuses.

The typed parent-custody capability registers a child, stores its recovery material and
revoked-token attestation, and reads the
allowlisted bootstrap reference through a dedicated Vault Kubernetes-auth identity. The Gateway
Runtime may consume only the bounded, redacted federation projection required for peer membership;
it does not expose child-custody or generic Vault listing endpoints. The transit-seal hierarchy,
direct parent-side writer, auto-unseal cascade, and sealed-state redaction must preserve this
boundary. See
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

## 17. The chicken-and-egg floor

Vault owns everything except the minimal floor it cannot bootstrap itself from. The **only** data
Vault may not own:

1. RKE2's self-signed cluster CA + admin kubeconfig (Vault runs inside this cluster's PKI).
2. The Vault PV binding itself.
3. **Root cluster only:** the operator unseal-bundle password (the sole operator-memorized
   bootstrap secret, and the key
   that unseals the root Vault). The password-AEAD-sealed pre-init `PreparedInitEnvelope` and final
   unlock bundle live in durable MinIO, not host disk (§6); they are not Vault-owned objects — they
   establish and then *unseal* Vault. Their bodies are password-AEAD-sealed, so the password remains
   the genuine off-box floor regardless of the static MinIO credential that gates their ciphertext
   (§6.1).
4. **Child cluster only:** the bootstrap reference + transit-seal credential the child uses to
   reach its parent's Vault to auto-unseal — itself provisioned and owned by the parent (§16).

Everything else — MinIO root creds, all derived-then-now-KV secrets, ACME EAB, AWS creds, SES,
OIDC, the in-force config, Pulumi state, and child-cluster custody — is Vault-owned or
Vault-enveloped. Public-edge TLS follows §11's exact-Secret/Agent encryption path and is retained
only as ciphertext plus a retained-home-Transit-wrapped DEK.

## 18. Vault design decisions

These are doctrine contracts. Migration and verification status belong only to the Development
Plan.

| # | Decision | Contract |
|---|----------|----------|
| 1 | Vault storage backend | Integrated storage on the retained `.data/vault/vault/0` PV; file storage is acceptable for development. Teardown never destroys Vault state and `init` never reruns (§5). |
| 2 | Init and root-session custody | Before `/sys/init`, read back a password-AEAD `PreparedInitEnvelope` containing the generated share-recipient private key and exact transaction/storage fingerprints. Persist/read back Vault's PGP-encrypted response, atomically promote the final unlock bundle, then delete/read back the prepared envelope. Encrypt Vault's initial root token to the compiled/pinned, provenance-audited burn public key; prodbox never generates, stores, accepts, or accesses its private key and never decrypts/uses the token ciphertext. Use only separately generated, operation-PGP-encrypted short-lived root sessions for baseline/break-glass; inventory stale accessors, repair/read back, revoke, and observe absence (§6, §16). |
| 3 | Opaque object names / indexes | Model B encryption (§9): capability-owned accessors share one pure envelope codec, opaque `objects/<vault-keyed-HMAC>.enc` names, Vault-encrypted indexes, hashed stored AAD, decoy count, and size buckets. Sharing the format grants no cross-capability authority. |
| 4 | Pulumi encrypted-backend approach | Decrypt-to-scratch interposition (§10): a fenced provider worker hydrates RAM-tmpfs `file://` state, runs Pulumi with no passphrase, writes an immutable encrypted blob, and commits its digest through the Lifecycle Authority aggregate. |
| 5 | TLS private-key custody and retention | cert-manager remains the public-edge issuer. The selected Agent encrypts exact TLS Secret bytes locally with a DEK supplied through the retained home Agent's `prodbox-tls-envelope` Transit lane; the TLS Retention Adapter stores ciphertext only under exact registered prefixes. Native Vault PKI remains the internal-cert authority (§11). |
| 6 | Fail-closed strictness for running workloads | Already-running workloads continue only while they need no new Vault operation; security-sensitive paths fail their capability/readiness gate rather than reconstructing a fallback (§2). |
| 7 | Federation depth + child-registration surface | Parent custody uses a dedicated typed Vault capability. Gateway Runtime receives only the bounded peer projection and exposes no child-secret listing or bootstrap proxy (§16). |
| 8 | In-force config ownership | Lifecycle Authority owns `ConfigObserve`/`ConfigProposeCas`, immutable encrypted config blobs, and the aggregate generation/digest/reference; host and Gateway direct object access is removed. |
| 9 | AWS identity split | Operational Lifecycle-provider/AWS-DNS01 and LongLived Authority-backup, TLS-retention, home Gateway-DNS/home-DNS01 identities use separate IAM resources, Vault paths/policies/generations, consumers, and lifecycle-class-correct cleanup nodes. Provider Worker owns only non-credential SES/S3; Credential Provisioner owns SMTP desired-present/repair; exact `DestroyAwsSes` owns registered terminal SES+SMTP absence. Credential Provisioner, Admin Action Runner, Provider Worker, Backup Adapter, and TLS Adapter are physically and cryptographically disjoint. |
| 10 | Retained cross-substrate operator material | The retained home Agent Transit-seals only the closed SMTP/EAB source schemas, then rewraps an exact current receipt to an attested selected Agent. Authority sees ciphertext/receipts only. AWS-admin and external-EAB ingress are distinct; raw IAM secret bytes never enter custody. Current receipts restore new targets/fresh AWS Vault, and target tombstones precede custody tombstones. |

## 19. Red-team checklist

Deployment qualification must prove every item below. Evidence and closure status belong only to
the Development Plan:

- A repo grep finds no real secret in Dhall, and no `FileSecret` / Secret-mounted Dhall fragment
  consumer remains.
- A generated cluster-manifest grep finds no real secret and no chart-generated
  `lookup`+`randAlphaNum` Secret.
- A Kubernetes Secret dump reveals no downstream-cluster metadata or Vault-bypass credential, and
  no ConfigMap, Secret, or namespace name encodes a child-cluster name (k8s leaks no child name;
  §9 whole-system).
- A MinIO bucket dump while Vault is sealed reveals no in-force-config or Pulumi plaintext, and no
  `master-seed` object exists at all.
- The root bootstrap namespace contains only the bounded init transaction objects (§6): a
  password-AEAD `PreparedInitEnvelope` while initialization is unfinished, Vault's PGP-encrypted
  response receipt, and the promoted password-AEAD unlock bundle. A bucket dump recovers no
  recipient private key or unseal share without the operator password, and the namespace is
  decoy-count-padded so it reveals only “this is the root cluster,” never a workload, downstream
  cluster, or count signal. Child clusters have no such objects.
- A bucket-level `s3api ls` while Vault is sealed reveals one generically-named bucket — neither
  the retired `prodbox` nor `prodbox-test-pulumi-backends` role-revealing name survives (§9).
- Object names and indexes reveal no downstream-cluster inventory: every object is
  `objects/<hmac>.enc` under one flat prefix (opaque-name layout), the `indexes/*.enc` map is
  itself a sealed envelope, and no `aws-eks`/stack-named or otherwise logical key exists (§9).
- A sealed-Vault `list-objects` returns a **constant** object count — decoy-padding hides how many
  real objects exist — and the bodies are size-bucketed, so neither count nor length leaks (§9).
- No exists-vs-absent oracle: a sealed-Vault query for a logical object cannot distinguish
  "present" from "absent" (the exists-vs-`NoSuchKey`/`stackPresentInList` discriminator is gated
  behind the readiness check; §9, §14; the Haskell-side gate landed in Sprint `4.33`).
- A raw host-disk walk of `.data/prodbox/minio/0` while Vault is sealed reveals only opaque-named
  ciphertext at a constant count—no plaintext name, body, or count—save the bounded fixed bootstrap
  keys for the root prepared/encrypted-response/final-bundle transaction, whose secret-bearing
  bodies remain password-AEAD or PGP ciphertext and whose presence is decoy-count-padded (§6.1,
  §9; Haskell-side gates landed in Sprint `4.33`; deployed proof is Sprint `5.8`).
- The object body stores a **hashed** AAD (`prodbox-envelope-v2`, `base64(SHA256(aad))`); a sealed
  envelope never contains a cleartext binding such as `aws-eks` (§8, §9; Sprint `4.30`).
- Sealed Vault blocks Pulumi before any preview/update/destroy starts.
- Sealed Vault blocks Lifecycle Authority, its Provider/Backup/TLS lanes, Target Secret Agent,
  Gateway Runtime config recovery, Keycloak bootstrap/recovery, and TLS private-key reconstruction,
  and prevents every child cluster from auto-unsealing.
- A child cluster cannot unseal while its parent is sealed/unreachable.
- Test-harness plaintext is isolated to `test-secrets.dhall` and never used by production paths.
- The unlock-bundle password is handled by KDF + authenticated encryption, not raw SHA-256.
- First init cannot run until the exact password-AEAD `PreparedInitEnvelope` and recipient/burn
  fingerprints are read back. Crash after a captured PGP-encrypted init response resumes final
  bundle promotion after re-prompt; crash with possible init but no durable response fails closed
  except for the proven-pristine storage-generation reset path. The prepared envelope is deleted
  and its absence read back only after the final bundle is promoted and decrypt-verified.
- Init and unseal prompt bytes reach only their separately attested one-shot Broker worker over
  authenticated exec/attach stdin; the controller sees metadata/receipts, and worker revocation,
  exit, and Pod absence are read back after success or failure.
- The unlock-bundle password is the only operator-memorized secret; its only cleartext home is
  `test-secrets.dhall`, and no production path stores or logs it.
- No recovered plaintext secret lands on a physical-disk-backed path, and every secret-bearing
  service-to-MinIO transfer uses TLS.
- The initial Vault root token is compiled/pinned burn-key ciphertext that prodbox never decrypts or
  uses and for which it never generates, stores, accepts, or accesses a private key; every generated root session
  is accessor-inventoried, revoked, and observed absent. `vault init` never reruns against
  established state; an ambiguous reset is permitted only for the exact proven-pristine storage
  generation with no durable init receipt or baseline (§5–§6).
- Updating the in-force config requires a config-admin proof plus exact generation CAS/read-back;
  no host or Gateway path receives a Vault root token or MinIO credential.
- Provider, Authority-backup-store, TLS-retention-store, Gateway-DNS, and cert-manager-DNS01
  credentials are distinct IAM/Vault generations with consumer-lifetime lifecycle classes; the
  shared `secret/gateway/gateway/aws` path and cross-role fallback are absent. Ordinary suite
  cleanup removes only Operational provider/AWS-DNS01 generations and retains the LongLived set.
- No Authority record, receipt API, output, or log exposes an unkeyed secret hash.
  Duplicate detection uses only opaque, domain-separated Agent/Vault keyed-HMAC commitment
  references and performs equality inside the Agent receipt fold.
- TLS restore survives AWS Vault/EBS recreation through the retained home Transit wrapping key;
  the TLS Adapter sees ciphertext only, not-yet-valid/uncertain time fails closed, and TLS-prefix
  deletion cannot delete the shared bucket.
- Current retained-home SMTP and EAB custody receipts populate a newly introduced target and restore
  fresh AWS Vault/EBS without remint/re-prompt; schema mismatch, missing/corrupt/unobservable source,
  raw-IAM-secret custody, host-direct EAB key-ID reads, and custody tombstone before every target
  tombstone are rejected.
- Cluster teardown preserves the Vault and MinIO PVs; cluster recreate cannot recover secrets
  without unsealing Vault — and is not a fresh Vault (unseal-on-rebuild; §5).

The forbidden golden-output patterns for the SecretRef / sealed-state golden tests (Sprint `5.8`)
include `AKIA`, `aws_secret_access_key`, `BEGIN PRIVATE KEY`, `client_secret = "…"`,
`password = "…"`, Pulumi passphrase strings, kubeconfig user tokens, `SecretRefFile`, removed
gateway `/v1/secret/*` RPC paths, child names, and stack names such as `aws-eks`. The pure
sealed-state audit helper is landed; the full generated-artifact SecretRef sweep remains part of
Sprint `5.8` closure.

## Cross-References

- [config_doctrine.md](./config_doctrine.md) — the single-Dhall-file contract; under this
  doctrine the file is a seed/propose input carrying `SecretRef` values and the unencrypted
  basics, not the in-force SSoT
- [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) — the root/child transit-seal
  trust tree, parent custody of encrypted child recovery material plus revocation attestations,
  downstream-cluster metadata as secret, and the generation-CAS config authority
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the retired master-seed HMAC
  derivation model, repurposed to map each secret to its Vault KV/PKI/Transit path
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained `.data/` PV
  layer that holds the durable Vault PV; init-once / unseal-on-rebuild
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — cluster
  reconcile/teardown integration and the sealed-state readiness gates
- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) — physical
  Bootstrap Broker, Lifecycle Authority, Provider Worker, Backup/TLS Adapters, Target Secret Agent,
  one-shot Credential Provisioner/Admin Action Runner, and Gateway Runtime boundaries
- [envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md) — the public-edge TLS path
  that fails closed under a sealed Vault
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — chart-secret consumption
  via Vault Kubernetes auth only (no Secret-mounted Dhall fragment)
- [acme_provider_guide.md](./acme_provider_guide.md) — the ZeroSSL public-cert + S3 retain-restore
  contract whose ACME EAB material and key material move behind Vault
- [aws_admin_credentials.md](./aws_admin_credentials.md) — prompted elevated AWS material used and
  discarded; prodbox-created AWS identities live in Vault KV
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) — the AWS
  substrate environment whose prodbox-created identities resolve via `SecretRef.Vault`
- [cli_command_surface.md](./cli_command_surface.md) — the `prodbox vault` command group
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — implementation status,
  migration order, and deployment-qualification evidence
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the retired master-seed derivation model, the removed FileSecret /
  Secret-mounted Dhall path, the host-CLI direct-config-read model, and the folded-in
  `VAULT_REFACTOR.md` proposal
</content>
