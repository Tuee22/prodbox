# Config Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[../../README.md](../../README.md),
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md),
[../../CLAUDE.md](../../CLAUDE.md),
[../../AGENTS.md](../../AGENTS.md),
[../documentation_standards.md](../documentation_standards.md),
[cli_command_surface.md](./cli_command_surface.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[dependency_management.md](./dependency_management.md),
[haskell_code_guide.md](./haskell_code_guide.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[vault_doctrine.md](./vault_doctrine.md),
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[unit_testing_policy.md](./unit_testing_policy.md),
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md](../../DEVELOPMENT_PLAN/phase-0-planning-documentation.md),
[../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
**Generated sections**: none

> **Purpose**: Single source of truth for how every `prodbox` binary instance — host CLI and
> in-cluster gateway daemon — sources, parses, watches, and reloads its configuration.

## 1. Why this doctrine exists

Every `prodbox` process needs configuration: hostnames, AWS coordinates, ports, ranked-node
inventories, timing knobs, credentials, TLS material. Historically the supported architecture
collected those values from a mix of sources: a repository-root `prodbox-config.dhall` for
host-CLI bootstrap settings, a per-Pod `config.json` rendered by the gateway chart for
daemon runtime knobs, a per-Pod `orders.json` for cluster topology, environment variables for
credentials and selected overrides (`AWS_*`, `MINIO_*`, `GATEWAY_NODE_ID`,
`PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT`, `PRODBOX_WORKLOAD_MODE`), and
files mounted from k8s Secrets for cryptographic material. The reload path was different
again — SIGHUP on the daemon, full process restart on the host, no live reload for chart
workloads.

That mix is no longer the supported architecture. Every `prodbox` binary takes its
configuration from exactly one Dhall file. The in-cluster binaries — the gateway daemon and
the workload Pods — name that file with a `--config <path>` flag (the chart passes the
mounted ConfigMap path). The **host CLI** locates the repo root and reads the on-disk
`prodbox-config.dhall` as a *seed/propose input only* — never as the in-force source of truth.
Either way the rule is one Dhall file per process and nothing else, and that file carries no
secret material. Sensitive fields are typed `SecretRef` values, never inline plaintext: the
production targets are `SecretRef.Vault` / `SecretRef.TransitKey` references resolved through
Vault. In-cluster consumers authenticate to Vault directly via Vault Kubernetes auth — there
are no Secret-mounted Dhall credential fragments and no `as Text` credential imports. See
[vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model) and
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth).

The reload model is symmetric: the running binary watches the file at its `--config` path,
classifies each on-disk change as a BootConfig change (drain + exit so kubelet restarts the
Pod) or a LiveConfig change (atomic STM swap, no restart), and acts accordingly. SIGHUP is no
longer the canonical reload trigger.

One further inversion governs *what the file means*. The in-force cluster configuration is not
the on-disk Dhall — it is a Vault-Transit-enveloped object in MinIO. The filesystem
`prodbox-config.dhall` is a seed/propose input that bootstraps or proposes an update to that
encrypted source of truth; the binary reads only the unencrypted basics locally and fetches +
decrypts the in-force config through Vault. Section 1a states this inversion in full; the
SecretRef union (Section 6.2), the import rules (Section 5), and the cluster mount contract
(Section 6) are all expressed against it.

## 1a. The in-force config lives encrypted in MinIO

The **in-force cluster configuration** is stored as a prodbox object-level Vault-Transit
envelope, and that encrypted object is the single source of truth. It is not a distinct
mechanism: the in-force config is one logical object routed through the same §9 object-store
every prodbox-owned secret-bearing object uses. It lands as an opaque, HMAC-named
`objects/<id>.enc` ciphertext in the one generically-named bucket — **never** under a literal,
role-revealing `in-force-config` key. The id↔logical map lives only in the Vault-encrypted
index, so a sealed-Vault MinIO listing exposes only opaque object IDs at a decoy-padded constant
count, never the fact that an in-force config exists. When Vault is sealed the object is opaque
ciphertext: nothing about the cluster's setup, its workloads, or its child clusters is
determinable beyond the *unencrypted basics*. This is the same fail-closed posture every other
prodbox-owned MinIO object obeys — a sealed Vault reduces prodbox to an opaque durable-data
pile. See [vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store) and
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

**One object-store, two accessors.** The same object-store — one envelope, HMAC-naming, and
index discipline — is shared by host and daemon accessors. Each binds its own Vault-auth
`DekCipher`: the host CLI through the root Vault token, daemon-side access through Vault
Kubernetes auth over the in-cluster MinIO Service DNS. Sprint `4.30` lands the shared pure layer
and the host production in-force read through an opaque object key; the current gateway daemon has
no durable MinIO state writer left after the master-seed removal. A future daemon-side durable read
or write uses the same `Prodbox.Minio.EncryptedObject` layer and recovers a logical object only
while Vault is unsealed and its policy permits the Transit unwrap. See
[vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store).

**Unencrypted basics.** The basics are the minimal, non-revealing bootstrap needed only to
reach and unseal Vault: the cluster id, this cluster's Vault address, the seal mode, and (for a
child cluster) the parent reference it must contact to auto-unseal. The basics carry nothing
about workloads, downstream clusters, or credentials. Reads of the basics are always free —
they are exactly the surface a host that cannot yet reach an unsealed Vault is allowed to see.
The Phase `1` file surface is `.data/prodbox/unencrypted-basics.json`, loaded and validated by
`Prodbox.Settings.loadUnencryptedBasics`.

