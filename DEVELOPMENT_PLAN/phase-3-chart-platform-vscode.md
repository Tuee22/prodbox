# Phase 3: Haskell Chart Platform and Public Workload Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md)

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, and the
> supported public workload delivery path.

## Phase Summary

This phase owns the Haskell chart platform and retained-storage orchestration while preserving
deterministic PV/PVC rebinding and the supported public workload delivery model. It owns retained
storage, Harbor-backed image sourcing for the supported chart stack, the Envoy Gateway browser-auth
path for `vscode`, the JWT-only API and Redis-backed WebSocket workload surfaces, and the
PostgreSQL doctrine for every Helm-managed application stack. Sprints `3.1`, `3.2`, `3.3`, and
`3.4` remain closed on the current chart platform. Sprint `3.5` remains active only on aggregate
validation closure for the now-implemented mixed-auth workload doctrine, the explicit JWT carrier
and Keycloak JWKS-availability boundary across browser, API, and direct-OIDC paths, and the
Keycloak proxy-aware identity-host contract. Sprint `3.6` remains active only on aggregate
validation closure for the now-implemented end-to-end WebSocket runtime, including the
one-connection-per-pod lifetime and readiness-based drain contract. The supported `vscode` stack stays on
Harbor-backed images after Harbor
bootstrap, uses Gateway API plus Envoy Gateway `SecurityPolicy` for the public route, and keeps
the Percona-operator-backed Patroni HA path for every Helm-managed application stack: exactly three
replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, and
  `src/Prodbox/PostgresPlatform.hs`.
- The retained-root contract remains the configured manual PV root (default `.data/`) plus
  generated non-PV chart state under `.prodbox-state/`; chart secret resolution and gateway
  event-key handling are Haskell-owned.
- The supported chart catalog now includes `keycloak`, `vscode`, `api`, `websocket`, and
  `gateway`, with `keycloak-postgres` plus `redis` as internal dependency releases.
- The current supported app dependency graph now includes `keycloak-postgres -> keycloak -> vscode`
  for the browser stack and `redis -> websocket` for the shared-state realtime stack.
- The current lifecycle and chart code install the Percona `pg-operator` Helm release, mirror the
  Percona operator and PostgreSQL images, and render `PerconaPGCluster` resources for
  `keycloak-postgres`.
- Sprint `3.3` keeps the namespace-local release shape, deterministic manual-PV bindings,
  retained-secret contract, and dependent-chart sequencing on the Percona operator surface.
- `keycloak` now consumes the namespace-local retained Patroni credentials secret and the namespace-local
  primary service endpoint instead of a shared `pgpool` service.
- `src/Prodbox/TestPlan.hs` maps the chart validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
- The current worktree renders the `vscode`, `api`, and `websocket` public paths through Gateway
  API `HTTPRoute` resources and Envoy Gateway `SecurityPolicy`, while `keycloak` publishes the
  shared public-edge `Gateway`, certificate, and identity route.
- The supported auth model now distinguishes request-borne bearer JWTs on the API route, the
  Envoy-managed browser redirect and cookie or session path on `vscode`, and workload-owned
  carrier or session state for the direct-OIDC `websocket` path.
- Envoy validates the current API route from Keycloak issuer metadata plus JWKS-backed signing keys
  on the edge hot path; Keycloak availability remains a dependency for login, refresh, and later
  JWKS refresh rather than for per-request API authorization.
- The shipped browser route currently exercises the Envoy-managed OIDC path, while the supported
  chart-managed direct-OIDC `websocket` workload now exercises workload-owned session bootstrap on
  the dedicated Keycloak host.
- The current dedicated Keycloak identity route is rendered and the named validation surface now
  proves the external-hostname, issuer, forwarded-header, and public-path constraints for
  Keycloak-backed public workloads; the remaining active work is the aggregate rerun closure for
  that implemented contract.
- Public TLS terminates at Envoy on the supported browser, API, and WebSocket hosts. Backend TLS
  or mTLS is not part of the current supported chart-workload contract.
- The current worktree ships repo-owned API, Redis, and WebSocket chart stacks, with settings-
  backed replica controls for the public API and WebSocket workloads. Redis remains scoped to
  shared application state for the current WebSocket surface and any later explicit external
  rate-limit service; the current chart catalog does not yet ship a standalone rate-limit-service
  workload.
