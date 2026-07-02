# Envoy Gateway Edge Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md),
[acme_provider_guide.md](acme_provider_guide.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md),
[README.md](./README.md), [cli_command_surface.md](./cli_command_surface.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md),
[local_registry_pipeline.md](./local_registry_pipeline.md),
[unit_testing_policy.md](./unit_testing_policy.md),
[vault_doctrine.md](./vault_doctrine.md),
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md)
**Generated sections**: none

> **Purpose**: Define the canonical MetalLB + Envoy Gateway + Keycloak public-edge doctrine for
> self-managed `prodbox` clusters, including JWT, Redis, and WebSocket boundaries.

## 0. Canonical Doctrine Statements

The target public-edge doctrine for self-managed `prodbox` clusters is:

1. MetalLB exposes the cluster edge through a stable `LoadBalancer` address.
2. Envoy Gateway is the target public-edge controller and Envoy is the edge data plane.
3. Kubernetes Gateway API resources own public Layer 7 routing.
4. cert-manager owns listener TLS material.
5. Keycloak remains the OIDC identity provider and JWT issuer.
6. Envoy owns edge authentication and authorization for routes that do not rely on
   application-local auth handling.
7. Envoy-managed browser authentication in this repository uses Envoy Gateway `SecurityPolicy`.
8. JWT validation happens locally at Envoy from issuer metadata and signing keys, not through
   per-request Keycloak lookups and not through Redis.
9. Redis is optional shared application infrastructure for realtime or rate-limit workloads only.
10. WebSocket authorization happens at connection setup time, while message-level authorization
    remains application-owned.
11. Supported public routing uses one shared public hostname with explicit path prefixes for
    identity, application, and admin surfaces; wildcard public DNS is not part of the supported
    architecture.
12. The Haskell distributed gateway daemon documented in
    [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) is distinct from
    the Envoy Gateway public edge.

The target control-plane principle is:

```text
Keycloak authenticates.
Envoy enforces.
Apps serve.
Redis shares optional app state.
MetalLB exposes the entrypoint.
```

## 1. Planning Ownership

This document is normative public-edge doctrine only.

Implementation status, validation closure, remaining work, and cleanup ownership live in
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

This doctrine applies to both supported substrates per
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md). On the home local
substrate (RKE2 on the operator host) MetalLB + Envoy Gateway terminate the public edge directly;
on the AWS substrate the AWS Load Balancer Controller replaces MetalLB while Envoy Gateway remains
the in-cluster public-edge controller per
`Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstrateEnvoyGatewayRuntime`. The Pulumi stacks under
`pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/` provision
AWS substrate substrate-platform inputs and SES shared infrastructure; the public-edge controller
itself remains in-cluster on both substrates.

## 2. Current Worktree Baseline

The current repository closes on the implemented self-managed public-edge doctrine:

1. `prodbox cluster reconcile` installs or reconciles Harbor, MinIO, MetalLB, Envoy Gateway, cert-manager, and the
   Percona PostgreSQL operator.
2. The current MetalLB runtime supports config-selected L2 or BGP advertisement from repo-owned
   settings, rendered through `IPAddressPool` plus `L2Advertisement` on the L2 path and
   `BGPPeer` plus `BGPAdvertisement` on the BGP path.
3. The current shipped public workloads are `vscode`, `api`, `websocket`, Harbor, and MinIO,
   each delivered through shared-host Gateway API `HTTPRoute` resources on
   `test.resolvefintech.com`.
4. The supported shared public edge is owned by the `keycloak` chart: the `keycloak` stack
   publishes the shared `Gateway`, the listener certificate, the port-80 redirect `HTTPRoute`, and
   the `/auth` Keycloak route, while `vscode`, `api`, and `websocket` attach `HTTPRoute` resources
   from their own namespaces. (The shared edge co-locates with the OIDC identity provider that
   terminates `/auth`, rather than with an application workload.)
