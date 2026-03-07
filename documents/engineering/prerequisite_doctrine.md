# Prerequisite Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, documents/engineering/README.md

> **Purpose**: Philosophy and patterns for prerequisite-based validation in prodbox CLI.

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

---

## 2. Prerequisite Categories

### 2.1 Platform Prerequisites

Validate operating system and capabilities:

| Prerequisite | Validates |
|--------------|-----------|
| `platform_linux` | Running on Linux |
| `systemd_available` | systemd is present |

### 2.2 Tool Prerequisites

Validate external tools are installed:

| Prerequisite | Validates |
|--------------|-----------|
| `tool_kubectl` | kubectl CLI available |
| `tool_helm` | helm CLI available |
| `tool_pulumi` | pulumi CLI available |
| `tool_rke2` | RKE2 binary installed |
| `tool_systemctl` | systemctl available |

### 2.3 Configuration Prerequisites

Validate configuration files exist:

| Prerequisite | Validates |
|--------------|-----------|
| `settings_loaded` | Environment variables configured |
| `kubeconfig_exists` | Kubeconfig file present |
| `rke2_config_exists` | RKE2 config.yaml present |
| `rke2_killall_exists` | RKE2 killall cleanup script present |

### 2.4 Service Prerequisites

Validate services are running:

| Prerequisite | Validates |
|--------------|-----------|
| `rke2_service_exists` | RKE2 systemd unit exists |
| `rke2_service_active` | RKE2 service is running |
| `k8s_cluster_reachable` | Can connect to Kubernetes API |

### 2.5 AWS Prerequisites

Validate AWS/Route53 access:

| Prerequisite | Validates |
|--------------|-----------|
| `aws_credentials_valid` | AWS credentials configured |
| `route53_accessible` | Can access Route 53 API |

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
    effect=Pure(...),
    prerequisites=frozenset(["tool_kubectl", "kubeconfig_exists"]),
)
```

### 3.3 Automatic Expansion

When you depend on `k8s_cluster_reachable`, you automatically get:
- `tool_kubectl`
- `kubeconfig_exists`

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
- `rke2_ensure`: idempotent runtime provisioning/startup
- `rke2_cleanup`: non-destructive runtime teardown

Both nodes fail fast on missing RKE2 installation prerequisites:

```python
# File: src/prodbox/cli/dag_builders.py
_build_rke2_ensure_dag(...):
    prerequisites=frozenset(["rke2_installed", "rke2_config_exists", "systemd_available"])

_build_rke2_cleanup_dag(...):
    prerequisites=frozenset(["rke2_installed", "rke2_killall_exists", "systemd_available"])
```

`rke2_cleanup` intentionally avoids uninstall scripts and host-path deletion.

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

## Cross-References

- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Prerequisite Registry](../../src/prodbox/cli/prerequisite_registry.py)
- [Effect Types](../../src/prodbox/cli/effects.py)