- The current `PRODBOX_WORKLOAD_MODE=websocket` runtime now materializes workload-managed OIDC
  bootstrap, a real `/ws` upgrade path, one-live-connection-per-backend-pod lifetime,
  readiness-based drain, revoke-and-reconnect behavior, and long-lived socket session semantics on
  the WebSocket host.

## Sprint 3.1: Haskell Chart Runtime and Deterministic Retained Storage ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep chart orchestration and retained-storage handling on the Haskell runtime while preserving the
supported platform doctrine.

### Deliverables

- `prodbox charts list|status|deploy|delete` are implemented in Haskell.
- Deterministic retained storage under the configured manual PV root remains intact.
- `.prodbox-state/` remains the canonical retained non-PV chart-state root.
- Chart secret resolution and gateway event-key handling move to Haskell-owned modules.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-storage`
4. `prodbox test integration charts-platform`

### Current Validation State

- `test/unit/Main.hs` proves deterministic Haskell chart-plan and storage-binding behavior.
- `test/integration/cli/Main.hs` proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`.
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
5. Helm proof: `prodbox rke2 install` reconciles the cluster-wide Percona operator before
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
- Keycloak remains a chart-managed dependency, but the public browser path no longer depends on the
  shared-host `/auth` model.
- `keycloak_nginx_client_secret` is removed from the long-term chart secret contract.
- The current chart platform closes on Envoy-managed browser OIDC for `vscode`; Sprint `3.5`
  owns the remaining direct-OIDC workload doctrine on the dedicated Keycloak host rather than
  broadening Sprint `3.4` beyond the shipped browser route.
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
  `HTTPRoute`, and the dedicated Keycloak public host expected by the app stack.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders the Gateway API, OIDC, and dedicated-hostname
  values contract, and the chart-secret contract now uses `keycloak_vscode_client_secret`.
- `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, and the built-frontend suites no
  longer carry the nginx proxy image or image-publication path.
- The shipped chart surface now extends beyond `keycloak` plus `vscode` to the dedicated `api`
  and `websocket` workloads. Sprint `3.5` remains active on the mixed-auth doctrine and Keycloak
  public-host contract, while Sprint `3.6` remains active on the remaining end-to-end WebSocket
  implementation.

### Remaining Work

None.

## Sprint 3.5: JWT-Protected API Workload Delivery 🔄

**Status**: Active
**Implementation**: `charts/api/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported JWT-protected API workload to the Haskell chart platform so the public edge proves
local token validation and route claims while the chart platform closes explicitly on the supported
split between Envoy-managed browser auth and app-managed OIDC workloads.

### Deliverables

- The supported chart catalog adds a dedicated API workload with its own public hostname and Haskell
  deploy, status, and delete ownership.
- Envoy authenticates the API route locally from Keycloak issuer metadata and signing keys rather
  than through per-request Keycloak lookups or Redis.
- The API route carries explicit issuer, audience, and route-claim requirements through repo-owned
  chart values and templates.
- The supported auth model explicitly identifies bearer-token API carriage, Envoy-owned browser
  redirect and cookie or session return paths, and workload-owned carrier or session state for
  direct-OIDC workloads.
- Envoy discovers Keycloak JWKS out of band and validates API tokens locally on the hot path;
  Keycloak availability remains a login, refresh, and JWKS-refresh boundary rather than a
  per-request API dependency.
- The chart secret and Keycloak client contract expands as needed for the supported API route
  without reintroducing any app-local auth proxy surface.
- The supported chart platform explicitly distinguishes Envoy-managed browser auth for proxy-auth
  workloads from app-managed OIDC for workloads that need direct identity claims or session
  ownership.
- Keycloak-backed public workloads preserve the dedicated identity-host contract, including
  external hostname and issuer alignment, proxy-header compatibility, and no supported public
  management or health path exposure unless a later doctrine revision expands that route set.