5. Keycloak publishes the identity flow and the authenticated admin API used by `prodbox users`
   on the shared hostname under `/auth`.
6. The shared `public-edge` `Gateway` exposes HTTPS on port `443` for application traffic and
   HTTP on port `80` only for a redirect-only `HTTPRoute` that returns a permanent redirect to the
   same shared-host path over HTTPS. Plaintext backend forwarding is unsupported.
7. `prodbox edge status` classifies Route 53, Envoy Gateway deployment, `GatewayClass`,
   `Gateway`, listener readiness, redirect `HTTPRoute`, application `HTTPRoute`,
   `SecurityPolicy`, certificate, `LoadBalancer`, and advertisement-mode state across the browser,
   API, WebSocket, Harbor, and MinIO routes.
8. `prodbox test integration charts-api` and `prodbox test integration charts-websocket` now
   prove the shipped JWT-only API and Redis-backed WebSocket paths externally, while
   `prodbox test integration admin-routes` proves the Harbor and MinIO auth gates externally.
9. Public browser redirects use the shared-host `/auth` identity route, while non-browser
   provider backchannels stay in-cluster: VS Code's Envoy `SecurityPolicy` targets the in-cluster
   Keycloak Service, API/WebSocket JWT policies fetch JWKS through the shared internal Keycloak
   endpoint, Harbor/MinIO admin OIDC policies use the shared internal Keycloak token endpoint, and
   the WebSocket workload uses the in-cluster Keycloak Service on port 8080. These are current
   runtime boundaries, not second public identity surfaces.

## 3. Component Responsibilities

### MetalLB

MetalLB owns external IP advertisement for Kubernetes `Service` objects of type `LoadBalancer`.

MetalLB does not own:

- HTTP routing
- TLS termination
- OIDC flows
- JWT validation
- WebSocket upgrade semantics
- application authorization

Its role is:

```text
Internet client -> MetalLB address -> Envoy service
```

The doctrine allows either L2 or BGP advertisement models, and the current implementation supports
both through repo-owned settings.

### Envoy Gateway and Envoy

Envoy Gateway owns Kubernetes control-plane reconciliation for the public edge. Envoy owns the hot
request path.

Envoy responsibilities include:

- TLS termination
- Gateway API listener and route attachment
- forwarding traffic to backend services
- Envoy Gateway `SecurityPolicy` attachment
- optional browser-facing OIDC enforcement
- optional JWT validation for token-bearing API routes
- optional claim-based route authorization
- WebSocket proxying
- edge observability

Envoy is treated as stateless edge infrastructure. It does not own durable application state.

### Keycloak

Keycloak remains the identity provider.

Keycloak responsibilities include:

- browser login
- OIDC issuer metadata
- token issuance and signing
- user, role, group, and client management
- identity and session persistence in PostgreSQL
- durable identity and session storage behind the public login flow
- the authenticated admin API consumed by the operator-owned `prodbox users invite|list|revoke`
  surface

Envoy and application workloads trust tokens issued by Keycloak according to route policy.

### cert-manager

cert-manager owns listener TLS material for the public edge. It renders one ACME
`ClusterIssuer` with a DNS-01 Route 53 solver per
[acme_provider_guide.md](./acme_provider_guide.md):

- `zerossl-dns01` — the ZeroSSL ACME issuer, built from `acme.server` and EAB-authenticated.

The issuer name is DNS-01-honest: the issuer authenticates ACME challenges through a
**DNS-01 Route 53 solver**, and the name now says so. It is held as one SSoT constant in
`Prodbox.PublicEdge.publicEdgeClusterIssuerName` and threaded through both chart
`values.yaml` files and the doc/test sites; no second hand-edited copy survives. Sprint 7.13
renamed it from the historically-inaccurate HTTP-01-claiming name (which named HTTP-01 but ran
DNS-01). Because the issuer name is baked into retained ACME account and certificate state,
the live rename lands on a wipe-and-rebuild boundary; the S3 cert retention key is keyed on
substrate + FQDN (not the issuer name), so the retained certificate restores under the new
issuer name without re-ordering from ZeroSSL.

