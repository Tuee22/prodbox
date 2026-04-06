# prodbox Development Plan

**Status**: Active - clean-room build plan authoritative as of 2026-04-03;
Sprint 7 is complete, Sprints 8 and 9 are blocked by external validation or
reachability dependencies, and Sprint 10 has not started

This file is the sole source of truth for development sequencing, completion
status, blockers, validation closure, and legacy-path removal across the
repository.

Documents under `documents/` are stable doctrine and reference only. They must
not carry competing sprint narratives, phase histories, or completion-status
tracking.

Although root `UPPER_CASE_PLAN.md` files are exempt from
[documents/documentation_standards.md](./documents/documentation_standards.md),
this plan intentionally follows the same ownership and non-duplication
discipline.

## Planning Doctrine

1. Sprint order in this file is the intended clean-room build order, not the
   historical commit order.
2. Prefer one canonical runtime path, one canonical CLI path, and one canonical
   automated validation path per surface.
3. Backward-compatibility shims, duplicate operator flows, and transitional
   naming are debt to remove, not surfaces to preserve.
4. Status vocabulary is exact:
   - `Not Started`: no sprint-owned closure work has landed yet.
   - `In Progress`: sprint-owned work is underway, but the resulting surface is
     still too incomplete to call partially complete.
   - `Partially Complete`: the primary implementation exists, but required
     docs, validation, or legacy removal are still open.
   - `Blocked`: only an external dependency, credential, or routing/control
     outside this repository remains between the current state and closure.
   - `Complete`: scope, doctrine updates, automated validation, and
     sprint-owned legacy removal are all done.
5. A sprint closes only when its scope, documentation ownership updates,
   automated validation, and sprint-owned legacy removals are all complete.
6. Every sprint that changes doctrine-owned behavior must list the owning
   documents to update under `documents/` and keep them aligned with
   [documents/documentation_standards.md](./documents/documentation_standards.md).
7. Every sprint must define the automated validation required for closure.
   Manual checks are allowed only for controls that live outside this
   repository, and those manual steps must be called out explicitly as
   unresolved closure work until they are automated or eliminated.
8. If a second path, compatibility shim, or transitional surface is discovered,
   add it to the legacy inventory in this file before implementing around it.
9. This plan distinguishes:
   - repository state: what is implemented and intended to exist
   - current-environment rerun blockers: what cannot be revalidated in the
     present operator environment

## Current Repository State

Completed and present in the repository:

- This plan now owns repository-wide status, blocker, and legacy-removal
  tracking.
- Runtime and CLI foundations exist: explicit Click command groups, command
  ADTs, eDAG builders, interpreter execution, named test suites, and
  documentation-topology guard coverage.
- Real-system validation exists for AWS foundation, EKS, Route 53, Pulumi,
  gateway process mode, gateway pod mode, chart storage/platform, and runtime
  lifecycle behavior.
- Distributed gateway implementation exists with `prodbox gateway`
  management commands, TLA+ artifacts, unit coverage, and Kubernetes
  integration suites.
- `prodbox charts` exists as a first-class capability with deterministic
  retained storage rooted at `.data/<namespace>/<statefulset>/<ordinal>`.
- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack exists,
  and the supported cluster auth model is nginx OIDC plus local Keycloak users.
- `prodbox rke2 cleanup --yes` uses namespace-first cleanup and preserves
  retained storage kinds for deterministic rebind.
- The lifecycle suite now reruns cleanup and re-ensure without a post-cleanup
  retry shim and passes from the canonical CLI path.
- Gateway startup is canonical through `prodbox gateway start`; the legacy
  Poetry `daemon` entrypoint and direct daemon wrapper path are gone.
- Route 53 ownership/update is canonical through gateway `dns_write_gate`; the
  old CLI/DDNS timer path and repo-tracked systemd units are gone.
- The interpreter and summary layer expose one canonical structured DAG outcome
  model without the old command-summary compatibility bridge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override,
  and `Settings()` reads `.env` only from the fixed repository root.
- The canonical certificate path is Let's Encrypt HTTP-01 through
  `letsencrypt-http01`.
