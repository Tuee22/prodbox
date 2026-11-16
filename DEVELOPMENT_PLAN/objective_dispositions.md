# Product Objective Dispositions

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Adopted product scope and historical-work conversion; implementation is tracked by numerical phases.

> **Purpose**: Preserve actual project objectives while replacing convoluted lifecycle mechanisms and assigning every retained outcome a numerical owner.

[Resume Here](README.md#resume-here) is the queue. These rows define ownership, not completion. The [command manifest](command_dispositions.md) covers all 138 current leaves and 65 option names. The [legacy ledger](legacy_tracking_for_deletion.md) covers all 81 former pending rows. Requirements not represented by a command still need an owner here.

## Retained outcomes

| ID | Accepted outcome | Owning phase | Canonical contract | Required evidence |
|---|---|---:|---|---|
| O00 | Doctrine ownership, one numerical queue, complete feature/command/removal coverage | 0 | [Plan standards](development_plan_standards.md) | A00 checker acceptance and adverse fixtures; no implementation by prose |
| O01 | Typed, introspectable public/maintenance/internal command registry; parser/help/docs/completions agree | 1 | [CLI](../documents/engineering/cli_command_surface.md) | Installed command/parser behavior; baseline mapping checked |
| O02 | Explicit Dhall context, minimal bootstrap config, separate authored production/test plans and no production-config rewriting | 1 | [Configuration](../documents/engineering/configuration.md) | Real context/config and isolation rejection cases |
| O03 | Linux/container-runtime/kind control bootstrap and host-backed persistent roots | 1 | [Control plane](../documents/engineering/control_plane.md) | Actual node loss/recreation and independent host/Pod read-back |
| O04 | Disjoint production/test names, mounts, endpoints, identities, credentials and ownership scopes | 1 | [Storage](../documents/engineering/storage.md) | Cross-environment mutation attempts rejected; unrelated markers survive |
| O05 | Pinned recovery artifacts independent of the in-cluster registry | 1 | [Control plane](../documents/engineering/control_plane.md) | Actual image loading; later real management recovery without registry |
| O06 | Real management network isolation and funded steady/worker resource envelopes | 1 | [Resource governance](../documents/engineering/resource_governance.md) | Actual allowed/denied sockets, scheduling, limits, capacity refusal |
| O07 | Actual Vault/MinIO/Broker init, seal/unseal, baseline, same-data recovery and bounded secret workers | 2 | [Security](../documents/engineering/security_and_credentials.md) | A02 real secret round-trip, worker settlement and crash cases |
| O08 | Protected production unlock and explicitly weaker test-only MinIO self-unseal | 2 | [Security](../documents/engineering/security_and_credentials.md) | Production rejects test policy; real test restart self-unseals same Vault |
| O09 | Accurate read-only status while Broker/Vault/registry unavailable | 3 | [Lifecycle](../documents/engineering/lifecycle.md) | Source/age/unknown observations; no privileged login needed for basic facts |
| O10 | Retained Authority, durable operations, explicit admission history and local backup/recovery | 3 | [Lifecycle](../documents/engineering/lifecycle.md) | Actual journal persistence, concurrency, crash/resume, missing-history refusal |
| O11 | Single observe/plan/execute/read-back engine, NoChange semantics, operation inspect/resume/cancel | 3 | [Lifecycle](../documents/engineering/lifecycle.md) | Actual public workflows; unresolved intent cannot become NoChange |
| O12 | Separate cloud deletion, local control removal, and operator-only local data purge | 3 | [Storage](../documents/engineering/storage.md) | Never-admitted control removal passes; unknown/cloud obligations block it |
| O13 | Advanced Vault rotation, PKI and audited ambiguous-init recovery | 3 | [Security](../documents/engineering/security_and_credentials.md) | A03-06 real key/cert/state observations and safe stale-input rejection |
| O14 | Same ephemeral elevated operator/test credential ingress; generated scoped credentials in Vault | 4 | [Security](../documents/engineering/security_and_credentials.md) | Real IAM/STS/Vault creation/use/retirement; descriptor-safe test fixture loading |
| O15 | Write-ahead IAM admission, least privilege, resource-before-credential cleanup and independent final verifier | 4 | [AWS resources](../documents/engineering/aws_resources.md) | Interrupted bootstrap/resume and exact IAM/Vault absence |
| O16 | First inexpensive real AWS family completely creates, recovers and deletes through shared engine | 5 | [AWS resources](../documents/engineering/aws_resources.md) | Real canary cycles, lost reply, checkpoint loss and planted residue |
| O17 | AWS policy/quota inspection/request and closed digest-bound repair, without generic admin passthrough | 5 | [AWS resources](../documents/engineering/aws_resources.md) | A05-05 actual provider read-back; permission and stale-plan refusal |
| O18 | Canonical local gateway, Keycloak/PostgreSQL, VS Code, API, Redis and websocket services | 6 | [Platform](../documents/engineering/platform_and_services.md) | Actual protocol/auth/data requests and service recovery |
| O19 | MinIO, registry:2, Percona operator, MetalLB, Envoy Gateway and cert-manager support | 6 | [Platform](../documents/engineering/platform_and_services.md) | Actual dependency readiness and protected management scope |
| O20 | Same workload image refs through working local/EKS mirrors and publication; no cached-image false proof | 6 | [Platform](../documents/engineering/platform_and_services.md) | Uncached local pull and restart; AWS projection extends in Phase 8 |
| O21 | Static retained local application volumes and real database/operator persistence | 6 | [Storage](../documents/engineering/storage.md) | SQL/object/application data after Pod/node replacement; local data outside cloud delete |
| O22 | Explicit host/LAN ingress and network-policy enforcement for the application projection | 6 | [Control plane](../documents/engineering/control_plane.md) | Actual host/LAN routes and allow/deny traffic |
| O23 | Gateway runtime and Pulsar broker/client/topic lifecycle with bounded messaging/state | 6 | [Gateway/messaging](../documents/engineering/gateway_and_messaging.md) | Real broker/protocol requests, ordering/idempotency and persistence cases |
| O24 | Whole local service capacity, transient workers, overload/backpressure and service diagnostics | 6 | [Resource governance](../documents/engineering/resource_governance.md) | Measured bounded load and limits; green probes alone insufficient |
| O25 | Real public Route 53 + ZeroSSL DNS01 TLS, explicit hostname/SAN scope and retention/restore | 7 | [Public edge](../documents/engineering/public_edge.md) | Independent public DNS, TLS issuer/hostname and failure/restore cases |
| O26 | Real SES sending/receiving, separate test identity/SMTP/capture/DNS/owned rules and no production receiving disruption | 7 | [AWS resources](../documents/engineering/aws_resources.md) | A07-02 concurrent owned scopes; active regional rule-set container coordinated explicitly |
| O27 | Keycloak invitation/list/revoke, email verification, login/JWT/API/websocket authorization | 7 | [Public edge](../documents/engineering/public_edge.md) | Real email/receipt/auth/negative access cases |
| O28 | Owned DNS validation zones/challenges and parent-zone record/delegation cleanup | 7 | [AWS resources](../documents/engineering/aws_resources.md) | Exact records absent; external parent/domain retained |
| O29 | Optional remote Authority backup and TLS/S3 storage with no bootstrap dependency | 7 | [Storage](../documents/engineering/storage.md) | Real backup/restore and object-version/bucket/IAM deletion before credentials retire |
| O30 | EKS/VPC/node groups/EC2/IAM/subzone target under retained local kind Authority | 8 | [AWS resources](../documents/engineering/aws_resources.md) | Real cluster and independent scope observations, no host-direct fallback |
| O31 | EKS platform/application equivalence including registry/MinIO/Percona and real edge/auth behavior | 8 | [Platform](../documents/engineering/platform_and_services.md) | Actual AWS service projection and image delivery |
| O32 | Static EBS attachment/rebind, explicit production data destruction under confirmed cloud delete | 8 | [Storage](../documents/engineering/storage.md) | Real volume/data observations and exact absence; no old LongLived exemption |
| O33 | Exact EKS drain, LBC/CNI/network-dependent families and convergent retry cleanup | 8 | [AWS resources](../documents/engineering/aws_resources.md) | Lost replies, late dependents, denied drain and real final inventory |
| O34 | Complete default AWS deletion covers SES, EBS, DNS, backing S3 and IAM without uninstalling kind | 8 | [Lifecycle](../documents/engineering/lifecycle.md) | Repeated real create/delete/no-op; retained control health and credential retirement |
| O35 | Target-local cert-manager identity and narrow EKS DNS01 trust | 8 | [Security](../documents/engineering/security_and_credentials.md) | Actual scoped credential/session actions; cannot access unrelated parent/prod identity |
| O36 | Gateway HA/leader/emitter continuity and real supported failure domains | 9 | [Gateway/messaging](../documents/engineering/gateway_and_messaging.md) | Actual kind/EKS faults, bounded load and correct replay/ownership |
| O37 | Explicit federation child trust, protected custody, registration/status and recovery | 9 | [Federation](../documents/engineering/federation.md) | Real child target and unavailable/replay/stale identity cases |
| O38 | Worker settlement, concurrent-operation recovery and physically bounded subprocess lifecycle | 9 | [Lifecycle](../documents/engineering/lifecycle.md) | Actual cancellation/restart/held request faults; expiry alone cannot prove settlement |
| O39 | Existing-layout import, single-writer migration, rollback boundaries and full regression | 10 | [Migration guide](../documents/operator/migration.md) | Actual disposable old fixture, same identity/custody, independent new writer and cleanup |
| O40 | Targeted source mutations with meaningful assertion kills and safe execution | 1 | [Mutation catalog](mutation_cases.md) | Phase 0 manual checker mutants; runner calibration in Phase 1; each later phase owns its own catalog rows |
| O41 | Source/build/config-bound, secret-free, available evidence and one real scenario runner | 1 | [Testing](../documents/engineering/testing.md) | Real validator negative controls; per-phase results stay open until executed |
| O42 | Haskell-only typed effects/errors, bounded subprocesses, structured concurrency and consistent messaging codecs | 1 | [Haskell guide](../documents/engineering/haskell_code_guide.md) | Build/pure/protocol tests plus real runtime tests in consuming phases; no invented second implementation |
| O43 | Canonical dev check, manual tooling, source pinning and useful formal-model correspondence | 0 | [Quality](../documents/engineering/code_quality.md) | Actual adopted checker negatives; toolchain/build proof extends in Phase 1, model/runtime claims in Phase 9 |
| O44 | Actual fixed local replica selection and resource-fit admission; retain typed fixed/bounded policy validation | 6 | [Resource governance](../documents/engineering/resource_governance.md) | A06-07 real replica reconcile/read-back and invalid local elastic/over-budget rejection |
| O45 | AWS bounded replica/node policy, Spot price/quota eligibility planning and explicit count reconciliation | 8 | [Resource governance](../documents/engineering/resource_governance.md) | A08-06 real provider price/quota/count observations; no claim of an unwired autonomous autoscaler |

An owning phase establishes an outcome's initial declared scope. Explicit extensions such as EKS service parity or later HA fault domains are separately owned rows above. An earlier phase cannot claim an unimplemented extension, and an extension cannot reverse earlier root, deletion, credential or evidence semantics.

## Historical open work converted

These are disposition records, not an old execution queue. All original text remains inspectable at baseline `583443f` as described in [history navigation](../documents/history/README.md).

| Historical open item | Disposition into accepted work | New owners | Evidence treatment |
|---|---|---|---|
| 2.147: Broker time/fence/worker settlement | Preserve concrete expiry, delayed-effect and owner-overlap failures; establish bounded bootstrap ownership without inventing trusted clock precision | O07/Phase 2; O15/Phase 4; O38/Phase 9 for actual extended fault domains | Frozen controls are regression seeds; no unbounded clock-source research is a hidden prerequisite |
| 4.114: Target worker/session release before retirement | Retain exact workload identity and prove actual settlement before lane/credential reuse | O15/Phase 4 shared local worker; O35/Phase 8 target adapter; O38/Phase 9 extended faults | Old codec/ambiguous sessions remain migration-owned until resolved, never silently freshened |
| 6.5: public cleanup cutover and old Authority import | Split normal local engine, AWS adapter activation and original-install migration instead of one indefinite private candidate | O11/Phase 3; O34/Phase 8; O39/Phase 10 | Every new public slice closes in its owner; existing-layout cleanup stays narrowly fenced |
| 6.7: scoped AWS lifecycle qualification | Real cheap-family proof first, then complete EKS family proof and final regression | O16/Phase 5; O34/Phase 8; O39/Phase 10 regression only | Old receipts qualify only their original source/config scope |
| 7.47: material not delivered to EKS Vault | Implement actual scoped EKS secret/identity delivery through the retained role boundary | O35/Phase 8 | Constructor/projection tests alone are insufficient |
| 81 pending removals, including 16 formerly unowned entries | Individually numbered B001–B081 and mapped to numerical removers | [Legacy ledger](legacy_tracking_for_deletion.md) | No row becomes Removed because its old sprint said Done |

## Deliberately replaced or excluded choices

| Historical choice | Decision | Owner / replacement |
|---|---|---|
| RKE2 mandatory local control | Replace with retained kind; preserve exact original-install recovery until migration resolves it | Phase 1 new install; Phase 10 old-layout retirement |
| HA RKE2-specific AWS provisioning suite | Remove that infrastructure choice; preserve gateway HA objectives on supported kind/EKS | Phase 9 / O36 |
| Host-managed lifecycle service proposal | Do not adopt; user retained kind and the same management roles | Phase 0 / product architecture |
| AWS state/SES/production-EBS exemptions from ordinary delete | Remove exemptions for this deployment's owned scope | Phase 7 SES/backups; Phase 8 complete cloud deletion |
| Whole-system sealed metadata concealment | Replace with useful authenticated non-secret lifecycle metadata; retain secret payload protection | Phase 3 / O09–O11 |
| Mandatory remote AWS backup before credential bootstrap | Remove circular prerequisite; local recovery first, optional remote adapter later | Phase 3 local; Phase 7 remote |
| Multiple test runners/config rewriting/host-direct fallback | Replace with explicit contexts and one shared real engine | Phases 1–8 by owning capability |
| Independent code-Done/live-pending phase closure | Replace with real phase acceptance and owned-removal completion | Phase 0 |
| Existing fixed/elastic/Spot/autoscaler planning foundations | Retain useful typed bounds/capacity/price/quota and trust/leader checks through the common explicit reconciler; no currently unwired background autoscaler is claimed as a live feature | O44/Phase 6; O45/Phase 8; L21/Phase 9 integrates or retires remaining unwired helpers |
| Generic always-on mutation score/framework | Do not add; use the scoped semantic catalog | Phase 1 / O40 |
| Unvalidated macOS/Windows/Lima/WSL/Incus support | No supported claim in this refactor; preserve reusable boundaries and explicitly separate future feature proposals | Phase 0 scope decision, not a hidden prerequisite |
| Speculative ML/JIT/cache/autoscaling type requirements not used by this product | Remove from mandatory runtime doctrine; actual workload/disk/concurrency budget requirements remain | Phase 0 doctrine; O24 actual resource governance |
| Account-wide destructive sweep as normal recovery | Remove; exact deployment adoption/cleanup and external ownership boundaries remain | Phase 8 normal routes; Phase 10 legacy import |

No feature may disappear merely because it is absent from a short CLI example. A newly discovered implemented objective gets a row and numerical owner before its source or documentation is removed.
