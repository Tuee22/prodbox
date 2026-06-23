# Local Registry Pipeline

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md
**Generated sections**: none

> **Purpose**: Define how `prodbox` provisions Harbor, bootstraps Harbor storage-backend
> prerequisites, publishes native-host-architecture custom images, mirrors required public images,
> and keeps
> later supported workloads on Harbor-backed image refs.

## 1. Scope

This document is the SSoT for the local image-registry doctrine:

1. Harbor is installed or reconciled during `prodbox cluster reconcile`.
2. Direct public-registry pulls are permitted only for Harbor itself and the current Harbor
   storage-backend bootstrap, presently MinIO, before Harbor is healthy and externally serving.
3. After Harbor is healthy and externally serving, later supported Helm workloads use Harbor-backed
   image refs.
4. Required public images are mirrored into Harbor idempotently after Harbor and its storage
   backend are healthy and before the later workloads that need them are deployed.
5. Custom `prodbox` images are built outside the cluster via Docker CLI and published to Harbor as
   native host-architecture images only, and no supported edge path depends on a
   repository-owned nginx auth-proxy image.

Retained storage and MinIO persistence doctrine remain defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md). The same MinIO server hosts
prodbox-owned object-store buckets; gateway object-store access uses the scoped
`prodbox-gateway` MinIO IAM principal, while Harbor storage uses its generated, persisted MinIO
user rather than the root credential. Administrative bucket bootstrap reads the MinIO root
credentials through Vault Kubernetes auth.

## 2. Runtime Contract

The authoritative `prodbox cluster reconcile` contract is owned by
`src/Prodbox/CLI/Rke2.hs`.

The native Haskell lifecycle reconciles Harbor state in this order:

1. Helm repository reconcile
2. Harbor storage-backend bootstrap from public `quay.io/minio/*` image refs, including MinIO
   reconcile plus Harbor-registry bucket and credential bootstrap. The bootstrap Job reads MinIO
   root credentials through the `minio` service account and Vault Kubernetes auth; Harbor itself
   receives a generated, persisted MinIO user in its storage Secret.
3. Harbor chart upgrade or install configured to use that storage backend
4. Harbor readiness-contract reconcile
5. Harbor readiness wait
6. Stable Harbor external-endpoint wait
7. Harbor project reconcile for `prodbox`
8. Docker login plus required public-image mirror into Harbor
9. Host-native custom-image build, push, and import for the single Haskell union runtime image
   (`prodbox-runtime`, shared by the gateway daemon and the `api`/`websocket` workloads)
10. `registries.yaml` reconcile and conditional RKE2 restart
11. Harbor-backed platform-runtime install for MetalLB, Envoy Gateway, cert-manager, and the
   Percona PostgreSQL operator
12. Optional Route 53 bootstrap A-record reconcile
13. MinIO steady-state re-reconcile, kept on the **public** `quay.io/minio/minio` image (never
    the Harbor mirror): MinIO is Harbor's own storage backend, so it cannot source its image from
    Harbor — a circular dependency a non-surging single-replica StatefulSet cannot break (a
    Harbor-sourced MinIO image would deadlock: MinIO down → Harbor 500 → MinIO `ImagePullBackOff`).
    The earlier bitnami Deployment masked this by surging a replacement pod before terminating the
    running one; the StatefulSet does not surge (Sprint 4.31).

The critical split is:

- pre-Harbor-ready public pulls: Harbor plus the current Harbor storage-backend bootstrap only
- post-Harbor-ready publication: mirror required public images and publish custom images into
  Harbor
- later Helm deployment: Harbor-backed images only

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

`prodbox cluster reconcile` derives Harbor image targets deterministically from machine identity:

- `prodbox-id` source: `/etc/machine-id`
- single union runtime image ref form (gateway daemon + `api`/`websocket` workloads):
  `127.0.0.1:30080/prodbox/prodbox-runtime:<prodbox-id-label>`
- supported mirrored public refs include Harbor-backed Percona operator, PostgreSQL, `pgBouncer`,
  and `pgBackRest` images, `code-server`, `keycloak`, `redis`, `minio`, `minio-mc`,
  `envoy-gateway-mirror`, `envoy-proxy-mirror`, `metallb`, `frr`, `kube-rbac-proxy`, and
  `cert-manager` images under the Harbor `prodbox` project

Platform-runtime and chart-runtime workloads consume those Harbor-backed refs after bootstrap.

