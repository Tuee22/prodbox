# Vault Secret-Management Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[../../README.md](../../README.md),
[config_doctrine.md](./config_doctrine.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
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
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md)
**Generated sections**: none

> **Purpose**: Single source of truth for Vault as the sole, fail-closed secrets,
> key-management, encryption-as-a-service, and PKI root of every prodbox-managed cluster — the
> SecretRef configuration contract, the password-AEAD-sealed unlock bundle in durable MinIO and
> the bootstrap MinIO credential that reaches it before unseal, Vault Transit envelope
> encryption of MinIO and Pulumi state, the init-once / unseal-on-rebuild durability model, the
> cluster-federation transit-seal trust tree, the sealed-state brick invariant, and in-cluster
> Vault Kubernetes auth.

## 1. Why this doctrine exists

prodbox manages an intentionally ephemeral cluster: the Kubernetes runtime may be destroyed and
recreated while `.data/`-backed persistent volumes survive and rebind on the next spin-up (see
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)). Before this doctrine, secret
material lived in three uneven places: plaintext fields inside the operator-authored
`prodbox-config.dhall` (AWS keys, ACME EAB material), plaintext Dhall fragments mounted from
k8s Secrets, and an unencrypted master-seed object in MinIO that any holder of the bucket
credential could read, with every per-namespace secret HMAC-derived from that seed. A `.data/`
snapshot, a MinIO dump, or a Kubernetes Secret export revealed everything prodbox knows —
including the inventory of any downstream cluster prodbox manages.

**Vault is now the sole secrets root.** It is the only secrets/credential/key/cert backend the
stack has: every such datum is a Vault object (KV v2 secret, Transit key, or PKI-issued cert).
There is no second store and no plaintext fallback. Every secret-bearing artifact prodbox
persists outside Vault — MinIO objects, the Pulumi backend state, the in-force cluster
configuration — is stored only as a Vault-Transit envelope. The operator-authored Dhall holds
**references** to secrets, never secret values.

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
- The **single-Dhall-file config contract** ([config_doctrine.md](./config_doctrine.md))
  changes posture: the in-force cluster configuration is a Vault-Transit-enveloped MinIO object
  (the SSoT), and a filesystem `prodbox-config.dhall` is a seed/propose input only. The file's
  sensitive fields are typed `SecretRef.Vault` references — no plaintext secret value, and no
  `FileSecret` arm (§3, §4; [cluster_federation_doctrine.md](./cluster_federation_doctrine.md)).
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
  clusters, where a child Vault auto-unseals against its parent and the parent owns the child's
  init keys (§16).

The architecture below is the finalized target. Where this doctrine prescribes behavior the
worktree does not yet honor, it names the owning sprint; until that sprint lands the statement is
the intended structure, not a present-tense implementation fact. Adoption is **phase-independent**
per the development-plan phase-independence doctrine (development_plan_standards.md Standards N /
O): each surface's adoption closes on its **own** owned-surface sprint once that sprint builds and
passes local validation (`prodbox dev check`, `test unit`, `test integration cli`/`env`); a proof
that needs live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an
operator-supplied credential) is tracked separately as a non-blocking `Live-proof: pending` note
and never gates a sprint's code-owned closure. No earlier phase is blocked by a later phase — a
`Blocked by` may name only an earlier-or-same-phase sprint or an external prerequisite. See the
[Development Plan](../../DEVELOPMENT_PLAN/README.md) Closure Status entry for the Vault-root
finalization and the per-surface owning sprints (`0.13`, `0.14`, `0.15`, `1.35`–`1.38`, `2.26`,
`3.17`–`3.20`, `4.29`–`4.33`, `5.8`, `7.14`–`7.16`, `8.9`).

## 2. The fail-closed invariant

The load-bearing requirement of the entire model: **a sealed Vault bricks the cluster.**

> A sealed (or unreachable, or uninitialized) Vault reduces prodbox to an opaque durable-data
> pile. PVs and MinIO objects may still exist, but they reveal no secrets, no in-force config, no
> Pulumi state, and no downstream-cluster inventory until Vault is unsealed.

Stated as hard architectural invariants — not implementation preferences:

1. **Sole-backend invariant.** Every secret/credential/key/cert is a Vault object. There is no
   second store and no plaintext fallback. No secret reconstructs from any non-Vault source (§3,
   §9).
2. **Dhall invariant.** `prodbox-config.dhall` never contains a plaintext secret value; sensitive
   fields are `SecretRef.Vault` references only (§3).
3. **Cluster-metadata-is-secret invariant.** Downstream-cluster names, endpoints, kubeconfigs,
   account IDs, DNS names, Pulumi stack identities, and the in-force config are secret data; a
   sealed Vault makes them unrecoverable from MinIO, Kubernetes Secrets/ConfigMaps, Pulumi
   backends, logs, or generated files (§9, §13, §16).
4. **Sealed-state invariant.** When Vault is sealed, no secret resolves, no cert issues, no MinIO
   object decrypts, no Pulumi op runs, and the gateway daemon and Keycloak fail their readiness
   gates (§15). There is no degraded mode that leaks.
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

`prodbox-config.dhall` **may** contain: non-secret topology; public, non-sensitive endpoint
names; Vault mount names; Vault policy intent; logical `SecretRef` values; the unencrypted-basics
bootstrap surface needed to reach and unseal Vault (cluster id, this cluster's Vault address, seal
mode, and — for a child cluster — the parent reference it must contact to auto-unseal; see §16 and
[config_doctrine.md](./config_doctrine.md)).

