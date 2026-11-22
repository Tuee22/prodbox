# Retained kind Control Plane

**Status**: Authoritative source
**Supersedes**: Pre-refactor RKE2 management topology and bootstrap readiness ownership
**Generated sections**: none
**Applicability**: Adopted target contract; current RKE2 code remains until its phase-owned replacement

> **Purpose**: Define local kind bootstrap, physical dependencies, management recovery, and readiness.

## Placement

The control machine runs the sole retained kind management cluster for a deployment. Vault, MinIO, Broker, Authority, Provider, Provisioner and narrow backup/TLS/target-delivery roles remain Kubernetes workloads. EKS is an application target, never a substitute Authority. Linux and pinned container/kind tooling are the supported host baseline.

The host bootstrap interpreter owns only the exact kind cluster, host mounts, network/port configuration, retained bootstrap artifacts and local caller. It does not open a host-direct provider lane or a second writer beside the Authority.

## Dependency order

```text
validated context and host capacity
  -> exact retained mounts, kind nodes and enforcing network policy
  -> pinned locally loaded bootstrap images
  -> bootstrap MinIO access + Vault/Broker
  -> init once or recover/unseal the same Vault
  -> operational policies and steady-state MinIO access
  -> Authority journal + local backup + scoped caller
  -> required Provider/Provisioner/Agent capabilities
  -> application platform only when requested
```

Bootstrap cannot depend on the registry it creates, AWS credentials it has not provisioned, remote backup, DNS/TLS, SES, or gateway readiness. Retain the necessary images/manifests by digest and architecture and load them into new kind nodes. Failed acquisition is a specific capability result, not permission to fetch a mutable image or ignore identity.

The dependency graph has a separate narrow branch from established local kind identity, mounted journal and pinned Authority image to **fresh non-secret Authority reads**. That branch is available before Vault unlock; the linear sequence above describes secret-dependent execution readiness. It uses the same Authority and cannot submit provider effects. Do not recreate authentication-before-classification by requiring Vault Transit merely to read provider-admission history.

## Persistence and networking

kind nodes are disposable containers. Explicit absolute host `extraMounts` bind the selected `.data` or `.test-data` root into nodes. A node `hostPath` without this binding is not retained host storage. Observe mount source and generation before attaching Vault or journal volumes; do not initialize over a wrong or unlinked mount.

Keep the Kubernetes API loopback-bound. Host, node and Pod loopback addresses differ. Reserve unique host ports, Docker networks, cluster names, kubeconfigs and node-local registry mappings for concurrent environments. Later application publication uses MetalLB on the kind network and explicit host ingress into Envoy; it cannot reuse RKE2/LAN assumptions without proof.

Pin the CNI and validate real allowed/denied management traffic before handling secrets or elevated AWS input. A successful NetworkPolicy apply is not enforcement evidence. Role service accounts, RBAC and network paths grant only the declared bounded operations; an internal launcher still requires its caller/permit checks.

## Capacity and readiness

Fund steady management plus the permitted concurrent secret/provisioner workers before bootstrap. Apply resource requests/limits and reserves and prove actual scheduling/completion under that envelope. Do not defer management resource sufficiency until application deployment. [Resource governance](resource_governance.md)

Distinguish process liveness, traffic readiness, capability readiness and temporal stability. Liveness/ready endpoints use bounded local observations and do not perform cloud audits or create work. An available API Pod does not prove Vault login, object-store access, worker scheduling, provider permissions or secret delivery.

Status reports independently observable component facts even when Broker or Authority is down. Last-known metadata is explicitly stale. Mutations repair required management capabilities and obtain fresh authority before proceeding. [Security bootstrap](security_and_credentials.md#vault-bootstrap-and-unlock)

## Recovery and local removal

`control reconcile` repairs stopped/absent kind against preserved identity and mounts. Recreate only the capability closure needed by the requested operation. Restore the exact local journal/backup before new admission. Keep unknown/missing old history unresolved and enter explicit recovery.

`control delete --yes` is separate from cloud deletion. It refuses unresolved cloud obligations, preserves host roots and a usable local completion record. Early Phase 1 removal is restricted to new identities for which cloud admission is impossible; it cannot decide for a foreign/legacy identity. Full data purge is a separate operator-confirmed operation.

## Required evidence

Phase 1 proves real mounts, kind node recreation, context isolation, management policy enforcement and worker capacity. Phase 2 proves same-Vault recovery and secret-worker behavior. Phase 3 proves Authority admission/restart and obligation-aware local removal. EKS availability is not a prerequisite for any of these proofs. [Numerical phases](../../DEVELOPMENT_PLAN/README.md#resume-here)

## Implemented through Phase 1

`control reconcile` admits a test identity only after, in order, host capacity (the compiled controller envelope against the observed CPU affinity, memory and device), the absence of Docker resources already bearing the scope's cluster name, and free declared host ports; each refusal happens before any archive, image, network, volume or node effect. The confined kind controller runs as a transient unit in its own slice. The pinned management NetworkPolicy lives in `Prodbox.Control.ManagementPolicy` (digest pinned by a unit test) and enforcement is observed with real sockets under the shipped kindnet CNI, never inferred from a successful apply. Authority admission, Vault and the secret workers are Phase 2 and later. Evidence: [Phase 1 validation](../../DEVELOPMENT_PLAN/evidence/phase_01_validation.md).

## Implemented through Phase 2

`control services` deploys, from locally imported pinned artifacts and with every container's pull policy `Never`, a source-built MinIO, Vault and the MinIO client in the management namespace plus the Bootstrap Broker (Deployment, Service and RBAC in its own namespace, with a ServiceAccount for the Broker and another for its one-shot secret worker). Vault runs as its own ServiceAccount bound to `system:auth-delegator`, which is what lets its Kubernetes authentication validate the Broker's tokens. `control status` reads each component directly and names an unobservable one as such. The Broker mutations the public surface drives are `control broker-init`, `broker-unseal` and `broker-baseline`; the post-unseal handoff needs the control-plane Authority and is a Phase 3 consumer.
