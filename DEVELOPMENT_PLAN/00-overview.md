# File: DEVELOPMENT_PLAN/00-overview.md
# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md), [phase-0-planning-documentation.md](phase-0-planning-documentation.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-5-public-host-validation.md](phase-5-public-host-validation.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)

> **Purpose**: Provide the architectural overview, clean-room sequence, repository state, and hard
> constraints for the prodbox development plan.

## Vision

Build a clean-room prodbox repository with:

1. One explicit `prodbox` CLI surface.
2. One repository-root `prodbox-config.dhall` compiled to `prodbox-config.json` for all
   configuration; cluster-internal secrets are auto-generated at chart deploy time; no `.env`
   file.
3. One distributed gateway runtime that lives entirely inside the RKE2 cluster as a Kubernetes
   workload, with leader election, partition tolerance, and Route 53 write ownership.
4. One chart-platform storage model rooted at `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
5. One supported cluster-backed `vscode` delivery path.
6. One named validation command per major surface.
7. One explicit ledger for every compatibility or cleanup item still slated for removal.
8. One cluster-wide StorageClass named `manual` of type `kubernetes.io/no-provisioner`; no dynamic
   provisioner is permitted.
9. All cluster services deployed via Helm; Pulumi orchestrates infrastructure Helm releases, the
   `prodbox charts` platform manages application Helm releases.
10. Chart replica counts are explicit: single-writer retained-state services stay single-replica,
    while clustered services may run multiple replicas with pod anti-affinity suppressed in dev
    mode.
11. PVs pre-created explicitly before Helm install; PVCs created only by Helm charts deploying
    StatefulSets.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology | The plan becomes the single roadmap and status source |
| 1 | Runtime, CLI, and AWS Validation Foundations | Core CLI, test surfaces, AWS auth doctrine, and real-system validation are established |
| 2 | Distributed Gateway Runtime and DNS Ownership | The distributed gateway, TLA+ entrypoint, and Route 53 write capability exist |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | Deterministic retained storage and the namespace-local stack are canonical |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | Cleanup is stable without settling shims and duplicate paths are removed |
| 5 | Public Hostname Closure and Authoritative External Proof | Public DNS, TLS, ingress, and Keycloak redirect proof are canonicalized |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | The full clean-room rerun passes and the legacy backlog is empty |

## Architecture Summary

| Surface | Canonical Path | Authority |
|---------|----------------|-----------|
| CLI control plane | `poetry run prodbox <command>` | Repository worktree |
| AWS auth/config | Repository-root `prodbox-config.dhall` compiled to `prodbox-config.json`, read by `Settings()` | Repository root |
| RKE2 lifecycle | `prodbox rke2 ensure`, `status`, `cleanup --yes` | `prodbox` CLI |
| Pulumi infrastructure | `prodbox pulumi ...` | `src/prodbox/infra/` plus Route 53 |
| Gateway startup | `prodbox gateway start` (in-pod entrypoint) | `src/prodbox/gateway_daemon.py` deployed via `prodbox charts` |
| Gateway steady state | In-cluster gateway pod under leader election | Kubernetes Deployment/StatefulSet managed by `prodbox charts` |
| Gateway DNS writes | Gateway `dns_write_gate` | In-cluster gateway pod (elected leader) |
| Public edge ingress | `MetalLB -> Traefik -> chart Ingress` | Pulumi plus cluster runtime |
| Namespace-local auth proxy | `vscode-nginx` inside the `vscode` chart | Chart platform |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Chart platform registry |
| Supported app delivery | Namespace-local `keycloak-postgres -> keycloak -> vscode` stack | Chart platform |
| Validation | Named `prodbox test ...`, `prodbox tla-check`, `prodbox check-code` | Repository-owned commands |
| Stable doctrine | `documents/engineering/` | Governed docs |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

Completed and present in the repository:

- Repository-wide status, blocker, and cleanup tracking now live in this plan suite.
- Runtime and CLI foundations exist: explicit Click command groups, command ADTs, eDAG builders,
  interpreter execution, named test suites, and documentation-topology guard coverage.
- Real-system validation exists for AWS foundation, EKS, Route 53, Pulumi, gateway process mode,
  gateway pod mode, chart storage/platform, lifecycle behavior, and public DNS delegation.
- Distributed gateway implementation exists with `prodbox gateway` management commands, TLA+
  artifacts, unit coverage, and Kubernetes integration suites.
- `prodbox charts` exists as a first-class capability with deterministic retained storage rooted
  at `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack exists, and the supported
  cluster auth model is nginx OIDC plus local Keycloak users.
