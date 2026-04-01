# prodbox Development Roadmap

**Status**: In Progress — Sprint 9 active

prodbox is a Python-native CLI for managing a home Kubernetes cluster. The current program delivers `prodbox charts` as a first-class capability, ending with `vscode.resolvefintech.com` as the first public service.

## Vision

After this program is complete:

- The existing public CLI surface remains contract-aligned, documented, and validated.
- Chart lifecycle management is a first-class `prodbox` capability implemented through the existing Click -> ADT -> eDAG -> interpreter architecture.
- Bespoke Helm charts live under `charts/` and obey the singleton, same-namespace, isolation, and retained-storage contracts.
- Stateful chart storage is owned by the CLI, never by Helm chart PV creation, and is deterministic across delete/redeploy.
- The first public service, `vscode.resolvefintech.com`, is delivered through MetalLB ingress, Let's Encrypt TLS, and local Keycloak with Google OAuth as the only login method.
- Documentation, command-surface doctrine, storage doctrine, and named suites all match the code.

Out of scope:

- Any change that weakens the already-completed pre-chart doctrine to make chart delivery easier
- Cross-namespace chart service sharing
- Chart-authored `PersistentVolume` creation
- Deleting underlying host data under `.data`

## Sprint Table

| Sprint | Status | Summary |
|--------|--------|---------|
| 1 | Complete | Repair runtime contracts and remove accidental placeholders |
| 2 | Complete | Audit and harden the full public command surface |
| 3 | Complete | Add and pass real-system validation suites for runtime, AWS, Pulumi, gateway, and lifecycle |
| 4 | Complete | Reconcile documentation topology, matrix parity, and doc-guard coverage |
| 5 | Complete | Lock chart-platform contracts and finish the repo scaffolding already present in the worktree |
| 6 | Complete | Add `prodbox charts` lifecycle commands and eDAG integration |
| 7 | Complete | Implement deterministic retained chart storage rooted at `.data` |
| 8 | Complete | Deliver the namespace-local `vscode` / `keycloak` / `keycloak-postgres` chart stack |
| 9 | In Progress | Expose `vscode.resolvefintech.com` and close docs, named suites, and the completion matrix |

## Maintenance Rules

1. Keep at most one sprint marked `In Progress`.
2. Do not mark a sprint complete until every validation criterion in that sprint is satisfied.
3. If the codebase contradicts this plan, update the plan before continuing work.
4. Reopen and update this file whenever a new audit finds command-surface drift, stale validation evidence, documentation contradictions, or chart-platform scope drift.

## Sprint 1: Repair Runtime Contracts And Remove Placeholders

Status: Complete

Scope: Close the original runtime placeholder set and confirm no new unfinished placeholder regressions in the pre-chart scope.

Validation criteria:

1. No public command in the original tracked surface reports success without performing its documented behavior.
2. No prerequisite intended to check real state is implemented as unconditional `Pure(True)`.
3. `env`, `host`, `dns`, and Pulumi bootstrap behavior are backed by unit coverage and named integration coverage.

## Sprint 2: Audit And Harden The Full Public Command Surface

Status: Complete

Scope: Row-by-row command-surface reconciliation across Click, ADTs, DAG builders, docs, and tests to confirm parity between the documented command matrix and the implemented pre-chart surface.

Validation criteria:

1. Every documented pre-chart command argument and option is either propagated into behavior or removed from the public surface.
2. The named `test` suite surface is explicit and closed to raw pytest passthrough.
3. `documents/engineering/cli_command_surface.md` matches the implemented pre-chart CLI.

## Sprint 3: Complete Real-System Validation For Runtime, AWS, Pulumi, Gateway, And Lifecycle

Status: Complete

Scope: Revalidate the cluster-backed gateway, lifecycle, AWS, and Pulumi real suites on the dirty worktree and complete a manual cleanup audit of the shared AWS test account.

Validation criteria:

1. The high-risk real-system surfaces have explicit named suites and passing evidence.
2. Cleanup and teardown semantics are validated, not implied.
3. Shared AWS test-account cleanup leaves no stray `managed_by=prodbox-integration` resources behind.

## Sprint 4: Reconcile Documentation Topology, Matrix Parity, And Guard Coverage

Status: Complete

Scope: Resolve README and doctrine contradictions, extend the markdown guard for `Referenced by` backlinks, and reconfirm 42-command parity between the documented matrix and the implemented pre-chart surface.

Validation criteria:

1. The owning pre-chart docs comply with [documents/documentation_standards.md](./documents/documentation_standards.md).
2. The documentation index, owning doctrine docs, and completion matrix do not contradict one another.
3. Documentation guard coverage enforces the tracked metadata and backlink rules.

## Sprint 5: Lock Chart-Platform Contracts And Finish The Existing Scaffolding

Status: Complete

Scope: Lock the chart-platform contract in one coherent doctrine set (singleton identity, root-chart-owned namespace, same-namespace-only prerequisite composition, default-deny network-policy isolation), decide the canonical `prodbox charts list|status|deploy|delete` surface, and reconcile existing scaffolding with the chosen contract.

Validation criteria:

1. The chart-platform rules above are explicitly documented and do not conflict with the pre-chart doctrine.
2. The planned chart CLI surface is documented before implementation proceeds.
3. The existing scaffolding is reconciled with the chosen contract rather than left as an undocumented side path.

