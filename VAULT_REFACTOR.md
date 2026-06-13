# Prodbox Vault Refactor Plan

Status: proposal
Scope: Prodbox host CLI, in-cluster gateway daemon, Dhall configuration contract, local RKE2 lifecycle, MinIO-backed state, Pulumi AWS validation stacks, TLS/certificate flow, and test harness.

## 1. Executive summary

Prodbox should make Vault the first-class secrets, key management, encryption-as-a-service, and PKI backend for the local cluster model.

The current Prodbox operating model has an intentionally ephemeral Kubernetes cluster: the cluster may be destroyed and recreated, while `.data/`-backed persistent volumes survive and rebind on the next spin-up. Vault should follow that model:

- Vault runs inside the local RKE2 cluster.
- Vault storage is backed by the same durable `.data/` persistent volume layer as the rest of the cluster.
- The host-side `prodbox` binary is responsible for Vault initialization, unseal, bootstrap reconciliation, and recovery UX.
- Dhall remains the typed configuration language, but `prodbox-config.dhall` must contain only non-secret topology and references to secrets, never secret values.
- The in-cluster gateway daemon's MinIO bucket becomes a secret-bearing store and must be encrypted with keys served by Vault.
- The active Dhall configuration stored for daemon use must be encrypted at rest in that MinIO bucket.
- Cluster configuration, including any knowledge of downstream clusters managed by Prodbox, must be treated as secret data.
- If Vault is sealed, it must be impossible to extract downstream-cluster metadata, active Dhall content, Pulumi state, credentials, TLS private keys, or MinIO envelope keys.
- Pulumi backends must be encrypted in a way that cannot be decrypted while Vault is sealed. Pulumi must not be able to preview, update, destroy, or otherwise deploy anything while Vault is sealed.

The resulting architecture is fail-closed:

```text
Dhall source of truth
  -> topology, policy intent, and SecretRef values only

Vault on durable PV
  -> secrets, PKI, transit keys, unlock-dependent decryption authority

MinIO on durable PV
  -> encrypted blobs only: active Dhall, daemon state, Pulumi state, artifacts

Prodbox host CLI
  -> initializes/unseals Vault, reconciles Vault policy, drives cluster lifecycle

Prodbox gateway daemon
  -> reads encrypted state from MinIO, asks Vault to decrypt/use keys, cannot operate when Vault is sealed
```

## 2. Existing assumptions and project objectives

This plan assumes the following existing Prodbox objectives and constraints:

1. The local RKE2 cluster is ephemeral.
   - `prodbox cluster delete` may remove the cluster runtime.
   - `.data/` is durable and must survive normal cluster teardown.
   - Persistent volumes rebind when the cluster is spun up again.

2. Dhall is the supported configuration contract.
   - Every `prodbox` binary instance should take exactly one Dhall config file.
   - The host CLI uses the repository-root `prodbox-config.dhall`.
   - The in-cluster daemon receives its config through cluster-managed config material.
   - `prodbox-config.json`, environment-variable precedence, and ad-hoc secret injection should not become the primary interface.

3. Prodbox has both host and in-cluster components.
   - The host-side CLI orchestrates local cluster lifecycle, charts, AWS validation stacks, and administrative flows.
   - The in-cluster Haskell gateway daemon is separate from Envoy Gateway and has daemon-owned durable state.

4. MinIO is part of the local cluster baseline.
   - The cluster baseline includes MinIO.
   - Pulumi AWS validation stacks use the repo-backed MinIO backend in the local RKE2 cluster.
   - The gateway daemon currently uses MinIO for durable daemon-owned state such as its master seed.

5. Prodbox should be safe by construction.
   - Secrets should not appear in generated configs, logs, test output, or committed Dhall.
   - Destructive and AWS-touching operations should remain explicit, typed, and leak-safe.
   - Reconciliation should be idempotent and rerunnable.

## 3. Hard security invariants

These invariants should be treated as architectural requirements, not implementation preferences.

### 3.1 Dhall invariants

`prodbox-config.dhall` must never contain plaintext secret values.

Allowed:

```dhall
{ aws =
    { credentials = SecretRef.Vault "kv/prodbox/aws/admin#access_key_id"
    }
}
```

Forbidden:

```dhall
{ aws =
    { access_key_id = "AKIA..."
    , secret_access_key = "..."
    }
}
```

`prodbox-config.dhall` may contain:

- non-secret topology;
- public endpoint names when they are not sensitive;
- Vault mount names;
- Vault policy intent;
- logical secret references;
- local cluster bootstrap policy.

`prodbox-config.dhall` must not contain:

- AWS access keys;
- ACME EAB HMAC material;
- TLS private keys;
- MinIO root credentials;
- Keycloak admin passwords or client secrets;
- Pulumi passphrases or stack secrets;
- downstream cluster kubeconfigs;
- downstream cluster hostnames, IPs, account IDs, or identities when those reveal managed-cluster inventory;
- any plaintext material needed to unseal, authenticate to, or decrypt Vault-protected state.

### 3.2 Cluster metadata is secret

The cluster config itself must be treated as secret data.

This includes:

- downstream cluster names;
- downstream cluster endpoints;
- kubeconfig material;
- cloud account IDs or regions tied to downstream clusters;
- DNS names tied to downstream clusters;
- Pulumi stack names and state for downstream clusters;
- deployment topology that reveals what Prodbox manages;
- any active Dhall content used by the in-cluster daemon.

If Vault is sealed, it must be impossible to recover this information from MinIO, Kubernetes Secrets, ConfigMaps, Pulumi backends, logs, or generated files.

### 3.3 Vault sealed-state invariant

When Vault is sealed:

- Envoy/Gateway TLS flows that require private-key access must fail closed.
- Keycloak bootstrap and secret-dependent operations must fail closed.
- The in-cluster gateway daemon must not be able to decrypt active Dhall or daemon state.
- MinIO encrypted daemon state must remain opaque.
- Pulumi state must remain opaque.
- Pulumi deployments must not run.
- AWS deployment credentials must not be obtainable.
- No downstream-cluster inventory must be extractable.

Operationally, already-running workloads may continue only to the extent that they do not need new Vault operations. For security-sensitive paths, prefer explicit fail-closed readiness gates over silent degraded operation.

### 3.4 MinIO object invariant

MinIO may store durable Prodbox state, but Prodbox-owned MinIO objects must be ciphertext unless they are explicitly public/non-sensitive artifacts.

Secret-bearing MinIO objects include:

- the gateway daemon master seed;
- active Dhall configuration used by the daemon;
- downstream cluster configuration;
- Pulumi state and history;
- generated manifests that contain secret references plus sensitive topology;
- bootstrap records;
- reconciliation checkpoints that reveal managed resources.

These objects must be encrypted using envelope encryption backed by Vault Transit.

### 3.5 Pulumi invariant

Pulumi must not be able to operate when Vault is sealed.

This means:

- Pulumi backend objects in MinIO must be encrypted with Vault-dependent envelope keys.
- Pulumi stack config secrets must not be decryptable without Vault.
- Pulumi preview/update/destroy commands must perform an explicit Vault readiness check before touching state.
- A sealed Vault must produce a clear, safe error before any AWS-side mutation is attempted.

## 4. Target architecture

### 4.1 Components

```text
Host filesystem
  .data/
    vault-pv/                  durable Vault storage
    minio-pv/                  durable MinIO storage
    prodbox-unlock-bundle.age  encrypted Vault recovery material

Host prodbox CLI
  config setup
  config validate
  cluster reconcile
  vault init
  vault unseal
  vault status
  vault reconcile
  charts reconcile
  aws stack ...

Local RKE2 cluster
  vault namespace
    vault server
    durable Vault PVC

  minio namespace
    MinIO server
    durable MinIO PVC
    prodbox bucket

  prodbox/gateway namespace
    in-cluster gateway daemon
    service account
    Vault auth role

  public-edge namespaces
    Envoy Gateway
    cert-manager
    Keycloak
    application charts
```

### 4.2 Data flow

```text
Host operator
  -> runs prodbox cluster reconcile
  -> starts/rebinds RKE2 and durable PVs
  -> starts Vault
  -> initializes Vault only if empty
  -> unseals Vault
  -> reconciles Vault mounts, policies, roles, transit keys, PKI issuers
  -> starts MinIO
  -> ensures Prodbox bucket exists
  -> configures MinIO encryption path through Vault Transit
  -> writes active Dhall as encrypted object
  -> deploys gateway daemon
  -> deploys secret-dependent charts
```

### 4.3 SecretRef model

Dhall should encode references, not values.

Conceptual Haskell shape:

```haskell
data SecretRef
  = VaultSecret VaultPath VaultField
  | VaultTransitKey TransitKeyName
  | PromptedSecret PromptSpec
  | TestPlaintext Text
  | FileSecret FilePath
```