- `prodbox rke2 cleanup --yes` uses namespace-first cleanup and preserves retained storage kinds
  for deterministic rebind.
- Gateway startup is canonical through `prodbox gateway start`; the legacy Poetry `daemon`
  entrypoint, compatibility container wrapper, and direct daemon wrapper path are gone.
- Route 53 ownership and update is canonical through gateway `dns_write_gate`; the old CLI/DDNS
  timer path and repo-tracked systemd units are gone.
- The interpreter and summary layer expose one canonical structured DAG outcome model without the
  old command-summary compatibility bridge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override, and `Settings()`
  loads from `prodbox-config.json` (compiled from `prodbox-config.dhall`) via
  `Settings.from_config_json()` only.
- The canonical certificate path is public ACME via cert-manager through `letsencrypt-http01`,
  with the ACME server configured in `prodbox-config.dhall`; the live cluster currently uses
  ZeroSSL DV90 (`https://acme.zerossl.com/v2/DV90`) with external account binding.
- Settings can now derive `METALLB_POOL` and `INGRESS_LB_IP` from the active LAN interface when
  those values are left blank, while still surfacing the detected interface, IPv4, and subnet in
  the effective settings model.
- The canonical infrastructure path now deploys cert-manager directly, wires the cluster issuer
  after cert-manager plus Traefik, and can skip Route 53 bootstrap with
  `PULUMI_ENABLE_DNS_BOOTSTRAP=false` when only local edge recovery is needed.
- `prodbox host public-edge` now exists as the named diagnostic command for public-edge ownership,
  Route 53 record state, Traefik service IP, ingress-class drift, and certificate readiness.
- `prodbox gateway config-gen` and `gateway status` expose `dns_write_gate` and DDNS health.
  The legacy `prodbox gateway install-service` Click command, `GatewayInstallServiceCommand`
  ADT, smart constructor, and DAG builder have been removed from the CLI surface, and the
  host-side `prodbox-gateway.service` unit has been removed from `bathurst` by Sprint 4.12.
