# System Component Catalog

**Status**: Authoritative source
**Supersedes**: Pre-refactor component/status inventory
**Generated sections**: none
**Applicability**: Accepted target; each component's actual proof belongs to its numerical phase.

> **Purpose**: Preserve the complete service set and clarify placement, ownership and state without a second implementation-status ledger.

[Product architecture](../documents/engineering/product_architecture.md) owns the boundaries. [Resume Here](README.md#resume-here) owns state. Reuse correct existing Haskell modules; proposed boundaries are not evidence of an installed implementation.

## Management plane retained on local kind

| Component | Sole responsibility and capability boundary | State / first owning phase |
|---|---|---|
| Haskell CLI and typed registry | Explicit public/maintenance/internal requests, config/context selection, truthful outputs; no provider fallback | Authored Dhall and local caller / 1 |
| Host kind bootstrap adapter | Exact cluster/mount/network/artifact preparation and repair; no cloud resource mutation | Non-secret bootstrap identity and host root generation / 1 |
| Pinned artifact inventory | Recover management without the registry, cloud, DNS or application platform | `.data` or run-owned artifact root / 1 |
| Resource/network isolation | Fund management plus concurrent workers and prove actual allow/deny traffic | Explicit quotas/envelopes/CNI and measured checks / 1 |
| MinIO | Durable scoped object/checkpoint/unlock storage with explicit bootstrap access | Host-backed MinIO volume; test unlock object in exact run / 2 |
| Vault | Operational secrets, Transit/encryption/PKI; same-data unlock, not implicit reinitialization | Host-backed Vault root / 2; advanced operations 3 |
| Bootstrap Broker and bounded secret workers | Closed init/unseal/baseline/status/rotation capabilities, authenticated scoped custody | Retained init/unlock journal and worker identities / 2 |
| Lifecycle Authority | One operation/admission/resource journal and desired-state planner/executor ownership | Durable management journal and non-secret diagnostic projection / 3 |
| Authority Backup Adapter | Exact local backup/restore; optional remote backup is a declared deletable adapter | Local recovery 3; remote owned S3/IAM 7 |
| Provider Worker | Only the admitted ordinary AWS effects under exact deployment/account/region scope | IAM/session material in authorized memory/Vault; first cloud family 5 |
| Credential Provisioner | Ephemeral elevated input creates/recovers/retires generated scoped identities after durable intent | No runtime elevated persistence; operational generations in Vault / 4 |
| Admin Action / external-material workers | Closed exceptional action and secret ingress; no arbitrary elevated passthrough | Permit-bound operation and independently settled workload / 4–7 |
| TLS Retention Adapter | Exact certificate custody/storage/restore with encrypted remote payload and owned lifecycle | Local custody and declared remote objects / 7 |
| Target Secret Agent | Only allowlisted selected-target secret delivery/retirement; no cloud authority | Scoped target generation and same-operation receipt / local 4–7, EKS 8 |
| Scenario/evidence/mutation runner | Shared product handlers, owned fixtures, independent read-back and safe mutant isolation | Non-secret result/availability records / 1; real capability cases extend by phase |

The ordinary AWS delete leaves this management projection available. Placement is outside application substrate equivalence; no management Authority moves to EKS. Internal launchers remain authenticated and hidden from ordinary operator help.

## Canonical application/platform projection

| Service/platform piece | Local target | AWS target | First real owner |
|---|---|---|---:|
| Gateway mesh and DNS client | Application namespace on kind; no bootstrap/provider/secret ownership | Application namespace on EKS, same bounded protocol/runtime | 6; HA 9 |
| Keycloak | Real identity/authorization service | Same service and auth behavior | 6; public user journeys 7 |
| Keycloak/application PostgreSQL | Percona PostgreSQL operator and real database persistence | Same operator/database projection over static EBS | 6; EKS 8 |
| VS Code | Canonical chart and authenticated route | Same workload/image refs | 6 |
| API | Canonical Haskell workload and authorization | Same workload/protocol | 6 |
| Redis | Shared realtime state with declared persistence/demand | Same service | 6 |
| Websocket | Canonical Haskell workload and auth/state protocol | Same service | 6 |
| Pulsar broker/client/topics | Real broker and bounded native client/topic lifecycle | Same service semantics | 6 |
| MinIO and registry:2 | Application/platform object/image service; management ownership stays separate | MinIO-backed registry and node mirror, no missing-registry exception | 6 |
| MetalLB / AWS Load Balancer Controller | MetalLB on the kind network plus explicit host ingress | AWS controller with registered network dependents | 6 / 8 |
| Envoy Gateway | Gateway API routing, browser/JWT integration | Same route catalog and security behavior | 6; real public edge 7 |
| cert-manager + ZeroSSL DNS01 | Same cert manager; real external issuance after domain/credential admission | Same issuer/hostname contract using target-local DNS01 identity | 7 / 8 |
| SES and receipt capture | Cloud support for real invite/email journeys, owned by selected deployment | Same protocol with distinct production/test identities | 7 |

A same-named component may need distinct management/application instances, volumes or namespaces because its lifecycle owner differs. The catalog determines that boundary; it cannot be inferred after cleanup starts. Keep one application projection and target adapters rather than different image literals or omitted services.

## Engineering and proof surfaces

- Haskell-only executable/library, pinned GHC/Cabal/dependencies, typed configs/effects/errors, bounded subprocesses and structured concurrency.
- Current source registry remains the generator for installed parser/help/manpages/completions; [command dispositions](command_dispositions.md) owns the complete migration map.
- Real public-command acceptance and critical mutations in [acceptance](acceptance_cases.md) / [mutation](mutation_cases.md) catalogs; current evidence never comes from prose alone.
- Useful property/TLA models retain explicit assumptions and actual runtime correspondence. Models tied to removed topology receive a retirement owner instead of an automatic proof claim.
- Capacity bounds cover real management/workers before secrets and real application traffic/load before service claims.
- [Legacy ledger](legacy_tracking_for_deletion.md) owns all superseded active code, compatibility stubs, old identities and necessary historical evidence.