`prodbox-config.dhall` **must not** contain: AWS access keys; ACME EAB HMAC material; TLS private
keys; MinIO root credentials; Keycloak admin passwords or client secrets; Pulumi passphrases or
stack secrets; downstream-cluster kubeconfigs; downstream-cluster hostnames, IPs, account IDs, or
identities that reveal managed-cluster inventory; or any plaintext material needed to unseal,
authenticate to, or decrypt Vault-protected state.

## 4. Config split: production references vs test plaintext

Two files, one rule each:

| File | Content | Consumed by |
|---|---|---|
| `prodbox-config.dhall` | Production-safe topology, the unencrypted basics, and `SecretRef` values only — a seed/propose input, not the in-force SSoT (§16). NO plaintext secrets; NO `aws_admin_for_test_simulation` block | Every supported binary, host and in-cluster |
| `test-secrets.dhall` (Sprint `1.43`; formerly `test-config.dhall`) | All test-only plaintext that simulates operator prompts and seeds fixtures — the Vault unlock-bundle password (simulates the unseal prompt) and the `aws_admin_for_test_simulation.*` elevated-AWS credentials (simulates the elevated-credential prompt) among them | The test harness only |

`test-secrets.dhall` may carry the Vault unlock-bundle password used by tests (which simulates the
operator entering the password at the unseal prompt; §6), the `aws_admin_for_test_simulation.*`
elevated AWS credentials that simulate the operator typing the elevated/admin credential at the
`SecretRef.Prompt` arm, fake ACME/EAB values, fake MinIO credentials, fake Keycloak bootstrap
passwords, and fixtures used to seed Vault in integration tests. None of these testing secrets live
in Vault — Vault holds production secrets only. `test-secrets.dhall` must never be required for
production, imported by `prodbox-config.dhall`, copied into generated cluster config, stored in
MinIO, mounted into the cluster, or committed with real values; it has no production role. It is the
only cleartext home of the root operator's memorized unseal password (§6, §16) and the only home of
the `aws_admin_for_test_simulation.*` test fixture (a test-harness fixture, not a production-config
section or a Vault object; see [aws_admin_credentials.md](./aws_admin_credentials.md) for the block
specifics).

## 5. Vault deployment model and durability

Vault runs **inside** the prodbox-managed cluster as a platform component, on the same footing as
MinIO, Harbor, MetalLB, Envoy Gateway, cert-manager, and the Percona PostgreSQL operator. It is a
normal in-cluster Helm release (`charts/vault/`) on the same ephemeral-PVC / retained-PV pattern
as everything else, and it appears in the shared `[PlatformComponent]` inventory so **both**
substrates (home + AWS) stand it up identically (substrate equivalence; see
[substrates.md](../../DEVELOPMENT_PLAN/substrates.md) and Sprint `3.17`).

Requirements:

- A single Vault instance per prodbox-managed cluster.
- A durable PV backed by `.data/` (`.data/vault/vault/0`, `manual` StorageClass, `Retain`,
  single-node affinity), preserved across cluster teardown exactly like MinIO's PV. Cluster
  teardown must not destroy Vault state (see
  [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)).
- The Vault chart defaults to root Shamir mode. Child clusters set `seal.mode = transit`, render a
  `seal "transit"` stanza pointing at the parent Vault, and source the parent Transit token from
  `VAULT_TOKEN` rather than from the ConfigMap.
- Startup readiness gates that distinguish: not deployed; deployed but uninitialized; initialized
  but sealed; initialized and unsealed; policy reconciled.

### Init-once / unseal-on-rebuild

The cluster is ephemeral; its storage is **not**. Vault KV is therefore as durable across rebuilds
as any retained PV:

- `vault init` runs **exactly once, ever** — the first time the PV is empty. Root Shamir init uses
  `secret_shares` / `secret_threshold` and writes the resulting unseal material to the
  password-AEAD-sealed unlock bundle in the durable MinIO bucket (§6) — not to host disk. Child
  Transit init uses `recovery_shares` / `recovery_threshold` and writes the resulting recovery keys
  plus initial root token to the parent's Vault KV (§16). Init is never rerun against existing state.
- Every subsequent `cluster reconcile` redeploys the Vault chart against the existing data and
  only **unseals** it. No re-init, no key regeneration. **A cluster rebuild is not a fresh Vault.**

Acceptable storage modes are Vault integrated storage on the retained PV or file storage on the
retained PV for development. The exact backend is not load-bearing; the load-bearing property is
that cluster teardown never destroys Vault state and `init` never reruns.

```text
.data/
  prodbox/
    minio/0/                     durable MinIO StatefulSet PV — ciphertext objects only (§9),
                                 incl. the password-AEAD-sealed unlock bundle at the fixed
                                 bootstrap key — ROOT cluster only (§6, §6.1, §9)
  vault/
    vault/0/                     durable Vault StatefulSet PV, preserved across cluster wipe
```

The unlock bundle is **not** a host-disk file. It is a password-AEAD-sealed object in the durable
MinIO bucket (§6, §9); host disk holds no Vault recovery material. The Vault PV
(`.data/vault/vault/0`, `Retain`) is still preserved across cluster wipe exactly as above —
moving the bundle into MinIO does not change the Vault PV's durability contract.

## 6. The unlock bundle (root cluster)

