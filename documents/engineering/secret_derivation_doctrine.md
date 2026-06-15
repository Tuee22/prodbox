# Vault-Backed Secret Management Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md),
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

> **Purpose**: Single source of truth for how prodbox stores and serves every secret the
> stack uses as a Vault object, and the host↔cluster boundary across which those secrets
> are fetched.
>
> **Filename note.** This file is named `secret_derivation_doctrine.md` for link
> stability only. The HMAC master-seed *derivation* model it once described is retired;
> the document now describes the Vault-KV secret-management model. The filename is
> retained so the docs that already reference it keep working — see
> [vault_doctrine.md](./vault_doctrine.md) for the finalized Vault-root statement.

## 1. Why this doctrine exists

Every secret, credential, key, and certificate the stack uses is a single class:
a **Vault object**. There is no second store, no host-side cache, and no plaintext
fallback. The earlier two-class split — "data-bound" secrets derived from a master seed
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

Because the secret and the data it protects now share Vault's retained PV, the operator
never reasons about a separate disaster-recovery artifact: wiping `.data/` removes both
Vault's storage and the data it protected together, and a fresh `vault init` mints a fresh
KV tree against fresh PVs.

## 2. Vault is the only secrets backend

Every prodbox secret is one of three Vault object shapes:

| Shape | Vault subsystem | Used for |
|---|---|---|
| KV v2 secret | `secret/` KV engine | passwords, API keys, OIDC client secrets, SMTP creds, AWS IAM creds, ACME EAB material |
| Transit key | `transit/` engine | envelope encryption of MinIO objects (in-force config, gateway state, Pulumi backend state, indexes) |
| PKI certificate | `pki/` engine | internal TLS leaf/intermediate certs; public ZeroSSL key material is Vault-protected |

There is no `master-seed` object in MinIO and no HMAC derivation. A secret that was
previously derived (Patroni/Postgres passwords, Keycloak admin, OIDC client secrets,
gateway event keys) is generated once and written to a Vault KV path; a secret that was
previously chart-generated behind a `lookup`-guarded `randAlphaNum` (MinIO root, internal
TLS) is generated once into Vault KV/PKI. Each in-cluster consumer authenticates to Vault
with its Kubernetes service account and reads the object it is authorized for — no chart
Helm template generates or stores a secret value.

The retirement of the master-seed/HMAC mechanism (the `Prodbox.Secret.{Derive,MasterSeed,
Inventory}` modules, the gateway daemon `/v1/secret/derive` + `/v1/secret/ensure-namespace`
RPC, the `checkRawMasterSeedReadScope` daemon-only-seed lint, and `selfBootstrapOwnSecrets`)
is tracked on the legacy ledger and owned by Sprint `3.19`. See
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).
This doctrine describes the finalized target; the implementation sprints below are Planned
or Active until validated.

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
exactly its own KV paths and nothing else. Removal is owned by Sprint `3.19`; the ledger
rows are in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

## 5. Secret inventory: Vault path, owning policy, consuming service account

This table is the authoritative inventory of every secret prodbox manages. Each secret maps
to a Vault object (KV path, Transit key, or PKI role), the Vault policy that grants access
to it, and the Kubernetes service account that consumes it via Vault Kubernetes auth.

