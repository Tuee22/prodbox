# Local Registry Pipeline

**Status**: Authoritative source
**Supersedes**: the prior Harbor-based local-registry doctrine (multi-pod Harbor Helm stack, Harbor
projects REST API, and the `admin:Harbor12345` credential), retired when the in-cluster registry
became a single-binary `registry:2`.
**Referenced by**: README.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/storage_lifecycle_doctrine.md, documents/engineering/host_platform_doctrine.md, documents/engineering/bootstrap_readiness_doctrine.md
**Generated sections**: none

> **Purpose**: Define how `prodbox` provisions the in-cluster single-binary `registry:2` (CNCF
> distribution) registry, bootstraps its MinIO/S3 storage-backend prerequisites, publishes
> native-host-architecture custom images, mirrors required public images, and keeps later
> supported workloads on registry-backed image refs.

Implementation and deployment-qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md); dated sprint references below are historical
provenance, not a parallel status ledger.

> **Naming note**: for continuity and to minimize churn, the Kubernetes namespace and front-door
> Service are still named `harbor`, and internal storage identifiers (the `harbor-registry-s3`
> Secret, the `prodbox-harbor-registry` MinIO bucket, and the `ensureHarborRegistryRuntime`
> reconciler) retain the historical `harbor` name. The registry software itself is `registry:2`,
> not Harbor. The namespace was **not** renamed to `registry`.

## 1. Scope

This document is the SSoT for the local image-registry doctrine:

1. The `registry:2` registry is installed or reconciled during `prodbox cluster reconcile`. It is a
   single `registry:2` Deployment plus a NodePort Service (nodePort `30080`) plus a ConfigMap
   holding `registry:2`'s `config.yml`, all applied with `kubectl apply` — there is **no Helm
   release** for the registry. A legacy Harbor Helm release is a registered managed resource whose
   desired-absence plan runs before the conflicting registry apply and requires absence read-back.
2. Direct public-registry pulls are permitted only for the registry itself and the current
   registry storage-backend bootstrap, presently MinIO, before the registry is healthy and
   serving.
3. After the registry is healthy and serving, later supported Helm workloads use registry-backed
   image refs.
4. Required public images are mirrored into the registry idempotently after the registry and its
   storage backend are healthy and before the later workloads that need them are deployed.
5. Custom `prodbox` images are built outside the cluster via Docker CLI and pushed to the registry
   as native host-architecture images only, and no supported edge path depends on a
   repository-owned nginx auth-proxy image.

Retained storage and MinIO persistence doctrine remain defined in
[Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md). The same MinIO server hosts
prodbox-owned object-store buckets. The Lifecycle Authority uses a dedicated MinIO IAM principal
for its bounded aggregate and immutable checkpoint-blob namespace, while the registry stores its
blobs in the MinIO-backed
`prodbox-harbor-registry` bucket through its generated, persisted MinIO user rather than the root
credential. Administrative bucket bootstrap reads the MinIO root credentials through Vault
Kubernetes auth. The Gateway Runtime has no registry-storage, lifecycle-CAS, or generic MinIO
authority.

## 2. Runtime Contract

The authoritative `prodbox cluster reconcile` contract is owned by
`src/Prodbox/CLI/Rke2.hs`.

The target native Haskell lifecycle reconciles registry state in this order:

1. Observe the exact legacy Harbor release. If present, execute its committed
   `ReconcileManagedResourceAbsent` intent and read back absence. Failure/unobservability is typed,
   retained in the cleanup report, and blocks only the conflicting registry apply—not independent
   always-run cleanup.
2. Registry storage-backend bootstrap from public `quay.io/minio/*` image refs, including MinIO
   reconcile plus the `prodbox-harbor-registry` bucket and credential bootstrap. The bootstrap Job
   reads MinIO root credentials through the `minio` service account and Vault Kubernetes auth; the
   registry itself receives a generated, persisted MinIO user in its `harbor-registry-s3` storage
   Secret (whose keys are `REGISTRY_STORAGE_S3_ACCESSKEY` / `REGISTRY_STORAGE_S3_SECRETKEY`,
   injected via `envFrom`).
