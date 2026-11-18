# Prodbox CLI and Lifecycle Refactor Plan

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Historical design proposal, adopted and superseded by the current engineering contracts and numerical plan.

> **Purpose**: Propose a simpler CLI, retained kind control plane, production/test isolation, and a doctrine-first development plan whose numerical phases each close with real validation and owned legacy removal.

This frozen proposal records the design reviewed before Markdown-only adoption. It is not current doctrine or an execution queue. Read [current navigation](../../REFACTOR_PLAN.md) and [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here). Canonical inventories now use Markdown rather than the originally proposed YAML; Phase 0 remains open for the unchanged code/checker migration.

## 1. Product decisions to adopt

1. Keep the project Haskell-only. Keep Kubernetes, Vault, MinIO, the existing control-plane roles, and the canonical application microservices. This proposal does not move lifecycle authority to a host daemon.
2. Use **local kind as the retained prodbox control plane**. An optional AWS application target uses EKS. The local application target can run alongside management services in kind, in separate namespaces and storage scopes.
3. Make `prodbox delete --yes` the single ordinary deletion command. It removes **all prodbox-created AWS resources owned by the selected deployment**, including formerly long-lived SES, application EBS, managed DNS/subzones, backing buckets, and generated IAM identities. It updates the retained control-plane state and leaves kind, Vault, MinIO, and management services available.
4. Remove `--cascade`. Separate cloud application deletion, local control-cluster removal, and local data destruction. No ordinary cloud deletion command uninstalls its own management plane.
5. Preserve `.data/` for production and `.test-data/` for testing. Give them separate identities, clusters, mounts, configurations, credentials, endpoints, and cloud ownership. A different directory alone is insufficient isolation.
6. Preserve `test-secrets.dhall`. Its elevated credential simulates the same ephemeral input an operator supplies interactively. The test harness uses the real credential-provisioning implementation; it does not install pre-provisioned operational credentials or bypass admission.
7. Permit test-only Vault self-unseal using a secret held in the test MinIO bootstrap scope. Production retains protected unlock custody and prompts when needed. Never silently enable the test policy for production.
8. Record non-secret deployment identity, provider admission, and cleanup obligations independently of Vault secret availability. Explicitly relax the existing whole-system concealment of resource presence for authenticated lifecycle metadata.
9. Share one observe/plan/execute/read-back engine across the CLI, tests, scoped maintenance, and operation recovery. Keep one mutation owner for a deployment.
10. Deliver a usable public-command slice in every implementation phase. There is no final deferred activation of an otherwise private replacement.
11. Require each phase's real composition, adverse cases, targeted mutation tests, cleanup, and legacy removals before it is complete. Later phases may depend on earlier completed phases; earlier validation never depends on later implementation.
12. Treat existing code as reusable material and historical evidence as regression input. Neither old phase completion nor a large test count automatically validates the new topology.

### 1.1 Precise deletion scope

“App-provisioned AWS resources” means resources created or explicitly adopted under this deployment's ownership, including management-support resources that prodbox itself placed in AWS. Ordinary delete covers EKS and its VPC/dependents, test networks, delegated subzones/records, SES objects, S3 objects/versions/buckets created for this deployment, EC2/EBS, and generated IAM users/roles/policies/keys. Enumerate the complete set before implementation; this list is not a substitute for that inventory.

Externally owned AWS accounts, domains, parent hosted zones, operator bootstrap credentials, and unrelated resources remain external prerequisites. Do not claim an empty account. Managed records inside an external parent zone are owned resources and must be removed without removing the zone.

A resource cannot remain silently exempt because an old registry calls it `LongLived`. Lifetime and ownership are different facts. Resources intentionally shared by multiple deployments need a separately named owner and explicit consumer references; delete releases this deployment's reference and deletes the resource only when its owning scope is being deleted and no consumers remain. Do not invent a shared owner during deletion to avoid cleaning an existing deployment-owned resource.

Successful delete records the application target as absent and retires its obsolete checkpoints, operational credentials, and remote references only after their dependants are resolved. Retain deployment identity, management trust, the operation journal, and a bounded terminal report. Local application services and production data are outside this command's cloud deletion scope; identify them explicitly in the result.

Deletion of production AWS data volumes and buckets is a real destructive change. Print the plan and require `--yes` or interactive confirmation. Do not add a new cascade/purge-all flag to recover the old ambiguity.

## 2. Findings that determine this design

- The public cascade is still explicitly a legacy executor in `src/Prodbox/CLI/Rke2.hs`; the replacement is qualification-only in `src/Prodbox/Lifecycle/Teardown/CascadeCandidate/Internal.hs`.
- The August 16 change `5b8c730` introduced the current unknown-state refusal. It repaired unsafe inference but did not deliver automatic recovery or a positive never-provisioned path to the public command.
- `queryPerRunResidueStatuses` authenticates before reaching its explicit Vault gate. `vault status` goes through Broker readiness. Basic diagnosis therefore inherits dependencies of privileged execution.
- The existing doctrine already describes recovery before teardown. Repeating that target contract without changing the public implementation and closure criteria will repeat the development cycle.
- The zero-child-information policy deliberately conceals presence while sealed. That policy conflicts with useful pre-unseal lifecycle status; this proposal changes the policy for non-secret management metadata.
- The old standards permit component closure with composition/live proof pending. The new phases close at their declared operator journey, not at private adapters or classifier tests.
- The generated command registry currently contains 138 leaves under 25 roots, mixing operator actions, internal process launchers, diagnostics, and test entrypoints. Capture this baseline in Phase 0 and account for every leaf and meaningful option.

These findings are design inputs, not instructions to discard correct authentication, ownership checks, cancellation handling, or independent resource read-back.

## 3. Target architecture and responsibility boundaries

```text
operator CLI / test harness
       |
       +-- bootstrap adapter: kind, exact host mounts, pinned images, local caller
       |
       +-- retained local kind management plane
               Bootstrap Broker + bounded secret workers
               Vault + MinIO
               Lifecycle Authority + durable journal
               Provider Worker + Credential Provisioner
               Authority Backup / TLS Retention / Target Secret Agent
                       |
                       +-- local application namespaces
                       +-- optional AWS application target: EKS + supporting AWS
```

Keep role isolation where it protects distinct capabilities. Simplify coordination and shared libraries rather than replacing all microservices with one privileged daemon. Internal role names are deployment details, not required operator steps.

### 3.1 Bootstrap and recovery

The host adapter may create/recover kind, mount the selected root, load pinned bootstrap images, install the minimal management manifests, and establish the local caller. It is not an alternate Authority or a host-direct AWS mutation fallback.

The minimal management path must boot and recover without the in-cluster registry, public edge, application charts, SES, an AWS backup bucket, or operational AWS credentials. Preload the exact Vault, MinIO, Broker, Authority, and necessary worker images from a retained artifact inventory. Reconcile only dependencies needed by the requested operation.

Persist management state on host-backed mounts outside disposable kind node filesystems. Restarting or recreating kind reattaches those same paths; it does not initialize a new Vault or Authority over an old deployment. A mismatched storage generation is a specific recovery condition.

Keep local authority backup and recovery functional before any AWS support is introduced. Optional remote backups are later resource adapters, not a prerequisite for creating the first credential needed to reach AWS. Define which failures local backups cover; a second file on the same disk is not a disk-loss backup.

### 3.2 One authority and one operation model

Use a durable operation journal owned by the retained Authority. Keep a small bootstrap identity manifest and an Authority-produced, non-secret diagnostic projection readable to the local authenticated operator. Do not create a host writer that competes with the Authority's cloud admission records.

The journal must be usable without Vault decrypting secret payloads. It records environment/deployment identity, target scope, admission history, resource families, outstanding operations, observation provenance, and completion. Credentials and sensitive checkpoint payloads remain Vault-protected.

A diagnostic projection may be stale: label its age and source. It cannot authorize mutation or prove present absence merely because its last line says clean. If the Authority is down, a mutating command first repairs the minimal management plane and obtains authoritative state; a newly established deployment may use its explicit pre-provider bootstrap record.

Use independent external observations rather than an indexed global world state. Model program-owned operation progress with a small ADT, for example `Requested`, `Running`, `WaitingForInput`, `RecoveryRequired`, `Completed`, and `Failed`. Cancellation is a request followed by settlement/cleanup, not immediate proof that provider effects stopped.

The pure planner consumes typed observations and the owned resource catalog. Interpreters perform bounded effects. Every mutation has a corresponding independent read-back and recovery rule, including applied-but-response-lost and partial creation. Resource absence, checkpoint availability, credentials, and audit scope are separate facts.

### 3.3 Smaller implementation structure

Refactor toward these ownership boundaries; names are proposed module destinations, not a demand to rename everything first:

| Boundary | Responsibility |
|---|---|
| `Prodbox.CLI.{Command,Spec,Parser}` | Typed requests, visibility, arguments, help and generated references |
| `Prodbox.CLI.Dispatch` | Thin mapping into application handlers; no lifecycle orchestration |
| `Prodbox.Context` | Validated deployment, environment, root, endpoints, account/region selections |
| `Prodbox.Control.Kind` | kind lifecycle, mounts, networking, pinned bootstrap artifacts |
| `Prodbox.Bootstrap` | Actual Vault/MinIO/Broker capability acquisition and unlock policy |
| `Prodbox.Lifecycle.{Model,Plan,Journal,Execute,Observe}` | Shared operation core and recovery |
| `Prodbox.Resources.*` | Resource-family declarations and provider/Kubernetes interpreters |
| `Prodbox.Credentials` | Shared prompt/test ingress, credential creation, use, retirement |
| `Prodbox.Services` | Canonical platform/application catalog and target projection |
| `Prodbox.Test` | Scenario selection, isolated contexts, fault controls, independent observers |

