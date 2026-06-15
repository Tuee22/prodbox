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
> SecretRef configuration contract, the host-side unlock bundle, Vault Transit envelope
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
the intended structure, not a present-tense implementation fact. Adoption is scheduled across the
reopened phases — see the [Development Plan](../../DEVELOPMENT_PLAN/README.md) Closure Status entry
for the Vault-root finalization and the per-surface sprints (`0.13`, `1.35`–`1.38`, `2.26`,
`3.17`–`3.20`, `4.29`–`4.32`, `5.8`, `7.14`–`7.15`, `8.9`).

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

Conceptual Haskell shape (scheduled in `Prodbox.Settings.SecretRef`, Sprints `1.35`, `1.38`):

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
`TestPlaintext` outside the test harness (Sprints `1.35`, `1.38`). Any secret a deployed
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
| `prodbox-config.dhall` | Production-safe topology, the unencrypted basics, and `SecretRef` values only — a seed/propose input, not the in-force SSoT (§16) | Every supported binary, host and in-cluster |
| `test-secrets.dhall` | Plaintext values that simulate operator prompts and seed fixtures | The test harness only |

`test-secrets.dhall` may carry the Vault unlock-bundle password used by tests, elevated AWS
credentials that simulate the operator prompt, fake ACME/EAB values, fake MinIO credentials, fake
Keycloak bootstrap passwords, and fixtures used to seed Vault in integration tests. It must never
be required for production, imported by `prodbox-config.dhall`, copied into generated cluster
config, stored in MinIO, mounted into the cluster, or committed with real values. The test-only
unlock-bundle password simulates an operator entering the password at the prompt (§6); it has no
production role. It is the only cleartext home of the root operator's memorized unseal password
(§6, §16).

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
- Startup readiness gates that distinguish: not deployed; deployed but uninitialized; initialized
  but sealed; initialized and unsealed; policy reconciled.

### Init-once / unseal-on-rebuild

The cluster is ephemeral; its storage is **not**. Vault KV is therefore as durable across rebuilds
as any retained PV:

- `vault init` runs **exactly once, ever** — the first time the PV is empty. It captures the
  unseal/recovery keys and the initial root token, writes them to the host-side unlock bundle (§6,
  for the root cluster) or the parent's Vault KV (§16, for a child cluster), and is never rerun
  against existing state.
- Every subsequent `cluster reconcile` redeploys the Vault chart against the existing data and
  only **unseals** it. No re-init, no key regeneration. **A cluster rebuild is not a fresh Vault.**

Acceptable storage modes are Vault integrated storage on the retained PV or file storage on the
retained PV for development. The exact backend is not load-bearing; the load-bearing property is
that cluster teardown never destroys Vault state and `init` never reruns.

```text
.data/
  prodbox/
    minio/0/                     durable MinIO StatefulSet PV — ciphertext objects only (§9)
    vault-unlock-bundle.age      host-side encrypted Vault recovery material — ROOT cluster only (§6)
  vault/
    vault/0/                     durable Vault StatefulSet PV, preserved across cluster wipe
```

## 6. The unlock bundle (root cluster)