3. `kubectl apply` of the `registry:2` Deployment, its NodePort Service (nodePort `30080`), and the
   `config.yml` ConfigMap, configured to use that MinIO-backed S3 storage driver
   (`storage.s3` in `config.yml`).
4. Registry readiness-contract reconcile (`GET /v2/`).
5. Registry readiness wait.
6. Stable registry external-endpoint wait.
7. Required public-image mirror into the registry (anonymous push — see below). Repositories
   auto-create on first push, so there is **no** projects REST API reconcile.
8. Host-native custom-image build, push, and import for the single Haskell union runtime image
   (`prodbox-runtime`, shared by the gateway daemon and the `api`/`websocket` workloads).
9. `registries.yaml` reconcile and conditional RKE2 restart.
10. Registry-backed platform-runtime install for MetalLB, Envoy Gateway, cert-manager, and the
    Percona PostgreSQL operator.
11. On home only, exact registered Gateway-DNS A-record reconcile through its bounded capability.
    The current optional direct Route 53 bootstrap call is pre-cutover residue removed by Sprint
    `4.50`; AWS-substrate A records are Lifecycle Authority provider intents owned by Sprint `7.33`.
12. MinIO steady-state re-reconcile, kept on the **public** `quay.io/minio/minio` image (never
    the registry mirror): MinIO is the registry's own storage backend, so it cannot source its
    image from the registry — a circular dependency a non-surging single-replica StatefulSet
    cannot break (a registry-sourced MinIO image would deadlock: MinIO down → registry 5xx → MinIO
    `ImagePullBackOff`). The earlier bitnami Deployment masked this by surging a replacement pod
    before terminating the running one; the StatefulSet does not surge (Sprint 4.31).

Push is **anonymous over plain HTTP**: a localhost NodePort is insecure-by-default in Docker, so
there is no `docker login`, no admin credential, and no TLS for pushes into the registry. The
MinIO→registry circular-dependency ordering (MinIO public bootstrap → registry → mirror → MinIO
steady-state) is unchanged.

The critical split is:

- pre-registry-ready public pulls: the registry plus the current registry storage-backend
  bootstrap only
- post-registry-ready publication: mirror required public images and push custom images into the
  registry
- later Helm deployment: registry-backed images only

### 2.1 Registry Readiness Contract

`prodbox` owns the bootstrap readiness contract for the registry's external-serving NodePort.

The registry dependency is represented by one operation-indexed `CapabilityRef`. Front-door
observation, deep-edge admission, and the first image-write execution retain that exact reference,
including service identity and backend coordinate; a probe result cannot be combined with another
endpoint. All queue wait, probe, retry, and write/read-back work consumes one monotonic absolute
deadline. This capability discipline and the dedicated Broker/Authority/Agent/Gateway boundaries
are defined in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

Policy:

1. Registry readiness is a plain `GET /v2/` probe on `127.0.0.1:30080`, expecting HTTP `200` or
   `401`. There is no nginx `/readyz` readiness patch — `registry:2` serves the OCI distribution
   API directly, so `/v2/` is the canonical readiness event.
2. Registry bootstrap remains event-driven.
3. The `/v2/` probe on the external NodePort path is a **front-door pre-check**, not the final
   barrier before image writes (see point 5).
4. `prodbox` requires six consecutive successful `GET /v2/` rounds, spaced five seconds apart
   (returning `200` or `401` on `127.0.0.1:30080`), as the front-door pre-check before the deep gate.
