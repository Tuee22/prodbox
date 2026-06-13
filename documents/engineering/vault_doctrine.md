# Vault Secret-Management Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[../../README.md](../../README.md),
[config_doctrine.md](./config_doctrine.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[acme_provider_guide.md](./acme_provider_guide.md),
[aws_admin_credentials.md](./aws_admin_credentials.md),
[cli_command_surface.md](./cli_command_surface.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md](../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md),
[../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md)
**Generated sections**: none

> **Purpose**: Single source of truth for Vault as the fail-closed secrets, key-management,
> encryption-as-a-service, and PKI backend of every prodbox-managed cluster — the SecretRef
> configuration contract, the host-side unlock bundle, Vault Transit envelope encryption of
> MinIO and Pulumi state, the sealed-state invariant, and in-cluster Vault Kubernetes auth.

## 1. Why this doctrine exists

prodbox manages an intentionally ephemeral cluster: the Kubernetes runtime may be destroyed and
recreated while `.data/`-backed persistent volumes survive and rebind on the next spin-up (see
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)). Before this doctrine, secret
material lived in three uneven places: plaintext fields inside the operator-authored
`prodbox-config.dhall` (AWS keys, ACME EAB material), plaintext Dhall fragments mounted from
k8s Secrets, and an unencrypted master-seed object in MinIO that any holder of the bucket
credential could read. A `.data/` snapshot, a MinIO dump, or a Kubernetes Secret export
revealed everything prodbox knows — including the inventory of any downstream cluster prodbox
manages.

Vault closes that gap. It becomes the per-cluster durable secret root: it owns KV secrets,
Transit encryption-as-a-service, PKI, Kubernetes auth, and the unlock-dependent decryption
authority. Every secret-bearing artifact prodbox persists outside Vault — MinIO objects, Pulumi
backend state, the active daemon Dhall — is stored only as a Vault-encrypted envelope. The
operator-authored Dhall holds **references** to secrets, never secret values.

This doctrine is the SSoT for that model. It extends, and does not replace, the existing secret
machinery:

- The **master-seed derivation model** ([secret_derivation_doctrine.md](./secret_derivation_doctrine.md))
  stays. HMAC-SHA-256 derivation, the daemon-only seed boundary, and the gateway as the sole
  derivation authority are unchanged. Vault adds encryption-at-rest of the seed object and a
  sealed-state gate in front of it.
- The **single-Dhall-file config contract** ([config_doctrine.md](./config_doctrine.md)) stays.
  Vault refines what the file may contain: typed `SecretRef` values for sensitive fields instead
  of plaintext.
- The **retained-PV model** ([storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md))
  stays. Vault adds a second durable PV under `.data/`, preserved across cluster wipes exactly
  like MinIO's.
- The **single ACME issuer + S3 retain-restore** ([acme_provider_guide.md](./acme_provider_guide.md))
  stays. Vault holds the ACME EAB material and protects the TLS private-key path.
- The **managed-resource-registry teardown**
  ([lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md)) stays. Vault
  adds reconcile-time deploy/unseal and a preserved Vault PV on teardown.

Adoption is scheduled across reopened phases — see the
[Development Plan](../../DEVELOPMENT_PLAN/README.md) Closure Status entry for the Vault refactor
and the per-surface sprints (`0.12`, `1.35`–`1.37`, `3.17`–`3.18`, `4.29`–`4.30`, `5.8`,
`7.14`–`7.15`, `8.9`). Where this doctrine describes structure the worktree does not yet honor,
it names the owning sprint; until that sprint lands the statement is the intended end state, not
a present-tense fact.

## 2. The fail-closed invariant

The load-bearing requirement of the entire model:

> A sealed Vault reduces prodbox to an opaque durable-data pile. PVs and MinIO objects may still
> exist, but they reveal no secrets, no active Dhall, no Pulumi state, and no downstream-cluster
> inventory until Vault is unsealed.

Stated as hard architectural invariants — not implementation preferences:

1. **Dhall invariant.** `prodbox-config.dhall` never contains a plaintext secret value (§3).
2. **Cluster-metadata-is-secret invariant.** Downstream-cluster names, endpoints, kubeconfigs,
   account IDs, DNS names, Pulumi stack identities, and the active daemon Dhall are secret data;
   a sealed Vault makes them unrecoverable from MinIO, Kubernetes Secrets/ConfigMaps, Pulumi
   backends, logs, or generated files (§9, §13).
3. **Sealed-state invariant.** When Vault is sealed, TLS private-key flows, Keycloak bootstrap,
   the gateway daemon's active-Dhall load, MinIO envelope decryption, Pulumi operations, and AWS
   deployment-credential retrieval all fail closed (§15).
4. **MinIO object invariant.** prodbox-owned MinIO objects are ciphertext unless they are
   explicitly public, non-sensitive artifacts (§8, §9).
5. **Pulumi invariant.** Pulumi cannot preview, update, destroy, or decrypt state while Vault is
   sealed; the readiness check runs before any AWS-side mutation is attempted (§10).

For security-sensitive paths prodbox prefers an explicit fail-closed readiness gate over silent
degraded operation. Already-running workloads may continue only to the extent they need no new
Vault operation.

## 3. The SecretRef model

Sensitive configuration fields encode a typed **reference** to a secret, never the secret.

Conceptual Dhall union, owned by a shared type module imported by `prodbox-config-types.dhall`:

```dhall
-- Example: shared SecretRef type module
let SecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : { name : Text }
      | Prompt : { name : Text, purpose : Text }
      | FileSecret : { path : Text }
      | TestPlaintext : Text
      >

in  SecretRef
```

Conceptual Haskell shape (scheduled in `Prodbox.Settings.SecretRef`, Sprint `1.35`):

```haskell
-- Example: Prodbox.Settings.SecretRef
data SecretRef
  = VaultSecret VaultPath VaultField   -- kv read, resolved only when Vault is unsealed
  | VaultTransitKey TransitKeyName     -- encryption-as-a-service handle
  | PromptedSecret PromptSpec          -- one-off elevated material, CLI prompt only
  | FileSecret FilePath                -- migration bridge for Secret-mounted Dhall
  | TestPlaintext Text                 -- test harness only; rejected in production mode
```

Constructor rules:

| Constructor | Production config | Notes |
|---|---|---|
| `VaultSecret` / `VaultTransitKey` | Allowed | The target for every in-cluster-consumed secret. |
| `PromptedSecret` | Allowed (CLI only) | One-off elevated operator material; never written to disk. |
| `FileSecret` | Allowed only as a migration bridge | The current Secret-mounted Dhall fragment path (`/etc/gateway/secrets/*.dhall`); not the long-term default. |
| `TestPlaintext` | **Rejected** | Accepted only by the test harness, only from `test-secrets.dhall` (§4). |

`prodbox config validate` rejects any plaintext secret value in production config and rejects
`TestPlaintext` outside the test harness (Sprint `1.35`). Any secret a deployed in-cluster
component needs must be a `VaultSecret` / `VaultTransitKey` reference before deployment.

`prodbox-config.dhall` **may** contain: non-secret topology; public, non-sensitive endpoint
names; Vault mount names; Vault policy intent; logical `SecretRef` values; local-cluster
bootstrap policy.

`prodbox-config.dhall` **must not** contain: AWS access keys; ACME EAB HMAC material; TLS private
keys; MinIO root credentials; Keycloak admin passwords or client secrets; Pulumi passphrases or
stack secrets; downstream-cluster kubeconfigs; downstream-cluster hostnames, IPs, account IDs, or
identities that reveal managed-cluster inventory; or any plaintext material needed to unseal,
authenticate to, or decrypt Vault-protected state.

## 4. Config split: production references vs test plaintext

Two files, one rule each:

| File | Content | Consumed by |
|---|---|---|
| `prodbox-config.dhall` | Production-safe topology and `SecretRef` values only | Every supported binary, host and in-cluster |
| `test-secrets.dhall` | Plaintext values that simulate operator prompts and seed fixtures | The test harness only |