The root cluster's Vault uses **Shamir** seal mode: the operator is the only one who can unseal
it. Initialization happens once and produces unseal/recovery keys plus the initial root token.
prodbox captures that material exactly once and immediately writes it to a password-AEAD-sealed
**unlock bundle** stored in the **durable MinIO bucket** — not on host disk — then never prints raw
keys or the root token to logs. (A child cluster's Vault uses `seal "transit"` against its parent
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

The operator password is the **sole ephemeral secret**: it derives both the AEAD key that seals
the bundle body and (via §6.1) the bootstrap MinIO credential that can fetch that object before
Vault is reachable. Nothing about the bundle touches host disk.

Conceptual plaintext (before encryption) — the stored bundle object is always ciphertext:

```json
{
  "cluster_id": "...",
  "vault_address_hint": "...",
  "created_at": "...",
  "unseal_keys": ["..."],
  "recovery_keys": ["..."],
  "initial_root_token": "...",
  "format_version": 1
}
```

The bundle backend is pluggable behind a single interface (the password-AEAD-sealed MinIO object
today; 1Password, pass/gopass, cloud KMS, YubiKey/age identity, or a TPM-backed host secret
later). The initial root token is bootstrap-only: prodbox creates named admin roles/tokens and
rotates or revokes the initial root token out of the steady-state admin path (an [open design
decision](#18-open-design-decisions)).

### The unlock chain

The operator's unlock-bundle password is the **single ephemeral root of trust** for the root
cluster — and, through the transit-seal tree, for every cluster beneath it. It is supplied at the
CLI unseal prompt, used in memory, and never persisted:

```text
operator CLI password
  -> KDF-derived bootstrap MinIO read credential (§6.1)
  -> fetch the password-AEAD-sealed unlock bundle from the durable MinIO bucket (fixed key; §6.1, §9)
  -> Argon2id + ChaCha20-Poly1305 authenticated decryption of the bundle body
  -> recover the root Vault's unseal/recovery keys (held only inside the bundle)
  -> submit the unseal keys -> UNSEAL THE ROOT VAULT
  -> the unsealed root Vault's Transit keys decrypt the in-force config envelope, the gateway
     state, and the Pulumi backend (§8, §9, §10), and serve as the transit-seal authority that
     auto-unseals child clusters (§16)
```

The password therefore does **not** encrypt secrets directly — it decrypts the unlock bundle that
holds the root Vault's unseal keys, and an *unsealed Vault* is what decrypts and serves everything
else. The consequences:

- A **sealed Vault** — no operator password entered this boot — leaves the in-force config, the
  gateway state, and the Pulumi backend as ciphertext, and leaves every child cluster unable to
  auto-unseal, exactly per the fail-closed invariant (§2) and the federation cascade (§16).
- The password is the only secret the operator memorizes; Vault's actual unseal keys are
  machine-generated and live only inside the encrypted bundle.
- The password's **only cleartext home is `test-secrets.dhall`**, read solely by the test harness
  to simulate the operator at the unseal prompt (§4); no production path stores or logs it.

### 6.1 Bootstrap MinIO credential

Because the unlock bundle lives in MinIO rather than on host disk (§6), prodbox must reach a MinIO
object *before* Vault is unsealed — yet MinIO's steady-state root credentials are themselves a
Vault KV secret (§9, §13). The bootstrap path that resolves this is a **password-derived bootstrap
credential**, scoped to exactly that one fetch:

```text
operator password
  -> KDF (Argon2id; the same memorized password, distinct derivation context/salt from the
     bundle-body AEAD key)
  -> a scoped bootstrap MinIO READ credential
  -> read-only GET of the fixed-key unlock-bundle object in the durable bucket (§9)
```

This bootstrap credential is **not** a Vault-Transit handle and resolves no Vault path — by
construction it must work while Vault is sealed. It is read-only and scoped to the single
fixed-key bootstrap object, so it cannot read the opaque-named, Vault-Transit-enveloped Tier-2
operational objects (§9) even if leaked; those still require an unsealed Vault. The operator
password remains the sole ephemeral secret (§6): one password derives both the bundle-body AEAD
key and this bootstrap MinIO credential.

**Bootstrap reorder.** Reaching the bundle before unseal means **MinIO must be reachable before
Vault unseal**, which inverts the historical `cluster reconcile` ordering (Vault first, then
MinIO; §7). The reconcile sequence therefore brings MinIO up to a bootstrap-readable state ahead
of the unseal step, then proceeds with Vault deploy → init-if-empty → fetch+decrypt the unlock
bundle → unseal. This bootstrap reorder is staged together with the **MinIO-root-decoupling
reorder** — decoupling MinIO's own steady-state root credentials from the unseal path so MinIO can
serve the bootstrap read before Vault is unsealed — which is sequenced **last** among the bootstrap
reorders so the rest of the model lands against the current ordering first.

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

- `vault init` connects to the in-cluster Vault, returns success unchanged if already
  initialized (init-once; §5), otherwise initializes Vault, captures unseal/recovery keys and the
  initial root token exactly once, writes the encrypted unlock bundle (root) or stores them in the
  parent's Vault KV (child; §16), and prints no raw key material (an optional
  `--show-sensitive-once` operator-confirmed flag may display it once).
- `vault unseal` reads the unlock bundle, prompts for the bundle password (unless the test harness
  supplies it), decrypts in memory, submits unseal keys, verifies Vault is unsealed, and clears
  sensitive material from process memory where practical. Plaintext unseal keys are never
  persisted. A child cluster auto-unseals against its parent's transit key with no human prompt
  (§16).
- `vault reconcile` requires Vault initialized and unsealed, then idempotently reconciles auth
  mounts, policies, roles, KV mounts, Transit keys, PKI mounts and issuers, Kubernetes
  service-account auth for in-cluster workloads, the MinIO bucket encryption policy metadata, and
  the Pulumi encryption configuration. It is safe to run on every cluster spin-up.
  The current Sprint `1.36` native foundation applies the baseline `secret` KV v2 / Transit / PKI
  mounts, Kubernetes auth, per-domain Transit keys, and baseline policies/roles through
  `Prodbox.Vault.Reconcile`; it also wires unlock-bundle re-encryption, Transit-key rotation, PKI
  mount status, and a PKI test-issue call against the later-configured `prodbox-test` role.
  Chart-by-chart Vault-auth adoption, PKI issuer generation, and child-custody workflows land in
  their owning later sprints (§12, §16, §18).

Lifecycle integration into `prodbox cluster reconcile` is split by cluster role: Sprint `4.29`
lands the root/local deploy, init-if-empty, unseal, and policy reconcile sequence; Sprint `4.32`
adds the child-cluster Transit-seal branch, parent-readiness fail-closed cascade, parent-custodied
child init write, and post-MinIO settings reload through the child root token stored in the parent
KV.

Because the root unseal step now fetches the unlock bundle from MinIO (§6, §6.1), MinIO must be
bootstrap-readable **before** Vault unseal — the bootstrap reorder of §6.1, staged with the
MinIO-root-decoupling reorder last:

```text
prodbox cluster reconcile
  -> reconcile RKE2 + retained PV layer
  -> deploy/rebind MinIO to a bootstrap-readable state (durable bucket present; §6.1)
  -> deploy/rebind Vault on its durable PV
  -> vault init-if-empty (init-once; §5)
  -> vault unseal
       (root: KDF-derive the bootstrap MinIO read credential from the operator prompt, fetch the
        fixed-key unlock bundle from MinIO, password-AEAD-decrypt, submit unseal keys; §6.1.
        child: auto-unseal from parent, §16)
  -> vault reconcile
  -> finish MinIO reconcile (steady-state root creds now resolvable; ensure the `prodbox-state`
     object-store bucket and its Vault-Transit encryption path)
  -> fetch + decrypt the in-force config from the MinIO SSoT (or seed it on first bring-up; §16)
  -> reconcile charts that depend on Vault
```

A sealed or unreachable Vault is surfaced as a first-class cluster status, never hidden:

```text
Vault: initialized, sealed
MinIO: reachable, encrypted objects present
In-force config: unavailable; Vault sealed
Pulumi backend: unavailable; Vault sealed
Gateway daemon: waiting for Vault
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
transit/prodbox-gateway-state
transit/prodbox-pulumi-state
transit/prodbox-minio-envelope
transit/prodbox-downstream-cluster-config
```

Least-privilege policy: the gateway daemon decrypts only the in-force config and gateway state it
needs; the Pulumi runner decrypts only Pulumi backend state; the host CLI may reconcile and rotate
keys; application workloads use only their assigned Transit keys. The
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
include the in-force cluster configuration, the gateway state, downstream cluster configuration
and custody material, Pulumi state and history, generated manifests carrying secret references
plus sensitive topology, bootstrap records, and reconciliation checkpoints that reveal managed
resources. There is **no `master-seed` object** — the HMAC-derivation model is retired (Sprint
`3.19`; §1).

The same durable bucket also holds the **root cluster's password-AEAD-sealed unlock bundle** (§6,
§6.1). This object is the single, deliberate exception to the opaque-name + Vault-Transit rules
below: it is the Tier-1 bootstrap secret that *unseals* Vault, so it cannot be a Vault-Transit
Tier-2 envelope and cannot hide behind a Vault-keyed-HMAC name a sealed Vault could not compute.
It is sealed under the operator password (Argon2id + ChaCha20-Poly1305; §6) and stored at a
**fixed, well-known bootstrap key** so the §6.1 bootstrap credential can find it pre-unseal. Its
discoverability and password-AEAD sealing are intentional and do not weaken the fail-closed
invariant — its body still requires the operator password, and the operational Tier-2 objects
below remain opaque-named and Vault-gated. Child clusters carry no such object (Tier 1 is
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
   object's role, not a downstream cluster, not a Pulumi stack identity. The **one exception** is
   the root unlock bundle (§6.1): it sits at a fixed, well-known bootstrap key (not HMAC-opaque)
   precisely because it must be findable while Vault is sealed — and it is decoy-padding-counted
   as part of the constant-count pool (rule 5) so its presence reveals nothing beyond "this is the
   root cluster".
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
Pulumi role. Harbor's public image layers stay a separate, non-secret store — the §13 public class,
not enveloped. The Sprint `7.14` interposition makes Pulumi see only a scratch `file://` backend on
main stack cycles; persistent checkpoints are opaque `objects/<id>.enc` Model-B objects.

**One object-store, shared by host and daemon accessors.** The pure envelope / HMAC-naming / index /
decoy layer is **shared and identical** across accessors; they differ only in how each binds its
Vault-auth `DekCipher` and its MinIO transport:

- the **host CLI** binds a Transit `DekCipher` via the root Vault token (privileged writes) and
  reaches MinIO through the current port-forward;
- the **gateway daemon** binds a Transit `DekCipher` via Vault **Kubernetes auth** (scoped reads)
  and reaches MinIO over the in-cluster MinIO Service DNS
  (`minio.prodbox.svc.cluster.local`).

Post-`3.19` the master seed is gone and the current gateway daemon has no durable MinIO state
writer left to migrate in Sprint `4.30`. A daemon-side durable read or write uses this same
`Prodbox.Minio.EncryptedObject` layer. Either accessor recovers a logical object **only** when
Vault is unsealed and policy allows it (Sprints `3.17`, `1.38`, `4.30`):
authenticate to Vault, ask Transit to unwrap the DEK, decrypt. Sealed Vault therefore means
nothing about the cluster's setup or its child clusters is determinable beyond the unencrypted
basics (§16). The operator unlock-bundle password is the ephemeral root that gates all of this —
see [The unlock chain](#the-unlock-chain).

Two transit/residency hardening rules apply to secret-bearing transfers. **In transit:**
secret-bearing transfers to and from MinIO use TLS; the daemon↔MinIO hop is plaintext HTTP today
(`http://minio.prodbox.svc.cluster.local:9000`), so adding MinIO TLS is a scheduled hardening item
(Sprint `3.17`). **At rest on the host:** no recovered plaintext secret lands on a
physical-disk-backed file. Two rungs achieve this (Sprint `3.17`): minimally, the daemon's scratch
file is backed by a RAM-only Kubernetes `emptyDir{medium: Memory}` tmpfs mount (e.g.
`/run/prodbox-secret`, with a small `sizeLimit`) so the get/put transits RAM rather than the
container overlay — valid as long as node swap is off, which the kubelet requires; ideally, the
daemon drops the CLI file handoff for a native in-process S3 path that keeps recovered plaintext
only in scrubbed memory (no file and no child process at all).

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
Pulumi never touches MinIO directly. For each operation, prodbox brackets the run
(`Prodbox.Pulumi.EncryptedBackend.withDecryptedStack`, Sprint `7.14`):

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

Current Sprint `7.14` implementation status: the checkpoint layer is active for main per-run stack
cycles (`aws-eks`, `aws-eks-subzone`, `aws-test`), the main long-lived `aws-ses` reconcile/destroy
paths, and production stack residue/output reads. Runtime AWS provider credentials require the Vault
KV object at `secret/gateway/gateway/aws` through `Prodbox.Infra.AwsProviderCredentials`; the
Pulumi provider path has no raw config fallback. The generated operational `aws.*` schema field
carries a mandatory `SecretRef.Vault` reference (never the plaintext key); the elevated/admin
credential never enters config at all — it is supplied through the interactive `SecretRef.Prompt`
arm and discarded after use (the test harness simulates that prompt from the
`aws_admin_for_test_simulation.*` `TestPlaintext` fixture in `test-secrets.dhall`, not from a
`prodbox-config.dhall` section). Setup/config-setup mint the dedicated least-privilege `prodbox`
identity using the prompted elevated credential and write the generated operational provider keys
straight into `secret/gateway/gateway/aws`, and teardown clears that Vault object without writing
provider secrets to `prodbox-config.dhall`.
First-touch deletion/import of pre-existing raw Pulumi checkpoint layouts is code-owned: the per-run raw
backend environment is confined to `LegacyPulumiBackend` first-touch export/delete, while supported
Pulumi actions receive provider-only input before `fileBackendEnvironment` rewrites the backend to
scratch `file://`. Live host-disk proof remains before Sprint `7.14` closes. The legacy
`aws-ses migrate-backend` command is now wrapper-backed as well: it opens the encrypted scratch
backend and relies on first-touch migration to import/delete the old long-lived S3 checkpoint when
encrypted state is absent, instead of running raw MinIO-to-S3 `pulumi stack export` /
`pulumi stack import`.

The target treatment is still **uniform**: per-run backends and the long-lived `aws-ses` backend go
through the same enveloped, opaque-named object-store. There is no AES256-SSE-only carve-out for the
long-lived backend — a sealed Vault yields opaque holds uniformly across every backend. The
operator unlock-bundle password is the ephemeral root that gates the decrypt — see
[The unlock chain](#the-unlock-chain).

## 11. TLS and PKI under Vault

Vault is the TLS authority for the stack, succeeding the prior plaintext ACME-field model and
keeping the single-issuer + S3 retain-restore contract of
[acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md).

**Landed (Sprint `7.15`, config-owned surface):**

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

**`Live-proof: pending` (Standard O — non-blocking, operator/live-driven):**

- The full native-Vault-PKI internal-cert issuance machinery (Vault PKI minting internal certs)
  and live ZeroSSL issuance against the Vault-sourced EAB are not yet built — there is no new PKI
  subsystem. The cert-manager-vs-native-Vault-PKI split is an [open design
  decision](#18-open-design-decisions); cert-manager remains the issuer today and only the EAB /
  key material is Vault-sourced.

Sealed behavior: the EAB key ID cannot be resolved and the materializer Job cannot read the HMAC
key, so new issuance fails closed rather than proceeding. This fail-closed property is structurally
guaranteed by the `SecretRef.Vault` resolver — a sealed (or unreachable, or uninitialized) Vault
cannot resolve the EAB reference — and needs no separate enforcement code. The live "sealed Vault
blocks issuance" proof is operator-driven. This is an explicit availability/security trade-off.

## 12. In-cluster service auth

Each in-cluster component that needs secrets or encryption-as-a-service uses Vault Kubernetes auth
idiomatically: a Kubernetes service account; a Vault role bound to that namespace and service
account; a least-privilege Vault policy; authentication with the service-account JWT; and access
only to assigned KV paths or Transit keys. This is the **only** in-cluster secret-delivery path —
there is no Secret-mounted plaintext Dhall fragment and no `FileSecret` reference (§3). Services
that authenticate to Vault include the gateway daemon, the Keycloak init/reconcile path, the
certificate reconciler, an in-cluster Pulumi runner if present, and any workload needing
encryption-as-a-service. Long term, prefer the Vault Agent Injector, the CSI Secret Store Vault
provider, or direct application-side Vault auth depending on chart ergonomics (Sprints `3.18`,
`3.19`, `8.9`; see [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md)).
The Sprint `3.18` foundation is active: `Prodbox.Secret.VaultInventory` enumerates chart-secret
KV paths, policies, service accounts, and roles, `Prodbox.Vault.Reconcile` writes those policies
and Kubernetes-auth roles, configures `auth/kubernetes/config` against
`https://kubernetes.default.svc:443`, and the straightforward workload charts render explicit
service accounts. The Vault chart binds its service account to `system:auth-delegator` for
TokenReview. The same inventory defines the read-before-write KV seed-object bootstrap plan for
generated/static/external fields, and `prodbox vault reconcile` now seeds the automatically managed
generated/static KV objects with a 32-byte random, base64url-unpadded generator while excluding
externally-owned objects from automatic writes. The `websocket` workload OIDC client-secret now
uses direct app-side `SecretRef.Vault` resolution through Vault Kubernetes auth; the Keycloak and
MinIO charts materialize their covered runtime fields through Vault-login init containers; and the
MinIO admin bootstrap Jobs use the `minio` service account plus a Vault-login init container for
root credential files. The VS Code Envoy `SecurityPolicy` client Secret is materialized from Vault
by a chart Job using a dedicated materializer ServiceAccount. Gateway event keys plus Route 53 AWS
and gateway MinIO credentials now resolve through Vault Kubernetes auth, including the
`gateway-minio-bootstrap` materializer role. Patroni role Secrets are materialized from Vault by the
`keycloak-postgres` pre-install hook using the `prodbox-<namespace>-pg` ServiceAccount; this is the
least-privilege path for the pinned Percona CRD, which does not expose a generated-Pod
`serviceAccountName` field. Externally-owned SMTP setup now writes `secret/keycloak/smtp`, and
host/admin helpers read remaining admin, OIDC, demo-user, and SMTP material from Vault KV. Sprint
`3.18` also pins the migrated chart materializers to fail closed on sealed or unreachable Vaults;
the live whole-system sealed-Vault validation is Sprint `5.8`.

Sprint `1.44` adds one **operator-write** Kubernetes auth role, `prodbox-operator-write` (bound to
the `prodbox-operator-write` service account in the `gateway` namespace), backed by a deliberately
narrow policy with `create`/`update` on exactly two KV paths — `secret/data/acme/eab` and
`secret/data/gateway/gateway/aws`. It exists so the gateway daemon's `POST /v1/secret/<logical>`
endpoint can persist the two host-minted operator secrets routed through the daemon (the ACME EAB
and the minted operational `aws.*`) on behalf of an operator-injected Kubernetes JWT, instead of a
host root-token direct write. The daemon never uses its own read-only `prodbox-gateway-daemon`
identity for the write, and the role cannot reach the rest of the KV store, the Transit keys, or
the federation custody tree. The `vault_operator_password` (needed before Vault is unsealed) and
the ephemeral `aws_admin_for_test_simulation` credential (never stored in Vault) stay host-side.
See [distributed_gateway_architecture.md §11](./distributed_gateway_architecture.md#11-rest-api).

## 13. Config and state classification

Every prodbox datum is classified explicitly.

| Class | Examples | Storage rule |
|---|---|---|
| **Public / non-secret** | Static chart names; non-cluster-revealing feature flags; public docs; non-sensitive local defaults; expected command topology; the unencrypted-basics bootstrap surface (§16) | May live in plain Dhall or logs |
| **Sensitive topology** | Downstream cluster names/endpoints/accounts; Pulumi stack identities (`aws-eks`, `aws-ses`, …) and their existence; the logical names and the *count* of prodbox-owned MinIO objects; the in-force config; generated downstream manifests; resource-graph/checkpoint state | Encrypted at rest; opaque-named + decoy-count-padded in the §9 object-store; unavailable when Vault is sealed |
| **Secret material** | Passwords; access keys; private keys; tokens; ACME EAB material; Keycloak client secrets; MinIO root credentials; Pulumi passphrases; child-cluster init keys (recovery keys + initial root token); unseal/recovery material | In Vault, or in a Vault-encrypted envelope; the root cluster's unseal/recovery material in the unlock bundle |

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
  Vault token never reaches a log through an incidental `show` (Sprint `4.33`). The token-bearing
  federation custody shapes redact their child/root tokens and recovery keys for the same reason.

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
| In-force config (MinIO envelope) | Unreadable; gateway daemon reports waiting-for-Vault; only the unencrypted basics remain legible (§16) |
| Every previously-derived secret (now Vault KV) | Not resolvable; no secret can be produced from any non-Vault source |
| Pulumi (`aws stack ...`) | Refuses before preview/update/destroy; no AWS mutation attempted |
| AWS deployment credentials | Not obtainable |
| Keycloak bootstrap / secret-dependent startup | Init/readiness fail closed; new Pods do not reconstruct secrets from k8s Secret plaintext |
| Ingress/Envoy TLS | New issuance fails; restarts fail closed; no plaintext reconstruction |
| Downstream-cluster inventory and custody | Not extractable from MinIO, ConfigMaps, Secrets, Pulumi backends, or logs |
| Child clusters (federation) | Cannot auto-unseal against a sealed parent; the brick cascades down the tree (§16) |

The sealed-Vault canonical validation (`prodbox test integration sealed-vault`, Sprint `5.8`) is
active on its code-owned suite surface: `ValidationSealedVault` is wired into the native planner and
parser, and `sealedVaultAuditReport` pins the forbidden-pattern oracle for the cross-surface
red-team. Full live closure seals Vault after a full reconcile and asserts every row above fails
closed without leaking metadata; that deployed assertion needs live infrastructure (an unsealed,
then sealed, Vault behind a full reconcile against live AWS/Pulumi infrastructure) and is therefore
recorded as a standalone non-blocking `Live-proof: pending` note (§1) that does not gate Sprint
`5.8`'s code-owned closure or its phase.

## 16. Cluster federation: a Vault transit-seal trust tree

prodbox manages a hierarchy of clusters — a root cluster and zero or more downstream/child
clusters. Trust, unseal authority, and config authority form a tree. This section summarizes the
contract;
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md) is the SSoT for the topology,
the auto-unseal mechanics, and the custody and config-authority flows.

### The transit-seal trust tree

| Tier | Vault seal mode | Who unseals it | Init keys (recovery keys + initial root token) owned by |
|---|---|---|---|
| **Root cluster** | Shamir | Operator only, via the password-AEAD-sealed unlock bundle in durable MinIO, decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests; §4, §6, §6.1) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

- A child Vault literally cannot unseal without a live, unsealed parent. If any parent is
  sealed/unreachable, its children cannot unseal → the fail-closed brick cascades down from the
  root. Cluster liveness for the whole tree roots in one operator unsealing the root (§2,
  invariant 7).
- **Parents own the init keys for child clusters.** At child init, the child's recovery keys and
  initial root token are stored in the parent's Vault KV (under the
  `transit/prodbox-downstream-cluster-config` blast-radius domain; §8); the parent's transit key
  is the child's unseal authority. The root cluster's own init keys are the only ones held outside
  Vault — in the password-AEAD-sealed unlock bundle in durable MinIO (§6, §6.1, the chicken-and-egg
  floor; §17).
- A cluster's knowledge of its child clusters (their existence, identities, endpoints,
  kubeconfigs, account IDs, Pulumi stacks) is **secret data** — only legible behind an unsealed
  Vault (§13, sensitive topology).

### Config SSoT inversion and root-token config authority

- The **in-force cluster configuration** is stored in MinIO as a Vault-Transit-enveloped object
  (§9). **That encrypted object is the source of truth.** When Vault is sealed it is opaque
  ciphertext: nothing about the cluster's setup or its child clusters is determinable beyond the
  unencrypted basics.
- **Unencrypted basics** = the minimal, non-revealing bootstrap needed only to reach and unseal
  Vault: cluster id, this cluster's Vault address, seal mode, and (for a child) the parent
  reference it must contact to auto-unseal. Nothing about workloads, downstream clusters, or
  credentials. The basics are the only thing legible from `prodbox-config.dhall` and from a
  sealed cluster.
- A filesystem `prodbox-config.dhall` is a **seed/propose input only, not the SSoT** (§4). On
  first-ever bring-up it seeds the encrypted MinIO SSoT; thereafter supplying a file is a
  *proposed update*. The prior host-CLI model of reading repo-root `prodbox-config.dhall` directly
  as the config is replaced by "read the basics locally, fetch+decrypt the in-force config from
  MinIO via Vault" (Sprint `1.38`). The Sprint `1.38` local foundations and global host-loader
  switch are landed
  (`loadUnencryptedBasics`, `decodeConfigDhallBytes`, MinIO envelope get/put, injected
  fetch/open/decode + seal/store, and `loadConfigForSettingsWith`).
- **Updating the root cluster's in-force config requires the root Vault token** (which requires an
  unsealed root Vault). Root config governs every downstream cluster — it is the keys to the
  kingdom. Reads of the basics are always free; full reads require unseal; writes require the
  privileged root token.

The CLI/gateway surface to register a child cluster and custody its init keys, and the
parent-owns-child-init-keys contract, are closed on the code-owned surface by Sprint `2.26`; the
transit-seal hierarchy and per-cluster seal custody model are implemented by Sprint `3.20`
(`Prodbox.Vault.Seal`, the recovery-key init wire shape, and the Vault chart transit seal branch);
the direct parent-side registration writer, live child auto-unseal, and fail-closed lifecycle
cascade land in Sprint `4.32`. Sprint `2.26` also records full downstream inventory in parent Vault
KV and exposes the gateway-mediated child listing / bootstrap-reference endpoints through the
gateway daemon's Vault Kubernetes-auth login. Sprint `4.33` closes the Haskell-side opaque namespace
audit and sealed-state gate/redaction surface; Sprint `5.8` owns the deployed sealed-federation
red-team proof. See
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

## 17. The chicken-and-egg floor

Vault owns everything except the minimal floor it cannot bootstrap itself from. The **only** data
Vault may not own:

1. RKE2's self-signed cluster CA + admin kubeconfig (Vault runs inside this cluster's PKI).
2. The Vault PV binding itself.
3. **Root cluster only:** the operator unseal-bundle password (the sole ephemeral secret, the key
   that unseals the root Vault). The password-AEAD-sealed unlock bundle it decrypts lives in the
   durable MinIO bucket, not on host disk (§6); it is not a Vault-owned object — it is what
   *unseals* Vault — but it is reachable pre-unseal only via the password-derived bootstrap MinIO
   credential (§6.1), so the password remains the genuine off-box floor.
