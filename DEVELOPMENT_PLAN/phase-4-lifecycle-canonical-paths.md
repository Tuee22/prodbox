# Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Capture the lifecycle hardening work, Pulumi scope reduction, Python-removal
> work, and the CLI-doctrine adoption sprints that bring the local-cluster lifecycle and AWS
> validation surfaces in line with [> Reconcilers](../documents/engineering/README.md) and `Test Organization`.

## Phase Status

✅ **Reclosed 2026-08-23 on Sprint `4.90`.** Host and Pulumi Vault probes now project the
validated deployment context, retained lifecycle resolution compares exact cluster/Vault identity
before any effect, lower gates consume sealed Tier-0 basics, and every state-store consumer imports
the one generic bucket identity. The duplicate defaults and production endpoint-changing test
environment seams are deleted. Code-owned validation is green; Standard-P deployment
qualification remains pending and non-blocking.

🔄 **Configuration-ownership expansion registered 2026-08-22 as Sprint `4.90` (Standards A/N).**
Host and lifecycle paths independently choose cluster, Vault, and object-store coordinates instead
of consuming the context they seal. This phase owns those capability consumers and the collapse of
duplicate state-bucket declarations; `4.90` follows Sprint `1.92`. The earlier teardown reopen and
its evidence remain unchanged; execution order lives in
[README.md → Resume Here](README.md#resume-here).

🔄 **Reopened 2026-08-15 on Sprints `4.84`–`4.86` (Standards A/L/P).** The pending live proof for
`4.82` falsified its composition claim: AWS returned one `ResourceTagMapping` for a retained S3
bucket with its full two-tag set; Prodbox's decoder emitted two internal rows, turned them into
“2 resource(s)” for each of three per-run stacks whose exact observations remained `Unobservable`,
and selected the AWS drain. No drain request reached
the Kubernetes API and no Pulumi destroy reached a provider effect. `4.84` is Active on the pure
exact-keyed registry and observation algebra; it has already replaced the former single
`aws-ebs-volumes :: LongLived` registry fact plus runtime-tag partition with distinct statically
classified test-scoped `PerRun` and production-retained `LongLived` EBS identities. At the paused
2026-08-16 checkpoint, `4.84`, `4.85`, and `4.86` all have dependency-safe implementation and are
Active: the exact algebra, descriptor-bound durable kernel, recovery plane, authenticated routes,
and bounded interpreters exist, while stable create generation, terminal audit, pre-uninstall
authority, two-phase host completion, total-decommission parity, and public-client cutover remain.
Checkpoint usability, exact provider truth, and escape-audit evidence remain separate. This changes
persistence/lifecycle/destructive cleanup, so both substrate qualification rows remain pending.
Their implementation status does not select the next work item: all three are parked behind Sprint
`3.41` by [README.md → Resume Here](README.md#resume-here).

✅ **Reclosed 2026-08-15 on Sprint `4.83`.** Every lifecycle Job and target-worker Pod now pulls a
declared `repository:tag`; the host-minted rollout identity is no longer consumed as a registry
coordinate. `ResolvedCustomImage` separately observes the OCI config digest, and the three runtime
observers compare Kubernetes `imageID` against that signed attestation identity rather than treating
their own Pod spec as evidence. The dormant Admin Action validator accepts the same declared-tag
contract, and the ownership check covers all four source regions.

✅ **Reclosed 2026-08-14 on Sprints `4.81` ✅ and `4.82` ✅ (Standards A/N).** The same-day
own-surface reopen on the residue-observation and destructive-cleanup paths this phase owns is
closed. The trigger was a doctrine gap rather than a new failure: [chaos_hardening_doctrine.md
§ 24](../documents/engineering/chaos_hardening_doctrine.md) (*an observation has a layer*, Sprint
`0.26`) requires a derived value to be enforced at the layer its source object is authoritative for,
and `ResidueStatus` — the common target of **nineteen** producers reading the Pulumi checkpoint
store, AWS resource presence, AWS IAM, AWS EBS, config text, a Pulsar topic, a Vault gate, an
object-store listing, SES consumer quiescence, and public-edge TLS — has no field in which to name
one. [Standard L](development_plan_standards.md#l-cli-doctrine-alignment)
makes scheduling that mandatory: "closing the gap silently without a sprint block is forbidden."

`4.81` made the layer sayable and its minting restricted — a field with a class-A opaque minter and a
mutation-proven `dev check` boundary, **not** a type index, because § 21 names *residue* explicitly
in its prohibition on indexing an observed value. `4.82` made the cascade consume the layer it
actually needs, using the admin credential the same command already loads for its postflight sweep,
and stopped one unobservable cause being narrated as two peer phase failures. The consequence they
existed to remove had been recorded in this plan's own prose since 2026-08-11 with no owner: the
per-run residue query observes the in-cluster Authority, authoritative for *what checkpoints this
cluster holds*, and the answer was consumed as *do these AWS resources exist*.

**One Standard-O live proof stays pending and does not gate closure**: `4.82`'s inverse-of-`4.76`
reproduction on a host whose API server is stopped. Both sprints move Standard-P
destructive-cleanup surfaces, so both substrate qualification rows remain `pending` and no
qualification identity captured before them survives.

Evidence: `prodbox dev check` exit 0, `prodbox test unit` exit 0 at main Hspec **3444** plus 27, 33,
and 27, and `prodbox test integration cli` **57/57**.

**Prior reclose — ✅ 2026-08-13 on Sprints `4.78`, `4.79`, and `4.80`.** The 2026-08-11 own-surface
reopen on the observation-producer and destructive-cleanup surfaces closed, taking this phase's last
three unowned `Pending Removal` rows. **Prior reclose — ✅ 2026-08-10 on Sprints `4.73`–`4.75`.** The
2026-08-09 own-surface reopen closed: **no `Pending Removal` row on a Phase-`4` surface was unowned
any more**, which was the condition that reopen existed to remove. Sprints `4.62`–`4.80` are all ✅
**Done** on their code-owned surfaces.

The closing three are worth reading together, because each answers a row that had been deferred with
a stated reason and each found the row understated itself.

- Sprint `4.73` ✅ routes the SES DNS writer through `DnsRecordProgram`, answering all three
  obstacles Sprint `4.72` measured. Its own finding: the lane needs **its own owner**, which the row
  did not say — sharing `AwsLifecycleProviderDnsOwner` would have classified retained-zone records
  as `PerRun` and handed the public A-record writer TXT/CNAME/MX authority over the same zone.
- Sprint `4.74` ✅ gives the Vault CAS seam the vocabulary the object-store seam has had since
  `ModelBCasResult`. Its row named three files against **ten call sites**, and said no caller made
  the distinction when **four made it wrongly** — one of them spending an authority-epoch retry on a
  refused request, another reporting a write that never happened as a replay conflict.
- Sprint `4.75` ✅ takes ownership of the one row that **cannot** be closed by code and corrects the
  false claim it rested on: `rawServiceTimeMicros`'s haddock said the value was measured while its
  only producer authors it, and `dhall/capacity/measured/` holds no committed profile for any lane.

**One row remains in `Pending Removal` on this phase's surface and it is owned, not unowned.** The
authored control-plane service time needs a recorded profile, which is a Standard-O recorder axis
rather than sprint-owned code work
([development_plan_standards.md § O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)),
so it does not hold the phase open. Deployment qualification stays `pending` on both substrates.

### Prior reopen (2026-08-09), closed by the above

Sprints `4.62`–`4.66` close the same defect shape at five layers — **a value the code already had and
then did not use** — and three of them corrected their own ledger row against source.

- Sprint `4.62` ✅ binds the target-sink CAS verdict; its row called the defect hygiene and the
  mutation exercise showed a refused write being recorded as `TargetCommitRunCommitted`.
- Sprint `4.63` ✅ decides the **global** ledger's CAS verdict at all four call sites the row said was
  one. `ModelBCasRefusedCorrupt` refuses — every producer of it refuses *before* the object store, so
  it is the one arm stating no write happened — while `Unobservable` deliberately stays on the
  read-back path. A second defect fell out: a refusal used to consume a compaction retry and surface
  as `TargetCommitCompactionOverBound`, a capacity bound named as the cause of a refusal.
- Sprint `4.64` ✅ makes the admission reset Sprint `4.61` fixed by hand **unnameable**: `noAdmissions`
  is package-internal, `runFirstAnchoredStepOrder` is the sole entry point that starts empty, and the
  existing `dev check` allowlist bars the way around it.
- Sprint `4.65` ✅ gives a refusal back its reason. Its row's stated evidence was false twice over —
  it named a module that has never existed and a mechanism `dev check` forbids — and it was filed
  against the wrong file.
- Sprint `4.66` ✅ stops the control plane writing `HTTP/1.1 403 Status`. This one was **live**, and
  the row understated it three ways: the unmapped set is `{401, 403, 408, 410}` not `{401, 403}`, 17
  sites not 9, and 338 literals not 47.

**Everything that reopen listed as remaining is now closed.** The unbounded control-plane accept
loop went to Sprint `4.68`; the producer-side `ReplyStatus` migration to `4.67`; the two untyped
Route 53 writers in `ProviderProduction.hs` to `4.72` and `4.73`; the
`TargetSinkCasRequest`/`TargetSinkRecord` constructor exports to `4.70`; the non-CAS
`vaultKvWriteV2` export to `4.71`; and the discarded final-slice admission set to `4.69`. The two
residuals `4.68` and `4.71` registered while doing that work went to `4.75` and `4.74`.

✅ **Reclosed 2026-08-08 on Sprint `4.61`** — a second own-surface reopen the same day, closed the
same day. Phase `5`'s Sprint `5.31` made a discarded refusal speak, and the sentence it produced
named a Phase-`4` defect: `runAnchoredStepOrder` reset its admission set at every phase boundary, so
a component whose readiness step is anchored in an earlier phase than its dependant's mutation step
was refused unconditionally — `never observed ready in this run` said of a component observed ready
earlier in that same run. Admissions are now threaded across the phases; staleness still expires and
re-observes, so what widened is which evidence counts, not how long evidence lasts. A gate holding
the threading is owed and is registered rather than claimed.

✅ **Reclosed 2026-08-08 on Sprint `4.60`**, which gave the control-plane server a response
obligation. `runControlPlaneServer` used to discard `forkFinally`'s `Either SomeException ()` with
`const`, so any throw from the request read, the readiness resolver, or `interpreterHandle` closed
the socket with zero bytes and no `500` — a known answer rendered indistinguishable from a network
fault, which is the *Distinguishability* class committed at a conversion boundary
([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md), landed by
governance Sprint `0.25`). The Bootstrap Broker had mapped an interpreter failure to a `500` since
Sprint `2.33`; `Prodbox.Http.ResponseObligation` now serves both, and is the only module in the
governed set permitted to import `Network.Socket.ByteString`. The reopen expanded this phase's own
owned surface only (Standard A) and moved no Standard-P production-composition surface. Prior
reclosures stand.

✅ **Reclosed 2026-08-08 on Sprint `4.59`** — the 2026-08-05 own-surface reopen closes; Sprints
`4.55`, `4.56`, and `4.59` are all Done on their code-owned surfaces and Phase `4` has no open
sprints. `4.55` moved every control-plane role's readiness off the kubelet request path: the seam is
now `STM`-typed cached facts, so a signed S3 LIST, a Vault read, or an `aws sts get-caller-identity`
subprocess behind readiness does not type-check, and the `m Bool` seam is deleted. `4.56` stopped
the repository minting an admission ticket and discarding it one line later — a mutating reconcile
step now takes a `MutationAdmission` it cannot be invoked without, re-validated against a bound read
from the graph. `4.59` deleted the superseded in-controller Target Agent write lane and the
`TrustedTargetSink` CAS half it existed to serve. Each corrected sprint text that was false against
source: `4.55`'s per-role backend-call counts were wrong for all five roles, and `4.59`'s
implementation list named two deletions the compiler and this plan's own ledger both refused. No
prior closure on this phase was falsified.

✅ **Reclosed 2026-08-04 on Sprint `4.54`** — own-surface reopen (Standard A/N) repairing this
phase's own validation evidence. Sprint `4.53`'s Independent Validation cited a test module that
Sprint `4.50` had deleted, and the three endpoint-readiness classifier cases it rested on were never
committed in any revision — leaving the production-live phrase-to-constructor mapping covered only by
a constructor-name presence scan that cannot detect a wrong mapping. Coverage is restored on the
surviving seam (`test/unit/ModelBCasTransportAdapter.hs`, 19/19), and a mutation exercise proves the
suite fails closed on the exact bring-up-dual regression. Test-only; no production behaviour change.

✅ **Reclosed 2026-08-01 after Sprints `4.50` and `4.53`.** The typed endpoint-readiness
refinement now includes the opaque authenticated-S3 endpoint witness and the shallow shell probe is
deleted. The authority-epoch cutover is production-bound across retained Authority admission,
Broker/Target/Provider roles, TLS retention, native SES/Route53 reconciliation, encrypted EKS client
authentication, clean-install backup admission, and crash-safe decommission. Focused validation is
`prodbox test unit` (2972/2972 plus the dedicated 27/27 admission, 33/33 authentication, and 27/27
transport suites) and `prodbox dev check` exit 0. The attempted broad CLI integration run exposed
Phase-5-owned stale fake-runtime assumptions about filesystem config and removed transports; those
failures are not treated as Phase-4 production evidence under Standard N.

**Typed-readiness history (2026-07-30)** (own-surface,
Standard A): the host-direct object-store / lease path gains a distinct retryable endpoint-unready
state (`ModelBEndpointUnready` / `LeaseAuthorityEndpointUnready`) so a transient MinIO-endpoint blip is
retried within the lease budget rather than collapsed into terminal authority-loss. Phase 1 (read) and
1b (write) landed and are `dev check`-green; Phase 2 (deep-probe witness) is the remaining Standard-O
increment. See [Sprint 4.53](#sprint-453-typed-endpoint-readiness-for-the-host-direct-object-store--lease-path--done).

**Authority-cutover history:** Sprints `4.48` and `4.49` completed the
restart-resumable retained Lifecycle Authority, fenced target outbox, and substrate-local Target
Secret Agent foundations. Sprint `4.50` owns the versioned authority-epoch cutover and legacy-route
removal. Sprint `4.51` is ✅ Done — the durability index, the retained SES transport cutover, and
the durable generation-scoped SES-operation replay fold all landed (2026-07-27); end-to-end
host-PUT/daemon-GET byte compatibility and live AWS response-loss behavior remain non-blocking
Standard-O evidence. Sprint `4.52` is Done on observed-host refinement.
These are forward-only lifecycle expansions; Sprint `4.47` remains historical proof of the pure
lease and intent rules it actually implemented, not proof of the replacement topology.

✅ **Sprint `4.51` Foundation Epoch expansion completed.** Counterexample
`LCPC-2026-07-11` ([phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)) froze the
`F-SES` mechanism on this phase's retained-authority surface: the retained SES authority's Model-B
CAS objects (lease, intent, SMTP projection, fenced checkpoint) are custodied through the
gateway-backed adapter whose chart the restore cycle deletes before the SES preparation step, and a
seventy-minute account-wide lease is held across a synchronous HTTP bracket. Sprint `4.51` closes
the storage half of that class with durability-indexed coordinates and adapters, a host-direct
`ClusterRetained` retained authority store over the same sealed envelopes, and an `OperationRecord`
intent that makes lease release idempotent; the policy half (the harness postflight residue bypass)
is narrowed by Sprint `7.34` on the Phase `7` surface. Sprint `4.51` is the retained-SES subset of
the Sprint `4.50` gateway-route removal landing early — Sprint `4.50` owns the full removal
— and it adds no `Blocked by` edge onto the `4.48` → `4.50` chain. The Foundation Epoch (Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34`), adopted by Sprint `0.17`, is the
completed before Sprints `1.61` and `1.62` as an execution-priority decision; it introduced no
`Blocked by` edge onto the existing `1.61` → `8.12` chain ([README.md](README.md)).

✅ **Reclosed 2026-07-10 after desired-present long-lived reconciliation.** The lifecycle class of
`aws-ses` correctly prevents automatic destruction, but the audited registry and suite integration
mistook retention for ambient pre-existence: the managed-resource registry was effectively
destroy-only, missing-state repair collapsed AWS errors to absence, and concurrent retained
stack reconciles had no shared lease. Sprint `4.47` expands Phase `4`'s own reconciler surface to
model desired presence as well as desired absence, fail closed on unobservable state, and serialize
the retained SES repair/reconcile cycle. The supported `AwsSesStack` ensure composes those
primitives through a retained-authority lease, fixed-role bounded STS sessions, fenced encrypted
checkpoint, finite SMTP repair, and global target-intent materialization. The role is a registered
`Operational` resource deleted and re-observed before its trusted user. Evidence is warning-clean
build, focused lifecycle 78/78 plus role 9/9, full unit 1476/1476, and `prodbox dev check` exit 0.
Earlier lifecycle, encrypted-backend, and cleanup closures remain valid; live AWS exercise is a
non-blocking Standard-O axis.

✅ **Reclosed 2026-07-10 after the classifier follow-up** — Phase `4` expanded
its **own** reconcile-driver + registry-config surface
([Standard A/N](development_plan_standards.md#n-phase-independence-and-execution-order)). Sprint `4.43`
single-sourced the STEP narration and landed the deep registry→MinIO gate. Sprint `4.44` is Done:
the deterministic `registryConfigYaml` `unlines` renderer takes a required typed
`RegistryStorageBackend`, always renders its `RedirectPolicy` as `disable: true|false`, and the
canonical backend chooses `RedirectDisabled`. This changes neither managed-resource ownership nor
credential delivery. Sprint `4.45` is also Done: `nativeInstallStepOrder` is graph-derived, the
nested platform list is hoisted into three first-class steps, the compiled plan carries its
validated DAG and order, graph/phase/edge/inventory/readiness violations fail closed, and every
native component is bound to the Sprint `1.59` readiness seam. Sprint `4.46` delegates the Route 53,
Helm, and Harbor retry classifiers to the landed Phase-1 `1.57` shared base, closes the confirmed
Helm-DNS flake, and deletes all three transitional RKE2 lint allowances (unit 1276/1276; `dev check`
exit 0).
All earlier Phase `4` closures remain valid.

✅ **Reclosed 2026-07-06 for EffectDAG-driven reconcile ordering and deep readiness barriers** —
Phase `4` expanded its own local-cluster lifecycle surface with Sprint `4.43`
(✅ Done), the core of the bootstrap-readiness refactor
([bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md)).
Sprint `4.43` replaces the hand-written `runSequentially` bring-up list (and its parallel
hand-synced `renderNativeInstallPlan` STEP narration) with an ordering derived from the Sprint
`1.56` component dependency/readiness graph, adds a **deep** registry→MinIO S3 edge-readiness
barrier before the image-mirror step (a real S3 round-trip through the registry, not the
front-door `GET /v2/` proxy), and closes the retry-classifier hole so transient name-resolution
failures (`no such host` / `dial tcp` / `lookup`) are retryable. The two retired surfaces are
recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). Per Standard N it
depended forward only on the earlier-phase Sprint `1.56` (now ✅ Done); the live green `test all` is a
non-blocking Standard O `🧪 Live-proof: pending` axis. All earlier Phase `4` closures remain valid on
their owned surfaces.

✅ **Reclosed 2026-07-05 for daemon-mediated lifecycle bootstrap.** Sprint `4.42` is now ✅ Done on
Phase `4`'s lifecycle interpreter surface. `cluster reconcile` brings up bootstrap-readable MinIO,
Vault, Harbor/image mirroring, the RKE2 registry config, and the loopback-restricted gateway daemon
before posting root Vault init/unseal/reconcile through the daemon; `prodbox vault ...` lifecycle
commands prefer the daemon NodePort and refuse direct host fallback when the daemon is reachable but
returns an error. Sprint `7.30` has since moved the supported Pulumi object-store/residue path
behind the same daemon boundary; surviving direct host Vault/MinIO helpers are explicit
legacy/config/test seams in the cleanup ledger. Sprint `5.14` owns the canonical
no-legacy-transport regression proof. Validation: warning-clean build plus local unit,
CLI-integration, and env-integration gates listed in Sprint `4.42`.

✅ **Reclosed 2026-07-04 for host/RKE2 resource guardrails** — Phase `4` reopened to expand its
own local-cluster lifecycle surface with Sprint `4.41`, now ✅ Done on its code-owned surface.
`prodbox cluster reconcile` reconciles RKE2/kubelet resource reservations, eviction thresholds,
log/image garbage-collection limits, and a systemd resource-control drop-in from the validated
capacity plan, and refuses when observed host capacity is lower than the authored host declaration.
Earlier lifecycle, storage, and teardown closures remain valid; this work adds the runtime
enforcement ring beneath the Phase `1` resource schema and Phase `3` chart rendering. Validation:
warning-clean build, `prodbox test unit` 1167/1167, and `prodbox test integration cli` 40/40. Sprint
`5.13` has since added canonical-suite pod/quota/limit-range validation; the live over-limit pod /
host-availability proof remains a non-blocking Standard O live-proof axis.

✅ **Live-proven 2026-06-26 — the destructive `lifecycle` validation passes under the green home
`test all`.** The `lifecycle` named validation (`cluster delete` → `cluster reconcile` → `cluster
health`, with the suite's postflight per-run AWS destroy) passes `ExitSuccess` in the green home
`prodbox test all` (2026-06-26, 18/18; see [00-overview.md → Historical Alignment Record](00-overview.md#historical-alignment-record)), so Phase
4's Vault-before-MinIO reconcile, Model-B object-store, retained-storage topology, and idempotent
teardown surfaces are home-substrate live-proven. The teardown was also hardened this run to close a
non-functional race at the cluster-teardown boundary — an EKS-ENI-detachment wait plus idempotent
`vault unseal` retries so the reconcile→destroy path never strands a freshly-sealed Vault under host
memory pressure (see [README.md → Historical Closure Record](README.md#historical-closure-record)). The `--substrate aws` lifecycle axis stays
orthogonal ([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-09** — Phase 4 was reopened for Sprints `4.26`–`4.27` (design-intention
review: the destructive-command Plan/Apply gaps + the registry-name SSoT consolidation surfaced
against the lifecycle reconciliation surface); both have now landed. Sprint `4.26` ✅ routed
`prodbox rke2 delete` (default + cascade) and `prodbox nuke` through `runPlanWithOptions` so
`--dry-run` / `--plan-file` are honored on the destructive arms (fixing the audit's #1 bug — a
discarded `_planOptions` that silently destroyed), added the `checkPlanOptionsHonored` lint, derived
the default-delete sweep from `perRunManagedResources` (closing the `aws-eks-subzone` omission),
failed the nuke step-4 tag sweep closed, read `nukePlanFile`, wired `noLiveLongLivedPulumiStacks`
into the `aws teardown` preflight, and retired `categorizePulumiResidue` — all while preserving the
refuse-gate vs reconciler split ([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
The cascade order was left untouched (drain → destroys; `storage_lifecycle_doctrine.md` §5 was
already corrected in Sprint 0.9). Sprint `4.27` ✅ introduced the `StackDescriptor` SSoT (deriving the
per-run/long-lived name lists, CLI verbs, project dirs, and a generated registry-name↔CLI-command doc
section), wrapped the Route 53 capability-proof create→delete in `bracketOnError` (unregistered — no
steady state), generalized `iamCreateSiteViolations` → `awsCreateSiteViolations`, and renamed
`longLivedStackNames` → `longLivedResourceNames`. Validation at reclosure: `check-code` 0,
`test unit` 802, `integration cli` 35, `prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check`
0; the live destructive cascade is operator-driven. All earlier Phase 4 sprints (`4.1`–`4.25`) remain
`Done` on their owned surfaces.

The phase was previously reopened for Sprint `4.24`: the public-edge production certificate
joins the managed-resource registry as a `LongLived` resource (now `Done` on the code-owned
surface), and for Sprint `4.25`, which makes `prodbox rke2 delete` a no-op success when no RKE2
cluster is installed (`Done`).

✅ **Reclosed 2026-06-16 (Vault secret-management refactor)** — Phase 4 reopened for Sprints
`4.29` (Vault folded into the canonical cluster lifecycle — reconcile deploys/unseals, teardown
preserves the durable Vault PV) and `4.30` (MinIO opaque-object-ID metadata hardening + sealed-state
red-team). Sprints `4.29` through `4.33` are now `Done`; Sprint `4.33` closes the Haskell-side
sealed-state residue gate, redaction, and opaque-namespace audit surface.
**Extended 2026-06-13** with Sprint `4.31` (the unified deterministic
retained-storage topology — a machine-id-free `.data/<namespace>/<StatefulSet>/<replica>` layout
under one reconciler, with MinIO and `vscode` converted to StatefulSets), also now ✅ Done. All
earlier Phase 4 sprints remain `Done` on their owned surfaces; the authoritative reopen narration is
the [README.md → Historical Closure Record](README.md#historical-closure-record) entries of the same dates. Sprint `4.31`
refines the canonical retained-storage paths — it extends, it does not reverse, the Phase `3`
storage-binding model (Sprint `3.1`).

✅ **Finalized 2026-06-14 (Vault-root finalization + cluster federation)** — the secrets model is
finalized: Vault is the sole secrets/KMS/PKI root, the master-seed HMAC derivation model is retired
(not extended), `FileSecret` / Secret-mounted plaintext Dhall is removed (not bridged), and a sealed
Vault fail-closed-bricks the cluster. Sprints `4.29` and `4.30` are reframed to own that finalized
end state (no bridge; derivation retired), and Phase 4 is extended with Sprint `4.32` (federated
lifecycle reconcile — child clusters auto-unseal from their parent on the init-once /
unseal-on-rebuild contract, the fail-closed unseal cascade bricks a subtree when a parent is
sealed/unreachable, and root-config writes are gated on the root Vault token), now `Done`. The
federation trust topology this lifecycle wiring depends on is owned by Sprint `3.20` (Vault
transit-seal hierarchy) and the new
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). All
earlier Phase 4 sprints remain `Done` on their owned surfaces; the authoritative reopen narration is
the [README.md → Historical Closure Record](README.md#historical-closure-record) 2026-06-14 entry. Sprint `4.32` extends,
it does not reverse, the Sprint `4.29` retained-Vault-PV lifecycle and the Phase `3` storage-binding
model.

✅ **Refined 2026-06-15 and reclosed 2026-06-16 (Model B object-store + whole-system
zero-child-info)** — the MinIO/Pulumi
encryption strategy is finalized to **Model B**: prodbox owns one application-level Vault-Transit
envelope per object (not MinIO bucket server-side encryption), and the fail-closed invariant is
recognized as a whole-system *existence/metadata* property spanning MinIO objects, the host disk,
Kubernetes objects, and logs/output. Sprint `4.30` closed on 2026-06-16 with the **Model B
object-store** — `Prodbox.Minio.ObjectStore` + `Prodbox.Minio.EncryptedObject`
(Vault-keyed-HMAC opaque IDs, the `prodbox-envelope-v2` hashed AAD, the encrypted index payload
shape, and decoy key pool), the `prodbox-state` generic bucket, and the in-force-config read routed
through the opaque object key. Phase 4 is extended with Sprint `4.33` (whole-system
sealed-state scrub of the on-disk, Kubernetes, and log surfaces — residue-query gating behind the
Vault-readiness check, redaction, opaque k8s namespaces, and the cross-surface red-team), now `✅
Done` on its code-owned Haskell surface. Sprint `4.32` (federation) owns the parent-side live child registration writer and child
Vault lifecycle interpreter that consume the downstream-identity-to-Vault-KV custody foundation;
Sprint `4.33` owns the Haskell-side opaque Kubernetes namespace, log, and sealed-state gate
enforcement. Live cross-surface sealed-Vault red-team validation remains Sprint `5.8`, and raw
Pulumi checkpoint decrypt-to-scratch interposition remains Sprint `7.14`.
This **refines, it does not reverse**, the 2026-06-14
finalized model and reopens no new phase; the authoritative narration is the
[README.md → Historical Closure Record](README.md#historical-closure-record) 2026-06-15 entry, and the doctrine SSoT is
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store).
All earlier Phase 4 sprints remain `Done` on their owned surfaces.

✅ **Done (Sprints `4.1`–`4.23`)** — Sprints `4.1`–`4.4` remain `Done` on lifecycle parity, Python Pulumi removal,
repository-wide Python toolchain removal, and the single-record DNS / single-certificate
contract. The phase was first reopened by Sprint 0.2 to schedule Sprints `4.5`–`4.7`: rename
`prodbox rke2 install` → `prodbox rke2 reconcile` per doctrine, apply the Plan / Apply +
`--dry-run` discipline (Sprint 1.7) to the lifecycle reconcile, and migrate AWS-validation
infrastructure tests into a dedicated `prodbox-pulumi` cabal test stanza. Sprint `0.5` reopened
the phase again to schedule Sprint `4.8`, the `prodbox rke2 delete --yes` success-summary
hardening. Current worktree evidence closes Sprints `4.5`, `4.6`, `4.7`, and `4.8`:
`prodbox rke2 reconcile` is the canonical entrypoint, the deprecated `install` alias has been
removed, lifecycle forbidden sister commands are rejected at parse time, the lifecycle plan is
golden-covered, the dedicated `prodbox-pulumi` stanza proves the retained Pulumi-program
ownership, local ephemeral-stack harness, typed-output contract, and forced-failure cleanup, the
governed docs and validation call sites reference `reconcile`, and successful
`prodbox rke2 delete --yes` runs are hermetic for chatter on the uninstaller's own stdout/stderr,
which the lifecycle-local quiet path filters, while non-zero uninstall exits still surface
actionable upstream context. (The inotify warning `Failed to allocate directory watch: Too many
open files` is emitted out-of-band by systemd/journald to the console and is not capturable by the
quiet path, so it may still appear on a successful run; it is benign — see streaming_doctrine.md §6.)

✅ **Reclosed 2026-07-03 after the AWS EBS block-storage lifecycle reopen** — two new sprints
expanded Phase 4's own lifecycle/teardown surface (narrated in [README.md → Historical Closure Record](README.md#historical-closure-record) per
rule A). Sprint `4.39` is ✅ Done: the **pre-created EBS volume is a registered managed
resource** (typed `discover`/`destroy`, extending the Sprint `4.20`/`4.22` registry) with
retain-vs-test-scoped tag markers, so production EBS is retained on teardown exactly like `.data/`
and only test-scoped EBS is deletable. Sprint `4.40` is ✅ Done: the **suite postflight
test-EBS reaper** and the retain-safe drain so `Retain` EBS PVs survive teardown while test-scoped
volumes are reaped at suite exit — closing the EBS-leak class that motivated this work. Both extend,
and do not reverse, the Sprint `4.12` K8s-drain and the Sprint `4.20`/`4.24`
resource-lifecycle-class model; the AWS-side static-EBS PV renderer is Phase 7 (Sprint `7.28`) and
the identical-rebinding validation is Phase 5 (Sprint `5.12`). All earlier Phase 4 sprints remain
`Done`/as-tracked on their owned surfaces. The superseded dynamic-`gp2` path is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Phase Summary

Current Sprints `4.84`–`4.86` replace the global residue funnel with exact keyed observations,
statically lifecycle-classed resource identities (including separate test-scoped and retained EBS
families), total desired-absence programs, a lifecycle-owned durable graph, and a proof-carrying
recover-to-clean candidate. Sprint `4.86` implements and independently validates that replacement
only; Sprint `6.5` later owns public generic/home activation and legacy-route removal, while Sprint
`7.36` owns AWS-specific adapters.

This phase closes the hard migration gap between parity and replacement. It owns the
in-cluster-registry-first local lifecycle, the bounded public-image bootstrap doctrine, the public
AWS-validation Pulumi surface,
the non-Python Pulumi stack format, and the repository-wide Python removal that leaves the
supported path Haskell-only. Sprints `4.2` and `4.3` remain closed on the AWS-validation Pulumi
surface and repository-wide Python removal. Sprint `4.1`'s historical Harbor bootstrap was later
superseded by the `registry:2` runtime recorded below. The supported lifecycle and retained
AWS-validation stacks otherwise close on clean-room-only behavior, native-host-architecture Docker
publication, one Route 53 record, and one listener certificate for `test.resolvefintech.com`.
Sprint `4.8` closed the user-visible delete-output hardening: success is summary-owned by
`prodbox`, while failures keep actionable upstream context.

**May 24, 2026 — pure-Dhall config doctrine cross-reference**: Phase 4's lifecycle
reconciliation surface is unaffected by the new
[config_doctrine.md](../documents/engineering/config_doctrine.md). One interaction is
worth naming: under the new doctrine, daemon Pods auto-restart on boot-field config
changes (the file-watch worker drains and exits with `ExitSuccess`; the kubelet restarts
the Pod against the new Dhall). This means `prodbox cluster reconcile` runs that re-render
the gateway or workload ConfigMaps trigger a Pod restart without operator action, by
design — there is no separate "reload running daemons" step in the cascade. See
[Sprint 2.21](phase-2-gateway-dns.md) for the implementation.

**2026-07-06 — in-cluster registry swapped from Harbor to single-binary `registry:2`**:
The multi-pod Harbor Helm stack (core/nginx/portal/jobservice/bundled-postgres/bundled-redis,
installed via `helm upgrade --install harbor harbor/harbor`) is replaced by one `registry:2`
(CNCF distribution) Deployment plus a NodePort Service (nodePort `30080`) plus a `config.yml`
ConfigMap, all applied with `kubectl apply` (no Helm); on reconcile any legacy Harbor Helm
release was best-effort `helm uninstall`ed first at that revision. Reopened Sprint `4.50` replaces
that always-success compatibility helper with registered absence/read-back. The durable MinIO/S3 storage backend is
**retained unchanged** — the registry keeps blobs in the existing `prodbox-harbor-registry`
bucket via `registry:2`'s native S3 driver + the `harbor-registry-s3` Secret (`envFrom`), and
the MinIO→registry circular-dependency ordering (MinIO public bootstrap → registry → mirror →
MinIO steady-state) is unchanged. Push is now **anonymous over HTTP**: no `docker login`, no
published default admin credential, no TLS, and no projects REST API (repos auto-create on first
push). Registry readiness is a plain `GET /v2/` probe on `127.0.0.1:30080` (expect 200/401)
with the same six-consecutive-rounds stability contract before image writes — the old Harbor
nginx `/readyz` readiness patch is gone. The registry has no web UI, so the OIDC-gated
`/harbor` public-edge admin route (`PublicRouteHarbor`, its `HTTPRoute`, the `harbor-oidc`
`SecurityPolicy`, and the `harbor-oidc-client` secret) is removed entirely; only the MinIO
console `/minio` admin route remains, and `admin-routes` now asserts only that route. The
canonical `127.0.0.1:30080/prodbox/<repo>:<tag>` image-ref scheme, the RKE2 `registries.yaml`
mirror, the mirror/publish pipeline, and the union-runtime build are all unchanged. For
continuity the Kubernetes namespace and front-door Service stay named `harbor`, and internal
identifiers (`harbor-registry-s3`, `prodbox-harbor-registry`, `ensureHarborRegistryRuntime`)
keep the historical `harbor` name; the namespace was **not** renamed. Doctrine SSoT is
[local_registry_pipeline.md](../documents/engineering/local_registry_pipeline.md).

**Independent Validation** (development_plan_standards.md Standard N): Phase 4 is
validatable on its owned surface — the local-cluster lifecycle reconcile/delete paths,
the Pulumi-decoupling and Python-removal surfaces, and the destructive Plan/Apply gates —
without depending on any later phase. Lifecycle, refuse-path, cascade-order, and tag-sweep
logic are exercised on the home/local substrate (with the per-run Pulumi state backend,
AWS substrate stacks, and live tag-sweep against fakes or stubs where a later phase owns
the live dependency) via `prodbox dev check`, `prodbox test unit`, and
`prodbox test integration cli`/`lifecycle`. Per Standard O, each sprint's code-owned
closure rests on those local validations; proofs that need live AWS spend, a deployed
cluster, or an unsealed Vault are tracked as non-blocking `Live-proof: pending` notes and
never gate this phase or an earlier one. AWS-substrate coverage of the same validations is
orthogonal and tracked only in [substrates.md](substrates.md)'s parity table.

## Current Pre-Cutover Baseline In Worktree

These bullets describe the active implementation that the reopened sprints migrate. In particular,
daemon object-store authority is not target architecture.

- The public local-lifecycle surface is `prodbox cluster ...`, implemented behind the retained
  internal `src/Prodbox/CLI/Rke2.hs` module name. `cluster delete` is a pure local uninstall by
  default; `cluster delete --cascade` drains Kubernetes, reconciles registered per-run resources
  absent, uninstalls the cluster, and runs the postflight tag sweep.
- `Prodbox.Lifecycle.ResourceRegistry` is the typed inventory for creatable resources and
  `reconcileAbsent` owns idempotent teardown by lifecycle class. Sprint `4.47` implements the
  independent `desiredPresentManagedResources` projection, registered ensure command/interpreter,
  and `Prodbox.Lifecycle.DesiredPresence` planner/interpreter; the supported `aws-ses` path consumes
  it through the bounded lease/session/intent/repair transaction.
- The public IaC surface is `prodbox aws stack <stack> reconcile|destroy --yes`, implemented behind
  the retained internal `src/Prodbox/CLI/Pulumi.hs` name. The four registered stack programs are
  `aws-eks`, `aws-eks-subzone`, `aws-test`, and `aws-ses`; local cluster/platform ownership
  does not use a root Pulumi project.
- Main Pulumi checkpoint reads and writes use the encrypted Model-B wrapper and the daemon
  object-store boundary. Stack outputs are observed authoritatively; EKS kubeconfig and HA-RKE2 SSH
  material are bracketed in scoped temporary files. No supported stack snapshot, kubeconfig, SSH
  key, or chart-secret path writes under `.prodbox-state/`.
- The in-cluster registry is a single `registry:2` Deployment and NodePort Service in the
  historically named `harbor` namespace. MinIO supplies its S3-compatible storage, and the
  lifecycle preserves the bounded public-image bootstrap exception needed to establish that
  registry before steady-state image publication.
- AWS provider credentials resolve through typed Vault references; elevated/admin credentials enter
  supported operator flows only through `SecretRef.Prompt`, with the test harness simulation
  confined to `test-secrets.dhall`.
- Python source, tests, packaging, type stubs, Pulumi programs, and bridge modules are absent from
  the supported repository path.

## Sprint 4.1: Lifecycle Parity and Canonical-Path Closure on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestRunner.hs`, `test/integration/CliSuite.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the lifecycle-critical surfaces Haskell-only and close the Harbor-first cluster image
contract without reintroducing Python, duplicate runtime paths, or cross-arch container builds.

### Deliverables

- The supported local lifecycle path is Haskell-only.
- Harbor is installed and reconciled as the canonical local registry.
- Direct public-registry pulls occur only for Harbor and Harbor's storage backend before Harbor is
  healthy and externally serving.
- `prodbox` idempotently ensures required public images and all custom images are present in
  Harbor after Harbor bootstrap and before later Helm deployments run.
- Lifecycle-managed Haskell-build custom images stay single-stage `ubuntu:24.04`, install
  `ghcup` in-image, pin GHC `9.12.4`, and do not depend on mounted `haskell:9.6.7-slim`
  BuildKit contexts or symlinked Haskell tool shims.
- Supported custom-image publication uses ordinary host-native Docker builds and pushes rather
  than `docker buildx`.
- `amd64` hosts publish only `amd64` images, and `arm64` hosts publish only `arm64` images.
- Native `arm64` publication works on native `arm64` Docker daemons without requiring cross-arch
  emulation.
- Every later Helm deployment obtains its images from Harbor.
- Mixed-arch cluster closure and cross-arch manifest publication are unsupported on the canonical
  lifecycle path.
- Harbor mirror publication retries transient Harbor availability failures on the same candidate
  and then retries alternate configured upstreams when a preferred source still fails after
  manifest inspection.
- The explicit repo upgrade to GHC `9.12.4`, including required cabal-bound changes, closes with
  full canonical validation reruns on the upgraded toolchain path.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration lifecycle`
5. `prodbox rke2 delete --yes`
6. `prodbox rke2 reconcile`
7. `prodbox dns check`
8. `prodbox host public-edge`
9. `prodbox test integration all`
10. `prodbox test all`

### Current Validation State

- The authoritative lifecycle target keeps the supported split explicit: Harbor-storage-backend
  bootstrap first, Harbor install configured to use that backend plus readiness second, Harbor
  population and custom-image publication third, and later Harbor-backed platform and chart
  workloads afterward.
- `runNativeInstall` now deploys MinIO before Harbor, bootstraps the Harbor registry bucket plus
  credential secret through the supported public `quay.io/minio/*` storage-backend path, and
  reconciles Harbor with S3-backed `persistence.imageChartStorage` values before mirror, custom-
  image publication, or later Harbor-backed platform work continues.
- The shared Helm repo-update and upgrade/install helpers in `src/Prodbox/CLI/Rke2.hs` now retry
  transient upstream chart-fetch failures before surfacing a hard lifecycle failure, so the
  supported clean-room rerun can absorb intermittent upstream `5xx` and timeout errors.
- The Harbor readiness gate now requires both the external `/readyz` endpoint and the registry
  `/v2/` endpoint on `127.0.0.1:30080`, with six consecutive successful probe rounds before Docker
  login, mirror, or custom-image publication proceeds on a fresh cluster.
- `mirrorClusterImagesOnce` now reconciles the canonical required public images and any
  already-running non-Harbor cluster images into Harbor, selecting from configured candidate
  sources, retrying transient Harbor publication failures on the same candidate, and then
  retrying alternate upstreams when Harbor publication still fails after manifest inspection. The
  configured candidate set now includes `mirror.gcr.io` fallbacks for the Docker Hub-hosted
  Percona and Envoy images used by the supported lifecycle, so clean-room reruns can absorb
  unauthenticated Docker Hub rate limiting without leaving the Harbor-first doctrine.
- `ensureCustomImageVariants` keeps the custom Haskell images single-stage and now publishes only
  the native architecture of the host through ordinary `docker build` plus `docker push`.
- `ensureClusterPlatformRuntime` now reconciles the supported MetalLB, Envoy Gateway,
  cert-manager, ACME, and Percona operator surfaces directly with no retained cluster-migration
  cleanup shims for Traefik or the earlier incompatible operator surface.
- `supportedHostArchitecture`, `harborTargetAvailableForHostArchitecture`, and
  `pushDockerImageWithRetry` in `src/Prodbox/CLI/Rke2.hs` now detect the supported native host
  architecture, decide whether Harbor already has the required image, and publish or retry only
  that architecture before later chart work resumes.

### Remaining Work

None.

## Sprint 4.2: Replace Python Pulumi Programs with Non-Python Pulumi Definitions ✅

**Status**: Done
**Implementation**: `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `src/Prodbox/TestPlan.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`

### Objective

Retain Pulumi as the IaC engine for AWS substrate resources while removing Python and broad
local-cluster supported ownership from the public Pulumi path.

### Deliverables

- Supported Pulumi stack programs are non-Python.
- Haskell owns Pulumi stack selection, config rendering, output parsing, and failure reporting.
- The AWS substrate paths close through `prodbox aws stack ...`.
- Stack checkpoints use the encrypted Model-B object-store wrapper; EKS kubeconfig and HA-RKE2
  SSH material use scoped temporary files. The HA-RKE2 validation destroys and recreates
  `aws-test` once when Pulumi reconcile succeeds but SSH validation fails.
- No supported root `Pulumi.yaml`, `pulumi/home`, or broad local-cluster public operator flow
  depends on Pulumi.
- No supported Pulumi program depends on Python.

### Validation

1. `prodbox aws stack eks reconcile`
2. `prodbox aws stack eks destroy --yes`
3. `prodbox aws stack test reconcile`
4. `prodbox aws stack test destroy --yes`
5. `prodbox test integration pulumi`
6. `prodbox test integration aws-eks`
7. `prodbox test integration ha-rke2-aws`

### Current Validation State

- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the retained AWS IaC programs.
- `src/Prodbox/CLI/Pulumi.hs` no longer exposes `up|preview|destroy|refresh|stack-init` for local
  cluster ownership; the public `aws stack` surface is AWS-validation-only.
- `src/Prodbox/CLI/Rke2.hs` retains bootstrap DNS reconcile and ACME `ClusterIssuer` projection
  on the lifecycle path rather than on the public `prodbox aws stack ...` surface.
- The AWS substrate stack inputs are split by sensitivity: non-secret operator-CIDR and
  SSH-public-key values are synchronized through explicit Pulumi stack config written by the
  Haskell infra modules. The Tier-0 `aws.*` fields point at the registered Lifecycle-provider
  Target-Agent generation (`secret/aws/lifecycle-provider`), never plaintext. Current host
  plaintext materialization refuses; the surviving generic aggregate and legacy reader callers are
  Pending removal under Sprint `4.50`, while the fenced Provider Worker retains the role-specific
  credential. (Original framing read a stored provider credential and later used
  `secret/gateway/gateway/aws`; both are historical.)
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` read authoritative
  encrypted checkpoint outputs; the HA-RKE2 SSH key is bracketed in a scoped temporary file. Stale
  retained EC2 nodes are repaired by one destroy-and-recreate retry when SSH validation fails after
  a successful Pulumi reconcile.
- The retained AWS substrate stack helpers now write only the supported operator-CIDR and
  SSH-public-key inputs and no longer remove older Pulumi provider-key layouts on the supported
  path.

### Remaining Work

None.

## Sprint 4.3: Repository-Wide Python Toolchain Removal ✅

**Status**: Done
**Implementation**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `src/`, `test/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `prodbox.cabal`, `cabal.project`, `.gitignore`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/pure_fp_standards.md`, `documents/engineering/refactoring_patterns.md`

### Objective

Remove Python implementation and Python toolchain ownership from the repository once Haskell
parity exists.

### Deliverables

- Python source trees are deleted from the supported path.
- Python packaging metadata and Poetry ownership are removed.
- Python type stubs and pytest-specific harnesses are removed.
- `prodbox dev check` no longer shells out to Python-specific tooling.
- The Python-removal portion of the legacy ledger reaches zero pending items owned by this phase.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. Repository text-search proof shows that any remaining Python-era references are intentional and
   historical only.
4. Repository artifact-search proof shows that no supported-path Python implementation or Python
   toolchain artifacts remain.

### Current Validation State

- The repository no longer contains `src/prodbox/`, `tests/`, `typings/`, `pyproject.toml`,
  `poetry.toml`, `.python-version`, or any Python Pulumi program.
- `prodbox dev check` remains the canonical doctrine gate for this sprint.
- The repository search checks in this sprint remain explicit repo-review gates alongside the
  implemented `prodbox` command-surface validations.
- Root guidance docs and governed doctrine are aligned with the Haskell-only repository state.
- The Python-removal portion of
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is complete, and the ledger
  remains closed on Python-removal residue.

### Remaining Work

None.

## Sprint 4.4: Single-Record DNS Bootstrap and Single-Certificate Lifecycle Closure ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the lifecycle-owned bootstrap DNS and TLS surfaces on the one-host doctrine:
`test.resolvefintech.com`, one Route 53 record, and one certificate for all public or admin
routes behind Envoy.

### Deliverables

- Lifecycle-owned bootstrap DNS reconcile writes only the canonical `test.resolvefintech.com`
  record.
- Lifecycle-owned certificate projection and listener configuration require only one public
  certificate for the shared Envoy edge.
- No supported lifecycle path assumes dedicated identity, browser, API, or WebSocket hostnames.
- The Harbor-first lifecycle preserves Envoy, MetalLB, and cert-manager ownership while switching
  the public edge to the one-record or one-cert contract.

### Validation

1. `prodbox dev check`
2. `prodbox test integration lifecycle`
3. `prodbox rke2 reconcile`
4. `prodbox host public-edge`
5. `prodbox test integration public-dns`
6. `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` owns bootstrap DNS reconcile and ACME `ClusterIssuer` projection on
  the supported lifecycle path.
- Those helpers now write only the canonical `test.resolvefintech.com` record and keep the
  lifecycle-owned certificate contract on one public listener certificate for the shared Envoy
  edge.

### Remaining Work

None.

## Sprint 4.5: Rename `prodbox rke2 install` → `prodbox rke2 reconcile` ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/TestRunner.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/local_registry_pipeline.md`, `CLAUDE.md`, `README.md`, `AGENTS.md`

### Objective

Adopt [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command) on the canonical local-cluster lifecycle entrypoint.

### Deliverables

- Introduce `prodbox rke2 reconcile` as the canonical idempotent reconcile entrypoint that
  owns install, repair, and drift reconciliation on the supported self-managed cluster path.
- Remove the completed one-cycle `prodbox rke2 install` deprecation alias from the supported
  command surface and record the cleanup in the legacy ledger.
- Update CLAUDE.md, root `README.md`, AGENTS.md, governed engineering docs, Pulumi
  orchestration call sites, integration tests, and any documentation referencing the old name.
- Sprint 0.4 round-3 extension: apply the same forbidden-flag and
  sister-command discipline to the lifecycle reconciler per
  [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command). `prodbox rke2 reconcile` refuses
  the literal flag names `--force` and `--reinstall` at parse time; no
  `prodbox rke2 install`, `prodbox rke2 upgrade`, `prodbox rke2 repair`, or
  `prodbox rke2 force-install` sister command is added. A `prodbox-unit` parser test asserts the
  rejection for both `install` and `reconcile`.

### Validation

1. `prodbox rke2 reconcile` is fully idempotent across repeated runs.
2. `prodbox rke2 install` is rejected at parse time as a forbidden sister command after the
   completed one-cycle compatibility window.
3. No supported-path documentation refers to `install` as a supported command after the alias
   cleanup.

### Remaining Work

None.

## Sprint 4.6: Lifecycle Plan / Apply + --dry-run ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Rke2.hs`
**Docs to update**: `documents/engineering/local_registry_pipeline.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Apply [pure_fp_standards.md#8-plan--apply](../documents/engineering/pure_fp_standards.md#8-plan--apply) (Sprint 1.7) to the
lifecycle reconcile.

### Deliverables

- `prodbox rke2 reconcile --dry-run` renders the full subprocess, Helm, Pulumi, and Kubernetes
  plan and exits `0` without mutation.
- Each existing reconcile step under `src/Prodbox/CLI/Rke2.hs` adopts the doctrine's
  check-before-mutate shape literally.

### Validation

1. Golden tests cover the rendered lifecycle plan.
2. Re-running `prodbox rke2 reconcile` after a successful run performs zero mutating work.

### Remaining Work

None.

## Sprint 4.7: prodbox-pulumi Test Stanza ✅

**Status**: Done
**Implementation**: `prodbox.cabal`, `test/pulumi/Main.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_test_environment.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [unit_testing_policy.md#pulumi-orchestrated-infrastructure-tests](../documents/engineering/unit_testing_policy.md#pulumi-orchestrated-infrastructure-tests) and `Test Organization`.

### Deliverables

- New `test-suite prodbox-pulumi` stanza with `type: exitcode-stdio-1.0`. Move the AWS-IaC
  validation flows (`aws-eks`, `aws-test`, HA-RKE2) into the stanza. Each run uses an
  isolated ephemeral stack, generates a unique stack name, and tears down via `bracket` /
  `finally`.
- Pulumi outputs flow as the typed contract between provisioning and test execution.

### Validation

1. `cabal test prodbox-pulumi` provisions, tests, and tears down successfully.
2. No leaked stacks survive a failing run; `bracket` cleanup is verified by a forced-failure
   test.

### Current Validation State

- The `prodbox-pulumi` Cabal stanza now passes locally with the doctrine-owned ephemeral-stack
  harness: each test run creates isolated local stack state, round-trips typed outputs through
  the `EphemeralPulumiOutputs` contract, and proves forced-failure cleanup.
- The retained AWS test-stack destroy path now refreshes Pulumi state and retries destroy once
  before surfacing failure, matching the existing AWS EKS cleanup behavior and protecting
  `prodbox rke2 delete --yes` from stale-state teardown races.
- The live retained AWS IaC flows (`aws-eks`, `aws-test`, HA-RKE2) are covered by the named
  `prodbox test integration aws-eks`, `prodbox test integration pulumi`, and
  `prodbox test integration ha-rke2-aws` validations and by `prodbox test all`.

### Remaining Work

None.

## Sprint 4.8: Hermetic `rke2 delete` Success Reporting ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Subprocess.hs`,
`test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Harden the successful `prodbox rke2 delete --yes` operator surface so it matches
[Output Rules](../documents/engineering/streaming_doctrine.md#8-output-rules) and
[Reconcilers: Idempotent Mutation as a Single
Command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command):
`prodbox` owns the success summary, while hard failures preserve actionable upstream context.

### Deliverables

- `deleteRke2ClusterSubstrate` captures the upstream uninstall-script stdout/stderr through a
  lifecycle-local quiet path rather than relying on generic subprocess streaming. The change is
  scoped to `prodbox rke2 delete --yes`; it does not broaden into repo-wide stderr suppression.
- When `/usr/local/bin/rke2-uninstall.sh` exits `0`, the user-visible delete output is hermetic:
  only the doctrine-owned summary lines remain (`Deleting local RKE2 environment...`, AWS destroy
  dispositions, `Local RKE2 substrate: cleanup complete`, kubeconfig disposition, retained-root
  notice).
- Benign upstream uninstall chatter on success that the uninstaller writes to its own stdout/stderr
  is classified as ignorable success-path noise and does not surface as an operator-visible
  red-herring error. The inotify warning `Failed to allocate directory watch: Too many open files`
  is emitted out-of-band by systemd/journald to the console, so the quiet path cannot suppress it
  and it may still appear on a successful run (benign — see streaming_doctrine.md §6).
- When the uninstall exits non-zero, `prodbox` still renders actionable failure context through the
  existing summarizer path rather than hiding the upstream failure.
- The fake uninstall harness in `test/integration/CliSuite.hs` gains both sides of the contract:
  a success case that emits the exact inotify warning and proves it is suppressed, and a failure
  case that proves non-ignorable lines still reach the user as a summarized error.
- The governed docs listed above update together, per
  [../documents/documentation_standards.md](../documents/documentation_standards.md):
  `cli_command_surface.md` states the hermetic success-summary contract,
  `streaming_doctrine.md` states the success-versus-failure output rule for noisy lifecycle
  subprocesses, and `storage_lifecycle_doctrine.md` records the cleanup-summary boundary on the
  destructive delete path.

### Validation

1. `prodbox dev check`
2. `prodbox test integration cli`
3. `prodbox test integration lifecycle`
4. `prodbox rke2 delete --yes`
5. `prodbox test all`

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` keeps `deleteRke2ClusterSubstrate` on the lifecycle-local quiet path
  (`captureToolOutput`) and `isIgnorableRke2DeleteNoiseLine` now classifies
  `Failed to allocate directory watch` and `Too many open files` as benign upstream chatter
  alongside the existing `Cannot find device`, `semodule: not found`, and timestamped
  `Cleanup completed successfully` lines.
- `test/integration/CliSuite.hs` exercises both sides of the hermetic contract: the existing
  success path now also proves the inotify warning is suppressed, and a new failure case proves
  actionable upstream context (`umount: ... target is busy`) reaches the operator while the benign
  chatter classes are filtered from the summary.
- `documents/engineering/cli_command_surface.md`,
  `documents/engineering/streaming_doctrine.md`, and
  `documents/engineering/storage_lifecycle_doctrine.md` describe the hermetic
  success-summary contract and the success-versus-failure output rule.

### Remaining Work

None.

## Sprint 4.10: Decouple Long-Lived Pulumi State Onto a Dedicated S3 Bucket ✅

**Status**: Done on the Sprint-owned historical decoupling surface. Sprint `4.10` moved
`aws-ses` off operational `aws.*` credentials and introduced the retained
`pulumi_state_backend` S3 bucket so the long-lived class was no longer tied to the in-cluster
MinIO lifetime. Retry 21's live exercise ran with `aws-ses` on that long-lived S3 backend while
per-run stacks stayed on MinIO, and both substrate-stack discovery paths reported correctly through
`Prodbox.Lifecycle.LiveResidue`. As of Sprint `7.14`, Pulumi checkpoints for both classes are
superseded by the encrypted Model-B decrypt-to-scratch wrapper; the S3 bucket remains retained for
public-edge TLS material and as an optional first-touch import/delete source for old `aws-ses`
checkpoints. The historical `loadAdminAwsCredentials` helper in
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` and `pulumiSesAdminBaseEnv` in
`src/Prodbox/Infra/AwsSesStack.hs` read a stored admin block; under the corrected model
(scheduled as [Sprint 7.16](phase-7-aws-substrate-foundations.md)) `ensureAwsSesStackResources` +
`destroyAwsSesStackStatus` acquire their elevated/admin credential through the interactive
`SecretRef.Prompt` (the test harness simulating that prompt from `test-secrets.dhall`), not from a
stored config block. The Sprint `4.10` raw export/import migration body was
superseded by Sprint `7.14`'s encrypted-wrapper-backed first-touch migration command.
`destroyLongLivedPulumiStateBucket` helper added to support Sprint 4.13's nuke step 5.
**Implementation**: `prodbox-config-types.dhall` (already includes
`pulumi_state_backend` with `bucket_name`, `region`, `key_prefix`);
`prodbox-config.dhall` (already overrides
`bucket_name = "prodbox-pulumi-state-long-lived"`,
`region = "us-west-2"`, `key_prefix = "pulumi/"`);
`src/Prodbox/Settings.hs` (new `PulumiStateBackendSection` record with
prefix-stripping custom `FromDhall` instance; renderer + display
output); `src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new) exports
`longLivedPulumiBackendUrl`, `longLivedPulumiBackendUrlEither`,
`ensureLongLivedPulumiStateBucket` (idempotent: head-bucket; on miss
create with versioning, AES256 SSE, block-public-access, prodbox
tags, 90-day non-current expiration lifecycle), and
`withLongLivedPulumiBackendEnv` (bracket sets `PULUMI_BACKEND_URL`,
restores prior value); `src/Prodbox/CLI/Command.hs`
(`PulumiAwsSesMigrateBackend PlanOptions`); `src/Prodbox/CLI/Spec.hs`
(parser + leaf for `pulumi aws-ses-migrate-backend`);
`src/Prodbox/CLI/Pulumi.hs` (handler dispatch);
`src/Prodbox/Infra/AwsSesStack.hs::migrateAwsSesStackBackend`
(TTY-gated scaffold; emits the migration runbook pending live closure);
`src/Prodbox/CLI/Interactive.hs::awsSesMigrateBackendGuard` (non-TTY
refusal with automation hint).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`substrates.md`](substrates.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../CLAUDE.md`](../CLAUDE.md)

### Objective

Move long-lived Pulumi state (today: `aws-ses`; tomorrow: any future
cross-substrate long-lived stack) out of the in-cluster MinIO backend and
into a dedicated AWS S3 bucket owned by the operator account, so the
long-lived class survives arbitrary `rke2 delete + rke2 reconcile` cycles
and operator-machine churn. Per-run stacks continue using the in-cluster
MinIO backend. The state-lifetime rule from
[lifecycle_reconciliation_doctrine.md → §2](../documents/engineering/lifecycle_reconciliation_doctrine.md)
becomes the implemented behaviour: state lifetime matches resource lifetime
per class.

### Deliverables

- `prodbox-config-types.dhall` exposes a new `PulumiStateBackend` record
  (`bucket_name : Text`, `region : Text`, `key_prefix : Text`) and a
  matching empty default. `prodbox-config.dhall` overrides
  `bucket_name = "prodbox-pulumi-state-long-lived"`,
  `region = "us-west-2"`, `key_prefix = "pulumi/"`.
- `src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new) exports
  `longLivedPulumiBackendUrl`, `ensureLongLivedPulumiStateBucket`
  (idempotent: head-bucket; on miss create with versioning, AES256 SSE,
  block-public-access, the prodbox tags, and a 90-day non-current-version
  expiration lifecycle rule), and
  `withLongLivedPulumiBackend` (bracket: ensures bucket, sets
  `PULUMI_BACKEND_URL`, runs action, restores env).
- `src/Prodbox/Aws.hs` routes long-lived stack names through the new
  module; per-run stacks continue using `MinioBackend`. The per-run vs
  long-lived partition stays sourced from `perRunStackNames` /
  `longLivedStackNames`.
- Long-lived stack operations acquire their elevated/admin credential through the interactive
  `SecretRef.Prompt` (the test harness simulating that prompt from `test-secrets.dhall`'s
  `aws_admin_for_test_simulation.*` fixture) rather than the operational `aws.*` credential. The
  operational `prodbox` IAM user — minted into Vault KV and referenced from
  `prodbox-config.dhall` only as a `SecretRef.Vault` value — is no longer granted retained-bucket
  state access. (Original framing read a stored admin block; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md).)
- `prodbox pulumi aws-ses-migrate-backend` was introduced as a TTY-gated migration command for the
  historical MinIO-to-S3 move. Sprint `7.14` later rewrote the compatibility path to run through
  `Prodbox.Pulumi.EncryptedBackend` and first-touch import/delete instead of raw export/import.
- `pulumi/aws-ses/Pulumi.yaml` recorded the historical backend URL for direct Pulumi compatibility.

### Validation

1. `prodbox dev check`
2. `prodbox test unit` covers the backend-URL renderer and the
   bucket-spec generator (pure logic).
3. Historical live proof: `aws-ses` remained readable across `rke2 delete` / `rke2 reconcile`
   while authenticated with admin credentials. Sprint `7.14` owns the current live first-touch
   encrypted migration/deletion proof.

### Current Validation State

Code framework landed May 21, 2026: `prodbox dev check` exits 0,
`prodbox test unit` (396/396, up from 387 by adding eight URL-renderer
+ error-rendering tests plus the `host public-edge --substrate aws`
test from Sprint 7.5.c.v.f); the pre-existing
`pulumi_state_backend` round-trip test failure cleared because
`PulumiStateBackendSection` is now a first-class Haskell record with
a custom `FromDhall` instance that strips the `psb` Haskell-side
prefix while keeping bare Dhall field names. `prodbox pulumi
aws-ses-migrate-backend --help` renders and the command refuses
non-TTY contexts via `awsSesMigrateBackendGuard`.

### Remaining Work

None for Sprint `4.10`. Current encrypted migration/deletion proof is owned by Sprint `7.14`.

Blocks Sprints `4.11`, `4.12`, `4.13`.

## Sprint 4.11: `rke2 delete` Refuse-Path and Predicate Library ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the cascade-with-live-per-run-stacks path was exercised end-to-end
("Per-run Pulumi destroys: running 3 destroy(s) against MinIO" during
suite preflight + "Per-run Pulumi destroys: running 2 destroy(s) against
MinIO" during postflight); the refuse-path was exercised in the
integration tests (`rke2 delete --yes refuses when the per-run Pulumi
state backend is unreachable` 28/28); the `--cascade` + `--allow-pulumi-
residue` mutual exclusion passed integration tests. Refuse-path +
`--cascade` entry point + predicate library + tag-sweep helpers landed
May 21, 2026; full predicate
inventory landed May 21, 2026 (`noLiveClusterTaggedAws` wraps
`TagSweep`; `noUndrainedK8sAwsResources` wraps the newly-exposed
`collectSurvivors` from `K8sDrain`; `noLiveOperationalIamUser` wraps
the new `operationalIamUserExists` helper in `src/Prodbox/Aws.hs`;
`noLeftoverDnsBootstrapRecords` wraps the new
`operationalBootstrapDnsRecordExists` helper). The `aws teardown`
reimplementation onto the new library is deliberately deferred —
the existing `checkPulumiResidueBeforeTeardown` +
`renderPulumiResidueRefusal` pair already implements the desired
runtime behavior, and switching the call site to
`checkAll [noLivePerRunPulumiStacks, noLiveLongLivedPulumiStacks]`
would require either (a) preserving the verbatim Sprint 7.7
refusal text via a fragile golden pin, or (b) changing the
operator-visible refusal text (which would need a Sprint 0.X
doctrine alignment). The library is wired and unit-tested by
label; consolidation behind `applyAwsTeardown` remains as a
clearly-scoped follow-up sub-sprint.
**Implementation**: `src/Prodbox/CLI/Command.hs` (new
`Rke2DeleteFlags` record); `src/Prodbox/CLI/Spec.hs`
(`rke2DeleteFlagsParser` enforces `--cascade` xor
`--allow-pulumi-residue` via the `flag' <|> flag' <|> pure` idiom;
new leaf options + examples); `src/Prodbox/Lifecycle/Preconditions.hs`
(new) exports `Precondition`, `StructuredError`, `checkAll`,
`renderPreconditionFailures`, `noLivePerRunPulumiStacks`,
`noLiveLongLivedPulumiStacks`; `src/Prodbox/Lifecycle/TagSweep.hs`
(new) exports `discoverClusterTaggedAwsResources` against the AWS
Resource Tagging API plus `renderTagSweepRefusal`;
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteWithResiduePolicy` opens
default-mode `rke2 delete` with `checkAll [noLivePerRunPulumiStacks]`
and `runNativeDeleteCascade` is the entry point for the cascade
orchestration (currently delegates to `runNativeDelete` with a
"K8s drain not yet implemented" warning until Sprint 4.12 lands).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../CLAUDE.md`](../CLAUDE.md), [`../documents/engineering/README.md`](../documents/engineering/README.md),
[`../README.md`](../README.md)

### Objective

Make orphaning per-run Pulumi-managed AWS resources structurally
impossible from `prodbox rke2 delete`. Introduce the positive-framed
`--cascade` "clean teardown" path that orchestrates per-run Pulumi
destroys, cluster uninstall, and a postflight tag sweep as one atomic
operator action. Generalize the Sprint `7.6` residue-check pattern into
a typed predicate library that excludes `aws-ses` from `rke2 delete`'s
scope (its state lives outside the cluster after Sprint `4.10`).

### Deliverables

- `src/Prodbox/Lifecycle/Preconditions.hs` (new) exports the named
  `Precondition` values from
  [lifecycle_reconciliation_doctrine.md → §4](../documents/engineering/lifecycle_reconciliation_doctrine.md):
  `noLivePerRunPulumiStacks`, `noLiveLongLivedPulumiStacks`,
  `noLiveClusterTaggedAws`, `noUndrainedK8sAwsResources`,
  `noLiveOperationalIamUser`, `noLeftoverDnsBootstrapRecords`. Each
  wraps one `discover` and returns `IO (Either StructuredError ())`.
  `checkAll :: [Precondition] -> IO (Either [StructuredError] ())`
  composes them.
- `src/Prodbox/Lifecycle/TagSweep.hs` (new) exports
  `discoverClusterTaggedAwsResources` against the AWS Resource Tagging
  API (Pulumi-tracked residue only in this sprint; full cluster-tag
  scan lands in Sprint `4.12`).
- `src/Prodbox/CLI/Rke2.hs` opens `prodbox rke2 delete` with
  `checkAll [noLivePerRunPulumiStacks]`. Adds the new flags
  `--cascade`, `--allow-pulumi-residue`, `--dry-run`, `--plan-file`.
  Mutual exclusion at parse time: `--cascade` and
  `--allow-pulumi-residue` cannot be combined. `--cascade`
  orchestrates per-run Pulumi destroys in canonical order
  (`aws-eks-subzone`, `aws-eks`, `aws-test`) + cluster uninstall +
  postflight tag sweep. The K8s drain phase is **not** part of this
  sprint; `--cascade` emits a "K8s drain not yet implemented" warning
  until Sprint `4.12` adds it.
- `prodbox aws teardown`'s existing predicates are reimplemented as
  composition of the new library (`noLivePerRunPulumiStacks <>
  noLiveLongLivedPulumiStacks`) so the Sprint `7.6`/`7.7` contract is
  preserved verbatim while the library is consolidated.

### Validation

1. `prodbox dev check`
2. `prodbox test unit` covers predicate composition, flag mutual
   exclusion, and refuse-path message rendering (pure logic).
3. `prodbox test integration cli` covers `--dry-run` / `--cascade
   --dry-run` snapshots.
4. `prodbox test integration aws-iam` (or new `lifecycle-cascade`)
   covers end-to-end refuse, then `--cascade`, then `rke2 reconcile`,
   then `pulumi aws-ses-resources` no-op-diff path against live AWS,
   including a scenario where `aws-ses` is live (must be ignored
   throughout) and per-run stacks are live (must be flagged in default
   mode and destroyed in `--cascade` mode).

### Current Validation State

Code framework landed May 21, 2026: `prodbox dev check` exits 0;
`prodbox test unit` (399/399, up from 396 by adding three new
`rke2 delete` parser tests covering the default, `--cascade`,
`--allow-pulumi-residue`, and mutual-exclusion paths). The new
help text + completions are regenerated via `prodbox dev docs generate`
and round-trip through `prodbox dev docs check` cleanly.

### Remaining Work

- Full predicate inventory (`noLiveClusterTaggedAws`,
  `noUndrainedK8sAwsResources`, `noLiveOperationalIamUser`,
  `noLeftoverDnsBootstrapRecords`) lands alongside Sprint 4.12's
  K8s drain phase because those discoverers need the same
  kubectl/aws-resourcegroups infrastructure.
- `prodbox aws teardown`'s existing residue predicates
  (`checkPulumiResidueBeforeTeardown` in `src/Prodbox/Aws.hs`) are
  not yet reimplemented as a composition of the new library; the
  refactor is straightforward (the existing function maps 1:1 onto
  `noLivePerRunPulumiStacks <> noLiveLongLivedPulumiStacks`) but
  the Sprint 7.7 contract must remain preserved verbatim, so the
  refactor is deferred to a follow-up sub-sprint that includes a
  golden-test pin on the rendered refusal text.
- `prodbox test integration aws-iam` (or a new `lifecycle-cascade`
  suite) exercising end-to-end refuse → `--cascade` → `rke2
  reconcile` → `pulumi aws-ses-resources` no-op-diff against live
  AWS — pending the live closure.
- Operator-facing strings in `src/Prodbox/CLI/Spec.hs` (`--cascade`
  / `--allow-pulumi-residue` flag-help, `rke2 delete` leaf
  description) currently leak Sprint identifiers; the doctrine
  alignment landed in
  [cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract),
  the implementation landed in Sprint `4.14` on May 21, 2026.

Blocks Sprints `4.12` and `4.13`.

## Sprint 4.12: K8s Drain Phase and Postflight Tag Sweep ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the per-run EKS drain executed against a live AWS EKS cluster
("Per-run EKS drain (cluster=aws-eks-test-cluster): deleting LoadBalancer
Services, ALB Ingresses, and Delete-reclaim PVCs..." → "Per-run EKS
drain complete; proceeding to `pulumi destroy`."), and the subsequent
per-run `pulumi destroy` succeeded without `DependencyViolation`. The
home-substrate `lifecycle` validation also exercised the drain skip-on-
unreachable path (`K8s drain skipped: Kubernetes API server not
reachable; nothing to drain. Proceeding...`). K8sDrain module +
cascade-wiring landed May 21, 2026;
TagSweep module already supports the full cluster-tag query through
the `kubernetes.io/cluster/<name>` filter family and the
`prodbox.io/managed-by` filter; Sprint 4.13's nuke step 4 is the
first wired caller of the postflight scan; cascade-postflight wiring
remains a follow-up because cascade runs with operational `aws.*`
which may not have `resourcegroupstaggingapi:GetResources` grants on
the compacted Sprint 7.5.c.v.d policy.
**Implementation**: `src/Prodbox/Lifecycle/K8sDrain.hs` (new) exports
`K8sDrainEnv`, `DrainTimeout`, `DrainResult`, `defaultDrainTimeout`
(5 min), `drainAwsAffectingK8sResources` (deletes LoadBalancer
Services, ALB Ingresses, and Delete-reclaim PVCs cluster-wide, then
polls every 10s with bounded timeout), `renderDrainTimeoutRefusal`
(structured error block naming the surviving K8s resources by
@Kind/namespace/name@);
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` now runs the drain
phase before the per-run Pulumi destroys per the doctrine in
@documents/engineering/lifecycle_reconciliation_doctrine.md § 5@.
The "K8s drain not yet implemented" warning emitted by Sprint 4.11
is removed.
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`substrates.md`](substrates.md),
[`../documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../documents/engineering/unit_testing_policy.md`](../documents/engineering/unit_testing_policy.md)

### Objective

Close leak classes 2–5 from
[lifecycle_reconciliation_doctrine.md → §1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
(CSI volumes, LBC load balancers, cert-manager DNS01 records,
direct-`aws`-CLI shell-out Route 53 records) by adding a K8s-API drain
phase to `prodbox rke2 delete --cascade` (and, when introduced,
`prodbox nuke`). The drain runs **before** any Pulumi destroy so the
LBC and EBS CSI driver are still alive and can unwind their AWS
resources.

### Deliverables

- `src/Prodbox/Lifecycle/K8sDrain.hs` (new) exports
  `drainAwsAffectingK8sResources :: KubectlEnv -> IO (Either
  StructuredError ())`. Deletes LoadBalancer Services, ALB Ingresses,
  and Delete-reclaim PVCs cluster-wide, then polls for AWS-side
  unwind with a bounded timeout (default 5 min). Structured error on
  timeout names the remaining AWS resources by ARN.
- Wires the drain into the `--cascade` arm of `rke2 delete` between
  the existing predicate check and the Pulumi destroys. Removes the
  "K8s drain not yet implemented" warning emitted by Sprint `4.11`.
- `src/Prodbox/Lifecycle/TagSweep.hs` extends the postflight scan from
  Pulumi-tracked residue only to the full cluster-tag query
  (`kubernetes.io/cluster/<cluster-name>` + `prodbox.io/*`).

### Validation

1. `prodbox dev check`
2. `prodbox test unit` covers drain-policy classifiers (which K8s
   objects trigger which AWS-side unwind) as pure logic.
3. `prodbox test integration lifecycle-cascade` deploys a chart
   producing an ALB and a PVC, runs `rke2 delete --cascade`, asserts
   (a) the ALB and EBS volume are gone from AWS within the drain
   timeout, (b) the postflight tag sweep returns empty, (c) `aws-ses`
   resources are untouched.

### Current Validation State

Code framework landed May 21, 2026: `prodbox dev check` exits 0;
`prodbox test unit` (399/399).

### Remaining Work

- Cascade-postflight tag sweep wiring: nuke step 4 is the only
  wired caller today. Wiring the same scan into the cascade arm of
  `rke2 delete --cascade` is the natural follow-up but requires
  either (a) extending the Sprint 7.5.c.v.d operational IAM policy
  to grant `tag:GetResources` / `resourcegroupstaggingapi:GetResources`,
  or (b) treating the cascade postflight sweep as a soft check that
  skips with a warning when the credentials lack the required grant.
- Drain-policy classifier unit tests (the "which K8s objects trigger
  which AWS-side unwind" matrix) are scaffolded by the module
  structure but not yet committed as pure tests.
- `prodbox test integration lifecycle-cascade` exercising end-to-end
  drain + postflight tag-sweep against live AWS — pending the live
  closure.
- The cascade currently fails noisily when the cluster is already
  absent (`kubectl delete services ...` returns `DrainFailed`
  because kubectl falls back to `localhost:8080`); the doctrine
  alignment landed in
  [lifecycle_reconciliation_doctrine.md § 3](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation)
  (`DrainSkipped` outcome treated as success-with-reason), the
  implementation landed in Sprint `4.15` on May 21, 2026.
  Operator-facing
  cascade-narration strings still leak Sprint identifiers; the
  vocabulary cleanup landed in Sprint `4.14` on May 21, 2026.

Blocked by Sprint `4.11`. Blocks Sprint `4.13`.

## Sprint 4.13: `prodbox nuke` Total Teardown ✅

**Status**: Done. CLI scaffold + parser + TTY guard + dry-run plan
renderer landed May 21, 2026; the five-step orchestration body landed
May 21, 2026 (composes the existing destroy commands in-process and
acquires its elevated/admin credential through the interactive `SecretRef.Prompt`, prompt-used
once then discarded — the test harness simulating that prompt from `test-secrets.dhall`'s
`aws_admin_for_test_simulation.*` fixture; reframed per
[Sprint 7.16](phase-7-aws-substrate-foundations.md)); live
end-to-end `nuke` closure completed June 3, 2026.
**Implementation**: `src/Prodbox/CLI/Nuke.hs` (orchestration body
landed; exports `runNukeCommand`, `confirmationLiteral`,
`renderNukePlan`, `defaultNukeOptions`); `src/Prodbox/CLI/Command.hs`
(`NativeNuke NukeOptions` + `NukeOptions {nukeDryRun, nukePlanFile}`);
`src/Prodbox/CLI/Spec.hs` (`nuke` parser + `nukeLeaf` registration in
`commandRegistry`); `src/Prodbox/Native.hs` (dispatch
`NativeNuke -> runNukeCommand`); `src/Prodbox/CLI/Interactive.hs`
(reused via `requireInteractiveTty` with a `nukeInteractiveGuard`
that names the canonical command sequence for automation);
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (new
`destroyLongLivedPulumiStateBucket` + the JSON-Haskell
`renderDeletePayload` / `purgeRemainingVersions` pipeline that
empties the versioned bucket before deletion);
`src/Prodbox/CLI/Rke2.hs` (exports `runNativeDeleteCascade`
so nuke step 2 delegates to the actual cascade arm after the retained
`aws-ses` destroy);
`src/Prodbox/Infra/AwsSesStack.hs` (long-lived SES operations load
raw Dhall config for non-secret settings and acquire their elevated/admin credential through the
interactive `SecretRef.Prompt` — the harness simulating it from `test-secrets.dhall`'s
`aws_admin_for_test_simulation.*` fixture — sourcing the SES `awsRegion` stack config from the
non-secret topology; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md));
`src/Prodbox/Lifecycle/LiveResidue.hs`
(treats `NoSuchBucket` from the long-lived Pulumi S3 backend as
`ResidueAbsent` while preserving fail-closed behavior for ordinary S3
errors); `src/Prodbox/Aws.hs` (exports `adminAwsEnvironment` so the
orchestration body can reuse the prompt-acquired elevated/admin credential across
steps 3, 4, 5; under the corrected model that credential comes from the interactive
`SecretRef.Prompt`, harness-simulated from `test-secrets.dhall`, not from Vault or a stored
config block — reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)).
**Docs to update**: [`../documents/engineering/lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[`../documents/engineering/cli_command_surface.md`](../documents/engineering/cli_command_surface.md),
[`../CLAUDE.md`](../CLAUDE.md), [`../documents/engineering/README.md`](../documents/engineering/README.md),
[`../README.md`](../README.md)

### Objective

Introduce the operator-only total teardown command — the only
sanctioned path to destroy `aws-ses` and the long-lived
`pulumi_state_backend` bucket transitively, alongside the explicit
per-stack `prodbox pulumi aws-ses-destroy --yes`. The command exists so
operators have one clearly-labelled "blow away everything prodbox owns"
entrypoint, with the discipline necessary to make accidental invocation
impossible.

### Deliverables

- `src/Prodbox/CLI/Nuke.hs` (new) implements the `prodbox nuke`
  command. Orchestrates, in dependency order: K8s drain (Sprint
  `4.12`), destroy all Pulumi stacks (`aws-eks-subzone`, `aws-eks`,
  `aws-test`, `aws-ses`), `prodbox aws teardown`-equivalent IAM
  cleanup, local rke2 uninstall, postflight tag sweep, and finally
  the long-lived `pulumi_state_backend` bucket destruction.
- TTY-only: refuses non-interactive contexts with a message naming the
  canonical command sequence to compose manually.
- Typed-confirmation: operator must type the literal string
  `NUKE EVERYTHING` (not `yes`) at the confirmation prompt.
- `--dry-run` / `--plan-file` render the exact sequence without
  mutating. No `--yes` shorthand — deliberate omission.

### Validation

1. `prodbox dev check`
2. `prodbox test unit` covers parser shape (TTY refusal, typed-token
   acceptance, flag mutual exclusion).
3. `prodbox nuke --dry-run` against a populated AWS account produces
   the expected ordered plan.
4. End-to-end live `nuke` is an opt-in CI suite (it destroys long-lived
   shared infrastructure) — gated behind explicit operator request,
   not part of the default canonical test suite.

### Current Validation State

Code framework landed May 21, 2026; orchestration body landed
May 21, 2026: `prodbox dev check` exits 0; `prodbox test unit`
(420/420, up from 403 by adding three new `renderDeletePayload`
tests covering the canonical S3 `delete-objects` payload shape and
two `renderNukePlan` tests that pin the five-step ordering plus the
typed-confirmation literal). `./.build/prodbox nuke --dry-run`
renders the dependency-ordered teardown plan with the
typed-confirmation literal `NUKE EVERYTHING` visible in the output.
TTY refusal exercised via `nukeInteractiveGuard`. After
typed-confirmation acceptance, the orchestration body now runs the
five-step destructive sequence (`aws-ses` destroy while Vault/MinIO are
still live → cascade arm → operational IAM teardown → postflight tag
sweep → long-lived state-bucket destroy) in-process. The elevated/admin credential is acquired
through the interactive `SecretRef.Prompt` (prompt-used once then discarded; the test harness
simulating that prompt from `test-secrets.dhall`'s `aws_admin_for_test_simulation.*` fixture),
matching the long-lived `aws-ses` and state-bucket paths. There is no stored admin block in
`prodbox-config.dhall`; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md).

2026-06-03 validation refresh: `./.build/prodbox nuke --dry-run`
exits 0 and renders the expected five-step plan (`aws-ses` destroy,
`rke2 delete --cascade` arm, operational IAM teardown, postflight tag
sweep, long-lived state-bucket destroy) plus
`CONFIRMATION_LITERAL=NUKE EVERYTHING`. The live closure gate also
completed on June 3, 2026 via `./.build/prodbox nuke` in a TTY with
the typed literal `NUKE EVERYTHING`: step 1 delegated to
`runNativeDeleteCascade` and completed against an already-absent local
cluster; step 2 treated the already-absent long-lived Pulumi S3 backend
bucket as an idempotent `aws-ses` absence; step 3 cleared the
operational IAM/config surface under the nuke-owned
`AcceptOrphanResidue` policy after the cascade; step 4 reported a
clean postflight tag sweep; step 5 completed the long-lived state-bucket
destroy idempotently. Validation after the live-run fixes:
`./.build/prodbox dev check` exit 0, `./.build/prodbox test unit`
634/634, `./.build/prodbox nuke --dry-run` exit 0, live
`./.build/prodbox nuke` exit 0.

### Remaining Work

- None.

## Sprint 4.14: Operator Vocabulary Contract Enforcement ✅

**Status**: Done (May 21, 2026)
**Implementation**: `src/Prodbox/CLI/Spec.hs` (rewrite the
sprint-tagged strings at `:672` `--cascade` parser-side help,
`:680` `--allow-pulumi-residue` parser-side help, `:1268–1271`
`rke2 delete` leaf description, `:1277` `aws-ses-migrate-backend`
leaf description, `:1333` `--cascade` leaf-side help, `:1345`
example help, `:1438` `nukeLeaf` description into operator
vocabulary); `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`
(strip the `Sprint 4.11:` / `Sprint 4.12 pending` labels from the
`writeOutputLine` strings); `src/Prodbox/CheckCode.hs` (add a
`Sprint [0-9]` regex scan over operator-facing surfaces per
[cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract));
regenerate `documents/cli/commands.md`, `share/man/man1/*`,
`share/completion/{bash,zsh,fish}/*`,
`test/golden/cli/{commands-tree.txt,commands.json,help-all.txt}`
via `prodbox dev docs generate` plus `cabal test --accept` on the three
golden tests.
**Docs to update**: `documents/engineering/cli_command_surface.md`
(already captures the contract; this sprint enforces it),
`documents/engineering/code_quality.md` (lint-stack reference is
already in place).

### Objective

Make the operator vocabulary contract structurally enforceable. The
May 21, 2026 Sprint `4.10`–`4.13` code frameworks leaked
"Sprint 4.X" labels into operator-facing CLI help text, manpages,
shell completions, and the generated CLI command reference. This
sprint rewrites every leak site to operator vocabulary and adds the
`prodbox dev check` regex scan that prevents the regression.

### Deliverables

- Every sprint-tagged string in `src/Prodbox/CLI/Spec.hs` rewritten
  to operator vocabulary. The behavioral prose (what `--cascade`
  does, what `--allow-pulumi-residue` bypasses, etc.) is preserved;
  only the sprint identifiers are removed.
- `runNativeDeleteCascade`'s runtime `writeOutputLine` calls
  rewritten similarly. The K8s drain narration still names the
  drain targets (`LoadBalancer Services, Ingresses, Delete-reclaim
  PVCs`) but does not name Sprint 4.11/4.12.
- `src/Prodbox/CheckCode.hs` gains a `checkOperatorVocabulary`
  scan that fails on `Sprint [0-9]` or `Sprints [0-9]` in any file
  under `src/Prodbox/CLI/Spec.hs` (string literals only — comments
  are exempt), `share/man/`, `share/completion/`,
  `documents/cli/`, or `test/golden/cli/`.
- Generated CLI artifacts regenerated via `prodbox dev docs generate`;
  test goldens refreshed via `cabal test --accept` on
  `command tree` / `command registry JSON` / `leaf help page`.

### Validation

1. `prodbox dev check` exit 0 (with the new scan wired).
2. `prodbox test unit` passes (no new tests strictly required, but
   one regression-guard test invoking the new scan against a
   fixture string `"Sprint 4.99: ..."` and asserting refusal is
   recommended).
3. `grep -rE 'Sprint [0-9]' documents/cli/ share/man/ share/completion/ test/golden/cli/`
   returns nothing.
4. `./.build/prodbox rke2 delete --help`,
   `./.build/prodbox pulumi aws-ses-migrate-backend --help`, and
   `./.build/prodbox nuke --help` outputs contain no `Sprint`
   substring.

### Remaining Work

None. Sprint closed on its owned surface:
`prodbox dev check` exits 0, the new
`checkOperatorVocabulary` scan refuses any `Sprint <digit>` or
`Sprints <digit>` token pair in `src/Prodbox/CLI/Spec.hs` string
literals and in every file under `share/man/`,
`share/completion/`, `documents/cli/`, and `test/golden/cli/`.
`prodbox test unit` runs 410/410 (up from 403 with seven new pure
tests covering `matchesSprintToken` and `extractStringLiterals`).
`grep -rE 'Sprint [0-9]' documents/cli/ share/man/ share/completion/
test/golden/cli/` returns nothing. The leaks at Spec.hs lines 672,
683, 1277, 1327, 1333, 1345, 1438 + Rke2.hs's cascade narration
are rewritten to operator vocabulary; the existing behavioral prose
is preserved.

## Sprint 4.15: Cascade Tolerates Absent Cluster ✅

**Status**: Done (May 21, 2026)
**Blocked by**: Sprint `4.12` (provides the existing `K8sDrain`
module and `runNativeDeleteCascade` wiring this sprint extends).
**Implementation**: `src/Prodbox/Lifecycle/K8sDrain.hs` (add
`DrainSkipped String` constructor to `DrainResult`; add
`clusterReachable :: K8sDrainEnv -> IO Bool` probing
`kubectl cluster-info --request-timeout=5s`, classifying any
non-zero exit or subprocess `Failure` as unreachable without
parsing stderr; gate `drainAwsAffectingK8sResources` on the probe
so `DrainSkipped "Kubernetes API server not reachable; nothing to
drain."` fires before any delete attempt);
`src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (prepend
`KUBECONFIG=/etc/rancher/rke2/rke2.yaml` to the drain env when
the file exists, using the existing `rke2KubeconfigPath`
constant at line 179; extend the `DrainResult` case-of with a
`DrainSkipped reason -> writeOutputLine ("K8s drain skipped: " ++ reason) >> runNativeDelete repoRoot`
arm; add an inline comment naming the skip-is-success invariant
per
[lifecycle_reconciliation_doctrine.md § 3](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation)).
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md`
(already captures the `DrainResult` outcome ADT and the
skip-is-success invariant; this sprint implements it).

### Objective

Close the symptom surfaced by the May 21, 2026 live run on a host
without a cluster: `prodbox rke2 delete --cascade --yes` failed
noisily because the drain phase called `kubectl delete services
--all-namespaces ...` immediately, `kubectl` fell back to
`localhost:8080` (no `KUBECONFIG`, no
`/etc/rancher/rke2/rke2.yaml`), and the drain returned
`DrainFailed` with memcache connection-refused noise. Operators
running cascade against an already-gone cluster (partial
teardown, first-time provisioning, repeated reruns) should see
`K8s drain skipped: Kubernetes API server not reachable; nothing
to drain.` and proceed to the rest of the cascade.

### Deliverables

- New `DrainSkipped String` constructor on the `DrainResult` ADT.
- New `clusterReachable` helper using the canonical reachability
  probe `kubectl cluster-info --request-timeout=5s`.
- `drainAwsAffectingK8sResources` checks reachability first and
  short-circuits on `DrainSkipped`.
- `runNativeDeleteCascade` sets `KUBECONFIG` from
  `rke2KubeconfigPath` when the file exists, and handles
  `DrainSkipped` as success-with-reason.
- Inline comment in `runNativeDeleteCascade` naming the
  skip-is-success invariant.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` passes (one new pure unit test verifying
   that `DrainSkipped` is treated as a non-failure by the cascade's
   case-of, ideally by refactoring the case-of into a pure helper
   `cascadeDecisionFromDrainResult :: DrainResult -> CascadeDecision`
   and testing the decision matrix).
3. `./.build/prodbox rke2 delete --cascade --yes` on a host without
   a running cluster emits `K8s drain skipped: Kubernetes API
   server not reachable; nothing to drain.` and proceeds to the
   existing `runNativeDelete` sequence (per-run Pulumi destroys +
   manual-cleanup fallback), exiting 0 (or with the existing
   per-run-Pulumi error code if any).
4. `./.build/prodbox rke2 delete --cascade --yes` on a host with a
   running cluster runs the drain normally (no behavior regression
   on the happy path).

### Remaining Work

None. Sprint closed on May 21, 2026 with the absent-cluster path
verified end-to-end via `./.build/prodbox rke2 delete --cascade
--yes` on this host (no rke2 service installed):

```text
Running K8s drain phase (LoadBalancer Services, Ingresses, Delete-reclaim PVCs)...
K8s drain skipped: Kubernetes API server not reachable; nothing to drain. Proceeding with per-run Pulumi destroys + cluster uninstall.
Deleting local RKE2 environment...
AWS EKS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy
AWS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy
Local RKE2 substrate: cleanup complete
Managed kubeconfig: already absent
Preserved host state:
  - manual PV root: /home/matthewnowak/prodbox/.data
  - retained chart state root: /home/matthewnowak/prodbox/.prodbox-state
```

The cascade exit code is 0; the previous "kubectl connection refused"
memcache noise from the May 21 first run is gone. Live cascade
exercise against a host **with** a running cluster rolls up into
Sprint `4.12`'s live closure when that happy-path also runs against
real AWS substrate work.

## Sprint 4.16: ResidueStatus ADT Replaces File-Existence Predicates ✅

**Status**: Done on the code-owned surface. Source-of-truth swap landed 2026-05-27.

Typed ADT, per-stack adapter, caller migration, and the supporting `Prodbox.Infra.StackOutputs` foundation landed earlier (May 23, 2026). The closing change (2026-05-27) introduces `Prodbox.Lifecycle.LiveResidue`, swaps each `<stack>ResidueStatus` to query the actual Pulumi backend, splits `Prodbox.Aws.checkPulumiResidueBeforeTeardown` into a pure `categorizePulumiResidue :: PerRunResidueStatuses -> ResidueStatus -> [(String, String)]` plus an IO wrapper that batches one MinIO port-forward and one S3 query, and refactors the three downstream callers (`Aws.checkPulumiResidueBeforeTeardown`, `Preconditions.noLive{PerRun,LongLived}PulumiStacks`, `Rke2.runNativeDeleteCascade`) onto the batch.

The four `<stack>HasLiveResources :: FilePath -> IO Bool` boolean predicates are removed; per-stack `<stack>ResidueStatus` functions delegate to `LiveResidue` (the per-run trio shares one MinIO port-forward bracket).

A test-only env var `PRODBOX_TEST_RESIDUE_ABSENT=1` (documented at the test-fixture boundary, set by `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment` in `test/integration/CliSuite.hs`) short-circuits both `queryPerRunResidueStatuses` and `queryAwsSesResidueStatus` to `ResidueAbsent` so the fake-AWS-CLI integration suite does not require a running MinIO or a configured long-lived S3 backend. The pure `categorizePulumiResidue` half is the actual subject of the unit-test rewrite; 17 file-existence unit tests are reauthored to inject synthetic `PerRunResidueStatuses` directly, and 13 new tests cover the LiveResidue pure helpers (`residueStatusFromListing`, error-mapping discriminators, suffix-aware stack-name matching) and the per-lifecycle-class doctrine asymmetry (per-run unreachable → absent; long-lived unreachable → still-present).

Removal of `save<Stack>StackSnapshot` / `load<Stack>StackSnapshot` / `clear<Stack>StackSnapshot` and the `AwsXxxStackSnapshot` file-IO surface (the in-memory records stay) remain Sprint 4.18 work. The live AWS-substrate regression (`prodbox test all --substrate aws` produces zero `.prodbox-state/aws-*/` snapshot writes during cascade refusal paths) remains the residual operator-driven closure gate.

**Implementation**: new `src/Prodbox/Lifecycle/LiveResidue.hs` (PerRunResidueStatuses + `queryPerRunResidueStatuses` / `queryAwsSesResidueStatus` IO surface + pure helpers); per-stack `<stack>ResidueStatus` in `src/Prodbox/Infra/{AwsEksTestStack,AwsEksSubzoneStack,AwsTestStack,AwsSesStack}.hs` now delegates to LiveResidue (boolean `<stack>HasLiveResources` predicates removed); `src/Prodbox/Aws.hs` exports the pure `categorizePulumiResidue` alongside the IO wrapper `checkPulumiResidueBeforeTeardown`; `src/Prodbox/Lifecycle/Preconditions.hs` and `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` use the batch query; new test-only env var bound at `src/Prodbox/Lifecycle/LiveResidue.hs::testResidueAbsentEnvVar`; integration helpers `fakeAwsEnvironment` / `fakeAwsHarnessEnvironment` set the var; 17 unit tests rewritten in `test/unit/Main.hs::"Sprint 7.6 AWS harness orphan-safety (Sprint 4.16 source-of-truth pure layer)"` / `"Sprint 7.7 applyAwsTeardown residue policy"` / `"Sprint 7.7 DestroyPulumiResidueFirst dispatch plan"`; 13 new tests in `"Sprint 4.16 LiveResidue error mapping + listing translation"`.

**Validation (2026-05-27)**: `prodbox dev check` exit 0; `prodbox test unit` 567/567 (up from 554); `prodbox test integration cli` 28/28; `prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14.

**Docs to update**: ✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, ✅ `DEVELOPMENT_PLAN/README.md`, ✅ `DEVELOPMENT_PLAN/system-components.md`, ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (frames the predicate as the pre-Sprint-4.16 file-existence approximation), ✅ `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` (the surviving `<stack>HasLiveResources` mentions are Sprint 7.6's historical implementation record of the predicate whose removal the [legacy ledger](legacy-tracking-for-deletion.md) owns).

### Objective

Replace the file-existence predicate
(`<stack>HasLiveResources :: FilePath -> IO Bool` = `doesFileExist` on
`.prodbox-state/<stack>/stack-snapshot.json`) with source-of-truth `ResidueStatus`
queries against the actual Pulumi backend (MinIO for per-run, S3 for long-lived).
The May 22, 2026 cascade-credentials failure on this host exposed the predicate as
the doctrine-violating piece that enables stale-state refusals. See
[lifecycle_reconciliation_doctrine.md §3](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Deliverables

- New `Prodbox.Lifecycle.ResidueStatus` module:
  `data ResidueStatus = ResidueAbsent | ResiduePresent ResidueDetails | ResidueUnreachable ResidueUnreachableReason`.
  Pure ADT with deriving `Eq`, `Show`, and structured-render helpers.
- `<stack>ResidueStatus :: ... -> IO ResidueStatus` per stack in each of
  `src/Prodbox/Infra/AwsEksTestStack.hs`, `AwsEksSubzoneStack.hs`, `AwsTestStack.hs`,
  `AwsSesStack.hs`. At Sprint `4.16` closure, per-run implementations opened the MinIO
  port-forward and the long-lived implementation queried S3. Sprint `7.14` superseded both main
  paths with encrypted Model-B observations; Sprint `4.47` implements the retained control-plane
  authority types and opaque-CAS adapter while keeping S3 only as TLS/legacy first-touch storage,
  and composes the adapter into the supported fenced reconcile transaction.
- Removal of `save<Stack>StackSnapshot`, `load<Stack>StackSnapshot`,
  `clear<Stack>StackSnapshot`, `<stack>StateDir`, `<stack>SnapshotPath`, and the
  `AwsXxxStackSnapshot` records' file-IO surface. Output cache replaced by
  `Prodbox.Infra.StackOutputs.fetch :: StackName -> IO (Map Text Text)` which
  shells out to `pulumi stack output --show-secrets` on demand and decodes the
  result.
- Caller updates: `aws teardown` residue policy
  (`src/Prodbox/Aws.hs::checkPulumiResidueBeforeTeardown`,
  `partitionResidueByLifecycle`), `rke2 delete` cascade
  (`src/Prodbox/CLI/Rke2.hs::runNativeDelete{,Cascade}`), harness postflight
  (`src/Prodbox/TestRunner.hs::runWithAwsHarnessCleanup`,
  `src/Prodbox/Aws.hs::runAwsIamHarnessSetup`/`Teardown`). All four switch from
  file-existence to `ResidueStatus`. Per-run `ResidueUnreachable` is treated as
  absent; long-lived `ResidueUnreachable` is a refusal.
- 15+ unit tests in `test/unit/Main.hs::"Sprint 4.16 ResidueStatus"` covering the
  three constructors per stack. 4 cascade-flow tests covering MinIO-up-and-stack-
  present, MinIO-up-and-stack-absent, MinIO-down-per-run (graceful), MinIO-down-
  long-lived (refusal).

### Validation

1. `prodbox dev check` exit 0 (May 23, 2026, code-framework landing; re-confirmed after
   the `Prodbox.Infra.StackOutputs` foundation landed in the later May 23 session).
2. `prodbox test unit` 515/515 (12 ResidueStatus tests + 18 StackOutputs tests; up from
   468 pre-Sprint, then 497 after the first 4.16 landing, then 515 after the
   `StackOutputs` foundation).
3. `prodbox test integration cli` 28/28 (the migrated callers preserve
   refuse-path semantics because the file-existence adapter still drives
   `<stack>ResidueStatus` today).
4. **Live regression (deferred)**: a full `prodbox test all --substrate aws`
   cycle on this host produces zero `.prodbox-state/aws-*/` files at any point
   during the run. This closure gate lands with the source-of-truth swap below.

### Remaining Work

- **Code-owned surface complete (2026-05-27)**. All Sprint 4.16 deliverables
  landed: typed ADT, `StackOutputs` foundation, `LiveResidue` source-of-truth
  module, per-stack adapter delegation, batch-aware caller refactor, and
  the unit-test rewrite to a pure-categorization layer.
- **Snapshot file-IO removal**: `save<Stack>StackSnapshot` /
  `load<Stack>StackSnapshot` / `clear<Stack>StackSnapshot` plus the
  consumers inside `src/Prodbox/TestValidation.hs:~1860–1920` (three
  `load*StackSnapshot` call sites) are Sprint 4.18 scope.
- **Live AWS-substrate gate**: `prodbox test all --substrate aws`
  produces zero `.prodbox-state/aws-*/` snapshot writes during cascade
  refusal paths. Tracked as the operator-driven closure gate alongside
  the broader Sprint 7.5.c.v live re-run.

## Sprint 4.17: Cascade Canonical Order and Self-Materialize Operational Creds ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the cascade narration printed the then-canonical phase order
(`confirm-MinIO → drain → per-run destroys → uninstall → sweep`; Sprint
`4.40` later inserts the test-EBS reaper before uninstall); the
`lifecycle` validation completed a full `rke2 delete --cascade --yes` on
the home substrate; the per-run AWS substrate validations exercised the
cascade with live `aws-eks-test` + `aws-test` per-run stacks present
("Per-run Pulumi destroys: running 3 destroy(s) against MinIO"), drained
the live EKS cluster's LoadBalancer / ALB / Delete-reclaim PVCs, and
completed without `DependencyViolation` on subnet deletion (Sprint 4.17.b
substrate-aware drain validated live). Every code-owned half landed
May 23, 2026. (a) Credential-fallback half (May 23, 2026 a.m.) — each per-run `loadOperationalAwsCredentials` (in `AwsEksTestStack`, `AwsTestStack`, and transitively `AwsEksSubzoneStack` via re-import) falls back to the harness-simulated elevated/admin prompt (sourced from `test-secrets.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)) when the operational `aws.*` `SecretRef.Vault` reference resolves empty. (b) Cascade-order rewrite (May 23, 2026 p.m.) reorders `runNativeDeleteCascade` to the canonical sequence (confirm-MinIO via per-stack `<stack>ResidueStatus` → K8s drain → per-run Pulumi destroys for any `ResiduePresent` stack → RKE2 uninstall + cluster-substrate cleanup → postflight cluster-tag sweep) per [lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md); Sprint `4.40` later inserts the test-EBS reaper between per-run destroys and uninstall. (c) **Postflight tag sweep wiring (May 23, 2026 later session)** — `runCascadePostflightTagSweep` now loads admin credentials via `Prodbox.Infra.LongLivedPulumiBackend.loadAdminAwsCredentials`, builds the AWS env via `Prodbox.Aws.adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` with `tagSweepClusterName = Just awsEksCanonicalClusterName`; an empty result is reported as "clean (no cluster-tagged or prodbox-owned AWS residue)" and a non-empty result is reported with the full `renderTagSweepRefusal` block, while the cascade still returns `ExitSuccess` (best-effort per doctrine §6). When no elevated/admin credential is supplied (home-only operator with no AWS substrate, and no harness-simulated `test-secrets.dhall` `aws_admin_for_test_simulation.*` fixture), the sweep emits a single-line skip diagnostic explaining that no AWS resources could exist. 4 new unit tests in `test/unit/Main.hs::"Sprint 4.17 postflight tag sweep wiring"` cover the refusal-block ARN/tag rendering, the multi-resource bullet output, the empty-list path, and the `TagSweepInput` record shape. The remaining live operator validation closes the sprint: a real cascade run on this host (or a substrate-equivalent) that exercises the new order end-to-end against a live cluster with at least one per-run Pulumi stack alive.
**Blocked by**: none — every code-owned deliverable is shipped and locally validated. **Live-proof: closed** (development_plan_standards.md Standard O): the real-cascade-against-a-host-with-a-live-`aws-eks`-stack proof is a live-infrastructure axis that never gated this sprint's code-owned closure; it was exercised live on 2026-06-01 via `prodbox test all` retry 21.
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs::loadOperationalAwsCredentials` and `src/Prodbox/Infra/AwsTestStack.hs::loadOperationalAwsCredentials` (May 23, 2026 a.m., in-memory operational→admin fallback). `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (May 23, 2026 p.m., reordered to confirm-MinIO → drain → per-run destroys → uninstall → postflight sweep; Sprint `4.40` later inserts the test-EBS reaper before uninstall); new helpers `perRunCascadeInventory` (pure, exported, drives test coverage), `runCascadeDrainPhase`, `runCascadePostflightTagSweep`; cascade now consumes the typed `<stack>ResidueStatus` adapter from Sprint 4.16 and skips per-run destroys whose stack reports `ResidueAbsent` (or `ResidueUnreachable` per the per-run lifecycle class). 7 new unit tests in `test/unit/Main.hs::"Sprint 4.17 cascade per-run inventory"` cover all-absent / all-present / individual-stack-present / `ResidueUnreachable`-treated-as-absent permutations. **Tag sweep wiring (May 23, 2026 later session)**: `runCascadePostflightTagSweep` rewritten in `src/Prodbox/CLI/Rke2.hs` to invoke `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against the admin AWS environment when an elevated/admin credential is supplied (the harness simulating the prompt from `test-secrets.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per [Sprint 7.16](phase-7-aws-substrate-foundations.md)); new exports `awsEksCanonicalClusterName` on `Prodbox.Infra.AwsEksTestStack` so the cascade can build the canonical `kubernetes.io/cluster/<name>` filter; 4 new unit tests in `"Sprint 4.17 postflight tag sweep wiring"` lift `renderTagSweepRefusal` + `TagSweepInput` invariants out of the live-only path (test count 519/519, up from 515).
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`

### Objective

Reorder `prodbox rke2 delete --cascade` to release MinIO-tracked AWS resources
before the local cluster is uninstalled, and eliminate the cascade-credentials
failure class by generalizing the Sprint 7.7 `aws-ses` self-materialize bracket to
all per-run stacks. See
[lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
for the authoritative cascade-order table.

### Deliverables

- **Credential-fallback half (Done May 23, 2026)**: each per-run
  `loadOperationalAwsCredentials` (in
  `src/Prodbox/Infra/AwsEksTestStack.hs` and
  `src/Prodbox/Infra/AwsTestStack.hs`) tries the operational `aws.*` credential
  (resolved from its `SecretRef.Vault` reference) first and transparently falls back to the
  harness-simulated elevated/admin prompt (sourced from `test-secrets.dhall`'s
  `aws_admin_for_test_simulation.*` fixture; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md)) when
  operational is empty. `src/Prodbox/Infra/AwsEksSubzoneStack.hs` inherits
  the new behavior because it re-imports `loadOperationalAwsCredentials`
  from `AwsEksTestStack`. No file mutation: the destroy paths only *read*
  credentials, so the in-memory fallback is sufficient. 4 new unit tests
  in `test/unit/Main.hs::"Sprint 4.17 destroy-path credential fallback"`
  cover the `credentialsConfigured` smart-constructor semantics that drive
  the fallback branch.
- **Cascade-order rewrite (landed wrong order May 23, 2026 p.m.; correction scheduled as Sprint 4.17.a)**:
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` initially shipped with the
  order:
  1. Confirm MinIO reachable via per-stack `<stack>ResidueStatus` queries
  2. Per-run `pulumi destroy` for stacks reporting `ResiduePresent`
  3. K8s drain (Sprint 4.12)
  4. RKE2 uninstall + cluster-substrate cleanup
  5. Postflight cluster-tag sweep

  The May 27/28 AWS-substrate live exercise on Bathurst surfaced this as
  the wrong order: on the AWS substrate the per-run destroys (step 2) run
  while AWS Load Balancer Controller + EBS CSI driver are still alive on
  the EKS cluster, leaving orphan ENIs that block subnet deletion
  (`DependencyViolation: The subnet '<id>' has dependencies and cannot be
  deleted`). The doctrine-canonical order — drain BEFORE per-run destroys
  — is documented in
  [`lifecycle_reconciliation_doctrine.md` §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  and tracked as new Sprint 4.17.a below. The pure helper
  `perRunCascadeInventory` (exported) drives unit test coverage of the
  canonical destroy ordering; the existing helpers `runCascadeDrainPhase`
  / `runCascadePostflightTagSweep` are preserved as named phases. Sprint
  4.17.b adds substrate-aware kubeconfig handling to the drain phase.
- **Optional ergonomic bracket (Remaining)**: an explicit
  `Prodbox.Aws.withMaterializedOperationalCreds :: IO a -> IO a` whose source under the
  corrected model is the harness-simulated elevated/admin prompt (from `test-secrets.dhall`),
  materializing operational `aws.*` into the in-memory environment for the body and clearing it
  on exit — never writing a plaintext key into `prodbox-config.dhall` (the generated operational
  `aws.*` is minted into Vault KV and referenced only as a `SecretRef.Vault` value; reframed per
  [Sprint 7.16](phase-7-aws-substrate-foundations.md)). Only required if a future call site needs
  the materializing semantics (today's in-memory fallback satisfies every destroy-path
  reader). Lands when the postflight tag sweep grows admin-credentials
  wiring.

### Validation

1. `prodbox dev check` exit 0 (May 23, 2026 p.m., after cascade
   reorder; re-confirmed after the postflight-tag-sweep wiring landed
   in the later May 23 session).
2. `prodbox dev lint docs` exit 0; `prodbox dev docs check` exit 0.
3. `prodbox test unit` 519/519 (7 cascade-inventory + 12 Residue + 18
   StackOutputs + 4 postflight-tag-sweep wiring tests; up from 468 at
   sprint start).
4. `prodbox test integration cli` 28/28 (cascade refactor preserves the
   existing rke2 reconcile + delete integration cases).
5. **Live regression (deferred to operator)**: bring up `aws-eks` via
   `prodbox test integration aws-iam --substrate aws`; manually clear
   `aws.*` in `prodbox-config.dhall`; run `prodbox rke2 delete --cascade
   --yes`; confirm it succeeds with output ordering
   "confirm-MinIO → drain → per-run destroys → uninstall → sweep" (Sprint
   `4.40` later inserts the test-EBS reaper before uninstall) and
   without the May 22 error message ("operational AWS credentials are
   required to destroy the AWS EKS test stack once a Pulumi stack
   exists: aws.access_key_id must not be empty") because the load helper
   now falls back.

### Remaining Work

All code-owned work is shipped. The postflight tag sweep now invokes
`Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources` against
the admin AWS environment when an elevated/admin credential is supplied (the harness simulating
the prompt from `test-secrets.dhall`'s `aws_admin_for_test_simulation.*` fixture; reframed per
[Sprint 7.16](phase-7-aws-substrate-foundations.md)); the explicit
`Prodbox.Aws.withMaterializedOperationalCreds`
bracket remains an optional ergonomic future addition only if a call
site needs the in-memory materializing semantics (today's in-memory fallback
satisfies every destroy-path reader, and the postflight is a
read-only AWS Resource Tagging API query). The remaining closure is
the live operator step: bring up `aws-eks` via
`prodbox test integration aws-iam --substrate aws`, then run
`prodbox rke2 delete --cascade --yes` and confirm the cascade ordering
matches the canonical sequence and the postflight reports either
"clean" or a structured refusal block. The final cleanup (kubeconfig
on-demand, SSH key via Pulumi output, tmp tarball, `forbidDotProdboxState`
lint) is Sprint 4.18. The cascade-order correction + substrate-aware
drain land via Sprints 4.17.a and 4.17.b below.

## Sprint 4.17.a: Reorder Cascade to Doctrine-Canonical Sequence ✅

**Status**: Done (May 28, 2026 on the code-owned surface; AWS-substrate
live re-verification rolls up with Sprint 4.17.b)
**Implementation**: `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`
+ new top-level constant `cascadeOrderNarration` exposed as a stable
test pin; pure helper `perRunCascadeInventory` unchanged.
**Blocked by**: none (independent of 4.17.b on the home substrate; AWS
substrate verification needs both)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`
(updated May 28, 2026 to flip §5b table + §1 prose);
`documents/engineering/cli_command_surface.md` (updated May 28, 2026
`prodbox rke2 delete --cascade` section);
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
(legacy row moved Pending → Completed)

### Objective

Reorder cascade phases to match the then-doctrine-canonical sequence
`confirm-MinIO → drain → per-run destroys → uninstall → sweep` (later extended
by Sprint `4.40` with the test-EBS reaper before uninstall) so AWS-side
controllers (AWS Load Balancer Controller, EBS CSI driver) unwind their
ENIs / ALBs / EBS volumes before the per-run Pulumi destroy phase tries
to delete the substrate. The pre-correction order
(`destroys → drain`) was harmless on the home substrate (no
in-cluster AWS controllers) but fatal on the AWS substrate, producing
`DependencyViolation: The subnet '<id>' has dependencies and cannot
be deleted` errors mid-destroy with no recoverable path.

### Deliverables

- Reorder the orchestration block at
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade` (lines 748–806) to
  match the doctrine §5b table. The pure helper `perRunCascadeInventory`
  does not move; only the orchestration sequence around it changes.
- Update the docstring at lines 722–730 to remove the "trade-off"
  rationale that justified the wrong order. Replace with the
  substrate-aware rationale from
  [`lifecycle_reconciliation_doctrine.md` §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md).
- Add a Sprint 4.17.a regression test in `test/unit/Main.hs` pinning the
  canonical phase order against `perRunCascadeInventory` outputs (the
  test renders the cascade plan and asserts `drain` appears before
  `per-run destroys`).

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` passes (with the new phase-order test).
3. `prodbox test integration cli` 28/28 (cascade refactor preserves the
   existing `rke2 reconcile + delete` integration cases).
4. Live re-verification on the home substrate: `prodbox rke2 reconcile`,
   deploy charts, then `prodbox rke2 delete --cascade --yes` — confirm
   the cascade narration emits `drain` before `per-run destroys`.
5. Live re-verification on the AWS substrate is the gate for Sprint
   4.17.b (a full `prodbox test all --substrate aws` cycle completes
   cleanly only when both 4.17.a and 4.17.b are landed).

### Remaining Work

Code-owned work landed May 28, 2026: 5 new unit tests pin the canonical
phase order via the `cascadeOrderNarration` constant
(`test/unit/Main.hs::"Sprint 4.17.a canonical cascade phase order"`).
Live re-verification on the home substrate (`prodbox rke2 reconcile`,
deploy charts, then `prodbox rke2 delete --cascade --yes` — confirm
narration emits `drain` before `per-run destroys`) and on the AWS
substrate (full `prodbox test all --substrate aws` cycle completes
cleanly) are the only remaining closure gates. The AWS-substrate gate
rolls up with Sprint 4.17.b.

## Sprint 4.17.b: Substrate-Aware K8s Drain Phase ✅

**Status**: Done (May 28, 2026 on the code-owned surface; live
AWS-substrate verification remains the operator-driven gate)
**Implementation**: `src/Prodbox/CLI/Rke2.hs::runCascadeDrainPhase`
+ new pure helper `inferCascadeSubstrate` (exported for unit tests)
+ new helper `buildDrainEnvironment` building the substrate-aware
env-var list; `src/Prodbox/Lifecycle/K8sDrain.hs` unchanged
(`drainAwsAffectingK8sResources` consumes the env list the cascade
phase now constructs per-substrate).
**Blocked by**: Sprint 4.17.a (the substrate-aware drain only matters
when drain runs in the canonical position before per-run destroys)
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md §5b`
(updated May 28, 2026 to require substrate-aware drain),
`documents/engineering/aws_integration_environment_doctrine.md §5.5`
(added May 28, 2026),
`DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (legacy row moved
Pending → Completed)

### Objective

`runCascadeDrainPhase` currently hard-codes
`KUBECONFIG=/etc/rancher/rke2/rke2.yaml` — the local RKE2 cluster's
kubeconfig. On the AWS substrate this means the drain phase walks the
local cluster's namespaces (which have no AWS LoadBalancer Services)
and reports nothing to drain. The EKS-side LoadBalancer Services / ALB
Ingresses / Delete-reclaim PVCs are never deleted before per-run
destroys begin, so the AWS LBC + EBS CSI controllers keep their ENIs
alive into the subnet-deletion phase.

Take a `Substrate` argument and use
`Prodbox.PublicEdge.withSubstrateKubectlEnvironment` (already exported
from `src/Prodbox/PublicEdge.hs`) for `SubstrateAws` so the drain phase
talks to the EKS API and actually removes the resources holding ENIs.
For `SubstrateHomeLocal` keep the existing local-kubeconfig behaviour.

### Deliverables

- Change `runCascadeDrainPhase` signature to take `Substrate`.
- Wrap `K8sDrain.drainAwsAffectingK8sResources` in
  `withSubstrateKubectlEnvironment` so kubectl + `aws eks get-token`
  receive the substrate's `KUBECONFIG` + `AWS_*` env.
- The cascade call site at
  `runNativeDeleteCascade` passes through the per-stack substrate
  already in scope.
- Treat `DrainSkipped` on the AWS substrate as a hard failure (the EKS
  cluster is the source of the resources that the per-run destroys will
  fail to delete; skipping the drain guarantees the failure). On the
  home substrate `DrainSkipped` remains success-with-reason per Sprint
  4.15.
- Add a unit test that asserts `runCascadeDrainPhase SubstrateAws` sets
  the EKS kubeconfig path via the bracket.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` passes (with the new kubeconfig-selection test).
3. `prodbox test integration cli` 28/28.
4. **Live AWS-substrate re-verification**: a full
   `prodbox test all --substrate aws` cycle (or alternatively
   provisioning aws-eks then running `prodbox rke2 delete --cascade
   --yes`) completes cleanly. The cascade narration emits
   `drain (substrate=aws)` followed by `per-run destroys`, and the
   destroys succeed without `DependencyViolation` on subnet deletion.

### Remaining Work

Code-owned work landed May 28, 2026: `runCascadeDrainPhase` now takes
`Substrate`; for `SubstrateAws` it builds `KUBECONFIG=<aws-eks-test
kubeconfig>` + `AWS_*` from `settings.aws`; for `SubstrateHomeLocal` it
keeps the existing local-kubeconfig path. `DrainSkipped` on
`SubstrateAws` is now a hard failure with an explanatory message
naming `DependencyViolation` as the downstream symptom. The cascade
caller infers the substrate from per-run residue via the new pure
helper `inferCascadeSubstrate` (any AWS per-run stack reporting
`ResiduePresent` → `SubstrateAws`; otherwise `SubstrateHomeLocal`). 6
new unit tests in `test/unit/Main.hs::"Sprint 4.17.b cascade substrate
inference"` pin every combination. Live AWS-substrate verification
(full `prodbox test all --substrate aws` cycle completes cleanly
including the cascade) is the closure gate. The
`Prodbox.PublicEdge.withSubstrateKubectlEnvironment` helper is not used
here because `K8sDrain.K8sDrainEnv` takes an explicit env-var list
rather than mutating process env via `setEnv`; the substrate-aware env
construction lives in the new `buildDrainEnvironment` helper instead.

## Sprint 4.18: Remove Remaining .prodbox-state Artifacts and Final Lint ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the four-block lifecycle exercise (preserved-data + recovery-escape-hatch +
original-failure-mode + final-cleanup) passed end-to-end on the home
substrate; `prodbox dev check`'s `forbidDotProdboxState` lint enforces
the broadened `.prodbox-state/` write ban across `src/` + `app/` (no
hits today); `grep -rn '\.prodbox-state' src/ app/` returns only
historical comment references, no string literals. First chunk of
code-owned work landed 2026-05-27 on top of Sprint 4.16's source-of-truth
swap:

- Tarball scratch directories moved from
  `repoRoot </> ".prodbox-state" </> "tmp"` to the system temporary
  directory in `src/Prodbox/Lib/AwsSubstratePlatform.hs::withTempJsonFile`
  and `src/Prodbox/CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane`.
- New `Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` /
  `fetchAwsSesStackOutputs` foundation reads stack outputs from the
  live Pulumi backend (MinIO for per-run, S3 for long-lived) via the
  existing `Prodbox.Infra.StackOutputs.fetchOutputs` surface.
- Two consumers migrated off `loadXxxStackSnapshot` to the live read:
  `src/Prodbox/PublicEdge.hs::resolveSubstrateHostedZoneId` (reads
  `subzone_id` from `aws-eks-subzone` outputs) and
  `src/Prodbox/TestValidation.hs::verifyAwsEksSnapshot` (reads
  `cluster_name` + `subnet_ids` from `aws-eks-test` outputs).

Second chunk landed 2026-05-27 (later session):

- New pure parsers `Prodbox.Infra.AwsTestStack.parseAwsTestNodesFromOutputs`
  and `Prodbox.Infra.AwsEksTestStack.parseAwsEksTestStackFromOutputs`
  decode the live `Map Text Text` returned by
  `fetchPerRunStackOutputs` into structured `[AwsTestNode]` and
  `AwsEksTestStackSnapshot` records respectively.
- Three additional consumers migrated off `loadXxxStackSnapshot`:
  `src/Prodbox/TestValidation.hs::verifyAwsTestSnapshot`,
  `src/Prodbox/TestValidation.hs::verifyAwsTestSshReachability`
  (sharing a new `fetchAwsTestNodes` helper), and
  `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstratePlatformRuntime`
  (constructs the in-memory `AwsEksTestStackSnapshot` from live outputs
  instead of `.prodbox-state/aws-eks-test/stack-snapshot.json`).
- `Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` gains a
  test-only `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` override that reads the
  outputs map from `<dir>/<stack-name>.json` so the unit suite can
  exercise the migrated consumers without a live MinIO port-forward.
- 7 new unit tests pin the two pure parsers' happy paths plus the
  missing-field / non-JSON / wrong-shape failure modes. The
  `native validation helpers` SSH-retry test is rewritten to inject
  the `nodes` output via the new override instead of writing
  `.prodbox-state/aws-test/stack-snapshot.json`.

Validated with `prodbox dev check` exit 0, `prodbox test unit`
574/574 (up from 567), `prodbox test integration cli` 28/28,
`prodbox test integration env` 28/28.

Third chunk landed 2026-05-27 (later session): the two per-run stacks
the home `prodbox test all` exercises (`aws-eks-test`, `aws-test`) drop
their on-disk snapshot cache entirely.

- New `fetchAwsEksTestSnapshotFromBackend` /
  `fetchAwsTestSnapshotFromBackend` (each returning the same `Maybe
  <Snapshot>` the file cache used to) read the stack snapshot live from
  the in-cluster MinIO Pulumi backend via `fetchPerRunStackOutputs` +
  the pure parsers (`parseAwsEksTestStackFromOutputs`, new
  `parseAwsTestStackFromOutputs`). The destroy path fetches the snapshot
  pre-destroy (stack still present), so the precise per-resource residue
  check behaves exactly as before; an absent / unreachable / unparseable
  read falls back to the canonical tag-based residue scan, matching the
  old `Nothing` arm.
- Every internal `loadAwsEksTestStackSnapshot` /
  `loadAwsTestStackSnapshot` consumer migrated to the live read:
  `ensureXxxStackResources` (pre-provision residue check),
  `destroyXxxStackStatus`, and `assertNoXxxStackResidue`.
- All `saveXxxStackSnapshot` / `clearXxxStackSnapshot` callsites removed,
  and the file-IO helpers deleted: `save`/`load`/`clear`,
  `<stack>SnapshotPath`, `snapshotToJson` / `snapshotFromJson` /
  `nodeToJson`, and (for EKS) the now-unused `optionalString`. The
  `<stack>StateDir` helpers survive only because the HA-RKE2 SSH keypair
  and the EKS kubeconfig still live there pending the next chunk.
- The unit round-trip test that exercised `save`/`load` is replaced by
  two `parse*FromOutputs` round-trips over the flat `Map Text Text`
  backend shape (test count 575/575, up from 574).

Static gates green: `prodbox dev check` exit 0, `prodbox test unit`
575/575, `prodbox test integration cli` 28/28, `prodbox test
integration env` 28/28. Live validation (`prodbox test all` on the home
substrate, exercising the `aws-eks` + `ha-rke2-aws` provision/destroy
paths against the migrated code) is the closure gate and is in progress.

Fourth chunk landed 2026-05-30: the remaining two per-run + long-lived
stacks (`aws-eks-subzone`, `aws-ses`) drop their on-disk snapshot caches
to match chunks 1–3.

- New pure parsers `parseAwsEksSubzoneStackFromOutputs` and
  `parseAwsSesStackFromOutputs` decode the flat `Map Text Text` returned
  by `fetchPerRunStackOutputs` / `fetchAwsSesStackOutputs` into the
  existing `AwsEksSubzoneStackSnapshot` / `AwsSesStackSnapshot` records;
  matching `fetchAwsEksSubzoneStackSnapshotFromBackend` /
  `fetchAwsSesStackSnapshotFromBackend` IO wrappers return the same
  `Maybe <Snapshot>` shape the file cache used to. The destroy paths
  read the live snapshot pre-destroy (stack still present); absent /
  unreachable / unparseable reads fall back to the canonical residue
  scan, matching the old `Nothing` arm.
- All `saveAwsEksSubzoneStackSnapshot` / `loadAwsEksSubzoneStackSnapshot`
  / `clearAwsEksSubzoneStackSnapshot` callsites removed; ditto the
  `aws-ses` equivalents. The file-IO helpers deleted entirely:
  `save`/`load`/`clear`, `awsEksSubzoneStateDir`,
  `awsEksSubzoneSnapshotPath`, `awsSesStateDir`, `awsSesSnapshotPath`,
  `snapshotToJson` / `snapshotFromJson` on both modules.
- `assertNoAwsEksSubzoneStackResidue` / `assertNoAwsSesStackResidue`
  drop the now-unused `Maybe <Snapshot>` parameter (both functions did
  their own AWS-CLI residue check against config-resolved identifiers,
  ignoring the snapshot).
- `finalizeDestroy` on both modules simplifies to `pure (Right
  "destroyed")` — no local file to clear.

Fifth chunk landed 2026-05-30: the cross-invocation kubeconfig file at
`.prodbox-state/aws-eks-test/kubeconfig` is replaced with a per-call
`withEksKubeconfig` bracket; every consumer re-derives the kubeconfig
on demand via `aws eks update-kubeconfig --kubeconfig <mktemp>` rather
than relying on file persistence.

- New `Prodbox.Infra.AwsEksTestStack.withEksKubeconfig :: FilePath -> (FilePath -> IO a) -> IO a`
  internally resolves region from settings + cluster name from the live
  MinIO backend snapshot (`fetchAwsEksTestSnapshotFromBackend`),
  `openTempFile`'s a scoped path, runs `aws eks update-kubeconfig
  --kubeconfig <temp>`, hands the path to the action, and cleans up on
  all exit paths (including async exceptions in the action) via
  `Control.Exception.bracket`. Setup failures (snapshot absent, region
  empty, aws CLI failure) throw via `error` so the bracket's cleanup
  fires and the top-level error handler surfaces a clean failure;
  consumers that want the pre-migration "best-effort" semantic
  (drain skips if kubeconfig unavailable) wrap the bracket in `try`.
- `materializeAwsEksKubeconfig` deleted; the only caller
  (`ensureAwsEksTestStackResources` after the Pulumi up) ignored the
  returned path (the call was purely for cross-invocation file
  persistence, which is gone).
- `awsEksTestKubeconfigPath` + `awsEksTestStateDir` exports removed;
  `PublicEdge.substrateKubeconfigPath` (the hardcoded `.prodbox-state`
  path producer) deleted entirely.
- `drainAwsEksClusterBeforeDestroy` wraps the drain in
  `try (withEksKubeconfig ...)`, preserving the pre-migration
  "skip-with-diagnostic on missing kubeconfig" best-effort semantic.
- `PublicEdge.withSubstrateKubectlEnvironment`,
  `CLI/Charts.withSubstrateEnvironment`,
  `TestValidation.withSubstrateKubeconfigEnv` rewritten to wrap their
  actions in `withEksKubeconfig` on AWS substrate; `KUBECONFIG` +
  `AWS_*` overrides project the temp path instead of the legacy
  `.prodbox-state` path.
- `CLI/Rke2.buildDrainEnvironment` re-shaped to take the
  AWS-kubeconfig path as a `Maybe FilePath` parameter;
  `runCascadeDrainPhase` on AWS substrate wraps the drain in
  `try (withEksKubeconfig ...)` and treats bracket-setup failure as a
  hard cascade failure (same severity as a skipped drain — the EKS
  cluster is the source of the AWS resources the per-run destroys would
  delete, so unreachable kubeconfig = guaranteed
  `DependencyViolation` on subnet deletion).

Sixth chunk landed 2026-05-30: the @aws-test@ HA-RKE2 validation SSH
keypair is migrated off `.prodbox-state/aws-test/id_ed25519{,.pub}`.
Ownership flipped to Pulumi: `pulumi/aws-test/Main.yaml` now declares a
`tls:PrivateKey` resource (ED25519), threads `sshKey.publicKeyOpenssh`
into the cloud-init `ssh_authorized_keys`, and exports
`ssh_private_key: ${sshKey.privateKeyOpenssh}` as a Pulumi output. The
host-side `ssh-keygen` invocation is gone.

- Pulumi side: `publicKey` config input removed; `tls:PrivateKey`
  resource added; `ssh_private_key` output added.
- New `Prodbox.Infra.AwsTestStack.withAwsTestSshPrivateKey :: FilePath -> (FilePath -> IO a) -> IO a`
  fetches `ssh_private_key` from the live MinIO Pulumi backend via
  `LiveResidue.fetchPerRunStackOutputs`, writes the PEM body to an
  `openTempFile` path, chmod 600 via `System.Posix.Files.setFileMode`
  (ssh refuses to use private-key files with group/other-readable
  modes), hands the path to the action, and cleans up via
  `Control.Exception.bracket` on all exit paths including async
  exceptions. Throws via `error` when the backend is unreachable or
  `ssh_private_key` is missing / empty.
- `ensureAwsTestSshKey`, `readSshPublicKey`, `awsTestPrivateKeyPath`,
  `awsTestPublicKeyPath`, `awsTestStateDir`, and the
  `testStackPublicKey` field on `AwsTestStackConfig` all deleted. The
  `publicKey` `pulumi config set --secret` entry in
  `syncAwsTestStackConfig` removed — the Pulumi resource owns the
  keypair end-to-end now, so the host no longer pushes a public key
  through stack config.
- Single consumer (`TestValidation.verifyAwsTestSshReachability`)
  rewritten to wrap the per-node SSH retry loop in
  `AwsTest.withAwsTestSshPrivateKey`.
- Unit test `retries AWS test-stack SSH validation until a node accepts
  connections` updated: the mock outputs JSON now includes
  `ssh_private_key`, the pre-migration `.prodbox-state/aws-test/`
  fixture setup is gone.

**Remaining (code-owned)**: none on the code-owned surface. The
`forbidDotProdboxState` lint landed 2026-05-31 (later session) as
`checkForbidDotProdboxState` in `src/Prodbox/CheckCode.hs`, wired into
`haskellStyleViolations`. Scope: scans `src/` + `app/` Haskell string
literals (via `extractStringLiterals`) for the closed `.secrets.json`
cache filename; allowlists `CheckCode.hs` (self-reference) and `test/`
(legitimate regression coverage). Diagnostic names Sprint 3.13 chunks
8–14 as the closure rationale. Three new unit tests cover: fires on an
offending literal, ignores comments, returns `[]` on the current repo
(baseline). The lint is **narrowly scoped** by design — it refuses the
closed `.secrets.json` cache filename, not all `.prodbox-state/*`
writes, because the gateway per-node event-key cache
(`.gateway-event-keys.json` via `resolveGatewayEventKeys`) is still a
legitimate writer pending the daemon self-bootstrap follow-on
described in `Prodbox.Secret.Inventory`. After that follow-on lands,
the lint broadens to refuse any `.prodbox-state/` write path.

**Blocked by**: ~~Sprint 3.13~~ unblocked — Sprint 3.13 chunks 8–14
landed 2026-05-31 and erased every chart-secret cache reference the
lint targets.

**Implementation**: `src/Prodbox/Lib/AwsSubstratePlatform.hs::withTempJsonFile` (system tmp dir; 2026-05-27); `src/Prodbox/CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane` (system tmp dir; 2026-05-27); `src/Prodbox/Lifecycle/LiveResidue.hs` (new `fetchPerRunStackOutputs` + `fetchAwsSesStackOutputs` exports + `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` test override; 2026-05-27); `src/Prodbox/PublicEdge.hs::resolveSubstrateHostedZoneId` (live `subzone_id` read; 2026-05-27); `src/Prodbox/TestValidation.hs::verifyAwsEksSnapshot` (live `cluster_name` + `subnet_ids` read; 2026-05-27); `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestNodesFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/Infra/AwsEksTestStack.hs::parseAwsEksTestStackFromOutputs` (new pure decoder; 2026-05-27 later session); `src/Prodbox/TestValidation.hs::verifyAwsTestSnapshot` + `verifyAwsTestSshReachability` + `fetchAwsTestNodes` (live read; 2026-05-27 later session). Third chunk (2026-05-27 later session): `src/Prodbox/Infra/AwsTestStack.hs::parseAwsTestStackFromOutputs` + `fetchAwsTestSnapshotFromBackend` (full-snapshot live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`nodeToJson`/`awsTestSnapshotPath` removed); `src/Prodbox/Infra/AwsEksTestStack.hs::fetchAwsEksTestSnapshotFromBackend` (live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`optionalString`/`awsEksTestSnapshotPath` removed); `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstratePlatformRuntime` (live read; 2026-05-27 later session). Fourth chunk (2026-05-30): `src/Prodbox/Infra/AwsEksSubzoneStack.hs::parseAwsEksSubzoneStackFromOutputs` + `fetchAwsEksSubzoneStackSnapshotFromBackend` (live read; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`awsEksSubzoneStateDir`/`awsEksSubzoneSnapshotPath` removed; `assertNoAwsEksSubzoneStackResidue` drops the unused `Maybe <Snapshot>` parameter); `src/Prodbox/Infra/AwsSesStack.hs::parseAwsSesStackFromOutputs` + `fetchAwsSesStackSnapshotFromBackend` (live read via long-lived S3 backend; `save`/`load`/`clear`/`snapshotToJson`/`snapshotFromJson`/`awsSesStateDir`/`awsSesSnapshotPath` removed; `assertNoAwsSesStackResidue` drops the unused `Maybe <Snapshot>` parameter). Fifth chunk (2026-05-30): `src/Prodbox/Infra/AwsEksTestStack.hs::withEksKubeconfig` (new `Control.Exception.bracket`-based scoped-temp-file materializer; `materializeAwsEksKubeconfig` + `awsEksTestKubeconfigPath` + `awsEksTestStateDir` removed; `drainAwsEksClusterBeforeDestroy` wraps in `try`); `src/Prodbox/PublicEdge.hs::substrateKubeconfigPath` deleted; `src/Prodbox/PublicEdge.hs::withSubstrateKubectlEnvironment`, `src/Prodbox/CLI/Charts.hs::withSubstrateEnvironment`, `src/Prodbox/TestValidation.hs::withSubstrateKubeconfigEnv` rewritten to wrap their actions in `withEksKubeconfig` on the AWS substrate; `src/Prodbox/CLI/Rke2.hs::buildDrainEnvironment` re-shaped to take a `Maybe FilePath` AWS-kubeconfig parameter, `runCascadeDrainPhase` wraps the AWS drain in `try (withEksKubeconfig ...)` and treats bracket-setup failure as a hard cascade failure. Sixth chunk (2026-05-30): `pulumi/aws-test/Main.yaml` flips SSH-keypair ownership to Pulumi via a new `tls:PrivateKey` resource + `ssh_private_key` secret output (removes the `publicKey` config input); `src/Prodbox/Infra/AwsTestStack.hs::withAwsTestSshPrivateKey` (new `bracket`-based scoped temp file + `setFileMode` chmod 600 materializer reading `ssh_private_key` from the live MinIO backend; `ensureAwsTestSshKey` / `readSshPublicKey` / `awsTestPrivateKeyPath` / `awsTestPublicKeyPath` / `awsTestStateDir` removed; `AwsTestStackConfig` loses `testStackPublicKey`; the `publicKey` `pulumi config set --secret` entry in `syncAwsTestStackConfig` removed); `src/Prodbox/TestValidation.hs::verifyAwsTestSshReachability` wraps the per-node SSH retry loop in `withAwsTestSshPrivateKey`; the `retries AWS test-stack SSH validation` unit test now injects `ssh_private_key` through the `PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` mock.

**Docs to update**: ✅ `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`, ✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (the `forbidDotProdboxState` lint is recorded; the broader `.prodbox-state` removal row stays in Pending Removal under its owning Sprint `3.13`).

### Objective

Finish removing every code-side and config-side `.prodbox-state/` reference. After
this sprint, `grep -rn '\.prodbox-state' src/ app/ test/ charts/ pulumi/ documents/
DEVELOPMENT_PLAN/ README.md CLAUDE.md AGENTS.md` returns zero hits.

### Deliverables

- EKS kubeconfig re-derives on demand via a new
  `Prodbox.Infra.EksKubeconfig.withEksKubeconfig` bracket that materializes a
  `mktemp` file by invoking `aws eks update-kubeconfig` and cleans up on exit.
- HA-RKE2 validation SSH key: read from
  `pulumi stack output --show-secrets ssh_private_key` into a `mktemp` file scoped
  to the validation run; old `.prodbox-state/aws-test/id_ed25519{,.pub}` paths
  removed from the source tree.
- Custom-image tarball at
  `/tmp/prodbox-custom-image-<run-id>.tar` instead of
  `.prodbox-state/tmp/prodbox-custom-image.tar`; caller `bracket`s the cleanup.
- New `prodbox dev lint files` rule `forbidDotProdboxState` in
  `src/Prodbox/CheckCode.hs` refuses any `.prodbox-state/*` write in source.
  Allowlist accepts only the legacy-tracking ledger references and historical
  sprint blocks.
- `.gitignore`, `CLAUDE.md`, and `prodbox.cabal` cleaned of `.prodbox-state/`
  references.
- Final grep gate: `! grep -rn '\.prodbox-state' src/ app/ test/ charts/ pulumi/
  documents/ DEVELOPMENT_PLAN/ README.md CLAUDE.md AGENTS.md` returns zero hits.

### Validation

1. `prodbox dev check` exit 0 (the new lint rule fires on any future
   regression).
2. `prodbox dev docs check` exit 0.
3. `prodbox test unit` exit 0.
4. `prodbox test integration cli` + `prodbox test integration env` exit 0.
5. Live verification: the four-block end-to-end run from the approved plan Part 3
   exercises every preserved-data + recovery-escape-hatch + original-failure-mode
   path.

### Remaining Work

None on the sprint-owned surface. Part 3 of the approved plan rolls up the end-to-
end verification.

## Sprint 4.19: `rke2 delete` Fails Closed When Per-Run Pulumi State Is Unreachable ✅

**Status**: Done on the code-owned surface (2026-05-28). Live verification via
`prodbox rke2 delete --yes` against an intentionally-unreachable per-run backend
on this host is the residual operator gate.

**Implementation**: `src/Prodbox/Lifecycle/ResidueStatus.hs::isResiduePresentOrUnknownPerRun`
(realigned to its name — now `isResiduePresent s || isResidueUnreachable s`, fail-closed
on unreachable); `src/Prodbox/Lifecycle/Preconditions.hs::noLivePerRunPulumiStacks` (branches
on the `ResidueStatus` constructor; new `perRunSummaryLine` / `renderPerRunRefusal` emit a
distinct, actionable refusal for the unreachable case); `src/Prodbox/Aws.hs::categorizePulumiResidue`
(per-run unreachable now counts as blocking residue for `aws teardown`);
`src/Prodbox/Lifecycle/LiveResidue.hs` (new test-only `PRODBOX_TEST_RESIDUE_UNREACHABLE`
override + `perRunUnreachableTriple`, symmetric to `PRODBOX_TEST_RESIDUE_ABSENT`).

**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3 layer 1
gate-vs-cascade asymmetry; §4 `noLivePerRunPulumiStacks` row), ✅ this file,
✅ `DEVELOPMENT_PLAN/README.md`.

### Objective

`prodbox rke2 delete --yes` must not report a clean per-run AWS teardown when it could not
read the authoritative per-run Pulumi state. Previously the gate treated
`ResidueUnreachable` (in-cluster MinIO state backend unreachable) the same as
`ResidueAbsent` and passed silently. On a degraded cluster (MinIO pod down, per-run state
still intact on `.data/`) the operator then ran the documented `rm .data` "start from
scratch" action on the strength of that false "clean" signal — destroying the only record
of still-live AWS resources and orphaning them permanently. The defect: the gate equated
*unreadable state* with *no resources*.

### Deliverables

> **Historical behavior:** the cascade exception recorded below is superseded by the reopened
> always-run cleanup design. Target cleanup may continue independent backstops after an
> unobservable checkpoint, but it retains a failed/unresolved outcome and never recodes it as
> absent; Sprints `4.48`, `5.18`, and `5.19` own that replacement and proof.

- The per-run delete gate (`noLivePerRunPulumiStacks`, used by `prodbox rke2 delete`
  default and `prodbox aws teardown`) **fails closed on `ResidueUnreachable`** with a
  distinct refusal: "cannot read the per-run Pulumi state backend (MinIO) … the per-run
  state may still be intact on `.data/` — do NOT delete `.data/` until it is confirmed
  destroyed … or re-run with `--allow-pulumi-residue` to accept the orphan risk."
- `ResiduePresent` keeps the existing "live resources — destroy first / `--cascade`"
  refusal. `ResidueAbsent` still passes.
- The `--cascade` path is **unchanged**: its own `perRunCascadeInventory` deliberately
  treats per-run unreachable as absent (the cluster is being torn down regardless, with
  the postflight tag sweep as backstop). The deliberate gate-vs-cascade asymmetry is
  documented in `lifecycle_reconciliation_doctrine.md` §3.
- `--allow-pulumi-residue` remains the explicit escape — turning a silent pass into an
  explicit, acknowledged operator decision.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` 578/578 (helper test asserts unreachable → blocking; the
   `categorizePulumiResidue` unreachable-per-run test now expects a refusal list; 3 new
   tests pin the refusal messages).
3. `prodbox test integration cli` 30/30 — two new tests: `rke2 delete --yes` with an
   unreachable per-run backend exits `ExitFailure 1` with the new message and **does not**
   print "Deleting local RKE2 environment…"; `--allow-pulumi-residue` still proceeds.
   `prodbox test integration env` 30/30.
4. Live (residual): `prodbox rke2 delete --yes` on this host with no reachable
   cluster/MinIO refuses loudly instead of reporting clean.

### Remaining Work

Live operator verification on this host (run the 4.19 binary against an unreachable
per-run backend and confirm `rke2 delete --yes` refuses). No remaining code-owned work
on the sprint surface.

### Follow-up: IAM-orphan residual class (2026-05-28)

A read-only AWS sweep after a live `rke2 delete --yes` confirmed the per-run leak was
confined entirely to **IAM** (no orphan EKS/EC2/VPC/ELB/NAT/EBS/OIDC residue): the
`aws-eks-test-aws-lb-controller` policy, three EKS roles (`clusterRole-*`/`nodeRole-*`),
and the operational `prodbox` IAM user, accumulated across runs dated 2026-04-25 →
2026-05-28. These were removed by the then-bounded operator escape hatch (targeted
`aws iam` deletes) and a re-sweep confirmed only the retained `prodbox-admin-temp`,
`prodbox-ses-smtp`, and the operator-owned Route 53 zone remain. The current harness
preflight now owns only the fixed-name `aws-eks-test-aws-lb-controller` policy/role and
`aws-eks-test-ebs-csi-driver` role when the authoritative `aws-eks-test` Pulumi
checkpoint is absent; broad IAM scanning remains deliberately unsupported. Documented as
a residual class in [substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes)
and [lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md).

## Sprint 4.20: Managed-Resource Registry Foundation + Soundness ✅

**Status**: Done on the code-owned surface (2026-05-28). Behavior-preserving and
fully static-validatable; no live re-run needed (the registry is not yet wired into a
teardown reconciler — that is Sprint 4.21 — so teardown behavior is unchanged).
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (new),
`src/Prodbox/Lifecycle/ResidueStatus.hs` (`residueBlocksTeardownGate`),
`src/Prodbox/Aws.hs` (derived `perRunStackNames`/`longLivedStackNames`; `categorizePulumiResidue`),
`src/Prodbox/Lifecycle/Preconditions.hs` (`noLiveLongLivedPulumiStacks`)
**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1, SSoT),
✅ `DEVELOPMENT_PLAN/substrates.md`, ✅ `DEVELOPMENT_PLAN/system-components.md`,
✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Introduce the single source of truth for "everything prodbox can create, and how to observe
and destroy it" — the typed managed-resource registry that the
[reconciler-with-predicates doctrine § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
prescribes. This generalizes the per-stack residue model (Sprint 4.16), the predicate library
(Sprint 4.11), and the fail-closed gate (Sprint 4.19) into one pattern; those sprints stay
`Done` and become instances of it.

### Deliverables (landed)

- New low-level `Prodbox.Lifecycle.ResourceClass` — `LifecycleClass (PerRun | LongLived |
  Operational)` plus the pure SSoT facts `resourceLifecycleClasses :: [(String, LifecycleClass)]`
  (the per-run stacks, `aws-ses`, and the two registered operational resources) and
  `resourceNamesOfClass`. Kept dependency-light so it sits below `Prodbox.Aws` /
  `Prodbox.Lifecycle.LiveResidue` without an import cycle.
- `Prodbox.Aws.perRunStackNames` / `longLivedStackNames` are **derived** from the facts by
  class (no hand-maintained literals; a unit test asserts they equal the prior literals).
- A single `Unreachable`-never-passes soundness combinator
  `Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate` (present OR unreachable → block),
  superseding the per-class `isResiduePresentOrUnknown{PerRun,LongLived}` booleans (removed).
  `categorizePulumiResidue` and `noLiveLongLivedPulumiStacks` now use it; the cascade keeps its
  documented graceful-degradation exception.

### Boundary refinement vs. the original plan

The IO-bearing `ManagedResource { resourceDiscover, resourceDestroy }` record and the
`managedResources` registry move to **Sprint 4.21**, where `reconcileAbsent` is their first
consumer — building discover/destroy closures that nothing calls yet would be dead code, and a
naive per-resource discover would regress the per-run port-forward batching that
`queryPerRunResidueStatuses` already does. Sprint 4.20 lands the pure facts + derived lists +
the soundness combinator (the load-bearing, behavior-preserving foundation); 4.21 decorates the
facts with batched discover/destroy and the reconciler. The operational resources are
**registered as class facts** here; their discover/destroy wiring lands with 4.21/7.8.

### Validation

`prodbox dev check` exit 0; `prodbox test unit` 583/583 (6 new registry-facts tests incl.
derived-lists-equal-prior-literals + the `residueBlocksTeardownGate` Present/Absent/Unreachable
table); `prodbox test integration cli` 30/30; `prodbox test integration env` 30/30.

### Remaining Work

None on the sprint-owned surface. The IO registry + reconciler land in Sprint 4.21.

## Sprint 4.21: IO Managed-Resource Registry + `reconcileAbsent` (cascade per-run) ✅

**Status**: Done on the code-owned surface (2026-05-28). Behavior-preserving refactor of the
cascade per-run destroy phase; live cascade smoke passed on this host. The present→destroy
path's full live exercise rolls up with the next AWS-substrate cascade run (operator-driven).
**Implementation**: `src/Prodbox/Lifecycle/ResourceRegistry.hs` (new — `ManagedResource`,
`perRunManagedResources`, `pairPerRunResidue`, `resourcesToDestroy`, `reconcileAbsent`),
`src/Prodbox/CLI/Rke2.hs` (`runNativeDeleteCascade` per-run phase routed through the registry;
`perRunCascadeInventory` removed)
**Docs to update**: ✅ `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1),
✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Land the IO-bearing managed-resource registry and the `reconcileAbsent` teardown reconciler
(§3.1), and route the cascade's per-run destroy phase through them — unifying the per-run
destroy commands into the registry SSoT so 4.22 / 7.8 / nuke can reuse them.

### Deliverables (landed)

- New `Prodbox.Lifecycle.ResourceRegistry`: the IO-bearing `ManagedResource { resourceName,
  resourceClass, resourceDestroy :: FilePath -> IO ExitCode }` record + `perRunManagedResources`
  (the three per-run stacks, destroy = the same `PulumiCommand`s the cascade used), the pure
  `pairPerRunResidue` (pairs each per-run resource with its already-batched `ResidueStatus`,
  preserving the single MinIO port-forward) and `resourcesToDestroy` (the present ones; absent
  skipped; unreachable skipped per the per-run graceful-degradation rule), and `reconcileAbsent`
  (destroy the present resources in canonical order, fail-fast, with the per-run destroy
  narration).
- `runNativeDeleteCascade` step 3 routed through `reconcileAbsent` (behavior-preserving: same
  stacks, same `PulumiCommand`s, same canonical order, same narration). `perRunCascadeInventory`
  + its tests removed in favor of `pairPerRunResidue` / `resourcesToDestroy` / `reconcileAbsent`.

### Boundary note vs. the original plan

The default `rke2 delete` / `aws teardown` stay **refuse-gates** (Sprint 4.19/4.20's
`residueBlocksTeardownGate`), not active reconcilers — making them `reconcileAbsent` would
contradict their gate contract. `reconcileAbsent` is the **active-destroy** engine; this sprint
adopts it in the cascade per-run phase. `aws teardown`'s active-destroy
(`--destroy-pulumi-residue`) and `nuke` adopt it in Sprint 7.8 / a follow-on, where idempotent
re-run of a re-runnable command genuinely pays off.

### Validation

`prodbox dev check` exit 0; `prodbox test unit` 584/584 (new tests: `pairPerRunResidue` order,
`resourcesToDestroy` present/absent/unreachable filtering, `reconcileAbsent` destroy-order +
fail-fast via injected fakes); `prodbox test integration cli` 30/30; `prodbox test integration
env` 30/30. **Live smoke**: `prodbox rke2 delete --cascade --yes` on this (clusterless) host
ran the rewired cascade clean to exit 0 — per-run residue all unreachable → `reconcileAbsent`
emitted "skipped (no live per-run residue)", drain skipped, uninstall + postflight
tag sweep clean. **See the Standard-C correction below: that smoke run proves the rewiring, not
the narration.**

### Correction To This Sprint's Own Live Smoke (Standard C)

**Recorded 2026-08-11.** The Validation paragraph above originally said `reconcileAbsent`
"**correctly** emitted 'skipped (no live per-run residue)'". The word is withdrawn.

The record states its own counter-evidence: the host was **clusterless** and per-run residue was
**all unreachable**. This sprint's own deliverable list says `resourcesToDestroy` keeps "the present
ones; absent skipped; **unreachable skipped** per the per-run graceful-degradation rule" — so
`unreachable` and `absent` take the same branch, and the emitted line is produced by construction on
any unreachable input. Absence was not observed on that run; it was unobservable. Narrating it as
"no live per-run residue" is the inverse of
[lifecycle_reconciliation_doctrine.md § 3](../documents/engineering/lifecycle_reconciliation_doctrine.md)
layer 1, whose heading is *Cleanup continues without lying*.

Two things stand. The **rewiring** this sprint delivered is behaviour-preserving and correct:
`pairPerRunResidue`, `resourcesToDestroy`, and `reconcileAbsent` do destroy the present resources in
canonical order with fail-fast, and the unit cases pinning present/absent/unreachable filtering are
real. And **skipping** the destroy on `unreachable` remains the documented cascade exception. What
was wrong is the *acceptance criterion*: a run in which every input was unobservable was read as
evidence that the observable path behaves correctly, and the narration it produced was recorded as
correct rather than as the thing to fix.

The narration, the substrate inference that also keys off `isResiduePresent`, and the aggregate exit
code are owned by Sprint `4.76` 📋.

### Remaining Work

The present→destroy path's full live exercise (`rke2 delete --cascade` with live per-run
residue) rolls up with the next operator-driven AWS-substrate cascade run, consistent with the
Sprint 4.17.a/4.17.b live closure gates. Note this is the branch the 2026-05-28 smoke run did **not**
exercise, and the correction above records why that matters.

## Sprint 4.22: Registry ↔ Doc Parity Enforcement in `docs check` ✅

**Status**: Done (2026-05-28). The registry ↔ substrates-doc parity is machine-enforced, and
the follow-on create-call-site coverage lint also landed (2026-05-28). **Standard-C correction
(2026-08-11): these do not "complete the § 3.1 totality enforcement" — see the correction below.**
The registered claim is narrowed to what the two scans deliver: no undocumented registry change, and
no unregistered create call site *for the verbs in the allowlist*. See Remaining Work for the
precise — deliberately narrow — surfaces the coverage scan covers.
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (`renderRegisteredResourcesMarkdown`),
`src/Prodbox/CheckCode.hs` (new `resource-lifecycle-classes` `GeneratedSectionRule`; new
`checkCreateCallSiteCoverage` lint with pure helpers `pulumiCreateSiteViolations` /
`pulumiCreateSiteOwners` / `iamCreateSiteViolations` / `iamCreateVerbs`),
`DEVELOPMENT_PLAN/substrates.md` (markers + `**Generated sections**` metadata)
**Docs to update**: ✅ `documents/engineering/code_quality.md`,
✅ `documents/documentation_standards.md` (§11), ✅ `DEVELOPMENT_PLAN/substrates.md`

### Objective

Make the managed-resource registry the **machine-enforced** SSoT for the documented resource
inventory — drift between the code registry and the doc fails the build — the totality
invariant from
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Deliverables (landed)

- The `DEVELOPMENT_PLAN/substrates.md` Resource Lifecycle Classes inventory is a **generated
  section** (`<!-- prodbox:resource-lifecycle-classes:start/end -->`) rendered from
  `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` by the deterministic
  `renderRegisteredResourcesMarkdown`, registered as a `GeneratedSectionRule` in
  `src/Prodbox/CheckCode.hs`. `prodbox dev docs check` fails the build if the doc table drifts from
  the registry; `prodbox dev docs generate` regenerates it. So a resource cannot be added to /
  removed from the registry without the documented inventory updating in lockstep — registry ↔
  doc parity is structurally enforced.

### Validation

`prodbox dev check` exit 0; `prodbox dev docs check` exit 0; `prodbox dev lint docs` exit 0 (markers ↔
`**Generated sections**` metadata agree); `prodbox test unit` 585/585 (renderer test:
`renderRegisteredResourcesMarkdown` emits every registered resource + class).

### Remaining Work

**Landed (2026-05-28): create-call-site coverage lint.** The follow-on hardening — the
create-call-site coverage scan that complements the registry ↔ doc parity — is now in
`check-code` as `checkCreateCallSiteCoverage` (wired into `haskellStyleViolations`). To avoid the
false-positive risk that originally deferred it, the scan is **deliberately narrow**: it covers
only the two surfaces where prodbox actually originates a new AWS/cluster resource, and the
decision logic is factored into pure, unit-tested helpers.

1. **Pulumi stack creation.** Every `Pulumi<Word>Resources` constructor token in
   `src/Prodbox/CLI/Command.hs` (`PulumiEksResources`, `PulumiTestResources`,
   `PulumiAwsSubzoneResources`, `PulumiAwsSesResources`) must map — via the explicit
   `pulumiCreateSiteOwners` table — to a stack name present in the registry's
   `PerRun`/`LongLived` classes. A new creation constructor with no registry entry, or a mapped
   stack name missing from `resourceLifecycleClasses`, fails the lint (`pulumiCreateSiteViolations`).
2. **Operational IAM user creation.** The AWS CLI verbs `create-user`, `create-access-key`,
   `put-user-policy` (`iamCreateVerbs`) may appear only in the `operational-iam-user` owner
   module `src/Prodbox/Aws.hs`. Their appearance in any other `src/Prodbox/**.hs` file fails the
   lint (`iamCreateSiteViolations`). `CheckCode.hs` itself is excluded from the scan so its own
   verb literals do not self-trigger.

**Deliberately out of scope** (would false-positive; not scanned): generic `create*`,
`change-resource-record-sets` (the § 6a bootstrap DNS record), `mc mb`, and
other resource origination that is Pulumi-managed (covered transitively by the stack scan) or
specially-handled. Broadening the scan to arbitrary mutation tokens is what the original
deferral warned against.

### Correction To This Sprint's Own Registration (Standard C)

**Recorded 2026-08-11.** Two statements in this block were wrong, one stale and one over-claimed.

**Stale.** This paragraph listed `create-bucket` as deliberately out of scope. It is *in* the
allowlist, with four owner modules, and Sprint `5.28` later removed the last carve-out
(`awsCreateProbeVerbs`, which had exempted `create-hosted-zone`). The list above is corrected in
place.

**Over-claimed.** The registered text said this sprint, with the parity scan, "completes the § 3.1
**totality** enforcement". `awsCreateVerbs` is a **7-entry substring allowlist** — `create-user`,
`create-access-key`, `put-user-policy`, `create-role`, `put-role-policy`, `create-hosted-zone`,
`create-bucket`. Verbs shelled out elsewhere in `src/` that create or mutate real AWS resources and
are **not** covered include `create-volume` (real billable EBS), `create-receipt-rule-set` (an
account-global resource of which only one may be active), `put-bucket-policy`, `put-object`,
`put-public-access-block`, and `request-service-quota-increase`. The Pulumi half is a
naming-convention scan for `Pulumi<Word>Resources` tokens in one file.

A totality invariant proven over an allowlist drawn to fit the code is not totality — it is a
regression guard on known sites, which is genuinely useful and is what this sprint delivered. The
same paragraph already carried the honest scoping ("on the two scanned surfaces") one sentence after
the totality claim; the two cannot both stand, and the narrower one is correct. This is the
[chaos_hardening_doctrine.md § 22](../documents/engineering/chaos_hardening_doctrine.md) rule — a
ring stated without its region is a claim about a different set of files than the reader assumes —
and the § 3.1 doctrine text carries the matching correction.

The enforcement gap itself is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than reopened here: closing
it means deciding what the registry owes, not widening a substring list.

## Sprint 4.23: Per-Run EKS Destroy Drains the Cluster First (DependencyViolation Fix) ✅

**Status**: Done (2026-05-30) — code-owned surface landed 2026-05-29; live closure confirmed
by `prodbox test all` run #6 on the home substrate. See the **2026-05-30 — live closure**
paragraph at the end of this sprint for the verification.
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs`
(`destroyAwsEksTestStackStatus` now calls the new best-effort helper
`drainAwsEksClusterBeforeDestroy` immediately before `pulumiDestroyEither`; new helper
`buildAwsEksDrainEnv` builds the `KUBECONFIG` + `AWS_*` env-var list mirroring
`Prodbox.CLI.Rke2.buildDrainEnvironment`; reuses
`Prodbox.Lifecycle.K8sDrain.drainAwsAffectingK8sResources` unchanged).
**Docs to update**:
`documents/engineering/lifecycle_reconciliation_doctrine.md` (per-run EKS destroy now drains
first), `DEVELOPMENT_PLAN/README.md`.

### Objective

Close the root cause of the May 28/29 leak incident: the per-run `aws-eks-test` Pulumi destroy
path does **not** drain the EKS cluster's AWS-affecting K8s resources (LoadBalancer Services, ALB
Ingresses, Delete-reclaim PVCs) before `pulumi destroy`, so it races AWS's async ENI cleanup. On
both May 28 and May 29 the live `lifecycle` validation's per-run EKS destroy hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (orphan ENIs from the EKS
cluster's CNI / ELBs lagging async cleanup) after a 20-minute wait.

Sprint 4.17.b already gave the `prodbox rke2 delete --cascade` path a substrate-aware drain
(`runCascadeDrainPhase` + `buildDrainEnvironment` in `src/Prodbox/CLI/Rke2.hs`), but the
**per-run `pulumi eks-destroy` path** — which the harness postflight
(`prodbox pulumi eks-destroy --yes` from `awsPostflightDestroyActions`) goes through — did not.
This sprint extends Sprint 4.17.b's drain to that per-run destroy path.

### The fix

Inject the drain into the eks-destroy path itself
(`AwsEksTestStack.destroyAwsEksTestStackStatus`), immediately before the `pulumi destroy` and
after operational credentials are resolved. Because **both** the harness postflight
(`prodbox pulumi eks-destroy --yes`) and the cascade
(`Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route through
`destroyAwsEksTestStack`, injecting the drain there covers both. The drain targets the per-run
EKS cluster's own kubeconfig (`.prodbox-state/aws-eks-test/kubeconfig`, materialized during
`ensureAwsEksTestStackResources` per Sprint 4.18) — not the host substrate's cluster — with
`AWS_*` projected from the already-resolved operational `Credentials` (with the
admin-simulation fallback from `loadOperationalAwsCredentials`).

Best-effort + safe-on-unreachable, scoped to the EKS stack:

- If the EKS kubeconfig file is **absent** (e.g. the stack is already partially gone, or a
  standalone `prodbox pulumi eks-destroy --yes` ran in a process that never materialized it),
  the drain is skipped with a diagnostic and the destroy proceeds.
- `drainAwsAffectingK8sResources` probes reachability first, so an unreachable-but-present
  kubeconfig yields `DrainSkipped` and the destroy proceeds.
- A drain **failure** or **timeout** NEVER hard-fails the destroy — the destroy is the goal; the
  worst case is the pre-4.23 behavior (race AWS's async ENI cleanup, possibly `DependencyViolation`,
  which Sprint 7.10 then preserves operational creds for so the orphans can be destroyed on
  retry).
- Only the EKS stack (`aws-eks-test`) gets the drain; the `aws-test` / `aws-eks-subzone` stacks
  are not EKS clusters (no in-cluster K8s to drain).

### Limitation

The drain reuses the on-disk EKS kubeconfig rather than re-materializing it from the backend
snapshot (which would add a MinIO-backend round-trip just to drain). Within a single
`prodbox test all` run the kubeconfig is present (bootstrap → validations → postflight destroy),
so the harness postflight path drains. A standalone `prodbox pulumi eks-destroy --yes` in a
fresh process that never ran the ensure step finds no kubeconfig and skips the drain (then
destroys) — the smallest safe version. The full DependencyViolation-free guarantee is therefore
established only for the harness-driven path (and the cascade, when the kubeconfig is present);
the live closure gate confirms it end-to-end.

### Validation

Fast gates (no live AWS):

- `prodbox dev check` → exit 0.
- `prodbox test unit` → all pass.
- `prodbox test integration cli` / `env` → exit 0 each.
- `prodbox dev docs check` / `prodbox dev lint docs` → exit 0.

### Remaining Work

- **Live closure gate (deferred):** a full `prodbox test all` whose per-run `aws-eks-test`
  destroy succeeds without `DependencyViolation` on subnet deletion. This is a flaky live-AWS
  behavior dependent on AWS's async ENI cleanup timing and is not fast-gate-validatable.

**2026-05-30 — live closure (sprint Done).** `prodbox test all` run #6
on the home substrate closed the live gate. The `lifecycle` validation
passed (it had failed in run #3 with `DependencyViolation` on subnet
deletion). The drain ran live — the validation body logged
`Per-run EKS drain (cluster=aws-eks-test-cluster): deleting LoadBalancer
Services...` — and the subsequent `pulumi destroy` succeeded.
Post-run AWS state was verified clean: operational `aws.*` empty,
zero EKS / VPCs / EC2, only the retained admin-managed IAM users
(`prodbox-admin-temp`, `prodbox-ses-smtp`) remained. The full
`prodbox test all` roll-up: 16/17 green (only `keycloak-invite`
failed, a known Sprint 8.5 operator-driven gap, unrelated to this
sprint).

## Sprint 4.24: Public-Edge Production Certificate Registered as a LongLived Managed Resource ✅

**Status**: Done (2026-06-07 on the code-owned surface)
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs`
(`("public-edge-tls", LongLived)` in `resourceLifecycleClasses`),
`src/Prodbox/Lifecycle/ResourceRegistry.hs` (`longLivedManagedResources` +
the `destroyPublicEdgeTlsCertificate` adapter),
`src/Prodbox/Lifecycle/LiveResidue.hs` (`queryPublicEdgeTlsResidueStatus`
`discover`, `destroyRetainedPublicEdgeTls`, the pure
`residueStatusFromObjectListing`, and the `publicEdgeTlsResourceName` /
`publicEdgeTlsRetentionPrefix` constants),
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (the shared S3 access path:
`listLongLivedObjectKeysUnderPrefix`, `purgeLongLivedObjectsUnderPrefix`,
`parseObjectKeysPayload`, and a prefix-aware `listVersionsPage`),
`src/Prodbox/Lifecycle/Preconditions.hs` (the `noLiveLongLivedPulumiStacks`
gate now also discovers the certificate)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`DEVELOPMENT_PLAN/substrates.md`

### Objective

Register the public-edge production TLS certificate — specifically its retained material in the
long-lived `pulumi_state_backend` S3 bucket — as a typed `ManagedResource` with
`discover`/`destroy`, classified **LongLived** in `resourceLifecycleClasses` (the same class as
`aws-ses`). This reclassifies the cert from disposable `PerRun` chart state to a rate-limited
external resource, so `prodbox dev check` totality
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md))
covers it and it is never auto-destroyed by `prodbox rke2 delete` or `prodbox aws teardown` —
only by `prodbox nuke` or an explicit destroy. The registration follows the
`lifecycle_reconciliation_doctrine.md § 3.1` totality + soundness pattern.

### Deliverables

- New `ManagedResource` entry for the retained public-edge production certificate
  (`longLivedManagedResources` in `ResourceRegistry.hs`, with the
  `destroyPublicEdgeTlsCertificate` adapter onto the `FilePath -> IO ExitCode`
  `resourceDestroy` shape). ✅
- `LongLived` membership for the certificate in `resourceLifecycleClasses` (declared after
  `aws-ses`). ✅
- `discover` (`queryPublicEdgeTlsResidueStatus`) queries the long-lived S3 store for objects
  under the `public-edge-tls/` prefix and returns a distinct not-present versus unreachable
  outcome via the pure `residueStatusFromObjectListing`: present → `ResiduePresent`, none →
  `ResidueAbsent`, a missing backend bucket → `ResidueAbsent` (the authoritative
  nothing-to-destroy during total teardown, mirroring `residueStatusFromS3Listing`), any other
  S3 failure → `ResidueUnreachable`. `Unreachable → refuse` holds through the single
  `residueBlocksTeardownGate` soundness combinator; it is never silently treated as absent. ✅
- `destroy` (`destroyRetainedPublicEdgeTls` → `purgeLongLivedObjectsUnderPrefix`) removes every
  retained object under the prefix; idempotent (a missing bucket / empty prefix is `Right ()`). ✅
- The generated `substrates.md` Resource Lifecycle Classes table re-renders (via
  `prodbox dev docs generate`) to include `| `public-edge-tls` | LongLived |`. ✅
- `prodbox dev check` create-site/totality coverage of the new resource — the registry entry
  flows into `resourceNamesOfClass LongLived` and the `checkCreateCallSiteCoverage` lint; the
  certificate is correctly *not* a Pulumi create site (S3-object class), so no
  `pulumiCreateSiteOwners` entry is required. ✅

The certificate is classified the same as `aws-ses`: never reconciled by `prodbox rke2 delete`
or `prodbox aws teardown` (neither touches the `LongLived` class), and removed only by
`prodbox nuke` (transitively, when nuke step 5 destroys the whole long-lived
`pulumi_state_backend` bucket) or by the explicit registered `destroy`. The shared S3
object-level access path added to `LongLivedPulumiBackend.hs` is the foundation that Sprint
`7.11` extends with the substrate-scoped write/key scheme.

### Validation

Closure gates (passed 2026-06-07):

1. `./.build/prodbox dev check` → exit `0`.
2. `./.build/prodbox test unit` → `682/682` (the new
   `Sprint 4.24 retained public-edge TLS certificate managed resource` describe block adds
   8 tests: registry entry + class, name ↔ constant parity, retention-prefix value, and the
   four-way `residueStatusFromObjectListing` present/absent/missing-bucket/unreachable
   discrimination — including `residueBlocksTeardownGate` on the unreachable case — plus the
   `parseObjectKeysPayload` JSON-shape decode). The existing Sprint 4.20 / 7.7 registry tests
   were updated for the new `LongLived` member.
3. `./.build/prodbox dev docs check` → exit `0` (generated lifecycle-class table parity, now
   including the certificate row).
4. `./.build/prodbox dev lint docs` → exit `0`.

`prodbox test integration cli` / `env` were also run; the two failures observed in this
environment (`CliSuite.hs:256` / `:376`, both `charts deploy vscode` fake-environment flows)
reproduce identically on the pre-Sprint-4.24 tree and are unrelated to this sprint — the
`charts deploy` command path imports none of the modules this sprint changed.

### Remaining Work

The live production round-trip (issue once → retain → cluster wipe → rebuild → restore, no
re-order) is exercised under Phase 8 Sprint `8.8`.

## Sprint 4.25: `rke2 delete` Is a No-Op Success When No RKE2 Cluster Is Installed ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `README.md`, `CLAUDE.md`

### Objective

Stop `prodbox rke2 delete` from refusing with the Sprint `4.19` fail-closed residue gate
("the per-run Pulumi state backend could not be read … cannot confirm destroyed") when the RKE2
cluster — and with it the in-cluster MinIO state backend — is **already entirely gone**. The
gate alone cannot distinguish "MinIO transiently unreachable while a cluster still exists" from
"no cluster at all", so deleting an already-deleted cluster wrongly exits `1`. When there is no
cluster there is nothing to delete: report `No RKE2 cluster to delete.` and exit `0`.

### Deliverables

- `rke2InstallPresent` (+ `rke2InstallMarkers`, `noRke2ClusterMessage`) in
  `src/Prodbox/CLI/Rke2.hs`: probe the on-disk RKE2 install markers (`/usr/local/bin/rke2`,
  `/usr/local/bin/rke2-uninstall.sh`, `/var/lib/rancher/rke2`, `/etc/rancher/rke2`).
- A no-install short-circuit at the `Rke2Delete` dispatch that precedes the residue gate and the
  cascade, applied uniformly to the default, `--cascade`, and `--allow-pulumi-residue` forms.
- Keyed off **install** state, not service state: an installed-but-stopped RKE2 still has a
  cluster and per-run state on disk and so still flows through the full gate / cascade (the
  Sprint `4.19` fail-closed behavior is preserved unchanged).
- `PRODBOX_TEST_RKE2_PRESENT` test seam (mirrors `PRODBOX_TEST_RESIDUE_*`); `fakeRke2Environment`
  defaults it to `1` so every existing gate/cascade test is unchanged.
- Integration tests (default + `--cascade`) proving the no-op success even when residue reports
  `ResidueUnreachable`.
- Doctrine § 5a documents the carve-out as a no-op short-circuit, categorically distinct from a
  `Precondition`, and explicitly **not** a relaxation of the fail-closed gate.

### Validation

1. `prodbox dev check` exits `0`.
2. `prodbox test unit` and `prodbox test integration cli` pass, including the unchanged
   Sprint `4.19` gate tests and the new no-cluster tests.
3. `prodbox dev docs check` confirms doc parity.
4. Live: `prodbox rke2 delete --yes` (and `--cascade`) on a host with no RKE2 install prints
   `No RKE2 cluster to delete.` and exits `0`, leaving `.data/` untouched.

### Remaining Work

None — the change is self-contained to the `rke2 delete` dispatch plus its tests and docs.

## Sprint 4.26: Route the Destructive Commands Through `runPlanWithOptions` ✅

**Status**: Done (2026-06-09). `rke2 delete` (default + `--cascade`) and `nuke` now route through
`runPlanWithOptions` — `--dry-run` renders the full destructive plan and exits 0 with **zero**
mutation (the audit's #1 bug: `Rke2Delete flags _planOptions` discarded its options and silently
destroyed), `--plan-file` writes it, and `nuke` now reads `nukePlanFile`. The new
`checkPlanOptionsHonored` lint (in `runDoctrineAlignmentCheck`, proven to fire) forbids a destructive
dispatch arm from binding its `PlanOptions`/`NukeOptions` to a `_` wildcard. The default-delete
per-run sweep is now derived from `perRunManagedResources` (closing the `aws-eks-subzone` omission;
`resourceDestroyCommand` added so the registry is the SSoT for both the destroy and the operator
command string). `nuke` step-4 tag sweep is fail-closed (aborts non-zero before the bucket destroy).
`noLiveLongLivedPulumiStacks` is wired into the operator `aws teardown` preflight (via DI to avoid a
`Preconditions`→`Aws` cycle; the harness `BypassAllResidueForHarnessRefresh` paths are untouched, so
Sprint 7.9's aws-ses relaxation is intact). `categorizePulumiResidue` was retired in favor of the
registry-derived residue path (behavior-preserving). The refuse-gate vs reconciler split is
preserved. The cascade order (drain → destroys) was left untouched. Validation green: `check-code` 0,
`test unit` 790, `integration cli` 35, `lint docs` 0, `docs check` 0. The live destructive cascade is
operator-driven.
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Nuke.hs`,
`src/Prodbox/Native.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Lifecycle/Preconditions.hs`,
`src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs` (recommended)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`

### Objective

Make `--dry-run` and `--plan-file` honored on the destructive arms — `prodbox rke2 delete`
(default and `--cascade`) and `prodbox nuke` — by routing them through the same
`runPlanWithOptions` Plan / Apply entrypoint the reconcile path already uses
([pure_fp_standards.md#8-plan--apply](../documents/engineering/pure_fp_standards.md#8-plan--apply),
Sprint 1.7), close two correctness gaps the audit surfaced (the default-delete sweep omitting
`aws-eks-subzone`; the nuke step-4 tag sweep treating a failed sweep as success), and add a lint
that keeps the wiring honest. The refuse-gate vs reconciler split stays intact: the default
`rke2 delete` and `aws teardown` remain refuse-gates (they refuse on live residue rather than
reconcile it); only `--cascade` reconciles
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).

### Deliverables

- `prodbox rke2 delete` (default + `--cascade`) and `prodbox nuke` dispatch through
  `runPlanWithOptions` so `--dry-run` renders the full destructive plan and exits `0` without
  mutation, and `--plan-file` writes the rendered plan. `prodbox nuke` reads its `nukePlanFile`
  field (today threaded into `NukeOptions` but unread).
- A `checkPlanOptionsHonored` lint in `src/Prodbox/CheckCode.hs` forbids any destructive dispatch
  arm from binding its `PlanOptions` to a `_` wildcard, so a future destructive command cannot
  silently drop `--dry-run` / `--plan-file`. Registered in the `prodbox dev check` lint stack
  ([code_quality.md](../documents/engineering/code_quality.md)).
- The default-delete per-run sweep is derived from `perRunManagedResources` rather than a
  hand-maintained stack list, closing the `aws-eks-subzone` omission (the registry is already the
  SSoT for the per-run class after Sprint `4.21`).
- The `prodbox nuke` step-4 tag sweep fails **closed**: a tag-sweep error aborts nuke with an
  actionable error instead of best-effort-continuing, matching the
  [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  "cannot observe is never silently absent" rule for the total-teardown path.
- `noLiveLongLivedPulumiStacks` is wired into the `aws teardown` preflight (completing the
  Sprint `4.11` deferred consolidation note), so `aws teardown` refuses on a live long-lived stack
  the same way it refuses on live per-run stacks.
- `storage_lifecycle_doctrine.md` §5 cascade order: **already corrected in Sprint 0.9** to the
  canonical sequence — confirm-MinIO → **K8s drain → per-run Pulumi destroys** → RKE2 uninstall →
  postflight tag sweep (DRAIN BEFORE DESTROYS, matching
  [lifecycle_reconciliation_doctrine.md §5b](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  and the landed Sprint `4.17.a` reorder). This sprint left it untouched. (An earlier draft of this
  bullet stated the inverted destroys-before-drain order; that was a typo — destroys-before-drain is
  the fatal `DependencyViolation` sequence, NOT canonical.)
- `categorizePulumiResidue` is retired in favor of the registry-derived residue path
  (`perRunManagedResources` + `pairPerRunResidue`), removing the parallel hand-maintained
  classifier the registry now subsumes.

### Validation

1. `prodbox dev check` exits `0`, including the new `checkPlanOptionsHonored` lint.
2. `prodbox test unit` covers the registry-derived default-delete sweep (asserting
   `aws-eks-subzone` is included), the nuke step-4 fail-closed branch, and the
   `noLiveLongLivedPulumiStacks` `aws teardown` preflight composition.
3. `prodbox test integration cli` covers `--dry-run` / `--plan-file` snapshots for
   `rke2 delete`, `rke2 delete --cascade`, and `nuke` (the three destructive `--dry-run` goldens
   are authored under Sprint `5.6`).
4. `prodbox dev docs check` confirms parity for the corrected `storage_lifecycle_doctrine.md` §5
   cascade order.

### Remaining Work

None — closed 2026-06-09. All deliverables landed; the refuse-gate vs reconciler split is preserved
(default `rke2 delete`/`aws teardown` refuse, only `--cascade` reconciles). The live destructive
cascade against a real cluster/AWS is operator-driven.

## Sprint 4.27: `StackDescriptor` SSoT and AWS Create-Site Generalization ✅

**Status**: Done (2026-06-09). New `src/Prodbox/Infra/StackDescriptor.hs` holds the
`StackDescriptor {stackRegistryName, stackPulumiStackId, stackProjectSubdir, stackCliVerb,
stackLifecycleClass}` SSoT and the single `stackDescriptors` list (recording the `aws-eks`
registry-name vs `aws-eks-test` Pulumi-stack-id difference); the per-run name list (`perRunStackNames`),
CLI verbs, and project subdirs are now DERIVED from it (a unit test pins the derived list equal to
both the prior literal and the `PerRun` registry slice). A new `stack-command-surface`
`GeneratedSectionRule` renders the registry-name↔CLI-command table into `substrates.md` (the typed
source Sprints `0.10`/`5.6` consume). `requireRoute53LifecycleCapability` now wraps its create→delete
probe in `bracketOnError` so the throwaway proof zone is always deleted on a mid-probe exception
(audit C66); it stays unregistered (no steady state) and keeps the create-site lint carve-out.
`iamCreateSiteViolations` was generalized to `awsCreateSiteViolations` (IAM verbs + `create-bucket`,
matching the quoted-arg form; `create-hosted-zone` carved out for the probe). `longLivedStackNames`
was renamed to `longLivedResourceNames` (still derived from the `LongLived` registry class, so it
keeps the non-stack `public-edge-tls` cert). Validation green: `check-code` 0, `test unit` 802/802,
`docs generate`→`docs check` 0, `integration cli` 35/35, `lint docs` 0. The live Route 53
`bracketOnError` cleanup exercise is operator-driven.
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`src/Prodbox/CheckCode.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Dns.hs`,
`test/unit/Main.hs` (recommended)
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Collapse the several hand-maintained parallel lists describing each Pulumi-managed stack
(registry name, Pulumi stack id, project subdir, CLI verb, lifecycle class) into one
`StackDescriptor` SSoT record, and generalize the IAM-specific create-site lint into an
AWS-wide one. This removes the drift risk the documentation-harmony audit flagged between the
registry names, the CLI verbs, and the project directories, and feeds the
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
registry totality from a single typed source.

### Deliverables

- A `StackDescriptor` record (`registryName`, `pulumiStackId`, `projectSubdir`, `cliVerb`,
  `lifecycleClass`) in `src/Prodbox/Aws.hs` (or a dedicated `Prodbox.Infra.StackDescriptor`
  module) as the SSoT for the Pulumi-managed substrate stacks. The per-run / long-lived name
  lists, the CLI verbs, and the project dirs are **derived** from `[StackDescriptor]` rather than
  hand-maintained.
- A generated registry-name↔CLI-command doc section (a `prodbox dev docs generate` marker block)
  driven by `[StackDescriptor]`; this is the typed source Sprint `0.10` consumes for the
  registry-name↔CLI-verb list and Sprint `5.6` consumes for registry-generated golden coverage.
- The Route 53 capability-proof create→delete is wrapped in `bracketOnError` so a failure after
  the probe record is created always deletes it. It is deliberately **not** registered as a
  `ManagedResource`: the capability probe has no steady state to discover or reconcile, so the
  § 3.1 totality registry stays correct without it.
- `iamCreateSiteViolations` is generalized into `awsCreateSiteViolations` in
  `src/Prodbox/CheckCode.hs` so the create-site lint covers every AWS-resource create call site,
  not only IAM.
- `longLivedStackNames` is renamed to `longLivedResourceNames` (the long-lived class now spans
  more than Pulumi stacks — it includes the public-edge production certificate from Sprint
  `4.24`), with all call sites and the `Prodbox.Lifecycle.Preconditions` /
  `Prodbox.Aws` references updated.

### Validation

1. `prodbox dev check` exits `0`, including the generalized `awsCreateSiteViolations` lint.
2. `prodbox test unit` covers the `StackDescriptor`-derived name lists (per-run / long-lived
   parity with the registry), the CLI-verb derivation, and the renamed `longLivedResourceNames`.
3. `prodbox dev docs check` confirms the generated registry-name↔CLI-command section round-trips.
4. The Route 53 capability-proof `bracketOnError` cleanup is exercised by the
   `prodbox test integration public-dns` (or `aws-iam`) flow, proving the probe record is deleted
   even on a mid-probe failure.

### Remaining Work

None — closed 2026-06-09. All deliverables landed; the Route 53 capability proof was correctly left
**unregistered** (no steady state). The live `bracketOnError` cleanup exercise is operator-driven.

## Sprint 4.29: Vault Lifecycle Integration and Durable Vault PV Preservation ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/Vault/Status.hs`, `src/Prodbox/Host.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Fold Vault — the sole, finalized secrets/KMS/PKI root — into the canonical cluster lifecycle:
reconcile deploys and unseals it on the init-once / unseal-on-rebuild contract, teardown preserves
its durable PV, and a sealed Vault is a first-class fail-closed cluster status (vault_doctrine §5,
§7, §15). Because Vault is the only secrets backend, a sealed Vault means no secret resolves, no
cert issues, no MinIO object decrypts, and no secret-dependent reconcile step proceeds. The
retained-PV teardown model is extended, not reversed.

### Deliverables

- `prodbox cluster reconcile` deploys/rebinds Vault before MinIO/chart reconcile, runs `vault init`
  **exactly once, ever** (only when the durable PV is empty), and on every subsequent reconcile
  redeploys the Vault chart against existing data and only **unseals** it from the `.age` unlock
  bundle (or prompts) — no re-init and no key regeneration. **[Superseded by Sprint 7.19/7.25:** the
  unlock bundle is a password-AEAD (Argon2id + ChaCha20-Poly1305) object in the durable MinIO bucket,
  not an on-disk `.age` file — see [config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model).**]** A cluster rebuild is not a fresh Vault.
- `prodbox cluster delete --yes` and `--cascade --yes` both preserve the durable Vault PV
  (`.data/vault/vault/0`) exactly like the MinIO PV; neither ordinary delete form removes it.
  Total decommission through `prodbox nuke` is the explicit exception. Vault KV is as durable
  across `cluster delete` + `cluster reconcile` rebuild cycles as any retained PV.
- `prodbox cluster status` / `prodbox edge status` surface Vault sealed/unsealed/uninitialized as a
  first-class line.
- Lifecycle commands gain absolute fail-closed readiness gates: a sealed, unreachable, or
  uninitialized Vault refuses every secret-dependent reconcile step rather than reconstructing any
  secret from a non-Vault source (the master-seed HMAC derivation model is retired, not wrapped).

### Validation

- `cabal build --builddir=.build exe:prodbox` passed, and `.build/prodbox` was refreshed.
- `./.build/prodbox test unit` passed 908/908. Coverage pins the rendered Vault seal-status line
  and the cluster-reconcile plan steps that install Vault before MinIO.
- `./.build/prodbox test integration cli` passed 34/34. Coverage proves the fake RKE2 harness
  emits the Vault status line, waits for `statefulset/vault`, and installs the Vault chart before
  the MinIO chart during `cluster reconcile`.
- Generated CLI docs/goldens were refreshed through the docs generator and the CLI golden harness.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`,
  and `./.build/prodbox dev check` passed after the plan and doctrine updates.

### Remaining Work

None for Sprint `4.29`. Metadata hardening + the red-team sweep land in Sprint `4.30`; the
federated child-cluster auto-unseal and the fail-closed unseal cascade close in Sprint `4.32`.

## Sprint 4.30: Model B Object-Store and MinIO Sealed-State Red-Team ✅

**Status**: Done
**Implementation**: `src/Prodbox/Minio/ObjectStore.hs`, `src/Prodbox/Minio/EncryptedObject.hs`, `src/Prodbox/Crypto/Envelope.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Config/InForce/Core.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Secret/VaultInventory.hs`, `pulumi/aws-*/Main.yaml`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Build the **Model B object-store** so a sealed Vault reduces every prodbox-owned MinIO bucket to an
opaque, durable ciphertext pile that leaks nothing about the cluster's children — not whether it has
any, how many, where, or what, down to object/key names like `aws`/`aws-eks`. The encryption
strategy is the prodbox application-level Vault-Transit envelope per object (Model B), not MinIO
bucket server-side encryption: content encryption alone leaves object names, prefixes, counts,
sizes, and bucket names as plaintext metadata, but the fail-closed invariant is an
*existence/metadata* property, not just a content property
([vault_doctrine.md §9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)).
Because prodbox owns the layer, naming, indexing, and padding live in the same trusted, Vault-bound
code path that does the encryption. Every prodbox-owned object (the in-force cluster config, gateway
state, Pulumi backend state, checkpoints, indexes) is a `prodbox-envelope-v2` Vault-Transit envelope.

### Deliverables

- `src/Prodbox/Minio/ObjectStore.hs` is the typed opaque-name S3 surface (`ensureObjectStoreBucket`
  / `putObject` / `getObject` → `Maybe` / `putIfAbsent` / `listKeys` / `deleteObject`) that
  consolidates the object-store `aws s3api` arg-builders, reuses `minioAwsEnv`
  (`src/Prodbox/Infra/MinioBackend.hs`), verifies the generic bucket before writes, and stages only
  already-enveloped object bytes in a scoped temporary handoff.
- `src/Prodbox/Minio/EncryptedObject.hs` (new) exposes `putLogical` / `getLogical` over a
  `LogicalObject` (`InForceConfig | GatewayState | PulumiStack <id> | DownstreamCluster <id>`) and
  enforces the five Model B rules
  ([vault_doctrine.md §9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)):
  - **Vault-keyed-HMAC opaque IDs.** Every object is stored at `objects/<vault-keyed-HMAC>.enc`
    under one flat prefix; the opaque ID is a deterministic, directly addressable,
    index-loss-tolerant HMAC of the logical name, with the MAC key held in Vault KV
    (`vaultKvReadV2`) so a sealed Vault cannot recompute or invert the logical→`objects/<id>.enc`
    mapping. The name carries no signal — not the object's role, not a downstream cluster, not a
    Pulumi stack identity.
  - **`prodbox-envelope-v2` hashed AAD.** `src/Prodbox/Crypto/Envelope.hs` stores
    `base64(SHA256(aad))` in the object body (never the cleartext binding) and carries
    `transit_key` / `created_at` / `key_version` fields; the earlier `prodbox-envelope-v1` wrote a
    literal `base64("clusterId|objectName")` — e.g. `aws-eks` — into the body, a metadata leak even
    while sealed. Open still re-supplies the real AAD via `expectedAad`, so binding strength is
    unchanged; only the stored form is hashed.
  - **Vault-encrypted index.** The id↔logical map lives in `indexes/*.enc`, themselves envelopes; a
    sealed Vault reveals only the opaque IDs, with logical meaning recoverable only once unsealed
    and policy allows the read.
  - **Decoy-pad to a constant object count + size buckets.** A fixed decoy pool keeps a sealed-Vault
    `list-objects` count constant, and object bodies are padded to a small set of fixed size buckets
    so a length histogram reveals nothing.
- The store is parameterized on a `DekCipher` so unit tests use `insecureLocalDekCipher` with no
  live Vault, and the production binding is the Sprint `1.37` `Prodbox.Vault.TransitCipher`.
- **One generically-named bucket.** All prodbox-owned secret-bearing state collapses into a single,
  generically-named bucket; the role-revealing bucket names `prodbox` +
  `prodbox-test-pulumi-backends` are retired, so a bucket-level `s3api ls` carries no signal. (Harbor's
  public image layers stay a separate, non-secret store — the §13 public class, not enveloped.)
- **One object-store, shared across host and daemon accessors.** The pure
  envelope / HMAC-naming / index / decoy layer is identical for both accessors; they differ only in
  the bound Vault-auth `DekCipher` and MinIO transport. The host CLI binds a Transit `DekCipher` via
  the root Vault token and reaches MinIO through `withMinioPortForward`; the in-cluster daemon
  accessor uses the same `EncryptedObject` layer with its own Vault Kubernetes-auth cipher and MinIO
  transport when it has a durable object to read or write. The current gateway daemon keeps its
  runtime state in memory and has no durable MinIO state writer left to migrate in Sprint `4.30`.
- **On-disk consequence.** The hostPath PV that backs MinIO (`.data/prodbox/minio/0`;
  [storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md)) therefore
  holds **only opaque-named ciphertext** — `objects/<hmac>.enc` and `indexes/*.enc` at a constant
  count, with no plaintext name, body, or count distinguishing a real object from a decoy.
- The in-force config production read now routes through the object-store: `Settings` reads the
  Vault-owned object-store HMAC key at `secret/object-store/hmac`, computes the opaque key for
  `LogicalInForceConfig`, fetches from the `prodbox-state` bucket, and then decrypts with the
  Sprint `1.37` Vault-Transit `DekCipher`. The pre-Model-B literal
  `active-config/in-force-config.prodbox-envelope-v1` MinIO helpers are removed from the supported
  backend API.
- The MinIO red-team checklist
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) is
  exercised for the MinIO + on-disk surfaces; Sprint `4.33` gates the Haskell-side host-disk / k8s /
  log residue/oracle surfaces and the Pulumi backend remains Sprint `7.14`.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the object-store integration.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "Model B object store"'`
  passes 9/9, proving the shared generic bucket, typed object-store bucket commands,
  `prodbox-envelope-v2` hashed-AAD non-leak (the object body never contains `aws-eks`),
  HMAC opaque-id determinism, AAD fail-closed behavior, index encode/decode, and the decoy key pool.
- `./.build/prodbox test unit` passes 918/918 and `./.build/prodbox test integration cli` passes
  36/36 after the Model-B object-store integration.
- Source search shows no surviving supported-path `prodbox-test-pulumi-backends`,
  `active-config/in-force-config`, `inForceConfigObjectKey`, or
  `Prodbox.Infra.MinioBackend.fetchInForceConfig` / `storeInForceConfig`; remaining old-name hits
  are historical documentation or negative regression assertions.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
  `./.build/prodbox dev lint chart`, and the full `./.build/prodbox dev check` pass.

### Remaining Work

- None on Sprint `4.30`'s owned surface. The raw Pulumi checkpoint interposition remains Sprint
  `7.14`; the Haskell-side host-disk / Kubernetes / log surfaces and exists-vs-`NoSuchKey` oracle
  are now gated by Sprint `4.33`; cross-surface live sealed-Vault validation remains Sprint `5.8`.

## Sprint 4.31: Unified Deterministic Retained-Storage Topology ✅

**Status**: Done
**Implementation**: `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Naming.hs`, `charts/minio/`, `charts/vscode/`, `charts/vault/`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Collapse every retained PersistentVolume onto one deterministic host-path scheme —
`.data/<namespace>/<StatefulSet>/<replica-index>` — provisioned by a single reconciler, and make
every stateful workload a StatefulSet so every retained PVC is a `volumeClaimTemplate` claim. This
refines the canonical retained-storage paths; it extends, it does not reverse, the Sprint `3.1`
storage-binding model or the retained-PV teardown contract.

### Deliverables

- `storageBinding` (`src/Prodbox/Lib/Storage.hs`) produces `.data/<namespace>/<StatefulSet>/<ordinal>`
  with no per-host machine-id prefix and no `<release>` / `<claim>` path segment; the deterministic
  PV name derives from `(namespace, statefulset, ordinal)` via
  `Prodbox.Naming.boundedResourceName` through the shared
  `retainedStatefulSetPersistentVolumeName` helper.
- The retained-storage reconciler now walks a typed always-on inventory for MinIO and Vault:
  deterministic PVs + `claimRef`-bound StatefulSet PVCs, host paths
  `.data/prodbox/minio/0` and `.data/vault/vault/0`, and non-root `uid:gid` ownership
  (`1000:1000` for MinIO, `100:100` for Vault). Patroni and `vscode` use the same
  `storageBinding` identity and host-path scheme through their chart release storage specs.
- MinIO moves off the bitnami standalone Deployment to a prodbox-owned `charts/minio/` single-replica
  StatefulSet (mirroring `charts/vault/`); PVC `data-minio-0` → `.data/prodbox/minio/0`. MinIO keeps
  the **public** `quay.io/minio/minio` image at steady state (never the Harbor mirror): it is Harbor's
  own storage backend, so it cannot source its image from Harbor, and unlike the surge-capable bitnami
  Deployment a single-replica StatefulSet cannot break that circular dependency (a Harbor-sourced image
  deadlocks — MinIO down → Harbor 500 → MinIO `ImagePullBackOff`). See
  [local_registry_pipeline.md](../documents/engineering/local_registry_pipeline.md) step 13.
- `vscode` moves from a Deployment to a single-replica StatefulSet; PVC `data-vscode-0` →
  `.data/vscode/vscode/0`.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the retained-storage identity refactor.
- Focused units pass: `cabal test --builddir=.build test:prodbox-unit --test-options='-p
  "deterministic storage bindings"'` (1/1) and `cabal test --builddir=.build test:prodbox-unit
  --test-options='-p "vscode deployment plans"'` (1/1).
- `./.build/prodbox test unit` passes 918/918.
- `./.build/prodbox test integration cli` passes 36/36, including the fake-kubectl
  `cluster reconcile` retained-storage manifest proof (`prodbox-retained-prodbox-minio-0`,
  `prodbox-retained-vault-vault-0`, `data-minio-0`, `data-vault-0`) and the chart delete proof for
  `vscode` / Patroni PV cleanup under the `prodbox-retained-<namespace>-<statefulset>-<ordinal>`
  naming scheme.
- Source search shows no surviving supported-path old PV names
  (`prodbox-minio-pv-0`, `prodbox-vault-pv-0`,
  `prodbox-chart-vscode-vscode-vscode-0-data`) outside historical legacy-ledger prose.
- `./.build/prodbox dev lint haskell --write` passes with no HLint hints; `./.build/prodbox dev
  docs check`, `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and
  `./.build/prodbox dev check` also pass.

### Remaining Work

- None on Sprint `4.31`'s owned surface. The federated child lifecycle closes in Sprint `4.32`, the
  Haskell-side sealed-state scrub closes in Sprint `4.33`, and the live whole-system sealed-state
  proof remains Sprint `5.8`.

## Sprint 4.32: Federated Lifecycle Reconcile and Fail-Closed Unseal Cascade ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lifecycle/FederatedVault.hs`, `src/Prodbox/Vault/Client.hs`, `src/Prodbox/Cluster/Federation.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/Secret/VaultInventory.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cluster_federation_doctrine.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`

**Closure update (2026-06-16)**: the code-owned federated lifecycle surface has landed. The parent
registration apply path now requires a ready parent root Vault plus `--child-vault-address` and
`--child-kubeconfig`, reads the Vault-owned federation HMAC key, ensures the per-child Transit key,
writes the scoped child token policy, creates the child transit-seal token, records child metadata
under the parent's KV, and applies the child-side `vault/vault-transit-seal-token` Secret without
printing the token. `cluster reconcile` resolves root vs child lifecycle from unencrypted basics:
root clusters keep the Shamir unlock-bundle lifecycle, while child clusters verify parent Vault
readiness, require the parent-provisioned transit-seal token Secret, render the Vault chart with
`seal "transit"`, initialize exactly once with recovery shares, write child init custody back to the
parent's KV, and reuse the parent-custodied child root token for later Vault reconcile and
post-MinIO in-force-config reads. The lifecycle settings order is split so bootstrap-only steps use
repo-root Dhall only until Vault and MinIO are reachable, then reload the in-force settings through
Vault/MinIO before chart and edge work continues.

### Objective

Wire the Vault transit-seal trust tree (Sprint `3.20`) into the canonical cluster lifecycle so a
child cluster's `cluster reconcile` auto-unseals against its parent, the init-once / unseal-on-rebuild
contract holds across the whole hierarchy, and a sealed-or-unreachable parent fail-closed-bricks its
children — the cascade rooted in one operator unsealing the root cluster
([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
Mutating the root cluster's in-force config — the keys to the kingdom for every downstream cluster —
is gated on the root Vault token (vault_doctrine §11; config_doctrine §6.2).

### Deliverables

- A **child** cluster's `prodbox cluster reconcile` deploys Vault with `seal "transit"` pointed at
  the parent cluster's Vault and auto-unseals against it — no human, no local unseal keys. A child
  Vault that cannot reach a live, unsealed parent fails reconcile closed with a clear safe error.
- The init-once / unseal-on-rebuild contract (Sprint `4.29`) holds per cluster across the tree: at
  child init the child's recovery keys + initial root token are stored in the parent's Vault KV and
  the parent's transit key is the child's unseal authority; on every subsequent child rebuild Vault
  only auto-unseals against the parent.
- The fail-closed brick cascade is enforced: a sealed/unreachable parent means its children cannot
  unseal, so the whole subtree refuses secret-dependent work — cluster liveness for the tree roots
  in the operator unsealing the root Vault.
- Reads of a cluster's unencrypted basics (cluster id, this cluster's Vault address, seal mode, and —
  for a child — the parent reference it contacts to auto-unseal) stay free; full in-force config
  reads require an unsealed Vault; **writes to the root cluster's in-force config require the root
  Vault token**, wired into the lifecycle so a non-root token cannot mutate root config.

### Validation

- `cabal build --builddir=.build exe:prodbox` passes after the federated lifecycle and settings
  loader changes.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "federated Vault lifecycle"'`
  passes 3/3, including root/child lifecycle classification, child Transit Helm args, and
  sealed/unreachable parent fail-closed rendering.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "cluster federation custody"'`
  passes 8/8, including live-registration readiness rendering and the scoped child seal policy.
- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 4.32"'` passes
  1/1 against the built frontend, fake Vault, and fake kubectl, proving live parent registration
  writes the parent-side surfaces and does not print the child token.
- `./.build/prodbox test unit` passes 923/923.
- `./.build/prodbox test integration cli` passes 37/37, including the Sprint `4.32` registration
  proof and the existing native RKE2 reconcile regression surface.
- `./.build/prodbox dev check` exits 0 after the final Sprint `4.32` docs alignment.
- The live two-cluster auto-unseal and sealed-root subtree-brick proof remains operator-driven and
  is carried by the canonical sealed-Vault validation in Sprint `5.8`.

### Remaining Work

- None on Sprint `4.32`'s code-owned lifecycle surface. The gateway-mediated child listing /
  bootstrap-reference surface is closed by Sprint `2.26`; Sprint `4.33` has closed the
  Haskell-side sealed-state gate/redaction/opaque-namespace audit surface; the live sealed-Vault
  federation proof remains Sprint `5.8`.

## Sprint 4.33: Whole-System Sealed-State Scrub: On-Disk, Kubernetes, and Log Surfaces ✅

**Status**: Done (2026-06-16, code-owned Haskell sealed-state scrub surface)
**Implementation**: `src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/StackOutputs.hs`, `src/Prodbox/Infra/LongLivedPulumiBackend.hs`, `src/Prodbox/Lifecycle/`, `src/Prodbox/Vault/`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/streaming_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

### Objective

Close the remaining surfaces of the whole-system zero-child-info invariant beyond the MinIO object
bodies that Sprint `4.30` sealed: the host disk, Kubernetes objects, and logs/output. The fail-closed
invariant is a whole-system *existence/metadata* property — when the parent cluster's Vault is sealed
it must be impossible to extract any information about its children across **every** surface, not just
object bodies
([vault_doctrine.md §9 — Whole-system zero-child-info](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store)).
This sprint scrubs the residue-query oracle, the log/output sites, and the Kubernetes object surfaces
so a sealed-Vault combined dump (bucket listing + host-disk walk + ConfigMap/Secret dump + log audit)
yields only `objects/<hmac>.enc` at a constant count and no exists-vs-absent oracle.

### Deliverables

- **Residue-query gating behind the Vault-readiness check.** The MinIO residue discriminators —
  `LiveResidue.residueStatusFromMinioListing`, the `bucketObjectCount` count, and the
  `isAwsCliNoSuchKeyMessage` / `stackPresentInList` exists-vs-absent discriminators — are gated behind
  the Vault-readiness check from Sprint `1.37`, so a sealed-state query for whether a given logical
  object is present never distinguishes "present" from "absent" in its output or error. Presence
  itself is metadata; the exists-vs-`NoSuchKey` oracle is closed
  ([vault_doctrine.md §14](../documents/engineering/vault_doctrine.md#14-error-model-and-logging)).
- **Structured-log / output redaction + redacted `Show`.** Opaque-id and Vault-token types carry a
  redacted `Show` so an opaque ID or token never reaches a log through an incidental `show`; the
  diagnostic sites in `MinioBackend.hs`, `LongLivedPulumiBackend.hs`, `LiveResidue.hs`, and
  `StackOutputs.hs` emit the redacted structured form (`vault_status=sealed component=… result=…`)
  rather than a logical name, a Pulumi stack identity (`aws-eks`), a child-cluster name, or a real
  object count on a sealed path
  ([streaming_doctrine.md](../documents/engineering/streaming_doctrine.md)).
- **Opaque Kubernetes namespaces + downstream-identity-to-Vault-KV audit.** No ConfigMap, Secret,
  namespace name, or other k8s object encodes a downstream-cluster name; child-named namespaces use
  opaque IDs, and downstream kubeconfig/identity is custodied in the parent's Vault KV
  (`secret/clusters/<child-id>/*`), never a k8s Secret. This deliverable is co-owned with the
  federation surfaces in Sprint `4.32`
  ([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
  [vault_doctrine.md §16](../documents/engineering/vault_doctrine.md#16-cluster-federation-a-vault-transit-seal-trust-tree)).
- **Cross-surface red-team.** The sealed-Vault combined sweep — bucket-level `s3api ls` +
  `list-objects` + host-disk walk of `.data/prodbox/minio/0` + k8s ConfigMap/Secret dump + log audit —
  is exercised and reveals only `objects/<hmac>.enc` at a constant count: no role-revealing bucket
  name, no `aws-eks`/stack-name key, no cleartext body, no child-named namespace, and no
  exists-vs-absent oracle
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)).

### Current State

- `queryPerRunResidueStatuses`, `queryAwsSesResidueStatus`, and
  `queryPublicEdgeTlsResidueStatus` consult the host Vault seal-status gate before interpreting
  Pulumi/S3 listings. When Vault is sealed, uninitialized, or unreachable, the query returns one
  uniform `ResidueUnreachable (ResidueQueryFailed "vault_status=... component=residue-query
  result=unobservable")` value and does not expose a stack name, object name, object count, or
  present-vs-absent result.
- `getLongLivedObject` now consults the same gate before classifying `NoSuchKey` for the retained
  public-edge cert object. A blocked gate returns
  `vault_status=... component=long-lived-object result=unobservable` instead of revealing the S3
  key's presence or absence.
- `VaultToken`, `ChildInitCustody`, and `ChildBootstrapCredential` have redacted `Show` instances so
  root/child tokens and recovery keys do not leak through incidental debug rendering.
- The opaque namespace derivation remains `childVaultNamespace`, and the child bootstrap token is
  held in parent Vault KV plus the child-side generic `vault/vault-transit-seal-token` Secret rather
  than a child-named Kubernetes namespace or downstream-identity Secret.

### Validation

- A sealed-state residue query distinguishes neither "present" from "absent" nor a real from a
  decoy-padded object count in its output or error.
- A `prodbox test unit` redaction proof asserts the redacted `Show` for opaque-id / token types and
  that the gated diagnostic sites emit no logical name on a sealed path.
- `cabal build --builddir=.build exe:prodbox` passes.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "Sprint 4.33"'` passes 4/4.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "LiveResidue"'` passes 19/19.
- `./.build/prodbox dev lint haskell --write` reports no hints.
- `./.build/prodbox test unit` passes 928/928.
- `./.build/prodbox test integration cli` passes 38/38.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, and `git diff --check`
  exit 0.
- `./.build/prodbox dev check` exits 0 after the final Sprint `4.33` implementation validation.

### Remaining Work

- None on Sprint `4.33`'s code-owned Haskell sealed-state scrub surface. The live cross-surface
  red-team is exercised alongside the sealed-Vault canonical validation (Sprint `5.8`), gated on
  the deployed Vault. Raw Pulumi checkpoint decrypt-to-scratch interposition remains Sprint `7.14`.

## Sprint 4.34: Autoscaler Runtime & Federation-Scoped Multi-Cluster Placement ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Scaling/Autoscaler.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the pure
autoscaler reconciler and the trust-tree placement-constraint solver, plus `prodbox test integration
cli`/`env` on the home/local substrate with placement targets stubbed to the local cluster — no
later-phase dependency.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/cluster_federation_doctrine.md`

### Objective

Run prodbox itself as the autoscaler reconciler over the capacity type per
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md), constraining
multi-cluster placement to the federation trust tree
([cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md)) so scaling
never perturbs gateway leadership.

### Deliverables

- `src/Prodbox/Scaling/` hosts the prodbox-as-autoscaler reconciler over the typed capacity value on
  the doctrine's check-before-mutate shape.
- Multi-cluster placement candidates are constrained to the federation trust tree; a target outside the
  trust subtree is rejected as inadmissible.
- Scaling actions are ordered so they never disturb the current gateway leader — leadership is preserved
  across scale-up and scale-down.
- `src/Prodbox/Lifecycle/ResourceRegistry.hs` exposes the capacity-scaled resources through the
  managed-resource registry.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `prodbox test unit` (1102/1102; autoscaler planner, trust-tree placement, capacity refusal,
   leader-preserving scale-down, action ordering, and registry exposure)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev check`

### Remaining Work

- None on the Sprint `4.34` code-owned planner surface. Live multi-cluster placement across a
  deployed federation trust tree is a non-blocking `Live-proof: pending` note.

## Sprint 4.35: Pulsar Topics as Managed Resources ✅

**Status**: ✅ Done on code-owned surface 2026-07-03
**Implementation**: `src/Prodbox/Pulsar/Topic.hs`, `src/Prodbox/Pulsar/TopicResidue.hs`, `src/Prodbox/Lifecycle/ResourceClass.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`
**Blocked by**: none — Sprint `3.21` has landed the repo-owned Haskell broker transport/framing.
**Live-proof**: proven 2026-07-03 via `./.build/prodbox test integration pulsar-broker`
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the typed
three-valued broker discover, typed ensure/delete adapters, `ResidueStatus` projection, dynamic
topic-family `LifecycleClass` assignment, and managed-resource destroy adapter, plus `prodbox test
integration cli`/`env` on the home/local substrate with the broker stubbed, plus the live
`pulsar-broker` validation proving broker-backed ensure/discover/delete — no later-phase dependency.
**Docs to update**: `documents/engineering/pulsar_topic_lifecycle_doctrine.md`

### Objective

Register Pulsar topics in the managed-resource registry as first-class typed resources per
[pulsar_topic_lifecycle_doctrine.md](../documents/engineering/pulsar_topic_lifecycle_doctrine.md), so a
topic reconciles present/absent through the same § 3.1 registry totality + soundness pattern as every
other managed resource.

### Deliverables

- ✅ `src/Prodbox/Pulsar/TopicResidue.hs` provides a typed three-valued broker `discover`
  (present / absent / cannot-observe) so "cannot observe" is never silently treated as "absent",
  plus the total projection onto `ResidueStatus`.
- ✅ Typed `ensureTopic` and `deleteTopic` adapters make present/absent reconciliation explicit and
  idempotent at the broker boundary.
- ✅ `src/Prodbox/Lifecycle.ResourceClass` registers dynamic topic-family rows:
  `pulsar-topics-per-run` and `pulsar-topics-long-lived`.
- ✅ `src/Prodbox/Lifecycle/ResourceRegistry.hs` exposes `pulsarTopicManagedResource`, which adapts
  a concrete algebra-derived `ManagedTopic` into the shared managed-resource destroy surface.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror` exit 0.
2. `cabal test --builddir=.build test:prodbox-unit` exit 0 (1157/1157), covering the three-valued
   discover, `ResidueStatus` projection, typed ensure/delete adapters, and registry entry.
3. `./.build/prodbox dev docs generate` exit 0, regenerating the Resource Lifecycle Classes table.
4. `./.build/prodbox test integration cli` exit 0 (39/39).
5. `./.build/prodbox test integration env` exit 0 (39/39).
6. `./.build/prodbox test integration pulsar-broker` exit 0 (2026-07-03): the validation deployed
   the internal Pulsar chart, created and discovered a `persistent://public/default/` validation
   topic through the admin-backed `PulsarTopicBroker`, produced/consumed/acked a CBOR message, then
   deleted the topic and verified broker-backed absence.

### Remaining Work

None.

## Sprint 4.36: Tiered-Storage Budget DSL + Region-Quota Gate + ML Storage Budget ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Capacity/Storage.hs`, `src/Prodbox/Aws.hs`, `test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
finite-budget capacity reconciler, the region service-quota preflight, and the ML storage-budget totals,
plus `prodbox test integration cli` on the home/local substrate with AWS quota calls stubbed — no
later-phase dependency.
**Docs to update**: `documents/engineering/tiered_storage_capacity_doctrine.md`

### Objective

Implement the finite-budget capacity reconciler, the per-deploy AWS region service-quota preflight, and
the mandatory ML-engine storage budget per
[tiered_storage_capacity_doctrine.md](../documents/engineering/tiered_storage_capacity_doctrine.md).

### Deliverables

- `src/Prodbox/Capacity/` carries a finite-budget capacity DSL with no `Infinite` constructor; MinIO
  unbounded is admissible only when accompanied by an autoscaling-policy witness.
- The per-deploy AWS region service-quota preflight reuses `Prodbox.Aws`'s `applyAwsCheckQuotas` /
  `ensureServiceQuota` so a deploy fails fast when a region quota is insufficient.
- The mandatory ML-engine JIT + model-cache storage budget (host + cluster) is a required input to the
  capacity reconciler.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1106/1106, covering the finite-budget type (no `Infinite`), the
   MinIO-unbounded witness rule, ML storage-budget totals, and insufficient stubbed AWS quota
   refusal.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.
6. `prodbox dev docs check` passed.
7. `git diff --check` passed.
8. `prodbox dev check` passed.

### Remaining Work

- None on the Sprint `4.36` code-owned capacity surface. Live AWS region service-quota checks
  against live AWS credentials are a non-blocking
  `Live-proof: pending` note.

## Sprint 4.37: Lima/WSL2/Incus Provisioning + Native-Arch Build Extension ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Host/Ensure.hs`, `src/Prodbox/DockerConfig.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
host-provider selection, the VM ensure reconcilers, and the Docker host-frame gate, plus
`prodbox test integration cli`/`env` on the home/local (Linux/Incus) substrate with foreign-OS providers
stubbed — no later-phase dependency.
**Docs to update**: `documents/engineering/host_platform_doctrine.md`,
`documents/engineering/local_registry_pipeline.md`

### Objective

Provision the host-provider VM per OS — Lima on macOS, WSL2 on Windows, Incus/native on Linux — and run
the native-host-arch image build inside the OS-appropriate Linux frame per
[host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md).

### Deliverables

- `src/Prodbox/Host/` selects the host provider by OS and provides idempotent VM `ensure` reconcilers
  (Lima / WSL2 / Incus/native).
- `src/Prodbox/DockerConfig.hs` extends the existing rule-j host-frame Docker gate so a Windows host
  builds through its WSL2 Linux frame and a macOS host builds through its Lima Linux frame.
- Native-host-arch image build runs inside the OS-appropriate Linux frame, extending the native-arch,
  no-cross-arch-emulation publication contract from Sprint `4.1`.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1110/1110, covering host-provider reconciler selection,
   ready/missing/reboot decisions, wrong-provider fail-fast refusal, and Docker Linux-frame
   dispatch through native Linux, Lima, and WSL2.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.

### Remaining Work

- None on the Sprint `4.37` code-owned host-provider surface. Live macOS-Lima and Windows-WSL2
  provisioning proofs on those hosts are non-blocking
  `Live-proof: pending` notes.

## Sprint 4.38: Substrate-Typed Worker Placement & One-Per-Machine Anti-Affinity ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Cluster/Placement.hs`, `src/Prodbox/Cluster/Topology.hs`,
`test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: Validated on its owned code surface — `prodbox test unit` over the
anti-affinity placement solver and the mixed-substrate admissibility rule, plus `prodbox test
integration cli` on the home/local (rke2) substrate — no later-phase dependency.
**Docs to update**: `documents/engineering/cluster_topology_doctrine.md`

### Objective

Place exactly one substrate-typed compute worker per machine per
[cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md): node
anti-affinity with `maxSurge: 0`, and mixed-substrate placement admissible only on `rke2`.

### Deliverables

- `src/Prodbox/Cluster/Placement.hs` derives one substrate-typed compute worker per machine using node
  anti-affinity and a `maxSurge: 0` rollout so no two workers co-locate.
- A worker carries its substrate type in the placement so a mismatched-substrate worker is rejected.
- Mixed-substrate placement is admissible only on the `rke2` substrate; every other substrate rejects a
  mixed placement.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1114/1114, covering one-worker-per-machine placement, required
   hostname anti-affinity, `maxSurge = 0`, duplicate-machine refusal, wrong-substrate worker
   refusal, and the mixed-substrate-only-`rke2` rule.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.

### Remaining Work

- None on the Sprint `4.38` code-owned placement surface. Live multi-machine anti-affinity proof on
  a multi-node deployed cluster is a non-blocking
  `Live-proof: pending` note.

## Sprint 4.39: Pre-Created EBS Volumes as a Registered Managed Resource ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/Lifecycle/ResourceClass.hs` (the historical single
`aws-ebs-volumes` `LongLived` registry entry, split by Sprint `4.84`),
`src/Prodbox/Lifecycle/EbsVolume.hs` (typed EC2
`discover`/`destroy` boundary plus pure JSON/residue adapters),
`src/Prodbox/Lifecycle/TagSweep.hs` (retain-vs-test-scoped markers and EBS tag
partitioning), `src/Prodbox/CLI/Rke2.hs` (substrate-aware retained-inventory projection),
`test/unit/Main.hs`.
**Blocked by**: none — extends the Sprint `4.20`/`4.22` managed-resource registry and the Sprint
`4.24` `LongLived`/`PerRun` classification.
**Live-proof**: pending (the live EKS static-PV materialization and suite postflight EBS reaper are
owned by Sprints `7.28`, `4.40`, and `5.12`; non-blocking per Standard O)
**Independent Validation**: pure unit tests over the EBS discover/destroy decision matrix and the
retain-vs-test-scoped tag partitioning; the generated `resource-lifecycle-classes` table
(`substrates.md`) regenerates from the new registry entry via `prodbox dev docs generate`. No
later-phase dependency.
**Docs to update**: `lifecycle_reconciliation_doctrine.md`, `storage_lifecycle_doctrine.md`,
`substrates.md`, `system-components.md`.

### Objective

Make the pre-created EBS volumes that back the EKS static `Retain` PVs (Sprint `7.28`) a
first-class managed resource with a typed `discover`/`destroy` pair and a lifecycle class, per
[lifecycle_reconciliation_doctrine.md § 1](../documents/engineering/lifecycle_reconciliation_doctrine.md)
and the "no new AWS resource type without a registry entry" rule in
[substrates.md](substrates.md). Encode the production-retain vs test-delete policy in the tag
markers.

### Deliverables

- An EBS-volume entry in `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` with typed
  `discover` (`ec2 describe-volumes` filtered by ownership tag) and `destroy` (`ec2 delete-volume`),
  through the harness AWS subprocess layer (never ad-hoc `aws`).
- Tag markers distinguishing retained production EBS (a long-lived retention marker recognized by
  `isRetainedLongLived`/`partitionRetainedLongLived`) from test-scoped EBS
  (`prodbox.io/lifecycle=per-run-test` plus `kubernetes.io/cluster/<name>: owned`).
- Retained-inventory parity: the same deterministic PV/claim names reconciled on AWS as on home,
  through `retainedStorageInventoryEntries SubstrateAws`, which projects the same retained
  namespace/PV/PVC identities as `SubstrateHomeLocal`.
- The generated `resource-lifecycle-classes` table in `substrates.md` regenerated via
  `prodbox dev docs generate`.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` (1095/1095; EBS discover/destroy decision matrix, retained-inventory parity,
   and retain-vs-test-scoped partitioning)
4. `prodbox dev docs generate` (regenerated the `resource-lifecycle-classes` table)
5. `prodbox dev docs check` (generated `resource-lifecycle-classes` table matches the registry)
6. `prodbox test integration cli` (39/39)
7. `prodbox test integration env` (39/39)
8. `prodbox dev check`

### Remaining Work

- None on Sprint `4.39`'s historical tag-partition surface. Its one
  `aws-ebs-volumes :: LongLived` registry identity did **not** make the test-scoped family
  statically `PerRun`; Sprint `4.84` closed that correction on 2026-08-17 by replacing the one
  identity with distinct test-scoped and production-retained EBS identities whose classes are
  selected before provider observation. Sprint `4.40` owns the historical suite postflight reaper, and Sprint
  `7.28` owns live static EBS PV materialization on EKS.

## Sprint 4.40: Suite Postflight Test-EBS Reaper + Retain-Safe Drain ✅

**Status**: ✅ Done
**Implementation**: `src/Prodbox/TestRunner.hs` (`awsPostflightDestroyActions` — a test-EBS reaper
step after the stack destroys), `src/Prodbox/CLI/Rke2.hs` (`--cascade` reaper hook + standalone
`aws ebs reap-test --yes` entrypoint), `src/Prodbox/Lifecycle/EbsVolume.hs` (typed reaper plan and
runner), `src/Prodbox/Lifecycle/K8sDrain.hs` (confirm `Retain` EBS PVs survive the drain),
`src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Native.hs`,
`test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/unit/Parser.hs`, and golden CLI/plan
fixtures.
**Live-proof**: pending
**Independent Validation**: pure unit tests over the reaper's test-scoped-only selection (a
retained-tagged volume is never selected; a test-scoped volume is), the idempotent no-op when
nothing matches, and the retain-safe `Delete`-reclaim drain selector; CLI/env integration runs
exercise the native command surface and fake-tool postflight path. Live-EKS proof that a suite
postflight leaves zero `available` test-scoped EBS volumes rides Sprint `5.12` on the AWS substrate
(Standards N/O).
**Docs to update**: `lifecycle_reconciliation_doctrine.md`, `storage_lifecycle_doctrine.md`,
`substrates.md`.

### Objective

Close the EBS-leak class that motivated this work: cluster/stack teardown RETAINS EBS (production
semantics), while the test harness deletes only test-scoped EBS at suite postflight. The `Retain`
EBS PVs survive the K8s drain (which deletes only `Delete`-reclaim PVCs), and the reaper runs on
every suite exit path (success/failure/Ctrl-C).

### Deliverables

- A test-EBS reaper step in `awsPostflightDestroyActions` that, after the per-run stack destroys,
  deletes only volumes tagged test-scoped (via the Sprint `4.39` discover/destroy), under the
  existing `runWithAwsHarnessCleanup` wrapper so it fires on success, failure, and Ctrl-C.
- A `cluster delete --cascade` reaper hook and `prodbox aws ebs reap-test --yes` standalone
  entrypoint so already-leaked test volumes can be swept on demand; production teardown never
  invokes the reaper.
- Confirmation (and a guard) that `Retain` EBS PVs are not deleted by the drain; the drain's
  `Delete`-reclaim PVC step is a generic safety net only.

### Validation

1. `cabal build --builddir=.build exe:prodbox`
2. `cabal build --builddir=.build all --ghc-options=-Werror`
3. `prodbox test unit` passed 1123/1123, covering reaper test-scoped-only selection,
   retained-production exclusion, idempotent no-op, report rendering, parser/command-surface
   coverage, and the `Delete`-only drain selector.
4. `prodbox test integration cli` passed 39/39.
5. `prodbox test integration env` passed 39/39.
6. `prodbox dev docs check`
7. `git diff --check`
8. `prodbox dev check`
9. Leak check (Standard O, live): after a suite postflight, `aws ec2 describe-volumes --filters
   Name=status,Values=available` returns zero test-scoped volumes; a production-mode teardown
   retains durable EBS.

### Remaining Work

- None on the Sprint `4.40` code-owned surface. The live EKS postflight leak check remains a
  non-blocking `Live-proof: pending` axis owned by Sprint `5.12`/AWS substrate parity.

## Sprint 4.41: RKE2 Host Guardrails and Observed-Capacity Refusal [✅ Done]

**Status**: Done (2026-07-04)
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Capacity/Config.hs`,
`src/Prodbox/Host.hs`, `src/Prodbox/Subprocess.hs`, `test/unit/Main.hs`,
`test/integration/CliSuite.hs`
**Live-proof**: pending — on a real local host, prove allocatable cpu/memory/ephemeral-storage are
below physical capacity by the configured reservations and an over-limit pod is OOMKilled/evicted
without starving host SSH/network availability.
**Independent Validation**: pure unit tests over rendered RKE2 config fragments, systemd drop-in
plans, observed-host-capacity comparison, and refusal cases; CLI integration with fake host probes
and fake filesystem/systemctl/kubectl boundaries proves no live cluster is required.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/host_platform_doctrine.md`

### Objective

Make the local RKE2 lifecycle enforce the resource plan at the host boundary. The host should stay
responsive even when a prodbox workload leaks memory: Kubernetes should OOM/evict the offending pod
inside declared limits, and RKE2 should never schedule into the host's reserved survival margin.

### Deliverables

- `cluster reconcile` observes host cpu, RAM, node filesystem capacity, and image filesystem
  capacity, then compares those observations against the authored `HostCapacity`. If observed
  capacity is lower, reconcile refuses before mutating the cluster.
- RKE2 config rendering writes a prodbox-owned config fragment for `kubelet-arg` values:
  `system-reserved`, `kube-reserved`, `eviction-hard`, `eviction-soft`,
  `eviction-soft-grace-period`, image-garbage-collection thresholds, and container log caps.
- The rendered kubelet reservations satisfy the Sprint `1.55` lemma
  `rke2.reserved + eviction.floor <= host.physical`.
- A systemd drop-in plan for `rke2-server.service` sets bounded `CPUQuota`, `MemoryHigh`,
  `MemoryMax`, `TasksMax`, and accounting options for the RKE2 process tree. The doctrine notes
  that this protects RKE2/kubelet/containerd processes, while pod limits are enforced through
  Kubernetes cgroups under `/kubepods.slice`.
- `cluster status` reports the authored host budget, observed host capacity, node allocatable
  capacity, and current quota headroom in a structured, non-secret form.

### Validation

1. `prodbox test unit` covering observed-capacity refusal, kubelet arg rendering, systemd drop-in
   rendering, and reservation arithmetic.
2. `prodbox test integration cli` with fake `systemctl`, `kubectl`, and host probes proving
   reconcile plans the guardrails before chart deployment.
3. `prodbox dev check`
4. Live-proof (Standard O): on a real local host, `kubectl describe node` shows allocatable cpu,
   memory, and ephemeral storage below capacity by the configured reservations, and an over-limit
   pod is OOMKilled/evicted without starving SSH/NetworkManager.

### Remaining Work

- None on the code-owned surface. Sprint `5.13` has landed suite-level coverage; the live host
  stress proof is a non-blocking live-infra axis.

## Sprint 4.42: Route Lifecycle Bootstrap Through the Daemon [✅ Done]

**Status**: Done (2026-07-05)
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Vault.hs`,
`src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Client.hs`, `src/Prodbox/Aws.hs`,
`test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/golden/plans/rke2-reconcile*.txt`
**Independent Validation**: fake-daemon integration and unit tests over lifecycle ordering,
fallback refusal, and no-direct-transport decisions; no AWS substrate or later phase required.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/config_doctrine.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/cli_command_surface.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Make `cluster reconcile` and the operator-facing `prodbox vault ...` commands use the daemon
bootstrap endpoint after the daemon NodePort is available. The host binary still owns initial
Kubernetes substrate bootstrap and daemon deployment, but it no longer reaches MinIO or Vault
directly for post-bootstrap lifecycle work.

### Deliverables

- `cluster reconcile` orders platform bring-up as: RKE2 and retained PVs, bootstrap-readable MinIO,
  Vault on its retained PV, daemon + loopback NodePort, daemon-mediated Vault init/unseal/reconcile,
  then Vault-dependent chart reconciliation.
- `prodbox vault status|init|unseal|reconcile|rotate-unlock-bundle|rotate-transit-key|pki ...`
  prefer the daemon API once the daemon NodePort is reachable; direct host Vault/MinIO access is kept
  only for explicit legacy/config/test seams tracked in the cleanup ledger.
- The host-side MinIO port-forward helper is removed from the supported root unlock-bundle
  lifecycle path; Sprint `7.30` also removes it from supported Pulumi/object-store reads.
- The Vault `vault-host` direct NodePort and `hostVaultAddress` are no longer part of the supported
  post-bootstrap lifecycle contract.
- Error reporting distinguishes "daemon unavailable before bootstrap" from "daemon available but
  Vault sealed/uninitialized" without leaking passwords, unseal shares, Vault tokens, object keys, or
  child-cluster metadata.

### Validation

1. `prodbox test unit` covers lifecycle ordering, daemon-client decision tables, bounded request
   decoders, route constants, and redaction. Passed 2026-07-05: 1182/1182.
2. `prodbox test integration cli` uses fake daemon/Vault/MinIO boundaries to prove commands prefer
   the daemon path and refuse unsupported direct fallback. Passed 2026-07-05: 43/43.
3. `prodbox test integration env` proves no new environment-variable config path is introduced.
   Passed 2026-07-05: 43/43.
4. `prodbox dev check` is the closure gate for the full worktree. Passed 2026-07-05 after
   pinned-format cleanup.

### Remaining Work

- None for Phase `4`. Sprint `7.30` now owns and closes the non-lifecycle object-store/Pulumi
  daemon API; Sprint `5.14` owns the canonical no-legacy-transport regression proof.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - AWS substrate environment and
  Pulumi boundary after broad local-cluster decoupling.
- `documents/engineering/aws_test_environment.md` - retained AWS substrate environment doctrine.
- `documents/engineering/cli_command_surface.md` - canonical Haskell lifecycle and public
  AWS-validation Pulumi surface, including the hermetic `prodbox rke2 delete --yes`
  success-summary contract.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - SSoT for the
  reconciler-with-predicates pattern, the state-lifetime rule, and the leak-class
  inventory that Sprints `4.10`–`4.13` operationalize; for Sprint `4.24` it also records
  the public-edge production certificate as a `LongLived` managed resource under the § 3.1
  totality + soundness pattern; for Sprints `4.26`–`4.27` it records the refuse-gate vs
  reconciler split (default `rke2 delete` / `aws teardown` stay refuse-gates, only `--cascade`
  reconciles), the registry-derived default-delete sweep, the nuke step-4 fail-closed tag sweep,
  and the `StackDescriptor` SSoT feeding the § 3.1 registry totality; for Sprint `4.41` it records
  RKE2/kubelet/systemd resource guardrails as lifecycle-owned reconcile inputs; for Sprint `4.42`
  it records the daemon-mediated post-bootstrap lifecycle boundary.
  For Sprint `4.76` it records where the `Unreachable → refuse` refusal actually lives — split across
  the gate, the destroy loop, and the aggregate — and replaces § 6's implementation-gap block with
  the fail-closed `decideTagSweep` verdict algebra plus the one residual (the cascade sweep's
  credential-absent skip). For Sprint `4.77` it records that the sweep is one query per filter set
  unioned by ARN, because the Tagging API ANDs `TagFilters`, and corrects § 3.1 invariant 4's note
  that `--yes` on the four stack-destroy verbs is inert.
- `documents/engineering/streaming_doctrine.md` - for Sprint `4.76`, § 6a *A narrated skip is not a
  narrated absence*: each skip reason gets its own sentence, the unobserved sentence goes to the
  diagnostic stream and states what remains true, an aggregate line naming phases is derived from
  the recorded phase outcomes, and operator advice is a function of the delete mode that is running.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `4.41`, host/RKE2 reservation,
  eviction-floor, observed-capacity refusal, and runtime enforcement rings.
- `documents/engineering/host_platform_doctrine.md` - for Sprint `4.41`, host capacity observation
  and host-provider-specific filesystem/cgroup capacity facts.
- `documents/engineering/code_quality.md` - final non-Python quality gate; for Sprint `4.26` it
  also lists the `checkPlanOptionsHonored` lint, and for Sprint `4.27` the generalized
  `awsCreateSiteViolations` create-site lint.
- `documents/engineering/dependency_management.md` - final Haskell dependency and container-image
  inventory, including the `ghcup` pin and no-symlink doctrine for Haskell-build containers.
- `documents/engineering/local_registry_pipeline.md` - Harbor-first lifecycle ordering and the
  authoritative Harbor-plus-storage-backend bootstrap doctrine.
- `documents/engineering/prerequisite_doctrine.md` - lifecycle and Pulumi prerequisite checks.
- `documents/engineering/streaming_doctrine.md` - user-visible success-summary versus actionable
  failure-context rules for noisy lifecycle subprocesses; for Sprint `4.33` the cross-linked
  no-name-in-logs and exists-vs-`NoSuchKey` oracle rules for sealed-state output.
- `documents/engineering/config_doctrine.md` - for Sprint `4.30` the in-force config flows through
  the §9 object-store (opaque `objects/<id>.enc`, not the literal `in-force-config` key); for
  Sprint `4.32` the lifecycle bootstrap/in-force-settings split for federated child reconcile; for
  Sprint `4.42` the removal of direct host MinIO/Vault transports after daemon bootstrap.
- `documents/engineering/helm_chart_platform_doctrine.md` - for Sprint `4.30` the
  `.data/prodbox/minio/0` hostPath holds opaque-named ciphertext only.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage contract after the
  lifecycle/chart rewrite, including the delete-side cleanup-summary contract; for Sprint `4.26`
  the §5 cascade order is corrected to the canonical per-run-destroy → drain → uninstall →
  tag-sweep sequence; for Sprint `4.30` the `.data/prodbox/minio/0` hostPath holds opaque-named
  ciphertext only; for Sprint `4.31` the host-path contract is the unified
  `.data/<namespace>/<StatefulSet>/<replica>` scheme (no machine-id prefix), every retained
  workload is a StatefulSet, and one reconciler provisions all retained PVs.
- `documents/engineering/aws_integration_environment_doctrine.md` - additionally, for Sprint
  `4.27`, the `StackDescriptor`-derived per-run / long-lived stack inventory and the generated
  registry-name↔CLI-command section.
- `documents/engineering/unit_testing_policy.md` - native lifecycle and aggregate validation
  ownership.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `4.34` the prodbox-as-autoscaler
  reconciler over the capacity type and the federation-scoped multi-cluster placement that never
  perturbs gateway leadership.
- `documents/engineering/pulsar_topic_lifecycle_doctrine.md` - for Sprint `4.35` Pulsar topics as
  managed resources — typed three-valued broker discover, typed destroy, and LifecycleClass assignment,
  reconciled present/absent under the § 3.1 registry pattern.
- `documents/engineering/tiered_storage_capacity_doctrine.md` - for Sprint `4.36` the finite-budget
  capacity DSL (no `Infinite`; MinIO unbounded only with an autoscaling-policy witness), the per-deploy
  AWS region service-quota gate, and the mandatory ML JIT + model-cache storage budget.
- `documents/engineering/host_platform_doctrine.md` - for Sprint `4.37` the host-provider VM
  provisioning (Lima on macOS, WSL2 on Windows, Incus/native on Linux), the Docker host-frame gate,
  and the native-host-arch build inside the OS-appropriate Linux frame.
- `documents/engineering/cluster_topology_doctrine.md` - for Sprint `4.38` one substrate-typed compute
  worker per machine (anti-affinity, `maxSurge: 0`), with mixed-substrate placement admissible only on
  `rke2`.
- [`DEVELOPMENT_PLAN/development_plan_standards.md`](development_plan_standards.md) - SSoT for the
  phase-independence doctrine (Standard N: Phase Independence — the phase-level Independent
  Validation line above; Standard O: Code-Local vs Live-Infra Proof — the non-blocking
  `Live-proof` axis used for the cascade live-closure proof in Sprint `4.17`); this phase defers
  to those standards rather than restating the doctrine.
- [`documents/engineering/vault_doctrine.md`](../documents/engineering/vault_doctrine.md) - SSoT
  for the fail-closed Vault-root secret-management model (Vault is the sole secrets/KMS/PKI root; the
  master-seed HMAC derivation model is retired, not extended); for Sprint `4.29` it records Vault
  folded into the canonical cluster lifecycle on the init-once / unseal-on-rebuild contract (reconcile
  deploys/unseals, teardown preserves the durable Vault PV alongside the MinIO PV, sealed Vault is a
  first-class fail-closed `cluster status` line — vault_doctrine
  [§5](../documents/engineering/vault_doctrine.md#5-vault-deployment-model-and-durability),
  [§7](../documents/engineering/vault_doctrine.md#7-vault-lifecycle-commands),
  [§15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix)), for
  Sprint `4.30` the Model B object-store — Vault-keyed-HMAC opaque IDs, the `prodbox-envelope-v2`
  hashed AAD, the Vault-encrypted index, decoy-pad-to-constant-count plus size buckets, one
  generically-named bucket shared by the host CLI and the gateway daemon, and the MinIO sealed-state
  red-team (vault_doctrine [§9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store),
  [§19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)), for Sprint `4.33` the
  whole-system sealed-state scrub of the on-disk, Kubernetes, and log surfaces — residue-query gating
  behind the Vault-readiness check, structured-log/output redaction plus redacted `Show`, opaque k8s
  namespaces with downstream identity in Vault KV, and the cross-surface red-team (vault_doctrine
  [§9 — Whole-system zero-child-info](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store),
  [§14](../documents/engineering/vault_doctrine.md#14-error-model-and-logging),
  [§19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)), and for Sprint `4.32` the
  federated lifecycle reconcile — direct parent-side child registration, child-cluster auto-unseal,
  the fail-closed unseal cascade, parent-custodied child root token reuse, and the post-MinIO
  settings reload; for Sprint `4.42` the daemon-mediated root Vault bootstrap path. The opaque
  child-named namespace enforcement landed in Sprint `4.33`. The retained-PV teardown model is
  extended, not reversed.
- [`documents/engineering/cluster_federation_doctrine.md`](../documents/engineering/cluster_federation_doctrine.md) -
  SSoT for the Vault transit-seal trust tree (root/child hierarchy, parent custody of child init
  keys, downstream-cluster metadata as secret, the root-token config-write authority, the fail-closed
  unseal cascade, and the unencrypted basics); for Sprint `4.32` it records the federated lifecycle
  reconcile that auto-unseals a child against its parent and cascades the fail-closed brick down the
  tree when a parent is sealed or unreachable; for Sprint `4.33` it records downstream
  kubeconfig/identity custodied in the parent's Vault KV (`secret/clusters/<child-id>/*`, never a
  k8s Secret) and child-named namespaces using opaque IDs. For
  [Sprint 7.16](phase-7-aws-substrate-foundations.md) the AWS-credential narrative across the
  `aws-ses`, cascade, and `nuke` paths in this phase is reframed onto the corrected three-role
  model — the ephemeral elevated/admin credential enters only through the interactive
  `SecretRef.Prompt` (the harness simulating it from `test-secrets.dhall`'s
  `aws_admin_for_test_simulation.*` fixture, never a stored block in `prodbox-config.dhall`), the
  generated operational `prodbox` `aws.*` is minted into Vault KV after Vault is unsealed and
  referenced from `prodbox-config.dhall` only as a `SecretRef.Vault` value, and no testing secret
  lives in Vault (vault_doctrine
  [§3](../documents/engineering/vault_doctrine.md), [§4](../documents/engineering/vault_doctrine.md),
  [§13](../documents/engineering/vault_doctrine.md); the `aws_admin_for_test_simulation` block
  specifics in [`aws_admin_credentials.md`](../documents/engineering/aws_admin_credentials.md); the
  per-stack credential-class assignment in
  [`lifecycle_reconciliation_doctrine.md` §2](../documents/engineering/lifecycle_reconciliation_doctrine.md)).

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep lifecycle and AWS IaC doctrine linked from [system-components.md](system-components.md).
- For Sprint `4.24`, cross-reference [substrates.md](substrates.md) so the regenerated Resource
  Lifecycle Classes table lists the public-edge production certificate as `LongLived`.
- For Sprint `4.27`, cross-reference [substrates.md](substrates.md) so the `StackDescriptor` SSoT
  and the renamed `longLivedResourceNames` stay aligned with the Resource Lifecycle Classes
  inventory.

## Sprint 4.43: EffectDAG-Driven Reconcile Ordering and the Deep Registry→MinIO Readiness Barrier [✅ Done]

**Status**: Done (2026-07-06)
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (the single typed `ReconcileStepId` step table
narration + execution project from, the deep `ensureRegistryStorageBackendEdgeReady` gate + pure
`classifyRegistryStorageEdgeProbe`, the name-resolution retry-classifier fix, and the
`nativeInstallStepOrderRespectsGraph` graph-consistency check), `src/Prodbox/Config/ComponentGraph.hs`
(`componentDagEdges`)
**Live-proof**: pending (the green home `prodbox test all` past the image-mirror step — non-blocking,
Standard O)
**Independent Validation**: fake-boundary unit + `prodbox test integration cli` tests over
(a) the graph-consistency lint over the hand-written step order (the 8/34 anchored steps),
(b) the deep registry→MinIO edge gate refusing to proceed while the S3 write path is unproven /
`Unreachable`, and (c) the **Harbor** retry classifier (`isRetryableHarborPublicationFailure`) treating
`no such host`/`dial tcp`/`lookup` as retryable — the sibling `isRetryableHelmFailure` still omits them
(a confirmed flake owned by new Sprint `4.46`). No AWS substrate or later phase required.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/local_registry_pipeline.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Make the home-substrate bootstrap readiness-race class unrepresentable on the reconcile driver:
derive bring-up order from the typed component graph rather than a hand-written list, and gate every
consumer→dependency edge behind a barrier that exercises the exact call path it uses — closing the
registry→MinIO S3 race that fails `cluster reconcile` at the image-mirror step.

### Deliverables

- `cluster reconcile` narration and execution project from ONE typed `ReconcileStepId` step table
  (`nativeInstallStepOrder`), retiring the parallel `renderNativeInstallPlan` STEP narration that had
  to be hand-kept in sync (ledger row under this sprint) — a real already-live drift closed
  (`ensure_host_control_data_directory` was executed but never narrated). **Correction (2026-07-10):**
  the *order* was still the hand-written enum `[minBound..maxBound]` with a test-only
  `nativeInstallStepOrderRespectsGraph` consistency lint (only 8/34 steps anchored); deriving the order
  from the graph (M1 proper) + a fail-closed guard + full step-anchoring therefore became Sprint
  `4.45`, now Done ([Standard C/L](development_plan_standards.md#c-honest-completion-tracking)). The
  `runSequentially` fold helper is retained as a total ordering primitive.
- A **deep** registry→MinIO readiness barrier runs before `mirrorClusterImagesOnce` and before any
  runtime/custom-image push: it exercises the registry's own S3 write path (a canary blob push
  through the registry, or the registry storagedriver health surface wired into readiness), not the
  front-door `GET /v2/` proxy (M3). An `Unreachable` observation gates closed.
- `isRetryableHarborPublicationFailure` classifies transient name-resolution failures
  (`no such host`, `dial tcp`, `lookup`, `name resolution`) as retryable so residual jitter is bounded
  by `pushDockerImageWithRetry` rather than failing the bootstrap outright.
- The EKS-substrate parity of the same barrier + classifier is owned forward by Sprint `7.31`.

### Validation

1. `prodbox test unit` covers the then-hand-authored order's graph consistency
   (`nativeInstallStepOrderRespectsGraph`), the
   deep-gate decision table (proceed only on a `201`/`202` upload session; refuse on `Unreachable`;
   retry a registry `5xx`/front-door `200`), and the retry-classifier name-resolution cases. ✅ 1214/1214.
2. The mirror step is not attempted until the deep gate passes: `verify_registry_minio_edge` precedes
   `mirror_cluster_images_once` in the single step table (golden + ordering unit test), and
   `runSequentially` short-circuits on the gate's failure, so a failed/`Unreachable` gate never reaches
   the mirror push. `prodbox test integration cli`/`env` green.
3. `prodbox dev check` is the closure gate. ✅ exit 0.
4. Live-proof (non-blocking, Standard O): a home `prodbox test all` reconcile completes past the
   image-mirror step.

Closed 2026-07-06. Narration and execution now project from ONE typed `ReconcileStepId` table
(retiring the two hand-synced lists — which had already drifted: `ensure_host_control_data_directory`
was executed but never narrated, now narrated). The deep registry→MinIO gate exercises the registry's
own S3 write path (a blob-upload session), not the front-door `GET /v2/` proxy; the `/v2/` gates are
kept as a cheaper pre-check ahead of it. **Correction (2026-07-10):** this sprint delivered the
narration single-sourcing + the deep gate, NOT M1 order-derivation — the order remained the hand-written
`[minBound..maxBound]` enum with a *test-only* graph-consistency lint, and a nested
MetalLB/Envoy/Percona `runSequentially` inside `ensureClusterPlatformRuntime` (`Rke2.hs:3886`) is
invisible to that lint. Sprint `4.45` has since derived the order from the graph, promoted the check
to a fail-closed guard, hoisted the nested list, and totalled the step executors.

### Remaining Work

- EKS parity (`AwsSubstratePlatform` gate + `EksImageMirror` classifier) is Sprint `7.31`; it composes
  this pattern and does not reopen Phase `4`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/bootstrap_readiness_doctrine.md` - the M1/M3 mechanisms this sprint lands on
  the reconcile driver.
- `documents/engineering/local_registry_pipeline.md` - the deep registry→MinIO gate replacing
  front-door-only `/v2/` gating before image writes.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - reconcile ordering as a projection
  over the component graph.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Add ledger rows (Sprint `4.43`) for the retired `runSequentially` list + STEP narration and the
  `/v2/`-only registry gates in `legacy-tracking-for-deletion.md`.

## Sprint 4.44: Typed Registry Storage Backend and Non-Defaultable Redirect Policy [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`RedirectPolicy`, `RegistryStorageBackend`,
`harborRegistryStorageBackend`, `registryConfigYaml`, `harborRegistryStorageRegion`),
`test/golden/config/registry-config.yaml`, `test/unit/Main.hs`
**Independent Validation**: `./.build/prodbox test unit` passes 1268/1268, including the registry
config golden and explicit `RedirectDisabled`/`RedirectEnabled` rendering assertions;
`./.build/prodbox dev check` exits 0. No later phase or live infrastructure is required.
**Docs to update**: `documents/engineering/local_registry_pipeline.md`

### Objective

Kill the 80a08e3 class without replacing the deterministic renderer: the load-bearing redirect
decision (the localhost NodePort cannot follow S3 presigned redirects) is a required field of a
typed backend value, and `registryConfigYaml` always renders the corresponding
`redirect.disable: true|false` line.

### Deliverables

- `RegistryStorageBackend` replaces the former zero-argument, untyped storage-policy input. Its
  required `registryStorageBackendRedirect :: RedirectPolicy` admits `RedirectDisabled` or
  `RedirectEnabled`; `registryConfigYaml` renders either value explicitly as `disable: true` or
  `disable: false`.
- `registryConfigYaml` deliberately remains a deterministic `unlines` renderer. The closure is the
  required typed input and total policy projection, not the removal of `unlines`.
- `harborRegistryStorageBackend` is the canonical MinIO-backed value and selects
  `RedirectDisabled`. It reuses the stable `harborRegistryStorageRegion = "us-east-1"` constant,
  along with the existing endpoint and bucket constants.
- Registry S3 credentials remain in the existing `harbor-registry-s3` Secret and reach
  `registry:2` through Deployment `envFrom`; they do not enter `RegistryStorageBackend` or the
  ConfigMap.
- No `ResourceRegistry` ownership changes and no new Kubernetes or AWS resource are part of this
  sprint. The existing registry ConfigMap, Deployment, Service, Secret, and bucket retain their
  existing lifecycle owners.
- `test/golden/config/registry-config.yaml` pins the canonical `disable: true` rendering, and a unit
  assertion proves `RedirectEnabled` renders `disable: false` rather than inheriting a driver
  default.

### Validation

1. `./.build/prodbox test unit` — passes 1268/1268, including
   `test/golden/config/registry-config.yaml` and both explicit redirect-policy projections.
2. `./.build/prodbox dev check` — exits 0.

### Remaining Work

- None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/local_registry_pipeline.md` - §2.1 the typed registry storage backend + non-defaultable redirect policy.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Former ledger row F (zero-argument untyped registry storage policy) is recorded under `Completed`
  in `legacy-tracking-for-deletion.md` for Sprint `4.44`.

## Sprint 4.45: Graph-Derived Reconcile Order, Fail-Closed Guard, and Full Step Anchoring [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`stepsForComponent`,
`nativeInstallStepOrder`, `buildNativeInstallExecutionPlan`, `NativeInstallPayload`, total
bootstrap/steady executors, and the native `ComponentReadinessTarget` factory),
`src/Prodbox/CLI/Vault.hs` (shared configured gateway endpoint),
`src/Prodbox/Config/ComponentGraph.hs` (corrected native dependency edges),
`src/Prodbox/Config/SchemaDhall.hs` (canonical default-graph Dhall projection),
`test/unit/Main.hs`, `test/golden/plans/rke2-reconcile.txt`,
`test/golden/plans/rke2-reconcile-with-edge.txt`, `test/support/TestSupport.hs`,
`test/integration/CliSuite.hs`
**Live-proof**: pending (a home `prodbox test all` derived-order reconcile; non-blocking Standard O,
not run as part of this code-local closure)
**Independent Validation**: `./.build/prodbox test unit` passes 1273/1273, including derived-order,
valid compiled-plan, inverted-graph phase-fail-closed, total-executor, and native-target coverage;
`./.build/prodbox cluster reconcile --dry-run` exits 0 with the derived STEP order;
`./.build/prodbox dev check` exits 0. The generated config schema was refreshed and
`./.build/prodbox config validate` exits 0. No AWS substrate or later phase is required.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Realize doctrine-M1: reconcile order is a pure projection over the validated component graph, so a mis-ordering fails graph expansion / the build guard, not a live cluster — retiring the hand-written enum as the ordering authority.

### Deliverables

- `nativeInstallStepOrder` is exactly
  `concatMap stepsForComponent (componentReconcileOrder dag)`. The plan compiler appends the
  separately-owned edge tail to that native order when edge reconcile is requested.
  `[minBound..maxBound]` is only an inventory-coverage enumeration, never the ordering authority.
  The compiled `NativeInstallPayload` carries the already-validated DAG and exact run order, so
  dry-run narration and apply consume the same value.
- Component dependency declarations include every real native consumer edge: cert-manager,
  pre-Vault gateway, MetalLB, Envoy Gateway, and Percona depend on the registry; MetalLB, Envoy
  Gateway, and Percona also depend on unsealed Vault. The resulting graph order is the execution
  order rather than a post-hoc lint target.
- Bind the corrected graph declarations to their RKE2-owned observations: cluster base uses
  `ProbeServiceActive` rather than a fictitious rollout; `ComponentVaultUnsealed` follows both the
  Vault workload and pre-Vault gateway daemon because supported unseal is daemon-mediated; and
  `ComponentGatewayDaemonFull` proves its explicit backend-write edge to MinIO through the gateway
  object-store interface. Sprint `1.59` landed these declarations and target types, not these
  production bindings. The one-shot target factory covers every native component, and the final
  step in each component group is followed by a bounded gate over its declared readiness target. The deep
  registry→MinIO barrier additionally remains immediately before the first registry write.
- The nested MetalLB/Envoy/Percona aggregate is replaced by first-class
  `StepMetalLbRuntime`, `StepEnvoyGatewayRuntime`, and `StepPostgresOperatorRuntime` values. The
  redundant home MinIO steady-state token is removed because it performed no distinct mutation.
  Consequently both reconcile plan goldens intentionally change: one aggregate platform token
  becomes three component steps and the redundant MinIO token disappears.
- `buildNativeInstallExecutionPlan` rejects invalid graph order, phase regression, edge placement,
  step inventory/anchoring, or readiness-target coverage as a structured error before apply. The
  deliberately inverted graph fixture proves this is an execution-path guard rather than a
  test-only assertion.
- `bootstrapStepAction` and `steadyStepAction` use total constructor matches; adding a step without
  choosing its phase executor cannot silently succeed.

### Validation

1. `./.build/prodbox test unit` — ✅ 1273/1273, including derived-order equality, a valid
   compiled plan, the phase-fail-closed inverted fixture, total executor matches, and every native
   readiness target. Inventory and edge checks are exercised by the valid compiled-plan path; no
   separate negative inventory/edge fixture is claimed.
2. `./.build/prodbox cluster reconcile --dry-run` — ✅ exit 0; its STEP narration uses the
   graph-derived order and matches the intentionally refreshed reconcile golden.
3. The binary-sibling config schema was regenerated; `./.build/prodbox config validate` — ✅
   exit 0.
4. `./.build/prodbox dev check` — ✅ exit 0 closure gate.
5. Three graph-consuming fake CLI reconcile fixtures — ✅ plain reconcile/delete, mirror fallback,
   and ZeroSSL `--with-edge` reconcile. Each consumes the full default component graph and the
   configured fake gateway-daemon endpoint.
6. 🧪 Live-proof (non-blocking, Standard O): a home `prodbox test all` reconcile completes on
   the derived order. This live proof was not run for code-local closure.

### Remaining Work

- None on the Sprint `4.45` code-owned surface. AWS-substrate readiness parity subsequently landed
  in Sprint `7.32`; the home live proof remains the non-blocking axis above.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/bootstrap_readiness_doctrine.md` - M1 realized (order derived, not linted).
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - reconcile ordering as a projection over the component graph.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Former ledger rows A/B/C/H (`[minBound..maxBound]` authority, nested `runSequentially`,
  test-only lint, executor wildcards) are recorded under `Completed` in
  `legacy-tracking-for-deletion.md` for Sprint `4.45`.

## Sprint 4.46: Reconcile-Driver Retry-Classifier Delegation and the Helm-DNS Flake Fix [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/CLI/Rke2.hs` — `isRetryableRoute53CredentialFailure`,
`isRetryableHelmFailure`, and `isRetryableHarborPublicationFailure` delegate to the landed
Sprint-`1.57` shared transient-fragment base; `src/Prodbox/CheckCode.hs` deletes all three
corresponding transitional RKE2 allowances; `test/unit/Main.hs` pins the shared and
operation-specific behavior plus the exact-name lint migration
**Independent Validation**: `./.build/prodbox test unit` passes 1276/1276, asserting
`isRetryableHelmFailure` treats `no such host`/`dial tcp`/`lookup`/`connection refused`/name
resolution as retryable through the shared base, the Route 53 classifier retains its
credential-specific extensions, Harbor retains its PUT-status extension, and none of the three
former exact-name RKE2 lint allowances remains. `./.build/prodbox dev check` exits 0. No AWS
substrate or later phase is required.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`

### Objective

Close the confirmed live flake: a transient name-resolution failure on a Helm install is retryable
exactly as it is on the registry push because both classifiers read one shared base, while retiring
the remaining RKE2-owned inline retry lists and their transitional lint allowances.

### Deliverables

- `isRetryableRoute53CredentialFailure`, `isRetryableHelmFailure`, and
  `isRetryableHarborPublicationFailure` delegate to the Sprint-`1.57` base, keeping only genuinely
  path-specific fragments; the Helm/Harbor divergence is gone and the `CheckCode` lint prevents its
  return.
- Delete all three RKE2 entries from `legacyInlineRetryClassifier`; Sprint `4.46` leaves no
  RKE2-owned inline-list allowance behind.

### Validation

1. `./.build/prodbox test unit` — ✅ 1276/1276, including the Helm classifier name-resolution
   cases, Route 53 and Harbor path-specific cases, negative authorization cases, and the
   no-RKE2-allowance exact-name lint fixture.
2. `./.build/prodbox dev check` — ✅ exit 0 closure gate.

### Remaining Work

- None. AWS `EksImageMirror` classifier delegation subsequently landed in Sprint `7.32`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/bootstrap_readiness_doctrine.md` - §4 the reconcile-driver classifiers read the shared base.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Ledger row D records the RKE2 completion in Sprint `4.46` and the final EKS completion in Sprint
  `7.32`; no classifier allowance remains. Sprint `1.57`'s base/lint and Phase-1 caller migration
  remain recorded separately.

## Sprint 4.47: Desired-Present Long-Lived Reconciliation and Shared SES Lease [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/Lifecycle/ResidueStatus.hs`,
`src/Prodbox/Lifecycle/DesiredPresence.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`src/Prodbox/Lifecycle/CheckpointAuthority.hs`,
`src/Prodbox/Lifecycle/CheckpointAuthorityStore.hs`, `src/Prodbox/Lifecycle/Lease.hs`,
`src/Prodbox/Lifecycle/LeaseInterpreter.hs`, `src/Prodbox/Lifecycle/LeaseRuntime.hs`,
`src/Prodbox/Lifecycle/TargetCommitIntent.hs`,
`src/Prodbox/Lifecycle/TargetCommitInterpreter.hs`,
`src/Prodbox/Lifecycle/SmtpKeyRepair.hs`,
`src/Prodbox/Lifecycle/SmtpKeyRepairInterpreter.hs`,
`src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/Infra/AwsSesLeaseRole.hs`,
`src/Prodbox/Infra/AwsSesSmtpKey.hs`, `src/Prodbox/Ses/Readiness.hs`,
`src/Prodbox/Aws.hs`, `pulumi/aws-ses/Main.yaml`,
`src/Prodbox/Pulumi/EncryptedBackend.hs`, `src/Prodbox/Gateway/ObjectStore.hs`,
`src/Prodbox/Gateway/Client.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`test/unit/DesiredPresentReconciliation.hs`, `test/unit/LifecycleLease.hs`,
`test/unit/TargetCommitSmtp.hs`, `test/unit/SmtpKeyRepairInterpreter.hs`,
`test/unit/AwsSesLeaseRole.hs`, `test/unit/AwsSesLifecycle.hs`, and `test/unit/Main.hs`
**Independent Validation**: focused pure/fake suites exercise the full observe → pure plan → enact
→ re-observe loop, unobservable-state refusal, lease ownership/expiry,
provider-grace/quiescence recovery, bounded Model-B codecs, global target intents, SMTP-key repair,
and retained cleanup policy without AWS, Kubernetes, or a later phase. Focused evidence is 78/78
Sprint-`4.47` lifecycle cases plus 9/9 fixed-role cases; the warning-clean full unit suite is
1476/1476 and `prodbox dev check` exits 0.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/pure_fp_standards.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, and
`README.md`

### Objective

Make `LongLived` mean "ensure when a selected workflow requires it, retain during ordinary
postflight, destroy only through an explicit long-lived teardown." Extend the registry/reconciler
model symmetrically so desired-present resources are planned from typed external observations and
cannot be created from an unobservable state.

### Current Implementation State

- `PresenceObservation` and `CheckpointObservation` are separate flat exhaustive ADTs in
  `Prodbox.Lifecycle.ResidueStatus`. `Prodbox.Lifecycle.DesiredPresence` owns the total six-action
  presence × checkpoint plan, structured refusal values, caller-injected hooks, mandatory
  post-enactment re-observation, and positive converged postcondition.
- `ManagedResource` carries independent optional ensure command/interpreter fields;
  `desiredPresentManagedResources` contains the registered `LongLived` `aws-ses` resource while
  the existing destroy projections remain unchanged.
- `LongLivedCheckpointAuthority` and `TargetClusterSecretSink` have unrelated opaque constructors.
  `ModelBCasAdapter` exposes missing/observed/corrupt/unobservable reads plus initialize/replace
  CAS requests over opaque object-store versions. `CheckpointAuthorityStore` binds that interface
  to the retained authority endpoint.
- The gateway exposes bounded `/v1/object-store/authority/get` and
  `/v1/object-store/authority/cas` routes. Logical names remain under Model-B HMAC/encryption;
  payloads are redacted in `Show`; absent initialization and expected-version replacement use the
  object store's opaque version/ETag rather than a payload-derived fence.
- `Lease` and `LeaseInterpreter` implement bounded non-renewable grants, safe-use arithmetic,
  authority-clock expiry, monotonic fences, owner/fence commit and release, bounded child
  cancellation, provider/target grace, stable quiescence, canonical bounded CBOR, and fresh
  re-observation after CAS.
- `TargetCommitIntent` implements a bounded registered-target projection and the
  prepare → revalidate → sink CAS/read-back → complete/recover/compact fold.
  `SmtpKeyRepair` implements finite authoritative inventory classification, committed-key reuse,
  owned orphan deletion, stable-empty witnessing, single replacement creation, and fenced commit.
- `SmtpKeyRepairInterpreter` loads the retained committed projection, executes every planned IAM
  cleanup, waits for the bounded stable inventory, derives generation `1` or committed `N + 1`,
  requests one fresh fenced permit, creates at most one key, guarded-CAS commits recoverable
  material, and mandates re-observation. The created key is exception-bracketed and deleted when
  commit is not applied; cleanup failures remain explicit. Pulumi retains ownership of the SMTP IAM
  user/policy but no longer declares an `aws:iam:AccessKey` or exports key material.
- **Superseded ownership boundary, history preserved:** the preceding sentence records the
  completed Sprint-`4.47` implementation and evidence; it is not the target ownership model.
  Sprint `8.11` freezes that legacy Pulumi writer, migrates the deterministic `LongLived` SMTP
  principal/policy/finite key family to the `OperatorMaterialPermit`-selected Credential
  Provisioner, and removes every SMTP IAM resource/output from the provider program without a
  dual-write interval.
- `EncryptedBackend` exposes fenced conditional checkpoint writeback. The registered
  `AwsSesStack` ensure acquires the account-scoped lease, drains predecessor provider/target
  effects, runs reconcile/provider→semantic-readiness/SMTP stages under bounded credentials,
  authorizes checkpoint persistence from a fresh fence, repairs the authoritative IAM-key
  inventory, and materializes only through the target-intent protocol. The readiness stage first
  proves the complete registered provider inventory, including the Pulumi-owned S3 canary, then
  delegates exact sender/DKIM, MX/rule, and capture list/get classification to
  `Prodbox.Ses.Readiness`. Control-plane probes use the lease-scoped role; capture probes use the
  operational credential consumed by invite polling. Only `Ready` proceeds, propagation `Pending`
  polls within the bounded window, and `Failed`/`Unobservable` terminate before SMTP mutation.
  Voluntary release retains a v2 predecessor tombstone whose grace starts at release time; unsafe
  v1 released projections fail closed.
- `AwsSesLeaseRole` owns the exact same-account trust, one-hour maximum, config-bounded SES/S3/
  Route53/SMTP-user policy, typed observation/reconcile/delete loop, and postcondition checks.
  `Aws` installs the operational user's exact assume-role/pre-lease-read policy, registers the role
  before its trusted user in teardown order, and re-observes absence after teardown.

### Deliverables

- Keep two flat exhaustive external observations: authoritative AWS presence
  (`Absent | Present inventory | Unobservable`) and checkpoint state
  (`Missing | Valid snapshot | Corrupt | Unobservable`). No GADT pretends an in-process transition
  creates an external fact.
- Add a pure desired-presence planner whose actions are explicit plan data. Missing/corrupt
  checkpoint plus positively observed AWS resources plans import/repair; positively absent AWS may
  plan create; any unobservable authoritative input refuses. Re-observation is mandatory after
  enactment.
- Register the canonical `aws-ses` ensure/reconcile action alongside its discover/destroy
  ownership. Preserve the existing explicit destroy commands and the suite postflight exclusion.
- Keep the former `awsCommandSucceeds :: ... -> IO Bool` state-repair helper removed and prove all
  supported callers consume typed classification, so authorization, credential, throttling, and
  network failures cannot masquerade as absence.
- Serialize `aws-ses` repair/reconcile and encrypted-checkpoint writeback with a shared lease that
  has an owner nonce, monotonic fencing token, authority-clock expiry, bounded acquisition, and
  owner/fence-checked release/commit. A pure `LeasePolicy` proves one non-renewable grant outlives
  every bounded reconcile/readiness/SMTP/cancellation step plus clock-skew and safety margins; a
  lease-scoped AWS session expires no later than the grant. The lease prevents two current owners
  from deliberately issuing new work and stale owners from committing checkpoint/SMTP CAS; it does
  not revoke an AWS request or provider action accepted before session expiry. A successor waits
  authority expiry plus declared clock-skew, cancellation, and conservative provider
  in-flight/visibility grace, then proves a stable authoritative quiescence witness before
  idempotently converging. Pending, unbounded, or unobservable provider state refuses.
- Make non-idempotent SMTP access-key repair compare the authoritative finite IAM-key inventory with
  the fenced committed key ID. Delete owned uncommitted or unrecoverable keys, wait and re-observe
  their absence, and only then create and fence-commit one replacement. Never retry key creation
  from an unobservable or over-bound inventory.
- Separate typed coordinates for the retained home/control-plane
  `LongLivedCheckpointAuthority` from the selected substrate's `TargetClusterSecretSink`. The
  cross-substrate `aws-ses` checkpoint and lease always use the retained control-plane
  `prodbox-state`/Vault keyspace; only SMTP KV materialization targets the selected cluster. No
  ambient gateway endpoint may choose checkpoint authority.
- Add a global `TargetCommitIntent` ledger at `LongLivedCheckpointAuthority`. Before a target Vault
  write, CAS-record owner/fence, target identity, credential generation, digest, and deadline;
  revalidate it, perform one bounded sink CAS with matching metadata, read back, and CAS-complete
  the global intent. A successor waits target-write grace and resolves every outstanding intent,
  including one for another substrate sink, before rotating credentials or committing anew.
  The registered target set and per-target intent projection are finite, terminal history compacts,
  and authoritative retirement removes the entry. Unobservable/unbounded target state refuses; do
  not claim an atomic fence across two authorities.
- Declare the current primary checkpoint path consistently: opaque Model-B state in MinIO for the
  main `aws-ses` path; the configured long-lived S3 store retains public-edge TLS and is an optional
  first-touch source for legacy SES checkpoints.

### Validation

1. Decision tables cover every desired-presence × AWS-presence × checkpoint-state case, prove
   unobservable never lowers to create, and preserve import/repair for positively observed live
   resources whose checkpoint is missing or corrupt.
2. Lease tables cover contention, authority-clock expiry, safe-use deadline arithmetic, stale
   fencing tokens, lost-lease cancellation, late checkpoint/SMTP commits, provider work accepted
   before expiry and visible only after cancellation, clock-skew/cancellation/provider grace,
   stable-quiescence witnessing, interruption, and retry convergence. Cross-authority tables cover
   late target writes, read-back failure, different target sinks, unresolved global intents, and
   bounded target churn/compaction and target retirement. The canonical 20-minute SES propagation
   window fits inside the validated 30-minute readiness-work budget and transaction grant.
3. Missing-state and SMTP-key-repair fixtures distinguish not-found from access denial and network
   failure; compare committed/uncommitted/unrecoverable key IDs; require delete → wait → stable
   re-observe → create → fenced commit; refuse unobservable/over-bound inventories; and propagate
   cleanup failures.
4. Retention tests prove success, failure, and interruption never schedule ordinary postflight
   destruction of `aws-ses`.
5. `prodbox dev check` is the code-owned closure gate.

Closure evidence: focused lifecycle tables 78/78, focused role tables 9/9, full unit 1476/1476,
warning-clean library/executable/unit builds, and `prodbox dev check` exit 0.

### Remaining Work

- None on the code-owned surface. Live AWS reconcile/concurrency exercise remains a non-blocking
  Standard-O proof axis.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_reconciliation_doctrine.md` - symmetric desired-present and
  desired-absent planning over external observations.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained SES ensure/lease and
  credential ownership.
- `documents/engineering/integration_fixture_doctrine.md` - `EnsureRetained` versus
  `DestroyPerRun` fixture semantics.
- `documents/engineering/pure_fp_standards.md` - external observations remain flat ADTs feeding a
  pure plan.

**Product docs to create/update:**

- `README.md` - identify the landed Sprint-`4.47` supported transaction and later phase ownership.

**Cross-references to add:**

- Sprint `5.17` consumes the registered ensure action; landed Sprint `8.10` supplies the typed
  provider→semantic readiness fold after reconciliation and before SMTP materialization.
- Keep `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, `system-components.md`, `substrates.md`, and
  `legacy-tracking-for-deletion.md` synchronized with the completed sprint.

## Sprint 4.48: Retained Lifecycle Authority and Durable Operation Journal [✅ Done]

**Status**: Done (validated 2026-07-26) — Sprint `3.26`'s control-plane charts, including the Lifecycle
Authority StatefulSet, landed). **Increment A (the pure genesis admission fold) landed 2026-07-23.**
**Deployment qualification**: pending
**Implementation**: **Increment A landed** — `src/Prodbox/Lifecycle/Authority/Genesis.hs` is the pure
`GenesisFrozen -> EstablishAuthorityBackup -> BackupEstablished` admission fold (`AuthorityAdmissionState`
+ `AuthorityGenesisCommand` / `GenesisDecision` / `AuthorityGenesisEvent` with total `decideGenesis` /
`evolveGenesis` / `stepGenesis`, modeled on the `Prodbox.ControlPlane.Capacity` decide/evolve shape),
enforcing the genesis invariant that normal admission (`admitsNormalOperations`) opens ONLY after BOTH
the home Target Agent generation receipt AND the Authority Backup Adapter receipt are read back, under
the genesis `AuthorityEpoch`. Forward plan: `src/Prodbox/Lifecycle/Authority/` and
`src/Prodbox/Lifecycle/AuthorityBackup/`, `src/Prodbox/Lifecycle/TlsRetention/`,
`src/Prodbox/Lifecycle/ProviderWorker/`, `src/Prodbox/Lifecycle/CredentialProvisioner/`,
`src/Prodbox/Lifecycle/AdminAction/`, and `src/Prodbox/Lifecycle/Decommission/` modules, separate
runtime-role dispatch/clients, versioned
journal/genesis codecs, native primary/backup/Vault interpreters, and deterministic simulator tests;
migrations from existing `Lease*`, `CheckpointAuthority*`, and `TargetCommit*` modules
**Independent Validation**: pure transition tables and a deterministic crash/restart interpreter
exercise every journal boundary with fake object-store, Vault, clock, and provider capabilities;
no AWS, Kubernetes, or later phase is required. **Increment A** is validated by
`test/unit/LifecycleAuthorityGenesis.hs` (8 cases: frozen refuses operations; begin-from-frozen;
one-receipt-does-not-open; both-receipts-open-under-epoch; order-independence; same-plan-idempotent /
divergent-plan-refused; post-admission refusal; replay-idempotent evolve) plus `prodbox dev check`
exit 0.
**Implementation**: **Increment B landed** — `src/Prodbox/Lifecycle/Authority/Operation.hs` is the
polymorphic durable operation journal / outbox: `OperationRecord binding intent result` with an
append-only `OperationPhase` (`OperationArmed intent` -> `OperationCompleted result`),
`newArmedOperation` / `resumeOperation` / `completeOperation` (terminal recorded at most once; rewrite
refused), and `decideOperationRecovery` — the at-most-once recovery that authorizes execution ONLY
when the source is provably still current, recovers (never repeats) a matching applied effect, and
fails closed on a mismatched / diverged / unobservable target. It generalizes
`Prodbox.Bootstrap.Broker.RequestJournal`. Validated by `test/unit/LifecycleAuthorityOperation.hs`
(8 cases) plus `prodbox dev check` exit 0.
**Implementation**: **Increment C landed** — `src/Prodbox/Lifecycle/Authority/State.hs` is the
`AuthorityState` aggregate composing the genesis fold with the operation journal: it holds the
admission state plus one `FencedOperation` per operation binding, and provides total
`decideAuthority` / `evolveAuthority` / `stepAuthority` (fully event-sourced via
`authorityDecisionEvents`; `Genesis` now exports `genesisDecisionEvents`). Normal operations are
admitted ONLY after genesis opens admission (`OperationRefusedAdmissionClosed` otherwise) and are
fenced by the admitting epoch; decisions are idempotent (`AuthorityOperationAlreadyArmed` /
`AuthorityOperationAlreadyComplete` commit no event) and conflict-checked
(`OperationRefusedBindingIntentConflict` / `OperationRefusedResultConflict`). Validated by
`test/unit/LifecycleAuthorityState.hs` (6 cases) plus `prodbox dev check` exit 0.
**Implementation**: **Increment D landed** — `src/Prodbox/Lifecycle/Authority/BackupRepair.hs` is the
pure post-genesis backup-repair reopen fold over the shared `AuthorityAdmissionState` (now carrying a
`BackupRepairFrozen !AuthorityEpoch !BackupRepairProgress` constructor). It is the ONLY post-genesis,
primary-only fold: a temporary/unobservable backup outage freezes admission and merely waits (no
permit, no external effect), reopening under a strictly greater epoch only once the backup reads
healthy again; a positively-absent key/bucket or proven policy drift primary-journals a signed
one-time `BackupRepairPermit` (replay idempotent, divergent permit refused) and — after BOTH the next
`LongLived` generation receipt AND the Authority Backup Adapter's first new backup receipt read back —
reopens admission under `nextAuthorityEpoch`. Total `decideBackupRepair` / `evolveBackupRepair` /
`backupRepairDecisionEvents` / `stepBackupRepair` mirror the genesis fold and compose into the
`AuthorityState` aggregate (new `AuthorityBackupRepair` command/decision/event arms) so admission is
frozen for the whole repair and a post-repair operation is fenced under the greater epoch. Validated by
`test/unit/LifecycleAuthorityBackupRepair.hs` (12 cases: repair-before-genesis; healthy no-op;
freeze-on-unhealthy; temporary-outage freeze→reopen; unobservable wait; positive-absence full
repair→greater-epoch reopen; policy-drift order-independent repair; receipt-before-permit refusal;
permit replay idempotent + divergent mismatch; response-loss re-observe idempotence; evolve/step
consistency; aggregate freeze+reopen) plus `prodbox dev check` exit 0 and the full `LifecycleAuthority*`
suite 34/34.
**Implementation**: **Increment E landed** — `src/Prodbox/Lifecycle/Authority/Submission.hs` is the pure,
standalone idempotent operation-submission front-door (closes Validation items 1–2). An `OperationId`
binds the admitting `AuthorityEpoch` plus the caller's `(client, client-sequence, request digest)`.
`decideSubmit` / `applySubmit` / `stepSubmit` accept a fresh submission, return the SAME id on an exact
resubmission (a lost response converges by id rather than becoming a second operation), refuse a sequence
reused with a different digest, refuse at live-population capacity, and return `SubmissionRefusedExpired`
for a sequence at or below the compacted per-client sequence floor (an old id is never treated as new).
`cancelSubmission` / `completeSubmission` settle in-flight submissions idempotently (cancel-after-complete
and complete-after-cancel refused); `compactClientTerminalsBelow` advances the floor and drops settled
tombstones, refusing across an in-flight submission; `submissionStatus` reports in-flight / settled /
expired / unknown. A client disconnect never determines an outcome — cancellation is an explicit command
and there is no disconnect input. Validated by `test/unit/LifecycleAuthoritySubmission.hs` (10 cases) plus
`prodbox dev check` exit 0 and the full `LifecycleAuthority*` suite 44/44.
**Implementation**: **Increment F landed** — `src/Prodbox/Lifecycle/Authority/AdminAction.hs` is the pure
disjoint admin-action permit family plus the Admin Action Runner's one-time acceptance fold (closes
Validation item 6). The `AdminAction` family (`DestroyAwsSes` / `MigrateLegacyBackend` / `ReconcileQuota`)
excludes normal provider intents, credential creation/delivery, and decommission by construction; an
`AdminActionPermit` names its audience `RunnerRole` and its single bound action. `decideAdminPermit` /
`applyAdminPermit` / `stepAdminPermit` accept a permit only if its audience is the `AdminActionRunner` AND
its action is the runner's instantiated one AND it is fresh — exactly once. A cross-role or cross-action
permit is refused (audience/action are checked before state), an expired permit is refused, replaying the
consumed nonce is idempotent (a lost response recovers by the stable nonce), and a divergent nonce after
consumption conflicts. Validated by `test/unit/LifecycleAuthorityAdminAction.hs` (8 cases) plus
`prodbox dev check` exit 0 and the full `LifecycleAuthority*` suite 52/52.
**Implementation**: **Increment G landed** — `src/Prodbox/Lifecycle/Authority/TlsRetention.hs` is the pure
versioned TLS-retention promotion/restore fold (closes Validation item 7). A `RetainedTlsRef` binds the
immutable `RetentionVersion`, the certificate serial / SPKI / `notAfter`, the ciphertext / wrapped-DEK
digest, and the source Kubernetes Secret UID / resourceVersion. `decideTlsPromotion` / `applyTlsPromotion`
/ `stepTlsPromotion` CAS-promote the current reference only after exact source re-observation AND Adapter
byte read-back, refusing an out-of-order / stale version, a validity regression, or an unapproved key
(SPKI) change; the exact current version is an idempotent no-op (response-loss recovery). `decideTlsRestore`
is a total ADT that applies the exact committed reference on an intact read-back (never S3 latest / list
order), permits fresh issuance only on positive authoritative absence or trusted-time expiry, and fails
closed on corrupt, digest-mismatched, or unobservable state. Validated by
`test/unit/LifecycleAuthorityTlsRetention.hs` (10 cases) plus `prodbox dev check` exit 0 and the full
`LifecycleAuthority*` suite 62/62.
**Implementation**: **Increment H landed** — `src/Prodbox/Lifecycle/Authority/Config.hs` is the pure
in-force-config observe / propose-CAS fold. The Authority owns the in-force configuration as a monotone
generation (`ConfigGeneration` + `ConfigSchemaVersion` + `ConfigDigest` + opaque `ConfigReference`),
seeded exactly once from the bounded Tier-0 boot projection and thereafter advanced only by a
compare-and-set. `decideConfigPropose` / `applyConfigPropose` / `stepConfigPropose` refuse an unsupported
schema, a CAS before seed, a re-seed after seed, and a mismatched expected-prior generation; re-proposing
the in-force schema+digest is an idempotent no-op (a lost response converges rather than forking a
generation). `observeInForceConfig` serves the current generation; encryption and role-scoped projection
of the referenced blob remain the interpreter's. Validated by `test/unit/LifecycleAuthorityConfig.hs`
(8 cases) plus `prodbox dev check` exit 0 and the full `LifecycleAuthority*` suite 70/70. This completes
the pure authority-core Deliverables (Increments A–H).
**Implementation**: **Increment I landed** — `src/Prodbox/Lifecycle/Authority/OutboxSim.hs` is the pure,
deterministic crash/restart reference interpreter the Independent Validation calls for. It composes the
durable operation journal and `decideOperationRecovery` over an in-memory fake substrate (a durable journal
plus a keyed effect target whose cell carries an apply-counter), with no object store, Vault, clock, AWS,
Kubernetes, or later phase. `armOperation` journals the intent before the effect; `runEffect` applies and
completes (the crash-free path); `armAndApply` is the "crash after effect, response lost" substrate; and
`recoverOperation` re-observes and either executes the armed intent (source still current), recovers the
observed result WITHOUT re-applying (proven by the apply-counter staying at 1 — at-most-once), or fails
closed leaving the record armed (diverged / unobservable). Validated by
`test/unit/LifecycleAuthorityOutboxSim.hs` (7 cases: crash-free once; crash-before-effect execute;
lost-response at-most-once recovery; diverged fail-closed; idempotent re-arm; completed-operation no-op
recovery/re-run + result lookup; unknown-operation no-op) plus `prodbox dev check` exit 0 and the full
`LifecycleAuthority*` suite 77/77.
**Remaining Work**: None on Sprint `4.48`'s independently validatable pure authority surface.
Binding the three retained projections to the host-direct store is Sprint `4.51` storage-transport
work; migrating production callers and deleting gateway-hosted authority transport is Sprint `4.50`
cutover work. Keeping either higher-numbered surface here would violate Standard N. The completed
4.48 authority kernel is their input, not their validation dependency.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/haskell_code_guide.md`, and
`documents/engineering/chaos_hardening_doctrine.md`

### Objective

Make retained lifecycle work a durable asynchronous operation owned by a dedicated authority
process, rather than a long host HTTP request whose correctness depends on gateway availability and
a best-effort release response.

### Deliverables

- Define pure `AuthorityState`, `AuthorityCommand`, and `AuthorityEvent` ADTs with total
  `decide`/`evolve` folds plus a versioned `OperationRecord`; interpreters execute only durably
  committed outbox intents and feed authoritative observations back as commands.
- Define `GenesisFrozen -> EstablishAuthorityBackup -> BackupEstablished` as the only pre-normal-
  admission fold. It primary-journals deterministic S3/IAM intent, recovers applied/lost key create
  by finite inventory delete/remint, seals the credential, writes/read-backs the complete initial
  envelope/blob set through the physically separate Backup Adapter, and opens normal admission only
  after the home Target Agent generation and backup receipt are both read back. No provider/DNS/
  suite effect is legal in genesis; primary loss can leave only the registered deterministic
  backup resources, removable/read-backable with a fresh admin prompt before retry.
- Have Broker baseline create the exact Transit genesis-signing trust. Authority issues a one-time
  signed `GenesisPermit` bound to service/signing generation, target/path, primary storage
  generation, nonce/intent digest, deterministic AWS/adapter coordinates, and expiry. Only the
  mode-indexed Credential Provisioner holds prompt bytes; core Authority receives typed
  observations/receipts. The home Agent CAS-records permit consumption/disablement and refuses
  replay, forged transport, opaque-commitment/path drift, or expiry.
- Stream prompt bytes only after Pod-UID/image/ServiceAccount/permit attestation over authenticated
  bounded Job stdin/attach; never argv, env, ConfigMap, Secret, disk, or logs. The Provisioner
  bounds and mlocks owned mutable buffers, disables core dumps, best-effort zeroizes only those
  buffers, revokes its session, and is deletion-read-back; process/Pod termination is the
  enforceable boundary and no byte-erasure claim is made for runtime/library copies. It returns a
  typed signed receipt. Disconnect/restart requires re-prompt but resumes the same permit and
  deterministic key inventory, never a blind new create.
- For first reconcile, compile a bounded secret-free provisioning plan from Tier-0 and the managed
  identity registry; bind its exact ordered action/coordinate/count/deadline digest into the Genesis
  permit and Job attestation. The retained prompt session may accept only the next unconsumed member
  after its predecessor receipt and a separate backup-receipted permit. The plan is not batch
  authority; drift, reordering, widening, or a later rotation requires a fresh Job/prompt.
- Define `BackupRepairFrozen` as the only post-genesis primary-only fold. Temporary/unobservable
  backup failure keeps admission frozen and waits; positively absent key/bucket or proven policy
  drift primary-journals a signed one-time repair permit. The mode-indexed Credential Provisioner
  creates/rotates deterministic resources, the Agent delivers the next LongLived generation, the Adapter full-
  copies/read-backs every current envelope/blob and commits the first new receipt, and Authority
  reopens only under a greater epoch. No normal external effect runs during repair.
- Define the disjoint `AdminActionPermit action` family and a separate attested Admin Action Runner
  for one receipt-committed `DestroyAwsSes`, legacy-backend migrate/retained-store compatibility,
  or quota reconcile-and-status action. `DestroyAwsSes` is a closed always-run dependency program:
  it first proves target consumers quiescent and commits the non-credential provider desired-absence
  sub-intent to the Provider Worker. Only after that worker's stack-absence receipt may the Admin
  Action Runner delete/read back the registered SMTP key family, least-privilege policy, and
  principal. While Target Agents remain live it finally tombstones/read-backs target generations
  and retained-home custody; every attempted-node failure is aggregated. Stable operation/
  provider-request identity and authoritative read-back make response loss resumable. It cannot
  create/deliver credentials, accept a normal provider intent, widen coordinates, or perform
  decommission; the Provider Worker and Credential Provisioner cannot accept its permit.
- Accept idempotent operation submission and return an `OperationId`; expose status/watch/cancel
  separately. Bind the ID to epoch/client/durable client sequence/request digest; retain per-client
  sequence floors, nonterminals, and bounded terminal request/result tombstones for a configured
  idempotency window. Refuse when capacity is full and return `OperationIdExpired` below the
  compacted floor rather than treating an old ID as new. A client disconnect never determines
  operation outcome.
- Journal intent before provider effects and journal observed/committed outcomes afterward. On
  restart, replay every nonterminal record and decide resume, compensate, wait, or refuse.
- Own validated serializable authority-clock observations/high-water, monotonic fence allocation,
  lease acquisition/renewal, Model-B checkpoint CAS, Pulumi operation serialization, and operation-
  result lookup inside this one service. Process-local monotonic deadlines are never persisted;
  clock regression/unobservability refuses time-sensitive mutation after failover.
- Publish checkpoint/config blobs through aggregate `PendingBlobRef` → write/read-back → CAS-
  promote. GC holds its own fence and deletes only blobs absent from pending/current/retained sets
  across two scans separated by grace. Every authority transition writes a digest-verified
  encrypted backup prepare containing the canonical evolved envelope bytes plus verified backup-
  blob references, CASes the primary, and read-backs a backup commit receipt before any external
  effect. Primary retained MinIO and the independently credentialed long-lived S3 backup coordinate
  may not alias a bucket/device/failure domain. Blob ciphertext is written/read back in both before
  promotion; store-loss restore accepts only receipt-committed transitions, restores every
  referenced byte, freezes writers, and increments epoch.
- Own `ConfigObserve`/`ConfigProposeCas`: validate and encrypt immutable in-force-config blobs,
  CAS their schema/generation/digest/reference in the aggregate, and serve role-scoped projections
  while starting only from the bounded Tier-0 authority boot projection.
- Own a versioned TLS-retention fold/outbox serialized by substrate plus exact canonical certificate
  scope set. One fenced candidate binds
  Kubernetes Secret UID/resourceVersion, certificate serial/validity/SPKI, ciphertext/wrapped-DEK
  digests, immutable S3 object version, and target read-back. Only exact source re-observation plus
  Adapter byte read-back may CAS-promote the Authority's current reference; stale/out-of-order
  receipts or an unapproved key/validity regression refuse, and response loss recovers the same
  immutable version. Restore names that committed reference, never S3 latest/list order. A total
  restore ADT permits issuance only after positive authoritative absence or trusted-time-validated
  expiry; corrupt, digest-mismatched, or unobservable state fails closed. The separate TLS Adapter
  stores ciphertext only; the retained home TLS Transit generation is referenced, not copied into
  ephemeral AWS Vault.
- Use Sprint `1.62` native object-store and renewable Vault sessions; no `aws s3api`, temporary
  object bodies, per-request login, or gateway route is part of authority storage.
- Keep provider truth external: all decisions consume typed observations and mandate positive
  postconditions; an unobservable result never lowers to absence or success.

### Validation

1. Exhaustive transition tables cover submission, deduplication window/saturation/expiry,
   contention, renewal, cancellation, clock restart/regression/unobservability, every crash
   boundary, stale fences, and terminal result lookup.
2. Applied-but-response-lost cases converge by re-observation and operation ID rather than becoming
   unknowable.
3. Journal codec properties prove versioning, bounded size, redaction, and decode/encode round trip.
4. Deterministic clean-install/crash simulations cover every genesis boundary, prompt attach/
   disconnect/Job restart, session revocation, owned-buffer best-effort zeroization, process/Pod
   absence, first-reconcile plan-digest/member/count enforcement, finite permit succession, missing
   prior receipt, later-action fresh-prompt enforcement, forged/replayed permit, response loss,
   exact registered residue cleanup, and refusal of normal
   admission before `BackupEstablished`.
5. Backup-repair tables cover temporary outage, positive key/bucket absence, policy drift,
   unobservability, permit replay, response loss, crash at every copy boundary, old-generation
   revocation, exact residue cleanup, and greater-epoch reopen.
6. Admin-action tables reject cross-action/cross-role permits and recover quota/destroy/migration
   response loss through stable identity and authoritative status/read-back.
7. TLS tables cover concurrent/out-of-order renewal, stale Secret versions, key/validity regression,
   applied-response-lost put, immutable-current restore, positive absence/expiry issuance, and
   corrupt/digest-mismatch/unobservable refusal.
8. Deterministic multi-controller simulations prove one active fence and stale-writer refusal;
   pending-blob/GC interleavings cannot create a dangling reference, and primary-loss restore from
   the independent backup reconstructs exact envelope/blob bytes before activating a greater epoch.
7. Unit/integration suites, warning-clean build, and `prodbox dev check` pass.

### Closure Boundary

Sprint `4.48` closes on the independently validatable pure Authority kernel. Dedicated-role
rendering, target delivery, and production cutover are deliberately separate surfaces owned by
their corresponding chart and lifecycle sprints; none is remaining work required to keep this
historical sprint Done.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - authority state machine,
  journal, API, and persistence.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - asynchronous desired-state
  operations and authority ownership.
- `documents/engineering/pure_fp_standards.md` - pure transition kernel/effect data.
- `documents/engineering/vault_doctrine.md` - authority session and keyspace custody.
- `documents/engineering/haskell_code_guide.md` - durable actor/interpreter lifecycle.
- `documents/engineering/chaos_hardening_doctrine.md` - journal crash matrix.

**Product docs to create/update:**

- `README.md` - retained authority role and operation-status workflow.

**Cross-references to add:**

- Link the managed-resource registry and Pulumi wrappers to the authority operation API.

## Sprint 4.49: Fenced Target Outbox and Target Secret Agent [✅ Done]

**Status**: Done (validated 2026-07-26) — the bounded target-commit protocol and closed target-store
boundary had already landed under Sprint `4.47`; Sprint `4.49` records them as the retained
Authority's target outbox rather than introducing a competing delivery authority.
**Deployment qualification**: pending
**Implementation**: `Prodbox.Lifecycle.TargetCommitIntent` owns the bounded canonical-CBOR global
intent projection, registered targets, generation/digest/fence/deadline binding, prepare/revalidate/
single-sink-CAS/read-back/complete decisions, recovery, terminal retirement, and compaction.
`Prodbox.Lifecycle.TargetCommitInterpreter` executes that protocol with at most one target mutation
per run and fresh authority observations. `Prodbox.Lifecycle.TargetSecretStore` is the allowlisted,
redacted target-local CAS boundary. Sprint `4.48` supplies the durable operation ID and admitting
authority epoch around this already-fenced outbox.
**Blocked by**: Sprint `4.48`
**Independent Validation**: pure outbox folds and loopback agents with fake Vault interpreters
cover cross-target delivery, restart, duplicate requests, and read-back without live substrates or
a later phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/integration_fixture_doctrine.md`, and
`documents/engineering/pure_fp_standards.md`

### Objective

Turn cross-substrate secret materialization into a durable, independently retryable delivery whose
target identity and fencing metadata are explicit, while keeping target Vault authority local to
the selected substrate.

### Deliverables

- Define bounded versioned `DeliveryIntent`, `DeliveryState`, `DeliveryDecision`, and
  `DeliveryEffect` types under the authority journal.
- Add a closed `OperatorMaterialRequest` install/rotate/revoke flow. It includes the deterministic
  `LongLived` SES-SMTP principal, least-privilege send policy, finite access-key family, and
  per-target derived generation. The `OperatorMaterialPermit`-selected Credential Provisioner is
  the sole create/rotate/remint and repair-time key-delete interpreter; Pulumi/Provider Worker has
  no constructor for that identity. The Authority asks the target agent to seal the bounded
  payload, commits only ciphertext/generation/opaque Agent-HMAC commitment/outbox state, and never
  persists plaintext provider, Authority-backup, TLS-retention, Gateway-DNS, cert-manager-DNS01,
  SES-SMTP, or ACME EAB material.
- Add a retained-home Agent custody/rewrap lane whose request family is closed over each explicitly
  registered non-recoverable cross-substrate payload, initially `SesSmtpSource` and `AcmeEabSource`;
  there is no arbitrary path, byte-export, or generic decrypt constructor. Initial material enters
  once through a schema-indexed ingress: direct Credential-Provisioner-to-home-Agent handoff for
  identity-derived SMTP material, and a distinct attested external-material ingress/permit for ACME
  EAB. EAB bytes never reuse the AWS-admin prompt/session or its Genesis-bound identity plan, and
  `config setup` remains Tier-0-only. The schema-specific ingress derives where required before
  handoff—the Credential Provisioner alone constructs the SMTP payload in bounded memory (username
  from access-key ID; password derived from the one-time secret plus region) and discards the raw
  IAM secret—then the Agent Transit-seals only the closed
  generation-bound source and returns an opaque one-shot source-ingest receipt. For a committed
  target intent it rewraps only that registered payload to the attested destination Agent. The Authority
  transports ciphertext and receipts only, so a fresh AWS Agent/Vault can restore the same SMTP
  generation without an admin re-prompt or access-key rotation.
- Represent that lane as a schema-indexed payload/command/event/effect family with total pure
  ingest/rewrap/retire folds. `SesSmtpSource` can contain only the derived region-bound SMTP
  username/password plus generation metadata; `AcmeEabSource` can contain only its distinct EAB
  schema. Neither can carry a raw IAM secret, arbitrary Vault path, or generic bytes, and their
  interpreters are disjoint.
- Add a genesis-only exact-path arm on the home Target Agent for
  `secret/aws/authority-backup-store`. It accepts only the signed `EstablishAuthorityBackup`
  genesis intent, CAS-seals/delivers one LongLived generation, and is permanently disabled for
  genesis after `BackupEstablished`; later rotation uses ordinary backup-receipted outbox intent.
- Add the same signed one-time proof discipline for `BackupRepairFrozen`: CAS-consume the repair
  permit, deliver only the next backup generation, and disable it after the new receipt/greater-
  epoch activation. A normal outbox or forged transport cannot invoke this exceptional arm.
- Make sealing idempotent by operation ID and a domain-separated Agent/Vault-HMAC commitment: the
  agent CAS-stores and reads back only the ciphertext/key-version receipt before replying. A lost
  seal response is re-observed without retaining plaintext; same-ID/different-commitment refuses.
  No raw hash of plaintext or low-entropy credential material crosses the Agent boundary.
- Deliver child recovery-share custody through the same parent-target sealing/outbox discipline.
  The payload includes the encrypted init receipt, burn-recipient evidence, custody generation,
  and later short-lived-root accessor-revocation attestation; it can never contain a usable initial
  root token or plaintext recovery share.
- Add dedicated TLS Kubernetes-Secret capability kinds. The selected Agent alone reads the exact
  issued Secret, uses an attestation-bound DEK from the retained home Agent, exports digest-bound
  ciphertext/wrapped-DEK bytes, and on restore decrypts/applies/read-backs that exact Secret before
  issuance. Authority/Adapter see ciphertext only; bounded plaintext is process-local.
- Commit an outbox intent before contacting a target; include operation ID, target identity,
  generation, digest, authority epoch/fence, deadline, and idempotency key.
- Make the mutation constructor an opaque signed `CommittedIntentRef` bound to target/action
  digests. The agent verifies issuer, current epoch/fence, target binding, generation, and deadline
  server-side; transport access alone cannot authorize a write.
- Expose a narrow Target Secret Agent API for allowlisted CAS/read-back only. The agent owns its
  substrate-local Vault session. It may transiently seal/materialize the allowlisted credential
  payload named by a committed outbox proof, but cannot use that credential against provider APIs,
  return plaintext, access authority checkpoints, or read arbitrary target paths.
- Make duplicate delivery idempotent, stale fence/generation terminal, transport failure retryable
  within policy, and ambiguous responses recoverable by exact read-back.
- Resume incomplete deliveries after either service restarts; compact only terminal deliveries
  whose provider revision and target generation remain durably referenced.
- Retain every non-recoverable source receipt while any target generation or dependant is live.
  Explicit resource teardown tombstones the source only after all target retirements are read back;
  ordinary postflight cannot delete it.
- Give `TargetGenerationRetired` and `CustodySourceRetired` physical Vault KV-v2 semantics. Rotation
  may `destroy` only the exact superseded secret-bearing versions after the Authority proves no
  dependant/outbox/rollback reference remains; it preserves the current version and metadata. Full
  revocation must destroy every exact secret-bearing version, delete the path metadata, and read back
  version/data/metadata absence before the terminal event. KV-v2 soft delete, a logical Authority
  tombstone, or an unverified metadata delete is never sufficient.

### Validation

1. Decision tables cover genesis-only delivery, new, duplicate, stale, conflicting, applied-response-lost, unavailable,
   retired-target, child-recovery-custody, and forbidden-root-token cases.
2. Cross-substrate simulations prove a home authority cannot silently redirect an AWS delivery or
   substitute one target's evidence for another.
3. Agent route/policy tests reject arbitrary Vault paths and all authority/provider operations.
4. Fresh-destination simulations destroy the AWS Vault/Agent, restore the same SMTP and ACME EAB
   generations from retained-home custody, and prove no prompt, key rotation, generic export, or
   Authority plaintext occurs.
5. Fake-Vault rotation/revocation tables prove superseded KV-v2 versions are physically destroyed
   only after their final reference, full revocation destroys all exact versions plus metadata and
   reads back absence, and soft delete or partial/unobservable destruction cannot commit retirement.
6. Bounded journal/compaction properties and loopback protocol tests pass.
7. Unit/integration suites and `prodbox dev check` pass.

### Scope Reconciliation

- SMTP/EAB schema-specific custody is Sprint `8.11`'s email-workflow specialization.
- Child recovery custody remains the completed Sprint `2.33` boundary.
- TLS Secret retention remains Sprint `4.48`'s versioned TLS fold.
- Production caller migration and gateway-route deletion remain Sprint `4.50`.

Assigning those independently owned surfaces to 4.49 would duplicate authorities and create
backward validation dependencies contrary to Standard N.

### Remaining Work

None. The focused Sprint `4.47` suite passes 84/84, including the target registration, prepare,
read-back, response-loss recovery, stable retirement, bounded codec, allowlisted route, and redacted
store cases. `prodbox dev check` passes.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - target agent and outbox.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - durable cross-authority effects.
- `documents/engineering/vault_doctrine.md` - target-local Vault authority and least privilege.
- `documents/engineering/integration_fixture_doctrine.md` - fake target-agent boundaries.
- `documents/engineering/pure_fp_standards.md` - pure delivery transition model.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link selected-substrate resolution to `TargetIdentity`, never a gateway URL.

## Sprint 4.50: Authority-Epoch Cutover and Legacy Transport Removal [✅ Done]

**Status**: Done — Sprints `4.48` and `4.49` are Done, and the 2026-07-31 source-level closure audit
corrected the prior status wording. The versioned migration kernel, retained-CAS abstractions,
role-indexed dispatch seam, request codecs, four injected-repository role builders, and substantial
decommission library scaffolding are landed. The production in-cluster Authority repository,
authenticated operation/checkpoint admission, Broker custody/CLI cutover, and production
decommission composition have since landed. The all-five-role steady-state installation, Target
Agent complete/read-back path, provider effects, config aggregate/client, epoch-fenced caller
migration, legacy route/transport deletion, clean-install authority choreography, and
credential/custody cutover are still code-owned work. Standard O separates an implemented
production path from its live exercise;
it does not turn missing production code into non-blocking evidence. Standard-P qualification remains
a distinct later campaign after the code-owned cutover and negative scans close.
**Audit correction (2026-07-31)**: the decommission subsystem was initially overstated as
code-complete: manifest/permit authentication and complete-inventory binding, verifier/receipt
header binding, semantic node/attempt validation, observe-before-retry crash recovery, real
pinned-artifact self-execution, production node interpreters, external receipt acknowledgement, and
`CLI.Nuke` composition were missing. Increment FF below now closes that code-owned subgraph and
records its focused evidence; this correction is retained as the audit trail rather than rewritten
as if the gap had never existed.
**Audit correction (2026-07-31 — executable custody boundaries)**: a second source-level pass found
that several compiled foundations still do not constitute the supported production topology.
`Bootstrap.Broker.applyBootstrapBrokerStart` still installs `failClosedProductionEngine`, whose
durable store, evidence, Vault, and one-shot-worker boundaries refuse every mutation and never open
readiness. The committed Credential Provisioner chart defaults to `aws-admin`, while the executable
currently accepts only `external-acme-eab`; normal AWS/genesis/repair members therefore have no
closed runtime command. The steady-state `TargetMaterialEndpoint` previously accepted and returned
`TargetSecretPayload` in the long-lived Agent process; its metadata-only observation cutover is now
in progress, but the required attested one-shot target worker is not yet production-bound. The
experimental EAB seal-only helper also used the ingress worker's Vault session and did not implement
the retained-home Agent rewrap/delivery lane required by §5.5, so it is being removed from the
supported path rather than counted as custody. Finally, public-edge TLS callers still use the direct
Kubernetes-Secret/admin-S3 helpers, the reconcile step still only observes backup admission instead
of driving `reconcileAuthorityBackupAdmission`, and the Admin Action Runner remains a pure permit
fold without its attested executable boundary. These are code-owned Sprint-4.50 blockers; none is
reclassified as Standard-O evidence. The sprint remains Active until the executable compositions,
negative scans, and independent validation below close.
**Audit correction (2026-07-31 — clean-install Broker session order)**: production composition found
two impossible assumptions in the provisional Broker protocol. A freshly initialized Vault cannot
use the baseline-created Kubernetes auditor to inventory root-token accessors before that baseline
exists, and a worker intent cannot preallocate the token accessor that Vault assigns only after a
successful login. The authoritative correction is to use the generated-root capability transiently
to install the baseline, establish the narrow auditor identity, then inventory/revoke every root
accessor (including the transient bootstrap root) and prove zero before readiness. Worker intent now
binds a logical operation/session identity; the optional server-issued accessor is recorded only
after login and exact-accessor revoke/absence is required when it exists. The typed state/codec and
crash/replay fixtures are being reordered accordingly, so the sprint remains Active until that
clean-install sequence validates.
**Audit correction (2026-07-31 — Admin Action executable effects)**: wiring the Runner command
exposed three additional production-boundary gaps. The Target Agent's decommission tombstone routes
correctly require a verified decommission manifest and therefore cannot accept an Admin Action
permit; legacy-backend migration had only the host-interactive Authority transport; and quota
increase submission had no durable recovery for a possibly-applied request. Closure now requires
separate Admin-Action-permit-scoped Target generation/custody tombstone routes, a runner-only
authenticated Authority migration adapter, and a persist-before-effect quota journal that resolves
response loss by authoritative quota/change-history observation and stable absence before any
retry. These routes remain exact-plan capabilities and do not weaken the decommission manifest
boundary or grant the runner generic Target/object-store access.
**Implementation in progress (2026-07-31 — Admin Action executable effects)**: the signed Admin Action
permit, attested Runner, runner-only Authority migration adapter, and permit-scoped Target
generation/custody tombstone routes are now production-composed. Legacy-backend migration persists
its prepared Authority state, publishes the canonicalized checkpoint through the registered
`aws-ses` checkpoint lane with primary/backup read-back, and permits source deletion only before a
positive absence commit. Service Quotas now journals the exact request before its first external
effect, observes current quota plus the complete paginated request history after ambiguity, requires
two stable-absence scans, and permits at most one retry. The worker and its distinct narrow auditor
session are separate, and the worker's exact server-issued Vault accessor is revoked and proven
absent. A follow-up production audit found that the auditor currently performs only `revoke-self`
and does not preserve and prove absence of its own server-issued accessor; that cleanup tail and its
failure fixtures remain open. The Admin CLI and production destroy path otherwise use these
authenticated routes; no Admin Action code opens Authority storage, host authentication, or a
HostDirect transport. A warning-as-error unit executable build passes, the endpoint/quota/
decommission-client/parser selection passes 14/14, and the targeted transport scan is empty. This
increment therefore remains in progress and does not advance Sprint `4.50`, whose Broker,
Credential Provisioner, Target/material, Provider/SES, and clean-install gates also remain open.
**Implementation completed (2026-08-01 — Admin Action terminal cleanup)**: the Runner now serializes
its exact Vault role lane through the retained service-session journal, persists preclean and the
single login attempt before a service accessor can become active, and cleans every correlated stale
accessor before admitting a greater fence. The worker's server-issued accessor is directly revoked
and then proven absent by a distinct bounded, nonrenewable, accessor-free batch auditor; invalid
auditor-role logins are revoked and a later conforming auditor must prove the complete role inventory
stably empty. Synchronous exceptions and cancellation run both session and exact Job/Pod cleanup,
while cancellation is rethrown and no receipt escapes a failed absence proof. Focused validation
passes all 15 Admin Action lifecycle and all 14 finite one-shot Vault-session cleanup fixtures,
including login/read-back ambiguity, response-lost revoke, auditor drift/login failure, thrown
effects, cancellation, UID substitution, and terminal receipt recovery. This closes the Admin Action
terminal-cleanup item only; the other Sprint `4.50` composition gates remain open.
**Implementation in progress (2026-07-31 — child-custody cutover)**:
`Prodbox.Cluster.Federation` no longer defines or accepts `ChildInitCustody`, a child `root_token`,
or an init-KV coordinate, and its registration plan has no root-token write gate. `Prodbox.Vault.Seal`
no longer projects a child-custody record from the init response. The child metadata and plan
fixtures now prove the reusable-token and `init_kv_path` fields absent, while the child Transit
policy is limited to its exact encrypt/decrypt lane. Engineering doctrine marks the old record and
readers as removed historical provenance. The warning-clean library and complete unit executable
now build after the concurrent Broker/checkpoint edits converged; aggregate Sprint validation still
waits on the remaining supported-path cutover and therefore this increment does not independently
satisfy Validation 4 or advance the sprint status.
**Implementation completed (2026-08-01 — Broker production registry and readiness)**:
`applyBootstrapBrokerStart` now constructs `productionBrokerEngine`; there is no fail-closed engine
installed on the supported executable path. The production registry is constructed from the actual
evidence, retained-store, Transit-rotation, PGP, one-shot worker, physical, and local boundaries and
contains every one of its 117 closed capability arms exactly once. Readiness is a derived decision
that additionally requires live Store, Vault, PGP, Kubernetes lease, and pinned controller-image
observations. Physical execution obtains a fresh fence/lease authorization before mutation, and the
durable root-init, generated-root, provisioner-session, child-delivery, and rotation paths recover
their response-loss and crash windows before replay. Focused validation passes 5/5 registry/readiness,
14/14 physical crash/fence/custody, and 4/4 native Kubernetes attestation/cleanup fixtures. This
closes the Broker production-registry item only; the remaining Sprint `4.50` cutovers stay open.
**Implementation in progress (2026-07-31 — retained operator-material aggregate)**:
`Prodbox.Lifecycle.Authority.RetainedMaterial` now defines the closed, nominally
schema-indexed SES-SMTP/EAB custody aggregate. A caller supplies only a registered target identity;
the schema fixes the physical target to `secret/keycloak/smtp` or `secret/acme/eab`, so an arbitrary
secret path is not constructible. Its public coordinate constructors admit only
`ClusterRetained` custody or `CrossClusterDurable` delivery outboxes; plaintext is absent from every
source, intent, receipt, command, decision, and durable wire value. The fold requires an exact
current ciphertext/read-back observation before delivery, distinguishes positive absence, corrupt,
digest-mismatched, and unobservable custody, makes response-loss replay idempotent, and retains a
rotated predecessor through its absolute grace deadline and every pending dependant before an
absence-read-back retirement can commit. Recovery uses a bounded versioned canonical-CBOR envelope
whose schema tag is checked against the singleton type index and whose fields are rebuilt through
smart constructors and aggregate invariants. Focused fixtures cover the state transitions,
cross-schema refusal, canonical round trip, and encoded-size bound. The module compiles under the
integrated warning-as-error library build; the complete unit gate is still running behind concurrent
strict-coordinate fixture migration. This is the ciphertext-only Authority half of §5.5, not the
production cutover: retained-home one-shot Transit custody/rewrap workers, target delivery binding,
baseline policy, and producer/caller integration remain blockers below.
**Audit correction (2026-07-31 — selected Target Agent and one-shot custody)**: the first
production-binding draft allowed the selected Kubernetes Agent boundary to be chosen independently
of the Authority-signed target intent and opened retained custody through the long-lived Target
Agent Vault session. Both violate the closed topology. The signed intent, accepted trust,
committed outbox, attested Job/Pod, and worker protocol must bind one exact `TargetAgentIdentity`;
wrong-Agent substitution refuses. A cluster identity alone is not an Agent identity: the binding
must distinguish the exact Authority-registered Agent generation/rollout and its attested Job,
Pod, and ServiceAccount UIDs so a different rollout in the same cluster cannot substitute.
Retained custody and rewrap run only inside an exact attested one-shot worker with its own bounded
Vault session, exact worker/auditor accessor-absence proof, and Job/Pod deletion/absence read-back.
The standing Agent remains metadata/coordinator-only.
**Implementation in progress (2026-07-31 — Provider Worker production binding)**:
the Provider Worker's authenticated production interpreter now covers the closed registered-stack,
checkpoint-scratch, SES, EBS-reaper, spot-price, operational-identity, and readiness vocabulary
behind a narrow-session interface. The three per-run Pulumi programs are selected by
typed stack/config pairs, run from the pinned `/opt/build` tree with the pinned Pulumi binary, and
hydrate/store checkpoints through the Lifecycle Authority client rather than a host object-store
fallback. The `aws-ses` Pulumi program no longer constructs or exports the SMTP IAM user, policy, or
access key; its two historical SMTP URNs remain typed read-only compatibility evidence for the later
Sprint `8.11` migration. Warning-as-error compilation and the Provider/SES invariant scan pass.
A follow-up production-composition audit found that the authenticated handler currently executes a
verified intent directly instead of first committing and recovering it through the retained
`ProviderWork` adapter, and that the production narrow-session runner reads Provider credentials
through the standing control-plane Vault session without an exact worker/auditor accessor-absence
tail. Both are code-owned blockers. This is also not yet the complete SES cutover: the
canonical-suite preparation call still selects the superseded host-direct SES transaction, and the
four native SES mutations do not yet converge the verification/DKIM/MX Route 53 records retained by
the non-credential Pulumi program. Those durable-execution, session, supported-caller, and DNS
effects remain explicit Sprint-4.50 blockers; they are not deferred to live proof.
**Implementation in progress (2026-07-31 — Credential Provisioner native IAM/S3 boundary)**:
`Prodbox.Aws.Native.Iam` and `.S3` now expose the finite typed observations and exact mutations
needed by the one-shot Credential Provisioner without ambient AWS environment/profile discovery.
`Prodbox.Lifecycle.CredentialProvisioner.ProductionIam` closes construction to the seven registered
credential classes, derives deterministic IAM identities/policies from the operator-material
registry, distinguishes a possibly-applied access-key create from a definite failure, and enforces
observe/delete/stable-absence/remint through the existing bounded execution fold. Authority-backup
bootstrap may create and harden the shared retained bucket; TLS retention may only adopt the exact
already-hardened bucket and refuses absence, prefix drift, or region drift. Fake-sender fixtures cover
all seven policies, wildcard exclusions, cross-class bucket-prefix refusal, TLS no-create behavior,
and response-loss classification, and the integrated library compiles warning-clean. This is the
AWS boundary only: the signed permit wire protocol, attested Kubernetes Job coordinator/runtime,
direct Target-Agent handoff, genesis/repair caller composition, complete unit gate, and supported
CLI/chart cutover remain code-owned blockers, so this increment does not advance sprint status.
**Audit correction (2026-07-31 — Credential Provisioner crash closure)**: a provisional executor
could create an IAM access key before durably recording its internal phase, trusted a freely
transported prepared-target observation instead of an Authority-signed receipt bound to the exact
selected Agent/owner/fence/outbox coordinate, and discarded the worker login accessor. That
executor is not eligible for production composition. Closure requires a persist-before-IAM phase
journal covering create intent, key observation, target receipt, and predecessor retirement;
restart must delete/read back stable absence and remint at most once after any ambiguous create.
The signed permit and prepared-target receipt bind the exact first-reconcile plan/member plus
selected Agent, owner nonce, fence, target, generation, digest, deadline, Job/Pod identities,
image, and ServiceAccount. Worker/auditor accessors and Job/Pod deletion each require exact absence
before the journal advances.
**Implementation in progress (2026-07-31 — durable first-reconcile journal)**:
`Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal` now owns the retained,
receipt-ordered continuation for the finite first-install plan. Its bounded, versioned,
canonical-CBOR value reconstructs every plan member and receipt through the existing smart
constructors, retains no credential bytes, resumes from the exact next member and prior-receipt
digest, makes an exact committed-receipt replay idempotent, and rejects divergent or out-of-order
receipts. The `ClusterRetained` Model-B repository distinguishes missing, corrupt,
endpoint-unready, unobservable, and concurrent-CAS observations. The module is registered and
warning-clean in the integrated library build; focused tests for restart recovery, replay,
divergence, corrupt/oversized bytes, CAS conflict, and endpoint-unready classification are landed
but the complete unit executable is still running behind concurrent route-registry expansion.
The production coordinator has not yet been cut over to this repository, so this checkpoint does
not close the Credential Provisioner remaining-work item or advance the sprint status.
**Implementation in progress (2026-08-01 — AWS-admin Job coordinator)**:
`Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator` now composes the authenticated
Authority prepare/observe/attest/authorize/complete protocol around one exact Kubernetes Job. It
prepares durable secret-free intent before creation, emits administrator material only through the
bounded post-attestation stdin frame, validates the worker receipt against the exact signed permit,
recovers a terminal Authority receipt after response loss, and always UID-cleans the Job/Pod with a
positive absence read-back before a receipt can escape. Synchronous exceptions are converted only
after cleanup, asynchronous cancellation is rethrown after cleanup, and positive absence closes a
lost delete response. The library builds warning-clean and the expanded AWS-admin Authority/
coordinator selection passes 10/10. At that checkpoint the production Kubernetes renderer/observer
and `StepEstablishAuthorityBackup` genesis/repair caller binding remained open, so the coordinator
increment did not close the Credential Provisioner item or advance Sprint `4.50`.
**Implementation in progress (2026-08-01 — AWS-admin Kubernetes boundary)**:
`Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes` now renders the canonical intent as an
immutable digest-pinned, Guaranteed-QoS, non-root Job with a bounded projected identity and no
administrator material in its manifest, argv, environment, Secret, or ConfigMap. The native
boundary recovers ambiguous create by exact read-back, independently observes the Job, sole owned
Pod, immutable image, ready/restart-free container, and ServiceAccount UID before Authority
attestation, attaches the credential frame only to that Pod, deletes with an exact Job-UID
precondition, refuses name reuse, and requires two stable Job/owned-Pod absence observations.
Deletion polling distinguishes an exact object still terminating from positive absence. The
warning-as-error library build passes and the expanded AWS-admin Authority/coordinator/renderer
selection passes 11/11. The `cluster reconcile` genesis/repair composition and its Authority Backup
Adapter copy/read-back callbacks remain open, so the Credential Provisioner item and Sprint `4.50`
remain Active.
**Implementation in progress (2026-08-01 — purpose-bound Authority aggregate export)**:
the Lifecycle Authority now exposes a dedicated authenticated `POST /v1/authority/backup/export`
route that returns only the exact canonical retained admission aggregate and only while its current
state matches the requested retained genesis-plan digest or backup-repair-permit digest. The caller
cannot select an object coordinate or arbitrary primary-store value; service callers are absent
from the route registry, malformed and oversized requests fail closed, the response is bounded to
1 MiB, and the client verifies the SHA-256 digest before exposing the opaque envelope. This closes
the missing primary-to-Adapter copy source without treating the read-only observation projection as
a backup API. The full package builds with `-Werror`, and the focused Authority Backup selection
passes 10/10, including wrong-purpose refusal. Binding this export and the Adapter copy/read-back
receipt to the genesis/repair coordinator in `cluster reconcile` remains open, so the Credential
Provisioner item and Sprint `4.50` remain Active.
**Implementation in progress (2026-08-01 — retained backup identity and Adapter health)**:
the admission aggregate now retains the exact Target generation receipt and immutable Authority
Backup digest alongside every open epoch instead of discarding either read-back receipt when
genesis opened. A temporary or unobservable freeze carries both prior receipts across restart and
reopens with them only after exact health recovers; a completed repair atomically replaces both
with the new Target generation and Adapter receipt. The
production copy boundary joins the purpose-bound Authority export to the aggregate-only Adapter
client, records only its content digest, and re-observes that exact digest to distinguish healthy,
positive absence, and corrupt/policy-drift state. This removes the prior impossible production
callback, where an open epoch contained no durable identity for the object it was required to
health-check. Warning-as-error builds pass for the library, main unit executable, retained-admission
suite, and authenticated-transport suite. Focused genesis, repair, coordinator, and Adapter
validation passes 37/37; the two separate retained/authenticated suites pass 27/27 each. The
Credential Provisioner target-generation permit composition and the final `cluster reconcile`
binding remain open, so Sprint `4.50` remains Active.
**Implementation in progress (2026-08-01 — deterministic genesis intent compilation)**:
the production backup reconciler now compiles the exceptional genesis AWS-admin request from the
retained `GenesisPlan` and the finite first-reconcile plan's member zero. Permit/operation identities
are deterministic hashes of the plan, the draft binds the exact Authority-backup IAM program,
digest-pinned worker image, Authority scope/endpoint, selected Target Agent rollout, target,
generation, request digest, plan binding, and absolute deadline, and the Authority remains
responsible for canonical prepared-target read-back and final Transit authorization. Completed
worker target read-back is projected into a versioned receipt that preserves generation, Vault
version, commitment, and request digest; the production generation parser refuses
non-production/opaque predecessor receipts instead of guessing a lost generation. The focused
Adapter/reconcile selection now passes 12/12.
The live coordinator invocation and backup-repair intent compiler remain open, so this increment
does not close the Credential Provisioner item or Sprint `4.50`.
**Implementation in progress (2026-08-01 — production backup reconcile composition)**:
the repair permit compiler now binds the open epoch, lost exact Target generation receipt,
predecessor Adapter receipt, deterministic repair coordinate, and strictly succeeding production
generation. Genesis and repair intents share the native AWS-admin coordinator, purpose-bound
Authority export, aggregate-only Backup Adapter copy/read-back, exact Target-generation
projection, and native Kubernetes Job boundary. `cluster reconcile` now calls this production
reconciler before ordinary lifecycle work and loads administrator material lazily only when a
genesis or repair effect is required; a healthy established epoch performs no credential prompt or
external mutation. The retained-admission and authenticated-transport suites pass 27/27 each after
the expanded retained wire shape, and the main unit executable passes 2,956/2,956. The repository
quality gate and live composition proof are the next validation checkpoints; the other explicit
Sprint-4.50 remaining-work items are unchanged, so the sprint remains Active.
**Validation checkpoint (2026-08-01 — production backup reconcile composition)**:
`prodbox dev check` passes after the production composition and doctrine updates, including the
pinned formatter, zero-hint HLint traversal, and warning-clean 461-module library/executable build.
The canonical live command `prodbox cluster reconcile` was then attempted and failed before any
infrastructure mutation because its binary-sibling `.build/prodbox.dhall` is absent; a host-wide
read-only search found no operator config to recover, only the generated unit-test fixture. The
fixture is not substituted for operator configuration. This leaves the revision-specific live
proof pending under Standards O/P without reopening the locally validated code path or blocking
the remaining Sprint-4.50 implementation work.
**Implementation in progress (2026-08-01 — post-genesis first-reconcile continuation)**:
the production compiler now forms each normal first-reconcile AWS-admin intent from the closed
member class with a stable scope/class operation identity, exact generation-one Target, selected
Agent rollout, immutable image, and class-matched native IAM parameters. Lifecycle Authority still
replaces the provisional fence, deadline, plan binding, and prepared-target receipt from its
retained journal before signing; a caller-supplied IAM class substitution refuses. The focused
Authority Backup selection passes 14/14 and the integrated unit executable builds warning-clean.
The production caller must next obtain a bounded authenticated projection of the retained journal's
exact next member and absolute deadline before coordinating members 1–4. Replaying a newly compiled
fixed list without that observation is intentionally not wired because it could conflict with an
already completed member after restart. Supplying the Lifecycle-provider account/role and the
class-specific zone/prefix parameters from a canonical non-secret projection also remains part of
this caller binding, so the broader Credential Provisioner item stays Active.
**Implementation in progress (2026-08-01 — retained first-reconcile continuation caller)**:
Lifecycle Authority now serves a bounded authenticated continuation projection containing only the
exact next registered credential class, retained member index/digest, and original absolute
deadline. The operator/harness client cannot select a journal coordinate or read journal bytes.
`cluster reconcile` repeatedly observes that projection, compiles class-matched IAM parameters,
coordinates one attested AWS-admin Job, and re-observes until the finite journal reports complete;
administrator credentials and the native STS account projection are loaded only while an actual
member remains. TLS retention uses the exact canonical home certificate-scope prefix, and Gateway
DNS/home DNS01 use the configured parent-zone identity. Restart cannot reset the retained deadline
or guess which member already completed. Focused Authority/coordinator tests pass 13/13 and
Authority Backup/continuation tests pass 15/15; `prodbox dev check` passes with zero HLint hints and
a warning-clean 461-module build. The remaining Credential Provisioner-owned gap is the concrete
Lifecycle-provider role/trust/policy substrate behind the now-bound exact role name; the current
native IAM program provisions only the assuming identity/policy/key and does not create that role.
Sprint `4.50` therefore remains Active.
**Implementation validated (2026-08-01 — Lifecycle-provider role substrate)**: the native
Credential Provisioner IAM program now reconciles the deterministic Lifecycle-provider role, its
exact account-bound trust principal, and its closed provider permissions policy after reconciling
the distinct assuming user/policy and before any access key is minted. Every role write is followed
by authoritative name, account-bound ARN, trust-document, and inline-policy read-back; an
already-existing role is converged through the same path, and teardown removes/read-backs the role
policy and role as part of the registered identity lifecycle. Focused Credential Provisioner tests
pass 27/27 and native AWS client tests pass 56/56; `prodbox dev check` passes with zero HLint hints
and a warning-clean 461-module build. This closes the
Lifecycle-provider role-substrate item without closing Sprint `4.50`; retained external-material
custody and the later caller/deletion items below remain code-owned.
**Implementation in progress (2026-08-01 — ACME EAB producer caller)**: the home edge reconcile
no longer invokes a fail-closed fixture placeholder. A populated `test-secrets.dhall` EAB pair is
encoded only as the bounded external-worker stdin frame and submitted through the authenticated
Lifecycle Authority external-ingress client, retained intent/permit/outbox, and exact attested
Kubernetes Job workflow; the host has no direct Target or Vault write callback. The library and
complete unit executable build warning-clean, the workflow's response-loss/cleanup suite passes
12/12, fixture parsing/frame tests pass 3/3, and `prodbox dev check` passes with zero HLint hints
and a warning-clean 461-module build. A bounded current-ingress projection now lets callers select
install, exact replay with the retained original deadline, or next-generation rotation without
selecting or reading a retained coordinate. Both edge reconcile (operator principal) and
cluster-bootstrapping harness suites (test-harness principal, inside always-run AWS cleanup) use the
same coordinator. This is not yet the custody-item closure: SES-SMTP and both selected-target
rewrap deliveries remain open.
**Implementation in progress (2026-08-01 — SES-SMTP retained-custody producer)**: the AWS-admin
worker now overlays a schema-specific SES branch on its delivery boundary after permit
verification and SMTP password derivation. The branch derives the complete canonical payload from
the registered sender identity (`email-smtp.<region>.amazonaws.com`, port 587,
`noreply@<identity>`, display name `prodbox`, derived username/password), Transit-seals it through
the exact retained-home SMTP lane, observes recovery by exact generation, and projects the actual
Provisioner Pod/image/request plus custody Vault version/commitment into the durable worker receipt.
The one-shot Credential Provisioner Vault policy gains only SMTP source read/CAS plus retained
encrypt/HMAC—never decrypt, EAB, final-target, or generic KV authority. The Credential Provisioner
suite passes 28/28 and `prodbox dev check` passes with zero HLint hints and a warning-clean
462-module build. Selected-target SMTP/EAB rewrap remains open, so this increment is not claimed
complete.
**Implementation validated (2026-08-01 — direct selected-Target delivery and receipt catalog)**:
the default verified AWS-admin worker now composes the Authority intent client, Target Agent
metadata observer, bounded controller-auditor login, and attested one-shot Kubernetes materializer
as its non-SMTP fallback. The durable Target record includes the exact request/action/Pod UID/image
tuple required to reconstruct the opaque receipt after a lost response. An older observed
generation remains retryable; an unexpectedly newer generation is a terminal binding refusal.
Credential Provisioner-to-Agent HTTP is metadata-only and NetworkPolicy-scoped; plaintext still
crosses only the already-attested Pod attach stream. The warning-clean executable build covers 463
modules, and the complete unit gate passes 2,965 main + 27 retained-admission + 33 authentication +
27 authenticated-transport cases. The retained-home Target Agent rewrap endpoint is now physically
bound for both closed schemas, but the Authority-to-selected-worker delivery workflow and its
fixtures remain open; Sprint `4.50` therefore stays Active.
**Implementation validated (2026-08-01 — retained delivery durable-state foundation)**: retained
SMTP/EAB delivery now has a schema-indexed, canonical Model-B aggregate codec and exact-revision
repository, plus persist-before-effect begin/receipt-commit coordination. Response-loss recovery
re-observes the selected Target before any retry; an in-flight intent is never replayed with a newly
generated ephemeral opening key. A missing receipt remains pending through its absolute deadline
and may be expired only strictly afterward, requiring a successor operation. Source identity
comparison deliberately excludes observation time while retaining generation, operation, receipt,
ciphertext digest, commitment, and Vault version. The focused aggregate/repository suite passes
10/10, the executable builds warning-clean across 466 modules, and `prodbox dev check` passes with
zero HLint hints. The authenticated Authority endpoint and supported caller are still open, so this
is an intermediate Sprint `4.50` checkpoint rather than closure.
**Implementation validated (2026-08-01 — retained delivery endpoint and caller cutover)**:
Lifecycle Authority now binds the authenticated retained-material route to distinct SMTP/EAB source
catalogs and dynamically resolved per-registered-target `CrossClusterDurable` outboxes. The effect
path is the physically separate Target Agent rewrap endpoint followed by the attested one-shot
materializer; recovery observes exact Target metadata before it can commit or retry. The Authority
workload has a dedicated projected controller token, bounded batch-auditor Vault binding, worker
RBAC, and NetworkPolicy edge. Both supported producers are callers: home EAB reconcile delivers
after the external-ingress receipt commit, and the SES SMTP AWS-admin worker cannot commit its
custody receipt until the Authority delivery succeeds or recovers. EAB receipts now retain distinct
Vault-HMAC commitment and ciphertext-digest fields. Evidence is retained aggregate 11/11,
external-material 13/13, Credential Provisioner 41/41, authentication 33/33, authenticated
transport 27/27, warning-clean 468-module build, and `prodbox dev check` with zero hints. TLS,
Provider, legacy deletion, and final aggregate validation remain open.
**Current validation checkpoint (2026-07-31)**: an integrated library checkpoint built all 438
then-present modules with `--ghc-options=-Werror` after the selected-Agent, Broker handoff, and
Credential execution-journal drafts converged. Subsequent batch-auditor, durable service-session,
strict ServiceAccount-identity, and worker-protocol increments then reached a later integrated
checkpoint: all 445 library modules and the 125-module unit executable built with
`--ghc-options=-Werror`. The complete unit executable ran 2,951 cases and reported 29 failures. The
exact failure inventory is retained as the active cutover checklist: schema-v7 validation ordering;
the retained-SES legacy-transport scan; Provider epoch/fence/revision/resource registration;
terminal worker-session cleanup; target-registration bounds; graph-derived order; generated Dhall,
command, help, and RKE2-plan artifacts; Pulumi destroy/credential invariants; explicit target-Agent
rollout digests in chart fixtures; authenticated AWS retry setup; and SES Route 53 repair. The
predecessor-grace fixture was independently confirmed stale and corrected to use the rotation
intent's supplied grace deadline; the remaining failures are not waived. Because the Target
attestation, Provider/caller, Broker relay, and Credential coordinator edits continue after this
exact checkpoint, the current moving shared tree is not yet claimed warning-clean. This is a
compile and regression-discovery gate only. The open session-cleanup, exact signed one-shot
attestation, durable-Provider, supported-caller, clean-install, full-unit/integration,
negative-scan, and deployment-qualification gates below remain unsatisfied.
**Audit correction (2026-07-31 — AWS-substrate client authentication)**: deleting the host-side
Lifecycle-provider credential resolver exposed a wider supported-caller dependency: the AWS
substrate's `kubectl`, Helm, drain, runtime-monitor, and kubeconfig helpers still projected the raw
Lifecycle-provider credential into host subprocess environments so `aws eks get-token` could run.
Leaving that resolver as an unconditional refusal is a negative guard, not a working cutover. The
closed replacement is an authenticated, registered Provider capability bound to the exact account,
region, EKS cluster identity, Authority epoch/fence, request digest, and non-extending absolute
deadline. It returns only the bounded short-lived EKS client-authentication projection plus exact
endpoint/CA read-back, never the AWS access key, and no returned bearer may enter retained Provider
state, logs, argv/environment, generated configuration, or qualification evidence. Every
`withEksKubeconfig`, substrate-`kubectl`/Helm, drain, and monitor caller must use that capability;
test-EBS reaping uses the already closed Provider intent, while explicit destructive/admin work
continues through the Admin Action or Decommission Runner. Focused response-loss, expiry,
wrong-cluster/region/epoch/fence, credential-non-disclosure, and materialization-cleanup fixtures,
plus a production-import lint for the removed host credential path, remain required. Sprint `4.50`
stays Active until those callers and proofs close.
**Implementation in progress (2026-07-31 — Gateway federation transport deletion)**: the fixed
`RouteFederationChildren` entry and variable child-bootstrap pattern, their public client URL/query
functions, daemon Vault-backed handlers, and both bounded target-operation constructors are
physically deleted. The daemon and CLI integration fixtures now require both former paths to return
`404`; engineering and historical Phase-2 doctrine identify the routes as removed provenance and
point the current path to Lifecycle Authority/Target Secret Agent delivery and read-back. A
warning-clean `lib:prodbox` build passes, the focused compiled-route unit proof passes, and a source
scan finds none of the deleted symbols. Broader Gateway authority/object-store/target/operator-write
routes remain, so this is an honest subincrement rather than sprint closure.
**Implementation in progress (2026-07-31 — Gateway continuity probe cutover)**: the native
reconcile gate no longer treats a generic Pulumi object-store RPC as a Gateway health check.
`ensureGatewayDaemonFullModeAt` and the compatibility-named backend observation now both classify
the daemon's deep `/readyz` projection as healthy, definitely not ready, or transport-transient;
only a definite not-ready result authorizes the one bounded restart, and verification polls the
same projection. The CLI integration fixture serves `/readyz` and no longer supplies a successful
Pulumi-object read for readiness. The touched modules format cleanly, `CLI.Rke2` compiles under
`-Werror`, and a deleted-symbol scan is empty. This retires the health-probe caller only; the actual
legacy RPC routes remain open until their final Authority/Target callers are cut over below.
**Implementation (Increment A, 2026-07-26)**: `Prodbox.Runtime.Role` now enumerates the physically
separate Lifecycle Authority, Provider Worker, Authority Backup Adapter, TLS Retention Adapter, and
Target Secret Agent alongside Bootstrap Broker and Gateway Runtime. Each maps bijectively to a
unique versioned mounted-config identity and canonical `/etc/<role>/config/config.dhall` path. This
removes the representational mismatch where charts selected dedicated roles that the executable's
closed runtime-role algebra could not name. Focused runtime-role validation passes 3/3. Command
dispatch and transport migration remain below, so the sprint stays Active.
**Implementation (Increment B, 2026-07-26)**:
`src/Prodbox/Lifecycle/Authority/Migration.hs` is the pure single-writer cutover kernel. Its closed
state machine moves `LegacyActive → ShadowVerified → WritersFrozen → ReplacementActive`; activation
requires the complete typed binding inventory, and there is no state with two active writers.
Exact replay is idempotent, digest divergence refuses, activation before freeze or before complete
preparation refuses with the missing binding set, and direct legacy rollback is always forbidden.
The focused `Lifecycle Authority single-writer migration` suite passes 5/5 under a warning-clean
unit build. Durable codecs/interpreters and executable role dispatch remain below, so the sprint
stays Active.
**Implementation (Increment C, 2026-07-26)**: the migration envelope now has a bounded canonical-CBOR
codec; corrupt and oversized states refuse before interpretation (focused migration suite 6/6).
The public command registry and native dispatcher now expose
`lifecycle-authority|provider-worker|authority-backup|tls-retention|target-secret-agent start
--config <mounted-role.dhall>` as five role-indexed processes. Each command decodes the explicit
mounted Dhall schema before Plan/Apply, has no repository or environment fallback, and starts the
shared fail-closed runtime boundary: liveness is served, while readiness and authority operations
remain unavailable until the role's production interpreter is installed. The chart renderer emits
the matching schema-v1 role config. Evidence: warning-clean executable/unit build, parser 279/279,
focused migration 6/6, and all five role dry-run projections. The production interpreters and
legacy transport deletion remain below, so the sprint stays Active.
**Implementation (Increment D, 2026-07-27)**: the durable migration bytes now carry an explicit
schema-v1 envelope rather than serializing a bare `MigrationState`. Decode refuses unsupported
versions, oversized/corrupt bytes, and any non-canonical representation before returning state.
Every durable command prefix round-trips through the envelope, so restart proof covers
`LegacyActive`, shadow verification, freeze, each binding preparation, and replacement activation.
The focused migration suite passes 8/8 under the warning-clean unit build. Production
Lifecycle-Authority interpreters and legacy transport deletion remain below, so the sprint stays
Active.
**Implementation (Increment E, 2026-07-27)**:
`Prodbox.Lifecycle.Authority.MigrationInterpreter` is the durable CAS boundary for the migration
kernel. It reads one opaque repository revision, rejects corrupt/version-invalid state before
decision, writes only an accepted state transition against that exact revision, performs no write
for idempotent replay or refusal, and reports a lost CAS as `MigrationConcurrentWrite` rather than
silently overwriting another writer. The in-memory repository fixtures cover complete activation,
restart decoding, no-write replay/refusal, corrupt durable state, and a forced concurrent-write
loss. The focused migration suite passes 11/11. Binding the repository to retained Authority
storage and removing the production legacy transports remain below, so the sprint stays Active.
**Implementation (Increment F, 2026-07-27)**: the migration repository is now bound to a
`ModelBCasAdapter 'ClusterRetained` and a `ModelBObjectCoordinate 'ClusterRetained`; the type system
therefore rejects chart-lifetime or cross-cluster coordinates at this Authority-primary boundary.
`migrationStateCodec` uses the same bounded versioned envelope, and the repository maps
missing/observed/corrupt/unobservable and initialize/replace/conflict/refused outcomes without
collapsing them. Focused fixtures prove the first durable command emits exactly one retained
Model-B initialization and that the bounded codec is the physical payload boundary. The focused
migration suite passes 13/13. Supplying the production retained adapter to the role server and
removing legacy transports remain below, so the sprint stays Active.
**Implementation (Increment G, 2026-07-27)**: mounted standing-role config now carries both
`schema_version` and the exact `runtime_role`. The binary compares that value to the role selected
by the command before Plan/Apply; a Lifecycle Authority config cannot start a Provider Worker,
Backup Adapter, TLS Retention Adapter, or Target Secret Agent, and unsupported schema versions
fail before the listener opens. `ChartPlatform` renders the exact chart/role binding into each
ConfigMap. Focused validation covers all five accepted bindings plus wrong-role and wrong-version
refusals; the migration/control-plane suite passes 14/14. Role-specific production interpreters
and legacy transport deletion remain below, so the sprint stays Active.
**Implementation (Increment H, 2026-07-27)**: migration events and the evolution function are no
longer public constructors, so callers cannot forge or apply an event outside `decideMigration` /
`stepMigration`. Migration digests now reject empty, control-bearing, and over-128-character
bindings before durable state construction. Focused validation covers both bounds and every
reachable writer transition; the suite passes 15/15. The sprint remains Active on its production
interpreter and cutover/removal surface.
**Implementation (Increment I, 2026-07-27)**:
`Prodbox.ControlPlane.Route` now defines the closed method/path topology for the five standing
roles. Every route has exactly one owner; decoding is role-indexed, cross-role decoding refuses,
and no generic object-store or Vault route exists. The executable runtime uses that registry when
classifying requests: liveness remains common, readiness stays fail-closed until the corresponding
interpreter is bound, an owned-but-unbound operation returns `503`, and a route owned by another
role returns `404` rather than reaching a shared dispatcher. The focused topology suite passes 4/4
and the warning-clean executable/unit build passes. Production in-cluster adapters and deletion of
the old gateway routes remain, so the sprint stays Active.
**Implementation (Increment J, 2026-07-27)**:
`Prodbox.ControlPlane.VaultSession` provides the standing roles' shared mechanism without a shared
identity: a smart constructor binds each executable role to exactly its compiled Vault
Kubernetes-auth role, and the cached renewable session re-reads the projected ServiceAccount JWT
on renewal. Gateway/Bootstrap identities, cross-role borrowing, and empty transport coordinates
refuse before login. The mounted role config is schema v2 and now requires the exact Vault address,
auth path, role, and token-file coordinate; chart rendering supplies those fields, and runtime
validation constructs the cached session before opening the listener. There is no environment,
host-root-token, or per-request-login fallback. `defaultVaultReconcilePlan` now creates five
distinct policies and Kubernetes-auth roles rather than rendering ServiceAccounts whose Vault
identities do not exist: core Authority has only retained-store HMAC/MinIO/Transit access;
Provider, Authority Backup, and TLS Retention each read only their exact AWS credential path; and
Target Agent has only the registered target-secret lanes. Focused Vault/migration validation
passes.
Binding the session to each role's least-privilege store/provider interpreter and deleting the old
gateway transports remain, so the sprint stays Active.
**Implementation (Increment K, 2026-07-27)**:
`Prodbox.ControlPlane.MigrationEndpoint` is the server side of the Lifecycle Authority
`migration/apply` route — the first standing-role route to gain a real handler rather than the
shared fail-closed `503`. `serveMigrationApply` decodes a bounded, versioned, canonical
`MigrationCommand` request body through a new kernel codec (`encodeMigrationCommand` /
`decodeMigrationCommand`) that is byte-symmetric with the retained-state envelope, so a corrupt,
oversized, non-canonical, or unsupported-version body is refused before it can reach
`decideMigration`; it then applies the command through the exact-revision retained
`MigrationRepository` and projects the outcome onto a total HTTP status (`migrationEndpointHttpStatus`)
and a stable kebab summary (`migrationEndpointSummary`): a malformed request is `400`, a well-formed
but state-machine-refused transition and a lost compare-and-swap race are `409`, an unobservable read
or a failed durable write is `503`, a corrupt retained decode is `500`, and accepted/already-applied
are `200`. The handler is pure over an injected repository, so an in-memory fixture exercises every
arm without a live cluster, Vault, or object store. The focused endpoint suite passes 9/9, the
migration kernel suite (now also proving the request codec) stays 15/15, and `prodbox dev check` plus
the Authority/control-plane/migration targeted suites (111/111) pass warning-clean. Constructing a
production in-cluster retained repository — over the role's Kubernetes-auth Vault session and the
in-cluster MinIO Service DNS rather than the host-root-token host-direct seam — and dispatching the
raw socket request on `LifecycleMigrationApply` to this handler in `runControlPlaneRole` remain
below, so the sprint stays Active.
**Implementation (Increment L, 2026-07-27)**:
`Prodbox.ControlPlane.Server` is the pure request/dispatch/response seam every standing-role server
shares. `parseControlPlaneRequest` extracts the method, request target, and body;
`classifyControlPlaneRequest` maps a request onto a typed `ControlPlaneDisposition`
(`Live` / `NotReady` / `OwnedRoute` / `NotOwned`) through the closed route topology; a role installs a
monad-generic `RoleInterpreter` (readiness probe plus per-route handler), and
`serveControlPlaneRequest` resolves a request to a `(status, body)` pair, with `renderHttpResponse`
rendering the bounded `Connection: close` reply. `runControlPlaneRole`'s raw-socket loop now owns only
accept/recv/send and dispatches through this seam with the shared `failClosedInterpreter` — liveness
serves while readiness and every owned route fail closed, byte-identical to the prior ad-hoc byte-prefix
classifier but now a single typed dispatch point rather than an unowned prefix match. A focused suite
proves request parsing, every disposition, cross-role route refusal, fail-closed serving, the rendered
response, and — through a Lifecycle Authority `RoleInterpreter` that binds `LifecycleMigrationApply` to
Increment K's `serveMigrationApply` over an in-memory repository — that an owned migration request is
reachable through the seam and returns `200 migration-accepted` / `409 migration-refused` end to end
(server seam 8/8, combined control-plane/migration regression 40/40, `prodbox dev check` warning-clean
and lint-clean). Constructing the production in-cluster retained repository behind that interpreter, and
reading a full request body larger than one bounded `recv`, remain below, so the sprint stays Active.
**Implementation (Increments M–N, 2026-07-27)**: the pure core of the resumable decommission receipt
landed. `Prodbox.Lifecycle.Decommission.Frame` is the physical frame unit — a content-addressed record
carrying its schema version, the binding manifest digest, a monotonically increasing index, a stable
node id, a stable attempt id, the SHA-256 digest of the previous frame (the hash chain), a SHA-256
checksum over its own payload, and the typed payload — with a bounded canonical per-frame codec that
refuses oversize, non-canonical, unsupported-version, and checksum-mismatched frames, a genesis link
bound to the manifest, and a pure `appendPayload` chain builder (frame suite 8/8).
`Prodbox.Lifecycle.Decommission.Journal` frames a length-delimited log and `recoverReceipt` computes
the longest complete, checksum-valid, manifest-bound, hash-chain-consistent prefix: a torn final record
(a crash part-way through the last append — a partial length prefix or body) is `RecoveryTruncatableTorn`
and recovers by truncating to the last valid frame, while a fully written but corrupt frame (interior or
final), a chain/index break, and a manifest mismatch each `RecoveryRefused` — committed history is never
silently dropped (recovery suite 7/7, matching Validation item 7's reopen matrix). Both modules are pure
and fully fixture-driven; `prodbox dev check` is warning-clean and lint-clean. The signed
inventory/manifest, the exported pinned verifier artifact, the SES/TLS-prefix-before-bucket destroy
subgraph, and the `DecommissionRunner` permit family remain below, so the sprint stays Active.
**Implementation (Increment O, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Receipt` is the fsync-ordered durable barrier — the protocol's only new
effectful primitive. `appendReceiptFrame` writes one length-delimited frame record, fsyncs the file,
then fsyncs the parent directory, so a committed frame is durable before the runner performs the
external effect it authorises. `reopenReceipt` reads the receipt, runs the pure longest-valid-prefix
recovery, and — only for a torn final record — truncates the file back to the last valid frame and
fsyncs, so resumption appends cleanly after the recovered prefix; a fully written corrupt frame, a chain
break, or a manifest mismatch is returned as a refusal with the file left untouched. A real-temp-file
suite proves durable append→reopen of the complete chain, torn-tail truncate-and-resume, corrupt-frame
refusal without truncation, and a missing receipt as an empty chain (barrier suite 4/4; full
decommission/control-plane/migration regression 59/59; `prodbox dev check` warning- and lint-clean). The
signed inventory/manifest, the exported pinned verifier artifact, the destroy subgraph, and the runner
permit family remain below, so the sprint stays Active.
**Implementation (Increment P, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Manifest` is the deterministic signed inventory the receipt binds to.
`DecommissionNode` is the closed typed vocabulary of teardown work (SES consumer-quiescence /
provider-stack / SMTP-IAM, per-target generation tombstone, retained custody, TLS objects,
TLS-retention identity, backup prefix-absence proof, backup objects, shared bucket).
`DecommissionManifest` is opaque — reachable only through `mkDecommissionManifest`, which rejects an
empty or duplicated inventory, an invalid cluster identity, and an invalid target reference — and
`decommissionManifestDigest` is the canonical SHA-256 (the shared `Frame.contentDigest` primitive) that
is exactly the `FrameDigest` every receipt frame carries. A fixture proves the binding is load-bearing:
a receipt built under one manifest's digest recovers, while reopening it under a different manifest's
digest is a chain refusal (`JournalChainDrift 0`), so a receipt can never be replayed against a
different plan (manifest suite 5/5; decommission regression 24/24; `prodbox dev check` warning- and
lint-clean). The typed-graph ordering over these nodes, the retained-Model-B receipt-commit under an
admission freeze, and the exported pinned verifier artifact remain below, so the sprint stays Active.
**Implementation (Increment Q, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Graph` is the typed destroy-ordering subgraph over the manifest's
`DecommissionNode` inventory. `decommissionRequiredPredecessors` derives the mandatory order — SES
consumer-quiescence before the provider-stack and SMTP-IAM destroys, which precede the
target-generation and retained-custody tombstones; TLS objects/identity and the whole backup chain
before the shared object bucket (the unique terminal); the backup prefix-absence proof after TLS
deletion and before backup-object deletion — and `runDecommissionGraph` is a total executor that runs
every node whose predecessors succeeded, records `NodeBlocked` with the offending predecessors
otherwise, aggregates every outcome, and never stops early. Fixtures prove convergence under
all-success, that a failed backup-absence proof blocks backup-objects and the shared bucket while the
SES branch still completes, and that an SES-provider failure blocks only the SES tombstones and the
bucket while the entire independent TLS→backup chain still succeeds; the pure ordering-invariant checks
(`tlsPrecedesSharedBucket`, `sesDestroyPrecedesTombstones`, `sharedBucketIsTerminal`) hold for the full
inventory (graph suite 4/4; decommission regression 28/28; `prodbox dev check` warning- and lint-clean).
Wiring the node effects to the real destroy/read-back operations, the retained-Model-B receipt-commit,
the exported pinned verifier artifact, and the `DecommissionRunner` permit family remain below, so the
sprint stays Active.
**Implementation (Increment R, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Commit` commits the signed manifest to retained authority state before
the point of no return. The manifest gains a bounded canonical codec
(`encodeDecommissionManifest`/`decodeDecommissionManifest`, refusing oversize/non-canonical/
unsupported-version input). `commitDecommissionManifest` is an initialize-if-absent compare-and-swap
over an injected `ModelBCasAdapter 'ClusterRetained` (`modelBDecommissionCommitRepository`): no plan
committed yet → `CommittedNew`; the same plan already committed → `CommittedAlready` (a resuming runner
proceeds against its recorded plan); a different plan committed → `RefusedDifferentPlan`, never
clobbering another run's plan — with read/write/concurrent-write failures surfaced distinctly and the
type index rejecting a chart-lifetime coordinate at this authority-primary boundary. In-memory-adapter
fixtures cover every arm plus the codec round-trip (commit suite 6/6; decommission regression 34/34;
`prodbox dev check` warning- and lint-clean). Freezing admission first is the runner's sequencing
obligation; the `DecommissionRunner` permit family, the exported pinned verifier artifact, and the real
destroy-effect wiring remain below, so the sprint stays Active.
**Implementation (Increment S, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Permit` is the Decommission Runner's one-time permit family — the gate
that authorizes a total-teardown run past the point of no return, disjoint from the Admin Action
Runner's family (whose `AdminAction` type cannot represent decommission). A permit binds the exact
committed plan by manifest digest, and `decideDecommissionPermit` refuses a cross-role audience or a
cross-plan digest structurally, then while awaiting accepts only when admission is `AdmissionFrozen`,
the exported verifier/runner artifact preflight is `VerifierArtifactReady`, and the permit is fresh;
consumption is one-time, so replaying the same nonce is idempotent and a divergent nonce conflicts. It
reuses the `RunnerRole`/`PermitFreshness` observations from `AdminAction` and is pure — admission,
verifier readiness, and freshness are injected observations. Fixtures cover every arm (permit suite
7/7; decommission/control-plane/migration regression 81/81; `prodbox dev check` warning- and
lint-clean). Constructing the exported pinned verifier artifact and its preflight, wiring the runner to
the real destroy effects, and composing permit→commit→receipt→graph into the run orchestration remain
below, so the sprint stays Active.
**Implementation (Increment T, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Runner` is the run orchestration that composes the whole subsystem.
`runDecommission` walks the destroy subgraph in topological order and, for each attempted node, journals
a `DecommissionIntent` frame before the injected destroy/read-back effect and a `DecommissionNodeResult`
frame after; a node whose predecessors did not all succeed is `NodeBlocked` and neither run nor
journaled. Resumption is derived from the recovered receipt: `completedNodes` returns the nodes a prior
run durably destroyed, and `runDecommission` skips them without re-running or re-journaling — so a
one-time external destroy is never attempted twice, while a node that recorded only an intent or a
failure is re-attempted. It is monad-generic over the injected journal and destroy effects. Fixtures
prove per-node intent/result journaling in order, skip-without-re-run, failed-result journaling with
blocked dependents, and `completedNodes` extraction; a real-temp-file integration test runs the plan to
a failure over the durable receipt, reopens and recovers it, and resumes — re-running only the failed
node and its dependents while the recovered prefix is skipped (orchestration suite 5/5;
decommission/control-plane/migration regression 86/86; `prodbox dev check` warning- and lint-clean).
With this the decommission subsystem is code-complete up to the live boundary: the exported pinned
verifier artifact + preflight and the wiring of the node effects to the real destroy operations remain,
so the sprint stays Active.
**Implementation (Increment U, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.Verifier` is the exported pinned verifier/runner artifact and its
preflight — the gate the Decommission Runner permit consumes. `exportVerifierArtifact` writes the opaque
pinned build bytes and their metadata (dependency-closure digest, manifest-schema version+digest,
interpreter-registry version+digest) to an operator/harness-owned coordinate, fsyncs each file and the
parent directory, reads back every byte to prove the export landed intact, and returns the
`VerifierBinding` (artifact digest + metadata) to bind into the signed manifest and receipt header.
`runVerifierPreflight` reopens the on-disk artifact and metadata and verifies them against that committed
binding: a missing artifact, a byte-tampered artifact (digest mismatch), corrupt metadata, or a drifted
dependency closure / manifest schema / interpreter registry each refuses with a typed reason, and only an
exact match yields `VerifierReady` (projected to the permit's `VerifierArtifactReady` via
`verifierPreflightReady`) — so a missing, changed, or drifted runner cannot be silently upgraded
mid-teardown. A real-temp-file suite proves durable export→read-back→preflight plus the
absent/tamper/drift/corrupt refusals (verifier suite 5/5; decommission regression 51/51;
`prodbox dev check` warning- and lint-clean). With the artifact preflight landed, the decommission
subsystem's only remaining piece is wiring the destroy subgraph's node effects to the real
destroy/read-back operations (a Standard-O live-coupled adapter), so the sprint stays Active.
**Implementation (Increment V, 2026-07-27)**:
`Prodbox.Lifecycle.Decommission.NodeEffect` is the destroy-and-read-back seam binding a
`DecommissionNode` to a real destructive operation. `classifyReadBack` enforces the observation
soundness rule of `ResidueStatus` — only a positively observed `ResidueAbsent` confirms a destroy,
while `ResiduePresent` and `ResidueUnreachable` both fail, so a torn or degraded read never authorizes
the run to advance to the shared bucket. `runNodeOperation` attempts the destroy and re-observes only
on success; `DecommissionNodeInterpreter` is the total per-node dispatch, and `runDecommissionNode` is
the effect the destroy subgraph executor consumes (`runDecommissionGraph nodes (runDecommissionNode
interpreter)`). The classification and dispatch are pure over injected `NodeOperation`s — fixtures prove
absence-confirms / presence-refuses / unobservable-refuses, that a failed destroy is not re-observed,
and that a still-present read-back fails the node and blocks its dependents end to end (node-effect
suite 4/4; decommission regression 55/55; `prodbox dev check` warning- and lint-clean). Supplying the
production `NodeOperation`s — the real `destroyAwsSesStack`, live-Target-Agent tombstones,
`destroyRetainedPublicEdgeTls`, and `destroyLongLivedPulumiStateBucket` calls with their
re-observations — is the live-coupled boundary this seam isolates (Standard-O), and it depends on the
Target Agent / Authority Backup runtimes that the remaining role interpreters supply.
**Implementation (Increment W, 2026-07-27)**:
`Prodbox.ControlPlane.TlsRetentionEndpoint` is the server side of the TLS Retention role's `store` and
`restore` routes — the second standing role (after the Lifecycle Authority migration route) to gain a
real handler. It fronts the existing pure retention algebra: `serveTlsStore` reads the current
retention state through an injected `TlsRetentionRepository`, drives `decideTlsPromotion`, and commits
only a genuine promotion through the repository's compare-and-swap; `serveTlsRestore` drives
`decideTlsRestore` against the committed reference with no mutation. `tlsRetentionHttpStatus` /
`tlsRetentionSummary` project the outcome onto a total HTTP status and stable summary
(promoted/no-op/applied/issue → 200; a refused decision or reference mismatch → 409; a corrupt
committed reference → 500; an unobservable read or failed write → 503). It is pure over the injected
repository — fixtures prove first-store promotion + commit, a no-source-reobservation refusal without
commit, an idempotent re-store no-op, a failed durable commit as a retryable write failure, and the
apply/issue/mismatch/corrupt restore arms (endpoint suite 5/5; `prodbox dev check` warning- and
lint-clean). The bounded canonical wire codec for the request/response bodies and the real
retained-store compare-and-swap are the live-coupled follow-ons this handler isolates (Standard-O).
**Implementation (Increment X, 2026-07-27)**:
two more standing-role server endpoints landed, bringing four of the five roles' routes to real
handlers. `Prodbox.ControlPlane.AuthorityBackupEndpoint` fronts the pure backup-repair algebra:
`serveBackupCopy` reads the admission state through an injected repository, drives `decideBackupRepair`,
folds the decision's events into the next state, and commits only a genuine advance; `serveBackupObserve`
returns the state; the status/summary projection maps every arm (freeze/permit/progress/reopen/wait/
not-needed → 200, refused → 409, write failure → 503). `Prodbox.ControlPlane.TargetSecretEndpoint` owns
the total projection of the richest role's `decidePrepareTargetCommit`/`decideCompleteTargetCommit`
decisions onto an HTTP status and stable summary, with a shared exhaustive refusal classifier
(unobservable → 503, corrupt / missing-after-prepare → 500, every other refusal → 409) over the
21-constructor refusal taxonomy; its full nine-input decision plus guarded retained CAS handler is the
live-coupled Standard-O follow-on. Fixtures: AuthorityBackup 5/5, TargetSecret 5/5; combined
control-plane endpoint regression 32/32; `prodbox dev check` warning- and lint-clean. The Provider
Worker role has no pure interpreter yet (only chart statics), so its `provider-work` routes remain
fail-closed through the L seam until the provider algebra is built; the four fronted roles' bounded
request/response wire codecs and real store/sink CAS backends are the Standard-O follow-ons.
**Implementation (Increment Y, 2026-07-28)**:
the bounded, versioned, canonical request wire codec that Increment K fixed for the migration route is
now shared and extended to the two fronted roles whose endpoints already had typed handlers. A new
`Prodbox.ControlPlane.Codec` lifts the migration route's `Serialise`-envelope framing —
maximum-size bound, supported-version check, and canonical round-trip check — into one generic
`encodeControlPlaneRequest` / `decodeControlPlaneRequest` (`ControlPlaneRequestCodecError`: too-large /
invalid / unsupported-version / non-canonical), so a role cannot reinvent or loosen the discipline
(migration keeps its own byte-frozen copy). `Prodbox.ControlPlane.AuthorityBackupEndpoint` gains
`serveBackupCopyRequest` (decode a bounded `BackupRepairCommand`, else `AuthorityBackupBadRequest` → 400
before any state is read) and `Prodbox.ControlPlane.TlsRetentionEndpoint` gains `serveTlsStoreRequest` /
`serveTlsRestoreRequest` (decode a `TlsStorePayload` / bare `RestoreObservation`, else
`TlsRequestBadRequest` → 400) — the through-seam entries a production `RoleInterpreter` dispatches the
raw socket body to. Their request payload types (`BackupRepairCommand` plus its `Genesis` field types;
`KeyRotationApproval` / `PromotionEvidence` / `RetainedTlsRef` / `RestoreObservation`) gained `Serialise`
derivations; all carry only digests, coordinates, and health/version enums — no key or ciphertext
material crosses the boundary. That brings three of the five roles (migration + Authority Backup + TLS
Retention) to through-seam request-codec parity. Fixtures: Authority Backup 9/9, TLS Retention 10/10,
combined control-plane endpoint regression 24/24, and the Sprint-4.48 authority-algebra suites whose
types gained `Serialise` remain 79/79; `prodbox dev check` warning- and lint-clean. The Target Secret
Agent role's request codec was the confirmed multi-actor, security-critical design boundary: unlike
migration / Authority Backup / TLS Retention, whose existing serve functions already fixed the
caller-input shape, its endpoint had only the projection (no serve function). A 2026-07-28 algebra
investigation showed the `FencedCommitPermit` is an authority-minted lease-authorization artifact
(`Lease.decideFencedCommit`) — used to stamp the intent's owner nonce and fencing token and to build
the guarded-CAS lease guard (`modelBLeaseGuardFromPermit`) — so a request must never reconstruct it,
and the parametric agent `TargetSinkReadback` plus the guarded `ModelBCasRequest` output make the
target-commit a lease → permit → prepare → agent-write → readback → guarded-CAS protocol. After the
operator reviewed and approved that request protocol (Increment Z), the **prepare** half landed; the
**complete** half stays the Standard-O agent binding because `TargetSinkReadback` / `TargetCommitIntent`
are deliberately un-exported (un-forgeable by design), so a complete request cannot reconstruct a
readback — it must transport the agent's trusted `confirmTargetSinkReadback` output. The Provider Worker
role still has no pure interpreter, so its codec awaits that greenfield algebra.
**Implementation (Increment Z, 2026-07-28)**:
after an operator-reviewed request-protocol design note, the Target Secret Agent role's **prepare**
handler landed on the approved shape: the fenced permit is authority-supplied (never on the wire), the
retained projection/registered-set/coordinate come from an injected repository, and the request carries
only raw commit primitives. `Prodbox.ControlPlane.TargetSecretEndpoint` gains `PrepareTargetCommitPayload`
(sink coordinates / generation / digest / deadline-micros — primitives only, so no `Serialise` cascade
across authority types), a `TargetSecretPrepareRepository` (registered set, intent coordinate, fenced
permit, retained projection observation, authority clock), and `servePrepareTargetCommitRequest`, which
decodes through the shared `ControlPlane.Codec`, re-validates each primitive through the same smart
constructors the algebra requires (`mkTargetClusterSecretSink` / `mkCredentialGeneration` /
`mkTargetValueDigest`; a bad field is `TargetPrepareFieldRejected` → 400, a malformed body
`TargetPrepareCodecRejected` → 400), reads the authority-side inputs, and drives the **proven**
`decidePrepareTargetCommit`, projecting through `targetPrepareEndpointStatus` / `…Summary`. The guarded
retained-projection CAS *execution* and the production repository (deriving the permit from live lease
state) stay Standard-O. Fixtures: Target Secret 11/11 (5 projection + 6 prepare, incl. codec/field
rejection, a lease-minted-permit happy-path guarded CAS, and an unregistered-target refusal); combined
control-plane endpoint regression 30/30; `prodbox dev check` warning- and lint-clean. The **complete**
handler remains deferred on the deliberate opacity of `TargetSinkReadback` / `TargetCommitIntent`
(agent-transport Standard-O), and Provider Worker still awaits its greenfield algebra — so four of the
five roles (migration + Authority Backup + TLS Retention + Target Secret prepare) now reach through-seam
request-codec parity.
**Implementation (Increment AA, 2026-07-28)**:
`Prodbox.ControlPlane.OperationEndpoint` fronts the Lifecycle Authority's **core operation-journal**
routes `LifecycleOperationSubmit` (POST `/v1/operations/submit`) and `LifecycleOperationObserve` (GET
`/v1/operations/observe`) — the two routes Increment I's closed topology declares for the Lifecycle
Authority beyond `migration/apply` but that had no fronting handler and so failed closed through the
Increment-L seam. It fronts the already-proven idempotent submission algebra
(`Prodbox.Lifecycle.Authority.Submission`, Sprint 4.48) exactly as `AuthorityBackupEndpoint` fronts
backup-repair: `serveOperationSubmit` reads the admitting `AuthorityEpoch` plus the current
`SubmissionLedger` through an injected `OperationSubmissionRepository`, drives `stepSubmit`, and
compare-and-swaps the evolved ledger **only on a genuine advance** — an idempotent duplicate and every
refusal never mutate (matching `applySubmit`'s no-op arms), so no CAS is attempted for them.
`serveOperationSubmitRequest` decodes a bounded, versioned, canonical `OperationSubmitPayload` (client
/ sequence / digest transport primitives only, so no `Serialise` cascade across authority types) through
the shared `ControlPlane.Codec` and rebuilds the algebra's `ClientId` / `ClientSequence` /
`RequestDigest`; `serveOperationObserve` / `serveOperationObserveRequest` are read-only over
`submissionStatus`. Total projections cover every arm: `operationSubmitHttpStatus` /
`operationSubmitSummary` map `SubmitDecision` (accepted / idempotent-duplicate 200, reused-sequence /
expired 409, at-capacity full 503 retryable, durable-write-failed 503, malformed-request 400) and
`operationObserveHttpStatus` / `operationObserveSummary` map `SubmissionStatus` (in-flight / settled-
completed / settled-cancelled / expired 200, never-seen 404). The handler is pure over the injected
repository, so an in-memory fixture exercises every submit decision and observe status without a live
cluster, Vault, or object store; a fail-writes repository proves a duplicate or refusal never reaches
the commit path. Evidence: operation-endpoint suite 17/17, combined control-plane endpoint regression
88/88, `prodbox dev check` warning- and lint-clean. The Lifecycle Authority role now serves **both**
its `migration/apply` (K) and its core `operations/submit` + `operations/observe` routes as testable
server endpoints over their existing pure algebras; the production retained compare-and-swap repository
(over the role's Kubernetes-auth Vault session and in-cluster MinIO Service DNS) and the raw-socket
dispatch of these routes in `runControlPlaneRole` remain the Standard-O live-coupled follow-ons — the
same tail every already-landed endpoint isolates — and Provider Worker still awaits its greenfield
algebra.
**Implementation (Increment BB, 2026-07-29)**:
`Prodbox.ControlPlane.RoleInterpreters` is the missing composition layer between the landed per-route
endpoint handlers and the Increment-L dispatch seam. Increment L made `serveControlPlaneRequest` route
an owned request to an installed `RoleInterpreter`, but production `runControlPlaneRole` still installs
the shared `failClosedInterpreter` (every owned route `503`), and the only interpreter binding a real
handler was a test-local, migration-only stub that `503`d the now-landed `operations/submit` /
`operations/observe` routes. This increment adds pure library builders that compose a role's landed
handlers into its `RoleInterpreter` over injected repositories plus an injected readiness probe:
`lifecycleAuthorityInterpreter` binds all three Lifecycle Authority routes (`migration/apply` → K's
`serveMigrationApply`, `operations/submit` → AA's `serveOperationSubmitRequest`, `operations/observe` →
AA's `serveOperationObserveRequest`, with the observe codec-error mapped to `400`), and
`tlsRetentionInterpreter` binds both TLS Retention routes (`store`/`restore` → W's request handlers).
These are the only two roles whose every owned route already has both a landed request handler and a
landed `(status, summary)` projection; Authority Backup's `observe` projection, the Target Secret Agent
`complete` arm, and the greenfield Provider Worker algebra are not yet landed, so those roles keep the
fail-closed interpreter rather than a partially-bound one (a broader all-roles builder would reintroduce
per-route `503` stubs). The builders are pure/monad-generic over the injected repositories, so an
in-memory fixture drives every route/arm end-to-end through `serveControlPlaneRequest` — including the
GET-with-body observe path that had zero dispatch coverage — proving each route reaches its handler and
the projection flows back. The obsolete migration-only stub in the server-seam suite is replaced by the
library builder. Evidence: role-interpreters suite 11/11, server-seam suite 8/8 (now library-built),
combined control-plane regression 28/28 and endpoint regression 88/88, `prodbox dev check` warning- and
lint-clean. Supplying the concrete production repositories (over each role's Kubernetes-auth Vault
session and in-cluster MinIO Service DNS) and installing the built interpreter in `runControlPlaneRole`
over a real socket remain the Standard-O live-coupled follow-ons — the same tail every endpoint isolates.
**Implementation (Increment CC, 2026-07-29)**:
`authorityBackupInterpreter` brings the Authority Backup role to full interpreter parity with the
Lifecycle Authority and TLS Retention roles, so three of the five control-plane roles now dispatch
every owned route through `serveControlPlaneRequest`. The `copy` arm was already landed (Increment Y's
`serveBackupCopyRequest` over the shared bounded/versioned/canonical `Prodbox.ControlPlane.Codec`); the
one missing piece was the `observe` arm's `(status, summary)` projection. This increment adds
`authorityBackupObserveStatus` (a read never fails at this layer, always `200`) and
`authorityBackupObserveSummary` (exhaustive over `AuthorityAdmissionState`: `genesis-frozen`,
`establishing`, `established`, `repair-frozen`), then binds `AuthorityBackupCopy` →
`serveBackupCopyRequest` and `AuthorityBackupObserve` → `serveBackupObserve` in the new
`authorityBackupInterpreter`. The builder is pure/monad-generic over the injected
`AuthorityBackupRepository`, so an in-memory fixture drives both routes end-to-end through the seam: a
`copy` that freezes admission, an `observe` reflecting that committed freeze, a malformed body mapped to
`400`, a foreign route `404 route-not-owned`, and the injected readiness probe. Only the Target Secret
Agent `complete` arm (deliberately opaque — a `complete` request cannot reconstruct a readback, a
Standard-O agent binding) and the greenfield Provider Worker algebra now keep their two roles
fail-closed rather than partially bound. Evidence: role-interpreters suite 17/17 (6 new Authority
Backup cases), Authority Backup endpoint regression 15/15, `prodbox dev check` warning- and lint-clean.
Supplying the concrete retained-store CAS repository and installing the built interpreter in
`runControlPlaneRole` over a real socket remain the Standard-O live-coupled follow-ons.
**Implementation (Increment DD, 2026-07-29)**:
`providerWorkerInterpreter` brings the fenced Provider Worker to full interpreter parity, so four of
the five control-plane roles now dispatch every owned route through `serveControlPlaneRequest`; only
the Target Secret Agent `complete` arm (deliberately opaque — Standard-O agent binding) keeps its
role fail-closed. The Provider Worker previously had only chart statics and no decision algebra; this
increment lands the greenfield algebra `Prodbox.Lifecycle.ProviderWorker.ProviderWork`, its endpoint
`Prodbox.ControlPlane.ProviderWorkEndpoint`, and the interpreter binding. The fence is both structural
and dynamic. __Structural__: `ProviderIntent` is a closed sum whose thirteen constructors are exactly
the normal provider intents the architecture authorizes — registered-stack
reconcile/destroy/observe/read-back, bounded scratch checkpoint, the four fenced `aws-ses`
non-credential arms (sending identity, DKIM, receipt rules, capture bucket), test-scoped EBS reap,
spot-price observation, operational-identity observation, and the closed readiness probes — so a
credential IAM identity/key, an admin/credential permit, an
Authority state write, a backup/TLS identity, a target secret, a Gateway/DNS election, or any SMTP IAM
principal/policy/key is unrepresentable, not merely rejected (the operator-selected richer intent
vocabulary). __Dynamic__: `decideProviderWork` refuses an unregistered resource, a stale provider
revision, or an expired session; admits at most one intent at a time (a different concurrent intent is
refused as `outstanding-intent`); treats an identical resubmission as an idempotent already-in-flight
(never a second admission, so a lost response is safe); and drives the single-narrow-session
idle→in-flight→clean-close path plus the canceled/expired/ambiguous→recovery→grace→successor lifecycle.
The `apply` route decodes a bounded/versioned/canonical `ProviderWorkApplyPayload` through the shared
`Prodbox.ControlPlane.Codec` and re-validates its references through the same smart constructors the
algebra requires; `observe` returns the current session phase. All three pieces are
pure/monad-generic over the injected repository, proven by an in-memory fixture with no live cluster,
Vault, or provider session: algebra 15/15, endpoint 10/10, interpreter 6/6 (full role-interpreters
suite 23/23, Sprint 4.50 aggregate 176/176), `prodbox dev check` warning- and lint-clean. Binding an
admitted decision to the real narrow-session provider execution (Pulumi/AWS effect + authoritative
read-back) and the concrete retained-store compare-and-swap are the Standard-O live-coupled
follow-ons.
**Implementation (Increment EE, 2026-07-31 — Bootstrap Broker custody and host CLI cutover)**:
the supported `prodbox vault` surface now drives status, initialize, unseal, baseline reconcile,
seal, unlock-bundle rotation, Transit-key rotation, and PKI status/issuance exclusively through a
TokenRequest-authenticated loopback port-forward to the dedicated Bootstrap Broker. Secret-bearing
operations concurrently attach a bounded payload only to an exact attested one-shot worker bound to
the route, request/action digests, storage generation, Pod UID, immutable image, ServiceAccount,
deadline, and distinct retry UID; the long-lived controller receives only secret-free metadata and
typed receipts. `Bootstrap.Broker.LegacyAdapter` is deleted, `UnlockBundle` cannot contain an
initial root token, and the plaintext `Vault.Client` init/generated-root DTO and executor family is
physically deleted; supported initialization decodes only the PGP-ciphertext response. Focused
Broker engine/recovery, client/runtime authentication and idempotency, Kubernetes attestation and
cleanup, one-shot ingress, and chart-static validation passes 104/104 under `-Werror`, and the
library builds 352/352 warning-clean. A categorized source audit finds no Gateway, direct-Vault, or
root-token dependency in the supported `CLI.Vault` path. Native and AWS
`ComponentVaultUnsealed` readiness now use a fresh authenticated Broker status call: initialized and
unsealed is ready, sealed or uninitialized is pending, and ambiguous/authentication/transport failure
is unreachable (focused classifier/transport proof 3/3). The later Authority-backup/config/
credential choreography still keeps clean-install validation and the sprint open.
**Audit correction (2026-07-31 — Broker production-readiness closure)**: Increment EE proved the
host/worker transport and removed the named legacy adapters, but its wording overstated the
production interpreter. The real controller composition now uses the production MinIO,
Kubernetes, PGP, and one-shot-worker boundaries; stale fixed-slot replay is CAS-replaced and every
durable worker result recomputes its canonical request/result digests. The 104/104 focused suite,
forced warning-clean Broker compilation, and deleted-symbol scan pass. Readiness nevertheless stays
closed because the root-session/baseline, ambiguous-reset, child-custody/recovery evidence
registries and several seal/generated-root/baseline/PKI/post-unseal/child physical arms are still
unbound; generated-root PGP, observed Vault session revocation, a pre-effect Transit-rotation
journal, and a fresh in-Pod fence/lease check before every Vault effect are also incomplete. Those
are code-owned Sprint-4.50 blockers now being implemented, not Standard-O live evidence; no Broker
production-readiness claim is valid until the complete typed capability registry and negative tests
close them.
**Implementation (Increment FF, 2026-07-31 — production decommission composition)**:
`prodbox nuke` now composes the authenticated external-receipt runner rather than the historical
process-local teardown. Lifecycle Authority freezes admission in its retained aggregate, discovers
and commits the exact complete Target inventory once, signs the manifest through its non-exportable
Transit signer, reuses that committed plan on every pinned-runner resume, and permanently stops only
against the exact manifest/receipt binding. The Target Agent exposes only authenticated
decommission inventory, generation-tombstone, and retained-custody-tombstone arms in production;
ordinary generic Target observe/commit remains unbound. SES teardown proves consumer quiescence,
targets the registered provider URNs without consuming the distinct SMTP-IAM family, then runs the
separate IAM, target, custody, TLS-prefix, backup-prefix, and final shared-bucket nodes through the
compiled registry. The exported executable/dependency/metadata preflight, external acknowledgement,
receipt-header binding, semantic node/attempt validation, fsync-ordered frames, observe-before-retry
recovery, and real pinned-process replacement are production-wired. Evidence: decommission 130/130,
control-plane routes 66/66, request authentication 33/33, authenticated transport 27/27, both
modified NetworkPolicies rendered successfully, warning-clean library/unit builds, negative scans,
and `git diff --check`. This closed the then-enumerated external-receipt resource-node subgraph;
steady-state Target delivery, Provider execution, config, credentials, and legacy-route deletion
remained open. **Standard-C correction (2026-08-15):** that enumeration omitted home-substrate
uninstall/read-back, explicit `.data` disposition, final no-retention audit, and terminal-receipt
read-back. The current terminal tag sweep still runs outside the receipt graph. Sprint `4.85` owns
that newly measured closed-program-universe residual; this paragraph is not evidence that those
effects landed in Increment FF.
**Implementation in progress (Increment GG, 2026-07-31 — schema-indexed Credential Provisioner)**:
`Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial`, `.Kubernetes`, `.TargetMaterial`, and
`.Execution` now define the closed AWS-admin versus external-EAB ingress schemas, distinct
Lifecycle-provider/Authority-backup/TLS-retention/Gateway-DNS/home-DNS01 descriptors, signed
normal permits, a finite receipt-ordered first-reconcile plan, exact one-shot Job attestation, and
the direct Target-Agent handoff/read-back interpreter. The AWS interpreter persists create intent
before its first finite key-inventory observation, enforces the IAM two-key bound, and resolves an
applied-but-response-lost create only by deleting the observed inventory, proving stable absence
across the provider visibility grace, and reminting at most once. Session revocation, Job deletion,
and positive Pod absence are terminal on every path. The exceptional opaque
`GenesisBackupPermit` binds the exact `GenesisPlan`, compiled Authority-backup descriptor,
deadline, and member zero of the same first-reconcile plan; its executor alone can install the
initial backup identity and returns typed Target-Agent generation and Backup-Adapter establishment
inputs. The inert-by-default `charts/credential-provisioner` chart uses separate AWS/EAB service
accounts, immutable image digests, permit-specific Jobs, stdin-only secret ingress, and a
default-deny NetworkPolicy. The removed shared credential coordinate and generic operator-write
policy/role are absent from production sources, charts, and test fixtures; root config now names
only the Lifecycle-provider target while Gateway names only Gateway-DNS. The modules and chart
compile/lint warning-clean; focused execution and genesis tests are present. Clean-install
coordinator integration, distinct live IAM provisioning for every 4.50 member, and current-revision
Standard-P qualification remain open, so this increment does not claim operational cutover or the
later Sprint `7.33` AWS-run DNS01 / Sprint `8.11` live SMTP migration.
**Deployment qualification**: pending
**Implementation**: planned versioned migration/cutover modules, revisions to
`CheckpointAuthority.hs`, `AuthorityConfig.hs`, `EncryptedBackend.hs`, `LiveResidue.hs`,
`AwsSesStack.hs`, gateway client/daemon routes, source lints, and migration fixtures
**Independent Validation**: a deterministic migration simulator and v1/v2/v3 fixture matrix prove
shadow-read comparison, quiescence, single-writer cutover, restart, rollback refusal, and legacy
route absence without live AWS or a later phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `documents/engineering/code_quality.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, and `DEVELOPMENT_PLAN/substrates.md`

### Objective

Move every supported Model-B lifecycle caller to the dedicated authority/agent topology under one
versioned authority epoch, then delete the gateway-backed and host-direct paths instead of keeping
an indefinite dual-write or fallback regime.

### Deliverables

- Add a migration plan with observe→shadow-read/compare→freeze→prepare all bindings→atomic
  authority activation→re-observe. Upgrade prodbox-owned old writers so each mutation checks the
  durable freeze/epoch record; model external controllers that cannot do so as explicit suspend,
  credential-revoke, lifetime-drain, and read-back nodes. Prepare Target Agents, config, split
  credentials, DNS owners, and backend issuer bindings while both writer sets are frozen. Open new
  admission only after one CAS activates the fully read-back topology; dual-write and a partially
  wired active epoch are forbidden.
- Import existing lease/checkpoint/target-intent/SMTP projections through bounded versioned codecs;
  preserve fences and refuse corrupt, ambiguous, or concurrent-writer state.
- Route Pulumi checkpoint hydrate/store/delete, residue, stack-output, lease, authority time, and
  target delivery through indexed Lifecycle Authority/Target Agent clients.
- Add closed resource/program types for exact Route 53 account/zone/name/type/owner-epoch
  coordinates and cut home public-record writes to Gateway-DNS with ensure/delete/read-back and no
  alternate writer. Sprint `7.33` alone cuts the AWS A-record call sites to the authority provider
  projection; Sprint `4.50` does not claim that AWS production cutover.
- Add the closed cert-manager DNS01 Challenge/TXT descriptor and program variants. Sprint `5.29`
  landed run-time pre-issuance registration, always-run Challenge deletion, and exact TXT absence
  observation. Sprint `4.85` owns migration of that landed operation into the generic lifecycle
  kernel; Sprint `5.18` is only the historical origin of the corrected deliverable.
- Cut config readers/writers to authority-owned config generations. Reconcile and register the
  Operational Lifecycle-provider plus LongLived Authority-backup, TLS-retention, Gateway-DNS,
  home cert-manager-DNS01, and SES-SMTP IAM/key/Vault resources, Target-Agent generations,
  non-recoverable-material custody receipts, and dependency-ordered cleanup nodes; delete the
  generic Tier-0 `aws.*` projection and legacy host readers only after every remaining operation is
  re-observed through its role-specific capability. Retain `secret/aws/lifecycle-provider` for the
  fenced Provider Worker; the old `secret/gateway/gateway/aws` coordinate is already gone. Sprint `7.33`
  owns only the AWS-target projection and its substrate-local DNS01 identity. This sprint establishes
  the SES-SMTP descriptor/protocol and excludes it from generic provider authority; Sprint `8.11`
  alone freezes and migrates the live legacy Pulumi-owned principal/policy/key family, with no
  dual-write state.
- Cut public-edge TLS retain/restore from direct long-lived-bucket/admin helpers to the durable
  Authority → selected Target Agent ↔ retained-home TLS-DEK lane → TLS Retention Adapter workflow.
  Register the LongLived TLS-store identity/prefix; no Lifecycle-provider, backup, Gateway-DNS, or
  ephemeral substrate Vault key may substitute.
- Make target `config setup` Tier-0 authoring/validation only. First `cluster reconcile` deploys
  MinIO/Vault/Broker, unseals/baselines, starts the home Target Agent plus frozen Authority/Backup
  Adapter, performs the visible `EstablishAuthorityBackup` action under one ephemeral admin prompt,
  then submits the Tier-0 config proposal and remaining identity setup after admission opens. No
  clean install calls a normal Authority operation before its backup exists.
- On later reconcile, distinguish backup temporary unavailability from positive loss/policy drift.
  The former remains frozen; the latter visibly invokes the signed `BackupRepairFrozen` prompt/
  repair path and cannot fall back to normal provider mutation or silently disable backup.
- For each role key, commit create intent before AWS, seal before generation commit, and recover a
  lost one-time create response by finite-inventory delete/stable-absence/remint. Blind create retry
  and an uncommitted surviving key are forbidden.
- Migrate child custody to encrypted recovery-share receipts plus burn-recipient initial-token
  evidence. Reject legacy custody records containing a reusable initial root token and delete all
  later child-root-token reads.
- During shadow mode, while the old writer is still the sole writer and before the freeze, capture
  a frozen, digest-bound `LCPC-2026-07-11` superseded-composition trace and pure simulator under the
  normalized resource/load profile. Its identity separately binds old Git HEAD, dirty flag,
  the recorded identifier/version/digest of Standard P's source-manifest exclusion policy, the
  resulting allowlisted code/docs/non-secret-schema/template manifest digest, secret-safe
  generated-config identity, component-image digests, topology/wiring digest, resource-envelope
  digest, and authored-load/fault-schedule digest. The manifest excludes `test-secrets.dhall`,
  local/generated secret material, secret roots, and runtime/build roots. Secret-dependent fixture
  bindings use only opaque Authority receipt/generation IDs or Vault-keyed HMAC commitments, never
  public raw hashes of plaintext secrets. The fixture is test-only, cannot satisfy a production
  interpreter registry, and remains auditable after route deletion for Sprint `5.19`.
- Delete `gatewayModelBCasAdapter`, gateway authority/object-store/target-secret routes, authority
  coordinates carrying gateway endpoints, direct Route 53/bootstrap calls, generic operator-write
  routes, direct config transports, and `Pulumi.HostDirectObjectStore` fallback callers.
- Replace the always-success legacy Harbor uninstall helper with a registered desired-absence
  program and authoritative Helm-release absence read-back before the conflicting registry apply;
  failure remains aggregated instead of being discarded.
- Replace process-local total teardown with an explicit decommission protocol. While backup
  receipts still exist, freeze admission and receipt-commit a signed deterministic inventory/plan.
  Before Authority permanent stop, export the exact manifest-verifier/Decommission-Runner build
  artifact and its dependency/build metadata to an operator/harness-owned durable coordinate outside
  every cluster, Vault, object-store, AWS account resource, path, or bucket named by the deletion
  graph. Bind the artifact digest plus manifest-schema/interpreter-registry version and digest into
  the signed manifest and receipt header; fsync the artifact and metadata files plus parent
  directory, reopen/read back every byte, verify digests, and run the pinned verifier's compatibility
  self-check. Authority shutdown and the point-of-no-return receipt are illegal until that preflight
  succeeds. Resume always executes the exported pinned artifact and rejects a missing, changed, or
  newly built runner, dependency closure, manifest schema, or interpreter registry instead of
  silently upgrading mid-teardown. Require `nuke` to create and acknowledge an operator/harness-
  owned non-secret external receipt
  before the point of no return. Encode it as bounded length-delimited canonical frames carrying a
  version, manifest digest, monotonically increasing frame index, stable node ID, stable attempt ID,
  previous-frame digest, payload checksum, and typed intent/observation/result. Every initial create/
  rename and appended committed frame requires file fsync plus parent-directory fsync before the
  corresponding external effect or acknowledgement. A standalone idempotent decommission runner
  reopens and validates the manifest signature/digest, frame lengths/checksums, complete hash chain,
  indices, and node/attempt IDs before resuming from that receipt plus a fresh admin prompt. It may
  discard only an incomplete final frame and must truncate/fsync the file and directory back to the
  last complete valid frame; interior corruption, a complete invalid tail, chain/index drift, or a
  conflicting reused ID refuses. After any crash or missing response it re-observes the exact
  external node before retrying the same durably recorded attempt ID, so a torn receipt can never
  authorize duplicate mutation. It journals exact delete/read-back outcomes. Its SES subgraph first proves
  consumers quiescent, destroys/read-backs the provider stack and external SMTP IAM family, then
  uses still-live Target Agents to tombstone/read-back target generations and retained-home custody;
  every attempted-node failure is aggregated. Because TLS retention and
  Authority backup use disjoint prefixes in the shared bucket, it deletes TLS objects/versions and
  identity first without deleting the bucket; the final backup node proves every registered prefix
  absent, then deletes backup objects/identity and the shared bucket last. It appends terminal
  absence evidence. Normal Authority queryability ends at the exported manifest; it never claims a
  backup receipt after deleting the backup.
- Add negative source/route/config lints that make those transports unable to return unnoticed.

### Validation

1. Migration fixtures cover missing, valid legacy, staged, released predecessor, corrupt,
   concurrent, interrupted-before-epoch, and interrupted-after-epoch states.
2. Exactly one writer exists at every reachable state; direct rollback after epoch activation
   refuses rather than resurrecting a stale gateway writer, an old process restarting after the
   freeze cannot mutate, and any recovery is a forward migration to a strictly greater epoch.
3. Production-route and source scans prove no supported gateway/host-direct lifecycle transport.
4. Config generation/CAS/projection, operator-material sealing/generation/revoke, split-credential,
   retained-home non-recoverable-material custody/rewrap, burn-recipient initial-token non-use/
   encrypted-share recovery, and exact A/TXT DNS owner/delete/read-back fixtures pass without a
   generic transport. SES-SMTP provider construction is unrepresentable and its live ownership
   migration remains explicitly assigned to Sprint `8.11`.
5. The frozen counterexample fixture matches every separately captured HEAD/dirty/source-policy/
   source-manifest/config/image/topology-wiring/envelope/load/fault-schedule identity, refuses an
   incomplete or reused identity, rejects every excluded secret/runtime/build-root input and public
   raw secret hash, and has no route into the production capability registry.
6. Pulumi/lifecycle/cleanup fake-boundary integration suites pass through the new clients.
7. Decommission crash fixtures at every node resume from the same exported manifest; no run crosses
   the point of no return without a matching frame whose file and parent directory are fsynced.
   Preflight fixtures prove the exact verifier/runner artifact and dependency metadata live outside
   every deletion target, are file/directory-fsynced and byte-for-byte read back, and are digest/
   schema/interpreter-registry-pinned before Authority stop. Missing/lost artifacts, binary upgrades,
   dependency drift, or schema/registry mismatch refuse before further mutation; only the pinned
   exported build may resume after a crash.
   Reopen fixtures validate the signed manifest binding and longest complete length-delimited,
   checksummed hash-chain prefix; byte-boundary torn tails recover only by truncating/fsyncing to the
   prior valid frame, while interior corruption, complete-invalid tails, chain/index drift, and
   conflicting node/attempt IDs refuse. Crash-before/after every intent/effect/result boundary
   preserves stable node/attempt IDs and authoritatively re-observes before retry. TLS-prefix
   deletion cannot delete the shared bucket, the SES subgraph deletes/read-backs external IAM before
   live-Agent target/custody tombstones and aggregates all failures, and the backup/all-prefix/
   shared-bucket node is last.
8. `prodbox dev check` and all local test suites pass.

### Remaining Work

None on Sprint `4.50`'s now-explicit resource-node/authority foundation. Sprint `4.85` owns the
separate terminal decommission-program residual corrected under Increment FF: home uninstall,
`.data` disposition, final audit, and terminal-receipt read-back must enter the signed manifest and
external receipt graph before total-decommission completion is constructible. The TLS lane is
exact-observe/CAS/read-back and passes 12/12. The retained signed Provider
vocabulary supplies encrypted, expiring EKS client authentication without credential projection
(5/5 projection and 18/18 execution), while native SES/Route53 production reconciliation dispatches
through authenticated Provider intents. `HostDirectAuthorityStore`, `HostDirectObjectStore`, and the
host AWS-credential projection module are physically absent and guarded by source checks; the sole
remaining refusing resolver is test-harness-only Phase-8 migration work, not a production caller.
Clean-install reconcile invokes the retained backup-admission reconciler before config CAS.

Closure evidence: warning-clean library/executable builds; `prodbox dev check` exit 0;
`prodbox test unit` exit 0 with 2972/2972 main tests plus 27/27 retained admission, 33/33 request
authentication, and 27/27 authenticated transport. A broad CLI integration audit was also run and
correctly exposed stale Phase-5 fake-runtime assumptions about filesystem-authoritative config and
removed transports; Standard N assigns that suite repair to the already-open Phase-5 surface rather
than reopening this independently validated authority cutover. Current-revision live infrastructure
exercise remains the non-blocking Standard-O/Standard-P axis.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - migration and deletion gates.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - sole supported authority path.
- `documents/engineering/vault_doctrine.md` - new state/session authority and removed transports.
- `documents/engineering/code_quality.md` - forbidden legacy routes/fallbacks.

**Product docs to create/update:**

- `README.md` - cutover state and supported diagnostic path.

**Cross-references to add:**

- Keep the pending-removal ledger authoritative until both code removal and revision-scoped
  deployment qualification are recorded.

## Sprint 4.51: Durability-Indexed Retained Authority Storage [✅ Done]

**Status**: Done — the byte-safe **type foundation (Increment A)** landed and is fully validated
2026-07-14: the `StoreLifetime` phantom index, its typed namespace-partitioning constructors, the
guard/object split resolution, and the compile + byte-erasure witness. The byte-compat-critical
**production cutover (Increment B)** — the host-direct `'ClusterRetained` adapter, the gateway
retype, the live-transaction cutover, and `OperationRecord` — is deferred to a dedicated pass
(cluster-adjacent; end-to-end byte-compat is Standard-O).
**Live-proof**: pending — host-PUT/daemon-GET byte compatibility and live AWS response-loss behavior
remain non-blocking Standard-O evidence.
**Deployment qualification**: pending
**Implementation**: ✅ **Increment A landed** — `src/Prodbox/Lifecycle/StoreLifetime.hs` defines the
DataKinds-promoted `StoreLifetime = ChartLifetime | ClusterRetained | CrossClusterDurable`.
`src/Prodbox/Lifecycle/CheckpointAuthority.hs` now carries it as a fully-erased phantom on
`ModelBObjectCoordinate (l :: StoreLifetime)` (with a load-bearing `type role … nominal` that blocks
`coerce` tag-laundering), `ModelBCasRequest (l :: StoreLifetime) value` (phantom before value so the
derived `Functor` still targets the payload), and `ModelBCasAdapter (l :: StoreLifetime) m value`;
the un-exported polymorphic `unsafeCoordinate` is fronted by the full-name-tagging constructors
`mkClusterRetainedCoordinate` / `mkChartLifetimeCoordinate` / `mkCrossClusterDurableCoordinate`
(each passes the byte-identical full logical name — no prefix-splitting), and `ModelBCodec` is lifted
in so the future host-direct adapter can share it without a cycle. **Design refinement (vs. the
original plan): `ModelBLeaseGuard` is NOT phantom-indexed** — a lease is always retained authority
state, so its coordinate is monomorphically `'ClusterRetained`; this cleanly lets a `'ChartLifetime'`
Pulumi checkpoint object be guarded by a retained lease (the real
`EncryptedBackend.withFencedDecryptedStackEnvironment` case) without a second lifetime parameter. The
phantom is threaded through the full 16-file consumer cascade (retained lease / target-intent /
SMTP coordinates → `'ClusterRetained'`; the `pulumi-stack/aws-ses` checkpoint → `'ChartLifetime'`;
`gatewayModelBCasAdapter` left polymorphic in `l`).
✅ **Increment B byte-compat de-risk landed (2026-07-16)**: `authorityLogicalObject` — the single
function mapping a retained-authority logical name to its `LogicalObject` (`pulumi-stack/*` →
`LogicalPulumiStack`, else → `LogicalLongLivedState`) — is lifted from `Gateway/Daemon.hs` into the
shared SSoT `Prodbox.Minio.EncryptedObject`, so the daemon and the future host-direct adapter route
through ONE function and their sealed envelopes are byte-identical by construction (not merely "looks
compatible"). `test/unit/AuthorityLogicalObjectTaxonomy.hs` pins the exact stored-key namespace
(`long-lived-state/…` for lease / target-commit-intent / SMTP families; `pulumi-stack/…` for the
checkpoint), the AAD (`clusterId|<stored-key>`), and the opaque-key HMAC derivation, so any drift
that would silently orphan retained objects fails the build pre-cluster.
✅ **Increment B Stage B landed (2026-07-24)**: the Model-B ↔ authority-object translation is lifted
into the shared SSoT `src/Prodbox/Lifecycle/ModelBCasTransport.hs` (`ModelBTransport` +
`modelBCasAdapterOverTransport`), and BOTH transports now delegate to it — `gatewayModelBCasAdapter`
(`CheckpointAuthorityStore.hs`, refactored to a thin gateway-HTTP transport, signature unchanged) and
the NEW `src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs` `hostDirectModelBCasAdapter ::
HostDirectPulumiHandle -> LongLivedCheckpointAuthority -> ModelBCodec value -> ModelBCasAdapter
'ClusterRetained IO value` (over the Stage-A `AuthorityObjectCore` host-direct primitives). This
extends Stage A's structural byte-compat one level up: the coordinate-authority guard, guard-coordinate
validation, payload encode/decode, and every `ModelBObservation`/`ModelBCasResult` mapping now exist
exactly once, so the two transports cannot silently diverge. `test/unit/HostDirectModelBAdapter.hs`
(11 cases) proves the shared adapter preserves observe/CAS/conflict/guard/coordinate-authority/
corrupt-encode semantics over the same in-memory conditional-put fake, plus a `'ClusterRetained` type
witness. Evidence: `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance); the new
suite 11/11; existing `LifecycleAuthority*`/`AuthorityObjectCore` suites unaffected. The host-direct
adapter is now a live-transaction writer.

**Evidence supersession (Sprint `0.21`, 2026-08-05).** The two modules named in the Stage-B record
above no longer exist: Sprint `4.50` deleted `HostDirectAuthorityStore.hs` with the rest of the
host-direct transport, and the differential suite went with it. The record stands as dated history,
but the surviving evidence a reader can open today is
`test/unit/ModelBCasTransportAdapter.hs`, which Sprint `4.53` created to carry that coverage forward
over the same `modelBCasAdapterOverTransport` seam (its module header records the replacement), and
`src/Prodbox/Lifecycle/ModelBCasTransport.hs`, which survives as the one Model-B ↔ authority-object
translation. This is the same repair Sprint `4.54` applied to Sprint `4.53`; Standard C requires the
citation to point at something that exists. ✅ **Increment B Stage D transport half landed
(2026-07-27)**: the gateway adapter is statically `'ChartLifetime`; retained lease, target-intent,
and SMTP-projection operations use one transaction-resolved host-direct material value and a fresh
short MinIO port-forward window per read/CAS. The gateway remains reachable only for authority
clock observations. Unit 2,353/2,353 passes. ✅ **Stage D operation fold and Stage E classification
landed (2026-07-27)**: the SES-specific durable `OperationRecord` intent/re-observation fold and
crash table are complete. The `host-direct-object-store` escape is sanctioned only for retained
bootstrap state; broader host access remains owned by Sprint `4.50`. Live
no-double-`CreateAccessKey` and cannot-observe-never-re-fires behavior remains Standard-O evidence.
✅ **Stage D operation-store foundation landed (2026-07-27)**:
`Prodbox.Lifecycle.Authority.OperationStore.operationRecordCodec` gives the existing append-only
`OperationRecord` a bounded, versioned, canonical-CBOR Model-B codec. Armed and completed records
round-trip; over-bound, corrupt, unsupported, and non-canonical envelopes refuse before
interpretation. The focused operation-journal suite passes 10/10.
✅ **Stage D SES binding landed (2026-07-27)**: the production SMTP repair interpreter
uses a generation-scoped retained `OperationRecord`: it confirms the armed intent before
`CreateAccessKey`, confirms the completed result (including recoverable secret material) before
publishing the SMTP projection, retains rather than compensates a durably completed key when
projection CAS is interrupted, and replays that completed result before inventory cleanup on
restart. The production adapter uses `operationRecordCodec` over the same transaction-resolved
host-direct retained material. The focused SMTP interpreter suite passes 9/9 across arm,
completion, and projection response-loss prefixes; serial unit passes 2,357/2,357 and
`prodbox dev check` exits 0.
**Discovery**: Increment B's transport cutover and `OperationRecord` are MORE coupled than first
scoped — a host-direct adapter would hold a MinIO port-forward across the entire ~70-minute lease
bracket, so the bracket removal must land WITH the transport cutover, not after it.
**Grounded + adversarially-verified Stage B–E plan (2026-07-18)**: an 8-agent design workflow
deep-read every cutover site and produced a staged plan whose byte-compat hazards are
*verified-mitigated*. The recommended shape adds a shared `src/Prodbox/Lifecycle/ModelBCasTransport.hs`
seam (`modelBCasAdapterOverTransport`) that BOTH `gatewayModelBCasAdapter` and the new host-direct
adapter delegate to — extending Stage A's structural byte-compat one level up (no second hand-maintained
ModelB↔AuthorityObject translation copy). Stage B (host-direct adapter + suite) and Stage C
(`OperationRecord` decide/evolve + canonical CBOR + suite) are additive and build green pre-cluster;
Stage D is the ATOMIC retype of `gatewayModelBCasAdapter → 'ChartLifetime` breaking exactly seven
sites (four move to host-direct: `LeaseRuntime` productionLeaseInterpreter + `AwsSesStack` target-commit
/ smtp-observe / smtp-repair; two keep the `pulumi-stack/aws-ses` checkpoint on the retyped gateway
adapter; one test) with GHC's type errors as the checklist. **The adversarial pass found a MATERIAL
FLAW in the bracket-dissolution design**: `productionLeaseInterpreter` still needs a *reachable gateway
daemon* for the authority-clock / wait-until / quiescence / lease acquire-release, so replacing the
gateway port-forward with host-direct MinIO windows would fail lease acquisition — each window must
keep the gateway forward open (nested) or reroute the authority clock host-direct. **Stage D's
functional correctness (no double `CreateAccessKey` across a Window1↔Window2 interruption;
cannot-observe → Ambiguous never re-fires) is Standard-O — provable only by a live
`prodbox test all --substrate aws`.** Because Stage D is genuinely cluster-adjacent and the prior pass
deliberately declined to land an unused byte-compat-critical adapter, Increment B remains a dedicated
pass, now starting from this verified, flaw-corrected plan.
**Independent Validation**: ✅ compile witness — the 16-file production cascade typechecks under the
phantom index, and `test/unit/StoreLifetimeWitness.hs` positively exercises well-typed
`'ClusterRetained'` and `'ChartLifetime'` round trips and documents the two cross-lifetime
expressions GHC rejects. ✅ byte-erasure pin (the top-risk mitigation) — the witness asserts
`mkClusterRetainedCoordinate` and `mkChartLifetimeCoordinate` yield byte-identical authority + logical
name for the same input, so re-tagging never drifts sealed-envelope bytes. Full pre-cluster gate
green 2026-07-14: unit PASS, `prodbox dev check` exit 0 (`-Werror`). 🔄 the CAS taxonomy tables vs. an
in-memory fake and the operation-record crash/replay tables land with Increment B (they validate the
host-direct adapter + `OperationRecord`, which Increment A does not introduce).
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, and
`documents/engineering/pure_fp_standards.md`

### Objective

Close the storage half of the `F-SES` class frozen by counterexample `LCPC-2026-07-11`: make
retained authority state unrepresentable through a chart-lifetime transport by indexing every
Model-B coordinate and adapter with its storage lifetime, and make the retained SES lease release
idempotent by recording operation intent durably instead of holding correctness open across a
synchronous HTTP bracket.

### Deliverables

- Define `StoreLifetime = ChartLifetime | ClusterRetained | CrossClusterDurable` as a phantom index
  on **both** the Model-B object coordinate and the CAS adapter, with smart constructors that
  partition the object namespace; storing retained state through an ephemeral transport becomes a
  type error. The gateway-backed adapter is retyped `ChartLifetime`.
- Add a host-direct `ClusterRetained` adapter over the same sealed envelopes (byte-compatible;
  transport-only cutover). This is the Lifecycle Authority primary MinIO namespace of the
  control-plane architecture, reached host-direct until the Authority Pod exists. The retained SES
  lease/intent/projection/checkpoint coordinates flip to `ClusterRetained`.
- Add `OperationRecord` — an operation-ID intent CAS-written to the retained store before the
  external SES effect and resolved by re-observation, making lease release idempotent and removing
  the seventy-minute-synchronous-bracket correctness boundary.
- Relation to Sprint `4.50`: this sprint is the retained-SES subset of the gateway-route removal
  landing early; Sprint `4.50` still owns the full removal.

### Validation

1. A compile witness proves the chart-lifetime write path for retained coordinates no longer
   typechecks.
2. CAS taxonomy tables against an in-memory fake prove the `ClusterRetained` adapter preserves the
   existing conditional-put semantics over the same sealed envelope bytes.
3. Operation-record crash/replay tables prove lease release converges by re-observation at every
   crash boundary instead of depending on a best-effort release response.
4. Unit suites, warning-clean build, and `prodbox dev check` pass; no cluster is required.

### Closure

- ✅ Increment A (the `StoreLifetime` phantom index, typed constructors, guard/object split
  resolution, 16-file consumer cascade, and the compile + byte-erasure witness) landed and validated
  2026-07-14.
- ✅ Increment B byte-compat de-risk (2026-07-16): `authorityLogicalObject` lifted to the shared
  `Prodbox.Minio.EncryptedObject` SSoT (daemon + future host-direct adapter share one function →
  byte-identical envelopes by construction) + `AuthorityLogicalObjectTaxonomy.hs` pinning the exact
  `long-lived-state/`/`pulumi-stack/` stored-key namespace, AAD, and opaque-key derivation. dev check
  exit 0, unit PASS.
- ✅ Increment B Stage B landed (2026-07-24): the shared `ModelBCasTransport` seam
  (`modelBCasAdapterOverTransport`) that both `gatewayModelBCasAdapter` (refactored) and the new
  `hostDirectModelBCasAdapter` (`HostDirectAuthorityStore.hs`, `'ClusterRetained`) delegate to, plus
  the `HostDirectModelBAdapter` differential suite (11 cases over the same in-memory conditional-put
  fake + a `'ClusterRetained` type witness). dev check exit 0, warning-clean, existing suites
  unaffected.
- ✅ Increment B Stage D transport half landed (2026-07-27): gateway CAS is `'ChartLifetime` only;
  `productionLeaseInterpreter` receives the retained adapter explicitly; `AwsSesStack` resolves
  retained material once and uses short host-direct windows for lease, target-intent, and SMTP CAS.
- ✅ The bounded versioned canonical-CBOR `OperationRecord` Model-B codec is landed (focused 10/10).
- ✅ Increment B Stage D operation fold and Stage E classification landed (2026-07-27):
  generation-scoped arm-before-create, completion-before-projection, pre-cleanup completed replay,
  fail-closed binding/generation checks, and response-loss coverage. Focused SMTP 9/9, operation
  journal 10/10, serial unit 2,357/2,357, and `prodbox dev check` exit 0. End-to-end
  host-PUT/daemon-GET byte compatibility and live AWS response-loss behavior remain non-blocking
  Standard-O evidence.
- Sprint `5.20` derives restore/cleanup edges from the storage-lifetime facts Increment A already
  registers; Sprint `4.50` deletes the legacy transports (and Increment B's gateway retype is the
  retained-SES subset of that removal landing early).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - durability-indexed
  authority-namespace coordinates and the host-direct retained authority store.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - storage-lifetime classes and
  retained-custody rules in the registry doctrine.
- `documents/engineering/pure_fp_standards.md` - durability-indexed coordinates as a phantom-index
  pattern.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link the [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) row for
  chart-lifetime custody of retained SES authority CAS objects to this sprint.

## Sprint 4.52: Observed-Host Over-commit Rejection [✅ Done]

**Status**: Done (2026-07-27) on the code-owned surface; the live host-probe exercise remains the
non-blocking Standard-O axis.
**Implementation**: `src/Prodbox/Capacity/ObservedHost.hs` defines the hidden-constructor
`ObservedHostRoot`, which observes cpu/memory plus the durable and ephemeral axes on **distinct
devices** — the kubelet root filesystem vs. the retained-PV host path. `src/Prodbox/Capacity/Allocation.hs`
gains `compileResourcePlanAgainstObserved`, which folds host coverage into the `AllocatedResourcePlan`
proof across all **four** axes, using a single shared-device joint budget when the two storage devices
coincide (fixing today's single `df /` fanned into both storage axes). `src/Prodbox/CLI/Rke2.hs`
`ensureRke2ResourceGuardrails` compiles against the observed proof and fails with the offending
dimension; it deletes `hostCapacityCoversPlan` and **both** saturating `clusterAllocatable` copies (in
`Rke2.hs` and the duplicate in `src/Prodbox/Settings.hs`), retargeting to the proof's `planAllocatable`,
and renders the guardrail manifests through the shared `Prodbox.Capacity.Render` (Sprint `3.28`).
**Deployment qualification**: pending — changes the Standard-P resource-envelope guardrail surface.
**Independent Validation**: `prodbox-unit` passes 2,353/2,353, including independent-axis,
offending-dimension, and shared-device joint-budget tables; `prodbox test integration cli` passes
52/52, including built-frontend RKE2 reconcile and resource-guardrail coverage. The live
`df`/`nproc` observed-host refusal is a non-blocking Standard-O proof. No deployed cluster, AWS, or
later phase is required.
**Docs to update**: `documents/engineering/host_platform_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`

### Objective

Close invariant (b) `cluster ≤ host` at reconcile against the **observed** machine as a compile refusal,
not the current late boolean. Sprint `4.41` checks only that the authored `host_capacity` is not larger
than the observed host; it never re-proves that the cluster's allocations fit the *observed* machine.
Compiling the `AllocatedResourcePlan` against an `ObservedHostRoot` makes an observed-host over-commit
unbuildable — the observed ring of the three-ring boundary in
[resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md), closing the
host/cluster (b) lemma of § 2B.

### Deliverables

- `Capacity/ObservedHost.hs` `ObservedHostRoot` (hidden constructor) observes cpu/memory plus durable and
  ephemeral on **distinct devices** (kubelet root fs vs. the retained-PV host path).
- `compileResourcePlanAgainstObserved` folds host coverage into the proof across all four axes, with a
  single shared-device joint budget when the two storage devices coincide.
- `ensureRke2ResourceGuardrails` compiles against the observed proof and fails with the offending
  dimension; delete `hostCapacityCoversPlan` and both saturating `clusterAllocatable` copies (`Rke2.hs`,
  `Settings.hs`), retargeting to `planAllocatable`; render the guardrail manifests through the shared
  `Capacity.Render`.

### Validation

1. `rke2-reconcile.txt` (+ `-with-edge.txt`) goldens regenerate byte-identical (checked subtraction
   equals saturating when there is no underflow).
2. A fake `PRODBOX_TEST_HOST_CAPACITY` below the plan ⇒ a compile refusal naming the offending dimension.
3. Unit/integration suites and `prodbox dev check` pass.

### Remaining Work

- None on the code-owned surface. The live `df`/`nproc` observed-host refusal is a non-blocking
  Standard-O proof and deployment qualification remains pending.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/host_platform_doctrine.md` - the observed-host over-commit rejection
  (dual-device durable vs. ephemeral).
- `documents/engineering/resource_scaling_doctrine.md` - invariant (b) closed at reconcile against
  observed facts via the § 2C observed ring.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Enqueue `hostCapacityCoversPlan` and both `clusterAllocatable` copies (`Rke2.hs`, `Settings.hs`) in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) under this sprint.
- Link the observed-host proof to Sprint `1.68`'s `AllocatedResourcePlan`, Sprint `1.69`'s
  `planAllocatable`, and Sprint `3.28`'s shared `Capacity.Render`.

## Sprint 4.53: Typed Endpoint-Readiness for the Host-Direct Object-Store / Lease Path [✅ Done]

**Status**: Done — own-surface Phase-4 reopen (Standard A) adopting the typed three-valued readiness
doctrine ([bootstrap_readiness_doctrine.md §2.4](../documents/engineering/bootstrap_readiness_doctrine.md))
on the lifecycle authority/lease/Model-B core. A live home `prodbox test all` failed
`RestoreNodePrepareRetainedSes` because a transient host-direct MinIO endpoint-unreachability
(`aws s3api get-object … could not connect to 127.0.0.1:39000`) was collapsed — through one
failure bucket at every layer — into a terminal `LeaseBoundedOwnershipLost` (the bring-up-dual defect).
This makes "classify a transient endpoint-unreachable as terminal authority-loss" unrepresentable.
**Persistence protocol untouched; happy path byte-identical.**
**Implementation**: ✅ **Phase 1 (read path) + 1b (write path) landed.** `ModelBObservation` gains a
distinct retryable `ModelBEndpointUnready` (and `ModelBCasResult` a `ModelBCasEndpointUnready`),
classified at the single shared `ModelBCasTransport` seam via `transportFailureObservation` /
`transportFailureCasResult` reusing `Prodbox.Service.isRetryableTransientFailure` plus the aws-phrase
fragments (the shared base omits "could not connect"). `LeaseRefusal` gains a distinct
`LeaseAuthorityEndpointUnready` routed from the four `ModelBObservation`→refusal sites; the
`LeaseRuntime` bounded-runner monitor retries **only** that constructor within the existing lease
readiness budget (gate stays closed), terminal on budget exhaustion, with **every other refusal
terminal** (fencing-safety catch-all). Acquire/release CAS loops retry `ModelBCasEndpointUnready`
within their deadlines. 18 + 6 exhaustive `ModelBObservation` / `ModelBCasResult` mirror arms preserve
fail-closed behavior everywhere else. The invariant is build-enforced by `readinessObservationViolations`
in `runConformanceTierChecks` (`src/Prodbox/CheckCode.hs`).
**Live-proof**: 🧪 the live home `prodbox test all` restore-through-a-transient-MinIO-blip proof
(`RestoreNodePrepareRetainedSes -> succeeded`) is the non-blocking Standard-O axis.
**Deployment qualification**: pending — a lifecycle-orchestration *failure-classification* refinement;
persistence protocol/wire JSON/CAS semantics unchanged, so it neither advances nor invalidates the
already-pending Standard-P qualification, and the current revision must not be called deployment-ready
on the strength of this compile-time fix alone.
**Independent Validation**: ✅ pure + fake-driven, no live cluster:
`test/unit/ModelBCasTransportAdapter.hs` (the classifier maps the aws phrase / connection-refused →
`ModelBEndpointUnready`, auth/HMAC/decode errors → `ModelBUnobservable`, both write-path analogues,
and the observe/CAS seams route them through a transport that actually fails), and
`test/unit/LifecycleLease.hs` (the monitor
retries a transient endpoint-unready to recovery, fails closed on persistence past the deadline, and
keeps a genuine loss terminal without retry). `prodbox dev check` exit 0 including the conformance gate.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

Give the host-direct object-store / lease path a typed not-yet-ready endpoint state so a transient
endpoint-unreachability is retried within the lease budget rather than collapsed into terminal
authority-loss, and make "issue an op against an unproven endpoint" unrepresentable.

### Deliverables

- A distinct `ModelBEndpointUnready` / `ModelBCasEndpointUnready` classified once at the transport seam,
  and a distinct retryable `LeaseAuthorityEndpointUnready` refusal.
- A bounded-runner monitor + acquire/release CAS loops that retry only the endpoint-unready class
  within the readiness budget, every other refusal terminal (fencing-safe).
- A build-enforced conformance gate against re-collapsing the third value.
- **Phase 2 (deep-probe witness):** replace the shallow host-direct `waitForPort` gate with a real S3
  round-trip proof and a `HostDirectEndpointProven` witness carried in the handle, so no object-store op
  is constructible without a proven-reachable endpoint.

### Validation

1. The classifier maps the aws "could not connect" phrase and a connection-refused to the retryable
   constructor, and auth/decode failures to the terminal one.
2. The monitor retries a transient endpoint-unready to recovery, fails closed past the deadline, and
   keeps a genuine fence/expiry loss terminal without retry.
3. `prodbox dev check` (incl. the three-valued readiness gate) and the lease/host-direct suites pass.

### Remaining Work

None. **Correction (2026-08-04, Sprint `4.54`):** this sprint's Independent Validation originally
rested on `test/unit/HostDirectModelBAdapter.hs`, which Sprint `4.50` deleted along with the
host-direct store it was named for. The three classifier cases behind Validation item 1 existed only
as uncommitted edits and are in no revision, so the phrase-to-constructor mapping had no behavioural
coverage — only a constructor-name presence scan, which cannot detect a wrong mapping. Sprint `4.54`
restores the coverage on the surviving seam; the citation above now names the module that exists.

Phase 2 replaces the `/dev/tcp` listener check with a bounded authenticated S3
`list-buckets` round trip. The port-forward callback receives an opaque
`HostDirectEndpointProven` value whose port can be projected only after that proof succeeds; the
Pulumi prerequisite and bootstrap-bundle readers consume the witness. The shallow shell probe and
its helper are deleted. Warning-clean library compilation validates the integrated type cutover;
the live transient-MinIO recovery remains the non-blocking Standard-O proof above.

## Documentation Requirements

**Engineering docs to create/update:**

- Sprint `4.60`: `documents/engineering/lifecycle_control_plane_architecture.md` - the control-plane
  server answers or refuses; it never closes an accepted connection silently.
- Sprint `4.60`: `documents/engineering/integration_fixture_doctrine.md` - the same rule for a
  fixture server (already authored by governance Sprint `0.25`; this sprint records the landed
  mechanism against it).
- ✅ `documents/engineering/bootstrap_readiness_doctrine.md` - §2.4 the transient-vs-persistent
  endpoint-unobservable distinction (SSoT).
- `documents/engineering/lifecycle_reconciliation_doctrine.md` - none required beyond the existing
  §3.1 bring-up-twin callout, which this instance realizes on the lease/Model-B path.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Enqueue the shallow host-direct `waitForPort` readiness gate in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) under this sprint (retired by
  Phase 2).

## Sprint 4.54: Restore Behavioural Coverage of the Endpoint-Readiness Classifier [✅ Done]

**Status**: Done (2026-08-04) — Phase `4` own-surface reopen (Standard A/N) repairing this phase's
own validation evidence. Test-only; no production behaviour changes.
**Implementation**: `test/unit/ModelBCasTransportAdapter.hs` (new), `prodbox.cabal`,
`test/unit/Main.hs`
**Blocked by**: none (own-surface reopen; validated without a later phase or live infrastructure).
**Deployment qualification**: pending — a test-only change touches no Standard-P
production-composition surface, so it neither advances nor invalidates the already-pending
qualification.
**Independent Validation**: pure + fake-driven, no live cluster —
`prodbox test unit -p "Sprint 4.53"` 19/19, plus a mutation exercise: collapsing
`ModelBEndpointUnready` back into `ModelBUnobservable` fails 3 of the 19 cases, and the classifier
restores byte-exactly afterward. `prodbox dev check` exit 0.
**Docs to update**: none

### Objective

Sprint `4.53` was recorded `Done` with `Independent Validation` resting on
`test/unit/HostDirectModelBAdapter.hs`. Sprint `4.50` deleted that module along with
`src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs`, the transport it was named for. Both committed
revisions of the deleted module contain zero endpoint-readiness cases, so the three cases behind
`4.53`'s Validation item 1 were never committed at all.

The classifier is production-live, and the only surviving gate over it is
`readinessObservationViolations` — a constructor-name presence scan over three fixed paths. A
presence scan proves the constructors are mentioned; it cannot prove the phrase-to-constructor
mapping is right. The exact defect `4.53` exists to prevent — a transient MinIO connection-refused
collapsing into terminal authority-loss — would therefore have shipped silently.

The store is gone and is not coming back; the seam it exercised survives in
`Prodbox.Lifecycle.ModelBCasTransport`, which is where the coverage belongs.

### Deliverables

- `test/unit/ModelBCasTransportAdapter.hs` replaces the deleted module. It carries the surviving
  adapter cases (coordinate authority, observe/CAS, conflict, corrupt-encode, fail-closed lease
  guard) and adds the endpoint-readiness cases `4.53` claimed.
- Both classification paths are pinned behaviourally: `transportFailureObservation` and
  `transportFailureCasResult` over a table of transient details (the aws-CLI
  "could not connect to the endpoint URL" phrase, connection-refused, connection-reset) and terminal
  details (signature mismatch, access denied, HMAC failure, decode failure).
- A `failingTransport` fake drives the classifier through the adapter. Without it the `Left` arms of
  `modelBCasAdapterOverTransport` are unreachable: the pre-existing `LifecycleLease.hs` case uses a
  codec that short-circuits on encode, so the transport is never consulted and the classifier never
  runs. A case pins that ordering explicitly so the gap cannot silently reopen.
- The deleted module's `'ClusterRetained` type-witness case is not restored: it witnessed
  `hostDirectModelBCasAdapter`, which no longer exists.

### Validation

1. `prodbox test unit -p "Sprint 4.53"` 19/19.
2. Mutation: collapsing the not-yet-ready arm into the terminal bucket fails 3 cases, proving the
   suite detects the exact regression class rather than merely exercising the code.
3. `prodbox dev check` exit 0.

### Remaining Work

None.

## Sprint 4.55: Control-Plane Readiness as Cached Facts ✅

**Status**: Done (2026-08-08) — Phase `4` own-surface work (Standard A/N) on the lifecycle
control-plane role runtimes this phase owns. Sprint `2.39` fixed this defect for the Bootstrap
Broker; five roles carried it unfixed. Both increments landed; the `m Bool` seam is deleted.
**Implementation**: `src/Prodbox/Readiness/ObservationSchedule.hs` (new — `ObservationSchedule`
extracted from the broker so one derivation is shared), `src/Prodbox/ControlPlane/RoleReadiness.hs`
(new — the four-valued observation, the `STM`-typed `RoleReadinessSource`, the layering algebra, and
the pure projection), `src/Prodbox/ControlPlane/RoleReadinessObserver.hs` (new — the background
observer, its supervised loop, and the constant-time request-path resolver),
`src/Prodbox/ControlPlane/Server.hs` (`interpreterReadiness` replaces `interpreterReadyz`;
`RoleReadinessResolver`), `src/Prodbox/ControlPlane/AuthenticatedRoleInterpreter.hs`
(`authenticatedHandlerReadiness` replaces `authenticatedHandlerReadyz`),
`src/Prodbox/ControlPlane/Runtime.hs` (per-role observers for all five roles),
`RoleInterpreters.hs`, `AuthenticatedRuntime.hs`, and the nine endpoint modules,
`src/Prodbox/CheckCode.hs` (`checkRoleReadinessProjection`, and an exact-module allowlist on the
Sprint `2.39` broker gate), `test/unit/RoleReadinessSuite.hs` (new), `test/support/TestSupport.hs`,
five test modules, and `prodbox.cabal`.
**Blocked by**: none.
**Deployment qualification**: pending — readiness semantics and queueing/admission are Standard-P
surfaces; both rows are already `pending`.
**Independent Validation**: pure fold plus fake-driven role fixtures, no live cluster — a role
`/readyz` handler performing backend I/O does not type-check, and layered readiness resolves from
one snapshot at one instant.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`

### Objective

The Bootstrap Broker was not special; it was the one that was measured. The Lifecycle Authority,
Authority Backup, TLS Retention, Provider Worker, and Target Secret Agent each perform backend I/O
**on the kubelet request path**, against a chart-declared `timeoutSeconds: 1`. That is the same
violation of
[bootstrap_readiness_doctrine.md § 0.7](../documents/engineering/bootstrap_readiness_doctrine.md)
Sprint `2.39` exists to repair.

**Count corrected against source, 2026-08-08 (Standard C).** This sprint originally said the five
roles "each run six signed S3 LISTs plus a Vault read plus a replay-projection read". That is wrong
for all five, and the corrected inventory is worth stating because the worst offenders were not the
ones the sprint named:

| Role | What its `/readyz` actually did |
|---|---|
| Lifecycle Authority | **five** signed S3 LISTs — the same `inClusterAuthorityReady store` reached from five separate handler layers, plus a custody record-path probe and a handoff-receipt read |
| Authority Backup | one signed S3 probe |
| TLS Retention | one signed S3 probe |
| Provider Worker | **zero** S3 LISTs, and the worst call in the set: a Provider Vault KV read followed by an `aws sts get-caller-identity` **subprocess** |
| Target Secret Agent | **zero** S3 LISTs, and up to **32 sequential Vault KV reads** — an `allM` over every registered target, which short-circuits only on failure, so the healthy path was the slowest |

Every authenticated role additionally carried a shared layer adding a retained-authority-epoch read
and a request-replay-projection read. The sixth `inClusterAuthorityReady` occurrence in
`Runtime.hs` is inside a per-operation repository resolver, not a readiness slot — counting it was
the grep-versus-trace error Sprint `4.58` recorded. The same wrong count appeared in this plan's own
[legacy ledger](legacy-tracking-for-deletion.md) row and is corrected there too.

Two aggravations. The role seam types readiness as `m Bool`, so *unreachable* and *not ready yet*
are the same value — the § 0.5 prohibition, and the *Distinguishability* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md). And the
layered handlers compose as `do a <- inner; b <- own; pure (a && b)` at six sites, which **does not
short-circuit**: every layer's backend call runs on every probe regardless of an earlier `False`.

### Deliverables

- The role seam exposes readiness **facts** in `STM` rather than an action in `m`. `STM` has no
  `IO`, so performing a signed S3 LIST on a probe path ceases to type-check — the invariant becomes
  structural rather than reviewed.
- A four-valued observation per dependency, mirroring the shape landed for the broker, with an
  absorbing refusal distinct from not-yet-ready.
- Layering composes facts, not actions, so N layers resolve from one snapshot at one instant.
- Split delivery: add the facts seam alongside the existing one and migrate a single role first;
  migrate the remaining four and delete the old seam in a second, separately-landed increment. The
  subtractive half is the 4.51-shaped one — land it alone.

### What landed

**Increment A** — the mechanism, proven, wired for one role. `Prodbox.Readiness.ObservationSchedule`
extracts Sprint `2.40`'s derived staleness bound so the broker and the five roles share one
definition rather than two that can drift; `Prodbox.ControlPlane.RoleReadiness` carries the
four-valued observation, the `STM`-typed source, the layering algebra, and the pure projection; and
`Prodbox.ControlPlane.RoleReadinessObserver` owns the background pass. The **Provider Worker**
migrated first — the role whose probe path shelled out to `aws sts get-caller-identity`.

**Increment B** — the subtractive half, landed after A was green. `interpreterReadyz :: m Bool` and
`authenticatedHandlerReadyz :: m Bool` are **deleted**; both seams now carry a
`RoleReadinessSource`. All five roles have observers, the nine endpoint layers compose facts through
`layerRoleReadinessSource`, and `serveControlPlaneRequest` resolves through an injected
`RoleReadinessResolver` that reads one clock and one transaction.

Three decisions worth recording:

- **The Lifecycle Authority's five LISTs became one observation.** They were always the same store
  reached from five layers, so the base layer contributes the dependency and the four outer layers
  contribute nothing. The identity element `noRoleReadinessContribution` exists for exactly this,
  and `composeRoleReadinessFacts` treats an empty dependency list as the identity so a pass-through
  layer does not have to invent a timestamp.
- **No observation was dropped in the move.** The custody record-path probe and the handoff-receipt
  read lived inside repository constructors whose readiness fields disappeared; rather than losing
  them, both are exported as labelled dependency observations
  (`observeTargetChildCustodyDependency`, `observeBootstrapHandoffDependency`) and folded into the
  Authority's background pass. The same observation, off the request path.
- **The broker's own Sprint `2.39` gate needed care.** Its `impureImportViolations` check permits
  only `Data.`/`Numeric.`/`GHC.Generics` prefixes, and sharing the schedule makes the projection
  import a `Prodbox.` module. Adding `"Prodbox."` as a prefix would have put every boundary in the
  repository back in scope — strictly worse than not sharing at all. The gate instead gained an
  **exact-module** allowlist naming one module.

### Validation (as run)

1. `prodbox-unit -p "Sprint 4.55"` — 10/10. (Written in the sprint as
   `prodbox test unit -p ...`; that flag does not exist on the `prodbox` surface. Pattern selection
   is a flag on the built test binary.)
2. **A role readiness handler that performs backend I/O is a type error.** The field is a
   `RoleReadinessSource` over `STM`, and `inClusterAuthorityReady store :: IO Bool`, so the shape
   that used to compile does not. This is carried by the seam's type; the suite records the exact
   refuted shape rather than asserting it at runtime, and the `dev check` gate
   (`checkRoleReadinessProjection`) additionally refuses any boundary import in the projection
   module and fails if the seam declaration disappears.
3. **Mutation exercise.** Collapsing `RoleDependencyIdentityRejected` into the non-terminal
   unavailable arm makes the projection report `object-store: connection refused` where
   `vault: role is not bound to this account` is expected — the absorbing case hidden inside a
   generic not-ready, which is the § 0.5 defect. The source restored byte-exactly (`cmp` clean) and
   10/10 returned.
4. **Layered readiness performs exactly one snapshot read per probe**, proven by counting fakes:
   three layers, one `atomically`, and after eleven probes each layer's observation count is still
   `1`. A single unready layer decides the composite and names itself, with no layer asked again.
5. `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit 0, and
   `prodbox test unit` exit 0 — 3215/3215 plus the dedicated 27/27, 33/33, and 27/27 suites.

### Remaining Work

None on this sprint's surface. The live proof — a role Pod reporting ready inside the chart's
`timeoutSeconds: 1` budget, and a stalled observer evicting it after the derived 20-second bound —
is a 🧪 Standard-O axis for the next `prodbox test all` on each substrate.

## Sprint 4.56: Thread the Dependency Admission Proof to the Act ✅

**Status**: Done (2026-08-08) — Phase `4` own-surface work on the capability readiness barrier and
anchored reconcile executor this phase owns.
**Implementation**: `src/Prodbox/Lifecycle/DependencyAdmission/Internal.hs` (new — the two
constructors), `src/Prodbox/Lifecycle/DependencyAdmission.hs` (new — the sole minter, the admission
set, the graph-derived bound, and the total re-validation),
`src/Prodbox/Lifecycle/CapabilityReadinessBarrier.hs` (the barrier returns the admission it minted
instead of discarding it), `src/Prodbox/Lifecycle/AnchoredReconcile.hs` (the executor threads an
admission set and invokes a mutation through a callback that requires a `MutationAdmission`),
`src/Prodbox/CLI/Rke2.hs` and `src/Prodbox/Lib/AwsSubstratePlatform.hs` (both drivers),
`src/Prodbox/CheckCode.hs` (`checkDependencyAdmissionBoundary`),
`test/unit/DependencyAdmissionSuite.hs` (new), `test/unit/CapabilityReadinessBarrierSuite.hs`,
`test/unit/Main.hs`, and `prodbox.cabal`.
**Blocked by**: none.
**Deployment qualification**: pending — lifecycle orchestration is a Standard-P surface; both rows
are already `pending`.
**Independent Validation**: pure, no live cluster — a mutating step cannot be invoked without an
admission value, and an admission older than its bound is refused by a total function.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

The repository already mints the right proof and then discards it. `classifyObservation` produces
an opaque, nominally-roled admission ticket binding coordinate digest, generation, and observation
instant, failing closed on mismatch, staleness, and stale generation. One line in
`Prodbox.Lifecycle.CapabilityReadinessBarrier` pattern-matches the ready verdict and returns unit.

Downstream, `runAnchoredStepOrder` takes the mutation as an action that accepts no admission and the
readiness gate as one that returns none, so a step mutating a component can run while that
component's graph-declared dependency was last observed ready an entire reconcile phase earlier —
minutes, across federated Vault unseal and settings reload.

This is the *Staleness* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md), and the
fix is the `ValidatedSettings` trick applied to ordering: make the proof a required argument.

### Deliverables

- An opaque `DependencyAdmission`, constructible only from a ready verdict, carrying the admitted
  component and the instant.
- The executor threads an admission set; the mutating step takes it as an argument, so a mutation
  with no admission is not expressible.
- A total re-validation at the mutating seam that refuses an admission older than a per-edge bound
  derived from the graph, not authored beside it.

### Validation (as run)

1. `prodbox-unit -p "Sprint 4.56"` — 8/8. (Written in the sprint as `prodbox test unit -p ...`;
   that flag does not exist on the `prodbox` surface. Pattern selection is a flag on the built test
   binary.)
2. **Invoking a mutating step without an admission is a type error.** `runAnchoredStepOrder` takes
   the `ComponentMutation` arm through a separate `MutationAdmission -> step -> IO ExitCode`
   callback, so the mutating path is unreachable without a proof. The proof itself is opaque: its
   constructors live in `DependencyAdmission.Internal`, and `checkDependencyAdmissionBoundary`
   fails any other `src/` module that names that representation — a mutating step cannot mint its
   own admission any more than it can skip one.
3. **Mutation exercise.** Deriving the bound and then discarding it — the same shape as the
   discarded ticket this sprint exists to fix — makes both the expiry case and the
   exactly-at-the-bound boundary case pass an admission that is `bound + 1` microseconds old. The
   source restored byte-exactly (`cmp` clean) and 8/8 returned.
4. The admission chain is exercised end to end rather than from a hand-built ticket: the suite
   drives `observationFromRef` → `classifyObservation` → `dependencyAdmissionFromVerdict`, because
   `AdmissionTicket` has no exported constructor and therefore no test can forge one either.
5. `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, and `prodbox test unit` exit 0 —
   3224/3224 plus the dedicated 27/27, 33/33, and 27/27 suites.

### Two things this does not claim

- **The per-edge bound is a mechanism, not a set of numbers.** The bound is read from the
  dependency's own resolved latency budget in the graph — genuinely derived, not authored beside
  the call site. But `componentRequirementSpec` returns the same `specRequireLatencyMicros` literal
  for every component today, so every edge currently derives the same value. The suite asserts that
  fact directly (`length (dedupe bounds) == 1`) so the next evidence sweep reads the limitation
  instead of inferring per-edge numbers that do not exist. When per-component budgets
  differentiate, the bounds differentiate with no change to this code.
- **It narrows the observe-to-act window; it does not make the pair atomic.** Only a fence does
  that, and that is Sprint `3.31`'s and the cardinality work's surface.

**Refusal-versus-retry, decided explicitly.** A hard refusal on an expired admission would have
failed the first home `cluster reconcile` outright, because admissions cannot survive a reconcile
phase boundary — `applyNativeInstallPlan` crosses federated Vault unseal and a settings reload
between phases. The executor therefore **re-observes the one dependency whose admission aged out**
and refuses only if the fresh observation also fails. That keeps the sprint's purpose (narrow the
window) without converting a routine phase boundary into a run failure.

### Remaining Work

None on this sprint's surface.

## Sprint 4.57: Delete the Superseded Precondition Orphans ✅

**Status**: Done (2026-08-05) — Phase `4` own-surface work on the precondition surface Sprint `4.11`
introduced and the managed-resource registry superseded.
**Implementation**: `src/Prodbox/Lifecycle/Preconditions.hs` (removed `noLiveClusterTaggedAws`,
`noUndrainedK8sAwsResources`, `noLiveOperationalIamUser`, `checkAll`, `renderPreconditionFailures`)
and the corresponding label-only cases in `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — zero call sites means zero runtime delta, so no Standard-P
surface moves.
**Independent Validation**: pure, no live cluster and no AWS credentials — every deleted export had
zero production references before removal, so the change is behaviour-preserving by construction;
`prodbox dev check` exit 0.
**Docs updated**: none. Verified by Sprint `0.27` (2026-08-12): no governed document under `documents/` names this sprint. This records a measurement — that no doc attributes text to this sprint — not a claim that no doctrine covers the behaviour it changed.

### Objective

Sprint `4.11` promised a composable precondition algebra. It shipped label-only tests as closure and
was never wired. Three of five predicates had zero production call sites, and **both composition
combinators — the module's entire stated reason to exist — had zero references anywhere, including
tests.**

`noLiveClusterTaggedAws` is the instructive one. It was not merely unused, it was **stale in a way
that would have caused harm if wired**: `runCascadePostflightTagSweep` (`src/Prodbox/CLI/Rke2.hs`)
already performs the identical check — same input, same discoverer, same renderer — and
additionally applies `partitionRetainedLongLived` to carve out infrastructure retained by design.
The orphan has no carve-out, so wiring it would have produced **false refusals on the state-backend
bucket and `aws-ses`**. It also returned a hard failure where
[lifecycle_reconciliation_doctrine.md § 6](../documents/engineering/lifecycle_reconciliation_doctrine.md)
calls for a non-fatal diagnostic.

The doctrine already recorded the supersession: § 4 states these predicates were generalized into
the registry's `reconcileAbsent`, which **is** wired as cascade step 3.

### Validation

1. Every deleted export had zero production references before removal.
2. The cascade postflight tag sweep still runs, and remains the wired implementation of this check.
3. `prodbox dev check` exit 0; the unit suite builds and runs with the label-only cases removed.

### Remaining Work

None. What survives is `StructuredError` plus `noLiveLongLivedPulumiStacks` /
`noLiveLongLivedPulumiStacksPreflight`, which are genuinely wired through
`src/Prodbox/Native.hs`.

## Sprint 4.58: Close the Unconditional Object-Store Write Surface ✅

**Status**: Done (Increment A 2026-08-05; Increment B 2026-08-06) — Phase `4` own-surface work on the
object-store write surface, the Target Secret Agent workload shape, and the target-sink
expected-version token this phase owns.
**Implementation**: Increment A — `src/Prodbox/Minio/ObjectStore.hs` and
`src/Prodbox/Minio/ObjectStoreNative.hs` (removed `putObject`, `putIfAbsent`, `putIfVersion` and
their now-orphaned `putGuarded` / `putObjectWithArgs` code paths),
`src/Prodbox/Minio/EncryptedObject.hs` (`putLogical`), `src/Prodbox/Vault/BootstrapBundle.hs`
(`putBundleObject`), and `charts/target-secret-agent/templates/deployment.yaml`
(`RollingUpdate` → `Recreate`). Increment B — new
`src/Prodbox/Lifecycle/TargetSinkVersion.hs` and
`src/Prodbox/Lifecycle/TargetSinkVersion/Internal.hs`,
`src/Prodbox/Lifecycle/TargetCommitIntent.hs` (removed `mkTargetSinkVersion`,
`targetSinkVersionText`, and the two now-unreachable `TargetCommitValueError` constructors),
`src/Prodbox/ControlPlane/TrustedTargetSink.hs` (sole minter; the parse and its refusal path
deleted), and `src/Prodbox/CheckCode.hs` (`checkTargetSinkVersionBoundary`).
**Blocked by**: none.
**Deployment qualification**: pending — the chart strategy change touches process topology, a
Standard-P surface, so it invalidates no prior `proven` row (both are already `pending`) but must be
named in any future one. Increment B moves no Standard-P surface: the Vault wire is unchanged,
because the expected version travels in `options.cas` and never in the record body
(`src/Prodbox/ControlPlane/TargetMaterialRecordCodec.hs` is untouched and names no version field).
**Independent Validation**: pure plus chart-render, no live cluster. Increment A — the removed
writers had zero external callers before removal, and the object-store modules now export **only**
`putIfAbsentObserved` and `putIfVersionObserved`, so an unconditional write is no longer
expressible. Increment B — `prodbox-unit -p "Sprint 4.58"` 8/8, plus the five suites whose fixtures
moved (`Sprint 4.47` 87/87, `Sprint 4.50 production decommission boundaries` 5/5, `Sprint 4.50
Target Agent generation tombstone` 13/13, `Sprint 4.50 authenticated decommission clients` 4/4,
`Sprint 5.17 retained SES different-sink recovery` 2/2), and **two mutation exercises, each restored
byte-exactly**: authoring a `TargetSinkVersion` outside the internal module fails to compile
(`GHC-01928`, illegal term-level use of the type constructor), and a second `src/` module naming the
internal representation fails `dev check` with the boundary message. `prodbox dev check` exit 0.
**Docs updated**: none. Verified by Sprint `0.27` (2026-08-12): no governed document under `documents/` names this sprint. This records a measurement — that no doc attributes text to this sprint — not a claim that no doctrine covers the behaviour it changed.

### Objective

Two findings, one of which corrects this plan's own ledger.

**The write surface.** `putObject` was exported at the same type as `putIfAbsent`, so an unfenced
authoritative write was expressible. The cleanup ledger recorded "11 unconditional call sites"; that
was a count of textual occurrences of the identifier. The true number of live unfenced authoritative
writes was **zero** — both leaf callers (`putLogical`, `putBundleObject`) were dead code. Removing
the entry points orphaned the entire unconditional code path, because the conditional writers use
separate helpers. This is the *Cardinality* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md), and with
zero live offenders, closing the surface *is* the move that makes the illegal state
unrepresentable — no permit needed threading to achieve it.

**The workload shape, which is the more serious finding.**
`charts/target-secret-agent/templates/deployment.yaml` declared `replicas: 1` with
`strategy: RollingUpdate`. On a single replica the default `maxSurge: 25%` surges to two pods, and
the pod carries a rollout-digest annotation implying routine rollouts — so the agent ran **two
concurrent writers during every deploy**. Alone among the six single-writer roles its chart comment
made no single-writer claim. `replicas: 1` is only a single-writer statement when the update
strategy cannot surge past it, and no type-level permit helps while the scheduler is running two
writers by design.

### Validation

1. The object-store modules export no unconditional writer; `putIfAbsentObserved` and
   `putIfVersionObserved` are the only exported writes.
2. Every removed function had zero external callers before removal, so the deletion is
   behaviour-preserving.
3. The rendered `target-secret-agent` Deployment carries `strategy.type: Recreate`.
4. A target-sink expected version cannot be authored: `TargetSinkVersion`'s constructor lives in an
   internal module with one permitted importer, and the mutation exercise confirms an attempt to
   construct one elsewhere is a compile error rather than a lint finding.
5. The boundary is enforced mechanically, not by convention: `checkTargetSinkVersionBoundary` fails
   `dev check` when a second `src/` module names the internal representation, and permits the public
   face to cross the boundary for the type while still refusing it the minter.
6. `prodbox dev check` exit 0.

### Remaining Work

**Increment B is closed, and this entry corrects what it said twice over (2026-08-06).**

The sprint's first entry said `PreparedTargetWritePermit` was written but unwired, needing threading
through one call site. Its 2026-08-05 correction replaced that with "a second writer routes around
the permit" in `src/Prodbox/ControlPlane/TargetSecretAgentExecution.hs". **Both were wrong on the
facts.** A source-level re-verification found four independent errors:

1. **The "second writer" is not unfenced.** `executeVerifiedTargetIntent` is total on
   `VerifiedTargetCommittedIntent`, exported abstractly and mintable only by
   `verifySignedTargetCommittedIntent`, which enforces Ed25519 verification against the Lifecycle
   Authority's issuer key plus issuer-generation, issuer-identity, authority-epoch, **fence-floor**,
   agent-identity, target-binding, action-digest and deadline checks. Every fencing field written
   into the record originates in those signed bytes, and the function re-reads agent-local trust,
   re-checks the deadline, and observes before and after its single CAS. The `grep` the claim rested
   on — "no `FencedCommitPermit` reference in that module" — measured the absence of *one*
   mechanism and concluded the absence of *any*. It is a legitimately post-authorized agent action.
2. **It is not production-reachable.** `executeVerifiedTargetIntent` has zero callers in `src/` or
   `app/`. Its only caller is `test/unit/ControlPlaneTargetSecretAgentExecution.hs`, and that suite
   is compiled but **not registered** in `test/unit/Main.hs`, so it never runs.
3. **The recorded fix does not compile.** Making `decideTargetSinkWrite` the sole source of a
   `TargetSinkCasRequest` would force that module to mint a `PreparedTargetWritePermit`, which needs
   a `FencedCommitPermit`, a `RegisteredTargetSet` and a `ModelBObservation TargetIntentProjection`
   — none of which it has, and none of which doctrine permits the Agent to hold. The export edit
   breaks the build rather than redirecting the caller.
4. **The class was wrong.** § 21 row C is a permit *"carrying the token the store itself checks"*.
   Vault KV v2 receives only `{"data": …, "options": {"cas": N}}`; owner nonce, fencing token and
   generation are opaque data fields it never inspects. On `TargetSinkCasRequest` the achievable
   coordinate is **A (provenance)**, not C.

**What was actually closed.** The one value on this path Vault itself checks is the expected
version, and it was authorable from a string literal: `mkTargetSinkVersion` accepted any non-empty
text, while its single legitimate minter round-tripped the store's own counter through
`Text.pack . show`. That is the literal class-C surface, and it is now shut. `TargetSinkVersion`
moves to its own module, abstract to every consumer, with the constructor confined to
`Prodbox.Lifecycle.TargetSinkVersion.Internal` and one permitted importer — the target sink's Vault
observation decoder. An expected version is now evidence that a store read happened. The retype from
`Text` to the store's `Natural` also deletes a parse step and its refusal path from the write path,
and corrects the type's `Ord` instance from lexicographic to numeric.

**The remaining surface, honestly bounded.** The `TargetSinkCasRequest` and `TargetSinkRecord`
constructors stay public. That is a real class-A representability gap and it is recorded in the
cleanup ledger, but with the request protocol superseded (Sprint `4.59`) it has no live offender to
close. Per [§ 22](../documents/engineering/chaos_hardening_doctrine.md), none of this proves
at-most-one writer across processes: two holders of a validly-decoded version both produce legal
requests, and Vault's version compare only makes the loser fail after the winner lands. That residue
is ring-3 containment and is recorded `assumed`, not `proven`.

Deliberately **not** in this sprint: collapsing `ModelBCasRequest`'s guarded and unguarded
constructor pairs. That is the move that makes an unguarded authority CAS inexpressible, and it
touches every `ModelBCasAdapter` consumer — the coupled shape the Sprint `4.51` revert warns about.

## Sprint 4.59: Delete the Superseded In-Controller Target Agent Write Lane ✅

**Status**: Done (2026-08-08) — Phase `4` own-surface work on the target write path this phase
owns. Disposition decided by the operator; the sprint is the execution. **Implementation scope
corrected against source (Standard C): two clauses of the original list were false and are not
executed. See "Scope correction" below.**
**Implementation**: `src/Prodbox/ControlPlane/TargetSecretAgentExecution.hs` (removed
`TargetSecretAgentExecutionBoundary`, `mkTargetSecretAgentExecutionBoundary`,
`TrustedTargetSecretMaterialSource`, `TargetAgentTrustRepository`, `TargetSecretMaterial`,
`admitTargetCommittedIntent`, `executeVerifiedTargetIntent`, and their error/result types —
230 lines, keeping the module for the signed-intent vocabulary five production modules import),
`src/Prodbox/ControlPlane/TrustedTargetSink.hs` (the CAS half — `trustedTargetSinkAdapter`,
`trustedRequestParts`, `compareAndSwapVaultTargetSink`, `vaultExpectedVersion`, and the
`mkTrustedTargetSink` CAS parameter), `test/unit/ControlPlaneTargetSecretAgentExecution.hs`
(deleted), the three registered decommission suites that constructed a trusted sink,
`src/Prodbox/CheckCode.hs` (`retiredCitedSourcePaths`), and `prodbox.cabal`.
**Docs updated**: none. Verified by Sprint `0.27` (2026-08-12): no governed document under `documents/` names this sprint. This records a measurement — that no doc attributes text to this sprint — not a claim that no doctrine covers the behaviour it changed.

### Scope correction (2026-08-08)

Two clauses of the original Implementation line are false against source and were **not** executed:

- **`src/Prodbox/Lifecycle/TargetCommitInterpreter.hs` is not deletable.** It has two importers,
  both *registered* suites — `test/unit/RetainedSesTargetRecovery.hs` and
  `test/unit/TargetCommitSmtp.hs` — which Sprints `4.47`, `4.49`, and `5.17` cite as evidence.
  Deleting it would retire live coverage, and this plan's own
  [legacy ledger](legacy-tracking-for-deletion.md) already says so in as many words: *"The
  Authority-side call site survives Sprint `4.59`."* The sprint contradicted the ledger; the ledger
  was right.
- **The `TargetSinkCasAdapter` / `TargetSinkCasRequest` / `TargetSinkCasResult` vocabulary is not
  orphaned.** `decideTargetSinkWrite` mints requests at
  `src/Prodbox/Lifecycle/TargetCommitIntent.hs:896` and `:910`, and the adapter type is consumed by
  the two registered suites above. Only the *binding* through `trustedTargetSinkAdapter` was
  orphaned, and that is what was removed.

Also corrected: the module itself survives. The original line reads as though
`TargetSecretAgentExecution.hs` goes away entirely, but five production modules import its
signed-intent vocabulary (`Cluster/FederationRegistration.hs`,
`Lifecycle/CredentialProvisioner/PreparedTarget.hs`, `ControlPlane/TargetAuthorityTrust.hs`,
`ControlPlane/TargetIntentAuthority.hs`, and the worker runtime). Deleting the file was attempted
first and the compiler refused it — recorded here because the sprint text invited exactly that
mistake.
**Blocked by**: none.
**Deployment qualification**: pending — the deleted lane has zero production callers, so this is a
no-op at runtime.

### Objective

Two complete, mutually redundant write lanes exist against the same target Vault coordinate. Only
one is deployed. `TargetSecretWorker.applyCas` → `targetWorkerCompareAndSwap` (bound at
`src/Prodbox/ControlPlane/TargetSecretWorkerRuntime.hs`) is the live writer, already gated by a
required opaque `TargetWorkerAttestation`. The in-controller lane through
`executeVerifiedTargetIntent` has **zero callers in `src/` or `app/`**, and three further facts say
it is abandoned rather than pre-landed:

- The standing Target Secret Agent Vault policy (`src/Prodbox/Vault/Reconcile.hs`) grants only
  `secret/metadata/<logical>` read and delete, no `secret/data/<logical>` capability at all, so the
  lane would fail authorization today.
- Its unit suite is listed in `prodbox.cabal` `other-modules` but is **not registered** in
  `test/unit/Main.hs`, so it compiles and never runs — the same evidence-integrity class Sprint
  `4.54` corrected.
- The deployed one-shot Job topology matches the doctrine requirement that plaintext-bearing
  materialization run in a one-shot secret worker, which an in-controller lane would violate.

Keep `verifySignedTargetCommittedIntent` and the signed-intent vocabulary: the live worker verifies
the same envelope and depends on it.

### Validation (as run)

1. **Every deleted export has zero references after removal**, verified by name across `src/`,
   `app/`, and `test/`: `executeVerifiedTargetIntent`, `admitTargetCommittedIntent`,
   `mkTargetSecretAgentExecutionBoundary`, `TargetSecretAgentExecutionBoundary`,
   `TrustedTargetSecretMaterialSource`, `trustedTargetSinkAdapter`, and
   `compareAndSwapVaultTargetSink` all return 0.
2. **The live worker's write path and its attestation gate are untouched.**
   `TargetSecretWorker.applyCas` → `targetWorkerCompareAndSwap` and the required opaque
   `TargetWorkerAttestation` are unchanged in
   `src/Prodbox/ControlPlane/TargetSecretWorkerRuntime.hs`.
3. **The kept vocabulary is intact.** `verifySignedTargetCommittedIntent` and the signed-intent
   types the live worker depends on remain exported.
4. **The retired suite is registered as retired rather than silently forgotten.**
   `retiredCitedSourcePaths` names it and why — the governed-document harmony lint failed the build
   until it did, which is the gate working.
5. `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, and `prodbox test unit` exit 0 —
   3224/3224 plus the dedicated 27/27, 33/33, and 27/27 suites.

The predicted blast radius held: `mkTrustedTargetSink`'s CAS parameter is dropped in the three
registered decommission suites as well as the dead one. The production `TrustedTargetSink` survives
as observe-only and is still consumed by the decommission inventory boundary.

### Remaining Work

None on this sprint's surface. Two items are deliberately **not** closed here and are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than absorbed: the
`TargetSinkCasRequest`/`TargetSinkRecord` constructor exports (a Provenance-class row this sprint's
deletion does not resolve, because the Authority-side minter survives), and the discarded
target-sink CAS verdict at the surviving Authority call site.

Note separately, and **not** owned by this sprint: the production observe path reads
`secret/data/<logical>` while the role's policy grants only `secret/metadata/<logical>`, so the
decommission-inventory observe would fail authorization under that role as policied. It degrades to
an absorbing `TargetSinkUnobservable` rather than being mistaken for absence, so it is a
functionality gap that fails closed, not a safety defect. It was not verified live.

## Sprint 4.60: A Response Obligation for the Control-Plane Server ✅

**Status**: Done (2026-08-08) — Phase `4` own-surface reopen (Standard A) on the control-plane role
runtime this phase owns. The doctrine it implements is Sprint `0.25`.
**Implementation**: `src/Prodbox/Http/ResponseObligation.hs` (new),
`src/Prodbox/ControlPlane/Runtime.hs` (`serveControlPlaneConnection`,
`controlPlaneResponseObligation`; `sendAll` removed from scope),
`src/Prodbox/ControlPlane/ConfigClient.hs` (`ConfigClientHttpStatus` carries the bounded reason),
`src/Prodbox/CheckCode.hs` (`responseObligationViolations`, `checkResponseObligation`),
`test/integration/FixtureServer.hs`, `test/unit/ResponseObligationSuite.hs` (new),
`test/unit/ControlPlaneServer.hs`, `test/unit/Main.hs`, `prodbox.cabal`.
**Blocked by**: none.
**Deployment qualification**: pending — and this sprint moves **no** Standard-P surface. It adds no
process, thread, pool, deadline, or admission decision; it changes only *which bytes* an
already-accepted connection receives before the same `close`. Both rows are already `pending`, so
nothing is invalidated — but the next qualification run must exercise the post-change path.
**Independent Validation**: pure and socket-pair driven, no live cluster — a throwing interpreter
yields a complete `500` rather than a closed socket, and an async exception yields a `503` **and**
still escapes.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/integration_fixture_doctrine.md`.

### Objective

`runControlPlaneServer` discards the outcome of the connection handler:

```haskell
void $ forkFinally (serve role client) (const (close client))
```

`const` throws away the `Either SomeException ()`. Only a framing refusal replies; any throw from
the request read, the readiness resolver, or `interpreterHandle` closes the socket with zero bytes
and no `500`. On the wire that is indistinguishable from a network fault — the *Distinguishability*
class of [chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md)
committed at a conversion boundary, which is
[§ 23](../documents/engineering/chaos_hardening_doctrine.md).

The Bootstrap Broker already solved this — `invokeInterpreter` maps a synchronous interpreter
failure to `internalErrorReply` — so this sprint brings the control plane to a standard the Broker
has held since Sprint `2.33`. Note the asymmetry with Sprint `5.30`, which is why the two are
separate: the fixture's failure was *already* a typed value and the fix there is to stop discarding
it, whereas no type can stop an arbitrary `IO` exception escaping `interpreterHandle`, so here a
backstop is the right primary fix rather than a consolation.

### Deliverables

- **`Prodbox.Http.ResponseObligation`** — the only module in the governed set that may import
  `Network.Socket.ByteString`. `withResponseObligation`'s handler has type `IO reply`, not `IO ()`,
  so "handled the connection without answering" does not type-check, and at-most-once delivery is
  structural rather than guarded by a flag.
- **The fallback is a total function of a closed `ResponseRefusal`, not a constant reply.** That is
  what lets production and the fixture share one helper under different disclosure policies:
  production maps to `(500, "internal-error\n")` — it must not put `show e` on the wire, which is
  why the Broker redacts its reply body from `Show` — while the fixture may name the exception,
  because there the detail is the deliverable.
- **`SomeAsyncException` is answered on a bounded best-effort write and then re-raised unchanged.**
  Load-bearing, not tidiness: `System.Timeout.Timeout` is an async exception, so converting it to a
  `500` would send a reply *and* make `timeout` return `Just ()`, silently defeating any future
  per-request deadline.
- **Adoption in `src/Prodbox/ControlPlane/Runtime.hs`**, with the request read moved *inside* the
  obligation — that also closes the read-throws-first gap the Broker still has. Export
  `serveControlPlaneConnection` so the `500` path is testable over a socket pair; today `serve` is a
  `where`-closure under a `forever` loop on a hard-coded port.
- **A `dev check` negative-space rule**: raw `sendAll`/`send`, including via a qualified alias, is
  not in scope in a governed server, with a positive anchor on the helper's signature.

### One deliverable added during validation

`ConfigClientHttpStatus` carried only an `Int`. Running the suite after the server change turned the
symptom from `NoResponseDataReceived` into `ConfigClientHttpStatus 500` — better, because a `500` is
definitely a server-side answer rather than a network fault, but still naming nothing. **The client
was performing the last conversion in the chain**, discarding a body the server had just been taught
to fill. That is the same rule (§ 23: do not convert a typed failure into an untyped one) at the
same sprint's own seam, so it was fixed here rather than registered: the constructor now carries a
bounded reason.

### Validation (as run)

1. ✅ `prodbox-unit -p "Sprint 4.60"` — 12/12 (9 obligation cases over a socket pair, 3 end-to-end
   control-plane cases). A throwing handler yields a complete, length-consistent `500`; a bottom
   *inside the reply body* yields a `500`, proving the render happens inside the guarded region; a
   bottom in the refusal renderer falls back to `lastResortInternalError`; a peer that closed first
   does not throw.
2. ✅ **End to end through the real accept path**: a `RoleInterpreter` whose `interpreterHandle`
   throws produces `HTTP/1.1 500 Internal Server Error`, not a closed socket. A readiness cell that
   is bottom does the same. The framing-refusal `400` is unchanged.
3. ✅ **Mutation exercise M1** — re-adding `sendAll` to `Runtime.hs`'s import list fails `dev check`
   with the response-obligation message. Restored byte-exactly (`cmp` clean).
4. ✅ **Mutation exercise M2, the load-bearing one** — reordering the guards so an asynchronous
   exception is treated as an ordinary handler failure makes the enclosing `timeout` return
   `Just ()` instead of `Nothing`. That is the concrete proof that re-raising async exceptions is
   what keeps a future per-request deadline composable, rather than a stylistic preference.
   Restored byte-exactly.
5. ✅ **The original symptom, negated.** Against the still-drifted fixture the integration suite now
   reports `ConfigClientHttpStatus 500 "fixture handler failed: user error (Failed to decode Tier-0
   prodbox.dhall \`parameters\` … public_edge_advertisement_mode : - < … > (a union type) + Text)"` —
   the exact drifted field — where it previously reported `NoResponseDataReceived`. The twenty cases
   still fail, because the drift itself is Sprint `5.30`'s surface; what changed is that the failure
   now names its cause.
6. ✅ `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit 0,
   and `prodbox test unit` exit 0 — 3245/3245 plus the dedicated 27/27, 33/33 and 27/27 suites.

### Remaining Work

None on this sprint's surface. Four things are deliberately **not** in it and are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than folded in: the
unbounded accept loop and missing read deadline (which *would* touch Standard-P admission); the
closed reply-status ADT; gateway and Broker adoption; and the absent control-plane logger, which
means the production `500`'s structured reason survives only as the `500`/`503` distinction — a
partial honouring of `bootstrap_readiness_doctrine.md` § 0.5 named here rather than papered over.
Note the asymmetry that justifies it: the *fixture* may name the exception on the wire, and does; a
production role must not, so its reason needs a log rather than a body.

## Sprint 4.61: Admissions Are Threaded Across Phases, Not Reset At Each One ✅

**Status**: Done (2026-08-08) — Phase `4` own-surface reopen (Standard A) on the dependency-admission
mechanism Sprint `4.56` introduced. Surfaced by Phase `5`'s Sprint `5.31`, which made the refusal
speak; the defect it named is Phase `4`'s.
**Implementation**: `src/Prodbox/Lifecycle/AnchoredReconcile.hs` (`runAnchoredStepOrder` takes an
incoming `AdmissionSet` and returns the resulting one), `src/Prodbox/CLI/Rke2.hs`
(`runAnchoredReconcileSteps`; `applyNativeInstallPlan` threads bootstrap → transition → steady, and
the two interstitial `requireNativeComponentReadiness` observations record into the set instead of
being discarded), `src/Prodbox/Lib/AwsSubstratePlatform.hs` (the post-port-forward slice inherits
the pre-forward slice's admissions).
**Blocked by**: none.
**Deployment qualification**: pending — this is a lifecycle-orchestration surface, so Standard P
applies and both rows are already `pending`. It does not add a process, thread, pool, or deadline;
it changes which evidence a mutation is admitted on, in the direction of admitting mutations that
were previously refused outright.
**Independent Validation**: fake-host reconcile, no live substrate — the reconcile that previously
exited 1 at `chart_authority_backup` now proceeds through the gateway chart and daemon-full
readiness. `prodbox dev check` exit 0; `prodbox test unit` 3253/3253.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

`applyNativeInstallPlan` runs its phases as separate `runAnchoredStepOrder` calls, because each
phase has a different step action. Each call started its fold at `noAdmissions`. A component whose
`ComponentReadiness` step is anchored in an earlier phase than its dependant's `ComponentMutation`
step was therefore **refused unconditionally**, and the message said so in words that were true of
the phase and false of the run:

```text
mutating `chart_authority_backup` requires an admission for its declared
dependency `registry`, which was never observed ready in this run
```

`registry` *was* observed ready in that run — `StepVerifyRegistryMinioEdge` is
`ComponentReadiness ComponentRegistry` and is a `PhaseBootstrap` step, while
`StepAuthorityBackupChartReady` is `ComponentMutation ComponentChartAuthorityBackup` in
`PhaseTransition`. The evidence existed and the next phase could not see it.

This is not a variant of § 23's conversion; it is a scope error with the same effect. "This run" was
implemented as "this call", and nothing in the types said which one was meant.

### What Landed

- `runAnchoredStepOrder` takes the admissions carried in and returns the admissions carried out, so
  the caller decides what "this run" spans instead of the function assuming it.
- `applyNativeInstallPlan` threads the set through bootstrap → transition → steady, and the two
  readiness observations that sit *between* phases — `ComponentVaultUnsealed` after the Vault
  lifecycle transition, and `ComponentChartAuthorityBackup` before the steady phase — now record
  into the set rather than being discarded through `fromLeft ExitSuccess`. They were already being
  performed; only their evidence was being thrown away.
- `runAwsSubstratePlatformOrder`'s second slice inherits the first's. Those two calls exist only
  because the gateway port-forward has to be established between them, which is not a reason for the
  evidence to reset.
- Staleness is untouched and still does the work it was designed for: an admission that has aged
  past its bound across a phase boundary is **not** silently trusted — it expires, triggers
  re-observation of that one dependency, and is decided on the fresh evidence. Threading widens what
  counts as evidence; it does not widen how long evidence lasts.

### Validation

1. The fake-host `cluster reconcile --with-edge` that exited 1 at `chart_authority_backup` now
   proceeds through pulsar, the gateway chart, and daemon-full readiness — the refusal is gone and
   the next failure was a different, further-along one.
2. `prodbox dev check` exit 0 with `--enable-tests` in force; `prodbox test unit` 3253/3253.
3. 🧪 Live: a home `cluster reconcile` is the Standard-O proof. Note what the code-local evidence
   does and does not establish — it shows the cross-phase refusal is gone on the fake-host path. It
   does not establish that a live reconcile ever reached this refusal, because no live reconcile has
   been run since Sprint `4.56` landed the admission requirement.

### Remaining Work

**A gate is owed and is deliberately not claimed.** Nothing yet prevents a future phase split from
reintroducing the reset — the threading is correct but not enforced, and `noAdmissions` is still
constructible at any call site. The honest options are a `dev check` rule holding that
`noAdmissions` appears exactly once per reconcile surface, or a type that distinguishes "the run's
admissions" from "an empty set". Registered here rather than asserted as done.

## Sprint 4.62: A Refused Sink CAS Is Not a Read-Back Question ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the target-commit persistence path.
**Implementation**: `src/Prodbox/Lifecycle/TargetCommitInterpreter.hs` (the discarded
`targetSinkCompareAndSwap` verdict is bound and decided; new `TargetCommitSinkCasRefused`),
`test/unit/TargetCommitSmtp.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — **this one does move a Standard-P surface**. It changes the
persistence protocol: a target-secret commit that the sink store explicitly refused is no longer
recorded as committed. Both substrate rows are already `pending`, so nothing is invalidated, but the
next qualification run must exercise the post-`4.62` commit path, in which a refused CAS surfaces as
`TargetCommitSinkCasRefused` instead of being absorbed by the following read-back.
**Independent Validation**: pure, no live infrastructure — a named `-p` filter with an exact count,
plus a mutation exercise that reproduces the pre-fix outcome and restores byte-exactly.
**Docs to update**: none — no governed document described the discarded verdict, which is part of why
it survived.

### Objective

`runPreparedTargetCommit` bound the target sink store's answer with `_ <-`. The adapter distinguishes
four outcomes — `TargetSinkCasApplied`, `TargetSinkCasConflict`, `TargetSinkCasRefused`,
`TargetSinkCasUnobservable` — and every one of them was dropped, so correctness rested entirely on the
read-back that follows. That is the *Distinguishability* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md).

**The deletion ledger recorded this as a hygiene defect. It is not.** The mutation exercise below
shows the pre-fix interpreter returning
`TargetCommitRunCommitted { targetCommitRunSinkCasAttempted = True }` for a write the store said it
did **not** perform — a false commit record for a target secret, produced whenever the sink happens to
hold the expected bytes for any other reason.

### Deliverables

- ✅ The verdict is bound and matched exhaustively, so a fifth outcome would be a compile error rather
  than a silent fifth thing that is also ignored.
- ✅ `TargetSinkCasRefused` becomes `TargetCommitSinkCasRefused`, a distinct error from
  `TargetCommitSinkReadbackFailed`. The distinction is the point: one is what the sink **said at the
  time**, the other is what the sink **looks like afterwards**, and collapsing them is how a refusal
  became a success.
- ✅ `Applied`, `Conflict`, and `Unobservable` continue through the authoritative read-back, decided
  explicitly rather than by falling through. `Unobservable` in particular **must** stay on the
  read-back path — it is the applied-but-response-lost case, and treating it as a refusal would
  reintroduce the "unobservable ≠ absent" defect Sprints `4.53` and `5.29` closed elsewhere.
- ✅ **A stale location claim in the ledger row is corrected against source** (Standard C). The row
  named two call sites — `TargetCommitInterpreter.hs` and
  `ControlPlane/TargetSecretAgentExecution.hs`. The second has **zero** occurrences of
  `targetSinkCompareAndSwap` or `TargetSinkCas` today: Sprint `4.59` deleted the lane it sat on. The
  row was written before that deletion and was never re-measured.

### Validation

1. ✅ The mutation exercise: with the fix reverted to `_ <-`, the new case fails with
   `expected: Left (TargetCommitSinkCasRefused …)` / `but got: Right (TargetCommitRunCommitted
   {…, targetCommitRunSinkCasAttempted = True})`. The fixture deliberately leaves the sink observation
   exactly as a successful write would leave it, so the read-back *would* have confirmed — which is
   what makes the old behaviour reachable rather than theoretical. Source restored byte-exactly
   (`sha256sum -c`: `OK`).
2. ✅ `prodbox-unit -p "Sprint 4.62"` — 1/1, also asserting that no read-back observation follows the
   refused CAS, so the refusal happens at the verdict rather than after another round trip.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 with main Hspec **3267/3267** plus
   27/27, 33/33, and 27/27 on the dedicated suites; `prodbox dev docs check` and
   `prodbox dev lint docs` exit 0; installed `prodbox test integration cli` **55/55**, exit 0. The
   installed run matters here rather than being a formality: this sprint edits a production
   interpreter on the target-commit path, so a suite that drives the installed binary is the
   regression gate for it.

### Remaining Work

One co-defect of the same shape is **registered rather than absorbed**: the neighbouring
`modelBCompareAndSwap` verdict on the global target-intent ledger is discarded the same way, at
`src/Prodbox/Lifecycle/TargetCommitInterpreter.hs`. It was found while reading this call path and is
not this sprint's stated deliverable; it is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) with its own analysis owed, because
the global ledger's guarded-CAS semantics are not the sink's and the right disposition per arm has to
be decided rather than copied.

## Sprint 4.63: The Global Ledger's CAS Verdict Is Decided, Not Discarded ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the target-commit persistence path.
**Implementation**: `src/Prodbox/Lifecycle/TargetCommitInterpreter.hs` (new `GlobalLedgerStep`,
`globalLedgerCasRefusal`, and `TargetCommitGlobalCasRefused`; four `_ <-` bindings replaced),
`test/unit/TargetCommitSmtp.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — this moves a Standard-P surface (persistence protocol). A
target-intent completion the global ledger refused is no longer recorded as committed, so *when a
commit counts as a commit* changes on the global lane as it did on the sink lane in Sprint `4.62`.
**Independent Validation**: pure, no live infrastructure — a named `-p` filter with an exact count
plus a mutation exercise that reproduces the pre-fix outcome and restores byte-exactly
(`sha256sum -c`: `OK`).
**Docs to update**: none — no governed document described the discarded verdict.

### Objective

Sprint `4.62` closed the discarded *sink* CAS verdict and **registered the global one rather than
absorbing it**, because the global ledger's guard semantics are not the sink's. This is that
analysis, done.

### Deliverables

- ✅ **The row's own location claim was corrected by measurement (Standard C).** It named
  `modelBCompareAndSwap` bound with `_ <-` as one site. There are **four**:
  `TargetCommitInterpreter.hs` prepare, complete, compaction, and recovery-resolve. It also said the
  result type "answers `ModelBCasApplied` / `ModelBCasUnobservable`"; `ModelBCasResult` has **five**
  constructors, and the two the row omitted include the only one that matters here.
- ✅ **The disposition is decided per arm rather than copied from `4.62`, and the answer differs.**
  `globalLedgerCasRefusal` is total over all five arms. `ModelBCasRefusedCorrupt` refuses; the other
  four continue to the authoritative re-observation the caller already performs. The reason is
  measured rather than assumed: **every producer of `ModelBCasRefusedCorrupt` in the repository
  refuses *before* reaching the object store** — an encode failure
  (`ModelBCasTransport.hs:122`), a non-registered coordinate, an unsupported guarded arm, or an
  Authority projection refusal (`RetainedSesLeaseClient.hs:137`–`:175`). It is the one answer that
  states no write was performed.
- ✅ **`ModelBCasUnobservable` deliberately stays on the read-back path.** It is the
  applied-but-response-lost case; routing it to a refusal would reintroduce the "unobservable is not
  absent" defect Sprints `4.53`, `4.62`, and `5.29` closed elsewhere.
- ✅ The refusal carries `GlobalLedgerStep`, because the same store text means four different things
  at prepare, complete, compaction, and recovery-resolve, and the constructor is the only place that
  distinction survives.
- ✅ **A second defect was found at the compaction site and is fixed by the same change.**
  `compactAllTerminalIntents` consumed one retry from `registeredTargetCapacity` per refusal and then
  reported `TargetCommitCompactionOverBound` — *a capacity bound named as the cause of a refusal*,
  reachable in the ordinary write-denied/read-allowed state where every observation succeeds and
  every write is refused.

### Validation

1. ✅ The mutation exercise, on the arm where discarding could invert the outcome: with the
   completion-arm decision reverted, the new case fails with
   `expected: Left (TargetCommitGlobalCasRefused GlobalLedgerComplete …)` /
   `but got: Right (TargetCommitRunCommitted {…})`. The fixture leaves the ledger exactly as a
   successful completion would, so the read-back *would* have confirmed — which is what makes the old
   behaviour reachable rather than theoretical. Source restored byte-exactly (`sha256sum -c`: `OK`).
2. ✅ `prodbox-unit -p "Sprint 4.63"` — 1/1, also asserting that no confirming observation follows the
   refused completion, so the refusal happens at the verdict rather than after another round trip.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0.

### Remaining Work

None.

## Sprint 4.64: An Admission Reset Is Not Nameable ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the reconcile executor.
**Implementation**: `src/Prodbox/Lifecycle/DependencyAdmission/Internal.hs` (`AdmissionSet` and
`noAdmissions` relocated), `src/Prodbox/Lifecycle/DependencyAdmission.hs` (export removed),
`src/Prodbox/Lifecycle/AnchoredReconcile.hs` (`runFirstAnchoredStepOrder`),
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`,
`src/Prodbox/CheckCode.hs` (allowlist entry), `test/unit/DependencyAdmissionSuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. No process, deadline,
envelope, or admission *decision* changes: the same admissions are threaded through the same phases
in the same order. What changes is which values a call site can name.
**Independent Validation**: pure — a compile-failure mutation exercise plus two named unit cases.
**Docs to update**: none.

### Objective

Sprint `4.61` fixed the admission reset by hand and left the threading correct **by convention**.
`noAdmissions` was exported, so any phase call site could pass an empty set and silently discard
everything the run had observed — the exact defect `4.61` had just removed, one edit away.

### Deliverables

- ✅ `AdmissionSet` and `noAdmissions` move to `Prodbox.Lifecycle.DependencyAdmission.Internal`;
  `noAdmissions` leaves the public export list. The type stays exported abstractly.
- ✅ `runFirstAnchoredStepOrder` is the sole entry point that starts empty. Every later phase must be
  handed a value **only an earlier phase could have returned**.
- ✅ The reconcile executor is added to the *already existing*
  `dependencyAdmissionInternalSourceViolations` allowlist rather than a new lint being written, so
  reaching around the removed export fails the build. Test modules import `Internal` deliberately —
  a suite must be able to construct the empty case to assert what it refuses — and the rule is scoped
  to `src/`, which is what makes that legal.
- ✅ The first-phase runners answer `Either ExitCode AdmissionSet` rather than the pair the later
  phases use. That is the point rather than an inconsistency: the pair shape would have forced these
  functions to name an empty set on the failure arm, reintroducing the value the sprint removes.

### Validation

1. ✅ Mutation exercise: adding `noAdmissions` to `Rke2.hs`'s import list fails the build —
   *Module 'Prodbox.Lifecycle.DependencyAdmission' does not export 'noAdmissions'*. Source restored.
2. ✅ `prodbox-unit -p "Sprint 4.64"` — 2/2. One asserts the allowlist admits the executor and refuses
   **both** reconcile surfaces; the other asserts a first phase returns a *non-empty* set, which is
   precisely the value `4.61`'s defect discarded.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0.

### Remaining Work

**The bound is stated rather than implied.** This makes an accidental reset a compile error and a
deliberate one a loudly-named function call. It does **not** prevent a surface from invoking
`runFirstAnchoredStepOrder` twice; what it removes is the innocuous-looking way to do it. The
`ReconcileRun` state-threading refactor that would close that too is not folded in.

One latent trap found while measuring and **registered rather than absorbed**:
`src/Prodbox/Lib/AwsSubstratePlatform.hs` drops the final slice's returned `AdmissionSet` with
`fst <$>`. That is correct today because it is the last slice, and becomes the same defect the moment
a third slice is added.

## Sprint 4.65: A Refusal Retains Its Reason ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the control-plane response path.
**Implementation**: `src/Prodbox/Http/ResponseObligation.hs` (required `obligationObserveRefusal`,
`renderResponseRefusalReason`, `responseObserveBudgetMicrosDefault`),
`src/Prodbox/ControlPlane/Runtime.hs`, `test/integration/FixtureServer.hs`,
`test/unit/ResponseObligationSuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. No process, capability,
deadline, envelope, or admission decision changes, and **no wire byte changes** — the reply is
identical; what is added is a write to the process's own stderr.
**Independent Validation**: pure — three named unit cases plus a mutation exercise.
**Docs to update**: none. `bootstrap_readiness_doctrine.md` § 0.5 already states the requirement this
implements; it needed satisfying, not amending.

### Objective

Sprint `4.60` made the reply obligatory and left the *reason* nowhere. Production must not put an
exception's text on the wire, so after `4.60` a `500` was the entire surviving record of any handler
failure — a refusal that does not retain its structured reason, which
[bootstrap_readiness_doctrine.md § 0.5](../documents/engineering/bootstrap_readiness_doctrine.md)
forbids.

### Deliverables

- ✅ **Two halves of the ledger row's evidence were false and are corrected against source
  (Standard C).** The row said the fix was to add a `Prodbox.Logging` import and an
  `hPutStrLn stderr`. `Prodbox.Logging` **has never existed** — the module is
  `Prodbox.Gateway.Logging` — and `hPutStrLn stderr` is **forbidden** in every `src/Prodbox/**.hs`
  by `checkErrorBoundaryViolations`, which exempts exactly three paths. Following the row as written
  would have failed the build.
- ✅ **The row was also filed against the wrong file.** `Runtime.hs` never sees the exception: the
  only seam that does is `obligationRefusal`, a **pure** field of `ResponseObligation`. The fix
  therefore lives in the helper, not the server.
- ✅ `obligationObserveRefusal` is a **positional** parameter of `mkResponseObligation`, not a record
  field with a default. A default would have made observation opt-in, and the defect is precisely
  that nobody opted in. It is the same required-argument move the module already makes for the
  refusal renderer.
- ✅ The observer runs inside its own `try` **and** its own `timeout`, both load-bearing: `4.60`'s
  guarantee is that nothing on the refusal path prevents the reply, and an observer is caller-supplied
  code that may throw or block. Cancellation is re-raised so an enclosing deadline still fires.
- ✅ `renderResponseRefusalReason` bounds the reason at 512 characters, because an exception's
  rendering can quote its input and an unbounded reason is an unbounded write to the log stream from
  the request path.
- ✅ The integration fixture server observes too. A fixture passing a no-op would be the
  counterexample to the required argument.

### Validation

1. ✅ Mutation exercise: with the observer invocation removed, `Sprint 4.65: a refusal is observed with
   its structured reason` fails `expected: 1 / but got: 0`. Source restored byte-exactly
   (`sha256sum -c`: `OK`).
2. ✅ `prodbox-unit -p "Sprint 4.65"` — 3/3: the reason is recorded and the **wire still does not
   carry it**; a throwing observer costs the reason and not the reply; the reason is bounded.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0.

### Remaining Work

**One residual is recorded rather than solved.** Truncation is not sanitisation: no mechanism here
proves an exception's text carries no secret byte. What bounds the exposure is the destination — the
process's own stderr, never a reply — and that is an argument, not a proof.

## Sprint 4.66: The Wire Stops Saying "Status" ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the control-plane transport.
**Implementation**: `src/Prodbox/Http/ReplyStatus.hs` (new), `src/Prodbox/ControlPlane/Server.hs`,
`src/Prodbox/CheckCode.hs` (`checkControlPlaneReplyStatusCoverage`), `prodbox.cabal`,
`test/unit/ControlPlaneServer.hs`.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. No status code changes —
a `403` is still a `403`. What changes is the reason phrase beside it, from the literal `Status` to
`Forbidden`. No process, capability, deadline, envelope, admission, persistence, or routing decision
moves.
**Independent Validation**: pure — three named unit cases plus a repository-wide mutation exercise
run through the installed gate.
**Docs to update**: none.

### Objective

`httpReasonPhrase` mapped six codes and ended `_ -> "Status"`, while the interpreters emit ten. This
was **live, not latent**: the control plane was writing `HTTP/1.1 403 Status` on the wire.

### Deliverables

- ✅ **Three counts in the ledger row are wrong and are corrected by measurement (Standard C).** The
  row said the unmapped emitted set is `{401, 403}`; it is **`{401, 403, 408, 410}`** — the row misses
  the `408` at `AuthenticatedRoleInterpreter.hs:191` and the `410` at `CleanupRunEndpoint.hs:269`. It
  said nine interpreter sites; the measured count is **17** across 11 files. It said 47 literals and
  17 type sites; the measured producer census is **338** literals and **75** type sites across 37
  files.
- ✅ `Prodbox.Http.ReplyStatus` holds the closed set. `replyStatusCode` and `replyStatusReason` are
  total with no wildcard arm, so adding a constructor is a `-Werror` error at each.
  `replyStatusFromCode` is **derived from** `replyStatusCode` rather than hand-written, so the two
  cannot drift — a second table is exactly the restatement that produced this defect.
- ✅ `checkControlPlaneReplyStatusCoverage` fails the build when a producer under
  `src/Prodbox/ControlPlane/` emits a code the closed set does not define, which is what makes the
  `Unmapped Status` arm unreachable on the governed namespace.

### Validation

1. ✅ **Repository-wide mutation exercise.** Deleting `ReplyForbidden` from the closed set makes
   `prodbox dev check` fail naming **11 real production files**, one per `403` producer — so the gate
   is coupled to the type and to the actual namespace, not to a fixture. Source restored byte-exactly
   (`sha256sum -c`: `OK`).
2. ✅ **The gate's own first run found two false positives, and both are recorded rather than quietly
   patched.** `CallerPrincipal` encodes caller identities as `100`–`103` through the same `-> NNN`
   shape a status projection uses — so shape alone does *not* discriminate, and the exemption is by
   path and named. `LocalClient.hs` binds `(127, 0, 0, 1)`, which matched the reply-tuple shape and
   was reported as "HTTP status 127"; the matcher now requires the body after the comma not to begin
   with a digit, at the cost of a **stated false negative**.
3. ✅ **An existing unit case's name was true and its body was not**, and it is corrected rather than
   extended: `maps every emitted status code to a reason phrase` listed six codes while ten are
   emitted, so the four it omitted were exactly the four that reached the wire unnamed. The list is
   now derived from the closed type.
4. ✅ `prodbox-unit -p "Sprint 4.66"` — 2/2; `prodbox dev check` exit 0; `prodbox test unit` exit 0.

### Remaining Work

**The row's own prescription is not fully executed, and that is stated rather than rounded off.** It
asks for a closed reply-status ADT **at the producer**; what landed is the closed set plus a
transport that cannot render outside it plus a drift gate. The producers still answer a raw `Int` —
`interpreterHandle`'s reply type is `(Int, ByteString)` and 51 status projections answer `Int`. The
338-literal producer migration is **registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) and remains open**; the row is not
closed by this sprint, it is narrowed.

## Sprint 4.67: A Status Is a Value at the Producer ✅

**Status**: Done (2026-08-09) — Phase `4` own-surface work on the control-plane reply seam.
**Implementation**: `src/Prodbox/ControlPlane/Server.hs`, `src/Prodbox/ControlPlane/Runtime.hs`,
`src/Prodbox/ControlPlane/AuthenticatedRoleInterpreter.hs`,
`src/Prodbox/ControlPlane/RequestReplay.hs`,
`src/Prodbox/ControlPlane/TlsRetentionAuthorityClient.hs`, 29 further endpoint modules under
`src/Prodbox/ControlPlane/`, five under `src/Prodbox/Lifecycle/Decommission/`,
`src/Prodbox/Http/ReplyStatus.hs`, `src/Prodbox/CheckCode.hs`, and the unit/transport suites.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. Every status keeps the
number it had; a `409` is still a `409`, byte for byte on the wire, and the retained replay
projection's encoding is unchanged. What moves is the type a producer states it in. No process,
capability, deadline, queue, envelope, admission, persistence, or routing decision changes.
**Independent Validation**: pure — the closed type plus two named unit cases, one of which derives
its expectation from both projections of every constructor rather than from a sample.
**Docs to update**: none.

### Objective

Sprint `4.66` closed the set at the **renderer** and left every producer answering a raw `Int`,
which is why a `dev check` text rule had to stand in for a type. Close it at the producer.

### Deliverables

- ✅ **The row's count was right for the namespace it named and wrong for the repository.** It said
  51 status projections under `src/Prodbox/ControlPlane/`; measured, that is exactly 51. But five
  more live under `src/Prodbox/Lifecycle/Decommission/` — `authorityDecommissionExportHttpStatus`,
  `authorityDecommissionStopHttpStatus`, `targetGenerationTombstoneHttpStatus`,
  `targetDecommissionInventoryHttpStatus`, `retainedCustodyTombstoneHttpStatus` — and they are
  reached from `RoleInterpreters.hs` like any other. The migrated total is **56 projections across
  34 files**. A namespace-scoped census measured a namespace, not a surface.
- ✅ `interpreterHandle`, `serveControlPlaneRequest`, `renderHttpResponse`,
  `AuthenticatedRoleHandler`, and every reply tuple answer `ReplyStatus`. `httpReasonPhrase` is
  deleted rather than kept as a compatibility projection: with no producer holding an `Int`, the
  only thing it could still serve is a new untyped seam.
- ✅ **A second copy of a server's status table was found and deleted, not merely retyped.**
  `TlsRetentionAuthorityClient` carried a verbatim seven-arm restatement of
  `tlsAuthorityResponseHttpStatus` in a `where` clause, so the client's idea of the expected status
  and the server's were two values that a change to one would have made disagree
  ([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)). The
  client now projects the server's own answer.
- ✅ **The durable replay projection admitted any code between 100 and 599.** `mkReplayResponse`
  range-tested an `Int`, which accepted every status the repository does not define — including all
  four Sprint `4.66` found reaching the wire unnamed. The live constructor now takes a
  `ReplyStatus`; the numeric admission moves to `mkReplayResponseFromStoredCode`, the one crossing
  that legitimately receives a number, where an undefined code is a **decode refusal** rather than a
  value that flows on. The stored bytes are unchanged, so a projection written by an earlier
  revision still decodes.
- ✅ **Two crossings deliberately keep an `Int`, and both are stated rather than left as residue.**
  A peer's status (`ControlPlaneResponse`) is a byte off the wire that no type here bounds — turning
  a proxy's `502` into a decode failure would name nothing — and the stored status above. Per
  [§ 22](../documents/engineering/chaos_hardening_doctrine.md), a ring-2 gate bounds a process, not
  a protocol.
- ✅ **The `dev check` rule is repurposed rather than retired.** Sprint `4.66`'s form admitted a
  literal the closed set defined, because the producers held `Int`s and a text rule was the only
  gate available. It now fails on **any** status literal in a reply position under
  `src/Prodbox/ControlPlane/`, which is a job the type cannot do: stop a new `Int`-typed reply seam
  being opened beside the typed one. Both named exemptions survive unchanged —
  `CallerPrincipal`'s `100`–`103` tags and `LocalClient`'s `(127, 0, 0, 1)`.

### Validation

1. ✅ **The migration is proven by the compiler, not by review.** With `interpreterHandle` retyped,
   `-Werror` named every producer; the closing build is warning-clean across the library, the
   executable, and all eight test suites.
2. ✅ `Sprint 4.67: renderHttpResponse takes a status, not a number` compares the rendered status
   line against both projections of **every** constructor, so a new constructor is covered by
   construction rather than by someone remembering to extend a list — the exact failure mode that
   produced `HTTP/1.1 403 Status`.
3. ✅ `Sprint 4.67: a producer stating a status as a number fails the build` fixes the gate's new
   meaning in both directions: `(403, body)` is now a violation where `4.66` allowed it, `418`
   still is, and the migrated `(ReplyForbidden, body)` shape is clean.
4. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3276/3276** (the sprint
   adds 1 net) plus 27/27, 33/33, and 27/27 on the dedicated suites.

### Remaining Work

None on this sprint's surface. The
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) row moves to `Completed`.

## Sprint 4.68: The Accept Path Has a Bound and a Deadline ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the control-plane accept path.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`, `src/Prodbox/Http/ReplyStatus.hs`,
`src/Prodbox/CheckCode.hs` (`controlPlaneCapacityViolations`), `test/unit/ControlPlaneServer.hs`.
**Blocked by**: none.
**Deployment qualification**: **pending, and this sprint moves two Standard-P surfaces** —
queueing/admission and absolute-deadline composition
([development_plan_standards.md § P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure)).
In-process concurrency changes from *unbounded* to a compiled four, a request acquires an absolute
deadline it did not have, and two new statuses (`429`, `408`) can appear on the wire. Both ledger
rows were already `pending`, so no qualification claim is withdrawn — but this is the sprint a
re-qualification run must exercise.
**Independent Validation**: pure plus socket-pair — the plan is proven by a build gate and a unit
case, and both new replies are driven end to end over a socket pair with no listener, no port, and
no live infrastructure.
**Docs to update**: none.

### Objective

`runControlPlaneServer` was `forever { accept; forkFinally }`: a thread per accepted connection,
nothing counting them, and no deadline on either the request read or the interpreter. A stalled peer
held a thread indefinitely and arrival rate alone decided concurrency.

### Deliverables

- ✅ **The admission machine already existed and had no production consumer.**
  `Prodbox.ControlPlane.Capacity` has held an opaque `ServiceCapacityPlan` and a pure decide/evolve
  `AdmissionQueue` — with saturation, deadline-feasibility, and a retry hint — since Sprint `1.62`,
  reachable from `TestValidation.hs` and from nothing on this path. This sprint makes it
  load-bearing rather than writing a second one. That is the same shape Sprint `1.82` closed for the
  Tier-0 secret guard: a mechanism documented as enforcing something, enforcing nothing.
- ✅ **The kernel backlog is not the bound, and the distinction is the finding.** `listen … 32`
  bounds *pending* connections and was easy to read as a bound on *accepted* ones. It is not: every
  connection the loop accepted became a thread immediately.
- ✅ Two bounds, deliberately redundant and in the same direction: the `TBQueue` is sized at the
  plan's queue capacity so over-admission is not representable in the carrier, while `admit` refuses
  at the lower rejection threshold and says **why**. A bug in the decision cannot unbound the memory.
- ✅ **The deadline is enforced inside the handler, not around the obligation, and that placement is
  the whole design.** A `timeout` wrapped outside delivers an asynchronous exception into
  `withResponseObligation`, which answers its *cancellation* refusal and re-raises — so the caller
  would read `503 shutting-down`, naming the wrong cause, and a worker writing `408` afterwards
  would be a second reply on one connection. Inside, expiry is an ordinary value and the peer gets
  exactly one reply that names what happened.
- ✅ **A refusal is answered through the same obligation as a served request**, not by a raw write —
  which is also why `Runtime.hs` still cannot import `sendAll` and the Sprint `4.60` lint still
  holds over it.
- ✅ `ReplyTooManyRequests` joins the closed set, because a producer now emits `429`.
- ✅ A `dev check` gate fails the build when `controlPlaneCapacityInputs` does not compile into a
  plan. The runtime answers `ExitFailure 1` on a `Left`, which is correct behaviour and a terrible
  way to discover an arithmetic property of four constants — the symptom would be a role Pod that
  starts and will not serve.

### Validation

1. ✅ **A defect was found by testing the path rather than by reasoning about it, and it is the one
   worth reading.** The `408` case failed with `Connection reset by peer`: `close` on a socket
   holding unread bytes sends **RST**, and an RST discards what was already written. The `429` and
   the `408` are exactly the two replies produced *without* reading the request, so both could be
   lost — Sprint `4.60`'s "accepted a connection and answered nothing", reappearing through the
   kernel instead of through a `const`. `drainBeforeRefusal` consumes the request through the
   ordinary bounded reader first, bounded in bytes by the framing limits and in time by 100 ms so a
   stalled peer cannot hold the accept thread.
2. ✅ **Mutation exercise on the build gate.** Setting `rawWorkerCount = 1` makes `prodbox dev check`
   exit 1 with `ServiceCapacityOverCommitted 2400000`. Source restored byte-exactly
   (`sha256sum -c`: `OK`).
3. ✅ Three named cases: the plan compiles with its utilization stated as a number (`600000` ppm
   against the `700000` ceiling) rather than as a passing constructor; a saturated path answers
   `429 Too Many Requests` and the unreachable-under-these-constants second arm answers `503`; an
   expired connection answers `408 Request Timeout` **and the interpreter is never invoked**.
4. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3279/3279** (the sprint
   adds 3) plus 27/27, 33/33, and 27/27.

### Remaining Work

**One number is authored rather than measured, and it is registered rather than glossed.**
`rawServiceTimeMicros = 300000` is the field
[resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md) calls
uncertified-until-first-profile, and no measured control-plane profile exists. What the plan buys
today is not a proven service rate: it is that concurrency, queue depth, and rejection threshold are
finite and stated in one place, where before they were unstated because there was no bound at all.
A measured profile for this lane is a Standard-O axis, tracked as a new
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) row rather than absorbed here.

## Sprint 4.69: A Reconcile Run Carries Its Admissions ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the AWS-substrate reconcile order.
**Implementation**: `src/Prodbox/Lib/AwsSubstratePlatform.hs` (`runReconcileSlices`),
`test/unit/DependencyAdmissionSuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. The same steps run in the
same order against the same admissions; what changes is that the carrier is threaded by a fold
instead of by hand. No process, capability, deadline, queue, envelope, persistence, or routing
decision changes.
**Independent Validation**: pure — three named cases drive the fold with recording slices, with no
graph, no cluster, and no AWS.
**Docs to update**: none.

### Objective

The final AWS-substrate slice discarded the `AdmissionSet` it returned with `fst <$>`. Sprint `4.64`
had made a slice that starts from *no* admissions unnameable; it did nothing about one that starts
from a *stale* set because an intervening slice's admissions were dropped.

### Deliverables

- ✅ **The defect was a call site, not a value, which is why the previous sprint's type could not
  see it.** `noAdmissions` being package-internal stops a phase being *given* an empty set; it says
  nothing about a phase being given a set that is real but out of date. Adding a third slice would
  have reintroduced Sprint `4.61`'s defect with no compile error and no lint.
- ✅ `runReconcileSlices` takes an opening slice and a list of continuing slices and threads the
  carrier between them. A continuing slice **is** a function of the carrier, so writing one that
  ignores it is now a deliberate act rather than the default; the run's final admissions are
  discarded in exactly one place, where the run ends and there is nothing left to hand them to.
- ✅ **The shape is deliberately asymmetric and that is stated rather than tidied away.** Only the
  opening slice may start from the executor's own empty set, so it is a separate argument rather
  than the head of a uniform list — a uniform list would need a starting `AdmissionSet` from
  somewhere, and the only honest source of an empty one is package-internal by construction
  (Sprint `4.64`).
- ✅ `runSlice` now answers the same `Either ExitCode AdmissionSet` the opening slice answers. The
  pair it used to answer is what made `fst <$>` expressible at all.

### Validation

1. ✅ Three named cases: three recording slices observe `[False, True, True]` — the first opens with
   nothing and each later one sees what its predecessor recorded, where the pre-fix shape produced
   `False` from the second slice onward; a failing continuing slice stops the run with its exit code
   and no later slice runs; a failing opening slice runs nothing at all.
2. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3282/3282** (the sprint
   adds 3) plus 27/27, 33/33, and 27/27.

### Remaining Work

None on this sprint's surface. The
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) row moves to `Completed`.

## Sprint 4.70: A Target-Sink Write Cannot Be Assembled From Raw Data ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the target-commit vocabulary.
**Implementation**: `src/Prodbox/Lifecycle/TargetCommitIntent.hs`,
`src/Prodbox/ControlPlane/TargetMaterialRecordCodec.hs`,
`src/Prodbox/ControlPlane/TrustedTargetSink.hs`,
`src/Prodbox/Lifecycle/Decommission/TargetTombstone.hs`, `src/Prodbox/CheckCode.hs`
(`targetSinkRecordMinterViolations`), and five unit modules.
**Blocked by**: none.
**Deployment qualification**: pending, and **no Standard-P surface moves**. No value that reaches a
store changes; what changes is which modules can construct one. The deleted code had zero callers.
**Independent Validation**: pure — the type carries the constructor bound, and two named cases fix
the lint's behaviour in both directions.
**Docs to update**: none.

### Objective

`TargetSinkCasRequest (..)` and `TargetSinkRecord (..)` were exported with their constructors, so a
CAS request — including the owner nonce and fencing token that make a write authoritative — was
constructible from raw data by any module. *Provenance* class,
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md).

### Deliverables

- ✅ **The request needed no `.Internal` module, because measurement showed it needed no
  constructors at all.** In `src/`, `TargetSinkInitialize`/`TargetSinkReplace` appear at exactly
  three sites: the definition and the two mints inside `decideTargetSinkWrite`. Every other use —
  all of them in test adapters — was the same three-way projection, so
  `targetSinkCasRequestSink` / `…ExpectedVersion` / `…Record` answer what a `case` used to and the
  constructors are simply unexported. An initialize projects to `Nothing`, not to version zero: the
  two are different facts and stay distinguishable.
- ✅ `TargetSinkRecord`'s constructor is unexported and its five accessors are not.
- ✅ **Two minters state different facts through one shape, and that is named rather than left
  implicit.** `recordForIntent` builds the record a committed intent **decided** to write;
  `targetSinkRecordFromStore` rebuilds what the store **says** it holds. No type separates them —
  the arguments are identical — so the second is bounded to the one durable decoder by a `dev check`
  rule, and [§ 22](../documents/engineering/chaos_hardening_doctrine.md) applies: that bounds this
  process, not the protocol. The bound is stated in the rule's own comment.
- ✅ **Narrowing the export surface exposed dead code that the `(..)` imports had been masking.**
  `TrustedTargetSink.hs` still imported `TargetSinkCasAdapter`, `TargetSinkCasRequest`,
  `TargetSinkCasResult`, `TargetSinkVersion`, `targetSinkVersionValue`, `KvV2Cas`,
  `vaultKvCasWriteV2`, `Control.Monad (void)`, `Data.Bifunctor (first)`, `Numeric.Natural`, and
  `Data.Map.Strict` — and carried `encodeVaultTargetRecord`, an unexported top-level binding with no
  caller. All of it is residue from Sprint `4.59`'s deletion of the CAS half of that module. It is
  deleted rather than annotated.
- ✅ `Decommission/TargetTombstone.hs` imported the constructor and used only
  `targetSinkRecordGeneration`; the import is narrowed to what it reads.

### Validation

1. ✅ **Mutation exercise on the wired gate.** Naming `targetSinkRecordFromStore` in
   `TrustedTargetSink.hs` makes `prodbox dev check` exit 1 with the rule's message; source restored
   and re-verified (`sha256sum -c`: `OK`).
2. ✅ Two named cases fix the rule in both directions: an unlisted `src/` module minting a record is
   a violation, and both allowlisted paths — the durable decoder and the definition site — are
   silent.
3. ✅ **The five test modules that built these values are migrated rather than exempted**, so the
   suite exercises the same projections production does.
4. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3284/3284** (the sprint
   adds 2) plus 27/27, 33/33, and 27/27.

### Remaining Work

None on this sprint's surface. Both
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rows — the constructor exports and
its 2026-08-08 correction — move to `Completed`.

## Sprint 4.71: There Is No Unconditional Vault Write ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the Vault KV write boundary.
**Implementation**: `src/Prodbox/Vault/Client.hs`, `src/Prodbox/Secret/VaultInventory.hs`,
`src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: **pending, and this sprint moves a Standard-P persistence-protocol
surface.** Four writes that previously always succeeded can now be refused by the store, and one is
create-only. Both qualification rows were already `pending`, so no claim is withdrawn — but a
re-qualification run must exercise the federation-register and gateway-continuity paths.
**Independent Validation**: pure — the deletion is enforced by the type (the function no longer
exists), and one named case fixes the version-threading in both arms with a recording fixture.
**Docs to update**: none.

### Objective

`vaultKvWriteV2` was exported beside the conditional `vaultKvCasWriteV2`, so any module holding a
`VaultSession` could overwrite a target secret path outright — one layer below every type-level gate
the target-commit path builds. *Cardinality* class,
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md).

### Deliverables

- ✅ **The function is deleted, not deprecated.** Once every caller supplies an expected version, an
  unconditional KV write is not expressible in this binary — which is a stronger statement than a
  lint, and it is why the audit the row described as "its own sprint" was worth doing rather than
  deferring again.
- ✅ **The audit found three real lost-update races, not five hygiene sites.** Each is a
  read-modify-write whose write could not observe that the value had changed underneath it:
  - `updateParentChildIndex` reads the federation child index, upserts one child, and wrote
    unconditionally. **Two concurrent registrations both read the same index and the second silently
    erased the first child** — and no downstream read-back would notice, because an index is
    perfectly well-formed with a child missing from it.
  - `runVaultSecretBootstrapWith` unions generated fields onto what it read, so a concurrent
    bootstrap's generated field could be discarded the same way. The read now answers a typed
    `VaultSecretObservation` carrying the version, because the old bare field map is precisely why
    the write that followed it *could* only be unconditional.
  - The two parent-held child objects — metadata and bootstrap credential — were blind overwrites.
    Registration may legitimately re-run, so these are read-then-CAS rather than create-only; what
    is refused is overwriting a value that changed since it was read, and silently replacing a
    bootstrap credential would strand the parent's custody of the previous one.
- ✅ **The gateway continuity admission marker becomes create-only (`cas = 0`), because its own
  contract already said so**: "once this marker exists, a missing object is recovery failure — not
  permission to recreate a genesis anchor." A latch that can be overwritten is not a latch. A second
  admission is now a refusal from the store rather than a silent clobber of the first.
- ✅ `0` is Vault's own create-if-absent, so an absent object and a present one are **one call with
  different evidence** rather than two code paths.

### Validation

1. ✅ `Sprint 4.71: a seed write is conditioned on the version it observed` drives both arms through
   a recording fixture and asserts the exact versions `[0, 9]`.
2. ✅ Three pre-existing bootstrap fixtures now assert the expected version inline, so the threading
   is checked by the cases that already covered those paths rather than only by a new one.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3285/3285** (the sprint
   adds 1) plus 27/27, 33/33, and 27/27.

### Remaining Work

**One limit is stated rather than claimed.** A Vault CAS conflict arrives as an HTTP error carrying
Vault's own message; this sprint does not classify it into a typed conflict distinct from a
transport failure. The callers therefore report "write failed" with the store's text, which is
honest but coarser than the `ModelBCas*` vocabulary the object-store path uses. Registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than absorbed, because
classifying it means parsing Vault's error surface and that is its own decision.

## Sprint 4.72: The Public A-Record Writer Holds an Owner ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the Provider Worker's DNS lane.
**Implementation**: `src/Prodbox/ControlPlane/ProviderProduction.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`, `test/unit/DnsOwnerAuthoritySuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. The written record is byte-identical — same zone, name, TTL,
and values through the same `changeResourceRecordSets` call — so no Standard-P surface moves. What
is added is an observe/read-back around it and two refusal paths that can now stop a write.
**Live-proof**: **pending.** The owner check, the coordinate, and every refusal arm are proven
locally; the read-back against live Route 53 is a Standard-O axis
([development_plan_standards.md § O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)).
**Independent Validation**: pure — the compiled authority and the total refusal projection are
driven by two named cases with no AWS.
**Docs to update**: none.

### Objective

`applyPublicARecord` called Route 53 directly and carried no owner value at all, so the supportable
claim about DNS ownership was narrower than it read.

### Deliverables

- ✅ **The row understated the gap, and the measurement is the finding.** It said `DnsOwnerAuthority`
  "says nothing about a caller that reaches Route 53 directly". Measured: before this sprint
  **`DnsRecordProgram` had no production caller anywhere** — `runDnsRecordProgram`,
  `EnsureDnsRecord`, and `DestroyDnsRecord` appear only in two unit suites. So the typed program
  bounded nothing that runs, which is the same shape Sprint `1.82` closed for the Tier-0 secret
  guard: a mechanism documented as enforcing something, with zero production call sites.
- ✅ The writer now runs `EnsureDnsRecord` against an exact coordinate through a Route 53-backed
  `DnsRecordBoundary`, so the mutation is preceded by an observation and followed by a read-back
  that must converge — neither of which the direct call had.
- ✅ **The coordinate's two non-request facts are observed, not asserted.** The AWS account comes
  from `sts get-caller-identity` — the account this process is actually acting in — and the
  ownership epoch from the retained Authority epoch the role already reads. Carrying either in the
  intent would let a request *claim* an account; observing them proves one, and it needs no change
  to the durable provider-intent wire format.
- ✅ The authority is `dnsOwnerAuthorityForProcess ProviderWorkerRuntime SubstrateAws`, whose table
  is written out pair by pair, so this role cannot name a second owner.
- ✅ `publicARecordProgramOutcome` is total over all nine `DnsProgramResult` arms. A refusal
  reaching this lane as a bare `Left` would lose which one occurred, and the two ownership arms are
  the entire reason for routing through the program.

### Validation

1. ✅ Two named cases: the production writer's compiled authority is `AwsLifecycleProviderDnsOwner`,
   and the outcome projection distinguishes both ownership refusals and a failed read-back from
   success.
2. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3287/3287** (the sprint
   adds 2) plus 27/27, 33/33, and 27/27.

### Remaining Work

**The SES DNS writer is re-scoped into its own row rather than forced into this one, and the reason
is measured rather than asserted.** `applySesDns` is not a second instance of the same rerouting:

- It writes **three record types** — TXT, CNAME, and MX — and `DnsRecordType` defines two. Adding
  them means value validation and owner/type rules for both, plus making `ownerAcceptsType`
  exhaustive so a new pair is a decision instead of a wildcard `False`.
- It writes **five records in one batched `changeResourceRecordSets`** with a single propagation
  wait. A coordinate is one name and one type, so the typed program turns that into five ensures
  and five sequential INSYNC waits on a live AWS path this repository cannot exercise locally —
  a live-behaviour change that would land unverified.
- Its desired values come from `ensureSesDnsInputs`, which may **create the SES identity** before
  the records are known. The program's ensure requires a conclusive initial observation, so this is
  a redesign of the SES DNS mutation rather than a rerouting of it.

Registered in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The original row
was therefore **narrowed, not closed**, and Phase `4` stayed Active on it until **Sprint `4.73`
below** closed it — answering all three obstacles rather than deferring them again, and finding a
fourth the list above had not considered: the lane needs its own DNS owner.

## Sprint 4.73: The SES DNS Writer Holds an Owner ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the Provider Worker's SES DNS lane.
**Implementation**: `src/Prodbox/Lifecycle/DnsRecord.hs`,
`src/Prodbox/Lifecycle/DnsRecord/Owner.hs`,
`src/Prodbox/Lifecycle/DnsRecord/Owner/Internal.hs`,
`src/Prodbox/Lifecycle/DnsRecord/Route53.hs` (new),
`src/Prodbox/ControlPlane/ProviderProduction.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`test/unit/DnsRecord.hs`, `test/unit/DnsOwnerAuthoritySuite.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. The five records written are byte-identical — same zone,
names, TTL, and values — and the propagation barrier below keeps the lane's wall-clock shape. What
is added is a per-coordinate observation before each write and a read-back after it, plus two
refusal paths that can now stop a write.
**Live-proof**: **pending.** The owner rules, the canonical value forms, and every refusal arm are
proven locally; the read-back against live Route 53 is a Standard-O axis
([development_plan_standards.md § O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)).
**Independent Validation**: pure — the owner/type matrix, the three SES coordinates, the canonical
CNAME/MX forms, and the total outcome projection are driven by five named cases with no AWS.
**Docs to update**: `system-components.md`.

### Objective

Close the last ledger row Phase `4` could close by code: `applySesDns` reached Route 53 through a
direct `changeResourceRecordSets` call and carried no owner value at all.

### Deliverables

- ✅ **All three obstacles Sprint `4.72` measured are answered rather than deferred again.**
  `DnsRecordType` gains `DnsRecordCname` and `DnsRecordMx`; the five lanes submit their changes in
  one burst and discharge propagation afterwards; and `ensureSesDnsInputs` still runs first, so the
  program's ensure always begins from a conclusive observation.
- ✅ `ownerAcceptsType` is **total over the whole 5 × 4 matrix**. The superseded body ended in a
  wildcard `False`, which was right for the pairs that existed and would have silently rejected
  every pair added afterwards — the rejection would have surfaced as an unconstructible coordinate
  rather than as a missing decision.
- ✅ **The row did not say the lane needs its own owner, and it does.** Reusing
  `AwsLifecycleProviderDnsOwner` would have made `dnsRecordLifecycleClass` assert `PerRun` about
  records that live in the operator's retained parent zone, and would have handed the public
  A-record writer TXT/CNAME/MX authority over the same zone. `AwsSesDnsOwner` is `LongLived` and
  accepts exactly `{TXT, CNAME, MX}`; the public A lane keeps `{A}`.
- ✅ The minter's range widens from one owner to a list, because **one process legitimately owns
  more than one DNS lane**. What did not widen is who may hold a lane: a caller now names the lane
  it wants and the table still decides, so `(GatewayRuntime, SubstrateHomeLocal, AwsSesDnsOwner)`
  is `Nothing`.
- ✅ **CNAME and MX values carry one canonical spelling** — lower case, exactly one trailing dot —
  built in `mkDnsRecordValue`. Route 53 echoes either spelling of the same name, so canonicalizing
  at the constructor is what lets the read-back stay exact equality; comparing at each use would
  let a correct record read as drift and provoke a rewrite. The bytes written are unchanged.
- ✅ **The propagation barrier preserves the batch's timing property.** A coordinate is one name
  and one type, so the program necessarily submits five changes. Awaiting each inline would spend
  five propagation windows in series where the batch spent one; `ensureSesDnsLanes` submits all
  five, then awaits. Deferring the wait does not weaken the read-back — `ListResourceRecordSets`
  answers from hosted-zone record data, which a change updates on acceptance, and the post-apply
  observation this repository already performed reads the same way.
- ✅ **One derivation feeds both the observation and the ensure.** `sesDnsRecordPlans` is the sole
  producer of the five names and values, and the record names have one definition each in
  `Prodbox.Lifecycle.DnsRecord` beside the coordinate constructors that consume them.
- ✅ `nativeDnsRecordType` / `nativeDnsRecordSet` **move to one shared module** rather than being
  copied. Two encoders for one typed value is the conversion defect
  [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) names;
  the public A-record boundary now uses the shared renderer too, so three copies became one.
- ✅ `sesDnsProgramOutcome` is total over all nine `DnsProgramResult` arms and names the coordinate
  in every refusal, because five lanes run in sequence and a bare `Left` would lose both which
  refusal occurred and which record provoked it.

### Validation

1. ✅ Five named cases: the exhaustive owner/type matrix stated as data, the three SES coordinates
   and their `LongLived` class, the cross-lane type refusals, the CNAME/MX canonical forms with
   their rejections, and the SES outcome projection naming its coordinate.
2. ✅ `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs`
   exit 0, `prodbox test unit` exit 0 at main Hspec **3294/3294** (the three sprints add 7) plus
   27/27, 33/33, and 27/27, and installed `prodbox test integration cli` **55/55**, exit 0.

### Remaining Work

None. The row moves to `Completed` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 4.74: A Vault CAS Says Which Of Three Facts It Established ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface work on the Vault compare-and-swap seam.
**Implementation**: `src/Prodbox/Vault/Client.hs`, `src/Prodbox/CheckCode.hs`,
`src/Prodbox/Secret/VaultInventory.hs`, `src/Prodbox/Vault/Reconcile.hs`,
`src/Prodbox/ControlPlane/RetainedAuthentication.hs`,
`src/Prodbox/ControlPlane/BootstrapCustodyEndpoint.hs`,
`src/Prodbox/ControlPlane/BootstrapHandoffEndpoint.hs`,
`src/Prodbox/ControlPlane/VaultServiceSessionJournal.hs`,
`src/Prodbox/ControlPlane/TargetSecretWorkerRuntime.hs`,
`src/Prodbox/ControlPlane/TargetAuthorityTrustEndpoint.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminExecutionVault.hs`,
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Gateway/Daemon.hs`, `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. This moves a **persistence-protocol** surface: four call
sites change which outcomes they treat as a lost race, and one changes what consumes a retry
budget. The qualification row was already `pending`, so no claim is withdrawn.
**Live-proof**: **pending.** The classification is proven against Vault's documented answers; the
live confirmation that a refused CAS carries the mismatch phrasing is a Standard-O axis.
**Independent Validation**: pure — the total classifier and the build rule are driven by two named
cases over fixed inputs, with no Vault.
**Docs to update**: none.

### Objective

Give the Vault CAS path the distinction the object-store path has had since `ModelBCasResult`: a
lost race, a refused request, and an attempt whose outcome is unknown are three different facts.

### Deliverables

- ✅ **The row understated itself twice, and both counts are corrected by measurement.** It named
  three files; the measured inventory is **eleven call sites across ten modules**. And it said the
  distinction was
  absent at the caller — measurement found **four callers already attempting it and all four wrong
  in the same way**: `HttpStatus 400 -> "conflict"` plus a `409` arm Vault never produces for a KV
  CAS.
- ✅ **The consequence was worse than "coarse reporting" in two places, and this is the finding.**
  Vault answers a version mismatch and a malformed or cas-required request with the same `400`. So
  `reconcileRetainedAuthorityEpoch` spent an authority-epoch CAS retry on a request Vault had
  refused and then reported it as a lost race; and `vaultRequestReplayRepository` answered
  `RequestReplayCasConflict` — "another writer already claimed this request id" — for a write that
  never happened. That is a replay-protection decision made on a premise that did not occur.
- ✅ `VaultCasOutcome` names the four outcomes, and `classifyVaultCasOutcome` is the one total
  reading of a CAS result. **Only the version-mismatch body is a conflict**; `5xx`, `429`, and
  every transport failure are `Unobservable` rather than refusals, because a write that may have
  applied and whose response was lost is the one case that must not collapse into "nothing
  happened".
- ✅ Every call site consumes it, and `VaultSecretBootstrapOps` carries the outcome instead of a
  bare `HttpError`, so the bootstrap fold's caller learns which fact occurred.
- ✅ A `prodbox dev check` rule fails the build for any `src/Prodbox/**.hs` that names
  `vaultKvCasWriteV2` without naming `classifyVaultCasOutcome`.
- ✅ **The rule found an eleventh call site on its first run, and that is the argument for having
  written it.** `retainedCustodyVaultBoundary` in
  `src/Prodbox/ControlPlane/RetainedMaterialWorkerVault.hs` reaches the CAS through a module-local
  session wrapper, so it did not appear in a grep for the call shape the other ten share — the
  measured inventory is therefore **eleven sites**, not the ten found by reading, and not the three
  the row named. Its consumer, `applyCas` in `Prodbox.ControlPlane.RetainedMaterialWorker`, recovers
  by authoritative read-back on every failure, which is the right response to all three arms, so
  what changed there is what the failure *says* rather than what it does.
- ✅ **The guarantee is stated as what it is.** The transport result stays `Either HttpError` so the
  Vault session wrapper can still see a `403` for its single relogin, so nothing in the type forces
  classification; the build rule supplies that force over the compiled source region instead. Per
  [chaos_hardening_doctrine.md § 22](../documents/engineering/chaos_hardening_doctrine.md) that
  bounds this repository's source, not the Vault protocol. Retyping the primitive across eleven
  critical-path sites was considered and declined: it is the coupled-big-bang shape that required
  reverting Sprint `4.51`.

### Validation

1. ✅ Two named cases: the classifier over applied, mismatch-`400`, non-mismatch-`400`, `403`,
   timeout, `500`, and the dead `409`; and the build rule firing on an unclassified call site,
   passing on a classified one, and exempting the classifier's own module.
2. ✅ `prodbox dev check` exit 0, which also reports zero violations of the new rule over a tree
   that would have produced eleven before this sprint. **The rule's first run was not vacuous**: it
   failed the build on `RetainedMaterialWorkerVault.hs`, the site reading found no path to, which is
   the evidence that it bounds something. Full gate set: `dev docs check` and `dev lint docs` exit 0,
   `prodbox test unit` exit 0 at main Hspec **3294/3294** plus 27/27, 33/33, and 27/27, and installed
   `prodbox test integration cli` **55/55**, exit 0.

### Remaining Work

None. The row moves to `Completed` in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 4.75: Name the Authored Control-Plane Service Time As Authored ✅

**Status**: Done (2026-08-10) — Phase `4` own-surface correction; the row it owns stays
`Pending Removal` as a Standard-O recorder axis.
**Implementation**: `src/Prodbox/ControlPlane/Capacity.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`.
**Blocked by**: none.
**Deployment qualification**: pending; unchanged — this sprint moves no executable behaviour.
**Live-proof**: **pending**, and it is the whole of the remaining work. Certifying the constant
needs a recorded control-plane profile.
**Independent Validation**: the corrected claims are checked against source in the same change; no
runtime dependency.
**Docs to update**: none.

### Objective

The last unowned row on a Phase-`4` surface asks for a measured per-request service time. Give it
an owning sprint (Standard I) and correct the false claim the type was making in the meantime.

### Deliverables

- ✅ **The row's premise is confirmed and its closure path is measured.** `rawServiceTimeMicros`'s
  own haddock said the field carries a *measured/attested* value; its only producer,
  `controlPlaneCapacityInputs`, authors it. Both statements are corrected in place rather than left
  to be quietly made true later — the same treatment Sprint `1.82` gave
  [vault_doctrine.md § 20.3](../documents/engineering/vault_doctrine.md).
- ✅ **Why no code change can close the row, stated as a measurement rather than a deferral.**
  `dhall/capacity/measured/` contains only `Schema.dhall` — **no measured profile has ever been
  committed for any lane**, so Sprint `5.21`'s recorder activation is itself outstanding and the
  control-plane profile is downstream of it. Adding a `service_time_p99_micros` schema field and a
  certification rule now would land a mechanism with nothing to certify, which is precisely the
  enforcing-nothing shape Sprints `1.82`, `4.68`, and `4.72` each had to close.
- ✅ The row is re-registered under this sprint with `Live-proof: pending`, so no `Pending Removal`
  row on a Phase-`4` surface is unowned.

### Validation

1. ✅ `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit 0,
   `prodbox test unit` exit 0 at main Hspec **3294/3294**, and installed
   `prodbox test integration cli` **55/55**, exit 0.

### Remaining Work

**The recorder run, and it is not code work.** A committed control-plane measured profile plus its
consumption through `certifyMeasuredProfile` closes the row. No such profile exists for any lane;
Sprint `5.21` owns the recorder that produces one, and its first capture is that sprint's own
`Live-proof` axis. This sprint makes no claim about when that capture happens — an ownership
statement rather than a dependency, because both sprints are `Done` and the outstanding item is
live-infra evidence. Non-blocking under
[Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof).

## Sprint 4.76: The Cascade Reports Absence It Did Not Observe ✅

**Status**: ✅ **Done (2026-08-11)** — Phase `4` own-surface reopen (Standard A) on the destructive
lifecycle paths this phase owns. Registered 2026-08-11 by an operator `cluster delete --cascade
--yes` run whose narration was read against §§ 3, 5b, and 6 of the reconciliation doctrine.
**Implementation**: `src/Prodbox/Lifecycle/ResourceRegistry.hs`,
`src/Prodbox/Lifecycle/K8sDrain.hs`, `src/Prodbox/Lifecycle/TagSweep.hs`,
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Nuke.hs`,
`src/Prodbox/Lifecycle/ResidueStatus.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/TestRunner.hs`.
**Blocked by**: none.
**Deployment qualification**: pending; this sprint **does** touch a Standard-P surface — destructive
cleanup and lifecycle orchestration are both in the § "Surfaces that invalidate qualification"
enumeration. Both rows are already `pending`, so nothing is invalidated, but a future run must
exercise the post-`4.76` cascade.
**Independent Validation**: the reproduction below runs on the home substrate with RKE2 installed
but not serving — no AWS, no live cluster API. `prodbox dev check`, `prodbox test unit`, and
`prodbox test integration cli` / `env` exit 0.
**Docs to update**: at landing, `documents/engineering/lifecycle_reconciliation_doctrine.md`'s
soundness/terminal-audit rules and `documents/engineering/streaming_doctrine.md` § 6. The target is
now superseded by the exact-keyed correction in Sprints `4.84`–`4.86`.

### Objective

An operator ran `prodbox cluster delete --cascade --yes` on a host with RKE2 installed but its API
server not serving. The command printed:

```text
Per-run residue status: aws-eks=unreachable (...), aws-eks-subzone=unreachable (...), aws-test=unreachable (...)
Per-run Pulumi destroys: skipped (no live per-run residue).
```

…and exited 0. Three statuses of `unreachable` were narrated as "no live per-run residue". Doctrine
§ 3 layer 1 is titled *Cleanup continues **without lying***, and § 5b phase 1 says an unreachable
checkpoint "records an unresolved cleanup failure … the aggregate cannot report success". Skipping
the destroy is the documented graceful-degradation exception; **claiming absence and exiting 0 is
not**.

The narration is the visible half. Four folds underneath it convert an unobserved state into a
benign one:

- `resourcesToDestroy` filters on `isResiduePresent`, so `ResidueUnreachable` lands in the same
  bucket as `ResidueAbsent`, and `reconcileAbsent` prints a line asserting absence.
- `inferCascadeSubstrate` also tests `isResiduePresent`, so all-`unreachable` infers
  `SubstrateHomeLocal` — precisely the branch on which a skipped drain is success.
- `clusterReachable :: K8sDrainEnv -> IO Bool` returns `False` for *any* non-zero `kubectl` exit, so
  permission-denied and stale-context are indistinguishable from "cluster is gone". `DrainResult`
  has four constructors and **no "cannot observe" arm** — the uncertainty is manufactured by the
  `Bool` and then discarded into `CascadeContinue`.
- `runCascadePostflightTagSweep :: FilePath -> IO ()` and `runCascadeTestEbsReaper` return unit, so
  a non-empty escapee list or a failed query cannot reach the exit code. The sweep's own Haddock
  cites § 6 as licensing this, while § 6 requires the opposite; and `prodbox nuke` — the doctrine's
  other sweep-owning surface — has no sweep call at all.

These compose: unreadable backend ⇒ "home substrate" ⇒ "nothing to drain" ⇒ "no residue" ⇒ exit 0,
with the postflight sweep as the only backstop and the sweep unable to fail.

### Deliverables

All seven are landed.

- **A three-valued cluster probe** replacing `clusterReachable :: IO Bool`. `ClusterProbe` is
  `Reachable | ClusterAbsent evidence | ClusterUnobservable detail`, and the split is decided by the
  pure `classifyClusterProbe` so it is pinned by unit cases rather than by a live cluster. Only a
  **recognised** connection-establishment phrase yields `ClusterAbsent`; the default arm is
  `ClusterUnobservable`, so a `kubectl` failure mode the classifier has never seen fails closed. The
  evidence set deliberately contains no authentication or authorization phrase — being told
  `Unauthorized` proves a server answered — and a unit case asserts that closed property directly
  rather than restating the list. `DrainResult` gains `DrainUnobservable`, which
  `cascadeDecisionFromDrainResult` maps to abort on **both** substrates;
  `src/Prodbox/TestRunner.hs` takes the same arm as its existing `DrainSkipped → ExitFailure 1`.
- **`reconcileAbsent` narrates absent and unobserved distinctly** and returns
  `AbsentReconcileOutcome` (destroy exit, observed-absent names, unobserved names) instead of a bare
  `ExitCode`. `absentReconcileExitCode` fails on a non-empty unobserved set even when every destroy
  succeeded. Its "no destroy ran" sentence is a total function of the `(observed-absent,
  unobserved)` pair, so an all-unobserved batch cannot borrow the all-absent wording, and the
  unobserved sentence goes to the diagnostic stream.
- **`inferCascadeSubstrate` treats `Unreachable` as "AWS may be in scope"** — written as
  `all isResidueAbsent … then SubstrateHomeLocal else SubstrateAws`, so the home branch is reached
  only from a positive observation of absence on every stack.
- **The cascade folds phase outcomes.** `runNativeDeleteCascade` records six
  `CascadePhaseOutcome`s (confirm-MinIO, drain, per-run destroys, test-EBS reaper, uninstall, sweep),
  runs every phase, and returns `aggregateCascadeExit`. Per § 5c the destroys run even when the
  drain failed — an attempt edge, not a barrier — and the destroy's success does not erase the drain
  failure. The closing line is derived from the recorded failures, not restated.
- **The postflight tag sweep is fail-closed**, through a pure
  `decideTagSweep :: TagSweepScope -> Either String [TaggedResource] -> TagSweepVerdict` that is
  total over the query result and the two owning surfaces. `TagSweepConfirmedClean` is the only
  verdict whose rendering asserts absence. `prodbox nuke` gains the terminal sweep § 5/§ 6 assign
  it — with **no** skip arm and **no** retained-long-lived carve-out, since destroying that class is
  what `nuke` is for.
- **`renderRetainedStateNotice` takes the delete mode**, so a `--cascade` run no longer closes by
  advising the operator to run `--cascade`.
- **`residueBlocksTeardownGate` is `not . isResidueAbsent`**, so a future constructor defaults to
  blocking rather than to the destructive side.

### What the sprint's own registration got wrong, and one thing it did not consider

Two corrections, both by measurement:

1. **The `reconcileAbsent` narration was not only per-run.** The row treated the
   `"Per-run Pulumi destroys: …"` prefix as the cascade's. `prodbox aws teardown` routes its
   **`Operational`** batch (IAM user + `aws.*` config) through the same function, so every operator
   who has ever torn down the IAM user was told "Per-run" about it. The label is now derived from
   the batch's own `LifecycleClass` via `reconcileScopeLabel`, so it cannot drift from the entries.
2. **A unit case pinned the defect the sprint exists to fix.** `test/unit/Main.hs`'s "contains no
   reachable legacy five-command teardown adapters" listed `discoverClusterTaggedAwsResources` among
   the forbidden tokens in `src/Prodbox/CLI/Nuke.hs` — so the absence of nuke's sweep was an
   asserted invariant, not merely an omission. It is corrected under Standard C: the sweep is not one
   of the legacy adapters, it is a § 6b terminal obligation, and the case now asserts its
   **presence**.

The thing the row did not consider is the **credential-absent third state**. The row named two
fail-closed conditions (non-empty escapee list, unreachable Tagging API); a missing ephemeral admin
credential is neither. Refusing on it would fail `--cascade` on every host that has never
provisioned an AWS substrate, so that arm stays a skip — narrated `NOT RUN`, explicitly disclaiming
confirmation, never rendering the clean sentence. It is **registered rather than absorbed** in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Validation

1. **Reproduction, and it is the acceptance criterion.** ✅ **Live-proven 2026-08-11 on the home
   substrate.** RKE2 was installed via `prodbox cluster reconcile` and its API server stopped, giving
   exactly the reported scenario; `prodbox cluster delete --cascade --yes` then:
   - reported per-run state as **unobserved** — `Per-run residue NOT OBSERVED for aws-eks,
     aws-eks-subzone, aws-test: the state backend could not be read. This is not a confirmation that
     the resources are gone.` and `Per-run Pulumi destroys: none run (no resource was observed
     present; 3 could not be observed at all).`;
   - printed the string `no live per-run residue` **zero** times;
   - exited **1**, closing with `Unresolved phase(s): confirm-MinIO, drain`;
   - ran every phase — drain, test-EBS reaper, uninstall, and sweep all executed, and RKE2 is fully
     uninstalled with `.data/` preserved.

   **The run also demonstrated the composing chain end to end, which the unit cases can only show
   piecewise.** `inferCascadeSubstrate` saw three `unreachable` statuses and inferred
   `substrate=aws`; the drain therefore attempted AWS kubeconfig materialization, failed, and was
   recorded as a failed phase. On the pre-`4.76` predicate the same input would have inferred
   `SubstrateHomeLocal`, where a skipped drain is success — so the identical host state would have
   produced a clean drain, no destroys, and **exit 0**. That is the reported defect reproduced and
   removed against live state rather than argued.

   Two behaviours were confirmed live that no fixture exercises: the postflight sweep reached the
   real AWS Tagging API, correctly carved out the retained `prodbox-pulumi-state-long-lived` bucket
   as retained-by-design, and reported `clean (the Tagging API confirmed no escaped residue)`; and
   the mode-aware retained-state notice closed a `--cascade` run **without** advising the operator to
   run `--cascade`.
2. **The reproduction as a unit case, which is what makes it falsifiable.** `reconcileAbsent` over
   an all-`ResidueUnreachable` batch and over an all-`ResidueAbsent` batch produced the *same*
   `ExitSuccess` and the *same* narration before this sprint. Both inputs are now asserted, side by
   side, to differ in narration and in exit code, with a third case proving a successful destroy
   does not absolve an unobserved sibling. ✅
3. Unit cases pinning the probe's connection-refused / permission-denied / success classification,
   the unrecognised-exit fail-closed default, the closed evidence set, `DrainUnobservable`'s abort,
   the substrate inference on an unreadable backend, the phase fold, the mode-aware notice, and the
   three-valued sweep verdict on both scopes. **25 new cases.** ✅
4. `prodbox dev check` exit 0 ✅; `prodbox test unit` exit 0 at main Hspec **3357/3357** (3332 + 25)
   plus 27/27, 33/33, 27/27 ✅; installed `prodbox test integration cli` **55/55** exit 0 ✅;
   `prodbox test integration env` exit 0 ✅.

### Remaining Work

None on the sprint's original code-owned surface. At landing, the then-current reconciliation
doctrine named the gate/destroy/aggregate refusal owners and terminal sweep verdict, and
`streaming_doctrine.md` gained *A narrated skip is not a narrated absence*. **2026-08-15
correction**: that composition still admitted a global audit answer as per-stack truth and
uninstalled on incomplete recovery. Sprints `4.84`–`4.86` supersede the target without withdrawing
the narrower `4.76` fail-closed and narration work.

**A regression found while validating this sprint, and fixed here rather than left.**
`prodbox test integration cli` did not pass 55/55 at the start of this sprint — it failed **8 of
55**, identically before and after the `4.76` code, so the sprint neither caused nor masked it.
Sprint `3.34` (2026-08-11) made `endpoints/kubernetes` a live observation on the chart-reconcile
path and closed on `dev check` + `test unit` evidence without running the integration suite; the two
fake-`kubectl` boundaries in `test/integration/CliSuite.hs` served no `endpoints kubernetes`, so
every fixture reconcile refused with `endpoints "kubernetes" not found` or, in the second fake,
with empty stdout through its catch-all arm and the message `observation was not in the expected
form`. Both boundaries now answer with an RFC 5737 TEST-NET-1 address and the real post-DNAT port.
This is Phase-`5` suite content under
[Standard M](development_plan_standards.md#m-test-suite-substrates) and is recorded as a Standard-C
correction on Sprint `3.34`'s evidence sentence, which did not claim the integration suite.

## Sprint 4.77: Two AWS Queries Do Not Send The Filters They Name, And `--yes` Does Not Confirm ✅

**Status**: ✅ **Done (2026-08-11)** — Phase `4` own-surface reopen (Standard A), same
destructive-path surface as Sprint `4.76`, split out because the root cause is argument
construction rather than observation folding.
**Implementation**: `src/Prodbox/Lifecycle/TagSweep.hs`, `src/Prodbox/Lifecycle/EbsVolume.hs`,
`src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`,
`src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksSubzoneStack.hs`,
`src/Prodbox/Infra/AwsSesStack.hs`.
**Blocked by**: none.
**Deployment qualification**: pending; touches destructive cleanup. Both rows already `pending`.
**Independent Validation**: argv is a pure projection, so the pinning tests below need no AWS. The
live confirmation is a read-only `aws … --debug` argv inspection with empty credentials.
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md` if the EBS reaper's scope statement changes.

### Objective

The AWS CLI parses list-valued options with `store`, so a repeated option **replaces** the earlier
occurrence rather than accumulating. Two argv builders pass their filter option twice. Measured
against the installed CLI with empty credentials:

```text
aws ec2 describe-volumes --filters A B --filters C
  → body: Filter.1.Name = C          (A and B never sent)

aws resourcegroupstaggingapi get-resources --tag-filters K1 --tag-filters K2
  → body: TagFilters = [K2]          (K1 never sent)
```

Consequences differ in kind:

- **`TagSweep.tagFilterArgs`** sends only `prodbox.io/managed-by=prodbox`. The
  `kubernetes.io/cluster/<name>` filter never reaches AWS — so the postflight sweep is structurally
  blind to exactly the controller-created ENIs, ALBs, and security groups it exists to backstop,
  which carry the cluster tag and not the ownership tag. A separate defect rides along: the Tagging
  API **ANDs** `TagFilters`, so the intended OR needs two calls unioned by ARN, not one call with
  two filters.
- **`EbsVolume.ebsDescribeVolumesArgs`** (`EbsPerRunTest` scope) sends only
  `kubernetes.io/cluster/<name>=owned`, dropping `prodbox.io/managed-by` and
  `prodbox.io/lifecycle=per-run-test`. `testScopedEbsReaperPlan` then deletes **every** returned
  volume with no client-side re-filter. This is contained today only because prodbox-created
  retained volumes are tagged without the cluster tag — an accidental guard, one tag away from
  deleting retained production EBS.

Separately, `--yes` on all four `aws stack <stack> destroy` verbs is inert. It is parsed as
`confirmed` with help text "Skip confirmation prompts", renamed `summary` at dispatch, wildcarded by
three of four sinks, and consumed by the fourth as a **quietness** selector
(`| summary = pulumiLoginQuiet`). No `requireInteractiveTty` guard covers these verbs. The command
is *intentionally* non-interactive per the
[AGENTS.md command-selection contract](../AGENTS.md#command-selection-automation-vs-operator-interactive),
so the defect is not a missing prompt — it is a
surface advertising a safety property it does not have, where omitting the flag is byte-identical to
passing it.

### Deliverables

All four are landed.

- **One `--filters` occurrence carrying all filter values.** `ebsDescribeVolumesArgs` emits the
  option once and appends the scope's cluster value to the same list. A second unit case asserts the
  *structural* property — no scope emits `--filters` more than once — so a future scope cannot
  reintroduce the shape without failing.
- **One `--tag-filters` occurrence per call, two calls unioned.** `tagSweepFilterSets` returns one
  argv per filter set and `discoverClusterTaggedAwsResources` runs each, unioning rows through
  `unionTaggedResources`. This closes **two** defects, not one: the argv defect the row named, and
  the relational one it noted in passing — the Tagging API ANDs `TagFilters`, so even both-sent
  would have asked for resources carrying *both* tags where the sweep wants either. A failure of any
  constituent query fails the whole discovery (`sequence` before the union), so a partial union is
  never reported as complete.
- **`runTestScopedEbsReaper` re-filters client-side**, via `testScopedEbsReaperPlan`, which now
  folds each volume's own tags into rows and runs them through the already-written
  `partitionEbsTagRows` / `testScopedEbsVolumeIdsFromTagRows` — until this sprint those had no
  production caller. The guards are independent: the argv narrows the query, the fold narrows the
  result, and the unit case exercises the fold on inputs the argv fix alone would still have
  deleted.
- **`parseTagSweepPayload` fails closed.** Both non-array arms returned `Right []`, so an error
  envelope or a renamed key was indistinguishable from a clean sweep. All three unreadable shapes
  now return `Left`, and — because Sprint `4.76` made the sweep fail-closed — a case pins that the
  `Left` reaches `TagSweepUnconfirmed` and exits non-zero rather than stopping at the parser.
- **`--yes` gates the destroy.** The row offered gate-or-remove; **gate** is the right resolution
  and the reason is not preference. `prodbox aws stack <stack> destroy --yes` is the documented
  automation entrypoint in
  [AGENTS.md](../AGENTS.md#command-selection-automation-vs-operator-interactive) and is the
  `resourceDestroyCommand` string in the
  managed-resource registry, which the teardown refusal surfaces print to operators. Removing the
  flag would have required changing all three and would have left the automation contract narrower
  than the doctrine. `requireDestroyConfirmation` refuses when the flag is unset, in the shape
  `runPruneCorruptCheckpoint` has always used, at one site covering all four verbs.

### What the row did not separate, and what that cost

The row said `--yes` "is consumed by the fourth as a **quietness** selector
(`| summary = pulumiLoginQuiet`)" and treated that as evidence of inertness. It is more than that:
it means the flag *did* have an observable effect, and the effect had nothing to do with what its
help text said. Gating alone would have left confirmation and output verbosity threaded through one
`Bool` — so `--yes` would still be doing two unrelated jobs, and the next reader would face the same
ambiguity. The two are now separate: `requireDestroyConfirmation` consumes the flag, and
`destroyOutputIsQuiet` is a named constant carrying the value every automation call site already
passed. The parameter is renamed `quietOutput` in all four sinks, so the three that ignore it are
visibly ignoring *output verbosity* — which they have no use for, since they dispatch through the
Lifecycle Authority rather than shelling out to `pulumi` — rather than appearing to ignore a
confirmation.

`--dry-run` is deliberately unaffected: the gate lives inside the apply closure, so a plan still
renders without `--yes`, and the integration case pins that alongside the refusal.

### Validation

1. Unit cases pinning the exact argv of `ebsDescribeVolumesArgs` for both scopes and of
   `tagSweepFilterSets` for named and unnamed clusters, plus the two structural
   one-occurrence-per-option assertions. The defect is invisible to any test that does not assert on
   the argument list. ✅
2. A unit case proving the reaper plan drops a volume carrying the cluster tag and **not** the
   lifecycle tag, and keeps the retained-production volume out even when it also carries the
   test-scoped marker — exercising the client-side re-filter independently of the argv fix. A
   companion case pins the `volume/<id>` coordinate round trip that couples the two halves. ✅
3. `prodbox aws stack eks destroy` without `--yes` in a non-TTY context refuses with exit 1, starts
   no Pulumi work, and names `--yes`; `--dry-run` still renders `CONFIRMED=false` without it; and
   passing `--yes` reaches past the gate. Pinned by one integration case. ✅
4. `prodbox dev check` exit 0 ✅; `prodbox test unit` exit 0 at main Hspec **3369/3369** (3357 + 12)
   plus 27/27, 33/33, 27/27 ✅; installed `prodbox test integration cli` **56/56** exit 0 ✅;
   `prodbox test integration env` exit 0 ✅.

### Remaining Work

None on the code-owned surface. Live AWS confirmation of the corrected argv is a Standard-O axis and
is non-blocking. 🧪 **Live-proof: pending** — the read-only `aws … --debug` argv inspection with
empty credentials is the confirmation the row specifies, and it requires the AWS CLI configured on
the host; the argv is a pure projection and is pinned exactly by the unit cases above, which is what
closes the sprint.

**A scope statement this sprint deliberately does not make.** The corrected sweep now sends the
cluster-tag filter it always named, so it *can* see controller-created ENIs, ALBs, and security
groups for the first time. Whether it *does* is a live-AWS question, and no claim is made here that
the sweep is complete — § 6 already says the sweep is defence-in-depth for a controller that
diverged from its registered family, never the ownership registry. `DEVELOPMENT_PLAN/substrates.md`
needs no scope change: the EBS reaper's scope statement is unchanged, since the client-side
re-filter narrows the same `EbsPerRunTest` scope the document already describes rather than widening
it.

## Sprint 4.78: Absence Decided From Free Prose, With Unanchored Markers ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `4` own-surface reopen (Standard A) on the
observation-producer surface this phase owns through Sprints `4.76` and `4.77`.
**Implementation**: `src/Prodbox/Observation/AbsenceMarker.hs` (**new** — the owner),
`src/Prodbox/Minio/ObjectStore.hs`, `src/Prodbox/Lifecycle/LiveResidue.hs`,
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`, `src/Prodbox/Lifecycle/AdminAction/KubernetesJob.hs`,
`src/Prodbox/ControlPlane/TargetSecretWorkerProduction.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/KubernetesJob.hs`, `src/Prodbox/Aws.hs`,
`test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (**this moves a Standard-P destructive-cleanup surface**).
The one behavioural consequence is narrowing: messages that previously classified as *absent* on an
unanchored numeral or the bare word `missing` now classify as *unobserved*, which the fail-closed
teardown gate refuses on. No resource is destroyed that was not destroyed before; some that would
have been presumed gone are now reported unobservable. Both substrate rows are already `pending`.
**Independent Validation**: pure classifiers over strings, validated by the unit suite and a
mutation exercise — no cluster, no AWS, no later phase. `prodbox dev check` exit 0;
`prodbox test unit` exit 0 at main Hspec **3414/3414**; `prodbox test integration cli` **57/57**.
**Docs updated**: none under `documents/` — the module's own Haddock cites
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md), which is
already authored and unchanged.

### Objective

Close the row recording that `String -> Bool` classifiers decide, from free error prose, whether a
resource is *absent* rather than *unobserved* — the producers one hop upstream of an ADT layer that
is otherwise sound.

### The row said seven; there are nine, and one of them was already dead

| Claim | Recorded | Measured |
|---|---|---|
| Classifiers | "Seven" | **9** — its own list enumerates 5 named plus "four `isNotFound` variants" |
| `operationalCredentialsAbsentError`'s reachability | implied live, with a Vault-policy example | **unreachable** — see below |

`readLifecycleProviderTargetCredentials`, the **sole** producer of the `Either` that classifier
reads, is a total constant `Left` whose message contains neither `missing` nor `empty`. So the
predicate evaluated `False` on every production input, and the row's own worked example — a Vault
error reading *token is missing the required policy* minting `ResidueAbsent` — could not occur
today. That does not make the row wrong about the defect; it makes the fix **behaviour-preserving**,
which is worth knowing before touching a fail-closed teardown gate.

### The shape is copied, as the row instructed

`Prodbox.Observation.AbsenceMarker` generalises `classifyAwsSesPresenceOutput`: a closed
`AbsenceProbe` set, anchored marker lists keyed per probe, and one total `reportsAbsence`. Three
classes of correction land with it:

- **Anchored numerals.** A bare `"404"` matched a request id or a byte count; `"(404)"` and
  `"status code: 404"` do not. Same for the conditional-conflict probe's `"409"`/`"412"`.
- **Stderr only.** The four `isNotFound` variants matched `stdout <> stderr`, so a *successful*
  `kubectl` whose printed object happened to contain `not found` — a ConfigMap value, a condition
  message, a log line — read as the object being absent. They now read stderr.
- **Deleted rather than anchored.** The three `operationalCredentialsAbsentError` arms are removed,
  not re-worded. An unresolvable credential is now `Left` / `ResidueUnreachable` — "I could not
  observe this" — where two of them previously answered `Right False` and `ResidueAbsent`, which say
  "I observed that it is not there".

### Validation

1. Four unit cases. The one that matters asserts the **direction**: across the whole closed probe
   set, `AccessDenied`, `ExpiredToken`, `SlowDown`, and a Vault policy refusal all stay
   *not absent* — the same reading Sprint `4.76` established when it required a recognised
   connection-establishment phrase before minting `ClusterAbsent`. ✅
2. A structural case requires every probe's marker set to be non-empty, lower-case, and free of
   digits-only entries, so the defect cannot return through a new probe. ✅
3. **The inverted test is the evidence.** `clearedDecision: a missing/empty SecretRef error is
   cleared` asserted the defect as an invariant. It now asserts that a real Vault refusal shape is
   **not** cleared — the fail-closed direction — under Standard C. ✅
4. Mutation-proven: re-adding the bare `"404"` marker fails **two** cases, the specific one and the
   structural one. ✅
5. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at **3414/3414**;
   `prodbox test integration cli` **57/57**. ✅

### Remaining Work

None on this row. **The bound is stated plainly**: matching prose is still matching prose. What
changed is that every marker is anchored to a form the tool actually emits, the sets are keyed by
probe so an S3 vocabulary cannot answer a Kubernetes question, and there is one place to read them.
This does not make a wrong classification unrepresentable — the tools offer no typed channel that
would — and no gate here can prove the registered *reasons* true.

## Sprint 4.79: Two Destroy Paths Reported Success They Did Not Observe ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `4` own-surface reopen (Standard A) on the destructive
lifecycle paths this phase owns through Sprints `4.76` and `4.77`.
**Implementation**: `src/Prodbox/Infra/AwsSesStack.hs` (`completeDestroy`, the new pure
`destroySummaryFromStackRemove`), `src/Prodbox/Infra/LongLivedPulumiBackend.hs`
(`destroyLongLivedPulumiStateBucket`, `purgeLongLivedObjectsUnderPrefix`), `test/unit/AwsSesLifecycle.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (**this moves a Standard-P destructive-cleanup surface**).
Both substrate rows are already `pending`, so nothing is invalidated. No resource is destroyed that
was not destroyed before; what changes is that two paths which reported completion now report what
they observed, and one refuses where it previously proceeded on an unobserved absence.
**Independent Validation**: a pure narration fold plus two classification arms, validated by the
unit suite — no live AWS. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec
**3417/3417**.
**Docs updated**: none under `documents/` —
[lifecycle_reconciliation_doctrine.md § 3](../documents/engineering/lifecycle_reconciliation_doctrine.md)
already states the rule these paths violated (*Cleanup continues without lying*).

### Objective

Close the row recording that `completeDestroy`/`finalizeDestroy` discard `pulumiStackRemoveEither`
and return a hardcoded `Right "destroyed"`, and that `destroyLongLivedPulumiStateBucket` /
`purgeLongLivedObjectsUnderPrefix` treat **any** `head-bucket` failure as `Right ()`.

### The row bundled two defects of the same shape but opposite severity, and they get opposite remedies

| Site | What it claimed | Remedy |
|---|---|---|
| `completeDestroy` | "destroyed", when the Pulumi stack entry may survive | **Report** the residue; the destroy itself had already succeeded |
| the two `head-bucket` arms | bucket absent, on a 403 / expired credential / throttle / network fault | **Refuse**; absence was never observed |

Making `completeDestroy` fail would refuse a teardown that did in fact remove every AWS resource —
the destroy runs *before* the stack removal and had already returned `Right`. What was wrong was the
silence, not the success, so the summary now names the surviving stack entry and tells the operator
to re-run. The `head-bucket` arms are the opposite: nothing was observed, and
[§ 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md) is explicit that "cannot
observe" is never "absent". They now admit only an anchored not-found response, through Sprint
`4.78`'s `reportsAbsence S3BucketProbe`, and refuse everything else.

### Why the second half is the serious one

`runAwsS3Api` returns `Left` for subprocess-start failure and every non-zero exit. So on the
terminal node of the `nuke` decommission DAG, an expired admin credential made
`destroyLongLivedPulumiStateBucket` answer "already gone" about the `pulumi_state_backend` bucket
holding every encrypted checkpoint — and the caller proceeded as though the decommission had
completed.

### Validation

1. Three unit cases over the extracted pure `destroySummaryFromStackRemove`, which is pure and
   exported precisely because the defect was a *narration* — a narration nothing can observe is how
   it survived. One asserts the deliberate decision that a failed removal still reports the AWS
   resources destroyed, so the record says why rather than implying it. ✅
2. The two `head-bucket` arms consume Sprint `4.78`'s classifier, whose direction case already
   asserts that `AccessDenied`, `ExpiredToken`, `SlowDown`, and a Vault policy refusal are **not**
   absence for every probe in the closed set. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at **3417/3417**. ✅

### Remaining Work

None. **One bound is stated**: the refusal arms are only as good as the marker set behind them,
which is Sprint `4.78`'s stated bound and not re-argued here. A `head-bucket` failure mode AWS
spells in some form not in `S3BucketProbe`'s markers now **refuses** rather than being mistaken for
absence — the fail-closed direction, which is the one to be wrong in.

## Sprint 4.80: The Cascade Sweep's Last Skip Arm Was a Policy Question, and It Is Answered ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `4` own-surface reopen (Standard A) on the destructive
lifecycle paths this phase owns; it closes the residual Sprint `4.76` registered against itself.
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`cascadeSweepCredentialAbsentExit`,
`runCascadePostflightTagSweep`), `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (**this moves a Standard-P destructive-cleanup surface**).
Both substrate rows are already `pending`. A host that never provisioned an AWS substrate exits 0
exactly as before; a host whose per-run AWS state was present or unobservable now fails a cascade
whose backstop never ran.
**Live-proof**: pending (Standard O, non-blocking) — the `SubstrateAws` refusal arm has not been
exercised on a live host that has AWS state *and* no admin credential. The composition is pinned by
unit case; the field observation is not.
**Independent Validation**: a pure two-arm decision composed with the existing pure substrate
inference, validated by the unit suite — no cluster, no AWS. `prodbox dev check` exit 0;
`prodbox test unit` exit 0 at main Hspec ~~**3419/3419**~~ — **corrected 2026-08-14 under Standard C**: the figure recorded here and the `3420` recorded in this plan's phase table disagreed with each other, and Sprint `4.81` measured the pre-`4.81` tree at **3430** by deriving the delta from its own case count rather than by subtracting totals.
**Docs updated**: none under `documents/` —
[lifecycle_reconciliation_doctrine.md § 6](../documents/engineering/lifecycle_reconciliation_doctrine.md)
already states the rule, and this sprint makes the code satisfy it rather than changing it.

### Objective

Close the row recording that the cascade's postflight tag sweep skips silently when no ephemeral
admin AWS credential is available — the one arm Sprint `4.76` left as a skip while making the other
two fail closed.

### The row framed this correctly, and the framing is what made it solvable

Sprint `4.76` registered it as **a policy question, not an honesty one**: the arm no longer claimed
absence, so what remained open was whether the home cascade should *require* an AWS credential it
has no other use for. Refusing outright would fail `prodbox cluster delete --cascade` on every host
that has never provisioned an AWS substrate — an authorized lifecycle path in
[AGENTS.md](../AGENTS.md#live-infrastructure-deployment-is-authorized).
Both horns are real, which is why the row sat unowned.

**The dilemma dissolves once you notice the cascade already computes the fact that decides it.**
`inferCascadeSubstrate` — Sprint `4.17.b`, corrected by `4.76` — yields `SubstrateAws` when any
per-run stack was *not positively observed absent*, and `SubstrateHomeLocal` only when every one of
them was. That is exactly the distinction the policy needs, it is already computed eight lines
earlier for the drain phase, and it needs no credential to compute:

- `SubstrateHomeLocal` — every per-run AWS stack was observed absent, so this cluster lifecycle
  created no AWS resources for the sweep to backstop. Skipping confirms nothing and needs to.
- `SubstrateAws` — AWS state was present or unobservable, the sweep is precisely the § 6 backstop
  for it, and "I have no credential to query with" is a case of cannot-confirm. Hard failure.

No new requirement is added. The AWS-free host still exits 0; the host that actually had AWS state
can no longer pass a cascade whose backstop never ran.

### Deliverables

- **`cascadeSweepCredentialAbsentExit`** — the decision as a pure total function of `Substrate`,
  outside the `IO` arm that used to hold it as a constant.
- **The narration follows the verdict.** The skip arm keeps its `writeOutputLine` and gains the
  reason it is sound; the refusal arm writes a diagnostic naming what is unconfirmed and what to
  re-run with. Neither claims absence, which is what Sprint `4.76` already fixed and this preserves.

### Validation

1. Two unit cases. The second is the one that carries the claim: it composes
   `cascadeSweepCredentialAbsentExit` with `inferCascadeSubstrate` over three real residue inputs,
   including **the exact input Sprint `4.76` found in the field** — every per-run stack
   `ResidueUnreachable` — which now fails rather than skipping silently. Testing either half alone
   would prove nothing about the arm. ✅
2. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at **3419/3419**. ✅

### Remaining Work

None on this row. **The bound is stated**: this decides the sweep's verdict from what the *cascade*
observed about per-run Pulumi state, not from what AWS holds. A host whose per-run stacks were all
observed absent but which nonetheless has orphaned AWS resources from some earlier lifecycle still
skips — correctly, because the cascade's sweep is scoped to the cluster lifecycle it is tearing
down, and § 6 already says the sweep is defence-in-depth for a controller that diverged from its
registered family, never the ownership registry.

## Sprint 4.81: A Residue Answer Does Not Say Which Authority Answered It ✅

**Status**: ✅ **Done (2026-08-14)** — Phase `4` own-surface reopen (Standard A) on the
residue-observation surface this phase owns through Sprints `4.16`, `4.19`, `4.21`, `4.76`, and
`4.78`.
**Implementation**: `src/Prodbox/Lifecycle/ResidueStatus.hs` (`ResidueObservationLayer`,
`ResidueObservation`, `observeResidueAt`, `ResidueAuthorityUnauthenticated`),
`src/Prodbox/Lifecycle/LiveResidue.hs` (`PerRunResidueStatuses`, the four triples),
`src/Prodbox/CLI/Rke2.hs` (`renderPerRunObservation`), `src/Prodbox/CheckCode.hs`
(`checkResidueObservationMinter`), `src/Prodbox/Infra/AwsTestStack.hs`,
`src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/AwsEksSubzoneStack.hs`,
`src/Prodbox/Aws.hs`, `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (**this moves a Standard-P destructive-cleanup surface** —
§ P names lifecycle orchestration and destructive cleanup among the surfaces a change invalidates).
Both substrate rows were already `pending`; no qualification identity captured before this sprint
survives it.
**Live-proof**: no live-infra axis (Standard O). Every deliverable is a pure projection or a
compile-time boundary, so there is nothing here that live infrastructure would falsify; the
consuming behaviour change is Sprint `4.82`'s and carries the live proof. This is an absent axis,
not a pending one.
**Independent Validation**: the layer projection is pure and total, and the minting boundary is a
`dev check` lint — unit suite only, no cluster and no AWS (Standard N).
**Docs updated**: the doctrine half was discharged in the change that registered this sprint, per
Standard L — [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
§ 5a records the residual and § 5b states which layer owns which question, and
[chaos_hardening_doctrine.md](../documents/engineering/chaos_hardening_doctrine.md) § 24 names the
second in-tree instance while citing the plan for the measurement (§ 22).
[system-components.md](system-components.md) still describes the layer distinction as the target
state; it is corrected when Sprint `4.82` makes the cascade consume it.

### Objective

[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) requires
that *a derived value is only as correct as the layer at which its source object is authoritative,
and that layer must match the layer at which the value is enforced*, and its corollary requires a
derivation to **name the layer whenever it names the source**. `ResidueStatus` had nowhere to name
one.

Measured rather than asserted: **nineteen** top-level producers, enumerated by signature over `src/`.
The authoritative sources they read are the Pulumi checkpoint store, AWS resource presence, AWS IAM,
AWS EBS, local config text, a Pulsar topic, a Vault gate decision, an object-store listing, SES
consumer quiescence, and public-edge TLS — plus two producers that are not observations at all: an
aggregate fold over other statuses and a bare transport-failure constructor.

**The producer count is mechanical; the layer count is a judgement, so this sprint states the list
and not a number.** An earlier draft said "eleven layers", arrived at by counting table rows rather
than distinct external authorities — EBS and IAM are both AWS, and a fold and a failure constructor
are neither. Publishing a numeral whose derivation is a bucketing choice is a restated inventory
wearing a derived one's clothes; the enumeration is falsifiable and the numeral was not.

**The defining module stated the rule and erased it ten lines later.** `PresenceObservation` and
`CheckpointObservation` are documented there as "deliberately independent … live resources and a
usable encrypted checkpoint are separate external facts"; `presenceObservationToResidue` joins the
first into `ResidueStatus` and `residueStatusFromCheckpointObservability` the second, after which
nothing distinguished them.

### The remedy was constrained by doctrine, not chosen

[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md) names this
surface explicitly: *"externally-authoritative state — readiness, leases, provider state, ownership,
**residue** — stays a flat exhaustive ADT computed by pure projection … the proof belongs in the
compile or decode gate, **never as an index on an observed value**."* A phantom or GADT layer index
was therefore out before the sprint began. Two further constraints bound the deliverable rather than
being discovered during it: § 24's anti-dedup rule — *say which layer a value is for, do not reduce
the count of values* — so `PresenceObservation` and `CheckpointObservation` are **not** merged; and
no § 25 was added, because § 24 already prescribes the behaviour and § 12 already carries its
strength row.

### Deliverables

- **`ResidueObservationLayer`** — a flat, `Bounded`/`Enum` ADT naming the authority that answered:
  retained checkpoint store, AWS, Vault gate, harness bypass. Carried as a **field**, per § 21.
- **`ResidueObservation`, with its constructor unexported** and `observeResidueAt` as the sole
  minter, so a consumer cannot obtain an answer without also obtaining the layer it was answered at.
- **`checkResidueObservationMinter`** restricts the minter to the two modules that hold an
  observation boundary. This is § 21's class-A move — *a witness is returned by performing the
  operation, never constructed by describing it* — in the same idiom as the Sprint `1.76`
  `RoundTripWitness` and Sprint `4.58` `TargetSinkVersion` boundaries and Sprint `3.32`'s
  `checkDnsOwnerAuthorityBoundary`.
- **`ResidueAuthorityUnauthenticated` replaces the mislabel.** `perRunAuthenticationFailedTriple`
  stamped `ResidueBackendMinioUnreachable` onto every `LifecycleAuthorityAuthentication` failure, so
  a live cascade run printed `MinIO backend unreachable` about a MinIO that was never dialled — three
  healthy subsystems named, and the one that failed named nowhere. Conversion class, § 23.
- **The cascade says who answered.** `renderPerRunObservation` prints
  `… [answered by: retained checkpoint store]` beside each status, which is § 24's corollary applied
  to the operator-facing sentence.
- **`residueAbsent` withdrawn.** It was an exported alias for `ResidueAbsent` with **no production
  caller**, whose only test asserted it equalled the constructor — a tautology about a redundant
  second minter, the enforcing-nothing shape Sprints `4.68`, `4.72`, and `4.77` each found. Deleted
  rather than re-worded, per § 23's "count the encoders" and "remove the conversion before adding a
  proof".

### Validation

1. **The reproduction as a unit case, side by side.** An absence observed at the checkpoint layer and
   one observed at AWS were the *same value* before this sprint; both are now asserted to share a
   status and differ in layer and in identity. That is the same shape of case Sprint `4.76` used to
   pin `ResidueUnreachable` against `ResidueAbsent`, and it is what makes the defect falsifiable
   rather than argued. ✅
2. **The closed property, asserted rather than the list restated**: no authentication failure renders
   as a claim about a backend that was never contacted, and the MinIO reason is retained for a
   boundary that genuinely was dialled. ✅
3. Layer rendering is total and injective over `[minBound .. maxBound]`, so a narration cannot
   conflate two authorities; and `mapResidueObservationStatus` is pinned not to relabel the
   authority. ✅
4. **`checkResidueObservationMinter` mutation-proven.** A minter call was introduced in
   `src/Prodbox/Infra/AwsTestStack.hs`; `dev check` failed naming file and line and listing the
   permitted modules; the file was restored and verified byte-exact by `md5sum -c`. ✅
5. **6 new cases**, measured by running only them (`prodbox-unit -p "/Sprint 4.81/"` → `All 6 tests
   passed`) rather than by subtracting totals. ✅
6. `prodbox dev check` exit 0 ✅; `prodbox test unit` exit 0 at main Hspec **3436** plus 27, 33, and
   27 ✅.

**A recorded baseline was wrong, and deriving the delta is what showed it.** 3436 − 6 = **3430**
before this sprint, but Sprint `4.80`'s block records `3419` and this plan's phase table records
`3420` — two figures that already disagreed with each other and both of which disagree with the
tree. Corrected under Standard C in both places rather than the newer number being quietly written
over the older.

### Remaining Work

None on this sprint's surface.

**The bound is stated.** This makes the layer *sayable*, its minting *restricted*, and the narration
*honest about who answered*. It does not make any consumer read the right layer — a producer may
record one and a consumer still ignore it. That is Sprint `4.82`'s surface and this sprint is not
credited with it. The gate is a compiled rule over a source region, not a property of the type
(§ 22): it cannot prove a permitted module named the *correct* layer, only that a module with no
observation boundary cannot name one at all.

## Sprint 4.82: Historical AWS-Layer Resolver — Composition Falsified ✅

**Status**: ✅ **Done (2026-08-14)** — Phase `4` own-surface reopen (Standard A), same
destructive-path surface as Sprints `4.76`–`4.81`, split from `4.81` because the root cause is
consumption rather than representation.
**Implementation**: `src/Prodbox/Lifecycle/ResidueStatus.hs` (`AwsLayerAnswer`,
`ResidueResolution`, `resolveResidueAcrossLayers`, `residueResolutionStatus`,
`residueResolutionConfirmedAbsence`, `renderResidueResolution`), `src/Prodbox/CLI/Rke2.hs`
(`queryAwsLayerForPerRun`, `perRunNeedsAwsLayer`, `independentPhase`, `derivedPhase`,
`renderFailedCascadePhases`, `runNativeDeleteCascade`), `src/Prodbox/CLI/Spec.hs`,
`test/unit/Main.hs`.
**Blocked by**: none remaining — Sprint `4.81` (same phase, lower number, Standard N compliant)
landed first and is Done.
**Deployment qualification**: pending (**this moves a Standard-P destructive-cleanup surface**, and
it is the sprint that changes what `cluster delete --cascade` *does* rather than what it says). Both
substrate rows were already `pending`. A qualification run must exercise the post-`4.82` cascade,
and its Cleanup/residue cell must name which layer confirmed absence — recording a bare "clean"
would reintroduce at the evidence layer exactly the collapse this sprint removes.
**Live-proof correction (2026-08-15)**: ❌ falsified. The pure resolver cases did not compose raw
tag discovery, lifecycle partition, ARN cardinality, and per-stack attribution. See Validation 7.
**Independent Validation**: the resolution is a pure total function over `(observation × AWS
answer)`, and the phase-attribution helpers are pure over recorded outcomes — unit suite only, no
cluster and no live AWS (Standard N).
**Docs updated**: [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
§ 5a and § 5b already state which layer owns which question and record the residual this sprint
closes; [system-components.md](system-components.md)'s residue row no longer describes the layer
distinction as a target state.

### Historical objective and corrected finding

With the layer recordable after Sprint `4.81`, the cascade can ask the authority that owns the
question it actually consumes. Before this sprint `queryPerRunResidueStatuses` asked the in-cluster
Lifecycle Authority — unreachable whenever the control plane is down, which is the normal state when
an operator reaches for `cluster delete --cascade` — and the cascade then treated that
non-observation as grounds to fail `confirm-MinIO` **and** to infer `SubstrateAws`, so one
unobservable cause produced two failed phases.

**The command held an AWS answer, but not the exact answer the stack decision required.**
`runCascadePostflightTagSweep` loads `loadAdminAwsCredentials` and reaches the real AWS Tagging API.
The sprint treated that global audit as authoritative for per-stack presence. The 2026-08-15 run
falsified that composition: AWS returned one `ResourceTagMapping` for the retained bucket with its
full two-tag set; Prodbox's decoder emitted two internal rows and copied the resulting global
answer to three stack identities whose exact observations remained `Unobservable`. Postflight correctly
partitioned both internal rows as retained and rendered the ARN once, but that scoped audit result was not
exact per-stack observation and could not authorize a per-stack decision.

### Deliverables

- **Historical second-layer observation, consulted only when the first failed.** `queryAwsLayerForPerRun`
  reuses `TagSweep.discoverClusterTaggedAwsResources` and `loadAdminAwsCredentials`, both already
  production-proven on this path. `perRunNeedsAwsLayer` states the "we did not need to ask" case as
  a decision with a reason rather than an absent branch, and a missing credential is
  `AwsLayerNotConsulted` — **never** an absence.
- **Historical `resolveResidueAcrossLayers`, total over both inputs.** A positive answer at the authority layer
  is never overridden by AWS, because the two answer different questions. Only
  `ResolutionAwsLayerAbsent` and an authority-observed `ResidueAbsent` establish absence, and
  `residueResolutionConfirmedAbsence` returns *which layer* established it.
- **`ResolutionAwsLayerPresent` maps to `ResidueUnreachable`, deliberately.** The abstract unit arm
  records a caller-supplied presence answer, but the production global query proved only that some
  query-matching AWS resource mapping existed; it did not identify the requested stack. Mapping the
  arm to refusal was fail-closed, but treating the raw query as that arm was unsound and could not
  authorize or attribute a stack destroy.
- **`inferCascadeSubstrate` consumed the resolved value.** Its synthetic exact-absence case remains
  a valid unit result, but the production observer did not produce exact per-stack evidence; the
  live composition therefore could not justify the inferred substrate or skipped drain.
- **Historical phase narration was narrower than the causal claim made for it.**
  `cascadePhaseDerivedFrom` is populated when both the drain and the nominated predecessor failed;
  it does not carry provenance from the decision that selected or blocked the drain. The rendered
  “downstream” label landed, but simultaneous failure cannot establish causality. Sprint `4.85`'s
  dependency graph replaces that inference with typed edges and independent outcomes.
- **The `--cascade` help text stops advertising a property the code removed.** It promised "the K8s
  drain phase skips gracefully when no cluster is reachable"; Sprint `4.76` ended that and this
  sprint changes the condition again, so the text now states what is actually true — every phase
  runs, and success requires each phase to confirm its own outcome.
- **A superseded renderer deleted rather than left.** Sprint `4.81`'s `renderPerRunObservation` is
  replaced by `renderResidueResolution`; keeping both would be the second-encoder shape § 23 warns
  about.

### Validation

1. **The two arms that decide the reported defect, asserted side by side.** An unreachable authority
   with AWS reporting none resolves to absence at the AWS layer; the same observation with AWS
   unobservable or not consulted still fails closed. Before this sprint both inputs produced the same
   refusal and the same exit 1, so the pair differing is what makes the fix falsifiable rather than
   argued. ✅
2. **AWS never overrides an authority that answered** — asserted over the full cross-product of both
   answering observations against all four `AwsLayerAnswer` constructors. ✅
3. **The refusal arm is pinned**: AWS-reports-resources with an unreadable checkpoint confirms no
   absence and renders "not destroyable". ✅
4. **Historical renderer cases are pinned, not causal provenance**: simultaneous predecessor/drain
   failure renders the nominated predecessor, while predecessor success and drain success suppress
   it. Those cases do not distinguish an independently failing drain from a truly downstream one;
   the live counterexample therefore falsified the stronger attribution claim. ✅ narrow renderer /
   ❌ causal claim
5. **8 new cases**, measured by running only them (`prodbox-unit -p "/Sprint 4.82/"` → `All 8 tests
   passed`) rather than by subtracting totals. ✅
6. `prodbox dev check` exit 0 ✅; `prodbox test unit` exit 0 at main Hspec **3444** plus 27, 33, and
   27 ✅ — reconciling exactly with `4.81`'s measured 3430 baseline plus 6 plus 8;
   `prodbox test integration cli` **57/57** ✅. The tree measures **3446** at the time of writing
   because Sprint `2.47` added two cases on a Phase-`2` surface in the same session; the figure above
   is this sprint's, stated as measured rather than as the tree's current total.
7. **The live reproduction was taken and falsified this composition (2026-08-15).** With the local
   Lifecycle Authority caller unobservable, AWS returned one `ResourceTagMapping` for the
   intentionally retained long-lived state bucket with its full two-tag set. Prodbox's decoder
   emitted two internal rows; the same global answer was copied to all three per-run stacks whose
   exact observations remained `Unobservable`; AWS drain was selected; and neither Kubernetes drain
   nor Pulumi destroy reached an external effect. Postflight partitioned both internal rows as retained and rendered the ARN
   once, with no escapees. Expected exit 0 did not occur. This is the stable counterexample owned
   by Sprints `4.84`–`4.86` and `5.35`. ❌

### Remaining Work

The narrow layer field/resolver implementation remains historical, but its production composition
is not accepted as the target. Sprints `4.84`–`4.86` own the exact-keyed replacement and deletion of
the global fallback.

**Corrected bound.** The AWS query was authoritative only for the cluster-wide tag-query response it
obtained; the pre-`4.84` path did not normalize that response into domain resources. It
was not keyed per stack, did not partition lifecycle class before the decision, and counted tag
rows rather than domain identities. Naming the AWS layer did not make those missing coordinates
true.


## Sprint 4.83: A Pullable Digest By Configuration Rather Than By Contract ✅

**Status**: ✅ **Done (2026-08-15)** — Phase `4` is reclosed. The rollout token remains the
host-reported Docker identity, while a distinct OCI config digest is resolved for runtime
attestation and every Pod pull uses its declared `repository:tag`.
**Implementation**: `resolveLocalImageBuildToken` and the runtime config-digest resolver in `src/Prodbox/Lib/ChartPlatform.hs`,
the observers `decodeAndValidateJob` / `validatePod` in
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`, `parseJobBinding` /
`podObservation` in `src/Prodbox/Lifecycle/CredentialProvisioner/KubernetesJob.hs`, `podObservation`
and `ContainerStatusDto` in `src/Prodbox/ControlPlane/TargetSecretWorkerProduction.hs`, and
`validateImageReference` in `src/Prodbox/Lifecycle/AdminAction/Kubernetes.hs`.
**Blocked by**: none.
**Deployment qualification**: code-owned validation complete; current-revision live qualification
remains Standard O/P evidence rather than a closure gate.
**Live-proof**: 🧪 pending, and deliberately low-value — the prior live tree already passed the pull
arm; this sprint closes the contract and runtime-attestation gap with deterministic cases.
**Independent Validation**: every Pod/Job manifest builder is pure over its intent and a caller-supplied
image reference, and every observer is pure over an HTTP status and body — unit cases only, no cluster
(Standard N).
**Docs to update**: [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) on closure;
`documents/engineering/local_registry_pipeline.md` § 6.2 already carries the measurement and the rule
this sprint enforces.

### Objective

Sprint `2.51` fixed two Bootstrap Broker Pod-image references built as
`repository@sha256:<config digest>`, which no OCI registry can resolve. Three further sites in this
phase build a reference the same way — `workerImage` in
`src/Prodbox/ControlPlane/TargetSecretWorkerKubernetes.hs`, the AWS-admin provisioner Job in
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`, and the external ACME-EAB
ingress Job in `src/Prodbox/Lifecycle/CredentialProvisioner/KubernetesJob.hs`, all with
`imagePullPolicy: Always`.

### The correction that defines this sprint, and it is the whole finding

**These three sites were registered as defective, and they are not. Measuring the value settled it
against the analysis, and the analysis was this plan's own.** The claim was that they inherit a
config digest from `resolveLocalImageBuildToken`, which runs
`docker image inspect --format '{{.Id}}'`. Measured on the operator host against one image:

| Reporter | Value |
|----------|-------|
| Kubernetes `status.containerStatuses[].imageID` | `sha256:e3c7ab7c…` |
| registry `Docker-Content-Digest` for the tag | `sha256:52d86a90…` |
| `docker image inspect --format '{{.Id}}'` | `sha256:52d86a90…` |
| `docker image inspect --format '{{json .RepoDigests}}'` | `…@sha256:52d86a90…` |

`.Id` equals the registry's manifest digest, so the rendered references **are** pullable and none of
the three is broken. **The inference that failed was reasoning from the Broker's measurement to a
different reporter**: the Broker reads Kubernetes' `imageID`, which genuinely is the config digest,
and "`docker inspect .Id` is the config digest" was carried across as though the two reporters were
one. They are not, and the plan has now made this class of error four times — *an identity stated in
prose is not a measurement, and the difference is a command away.*

**What is real is why it works.** This host runs the Docker daemon with the **containerd image
store** (`docker info` → `driver-type io.containerd.snapshotter.v1`), under which `.Id` is the
manifest digest. Under Docker's classic image store `.Id` is the config digest — same field, different
layer, selected by daemon configuration this repository never sets, asserts, or documents. So three
`imagePullPolicy: Always` Jobs are pullable **by host configuration rather than by contract**, and the
failure mode if that configuration differs is the one Sprint `2.51` spent a session diagnosing.

### Deliverables

- **The three sites stop needing a registry-resolvable digest at all.** The first draft of this
  deliverable proposed changing `resolveLocalImageBuildToken` to read `.RepoDigests`. **That is the
  wrong fix and is recorded as refuted rather than deleted.** Two reasons: `.RepoDigests` is empty
  until an image has been pushed, so a locally built image would silently lose its rollout token and
  with it the change detection Sprint `3.38` just made load-bearing; and more fundamentally, a
  rollout token does not need to be a registry coordinate at all — it only has to **change when the
  image changes**, which `.Id` does under either image store. The layer confusion is not in the token,
  it is in the three sites that consume a token as a pull reference. So the remedy is Sprint `2.51`'s
  exactly: the `image` field carries the declared `repository:tag` that `ResolvedCustomImage` already
  holds beside the token, and the digest stays an attestation identity compared against an observed
  `imageID`.
- **The observers given a runtime identity to attest against**, which is a defect independent of the
  digest question and does not go away with it.

  **A constraint that makes this harder than the Broker's version, measured so the next session does
  not design around a false premise.** The Broker could attest one Pod against another because both
  identities came from the *same reporter* — Kubernetes `imageID`. These three cannot: their intent
  digest is minted on the **host** by `docker image inspect`, and on the operator host that value is
  `sha256:5baff542…` while the Pod running that exact image reports
  `imageID sha256:fad071f2…`. Measured side by side. **So comparing the observed `imageID` against the
  intent digest can never pass**, and the naive form of this deliverable is unimplementable.

  Two shapes remain and the choice is not settled here: attest a Job Pod against a **counterpart Pod**
  observed through the same reporter (the Target Agent for the target worker, the Lifecycle Authority
  for the credential-provisioner Jobs), which is the Broker's pattern and needs no host-minted digest;
  or have the host mint a *config* digest rather than `.Id`, which requires establishing that one is
  obtainable at all under the containerd image store before it can be relied on. `decodeAndValidateJob` / `validatePod`, `parseJobBinding` /
  `podObservation`, and `TargetSecretWorkerProduction.podObservation` each validate a Pod by
  re-deriving the same `repository@digest` string and comparing it to `spec.containers[].image` — a
  value the same code path wrote, so the comparison is self-consistent by construction and can only
  ever pass. `ContainerStatusDto` does not parse `imageID` at all, so the runtime identity is not
  merely unused there; it is unavailable. The contract to adopt is
  [bootstrap_readiness_doctrine.md § 0.4.1](../documents/engineering/bootstrap_readiness_doctrine.md):
  the attestation identity is the **observed** runtime digest, and a spec field is a request rather
  than a proof.
- **The latent fourth site addressed**: `validateImageReference` in
  `src/Prodbox/Lifecycle/AdminAction/Kubernetes.hs` *requires* a digest-suffixed reference and has no
  production caller today.
- **`checkWorkerImagePullReferenceOwner` widened** beyond `src/Prodbox/Bootstrap/Broker/` once these
  paths no longer assemble references, which is the point at which the Sprint `2.51` guard stops
  being Broker-local.

### Validation

1. Warning-clean `cabal build --builddir=.build all --enable-tests --ghc-options=-Werror` exit 0. ✅
2. `prodbox test unit`: **3482/3482** in the main suite, including the new negative runtime-identity
   case; the additional registered suites are run by the final repository gate. ✅
3. `prodbox dev check` exit 0; `prodbox test integration cli` **57/57**; `prodbox test integration
   env` **57/57**. ✅
4. The target-worker observer decision is pinned directly: a `containerd://sha256:…` identity equal
   to the intent is accepted and a different observed digest is refused. The production observer
   uses that decision after parsing `status.containerStatuses[].imageID`; its declared image is not
   an attestation input. ✅

### Remaining Work

None on the code-owned surface. The deliberately non-blocking Standard-O live proof remains evidence
work.


**Two facts established while scoping, so the implementation does not start by rediscovering them.**
First, **no durable type needs to widen**: `imageRepository` is already a caller-supplied parameter on
`renderAwsAdminJob` and `renderCredentialProvisionerExternalJob`, and `ResolvedCustomImage` already
carries the tag beside the repository, so the `image` field can become a declared reference without
touching `AwsAdminPermitIntent` or the external-ingress intent — both of which **are** `Serialise` and
would have hit exactly the arity trap Sprint `2.51` measured. Second, the observer half is blocked on
the reporter mismatch recorded under Deliverables and must resolve that before it can be written.

**What is deliberately not folded in.** The config digest is not removed from
`resolvedCustomImageRolloutToken`'s *purpose*: a rollout token only has to change when the image
changes, and either digest satisfies that. The defect is a value whose layer depends on host
configuration being consumed where a registry coordinate is required.

## Sprint 4.84: Pure Registry and Exact-Keyed Observation Algebra [✅ Done]

**Status**: Done on its code-owned surface (opened 2026-08-15; closed 2026-08-17). The pure
exact-keyed foundation, the stable registered-stack lifecycle generation, its durable run-invariant
join, the terminal retained matcher/query catalog, the measured audit field of view, the
Authority-side generation producer, the read-back-bound cleanup selector, the submitting lane that
commits a run-invariant generation for every per-run stack creation, the selection route that makes
both directions reachable from a host run, comprehensive escape-registry coverage, the two separately
classed EBS registry identities, the typed ServiceAccount observation-cause classifier, the measured
operational-credential liveness edge, and the region-bounded terminal-audit verdict are implemented
and validated.

**Re-scoped on closure (2026-08-17, Standard N).** This sprint previously held a consumer-conversion
item whose own text said it "cannot land independently of the caller restructuring in Sprints
`4.85`/`5.36`/`6.5`". That is a dependency on a later phase, which
[Standard N](development_plan_standards.md#n-phase-independence-and-execution-order) forbids and
directs to be re-scoped rather than recorded — and holding it made this sprint, and therefore the
whole queue behind it, unable to close. The conversion is now owned by the sprints that already own
the compositions it deletes: the `TestRunner`/`DurableCleanupComposition` half by Sprint `5.36`, and
the `runNativeDeleteCascade` half by Sprint `6.5`. Nothing about the landed surface changed.
**Blocked by**: none.
**Deployment qualification**: pending — lifecycle selection and destructive-cleanup evidence change.
**Doctrine**: [Lifecycle Reconciliation Doctrine § 3.1, “The managed-resource registry and exact
observation boundary”](../documents/engineering/lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary),
[Pure FP Standards § 1.3, “Programs are data”](../documents/engineering/pure_fp_standards.md#13-programs-are-data),
and [Pure FP Standards § 6, “External-System Boundaries”](../documents/engineering/pure_fp_standards.md#6-external-system-boundaries).
**Implementation**: `Prodbox.Lifecycle.Teardown.Model`, `Registry`, `Decision`, `StackGeneration`,
`RetainedInventory` (region-indexed derived discoverability and region-bounded clean verdict),
`Prodbox.Lifecycle.Teardown.TaggingApiReach`, `Prodbox.Lifecycle.OwnedResourceTags`,
`Prodbox.Lifecycle.Teardown.AuditFieldOfView` with
`Prodbox.CheckCode.checkTerminalAuditFieldOfView`,
`Prodbox.Lifecycle.ResourceClass` (the two EBS identities),
`Prodbox.Lifecycle.EbsVolume` (scope-indexed identity),
`Prodbox.CheckCode.managedResourceRegistryParityViolations`,
`Prodbox.ControlPlane.LifecycleAuthorityAuthentication` (the observation-cause classifier),
`Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage`,
`Prodbox.ControlPlane.RegisteredStackGenerationRepository`,
`Prodbox.ControlPlane.RegisteredStackCreationProducer`,
`Prodbox.ControlPlane.RegisteredStackCreationSubmitter` with
`Prodbox.ControlPlane.AuthorityProviderEndpoint`'s operation-naming dispatch,
`Prodbox.ControlPlane.RegisteredStackCleanupSelection`, the exact observation and ownership facades
under `Prodbox.Lifecycle.Teardown`, `Prodbox.Lifecycle.AwsInventory`, and the coverage layer in
`Prodbox.Legacy.EscapeRegistry`. The old `ResourceClass`/`EbsVolume`/`TagSweep` and CLI residue
funnel remain pre-cutover.
**Live-proof**: pending and non-blocking for code-local closure; the pure counterexample is
independently validatable first.
**Independent Validation**: exhaustive tables and properties over registry projection, keyed
observation-set construction, ARN normalization, and decision inputs; warning-clean build and
`prodbox dev check`.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/chaos_hardening_doctrine.md`,
`documents/engineering/pure_fp_standards.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/substrates.md`, and `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Make it impossible for cascade to target a `LongLived` resource, for a global audit answer to
inhabit exact per-stack truth, for tag-row cardinality to become resource cardinality, or for a
runtime EBS tag set to choose the lifecycle class of the resource being observed.

### Measured counterexample and correction to Sprint 4.82

The 2026-08-15 run falsifies `4.82`'s remaining-work and live-proof premise. The AWS Tagging API
worked: it returned one `ResourceTagMapping` for the intentionally retained bucket with its full
two-tag set; Prodbox's decoder emitted two internal rows and copied one global answer to `aws-eks`,
`aws-eks-subzone`, and `aws-test`, whose exact observations remained `Unobservable`. Postflight partitioned
both internal rows as retained and rendered the ARN once, with no escapees. The preliminary
caller-ServiceAccount observation reported unobservable, but discarded stderr leaves its cause and
API reach unknown. No Kubernetes drain request and no Pulumi provider effect occurred. The evidence
supports a Prodbox identity/scope/cardinality composition failure, not an AWS or Kubernetes failure.

### Current Implementation Checkpoint (2026-08-16, paused)

- Pure lifecycle/surface/target registries, exact observation scopes and complete-set decisions,
  ARN normalization, and distinct checkpoint/manifest/audit types have focused exhaustive tests.
- Authority-facing stack-creation and ownership routes (`54`/`55`) use bounded authenticated
  requests and independent read-back. Provider AWS-scope receipts and stack-reader repositories
  expose opaque proof facades; raw repository/codec/remint paths are hidden.
- The direct public ownership-manifest and stack-reader proof-laundering chains were removed;
  route `55` remains deliberately observation-only until an exact admitted-create join exists.
- The terminal retained-resource inventory is incomplete (for example, it does not yet carry the
  full S3/SES/shared/dynamic matcher catalog), and the old global tag/residue composition and
  incomplete legacy-escape registry remain Pending Removal.

### Stable Registered-Stack Lifecycle Generation (landed 2026-08-17)

The structural identity defect this sprint named is closed at the type level.
`Prodbox.Lifecycle.Teardown.StackGeneration` splits one fused identity into two:

- `StackGenerationKey` is run-invariant. It carries the registered key, the compiled coordinate
  digest, the registry revision, the sole local foundation, the AWS account/region, and an ordinal
  distinguishing successive create/destroy cycles of one stack. No fact about *who was running*
  appears in it, and the canonical NUL-framed rendering is asserted not to contain the creating run
  scope or surface.
- `RegisteredStackGeneration` adds causal provenance — the admitted create operation, the exact
  Provider credential session, and the creating run scope and surface. Provenance is recorded and
  never consulted during selection.

Three key components are deliberately not parameters of
`establishRegisteredStackGeneration`: the AWS scope comes only from an opaque
`VerifiedProviderAwsScope`, and the coordinate digest and registry revision come only from the
compiled registry. A caller therefore cannot assert an account, a region, a coordinate the registry
does not own, or a revision this binary was not built with — each of which would mint a key no later
run could reproduce. A non-`Stack` kind and an unregistered key both refuse.
`selectRegisteredStackGeneration` succeeds across a *different* durable run scope and a *different*
cleanup surface — the property the defect denied — while refusing each run-invariant key component
on its own, and it re-applies `cleanupSurfaceAllows` so knowing a generation key cannot widen a
surface.

Because the key is run-invariant, so is its durable address: `stackGenerationSlotLogicalName` hashes
the canonical NUL-framed key rendering into `authority/registered-stack-generations/<digest>`. The
creating run and a later cleanup run compute the same slot without either knowing the other's scope,
and the prefix is distinct from the per-run `authority/aws-stack-creations/` prefix so a
generation-keyed record cannot collide with or be mistaken for a run-keyed one.

Eleven focused cases in `test/unit/LifecycleTeardownStackGeneration.hs` exercise this against the
real admitted-create and Provider-scope proof paths, not fakes of them.

### The Durable Run-Invariant Join (landed 2026-08-17)

The generation is now a durable record rather than an addressable-in-principle one.
`Prodbox.ControlPlane.RegisteredStackGenerationRepository` commits it at
`stackGenerationSlotLogicalName` through a `ClusterRetained` Model-B repository and settles every
outcome by independent read-back.

- **Response-loss repair.** A lost CAS response is neither a success nor a failure, so
  `commitRegisteredStackGenerationWithRepair` re-observes the slot: the exact record repairs the lost
  response to a commit; an absent slot reports that nothing was committed and names the lost
  response; a different record is a conflict. This is the same repair shape the AWS stack-creation
  binding already carries, applied to the run-invariant slot.
- **A later run derives its own addressing key.**
  `stackGenerationKeyFromProviderScope` mints the key from the compiled registry and one exact
  `VerifiedProviderAwsScope`. The coordinate digest and registry revision come only from the
  registry, and the account/region only from the Provider proof, so a cleanup run cannot assert its
  way to a key the creating run could not also have minted, and it never needs the creating run's
  scope or surface.
- **Selection is bound to the read-back.**
  `selectRegisteredStackGenerationFromRepository` reads the record the addressing key addresses,
  requires the stored key to equal that key, and only then applies `cleanupSurfaceAllows`. An empty
  slot refuses (`RegisteredStackGenerationAbsent`) instead of inferring a generation from residue;
  an unobservable store stays distinct from an absent one; a record found under a key that is not
  its own is a slot-collision refusal.
- **The record cannot smuggle authority.** Decoding re-derives the coordinate digest and registry
  revision from the compiled registry and refuses a stored disagreement, alongside canonical-form,
  version, bound, and reserved-ordinal checks.

### Durable Ordinal Succession (landed 2026-08-17)

A generation slot is addressed *by* its ordinal, so nothing in the generation records can say what
the next cycle is without an unbounded probe. The series answers that in one read.

- `StackGenerationSeriesKey` is the generation key minus its ordinal: one registered stack, in one
  account, region, and foundation, has exactly one series, and its successive create/destroy cycles
  are the ordinals within it. It is derived by the same registry-and-Provider-proof route as a
  generation key, so it inherits the same refusals and the same caller-cannot-assert property.
- The series cursor lives at `authority/registered-stack-generation-series/<digest>` — a prefix
  distinct from every cycle's own slot, so the pointer saying which cycle is current can never be
  mistaken for a cycle's record.
- `reserveNextStackGeneration` is idempotent in the admitted create operation. A retried create
  whose operation already advanced the cursor is recognized as a replay and is handed back the same
  cycle, so a lost response cannot burn a second ordinal and strand the record the first attempt may
  already have written. Opening a series requires no cursor; advancing one requires exactly the
  version it read.
- Every terminal answer is settled by re-observing the cursor rather than by trusting the write
  response: a lost response whose write applied resolves to the reservation, a lost response that
  applied nothing reports that nothing was committed, and a settled cycle held by another admitted
  create refuses as contended rather than proceeding on a cycle this run does not own.

Thirty-one focused cases now cover the generation: twelve the durable record, the repository, and
read-back-bound selection, and eight the series, the cursor, and reservation. **Not yet converted:**
no production producer reserves a cycle or writes the record, and no production consumer reads it.
The existing `AwsStackCreationBindingRepository` slot remains keyed by surface and run scope, so the
identity, its durable join, and its succession exist and are proven while the public cascade has not
cut over to them.

### Deliverables

- Replace callback-bearing lifecycle metadata with a pure registry indexed by static
  `LifecycleClass`, `ResourceKind`, and cleanup surface. The closed surfaces are local-only,
  cascade, explicit per-run stack, operational teardown, explicit long-lived, and external total
  decommission. Cascade targets are constructible from `PerRun` entries, separately typed
  `Operational` credentials whose dependency edges keep them live until every final consumer is
  terminal, and the separately typed final local-substrate target. `LongLived` cannot enter
  cascade; local-only and explicit per-run surfaces cannot be conflated with it.
- Replace the single `aws-ebs-volumes :: LongLived` registry identity with two distinct registered
  target identities: test-scoped EBS indexed `PerRun`, and production-retained EBS indexed
  `LongLived`. Creators, observers, and cleanup-program projection select the typed descriptor
  before any provider response is read. Runtime tags remain ownership/coordinate/spec evidence;
  no tag classifier may mint, change, or recover `LifecycleClass`.
- Introduce distinct flat ADTs for exact resource observation, checkpoint-copy observation,
  ownership-manifest observation, and terminal escape audit. An exact-resource observation carries
  its registered key, coordinate digest, authority layer, observation revision, opaque durable-run
  scope, and explicit absent/present/partial/unobservable result. Checkpoint and manifest wrappers
  retain their own stack/copy or manifest provenance plus that scope. The aggregate escape audit
  instead carries its surface-indexed query/registry/run scope and retained/escaped/unobservable
  result; it cannot inhabit a keyed resource observation. The durable descriptor supplies each
  scope explicitly to the observer, so a prior run or surface cannot enter the current fold.
- Add a private `CompleteObservationSet` smart constructor requiring exactly one correctly bound
  observation for every selected key. `Absent`, `Present`, `Partial`, and `Unobservable` are all
  legitimate observations; the constructor refuses only incomplete coverage, duplicate keys, or
  wrong key/coordinate/authority/scope bindings. The total decision fold maps `Partial` and
  `Unobservable` to typed refusal, never to absence.
- Normalize AWS responses to `Map Arn AwsResource` before lifecycle partition, cardinality, or
  narration. Conflicting facts for one ARN refuse.
- Delete the conversion path by which `AwsLayerAnswer`, `ResidueResolution`, positional pairing, or
  a cluster-wide tag result becomes per-stack presence.
- Make the legacy-escape inventory comprehensive, not merely internally bijective: every surviving
  compatibility seam named by the Pending ledger must project to one typed escape category, exact
  source marker, removal owner, and deletion condition. The current one-entry registry is retained
  as measured input, not accepted as proof that no other escape exists.

### Validation

1. Complete registry/surface table: every `PerRun` entry is selected exactly once; each
   cascade-owned `Operational` credential is selected only through its separate constructor and
   dependency edges keep it present until all final consumers are terminal; no `LongLived` entry
   can inhabit `CleanupTarget 'Cascade`; local-only and explicit-per-run targets cannot inhabit
   cascade; and the local substrate cannot enter a generic resource destroyer. The table contains
   exactly two EBS family identities with different keys and fixed classes: test-scoped `PerRun`
   and production-retained `LongLived`; it contains no catch-all EBS identity spanning both.
2. Smart-constructor tables reject missing, duplicate, reordered-with-wrong-key, wrong-coordinate,
   wrong-authority, wrong-registry-revision, wrong-account/region/substrate/operation, and wrong-run/
   surface bindings. Pure exact-resource, checkpoint-pair, and ownership-manifest observation
   requests require the opaque durable-run scope explicitly; no request smart constructor accepts
   an ambient or mismatched value. Complete sets containing `Partial` or `Unobservable` construct
   successfully and the decision table deterministically refuses them.
3. One returned `ResourceTagMapping` with a full two-tag set may decode to two internal rows, but
   normalizes to one ARN; duplicated filters/pages/retries remain one, and a conflicting
   tag/resource fact refuses.
4. The frozen retained-bucket input yields one retained audit resource while all three exact stack
   observations remain `Unobservable`; the audit cannot construct per-run presence or absence.
5. Source/gate proof: registry modules contain no `IO`, callbacks, client endpoints, command
   strings, or generic `Maybe` destroy hooks; external observations remain flat ADTs, not
   state-indexed GADTs. No production function converts EBS tags or provider rows into
   `LifecycleClass`; mutation/removal of a lifecycle tag can produce mismatch, partial, or
   unobservable evidence, but can never reclassify retained EBS as `PerRun` or test-scoped EBS as
   `LongLived`.
6. Projection and negative-construction tables prove the test-scoped EBS key alone can enter the
   cascade/test-reaper cleanup-target projection, the production-retained key alone can enter
   explicit-long-lived or total-decommission target projections, and every wrong-key/class/tag
   cross-product refuses. Regenerating documentation from the implemented registry replaces the one
   current generated EBS row with the two target rows; `prodbox dev docs check` then pins that result.
7. The audit's field of view is joined to what the repository provisions: every resource a program
   under `pulumi/` declares whose provider type accepts tags must author a tag the compiled query
   catalog asks for, an unclassified provider type fails the build rather than being assumed either
   way, and a program the reader cannot read completely fails rather than contributing a subset. The
   program set is enumerated from disk, so a new provisioning program is covered without a second
   list.
8. Escape-registry coverage joins the compiled inventory to every still-Pending compatibility seam:
   an unmarked generic Tier-0 `aws.*`/`secret/aws/lifecycle-provider` legacy-reader, host-MinIO, or
   bespoke-cascade escape fails even though the
   existing marker↔entry bijection remains satisfied; deleted source plus stale entry also fails.
9. The audit's field of view is indexed by the audited region. The global-service set is derived from
   the reach table rather than authored beside it; only the global-service arm is attributed to the
   region, so a regional, untaggable, or non-AWS exclusion is never misreported as one; a
   global-service retained family is never discoverable outside that region; the two regions produce
   different retained-set digests; and a would-be-clean verdict taken outside the global-service
   region lowers to `TerminalAuditUnobservable` naming each unqueried service, while a discovered
   escapee still reports as an escape.

### The Terminal Retained Matcher and Query Catalog (landed 2026-08-17)

A terminal escape audit answers one question over a discovered inventory — is everything still here
something this surface intends to keep? — and until now the repository had no catalog with which to
answer it. `Prodbox.Lifecycle.Teardown.RetainedInventory` supplies both halves.

- **The query catalog** is what the audit asked for, so a clean verdict claims nothing outside it.
  It is symbolic — tag keys and tag pairs — and names every prodbox-owned tag family plus the
  per-run cluster ownership tag, which is strictly wider than the two-filter sweep it replaces.
- **The retained-matcher catalog** covers the four declared categories the sprint named: S3 (the
  long-lived Pulumi state bucket and the SES capture bucket), SES (the sending identity and the
  receipt rule set), shared identities (the operational IAM principal and every managed credential
  family from `managedAwsCredentialInventory` whose lifetime outlives the audited surface), and the
  one dynamic family (the registry's `LongLived` EBS identity, of unbounded cardinality).

The distinction against the superseded classifier in `Prodbox.Lifecycle.TagSweep` is the point.
That classifier read a retention marker off a provider row and concluded the resource was retained,
so an escapee that acquired a retention tag was laundered into the retained set. Every matcher here
is an exact identity instead: a fully-qualified ARN composed from the audited `AwsScope` plus a
validated name binding, or a registered family whose membership coordinate comes only from the
compiled registry. A runtime tag can witness membership in a family whose lifecycle class the
registry already fixed statically; it can never mint, change, or recover one, and a resource no
matcher names is an escapee whatever it wears. A focused case pins exactly this: the same fixture
row the old classifier retains, the catalog calls an escapee.

Retention is surface-indexed and the catalog carries its index, so one surface's retained set cannot
be presented as another's. Total decommission retains nothing; operational teardown owns the
operational principal and the operational credential families and therefore does not retain them; a
run-scoped credential is retained on no surface at all, so finding one after a cleanup is an escape.
The retained-set and query digests are derived from the catalog rather than authored, and
`mkCascadeTerminalAuditEvidence` now joins the catalog's AWS scope to the compiled program's own,
so a caller cannot present a foreign-account retained set whose digest happens to match its claim.

The partition separates two failures the old sweep conflated: an escapee, and a declared retained
resource that the query should have returned and did not. Only the first makes the surface dirty.

### Production Producer and Read-Back-Bound Consumer (landed 2026-08-17)

The generation existed and was proven, but nothing wrote one. Both directions now have a production
path, and both refuse rather than fall back.

- **`Prodbox.ControlPlane.RegisteredStackCreationProducer`** is the admitted-create path. It observes
  the create operation from the Authority's own admission aggregate, reads the Provider AWS-scope
  receipt back from that same aggregate, reserves the cycle, commits the run-invariant generation,
  and only then commits the run-scoped creation binding. The order is deliberate: a create that
  fails midway leaves the addressable record present and the run-scoped one absent, which is
  recoverable, where the reverse leaves a stack whose cycle no later run can name.
- **The account and region can no longer be asserted.** Endpoint format version `2` carries the
  admitted `ObserveProviderAwsScope` operation, and `ProvenProviderAwsSession` — an opaque type with
  a private constructor and exactly two introductions, one per proof kind — is the only way into the
  generation derivation. `Prodbox.ControlPlane.Runtime` binds the Authority form. A commit whose
  scope no retained receipt proves is refused with its own wire constructor, not silently downgraded
  to the caller's asserted scope.
- **`Prodbox.ControlPlane.RegisteredStackCleanupSelection`** is the cleanup-run path. A generation
  slot is addressed by its ordinal, so a run that knows only the registered key reaches the record
  through two authoritative reads — the series cursor, then the generation the cursor's ordinal
  addresses — and through nothing else. `selectCurrentRegisteredStackGeneration` refuses an unopened
  series rather than inferring a cycle from visible residue, keeps unobservable distinct from
  absent, and still re-applies `cleanupSurfaceAllows`.

### The Operational-Credential Liveness Edge Is Measured, Not Asserted (landed 2026-08-17)

This sprint's first validation item requires that a cascade-owned `Operational` credential's
"dependency edges keep it present until every final consumer is terminal."
`Prodbox.Lifecycle.Teardown.OperationalCredentialInventory` already carried the enumeration that claim
rests on — `OperationalCredentialGraphConsumer`, the teardown operations whose production interpreters
may open a Lifecycle-provider session — and its own comment stated the purpose: *"This list proves no
node is terminal."*

The list was authored by hand and joined to nothing, and re-reading the interpreters against it found
it **under-complete by three**. It stopped at `ReconcileStackCheckpointRestore`, but
`Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter` calls `readBackAwsRegisteredTargetAbsent`
through the registered-target interpreter that `mkCloudRuntime` normalizes into it in three further
arms: checkpoint recovery read-back, retirement, and retirement read-back.

The three omissions are not incidental. `targetCompletionName` makes the checkpoint-retirement
read-back the *completion node of every stack target* — later than anything the list named. An
ordering claim about when a credential may be disposed of turns on which consumer is **last**, so an
inventory that under-reports its last consumer understates precisely the fact it exists to establish.

`Prodbox.Lifecycle.Teardown.OperationalCredentialCoverage` supplies the missing join:

- `teardownOperationCredentialConsumer` is total over the closed operation universe, so a newly added
  `TeardownOperation` is an exhaustiveness failure until its credential dependency is classified
  deliberately — the discipline `operationalCredentialConsumerForIntent` already applies to
  `ProviderIntent`. This makes the forward direction hold *by construction*: the classifier's result
  type is the inventory, so an unclassified operation cannot compile.
- `validateOperationalCredentialCoverage` compiles the cascade program and proves the reverse
  direction — no stale inventoried consumer that no node reaches — and the ordering property itself:
  every credential-consuming node is a transitive predecessor of `cascade/audit-escapes`. That
  mechanizes `DispositionBeforeAuditConflictsWithLiveAuditCredential`, which until now was a typed
  assertion with nothing checking it against the graph. Ancestry counts every dependency kind:
  `RequiresAttempt` and `RequiresTerminal` order the run exactly as `RequiresSuccess` does, and the
  credential must stay live for a merely-attempted consumer just as much as for a required one.
- `fixedOperationalCredentialCoverageRegression` keeps the check from passing vacuously. It records
  that the ancestry relation is *discriminating* — `cascade/read-back-completion` runs strictly after
  the audit and is not among its ancestors — and that the audit is not its own credential consumer.

The gate runs in `prodbox dev check`. Three operations were also deliberately confirmed as
*non*-consumers, each adjacent to an arm that is one: `ObserveStackCheckpointPair` reads only the two
Authority-held checkpoint copies, the stack-reader bundle is an Authority repository round trip, and
`ReadBackEksDrainIntent` recovers the committed intent without re-observing the cluster.

This does not unblock credential disposition. The other seven
`OperationalCredentialDispositionBlocker` arms are untouched; what changed is that the ordering
premise underneath them is now measured against the compiled program instead of asserted beside it.

### The ServiceAccount Observation Cause Is a Value (landed 2026-08-17)

The 2026-08-15 run's preliminary caller-ServiceAccount observation "reported unobservable, but
discarded stderr leaves its cause and API reach unknown." That was not incidental narration loss.
`kubectl` exits `1` for an unreachable API server, refused credentials, an RBAC denial, an
unresolvable kube context, and a genuinely absent object alike, so the exit code carries none of
the distinction and the captured stderr carried all of it — and `validateServiceAccountProcess`
discarded it, emitting one sentence for all five.

`ServiceAccountObservationFailure` is now a closed ADT over those causes plus the
subprocess-never-started, identity-mismatch, and unclassified arms, and
`classifyServiceAccountObservation` is the total pure classifier that produces it.

The load-bearing distinction is `serviceAccountObservationAuthorityReached`: absence is a fact
about the cluster's contents and can only be reported by an authority that answered, while
unreachable, context-unavailable, and subprocess-unavailable are facts about whether the cluster
was observed at all. Collapsing them is exactly the shape of the counterexample this phase is
correcting — a non-answer inhabiting an answer. An unrecognized diagnostic is deliberately *not*
rounded to the nearest known cause; it stays `ServiceAccountObservationUnclassified` carrying the
exit code and the exact stderr.

#### The caller consumes the classification (landed 2026-08-17)

`validateServiceAccountProcess` survived as a rendering adapter that flattened the classification to
one `String` immediately, so the distinction the classifier exists to draw died at the call site. It
is deleted. `mintExternalCallerToken` returns `ExternalCallerTokenError`, which carries the
`ServiceAccountObservationFailure` whole and gives the two later `kubectl` boundaries — the
self-`TokenRequest` RBAC check and the `TokenRequest` itself — their own arms separating a subprocess
that never started from an API that answered and refused.

`externalCallerLogin` then decides with it, and the decision is the point. Every arm previously became
`VaultSessionUnavailable`, so an RBAC denial — permanent for the presented identity — was
indistinguishable from a transport failure and read to an operator as *retry later*.
`externalCallerTokenSessionError` derives its class from
`externalCallerTokenAuthorityRefusedAuthorization` rather than restating the mapping, so a new arm
cannot classify one way in the predicate and the other way at the boundary. Refused authorization is
deliberately narrower than "the API answered": an absent ServiceAccount and a mismatched read-back are
both answers, and neither is a denial.

The ledger row stays Pending for its last half. These observations are still authentication preflight
rather than nodes in the keyed observation algebra; the consumer conversion this sprint owns is what
places them there.

### The Residue Answer's Layer Is Complete and Consultable (landed 2026-08-17)

Sprint `4.81` made a residue answer carry the authority that produced it, so a `ResidueAbsent` minted
from a retained checkpoint could not be mistaken for one minted from AWS. Two things were left
unfinished, and both are measurable rather than stylistic.

- **The long-lived classes had no layer at all.** `queryPerRunResidueStatuses` minted its harness
  bypass at `ResidueLayerHarnessBypass`, but `queryAwsSesResidueStatus` and
  `queryPublicEdgeTlsResidueStatus` returned a bare `ResidueStatus` — so on exactly the two classes
  where "absent" authorizes the most, a bypass absence, a checkpoint absence, and an AWS absence were
  one indistinguishable value. That is the position that predates `4.81`, surviving in the paths the
  distinction was never applied to. Both now return `ResidueObservation`, and the layers differ for a
  reason: `aws-ses` is answered by listing an encrypted *checkpoint* through the Authority, while the
  retained public-edge TLS material is answered by listing *S3*. Naming both is what makes them
  distinguishable to a consumer.
- **The layer was consulted by nothing.** Every consumer stripped it with `residueObservationStatus`
  and decided over the bare status, so the field was expressible and load-bearing nowhere.
  `residueLayerAnswersResourceExistence` and `residueObservationProvesAwsAbsence` are the classifier:
  only AWS may answer whether an AWS resource exists, so a checkpoint-layer or bypass-layer absence
  proves nothing, and an AWS-layer *unreachable* proves nothing either.

The classifier is deliberately **not** wired into `residueBlocksTeardownGate`, and the reason is
evidence rather than typing. Doing so today would refuse every long-lived teardown: `aws-ses` has no
AWS-side observer — Sprint `7.36` owns it — and the integration fixtures still supply absence through
the harness bypass, which Sprint `5.36`'s typed-observer cutover removes. The predicate exists so
those two land as one decision rather than as two rules discovered separately.

### The Per-Run Join Is Keyed, Not Positional (landed 2026-08-17)

This sprint's counterexample is a global answer copied onto three per-stack observations. One layer
under it sat the same shape in miniature: `pairPerRunResidue` was
`zip perRunManagedResources [eksStatus, subzoneStatus, testStatus]`, so the join between a stack's
registry entry — carrying its *destroy command* — and the observation about that stack was correct
only while two independently written orders happened to agree.

Nothing enforced the agreement. Reordering the registry, or adding a fourth per-run stack, would have
attached one stack's presence to another stack's destroy command silently; and because every argument
had type `ResidueStatus`, swapping two at a call site was invisible to the type checker. The
destructive boundary itself, `runAuthorizedDeleteCascade`, took the three positionally.

`PerRunStackIdentity` is the closed enumeration that addresses both sides.
`perRunManagedResourceFor` and `perRunResidueAnswerFor` are total functions of it,
`perRunManagedResources` is derived from it rather than authored beside it, and the answers travel as
the named `PerRunResidueAnswers` record. The cascade's per-run narration also names each stack from
the registry entry the identity selects, rather than from a separately written label list zipped
against the resolutions by position. Adding a per-run stack is now an exhaustiveness failure in three
places instead of a silent misalignment, and a focused case pins that the enumeration order is the
documented teardown order — dependent VPC/subnet residue before the broader network substrate.

The ledger row stays Pending for its larger half: `queryAwsLayerForPerRun`, the global-answer fan-out,
`AwsLayerAnswer`, and `ResidueResolution` are unchanged and are deleted by the consumer conversion.

### The Effect-Bearing Registry Owns Its Own Identities (landed 2026-08-17)

Two related gaps closed together, both instances of a statement about a resource that nothing joined.

- **The registry did not own the operational entries.** `operationalManagedResources` was authored in
  `Prodbox.Aws` — so the module that supplies the credentials-bearing *effect* also authored the
  identity, the lifecycle class, and the operator-facing command text. A caller outside the registry
  could therefore register a name the registry never declared, or classify one of these as anything
  at all, which is exactly the "membership does not determine one closed legal program" defect the
  ledger row names. `OperationalResourceIdentity` is now the closed enumeration and
  `operationalManagedResourceFor` supplies every field but the effect; `Prodbox.Aws` maps a total
  function over the enumeration supplying only `resourceDestroy`, so a new identity is an
  exhaustiveness failure rather than a registry row with no action.
- **`resourceClass` was a third unjoined statement of lifecycle class.** After the typed teardown
  registry and `resourceLifecycleClasses`, `ManagedResource` carried its own, joined to neither — and
  it is not decorative: it selects the operator-facing scope label for a *destructive* reconcile
  batch, and it sits beside the table `guardTestDelete` refuses against and `substrates.md` publishes.
  `effectRegistryLifecycleClassViolations` joins it in `prodbox dev check`, reading the name and class
  off the constructed entries rather than restating them, so the projection cannot itself become a
  fourth copy. The reverse direction is deliberately not a violation: the flat inventory also
  registers dynamic families whose concrete names exist only at run time.

The two tables were measured **in agreement** today, so this is a cannot-drift guard rather than a
corrected disagreement — stated plainly because the same join between the typed registry and the flat
inventory did find one. The ledger row stays Pending for the fields themselves: `ManagedResource`
still carries raw command text and `IO` destroy hooks, and the reaper still treats a successful
provider delete exit as completion rather than requiring exact absence read-back.

### The Two EBS Registry Identities (landed 2026-08-17)

The typed registry has carried `AwsEbsPerRunTestKey` and `AwsEbsProductionRetainedKey` as separate
statically classed descriptors since this sprint's first increment, but the flat inventory those
descriptors are documented and guarded through — `resourceLifecycleClasses` in
`Prodbox.Lifecycle.ResourceClass` — still carried the single `aws-ebs-volumes :: LongLived` row.
Two tables disagreeing about one resource's class is not a documentation defect: `guardTestDelete`
refuses a `DeletePerRunResidue` for any name outside the flat `PerRun` slice, and
`renderRegisteredResourcesMarkdown` is what `substrates.md` publishes, so the flat table was
asserting that the test-scoped family was retained while the typed one had already classified it
`PerRun`.

Three things closed together:

- **The flat inventory carries both identities**, under exactly the names the typed keys render:
  `aws-ebs-volumes-per-run-test :: PerRun` and `aws-ebs-volumes-production-retained :: LongLived`.
  Regenerating the marked section replaced the one generated EBS row with the two target rows, and
  `prodbox dev docs check` pins that result.
- **The observing scope names the answer.** `ebsManagedResourceName` was a constant, so a volume
  discovered under `EbsPerRunTest` was reported under the same identity as one discovered under
  `EbsRetainedProduction`, and the distinction had to be recovered downstream from the runtime tag
  set. It is now indexed by `EbsVolumeScope`, and `ebsVolumesResidueStatus` /
  `ebsDiscoverResultToResidue` take that scope. A focused case runs the same discovered bytes —
  whose own tag list is empty — through both scopes and pins two different registered identities.
- **The join is machine-enforced.** `managedResourceRegistryParityViolations` fails
  `prodbox dev check` when a typed descriptor names no flat row, or when the two tables disagree
  about a class. The reverse direction is deliberately not a violation: the flat inventory also
  registers Pulsar topic families, the superseded Harbor release, the retained public-edge
  certificate, and the operational credentials, none of which the typed teardown registry owns.

What did *not* change is the reaper's completion evidence: a successful provider delete exit is
still not exact absence read-back. That obligation stays with the exact-observation algebra.

### The Terminal Audit's Field of View Is Measured (landed 2026-08-17)

The retained catalog answers *which discovered resources are intentionally kept*. It cannot answer
the prior question — *which resources the audit can discover at all* — and that question was settled
by a comment. `terminalAuditQueryCatalog` named five tag families and asserted that "every
prodbox-owned tag family appears, so a retained resource carrying any of them is returned and
classified rather than falling outside the audit unseen." Whether those families cover what prodbox
creates is a fact about the provisioning programs under `pulumi/`, and no code read them.

Reading them falsified the claim, and the measurement is stark:

- **Every resource of the `aws-test` substrate stack** — the VPC, internet gateway, route table,
  three subnets, the security group, and all three EC2 instances — carried only a `Name` tag. Three
  leaked EC2 instances would have been returned by no query, and `terminalAuditResultFor` would have
  reported `TerminalAuditConfirmedClean` over an inventory that never contained them.
- In `aws-eks`, the EKS cluster, node group, EBS-CSI addon, both node/cluster IAM roles, the OIDC
  provider, and both load-balancer-controller identities were in the same position. The subnets and
  VPC were discoverable; the cluster itself was not.

`Prodbox.Lifecycle.Teardown.AuditFieldOfView` is the join. It reads each provisioning program,
classifies every declared resource's provider type for Tagging API reach, and requires a
catalog-queried tag on every type that accepts one. Three properties are deliberate:

- **The program set is enumerated from disk, not declared.** A new provisioning program is covered by
  existing. This is the one inventory shape that cannot drift, and it is chosen precisely because the
  defect being closed was a hand-authored inventory joined to nothing.
- **An unrecognized provider type refuses.** `classifyTaggingApiReach` returns `Nothing` rather than
  guessing, so adding a resource type is a build failure until someone states whether AWS tags it —
  which is the only moment at which anyone knows. Assuming unreachable would silently excuse it;
  assuming reachable would demand a tag AWS may reject.
- **The reader refuses what it cannot read completely.** A program with no resources, a resource with
  no type, a duplicated logical name, or a `tags:` block at an unmodelled depth fails the build
  instead of contributing the subset it understood — the same failure the audit itself makes when it
  reports over a partial query union.

Nineteen violations were measured and corrected by authoring `prodbox.io/managed-by: prodbox` onto
every resource the join named. No IAM policy change was needed: `iam:TagRole`, `iam:TagPolicy`,
`iam:TagOpenIDConnectProvider`, `ec2:*`, and `eks:*` are already registered.

**This changes live audit behavior, and that is the point.** A cascade or `nuke` that leaves one of
these resources behind now surfaces it as an escape where the sweep previously returned nothing; the
retention carve-out is unaffected, because it keys on `prodbox.io/role=long-lived-pulumi-state`,
`prodbox.io/substrate=shared`, and the retained-EBS marker, none of which the newly tagged per-run
resources carry. The retained SES capture bucket continues to be carved out: `substrate=shared` is
among the families its writer authors.

One bound is stated rather than closed. A tag on an IAM identity is a backstop for this audit and
never an ownership authority — [§ 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md#6a-iam-is-registry-owned-not-tag-sweep-owned)
keeps IAM registry-owned.

#### The audited region bounds what a clean verdict may claim (landed 2026-08-17)

The reach classification was region-dependent and the region was bound to nothing. The Tagging API
returns global-service resources only from the global-service region; the audit composes its queries
from the audited scope and issues them in that scope's own region; and no type recorded the join. So
whether a tagged IAM role was inside or outside the audit's field of view was a fact about the
configured region that nothing in the repository could state — and every observation taken to date was
taken from `defaultAwsRegion`, which *is* that region, which is exactly what kept the dependency
invisible.

`Prodbox.Lifecycle.Teardown.TaggingApiReach` is the binding, and it is a leaf module so that the
provisioning-time join and the audit-time verdict decide reach from one table rather than from two
agreeing statements. Three properties are deliberate:

- **The global-service set is derived from the reach table.** `taggingApiReachTable` became a table
  rather than a `case` so `globalServicesRequiringGlobalRegion` reads out of it. A hand-authored list
  of global services beside the classifier is the same defect shape the field-of-view join closed one
  layer above it.
- **Discoverability is derived through the region.** `mkRetainedMatcher` now requires all three facts
  — the writer authors a queried tag, the catalog asks for it, and the audited region answers for the
  family's service — and none is sufficient alone. IAM families author no queried tag today, so this
  changes no current value; it makes the failure non-constructible. The moment a writer starts tagging
  the operational principal, an audit outside the global-service region would otherwise have reported
  it permanently absent-declared, which is the retention defect with no defect behind it that the
  capture bucket already demonstrated once.
- **A clean witness cannot be minted over a blind spot.** `terminalAuditResultFor` keeps its escaped
  arm unchanged — a discovered escapee is still an escapee, and a blind spot cannot launder one — and
  lowers the would-be-clean arm outside the global-service region to `TerminalAuditUnobservable`,
  carrying one `ObservationFailure` per unqueried service that names the service, the region that
  answered, and why absence there is not evidence. A non-answer is reported as a non-answer.

The retained-set digest separates the two regions, so a catalog composed in one cannot present its
retained set as the other's. What survives is the superseded executing sweep in
`Prodbox.Lifecycle.TagSweep`, which carries no region at all; its ledger row is narrowed to that
executor and closes with the consumer conversion that deletes it.

#### Discoverability is derived from the writer, not authored beside it

The provisioning programs are one of two creation surfaces, and the second one disproved the same
claim from the other direction. `RetainedMatcher` carried a hand-authored `RetainedDiscoverability`
flag, and it declared `RetainedSesCaptureBucket` discoverable — while that family's *supported*
writer, the Provider Worker's `ReconcileSesCaptureBucket` intent, created the bucket through
`s3api create-bucket` carrying **no tag at all**. The audit could therefore neither confirm the
retained bucket present nor find it escaped, and `retainedPartitionAbsentDeclared` would have
reported it missing on every run — a permanent retention defect with no defect behind it.

The flag is now computed rather than declared. `retainedMatcherCreatorTags` states, per family, the
tags its production writer authors; `mkRetainedMatcher` derives discoverability by asking whether the
compiled query catalog covers any of them. A family whose writer stops tagging becomes
not-discoverable by construction instead of continuing to claim otherwise.

One smaller copy of the same shape closed alongside it. The catalog composes the retained SES
receipt-rule-set ARN from its own literal of a name `Prodbox.Ses.Readiness` already owns, and — unlike
the operational IAM principal beside it — nothing pinned the two together, so a renamed rule set would
have left the matcher composing an ARN for an identity that no longer exists and the retained-set
digest encoding it. A focused case now composes the expectation from `sesReceiveRuleSetName` itself.

Three writers now hold one value rather than three agreeing statements.
`Prodbox.Lifecycle.OwnedResourceTags` is a leaf module carrying the retained buckets' tag families;
the native S3 client both writes and certifies the state bucket's set from it (those were two
separately authored copies — `renderBucketTaggingXml` and `expectedLongLivedBucketHardening` — of one
fact); the SES capture-bucket intent now authors its set and *observes* it, treating a bucket without
the prodbox-owned families as needs-apply so an existing untagged bucket is repaired rather than
reported clean. Observation is containment rather than equality, because the frozen `aws-ses`
provisioning program remains a writer during migration and authors a `Name` tag of its own; that
program now also declares `prodbox.io/managed-by`, so the two writers do not disagree about the
families the audit queries.

### Comprehensive Escape-Registry Coverage (landed 2026-08-17)

The one-entry bijection proved that every *marked* escape was registered; it could not prove that an
unmarked surviving escape had ever been inventoried, which is why Standard P could not treat it as
comprehensive. `Prodbox.Legacy.EscapeRegistry` now carries a coverage layer beside the bijection:
each still-Pending seam the deletion ledger names declares the exact source symbol that names it and
the complete set of files allowed to mention that symbol. A mention anywhere else fails the build
even when the bijection stays satisfied; a declared site that no longer mentions its symbol fails
too, so a deleted seam cannot leave a stale declaration; and every coverage rule anchors on a
registered marker entry of its own category, so a seam cannot be inventoried by symbol alone with no
owner and no deletion condition behind it. The three ledger-named seams — the generic Tier-0 `aws.*`
Lifecycle-provider aggregate and its host reader family, the host-direct MinIO transport, and the
bespoke cascade executor — are registered, marked, and covered.

### The Submitting Lane Exists (landed 2026-08-17)

Every part of the generation was proven and none of it ran. The reason was one discarded value.

Committing a generation needs the `OperationId` of the admitted create and of the admitted
`ObserveProviderAwsScope`. An `OperationId` is `(epoch, client, sequence, digest)`, and the epoch and
sequence are assigned **at admission** — so a submitter cannot derive one, it has to be told. The
Provider dispatch response returned only bounded evidence, and the duplicate-completed arm literally
pattern-matched the operation to `_`. The identity was in hand at both settlement sites and thrown
away at both, which is precisely why "no production submitter calls that route yet" was a structural
fact rather than missing wiring.

- **The route names what it admitted.** `ProviderDispatchCompleted` and
  `ProviderDispatchAlreadyCompleted` now carry the `OperationId`. Because a replay names the same
  operation the first attempt admitted, the lane is safe to retry rather than merely idempotent at the
  resource boundary. The route previously carried no version at all, so a change to either side of its
  wire shape would have been decided by a decode failure; `providerDispatchFormatVersion` is now `2`
  and a caller at another version is refused explicitly, in the same idiom
  `awsStackCreationEndpointFormatVersion` already uses.
- **`dispatchAuthorityProviderIntentWithOperation`** is the form that keeps it, and
  `dispatchAuthorityProviderIntent` is defined as its projection, so the dozens of callers that
  narrate a receipt and decide nothing are untouched and cannot drift from it.
- **`Prodbox.ControlPlane.RegisteredStackCreationSubmitter`** is the composition: observe the Provider
  AWS scope, dispatch the create, then present both operations to the Authority route that reserves
  the cycle, commits the run-invariant generation, and only then commits the run-scoped binding.

The load-bearing choice is the **foundation**. It is part of the run-invariant generation *key*, so a
later cleanup run must compute the same value knowing nothing about the run that created the stack.
It therefore comes from the retained local RKE2 control plane's own cluster id — the one fact stable
across runs by construction — and never from a per-invocation value. The creating run scope and
surface are the opposite: `selectRegisteredStackGeneration` records them and never matches on them, so
a per-invocation value there is correct rather than merely tolerated. A focused case pins both halves
together, because getting them the wrong way round is the failure this whole identity exists to
prevent.

The submission scope deliberately offers **no AWS scope slot**. The account and region enter the
generation only through the Provider proof the Authority reads back; a field for them here would be a
field for an assertion.

All three per-run stacks — `aws-eks`, `aws-eks-subzone`, and `aws-test` — create through this lane.
Their destroy paths deliberately do not: a destroy names a cycle that already exists and must not open
one.

### Both Directions of the Generation Are Reachable (landed 2026-08-17)

Committing a generation and selecting one are the two halves of a single identity, and until now only
the Authority could perform either. The consumer half is now served on the **same route** the creating
run commits through — a third action rather than a route of its own — so one wire version governs both
directions and a caller cannot be current for one and stale for the other.

- **The request names only what a cleanup run can prove.** It carries the registered key, the run's
  own admitted `ObserveProviderAwsScope` operation, and its own scope. There is no ordinal, no
  creating run scope, no creating surface, and no account or region: the cycle is reached through the
  series cursor and then the generation that cursor's ordinal addresses, and the account and region
  come only from the Provider proof the named operation retained.
- **The response is validated, not trusted.** It carries the generation's canonical record bytes, and
  the caller decodes them with `decodeRegisteredStackGeneration`, which re-derives the coordinate
  digest and registry revision from *its own* compiled registry and refuses a stored disagreement. A
  reply echoing a different request is a mismatch, and a reply of another kind is a kind mismatch.
- **A missing generation is a missing record, not a bad request.** Selection refusal maps to
  `ReplyNotFound`: a cleanup run that finds nothing is looking at a stack no admitted create ever
  committed a cycle for, and the four distinct refusals behind it — unopened series, unobservable
  store, slot collision, and a surface that may not select this identity — still do not degrade into
  "nothing is there".
- **Selection is a separate entry point from the creating client.**
  `selectRegisteredStackGenerationOverTransport` is a free function rather than a field of
  `AwsStackCreationBindingClient`, so a create-path consumer holding that record cannot reach
  selection with it.

The host lane, `selectRegisteredStackGenerationForCleanup`, selects under the **same foundation** a
creating run committed under, because both derive it from the retained cluster id — that shared
derivation is what makes selection across runs possible at all. Its own run scope differs and is meant
to; the selector records it and never matches on it. A focused case pins the two together against the
creating scope.

### Closure

All seven deliverables are landed and validated on this sprint's code-owned surface. Deliverable 6 —
deleting the superseded conversion path — is not this sprint's to perform, and saying so is the
correction that closed it.

**What this sprint does not do, and who owns it.** The exact-keyed selection is reachable from a host
cleanup run in both directions: the Authority route serves it, the transport client calls it, and
`selectRegisteredStackGenerationForCleanup` is the host lane (see
[Both Directions Are Reachable](#both-directions-of-the-generation-are-reachable-landed-2026-08-17)).
Converting the *existing* callers onto it is a different act, because each caller reaches its targets
through a composition that a later sprint deletes outright:

- `TestRunner` and `DurableCleanupComposition` → **Sprint `5.36`**, which already owns migrating the
  validation client onto the lifecycle-owned cleanup run and deleting the validation-owned executor.
- `runNativeDeleteCascade` → **Sprint `6.5`**, which already owns the single-writer cutover and the
  removal of the legacy generic/home path.

Converting them here would build the new selection on top of compositions those sprints delete, which
is why the work belongs with them rather than in front of them.

The unkeyed residue funnel and the ambient residue-absence path therefore stay live and stay
`Pending Removal`, owned by the sprints above.
[Standard I](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger) permits exactly
this: the replacement is complete while the superseded helper survives until its owner deletes it.

The landed exact modules — the generation, its durable join, the retained catalog, and both
production paths — are the replacement, not evidence that the public cascade stopped using the old
composition. The layer field from `4.81` remains valid; this sprint adds the exact object, key,
scope, and cardinality that layer alone could not express.

## Sprint 4.85: Desired-Absence Programs and Durable Cleanup Kernel [✅ Done]

**Status**: Done (implementation began 2026-08-15; closed 2026-08-18). All eight
operational-credential disposition blockers are retired, each by building the missing capability and
deriving the blocker from it rather than by deleting the reason: the Cascade-audit freeze has an
authenticated caller, the terminal escape audit is classified as a Lifecycle-provider consumer, every
legacy operational resource names its successor, the canonical target revocation read-back is a closed
decision table both revocation paths decide through, the operational surface compiles its own
credential revocation and that revocation's mandatory read-back, total decommission orders its
disposition strictly after its terminal audit, and a retained Provider operation names the cleanup
operation that authorized it. `OperationalTeardown` mints its own completion witness. Every surface
that states
the signed decommission node universe — the Authority's production plan, the signed
interpreter-registry identity, the per-node interpreter lookup, and the operator-approved `--dry-run`
plan — is derived from the closed enumeration rather than authored, and all four scheduled
decommission nodes have landed: the final no-retention escape audit, the home-substrate uninstall,
the operator's explicit `.data` retain-or-delete disposition, and the terminal receipt are the
ordered terminal phase of the signed receipt graph, with that order measured against the compiled
program rather than asserted once per implementation. Node cardinality is one derived classification
covering both the mandatory singletons and the one mandatory parameterized choice. The
descriptor-bound
kernel and major proof repositories are landed, the DNS01 Challenge/TXT obligation is pure data in
lifecycle-owned types, the harness-namespace import direction is gated, the mandatory decommission
singleton set is derived from its closed enumeration rather than authored, explicit per-run can mint
its own completion witness, and the per-run projection reaches the `dns-aws` validation hosted zone
the harness sweeps. Sprint `4.84`'s creation-generation and audit-catalog inputs are now closed and
consumable.
**Blocked by**: none. Sprint `4.84` closed 2026-08-17; its stable registered-stack lifecycle
generation and complete retained audit inventory are available.
**Deployment qualification**: pending — persistence, operation recovery, and cleanup execution change.
**Doctrine**: [Lifecycle Reconciliation Doctrine § 3.2, “Checkpoint recovery and the
desired-absence decision”](../documents/engineering/lifecycle_reconciliation_doctrine.md#32-checkpoint-recovery-and-the-desired-absence-decision),
[Lifecycle Reconciliation Doctrine § 3.3, “Result-indexed programs and the durable cleanup
graph”](../documents/engineering/lifecycle_reconciliation_doctrine.md#33-result-indexed-programs-and-the-durable-cleanup-graph),
[Pure FP Standards § 3.4, “Always-run work uses a DAG result
fold”](../documents/engineering/pure_fp_standards.md#34-always-run-work-uses-a-dag-result-fold),
and [Pure FP Standards § 7, “GADT-Indexed State
Machines”](../documents/engineering/pure_fp_standards.md#7-gadt-indexed-state-machines).
**Implementation**: `Prodbox.Lifecycle.Teardown.{Program,Graph,Execution,Report}`, lifecycle core
`CleanupRun`/`CleanupRunRunner`, `CleanupProgramDescriptor`, RecoveryCapability/Requirement, and
their bounded Authority repositories/clients now exist, alongside
`Prodbox.Lifecycle.Dns01Challenge` (pure desired-absence obligation),
`Prodbox.CheckCode.checkTestNamespaceBoundary`, the `DecommissionSingletonNode`/
`DecommissionChoiceFamily` cardinality join in `Prodbox.Lifecycle.Decommission.Manifest`, and
`Prodbox.Lifecycle.HostCleanupLocalData` (the retained-local-data terminal adapter), and
`decommissionRunTerminalEvidence`/`readBoundReceiptFramesReadOnly` (the terminal-convergence
read-back). Bidirectional total-decommission parity remains.
**Live-proof**: pending and non-blocking after code-local deterministic crash/response-loss
validation.
**Independent Validation**: total decision matrices, graph properties, fake interpreters, and
deterministic restart/cancellation schedules; no Phase 5 or 7 implementation is required.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/integration_fixture_doctrine.md`,
`documents/engineering/pure_fp_standards.md`, `DEVELOPMENT_PLAN/system-components.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Replace caller-injected actions and hand-authored phase folds with one result-indexed program
algebra and durable desired-absence kernel whose distinct surface-specific success constructors
require exact evidence.

### Current Implementation Checkpoint (2026-08-16, paused)

- `CleanupRun` and its index/stored aggregates have descriptor-bound v2 forms, retain v1
  compatibility where safe, and recover an opaque `DescriptorBoundCleanupRun` only after fresh
  authenticated descriptor read-back and exact recompile. Create/replay/scan/claim/node/primary/
  compact paths and response-loss repair are covered by focused tests.
- Canonical `CleanupProgramDescriptor` bytes retain surface, foundation, optional AWS scope,
  registry/compiler/capability versions, initial run, semantic operation map, and graph/catalog
  digests. Hidden rank-2 eliminators are the only restart path to a compiled program.
- Result-indexed Program/Graph/Execution/Report, RecoveryCapability/Requirement, RecoveryPlane,
  checkpoint, drain, registered-target, ownership, stack-reader, and surface-report foundations are
  present behind opaque facades. Public raw proof/remint seams found during the audit were closed.
- Route-local authenticated repositories `54` through `57` are additive; route `56` re-observes
  RecoveryPlane state and route `57` commits only an exact post-Begin Healthy host observation.
- The latest combined green kernel-era checkpoint was 610 library modules and 193 unit modules
  linked under `-Werror`; the last full unit runtime was 3921/3921 on the preceding source set.
- Unfinished work includes stable create-generation binding, atomic audit reservation plus durable
  read-back, credential disposition/revocation, Stage-C pre-uninstall report authority,
  descriptor-bound two-phase host absence/completion, total-decommission program parity, and
  deletion of the legacy callback clients.

### Deliverables

- Implement the total stack decision over exact provider inventory, primary/backup checkpoint
  observations, and ownership-manifest completeness: already absent; destroy from verified primary;
  restore backup then destroy; destroy from complete manifest; or refuse.
- Receipt-commit a bounded exact ownership manifest before the first provider/controller mutation.
  Append dynamic IDs and read them back before the owner may create another child. Index manifest
  writes/read-backs by `WriteAheadOwnership` versus `LegacyAdoptionOwnership surface`: only the
  former may authorize create/append, while either can be bound into cleanup only after exact
  target, surface, coordinate, and plan-digest agreement. A cleanup adoption receipt has no path to
  a future create.
- Define closed result-indexed teardown programs indexed by cleanup surface. A non-stack cleanup
  witness has no `Stack`/`LocalSubstrate` constructor; stack effects require checkpoint or manifest
  authority; local-only, cascade, explicit-per-run, operational, explicit-long-lived, and external
  decommission values cannot cross surfaces. The interpreter is total and admits no callback, raw
  shell command, ambient credential, `error`, or discarded `Left` path.
- Index escape-audit authority, scope, report, and clean evidence by cleanup surface. Only cascade
  and total decommission have an `AuditEscapes` authority: cascade binds its exact
  intentionally-retained projection, while total decommission admits no retained carve-out. Their
  clean witnesses cannot convert across surfaces; local-only, explicit-per-run, operational, and
  explicit-long-lived programs have no audit-authority constructor. The cascade audit constructor
  additionally requires the opaque aggregate of exact per-run, family, and operational-credential
  read-back, so scheduling the audit before convergence is unrepresentable.
- Allocate and receipt stable operation references before every registered desired-absence effect—
  including stack, controller-family, and singleton/direct-resource programs—and before every
  checkpoint-restore, checkpoint-retirement, cascade convergence-report, ordinary surface-report,
  local-uninstall, local-completion, decommission local-data, and decommission terminal-receipt
  effect. Mandatory `RequiresAttempt` read-back consumes the stable reference rather than the effect
  response, so applied-with-response-lost and process-loss arms remain expressible and resumable. A
  checkpoint restore outcome cannot mint the verified primary; only exact read-back through that
  reference can.
- Add the checkpoint retirement/quarantine program selected only by an opaque authorization that
  already contains exact stack-absence evidence; retirement effect success still requires its own
  read-back.
- Bind a legacy-adoption plan and admin permit into one opaque request only after exact target,
  candidate-set, rendered-plan digest, permit ID/expiry, and cleanup scope agree. The interpreter
  never accepts the plan and permit as independently composable values.
- Promote the generic cleanup journal, fencing, stable node operation IDs, scanning, report, and
  compaction from the test namespace into lifecycle core. Validation becomes a client.
- Give cascade, explicit-per-run, operational, and explicit-long-lived their own closed recovery-
  plane authority constructors; local-only and total decommission have none. Give the three
  non-cascade ordinary cleanup surfaces closed commit/read-back report programs over stable
  references so their required `SurfaceCompletionReceipt surface` values are actually producible.
- Derive every `RequiresSuccess`/`RequiresAttempt` edge from registry ownership, dependency,
  storage-lifetime, and credential-lifetime facts. Delete lifecycle-owned fail-fast/sequential
  cleanup projections; Sprint `5.36` owns migration and removal of the `TestRunner` client-side
  projection after this kernel exists.
- Give `ReadyToUninstallEvidence` a private constructor requiring exact per-run/family absence,
  complete credential disposition, an opaque `TerminalAuditEvidence` that is either a clean exact
  intended-retained AWS audit or a private complete no-AWS-target projection, a backed-up/read-back
  pre-uninstall report, and a one-shot local-completion permit. Give `CascadeCompleteEvidence` a separate private constructor
  requiring that readiness witness, exact `LocalUninstallEvidence`, and a read-back
  `LocalCompletionReceipt`. Every witness must bind the same `CleanupRunId`, registry revision,
  account, region, substrate, operation scope, and report digest; merely completing an audit or
  uninstall call is not clean or complete evidence.
- Admit total-decommission local uninstall only from private
  `ReadyForDecommissionLocalUninstall`, minted after the external receipt proves every node that
  still needs the home Agent, Vault, Gateway, cert-manager, or control-plane service terminal. The
  external decommission permit alone cannot authorize local uninstall; exact local absence, final
  backup-store work, and the no-retention total audit remain separately ordered evidence.
- Extend the signed decommission manifest/`DecommissionProgramTag`/required-node registry and
  external receipt graph with home-substrate uninstall/read-back, explicit `.data` retain/delete/
  read-back, final no-retention audit, and terminal-receipt append/read-back. Delete the current
  out-of-band `runNukeTerminalTagSweep` tail only after the closed runner owns it; no decommission
  interpreter effect may exist without a manifest tag and result-indexed source case. The pure
  compiler maps one semantic operation to one tag. It fuses the lifecycle graph's distinct effect
  and `RequiresAttempt` read-back nodes, plus their stable operation reference, into the runner's
  one resumable program for that tag; the runner operation owns effect plus read-back and returns
  the final observation. Generic registered destroys select provider, TLS, and Authority-backup
  tags through their closed registry program tags.
- Define separate complete/incomplete result types and private completion evidence for local-only,
  cascade, explicit-per-run, operational teardown, explicit-long-lived, and total decommission.
  Explicit per-run requires selected-stack/child-family absence plus checkpoint disposition;
  operational requires consumer quiescence, credential/lease absence, and retained-dependency
  observation; explicit long-lived requires its aggregate permit, aggregate/family absence,
  credential/tombstone and checkpoint disposition; total decommission requires non-local absence,
  exact local absence, no-retention audit evidence, explicit local-data disposition, and external
  terminal-receipt read-back. No generic exit-zero wrapper or cross-surface conversion can mint
  completion.
- Model cascade, explicit-per-run, operational, and explicit-long-lived incomplete results with
  surface-indexed `RecoveryPlaneDisposition`: `Established`, `NotEstablished`, or `Lost`. Private
  incomplete-evidence minters seal the stable run ID, disposition, and scope-bound nonempty failure
  set together; values from different runs/surfaces cannot be paired. A local-only incomplete result
  carries only its bound local-delete evidence; total decommission carries its separately bound
  `DecommissionRunnerDisposition` and decommission failures. No result can promise that a recovery
  or decommission plane which failed to establish or was subsequently lost remains live.

### Validation

1. Exhaustive provider-inventory × checkpoint-pair × manifest table covers every constructor once.
2. Graph properties prove coverage, uniqueness, acyclicity, stable IDs, credential lifetime, and
   that sibling failure cannot suppress an independent or attempt-dependent node.
3. Crash/response-loss/cancellation is injected before and after every durable transition and every
   registered stack/controller-family/direct-resource desired-absence, checkpoint, cascade-report,
   surface-report, local, decommission-local-data, and decommission-terminal-receipt effect; the
   same operation reference resumes read-back without requiring the lost return value or
   duplicating mutation. A lost checkpoint-restore response cannot suppress primary read-back or
   directly produce `VerifiedCheckpointRef`; a lost cascade-report response cannot directly
   produce `PreUninstallCommit`.
4. A provider exit zero without exact absence cannot construct success; a corrupt checkpoint cannot
   be pruned before exact resource absence, and a checkpoint-retirement exit cannot replace its
   read-back.
5. A no-AWS registry projection can construct the no-audit terminal witness; an AWS-bearing scope
   cannot. Missing credentials, empty tag output, and failed audit cannot construct that witness.
6. Surface-indexed audit tables prove only cascade and total decommission can construct
   `AuditEscapes`; a clean cascade audit with its exact retained set cannot satisfy total
   decommission, a total audit refuses any retained resource, and neither escaped nor unobservable
   reports can mint either clean witness. Cascade audit authority cannot construct before the exact
   per-run/family/operational convergence aggregate exists.
7. Wrong-surface targets and wrong-plan legacy permits fail at the smart-constructor/export
   boundary; compile tests show no generic stack/local destroy constructor exists. Total
   decommission local uninstall also fails without matching
   `ReadyForDecommissionLocalUninstall`, including when the external permit is otherwise valid;
   the readiness witness cannot be minted while any home-plane-dependent node is non-terminal.
   Observer-program construction requires the same opaque scope for exact-resource, checkpoint-
   pair, ownership-manifest, and legacy-adoption requests; compile tests also prove only the EBS
   target projections admitted by `4.84` can enter their corresponding cleanup programs.
8. Surface-completion matrices exercise the complete and every incomplete arm for explicit
   per-run, operational teardown, explicit long-lived, and total decommission. Missing, wrong-run,
   or cross-surface evidence refuses; a completion witness for one surface cannot construct any
   other surface's result. Each ordinary explicit surface can establish/observe its own recovery
   disposition and commit/read back its own report; incomplete evidence rejects a run/disposition/
   failure scope mismatch. These are generic kernel/fake-interpreter proofs and require no Phase 5
   client or Phase 7 AWS adapter.
9. Manifest provenance compile tests prove a legacy-adoption write/read-back cannot enter
   `SubmitRegisteredCreate` or write-ahead append, cannot bind to a different cleanup surface, and
   can enter desired absence only through the digest-bound cleanup binder. Write-ahead append also
   requires the exact registry ownership edge, so a present resource from stack A cannot enter
   stack B's manifest.
10. Decommission registry/compiler parity is measured in both directions over the complete closed
    tag universe. Every total-decommission source operation or registered projection maps to
    exactly one semantic tag; every `DecommissionProgramTag` has exactly one source operation,
    runner program, manifest dependency relation, interpreter, and receipt codec **on whichever
    side implements it**; no tag is implemented by neither side; and the authored implementation
    claim is checked against both *measured* images rather than trusted, so a claim cannot survive
    the side it names not producing the tag. The table covers managed resources, target
    generations, SES/EAB custody, TLS and Authority-backup tails, home uninstall, local-data
    disposition, final audit, and terminal receipt. Compiler tests prove each lifecycle graph
    effect/read-back pair and stable reference fuse into its one resumable runner program; they do
    not equate lifecycle graph-node count with tag count. Crash/response loss before and after each
    resumes the same stable operation; source scans prove `runNukeTerminalTagSweep` and every other
    out-of-graph terminal effect are absent.

    **Convergence is not this sprint's item.** Requiring every tag to be implemented by *both*
    sides would require the compiled program and the signed manifest to become one universe — the
    single-writer cutover Sprint `6.5` owns, over adapters Sprint `7.36` owns. Read that way, item
    10 could not pass on Phase 4's owned surface, which
    [Standard N](development_plan_standards.md#n-phase-independence-and-execution-order) forbids;
    it is re-scoped to `6.5` as of 2026-08-18. What this phase owns and proves is that the
    measurement exists, is exact, and fails the build when the claim and the two images disagree.
11. The old `ManagedResource`/`CapabilityBoundCleanupAction` callback shapes and test-owned generic
   kernel are absent from supported production composition.

### Explicit Per-Run Can Report Completion (landed 2026-08-17)

`SurfaceCompletionEvidence` had exactly one constructor, for `Cascade`, so no ordinary cleanup
surface could report completion at all — its `Done` arm was unreachable regardless of how the run
went.

Explicit per-run is the one ordinary surface whose obligation is *fully determined by the compiled
program*, and that is a structural fact rather than a convenience. Cascade completion is not implied
by its own read-backs: it additionally uninstalls the local foundation and must produce a read-back
`LocalCompletionReceipt`, which is why it carries a separate `CascadeCompleteEvidence` chain.
Explicit per-run has no local-uninstall arm. Its whole obligation is the registered per-run targets
and its own report — and `classifyDesiredAbsenceReportInternal` already refuses to produce a complete
read-back set unless every mandatory read-back succeeded, where `operationIsMandatoryReadBack`
includes `ReadBackRegisteredTargetAbsent` (every per-run stack and the per-run EBS family),
`ReadBackStackCheckpointRetirement` (the checkpoint disposition the deliverable names), and
`ReadBackOrdinarySurfaceReport` (this surface's own committed report, independently read back).

`completeExplicitPerRunDesiredAbsence` is therefore a minter over that evidence rather than a
gatherer of new evidence. Cross-surface conversion is prevented by the index: the function is typed
at `'ExplicitPerRun`, so it cannot be applied to another surface's read-backs, and each
`SurfaceCompletionEvidence` constructor fixes its own index. Two things are re-checked rather than
assumed, and both are arms classification cannot produce — so only a mis-minted value could carry
one: the evidence's surface tag, and an `Established` recovery plane. A surface that cannot say its
recovery plane held has made no liveness claim and may not report clean completion.

The fixed regression records four facts, including that the per-run program's mandatory read-backs
genuinely contain both target absence and checkpoint disposition — without which the completion claim
would be true but empty.

**The other two ordinary surfaces still have no minter, and the reason is missing evidence rather
than missing typing.** `OperationalTeardown` projects **zero** registered targets, because
`cleanupSurfaceAllows` admits only `Operational`-class descriptors and the typed registry contains
none; minting completion there would be a clean-completion claim over an empty projection — the shape
this phase exists to remove. `ExplicitLongLived` requires the aggregate operator permit its
deliverable names, and that permit has no type. Registering the operational descriptors is separately
constrained: `OperationalCredentialDispositionBlocker` documents that the current graph asks for
disposition *before* the audit while the audit doctrine requires the credential live *through* it, so
a naive registration would compile exactly the illegal ordering that module exists to refuse.
*(Superseded 2026-08-18: every disposition blocker is retired, the compiled decommission program
orders its disposition after the audit, and `OperationalTeardown` mints completion over the credential
revocation's own read-back rather than over registered targets.)*

### The Mandatory Decommission Node Set Is Derived (landed 2026-08-17)

Validation item 10 requires bidirectional parity across the complete total-decommission universe.
That universe is about to grow: the deletion ledger's decommission row schedules four further nodes —
home-substrate uninstall/read-back, explicit `.data` retain/delete/read-back, the final no-retention
audit, and terminal-receipt append/read-back — none of which exists yet.

The verifier that will have to require them was not ready for that. Every singleton `DecommissionNode`
is mandatory, because a manifest that omits one authorizes a decommission that provably leaves that
resource class behind, and `requiredSingletonNodes` in `Prodbox.CLI.Nuke` enforced it as a
hand-authored list of nine joined to nothing. A newly added singleton constructor would therefore have
been **silently optional**: the verifier would accept a signed manifest that never names it, and the
run would report success having never executed it. That is the precise failure mode the four scheduled
nodes would have walked into.

`DecommissionSingletonNode` is now the closed enumeration of that half of the node universe, with
`decommissionNodeSingleton` total over `DecommissionNode` — so adding a node constructor is an
exhaustiveness failure until it is deliberately classified as mandatory singleton work or as
parameterized work — and `requiredSingletonDecommissionNodes` derived from it rather than authored
beside it. `decommissionSingletonNodeBijection` pins both directions, because a one-directional map
would still produce a nine-element list while demanding the wrong nodes.

It is a separate type rather than a restructuring of `DecommissionNode`, and deliberately so:
`DecommissionNode` derives `Serialise`, and its serialization feeds both `decommissionNodeFrameId` and
the signed manifest digest, so changing its constructor shape would change every historical frame ID
and manifest signature — a Standard-P identity change for a check that needs none. `TargetGeneration`
stays outside the enumeration: it is parameterized by target reference and generation, so a run names
as many as it has Agents and none is individually mandatory.

This does not add the four scheduled nodes. It makes adding them a change the verifier cannot ignore.

### The Harness Namespace Is No Longer a Production Type Source (landed 2026-08-17)

`Prodbox.Test.*` is the validation harness — fixtures, fake interpreters, and the harness's own
cleanup composition. It lives under `src/` because the harness ships in the binary, not because it
is supported production composition, and until now that distinction was only a convention.

It had already been crossed. `Prodbox.Lifecycle.Dns01Challenge` — a lifecycle module, not a harness
module — imported `Prodbox.Test.ManagedCleanupPlan` to express its cleanup edge, so a production
teardown obligation was typed in a shape the harness owned. Two things closed it:

- **The DNS01 obligation is data in lifecycle-owned types.** Sprint `5.29` registered the challenge
  as a `ManagedResource` built from two caller-supplied `FilePath -> IO` closures. That shape had
  two defects independent of whether it worked: a caller could substitute the effect *after* the
  registry entry was projected, so registry membership did not determine one legal program; and the
  edge came from the harness namespace. Neither closure was ever wired to a production caller, so
  removing them lost nothing. `Dns01ChallengeDesiredAbsence` now carries the coordinate, the
  `CleanupNodeId`, and an always-run `CleanupRequiresAttempt` `CleanupDependency` as a value, and
  `dns01ChallengeDesiredAbsenceOutcome :: DnsRecordObservation -> Dns01ChallengeAbsence` makes the
  delete result structurally incapable of entering the verdict — the property the old `IO` version
  asserted in a comment. Everything Sprint `5.29` actually established survives unchanged: the
  exact pre-issuance coordinate, the three-valued absence classification in which *unobservable is
  not absence*, and the always-run edge.
- **The direction is now non-constructible.** `checkTestNamespaceBoundary` fails
  `prodbox dev check` when any module under `src/Prodbox/` outside the harness namespace imports
  `Prodbox.Test.*`. `validationHarnessClientModules` is an enumerated allowlist — `TestRunner` and
  `TestValidation`, the harness entrypoints that are its clients — deliberately not a pattern, so
  widening it is a visible edit rather than a naming accident. Sprint `5.36` removes the
  `TestRunner` entry when it migrates the validation client onto the lifecycle-owned kernel.

What this does **not** close: the challenge family still has no `RegisteredResourceKey`, so
`compileDesiredAbsenceProgram` emits no node for it and the response-loss/restart proof in the
generic cleanup report is still owed. Its ledger row stays `Pending Removal` for that half.

### The Per-Run Projection Reaches What the Harness Actually Sweeps (landed 2026-08-17)

Sprint `5.36` migrates `TestRunner` onto the lifecycle-owned cleanup run, which is only correct if the
compiled program can express what the harness cleans. Measuring the two against each other found the
per-run projection **short by one billable resource**.

The `dns-aws` validation hosted zone is registered in the flat lifecycle inventory as
`dns-aws-validation-hosted-zone :: PerRun`, has a dedicated owner module holding its create, delete,
absence read-back, and prefix sweep, and is swept by an always-run node in the harness's own cleanup
graph — the graph Sprint `5.36` deletes. It had no typed registry descriptor, so
`compileDesiredAbsenceProgram` emitted no node for it on any surface. Migrating the harness before
registering it would have deleted the only thing sweeping a billable Route 53 zone.

**The join that would have caught this is now closed.**
`managedResourceRegistryParityViolations` runs typed → flat, and cannot see a flat row the typed
registry never registered — so the omission read like a decision. `untypedLifecycleInventoryViolations`
runs flat → typed: every flat row without a typed descriptor must carry a stated reason in an
enumerated exemption list, and a stale exemption for a resource that *is* now registered fails too. The
nine current exemptions are the dynamic Pulsar topic families, the superseded Harbor release, the
long-lived SES stack and retained TLS material, the `dns-aws` validation hosted zone (see the next
section), and the three operational credential rows whose descriptors
`OperationalCredentialDispositionBlocker` still constrains. *(Corrected 2026-08-18: the three
operational rows are the pre-cutover identity, whose successor is now declared — registering them
would make a superseded identity a target of the supported registry, so their exemption reason is
the legacy replacement rather than the retired blockers.)*

The correction that measurement asked for is a Sprint-`7.36` adapter plus a registration, not a
registration alone. The section below records why, and what makes the difference non-constructible.

### A Registered Target the Production Interpreter Cannot Execute (landed 2026-08-17)

Registering a descriptor is not a neutral act. `compileDesiredAbsenceProgram` emits three nodes for
each one — observe, reconcile-absent, and a **mandatory** absence read-back — and
`classifyDesiredAbsenceReportInternal` refuses a complete read-back set unless every mandatory
read-back succeeded. A surface that mints completion evidence is therefore asserting all of them
succeeded.

`Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter` dispatched its three entry points on
ad-hoc `(kind, key)` guards — `Stack` with an `AwsEksKey` special case, `VolumeFamily` guarded on the
**per-run** EBS key — and fell through to a refusal. The refusal is right. The silence is not:
nothing joined the keys those guards cover to the keys the registry contains, so a descriptor could
be registered with no executor behind it, and the only symptom was a node that always failed. In a
teardown report that reads exactly like infrastructure that refused to go away.

Measured against the registry, two of the six registered descriptors had no executor. The retained
EBS family (`AwsEbsProductionRetainedKey`) has had none since it was split out, and the omission was
harmless only because it projects onto `ExplicitLongLived` and `TotalDecommission`, neither of which
can mint completion. The `dns-aws` validation zone registered earlier the same day is `PerRun`, so it
projects onto `Cascade` and `ExplicitPerRun` — and there the same gap is fatal: `cascade/audit-escapes`
requires `success` on every target's completion node, so **the cascade could no longer reach its
terminal audit, and the `ExplicitPerRun` completion minter landed in this same sprint could never
fire.** The registration achieved nothing operationally — no adapter existed to sweep the zone
either — while making both programs unsatisfiable.

`Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor` is the join.
`registeredTargetExecutorFor :: RegisteredResourceKey -> Either UnexecutableRegisteredTarget
RegisteredTargetExecutor` is total over the closed key enumeration, so adding a key is an
exhaustiveness failure until someone states which executor runs it. It is keyed on the registry key
rather than the resource kind deliberately: the kind says what shape a resource has, and the executor
is a fact about which adapter was actually built — dispatching on kind is what let a newly registered
`Singleton` reach a fall-through without anyone noticing. The interpreter's three entry points now
dispatch on that function, so the classifier and the interpreter cannot disagree, and the two
unexecutable arms stay distinct: a key that should never reach this interpreter (the local
foundation) and a key whose adapter is unbuilt are different defects with different owners.

`Prodbox.CheckCode.registeredTargetExecutorViolations` gates it, and the gate is a **derivation
rather than an exemption list**: a gap is reported only when the key projects onto a surface for which
`cleanupSurfaceMintsCompletionEvidence` is `True`. There is one total function, so a stale exemption
is not representable — a key that gains an executor stops being reported by construction, and the
retained EBS family stops being admissible the moment `ExplicitLongLived` or `TotalDecommission`
gains a minter.

The `dns-aws` registration is therefore withdrawn and its flat-inventory exemption restored, naming
Sprint `7.36` — which owns the exact AWS desired-absence adapters — as the owner of both the Route 53
hosted-zone adapter and the registration that depends on it. This follows
[Standard N](development_plan_standards.md#n-phase-independence-and-execution-order) rather than
merely tidying: a Phase-4 registration whose program cannot complete until a Phase-7 adapter lands
would have made Sprint `6.5`'s cutover depend on a later phase. **The precondition the measurement
found is real, and since 2026-08-21 it is Sprint `5.36`'s declared `**Backward dependency**` on
Sprint `7.36`** (Standard N.2): the harness sweep is still the only thing removing that billable
zone. It is stated once, in that sprint's field. The 2026-08-21 audit found this paragraph was one of
three prose copies of a dependency no gate could read.

### The Write-Ahead Manifest Named the Wrong Owning Stack (landed 2026-08-17)

A deliverable of this sprint is to *derive* every `RequiresSuccess`/`RequiresAttempt` edge from
registry ownership facts rather than author them. Reading the ownership fact itself found it stated
three times and wrong once.

`registeredOwnershipEdges` was a one-element literal: `RegisteredOwnershipEdge AwsTestKey
AwsEbsPerRunTestKey`. The per-run test EBS family's registered coordinate is keyed on
`kubernetes.io/cluster/aws-eks-test-cluster=owned` — the tag AWS applies to volumes an EKS cluster's
controllers provision. `pulumi/aws-test/Main.yaml` declares no cluster at all;
`pulumi/aws-eks/Main.yaml` declares the cluster (`clusterName: ${stackName}-cluster`) **and** installs
the EBS CSI driver that creates them. `Prodbox.Lifecycle.Teardown.Program` already ordered the family
against the **EKS** stack on both sides — the family's observation waits on the EKS drain attempt, and
the EKS destroy waits on the family's absence read-back — so two of the three statements said EKS and
the one that authorizes manifest membership said `aws-test`.

**The consequence is operational, not cosmetic.** `initialManifestEntries` seeds a stack's write-ahead
ownership manifest with its owned resources, and `projectRegisteredOwnershipEdge` is what admits a
discovered resource into that manifest. So the `aws-eks` manifest could not record the EBS volumes its
own cluster created — the exact recovery evidence the manifest exists to carry when both checkpoint
copies are unusable — while the `aws-test` manifest could legally adopt volumes that stack never
creates.

The relation is now computed from the two registry coordinates that already contain the answer.
`coordinateControllerOwnerCluster` reads the owning cluster out of a family's ownership tag and
`coordinateProvisionedClusterName` gives a stack's Pulumi stack name the suffix
`pulumiEksClusterNameSuffix`, which is the one place `pulumi/aws-eks/Main.yaml`'s naming rule is
written down. Both are total over the coordinate universe, so a new coordinate shape is an
exhaustiveness failure until someone states whether it has a controller owner. `owned` and `shared`
are deliberately distinguished: a shared resource outlives the cluster by design and has no controller
owner to order a teardown against.

`Prodbox.Lifecycle.Teardown.Program` now reads the same relation instead of testing
`== AwsEbsPerRunTestKey` and `== AwsEksKey` inline, so the manifest a stack may seed and the order its
destroy waits on cannot disagree. The compiled programs are byte-identical — this half is a refactor
onto a derived source, and the manifest half is the fix. What stays representable is a family whose
ownership tag names a cluster no registered stack provisions: that produces no edge, and an absent
edge is indistinguishable at the edge list from a family with no controller owner, so
`ownershipEdgeDerivationViolations` fails `prodbox dev check` on it rather than letting it read as
"no owner".

### The Terminal-Audit Freeze Has a Transition (landed 2026-08-17)

The deletion ledger's terminal-audit row names a deadlock: audit-pending-before-freeze refuses the
freeze, freeze-before-audit refuses the fresh audit submission, and audit-before-freeze races new
consumers. `ProviderAdmissionEpoch` retained the frozen shape, its validation, and its view, and
exported no transition into it — so the state was unreachable and the deadlock unexercised.

Everything the freeze needs was already in one place. The aggregate that the Provider submission path
reads holds both the admission epoch and `authorityAggregateProviderOperations`, and
`stepRegisteredProviderSubmission` already refuses every fresh submission once the epoch is frozen. So
the freeze is an `AuthorityAdmissionCommand` over that same aggregate, which is what makes it atomic
with its own pending-work proof: `aggregatePendingProviderWork` projects the pending set in the same
step that fences, leaving no window in which a submission is accepted between the proof and the fence.
The proof is read from the aggregate rather than supplied by the caller, so a caller cannot understate
what is in flight.

Four decisions in the transition are ones no type would otherwise catch, and each is a fixed
regression:

- **A freeze must name the generation it fenced.** `LegacyServingUnbound` refuses, because a later
  revoke could not prove which generation it revoked. `BindProviderAdmissionGeneration` is the
  companion command that makes `Serving` reachable; it is idempotent on the same generation and
  refuses a different one rather than replacing it.
- **Freezing over pending work is refused.** The fence would block the retries that would settle
  already-admitted operations. Completed records do not count — they exist so a response-loss retry
  returns the durable outcome.
- **An identical freeze is idempotent, a different binding is refused.** A lost response must not burn
  a second reservation, and a second freeze must not silently replace the reservation the first one
  committed.
- **The fence honours its own reservation.** The gate previously refused *every* fresh submission when
  frozen, which would have fenced the terminal audit the freeze exists to run — the frozen state would
  have been a dead end. `providerAdmissionFreshSubmissionRefusalInternal` now takes the submission key
  and admits exactly the keys the binding reserved. Revocation still admits nothing: there is no
  credential left to execute a reserved submission with.

Both commands are appended to `AuthorityAdmissionCommand`, so every earlier constructor keeps its
`Serialise` index and no historical command re-decodes as a different one. Nothing public mints,
transitions, or reserves.

**No authenticated route issues either command**, so no production caller can reach the frozen state —
and that is now what the disposition blocker says. `AbsentDispositionCapability` was refined from
"exports no transition into its Cascade-audit frozen state", which this increment made false, to
"no authenticated route issues the Cascade-audit freeze command". A reason that stops being true has to
be corrected in the same change, which is exactly what the increment before this one made visible.

### The Disposition-Blocker List Now Recomputes Itself (landed 2026-08-17)

`operationalCredentialInventoryDispositionBlockers` is the stated reason `OperationalTeardown` has no
registered descriptors, and therefore the reason its completion minter is one of this sprint's named
remaining items. It was eight hand-authored constructors whose only consumer was a unit case asserting
the list equalled itself. A blocker that stopped being true would have gone on justifying the same
omission — the exact staleness `OperationalCredentialCoverage` already refuses for the consumer
inventory beside it.

`dispositionBlockerEvidence` is total over the closed blocker universe and says how each one is
established, and the distinction is the point rather than bookkeeping. Four are **recomputed** from
sources: two from the compiled teardown programs, one from the credential-consumer classifier, and one
from `legacyOperationalIdentityStatus`. Four rest on a **type-level absence** — a missing constructor
or transition that no value in this repository can witness — and `AbsentDispositionCapability` names
each missing capability instead of letting them read as measured.

The two program-derived blockers are now stated precisely enough to be checkable, and stating them
that way sharpened them. `DispositionBeforeAuditConflictsWithLiveAuditCredential` holds because the
compiled `OperationalTeardown` program contains **no terminal audit node at all**, so scheduling
disposition there disposes before any audit runs.
`AuditBeforeDispositionConflictsWithCurrentCascadeGraph` holds because no `TeardownOperation`
constructor disposes of the credential, so the audit-then-dispose order cannot be expressed on the
surface that owns the audit — the disposition half has no operation.
`teardownOperationIsCredentialDisposition` is total and answers `False` everywhere today; adding a
disposition operation is what should retire that blocker, and that predicate is where the decision
lands.

`validateOperationalCredentialCoverage` now compares published against measured in both directions and
fails `prodbox dev check` on a stale or an unpublished blocker. The fixed regression records the
discriminating facts alongside the agreement: the audit predicate finds the cascade audit, so "the
operational surface has no audit" is a measurement rather than a predicate that never matches, and it
does not match a non-audit operation.

This does not register the `Operational` descriptors. It makes the four reasons that would stop being
true say so.

### The Third Creation Surface Was Outside the Audit's Field of View (landed 2026-08-17)

Sprint `4.84` closed two of the three surfaces that create prodbox-owned AWS resources. The
field-of-view gate reads every `pulumi/*/Main.yaml` and fails on a taggable declared resource that
authors no queried tag; the Provider Worker's SES capture-bucket intent was given the tags its
retained catalog already assumed. A resource created by a **direct AWS call in `src/`** is covered by
neither — no provisioning program declares it, so the disk-reading gate cannot see it.

The `dns-aws` validation hosted zone is exactly that. `Prodbox.Infra.Route53ValidationZone` created it
with `--name` and `--caller-reference` and **no tag at all**, so a leaked billable Route 53 hosted zone
was returned by no audit query while a clean `TerminalAuditConfirmedClean` read like a statement that
it was gone. Nothing but the missing call stood in the way: Route 53 hosted zones are taggable,
`TaggingApiReach` already classifies `aws:route53:Zone` as returned from the global-service region,
and the registered IAM policy already grants `route53:ChangeTagsForResource` and
`route53:ListTagsForResource`.

`CodeCreatedAwsResource` in `Prodbox.Lifecycle.OwnedResourceTags` is the closed enumeration of that
surface, and the writer takes its tag set from it rather than spelling one out — the same single-source
discipline the retained buckets already use, so the writer, its read-back, and the audit's query
catalog hold one value. `codeCreatedResourceFieldOfViewViolations` gates it: both sides are values, so
the join is exact — at least one authored family must be covered by `terminalAuditQueryCatalog`, and a
member authoring nothing is reported. Adding a code-created AWS resource means adding a constructor,
which is what puts it inside the gate.

The tags carry none of the retention markers, so a surviving zone classifies as an escapee rather than
as intentionally retained. The create now fails when tagging or its read-back fails, and deliberately
does **not** delete the zone in that case: discovery is by the prefix that is also its caller
reference, so the always-run sweep still removes it, and reporting the failure while leaving a
prefix-discoverable zone is strictly safer than reporting success with a zone the audit cannot see.

This changes live audit behaviour: a leaked validation zone now surfaces as an escape where the sweep
previously returned nothing — and only from the global-service region, which is the bound Sprint
`4.84` recorded rather than closed.

### One Compiled Source for the Stack and Cluster Names (landed 2026-08-17)

Correcting the ownership relation surfaced what it rested on. The per-run Pulumi stack names were
written down in the typed registry coordinates, again in `Prodbox.Lifecycle.LiveResidue`, and a third
time in `Prodbox.Infra.AwsEksTestStack`; the EKS cluster name was derived independently in
`AwsEksTestStack` **and** spelled out inside the per-run EBS family's cluster ownership tag. Four
statements of two facts, joined to nothing. They agreed, so this is a cannot-drift correction rather
than a repaired disagreement — but the cluster name is not decorative: it is the tag the EBS reaper
filters on and the coordinate controller ownership is now derived from, so a rename that split them
would have silently unaddressed a billable family.

`Prodbox.Lifecycle.Teardown.Registry` is now the compiled source. It names the three per-run stack
names, derives each Pulumi project as `prodbox-<stack name>`, derives the EKS cluster name from the
stack name plus `pulumiEksClusterNameSuffix`, and **builds the EBS family's ownership tag from that
derived cluster name** — so "the EKS stack owns this family" is true by construction rather than a
claim the ownership derivation has to discover. Every rendered coordinate is byte-identical, so no
coordinate digest moves. `LiveResidue` and `AwsEksTestStack` became projections, which GHC keeps
equal without a gate. `aws-ses` stays authored in `LiveResidue`: it has no typed descriptor until
Sprint `7.36`, so there is no coordinate to project it from.

The remaining half is a fact about disk, so it is a gate rather than a derivation.
`checkRegisteredStackProvisioningPrograms` reads the `name:` field of every `pulumi/*/Pulumi.yaml` —
the field Pulumi itself resolves, rather than the directory layout, which does not match the stack
names — and fails `prodbox dev check` when a registered stack names a project no program declares, or
when a coordinate's project and stack names disagree with the derivation. A registered stack with no
provisioning program can never be reconciled or destroyed, and its compiled desired-absence nodes
would fail for a reason no teardown report distinguishes from live infrastructure. A mutation
exercise over an empty `pulumi/` tree pins that the gate reports one violation per registered stack
rather than passing vacuously.

### Total-Decommission Parity Is Measured, and the Two Universes Are Disjoint (landed 2026-08-17)

Validation item 10 requires bidirectional parity across the complete total-decommission universe.
Nothing measured it, and the reason it went unmeasured is that "total decommission" is described in
two places that had never been compared:

- `compileDesiredAbsenceProgram TotalDecommissionSurface` emits a closed result-indexed program over
  the **typed registry** — the registered AWS targets, the local foundation uninstall and its
  read-back, the final escape audit, the external receipt observation, the `.data` disposition, and
  the terminal receipt.
- `Prodbox.Lifecycle.Decommission.{Manifest,Graph,NodeEffect,Runner}` runs a signed `DecommissionNode`
  inventory — SES quiescence and destroy, the external SMTP IAM family, per-Agent target-generation
  tombstones, retained-home custody, the retained TLS objects and their identity, the Authority
  backup objects and their all-prefix absence proof, and the shared object bucket.

`Prodbox.Lifecycle.Decommission.ProgramTag` is the semantic layer over both.
`DecommissionProgramTag` is the closed enumeration of total-decommission *operations* — the effect
and its mandatory read-back fuse into one tag, because a lost response is recovered by re-reading
through the same stable operation reference rather than by re-running a second graph node, so tag
count is deliberately not graph-node count. `decommissionNodeProgramTag` and
`totalDecommissionOperationProgramTag` are total and their result type **is** the enumeration, so the
forward direction is a compile error: a new node or operation cannot be added without saying which
semantic operation it is.

The reverse direction is a measurement rather than a declaration.
`validateDecommissionProgramTagParity` compiles the total-decommission program, takes the manifest
node universe from `requiredSingletonDecommissionNodes` — itself derived from the closed
`DecommissionSingletonNode` enumeration, so a newly added singleton reaches the measurement without
anyone editing it — and checks the authored `decommissionProgramTagImplementation` claim against both
images. A claim that a tag is implemented on one side cannot survive the other side producing it, a
tag no side produces is reported, and a compiled node whose operation maps to no tag is reported
too. The unmapped constructors are exactly the surface-polymorphic recovery-plane and ordinary-report
shapes this surface never emits, so one appearing means the program grew a shape the semantic
universe does not name.

**The measurement is the finding: the two images are disjoint.** Twenty-one tags, zero overlap. The
compiled program would destroy the registered AWS targets and uninstall the home foundation while
never touching SES, the retained TLS material, the Authority backup, or the shared object bucket; the
runner does the converse while never proving the final no-retention audit or appending a terminal
receipt. Neither alone is a total decommission. That is the same gap the deletion ledger's
decommission row records in prose — a prose sentence cannot notice a node being added, and this can:
implementing any of the four scheduled nodes flips its tag from `CompiledProgramOnly` to
`CompiledProgramAndRunner` and fails `prodbox dev check` until the claim is updated in the same
change.

This does not implement the four scheduled nodes. It makes the size and shape of the remaining work a
derived value, and makes closing any part of it a change the build notices.

### The Signed Node Universe Is Derived on Every Surface That States It (landed 2026-08-18)

The previous increment derived the mandatory-singleton set from a closed enumeration and recorded
that adding a node would be "a change the verifier cannot ignore". Only one surface had been closed.
The same universe was written down five more times, in three naming schemes, joined to nothing:

- **The signed interpreter-registry identity.** `nukeInterpreterRegistryIdentity` is digested into
  `VerifierMetadata`, so the operator's signature covers which interpreters the runner was built
  with. It was a flat list of ten strings sitting beside `nukeNodeProgramTag`, a `case` of the same
  ten, with neither joined to the node universe: a node implemented with a new interpreter would have
  been absent from the signed identity while a manifest naming it still verified. The only check
  between the two was `not (ByteString.null (nukeNodeProgramTag node))` — a non-empty-literal test no
  arm could fail. `decommissionRunnerInterpreterIdentity` is now the source; the per-node lookup is
  its projection through `decommissionNodeProgramTag`; the registry list is derived in tag order; and
  `decommissionInterpreterIdentityViolations` gates `dev check` in both directions — a
  runner-implemented tag with no identity, and an identity for a tag no manifest node reaches, are
  each violations. `validateProductionManifest` now refuses a node whose tag has no compiled
  interpreter identity, which is a reachable arm.
- **The Authority's production plan.** `Prodbox.ControlPlane.Runtime` authored a three-element prefix
  and a six-element suffix around the optional Target Agent generation. That is the *producer*; the
  derived set is enforced by the *verifier*. A newly added singleton would have been demanded by one
  and never signed by the other, and the fail-closed refusal arrives inside the interactive run —
  after the point-of-no-return confirmation literal and the ephemeral admin credential — as
  "Authority signed an incomplete production decommission manifest".
  `productionDecommissionPlanNodes` derives membership from the closed singleton enumeration and
  placement from `decommissionTopologicalOrder`, the same order the runner executes, so the plan a
  stack signs and the order it runs cannot disagree.
- **The `--dry-run` plan.** Its ten `NODE=` lines were the sixth copy, and this is the artifact an
  operator reads and approves before running the real command: a node added to the signed inventory
  would have been destroyed without appearing in the plan that authorized it. The lines are now a
  projection of the same derived inventory through `decommissionProgramTagText`, and both annotations
  are derived rather than asserted — the parameterized note attaches to the node the plan carries a
  representative of, and `(unique terminal)` only to whatever the derived order actually ends with.

All three derivations reproduce their authored predecessors byte for byte, so this is a cannot-drift
guard rather than a change to anything the Authority signs; a historical receipt stays verifiable.
The single visible change is operator-facing: three dry-run labels now use the semantic tag name
(`target-generation-tombstone`, `retained-custody-tombstone`, `authority-backup-objects`) rather than
a third spelling of their own, and the destructive golden is regenerated.

This does not add the four scheduled decommission nodes. It removes the surfaces on which adding one
would have been silently incomplete — which is the precondition for adding them at all.

### The Final No-Retention Audit Is a Node, Not a Tail (landed 2026-08-18)

Sprint `4.76` gave the terminal scoped tag sweep its first call site — the doctrine had assigned it to
`nuke` all along and nothing ran it — but it ran **outside** the receipt graph, in
`runNukeTerminalTagSweep`, after `runPreparedNuke` had already returned success. The deletion ledger
records the consequence exactly: a crash or a lost response there cannot resume through the manifest.
The run has converged on paper, every node in the signed plan is terminal, and the only proof that
nothing escaped was never taken — so re-running `nuke` restarts from a plan with nothing left to do.

`FinalNoRetentionAudit` is that sweep as the terminal node of the signed graph. Four properties come
from where it now sits rather than from new code: a durable intent frame before the effect, a stable
attempt identity, authoritative re-observation on resume, and a receipt entry that says what was
observed. `FinalNoRetentionAuditCapability` is read-only by construction, like the all-prefix absence
proof — production composition cannot smuggle a deletion into the terminal proof — and the sweep's
three verdicts stay three: confirmed-clean is `ResidueAbsent`, escapees are `ResiduePresent`, and an
unreadable Tagging API is `ResidueUnreachable`. Collapsing the last two would record the wrong fact,
because an escapee is a resource that survived while an unreadable API is an absence nobody observed.
Both refuse the node, as before.

**The shared object bucket stops being the unique terminal.** It remains the last *resource deletion*
— `sharedBucketIsLastDeletion` — and the audit follows it, because the audit admits no retained
carve-out and would otherwise report the bucket it is waiting on as an escapee. The ordering matches
the compiled `TotalDecommission` program, where `decommission/audit-escapes` precedes the local
uninstall, so the runner graph and the compiled program agree on where the audit sits rather than
each asserting it.

**This is the first tag implemented on both sides.** `decommissionProgramTagImplementation` measured
twenty-one tags with zero overlap; `TotalDecommissionEscapeAuditTag` is now
`CompiledProgramAndRunner`, and `validateDecommissionProgramTagParity` required that claim to be
updated in the same change — which is what the previous increment built it for.

**The three derivations added a day earlier carried the node without being touched.** It reached
`requiredSingletonDecommissionNodes`, the Authority's production plan, the operator-approved
`--dry-run` plan, and the signed interpreter-registry identity through the closed enumerations alone.
That last one is a genuine identity change rather than a cannot-drift guard — the runner gained its
first escape-audit interpreter — so `nukeInterpreterRegistryVersion` is bumped to `2` in the same
change and a receipt signed under version `1` will not verify against this runner.

Crash/response-loss coverage came the same way: the runner suite's recovery case iterates its node
inventory, and that inventory was two identical literals in two scopes, now one value the new node
joins. Seven pinned inventories failed on the addition and were updated deliberately, which is the
behaviour the mandatory-singleton derivation exists to produce.

**What this does not close.** Three scheduled nodes remain — home-substrate uninstall/read-back, the
explicit `.data` retain/delete disposition, and terminal-receipt append/read-back — and each needs a
production boundary that does not exist yet, unlike this one, which had a working boundary in the
wrong place.

### The Home Substrate Is Uninstalled by the Signed Graph (landed 2026-08-18)

`compileDesiredAbsenceProgram TotalDecommissionSurface` has emitted
`decommission/uninstall-local` and its read-back since the program algebra landed, and **no runner
executed either**: a total decommission destroyed every AWS resource class and left the local RKE2
substrate installed. `HomeSubstrateUninstall` is that operation as the last node of the signed receipt
graph.

The stable `CleanupOperationId` is **derived from the receipt attempt** rather than freshly generated,
which is the property the whole graph rests on: the uninstaller runs under an identity the durable
intent already recorded, so a lost response resumes by re-observing markers under the same operation
instead of running a second uninstall. The destroy half is deliberately not the read-back —
`attemptLocalRke2Uninstall` distinguishes applied, already-absent, refused, and response-lost, and only
a fresh all-markers-absent observation closes the node, so an uninstaller that exits zero without
removing the install cannot report success. The three marker outcomes stay three: absent, surviving
markers, and markers that could not be observed.

**The terminal phase is now ordered, and its order is measured rather than asserted.** Two nodes now
follow the last resource deletion, and both the runner graph and the compiled program state an order
over them. `DecommissionTerminalPhaseNode` is the closed, ordered enumeration the graph derives its
predecessors from — a terminal-phase node waits on every non-terminal node in the plan and on every
terminal-phase node ranked before it — and `compiledDecommissionTagPrecedes` measures the compiled
program's own order over the same semantic tags by transitive dependency reachability.
`decommissionTerminalPhaseOrderViolations` joins the two in `dev check`. The relation is deliberately
two-sided: every node of the later tag must reach some node of the earlier one, **and** no node of the
earlier may reach the later, so an unordered pair does not read as ordered. A fixed regression pins
that the reverse direction is `False` and that a tag the compiled program never emits precedes nothing.

The ordering is not arbitrary. The audit admits no retained carve-out, so it must follow every
deletion; the uninstall dismantles the plane through which the SES quiescence, target-generation, and
retained-custody nodes were answered, so it must follow the audit. Waiting on *every* other node is
strictly stronger than the "every home-plane-dependent node is terminal" readiness the doctrine asks
for.

`HomeSubstrateUninstallTag` is the second tag to measure `CompiledProgramAndRunner`, and
`nukeInterpreterRegistryVersion` is `3` — the runner gained a second interpreter, so the identity the
Authority signs genuinely changed again.

**What remains of the four scheduled nodes**: terminal-receipt append/read-back. The explicit
`.data` retain/delete disposition landed later the same day (see below); the terminal receipt still
needs a production boundary that does not exist.

### The Operator's `.data` Disposition Is a Signed Node (landed 2026-08-18)

`nuke` has named the manual PV host root as the **first entry of its own deletion-root inventory**
since the external-path guard landed — that inventory is exactly why the external receipt and the
pinned runner are refused inside it — and **nothing ever disposed of it**. A total decommission
destroyed every AWS resource class, uninstalled the home substrate, and left the retained data tree
on disk with no record of whether that was what the operator wanted. The deletion ledger's own
description of the target has always said "explicit `.data` retain/delete/read-back"; the code had
neither the decision nor the effect.

`LocalDataDisposition` is that operation as the last node of the signed receipt graph, and the
decision it carries is `DecommissionLocalDataDisposition` — a closed two-valued type with **no
default**. Making it a value rather than a flag read at the effect boundary is what lets it be
signed: it is a *parameter* of the node, so it enters the manifest digest and the frame node
identity, and a receipt opened for a `retain` run cannot be resumed as a `delete` run because the
node IDs differ. `prodbox nuke --local-data <retain|delete>` is required for apply and optional for
`--dry-run`; there is no default because both candidates silently decide the fate of retained data
and one of them is irreversible.

**A mandatory node with a parameter was previously unrepresentable.** Sprint `4.85` had already
derived the required-node set from the closed `DecommissionSingletonNode` enumeration, so that a
newly added singleton could not be silently optional. That derivation could only express "every
singleton is present" — and the disposition node is mandatory *and* parameterized, so it would have
fallen through the same hole one constructor shape further along. `DecommissionNodeFamily` is now the
single cardinality classifier: every node is a mandatory singleton, a mandatory choice from a closed
family, or per-Agent parameterized work. `decommissionNodeSingleton` is a *projection* of it rather
than a second `case`, so the required-singleton list and the mandatory-choice list cannot disagree
about a node, and `validateDecommissionPlanCardinality` derives all three refusals — missing
singleton, missing decision, competing decisions — from it. `validateProductionManifest` consumed the
authored missing-node list and now consumes that function instead.

**The Authority still owns the plan; the operator owns one bounded choice.** The export request was
deliberately shaped so that a caller cannot supply a plan, and it still cannot: the node set and its
order come from the Authority's registered inventory. What the inventory cannot supply is the
*disposition* — it knows the root exists, not what should become of it. So the request carries a
two-valued decision, the Authority places it into the plan, and the runner then **refuses a signed
manifest whose disposition is not the one the operator requested**. Without that check a defective or
compromised Authority could sign `retain` over an operator's `delete` and the run would converge
reporting success. The resume path makes the check load-bearing rather than theoretical:
`readCommittedPlanOrDiscover` binds the decision on the first export and never rediscovers, so a
resume supplying the other value is refused instead of silently inheriting the committed one.

**The adapter's two arms are deliberately asymmetric.** `retain` issues **no effect at all** — the
deleting arm is selected by the decision the manifest carries, so a capability built on a host cannot
delete under a plan that said retain. `delete` observes the root, refuses an unobservable one before
removing anything, and distinguishes already-absent, applied, refused, and response-lost; the stable
`CleanupOperationId` is derived from the receipt attempt, so a lost removal response resumes by
re-observing the root under the same operation rather than issuing a second removal. The read-back is
disposition-indexed and refuses in **both** directions: a surviving root under `delete` and a missing
root under `retain` are both residue, because the operator asked for the data to survive the
decommission and it did not — a fact the receipt must record rather than round up to success. An
unobservable root closes neither, because an absence nobody observed is not a disposition anybody
honoured.

`mkLocalDataRootPath` is the guard between a configured string and a recursive removal: absolute,
canonical, and at least three components below `/`. It is a depth rule rather than a denylist because
a denylist of system directories is open-ended and a new mount point escapes it, while the depth of a
prodbox-owned PV root is a property of what the value *is*. The same resolution now serves both
consumers — `resolveNukeManualPvRoot` feeds the deletion-root inventory and the disposition target —
so `nuke` cannot refuse a receipt path under one root while disposing of another.

`LocalDataDispositionTag` is the **third of twenty-one tags** to measure `CompiledProgramAndRunner`,
`nukeInterpreterRegistryVersion` is `4`, and the terminal-phase order gained a third rank measured
the same two-sided way as the first two. One scheduled node remains: terminal-receipt
append/read-back.

### The Receipt Says the Run Converged (landed 2026-08-18)

The external receipt records every node's intent, observation, and result. What it never recorded is
that the **run** converged. A receipt whose last frame is the final node's result is byte-identical
to one whose run crashed immediately after writing that frame — the only place the convergence fact
existed was `reportConverged`, an in-memory fold inside the process that produced it, which dies with
that process. A reader of the durable record could not tell a completed decommission from an
interrupted one.

`DecommissionTerminalReceipt` is the fourth and last scheduled node, and it closes that gap by being
last in the derived order and refusing unless the durable record already carries a terminal success
for **every other node of the signed plan**. Its own success frame is then the declaration, written
through the same fsync/reopen/validate append primitive as every other frame — so a crash before it
leaves a receipt that visibly does not claim convergence, and a resume re-observes rather than
assuming.

**The append is the runner's frame; the node supplies the read-back and the ordering.** This is worth
stating plainly rather than letting "terminal-receipt append/read-back" imply a second writer. The
node has no destructive half at all: `DecommissionTerminalReceiptCapability` is read-only by
construction, like the all-prefix absence proof and the terminal escape audit, and here that
discipline is at its strongest — the node reads the very record it is a node of, so a capability that
could write would be one that mutates the history it is proving something about. What makes the
runner's existing result frame *terminal* is that it cannot be written until the read-back succeeds,
and the read-back cannot succeed until everything else is durably done.

`decommissionRunTerminalEvidence` is that decision, and it is a function of the durable record rather
than of the runner's verdicts. It reuses `validateReceiptSemantics` — the same fold the runner
resumes from — deliberately: a second traversal with its own notion of "terminal" could accept a
history the runner would refuse to resume. The asking node is excluded because it cannot be terminal
while it is deciding (at observation time the receipt holds its intent frame and no result), and it
is required to be a plan member so a caller cannot obtain a vacuous verdict by asking about a node
the plan never contained. A node whose only frames are an intent and a *failed* result is not
terminal, so a failed run cannot mint convergence.

**A reader that could repair is not a reader.** `reopenBoundReceipt` truncates a torn final record,
which is correct for the runner that is about to append and wrong for anything that only wants to
read. `readBoundReceiptFramesReadOnly` is its read-only sibling: a torn tail is `BoundReceiptTornTail`
rather than a repair, and a fixed regression pins that the file's bytes are unchanged after the
refusal while the runner's own path still repairs it — so the two readers are deliberately different
rather than accidentally so.

The three verdicts stay three. Outstanding nodes are residue and name themselves; an unreadable or
semantically refused receipt is an absence nobody observed. `TerminalReceiptTag` is the **fourth of
twenty-one tags** to measure `CompiledProgramAndRunner` and `nukeInterpreterRegistryVersion` is `5`.
All four scheduled decommission nodes have now landed, and the terminal phase is a four-rank ordered
enumeration whose order is measured against the compiled program in both directions.

### The Cascade-Audit Freeze Has a Caller (landed 2026-08-18)

The freeze transition landed a day earlier and no production caller could reach it. That was the
whole content of `GlobalProviderAdmissionFreezeUnavailable`: the aggregate command existed, the
submission gate already honoured its reservation, and `AuthorityControlPayload` — the closed
externally admissible control vocabulary the authenticated `authority/control` route decodes — had
four constructors, none of which was either Provider-admission command.

`AuthorityControlBindProviderGeneration` and `AuthorityControlFreezeProviderAdmissionForCascadeAudit`
are appended to that vocabulary, so every earlier constructor keeps its `Serialise` index and no
historical request re-decodes as a different payload. `CascadeAuditFreezeBinding` and its smart
constructor are exported from the `ProviderAdmissionEpoch` facade for the first time — the facade
said they stayed package-private "until the canonical terminal audit route exists", and it now does.
What stays package-private is every way to *apply* one: the epoch constructors, both transitions, and
the revocation receipt. A caller states the reservation it owns — its own run, node, operation,
attempt, and the submission keys it will use — and cannot transition the epoch itself.

**The route and the command it issues are now one relation instead of two.**
`serveAuthorityControlRequest` used to relate them in an inline `case` that nothing outside the
function could read, which is why "no authenticated route issues that command" had to be an authored
note in `AbsentDispositionCapability` rather than a measurement. `AuthorityControlRoute` is that
relation as data, `authorityControlPayloadRoute` and `authorityControlPayloadCommand` are total
projections of the payload onto it, and the endpoint serves the second one. The blocker's evidence
kind moves from `TypeLevelAbsence` to `DerivedFromAuthorityControlRoutes`, so deleting the route
re-establishes the blocker as an unpublished-blocker failure instead of leaving it silently retired.

The retired blocker keeps its constructor and its derivation. Seven of the original eight remain, and
the coverage join still fails in both directions.

### The Terminal Audit Is a Credential Consumer (landed 2026-08-18)

`TerminalAuditProviderCapabilityUnassigned` said no capability had been assigned to the terminal
escape audit, and the assignment was one arm of a classifier that already exists:
`teardownOperationCredentialConsumer` answered `Nothing` for both `AuditCascadeEscapes` and
`AuditTotalDecommissionEscapes`.

That answer made the ordering claim the whole inventory rests on weaker than it reads. "The credential
must stay live *through* the audit" is a statement about the audit needing the credential, and the
classifier said it did not. An escape audit enumerates provider-side resources; it cannot run without
a Lifecycle-provider session. `TerminalEscapeAuditCredentialConsumer` is that requirement, and it is
now the last consumer in the cascade ancestry rather than a node outside the relation.

**The executing adapter is Sprint `7.36`'s, and this sprint makes no claim about it.** What is fixed
here is the requirement the adapter has to satisfy — which is exactly the half a capability assignment
is, and exactly the half a Phase-4 lifecycle-core surface owns.

The coverage regression that recorded "the audit is not its own consumer" is replaced rather than
deleted: it existed to show the ordering check was not vacuous, so it is now the pair
`coverageRegressionAuditConsumesCredential` and `coverageRegressionNonConsumersExist` — the audit does
consume, and the cascade completion read-back still does not, so the classifier has not drifted toward
answering `Just` for everything.

### The Legacy Operational Identity Names Its Successor (landed 2026-08-18)

`LegacyOperationalIdentityReplacementUndefined` was derived from a status field whose value was
authored, on an identity whose three resources were a `[Text]` field. A string has nowhere to carry a
successor, so "the replacement is undefined" could never stop being true by anything short of an edit.

`LegacyOperationalResource` is those three names as a closed enumeration and
`legacyOperationalResourceReplacement` is total over it. The answers are the collapse the target
architecture already performs: the `prodbox` IAM user becomes `prodbox-lifecycle-provider`, the fixed
session role that user assumed for one SES lease transaction becomes the registered provider role that
credential's single `AssumeRegisteredProviderRole` permission names, and the operational `aws.*` config
block has no successor credential at all — generated non-secret configuration carries what it carried.

`ReplacementUndeclared` is a real answer rather than a placeholder, which is what makes the blocker a
measurement: a new legacy resource is an exhaustiveness failure until someone answers, and answering
`ReplacementUndeclared` re-establishes the blocker. The identity's status is derived from the map
instead of authored beside it.

**Declaring a successor is not migrating to one.** Revoking the legacy identity and reading back its
absence stays where it was, in the deletion ledger; what this closes is the definition the disposition
argument needs. `prodbox dev check` joins the enumeration to the `Operational` rows of the flat
lifecycle inventory in both directions, so an enumeration that lost a row cannot report that every
legacy resource has a successor while a real one goes unanswered.

### A Revoke Response Is Not a Read-Back (landed 2026-08-18)

`CanonicalTargetRevocationReadBackUnavailable` said a revoke response could not be independently
confirmed, and the production path showed exactly that: the fenced Admin worker revoked the target
generation, took the boundary's own success text as evidence that the material was gone, and then went
on to destroy the IAM identity. The identity's absence *was* read back. The target generation's was
not, so an applied-but-unconfirmed revoke and a confirmed one were the same value.

The target is now re-observed through the same boundary the delivery path already uses to distinguish
present from absent, and a still-present generation is a refusal rather than a successful revocation.
Ordering is deliberate: the generation is revoked and read back **before** the identity is destroyed,
so a run that fails in between leaves an identity with no usable material rather than material with no
identity to revoke it under.

**Two paths, one definition.** `decideCredentialRevocationReadBack` is a total function over a closed
observation product — three target answers by four identity answers, including "the identity step was
not attempted" — and it mints a read-back through `mkOperatorMaterialRevocationReadBack`, the binder
the pure provisioner algebra already used. Exactly one of the twelve pairs succeeds. Both paths decide
through it, so "revocation read-back" stops being one notion per path.

The blocker moves from `TypeLevelAbsence` to a derivation over that table: a protocol that drifted into
accepting an unobservable or still-present target stops satisfying it and re-establishes the blocker.

### An Ordinary Surface That Revokes (landed 2026-08-18)

`OrdinaryLifecycleProviderRevocationUnavailable` said no ordinary lifecycle path revokes the
Lifecycle-provider credential, and it was right in the strongest way: the revocation protocol existed
at the Admin-worker boundary and **no compiled teardown program named it**, so nothing an operator
could run reached it.

`RevokeOperationalCredential` and `ReadBackOperationalCredentialRevocation` are that path. They are
indexed at `'OperationalTeardown` — the one ordinary surface whose scope *is* the operational
credential. Cascade deliberately retains the credential: a cascade that revoked it would fence the
terminal audit it had just run, and every later run. The read-back is a mandatory read-back, so the
surface cannot report completion while its own revocation is unconfirmed, and the surface report now
depends on it.

The node's capability is `LifecycleSubmit` and its read-back's is `LifecycleObserve`, not a provider
capability — the disposition submits to the Authority and observes its own result. That is also why it
is **not** a Lifecycle-provider consumer: a disposition that consumed the credential it disposes of
could not be ordered after the audit at all.

**The blocker is narrowed rather than retired, and it is now measured.** What survives is that no
released runtime executes either node — the descriptor-bound dispatcher classifies both as typed
refusals, like every other unreleased operation. That classification is the dispatcher's own, so
`descriptorBoundLifecycleOperationIsReleased` is what the blocker reads: routing the adapter retires
the blocker automatically instead of leaving a stale reason behind. Seven of the eight blockers are now
measured; only Provider-operation cleanup-run ownership still rests on a missing constructor.

### One Surface With Both Halves (landed 2026-08-18)

The two revoke orders were the last pair of program-derived blockers, and they were one fact stated
twice: `DispositionBeforeAuditConflictsWithLiveAuditCredential` said the surface that would carry a
disposition had no audit, and `AuditBeforeDispositionConflictsWithCurrentCascadeGraph` said the
surface that owns the audit had no disposition. Neither order was expressible on a surface with both
halves.

Total decommission is that surface. It owns the final no-retention audit, and it is the one surface
whose scope includes destroying the operational credential. The compiled program now orders
`decommission/revoke-operational-credential` strictly after `decommission/audit-escapes` and strictly
before `decommission/uninstall-local`: the audit needs the credential live to enumerate provider-side
resources, and nothing after the disposition touches the provider at all — the uninstall, the
local-data disposition, and the terminal receipt are local. The home uninstall additionally waits on
the revocation's read-back, because the revocation is answered through the plane the uninstall
dismantles.

`OperationalCredentialRevocationTag` is the twenty-second decommission tag and is `CompiledProgramOnly`:
the signed manifest names resource families, and revoking the Lifecycle-provider credential is not one
of them. Giving it a manifest node is part of the convergence Sprint `6.5` owns, and this sprint makes
no claim about it.

Both blockers are measured over the emitted dependency graph rather than asserted beside the node
list. The fixed regression records the discriminating direction as well: the audit precedes every
disposition and no disposition precedes the audit, so an unordered pair cannot read as ordered.

### A Provider Operation Names the Run That Authorized It (landed 2026-08-18)

`ProviderOperationCleanupRunOwnershipUnavailable` was the last blocker resting on a missing
constructor. The retained Provider record held the request digest and the exact intent and nothing
about who asked for it, so "which run destroyed this?" was answerable only by matching intents by eye
— and a disposition that cannot be attributed to the run that authorized it is not an auditable
disposition.

`AuthorityProviderOperation` now carries a `ProviderOperationCleanupOwner`, and the owner is part of
the binding a duplicate retry must match, so a second run replaying another run's submission key
cannot inherit its durable outcome. The codec is hand-written for the same reason the aggregate's is:
generic `Serialise` encodes a sum as a list whose head is the constructor tag, so the pre-ownership
shapes are exactly the shorter encodings and decode as unowned rather than being guessed into a run.

**The owner is a `CleanupOperationId`, not a bare run id**, because that is the identity the teardown
dispatch path actually holds: the graph lowering derives one stable operation id per (run, node) and
the Provider submission key is derived from it. Naming the operation names the run and the node within
it, which a run id alone would not. `ProviderOperationUnownedByCleanupRun` is a real answer —
desired-present provisioning work is not authorized by a cleanup run, and pretending otherwise would
make ownership meaningless.

The teardown boundary now receives the whole dispatch key rather than only its derived submission
string. Recovering the operation id by parsing that string back apart would be deriving an identity
from a rendering; the key *is* the identity, and it was being discarded at exactly the seam where the
Authority could have retained it.

### Operational Teardown Reports Its Own Completion (landed 2026-08-18)

With every disposition blocker retired, the last named item of this sprint closes. `OperationalTeardown`
had no completion minter because it projected **zero** registered targets: completing it would have
been a clean-completion claim over an empty projection, which is the shape this phase exists to remove.

Its obligation is no longer empty. The credential revocation and that revocation's mandatory read-back
are the surface's own, not a registered target's, so a complete read-back set on this surface really is
credential/lease absence — independently observed rather than taken from the revoke response — plus its
own committed report read back. Retained-dependency observation is the `Established` recovery plane the
minter re-checks, along with the evidence's surface tag; both are arms classification cannot produce, so
only a mis-minted value could carry one.

**Consumer quiescence is not claimed by this minter**, and it says so. Proving every Provider consumer
quiescent before the credential is revoked is a condition on when an operator may *start* the run; it
belongs to the surface that admits the run rather than to the witness that reports it.

`ExplicitLongLived` remains the one ordinary surface with no minter, and the reason is still missing
evidence rather than missing typing: it requires the aggregate operator permit its deliverable names,
and that permit has no type.

### Every Disposition Blocker Is Now Measured (closed 2026-08-18)

`OperationalCredentialDispositionBlocker` published eight reasons when this sprint began, four of them
authored facts about missing constructors that no value could witness. A reason nothing recomputes goes
on justifying an omission after the reason is gone, which is precisely the failure this list was found
to have. Each of the eight was closed by building the missing capability and deriving the blocker from
it:

| Blocker | Closed by | Derived from |
|---|---|---|
| `GlobalProviderAdmissionFreezeUnavailable` | the authenticated control route that issues the Cascade-audit freeze | the closed Authority control-route vocabulary |
| `TerminalAuditProviderCapabilityUnassigned` | classifying the terminal escape audit as a Lifecycle-provider consumer | the credential-consumer classifier |
| `LegacyOperationalIdentityReplacementUndefined` | every legacy operational resource naming its successor | the legacy identity's derived status |
| `CanonicalTargetRevocationReadBackUnavailable` | the canonical revocation read-back decision both paths decide through | its twelve-pair decision table |
| `OrdinaryLifecycleProviderRevocationUnavailable` | the operational surface compiling its credential revocation and read-back | the compiled operational program |
| `DispositionBeforeAuditConflictsWithLiveAuditCredential` | ordering the decommission disposition strictly after the terminal audit | the emitted dependency graph |
| `AuditBeforeDispositionConflictsWithCurrentCascadeGraph` | total decommission owning both halves | the compiled decommission program |
| `ProviderOperationCleanupRunOwnershipUnavailable` | the retained Provider operation carrying its cleanup owner | the teardown dispatch key's ownership |

The published list is now empty and `TypeLevelAbsence` is gone with the last blocker that used it.
Every constructor and every derivation stays, and the coverage join still fails in **both** directions,
so any of the eight becoming true again is an unpublished-blocker failure rather than a silently lost
reason.

### Remaining Work

Finish the enumerated terminal proof protocols and total-decommission parity, and consume Sprint
`4.84`'s stable generation/audit catalog. The landed descriptor-bound kernel must remain unactivated
wherever a required opaque proof cannot yet be obtained; no raw `CleanupRun`, public repository
record, or write response may substitute.

All four scheduled decommission nodes have landed — the final no-retention escape audit, the
home-substrate uninstall, the operator's explicit `.data` retain-or-delete disposition, and the
terminal receipt. What remains of this sprint is the ordinary-surface completion evidence below.
Bidirectional total-decommission parity is **not** this sprint's item and is not listed here: making
the compiled program and the signed manifest one universe is the single-writer cutover Sprint `6.5`
owns, which is what validation item 10 was re-scoped to record on 2026-08-18.

One named item is worth stating precisely, because it is blocked on evidence that does not exist
rather than on typing:

- **`OperationalTeardown` completion evidence.** `ExplicitPerRun` landed (see above).
  `OperationalTeardown` remains, and is blocked on evidence rather than typing: it projects **zero**
  registered targets because the typed registry contains no `Operational` descriptor. Registering
  the operational descriptors is itself constrained —
  `OperationalCredentialDispositionBlocker` records why, and five of its reasons are recomputed from
  their sources rather than authored, so one that stops being true fails `prodbox dev check` instead
  of continuing to justify the omission. Four of the eight closed that way on 2026-08-18 —
  `GlobalProviderAdmissionFreezeUnavailable` when the authenticated control route that issues the
  Cascade-audit freeze landed, `TerminalAuditProviderCapabilityUnassigned` when the terminal escape
  audit was classified as a Lifecycle-provider consumer, and
  `LegacyOperationalIdentityReplacementUndefined` when every legacy operational resource named its
  successor, and `CanonicalTargetRevocationReadBackUnavailable` when the revocation read-back became a
  closed decision table both paths decide through. Each stays derivable, so undoing any of the four
  re-establishes its blocker. A fifth, `OrdinaryLifecycleProviderRevocationUnavailable`, was narrowed
  to the one fact that survives — no released runtime executes the compiled revocation — and is
  measured from the dispatcher's own route classifier. The two program-derived ones are
  now stated precisely: the compiled `OperationalTeardown` program has no terminal audit node at all,
  and no `TeardownOperation` constructor disposes of the credential, so neither revoke order is
  expressible on a surface that has both halves. Every one of the four surviving reasons is a type-level or
  program-level absence on **this phase's own** lifecycle-core surface, so closing them is
  same-phase work: the two revoke orders, Provider-operation cleanup-run ownership, and the released
  runtime for the compiled operational revocation.

**This sprint does not mint `ExplicitLongLived` completion.** Its only registered target — the
retained EBS family — has no production executor, so minting completion there would assert a
mandatory read-back that cannot run. `registeredTargetExecutorViolations` makes that ordering
mechanical rather than advisory: the family "stops being admissible the moment `ExplicitLongLived`
or `TotalDecommission` gains a minter", so the minter and the retained-EBS desired-absence adapter
are **one change**. Sprint `7.36` owns that adapter, and this sprint makes no claim about the pair.
Re-scoped 2026-08-18 under
[Standard N](development_plan_standards.md#n-phase-independence-and-execution-order), by the same
argument that withdrew the `dns-aws` registration to `7.36` earlier: a Phase-4 item that cannot land
until a Phase-7 adapter does is a backward dependency, not a sequencing note.

**This sprint does not delete the callback cleanup clients.** `CapabilityBoundCleanupAction` and the
`TestRunner` composition around it are genuinely load-bearing, unlike the DNS01 pair: they are the
validation harness's live cleanup path. Sprint `5.36` owns their removal as part of migrating that
harness onto the lifecycle-owned cleanup run, and this sprint makes no claim about them.

**This sprint does not build the DNS01 challenge executor or the terminal-audit Provider adapter.**
Registering the DNS01 Challenge/TXT family compiles a mandatory absence read-back that no
registered-target execution path can discharge, so the executor must land with the registration; and
the terminal cascade audit's execution half needs the Provider adapter its own ledger row names.
Both are Sprint `7.36`'s, re-scoped 2026-08-18 under Standard N. What stays here is what this phase
can prove on its own surface: the admission algebra, the freeze transition and its reservation, and
the pure obligation data.

## Sprint 4.86: Recover-to-Clean Cascade and Proof-Carrying Completion [✅ Done]

**Status**: Done (2026-08-20; implementation began 2026-08-15). Every node of doctrine § 5b has a
production surface, both closed runtimes the descriptor-bound dispatcher takes are constructible,
the non-public candidate entrypoint drives the total dispatcher over a durable descriptor-bound run,
and the seven validation items are measured where the coverage map below records them. Activation of
a public writer and the Standard-P qualification over the composed running system are Sprint `6.5`'s.
**Closure dependency**: Sprint `3.41` for the recovery-only renderer/artifact authority and Sprint
`4.85` for the remaining terminal proof protocols. Both are same/earlier-phase dependencies.
**Deployment qualification**: pending — destructive orchestration, topology, credentials, and local
uninstall order change.
**Doctrine**: [Lifecycle Reconciliation Doctrine § 5b, “Canonical recover-to-clean
cascade”](../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade),
[Pure FP Standards § 8, “Plan / Apply”](../documents/engineering/pure_fp_standards.md#8-plan--apply),
and [CLI Command Surface, “Reconcilers: Idempotent Mutation as a Single
Command”](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).
**Implementation**: `RecoveryPlane`, `RecoveryPlaneRepository`, `RecoveryPlaneInterpreter`, routes
`56`/`57`, `RecoveryPlaneComponentObserver`, `RecoveryPlaneHostRuntime`,
`Prodbox.Lifecycle.Teardown.RetainedArtifactCustody`,
`Prodbox.Lifecycle.Teardown.RecoveryRepairExecution`,
`Prodbox.Lifecycle.Teardown.PreUninstallReadiness`,
`Prodbox.Lifecycle.Teardown.PreUninstallStageC`,
`Prodbox.Lifecycle.HostCleanupLocalAbsence`,
`Prodbox.Lifecycle.HostCleanupCompletion`,
`Prodbox.Lifecycle.HostCleanupRecoveryPlane`,
`Prodbox.Lifecycle.HostCleanupProductionEffects`,
`Prodbox.Lifecycle.Teardown.RecoveryRepairProduction`,
`Prodbox.ControlPlane.HostCleanupReadinessRepository`,
`Prodbox.Lifecycle.HostCleanupAuthorityArms`,
`Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction`,
`Prodbox.ControlPlane.CascadeRetainedSlotEndpoint`,
`Prodbox.ControlPlane.CascadeRetainedSlotClient`,
`Prodbox.Config.RetainedArtifacts`,
`Prodbox.Lifecycle.HostCleanupCompositionRoot`,
`Prodbox.Lifecycle.Teardown.CloudRuntimeProduction`,
`Prodbox.Lifecycle.CleanupRunEntry`,
`Prodbox.Lifecycle.Teardown.CascadeCandidate`,
`Prodbox.Lifecycle.Teardown.CascadeCredentialDisposition`,
`Prodbox.Lifecycle.Teardown.CascadeTerminalAudit`, and the source-stable hidden
`DescriptorBoundLifecycleRuntime` dispatcher form the unactivated candidate foundation. Retain the
existing public `runNativeDeleteCascade` route until Sprint `6.5` performs one-writer activation.
**Live-proof**: pending and non-blocking for code-local closure; home recovery/counterexample and
repeated-cascade evidence are required by Standard P before public activation.
**Independent Validation**: installed-binary fake trace plus pure graph/result tests; live AWS
adapter proof belongs to Phase 7.
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/streaming_doctrine.md`, root `README.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Implement the typed recover-to-clean candidate that restores its own narrow authority, proves exact
convergence, records it durably, and can construct a local-uninstall plan only after success. Public
`cluster delete --cascade` activation and legacy-path removal belong solely to Sprint `6.5`.

### Current Implementation Checkpoint (2026-08-16, paused)

- RecoveryPlane identity commits run, descriptor, graph, scope, capability profile, exact recovery
  operations, and distinct Establish/initial-read-back/final-disposition attempts. Only final
  independently read-back `Established` evidence exposes Ready.
- Lifecycle Authority constructs the production component observer once, then each phase freshly
  reloads the descriptor-bound running handle and re-observes exact Kubernetes/Vault/host facts.
  Authenticated route `56` returns only phase outcome; route `57` accepts only the operator's exact
  post-Begin Healthy host observation and returns no proof.
- The hidden total dispatcher classifies all 38 compiled operation shapes (3 RecoveryPlane, 14
  cloud-runtime, 21 typed unsupported). Its strengthened diagnostic uses real authenticated
  descriptor reconstruction and checks one real cloud dispatch plus a zero-effect typed refusal.
  It is source-stable and style-clean but was deliberately paused before the current-tree aggregate.
- No Runtime, CLI, or `TestRunner` constructs the total dispatcher. The active public cascade is
  unchanged.
- Cascade Stage C was absent: no production path could yet mint/read back the descriptor-bound
  pre-uninstall readiness evidence. Closed on 2026-08-18 by the Stage-C checkpoint below, which
  performs the sequence behind two injected boundaries; wiring the real clients into them remains. The target host-completion boundary remains a locked immutable
  `Prepared -> Absent` retained-root record created before uninstall and resumable from the exact
  bootstrap locator while Authority is absent; no production path implements that complete
  protocol yet.

### Current Implementation Checkpoint (2026-08-18, retained-artifact custody)

- The bytes a Sprint-`3.41` repair plan names now have a custody surface.
  `Prodbox.Lifecycle.Teardown.RetainedArtifactCustody` derives one plan from the validated inventory
  and one exact store listing, classifying every inventory entry and every observed member exactly
  once: matching is retained, absent is acquired, mismatched or unreadable is replaced with the
  reason preserved, and a member the inventory does not name is collected.
- The inventory is the authority and a source is a transport. A pinned-archive locator is bound to
  the inventory's own digest at catalog construction, and delivered bytes are discarded rather than
  placed unless they hash to that digest at execution, so neither an ambient fetch nor a host cache
  can decide what is retained. Deliveries stage in a sibling of the store and are admitted by
  rename, so a partial or rejected delivery is never observable as a store member.
- Convergence is read back from a fresh listing alone. The applied steps are deliberately not an
  input to the read-back, so a successful delivery response cannot be mistaken for retention; an
  unobservable store closes nothing.
- The store is phantom-indexed by how its retained root was obtained. A bootstrap-located root can
  locate retained bytes — which is what recovery needs while the Authority is absent — and only an
  Authority-bound root can construct the mutating boundary.
- The delivery locator has exactly one arm, and the reason is the pinned-digest rule rather than a
  shortage of mechanisms: a delivery whose byte stream is not stable cannot be described by a digest
  fixed ahead of time. Exporting a registry image to an archive is such a mechanism, so retaining
  image bytes from a registry is a content-addressed mechanism this type does not yet have an arm
  for. The repository's control-plane images are retained as pinned archives.
- `Prodbox.Http.Client.httpDownloadToFile` is the bounded, streaming, digesting transfer this
  requires: an artifact is hundreds of megabytes, and a response that crosses the ceiling, fails
  mid-stream, or reports a non-2xx status leaves no completed file.
- The one prodbox-owned control-directory coordinate under a retained root now exists once, in
  `Prodbox.Config.LocalRetainedRoot`, instead of as a literal repeated at each marker site.

### Current Implementation Checkpoint (2026-08-18, repair admission and execution)

- A rendered repair now has a consumer. `Prodbox.Lifecycle.Teardown.RecoveryRepairExecution`
  admits, applies, and reads back the Sprint-`3.41` repair matrix, and it is the only surface that
  executes one.
- **A repair is admitted, never merely rendered.** `AdmittedRecoveryRepair` has no constructor
  reachable from a rendered plan: the plan is joined against an observation of the retained store,
  and only a join in which every artifact the plan names is present and hashes to its pinned digest
  produces one. A rendered plan is a claim about the inventory; an admitted repair is a claim about
  the disk, and the disk is what a recovery runs against.
- **A refusal names its remedy, or names why it has none.** Retention drift is refused with the
  custody plan derived from the same observation the readiness check rejected. The two cases where
  no acquisition helps are distinguished rather than collapsed into an empty plan: an artifact the
  inventory never declares has no pinned digest for a delivery to be checked against, and an
  unlistable store decides neither retention nor drift.
- **Execution reads what the admission verified.** Each step carries the store-relative path and the
  digest observed there rather than an inventory reference, so no step re-derives which bytes it is
  “really” about from a declaration nothing observed.
- **Repair steps are sequentially dependent, and the run says so.** Unlike a custody plan, whose
  obligations are independent, starting a service that was never installed is a second failure that
  describes the wrong boundary. Application stops at the first failure and carries the unattempted
  tail explicitly, so “the repair stopped here” and “the repair had nothing further to do” are
  different values.
- **Convergence is read from a fresh observation and nothing else.** The run is deliberately not an
  input, so a run in which every step reported success against a substrate that is still absent
  reads as unconverged. The verdict is scoped to the substrate arm and makes no claim about chart
  convergence, which the descriptor-bound component observer measures.
- No production boundary is wired. Installing a substrate from retained bytes, starting its service,
  and reconciling the recovery charts are host mutations belonging to the non-public candidate
  entrypoint this sprint still owns; wiring one here would activate a writer this sprint does not
  activate.

### Current Implementation Checkpoint (2026-08-18, Stage C pre-uninstall readiness)

- Stage C exists as a sequence rather than as five unrelated types.
  `Prodbox.Lifecycle.Teardown.PreUninstallReadiness` commits the pre-uninstall report, reads it back
  independently, obtains the one-shot local-completion permit, and composes
  `ReadyToUninstallEvidence` from those two plus the absence, credential, and terminal-audit
  evidences the earlier nodes produce. Before this, every value doctrine § 5b node 7 names existed
  and nothing performed the sequence, so no production cascade could reach readiness at all.
- **The read-back decides durability; the commit response does not.** The read-back runs after every
  commit outcome, including a reported refusal. A commit that reported success and left nothing
  durable is not ready, and one whose response was lost — or that reported a refusal after the write
  had already landed — is separated from the first by the observation. Suppressing the read-back on
  either outcome would decide the run from the weaker fact, which is precisely the
  applied-but-response-lost case Standard P names.
- **The reader is a separate boundary from the writer.** Committing and reading back are two records
  rather than two fields of one, because the whole content of the requirement is that the surface
  claiming to have written the report is not the surface that decides it is durable. In production
  the writer is the Authority and the reader is the Backup Adapter.
- **A drifted report identity never reaches the Authority twice.** When the observed digest differs
  from the committed one the run refuses before a permit is requested, so the Authority cannot sign
  a permit over a report identity nothing durably holds. The measurement is that the permit boundary
  is not called at all in that case.
- The module owns the protocol and says so: the report's *content* belongs to
  `Prodbox.Lifecycle.Teardown.Report`, the permit's one-shot semantics are enforced where the
  Authority signs it, and the uninstall that consumes this readiness is
  `Prodbox.Lifecycle.HostCleanupRunner`. No production client is wired into either boundary, so this
  composition activates no writer; wiring the real Authority and Backup-Adapter clients is part of
  the candidate entrypoint below.

### Current Implementation Checkpoint (2026-08-18, exact host-absence read-back)

- The terminal node's observation half has a production implementation.
  `Prodbox.Lifecycle.HostCleanupLocalAbsence` is the only join between the canonical local-RKE2
  marker observation and the private constructor that mints local uninstall evidence, and it is a
  member of the cascade-evidence ownership set for exactly that reason.
- **The two halves could not previously meet.** `Prodbox.Lifecycle.HostCleanupRke2` observes the
  eight canonical install markers with `lstat(2)` and is forbidden — by a gate that measures it —
  from naming `LocalUninstallEvidence`, while the constructor that mints that proof is private to
  the evidence boundary. The absent arm of an exact host observation therefore had nowhere to go.
- **The scope comes from the durable record, not from the proof.** The observation is scoped by the
  running host-cleanup intent while the readiness carries its own scope, so the constructor's
  comparison is between two independent sources. Scoping the observation from the readiness instead
  would have made that check compare a value with itself.
- **Still-installed and unobservable stay distinct.** A host whose markers are present has not
  converged and the runner acts on that by issuing the uninstall; a host whose markers could not be
  read has said nothing, and calling that either absence or presence would invent a fact. A present
  marker continues to outrank an unrelated read failure, which is the observer's existing rule
  preserved rather than re-decided here.
- **The record now has a derived location.** The host-completion record is created before the local
  uninstall, while the Authority is reachable, and read again afterwards, while it is not. Its store
  was located from a caller-supplied absolute path, so nothing composed those two moments: a record
  could be written where no recovery would look. It is now derivable from the non-authorizing
  bootstrap locator and from the Authority-bound root, both resolving through the one prodbox-owned
  control directory, and the segment naming it is a compiled constant beside the retained-artifact
  store rather than a literal at each site. There is deliberately no durability index here: unlike
  artifact custody, this record must be *mutated* after the Authority is gone — recording local
  absence is the terminal node's whole point — so an Authority-bound mutation index would forbid the
  one write that matters most. The supplied-path constructor survives as the test-scoped seam.

### Current Implementation Checkpoint (2026-08-18, terminal escape audit)

- The cascade's terminal arm has a producer. Every part of doctrine § 5b node 6's decision existed —
  the retained matcher catalog, the query catalog, the classification, and the region-bounded
  verdict — and nothing assembled them, so there was no path from a set of issued queries to a
  `TerminalAuditObservation`.
- **The queries are a union, issued separately.** The Resource Groups Tagging API intersects the tag
  filters inside one call, so the audit's field of view — any prodbox-owned tag family — is several
  calls unioned by ARN. Issuing them as one call is the exact defect Sprint `4.77` found in the
  sweep, and it is not reintroduced.
- **A query that went unanswered is a blind spot, and a blind spot is not clean.** Rows that came
  back are still classified, because an escapee found through one query is an escapee whatever the
  others did; but a would-be-clean verdict is downgraded to unobservable carrying that query's
  failure. This is the same asymmetry the region bound already applies, preserved rather than
  re-decided — and the region bound itself is now exercised end to end, because the fixed run's own
  region answers for no global service and can therefore never report clean.
- **A decoder conflict refuses the audit rather than resolving it.** Two returned rows that disagree
  about one ARN mean the audit's own view is incoherent; no resource in it is trustworthy enough to
  classify, so no verdict is produced at all.
- **The audit scope is derived, never authored.** It comes from the compiled run's observation scope
  through the same derivation `mkCascadeTerminalAuditEvidence` checks against, so an audit cannot be
  taken under a scope that constructor would then reject for a reason the operator cannot see.
- No production boundary is wired. On the AWS substrate the queries are a Provider effect that Sprint
  `7.36` owns, and reaching for a host-direct tagging call here would add an unregistered escape
  path.

### Current Implementation Checkpoint (2026-08-18, local completion journal)

- The terminal node's receipt half has a producer.
  `Prodbox.Lifecycle.HostCleanupCompletion` binds the signed permit and the observed uninstall
  evidence to the stable local-completion operation reference, appends that entry to the preserved
  non-secret cleanup journal, and separately observes it back. Doctrine § 5b node 8 named
  `prepareLocalCompletion` and the receipt it mints; neither existed, so nothing in the repository
  appended a completion entry and nothing read one back.
- **The append is keyed by the reference, not by the bytes.** The entry is published by an
  exclusive link under the digest of its reference, so a rerun whose first append response was lost
  finds its own entry already present and succeeds without writing a second one. That is what makes
  the append idempotent in the sense the node needs: the rerun performs the *observation* rather
  than reinstalling a control plane merely to rewrite history.
- **The host does not rewrite a completion it already recorded.** An entry that is present and does
  not match the prepared bytes is a conflict, not an overwrite, and the signed scope reaches the
  entry through the running context alone — there is no argument through which a wider scope,
  another permit, or another report identity could enter.
- **The writer does not decide.** Appending and observing are separate operations over separate
  descriptors, and the observation reads the journal rather than the append's answer, so an append
  that reported success over a journal holding nothing observable produces no receipt. A journal
  with no entry and a journal that could not be read stay distinct answers, because collapsing them
  would let an unreadable directory read as a clean "not yet".
- **Every field of the read-back is decoded from the durable bytes.** Run, graph digest, scope,
  operation reference, permit, and report digest come from the entry and none from the running
  context, so the runner's binding comparison is between two independent sources. The completion
  proof itself is still minted by the private constructor, which is why this module joins the
  cascade-evidence ownership set exactly as the absence read-back does.
- The record's location is derived from the same one prodbox-owned control directory as the
  host-cleanup record and the retained-artifact store, and carries no durability index for the same
  reason the host-cleanup record carries none: this journal is written at the moment the Authority
  may already be gone.
- `HostCleanupCompletionReadBack`'s constructor became reachable inside the library so this one
  producer can mint it. It remains uninhabitable outside the library, because the receipt
  observation it carries is Cabal-hidden, and holding one still authorizes nothing: the runner
  rebuilds the expected completion proof from the run's own readiness and absence evidence and
  refuses any read-back that does not equal it.

### Current Implementation Checkpoint (2026-08-18, credential disposition)

- The cascade's credential-disposition node has a producer.
  `Prodbox.Lifecycle.Teardown.CascadeCredentialDisposition` observes every disposable credential
  class and folds the answers into the observation `mkCascadeCredentialDispositionEvidence`
  consumes. The constructor existed and nothing produced its input, so the only inhabitant in the
  repository was the fixture's authored `Disposed` — a proof about nothing that the readiness
  composition would nonetheless accept.
- **The disposal set is derived from the credential inventory, not authored.** It is exactly the
  classes whose lifetime is `RunScopedCredential`, and the retained set is its complement rather
  than a second list, so a class cannot be absent from both and become nobody's concern. A new
  run-scoped class is observed without editing this node.
- **The operational credential is retained, and that is now structural.** A cascade that revoked the
  Lifecycle-provider credential would fence the terminal audit it had just run, which is why the
  compiled cascade program emits no credential-disposition node at all. Here the same fact falls out
  of the lifetime partition rather than being asserted a second time: an operational or long-lived
  class is not in the disposal set, so the boundary is never asked about it and it can never be
  reported disposed.
- **A present credential outranks an unanswered one.** A class observed still present is outstanding
  whatever the other observations did, and only when nothing is outstanding does an unanswered class
  decide — and then it decides unobservable rather than disposition. This is the same asymmetry the
  terminal audit applies to a blind query, preserved rather than re-decided.
- **An empty disposal set is a refusal.** A run whose inventory names no run-scoped credential has
  nothing this node can establish, and reporting disposition over an empty set would be exactly the
  vacuous proof this increment removes.
- No production boundary is wired: observing whether an IAM principal still exists is a Provider
  effect Sprint `7.36` owns, and a host-direct IAM call here would add an unregistered escape path.

### Current Implementation Checkpoint (2026-08-18, recovery-plane runner arms)

- The runner's bootstrap recovery-plane arms have a production implementation.
  `Prodbox.Lifecycle.HostCleanupRecoveryPlane` observes the local substrate, admits the Sprint-`3.41`
  repair its observed state needs, applies it through the Sprint-`4.86` execution surface, and reads
  the plane back. Both halves existed and neither reached the runner, so the destructive host
  boundary had no way to re-establish the plane it depends on.
- **The re-establishment never reports availability.** Its answers are about what the attempt did —
  a repair applied, a repair stopped at a step with its unattempted tail, a repair nothing could
  admit, a substrate nothing could observe. Whether the plane *is* available is decided only by the
  separate read-back from a fresh observation, which is the same separation the repair execution
  already applies to substrate convergence and the reason the runner asks two questions.
- **Unavailable and unobservable stay distinct.** A stopped or absent substrate has said something
  and the run acts on it by repairing; a substrate that could not be observed has said nothing, and
  the runner has separate errors for the two. An unobserved substrate therefore selects *no* repair,
  because a repair plan is rendered for an observed state and falling back to one would choose a
  plan for a state nothing established — measured as the boundary not being called at all.
- **Admission precedes every boundary call.** A repair whose retained bytes are not present is
  refused before a host mutation is attempted rather than half-run, and the refusal carries the
  remedy the admission produced.
- The scope of the check comes from the running host-cleanup intent, so the runner's scope
  comparison is over a value the observation carried rather than one it was handed.
- Installing a substrate, starting its service, and reconciling the recovery charts stay behind the
  injected repair boundary: they are host mutations belonging to the non-public candidate entrypoint
  this sprint still owns, and wiring one here would activate a writer this sprint does not activate.

### Current Implementation Checkpoint (2026-08-18, Authority runner arms)

- The runner's three Lifecycle-Authority arm pairs have a production implementation.
  `Prodbox.ControlPlane.HostCleanupReadinessRepository` is the retained namespace the accepted
  readiness lives in, and `Prodbox.Lifecycle.HostCleanupAuthorityArms` accepts the readiness there,
  reads it back, re-establishes the Authority after the destructive step, and reconciles the durable
  cleanup run. All six arms existed as injected effects with no production answer, so the
  destructive host boundary could only ever be exercised against fakes.
- **One observation answers both readiness read-backs.** The runner reads the accepted readiness
  before the uninstall and again after re-establishment; that is deliberately the same question
  asked at two times rather than two questions. A re-established Authority that cannot produce the
  readiness it accepted has not been re-established in the sense the run needs, and giving the
  second read-back a weaker source would hide exactly that.
- **A run owns exactly one readiness slot.** The logical name is derived from the `CleanupRunId`
  alone and the only write the repository can issue is into an empty slot, so a second, different
  readiness under one run is a conflict rather than a second key — two readiness proofs under one
  run would be two permits. An exact replay is a success, because a rerun accepting what it already
  accepted is the case the protocol exists for.
- **Re-establishment never reports readiness.** Its answers are about what the attempt did — bytes
  restored, a restore that failed, an Authority that never admitted a request — and whether the
  readiness survived is the read-back's answer. Admission is awaited only after a successful
  restore, because admission from an Authority whose bytes were not restored would accept an empty
  control plane that has forgotten the run. That is the same separation the recovery-plane arms
  apply to the substrate.
- **The reconciliation re-issues its own attempt.** The local-uninstall node is begun and completed
  under the attempt id `deterministicCleanupNodeAttemptId` derives, which is now the one derivation
  — shared with the durable cleanup driver rather than copied — so a rerun after a lost response
  replays its own attempt instead of colliding with it. Owner and fence come from the lease the
  durable host intent already carries. A transport failure is reported as a lost response rather
  than a refusal, because the transition may have landed and the run read-back is what decides.
- Restoring the aggregate from the independent backup domain and awaiting admission stay behind the
  injected restore boundary: they are host mutations belonging to the non-public candidate
  entrypoint, and wiring one here would activate a writer this sprint does not activate.

### Current Implementation Checkpoint (2026-08-18, single-phase host runner)

- The host cleanup runner can now be driven one durable phase at a time.
  `stepHostCleanupRunner` performs exactly the phase its action selects, persists that transition,
  and stops; the whole-run entrypoints become a loop over the same single-phase body rather than a
  second implementation of it.
- **The reason is attribution, not convenience.** The compiled cascade graph reaches the destructive
  host boundary through *separate* nodes — `UninstallCascadeLocalFoundation`,
  `ReadBackCascadeLocalAbsence`, `CommitCascadeCompletion`, `ReadBackCascadeCompletion` — and a node
  interpreter that ran the whole runner would collapse them: the durable cleanup run would record
  one node as having performed every later node's effect, and a resume would have nothing left to
  attribute a failure to. Stepping keeps the durable cleanup run and the durable host intent
  advancing together.
- **The step is not a weaker protocol.** It takes the same execution lease the whole-run
  entrypoints take, so two concurrent hosts still cannot interleave phases; it performs the same
  read-backs and the same exact bindings; and a step that ends leaves a resumable intent behind. The
  measurement is that stepping reaches the same completion over the same effects with the
  destructive uninstall still issued exactly once.
- Wiring these nodes into the descriptor-bound dispatcher was deliberately not done here; it landed
  on 2026-08-19 once the Authority restore boundary made a closed cascade host runtime constructible
  (checkpoints below), and the durable phase set was split so that one phase performs one node's
  effect.


### Current Implementation Checkpoint (2026-08-19, Authority restore boundary)

- The runner's last injected arm has a production answer.
  `Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction` implements
  `LifecycleAuthorityRestoreBoundary` over the authenticated Lifecycle Authority observation route
  and the physically separate Authority Backup Adapter, and adds the runner arm
  `productionHostCleanupAuthorityReestablish` beside the accept, read-back, and reconcile arms that
  already existed.
- **A cascade never mints an authority epoch.** Restoration succeeds only from `BackupEstablished`.
  Genesis-frozen, mid-genesis establishment, and repair-frozen are each reported as the distinct
  state they are rather than advanced, because an Authority that genesis re-opened would admit
  requests and have forgotten the run — exactly the empty control plane the ordering rule in
  doctrine § 5b node 7 exists to refuse. The genesis and repair choreography in
  `Prodbox.Lifecycle.Authority.BootstrapReconcile` is deliberately not reachable from this module.
- **The backup domain is the independent half.** The retained admission projection names its own
  `BackupReceipt`, and the Backup Adapter is asked whether that exact receipt is healthy, so the two
  halves are joined by a value neither of them was handed. A restoration decided from the
  Authority's own answer alone would be the writer deciding its own durability, which is the
  separation node 7 already insists on for the pre-uninstall report.
- **Only a transient failure is waited on.** A control plane that is not yet routable has said
  nothing and is retried under the bounded wait; a decided refusal and a terminal observation
  failure are answers, and retrying an answer would report a timeout where the run should report
  the refusal. The classification is the repository's shared transient table rather than a flag set
  at this call site.
- **Restoration is not admission.** Restoration decides which aggregate is being served; admission
  decides whether the control plane accepts work now. They are separate arms over separate fresh
  observations, so an Authority that is restored and then freezes for backup repair reads as not
  admitting rather than as never restored.
- Neither arm reaches an object store from the host. The Authority answers for its own retained
  projection through the closed authenticated protocol and the Backup Adapter answers for the
  backup domain through its own; a host-direct read of either namespace would be an unregistered
  escape path under Standard P.

### Current Implementation Checkpoint (2026-08-19, cascade host route)

- The four compiled cascade host nodes are dispatched.
  `Prodbox.ControlPlane.CascadeHostRuntime` is the closed host runtime — a durable host-cleanup
  record and a production effects record, with no caller-supplied continuation and no injected
  boundary — and the descriptor-bound dispatcher routes `UninstallCascadeLocalFoundation`,
  `ReadBackCascadeLocalAbsence`, `CommitCascadeCompletion`, and `ReadBackCascadeCompletion` to it
  instead of classifying them as unreleased.
- **The durable phase set now has one phase per node.** `HostCleanupIntentPhase` gained
  `HostCleanupLocalUninstallIssued` and `HostCleanupCompletionCommitted`, and the runner's actions
  split with them: issuing the uninstall, recording the absence, re-establishing the plane and
  reconciling the run, committing the completion receipt, and verifying it are five phases rather
  than three. Without the split a node interpreter would have attributed several nodes' effects to
  one node, which is exactly the collapse stepping exists to prevent.
- **The split did not weaken any read-back.** The issue phase still pre-checks absence, issues the
  destructive operation only when the foundation is present, and advances only from an exact absence
  read-back — so a lost uninstall response is still decided by the observation and a failed attempt
  still leaves the intent resumable at `HostCleanupTerminalArmed`, where it may re-issue. The
  absence node performs a fresh read-back and never issues: a phase that could re-issue would make
  the record of absence and the act of removal one node again.
- **A node that finds its phase already reached performs nothing.** The durable intent is the shared
  answer, so a rerun after a lost response observes that its effect is already durable rather than
  repeating it. That is what keeps the destructive uninstall issued exactly once across an
  interrupted cascade.
- **An observation failure is unconfirmed, never a refusal.** The runner reports "the mutation was
  issued and its read-back failed" and "a read-back failed on its own" through one typed error, and
  from the node's side the two are indistinguishable. Reporting that as a definite failure would let
  the run close a node whose effect is still outstanding.
- The cloud runtime refuses a cascade host operation that reaches it, the same way it already
  refuses a recovery-plane operation, so the route cannot silently fall back.

### Current Implementation Checkpoint (2026-08-20, the report reaches the independent domain)

- **The open decision is made: a fourth Authority-backup blob class, not a second addressing
  scheme.** Node 7 requires the independent Backup Adapter to read back the exact pre-uninstall
  report, and the adapter addresses objects only by `(class, digest)`. The alternative — a distinct
  retained namespace the adapter reads — would have given one adapter two addressing schemes and
  needed its own registered bucket prefix and its own least-privilege grant, for a value that is
  already a digest. `AuthorityCleanupReportBlob` is appended to `AuthorityBackupBlobClass`, and its
  objects land at `blobs/cleanup-report/sha256-<digest>` **inside the prefix the adapter's IAM grant
  already covers**, so no policy widens.
- **The constructor is appended rather than inserted.** The generic sum encoding tags constructors
  by declaration index, so appending is byte-compatible with every retained object already written;
  re-ordering would have made them undecodable. Sprint `4.87`'s enumeration gate — every class must
  name a distinct adapter object — is extended to the fourth member rather than left at three.
- **`Prodbox.ControlPlane.CleanupReportBackupClient` is the authenticated client for that one
  class.** It cannot select the aggregate, checkpoint, or config objects, and it refuses a receipt
  naming another class or another digest, so a reply that agrees with the request only by accident
  is not admitted.
- **`Prodbox.Lifecycle.Teardown.PreUninstallReportBackup` is the join.** It projects each adapter
  answer onto the Stage-C observation and is the only place the three dispositions are decided:
  a present receipt is `DurableReceiptObserved` carrying **the adapter's own digest** rather than
  the digest it was asked about, a missing object is `DurableReceiptMissing`, and a corrupt object
  or an unreachable domain is `DurableReceiptUnobservable`. Collapsing the last into the second
  would let an adapter nobody could reach read as "the commit never landed", which is the fail-open
  shape an independent read-back exists to exclude.
- **The observation is bound to the run that asked for it.** The receipt carries the compiled run's
  observation scope and graph digest, so the evidence constructor compares it against the binding
  rather than against itself; the regression exercises both directions — accepted by its own run,
  refused by another.
- **One bound is recorded rather than implied.** The adapter is content-addressed and re-hashes what
  it reads, so a report identity differing from the committed one presents as *missing* or
  *corrupt*, never as a successfully observed different digest. Stage C's
  `PreUninstallReportDigestDrift` arm stays reachable through the pure kernel, but this production
  reader cannot produce it, and the module says so.

### Current Implementation Checkpoint (2026-08-20, the Stage-C writing half)

- **Both Stage-C boundaries now have production surfaces, and neither is injected.**
  `Prodbox.ControlPlane.CascadeReportRepository` is the Authority's retained namespace for one
  run's committed report identity and its one-shot local-completion permit, and
  `Prodbox.Lifecycle.Teardown.PreUninstallReportCommit` is the `CascadeReportCommitBoundary` over it
  and the independent copy target.
- **The permit is one-shot by construction rather than by check.** Both slots are keyed by the
  `CleanupRunId` alone, the only write either can issue is into an empty slot, and there is no
  replace arm — so a second and different permit under one run is a conflict rather than a second
  key. Two permits under one run would be two licences to destroy the same host. An *exact* replay
  is a success, because a rerun that lost its response is what a resumable cascade does.
- **The bytes and the identity are checked against each other before anything is written.** A
  commit is asked for one `CascadeReportDigest` and the boundary holds the bytes that digest is
  supposed to name; if they do not hash to it the commit refuses, so the Authority never records an
  identity the replicated bytes do not have and the independent reader is never set up to confirm a
  name nothing produces.
- **The Authority write precedes the independent copy, and the order is load-bearing.** An identity
  the Authority holds with no copy beside it is a run that can retry the copy; a copy with no
  Authority record is an object nothing refers to. The regression measures the order rather than
  asserting it.
- **A failed replication is a lost response, not a refusal.** The copy's outcome is not decidable
  from this side — a transport failure may have landed — and Stage C reads the report back after
  *every* commit outcome precisely so the observation arbitrates. Reporting a definite refusal would
  decide the run from the weaker fact.
- **The permit that is returned is the durable one.** After the write the slot is read back and the
  grant is rebuilt from what the Authority holds, so a grant nothing recorded cannot reach
  `bindLocalCompletionPermit` merely because a write reported success.
- **The durable record states only what the compiled run cannot.** The report slot holds the run and
  the report digest; the permit slot holds the grant's own identities. Scope and graph digest are
  re-derived from the compiled program rather than stored, so the durable bytes and the running
  cascade have nothing to disagree about — unlike the durable readiness binding, which must restore
  a proof from bytes alone while the Authority is absent and therefore has to carry them.

### Current Implementation Checkpoint (2026-08-20, the report the digest is the digest of)

- **Stage C's two boundaries both took a `CascadeReportDigest` that nothing produced.**
  `Prodbox.Lifecycle.Teardown.PreUninstallReport` is what the digest is the digest *of*: the
  canonical bytes of the complete pre-uninstall cleanup report, and their identity.
- **The report is admitted, never merely rendered.** `PreUninstallReport` has no constructor
  reachable from a compiled program alone — it is built only from a program together with the three
  convergence evidences, and only when all three bind to that program. A report is a durable
  statement that *this* run reached exact absence, disposed its credentials, and passed its terminal
  audit, and the proof bindings are the only thing that can refuse a statement about the wrong run.
  `requireCascadeConvergenceBinding` is the private check it goes through, and it is deliberately
  the same three comparisons `mkReadyToUninstallEvidence` makes rather than a weaker prefix, so a
  report and the readiness composed from it cannot disagree about which run they belong to.
- **The enumeration comes from the compiled program, and that is not the weaker source.** The
  resources the report names are the exact-absence targets the program compiled, not a list an
  observer accumulated — which is the same set `mkCascadeAbsenceEvidence` required the observation
  set to equal *exactly*. Holding the absence evidence is therefore what makes the enumeration true,
  and deriving it from the program means a report cannot name more than was proven.
- **The bytes are canonical and the identity is their digest.** Keys are sorted and de-duplicated
  and the payload is a versioned record, so rendering one converged run twice yields the same bytes
  and the same identity. That is what lets a rerun after a lost response re-render its own report and
  find the Authority already holding exactly it, instead of committing a second identity for the
  same facts — the exact-replay arm the Authority slot depends on.
- **The report states identities, not narration.** No timestamps, no attempt counts, no operator
  prose: an identity a permit is signed over must be a function of what was proven, and anything
  varying between two renderings of one converged run would make the permit unrepeatable.
- **The identity is computed the way the independent adapter computes the name it stores the bytes
  under**, so the renderer, the commit boundary, and the adapter cannot disagree about what this
  report is called, and none of them is told another's answer.

### Current Implementation Checkpoint (2026-08-20, Stage C composed)

- Stage C is a chain rather than five surfaces that never met.
  `Prodbox.Lifecycle.Teardown.PreUninstallStageC` renders the pre-uninstall report from the compiled
  program and its three convergence evidences, commits it at the Lifecycle Authority, replicates it
  into the independent failure domain, reads it back from that domain, obtains the one-shot permit,
  and composes `ReadyToUninstallEvidence`. Before this every one of those surfaces existed and each
  was exercised only by its own regression.
- **The report identity is rendered, never supplied.** No caller names a `CascadeReportDigest`: it is
  the digest of the bytes this run rendered, and that one value is what the Authority is asked to
  commit and what the independent adapter is asked to confirm. While each half took the digest as an
  argument, a run could commit a report identity its own proofs do not produce; it now cannot.
- **Nothing is written before the report is admitted.** The three evidences must bind to the compiled
  program for the report to render at all, and that refusal returns before the commit boundary is
  constructed — measured as no client being reached at all when the proofs describe another run. A
  report is a durable statement that *this* run converged, so a run that cannot make the statement
  never reaches the surface that records it.
- **The same three evidences render the report and compose the readiness.** They are passed once and
  used twice, so the report a permit is signed over and the readiness that permit belongs to are
  statements about one run by construction rather than by the caller's discipline.
- **The permit is signed after the durability decision, not before it.** The measured order of one
  converged run is the Authority record, the independent copy, the independent read-back, and only
  then the permit, so the licence to uninstall is never issued ahead of the observation that
  justifies it.
- The composition activates no writer: nothing in the repository constructs it outside its own
  regression, and the two clients it takes are supplied by the caller. Composing it with the host
  runner and the restore boundary into a running cascade is the non-public candidate entrypoint this
  sprint still owns.

### Current Implementation Checkpoint (2026-08-20, the production effects record)

- The host cleanup runner's twelve injected arms are assembled.
  `Prodbox.Lifecycle.HostCleanupProductionEffects` is the assembly, and it is what
  `Prodbox.ControlPlane.CascadeHostRuntime` is handed to become a closed runtime. Every arm already
  had a production surface and nothing put them together, so the runner could only ever be driven
  by a fixture.
- **Every arm reads its own source and the record holds no mutable state**, so an arm asked twice
  observes twice. That is what keeps the runner's two readiness read-backs — the same question
  before the uninstall and again after re-establishment — two observations rather than one cached
  value.
- **The completion read-back derives its own prerequisites.** It needs the run's readiness and its
  observed local-uninstall evidence, and it obtains both by observing: the readiness from the
  Authority's durable slot, the absence from a fresh marker observation. Remembering what the commit
  arm was handed would have failed in exactly the case that matters most — a resumed run reaches the
  verification without issuing a commit at all, so a remembered value would be missing precisely
  when the run is closing.
- **A host that is not absent refuses that read-back**, because the receipt's meaning is that *this
  run* recorded its own local absence; asking the journal about a host whose markers are still
  present would compare a durable entry against a proof the run does not hold. A host that could not
  be observed stays a third answer.
- **The resolution mentions neither proof type.** It is polymorphic in both, so routing is all it
  can do — a signature naming `ReadyToUninstallEvidence` and `LocalUninstallEvidence` would have left
  room to inspect them — and the four-arm table is therefore exercised over stand-ins, with no
  Authority, no host, and no proof.
- **The injected surface is now exactly the five host mutations.** Installing a substrate from
  retained bytes, starting its service, awaiting its API, loading a retained image, and reconciling a
  recovery chart are the only effects the record does not supply. Everything the repair needs to
  *decide* is production: the substrate observation, and the retained-store listing, which
  `observeRetainedArtifactStore` now exposes from either root — listing is not a mutation, and a
  bootstrap-located root is what a recovery holds while the Authority is absent.
- Nothing in the repository constructs the record. Building its sources is the non-public candidate
  entrypoint this sprint still owns.

### Current Implementation Checkpoint (2026-08-20, the repair's host mutations)

- The last injected arm of the host cleanup runner has a production answer for four of its five
  acts. `Prodbox.Lifecycle.Teardown.RecoveryRepairProduction` installs the substrate from retained
  bytes, starts its service, awaits its API, and imports a retained image;
  `Prodbox.Lifecycle.Teardown.RecoveryRepairExecution` had deliberately shipped no production
  boundary at all.
- **The retained-artifact kind universe was short two kinds, and that is the finding this increment
  opened with.** It declared a substrate installer and a system-images archive, and an offline
  install also reads the release tarball and the checksum file the installer verifies it against —
  in one artifact directory, under fixed architecture-specific names. A repair rendered against the
  old universe would have admitted against the retained store and then refused at its first step on
  a real host. `RetainedSubstrateReleaseTarball` and `RetainedSubstrateChecksum` are now members,
  the absent-substrate obligation names all four, and every surface that enumerates the universe
  moves with it.
- **The installer reads exactly the verified bytes.** The install stages a directory of links to the
  verified retained files rather than copying, renaming, or re-fetching them, so the bytes the
  installer reads are the bytes the admission hashed — and the staged directory is outside the
  retained store, because custody measures store membership in both directions and scratch inside it
  would be collected as unreferenced. It is discarded on every path, including a failed install.
- **An incomplete install refuses before anything is staged**, measured as no command being issued at
  all. A missing artifact must be named by the run rather than discovered inside a root subprocess,
  where it can no longer say which byte source was absent.
- **Availability is read from the one substrate observer.** The API wait polls
  `Prodbox.Config.LocalRke2RecoveryState` rather than issuing a second health check, so the repair
  and the read-back that judges it agree by construction about what healthy means. The wait stops at
  the first healthy observation and an exhausted bound reports the last observation rather than a
  bare timeout, which is what keeps a stopped substrate and an unobservable one distinct.
- **The chart reconcile is supplied, not built here.** Reconciling a recovery chart is chart
  delivery, which sits above the lifecycle surface rather than beside it; taking it as an argument
  states that dependency instead of inverting it.
- One bound is recorded rather than implied: the install, start, and import invocations are a
  contract with the substrate's own tooling, and the regressions measure what this module decides
  through an injected physical boundary. That the external tools accept these exact invocations is a
  live-infrastructure proof and is not claimed.

### Current Implementation Checkpoint (2026-08-20, the host reaches its own retained slots)

- **The cascade's three retained slots had no production reader or writer on the host at all.** One
  run's accepted pre-uninstall readiness, its committed report identity, and its one-shot
  local-completion permit are all written against a `ModelBCasAdapter 'ClusterRetained`, and the only
  production adapter in the repository was the in-cluster one. A cascade runs on the host — that is
  what makes it a cascade — so `Prodbox.ControlPlane.HostCleanupReadinessRepository` and
  `Prodbox.ControlPlane.CascadeReportRepository` were constructible only from a fixture.
- `Prodbox.ControlPlane.CascadeRetainedSlotEndpoint` is the authenticated Authority route that closes
  the gap and `Prodbox.ControlPlane.CascadeRetainedSlotClient` is the host adapter over it. The
  adapter's type is the one the two repositories already take, so neither changed.
- **The namespace is closed, and that is the whole point of the route.** A generic
  "compare-and-swap any Authority object" boundary would have put the admission projection, the
  cleanup-run index, the decommission manifest, and every credential namespace one logical name away
  from a host — an escape path wearing a protocol. This route admits exactly three run-keyed slot
  families, by prefix *and* by the canonical slot digest the repositories derive, so a prefix with a
  traversal suffix is refused as surely as a foreign name.
- **The only write is an initialize**, because the wire type has no replace arm and no guarded arm.
  The no-replace property all three slots already had at their repositories is now a property of the
  protocol as well, which is what keeps the permit one-shot across a boundary the repositories do not
  own. A conflict carries the bytes already in the slot, because telling an exact replay from a
  genuine disagreement is exactly what the accept, commit, and grant protocols use that arm for.
- **Authority identity never crosses the wire.** The host names a slot; the Authority builds the
  coordinate from the authority it was configured with. A host therefore cannot address another
  cluster's retained namespace by construction, and there is no bucket, namespace, or cluster id on
  the wire to tamper with.
- **An unconfirmable answer is unobservable, never a refusal.** A failed call, an undecodable body, a
  response bound to a different request, and a status that disagrees with its own payload all leave a
  write that may have landed. Each becomes the unobservable arm of the Model-B result, so the run
  resolves it by observing rather than by concluding the opposite of what is durable. The applied arm
  carries only the object version and the caller reconstructs the value it sent, because an
  initialize applies exactly the bytes it was given and believing an echo would let a corrupted
  response rewrite the caller's own record of what it wrote.
- The route is refused for every caller except the operator CLI, is registered in the closed
  role/route registry like every other, and activates no writer: the endpoint is served by the
  Authority runtime and nothing in the repository constructs the host adapter yet.

### Current Implementation Checkpoint (2026-08-20, the sources are declared and assembled)

- **The retained-artifact inventory had no configuration surface at all.** Nothing in `src/` or
  `app/` constructed a `RetainedArtifactEntry`; the inventory and the source catalog existed only in
  tests, so the repair that consumes them could be rendered only against a fixture. They are now
  operator-declared Tier-0 config: `retained_artifacts` carries an architecture and a list of
  artifacts, and `prodbox-config-types.dhall` is regenerated from the same Haskell source of truth
  as every other section.
- **An artifact is declared once.** One entry projects into both the inventory and the source
  catalog, so the digest the acquisition promises the locator delivers and the digest the retained
  store is measured against are the same field. Two separately authored lists could disagree, and
  would, exactly when a recovery needed them — the run would acquire one artifact and then refuse
  the store that now holds it. An empty `source_url` declares an artifact that is retained and has
  no acquisition: a member of the inventory, not of the catalog, which is how custody reports it
  unsourced rather than inventing somewhere to fetch it from.
- **The declaration is validated by being projected**, inside `validateLocalConfig`'s positional
  match, rather than by a second list of shape rules that could drift from the projection. A
  malformed digest, an unsafe retained path, an unusable locator, a duplicate kind, or an
  unrecognized architecture or kind is refused at config load rather than at the moment a control
  plane is already gone and the repair is the only way back. An unrecognized token is *named*: a
  dropped entry would become an inventory that reports "nothing is retained" and then refuses for a
  reason that says nothing about the typo.
- **This required a split, and the split is the finding.** The vocabulary lived in
  `Prodbox.Config.OrdinaryTeardownRepair`, which also owns the repair matrix and therefore reaches
  the observed substrate state and, through it, the lifecycle surface — so `Prodbox.Settings` could
  not import it without a module cycle, and the declaration could not live in the config the repair
  reads. `Prodbox.Config.RetainedArtifacts` is the leaf that vocabulary now lives in, re-exported
  unchanged by the repair module, which also collapsed the two separate canonical-digest predicates
  the two halves had been carrying.
- **`Prodbox.Lifecycle.HostCleanupCompositionRoot` is the composition root.** Everything decidable
  without a session is decided first — the Tier-0 declaration, the retained root, the inventory, the
  catalog, the recovery closure, and the Authority coordinate — and only then are the two
  authenticated transports opened. A composition that authenticated first would have taken a session
  it cannot use and reported an operator's typo as an Authority failure; the local half is a value
  whose type mentions no transport, so the ordering is a fact rather than a comment.
- **One retained root feeds both roots**, so a run cannot read its artifacts under one root and
  append its completion beside another; **the repair inherits the declaration's architecture** from
  the projected inventory rather than a second supplied value; **the observation scope and the
  retained coordinate are derived from one cluster id**; and the Authority Backup Adapter session is
  opened beside the Authority session because that is what makes re-establishment's confirmation
  independent of the Authority being re-established.
- **The Tier-0 floor is the source, not the in-force projection**, and the consequence is stated
  rather than hidden: a cascade repairs a control plane that may be absent, so a declaration
  readable only through the Lifecycle Authority would be unreadable precisely when the repair exists
  to run — and an operator's retained-artifact change therefore reaches a recovery when it reaches
  `prodbox.dhall`.
- **The durable host-cleanup record comes from that same located root**, beside the artifact store
  and the completion journal, so a resumed run reads the phase it reached beside the bytes it
  reached it with. The record, the effects that act on it, and the session they were built over are
  handed over as one value because they are only meaningful together — and they are exactly what
  `mkCascadeHostRuntime` takes, so the closed cascade host runtime the descriptor-bound dispatcher
  admits is now constructible.
- Building the sources issues no host mutation and no wire call, and nothing in the repository calls
  the composition root: activating a writer is Sprint `6.5`'s.

### Deliverables

- Acquire/resume one durable cleanup run and derive substrate/account/region/cluster identity from
  its descriptor, never from residue.
- Repair/start or reinstall the Sprint-`3.41` minimal profile against preserved `.data`; restore
  exact Authority bytes from the independent backup when needed; scan old runs before new admission.
- Observe each target independently; attempt typed EKS drain only from positive EKS evidence; run
  controller/provider backstops through `RequiresAttempt`; re-observe exact absence.
- Run normalized escape audit only after exact resource convergence, then receipt-commit and
  independently read back the pre-uninstall report and obtain its one-shot completion permit.
- Make the candidate interpreter admit its local-uninstall node only from
  `ReadyToUninstallEvidence`. After uninstall, require exact host-absence read-back plus the matching
  read-back `LocalCompletionReceipt` before `CascadeCompleteEvidence` is constructible.
- On incomplete cleanup, render the stable `CleanupRunId`, return the exact failures and
  `RecoveryPlaneDisposition`, and retain every credential still required by a nonterminal
  obligation. Claim that the recovery profile and its credentials remain live only when the
  disposition is `Established`; `NotEstablished` and `Lost` make no liveness claim and do not by
  themselves authorize credential deletion.
- Preserve the public `cluster delete --yes` behavior and the currently active cascade writer in
  this sprint. Implement its distinct typed local-only program/result so it can observe local
  absence and complete without AWS/recovery evidence but has no constructor or conversion capable
  of claiming cascade completion.
- Implement replacement typed equivalents for the hand-written phases, inferred
  causality/substrate, no-RKE2 shortcut, and uninstall-on-incomplete behavior. Sprint `6.5` removes
  those legacy symbols when it activates the replacement as sole public writer.

### Validation

1. Frozen composition: Authority unavailable + one returned `ResourceTagMapping` carrying the
   retained bucket's full two-tag set + two decoder rows + three `Unobservable` exact stack
   observations reports one retained audit resource, selects no EKS drain/destroy from the audit,
   and preserves every exact-stack and Authority failure independently.
2. No plan with an incomplete exact obligation or a missing pre-uninstall report receipt,
   terminal-audit witness (clean scoped AWS audit or exact no-AWS projection), or completion permit
   can construct `ReadyToUninstallEvidence` or the uninstall node;
   no uninstall exit status without exact local absence and the matching read-back receipt can
   construct `CascadeCompleteEvidence`.
3. Local-only absent/install/uninstall/failure tables close only through
   `LocalUninstallEvidence 'LocalOnly`; neither that evidence nor an explicit one-stack target can
   inhabit aggregate cascade readiness/completion.
4. API stopped and API absent both derive the same bounded recovery-profile repair before exact
   observation; unrecoverable trust-root loss refuses without uninstall.
5. Original and all cleanup failures survive; dependency causality is carried by graph edges rather
   than inferred from simultaneous exit failures.
6. A second cascade resumes the same run or accepts its scoped read-back local-completion receipt
   idempotently; it does not allocate a second ambiguous provider operation or reinstall merely to
   rewrite completion history.
7. Fake-driven traces over this sprint's own surfaces cover success, failure, cancellation,
   response loss, and restart with exact keys, authorities, and `CleanupRunId`.
   **Re-scoped 2026-08-20 under
   [Standard N](development_plan_standards.md#n-phase-independence-and-execution-order).** The item
   previously required *installed CLI* traces and terminal narration. This sprint deliberately
   activates no public writer — the candidate entrypoint is package-private and nothing calls it —
   so there is no installed command whose narration could be traced, and the item was a Phase-4
   validation criterion only a Phase-6 composition could satisfy. Sprint `6.5` received the
   installed-binary and narration half as its validation item 10; this sprint makes no claim about
   it.

### Validation Result (2026-08-18, retained-artifact custody)

- 28 focused cases in `test/unit/LifecycleTeardownRetainedArtifactCustody.hs` cover the pinned
  source catalog's duplicate/foreign-architecture/malformed-digest/locator refusals; the plan over an
  empty, exact, mismatched, unreadable, and polluted store; the two-sided membership property; the
  complete unsourced set; a source digest that is not the pinned one; the fault matrix of a lost
  delivery, delivered bytes with the wrong digest, a failed placement, and a failed collection; that
  a failure of one obligation does not abandon the rest; that a successful delivery response is
  not accepted as evidence of retention; and the repair-readiness join over a matching, empty,
  corrupted, polluted, and unobservable store.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`, and
  `prodbox dev check` passes.
- This result covers the custody surface only. Validation items 1–7 above measure the cascade proof
  chain and remain open.

### Validation Result (2026-08-18, repair admission and execution)

- 19 focused cases in `test/unit/LifecycleTeardownRecoveryRepairExecution.hs` cover admission of all
  three matrix arms over an exact store; the absent arm's install/start/await ordering and the
  healthy arm's absence of any substrate step; that an admitted step carries the store-relative path
  and pinned digest the admission checked; that a store member the plan does not read never refuses
  the repair while custody still collects it; the empty-store, corrupt-artifact, unobservable-store,
  and unrenderable-plan refusals with the remedy each does or does not carry; the fault matrix of a
  failed install, an API that never arrives, and a failing chart, each with the exact unattempted
  tail and the exact boundary calls that did *not* happen; that the boundary is handed only
  store-relative artifact locations; and that convergence is decided from a fresh observation rather
  than from a run in which every step succeeded.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`, and
  `prodbox dev check` passes.
- This result covers the repair admission/execution surface only. Validation items 1–7 above measure
  the cascade proof chain and remain open.

### Validation Result (2026-08-18, Stage C pre-uninstall readiness)

- 13 focused cases in `test/unit/LifecycleTeardownPreUninstallReadiness.hs` read a package-private
  regression built over one fixed compiled cascade run. They cover readiness reached from an applied
  commit, from a lost commit response, and from a commit that reported a refusal after the write had
  landed; that the read-back is attempted exactly once even when the commit reported a refusal; the
  refusals for an applied commit whose report is not observed, an unobservable durable store, a
  drifted report identity, an unavailable permit, and a permit bound to another run; that a drifted
  identity never reaches the permit boundary; that readiness carries the independently observed
  report identity; and that one inhabitant of every refusal arm is produced by a real fault and
  renders as an operator-readable line.
- `Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal` gained one package-private fixture accessor
  so the Stage-C regression composes the *same* absence, credential, and audit evidences the
  evidence regression uses, rather than rebuilding a second fixture that could drift from it.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`, and
  `prodbox dev check` passes.
- This result covers the Stage-C protocol only. Validation items 1–7 above measure the whole cascade
  proof chain and remain open.

### Validation Result (2026-08-18, exact host-absence read-back)

- 6 focused cases in `test/unit/LifecycleHostCleanupLocalAbsence.hs` read a package-private
  regression over the same fixed cascade fixture the evidence regression uses. They cover an exact
  absent marker set becoming local uninstall evidence; a present marker set reported as still
  installed rather than as a failure; an unread marker set refused rather than treated as absence; a
  present marker outranking an unrelated read failure; a refusal when the durable record's scope and
  the readiness disagree; and the mapping of the three read-back answers onto the runner's three
  effect answers.
- The Cabal-hidden ownership-set gate recorded the new member deliberately, which is what that gate
  exists for: a module reaching the private evidence constructors is a decision with a stated
  reason rather than an import.
- Two further cases in `test/unit/HostCleanupIntent.hs` cover the record's derived location: the
  compiled directory-name constant, that it does not collide with the retained-artifact store under
  the same control directory, the exact composed record path, and that a relative or filesystem-root
  location is refused.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`, and
  `prodbox dev check` passes.
- This result covers the terminal node's observation half only. Validation items 1–7 above measure
  the whole cascade proof chain and remain open.

### Validation Result (2026-08-18, terminal escape audit)

- 8 focused cases in `test/unit/LifecycleTeardownCascadeTerminalAudit.hs` read a package-private
  regression over the same fixed cascade fixture. They cover that all five catalog queries are
  issued separately and in catalog order; that the derived audit scope is accepted by the evidence
  constructor; that one returned tag mapping carrying the retained state bucket's full two-tag set
  decodes as two rows for one resource and classifies as retained rather than as an escapee; that a
  prodbox-tagged resource no matcher retains is an escapee; that an unanswered query prevents a clean
  verdict; that a discovered escapee outranks an unanswered query; that two rows disagreeing about
  one resource refuse the audit outright; and that a region answering for no global service can never
  report clean.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`, and
  `prodbox dev check` passes.
- This result covers the audit's projection only; issuing its queries against a real provider is
  Sprint `7.36`'s adapter. Validation items 1–7 above measure the whole cascade proof chain and
  remain open.

### Validation Result (2026-08-18, local completion journal)

- 11 focused cases in `test/unit/LifecycleHostCleanupCompletion.hs` read a package-private
  regression over the same fixed cascade fixture. They cover an appended entry becoming the
  completion read-back; a repeated append of the same entry reported as already present rather than
  written twice; a durable entry that differs refused as a conflict rather than overwritten; a
  journal with no entry kept distinct from a journal that could not be read, with both refusing;
  that the read-back carries the decoded entry's run, graph digest, scope, operation reference, and
  observed entry digest rather than the running context's; an entry appended under another run's
  proofs refused; that an append which reported success over an entry that is then gone yields no
  receipt; that each entry is named by the digest of its reference; and the journal's derived
  location, its non-collision with the host-cleanup record and the retained-artifact store under one
  control directory, and its absolute non-root refusals.
- Three ownership gates recorded the new member deliberately, which is what those gates exist for:
  the Cabal-hidden cascade-evidence set, the retained-root locator-consumer set, and the
  completion-read-back producer set. The last of these replaced an export-list assertion with a
  library-scoped one: the read-back's constructor is now reachable inside the library, and what
  keeps it closed is the Cabal-hidden type of its receipt field, so a third producer has to be
  recorded rather than merely compiling.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4225/4225 (excluding the environment-dependent
  SSH validation case).
- This result covers the completion journal and its read-back only. Validation items 1–7 above
  measure the whole cascade proof chain and remain open.

### Validation Result (2026-08-18, credential disposition)

- 10 focused cases in `test/unit/LifecycleTeardownCascadeCredentialDisposition.hs` read a
  package-private regression over the same fixed compiled cascade run. They cover that every
  disposable class is asked about exactly once and in inventory order; that the Lifecycle-provider
  credential is in the retained set and unreachable through the boundary; that disposition is
  reported only when every class was observed absent; that a still-present credential is
  outstanding and an unanswered one is unobservable; that a present credential outranks an
  unanswered one; that the disposed observation is accepted and the outstanding one refused by the
  evidence constructor; that the disposable and retained sets partition the inventory; and that the
  single refusal renders.
- The Cabal-hidden cascade-evidence ownership set recorded the new member deliberately.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4235/4235 (excluding the environment-dependent
  SSH validation case).
- This result covers the credential-disposition projection only; issuing its observations against a
  real provider is Sprint `7.36`'s adapter. Validation items 1–7 above measure the whole cascade
  proof chain and remain open.

### Validation Result (2026-08-18, recovery-plane runner arms)

- 9 focused cases in `test/unit/LifecycleHostCleanupRecoveryPlane.hs` cover the read-back's
  one-to-one mapping of healthy, stopped, absent, and unread onto available, unavailable, and
  unobservable; that the check carries the scope it was given; that a stopped substrate's detail is
  distinct from an unread one's; and, over a real admission against a fixed retained inventory,
  catalog, and recovery closure: that the repair the observed state needs is applied in order, that
  an applied repair projects to `Applied` and claims no availability, that a failed step stops the
  run and carries the unattempted tail as a refusal, that an unadmittable repair refuses with no
  boundary call at all, that an unobservable substrate selects no repair, and that every attempt
  renders.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4244/4244 (excluding the environment-dependent
  SSH validation case).
- This result covers the recovery-plane arms only. Validation items 1–7 above measure the whole
  cascade proof chain and remain open.

### Validation Result (2026-08-18, Authority runner arms)

- 15 focused cases in `test/unit/LifecycleHostCleanupAuthorityArms.hs` cover, over the
  package-private cascade-evidence fixture and an in-memory retained store: that an accepted
  readiness reads back as the exact proof the runner holds, that accepting twice is an applied
  replay rather than a second slot, that a second different readiness under one run is refused in
  both the acceptance and the read-back, that readiness belonging to another run is refused, that a
  slot holding nothing stays distinct from one that could not be read, and that an acceptance which
  reported applied over an emptied slot still produces no proof; that a failed restore never awaits
  admission and a completed restore projects to `Applied` without claiming readiness, with every
  re-establishment arm rendering and every non-restored arm refusing; and that the run
  reconciliation issues the same two commands under the same deterministic attempt on a rerun,
  refuses a run the Authority does not hold, and reports a transport failure as a lost response.
- The Cabal-hidden ownership-set measurement in `test/unit/LifecycleTeardownCascadeEvidence.hs`
  records both new members with the reason each needs the private surface: the repository decodes
  the durable binding at the object-store seam so corrupt bytes are classified as corrupt and never
  restores a proof, and the arms are the only surface that captures a binding for acceptance and
  restores one back into readiness.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4259/4259 (excluding the environment-dependent
  SSH validation case).
- This result covers the Authority runner arms only. Validation items 1–7 above measure the whole
  cascade proof chain and remain open.

### Validation Result (2026-08-18, single-phase host runner)

- Two further cases in `test/unit/HostCleanupRunner.hs` cover the stepped driver over the same fixed
  fault-matrix fixture: that stepping reaches the same completion the whole-run entrypoint reaches,
  over the same effects and with the destructive uninstall still issued exactly once, and that one
  step advances exactly one phase — the first step over a `Prepared` intent leaves the durable record
  at `AuthorityAccepted` and goes no further.
- The whole-run entrypoints are now defined in terms of the same single-phase body, so the existing
  unbound-refusal, full-topology, response-loss, no-repeat, wrong-readiness, missing-completion, and
  concurrent-lease cases continue to measure both callers.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4261/4261 (excluding the environment-dependent
  SSH validation case).

### Validation Result (2026-08-19, Authority restore boundary)

- 18 focused cases in `test/unit/ControlPlaneLifecycleAuthorityRestore.hs` cover the restore arm over
  an established-and-healthy aggregate, a genesis-frozen and a repair-frozen projection kept distinct
  from each other, an unhealthy independent backup, and the two-sided join measured as the backup
  domain being asked about exactly the receipt the projection named — and being asked nothing at all
  when the projection is not established.
- The bounded wait is measured by its pause count rather than by its wall clock: a transient
  unroutability is waited on once and then succeeds, a decided refusal and a terminal decode failure
  are not waited on at all, and a wait that would take no observation is refused at construction.
- The admission arm is measured on both sides of the bound: a starting control plane is waited for
  and then admits, and an exhausted bound reports the last decided state rather than an
  unobservability.
- The composed boundary is exercised through `reestablishLifecycleAuthority`, so the ordering rule is
  measured where the runner injects it: a failed restore observes the admission state exactly once in
  the whole re-establishment, which is the restore's own observation and no other.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4280/4280.

### Validation Result (2026-08-19, cascade host route)

- 5 focused cases in `test/unit/ControlPlaneCascadeHostRuntime.hs` measure the closed runtime: the
  four cascade host operations classify to four *distinct* durable phases and every other operation
  is refused, an observation failure maps to `CleanupNodeEffectUnconfirmed`, a definite runner
  refusal maps to `CleanupNodeFailed`, and the store, effects record, operation, and action stay
  package-private.
- The dispatcher regression gained a fourth route inventory: the cascade host route carries exactly
  4 of the 41 compiled shapes, the unreleased inventory drops from 23 to 19, and the cloud (14) and
  recovery (3) inventories are unchanged. The exercise now dispatches a real cascade host node
  through the dispatcher and measures that it reaches the closed runtime and never the cloud runtime
  — zero provider calls and a refusal naming the empty durable record.
- The runner's existing fixed fault matrix is unchanged and still passes over the split phases:
  exact success, response-loss replay, confirmed-absence-not-repeated, wrong-readiness refusal,
  missing-completion refusal, concurrent-lease fencing, stepped topology, and one-phase-per-step.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4286/4286.

### Validation Result (2026-08-20, the report reaches the independent domain)

- 7 focused cases in `test/unit/LifecycleTeardownPreUninstallReportBackup.hs` measure the
  projection against a package-private compiled-run fixture: present is observed, present carries
  the **adapter's** identity rather than the caller's question, missing stays distinct from
  unobservable, corrupt is unobservable, an unreachable domain is unobservable and **not** missing,
  and the resulting observation is accepted by its own run and refused by another. No compiled
  cascade program, evidence value, or report digest leaves the package.
- Sprint `4.87`'s class enumeration is extended and still measures what it measured: all **4**
  classes name an adapter object, and all 4 names are distinct. The count is pinned deliberately so
  a fifth class forces a decision there rather than passing by construction.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, the Stage-C writing half)

- 8 focused cases in `test/unit/LifecycleTeardownPreUninstallReportCommit.hs`, each produced by
  running the boundary against the fault rather than by asserting its classification: both halves
  landing is `Applied`; the Authority write is measured to precede the copy; an identity that does
  not name the bytes refuses; a second and different report identity refuses; a failed copy is a
  lost response and **not** a refusal; the granted permit is bound to the committed report; a
  replaying run receives the durable grant rather than a fresh one; and a permit for a different
  report under the same run refuses.
- No Authority, compiled cascade program, report digest, or permit grant leaves the package: the
  fixture runs against an in-memory `ClusterRetained` slot store and an in-memory copy target, and
  the suite reads only booleans.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, the report the digest is the digest of)

- 6 focused cases in `test/unit/LifecycleTeardownPreUninstallReport.hs` over a package-private
  compiled-run fixture: one converged run renders to the same bytes and the same identity twice; the
  identity is the digest of the bytes; the enumeration is exactly the compiled exact-absence
  targets; describing a program with another run's proofs refuses; two distinct converged runs get
  two distinct identities; and the identity this module derives is the identity the commit boundary
  derives from the same bytes.
- The last of those is the join the rest of Stage C rests on and is measured rather than assumed.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, Stage C composed)

- 8 focused cases in `test/unit/LifecycleTeardownPreUninstallStageC.hs` over a package-private
  compiled-run fixture, an in-memory `ClusterRetained` Authority slot store, and an in-memory
  independent domain: a converged run reaches readiness; the readiness carries the identity of the
  report the run rendered; the measured call order is Authority record, independent copy,
  independent read-back, permit; proofs describing another run refuse; that refusal reaches no
  client at all; a domain that accepted the copy and holds nothing is not ready; a domain that
  answers nothing is not ready; and the same converged run run twice re-renders one identity.
- Every property is produced by running the composition against the fault that causes it rather than
  by asserting a classification, so an arm the chain stops producing disappears from the result
  instead of surviving as an authored constant.
- No compiled program, evidence value, report identity, or readiness proof leaves the package; the
  suite reads only booleans.
- `prodbox dev check` exits 0 with the new module and suite in the region, and the library and unit
  surface build warning-clean under `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, the production effects record)

- 5 focused cases in `test/unit/LifecycleHostCleanupProductionEffects.hs` over the completion
  read-back's closed prerequisite table: both observations answered resolves to exactly the pair it
  was handed; an Authority holding no readiness refuses before the markers are consulted; a host
  whose markers are present refuses; a host that could not be observed is a third answer; and the
  three refusals render as three distinct answers.
- The table is exercised over stand-in values rather than proofs, which is what measures that the
  resolution routes and never inspects: a resolution that read either proof could not typecheck
  against them.
- The remaining eleven arms are one production surface applied to one source each, and each of those
  surfaces is measured by its own regression. The end-to-end exercise of the assembled record is the
  candidate entrypoint's fault matrix, which this sprint still owns and which is stated as remaining
  rather than implied by this result.
- Assembling the record exposed a gate reading its own spelling rather than the fact it measures.
  The rule that only the completion journal may mint a `HostCleanupCompletionReadBack` matched the
  type name as a *substring*, so a module that merely calls the production arm
  `productionHostCleanupCompletionReadBack` was reported as a third producer. It now matches the
  name as a token, and it is proven to refuse rather than only to pass: a standalone mention added
  to a third source file fails the case, and removing it restores the pass.
- `prodbox dev check` exits 0 with the new module and suite in the region, and the library and unit
  surface build warning-clean under `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, the repair's host mutations)

- 9 focused cases in `test/unit/LifecycleTeardownRecoveryRepairProduction.hs` over an in-memory
  physical boundary: the install stages exactly the four expected names against the four
  store-resolved paths; it runs the installer over the staged directory and discards it; an
  incomplete install stages nothing and issues nothing; a failed install still discards; the start
  enables and starts in one act; the wait stops at the first healthy observation with no pause; an
  exhausted wait observes exactly its bound and reports the last observation; the image import
  addresses the store-resolved path; and the chart arm is delegated with no command issued here.
- The kind-universe extension is measured by the existing Sprint-`3.41` matrix moving with it: the
  absent-substrate obligation, the unretained-artifact refusal's complete missing set, the rendered
  install step's references, and the custody read-back's residue all now name four substrate kinds,
  and the whole unit suite passes at 4344.
- `prodbox dev check` exits 0, and the library and unit surface build warning-clean under
  `--enable-tests --ghc-options=-Werror`.

### Validation Result (2026-08-20, the host reaches its own retained slots)

- 16 focused cases in `test/unit/ControlPlaneCascadeRetainedSlot.hs` cover the closed namespace
  measured against the names the two repositories actually derive (so a rename there fails this
  route rather than silently stranding the host); a foreign name, a cascade prefix with a
  non-canonical slot key, a malformed body, an oversize body, an unsupported format version, and an
  oversize slot value each refused without the object store being reached; the conflict arm carrying
  the observed bytes; every response arm bound to the exact request digest and format version; the
  host side refusing a foreign name, a replace, and both guarded arms before a request is issued; an
  applied value reconstructed from the bytes the caller sent; a lost or unconfirmable response
  reported as unobservable; and missing/observed round-tripping.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4359/4359 with the known-environmental SSH case excluded, and the three auxiliary control-plane
  suites are 27/27, 33/33, and 29/29.
- This result covers the route and its host adapter only. Validation items 1-7 above measure the
  cascade proof chain and remain open. That the route behaves this way against a deployed Authority
  is a live-infrastructure proof and is not claimed.

### Validation Result (2026-08-20, the sources are declared and assembled)

- 10 focused cases in `test/unit/OrdinaryTeardownRepair.hs` cover the empty declaration; one
  declaration projecting into both surfaces carrying one digest; the architecture reaching both
  surfaces; an unsourced artifact staying in the inventory and out of the catalog; an unrecognized
  kind and an unrecognized architecture each named rather than dropped; and a malformed digest, an
  unsafe retained path, a non-`https` locator, and a duplicate kind each refused.
- One case in `test/unit/Main.hs` measures the config-load gate itself: an empty declaration loads,
  a foreign architecture and a malformed digest are refused by `validateLocalConfig`.
- Three cases in `test/unit/HostCleanupCompositionRoot.hs` measure the ordering property — a
  directory with no Tier-0 floor is refused with a local error rather than an authentication
  failure — that the artifact store, the completion journal, and the durable record all derive from
  one locator, and that every refusal renders distinctly so an operator is told which surface to
  fix.
- `test/unit/LocalRetainedRoot.hs`'s bootstrap-locator consumer registry gains the composition root
  with its admission recorded: it holds the locator only to hand one located root to the store and
  the journal.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4373/4373 with the known-environmental SSH case excluded.
- This result covers the declaration and the composition root only. Validation items 1-7 above
  measure the cascade proof chain and remain open; that the assembled record drives a real host is a
  live-infrastructure proof and is not claimed.

### Current Implementation Checkpoint (2026-08-20, the cloud half could not be composed)

- **The cloud runtime had no production composition root at all.**
  `Prodbox.Lifecycle.Teardown.CloudRuntime` normalizes four interpreters into the closed dispatcher
  for the fourteen cloud-owned operations, and nothing in `src/` or `app/` constructed one: the only
  inhabitants in the repository were the dispatcher's own fixed diagnostic and a unit fixture. The
  descriptor-bound dispatcher therefore admitted a closed cascade *host* runtime it could construct
  and a closed *cloud* runtime it could not.
  `Prodbox.Lifecycle.Teardown.CloudRuntimeProduction` is that root.
- **Two durable records were unreachable from a host, and that is the finding this increment opened
  with.** The complete ownership manifest decision and the AWS stack creation binding are each keyed
  by an authority identity whose derivation is private to the repository module that owns the record
  — and both host-reachable transport clients take that identity as an *argument*. A host holding
  either client could therefore not address the record at all, so two of the stack reader's three
  durable inputs had no production reader.
  `readBackOwnershipManifestDecisionForScope` and
  `readBackCommittedAwsStackCreationBindingForScope` are the derivations, keyed by the stack and the
  run's own observation scope and nothing else.
- **The manifest target is rebuilt from the scope's surface rather than chosen.** A rank-2 reader
  over `forall surface` has no witness to give, and `mkOwnershipManifestTarget` needs one.
  `cleanupSurfaceWitnessFor` recovers it from the scope the run already carries, which is the
  opposite of choosing one: it is the only witness that can satisfy the surface checks the scope
  itself imposes, so a reader cannot name a surface the scope does not carry.
- **The EKS drain interpreter carried two arms no production caller could inhabit.** It held a
  session-acquisition arm and the ephemeral-client boundary that arm's session opens, and neither is
  reachable from the descriptor-bound path: the three entry points the EKS teardown executor uses go
  through the commit-selection and attempt boundaries, which issue their own Provider auth and build
  their own session. The acquisition arm was moreover *unproducible*, because the session it must
  return needs a fresh `VerifiedAwsEksObservation` that `EksDrainInvocationBinding` does not carry —
  a production composition had no honest value to put there. Both arms moved to
  `EksDrainSessionArms`, taken explicitly by the four session-driven entry points, so the interpreter
  a production cloud runtime builds names exactly the clock it uses.
- **The ephemeral facts a selection needs are derived, not sampled.** A drain intent is committed
  durably and a resumed run must re-derive the same one, so the two observation revisions come from
  the attempt's own operation identity under two distinct dispatch purposes. Sampling a counter here
  would let a replay commit a second intent for one operation, which is exactly the ambiguity the
  durable intent exists to remove.
- **Liveness is the only thing a clock decides.** The drain deadline is `now + lease` under an
  operator-declared lease bounded *at construction* by the session module's own ceiling, so a
  deadline this runtime computes cannot be refused later by `mkEksDrainSession` for a reason an
  operator could only discover mid-cascade. The execution identity the deadline callback receives
  supplies no freedom, which is why it is ignored rather than consulted.
- **One registered-target interpreter, by construction.** Checkpoint recovery, EKS drain, and
  registered reconciliation must address the same Provider boundary; the composition builds exactly
  one interpreter and lets `mkCloudRuntime` normalize it, and the recursion this creates is the
  point — the stack reader's checkpoint input is the same checkpoint interpreter the graph's own
  recovery nodes use, so the pair a stack decision is taken over and the pair a recovery read back
  cannot be two observations of different authorities.
- Nothing in the repository constructs the runtime outside its own regression, and building it
  issues no AWS mutation and no wire call. Composing it with the closed cascade host runtime behind
  the non-public candidate entrypoint is the item this sprint still owns.

### Validation Result (2026-08-20, the production cloud runtime)

- 5 focused cases in `test/unit/LifecycleTeardownCloudRuntimeProduction.hs` drive the real runtime
  over a fake *wire* rather than fake components, so every arm under test is the production client.
  They cover the drain lease's closed bound at both ends with the accepted value preserved; that
  every refusal renders as a bounded operator-readable line naming its cause; that the runtime is
  constructible on a host from one authenticated Authority transport; that every cloud-owned cascade
  node that reaches a boundary reaches the local Lifecycle Authority endpoint and exactly one
  authority — an arm that had opened an object store, a Vault session, or a provider CLI of its own
  would leave no call recorded at all; and that an unavailable Authority closes *only* the three
  checkpoint-pair observers, which is their job, while every node that would have had to decide
  something from that outage fails instead.
- The succeeding set is pinned rather than merely asserted non-empty, because "something failed" is
  what a component closing a mutation from its own request would also satisfy.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`, and `prodbox dev check` passes.
- This result covers the cloud runtime's composition and routing only. That its arms reach a real
  Lifecycle Authority and a real AWS account is a live-infrastructure proof and is not claimed;
  validation items 1-7 above measure the cascade proof chain and remain open.

### Current Implementation Checkpoint (2026-08-20, the candidate entrypoint)

- **Both closed runtimes the descriptor-bound dispatcher takes were constructible and nothing drove
  the dispatcher.** `Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal` is that drive: it
  resolves the compiled program, the declared initial run, the canonical program descriptor, the
  host scope, and the terminal identity as one transport-free value; opens the two authenticated
  sessions through the host composition root; builds the cloud runtime and the cascade host runtime
  over the same transport; and runs the total dispatcher across the durable descriptor-bound run.
- **The entrypoint is non-public and stays that way.** It is Cabal-hidden and its facade exposes
  four booleans, exactly as the dispatcher and the cascade host runtime do; nothing in the
  repository calls it. Activating it as the sole public writer and deleting the legacy route is
  Sprint `6.5`'s qualified cutover, which this sprint makes no claim about.
- **The durable-cascade entry protocol was on the wrong side of a boundary, and that is the finding
  this increment opened with.** Capturing the program descriptor, preparing the host intent
  *before* any mutation, observing-or-creating the run, claiming it, attaching the primary outcome,
  and reading the terminal report back independently before compacting are what **any** caller of
  the descriptor-bound protocol must do — none of it is validation-specific. It lived in
  `Prodbox.Test.*`, and the Sprint-`4.85` harness-namespace gate refused the first production caller
  outright. The remedy the gate itself names is "express the obligation in lifecycle-owned types",
  so the module moved to `Prodbox.Lifecycle.CleanupRunEntry` rather than the allowlist being
  widened. The validation harness remains a client of that protocol; it is no longer its owner.
- **The plan is a function of the declared identity, so re-entry replays rather than forks.** The
  program descriptor digests the initial run, and the initial run's lease is a *declared* window
  rather than a clock sample — so two entries with the same inputs derive the same descriptor and
  the Authority replays the run it already holds. Sampling a clock here would make every resume a
  different program, which is precisely how a cascade would end up with two runs destroying one
  host. A degenerate declared window is refused rather than admitted.
- **The terminal identity is compiled, not authored.** The durable host record's terminal operation
  is the operation id the compiled program gave its `UninstallCascadeLocalFoundation` node, so the
  record and the graph cannot disagree about which node is licensed to destroy the host. The
  regression computes both sides rather than checking the identity is non-empty, because a non-empty
  identity would also be satisfied by one the graph never gave.
- **One repository root and one caller for both halves.** The cloud half's Provider dispatch reads
  them out of the host composition inputs rather than taking its own, because a cloud half
  authenticating as a different caller than the host half would be two cascades sharing a run id.
- **The cascade is its own primary work.** There is no separate action whose failure the cleanup
  would be reacting to, so the primary outcome is recorded as a fact about the run rather than as an
  observation of something else.
- The dispatcher's Internal-module importer gate and the stack-reader transport client's
  zero-importer gate both recorded their new member deliberately, which is what those gates exist
  for: a module reaching a package-private construction is a decision with a stated reason rather
  than an import.

### Validation Result (2026-08-20, the candidate entrypoint)

- 4 focused cases in `test/unit/LifecycleTeardownCascadeCandidate.hs` read the entrypoint's fixed
  non-authorizing regression: that two resolutions of one declared cascade identity produce one
  program descriptor, graph digest, and run id; that the durable host record's terminal operation
  equals the compiled program's local-uninstall operation id, computed independently on both sides;
  that a declared lease window of zero is refused as an invalid initial run; and that a different
  declared run id produces a different program descriptor, so two cascades cannot share one.
- `test/unit/ControlPlaneDescriptorBoundLifecycleRuntime.hs` and
  `test/unit/ControlPlaneAwsStackReaderRepository.hs` each record their new package-private importer
  by name, so a third one is a build failure rather than a silent widening.
- `test/unit/LifecycleCleanupClient.hs` follows the entry protocol to its new lifecycle-owned path;
  its own no-validation-owned-graph assertions are unchanged.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4382/4382 with the known-environmental SSH case excluded.
- This result covers the entrypoint's transport-free half and its ownership boundaries. Driving a
  real cascade is a live-infrastructure proof and is not claimed.

### Current Implementation Checkpoint (2026-08-20, the local-only surface could claim a cascade)

- **`LocalUninstallEvidence` stood for both surfaces at once, and only a caller's discipline kept
  them apart.** Validation item 3 names a `LocalUninstallEvidence 'LocalOnly`, and the type carried
  no index: nothing but convention stopped a local-only host observation from being handed to
  `mkCascadeCompleteEvidence`, which would have claimed a cascade converged on the strength of an
  observation that says nothing about AWS. The type is now indexed by the surface whose compiled
  program licensed the uninstall, both constructors are private, and there is deliberately no
  conversion in either direction — the confusion is a type error rather than a runtime refusal.
- **The local-only surface closes on its own terms.** `mkLocalOnlyUninstallEvidence` is licensed by
  the compiled local-only program alone, and `mkLocalOnlyCompleteEvidence` confirms the receipt that
  surface's own node commits. There is no report identity and no permit to compare, because the
  local-only surface signs neither — which is precisely why its completion cannot stand in for a
  cascade's. `LocalOnlyCompleteEvidence` is a separate type for the same reason.
- **The binding is a distinct type, validated by the opposite rule.** A cascade binding refuses a
  missing AWS scope; a local-only binding refuses a present one, so a value that satisfies one
  cannot satisfy the other. That check is measured where it is *decidable*: a local-only program
  carrying an AWS scope does not compile at all, so no such program can reach the binding. The
  binding keeps its own check anyway, because this module must not depend on another module's
  invariant to know that a local-only proof names no stack.
- **The scope, present, and unobservable rules are shared rather than re-decided.** Both surfaces
  reach absence through one `localFoundationAbsence`: an observation of another scope is a refusal, a
  present foundation has not converged, and an unobservable one has said nothing. Collapsing the last
  two would let an unreadable marker set read as absence, on either surface.
- Nothing in production constructs the local-only evidence yet; it is exercised by the fixed
  regression. Driving it from an installed command is the public writer Sprint `6.5` activates.

### Validation Result (2026-08-20, the local-only surface)

- 4 further arms in `fixedCascadeEvidenceRegression`, read by one case in
  `test/unit/LifecycleTeardownCascadeEvidence.hs`: that the local-only chain closes from an observed
  absence and its own committed receipt; that a local-only program carrying an AWS scope does not
  compile; that a missing local-only receipt refuses the completion; and that a still-present
  foundation refuses the absence. There is deliberately no arm for handing local-only evidence to
  `mkCascadeCompleteEvidence`, because that does not type-check.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4383/4383 with the known-environmental SSH case excluded.

### Current Implementation Checkpoint (2026-08-20, the frozen composition)

- **Every piece of validation item 1 had its own regression and nothing composed them.** The
  composition is the claim: the audit reports one retained resource from one returned two-tag
  mapping, no cloud node consumes what the audit saw, and every exact per-stack failure survives as
  its own node's outcome rather than being folded into one verdict — which is the exact defect an
  aggregate exit status invites and the one the legacy cascade's phase fold still has.
- **The region bound and the retained classification are independent, and the case pins both.** The
  frozen run's own region answers for no global service, so a would-be-clean verdict is downgraded
  to unobservable on the region bound alone; asserting only "not clean" would have passed even if
  the retained bucket had been classified as an escapee. The case therefore pins the inventory at
  one resource, pins that no escapee was found, and pins that every carried failure names the
  tagging API's endpoint rather than anything the returned mapping said.
- **No EKS drain or destroy can be selected from the audit, and that is structural.** The cloud
  runtime does not own `AuditCascadeEscapes` — it declines the operation rather than answering it —
  so the measurement is that driving every cloud-owned node issues zero audit queries while the
  audit, issued against its own boundary, issues exactly its catalog.

### Validation Result (2026-08-20, the frozen composition)

- 4 focused cases in `test/unit/LifecycleTeardownCascadeFrozenComposition.hs` over the production
  cloud runtime with the Authority answering 503: the three exact per-stack observations produce
  three separate failed node outcomes; the audit's two returned rows for one ARN report one retained
  resource, no escapee, and an unobservability attributable only to the region bound; driving every
  cloud-owned node issues no audit query at all; and the audit node is declined rather than answered.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4387/4387 with the known-environmental SSH case excluded; `prodbox test integration cli` and
  `prodbox test integration env` are 61/61 each.

### Current Implementation Checkpoint (2026-08-20, two harness defects the closure found)

Running this sprint's Definition of Done end to end — `prodbox test integration cli` and `env`, not
only `dev check` and `prodbox test unit` — found six failing integration cases that no gate had been
reading, and both causes were in the harness rather than in the command under test.

- **The fixture Authority served a config projection whose digest could never match its bytes.**
  `fixtureInForceConfig` declared a fixed literal digest while `fixtureConfigBytes` rendered the real
  operator config, so every caller that validated the projection refused it as non-canonical. A
  fixture that answers for a config must answer with that config's own identity; anything else
  measures the fixture. The identity is now derived from the exact bytes served, on both the observe
  and the propose-cas arm.
- **The fixture repository had no retained-root layout at all.** `Prodbox.Config.LocalRetainedRoot`
  validates the prodbox control directory, the retained MinIO volume under it, and the retained Vault
  volume beside it before an Authority-bound root exists, and the harness created none of them — so
  every reconcile refused with a layout error before reaching the behaviour the case was written to
  measure.
- Neither defect is in a production path and neither changes one. What they show is that a suite the
  Definition of Done requires had been failing while the gates it runs beside were green, which is
  why closure ran it rather than assuming it.

### Validation Coverage Map (2026-08-20)

Where each numbered item above is measured today, and what is open. An item is listed as measured
only when a named regression exercises it; "structural" means the property holds because the value
is non-constructible otherwise, and the refusal is what is measured.

| Item | Measured by | State |
|---|---|---|
| 1 | `test/unit/LifecycleTeardownCascadeFrozenComposition.hs` (the composed frozen run), over `test/unit/LifecycleTeardownCascadeTerminalAudit.hs` (the two-tag mapping decoding as two rows for one retained resource, the disagreeing-row refusal, the blind-query downgrade) and `test/unit/LifecycleTeardownCloudRuntimeProduction.hs` (every AWS-scoped cloud node failing independently under an unavailable Authority) | Measured |
| 2 | `test/unit/LifecycleTeardownCascadeEvidence.hs` over `fixedCascadeEvidenceRegression`: absence, credential, audit, pre-uninstall, permit, mixed-binding, local-absence, and completion refusals | Measured |
| 3 | `test/unit/LifecycleTeardownCascadeEvidence.hs`, local-only arms (checkpoint above); the cross-surface confusion is a type error | Measured |
| 4 | `test/unit/OrdinaryTeardownRepair.hs` (the image obligation identical in every observed state; stopped renders start+await, absent renders reinstall+start) and `test/unit/HostCleanupRunner.hs` (`HostCleanupRunnerReadyBindingMissing`) | Measured — the trust-root half is structural: every path to the uninstall node runs through an accepted readiness only a re-established Authority can produce |
| 5 | `test/unit/LifecycleTeardownRecoveryRepairExecution.hs` (the unattempted tail preserved at the first failure) and the cleanup-run graph regressions | Measured |
| 6 | `test/unit/LifecycleHostCleanupCompletion.hs` (the reference-keyed idempotent append), `test/unit/HostCleanupRunner.hs` (a phase already reached performs nothing), and `test/unit/LifecycleCleanupClient.hs` (observe-or-create resolving a lost create response) | Measured |
| 7 | `test/unit/LifecycleCleanupClient.hs` (cancellation), `test/unit/HostCleanupRunner.hs` (restart and response loss), `test/unit/ControlPlaneDescriptorBoundLifecycleRuntime.hs` (typed refusal) | Measured on this sprint's surface; the installed-CLI and narration half is Sprint `6.5`'s validation item 10 |

### Remaining Work

Acquiring, retaining, and garbage-collecting the artifact bytes the Sprint-`3.41` recovery plans name
landed on 2026-08-18, and the recovery path that *consumes* that custody landed with it: a rendered
repair is admitted only from an observation of the retained store, and a refusal carries the custody
plan that closes it (checkpoints above). What is still open in that item is the production boundary
for the admitted steps, which is part of the candidate entrypoint below rather than a separate
surface.

The Stage-C pre-uninstall interpreter landed on 2026-08-18 as the protocol (checkpoint above); what
is still open in that item is the wiring of the real Authority commit client and the real
Backup-Adapter read-back client into its two boundaries, which is part of the candidate entrypoint
below rather than a separate surface.

The exact host-absence read-back landed on 2026-08-18 (checkpoint above), giving the terminal node's
observation half a production implementation, and the host-completion record gained a location
derived from the exact bootstrap locator rather than from a caller-supplied path. The completion
receipt half landed on 2026-08-18 with it: `Prodbox.Lifecycle.HostCleanupCompletion` prepares the
local-completion entry, idempotently appends it to the preserved journal, and separately observes it
back into the read-back the runner validates, so both of the terminal node's arms now have a
production implementation. The bootstrap recovery-plane arms landed on 2026-08-18 (checkpoint
below), and the three Authority arm pairs landed with them: accepting the readiness into the
retained namespace, reading it back both before the uninstall and after re-establishment, and
reconciling the durable cleanup run all have a production implementation, so every arm of
`HostCleanupRunnerEffects` is now answered by a production surface. What is still open in that item
was the injected restore boundary the re-establishment calls, and it landed on 2026-08-19
(checkpoint above): `Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction` restores only from an
established aggregate the independent backup domain confirms, waits only on a control plane that is
not yet routable, and supplies the runner arm beside the accept, read-back, and reconcile arms. Every
arm of `HostCleanupRunnerEffects` now has a production implementation and none of them is injected.

The terminal escape audit's projection landed on 2026-08-18 (checkpoint above); issuing its queries
against a real provider is Sprint `7.36`'s adapter and this sprint makes no claim about it.

The Authority runner clients landed on 2026-08-18 (checkpoint above). The credential-disposition
observation landed on 2026-08-18 (checkpoint above); issuing its observations against a real
provider is Sprint `7.36`'s adapter and this sprint makes no claim about it.

The host runner became single-phase-drivable on 2026-08-18 (checkpoint above), which is what lets a
node interpreter attribute one node's effect to that node. Wiring the four cascade host nodes into
the descriptor-bound dispatcher waits on one thing named there: that dispatcher admits only closed
production runtimes and has no caller-supplied continuation, so a host route may not take an
injected effects record. With the Authority restore boundary landed on 2026-08-19 every arm has a
production implementation, so a closed cascade host runtime is now constructible and building it is
the next item.

The cascade host route's node-to-phase correspondence was the open decision here, and it was made
and landed on 2026-08-19 (checkpoint above): the durable phase set gained one phase per compiled
cascade host node, and `Prodbox.ControlPlane.CascadeHostRuntime` is the closed runtime the dispatcher
routes those four nodes to. What is still open is the *construction* of that runtime's production
effects record, which is the non-public candidate entrypoint below rather than a separate surface.

The decision this paragraph used to hold open was made and landed on 2026-08-20 (checkpoint above).
The Stage-C read-back had no independent reader for a report identity: the Backup Adapter addresses
objects only by `AuthorityBackupBlobClass` and digest, and no class named a cleanup report. It is a
**fourth blob class** rather than a second addressing scheme, because the adapter's least-privilege
grant already covers the prefix a new class lands under, and the report is already a digest.
`Prodbox.ControlPlane.CleanupReportBackupClient` reaches that class and
`Prodbox.Lifecycle.Teardown.PreUninstallReportBackup` is the production
`CascadeReportReadBackBoundary` over it.

Stage C was complete as a chain and composed into nothing, and the composition landed on 2026-08-20
(checkpoint above). `Prodbox.Lifecycle.Teardown.PreUninstallStageC` renders the report, commits it,
replicates it, reads it back from the independent domain, obtains the permit, and composes
`ReadyToUninstallEvidence`; the report identity is derived from the rendered bytes rather than
supplied, so no caller can name a report identity the run's own proofs do not produce. Nothing
constructs that composition outside its own regression, which is the candidate entrypoint below
rather than a separate surface.

What remains, in order:

The production `HostCleanupRunnerEffects` record landed on 2026-08-20 (checkpoint above). The
completion read-back's two prerequisites are derived by observing rather than remembered from the
commit arm, so a resumed run that never issues a commit still closes; and
`observeRetainedArtifactStore` is now available from either root, so the repair's *deciding*
observations are production. What is still open in that item is the production
`RecoveryRepairBoundary IO` — installing a substrate from retained bytes, starting its service,
awaiting its API, loading retained images, and reconciling the recovery charts — which is the last
injected arm and is host mutation belonging to the candidate entrypoint below.

- **The construction of the record's remaining sources.** The production `RecoveryRepairBoundary`
  landed on 2026-08-20 (checkpoint above) for four of its five acts, and the decision that had been
  open here is made: the retained-artifact kind universe was short the release tarball and the
  checksum file, and it now carries both. The one supplied arm is the recovery chart reconcile,
  which is chart delivery and belongs above the lifecycle surface.
  The Authority client's own missing half landed on 2026-08-20 with it (checkpoint above): the
  readiness namespace and both Stage-C slots were reachable only from inside the cluster, so
  `Prodbox.ControlPlane.CascadeRetainedSlotEndpoint` and
  `Prodbox.ControlPlane.CascadeRetainedSlotClient` are the closed route and host adapter that make
  `modelBHostCleanupReadinessRepository` and `modelBCascadeReportRepository` constructible on a
  cascading host. What remains is the composition root that builds the inventory, the source
  catalog, the recovery closure, the retained store, the journal, and the Authority and
  cleanup-run clients from one located repository root and one authenticated Authority session —
  and it landed on 2026-08-20 (checkpoint above) as
  `Prodbox.Lifecycle.HostCleanupCompositionRoot`, on top of the Tier-0 `retained_artifacts`
  declaration that gave the inventory and the source catalog the configuration surface they had
  never had. Every source of `HostCleanupProductionSources` now has a production constructor and
  the record is constructible on a host.
- The cloud runtime beside it landed on 2026-08-20 (checkpoint above).
  `Prodbox.Lifecycle.Teardown.CloudRuntimeProduction` assembles the four interpreters over one
  authenticated Authority transport, and the two durable records that had no host-reachable reader —
  the ownership manifest decision and the AWS stack creation binding — gained the scope-keyed
  derivations their own repository modules owe them. The EKS drain interpreter's two unreachable
  arms moved to `EksDrainSessionArms` rather than being filled with a refusal.
- The non-public candidate entrypoint landed on 2026-08-20 (checkpoint above).
  `Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal` resolves the transport-free plan, opens the
  two sessions through the host composition root, builds both closed runtimes over one transport,
  and drives the total dispatcher across the durable descriptor-bound run. The durable-cascade entry
  protocol moved to `Prodbox.Lifecycle.CleanupRunEntry`, because it was named as harness-owned while
  being lifecycle-owned and the harness-namespace gate refused the first production caller.
The complete cascade Plan/Apply/fault matrix landed on 2026-08-20. Item 3 closed with the
surface-indexed local uninstall evidence, item 1 with the composed frozen run, and item 7's
installed-CLI half was re-scoped to Sprint `6.5` under Standard N because this sprint activates no
public writer to trace. The coverage map above records where each of the seven items is measured.

None. Activating the candidate entrypoint as the sole public writer, deleting the legacy route, and
the Standard-P deployment qualification over the composed running system are Sprint `6.5`'s
qualified cutover; this sprint makes no claim about them.

This sprint does not activate a public writer or delete the legacy route; Sprint `6.5` owns those
cutover actions.


## Sprint 4.87: The Backup Adapter Could Not Name a Config Blob [✅ Done]

**Status**: Done (2026-08-19)
**Implementation**: `src/Prodbox/ControlPlane/DedicatedAdapterStore.hs`,
`src/Prodbox/ControlPlane/AuthorityBackupAdapter.hs`,
`src/Prodbox/ControlPlane/AuthorityBackupEndpoint.hs`
**Deployment qualification**: pending — the config-backup replication path changes from always
refusing to writing and observing a `blobs/config/…` object.
**Live-proof**: not applicable; the defect and its guard are pure.
**Independent Validation**: every `AuthorityBackupBlobClass` is enumerated against the adapter's
object-name mapping in the unit suite. No substrate, credential, or later phase is involved.
**Docs to update**: `DEVELOPMENT_PLAN/README.md`.

### Objective

Make the Authority Backup Adapter able to name an object for every backup blob class it accepts, and
make a class it cannot name a compile-time or measured failure rather than a run-time refusal.

### Current Blockers

None.

### Architecture

The typed `AuthorityBackupBlobClass` has three members and the adapter maps each to a path segment,
but the store function that builds the object name takes that segment as `Text` and admits it against
its own allowlist. The allowlist held `authority-aggregate` and `checkpoint` and not `config`, so
`AuthorityConfigBlob` — the class `Prodbox.ControlPlane.ConfigBackupClient` uses, wired into the
production `Prodbox.ControlPlane.Runtime` — refused **every** copy and **every** observation with
`invalid Authority backup blob class`. The config-backup replication path could not have worked.

The defect is a stringly-typed seam, so the remedy is a measurement across it rather than one more
literal: the class gains `Bounded`/`Enum`, the adapter exports the one typed
class-to-object-name function, and the suite enumerates every class through it and requires three
distinct names. A class added later without a segment fails that measurement instead of failing in
production.

### Deliverables

- `authorityBackupBlobObjectName` admits the `config` segment.
- `AuthorityBackupBlobClass` derives `Bounded` and `Enum`.
- `authorityBackupBlobObjectNameForClass` is the one exported typed mapping; the adapter's internal
  `backupObjectName` is defined as it rather than as a second copy.

### Validation

1. Every member of `AuthorityBackupBlobClass` produces an adapter object name, and the three names
   are distinct.
2. The existing copy/observe/read-back behaviour for the aggregate and checkpoint classes is
   unchanged.

### Validation Result (2026-08-19)

- One case in `test/unit/ControlPlaneAuthorityBackupEndpoint.hs` enumerates
  `[minBound .. maxBound]` through `authorityBackupBlobObjectNameForClass` and requires three
  distinct names.
- The guard was measured against the defect: with the `config` segment removed the case fails
  (`test/unit/ControlPlaneAuthorityBackupEndpoint.hs:196`, "Expected predicate to return True") and
  with it restored the case passes, so the measurement is of the defect and not of the fix's shape.
- The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
  `prodbox dev check` passes, and the unit suite is 4287/4287.


## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_reconciliation_doctrine.md` — exact-keyed observation,
  checkpoint recovery, the closed desired-absence program, durable graph, and proof-carrying
  recover-to-clean terminal contract.
- `documents/engineering/lifecycle_control_plane_architecture.md` — recovery-profile consumption,
  cleanup-run ownership, and uninstall-last authority lifetime.
- `documents/engineering/chaos_hardening_doctrine.md` — the measured authority/key/lifecycle/
  cardinality counterexample and its MISU rule.
- `documents/engineering/cli_command_surface.md`,
  `documents/engineering/storage_lifecycle_doctrine.md`, and
  `documents/engineering/streaming_doctrine.md` — public semantics and narration by reference to the lifecycle SSoT,
  without copying its phase sequence.
- `documents/engineering/lifecycle_control_plane_architecture.md` — § 2 gains the capability-release
  invariant, and a new § 3.4 owns the term *custodial capability*, its disambiguation from the
  operation-indexed reference, the disposition's constructor set including the absent destroy
  constructor, the derived-and-underivable dependant set, and why the rule survives arbitrary lifts.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` — § 3.1 gains a sixth
  registry-boundary invariant stating what a run must have proven before completion; § 5 and § 5a
  gain the rule that the no-install arm is selected by delete mode rather than by install presence,
  and that a cascade which reached no phase exits non-zero; § 5b node 5 carries the per-node
  disposition; § 5d's stale naming of the postflight predicate as the live mechanism is corrected;
  § 6a gains the IAM destroy-granularity consequence; § 9 gains the zero-key-family rule.
- `documents/engineering/storage_lifecycle_doctrine.md` — § 5 states the zero-exit asymmetry
  alongside the nonzero one, and § 7 rule 10 gains its missing precondition: retiring the retained
  root is licensed by a positive disposition of the capabilities it holds, never by an exit code.
- `documents/engineering/pure_fp_standards.md` — the generic form only: a fifth forbidden program
  shape, the absent-constructor design statement in § 7, and one review-checklist item.
- `documents/engineering/cli_command_surface.md` — the `cluster delete` public semantics as a
  current/target split, the cascade mode's exit status, and the retained-state narration as a total
  function over terminal arms.
- `documents/engineering/streaming_doctrine.md` — § 6a's twin rule: an unnarrated exit is not a
  narrated absence.
- `documents/engineering/chaos_hardening_doctrine.md` — § 22's fifth honest consequence: a region can
  be an argument type, not only a module set.
- `documents/engineering/aws_integration_environment_doctrine.md` — the dated correction to the
  Sprint-`4.19` record, which claimed this defect class closed.
- `documents/engineering/README.md` — index Purpose cells and one Quick Navigation deep link.

**Product docs to create/update:**

- Root `README.md` — the corrected `--cascade` no-install behaviour and what a zero and a non-zero
  cascade exit each do and do not say about AWS and about the retained root.
- `AGENTS.md` — the same correction on the operator-authorization surface.

**Cross-references to add:**

- [system-components.md](system-components.md) — the custodial-capability disposition, the capability
  dependant derivation, the destructive delete entry contract, and the custody row in Authority and
  State Locations.
- [substrates.md](substrates.md) — the readiness composition's custody requirement, the current
  deterministically named EKS roles and their destroy granularity, and the SES current-source
  divergence note, without restating the disposition algebra.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) — the eight new rows, each owned
  by the sprint that owns its file.

**Product docs to create/update:**

- Root `README.md` — local-only versus cascade semantics and incomplete-run recovery behavior.

**Cross-references to add:**

- [system-components.md](system-components.md) — lifecycle kernel and recovery-profile consumers.
- [substrates.md](substrates.md) — exact adapter/qualification ownership without restating the
  lifecycle algorithm.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) — every superseded funnel,
  callback, executor, and false completion has one removal owner.

## Sprint 4.88: The No-Install Cascade Exit Licenses a Deletion It Never Observed [✅ Done]

**Status**: Done (2026-08-20; opened 2026-08-19). The arm is selected by the delete mode over the
(mode, presence) product, the cascade's no-install path exits non-zero naming the disposition it
reports, and the retained-state narration is a total function over the command's terminal arms.
**Blocked by**: none. The corrected arm is reached with no cluster present and no AWS credential, so
nothing earlier in the queue is required to build or measure it.
**Deployment qualification**: pending — this changes a destructive-cleanup entry contract and its
exit status, which invalidates prior qualification under Standard P.
**Doctrine**: [Lifecycle Reconciliation Doctrine § 5, “Mandatory Entry Contracts for Destructive
Commands”](../documents/engineering/lifecycle_reconciliation_doctrine.md#5-mandatory-entry-contracts-for-destructive-commands),
[Lifecycle Reconciliation Doctrine § 5a, “Local-only no-install
short-circuit”](../documents/engineering/lifecycle_reconciliation_doctrine.md#5a-local-only-no-install-short-circuit),
and [CLI Command Surface, “Reconcilers: Idempotent Mutation as a Single
Command”](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`applyNativeDelete`'s install-presence arm and
`renderRetainedStateNotice`), `src/Prodbox/CLI/Spec.hs` (the `cluster delete` leaf description and
its generated artifacts), and `test/integration/CliSuite.hs` (the Sprint-`4.25` no-install cascade
case, which currently pins the defect).
**Live-proof**: pending and non-blocking. The refusal arm and the narration are measured through the
installed binary with no cluster present; what remains live is a home host holding a preserved
`.data/` and no RKE2 install, showing the cascade reach the durable cleanup namespace instead of
returning.
**Independent Validation**: a pure decision table over the delete-mode × install-presence product
plus installed-binary traces against the existing fake RKE2 environment. No AWS, no reachable
cluster, no later-phase implementation.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/cli_command_surface.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`, root `README.md`, `AGENTS.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make `prodbox cluster delete --cascade --yes` structurally unable to report the success that
licenses deleting the capability store, when it observed nothing. Local RKE2 absence is not per-run
AWS absence; a cascade that returned before its first phase must say so in its exit status and its
narration, not in prose the operator reads afterwards.

### Architecture

The short-circuit is selected before the delete mode is consulted. `applyNativeDelete` reads the
install-presence probe and, when nothing is installed, writes the no-cluster line and returns
`ExitSuccess` for **both** modes — before the per-run residue gate and before any cascade phase.
Doctrine § 5a says this arm belongs only to `--yes`: cascade must instead inspect the durable
cleanup namespace and retained establishment metadata, and where neither a valid completion receipt
nor a recoverable trust root exists, return `RecoveryPlaneNotEstablished` while making no AWS-absence
claim.

The consequence is not a narration defect. The retained-state notice — the only place the supported
surface mentions the retained root — is rendered from both terminal arms, `runNativeLocalUninstall`
and the cascade, each with its own mode-specific per-run sentence. The arm that renders nothing is
the install-presence short-circuit, which returns before either. So the two exits that describe the
retained root are the two that reached a delete path, while the exit that reached none says nothing
about it and still returns zero. An operator reading exit `0` from a cascade has been told the
cascade ran.

The remedy is to make the arm a function of the mode rather than of install presence alone, and to
make the retained-state narration a total function of what the run proved: a path carrying a
completion receipt or an explicit local-only uninstall may say the store is preserved; every other
terminal path emits the counterpart line naming what it did not observe.

### Deliverables

- The no-install arm is selected by the delete mode and not by install presence alone. Only the
  local-only mode has a no-install success arm; the cascade mode has none, so a cascade cannot reach
  it and cannot be given one by a later caller.
- The cascade's no-install path returns a non-zero status carrying the disposition it reached, and
  the exit-code contract change lands in the same commit as the test that pinned the old one.
- The retained-state notice becomes a total function over the command's terminal arms. Its
  root-is-preserved sentence is reachable only from an arm that carries a completion receipt or is
  an explicit local-only uninstall; every other arm renders the counterpart line naming the
  unobserved obligations, so no exit path silently reads as permission to delete the store.
- The `cluster delete` leaf's public help stops describing graceful skipping in terms that read as
  licensing the whole cascade, and every generated CLI artifact is regenerated through the
  generated-section registry in the same change.
- The local-only `--yes` behaviour is unchanged, and the unchanged half is measured so the scope of
  the change is provable rather than asserted.

This sprint makes no claim about what the cascade proves once it proceeds; the proof chain is Sprint
`4.86`'s, and the disposition governing the store itself is Sprint `4.89`'s.

### Validation

1. A pure table over the delete-mode × install-presence product shows exactly one no-install
   success arm and shows it is selected by the local-only mode, so the cascade mode is unable to
   reach it.
2. An installed-binary trace with no RKE2 install marker and `--cascade --yes` exits non-zero,
   names the durable cleanup namespace it could not reach and the recovery-plane disposition it
   reports, does not emit the no-cluster success line, and makes no AWS-absence statement.
3. An installed-binary trace with no RKE2 install marker and `--yes` is unchanged: exit zero, the
   no-cluster line, and neither the residue-gate refusal nor a teardown narration.
4. Every terminal arm of the command is enumerated, and the root-is-preserved sentence is emitted by
   exactly the arms that carry a completion receipt or an explicit local-only uninstall; each other
   arm emits its counterpart line. A new arm with no narration fails the enumeration.
5. `prodbox dev docs check` and `prodbox dev lint docs` exit 0 over the regenerated CLI artifacts,
   so the public help and the arm cannot disagree.
6. `prodbox dev check`, `prodbox test unit`, and `prodbox test integration cli` pass, with the
   rewritten Sprint-`4.25` case measuring the refusal rather than the former success.

### Validation Result (2026-08-20)

- 4 focused cases in `test/unit/ClusterDeleteEntryArm.hs` over the two pure tables: the
  delete-mode × install-presence product has exactly four members and exactly one no-install success
  arm, selected by the local-only mode; every pair maps to a distinct terminal arm, so the four
  constructors are exhausted and the cascade mode's no-install arm is a different constructor
  entirely; the retained-root licence is emitted by exactly `DeleteArmLocalOnlyUninstalled`, with
  the phase-running cascade arm rendering `RetainedStateUnproven` and both no-delete-path arms
  rendering `RetainedStateSilent`; and the local-only per-run sentence keeps its advice while the
  cascade's names the licence it does not carry.
- The narration is total by construction rather than by assertion: a new terminal arm with no
  narration fails to compile, which is what validation item 4 asks for.
- `test/unit/Main.hs`'s three Sprint-`4.76` notice cases move from the delete mode to the terminal
  arm and are otherwise unchanged, so the mode-aware behaviour they pinned is preserved under the
  new key.
- The Sprint-`4.25` integration case that pinned the defect is rewritten as
  `Sprint 4.88: rke2 delete --cascade with no RKE2 install refuses instead of reporting success`: the
  installed binary exits `1`, names the durable cleanup run namespace and
  `RecoveryPlaneNotEstablished`, states that it makes no claim about per-run AWS stacks, does not
  emit the local-only no-cluster line, and never starts the cascade orchestration.
- The local-only half is measured unchanged: the sibling Sprint-`4.25` case still asserts exit `0`,
  the no-cluster line, and neither the residue-gate refusal nor a teardown narration, so the scope
  of the change is provable rather than asserted.
- `prodbox dev docs check` and `prodbox dev lint docs` exit 0 over the regenerated CLI artifacts:
  the `cluster delete` leaf help and both golden CLI renderings carry the new contract, so the
  public help and the arm cannot disagree.
- `prodbox dev check` passes; `prodbox test unit` is 4391/4391 with the known-environmental SSH case
  excluded; `prodbox test integration cli` is 61/61.

### Remaining Work

None. This sprint does not activate the replacement cascade and does not delete the legacy route;
Sprint `6.5` owns both, and this sprint makes no claim about them. What this sprint removed is the
licence, not the possibility.

## Sprint 4.89: Custodial-Capability Disposition and the Absent Destroy Constructor [✅ Done]

**Status**: Done (opened 2026-08-19; implementation 2026-08-20 to 2026-08-21). The three-module
unit, the derived dependant set, the disposition-carrying destructive boundary, the `dev check`
derivation rule, and every consumption site are landed and measured.
**Closure dependency**: Sprint `4.86`, which closed 2026-08-20. This sprint generalises a helper
inside the cascade-evidence boundary that sprint was completing, so it could only close after that
boundary stopped changing. Same-phase and earlier, permitted by Standard N.
**Deployment qualification**: pending — checkpoint retirement, checkpoint pruning, and Authority
retirement authorization are destructive-cleanup and lifecycle-orchestration surfaces under
Standard P, so prior qualification is invalidated even though this sprint activates no public writer.
**Doctrine**: [Lifecycle Control-Plane Architecture § 3.4, “Custodial capability and the disposition
rule”](../documents/engineering/lifecycle_control_plane_architecture.md#34-custodial-capability-and-the-disposition-rule),
[Lifecycle Reconciliation Doctrine § 3.1, “The managed-resource registry and exact observation
boundary”](../documents/engineering/lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary),
[Lifecycle Reconciliation Doctrine § 5b, “Canonical recover-to-clean
cascade”](../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade),
[Pure FP Standards § 7, “GADT-Indexed State
Machines”](../documents/engineering/pure_fp_standards.md#7-gadt-indexed-state-machines), and
[Pure FP Standards § 6, “External-System
Boundaries”](../documents/engineering/pure_fp_standards.md#6-external-system-boundaries).
**Implementation**: `Prodbox.Lifecycle.Teardown.CapabilityCustody` (zero-definition facade),
`Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe` (exposed), and
`Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal` (Cabal-hidden), placed exactly as
`Prodbox.Lifecycle.Teardown.CascadeEvidence` and its `.Internal` are placed today. Consumed by
`src/Prodbox/Lifecycle/LiveResidue.hs`,
`src/Prodbox/Lifecycle/Teardown/AwsCheckpointInterpreter.hs`,
`src/Prodbox/Pulumi/EncryptedBackend.hs`, and
`src/Prodbox/Lifecycle/Authority/PulumiCheckpointRegistry.hs`; derived from
`src/Prodbox/Lifecycle/Teardown/OwnershipManifest.hs`,
`src/Prodbox/Lifecycle/Teardown/Registry.hs`, and
`src/Prodbox/Lifecycle/CredentialProvisioner/OperatorMaterial.hs`; gated by
`src/Prodbox/CheckCode.hs`.
**Live-proof**: pending and non-blocking. The Authority checkpoint registry derives `Serialise`, so a
real retained aggregate written by the pre-change revision must decode after the change; the frozen
compatibility fixture measures the same shape code-locally and is what closure depends on.
**Independent Validation**: total decision tables over the closed disposition universe, a derivation
exercised against the compiled registries, a `prodbox dev check` gate measured against its own
defect, fake checkpoint and Authority boundaries, and a natural-transformation invariance exercise.
No provider observation, no live substrate, and no later-phase implementation is involved.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/chaos_hardening_doctrine.md`, `documents/engineering/README.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/substrates.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Make it unrepresentable for a run to stop holding a custodial capability without stating where it
went. A loss of custody must be paired with a value proving the capability already authorises
nothing, proving the resources it reaches are absent, or destroying those resources in the same
operation. The absence of a destroy constructor is the invariant; it is not an omission to be
filled in later.

### Terminology

**Custodial capability** is the doctrine term for material whose possession is what makes a resource
destroyable — a Pulumi checkpoint, an access-key family, a sealed credential generation, a retained
store's contents. It is deliberately distinct from the operation-indexed reference to a live service
boundary that
[Lifecycle Control-Plane Architecture § 2](../documents/engineering/lifecycle_control_plane_architecture.md#2-non-negotiable-invariants)
and § 3.1 define. A reference is how a run *reaches* a boundary; a custodial capability is what a run
*holds*. The one-sentence disambiguation lives once, in § 3.4 of that document, and every governed
document that uses both terms in one passage cites it rather than repeating it.

### Architecture

Two AWS resources were stranded by one event, and the two halves of the event are the two halves of
this design. The EKS node role had its creation-side defects closed — an explicit deterministic name
and an ownership tag now gated by the terminal-audit field-of-view check — while its recovery side
has nothing: the teardown registry declares three stack descriptors and two volume families and no
IAM family, and no provider intent lists or deletes an IAM role, so the only destroy granularity
that reaches it is the whole-stack destroy, which needs the checkpoint. The retained SES SMTP
principal exists with zero access keys because the decommission path deletes keys, then policy, then
user inside a short-circuiting `ExceptT`, so a mid-sequence failure leaves a principal nothing can
authenticate as. Both resources depended on capabilities inside the store, and the store was
destroyed while they existed.

The disposition is the value that must be produced before custody ends. Four constructors sit at the
retire index — the capability is already inert, the capability is discharged by proven absence of
everything it reaches, the capability is rotated onto a named successor, or the capability and the
identity it belongs to are destroyed jointly — and each carries a mandatory strict discharge, so
none can be built from a capability alone. One constructor sits at the hold index. **There is no
destroy constructor**, and that absence is the whole mechanism: the destructive boundary takes the
disposition multiset, so a caller with a capability and no discharge has nothing to pass.

The dependant set is derived rather than authored, from the registered ownership edges, the managed
resource registry, and the managed AWS credential inventory — the same three compiled sources the
ownership manifest and the cascade credential disposition already read, so a new registered resource
is covered without editing this module. Where the registry declares no family for a capability's
dependants, the derivation reports the set **underivable** rather than empty: a capability whose
dependant set defaulted to nothing would discharge trivially, which is the exact failure that
stranded the node role.

The invariant survives arbitrary lifts, and that is a property of the shape rather than a
convention. The destructive boundary's argument type mentions no `m`, and the disposition multiset
is a pure projection computed before dispatch, so any natural transformation — a test double, a
chaos lift, a retry wrapper — observes identical arguments and has no arm through which to
synthesise a disposition it was not handed.

### Deliverables

- The three-module `CapabilityCustody` unit: the indexed disposition and its closed class universe
  in the exposed `Universe` module, every eliminator and the destructive boundary's argument type in
  the Cabal-hidden `Internal` module, and a zero-definition facade, in the placement the
  cascade-evidence boundary already uses.
- The dependant derivation, computed from the three compiled sources, with an explicit underivable
  answer and no default. A `prodbox dev check` rule fails the build when a registered capability's
  dependant set is neither derived nor declared underivable, and when one of the three derivation
  sources stops contributing.
- The disposition-carrying destructive boundary, whose argument type mentions no `m`, together with
  the pure pre-dispatch projection that computes the multiset.
- The cascade proof binding generalised off its cascade-only index so the binding is indexed by
  cleanup surface. The cascade instantiation produces the same binding the landed regression
  measures.
- The residue classifier stops converting checkpoint absence into a discharge. A checkpoint that is
  absent or empty produces a lost-capability answer carrying what was lost, distinct from a corrupt
  checkpoint's unobservability and from a provider-observed resource absence. A run holding a lost
  capability cannot compose readiness.
- Checkpoint retirement and checkpoint pruning consume a disposition. The registered-target absence
  read-back the retirement path already performs becomes an input to the decision instead of being
  discarded from it.
- The Authority-side retirement authorization takes an absence observation. Because that registry
  derives `Serialise`, the change ships with a frozen compatibility fixture proving pre-change
  aggregate bytes decode and that a decode which loses the observation refuses rather than
  defaulting.
- The retained stores and the operational credential generations gain their custody wiring, so
  ending custody of either is a disposition rather than a deletion.

**This sprint does not perform the IAM joint destruction.** The audited defect — the short-circuiting
key/policy/principal sequence and the pinned policy name that diverges from the registered
descriptor's — needs a production IAM-principal observation and an IAM-role family registered
alongside its executor. On the AWS substrate that observation is a Provider effect Sprint `7.36`
owns, by the same rule that keeps the cascade credential-disposition observation unwired; reaching
for a host-direct IAM call here would add an unregistered escape path. This sprint supplies the
joint-destruction constructor that sprint's execution half consumes, and makes no claim about the
execution half.

**This sprint does not register the IAM-role family.** Registering a descriptor compiles a mandatory
absence read-back, and no production executor can discharge one for an IAM role, so registering it
here would make the compiled programs unsatisfiable rather than making the role destroyable. It is
the third instance of the pairing rule Sprint `7.36` already carries for the retained EBS family and
the DNS01 challenge family, and it lands there with its adapter.

**This sprint does not wire the write-ahead ownership manifest's first production caller.** That
caller is the surface that receipt-commits coordinates before the first provider mutation, which
Sprint `7.36` owns and declares; this sprint supplies the disposition type it commits.

**This sprint does not delete either dead guard.** The postflight operational-credential predicate
lives in the harness composition Sprint `5.36` is migrating, and the long-lived residue-protection
predicate lives on the AWS residue-policy surface whose open row is Sprint `7.36`. Each is a
Standard-I surviving helper beside a landed replacement and is carried as a deletion-ledger row
owned by the sprint that owns its file.

**This sprint does not re-implement the signed retained-local-data disposition.** Sprint `4.85`
landed it for the total-decommission surface, and it stays the precedent this design generalises
rather than a second implementation.

### Validation

1. The disposition universe is closed and counted: exactly five constructors, four at the retire
   index and one at the hold index, with the count asserted so a sixth fails the build. A table over
   the closed universe shows no constructor whose meaning is destruction without a discharge.
2. Every retire constructor's discharge is strict and mandatory: no value is constructible from a
   capability alone, and the elimination table is total over the universe with no fall-through arm.
3. The dependant set is derived, not authored. Over the compiled registries, every registered
   capability's dependant set is computed; a capability the registry declares no family for reports
   underivable rather than empty, and no capability derives an empty set.
   **Corrected 2026-08-20 (Standard C).** This item named the EKS node role as the fixed inhabitant
   of the underivable arm. The measurement is that **every managed AWS credential class** inhabits
   it, because each one's permissions reach an IAM role, an S3 prefix, a Route 53 record set, or an
   SES identity and the registry — three stack descriptors, two volume families, and the local RKE2
   foundation — declares a family for none of them. The node role is inside that answer rather than
   beside it: `LifecycleProviderCredential`'s `AssumeRegisteredProviderRole` is refused by name with
   "the registry declares no IAM role family".
4. The `dev check` rule is measured against its own defect rather than its own shape: removing one
   derivation source makes the case fail and restoring it makes the case pass, in the idiom Sprint
   `4.87` used.
5. Lift invariance is exercised rather than argued. One fixed program runs under the identity
   boundary and under a chaos lift, the argument sequences the destructive boundary observes are
   identical, and the lift has no arm through which a disposition can be introduced.
6. Checkpoint absence is not a discharge. Over the four checkpoint observability arms, absent and
   empty produce the lost-capability answer, corrupt stays unobservable, and only a provider-observed
   resource absence or a complete ownership manifest discharges. A run holding a lost capability
   fails to compose readiness, measured as the composition refusing rather than as a warning.
7. Retirement authorization requires an absence observation and cannot be reached without one; a
   retirement authorized under a stale observation refuses. The frozen `Serialise` fixture decodes
   pre-change aggregate bytes, and a decode that loses the observation refuses rather than
   defaulting to a permissive one.
8. The generalised proof binding is byte-identical at the cascade instantiation to the binding the
   landed cascade-evidence regression already measures, so the generalisation is proven to change no
   existing proof.
9. The library and unit surface build warning-clean under `--enable-tests --ghc-options=-Werror`,
   and `prodbox dev check`, `prodbox dev lint docs`, `prodbox dev docs check`, and
   `prodbox test unit` pass.

### Current Implementation Checkpoint (2026-08-20, the disposition and its derivation)

- **The three-module unit exists in the placement the cascade-evidence boundary already uses.**
  `Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe` is exposed and holds the closed capability
  universe and the indexed disposition; `…​.Internal` is Cabal-hidden and holds the derived dependant
  set, the release multiset, the destructive boundary, and the fixed regression; and
  `Prodbox.Lifecycle.Teardown.CapabilityCustody` is the facade.
- **There is no destroy constructor, and that is the mechanism rather than an omission.** Four
  constructors sit at the retire index — already inert, discharged by proven absence, rotated onto a
  named successor, destroyed jointly with its identity — and each takes a strict discharge, so none
  is constructible from a capability alone. One sits at the hold index. A caller holding a capability
  and nothing else has nothing to pass to the boundary.
- **The dependant set is derived from the three compiled sources and never authored.** A checkpoint
  reaches its own stack plus every controller-owned family the registered ownership edges say that
  stack owns; a credential reaches whatever its declared permissions reach. A new registered resource
  is covered without editing the module.
- **An undeclared family is underivable, not empty**, and the measurement corrects this sprint's own
  illustration under Standard C. The plan said the EKS node role is the fixed inhabitant of that arm;
  what the compiled registries actually make underivable is **every managed AWS credential class**,
  because each one's permissions reach an IAM role, an S3 prefix, a Route 53 record set, or an SES
  identity and the registry declares a family for none of them. The node role is inside that answer
  rather than beside it — `LifecycleProviderCredential`'s `AssumeRegisteredProviderRole` is refused
  by name with "the registry declares no IAM role family" — and the shape the plan described is the
  shape that is measured: a capability whose dependant set defaulted to empty would discharge
  trivially, and none does.
- **The permission-to-family map is total over the closed permission universe**, so registering a
  family later turns one arm from a refusal into a key with no other change, and forgetting to is a
  non-exhaustive pattern rather than a silent empty set.
- **The gate is written against its sources, not against its answer.** The answer type has exactly
  two arms, so "derived or explicitly underivable" is structural; what can rot is a derivation source
  that stops contributing, which would make every capability quietly derivable-and-empty. The rule
  therefore takes the three sources as arguments, and the regression removes one at a time.
- **Lift invariance is a property of the shape.** `CustodyRelease` mentions no `m`, the multiset is
  computed purely before dispatch, and the boundary is a newtype over
  `CustodyRelease -> m ()`, so a natural transformation observes the identical argument.
- No production surface consumes a disposition yet: checkpoint retirement, checkpoint pruning, the
  Authority-side retirement authorization, the residue classifier, and the retained stores are the
  consumption sites this sprint still owns.

### Validation Result (2026-08-20, the disposition and its derivation)

- 6 focused cases in `test/unit/LifecycleTeardownCapabilityCustody.hs` read the fixed
  non-authorizing regression: the universe is closed at four retire arms and one hold arm with the
  counts asserted and every retire arm naming the capability it disposes; a checkpoint's dependant
  set is derived and strictly larger than its own stack; no capability derives an empty set while at
  least one reports underivable with its reason; the derivation gate fails when any one of the three
  sources is removed and passes when all three are restored; a release refuses an undisposed, a
  foreign, and a duplicated capability and each refusal renders naming the capability; and one fixed
  program hands the identity boundary and a chaos lift the identical release.
- The foreign-capability case deliberately pairs the held capability's own disposition with the
  foreign one, so the foreign disposition is the only thing wrong: a release that is both incomplete
  and foreign reports the incompleteness first, because a capability with no disposition is the
  failure custody exists to refuse.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes with the new derivation rule in
  its doctrine-alignment run; `prodbox test unit` is 4397/4397 with the known-environmental SSH case
  excluded.
- This result covers the disposition, the derivation, and the gate. Validation items 6-8 measure the
  consumption sites and remain open.

### Current Implementation Checkpoint (2026-08-20, checkpoint absence is not a discharge)

- **The residue answer and the custody answer are two questions over one observation, and they were
  one function consumed twice.** "Is there a stack to destroy" and "does this run still hold what
  makes that stack's resources destroyable" have different answers for an absent or empty checkpoint:
  the first is `ResidueAbsent` and correctly so, and the second is *lost*, because the resources may
  exist and nothing now names them. Reading the first as the second is what stranded two AWS
  resources. `CheckpointCustodyObservation` and `classifyCheckpointCustody` are the second answer;
  `residueStatusFromCheckpointObservability` is unchanged, because it was answering its own question
  correctly.
- **A corrupt checkpoint stays unobservable rather than lost.** A blob that cannot be parsed may
  still be the capability, so declaring it gone would be an invention in the opposite direction —
  the same asymmetry the residue classifier already applies.
- **`dischargeByObservedAbsence` is the only constructor of an absence discharge**, and it has four
  refusals, each naming a distinct way one could otherwise be invented: an underivable dependant set
  cannot be discharged at all because nothing enumerates what the capability reaches; a dependant
  with no observation cannot, because a missing answer is not an absent resource; an observation
  taken at any layer other than the provider cannot — which is precisely the checkpoint-layer absence
  this increment exists to stop accepting; and a dependant the provider still reports cannot.
- **The gate found the fixture, which is what that gate is for.** The residue-observation minter rule
  refused the custody module's regression for minting observations outside an observing boundary, and
  the remedy the rule itself names was taken rather than the owner list widened: the discharge's
  fixture moved to `Prodbox.Lifecycle.LiveResidue`, which already owns both vocabularies and is a
  permitted minter. A fixture minting an observation inside the custody boundary would have been a
  consumer asserting the layer — the exact move the Sprint-`4.81` layer field exists to prevent.
- The total map from the encrypted-backend observability to the custody observation lives in
  `LiveResidue` rather than in the custody vocabulary, because the backend type sits beside a
  subprocess and a Vault session and the custody module is a vocabulary.

### Validation Result (2026-08-20, checkpoint absence is not a discharge)

- 2 further cases in `test/unit/LifecycleTeardownCapabilityCustody.hs`: the four checkpoint arms
  answer held, lost, lost, and unobservable respectively; and the absence discharge is constructible
  only from provider-observed absence of every derived dependant, with the checkpoint-layer absence,
  the unobserved dependant, the still-present dependant, and the underivable dependant set each
  refused by its own arm.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4399/4399 with the known-environmental SSH case excluded.
- This result covers the classification and the discharge constructor. Composing a run that holds a
  lost capability into cascade readiness is the wiring this sprint still owns.

### Current Implementation Checkpoint (2026-08-20, the binding is indexed by surface)

- **The three identities a proof binds to were never cascade-specific; only the AWS-scope rule is.**
  `CleanupProofBinding (surface :: CleanupSurface)` is the generalised type, `CascadeProofBinding`
  and `LocalOnlyProofBinding` are its two instantiations, and `cleanupProofBinding` takes the same
  surface witness the compiler already consults.
- **The AWS-scope rule is read from the witness rather than written twice.** A surface that requires
  a scope refuses its absence; a surface that requires none refuses its presence, because a
  local-only run naming a stack has proven nothing about it by observing the host. The Sprint-`4.86`
  local-only binding — a structurally identical record validated by the opposite rule — is deleted
  rather than kept, because two implementations of one set of checks is how the two drift.
- **The generalisation also strengthened the local-only side.** The cascade-only function checked the
  durable run scope and the standalone local-only binding did not; unifying gives that check to both.
- The operation, registry revision, and durable run scope are facts about the compiler rather than
  about the target, which is why they are checked identically on every surface.

### Validation Result (2026-08-20, the binding is indexed by surface)

- One case in `test/unit/LifecycleTeardownCascadeEvidence.hs` measures validation item 8: the
  cascade instantiation of the surface-indexed binding equals what the cascade-only function
  produced, and its run id, graph digest, and scope are the compiled program's own — so the
  generalisation is proven to change no existing proof rather than asserted to. The same case
  measures that the local-only instantiation refuses a program carrying an AWS scope.
- Every other arm of `fixedCascadeEvidenceRegression` is unchanged and still passes, including the
  complete proof chain, so the generalisation is measured against the proofs it might have broken.
- The library, the executable, and every test suite build warning-clean under
  `--enable-tests --ghc-options=-Werror`; `prodbox dev check` passes; `prodbox test unit` is
  4400/4400 with the known-environmental SSH case excluded.

### Current Implementation Checkpoint (2026-08-21, readiness is a six-component composition)

- **A run that has lost a checkpoint could still compose readiness, and readiness is what admits
  the local RKE2 uninstall that destroys the retained store those checkpoints live in.** The three
  convergence evidences say the resources are gone; none of them says the run can still prove that
  about them. `CascadeCapabilityCustodyEvidence` is the sixth component, and it binds to the
  compiled run exactly as the other five do.
- **The capability set is derived from the compiled program's own registered stack targets**, not
  authored and not taken from the caller. A run therefore cannot reach readiness by answering only
  the capabilities it happened to look at, and cannot answer for a stack it never touched.
- **The refusal is the composition refusing, not a warning beside it.** A lost capability yields no
  evidence value, so `mkReadyToUninstallEvidence` cannot be called at all — the refusal is reached
  before a report identity is committed or a one-shot permit is requested.
- **A corrupt checkpoint refuses too, as unobservable rather than lost.** A capability nobody could
  answer for is not a held one, which is the same asymmetry the residue classifier already applies.

### Validation Result (2026-08-21, readiness is a six-component composition)

- One further case in `test/unit/LifecycleTeardownCascadeEvidence.hs` measures validation item 6
  over four arms: a lost capability refuses, an unobservable one refuses, an answer set smaller
  than the derived set refuses on the set, and another run's custody evidence is refused by the
  binding rather than accepted because its answers happened to be held.
- `establishPreUninstallReadiness` and `runCascadeStageC` take the evidence as an input beside the
  other three, so the Stage-C protocol is unchanged and its eleven fault arms still pass.

### Current Implementation Checkpoint (2026-08-21, retirement and pruning consume a disposition)

- **The retirement node waited only on its own stack's absence read-back.** Retiring the reference
  ends this run's custody of the capability that made the stack's resources destroyable, so a
  retirement gated on one read-back ends custody while a controller-owned family that stack owns may
  still be present and nothing afterwards names it. That is the shape that stranded two AWS
  resources, and it was in the compiled program rather than in any interpreter.
- **The dependency set is now the derived dependant set.** `checkpointRetirementDependencies` reads
  `capabilityDependants`, so a newly registered controller-owned family joins the ordering without
  editing the program builder, and the ordering cannot disagree with the derivation the discharge
  uses. A capability whose dependants nothing enumerates waits on every non-stack target instead —
  never fewer than the derived set, and cycle-free because a stack never waits on another stack.
- **The absence rule is one rule over two currencies.** `dischargeFromDependantAnswers` holds the
  four refusals; `dischargeByObservedAbsence` projects a residue observation into it and
  `dischargeBySucceededAbsenceReadBack` projects the run's completed absence read-backs. A
  `ReadBackRegisteredTargetAbsent` node succeeds only on an exact absence answered at the registered
  identity's own authority, so "this run read it back" *is* a provider observation — and it is the
  answer the retirement path already had and discarded.
- **The retirement authorization takes the disposition rather than producing one.** There is no
  destroy constructor, so a caller holding a checkpoint and nothing else has nothing to pass; what
  the authorization checks is that the discharge it was handed is about this checkpoint. The
  compatibility execution entrypoint supplies no successful predecessors, so it can no longer reach
  the effect at all — the "proof-gated effects consume only the durable path" rule, enforced.
- **The retirement read-back stays gated on the attempt alone**, because a read-back that can be
  blocked cannot close a lost response. Its discharge is the retirement it observes: having seen the
  Authority holding the reference in its retired set, it reconstructs the authorization against a
  rotation onto that retained reference.
- **Pruning is a rotation, not a deletion, and saying so is what makes it checkable.** Retiring a
  reference records it in the Authority's retained set and clears the live slot, and the retained
  reference still names the backup copy's version. A zero-length object is already inert; a corrupt
  blob may still be the only thing naming live resources and is therefore kept where it can be
  found. `RetiredCheckpointCapability` names that successor, is never enumerated as something a run
  holds, and reaches exactly what the live reference reached.

### Validation Result (2026-08-21, retirement and pruning consume a disposition)

- One case in `test/unit/LifecycleTeardownProgram.hs` measures every stack's retirement node against
  the ownership edges rather than against a second copy of the derivation, over every non-local
  surface, with a non-vacuity assertion so it cannot pass against the pre-sprint one-dependency
  list.
- Three further cases in `test/unit/LifecycleTeardownCapabilityCustody.hs`: the run projection
  discharges from the complete read-back set and refuses a partial one as unobserved; inertness is
  admitted only from a zero-length object; and a retirement rotates onto a retained successor that
  reaches what the live reference reached.
- One case in `test/unit/LifecycleTeardownCheckpoint.hs` refuses a retirement whose discharge names
  another capability, and one in `test/unit/LifecycleTeardownAwsCheckpointInterpreter.hs` measures
  that the compatibility entrypoint cannot reach the retirement effect.

### Current Implementation Checkpoint (2026-08-21, the Authority refuses an unstated retirement)

- **The Lifecycle Authority retired a registered checkpoint reference on the strength of an
  operation permit alone.** It cannot observe AWS and so cannot check the proof a disposition
  carries; what it can refuse — and now does — is a retirement for which no disposition was ever
  stated. That is the failure the two stranded resources are an instance of.
- **The disposition crosses the boundary as a flat record rather than as the indexed value.** The
  disposition is a GADT precisely so it cannot be built without a discharge, and a decoder is a way
  to build one; `CustodyDispositionRecord` is therefore evidence rather than authority, produced by
  a total projection that gains an arm or fails to compile when a fifth retire constructor appears.
- **The permit is registered against the disposition, and the retirement is authorized against the
  permit.** A retire permit with no disposition naming the checkpoint it retires is refused at
  registration; a retirement whose operation carries no recorded disposition is refused at
  authorization and again at apply. A disposition that outlives its operation is a separate
  invariant failure, because a claim nothing can consume is a different defect from a claim nobody
  made.
- **The `Serialise` change is a migration rather than a durability break, and the difference is one
  line of the codec.** The disposition map is encoded __only when non-empty__: each value still has
  exactly one byte string, so canonicality holds, and every retained aggregate that predates
  dispositions re-encodes byte-identically. Widening the encoding unconditionally would have made
  every retained Authority object fail the enclosing envelope's own canonicality check on its next
  read — which the v6 compatibility fixture caught before it could reach a deployed Authority.
- **The frozen fixture is a shadow type rather than a captured byte string.** A captured string
  asserts over bytes nobody can re-derive; the shadow record derives the same generic encoding, so
  a change to the first three fields breaks the fixture instead of leaving it silently stale.

### Validation Result (2026-08-21, the Authority refuses an unstated retirement)

- One case in `test/unit/LifecycleAuthorityPulumiCheckpointRegistry.hs` measures validation item 7's
  `Serialise` half over three properties: a pre-change aggregate decodes and re-encodes
  byte-identically; every retirement permit inside it refuses at both `authorizeCheckpointRetirement`
  and `applyCheckpointRetirement` rather than defaulting to a permissive answer; and an aggregate
  that does carry a disposition round-trips and authorizes.
- The pre-existing v6 Authority-admission canonical-byte fixture passes unchanged, which is what
  proves the encoding change is invisible to every retained object.
- `prodbox dev check`, `prodbox dev lint docs`, `prodbox dev docs check`, `prodbox test unit`
  (4409/4409), `prodbox test integration cli`, and `prodbox test integration env` all pass.

### Current Implementation Checkpoint (2026-08-21, ending custody of a credential generation)

- **Committing a revocation receipt is where a run stops holding a credential generation, and it now
  consumes a disposition.** The disposition is minted from the read-back rather than authored: a
  revocation that was independently read back proves the family's keys no longer authenticate, which
  is inertness.
- **A revocation is inertness and never destruction, and that distinction is the audited SES defect
  stated as a type.** The retained SMTP principal exists with zero access keys because a
  decommission deleted keys, then policy, then user inside a short-circuiting sequence; the keys'
  absence made the capability inert, and inert is not destroyed. Destroying the identity alongside
  the capability is `CapabilityDestroyedJointly`, a different constructor and the operation Sprint
  `7.36` executes. `dischargeByObservedRevocation` refuses every non-credential capability, so a
  checkpoint cannot be called revoked and a retired reference cannot be disposed twice.
- **The external ACME EAB family is deliberately untouched**: it is not an AWS credential class and
  so is not a capability in this universe, and its commit is unchanged rather than given a
  disposition it has no capability to carry.
- **The retained-store half needed no new surface, and saying which surface covers it is the
  deliverable.** The retained store whose contents make registered resources destroyable is the
  checkpoint store, and its contents are disposed by the retirement and prune wiring above. The
  retained local data and the Vault-held retained source custody are both reachable only through
  `runRetainedCustodyTombstone`, which requires a `VerifiedDecommissionManifest` naming the
  `RetainedCustody` node — Sprint `4.85`'s signed retained-local-data disposition, which this sprint
  states it does not re-implement. Adding a second disposition in front of a signed one would have
  been two answers to one question, which is the shape `mkCustodyRelease` already refuses.

### Validation Result (2026-08-21, ending custody of a credential generation)

- One case in `test/unit/LifecycleTeardownCapabilityCustody.hs` measures that a revocation read-back
  yields an inertness disposition naming the credential family and carrying the generation it
  revoked, and that a checkpoint and an already-retired reference are each refused by their own arm.
- `prodbox dev check` 0, `prodbox dev lint docs` 0, `prodbox dev docs check` 0, `prodbox test unit`
  4410/4410, `prodbox test integration cli` 0, `prodbox test integration env` 0.

### Closure

All nine validation items are measured and no sprint-owned code work survives.

The three-module unit, the derived dependant set with its explicit underivable answer, the
disposition-carrying destructive boundary, the pure pre-dispatch projection, and the `dev check`
derivation rule landed on 2026-08-20, together with the residue classifier's lost-capability answer,
the provider-only absence discharge, and the surface-indexed proof binding. On 2026-08-21 the
readiness composition gained its custody component, checkpoint retirement and pruning began
consuming a disposition, the Lifecycle Authority began refusing a retirement no disposition was
stated for, and ending custody of a credential generation became a disposition rather than a
deletion.

This sprint makes no claim about the IAM joint destruction, the IAM-role family registration, the
write-ahead ownership manifest's first production caller, or either dead guard; Sprints `5.36`,
`6.5`, and `7.36` own those, as the disclaimers above state. Deployment qualification remains
pending, which Standard O keeps non-blocking and Sprint `6.5` owns.

A durable custody ledger — a retained record of which disposition ended which custody — is
deliberately out of scope and is not scheduled here: it is worth building once a disposition has more
than one producer, and building it now would land a recorder with a single writer to record. If it
becomes necessary it opens as its own sprint rather than as an unstated extension of this one.

## Sprint 4.90: Lifecycle Uses the Context It Sealed [✅ Done]

**Status**: Done — 2026-08-23.
**Implementation**: `src/Prodbox/Vault/Host.hs`, `src/Prodbox/Host.hs`,
`src/Prodbox/CLI/{Rke2,Pulumi}.hs`, `src/Prodbox/Config/Tier0.hs`,
`src/Prodbox/ControlPlane/{LifecycleAuthorityAuthentication,InClusterAuthorityStore}.hs`,
`src/Prodbox/Infra/{LongLivedPulumiBackend,MinioBackend}.hs`,
`src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/Minio/ObjectStoreTypes.hs`,
`src/Prodbox/CheckCode.hs`, and focused unit/integration fixtures.
**Deployment qualification**: pending — bootstrap capability wiring, persistence routing, and
lifecycle orchestration change; prior aggregate evidence is invalid for this composition.
**Independent Validation**: pure context-to-capability projections and injected fake Vault/MinIO
clients exercise two contexts plus missing/mismatch refusals; unit/CLI tests and
`prodbox dev check` require no live cluster or later phase.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Make lifecycle commands consume the same cluster id, Vault address, MinIO endpoint, and state-bucket
identity that Tier-0 names and the retained context seals. Today `hostVaultAddress`, a test
environment override in the production module, `RootVaultLifecycle "prodbox-home"`, the in-cluster
authority-store endpoint, and several bucket constants can independently answer those questions.
Restoring or deleting under a different answer than the sealed context is a capability-binding
failure, not a harmless default.

### Deliverables

- Host and RKE2 lifecycle entrypoints receive Sprint `1.92`'s validated context and construct
  `RootVaultLifecycle`, Vault probes, basics-floor operations, authority-store clients, and MinIO
  backend configuration only from it.
- Delete `hostVaultAddress`, `resolveHostVaultAddress`,
  `PRODBOX_TEST_HOST_VAULT_ADDR`, the `prodbox-home` fallback arm, and the default in-cluster MinIO
  endpoint. Tests inject a typed context/client instead of changing production behavior through an
  environment variable.
- Collapse `minioBackendBucket`, `gatewayMinioBucket`, `defaultObjectStoreBucket`, and equivalent
  production declarations onto the one prodbox-owned state-bucket identity introduced by Sprint
  `1.92`; fixtures import or receive that value instead of restating it when identity matters.
- Bind the resolved endpoint/cluster identity into the capability reference or request identity
  used for observation and execution, so a probe against one context cannot authorize execution
  against another.

### Validation

1. Two distinct valid contexts drive distinct Vault/MinIO client coordinates and lifecycle request
   identities end to end through fakes.
2. A probe/execution context mismatch, missing endpoint, or missing cluster id refuses before any
   effect; no host-local address is substituted.
3. Production source contains one state-bucket declaration and no complete host Vault or MinIO
   endpoint literal outside the compiled chart/service identity surfaces that own them.
4. The old environment variable has no production read and a test attempting to set it cannot
   change the selected endpoint.
5. Lifecycle/host unit and CLI suites plus `prodbox dev check` pass.

### Remaining Work

None on the sprint's code-owned surface. Deployment qualification remains pending under Standard P;
this sprint does not claim a current live bootstrap/lifecycle composition proof.

### Closure Record (2026-08-23)

- Host/public-edge, RKE2 status, and Pulumi preflight project Vault only from
  `ValidatedDeploymentContext`. The old host and Pulumi endpoint environment variables and the
  compiled loopback fallback are gone.
- A retained `RootVaultLifecycle` is usable only after its cluster id and Vault address match the
  validated context. A missing Tier-0 basics floor, missing authored coordinate, or mismatch
  refuses before an effect; authentication, retained-backend, and residue gates below settings use
  the address already sealed in that floor.
- `defaultObjectStoreBucket` is the only `prodbox-state` declaration. The RKE2 gateway path,
  MinIO backend, sealed-Vault audit, charts, and role stores import or receive it; the in-cluster
  Authority store has no endpoint or bucket default.
- Two-context and mismatch tests cover distinct Vault/MinIO/lifecycle identities, non-rewriting
  floor refusal, and immunity to the retired host override. The mutation-proven
  `checkHostLifecycleContextOwnership` gate pins every consumer reach and rejects restored
  fallbacks or duplicate bucket declarations.
- Validation is green: focused Sprint `4.90` unit proof 5/5, the sealed-Pulumi CLI refusal 1/1,
  Haskell lint, the complete canonical unit command (4543 primary tests plus 27/33/29 specialized
  suites), both canonical CLI/environment integration commands (62/62 each), documentation lint,
  HLint with `No hints`, and the warning-clean `prodbox dev check`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` — sealed context and exact
  capability-coordinate binding.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` — observation and execution consume
  one context identity.
- `documents/engineering/vault_doctrine.md` — no host-address fallback and one generic state-bucket
  identity.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Record the Phase `4` own-surface reopen in [README.md](README.md) and
  [00-overview.md](00-overview.md); register every surviving lifecycle fallback/duplicate in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [system-components.md](system-components.md)
- [Pure Functional Programming Standards](../documents/engineering/pure_fp_standards.md)
- [Integration Fixture Doctrine](../documents/engineering/integration_fixture_doctrine.md)
