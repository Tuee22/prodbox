# Phase 3: Haskell Chart Platform and Public Workload Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md)
**Generated sections**: none

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, the
> supported public workload delivery path, and the CLI-doctrine adoption sprints that align chart
> orchestration with [the engineering doctrine docs](../documents/engineering/README.md).

## Phase Status

✅ **Live-proven 2026-06-26 — the full chart stack passes end-to-end under the green home `test all`.**
The `charts-vscode`, `charts-api`, `charts-websocket`, `charts-platform`, and `charts-storage` named
validations all pass `ExitSuccess` in the green home `prodbox test all` (2026-06-26, 18/18; see
[00-overview.md](00-overview.md) Alignment Status), so Phase 3's chart-orchestration / retained-storage
/ Keycloak-OIDC / Redis / Patroni-PostgreSQL surfaces are home-substrate live-proven. This run also
fixed two chart defects en route — the `api` chart `config.dhall` `oidc.client_secret` type and the
`websocket-isolation` NetworkPolicy Vault egress (see [README.md](README.md) Closure Status). The
`--substrate aws` chart coverage stays orthogonal ([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-16** — the Vault secrets model is finalized to the Vault-root architecture
(narrated in the [README.md](README.md) Closure Status and harmonized across the plan suite per
[development_plan_standards.md](development_plan_standards.md) rule J). Vault is the sole
secrets/KMS/PKI root for the chart platform; the master-seed HMAC-SHA-256 derivation model is
**retired, not extended**; the `SecretRef.FileSecret` / Secret-mounted plaintext Dhall fragment is
**removed, not bridged**; a sealed Vault bricks chart and Keycloak secret resolution (hard
fail-closed). Sprint `3.17` is **Done** on the code-owned Vault platform and envelope foundation:
the shared Vault chart is installed by both substrate platform reconcilers, the durable Vault PV
shape is in the retained-storage manifest, and the `prodbox-envelope-v1` / Vault-Transit `DekCipher`
foundation exists. Sprint `3.18` is **Done** on the chart-secret Vault-auth surface: the typed
Vault chart-secret inventory, generated least-privilege policies/roles in
`defaultVaultReconcilePlan`, explicit service accounts for the straightforward chart workloads,
read-before-write Vault KV seed-object bootstrap in `vault reconcile`, Kubernetes-auth backend config
and Vault TokenReview binding, direct websocket OIDC `SecretRef.Vault` app-side consumption,
Keycloak/MinIO runtime secret materialization through Vault-login init containers, MinIO admin
bootstrap Vault-login init containers, VS Code Envoy `SecurityPolicy` client-Secret
materialization, gateway event/AWS/MinIO Vault consumers, Patroni role Secret materialization, and
host/admin helper plus AWS SES SMTP Vault reads/writes all landed on 2026-06-15. Unit proof now pins
the secret-dependent chart startup sections to `set -eu` + direct Vault login/KV reads with no
ignored Vault failure or generated-secret fallback; the live whole-system sealed-Vault validation is
owned by Sprint `5.8`. Sprint `3.19` is **Done**: the master-seed derivation modules, gateway
`/v1/secret/*` RPCs, daemon-only-seed lint, and self-bootstrap path are removed, so Vault KV is the
sole chart-secret store. Sprint `3.20` stands up the **Vault transit-seal hierarchy** with
per-cluster seal custody and is **Done**: `Prodbox.Vault.Seal` defines root Shamir versus child
Transit modes, child init uses recovery-key shares, the Vault chart renders `seal "transit"` only
for child mode, and child init material maps to parent-owned Vault KV. Phase 3 sprints
(`3.1`–`3.20`) are `Done` on their owned surfaces; live child auto-unseal during lifecycle is now
closed by Sprint `4.32`, and the gateway-mediated federation custody surface is closed by Sprint
`2.26`. Remaining sealed-Vault whole-system validation is owned by Sprint `5.8`, not Phase `3`.
See
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
and [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md).

✅ **Reclosed 2026-06-09** — reopened for Sprints `3.15`–`3.16` (design-intention review,
2026-06-09; narrated in the [README.md](README.md) Closure Status per
[development_plan_standards.md](development_plan_standards.md) rule A); both landed. Sprint `3.15` ✅
made the public-workload binary config-as-data: deleted the `src/Prodbox/Workload.hs` `PRODBOX_*`
env-var ladder (`--config` is now mandatory and `Workload.hs` has zero `lookupEnv`), gave the
workload the daemon's Boot/Live split + `fsnotify` reload symmetry, and added `Workload.hs` to
`checkEnvVarConfigReads.scopedPaths` so the workload path cannot regress to env-var config. Sprint
`3.16` ✅ closed the master-seed boundary: the raw seed is read in-cluster only (lint-enforced by
`checkRawMasterSeedReadScope`), the host derives chart secrets via `Prodbox.Gateway.Client`, the
`/tmp` seed-file + `resolveSeedViaMinio` host paths are deleted, `MinioMasterSeedConfig` got a
redacting `Show`, and `resetPatroniStorageIfRequested` was landed as the doctrine-prescribed
loud-failure mismatch check. Validation at reclosure: `check-code` 0, `test unit` 775,
`integration cli` 35, `prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check` 0; the live
first-install secret-materialization and Patroni-probe exercises are operator-driven. All earlier
Phase 3 sprints (`3.1`–`3.14`) remain `Done`; no later phase was reopened by this change.

✅ **Done** — Sprints `3.1`–`3.7` remain `Done` on the chart runtime, retained storage, browser
delivery, JWT-API, WebSocket, admin surfaces, and the Patroni doctrine. The phase is reopened by
Sprint 0.2 to schedule Sprints `3.8`–`3.12`, which adopt the doctrine's smart-constructor pattern
for paired chart resources, route Redis and Postgres call sites through capability classes, apply
the reconciler discipline to `prodbox charts deploy|delete`, surface `--dry-run` plans on chart
operations, and add the `prodbox lint chart` Helm-chart structural-invariants linter together
with marker-delimited route-inventory generation from `src/Prodbox/PublicEdge.hs` into chart
artifacts via the existing `generatedSectionRule` registry. Current worktree evidence puts
Sprints `3.8`–`3.12` in `Done` state: `storageBinding`, the
shared Patroni helper inventory in `src/Prodbox/PostgresPlatform.hs`, and the chart-platform
call-site migration now centralize the retained paired-resource, related-name, and
Redis/Postgres capability surfaces; the
chart reconciler surface now treats already-deployed healthy releases as a success no-op and
rejects the doctrine-forbidden flags and sister commands, chart dry-run plans are rendered and
golden-covered, the structural-lint implementation is live on `prodbox lint chart`, and the
marker-delimited route inventory generated from `src/Prodbox/PublicEdge.hs` is now emitted into
the consuming chart templates. Sprint `3.13` closed on 2026-06-01 via the live
home-substrate preserved-data and lifecycle exercise; Sprint `3.14` closed on the same
run when `charts-api` and `charts-websocket` proved the Dhall workload config path.

## Phase Summary

This phase owns the Haskell chart platform and retained-storage orchestration while preserving
deterministic PV/PVC rebinding and the supported public workload delivery model. It owns retained
storage, Harbor-backed image sourcing for the supported chart stack, the Envoy Gateway browser-auth
path for `vscode`, the JWT-only API and Redis-backed WebSocket workload surfaces, and the
PostgreSQL doctrine for every Helm-managed application stack. Sprints `3.2` through `3.7` remain
closed on the current chart platform, shared-host API, WebSocket, supported admin delivery, and
the authoritative Patroni doctrine. Sprint `3.1` now also closes on the root-chart-only public
command surface. The supported
`vscode` stack stays on Harbor-backed images after Harbor bootstrap, uses
Gateway API plus Envoy Gateway `SecurityPolicy` for the public route, and keeps the
Percona-operator-backed Patroni HA path for every Helm-managed application stack: exactly three
replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.

**Independent Validation** (per
[development_plan_standards.md](development_plan_standards.md) Standard N): Phase 3 is
validatable on its owned chart-platform surface — the Haskell chart runtime, retained-storage
binding, Patroni/Vault rendering, and Gateway-API/Envoy route generation — without depending on
any later phase. Code-owned closure is proven locally (`prodbox dev check`, `prodbox test unit`,
`prodbox test integration cli`/`env`, `prodbox dev lint chart`, and `helm template` rendering),
and the home-substrate live exercise validates the chart stack end-to-end where a dependency owned
by another phase is touched. Proofs that require live infrastructure (a deployed cluster, an
unsealed Vault, operator-supplied unlock material, or live AWS substrate) are recorded as
non-blocking Live-proof items, per Standard O, and never gate this phase's code-owned closure; the
live whole-system sealed-Vault validation is owned by Sprint `5.8`, and AWS-substrate coverage of
the same chart validations is tracked in
[substrates.md](substrates.md)'s parity table. No incomplete later phase reopens Phase 3 — reopening
is only to expand its own owned chart-platform surface.

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, and
  `src/Prodbox/PostgresPlatform.hs`.
- The retained-root contract remains the configured manual PV root (default `.data/`) plus
  chart-secret resolution via the in-cluster gateway service (k8s Secrets only after Sprint `3.13`; the legacy `.prodbox-state/` cache is on the [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) cleanup ledger); chart secret resolution and gateway
  event-key handling are Haskell-owned.
- The supported chart catalog now includes `keycloak`, `vscode`, `api`, `websocket`, and
  `gateway`, with `keycloak-postgres` plus `redis` as internal dependency releases. The public
  parser and chart CLI now reject those internal names on the operator-facing
  `prodbox charts ...` surface with explicit guidance toward the owning root charts.
- The current supported app dependency graph now includes `keycloak-postgres -> keycloak -> vscode`
  for the browser stack and `redis -> websocket` for the shared-state realtime stack.
- The current lifecycle and chart code install the Percona `pg-operator` Helm release, mirror the
  Percona operator and PostgreSQL images, and render `PerconaPGCluster` resources for
  `keycloak-postgres`.
- The namespace-local release shape, deterministic manual-PV bindings, retained-secret contract,
  dependent-chart sequencing, and authoritative three-replica synchronous-replication doctrine
  all close on the Percona operator surface.
- `keycloak` now consumes the namespace-local retained Patroni credentials secret and the namespace-local
  primary service endpoint instead of a shared `pgpool` service.
- `src/Prodbox/TestPlan.hs` maps the chart validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host path-prefix catalog, canonical
  route URLs, and Keycloak issuer derivation consumed by the lifecycle, DNS, chart,
  host-diagnostic, and native validation surfaces.
- The chart templates that consume the shared public-edge path catalog now do so through the
  marker-delimited `route-registry` sections generated from `src/Prodbox/PublicEdge.hs` by
  `prodbox docs generate`, and `prodbox lint chart` validates chart metadata plus generated
  route-inventory drift on the supported surface.
- The current worktree renders the `vscode`, `api`, and `websocket` public paths through Gateway
  API `HTTPRoute` resources and Envoy Gateway `SecurityPolicy`, while `keycloak` publishes the
  shared public-edge `Gateway`, certificate, and identity route.
- The supported auth model now distinguishes request-borne bearer JWTs on the API route, the
  Envoy-managed browser redirect and cookie or session path on `vscode`, and workload-owned
  carrier or session state for the direct-OIDC `websocket` path.
- Envoy validates the current API route from Keycloak issuer metadata plus JWKS-backed signing keys
  on the edge hot path; Keycloak availability remains a dependency for login, refresh, and later
  JWKS refresh rather than for per-request API authorization.
- The shipped browser route exercises the Envoy-managed OIDC path, while the chart-managed
  direct-OIDC `websocket` workload keeps its workload-owned session bootstrap behind the shared
  host on the `/ws` route.
- The shared-host Keycloak identity route is rendered on `/auth`, and the named validation
  surfaces prove the issuer, forwarded-header, and public-path constraints for the supported
  Keycloak-backed workloads.
- Public TLS currently terminates at Envoy on the supported `/vscode`, `/api`, and `/ws` routes
  behind `test.resolvefintech.com`. Phase `3` closes on one shared hostname and one certificate
  for all public and admin routes. Backend TLS or mTLS is not part of the current supported
  chart-workload contract.
- The current worktree ships repo-owned API, Redis, and WebSocket chart stacks, with settings-
  backed replica controls for the public API and WebSocket workloads. Redis remains scoped to
  shared application state for the current WebSocket surface and any later explicit external
  rate-limit service; the current chart catalog does not yet ship a standalone rate-limit-service
  workload.
- The current Vault reconcile plan includes the Sprint `3.18` chart-secret policy/role foundation:
  `src/Prodbox/Secret/VaultInventory.hs` enumerates the KV v2 paths, policies, service accounts,
  and Kubernetes-auth roles for Keycloak, Patroni, OIDC, SMTP, gateway event keys, and MinIO root
  credentials, plus the seed-object field plan for generated/static/external Vault KV fields. The
  supported workload charts now render explicit service accounts for the straightforward pod
  controllers. The `websocket` chart renders its workload OIDC client secret as a
  `SecretRef.Vault` read from `secret/data/vscode/oidc/prodbox-websocket`, and the workload binary
  exchanges its service-account JWT through Vault Kubernetes auth before the WebSocket runtime
  starts. The `keycloak` chart renders Vault-login init-container materialization for the admin,
  Patroni app-role, OIDC, demo-user, and shared SMTP fields before realm import, and the `minio`
  chart renders Vault-login init-container materialization for root credential files consumed by
  `MINIO_ROOT_USER_FILE` / `MINIO_ROOT_PASSWORD_FILE`. The `vscode` chart materializes the Envoy
  `SecurityPolicy` client Secret from `secret/data/vscode/oidc/vscode` with a Vault-authenticated
  post-install/post-upgrade Job and namespace-local Secret RBAC. The gateway chart renders
  event-key, AWS, and MinIO credential fields as `SecretRef.Vault` values and the daemon resolves
  them through Vault Kubernetes auth. The `keycloak-postgres` chart materializes Patroni role
  Secrets from Vault through the `prodbox-<namespace>-pg` pre-install hook. The AWS SES setup flow
  writes `secret/keycloak/smtp`, and host/admin helper paths read the remaining Keycloak admin,
  OIDC, demo-user, and SMTP material from Vault KV. Sprint `3.18` now includes the structural proof
  that migrated Vault materializers fail closed when Vault is sealed or unreachable; retirement of
  the old derivation and chart-generated paths is Sprint `3.19`.
- Supported operational dashboards now close on the shared Envoy edge for Harbor and MinIO.
- The current `PRODBOX_WORKLOAD_MODE=websocket` runtime now materializes workload-managed OIDC
  bootstrap, a real `/ws` upgrade path, one-live-connection-per-backend-pod lifetime,
  readiness-based drain, revoke-and-reconnect behavior, and long-lived socket session semantics on
  the shared `/ws` route.

## Sprint 3.1: Haskell Chart Runtime and Deterministic Retained Storage ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep chart orchestration and retained-storage handling on the Haskell runtime while preserving the
supported platform doctrine.

### Deliverables

- `prodbox charts list|status|deploy|delete` are implemented in Haskell.
- Deterministic retained storage under the configured manual PV root remains intact.
- All non-PV chart state stays inside the cluster; the older master-seed-derived and
  chart-generated Secret model is being retired by Sprints `3.18`–`3.19` in favor of Vault KV via
  Kubernetes auth. The legacy `.prodbox-state/` cache is on the cleanup ledger;
  `forbidDotProdboxState` in `prodbox check-code` (Sprint `4.18`) refuses regressions.
- Chart secret resolution and gateway event-key handling move to Haskell-owned modules.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-storage`
4. `prodbox test integration charts-platform`

### Current Validation State

- `test/unit/Main.hs` proves deterministic Haskell chart-plan and storage-binding behavior.
- `test/integration/CliSuite.hs` proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`, including explicit
  failure guidance when operators try to address internal `keycloak-postgres` or `redis`
  dependency releases directly.
### Remaining Work

None.

## Sprint 3.2: Haskell `vscode` Stack Delivery and Auth Path ✅

**Status**: Done
**Implementation**: `charts/`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the supported cluster-backed `vscode` stack on the Haskell chart runtime and the canonical
Harbor-first image doctrine.

### Deliverables

- The supported app path is `external PostgreSQL -> keycloak -> vscode`.
- The Haskell chart runtime owns deploy, status, and delete behavior for the `vscode` stack.
- Harbor-backed image refs remain canonical for the supported `keycloak` and `vscode` workloads
  after Harbor bootstrap.

### Validation

1. `prodbox test integration charts-platform`
2. `prodbox test integration charts-vscode`
3. Image-source proof: the supported chart or rendered manifests reference Harbor-backed refs for
   `keycloak` and `vscode`

### Current Validation State

- `src/Prodbox/TestPlan.hs` keeps `prodbox test integration charts-vscode` on the supported
  runtime bootstrap path rather than bypassing the cluster runbook.
- `src/Prodbox/TestRunner.hs` waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` before the external `charts-vscode` curl proof
  continues.
### Remaining Work

None.

## Sprint 3.3: Percona-Operator-Backed Patroni PostgreSQL Doctrine for Helm Workloads ✅

**Status**: Done
**Implementation**: `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/ContainerImage.hs`, `charts/`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep every Helm-managed PostgreSQL dependency on the implemented Percona-operator-backed external
Patroni HA surface.

### Deliverables

- Every supported Helm-managed PostgreSQL dependency consumes an external
  Percona-operator-backed Patroni HA deployment rather than an embedded chart-local PostgreSQL
  subchart or any retired operator surface.
- Every supported Patroni deployment runs exactly three PostgreSQL replicas with synchronous
  replication enabled.
- The only supported Helm role for Patroni is the cluster-wide Percona operator release plus the
  namespace-local application charts that render Percona-managed PostgreSQL custom resources,
  secrets, and dependent service inputs.
- Patroni-related images and Helm repository references are Harbor-backed or lifecycle-owned on
  the supported path after Harbor bootstrap.
- `keycloak`, `vscode`, and any later PostgreSQL-backed chart stack declare external database
  connectivity instead of rendering or depending on embedded PostgreSQL.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-vscode`
5. Helm proof: `prodbox rke2 reconcile` reconciles the cluster-wide Percona operator before
   namespace-local application charts deploy
6. Manifest proof: supported chart renders disable embedded PostgreSQL and target
   Percona-operator-managed service endpoints and custom resources
7. Image-source proof: Patroni-related chart workloads reference Harbor-backed images on the
   supported path

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` now installs the Percona `percona/pg-operator` Helm release from
  `https://percona.github.io/percona-helm-charts/`.
- `src/Prodbox/PostgresPlatform.hs` now defines the Percona operator namespace, release,
  deployment, CRD, service, and secret naming contract, including
  `perconapgclusters.pgv2.percona.com`, the `-ha` primary service, the `-replicas` service, and
  the Percona secret names for the application, superuser, and standby credentials.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders `keycloak-postgres` through
  `PerconaPGCluster`, waits for `.status.state=ready` plus `.status.postgres.ready=3`, discovers
  the operator-created PVC names before binding deterministic retained PVs, preserves the
  retained Patroni credential flow into `keycloak`, preserves the ordinal-0 retained anchor PV,
  restores retained clusters first at one replica, and then scales them back to three replicas
  after readiness before reinitializing follower roots when needed.
- `src/Prodbox/ContainerImage.hs` now mirrors
  `docker.io/percona/percona-postgresql-operator:2.9.0`,
  `docker.io/percona/percona-distribution-postgresql:17.9-1`,
  `docker.io/percona/percona-pgbouncer:1.25.1-1`, and
  `docker.io/percona/percona-pgbackrest:2.58.0-1` into Harbor and no longer carries any Zalando
  operator image targets on the supported path.
- `charts/keycloak-postgres/` now renders the retained application, superuser, and standby
  credentials secrets before the Percona cluster resource, alongside three replicas,
  synchronous mode, explicit security IDs `1001`, and deterministic manual-PV bindings.
- `charts/keycloak/` now consumes the namespace-local retained database secret and the namespace-local
  primary service endpoint.
- `documents/engineering/helm_chart_platform_doctrine.md` and the linked chart-platform doctrine
  now match the authoritative three-replica synchronous-replication contract described here.
### Remaining Work

None.

## Sprint 3.4: Envoy-Protected `vscode` Delivery and `vscode-nginx` Removal ✅

**Status**: Done
**Implementation**: `charts/vscode/`, `charts/keycloak/`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the `vscode` browser route on Gateway API delivery and Envoy-enforced browser auth with
Keycloak as the identity provider.

### Deliverables

- The supported `vscode` public route is expressed through Gateway API resources rather than
  `Ingress`.
- `vscode-nginx` is removed from the supported chart dependency graph and browser-facing auth path.
- Keycloak remains a chart-managed dependency, and this closed sprint removed the earlier
  nginx-backed browser-auth path before the final shared-host doctrine closed on the public edge.
- `keycloak_nginx_client_secret` is removed from the long-term chart secret contract.
- The current chart platform closes on Envoy-managed browser OIDC for `vscode`; Sprint `3.5`
  owns the remaining single-host API doctrine and any direct-identity path that still survives
  behind the shared hostname rather than broadening Sprint `3.4` beyond the shipped browser route.
- Optional Redis remains out of scope for the closed `vscode` sprint surface; Sprints `3.5` and
  `3.6` now carry the repo-owned API plus WebSocket workloads instead of chart-local auth proxies.

### Validation

1. `prodbox check-code`
2. `prodbox test integration charts-platform`
3. `prodbox test integration charts-vscode`
4. `prodbox test integration public-dns`
5. Manifest proof: the supported `vscode` path renders Gateway API resources and no longer renders
   `vscode-nginx`
6. Secret-contract proof: supported chart-secret state no longer requires
   `keycloak_nginx_client_secret`

### Current Validation State

- `charts/vscode/` now renders the public app path through `HTTPRoute` plus Envoy Gateway
  `SecurityPolicy`, with no `Ingress`, `vscode-nginx` deployment, or nginx config path.
- `charts/keycloak/` now renders the shared public-edge `Gateway`, certificate, identity
  `HTTPRoute`, and the supported shared-host Keycloak contract.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders the Gateway API, OIDC, and shared-host values
  contract, and the chart-secret contract now uses
  `keycloak_vscode_client_secret`.
- `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, and the built-frontend suites no
  longer carry the nginx proxy image or image-publication path.
- The shipped chart surface now includes `keycloak`, `vscode`, `api`, and `websocket` workloads
  on the supported shared-host public edge.

### Remaining Work

None.

## Sprint 3.5: JWT-Protected API Workload Delivery ✅

**Status**: Done
**Implementation**: `charts/api/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported JWT-protected API workload to the Haskell chart platform on the shared hostname
so the public edge proves local token validation and route claims while the chart platform closes
explicitly on Keycloak-backed Envoy auth and RBAC.

### Deliverables

- The supported chart catalog adds a JWT-protected API workload on
  `https://test.resolvefintech.com/api` with Haskell deploy, status, and delete ownership.
- Envoy authenticates the API route locally from Keycloak issuer metadata and signing keys rather
  than through per-request Keycloak lookups or Redis.
- The API route carries explicit issuer, audience, path-claim, and RBAC requirements through
  repo-owned chart values and templates.
- The supported auth model explicitly identifies bearer-token API carriage, Envoy-owned browser
  redirect and cookie or session return paths, and the shared-host relationship between `/api`,
  `/vscode`, `/ws`, `/auth`, and later admin paths.
- Envoy discovers Keycloak JWKS out of band and validates API tokens locally on the hot path;
  Keycloak availability remains a login, refresh, and JWKS-refresh boundary rather than a
  per-request API dependency.
- The chart secret and Keycloak client contract expands as needed for the supported API route
  without reintroducing any app-local auth proxy surface.
- The supported chart platform explicitly distinguishes Envoy-managed browser or admin auth for
  proxy-auth workloads from any remaining workload-managed auth path that still needs direct
  identity claims or session ownership behind the same host.
- Keycloak-backed public workloads preserve the shared-host contract, including issuer alignment,
  proxy-header compatibility, and no supported public management or health path exposure unless a
  later doctrine revision expands that route set.
- The supported chart platform makes the current transport boundary explicit: public TLS terminates
  at Envoy, and backend TLS or mTLS remains outside the supported chart-workload contract until a
  later doctrine revision expands it.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-api`
5. Manifest proof: the API route attaches shared-host Gateway API and Envoy auth policy resources
   on the supported public edge
6. Auth proof: unauthenticated or wrong-claim requests are denied, while valid tokens from the
   configured Keycloak issuer are accepted
7. Doctrine proof: the supported API, browser, and direct-OIDC split names the request-token
   carrier and JWKS boundary explicitly and does not route JWT validation through Redis or
   per-request Keycloak calls
8. Manifest or runtime proof: the API route closes on the shared-host Keycloak issuer and proxy
   contract without reintroducing nginx proxy surfaces or extra public subdomains

### Current Validation State

- `src/Prodbox/Lib/ChartPlatform.hs`, `charts/api/`, and `src/Prodbox/Workload.hs` now render and
  serve the API workload, JWT provider configuration, audience, and route-claim requirements
  through repo-owned Gateway API, Envoy, and `PRODBOX_WORKLOAD_MODE=api` runtime surfaces.
- The current shipped browser route exercises the Envoy-managed redirect and cookie or session
  path, and the current API route validates request-carried bearer JWTs locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose `charts-api` as a
  named external validation surface that proves unauthenticated rejection, wrong-claim rejection,
  and valid-token acceptance.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain aligned with the API workload surface.
- The shipped chart catalog now exercises the auth shapes the single-host doctrine must preserve:
  Envoy-managed browser OIDC through `vscode`, request-carried bearer JWTs through `api`, and the
  remaining direct-OIDC or workload-owned state required by the `websocket` path.
- `src/Prodbox/TestValidation.hs` proves the shared-host Keycloak issuer, redirect, and
  public-path contract for the API route on `https://test.resolvefintech.com/api`.
- The repo-owned chart surface now also carries the current WebSocket auth-path hardening:
  `charts/keycloak/` runs the identity path on one Keycloak replica, `charts/websocket/`
  authorizes a private token-endpoint backchannel to that identity workload, and the repo-owned
  custom image charts now force fresh pulls for the stable machine-id tags so the canonical suite
  does not reuse stale workload binaries.

### Remaining Work

None.

## Sprint 3.6: Redis-Backed WebSocket Delivery and Scale-Out ✅

**Status**: Done
**Implementation**: `charts/redis/`, `charts/websocket/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported WebSocket workload and its Redis backing service to the Haskell chart platform so
the public edge closes on reconnect-safe realtime delivery under the shared hostname.

### Deliverables

- The supported chart catalog adds repo-owned Redis and WebSocket workloads with shared-host
  WebSocket routing on the Envoy edge.
- The supported `websocket` surface serves a true WebSocket endpoint on
  `https://test.resolvefintech.com/ws` rather than only HTTP helper endpoints on a dedicated
  WebSocket hostname.
- Reconnect-safe or restart-safe WebSocket state lives in Redis rather than in one pod's memory,
  and each live upgraded connection remains on one selected backend pod until disconnect.
- The supported public workload surface expands from single-replica `vscode` only to explicit
  multi-replica API or WebSocket workload scaling where the doctrine requires it.
- The chart runtime keeps Redis scoped to shared application state and never to Envoy JWT
  validation.
- The supported WebSocket workload documents and implements bounded connection-lifetime auth plus
  graceful termination behavior for deploy-time drain and reconnect, including readiness removal
  before terminating pods exit.
- The supported WebSocket workload defines token-expiry, authorization-change, reconnect, and
  drain behavior explicitly, and leaves per-message authorization to the workload when
  message-level permissions are finer-grained than the edge can enforce.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-websocket`
5. Manifest proof: the WebSocket route and Redis backing service render through repo-owned charts
   and the shared public hostname
6. Behavioral proof: authenticated WebSocket upgrade, one-upgraded-connection-per-backend-pod
   lifetime, reconnect-safe state, cross-replica message delivery, token-expiry or reconnect
   behavior, authorization-change handling, and readiness-based graceful drain work through the
   supported Redis-backed path

### Current Validation State

- The current chart catalog now includes repo-owned `redis` and `websocket` stacks, and
  `src/Prodbox/Workload.hs` provides the shared public-edge workload runtime selected through
  `PRODBOX_WORKLOAD_MODE=websocket`.
- The current WebSocket runtime surface now implements workload-managed OIDC bootstrap, a real
  `/ws` upgrade path, one-upgraded-connection-per-backend-pod lifetime, Redis-backed shared
  state, revocation-driven reconnect, and readiness-based drain for long-lived socket sessions.
- `deployment.websocket_scaling` and `deployment.api_scaling` now carry the settings-backed
  scale-out contract for the public workload surface.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose `charts-websocket` as
  a named external validation surface that proves authenticated WebSocket upgrade, cross-replica
  delivery, revocation-driven reconnect, readiness-based drain, and post-pod-restart state
  survival on the WebSocket surface.
- `src/Prodbox/Workload.hs`, `charts/websocket/`, and `charts/keycloak/` now also carry the
  private Keycloak token-endpoint backchannel, the matching inter-chart network-policy allowance,
  and the current single-replica Keycloak auth-path workaround needed to keep direct-OIDC browser
  login stable on the supported stack while remaining on the shared-host doctrine.

### Remaining Work

None.

## Sprint 3.7: Envoy-Routed Admin Surfaces and Shared-Host RBAC ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/PublicEdge.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `charts/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Expose the supported operational dashboards, Harbor and MinIO, through Envoy on
`test.resolvefintech.com`, protected by Keycloak-backed auth and RBAC, so the platform needs only
one public hostname, one DNS entry, and one certificate.

### Deliverables

- Supported Harbor and MinIO dashboards route only through Envoy on explicit shared-host paths.
- Keycloak-backed JWT auth and route-level RBAC protect those admin surfaces at Envoy.
- No supported admin dashboard requires its own public hostname, DNS record, or certificate.
- Public-edge diagnostics and named validations include the shared-host admin surface.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-platform`
5. `prodbox test integration admin-routes`
6. Manifest proof: Harbor and MinIO render behind Envoy on shared-host paths with Keycloak-backed
   auth policy

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` now renders the supported Harbor and MinIO `HTTPRoute` plus
  `SecurityPolicy` resources behind Envoy on `/harbor` and `/minio`.
- `src/Prodbox/PublicEdge.hs` now centralizes the supported `/auth`, `/vscode`, `/api`, `/ws`,
  `/harbor`, and `/minio` path catalog used by the shared-host admin manifests, host
  diagnostics, and named validation surfaces.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose
  `prodbox test integration admin-routes` as the named external validation surface for the
  supported shared-host admin paths.
- `src/Prodbox/Host.hs` classifies Harbor and MinIO as supported admin routes on the shared
  hostname alongside the application route catalog.

### Remaining Work

None.

## Sprint 3.8: Smart Constructors for Paired Chart Resources ✅

**Status**: Done
**Implementation**: `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Adopt [haskell_code_guide.md#smart-constructors-for-paired-resources](../documents/engineering/haskell_code_guide.md#smart-constructors-for-paired-resources) on the chart platform.

### Deliverables

- Refactor PV/PVC pair construction in `src/Prodbox/Lib/Storage.hs` and
  `src/Prodbox/PostgresPlatform.hs` to flow through a single `mkStorageBinding`-style smart
  constructor that derives both resources from one set of inputs and uses the naming helpers
  introduced in Sprint 1.15.
- Apply the same discipline to any other paired resources (database user + grants, queue +
  dead-letter queue, etc.) observable in the chart platform.

### Validation

1. Unit tests confirm that the paired resources are derived from the smart constructor only.
2. Hand-constructed PV/PVC pairs outside the smart constructor are enqueued in the legacy
   ledger and removed.

### Remaining Work

None.

## Sprint 3.9: Capability Classes Applied to Redis and Postgres ✅

**Status**: Done
**Implementation**: `src/Prodbox/Service.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Apply [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors) (Sprint 1.12) to chart-platform call sites.

### Deliverables

- Replace direct Redis / Postgres call sites in `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs` with `HasRedis` / `HasPg` method calls.
- Wire `retryServiceAction` into transient failure paths.

### Validation

1. `cabal test prodbox-unit` covers the new abstraction with `Env` test hooks.
2. Direct `redis-cli` / raw Postgres subprocess invocations outside the capability classes are
   absent.

### Remaining Work

None. Patroni cluster discovery, readiness, retained-claim wait, retained-anchor lookup,
secret recovery, and cleanup paths in `src/Prodbox/Lib/ChartPlatform.hs` now consume the `HasPg`
capability and classify transient PostgreSQL convergence failures as `PgError` through
`retryServiceAction`. The supported chart platform has no direct `redis-cli` call site, and
`test/unit/Main.hs` asserts that the chart PostgreSQL service calls pass through the capability
boundary.

## Sprint 3.10: Reconciler Discipline on prodbox charts deploy | delete ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Parser.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Adopt [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).

### Deliverables

- `prodbox charts deploy <chart>` is the canonical idempotent reconcile; re-running it on a
  healthy chart is a documented no-op.
- `prodbox charts delete <chart> [--yes]` is the explicit teardown.
- Forbid any `--force` / `--reinstall` flag flavor on the chart surface; document
  already-deployed as the success case.
- Sprint 0.4 round-3 extension: name the forbidden flags and sister commands
  explicitly per [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command). The chart reconciler surface
  refuses the literal flag names `--force` and `--reinstall` at parse time
  (Sprint 1.6 `CommandSpec` for `prodbox charts deploy|delete` does not register
  them; `execParserPure` returns a doctrine-named error if they are passed). The
  reconciler surface also refuses any sister command named `install`, `upgrade`,
  `repair`, or `force-install` on the `prodbox charts ...` family; the only
  mutation entrypoints are `deploy` and `delete`. A `prodbox-unit` parser test
  asserts that each forbidden flag and each forbidden sister-command name yields
  a parse-time rejection with the doctrine pointer.

### Validation

1. Integration test runs `prodbox charts deploy <chart>` twice in succession; the second run
   completes with no mutations applied.
2. The lint stack from Sprint 1.10 rejects the forbidden flag names.

### Remaining Work

None.

## Sprint 3.11: --dry-run on Chart Operations ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Lib/ChartPlatform.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Apply the Plan / Apply discipline from Sprint 1.7 to chart operations.

### Deliverables

- `prodbox charts deploy --dry-run <chart>` and `prodbox charts delete --dry-run <chart>`
  render the full Helm + Kubernetes + Pulumi plan and exit `0` without mutation.
- Golden tests cover the rendered plans.

### Validation

1. `cabal test prodbox-unit` validates the rendered chart plans.
2. The dry-run output is deterministic and free of timestamps or environment leakage.

### Remaining Work

None.

## Sprint 3.12: prodbox lint chart and Route-Inventory Generation ✅

**Status**: Done
**Implementation**: `src/Prodbox/CheckCode.hs`, `src/Prodbox/PublicEdge.hs`, `charts/keycloak/templates/gateway.yaml`, `charts/vscode/templates/http-route.yaml`, `charts/api/templates/http-route.yaml`, `charts/websocket/templates/http-route.yaml`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/documentation_standards.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/documentation_standards.md`

### Objective

Adopt [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack)and §1870, and apply
[code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)/ §394–443
to the `src/Prodbox/PublicEdge.hs` route catalog so chart artifacts consume the route
inventory through marker-delimited generation rather than hand-maintained YAML.

### Deliverables

- `src/Prodbox/CheckCode.hs` owns the `prodbox lint chart` subcommand declared in the
  `CommandSpec` registry (Sprint 1.6). The linter validates Helm chart structural invariants
  for every chart under `charts/`:
  - `Chart.yaml` parses, declares `apiVersion: v2`, and carries the required
    `name` / `version` / `appVersion` fields.
  - Every chart includes the mandatory `app.kubernetes.io/name`,
    `app.kubernetes.io/managed-by: prodbox`, and the phase-3 retained-storage label set.
  - Marker-delimited generated sections inside charts are reachable through the
    `generatedSectionRule` registry (Sprint 1.10) so drift fails closed.
- The existing `prodbox-haskell-style` test-suite stanza (Sprint 1.11) covers the
  generated route-inventory output and durable chart-generation surfaces, so the lint
  contract is exercised from both `prodbox lint chart` and `cabal test
  prodbox-haskell-style`.
- `src/Prodbox/PublicEdge.hs` rendering helpers emit the route catalog into chart
  manifests through marker-delimited blocks (`{{/* prodbox:route-registry:start */}}` /
  `{{/* prodbox:route-registry:end */}}` in Helm-template files,
  `# prodbox:route-registry:start` / `# prodbox:route-registry:end` in YAML manifests),
  registered in `generatedSectionRule` alongside CLI docs. Consumers in `charts/keycloak/`,
  `charts/vscode/`, `charts/api/`, `charts/websocket/`, and the shared-host admin manifests
  consume the generated section rather than hand-maintaining path prefixes.
- `documents/engineering/cli_command_surface.md` enumerates the new `prodbox lint chart`
  subcommand and the route-inventory generation surface.
- `documents/documentation_standards.md` adds route inventory to its enumerated list of
  generated files.
- "Cross-language types" generation (doctrine §341–343) is **deferred**: no non-Haskell
  consumer is in scope; the deferral is recorded in `system-components.md` and in
  `documents/engineering/cli_command_surface.md`. The `generatedSectionRule` registry
  remains ready for that consumer when one appears.
- Enqueue any pre-doctrine hand-maintained route catalog inside chart manifests in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal`
  with Sprint 3.12 as owner.

### Validation

1. `prodbox lint chart` succeeds on a clean tree and fails on a chart with a missing
   mandatory label or malformed `Chart.yaml`.
2. Hand-editing the route inventory inside any consuming chart manifest fails
   `prodbox lint docs` with the doctrine's path / registry-key / remedy-hint triple.
3. Regenerating the route inventory via `prodbox lint docs --write` (or
   `prodbox docs generate`) produces byte-identical output for the same `PublicEdge.hs`
   inputs (idempotent renderer property test from Sprint 1.21 covers this).

### Remaining Work

None.

## Sprint 3.13: Chart Secrets Derived by the Gateway Service ✅

**Status**: Done — code-owned surface
fully closed (chunks 1\8211\&16) as of 2026-05-31. Every host-side
`.prodbox-state/` chart-secret + gateway-event-key writer has been
removed; chart secrets and gateway event keys all flow through
master-seed-derived k8s `Secret`s materialized by the gateway daemon's
`ensure-namespace` handler or startup self-bootstrap, and chart
templates read them via Helm `lookup`. The full-sprint closure gate is
the live four-block preserved-data exercise (operator-driven). First
chunk landed 2026-05-30 on top of Sprint
2.19's daemon-side derivation foundation: new
`src/Prodbox/Secret/Inventory.hs` exposes the doctrine-§6 derived-secret
inventory in code via `derivedSecretInventoryFor :: Text -> Text -> [DerivedSecretEntry]`.
Currently enumerates the three Patroni roles for
`(keycloak, keycloak-postgres)` (`prodbox-keycloak-pg-pguser-keycloak` /
`-pg-pguser-postgres` / `-primaryuser` against the
`patroni:keycloak:keycloak-postgres:{app,superuser,standby}` context
strings) and the Keycloak admin field for `(keycloak, keycloak)`
(`keycloak-runtime.KEYCLOAK_ADMIN_PASSWORD` against
`keycloak:keycloak:admin`); returns `[]` for releases whose chart-side
Secrets are non-derived (`vscode`, `api`, `websocket`). Gateway per-node
event-key Secrets are intentionally not in the static table — their
count is a function of the live gateway node inventory, so the daemon's
`ensure-namespace` handler will inject them dynamically when
materializing the gateway release. Seven new unit tests in
`test/unit/Main.hs::"Sprint 3.13 derived-secret inventory"` cover the
keycloak-postgres + keycloak rows, the empty-fallthrough cases, and the
purity invariant. **Implementation choice (replaces the "new in-cluster
bootstrap binary OR ServiceAccount-via-kubectl" fork in the original
Sprint 3.13 scope)**: the chart pre-install Jobs will POST to
`/v1/secret/ensure-namespace`; the daemon itself owns the
kubectl-apply via its in-cluster ServiceAccount, so no new bootstrap
binary or chart-side Secret-create RBAC is needed. The pre-install Job
is a thin `curl`-equivalent + wait pattern. `prodbox check-code` 0,
`prodbox test unit` 613/613, `prodbox test integration cli` 30/30,
`prodbox docs check` 0, `prodbox lint docs` 0.

Second chunk landed 2026-05-30: new `src/Prodbox/K8s/InCluster.hs`
exposes the foundational K8s API client surface the daemon's
`ensure-namespace` handler will consume — pod ServiceAccount
credentials (`loadInClusterCredentials :: IO (Either String
InClusterCredentials)` reads token + ca.crt path + namespace from the
standard `/var/run/secrets/kubernetes.io/serviceaccount/` projected
mount), the canonical kube-apiserver Service URL
(`secretApiBaseUrl = "https://kubernetes.default.svc.cluster.local:443"`),
the namespaced @v1.Secret@ REST path renderer (`secretApiPath ::
namespace -> name -> String`), and the pure JSON manifest builder
(`secretManifestJson :: namespace -> name -> Map Text Text -> Value`
that emits `apiVersion: v1`, `kind: Secret`, `type: Opaque`, and a
lexically-ordered `stringData` block — deterministic per the doctrine
generated-artifact rule). Seven new unit tests in
`"Sprint 3.13 in-cluster K8s API client pure helpers"` cover the
ServiceAccount paths, the kube-apiserver URL, the REST-path renderer,
manifest field encoding, deterministic key ordering, purity, and the
empty-stringData edge case. `prodbox check-code` 0, `prodbox test
unit` 620/620 (+7), `prodbox test integration cli` 30/30, `prodbox
docs check` 0, `prodbox lint docs` 0.

Third chunk landed 2026-05-30: the `applyDerivedSecrets` pipeline +
the `K8sSecretOps` capability that decouples the handler logic from
the TLS-backed HTTPS implementation.

- New `K8sSecretOps` record on `Prodbox.K8s.InCluster` bundles the
  two namespaced @v1.Secret@ operations the handler needs:
  `secretOpsGet :: Text -> Text -> IO (Either String (Maybe Value))`
  and `secretOpsPut :: Text -> Text -> Value -> IO (Either String ())`.
  Lets the handler logic be unit-tested against an in-process mock
  without spinning up an HTTPS stack.
- New `src/Prodbox/Secret/EnsureNamespace.hs` exposes
  `applyDerivedSecrets :: K8sSecretOps -> MasterSeed -> Text -> [DerivedSecretEntry] -> IO (Either String [SecretSha256Entry])`
  — the doctrine-§4 idempotent materialization loop: for each entry,
  derive the value via `deriveBase64Url` over the master seed +
  context, build the `v1.Secret` manifest via
  `InCluster.secretManifestJson`, PUT through `secretOpsPut`, then
  compute the SHA-256 of the derived value for the response inventory.
  Short-circuits on the first PUT failure with a structured error
  naming the offending Secret + namespace + reason. Also exposes
  pure `deriveSecretValueText` (base64url Text wrapper) +
  `deriveSecretSha256Hex` (lowercase-hex SHA-256 wrapper) so unit tests
  can pin the wire encoding independent of the I/O loop.
- Six new unit tests in
  `"Sprint 3.13 applyDerivedSecrets pipeline"` cover: PUT-per-entry
  ordering against the keycloak-postgres inventory triple; the full
  v1/Secret/Opaque manifest shape for the single keycloak-runtime
  entry; that the response inventory carries SHA-256-of-derived
  (verified against a freshly-recomputed expected value); the
  determinism + lowercase-hex + 64-char-length invariants of
  `deriveSecretSha256Hex`; first-failure short-circuit behavior with
  no further PUT calls; and the empty-list passthrough.

The handler logic is now testable end-to-end via a mock
`K8sSecretOps`. The TLS-backed `K8sSecretOps` constructor (with the
in-pod CA store + bearer-token bearer-auth via `http-client-tls`) is
the next chunk's target. `prodbox check-code` 0, `prodbox test unit`
626/626 (+6), `prodbox test integration cli` 30/30, `prodbox docs
check` 0, `prodbox lint docs` 0.

Fourth chunk landed 2026-05-30: TLS-backed `K8sSecretOps` constructor
ready to drop into the daemon handler.

- New `inClusterK8sSecretOps :: InClusterCredentials -> IO (Either
  String K8sSecretOps)` on `Prodbox.K8s.InCluster`: reads the in-pod
  CA at 'inClusterCredentialsCaCertPath' via
  `Data.X509.CertificateStore.readCertificateStore`, configures a
  `Network.TLS.ClientParams` whose `clientShared.sharedCAStore` is
  the in-pod store (so the API server's serving cert verifies against
  the cluster's internal CA, not the system trust store), wraps in a
  `Network.Connection.TLSSettings`, and creates an HTTP `Manager` via
  `Network.HTTP.Client.TLS.mkManagerSettings`. The `secretOpsGet` and
  `secretOpsPut` closures inject the ServiceAccount bearer token as
  the `Authorization` header on every request. GET returns @Right
  Nothing@ on 404, @Right (Just value)@ on 200, @Left@ otherwise; PUT
  accepts 200 and 201 as success (API server picks create-vs-update
  server-side), structured-error on anything else with a truncated
  response-body suffix for diagnostics.
- New cabal deps to enable this (and resolved the `tls`-vs-`connection`
  version conflict by switching to the modern fork): `tls ^>=2.1`,
  `crypton-connection ^>=0.4` (replaces the old `connection` package),
  `crypton-x509-store ^>=1.6` (for `readCertificateStore`), and a
  bump of `http-client-tls` to `^>=0.3.6.4` so its newer release pulls
  `crypton-connection` instead of legacy `connection`.

Inert until the daemon handler dispatch chunk wires it in — the
TLS-backed constructor lives as a pure factory that the next chunk
imports. `prodbox check-code` 0, `prodbox test unit` 626/626 (no new
tests added; the TLS path is exercise-gated, not unit-gated), `prodbox
test integration cli` 30/30, `prodbox docs check` 0, `prodbox lint
docs` 0.

Fifth chunk landed 2026-05-30: daemon handler dispatch wires all four
prior chunks together. The hardcoded 503 stub at
`Gateway/Daemon.hs:855` is replaced by a real
`handleSecretEnsureNamespace` that:

1. Returns 503 when `envMasterSeed` is `Nothing` (same gate as
   `/v1/secret/derive`).
2. Extracts the HTTP request body via a new pure
   `extractRequestBody :: BS.ByteString -> BS.ByteString` helper
   (splits on `\\r\\n\\r\\n`, returns empty on missing separator).
3. Decodes the body to `SecretWire.EnsureNamespaceRequest`; returns
   400 with structured JSON on malformed input.
4. Loads in-pod ServiceAccount credentials via
   `InCluster.loadInClusterCredentials`; returns 503 when the
   ServiceAccount projection is missing (e.g. running outside
   Kubernetes).
5. Constructs the TLS-backed K8s API client via
   `InCluster.inClusterK8sSecretOps`; returns 503 with the structured
   reason on CA-cert load failure.
6. Looks up the doctrine-§6 inventory via
   `Inventory.derivedSecretInventoryFor namespace release`.
7. Invokes `EnsureNamespace.applyDerivedSecrets ops seed namespace
   inventory`; returns 500 with the structured reason on first PUT
   failure.
8. On success: returns 200 with the
   `SecretWire.EnsureNamespaceResponse` carrying the per-Secret
   SHA-256 inventory.

The daemon endpoint is now fully wired end-to-end on the code surface;
the only remaining moving parts are the chart-side RBAC (so the daemon
Pod actually has `secrets:create` permission in target namespaces)
and the chart pre-install Jobs (the in-cluster callers). Live
exercise — chart pre-install Job → endpoint → derived Secret applied
to a target namespace — is the closure gate. `prodbox check-code` 0,
`prodbox test unit` 626/626, `prodbox test integration cli` 30/30,
`prodbox docs check` 0, `prodbox lint docs` 0.

Sixth chunk landed 2026-05-30: gateway-chart RBAC so the daemon's
in-pod ServiceAccount actually has `secrets:get,create,patch` in the
namespaces it writes to.

- New `charts/gateway/templates/serviceaccount.yaml` declares the
  `prodbox-gateway-daemon` ServiceAccount in the gateway namespace.
- New `charts/gateway/templates/rbac.yaml` emits one `Role` +
  `RoleBinding` pair per entry in the new
  `rbac.targetNamespaces` values list. Each Role lives in the target
  namespace (so the grant is narrowly scoped) and grants
  `secrets:get,create,patch`; each RoleBinding binds the
  gateway-namespace ServiceAccount to the target-namespace Role.
- `charts/gateway/values.yaml` adds the `rbac.targetNamespaces` list;
  currently `[keycloak]` (the only namespace with derived inventory
  entries today). The comment block documents the expansion rule for
  when the gateway per-node event-key inventory + vscode/api/websocket
  derived entries land.
- `charts/gateway/templates/deployments.yaml` binds the daemon Pod
  spec to the new ServiceAccount via `serviceAccountName:
  prodbox-gateway-daemon` — this is what makes
  `/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt,namespace}`
  project the gateway-daemon token (instead of the namespace's
  `default` SA token) into the Pod for
  `InCluster.loadInClusterCredentials` to read.

The chart-side daemon-secret-write path is fully wired now. The
remaining Sprint 3.13 work is the chart pre-install Jobs (the
in-cluster callers) and the host-side `resolveChartSecrets` rewrite.
`prodbox check-code` 0, `prodbox test unit` 626/626, `prodbox test
integration cli` 30/30, `prodbox docs check` 0, `prodbox lint docs` 0.

Seventh chunk landed 2026-05-30: unified gateway ClusterIP + chart
pre-install Jobs for the two releases with derived inventory entries
(`keycloak-postgres` and `keycloak`).

- New `charts/gateway/templates/service-clusterip.yaml` exposes an
  unsuffixed `gateway` ClusterIP Service in the gateway namespace,
  selecting any gateway pod (selector intentionally omits the
  `gateway-node` label). This is the third Service shape per
  [doctrine §5](../documents/engineering/secret_derivation_doctrine.md#5-host-cluster-boundary)
  — the in-cluster RPC entrypoint at
  `gateway.gateway.svc.cluster.local:8443`. The per-node `gateway-<nodeId>`
  ClusterIPs (peer-gossip event channel) and the `gateway-nodeport`
  Service (host-CLI access) remain unchanged.
- New `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml`
  + `charts/keycloak/templates/secret-bootstrap-job.yaml`: Helm
  `pre-install,pre-upgrade` hooks (`hook-weight: -10`,
  `hook-delete-policy: before-hook-creation,hook-succeeded`) that
  POST `{"namespace":"<release-ns>","release":"<release-name>"}` to
  the gateway's `/v1/secret/ensure-namespace` endpoint via
  the canonical Harbor mirror
  `127.0.0.1:30080/prodbox/curl-mirror:8.11.0` (small +
  curl-only image). `--retry 12 --retry-delay 5
  --retry-connrefused` covers transient daemon-pod
  readiness flaps; `--max-time 30` bounds the wait. The Job's
  successful completion is the gate that lets the chart's actual
  Secret manifests (which `lookup` the daemon-applied Secrets)
  render.
- `charts/{keycloak,keycloak-postgres}/values.yaml` add the new
  `prodboxGateway.restPort: 8443` key (separate top-level to avoid
  collision with keycloak's existing Envoy-Gateway `gateway:` block).

The end-to-end Sprint 3.13 pipeline is now fully assembled on the
cluster side: chart pre-install Job → POST to gateway ClusterIP →
`handleSecretEnsureNamespace` → master-seed derivation →
`applyDerivedSecrets` via the in-pod RBAC'd K8s API client → derived
Secrets land in the target namespace before the chart's own resources
install. The only remaining work is the host-side `resolveChartSecrets`
rewrite (gut the `.prodbox-state` cache, call
`Prodbox.Gateway.Client.ensureNamespace` from the operator host, drop
the silent-reset arm of `shouldResetPatroniStorage`). Live exercise on
this host (the four-block preserved-data + recovery-escape-hatch +
original-failure-mode path from the approved plan Part 3) is the
closure gate. `prodbox check-code` 0, `prodbox test unit` 626/626,
`prodbox test integration cli` 30/30, `prodbox docs check` 0, `prodbox
lint docs` 0.

Eighth chunk landed 2026-05-31: end the chart-vs-daemon multi-writer
race on the data-bound Secrets the daemon now owns
(`keycloak-runtime.KEYCLOAK_ADMIN_PASSWORD` for keycloak,
`prodbox-keycloak-pg-pguser-*` / `-primaryuser` for keycloak-postgres).
Pre-chunk-8 state was structurally inconsistent: chunks 1–7 wired the
daemon to write those Secrets via the pre-install Job, but the chart's
`secret.yaml` (keycloak) and `00-secrets.yaml` (keycloak-postgres) also
rendered `keycloak-runtime` and the three Patroni Secrets via
`{{ .Values… }}` injection. Helm's apply runs **after** the pre-install
hook completes, so helm would overwrite the daemon's
master-seed-derived `KEYCLOAK_ADMIN_PASSWORD` / Patroni `password` with
the chart's `--set`-injected `chartSecrets` random/file-cache values —
silently undoing the entire derivation pipeline.

- `charts/keycloak/templates/secret.yaml` no longer renders the
  `keycloak-runtime` Secret; the daemon's pre-install Job is the sole
  writer of `KEYCLOAK_ADMIN_PASSWORD`. The `keycloak-smtp` Secret block
  is unchanged (still chart-managed pending the SES migration chunk).
- `charts/keycloak/templates/deployment.yaml` reads
  `KEYCLOAK_ADMIN` as a literal env var (`value: "admin"` from
  `.Values.keycloak.adminUser`); `KEYCLOAK_ADMIN_PASSWORD` continues to
  read from the daemon-applied `keycloak-runtime` Secret via
  `secretKeyRef`. Splits the admin username (non-secret) from the
  derived admin password (data-bound).
- `charts/keycloak-postgres/templates/00-secrets.yaml` removed entirely
  — the daemon's pre-install Job is the sole writer of the three
  Patroni Secrets the Crunchy operator watches.
- `Prodbox.Secret.Inventory.DerivedSecretEntry` extends with
  `derivedSecretEntryStaticFields :: [(Text, Text)]` so the daemon can
  write non-derived companion fields alongside the derived value in the
  same k8s Secret. Required because the Crunchy operator demands both
  `username` and `password` in each Patroni Secret it watches: the
  username is per-role static (`keycloak` / `postgres` /
  `primaryuser`), the password is HMAC-derived from the master seed.
- `Prodbox.Secret.EnsureNamespace.applyDerivedSecrets` merges the
  static fields into the manifest body so the daemon's PUT writes both
  `username` and `password` atomically.
- Tests: 2 new tests in `test/unit/Main.hs` — one pinning the
  `derivedSecretEntryStaticFields` shape for the three Patroni entries,
  one asserting the rendered manifest includes the `username` static
  field. The existing test that exercised
  `charts/keycloak-postgres/templates/00-secrets.yaml` is rewritten to
  assert the file is absent (delegation to daemon) and to check the
  pre-install Job's `helm.sh/hook` annotation as the new closure of
  the same contract. The stale `awsTestMain shouldContain "publicKey:"`
  assertion is updated to the chunk-6 reality
  (`tls:PrivateKey` + `ssh_private_key:` outputs).
- Validation: `prodbox check-code` exit 0; `prodbox test unit` 628
  examples pass; `prodbox lint docs` / `docs check` exit 0;
  `helm template keycloak charts/keycloak` and
  `helm template keycloak-postgres charts/keycloak-postgres` both
  render cleanly without any conflicting Secret apply.

Remaining Sprint 3.13 work after chunk 8:

- OAuth client secrets (`vscode`, `prodbox-api`, `prodbox-websocket`)
  + the `demo-user` password still flow via `chartSecrets` → `--set`
  → `configmap.yaml` realm-import JSON / chart values. To eliminate the
  remaining `.prodbox-state/<ns>/.secrets.json` writes, these need to
  either join the daemon's derivation inventory (`oidc:<ns>:<clientId>`
  context strings — straightforward extension of `Prodbox.Secret.Derive`
  + `Prodbox.Secret.Inventory`) and be read via Helm `lookup` from
  chart templates, OR become chart-managed via per-chart Secret +
  `lookup` + `randAlphaNum`. The latter is simpler for the
  non-data-bound case but requires the chart's realm-import to read the
  client secret from a Pod env var via Keycloak's `${env:VAR}`
  substitution.
- `resolveChartSecrets` rewrite per spec (single call to
  `Prodbox.Gateway.Client.ensureNamespace` + sanity check via
  `kubectl get secret`; remove `recoverPatroniSecretValues` /
  `mergeChartSecretValues`).
- `shouldResetPatroniStorage` rework (replace silent reset with
  loud-failure mismatch check via `Prodbox.Gateway.Client.derive` +
  `pg_authid` probe).
- `.patroni-anchor-volume` marker removal.
- `Prodbox.Infra.AwsSesStack.persistKeycloakSmtpChartSecrets` migration
  off `.prodbox-state/charts/keycloak/.secrets.json`.
- `Prodbox.UsersAdmin` read path off
  `.prodbox-state/charts/keycloak/.secrets.json`.

The live closure gate (four-block preserved-data + recovery-escape-hatch
+ original-failure-mode exercise) closes the whole sprint after the
remaining chunks land.

**Blocked by**: ~~Sprint 2.19~~ unblocked — `/v1/secret/ensure-namespace` is no longer a structured-503 stub; the daemon handler dispatch is live.
**Implementation**: ✅ `src/Prodbox/Secret/Inventory.hs` (doctrine-§6 inventory; 2026-05-30); ✅ `src/Prodbox/K8s/InCluster.hs` (in-pod credentials loader + REST-path / manifest helpers + `K8sSecretOps` capability + TLS-backed `inClusterK8sSecretOps` constructor; 2026-05-30); ✅ `src/Prodbox/Secret/EnsureNamespace.hs` (`applyDerivedSecrets` pipeline + sha256/base64url wire helpers; 2026-05-30); ✅ `src/Prodbox/Gateway/Daemon.hs::handleSecretEnsureNamespace` (replaces the 503 stub with the full request-body parse + master-seed gate + ServiceAccount load + TLS client construction + `applyDerivedSecrets` invocation + structured response; 2026-05-30); ✅ `charts/gateway/templates/serviceaccount.yaml` + `rbac.yaml` + `service-clusterip.yaml` + `deployments.yaml::serviceAccountName` (per-target-namespace Role + RoleBinding pairs for `secrets:get,create,patch` + unsuffixed in-cluster ClusterIP; 2026-05-30); ✅ `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml` + `charts/keycloak/templates/secret-bootstrap-job.yaml` (Helm pre-install Jobs that POST to ensure-namespace via the gateway ClusterIP; 2026-05-30); ✅ `src/Prodbox/Lib/ChartPlatform.hs` (`resolveChartSecrets` cache removal); ✅ `charts/<release>/templates/secret.yaml` (lookup-guarded patterns for non-derived fields).
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

### Objective

Eliminate the host-side `.prodbox-state/<namespace>/.secrets.json` chart-secret cache.
Chart secrets that bind to preserved `.data/` content (Patroni roles, Keycloak admin,
gateway event keys) are materialized as k8s Secrets by an in-cluster pre-install Job
that calls `/v1/secret/ensure-namespace` on the gateway service. Non-data-bound chart
secrets use Helm `lookup` + `randAlphaNum` behind early-return guards so reconciles
preserve the existing value. The full derived-vs-generated inventory lives in
[secret_derivation_doctrine.md §6](../documents/engineering/secret_derivation_doctrine.md).

### Deliverables

- `resolveChartSecrets` (`src/Prodbox/Lib/ChartPlatform.hs:1212-1280`) rewritten to a
  single call: `Prodbox.Gateway.Client.ensureNamespace endpoint namespace release`,
  then a sanity check that the expected Secrets now exist via `kubectl get secret`.
  Removes `recoverPatroniSecretValues` and `mergeChartSecretValues` entirely.
- `shouldResetPatroniStorage` (`src/Prodbox/Lib/ChartPlatform.hs:1343`) reworked:
  the reset-marker write path is replaced by a check that compares the derived
  password (via the gateway client) against what `pg_authid` reports through a
  probe-only Postgres connection. Mismatch is a loud failure that names the
  namespace/role pair and the resolution options (restore the seed, or wipe
  `.data/<ns>/<release>/`); never a silent reset. The
  `<namespace>/.patroni-anchor-volume` marker file path is removed; Patroni anchor
  decision derives from k8s PVC state alone.
- New chart pre-install Job per supported chart (`charts/<release>/templates/
  secret-bootstrap-job.yaml`): runs a small busybox-equivalent image with a
  Haskell-built `prodbox-secret-bootstrap` binary that POSTs to
  `/v1/secret/ensure-namespace` via the in-cluster gateway ClusterIP, waits for
  completion, exits. Helm `--wait` ensures the Job completes before chart
  resources install. (Alternative: in-cluster kubectl-apply via a ServiceAccount
  with Secret-create permission, eliminating the new binary. Pick during
  implementation based on chart-platform fit.)
- Each chart's `templates/secret.yaml` updated to use `lookup`-guarded generation
  for non-data-bound fields per
  [secret_derivation_doctrine.md §6](../documents/engineering/secret_derivation_doctrine.md);
  data-bound fields are populated by the pre-install Job above and surfaced via
  `lookup`.
- 15+ new unit tests in `test/unit/Main.hs::"Sprint 3.13 chart secrets via gateway"`
  for the derived-vs-generated chart-secret split with golden manifests covering
  Keycloak, vscode, gateway, api, websocket.

### Validation

1. `prodbox check-code` exit 0; the `forbidDotProdboxState` lint (introduced by
   Sprint 4.18) fires if any new `.prodbox-state/*` write regresses.
2. `prodbox test unit` covers the new tests.
3. `prodbox test integration cli` continues to pass.
4. Live exercise of the preserved-data case on this host:
   `prodbox rke2 reconcile` → `prodbox charts deploy keycloak` → use Keycloak
   (create a realm, add a user) → `prodbox rke2 delete --cascade --yes`
   (preserves `.data/`) → `prodbox rke2 reconcile` → `prodbox charts deploy
   keycloak` → derived secrets match existing `pg_authid` → Keycloak exports the
   realm and user from before the wipe.

**Chunks 9 + 10 + 11 + 12 + 13 + 14 landed 2026-05-31** as a connected push closing the
host-side cache eradication. Every code-side `.prodbox-state/charts/<ns>/.secrets.json`
writer is gone; the chart-vs-daemon multi-writer race is closed for every
data-bound field the daemon now owns; the @.patroni-{anchor-volume,reset-required}@
markers are deleted and the Patroni anchor decision derives from live k8s state.

- **Chunk 9** — `Prodbox.UsersAdmin.loadKeycloakAdminPassword` reads the daemon-applied
  `keycloak-runtime` Secret's `KEYCLOAK_ADMIN_PASSWORD` via `kubectl get secret`
  (using `runPg` from `Prodbox.Service`). The `.prodbox-state` read-path is gone.
- **Chunk 10** — `Prodbox.Infra.AwsSesStack.persistKeycloakSmtpChartSecrets` kubectl-
  applies the `keycloak-smtp` Secret with all seven `KC_SMTP_*` fields +
  `helm.sh/resource-policy: keep`. `mergeChartSecretsFile`/`readChartSecretsFile`/
  `chartSecretsPrettyConfig` removed. Chart's `secret.yaml` no longer renders
  `keycloak-smtp` (sole-owner kubectl). `configmap.yaml`'s realm-import
  `smtpServer` block uses Helm `lookup` at template-render time.
- **Chunk 11** — extended `Prodbox.Secret.Derive` with `oidcClientSecretContext` and
  `keycloakDemoUserContext`; refactored `Prodbox.Secret.Inventory.DerivedSecretEntry`
  to carry `derivedSecretEntryDerivedFields :: [(Text, Text)]` (replaces the single
  key+context shape) so the daemon writes one `keycloak-oidc-clients` Secret with
  four derived fields atomically. `applyDerivedSecrets` derives every field and
  merges static fields into the manifest body. `configmap.yaml` realm-import +
  `charts/vscode/templates/http-route.yaml` + `charts/websocket/templates/configmap-config.yaml`
  all read the OAuth client secrets via Helm `lookup` (cross-namespace for vscode/
  websocket from the keycloak namespace).
- **Chunk 12** — `resolveChartSecrets` reduced to `pure (Right Map.empty)`.
  `requireMapValue`, `requiredChartSecretKeys`, `recoverPatroniSecretValues`,
  `mergeChartSecretValues`, `readSharedKeycloakSecretValues` deleted.
  `valuesForKeycloak`/`valuesForKeycloakPostgres`/`valuesForVscode`/`valuesForWebsocket`
  drop every `requireMapValue` call and the corresponding chart-value override; the
  charts now read all migrated fields via Helm `lookup` of daemon/kubectl-applied
  Secrets.
- **Chunk 13** — `.patroni-anchor-volume` marker file deleted (writer + reader gone).
  The two surviving anchor-read sites (`readOptionalPatroniBootstrapAnchorBinding`
  and `ensurePerconaPatroniStorageBindings`) now call
  `discoverPatroniAnchorPersistentVolumeName` directly (k8s state via Patroni
  primary endpoint). The post-install marker-write hook becomes a documented
  no-op.
- **Chunk 14** — `shouldResetPatroniStorage` deleted (sole caller was the now-gutted
  `resolveChartSecrets`). `patroniClusterStatusIndicatesFailure` +
  `patroniStorageExists` + `requiredKeysPresent` + `requiredKeyPresent` +
  `readOptionalSecretPassword` + `writePatroniResetMarker` +
  `patroniResetMarkerFileName` all removed. `resetPatroniStorageIfRequested`
  reduces to `pure (Right ())` since the marker is never written. The
  spec's prescribed loud-failure mismatch check (derive vs `pg_authid` probe)
  is deferred to the live four-block exercise where the failure paths actually
  fire — until that lands, the reset arm is a documented no-op.

Validated on all five static gates: `prodbox check-code` exit 0,
`prodbox test unit` 628/628, `prodbox test integration cli`/`env` exit 0,
`prodbox lint docs` / `docs check` exit 0; `helm template` renders cleanly for
`keycloak`, `keycloak-postgres`, `vscode`, `websocket`.

### Current Validation State

**Chunk 16 (2026-05-31 still later)** closes the host-side cache
eradication completely. The gateway per-node event-key cache
(`.prodbox-state/<ns>/.gateway-event-keys.json` via the prior
`resolveGatewayEventKeys`) is gone; the daemon's own startup loop
self-bootstraps a `gateway-event-keys` k8s Secret in the gateway
namespace right after acquiring the master seed. The chart reads it via
Helm `lookup`. With the cache gone, `chartStateRootRelative` +
`chartStateDir` + `ensureChartStateDir` + `repairChartStateDir` +
`resolveOrGenerateStringMap` + `writeGeneratedMap` + `mergeRequiredKeys` +
`writeStringMap` + `readStringMap` + `randomHexString` + `byteToHex` are
all removed.

- `Prodbox.Secret.Inventory.derivedSecretInventoryFor` adds a
  `(gateway, gateway)` entry writing `gateway-event-keys` with three
  derived fields: `NODE_A_EVENT_KEY` / `NODE_B_EVENT_KEY` /
  `NODE_C_EVENT_KEY` via the existing `gatewayEventKeyContext` (shape
  `gateway:<namespace>:<node-id>:event-key`).
- New `Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets`: called right
  after `acquireInitialMasterSeed`, it loads in-pod ServiceAccount
  credentials, constructs the TLS-backed K8s API client, and applies
  the daemon's own (gateway, gateway) inventory. All failure modes
  degrade gracefully (no seed yet → skip; outside k8s → skip with
  diagnostic; RBAC missing → log and continue). The chart's Helm
  `lookup` re-renders cleanly on the next reconcile.
- `charts/gateway/values.yaml` extends `rbac.targetNamespaces` with
  `gateway` so the daemon's ServiceAccount can write the
  `gateway-event-keys` Secret in its own namespace. This is what
  authorizes the self-bootstrap.
- `charts/gateway/templates/configmap-config.yaml` reads three
  `NODE_<X>_EVENT_KEY` fields via Helm `lookup` of `gateway-event-keys`
  and renders the per-node `event_keys` list directly. On `helm
  template` (no cluster) the lookup is empty and the chart falls back
  to an empty list — fine for golden-test determinism.
- `charts/gateway/values.yaml` drops the `eventKeys: {}` value (no
  consumer remains); `valuesForGateway`'s `gatewayEventKeys` parameter
  becomes a vestigial `Map.empty` (signature preserved for now).
- `renderRetainedStateNotice` (in `Prodbox.CLI.Rke2`) no longer claims
  to preserve a "chart state root" — nothing under `.prodbox-state/` is
  preserved by the supported lifecycle any more.

Sprint 4.18's `forbidDotProdboxState` lint **broadens** in lockstep:
the scan needle widens from the closed `.secrets.json` filename to the
whole `.prodbox-state/` prefix; one new unit test pins the broader
contract. After chunk 16 a grep for `.prodbox-state` in `src/`+`app/`
string literals returns zero hits (only comments mention it for
historical context).

Validated on all five static gates: `prodbox check-code` exit 0,
`prodbox test unit` 631/631, `prodbox test integration cli`/`env`
exit 0, `prodbox lint docs` / `docs check` exit 0; `helm template`
renders cleanly for the gateway chart with empty `event_keys` fallback.

The live four-block end-to-end verification from the approved plan
Part 3 (preserved-data + recovery-escape-hatch + original-failure-mode
+ Sprint 4.18 final-cleanup) is the full-sprint closure gate; it
remains operator-driven because it depends on a live `prodbox rke2
reconcile` + multi-cycle delete/redeploy of Keycloak.

**Chunks 17–31 (2026-06-01)** are the live-iteration "tail" — each
chunk lands one targeted fix surfaced by a live `prodbox test all`
retry on the home substrate, since pure code review missed each one.
The pattern is single-issue → diagnose with `kubectl` + daemon logs →
targeted fix → re-run, repeated until live convergence.

- **Chunk 17** — `ensureAdminPublicEdgeRoutes` regressed against the
  new master-seed flow; the host-side derivation in chunk 12 had
  pulled the rug from under it. `waitForAccessToken` and the missing
  `keycloak_vscode_client_secret` rendering paths both updated to read
  the daemon-applied Secret via cross-namespace `kubectl` rather than
  the deleted host cache.
- **Chunk 18** — chunk 17's `kubectl`-based read fails *during*
  platform setup, before the `keycloak` namespace exists. The fix:
  derive `VSCODE_CLIENT_SECRET` host-side from the master seed in
  MinIO (which is materialized by `ensureGatewayMinioBootstrap` one
  reconciler step earlier). New `readKeycloakVscodeClientSecret` uses
  `withMinioPortForward` + `ensureMasterSeed` + `deriveBase64Url` to
  compute the same value the daemon would write — deterministic over
  the same seed.
- **Chunk 19** — drop the stale "non-empty `gatewayEventKeys`"
  validation in `valuesForGateway`. After chunk 16 the chart reads
  event keys via Helm `lookup`, not via the `eventKeys:` value, so the
  validation was rejecting fresh deploys.
- **Chunk 20** — the gateway chart's RBAC templates now emit a
  `Namespace` resource for each entry in `rbac.targetNamespaces` that
  isn't the chart's own. Otherwise `helm upgrade --install gateway`
  fails when `keycloak`/`vscode` namespaces don't exist yet for the
  Role/RoleBinding to land in.
- **Chunk 21** — `derivedSecretInventoryFor` is now
  *namespace-aware* for the `keycloak-postgres` release. The Crunchy
  operator names the Patroni Secrets after the cluster, which is
  named after the root chart. `vscode` and `keycloak` both pull
  `keycloak-postgres` as a dependency, so the daemon sees the same
  release in two different namespaces and must write
  `prodbox-vscode-pg-*` / `prodbox-keycloak-pg-*` accordingly. The
  cluster-name prefix is now `"prodbox-" <> namespace <> "-pg"`.
- **Chunk 22** — the gateway daemon's ServiceAccount RBAC adds the
  `update` verb on Secrets. The K8s API rejects `PUT` without it; the
  daemon was getting `403 cannot update`.
- **Chunk 23** — the daemon's K8s API client is rewritten as
  POST-first, PUT-on-`409`-conflict. The naive PUT-only path was
  failing with `404 secrets not found` on first creation; the
  recommended K8s create-or-update idiom is the two-phase form
  above.
- **Chunk 24** — `Daemon.deriveOwnGatewayEventKeys` now derives the
  three per-node event keys *in memory* at startup, populating the
  daemon's own `eventKeys` map from the master seed instead of
  relying on Helm `lookup` to land them in the ConfigMap. This
  closes the bootstrap chicken-and-egg where the daemon's Pod
  started before its own `gateway-event-keys` Secret existed and so
  refused to forward events with `event_key_missing`.
- **Chunks 25 + 26** — `secret-bootstrap-job.yaml` (in both
  `charts/keycloak` and `charts/keycloak-postgres`) tunes the
  pre-install Job's `backoffLimit` + `curl --retry / --retry-delay /
  --max-time` so the worst-case wait fits inside helm's default
  `--timeout`. The Job calls the gateway daemon's
  `ensure-namespace` endpoint and must tolerate Service-warmup
  flaps without exceeding the helm timeout.
- **Chunk 27** — `rbac.targetNamespaces` extends with `vscode` so
  the daemon can write the namespace-aware Patroni Secrets
  (`prodbox-vscode-pg-*`) into the `vscode` namespace, not just
  `keycloak`.
- **Chunk 28** — `derivedSecretInventoryFor` is namespace-aware for
  the `keycloak` release too: vscode pulls keycloak transitively, so
  both deployments need their `keycloak-runtime` +
  `keycloak-oidc-clients` Secrets in their own namespace with
  context strings scoped to that namespace. Cross-namespace `lookup`
  in `vscode/templates/http-route.yaml` /
  `websocket/templates/configmap-config.yaml` updates to point at
  the correct lookup namespace.
- **Chunk 29** — operator-only state hygiene: a stale
  `.data/vscode/keycloak-postgres/` directory from a pre-chunk-21
  test run carried a different PostgreSQL system ID, so the third
  Patroni replica refused to start with `system ID mismatch`.
  Wiped the directory; future runs re-initdb cleanly with one
  shared system ID. No code change.
- **Chunk 30** — delete the obsolete
  `"restores retained Patroni state through a staged bootstrap"`
  integration test. The "staged bootstrap" code path it exercised
  (`.patroni-anchor-volume` + two-pass helm upgrade) was removed by
  chunks 13–14; the test was failing on the new always-emit-three-
  PVs path.
- **Chunk 31** — `PRODBOX_TEST_HOST_MASTER_SEED_HEX` test-only
  injection seam in `readKeycloakVscodeClientSecret` (mirroring the
  existing `PRODBOX_TEST_RESIDUE_*` pattern in
  `Prodbox.Lifecycle.LiveResidue`). The integration test harness's
  `fakeRke2Environment` can't run a real MinIO; the env var
  short-circuits the port-forward with a deterministic constant
  seed so the three reconcile tests (`rke2 reconcile and delete`,
  `falls back to mirror.gcr`, `projects ZeroSSL`) exercise the new
  chunk-18 code path without infrastructure. Production never sets
  the env var.
- **Chunk 32** — namespace-aware host-side Secret reads. Three
  host-side readers (`readKeycloakOidcClientField` in
  `Prodbox.TestValidation`, `loadKeycloakAdminPassword` in
  `Prodbox.UsersAdmin`, and the `oidcClientSecretContext` call in
  `Prodbox.CLI.Rke2.readKeycloakVscodeClientSecret`) were still
  hardcoded to namespace `keycloak`. With chunk 28 making the
  daemon's Inventory deploy-namespace-aware and `prodbox test all`
  deploying via the `vscode` root chart (which transitively pulls
  keycloak into the `vscode` namespace), the reads were missing the
  Secret entirely. Switched all three to `vscode`. The host-side
  derivation context now agrees with what the daemon writes
  byte-for-byte; otherwise the harbor/minio admin SecurityPolicy
  OIDC handshake would never accept any token.
- **Chunk 33** — host-side pre-helm Secret materialization
  (`Prodbox.Secret.HostBootstrap.preApplyDerivedSecretsForRelease`)
  closes the Helm `lookup` timing hole. Helm renders **all**
  templates (including `lookup`) BEFORE applying pre-install
  hooks; on first install the daemon's pre-install Job hadn't
  run yet, so `lookup` of `keycloak-oidc-clients` returned empty
  and the chart fell back to its `"change-me"` placeholder.
  Keycloak imports the realm with that placeholder once and
  never re-imports — direct-grant OIDC handshakes 401 forever.
  The fix: `deployRelease` (and `deployPatroniRelease`) now read
  the master seed host-side (reusing the chunk 18 path: MinIO
  port-forward + `ensureMasterSeed` + the chunk-31
  `PRODBOX_TEST_HOST_MASTER_SEED_HEX` test seam) and
  `kubectl apply` every inventory entry BEFORE
  `helmUpgradeInstall`, so the realm-import ConfigMap renders
  with the real master-seed-derived client secrets on first
  install. The chart's pre-install Job remains the in-cluster
  idempotent fallback. Reuses `secretManifestJson` +
  `deriveBase64Url` so host and daemon write identical bytes.

Validated on all five static gates after chunk 33: `prodbox
check-code` exit 0, `prodbox test integration cli` 29/29 PASS,
`prodbox test integration env` 3/3 PASS, fourmolu + hlint +
warning-clean build all green.

**Live closure (2026-06-01):** `prodbox test all` retry 21 closes
**16 of 17 validations** on the home substrate after quay.io
stabilized: `charts-vscode`, `charts-api`, `charts-websocket`,
`admin-routes`, `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`,
`pulumi`, `ha-rke2-aws`, `gateway-daemon`, `gateway-pods`,
`gateway-partition`, `charts-platform`, `charts-storage`, and
`lifecycle` — every OIDC handshake, chart deploy, public-edge
probe, and a full `rke2 delete --cascade` + RKE2 reinstall +
helm-from-scratch cycle pass. Only `keycloak-invite` fails, and
the dev plan explicitly carves that one out to Sprint 8.5 (the
credential-setup form parser + invite flow is 8.5's owned
surface). Sprint 3.13's four-block preserved-data exercise is
closed end-to-end: the doctrine of deterministic master-seed-
derived passwords flowing through k8s Secrets to chart consumers
(via Helm `lookup` + the chunk-33 host-side pre-apply) is
validated against a real Keycloak realm import, a real OIDC
handshake, and a real cluster-wipe-and-rebuild cycle.

### Remaining Work

None. The only failing validation in the closure run was `keycloak-invite`, which is
owned by Sprint `8.5`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface,
  restricted to root charts.
- `documents/engineering/config_doctrine.md` - workload-binary config-as-data: the public
  workload (`api` / `websocket`) reads its full configuration from the mounted Dhall config as
  the sole source (no `PRODBOX_*` fallback ladder), with the Boot/Live split and
  `fsnotify`-driven reload symmetry the daemon already follows (Sprint `3.15`).
- `documents/engineering/secret_derivation_doctrine.md` - the daemon-only master-seed boundary:
  the raw master seed is read in-cluster only, the host obtains *derived* values via the gateway
  RPC (`Prodbox.Gateway.Client`), and no host-side `/tmp` seed file or `resolveSeedViaMinio`
  raw-seed read remains on the supported path (Sprint `3.16`).
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Keycloak edge
  doctrine for chart-managed workloads.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, internal dependency-release boundary, the authoritative synchronous-replication
  Patroni doctrine, and the land-or-delete loud-failure Patroni-storage-mismatch contract
  (Sprint `3.16`).
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/vault_doctrine.md` - Vault as the sole secrets/KMS/PKI root on a durable
  `.data/vault/vault/0` PV (init-once/unseal-on-rebuild, both substrates), the `prodbox-envelope-v1`
  Vault-Transit envelopes wrapping every prodbox-owned MinIO object, the
  chart/Keycloak-secret-via-Vault-Kubernetes-auth model, and the per-cluster Vault seal model;
  scheduled under Sprints `3.17`–`3.20`. The master-seed HMAC-SHA-256 derivation model is retired,
  not extended (Sprint `3.19`).
- `documents/engineering/cluster_federation_doctrine.md` - the root/child transit-seal trust tree and
  per-cluster seal custody (Sprint `3.20`).
- `documents/engineering/pulsar_messaging_doctrine.md` - the Pulsar platform chart plus the
  self-maintained native-protocol Haskell Pulsar client whose payload codec is canonical-CBOR-only,
  with the derived topic algebra (`topicFor`) and the `Work*` envelope family (Sprint `3.21`).
- `documents/engineering/config_doctrine.md` - chart/Keycloak secrets from Vault KV via Vault
  Kubernetes auth, with no Secret-mounted plaintext Dhall fragment (Sprints `3.18`–`3.19`).
- `documents/engineering/local_registry_pipeline.md` - Harbor-loading implications for the chart
  platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the browser, API, WebSocket, and admin public workload
  paths.

## Sprint 3.14: Workload Mode via Dhall (Replaces `PRODBOX_WORKLOAD_MODE` Env Var) ✅

**Status**: Done (May 24, 2026 — code-owned surface landed: new
`src/Prodbox/Workload/Settings.hs` module with `loadWorkloadConfig ::
FilePath -> IO (Either String WorkloadConfigDhall)` decoder, schema covers
`mode : < Api | Websocket >` plus optional `log_level` / `workload_port` /
`redis` / `oidc` sub-records; `workloadConfigPath :: Maybe FilePath` added
to `WorkloadOptions`; new `--config` flag in `workloadOptionsParser`;
`runWorkloadServer` now dispatches through `resolveWorkloadModeFromConfig`
which prefers the Dhall config when `--config` is passed and falls back to
the legacy `PRODBOX_WORKLOAD_MODE` env-var ladder otherwise; new
`charts/api/templates/configmap-config.yaml` and
`charts/websocket/templates/configmap-config.yaml` render Dhall content;
`charts/api/templates/deployment.yaml` and
`charts/websocket/templates/deployment.yaml` updated with `args: ["workload",
"start", "--config", "/etc/workload/config.dhall"]` + matching ConfigMap
volume mount; `PRODBOX_*` env vars retained for rollback safety. 3 new unit
tests (543/543 total): happy-path Api and Websocket Dhall decode plus
schemaVersion mismatch failure. `helm template` renders cleanly for both
charts. **May 24, 2026 later session — full Dhall read-through landed**:
`runWorkloadServer` now loads the Dhall config once via
`resolveWorkloadDhallConfig` and threads the resulting
`Maybe WorkloadConfigDhall` through every resolver. New helpers
`resolveWorkloadModeFromDhall`, `resolveHttpPortWithDhall`,
`resolveWorkloadLogLevelWithDhall`, and the refactored
`resolveWebsocketRuntime`/`resolveRedisConfig`/`resolveOidcConfig` use the
Dhall sub-records when `--config` is set and fall back to env vars
otherwise. `PRODBOX_WORKLOAD_MODE` / `PRODBOX_HTTP_PORT` /
`PRODBOX_REDIS_HOST` / `PRODBOX_REDIS_PORT` / `PRODBOX_OIDC_*` env vars
are removed from `charts/api/templates/deployment.yaml` and
`charts/websocket/templates/deployment.yaml`; the Dhall ConfigMap is the
sole source on the chart-side surface. Validation: `prodbox check-code`
exit 0; `prodbox test unit` 543/543; `prodbox test integration cli` 28/28;
`prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14.
**Live closure 2026-06-01:** `prodbox test all` retry 21 deployed the
api and websocket workloads via the new Dhall-ConfigMap path and
passed `charts-api` (api workload Pod up, reachable via OIDC-gated
`/api`) and `charts-websocket` (websocket workload Pod up, reachable
via OIDC-gated `/ws`). The chart-side `--config /etc/workload/config.dhall`
mount + the `Prodbox.Workload.Settings.loadWorkloadConfig` reader work
end-to-end against real Keycloak OIDC, validating the full Dhall
read-through path. Sprint 3.14 closure gate met.)
**Blocked by**: Sprint 0.8 ([config_doctrine.md](../documents/engineering/config_doctrine.md)) — resolved
**Implementation**: `src/Prodbox/Workload.hs` (replace env-var read with Dhall config
field), `charts/api/templates/deployments.yaml` and `charts/websocket/templates/deployments.yaml`
(remove `PRODBOX_WORKLOAD_MODE` env var, add `--config <path>` arg pointing at a mounted
workload Dhall ConfigMap), new `charts/api/templates/configmap-config.yaml` and
`charts/websocket/templates/configmap-config.yaml`, new workload Dhall schema in
`prodbox-config-types.dhall` (or a sibling `prodbox-workload-types.dhall`)
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Migrate the public-workload entry-point (`api`, `websocket`) from
`PRODBOX_WORKLOAD_MODE=api|websocket` env-var selection to a `workload.mode` field of
the workload Pod's mounted Dhall config, per
[config_doctrine.md](../documents/engineering/config_doctrine.md). The workload Pod
binary reads its full configuration from `--config /etc/workload/config.dhall`, decoded
via `Dhall.inputFile auto`.

### Deliverables

- Replace `lookupEnv "PRODBOX_WORKLOAD_MODE"` in `src/Prodbox/Workload.hs` with a Dhall
  decoder for the workload config record. The workload-mode field is a sum type
  `Api | Websocket` in the Dhall schema.
- New `charts/api/templates/configmap-config.yaml` and
  `charts/websocket/templates/configmap-config.yaml` rendering the per-workload Dhall
  expression at `/etc/workload/config.dhall`.
- Remove the `PRODBOX_WORKLOAD_MODE` env var from the api and websocket chart
  Deployments; replace with `args: [--config, /etc/workload/config.dhall]` and the
  matching ConfigMap volume mount.
- New workload Dhall schema (either extending `prodbox-config-types.dhall` or in a
  sibling file) covering the workload `mode`, OIDC bootstrap config, and Redis
  endpoint.

### Validation

1. `prodbox check-code` exit 0 (the `forbidEnvVarConfigReads` lint added by Sprint 1.28
   now fires on regressions).
2. `helm template api charts/api` and `helm template websocket charts/websocket` render
   cleanly.
3. `prodbox lint chart` exit 0.
4. Live exercise: `prodbox charts deploy api` and `prodbox charts deploy websocket`
   bring up the respective workloads against the new Dhall surface; both serve their
   public-edge routes.

### Remaining Work

None. The 2026-06-01 live `prodbox test all` retry 21 deployed `api` and `websocket`
through the mounted Dhall config path and passed both public-edge validations. The
workload-only Dhall schema remains inline in
`src/Prodbox/Workload/Settings.hs::WorkloadConfigDhall`; promoting it to a sibling
`prodbox-workload-types.dhall` remains optional follow-up work, not a closure blocker.

## Sprint 3.15: Workload Config-as-Data (Delete the `PRODBOX_*` Ladder, Boot/Live + fsnotify Symmetry) ✅

**Status**: Done (2026-06-09). The entire `PRODBOX_*` env ladder was deleted from `Workload.hs`
(`--config` is now mandatory — a missing/unparseable file is a fast structured failure; the sole
legitimate runtime-metadata read, the `HOSTNAME` pod name, moved to a new `Workload/PodIdentity.hs`
so `Workload.hs` has zero `lookupEnv`). The workload gained the daemon's Boot/Live split
(`WorkloadBootConfig`/`WorkloadLiveConfig` + pure `workloadBootFieldsChanged`; Live fields apply
in-process via a `TVar`, Boot fields drain-and-exit) and an `fsnotify` `configFileWatchLoop` on the
`--config` parent directory. `src/Prodbox/Workload.hs` joined `checkEnvVarConfigReads.scopedPaths`
(proven to fire on a reintroduced read). The api/websocket charts switched to a directory mount, the
legacy-ladder comments were removed, and the Sprint 3.14 workload `PRODBOX_*` ledger row moved to
Completed. Validation green: `check-code` 0, `test unit` 769/769, `integration cli` 35/35,
`prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check` 0, and `helm template api|websocket`
render with zero `PRODBOX_*` env vars. The live in-cluster reload exercise is operator-driven.
**Implementation**: `src/Prodbox/Workload.hs`, `src/Prodbox/Workload/Settings.hs`, `src/Prodbox/CheckCode.hs`, `charts/api/templates/configmap-config.yaml`, `charts/websocket/templates/configmap-config.yaml`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Finish the [config_doctrine.md](../documents/engineering/config_doctrine.md) migration on the
public-workload binary. Sprint `3.14` moved `api` / `websocket` mode and config to a mounted
Dhall ConfigMap but left the entire `PRODBOX_*` env-var fallback ladder in
`src/Prodbox/Workload.hs` "for rollback safety", so the workload remains a second supported
config source. This sprint makes the Dhall config the *sole* workload config source, gives the
workload the same Boot/Live split and `fsnotify`-driven reload the gateway daemon already runs
(Sprint `2.21`), and lint-enforces that the supported workload path cannot regress to env-var
config — closing the gap [config_doctrine.md §7](../documents/engineering/config_doctrine.md)
requires for every long-running `prodbox` binary.

### Deliverables

- Delete the `PRODBOX_WORKLOAD_MODE` / `PRODBOX_PORT` / `PRODBOX_HTTP_PORT` /
  `PRODBOX_LOG_LEVEL` / `PRODBOX_REDIS_*` / `PRODBOX_OIDC_*` `lookupEnv` ladder from
  `src/Prodbox/Workload.hs` (the `resolveWorkloadModeFromDhall`, `resolveHttpPortWithDhall`,
  `resolveWorkloadLogLevelWithDhall`, `resolveRedisConfig`, and `resolveOidcConfig` env-var
  fallback arms). The mounted Dhall config decoded via `Dhall.inputFile auto` from
  `--config /etc/workload/config.dhall` is the only config source; a missing `--config` is a
  fast structured failure, not a silent env-var fallback.
- Give the workload the daemon's Boot/Live config split: fields that can change in place
  (`log_level`, OIDC/Redis tunables that do not require a socket rebind) are Live and applied
  in-process on reload; fields that require a restart (the `mode` sum, the listen port) are
  Boot and trigger drain-and-exit per [config_doctrine.md §8](../documents/engineering/config_doctrine.md),
  mirroring `Prodbox.Gateway` `daemonBootFieldsChanged` / `reloadLiveConfig`.
- Add an `fsnotify`-driven `configFileWatchLoop`-equivalent in the workload runtime that
  watches the `--config` parent directory (directory mount, not `subPath`, so the kubelet
  atomic `..data` symlink swap fires the watch — the same gotcha Sprint `2.21` chunk 47 hit).
- Add `src/Prodbox/Workload.hs` to `checkEnvVarConfigReads.scopedPaths` in
  `src/Prodbox/CheckCode.hs` so `prodbox check-code` fails closed on any reintroduced
  `PRODBOX_*` config read on the workload surface (joining `Settings.hs`,
  `Gateway/Settings.hs`, and `Gateway.hs`).
- Remove the legacy-ladder note from the Sprint `3.14` `Workload/Settings.hs` header comment
  and from the api/websocket chart Deployments (no rollback-safety `PRODBOX_*` env vars
  remain).

### Validation

1. `prodbox check-code` exit 0 with `src/Prodbox/Workload.hs` newly in
   `checkEnvVarConfigReads.scopedPaths`; reintroducing any `PRODBOX_*` config read on the
   workload surface fails the lint.
2. `prodbox test unit` covers the Boot/Live field classification and the
   missing-`--config`-is-a-hard-failure path.
3. `helm template api charts/api` and `helm template websocket charts/websocket` render
   cleanly with no `PRODBOX_*` config env vars on the Deployments.
4. Live exercise: a `log_level` edit to a deployed workload's mounted ConfigMap reloads
   in-process with no Pod restart; a `mode`/port edit drains and exits for kubelet restart.

### Remaining Work

None — closed 2026-06-09. The only outstanding item is the operator-driven live in-cluster reload
exercise (a `log_level` ConfigMap edit reloads in-process; a `mode`/port edit drains+exits).

## Sprint 3.16: Daemon-Only Master-Seed Boundary ✅

**Status**: Done (2026-06-09). The host no longer reads the raw seed:
`HostBootstrap.preApplyDerivedSecretsForRelease` and `Rke2.readKeycloakVscodeClientSecret` now call
`Gateway.Client.ensureNamespace`/`derive` over the loopback NodePort (`hostLoopbackGatewayEndpoint`),
so the in-cluster daemon materializes the data-bound Secrets and the host sees only derived values /
the SHA-256 inventory. `resolveSeedViaMinio`, the `readHostMasterSeedHexOverride` /
`PRODBOX_TEST_HOST_MASTER_SEED_HEX` seam, and the fixed `/tmp/prodbox-master-seed*.bin` paths are
deleted (seed get/put now transit a randomized, single-use, bracket-deleted temp file in
`MasterSeed.hs`, in-cluster only); a new gateway-client-boundary test seam
(`PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX`, `Prodbox.TestSeam.GatewayDerive`) injects a *derived* value
without re-exporting the seed. The new `checkRawMasterSeedReadScope` lint (in
`runDoctrineAlignmentCheck`, proven to fire) confines the raw-seed read to
`{Gateway/Daemon.hs, Secret/EnsureNamespace.hs, Secret/MasterSeed.hs}`. `MinioMasterSeedConfig` got a
redacting `Show`. `resetPatroniStorageIfRequested` was **landed** (not deleted) as the
doctrine-prescribed loud-failure guard — pure `patroniSeedMismatchDecision` (auth-rejected → loud
failure naming namespace/role; matches/unobservable → proceed, never a silent reset) + a probe-only
`psql` auth check (`PGPASSWORD` in exec env, never argv). `secret_derivation_doctrine.md §8` flipped to
Implemented; ledger rows moved to Completed. Validation green: `check-code` 0, `test unit` 775/775,
`integration cli` 35/35, `lint docs` 0, `docs check` 0. The live first-install secret-materialization
and Patroni mismatch-probe exercises are operator-driven.
**Implementation**: `src/Prodbox/Secret/MasterSeed.hs`, `src/Prodbox/Secret/HostBootstrap.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Make the raw master seed an in-cluster-only secret. Sprint `3.13`'s live-iteration tail (chunks
18 / 31 / 33) added host-side master-seed reads — `resolveSeedViaMinio`, the
`PRODBOX_TEST_HOST_MASTER_SEED_HEX` seam, and `/tmp/prodbox-master-seed*.bin` scratch files —
to close Helm `lookup` timing holes on first install. Those host paths re-export the raw seed
outside the cluster, contradicting [secret_derivation_doctrine.md §5](../documents/engineering/secret_derivation_doctrine.md)'s
host↔cluster boundary (the host should consume *derived* values via the gateway RPC, never the
raw seed). This sprint moves all host-side chart-secret materialization onto
`Prodbox.Gateway.Client.derive` / `ensureNamespace`, confines the raw-seed read to in-cluster
code, lint-enforces that confinement, and lands-or-deletes the no-op
`resetPatroniStorageIfRequested` arm Sprint `3.13` chunk 14 deferred.

### Deliverables

- Replace the host-side raw-seed paths (`src/Prodbox/Secret/HostBootstrap.hs::resolveSeedViaMinio`
  and `preApplyDerivedSecretsForRelease`'s direct derivation) with calls to
  `Prodbox.Gateway.Client.derive` / `ensureNamespace` so the host obtains the *derived* Secret
  values (or triggers in-cluster materialization) without ever reading the raw seed. The
  `Prodbox.CLI.Rke2.readKeycloakVscodeClientSecret` host path migrates to the same RPC.
- Confine the raw-seed read in `src/Prodbox/Secret/MasterSeed.hs` to in-cluster daemon code and
  delete the `/tmp/prodbox-master-seed.bin` / `/tmp/prodbox-master-seed-put.bin` scratch-file
  round-trip (the seed never lands on a host filesystem path). Replace the
  `PRODBOX_TEST_HOST_MASTER_SEED_HEX` host-side test seam with a derived-value test seam at the
  gateway-client boundary so the integration harness still exercises the chunk-18/33 code path
  without re-exporting the raw seed.
- Add a `prodbox check-code` lint (`checkRawMasterSeedReadScope` or equivalent) that forbids the
  raw-seed read outside the in-cluster daemon module set (`src/Prodbox/Gateway/Daemon.hs`,
  `src/Prodbox/Secret/EnsureNamespace.hs`), the same lint shape `checkEnvVarConfigReads` uses.
- Add a redacting `Show` instance to `MinioMasterSeedConfig` in
  `src/Prodbox/Secret/MasterSeed.hs` so the master-seed config never prints credentials in
  logs or error output.
- Land-or-delete the deferred `resetPatroniStorageIfRequested` arm
  (`src/Prodbox/Lib/ChartPlatform.hs:2430`, currently `pure (Right ())`): either implement the
  Sprint `3.13`-prescribed loud-failure mismatch check (derive the expected Patroni password
  via `Prodbox.Gateway.Client.derive`, compare against `pg_authid` through a probe-only
  Postgres connection, fail loudly naming the namespace/role pair and the resolution options),
  or delete the no-op function and its lone call site if the live four-block exercise proves the
  check is unnecessary.

### Validation

1. `prodbox check-code` exit 0 with the new raw-seed-scope lint; reintroducing a raw-seed read
   outside the in-cluster daemon module set fails the lint.
2. `prodbox test unit` covers the redacting `Show` on `MinioMasterSeedConfig` (no credential
   substring in the rendered output) and the gateway-client-derived host path.
3. A `grep` for `/tmp/prodbox-master-seed` and `resolveSeedViaMinio` in `src/` + `app/`
   returns zero supported-path hits.
4. Live exercise: first-install `prodbox charts deploy keycloak` / `... vscode` still renders
   the realm-import with the correct master-seed-derived OIDC client secrets (the chunk-33
   timing hole stays closed) while the host obtains them via the gateway RPC, not the raw seed.

### Remaining Work

None — closed 2026-06-09. Remaining items are operator-driven live exercises (first-install
`charts deploy keycloak|vscode` secret materialization via the gateway RPC, and the live Patroni
seed/`pg_authid` mismatch probe) — they require a running cluster.

## Sprint 3.17: In-Cluster Vault Platform Component and Vault-Transit Envelopes ✅

**Status**: Done (code-owned platform/envelope foundation; live lifecycle integration continues in
Sprints `4.29`/`4.31`, Model-B object-store integration in Sprint `4.30`, chart Vault-auth
consumption in Sprint `3.18`, and transit-seal custody in Sprint `3.20`)
**Implementation**: `charts/vault/`, `src/Prodbox/Crypto/Envelope.hs`,
`src/Prodbox/Vault/TransitCipher.hs`, `src/Prodbox/ContainerImage.hs`,
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

**Current state (2026-06-11)**: one rung of the seed-residency-hardening deliverable has **landed
and validated** ahead of the rest of the sprint — the master-seed scratch file is now backed by a
RAM-only `emptyDir{medium: Memory}` tmpfs mount (`/run/prodbox-seed`) rather than a disk-backed
path (`charts/gateway/templates/deployments.yaml` adds the volume + mount;
`src/Prodbox/Secret/MasterSeed.hs` adds `seedScratchTmpfsDir` / `resolveSeedScratchDir` with a
`/tmp` fallback). Gates green: `dev check` 0, `dev lint chart` 0. This rung is valid even pre-Vault, since the seed
is plaintext today.

The **Vault-Transit envelope library** has also landed and validated (2026-06-12):
`Prodbox.Crypto.Envelope` seals each secret-bearing object under a fresh random DEK (a local
ChaCha20-Poly1305 AEAD with the object identity bound as AAD) and wraps the DEK behind a pluggable
`DekCipher` — Vault Transit in production, a loudly-named `insecureLocalDekCipher` for tests —
producing the self-describing `prodbox-envelope-v1` JSON document. Four unit tests cover the
AAD-bound round-trip, fail-closed-on-wrong-AAD, tamper rejection, and the no-plaintext-leak
property. Gates green: `dev check` 0, `test unit` **862/862**.

The in-cluster Vault **platform-component chart** also landed as a structurally-validated artifact:
`charts/vault/` deploys a single-replica Vault StatefulSet (file storage on a durable PVC over the
retained `manual` StorageClass under `.data/vault/vault/0`), a ConfigMap with the Vault HCL config, an
in-cluster ClusterIP Service, and a host-CLI NodePort (loopback-restricted, mirroring the gateway
pattern). It passes `dev lint chart` 0, renders cleanly under `helm template`, and `dev check` 0.

Vault is now a **declared shared platform component**: `ContainerImage.ComponentVault` joined the
`sharedPlatformComponents` enum + label, both installers' coverage lists
(`homeSubstratePlatformComponents` / `awsSubstratePlatformComponents`) include it, the 14-component
inventory test is updated, and `Prodbox.CLI.Rke2.ensureVaultRuntime` is the real
`helm upgrade --install charts/vault -n vault --create-namespace` install helper. Gates green:
`dev check` 0, `test unit` **869/869** (including the platform-component coverage test).

The AWS-substrate platform runtime now also calls the same Vault chart helper through
`Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstrateVaultRuntime`, sequenced after the AWS
LoadBalancer/Envoy/cert-manager/ACME layer and before the storage/registry bootstrap. Unit coverage
pins the canonical 17-step AWS platform sequence and asserts Vault precedes MinIO/Harbor bootstrap,
so `ComponentVault` is not only declared but actually installed by both substrate reconcilers.

**LIVE-VALIDATED 2026-06-12.** `prodbox cluster reconcile` stood up RKE2 (`v1.35.5+rke2r2`, node
`bathurst` Ready) + the platform (Harbor/MinIO/Envoy/cert-manager/Percona); `charts/vault/` then
deployed cleanly (`helm upgrade --install vault ./charts/vault -n vault`) — Vault `1.18.3` came up
**Running 1/1** with its durable PVC `data-vault-0` **Bound** to a retained `manual`-class PV under
`.data/vault/vault/0`. The full lifecycle was proven end-to-end: a fresh `prodbox vault status` reported
`initialized=False, sealed=True`; after init + unseal the deployed Vault reported `sealed:false`,
and `prodbox vault status` correctly tracked the change to `initialized=True, sealed=False`. So the
**`Prodbox.Vault.Client` HTTP path and the `prodbox vault` command group work against a real
deployed Vault** (Sprint `1.36`), and **the `charts/vault/` platform-component chart deploys a
working durable-PV Vault** (Sprint `3.17`).

The production Vault-Transit-backed `DekCipher` (`Prodbox.Vault.TransitCipher`) also landed with
the Phase 1 Sprint `1.37` foundation and is available to every envelope caller. Sprint `3.17`
therefore closes on the platform/envelope foundation. The in-cluster Vault Kubernetes-auth
consumption of chart/Keycloak secrets is Sprint `3.18`; retiring the master-seed derivation modules
so Vault KV is the sole secret store is Sprint `3.19`; the transit-seal hierarchy that gives each
cluster its seal custody is Sprint `3.20`; lifecycle-integrated init-once/unseal-on-rebuild and
retained-PV reconcile semantics remain owned by Sprints `4.29`/`4.31`; and the Model-B opaque
object-store is Sprint `4.30`.

### Objective

Stand up Vault as the durable-PV secrets/KMS/PKI root on **both substrates** (home + AWS,
identically) and provide the Vault-Transit envelope foundation (`prodbox-envelope-v1` plus the
production Vault-Transit `DekCipher`) that later config, chart, object-store, and Pulumi paths bind
to. Lifecycle-driven init-once/unseal-on-rebuild, Model-B opaque object-store naming, and
chart/Keycloak Vault-auth reads are downstream sprints; this sprint makes Vault a real shared
platform component and proves the envelope layer fails closed.

### Deliverables

- Vault added to the shared `[PlatformComponent]` inventory so the home and AWS substrate installers
  both stand up an in-cluster Vault — identically — on a durable `.data/vault/vault/0` PV
  (`manual` StorageClass, `Retain`, single-node affinity), preserved across `cluster delete` exactly
  like MinIO's PV (substrate equivalence; vault_doctrine §A2 init-once/unseal-on-rebuild).
- `Prodbox.Crypto.Envelope` provides the AEAD + DEK-wrap format and fails closed on wrong AAD,
  tamper, or unwrap failure.
- `Prodbox.Vault.TransitCipher` binds the envelope `DekCipher` to Vault Transit encrypt/decrypt,
  so production callers can wrap and unwrap DEKs through Vault rather than the test-only local
  cipher.
- `ensureVaultRuntime` is sequenced into home `cluster reconcile`, and
  `ensureAwsSubstrateVaultRuntime` is sequenced into the AWS substrate platform runtime so
  `ComponentVault` coverage reflects a real install on both substrates.

### Validation

- Unit coverage proves the envelope round-trip, wrong-AAD refusal, tamper refusal, and no plaintext
  leak property using `insecureLocalDekCipher`.
- Unit coverage proves the Vault-Transit `DekCipher` wraps and unwraps via injected
  Vault-shaped functions.
- Unit coverage pins both substrate component inventories and the AWS platform step sequence so
  Vault cannot be declared without being installed.
- Chart lint and Helm rendering validate `charts/vault/` structurally; the 2026-06-12 live run
  proved the chart against a home cluster. The AWS live proof is owned by the AWS-substrate
  aggregate when the platform runtime runs against EKS.

### Remaining Work

None for Sprint `3.17`. Chart/Keycloak secret consumption via Vault auth lands in Sprint `3.18`;
the master-seed derivation model is retired in Sprint `3.19`; the transit-seal hierarchy lands in
Sprint `3.20`; lifecycle-owned init-once/unseal-on-rebuild is Sprint `4.29`; retained Vault PV
reconcile is Sprint `4.31`; and Model-B opaque object-store integration is Sprint `4.30`.

## Sprint 3.18: Chart and Keycloak Secrets via Vault Kubernetes Auth ✅

**Status**: Done
**Implementation**: `src/Prodbox/Secret/VaultInventory.hs`, `src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/Vault/Host.hs`, `src/Prodbox/Settings/SecretRef.hs`, `src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/UsersAdmin.hs`, `src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/TestValidation.hs`, `charts/keycloak/`, `charts/keycloak-postgres/`, `charts/vscode/`, `charts/api/`, `charts/websocket/`, `charts/minio/`, `charts/gateway/`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Have **every** in-cluster chart workload — including Keycloak — consume **all** of its secrets from
Vault KV via Vault Kubernetes auth. Vault KV is the sole secret store for the chart platform; there
is no Secret-mounted plaintext Dhall fragment, no `as Text` credential import, and no plaintext
fallback (vault_doctrine §12; config_doctrine §A6). The `SecretRef.FileSecret` constructor and its
`/etc/.../secrets/*.dhall` mount contract are **removed, not bridged**.

### Deliverables

- Each chart that needs a Vault-held secret has a Kubernetes service account, a namespace+SA-bound
  Vault role, and a least-privilege Vault policy.
- Keycloak admin bootstrap, database credentials, client secrets, and SMTP material — and every
  other chart/workload secret — resolve from Vault KV via Vault auth (Vault Agent Injector, CSI
  Secret Store Vault provider, or app-side auth). There is no second store.
- The `SecretRef.FileSecret` constructor and its resolver arm are deleted from
  `Prodbox.Settings.SecretRef`; the secret-mounted plaintext Dhall fragment contract is removed from
  every chart and from the gateway daemon. In-cluster consumers authenticate to Vault directly.
- The secret inventory in `secret_derivation_doctrine.md` maps each chart/Keycloak secret to its
  Vault KV path, owning Vault policy, and consuming service account (no derivation class survives).

### Current Validation State

- 2026-06-15 foundation landed: `Prodbox.Secret.VaultInventory` is the typed chart-secret
  inventory for Vault KV paths, Vault policies, bound service accounts, and Kubernetes-auth roles.
  `defaultVaultReconcilePlan` now writes those chart-secret policies and roles, configures
  `auth/kubernetes/config` against `https://kubernetes.default.svc:443`, and bootstraps the
  automatically managed generated/static Vault KV objects in `prodbox vault reconcile` using a
  32-byte random, base64url-unpadded generator. The inventory still carries externally-owned
  objects such as SMTP material, but those are deliberately excluded from automatic seeding and fail
  if a caller asks the bootstrap runner to synthesize them.
- The `api`, `keycloak`, `minio`, `vault`, `vscode`, and `websocket` charts now render explicit
  ServiceAccounts and bind their workload Pods to those accounts. The Vault chart binds its service
  account to Kubernetes `system:auth-delegator` so the in-cluster Vault server can use its local
  service-account token for TokenReview. Patroni role delivery now uses a dedicated
  `prodbox-<namespace>-pg` pre-install/pre-upgrade materializer ServiceAccount instead of pretending
  the pinned PerconaPGCluster v2.9.0 CRD exposes a generated-Pod `serviceAccountName` field.
- The `websocket` workload now consumes its OIDC client secret directly from Vault KV by app-side
  Kubernetes auth: `charts/websocket/templates/configmap-config.yaml` renders
  `oidc.client_secret = SecretRef.Vault { mount = "secret", path =
  "vscode/oidc/prodbox-websocket", field = "client_secret" }`, the chart supplies the
  `websocket-oidc` Vault role and in-cluster Vault address, and `Prodbox.Workload` logs in through
  `vaultKubernetesLogin` before resolving the SecretRef. The default workload resolver runs in
  production mode, so `SecretRef.TestPlaintext` is rejected unless a unit test injects the
  test-harness resolver.
- The `keycloak` chart no longer renders `keycloak-runtime`, `keycloak-oidc-clients`, or SMTP
  lookup fallbacks. Its Deployment logs in to Vault from a `vault-secrets` init container, writes a
  tmpfs env file for `KEYCLOAK_ADMIN_PASSWORD`, `KC_DB_PASSWORD`, OIDC client secrets, demo-user
  password, and SMTP fields, and starts Keycloak only after sourcing that file. The realm import
  uses Keycloak environment placeholders instead of Helm materialized secret values.
- The `minio` chart no longer renders a root-credential Secret. Its StatefulSet logs in to Vault
  from a `vault-secrets` init container, writes tmpfs `rootUser` and `rootPassword` files, and the
  MinIO container reads them through `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE`.
- The MinIO admin bootstrap Jobs rendered by `src/Prodbox/CLI/Rke2.hs` no longer read the removed
  `minio` root Secret. The gateway MinIO bootstrap Job and Harbor storage-backend bootstrap Job
  run as the `minio` service account, use a Vault-login init container to materialize root
  credential files on tmpfs, and then run `mc` from those files. Harbor storage now has its own
  generated/persisted MinIO user in the Harbor storage Secret; the Job creates or updates that user
  and policy with root credentials that never leave the Pod.
- The `vscode` chart no longer renders an Envoy `SecurityPolicy` client Secret from
  `.Values.oidc.clientSecret`, `keycloak-oidc-clients`, or Helm `lookup`. The SecurityPolicy still
  references the Kubernetes Secret Envoy Gateway requires, but that Secret is created or patched by
  the chart's `post-install,post-upgrade` Job after the Job logs into Vault as the dedicated
  `vscode-oidc-secret-materializer` ServiceAccount and reads `secret/vscode/oidc/vscode` field
  `client_secret`. The VS Code NetworkPolicy now allows the selected materializer pod to reach the
  Vault service on port `8200`.
- The `gateway` chart no longer renders `gateway-aws-credentials`, mounts
  `gateway-minio-creds`, or performs a Helm `lookup` for `gateway-event-keys`. Its per-node
  `config.dhall` renders event keys, Route 53 AWS credentials, and gateway MinIO credentials as
  `SecretRef.Vault` values under `secret/gateway/gateway/{node-*/event-key,aws,minio}`, and
  `Prodbox.Gateway.Settings.loadDaemonConfig` resolves those references through Vault Kubernetes
  auth as the `prodbox-gateway-daemon` ServiceAccount. The `gateway/gateway/aws` object is
  populated by `prodbox aws setup` / `prodbox config setup` and cleared by AWS teardown; the
  repo-root config carries only the `SecretRef.Vault` target. `gateway/gateway/minio` is
  generated/static Vault-managed seed material. The gateway MinIO
  bootstrap Job now logs into Vault as `gateway-minio-bootstrap`, materializes both MinIO root and
  gateway MinIO credentials on tmpfs, and creates/updates the `prodbox-gateway` MinIO user and
  policy from those files.
- The `keycloak-postgres` chart no longer calls the gateway daemon
  `/v1/secret/ensure-namespace` RPC or carries `password: change-me` placeholders for Patroni
  roles. Its `pre-install,pre-upgrade` materializer hook logs into Vault as the
  `prodbox-<namespace>-pg` ServiceAccount, reads the app/superuser/standby Patroni KV paths, and
  creates or merge-patches the three Percona-watched Kubernetes Secrets with only `username` and
  `password` data before the `PerconaPGCluster` resource is applied. The hook RBAC can create
  Secrets and can get/update/patch only the three named Patroni Secrets for the release.
- Host/admin helper paths now use the host-side Vault root-token helper instead of legacy Kubernetes
  Secrets: `UsersAdmin.loadKeycloakAdminPassword` reads `secret/vscode/keycloak/admin.password`,
  `UsersAdmin.loadKeycloakSmtpSettings` reads `secret/keycloak/smtp`, the AWS SES stack sync writes
  `secret/keycloak/smtp` after deriving the SES SMTP password, and `TestValidation` reads OIDC
  client secrets plus demo-user password from `secret/vscode/oidc/*` Vault paths. A sealed,
  unreachable, or incomplete Vault fails those flows loud.
- Unit coverage pins the KV v2 policy path rendering, chart-secret policy/role inclusion in the
  default Vault reconcile plan, the cross-namespace `keycloak-smtp` role binding, seed-object
  coverage for every consumer path, automatic-seed exclusion of externally-owned objects,
  Kubernetes-auth config and login request rendering, read-before-write live reconcile bootstrap
  semantics, the direct websocket SecretRef chart source, production rejection of workload
  `TestPlaintext`, Keycloak and MinIO Vault-init materialization, MinIO bootstrap Job Vault-init
  materialization, VS Code SecurityPolicy client-Secret Vault materialization, the gateway SecretRef
  config/MinIO bootstrap/AWS KV writer path, the Patroni Vault materializer hook/RBAC/values path,
  and the host/admin Vault helper paths for SMTP field decoding and OIDC/SES field rendering, plus
  the service-account manifests/bindings for the straightforward chart controllers plus Vault's
  TokenReview binding.
- Unit coverage also pins the sealed-startup structural proof: the Keycloak, Keycloak-Postgres,
  VS Code, and MinIO `vault-secrets` init sections use `set -eu`, Vault Kubernetes login, and direct
  Vault KV reads, with no ignored Vault failures, Helm `lookup`, `randAlphaNum`, `secretKeyRef`, or
  `TestPlaintext` fallback in those startup sections. The later live `sealed-vault` canonical
  validation is owned by Sprint `5.8`.
- Validation: `helm template keycloak charts/keycloak --namespace keycloak`,
  `helm template keycloak-postgres charts/keycloak-postgres --namespace keycloak`,
  `helm template minio charts/minio --namespace minio`,
  `helm template vscode charts/vscode --namespace vscode`,
  `helm template gateway charts/gateway --namespace gateway`,
  `./.build/prodbox dev lint chart`, `cabal build --builddir=.build exe:prodbox`,
  `cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'`
  (**955/955**), `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
  `./.build/prodbox dev lint haskell`, `./.build/prodbox dev check`, and
  `./.build/prodbox test unit` (**955/955** after the sealed-startup proof increment).

### Validation

- The code-owned sealed-startup proof shows Keycloak, Keycloak-Postgres, VS Code, and MinIO
  secret-dependent init paths fail closed on a sealed/unreachable Vault because the Vault login/KV
  reads run under `set -eu` with no non-Vault fallback.
- No chart or gateway manifest mounts a plaintext Dhall fragment, and `Prodbox.Settings.SecretRef`
  carries no `FileSecret` arm.
- Chart templates render against the Vault-auth values shape; live whole-system sealed-Vault
  behavior is validated by Sprint `5.8`.

### Remaining Work

None for Sprint `3.18`. Sprint `3.19` is also closed: the master-seed derivation modules, daemon
`/v1/secret/*` RPCs, daemon-only-seed lint, `selfBootstrapOwnSecrets`, and surrounding
generated-secret assumptions are removed. Sprint `8.9` owns any remaining invite-auth-specific
Vault migration; Sprint `5.8` owns the live whole-system `sealed-vault` canonical validation.

## Sprint 3.19: Retire Master-Seed Derivation: Vault KV Is the Sole Secret Store ✅

**Status**: Done (2026-06-16)
**Implementation**: `prodbox.cabal`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Client.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`, `src/Prodbox/CheckCode.hs`, `charts/gateway/`, `charts/minio/`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

Retire the master-seed HMAC-SHA-256 derivation model entirely so Vault KV is the sole secret store.
The derivation model is removed, not wrapped: every secret that was previously HMAC-derived or
chart-generated becomes a Vault KV object, generated once, persisted on Vault's durable storage, and
fetched by each in-cluster consumer via Vault Kubernetes auth (secret_derivation_doctrine §A1;
vault_doctrine §A1). There is no `master-seed` object in MinIO.

### Deliverables

- `Prodbox.Secret.Derive`, `Prodbox.Secret.MasterSeed`, `Prodbox.Secret.Inventory`,
  `Prodbox.Secret.EnsureNamespace`, `Prodbox.Secret.Wire`, `Prodbox.Secret.GatewayDeriveMode`,
  `Prodbox.Secret.HostBootstrap`, and the host-side `Prodbox.TestSeam.GatewayDerive` seam are
  deleted and removed from `prodbox.cabal`.
- The gateway daemon no longer acquires a master seed, self-bootstraps Secrets, or exposes
  `/v1/secret/derive` / `/v1/secret/ensure-namespace`; the host gateway client no longer has secret
  RPC helpers.
- `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/AwsSubstratePlatform.hs` no longer
  pre-apply derived Secrets or thread a gateway-derive mode. Host/admin reads use Vault KV through
  `Prodbox.Vault.Host`.
- `src/Prodbox/CheckCode.hs` no longer carries the daemon-only raw master-seed lint because there
  is no raw seed reader to scope.
- The gateway chart no longer grants cross-namespace secret-writer RBAC, mounts seed scratch
  storage, or documents `/v1/secret/*`; gateway-owned MinIO access is limited to remaining gateway
  object-store work.
- The `prodbox/master-seed` MinIO object is retired as a supported artifact; no code path reads or
  writes it.
- Every previously-derived secret — Patroni/Postgres passwords, the Keycloak admin password, OIDC
  client secrets, gateway per-node event keys — is a Vault KV object fetched via Vault k8s auth or,
  for host/admin flows, through the host Vault helper.
- The chart-generated `lookup`+`randAlphaNum` Secret pattern is absent on the supported chart-secret
  path; MinIO root credentials and OIDC client secrets resolve from Vault KV.
- `secret_derivation_doctrine.md` describes only the Vault-KV model; the retired derivation history
  is preserved in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes after the retired modules are removed from the
  package exposure list.
- `./.build/prodbox test unit` passes (**898/898**) after the removal. The unit suite includes the
  Sprint `3.19` absence proof that the deleted module files stay absent and that the selected
  daemon/client/lint/chart surfaces do not reintroduce retired module names or `/v1/secret/*` RPCs.
- `test/integration/CliSuite.hs` no longer injects the gateway-derive test seed seam or expects
  host pre-application of derived chart Secrets.
- `./.build/prodbox test integration cli` passes (**34/34**) after the CLI fixtures move to
  Vault-shaped inputs: gateway config tests use `SecretRef.Vault` with a fake loopback Vault server,
  and fake RKE2/Pulumi flows opt into test-only Vault gate/KV seams instead of the removed derive
  seam.
- The legacy ledger's Sprint `3.19` rows for the master-seed object, derivation modules/RPC/lint,
  and chart-generated `lookup`+`randAlphaNum` pattern are moved to `Completed`.

### Validation

- The repository contains no `Prodbox.Secret.{Derive,MasterSeed,Inventory,EnsureNamespace,Wire}`,
  no `/v1/secret/*` daemon RPC, no `checkRawMasterSeedReadScope` lint, and no
  `selfBootstrapOwnSecrets`.
- No supported chart template renders a `lookup`+`randAlphaNum` Secret for MinIO root or OIDC client
  material; those values read from Vault KV.
- With Vault unsealed, chart and Keycloak secrets resolve from Vault KV; with Vault sealed, secret
  resolution fails closed and no consumer reconstructs a secret from any non-Vault source.
- Closure gates: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox dev docs check`,
  `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and
  `./.build/prodbox dev check`.

### Remaining Work

None for Sprint `3.19`. The transit-seal hierarchy that gives each cluster its seal custody for
these Vault KV objects is Sprint `3.20`; federated lifecycle reconcile and the fail-closed unseal
cascade closed under Sprint `4.32`.

## Sprint 3.20: Vault Transit-Seal Hierarchy and Per-Cluster Seal Custody ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Vault/Seal.hs`, `src/Prodbox/Vault/Client.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/Vault/Reconcile.hs`, `charts/vault/`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cluster_federation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`

### Objective

Establish the per-cluster Vault seal model and seal custody that underpins cluster federation: the
root cluster uses a Shamir seal unlocked by the operator, and each child cluster uses
`seal "transit"` pointed at its parent's Vault, with the child's init keys held in the parent's
Vault KV (cluster_federation_doctrine §A3; vault_doctrine §A2–§A3). A child Vault literally cannot
unseal without a live, unsealed parent — the fail-closed brick cascades down the tree from the root.

### Deliverables

- `Prodbox.Vault.Seal` defines the root Shamir seal mode, the child Transit seal mode, the HCL
  renderer, the init-request selector, per-child Transit seal policy rendering, and the
  child-init-custody field map stored in the parent's Vault KV.
- The root cluster's Vault uses a Shamir seal; its unseal/recovery keys + initial root token are
  emitted into the `.age` unlock bundle on retained host storage
  (`.data/prodbox/vault-unlock-bundle.age`), decrypted only by the operator's memorized password
  (the test harness simulates the password via `test-config.dhall`).
- A child cluster's Vault config carries `seal "transit"` against the parent cluster's Vault; the
  chart renders that stanza only when `seal.mode = transit` and supplies the parent Transit token
  through `VAULT_TOKEN` from a Kubernetes Secret instead of embedding it in `vault.hcl`.
- `Prodbox.Vault.Client.InitRequest` supports both root Shamir init (`secret_shares` /
  `secret_threshold`) and child Transit auto-unseal init (`recovery_shares` /
  `recovery_threshold`); init responses may carry recovery keys without unseal keys.
- At child init, the child's recovery keys + initial root token are stored in the **parent's** Vault
  KV; the parent's Transit key is the child's unseal authority.
- Per-domain Transit keys + least-privilege Vault policies are provisioned for the envelope and
  secret-class consumers (config, gateway state, Pulumi backend, chart/Keycloak secrets), and the
  federation-custody policy covers the opaque `prodbox-child-*` Transit-key namespace.
- The `prodbox vault` command group surfaces the root init/unseal path through the same typed seal
  model the child seal-custody runtime consumes.

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes with `Prodbox.Vault.Seal` exposed.
- `./.build/prodbox test unit` passes (**907/907**). The Sprint `3.20` tests prove root Shamir
  init renders only unseal-key shares, child Transit init renders recovery-key shares, the child
  `seal "transit"` HCL contains no token literal, child recovery keys/root token become a
  parent-owned Vault KV field map, and per-child Transit policies scope to one key.
- `./.build/prodbox test integration cli` passes (**34/34**) after the CLI help/golden fixtures
  move the live-registration blocker to the later auto-unseal lifecycle sprint.
- `./.build/prodbox dev lint chart` passes after the Vault chart gains the `seal.mode` conditional
  and `VAULT_TOKEN` Secret reference.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, and
  `./.build/prodbox dev check` pass on the final Sprint `3.20` tree.

### Validation

- The root Shamir path writes only the host-side `.age` unlock bundle; the child Transit path has no
  child unlock-bundle model and maps child init material into the parent's Vault KV custody shape.
- The Vault chart defaults to Shamir and renders `seal "transit"` only for a child configuration;
  the parent Transit token is sourced from `VAULT_TOKEN`, not from the ConfigMap.
- The root Vault's recovery keys + root token are present only inside the `.age` unlock bundle and a
  child's init keys are present only in its parent's Vault KV — never on the child's local storage.
- Per-domain Transit keys exist with least-privilege policies; an unauthorized SA cannot wrap/unwrap
  against a domain it is not bound to.
- Closure gates: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit`,
  `./.build/prodbox dev lint chart`, `./.build/prodbox dev docs check`,
  `./.build/prodbox dev lint docs`, and `./.build/prodbox dev check`.

### Remaining Work

None for Sprint `3.20`. Child `cluster reconcile` auto-unseal-from-parent wiring, the
init-once/unseal-on-rebuild lifecycle, and the fail-closed unseal cascade closed under Sprint
`4.32`; the cluster-federation trust topology and downstream-cluster custody gateway surface
closed under Sprint `2.26`.

## Sprint 3.21: Pulsar Workload Chart + Self-Maintained CBOR Pulsar Client [✅ Done]

**Status**: ✅ Done 2026-07-03.
**Blocked by**: none — the broker client is prodbox-owned Haskell work.
**Implementation**: `src/Prodbox/Pulsar/Client.hs`, `src/Prodbox/Pulsar/Protocol.hs`, `src/Prodbox/Pulsar/Codec.hs`, `src/Prodbox/Pulsar/Topic.hs`, `src/Prodbox/Pulsar/Envelope.hs`, `charts/pulsar`
**Live-proof**: proven 2026-07-03 via `./.build/prodbox test integration pulsar-broker`
**Independent Validation**: unit + CLI/env integration on the home/local substrate — the codec round-trip, `topicFor` topic-algebra, `Work*` envelope suites, native frame/metadata/CRC32C/message-id parser tests, client endpoint validation, Pulsar chart-render surface, `prodbox test integration cli`/`env`, and live `pulsar-broker` produce/consume/ack prove the locally owned code with no dependency on any later phase.
**Docs to update**: `documents/engineering/pulsar_messaging_doctrine.md`

### Objective

Deliver the Pulsar platform chart and the self-maintained native-protocol Haskell Pulsar client
whose payload codec is canonical-CBOR-only — no codec-selection field on the wire — per
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md). The client
carries the derived topic algebra (`topicFor`) and the `Work*` envelope family so every producer and
consumer shares one typed topic-and-envelope surface.

### Deliverables

- ✅ `src/Prodbox/Pulsar/Client.hs` exposes the native-client boundary (`connect`, `produce`,
  `consume`, `ack`) and typed request/error values over the repo-owned Haskell transport/framing
  layer. It validates endpoints, opens a TCP broker session, performs lookup / producer / consumer /
  ack flows, correlates requests, reconnects with bounded backoff on retryable transport failures,
  validates metadata + CRC32C payload frames, and classifies broker failures into typed errors.
  There is no WebSocket fallback and no second runtime.
- ✅ `src/Prodbox/Pulsar/Protocol.hs` owns the minimal Pulsar protobuf/framing surface required by
  the client: command encoders, response decoders, payload-frame parser, message metadata,
  message-id rendering/parsing, broker service URL parsing, and server-error classification.
- ✅ `src/Prodbox/Pulsar/Codec.hs` encodes and decodes message payloads as canonical CBOR only,
  with no runtime codec-selection field.
- ✅ `src/Prodbox/Pulsar/Topic.hs` provides the derived topic algebra `topicFor`, and
  `src/Prodbox/Pulsar/Envelope.hs` defines the `Work*` envelope family.
- ✅ `charts/pulsar` renders as a retained-storage gateway dependency against the canonical
  `127.0.0.1:30080/prodbox/pulsar-mirror:4.0.2` in-cluster image reference.

### Validation

Code-owned validation on 2026-07-03:

1. `cabal build --builddir=.build exe:prodbox` exit 0.
2. `cabal build --builddir=.build all --ghc-options=-Werror` exit 0.
3. `cabal test --builddir=.build test:prodbox-unit` exit 0 (1155/1155 after Sprint `3.21`),
   including the CBOR codec round-trip, `topicFor` topic-algebra, `Work*` envelope coverage,
   native frame/metadata/CRC32C/message-id parser coverage, endpoint validation, and Pulsar chart
   plan coverage.
4. `./.build/prodbox test integration cli` exit 0 (39/39).
5. `./.build/prodbox test integration env` exit 0 (39/39).
6. `./.build/prodbox dev lint chart` exit 0 over `charts/pulsar`.
7. `./.build/prodbox test integration pulsar-broker` exit 0 (2026-07-03): deployed the internal
   Pulsar chart on the home-local substrate, created a validation topic under
   `persistent://public/default/`, produced and consumed a CBOR payload over the native broker
   protocol, and acknowledged message id `8:0:-1`.

### Remaining Work

None.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
