# Phase 5: Public Hostname Closure and External Proof on the Haskell Stack

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md)

> **Purpose**: Capture the live public-host closure work and the named external proof path after the
> gateway, chart, and infrastructure ownership have moved to Haskell.

## Phase Summary

This phase re-proves the public DNS, TLS, ingress, and external auth path through Haskell-only
surfaces. It preserves the existing public-host doctrine: external proof remains external-only,
explicit per-subdomain Route 53 records remain canonical, and `/etc/hosts`-based closure remains
unsupported.

## Sprint 5.1: Public Hostname Closure and External Proof on the Haskell Stack 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Host.hs`, `src/Prodbox/Infra/Ingress.hs`, `src/Prodbox/Infra/CertManager.hs`, `test/integration/public_host/`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the public DNS and ingress path again after the Haskell rewrite has replaced the runtime that
owns it.

### Deliverables

- `prodbox host public-edge` is implemented in Haskell and preserves the supported diagnostic
  classification contract.
- Public DNS delegation, live HTTPS reachability, TLS issuance, and auth redirects are proven on
  the Haskell stack.
- The external proof path remains cluster-external and does not depend on manual kubeconfig
  workflows.
- Wildcard public DNS remains unsupported.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`

### Remaining Work

- All deliverables remain open.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - external proof and AWS access
  doctrine after the Haskell rewrite.
- `documents/engineering/cli_command_surface.md` - supported public-host validation commands.
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