The root cluster's Vault uses **Shamir** seal mode: the operator is the only one who can unseal
it. Initialization happens once and produces unseal/recovery keys plus the initial root token.
prodbox captures that material exactly once and immediately writes it to a host-side **unlock
bundle**, then never prints raw keys or the root token to logs. (A child cluster's Vault uses
`seal "transit"` against its parent instead and has no host-side unlock bundle — see §16 and
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).)

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
decision](#18-open-design-decisions)).

### The unlock chain

The operator's unlock-bundle password is the **single ephemeral root of trust** for the root
cluster — and, through the transit-seal tree, for every cluster beneath it. It is supplied at the
CLI unseal prompt, used in memory, and never persisted:

```text
operator CLI password
  -> Argon2id / age authenticated decryption of .data/prodbox/vault-unlock-bundle.age
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

Lifecycle integration into `prodbox cluster reconcile` (Sprints `4.29`, `4.32`):

```text
prodbox cluster reconcile
  -> reconcile RKE2 + retained PV layer
  -> deploy/rebind Vault on its durable PV
  -> vault init-if-empty (init-once; §5)
  -> vault unseal (root: from unlock bundle / operator prompt; child: auto-unseal from parent, §16)
  -> vault reconcile
  -> deploy/rebind MinIO
  -> ensure the prodbox bucket and its Vault-Transit encryption path
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

Least-privilege policy: the gateway daemon decrypts only the in-force config and gateway state it
needs; the Pulumi runner decrypts only Pulumi backend state; the host CLI may reconcile and rotate
keys; application workloads use only their assigned Transit keys. The
`prodbox-downstream-cluster-config` key and its policy gate a parent cluster's custody of child
clusters (§16).

The envelope template above pins the format tag (`prodbox-envelope-v1`) and field set; the exact
local AEAD cipher (e.g. AES-256-GCM or ChaCha20-Poly1305), the on-disk serialization, and the AAD
canonicalization are deliberately left to the implementing sprint (`Prodbox.Crypto.Envelope`,
Sprint `3.17`) rather than fixed here, so the wire format can be chosen against the available
crypto libraries without a doctrine change.

## 9. MinIO as a ciphertext store

The gateway daemon's `prodbox` MinIO bucket is a secret-bearing state store. MinIO itself is just
object storage; its own root credentials come from Vault KV (§5, §13). Every prodbox-owned object
is ciphertext (a §8 envelope) unless it is an explicitly public, non-sensitive artifact.
Secret-bearing objects include the in-force cluster configuration, the gateway state, downstream
cluster configuration and custody material, Pulumi state and history, generated manifests carrying
secret references plus sensitive topology, bootstrap records, and reconciliation checkpoints that
reveal managed resources. There is **no `master-seed` object** — the HMAC-derivation model is
retired (Sprint `3.19`; §1).

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

Because the indexes are Vault-encrypted, a sealed Vault reveals only opaque object IDs. The
in-force config is an envelope here: the host CLI and the gateway daemon authenticate to Vault
(the host CLI with the root token for privileged writes; the daemon with Kubernetes auth for
scoped reads), ask Transit to unwrap the DEK, and recover the in-force config **only** when Vault
is unsealed and policy allows it (Sprints `3.17`, `1.38`). Sealed Vault therefore means nothing
about the cluster's setup or its child clusters is determinable beyond the unencrypted basics
(§16). The operator unlock-bundle password is the ephemeral root that gates all of this — see
[The unlock chain](#the-unlock-chain).

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

Vault is the TLS authority for the stack, succeeding the prior plaintext ACME-field model and
keeping the single-issuer + S3 retain-restore contract of
[acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md) (Sprint `7.15`):

- ACME EAB material moves from the plaintext `acme.eab_key_id` / `acme.eab_hmac_key` config fields
  into Vault KV, referenced by `SecretRef.Vault`.
- TLS private keys are generated by, stored in, or wrapped by Vault — Vault PKI issues internal
  certs, and public ZeroSSL certs keep the S3 retain-and-restore contract but their key material
  is Vault-protected. Certificate-issuance state is not recoverable from plaintext Kubernetes
  Secrets alone.
- ZeroSSL remains the sole public ACME provider; the single `zerossl-http01` issuer and the S3
  cert retain-and-restore flow are unchanged — only the key material moves behind Vault.
- The cert-manager-vs-Vault-PKI split (cert-manager Vault issuer, native Vault PKI for internal
  certs, ACME-with-Vault-stored-credentials for public certs) is an [open design
  decision](#18-open-design-decisions).

Sealed behavior: new issuance fails, private-key retrieval fails, Envoy/Gateway TLS is not
regenerated from plaintext, and restarts fail closed rather than reconstruct TLS from Kubernetes
Secrets. This is an explicit availability/security trade-off.

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

## 13. Config and state classification

Every prodbox datum is classified explicitly.

| Class | Examples | Storage rule |
|---|---|---|
| **Public / non-secret** | Static chart names; non-cluster-revealing feature flags; public docs; non-sensitive local defaults; expected command topology; the unencrypted-basics bootstrap surface (§16) | May live in plain Dhall or logs |
| **Sensitive topology** | Downstream cluster names/endpoints/accounts; Pulumi stack identities that reveal inventory; the in-force config; generated downstream manifests; resource-graph/checkpoint state | Encrypted at rest; unavailable when Vault is sealed |
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
  | UnlockBundleMissing FilePath
  | UnlockBundleDecryptFailed
```

Errors are operator-clear and never include secret values. Logging never emits SecretRef-resolved
values, unlock-bundle plaintext, Vault tokens, child-cluster init keys, Pulumi passphrases, object
plaintext, or downstream-cluster names on sealed-state failure paths when those names are
sensitive. Prefer redacted structured logs:

```text
vault_status=sealed component=pulumi operation=preview result=blocked
```

over identifying messages such as `Cannot deploy downstream cluster prod-eu-west-1 …`.

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

The sealed-Vault canonical validation (`prodbox test integration sealed-vault`, Sprint `5.8`)
seals Vault after a full reconcile and asserts every row above fails closed without leaking
metadata.

## 16. Cluster federation: a Vault transit-seal trust tree

prodbox manages a hierarchy of clusters — a root cluster and zero or more downstream/child
clusters. Trust, unseal authority, and config authority form a tree. This section summarizes the
contract;
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md) is the SSoT for the topology,
the auto-unseal mechanics, and the custody and config-authority flows.

### The transit-seal trust tree

| Tier | Vault seal mode | Who unseals it | Init keys (recovery keys + initial root token) owned by |
|---|---|---|---|
| **Root cluster** | Shamir | Operator only, via the `.age` unlock bundle decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests; §4, §6) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

- A child Vault literally cannot unseal without a live, unsealed parent. If any parent is
  sealed/unreachable, its children cannot unseal → the fail-closed brick cascades down from the
  root. Cluster liveness for the whole tree roots in one operator unsealing the root (§2,
  invariant 7).
- **Parents own the init keys for child clusters.** At child init, the child's recovery keys and
  initial root token are stored in the parent's Vault KV (under the
  `transit/prodbox-downstream-cluster-config` blast-radius domain; §8); the parent's transit key
  is the child's unseal authority. The root cluster's own init keys are the only ones held outside
  Vault — in the host unlock bundle (§6, the chicken-and-egg floor; §17).
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
  MinIO via Vault" (Sprint `1.38`).
- **Updating the root cluster's in-force config requires the root Vault token** (which requires an
  unsealed root Vault). Root config governs every downstream cluster — it is the keys to the
  kingdom. Reads of the basics are always free; full reads require unseal; writes require the
  privileged root token.

The CLI/gateway surface to register a child cluster and custody its init keys, and the
parent-owns-child-init-keys contract, land in Sprint `2.26`; the transit-seal hierarchy and
per-cluster seal custody land in Sprint `3.20`; the child auto-unseal and the fail-closed unseal
cascade wired into lifecycle land in Sprint `4.32`. See
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

## 17. The chicken-and-egg floor

Vault owns everything except the minimal floor it cannot bootstrap itself from. The **only** data
Vault may not own:

1. RKE2's self-signed cluster CA + admin kubeconfig (Vault runs inside this cluster's PKI).
2. The Vault PV binding itself.
3. **Root cluster only:** the operator unseal-bundle password (the key that unseals the root
   Vault) plus the `.age` unlock bundle on retained host storage
   (`.data/prodbox/vault-unlock-bundle.age`; §6).
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
| 3 | Opaque object names / indexes | Opaque object IDs + Vault-encrypted indexes, since config/topology metadata is secret (§9). | `4.30` |
| 4 | Pulumi encrypted-backend approach | Option B (Vault-derived passphrase) first, then Option A or C for full metadata secrecy (§10). | `1.37` / `7.14` |
| 5 | TLS private-key generation | cert-manager Vault issuer vs native Vault PKI vs ACME-with-Vault-stored-credentials — pick on cert-manager integration + operational simplicity (§11). | `7.15` |
| 6 | Fail-closed strictness for running workloads | Already-running workloads continue only to the extent they need no new Vault operation; security-sensitive paths prefer explicit fail-closed readiness gates over silent degraded operation (§2). The exact per-component strictness (block new reads vs fail existing readiness) is pinned by the lifecycle and sealed-vault sprints. | `4.29` / `5.8` |
| 7 | Federation depth + child-registration surface | A single root with direct children first; deeper trees and the child-registration CLI/gateway surface follow once the two-tier custody contract is proven (§16). | `2.26` / `4.32` |

## 19. Red-team checklist

Before the Vault-root finalization is considered complete (tracked across the reopened phases):

- A repo grep finds no real secret in Dhall, and no `FileSecret` / Secret-mounted Dhall fragment
  consumer remains.
- A generated cluster-manifest grep finds no real secret and no chart-generated
  `lookup`+`randAlphaNum` Secret.
- A Kubernetes Secret dump reveals no downstream-cluster metadata or Vault-bypass credential.
- A MinIO bucket dump while Vault is sealed reveals no in-force-config or Pulumi plaintext, and no
  `master-seed` object exists at all.
- Object names and indexes reveal no downstream-cluster inventory.
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

The forbidden golden-output patterns for the SecretRef golden tests (Sprint `5.8`) include
`AKIA`, `aws_secret_access_key`, `BEGIN PRIVATE KEY`, `client_secret = "…"`, `password = "…"`,
Pulumi passphrase strings, and kubeconfig user tokens.

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