### 3.1 Target Edge Image Implications

The supported public-edge doctrine uses this image set:

1. The supported edge image set includes the Envoy Gateway control-plane image plus the Envoy data
   plane images that back Gateway API listeners.
2. The supported public API and WebSocket workloads run from the single repository-owned union
   runtime image `prodbox-runtime` (the same image as the gateway daemon; the role is chosen by
   each chart's `args:`).
3. No supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
4. The Haskell distributed gateway runs from that same `prodbox-runtime` image (not replaced by
   Envoy Gateway).

### 3.2 One Release Value Per Substrate-Shared Platform Image

The mirrored platform images are substrate-equivalent by construction (Sprint 7.12). The home
local substrate and the AWS substrate mirror and consume the **same** image refs:

1. The Envoy Gateway control-plane image, the Envoy data-plane image, and the cert-manager image
   set are each pinned to exactly one `Prodbox.ContainerImage` release value — shared by the
   chart, the control plane, and the data plane. There is no separate per-substrate Envoy or
   cert-manager version, so the EG-control-plane-vs-Envoy-data-plane skew class (e.g. the
   EG-1.4.4 / Envoy-1.37 mismatch) cannot arise from this pipeline.
2. A lint forbids any `prodbox` code path from re-pinning a chart version or image ref
   conditionally on the active substrate; `Prodbox.Lib.AwsSubstratePlatform` consumes the shared
   `Prodbox.ContainerImage` values that the home reconcile uses rather than overriding them. A
   substrate-keyed re-pin is a build-time error, never a silent divergence.
3. Both installers draw the mirrored platform images from one shared `[PlatformComponent]`
   inventory (Harbor, MinIO, the Percona PostgreSQL operator, the substrate load balancer, Envoy
   Gateway, cert-manager). A coverage test asserts both installers cover every entry; the AWS
   substrate is **not** a "no-Harbor" cluster and uses the identical `127.0.0.1:30080/prodbox/...`
   refs (resolved on EKS via the EKS-side Harbor + node-local registry proxy).

This is the image-pipeline statement of the substrate-equivalence mechanism; the chart-platform
side is in
[helm_chart_platform_doctrine.md § 3A](./helm_chart_platform_doctrine.md#3a-substrate-equivalence-mechanism),
and the project-level rule is in [../../CLAUDE.md](../../CLAUDE.md) "Substrate Equivalence" and
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md).

## 4. RKE2 Mirror Behavior

`rke2 reconcile` reconciles:

- file: `/etc/rancher/rke2/registries.yaml`
- mirror target: local Harbor endpoint (`127.0.0.1:30080`)
- rewrite policy: `docker.io` paths are rewritten into the Harbor `prodbox/` project path

If `registries.yaml` content changes, RKE2 is restarted once and cluster access is re-verified
before the effect succeeds.

## 5. Public Image Population

Population is idempotent and host-architecture specific. It runs after Harbor and the current
Harbor storage backend are healthy:

1. enumerate the required supported-workload public images plus any already-referenced non-Harbor
   cluster images
2. normalize upstream refs into canonical registry-qualified image refs and ordered candidate
   source lists
3. map those refs into the Harbor `prodbox` project
4. pull the preferred candidate source for the current host architecture
5. if a preferred candidate later hits a transient Harbor availability failure during publication,
   retry that same candidate before falling through
6. if the candidate still fails during Harbor publication, purge the Harbor destination repository
   path and retry the next configured candidate source
7. retag the pulled source onto the Harbor target and push that host-native image only when the
   Harbor target for the current architecture is missing

The supported candidate sets include `mirror.gcr.io` fallbacks for the Docker Hub-hosted Percona
and Envoy images used by the current lifecycle, so clean-room reruns can survive unauthenticated
Docker Hub rate limiting without widening the supported steady-state image sources.

## 6. Union Runtime Container Build Doctrine

All repository-owned Haskell image builds use the single `docker/prodbox.Dockerfile` with
full-repository build context, producing one union runtime image (`prodbox-runtime`) for every
in-cluster role.

Container build requirements:

1. use single-stage `ubuntu:24.04` for the repository-owned Haskell image
2. build the Haskell `prodbox` binary under `/opt/build`
3. install `ghcup` in-image, pin GHC `9.12.4`, and do not create symlinked Haskell tool shims
4. build once through ordinary host-native `docker build`
5. push the resulting Harbor tags through ordinary `docker push`
6. keep `.dockerignore` synchronized with the intended build inputs
7. use `tini` as PID 1 in the runtime image
8. keep the `ENTRYPOINT` a bare `tini -- prodbox`; each chart selects its role through the pod
   `args:` (`gateway start` vs `workload start`)
9. install the official AWS CLI bundle from the image's native Debian architecture so the in-pod
   Route 53 subprocess path remains available (the gateway role uses it)

### 6.1 Host `docker` CLI auth isolation (Harbor login vs the operator's Docker Hub login)

prodbox publishes the images it builds to the in-cluster Harbor NodePort (`127.0.0.1:30080`) and
pulls public images using the operator's fixed-token Docker Hub login. Sprint `1.47` keeps those two
concerns separate with the **ephemeral `DOCKER_CONFIG`** pattern from the operator's `hostbootstrap`
project (`HostBootstrap.Registry`), implemented in `Prodbox.DockerConfig`. **No `docker login` runs
anywhere**, and the operator's global `~/.docker/config.json` is only ever read.

Each host-docker flow (`mirrorClusterImagesOnce`, `ensureCustomImageVariantsHomeLocal`, and the AWS
host build) runs inside `withEphemeralDockerConfig`, which:

- **Discovers the host `docker.io` auth read-only.** It reads
  `${DOCKER_CONFIG:-$HOME/.docker}/config.json` and projects a **minimal `docker.io`-only** set
  (`dockerHubAuthFromConfig` keeps only registry keys mentioning `docker.io`, excluding any local
  Harbor / private-registry entries). No host login ⇒ `Nothing` ⇒ anonymous pulls (graceful degrade).
- **Materialises a throwaway `DOCKER_CONFIG`.** `renderEphemeralDockerConfig` writes a `config.json`
  into a `withSystemTempDirectory "prodbox-docker-config"` whose `auths` hold that `docker.io` entry
  (if any) **plus an inline Harbor `127.0.0.1:30080` entry** (`base64 admin:Harbor12345`, no
  `credsStore`) — so Harbor pushes authenticate **without** a `docker login`. `DOCKER_CONFIG` points
  the process at it for the flow, then a `bracket` **scrubs the temp dir and restores the prior
  `DOCKER_CONFIG`** on exit. Nothing persists in `~/prodbox`.

Inside the bracket, plain `docker` subprocesses inherit `DOCKER_CONFIG`; pulls/builds use the host
Docker Hub login (rate-limit headroom), pushes use the inline Harbor auth. Because prodbox **never
writes** `~/.docker/config.json`, it cannot disturb the operator's carefully-managed (fixed-token)
Docker Hub state. The home Harbor-project creation uses the Harbor REST API (`curl -u
admin:Harbor12345`), not a docker login, and its readiness is gated by the `waitForHarbor*` probes.

In-cluster pulls are unaffected: RKE2 `/etc/rancher/rke2/registries.yaml` and the EKS
containerd-mirror DaemonSet reach Harbor's NodePort credential-free and never consult a Docker
config. The local-only `docker image inspect` (`Prodbox.Lib.ChartPlatform`) and the dev-only
`docker run` for the TLA+ image (`Prodbox.Tla`) neither write nor depend on the Harbor credential
and are out of scope. The `docker.io` discovery/projection is the seam that later swaps onto
`HostBootstrap.Registry` at the planned hostbootstrap refactor.

**Operator note:** if `~/.docker/config.json` already carries a stale `127.0.0.1:30080` entry from a
prior prodbox version, remove it once with `docker logout 127.0.0.1:30080` (leaves the
`index.docker.io` login untouched). prodbox will not touch the global file — including to clean it.

## 7. Operator Runbook

Recommended flow before gateway or public-edge workload integration tests:

```bash
prodbox cluster reconcile
prodbox test integration gateway-pods
prodbox test integration charts-api
prodbox test integration charts-websocket
```

There is no `PRODBOX_*_IMAGE` (or any other `PRODBOX_*`) environment-variable override: no
supported `prodbox` binary reads `PRODBOX_*` environment variables, per
[config_doctrine.md](./config_doctrine.md). The single union runtime image ref is derived
deterministically from machine identity (§3) into the Harbor `prodbox` project;
there is no env-var seam to substitute an explicit ref. Tests run the canonical commands above
against the Harbor-published image set produced by `prodbox cluster reconcile`.

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Documentation Standards](../documentation_standards.md)