**Filesystem Dhall is seed/propose, not SSoT.** A filesystem `prodbox-config.dhall` is a
seed/propose input only. On first-ever bring-up it seeds the encrypted MinIO source of truth;
thereafter supplying a file is a *proposed update*, reconciled into the in-force config rather
than read as the live config. The prior host-CLI model — read the repo-root
`prodbox-config.dhall` directly as the live config — is replaced by "read the basics locally,
fetch and decrypt the in-force config from MinIO via Vault." The Sprint `1.38` foundation has
landed the Dhall-payload decoder (`decodeConfigDhallBytes`) and the injected
`fetchInForceConfigWith` / `storeInForceConfigWith` composition. Sprint `4.30` routes the
production MinIO read through `Prodbox.Minio.EncryptedObject` / `ObjectStore`: `Settings` reads
`secret/object-store/hmac` from Vault, computes the opaque key for `LogicalInForceConfig`, and
fetches from the `prodbox-state` bucket. The global `validateAndLoadSettings` behavior flip is
implemented: once unencrypted basics exist, ordinary host settings loads use basics → ready Vault
root token → Vault KV MinIO credentials → object-store envelope fetch/decrypt/decode instead of
treating repo-root Dhall as the live source of truth. The lifecycle reconcile path uses repo-root
Dhall only as bootstrap/propose input for the pre-Vault/pre-MinIO steps, then reloads the in-force
settings through Vault and MinIO before chart and edge work continues; for a child cluster that
reload uses the child root token custodied in the parent Vault KV (Sprint `4.32`).

**Root-token-gated config writes.** Updating the *root cluster's* in-force config requires the
root Vault token, which in turn requires an unsealed root Vault. Root config governs every
downstream cluster — it is the keys to the kingdom. The authority ladder is: reads of the basics
are free; a full read of the in-force config requires an unsealed Vault; a write to the root
cluster's in-force config requires the privileged root token. The root/child trust tree, the
transit-seal auto-unseal, and downstream-cluster custody are owned by
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md). (The local basics and
in-force-config foundation are in Sprint `1.38`; the federation surface is in Sprint `2.26`; the
root Shamir / child Transit seal model is in Sprint `3.20`. The pure root-write decision and
rendered refusal are in `Prodbox.Config.InForce`; the child lifecycle and post-MinIO settings
reload are wired under Sprint `4.32`.)

## 2. Single Dhall surface per binary instance

Each `prodbox` binary instance sources configuration from exactly one Dhall file. The
in-cluster binaries name that file with a CLI flag:

```
prodbox <gateway|workload subcommand> --config <path-to-dhall-file>
```