The keycloak chart `Certificate` references this single issuer
(`Prodbox.PublicEdge.publicEdgeClusterIssuerName`). Because the canonical validation loop
repeatedly rebuilds the substrate, the issued certificate is retained and restored before
issuance (see below) so rebuilds do not re-order it and consume ZeroSSL issuance quota.

The public-edge listener certificate is a **LongLived** managed resource, not disposable
chart state. It is issued once, retained in the long-lived `pulumi_state_backend` S3 bucket
under a substrate-scoped key, and registered in the managed-resource registry per
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md); it is removed
only by `prodbox nuke`. Restore-before-issue and rebuild semantics are in §9. Scheduled for
adoption in Sprints 4.24 / 7.11 / 8.7.

#### TLS and ACME Material Under Vault

The Vault refactor places the ACME and TLS key material beneath this issuer model as a
fail-closed authority layer; it **extends** the single ZeroSSL issuer + S3 retain-restore
behavior above and does not replace it. The retained-and-restored public-edge certificate
contract (substrate-scoped S3 key, restore-before-issue, LongLived managed resource) is
unchanged. Under the refactor:

- **Landed (Sprint 7.15):** the ACME EAB material (the ZeroSSL external-account-binding key id
  and HMAC) lives in the `secret/acme/eab` Vault KV object and is referenced from
  `prodbox-config.dhall` by a typed `Optional SecretRef` (`SecretRef.Vault`) rather than carried
  as plaintext. The non-secret key id is resolved host-side and rendered inline on the
  `zerossl-dns01` `ClusterIssuer`; the HMAC key is materialized into the `cert-manager` namespace
  as the `acme-eab-credentials` Secret by a Vault-login materializer Job (the same Sprint 3.18
  chart-side pattern used for the `vscode` OIDC client Secret), never as inline plaintext.
  `prodbox config validate` rejects any plaintext EAB value.
- New ZeroSSL issuance fails closed when Vault is sealed: the EAB key id cannot be resolved and
  the materializer Job cannot read the HMAC key, so the issuer cannot authenticate to ZeroSSL.
  This is structurally guaranteed by the `SecretRef.Vault` resolver (a sealed Vault cannot
  resolve the reference) and needs no separate enforcement.
- The broader native-Vault-PKI internal-cert authority and the live "sealed Vault blocks
  issuance" proof are a non-blocking `Live-proof: pending` axis (no new PKI subsystem was built
  in 7.15); cert-manager remains the issuer.

