# Envoy Gateway Edge Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md), [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md), [../../DEVELOPMENT_PLAN/00-overview.md](../../DEVELOPMENT_PLAN/00-overview.md), [../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md), [README.md](./README.md), [cli_command_surface.md](./cli_command_surface.md), [distributed_gateway_architecture.md](./distributed_gateway_architecture.md), [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md), [local_registry_pipeline.md](./local_registry_pipeline.md), [unit_testing_policy.md](./unit_testing_policy.md)

> **Purpose**: Define the target public-edge doctrine for self-managed `prodbox` clusters: MetalLB,
> Envoy Gateway, Kubernetes Gateway API, Keycloak-backed edge authentication, and the optional
> Redis/WebSocket state model.

## 0. Canonical Doctrine Statements

The target public-edge doctrine for self-managed `prodbox` clusters is:

1. MetalLB exposes the cluster edge with a stable `LoadBalancer` IP on self-managed local clusters.
2. Envoy Gateway is the target public edge controller.
3. Kubernetes Gateway API resources own public Layer 7 routing.
4. cert-manager owns listener TLS material.
5. Keycloak remains the OIDC identity provider.
6. Envoy authenticates and authorizes public traffic at the edge for apps that do not natively own
   their own OIDC flow.
7. Supported browser-facing routes do not depend on application-local auth proxies such as
   `vscode-nginx`.
8. Supported public routing does not depend on Traefik or `Ingress`.
9. Redis is optional shared application infrastructure for realtime or rate-limit workloads; it is
   not part of Envoy JWT validation.

The target control-plane principle is:

```text
Keycloak authenticates.
Envoy enforces.
Apps serve.
Redis shares optional app state.
MetalLB exposes the entrypoint.
```

Envoy-managed browser authentication in this repository is expected to use Envoy Gateway
`SecurityPolicy`, which is an Envoy Gateway extension layered on top of Gateway API rather than a
plain upstream Gateway API capability.

## 1. Planning Ownership

This document owns the target public-edge doctrine only.

Implementation status, validation closure, and cleanup history are tracked in
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

This doctrine applies to the self-managed local-cluster path only. The repository's AWS validation
stacks remain separate validation surfaces and do not currently provision MetalLB or Envoy
Gateway.

This doctrine is intentionally distinct from the distributed Haskell gateway daemon documented in
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md):

- `prodbox gateway start|status|config-gen` refers to the Haskell in-cluster gateway daemon.
- Envoy Gateway refers to the Kubernetes Gateway API edge controller for public HTTP(S) traffic.

## 2. Current Worktree Baseline

The current repository closes on this doctrine.

Current implementation facts:

1. Local `prodbox rke2 install` installs Harbor, MinIO, MetalLB, Envoy Gateway, cert-manager,
   and the Percona PostgreSQL operator.
2. The public `vscode` route uses Gateway API `HTTPRoute` resources plus Envoy Gateway
   `SecurityPolicy`.
3. Keycloak publishes the browser login flow on the dedicated hostname from
   `domain.keycloak_fqdn`.
4. `prodbox host public-edge` classifies Route 53, Envoy Gateway deployment, `GatewayClass`,
   `Gateway`, `HTTPRoute`, `SecurityPolicy`, certificate, and `LoadBalancer` state.

## 3. Target Public-Edge Topology

The target self-managed public edge is:

```text
Internet
  -> Router port-forward
  -> MetalLB-assigned LoadBalancer IP
  -> Envoy service managed by Envoy Gateway
  -> Gateway API resources
  -> Backend Kubernetes Services
  -> Pods
```

The target resource model is:

1. a cluster-level `GatewayClass` owned by Envoy Gateway
2. one or more `Gateway` resources for public listeners
3. `HTTPRoute` resources attached to those listeners
4. `SecurityPolicy` resources attached to `Gateway` or `HTTPRoute`
5. cert-manager-managed TLS secrets referenced by Gateway listeners

The supported DNS doctrine remains explicit per-FQDN Route 53 ownership. Wildcard public DNS is
not part of the supported architecture.

