# Retained Storage Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md

> **Purpose**: Define deterministic retained-storage behavior for `prodbox` install/delete
> lifecycles.

## 1. Canonical Doctrine Statements

- Retained storage is reconciled via the static `manual` no-provisioner `StorageClass` plus
  prebound PV/PVC resources to guarantee deterministic PVC-to-PV rebinding across cluster
  delete/reinstall.
- `prodbox rke2 install` recreates the cluster-scoped `manual` `StorageClass` and removes every
  other `StorageClass` before retained-storage reconciliation succeeds.
- The configured manual PV host root (default repository `.data/`) stores PV contents only.
- Retained non-PV chart state lives under the repo-local `.prodbox-state/<namespace>/` root.
- `prodbox rke2 delete --yes` must destroy both Pulumi-managed AWS test stacks before local backend
  teardown removes the MinIO host that stores Pulumi state.

## 2. Scope

This doctrine governs:

1. retained local storage resources created by `prodbox rke2 install`
2. rebinding guarantees expected after `prodbox rke2 delete --yes` plus `prodbox rke2 install`
3. the boundary between the PV-only manual host root and the repo-local `.prodbox-state/` retained
   chart-state root
4. MinIO persistence behavior on the supported single-node RKE2 machine

Harbor registry details remain in [Local Registry Pipeline](./local_registry_pipeline.md).

## 3. eDAG Contract

`rke2 install` reconciles Harbor, retained storage, and MinIO using the Haskell lifecycle runtime.
The Harbor portion of that lifecycle must reach a stable external-serving state before image mirror
or MinIO install continues.

The retained-storage effect must reconcile:

1. `StorageClass` `manual` with `kubernetes.io/no-provisioner`, `Retain`, and
   `WaitForFirstConsumer`
2. static `PersistentVolume` objects with deterministic names, `claimRef`, and single-node
   affinity
3. `PersistentVolumeClaim` objects with explicit `volumeName` prebinding
4. host storage directories rooted at `storage.manual_pv_host_root`
5. Harbor external readiness plus stable `/readyz` and `/v2/` probes before image writes and
   Harbor-backed MinIO install continue

`rke2 delete` must preserve:

1. the configured manual PV host root
2. the repo-local `.prodbox-state/` retained chart-state root

## 4. Deterministic Rebinding Rules

Deterministic rebinding is guaranteed only when all of these hold:

1. PVC name and namespace remain unchanged across reinstall
2. PV name and `claimRef` are reconciled deterministically
3. PVC sets `spec.volumeName` to the canonical PV name
4. the configured manual PV host path remains present on disk
5. the workload remains scheduled to the same single node

## 5. Delete Contract

`prodbox rke2 delete --yes`:

1. runs `prodbox pulumi eks-destroy --yes`, then `prodbox pulumi test-destroy --yes`
2. removes the RKE2 substrate and managed kubeconfig residue
3. preserves the configured manual PV host root
4. preserves `.prodbox-state/`
5. reports expected-absence cleanup as normal delete disposition rather than failure-looking trace
   noise
6. prints the preserved-state boundary explicitly

## 6. Test Expectations

Lifecycle-oriented validation should prove:

1. the real MinIO PVC remains bound to the same PV across delete/reinstall
2. only the `manual` `StorageClass` remains after `prodbox rke2 install`
3. `./.build/prodbox rke2 delete --yes` succeeds on the first operator invocation
4. temporary validation resources are fully removed at test end
5. baseline runtime after test completion matches the post-install state defined by
   `prodbox rke2 install`

Cleanup ownership is defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).

## 7. Repo-Local Retained State Layout

The chart platform uses two retained repository-local roots with different authority boundaries:

1. PV contents: `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>/`
2. Non-PV retained chart state: `.prodbox-state/<namespace>/`

Rules:

1. `.data/` is PV-content-only storage
2. `.prodbox-state/` is retained non-PV chart state
3. `prodbox charts delete <chart>` deletes PV/PVC objects but never removes either retained
   host-state root
4. full cluster delete preserves both retained roots so reinstall can reconnect stateful services

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