- The external public-host `charts-vscode` suite now runs without cluster
  prerequisite gates or an `rke2 ensure` preflight.
- The authoritative public DNS delegation proof now exists as
  `poetry run prodbox test integration public-dns`.
- Hook-oriented `pre-commit` dev dependency and config residue are gone.

Open, incomplete, or blocked:

- Public-host closure for `vscode.resolvefintech.com` is not complete because
  public DNS resolution exists, but HTTP/HTTPS requests to the hostname still
  time out before reaching the canonical ingress path.
- Sprint 8 closure is blocked in the current AWS environment because the active
  identity still cannot rerun the authoritative `dns-aws`, `pulumi`, and
  `public-dns` validations against the configured hosted zone path.
- A full clean-room rerun that ends with zero remaining legacy items has not
  been completed.

Current-environment rerun blockers:

- `poetry run prodbox test integration dns-aws` is blocked in the current AWS
  environment because the active identity lacks `route53:CreateHostedZone`.
- `poetry run prodbox pulumi up --yes` is blocked in the current AWS
  environment because the active identity lacks `route53:GetHostedZone` for the
  demo hosted zone path.
- `poetry run prodbox test integration public-dns` is blocked in the current
  AWS environment because the active identity lacks `route53:GetHostedZone` for
  `ROUTE53_ZONE_ID`.
- Sprint 9 closure remains blocked by external edge routing, NAT, firewall, or
  port-forwarding outside this repository.

## Legacy Inventory

### Removed

- Public commands that reported success without performing their documented
  behavior
- Placeholder prerequisites implemented as unconditional `Pure(True)`
- Raw pytest passthrough from the public `prodbox test` surface
- Undocumented command-surface side paths that drifted from the Click matrix
- Cross-namespace chart composition
- Chart-authored `PersistentVolume` creation
- `oauth2-proxy` and Google OAuth as the supported `vscode` auth path
- Stale oauth2/google auth naming in chart metadata and chart-storage fixture
  input
- `CleanupProdboxAnnotatedResources.cleanup_passes`
- The old multi-pass `_collect_annotated_refs` / `_delete_ref` cleanup strategy
- Unsupported `docker/vscode-dev` repository files
- Competing implementation-status and phase-history narratives in doctrine docs
- `rke2_killall_exists` prerequisite
- `daemon` Poetry entrypoint alongside `prodbox gateway start`
- CLI/DDNS timer Route 53 path alongside gateway `dns_write_gate`
- Cluster-gated `charts-vscode` invocation for an external public-host suite
- Interpreter command-summary compatibility bridge
- Hook-oriented `pre-commit` workflow residue
- Retry-as-settling behavior in lifecycle validation after cleanup
- Manual-only authoritative public DNS delegation proof

### Remaining To Remove

None.

No other repo-internal legacy paths are currently identified.

## Sprint Table

| Sprint | Status | Depends on | Summary |
|--------|--------|------------|---------|
| 1 | Complete | none | Establish the plan as the sole status source and align doctrine docs with documentation standards |
| 2 | Complete | 1 | Establish runtime, CLI, and named test-command foundations |
| 3 | Complete | 1, 2 | Establish AWS auth doctrine and authoritative real-system validation foundations |
| 4 | Complete | 2, 3 | Deliver distributed gateway runtime, formal verification, and DNS-write capability |
| 5 | Complete | 2, 3 | Deliver the chart platform and deterministic retained storage |
| 6 | Complete | 5 | Deliver the cluster-backed `vscode` stack and canonical in-cluster auth path |
| 7 | Complete | 2, 3, 5 | Harden `rke2 cleanup` and lifecycle validation until no settling shim remains |
| 8 | Blocked | 1, 2, 3, 4, 5, 6, 7 | Remove remaining duplicate/operator-compatibility paths and leave one canonical surface per capability |
| 9 | Blocked | 6, 8 | Close the live public hostname path and automate authoritative external proof |
| 10 | Not Started | 7, 8, 9 | Rerun the full clean-room validation set and hand off with zero legacy backlog |

## Sprint 1: Planning And Documentation Topology Baseline

Status: Complete

Depends on: none

Goal:

- Make this file the only repository-wide tracker for sequencing, blockers,
  completion state, and legacy removal.

Scope:

- Remove competing implementation-history or completion-status narratives from
  doctrine docs.
- Align touched docs with
  [documents/documentation_standards.md](./documents/documentation_standards.md).

Documentation owners to update:

- [DEVELOPMENT_PLAN.md](./DEVELOPMENT_PLAN.md)
- [documents/documentation_standards.md](./documents/documentation_standards.md)
- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/distributed_gateway_architecture.md](./documents/engineering/distributed_gateway_architecture.md)
- [documents/engineering/dependency_management.md](./documents/engineering/dependency_management.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`

Closure outcomes:

1. No document under `documents/` carries a competing sprint, phase, or
   completion-status narrative.
2. Touched docs retain required metadata, backlink hygiene, and
   non-duplication discipline.
3. This plan owns repository-wide complete, incomplete, blocked, and
   legacy-removal state.

Sprint-owned legacy removed:

- Competing implementation-status narratives in doctrine docs

## Sprint 2: Runtime, CLI, And Test-Command Foundations

Status: Complete

Depends on: Sprint 1

Goal:

- Establish one explicit public CLI surface and one explicit named test-command
  surface.

Scope:

- Remove inert runtime placeholders and prerequisite shortcuts.
- Reconcile the documented Click surface with the implemented core CLI.
- Enforce explicit named test suites and command-surface ownership.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/prerequisite_doctrine.md](./documents/engineering/prerequisite_doctrine.md)
- [documents/engineering/unit_testing_policy.md](./documents/engineering/unit_testing_policy.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration env`

Closure outcomes:

1. No documented public command or option is inert.
2. `prodbox test` exposes named suites only.
3. Documentation anchors, backlinks, and click-passthrough rules are enforced
   by automation.

Sprint-owned legacy removed:

- Runtime placeholders
- Unconditional prerequisite success paths
- Undocumented CLI passthrough behavior

## Sprint 3: AWS Auth Doctrine And Real-System Validation Foundation

Status: Complete

Depends on: Sprints 1 and 2

Goal:

- Establish one canonical AWS auth source and authoritative real-system
  validation for AWS-backed surfaces.

Scope:

- Lock repository-root `.env` AWS-auth doctrine for stateful integration runs.
- Add and stabilize named AWS, Route 53, and Pulumi real-system suites.
- Make teardown and cleanup validation explicit rather than implied.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/aws_integration_environment_doctrine.md](./documents/engineering/aws_integration_environment_doctrine.md)
- [documents/engineering/aws_test_environment.md](./documents/engineering/aws_test_environment.md)
- [documents/engineering/integration_fixture_doctrine.md](./documents/engineering/integration_fixture_doctrine.md)
- [documents/engineering/unit_testing_policy.md](./documents/engineering/unit_testing_policy.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration aws-foundation`
4. `poetry run prodbox test integration aws-eks`
5. `poetry run prodbox test integration dns-aws`
6. `poetry run prodbox test integration pulumi`

Closure outcomes:

1. AWS-mutating suites use repository `.env` credentials plus fixture-owned
   ephemeral resources only.
2. AWS-backed suites fail hard on teardown cleanup failures.
3. Pulumi integration runs against an isolated local backend plus a
   fixture-owned hosted zone.

Sprint-owned legacy removed:

- Ambient/shared-profile AWS auth assumptions
- Unnamed high-risk AWS real-system validation
- Implicit cleanup assumptions for AWS suites

## Sprint 4: Distributed Gateway Runtime, Formal Verification, And DNS-Write Capability

Status: Complete

Depends on: Sprints 2 and 3

Goal:

- Ship the distributed gateway daemon, its managed CLI surface, and formal
  verification entrypoint.

Scope:

- Deliver `prodbox gateway start|status|config-gen`.
- Validate both process-mode mesh behavior and pod-backed mesh behavior.
- Expose TLA+ model-checking through the CLI.
- Deliver gateway Route 53 write capability through `dns_write_gate`.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/distributed_gateway_architecture.md](./documents/engineering/distributed_gateway_architecture.md)
- [documents/engineering/tla/README.md](./documents/engineering/tla/README.md)
- [documents/engineering/tla_modelling_assumptions.md](./documents/engineering/tla_modelling_assumptions.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration gateway-daemon`
4. `poetry run prodbox test integration gateway-pods`
5. `poetry run prodbox tla-check`

Closure outcomes:

1. `prodbox gateway start|status|config-gen` exists as the managed CLI surface.
2. The daemon implementation, unit tests, and both gateway integration suites
   are present in the repository.
3. TLA+ model-checking is exposed through `prodbox tla-check`.
4. The gateway runtime supports Route 53 writes through `dns_write_gate`.

Sprint-owned legacy removed:

- None; compatibility-path removal for adjacent gateway surfaces is owned by
  Sprint 8

## Sprint 5: Chart Platform And Deterministic Retained Storage

Status: Complete

Depends on: Sprints 2 and 3

Goal:

- Deliver one canonical chart-lifecycle platform with deterministic retained
  storage.

Scope:

- Define the canonical `prodbox charts list|status|deploy|delete` surface.
- Deliver deterministic CLI-owned chart storage under
  `.data/<namespace>/<statefulset>/<ordinal>`.
- Deliver end-to-end chart integration suites for retained storage and stack
  deploy/delete behavior.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)