The target public-host model prefers separate hostnames for identity and application routes:

- a dedicated public Keycloak hostname
- one hostname per browser-facing app
- additional API or WebSocket hostnames only when a workload needs them

## 4. Authentication Doctrine

Keycloak remains the identity provider.

Keycloak owns:

1. browser login
2. user, group, role, and client management
3. OIDC issuer metadata
4. token issuance and signing
5. identity and session persistence in PostgreSQL

Envoy Gateway owns:

1. TLS termination at the edge
2. Gateway API route attachment
3. OIDC login enforcement for browser apps that do not own their own OIDC flow well
4. JWT validation for token-bearing API routes
5. route-level or listener-level auth policy attachment through `SecurityPolicy`

Application workloads own:

1. application behavior after successful authentication
2. fine-grained per-request or per-message authorization that Envoy cannot infer from route
   metadata alone
3. any app-specific session or collaboration semantics that must survive reconnects

The target `vscode` doctrine is:

1. `code-server` does not own the public OIDC browser flow directly.
2. Envoy Gateway enforces browser authentication in front of the workload.
3. Keycloak remains the OIDC provider.
4. No supported long-term `vscode` architecture depends on `vscode-nginx`.

For API routes, Envoy may validate JWTs without taking over the full interactive browser login
flow.

## 5. Redis, WebSocket, and Realtime-State Doctrine

Redis is optional shared application infrastructure.

It is appropriate for:

1. WebSocket presence state
2. pub/sub fanout
3. shared ephemeral app state
4. distributed locks
5. external rate-limit backends

It is not part of Envoy JWT validation. Envoy validates JWTs from Keycloak locally from issuer
metadata and signing keys.

The public-edge doctrine for WebSockets is:

1. Envoy authenticates at connection setup time.
2. Envoy proxies the upgraded connection to one selected backend pod.
3. The backend application owns message-level authorization.
4. Long-lived connection recovery, token-expiry handling, and reconnect semantics must be designed
   explicitly by the application surface.

If a workload needs reconnect-safe shared state, that state must live outside the pod. Redis is the
default optional doctrine for that class of state, but only when the workload actually needs it.

The current repository does not yet ship a Redis-backed application stack. This doctrine exists to
guide the target edge and future workload shape, not to overclaim current implementation.

## 6. Lifecycle, Chart, and Image-Delivery Implications

Supported lifecycle implications:

1. `prodbox rke2 install` installs MetalLB, Envoy Gateway, cert-manager, and the Percona
   PostgreSQL operator for the self-managed public edge.
2. Harbor-backed steady-state image sourcing mirrors or publishes Envoy Gateway control-plane and
   Envoy data-plane images rather than Traefik images.
3. No supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
4. The Haskell distributed gateway daemon remains a separate chart and runtime surface; this
   doctrine does not replace it with Envoy Gateway.

Supported chart implications:

1. `vscode` public delivery routes through Gateway API resources.
2. Keycloak remains a chart-managed workload with a dedicated public identity host.
3. The chart platform no longer treats an app-local nginx auth proxy as a permanent supported
   dependency for `vscode`.
4. Optional Redis belongs only to workloads that actually need shared realtime state.

## 7. Diagnostics and Validation Doctrine

The supported public-edge diagnostic surface classifies:

1. Route 53 record ownership and IP sync
2. `Gateway` listener readiness and advertised addresses
3. `HTTPRoute` attachment and acceptance
4. Envoy Gateway policy attachment for protected routes
5. cert-manager certificate readiness
6. external HTTPS reachability

The supported success state for `prodbox host public-edge` is the canonical ready classification
derived from Gateway API and Envoy Gateway state.

Named validation implications:

1. `prodbox test integration charts-vscode` proves the Envoy-protected browser path.
2. `prodbox test integration public-dns` proves the Gateway API public host contract.
3. If future app stacks expose WebSockets, they need named validation that proves connection-time
   auth, reconnect behavior, and any required shared-state backend assumptions.

## 8. Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Documentation Standards](../documentation_standards.md)
