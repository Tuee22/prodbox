# Phase 5: Public Hostname Closure and External Proof on the Haskell Stack

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the public-host diagnostic and named external proof path after the
> gateway, chart, and infrastructure ownership have moved to Haskell.

## Phase Summary

This phase defines the public DNS, TLS, public-edge, and external auth proof surfaces on the
Haskell stack. It keeps external proof external-only and keeps `/etc/hosts`-based closure
unsupported, but the supported public-host doctrine now changes from explicit per-subdomain Route
53 records to one canonical hostname: `test.resolvefintech.com`. Sprints `5.1` and `5.2` remain
closed on the Haskell-owned Gateway API and Envoy-aware readiness proof baseline. Sprint `5.3` is
active because the browser, API, WebSocket, and Keycloak proof surfaces now move to shared-host
paths on one Route 53 record and one certificate. Sprint `5.4` is active because operational
dashboards must also be proven through that same shared-host edge.

## Current Baseline In Worktree

- `src/Prodbox/Host.hs` owns the public `prodbox host public-edge` surface. All Python host
  wrappers and duplicate report logic have been removed.
- Public-edge proof lives in the Haskell test suites under `test/`.
- The public-edge proof depends on the Harbor-first lifecycle and chart/runtime surfaces closed in
  earlier phases; this phase remains limited to the diagnostic and external proof contract.
- The current worktree derives public-edge readiness from Route 53, Envoy Gateway controller
  state, Gateway API readiness, certificate readiness, security-policy attachment, advertisement
  mode, and explicit external browser or API or WebSocket proof.
- The current diagnostic and proof surface still covers the dedicated Keycloak identity route plus
  the `vscode`, `api`, and `websocket` public routes. That route split is now legacy
  implementation only.
- The current API proof exercises request-carried JWT validation on the dedicated API route, while
  the browser proof still follows the Envoy-managed redirect and cookie or session path while the
  direct-OIDC path on the current `websocket` host now exercises the workload-owned session
  boundary with Phase `3` still owning aggregate rerun closure.
- The current proof surface now covers the supported direct-OIDC workload path and the Keycloak
  proxy-aware identity-host contract, but the target doctrine is shared-host issuer and redirect
  behavior on `test.resolvefintech.com`.
- The current `charts-websocket` proof now exercises the real WebSocket upgrade path, long-lived
  socket lifetime, revocation-driven reconnect, and readiness-based drain on the WebSocket host.
- Operational dashboards are not yet closed on the public proof surface; Sprint `5.4` owns those
  validations.
- The current proof surface intentionally closes on Envoy listener TLS and route behavior only;
  backend TLS or mTLS is outside the current supported chart-workload contract and is not claimed
  by this phase.

## Sprint 5.1: Public Hostname Closure and External Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the implemented public DNS and public-edge path on the Haskell runtime that owns it.

### Deliverables

- `prodbox host public-edge` is implemented in Haskell and preserves the supported diagnostic
  classification contract.
- Public DNS delegation, live HTTPS reachability, TLS issuance, and auth redirects are proven
  through Haskell-owned command surfaces.
- The external proof path remains cluster-external and does not depend on manual kubeconfig
  workflows.
- Wildcard public DNS remains unsupported.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`

### Current Validation State

- `src/Prodbox/Host.hs` now owns the public `prodbox host public-edge` surface and preserves the
  supported readiness-report fields and classification contract.
- `src/Prodbox/TestRunner.hs` now uses the native Haskell `host public-edge` command directly
  inside the supported-runtime bootstrap and postflight checks.
- `test/unit/Main.hs` proves parser routing for native `host public-edge`.
- The named validation commands `prodbox test integration charts-vscode` and
  `prodbox test integration public-dns` now run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- Environment-dependent public-edge success remains owned by those commands rather than asserted
  here as a fresh run result.
### Remaining Work

None.

## Sprint 5.2: Gateway API Public-Edge Diagnostics and External Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep public-edge readiness on Gateway API and Envoy Gateway diagnostics with explicit Route 53
proof and external-only validation.

### Deliverables

- `prodbox host public-edge` classifies Route 53, `Gateway`, `HTTPRoute`, certificate, and
  external-reachability state on the self-managed public edge.
- The public `charts-vscode` and `public-dns` proofs close on Envoy-authenticated browser delivery
  rather than the retired `vscode-nginx` path.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.
- Wildcard public DNS remains unsupported.
- Additional API and WebSocket hostnames now live in Sprint `5.3`, which remains active because
  the WebSocket-host proof surface still has to follow the remaining Phase `3` runtime work.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`
6. Classification proof: the ready state is derived from Gateway API and Envoy Gateway state rather
   than `IngressClass` or `Ingress`

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the public edge through Route 53 record sync, Envoy Gateway
  deployment readiness, `GatewayClass` acceptance, `Gateway` readiness, `HTTPRoute` attachment,
  `SecurityPolicy` attachment, certificate readiness, and `LoadBalancer` IP agreement.