Extract from `CLI/Rke2.hs`, `TestValidation.hs`, and current lifecycle modules incrementally. Do not write a second general framework beside the first. Reuse correct provider adapters, types and tests; remove each predecessor when its owning slice switches over.

## 4. Storage, configuration, credentials, and unseal

### 4.1 Explicit environment-owned roots

```text
.data/<installation-id>/
  identity/          # non-secret identity, root/mount generation, bootstrap policy
  control/           # Authority journal, retained management volumes and backups
  vault/             # Vault storage
  minio/             # MinIO storage, scoped checkpoint and unlock objects
  applications/      # local application persistent volumes
  artifacts/         # pinned recovery images and manifests
  reports/           # secret-free operation/evidence summaries

.test-data/<run-id>/
  config/            # generated test-only prodbox.dhall and public run context
  control/ vault/ minio/ applications/ artifacts/ reports/
```

These are proposed logical directories, not a renaming instruction for existing live mounts. Phase 0 defines the migration manifest; Phase 1 implements identity and safe path handling. No implementation may move or delete old roots as a side effect of loading configuration.

Production and test root identities are disjoint even when the operator runs both concurrently. Use unique kind names, kubeconfigs, ports, network allocations, MinIO namespaces, Vault identities, and AWS ownership tags. Bind every operation to environment plus deployment/run ID and account/region. Never use the current shell's kubeconfig or ambient AWS profile to choose a target.

For untaggable or externally constrained resources, use exact run-bound names/coordinates, including DNS records, SES identities, email capture prefixes and child zones. Validate configured test domains/addresses against the production ownership catalog. Encountering a preexisting name never silently adopts it; ownership collision refuses before mutation or requires an explicit scoped adoption plan.

Reject cross-environment mount aliases, symlink escapes, root overlap, and a test context pointing at production resources before effects. Test cleanup has authority only over its exact run. A failed test leaves its run recoverable; it does not erase evidence or borrow `.data/` to continue.

### 4.2 Configuration source model

Keep the existing Dhall toolchain, schemas, and binary-sibling production `prodbox.dhall` default. Add an explicit global `--config PATH` for public commands; tests pass their own run file rather than rewriting the production sibling. Resolve storage paths against an explicit project/context anchor, never incidental working directory.

Retain a separate authored `prodbox.test.dhall` plan and a separate `test-secrets.dhall` fixture. The run plan declares scenarios, budgets, external-input references, and topology. The fixture provides sensitive and operator-chosen test inputs. Generate each run config under its own test root through the same production config builder.

A small bootstrap configuration is sufficient to identify and diagnose the control plane. Do not require application FQDN, ACME, SES, or AWS configuration for local status, a never-admitted delete, or control bootstrap. Decode and validate additional projections only when the requested capability needs them.

Keep the selected Dhall file as the explicit authored deployment specification; the Authority records the accepted request/specification digest, applied generation, and observed state. Do not retain a second opaque in-force configuration authority with different values. An intentional subsequent reconcile may recreate an AWS deployment from its retained specification after delete; it must never mistake a retained specification for evidence that resources currently exist.

### 4.3 Ephemeral elevated AWS input

Production and test call the same credential workflow:

```text
interactive operator prompt | test-secrets prompt simulator
                 -> bounded Credential Provisioner
                 -> least-privilege prodbox identities
                 -> operational material written to Vault
                 -> registered Provider operations
                 -> resource cleanup / IAM retirement / Vault retirement
```

The Authority commits the exact IAM-family creation/retirement intent before any elevated worker can mutate AWS, including first credential bootstrap. Receiving prompt input is not authorization to perform an unrecorded preparation effect. After interruption, reacquire elevated input for the same recorded operation rather than starting an untracked replacement.

The elevated input is used ephemerally in the provisioning/retirement worker. Do not persist a runtime copy in Vault, MinIO, operation state, Kubernetes objects, argv, environment variables, logs, or evidence. The user-owned `test-secrets.dhall` remains the intentional test fixture source; the runtime never copies its elevated value elsewhere. Validate owner, regular-file/no-follow identity, and mode `0600` on the descriptor actually read.

Production configuration cannot name the test fixture as an auth source. No ambient AWS environment variables, profiles, or host AWS CLI login replace either ingress. Generated operational credentials live in Vault under the selected deployment's identity and least-privilege role policy.

For deletion, keep credentials until their dependants are clean. Commit the recovery/terminal information to the retained local journal before deleting any remote state or backup store. Remove deployment-owned cloud backing objects/buckets while their exact read/write authority remains available, then retire resource credentials and IAM identities in dependency order, then their Vault generations. Establish an independent final verifier in the credential phase, using the same ephemeral elevated ingress when necessary; do not discover at the last EKS deletion that the revoked identity cannot verify its own removal. The final report is local and never requires a write to a bucket already deleted. Incomplete cleanup preserves or reacquires recovery capability through this same workflow.

### 4.4 Vault unlock policies

Define a closed configuration choice with no implicit environment fallback:

| Policy | Source and behavior |
|---|---|
| Production protected unlock | Password-protected bundle/protected external custody; use configured usable material or prompt within the requesting command |
| Test MinIO self-unseal | Test-only MinIO bootstrap object contains the test unlock material; Broker retrieves it automatically for the bound run |

The test MinIO path intentionally has a weaker custody model. Its read capability must be available before Vault, scoped to the exact test bootstrap object and run, with local endpoints and least-privilege access. Any bootstrap credential is test-only and distinct from elevated AWS input. Keep unlock bytes out of reports and ordinary object-list output; deleting the test run retires the object and its access material.

Do not claim encryption whose decrypting key is only in the sealed Vault solves this bootstrap problem. Prove the actual dependency order: retained mounts and images, MinIO bootstrap access, unlock material, Vault unsealed, operational MinIO identities/policies, Authority/worker capabilities. Test automatic restart against the same Vault data without reinitialization.

## 5. Proposed public command topology

The default help teaches the main workflow. Maintenance commands are grouped under `admin`; runtime launchers are under `internal` and omitted from ordinary help. Visibility is generated from `CommandSpec`, not maintained as separate documentation.

```text
prodbox [--config PATH] [--json] <command>
  status
  plan reconcile|delete
  reconcile [--target local|aws]
  delete --yes

  control status|reconcile|delete
  services list|status|logs
  operations list|show|resume|cancel
  config setup|generate|show|validate|schema
  users invite|list|revoke

  test init|list|run|status|cleanup
  dev check|lint|docs|tla-check

  admin aws ...
  admin vault ...
  admin control ...
  admin services ...
  admin edge ...
  admin dns ...
  admin federation ...
  admin host ...

  commands [--tree|--json|--include-internal]
  help <path>
  internal ...
```

### 5.1 Main contracts

| Command | Behavior |
|---|---|
| `status` | Read-only deployment/control/target facts, pending operation and exact next action; useful while Vault, Broker, or registry is down |
| `plan reconcile` / `plan delete` | Same planner and scope as execution; identify unresolved inputs and observations; no hidden recovery mutations |
| `reconcile` | Ensure requested application targets through retained kind; acquire only necessary prerequisites and resume incomplete work |
| `delete --yes` | Remove this deployment's entire owned AWS scope, update local state, retain kind and management services; no `--cascade` or local uninstall branch |
| `control reconcile` | Create/restore kind plus minimal management services; no automatic cloud application provisioning |
| `control delete --yes` | Remove local kind only after its recorded AWS obligations are clean or never admitted; preserve host roots and a usable completion record |
| `services ...` | Component diagnostics for the selected local/AWS target; control services separately identified |
| `operations resume ID` | Continue a named operation through the same engine; no alternate permission or broader scope |
| `test run NAME` | One runner for unit, CLI, real integration, fault, and aggregate scenarios; scenario metadata states prerequisites and proof scope |
| `test cleanup RUN_ID` | Run the same deletion engine for that exact test deployment; remove its disposable local control environment only after cloud cleanup is proven |

`reconcile --target local` installs the canonical local application projection. `--target aws` provisions the AWS projection without moving management authority. With no flag, use the config's explicit desired targets. Selection is never inferred from which checkpoint happens to exist.

Service commands take an explicit target when it is ambiguous. `admin services delete` durably updates the selected specification's component selection and registers that change with the Authority before executing absence, so an ordinary reconcile does not unexpectedly recreate the component. Config publication is atomic and recoverable. A temporary process action is named stop/restart instead; it must not masquerade as desired-state deletion. Both operations honor dependency checks and cannot remove control capabilities needed by pending cloud work.

Do not turn `plan` into a mandatory plan-file ceremony for ordinary commands. Execution reobserves mutable preconditions. Exceptional ownership adoption or dangerous data purge requires an explicitly scoped digest/confirmation.

Local data destruction is a separate `admin control purge-data` operation requiring exact identity, successful cloud retirement, no mounted consumers, and explicit typed confirmation. It cannot fall back to an account sweep or recursive deletion of an unknown root. Production purge remains operator-only; scoped disposable test-root cleanup is authorized by the test run contract.

### 5.2 Results and operator output

Use structured outcomes: `NoChange`, `Completed`, `NeedsInput`, `Incomplete`, and `Failed`. Distinguish outcomes in JSON and document their exit codes once. Use zero only for a satisfied requested goal. A live read-only status that cannot observe a requested component reports that fact; it does not fabricate a healthy aggregate.

Print scope, observed facts, action, and outcome. Keep internal signer/CAS/stack details behind verbose diagnostics unless they change the operator's next action. Examples:

```text
Deployment: example-production
AWS: never provisioned by this deployment
Nothing to delete. Local kind control plane retained.
```

