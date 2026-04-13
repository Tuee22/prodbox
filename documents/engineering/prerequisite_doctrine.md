# Prerequisite Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effect_interpreter.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/pure_fp_standards.md, documents/engineering/storage_lifecycle_doctrine.md

> **Purpose**: Philosophy and patterns for prerequisite-based validation in prodbox CLI.

---

## 0. Canonical Doctrine Statements

The only supported operator environment is `Ubuntu 24.04 LTS` with systemd.

`prodbox rke2 install` owns supported-host RKE2 install/reconcile behavior, including systemd boot ownership and retained-storage reconciliation.

Prerequisite nodes validate existence/readiness and fail fast with actionable fix hints; no silent auto-install occurs inside prerequisite checks themselves.

`prodbox rke2 delete --yes` removes managed cluster and host substrate remnants while preserving the configured manual PV host root plus the repo-local `.prodbox-state/` retained chart-state root.

Exactly one prodbox instance exists per supported Linux machine, anchored by machine identity (`/etc/machine-id`) and its derived `prodbox-<machine-id>` identifier.

Runtime-managed pod/service/deployment objects reconciled by prodbox lifecycle effects use the `prodbox` namespace; ephemeral integration-test fixtures may use isolated namespaces as defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).

Retained host state is preserved across delete/reinstall to keep deterministic PVC->PV rebinding intact.

---

## 1. Philosophy

### 1.1 Fail Fast

Prerequisites check conditions BEFORE expensive operations begin:

```
GOOD: Check kubectl exists before running kubectl commands
BAD: Run kubectl command and handle "command not found" error
```

### 1.2 Fail Early

Prerequisites run at DAG construction time, not effect execution time:

```
GOOD: DAG won't build if "platform_linux" fails on macOS
BAD: RKE2 effect starts, then fails with "systemctl not found"
```

### 1.3 Actionable Errors

Prerequisites provide clear error messages with fix suggestions:

```
GOOD: "kubectl not found. Install with: sudo apt install kubectl"
BAD: "Command failed with exit code 127"
```

### 1.4 No Silent Degradation

Prerequisites either pass or fail - no "maybe" state:

```
GOOD: Fail if kubeconfig doesn't exist
BAD: Proceed with default kubeconfig path that might not work
```

### 1.5 Fix Hint Ownership Contract (SSoT)

Fix hints are owned once and must not be duplicated downstream:

1. User-controlled environment prerequisites may emit actionable fix hints.
2. DAG-managed downstream failures must not add fix hints when upstream prerequisite failure already exists.
3. Manual environment fixes are surfaced once in summary output under `Manual env changes needed`.
4. Remediation text must describe user-controlled environment actions, not DAG-managed runtime effects.

### 1.6 Prerequisite Result Propagation

Prerequisite outcomes propagate as `Result` values to dependent nodes.

Default node policy in prodbox is `PROPAGATE`:
- if prerequisite results include failure, the node returns a propagated prerequisite failure.

Nodes that require custom handling can opt into `IGNORE` and explicitly aggregate or recover using prerequisite results in their effect builder.

---

## 2. Prerequisite Categories

### 2.1 Platform Prerequisites

Validate operating system and capabilities:

| Prerequisite | Validates |
|--------------|-----------|
| `platform_linux` | Running on Linux |
| `supported_ubuntu_2404` | Host is Ubuntu 24.04 LTS |
| `systemd_available` | systemd is present |
| `machine_identity` | Valid `/etc/machine-id`, plus derived `prodbox-<machine-id>` |

### 2.2 Tool Prerequisites

Validate external tools are installed:

| Prerequisite | Validates |
|--------------|-----------|
| `tool_kubectl` | kubectl CLI available |
| `tool_ctr` | ctr CLI available for RKE2 containerd import |
| `tool_helm` | helm CLI available |
| `tool_sudo` | sudo CLI available for root-owned host operations |
| `tool_pulumi` | pulumi CLI available |
| `tool_aws` | system-level aws CLI available for real AWS integration tooling |
| `tool_rke2` | RKE2 binary installed |
| `tool_systemctl` | systemctl available |

### 2.3 Configuration Prerequisites

Validate configuration files exist:

| Prerequisite | Validates |
|--------------|-----------|
| `settings_object` | Dhall-backed settings compile and load successfully |
| `settings_loaded` | Effective settings mapping is available to pure code |
| `kubeconfig_exists` | Kubeconfig file present |
| `rke2_config_exists` | RKE2 config.yaml present |

### 2.4 Service Prerequisites

Validate services are running:

| Prerequisite | Validates |
|--------------|-----------|
| `rke2_service_exists` | RKE2 systemd unit exists |
| `rke2_service_active` | RKE2 service is running |
| `k8s_cluster_reachable` | `kubectl cluster-info` succeeds against the active cluster |

### 2.5 AWS Prerequisites

Validate AWS/Route53 access:

| Prerequisite | Validates |
|--------------|-----------|
| `aws_credentials_valid` | Dhall-configured AWS authentication compiled to `prodbox-config.json` is configured and valid for the selected suite |
| `route53_accessible` | AWS authentication loaded from `Settings` can reach the Route 53 API |

Suite-specific AWS auth source, Dhall-config storage rules, and fixture capability proof are defined in [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md).

---

## 3. Registry

### 3.1 Central Definition

All prerequisites are defined in `prerequisite_registry.py`:

```python
# File: src/prodbox/cli/prerequisite_registry.py
PREREQUISITE_REGISTRY: PrerequisiteRegistry = {
    "platform_linux": PLATFORM_LINUX,
    "systemd_available": SYSTEMD_AVAILABLE,
    "tool_kubectl": TOOL_KUBECTL,
    # ...
}
```

### 3.2 Transitive Dependencies

Prerequisites can depend on other prerequisites:

```python
# File: src/prodbox/cli/prerequisite_registry.py
SYSTEMD_AVAILABLE = EffectNode(
    effect=RequireSystemd(...),
    prerequisites=frozenset(["platform_linux"]),  # Depends on platform_linux
)

K8S_CLUSTER_REACHABLE = EffectNode(
    effect=CaptureKubectlOutput(...),
    prerequisites=frozenset(["tool_kubectl", "kubeconfig_exists", "rke2_service_active"]),
)
```

### 3.3 Automatic Expansion

When you depend on `k8s_cluster_reachable`, you automatically get:
- `tool_kubectl`
- `kubeconfig_exists`
- `rke2_service_active`

When you depend on lifecycle roots (`rke2_install`, `rke2_delete`, `pulumi_up`), you also get:
- `machine_identity` result propagation (machine-id + derived prodbox-id).

---

## 4. Patterns

### 4.1 Pure Check Pattern

Prerequisites use `Pure` effects for composed checks:

```python
# File: src/prodbox/cli/prerequisite_registry.py
K8S_READY = EffectNode(
    effect=Pure(
        effect_id="k8s_ready",
        description="Validate Kubernetes cluster is fully ready",
        value=True,
    ),
    prerequisites=frozenset(["k8s_cluster_reachable", "rke2_service_active"]),
)
```

### 4.2 Tool Validation Pattern

Use `ValidateTool` for external tools:

```python
# File: src/prodbox/cli/prerequisite_registry.py
TOOL_KUBECTL = EffectNode(
    effect=ValidateTool(
        effect_id="tool_kubectl",
        description="Validate kubectl is installed",
        tool_name="kubectl",
        version_flag="version --client --short",
    ),
    prerequisites=frozenset(),
)
```

### 4.3 File Existence Pattern

Use `CheckFileExists` for configuration files:

```python
# File: src/prodbox/cli/prerequisite_registry.py
KUBECONFIG_EXISTS = EffectNode(
    effect=CheckFileExists(
        effect_id="kubeconfig_exists",
        description="Check kubeconfig file exists",
        file_path=Path("/etc/rancher/rke2/rke2.yaml"),
    ),
    prerequisites=frozenset(),
)
```

### 4.4 Chained Prerequisites

Chain prerequisites for complex validation:

```python
# File: src/prodbox/cli/prerequisite_registry.py
# rke2_service_active depends on rke2_service_exists
# rke2_service_exists depends on rke2_installed and systemd_available
# systemd_available depends on platform_linux
```

### 4.5 RKE2 Lifecycle Nodes

RKE2 lifecycle is managed by eDAG nodes:
- `rke2_install`: supported-host install/reconcile of the cluster substrate plus Harbor/storage reconciliation
- `rke2_delete`: destructive cluster-removal flow that preserves retained host state roots

Both nodes fail fast on prerequisites and consume machine identity plus settings as source-of-truth:

```python
# File: src/prodbox/cli/dag_builders.py
_build_rke2_install_dag(...):
    prerequisites=frozenset([
        "supported_ubuntu_2404",
        "systemd_available",
        "tool_kubectl",
        "tool_helm",
        "tool_docker",
        "tool_ctr",
        "tool_sudo",
        "tool_systemctl",
        "machine_identity",
        "settings_object",
    ])

_build_rke2_delete_dag(...):
    prerequisites=frozenset([
        "supported_ubuntu_2404",
        "systemd_available",
        "tool_sudo",
        "tool_systemctl",
        "settings_object",
    ])
```

