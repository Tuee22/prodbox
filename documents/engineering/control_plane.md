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

## Current Phase 1 implementation

`control reconcile` checks host capacity, conflicting Docker resources and
declared host ports before admitting fresh work. It records an owner-first
`family-v2` intent and submits a managed family. The worker prepares the
image, network and volume before creating the node. The public completion
observer requires the bound worker result, exact family retirement, the
recorded management network probe and independent Kubernetes readiness
against the owned node and CA. The pinned NetworkPolicy lives in
`Prodbox.Control.ManagementPolicy`. Each connection phase waits for both
exact client Pods to complete before reading their result logs. A missing
or failed observation leaves enforcement unconfirmed.

Phase 1 `control delete --yes` applies to new test identities. For a sent
operation, it requires exact family settlement and input retirement before
removing recorded resources. A pre-publication intent can be cancelled
under the operation lease, fencing later publication. A published family
can also prove it was never sent. After a durable publication attempt,
missing records leave settlement unconfirmed. A missing `family-v1` launch
remains unresolved. `control status` reports these checkpoints and the
independent resource observations.

Before early owner-family removal, `control delete --yes` records the fresh
local `NeverAdmitted` decision for the exact scope and operation. The
Authority deployer shares the scope lease and refuses while that fence is
present or unobservable. Resuming after API loss requires the original
checkpoint, the matching owner operation and independent observation that
both the retained Authority journal and the legacy local journal root are
absent. A checkpoint establishes admission for that operation. Resource
removal requires its own settlement and read-back. After an owned node
removal, delete combines the recorded positive pre-removal observation and
the bound receipt with independent node inventories and an exact Docker
not-found response. Volume and network removal likewise require exact
resource observations before proceeding or reporting completion.

An uncertain probe cleanup can require a separately identified managed
verifier. Its request and publication bind the original cleanup, namespace
UID and execution window. A successor retains the predecessor chain and
holds its exact retirement observations throughout the namespace read-back.
The verifier checks the owned node and API CA and brackets the selected
namespace inventory with Kubernetes positive controls. Before using that
read-back for node removal, delete independently checks the verifier's
retirement and published-input retirement. An interrupted cleanup with no
recorded cleanup submission still requires isolated cleanup launch support.

The [Phase 1 implementation and evidence](../../DEVELOPMENT_PLAN/phase_01_cli_contexts_kind_and_evidence.md)
record which paths have been exercised and which acceptance and cleanup
obligations remain open.

## Implemented through Phase 2

`control services` deploys, from locally imported pinned artifacts and with every container's pull policy `Never`, a source-built MinIO, Vault and the MinIO client in the management namespace plus the Bootstrap Broker (Deployment, Service and RBAC in its own namespace, with a ServiceAccount for the Broker and another for its one-shot secret worker). Vault runs as its own ServiceAccount bound to `system:auth-delegator`, which is what lets its Kubernetes authentication validate the Broker's tokens. `control status` reads each component directly and names an unobservable one as such. The Broker mutations the public surface drives are `control broker-init`, `broker-unseal` and `broker-baseline`; the post-unseal handoff needs the control-plane Authority and is a Phase 3 consumer.