```text
Vault is initialized and sealed. Unlocking from this test run's MinIO bundle...
Deleting AWS deployment example-run-123...
AWS deletion verified. Operational credentials revoked.
Local kind control plane retained. Operation: operation-123
```

If AWS cleanup is incomplete, name actual resources/families and the failed dependency, preserve operation identity, and give one canonical resume/remedy. Do not repeat one Vault failure as three independent stack failures.

### 5.3 Existing-feature disposition

Phase 0 captures every existing registry leaf and option in a machine-readable migration manifest. The following grouping is the required product coverage; the manifest expands repeated stack/suite patterns to exact leaves.

| Existing surface or capability | Target and disposition |
|---|---|
| Cluster reconcile/status/health/wait | Top-level reconcile/status; wait/health detail under `admin control`; all use capability observations |
| Cluster start/stop/restart/logs | `admin control` kind semantics; logs remain diagnostics, restart preserves data; no assumption of RKE2 systemd units |
| Cluster workload logs | `services logs` with explicit target and service |
| Cluster delete, `--cascade`, `nuke` | Ordinary AWS delete + separate control removal/data purge; remove old flags/routes after their safe replacement is live |
| Four AWS stacks: eks, test, aws-subzone, aws-ses | `admin aws stack <eks|test|subzone|ses> status|diff|reconcile|delete`; exact-target clients of the common engine |
| AWS setup/teardown/policy | `admin aws credentials status|reconcile|revoke|policy`; routine reconcile/delete invoke the same credential handlers automatically |
| AWS audit/quotas check/request | `admin aws audit`, `admin aws quotas check|request`; audit states declared field and observation limits |
| Test EBS reaper, EKS network purge | Normal cleanup is automatic; exceptional repair uses `admin aws recovery plan|apply` with a closed repair kind |
| Corrupt checkpoint prune, legacy adoption, SES backend migration | Typed `admin aws recovery` plans; preserve source/ownership evidence and digest binding; no arbitrary AWS passthrough |
| Charts list/status/reconcile/delete | Read-only `services` plus `admin services reconcile|delete` for explicit component work through common desired-state ownership |
| Edge reconcile/status, DNS check | Main reconcile/status include them; detailed `admin edge` / `admin dns` remain available |
| Users invite/list/revoke | Preserve `users`; identity, email, and auth semantics remain real end-to-end features |
| Gateway status/start/config generation | Status in services; process launch internal; role-config generation under dev/internal tooling |
| Vault init/reconcile/unseal/seal/status | Automatic init/unlock where appropriate, diagnostics and manual operations under `admin vault`; init cannot overwrite damaged retained state |
| Vault ambiguous-init reset, unlock/Transit rotation, PKI status/test issuance | Preserve explicit scoped recovery/rotation under `admin vault`; no generic reset-by-flag |
| Federation register | `admin federation register|status`; preserve explicit child trust and recovery as Phase 9 work |
| Host tools, ports, info, SES readiness, firewall restrict/unrestrict | `admin host`; kind-aware diagnostics and networking |
| Config setup/generate/show/validate/schema | Preserve purposes under `config`; test generation never overwrites the production sibling |
| Test init/run/all/lint/unit/integration and every named suite | One scenario registry and `test run NAME`; lint maps to dev check, unit to named unit scenario, all to aggregate; remove duplicate dispatch paths |
| Cascade qualification / receipt suites | Rename to delete/recovery scenarios and bounded evidence inspection; historical receipts do not qualify the new topology |
| HA RKE2/AWS suite | Retire RKE2 as a provisioner-specific target; preserve its gateway HA/failover objectives on multi-node kind and EKS in Phase 9 |
| Other named suites: IAM/DNS/EKS/Pulumi, lifecycle/recovery/interruption, charts/storage/volumes, capacity, gateway, daemon, Pulsar, routes/TLS/invitation/sealed Vault | Preserve each substantive assertion in the scenario registry with an owning phase; consolidate overlapping setup/cleanup, not assertion coverage |
| Dev check/lint/docs/TLA, help/commands/generated docs/completions | Preserve, generate from typed registries, update topology and phase checks atomically |
| Broker/Authority/Provider/Backup/TLS/Agent/Provisioner/Admin Action/workload launchers and RPC birth controller | `internal` launchers; same runtime roles as required by the new architecture, no ordinary operator setup sequence |

A mapping to “internal” must not bypass authentication. A mapping to “removed” requires the rationale and replacement assertion, if any. Do not preserve obsolete distributed-protocol machinery merely because it has a launcher; do not remove a microservice or product capability merely to shorten help.

## 6. Change the documentation and development doctrines first

This section is the work specification for Phase 0. Updating only prose while leaving the old checker grammar and completion rules active is not adoption.

### 6.1 `documents/documentation_standards.md`

Replace the contradictory or overbroad rules with these contracts:

- One owner for each **decision**, one for each **implementation status**, and one for each **acceptance result**. Architecture describes the accepted target; current command availability is generated from code; phase records state what is actually validated. Target text cannot masquerade as implemented behavior.
- Header metadata remains. Add an explicit applicability field for target/implemented/historical scope where needed; admit `REFACTOR_PLAN.md` as a root planning artifact until adoption retires it. Do not require plan proposals to pretend to be current doctrine.
- Stable architecture contains invariants and rationale, not dated probe diaries, sprint numbering, transcript hashes, or constantly amended implementation correspondence. Put current evidence in bounded phase records; retain historical evidence separately.
- Keep relative links and generated-section checks. Allow short operator workflow examples where useful; distinguish duplication of authoritative facts from examples that exercise those facts.
- Use one canonical architecture ownership map and one generated command reference. Prefer a small coherent set of documents to dozens of overlapping doctrine fragments.
- Mark replaced documents deprecated, name their replacement and removal phase, migrate incoming links, then delete. Do not retain two authoritative variants.
- Evidence links must resolve to retained artifacts or an explicitly historical source identity. A source filename or test that no longer exists cannot support current closure. Preserve needed non-versioned evidence with an availability manifest and a removal owner.
- Use snake_case for the new `legacy_tracking_for_deletion.md`. Rename the existing hyphenated file and update links/checkers in the adoption transaction; do not create a second ledger.
- Do not embed a competing open-work queue in engineering docs, the root README, or this proposal after adoption.

### 6.2 `DEVELOPMENT_PLAN/development_plan_standards.md`

Replace the current phase/sprint machinery with a simpler numbered phase model:

| Current rule/problem | New rule |
|---|---|
| Fixed old 0–8 filenames and phase ownership | Adopt the Phase 0–10 files in Section 9; every product objective and legacy row has one numerical owner |
| Independent validation can substitute a fake for an incomplete later dependency | Phase N depends only on completed 0…N−1 and declared external prerequisites. If real closure needs N+1, move that deliverable to N+1 or reorder the plan before implementation |
| `Done` components with mandatory live/composition proof pending | `Complete` means every declared phase acceptance case, critical mutation check, cleanup, docs, and owned removal passed. Component tasks may be implemented while the phase remains open |
| Separate qualification axis can postpone actual public behavior | Production-composition proof required by the phase is a closure gate in that phase; the final phase repeats existing proofs |
| Backward dependencies and fractional sprint proliferation | No backward dependencies and no unbounded new decimal sprints. Use stable tasks inside a phase and a bounded defect-class record |
| Replacement complete while its own removal rows remain pending | The phase cannot close while it owns pending removal rows; dependencies are earlier/current phases only |
| Unowned cleanup rows | Zero unowned rows after adoption; uncertainty is a discovery task with a numerical owner |
| Reopen only as narrative expansion of an owned surface | A reproducible regression reopens the owning phase and invalidates affected downstream results until rerun; it does not silently change the contract |
| Globals → phase → doctrine maintenance order | Decision/doctrine → phase ownership and acceptance → implementation/removal → real validation → closure |

Phase states are `Planned`, `Active`, `Blocked`, and `Complete`. Task implementation is separate from phase completion. A missing external AWS credential or unavailable provider may genuinely block the phase that requires it; it does not justify fake closure or a dependency on unimplemented later code.

The README contains exactly one numerical queue. The first incomplete runnable phase is next. Keep short per-phase records of scope, prerequisites, task status, acceptance command, evidence reference, and owned removals. Do not transplant the 36,000-line historical resume ledger into the replacement.

Every phase definition includes:

1. Frozen inputs and public behavior added in that phase.
2. Prior-phase and external prerequisites; no future-phase prerequisite.
3. Product objectives and resource families introduced.
4. Specific real happy-path, adverse, resume, and cleanup cases.
5. Independent observer, deliberate negative controls, and named critical source-code mutations with their expected failing assertions, execution budgets and outcomes.
6. Source/binary/image/config identity excluding secret bytes, and execution/cleanup evidence.
7. Owned legacy rows and the exact condition for removing each.
8. Documentation changes and a cumulative regression command.

Preserve useful live-campaign rationing: batch related fixes, record what a real run taught, use at most the existing three AWS-spending attempts per session without a new reproducer, and stop for class review after repeated new-boundary failures. A new boundary reached is progress in diagnosis, not phase completion. Keep least privilege, spend budgets, cancellation, and read-back requirements.

Preserve formal models and property tests where they establish useful laws. They supplement the actual execution evidence; they do not certify Kubernetes behavior, provider cleanup, memory fit, or security policy enforcement by construction alone.

### 6.3 Migrate the enforcement with the doctrine

`src/Prodbox/CheckCode.hs` currently hardcodes governed roots, the legacy ledger path/table grammar, queue structure, and sprint conventions. Phase 0 updates those expectations and their tests atomically with the renamed files and new phase records.