The host CLI takes no `--config` flag at all. It resolves the canonical repository-root
`prodbox-config.dhall` automatically by locating the repo root, so the operator never names
the path:

```bash
# The host CLI resolves the repo-root prodbox-config.dhall via findRepoRoot;
# there is no --config flag to pass.
prodbox dev check
```

Example in the cluster:

```yaml
# charts/gateway/templates/deployments.yaml
args:
  - --config
  - /etc/gateway/config.dhall
```

Forbidden alternatives:

- `--config-path` env-var fallback (any spelling of `PRODBOX_CONFIG_PATH`, `GATEWAY_CONFIG_PATH`, etc.).
- `--log-level`, `--port`, `--node-id`, `--foreground` and similar runtime-override flags. Every value the binary needs lives in the Dhall file.
- `prodbox-config.json` (or any other generated JSON projection of the Dhall) on a supported path. `prodbox config compile` is not a supported subcommand.
- Reading any other Dhall file silently (the binary never falls back to `~/.config/prodbox.dhall` or `/etc/prodbox/...` if `--config` is omitted; the canonical resolution is named below).

The single-file rule is about the binary's CLI surface, not about the content of that file:
the Dhall expression may, and frequently will, import sibling Dhall files via Dhall's native
import syntax (Section 5).

## 3. Canonical paths

| Binary instance | Canonical Dhall path | Resolution |
|---|---|---|
| Host CLI (`prodbox` on the operator host) | Seed/propose `./prodbox-config.dhall` plus `.data/prodbox/unencrypted-basics.json` (resolved against the repository root) | `src/Prodbox/Repo.hs::canonicalConfigPaths` + `src/Prodbox/Settings.hs::loadConfigForSettingsWith`; when basics are absent it reads the filesystem file as the first-bring-up seed, and when basics exist it fetches/decrypts the in-force MinIO envelope via Vault |
| In-cluster gateway daemon | `/etc/gateway/config.dhall` | chart-side ConfigMap mount; see [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) |
| In-cluster workload Pods (`api`, `websocket`) | `/etc/workload/config.dhall` | chart-side ConfigMap mount on the owning workload chart |

The host CLI has no `--config` flag; it always resolves the canonical repo-root path via
`findRepoRoot` + `canonicalConfigPaths`. Inside the cluster the deployments always pass
`--config <path>` explicitly so the resolution rule is trivial.

The path each binary resolves here names the *seed/propose* Dhall input, not the in-force
config. The in-force config is the Vault-Transit-enveloped MinIO object (Section 1a); a host
that cannot reach an unsealed Vault sees only the unencrypted basics, and supplying a file is a
proposed update reconciled into the encrypted source of truth. Sprint `1.38` has landed the local
foundations and switched host settings consumers off the `loadConfigFile` live-config path once
unencrypted basics exist.

## 4. Decoding

Every binary decodes its Dhall in-process through the native Haskell `dhall` library:

```haskell
-- src/Prodbox/Settings.hs
loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = do
  let configPath = configDhallPath (canonicalConfigPaths repoRoot)
  configExists <- doesFileExist configPath
  if not configExists
    then pure (Left (missingConfigMessage configPath))
    else do
      result <- try (inputFile auto configPath)
      pure $ case result of
        Left (e :: SomeException) -> Left ("Failed to decode Dhall config …: " ++ displayException e)
        Right config -> Right config
```

The host loader takes the **repository root**, derives the canonical
`prodbox-config.dhall` path via `canonicalConfigPaths`, guards existence with
`doesFileExist`, and wraps the decode in `try` so a missing or malformed config surfaces as
a `Left String` rather than an exception. The in-cluster binaries pass their mounted
`--config` path straight to `Dhall.inputFile auto`.

There is no intermediate JSON projection on the supported path. `dhall-to-json` is not part
of the supported toolchain. The on-disk artifact is the typed, operator-authored Dhall
expression; the in-memory value is a Haskell record type produced by `Dhall.inputFile auto`.

