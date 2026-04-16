# Retained Storage Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md

> **Purpose**: Define deterministic retained-storage behavior for prodbox install/delete lifecycles.

---

## 1. Canonical Doctrine Statements

Retained storage in prodbox is reconciled via the static `manual` no-provisioner StorageClass plus prebound PV/PVC resources to guarantee deterministic PVC->PV rebinding across cluster delete/reinstall.

`prodbox rke2 install` recreates the cluster-scoped `manual` StorageClass and deletes every other StorageClass before retained-storage reconciliation succeeds.

The configured manual PV host root (default repository `.data/`) stores PV contents only. Generated chart secrets, gateway event keys, and other non-PV retained artifacts do not live there.

Retained non-PV chart state lives under the repo-local `.prodbox-state/<namespace>/` root.

For lifecycle integration tests, prodbox baseline state is the canonical post-install runtime produced by `prodbox rke2 install`.

Because `prodbox rke2 install` and `prodbox rke2 delete` preserve retained host state, test fixtures must explicitly delete any temporary MinIO or other storage artifacts they create.

`prodbox rke2 delete --yes` must destroy both Pulumi-managed AWS test stacks before local backend
teardown removes the MinIO host that stores Pulumi state.

---

## 2. Scope

This doctrine governs:

1. The retained local storage resources created by `prodbox rke2 install`.
2. Rebinding guarantees expected after `prodbox rke2 delete --yes` plus `prodbox rke2 install`.
3. The boundary between the PV-only manual host root and the repo-local `.prodbox-state/` retained chart-state root.
4. MinIO persistence behavior on the supported single-node RKE2 machine.

Harbor registry pipeline details remain in [Local Registry Pipeline](./local_registry_pipeline.md).

---

## 3. eDAG Contract

`rke2_install` reconciles Harbor, retained storage, and MinIO using railway-style `Result` propagation from `machine_identity` and `settings_object`.

```python
# File: src/prodbox/cli/dag_builders.py
Parallel(
    effect_id="rke2_install_registry_and_storage",
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

1. `StorageClass` `manual` with `kubernetes.io/no-provisioner`, `Retain`, and `WaitForFirstConsumer`.
2. Static `PersistentVolume` objects with deterministic names, `claimRef`, and single-node affinity.
3. `PersistentVolumeClaim` objects with explicit `volumeName` prebinding.
4. Host storage directories rooted at the configured `storage.manual_pv_host_root` setting.

`EnsureMinio` must install `minio/minio` in the `prodbox` namespace with `persistence.existingClaim=<prebound-claim>`.

`rke2_delete` must first invoke the same Pulumi-owned AWS test-stack destroy paths exposed by
`prodbox pulumi eks-destroy --yes` and `prodbox pulumi test-destroy --yes`, then remove the RKE2
substrate, managed kubeconfig residue, and legacy cluster remnants while preserving:

1. The configured manual PV host root.
2. The repo-local `.prodbox-state/` retained chart-state root.

---

## 4. Deterministic Rebinding Rules

Deterministic rebinding is guaranteed only when all of these hold:

1. PVC name and namespace remain unchanged across reinstall.
2. PV name and `claimRef` are reconciled deterministically.
3. PVC sets `spec.volumeName` to the canonical PV name.
4. The configured manual PV host path remains present on disk.
5. Workload remains scheduled to the same single node.

For this reason, the source of truth for storage host paths is the machine-identity pipeline:

- `machine_identity` -> `prodbox-<machine-id>` -> deterministic host path root

---

## 5. Delete Contract

`prodbox rke2 delete --yes`:

1. Runs `prodbox pulumi eks-destroy --yes` semantics first, then
   `prodbox pulumi test-destroy --yes`, so Pulumi-managed AWS test resources are gone before the
   local MinIO backend disappears.
2. Runs the supported RKE2 uninstall flow when present, otherwise disables the service and removes
   the known RKE2 data directories.
3. Deletes a managed `~/.kube/config` only when it still targets the local RKE2 API endpoint.
4. Preserves the configured manual PV host root because it contains retained PV contents.
5. Preserves `.prodbox-state/` because it contains retained non-PV chart state required to
   reconnect retained services after reinstall.
6. Prints the preserved-state boundary explicitly so the data-loss contract is unambiguous to the
   operator.

This keeps retained data recoverable and supports deterministic rebinding after reinstall.

---

## 6. Test Expectations

Integration lifecycle tests must verify:

1. The real MinIO PVC remains bound to the same PV across delete/reinstall.
2. Only the `manual` StorageClass remains after `prodbox rke2 install` completes.
3. `poetry run prodbox rke2 delete --yes` succeeds on the first operator invocation.
4. Temporary test resources are fully removed at test end, including temporary storage artifacts and host-path data created by the fixture harness.
5. Baseline prodbox runtime after test completion matches the post-install state defined by `prodbox rke2 install`.

Shared-runtime lifecycle fixture ownership and teardown behavior are defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md#32-shared-runtime-baseline-fixtures).

---

## 7. Repo-Local Retained State Layout

The chart platform uses two retained repository-local roots with different authority boundaries:

1. PV contents: `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>/`
2. Non-PV retained chart state: `.prodbox-state/<namespace>/`

Rules:

1. `.data/` is PV-content-only storage and is excluded from both `.gitignore` and `.dockerignore`.
2. `.prodbox-state/` is retained non-PV chart state and is also excluded from both `.gitignore` and `.dockerignore`.
3. `prodbox charts delete <chart>` deletes PV/PVC objects but never removes either retained host-state root.
4. Full cluster delete preserves both retained roots so reinstall can reconnect stateful services without manual secret repair.

Full doctrine for the chart platform is in [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md).

---

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