4. **Child cluster only:** the bootstrap reference + transit-seal credential the child uses to
   reach its parent's Vault to auto-unseal — itself provisioned and owned by the parent (§16).

Everything else — MinIO root creds, all derived-then-now-KV secrets, ACME EAB, AWS creds, SES,
OIDC, TLS, the in-force config, Pulumi state, and child-cluster custody — is Vault-owned.

## 18. Open design decisions

The following choices are deliberately left open until the implementing sprints. Each is recorded
here with its current lean and owning sprint so it is resolved on purpose, not by accident.

| # | Decision | Current lean | Owning sprint |
|---|----------|--------------|---------------|
| 1 | Vault storage backend | Integrated storage on the retained `.data/vault/vault/0` PV (file storage acceptable for dev); the load-bearing property is only that teardown never destroys Vault state and `init` never reruns (§5). | `3.17` / `4.29` |
| 2 | Initial root-token lifetime | Store unseal/recovery material in the unlock bundle (root) or the parent's Vault KV (child), create named admin roles/tokens, and rotate or revoke the initial root token out of the steady-state admin path after bootstrap (§6, §16). | `1.36` / `3.20` |
| 3 | Opaque object names / indexes | **Resolved — Model B object-store** (§9): every prodbox-owned object goes through one application-level layer that envelopes via Vault Transit, names objects `objects/<vault-keyed-HMAC>.enc`, keeps a Vault-encrypted `indexes/*.enc` map, hashes the stored AAD (`prodbox-envelope-v2`), and decoy-pads to a constant object count + size buckets, in one generically-named bucket shared by the host CLI and the gateway daemon. | `4.30` |
| 4 | Pulumi encrypted-backend approach | **Resolved — decrypt-to-scratch interposition** (§10): hydrate the stack into a RAM-tmpfs `file://` backend, run `pulumi` with no passphrase, re-envelope + opaque-name back through the §9 object-store. Pulumi's own secrets provider is dropped; applied uniformly to per-run and the long-lived `aws-ses` backend (no AES256-SSE carve-out). | `1.37` / `7.14` |
| 5 | TLS private-key generation | **Lean (Sprint `7.15`): cert-manager remains the issuer; EAB / key material is Vault-sourced.** The ACME EAB key ID + HMAC key now live in `secret/acme/eab` referenced by `SecretRef.Vault` (key ID resolved host-side, HMAC materialized in-cluster via the Sprint `3.18` Vault-login Job pattern); cert-manager continues to drive ZeroSSL public-edge issuance and any internal certs. Native Vault PKI as the internal-cert authority remains a deferred, non-blocking `Live-proof: pending` option — not built in `7.15` (§11). | `7.15` |
| 6 | Fail-closed strictness for running workloads | Already-running workloads continue only to the extent they need no new Vault operation; security-sensitive paths prefer explicit fail-closed readiness gates over silent degraded operation (§2). The exact per-component strictness (block new reads vs fail existing readiness) is pinned by the lifecycle and sealed-vault sprints. | `4.29` / `5.8` |
| 7 | Federation depth + child-registration surface | Direct root-to-child registration, the gateway-mediated child listing/bootstrap surface, and the child lifecycle interpreter are live. Deeper parent-as-child registration is a future extension of the same parent-owned custody rules (§16). | `2.26` / `4.32` |

