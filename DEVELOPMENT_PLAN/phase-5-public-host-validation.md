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

## Sprint 5.1: Public Hostname Closure and Authoritative External Proof ✅

**Status**: Done
**Implementation**: `prodbox-config.dhall`, `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/infra/cluster_issuer.py`, `tests/integration/test_charts_vscode.py`, `tests/integration/test_public_dns_delegation.py`, `documents/engineering/helm_chart_platform_doctrine.md`
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

- `poetry run prodbox check-code` passed on April 12, 2026.
- `poetry run prodbox test unit` passed on April 12, 2026 (972 tests).
- The Route 53 real-system suite in `tests/integration/test_dns_route53_aws.py` passed during the
  canonical aggregate rerun on April 12, 2026.
- `poetry run prodbox test integration public-dns` passed on April 12, 2026 (2 tests) and remains
  the named automated public delegation proof path.
- `prodbox host public-edge` reports `CLASSIFICATION=ready-for-external-proof` with
  `ROUTE53_STATUS=in-sync`, `TRAEFIK_SERVICE_IP=192.168.2.240`, `CERTIFICATE_READY=true`, and
  `PRIVATE_EDGE_READY=true`.
- `kubectl get clusterissuer letsencrypt-http01 -o yaml` reports
  `spec.acme.server=https://acme.zerossl.com/v2/DV90`, `externalAccountBinding` configured, and
  `status.conditions[type=Ready].status=True`.
- `kubectl wait --for=condition=Ready certificate/vscode-tls -n vscode --timeout=300s` succeeded
  on April 12, 2026.
- Direct TLS verification for `vscode.resolvefintech.com:443` returns
  `SUBJECT_CN=vscode.resolvefintech.com`, `ISSUER_O=ZeroSSL GmbH`, and
  `ISSUER_CN=ZeroSSL RSA DV SSL CA 2`.
- `poetry run prodbox test integration charts-vscode` passed on April 12, 2026 (8 tests).

### Remaining Work

None.

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