See [vault_doctrine.md §11](./vault_doctrine.md#11-tls-and-pki-under-vault) and
[acme_provider_guide.md](./acme_provider_guide.md).

### Redis

Redis is optional shared infrastructure for workloads that need state outside one pod. It is
appropriate for:

1. WebSocket presence state
2. pub/sub fanout
3. shared ephemeral app state
4. distributed locks
5. application-level caching
6. external rate-limit backends

Redis is not part of Envoy JWT validation.

### Application Workloads

Application workloads sit behind Envoy.

They may be:

- browser apps
- APIs
- WebSocket services
- legacy apps that do not understand OIDC
- modern apps that integrate with Keycloak directly
- app-managed OIDC workloads
- edge-authenticated workloads

Application workloads own:

- behavior after authentication succeeds
- fine-grained per-request authorization beyond route metadata
- message-level authorization for WebSocket payloads
- reconnect-safe state that must survive pod restart or rebalance

## 4. Traffic and Hostname Model

The target public edge is:

```text
Internet
  -> router port-forward
  -> MetalLB-assigned LoadBalancer IP
  -> Envoy service managed by Envoy Gateway
  -> Gateway API listeners and routes
  -> backend services
  -> pods
```

The supported route model is explicit:

- one shared public hostname, currently `test.resolvefintech.com`
- port `80` is redirect-only and returns a permanent redirect to the same path on HTTPS
- port `443` is the only public application-routing listener
- Keycloak on `/auth`
- browser workloads on explicit path prefixes such as `/vscode`
- API and WebSocket workloads on explicit path prefixes such as `/api` and `/ws`
- admin surfaces on explicit path prefixes such as `/harbor` and `/minio`

Example hostname routing inside this model may look like:

```text
/auth   -> Envoy -> Keycloak Service
/vscode -> Envoy -> Browser App Service
/api    -> Envoy -> API Service
/ws     -> Envoy -> WebSocket Service
/harbor -> Envoy -> Harbor Service
/minio  -> Envoy -> MinIO Service
```

The supported architecture no longer treats an app-local nginx auth proxy or Traefik `Ingress`
surface as the canonical public edge.

In the supported implementation, the `keycloak` chart owns the shared `public-edge` `Gateway` and
listener certificate in the `keycloak` namespace, alongside the `/auth` identity route it
terminates. `vscode`, `api`, and `websocket` keep their workloads in their own namespaces, but
their `HTTPRoute` resources attach to that shared `Gateway` through cross-namespace `parentRefs`.
The HTTP redirect route also lives with the shared `Gateway` and attaches only to the port `80`
listener, while every backend route attaches to HTTPS listener sections.

The chart→edge-resource ownership above is **editorial doctrine, not a generated section** — and
deliberately so. The route→service catalog *is* generated: the canonical six-route inventory
(`/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, `/minio` and their path prefixes) is a faithful
projection of the typed `PublicEdgeRoute` catalog in `src/Prodbox/PublicEdge.hs`, rendered into
the chart `HTTPRoute` / `Gateway` manifests by the Sprint `3.12` `route-registry` generated
sections (`charts/api/...`, `charts/keycloak/...`, `charts/vscode/...`, `charts/websocket/...`).
Chart-*ownership* of the shared edge resources, however, has **no typed source** to project from:

- The typed catalog encodes only route identity and path prefix
  (`PublicEdgeRoute`, `publicRoutePathPrefix`); it carries no owning-chart field.
- The shared `Gateway`, the listener certificate, and the port-80 redirect `HTTPRoute` are **not
  routes** — they do not appear in `PublicEdgeRoute` at all — so no `route-registry` extension can
  attribute them.
- The `/harbor` and `/minio` admin routes are not owned by any chart template; they are applied
  imperatively by `ensureAdminPublicEdgeRoutes` in `src/Prodbox/CLI/Rke2.hs`.
- The keycloak-chart attribution of the `Gateway` / listener-cert / redirect / `/auth` route is a
  deployment fact reattributed by Sprint `7.13`, not derived from the catalog.

Adding an "owning chart" column would therefore require a new hand-authored Haskell annotation
parallel to the catalog, which would only relocate drift into a second source rather than remove
it. Per the documentation-harmony design guardrail (a table is generated only when it is a faithful
projection of a typed value that needs *no* new hand-authored annotation), the chart→edge ownership
mapping stays editorial here and is owned/corrected by Sprint `7.13`'s route-ownership
reattribution.

The earlier edge pattern:

```text
Client -> Nginx reverse proxy -> Keycloak / Apps
```

becomes:

```text
Client -> MetalLB -> Envoy Gateway -> Keycloak / Apps
```

Nginx or another app-local edge proxy should remain only when a concrete feature gap requires it.

## 5. Authentication Doctrine

Two authentication patterns are supported by doctrine.

### Pattern A: Application-Managed OIDC

Use this pattern when the application already owns its OIDC flow well.

Responsibilities:

```text
Keycloak = authenticates user
App      = performs OIDC flow and manages login/session semantics
Envoy    = TLS termination and routing
```

This pattern is acceptable for future workloads when application-local identity handling is
material to the workload.

Typical fit:

- the application already supports OIDC well
- the application needs to manage its own session semantics
- application behavior depends directly on identity claims

### Pattern B: Envoy-Enforced Edge Auth

Use this pattern when central edge enforcement is preferred.

Responsibilities:

```text
Keycloak = authenticates user and issues tokens
Envoy    = verifies identity and blocks unauthenticated traffic
App      = receives authenticated traffic
```

The current repository uses this pattern for the public `vscode` path through Envoy Gateway
`SecurityPolicy`.

Typical fit:

- the application does not support OIDC
- centralized edge auth is preferred
- unauthenticated traffic should be blocked before it reaches the workload
- multiple internal apps should share the same enforcement model

### Current Implementation Boundary

The current worktree ships all three supported public-edge auth shapes:

- `vscode` uses Envoy-managed browser OIDC enforcement through `SecurityPolicy`; the browser-facing
  authorization endpoint remains on the public issuer, and Envoy's token/provider exchange uses
  the in-cluster Keycloak Service on port 8080 through a cross-namespace backend reference granted
  by `ReferenceGrant`. Envoy Gateway still requires a Kubernetes Secret reference for the OIDC
  client secret, but the `vscode` chart creates or patches that Secret from Vault KV with a
  Vault-authenticated post-install/post-upgrade Job rather than rendering a Helm lookup or
  plaintext value.
- `api` uses request-carried bearer JWTs validated locally at Envoy from Keycloak issuer metadata,
  JWKS, audience, and route claims. The issuer stays public, while Envoy fetches JWKS from the
  in-cluster Keycloak Service on port 8080 through `remoteJWKS.backendRefs` plus a
  `ReferenceGrant` from `api` to the Keycloak Service.
- Harbor and MinIO admin routes use Envoy-managed browser OIDC enforcement through
  `SecurityPolicy`, public authorization redirects, and the shared internal Keycloak token
  endpoint for provider exchange. Their host, issuer, and redirect URL are substrate-aware:
  home local uses `domain.demo_fqdn`; AWS uses `aws_substrate.subzone_name`. The AWS substrate
  platform applies these routes after gateway MinIO bootstrap.
- `websocket` uses workload-managed OIDC bootstrap and cookie-backed session ownership on
  `/ws/oidc`, then a JWT-protected `/ws` upgrade path plus Redis-backed shared state for upgraded
  connections; the current token exchange path uses private in-cluster access to the Keycloak
  Service on port 8080, and its Envoy JWT JWKS fetch uses the same internal service boundary
  through a `ReferenceGrant` from `websocket` to the Keycloak namespace.

The shared-host Keycloak route on `/auth` remains the external identity surface for issuer
metadata, browser login, and workload-managed redirect flows.

## 6. JWT Validation Doctrine

OIDC and JWT are related but different:

```text
OIDC = login and identity protocol
JWT  = signed token format often carried after OIDC authentication
```

Representative claims in a Keycloak-issued token may include:

```text
iss            = https://<shared-host>/auth/realms/<realm>
sub            = <user-id>
aud            = <client-or-api>
exp            = <unix-timestamp>
groups         = [users]
realm roles    = [user]
resource roles = [editor]
```

For token-bearing API routes, the doctrine is:

1. the client presents a JWT through `Authorization: Bearer ...` or another explicitly supported
   transport
2. Envoy obtains Keycloak issuer metadata and signing keys
3. Envoy validates signature, expiry, issuer, audience, and any route-required claims locally
4. Envoy forwards only allowed traffic

The hot path is:

```text
Request -> Envoy -> local JWT verification -> application
```

not:

```text
Request -> Envoy -> Keycloak -> database -> Envoy -> application
```

This means:

- JWT validation must not depend on Redis
- JWT validation must not require a per-request Keycloak round-trip
- issuer, audience, and claim requirements belong to route policy

Typical local validation checks are:

1. extract the JWT from the request
2. decode the JWT header and payload
3. fetch or refresh issuer signing keys from the Keycloak JWKS endpoint
4. verify the JWT signature
5. check expiry
6. check issuer
7. check audience
8. check any route-required roles, groups, or scopes

Common token transport locations are:

```text
Authorization: Bearer <jwt>
Cookie: <session-cookie-or-token-cookie>
```

Depending on the workload shape, either:

1. the application performs the OIDC flow and the client later sends JWTs to Envoy, or
2. Envoy performs the OIDC flow and manages browser login at the edge.

Redis is intentionally excluded from the JWT hot path because adding it would introduce:

- a network call
- a shared dependency
- additional failure modes
- coordinated state that local JWT verification does not need

The current repository ships public JWT-only API route manifests and named JWT-policy validation.
Those routes prove issuer, audience, and claim enforcement through `prodbox test integration charts-api`
rather than undocumented manual checks.

## 7. Redis and WebSocket Doctrine

Redis is workload-local optional infrastructure, not a mandatory platform dependency.

Appropriate Redis-backed workload uses include:

1. WebSocket presence tracking
2. pub/sub fanout
3. shared application state
4. distributed locks
5. application-level caching
6. global rate-limit counters behind an external rate-limit service

If a workload exposes WebSockets behind the public edge, the doctrine is:

1. Envoy authenticates the connection request at setup time.
2. Envoy upgrades the connection and proxies it to one selected backend pod.
3. The backend pod owns that live connection until it closes.
4. Message-level authorization remains application-owned.

The connection flow is:

```text
Client
  -> Envoy HTTPS request
  -> Envoy validates auth at connection time
  -> Envoy upgrades the connection
  -> Envoy proxies the WebSocket stream to one backend pod
```

Stateless WebSocket behavior means reconnects may land on any healthy pod. It does not mean a
single live connection migrates between pods.

Reconnect-safe or restart-safe state must live outside the pod, for example in Redis, NATS,
Kafka, PostgreSQL, or another dedicated service.

Application pods should not be the only place that knows:

- which users are online
- which rooms they joined
- what messages need to be delivered
- what subscriptions exist
- what state must survive a restart

Operational caveats for future WebSocket workloads:

- token expiry during a long-lived connection requires explicit reconnect or refresh design
- role or group changes do not automatically revoke an already-open socket unless the workload or
  surrounding infrastructure actively closes it
- high-security workloads should implement explicit revocation or reconnect logic
- graceful shutdown needs readiness withdrawal and a drain window before process exit

Per-message authorization remains an application concern. Envoy may enforce access to `/ws`, but
the workload still decides whether an authenticated user may perform privileged actions inside the
socket protocol.

The current repository ships a Redis-backed WebSocket application stack and validates it through
`prodbox test integration charts-websocket`, including connection-time auth, shared-state proof,
and post-restart state continuity.

## 8. Scaling and Availability Doctrine

The typed capacity, scaling-policy, and placement model is now owned by
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md); this section retains only the
per-component availability notes below.

The doctrine is horizontally scalable, but the implementation boundary matters.

### Envoy

Envoy is the stateless edge data plane. The doctrine allows multiple Envoy replicas.

The current repository defaults to one Envoy Gateway controller replica and one Envoy data-plane
replica through settings-backed inputs. Those defaults are implementation choices, not doctrinal
scaling limits.

### Applications

Application replicas may scale horizontally behind Envoy.

Run multiple application replicas when the workload needs horizontal capacity.

For HTTP workloads, requests may rebalance normally.

For WebSockets, one live connection stays on one selected pod until disconnect.

### Keycloak

Keycloak remains stateful and depends on PostgreSQL. Keycloak availability matters for new login
and refresh operations even though local JWT verification can continue briefly while cached
signing-key material remains valid.

### Redis

Redis high availability matters only for workloads that actually depend on Redis-backed state.
Production workloads should size Redis availability according to the criticality of that shared
state.

## 9. Operational and Delivery Implications

The supported operational model is:

1. TLS terminates at Envoy on the public edge.
2. Backend HTTP is acceptable on the trusted cluster network, but workloads with stricter
   zero-trust requirements may also use TLS or mTLS from Envoy to backends.
3. Shared-host path routing must remain explicit, with `/auth`, `/vscode`, `/api`, `/ws`,
   `/harbor`, and `/minio` owned as first-class public-edge paths.
4. Keycloak must be proxy-aware and must emit public redirects and issuer URLs that match the
   shared public hostname and `/auth` path contract.
5. Proxy headers such as `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` are part
   of the expected backend contract when the workload needs them.
6. Keycloak health or management endpoints are not a public-route goal by default. The supported
   public Keycloak route covers browser/OIDC identity paths plus `/auth/admin` for the
   authenticated operator invite API; other management endpoints stay private unless a future
   sprint explicitly owns them.
7. WebSocket workloads need graceful termination that stops new connections, drains existing
   sockets, and relies on readiness withdrawal before process exit.

Lifecycle and chart implications:

1. `prodbox cluster reconcile` owns MetalLB, Envoy Gateway, cert-manager, and the Percona PostgreSQL
   operator on the self-managed cluster path.
2. Harbor-backed steady-state image sourcing mirrors or publishes the Envoy Gateway control-plane
   and Envoy data-plane images rather than Traefik images. As of Sprint `7.12` the Envoy Gateway
   chart version, the control-plane (gateway controller) image, and the data-plane (Envoy proxy)
   image are pinned together as one release in `Prodbox.ContainerImage.envoyGatewayRelease` and
   consumed identically by both substrate installers — there is no per-substrate Envoy version, so
   the EG-`1.4.4`-chart / Envoy-`1.37`-data-plane skew (audit C79) is eliminated by construction.
   The proven pairing is EG chart `v1.7.2` / control plane `v1.7.2` / data plane
   `distroless-v1.37.0`.
3. The chart platform ships Keycloak, `vscode`, `api`, and `websocket` on one shared
   public hostname, anchors the shared `Gateway`, listener certificate, port-80 redirect route,
   and `/auth` Keycloak route in the `keycloak` namespace via the `keycloak` chart, attaches
   `vscode`, `api`, and `websocket` `HTTPRoute` resources through cross-namespace `parentRefs`,
   keeps the Keycloak public route limited to browser/OIDC identity paths plus `/auth/admin` for
   the authenticated `prodbox users` invite API, and no longer depends on `vscode-nginx`.
4. The Haskell distributed gateway daemon remains a separate chart and runtime surface; it is not
   the Envoy Gateway public edge.
5. Additional JWT-only API routes, Redis-backed workloads, or WebSocket services must be added
   only when a real workload needs them and must follow this doctrine rather than inventing a
   parallel edge model.
6. The current `vscode` SecurityPolicy, API/WebSocket JWT `remoteJWKS` policies, Harbor/MinIO
   admin SecurityPolicies, and `websocket` workload keep token/provider/JWKS backchannels
   in-cluster rather than exposing a second public Keycloak route or relying on EKS
   public-load-balancer hairpin behavior. The `vscode` SecurityPolicy's client Secret is
   materialized from Vault KV by the chart before Envoy needs the credential.
7. cert-manager renders one ACME `ClusterIssuer` (`zerossl-dns01`, a DNS-01-honest name for its
   DNS-01 Route 53 solver — renamed from the misleading HTTP-01-claiming name in Sprint 7.13) on
   every reconcile; the `keycloak` chart `Certificate` for the shared listener references it, per
   [acme_provider_guide.md](./acme_provider_guide.md) and
   [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md). The high-churn
   canonical validation loop relies on the retained-and-restored public-edge certificate so
   rebuilds do not re-order it.
8. The public-edge listener certificate is restored before issuance on every rebuild path
   (`prodbox cluster reconcile`, `prodbox charts reconcile`, and the substrate-platform installs):
   the reconciler reads the retained certificate from the long-lived `pulumi_state_backend`
   S3 bucket under its substrate-scoped key and re-materializes the cert-manager Secret before
   any ZeroSSL ACME issuance is attempted, so a cluster wipe never triggers a re-order against
   ZeroSSL. Because it lives in the long-lived bucket and is
   registered as a LongLived managed resource, the public-edge certificate survives cluster
   wipes (`prodbox cluster delete --cascade`) and is removed only by `prodbox nuke`, per
   [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md). Scheduled
   for adoption in Sprints 4.24 / 7.11 / 8.7.

Typical WebSocket drain flow is:

```text
1. Pod receives termination signal
2. Pod stops accepting new sockets
3. Existing sockets stay alive for a bounded drain period
4. Clients reconnect to another healthy pod
```

## 10. Recommended Migration and Adoption Path

The intended migration path from a legacy reverse-proxy edge is:

```text
Client -> Nginx -> Keycloak / Apps
```

to:

```text
Client -> MetalLB -> Envoy Gateway -> Keycloak / Apps
```

Recommended phases:

### Phase 1: Replace legacy edge routing with Envoy routing

- deploy MetalLB
- deploy Envoy Gateway
- expose Envoy Gateway through a Kubernetes `LoadBalancer` service
- route the shared-host `/auth` path to the Keycloak service
- route the other shared-host public path prefixes to application services
- keep application-managed OIDC first when that minimizes migration risk

### Phase 2: Add JWT validation for selected APIs

- configure Envoy to trust the Keycloak issuer metadata and JWKS
- require valid JWTs for selected API routes
- enforce issuer and audience
- add role, group, or scope checks where required

### Phase 3: Add edge OIDC for browser apps that need it

- use Envoy-managed login for apps that do not support OIDC
- keep app-managed OIDC for apps that need deeper identity integration

### Phase 4: Harden WebSocket behavior

- authenticate WebSocket connection requests at Envoy
- move presence and fanout state to Redis or another shared backend
- add reconnect and token-refresh behavior
- add graceful drain behavior for deploys

## 11. Diagnostics and Validation Doctrine

The supported public-edge diagnostic surface classifies:

1. Route 53 record ownership and public-IP sync
2. Envoy Gateway deployment readiness
3. `GatewayClass` acceptance
4. `Gateway` readiness and advertised addresses
5. `HTTPRoute` attachment and acceptance
6. Envoy Gateway policy attachment for protected routes
7. cert-manager certificate readiness
8. `LoadBalancer` IP agreement
9. external HTTPS reachability

The supported success state for `prodbox edge status` is
`CLASSIFICATION=ready-for-external-proof`.

Current named validation implications:

1. `prodbox test integration charts-vscode` proves the current Envoy-protected browser path.
2. `prodbox test integration public-dns` proves the explicit Route 53 and public-host contract.
3. `prodbox test integration charts-api` proves the shared-host Keycloak issuer plus JWKS
   contract, then proves unauthenticated rejection, wrong-claim rejection, and acceptance for the
   JWT-only API route on `/api`.
4. `prodbox test integration charts-websocket` proves workload-managed OIDC bootstrap on the
   shared hostname under `/ws/oidc`, real WebSocket upgrade, connection-time auth, shared-state
   continuity, cross-replica behavior, revocation-driven reconnect, and readiness-based drain,
   while token-expiry behavior remains workload-specific doctrine when required.
5. `prodbox test integration admin-routes` proves that Harbor and MinIO stay behind shared-host
   Envoy OIDC auth gates on `/harbor` and `/minio`.

## 12. Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