`test-secrets.dhall` may carry the Vault unlock-bundle password used by tests, elevated AWS
credentials that simulate the operator prompt, fake ACME/EAB values, fake MinIO credentials, fake
Keycloak bootstrap passwords, and fixtures used to seed Vault in integration tests. It must never
be required for production, imported by `prodbox-config.dhall`, copied into generated cluster
config, stored in MinIO, mounted into the cluster, or committed with real values. The test-only
unlock-bundle password simulates an operator entering the password at the prompt (§6); it has no
production role.

## 5. Vault deployment model

Vault runs **inside** the prodbox-managed cluster as a platform component, on the same footing as
MinIO, Harbor, MetalLB, Envoy Gateway, cert-manager, and the Percona PostgreSQL operator. It
appears in the shared `[PlatformComponent]` inventory so **both** substrates stand it up
identically (substrate equivalence; see [substrates.md](../../DEVELOPMENT_PLAN/substrates.md) and
Sprint `3.17`).

Requirements:

- A single Vault instance per prodbox-managed cluster.
- A durable PVC backed by `.data/` (`.data/vault/vault/0`), preserved across cluster teardown exactly
  like MinIO's PV. Cluster teardown must not destroy Vault state.
- Init only when no existing Vault state is found; no accidental reinitialization.
- Startup readiness gates that distinguish: not deployed; deployed but uninitialized; initialized
  but sealed; initialized and unsealed; policy reconciled.

Acceptable storage modes are Vault integrated storage on the retained PV or file storage on the
retained PV for development. The exact backend is not load-bearing; the load-bearing property is
that cluster teardown never destroys Vault state.

```text
.data/
  prodbox/
    minio/0/                     durable MinIO StatefulSet PV — ciphertext objects only (§9)
    vault-unlock-bundle.age      host-side encrypted Vault recovery material (§6)
  vault/
    vault/0/                     durable Vault StatefulSet PV, preserved across cluster wipe
```

## 6. The unlock bundle

Vault initialization happens once and produces unseal/recovery keys plus the initial root token.
prodbox captures that material exactly once and immediately writes it to a host-side **unlock
bundle**, then never prints raw keys or the root token to logs.

The unlock bundle uses authenticated encryption with a real password-based key-derivation
function — **never raw SHA-256**, which is a hash, not encryption:

```text
operator password
  -> Argon2id (or scrypt) KDF
  -> age / sops-style authenticated encryption
  -> .data/prodbox/vault-unlock-bundle.age
```

Conceptual plaintext (before encryption) — the on-disk bundle is always ciphertext:

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

