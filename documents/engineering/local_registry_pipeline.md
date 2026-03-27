# Local Registry Pipeline

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md

> **Purpose**: Define how prodbox provisions Harbor, builds/pushes custom images via Docker CLI, and enforces local image pull behavior for RKE2.

---

## 1. Scope

This document is the SSoT for the local image-registry doctrine:

1. Harbor is installed/reconciled during `prodbox rke2 ensure`.
2. Custom prodbox images are built outside the cluster via Docker CLI and pushed to Harbor.
3. RKE2 is configured to mirror `docker.io` pulls through local Harbor.
4. Missing mirrored images are populated on demand (once) from currently referenced cluster images.

Retained storage and MinIO persistence doctrine are intentionally out-of-scope here and defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md).

---

## 2. eDAG Contract

`rke2_ensure` includes a dedicated effect node:

```python
# File: src/prodbox/cli/effects.py
@dataclass(frozen=True)
class EnsureHarborRegistry(Effect[HarborRuntime]):
    machine_identity: MachineIdentity
    ...
```

The node returns `HarborRuntime` and executes in railway-order sequence:

1. Helm repository reconcile.
2. Harbor chart `upgrade --install`.
3. Prodbox-owned Harbor nginx readiness-contract reconcile.
4. Harbor readiness wait.
5. Harbor project reconcile for `prodbox` image/mirror namespace.
6. Docker login + mirror/build/push operations.
7. Import gateway image into RKE2 containerd cache.
8. `registries.yaml` reconcile and conditional RKE2 restart.

### 2.1 Harbor Readiness Contract

`prodbox` owns the bootstrap readiness contract for Harbor's external-serving `nginx`
Deployment.

Policy:

1. `prodbox` MUST NOT treat the Harbor chart's default `harbor-nginx` `/` probe as the
   canonical readiness event for `rke2 ensure`.
2. `prodbox` MUST patch the `harbor-nginx` ConfigMap to publish a local `GET /readyz`
   response from nginx itself.
3. `prodbox` MUST patch the `harbor-nginx` Deployment so readiness and liveness use
   `/readyz`.
4. Harbor bootstrap MUST remain event-driven: `harbor-core` and `harbor-registry`
   availability are waited independently, and `harbor-nginx` availability is consumed
   only after the local `/readyz` contract is applied.
5. Docker login, Harbor API project reconcile, and image push operations remain the
   capability checks for the external NodePort path (`127.0.0.1:30080`).

Rationale:

- The chart-default `harbor-nginx` `/` probe traverses the proxied UI path and can report
  false-not-ready during cold bootstrap even when nginx itself is healthy enough to serve
  Harbor API and registry traffic once backend components are available.
- Publishing a local `/readyz` endpoint makes the Kubernetes readiness event represent
  nginx serve capability instead of upstream UI timing.
- This doctrine forbids sleep-based retry compensation in `prodbox`; readiness must come
  from component events and direct capability checks.

---

## 3. Runtime Outputs

`EnsureHarborRegistry` returns:

```python
# File: src/prodbox/cli/effects.py
@dataclass(frozen=True)
class HarborRuntime:
    registry_endpoint: str
    gateway_image: str
```

`gateway_image` is derived deterministically from machine identity:

- `prodbox-id` source: `/etc/machine-id` prerequisite pipeline
- image ref form: `127.0.0.1:30080/prodbox/prodbox-gateway:<prodbox-id-label>`

---

## 4. RKE2 Mirror Behavior

`rke2 ensure` reconciles:

- file: `/etc/rancher/rke2/registries.yaml`
- mirror target: local Harbor endpoint (`127.0.0.1:30080`)
- rewrite policy: `docker.io` paths are rewritten into Harbor `prodbox/` project path

If `registries.yaml` content changes, RKE2 is restarted once, then cluster access is re-verified before the effect succeeds.

---

## 5. Docker Hub Population

Population is idempotent and demand-driven:

1. Enumerate currently referenced pod container images.
2. Normalize docker-hub references.
3. For each image:
   1. Check Harbor manifest existence.
   2. Pull from Docker Hub only when missing.
   3. Tag/push once into Harbor.

This keeps mirror state convergent without repeatedly re-pulling/pushing already mirrored images.

---

## 6. Gateway Container Build Doctrine

Gateway image builds MUST use `docker/gateway.Dockerfile` with full-repository build context.

Container build requirements:

1. Install Poetry explicitly via pip:

```bash
python -m pip install --upgrade pip setuptools wheel poetry
```

2. Copy repository root into container image:

```dockerfile
# File: docker/gateway.Dockerfile
COPY . /app
```

3. Keep `.dockerignore` synchronized with `.gitignore` (mirrored patterns).
4. Override `poetry.toml` inside container build so Poetry does not create virtualenvs:

```toml
# File: poetry.toml
[virtualenvs]
create = false
```

5. Do not set `PYTHONDONTWRITEBYTECODE` or `PYTHONUNBUFFERED` in this image.
6. Use `tini` as PID 1 and invoke daemon through it:

```dockerfile
# File: docker/gateway.Dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "daemon"]
```

## 7. Operator Runbook

Recommended flow before gateway pod integration tests:

```bash
poetry run prodbox rke2 ensure
poetry run prodbox test integration gateway-pods
```

Image override remains available for explicit testing:

```bash
PRODBOX_GATEWAY_IMAGE=<explicit-image-ref> poetry run prodbox test integration gateway-pods
```

---

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Documentation Standards](../documentation_standards.md)