Production config should allow `VaultSecret`, `VaultTransitKey`, and `PromptedSecret` only where appropriate.

`TestPlaintext` should be accepted only in test harness mode and only from `test-secrets.dhall`.

`FileSecret` should remain only as a migration bridge for existing Secret-mounted Dhall behavior, not as the long-term default.

## 5. Vault deployment model

### 5.1 Vault runs in-cluster

Vault should be installed as a local-cluster chart or Prodbox-owned Kubernetes deployment.

Requirements:

- Single-cluster Vault instance per Prodbox-managed local cluster.
- Durable PVC backed by `.data/`.
- Init only when no existing Vault state is found.
- No accidental reinitialization.
- Startup readiness gates that distinguish:
  - not deployed;
  - deployed but uninitialized;
  - initialized but sealed;
  - initialized and unsealed;
  - policy reconciled.

### 5.2 Vault storage

Acceptable storage modes:

1. Vault integrated storage on retained PV.
2. File storage on retained PV for development if simpler.

The important property is not the exact Vault storage backend. The important property is:

```text
cluster teardown must not destroy Vault state
```

### 5.3 Vault init

Add:

```text
prodbox vault init
```

Behavior:

- Connect to the local Vault service.
- Detect whether Vault is already initialized.
- If already initialized, return success without changing root/unseal state.
- If uninitialized, initialize Vault.
- Capture unseal/recovery keys and initial root token exactly once.
- Immediately write them to a host-side encrypted unlock bundle.
- Never print raw keys or root token to logs.
- Offer a one-time emergency display only behind an explicit `--show-sensitive-once` or similar operator-confirmed flag, if desired.

### 5.4 Unlock bundle

Do not store root/unseal material encrypted with “a SHA256 password.” SHA-256 is a hash, not encryption.

Use authenticated encryption with a real password-based key derivation function.

Recommended local backend:

```text
password
  -> Argon2id or scrypt KDF
  -> age/sops-style authenticated encryption
  -> .data/prodbox/vault-unlock-bundle.age
```

Unlock bundle contents:

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

The actual bundle should be encrypted. The JSON above is conceptual plaintext before encryption.

Future backends should be pluggable:

- local encrypted file;
- 1Password;
- pass/gopass;
- cloud KMS;
- YubiKey or age identity;
- TPM-backed host secret.

### 5.5 Vault unseal

Add:

```text
prodbox vault unseal
```

Behavior:

- Read encrypted unlock bundle.
- Prompt for unlock-bundle password unless test harness supplies it.
- Decrypt bundle in memory.
- Submit unseal keys.
- Verify Vault becomes unsealed.
- Clear sensitive material from process memory where practical.
- Do not persist plaintext unseal keys.

### 5.6 Vault reconcile

Add:

```text
prodbox vault reconcile
```

Behavior:

- Require Vault initialized and unsealed.
- Reconcile auth mounts.
- Reconcile policies.
- Reconcile roles.
- Reconcile KV mounts.
- Reconcile Transit keys.
- Reconcile PKI mounts and issuers.
- Reconcile service-account auth for in-cluster workloads.
- Reconcile Prodbox bucket encryption policy metadata.
- Reconcile Pulumi encryption configuration.

This command should be idempotent and safe to run on every cluster spin-up.

## 6. CLI topology changes

Add a `vault` command group:

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

Suggested lifecycle integration:

```text
prodbox cluster reconcile
  -> reconcile RKE2
  -> reconcile retained PV layer
  -> deploy/rebind Vault
  -> run vault init-if-empty
  -> run vault unseal if unlock material is available or prompt operator
  -> run vault reconcile
  -> deploy/rebind MinIO
  -> ensure Prodbox bucket
  -> ensure encrypted active Dhall object
  -> reconcile charts that depend on Vault
```

Do not hide Vault failure. A sealed or unreachable Vault should be surfaced as a first-class cluster status.

Add status output such as:

```text
Vault: initialized, sealed
MinIO: reachable, encrypted objects present
Active Dhall: unavailable; Vault sealed
Pulumi backend: unavailable; Vault sealed
Gateway daemon: waiting for Vault
Keycloak: blocked by Vault
Ingress TLS: blocked by Vault
```

## 7. Dhall schema refactor

### 7.1 Add typed secret references

Introduce a shared Dhall type module for secret references.

Conceptual Dhall:

```dhall
let SecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : { name : Text }
      | Prompt : { name : Text, purpose : Text }
      | TestPlaintext : Text
      >

in  SecretRef
```

Production validation rules:

- `TestPlaintext` is rejected outside the test harness.
- `Prompt` is allowed only for CLI-only, one-off elevated material.
- Any secret needed by an in-cluster component must become a Vault ref before deployment.

### 7.2 Split production config from test secrets

Use:

```text
prodbox-config.dhall
  production-safe topology and SecretRef values

test-secrets.dhall
  plaintext test harness inputs only
```

`test-secrets.dhall` may contain:

- Vault unlock-bundle password for tests;
- elevated AWS credentials used to simulate operator prompts;
- fake ACME/EAB values;
- fake MinIO credentials;
- fake Keycloak bootstrap passwords;
- fixture values needed to seed Vault in integration tests.

`test-secrets.dhall` must never be:

- required for production;
- imported by `prodbox-config.dhall`;
- copied into generated cluster config;
- stored in MinIO;
- mounted into the cluster;
- committed with real values.

### 7.3 Active Dhall as encrypted daemon state

The active Dhall used by the in-cluster gateway daemon should be stored in the daemon's MinIO bucket in encrypted form.

This means:

1. Host CLI reads and validates `prodbox-config.dhall`.
2. Host CLI resolves production-safe shape and validates that secret fields are references only.
3. Host CLI serializes the active daemon Dhall/config payload.
4. Host CLI encrypts that payload using envelope encryption backed by Vault Transit.
5. Host CLI writes only ciphertext to MinIO.
6. Gateway daemon reads ciphertext from MinIO.
7. Gateway daemon authenticates to Vault using Kubernetes auth.
8. Gateway daemon asks Vault Transit to decrypt the envelope or unwrap the data key.
9. Gateway daemon obtains active config only if Vault is unsealed and policy allows it.

Sealed Vault therefore means active Dhall is not readable.

## 8. MinIO encryption design

### 8.1 Prodbox bucket

The in-cluster gateway daemon's MinIO bucket should be treated as a Prodbox secret-bearing state store.

Suggested bucket/object layout:

```text
s3://prodbox/
  active-config/current.enc
  active-config/generations/<generation>.enc
  gateway/master-seed.enc
  gateway/checkpoints/<id>.enc
  pulumi/aws-eks/<stack>.enc
  pulumi/aws-test/<stack>.enc
  pulumi/aws-ses/<stack>.enc
  manifests/<generation>/<object>.enc
```

Do not rely on bucket names, object names, or prefixes to hide sensitive meaning. If object names reveal downstream clusters, then object names themselves become metadata leaks. Prefer opaque object IDs plus encrypted indexes.

Example safer layout:

```text
s3://prodbox/
  objects/<opaque-id>.enc
  indexes/active-config.enc
  indexes/pulumi.enc
  indexes/gateway.enc
```

The indexes are encrypted through Vault, so a sealed Vault reveals only opaque object IDs.

### 8.2 Envelope encryption

Use Vault Transit for envelope encryption.

Preferred pattern:

```text
plaintext object
  -> generate random data encryption key
  -> encrypt plaintext locally with AEAD
  -> ask Vault Transit to encrypt/wrap data encryption key
  -> store ciphertext + encrypted data key + metadata in MinIO
```

Object envelope format:

```json
{
  "format": "prodbox-envelope-v1",
  "transit_key": "prodbox-minio-objects",
  "wrapped_dek": "vault:v1:...",
  "nonce": "...",
  "aad": "...",
  "ciphertext": "...",
  "created_at": "...",
  "key_version": 1
}
```

AAD should bind:

- cluster ID;
- object logical type;
- object generation;
- schema version;
- expected bucket/object identity if object names are not sensitive.

### 8.3 Transit keys

Create separate Transit keys for separate blast-radius domains:

```text
transit/prodbox-active-config
transit/prodbox-gateway-state
transit/prodbox-pulumi-state
transit/prodbox-minio-envelope
transit/prodbox-downstream-cluster-config
```

Policies should enforce least privilege:

- gateway daemon can decrypt only active config and gateway state it needs;
- Pulumi runner can decrypt only Pulumi backend state;
- host CLI can reconcile and rotate keys;
- application workloads can use only their assigned Transit keys.

## 9. Pulumi backend refactor

### 9.1 Current problem

Pulumi state stored in MinIO can reveal:

- AWS resource names;
- account IDs;
- cluster names;
- endpoint names;
- generated identifiers;
- dependency topology;
- provider configuration;
- secrets, if Pulumi stack encryption is misconfigured.

Under the new invariant, this is secret data.

### 9.2 Target state

Pulumi backend state must be encrypted such that sealed Vault prevents decryption.

`prodbox aws stack ...` commands must perform:

```text
check Vault reachable
check Vault initialized
check Vault unsealed
check Transit key available
check Pulumi backend decryptable
only then run Pulumi
```

If Vault is sealed:

```text
Error: Vault is sealed.
Pulumi backend state is intentionally unavailable.
No preview/update/destroy was started.
```

### 9.3 Implementation options

Option A: Prodbox-managed encrypted S3 wrapper

- Prodbox stores Pulumi backend objects in MinIO as encrypted envelopes.
- Pulumi is invoked against a decrypted temporary local backend or a controlled filesystem view.
- After Pulumi completes, Prodbox re-encrypts and writes state back to MinIO.
- Pros: strong control over encryption.
- Cons: more complex locking and crash recovery.

Option B: Pulumi passphrase/secrets provider derived from Vault

- Pulumi backend remains MinIO.
- Pulumi stack secrets provider uses a Vault-derived passphrase or key.
- Prodbox obtains the passphrase only when Vault is unsealed.
- Pros: simpler integration.
- Cons: raw backend metadata may still leak unless state object itself is fully encrypted.

Option C: Vault-aware Pulumi state proxy

- Prodbox exposes a local temporary S3-compatible or filesystem proxy to Pulumi.
- Proxy encrypts/decrypts state through Vault Transit.
- Pros: clean sealed-state invariant.
- Cons: most implementation work.

Recommended path:

1. Start with Option B for stack secrets, but treat it as insufficient for the full metadata secrecy requirement.
2. Move to Option A or C for full encrypted backend objects.
3. Gate all Pulumi operations on Vault unsealed state from the beginning.

## 10. TLS and PKI refactor

### 10.1 Goal

Vault becomes the backend for TLS private keys, certificate issuance, and certificate lifecycle state.

The existing ACME/cert-manager flow should be refactored so that:

- ACME EAB secrets live in Vault.
- TLS private keys are generated by, stored in, or protected by Vault.
- Certificate issuance state is not recoverable from plaintext Kubernetes Secrets alone.
- Gateway TLS availability depends on Vault according to the fail-closed policy.

### 10.2 Vault PKI and cert-manager

Possible approaches:

1. Use Vault PKI directly for internal certificates.
2. Use cert-manager with Vault issuer for Kubernetes-native certificate issuance.
3. Continue ACME for public certs while storing ACME credentials and private key material through Vault-backed workflows.

### 10.3 Sealed behavior

When Vault is sealed:

- new certificate issuance must fail;
- private-key retrieval must fail;
- Envoy/Gateway TLS configuration should not be regenerated from plaintext;
- existing in-memory listeners may continue only if that is intentionally accepted;
- restarts should fail closed rather than reconstruct TLS from Kubernetes Secrets.

This should be documented as an explicit availability/security tradeoff.

## 11. Keycloak refactor

Keycloak should depend on Vault for:

- admin bootstrap password;
- database credentials;
- client secrets;
- OIDC signing or encryption material if applicable;
- any Prodbox-created realm/bootstrap secrets.

A sealed Vault should brick Keycloak bootstrap and secret-dependent startup.

Recommended behavior:

```text
Vault unsealed:
  Keycloak can start/reconcile.

Vault sealed:
  Keycloak init containers/readiness gates fail.
  Existing pods may remain running only if they already have needed material in memory.
  New pods should not reconstruct secrets from Kubernetes Secret plaintext.
```

Long term, prefer Vault Agent Injector, CSI Secret Store with Vault provider, or direct application-side Vault auth depending on chart ergonomics.

## 12. AWS secret refactor

### 12.1 Elevated operator secrets

The normal CLI UX may prompt for one-off elevated secrets.

Example:

```text
prodbox aws admin bootstrap
  -> prompts for operator AWS credentials
  -> creates least-privilege IAM identities
  -> stores resulting identities in Vault
  -> discards elevated credentials
```

The prompted elevated credentials should not be written to `prodbox-config.dhall`.

### 12.2 IAM identities created by Prodbox

IAM users/roles/access keys created by Prodbox should live in Vault.