5. `GET /v2/` is a **front-door** signal: `registry:2` answers it without touching S3, so it does
   **not** prove the registry → MinIO storage-backend write edge. Per the
   [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md) M3, the **final barrier before
   any image write** (home substrate, Sprint `4.43`) is the deep gate
   `ensureRegistryStorageBackendEdgeReady`: it opens a blob-upload session against the registry
   (`POST /v2/<name>/blobs/uploads/`), which the S3 storage driver services by writing to MinIO, so a
   `201`/`202` proves the registry reached its MinIO backend. A curl-level failure is `Unreachable`
   and gates closed (doctrine Statement 4); a registry `5xx` (it cannot reach MinIO) is retryable.
   This runs before `mirrorClusterImagesOnce` and every downstream registry write, closing the
   transient `minio.prodbox.svc.cluster.local` resolution race that front-door-only gating left open.
   The S3 storage-backend config this edge depends on carries the load-bearing `redirect.disable: true`
   (the `127.0.0.1:30080` NodePort cannot follow S3 presigned redirects to cluster-internal MinIO DNS).
   Sprint `4.44` replaces the former zero-argument untyped policy block with a required
   `RegistryStorageBackend` value. Its `registryStorageBackendRedirect :: RedirectPolicy` always
   renders explicitly: `RedirectDisabled` becomes `disable: true`, `RedirectEnabled` becomes
   `disable: false`, and canonical `harborRegistryStorageBackend` chooses `RedirectDisabled`.
   `registryConfigYaml` intentionally remains a deterministic `unlines` renderer; the guarantee is
   that the typed input cannot omit the redirect decision, not that YAML line assembly disappeared.
   The backend also uses the stable `harborRegistryStorageRegion = "us-east-1"` constant. The golden
   at `test/golden/config/registry-config.yaml` pins the canonical output, including
   `redirect.disable: true`, and unit coverage pins the alternate `false` rendering (the dropped
   redirect line caused the 80a08e3 bring-up regression).

**Historical pre-cutover implementation.** `ensureHarborRegistryRuntime` currently invokes
`helm uninstall` as an always-success best-effort helper that discards failure. Sprint `4.50`
replaces that helper with the registered absence program above; the current behavior is not target
cleanup semantics and cannot satisfy deployment qualification.

   Registry credentials are unchanged: `REGISTRY_STORAGE_S3_ACCESSKEY` and
   `REGISTRY_STORAGE_S3_SECRETKEY` remain keys in the existing `harbor-registry-s3` Secret and enter
   the Deployment through `envFrom`; they are not fields of `RegistryStorageBackend` and do not
   appear in the ConfigMap. Sprint `4.44` adds no Kubernetes/AWS resource and changes no
   `ResourceRegistry` ownership; the existing ConfigMap, Deployment, Service, Secret, and bucket
   keep their current owners. The
   shared constructor-owned transient-fragment base and the no-new-inline-list `CheckCode` guard now
   live in `src/Prodbox/Service.hs` / `src/Prodbox/CheckCode.hs` (Sprint `1.57`). Sprint `4.46` moved
   the home registry-publication caller onto that base, retaining only its PUT-status extension; the
   EKS edge caller joined the same base in Sprint `7.32`. The shared name-resolution, connection,
   transient-HTTP, and timeout classes therefore bound residual jitter on both substrates without
   duplicating a per-path list. The Sprint `1.59` `BackendRoundTripTarget` and injected one-shot
   registry→MinIO bindings are historical pre-redesign behavior. The target resolves one
   operation-indexed registry-publication `CapabilityRef`; observation, admission, blob
   mutation/read-back, and the subsequent write share its service/storage identity and absolute
   deadline. A front-door or separately bound backend probe cannot authorize publication. The AWS
   substrate's historical deep-gate work (Sprint `7.31`) was:
   `ensureAwsSubstratePlatformRuntime` runs the same
   `ensureRegistryStorageBackendEdgeReady` gate before the EKS image-mirror Job and crane pushes, and
   `applyEksImageMirrorJob` re-applies the Job on an `isRetryableEksImageMirrorFailure`-matched
   transient failure.