- [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration charts-storage`
4. `poetry run prodbox test integration charts-platform`

Closure outcomes:

1. `prodbox charts` is implemented through Click -> ADT -> eDAG -> interpreter.
2. The only supported bespoke charts are the ones registered in
   `src/prodbox/lib/chart_platform.py`.
3. No tracked chart manifest creates a `PersistentVolume`.
4. Delete and redeploy preserve deterministic PV/PVC rebinding on the same
   retained host paths.

Sprint-owned legacy removed:

- Undocumented chart scaffolding
- Cross-namespace chart composition
- Chart-authored PV creation

## Sprint 6: `vscode` Stack And Canonical Cluster Auth Path

Status: Complete

Depends on: Sprint 5

Goal:

- Deliver the supported cluster-backed `vscode` stack and one canonical
  in-cluster auth path.

Scope:

- Ship the namespace-local `keycloak-postgres -> keycloak -> vscode` stack.
- Make nginx OIDC plus local Keycloak username/password the supported auth
  model.
- Remove unsupported non-cluster local-dev delivery content from the
  repository.
- Defer live public-host closure to Sprint 9.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration charts-platform`

Closure outcomes:

1. The namespace-local `keycloak-postgres -> keycloak -> vscode` stack exists.
2. `KEYCLOAK_NGINX_CLIENT_SECRET` is the intended shared auth-secret setting.
3. Unsupported local `docker/vscode-dev` file content is gone.
4. Public-host closure is explicitly owned by Sprint 9, not this sprint.

Sprint-owned legacy removed:

- `oauth2-proxy`
- Google OAuth as the supported identity-provider path
- Stale oauth2/google auth terminology in chart metadata and chart-storage
  inputs
- Unsupported `docker/vscode-dev` file content

## Sprint 7: `rke2 cleanup` Hardening And Lifecycle Regression Closure

Status: Complete

Depends on: Sprints 2, 3, and 5

Goal:

- Make `rke2 cleanup` stable enough that the lifecycle suite does not need
  retry-based settling.

Scope:

- Replace the multi-pass cleanup implementation with a namespace-first cascade
  flow.
- Preserve retained kinds (`PersistentVolume`, `StorageClass`,
  `PersistentVolumeClaim`) by doctrine.
- Prove first-attempt cleanup success and retained-storage rebind without a
  cleanup-settling shim.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/integration_fixture_doctrine.md](./documents/engineering/integration_fixture_doctrine.md)