Retain one canonical `prodbox dev check` entrypoint. Add focused enforcement for command-disposition completeness, phase dependency direction, objective coverage, evidence/acceptance/mutation identifiers, and removal-owner validity. Prove the checks reject a planted missing command mapping, future dependency, missing removal owner, and invalid evidence reference. Mutation metadata checks validate ownership and result bindings; they do not substitute for executing the mutants. Do not disable existing checks wholesale or add a blanket exception for the new plan.

Do not expand the checker into another theorem-proving framework. Mechanical checks validate structure and cross-references; real scenario execution validates behavior.

## 7. Refactor `documents/` around product responsibilities

Adopt this ownership map in Phase 0. The new destination files contain target contracts; affected phases update implemented correspondence without rewriting the target. A document family may remain split when it is genuinely independent; consolidation is about ownership, not a file-count target.

| Proposed canonical owner | Existing documents to merge, narrow, or replace |
|---|---|
| `engineering/product_architecture.md` | High-level objectives, component boundaries, kind/EKS target distinction; replaces architectural duplication in README/inventories |
| `engineering/cli_command_surface.md` | Keep path, replace command model, visibility, delete semantics, output and recovery; generated detailed reference remains `documents/cli/commands.md` |
| `engineering/lifecycle.md` | Lifecycle reconciliation/control-plane architecture, resource evidence contract, operation identity and cleanup semantics |
| `engineering/control_plane.md` | kind topology, bootstrap readiness, host adapters, retained artifacts, role placement and local recovery |
| `engineering/storage.md` | Storage lifecycle, production/test roots, static PV/EBS policy, mounts, backup/restore, final local purge |
| `engineering/configuration.md` | Configuration doctrine and typed prerequisites; source partition, explicit context and minimal bootstrap inputs |
| `engineering/security_and_credentials.md` | Vault, secret derivation, AWS admin input, test self-unseal, role policies, redaction, rotations, PKI and external custody |
| `engineering/platform_and_services.md` | Chart platform, registry pipeline, service catalog, PostgreSQL operators, MetalLB locally/AWS Load Balancer Controller on EKS, image delivery and service parity |
| `engineering/public_edge.md` | Envoy edge, ACME guide, DNS/TLS, SES, authentication and user invitation |
| `engineering/aws_resources.md` | AWS environment/substrate ownership, provider families, quotas, exact discovery and deletion, EKS/EBS/controller dependents |
| `engineering/gateway_and_messaging.md` | Gateway runtime, Pulsar client/broker/topics, mesh/HA and retained emitter continuity |
| `engineering/testing.md` | Unit policy, integration fixtures, test topology, real-provider observations, targeted mutation testing and phase acceptance rules |
| `engineering/resource_governance.md` | Host/container/workload CPU, memory, ephemeral/durable disk, concurrency, measured profiles and admission |
| `engineering/haskell_code_guide.md` | Keep language guide; absorb relevant pure-FP/effect/refactoring material without mandating redundant protocol layers |
| `engineering/code_quality.md`, `dependency_management.md` | Keep canonical quality/build/pinning ownership; update generated artifacts and kind toolchain |
| `engineering/federation.md` | Explicit child registration, trust, custody and cross-cluster recovery; Phase 9 implemented scope |
| `engineering/tla/` plus model correspondence | Keep useful runnable models; archive/delete those tied solely to removed protocols after replacement regression coverage exists |
| Operator guides under `documents/operator/` | Short setup, everyday workflow, recovery, testing, credential/unlock, migration, and deletion/data-loss guides |

The account/domain onboarding guide remains an operator prerequisite guide. Burn-recipient provenance or other immutable security ceremony records remain historical security evidence, not active runtime setup instructions. Generic future ML/autoscaling examples are either retained as clearly non-product reference material or removed; they do not become mandatory prerequisites for this refactor.

`documents/engineering/README.md` becomes a short ownership index. `DEVELOPMENT_PLAN/system-components.md` becomes a concise target catalog without probe diaries. `substrates.md` describes kind versus EKS projection and ownership, not a second status ledger. Update root README, AGENTS.md, CLAUDE.md, generated manpages/completions/goldens, Docker docs, Cabal module lists, and inline doctrine links as the owning changes land.

Before deleting old text, extract each actual requirement into an objective/disposition manifest: retain, replace, or deliberately remove, with rationale and owner. Historical status remains in Git. Non-versioned artifacts that still substantiate a regression remain available until their explicit retention condition ends.

## 8. Spoof-resistant phase validation

“Spoof-free” here means a scenario cannot pass merely because its own code printed success, returned a constructed witness, read a cached receipt, or used a fake implementation of the effect being claimed. State the concrete limits of each proof; do not promise an unbounded mathematical guarantee about a cloud account.

### 8.1 Acceptance runner from the beginning

Build the common scenario runner and evidence schema in Phase 1. Later phases add scenarios to that runner. Each scenario invokes the actual built public binary with explicit config, real interpreters, owned environment, bounded budgets, and independent observation. Phase 0's document/checker validation is real repository validation, not a claim about a runtime not built yet.

The runner records: scenario and case IDs, source-manifest identity, binary/image digests, non-secret config projection, environment/deployment/operation IDs, commands, start/end, observations, primary result, cleanup result, and observer failures. No plaintext secret or public raw hash of a secret enters evidence. Artifacts have an availability manifest.

For production-policy acceptance, create an isolated project anchor inside the test run and its own `.data/<id>` beneath that anchor. Invoke the normal production-policy CLI and drive its real protected prompt through an owned terminal when required; do not enable a special production-bypass flag or point at the operator's real root. The outer run owns the disposable project and its distinct cloud identity. This tests production behavior without conflating the operator's production installation with the test environment.

### 8.2 Independent observations and negative controls

| Claimed property | Required observation | Negative control |
|---|---|---|
| Storage survives kind loss | Write random non-secret marker through a Pod, destroy/recreate nodes through the control adapter, read it through a new Pod and verify host-root binding | Wrong mount/generation must fail; a Pod restart alone does not qualify |
| Vault boot/unseal | Real Vault initialized/sealed status and authenticated secret round-trip | Wrong password/key, missing object, unreachable MinIO and changed Vault data must fail distinctly |
| AWS credential workflow | Real IAM/STS identity/use, real Vault storage, independent IAM and Vault retirement checks | Ambient credentials, unsafe fixture mode, denied required action and still-live key must fail |
| Provider lifecycle | Service-specific inventory for the declared ownership scope, before/after effects and on resume | Withheld create/delete, wrong account/region, leaked child and unanswered API query must invalidate the result |
| Service readiness | Real protocol/application request and required persistence behavior | Remove dependency or deny traffic; unchanged Ready conditions cannot rescue the check |
| Network isolation | Actual allow/deny connections under the pinned CNI/policies | Disabling the policy must change the observed result |
| Real public TLS/auth | Independent DNS lookup and TLS verification plus auth redirect/token/API behavior | Wrong certificate/host, missing DNS and unauthorized request must fail |
| Delete is complete | Exact required resources absent, credentials retired, obsolete state retired, retained control plane still works | Resource residue or missing read-back prevents successful completion |
| Observer is meaningful | Evidence gate rejects missing/fabricated/wrong-scope output and detects a deliberately retained disposable resource | Runner exit zero or a copied old receipt cannot pass |

Use fakes for pure decisions, protocol edge cases, and deterministic fault injection. They are useful local tests but cannot close a phase's real-component/provider claim. A fault proxy may lose a real reply; it may not manufacture the provider response used to certify absence.

Read-only independent provider diagnostics may inspect the real account for the admitted scope. All mutations, including deliberate test residue and fault setup, go through registered prodbox operations. No manual cleanup or ad-hoc mutation counts as a passing scenario. Include provider positive controls where needed to distinguish a blind observer from an empty field.

### 8.3 No future-phase dependency

At Phase N, the acceptance command runs only the real capabilities introduced through N. An intentionally later service is outside this phase's claim, not a skipped requirement hidden behind a green aggregate. The runner can list planned cases but must not count them as passed. `test run all` on the final product includes all accepted product cases; earlier phase closure uses an explicitly named cumulative phase set.

Real AWS prerequisites first appear at the credential phase. Earlier phases validate without AWS, SES, external DNS, or EKS. Real public-edge requirements first appear in the edge phase. This is dependency ordering, not substitution of fake later systems.

A later phase extends catalog entries and scenarios without changing established delete, root-isolation, credential-input, or evidence semantics. If an apparent future dependency appears, repair the phase boundary before implementing a workaround. Any genuine contract change requires an explicit amendment, affected-phase reopening and regression; never silently reverse an earlier decision.

### 8.4 Targeted source-code mutation testing

Add mutation testing as a phase-completion gate for critical lifecycle decisions and the observers that validate them. Here a **source-code mutation** is a deliberate implementation change used to determine whether the unchanged tests detect the resulting defect. It is distinct from an infrastructure mutation, fault injection, or a bad test input. Keep all of these forms of testing, with separate evidence for what each establishes.

Use a small reviewed catalog of named semantic mutations, plus a bounded selection around changed critical code. Do not impose a repository-wide mutation percentage or mutate every Haskell expression. Prioritize historical failure classes and boundaries where an incorrect answer could cross environments, lose recovery capability, or falsely report cleanup. New source faults discovered by live runs become targeted mutation cases when reproducible.