Under GHC 9.14.1, `cabal.project` carries `allow-newer` clauses for the `dhall` library's
transitive dependencies so the pinned `dhall ^>=1.42` bound continues to build cleanly on
the newer GHC. The specific `allow-newer` set is owned by
[dependency_management.md](./dependency_management.md).

## 5. Dhall imports

The Dhall expression at the `--config` path is free to compose itself from sibling files
using Dhall's native import system. It imports only non-secret parts — types, cluster topology,
and `SecretRef` references — never a secret value:

```dhall
-- /etc/gateway/config.dhall (rendered into the gateway-config-<nodeId> ConfigMap)
let types  = ./types.dhall
let orders = ./orders.dhall                          -- separate ConfigMap mount
in  types.BootConfig::{ node_id   = "node-a"
                      , orders    = orders
                      -- credentials are SecretRef.Vault references, resolved at runtime
                      -- through Vault Kubernetes auth — never imported as a value here
                      , aws_creds = types.SecretRef.Vault { mount = "kv", path = "aws/route53", field = "creds" }
                      , minio     = types.SecretRef.Vault { mount = "kv", path = "minio/root", field = "creds" }
                      , …
                      }
```

The binary reads one file. That file imports the parts that have independent lifecycles —
Orders (cluster topology, monotonically versioned per Sprint 2.7) and the operator-authored
bootstrap fragment (rotated only when the operator edits the repo). The single-file rule is
preserved at the CLI surface; the on-disk layout follows the data lifecycles.

There are **no `as Text` credential imports and no Secret-mounted Dhall credential fragments.**
Sensitive fields carry `SecretRef.Vault` / `SecretRef.TransitKey` references; the value is
fetched at runtime by the in-cluster consumer authenticating to Vault directly via Vault
Kubernetes auth. The Dhall typechecker never sees a literal secret because there is no literal
secret in the config tree — only a reference to a Vault object. See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and Section 6.2.
The `SecretRef` type/resolver foundation has landed under Sprint 1.35, and the chart
Vault policy/role/service-account, Kubernetes-auth config, and generated/static seed-bootstrap
foundation is active under Sprint 3.18. The `websocket` workload config now carries
`oidc.client_secret` as `SecretRef.Vault` and resolves it through Vault Kubernetes auth at runtime;
the Keycloak and MinIO charts materialize their covered runtime fields through Vault-login init
containers, and MinIO admin bootstrap Jobs read root credentials through the same init-container
pattern. The VS Code Envoy `SecurityPolicy` client Secret is materialized from Vault by a chart
Job, and gateway event keys plus Route 53 AWS and gateway MinIO credentials now resolve through
Vault Kubernetes auth. Patroni role Secrets are materialized from Vault by the `keycloak-postgres`
pre-install hook. Host/admin helpers and the AWS SES SMTP setup flow now read/write their remaining
Keycloak admin, OIDC, demo-user, and SMTP material through Vault KV. Sprint 3.18 also pins the
sealed-startup structural proof; legacy derivation/removal remains open under Sprint 3.19.

## 6. Cluster mount contract

The gateway daemon's Dhall file is materialized by the Helm chart as follows:

| Mount source | Mount path | Content |
|---|---|---|
| `gateway-config-<nodeId>` ConfigMap | `/etc/gateway/config.dhall` | per-node Dhall expression; imports `orders.dhall`, carries `SecretRef.Vault` references for credentials, and carries non-secret service endpoints (notably `boot.minio_endpoint_url`) inline |
| `gateway-orders` ConfigMap | `/etc/gateway/orders.dhall` | cluster-wide ranked-node + timing Dhall expression |
| `gateway-<nodeId>-tls` Secret | `/tls/` | cert-manager-issued per-node TLS keypair; referenced by file path from the Dhall config |
| Cert-manager CA Secret | `/ca/` | trust anchor for peer mTLS; referenced by file path from the Dhall config |

