# File: DEVELOPMENT_PLAN/phase-5-public-host-validation.md
# Phase 5: Public Hostname Closure and Authoritative External Proof

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the live public-host closure work for `vscode.resolvefintech.com` and the
> named authoritative external proof path that validates DNS, TLS, ingress, and auth behavior.

## Phase Summary

This phase closes the live public DNS and ingress path for `vscode.resolvefintech.com` and makes
authoritative external proof part of the canonical automated validation path without reintroducing
cluster-gated operator workflows.

## Sprint 5.1: Public Hostname Closure and Authoritative External Proof ⏸️

**Status**: Blocked
**Implementation**: `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py`, `documents/engineering/helm_chart_platform_doctrine.md`
**Blocked by**: Sprint 4.3 and Sprint 4.4
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the live public DNS and ingress path for `vscode.resolvefintech.com` and make authoritative
external proof part of the canonical automated validation path.

### Deliverables

- Public DNS resolution, live HTTPS reachability, TLS issuance, authoritative delegation, and
  Keycloak redirect behavior are all proven on the public host.
- The supported public path resolves through explicit named Route 53 records only; wildcard public
  DNS is not part of the supported architecture.
- The public-host validation path stays external-only: no kubeconfig, cluster prerequisite gate, or
  `rke2 ensure` runbook is required.
- Manual-only authoritative delegation proof is replaced by a named automated suite.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration dns-aws`
4. `poetry run prodbox test integration charts-vscode`
5. `poetry run prodbox test integration public-dns`

### Current Validation State

- `poetry run prodbox test integration charts-vscode` no longer imposes cluster prerequisites or an
  `rke2 ensure` runbook.
- `poetry run prodbox test integration public-dns` is now the named automated public delegation
  proof path.
- `poetry run prodbox charts deploy vscode` succeeds on the canonical chart path.
- Public NS lookups return the expected Route 53 authoritative name servers.
- `prodbox host public-edge` now exists as the named preflight command that distinguishes
  authoritative-DNS state, ingress-class drift, certificate readiness, and cluster-edge ownership
  before the external proof suites run.
- `poetry run prodbox test integration charts-platform` passed on April 6, 2026, so the remaining
  public-host breakage is now outside the namespace-local chart stack itself.
- `poetry run prodbox test integration charts-vscode` currently fails all eight HTTPS/TLS/auth
  probes with TCP timeouts to `https://vscode.resolvefintech.com`.
- `poetry run prodbox test integration public-dns` passed on April 9, 2026 (2 tests) after IAM
  policy `prodbox-integration-tests` was attached to `bathurst-resolvefintech-dns`.
- `poetry run prodbox test integration dns-aws` passed on April 9, 2026 (2 tests).
- Public-host closure is still blocked until router port forwarding is updated (ports 80/443 to
  MetalLB `192.168.2.240`), Let's Encrypt cert issuance completes, and `charts-vscode` passes.

### Remaining Work

- Close Sprint 4.3 (router port forwarding and cert issuance) and Sprint 4.4 (gateway host
  supervision) so the live environment matches the repo-local implementation.
- Restore live HTTP and HTTPS reachability for `vscode.resolvefintech.com` so requests resolve to
  the current WAN IP and reach the canonical `Traefik -> vscode-nginx -> Keycloak` path.
- Rerun `poetry run prodbox test integration charts-vscode` once the public HTTPS path is live.
- Close the sprint only after public DNS, TLS, and Keycloak redirect behavior all pass from the
  canonical external-only test path with explicit named Route 53 records and no wildcard DNS.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - authoritative public-DNS proof
  and required AWS access.
- `documents/engineering/cli_command_surface.md` - supported public-host validation commands.
- `documents/engineering/helm_chart_platform_doctrine.md` - public-host `vscode` behavior and auth
  boundary.
- `documents/engineering/unit_testing_policy.md` - external-only public-host validation doctrine.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep public-host closure status and blockers pointed at `DEVELOPMENT_PLAN/README.md`.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
