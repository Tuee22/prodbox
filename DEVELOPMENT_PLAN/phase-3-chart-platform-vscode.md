# Phase 3: Haskell Chart Platform and Public Workload Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md)

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, the
> supported public workload delivery path, and the CLI-doctrine adoption sprints that align chart
> orchestration with [the engineering doctrine docs](../documents/engineering/README.md).

## Phase Status

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
the consuming chart templates.

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
- All non-PV chart state lives in the cluster as k8s Secrets (data-bound values derived by the gateway service from the master seed at MinIO `prodbox/master-seed` per Sprint `3.13`; non-data-bound values generated by Helm `lookup` + `randAlphaNum`). The legacy `.prodbox-state/` cache is on the cleanup ledger; `forbidDotProdboxState` in `prodbox check-code` (Sprint `4.18`) refuses regressions.
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
- `deployment.websocket_replicas` and `deployment.api_replicas` now carry the settings-backed
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

## Sprint 3.13: Chart Secrets Derived by the Gateway Service 🔄

**Status**: Active. First chunk landed 2026-05-30 on top of Sprint
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
  `curlimages/curl:8.10.1` (small + curl-only image). `--retry 5
  --retry-delay 2 --retry-connrefused` covers transient daemon-pod
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

**Blocked by**: ~~Sprint 2.19~~ unblocked — `/v1/secret/ensure-namespace` is no longer a structured-503 stub; the daemon handler dispatch is live.
**Implementation**: ✅ `src/Prodbox/Secret/Inventory.hs` (doctrine-§6 inventory; 2026-05-30); ✅ `src/Prodbox/K8s/InCluster.hs` (in-pod credentials loader + REST-path / manifest helpers + `K8sSecretOps` capability + TLS-backed `inClusterK8sSecretOps` constructor; 2026-05-30); ✅ `src/Prodbox/Secret/EnsureNamespace.hs` (`applyDerivedSecrets` pipeline + sha256/base64url wire helpers; 2026-05-30); ✅ `src/Prodbox/Gateway/Daemon.hs::handleSecretEnsureNamespace` (replaces the 503 stub with the full request-body parse + master-seed gate + ServiceAccount load + TLS client construction + `applyDerivedSecrets` invocation + structured response; 2026-05-30); ✅ `charts/gateway/templates/serviceaccount.yaml` + `rbac.yaml` + `service-clusterip.yaml` + `deployments.yaml::serviceAccountName` (per-target-namespace Role + RoleBinding pairs for `secrets:get,create,patch` + unsuffixed in-cluster ClusterIP; 2026-05-30); ✅ `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml` + `charts/keycloak/templates/secret-bootstrap-job.yaml` (Helm pre-install Jobs that POST to ensure-namespace via the gateway ClusterIP; 2026-05-30); 🔄 `src/Prodbox/Lib/ChartPlatform.hs` (gut `resolveChartSecrets`); 🔄 `charts/<release>/templates/secret.yaml` (lookup-guarded patterns for non-derived fields).
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

### Remaining Work

The four-block end-to-end verification from the approved plan Part 3 rolls up into
Sprint 4.18's final-cleanup closure.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface,
  restricted to root charts.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Keycloak edge
  doctrine for chart-managed workloads.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, internal dependency-release boundary, and the authoritative synchronous-replication
  Patroni doctrine.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/local_registry_pipeline.md` - Harbor-loading implications for the chart
  platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the browser, API, WebSocket, and admin public workload
  paths.

## Sprint 3.14: Workload Mode via Dhall (Replaces `PRODBOX_WORKLOAD_MODE` Env Var) 🔄

**Status**: Active (May 24, 2026 — code-owned surface landed: new
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
Remaining work: the live operator exercise (`prodbox rke2 reconcile`
plus `prodbox charts deploy api` / `prodbox charts deploy websocket`)
is the closure gate.)
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

- All code-owned work is shipped on the workload-binary and chart-side surfaces.
  Live operator exercise (`prodbox rke2 reconcile` plus `prodbox charts deploy api` /
  `prodbox charts deploy websocket`) is the only remaining closure gate. The
  workload-only Dhall schema currently lives inline in
  `src/Prodbox/Workload/Settings.hs::WorkloadConfigDhall`; promoting it to a
  sibling `prodbox-workload-types.dhall` is an optional follow-up and not a
  closure blocker.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