- The supported chart platform makes the current transport boundary explicit: public TLS terminates
  at Envoy, and backend TLS or mTLS remains outside the supported chart-workload contract until a
  later doctrine revision expands it.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-api`
5. Manifest proof: the API route attaches dedicated Gateway API and Envoy auth policy resources on
   the supported public edge
6. Auth proof: unauthenticated or wrong-claim requests are denied, while valid tokens from the
   configured Keycloak issuer are accepted
7. Doctrine proof: the supported API, browser, and direct-OIDC split names the request-token
   carrier and JWKS boundary explicitly and does not route JWT validation through Redis or
   per-request Keycloak calls
8. Manifest or runtime proof: one supported direct-OIDC workload closes on the dedicated Keycloak
   host and proxy-aware issuer contract without reintroducing shared-host `/auth` or nginx proxy
   surfaces

### Current Validation State

- `src/Prodbox/Lib/ChartPlatform.hs`, `charts/api/`, and `src/Prodbox/Workload.hs` now render and
  serve the dedicated API workload, public hostname, JWT provider configuration, audience, and
  route-claim requirements through repo-owned Gateway API, Envoy, and `PRODBOX_WORKLOAD_MODE=api`
  runtime surfaces.
- The current shipped browser route exercises the Envoy-managed redirect and cookie or session
  path, and the current API route validates request-carried bearer JWTs locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose `charts-api` as a
  named external validation surface that proves unauthenticated rejection, wrong-claim rejection,
  and valid-token acceptance.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` now pass with the API workload surface in place.
- The shipped chart catalog now exercises all three supported auth shapes: Envoy-managed browser
  OIDC through `vscode`, request-carried bearer JWTs through `api`, and workload-managed OIDC
  bootstrap plus workload-owned session state on the dedicated `websocket` host.
- `src/Prodbox/TestValidation.hs` now proves the dedicated Keycloak identity-host redirect,
  issuer, and public-path contract, plus the direct-OIDC session boundary for the workload-owned
  `websocket` path.
- The repo-owned chart surface now also carries the current WebSocket auth-path hardening:
  `charts/keycloak/` runs the identity path on one Keycloak replica, `charts/websocket/`
  authorizes a private token-endpoint backchannel to that identity workload, and the repo-owned
  custom image charts now force fresh pulls for the stable machine-id tags so the canonical suite
  does not reuse stale workload binaries.

### Remaining Work

- Rerun aggregate runtime validation from the current tree so `prodbox test integration charts-api`
  and `prodbox test all` close on the current API plus identity-host contract after the
  single-replica Keycloak and forced custom-image rebuild or pull fixes.

## Sprint 3.6: Redis-Backed WebSocket Delivery and Scale-Out 🔄

**Status**: Active
**Implementation**: `charts/redis/`, `charts/websocket/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported WebSocket workload and its Redis backing service to the Haskell chart platform so
the public edge closes on reconnect-safe realtime delivery instead of a single-replica browser-only
stack.

### Deliverables

- The supported chart catalog adds repo-owned Redis and WebSocket workloads with dedicated public
  WebSocket routing on the shared Envoy edge.
- The supported `websocket` surface serves a true WebSocket endpoint on `/ws` rather than only
  HTTP helper endpoints on the WebSocket hostname.
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
   and dedicated public-edge hostnames
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
  a named external validation surface that proves direct-OIDC bootstrap, authenticated WebSocket
  upgrade, cross-replica delivery, revocation-driven reconnect, readiness-based drain, and
  post-pod-restart state survival on the WebSocket host.
- `src/Prodbox/Workload.hs`, `charts/websocket/`, and `charts/keycloak/` now also carry the
  private Keycloak token-endpoint backchannel, the matching inter-chart network-policy allowance,
  and the current single-replica Keycloak auth-path workaround needed to keep direct-OIDC browser
  login stable on the supported stack.
- Sprint `3.6` remains active only on the aggregate reruns that close this implemented WebSocket
  runtime and proof surface on the canonical suite.

### Remaining Work

- Rerun `prodbox test integration charts-websocket` and `prodbox test all` from the current tree
  so the real WebSocket path closes on the private Keycloak backchannel plus fresh custom-image
  publication path rather than the stale stable-tag binaries from earlier reruns.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Keycloak edge
  doctrine for chart-managed workloads.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, and the Percona-operator-backed Patroni PostgreSQL doctrine.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/local_registry_pipeline.md` - Harbor-loading implications for the chart
  platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the browser, API, and WebSocket public workload paths.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