The chart materializes **no credential as a Dhall fragment**. There are no
`gateway-secrets-aws` / `gateway-secrets-minio` Secret-mounted Dhall fragments — those mounts
are removed. Credentials are `SecretRef.Vault` references in the ConfigMap-rendered Dhall, and
the daemon resolves them at runtime by authenticating to Vault via Vault Kubernetes auth: a
Kubernetes service account, a Vault role bound to the daemon's namespace and service account,
and a Vault policy scoping which KV paths it may read. See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md). The Sprint 3.18
foundation now provisions Vault roles, service accounts, Kubernetes-auth config, and
generated/static seed KV objects for this model, and the websocket workload now resolves its OIDC
client secret through that SecretRef path; Keycloak and MinIO materialize their covered runtime
fields through Vault-login init containers, and MinIO admin bootstrap Jobs read root credentials
through the same init-container pattern. The VS Code Envoy `SecurityPolicy` client Secret is
materialized from Vault by a chart Job, and gateway event/AWS/MinIO credentials are resolved from
Vault by the daemon and gateway MinIO bootstrap Job. Sprint `2.26` also uses the same non-secret
gateway Vault Kubernetes-auth coordinates at runtime for the gateway federation read endpoints
(`/v1/federation/children` and `/v1/federation/children/<child>/bootstrap`); the endpoints read
parent-custodied child inventory from Vault KV, not from Dhall, Kubernetes Secrets, or
gateway-local files. Patroni role Secrets are materialized from Vault by a chart hook. The
sealed-startup structural proof has landed; legacy derivation/removal remains Sprint 3.19. The
operator-facing `gateway-config-<nodeId>` ConfigMap therefore contains no
secret material — only `SecretRef` references plus non-secret service endpoints rendered
inline. The cert-manager-issued TLS keypair and CA trust anchor remain ordinary k8s Secret
mounts referenced by file path; they are cert material under Vault's PKI authority, not Dhall
credential fragments.

### Non-secret service-endpoint fields

Service endpoints the daemon must reach (currently: the MinIO endpoint URL used to fetch the
Vault-Transit-enveloped in-force config and gateway state) live as fields on the
chart-rendered `boot` record rather than in Secrets. The endpoint is not credential material;
placing it in a Secret would unnecessarily restrict who can read it. Today the only such field
is:

| Field | Type | Source | Canonical value |
|---|---|---|---|
| `boot.minio_endpoint_url` | `Optional Text` | rendered inline by `gateway-config-<nodeId>` ConfigMap from chart value `minio.endpointUrl` | `http://minio.prodbox.svc.cluster.local:9000` on the home substrate |

The daemon decoder (`Prodbox.Gateway.Settings.DaemonBootDhall.minio_endpoint_url`) treats
the field as `Optional Text` so chart-only smoke installs without a live MinIO can still
decode the config; the MinIO-backed config fetch falls back to `127.0.0.1:9000` and fails
closed — serving the documented unavailable response — when the field is `None` and MinIO (or
the Vault unseal the decrypt depends on) is unreachable. The MinIO objects are
Vault-Transit-enveloped, so a sealed Vault leaves the daemon with opaque ciphertext regardless
of MinIO reachability; see Section 1a and
[vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store).

ConfigMap and Secret volume updates land in the Pod via the kubelet's atomic `..data`
symlink swap. The file-watch reload trigger (Section 7) follows that symlink swap rather
than the leaf-file `mtime`.

## 6.1 ACME issuer config fields

The `acme` config block carries the ACME-issuance inputs consumed by cert-manager
`ClusterIssuer` rendering. It is decoded into `AcmeSection` in
`src/Prodbox/Settings.hs`, declared in `prodbox-config-types.dhall`, and given its default
in `prodbox-config.dhall`:

| Field | Type | Purpose |
|---|---|---|
| `acme.email` | `Text` | expiry-notice email; required and non-empty |
| `acme.server` | `Text` | ZeroSSL ACME directory URL rendered into the `ClusterIssuer` |
| `acme.eab_key_id` | `Optional Text` | EAB key ID (required for ZeroSSL) |
| `acme.eab_hmac_key` | `Optional Text` | EAB HMAC key (required for ZeroSSL) |