## 19. Red-team checklist

Before the Vault-root finalization is considered complete (each item tracked per its owning sprint
on that phase's owned surface; live-infrastructure proofs are non-blocking `Live-proof: pending`
notes that never gate an earlier phase or a sprint's code-owned closure — development_plan_standards.md
Standards N / O):

- A repo grep finds no real secret in Dhall, and no `FileSecret` / Secret-mounted Dhall fragment
  consumer remains.
- A generated cluster-manifest grep finds no real secret and no chart-generated
  `lookup`+`randAlphaNum` Secret.
- A Kubernetes Secret dump reveals no downstream-cluster metadata or Vault-bypass credential, and
  no ConfigMap, Secret, or namespace name encodes a child-cluster name (k8s leaks no child name;
  §9 whole-system).
- A MinIO bucket dump while Vault is sealed reveals no in-force-config or Pulumi plaintext, and no
  `master-seed` object exists at all.
- The root unlock-bundle object — the one deliberately fixed-key, password-AEAD-sealed exception
  in the bucket (§6.1, §9) — has a body that requires the operator password, not Vault; a
  sealed-Vault bucket dump recovers no unseal key from it, and it is decoy-count-padded so its
  presence reveals only "this is the root cluster", never a workload, downstream cluster, or count
  signal. Child clusters have no such object at all.
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
  ciphertext at a constant count — no plaintext name, body, or count — save the single fixed-key,
  password-AEAD-sealed unlock-bundle object on the root cluster, whose body is still password-gated
  and whose presence is decoy-count-padded (§6.1, §9; Haskell-side gates landed in Sprint `4.33`;
  deployed proof is Sprint `5.8`).