`rke2_install` installs the RKE2 server binary when missing, ensures the host-owned ingress-disable config, enables and restarts the systemd service, refreshes the canonical kubeconfig path, confirms cluster access (`kubectl cluster-info`), resets cluster-scoped StorageClass state to `manual` only, ensures the `prodbox/prodbox-identity` ConfigMap, then reconciles in parallel:

1. Harbor registry runtime (`EnsureHarborRegistry`)
2. Retained local storage + MinIO (`EnsureRetainedLocalStorage` -> `EnsureMinio`)

Finally, it reconciles prodbox annotations.

`rke2_delete` removes the RKE2 substrate, deletes managed kubeconfig residue that still targets the local RKE2 API, removes the legacy storage root when safe, and preserves the configured manual PV host root plus `.prodbox-state/`.

Harbor install/mirror/build details are defined in
[Local Registry Pipeline](./local_registry_pipeline.md).

Retained storage and rebinding guarantees are defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md).

### 4.6 Machine Identity Result Contract

`machine_identity` prerequisite returns `Result[MachineIdentity, E]` where:
- `MachineIdentity.machine_id` is the canonical Linux machine-id.
- `MachineIdentity.prodbox_id` is `prodbox-<machine_id>`.

Downstream DAG nodes must derive annotation values, namespace ownership markers,
and cleanup selectors from this propagated result only.

### 4.7 Kubernetes Ownership Markers

All Kubernetes resources created by prodbox, including installed CRDs, must carry:
- annotation: `prodbox.io/id=<prodbox-id>`
- label: `prodbox.io/id=<label-safe-prodbox-id>`

---

## 5. Anti-Patterns

### 5.1 Late Validation

**DON'T**: Validate conditions inside effect interpretation:

```python
# BAD: Checking inside the effect
async def _interpret_run_kubectl(self, effect):
    if not shutil.which("kubectl"):  # Too late!
        return Failure("kubectl not found")
```

**DO**: Use prerequisites to validate early:

```python
# GOOD: Prerequisite checks before effect runs
root = EffectNode(
    effect=RunKubectlCommand(...),
    prerequisites=frozenset(["tool_kubectl"]),
)
```

### 5.2 Soft Failures

**DON'T**: Return partial success or warnings:

```python
# BAD: Trying to continue despite missing tool
if not tool_exists:
    print("Warning: tool not found, trying anyway...")
```

**DO**: Fail fast and clearly:

```python
# GOOD: Prerequisites fail the entire DAG
case Failure(error):
    return render_error_and_return_exit_code(error)
```

### 5.3 Implicit Dependencies

**DON'T**: Assume prerequisites will be checked elsewhere:

```python
# BAD: Assuming kubectl is already validated
root = EffectNode(
    effect=RunKubectlCommand(...),
    prerequisites=frozenset(),  # Missing tool_kubectl!
)
```

**DO**: Explicitly declare all prerequisites:

```python
# GOOD: Explicit prerequisites
root = EffectNode(
    effect=RunKubectlCommand(...),
    prerequisites=frozenset(["tool_kubectl", "kubeconfig_exists"]),
)
```

---

## 6. Error Messages

### 6.1 Format

Error messages should include:
1. What failed
2. Why it matters
3. How to fix it

```
kubectl not found.

This is required for Kubernetes cluster management.

Fix: Install kubectl with:
  sudo apt install kubectl

Or see: https://kubernetes.io/docs/tasks/tools/install-kubectl/
```

### 6.2 Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success |
| 1 | Prerequisite failure |
| 2 | Effect execution failure |
| 3 | Configuration error |

---

## 7. Intent Ownership

This SSoT owns RKE2 lifecycle prerequisite doctrine statements:

- RKE2 runtime reconciliation and startup are idempotently performed via eDAG lifecycle effects once required host binaries and configuration already exist; host installation is not performed implicitly.
- Prerequisite nodes validate existence/readiness and fail fast with actionable fix hints; no silent auto-install in checks.
- Cleanup must idempotently remove prodbox-annotated Kubernetes objects without deleting host storage paths used for persistent data.

Linked dependents: `documents/engineering/effectful_dag_architecture.md`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/prerequisite_registry.py`.

---

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Code Quality Doctrine](./code_quality.md)
- [Prerequisite Registry](../../src/prodbox/cli/prerequisite_registry.py)
- [Effect Types](../../src/prodbox/cli/effects.py)