- `charts/gateway/` is the canonical Helm chart for the in-cluster gateway. It renders one
  Deployment per ranked node id (canonical ranking: `node-a`, `node-b`, `node-c`), each
  backed by a per-node Service, an orders ConfigMap, a per-node config ConfigMap, a
  cert-manager-issued per-node TLS Certificate (with CN equal to the node id, matching the
  daemon's `_validate_peer_cert_cn`), a shared CA Issuer, and a Secret carrying
  `prodbox-config.json` so the daemon's Route 53 client reads AWS credentials through the
  canonical `Settings.from_config_json()` path. `chart_platform.CHART_REGISTRY` registers
  the chart with `requires_public_host=True`; `resolve_gateway_event_keys()` auto-generates
  per-node HMAC signing keys and persists them in `.data/gateway/.gateway-event-keys.json`
  so redeployments preserve mesh identity.
- The `charts-platform` integration fixture now clears retained `.data/vscode` state before live
  setup so reruns do not inherit stale Keycloak/Postgres credentials from previous deployments.
- Gateway daemon shutdown now tracks and awaits per-connection reader tasks so the in-cluster
  pod and the dev-only host process mode both teardown without leaking sockets/transports.
- The intended public-edge stack in repository code is `MetalLB -> Traefik -> vscode` Ingress,
  with `vscode-nginx` acting only as the namespace-local auth proxy behind that edge.
- The external public-host `charts-vscode` suite now runs without cluster prerequisite gates or an
  `rke2 ensure` preflight.
- Aggregate suites (`prodbox test integration all`, `prodbox test all`) now preserve the live
  public-host proof surface through the external suites, require `prodbox host public-edge` to
  report `CLASSIFICATION=ready-for-external-proof` before Phase 2 pytest starts, run
  `test_charts_platform.py` before `test_charts_storage.py`, keep the lifecycle suite last, and
  finish by restoring the supported runtime through `prodbox pulumi refresh`,
  `prodbox pulumi up --yes`, `prodbox charts deploy gateway`, `prodbox charts deploy vscode`,
  plus a final public-edge
  readiness recheck before exit.
- Pulumi-managed Helm releases for MetalLB, Traefik, and cert-manager now use stable Helm release
  names (`metallb`, `traefik`, `cert-manager`) so cluster-scoped objects can be reattached
  cleanly after clean-room teardown/recreate cycles.
- `prodbox-config-types.dhall` exists as the version-controlled Dhall schema;
  `prodbox config init|compile|show|validate` commands exist; `Settings` loads from
  `prodbox-config.json` via `from_config_json()`.
- `pydantic-settings` dependency removed; `Settings` uses `BaseModel` from plain `pydantic`.
- `aws_auth.py` module deleted; all AWS credential access flows through `Settings`.
- `prodbox env` command group removed; replaced by `prodbox config`.
- All subprocess environment builders use explicit passthrough allowlists; no `os.environ`
  inheritance remains. The interpreter uses `_base_subprocess_env()`, `check_code.py` uses
  `_TOOL_PASSTHROUGH_VARS`, and `test_cmd.py` uses `_TEST_PASSTHROUGH_VARS`.
- AWS fixture leak prevention is closed: each AWS-mutating fixture now begins with
  scope-owned preflight cleanup via shared helpers; taggable Route 53, S3, VPC, subnet,
  security-group, EKS, and IAM resources carry canonical ownership/expiry/safe-delete tags;
  setup helpers roll back partial creation before fixture yield; and the session-scoped sweep,
  `prodbox aws sweep-fixtures`, and hourly cron supervision remain defense-in-depth.

Additional canonical state established by Phase 4 cleanup work:

- The cluster runs exactly one StorageClass named `manual` with provisioner
  `kubernetes.io/no-provisioner`; the previous names (`prodbox-local-retain` and
  `prodbox-chart-null-storage`) have been consolidated.
- The retained storage path scheme is the 5-segment
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
- Replica counts now follow workload semantics: single-writer retained-state services stay
  single-replica, while clustered services can run multiple replicas. Dev mode
  (`PRODBOX_DEV_MODE=true`) suppresses anti-affinity while retaining the configured counts.

Open, incomplete, or blocked:

- None.

## Current-Environment Validation Snapshot

- `poetry run prodbox aws sweep-fixtures` passed on April 12, 2026 and reported no
  expired fixture resources.
- `poetry run prodbox check-code` passed on April 12, 2026.
- `poetry run prodbox test unit` passed on April 12, 2026 (972 tests).
- `poetry run prodbox test integration aws-foundation` passed on April 12, 2026 (3 tests).
- `poetry run prodbox test integration aws-eks` passed on April 12, 2026 (1 test).
- `poetry run prodbox test integration dns-aws` passed on April 12, 2026 (2 tests).
- `poetry run prodbox test integration pulumi` passed on April 12, 2026 (1 test).
- `poetry run prodbox test integration public-dns` passed on April 12, 2026 (2 tests).
- `poetry run prodbox test integration charts-vscode` passed on April 12, 2026 (8 tests).
- `poetry run prodbox tla-check` passed on April 12, 2026.
- `poetry run prodbox test integration all` passed on April 12, 2026.
- `poetry run prodbox test all` completed cleanly on April 12, 2026 after postflight runtime
  restore returned `prodbox host public-edge` to
  `CLASSIFICATION=ready-for-external-proof`.
- Live AWS inventory audit on April 12, 2026 found no current fixture-owned Route 53, S3, VPC,
  EKS, or IAM resources in account `751103452346`.
- Live cluster on `bathurst` has RKE2, MetalLB, Traefik, cert-manager, the
  `letsencrypt-http01` ClusterIssuer, the in-cluster gateway, and the `vscode` stack restored on
  the supported path.
- `prodbox-config.dhall` and `prodbox-config.json` carry the canonical AWS, Route 53,
  domain, ACME, and deployment settings.
- `kubectl get clusterissuer letsencrypt-http01 -o yaml` shows
  `spec.acme.server=https://acme.zerossl.com/v2/DV90`, `externalAccountBinding` configured, and
  `status.conditions[type=Ready].status=True`.
- `kubectl wait --for=condition=Ready certificate/vscode-tls -n vscode --timeout=300s` succeeded
  on April 12, 2026.
- Direct TLS verification for `vscode.resolvefintech.com:443` returns
  `SUBJECT_CN=vscode.resolvefintech.com`, `ISSUER_O=ZeroSSL GmbH`, and
  `ISSUER_CN=ZeroSSL RSA DV SSL CA 2`.
- `prodbox host public-edge` reports `CLASSIFICATION=ready-for-external-proof` with
  `ROUTE53_STATUS=in-sync`, `INGRESSCLASS_TRAEFIK=present`, and the expected Traefik load-balancer
  IP.
- The in-cluster gateway remains the sole Route 53 writer for `vscode.resolvefintech.com`.
- The legacy ledger Pending Removal section is empty.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The repository-root `prodbox-config.dhall` is the single configuration source. It is compiled
  to `prodbox-config.json` by `prodbox config compile` and read by `Settings()`. Both files are
  gitignored. Cluster-internal secrets are auto-generated at chart deploy time and persisted in
  `.data/`; they do not appear in the config file. IP addressing (MetalLB pool, ingress LB IP)
  is always auto-discovered from the host LAN. `KUBECONFIG` always uses the default
  `~/.kube/config`. Subprocess environments are constructed explicitly from configuration; no
  credentials are inherited from `os.environ`.
- No prodbox daemon runs on the host. The only supported steady-state location for the gateway
  daemon is inside the RKE2 cluster as a Kubernetes workload managed by `prodbox charts`.
- The only supported gateway startup path is `prodbox gateway start`, invoked as the entrypoint
  of the in-cluster gateway pod.
- The in-cluster gateway must remain available across pod restarts, node failures, and network
  partitions; leader election determines exactly one Route 53 writer at any time, and a
  partition heal converges to a single leader without split-brain Route 53 writes.
- Manual `prodbox gateway start` outside Kubernetes is permitted only for development and
  testing; it is not a supported public-host steady state.
- The only supported Route 53 ownership/update path is gateway `dns_write_gate`.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported cluster-edge ingress controller is Traefik; namespace-local `vscode-nginx` is
  an application auth proxy behind it, not a competing edge controller.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- The only supported validation paths are named `prodbox` commands; raw passthrough or alternate
  operator workflows are debt to remove, not supported surfaces.
- Every AWS-mutating integration test must begin by searching for and deleting stale fixture-owned
  resources for its declared scope before creating fresh AWS resources. All taggable fixture-owned
  AWS resources must carry canonical ownership, expiry, and safe-to-delete tags, and setup
  failure must roll back partial AWS creation before the fixture yields.
- Documents under `documents/` are stable doctrine and reference only. They do not own sprint
  histories, blocker tracking, or completion state.
- Compatibility shims, duplicate operator paths, competing ingress controllers, and transitional
  naming are removal targets, not long-term architecture.
- The only permitted cluster StorageClass is named `manual` with provisioner
  `kubernetes.io/no-provisioner`; bootstrap must fail if a chart requests a dynamic provisioner.
- PVCs may only be created by Helm charts deploying StatefulSets; no other mechanism may create
  PVCs.
- PVs must be pre-created explicitly before Helm install; implicit PVC provisioning is not
  permitted.
- All cluster services are deployed via Helm. Pulumi orchestrates infrastructure-layer Helm
  releases (MetalLB, Traefik, cert-manager). The `prodbox charts` platform manages
  application-layer Helm releases.
- Replica counts must follow chart storage semantics: single-writer retained-state services stay
  single-replica, while clustered services may use multiple replicas with pod anti-affinity.
  Dev mode suppresses anti-affinity but retains the configured replica counts.
- The retained storage path scheme is
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`. Path naming must be stable across
  teardown/rebuild cycles so data survives cluster down and cluster up.
- No tooling or CLI command is permitted to delete `.data/` itself.
- `.data/` must appear in both `.gitignore` and `.dockerignore`.

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-0-planning-documentation.md](phase-0-planning-documentation.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