- [documents/engineering/prerequisite_doctrine.md](./documents/engineering/prerequisite_doctrine.md)
- [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration lifecycle`

Closure outcomes:

1. `CleanupProdboxAnnotatedResources` no longer exposes `cleanup_passes`.
2. The interpreter no longer relies on `_collect_annotated_refs` /
   `_delete_ref` multi-pass deletion during namespace termination.
3. Namespace-scoped resources are deleted by namespace cascade before
   cluster-scoped cleanup.
4. The lifecycle suite proves retained storage still rebinds after cleanup and
   re-ensure without retrying `rke2 ensure` for cleanup settling.

Progress currently in repo:

- Namespace-first cleanup is implemented.
- The lifecycle suite asserts first-attempt CLI cleanup success.
- Retained storage rebinding after cleanup is covered by automation.
- The lifecycle suite reruns from the canonical CLI path without the old
  post-cleanup `rke2 ensure` retry shim.

Sprint-owned legacy removed:

- `cleanup_passes`
- The multi-pass global list/delete cleanup loop
- Retry-as-settling behavior for the known cleanup race

## Sprint 8: Canonical-Path Cleanup And Legacy Removal

Status: Blocked

Depends on: Sprints 1, 2, 3, 4, 5, 6, and 7

Goal:

- Collapse each major surface to one canonical runtime path, one canonical CLI
  path, and one canonical automated validation path.

Scope:

- Remove compatibility-only or duplicate operator paths instead of preserving
  them.
- Keep doctrine docs architectural and current; track all transitional removal
  timing only in this file.
- Remove workflow/tooling residue that conflicts with the supported operator
  doctrine.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/aws_integration_environment_doctrine.md](./documents/engineering/aws_integration_environment_doctrine.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/dependency_management.md](./documents/engineering/dependency_management.md)
- [documents/engineering/distributed_gateway_architecture.md](./documents/engineering/distributed_gateway_architecture.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)
- [documents/engineering/prerequisite_doctrine.md](./documents/engineering/prerequisite_doctrine.md)
- [documents/engineering/unit_testing_policy.md](./documents/engineering/unit_testing_policy.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration gateway-daemon`
5. `poetry run prodbox test integration gateway-pods`
6. `poetry run prodbox test integration charts-platform`
7. `poetry run prodbox test integration dns-aws`
8. `poetry run prodbox test integration pulumi`

Closure outcomes:

1. No compatibility-only prerequisite remains in the prerequisite registry.
2. Exactly one supported gateway startup path remains.
3. Exactly one supported Route 53 ownership/update path remains.
4. Exactly one supported `.env` auth/config path remains.
5. Exactly one supported `vscode` delivery path remains.
6. `pyproject.toml` no longer carries hook-oriented `pre-commit` residue.
7. The remaining legacy inventory contains only genuinely unresolved items.

Progress currently in repo:

- Repository-wide status tracking has been centralized in this plan.
- Doctrine docs defer completion tracking to this plan.
- The `rke2_killall_exists` prerequisite has been removed.
- The legacy Poetry `daemon` entrypoint and direct daemon wrapper path are gone.
- The CLI/DDNS Route 53 update and timer path are gone.
- The interpreter and summary layer now use one canonical structured DAG
  outcome model.
- Pulumi subprocess handling now injects `PRODBOX_ALLOW_NON_ENTRYPOINT=1`.
- `Settings()` now reads `.env` only from the fixed repository root.
- The certificate issuance path is canonicalized to `letsencrypt-http01`.
- Hook-oriented `pre-commit` dependency and config residue are gone.
- Sprint 7 is now closed without a cleanup-settling retry shim.

Current blockers:

- Rerun `dns-aws` and `pulumi` in an AWS environment with the required Route 53
  permissions.
- Rerun `public-dns` in an AWS environment with `route53:GetHostedZone` access
  to `ROUTE53_ZONE_ID`.

Sprint-owned legacy removed:

- `rke2_killall_exists` prerequisite
- `daemon` Poetry entrypoint alongside `prodbox gateway start`
- CLI/DDNS timer Route 53 path alongside gateway `dns_write_gate`
- Interpreter command-summary compatibility bridge
- Hook-oriented `pre-commit` workflow residue

## Sprint 9: Public Hostname Closure And Authoritative External Proof

Status: Blocked

Depends on: Sprints 6 and 8

Goal:

- Close the live public DNS and ingress path for `vscode.resolvefintech.com`
  and make authoritative external proof part of the canonical automated
  validation path.

Scope:

- Verify live HTTPS reachability, public DNS resolution, TLS issuance,
  authoritative delegation, and Keycloak redirect behavior on the public host.
- Keep the public-host validation path external-only: no kubeconfig, cluster
  prerequisite gate, or `rke2 ensure` runbook.
- Replace manual-only authoritative delegation proof with a named automated
  command or suite.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/aws_integration_environment_doctrine.md](./documents/engineering/aws_integration_environment_doctrine.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)
