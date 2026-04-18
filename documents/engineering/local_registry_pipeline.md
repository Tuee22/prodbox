# Local Registry Pipeline

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md

> **Purpose**: Define how `prodbox` provisions Harbor, builds and pushes custom images via Docker
> CLI, and enforces local image-pull behavior for RKE2.

## 1. Scope

This document is the SSoT for the local image-registry doctrine:

1. Harbor is installed or reconciled during `prodbox rke2 install`.
2. Custom `prodbox` images are built outside the cluster via Docker CLI and pushed to Harbor.
3. RKE2 is configured to mirror `docker.io` pulls through local Harbor.
4. Missing mirrored images are populated on demand from currently referenced cluster images.

Retained storage and MinIO persistence doctrine remain defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md).

## 2. Current Runtime Contract

The supported `prodbox rke2 install` path is owned by `src/Prodbox/CLI/Rke2.hs`.

The native Haskell lifecycle runtime reconciles Harbor state in order:

1. Helm repository reconcile
2. Harbor chart upgrade or install
3. Harbor readiness-contract reconcile
4. Harbor readiness wait
5. Harbor project reconcile for `prodbox`
6. Docker login plus mirror, build, and push operations
7. Gateway image import into the RKE2 containerd cache
8. `registries.yaml` reconcile and conditional RKE2 restart

### 2.1 Harbor Readiness Contract

`prodbox` owns the bootstrap readiness contract for Harbor's external-serving `nginx` deployment.

Policy:

1. `prodbox` does not treat the chart-default `/` probe as the canonical readiness event.
2. `prodbox` patches `harbor-nginx` to publish a local `GET /readyz` response.
3. Readiness and liveness use `/readyz`.
4. Harbor bootstrap remains event-driven.
5. Docker login, Harbor API project reconcile, and image push operations are the final capability
   checks for the external NodePort path.

## 3. Runtime Outputs

`prodbox rke2 install` derives Harbor image targets deterministically from machine identity:

- `prodbox-id` source: `/etc/machine-id`
- image ref form: `127.0.0.1:30080/prodbox/prodbox-gateway:<prodbox-id-label>`
- additional custom image ref: `127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest`

## 4. RKE2 Mirror Behavior

`rke2 install` reconciles:

- file: `/etc/rancher/rke2/registries.yaml`
- mirror target: local Harbor endpoint (`127.0.0.1:30080`)
- rewrite policy: `docker.io` paths are rewritten into the Harbor `prodbox/` project path

If `registries.yaml` content changes, RKE2 is restarted once and cluster access is re-verified
before the effect succeeds.

## 5. Docker Hub Population

Population is idempotent and demand-driven:

1. enumerate currently referenced pod container images
2. normalize Docker Hub references
3. for each image:
   check Harbor manifest existence, pull only when missing, then tag and push once

## 6. Gateway Container Build Doctrine

Gateway image builds use `docker/gateway.Dockerfile` with full-repository build context.

Container build requirements:

1. build the Haskell gateway binary in the builder stage
2. copy the repository content needed by the build into the image context
3. keep `.dockerignore` synchronized with the intended build inputs
4. use `tini` as PID 1 in the runtime image
5. invoke the canonical CLI startup path through the Haskell gateway entrypoint

## 7. Operator Runbook

Recommended flow before gateway pod integration tests:

```bash
./.build/prodbox rke2 install
./.build/prodbox test integration gateway-pods
```

Image override remains available for explicit testing:

```bash
PRODBOX_GATEWAY_IMAGE=<explicit-image-ref> ./.build/prodbox test integration gateway-pods
```

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Documentation Standards](../documentation_standards.md)