| Critical mutation | Expected test failure | First owning phase |
|---|---|---:|
| Disable a phase-direction, removal-owner, or evidence-reference check | The corresponding invalid-plan fixture is incorrectly accepted and its checker assertion fails | 0 |
| Remove a root/environment/context ownership check | A foreign or production/test-crossing synthetic context is admitted and its rejection assertion fails | 1 |
| Make the evidence validator accept absent, fabricated, or wrong-scope results | The validator's adversarial report case fails | 1 |
| Permit test self-unseal policy in a production context, or initialize over a recorded storage mismatch | The production-policy or same-Vault-identity assertion fails | 2 |
| Treat unobservable or missing existing journal state as absence/NeverAdmitted | The uncertainty/recovery assertion fails | 3 |
| Report `NoChange` despite an unresolved admitted operation | The pending-obligation/no-op assertion fails | 3 |
| Revoke credentials before dependants are clean, or omit IAM intent registration before creation | The resource-before-credential ordering or write-ahead assertion fails | 4 |
| Skip provider deletion or its required read-back, or retire its checkpoint early | The residue or recovery-custody assertion fails | 5 |
| Make an independent resource observer return `Clean` unconditionally | A retained-resource or unanswered-query case is wrongly accepted and its observation assertion fails | 5 |
| Skip application persistence or dependency checks | The corresponding service/storage assertion fails | 6 |
| Omit an owned DNS/SES/S3 family from delete, or retain the old SES exemption | The complete-family cleanup assertion fails | 7 |
| Omit an EKS controller-dependent family or select a drain target from another stack | The dependency inventory or exact-target assertion fails | 8 |
| Admit a successor before predecessor settlement, or accept a stale federation/worker identity | The ownership/settlement assertion fails | 9 |
| Permit competing old/new writers or substitute a fresh identity during import | The migration exclusivity or identity-continuity assertion fails | 10 |

These are semantic faults to seed, not permission to execute unsafe provider actions. The catalog binds each mutation to exact source locations/preconditions, the violated invariant, owning phase, selected tests, intended assertion/test ID, and fixed build/execution budget. Detect changed or missing patch sites rather than silently skipping a mutant. Extend an existing case to every adapter that implements the same critical rule as those adapters arrive.

**Execution and result validity:**

1. Establish a passing unmodified baseline for the same selected tests and dependencies. Apply one mutation at a time in an isolated non-secret source snapshot with a separate build directory. Never overwrite the operator binary or working source tree, alter the tests to accommodate the mutant, or copy `test-secrets.dhall`, production/test data roots, generated secrets, or ambient credentials into the mutation workspace.
2. Build and exercise the actual mutated implementation. Run the unchanged tests and require the identified invariant's assertion to fail. A hand-written model of what the mutant would do does not exercise the mutant. When the observer/harness itself is the subject, keep its independent meta-test/checker unmodified.
3. Record `Killed`, `Survived`, `Invalid`, `Inconclusive`, or `Equivalent`. `Killed` requires the expected behavioral assertion/test failure. Compilation failures are `Invalid`; unrelated test errors, unavailable dependencies, and generic timeouts are `Inconclusive`. A timeout alone never proves the intended fault was detected.
4. A surviving critical mutation prevents phase closure until the tests detect it or a documented equivalence review proves it cannot change supported behavior. An equivalence exclusion records its reason and source/contract identity; replace an equivalent candidate with a meaningful fault where possible. Invalid/inconclusive runs and silent skips do not satisfy a required critical case. Do not weaken assertions or silently remove cases to obtain a green score.
5. Bind the result to the baseline source/build identity, patch identity, test selection and expected assertion, actual failure, duration and cleanup. Re-run affected mutations when the implementation, relevant tests, observer, or mutation definition changes; an old kill is not current evidence for a changed path. Report counts by outcome and their scope without presenting an aggregate score as a reliability guarantee.

**Execution boundaries:** run dangerous ownership/deletion/credential mutants offline against recorded provider-boundary fixtures and pure/interpreter-boundary tests. Mutant execution receives no real AWS credentials, elevated fixture input, production root, or network route to real provider APIs. Use actual disposable local services only for explicitly reviewed local cases, under unmodified outer isolation and cleanup ownership. The mutated code cannot grant its own safety boundary or certify its own cleanup; the outer runner verifies workspace/local-resource retirement.

Enforce these limits with the process/container isolation available in Phase 1, not only by clearing environment variables. Do not expose the current kubeconfig, host data roots, unrestricted container-runtime socket, or artifact publication credentials. Build from prepared trusted dependencies without provider egress. The unmodified outer runner may provision an exact disposable local fixture and lend only its scoped interface; mutated binaries/images can never enter production or real-AWS deployment/publication paths. Phase 1's runner checks must demonstrate these denials.

Real AWS and public-edge qualification continue to use the **unmodified** implementation and actual provider observations. Offline mutation results show that the relevant tests detect seeded defects; they do not replace real-component composition, credential, cleanup or provider evidence. Match the same semantic invariant across the offline mutant case and its real scenario.

**Delivery and cost:** Phase 0 defines the catalog/closure rules and exercises its checker mutants in scratch copies using existing build tooling; it does not depend on Phase 1's runner. Phase 1 adds the minimal bounded mutation executor to the existing test/evidence runner and proves outcome classification with a known detected fault, a compiled surviving fault, an invalid mutant and an inconclusive execution. Later phases add and kill their own required cases using already completed capabilities. Expose this through the existing scenario registry, for example `test run mutations`; cumulative phase acceptance includes its owned critical cases. Pure build/fixture work may be included in the canonical gate within its declared budget. Do not build a separate general mutation framework or trigger a live cloud campaign for every mutant.

## 9. Replacement `DEVELOPMENT_PLAN/` and numerical execution

Phase 0 replaces the active plan with:

```text
DEVELOPMENT_PLAN/
  README.md
  development_plan_standards.md
  objective_dispositions.yaml
  command_dispositions.yaml
  acceptance_cases.yaml
  mutation_cases.yaml
  phase_00_contracts_and_documentation.md
  phase_01_cli_contexts_kind_and_evidence.md
  phase_02_vault_minio_and_bootstrap.md
  phase_03_authority_and_local_lifecycle.md
  phase_04_ephemeral_credentials.md
  phase_05_first_complete_aws_lifecycle.md
  phase_06_local_platform_and_applications.md
  phase_07_public_edge_email_and_users.md
  phase_08_eks_and_substrate_parity.md
  phase_09_ha_federation_and_recovery.md
  phase_10_migration_and_final_regression.md
  legacy_tracking_for_deletion.md
  system-components.md
  substrates.md
  evidence/README.md
```

The YAML files are small structural inputs for the existing Haskell checker, not a second runtime configuration language. Generate redundant queue/cross-reference views where useful; do not duplicate task status into every manifest. Acceptance and mutation results belong to phase evidence records. `mutation_cases.yaml` contains definitions and bindings, not self-authored claims that a mutant was killed.

The README links each phase, its current state, next task, acceptance set, and unresolved external prerequisite. Archive old plan history in Git and preserve references needed to find historical regressions. Do not copy old Done labels into new phases. Reuse existing implementation only after the new phase validates it.

### Phase 0 — Contracts, doctrines, documentation, and removal ownership

**Prerequisites:** current repository and build/check tooling; no cluster or AWS.

**Deliver:** implement Sections 6–7 as documentation and checker changes. Adopt the target architecture, command semantics, security tradeoffs, root contract and service inventory. Expand the complete existing command/option and product-objective inventories into dispositions. Create all Phase 0–10 records, their acceptance cases, critical mutation catalog and the renamed legacy ledger. Map every old open sprint and pending/unowned removal row to a retained task, replaced task, or explicit retirement with a new owner. Update root navigation and agent instructions.

**Validate:** run the real documentation/registry/phase checker and canonical quality gate. Plant controlled repository copies with a missing command disposition, backwards dependency, broken link, absent acceptance ID and unowned legacy item; each must fail for its intended reason. Check that all existing features have a disposition and all pending rows an owner. No runtime behavior is certified here.

Seed the named checker source mutations in separate scratch copies, build them with existing tooling, and prove the unchanged invalid-plan assertions fail. These are the first source-mutation cases, not merely malformed-input tests. Record results under Section 8.4 without waiting for the next phase's automation.

**Remove:** conflicting phase/status grammar, duplicate queues, active migration diaries and competing doctrine ownership. Rename the legacy ledger and checker references atomically. Keep historical evidence attributable and available.

**Exit:** a reader can select Phase 1 without interpreting old fractional sprint order. No new phase depends on a larger phase number. Every target capability has an owner and an acceptance requirement.

### Phase 1 — Public CLI foundations, isolated contexts, real kind, and evidence

**Prerequisites:** Phase 0; supported Linux host with the pinned container runtime/kind prerequisites.

**Deliver:** the typed request/visibility model, explicit context and config loading, production/test root identities, path safety, bootstrap manifest, kind adapter, pinned node/artifact contract, and real scenario/evidence runner with the bounded offline mutation executor from Section 8.4. Start exposing completed control/diagnostic commands through their final paths. Planned later commands are documented as planned, not installed as successful stubs.

Implement host `extraMounts`, per-environment kubeconfigs/ports/network allocation, local API access, deterministic PV binding, and the bootstrap image loading boundary. Pin actual tool/node/CNI versions in dependency management; do not guess the current upstream version in this proposal. Establish and test the management network-isolation primitive here, before later phases handle secrets or elevated AWS input.

Establish host/container capacity discovery, enforceable management resource limits, and a reserved envelope for steady management plus the allowed concurrent secret/provisioner workers. Validate admission with real scheduled bounded worker Pods; do not defer management capacity to Phase 6. Any early `control delete` is restricted to new Phase 1 identities whose enrollment prevents all cloud admission; existing, foreign, or uncertain identities refuse until their obligation-aware path is available.

