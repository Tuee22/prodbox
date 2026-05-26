# Config Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md),
[../../README.md](../../README.md),
[../../CLAUDE.md](../../CLAUDE.md),
[../../AGENTS.md](../../AGENTS.md),
[../documentation_standards.md](../documentation_standards.md),
[cli_command_surface.md](./cli_command_surface.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[dependency_management.md](./dependency_management.md),
[haskell_code_guide.md](./haskell_code_guide.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
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
configuration from exactly one Dhall file passed by `--config <path>`. Cryptographic material
and credentials are still mounted from k8s Secrets, but they are referenced **from the Dhall
file** via Dhall's native import system — never from environment variables, never from a
parallel JSON document, never from a CLI override that fronts an env-var fallback.

The reload model is symmetric: the running binary watches the file at its `--config` path,
classifies each on-disk change as a BootConfig change (drain + exit so kubelet restarts the
Pod) or a LiveConfig change (atomic STM swap, no restart), and acts accordingly. SIGHUP is no
longer the canonical reload trigger.

## 2. Single Dhall surface per binary instance

Each `prodbox` binary instance accepts exactly one CLI flag for configuration:

```
prodbox <subcommand> --config <path-to-dhall-file>
```

Examples on the host:

```bash
# Implicit: prodbox resolves the canonical repository-root path.
prodbox check-code

# Explicit: same shape, named path.
prodbox --config ./prodbox-config.dhall check-code
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
| Host CLI (`prodbox` on the operator host) | `./prodbox-config.dhall` (resolved against the repository root) | `src/Prodbox/Repo.hs::canonicalConfigPaths` + `src/Prodbox/Settings.hs::loadConfigFile` |
| In-cluster gateway daemon | `/etc/gateway/config.dhall` | chart-side ConfigMap mount; see [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) |
| In-cluster workload Pods (`api`, `websocket`) | `/etc/workload/config.dhall` | chart-side ConfigMap mount on the owning workload chart |

For the host CLI, omitting `--config` resolves the canonical repo-root path. Inside the
cluster the deployments always pass `--config <path>` explicitly so the resolution rule is
trivial.

## 4. Decoding

Every binary decodes its Dhall in-process through the native Haskell `dhall` library:

```haskell
-- src/Prodbox/Settings.hs
loadConfigFile :: FilePath -> IO ConfigFile
loadConfigFile path = Dhall.inputFile auto path
```

There is no intermediate JSON projection on the supported path. `dhall-to-json` is not part
of the supported toolchain. The on-disk artifact is the typed, operator-authored Dhall
expression; the in-memory value is a Haskell record type produced by `Dhall.inputFile auto`.

Under GHC 9.14.1, `cabal.project` carries `allow-newer` clauses for the `dhall` library's
transitive dependencies so the pinned `dhall ^>=1.42` bound continues to build cleanly on
the newer GHC. The specific `allow-newer` set is owned by
[dependency_management.md](./dependency_management.md).

## 5. Dhall imports

The Dhall expression at the `--config` path is free to compose itself from sibling files
using Dhall's native import system:

```dhall
-- /etc/gateway/config.dhall (rendered into the gateway-config-<nodeId> ConfigMap)
let types  = ./types.dhall
let orders = ./orders.dhall                          -- separate ConfigMap mount
let aws    = /etc/gateway/secrets/aws.dhall as Text  -- separate Secret mount, kept opaque
let minio  = /etc/gateway/secrets/minio.dhall as Text
in  types.BootConfig::{ node_id   = "node-a"
                      , orders    = orders
                      , aws_creds = aws
                      , minio     = minio
                      , …
                      }
```

The binary reads one file. That file imports the parts that have independent lifecycles —
Orders (cluster topology, monotonically versioned per Sprint 2.7), credentials (Secret-backed,
rotated independently of ConfigMaps), the operator-authored bootstrap fragment (rotated only
when the operator edits the repo). The single-file rule is preserved at the CLI surface; the
on-disk layout follows the data lifecycles.

Imports of `as Text` are encouraged for credential files so the Dhall typechecker never sees
the literal secret value; the consumer of the field treats it as an opaque token.

## 6. Cluster mount contract

The gateway daemon's Dhall file is materialized by the Helm chart as follows:

| Mount source | Mount path | Content |
|---|---|---|
| `gateway-config-<nodeId>` ConfigMap | `/etc/gateway/config.dhall` | per-node Dhall expression; imports the files below, and also carries non-secret service endpoints (notably `boot.minio_endpoint_url`) inline |
| `gateway-orders` ConfigMap | `/etc/gateway/orders.dhall` | cluster-wide ranked-node + timing Dhall expression |
| `gateway-secrets-aws` Secret | `/etc/gateway/secrets/aws.dhall` | Dhall expression carrying the AWS Route 53 credentials |
| `gateway-secrets-minio` Secret | `/etc/gateway/secrets/minio.dhall` | Dhall expression carrying the MinIO IAM credentials |
| `gateway-<nodeId>-tls` Secret | `/tls/` | cert-manager-issued per-node TLS keypair; referenced by file path from the Dhall config |
| Cert-manager CA Secret | `/ca/` | trust anchor for peer mTLS; referenced by file path from the Dhall config |

The chart materializes every credentialed value as a Dhall fragment in a k8s Secret (not a
ConfigMap). The operator-facing `gateway-config-<nodeId>` ConfigMap contains no secret
material — only references to the Secret-mounted Dhall imports plus non-secret service
endpoints rendered inline.

### Non-secret service-endpoint fields

Service endpoints the daemon must reach (currently: the MinIO endpoint URL used by
`acquireInitialMasterSeed`) live as fields on the chart-rendered `boot` record rather
than in Secrets. The endpoint is not credential material; placing it in a Secret would
unnecessarily restrict who can read it. Today the only such field is:

| Field | Type | Source | Canonical value |
|---|---|---|---|
| `boot.minio_endpoint_url` | `Optional Text` | rendered inline by `gateway-config-<nodeId>` ConfigMap from chart value `minio.endpointUrl` | `http://minio.prodbox.svc.cluster.local:9000` on the home substrate |

The daemon decoder (`Prodbox.Gateway.Settings.DaemonBootDhall.minio_endpoint_url`) treats
the field as `Optional Text` so chart-only smoke installs without a live MinIO can still
decode the config; the master-seed acquisition path falls back to `127.0.0.1:9000` and
serves the documented 503 master-seed-unavailable response when the field is `None` and
MinIO is unreachable.

ConfigMap and Secret volume updates land in the Pod via the kubelet's atomic `..data`
symlink swap. The file-watch reload trigger (Section 7) follows that symlink swap rather
than the leaf-file `mtime`.

## 7. File-watch reload trigger

Every long-running `prodbox` binary instance (the gateway daemon, the workload Pods) watches
the file at its `--config` path for changes via filesystem-watch primitives. Concretely the
supported watcher is `fsnotify` on Linux (with `hinotify` as an acceptable equivalent inside
the canonical Docker image); the chosen library is named by the implementing sprint. The
watch loop subscribes to events on the parent directory so the `..data` symlink swap
performed by the kubelet on ConfigMap or Secret updates triggers a reload.

SIGHUP is no longer a supported reload trigger. The signal handler that previously fed the
reload queue is removed; the watcher feeds the same `TBQueue ()` reload-worker that the
existing implementation drains. The downstream STM broadcast channel that publishes
LiveConfig changes to subscribers is unchanged.

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

The host CLI applies the same contract with one simplification: the host binary is not
long-running, so file watching is unnecessary. `prodbox` reads `./prodbox-config.dhall`
once at the start of each invocation via `Dhall.inputFile auto`, executes the requested
subcommand, and exits. There is no env-var precedence ladder on the host either — the file
is the sole source.

The host case is the existing baseline (Sprint 1.2); no migration is required for the host
surface beyond removing residual env-var-read call sites in `Prodbox.Gateway` and friends
that read `PRODBOX_*` for daemon-launch knobs.

## 10. Forbidden surfaces

The following surfaces are explicitly forbidden on the supported path:

- Reading configuration from environment variables in any binary code path. `lookupEnv`,
  `getEnv`, and `getEnvironment` from `System.Environment` are linted out of the supported
  source tree. The k8s Pod environment may still carry runtime metadata (Pod name, namespace)
  that the binary does not read; the lint rule is scoped to the config-loading paths.
- Materializing `prodbox-config.json` (or any other JSON projection of the Dhall) on a
  supported path. `prodbox config compile` is not a supported subcommand.
- `--log-level`, `--port`, `--node-id`, `--foreground`, `--config-path`, and any other
  runtime-override CLI flag that fronts a non-`--config` config source. `--config` is the
  sole startup-time CLI knob.
- `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT`, `PRODBOX_WORKLOAD_MODE`, and
  any other `PRODBOX_*` env-var precedence rule.
- `MINIO_ENDPOINT_URL` env var on the gateway Pod (the attempted addition rolled back
  May 24, 2026). The MinIO endpoint reaches the daemon via the `boot.minio_endpoint_url`
  field of the mounted Dhall config; see §6 "Non-secret service-endpoint fields".
- SIGHUP-driven reload. The signal handler is removed; SIGHUP becomes a process-level
  terminate signal again with the supported behavior `drain + exit`.
- ConfigMap-rendered credentials. Credentials live in k8s Secrets, mounted as Dhall files
  and imported by the main Dhall.

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
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — MinIO endpoint and
  credentials sourcing for the master-seed read path.
- [unit_testing_policy.md](./unit_testing_policy.md) — file-watch reload test stanza.
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — sprint status and
  adoption schedule for this doctrine.
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the superseded JSON / env-var / SIGHUP surfaces.