| Secret | Vault object | Owning Vault policy | Consuming service account |
|---|---|---|---|
| Patroni application role | `secret/<ns>/<release>/patroni/app` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<release>-pg` |
| Patroni superuser role | `secret/<ns>/<release>/patroni/superuser` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<release>-pg` |
| Patroni standby role | `secret/<ns>/<release>/patroni/standby` (KV) | `policy/<ns>-<release>-pg` | `<ns>:prodbox-<release>-pg` |
| Keycloak admin password | `secret/keycloak/admin` (KV) | `policy/keycloak` | `keycloak:keycloak` |
| Keycloak DB credentials | `secret/keycloak/db` (KV) | `policy/keycloak` | `keycloak:keycloak` |
| OIDC client secrets | `secret/<ns>/oidc/<client>` (KV) | `policy/<ns>-oidc` | `<ns>:<consumer>` |
| Keycloak SMTP credentials | `secret/keycloak/smtp` (KV) | `policy/keycloak-smtp` | `keycloak:keycloak`, `vscode:keycloak` |
| Gateway peer-event key | `secret/<ns>/gateway/<node-id>/event-key` (KV) | `policy/<ns>-gateway` | `<ns>:prodbox-gateway` |
| MinIO root credentials | `secret/minio/root` (KV) | `policy/minio` | `minio:minio` |
| ACME EAB material | `secret/acme/eab` (KV) | `policy/acme` | `cert-manager:cert-manager` |
| AWS IAM identities (prodbox-created) | `secret/aws/<identity>` (KV) | `policy/aws-<identity>` | the gateway / Pulumi runner SA |
| Internal TLS certs (any chart) | `pki/issue/<role>` (PKI) | `policy/pki-<role>` | per-chart workload SA |
| Object-store envelope DEKs | `transit/keys/prodbox-envelope-v1` (Transit) | `policy/transit-envelope` | `<ns>:prodbox-gateway` |
| Service-account tokens | n/a — Kubernetes-managed | n/a | k8s generates and rotates automatically |

Adding a new secret to any chart or code path requires a same-change row in this table,
naming its Vault object, owning policy, and consuming service account. There is no
chart-template `lookup`+`randAlphaNum` path and no gateway-derived path; the only sanctioned
secret surface is a Vault object fetched via Vault Kubernetes auth. Storing secrets on the
operator host is forbidden; the `forbidDotProdboxState` lint in `prodbox dev check` enforces
this. The one-off elevated operator AWS admin credential is the sole exception to the
"in Vault" rule — it is prompted via `SecretRef.Prompt`, used, and discarded, never written
to `prodbox-config.dhall` and never persisted. See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and
[aws_admin_credentials.md](./aws_admin_credentials.md).

The Vault path / policy / service-account adoption across the canonical chart set is
scheduled under Sprints `3.18` (chart and Keycloak secrets via Vault Kubernetes auth),
`3.19` (retire master-seed derivation; Vault KV is the sole store), and `8.9` (Keycloak
SMTP + invite secrets via Vault); it is not yet implemented.

## 6. Host↔cluster boundary

In-cluster consumers authenticate to Vault directly with their Kubernetes service account —
no gateway derive RPC, no Secret-mounted plaintext Dhall fragment, no
`/etc/gateway/secrets/*.dhall` mount. The `SecretRef.Vault` reference names the Vault mount,
path, and field; the consumer's Vault Kubernetes-auth role and policy decide what it may
read.

The host CLI never holds a raw seed (there is none) and never reads in-cluster workload
secrets. It reads only the **unencrypted basics** locally — the minimal, non-revealing
bootstrap needed to reach and unseal Vault (cluster id, this cluster's Vault address, seal
mode, and, for a child cluster, the parent reference it must contact to auto-unseal) — then
fetches and decrypts the in-force configuration from MinIO via Vault. Nothing about
workloads, downstream clusters, or credentials is legible from the basics. See
[config_doctrine.md](./config_doctrine.md) and
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

The host firewall posture is unchanged: the gateway daemon's NodePort is restricted to
`127.0.0.1` on the operator host via an iptables rule installed by
`prodbox cluster reconcile` (in `src/Prodbox/Host.hs`, exposed through `host firewall`),
surviving reboot via `iptables-save` and removed by `prodbox cluster delete --yes`. That
rule scopes the gateway's `/v1/state` and peer-event surfaces; it no longer fronts any
`/v1/secret/*` route, because those routes are removed (§4).

## 7. Bootstrap order

Vault must be reachable, initialized, and unsealed before any secret resolves. The reconcile
order:

1. `prodbox cluster reconcile` brings RKE2 up.
2. Storage prerequisites bring up MinIO with its root credentials sourced from Vault KV
   (`secret/minio/root`) once Vault is available; on the first-ever bring-up MinIO's root
   is minted into Vault as part of Vault platform install.
