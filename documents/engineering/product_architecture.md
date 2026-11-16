# Product Architecture

**Status**: Authoritative source
**Supersedes**: Architectural duplication in the pre-refactor doctrine suite
**Generated sections**: none
**Applicability**: Adopted target contract; runtime migration is not yet implemented

> **Purpose**: Define the retained kind management plane, application targets, product scope, and ownership boundaries.

## Product shape

Prodbox is a Haskell CLI and a retained local Kubernetes management plane. The management plane runs in kind. It manages a local application projection and an optional AWS/EKS application projection. Selecting EKS never moves lifecycle authority to EKS or creates a host-direct AWS fallback.

The existing binary still contains the RKE2-era command topology. Use its actual help for current operations. Target commands below become available through the numerical [development plan](../../DEVELOPMENT_PLAN/README.md#resume-here); publishing this doctrine does not implement them.

## Components and authority

| Boundary | Responsibility |
|---|---|
| CLI / test harness | Select an explicit context; submit the same desired-state operations; render outcomes |
| Host bootstrap adapter | Create/restore kind, bind exact host roots, load pinned bootstrap images, establish the local caller |
| Bootstrap Broker and bounded secret workers | Initialize once, unlock, observe and maintain the selected Vault bootstrap policy |
| Vault | Operational secrets, Transit encryption, PKI and role-specific authentication |
| MinIO | Retained object storage, encrypted checkpoints and the explicitly scoped test unlock object |
| Lifecycle Authority | Sole journal/admission owner for a deployment; durable intent, progress, resource scope and terminal reports |
| Credential Provisioner / bounded admin worker | Use ephemeral elevated input for registered IAM creation/retirement |
| Provider Worker | Execute exact provider operations using scoped operational credentials |
| Authority Backup, TLS Retention and Target Secret Agent | Bounded backup/ciphertext transport and exact secret-generation delivery; no generic secret-export API |
| Gateway | Mesh, election, semantic state and registered DNS intent; no lifecycle/credential/bootstrap authority |

Keep these role boundaries and the application services. Simplify their shared implementation and coordination instead of replacing them with a privileged host daemon or adding a second lifecycle owner. Roles are internal deployment details, not operator setup steps.

## Application and platform projection

Both targets support gateway, Keycloak, PostgreSQL through the Percona operator, VS Code, API, Redis and websocket, with MinIO, registry:2, Envoy Gateway, cert-manager and real ZeroSSL. Preserve Pulsar broker/native-client/topic behavior and gateway messaging. Management and application instances have distinct namespaces, desired-state ownership and storage where their lifetimes differ.

Local kind uses MetalLB on the kind network plus explicit host ingress publication. EKS uses AWS Load Balancer Controller and statically provisioned EBS. Workload image semantics, protocol behavior and application readiness stay shared. Actual differences are declared target adapters, not scattered substrate conditionals. [Platform contract](platform_and_services.md)

## Ownership and deletion

A deployment owns every resource it created or explicitly adopted. Top-level `delete --yes` reconciles all of its AWS resources absent, including SES, EBS, DNS records/subzones, state/backup buckets and generated IAM. A former `LongLived` label never grants an exemption. Kind, management trust/journal and local application data remain retained. [Lifecycle contract](lifecycle.md#deletion-order-and-completion)

Removing kind and destroying host data are separate operations with stronger preconditions. Ordinary cloud delete cannot remove the engine or evidence it needs to finish. External account/domain/parent-zone/bootstrap input and unrelated resources remain outside deployment ownership.

## Environment isolation and secrets

Production lives beneath `.data/<installation-id>/`; tests beneath `.test-data/<run-id>/`. Identity isolation also covers clusters, mounts, endpoints, credentials, names and AWS scope. Test SES identities, DNS records, SMTP identities and capture buckets are separate from production. [Storage](storage.md) and [security](security_and_credentials.md) define the exact contracts.

The test fixture `test-secrets.dhall` simulates an operator's ephemeral elevated input through the same Provisioner. Test-only MinIO self-unseal is allowed before Vault; production cannot enable it. Non-secret lifecycle identity and admission history remain inspectable while Vault is sealed. Secret custody stays protected.

## Delivery and scope

The supported host baseline is Linux with pinned container tooling. RKE2 is removed from new control-plane enrollment and the old AWS HA provisioner; gateway HA objectives remain on kind/EKS. Portable-host aspirations and speculative ML/autoscaling prose are not hidden dependencies of this product. Every historical objective has an explicit [disposition](../../DEVELOPMENT_PLAN/objective_dispositions.md).

Each phase exposes a completed public slice and validates its real predecessors. The final phase repeats existing proofs and resolves old installations; it is not a deferred first cutover. Current work state lives only in [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here).