Dhall should contain references such as:

```dhall
{ awsValidation =
    { deployerCredentials =
        SecretRef.Vault
          { mount = "kv"
          , path = "prodbox/aws/validation/deployer"
          , field = "access_key_id"
          }
    }
}
```

### 12.3 Local RKE2 AWS deployments

After initial Vault init and unseal, AWS secrets needed in the local RKE2 cluster for AWS deployments should be stored in Vault and consumed through Vault-authenticated flows.

No AWS deployment path should depend on plaintext credentials in Dhall.

## 13. In-cluster service auth

Use Vault Kubernetes auth idiomatically.

For each service needing secrets or encryption-as-a-service:

- create a Kubernetes service account;
- create a Vault role bound to namespace and service account;
- create least-privilege Vault policy;
- authenticate with service-account JWT;
- read only assigned KV paths or use only assigned Transit keys.

Services that should use Vault:

- gateway daemon;
- Keycloak init/reconcile paths;
- cert-manager or certificate reconciler;
- Pulumi runner if in-cluster;
- MinIO encryption helper/controller if separate;
- any service needing encryption as a service.

## 14. Config and state classification

Classify all Prodbox data explicitly.

### Public/non-secret

May be stored in plain Dhall or logs:

- static chart names;
- feature flags that reveal no managed cluster inventory;
- public docs;
- non-sensitive local defaults;
- expected command topology.

### Sensitive topology

Must be encrypted at rest and unavailable when Vault is sealed:

- downstream cluster names;
- downstream cluster endpoints;
- downstream cluster accounts;
- Pulumi stack names if they reveal managed inventory;
- active daemon Dhall;
- generated manifests for downstream clusters;
- resource graph/checkpoint state.

### Secret material

Must live in Vault or Vault-encrypted envelopes:

- passwords;
- access keys;
- private keys;
- tokens;
- ACME EAB material;
- Keycloak client secrets;
- MinIO credentials;
- Pulumi passphrases;
- unseal/recovery material, encrypted in the unlock bundle.

## 15. Test-suite refactor

### 15.1 Test config split

Tests should use:

```text
prodbox-config.dhall
  no plaintext secrets
  production-like SecretRef values

test-secrets.dhall
  plaintext values used to simulate user prompts and fixture seeding
```

`test-secrets.dhall` may contain a Vault unlock-bundle password for testing.

This password is test-only. It simulates an operator entering the unlock-bundle password.

### 15.2 Test flows

Add tests for:

1. `prodbox-config.dhall` rejects plaintext secrets in production mode.
2. `test-secrets.dhall` is accepted only by test harness code.
3. Vault init creates encrypted unlock bundle.
4. Vault unseal succeeds using password from `test-secrets.dhall`.
5. Vault reconcile creates KV, Transit, PKI, policies, and Kubernetes auth roles.
6. AWS fixture secrets are seeded into Vault after init/unseal.
7. Active Dhall is encrypted before writing to MinIO.
8. Gateway daemon cannot read active Dhall when Vault is sealed.
9. MinIO daemon bucket objects are ciphertext.
10. Pulumi commands refuse to run when Vault is sealed.
11. Pulumi backend state cannot be decrypted when Vault is sealed.
12. Downstream-cluster metadata is not visible from MinIO object plaintext, Kubernetes ConfigMaps, Kubernetes Secrets, or logs.
13. Keycloak startup/reconcile fails closed when Vault is sealed.
14. TLS issuance/reconcile fails closed when Vault is sealed.
15. Cluster teardown preserves Vault and MinIO PVs.
16. Cluster spin-up rebinds Vault and MinIO PVs and recovers after unseal.

### 15.3 Golden tests

Add golden tests for generated Dhall/config artifacts to ensure they contain only `SecretRef` values.

Forbidden golden output patterns:

```text
AKIA
aws_secret_access_key
BEGIN PRIVATE KEY
client_secret = "..."
password = "..."
pulumi passphrase
kubeconfig user token
```

### 15.4 Sealed Vault integration tests

Create an integration test mode:

```text
prodbox test sealed-vault
```

It should:

1. Spin up cluster.
2. Initialize and unseal Vault.
3. Reconcile MinIO, active Dhall, Pulumi backend, and charts.
4. Seal Vault.
5. Attempt to read active Dhall from MinIO.
6. Attempt Pulumi preview.
7. Attempt gateway daemon config load.
8. Attempt Keycloak reconcile.
9. Attempt TLS reconcile.
10. Assert all fail closed without leaking metadata.