**Validate:** create two disposable kind environments, one representing production semantics and one test semantics, without touching the operator's real `.data/`. Write different random markers through real Pods, recreate kind nodes, and read back exact bytes from new Pods. Demonstrate that contexts cannot mount each other's roots, collide on ports, or act through ambient kubeconfig. Prove actual allowed and denied management test traffic under the pinned CNI, including the disabled-policy negative control. Test malformed/symlinked/overlapping roots, wrong identity and node/container loss. Exercise the actual CLI and prove the evidence runner rejects missing/wrong-scope reports.

Kill the root/context and evidence-validator mutations, demonstrate that the runner distinguishes killed/surviving/invalid/inconclusive outcomes, and prove a generic failure cannot count as the expected assertion. Re-run Phase 0's checker mutations through the new automation. Later phases own their corresponding Section 8.4 cases and run them before closure, without sending mutants to AWS.

**Remove:** RKE2 assumptions from the **new-install** host/context path; duplicate context and config selection. Existing-install migration code remains explicitly owned by Phase 10, not called by new enrollment.

**Exit:** local kind lifecycle and storage retention work before Vault, application services, DNS, or AWS exist. No cloud capability can be admitted.

### Phase 2 — Real Vault/MinIO bootstrap and unlock

**Prerequisites:** Phase 1 only; no AWS, DNS, SES, registry service, or later Authority implementation.

**Deliver:** real MinIO/Vault/Broker deployments and bounded secret workers, the two explicit unlock policies, operational baseline, and direct read-only component status. Bootstrap from pinned locally available images. Separate bootstrap MinIO access from steady-state Vault-backed MinIO credentials. Include backup/restore and storage-generation detection for this owned scope.

**Validate:** actual initialization, secret round-trip, seal, test self-unseal from MinIO, protected-production-policy password prompting, noninteractive input-required result, wrong password/key, missing bundle, interrupted initialization, MinIO outage, Broker outage and wrong storage mount. Prove the actual Broker/worker/Vault/MinIO allowed and denied paths using Phase 1's network-isolation capability. Recreate kind against retained data and prove it unlocks the same Vault, retains the secret, and does not call init again. The production-semantics test must reject the test unlock policy.

Measure the running management projection and execute its permitted concurrent real secret workers within Phase 1's budget; prove scheduling, completion, limits, and retained headroom rather than relying only on arithmetic or templates. Phase 4 repeats this check for the elevated-credential worker. Phase 6 adds application budgets to this existing resource-governance implementation.

**Remove:** registry-dependent management bootstrap, shared production/test unlock fallback, status-through-ready-Broker coupling, and init/unseal flows that misclassify uninitialized or replaced storage as ordinary authentication failure.

**Exit:** each advertised bootstrap/recovery case works against real services and every introduced secret worker terminates or remains explicitly owned for recovery. No future cloud adapter is needed.

### Phase 3 — Retained Authority and the shared local lifecycle engine

**Prerequisites:** Phases 1–2.

**Deliver:** the actual Authority journal, public metadata projection, operation model, catalog/planner/interpreter boundary and status/plan/delete/resume contracts. Establish local backup and crash recovery. Bind NeverAdmitted to a successfully established identity and admission history, never to a missing file or blank Vault. Add provider intent registration before any future cloud effect can be authorized.

Activate `delete` for registered new deployments with no admitted AWS work: it succeeds without cloud credentials, leaves management services intact, and prints its exact scope. An initialized sealed Vault is unlocked only when the pending work requires it. Status remains available when dependencies are down. Separate control removal and test-root cleanup from ordinary delete.

**Validate:** fresh delete twice, interrupted local bootstrap, initialized/uninitialized/sealed/unreachable Vault distinctions, diagnostic projection staleness, concurrent commands, killed/restarted Authority, durable operation resume, missing/corrupt journal and wrong root. Prove a missing existing journal cannot be reclassified as NeverAdmitted. Verify no-op delete does not contact AWS or initialize Vault. Prove control removal refuses outstanding/unknown cloud obligations.

**Remove:** bespoke installed/no-install decision funnels for **new deployments**, checkpoint-derived target inference, repeated auth-failure triples, and duplicate local cleanup dispatch. Remove `--cascade` from the active new operator surface and generated artifacts. Preserve any still-needed original-install cleanup only as the fenced migration lane described in Section 11, with an explicit later remover.

**Exit:** one actual public engine reaches the local/never-admitted goals and recovers its own state. It does not claim support for AWS families whose adapters have not been delivered.

### Phase 4 — Real ephemeral-admin and operational credential lifecycle

**Prerequisites:** Phase 3; declared real test AWS account and owner-safe `test-secrets.dhall` elevated fixture. External account onboarding is not a later product feature.

**Deliver:** the common operator/test credential ingress, bounded Provisioner worker, least-privilege generated identities, Vault delivery, provider session creation, cleanup/recovery and independent final revocation verifier. Register this first real AWS resource family before its first effect; ordinary `delete` must already reconcile its IAM/Vault obligations, rather than retaining Phase 3's never-admitted result. Use an explicit production-semantics prompt driver and the real test fixture driver against the same implementation.

**Validate:** create a real narrowly scoped identity, observe its actual account/principal and allowed/denied actions, resolve its operational material from real Vault, restart/resume, then revoke and independently confirm exact IAM key/user/role/policy disposition and Vault generation retirement. Interrupt after identity creation and after Vault delivery, lose a real reply, and recover. Test fixture mode/ownership/region validation, noninteractive missing input, ambient auth rejection, redaction, token expiry and real server-supported token retirement behavior.

**Remove:** parallel AWS setup/test preflight implementations, fixture-to-production configuration copying, broad/shared operational credentials, credential cleanup that reports success without observation, and credential paths not bounded by a registered operation.

**Exit:** credential creation and deletion are fully real and recoverable before EKS or public-edge features enter the dependency graph. Elevated input has no runtime persistence copy.

### Phase 5 — First complete AWS lifecycle through the public engine

**Prerequisites:** Phase 4; same real account and a small fixed spend budget.

**Deliver:** the first cheap real AWS resource family, preferably the existing test/S3 family with object-version cleanup, using the final resource adapter interface. Establish ownership tagging/naming, write-ahead admission, exact service inventory, checkpoint independence, partial-create recovery and terminal reports. Scoped `admin aws stack test` and ordinary `delete` are clients of this same engine.

**Validate:** real create/use/delete, delete again, interruption before/after effect, lost provider response, missing/corrupt checkpoint while the resource remains, denied observation and deliberately retained disposable residue. Query the real declared provider field with independent positive controls. Prove cleanup and IAM/Vault retirement, operation resume after command/Authority restart, and retained kind/Vault/MinIO health. Run two consecutive complete audit-clean cycles under the recorded build, within live-campaign limits.

**Remove:** the migrated family's old provider/stack execution and harness cleanup path. The old EKS implementation does not count as a dependency or a completed adapter for this phase.

**Exit:** a real cloud target can be provisioned, interrupted, recovered, deleted, and reported empty by the actual public deletion engine. No EKS, SES, or public DNS required.

### Phase 6 — Canonical local platform, application services, and image delivery

**Prerequisites:** Phase 5; local service tests themselves require no cloud beyond explicitly selected prior capabilities.

**Deliver:** the full local application projection: gateway, Keycloak, application PostgreSQL via Percona, VS Code, API, Redis, websocket; MinIO and registry:2; Percona operator, MetalLB, Envoy Gateway and cert-manager. Preserve Pulsar broker/client/topic lifecycle and gateway messaging features. Keep management and application instances/scopes distinct where they would otherwise share lifecycle ownership.

Implement the final registry/mirror pattern, actual images, host/LAN publication, resource requests/limits/quotas, static storage, service-specific readiness, and the `services`/admin component operations. Phase 0 fixes the local publication contract: retain MetalLB with a kind-network address pool and explicitly published host ingress into Envoy, rather than assuming its former RKE2/LAN addresses transfer unchanged. Phase 1 reserves the necessary node port mappings; this phase proves actual Service, Docker-network, host and intended LAN reachability. Any additional publication process is lifecycle-owned and budgeted.

**Validate:** uncached image pulls after registry restart; real API/auth/Redis/websocket/VS Code/Pulsar/SQL interactions; persistence after Pod and kind-node replacement; actual NetworkPolicy allow/deny behavior; service failure and recovery; capacity fit including transient workers; application component deletion while management remains available. Local certificate checks need not claim public ACME proof, which belongs to Phase 7. Default cloud delete leaves local application/data scope identifiable and does not accidentally stop control services.

**Remove:** duplicate substrate platform/service catalogs, registry bootstrap cycles, gateway authority/secret/provider fallback responsibilities, RKE2-specific local networking in the new application path, and duplicated test bring-up implementations for this projection.

**Exit:** all retained local service features have real protocol and storage checks. The same catalog can be projected onto EKS later without replacing its semantics.

### Phase 7 — Real public edge, SES, identity and user journeys

**Prerequisites:** Phase 6 and existing credential/AWS lifecycle; real delegated domain/parent-zone access, ACME/ZeroSSL inputs, SES prerequisites and required spend/quotas.

**Deliver:** real managed Route 53 records/subzone where needed, ZeroSSL DNS01, certificate retention/restore/rotation, SES identity/sending/receiving/receipt resources, user invitation/list/revoke, Keycloak login and gateway/API/websocket public authorization. Local kind remains the management and local application target.

Introduce any optional remote Authority-backup storage adapter here, including its objects/versions, bucket and IAM scope, before Phase 8 claims complete supported-family deletion. Local control and terminal reporting never require that remote store to remain present.

Every AWS family introduced here receives create, observe, recover, delete and credential-tail behavior in this phase. Ordinary delete removes deployment-owned SES and remote TLS/backing-store resources as well as networks. Quiesce local consumers of deleted cloud DNS/SES credentials; report their inactive cloud-dependent features rather than claiming the public edge stayed healthy.

