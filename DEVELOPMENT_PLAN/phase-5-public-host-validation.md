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
closure remains unsupported. Sprint `5.1` remains the implemented Haskell public-edge baseline,
while Sprint `5.2` reopens this phase on Gateway API and Envoy-aware readiness proof.

## Current Baseline In Worktree

- `src/Prodbox/Host.hs` owns the public `prodbox host public-edge` surface. All Python host
  wrappers and duplicate report logic have been removed.
- Public-edge proof lives in the Haskell test suites under `test/`.
- The public-edge proof depends on the Harbor-first lifecycle and chart/runtime surfaces closed in
  earlier phases; this phase remains limited to the diagnostic and external proof contract.
- The current worktree still derives public-edge readiness from Traefik, `Ingress`, and
  certificate state. Sprint `5.2` reopens this phase to classify Envoy Gateway and Gateway API
  readiness instead.

## Sprint 5.1: Public Hostname Closure and External Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `test/unit/Main.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`
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

## Sprint 5.2: Gateway API Public-Edge Diagnostics and External Proof 📋

**Status**: Planned
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the Traefik and `Ingress` public-edge readiness model with Gateway API and Envoy Gateway
diagnostics while preserving explicit Route 53 proof and external-only validation.

### Deliverables

- `prodbox host public-edge` classifies Route 53, `Gateway`, `HTTPRoute`, certificate, and
  external-reachability state on the self-managed public edge.
- The public `charts-vscode` and `public-dns` proofs close on Envoy-authenticated browser delivery
  rather than the current `vscode-nginx` path.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.
- Wildcard public DNS remains unsupported.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`
6. Classification proof: the ready state is derived from Gateway API and Envoy Gateway state rather
   than `IngressClass` or `Ingress`

### Current Validation State

- The current implementation still inspects Traefik service IPs, `IngressClass`, `Ingress`, and
  `vscode-tls` certificate readiness.
- The external proof commands still exercise the current Traefik and `vscode-nginx` baseline.

### Remaining Work

- Replace the current Traefik and `Ingress` public-edge classification logic.
- Align external proof with the Envoy-authenticated browser path.
- Keep Route 53 and TLS proof explicit while the Gateway API edge replaces the current baseline.

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