## 3. Runtime Outputs

`prodbox cluster reconcile` derives registry image targets deterministically from machine identity:

- `prodbox-id` source: `/etc/machine-id`
- single union runtime image ref form (gateway daemon + `api`/`websocket` workloads):
  `127.0.0.1:30080/prodbox/prodbox-runtime:<prodbox-id-label>`
- supported mirrored public refs include registry-backed Percona operator, PostgreSQL, `pgBouncer`,
  and `pgBackRest` images, `code-server`, `keycloak`, `redis`, `minio`, `minio-mc`,
  `envoy-gateway-mirror`, `envoy-proxy-mirror`, `metallb`, `frr`, `kube-rbac-proxy`, and
  `cert-manager` images under the registry `prodbox/` path

Platform-runtime and chart-runtime workloads consume those registry-backed refs after bootstrap.

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
   inventory (the registry, MinIO, the Percona PostgreSQL operator, the substrate load balancer,
   Envoy Gateway, cert-manager). A coverage test asserts both installers cover every entry; the
   AWS substrate is **not** a "no-registry" cluster and uses the identical
   `127.0.0.1:30080/prodbox/...` refs (resolved on EKS via the EKS-side registry + node-local
   registry proxy).

This is the image-pipeline statement of the substrate-equivalence mechanism; the chart-platform
side is in
[helm_chart_platform_doctrine.md § 3A](./helm_chart_platform_doctrine.md#3a-substrate-equivalence-mechanism),
and the project-level rule is in [../../CLAUDE.md](../../CLAUDE.md) "Substrate Equivalence" and
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md).

## 4. RKE2 Mirror Behavior

`rke2 reconcile` reconciles:

- file: `/etc/rancher/rke2/registries.yaml`
- mirror target: local registry endpoint (`127.0.0.1:30080`)
- rewrite policy: `docker.io` paths are rewritten into the registry `prodbox/` path

If `registries.yaml` content changes, RKE2 is restarted once and cluster access is re-verified
before the effect succeeds.

## 5. Public Image Population

Population is idempotent and host-architecture specific. It runs after the registry and the current
registry storage backend are healthy:

1. enumerate the required supported-workload public images plus any already-referenced
   non-registry cluster images
2. normalize upstream refs into canonical registry-qualified image refs and ordered candidate
   source lists
3. map those refs into the registry `prodbox/` path
4. pull the preferred candidate source for the current host architecture
5. if a preferred candidate later hits a transient registry availability failure during
   publication, retry that same candidate before falling through
6. if the candidate still fails during registry publication, purge the registry destination
   repository path and retry the next configured candidate source
7. retag the pulled source onto the registry target and push that host-native image only when the
   registry target for the current architecture is missing

The supported candidate sets include `mirror.gcr.io` fallbacks for the Docker Hub-hosted Percona
and Envoy images used by the current lifecycle, so clean-room reruns can survive unauthenticated
Docker Hub rate limiting without widening the supported steady-state image sources.

## 6. Union Runtime Container Build Doctrine

All repository-owned Haskell image builds use the single `docker/prodbox.Dockerfile` with
full-repository build context, producing one union runtime image (`prodbox-runtime`) for every
in-cluster role.

This native-host-architecture image publication extends across the macOS (Lima) and Windows
(WSL2) host providers per [host_platform_doctrine.md](./host_platform_doctrine.md): the build runs
inside the OS-appropriate Linux frame, so everything Docker-inward stays OS-agnostic Linux. Sprint
`4.37` lands the pure `Prodbox.DockerConfig.dockerLinuxFrameDispatch` helper that re-invokes
prodbox directly on Linux and through the Lima/WSL2 frame on non-Linux hosts.

Container build requirements:

