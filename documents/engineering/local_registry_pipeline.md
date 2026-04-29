# Local Registry Pipeline

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md

> **Purpose**: Define how `prodbox` provisions Harbor, bootstraps Harbor storage-backend
> prerequisites, publishes dual-arch custom images, mirrors required public images, and keeps
> later supported workloads on Harbor-backed image refs.

## 1. Scope

This document is the SSoT for the local image-registry doctrine:

1. Harbor is installed or reconciled during `prodbox rke2 install`.
2. Direct public-registry pulls are permitted only for Harbor itself and the MinIO bootstrap that
   makes Harbor's storage backend functional before Harbor is healthy and externally serving.
3. After Harbor is healthy and externally serving, later supported Helm workloads use Harbor-backed
   image refs.
4. Required public images are mirrored into Harbor idempotently after Harbor and its storage
   backend are healthy and before the later workloads that need them are deployed.
5. Custom `prodbox` images are built outside the cluster via Docker CLI and published to Harbor as
   `linux/amd64` plus `linux/arm64` manifests, and the long-term supported edge does not require a
   permanent app-local `vscode-nginx` image.

Retained storage and MinIO persistence doctrine remain defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md).

## 2. Current Runtime Contract

The supported `prodbox rke2 install` path is owned by `src/Prodbox/CLI/Rke2.hs`.

The native Haskell lifecycle reconciles Harbor state in order:

1. Helm repository reconcile
2. Harbor chart upgrade or install
3. Harbor readiness-contract reconcile
4. Harbor readiness wait
5. Stable Harbor external-endpoint wait
6. Harbor project reconcile for `prodbox`
7. MinIO bootstrap install from public `quay.io/minio/*` image refs
8. Docker login plus required public-image mirror into Harbor
9. Multi-platform custom-image publish and host-arch import for the Haskell gateway and the
   current-worktree `vscode-nginx` migration-residue image
10. `registries.yaml` reconcile and conditional RKE2 restart
11. Harbor-backed platform-runtime install for MetalLB, the current Traefik baseline or the target
   Envoy Gateway edge controller, cert-manager, and the Percona
   PostgreSQL operator
12. Optional Route 53 bootstrap A-record reconcile
13. MinIO steady-state reconcile onto Harbor-backed image refs

The critical split is:

- pre-Harbor-ready public pulls: Harbor plus MinIO bootstrap only
- post-Harbor-ready publication: mirror required public images and publish custom images into
  Harbor
- later Helm deployment: Harbor-backed images only

Custom-image publication uses a `docker-container` buildx builder created with host networking.
That builder contract is required because the canonical Harbor push target remains the local
NodePort endpoint `127.0.0.1:30080`, and buildx export or push traffic must resolve that address
from inside the builder container as well as from the host.

### 2.1 Harbor Readiness Contract

`prodbox` owns the bootstrap readiness contract for Harbor's external-serving `nginx` deployment.

Policy:

1. `prodbox` does not treat the chart-default `/` probe as the canonical readiness event.
2. `prodbox` patches `harbor-nginx` to publish a local `GET /readyz` response.
3. Readiness and liveness use `/readyz`.
4. Harbor bootstrap remains event-driven.
5. Docker login, Harbor API project reconcile, and image push operations are the final capability
   checks for the external NodePort path.
6. Before Docker login, `prodbox` requires `GET /readyz` to return `200` and `GET /v2/` to return
   `200` or `401` on `127.0.0.1:30080`.
7. Before any Harbor image write continues on a fresh cluster, `prodbox` requires six consecutive
   successful probe rounds, spaced five seconds apart, where `/readyz` returns `200` and `/v2/`
   returns `200` or `401`.

## 3. Runtime Outputs

`prodbox rke2 install` derives Harbor image targets deterministically from machine identity:

- `prodbox-id` source: `/etc/machine-id`
- image ref form: `127.0.0.1:30080/prodbox/prodbox-gateway:<prodbox-id-label>`
- additional custom image ref: `127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest`
- supported mirrored public refs include Harbor-backed Percona operator, PostgreSQL, `pgBouncer`,
  and `pgBackRest` images, `code-server`, `keycloak`, `minio`, `minio-mc`, `traefik`, `metallb`,
  `frr`, `kube-rbac-proxy`, and `cert-manager` images under the Harbor `prodbox` project

Platform-runtime and chart-runtime workloads consume those Harbor-backed refs after bootstrap.

### 3.1 Target Edge Image Implications

The target public-edge doctrine changes the expected image set:

1. Traefik images become removable migration residue.
2. The supported edge image set becomes the Envoy Gateway control-plane image plus the Envoy data
   plane images that back Gateway API listeners.
3. `prodbox-nginx-oidc` becomes removable once Envoy Gateway `SecurityPolicy` owns the browser
   auth flow.
4. The Haskell distributed gateway image remains a separate repository-owned image and is not
   replaced by Envoy Gateway.

## 4. RKE2 Mirror Behavior

`rke2 install` reconciles:

- file: `/etc/rancher/rke2/registries.yaml`
- mirror target: local Harbor endpoint (`127.0.0.1:30080`)
- rewrite policy: `docker.io` paths are rewritten into the Harbor `prodbox/` project path

If `registries.yaml` content changes, RKE2 is restarted once and cluster access is re-verified
before the effect succeeds.

## 5. Public Image Population

Population is idempotent and dual-arch. It runs after Harbor and the local MinIO-backed backend
are healthy:

1. enumerate the required supported-workload public images plus any already-referenced non-Harbor
   cluster images
2. normalize upstream refs into canonical registry-qualified image refs and ordered candidate
   source lists
3. map those refs into the Harbor `prodbox` project
4. verify a candidate source publishes both `linux/amd64` and `linux/arm64`
5. if a preferred candidate later fails during Harbor publication, purge the Harbor destination
   repository path and retry the next configured candidate source
6. create the Harbor target manifest only when the Harbor target is missing one of those
   architectures

This is why inspect-time success is not sufficient: the later
`docker buildx imagetools create` step still depends on the source registry being usable for
digest fetches all the way through publication.

## 6. Gateway Container Build Doctrine

Gateway image builds use `docker/gateway.Dockerfile` with full-repository build context.

Container build requirements:

1. use single-stage `ubuntu:24.04` for repository-owned Haskell images
2. build the Haskell gateway binary under `/opt/build`
3. install `ghcup` in-image, pin GHC `9.14.1`, and do not create symlinked Haskell tool shims
4. publish `linux/amd64` plus `linux/arm64` together through
   `docker buildx build --platform linux/amd64,linux/arm64 --push`
5. create or reuse the `docker-container` buildx builder with host networking so Harbor pushes to
   `127.0.0.1:30080` succeed from inside the builder
6. keep `.dockerignore` synchronized with the intended build inputs
7. use `tini` as PID 1 in the runtime image
8. invoke the canonical CLI startup path through the Haskell gateway entrypoint
9. install the official AWS CLI bundle per `TARGETARCH` so the in-pod Route 53 subprocess path
    remains available inside the single-stage gateway image

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
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Documentation Standards](../documentation_standards.md)