- `src/Prodbox/TestValidation.hs` now waits for `CLASSIFICATION=ready-for-external-proof`, proves
  the external `vscode` path through the Envoy-to-Keycloak redirect, and validates every
  configured public-edge hostname through Route 53 plus public DNS resolution.
- `test/unit/Main.hs` and the built-frontend suites now align the public-edge fixtures with the
  Gateway API baseline that later single-host work refines.
- The current named public-edge proof surface now extends beyond the current Keycloak identity
  route and `vscode` browser route to the API and WebSocket validations owned by Sprint `5.3`.

### Remaining Work

None.

## Sprint 5.3: API and WebSocket Public-Edge Proof 🔄

**Status**: Active
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Extend the Haskell-owned diagnostic and external proof surface from the current dedicated-host
implementation to the shared-host doctrine on `test.resolvefintech.com`, covering browser, API,
WebSocket, and Keycloak paths on one public edge.

### Deliverables

- `prodbox host public-edge` classifies shared-host browser, API, WebSocket, and Keycloak paths on
  the supported Envoy Gateway edge.
- The public-edge diagnostic reports the active MetalLB advertisement mode and preserves the
  existing Route 53, certificate, and readiness classification contract on one public hostname.
- Named external validations prove the supported API route on the explicit request-token and
  local-JWKS doctrine, and prove the supported WebSocket route in addition to the existing
  `charts-vscode` and `public-dns` browser or DNS proof surfaces.
- Named external validations prove the supported Keycloak public-host contract, including
  issuer and redirect alignment on the shared hostname, forwarded-header compatibility, and no
  accidental public management or health route exposure.
- Named external validations prove the supported WebSocket connection-lifetime contract, including
  one upgraded connection per selected backend pod until disconnect and readiness-based drain
  before pod exit through the runtime surface owned by Sprint `3.6`.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration charts-api`
6. `prodbox test integration charts-websocket`
7. `prodbox test integration public-dns`
8. Classification proof: the readiness payload covers the full shared-host route set and the
   configured advertisement mode without falling back to `Ingress` assumptions
9. Behavioral proof: the WebSocket validation uses the real upgrade path, proves the
   one-upgraded-connection-per-backend-pod lifetime until disconnect, and checks readiness-based
   drain rather than only HTTP helper endpoints on that route
10. Identity proof: Keycloak-backed public workloads use the shared hostname for issuer and
    redirect flows, the browser auth path stays on explicit redirect and cookie assumptions, and
    unsupported management or health paths are not publicly routed

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the current dedicated identity, browser, API, and
  WebSocket routes, reports the active MetalLB advertisement mode, and proves per-route
  `SecurityPolicy` attachment; Sprint `5.3` now replaces that route split with shared-host path
  classification.
- `src/Prodbox/TestValidation.hs` now proves the browser redirect path, JWT-protected API
  rejection and acceptance on the request-carried JWT path, the current Keycloak identity-host
  redirect and issuer contract, workload-managed direct-OIDC session ownership on the WebSocket
  host, real WebSocket upgrade behavior, and Route 53 resolution for every configured public
  host.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` now pass with the expanded public-edge proof surface plus the
  current custom-image rebuild or pull fix in place.
- The remaining public-edge auth-path closure now depends on moving those proofs to the shared
  hostname and then rerunning the canonical suite.

### Remaining Work

- Move public-edge classification and proof from dedicated hostnames to the shared
  `test.resolvefintech.com` route set.
- Rerun aggregate runtime validation from the updated tree so `prodbox host public-edge`,
  `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and
  `prodbox test all` close on the single-host doctrine.

## Sprint 5.4: Shared-Host Admin-Route Proof 🔄

**Status**: Active
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove that operational dashboards such as Harbor, MinIO, and supported PostgreSQL administration
surfaces are reachable only through Envoy on `test.resolvefintech.com`, protected by
Keycloak-backed auth and RBAC.

### Deliverables

- `prodbox host public-edge` classifies the supported admin paths on the shared hostname.
- Named external validations prove auth and RBAC on the supported admin routes.
- The external proof surface preserves the one-DNS or one-cert doctrine as admin coverage grows.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration public-dns`
5. Named admin-route validations

### Current Validation State

- The current proof surface does not yet close on shared-host admin routes.
- Harbor, MinIO, and supported PostgreSQL administration surfaces therefore still need explicit
  route classification and external proof ownership.

### Remaining Work

- Add shared-host admin-route classification to `prodbox host public-edge`.
- Add named external validations for the supported admin surfaces.
- Keep admin-route proof external-only and aligned with the one-host DNS or certificate doctrine.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - external proof and AWS access
  doctrine after the Haskell rewrite.
- `documents/engineering/aws_test_environment.md` - shared AWS validation-environment doctrine for
  the Haskell public-host proof path.
- `documents/engineering/cli_command_surface.md` - supported public-host validation commands.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Gateway API and Envoy public-edge
  doctrine.
- `documents/engineering/helm_chart_platform_doctrine.md` - public-host behavior of the rewritten
  `vscode` stack.
- `documents/engineering/unit_testing_policy.md` - external-only public-host validation doctrine.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep public-host closure linked back to [README.md](README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
