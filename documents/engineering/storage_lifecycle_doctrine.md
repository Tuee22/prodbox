# Retained Storage Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md

> **Purpose**: Define deterministic retained-storage behavior for prodbox cleanup/redeploy lifecycles.

---

## 1. Canonical Doctrine Statements

Retained storage in prodbox is reconciled via static no-provisioner StorageClass and prebound PV/PVC resources to guarantee deterministic PVC->PV rebinding across cleanup/redeploy.

Cleanup must preserve retained storage resources (`StorageClass`, `PersistentVolume`, `PersistentVolumeClaim`) by default.

MinIO is installed in the `prodbox` namespace via the official `minio/minio` Helm chart and must consume prebound retained PVC storage.

For lifecycle integration tests, prodbox baseline state is the canonical post-deploy runtime produced by the runtime deploy action, `prodbox rke2 ensure`.

Because `prodbox rke2 ensure` and `prodbox rke2 cleanup` preserve storage, test fixtures must explicitly delete any temporary MinIO or other storage artifacts they create.

---

## 2. Scope

This doctrine governs:

1. The retained local storage resources created by `prodbox rke2 ensure`.
2. Rebinding guarantees expected after `prodbox rke2 cleanup` + `prodbox rke2 ensure`.
3. MinIO persistence behavior on a single-node RKE2 machine.

Harbor registry pipeline details remain in [Local Registry Pipeline](./local_registry_pipeline.md).

---

## 3. eDAG Contract

`rke2_ensure` reconciles storage and MinIO using railway-style `Result` propagation from `machine_identity`.

```python
# File: src/prodbox/cli/dag_builders.py
Parallel(
    effect_id="rke2_ensure_registry_and_storage",
    effects=[
        EnsureHarborRegistry(...),
        Sequence(
            effects=[
                EnsureRetainedLocalStorage(...),
                EnsureMinio(...),
            ]
        ),
    ],
)
```

`EnsureRetainedLocalStorage` must reconcile:

1. `StorageClass` with `kubernetes.io/no-provisioner`, `Retain`, `WaitForFirstConsumer`.
2. Static `PersistentVolume` with `claimRef` and single-node affinity.
3. `PersistentVolumeClaim` with explicit `volumeName` prebinding.

`EnsureMinio` must install `minio/minio` in `prodbox` namespace with `persistence.existingClaim=<prebound-claim>`.

---

## 4. Deterministic Rebinding Rules

Deterministic rebinding is guaranteed only when all of these hold:

1. PVC name/namespace remain unchanged across redeploy.
2. PV name and `claimRef` are reconciled deterministically.
3. PVC sets `spec.volumeName` to the canonical PV name.
4. Host storage path is preserved on disk.
5. Workload remains scheduled to the same single node.

For this reason, the source of truth for storage host paths is the machine-identity pipeline:

- `machine_identity` -> `prodbox-<machine-id>` -> deterministic host path root.

---

## 5. Cleanup Contract

`prodbox rke2 cleanup --yes`:

1. Deletes prodbox-annotated runtime resources.
2. Preserves retained storage resources by kind.
3. Preserves the `prodbox` namespace so retained PVC objects are not garbage-collected.
4. Prints explicit manual host-path deletion instructions and data-loss warning.

This keeps data recoverable and supports deterministic rebinding after re-ensure.

---

## 6. Test Expectations

Integration lifecycle tests must verify:

1. Real MinIO PVC remains bound to the same PV across cleanup/redeploy.
2. A temporary 3-replica StatefulSet scenario can rebind to identical prebound PV names after redeploy.
3. Temporary test resources are fully removed at test end, including temporary storage artifacts and host-path data created by the fixture harness.
4. Baseline prodbox runtime after test completion matches the post-deploy state defined by the runtime deploy action, `prodbox rke2 ensure`.

Shared-runtime lifecycle fixture ownership and teardown behavior are defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md#32-shared-runtime-baseline-fixtures).

---

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Documentation Standards](../documentation_standards.md)
