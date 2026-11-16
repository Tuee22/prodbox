# Platform and Application Services

**Status**: Authoritative source
**Supersedes**: Pre-refactor chart platform and local registry pipeline doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; application adapters are implemented in their owning phases

> **Purpose**: Define one service catalog, local/EKS projection, image delivery, storage, and readiness.

## Canonical catalog

One typed catalog owns chart identity, namespace, image, resources, dependencies, storage and readiness. Parser/help/config/schema, renderers and tests derive shared facts from it. A supported service is not installed by a separate test-only path.

| Service/platform | Required behavior |
|---|---|
| Gateway | Mesh/election, bounded semantic state and registered DNS intent |
| Keycloak + keycloak-postgres | OIDC, invitation/revocation and durable identity data through Percona PostgreSQL |
| VS Code | Browser IDE behind the supported edge authentication model |
| API | Authenticated HTTP API with enforced JWT semantics |
| Redis + websocket | Realtime shared state and authenticated websocket behavior |
| MinIO + registry:2 | Object storage and registry image storage/delivery; retain namespace compatibility only where migration needs it |
| Percona PostgreSQL operator | Stateful PostgreSQL/HA control and deterministic storage binding |
| Envoy Gateway + cert-manager | Gateway API routing, TLS and real ZeroSSL DNS01 |
| Pulsar broker/native client | Durable topic/envelope behavior under finite declared capacity |

Keep management-owned MinIO/Vault/Authority and application instances/scopes distinct where their lifetimes differ. Ordinary AWS deletion preserves the local management environment and local application/data scope.

## Shared projection and target adapters

The local kind and EKS projections use the same application semantics and image catalog. Local differences are host mounts, kind/container networking and MetalLB; EKS differences are AWS Load Balancer Controller, delegated subzone, EKS authentication and static EBS/AZ placement. Authority remains local kind.

Every app chart owns explicit dependencies and resource/storage declarations. PostgreSQL is supplied through the registered operator, not an ad-hoc single-container fallback. Render requests/limits, PVC sizes and namespace quotas from the same validated capacity plan. Do not infer lifetime from tags after choosing a resource.

## Image delivery and bootstrap

Management bootstrap loads exact pinned artifacts before registry availability. The in-cluster registry and MinIO backend exist on both targets. Workloads use the shared image references; target adapters make those references resolvable inside nodes.

Host, kind node and Pod `127.0.0.1` are different network namespaces. A localhost-style registry reference requires an explicit node containerd mirror/proxy mapping. Prove an uncached pull through that mapping after registry restart; a cached Pod launch is insufficient. Do not fix an unavailable EKS registry by rendering a different private image scheme.

Image identity includes platform/manifest digest and build provenance. Build/push/load operations are lifecycle-owned with bounded subprocesses and cleanup. Runtime union images include actual role prerequisites, not builder-only dependencies. [Dependency contract](dependency_management.md)

## Local traffic and storage

Phase 0 fixes MetalLB on the kind network plus explicit host ingress into Envoy. Phase 1 reserves ports; application delivery proves actual Docker-network, Service, host and intended LAN reachability. Keep Kubernetes API private. Do not advertise former RKE2/LAN addresses without a real path.

Use static host-backed PVs locally and pre-created static EBS on EKS. Recreate nodes/Pods and verify data and exact binding. `Retain` is volume-controller behavior; explicit AWS delete still removes owned production data volumes under its confirmed scope. [Storage](storage.md)

## Readiness and desired-state mutation

Liveness is bounded local health. Component readiness proves actual dependencies/protocol behavior, not only rollout status. Model failed/pending/unobservable explicitly. NetworkPolicy enforcement requires observed allow/deny traffic under the pinned CNI. Apply lifecycle permits to desired-state changes, not arbitrary `kubectl`/Helm work outside the engine.

`admin services delete` updates desired component selection durably before effects, so ordinary reconcile respects removal. Stop/restart is transient and separately named. Dependency checks prevent removing management capabilities that pending cloud work needs. Failed release recovery records original causes and observes cleanup; it cannot delete evidence then manufacture absence.

## Acceptance

Local delivery proves real SQL/auth/API/IDE/Redis/websocket/Pulsar behavior, persistence, registry recovery, network isolation and actual capacity. Public DNS/TLS/SES proof is introduced later and not faked to close local service delivery. EKS parity repeats these assertions with its real target adapters. [Acceptance catalog](../../DEVELOPMENT_PLAN/acceptance_cases.md)