- [documents/engineering/unit_testing_policy.md](./documents/engineering/unit_testing_policy.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration dns-aws`
4. `poetry run prodbox test integration charts-vscode`
5. `poetry run prodbox test integration public-dns`

Closure outcomes:

1. `vscode.resolvefintech.com` resolves publicly without local-network or
   hosts-file exceptions.
2. The public hostname serves a valid Let's Encrypt certificate.
3. An unauthenticated HTTPS request redirects to the Keycloak login flow on the
   public host.
4. The canonical public-host test command runs without kubeconfig, cluster
   prerequisite gates, or `rke2 ensure`.
5. Authoritative delegation proof is automated rather than manual.

Progress currently in repo:

- `poetry run prodbox test integration charts-vscode` no longer imposes cluster
  prerequisites or an `rke2 ensure` runbook.
- `poetry run prodbox test integration public-dns` is now the named automated
  public delegation proof path.
- `poetry run prodbox charts deploy vscode` succeeds on the canonical chart
  path.
- The canonical issuer path is `letsencrypt-http01`, and the ACME solver token
  is reachable on the ingress endpoint when requested with host header
  `vscode.resolvefintech.com`.
- Public NS lookups now return the expected Route 53 authoritative name
  servers.

Current blockers:

- HTTP and HTTPS requests to `vscode.resolvefintech.com` still time out before
  reaching the canonical ingress path.
- The active AWS identity still lacks `route53:GetHostedZone` for
  `ROUTE53_ZONE_ID`, so `poetry run prodbox test integration public-dns`
  cannot yet prove delegation against the configured hosted zone.

Sprint-owned legacy removed:

- The cluster-gated invocation path for external public-host verification
- Manual-only authoritative public delegation proof

## Sprint 10: Final Clean-Room Validation Rerun And Zero-Legacy Handoff

Status: Not Started

Depends on: Sprints 7, 8, and 9

Goal:

- Rerun the authoritative validation set from a clean operator flow and hand
  off a repository with no remaining compatibility backlog.

Scope:

- Close every remaining partial or blocked sprint.
- Rerun the clean-room validation set through canonical entrypoints only.
- Confirm that docs under `documents/` remain doctrine-only and defer status to
  this file.

Documentation owners to update:

- [documents/engineering/README.md](./documents/engineering/README.md)
- [documents/engineering/aws_integration_environment_doctrine.md](./documents/engineering/aws_integration_environment_doctrine.md)
- [documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md)
- [documents/engineering/helm_chart_platform_doctrine.md](./documents/engineering/helm_chart_platform_doctrine.md)
- [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md)
- [documents/engineering/unit_testing_policy.md](./documents/engineering/unit_testing_policy.md)

Automated validation for closure:

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration all`
4. `poetry run prodbox tla-check`
5. `poetry run prodbox test integration public-dns`

Closure outcomes:

1. No sprint remains `Partially Complete`, `In Progress`, or `Blocked`.
2. All validation commands pass through canonical CLI entrypoints only.
3. Docs under `documents/` describe stable doctrine only and defer status
   tracking to this file.
4. The remaining legacy inventory is empty.

## Exit Definition

This plan is done only when all of the following are true:

1. Sprint 7 closes without retry-based cleanup settling in the lifecycle suite.
2. Sprint 8 removes the remaining duplicate or compatibility-only operator
   paths, including hook-oriented workflow residue.
3. Sprint 9 closes with authoritative public DNS delegation proof plus live
   TLS/auth-wall verification for `vscode.resolvefintech.com`.
4. Sprint 10 reruns the full clean-room validation set from canonical
   entrypoints.
5. No document under `documents/` carries a competing completion-status or
   sprint narrative.
6. The remaining legacy inventory is empty.