The bundle backend is pluggable behind a single interface (local encrypted file today; 1Password,
pass/gopass, cloud KMS, YubiKey/age identity, or a TPM-backed host secret later). The initial
root token is bootstrap-only: prodbox creates named admin roles/tokens and rotates or revokes the
initial root token out of the steady-state admin path (an [open design
decision](#17-open-design-decisions)).

### The unlock chain

The operator's unlock-bundle password is the **single ephemeral root of trust** for the whole
cluster. It is supplied at the CLI unseal prompt, used in memory, and never persisted:

```text
operator CLI password
  -> Argon2id / age authenticated decryption of .data/prodbox/vault-unlock-bundle.age
  -> recover Vault's unseal/recovery keys (held only inside the bundle)
  -> submit the unseal keys -> UNSEAL VAULT
  -> an unsealed Vault's Transit keys decrypt the master-seed envelope, the active Dhall,
     and the Pulumi backend (§8, §9, §10)
```

The password therefore does **not** encrypt the master seed directly — it decrypts the unlock
bundle that holds Vault's unseal keys, and an *unsealed Vault* is what decrypts the seed. The
consequences:

- A **sealed Vault** — no operator password entered this boot — leaves the master seed, the active
  Dhall, and the Pulumi backend as ciphertext, exactly per the fail-closed invariant (§2).
- The password is the only secret the operator memorizes; Vault's actual unseal keys are
  machine-generated and live only inside the encrypted bundle.
- The password's **only cleartext home is `test-secrets.dhall`**, read solely by the test harness
  to simulate the operator at the unseal prompt (§4); no production path stores or logs it.

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
  initialized, otherwise initializes Vault, captures unseal/recovery keys and the initial root
  token exactly once, writes the encrypted unlock bundle, and prints no raw key material (an
  optional `--show-sensitive-once` operator-confirmed flag may display it once).
- `vault unseal` reads the unlock bundle, prompts for the bundle password (unless the test harness
  supplies it), decrypts in memory, submits unseal keys, verifies Vault is unsealed, and clears
  sensitive material from process memory where practical. Plaintext unseal keys are never
  persisted.
- `vault reconcile` requires Vault initialized and unsealed, then idempotently reconciles auth
  mounts, policies, roles, KV mounts, Transit keys, PKI mounts and issuers, Kubernetes
  service-account auth for in-cluster workloads, the MinIO bucket encryption policy metadata, and
  the Pulumi encryption configuration. It is safe to run on every cluster spin-up.

Lifecycle integration into `prodbox cluster reconcile` (Sprint `4.29`):

```text
prodbox cluster reconcile
  -> reconcile RKE2 + retained PV layer
  -> deploy/rebind Vault on its durable PV
  -> vault init-if-empty
  -> vault unseal (from unlock bundle, or prompt the operator)
  -> vault reconcile
  -> deploy/rebind MinIO
  -> ensure the prodbox bucket and its Vault-Transit encryption path
  -> write the active Dhall as an encrypted object
  -> reconcile charts that depend on Vault
```

A sealed or unreachable Vault is surfaced as a first-class cluster status, never hidden:

```text
Vault: initialized, sealed
MinIO: reachable, encrypted objects present
Active Dhall: unavailable; Vault sealed
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
  "format": "prodbox-envelope-v1",
  "transit_key": "prodbox-minio-envelope",
  "wrapped_dek": "vault:v1:...",
  "nonce": "...",
  "aad": "...",
  "ciphertext": "...",
  "created_at": "...",
  "key_version": 1
}
```

The AAD binds cluster ID, object logical type, object generation, schema version, and the
expected object identity, so an envelope cannot be replayed under a different identity.

Transit keys are split by blast-radius domain so a leaked decrypt grant is contained:

```text
transit/prodbox-active-config
transit/prodbox-gateway-state
transit/prodbox-pulumi-state
transit/prodbox-minio-envelope
transit/prodbox-downstream-cluster-config
```

Least-privilege policy: the gateway daemon decrypts only the active config and gateway state it
needs; the Pulumi runner decrypts only Pulumi backend state; the host CLI may reconcile and rotate
keys; application workloads use only their assigned Transit keys.

The envelope template above pins the format tag (`prodbox-envelope-v1`) and field set; the exact
local AEAD cipher (e.g. AES-256-GCM or ChaCha20-Poly1305), the on-disk serialization, and the AAD
canonicalization are deliberately left to the implementing sprint (`Prodbox.Crypto.Envelope`,
Sprint `3.17`) rather than fixed here, so the wire format can be chosen against the available
crypto libraries without a doctrine change.

## 9. MinIO as a ciphertext store

The gateway daemon's `prodbox` MinIO bucket is a secret-bearing state store. Every prodbox-owned
object is ciphertext (a §8 envelope) unless it is an explicitly public, non-sensitive artifact.
Secret-bearing objects include the gateway master seed, the active daemon Dhall, downstream
cluster configuration, Pulumi state and history, generated manifests carrying secret references
plus sensitive topology, bootstrap records, and reconciliation checkpoints that reveal managed
resources.

Object names must not carry sensitive meaning. If an object name or prefix reveals a downstream
cluster, the name itself is a metadata leak. The target layout uses opaque object IDs plus
Vault-encrypted indexes (Sprint `4.30`):

```text
s3://prodbox/
  objects/<opaque-id>.enc
  indexes/active-config.enc
  indexes/pulumi.enc
  indexes/gateway.enc
```

Because the indexes are Vault-encrypted, a sealed Vault reveals only opaque object IDs. The master
seed and active Dhall are envelopes here: the gateway daemon authenticates to Vault with
Kubernetes auth, asks Transit to unwrap the DEK, and recovers the seed or active config **only**
when Vault is unsealed and policy allows it (Sprint `3.17`). Sealed Vault therefore means the
active Dhall is unreadable and the seed cannot be derived from — the derivation model of
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md) runs only behind an unsealed
Vault. The operator unlock-bundle password is the ephemeral root that gates all of this — see
[The unlock chain](#the-unlock-chain).

Two transit/residency hardening rules apply to the seed envelope. **In transit:** secret-bearing
transfers to and from MinIO use TLS; the daemon↔MinIO hop is plaintext HTTP today
(`http://minio.prodbox.svc.cluster.local:9000`), so adding MinIO TLS is a scheduled hardening item
(Sprint `3.17`). **At rest on the host:** the plaintext seed never lands on a physical-disk-backed
file. Two rungs achieve this (Sprint `3.17`): minimally, the daemon's scratch file is backed by a
RAM-only Kubernetes `emptyDir{medium: Memory}` tmpfs mount (e.g. `/run/prodbox-seed`, with a small
`sizeLimit`) so the AWS-CLI get/put transits RAM rather than the container overlay — valid as long
as node swap is off, which the kubelet requires; ideally, the daemon drops the CLI file handoff for
a native in-process S3 path that keeps the recovered plaintext seed only in scrubbed memory (no file
and no child process at all).

## 10. Pulumi backend under Vault

Pulumi backend state in MinIO can reveal AWS resource names, account IDs, cluster names,
endpoints, dependency topology, and provider configuration. Under this doctrine that is secret
data: the backend objects are Vault-encrypted, and every `prodbox aws stack ...` command performs
the readiness check before touching state (Sprints `1.37`, `7.14`):

```text
check Vault reachable
check Vault initialized
check Vault unsealed
check Transit key available
check Pulumi backend decryptable
only then run Pulumi
```

A sealed Vault produces a clear, safe error before any AWS-side mutation is attempted:

```text
Blocked: Vault is sealed.
Pulumi backend state and AWS deployment credentials are intentionally unavailable.
No preview/update/destroy was started.
Run: prodbox vault unseal
```

The implementation path: start by deriving the Pulumi secrets provider/passphrase from Vault and
gating every operation on unsealed Vault (Sprint `1.37`), then move to fully Vault-encrypted
backend objects so the raw backend metadata is itself opaque while Vault is sealed (Sprint
`7.14`). The gate on unsealed Vault holds from the beginning.

Three implementation options exist for the encrypted backend; prodbox starts with Option B and
moves to A or C for full metadata secrecy:

- **Option A — prodbox-managed encrypted-S3 wrapper:** backend objects are stored as envelopes and
  Pulumi runs against a decrypted temporary local view that prodbox re-encrypts afterward. Strong
  control; more locking and crash-recovery complexity.
- **Option B — Vault-derived secrets provider:** the backend stays MinIO and the Pulumi stack
  secrets provider uses a Vault-derived passphrase obtainable only when unsealed. Simplest; raw
  backend metadata can still leak unless the object itself is encrypted. This is the Sprint `1.37`
  starting point.
- **Option C — Vault-aware state proxy:** prodbox exposes a local S3-compatible/filesystem proxy
  that encrypts/decrypts state through Vault Transit. Cleanest sealed-state invariant; most work.

Scope note: the unencrypted-metadata concern targets the **per-run MinIO backend**; the long-lived
`pulumi_state_backend` S3 bucket already carries AES256 server-side encryption and gains the
Vault-unsealed gate on top of it. The operator unlock-bundle password is the ephemeral root that
gates the decrypt — see [The unlock chain](#the-unlock-chain).

## 11. TLS and PKI under Vault

Vault becomes the backend for ACME credentials, TLS private keys, and certificate-issuance state,
extending the single-issuer + S3 retain-restore model of
[acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md) (Sprint `7.15`):

- ACME EAB material moves from the plaintext `acme.eab_key_id` / `acme.eab_hmac_key` config fields
  into Vault KV, referenced by `SecretRef.Vault`.
- TLS private keys are generated by, stored in, or wrapped by Vault; certificate-issuance state is
  not recoverable from plaintext Kubernetes Secrets alone.
- The cert-manager-vs-Vault-PKI choice (cert-manager Vault issuer, native Vault PKI for internal
  certs, or ACME with Vault-backed credential storage for public certs) is an [open design
  decision](#17-open-design-decisions).

Sealed behavior: new issuance fails, private-key retrieval fails, Envoy/Gateway TLS is not
regenerated from plaintext, and restarts fail closed rather than reconstruct TLS from Kubernetes
Secrets. This is an explicit availability/security trade-off.

## 12. In-cluster service auth

Each in-cluster component that needs secrets or encryption-as-a-service uses Vault Kubernetes auth
idiomatically: a Kubernetes service account; a Vault role bound to that namespace and service
account; a least-privilege Vault policy; authentication with the service-account JWT; and access
only to assigned KV paths or Transit keys. Services that authenticate to Vault include the gateway
daemon, the Keycloak init/reconcile path, the certificate reconciler, an in-cluster Pulumi runner
if present, and any workload needing encryption-as-a-service. Long term, prefer the Vault Agent
Injector, the CSI Secret Store Vault provider, or direct application-side Vault auth depending on
chart ergonomics (Sprints `3.18`, `8.9`).

## 13. Config and state classification

Every prodbox datum is classified explicitly.

| Class | Examples | Storage rule |
|---|---|---|
| **Public / non-secret** | Static chart names; non-cluster-revealing feature flags; public docs; non-sensitive local defaults; expected command topology | May live in plain Dhall or logs |
| **Sensitive topology** | Downstream cluster names/endpoints/accounts; Pulumi stack identities that reveal inventory; the active daemon Dhall; generated downstream manifests; resource-graph/checkpoint state | Encrypted at rest; unavailable when Vault is sealed |
| **Secret material** | Passwords; access keys; private keys; tokens; ACME EAB material; Keycloak client secrets; MinIO credentials; Pulumi passphrases; unseal/recovery material | In Vault, or in a Vault-encrypted envelope; unseal/recovery material in the unlock bundle |

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
  | UnlockBundleMissing FilePath
  | UnlockBundleDecryptFailed
```

Errors are operator-clear and never include secret values. Logging never emits SecretRef-resolved
values, unlock-bundle plaintext, Vault tokens, Pulumi passphrases, object plaintext, or
downstream-cluster names on sealed-state failure paths when those names are sensitive. Prefer
redacted structured logs:

```text
vault_status=sealed component=pulumi operation=preview result=blocked
```

over identifying messages such as `Cannot deploy downstream cluster prod-eu-west-1 …`.

## 15. Sealed-state behavior matrix

When Vault is sealed, each surface fails closed:

| Surface | Sealed-Vault behavior |
|---|---|
| Active daemon Dhall (MinIO envelope) | Unreadable; gateway daemon reports waiting-for-Vault |
| Master seed (MinIO envelope) | Cannot be unwrapped; no derived secret can be produced |
| Pulumi (`aws stack ...`) | Refuses before preview/update/destroy; no AWS mutation attempted |
| AWS deployment credentials | Not obtainable |
| Keycloak bootstrap / secret-dependent startup | Init/readiness fail closed; new Pods do not reconstruct secrets from k8s Secret plaintext |
| Ingress/Envoy TLS | New issuance fails; restarts fail closed; no plaintext reconstruction |
| Downstream-cluster inventory | Not extractable from MinIO, ConfigMaps, Secrets, Pulumi backends, or logs |

The sealed-Vault canonical validation (`prodbox test integration sealed-vault`, Sprint `5.8`)
seals Vault after a full reconcile and asserts every row above fails closed without leaking
metadata.

## 16. Red-team checklist

Before the Vault refactor is considered complete (tracked across the reopened phases):

- A repo grep finds no real secret in Dhall.
- A generated cluster-manifest grep finds no real secret.
- A Kubernetes Secret dump reveals no downstream-cluster metadata or Vault-bypass credential.
- A MinIO bucket dump while Vault is sealed reveals no active-Dhall or Pulumi plaintext.
- Object names and indexes reveal no downstream-cluster inventory.
- Sealed Vault blocks Pulumi before any preview/update/destroy starts.
- Sealed Vault blocks gateway daemon config recovery, Keycloak bootstrap/recovery, and TLS
  private-key reconstruction.
- Test-harness plaintext is isolated to `test-secrets.dhall` and never used by production paths.
- The unlock-bundle password is handled by KDF + authenticated encryption, not raw SHA-256.
- The unlock-bundle password is the only operator-memorized secret; its only cleartext home is
  `test-secrets.dhall`, and no production path stores or logs it.
- The plaintext master seed never lands on a physical-disk-backed path, and secret-bearing
  daemon↔MinIO transfers use TLS.
- The Vault root token is not the steady-state admin path; `vault init` never reruns against
  existing state.
- Cluster teardown preserves the Vault and MinIO PVs; cluster recreate cannot recover secrets
  without unsealing Vault.

The forbidden golden-output patterns for the SecretRef golden tests (Sprint `5.8`) include
`AKIA`, `aws_secret_access_key`, `BEGIN PRIVATE KEY`, `client_secret = "…"`, `password = "…"`,
Pulumi passphrase strings, and kubeconfig user tokens.

## 17. Open design decisions

The following choices from the original proposal (`VAULT_REFACTOR.md` §20) are deliberately left
open until the implementing sprints. Each is recorded here with its current lean and owning sprint
so it is resolved on purpose, not by accident.

| # | Decision | Current lean | Owning sprint |
|---|----------|--------------|---------------|
| 1 | Vault storage backend | Integrated storage on the retained `.data/vault/vault/0` PV (file storage acceptable for dev); the load-bearing property is only that teardown never destroys Vault state (§5). | `3.17` / `4.29` |
| 2 | Initial root-token lifetime | Store unseal/recovery material in the unlock bundle, create named admin roles/tokens, and rotate or revoke the initial root token out of the steady-state admin path after bootstrap (§6). | `1.36` |
| 3 | Opaque object names / indexes | Opaque object IDs + Vault-encrypted indexes, since config/topology metadata is secret (§9). | `4.30` |
| 4 | Pulumi encrypted-backend approach | Option B (Vault-derived passphrase) first, then Option A or C for full metadata secrecy (§10). | `1.37` / `7.14` |
| 5 | TLS private-key generation | cert-manager Vault issuer vs native Vault PKI vs ACME-with-Vault-stored-credentials — pick on cert-manager integration + operational simplicity (§11). | `7.15` |
| 6 | Fail-closed strictness for running workloads | Already-running workloads continue only to the extent they need no new Vault operation; security-sensitive paths prefer explicit fail-closed readiness gates over silent degraded operation (§2). The exact per-component strictness (block new reads vs fail existing readiness) is pinned by the lifecycle and sealed-vault sprints. | `4.29` / `5.8` |

## Cross-References

- [config_doctrine.md](./config_doctrine.md) — the single-Dhall-file contract this doctrine
  refines with `SecretRef`
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the master-seed derivation
  model whose seed object becomes a Vault-Transit envelope
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained `.data/` PV
  layer that now also holds the Vault PV
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — cluster
  reconcile/teardown integration and the sealed-state readiness gates
- [envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md) — the public-edge TLS path
  that fails closed under a sealed Vault
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — chart-secret consumption
  via Vault Kubernetes auth
- [acme_provider_guide.md](./acme_provider_guide.md) — the ACME EAB material that moves into Vault
  KV
- [aws_admin_credentials.md](./aws_admin_credentials.md) — prompted elevated AWS material stored
  in Vault and discarded
- [cli_command_surface.md](./cli_command_surface.md) — the `prodbox vault` command group
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — Closure Status and the
  per-surface adoption sprints
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the superseded plaintext-secret, unencrypted-seed, and unencrypted-Pulumi
  surfaces
