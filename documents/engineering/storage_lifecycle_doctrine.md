# Retained Storage Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/secret_derivation_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md
**Generated sections**: none

> **Purpose**: Define deterministic retained-storage behavior for `prodbox` install/delete
> lifecycles.

## 1. Canonical Doctrine Statements

- The operator host retains exactly one durable directory: the configured manual PV host
  root (default `.data/`). No other operator-host state is preserved across cluster
  wipes. The legacy `.prodbox-state/` repo-local cache is removed; chart secrets, gateway
  event-key files, stack-output caches, EKS kubeconfig snapshots, and HA-RKE2 SSH key
  material no longer live on disk outside `.data/`.
- Retained storage is reconciled via the static `manual` no-provisioner `StorageClass`
  plus deterministic PV resources to guarantee stable PVC-to-PV rebinding across cluster
  delete/reinstall.
- `prodbox rke2 reconcile` recreates the cluster-scoped `manual` `StorageClass` and
  removes every other `StorageClass` before retained-storage reconciliation succeeds.
- The manual PV host root stores PV contents and the per-cluster MinIO bucket files.
  MinIO's own PV lives under `.data/minio/...`; therefore the per-run Pulumi state
  backend (`prodbox-test-pulumi-backends`) and the gateway-owned secret-derivation bucket
  (`prodbox/master-seed`) both survive cluster wipes whenever `.data/` is preserved.
- Namespace-local Patroni PostgreSQL clusters created for Helm-managed application stacks
  use deterministic CLI-owned PVs rooted at
  `.data/<namespace>/keycloak-postgres/prodbox-<root-chart>-pg/<ordinal>/data/`.
- The shipped `api`, `redis`, and `websocket` workloads do not add new manual-PV
  contracts; the Redis-backed WebSocket path keeps shared state at the application layer
  rather than extending the retained PV inventory.
- Chart secrets and the gateway peer-event signing keys are k8s Secrets, never host-disk
  files. Data-bound secrets (Patroni roles, Keycloak admin, gateway event keys) are
  derived from the master seed inside the cluster by the gateway service per
  [secret_derivation_doctrine.md](./secret_derivation_doctrine.md). Non-data-bound
  secrets are chart-generated behind `lookup`-guarded Helm helpers.
- `prodbox rke2 delete --yes` and `prodbox rke2 delete --cascade --yes` both preserve
  `.data/`. No `prodbox` command removes `.data/` on its own; deletion is operator-only.
- When the MinIO-backed Pulumi backend is still running but kubelet reports its `/export`
  mount as deleted, the Haskell backend helper recreates the declared retained host path,
  reapplies the `1000:1000` plus `0770` contract, and restarts `deployment/minio` before
  backend validation or stack operations continue.

## 2. Scope

This doctrine governs:

1. retained local storage resources created by `prodbox rke2 reconcile`
2. retained local storage resources created by `prodbox charts deploy keycloak|vscode`
   for the namespace-local Patroni PostgreSQL cluster and `vscode` data
3. rebinding guarantees expected after `prodbox rke2 delete --yes` plus
   `prodbox rke2 reconcile`
4. the `.data/` host root as the sole preserved operator-host directory, and the
   pin that MinIO's PV lives inside it
5. MinIO persistence behavior on the supported single-node RKE2 machine
6. deleted-export-mount repair for the repo-backed Pulumi backend
7. the master seed at `prodbox/master-seed` in MinIO, which lives on MinIO's PV under
   `.data/minio/...` and is therefore in scope of this doctrine for persistence
   (derivation, access control, and endpoint contract are governed by
   [secret_derivation_doctrine.md](./secret_derivation_doctrine.md))

Harbor registry details remain in
[Local Registry Pipeline](./local_registry_pipeline.md).

## 3. eDAG Contract

`rke2 reconcile` reconciles Harbor, retained storage, and MinIO using the Haskell
lifecycle runtime. The Harbor portion of that lifecycle must reach a stable
external-serving state before public-image mirror, custom-image publication, or
Harbor-backed steady-state workload reconcile continues. The bootstrap MinIO install
that establishes the local backend may pull its images from public registries first.

The retained-storage effect must reconcile:

1. `StorageClass` `manual` with `kubernetes.io/no-provisioner`, `Retain`, and
   `WaitForFirstConsumer`
2. deterministic `PersistentVolume` objects with `claimRef` and single-node affinity
3. direct-workload `PersistentVolumeClaim` objects with explicit `volumeName` prebinding
   where the workload is not operator-managed
4. post-install Percona PostgreSQL PVC discovery plus staged retained-cluster restore so
   deterministic PVs bind to the operator-created claim names, the preserved ordinal
   `0` anchor comes up first, and follower ordinals `1` and `2` rejoin only after their
   retained roots are reset
5. host storage directories rooted at `storage.manual_pv_host_root`
6. Harbor external readiness plus stable `/readyz` and `/v2/` probes before image writes
   and Harbor-backed steady-state workload reconcile continue
7. deleted MinIO export-mount detection and a bounded recreate-plus-restart repair before
   MinIO-backed Pulumi validation continues