3. The Vault chart (`charts/vault/`) deploys on the same ephemeral-PVC / retained-PV pattern
   as MinIO. On a fresh PV, `vault init` runs exactly once; on every subsequent reconcile,
   the existing data is only unsealed (init-once / unseal-on-rebuild). A root cluster is
   unsealed by the operator via the `.age` unlock bundle; a child cluster auto-unseals
   against its parent's Vault Transit seal — see
   [cluster_federation_doctrine.md](./cluster_federation_doctrine.md).
4. Vault becomes ready; its KV/Transit/PKI engines and per-domain policies + Kubernetes-auth
   roles are configured.
5. Chart deploys proceed. Each workload's service account authenticates to Vault via
   Kubernetes auth and reads exactly the Vault objects its policy grants (§5). No chart
   pre-install Job materializes secrets; no Helm `lookup` resolves a secret value.

**Ordering constraint: Vault ready before any secret consumer.** No consumer of a secret may
run before Vault reports reachable, initialized, and unsealed (and, for a child cluster,
auto-unsealed against its parent). Vault is the sole secrets authority; a consumer that
reaches Vault before it is unsealed fails closed (§3) rather than racing it.

[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) §5 is the
authoritative reference for the inverse (teardown) order.

## 8. Failure modes

| Failure | Surface | Response |
|---|---|---|
| Vault sealed / unreachable / uninitialized | not yet unsealed after bring-up, re-sealed mid-flight, or a sealed parent for a child cluster | no secret resolves, no cert issues, no Transit unwrap; consumers fail their readiness gate and report a waiting-for-Vault reason (fail closed). See [vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix) |
| Vault KV path missing | first-ever bring-up before the secret is minted, or a misconfigured policy | the platform install mints the object once into the path under a read-then-write guard; a consumer reaching an unminted path before install completes fails closed and retries after install |
| Vault policy denies the read | service account bound to the wrong Vault role, or a path typo | the consumer receives a permission-denied from Vault and fails its readiness gate; never a silent fallback to a non-Vault source (none exists) |
| Generated secret mismatches preserved `pg_authid` | preserved `.data/` whose Postgres hash was written under a different Vault KV value (e.g., Vault re-initialized while the PG datadir was preserved) | a loud failure naming the namespace/role pair: the operator must either restore the matching `.data/` or wipe the affected `.data/<ns>/prodbox-<root-chart>-pg/` subtree. A fresh install or any un-observable probe proceeds — only a proven authentication rejection fails loudly. Never a silent destructive reset |
| Vault unreachable from host | Vault Service down, or host can't reach the cluster | the host CLI returns a structured error; never silently falls back to a host-side cache (none exists) |

The fourth row is the load-bearing failure case. It is loud by design: silent data reset on
a secret mismatch is precisely the failure mode the pre-doctrine
`.prodbox-state/<ns>/.secrets.json` cache used to hide. The mismatch is detected up-front and
reported; the pure decision (loud-failure policy) is kept separate from the boundary probe
and is unit-tested so a definite `pg_authid` rejection is the only path to a loud failure and
an un-observable probe proceeds, so the guard never blocks an ordinary first install. This
guard is owned by the Vault-secret-adoption sprints (`3.18` / `3.19`) and is Planned until
validated.

## Cross-References

- [vault_doctrine.md](./vault_doctrine.md) — the finalized Vault-root statement: SecretRef
  model, fail-closed invariant, Transit envelopes, MinIO ciphertext store, sealed-state
  matrix
- [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) — the root/child
  Vault transit-seal trust tree, parent custody of child init keys, and the fail-closed
  unseal cascade
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained
  `.data/vault/vault/0` PV, init-once / unseal-on-rebuild, and Vault state surviving teardown
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — chart/workload
  secrets come only from Vault via Vault Kubernetes auth
- [config_doctrine.md](./config_doctrine.md) — the unencrypted-basics local surface and the
  Vault-encrypted in-force config in MinIO as SSoT
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — gateway
  daemon endpoint surface (the `/v1/secret/*` routes are removed)
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — the
  cascade order that releases MinIO-tracked AWS resources before cluster uninstall
- [cli_command_surface.md](./cli_command_surface.md) — the `host firewall` subcommand that
  installs the iptables rule
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — the retired master-seed/HMAC derivation modules + daemon RPC and the
  `.prodbox-state/<ns>/.secrets.json` host cache on the cleanup ledger