## Sprint 6: Add `prodbox charts` Lifecycle Commands And eDAG Integration

Status: Complete

Scope: Add the `charts` Click group; add chart command ADTs, smart constructors, DAG builders, and `_interpret_chart_*` handlers; register `charts-storage`, `charts-platform`, `charts-vscode` named suites; enforce singleton and cross-namespace rejection before any Helm action.

Validation criteria:

1. `poetry run prodbox check-code` passes.
2. `poetry run prodbox test unit` passes with direct coverage for chart ADTs, planning, and failure paths.
3. `poetry run prodbox test integration cli` passes with the final chart command surface included.
4. The public CLI can list, inspect, deploy, and delete supported chart identities through the eDAG path only.

## Sprint 7: Implement Deterministic Retained Chart Storage Rooted At `.data`

Status: Complete

Scope: Make the CLI the sole owner of chart PV/PVC lifecycle using deterministic host paths `.data/<namespace>/<StatefulSet>/<ordinal>`; add `.data` to `.gitignore` and `.dockerignore`; ensure chart deletion removes Helm releases, namespaces, PVCs, and CLI-created PVs but never the underlying host directories.

Validation criteria:

1. `poetry run prodbox check-code` passes.
2. `poetry run prodbox test unit` passes with direct coverage for PV naming, host-path mapping, delete semantics, and prebinding.
3. `poetry run prodbox test integration lifecycle` passes without regressing the existing retained-storage doctrine.
4. A new named suite, `poetry run prodbox test integration charts-storage`, proves deterministic delete/redeploy rebinding.
5. No tracked chart manifest creates a `PersistentVolume`.

## Sprint 8: Deliver The Namespace-Local `vscode` / `keycloak` / `keycloak-postgres` Stack

Status: Complete

Scope: Finalize the three bespoke charts under `charts/`, model the `vscode -> keycloak -> keycloak-postgres` prerequisite chain, enforce namespace-local network isolation, and keep all stateful services on the Sprint 7 retained-storage path.

Validation criteria:

1. `charts/` contains only the supported bespoke chart identities and their required templates.
2. `poetry run prodbox check-code` passes.
3. `poetry run prodbox test unit` passes with coverage for prerequisite ordering and same-namespace plan validation.
4. A new named suite, `poetry run prodbox test integration charts-platform`, proves:
   automatic prerequisite reconciliation
   singleton enforcement
   same-namespace-only rendering
   namespace isolation

## Sprint 9: Expose `vscode.resolvefintech.com` And Close Docs, Suites, And Matrix

Status: In Progress

Scope:

1. Reuse the existing Route 53 and dynamic-IP tooling so `vscode.resolvefintech.com` is managed through the canonical `prodbox dns` path.
2. Expose the service through MetalLB-backed ingress with Let's Encrypt TLS.
3. Run local Keycloak as the auth broker, backed by local Postgres.
4. Support only Google OAuth as the upstream identity provider for VS Code access.
5. Document the required settings and secret injection path according to [documents/documentation_standards.md](./documents/documentation_standards.md).
6. Add or update the owning docs:
   `documents/engineering/helm_chart_platform_doctrine.md`
   `documents/engineering/cli_command_surface.md`
   `documents/engineering/storage_lifecycle_doctrine.md`
   `documents/engineering/README.md`
   `README.md`
7. Extend the completion matrix and verification set so chart delivery is part of release-readiness, not a side note.

Validation criteria:

1. ✓ `poetry run prodbox check-code` passes.
2. ✓ `poetry run prodbox test unit` passes.
3. ✓ `poetry run prodbox test integration dns-aws` passes with the public hostname path still owned by the canonical DNS tooling.
4. ✗ A named suite, `poetry run prodbox test integration charts-vscode`, proves ingress reachability, valid TLS, auth redirection into Keycloak, and successful Google OAuth mediated login. **Pending — requires live DNS, TLS, and Google OAuth credentials.**
5. ✓ The owning docs and completion matrix comply with [documents/documentation_standards.md](./documents/documentation_standards.md).

Open issues:

- Google OAuth credentials (`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`) are still required for end-to-end validation.
- Final DNS and TLS validation depends on live Route 53 and Let's Encrypt reachability at execution time.

## Final Completion Definition

This plan is complete only when all of the following are true:

1. The completed pre-chart baseline remains green and documented.
2. `prodbox charts` is part of the public CLI surface and is implemented through the existing architecture.
3. `charts/` is the canonical home for bespoke Helm charts owned by this repository.
4. Each supported chart identity can be deployed at most once.
5. A root chart and all of its designated prerequisites render only into the root chart namespace.
6. Namespace-local services created by a chart stack are not consumed from other namespaces.
7. Charts never create `PersistentVolume` objects.
8. The CLI owns deterministic PV/PVC creation under `.data/<namespace>/<StatefulSet>/<ordinal>`.
9. `.data` is ignored by both Git and Docker tooling.
10. Chart deletion never deletes underlying host storage in `.data`.
11. Delete/redeploy preserves the same numbered PV/PVC bindings for the same retained state.
12. `vscode.resolvefintech.com` is live behind MetalLB and Let's Encrypt and is protected by local Keycloak with Google OAuth as the only login path.
13. The owning docs and named suites match the shipped implementation.