**Validate:** independent public DNS and TLS verification with hostname/issuer checks, actual login/token/API/websocket behavior, real invitation/SES receipt flow, user revocation, failed issuance, lost replies and restored material. Delete and independently verify managed records/SES/S3/IAM absence while externally owned zones/account remain. Reconcile again from retained control state and prove a new valid deployment. Use the real provider; a local mail or certificate fake does not qualify these claims.

For the optional remote-backup adapter, perform a real backup/read/restore round-trip, then ordinary delete and independent exact absence of its object versions, owned bucket and IAM material. Scope shared external buckets explicitly; remove only deployment-owned objects when the bucket is not owned.

**Remove:** old retained-SES exemptions, duplicate edge preparation, test-only credential shortcuts, scattered certificate/SMTP custody paths and separate cleanup wrappers for these families.

**Exit:** complete local public application and cloud-support lifecycle works without any EKS implementation.

### Phase 8 — EKS, static EBS, delegated DNS, and substrate parity

**Prerequisites:** Phase 7; actual EKS quotas and live budget. No new auth mechanism is introduced here.

**Deliver:** EKS/VPC/node-group/IAM/subzone adapters, static EBS with explicit data policy, registry mirror, AWS Load Balancer Controller, full platform/application projection, scoped EKS drain and controller-family cleanup. Retained local kind is the only lifecycle Authority. Use the existing real credential, operation, catalog and evidence implementations.

Observe exact EKS identity before deciding drain; do not infer it from unrelated stack presence. Record controller-created network families and certificate/DNS consumers before enabling them. Clean load balancers, CNI interfaces, security groups, NAT/endpoints, subnets and volumes through closed ownership rules and provider backstops. Pulumi may remain an implementation tool; its checkpoint is not resource truth.

**Validate:** actual EKS application/service parity, external DNS/TLS/auth behavior, static volume rebind and data semantics, interrupted create before checkpoint commit, late controller dependents, unavailable drain, stalled delete, wrong account/region and resumed deletion. Independently inventory all declared AWS families and verify default delete removes production-owned as well as test-owned volumes under the stated destructive contract. Verify local kind still handles status and subsequent reconcile. Complete the required repeated audit-clean create/delete cycles; no manual cleanup counts.

**Remove:** ordinary/new-deployment routes into the old EKS bespoke cascade, no-install AWS special executor, orphan-prone provider paths, stack/checkpoint-based absence, independent EBS reaper as a normal operator duty, old `nuke` cloud semantics and remaining public cascade flags/artifacts. Close these route removals here, not in a future generic qualification sprint. Any implementation still necessary exclusively for an original-install identity is inventoried under L18 and the fenced migration lane until Phase 10; do not delete it before import or cleanup resolves that identity.

**Exit:** ordinary `delete` fulfills its complete AWS contract across all supported resource families. Every ordinary new deployment uses the replacement routes publicly.

### Phase 9 — HA, federation, and recovery guarantees

**Prerequisites:** Phase 8 and its real running service set.

**Deliver:** retained gateway leader/emitter continuity and failover tests on multi-node kind and EKS; explicit federation register/status and child trust/custody/recovery; local backup restore and crash-recovery exercises for the remote backup adapter already delivered in Phase 7; worker/Authority crash, cancellation and concurrent command recovery. The management Authority remains local kind; federation does not silently create another writer for the same deployment. Any newly discovered owned resource family must add its own default-delete/read-back case before this phase closes; reliability work cannot create a cleanup exemption.

Use the same operation/resource model and bounded worker contracts. Validate physical worker settlement before successor effects; do not substitute wall-clock expiry for proof that an earlier worker cannot act. Prefer one well-defined local authority and Kubernetes/operation ownership over additional distributed consensus or trusted-time machinery unless a retained feature demonstrably requires it.

**Validate:** real node/Pod/process loss, network denial, held/delayed requests and response loss, concurrent duplicate submissions, restored retained state, federation child unavailable/unsealed states, replay/stale ownership rejection and independent absence of retired workers. A multi-node kind experiment proves container/node failure behavior, not independent physical-machine or availability-zone failure. EKS evidence must state which topology/failure domain it actually exercised.

**Remove:** the HA-RKE2-specific provisioner and its obsolete suite names after equivalent retained gateway assertions pass, duplicate federation/bootstrap lanes, dead protocol variants and formal models exclusive to removed topology. Preserve current models/regressions that still guard actual behavior.

**Exit:** each retained HA/federation/recovery claim has real fault evidence and its cleanup. This phase extends reliability claims without changing previous command semantics.

### Phase 10 — Existing-install migration, final removal, and cumulative regression

**Prerequisites:** Phase 9. All ordinary product journeys are already proven by their owning phases.

**Deliver:** the bounded supported upgrade/import for existing RKE2-era identities and storage, old-operation disposition, full operator migration guide, and deletion of remaining migration-only readers/routes/codecs after their actual obligations are resolved. Retain historical evidence needed to reproduce regressions without treating it as current qualification.

**Validate:** migrate a real disposable old-layout fixture through the public migration command: inventory, quiesce old writer, snapshot/verify data and ownership, restore kind with the same logical deployment scope, confirm new Authority, resume pending work, delete remote resources, and repeat no-op. Reject missing legacy evidence, wrong mounts, foreign owners and unsupported schema without inventing clean state. Run the entire public acceptance matrix for production semantics and isolated tests, including real AWS/public edge and concurrent production/test isolation. Complete repeated clean cycles and the declared soak budget; report their practical limits.

**Remove:** all remaining pending legacy rows, temporary aliases and importers whose supported migration window has ended, old RKE2 management implementation and unused generated artifacts. No phase-owned pending removals, unreachable public commands, fake-only product assertions, or unowned scratch/evidence obligations remain.

**Exit:** `test run all`, canonical `dev check`, the current critical mutation results and final acceptance evidence agree with active docs and generated help. Re-run the scoped critical catalog against the final implementation; no unresolved surviving critical case or invalid/inconclusive substitute can satisfy closure. This phase confirms/regresses the integrated product; it is not the first activation or first real proof of any earlier feature.

### 9.1 Deliberate scope reductions

The refactor preserves the microservices and operator capabilities above, but does not preserve every historic implementation choice:

- RKE2 is removed as the local control plane and as the special AWS HA validation substrate. Gateway HA objectives remain on kind/EKS.
- Account-wide destructive sweeps are not ordinary product features. Exact legacy recovery remains available; account-wide absence is never claimed.
- Sealed-Vault concealment of all lifecycle metadata is replaced by protected secret custody plus authenticated, useful non-secret lifecycle status.
- A required AWS Authority-backup bootstrap and a host management daemon are both excluded from the minimal kind control-plane design.
- Linux with the pinned container runtime is the supported host baseline for this refactor. Preserve platform-independent Haskell boundaries, but do not carry unvalidated macOS/Windows/VM provisioning as a mandatory hidden dependency. Existing portable-host objectives receive an explicit future-feature disposition in Phase 0, not a false support claim or silent deletion.
- Generic speculative ML/cache/autoscaling doctrine is not a new microservice requirement. Preserve actual resource-governance features and any implemented product objective identified by the inventory; classify the remaining speculative material explicitly.

Changing this scope after Phase 0 requires an explicit contract amendment and ownership update.

## 10. Make `legacy_tracking_for_deletion.md` executable ownership

Rename `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` to `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md` during Phase 0, including the checker, generated references and all incoming links. Keep one ledger. Preserve useful completed history through Git and a compact historical reference; do not carry hundreds of completed rows into the working queue.

Each active row has stable ID, exact locations/symbols/artifacts, reason, replacement, numerical remover phase, prior/current prerequisites, required behavior/evidence before deletion, absence check, and state. Proposed states are `Pending`, `Ready`, and `Removed`. `Removed` requires both the replacement's acceptance and absence of the old active route; source search alone cannot prove safe replacement.

The owner is the phase that **removes** the item, not the phase that wrote its replacement. Its prerequisites cannot name later phases. Split a row if different parts have different removal conditions. The checker rejects an absent owner, unknown phase, larger-phase prerequisite, removed row with live callers, or Complete phase that owns a pending row.

### 10.1 Seed removal assignments

Expand these families to concrete rows during Phase 0; this table does not replace the required audit of every existing pending/unowned row.