- The object body stores a **hashed** AAD (`prodbox-envelope-v2`, `base64(SHA256(aad))`); a sealed
  envelope never contains a cleartext binding such as `aws-eks` (§8, §9; Sprint `4.30`).
- Sealed Vault blocks Pulumi before any preview/update/destroy starts.
- Sealed Vault blocks gateway daemon config recovery, Keycloak bootstrap/recovery, and TLS
  private-key reconstruction, and prevents every child cluster from auto-unsealing.
- A child cluster cannot unseal while its parent is sealed/unreachable.
- Test-harness plaintext is isolated to `test-secrets.dhall` and never used by production paths.
- The unlock-bundle password is handled by KDF + authenticated encryption, not raw SHA-256.
- The unlock-bundle password is the only operator-memorized secret; its only cleartext home is
  `test-secrets.dhall`, and no production path stores or logs it.
- No recovered plaintext secret lands on a physical-disk-backed path, and secret-bearing
  daemon↔MinIO transfers use TLS.
- The Vault root token is not the steady-state admin path; `vault init` never reruns against
  existing state (init-once; §5).
- Updating the root cluster's in-force config requires the root Vault token.
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
  trust tree, parent custody of child init keys, downstream-cluster metadata as secret, and the
  root-token config authority
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the retired master-seed HMAC
  derivation model, repurposed to map each secret to its Vault KV/PKI/Transit path
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained `.data/` PV
  layer that holds the durable Vault PV; init-once / unseal-on-rebuild
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — cluster
  reconcile/teardown integration and the sealed-state readiness gates
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
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — Closure Status and the
  per-surface adoption sprints
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the retired master-seed derivation model, the removed FileSecret /
  Secret-mounted Dhall path, the host-CLI direct-config-read model, and the folded-in
  `VAULT_REFACTOR.md` proposal
</content>
