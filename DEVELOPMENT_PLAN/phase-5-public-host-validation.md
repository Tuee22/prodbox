# Phase 5: Public Hostname Closure and External Proof on the Haskell Stack

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the public-host diagnostic and named external proof path after the
> gateway, chart, and infrastructure ownership have moved to Haskell.

## Phase Summary

This phase defines the public DNS, TLS, public-edge, and external auth proof surfaces on the
Haskell stack. It preserves the existing public-host doctrine: external proof remains
external-only, explicit per-subdomain Route 53 records remain canonical, and `/etc/hosts`-based
closure remains unsupported. Sprints `5.1` and `5.2` remain closed on the Haskell-owned Gateway
API and Envoy-aware readiness proof. Sprint `5.3` now implements API plus WebSocket route
classification and named external proof while remaining active on aggregate validation closure.

## Current Baseline In Worktree

- `src/Prodbox/Host.hs` owns the public `prodbox host public-edge` surface. All Python host
  wrappers and duplicate report logic have been removed.
- Public-edge proof lives in the Haskell test suites under `test/`.
- The public-edge proof depends on the Harbor-first lifecycle and chart/runtime surfaces closed in
  earlier phases; this phase remains limited to the diagnostic and external proof contract.
- The current worktree derives public-edge readiness from Route 53, Envoy Gateway controller
  state, Gateway API readiness, certificate readiness, security-policy attachment, advertisement
  mode, and explicit external browser or API or WebSocket proof.
- The current diagnostic and proof surface covers the Keycloak identity route plus the `vscode`,
  `api`, and `websocket` public routes.

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
- Additional API and WebSocket hostnames now live in Sprint `5.3`, which remains active only on
  aggregate validation closure.

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
  configured public hostname through Route 53 plus public DNS resolution.
- `test/unit/Main.hs` and the built-frontend suites now align the public-edge fixtures with the
  Gateway API and dedicated-hostname contract.
- The current named public-edge proof surface now extends beyond the dedicated Keycloak identity
  route and `vscode` browser route to the dedicated API and WebSocket validations owned by Sprint
  `5.3`.

### Remaining Work

None.

## Sprint 5.3: API and WebSocket Public-Edge Proof 🔄

**Status**: Active
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Extend the Haskell-owned diagnostic and external proof surface from the current browser-only route
set to the full supported identity, browser, API, and WebSocket public edge.

### Deliverables

- `prodbox host public-edge` classifies dedicated identity, browser-app, API, and WebSocket routes
  on the supported Envoy Gateway edge.
- The public-edge diagnostic reports the active MetalLB advertisement mode and preserves the
  existing Route 53, certificate, and readiness classification contract.
- Named external validations prove the supported API and WebSocket routes in addition to the
  existing `charts-vscode` and `public-dns` browser or DNS proof surfaces.
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
8. Classification proof: the readiness payload covers the full route set and the configured
   advertisement mode without falling back to `Ingress` assumptions

### Current Validation State

- `src/Prodbox/Host.hs` now classifies dedicated identity, browser, API, and WebSocket routes,
  reports the active MetalLB advertisement mode, and proves per-route `SecurityPolicy`
  attachment.
- `src/Prodbox/TestValidation.hs` now proves the browser redirect path, JWT-protected API
  rejection and acceptance, Redis-backed WebSocket state continuity, and Route 53 resolution for
  every configured public host.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` now pass with the expanded public-edge proof surface in place.
- The latest `prodbox test all` run reached the supported-runtime bootstrap and stalled during the
  shared public-edge workload image build before the aggregate suite could return to the named API
  and WebSocket proofs.

### Remaining Work

- Complete aggregate runtime validation so `prodbox host public-edge`,
  `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and
  `prodbox test all` can finish through the shared public-edge workload image build and close the
  external-proof contract.

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