| ID | Legacy family / representative location | Remover | Required removal proof |
|---|---|---:|---|
| L01 | Old phase/status grammar and hardcoded filenames in `CheckCode.hs` | 0 | New checker accepts valid plan and rejects planted invalid dependency/status/ownership cases |
| L02 | Giant active status diaries, duplicate current-state narratives and superseded doctrine owners | 0 | Requirements/evidence mapped, links repaired, one short authoritative queue |
| L03 | Hyphenated legacy ledger name and all parser/link assumptions | 0 | One snake_case ledger, zero active old-path references |
| L04 | Ambient/duplicated context selection and new-harness production sibling rewriting | 1 | Real prod/test isolation and explicit config selection |
| L05 | RKE2-specific new-install host adapter and node-path assumptions | 1 | Real kind recreation proves host persistence and correct root identity |
| L06 | Registry-dependent Vault/MinIO/Broker bootstrap | 2 | Bootstrap/recovery succeeds with registry unavailable |
| L07 | Broker-readiness prerequisite for status; implicit test/production unlock fallback | 2 | Real degraded status and two distinct unlock policies |
| L08 | New-deployment local/no-install bespoke lifecycle funnel and inferred target choice | 3 | New public no-op/recovery/control-removal acceptance passes |
| L09 | `--cascade` in new public parser/help/completions/goldens | 3 | Ordinary delete contract passes for admitted new capabilities; remaining legacy cleanup uses only explicit migration lane |
| L10 | Duplicate setup/test credential ingress, shared broad operational auth and fixture copying | 4 | Real common prompt/fixture→IAM→Vault→use→retire path |
| L11 | First migrated test/S3 family's old provider and cleanup dispatch | 5 | Real partial-create/resume/delete and residue negative control |
| L12 | Duplicate local service catalog/chart renderers and gateway secret/authority fallback | 6 | Real canonical local service and messaging/persistence cases |
| L13 | Retained-SES/cloud-store exemptions and duplicate edge/invite preparation | 7 | Real DNS/TLS/SES/user checks and complete owned-family cleanup |
| L14 | Ordinary/new-deployment routes into bespoke AWS cascade/no-install executors and checkpoint-as-resource-truth gates | 8 | Complete EKS/network/EBS/default-delete acceptance; exact original-install-only residue separately enumerated in L18 |
| L15 | Normal-operation EBS reaper/network purge duties and old `nuke` cloud path | 8 | Common deletion handles all owned families; advanced recovery is exact and independently validated |
| L16 | Duplicate aggregate/integration setup/cleanup and old test command dispatch | 8 | Every old suite assertion mapped; one real runner and per-family cleanup |
| L17 | HA-RKE2 provisioner/suite, obsolete federation/worker protocol variants | 9 | Preserved HA/federation objectives pass on actual supported targets |
| L18 | Old RKE2 management importer/cleanup lane and retained-layout readers | 10 | Existing-install migration passed; all actual old operations/resources have disposition |
| L19 | Temporary compatibility routes/codecs and final legacy escape registry | 10 | No active caller/old owned deployment needs them; replacement regressions pass |
| L20 | Non-versioned scratch/evidence aliases still needed for historical regressions | 10 | Needed inputs retained in verifiable evidence manifest; temporary duplicates retired without losing reproducibility |

Do not move an unresolved Phase 4 credential tail into Phase 10 merely to close Phase 4. Phase 10 owns actual migration-only residue, not unfinished ordinary functionality. If a supposedly migration-only component serves new ordinary operations, its row belongs to the phase that introduces those operations and must close there.

### 10.2 Agent execution contract after adoption

The root agent instructions should say:

```text
Read DEVELOPMENT_PLAN/README.md.
Select the first incomplete numerical phase.
Read its contract, tasks, acceptance cases and owned legacy rows.
Implement that public slice using completed earlier capabilities.
Run its real acceptance and cumulative regression set.
Run its critical source-mutation cases and verify the expected assertion failures.
Resolve every owned removal row and update docs.
Mark Complete only when its actual evidence, mutation gates and cleanup pass.
Continue with the next numerical phase.
```

A discovered future dependency triggers a phase-boundary correction before work continues; it does not create a secret queue or a decimal sprint elsewhere. An unavailable external prerequisite is reported as the named prerequisite, with work/evidence preserved. It is not rounded up to Complete and is not blamed on later unfinished product code.

## 11. Safe implementation and existing-install migration

This is a refactor plan, not permission to delete the currently mounted storage or reinitialize the observed Vault.

1. **Snapshot the baseline.** Capture current command/feature inventories, old deployment identities, state-root declarations, pending cleanup runs and resource ownership. Preserve required non-versioned inputs. Do not read secrets into the plan/evidence.
2. **Adopt the plan first.** Replace doctrines, checker grammar, queue and ownership maps in one reviewable documentation/tooling change. Do not make every runtime module follow a new naming layout in that change.
3. **Freeze new enrollment into the old topology.** Existing identities retain their exact supported cleanup/recovery capability until the corresponding new resource family and import are proven. A narrowly scoped `admin migration` lane may wrap existing cleanup for those identities; it is not a second writer or a generic fallback for new deployments.
4. **Ship new public slices in order.** New isolated kind deployments use the replacement as each phase closes. A capability not yet implemented is explicitly unavailable; no fake provider or private-only substitute supplies a successful result. Extend default delete with each newly admitted resource family in the same phase.
5. **Quiesce before import.** For an existing identity, stop new admission under the old writer, settle or explicitly retain its operations, verify storage/ownership and read back a backup. Establish the new kind store only from that exact scope. Do not run two Authorities against one scope or discard an unresolved old operation.
6. **Verify before switch.** Read back restored journal/checkpoints/Vault identity and the new caller, confirm old-writer rejection, then resume through the new engine. Record which steps are reversible. Once new effects occur, recover forward rather than resuming an old writer from stale state.
7. **Retire with the ledger.** Delete the old handler/modules/artifacts when their numerical removal condition passes. Do not retain an indefinite deprecated alias that still implements different deletion semantics.

For the current host's `.test-data/legacy-aggregate`/unlinked-mount situation, first establish the specific retained-root and deployment disposition. A new installation record cannot erase an existing deployment's unknown obligations. Migration must offer bounded exact inventory/adoption/recovery for the recorded scope. If required custody is irrecoverably lost, report that exact data-loss/recovery condition; do not initialize a replacement over it or claim AWS is empty from a blank Vault.

The migration lane is temporary and tracked from Phase 0. It avoids stranding existing resources while new adapters arrive; it does not defer activation of the new public paths until Phase 10.

## 12. Definition of the finished refactor

The refactor is complete when all of the following hold:

- A normal operator learns `config setup`, `control reconcile`, `reconcile`, `status`, and `delete`; no internal service-start sequence is required.
- `delete --yes` removes the selected deployment's owned AWS resources, including formerly exempt SES/EBS/state/IAM families, then updates local state. It preserves the working kind management plane.
- Repeating a completed delete prints “Nothing to delete” for its defined scope without unnecessary elevated credentials or Vault initialization.
- An initialized sealed Vault unlocks automatically when configured material is usable, or requests the needed input in the same operation. Status diagnoses it without requiring every other component healthy.
- Test self-unseal works from test MinIO, production refuses that policy, and elevated AWS test input follows the real ephemeral operator-simulation path.
- Concurrent production/test execution cannot cross roots, clusters, credentials, cloud ownership, or cleanup authority. Tests never rewrite the production config or sweep production resources.
- The canonical local and EKS application/service projection, public DNS/TLS/auth/email, gateway/Pulsar behavior, static storage and retained HA/federation features have real owned acceptance evidence.
- Every phase was validated using its real predecessors. The final campaign repeats those results; it does not conceal earlier incomplete composition behind a final green badge.
- Each phase's critical source mutations trigger the intended unchanged test assertions, with baseline/build/result evidence and reviewed equivalence exclusions. Compilation errors, unrelated timeouts, fabricated receipts and surviving critical faults cannot produce a passing mutation gate. Real-provider proof remains separately required on unmodified code.
- Every old command/option/objective has an explicit disposition, and every obsolete active path has its removal evidence. No pending/unowned legacy rows or contradictory active doctrines remain.
- `prodbox dev check`, the scenario registry, generated CLI artifacts and the numerical plan describe the same product.

No finite campaign guarantees the absence of all future defects. This plan changes the deliverable from accumulating individually correct mechanisms to repeatedly demonstrated public workflows, with explicit ownership, scoped evidence, and a tested recovery path for every supported failure condition.

## 13. Review sources

Repository sources reviewed include:

- [Current command registry](../../src/Prodbox/CLI/Spec.hs), [request types](../../src/Prodbox/CLI/Command.hs), [generated command inventory](../../documents/cli/commands.md), and [CLI doctrine](../../documents/engineering/cli_command_surface.md).
- [Current lifecycle executor](../../src/Prodbox/CLI/Rke2.hs), [residue observations](../../src/Prodbox/Lifecycle/LiveResidue.hs), [private replacement](../../src/Prodbox/Lifecycle/Teardown/CascadeCandidate/Internal.hs), and [host recovery boundary](../../src/Prodbox/Lifecycle/HostCleanupRecoveryPlane.hs).
- [Vault commands](../../src/Prodbox/CLI/Vault.hs), [test routing](../../src/Prodbox/TestPlan.hs), and [doctrine/plan checker](../../src/Prodbox/CheckCode.hs).
- [Documentation standards](../../documents/documentation_standards.md), [plan standards](../../DEVELOPMENT_PLAN/development_plan_standards.md), [current plan](../../DEVELOPMENT_PLAN/README.md), [component inventory](../../DEVELOPMENT_PLAN/system-components.md), [substrate inventory](../../DEVELOPMENT_PLAN/substrates.md), and [active removal ledger](../../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md). The prior ledger is available at revision `583443f` as described in [history navigation](README.md).
- The July–November 2026 Git history, including `8bed066`, `f59ccfc`, `39f17be`, `5b8c730`, `b2e9bf6`, and `e21ed05`. Historical results identify the revisions they exercised, not this proposed replacement.

kind/Kubernetes implementation constraints were checked against primary documentation:

- [kind configuration](https://kind.sigs.k8s.io/docs/user/configuration/): host extra mounts, published ports, and local API configuration require explicit node configuration. Phase 1 validates these in the actual pinned build.
- [kind local registry](https://kind.sigs.k8s.io/docs/user/local-registry/): host and node loopback namespaces differ; a node registry mapping is necessary when retaining localhost-style image references. Phase 6 validates uncached pulls through the actual chosen mapping.
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/): policy objects require an enforcing network implementation. Phase 1 establishes real allow/deny enforcement, Phase 2 proves management-service policies, and Phase 6 extends this to application traffic; manifest acceptance never counts as enforcement.

The bounded, incremental mutation-testing approach is informed by [Practical Mutation Testing at Scale: A View from Google](https://research.google/pubs/practical-mutation-testing-at-scale-a-view-from-google/). That research supports filtering and incremental selection as cost controls; it does not establish prodbox's lifecycle correctness or replace the phase-specific evidence required here.