`acme.server` is a non-empty ACME directory `Text` that defaults to the ZeroSSL directory
`https://acme.zerossl.com/v2/DV90` and feeds the single `ClusterIssuer` (`zerossl-dns01`).
ZeroSSL is the only supported ACME provider, so `acme.eab_key_id` / `acme.eab_hmac_key` are
required and `validateAcmeBinding` rejects a ZeroSSL `acme.server` with either EAB field
missing. The single-issuer model — one `ClusterIssuer` with a DNS-01 Route 53 solver plus the
S3-backed retain-and-restore of the issued certificate so rebuilds do not re-order it — is
owned by [acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md).

`acme.eab_key_id` / `acme.eab_hmac_key` move from plaintext config fields into Vault KV,
referenced by `SecretRef.Vault` rather than carried inline (scheduled under Sprint 7.15; see
[vault_doctrine.md §11](./vault_doctrine.md#11-tls-and-pki-under-vault)). The field names and
their required-for-ZeroSSL semantics are unchanged; only their at-rest carrier moves behind
Vault.

## 6.2 SecretRef: typed secret references

Sensitive config fields carry a typed `SecretRef` value, never a plaintext secret. The Dhall
union is `< Vault | TransitKey | Prompt | TestPlaintext >`; the corresponding Haskell ADT is
`Prodbox.Settings.SecretRef`. There is **no `FileSecret` arm** — the `SecretRefFile`
constructor and its resolver are removed, and there are no Secret-mounted Dhall credential
fragments. `Vault` / `TransitKey` are the production targets, `Prompt` is CLI-only one-off
elevated material, and `TestPlaintext` is accepted only by the test harness from
`test-config.dhall`. The ADT, Dhall decoder, production plaintext validator, and Vault KV reader
seam (`resolveSecretRefWithVault` / `resolveSecretRefFromVault`) are implemented under Sprint
1.35; migrating the sensitive repo config fields onto that contract is scheduled under Sprint
1.38.

- `prodbox config validate` rejects any plaintext secret value in production config and rejects
  `TestPlaintext` outside the test harness.
- Production config and test plaintext are split: `prodbox-config.dhall` holds references only,
  while `test-config.dhall` holds plaintext used solely by the test harness — including the
  `aws_admin_for_test_simulation.*` elevated-credential simulation — never imported by
  `prodbox-config.dhall` and never in Vault. See
  [vault_doctrine.md §4](./vault_doctrine.md#4-config-split-production-references-vs-test-plaintext).

This is the SSoT-deferring summary; [vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model)
owns the full SecretRef model and is the single source of truth for it.

## 7. File-watch reload trigger

Every long-running `prodbox` binary instance watches the file at its `--config` path for
changes via filesystem-watch primitives (the gateway daemon does so today; the workload Pods
are the scheduled target — see below). Concretely the supported watcher is `fsnotify` on
Linux (with `hinotify` as an acceptable equivalent inside the canonical Docker image); the
chosen library is named by the implementing sprint. The watch loop subscribes to events on
the parent directory so the `..data` symlink swap performed by the kubelet on ConfigMap or
Secret updates triggers a reload.

SIGHUP is no longer a supported reload trigger. The signal handler that previously fed the
reload queue is removed; the watcher feeds the same `TBQueue ()` reload-worker that the
existing implementation drains. The downstream STM broadcast channel that publishes
LiveConfig changes to subscribers is unchanged.

The gateway daemon already implements this fsnotify-driven Boot/Live reload loop. The
**workload Pods are a target, not yet a reality**: today `Prodbox.Workload` decodes its Dhall
once at startup and has no file watcher. Giving the workload the same daemon-style
fsnotify watcher and Boot/Live reload split is scheduled work (Sprint 3.15); until that lands,
"the workload Pods watch their config file" describes the intended structure rather than the
current code.

This explicitly overrides the prior prohibition on `fsnotify`, `inotify`, and `mtime` as
reload triggers. The `forbidFsnotify` / `forbidInotify` / `forbid-mtime-polling` lint rules
in `src/Prodbox/CheckCode.hs` are removed by the implementing sprint and the legacy ledger
records their removal.

## 8. Boot-vs-Live split and the restart contract

The BootConfig / LiveConfig record-level split survives. `BootConfig` carries fields that
the daemon binds once at startup and cannot meaningfully change without rebinding the
process (listener sockets, peer-transport handles, identity, cert/key paths, Orders).
`LiveConfig` carries fields the daemon can swap at runtime (log level, timing knobs, drain
deadline, max clock skew).

When the watch loop detects a change at `--config`:

1. The reload worker re-decodes the Dhall via `Dhall.inputFile auto`.
2. If decode fails, the daemon logs `config_reload_decode_failed` and keeps the previous
   in-memory config. Live traffic is unaffected.
3. If decode succeeds and only LiveConfig fields differ from the running config, the worker
   atomically swaps `envLiveConfig` via STM and publishes the change on the existing
   broadcast channel. Subscribers (log-level, timing) refresh in place. No drain, no restart.
4. If decode succeeds and any BootConfig field differs from the running config, the worker
   logs `config_reload_boot_change_detected`, calls the existing drain machinery
   (`liveDrainDeadlineSeconds` default 30s), and exits with `ExitSuccess`. The kubelet
   restarts the Pod, which decodes the new Dhall fresh at startup. This is the supported
   path for promotion of new ranked nodes, new listener ports, cert/key rotation, and any
   other boot-field change.

The "restart" semantics live in k8s, not in the daemon itself. The daemon never
self-respawns; it only ever drains and exits. Pod-level restart-on-exit is the kubelet's
job, not the binary's.

## 9. Host CLI

The host CLI applies the same contract with two simplifications: it has no `--config` flag
(it resolves the fixed repo-root `prodbox-config.dhall`, §1–§3), and the host binary is not
long-running, so file watching is unnecessary. `prodbox` resolves the repo root, then
`loadConfigForSettingsWith` either reads the canonical `prodbox-config.dhall` as first-bring-up
seed input when unencrypted basics are absent, or reads the basics and loads the in-force MinIO
envelope via Vault when basics exist. There is no env-var precedence ladder on the host — the
on-disk file is only a seed/propose Dhall surface, never the live SSoT after basics exist. Lifecycle
reconcile is the bootstrap exception: it validates the file for the RKE2/Vault/MinIO bring-up
steps that precede the in-force object-store read, then reloads through Vault/MinIO before
secret-dependent chart and edge reconciliation.

The on-disk file is the seed/propose input, not the in-force config. The host reads the
unencrypted basics locally and fetches + decrypts the in-force config from MinIO via Vault
(§1a); supplying a file is a proposed update, and a write to the root cluster's in-force config
requires the root Vault token. The local decoding/fetch/store foundations landed in Sprint
`1.38`; the global host-loader flip now lands there too. Without basics, `loadConfigFile`
remains only the first-bring-up seed path.

The host case is the existing baseline (Sprint 1.2). The remaining env-var-read call sites on
the supported path are not on the host CLI but in `Prodbox.Workload`, which still reads a
`PRODBOX_*` precedence ladder (`PRODBOX_WORKLOAD_MODE`, `PRODBOX_PORT`, `PRODBOX_LOG_LEVEL`,
`PRODBOX_REDIS_*`, `PRODBOX_OIDC_*`). Deleting that ladder and moving the workload to the
config-as-data Dhall surface is scheduled work (Sprint 3.15); see §10.

## 10. Forbidden surfaces

The following surfaces are the **target** forbidden set — the structure the supported path is
moving to. Where a surface is named "scheduled" below, the code has not finished the move yet,
so the prohibition is the intended end state rather than a present-tense fact:

- Reading configuration from environment variables in any binary code path. `lookupEnv`,
  `getEnv`, and `getEnvironment` from `System.Environment` are the target for being linted out
  of the supported config-loading paths. **Not yet complete on the workload**: `Prodbox.Workload`
  still reads a `PRODBOX_*` precedence ladder (mode, port, log level, Redis host/port, OIDC
  fields); deleting that ladder and adding `Workload.hs` to the env-var-read lint scope
  (`checkEnvVarConfigReads.scopedPaths`) is scheduled under Sprint 3.15. The k8s Pod
  environment may still carry runtime metadata (Pod name, namespace) that the binary does not
  read; the lint rule is scoped to the config-loading paths.
- Materializing `prodbox-config.json` (or any other JSON projection of the Dhall) on a
  supported path. `prodbox config compile` is not a supported subcommand.
- `--log-level`, `--port`, `--node-id`, `--foreground`, `--config-path`, and any other
  runtime-override CLI flag that fronts a non-`--config` config source. `--config` is the
  sole startup-time CLI knob.
- `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT`, `PRODBOX_WORKLOAD_MODE`, and
  any other `PRODBOX_*` env-var precedence rule. The host CLI carries none of these. The
  workload's surviving `PRODBOX_*` ladder is the one outstanding violation of this rule;
  retiring it is scheduled under Sprint 3.15 (see §9 and the first bullet above).
- `MINIO_ENDPOINT_URL` env var on the gateway Pod (the attempted addition rolled back
  May 24, 2026). The MinIO endpoint reaches the daemon via the `boot.minio_endpoint_url`
  field of the mounted Dhall config; see §6 "Non-secret service-endpoint fields".
- SIGHUP-driven reload. The signal handler is removed; SIGHUP becomes a process-level
  terminate signal again with the supported behavior `drain + exit`.
- ConfigMap-rendered credentials, and Secret-mounted Dhall credential fragments (any
  `as Text` credential import, any `gateway-secrets-*` Dhall Secret). Credentials are
  `SecretRef.Vault` references resolved at runtime through Vault Kubernetes auth, not mounted
  Dhall values (foundation active under Sprint 3.18; websocket OIDC SecretRef consumer landed;
  Keycloak and MinIO Vault-init consumers landed; the VS Code Envoy `SecurityPolicy` client Secret
  is Vault-materialized by a chart Job; gateway event/AWS/MinIO Vault consumption landed; Patroni
  role Secret materialization landed; host/admin helper and AWS SES SMTP Vault reads/writes landed;
  sealed-startup structural proof landed; legacy derivation/removal remains Sprint 3.19; see §5,
  §6, and [vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth)).
- Plaintext secret values in `prodbox-config.dhall` or in ConfigMap-rendered Dhall. Sensitive
  fields carry `SecretRef` references instead. The FileSecret-free `SecretRef` contract is Sprint
  `1.35`; AWS provider credential migration is Sprint `7.14`; ACME EAB migration is Sprint `7.15`
  (see §6.2 and [vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model)).
- Reading the on-disk `prodbox-config.dhall` as the in-force config SSoT. The filesystem Dhall
  is a seed/propose input only; the in-force config is the Vault-Transit-enveloped MinIO object
  (Sprint `1.38`; see §1a).

## 11. Cross-references

- [cli_command_surface.md](./cli_command_surface.md) — CLI flag inventory; defers
  startup-config sourcing rules to this doctrine.
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — daemon
  lifecycle; defers config-source and reload-trigger rules to this doctrine.
- [dependency_management.md](./dependency_management.md) — `dhall` library pin and
  `allow-newer` clauses under GHC 9.14.1.
- [haskell_code_guide.md](./haskell_code_guide.md) — forbidden subprocess and env-var-read
  primitives.
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — ConfigMap and
  Secret mount layout for the cluster Dhall surface.
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the secret inventory
  mapping each secret to its Vault KV / PKI / Transit path (the HMAC master-seed derivation
  model is retired; secrets are Vault objects).
- [vault_doctrine.md](./vault_doctrine.md) — the finalized Vault-root model: the `SecretRef`
  contract, the production references vs. `test-config.dhall` plaintext split, MinIO as a
  ciphertext store, and in-cluster Vault Kubernetes auth.
- [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) — the root/child trust
  tree, transit-seal auto-unseal, parent custody of child init keys, and the
  root-token-gated config-write authority that governs §1a.
- [unit_testing_policy.md](./unit_testing_policy.md) — file-watch reload test stanza.
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — sprint status and
  adoption schedule for this doctrine.
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the superseded JSON / env-var / SIGHUP surfaces.