8. MinIO IAM bootstrap (the `prodbox` bucket and the `prodbox-gateway` user + policy)
   per [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §7 so the
   gateway daemon can read or create the master seed before any chart deploy requires
   derived secrets

`rke2 delete` must preserve the configured manual PV host root and nothing else on the
operator host.

## 4. Deterministic Rebinding Rules

Deterministic rebinding is guaranteed only when all of these hold:

1. PVC name and namespace remain unchanged across reinstall
2. PV name and `claimRef` are reconciled deterministically
3. direct-workload PVCs set `spec.volumeName` to the canonical PV name, or the Percona
   operator recreates the same PVC names that the Haskell runtime later binds through
   deterministic PVs
4. the configured manual PV host path remains present on disk
5. the workload remains scheduled to the same single node
6. the master seed at `prodbox/master-seed` in MinIO matches the seed that was active
   when the preserved data was written. The seed survives cluster wipes via MinIO's
   PV under `.data/minio/...`; mismatch surfaces as a loud failure per
   [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §8, never a silent
   data reset.

## 5. Delete Contract

`prodbox rke2 delete --cascade --yes` is the canonical operator-driven teardown. The
cascade order, defined in
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) §5, is:

1. Confirm MinIO is reachable (or treat per-run Pulumi state as already gone if not).
2. Per-run Pulumi destroys against MinIO with the
   `withMaterializedOperationalCreds` bracket filling `aws.*` from
   `aws_admin_for_test_simulation.*` when empty.
3. K8s drain phase (LoadBalancer Services, Ingresses, Delete-reclaim PVCs).
4. RKE2 uninstall, removing the substrate and managed kubeconfig.
5. Postflight cluster-tag sweep that fails the command with the leak list if anything
   cluster-tagged survives.

`prodbox rke2 delete --yes` (without `--cascade`) preserves any Pulumi residue in MinIO
when invoked with `--allow-pulumi-residue`; reconcile + per-stack destroy from the
rebuilt cluster is the supported recovery path because MinIO's PV under `.data/` keeps
the Pulumi state alive across the cluster cycle. Live AWS resources tracked in MinIO
state remain reachable from any subsequent reconcile.

Both delete shapes preserve `.data/` and remove nothing else on the operator host. The
host iptables rule installed by reconcile (per
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §5) is removed as part
of clean teardown.

`prodbox rke2 delete` captures the upstream `/usr/local/bin/rke2-uninstall.sh` stdout
and stderr through the lifecycle-local quiet path so that successful uninstall runs
surface only the doctrine-owned summary lines, while non-zero uninstall exits still
surface actionable upstream context through `summarizeRke2DeleteFailure`. Benign
upstream chatter — including `Cannot find device`, `semodule: not found`, and
`Failed to allocate directory watch: Too many open files` — is classified as ignorable
noise and never appears as a red-herring operator-visible error.

## 6. Test Expectations

Lifecycle-oriented validation should prove:

1. the real MinIO PVC remains bound to the same PV across delete/reinstall, and the
   `prodbox/master-seed` object inside MinIO is unchanged
2. only the `manual` `StorageClass` remains after `prodbox rke2 reconcile`
3. the `keycloak-postgres` and `vscode` storage bindings remain deterministic for their
   root namespaces
4. Percona PostgreSQL PVC discovery binds retained PVs to the operator-created claim
   names before dependent charts continue
5. retained Patroni redeploy preserves the ordinal `0` anchor PV, resets retained
   follower roots for ordinals `1` and `2`, and scales from one replica back to the
   supported three-replica steady state
6. Patroni passwords derived from the master seed via the gateway service authenticate
   against the preserved `pg_authid` on a wipe-and-rebuild cycle
7. `prodbox rke2 delete --yes` succeeds on the first operator invocation
8. temporary validation resources are fully removed at test end
9. baseline runtime after test completion matches the post-install state defined by
   `prodbox rke2 reconcile`
10. a deleted MinIO export host-path mount is repaired back onto the declared retained
    directory before Pulumi backend login or stack operations continue
11. no `prodbox` invocation writes to `.prodbox-state/` (enforced by
    `forbidDotProdboxState` in `prodbox check-code`)

Cleanup ownership is defined in
[Integration Fixture Doctrine](./integration_fixture_doctrine.md).

## 7. The Single Retained Operator-Host Root

`.data/` is the only repository-local retained root.

Rules:

1. `.data/` stores PV content. The MinIO PV at `.data/minio/...` is the persistence
   anchor for per-run Pulumi state and for the gateway-owned secret-derivation bucket
   (`prodbox/master-seed`).
2. The internal `keycloak-postgres` release uses the deterministic path
   `.data/<namespace>/keycloak-postgres/prodbox-<root-chart>-pg/<ordinal>/data/`.
3. The `vscode` StatefulSet uses the deterministic path
   `.data/vscode/vscode/vscode/0/data/`.
4. Deterministic PV and Patroni resource names flow through `src/Prodbox/Naming.hs`.
5. Patroni service names, PVC names, and storage-spec inventory flow through
   `src/Prodbox/PostgresPlatform.hs` rather than through chart-platform string
   concatenation.
6. The `api`, `redis`, and `websocket` workloads do not currently allocate
   deterministic `.data/` roots on the supported path.
7. The retained Patroni anchor path is
   `.data/<namespace>/keycloak-postgres/prodbox-<root-chart>-pg/0/data/`; follower
   paths for ordinals `1` and `2` are preserved on disk but must be reset before those
   replicas rejoin a restored cluster.
8. `prodbox charts delete <chart>` deletes PV/PVC objects but never removes `.data/`.
9. Cluster delete preserves `.data/` so reinstall can reconnect stateful services and
   so MinIO bucket contents (Pulumi state, master seed) remain available across the
   cycle.
10. Deleting `.data/` is an operator-only action. It is the supported way to start from
    a truly empty baseline; on the next reconcile the master seed is regenerated and
    all data-bound secrets derive from the new value.

## Cross-References

- [Config Doctrine](./config_doctrine.md) — storage paths and MinIO coordinates live in
  the daemon's Dhall config, not in environment variables
- [Secret Derivation Doctrine](./secret_derivation_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