## 16. Migration plan

### Phase 1: Types and validation

- Introduce `SecretRef` in Haskell.
- Introduce Dhall type for `SecretRef`.
- Refactor sensitive settings fields to use `SecretRef`.
- Add validation that production config rejects plaintext secrets.
- Add `test-secrets.dhall` support in test harness only.

Deliverable:

```text
prodbox config validate
  -> proves production config contains no plaintext secrets
```

### Phase 2: Vault lifecycle commands

- Add `prodbox vault status`.
- Add `prodbox vault init`.
- Add encrypted unlock bundle.
- Add `prodbox vault unseal`.
- Add `prodbox vault reconcile`.
- Add idempotent init-if-empty behavior.

Deliverable:

```text
cluster can be torn down and recreated;
Vault PV rebinds;
operator unseals with encrypted unlock bundle;
Vault state survives.
```

### Phase 3: Vault KV for existing secrets

- Move AWS credentials to Vault.
- Move ACME/EAB material to Vault.
- Move Keycloak bootstrap secrets to Vault.
- Move MinIO credentials to Vault.
- Keep file-mounted Dhall secrets only as migration compatibility.

Deliverable:

```text
prodbox-config.dhall has references only;
all current production secrets live in Vault.
```

### Phase 4: Transit-backed MinIO encryption

- Create Transit keys.
- Implement envelope encryption library.
- Encrypt gateway master seed.
- Encrypt active Dhall in Prodbox bucket.
- Encrypt daemon checkpoints and sensitive indexes.
- Make gateway daemon unable to start without Vault decrypt rights.

Deliverable:

```text
MinIO Prodbox bucket contains ciphertext only;
sealed Vault makes active Dhall unreadable.
```

### Phase 5: Pulumi backend encryption

- Gate Pulumi commands on Vault unsealed state.
- Move Pulumi secrets provider material to Vault.
- Encrypt Pulumi backend state objects.
- Prevent preview/update/destroy when Vault is sealed.
- Add sealed-state tests.

Deliverable:

```text
Pulumi cannot deploy, preview, destroy, or decrypt state while Vault is sealed.
```

### Phase 6: TLS/PKI refactor

- Move ACME and TLS private-key material behind Vault.
- Decide cert-manager Vault issuer vs Prodbox-managed PKI path.
- Refactor certificate reconciliation to use Vault.
- Add fail-closed sealed-state behavior.

Deliverable:

```text
TLS private key material is Vault-protected;
sealed Vault bricks TLS reconciliation and restart recovery.
```

### Phase 7: Keycloak and service integration

- Move Keycloak secrets to Vault.
- Add Vault auth for Keycloak secret consumption.
- Add readiness/init failure when Vault is sealed.
- Repeat pattern for other services needing encryption as a service.

Deliverable:

```text
Keycloak is intentionally unavailable for secret-dependent operations when Vault is sealed.
```

### Phase 8: Metadata hardening

- Audit MinIO object names and indexes.
- Replace metadata-bearing paths with opaque object IDs where needed.
- Encrypt indexes.
- Audit logs for downstream-cluster metadata leakage.
- Audit Kubernetes ConfigMaps and Secrets.
- Audit Pulumi stack names and local work dirs.

Deliverable:

```text
sealed Vault prevents extraction of downstream-cluster inventory and topology.
```

## 17. Implementation notes

### 17.1 Haskell modules

Likely module areas:

```text
Prodbox.Settings.SecretRef
Prodbox.Vault.Client
Prodbox.Vault.Bootstrap
Prodbox.Vault.UnlockBundle
Prodbox.Vault.Reconcile
Prodbox.Crypto.Envelope
Prodbox.Minio.EncryptedObject
Prodbox.Pulumi.EncryptedBackend
Prodbox.Test.Secrets
```

### 17.2 Error model

Introduce typed errors such as:

```haskell
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

Errors should be operator-clear and must not include secret values.

### 17.3 Logging

Never log:

- SecretRef resolved values;
- unlock bundle plaintext;
- Vault tokens;
- Pulumi passphrases;
- object plaintext;
- downstream-cluster names in sealed-state failure paths if those names are considered secret.

Prefer redacted structured logs:

```text
vault_status=sealed component=pulumi operation=preview result=blocked
```

Avoid:

```text
Cannot deploy downstream cluster prod-eu-west-1 because Vault is sealed
```

if `prod-eu-west-1` is sensitive.

## 18. Operator UX

### First bring-up

```text
prodbox config setup
prodbox host ensure-tools
prodbox cluster reconcile
```

During first reconcile:

```text
Vault is not initialized.
Initialize now? yes
Choose unlock-bundle password: ********
Confirm unlock-bundle password: ********
Vault initialized.
Vault unsealed.
Vault policies reconciled.
MinIO encrypted bucket reconciled.
Active Dhall encrypted and stored.
```

### Later spin-up after cluster teardown

```text
prodbox cluster reconcile
```

Output:

```text
Vault PV rebound.
Vault is initialized and sealed.
Enter unlock-bundle password: ********
Vault unsealed.
Vault policy reconciled.
MinIO bucket available.
Active Dhall decrypted check succeeded.
Pulumi backend decrypt check succeeded.
```

### Sealed Vault

```text
prodbox aws stack eks reconcile
```

Output:

```text
Blocked: Vault is sealed.
Pulumi backend state and AWS deployment credentials are intentionally unavailable.
No Pulumi command was started.
Run: prodbox vault unseal
```

## 19. Red-team checklist

Before considering the refactor complete, verify:

- A repo grep does not find real secrets in Dhall.
- A generated cluster manifest grep does not find real secrets.
- A Kubernetes Secret dump does not reveal downstream-cluster metadata or credentials needed to bypass Vault.
- A MinIO bucket dump while Vault is sealed reveals no active Dhall plaintext.
- A MinIO bucket dump while Vault is sealed reveals no Pulumi plaintext state.
- Object names and indexes do not reveal downstream-cluster inventory.
- Sealed Vault blocks Pulumi before preview/update/destroy starts.
- Sealed Vault blocks gateway daemon config recovery.
- Sealed Vault blocks Keycloak bootstrap/recovery.
- Sealed Vault blocks TLS private-key reconstruction.
- Test harness plaintext is isolated to `test-secrets.dhall` and never used by production paths.
- Unlock-bundle password is handled by KDF + authenticated encryption, not raw SHA-256.
- Vault root token is not used as the steady-state admin path.
- Vault init is never accidentally rerun against existing state.
- Cluster teardown preserves Vault and MinIO PVs.
- Cluster recreate cannot recover secrets without unsealing Vault.

## 20. Open design decisions

1. Which Vault storage backend should Prodbox use initially?
   - Integrated storage on retained PV is likely the cleanest long-term path.

2. Should the unlock bundle store the initial root token long-term?
   - Safer pattern: store recovery/unseal material, create named admin tokens/roles, and revoke or rotate the initial root token after bootstrap.

3. Should active Dhall object names be opaque?
   - If active config metadata is considered secret, yes.

4. Should Pulumi use a Prodbox-managed encrypted backend wrapper or a Vault-derived passphrase first?
   - For the full metadata secrecy invariant, a wrapper/proxy is eventually needed.

5. Should TLS private keys be generated in Vault, stored in Vault, or wrapped by Vault?
   - Pick based on cert-manager integration and operational simplicity.

6. How strict should fail-closed runtime behavior be for already-running workloads?
   - Decide whether sealed Vault should merely block new secret reads or actively make readiness fail for existing components.

## 21. Recommended final shape

The final architecture should be summarized as:

```text
prodbox-config.dhall
  typed, declarative, production-safe topology
  contains only SecretRef values for sensitive fields

Vault
  per-cluster durable secret root
  owns KV, Transit, PKI, Kubernetes auth, service policies

MinIO
  durable object store
  stores only Vault-encrypted Prodbox-owned state
  stores active Dhall only as ciphertext
  stores Pulumi backend only as ciphertext

Prodbox host CLI
  trusted bootstrap and reconciliation authority
  prompts for one-off elevated material
  stores resulting identities in Vault
  blocks secret-dependent operations when Vault is sealed

Prodbox in-cluster daemon
  authenticates to Vault with Kubernetes auth
  reads encrypted state from MinIO
  cannot recover active config or downstream-cluster knowledge while Vault is sealed

Test harness
  uses test-secrets.dhall to simulate prompts and unlock passwords
  never imports test secrets into production config
```

The most important sentence for the refactor is:

> Sealed Vault must reduce Prodbox to an opaque durable-data pile: PVs and MinIO objects may still exist, but they must not reveal secrets, active Dhall, Pulumi state, or downstream-cluster inventory until Vault is unsealed.