1. use single-stage `ubuntu:24.04` for the repository-owned Haskell image
2. build the Haskell `prodbox` binary under `/opt/build`
3. install `ghcup` in-image, pin GHC `9.12.4`, and do not create symlinked Haskell tool shims
4. build once through ordinary host-native `docker build`
5. push the resulting registry tags through ordinary `docker push`
6. keep `.dockerignore` synchronized with the intended build inputs
7. use `tini` as PID 1 in the runtime image
8. keep the `ENTRYPOINT` a bare `tini -- prodbox`; each chart selects its role through the pod
   `args:` (`gateway start` vs `workload start`)
9. the current union image may retain the official AWS CLI bundle for the fenced lifecycle-provider
   worker during cutover, but target Gateway-DNS uses its bounded managed adapter and Gateway
   Runtime cannot invoke `aws route53`; the direct in-pod Gateway subprocess path is Sprint `4.50`
   removal residue

### 6.1 Host `docker` CLI auth isolation (registry push vs the operator's Docker Hub login)

prodbox pushes the images it builds to the in-cluster registry NodePort (`127.0.0.1:30080`)
anonymously and pulls public images using the operator's fixed-token Docker Hub login. Sprint
`1.47` keeps those two concerns separate with the **ephemeral `DOCKER_CONFIG`** pattern from the
operator's `hostbootstrap` project (`HostBootstrap.Registry`), implemented in
`Prodbox.DockerConfig`. **No `docker login` runs anywhere** — the localhost NodePort registry is
anonymous over HTTP — and the operator's global `~/.docker/config.json` is only ever read.

Each host-docker flow (`mirrorClusterImagesOnce`, `ensureCustomImageVariantsHomeLocal`, and the AWS
host build) runs inside `withEphemeralDockerConfig`, which:

- **Discovers the host `docker.io` auth read-only.** It reads
  `${DOCKER_CONFIG:-$HOME/.docker}/config.json` and projects a **minimal `docker.io`-only** set
  (`dockerHubAuthFromConfig` keeps only registry keys mentioning `docker.io`, excluding any local
  registry / private-registry entries). No host login ⇒ `Nothing` ⇒ anonymous pulls (graceful
  degrade).
- **Materialises a throwaway `DOCKER_CONFIG`.** `renderEphemeralDockerConfig` writes a `config.json`
  into a `withSystemTempDirectory "prodbox-docker-config"` whose `auths` hold **only** that
  read-only `docker.io` entry (if any) — for Docker Hub rate-limit headroom on pulls. There is no
  registry auth entry: pushes to `127.0.0.1:30080` are anonymous, so no credential is materialised.
  `DOCKER_CONFIG` points the process at it for the flow, then a `bracket` **scrubs the temp dir and
  restores the prior `DOCKER_CONFIG`** on exit. Nothing persists in `~/prodbox`.

Inside the bracket, plain `docker` subprocesses inherit `DOCKER_CONFIG`; pulls/builds use the host
Docker Hub login (rate-limit headroom), and pushes to the registry are anonymous. Because prodbox
**never writes** `~/.docker/config.json`, it cannot disturb the operator's carefully-managed
(fixed-token) Docker Hub state. Repositories auto-create on first push, so there is no
project-creation REST call and no readiness gate beyond the `/v2/` probes of §2.1.

In-cluster pulls are unaffected: RKE2 `/etc/rancher/rke2/registries.yaml` and the EKS
containerd-mirror DaemonSet reach the registry's NodePort credential-free and never consult a Docker
config. The local-only `docker image inspect` (`Prodbox.Lib.ChartPlatform`) and the dev-only
`docker run` for the TLA+ image (`Prodbox.Tla`) neither write nor depend on any registry credential
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
deterministically from machine identity (§3) into the registry `prodbox/` path;
there is no env-var seam to substitute an explicit ref. Tests run the canonical commands above
against the registry-published image set produced by `prodbox cluster reconcile`.

## Cross-References

- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Documentation Standards](../documentation_standards.md)
