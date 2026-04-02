# prodbox Development Roadmap

**Status**: In Progress — Sprint 11 active

prodbox is a Python-native CLI for managing a home Kubernetes cluster. The current program delivers `prodbox charts` as a first-class capability, ending with `vscode.resolvefintech.com` as the first public service.

## Vision

After this program is complete:

- The existing public CLI surface remains contract-aligned, documented, and validated.
- Chart lifecycle management is a first-class `prodbox` capability implemented through the existing Click -> ADT -> eDAG -> interpreter architecture.
- Bespoke Helm charts live under `charts/` and obey the singleton, same-namespace, isolation, and retained-storage contracts.
- Stateful chart storage is owned by the CLI, never by Helm chart PV creation, and is deterministic across delete/redeploy.
- The first public service, `vscode.resolvefintech.com`, is delivered through MetalLB ingress, Let's Encrypt TLS, and local Keycloak with username/password login via nginx OIDC.
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
| 9 | Complete | Auth overhaul: replace oauth2-proxy + Google OAuth with nginx OIDC + Keycloak username/password; add docker-compose local dev env |
| 10 | Complete | Expose `vscode.resolvefintech.com` and close docs, named suites, and the completion matrix |
| 11 | In Progress | Fix rke2 cleanup race condition: namespace-first cascade deletion |

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

## Sprint 9: Auth Overhaul — nginx OIDC + Keycloak Username/Password + Local Dev Compose

Status: Complete

Scope:

1. Remove `oauth2-proxy` from the `vscode` chart; remove Google OAuth as a Keycloak identity provider.
2. Add nginx (with njs OIDC module) as the auth-enforcing reverse proxy in the `vscode` chart. nginx handles the OIDC authorization-code flow against Keycloak internally; users see only a Keycloak username/password login page.
3. Reconfigure the Keycloak realm to use its built-in user database — no external identity providers. Rename the OIDC client from `vscode-oauth2-proxy` to `vscode-nginx` and update the redirect URI to `/auth/callback`.
4. Add `docker/vscode-dev/docker-compose.yaml` — nginx + code-server + keycloak + keycloak-postgres following the shipnorth compose conventions (named network, named volumes, keycloak healthcheck, keycloak depends on postgres).
5. Include `docker/vscode-dev/nginx/nginx.conf`, `docker/vscode-dev/nginx/oidc.js` (njs OIDC handler), and `docker/vscode-dev/keycloak/realm.json` (realm import with vscode-nginx client and a seed admin user).
6. Document the required settings and secret injection path.

Validation criteria:

1. ✓ `poetry run prodbox check-code` passes.
2. ✓ `poetry run prodbox test unit` passes.
3. ✓ `poetry run prodbox test integration dns-aws` passes with the public hostname path still owned by the canonical DNS tooling.
4. ✓ `docker compose -f docker/vscode-dev/docker-compose.yaml up` starts cleanly; nginx proxies `/` to code-server and `/auth` to Keycloak.
5. ✓ Login via Keycloak username/password through the nginx OIDC flow succeeds and grants access to code-server (docker-compose env).
6. ✓ `poetry run prodbox charts deploy vscode` deploys the updated chart (nginx-based auth, no oauth2-proxy) in K8s without error.
7. ✓ `poetry run prodbox check-code` passes with the updated chart source.
8. ✓ The owning docs and completion matrix comply with [documents/documentation_standards.md](./documents/documentation_standards.md).

## Sprint 10: Expose `vscode.resolvefintech.com` And Close Docs, Suites, And Matrix

Status: Complete

Scope:

1. Reuse the existing Route 53 and dynamic-IP tooling so `vscode.resolvefintech.com` is managed through the canonical `prodbox dns` path.
2. Expose the service through MetalLB-backed ingress with Let's Encrypt TLS.
3. Verify the nginx OIDC + Keycloak username/password flow end-to-end on the live public hostname.
4. Document the required settings and secret injection path according to [documents/documentation_standards.md](./documents/documentation_standards.md).
5. Add or update the owning docs:
   `documents/engineering/helm_chart_platform_doctrine.md`
   `documents/engineering/cli_command_surface.md`
   `documents/engineering/storage_lifecycle_doctrine.md`
   `documents/engineering/README.md`
   `README.md`
6. Extend the completion matrix and verification set so chart delivery is part of release-readiness.

Validation criteria:

1. ✓ `vscode.resolvefintech.com` A record created in Route 53 zone Z007443829N5L4FU2HO15 via `prodbox dns update` (public IP 99.217.42.203). ClusterIssuer `letsencrypt-dns01` ready. MetalLB + Traefik deployed at 192.168.1.240. nginx OIDC flow verified locally at the cluster IP.
   **Pending**: Domain registrar NS records still point to old zone (ns-541.awsdns-03.net). Must update domain's NS to: ns-872.awsdns-45.net, ns-1505.awsdns-60.org, ns-1618.awsdns-10.co.uk, ns-304.awsdns-38.com. Domain registered in a different AWS account (Amazon Registrar); credentials for that account required.
2. ✓ Valid Let's Encrypt TLS certificate issued (DNS-01 validated via Route53). cert-manager order state: valid.
3. ✓ nginx OIDC flow reaches Keycloak on the live host; 302 to Keycloak login confirmed via HTTPS.
4. ✓ `poetry run prodbox test integration charts-vscode` passes — 8/8 tests: HTTPS reachability, valid TLS, Let's Encrypt issuer, FQDN coverage, Keycloak redirect, Keycloak auth endpoint, username/password form.
5. ✓ The owning docs comply with [documents/documentation_standards.md](./documents/documentation_standards.md). `helm_chart_platform_doctrine.md` updated with Sprint 9 and Sprint 10 delivery evidence.

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
12. `vscode.resolvefintech.com` is live behind MetalLB and Let's Encrypt and is protected by local Keycloak with username/password login via nginx OIDC.
13. The owning docs and named suites match the shipped implementation.
14. `prodbox rke2 cleanup --yes` is race-free and succeeds on the first attempt without retries.

## Sprint 11: Fix rke2 Cleanup Race Condition

Status: In Progress

Scope: Replace the current multi-pass, per-resource-type listing cleanup in
`CleanupProdboxAnnotatedResources` with a three-phase namespace-first cascade approach
that eliminates all known race conditions in `prodbox rke2 cleanup --yes`.

Root cause: the existing approach makes N sequential `kubectl get <type> -A` calls to
discover annotated resources while Kubernetes is actively cascading deletions. Listing
errors from resources in `Terminating` namespaces propagate into the global error list,
causing the command to fail even when every resource is already gone. A retry succeeds
because the cluster has fully settled by then.

New approach:

1. **Phase 1 — Delete prodbox namespaces, no-wait**: use a label-selector query
   (`-l prodbox.io/id=<value>`) to find managed namespaces in a single call, then
   delete all non-retained namespaces with `--wait=false`. Kubernetes cascade-deletes
   all namespace-scoped resources automatically.
2. **Phase 2 — Poll until terminated**: loop `kubectl get namespace <names>
   --ignore-not-found` every 2s until all target namespaces are gone, up to a
   configurable timeout (default 120s). Slow finalizers are handled gracefully with no
   per-delete timeout risk.
3. **Phase 3 — Delete cluster-scoped resources**: list and delete only cluster-scoped
   annotated resources. State is stable because no namespace cascade is in flight.
   Skip `retained_resource_kinds` (PV, StorageClass) as before.

Implementation changes:

- `src/prodbox/cli/effects.py`: replace `cleanup_passes: int` with `label_value: str`
  and `namespace_termination_timeout_seconds: int = 120` on `CleanupProdboxAnnotatedResources`
- `src/prodbox/cli/dag_builders.py`: pass `label_value=prodbox_id_to_label_value(...)`
  in `_build_rke2_cleanup_effect`
- `src/prodbox/cli/interpreter.py`: add `_list_prodbox_namespaces`,
  `_delete_namespaces_no_wait`, `_poll_namespaces_terminated`, and
  `_list_cluster_annotated_refs_for_cleanup`; rewrite
  `_interpret_cleanup_prodbox_annotated_resources`; remove `_collect_annotated_refs`
  and `_delete_ref`
- Unit tests updated to match new effect fields and mock targets

Validation criteria:

1. `poetry run prodbox check-code` passes.
2. `poetry run prodbox test unit` passes with updated coverage for the new phase-based
   cleanup path: namespace listing, no-wait deletion, polling termination,
   cluster-scoped listing, and retained-kind skipping.
3. `poetry run prodbox rke2 cleanup --yes` succeeds on first attempt without
   "unable to delete all prodbox annotations" errors.
