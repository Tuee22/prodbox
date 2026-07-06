# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
**Generated sections**: none

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

**2026-07-05 — Phases `2`, `4`, `5`, and `7` reclosed for the daemon-mediated
post-bootstrap control-plane boundary.** Operator decision: once the host binary has
bootstrapped the substrate, deployed MinIO/Vault, and exposed the loopback-restricted `prodbox`
daemon NodePort, follow-on host interactions must flow through the daemon service instead of ad-hoc
host MinIO/Vault transports. Sprint `2.29` is ✅ Done: the daemon has a pre-Vault config loader and
`POST /v1/bootstrap/vault/ensure` endpoint with bounded redacted request parsing, mandatory
loopback-proof input, in-cluster MinIO/Vault Service access, init/unseal/reconcile orchestration, no
standing unseal authority, and a host-side `Prodbox.Gateway.Client.ensureVaultBootstrap` call.
Validation: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit` (1178/1178),
and `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes` (12/12).
Sprint `4.42` is ✅ Done: `cluster reconcile` deploys the pre-Vault gateway daemon before root Vault
init/unseal/reconcile, `prodbox vault ...` lifecycle leaves prefer the daemon NodePort, daemon-side
Vault errors no longer fall back to direct host Vault/MinIO transports, and operator-secret writes
do not bypass a daemon failure once the operator JWT is mintable. Validation: warning-clean build,
`./.build/prodbox test unit` (1182/1182), `./.build/prodbox test integration cli` (43/43), and
`./.build/prodbox test integration env` (43/43), plus `./.build/prodbox dev check` (0). Sprint
`5.14` is ✅ Done on its code-owned surface: `daemon-bootstrap` is a named canonical validation with
parser/registry/planner/topology wiring, aggregate ordering after `resource-guardrails`, a pure
transport oracle requiring daemon bootstrap/lifecycle routes, redaction checks, and built-frontend
proof that legacy MinIO port-forward traces fail. Validation: unit 1188/1188, targeted
`daemon-bootstrap` 1/1, CLI integration 44/44, env integration 44/44, and `dev check` 0. Sprint
`7.30` is ✅ Done on its code-owned surface: the gateway daemon now exposes typed Pulumi object-store
get/put/delete routes, resolves Vault Transit/HMAC material via Kubernetes auth, reaches MinIO
in-cluster, and the supported per-run AWS stacks hydrate/store/prune/query encrypted checkpoints
through `Prodbox.Gateway.Client` rather than opening a host MinIO port-forward. Validation: unit
1195/1195, built-frontend CLI integration 44/44, and env integration 44/44; live AWS/EKS parity
remains a non-blocking Standard O proof axis in [substrates.md](substrates.md). The surviving direct
host helpers are tracked in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) as
explicit legacy/config/test seams, not supported post-bootstrap Pulumi/residue paths.

**2026-07-04 — Phases `1`, `3`, `4`, and `5` reclosed for explicit resource
guardrails.** A host OOM during prodbox tests exposed a remaining supported-path gap: the
capacity/scaling model had aggregate budgets, but RKE2/kubelet reservations, namespace quotas, and
chart container request/limit envelopes were not mandatory everywhere. Sprint `1.55` is now ✅ Done:
`capacity.resource_plan` is part of the Dhall/Haskell config surface, config display/schema
generation include it, and invalid host reservation / namespace quota / workload envelope states
fail before command execution (`dhall type`, unit 1162/1162, env integration 40/40). Sprint `3.22`
is now ✅ Done: `Prodbox.Lib.ChartPlatform` injects resource profiles into every chart release,
root charts render namespace `ResourceQuota`/`LimitRange`, `prodbox dev lint chart` refuses
container templates without values-backed `resources`, and chart-plan unit tests prove
missing-profile refusal (`prodbox dev lint chart`, unit 1164/1164, CLI integration 40/40). Sprint
`4.41` is now ✅ Done: `prodbox cluster reconcile` writes the RKE2 kubelet reservation/eviction/log
and image-GC config fragment, writes the bounded `rke2-server.service` systemd drop-in, and refuses
observed hosts below the authored capacity declaration (warning-clean build, unit 1167/1167, CLI
integration 40/40). Sprint `5.13` is now ✅ Done on its code-owned surface: `resource-guardrails`
is a named canonical validation with parser/planner/topology wiring, a pure pod/quota/limit-range
JSON oracle, fake-`kubectl` integration coverage, and invalid-config refusal before mutation
(unit 1172/1172, targeted fake integration 1/1, CLI integration 41/41, env integration 41/41). The
optional real over-limit pod stress proof and AWS parity run are non-blocking live-infra axes per
Standard O, tracked in [substrates.md](substrates.md).

**2026-07-03 — Phase 3 Sprint `3.21` and Phase 4 Sprint `4.35` closed end-to-end:
Pulsar broker transport and topic lifecycle.** `Prodbox.Pulsar.Protocol` now owns the repo-maintained
Pulsar protobuf/framing subset, metadata and payload-frame CRC32C validation, message-id
rendering/parsing, broker service URL parsing, and typed server-error classification.
`Prodbox.Pulsar.Client` replaces the former explicit unsupported guard with TCP connect,
reconnect/backoff, request correlation, lookup, producer/consumer/ack flows, endpoint validation,
and typed broker errors over canonical CBOR payload bytes. `Prodbox.Pulsar.TopicResidue` now owns
`ManagedTopic`, three-valued topic discovery, typed `ensureTopic` / `deleteTopic`, and the total
projection onto `ResidueStatus`; `ResourceClass` registers `pulsar-topics-per-run` and
`pulsar-topics-long-lived`, and `ResourceRegistry.pulsarTopicManagedResource` adapts concrete
algebra-derived topics into the shared managed-resource destroy surface. Validation: warning-clean
build, unit 1157/1157, CLI integration 39/39, env integration 39/39, chart lint, and docs generate
for the registry table. The live home-local proof is now `./.build/prodbox test integration
pulsar-broker`: it deploys the internal Pulsar chart, creates
`persistent://public/default/reconcile.command.validation-<nonce>`, produces and consumes a CBOR
payload through the native broker protocol, acknowledges the consumed message id, deletes the topic,
and verifies broker-backed topic absence.

**2026-07-03 — Phase 7 Sprint `7.27` closed on code-owned surface: spot-price economics gate.**
`Prodbox.Scaling.Spot` now owns the three-valued spot-price model
(`SpotObserved` / `SpotUnobservable`), `SpotPriceThreshold`, the fail-closed
`admitSpotDeploy` decision, and the substrate guard that makes home-local a structural no-op while
requiring an AWS elastic policy before a spot gate can apply. `Prodbox.Aws` now has a live
credential-region `ec2 describe-spot-price-history` observer surface and pure payload/output
translation helpers; AWS CLI failure, invalid JSON, empty history, and invalid price text all become
`SpotUnobservable`, which the gate refuses rather than admitting. Validation: warning-clean build,
unit 1153/1153, Haskell lint, CLI integration 39/39, env integration 39/39, docs generate/check,
`git diff --check`, and canonical `dev check`. Live EC2 spot-price observation on an actual AWS
substrate remains a non-blocking live-proof axis.

**2026-07-03 — Phase 7 Sprint `7.29` closed on code-owned surface: EKS VPC ownership hardening.**
`pulumi/aws-eks/Main.yaml` now tags the dedicated EKS VPC, internet gateway, public route table, and
public subnets with `prodbox.io/managed-by=prodbox`, preserving the Kubernetes subnet tags. The
postflight tag sweep classifies VPC/IGW/route-table/subnet rows carrying that tag as per-run
escapees unless a real long-lived retention marker is present, and the always-fresh test VPC
guarantee remains the existing destroy-before-ensure residue purge. Validation: warning-clean build,
unit 1145/1145, Haskell lint, docs generate/check, CLI integration 39/39, env integration 39/39,
`git diff --check`, and canonical `dev check`.

**2026-07-03 — Phase 7 Sprint `7.28` closed: static retained EBS PVs on EKS.**
AWS chart/bootstrap storage now uses the same static `manual`/`Retain` discipline as home:
`Prodbox.Lib.Storage` renders CSI EBS PVs with `volumeHandle` and AZ affinity,
`Prodbox.Lifecycle.EbsVolume` idempotently discovers/creates retained, PV-tagged `gp3` volumes, and
`Prodbox.Lib.ChartPlatform` / `Prodbox.Lib.AwsSubstratePlatform` materialize static PVs (plus PVCs
where the chart owns the claim) before workloads bind. The EKS node group is pinned to the retained
EBS AZ exported by `pulumi/aws-eks/Main.yaml`; AWS MinIO now uses `storage.className=manual` at
20Gi. The old dynamic `gp2` branch, `awsChartStorageClassName`, and `chartDynamicStorageManifest`
are removed and the legacy row moved to Completed. Validation: warning-clean build, unit
1143/1143, Haskell lint, docs generate/check, CLI integration 39/39, env integration 39/39,
`git diff --check`, and canonical `dev check`. Live EKS rebinding remains the non-blocking Sprint
`5.12` / AWS parity proof axis.

**2026-07-03 — Phase 5 Sprint `5.12` closed: `eks-volume-rebind` validation surface.**
`prodbox test integration eks-volume-rebind` is now a first-class named validation:
`IntegrationEksVolumeRebind` / `ValidationEksVolumeRebind` are wired through the parser, command
registry, native planner, aggregate ordering, topology suite mapping, and per-run AWS postflight
ownership. The validation selects the retained MinIO PV/PVC inventory row, writes a sentinel through
the workload's `/export` mount, runs a teardown/spinup cycle, and compares Kubernetes PV snapshots
so the same PV/PVC remains `Bound`, the sentinel survives, and any EBS `volumeHandle` is identical
before and after the rebind. The home-substrate plan stays cluster-only; the AWS-substrate plan
engages the IAM harness and remains the non-blocking parity proof for the Sprint `7.28` static
retained-EBS PV path. Validation so far: `cabal build --builddir=.build all
--ghc-options=-Werror`, `./.build/prodbox test unit` (1139/1139, including parser/planner,
topology mapping, PV JSON parsing, report oracle, and refreshed CLI goldens),
`./.build/prodbox dev docs generate`, `./.build/prodbox dev docs check`,
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
`git diff --check`, and `./.build/prodbox dev check`. The destructive home live proof was attempted
and failed fast before mutation because `.build/prodbox.dhall` is absent; that remains a
non-blocking live-infra proof axis.

**2026-07-03 — Phase 5 Sprint `5.11` closed: test-topology command surface and `.test-data`
isolation.** `prodbox test init` now writes the executable-sibling `prodbox.test.dhall` and refuses
overwrite without `--force`; `prodbox test run <suite>|all` loads that authored topology, maps
declared suite names onto supported test scopes, writes a disposable binary-sibling
`prodbox.dhall` per variant through the shared Tier-0/config builder path, points
`storage.manual_pv_host_root` at `.test-data/<case>/`, and removes the generated config plus this
run's `.test-data` root in `finally`. `guardTestDelete` now admits only generated config under
`.build`, paths proven under `.test-data`, and `LifecycleClass PerRun` residue, while long-lived
resources and production `.data` refuse. `src/Prodbox/TestValidation.hs` resolves the sealed-Vault
host-disk audit root from the same test-run override. Validation: `cabal build --builddir=.build
all --ghc-options=-Werror`, `./.build/prodbox test unit` (1134/1134), `./.build/prodbox test
integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
`./.build/prodbox dev docs check`, `git diff --check`, and the canonical `dev check` gate. Live
multi-variant cluster proof remains a non-blocking live-infra axis.

**2026-07-02 — Phase 4 Sprint `4.40` closed: suite postflight test-EBS reaper and retain-safe
drain.** `src/Prodbox/Lifecycle/EbsVolume.hs` now owns the typed test-scoped EBS reaper plan and
runner; `src/Prodbox/TestRunner.hs` runs it after successful per-run AWS stack destroys under the
existing harness cleanup wrapper; `src/Prodbox/CLI/Rke2.hs` inserts the same reaper into the
`cluster delete --cascade` order between per-run destroys and uninstall; and
`prodbox aws ebs reap-test --yes` provides the standalone recovery entrypoint for already-leaked
test volumes. `src/Prodbox/Lifecycle/K8sDrain.hs` now exposes the `Delete`-reclaim PV selector and
PVC-binding parser as a retain-safe guard, so `Retain` EBS PVs stay outside the drain target set.
Validation: `cabal build --builddir=.build exe:prodbox`, `cabal build --builddir=.build all
--ghc-options=-Werror`, `./.build/prodbox test unit` (1123/1123), `./.build/prodbox test
integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
`./.build/prodbox dev docs check`, `git diff --check`, and `./.build/prodbox dev check`. Live EKS
postflight leak proof remains a non-blocking live-infra axis.

**2026-07-02 — Phase 4 Sprint `4.38` closed: substrate-typed worker placement and anti-affinity.**
`src/Prodbox/Cluster/Placement.hs` now owns the topology-level worker-placement plan: each machine
gets exactly one substrate-typed worker placement with required hostname anti-affinity, `maxSurge =
0`, and `maxUnavailable = 1`; duplicate machine IDs refuse before rendering; worker/machine
substrate mismatches refuse explicitly; and mixed-substrate placement is admitted only for `rke2`.
`src/Prodbox/Cluster/Topology.hs` exposes query helpers so placement consumes topology facts without
exporting raw constructors. Validation: `cabal build --builddir=.build exe:prodbox`, `cabal build
--builddir=.build all --ghc-options=-Werror`, `./.build/prodbox test unit` (1114/1114),
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env`
(39/39), `./.build/prodbox dev docs check`, `git diff --check`, and `./.build/prodbox dev
check`. Live multi-machine anti-affinity proof remains a non-blocking live-infra axis.

**2026-07-02 — Phase 4 Sprint `4.37` closed: host-provider ensure decisions and Docker Linux-frame
dispatch.** `src/Prodbox/Host/Ensure.hs` now selects the provider reconciler by detected
`HostSubstrate` (Lima for Apple Silicon, WSL2 for Windows, Incus/native for Linux) and folds
provider state into explicit idempotent decisions: already-ready is a no-op, missing providers
produce the probe/install/verify plan, reboot-required is first-class, and a wrong provider refuses
before any host-provisioning action. `src/Prodbox/DockerConfig.hs` now exposes
`dockerLinuxFrameDispatch`, so Docker-inward prodbox work runs directly on Linux and through the
Lima/WSL2 self-reinvocation frame on macOS/Windows. Validation: `cabal build --builddir=.build
exe:prodbox`, `cabal build --builddir=.build all --ghc-options=-Werror`, `./.build/prodbox test
unit` (1110/1110), `./.build/prodbox test integration cli` (39/39), and `./.build/prodbox test
integration env` (39/39). Live macOS-Lima and Windows-WSL2 provisioning remain non-blocking
host-specific proof axes.

**2026-07-02 — Phase 4 Sprint `4.36` closed: tiered-storage capacity gate and AWS quota
preflight.** `src/Prodbox/Capacity/Storage.hs` now owns the storage-specific finite-budget planner:
durable store claims draw down a declared `CapacityBudget`, the capacity constructors remain
`Bounded`/`Autoscaled` with no `Infinite` arm, autoscaled MinIO-style sinks require a
`ScalingPolicyWitness`, and ML engines carry explicit host + cluster JIT-artifact and model-cache
budgets that are included in the same finite total. `src/Prodbox/Aws.hs` exposes the AWS region
quota preflight adapter over existing `QuotaStatus` values and the live
`applyAwsCheckQuotas`/`ensureServiceQuota` boundary, so stubbed shortfalls refuse locally and live
checks continue through the canonical Service Quotas path. Validation: `cabal build
--builddir=.build exe:prodbox`, `cabal build --builddir=.build all --ghc-options=-Werror`,
`./.build/prodbox test unit` (1106/1106), `./.build/prodbox test integration cli` (39/39), and
`./.build/prodbox test integration env` (39/39). Live AWS Service Quotas checks against real
credentials remain a non-blocking live-infra proof axis.

**2026-07-02 — Phase 4 Sprint `4.34` closed: autoscaler runtime and
federation-scoped placement.** `src/Prodbox/Scaling/Autoscaler.hs` now owns the pure autoscaler
planner: scale-up requests are admitted only for clusters inside the parent-custodied federation
trust tree, capacity requests must fit the target cluster's known `CapacityBudget`, scale-down
requests refuse the current gateway leader, and accepted work is ordered so capacity-adding actions
precede capacity-removing actions. `Prodbox.Lifecycle.ResourceRegistry` now exposes
`capacityScaledManagedResources` for the canonical chart workload set (`gateway`, `keycloak`,
`keycloak-postgres`, `vscode`, `api`, `redis`, `websocket`) so later interpreters consume the same
registry-owned surface. Validation: `cabal build --builddir=.build exe:prodbox`, `cabal build
--builddir=.build all --ghc-options=-Werror`, `./.build/prodbox test unit` (1102/1102),
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
`./.build/prodbox dev docs check`, and `./.build/prodbox dev check`. Live multi-cluster placement
against a real federated substrate remains a non-blocking live-infra proof axis.

**2026-07-02 — Phase 4 Sprint `4.39` closed: pre-created EBS volumes registered as a managed
resource.** `aws-ebs-volumes` is now a `LongLived` entry in
`Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses`, with `Prodbox.Lifecycle.EbsVolume`
owning the typed EC2 `describe-volumes` / `delete-volume` subprocess boundary, JSON parsing, and
`ResidueStatus` mapping. `Prodbox.Lifecycle.TagSweep` now owns the retained-production
`prodbox.io/lifecycle=retained-ebs` carve-out, the test-scoped
`prodbox.io/lifecycle=per-run-test` + `kubernetes.io/cluster/<name>=owned` partition, and
`partitionRetainedLongLived` recognizes retained EBS rows. `Prodbox.CLI.Rke2` exposes
`retainedStorageInventoryEntries` so home and AWS project the same deterministic retained
namespace/PV/PVC inventory. `DEVELOPMENT_PLAN/substrates.md` was regenerated from the registry and
now contains the `aws-ebs-volumes` row. Validation: `cabal build --builddir=.build exe:prodbox`,
`cabal build --builddir=.build all --ghc-options=-Werror`, `./.build/prodbox test unit`
(1095/1095), `./.build/prodbox dev docs generate`, `./.build/prodbox dev docs check`,
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
and `./.build/prodbox dev check`. Sprint `4.40` has since landed the suite postflight test-EBS
reaper and retain-safe drain; Sprint `7.28` still owns live static EBS PV materialization on EKS.

**2026-07-02 — Phase 3 Sprint `3.21` partially landed; superseded by the 2026-07-03 broker
transport closure above.** Sprint `2.27` no longer blocks this work: `src/Prodbox/Pulsar/Codec.hs`,
`src/Prodbox/Pulsar/Topic.hs`, `src/Prodbox/Pulsar/Envelope.hs`, the typed
`src/Prodbox/Pulsar/Client.hs` boundary, and `charts/pulsar` now exist. The local surface proves
canonical CBOR payload round trips, `topicFor`, `WorkCommand`/`WorkEvent`/`WorkResult`, and
gateway deployment-plan rendering of the
retained Pulsar chart. Validation: `cabal build --builddir=.build exe:prodbox`, `cabal build
--builddir=.build all --ghc-options=-Werror`, `./.build/prodbox test unit` (1085/1085),
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
and `./.build/prodbox dev lint chart`.

**2026-07-02 — Phase 2 Sprint `2.28` closed: durable at-least-once event store canonical
CBOR.** The shared payload codec is now code-owned in `src/Prodbox/Cbor.hs`, with
`CborPayload` and the deterministic JSON-shaped value-to-CBOR conversion used by both gateway
signing and durable events. `src/Prodbox/Daemon/Events.hs` now stores
`eventPayload :: CborPayload`, derives `Serialise` for durable event identifiers and
`StoredEvent`, and exposes `encodeStoredEventCbor` / `decodeStoredEventCbor`; the
`markEventProcessed` first-write-wins `processed_at IS NULL` guard is unchanged. Validation:
`cabal build --builddir=.build exe:prodbox`, `cabal build --builddir=.build all
--ghc-options=-Werror`, `./.build/prodbox test unit` (1081/1081),
`./.build/prodbox test integration cli` (39/39), `./.build/prodbox test integration env` (39/39),
and `./.build/prodbox dev check`. Phase `2` is reclosed for the CBOR migration batch; Sprint `3.21`
has since landed the local Pulsar CBOR/topic/chart boundary plus repo-owned Haskell broker
transport/framing for native Pulsar I/O.

**2026-07-02 — Phase 2 Sprint `2.27` closed: gateway gossip + Orders canonical CBOR.** The
gateway peer wire surface now uses canonical CBOR for `Orders`, `SignedEvent`, and
`PeerEventBatch`: `src/Prodbox/Gateway/Types.hs` owns `CborPayload`, `encodeOrdersCbor`,
`decodeOrdersCbor`, `encodeSignedEventCbor`, `decodeSignedEventCbor`, and canonical unsigned-event
bytes for hash/HMAC input; `src/Prodbox/Gateway/Peer.hs` parses `POST /v1/peer/events` as
`application/cbor`; and `src/Prodbox/Gateway/Daemon.hs` pushes CBOR peer batches and signs
heartbeat/claim/yield values after converting them to canonical CBOR payload bytes. `prodbox.cabal`
now carries `cborg` and `serialise` in the library component. Validation: `cabal build
--builddir=.build exe:prodbox`, `cabal build --builddir=.build all --ghc-options=-Werror`,
`./.build/prodbox test unit` (1080/1080), `./.build/prodbox test integration cli` (39/39),
`./.build/prodbox test integration env` (39/39), supported-gateway-path text search for
legacy non-CBOR payload terms plus `payloadJson`/`payload_json` (no hits), and
`./.build/prodbox dev check`.
Sprint `2.28` closes the durable at-least-once event-store CBOR surface later the same day.

**2026-07-02 — Phase 1 Sprint `1.54` closed: test-topology schema and topology-mode
preflight.** The authored test-run surface is now code-owned in `dhall/TestTopologySchema.dhall`
and `src/Prodbox/TestTopology.hs`, with executable-sibling `prodbox.test.dhall` resolution in
`src/Prodbox/Repo.hs`, decode/validation in `src/Prodbox/Settings.hs`, and the topology-mode
production-sibling refusal in `src/Prodbox/TestRunner.hs`. When an authored
`prodbox.test.dhall` exists, a production `prodbox.dhall` beside the binary aborts before
topology-driven test work can clobber it; Sprint `5.11` has since landed the command surface that
writes a disposable per-variant run config under this gate. Validation: `cabal build --builddir=.build
exe:prodbox`, `dhall type --file dhall/TestTopologySchema.dhall`, `./.build/prodbox test unit`
(1080/1080), `./.build/prodbox test integration cli` (39/39), and `./.build/prodbox test
integration env` (39/39), and `./.build/prodbox dev check`. Phase `1` is reclosed for the
2026-07-01 doctrine-batch schema/config surface; `test init` / `test run` and `.test-data/`
isolation landed later in Sprint `5.11`.

**2026-07-02 — Phase 1 Sprint `1.53` closed: cluster-topology schema and config surface.** The
cluster topology surface is now code-owned in `dhall/cluster/Schema.dhall`,
`src/Prodbox/Cluster/Substrate.hs`, `src/Prodbox/Cluster/Topology.hs`, and
`src/Prodbox/Cluster/Placement.hs`. `ConfigFile` and Tier-0 parameters now carry the declared
`cluster_topology` field; the default is the home-local single-machine `rke2` topology, and local
config validation rejects malformed decoded topology values before command execution. Validation:
`cabal build --builddir=.build exe:prodbox`, `dhall type --file dhall/cluster/Schema.dhall`,
`./.build/prodbox test unit` (1075/1075), `./.build/prodbox test integration cli` (39/39),
`./.build/prodbox test integration env` (39/39), and `./.build/prodbox dev check`. Phase `1`
is now reclosed for this schema/config batch; runtime placement/anti-affinity enforcement has since
landed in Sprint `4.38`.

**2026-07-02 — Phase 1 Sprint `1.52` closed: multi-OS host-provider DSL and relaxed host gate.** The
host-provider surface is now code-owned in `src/Prodbox/Host/Substrate.hs`,
`src/Prodbox/Host/Tool.hs`, `src/Prodbox/Host/Lift.hs`, `src/Prodbox/Host/Lima.hs`,
`src/Prodbox/Host/Wsl2.hs`, and `src/Prodbox/Host/Ensure.hs`. `DockerConfig` now gates host-frame
Docker to detected Linux hosts, the prerequisite registry adds `host_substrate_supported`, and the
cluster prerequisite bundle now starts from that multi-OS host gate instead of the old
`supported_ubuntu_2404` Ubuntu-only root. Validation: `cabal build --builddir=.build exe:prodbox`,
`./.build/prodbox test unit` (1070/1070), `./.build/prodbox test integration cli` (39/39),
`./.build/prodbox test integration env` (39/39), and `./.build/prodbox dev check`. Phase `1`
is now reclosed for this schema/config batch; the follow-on host-provider ensure decision layer and
Docker Linux-frame dispatch have since landed in Sprint `4.37`.

**2026-07-02 — Phase 1 Sprint `1.51` closed: capacity/scaling schema and config surface.** The
shared capacity budget algebra is now code-owned in `dhall/capacity/Schema.dhall` and
`src/Prodbox/Capacity/Config.hs`, `ConfigFile` carries the binary-sibling `capacity` block, and the
old deployment replica knobs are replaced by validated substrate-indexed scaling policies in
`src/Prodbox/Substrate.hs` / `src/Prodbox/Settings.hs`. Chart, AWS-substrate, and RKE2 renderers now
consume scaling through `replicasForSubstrate`, using a fixed count on home/local and the lower bound
for elastic AWS policies until the Sprint `4.34` autoscaler planner is interpreted by the live
runtime. Validation: `cabal build
--builddir=.build exe:prodbox`, `dhall type --file dhall/capacity/Schema.dhall`,
`./.build/prodbox test unit` (1064/1064), `./.build/prodbox test integration cli` (39/39),
`./.build/prodbox test integration env` (39/39), and `./.build/prodbox dev check`. Phase `1` is
now reclosed for this schema/config batch; the later autoscaler and tiered-storage surfaces have
landed in Sprints `4.34` and `4.36`, and the spot-economics gate has landed in Sprint `7.27`.

**2026-07-02 — Unified block storage across substrates scheduled; Sprint `4.39` code-owned registry
surface landed.** An abnormal AWS bill traced to leaked, unattached `gp2` EBS volumes from EKS test
runs (the dynamic `gp2` path with `reclaimPolicy: Delete` orphaned CSI-provisioned volumes on
teardown) motivates unifying block storage onto the home substrate's static model. The SSoT
[storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md) is extended
so EKS uses **pre-created EBS volumes lifted in as static `Retain` PVs** (CSI `volumeHandle`,
AZ-pinned), mirroring the home `manual`/no-provisioner/hostPath model — **no dynamic provisioning on
either substrate**, satisfying
[cluster_topology_doctrine.md § 4](../documents/engineering/cluster_topology_doctrine.md).
Production retains EBS (the EBS analog of `.data/`); the test harness deletes only test-scoped EBS at
suite postflight. `lifecycle_reconciliation_doctrine.md` leak-class 2, `helm_chart_platform_doctrine.md`,
`vault_doctrine.md`, `aws_integration_environment_doctrine.md`, and
`tiered_storage_capacity_doctrine.md` are reconciled to defer to the SSoT. Sprint `4.39` has now
landed the `aws-ebs-volumes` registry entry, typed EC2 `describe-volumes`/`delete-volume` boundary,
retain/test-scoped tag partitioning, and retained-inventory parity; Sprint `4.40` has landed the
suite postflight test-EBS reaper, retain-safe drain guard, cascade hook, and
`prodbox aws ebs reap-test --yes` recovery entrypoint. **No new phase** (Standard E
preserved): three phases reopen to expand their own owned surface — **Phase 7** (Sprint `7.28`
static EBS PVs superseding the dynamic `gp2` path of `7.5.c.i`; Sprint `7.29` EKS VPC ownership
hardening + always-fresh test VPC), **Phase 4** (Sprints `4.39` and `4.40` closed), and **Phase 5**
(Sprint `5.12` closed on its code-owned `eks-volume-rebind` identical-rebinding validation surface;
the destructive home run and AWS run are non-blocking live-proof axes). Each reopen
extends, it does not reverse, the prior owned surface (Standards A/N); the superseded dynamic-`gp2`
path plus `awsChartStorageClassName` and `chartDynamicStorageManifest` (AWS usage) are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) Pending Removal.

**2026-07-01 — Five new doctrine areas scheduled (documentation + plan only): CBOR-everywhere,
resource-scaling, topic-lifecycle + tiered-storage, multi-OS host/topology, and test-topology.**
Seven new authoritative engineering docs land —
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md),
[pulsar_topic_lifecycle_doctrine.md](../documents/engineering/pulsar_topic_lifecycle_doctrine.md),
[tiered_storage_capacity_doctrine.md](../documents/engineering/tiered_storage_capacity_doctrine.md),
[host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md),
[cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md), and
[test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md) — specifying prodbox
as the proven single-node "root control-plane" specialization that the `~/amoebius` umbrella
generalizes. Structured payloads are unified on canonical **CBOR project-wide** (the older
non-CBOR gateway wording in
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
is superseded; `cborg`/`serialise` landed for the Phase `2` CBOR surfaces). **No new phase**
(Standard E preserved): adoption is
scheduled as sprints across existing phases — `2.27`/`2.28` (CBOR gateway
gossip + Orders + at-least-once store), `3.21` (Pulsar chart + self-maintained CBOR client boundary,
with repo-owned Haskell broker transport/framing now landed),
`1.51`–`1.54` (capacity/scaling schema; multi-OS host-provider DSL; cluster-topology schema;
`prodbox.test.dhall` + the sibling-config fail-fast inversion), `4.34`–`4.38` (autoscaler +
federation-scoped placement now landed; topics-as-managed-resources; tiered-storage budget +
per-deploy region service-quota gate + mandatory ML JIT/model-cache budget now landed;
Lima/WSL2/Incus provisioning now landed;
substrate-typed one-worker-per-machine placement now landed), `5.11` (`test init`/`test run`
topology + `.test-data/` isolation now landed), and `7.27` (spot-price economics). Every
`Blocked by` edge is
earlier-or-same-phase (Standard N). This batch began as **docs + plan only**; Sprints `1.51` through
`1.54` have since landed the capacity/scaling schema, the multi-OS host-provider config/detection
surface, the cluster-topology config/schema surface, and the test-topology schema/preflight
surface, and Sprints `2.27`–`2.28` have landed the gateway gossip + Orders CBOR codec and durable
at-least-once CBOR store; Sprint `3.21` has landed the Pulsar CBOR/topic/envelope/chart boundary
and repo-owned Haskell broker transport/framing, Sprint `4.35` has landed Pulsar topics as managed
resources, and Sprint `4.34` has landed the pure
autoscaler planner plus federation-scoped placement guard; Sprint `4.36` has landed the
tiered-storage finite-budget planner, autoscaling witness, ML storage totals, and AWS quota
preflight adapter; Sprint `4.37` has landed host-provider ensure decisions and Docker Linux-frame
dispatch; Sprint `4.38` has landed substrate-typed one-worker-per-machine placement and
anti-affinity; Sprint `7.27` has landed the spot-price economics gate and AWS observer surface.
The illegal-states the DSLs make unrepresentable (rke2-without-a-VM on Apple/Windows,
multi-node-rke2 on one machine, >1 compute worker/machine, over-committed node/cluster/region,
unbounded MinIO without an autoscaling witness, a test touching `.data/`, a literal secret at rest)
are catalogued in the new docs, aligned with amoebius's `illegal_state_catalog.md`. See
[substrates.md](substrates.md) for the host-provider dimension and
[system-components.md](system-components.md) for the new inventory rows.

**2026-06-26 — `test all` reaches 17/18 validations; only `lifecycle` (#18) fails on an AWS ENI
teardown race.** With the gateway-daemon fix, the chain cleared validations 1–17 (charts-vscode →
sealed-vault, incl. gateway-pods/partition, charts-platform, keycloak-invite, charts-storage). The
final `lifecycle` validation failed on the per-run EKS destroy: `delete-security-group … (DependencyViolation)`.
Root cause (`Prodbox.Infra.AwsEksTestStack` destroy flow): it drains (LBs/PVCs) → purges *detached*
ENIs (`status=available`) → deletes the cluster SG → `pulumi destroy`, with one *immediate* retry — but
never **waits** for AWS to detach the LB-created ENIs (async, minutes). So the SG-delete and both
destroy attempts race the still-attached ENIs. Confirmed by retrying the destroy manually after a delay:
`AWS EKS test stack: destroyed and residue check passed`. All per-run stacks were then cleaned up
(`aws-eks` + `aws-test` destroyed, `aws-eks-subzone` absent) — **no leaked AWS spend**. This is the
first *non-functional* failure (AWS eventual-consistency teardown timing, not a prodbox logic bug); the
durable fix is an ENI-detachment poll-wait before the SG-delete/destroy. Gates for the 17 functional
fixes: `dev check` 0, `test unit` 1062/1062.

**2026-06-26 — `lifecycle` is flaky/multi-modal at the teardown boundary (partly environmental); ENI-wait
landed.** Implemented `waitForClusterSecurityGroupEnisDetached` in the `AwsEksTestStack` harness destroy
flow (poll the cluster SG's dependent ENIs, 30×10 s budget, before SG-delete/`pulumi destroy`; best-effort
— never blocks teardown). Two `test all` re-runs after it BOTH still failed `lifecycle`, but on **two
different modes**: (ta13) the ENI `DependencyViolation` the fix targets; (ta14) `Blocked: Vault is sealed`
— the `lifecycle` validation does cluster delete→reconcile, bringing up a **fresh sealed Vault** that the
per-run destroy then races before auto-unseal completes, with the host under memory pressure (`swap free:
0 MiB`). So the ENI-wait is correct for mode (ta13) but never fired in (ta14). All orphaned per-run stacks
were cleaned up after each run — **no leaked AWS spend**. Conclusion: the remaining `lifecycle` failure is
non-functional teardown-orchestration flakiness (ENI timing + Vault-unseal-after-reconcile race +
host-memory pressure), expensive and flaky to chase via repeated EKS runs. The functional chain is
complete at 17/18. `dev check` 0, `test unit` 1062/1062.

**2026-06-26 — `lifecycle` teardown-ordering hardening landed (Vault-unseal race).** Implemented the
two Vault-unseal fixes for the ta14 mode (validated at build/`dev check`/`test unit` level, not via a
fresh EKS run, by request): (1) the `lifecycle` validation now runs `cluster delete → cluster reconcile
→ vault unseal → cluster health` — the idempotent `vault unseal` (no-op when unsealed) closes the race
where reconcile's auto-unseal loses to host memory pressure, leaving Vault sealed for the health check;
(2) `awsPostflightDestroyActions` (`Prodbox.TestRunner`) prepends an idempotent `vault unseal` before
the per-run `aws stack … destroy` commands, so the postflight destroy never races a sealed Vault (and
if the cluster is genuinely down, the unseal fails and the destroys are skipped, preserving operational
creds for manual recovery as before). Combined with the already-landed `waitForClusterSecurityGroupEnisDetached`
ENI-wait, both observed `lifecycle` teardown modes are now addressed. `dev check` 0, `test unit`
1062/1062.

**2026-06-26 — ✅ `prodbox test all` FULLY GREEN (exit 0).** End-to-end confirmation after resetting host
swap (the memory pressure that caused the flake): **18/18 validations pass** (18 `body exit=ExitSuccess`,
0 failures, including `lifecycle`), `prodbox-unit` PASS (1062), `prodbox-integration` PASS (39), a real
EKS cluster provisioned and **cleanly destroyed** (`destroyed and residue check passed`; final residue
check `absent`) — **no leaked AWS spend**. The hardening worked: 2 transient `Vault is sealed` moments
occurred but the idempotent `vault unseal` retries recovered them, so the `lifecycle` teardown and the
postflight per-run destroy both succeeded. This closes the full `test all` chain that began the session
failing at config preflight.

**2026-06-25 — `gateway-daemon` validation fixed: stale config renderer (Text creds + missing `vault`).**
After the `aws-eks` fix, `test all` cleared 10 validations and failed at `gateway-daemon` with
`failed to decode gateway daemon Dhall config … Expression doesn't match annotation`. Root cause:
`renderGatewayValidationConfigDhall` (`Prodbox.TestValidation`) rendered `aws_creds`/`minio_creds`/
`event_keys.value` as `Text` and omitted the top-level `vault` field, but the daemon decoder
(`Prodbox.Gateway.Settings.DaemonConfigDhall`) types those creds as the `SecretRef` union and carries a
`vault :: Maybe VaultKubernetesAuthDhall` (both added later; the validation renderer was never updated,
unlike the production `renderGatewayConfigTemplate`). Fix: render the creds as the `SecretRef` union
(`event_keys.value` as a `TestPlaintext` SecretRef; `aws_creds`/`minio_creds` `None`-annotations as the
union, `region` stays `Text`) and add `vault = None {…}`. Added a unit regression test that renders the
validation config and decodes it through `decodeDaemonConfigDhallWith` (catches the mismatch without an
EKS run). Further passes peeled back two more layers: `loadDaemonConfig` *eagerly* resolves every SecretRef during
decode, and the **host** `gateway status` can resolve neither a `TestPlaintext` ref (production mode
forbids it) nor a `Vault` ref (no in-cluster Kubernetes-auth token on the host). But `runGatewayStatus`
never *uses* `event_keys` — it queries the running daemon by endpoint (`queryGatewayState` ignores the
config path). So the final fix renders `event_keys = [] : List {…}` (empty — nothing to resolve), which
decodes cleanly and lets the host status check query the live daemon. Gates: `dev check` 0,
`test unit` 1062/1062. The full validation list (`TestPlan.hs`) is 18; `gateway-daemon` is #11.

**2026-06-25 — `aws-eks` validation fixed: invalid `plaintext` Pulumi secrets-provider.** With the
realm reconciler in place, `test all` advanced through 7 validations and failed at `aws-eks` with
`could not create secrets manager for new stack: open secrets.Keeper: no scheme in URL "plaintext"`.
`AwsSesStack` was already fixed for this (Sprint 7.23 — `plaintext` is not a valid pulumi
secrets-provider URL on current pulumi; it uses the empty-passphrase provider), but
`AwsTestStack` / `AwsEksTestStack` / `AwsEksSubzoneStack` still passed `--secrets-provider plaintext`.
Fix: switch those three to `--secrets-provider passphrase` (each already sets
`PULUMI_CONFIG_PASSPHRASE = ""`; at-rest secrecy is the Model-B Vault-Transit envelope). Gates:
`dev check` 0, `test unit` 1061/1061. Not yet validated end-to-end (the `aws-eks` validation provisions
a real EKS cluster).

**2026-06-25 — charts-vscode OIDC 401 fixed durably: realm-secret reconciler.** The `charts-vscode`
validation got a persistent Keycloak 401 (`invalid_client_credentials`). Root cause: Keycloak boots
with `--import-realm` (`IGNORE_EXISTING` — never overwrites an existing realm), the `prodbox` realm
lives in the durable keycloak-postgres, and the Vault OIDC secrets are `VaultSecretGenerated`
(write-if-absent) — so **nothing reconciled an existing realm's client secrets** when postgres and
Vault drifted, leaving a stale `prodbox-api` secret. Proven by re-syncing via the admin API (token →
HTTP 200). Durable fix: added `setClientSecret`/`resetUserPassword` to `Prodbox.Keycloak.Admin` and
`reconcileRealmOidcSecretsAtPublicHost` to `Prodbox.UsersAdmin` (reads the three OIDC client secrets +
demo-user password from Vault, patches the live realm via the admin API — idempotent, mirroring the
existing realm-SMTP reconcile that exists for the same import-skip reason), wired as a
`reconcileKeycloakRealmSecrets` preflight step in `runChartsVscodeValidation` before the password
grant. Validated by **injecting deliberate drift** (wrong `prodbox-api` secret → token 401) and
confirming the reconciler heals it on the next `test all`. Gates: `dev check` 0, `test unit` 1061/1061.

**2026-06-24 — 4 Phase-2/2 integration-test regressions fixed (two distinct causes, both from this
session's `ses.*`/`pulumi_state_backend` work).** With the whole lifecycle green, `test all` reached
Phase 2/2 and 4 of 39 integration tests failed. (1) **Decode** — the bare-record `test-secrets.dhall`
generators in `test/integration/CliSuite.hs` (`testSecretsDhallWithAdmin*`) didn't carry the new
`TestSecrets` fields, so the binary's decoder saw missing fields; added a shared
`testSecretsOperatorIdFields` spliced into both generators (fixed `vault lifecycle` + `nuke`).
(2) **Clobber** — `regenerateConfigFromTestSecrets` overwrote the fixture config's populated
`route53.zone_id` with the fake test-secrets' empty value (the guard now also requires `ses`/`backend`,
so the regen ran), failing the IAM harness with `route53.zone_id must not be empty`; added
`harnessPreferNonEmpty` so the regen fills empty operator fields from test-secrets without clobbering a
populated one (identity for real `test all`, which supplies non-empty values) — fixed `aws-iam` +
`acme`. All 4 now pass; gates: `dev check` 0, `test unit` 1061/1061.

**2026-06-24 — `pulumi_logged_in` prerequisite fixed: `readMinioCredentials` read a removed k8s
Secret.** After the workload fixes, `test all` reached the Pulumi MinIO-backend login check, which
failed with `kubectl get secret failed for rootUser: secrets "minio" not found`. Root cause:
`Prodbox.Infra.MinioBackend.readMinioCredentials` (used by the login check + the per-run substrate
stacks `aws-test`/`aws-eks-subzone`) read the `minio` Kubernetes Secret, but Sprint 7.25 removed it —
the MinIO root credential is now the static constant `Prodbox.Minio.RootCredential`
(`minioRootUser`/`minioRootPassword`), `--set`-injected by `renderMinioChartArgs`. Verified the running
`minio-0` has `MINIO_ROOT_USER=prodbox-minio-root` (= the constant). Fix: `readMinioCredentials` returns
the static constant directly (removed the stale `readSecretField` Secret read). Gates: `dev check` 0,
`test unit` 1061/1061. Distinct subsystem; unrelated to the binary-sibling/config doctrine.

**2026-06-24 — websocket workload CrashLoopBackOff fixed: missing Vault egress in the
`websocket-isolation` NetworkPolicy.** After the api fix, `test all` reached the websocket workload,
which crash-looped with `Vault Kubernetes auth login failed: HttpTimeout "connection timeout"`. Root
cause: unlike the api (`oidc = None`), the websocket resolves its `oidc.client_secret`
`SecretRef.Vault` at startup via Vault k8s auth (role `websocket-oidc`), but
`charts/websocket/templates/networkpolicy.yaml` allowed egress only to redis (6379), keycloak (8080),
and DNS (53) — **no Vault (8200 / `vault` ns) rule** — so the auth timed out. (vscode/gateway run
because their NetworkPolicies allow Vault.) Fix: add the Vault egress rule to the websocket
NetworkPolicy, mirroring the vscode chart. LIVE-VERIFIED: after `charts delete websocket --yes` +
`charts reconcile websocket`, the websocket pod is **Ready (restarts=0)**. `dev lint chart` 0.
Unrelated to the binary-sibling/config-generation doctrine.

**2026-06-24 — api workload CrashLoopBackOff fixed: stale `api` chart `config.dhall` template.** With
all config/SES/backend blockers cleared, `test all` reached the workload stage and the `api` pod
crash-looped. Root cause: `charts/api/templates/configmap-config.yaml` rendered
`oidc.client_secret : Text`, but the workload decoder (`Prodbox.Workload.Settings.OidcConfigDhall`,
`client_secret :: SecretRef`) expects the `< Vault | TransitKey | Prompt | TestPlaintext >` union —
the api chart was never updated when `oidc.client_secret` became a `SecretRef` (the websocket chart
was). The Dhall type mismatch failed the in-process decode of `/etc/workload/config.dhall`. Fix:
align the api chart's `oidc.client_secret` type annotation to the `SecretRef` union. LIVE-VERIFIED:
after `charts delete api --yes` + `charts reconcile api`, the api pod is **Ready (restarts=0)**. Gates:
`dev check` 0, `dev lint chart` 0, `test unit` 1061/1061 (the `assertGeneratedSecretRefArtifact`
api-template check still green). Unrelated to the binary-sibling/config-generation doctrine.

**2026-06-24 — Sprint `5.10` follow-up: harness force-syncs the in-force SSoT (fixes the stale-config
edge-reconcile failure).** Root-caused a live `test all` failure: on an ESTABLISHED cluster the edge
reconcile's gateway-chart deploy reads the **in-force config SSoT** (MinIO), not the binary-sibling
file, and failed `gateway chart requires route53_zone_id in settings` because the SSoT was seeded
empty before the operator fields were populated (the harness only regenerated the binary-sibling
file, which the preflight validated — a config-source mismatch). Fix: `forceSyncInForceConfigFromFile`
(`src/Prodbox/Settings.hs`) unconditionally re-seals the binary-sibling config into the in-force SSoT
(root-Vault-token write; best-effort/no-op when not established or Vault sealed), wired into the
harness after the pre-reconcile unseals Vault (`src/Prodbox/TestRunner.hs`). LIVE-VERIFIED: in-force
`route53.zone_id` now populated (`config show`), the gateway error is gone, and `test all` advanced
past it to the next deferred operator field (`ses.sender_domain`). Gates: `dev check` 0, `test unit`
1061/1061. **Follow-up landed same day:** the `ses.*` block (`ses_sender_domain` /
`ses_receive_subdomain` / `ses_capture_bucket`) was wired the same way as `route53_zone_id` — added to
`TestSecrets` + the harness regen (`configFromSetupInput` doesn't author `ses.*`, so the harness
injects it directly from `test-secrets.dhall`), schema regenerated, and the fixture populated from the
operator's own `pulumi/aws-ses/Pulumi.aws-ses.yaml` (`test.resolvefintech.com` /
`inbox.test.resolvefintech.com` / the existing `prodbox-ses-capture` bucket). The
`pulumi_state_backend` block (`prodbox-pulumi-state-long-lived` / `us-west-2` / `pulumi/`, from
`pulumi/aws-ses/Pulumi.yaml`) was wired the same way (needed for the long-lived `aws-ses` backend),
and the long-lived **`aws-ses` stack was provisioned** (`prodbox aws stack aws-ses reconcile`, exit 0:
SES sending identity `test.resolvefintech.com` VERIFIED + DKIM SUCCESS, receive rule set
`prodbox-receive-rule-set`, `prodbox-ses-capture` imported, SMTP IAM user `prodbox-ses-smtp`). `aws
stack aws-ses reconcile` reads the binary-sibling config (`loadConfigFile`) + the `test-secrets.dhall`
admin credential — no operational `aws.*` needed. Remaining: only the AWS-substrate-only
`aws_substrate.*` fields (not exercised on home-local).

**2026-06-24 — Binary-sibling + harness-generated-config doctrine LIVE-PROVEN; one follow-up fix
(Sprint `1.49`) surfaced + fixed.** A live home `prodbox test all` confirmed the doctrine end-to-end:
the harness regenerated the binary-sibling `prodbox.dhall` from `test-secrets.dhall` (`route53.zone_id`
populated), the **original `route53.zone_id must not be empty` failure is gone**, the managed AWS IAM
harness setup PASSED (operational IAM user minted, `POLICY_TIER=full`), the in-container image build's
`RUN prodbox config generate` PASSED, and the cluster came fully up (control plane, all platform
charts). The live run surfaced one bug in Sprint `1.49`: `config generate` was gated by `findRepoRoot`
and failed in the container's non-repo cwd — fixed by adding `NativeConfig ConfigGenerate` to
`canRunWithoutRepoRoot` (`src/Prodbox/App.hs`) with a regression test; gates re-green (`dev check` 0,
`test unit` 1061/1061). The run's remaining failure is deeper, in `cluster reconcile --with-edge`
(public-edge / real-ZeroSSL-ACME bring-up) — pre-existing live-infrastructure territory unrelated to
this doctrine, tracked as a non-blocking live-proof.

**2026-06-23 — Binary-sibling `prodbox.dhall` doctrine LANDED end-to-end (Phase `1` Sprints
`1.48`–`1.50` ✅; Phase `5` Sprint `5.10` ✅).** Sprint `5.10` closed the loop the doctrine was
motivated by: the test harness now regenerates the binary-sibling `prodbox.dhall` from
`test-secrets.dhall` (`route53_zone_id` added to `TestSecrets`; the real `resolvefintech.com` zone in
the fixture) + baked defaults through the shared `configFromSetupInput` builder, so `prodbox test all`
runs from a freshly-generated skeleton without an interactive `config setup`. Gates: `dev check` 0,
`test unit` 1060/1060. The `route53.zone_id must not be empty` preflight failure that started this
work is now code-resolved (live-proof: a real `test all` run, non-blocking). The reopened Phase `1` config-surface work is code-complete and
validated: `1.48` (binary-sibling resolution via `resolveTier0ConfigPath` + the `…AtPath`
path-injection seam for in-process tests), `1.49` (removed `docker/default-prodbox.dhall`; the image
RUNs the binary to generate its binary-sibling config; daemon fallback repointed; ConfigMap override
unchanged), `1.50` (the shared pure `configFromSetupInput` builder). Gates: `prodbox dev check` 0,
`prodbox test unit` 1060/1060. Integration suites run a tmpDir-local binary against a sibling fixture.
Phase `5` Sprint `5.10` (harness generates its run config from `test-secrets.dhall` through the
`1.50` builder) is now unblocked.

**2026-06-23 — Binary-sibling `prodbox.dhall` doctrine: Phase `1` reopened (Sprints `1.48`–`1.50`
📋/⏸️) and Phase `5` reopened (Sprint `5.10` ⏸️).** Adopting hostbootstrap's binary-owns-its-config
contract: every `prodbox` binary resolves its Tier-0 `prodbox.dhall` at the **binary-sibling path**
(`.build/prodbox.dhall`, beside the executable), the same filename in every context — never the repo
root and never a `--config` flag; the committed/copied container default
(`docker/default-prodbox.dhall`) is **removed**, with the in-container config generated by **running
the binary** post-build; and the **test harness generates its run config** through the same builder
production uses, sourcing cleartext operator ids (`route53.zone_id`) from `test-secrets.dhall`.
Motivation: `prodbox test all` from a freshly-generated skeleton failed the managed AWS IAM harness
preflight (`route53.zone_id must not be empty`) because nothing populated the operator fields
non-interactively. Doctrine bodies changed this pass:
[config_doctrine.md](../documents/engineering/config_doctrine.md) §0 (Tier 0 + new "The test harness
generates its run config") / §2 / §3 / §9 / §10,
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md),
plus `../README.md` and `../CLAUDE.md`. The plan-side reopenings:

- **Phase `1` reopened** to expand its own Tier-0 config surface with three sprints in
  [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md): Sprint `1.48`
  (binary-sibling resolution, 📋 Planned), Sprint `1.49` (remove `docker/default-prodbox.dhall`;
  container generates config by running the binary, ⏸️ Blocked by `1.48`), Sprint `1.50` (factor out
  the shared `configFromSetupInput` builder, 📋 Planned). Forward-only `Blocked by`
  ([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)).
- **Phase `5` reopened** to expand its own test-harness surface with Sprint `5.10`
  (harness-generated run config from `test-secrets.dhall`, ⏸️ Blocked by earlier-phase Sprints
  `1.48`/`1.50`) in [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md). Removals
  recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) (the
  `docker/default-prodbox.dhall` row superseded; repo-root resolution + baked-default seeding added).

**2026-06-23 — Sprint `7.26` ✅: cascade tag sweep carves out retained long-lived shared infra.**
Operator-reported: `cluster delete --cascade --yes` printed a postflight tag-sweep "manual cleanup
required" refusal naming the long-lived `pulumi_state_backend` bucket
(`prodbox-pulumi-state-long-lived`) — which `cluster delete` retains **by design** (destroyed only by
`prodbox nuke`). The bucket surviving was correct; the sweep flagging it was a false positive (it was a
best-effort step, so the command still exited 0 — a misleading message, not a failed teardown). Fix:
`TaggedResource` now carries the matched tag value, a pure `partitionRetainedLongLived` carves out the
retained classes (`prodbox.io/role=long-lived-pulumi-state` + `prodbox.io/substrate=shared`), and
`runCascadePostflightTagSweep` refuses only on genuine per-run/cluster escapees while reporting the
retained resources as "left in place by design". `prodbox nuke`'s own sweep is unchanged (it exists to
destroy them). Gates: `dev check` 0, `test unit` (state-bucket + `aws-ses` carve-out, genuine-escapee
still-refused, mixed → refuse-only-the-stray). See Phase 7 Sprint `7.26`.

**2026-06-22 — Sprint `7.25` ✅ (code-owned): disk-free Vault unseal — unlock bundle MinIO-only.**
Landed the cutover that takes the Tier-1 unlock bundle fully off host disk into the durable MinIO
bucket, so the host's local disk holds NO material that can unseal Vault. The previously-cited risk
(MinIO unreachable at unseal → brick) is removed by the precondition that **MinIO depends on nothing but
the cluster** — it can only be down when the cluster is down, when there is nothing to unseal anyway.
Three coupled parts: **(A)** MinIO is now cluster-only — its chart's `vault-secrets` init container is
gone and the static root cred is injected directly via `renderMinioChartArgs --set`; **(B)** MinIO is
reordered ahead of Vault in `applyNativeInstallPlan`; **(C)** the host-disk bundle write + disk fallback
are dropped (MinIO is the sole source; the bundle stays password-AEAD-sealed). The config loader's
"established" probe moved to a NON-SECRET `.cluster-established` marker (the only on-disk artifact). This
**closes Sprint `7.19`'s deferred 🧪 disk-free axis**. Accepted edge: wiping the MinIO PV while retaining
Vault loses the unseal source (wipe both or neither). Gates: `dev check` 0, `test unit` 1053/1053, the
disk-free `vault lifecycle` integration test passes. **Live-proven 2026-06-23**: a `.data/`-wiped
`cluster reconcile` (RC=0) brought MinIO up first, wrote the bundle to + read it from the durable MinIO
bucket, with **no `vault-unlock-bundle.age` on disk** and the `.cluster-established` marker stamped — no
`InvalidAccessKeyId`, no disk fallback. The operator config was regenerated headlessly by the new
**`prodbox config generate`** (non-interactive, idempotent, renders `prodbox.dhall` from
`defaultConfigFile`), paired with removing the `defaultProjectConfig` synthesis from the `vault init`
floor stamp so the binary now **fails fast** when `prodbox.dhall` is absent (operator-directed). Removed
machinery is in [legacy-tracking → Completed](legacy-tracking-for-deletion.md#completed).

**2026-06-22 — Sprint `7.19` MinIO credential simplified to STATIC ✅ (the password-derivation was
security theatre).** Operator decision: the MinIO access credential is not prodbox's security
boundary — confidentiality comes from Vault Transit (every stored object is an envelope) and the
password-AEAD seal on the unlock bundle; the access credential only gates ciphertext over a
localhost NodePort (the same posture as Harbor's hardcoded creds). So BOTH password-derived MinIO
credentials — the 2026-06-21 `deriveMinioRootPassword` (root) and `deriveBootstrapMinioCredential`
(bootstrap read) — are replaced by a single **static** constant (`Prodbox.Minio.RootCredential`).
A static credential is stable across rebuilds (a retained MinIO PV always matches Vault, fixing the
original mismatch just as the derivation did, but simpler) AND is a credential MinIO actually accepts,
so the Tier-1 unlock-bundle dual-write/read round-trips through MinIO — **resolving the
`InvalidAccessKeyId` axis** that was previously deferred. `secret/minio/root.rootPassword` is now a
`staticField`; the bundle I/O uses the static root via `bootstrapObjectStoreConfig`; all the
derivation + `vaultReconcileSuppliedSecretValues` override machinery (across `BootstrapBundle`,
`VaultInventory`, `Reconcile`, `CLI/Vault`, `Host`) is deleted — see
[legacy-tracking → Completed](legacy-tracking-for-deletion.md#completed). The unlock bundle stays
password-AEAD-sealed and Vault Transit is unchanged (the real security is untouched). Gates: `dev
check` 0, `test unit` 1058/1058 (derivation tests removed, +1 static-field test), docs check 0.
🧪 Live-proof pending: a wipe-and-rebuild confirming MinIO on the static cred + the bundle round-trip
+ no `InvalidAccessKeyId`. The 2026-06-21 derivation entries below are the prior point-in-time record.

**2026-06-22 — Sprint `1.42` follow-up ✅: in-force SSoT seed now materialises on first bring-up
(`NoSuchBucket`-as-absent fix).** Live-running the Sprint `7.19` migration surfaced that the in-force
config SSoT seed never created the `prodbox-state` bucket: `Prodbox.Minio.ObjectStore.getObject`
classified `NoSuchBucket` (the bucket doesn't exist yet on first-ever bring-up) as a hard observe
failure, so the seed's presence probe aborted the seal and the bucket was never created — the cluster
fell back to the filesystem seed *forever*. (Sprint `7.19` exposed it: with the MinIO root credential
now valid, the probe reached `NoSuchBucket` instead of `InvalidAccessKeyId`.) Fix: `getObject` now
treats `NoSuchBucket` as definitive object-absence (`Right Nothing`) — distinct from a
credential/connection failure, which stays `Left` (failure to observe is not absence) — so the probe
reads "absent → seed" and the write creates the bucket. **Live-proven**: a fresh reconcile logged
"Seeded the in-force config SSoT in MinIO from the filesystem operator config." and materialised both
the `prodbox-state` bucket and the opaque Vault-Transit envelope `prodbox-state/objects/<hmac>.enc`.
Gates: `dev check` 0, +1 regression unit test (`NoSuchBucket`=absent vs `InvalidAccessKeyId`=not), full
`test unit` 1069/1069. The separate `bootstrap/vault-unlock-bundle.v1` `InvalidAccessKeyId` fallback
remains the deferred Sprint `7.19` disk-free-cutover axis (out of scope here).

**2026-06-21 — Sprint `7.19` MinIO-root-decouple ✅: deterministic, password-derived MinIO root
credential (fixes the cluster-rebuild mismatch).** `secret/minio/root.rootPassword` was a *random*
Vault secret that had to coincidentally match a retained MinIO data PV across rebuilds — a
fresh/re-initialized Vault paired with a retained MinIO disk presented a different password and MinIO
crash-looped (this blocked the live `test all`). It is now **deterministically derived** from the
operator password + per-cluster salt (`Prodbox.Vault.BootstrapBundle.deriveMinioRootPassword`, a
sibling Argon2id derivation to the bootstrap read credential), so the value is identical on every init
and a retained disk always matches Vault. `CLI/Vault.runVaultReconcileCommandDetailed` derives it
host-side (`obtainOperatorPassword` + `resolveBootstrapClusterId`) and supplies it into the root
reconcile through a new `VaultReconcilePlan` `vaultReconcileSuppliedSecretValues` override
(derive-on-absent; present values are never rewritten, so no churn; graceful random fallback if the
password is unavailable). Scope is root-only and the MinIO root password specifically — the gateway
MinIO user stays random (idempotently re-added). This also lands Sprint `7.19`'s "MinIO-root-decouple"
half; only the disk-free unseal cutover remains on the live-proof axis. Per the verified posture, the
root password is **access** (no MinIO SSE/KMS; prodbox objects are app-layer Vault-Transit envelopes),
so the prior mismatch was an access/startup failure, not data loss. Gates: `dev check` 0, +7 unit tests
(derivation determinism/charset/fail-closed + supplied-override write + idempotency), full `test unit`
1068/1068. 🧪 Live-proof pending (non-blocking): a `cluster delete --cascade` + reconcile, then a
Vault-wipe-only rebuild, both bringing MinIO up clean. See
[phase-7 Sprint `7.19`](phase-7-aws-substrate-foundations.md) +
[legacy-tracking → Completed](legacy-tracking-for-deletion.md#completed).

**2026-06-20 — Sprint `1.47` ✅: Harbor-login isolation moved to hostbootstrap's ephemeral
`DOCKER_CONFIG` pattern.** The Sprint `1.46` *persistent* `<repoRoot>/.docker` dir + `docker login`
is replaced by `HostBootstrap.Registry`'s **ephemeral** model (`Prodbox.DockerConfig` rewritten):
`withEphemeralDockerConfig` discovers the host `docker.io` auth read-only, projects a minimal
`docker.io`-only config (`dockerHubAuthFromConfig`), and writes a throwaway
`withSystemTempDirectory "prodbox-docker-config"` `DOCKER_CONFIG` (that auth + an inline Harbor
`127.0.0.1:30080` entry, `base64 admin:Harbor12345`) `bracket`-scrubbed on exit — so **no
`docker login` runs anywhere**. `mirrorClusterImagesOnce`, `ensureCustomImageVariantsHomeLocal`, and
the AWS host build wrap their docker calls in it; `ensureHarborDockerLogin` + `harborLoginRetryPolicy`
are deleted; the home Harbor-project creation keeps its `curl -u` REST path (readiness on the
`waitForHarbor*` probes). Nothing persists in `~/prodbox`; `~/.docker` is only read. Gates: `dev
check` 0, six new `DockerConfig` unit tests (incl. exact base64), the CliSuite reconcile asserting no
`docker login` + an ephemeral `prodbox-docker-config` `DOCKER_CONFIG`, full `test unit` 1061/1061. The
1.46 mechanism is in [legacy-tracking → Completed](legacy-tracking-for-deletion.md#completed). This
also retires the in-cluster-crane-for-home idea (the home push stays a host `docker push` inside the
ephemeral config). The `docker.io` discovery/projection is the seam to swap onto
`HostBootstrap.Registry` at the planned hostbootstrap refactor. 🧪 Live-proof pending (non-blocking):
a home reconcile leaving `~/.docker` byte-unchanged with no `~/prodbox/.docker`.

**2026-06-20 — Sprint `1.46`: host `docker` CLI Harbor-login isolation.** Every prodbox `docker`
call now runs with a prodbox-local `DOCKER_CONFIG` (`<repoRoot>/.docker`, git-ignored, new
`Prodbox.DockerConfig` via `captureDockerToolOutput`): Harbor `docker login` lands inside `~/prodbox`
instead of the operator's global `~/.docker/config.json`, while public pulls keep the operator's
fixed-token Docker Hub login (seeded read-only from `~/.docker`, Harbor entry + `credsStore`
dropped). prodbox **never writes** `~/.docker/config.json`, so it cannot disturb the operator's
Docker Hub state. In-cluster containerd pulls (credential-free) are unaffected. Gates: `dev check` 0,
five `DockerConfig` unit tests + the CliSuite `DOCKER_CONFIG`-isolation assertion, full `test unit`
1060/1060. 🧪 Live-proof pending: a home reconcile confirming `~/.docker` is byte-unchanged.

**2026-06-20 — Operator-directed: GHC 9.12.4 downgrade, basic-`docker` build, container-image
consolidation (Sprint `1.45`), and the preflight fail-closed-gate fix (Sprint `7.24`).** The whole
project moved to a single GHC `9.12.4` (build + code-checking); the image build uses basic
`docker build`/`docker push` on the daemon's default builder (no `docker buildx` — the orphaned
`prodbox-multiarch-hostnet` builder was swept — and no BuildKit-only Dockerfile features). **Sprint
`1.45`** consolidated the former `prodbox-gateway` + `prodbox-public-edge-workload` images into ONE
union runtime image `prodbox/prodbox-runtime` from a single `docker/prodbox.Dockerfile`; each chart
selects its role via the pod `args:` (`gateway start` vs `workload start`). Then the first live
`prodbox test all` surfaced the Sprint `7.14` live-proof gap: **Sprint `7.24`** — the AWS IAM-harness
preflight observed `operational-aws-config` by resolving its `SecretRef.Vault` from a Vault that is not
up yet at preflight, so the fail-closed gate aborted every clean-machine run;
`refineAwsConfigResidueAgainstIamUser` now downgrades that `Unreachable` aws-config to `Absent` only
when the operational IAM user is confirmed absent via the admin credential (Vault-independent),
preserving fail-closed in every other case. Gates: `dev check` 0, `test unit` green (incl. the
four-case refine truth-table + the union-image Dockerfile invariants), real `docker build` of the
union image 0. 🧪 The resumed live `test all` is the non-blocking live-proof axis.

**2026-06-20 — Phase 1 Sprints `1.43` + `1.44` closed on the code-owned surface (config/secrets-SSoT
surface complete).** **Sprint `1.43`** moved the harness's only durable secrets into a dedicated,
git-ignored `test-secrets.dhall` (`TestConfig`→`TestSecrets`; generated `test-secrets-types.dhall` via
`prodbox config schema`); because the fixture carried no non-secret toggles, the now-empty
`test-config.dhall` / `test-config-types.dhall` were removed outright (the sprint's "removed if empty"
branch), making `test-secrets.dhall` the sole durable-secret fixture file. **Sprint `1.44`** added the
gateway daemon's write-capable `POST /v1/secret/<logical>` endpoint (two-path allowlist:
`secret/acme/eab` + `secret/gateway/gateway/aws`), a dedicated `prodbox-operator-write` Vault
policy/role (distinct from the read-only `prodbox-gateway-daemon`), the host CLI
`Gateway.Client.writeOperatorSecret`, and the harness rewiring
(`writeOperatorSecretViaDaemonOrHost`, minting the operator JWT via `kubectl create token
prodbox-operator-write -n gateway`, with the host root-token fallback later narrowed by Sprint
`4.42` to the no-JWT/test-seam cases). The `vault_operator_password` and the ephemeral
`aws_admin_for_test_simulation`
credential stay host-side. Gates: `test unit` 1046/1046 (+9), `integration cli`/`env` pass. 🧪
Live-proof (non-blocking, Standard O): a live home run routing the EAB + operational `aws.*` through
the daemon NodePort under the `prodbox-operator-write` role (the matching Kubernetes ServiceAccount
must exist in `gateway` for the JWT mint; until then the harness falls back to the host write, but a
daemon failure after JWT mint is authoritative after Sprint `4.42`).
Both forward-only-blocked on the closed `1.42`/`1.43` (Standard N). The stale `📋 Planned` marker for
Phase 8 Sprint `8.9` in the Phase Overview is harmonized to `✅` (its code-owned surface was already
delivered by Sprint `3.18`; the both-substrate live invite is its non-blocking 🧪 axis).

**2026-06-19 — Phase 0 reconciled + Phase 1 Sprint `1.42` closed (config-SSoT surface); Sprints `1.43`/`1.44`
opened.** Working open development-plan work in numerical order: **Phase 0 Sprint `0.13`** flipped from a
stale `📋 Planned` marker to `✅ Done` (its deliverables — `VAULT_REFACTOR.md` deleted,
`cluster_federation_doctrine.md` present — had already landed; docs gate green). **Phase 1 Sprint `1.42`
Part B** landed: the standalone `prodbox-config.dhall` seed file is **RETIRED** — `Settings.loadConfigFile`
decodes `( prodbox.dhall ).parameters` (Dhall field-projection, no `Tier0`↔`Settings` cycle); the SSoT
payload decoder is split out as `decodeConfigFileAtPath` (internal temp basename only); `config setup` /
`aws setup` / `vault init` author into `prodbox.dhall` merge-preserving `context`/`witness`
(`Tier0.writeOperatorParametersToTier0` / `writeTier0FloorPreservingParameters`); ~35 test fixtures convert
to a Tier-0 `prodbox.dhall` via the new `TestSupport.wrapTier0`; all `src` user-facing messages repointed.
Per the operator's 2026-06-19 decision: `prodbox.dhall` is binary-generated + git-ignored; the establishment
signal is the unlock-bundle presence; a sealed/unreachable Vault on an established cluster has **no config
fallback** (the cluster runs, just can't read config). Gates: `dev check` 0, `test unit` 1037, plus
`integration cli`/`env`. 🧪 Live-proof (non-blocking): a from-scratch home bring-up reading config with no
`prodbox-config.dhall` present. The operator's expanded config/secrets target is scheduled as the new
**Sprints `1.43`** (split durable test secrets into `test-secrets.dhall`) and **`1.44`** (route the
Vault-written secrets — ACME EAB + minted operational `aws.*` — through a new gateway-daemon write endpoint
via simulated CLI→NodePort with a Vault-k8s JWT; the unlock password + ephemeral admin cred stay host-side),
both forward-only-blocked on the closed `1.42` (Standard N), `📋 Planned`.

**2026-06-19 — keycloak `test all` failure diagnosed (sub-agent, live cluster): THREE distinct faults, all
separate from the config-shape work; none is a cold-start race.** Investigating the keycloak CrashLoopBackOff
that blocks the home `test all` at `charts reconcile vscode` found three independent issues:
(1) **keycloak startup fault (persistent, not a race).** The keycloak container exits 1 in ~0s — *before* any
DB work — so the DB role, `keycloak` database, retained PVs, and Vault secrets (all confirmed ready/readable)
are NOT the cause. Most likely a Keycloak-26 `kc.sh start` bootstrap rejection: an unbuilt image (no
`kc.sh build` / `--optimized` step in `charts/keycloak`) or a rejected start flag
(`--hostname`/`--http-enabled`/`--proxy-headers` combo). Literal stderr not yet captured (needs a controlled
keycloak deploy; the pod rolled back with helm so `--previous` is gone). Phase 8 / chart territory.
(2) **Harness bug — `ChartPlatform.deployChartPlan` duplicates guard (`ChartPlatform.hs:588-595`).** It
short-circuits the ENTIRE chart-root plan (returns RC=0, deploys nothing) when *any* release in the plan
already exists in `helm list`. So a rolled-back `keycloak` (siblings `keycloak-postgres`/`vscode` still
installed) can never be re-deployed by `charts reconcile vscode` — it no-ops. The fix is to deploy the
releases MISSING from `helm list` rather than skip the whole plan when any sibling exists. This is why a warm
`charts reconcile vscode` re-deploy printed `NAME=keycloak` but ran no helm deploy.
(3) **Gateway CrashLoopBackOff (separate, pre-existing).** 2/3 `gateway` nodes crash on
`aws_creds.access_key_id resolved to an empty value` — the same empty-`aws.*`-on-home-substrate condition as
the Tier-1 unlock-bundle `InvalidAccessKeyId` warning (`aws.*` is only transiently populated during AWS-substrate
runs). gateway-node-c is healthy. Independent of keycloak and of the config-shape work.
**All three are downstream of the home cluster's degraded post-`test all` state and are independent of the
✅-Done three-tier config-shape work (aws-ses SMTP sync validated end-to-end).** Tracked as follow-ups; not
scheduled into sprints pending the operator decision on whether/which to pursue (the literal keycloak stderr
should be captured first to scope the chart fix).

**2026-06-18 — Home `test all` now clears the config-shape blockers (preflight per-run destroy + aws-ses
SMTP sync) and reaches a NEW, separate downstream fault: keycloak CrashLoopBackOff during `charts reconcile
vscode`.** With Sprints `7.22` + `7.23` landed, a full home `prodbox test all` progresses through preflight
(per-run destroys gated/skip), cluster + Vault reconcile, Phase 1.5 runbook, and **Phase 1.6 "restoring
supported runtime" — including the Keycloak SMTP sync from aws-ses, which now SUCCEEDS** (no `unexpected end
of JSON input`; keycloak's `vault-secrets` init container reads `secret/keycloak/smtp` exit 0). It then RC=1's
at the next Phase 1.6 step, `charts reconcile vscode`: `helm upgrade --install keycloak --wait` →
`context deadline exceeded` because the keycloak container CrashLoopBackOffs (exit 1 in ~0s, ×10), so the
deploy rolls back (`helm uninstall`) and Phase 2/2 (named validations) never starts. **Sub-agent-verified
this is NOT a config-shape / aws-ses / `7.22` regression:** the SMTP secret is written and readable; the
Postgres HA cluster (`prodbox-vscode-pg`) is healthy post-failure (3/3 Running, retained PVs Bound) — the
early `FailedScheduling`/`no available persistent volumes to bind` was a transient cold-start. The keycloak
crash cause is not in the log (only `kubectl describe`, no container stdout) and the pod was rolled back, so
`--previous` logs are unavailable; diagnosing it needs a targeted keycloak re-deploy with log capture. The
exit-1-in-~0s pattern points at a keycloak STARTUP fault (realm-import or DB-connect-on-start), Phase 8 /
chart-platform territory — a separate follow-up, not part of the three-tier config-shape work (which is now
✅ implemented and validated end-to-end through the SMTP sync). The recurring Tier-1 unlock-bundle
`InvalidAccessKeyId` warning (non-fatal, host-disk fallback) remains the separate Sprint `7.19` axis.

**2026-06-18 — Sprint `7.23` ✅ Done + `aws-ses` reconcile live-proven: five stacked bugs in the encrypted
Model-B reconcile path fixed; the path had never run end-to-end on pulumi v3.228.** Per the operator's
"destroy it all / prioritize the new config shape" steer, the `aws-ses` encrypted-backend reconcile was
repaired. Five stacked bugs (all fixed; full detail in [phase-7 Sprint `7.23`](phase-7-aws-substrate-foundations.md#sprint-723-aws-ses-encrypted-backend-reconcile-recovery-five-stacked-bugs)):
(1) `EncryptedBackend.fileBackendEnvironment` stripped `PULUMI_CONFIG_PASSPHRASE` → the only `encryptionsalt`
stack (`aws-ses`) died `passphrase must be set` → now sets `""`; (2) the hydrate load used an unusable
(blank / corrupt / `pulumi stack export`-format) Model-B object instead of falling back to legacy → split
into `loadHydratableCheckpoint` (falls back via `checkpointBytesUsable`, incl. export-format rejection) vs
the raw-classifying `loadEncryptedOrLegacyCheckpoint` the 7.21 observe gate needs; (3) `--secrets-provider
plaintext` is invalid on pulumi v3.228 → `passphrase`; (4) state-recovery's `aws` CLI probes / `pulumi
import` / SMTP-key rotation ran with the scratch env (AWS\_\* stripped) → imported nothing → create-conflicts
→ new `awsCliCredsFromProviderEnv` re-derives `AWS_*` from `PRODBOX_PULUMI_AWS_*`; (5) durable-S3 / stale-state
semantics resolved by the operator steer (stale S3 state + export-format Model-B object cleared; reconcile
re-imports live resources). **Live-proof:** `prodbox aws stack aws-ses reconcile` now imports the live
resources + idempotent-creates the rest; a second run reports **17 unchanged, RC=0** with a valid on-disk
Model-B checkpoint. Gate green: unit 1034/1034, `dev check` 0, integration cli/env 0. All temporary
diagnostics removed. The home `prodbox test all` end-to-end pass (SMTP-sync now reads the valid `aws-ses`
Model-B → Phase 1.6 clears) is the remaining non-blocking 🧪 axis (in flight at close). This supersedes the
immediately-following investigation entry.

**2026-06-18 — `aws-ses` repair investigation: the data is HEALTHY (in S3), the blocker is a multi-layer
backend-layering bug; layer 1 (scratch passphrase) FIXED, layers 2–3 are a backend-durability design
decision (Sprint `7.23`).** Acting on the operator's "repair the data" choice, an adversarially-verified
investigation + read-only AWS prechecks established that `aws-ses` is **not** corrupt or lost: its real
Pulumi state is in the **long-lived S3 backend** (`prodbox-pulumi-state-long-lived`, 110 KB, 2026-06-06),
the SES domain is verified (identity + DKIM), `prodbox-receive-rule-set` is active, the capture bucket +
SMTP user exist (1 access key). The empty object the runtime tripped on is the **encrypted Model-B MinIO**
working-copy (empty on a fresh-MinIO cluster), which the reads + reconcile go through. Three layers surfaced:
(1) ✅ **FIXED** — `EncryptedBackend.fileBackendEnvironment` *stripped* `PULUMI_CONFIG_PASSPHRASE`, so the
only stack with a committed `encryptionsalt` (`aws-ses`) died with `get stack secrets manager: passphrase
must be set`; it now sets `PULUMI_CONFIG_PASSPHRASE = ""` (unit test updated, `dev check` 0, `test unit`
1034/1034); (2) 📋 `loadEncryptedOrLegacyCheckpoint` treats a present-but-**empty** Model-B object as a
valid checkpoint instead of falling back to the legacy S3 export, hydrating an empty scratch →
`failed to load checkpoint: unexpected end of JSON input`; (3) 📋 the migrate path **deletes the legacy S3
state on success**, which would destroy the durable `aws-ses` copy ("lives in S3 independent of cluster
lifetime") — a backend-durability design decision (read-from-S3 directly vs. Model-B-working-copy-keeping-S3).
Layers 2–3 are **not auto-applied** because they change the `aws-ses` durability model and have data-safety
implications; recorded as **Sprint `7.23`**
([phase-7](phase-7-aws-substrate-foundations.md#sprint-723-aws-ses-encrypted-backend-reconcile-recovery-five-stacked-bugs)).
The read-only prechecks confirmed any reconcile's unimported `pulumi up` creates are idempotent (verified
domain/DKIM, active rule set, route53 upsert, ≤2 IAM keys), so the chosen fix can proceed safely once the
backend-model decision is made. The home validation suites still have not run end-to-end (blocked at Phase
1.6 pending layers 2–3).

**2026-06-18 — Home `test all` end-to-end (post-`7.22`): the preflight per-run destroy is FIXED; the run
now reaches Phase 1.6 and hits a NEW, separate blocker — an empty `aws-ses` checkpoint on the SMTP-sync
read (→ new Sprint `7.23`).** With Sprint `7.22` landed, a full home `prodbox test all` no longer dies at
the preflight per-run destroy — it proceeds through build → `dev check` → preflight (IAM setup + per-run
destroys, which now cleanly skip: `AWS EKS test stack: absent (no per-run checkpoint to destroy …)`) →
cluster + Vault reconcile (Vault rev 12, all mounts/policies present) → gateway/prodbox image builds → and
into **Phase 1.6 "restoring supported runtime"**. It then exits RC=1 at
`Supported runtime bootstrap: syncing Keycloak SMTP Secret from aws-ses`:
`pulumi stack output failed: error: failed to load checkpoint: unexpected end of JSON input`, **before any
named validation runs (Phase 2/2 never starts)**. Root cause (sub-agent-verified against the 1372-line
log): the long-lived `aws-ses` stack's encrypted Model-B checkpoint is **empty/zero-length**
(`classifyCheckpointBytes` → `CheckpointEmpty`), and the SMTP-sync read
(`AwsSesStack.syncKeycloakSmtpChartSecrets` → `pulumiStackOutputs`) treats any non-zero `pulumi stack
output` as a fatal `Left` — it has **no** Sprint `7.21`/`7.22` empty-checkpoint observation gate. This is
the *same* empty-checkpoint failure mode `7.21`/`7.22` hardened the per-run *destroy* against, on a
different *read* path; it is **NOT a `7.22` regression** (the same run proves `7.22`'s destroy gate works).
The preflight crash had masked this blocker on every prior home `test all` attempt. Tracked as new
**Sprint `7.23`** ([phase-7](phase-7-aws-substrate-foundations.md#sprint-723-aws-ses-encrypted-backend-reconcile-recovery-five-stacked-bugs)).
**Operator decision (open):** the immediate unblock is repairing the `aws-ses` checkpoint via
`prodbox aws stack aws-ses reconcile` (a heavy long-lived-SES op — left to the operator because reconciling
against an empty checkpoint risks create-conflicts with already-live SES resources), and/or hardening the
SMTP-sync read to classify empty/absent/corrupt deliberately (Sprint `7.23`). The recurring Tier-1
unlock-bundle `InvalidAccessKeyId` warning (falls back to host-disk, non-fatal) is a separate Sprint `7.19`
live-proof axis. This supersedes the immediately-following per-`7.22` entry only on the end-to-end question;
`7.22` itself remains ✅ Done + live-proven below.

**2026-06-18 — Sprint `7.22` ✅ Done + live-proven: the per-run destroy-invocation path is now gated,
closing Sprint `7.21`'s outstanding home-`test all` preflight/postflight proof.** Each
`destroy<Stack>Status` (`destroy{AwsEksTest,AwsTest,AwsEksSubzone}StackStatus`) now consults the Sprint
`7.21` read-only Model-B observation **first**, via the pure
`Prodbox.Lifecycle.LiveResidue.perRunDestroyDecisionFromStatus`: absent/empty → `PerRunDestroySkip`
(success, never touch `pulumi`/the `minio` k8s secret); present → `PerRunDestroyProceed` (the existing
destroy body); corrupt/unreadable → `PerRunDestroyRefuse` (clean, actionable refusal naming the prune
recovery — never a crashing `pulumi destroy`). The observation resolves MinIO creds from Vault
`secret/minio/root`, so the `secrets "minio" not found` failure mode is gone. A doctrine-clean recovery for
genuinely-corrupt checkpoints landed: `prodbox aws stack {eks,test,aws-subzone} prune-corrupt-checkpoint
--yes` (`LiveResidue.pruneCorruptPerRunCheckpoint` → `EncryptedBackend.pruneLogicalPulumiStack`), a **named
per-run leaf** (not a `--force` flag — prodbox forbids `--force` escape hatches) that deletes the opaque
Model-B object only when corrupt/empty, refuses a `Present` one or an unobservable backend, idempotent on
absent. **Refined root cause:** the home cluster had **no corrupt Model-B checkpoints** — its per-run
checkpoints were already absent (home never provisions per-run AWS stacks); the prior 3rd-attempt crash was
the *ungated* destroy diving into the legacy k8s-secret + `pulumi stack export` path *without first
observing* the Model-B residue. **Live-proof (home cluster, Vault unsealed):** the exact harness commands
`prodbox aws stack {aws-subzone,eks,test} destroy --yes` each now return RC=0 with `absent (no per-run
checkpoint to destroy …)` (the prior `unexpected end of JSON input` + `secrets "minio" not found`
hard-failure is gone); `prune-corrupt-checkpoint --yes` confirmed Model-B absent (idempotent) on all three.
Gate green: `dev check` 0, `test unit` 1034/1034 (+5 new), `integration cli`/`env` 0, CLI goldens
regenerated (3 per-run prune leaves, not aws-ses). SSoT: [lifecycle_reconciliation_doctrine.md §3.2](../documents/engineering/lifecycle_reconciliation_doctrine.md);
see [phase-7 Sprint `7.22`](phase-7-aws-substrate-foundations.md). The full home `prodbox test all`
end-to-end pass through the validation suites is the remaining non-blocking 🧪 axis (in flight at close).
This supersedes the immediately-following 3rd-attempt finding.

**2026-06-18 — Home `test all` (3rd attempt) still RC=1 at the preflight per-run destroy: leftover
corrupt per-run state + a Sprint `7.21` destroy-path gap (NOT the session's code).** With Sprints
`1.39`–`1.42`A / `5.9` / `7.21` landed + all gates green, a full home `prodbox test all` still fails in the
**preflight** per-run Pulumi destroy ("running 2 destroy(s) against MinIO" → `pulumi stack output failed:
... failed to load checkpoint: unexpected end of JSON input` + `secrets "minio" not found`), **before** the
validation suites run. Root cause: this hand-reconciled home cluster carries **2 leftover corrupt per-run
Pulumi checkpoints** (garbage from prior interrupted runs — the home substrate never provisions
`aws-eks`/`aws-eks-subzone`/`aws-test`) that `ResourceRegistry.reconcileAbsent` tries to destroy.
**Sprint `7.21`'s gap (visible only live):** 7.21 wired the observe-then-skip classifier into the residue
*funnel* (`Prodbox.Lifecycle.LiveResidue.queryOne`), but the preflight **destroy-invocation** path
(`reconcileAbsent` → `EksStack.destroyAwsEksTestStack` → `pulumi destroy` / `pulumi stack output` +
`Infra.MinioBackend.readMinioCredentials`) is **not** gated by it — so it still runs `pulumi destroy` on the
corrupt checkpoints, and it reads MinIO creds from the in-cluster `minio` **k8s secret** (absent on this
cluster) rather than the Vault `secret/minio/root` the observation path uses. So 7.21's code-owned classifier
is ✅ but its 🧪 home-`test all`-preflight live-proof is **NOT met**. **Follow-up Sprint `7.22`** (📋): gate
the per-run destroy-invocation path with the `classifyCheckpointBytes` observe-then-skip (corrupt/unreachable
→ clean refuse, never a crashing `pulumi destroy`) and unify the MinIO-creds source onto Vault. Separately,
the 2 leftover corrupt checkpoints are stale state the canonical `prodbox aws stack <stack> destroy --yes`
cannot clear (it trips on the same corrupt checkpoint), so removing them needs either the `7.22` robustness
fix or a direct removal of the corrupt objects. The home validation **suites never ran** (blocked in
preflight); all other session work remains code-validated (local gates + live `cluster reconcile` /
SSoT-seed).

**2026-06-18 — Sprint `1.42` Part A ✅ Done + live-validated: the in-force MinIO SSoT is now
established as the live config source.** The unwired `storeInForceConfigWith` (twin of the floor-write
gap) is wired via `seedInForceConfigFromFileWithToken` (the PUT-twin of the read path) into the
post-MinIO/post-Vault-unseal reconcile step (`loadPostMinioLifecycleSettings` / `seedInForceConfigStep`,
root + child arms), gated by `seedProposeDecision` (only `SeedInForce` writes; idempotent no-op otherwise),
best-effort (a seed failure WARNs + continues — the `inForceConfigObjectAbsent` filesystem fallback stays
intact). Live home `cluster reconcile` proved it: 1st run RC=0 "Seeded the in-force config SSoT in MinIO
from the filesystem operator config" with the fallback count at 0 (config read from the SSoT); 2nd run RC=0
with no re-seed (`UseInForceAsIs`) and no fallback — established + idempotent. Gate green (`dev check` 0,
`test unit` 0 incl. a seal→read round-trip + `seedProposeDecision` classification tests, `integration cli`/
`env` 0). **Part B (retire `prodbox-config.dhall`) remains 📋** — pending the operator authoring-surface
decision (edit `prodbox.dhall` Tier-0 and seed/propose from it, vs. `config setup` writing the SSoT with no
authored file); secret-safety already verified (only `SecretRef.Vault` pointers). See
[phase-1 Sprint `1.42`](phase-1-runtime-cli-aws-foundations.md).

**2026-06-18 — Config-topology end-state canonicalized: drop the JSON floor, all Dhall
generated/not-version-controlled, seed the in-force MinIO SSoT and retire the
`prodbox-config.dhall` seed.** A docs/plan pass records the full config-topology end-state intent,
with [config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model)
remaining the sole SSoT for the three-tier model (this entry references it, never duplicates it).
The end-state: **Tier 0** = the self-contained (no imports), GENERATED, NON-SECRET `prodbox.dhall`
that IS the sealed-Vault bootstrap floor — the binary decodes it and projects the basics via
`projectBasics`; there is **no separate JSON floor** (`prodbox-basics.json` and the legacy
`.data/prodbox/unencrypted-basics.json` are both eliminated). **Tier 1** = the password-AEAD unlock
bundle in the durable MinIO bucket (Sprint `7.19`). **Tier 2** = operational secrets as opaque
Vault-Transit MinIO objects. The **in-force config** is an encrypted MinIO SSoT object, SEEDED from
the operator config on first bring-up (Sprint `1.42` wires `storeInForceConfigWith` — the twin of
the floor-write gap), after which the cluster reads its config from the SSoT, not the filesystem
seed-fallback. **All Dhall is generated or locally-authored and NONE is version-controlled**:
`prodbox.dhall` (generated), the `*-types.dhall` schemas (generated), `docker/default-prodbox.dhall`
(generated at image-build time), `prodbox-config.dhall` (operator-authored seed, git-ignored),
`test-config.dhall` (test fixture, git-ignored) — net zero version-controlled `.dhall`. The new
sprints owning this work:

- **Sprint `1.41`** (Phase `1`, ✅ Done code-owned 2026-06-18 — live home `cluster reconcile` RC=0 reads the floor from `prodbox.dhall`, `prodbox-basics.json` gone, schemas materialized): Config-Topology Consolidation —
  drop the JSON floor (read the floor directly from the self-contained Tier-0 `prodbox.dhall` via
  `projectBasics`; drop `configBasicsDerivedPath` + the legacy unencrypted-basics.json fallback),
  make `docker/default-prodbox.dhall` generated at image-build time (git-ignored; drop its committed
  `TrackedGeneratedPath`), and keep the `*-types.dhall` schemas generated + git-ignored (one-time
  operator `git rm --cached`). Forward-only `Blocked by` the closed Sprints `1.39`/`1.40`.
- **Sprint `1.42`** (Phase `1`, **Part A ✅ Done + live-validated 2026-06-18** / **Part B 📋 Planned**):
  Seed the In-Force MinIO SSoT + Retire the
  `prodbox-config.dhall` Seed — Part A wired `storeInForceConfigWith` so first bring-up envelopes the
  operator config into the encrypted MinIO SSoT and the cluster reads config from the SSoT rather
  than the Sprint `1.39` `inForceConfigObjectAbsent` seed-fallback (live home reconcile: seeded then
  idempotent read-from-SSoT, fallback count 0). Part B THEN retires the
  `prodbox-config.dhall` seed/propose input. Forward-only `Blocked by` the closed Sprints
  `1.38`/`1.39` and the same-phase `1.41`. **`prodbox-config.dhall` retirement plan**: SECRET-SAFETY
  VERIFIED — it carries no plaintext secrets, only `SecretRef.Vault` pointers (`aws.*` →
  `secret/gateway/gateway/aws`; `acme.eab_*` → `secret/acme/eab`), and the test secrets already live
  in `test-config.dhall`. It is NOT yet redundant (the operator non-secret config currently lives
  ONLY in it — `prodbox.dhall` has empty defaults and the SSoT is not yet seeded), so its deletion is
  GATED on Sprint `1.42` establishing the config in its replacement home.
- **Sprint `7.21`** (Phase `7`, ✅ Done code-owned 2026-06-18 — `classifyCheckpointBytes` + `LiveResidue` mapping; absent/empty→skip, corrupt/unreadable→fail-closed refuse; 1025 unit tests; 🧪 home-`test all`-preflight live-proof pending): Per-Run Pulumi-Destroy Robustness — gracefully handle a
  corrupt/empty per-run checkpoint ("unexpected end of JSON input") and an absent in-cluster `minio`
  secret, treating genuinely-absent per-run state as nothing-to-destroy per
  [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  ("cannot observe" is never silently treated as "absent"), rather than hard-failing the suite.
  Surfaced by the home `test all` after the Sprint `1.39` floor fix advanced past the basics-floor
  gap. Forward-only `Blocked by` Sprint `7.14` and the `4.20`–`4.22`/`7.8` managed-resource registry.
- **Sprint `5.9`** (Phase `5`, ✅ Done 2026-06-18 — suite now 11/11; `renderConfig` repaired to the
  current `SecretRef`-union `DaemonConfigDhall` shape; no assertion weakened; main gate unaffected):
  Repair the daemon-lifecycle Suite Fixture (SecretRef
  Schema Drift) — the standalone `prodbox-daemon-lifecycle` cabal suite was 8/11 red because
  `test/daemon-lifecycle/Main.hs::renderConfig` emits the pre-Vault-root plaintext
  `event_keys`/`aws_creds`/`minio_creds` shape instead of the current `DaemonConfigDhall` SecretRef
  union (drift predating the Vault-root migration; not in the `prodbox test` frontend gate).
  Forward-only `Blocked by` the landed SecretRef migration (Sprint `1.35`).

**2026-06-18 — Home `test all`: floor fix confirmed (original gap GONE); a SEPARATE pre-existing per-run
Pulumi-state gap now surfaces.** A full home `prodbox test all` run confirmed the basics-floor fix end-to-end:
**zero** `"Missing unencrypted basics file"` occurrences (was the earlier `test all` failure). The run now
advances past the floor gap and fails in the **preflight** per-run Pulumi destroy (before the validation
suites) with `"failed to load checkpoint: unexpected end of JSON input"` + `"secrets minio not found"` — the
per-run destroy cannot read 2 pre-existing, corrupt/empty per-run AWS-stack checkpoints in MinIO (accumulated
from prior interrupted runs on this hand-reconciled cluster), and the `minio` k8s secret it falls back to is
absent. This is a **separate, pre-existing per-run-Pulumi-state-backend robustness gap** (lifecycle-reconciliation
domain, Sprints `4.20`–`4.22`/`7.8`), NOT the config-tier work — none of 1.39/1.40/7.19/7.20 touches the
checkpoint or `minio`-secret code; the floor fix merely advanced past the floor layer to expose the next one.
The home `cluster reconcile` (RC=0 above) already validates the config-tier code-owned surface live; the
per-run-state gap is the next, distinct thing to resolve (clean the corrupt per-run checkpoints via the
canonical `prodbox aws stack <stack> destroy --yes` path, or harden the per-run destroy to handle a
corrupt/absent checkpoint) before a clean home `test all`.

**2026-06-18 — Live home `cluster reconcile` RC=0 with the full 1.39/1.40/7.19 surface (🧪 home axes proven).**
A live home reconcile validated the hardened changes end-to-end: (1) the Tier-0 basics floor self-healed —
`"Reconstructed the missing Tier-0 sealed-Vault basics floor (prodbox-basics.json) for cluster prodbox-home"`,
file present with correct non-secret content; (2) the **first** reconcile after the floor self-heal exposed a
regression — writing the floor flipped `loadConfigForSettingsWith` to in-force mode, but this cluster's
in-force SSoT object was never seeded into MinIO (the `storeInForceConfigWith` twin of the
`writeUnencryptedBasics` gap), so the fetch hard-failed (RC=1); **fixed** by making
`loadConfigForSettingsWith` fall back to the filesystem seed when (and only when) the in-force object is
**absent** (`inForceConfigObjectAbsent` predicate — sealed-Vault / unreachable-MinIO / decrypt errors stay
fail-closed); (3) the 7.19 dual-write fail-safe behaved correctly live — the bootstrap MinIO read failed
(`InvalidAccessKeyId`: bundle/user not in MinIO on an already-init'd cluster) and **fell back to the host-disk
bundle with a loud warning**, RC stayed 0. Re-run: **`cluster reconcile` RC=0**. Gate green (`dev check` 0,
`test unit` 0 — +3 tolerance tests, `integration cli`/`env` 0). Known cosmetic follow-up: the bootstrap-MinIO
read-fail warning repeats per-reconcile on already-init'd clusters (bundle never written to MinIO); and the
proper in-force-SSoT seed (`storeInForceConfigWith`) remains an open follow-on (FIX B) so the cluster
eventually reads its config from the encrypted MinIO SSoT rather than the filesystem seed.

**2026-06-18 — Adversarial pre-live review + live-readiness hardening (Sprints `1.39`/`7.19`/`7.20`).**
Before running the live 🧪 proofs, a multi-agent adversarial review of the landed code caught a CONFIRMED
critical regression: the Tier-0 basics floor (`prodbox-basics.json`) was written only by `initFreshVault`,
so on a rebuild against a durable Vault PV (init runs once-ever; only unseal happens) the floor was never
written — `loadUnencryptedBasics` would fail and the per-run Pulumi destroy would break, **exactly the gap
that failed the earlier home `test all`** and the original `writeUnencryptedBasics`-has-no-callers defect.
Fixed: `ensureBasicsFloor` / `ensureChildBasicsFloor` (`Config/Tier0.hs`) self-heal the floor idempotently
on every `cluster reconcile` (wired into `ensureRootVaultLifecycleDetailed` + the child lifecycle, after
init/unseal), reconstructing from `prodbox.dhall` or the root default. Also hardened: `vault init` fails
loud if the floor write fails (no silent bricked state); the bootstrap-bundle unseal no longer silently
masks a corrupt MinIO object or a credential-derivation failure (fail-loud classifier + read-back verified
by decrypt); the 7.20 teardown-guard IAM probes retry genuine transient AWS errors (the adversarially-refuted
eventual-consistency wait was NOT added). Gate green (`dev check` 0, `test unit` 0 — **1006**,
`integration cli`/`env` 0). This closes the long-standing basics-write gap and makes 1.39/7.19's code-owned
surface genuinely live-ready ahead of the live proofs.

**2026-06-18 — Phase `7` code work landed: Sprint `7.20` ✅ Done, Sprint `7.19` staged ✅ (relocation
reorder 🧪) — open-work pass code-complete.** Continuing the numerical-order open-work pass after Phase `1`:
**Sprint `7.19`** (Tier 1 unlock-bundle → MinIO) landed its conservative **additive** stage —
`Prodbox.Vault.BootstrapBundle` (fixed key `bootstrap/vault-unlock-bundle.v1`; password-derived bootstrap
MinIO credential via `deriveBootstrapMinioCredential` with a distinct KDF context + per-cluster salt);
`initFreshVault` dual-writes the password-AEAD bundle to MinIO alongside the unchanged host-disk write
(best-effort + read-back-verified, swallowed on failure so it never bricks init — disk stays PRIMARY); and
`loadAndDecryptBundle` prefers the MinIO object then falls back to `loadAndDecryptDiskBundle`. The
**MinIO-root-decouple** half then landed ✅ (2026-06-21): the MinIO root password is now password-derived
(`deriveMinioRootPassword`), supplied into the root reconcile via `vaultReconcileSuppliedSecretValues`,
fixing the retained-PV cluster-rebuild mismatch (+7 unit tests, `dev check` 0, `test unit` 1068/1068). Only
the disk-free unseal cutover (MinIO-before-unseal reorder, marked `-- Sprint 7.19 (live-proof)`) remains the
🧪 axis. **Sprint `7.20`** ✅ Done: the IAM mint-to-Vault + delete-from-AWS-and-Vault lifecycle (already
shipped) was canonicalized as doctrine (earlier docs pass) and gained a teardown-completeness guard
(`residueFromProbe` pure classifier + `assertOperationalTeardownComplete` wired into
`runAwsIamHarnessTeardown`, reusing the existing IAM/Vault probes, fail-closed on "cannot observe"). Gate
green across all changes: `dev check` 0, `test unit` 0 (995), `test integration cli`/`env` 0 (39/39),
`dev docs check` / `dev lint docs` 0. **All locally-implementable open DEVELOPMENT_PLAN code work is now
done** (Phase `1`: `1.39`/`1.40`; Phase `7` code: `7.19`-staged / `7.20`). The remaining open items are
purely **🧪 Live-proof axes**, all non-blocking per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)
and operator-driven: the live `prodbox test all --substrate aws` canonical-suite run (`7.5`/`7.5.c`), the
MinIO-root-decouple/reorder + live unseal-from-MinIO (`7.19`), and the live exercise of the teardown guard
(`7.20`).

**2026-06-18 — Sprint `1.40` ✅ Done (code-owned surface); 🧪 Live-proof pending — Phase `1` open work
closed.** The in-cluster Tier-0 binary context landed: `Prodbox.Config.Tier0` gained the `Daemon`-frame
context (`defaultDaemonProjectConfig`; `loadDaemonBinaryContext` = ConfigMap-`prodbox.dhall` overwrite →
baked-in container default at `/etc/prodbox/prodbox.dhall` → compiled fallback); `docker/default-prodbox.dhall`
is the drift-guarded `TrackedGeneratedPath` render of the Haskell default, `COPY`-ed into the single
union runtime `prodbox.Dockerfile`; `runGatewayDaemon` logs the resolved context + provenance
(additive — the operational `DaemonConfig` runtime is untouched; a decode failure is a warning, never fatal).
**Deferred (pragmatic):** the full `DaemonConfigDhall`↔Tier-0 unification (high-risk boot/live/SecretRef merge)
is a follow-on; the Tier-0 path is added alongside without destabilizing the daemon. Gate green: `dev check` 0,
`test unit` 0 (979, +7 Sprint 1.40 tests), `test integration cli`/`env` 0 (39/39), `dev docs check` /
`dev lint docs` 0. **Pre-existing (not this sprint):** the standalone `prodbox-daemon-lifecycle` cabal suite is
8/11 red on a stale `SecretRef`-shape fixture (`test/daemon-lifecycle/Main.hs::renderConfig`, drift predating the
Vault-root migration; reproduced on pristine HEAD) — not in the `prodbox test` frontend gate; queued as a
fixture-repair follow-up. With Sprints `1.39`+`1.40` done, Phase `1`'s reopened config-SSoT surface is
code-complete; next is **Phase `7`** (Sprints `7.19`/`7.20`, then the `7.5`/`7.5.c` live-AWS axis).

**2026-06-17 — Sprint `1.39` ✅ Done (code-owned surface); 🧪 Live-proof pending.** The Tier-0
binary-context config landed and validated. `Prodbox.Config.Tier0` defines `ProdboxProjectConfig
{ parameters, context, witness }` (hostbootstrap `BinaryContext`-aligned: `context_kind`, `cluster_id`,
`vault_address`, MinIO coordinates, `topology { seal_mode, parent_ref }`, `capabilities` incl.
`DurableStore`; `parameters` carries the non-secret sections with `aws.*` / `acme.eab_*` as
`SecretRef.Vault` pointers only). `renderProjectConfigDhall` renders `prodbox.dhall` from the Haskell
record (one typed SoT; `decode . encode == id`), `projectBasics`/`projectBasicsJson` derive the
dependency-free `prodbox-basics.json` floor, `tier0CarriesNoSecretValues` is the secret-free guard, and
`writeTier0` is wired into `initFreshVault`. `loadUnencryptedBasics` / `loadConfigForSettingsWith`
resolve the floor via `resolveBasicsFloorPath` (prefer `prodbox-basics.json`, fall back to the legacy
`.data/prodbox/unencrypted-basics.json`). Gate green: `dev check` 0, `test unit` 0 (972, +6 Tier-0
tests), `test integration cli` 0 (39), `test integration env` 0 (39). The live `vault init` floor-write
+ read-on-rebuild proof is the 🧪 Live-proof-pending axis. Sprint `1.40` (in-cluster container default +
ConfigMap overwrite) is next.

**2026-06-17 — Three-tier config separation: Phase `1` reopened (Sprints `1.39`/`1.40` ✅-code) and
Phase `7` reopened (Sprint `7.19` 🔄 staged-code / Sprint `7.20` ✅).** A docs-only doctrine pass
canonicalizes the three-tier config model — **Tier 0** non-secret binary-context `prodbox.dhall`
(shaped to align with hostbootstrap's binary-context contract), **Tier 1** the password-gated Vault
unlock material relocated to the durable MinIO bucket, and **Tier 2** the Vault-Transit operational
secrets — with
[config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model) as the
single canonical home and every other doc referencing it. The doctrine bodies changed this pass:
[config_doctrine.md](../documents/engineering/config_doctrine.md) §0 (new, with the balance
principle) / §1a / §3 / §6 / §10, and
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) §5 / §6 / §6.1 / §9 (the unlock
bundle is now a MinIO-resident password-AEAD object read via the static bootstrap MinIO root
credential, not a host-disk `.age` file; the intermediate password-derived credential stage was
superseded on 2026-06-22). The plan-side reopenings:

- **Phase `1` reopened** to expand its own config-SSoT surface with two 📋 Planned sprints in
  [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md): Sprint `1.39`
  (Tier 0: binary-owned `prodbox.dhall` in hostbootstrap binary-context shape, folding
  `.data/prodbox/unencrypted-basics.json` + the non-secret sections of `prodbox-config.dhall`, with a
  derived dependency-free `prodbox-basics.json` bootstrap floor) and Sprint `1.40` (Tier 0
  in-cluster: container default `prodbox.dhall` overwritten by the cluster daemon from the existing
  `gateway-config-<nodeId>` ConfigMap). Forward-only `Blocked by`: both build on the closed Sprint
  `1.38`, and `1.40` also on same-phase `1.39` ([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)).
- **Phase `7` reopened** to expand its own owned surface with two sprints in
  [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md): Sprint `7.19`
  (Tier 1: relocate the Vault unlock bundle to the durable MinIO bucket as a password-AEAD object —
  Argon2id + ChaCha20-Poly1305 — read via the static bootstrap MinIO root credential; child clusters
  keep transit-seal) — 📋 Planned with
  a non-blocking 🧪 Live-proof pending (live home reconcile/unseal/rebuild reads the bundle from MinIO
  with the operator password); forward-only `Blocked by` Sprint `7.14`. Sprint `7.20`
  (Test-Harness IAM Credential Lifecycle Doctrine + Teardown-Completeness Guard) is ✅ Done on its
  code-owned surface — the mint-to-Vault + delete-from-AWS-and-clear-Vault IAM lifecycle is already
  implemented — and 📋 Planned for the new deliverable: canonicalizing that lifecycle as doctrine
  ([aws_admin_credentials.md §4.2](../documents/engineering/aws_admin_credentials.md);
  [aws_integration_environment_doctrine.md §4.4](../documents/engineering/aws_integration_environment_doctrine.md))
  plus a teardown-completeness guard. Nuance recorded: the Vault clear is currently an empty-value
  write, not a true KV delete (an optional future refinement, not a hard-delete claim).

This is a docs/plan correction; the Tier 0 / Tier 1 code moves are scheduled, not made now. The plan
suite (this file, `00-overview.md`, `system-components.md`, the reopened phase files, the governed
engineering docs, and the legacy ledger) stays in harmony under the same change. Gates: `dev docs
check` 0, `dev lint docs` 0.

**2026-06-17 — Sprint `7.18` ✅ Done; 🧪 Live-proof: passed — home public-edge ACME issuer Ready
with the real ZeroSSL EAB.** `prodbox edge reconcile` brought `zerossl-dns01` to
`Ready=True (ACMEAccountRegistered)` (`status.acme.uri = https://acme.zerossl.com/v2/DV90/account/…`)
non-interactively, closing the EAB half of the home public-edge `Live-proof: pending` axis. Two
stacked defects found + fixed live: (1) nothing seeded `secret/acme/eab` from the test fixture before
the in-cluster materializer read it — fixed by `seedAcmeEabFromTestConfig` (in `Prodbox.Vault.Host`),
invoked in `ensureAcmeRuntime` immediately before the ACME-runtime manifest applies (a no-op without
`test-config.dhall`, so real operators still seed via the interactive prompt); (2) the materializer's
vault-image init container wrote the HMAC handoff file `0600` (own UID), unreadable by the
different-UID curl sibling container, silently materializing an **empty** `acme-eab-credentials`
Secret — fixed by `chmod 0644` on the pod-scoped in-memory handoff file plus a fail-loud empty-HMAC
guard. Verified live: Vault `secret/acme/eab#hmac_key` = the real 86-char key, materialized Secret
non-empty, issuer registered. `dev check` / `test unit` (966) / `test integration cli`+`env` all
green. See [phase-7 Sprint `7.18`](phase-7-aws-substrate-foundations.md).

**2026-06-17 — Live home-substrate platform reconcile validated.** `prodbox cluster reconcile` ran
green from a fresh host (no prior RKE2 / Vault / `.data/`): RKE2 installed and active; **Vault
initialized once and unsealed non-interactively from `test-config.dhall`'s `vault_operator_password`**
(proving the init-once / unseal-from-fixture path live); MinIO, Harbor, MetalLB, Envoy Gateway,
cert-manager, and the Percona PostgreSQL operator deployed; and the gateway daemon correctly
**skipped with its documented fail-safe** because operational `aws.*` is absent from Vault on a bare
local reconcile. `cluster status`: `RKE2_SERVICE=active`, `Vault: initialized=True, sealed=False`.
The pre-7.16/7.17 local `prodbox-config.dhall` was migrated to the new schema (no plaintext; the
admin block moved to a git-ignored `test-config.dhall`; `aws.*` / `acme.eab_*` as `SecretRef.Vault`
references) and `config validate` passes. This closes the home-substrate platform
`Live-proof: pending` axis (local lifecycle + Vault deploy/init/unseal + platform); the retained
`prodbox-admin-temp` admin credential is confirmed valid. **Update (Sprint `7.18`, same day):** the
ACME EAB is now seeded into Vault non-interactively from `test-config.dhall` by the harness, and the
home public-edge ACME issuer reaches Ready live (see the `7.18` entry above) — so the public-edge
proof no longer requires `prodbox config setup` run interactively. The operational IAM bootstrap is
minted into Vault by the harness (`aws setup` / suite preflight) from the simulated admin prompt.
What remains for the AWS-substrate Sprints `7.5` / `7.5.c` is live AWS spend plus the substrate
parity work — not a TTY gate on the home substrate.

**2026-06-16 — Sprint `0.15` ✅ Done: phase-independence doctrine adoption (docs-only).** The
development plan now decouples phase **validation** from forward **build** order so that an
incomplete later phase can never block, gate, or reopen an earlier phase. The doctrine SSoT is
[development_plan_standards.md](development_plan_standards.md) Standards
[N (Phase Independence)](development_plan_standards.md#n-phase-independence-no-backward-blocking)
and [O (Code-Local Completion vs. Live-Infra Proof)](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof),
plus the amendments to Standards A/C/H/M; every other governed doc defers to it. Four principles:
(1) **phase independence** — each phase is validatable on its owned surface even when any other phase
is incomplete, exercising any cross-phase dependency against the home/local substrate, a fake, or a
stub, with an **Independent Validation** line on every phase document; (2) **forward-only blocking** —
a `Blocked by` may name only an earlier-or-same-phase sprint or an external prerequisite, never a
later phase or higher-numbered sprint; (3) **code-local completion vs. live-infra proof** — a sprint
is `✅ Done` on its code-owned surface once it builds and passes local validation (this axis
determines phase closure), and any proof needing live infrastructure is a distinct, non-blocking
`🧪 Live-proof: pending` note, never `⏸️ Blocked`; (4) **substrate coverage is orthogonal** — a
suite-content sprint is `Done` when its validation passes on the home substrate, and AWS-substrate
coverage is tracked only in [substrates.md](substrates.md)'s parity table. Forward build order is
kept (later phases compose earlier deliverables) but is not a validation gate. This is a purely
structural change to the dependency model, status semantics, and where narrative lives — no
objective, feature, or validation changes. Under this doctrine the previously backward-blocked
entries are reframed: Sprint `5.8` is `✅ Done` on its home/code surface with a non-blocking
AWS-substrate live-proof (no longer "gated on Sprint `7.14`"); Sprint `7.14` is code-`Done` with a
non-blocking live-proof, not `⏸️ Blocked`. The doctrine shift and the relocated
"reopened-phase to attach a later-phase dependency" narrative are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) (Standards I/D). The plan suite
(this file, `00-overview.md`, `system-components.md`, the affected phase files, the governed
engineering docs, and the legacy ledger) stays in harmony (Standard J) under the same change.

**2026-06-17 — Sprint `7.16` ✅ Done (code-owned surface): test-simulation credentials moved to
`test-config.dhall`; admin acquisition unified on the prompt.** Landed and locally validated
(`dev check` 0, `test unit` 0, `test integration cli`/`env` 0): `aws_admin_for_test_simulation`
removed from `prodbox-config(-types).dhall` + the `ConfigFile` record; new committed
`test-config-types.dhall` schema and `src/Prodbox/Aws/AdminCredentials.hs`
(`acquireAdminAwsCredentials` — the single ephemeral admin seam: test-config.dhall → TTY prompt →
fail-loud); `Vault/Host.hs` `TestConfig`/`loadTestConfig`; every long-lived/`nuke`/harness consumer
re-pointed off the stored block; `config validate` rejects plaintext admin/operational AWS keys; no
leak-guard weakened. The live AWS exercise of the harness-simulated prompt path is a non-blocking
`Live-proof: pending` axis (Standard O). A correction to the test-credential model splits three
AWS credential roles cleanly and unifies how elevated/admin AWS power enters prodbox. (1) The
**ephemeral elevated/admin credential** a human operator holds enters only through the interactive
`SecretRef.Prompt` arm, is held in memory for one command to mint the dedicated least-privilege
`prodbox` IAM identity, and is then discarded — never written to `prodbox-config.dhall`, never
stored in Vault, never persisted to disk. (2) The **generated operational `prodbox` IAM credential**
(`aws.*`) is minted using role (1) and written straight into Vault KV (`secret/gateway/gateway/aws`)
the instant it exists; `prodbox-config.dhall` carries only its `SecretRef.Vault` reference, and
because it is minted into Vault the mint step happens **after Vault is set up and unsealed**.
(3) The **test-simulation admin credential** (`aws_admin_for_test_simulation.*`) is a
test-harness-only `TestPlaintext` fixture whose sole purpose is to feed the same interactive prompts
a real operator answers, so the suite-level IAM harness can exercise admin-credentialed flows
non-interactively; it lives only in `test-config.dhall`, is never imported by
`prodbox-config.dhall`, never read by a production binary, and never stored in Vault or copied into
generated cluster config or MinIO. There is exactly one runtime path by which elevated/admin power
enters prodbox — the interactive `SecretRef.Prompt` — for `config setup`, `aws setup`, the native
IAM harness, the long-lived `aws-ses` stack ops (reconcile/destroy/migrate-backend), and
`prodbox nuke`; the harness automates that prompt by feeding `aws_admin_for_test_simulation.*` from
`test-config.dhall`. There is no production config-backed admin path that reads stored admin
credentials from `prodbox-config.dhall`. Sequencing: bring up and unseal Vault → the operator at the
prompt (or the harness simulating it from `test-config.dhall`) supplies the ephemeral elevated
credential → prodbox mints the dedicated least-privilege `prodbox` IAM identity → writes the
generated `aws.*` credential into Vault KV → discards the prompted elevated credential. The
deliverables are owned by **Sprint `7.16`** in
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) (status 📋 Planned; its
dependency, Sprint `7.14`'s `SecretRef.Vault` treatment of `aws.*`, is already scheduled): remove
the `aws_admin_for_test_simulation` block from `prodbox-config.dhall` / `prodbox-config-types.dhall`;
introduce the test-harness-only `test-config.dhall` (`TestPlaintext`) consumed only by the
suite-level IAM harness; unify `aws-ses` reconcile/destroy/migrate-backend and `prodbox nuke` admin
acquisition on the interactive `SecretRef.Prompt`; mint the generated operational `aws.*` into Vault
KV only after unseal with `prodbox-config.dhall` carrying only the `SecretRef.Vault` reference; and
make `prodbox config validate` reject any plaintext admin/operational AWS key in
`prodbox-config.dhall`. None of the project's testing secrets live in Vault — Vault holds production
secrets only; test fixtures live in `test-config.dhall` and drive the test UI. The SSoT for the
SecretRef model, the config split, and the secret-classification statement is
[../documents/engineering/vault_doctrine.md §3/§4/§13](../documents/engineering/vault_doctrine.md);
the `aws_admin_for_test_simulation` block specifics are owned by
[../documents/engineering/aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md);
the per-stack credential-class assignment is owned by
[../documents/engineering/lifecycle_reconciliation_doctrine.md §2](../documents/engineering/lifecycle_reconciliation_doctrine.md).
The superseded `aws_admin_for_test_simulation` plaintext block in `prodbox-config.dhall`, the
config-backed admin path (`loadAdminAwsCredentials` / `pulumiSes*BaseEnv` reading a stored block),
and the `test-config.dhall` naming are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). This is a docs/plan correction;
the code moves (`.dhall` / `.hs`) are scheduled as Sprint `7.16`, not made now.

**2026-06-16 — Sprint `7.14` ✅ Done on its code-owned surface; 🧪 Live-proof: pending (first-touch migration + both-substrate opacity).**
The main Pulumi stack cycles now hydrate encrypted checkpoints into scratch `file://` backends and
re-store them as Model-B `LogicalPulumiStack <stack-id>` objects. The per-run stacks
(`aws-eks`, `aws-eks-subzone`, `aws-test`) and the main `aws-ses` reconcile/destroy/SMTP-sync paths
use `Prodbox.Pulumi.EncryptedBackend`; production residue/output reads use encrypted checkpoint
presence and scratch-backed `pulumi stack output`, not raw backend listings. The first-touch
migration path imports legacy raw MinIO / long-lived S3 checkpoints when the encrypted object is
absent and deletes the legacy stack only after the encrypted store/delete and Pulumi action succeed.
The `aws-ses migrate-backend` compatibility command now drives that same encrypted wrapper instead
of performing raw `pulumi stack export` / `pulumi stack import` between MinIO and S3.
Pulumi provider credentials now require the Vault KV object at `secret/gateway/gateway/aws`; the
raw config credential fallback is removed from `Prodbox.Infra.AwsProviderCredentials`. The local
cluster reconciler now resolves the Vault-backed `aws.*` gate before deploying the Route 53-writing
gateway daemon; a bare cluster with no `secret/gateway/gateway/aws` object skips that chart cleanly
instead of leaving crash-looping pods. Validation so far: `cabal build --builddir=.build
exe:prodbox`, Haskell lint no hints, focused Sprint `7.14` units 9/9, focused operational
AWS-credential gate units 2/2, focused Vault KV object units 3/3, Sprint `4.16`
residue/StackOutputs units 54/54, Sprint `4.10` long-lived-backend/admin units 12/12, full
`cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'` 950/950,
`./.build/prodbox test integration cli` 38/38, `./.build/prodbox test integration env` 38/38,
docs check/lint 0, `git diff --check` 0, `./.build/prodbox dev check` 0, and a live
`./.build/prodbox cluster reconcile` on the home substrate with Vault initialized/unsealed,
Harbor/MinIO/MetalLB/Envoy/cert-manager/Percona running, gateway skipped because operational
`aws.*` is not materialized, and no gateway CrashLoopBackOff residue.
**Independent Validation**: the decrypt-to-scratch interposition, encrypted residue/output reads,
first-touch import/delete hooks, Vault-only AWS provider credential resolution, and the
`SecretRef.Vault` migration are all validated on the code-owned surface and against the home/local
substrate (the live home `cluster reconcile` above), with no dependency on a later phase — the
sealed-Vault gate, scratch `file://` rewrite, and Vault-KV credential path are exercised on the home
substrate. The targeted AWS proof `./.build/prodbox test integration aws-eks --substrate aws` is the
live-infra axis: it currently stops in IAM-harness preflight because the live Vault does not yet
contain `secret/aws/admin-for-test-simulation`; no AWS stack reconcile or AWS resource provisioning
begins before that point.
The generated operational `aws.*` credential is now a mandatory `SecretRef.Vault` reference:
`prodbox aws setup` / `config setup` mint the dedicated least-privilege `prodbox` IAM identity using
the prompted ephemeral elevated credential and write its generated provider keys straight into
`secret/gateway/gateway/aws` after Vault is unsealed, and teardown clears that Vault object without
writing any provider secrets to `prodbox-config.dhall`. The ephemeral elevated/admin credential
enters only through the interactive `SecretRef.Prompt` arm (the test harness simulates that prompt
from `test-config.dhall`'s `aws_admin_for_test_simulation.*` fixture); it is never stored in
`prodbox-config.dhall`, Vault, or on disk. Sprint `7.16` moves the `aws_admin_for_test_simulation`
fixture out of `prodbox-config.dhall` into `test-config.dhall` and unifies admin acquisition on the
prompt. 🧪 **Live-proof: pending** — the live first-touch migration/deletion proof and the
both-substrate sealed-Vault opacity proof are a distinct, non-blocking live-infra axis (they need a
live `secret/aws/admin-for-test-simulation` Vault object and a deployed AWS substrate for the IAM
harness preflight); they do not gate the sprint's code-owned closure, and per
[Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) this is
**not** ⏸️ Blocked. Raw backend
environment is now confined to `LegacyPulumiBackend` first-touch import/delete; supported Pulumi
actions receive provider-only input before `fileBackendEnvironment` rewrites them to scratch
`file://`.

**2026-06-16 — Sprint `5.8` ✅ Done on its code-owned surface; 🧪 Live-proof: pending (AWS-substrate red-team).**
Phase 5 now has the code-owned canonical-suite entrypoint for sealed-Vault validation:
`IntegrationSealedVault` / `ValidationSealedVault`, the parser/docs surface
`prodbox test integration sealed-vault`, aggregate-suite ordering after `charts-storage` and before
`lifecycle`, and the pure `sealedVaultAuditReport` forbidden-pattern oracle for the cross-surface
zero-child-info red-team. The runtime validation body seals Vault when needed, asserts
`vault status` reports `sealed=True`, asserts `aws stack eks reconcile` is blocked by the
sealed-Vault gate before Pulumi work, audits the MinIO hostPath and Kubernetes ConfigMap/Secret
names, and restores Vault to unsealed when it started unsealed. Validation so far:
`cabal build --builddir=.build exe:prodbox`, `./.build/prodbox dev lint haskell --write` 0,
focused Sprint `5.8` units 2/2, `test planning` units 42/42, parser units 260/260, and accepted
CLI generated-output goldens for the new command; focused generated Dhall/config SecretRef sweep
1/1; full `cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'` 950/950,
`./.build/prodbox test integration cli` 38/38, docs check/lint 0, `git diff --check` 0, and
`./.build/prodbox dev check` 0. The live home-substrate proof now also passes:
`./.build/prodbox test integration sealed-vault` reconciles the local platform with the bare
`cluster reconcile` runbook, skips the gateway chart when operational `aws.*` is absent from Vault,
seals Vault, proves `aws stack eks reconcile` stops at the sealed-Vault gate before Pulumi starts,
emits `SEALED_VAULT_AUDIT=pass`, and restores Vault to `sealed=False`. **Independent Validation**:
Phase 5's sealed-Vault suite content is validated end-to-end on the home/local substrate (the live
home `sealed-vault` proof above) plus the pure forbidden-pattern oracle and full local gates, with
no dependency on a later phase — where a validation would touch an AWS-owned dependency it runs
against the home substrate. 🧪 **Live-proof: pending** — the AWS-substrate sealed-Vault red-team and
parent/child federation proof is a distinct, non-blocking live-infra proof; AWS-substrate coverage
of this same validation is tracked in [substrates.md](substrates.md)'s parity table and does not
gate the sprint's code-owned closure or Phase 5. It is **not** ⏸️ Blocked: it needs a live
`secret/aws/admin-for-test-simulation` Vault object and a deployed AWS substrate, neither of which
is an earlier-phase or external structural prerequisite.

**2026-06-16 — Sprint `4.33` ✅ Done: Haskell-side sealed-state residue/oracle/log scrub.**
The code-owned sealed-state scrub surface is closed. Residue queries and retained long-lived object
reads now consult the Vault readiness gate before classifying listings or `NoSuchKey`; when Vault is
sealed, uninitialized, or unreachable they return the uniform
`vault_status=... component=... result=unobservable` form rather than a stack name, object key,
object count, or present-vs-absent result. Token-bearing values also redact through `Show`:
`VaultToken`, `ChildInitCustody`, and `ChildBootstrapCredential` no longer expose root tokens, child
bootstrap tokens, or recovery keys through incidental debug rendering. The opaque namespace audit
remains clean: child namespace derivation is opaque, downstream inventory lives in parent Vault KV,
and the child-side Kubernetes Secret is the generic `vault/vault-transit-seal-token`. Validation:
`cabal build --builddir=.build exe:prodbox`, focused Sprint `4.33` units 4/4, `LiveResidue` units
19/19, `./.build/prodbox test unit` 928/928, `./.build/prodbox test integration cli` 38/38,
`./.build/prodbox dev docs check` 0, `./.build/prodbox dev lint docs` 0, `git diff --check` 0, and
`./.build/prodbox dev check` 0. Live cross-surface sealed-Vault red-team validation remains Sprint
    `5.8`; live first-touch raw Pulumi checkpoint migration proof remains Sprint `7.14`.

**2026-06-16 — Sprint `2.26` ✅ Done: gateway-mediated federation custody and child bootstrap.**
The cluster-federation custody surface is now closed on the gateway/CLI-owned path. Registration
records full downstream inventory — endpoints, kubeconfig reference, account id, and Pulumi stack
references — in parent Vault KV alongside metadata, bootstrap credential, and child-index objects.
The gateway daemon keeps its non-secret Vault Kubernetes-auth coordinates at runtime and exposes
`/v1/federation/children` plus `/v1/federation/children/<child>/bootstrap`, both backed by the
parent's unsealed Vault KV. The child list response omits the transit-seal token; the bootstrap
response returns it only through the Vault-backed path. Validation: `cabal build --builddir=.build
exe:prodbox`, cluster federation custody units 9/9, native gateway helper units 3/3, parser suite
258/258, built-frontend Sprint `2.26` integration 1/1, and the Sprint `4.32` registration
integration rerun 1/1; final closure gates also pass with `./.build/prodbox test unit` 924/924,
`./.build/prodbox test integration cli` 38/38, `./.build/prodbox dev docs check` 0,
`./.build/prodbox dev lint docs` 0, `git diff --check` 0, and `./.build/prodbox dev check` 0.
Opaque Kubernetes namespace/log redaction is now closed by Sprint `4.33`; the live two-cluster
sealed-Vault proof remains Sprint `5.8`.

**2026-06-16 — Sprint `4.32` ✅ Done: federated Vault lifecycle and direct child registration.**
The federation lifecycle now has a live parent registration path and a child reconcile interpreter.
`prodbox cluster federation register <child>` requires a ready parent root Vault plus
`--child-vault-address` and `--child-kubeconfig`, reads the Vault-owned federation HMAC key,
ensures the child Transit key and scoped policy, creates the child transit-seal token, records
metadata in parent KV, applies the child `vault/vault-transit-seal-token` Secret, and redacts the
token from output. `cluster reconcile` resolves root vs child lifecycle from unencrypted basics:
root clusters keep Shamir + unlock bundle; child clusters require a live unsealed parent and the
parent-provisioned transit-seal token Secret, render `seal "transit"`, initialize once with recovery
shares, write init custody to the parent KV, and reuse the parent-custodied child root token for
Vault reconcile plus the post-MinIO in-force-config read. Validation: `cabal build --builddir=.build
exe:prodbox`, focused federated lifecycle units 3/3, cluster federation custody units 8/8,
`./.build/prodbox test unit` 923/923, focused built-frontend Sprint `4.32` integration 1/1, and
`./.build/prodbox test integration cli` 37/37; canonical `./.build/prodbox dev check` exits 0. The
gateway-mediated child-listing/bootstrap surface is now closed by Sprint `2.26`; the Haskell-side
opaque namespace/log/redaction surface is now closed by Sprint `4.33`; the live two-cluster
sealed-Vault proof remains Sprint `5.8`.

**2026-06-16 — Sprint `4.31` ✅ Done: unified deterministic retained-storage topology.**
Retained PV identity now uses the shared `(namespace, statefulset, ordinal)` naming scheme:
`storageBinding` drops release/claim path identity, PV names derive through
`retainedStatefulSetPersistentVolumeName`, and host paths are
`.data/<namespace>/<StatefulSet>/<ordinal>`. `ensureRetainedLocalStorage` now walks a typed
always-on inventory for MinIO and Vault, creating/chowning `.data/prodbox/minio/0` and
`.data/vault/vault/0` and applying deterministic claimRef-bound PVs; Patroni and `vscode` use the
same binding helper through chart storage specs. MinIO and `vscode` are single-replica StatefulSets
with `data-<statefulset>-0` PVCs, and MinIO stays on the public `quay.io/minio/minio` image to avoid
the Harbor storage-backend deadlock. Validation: `cabal build --builddir=.build exe:prodbox`,
focused storage units 1/1 + VS Code plan unit 1/1, `./.build/prodbox test unit` 918/918,
`./.build/prodbox test integration cli` 36/36, and `./.build/prodbox dev lint haskell --write`
with no HLint hints; `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
`./.build/prodbox dev lint chart`, and `./.build/prodbox dev check` also pass.

**2026-06-16 — Phase `1` ✅ Reclosed: Sprints `1.35` and `1.38` complete on their
Phase-owned surfaces.** Sprint `1.35` is now scoped to the implemented FileSecret-free
`SecretRef` contract: Dhall decoder, production plaintext validator, and Vault KV resolver seam.
The runtime migrations that consume that contract stay in their later owning sprints (AWS provider
credentials in `7.14`, ACME EAB/TLS key material in `7.15`). Sprint `1.38` closes the in-force-config
source-of-truth inversion: `validateAndLoadSettings` now uses repo-root Dhall only as the
first-bring-up seed path when unencrypted basics are absent; once basics exist it loads basics,
recovers the ready Vault root token, reads MinIO root credentials from Vault, and fetches/decrypts
the in-force MinIO envelope. Validation: targeted Sprint `1.38` unit filter 31/31,
`./.build/prodbox test unit` 910/910, `./.build/prodbox test integration cli` 36/36,
`./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
`./.build/prodbox dev lint chart`, and `./.build/prodbox dev check`.

**2026-06-16 — Sprint `1.36` ✅ Done: `prodbox vault` lifecycle command group and
encrypted unlock bundle.** The root/local Vault lifecycle surface now runs through the native CLI
and Vault HTTP client end to end: status, init, idempotent re-init refusal, unseal from the
Argon2id/ChaCha20-Poly1305 encrypted unlock bundle, reconcile, unlock-bundle rotation, Transit-key
rotation, PKI status, PKI test issuance, and seal. The closing integration proof drives the built
`prodbox` executable against a Vault-compatible loopback server, uses `test-config.dhall` for the
test-only unlock password, verifies `.data/prodbox/vault-unlock-bundle.age` is created, and confirms
the final Vault state is initialized and sealed. Targeted validation: the `prodbox-integration`
filter for `Sprint 1.36` passed. Phase validation after closure: `./.build/prodbox test unit`
908/908, `./.build/prodbox test integration cli` 36/36, `./.build/prodbox dev docs check`,
`./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and `./.build/prodbox dev
check`.

**2026-06-16 — Sprint `1.37` ✅ Done: sealed-Vault gate and production Vault-Transit
`DekCipher`.** The production path now gates every real `prodbox aws stack ...` apply/destroy/migrate
action on Vault readiness before Pulumi starts, while dry-runs remain plan-only and do not probe
Vault. The `Prodbox.Vault.TransitCipher` binding delegates envelope DEK wrap/unwrap to Vault Transit
and fails closed when Vault is sealed or unreachable. The closing integration proof runs
`prodbox aws stack eks reconcile` against a Vault-compatible sealed `sys/seal-status` response and
asserts the command exits with the redacted sealed-Vault message and no Pulumi invocation record.
Targeted validation: the `prodbox-integration` filter for `Sprint 1.37` passed.

**2026-06-16 — Sprint `4.29` ✅ Done: Vault lifecycle integration and durable Vault PV
preservation.** `prodbox cluster reconcile` now folds the root/local Vault into the canonical
lifecycle before MinIO: it installs or rebinds the Vault chart, waits for `statefulset/vault`, runs
the init-once path only when needed, unseals from the host-side unlock bundle, and reconciles Vault
policy before secret-dependent work proceeds. `prodbox cluster status` and `prodbox edge status`
surface the Vault seal state as a first-class line, and `cluster delete` preserves the durable Vault
PV at `.data/vault/vault/0` alongside the MinIO retained state. Validation: `cabal build
--builddir=.build exe:prodbox`, refreshed `.build/prodbox`, `./.build/prodbox test unit` 908/908,
`./.build/prodbox test integration cli` 34/34, `./.build/prodbox dev docs check`,
`./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and `./.build/prodbox dev check`.
Sprint `1.37` has since closed, so Sprint `4.30` is the next planned Phase `4` sprint.

**2026-06-15 — Pulumi-under-Vault + MinIO encryption finalized to Model B (prodbox object-level
Vault-Transit envelope) + whole-system zero-child-info framing.** A security-architecture decision
settles how prodbox encrypts MinIO-stored state and Pulumi backend state under the finalized
Vault-root model around one invariant: **when the parent cluster's Vault is sealed, it is impossible
to extract any information about its children — whether it has any, how many, where, or what — down
to object/key names like `aws`/`aws-eks`.** This is an existence/metadata property, not a content
property: its leaks live in plaintext object keys/prefixes, counts, sizes, the host disk, k8s
objects, and logs, which bucket-level SSE and object-level content encryption alone do not fix. The
decision adopts **Model B** — prodbox's own application-level Vault-Transit envelope per object (the
half-built `Crypto.Envelope` + `Vault.Client` + `Config.InForce` layer), **not** MinIO bucket SSE —
because prodbox controls naming, index, and padding in the same trusted, Vault-native, AAD-bound
layer; **Pulumi's own secrets provider is dropped** (the prodbox envelope is the encryption); and the
property is treated as a **whole-system** one spanning MinIO objects, the host disk, k8s objects, and
logs/output, not a MinIO-only one. The finalized object-store: every prodbox-owned object is
enveloped via Vault Transit and named `objects/<vault-keyed-HMAC>.enc` under one flat prefix in
**one generically-named bucket** (retiring the role-revealing names `prodbox` and
`prodbox-test-pulumi-backends`), with a Vault-encrypted `indexes/*.enc` id↔logical map, a HASHED
stored AAD (`prodbox-envelope-v2` stores `base64(SHA256(aad))` plus the doctrine-§8
`transit_key`/`created_at`/`key_version` fields), and a **decoy-pad-to-constant-count** + size-bucket
discipline so a sealed-Vault listing carries no signal. The hostPath PV (`.data/prodbox/minio/0`)
therefore holds only opaque-named ciphertext. The **same object-store is shared by the host CLI and
the in-cluster gateway daemon** — one envelope/HMAC-naming/index layer, each accessor binding its own
Vault-auth `DekCipher` (the host CLI via the root Vault token, the daemon via Vault Kubernetes auth
over the in-cluster MinIO Service DNS). Pulumi runs through a **decrypt-to-scratch interposition**:
each op hydrates the stack into a RAM-tmpfs `file://` backend, runs `pulumi`, then re-envelopes and
opaque-names back to MinIO, so Pulumi never touches MinIO and the PV only ever holds opaque
ciphertext even mid-run. The long-lived `aws-ses` backend is treated **uniformly** under the same
Model B envelope — the AES256-SSE-only carve-out is dropped.

This **refines, it does not reverse**, the 2026-06-14 finalized Vault-root + cluster-federation
model, and it **reopens no new phase** — every affected phase (`0`, `1`, `4`, `5`, `7`) is already
reopened (Phases `0`/`1`/`4`/`5`/`7` on 2026-06-11, finalized 2026-06-14). It commits to Model B
explicitly, adds the Pulumi-interposition keystone, extends scope to disk/k8s/logs, and reframes the
already-scheduled MinIO-metadata and Pulumi-backend sprints. The per-sprint shape:

- **New Sprint `0.14`** (Phase `0`, docs-only — may close `Done` like Sprints `0.12`/`0.13`):
  Model-B Pulumi/MinIO and Whole-System Sealed-State Doctrine Harmony. Owns the
  `vault_doctrine.md §9/§10` Model-B rewrite (the opaque object-store spec, the decrypt-to-scratch
  Pulumi interposition, the uniform-envelope and one-generic-bucket consequences), the whole-system
  zero-child-info subsection, the §13/§14/§19 red-team additions, the config/federation/storage/
  streaming cross-links, the legacy-ledger repoint, and the plan-suite harmony. **This change closes
  it.**
- **Reframed Sprint `1.37`** (Phase `1`, 🔄) — drops "Vault-Derived Secrets Provider"; now owns the
  Vault-readiness gate (landed: `vaultGateOutcome` plus the `runPulumiCommandWithGate` apply-path
  wiring) **plus the production Vault-Transit `DekCipher`** (`Prodbox.Vault.TransitCipher`) — the
  shared dependency every envelope needs. The Pulumi-passphrase deliverable is removed (Pulumi's
  secrets provider is dropped).
- **Reframed Sprint `4.30`** (Phase `4`, ✅ closed 2026-06-16) "MinIO Metadata Hardening" → the
  **Model B object-store**: `Prodbox.Minio.ObjectStore` + `Prodbox.Minio.EncryptedObject` (HMAC
  opaque IDs, `prodbox-envelope-v2` hashed AAD, encrypted index payload shape,
  decoy-pad-to-constant-count key pool), the collapse to the `prodbox-state` generic bucket, the
  in-force-config read through the opaque object key, and removal of the pre-Model-B
  `active-config/in-force-config.prodbox-envelope-v1` backend helpers. Sprint `7.14` has landed the
  decrypt-to-scratch wrapper/read path and first-touch raw checkpoint migration hook; whole-system
  live red-team validation remains Sprint `5.8`.
- **New Sprint `4.33`** (Phase `4`, ✅ closed 2026-06-16) "Whole-System Sealed-State Scrub:
  On-Disk, Kubernetes, and Log Surfaces." Owns residue-query gating behind the Vault-readiness check
  (closing the exists-vs-`NoSuchKey`/`stackPresentInList` oracle on the Haskell-side residue
  translators and retained-object reader), structured-log/output redaction + redacted `Show` for
  token-bearing types, and the opaque namespace + downstream-identity-to-Vault-KV audit. The live
  cross-surface red-team is exercised by Sprint `5.8`; live first-touch raw Pulumi checkpoint
  migration proof remains Sprint `7.14`.
- **Reframed Sprint `7.14`** (Phase `7`, 🔄 active) → the **decrypt-to-scratch Pulumi interposition**
  (`Prodbox.Pulumi.EncryptedBackend`, `withDecryptedStack` on a RAM tmpfs), applied to main per-run
  and `aws-ses` stack cycles plus production stack reads; **drops Pulumi's secrets provider**.
  First-touch raw checkpoint import/delete and Vault-only AWS provider credential resolution are
  code-owned. The transitional raw backend environment is confined to `LegacyPulumiBackend`
  first-touch import/delete; supported Pulumi actions receive provider-only input before the
  scratch `file://` rewrite. The generated operational `aws.*` credential is now a mandatory
  `SecretRef.Vault` reference; setup/config-setup mint the dedicated least-privilege `prodbox` IAM
  identity from the prompted ephemeral elevated credential and write the generated keys into Vault KV
  after Vault is unsealed, and teardown clears that object. (The `aws_admin_for_test_simulation`
  test-simulation fixture's move to `test-config.dhall` and the unification of admin acquisition on
  the interactive `SecretRef.Prompt` is owned by Sprint `7.16`.) Remaining `7.14` work: live
  first-touch deletion proof and deciding whether to remove the now-wrapper-backed
  `aws-ses migrate-backend` compatibility alias after live proof.

Sprint `5.8` (sealed-Vault validation) gains the cross-surface red-team test, and Sprints
`2.26`/`4.32` (federation) gain the downstream-identity-to-Vault-KV + opaque-namespace deliverables —
no reframe needed. The doctrine SSoT is
[../documents/engineering/vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md); the
superseded cleartext-AAD `prodbox-envelope-v1`, the Pulumi DIY raw-S3 access, the `aws-ses`
AES256-SSE-only treatment, the Vault-derived Pulumi passphrase / Pulumi secrets provider, the
role-revealing bucket names, the log/oracle sites, and the child-named k8s namespaces are registered
in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The plan suite (this file,
`00-overview.md`, `system-components.md`, the reopened phase files, the governed engineering docs,
and the legacy ledger) is updated in the same change.

**2026-06-14 — Vault-root finalization + cluster federation: the secrets model is finalized.** A
security-architecture decision makes Vault the **sole, finalized** secrets / KMS / encryption-as-a-
service / PKI root for the entire prodbox stack, with no transitional or bridge pattern. Every
secret, credential, key, and certificate the stack uses is a Vault object — a KV v2 secret, a
Transit key, or a PKI-issued cert — with no second store and no plaintext fallback; **a sealed
(or unreachable / uninitialized) Vault bricks the cluster** (hard fail-closed: no secret resolves,
no cert issues, no MinIO object decrypts, no Pulumi op runs, gateway daemon and Keycloak fail their
readiness gates). This **supersedes the 2026-06-11 "Vault extends — it does not reverse" framing for
the derivation model specifically**: under the finalized option B, the master-seed HMAC derivation
model is **retired, not wrapped** — `Prodbox.Secret.{Derive,MasterSeed,Inventory}`, the gateway
daemon `/v1/secret/derive` + `/v1/secret/ensure-namespace` RPC, the `checkRawMasterSeedReadScope`
lint, and `selfBootstrapOwnSecrets` are removed; there is **no** `master-seed` object in MinIO; every
previously-HMAC-derived or chart-generated secret becomes a Vault KV object fetched via Vault
Kubernetes auth. `FileSecret` / Secret-mounted plaintext Dhall fragments are **removed, not bridged**
(the `SecretRefFile` constructor and its resolver arm are deleted from `Prodbox.Settings.SecretRef`).
The in-force cluster configuration is itself a Vault-Transit-enveloped MinIO object that is the
config SSoT; a filesystem `prodbox-config.dhall` is a seed/propose input only, and updating the root
cluster's in-force config requires the root Vault token. Cluster federation adds a **Vault
transit-seal trust tree**: a root cluster (Shamir seal, operator-unsealed via the `.age` unlock
bundle) and zero or more child clusters (`seal "transit"` against the parent), where each parent's
Vault KV owns its children's init keys and a child's downstream-cluster inventory is itself secret
behind an unsealed Vault — so the fail-closed brick cascades down the tree from the root.

- **Phase `2` reopens** (new, in addition to the phases the 2026-06-11 entry already reopened —
  `0`, `1`, `3`, `4`, `5`, `7`, `8`) for Sprint `2.26` (Cluster Federation Trust Topology and
  Downstream-Cluster Custody: the parent/child hierarchy, downstream-cluster config/identities as
  secret data, and the CLI/gateway surface to register a child cluster and custody its init keys).
- **Phase `0`**: Sprint `0.13` (Vault-Root Finalization and Cluster-Federation Doctrine Harmony —
  docs-only, may close `Done` like Sprint `0.12`) owns this entire doc/plan rearchitecture: the
  rewrite of the vault / config / secret-management / helm / storage / acme / aws doctrine to the
  finalized Vault-root model, the new `cluster_federation_doctrine.md`, the deletion of the repo-root
  `VAULT_REFACTOR.md`, the legacy-ledger repoint, and the README / `00-overview` / `system-components`
  / `substrates` harmonization. Existing Sprint `0.12` stands.
- **Phase `1`**: Sprints `1.35`–`1.38` are now ✅ Done on their Phase-owned surfaces. Sprint
  `1.35` owns the FileSecret-free `SecretRef` contract and Vault resolver seam; Sprint `1.36` owns
  the `prodbox vault` command group and encrypted unlock bundle; Sprint `1.37` owns the sealed-Vault
  Pulumi gate plus production Vault-Transit `DekCipher`; Sprint `1.38` owns the in-force-config
  source-of-truth inversion and global host-loader switch. Runtime AWS provider credential
  migration remains Sprint `7.14`; ACME EAB/TLS key material remains Sprint `7.15`.
- **Phase `3`**: Sprint `3.19` (Retire Master-Seed Derivation: Vault KV Is the Sole Secret Store) and
  Sprint `3.20` (Vault Transit-Seal Hierarchy and Per-Cluster Seal Custody — root Shamir + `.age`
  bundle, child `seal "transit"`, child init keys in the parent's KV, per-domain Transit keys), with
  the reframed Sprints `3.17` (in-cluster Vault on both substrates, init-once/unseal-on-rebuild) and
  `3.18` (all chart and Keycloak secrets via Vault Kubernetes auth).
- **Phase `4`**: Sprint `4.32` (Federated Lifecycle Reconcile and Fail-Closed Unseal Cascade — child
  `cluster reconcile` auto-unseals from its parent, init-once/unseal-on-rebuild, the brick cascade,
  root-token-gated root-config mutation), with the reframed Sprints `4.29`–`4.31`.
- **Phase `5`** (Sprint `5.8`), **Phase `7`** (Sprints `7.14`–`7.15`), and **Phase `8`**
  (Sprint `8.9`) reframe to the finalized end state: sealed-Vault canonical validation and
  SecretRef-only goldens; the Vault-encrypted Pulumi backend + AWS secrets in Vault KV + ACME EAB /
  TLS key material behind Vault; Keycloak SMTP + invite secrets via Vault.
- **Phase `6`** (final clean-room rerun and zero-Python handoff) stays **✅ Done on its owned
  surface** — the clean-room rerun and zero-Python handoff are reused unchanged; the finalized Vault
  model is adopted on the Phase-0/1/2/3/4/5/7/8 surfaces above, not the Phase-6 handoff contract.

The doctrine SSoT for the finalized model is
[../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md); the
federation trust tree is
[../documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
the superseded master-seed-derivation modules, the chart-generated `lookup`+`randAlphaNum` Secrets,
the removed `FileSecret` / Secret-mounted Dhall surfaces, the deleted master-seed object, and the
repo-root config-as-SSoT model are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The plan suite (this file,
`00-overview.md`, `system-components.md`, `substrates.md`, the reopened phase files, the governed
engineering docs, and the legacy ledger) is updated in the same change.

**2026-06-13 — retained-storage topology reorg folds into the open Vault refactor.** The ad-hoc
`.data/` layout — a per-host machine-id prefix on MinIO's PV, an over-nested
`<release>/<workload>/<ordinal>/<claim>` chart path, and a hand-applied Vault PV — is replaced by one
deterministic scheme, `.data/<namespace>/<StatefulSet>/<replica>`, provisioned by a single
reconciler, with every retained workload a StatefulSet (MinIO and `vscode` convert; the Patroni
cluster and Vault already are). **Phase 4 gained Sprint `4.31`** (the unified topology; MinIO off the
bitnami Deployment onto a prodbox-owned `charts/minio/` StatefulSet; `vscode` Deployment →
StatefulSet), now ✅ Done as of 2026-06-16. The storage / chart-platform / Vault /
secret-derivation doctrines and `system-components.md` + `substrates.md` were updated to the target
topology, and the implementing code is now closed across Sprints `3.17` / `4.29` / `4.31` on their
owned surfaces. The removed machine-id prefix, the bitnami MinIO Deployment, the `vscode`
Deployment, and the hand-applied Vault PV are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). This **refines, it does not
reverse**, the Phase `3` storage-binding model; all later phases remain closed on their owned
surfaces.

**2026-06-12 (live) — first live Vault validation on the home cluster.** `prodbox cluster reconcile`
stood up RKE2 (`v1.35.5+rke2r2`, node `bathurst` Ready) + the platform stack from the schema-default
local config; `charts/vault/` then deployed cleanly and Vault `1.18.3` came up **Running 1/1** with
its durable PVC **Bound** to a retained `manual`-class PV under `.data/vault/vault/0`. The full lifecycle
was proven end-to-end: `prodbox vault status` reported `initialized=False, sealed=True` on a fresh
Vault, then `initialized=True, sealed=False` after init + unseal — so **`Prodbox.Vault.Client` and the
`prodbox vault` command group work against a real deployed Vault (Sprint `1.36`), and the
`charts/vault/` platform-component chart deploys a working durable-PV Vault (Sprint `3.17`)** — both
now **live-validated**, not just unit-validated. Remaining live wiring (the init/unseal orchestration
so `prodbox vault init`/`unseal` drive the unlock bundle, the reconcile-side Vault deploy + PV, the
Transit `DekCipher`, gateway Vault-auth, the gate's `aws stack` activation) is now unblocked — a
running Vault exists to build and validate against.

**2026-06-12 — Phase `1` Sprint `1.36` opened (now ✅ Done): the encrypted unlock bundle landed.**
`src/Prodbox/Vault/UnlockBundle.hs` implements the host-side Vault recovery bundle — an **Argon2id**
KDF (crypton) feeding a **ChaCha20-Poly1305** AEAD into a self-describing
`prodbox-vault-unlock-bundle-v1` envelope, with the derived key held in `ScrubbedBytes` and the KDF
parameters stored in the envelope for forward-decryptability. Four unit tests (encrypt/decrypt
round-trip, wrong-password AEAD rejection → `UnlockBundleAuthFailed`, tamper rejection, and the
no-plaintext-leak property) pass. The **Vault HTTP client** (`src/Prodbox/Vault/Client.hs`) also
landed — it speaks the unauthenticated `sys/seal-status` / `sys/init` / `sys/unseal` endpoints
through the native `Prodbox.Http.Client` (no curl), with the pure `bootstrapAction` decision and
`initResponseToUnlockBundle` mapping (5 more unit tests). The **`prodbox vault` command group** is
now wired end-to-end (`Command` / `Spec` / `Parser` / `Native` + `Prodbox.CLI.Vault`): `vault
status` probes the in-cluster Vault and reports initialized / sealed / unseal-progress (or
unreachable); at this checkpoint the mutating subcommands were present on the command surface while
their authenticated orchestration was still landing. The man pages, shell completions, and the
generated command-registry / command-surface tables were regenerated, with parser-routing and three
CLI goldens covering the surface. Gates green: `prodbox dev check` 0 (Fourmolu/HLint/warning-clean build + generated-artifact
lint), `prodbox dev docs check` 0, `prodbox dev lint docs` 0, and `prodbox test unit` **854/854**.
`crypton ^>=1.0.6` + `memory ^>=0.18` joined the library build-depends. This is the core security
primitive of the unlock chain
([vault_doctrine.md §6](../documents/engineering/vault_doctrine.md#6-the-unlock-bundle-root-cluster)) and is
independent of Sprint `1.35`. **Sprint `1.36` has since closed** with the authenticated request
helpers (`sys/seal` + KV/Transit/PKI), `Prodbox.Vault.Reconcile`, every `prodbox vault` leaf handler,
and the 2026-06-16 native CLI lifecycle integration proof recorded above. **Sprint `1.37`
is now `✅ Done`** too: the sealed-Vault gate decision (`Prodbox.Vault.Gate` — `vaultGateDecision`
folds a seal-status probe into `VaultGateAllow` / `VaultGateBlockSealed` / `…Uninitialized` /
`…Unreachable`, with the fail-closed "No preview/update/destroy was started" message), the
`runPulumiCommandWithGate` apply-path wiring, and the production Vault-Transit `DekCipher` have
landed and are unit-validated (`cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'`
**918/918**); the final integration proof closes with the 2026-06-16 `Sprint 1.37` entry above.
**Sprint
`3.17`'s Vault-Transit envelope library** also landed: `Prodbox.Crypto.Envelope` seals objects
under a fresh DEK (local ChaCha20-Poly1305 AEAD, object identity bound as AAD) and wraps the DEK
behind a pluggable `DekCipher` (Vault Transit in production; a loudly-named `insecureLocalDekCipher`
for tests) into the self-describing `prodbox-envelope-v1` document — four unit tests (AAD-bound
round-trip, fail-closed-on-wrong-AAD, tamper, no-plaintext-leak), `test unit` **862/862**,
`dev check` 0. **Sprint `1.35`'s `SecretRef` type + validator** also landed:
`Prodbox.Settings.SecretRef` is the typed reference (`Vault` / `TransitKey` / `Prompt` /
`TestPlaintext`) with no `FileSecret` arm; `validateProductionSecretRef` rejects a plaintext literal
on a production path and `resolveSecretRef` resolves `TestPlaintext` only in the test harness while
failing loud for Vault-backed references unless a Vault reader is supplied (7 unit tests; `test unit`
**869/869**, `dev check` 0). **2026-06-15 update:** the Vault KV resolver seam
(`resolveSecretRefWithVault` / `resolveSecretRefFromVault`) and the production Vault-Transit
`DekCipher` (`Prodbox.Vault.TransitCipher`) landed with validation (`./.build/prodbox dev check` 0;
`./.build/prodbox dev docs check` 0; `./.build/prodbox dev lint docs` 0; `./.build/prodbox test
unit` **909/909**). The `SecretRef` field migration remains deferred
until the Sprint `1.38` in-force-config loader flip and a Sprint `3.17` deployed Vault.
**Later 2026-06-15 update:** the base `vault reconcile` foundation landed too:
`Prodbox.Vault.Reconcile` now applies the ordered baseline mounts, Kubernetes auth, policies, roles,
and per-domain Transit keys, and `Prodbox.CLI.Vault` refuses sealed/uninitialized Vaults before
using the unlock-bundle root token to reconcile. Validation: `cabal test --builddir=.build
prodbox-unit --test-options='--hide-successes'` **915/915**, `./.build/prodbox test unit`
**915/915**, `./.build/prodbox dev check` 0, `./.build/prodbox dev docs check` 0, and
`./.build/prodbox dev lint docs` 0.
**Final 2026-06-15 Sprint `1.36` leaf update:** `vault rotate-unlock-bundle`, `vault
rotate-transit-key KEY`, `vault pki status`, and `vault pki issue-test-cert` now have native
handlers. The PKI issue leaf calls a preconfigured `prodbox-test` PKI role; its live test-issue is
a non-blocking `Live-proof: pending` axis that exercises once Sprint `7.15` configures that role
(development_plan_standards.md Standard O) and never gates this Phase-1 sprint's code-owned closure.
Validation: `cabal test
--builddir=.build prodbox-unit --test-options='--hide-successes'` **916/916** and
`./.build/prodbox test unit` **916/916**, `./.build/prodbox dev check` 0,
`./.build/prodbox dev docs check` 0, and `./.build/prodbox dev lint docs` 0. **Final 2026-06-16
closure:** the `Sprint 1.36` integration filter exercises status/init/idempotent re-init/unseal/
reconcile/rotate/PKI/seal through the built CLI and passes. Direct child registration,
federated auto-unseal, and the gateway-mediated federation bootstrap surface are now closed by
Sprints `3.20`/`4.32`/`2.26`. Sprint `3.17` now has the
code-owned platform/envelope foundation and Sprint `3.18` now has the chart-secret
policy/role/service-account, Kubernetes-auth config, and live seed-object bootstrap foundation;
the `websocket` workload OIDC client-secret is now a direct `SecretRef.Vault` app-side consumer,
the Keycloak / MinIO charts materialize their covered runtime fields through Vault-login init
containers, the VS Code Envoy `SecurityPolicy` client Secret is Vault-materialized by a chart Job,
gateway event keys plus Route 53 AWS and gateway MinIO credentials are direct Vault consumers, and
Patroni role Secrets are materialized from Vault by the `keycloak-postgres` pre-install hook;
the AWS SES SMTP sync writes `secret/keycloak/smtp`, and host/admin helper paths read remaining
Keycloak admin, OIDC, demo-user, and SMTP material from Vault KV; the Sprint `3.18` structural
sealed-startup proof now pins those chart materializers to fail closed on sealed/unreachable Vaults.
The
`1.35` field migration, and
Sprints `4.29`–`4.30`, `5.8`, `7.14`–`7.15`, `8.9` remain open, all converging on the deployed
in-cluster Vault as the gate that unblocks live validation. The
**Vault platform-component chart** itself now exists as a structurally-validated artifact
(`charts/vault/` — single-replica StatefulSet on a durable PVC, ConfigMap, ClusterIP + loopback
NodePort; `dev lint chart` 0, `helm template` renders, `dev check` 0), and Sprint `3.17` now wires
Vault into both substrate platform installs. What remains is the later lifecycle-owned **live
`cluster reconcile`** init/unseal exercise under Sprint `4.29` — a long, watched operator
operation, not a unit-validatable change.

**2026-06-11 (validation pass) — Phase `0` Sprint `0.12` closed; Vault implementation phases
remain `📋 Planned`.** A clean cold build of `exe:prodbox` (exit 0) plus the gate run closed the
docs-only Vault sprint: `prodbox dev lint docs` 0, `prodbox dev docs check` 0, `prodbox dev check`
0 (policy + Fourmolu + HLint + warning-clean build), and `prodbox test unit` **823/823**. The same
run validated a **Sprint `3.17` increment** — the master-seed scratch file now lands on a RAM-only
`emptyDir{medium: Memory}` tmpfs mount (`/run/prodbox-seed`) instead of a disk-backed path
(`charts/gateway/templates/deployments.yaml` + `src/Prodbox/Secret/MasterSeed.hs`); Sprint `3.17`
stays `📋 Planned` overall (the Vault-Transit envelope, the in-cluster Vault platform component,
and the native-S3/scrubbed-memory rung are not yet built). At that time, the remaining Vault sprints
(`1.35`–`1.37`, `3.17`–`3.18`, `4.29`–`4.30`, `5.8`, `7.14`–`7.15`, `8.9`) had not yet started:
they are tightly ordered (the `SecretRef` field migrations cannot resolve until the Vault client
and `vault reconcile` land in `1.36`, and there is no in-cluster Vault to encrypt against yet),
and their `Done` gate per [development_plan_standards.md](development_plan_standards.md) §C
requires live validation against a deployed in-cluster Vault + cluster + AWS that a non-cluster
session cannot drive. Implementation proceeds from `1.35` (the `SecretRef` type + config-validate
plaintext rejection + `test-config.dhall` seam) → `1.36` (the `prodbox vault` group + Argon2id/age
unlock bundle + Vault HTTP client) → the rest, in order, with the live exercises driven from the
operator host.

**2026-06-11 — Vault secret-management refactor reopens Phases `0`, `1`, `3`, `4`, `5`, `7`, and
`8`.** A security review adopted Vault as the first-class secrets, key-management,
encryption-as-a-service, and PKI backend of every prodbox-managed cluster under one load-bearing
invariant: a sealed Vault reduces prodbox to an opaque durable-data pile — PVs and MinIO objects
may still exist, but they reveal no secrets, no active Dhall, no Pulumi state, and no
downstream-cluster inventory until Vault is unsealed. Vault runs in-cluster on a durable
`.data/`-backed PV (preserved across cluster wipes exactly like MinIO's); `prodbox-config.dhall`
carries only typed `SecretRef` values and never plaintext; MinIO objects, Pulumi backend state,
and the active daemon Dhall are stored only as Vault-Transit envelopes; and the
TLS/Keycloak/Pulumi/AWS-credential paths fail closed when Vault is sealed. The doctrine SSoT is
[../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md).
**Crucially, Vault extends — it does not reverse — earlier phases:** the master-seed derivation
model, the single-Dhall-file config contract, the retained-PV model, the single ZeroSSL issuer +
S3 retain-restore, and the managed-resource-registry teardown all stand; Vault adds an
encryption-at-rest + sealed-state authority layer beneath them. Per standards rule A each reopen
is narrated here and per rule L each workstream is a new sprint in its owning phase — no surface
moves to a different phase.

- **Phase `0` reopens** for Sprint `0.12` (create the `vault_doctrine.md` SSoT, add the
  secret-classification model + the engineering-index row, and cross-link the
  config/secret-derivation/storage/lifecycle/edge/helm/acme/aws-admin docs to it — docs-only).
- **Phase `1` reopens** for Sprint `1.35` (the typed `SecretRef` Dhall union + the
  `Prodbox.Settings.SecretRef` ADT; refactor `aws.*` / `acme.eab_*` to references;
  `prodbox config validate` rejects plaintext secret values in production config; `test-config.dhall`
  is accepted only by the test harness), Sprint `1.36` (the
  `prodbox vault status|init|unseal|seal|reconcile|rotate-*|pki` command group + the Argon2id/age
  authenticated unlock bundle at `.data/prodbox/vault-unlock-bundle.age` +
  `Prodbox.Vault.{Client,Bootstrap,UnlockBundle,Reconcile}`, idempotent init-if-empty), and
  Sprint `1.37` (real `aws stack` apply/destroy/migrate actions gate on Vault
  reachable/initialized/unsealed before touching state; Sprint `7.14` extends that same gate with
  Transit/backend decryptability when the encrypted Pulumi backend lands; Model B drops Pulumi's
  own secrets provider and uses the prodbox Vault-Transit envelope as the encryption).
- **Phase `3` reopens** for Sprint `3.17` (Vault added to the shared `[PlatformComponent]`
  inventory so both substrates stand up an in-cluster Vault on a durable PV; `Prodbox.Crypto.Envelope`
  + `Prodbox.Minio.EncryptedObject`; the master seed and active Dhall become Vault-Transit
  envelopes; the gateway daemon authenticates to Vault with Kubernetes auth and fails closed when
  sealed) and Sprint `3.18` (chart and Keycloak data-bound secrets consumed via Vault Kubernetes
  auth; the derived-vs-generated inventory extends with the Vault-KV class).
- **Phase `4` reopens** for Sprint `4.29` (`cluster reconcile` integrates deploy / init-if-empty /
  unseal / reconcile of Vault; `cluster delete` preserves the durable Vault PV; sealed-Vault
  becomes a first-class `cluster status` / `edge status` line; lifecycle commands gain fail-closed
  readiness gates) and Sprint `4.30` (metadata hardening: opaque MinIO object IDs + Vault-encrypted
  indexes + log redaction + the red-team checklist).
- **Phase `5` reopens** for Sprint `5.8` (the `sealed-vault` canonical validation that seals Vault
  and asserts active-Dhall / Pulumi / gateway / Keycloak / TLS all fail closed without metadata
  leak, plus SecretRef-only golden tests and the plaintext-rejection / init-unseal-reconcile /
  teardown-preserves-Vault-PV unit proofs).
- **Phase `7` reopens** for Sprint `7.14` (full Vault-Transit-encrypted Pulumi backend objects;
  the generated least-privilege `prodbox` IAM identity prodbox mints lives in Vault KV; the
  interactive `SecretRef.Prompt` supplies the ephemeral elevated credential, which mints that
  identity, writes the generated `aws.*` keys to Vault, and is then discarded — never persisted) and
  Sprint `7.15` (ACME EAB material moves from the
  plaintext `acme.eab_*` config fields into Vault KV; TLS private-key material is
  generated-in / stored-in / wrapped-by Vault; TLS fails closed when Vault is sealed).
- **Phase `8` reopens** for Sprint `8.9` (the `keycloak-smtp` SMTP credential and the invite-flow
  OIDC client secrets move into Vault KV, consumed by Keycloak via Vault Kubernetes auth; the
  invite and bootstrap paths fail closed when Vault is sealed).

**Phases `2` and `6` stay `✅ Done` on their owned surfaces** — the gateway runtime / DNS
ownership and the clean-room rerun / zero-Python handoff are reused unchanged; the gateway
daemon's new Vault authentication for seed-envelope decryption is scheduled on the
Phase-3-owned secret-derivation surface (Sprint `3.17`), not the Phase-2 runtime. The overall
handoff is incomplete until the Vault sprints land; the canonical-suite-green claim below stands
for the behavior it proved and is now qualified by the sealed-state fail-closed coverage
scheduled in Sprint `5.8`. The superseded plaintext-secret, unencrypted-master-seed,
unencrypted-Pulumi-backend, and Secret-mounted-plaintext-Dhall surfaces are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The plan suite (this file,
`00-overview.md`, `system-components.md`, `substrates.md`, the reopened phase files, the governed
engineering docs, and the legacy ledger) is updated in the same change.

**2026-06-10 (later) — `cluster delete` per-run-backend decoupling reopens Phase `4`.** A live
`prodbox cluster delete --yes` on a freshly-reconciled local cluster wrongly REFUSED because the
default delete's per-run residue gate misclassified a never-created MinIO state bucket
(`NoSuchBucket` / 404) as `Unreachable` instead of `Absent`. Per the operator's call, the default
`cluster delete` is redefined as a **pure local cluster uninstall**: it preserves `.data/` and
never queries, gates on, or destroys the per-run AWS Pulumi backend — so deleting the cluster can
never be blocked by AWS-backend observability, and per-run AWS stacks (if any) stay destroyable
afterward via `--cascade` or `prodbox aws stack <name> destroy --yes`. **Phase `4` reopens** for
the next Phase-4 sprint: remove the `noLivePerRunPulumiStacks` precondition + the default-delete
refuse-gate + the `--allow-pulumi-residue` flag (clean cut, no alias); add the secondary
`NoSuchBucket → Absent` classification fix in `LiveResidue` (benefits the cascade + `aws teardown`
per-run queries); regenerate the `rke2-delete` default golden; update `CLAUDE.md`, `README.md`,
and `lifecycle_reconciliation_doctrine.md` / `cli_command_surface.md`. `--cascade` is unchanged and
remains the only `cluster delete` path that destroys per-run AWS stacks. Phases `0`/`1`/`5` (the
command-surface refactor below) and `2`/`3`/`6`/`7`/`8` are otherwise unaffected.

**2026-06-10 — Command-surface refactor reopens Phases `0`, `1`, and `5`.** A whole-surface
review found the documented command topology leaked implementation (`rke2`, `pulumi`) and coupled
local cluster commands to AWS. The refactor: tiers config validation so local commands decode with
an empty `aws.*` block; splits the AWS-free local **cluster** from the AWS-gated public **edge**
(`prodbox cluster reconcile` is local-only; `prodbox cluster reconcile --with-edge` /
`prodbox edge reconcile` attach Route 53 DNS + ZeroSSL TLS); renames/regroups the whole tree
(`rke2`→`cluster` with `k8s` folded in, new `edge`, `pulumi <stack>-resources/-destroy`→
`aws stack <name> reconcile/destroy`, `aws check-quotas/request-quotas`→`aws quotas check/request`,
`check-code`/`lint`/`docs`/`tla-check`→a `dev` group, `charts deploy`→`charts reconcile`); and
points every prerequisite remedy at the new commands. Per standards rule L each workstream is a new
sprint in its owning phase, and per rule A the reopen is narrated here. **Phase `0` reopens** for
Sprint `0.11` (regenerate the CLI command matrix + `StackDescriptor` command-surface table from the
typed registries; sweep the hand-edited prose in `README.md`, `CLAUDE.md`, `AGENTS.md`, and the
engineering docs onto the new names). **Phase `1` reopens** for Sprint `1.33` (config-validation
tiering in `Settings.hs` + the local/edge split extracting the Route 53 DNS-01 issuer and bootstrap
record into a standalone edge reconcile) and Sprint `1.34` (the full command-tree rename/regroup
across `Command.hs`/`Spec.hs`/`Parser.hs`/`Native.hs` and the handlers, with the new `EdgeCommand`
and the `--with-edge` switch). **Phase `5` reopens** for Sprint `5.7` (prerequisite remedy strings
name the new commands so a missing local cluster fails fast with `Run `prodbox cluster reconcile``,
plus the regenerated destructive `--dry-run` goldens). **Phases `2`, `3`, `4`, `6`, `7`, and `8`
stay `✅ Done`** — the gateway runtime, chart platform, lifecycle reconcilers, clean-room contract,
AWS substrate, and email-auth foundations are reused and renamed, not re-architected. Removed
command-surface constructors and the `prodbox pulumi`/`check-code` surfaces are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

**2026-06-09 (later) — Design-intention review reopens Phases `0`, `1`, `2`, `3`, `4`, `5`, and
`7`.** After Phase `8` closed the canonical suite on both substrates (entry below), a whole-system
design analysis adjudicated each documented-intention-vs-code divergence toward the structure that
best serves the project's ultimate needs — not "make the doc match the code." It found genuine
code-convergence gaps the doctrine mandates but the worktree does not yet honor, plus five places
the doctrine itself should change; per standards rule L each gap is scheduled as a new sprint in its
owning phase, and per rule A the reopen is narrated here. **Phase `0` reopens** for Sprint `0.9`
(Documentation Harmony made an *enforced* invariant: repair the stale/contradictory doctrine
statements, add the missing `**Generated sections**` headers, implement the header↔markers
reconciler + relative-link check) and Sprint `0.10` (generate the drift-prone command/route/stack
tables from their typed registries so they cannot drift again). **Phases `1`–`7` reopen** for the
code-convergence sprints the rewritten doctrine now mandates: `1.29`–`1.32` (CLI matrix generated
from `commandRegistry`; classifiable `ServiceError` + one PATH-preserving AWS-CLI env builder +
`Dns.hs` PATH fix; construction-enforced DAG acyclicity; retire the un-adopted `StateMachine.hs`),
`2.24`–`2.25` (delete the daemon `--log-level`/`--port`/`--foreground` override flags; gateway
per-connection read-timeout + inbound/outbound health split + restart-based Orders promotion),
`3.15`–`3.16` (workload config-as-data + `PRODBOX_*` ladder removal; daemon-only master-seed
boundary so a plaintext seed never reaches the host), `4.26`–`4.27` (route `rke2 delete`/`nuke`
through `runPlanWithOptions` so `--dry-run` cannot silently mutate, `nuke` tag-sweep fail-closed; a
`StackDescriptor` SSoT + exception-safe Route 53 capability probe), `5.6` (typed `PrerequisiteId`
with minimal per-validation prerequisites + the missing destructive `--dry-run` goldens), and
`7.12`–`7.13` (substrate equivalence as a shared-component-inventory + single-version-pin invariant;
the DNS-01-honest issuer rename). **Phases `6` and `8` stay `✅ Done`** on their owned surfaces — the
clean-room rerun, the registry SSoT enforcement, the `Plan`/Apply and Effect-DAG foundations, the
single-issuer + S3 retain-restore behavior, and the chart-side env-emission removal are reused, not
changed. The canonical-suite-green claim below stands for the behavior it proved; it is qualified
only by these scheduled correctness/clarity convergences, so the overall handoff is incomplete until
they land. Sprint `0.9` (the documentation-intention rewrite) is landable as a docs-only pass; the
code-bearing sprints follow. The plan suite (this file, `00-overview.md`, `system-components.md`, the
phase files, the governed engineering docs, and `legacy-tracking-for-deletion.md`) is updated in the
same change to express the corrected intention.

**2026-06-09 — AWS substrate parity ✅ (Sprint `8.6` closed) + certificate round-trip
restore-no-reorder ✅ proven (Sprint `8.8`).** Targeted `keycloak-invite --substrate aws` passed
end-to-end (`KCINVITE_AWS_EXIT=0`, OIDC claims verified on `aws.test.resolvefintech.com`, clean
EKS/subzone/test teardown, no leak), so `keycloak-invite` is green on **both** substrates — the
live POST/OIDC substrate proof. The fifth defect (re-ordering the cert against ZeroSSL on every
rebuild) is fixed: `retainReadyPublicEdgeCertificate` captures the issued cert to the long-lived
S3 store at the readiness gate, and `retainedPublicEdgeTlsSecretManifest` now preserves the
`cert-manager.io/*` adoption annotations so the restored cert is **adopted** on rebuild — verified
live (a home rebuild brought the cert Ready with **zero ACME orders / zero readiness cycles**,
then `keycloak-invite` passed). Gates: `check-code` 0, `test unit` 695/695. The full AWS aggregate then closed ✅ **GREEN**
(`TESTALL_AWS_EXIT=0`): all 16 then-canonical validations on EKS including `keycloak-invite` + the
destructive `lifecycle`, both cabal suites (unit 695, integration 32), clean teardown (no leak).
That closed the Phase 8-owned then-canonical substrate proof; current full-suite membership is
defined in `src/Prodbox/TestPlan.hs` and current AWS live-proof axes are tracked in
[substrates.md](substrates.md). The final Sprint
`8.8` deliverable — the `prodbox nuke` nuke-only-removes-the-retained-cert proof — then closed via
the **interactive integration harness**: `prodbox nuke` is operator-only (TTY + typed
confirmation), but the suite drives it through the same `PRODBOX_ALLOW_NON_TTY_INTERACTIVE` + stdin
seam as the other interactive surfaces. Three new `CliSuite.hs` cases prove the typed-confirmation
gate (wrong literal destroys nothing), the `--dry-run` plan's step-5 long-lived bucket destroy
(where the retained cert lives), and the full five-step total-teardown running end-to-end on
`NUKE EVERYTHING`. With the Sprint `4.24` `LongLived` registry classification (nuke-only), this
completes the proof. Gates: `check-code` 0, `test unit` 695/695, `test integration cli` 35/35.
**Phase `8` is now ✅ Done** on all owned deliverables.

**2026-06-08 — Home `keycloak-invite` live gate ✅ GREEN (Sprint `8.5` home POST/OIDC proof
closed); four real defects fixed.** The first live home-substrate
`prodbox test integration keycloak-invite --substrate home-local` passed end-to-end (invite →
SES capture → action-token proceed page → credential set → invited-user OIDC claims verified →
cleanup; exit 0, no AWS leak). Four fixes landed, each verified (`check-code` 0, `test unit`
693/693, `test integration cli` 32/32): (1) the fake `kubectl` in `test/integration/CliSuite.hs`
now honors `--ignore-not-found=true` — its absence was a Sprint `8.7` regression that failed
`charts deploy vscode` and **aborted `prodbox test all` before any native validation** (the real
cause of the two failures previously mislabeled "pre-existing environmental"); (2) the
credential-setup parser now follows Keycloak 26's `/login-actions/action-token` "proceed" anchor
(`CredentialSetupForm.hs`, +2 tests, fixture refreshed to the live capture); (3) **retain-on-ready**
(`retainReadyPublicEdgeCertificate` + `TestRunner.runWaitForPublicEdgeReady`) captures the issued
cert to the long-lived S3 store the moment it is confirmed ready — the prior retain-on-delete never
populated S3 (delete plan has no FQDN), forcing a fresh ZeroSSL order every rebuild; the delete-path
preserve outcome is now surfaced (Sprint `8.7` "never silent"); (4) `newUserCreationPayload`
(`Keycloak/Admin.hs`) now sets `firstName`/`lastName` so the invited user is "fully set up" for
Keycloak 26's user-profile validation — without them the OIDC password-grant returned `400
invalid_grant: "Account is not fully set up"`. The full home `prodbox test all` aggregate then closed
the Sprint `8.8` home deliverable ✅ **GREEN** (`TESTALL_HOME4_EXIT=0`): all 16 then-canonical
validations passed including `keycloak-invite` and the destructive `lifecycle` cluster-wipe cycle,
plus both cabal suites (unit 693/693, integration 32/32), postflight clean (no AWS leak). Remaining
for Phase `8`: AWS parity (Sprint `8.6`), the certificate round-trip restore-no-reorder proof
(Sprint `8.8` — retain-on-ready bootstraps S3, but cert-manager re-issues on rebuild instead of
adopting the restored Secret; root cause identified: the restored Secret strips the
`cert-manager.io/*` adoption annotations; fix pending), and the TTY-only `prodbox nuke`
retained-cert proof (Sprint `8.8`, cannot run non-interactively).

**2026-06-07 — ZeroSSL is the sole supported ACME provider; the two-issuer model is reverted to
one ZeroSSL issuer.** Sprints `7.11`/`8.7` originally rendered two cert-manager `ClusterIssuer`s
(a production issuer plus a staging issuer on a separate ACME provider) selected by an
`IssuerClass`. ZeroSSL became the only supported provider, so the ACME runtime now renders ONE
`ClusterIssuer` — `zerossl-dns01` (built from `acme.server`, EAB-authenticated, with a factored
DNS-01 Route 53 solver and the `zerossl-account-key` account key). Removed: the staging issuer,
the `acme.staging_server` config field + its default constant, the `IssuerClass` ADT +
`issuerClassClusterIssuerName` + `parseIssuerClass` + `issuerClassFromOverride` +
`resolvePublicEdgeIssuerClass` + the `PRODBOX_PUBLIC_EDGE_ISSUER_CLASS` env var. ZeroSSL has no
staging endpoint; rebuild churn is handled by the S3 retain-and-restore of the issued certificate
(Sprints `4.24`/`7.11`/`8.7`), so the cert is issued once and restored rather than re-ordered.
`Prodbox.PublicEdge.publicEdgeClusterIssuerName` is the single shared issuer-name constant used
by both the ACME runtime and the chart `Certificate` values. Gates green: `check-code` 0,
`test unit` 690/690, `docs check` 0, `lint docs` 0; integration cli/env only the 2 pre-existing
`charts deploy vscode` environmental failures. Code:
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) Sprint `7.11`,
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) Sprint `8.7`; doctrine
[acme_provider_guide.md](../documents/engineering/acme_provider_guide.md).

**2026-06-07 — Sprint `8.7` ✅ Done on the code-owned surface.** The chart-platform
public-edge cert retention is refactored onto the S3-backed `LongLived` store.
`Prodbox.Lib.ChartPlatform` gains the typed `PublicEdgePreserveOutcome` +
pure `classifyPublicEdgePreserve` + `renderPublicEdgePreserveOutcome`, closing the
`preservePublicEdgeTlsSecretBeforeDelete` silent-success gap (an unobservable owned cert still
refuses with `Left`; observed-absent is now a distinct typed/returned value, never silent);
preserve writes the cert to the long-lived S3 store and restore reads it back
(`retainPublicEdgeSecretToStore` / `restorePublicEdgeSecretFromStore` over
`putLongLivedObject`/`getLongLivedObject` + `resolveLongLivedAdminS3Context`), both
gracefully degrading when the store is unavailable — so restore-before-issue now works on
every rebuild path (fresh cluster / post-`rke2 delete`) because the store is durable, not an
in-cluster Secret. The keycloak + vscode `Certificate` issuers reference the single
`zerossl-dns01` `ClusterIssuer`, replacing the removed hardcoded constant (the
`charts/keycloak` + `charts/vscode` `values.yaml` defaults point at it). (The `IssuerClass`
selector this sprint originally added was reverted with the ZeroSSL single-issuer decision
above.) Gates green: `check-code` 0, `test unit` 690/690, `docs check` 0, `lint docs` 0;
integration cli/env only the 2 pre-existing `charts deploy vscode` environmental failures (the
graceful S3 retention is a no-op without admin creds, so the deploy path is behavior-preserving).
The live S3 round-trip is the Phase 8 Sprint `8.8` gate. Code:
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) Sprint `8.7`; doctrine
[helm_chart_platform_doctrine.md § 9](../documents/engineering/helm_chart_platform_doctrine.md).
Sprints `8.5`/`8.6` (live home/AWS POST-OIDC + aggregate proofs) and `8.8` (live
`keycloak-invite` gate + certificate round-trip + nuke-only-removes-cert proof) were
**operator-driven live gates** at this point — they required hours-long live AWS/cluster runs and
external ACME state and could not be exercised on the fast gates or in a non-interactive session;
they later landed under the Phase `8` live-closure notes.

**2026-06-07 — Sprint `7.11` ✅ Done; Phase 7 reclosed on its owned surface.** The ACME
runtime renders one cert-manager `ClusterIssuer` from `acmeRuntimeManifestWith`:
`zerossl-dns01` (built from `acme.server`, EAB-authenticated). The DNS-01 Route 53 solver is
factored out (`acmeRoute53Solver`); the issuer carries its own `privateKeySecretRef` account key
(`zerossl-account-key`) and the ZeroSSL external account binding. Both the home
(`Rke2.ensureAcmeRuntime`) and AWS (`AwsSubstratePlatform.ensureAwsSubstrateAcmeRuntime`) paths
wait for it. The substrate-scoped cert-retention key scheme `public-edge-tls/<substrate>/<fqdn>`
(`PublicEdge.publicEdgeTlsRetentionKey`) and the S3 access path
(`putLongLivedObject`/`getLongLivedObject` in `LongLivedPulumiBackend.hs`) land here, reused
by Sprint `8.7`. Gates green: `./.build/prodbox check-code` exit 0,
`./.build/prodbox test unit` 690/690, `./.build/prodbox docs check` exit 0,
`./.build/prodbox lint docs` exit 0; integration cli/env pass (only the 2 pre-existing
`charts deploy vscode` environmental failures remain). The live single-issuer + S3-retention
round-trip is the Phase 8 Sprint `8.8` gate. Code:
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) Sprint `7.11`;
doctrine [acme_provider_guide.md](../documents/engineering/acme_provider_guide.md).

**2026-06-07 — Sprint `4.24` ✅ Done; Phase 4 reclosed on its owned surface.** The
public-edge **production** TLS certificate is now a registered `LongLived` managed
resource. `("public-edge-tls", LongLived)` joins `resourceLifecycleClasses`
(`src/Prodbox/Lifecycle/ResourceClass.hs`); `queryPublicEdgeTlsResidueStatus`
(`src/Prodbox/Lifecycle/LiveResidue.hs`) is the typed `discover` — it lists objects under
the `public-edge-tls/` prefix in the long-lived `pulumi_state_backend` S3 bucket and maps
them through the pure `residueStatusFromObjectListing` to present / absent /
missing-bucket-is-absent / `Unreachable`-is-refuse, so the soundness rule
(`residueBlocksTeardownGate`, §3.1 invariant 2) covers it; `destroyRetainedPublicEdgeTls`
(→ `purgeLongLivedObjectsUnderPrefix` in `LongLivedPulumiBackend.hs`) is the registered,
idempotent `destroy`; and `longLivedManagedResources`
(`src/Prodbox/Lifecycle/ResourceRegistry.hs`) carries it. Classified the same as
`aws-ses`, it is never reconciled by `prodbox rke2 delete` or `prodbox aws teardown` and is
removed only by `prodbox nuke` (transitively, via the whole-bucket destroy) or the explicit
registered destroy; the `noLiveLongLivedPulumiStacks` gate now discovers it too. The
generated `substrates.md` Resource Lifecycle Classes table re-renders with the
`public-edge-tls` row. Gates green: `./.build/prodbox check-code` exit 0,
`./.build/prodbox test unit` 682/682 (new 8-test `Sprint 4.24` block),
`./.build/prodbox docs check` exit 0, `./.build/prodbox lint docs` exit 0. The two
`charts deploy vscode` integration-cli failures observed in this environment
(`CliSuite.hs:256`/`:376`) reproduce identically on the pre-Sprint-4.24 tree and are
unrelated (the deploy path imports none of the changed modules). The live production
round-trip remains the Phase 8 Sprint `8.8` gate. Code:
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) Sprint `4.24`;
doctrine
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).

**2026-06-06 — `rke2 delete` no longer refuses an already-deleted cluster (Sprint
`4.25`).** `prodbox rke2 delete` (default and `--cascade`) now probes for an installed RKE2
*before* the Sprint `4.19` fail-closed residue gate; when no install is present
(`/usr/local/bin/rke2`, `/usr/local/bin/rke2-uninstall.sh`, `/var/lib/rancher/rke2`,
`/etc/rancher/rke2` all absent) it prints `No RKE2 cluster to delete.` and exits `0` instead
of refusing because the in-cluster MinIO state backend "could not be read". This resolves the
degenerate case where the cluster — and with it MinIO — is already entirely gone, which the
gate alone cannot distinguish from a transiently-unreachable backend. The probe is keyed off
**install** state, not service state, so an installed-but-stopped RKE2 still flows through the
full gate / cascade unchanged; `.data/` is never touched. Code: `rke2InstallPresent` in
`src/Prodbox/CLI/Rke2.hs`; doctrine carve-out
[lifecycle_reconciliation_doctrine.md § 5a](../documents/engineering/lifecycle_reconciliation_doctrine.md);
phase block Sprint `4.25` in
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md).

**2026-06-06 — Public-edge TLS certificate reclassified as a LongLived,
rate-limit-safe resource; Phase 4 and Phase 7 reopened, Phase 8 extended.** The
ordered home `keycloak-invite` live gate was blocked by the ACME provider's certificate
issuance rate limit after the pre-retention `public-edge-tls` Secret was lost. Root cause is a
classification bug: the public-edge certificate is treated as disposable `PerRun` chart state
(best-effort in-cluster copy into the `prodbox` namespace, a silent-success gap in
`preservePublicEdgeTlsSecretBeforeDelete`, and no protection on cluster-wipe teardown
paths), even though re-ordering it on every rebuild makes it a `LongLived`,
rate-limited external resource — the TLS analogue of the long-lived `aws-ses` identity.
The refactor retains the issued cert once in the long-lived `pulumi_state_backend`
S3 bucket, restores it before every issuance, and registers it in the managed-resource
registry. It is scheduled as **Phase 4 Sprint `4.24`** (cert registered as a `LongLived`
`discover`/`destroy` resource; §3.1 totality), **Phase 7 Sprint `7.11`** (the single ZeroSSL
ACME `ClusterIssuer` `zerossl-dns01` with a DNS-01 Route 53 solver + the substrate-scoped S3
retention key), and **Phase 8 Sprint `8.7`** (chart-platform retention refactor: close the
silent gap, S3 restore-before-issue on all rebuild paths) and **`8.8`** (live
`keycloak-invite` gate closure + the certificate round-trip). **Phase 4
reopened** because the registry gains a new `LongLived` resource on its owned surface;
**Phase 7 reopened** because the substrate-aware ACME `ClusterIssuer` rendering (Sprint
7.5.b) extends to the substrate-scoped retention store; **Phases 1, 2,
3, 5, and 6 stay `Done`** — the `Plan`/Apply, gateway, chart-platform, and canonical-suite
foundations are reused, not changed. The overall handoff stays incomplete until the
refactor lands and the home `keycloak-invite` gate passes, with AWS parity
following. Doctrine SSoT:
[acme_provider_guide.md](../documents/engineering/acme_provider_guide.md),
[helm_chart_platform_doctrine.md](../documents/engineering/helm_chart_platform_doctrine.md),
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).

**2026-06-01 — Sprint 3.13 ✅ Done: live home-substrate `prodbox test
all` retry 21 closes 16 of 17 validations including the previously-
blocked `lifecycle` (full `rke2 delete --cascade` + RKE2 reinstall +
helm-from-scratch cycle).** Every Sprint 3.13-owned validation
(`charts-vscode`, `charts-api`, `charts-websocket`, `admin-routes`,
`public-dns`, `dns-aws`, `aws-iam`, `aws-eks`, `pulumi`,
`ha-rke2-aws`, `gateway-daemon`, `gateway-pods`, `gateway-partition`,
`charts-platform`, `charts-storage`, `lifecycle`) green. Only
`keycloak-invite` failed, and the dev plan explicitly carves that
one out to Sprint 8.5 (the credential-setup form parser + invite
flow is 8.5's owned surface). Sprint 3.13's four-block preserved-
data exercise is therefore closed end-to-end; the doctrine of
deterministic master-seed-derived passwords flowing through k8s
Secrets to chart consumers (via Helm `lookup` + the new chunk-33
host-side pre-apply) is validated against a real Keycloak realm
import, a real OIDC handshake, and a real cluster-wipe-and-rebuild
cycle.

**2026-06-01 — Sprint 3.13 chunks 17–33 land: live-iteration tail
closing every regression surfaced by `prodbox test all` retries 1–21
on the home substrate.** After chunk 16 declared Sprint 3.13's
code-owned surface closed, the live four-block exercise surfaced a
long chain of issues that pure code review had missed. Each chunk
17–33 fixes one targeted issue, in order:

- **17** `ensureAdminPublicEdgeRoutes` / `waitForAccessToken` against the
  new master-seed flow (`kubectl`-based read of the daemon-applied
  Secret).
- **18** Reconcile-time host-side master-seed derivation via
  `withMinioPortForward` + `ensureMasterSeed` + `deriveBase64Url` (the
  Secret doesn't exist yet during reconcile).
- **19** Drop the stale "non-empty `gatewayEventKeys`" validation —
  the chart now reads via Helm `lookup`, not via values.
- **20** Gateway chart RBAC emits `Namespace` resources for each entry
  in `rbac.targetNamespaces` not equal to the chart's own.
- **21** Namespace-aware Patroni Secret names: cluster prefix is now
  `"prodbox-" <> namespace <> "-pg"` (vscode/keycloak both pull
  keycloak-postgres as a dep).
- **22** Add `update` verb to gateway daemon RBAC on Secrets (`PUT`
  needs it).
- **23** Rewrite K8s API client as POST-first, PUT-on-`409`-conflict.
- **24** `Daemon.deriveOwnGatewayEventKeys` derives in-memory at
  startup, closing the bootstrap chicken-and-egg.
- **25 + 26** Tune the keycloak/keycloak-postgres pre-install Job
  retry budget (`backoffLimit: 6`, `curl --retry 12 --retry-delay 5
  --max-time 30`) to fit helm's default `--timeout`.
- **27** Extend `rbac.targetNamespaces` with `vscode`.
- **28** Namespace-aware `keycloak` inventory + cross-namespace
  `lookup` fixes in `vscode/templates/http-route.yaml` and
  `websocket/templates/configmap-config.yaml`.
- **29** Operator-only state hygiene: wiped a stale
  `.data/vscode/keycloak-postgres/` directory left over from a
  pre-chunk-21 test run carrying a different PostgreSQL system ID. No
  code change.
- **30** Delete the obsolete `"restores retained Patroni state
  through a staged bootstrap"` integration test — testing dead
  code path that chunks 13–14 removed.
- **31** `PRODBOX_TEST_HOST_MASTER_SEED_HEX` test-only injection
  seam in `readKeycloakVscodeClientSecret` (mirrors the existing
  `PRODBOX_TEST_RESIDUE_*` pattern). The fake-env reconcile tests
  short-circuit the MinIO port-forward with a constant seed;
  production never sets the env var.
- **32** Three host-side cluster-Secret reads
  (`readKeycloakOidcClientField`, `loadKeycloakAdminPassword`,
  the `oidcClientSecretContext` call in
  `readKeycloakVscodeClientSecret`) switched from namespace
  `keycloak` to `vscode` to match chunk 28's deploy-namespace-aware
  Inventory. Pre-fix the harbor/minio admin OIDC handshake 401'd.
- **33** New `Prodbox.Secret.HostBootstrap.preApplyDerivedSecretsForRelease`
  closes the Helm `lookup` timing hole — Helm renders templates
  (including `lookup`) BEFORE applying pre-install hooks, so on
  first install the realm-import ConfigMap was substituting
  `"change-me"` placeholder client secrets that Keycloak then
  imported permanently. The new function reads the master seed
  host-side and `kubectl apply`s every Inventory entry BEFORE
  `helmUpgradeInstall`; the chart's pre-install Job remains the
  in-cluster idempotent fallback. Wired into both `deployRelease`
  and `deployPatroniRelease` in `Prodbox.Lib.ChartPlatform`.

Validated on every static gate after chunk 33: `prodbox check-code`
exit 0, `prodbox test integration cli` 29/29 PASS, `prodbox test
integration env` 3/3 PASS, fourmolu + hlint + warning-clean build
all green. Live `prodbox test all` retry 20 reached **15 of 16
validations passing** on the home substrate (every OIDC handshake /
chart deploy / public-edge probe green). Only the final `lifecycle`
validation (full `rke2 delete --cascade` + RKE2 reinstall +
helm-from-scratch cycle) failed, blocked by intermittent quay.io
502/504 outages on the `minio/mc:RELEASE.*` image manifest. Not a
Sprint 3.13 code issue; re-exercising when quay.io stabilizes is
the residual.

**2026-05-31 (still later still) — Sprint 3.13 chunk 16 lands: gateway event-key
cache fully migrated, `.prodbox-state/` writers entirely gone from source.**

Chunk 16 closes the final piece of the host-side cache eradication. The
gateway per-node event-key cache (`.prodbox-state/<ns>/.gateway-event-keys.json`)
is gone; the daemon's own startup loop self-bootstraps a `gateway-event-keys`
k8s Secret in its own namespace right after acquiring the master seed.

- `Prodbox.Secret.Inventory.derivedSecretInventoryFor` adds `(gateway,
  gateway)` writing `gateway-event-keys` with three `NODE_<X>_EVENT_KEY`
  fields derived via `gatewayEventKeyContext` (master-seed-derived).
- New `Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets`: called right after
  `acquireInitialMasterSeed`, loads in-pod ServiceAccount credentials,
  constructs the TLS-backed K8s API client, applies own (gateway, gateway)
  inventory. All failures degrade gracefully (no seed → skip; outside k8s
  → skip + diagnostic; RBAC missing → log + continue).
- `charts/gateway/values.yaml::rbac.targetNamespaces` extends to include
  `gateway` so the daemon's ServiceAccount can write to its own namespace.
- `charts/gateway/templates/configmap-config.yaml` reads via Helm `lookup`
  of `gateway-event-keys` Secret; renders `event_keys` list directly from
  the three NODE_<X> fields. Empty fallback on `helm template`.
- `resolveGatewayEventKeys` + `resolveOrGenerateStringMap` +
  `writeGeneratedMap` + `mergeRequiredKeys` + `writeStringMap` +
  `readStringMap` + `chartStateRootRelative` + `chartStateDir` +
  `ensureChartStateDir` + `repairChartStateDir` + `randomHexString` +
  `byteToHex` all deleted. Callers in `CLI/Charts.hs` +
  `Lib/ChartPlatform.hs` pass `Map.empty` for the (now-vestigial)
  `gatewayEventKeys` parameter.
- `renderRetainedStateNotice` no longer mentions `.prodbox-state` —
  nothing under it is preserved by the supported lifecycle any more.

**Sprint 4.18's `forbidDotProdboxState` lint broadens** in the same chunk:
the scan needle widens from the closed `.secrets.json` filename to the
whole `.prodbox-state/` prefix; one new unit test pins the broader
contract. After chunk 16 a grep for `.prodbox-state` in `src/`+`app/`
string literals returns zero hits (only comments mention it for
historical context). The lint now refuses **any** new `.prodbox-state/`
write path in production source.

Validated on all 7 gates: build, `prodbox check-code` exit 0, `prodbox
test unit` **631/631**, `prodbox test integration cli`/`env` exit 0,
`prodbox lint docs` / `docs check` exit 0; `helm template` renders cleanly
for the gateway chart.

Sprint 3.13's code-owned surface is **fully closed** with chunk 16. The
live four-block preserved-data exercise remains the operator-driven
full-sprint closure gate.

**2026-05-31 (still later) — Sprint 4.18 `forbidDotProdboxState` lint lands.**
With every chart-secret cache writer gone (Sprint 3.13 chunks 8–14), the
narrow `checkForbidDotProdboxState` scan in `Prodbox.CheckCode` is wired
into `haskellStyleViolations`: it sweeps `src/` + `app/` Haskell string
literals (via `extractStringLiterals`) for the closed `.secrets.json`
filename, with `CheckCode.hs` allowlisted as the lint's self-reference
host and `test/` allowlisted for legitimate regression coverage.
Diagnostic names Sprint 3.13 chunks 8–14 as the closure rationale. Three
new unit tests pin the regression-resistance contract (fires on
offending literal; ignores comments; returns `[]` on the current repo
baseline). 630/630 unit tests pass.

Sprint 3.13's gateway per-node event-key cache
(`.prodbox-state/<ns>/.gateway-event-keys.json` via
`resolveGatewayEventKeys`) is **deliberately carved out** of this lint:
the doctrine intends those keys to flow through the daemon's
`ensure-namespace` handler too, but the bootstrap pattern has a
chicken-and-egg (the daemon Pod that materializes its own secrets is
the very same daemon the chart's pre-install Job would POST to). A
future chunk extends the daemon's startup loop with a self-bootstrap
(granting the daemon's ServiceAccount write access to its own namespace
via `rbac.targetNamespaces`); after that lands, the lint broadens to
refuse any `.prodbox-state/` write path. Documented as a deferred entry
in `Prodbox.Secret.Inventory`.

**2026-05-31 (later session) — Sprint 3.13 chunks 9 + 10 + 11 + 12 + 13 + 14
land: every host-side `.prodbox-state/charts/<ns>/.secrets.json` writer is
gone; OAuth client secrets + demo-user password + SES SMTP credentials all
flow through k8s Secrets (daemon-applied or kubectl-applied) and chart
templates read them via Helm `lookup`.**

- **Chunk 9**: `Prodbox.UsersAdmin.loadKeycloakAdminPassword` reads the
  daemon-applied `keycloak-runtime` Secret via `kubectl get secret`. The
  `.prodbox-state` read-path is gone.
- **Chunk 10**: `Prodbox.Infra.AwsSesStack.persistKeycloakSmtpChartSecrets`
  kubectl-applies the `keycloak-smtp` Secret with all seven `KC_SMTP_*`
  fields + `helm.sh/resource-policy: keep`. Chart's `keycloak-smtp` Secret
  rendering removed (sole-owner kubectl). `configmap.yaml`'s `smtpServer`
  block uses Helm `lookup`. `mergeChartSecretsFile`/`readChartSecretsFile`/
  `chartSecretsPrettyConfig` deleted.
- **Chunk 11**: extended `Prodbox.Secret.Derive` with `oidcClientSecretContext`
  and `keycloakDemoUserContext`; refactored
  `Prodbox.Secret.Inventory.DerivedSecretEntry` to carry
  `derivedSecretEntryDerivedFields :: [(Text, Text)]` so the daemon writes
  one `keycloak-oidc-clients` Secret with four derived fields atomically.
  `applyDerivedSecrets` derives every field + merges static fields into the
  manifest. `configmap.yaml` realm-import + `charts/vscode/templates/http-route.yaml`
  + `charts/websocket/templates/configmap-config.yaml` all read OAuth secrets
  via Helm `lookup` (cross-namespace for vscode/websocket from keycloak).
- **Chunk 12**: `resolveChartSecrets` reduced to `pure (Right Map.empty)`.
  `requireMapValue`, `requiredChartSecretKeys`, `recoverPatroniSecretValues`,
  `mergeChartSecretValues`, `readSharedKeycloakSecretValues` deleted.
  `valuesForKeycloak`/`KeycloakPostgres`/`Vscode`/`Websocket` drop every
  `requireMapValue` call and the corresponding chart-value override; charts
  now read all migrated fields via Helm `lookup`.
- **Chunk 13**: `.patroni-anchor-volume` marker file deleted. Anchor PV
  derives from live k8s state via `discoverPatroniAnchorPersistentVolumeName`
  (Patroni primary endpoint). Post-install marker-write hook becomes a
  documented no-op.
- **Chunk 14**: `shouldResetPatroniStorage` deleted (sole caller was the
  now-gutted `resolveChartSecrets`). `patroniClusterStatusIndicatesFailure` +
  `patroniStorageExists` + `requiredKeysPresent` + `requiredKeyPresent` +
  `readOptionalSecretPassword` + `writePatroniResetMarker` +
  `patroniResetMarkerFileName` all removed. `resetPatroniStorageIfRequested`
  reduces to `pure (Right ())` since marker is never written. The spec's
  prescribed loud-failure mismatch check (derive vs `pg_authid` probe) is
  deferred to the live four-block exercise that drives the failure paths.

Validated on all five static gates: `prodbox check-code` exit 0,
`prodbox test unit` 628/628, `prodbox test integration cli`/`env` exit 0,
`prodbox lint docs` / `docs check` exit 0; `helm template` renders cleanly
for keycloak, keycloak-postgres, vscode, websocket.

After this batch the only remaining `.prodbox-state/*` writes in source come
from the gateway per-node event-key cache (`.gateway-event-keys.json` via
`resolveGatewayEventKeys`). That cache is out-of-scope for Sprint 3.13's
static doctrine inventory — the daemon's `ensure-namespace` handler is meant
to inject gateway event keys dynamically from the live node inventory. A
follow-on chunk extends the daemon Inventory with the dynamic-injection
path and removes the host-side cache; Sprint 4.18's `forbidDotProdboxState`
lint waits on that closure. The live four-block preserved-data exercise
remains the full-sprint closure gate (operator-driven).

**2026-05-31 — Sprint 3.13 chunk 8 lands: chart-vs-daemon multi-writer race
closed for data-bound Secrets.** Pre-chunk-8, chunks 1–7 had wired the daemon's
pre-install Job to write the master-seed-derived `KEYCLOAK_ADMIN_PASSWORD` and
the three Patroni `password` fields, but the chart's `secret.yaml` (keycloak)
and `00-secrets.yaml` (keycloak-postgres) also rendered those same Secret
names via `--set`-injected `chartSecrets` values — and Helm's apply runs
**after** the pre-install hook completes, so helm silently overwrote the
daemon's derived value with the chart's random/file-cache value. The whole
derivation pipeline was structurally inert. Chunk 8 fixes this:

- `charts/keycloak/templates/secret.yaml` no longer renders `keycloak-runtime`
  (daemon is sole writer of `KEYCLOAK_ADMIN_PASSWORD`). The `keycloak-smtp`
  Secret block is unchanged pending the SES migration chunk.
- `charts/keycloak/templates/deployment.yaml` reads `KEYCLOAK_ADMIN` as a
  literal env var (`value: "admin"` from `.Values.keycloak.adminUser`);
  `KEYCLOAK_ADMIN_PASSWORD` continues to read from the daemon-applied
  `keycloak-runtime` Secret via `secretKeyRef`. The admin username (non-secret)
  is split from the derived admin password (data-bound).
- `charts/keycloak-postgres/templates/00-secrets.yaml` removed entirely — the
  daemon's pre-install Job is the sole writer of the three Patroni Secrets the
  Crunchy operator watches (`prodbox-keycloak-pg-pguser-keycloak` / `-pguser-postgres`
  / `-primaryuser`).
- `Prodbox.Secret.Inventory.DerivedSecretEntry` extends with
  `derivedSecretEntryStaticFields :: [(Text, Text)]` so the daemon writes the
  per-role static `username` field alongside the HMAC-derived `password` in
  each Patroni Secret atomically. Required because the Crunchy operator
  demands both `username` and `password` in each Secret it watches.
- `Prodbox.Secret.EnsureNamespace.applyDerivedSecrets` merges static fields
  into the manifest body so the daemon's PUT writes both atomically.
- 2 new unit tests in `test/unit/Main.hs` (static-fields shape + Patroni
  manifest contains `username`); the stale chart-secret render test rewritten
  to assert daemon delegation; the stale `awsTestMain shouldContain "publicKey:"`
  assertion updated to the Sprint 4.18 chunk-6 reality (`tls:PrivateKey` +
  `ssh_private_key:` outputs).

Validated: `prodbox check-code` exit 0; `prodbox test unit` 628/628;
`prodbox test integration cli` / `env` exit 0; `prodbox lint docs` /
`docs check` exit 0; `helm template keycloak charts/keycloak` and
`helm template keycloak-postgres charts/keycloak-postgres` both render
cleanly. This chunk-8 snapshot is superseded by the later Sprint 3.13
closure recorded in the Phase Overview: chunks 9–33 removed the remaining
OAuth, demo-user, SMTP, Patroni marker, and gateway-event-key cache paths,
and the live four-block preserved-data exercise closed on 2026-06-01.

**2026-05-31 — Plan-suite doc-sync brings README and 00-overview into agreement
with the phase-doc truth.** The phase docs had drifted ahead of the live tracker over
the May 28–30 commit dump: README's Phase 2 row still showed Sprint 2.19 as 🔄 even
though `phase-2-gateway-dns.md` had marked it ✅ Done after the May 30 live closure on
home substrate (run #6: master_seed_ready, gateway-minio-creds + MinIO user stay in sync
across delete+reconcile cycles via the 3-part fix). README's Phase 3 row didn't mention
Sprint 3.13 at all even though seven code chunks had landed 2026-05-30. README's Phase 4
row's Sprint 4.18 description still listed save/load/clear callsite removal +
withEksKubeconfig bracket + Pulumi-stored SSH private-key output as "Remaining" even
though chunks 3, 4, 5, 6 all landed across 2026-05-27 and 2026-05-30. Sprint 4.23 was
absent from the Phase 4 row. Sprints 7.9 + 7.10 were absent from the Phase 7 row.
`00-overview.md` still called Sprint 2.19 "Active". Doc-sync landed: Sprint 2.19 marked
✅ Done with the live closure summary in both README + 00-overview; Sprint 3.13 added
to the Phase 3 row with the full chunk inventory; Sprint 4.18 row condensed to reflect
six landed chunks with `forbidDotProdboxState` lint named as the sole remaining code
item (blocked on Sprint 3.13); Sprints 4.23, 7.9, 7.10 added to their phase rows.

The doc-sync is the first half of the **"proceed in order through open phases, completing
and validating each phase before starting the next"** directive. The second half — closing
the residual Active sprints — turns out to require *only* live operator exercises in every
remaining case: Sprints 2.21/2.22 (live RKE2 reconcile + ConfigMap edit + DNS write);
3.13 (four-block preserved-data exercise after the host-side `resolveChartSecrets`
rewrite); 3.14 (live charts deploy api/websocket); 4.10/4.13/4.17 (live AwsSesStack
migrate, live nuke, live cascade against running AWS cluster); 4.18 (blocked on 3.13's
chart-secret cache closure); 7.5.c.v + 7.8 (live `prodbox test all --substrate aws`
roll-up); 8.5 (now local POST/OIDC code + unit proof, with live substrate validation
remaining) + 8.6 (blocked on live 8.5 + AWS aggregate). The only code-side work that could be attempted in this session —
Sprint 3.13's host-side `resolveChartSecrets` rewrite — is high-risk (it gut-rewrites
the chart-deploy secret-injection pipeline + cascades through `shouldResetPatroniStorage`
and the chart-secret value flow) and cannot be safely validated without the live
preserved-data exercise, so it is deferred to a dedicated session where the live closure
gate can run end-to-end. Doc-sync gates green: `prodbox check-code` exit 0;
`prodbox test unit` exit 0; `prodbox test integration cli`/`env` exit 0;
`prodbox lint docs` exit 0; `prodbox docs check` exit 0.

**2026-05-29 — Two leak-critical lifecycle fixes landed for the May 28/29
`DependencyViolation` incidents (Sprint 4.23 + Sprint 7.10).** A live `prodbox test all` run
twice leaked AWS resources when the per-run `aws-eks-test` Pulumi destroy hit
`DependencyViolation: subnet … has dependencies and cannot be deleted` (orphan ENIs from the
EKS cluster lagging async cleanup) after a 20-minute wait. Two independent gaps caused the leak,
each now closed:

- **Sprint 4.23 (root cause, ✅ Done on the code-owned surface):** the per-run EKS destroy
  path did not drain the EKS cluster's AWS-affecting K8s resources before `pulumi destroy`, so it
  raced AWS's ENI cleanup. `src/Prodbox/Infra/AwsEksTestStack.hs::destroyAwsEksTestStackStatus`
  now calls the new best-effort helper `drainAwsEksClusterBeforeDestroy` (deleting LoadBalancer
  Services, ALB Ingresses, and Delete-reclaim PVCs via the per-run EKS cluster's own kubeconfig)
  immediately before the `pulumi destroy`, reusing
  `Prodbox.Lifecycle.K8sDrain.drainAwsAffectingK8sResources` and a new `buildAwsEksDrainEnv`
  helper mirroring `Rke2.buildDrainEnvironment`. Both the harness postflight
  (`prodbox pulumi eks-destroy --yes`) and the cascade
  (`ResourceRegistry.reconcileAbsent` → `PulumiEksDestroy`) route through this destroy, so the
  injection covers both. Best-effort + safe-on-unreachable: an absent kubeconfig or unreachable
  cluster skips the drain with a diagnostic and proceeds; a drain failure/timeout never hard-fails
  the destroy. Extends Sprint 4.17.b's cascade drain to the per-run destroy path. The live
  closure gate (a `prodbox test all` whose per-run `aws-eks-test` destroy succeeds without
  `DependencyViolation`) is deferred (flaky live-AWS ENI-cleanup timing, not fast-gate-validatable).
- **Sprint 7.10 (amplifier, ✅ Done):** the harness postflight cleared operational `aws.*` +
  deleted the operational `prodbox` IAM user **even when the per-run auto-destroy failed**,
  stranding the orphaned stacks without the operational creds needed to destroy them on retry.
  `src/Prodbox/TestRunner.hs::runWithAwsHarnessCleanup` now runs the operational-credential
  teardown only when the per-run destroy succeeded, gated by the new pure helper
  `clearOperationalCredsAfterPostflight :: ExitCode -> Bool` (`True` iff `ExitSuccess`). On a
  per-run destroy failure the teardown is held, operational `aws.*` + the operational user are
  preserved, and a diagnostic names the recovery path (`prodbox pulumi <stack>-destroy --yes`
  after resolving the destroy failure, then `prodbox aws teardown`). Applies on both the normal
  and async-exception (Ctrl-C) paths; the per-run destroy failure is still surfaced as a non-zero
  exit. This is the per-run analog of Sprint 7.9: 7.9 stopped the teardown from *refusing* on
  admin-managed `aws-ses`; 7.10 *holds* the teardown when the per-run auto-destroy (which needs
  operational creds) failed. New `Sprint 7.10` unit-test describe block (2 tests).

Both validated on the fast gates: `check-code` 0; `test unit` all pass (+2, the `Sprint 7.10`
group); `test integration cli`/`env` exit 0; `docs check`/`lint docs` 0.

**2026-05-29 — Sprint 7.9 landed on the code-owned surface: harness postflight teardown
no longer gates on admin-managed `aws-ses`.** A one-line policy swap in
`src/Prodbox/Aws.hs::runAwsIamHarnessTeardown` (`BypassPerRunResidueOnly` →
`BypassAllResidueForHarnessRefresh`) closes an operational-user stranding bug: every
`prodbox test all` run with the long-lived `aws-ses` stack alive (its retained-by-design
steady state) previously ended with the postflight **refusing** to clear operational
`aws.*`, stranding the freshly-created operational `prodbox` IAM user. The Sprint 7.7
refusal was correct only pre-Sprint-4.10, when `aws-ses` was operationally credentialed;
Sprint 4.10 moved `aws-ses` to admin creds (`aws_admin_for_test_simulation.*`), and Sprint
7.5.c.v.c fixed the *preflight* the same way but deliberately left the postflight stale.
Sprint 7.9 finishes the reconciliation; the postflight now matches the preflight and clears
`aws.*` + deletes the operational IAM user unconditionally with respect to Pulumi residue
(per-run stacks are destroyed separately by `awsPostflightDestroyActions`; `aws-ses` is
admin-managed so it cannot be stranded). The `BypassPerRunResidueOnly` constructor is
retained as a valid ADT member (still refuses on long-lived residue) but has no production
caller — tracked in `legacy-tracking-for-deletion.md` `Pending Removal`. New pure SSoT
helper `harnessPostflightResiduePolicy` + a `Sprint 7.9` unit-test describe block.
Validated: `check-code` 0; `test unit` all pass; `test integration cli`/`env` exit 0;
`docs check`/`lint docs` 0. Separate deferred follow-on (NOT addressed here): the lost
`aws-ses` Pulumi state (long-lived S3 backend bucket missing) leaving `aws-ses`
Pulumi-unmanageable until re-imported/re-provisioned. Later Phase `8` follow-up work closes
that state-loss recovery by importing retained SES/S3/IAM resources during `aws-ses-resources`.
Live `prodbox test all --substrate aws` roll-up remains the closure gate.

**2026-05-28 — Sprint 4.22 follow-on landed: create-call-site coverage lint.** The
second half of the § 3.1 totality enforcement is now in `check-code`: a new
`checkCreateCallSiteCoverage` scan (in `src/Prodbox/CheckCode.hs`, wired into
`haskellStyleViolations`) complements the already-landed registry ↔ doc parity. It is
**deliberately narrow** to avoid the false-positive risk that originally deferred it,
covering only the two surfaces where `prodbox` actually originates a new AWS/cluster
resource: (1) every `Pulumi<Word>Resources` constructor in `src/Prodbox/CLI/Command.hs`
must map (via the explicit `pulumiCreateSiteOwners` table) to a registered
`PerRun`/`LongLived` stack name (pure `pulumiCreateSiteViolations`); (2) the
operational-IAM creation verbs `create-user` / `create-access-key` / `put-user-policy`
(`iamCreateVerbs`) may appear only in the `operational-iam-user` owner module
`src/Prodbox/Aws.hs` (pure `iamCreateSiteViolations`). Broader generic-`create*` /
`change-resource-record-sets` / `create-bucket` scanning is **explicitly excluded** (those
resources are Pulumi-managed or specially-handled bootstrap operations). Together with the
registry ↔ doc parity this **completes** the § 3.1 totality enforcement (registry ↔ doc
parity + create-site coverage). Validation: `prodbox check-code` exit 0 (zero new
violations on the current tree); `prodbox test unit` 600/600 (+6, new `Sprint 4.22
create-call-site coverage lint` group); `prodbox test integration cli` 30/30; `prodbox
test integration env` 30/30.

**2026-05-28 — Phase 4 managed-resource-registry sprints (4.20–4.22) landed +
validated.** Sprint 4.21 added the IO `Prodbox.Lifecycle.ResourceRegistry`
(`ManagedResource` + `perRunManagedResources` + the pure `pairPerRunResidue` /
`resourcesToDestroy` helpers + the `reconcileAbsent` reconciler) and routed
`runNativeDeleteCascade`'s per-run destroy phase through it as a behavior-preserving
refactor (same `PulumiCommand`s, same canonical order, same narration; the old
`perRunCascadeInventory` removed). The default `rke2 delete` / `aws teardown` stay
refuse-gates (4.19/4.20); `reconcileAbsent` is the active-destroy engine, adopted in the
cascade here and in `aws teardown --destroy-pulumi-residue` / `nuke` in Sprint 7.8. Sprint
4.22 made the `substrates.md` Resource Lifecycle Classes inventory a generated section
rendered from `resourceLifecycleClasses`, so `prodbox docs check` fails the build on
registry↔doc drift (the create-call-site coverage lint follow-on landed the same day — see
the dated note above). Validation across 4.20–4.22: `prodbox check-code` exit 0; `prodbox test unit`
585/585; `prodbox test integration cli` 30/30; `prodbox test integration env` 30/30;
`prodbox docs check` / `lint docs` exit 0; plus a live `prodbox rke2 delete --cascade --yes`
smoke on this host (clean exit 0, the rewired cascade's `reconcileAbsent` skip-path
confirmed). The present→destroy cascade path's full live exercise and the Sprint 7.8
operational-credential adoption roll up with the next operator-driven AWS-substrate cascade
run. **Phase 4 is now Done on its code-owned surfaces** (Sprints 4.1–4.22), with the
residual live operator gates (AWS-substrate cascade, `nuke`, AwsSesStack migrate-backend)
tracked per-sprint.

**2026-05-28 — Sprint 4.20 landed (registry foundation).** The first code chunk of the
managed-resource-registry doctrine: new low-level `Prodbox.Lifecycle.ResourceClass` holds
the SSoT facts (`LifecycleClass = PerRun | LongLived | Operational` + the
`resourceLifecycleClasses` list, including the two now-registered operational classes);
`Prodbox.Aws.perRunStackNames`/`longLivedResourceNames` (then `longLivedStackNames`, renamed by
Sprint `4.27`) are **derived** from it (a unit test
asserts they equal the prior literals); and a single soundness combinator
`Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate` ("present OR unreachable →
block") replaces the per-class `isResiduePresentOrUnknown{PerRun,LongLived}` booleans
(removed), with `categorizePulumiResidue` and `noLiveLongLivedPulumiStacks` migrated to it.
Behavior-preserving (no teardown-behavior change — the registry is not yet wired into a
reconciler; that is Sprint 4.21), so it closes on static gates: `prodbox check-code` exit 0,
`prodbox test unit` 583/583, `prodbox test integration cli` 30/30, `prodbox test integration
env` 30/30. The IO `ManagedResource` record + `reconcileAbsent` reconciler move to Sprint
4.21 (so the discover/destroy closures land with their first consumer rather than as dead
code, and the per-run port-forward batching is preserved); the legacy-ledger rows for the
retired booleans + hand-maintained stack lists moved to `Completed`.

**2026-05-28 — Managed-resource-registry doctrine adopted; Phase 4 extended,
Phase 7 reopened.** The recurring leak/edge-case failures (orphan IAM, silent-pass
teardown, stale operational `aws.*`, the operational `prodbox` user surviving an
interrupted run) were diagnosed not as a missing global state machine but as two
structural gaps in the existing reconciler-with-predicates doctrine: **fail-open
predicates** (an `Unreachable` discover silently treated as "clean") and **incomplete
coverage** (resources prodbox can create with no registered discover/destroy). A
global state machine was deliberately rejected (it would still rely on the same
unsound discovers and go stale against external authoritative state; the existing
doctrine's reasoning holds). The chosen fix is a **typed managed-resource registry** —
the SSoT for "everything prodbox can create, and how to observe and destroy it" — over
which teardown is one idempotent `reconcileAbsent` reconciler, with `Unreachable`
never silently passing and `check-code` making "a creatable-but-undiscoverable
resource" structurally unrepresentable. The doctrine SSoT is
[lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).
It is scheduled — code not yet landed — as **Phase 4 Sprints 4.20** (registry
foundation + soundness), **4.21** (`reconcileAbsent` + `rke2 delete`), **4.22**
(`check-code` totality + the `substrates.md` Resource Lifecycle Classes table as a
generated section), and **Phase 7 Sprint 7.8** (operational IAM user + `aws.*` config
creds registered; `aws setup`/`teardown` re-expressed as registry reconciliations).
**Sprint 7.8's operational-coverage core landed 2026-05-28**: the registry now covers
the operational IAM user and the operational `aws.*` config block, and
`prodbox aws teardown` reconciles them through `reconcileAbsent` with operational
`Unreachable` failing closed (a dedicated gate refuses rather than letting the cascade
graceful-degradation skip an unobservable operational resource). The broader
`PerRun` ∪ `Operational` merge of the teardown path and the live `test all` roll-up
remain tracked follow-ons — status Active, not Done, on the code-owned surface.
**Phase 7 reopened** for Sprint 7.8 because the registry changes its owned
`aws setup`/`teardown` command surface; **Phase 1 stays Done** (the registry is built
on its `Plan`/Apply, Effect DAG, and capability-class foundations, not a change to
them); Phases 5 and 6 and the rest of Phase 7 remain closed on their owned surfaces.
The registry **generalizes** the existing Phase 4 reconciler work — Sprint 4.11
(predicate library), 4.16 (ResidueStatus source-of-truth), and 4.19 (fail-closed
gate) become instances of one pattern and stay `Done`; nothing earlier is
contradicted. No global state machine, no per-run state migration to S3, no
AWS-name-scanning detector, no auto-sweep (all explicitly out of scope — the registry
surfaces and reconciles leaks, it does not hide them).

**2026-05-28 — Live IAM-orphan sweep + operator cleanup (Sprint 4.19 follow-up).**
After a `prodbox rke2 delete --yes`, a manual read-only AWS sweep (admin creds,
`us-west-2` + `us-east-1` + global) found the per-run leak confined entirely to
**IAM** — no orphan EKS clusters, EC2 instances, VPCs, ELBs, NAT gateways, EIPs,
EBS volumes, or OIDC providers in either region. The IAM orphans, accumulated
across several runs (dated 2026-04-25 → 2026-05-28): managed policy
`aws-eks-test-aws-lb-controller` (0 attachments); roles `clusterRole-6a4fdb3`,
`nodeRole-05d81e0`, `nodeRole-f28de65`; and the operational `prodbox` IAM user with
an active access key + `prodbox-inline` policy. All were removed via the bounded
operator escape hatch (targeted `aws iam` deletes); a re-sweep confirmed only the
intentionally-retained `prodbox-admin-temp`, `prodbox-ses-smtp`, and the
operator-owned `resolvefintech.com` Route 53 zone remain. **Why it was IAM-only and
undetected:** the postflight tag sweep queries the AWS Resource Groups Tagging API,
which does not return IAM resources; combined with the (now-fixed)
silent-pass-on-unreachable delete gate, IAM orphans from partial/diverged runs
accumulated unnoticed. Current doctrine keeps broad IAM name scanning forbidden, but
the harness preflight now owns the exact fixed-name `aws-eks-test-aws-lb-controller`
policy/role and `aws-eks-test-ebs-csi-driver` role when the authoritative
`aws-eks-test` Pulumi checkpoint is absent. See
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)
and [substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

**2026-05-28 — Sprint 4.19: `rke2 delete` fails closed when per-run Pulumi
state is unreachable.** Root-caused from a live incident: `prodbox rke2 delete
--yes` reported a clean per-run AWS teardown and let the operator proceed to the
documented `rm .data`, even though live `aws-eks` resources still existed. The
defect was in the per-run delete **gate** (`noLivePerRunPulumiStacks`): it
treated `ResidueUnreachable` (in-cluster MinIO state backend unreachable — e.g.
MinIO pod down on a degraded cluster, while the per-run state sat intact on
`.data/`) the same as `ResidueAbsent` and passed silently. The fix realigns
`isResiduePresentOrUnknownPerRun` to fail closed on unreachable and branches the
gate on the `ResidueStatus` constructor so the unreachable case gets a distinct,
actionable refusal ("cannot read the per-run Pulumi state backend … do NOT delete
`.data/` until confirmed destroyed … or re-run with `--allow-pulumi-residue` to
accept the orphan risk"). `aws teardown`'s residue check gets the same fail-closed
treatment. The `--cascade` path is unchanged — its own `perRunCascadeInventory`
deliberately keeps graceful degradation (cluster torn down regardless; postflight
tag sweep backstop); the gate-vs-cascade asymmetry is now documented in
`lifecycle_reconciliation_doctrine.md` §3. No live-AWS scanning, no orphan sweep,
no per-run state migration to S3 (all explicitly out of scope). Validation:
`prodbox check-code` exit 0; `prodbox test unit` 578/578; `prodbox test
integration cli` 30/30 (two new tests: unreachable per-run backend → `rke2 delete
--yes` exits non-zero with the refusal and does not claim clean; `--allow-pulumi-residue`
still proceeds); `prodbox test integration env` 30/30. Live operator verification on
this host is the residual gate. See
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) Sprint 4.19.

**2026-05-27 (later session) — Sprint 4.18 third chunk lands; live
validation running.** The two per-run stacks the home `prodbox test all`
exercises (`aws-eks-test`, `aws-test`) drop their on-disk snapshot cache
entirely. New `fetchAwsEksTestSnapshotFromBackend` /
`fetchAwsTestSnapshotFromBackend` read the stack snapshot live from the
in-cluster MinIO Pulumi backend (via `fetchPerRunStackOutputs` + the pure
parsers, including a new full-snapshot `parseAwsTestStackFromOutputs`),
returning the same `Maybe <Snapshot>` the file cache used to so the
destroy and residue-assertion logic is behavior-preserving (precise
per-resource check pre-destroy; tag-scan fallback on absent/unreachable).
Every internal `loadXxxStackSnapshot` consumer is migrated; all
`saveXxxStackSnapshot` / `clearXxxStackSnapshot` callsites and the file-IO
helpers (`save`/`load`/`clear`, `<stack>SnapshotPath`, `snapshotToJson` /
`snapshotFromJson` / `nodeToJson`, EKS `optionalString`) are removed. The
unit round-trip test that exercised `save`/`load` is replaced by two
`parse*FromOutputs` round-trips over the flat `Map Text Text` backend
shape. Static gates green: `prodbox check-code` exit 0; `prodbox test
unit` 575/575; `prodbox test integration cli` 28/28; `prodbox test
integration env` 28/28. The live closure gate — `prodbox test all` on the
home substrate, which provisions/destroys the `aws-eks-test` and
`aws-test` stacks through the migrated code — is in progress on this host.
Remaining Sprint 4.18 work: the same migration for `aws-eks-subzone` /
`aws-ses` (validated by the AWS-substrate run / explicit `aws-ses-destroy`),
the `withEksKubeconfig` bracket, the Pulumi-stored SSH private key, and the
`forbidDotProdboxState` lint (after Sprint 3.13).

**2026-05-27 (later session) — Sprint 4.18 second chunk lands.** Three more
code-owned consumers move off the file-based `loadXxxStackSnapshot` adapter
onto the live `fetchPerRunStackOutputs` read introduced by the first
2026-05-27 chunk: `verifyAwsTestSnapshot`, `verifyAwsTestSshReachability`
(sharing a new `fetchAwsTestNodes` helper), and
`ensureAwsSubstratePlatformRuntime` in
`src/Prodbox/Lib/AwsSubstratePlatform.hs`. Two new pure parsers
(`Prodbox.Infra.AwsTestStack.parseAwsTestNodesFromOutputs` and
`Prodbox.Infra.AwsEksTestStack.parseAwsEksTestStackFromOutputs`) decode the
flat `Map Text Text` returned by `fetchPerRunStackOutputs` into structured
records. `fetchPerRunStackOutputs` gains a test-only
`PRODBOX_TEST_PER_RUN_OUTPUTS_DIR` override so the unit suite can exercise
the migrated consumers without a live MinIO port-forward; the existing
`native validation helpers` SSH-retry test is rewritten to inject the
`nodes` output through that override instead of writing
`.prodbox-state/aws-test/stack-snapshot.json`. 7 new unit tests pin the
parsers' happy paths plus missing-field / non-JSON / wrong-shape failure
modes. Validation: `prodbox check-code` exit 0; `prodbox test unit`
574/574 (up from 567); `prodbox test integration cli` 28/28;
`prodbox test integration env` 28/28. Remaining Sprint 4.18 work
(removing the surviving `saveXxxStackSnapshot` / `clearXxxStackSnapshot`
callsites, replacing `awsEksTestKubeconfigPath` with a `withEksKubeconfig`
bracket, replacing the local SSH-keygen surface with a Pulumi-stored
private-key output, and landing the `forbidDotProdboxState` lint) is
unchanged and remains tracked in
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
Sprint 4.18.

**May 28, 2026 — AWS-substrate cascade `DependencyViolation` failure exposes
doctrine-vs-code inversion in `prodbox rke2 delete --cascade --yes`.**
A live cleanup attempt on Bathurst (Phase 7's AWS-substrate residue from
killed `prodbox test all --substrate aws` runs) failed mid-way through the
per-run Pulumi destroy phase with:

```
aws:ec2:Subnet publicSubnet1 deleting (1200s) error:
DependencyViolation: The subnet 'subnet-00db2adeb400ca61f' has dependencies
and cannot be deleted
```

Root-cause analysis identified two independent issues that share the same
fix shape, both originating in the original Sprint 4.17 cascade-order
landing (May 23, 2026):

1. **Cascade phase order inverted vs. doctrine canonical order.** The
   doctrine §1 prose at
   [`lifecycle_reconciliation_doctrine.md`](../documents/engineering/lifecycle_reconciliation_doctrine.md)
   states "the drain runs **before** any Pulumi destroy so the controllers
   are still alive to unwind their AWS-side state." However the doctrine
   §5b table that Sprint 4.17 added (and that the code implements)
   inverted the order to `destroys → drain`. On the home substrate the
   inversion is harmless because no in-cluster controllers create AWS
   resources; on the AWS substrate the inversion is fatal because AWS Load
   Balancer Controller + EBS CSI driver are alive on the EKS cluster when
   per-run destroys begin, leaving orphan ENIs that block subnet deletion.
   The doctrine §5b table and §1 prose are updated May 28, 2026 to require
   the canonical `drain → destroys` order; the code correction is
   scheduled as **Sprint 4.17.a** in
   [`phase-4-lifecycle-canonical-paths.md`](phase-4-lifecycle-canonical-paths.md).

2. **K8s drain phase hardcodes the local-cluster kubeconfig.**
   `src/Prodbox/CLI/Rke2.hs::runCascadeDrainPhase` (lines 840–855) sets
   `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` unconditionally. On the AWS
   substrate the drain consequently walks the local cluster's namespaces
   (which contain no AWS LoadBalancer Services / ALB Ingresses /
   Delete-reclaim PVCs), reports nothing to drain, and lets the per-run
   destroys hit the same `DependencyViolation` because the EKS-side
   controllers' ENIs are never released. The fix wraps the drain call in
   `Prodbox.PublicEdge.withSubstrateKubectlEnvironment` (already exported
   from `src/Prodbox/PublicEdge.hs` from earlier Sprint 7.5.c.v follow-up
   work) for `SubstrateAws`. Scheduled as **Sprint 4.17.b** blocked on
   Sprint 4.17.a so the substrate-aware drain runs in the doctrine-
   canonical position. The
   [`aws_integration_environment_doctrine.md` §5.5](../documents/engineering/aws_integration_environment_doctrine.md)
   section is added May 28, 2026 to document the substrate-aware drain
   requirement.

Both Sprints 4.17.a and 4.17.b landed code-side May 28, 2026 and are now
`Done` on their owned surfaces. `runNativeDeleteCascade` reorders to the
then-doctrine-canonical `confirm-MinIO → drain → per-run destroys → uninstall
→ sweep` with `cascadeOrderNarration` exposed as a stable test pin (5 new
unit tests pin the order); Sprint `4.40` later extends that order with the
test-EBS reaper between per-run destroys and uninstall. `runCascadeDrainPhase` now takes a `Substrate`
argument and builds a substrate-aware env-var list via new helper
`buildDrainEnvironment`; the cascade infers substrate from per-run
residue via new pure helper `inferCascadeSubstrate` (6 new unit tests
cover every substrate-inference combination). `DrainSkipped` on the AWS
substrate is now a hard failure with an explanatory message. Test count:
554/554 (up from 543). The corresponding rows in
[`legacy-tracking-for-deletion.md`](legacy-tracking-for-deletion.md) are
moved from `Pending Removal` to `Completed`. The
[`cli_command_surface.md`](../documents/engineering/cli_command_surface.md)
`prodbox rke2 delete --cascade` section is updated to document the
corrected phase order.

**Live verification on the home substrate closed May 28, 2026** with a
clean `prodbox rke2 delete --cascade --yes` run on the Bathurst host
after operator cleanup. The cascade narration emitted the then-canonical
`confirm-MinIO → drain → per-run destroys → uninstall → sweep` order
verbatim (Sprint `4.40` later inserts the test-EBS reaper before uninstall);
`inferCascadeSubstrate` correctly returned `SubstrateHomeLocal`
because no AWS per-run residue was present
(`aws-eks=absent, aws-eks-subzone=absent, aws-test=absent`); the local
RKE2 substrate was uninstalled cleanly with `.data/` preserved; the
postflight tag sweep reported `clean (no cluster-tagged or
prodbox-owned AWS residue)`. The orphan AWS resources from the May
27/28 in-flight runs (3 `aws-test-node-*` EC2 instances,
`aws-eks-test-vpc`, `aws-test-vpc`, the one orphan ENI in
`subnet-00db2adeb400ca61f`) were cleaned up by the operator-driven
procedure documented in the approved plan file, in dependency order:
terminate instances → delete orphan ENI → delete subnets → detach +
delete IGW → delete non-main route tables and non-default security
groups → delete VPCs. EBS volumes auto-deleted with the root-volume
flag on instance termination. Final AWS state: zero non-default VPCs,
zero EC2 instances, zero ENIs, zero ELBs, zero EKS clusters.

Live re-verification on the AWS substrate (full
`prodbox test all --substrate aws` cycle completes cleanly including
the cascade) remains the operator-driven closure gate for both Sprint
4.17.a and 4.17.b on the AWS path. The home-substrate gate is satisfied.

This is a distinct leak class from the May 27 "Pulumi state lost across
`rke2 delete + rke2 reconcile`" failure documented below — that produced
silent residue; this one produces a hard AWS API error mid-destroy. Both
share the structural root cause that the cascade had no path to drain
EKS-side K8s resources before destroying the EKS cluster.

The orphan AWS resources from the May 27/28 runs (3 `aws-test-node-*` EC2
instances, `aws-eks-test-vpc` + `aws-test-vpc` plus their orphan ENIs)
are tracked as operator-driven cleanup. The cleanup procedure is
operator-driven (`aws ec2 describe-network-interfaces` to identify ENI
holders, then targeted `aws elbv2 delete-load-balancer` /
`aws ec2 terminate-instances` / `aws ec2 delete-network-interface` /
`aws ec2 delete-subnet` / `aws ec2 delete-vpc` in dependency order). This
one-time deviation from CLAUDE.md's "harness is the exclusive AWS owner"
rule is the bounded escape hatch the doctrine doesn't currently provide
for cases where Pulumi state has diverged from live AWS state.

**May 27, 2026 — Phase 2/3 live-exercise progress (`prodbox test all` home substrate).**
Three latent code bugs surfaced by the live `prodbox test all` cycle on Bathurst and were
fixed in-session, restoring the canonical-suite path past the previous closure gates:

1. **`BS.readFile "/dev/urandom"` hang in
   `src/Prodbox/CLI/Rke2.hs::resolveGatewayMinioCredentials`** (Sprint 2.19 follow-up):
   `BS.readFile` reads until EOF, which never comes from the infinite character device, so
   `prodbox rke2 reconcile` blocked indefinitely on the gateway-minio credential bootstrap
   when the `gateway-minio-creds` Secret was absent. Fix: open the handle with
   `openBinaryFile` and `BS.hGet handle 34` to read exactly the 34 bytes the suffix +
   password derivation needs. Restored 28/28 integration cli/env passing (was 25/28 due to
   ZeroSSL, Percona-mirror, and `rke2 reconcile + delete` tests timing out at ~70s on the
   hung urandom read).
2. **UTF-8 decode failure in the gateway daemon Pod** (Sprint 2.20/2.22 follow-up):
   chart-rendered `config.dhall` contains `§` (`0xC2 0xA7`) in the Sprint 2.22 comment
   block, which fails Dhall decoding under the container's default C/POSIX locale.
   Fix: `setLocaleEncoding utf8` at the top of `src/Prodbox/App.hs::main`
   (defense-in-depth at the binary boundary), plus `ENV LANG=C.UTF-8` and
   `ENV LC_ALL=C.UTF-8` in `docker/gateway.Dockerfile` and `docker/prodbox.Dockerfile`
   (defense-in-depth at the container boundary). With this fix the three gateway daemon
   Pods (`gateway-node-a/b/c`) reach `Running 1/1` with 0 restarts and successfully emit
   `gateway_starting`, `orders_loaded`, `rest_server_listening`,
   `gateway_ownership_event_emitted`, `peer_listener_listening`, and
   `dns_write_succeeded` against the live Route 53 zone.
3. **`gateway-daemon` validation rendered JSON-format config** (Sprint 2.20 follow-up):
   `src/Prodbox/TestValidation.hs::renderGatewayValidationConfig` /
   `renderGatewayValidationOrders` still emitted JSON, which the post-Sprint-2.20 Dhall-
   only daemon decoder rejects with `Invalid input: unexpected '"'`. Fix: replace both
   renderers with `renderGatewayValidationConfigDhall` / `renderGatewayValidationOrdersDhall`
   emitting the canonical `{ schemaVersion = 1, boot = {…}, live = {…} }` shape that
   matches `Prodbox.Gateway.Settings.DaemonConfigDhall`; rename temp file extensions from
   `.json` to `.dhall`; drop unused `encode`/`object`/`.=` imports from `Data.Aeson`. New
   `dhallText` helper escapes string literals safely. The live re-run gate for the
   gateway-daemon validation remains.

The `prodbox test all` run-3 cycle (~1h32m) closed the Phase 2/3 live gates for every
non-gateway-daemon canonical validation on the home substrate. Validations recorded
`body exit=ExitSuccess` for `charts-vscode`, `charts-api`, `charts-websocket`,
`admin-routes`, `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, and
`ha-rke2-aws`. Only `gateway-daemon` failed, due to the JSON-config bug above.

**Run-4 (~1h35m) closed the gateway-daemon validation live too**, after the
JSON→Dhall fix landed. Final run-4 validation roll-up: every named canonical
validation on the home substrate recorded `body exit=ExitSuccess` —
`charts-vscode`, `charts-api`, `charts-websocket`, `admin-routes`, `public-dns`,
`dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, `ha-rke2-aws`, `gateway-daemon`,
`gateway-pods`, `gateway-partition`, `charts-platform`, `charts-storage`, and
`lifecycle` (the destructive `rke2 delete + rke2 reconcile` cycle inside one
run). The only failing validation was `keycloak-invite`, which is the documented
Sprint 8.5 follow-up that requires live Keycloak credential-setup form-structure
capture (operator-driven). Postflight cleared the operational `aws.*` block and
deleted the dedicated IAM user.

With run-4 closed, the home-substrate row in the Substrate Parity table below is
✅ full canonical suite less keycloak-invite. The remaining live closure work
narrows to: (a) Sprint 7.5.c.v's AWS-substrate canonical-suite re-run; (b)
Sprint 8.5/8.6's live OIDC form-structure capture; (c) Sprint 7.14's live
encrypted first-touch `aws-ses` migration/deletion proof; (d) Sprint 4.13's
operator-driven `prodbox nuke` total-teardown exercise; (e) Sprint 4.16's
live source-of-truth swap regression against MinIO/S3 backends. The home-
substrate Sprints 2.19/2.21/2.22/3.14/4.11/4.12/4.15/4.17 live gates are
satisfied on this host.

The master-seed acquisition on the live gateway daemon emits
`master_seed_unavailable` with a 403 from MinIO (the `prodbox-gateway-…` user can
authenticate but the master-seed object HEAD returns Forbidden). Per
[secret_derivation_doctrine.md §8](../documents/engineering/secret_derivation_doctrine.md),
the daemon falls back to structured-503 responses on `/v1/secret/derive` rather than
crashing — the contract is preserved. Full closure of Sprint 2.19 requires diagnosing
why the dedicated `prodbox-gateway` MinIO user does not have the HeadObject grant the
master-seed read needs and is tracked as a Sprint 2.19 follow-up.

**Run-5 (AWS substrate, ~50m) revealed the first hosted-zone-ID propagation gap on the
Sprint 7.5.c.v live path.** `prodbox test all --substrate aws` provisioned the
EKS cluster + Harbor + MinIO + Percona + Envoy Gateway + cert-manager + AWS LBC
+ workload charts and reached `CLASSIFICATION=ready-for-external-proof`, but the
first AWS-substrate canonical validation (`charts-vscode --substrate aws`) failed
because the just-provisioned subzone ID was not available to downstream validation
commands. That gap is now closed without violating the no-fallback doctrine:
the harness provisions the subzone first, and every child bootstrap and validation
command resolves the AWS hosted-zone id through
`PublicEdge.resolveSubstrateHostedZoneId` from `aws_substrate.hosted_zone_id` or the
live `aws-eks-subzone` Pulumi stack output. Sprint `7.13` removed the
`PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env var entirely (config_doctrine.md § 10 —
no `PRODBOX_*` config reads); `PublicEdge` is now scoped by `checkEnvVarConfigReads`.
Resolution still never falls back to the home `route53.zone_id`.

The postflight cleanup left residual AWS resources (`aws-eks-test-vpc`,
`aws-test-vpc`, and 3 `aws-test-node-*` EC2 instances) on the operator AWS account
after `prodbox pulumi eks-destroy --yes` and `prodbox pulumi aws-test-destroy --yes`
ran in the postflight sweep. This matches the file-existence residue-predicate
failure class that Sprint 4.16's source-of-truth swap is meant to close — when the
in-cluster MinIO backend's stack snapshot was lost across the rke2 wipe between
runs, the per-stack destroy reported "nothing to destroy" while the underlying AWS
resources persisted. The residue is recorded here as a known follow-up for Sprint
4.16's live closure rather than a regression in the destroy code.

**May 24, 2026 — Phase 0/1/2/3 reopened for the pure-Dhall config doctrine.** A new SSoT
[config_doctrine.md](../documents/engineering/config_doctrine.md) consolidates every
`prodbox` binary's configuration sourcing to a single Dhall file at `--config <path>`,
decoded in-process via the native Haskell `dhall` library. The reopen affects:
Phase 0 (Sprints 0.3, 0.4 revised in place + new Sprint 0.8 adopting the doctrine and
updating governed docs); Phase 1 (Sprint 1.2 revision note + new Sprint 1.28 covering
the `allow-newer` clauses for `dhall`'s transitive deps under GHC 9.12.4 plus the
env-var-read lint rule); Phase 2 (Sprints 2.9, 2.11, 2.12, 2.13, 2.15, 2.19 revised in
place + new Sprints 2.20/2.21/2.22 covering the daemon Dhall settings module,
file-watch reload trigger with drain-and-exit on boot-field changes, and chart-side
Dhall ConfigMap + Secret-mounted credentials); Phase 3 (new Sprint 3.14 covering the
`PRODBOX_WORKLOAD_MODE` env-var migration to Dhall). Phase 4's lifecycle-reconciliation
scope is unchanged by this reopen; a cross-reference line in phase-4 notes that daemon
Pods auto-restart on boot-field config changes. The superseded doctrine — SIGHUP-only
reload trigger, `PRODBOX_*` env-var precedence ladder, JSON daemon config rendering,
chart-side env-var-sourced daemon credentials, the `MINIO_ENDPOINT_URL` env-var
addition rolled back the same day — is moved to
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) per
`development_plan_standards.md §A` and §I. The closure gate for these reopen sprints is
the live exercise of file-watch reload on this host (Phase 2) plus the canonical-suite
re-run.

Phase `0` reopened through Sprints `0.2`–`0.7` (see
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)) to adopt
[the engineering doctrine docs](../documents/engineering/README.md) as the canonical CLI doctrine, align the
governed docs and plan suite to that doctrine, schedule every currently known code-level
adoption gap onto explicit downstream sprints, and (Sprint `0.7`, May 20, 2026) add the
LLM/automation guardrails so every operator-interactive entry point refuses to run on a
non-TTY stdin and points the caller at the automation equivalent. That Phase-0
doctrine-governance work is now `Done`. Phases `1` through `4` were **reopened** for the
scheduled implementation work named below and are now reclosed. Sprint 0.3 extended the
doctrine-adoption scope with the residual items surfaced by the May 2026 doctrine-vs-plan
audit, scheduling them through new Phase `1` sprints (1.24–1.26) and through deliverable
extensions to existing planned Phase `1` and Phase `2` sprints. Sprint 0.4 extended the
doctrine-adoption scope again with the residual items surfaced by the May 12, 2026 round-3
doctrine-vs-plan audit, scheduling them through one new Phase `1` sprint (1.27) and through
deliverable extensions to existing planned Phase `1`, Phase `2`, Phase `3`, and Phase `4`
sprints. Sprint 0.5 reopened Phase `4` through Sprint `4.8` to harden the
`prodbox rke2 delete --yes` success-summary contract; Sprint
`4.8` is now `Done`, the lifecycle-local quiet path captures the upstream uninstall output, the
expanded `isIgnorableRke2DeleteNoiseLine` filter classifies inotify warnings such as
`Failed to allocate directory watch: Too many open files` as benign noise (note: this warning is
usually emitted out-of-band by systemd/journald to the console, so the filter only catches it when
systemd routes it to the captured stderr — it may still appear on a successful run, benign), and the
integration suite proves both the hermetic success contract and the summarized failure path. Sprint 1.2
was revised May 20, 2026 to replace the external `dhall-to-json` subprocess decode bridge
with in-process decoding through the native Haskell `dhall` library
(`Dhall.inputFile auto`); the `toolDhall` / `tool_dhall` external-tool prerequisite, the
matching prerequisite-registry assertion, and the `FromJSON` / `ToJSON` derivations on the
settings record types are removed from the supported path.
Phase `5` briefly reopened
through Sprint `5.5` to add the missing public HTTP listener that redirects port `80` to the
canonical HTTPS edge, and that redirect follow-up is now `Done` after the May 13, 2026
aggregate validation. Phases `5` and `6` are `Done` on their owned surfaces (public-edge
proof, clean-room rerun contract). Phase `7` is `Done` on its **legacy** owned scope
(Sprints `7.1`–`7.4`: interactive onboarding, AWS IAM management, quota automation, and the
temporary-admin-credential validation harness) **and** has reopened for AWS-substrate parity:
Sprint `7.5` is `Active` (sub-sprints `7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/
`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/`7.5.c.v.e` are `Done` on their code-owned surfaces;
Sprint `7.5.c.v.f` is `Done` on its code-owned surface (May 21, 2026: substrate-aware
`prodbox host public-edge --substrate {home-local,aws}` plus stderr breadcrumbs in
`runNativeValidation` that make silent exit structurally impossible); the live
`--substrate aws` re-run rolls up into Sprint `7.5.c.v`); Sprints `7.6` (orphan-safety
refuse-path + auto-destroy postflight) and `7.7` (generalized `aws teardown` +
`PulumiResiduePolicy` ADT + harness teardown bug closure + admin-credential prompt UX)
are both `Done` (May 19, 2026). Phase `4` reopened May 21, 2026 to schedule Sprints
`4.10`–`4.15`: code frameworks for Sprints `4.10`–`4.13` landed the same day
(long-lived Pulumi backend decouple, lifecycle predicate library + `--cascade`,
K8s drain phase, `prodbox nuke` scaffold), Sprint `4.14`
(operator vocabulary contract enforcement) closed the same day —
every `Sprint <digit>` leak in operator-facing surfaces is removed
and a new `checkOperatorVocabulary` scan refuses regressions — and
Sprint `4.15` (cascade tolerates absent cluster) closed the same
day with a live verification on this host: `prodbox rke2 delete
--cascade --yes` now skips the K8s drain phase cleanly when the
cluster is already gone and proceeds to the per-run Pulumi destroys.
The live cascade exercise against a running cluster remains tracked on the
Phase 4 ledger; the `aws-ses` migration proof is now owned by Sprint `7.14`'s encrypted
first-touch path, and the live `nuke` exercise closed on June 3, 2026.
Phase `8` is `Active` on Sprints
`8.5`–`8.6`. **Phase `2`, Phase `3`, and Phase `4` reopened May 23, 2026** to schedule
the `.prodbox-state/` elimination work surfaced by the May 22 cascade-credentials
failure on this host: Phase `2` adds Sprints `2.17` (native Haskell HTTP client replaces
`curl` shell-outs) **— ✅ Done on the host-side host-CLI surface (5 callers migrated;
`Prodbox.Http.Client` + `Prodbox.Gateway.Client` modules; 10 unit tests; the
TestValidation-suite callers and the RKE2 installer download remain on the cleanup
ledger as Sprint 4.18 follow-up)**; `2.18` (127.0.0.1-only NodePort enforcement via
`host firewall`) **— ✅ Done on the foundational host-side surface (pure
`gatewayNodePortFirewallRuleArgs` + `runHostFirewallGatewayRestrict` + new `host
firewall gateway-restrict --port PORT` subcommand; 7 unit tests; chart-side NodePort
Service + reconcile/delete wiring land with Sprint 2.19)**; and `2.19` (gateway daemon
becomes secret-derivation service) **— 🔄 Active: pure `Prodbox.Secret.Derive` module
landed (HMAC-SHA-256 + per-secret context-string table + 13 unit tests, including the
five canonical context strings from the doctrine table); the wire-contract layer also
landed May 23, 2026 — new `Prodbox.Secret.Wire` with typed `DeriveResponse` /
`EnsureNamespaceRequest` / `EnsureNamespaceResponse` / `SecretSha256Entry` shapes, typed
`Prodbox.Gateway.Client.derive` / `ensureNamespace` client functions, and daemon route
stubs at `/v1/secret/derive` and `/v1/secret/ensure-namespace` returning structured 503
"master-seed unavailable" per doctrine §8 until the live handlers land (8 new unit
tests; total 495). Chart-side scaffolding also landed May 23, 2026: new
`charts/gateway/templates/secret-minio-creds.yaml` (Opaque Secret using `lookup` +
`randAlphaNum`, persists across helm upgrades), new
`charts/gateway/templates/service-nodeport.yaml` (NodePort `30443` exposing the gateway
REST port for host-CLI loopback access; matches the Sprint 2.18 iptables-rule default),
and `charts/gateway/templates/deployments.yaml` wires `MINIO_ACCESS_KEY_ID` /
`MINIO_SECRET_ACCESS_KEY` env vars from the new Secret into the gateway pod. Symmetric
firewall-rule removal landed alongside: new
`Prodbox.Host.runHostFirewallGatewayUnrestrict :: Int -> IO ExitCode` plus
`prodbox host firewall gateway-unrestrict --port PORT` operator-facing subcommand
(idempotent — treats absent-rule as success-with-reason). **`Prodbox.Secret.MasterSeed`
foundation also landed May 23, 2026 (later session)**: new
`src/Prodbox/Secret/MasterSeed.hs` shells out to `aws s3api` via
`Prodbox.Service.runMinIOWithEnv` (no `amazonka-s3` / `minio-hs` dependency required
today); exposes `MinioMasterSeedConfig`, the six-constructor `MasterSeedError` ADT,
`ensureMasterSeed` (read-or-create with `If-None-Match: *` concurrent-creation guard +
post-PUT GET re-read), `generateFreshSeedBytes` (32 bytes from `/dev/urandom`), and the
pure `awsS3Api{Head,Get,Put}Args` helpers + AWS-CLI error-blob recognizers; 14 new unit
tests pin the wire shape (test count 533/533, up from 519). MinIO IAM bootstrap + live
daemon endpoint bodies (replacing the structured 503 stubs with `ensureMasterSeed` ∘
`derive` and the per-context `ensure-namespace` inventory) + the chart-side
`MINIO_ENDPOINT_URL` env-var addition + automatic reconcile/delete firewall-rule wiring
remain as coupled deliverables for a dedicated live session**. Phase `3` adds Sprint `3.13` (chart secrets derived by the gateway
service; eliminates the host-side `.prodbox-state/<ns>/.secrets.json` cache) **— 📋
Planned (blocked on Sprint 2.19's full closure)**. Phase `4` adds Sprints `4.16`
(`ResidueStatus` source-of-truth swap) **— ✅ Done on the code-owned surface
(2026-05-27). The 4.16 closing change introduces
`src/Prodbox/Lifecycle/LiveResidue.hs` (one shared MinIO port-forward
across the three per-run stacks; admin-credentialled long-lived S3 query
for `aws-ses`); per-stack `<stack>ResidueStatus` delegates to LiveResidue
and the four `<stack>HasLiveResources` boolean predicates are removed.
`Prodbox.Aws.checkPulumiResidueBeforeTeardown` splits into the pure
`categorizePulumiResidue` + an IO wrapper that batches one MinIO and one S3
query; the three downstream callers (`Aws.checkPulumiResidueBeforeTeardown`,
`Preconditions.noLive{PerRun,LongLived}PulumiStacks`,
`Rke2.runNativeDeleteCascade`) all share the batch. New test-only env var
`PRODBOX_TEST_RESIDUE_ABSENT=1` short-circuits both queries to
`ResidueAbsent` for the fake-AWS-CLI integration suite. 17 unit tests
rewritten to inject synthetic `PerRunResidueStatuses` via
`categorizePulumiResidue` (replacing the `writeFakeStackSnapshot` +
file-existence pattern); 13 new tests cover the LiveResidue pure helpers
and the doctrine asymmetry (per-run unreachable → absent; long-lived
unreachable → still-present). Validated with `prodbox check-code` exit
0, `prodbox test unit` 567/567, `prodbox test integration cli` 28/28,
`prodbox test integration env` 28/28, `prodbox-daemon-lifecycle` 14/14.
Snapshot file-IO removal moves to Sprint 4.18; the live AWS-substrate
regression (`prodbox test all --substrate aws` produces zero
`.prodbox-state/aws-*/` writes during cascade refusal paths) rolls up
with Sprint 7.5.c.v**, `4.17`
(cascade canonical order + self-materialize operational creds) **— 🔄 Active: the
credential-fallback half landed May 23, 2026 a.m. and **structurally closes the May 22
cascade-credentials failure class** by making each per-run
`loadOperationalAwsCredentials` fall back to `aws_admin_for_test_simulation.*` when
operational `aws.*` is empty (4 unit tests); the cascade-order rewrite landed
May 23, 2026 p.m. — `runNativeDeleteCascade` now executes confirm-MinIO → per-run
destroys → drain → uninstall → postflight sweep, with new pure helper
`perRunCascadeInventory` exposed for test coverage (7 new unit tests). **The postflight
tag sweep wiring also landed May 23, 2026 (later session)**: `runCascadePostflightTagSweep`
now loads admin credentials via `loadAdminAwsCredentials`, builds the admin AWS env via
`adminAwsEnvironment`, and calls `Prodbox.Lifecycle.TagSweep.discoverClusterTaggedAwsResources`
with `awsEksCanonicalClusterName` as the cluster filter; an empty result reports "clean",
a non-empty result emits the full `renderTagSweepRefusal` block, and the cascade returns
`ExitSuccess` either way per doctrine §6 (4 new unit tests; test count 519/519, up from
515). All code-owned halves of Sprint 4.17 are now shipped; only the live cascade exercise
against a host with a live `aws-eks` stack remains as the closure gate**, and `4.18`
(removes remaining `.prodbox-state/` artifacts) **— 🔄 Active. First
chunk of code-owned work landed 2026-05-27 on top of Sprint 4.16's
source-of-truth swap: tarball scratch directories moved from
`.prodbox-state/tmp/` to the system temp directory in
`Lib/AwsSubstratePlatform.hs::withTempJsonFile` and
`CLI/Rke2.hs::pushCustomImageVariantsViaInClusterCrane`; new
`Prodbox.Lifecycle.LiveResidue.fetchPerRunStackOutputs` /
`fetchAwsSesStackOutputs` foundation reads from live Pulumi backend;
two consumers migrated off `loadXxxStackSnapshot`
(`PublicEdge.hs::resolveSubstrateHostedZoneId` reads `subzone_id`;
`TestValidation.hs::verifyAwsEksSnapshot` reads `cluster_name` +
`subnet_ids`). Remaining: migrate the two `AwsTestStack`-node
readers + the `AwsSubstratePlatform` snapshot consumer; remove
save/load/clear + state-dir helpers + JSON serialization in the four
per-stack modules; replace the `awsEksTestKubeconfigPath` and SSH-key
paths with mktemp brackets; add the `forbidDotProdboxState` lint
once Sprint 3.13 closes the chart-secret cache references.** New doctrine SSoT
[secret_derivation_doctrine.md](../documents/engineering/secret_derivation_doctrine.md)
governs the master seed and the host↔cluster boundary. The doctrine-adoption handoff
is closed; remaining open work is substrate-parity live validation (Sprint `7.5.c.v`),
the residual Phase `4` live closures for Sprints `4.10`–`4.13`, live Keycloak invite
OIDC closure (Sprint `8.5`), and the Phase `2`/`3`/`4` reopened sprints above.

Reopened sprints by phase:

- Phase 0 — **Sprints 0.2, 0.3, 0.4, 0.5, 0.6**: Sprint 0.2 adopts the engineering doctrine docs as governed CLI
  doctrine. Updates `documents/documentation_standards.md` with the six Generated Sections
  requirements, retags governed engineering docs as doctrine pointers, and threads doctrine
  cross-references through the plan suite and root guidance. Sprint 0.3 schedules the
  residual doctrine items surfaced by the May 2026 audit: durable CLI documentation
  artifacts (Markdown command reference, manpages, shell completions), the `execParserPure`
  parser-test category, the `renderError` error-rendering boundary discipline, per-command
  `CommandSpec` `Example` entries, the `cabal format` temp-file round-trip byte-equality
  compare, the default 30 s drain deadline plus explicit `bracketOnError`, the
  `envMetrics :: MetricsRegistry` typed daemon `Env` field, the STM broadcast channel for
  `LiveConfig` subscribers, the prescribed on-disk Dhall file shape, and the daemon
  log-level refresh from `LiveConfig` on every hot reload. Sprint 0.4 schedules the
  residual doctrine items surfaced by the May 12, 2026 round-3 audit: cabal-manifest
  toolchain pin declarations (`tested-with: ghc ==9.12.4`, `with-compiler: ghc-9.12.4`,
  the `Cabal 3.16.1.0` reference), library-first / thin-`Main.hs` layout, the
  `CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch, forbidden subprocess primitives (`callProcess`, `readCreateProcess`,
  direct `System.Process` constructors), the thirteen minimum `fourmolu.yaml` settings,
  the canonical property-test invariants (`decode . encode == id`,
  `render is deterministic`, `parser roundtrips`), the service-error newtype inventory
  (`MinIOError`, `RedisError`, `PgError` wrapping `ServiceError`), the daemon
  `AppError` record shape (`errorKind`, `errorMsg`, `errorCause :: Maybe SomeException`),
  the naming-helper signatures with DNS-1123 / 63-character constraints, the enumerated
  forbidden renderer inputs, the structured-concurrency primitive set
  (`withAsync` / `race` / `concurrently` / `replicateConcurrently`), the forbidden
  reload triggers (`fsnotify`, `inotify`, `mtime` polling) plus typed
  `schemaVersion : Natural` Dhall field and eight-step reload procedure, typed
  logging field helpers (`field`, `logStructured`, `logDebug`, `logInfo`,
  `logWarn`, `logError`), the production-no-op / test-injected hook contract,
  the health-endpoint response shapes captured as golden tests, and the forbidden
  reconciler flags and sister commands (`--force`, `--reinstall`, `install`,
  `upgrade`, `repair`, `force-install`). Sprint 0.5 schedules the remaining
  `prodbox rke2 delete --yes` success-path output residue: a new Phase `4` sprint
  hardens hermetic success summaries, tracks the leak in the cleanup ledger, and names the
  governed documentation updates required by `documents/documentation_standards.md`. Sprint
  0.6 introduces the substrate doctrine into the canonical phase model, renames
  `phase-5-public-host-validation.md` → `phase-5-canonical-test-suite.md` and
  `phase-7-aws-iam-quota-automation.md` → `phase-7-aws-substrate-foundations.md`, adds
  [substrates.md](substrates.md), and makes substrate provision/teardown a per-substrate
  concern separate from suite content.
- Phase 1 — **Sprints 1.6–1.27**: `CommandSpec` source-of-truth split; `Plan` / `apply`
  discipline with `--dry-run`; `Subprocess` ADT formalization; prerequisite registry
  remedy-hint contract; lint, generated-section, and forbidden-path stack alignment;
  `hspec` → `tasty` test-stanza migration; capability classes plus `AsServiceError`;
  `RetryPolicy` as first-class values; `Recoverable` / `Fatal` `ErrorKind`; naming helpers
  and smart-constructor module; GADT-indexed state machines for multi-state workflows;
  toolchain pin reaffirmation on GHC `9.12.4` / Cabal `3.16.1.0`; one-shot CLI output
  discipline with `--format` / `--color` / `--no-color` and stdout/stderr split; one-shot
  `Env` record and `ReaderT App` adoption; pinned style-tools sandbox under
  `.build/prodbox-style-tools/` plus custom nesting warnings and negative-space
  symbol rules refusing `forkIO`, `unsafePerformIO`, and module-level `IORef` in daemon paths;
  aggregate `prodbox test lint` dispatch with lint-first ordering of `prodbox test all`;
  `trackingGeneratedPaths` registry plus renderer determinism contract; standardized library
  audit of `prodbox.cabal`; the `lint docs` ↔ `docs check`/`docs generate` naming-consolidation
  decision and the parser `--foreground` default plus self-daemonization-forbidden rule; and —
  added by Sprint
  0.3 — durable CLI documentation artifacts under `documents/cli/`, `share/man/`, and
  `share/completion/` registered in `trackingGeneratedPaths`; the `execParserPure`
  parser-test category in the `prodbox-unit` stanza; and the `renderError` error-rendering
  boundary discipline with hlint rules refusing `print`, `exitFailure`, and direct terminal
  formatting outside the dedicated output layer. Sprint 0.4 adds Sprint 1.27 (cabal-manifest
  `tested-with: ghc ==9.12.4` and `with-compiler: ghc-9.12.4` declarations, the literal
  `Cabal 3.16.1.0` reference, and the library-first / thin-`Main.hs` audit through
  `src/Prodbox/CheckCode.hs`) and threads the round-3 extensions through Sprint 1.6
  (`CommandSpec` / `OptionSpec` record-field bindings plus daemon-as-typed-`Command`
  dispatch), Sprint 1.8 (typed `Subprocess` record plus removal of the pre-doctrine
  `CommandSpec`, `runStreamingCommand`, and `captureCommand` compatibility names), Sprint 1.10
  (thirteen minimum `fourmolu.yaml` settings bound), Sprint 1.11 (canonical
  property-test invariants `decode . encode == id`, `render is deterministic`,
  `parser roundtrips`), Sprint 1.12 (service-error newtype inventory `MinIOError`,
  `RedisError`, `PgError`), Sprint 1.14 (`AppError` record shape `errorKind`,
  `errorMsg`, `errorCause :: Maybe SomeException`), Sprint 1.15 (naming-helper
  signatures with DNS-1123 / 63-character constraints), and Sprint 1.21 (enumerated
  forbidden renderer inputs).
- Phase 2 — **Sprints 2.9–2.16**: Explicit daemon lifecycle
  (`load→prereq→acquire→ready→serve→drain→exit`) with worker loops wrapped in `try`/`catch`
  + bounded retry-with-backoff; `/healthz`, `/readyz`, `/metrics` endpoints with response
  shapes captured as golden tests; `BootConfig` / `LiveConfig` split with `SIGHUP` hot
  reload and atomic-swap discipline on `envLiveConfig`; structured JSON logging via `co-log`;
  test hooks in `Env`; `prodbox-daemon-lifecycle` test stanza asserting that single SIGTERM
  begins drain and second SIGTERM (or drain deadline) forces exit; daemon CLI plumbing
  (`--config`, `--log-level`, `--port`, `--foreground`) plus `PRODBOX_*` env-var precedence
  rule; formal at-least-once event-processing module
  (`src/Prodbox/Daemon/Events.hs`) with `StoredEvent` / `recordEvent` /
  `markEventProcessed` / `fetchUnprocessedEvents` and idempotent `EventHandler`; and — added
  by Sprint 0.3 — the default 30 s drain deadline plus explicit `bracketOnError` on
  external-side-effect resources (2.9); the `envMetrics :: MetricsRegistry` typed daemon
  `Env` field consumed by `/metrics` (2.10); the STM broadcast channel for `LiveConfig`
  subscribers plus the prescribed on-disk Dhall file shape (2.11); and the daemon log
  level refreshed from `LiveConfig` on every hot reload (2.12). Sprint 0.4 threads the
  round-3 extensions through Sprint 2.9 (enumerated structured-concurrency primitive set
  `withAsync` / `race` / `concurrently` / `replicateConcurrently`), Sprint 2.11 (forbidden
  reload triggers `fsnotify`, `inotify`, `mtime` polling; typed `schemaVersion : Natural`
  Dhall field with mismatch-as-parse-failure; eight-step reload procedure step-by-step),
  Sprint 2.12 (typed `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` helper
  plus `logStructured` / `logDebug` / `logInfo` / `logWarn` / `logError` wrappers),
  Sprint 2.13 (production-no-op / test-injected hook contract bound), and Sprint 2.14
  (health-endpoint response shapes captured as golden tests inside the lifecycle stanza).
- Phase 3 — **Sprints 3.8–3.12**: Smart constructors for paired chart resources; capability
  classes applied to Redis and Postgres chart call sites; reconciler discipline on
  `prodbox charts deploy` / `delete`; `--dry-run` on chart operations; `prodbox lint chart`
  Helm-chart structural-invariants linter; and marker-delimited route-inventory generation
  from `src/Prodbox/PublicEdge.hs` into chart artifacts via the `GeneratedSectionRule`
  registry. Sprint 0.4 extends Sprint 3.10 with the named forbidden reconciler flags
  (`--force`, `--reinstall`) and forbidden sister commands (`install`, `upgrade`,
  `repair`, `force-install`) on the chart surface.
- Phase 4 — **Sprints 4.5–4.8**: Rename the legacy lifecycle command to
  `prodbox rke2 reconcile`, retire the one-cycle `install` alias after its compatibility
  window, apply lifecycle Plan / Apply + `--dry-run`, and add the `prodbox-pulumi` test
  stanza. Sprint 0.4 extends Sprint 4.5 with the same forbidden-flag and sister-command
  discipline on the lifecycle reconciler, so `install`, `upgrade`, `repair`, and
  `force-install` are rejected at parse time. Sprint `4.8` makes successful
  `prodbox rke2 delete --yes` runs hermetic and summary-owned by `prodbox`, while preserving
  actionable upstream context on failure.
- Phase 4 — **Sprints 4.10–4.13** (added May 21, 2026 to bind the lifecycle reconciliation
  doctrine into code): Sprint `4.10` decouples long-lived Pulumi state onto a dedicated
  operator-account S3 bucket so the `aws-ses` stack survives `rke2 delete + rke2 reconcile`
  cycles. Sprint `4.11` introduces the composable `Precondition` algebra and the
  `prodbox rke2 delete --cascade` / `--allow-pulumi-residue` flag matrix (mutually exclusive
  at parse time) so orphaning per-run Pulumi-managed AWS resources is structurally
  impossible. Sprint `4.12` adds the K8s drain phase that deletes LoadBalancer Services, ALB
  Ingresses, and Delete-reclaim PVCs before per-run Pulumi destroys, so AWS-side controllers
  can unwind cleanly. Sprint `4.13` introduces `prodbox nuke`, the operator-only total-
  teardown command that refuses non-TTY contexts and requires the typed-confirmation
  literal `NUKE EVERYTHING`. Code frameworks for all four sprints landed May 21, 2026; the
  live operator validations (AwsSesStack admin-credential switch + live migration body,
  live cascade exercise against a running cluster) are tracked as remaining work in the
  respective sprint blocks; live `nuke` closed on June 3, 2026.
- Phase 4 — **Sprints 4.14 + 4.15** (added May 21, 2026 from the live
  `prodbox rke2 delete --help` and `--cascade --yes` review):
  Sprint `4.14` enforces the operator vocabulary contract introduced
  in
  [cli_command_surface.md § 2A](../documents/engineering/cli_command_surface.md#2a-operator-vocabulary-contract)
  — `Sprint <number>` labels and other dev-plan tracking vocabulary
  must not appear in any operator-facing CLI surface
  (`prodbox <command> --help`, manpages under `share/man/`, shell
  completions under `share/completion/`, the generated
  `documents/cli/commands.md`, or stdout/stderr emitted by the
  binary at runtime). Implementation rewrites the sprint-tagged
  strings in `src/Prodbox/CLI/Spec.hs` and the cascade narration in
  `src/Prodbox/CLI/Rke2.hs::runNativeDeleteCascade`, then adds a
  `Sprint [0-9]` regex scan to `prodbox check-code`. Sprint `4.15`
  closes the symptom surfaced when an operator runs
  `prodbox rke2 delete --cascade --yes` on a host without a cluster:
  the drain phase currently calls `kubectl delete services` against
  `localhost:8080` and fails noisily. Implementation adds a
  `DrainSkipped <reason>` constructor to the `DrainResult` ADT in
  `src/Prodbox/Lifecycle/K8sDrain.hs`, a quick
  `kubectl cluster-info --request-timeout=5s` reachability probe,
  and a cascade caller arm that treats `DrainSkipped` as
  success-with-reason — matching the
  [reconciler-with-predicates doctrine](../documents/engineering/lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern)
  rule that source-of-truth queries tolerate the case where the
  authoritative source is already gone.
- Phase 5 — **Sprint 5.5**: Add a Gateway API HTTP listener on port `80` that never routes
  plaintext backend traffic and only returns a permanent redirect to the canonical
  `https://test.resolvefintech.com/<service-path>` URL. Extend `prodbox host public-edge` and
  the external public-host validation surface to prove the redirect alongside the existing
  HTTPS-only application traffic contract. This follow-up is `Done` and was validated by the
  May 13, 2026 `./.build/prodbox test all` run.

The earlier alignment follow-up on native `gateway-partition` validation, peer trust-material
runtime closure, root-chart-only public chart commands, the Harbor-plus-storage-backend
bootstrap contract, and the later Phase `2` cleanup follow-up that removed the retained legacy
`NTP synchronized` `timedatectl` parser branch in `src/Prodbox/Host.hs` is complete in both
governed docs and code; those closures sit inside the Sprint 1.1–1.5, 2.1–2.8, 3.1–3.7,
4.1–4.4, 5.1–5.4, 6.1–6.3, and 7.1–7.N surfaces and are unchanged by the doctrine reopen.

The authoritative target still closes on:

- one Haskell-owned CLI, lifecycle, Pulumi, gateway-daemon, public-workload, chart, onboarding,
  AWS, and test surface
- one leak-proof, idempotent command topology: every AWS or cluster resource prodbox can create
  is a registered entry in the managed-resource registry (typed `discover` + `destroy`), teardown
  is one idempotent `reconcileAbsent` reconciler with `Unreachable` never silently passing, and
  `check-code` makes a creatable-but-undiscoverable resource unrepresentable (per
  [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md);
  scheduled as Phase 4 Sprints 4.20–4.22 and Phase 7 Sprint 7.8)
- one direct `Dhall -> Haskell types` config contract rooted at operator-authored
  `prodbox-config.dhall`
- one Harbor-first local lifecycle that reconciles MetalLB, Envoy Gateway, cert-manager, Harbor,
  MinIO, and the Percona PostgreSQL operator on the supported self-managed cluster path
- one supported public-edge doctrine where every externally reachable application or dashboard sits
  behind Envoy Gateway on `test.resolvefintech.com`, distinguished only by explicit path prefixes
  such as `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio`, protected by Keycloak-
  backed JWT auth or RBAC, covered by one Route 53 record plus one listener certificate, and
  fronted by a port `80` HTTP listener that only redirects to HTTPS
- one native-host-architecture lifecycle image-publication doctrine where `amd64` hosts build and
  publish only `amd64` images, `arm64` hosts build and publish only `arm64` images, and no
  supported path uses `docker buildx` or cross-arch emulation
- one explicit steady-state JWT boundary where Envoy validates Keycloak-issued tokens locally and
  does not require per-request Keycloak or Redis calls on the hot path
- one explicit Keycloak availability boundary where new logins, refresh flows, and later JWKS
  refresh depend on Keycloak, while the steady-state JWT hot path at Envoy does not require
  per-request Keycloak or Redis access
- one explicit distinction between the Envoy Gateway public edge and the separate Haskell
  distributed gateway daemon shipped through `prodbox gateway ...` and
  `prodbox charts deploy gateway`
- one explicit current transport boundary where public TLS terminates at Envoy and backend TLS or
  mTLS stays outside the supported chart-workload contract unless a later doctrine revision
  expands that path
- one Redis surface that currently backs WebSocket shared state and may later back an explicit
  external rate-limit service, but does not yet ship a standalone rate-limit-service workload or
  validation surface
- one cleanup ledger that preserves completed removal history; after the May 23, 2026 reopen of
  Phases `2`, `3`, and `4` the only open rows are the cluster-as-source-of-truth and
  native-HTTP-client cleanups owned by Sprints `2.17`, `3.13`, `4.16`, and `4.18`

The implemented clean-room rerun proof remains the Phase `6` command contract expressed through
`prodbox test all`, `prodbox config show`, `prodbox config validate`, and
`prodbox host public-edge`. Separate repository review gates still verify that `example.com` and
zero-Python residue stay out of supported-path sources, but those checks are not a dedicated
`prodbox` command. The canonical automated validation contract otherwise remains the `prodbox`
command surface documented by this plan: `prodbox check-code`,
`prodbox test unit`, `prodbox test integration cli`, `prodbox test integration env`, and the
canonical test suite behind `prodbox test integration ...` (planned by
`src/Prodbox/TestPlan.hs`, dispatched by `src/Prodbox/TestValidation.hs`, orchestrated by
`src/Prodbox/TestRunner.hs`). Per
[development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
that canonical suite runs against substrates — today the home local substrate and the AWS
substrate (see [substrates.md](substrates.md)) — and substrate-specific provision and
teardown belong to the substrate-owning phase docs, not to suite content. Substrate parity is
tracked in [substrates.md](substrates.md) and in the Substrate Parity table below.

The rewrite remains on the canonical phase model required by
[development_plan_standards.md](development_plan_standards.md).

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [substrates.md](substrates.md) | Authoritative inventory of substrates the canonical test suite runs against |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and public workload delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) | Phase 5: Canonical test suite — substrate-agnostic named validations |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Phase 7: AWS substrate foundations — onboarding, IAM, quota, and AWS substrate parity with the canonical suite |
| [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Phase 8: Operator-invited email authentication via Keycloak + AWS SES |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of cleanup/removal history and ownership |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated on the code-owned surface, and aligned in docs (a pending live-infra proof does not prevent `Done` — [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet **earlier-or-same-phase** sprint or **external** prerequisite — never a later phase and never a pending live-infra proof ([Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking)) | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |
| **Live-proof pending** | Code-owned surface `Done` and locally validated; a live-infra proof (live AWS / deployed cluster / unsealed Vault / operator credential) is outstanding. **Non-blocking** ([Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | 🧪 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass on the **code-owned surface** through the canonical `prodbox`
   surface (`prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env`).
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

Per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof), a
proof that requires live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an
operator-supplied credential) does **not** prevent `Done`; it is tracked as a distinct, non-blocking
`🧪 Live-proof: pending` note on the sprint. Per
[Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking), a `Blocked by`
entry may name only an earlier-or-same-phase sprint or an external prerequisite — never a later phase
or a higher-numbered sprint — and an incomplete later phase never reopens or blocks an earlier phase.

## Phase Overview

> **2026-06-26 live-proof update:** the home-substrate aggregate `prodbox test all` is **green**
> (18/18 validations + both cabal suites; see the Closure Status above and
> [00-overview.md](00-overview.md) Alignment Status). That run is the live-infra proof that satisfies
> the **home-substrate** `🧪 Live-proof: pending` axes referenced in the rows below across Phases
> 1–8 (config/secrets, gateway/DNS, charts, lifecycle, the canonical suite incl. `sealed-vault`, the
> AWS per-run resource cycles the home suite exercises, and `keycloak-invite`). Per
> [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) these were
> already non-blocking; they are now proven. The `--substrate aws` aggregate stays a distinct axis
> ([substrates.md](substrates.md)).

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ **Done on owned surfaces** — **finalized 2026-06-14** (Vault-root + cluster federation): the secrets model is now the finalized Vault-root model — Vault is the sole secrets/KMS/PKI root, the master-seed derivation model is retired (not extended), and cluster federation adds a Vault transit-seal trust tree; Sprint `0.13` (Vault-Root Finalization and Cluster-Federation Doctrine Harmony — docs-only) owns the doc/plan rearchitecture and the new `cluster_federation_doctrine.md` (✅ Done 2026-06-14 — `VAULT_REFACTOR.md` deleted and `cluster_federation_doctrine.md` present; see the 2026-06-14 Closure Status). Reopened 2026-06-11 for the Vault refactor's Sprint `0.12` (the `vault_doctrine.md` SSoT + documentation harmony), which **closed 2026-06-11** with gates green (`dev lint docs` 0, `dev docs check` 0, `dev check` 0, `test unit` 823). Prior closure preserved: ✅ Done — reopened 2026-06-09 for Sprints `0.9`–`0.10` (design-intention review; see Closure Status), both landed. ✅ `0.9` (header↔markers↔registry reconciler + governed-doc relative-link check in `runGeneratedArtifactLint`; sha256-freeze over-claim struck). ✅ `0.10` (the §2/§3 command matrix from `commandRegistry` (1.29) and the registry-name↔CLI table from `StackDescriptor` (4.27) are generated sections; the chart→edge ownership table left editorial per the design guardrail — no typed owning-chart source). Documentation Harmony is now machine-enforced; gates `check-code` 0, `test unit` 802, `lint docs`/`docs check` 0. Prior closure preserved: ✅ Done (Sprints 0.1–0.8). Sprint 0.8 (May 24, 2026 — pure-Dhall config doctrine adoption) closed on its owned doc-revision surface: `documents/engineering/config_doctrine.md` SSoT created, governed engineering and root docs revised to defer to it, plan suite updated, and the four validation gates exit 0 (`prodbox lint docs`, `prodbox docs check`, `prodbox check-code`, `prodbox test unit` 533/533). The code-implementation work lands in Phase 1 Sprint 1.28, Phase 2 Sprints 2.20/2.21/2.22, and Phase 3 Sprint 3.14. **Independent Validation**: a docs-only phase validated by the documentation gates (`prodbox dev docs check`, `prodbox dev lint docs`, `prodbox dev check`) plus the header↔markers↔registry reconciler, with no dependency on a later phase; Sprint `0.15` adopts the phase-independence doctrine here. | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ **Reclosed 2026-07-04** after Sprint `1.55` added the explicit `capacity.resource_plan` schema/config surface (Dhall capacity typecheck, unit 1162/1162, env integration 40/40). Prior 2026-07-02 closure preserved after expanding its own schema/config surface for the 2026-07-01 doctrine batch: Sprint `1.51` is ✅ Done (capacity/scaling Dhall schema, `CapacitySection`, and substrate-indexed scaling policies; validation 1064/1064 unit + 39/39 CLI/env integration + `dev check`), Sprint `1.52` is ✅ Done (multi-OS host-provider DSL, host-frame Docker gate, and `host_substrate_supported` prerequisite root; validation 1070/1070 unit + 39/39 CLI/env integration + `dev check`), and Sprint `1.53` is ✅ Done (cluster-topology Dhall schema, Haskell mirror, declared `cluster_topology` config field, and pure placement outcome ADT; validation 1075/1075 unit + 39/39 CLI/env integration + `dev check`), and Sprint `1.54` is ✅ Done (test-topology Dhall schema, Haskell mirror, executable-sibling `prodbox.test.dhall` decoder, and topology-mode production-config preflight; validation 1080/1080 unit + 39/39 CLI/env integration + `dev check`). Prior reopen preserved: ✅ **Reclosed after the 2026-06-17/18 expansion** to expand its own config-SSoT surface with the three-tier config model: Sprint `1.39` (✅ Done code-owned 2026-06-17; 🧪 Live-proof pending — Tier 0 binary-owned `prodbox.dhall` in hostbootstrap binary-context shape, folding the unencrypted basics + non-secret `prodbox-config.dhall` sections, with a derived `prodbox-basics.json` bootstrap floor) and Sprint `1.40` (✅ Done code-owned 2026-06-18; 🧪 Live-proof pending — Tier 0 in-cluster: container-default `prodbox.dhall` overwritten by the daemon from the `gateway-config-<nodeId>` ConfigMap; full `DaemonConfigDhall`↔Tier-0 unification deferred), both forward-only-blocked on the closed Sprint `1.38` (`1.40` also on `1.39`); cites [config_doctrine.md §0/§1a/§3/§6](../documents/engineering/config_doctrine.md#0-three-tier-config-model). Sprint `1.41` (✅ Done code-owned 2026-06-18; live `cluster reconcile` RC=0 — Config-Topology Consolidation: drop the JSON floor (read the sealed-Vault floor directly from the self-contained Tier-0 `prodbox.dhall` via `projectBasics`; `prodbox-basics.json` + the legacy `.data/prodbox/unencrypted-basics.json` eliminated), `docker/default-prodbox.dhall` becomes generated at image-build time + git-ignored, the `*-types.dhall` schemas stay generated + git-ignored — net zero version-controlled `.dhall`; forward-only-blocked on the closed `1.39`/`1.40`) and Sprint `1.42` (Part A ✅ Done 2026-06-18 / Part B ✅ Done 2026-06-19 — `prodbox-config.dhall` RETIRED: the operator non-secret config now lives in the binary-generated, git-ignored Tier-0 `prodbox.dhall` `parameters` read via `loadConfigFile`'s Dhall field-projection; `config setup`/`aws setup`/`vault init` author it merge-preserving; ~35 fixtures converted via `TestSupport.wrapTier0`; sealed/unreachable Vault on an established cluster has NO config fallback per operator decision; 🧪 live-proof pending; forward-only-blocked on the closed `1.38`/`1.39`/`1.41`). Phase `1` further reopened with Sprint `1.43` (✅ Done 2026-06-20 — moved the durable test secrets into the dedicated, git-ignored `test-secrets.dhall` as the SOLE secret fixture; `TestConfig`→`TestSecrets`, generated `test-secrets-types.dhall`, the now-empty `test-config.dhall`/`test-config-types.dhall` removed) and Sprint `1.44` (✅ Done code-owned 2026-06-20; 🧪 Live-proof pending — routes the Vault-written secrets, ACME EAB + minted operational `aws.*`, through the gateway daemon's `POST /v1/secret/<logical>` endpoint under a dedicated `prodbox-operator-write` Vault policy/role, authenticated by an operator-injected k8s JWT, with the host-write fallback later narrowed to no-JWT/test-seam cases; the unlock password + ephemeral admin cred stay host-side), both expanding Phase 1's own config/secrets surface per the operator's 2026-06-19 target (see the Closure Status). Phase `1` further reopened with Sprint `1.45` (✅ Done code-owned 2026-06-20; 🧪 Live-proof pending — consolidated the former `prodbox-gateway` + `prodbox-public-edge-workload` images into ONE union runtime image `prodbox/prodbox-runtime` from a single `docker/prodbox.Dockerfile` (tini + AWS CLI, bare `tini -- prodbox` entrypoint); each chart selects its role via the pod `args:` (`gateway start` vs `workload start`); the former `docker/gateway.Dockerfile` is deleted; the gateway's Vault identity `prodbox-gateway-*` is unchanged; expands Phase 1's own container-packaging surface and consolidates Phase 2's former gateway-image build, which now cross-references this sprint, Standards A/N). Phase `1` further reopened with Sprint `1.46` (✅ Done code-owned 2026-06-20; 🧪 Live-proof pending — host `docker` CLI Harbor-login isolation via a persistent `<repoRoot>/.docker` `DOCKER_CONFIG` so the Harbor login never pollutes the operator's global `~/.docker`) and Sprint `1.47` (✅ Done code-owned 2026-06-20; 🧪 Live-proof pending — supersedes the 1.46 *persistent* mechanism with hostbootstrap `Registry`'s **ephemeral** scrubbed `prodbox-docker-config` `DOCKER_CONFIG` + inline Harbor entry, **no `docker login` anywhere**; `Prodbox.DockerConfig` rewritten, `ensureHarborDockerLogin` deleted, `dev check` 0 + 6 new unit tests + CliSuite no-login assertion + `test unit` 1061/1061; the 1.46 mechanism is in [legacy-tracking → Completed](legacy-tracking-for-deletion.md#completed)). `test unit` 1045/1045, `integration cli`/`env` pass. ✅ **Reclosed 2026-06-16** on Phase-owned Vault-root + cluster-federation foundations. Sprints `1.35`–`1.38` are Done: FileSecret-free `SecretRef` type/decoder/production validator/Vault resolver seam; encrypted unlock bundle and native `prodbox vault` lifecycle command group; sealed-Vault gate decision/outcome fold plus production Vault-Transit `DekCipher`; and the in-force-config source-of-truth inversion with `loadConfigForSettingsWith` switching host settings loads from repo-root Dhall-as-live-config to basics → Vault → MinIO envelope once unencrypted basics exist. Runtime AWS provider credential migration is landed under Sprint `7.14`; ACME EAB/TLS key material remains Sprint `7.15`; the direct live child registration and federated unseal cascade are now closed by Sprint `4.32`, and the gateway-mediated federation bootstrap is now closed by Sprint `2.26`. Prior closure preserved: ✅ Done — reopened 2026-06-09 for Sprints `1.29`–`1.32` (design-intention review; see Closure Status), all four landed 2026-06-09. Prior closure preserved: ✅ Done (Sprints 1.1–1.28). **Independent Validation**: the `SecretRef` contract, unlock bundle, `prodbox vault` command group, sealed-Vault gate, in-force-config loader, capacity config, scaling config, host-provider config/detection surface, cluster-topology config/schema surface, test-topology schema/preflight surface, and explicit resource-plan schema are validated on the code-owned surface (unit + CLI/env integration) and against the home/local substrate, with no dependency on a later phase. | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ **Reclosed 2026-07-02** after the CBOR migration batch. Sprint `2.27` is ✅ Done: gateway `Orders`, `SignedEvent`, and peer gossip batches use canonical CBOR via `cborg` / `serialise`; `POST /v1/peer/events` is `application/cbor`; supported-gateway-path legacy non-CBOR text search is clean. Sprint `2.28` is ✅ Done: `Prodbox.Cbor` owns the shared `CborPayload`, `Daemon.Events` stores durable event payloads as CBOR, and `StoredEvent` has CBOR round-trip coverage while the `markEventProcessed` first-write-wins guard remains pinned. Validation for the batch: build, warning-clean build, 1081/1081 unit tests, 39/39 CLI/env integration, and `dev check`. Prior closure preserved: ✅ **Reclosed 2026-06-16** for cluster-federation custody. Sprint `2.26` is Done: `Prodbox.Cluster.Federation` owns parent-owned child metadata/init/bootstrap/index Vault KV JSON framing, opaque child namespace/Transit-key derivation, root-token write gating, and the native `prodbox cluster federation register <child>` plan/apply surface; registration records full downstream inventory; and the gateway daemon exposes Vault-backed child-listing and child-bootstrap endpoints through its configured Kubernetes-auth Vault login. Prior closure preserved: ✅ Done on owned gateway-runtime, DNS-ownership, peer-transport, daemon-lifecycle, and CLI-doctrine surfaces through Sprint `2.25`. **Independent Validation**: gateway/durable-event CBOR codec, federation custody framing, opaque derivation, root-token gating, and the gateway daemon's child-listing/bootstrap endpoints are validated on the code-owned surface (unit + built-frontend integration) against the home/local substrate and Vault-backed fixtures, with no dependency on a later phase. | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ **Reclosed 2026-07-04** after Sprint `3.22` added chart resource requirements from `capacity.resource_plan`: every repo-owned chart container/init container renders a values-backed cpu/memory/ephemeral-storage request+limit envelope, root charts render namespace `ResourceQuota`/`LimitRange`, missing workload profiles fail before Helm, and `prodbox dev lint chart` refuses unbounded container templates. Validation: chart lint, unit 1164/1164, CLI integration 40/40. Prior 2026-07-03 closure preserved for Sprint `3.21` self-maintained CBOR Pulsar client broker transport/framing. Sprint `3.21` is ✅ Done: the local CBOR codec, derived topic algebra, `Work*` envelope family, typed client boundary, retained-storage Pulsar chart, repo-owned Haskell native broker transport/framing, and live home-local `pulsar-broker` produce/consume/ack proof are landed; `Prodbox.Pulsar.Protocol` owns the protobuf/framing subset and checksum/message-id/server-error helpers, while `Prodbox.Pulsar.Client` owns endpoint validation, reconnect/backoff, lookup, producer/consumer, request-correlation, and ack flows with typed broker errors. Prior 2026-06-16 closure is preserved for Vault-root chart-platform surfaces: Sprints `3.17`–`3.20` remain ✅ Done on Vault platform/envelope foundation, typed chart-secret Vault inventory, chart-secret materialization, removal of the retired derivation/RPC machinery, and root/child Vault seal-mode rendering. The master-seed derivation model is **retired, not extended**. Prior closures for Sprints `3.1`–`3.16` are preserved. Remaining sealed-Vault whole-system validation is Sprint `5.8`, not Phase `3`. **Independent Validation**: the Vault platform/envelope foundation, chart-secret Vault inventory, seal-mode rendering, structural sealed-startup proof, Sprint `3.21` CBOR/topic/envelope/chart/client/protocol surface, live broker proof, and Sprint `3.22` resource rendering/lint surface are validated against the home/local substrate with no dependency on a later phase. | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ **Reclosed 2026-07-05** after Sprint `4.42` routed root Vault lifecycle through the daemon boundary: `cluster reconcile` deploys the pre-Vault gateway daemon before root init/unseal/reconcile, `prodbox vault ...` lifecycle leaves prefer the daemon NodePort, daemon-side Vault errors do not fall back to direct host Vault/MinIO transports, and operator-secret writes do not bypass daemon failure once the operator JWT is mintable. Validation: warning-clean build, unit 1182/1182, CLI integration 43/43, env integration 43/43. Prior 2026-07-03 closure preserved after expanding its own lifecycle, capacity, host-provider, placement, EBS-retention, and Pulsar-topic managed-resource surface — Sprint `4.34` is ✅ Done on its code-owned surface (pure autoscaler planner, federation trust-tree placement guard, capacity refusal, gateway-leader-preserving action ordering, registry-exposed capacity-scaled resources); Sprint `4.35` is ✅ Done (`Prodbox.Pulsar.TopicResidue`, `ensureTopic` / `deleteTopic`, three-valued topic discovery, residue projection, `pulsar-topics-per-run` / `pulsar-topics-long-lived` resource-class rows, `pulsarTopicManagedResource`, and live broker-backed ensure/delete/discover proof through `pulsar-broker`); Sprint `4.36` is ✅ Done on its code-owned surface (finite storage-capacity planner, autoscaled-sink witness, ML JIT/model-cache totals, AWS region-quota preflight adapter); Sprint `4.37` is ✅ Done on its code-owned surface (host-provider ensure decisions, reboot-required outcome, wrong-provider fail-fast refusal, Docker Linux-frame dispatch); Sprint `4.38` is ✅ Done on its code-owned surface (one-worker-per-machine placement, required hostname anti-affinity, `maxSurge = 0`, mixed-substrate-only-`rke2` rule); Sprint `4.39` is ✅ Done on its code-owned surface (registered `aws-ebs-volumes`, typed EC2 discover/destroy, retain/test-scoped tag markers, deterministic retained-inventory parity); and Sprint `4.40` is ✅ Done on its code-owned surface (suite postflight test-EBS reaper, `cluster delete --cascade` hook, `aws ebs reap-test --yes`, retain-safe `Delete`-only drain guard), closing the EBS-leak class; extends the Sprint `4.12` drain and `4.20`/`4.24` resource-lifecycle-class model (Standards A/N). Prior closure preserved: ✅ **Reclosed 2026-06-16** on Vault-root lifecycle, Model-B object-store work, retained-storage topology, federated lifecycle, and Haskell-side sealed-state scrub. Sprints `4.29`–`4.33` are ✅ Done: `cluster reconcile` deploys/rebinds/unseals/reconciles Vault before MinIO while preserving the durable Vault PV; the Model-B object-store foundation is implemented with `Prodbox.Minio.ObjectStore`, `Prodbox.Minio.EncryptedObject`, `prodbox-envelope-v2` hashed stored AAD, the `prodbox-state` generic bucket, Vault-owned object-store HMAC key material, and the in-force-config read through an opaque object key; retained PVs now use the unified `.data/<namespace>/<StatefulSet>/<ordinal>` topology; federated lifecycle registers direct children from the parent and lets child `cluster reconcile` fail closed against a sealed/unreachable parent; and the Haskell residue/listing translators plus retained-object `NoSuchKey` classifier fail closed behind Vault readiness with token-bearing `Show` redaction. Sprint `7.14` owns the remaining Pulumi live first-touch deletion proof and live sealed-state proof; live cross-surface sealed-Vault red-team validation remains Sprint `5.8`. Latest Phase 4 gates after Sprint `4.42`: full unit suite 1182/1182, CLI integration 43/43, env integration 43/43, warning-clean build, docs generate/check, `git diff --check`, canonical dev check, and live `pulsar-broker`. **Independent Validation**: the Vault-before-MinIO lifecycle, Model-B object-store, unified retained-storage topology, federated lifecycle fail-closed cascade, sealed-state residue scrub, Sprint `4.34` autoscaler planner, Sprint `4.35` Pulsar topic lifecycle/resource-registry surface plus live broker-backed topic reconciliation, Sprint `4.36` tiered-storage capacity gate, Sprint `4.37` host-provider frame planner, Sprint `4.38` substrate-typed placement planner, Sprint `4.39` EBS managed-resource registry/tag surface, Sprint `4.40` test-EBS reaper/drain guard, and Sprint `4.42` daemon-mediated root lifecycle routing are validated against the home/local substrate with no dependency on a later phase; the Pulumi live first-touch deletion proof, live federation placement proof, live AWS Service Quotas proof, live macOS/Windows host-provider proof, live multi-machine anti-affinity proof, live EKS static-EBS proof, and live EKS test-EBS postflight leak proof remain non-blocking 🧪 live-infra axes. | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Canonical Test Suite | ✅ **Reclosed 2026-07-05 on code-owned Phase 5 surfaces through Sprint `5.14`; 🧪 live-proof pending for destructive volume-rebind, real resource-stress runs, sealed-Vault AWS parity, and AWS daemon object-store parity.** Sprint `5.14` adds `daemon-bootstrap`: parser/registry, `IntegrationDaemonBootstrap`, `ValidationDaemonBootstrap`, aggregate ordering after `resource-guardrails`, topology mapping, a pure transport oracle requiring daemon bootstrap/lifecycle routes, redaction checks, and built-frontend proof that legacy MinIO port-forward/direct-Vault/root-token traces fail. Prior Sprint `5.13` (`resource-guardrails`), Sprint `5.12` (`eks-volume-rebind`), Sprint `5.11` (test topology), Sprint `5.9` (daemon-lifecycle fixture repair), Sprint `5.8` (`sealed-vault`), and Sprints `5.1`–`5.6` remain closed/as-tracked on their owned surfaces. **Independent Validation**: Phase 5 suite content is validated on the code-owned surface and home/local substrate with no dependency on a later phase; AWS-substrate parity rows are tracked in [substrates.md](substrates.md) per Standards M/N/O. Latest Sprint `5.14` gates: warning-clean build, unit 1188/1188, targeted `daemon-bootstrap` 1/1, CLI integration 44/44, env integration 44/44, docs generate/check, and canonical dev check 0. | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ Done on owned surfaces. **Independent Validation**: the clean-room rerun and zero-Python handoff contract are validated on the code-owned surface and against the home/local substrate, with no dependency on a later phase; an incomplete later phase never reopens or blocks this phase ([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | AWS Substrate Foundations | ✅ **Reclosed 2026-07-05** after Sprint `7.30` moved supported per-run Pulumi object-store access behind the daemon API: daemon get/put/delete routes, Kubernetes-auth Vault Transit/HMAC resolution, in-cluster MinIO access, gateway-client hydration/store/prune/read calls, and fake-daemon built-frontend proof are done (unit 1195/1195, CLI integration 44/44, env integration 44/44). Live AWS/EKS object-store parity remains a non-blocking Standard O proof axis. Prior 2026-07-03 reclosure preserved after expanding its own AWS-substrate scaling, storage + networking surface — Sprint `7.27` is ✅ Done on its code-owned surface (2026-07-03: fail-closed spot-price economics gate plus credential-region AWS observer), Sprint `7.28` is ✅ Done on its code-owned surface (2026-07-03: static pre-created EBS as `Retain` PVs on EKS, superseding and removing the dynamic `gp2` path), and Sprint `7.29` is ✅ Done on its code-owned surface (2026-07-03: EKS VPC ownership hardening + always-fresh test VPC), per [storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md) + [cluster_topology_doctrine.md § 4](../documents/engineering/cluster_topology_doctrine.md) (Standards A/N). Prior reopen preserved: ✅ **Reclosed after the 2026-06-17/18 expansion** (and **further 2026-06-22** for the disk-free unseal cutover, **Sprint `7.25` ✅ code-owned** — unlock bundle MinIO-only: MinIO is now cluster-only + reordered before Vault, host-disk bundle dropped, established-probe on a non-secret marker; closes `7.19`'s deferred 🧪 axis; `dev check` 0 + `test unit` 1053/1053 + disk-free vault-lifecycle integration test green; **live-proven 2026-06-23** via a `.data`-wiped reconcile RC=0 — bundle written to + read from MinIO, no `.age` on disk; plus the new `config generate` + fail-fast Tier-0; and **Sprint `7.26` ✅ 2026-06-23** — the `cluster delete --cascade` postflight tag sweep now carves out the intentionally-retained long-lived `pulumi_state_backend`/`aws-ses` resources and refuses only on genuine per-run/cluster escapees) to expand its own owned surface with the three-tier config model: Sprint `7.19` (✅ staged 2026-06-18, closed by Sprint `7.25` — the additive dual-write/fallback-read code-owned surface ✅ Done; the MinIO-root-decouple landed 2026-06-22 as a STATIC credential; the disk-free unseal cutover is now Sprint `7.25`) and Sprint `7.20` (✅ Done 2026-06-18 — the IAM mint-to-Vault + delete-from-AWS-and-Vault lifecycle canonicalized as doctrine plus a teardown-completeness guard; the live AWS guard exercise is the 🧪 axis); cites [config_doctrine.md §0](../documents/engineering/config_doctrine.md#0-three-tier-config-model), [vault_doctrine.md §5/§6/§6.1/§9](../documents/engineering/vault_doctrine.md), [aws_admin_credentials.md §4.2](../documents/engineering/aws_admin_credentials.md), and [aws_integration_environment_doctrine.md §4.4](../documents/engineering/aws_integration_environment_doctrine.md). Sprint `7.21` (✅ Done code-owned 2026-06-18; 🧪 home-`test all`-preflight live-proof pending — Per-Run Pulumi-Destroy Robustness: a pure `classifyCheckpointBytes` (Absent/Empty/Corrupt/Present) + read-only `observeStackCheckpoint` feed `LiveResidue.queryOne`; absent/empty per-run checkpoint → `ResidueAbsent` (skip — the home case), corrupt-non-empty/unreadable → `ResidueUnreachable` (fail-closed refuse with the stack + `aws stack destroy --yes` recovery), per [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md) "cannot observe is never silently treated as absent"; leak-safe; +16 unit tests, gate green; surfaced by the home `test all` after the Sprint `1.39` floor fix; forward-only-blocked on Sprint `7.14` and the `4.20`–`4.22`/`7.8` managed-resource registry) and Sprint `7.22` (✅ Done + live-proven 2026-06-18 — gate the per-run **destroy-invocation** path: `destroy<Stack>Status` consults the `7.21` read-only observation first via `LiveResidue.perRunDestroyDecisionFromStatus` (absent→skip / present→destroy / corrupt→refuse), resolving MinIO creds from Vault `secret/minio/root`; plus the `prodbox aws stack {eks,test,aws-subzone} prune-corrupt-checkpoint --yes` recovery leaf; the exact harness `aws stack <stack> destroy --yes` commands now skip cleanly on the home cluster — closes `7.21`'s preflight proof; cites [lifecycle_reconciliation_doctrine.md §3.2](../documents/engineering/lifecycle_reconciliation_doctrine.md)) and Sprint `7.23` (✅ Done + `aws-ses` reconcile live-proven 2026-06-18 — fixed FIVE stacked bugs in the `aws-ses` encrypted Model-B reconcile path that had never run end-to-end on pulumi v3.228: scratch-env `PULUMI_CONFIG_PASSPHRASE=""`; `loadHydratableCheckpoint`/`checkpointBytesUsable` hydrate-fallback on blank/corrupt/export-format Model-B objects (kept distinct from the raw observe load the 7.21 gate needs); `--secrets-provider passphrase` (not invalid `plaintext`); `awsCliCredsFromProviderEnv` so state-recovery probes/import/key-rotation authenticate; stale-state clearing per operator destroy-authorization. `prodbox aws stack aws-ses reconcile` now imports live resources + idempotent-creates the rest → re-run 17 unchanged RC=0; home `test all` end-to-end is the remaining 🧪 axis) (see the 2026-06-18 Closure Status). ✅ **Done on its code-owned surface 2026-06-16; 🧪 Live-proof: pending** after the Sprint `7.14` landing. Phase 7 owns its own surface and does not block earlier phases. Sprint `7.14` has landed the code-owned Pulumi decrypt-to-scratch wrapper for main per-run and `aws-ses` stack cycles, encrypted production residue/output reads, first-touch raw checkpoint import/delete hooks, per-run raw backend env confinement to `LegacyPulumiBackend`, the wrapper-backed `aws-ses migrate-backend` compatibility command, Vault-only AWS provider credential resolution through `secret/gateway/gateway/aws`, and the migration of the generated operational `aws.*` credential to a mandatory `SecretRef.Vault` reference (minted into Vault KV after unseal; `prodbox-config.dhall` carries only the reference). **Independent Validation**: the interposition, encrypted residue/output reads, Vault-only credential resolution, and the `SecretRef.Vault` migration are validated on the code-owned surface and against the home/local substrate (the live home `cluster reconcile` below), with no dependency on a later phase. The live first-touch migration/deletion proof and the both-substrate sealed-Vault opacity proof are a distinct, non-blocking 🧪 live-infra axis (they need a live `secret/aws/admin-for-test-simulation` Vault object and a deployed AWS substrate for IAM-harness preflight); they are **not** ⏸️ Blocked ([Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)). Sprint `7.16` ✅ landed (2026-06-17): the `aws_admin_for_test_simulation` test-simulation fixture moved out of `prodbox-config(-types).dhall` into the test-harness-only `test-config.dhall`, and elevated-credential acquisition is unified on the interactive `SecretRef.Prompt` (`Prodbox.Aws.AdminCredentials.acquireAdminAwsCredentials`; the harness simulates the prompt from `test-config.dhall`). Sprint `7.17` ✅ landed (2026-06-17) on its code-owned surface: a new `Prodbox.Config.SchemaDhall` renderer generates `prodbox-config-types.dhall` / `test-config-types.dhall` from the Haskell `ConfigFile` / `defaultConfigFile` source of truth (`Dhall.expected` for the Type, `Dhall.inject` for the default), `prodbox config schema` / `config setup` / `config validate` materialize them, both are now git-ignored, and six round-trip drift-guard tests prove the generated schema decodes to `defaultConfigFile` — retiring the hand-maintained Dhall↔Haskell duplication. It depended only on Sprint `7.16` (same phase) and Sprint `1.35` (earlier phase) — forward-only per Standard N. The one-time `git rm --cached` to untrack the already-committed `prodbox-config-types.dhall` is an operator follow-up (git-workflow policy). Current Sprint `7.14` gates: full unit 950/950, CLI integration 38/38, env integration 38/38, live home `cluster reconcile` + sealed-vault proof, docs check/lint 0, `git diff --check` 0, and canonical dev check 0. Sprint `7.15` ✅ landed (2026-06-17) on its code-owned surface: ACME EAB (`acme.eab_*`) is now `SecretRef.Vault` (Vault KV `secret/acme/eab`, validation-enforced), materialized into the cert-manager `ClusterIssuer` via a Vault-login Job; the deeper TLS private-key / native-Vault-PKI material (public ZeroSSL keeps the S3 retain-restore contract) is the non-blocking `Live-proof: pending` axis. The single ZeroSSL issuer + S3 retain-restore is unchanged; a sealed Vault fails new issuance and key retrieval closed. Prior closure preserved: ✅ Done on owned surfaces — reopened 2026-06-09 for Sprints `7.12`–`7.13` (design-intention review; see Closure Status), both landed 2026-06-09: `7.12` made substrate equivalence structural (one `ContainerImage` Envoy release pin — the C79 skew is gone — + the per-substrate-repin lint + `[PlatformComponent]` coverage test + "no Harbor on EKS" prose fix); `7.13` renamed the issuer to the DNS-01-honest `zerossl-dns01` + reattributed shared-route ownership to the keycloak chart + removed the `PublicEdge.hs` `PRODBOX_*` read. Gates: `check-code` 0, `test unit` 821, `integration cli` 35, `integration env` 35. Prior closure preserved: ✅ Done on owned surfaces (Sprints 7.1–7.11) — Phase 7 reclosed 2026-06-07 when ✅ Sprint 7.11 landed: `acmeRuntimeManifestWith` renders one cert-manager `ClusterIssuer` — `zerossl-dns01` (`acme.server`, EAB-authenticated; renamed from the historical HTTP-01 spelling by Sprint 7.13) — with a factored-out DNS-01 Route 53 solver (`acmeRoute53Solver`) and the `zerossl-account-key` account key; both home (`ensureAcmeRuntime`) and AWS (`ensureAwsSubstrateAcmeRuntime`) paths wait for it; `publicEdgeTlsRetentionKey` defines the substrate-scoped retention key `public-edge-tls/<substrate>/<fqdn>` and `putLongLivedObject`/`getLongLivedObject` are the S3 access path consumed by Sprint 8.7. Gates green: `check-code` 0, `test unit` 690/690, `docs check` 0, `lint docs` 0, integration cli/env pass (only the 2 pre-existing `charts deploy vscode` environmental failures remain). The live single-issuer + S3-retention behavior is the Phase 8 Sprint `8.8` gate. Sprints 7.1–7.10 remain ✅ Done on owned surfaces. Sprint 7.5 closed June 5, 2026 after live `./.build/prodbox test all --substrate aws` proved AWS NLB-target Route 53 reconciliation, delegated-subzone cleanup, per-run postflight teardown, Harbor-login retry, Keycloak public-token-endpoint readiness, VS Code OIDC redirect, API/WebSocket in-cluster JWKS backchannels, substrate-aware Harbor/MinIO admin routes, public DNS, destructive lifecycle, and operational IAM/config postflight cleanup. The aggregate run's remaining failure is Phase 8-owned invite-auth closure, not a Phase 7 substrate gap. Sprint 7.8 is also Done on the operational managed-resource registry surface; the `PerRun` ∪ `Operational` teardown merge remains a tracked follow-on, not an open Sprint 7 blocker. | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ✅ **Reclosed 2026-06-14** after the 2026-06-11 reopen and Vault-root finalization (Vault-root + cluster federation). Sprint `8.9` reframes to the finalized end state: the `keycloak-smtp` SMTP credential and invite-flow OIDC client secrets are Vault KV objects consumed via Vault Kubernetes auth, and a sealed Vault bricks Keycloak bootstrap and the invite/secret-dependent startup paths — ✅ Done on its code-owned surface (already delivered by the Sprint `3.18` Vault-materialization work and confirmed in [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)); the both-substrate live `keycloak-invite` exercise (real SES send + a live sealed-Vault-fails-invite proof) is the non-blocking 🧪 axis (Standard O). The invite-auth flow is extended; its secrets are no longer derivation- or chart-generated. Prior closure preserved: ✅ Done on owned surfaces (Sprints 8.1–8.8; closed 2026-06-09 — see the Closure Status notes) (✅ Sprint 8.1 code + doctrine + live SES provisioning + verification May 18, 2026; ✅ Sprint 8.2 Keycloak realm chart + live deploy proof on home substrate May 18, 2026; ✅ Sprint 8.3 CLI surface + live Keycloak admin API HTTP integration; ✅ Sprint 8.4 SES prerequisites; ✅ Sprint 8.5 suite content + dispatch arm + live invite/capture/link-follow steps + SES SMTP IAM-to-SMTP-password derivation + chart-secret persistence landed; June 6 credential-setup form POST + fresh invited-user OIDC claim assertions are wired locally and unit-tested (674/674 after the home SMTP-reconcile, SMTP NetworkPolicy, verify-email continuation, public-edge certificate status-patch renderer, and public-edge TLS Secret retention fixes), with live home/AWS substrate proof later closed; ✅ Sprint 8.6's targeted AWS `keycloak-invite` proof is green after the canonical ordering/substrate-host/public-admin-route/targeted-harness/SMTP-secret-sync/Phase-1.6-restore/namespace-adoption/invite-link-normalization/public-edge-cert-reissue/ACME-provider work: the validation now runs before destructive `ValidationChartsStorage` / `ValidationLifecycle`, targets the selected substrate public FQDN, routes `/auth/admin` to Keycloak for the invite admin API, materializes operational credentials from `aws_admin_for_test_simulation.*`, syncs `keycloak-smtp` before Keycloak renders, syncs the same Secret during invite-aware home runtime bootstrap, patches preserved Keycloak realms from `keycloak-smtp` before invite sends, avoids duplicate local `rke2 reconcile`, adopts SMTP pre-created Keycloak release namespaces, accepts text/html duplicate invite links, repairs failed public-edge certificate issuance, retains the public-edge TLS Secret across chart namespace resets, uses the ZeroSSL ACME path, and passes targeted AWS invite capture/link-follow with harness cleanup. AWS aggregate rerun and live Sprint 8.5 POST/OIDC substrate proof later closed; the home rerun runs against the single ZeroSSL issuer whose certificate is retained in S3 and restored before issuance. ✅ Sprint 8.7 (chart-platform cert retention refactor: silent-success gap closed via the typed `PublicEdgePreserveOutcome`, S3 restore-before-issue on all rebuild paths — landed 2026-06-07 on the code-owned surface; gates green, unit 690/690) and ✅ Sprint 8.8 (live `keycloak-invite` gate closure on the ZeroSSL issuer plus the certificate round-trip and AWS parity) carried the live invite-auth closure. ZeroSSL is the sole ACME provider; the two-issuer/`IssuerClass` model from 7.11/8.7 was reverted to a single ZeroSSL issuer 2026-06-07.) Sprints 8.1–8.8 ✅ Done — 8.5/8.6 closed live 2026-06-08/09 (home + AWS `keycloak-invite` end-to-end, OIDC claims verified, no leak); 8.8 closed via the home + AWS `test all` aggregates (both green), the cert round-trip restore-no-reorder proof, and the `prodbox nuke` proof exercised through the interactive integration harness. Phase 8 closed. **Independent Validation**: the invite-auth flow and its Vault-backed SMTP/OIDC secret consumers are validated on the code-owned surface and against the home/local substrate (the live home `keycloak-invite` proof), with no dependency on a later phase; AWS-substrate coverage is tracked in [substrates.md](substrates.md)'s parity table. | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

**Status interpretation**: As of 2026-06-15 the MinIO/Pulumi encryption strategy is **finalized to
Model B** (prodbox object-level Vault-Transit envelope) with **whole-system zero-child-info** framing
— one generically-named bucket of opaque `objects/<hmac>.enc`, `prodbox-envelope-v2` hashed AAD,
decoy-pad-to-constant-count, a decrypt-to-scratch Pulumi interposition, a uniform `aws-ses` envelope,
and Pulumi's own secrets provider dropped. This **refines, it does not reverse**, the 2026-06-14
model and reopens **no new phase** — it reframes the already-scheduled Sprints `1.37`/`4.30`/`7.14`
and added docs-only Sprint `0.14` + Sprint `4.33` (now closed 2026-06-16); see the 2026-06-15 and
2026-06-16 Closure Status entries.
As of 2026-06-16, Phase `3` Sprint `3.19` has removed the master-seed derivation machinery from
the supported path: the retired derivation/master-seed/inventory/ensure-namespace/wire modules,
gateway `/v1/secret/*` RPCs, daemon-only-seed lint, host gateway-derive seam, and gateway
self-bootstrap path are gone, and the Sprint `3.19` legacy rows are completed; Sprint `3.20` is also
closed. As of 2026-06-14 the Vault model is **finalized to Vault-root +
cluster federation**, superseding the 2026-06-11 "Vault extends — it does not reverse" framing for
the derivation model: Vault is the sole, finalized secrets / KMS / PKI root, a sealed Vault bricks
the cluster (hard fail-closed), the master-seed HMAC derivation model is **retired** (not extended),
and `FileSecret` / Secret-mounted plaintext Dhall is **removed** (not bridged). Phase `2` reopens
2026-06-14 for the cluster-federation custody (Sprint `2.26`), **in addition to** Phases `0`, `1`,
`3`, `4`, `5`, `7`, and `8` (reopened 2026-06-11 and finalized 2026-06-14 to the Vault-root +
federation model — Sprints `0.12`–`0.13`, `1.35`–`1.38`, `3.17`–`3.20`, `4.29`–`4.32`, `5.8`,
`7.14`–`7.15`, `8.9`); Phase `6` stays `Done` on its owned surface. The doctrine SSoT is
[../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) and the
federation trust tree is
[../documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
see the 2026-06-14 Closure Status entry. The earlier 2026-06-11 Vault reopen and the design-intention
reopen history follow. As of 2026-06-09 (later) Phases `0`, `1`, `2`,
`3`, `4`, `5`, and `7`
are reopened for the design-intention review (Sprints `0.9`–`0.10`, `1.29`–`1.32`, `2.24`–`2.25`,
`3.15`–`3.16`, `4.26`–`4.27`, `5.6`, `7.12`–`7.13`); Phases `6` and `8` stay `Done`. See the
2026-06-09 (later) Closure Status entry for the rationale and the which-stays-Done narration. The
earlier reopen history follows. Phase `0` reopened through Sprints `0.2`–`0.7` to adopt
[the engineering doctrine docs](../documents/engineering/README.md) and to add the LLM/automation guardrails on
the interactive command surface; Phase `0` is now `Done` on that planning, documentation, and
non-TTY-guardrail surface. Phases `1`–`4` were reopened on the downstream doctrine-driven
implementation work and are now reclosed. Phase `5` is re-closed after Sprint `5.5` added and
proved the port `80`
HTTP-to-HTTPS redirect on the existing single-host public edge. The pre-reopen Haskell rewrite
baseline, clean-room rerun, public-edge proof, and AWS-administration surfaces remain validated
on the supported Haskell command surface; Phases `5` and `6` remain `Done` on their owned
surfaces. On 2026-06-06 Phase `4` reopened (Sprint `4.24`: the public-edge production certificate
joins the managed-resource registry as a `LongLived` resource) and Phase `7` reopened (Sprint
`7.11`: two ACME `ClusterIssuer`s — staging + production — plus a substrate-scoped long-lived S3
cert-retention store, extending the substrate-aware Sprint `7.5.b` rendering); Phases `1`, `2`,
`3`, `5`, and `6` stay `Done` because their `Plan`/Apply, gateway, chart-platform, and
canonical-suite foundations are reused, not changed. **Phases `4` and `7` reclosed 2026-06-07** when
Sprints `4.24` and `7.11` landed on their code-owned surfaces (Sprint `4.24`: registry entry +
`discover`/`destroy` + generated table + soundness gate; Sprint `7.11`: the single ZeroSSL ACME
`ClusterIssuer` `zerossl-dns01` + the substrate-scoped S3 cert-retention key scheme and
access path). The live certificate round-trip and the home gate are the Phase 8 Sprint
`8.8` gates. Phase `8` stays open for Sprints `8.7`/`8.8` (and the live Sprint `8.5`/`8.6`
proofs). The overall handoff stays incomplete until
the cert refactor lands and the home `keycloak-invite` gate passes, with AWS
parity following (Phase `8` Sprints `8.7`/`8.8`). Phase `7`'s AWS-substrate parity work is
otherwise closed: the June 5, 2026 live AWS runs
proved NLB-target Route 53 reconciliation, delegated-subzone cleanup, per-run postflight
teardown, Harbor-login retry, Keycloak public-token-endpoint readiness, VS Code OIDC redirect,
API/WebSocket in-cluster JWKS backchannels, substrate-aware Harbor/MinIO admin routes, public
DNS, destructive lifecycle, and operational IAM/config postflight cleanup. The aggregate run's
remaining failure belongs to Phase `8`: the first June 5 run scheduled
`ValidationKeycloakInvite` after destructive `ValidationLifecycle`, the follow-up run reached
`ValidationKeycloakInvite` before lifecycle but still targeted the home `domain.demo_fqdn` for
the Keycloak admin token during the AWS-substrate run, and the next run validated the selected
AWS public FQDN before exposing that the Keycloak public auth route lacked the `/auth/admin`
match used by the invite admin API. The active fix places `ValidationKeycloakInvite` before
destructive `ValidationChartsStorage` and `ValidationLifecycle`, passes
`substratePublicFqdn settings substrate` into the Keycloak admin invite/revoke flow, and routes
`/auth/admin` to Keycloak. The targeted `keycloak-invite --substrate aws` rerun after the route
fix exposed the last standalone-run mismatch: named AWS-substrate validation still expected
pre-populated operational `aws.*` instead of the suite-driven
`aws_admin_for_test_simulation.*` harness. The runner/planner fix wraps targeted AWS-substrate
native validations in the managed IAM harness and preserves per-run-stack cleanup before
operational credential teardown. The follow-up targeted run proved that credential path through
per-run AWS provisioning and chart deployment, then reached the Keycloak invite-email trigger and
failed because the fresh EKS cluster had no `keycloak-smtp` Secret in the Keycloak release
namespace. The current fix syncs the retained long-lived `aws-ses` SMTP outputs into the
supported Keycloak release namespaces before AWS chart deployment. The June 6 targeted rerun
proved the hook placement, then failed because the configured long-lived Pulumi state bucket was
absent; the sync path now runs the same idempotent `ensureLongLivedPulumiStateBucket` precondition
as `aws-ses-resources` before reading the retained stack. The live `aws-ses-resources` repair
recreated the long-lived stack state by importing retained SES/S3/IAM resources, rotating stale
SMTP keys, and restoring `keycloak-smtp` in the supported local release namespaces. The next
June 6 targeted AWS rerun failed before AWS provisioning during Phase `1.6/2` local restore after
a duplicate full `rke2 reconcile` repeated Harbor image publication and exhausted the transient
Harbor login retry window. The active fix keeps Phase `1.5/2` as the single local runbook
reconcile for suites that already require it and lets Phase `1.6/2` perform the chart reset without
rerunning local image publication. Local validation for that guard passed with
`./.build/prodbox test unit` (658/658), `./.build/prodbox check-code`, docs lint/check,
`git diff --check`, and `./.build/prodbox test integration cli` (30/30). The next targeted AWS
rerun proved the duplicate-reconcile guard in the live harness, reached AWS chart deployment, and
then failed at the `gateway` Helm install because SMTP sync had pre-created the `keycloak`
namespace without the Helm ownership metadata needed for the gateway chart's RBAC Namespace
resource to adopt it. The active fix stamps gateway-release Helm ownership and
`helm.sh/resource-policy: keep` on SMTP pre-created Keycloak release namespaces, with matching
metadata in the gateway chart Namespace resources. The follow-up targeted AWS rerun proved that
namespace-adoption fix live by moving through gateway install and into the invite validation body,
then exposed the next Sprint 8.5 parser edge: Keycloak multipart email repeats the same
action-token URL in text and HTML forms that differ only by URL-local quoted-printable encoding.
The active parser fix normalizes extracted invite URLs for Keycloak's `=3D` query-delimiter
encoding and HTML `&amp;` before distinct-link detection. The next targeted AWS rerun was
interrupted before AWS provisioning because the home-local public-edge certificate repair helper
deleted stale ACME child resources after a failed order but did not mark the Certificate for
immediate reissuance. The first harness fix patches the Certificate status with an
`Issuing=True` manual-trigger condition after stale-resource cleanup; the follow-up live rerun
showed the same failed-Certificate state can recur after a prior cleanup has already removed every
stale child resource, so the active no-target branch triggers the same manual reissue patch when
there is nothing left to delete. Local validation for that no-target branch passed with
`./.build/prodbox test unit` (661/661), docs lint/check, `git diff --check`,
`./.build/prodbox check-code`, and `./.build/prodbox test integration cli` (30/30). The follow-up
targeted AWS rerun reached public-edge readiness with a fresh active ACME Order, then stalled
on a transient ACME-endpoint response in that environment. Local validation passed with
`./.build/prodbox test unit` (661/661), docs lint/check, `git diff --check`,
`./.build/prodbox check-code`, and `./.build/prodbox test integration cli` (30/30). The first
targeted AWS rerun after that failed before AWS provisioning because local
DiskPressure caused MetalLB rollout timeout; harness cleanup completed, then generated temp image
artifacts plus dangling Docker/build cache were pruned. The follow-up targeted AWS rerun recovered
the local runtime through the harness `rke2 reconcile`, validated MetalLB, Envoy Gateway,
cert-manager, the ZeroSSL ClusterIssuer, and Percona readiness, provisioned the per-run AWS
substrate, deployed `gateway`, `vscode`, `api`, and `websocket`, entered
`ValidationKeycloakInvite`, captured the SES invite email, parsed and followed the normalized
invite link, exited the validation body successfully, destroyed per-run AWS stacks with residue
checks, and cleared operational IAM/config material.
The follow-up home-substrate Sprint 8.5 POST/OIDC rerun proved the Keycloak 26 verify-email
continuation handling far enough to re-enter public-edge certificate repair, then exposed a local
harness bug: the status patch used to trigger immediate cert-manager reissuance was malformed
JSON. The status patch renderer now uses structured Aeson encoding with a unit decode guard.
Local validation for that guard passed with `./.build/prodbox test unit` (673/673),
`git diff --check`, and `./.build/prodbox check-code`; the live home invite rerun remains the
next ordered gate before AWS POST/OIDC validation. The next live home rerun proved that status
patch fix and reached cert-manager reissue retry, then hit the ACME provider's certificate
issuance rate limit for the public-edge hostname. The chart platform now backs up an
issued `public-edge-tls` Secret into the stable `prodbox` namespace before deleting the `vscode`
chart namespace and restores it before re-applying the Keycloak/Gateway chart. Local validation
for that retention fix passed with `./.build/prodbox test unit` (674/674), docs lint/check,
`git diff --check`, and `./.build/prodbox check-code`; the already-issued Secret had been lost
before the fix landed, so the live home gate waits for the provider window to reset on
June 7, 2026 UTC.

Phase `8` was opened May 18, 2026 with the full code + doctrine layer of Sprints
`8.1`–`8.6` landed in a single session: `pulumi/aws-ses/` (Pulumi program for the
SES sending identity, receive subdomain MX, receive rule set, S3 capture bucket, and
SMTP IAM user); `src/Prodbox/Infra/AwsSesStack.hs` orchestration plus
`prodbox pulumi aws-ses-resources` / `aws-ses-destroy` CLI surface; the
`ses : { sender_domain, receive_subdomain, capture_bucket }` block in
`prodbox-config-types.dhall` and `prodbox-config.dhall`; Keycloak realm chart updates
(`verifyEmail: true`, `smtpServer` from the looked-up `keycloak-smtp` Secret) under
`charts/keycloak/`; the operator-facing `prodbox users invite|list|revoke` surface in
`src/Prodbox/CLI/Users.hs` and `src/Prodbox/UsersAdmin.hs`; three new
prerequisite nodes (`ses_sending_identity_verified`, `ses_receive_rule_set_active`,
`ses_receive_bucket_accessible`) wired through `src/Prodbox/Effect.hs`,
`src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs` with AWS CLI
validators; the `ValidationKeycloakInvite` / `IntegrationKeycloakInvite` canonical-suite
variants planned by `src/Prodbox/TestPlan.hs` and dispatched through
`src/Prodbox/TestValidation.hs`; and the cross-substrate shared-SES doctrine in
[substrates.md](substrates.md) and
[documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md).
Validated with `prodbox check-code`, `prodbox lint docs`, `prodbox docs check`, and
`prodbox test unit` (312/312). The residual live operator workflows that were tracked for Phase `8`
at that point — Sprint `8.5` live credential-setup form POST plus fresh OIDC login / claim
assertions, and the Sprint `8.6` AWS aggregate rerun after the targeted
`keycloak-invite --substrate aws` proof validated the fixed canonical ordering, selected substrate
public FQDN, `/auth/admin` route, managed IAM harness, fresh-cluster `keycloak-smtp` sync, ZeroSSL
ACME path, invite capture/link follow, and cleanup — have since closed under the Phase `8` live
closure notes.

## Substrate Parity

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates,
with no fallback between them (see
[Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)).
A complete canonical-suite proof requires both the home local and AWS substrate rows below to
land independently against their own real infrastructure. The authoritative substrate
inventory is [substrates.md](substrates.md); this section is the live tracker for substrate
parity. The authoritative AWS resource inventory and per-resource lifecycle class (auto-managed
per-run stacks vs long-lived cross-substrate shared infrastructure) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Suite parity | Phase ownership |
|-----------|-----------|----------|--------------|-----------------|
| Home local | `prodbox rke2 reconcile` + `prodbox charts deploy ...` | `prodbox rke2 delete --yes` | ✅ Full canonical suite, including real ZeroSSL, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com`. Re-verified May 27, 2026 via `prodbox test all` run-4 (~1h35m, all 16 named canonical validations `ExitSuccess` except `keycloak-invite`; Sprint 8.5 now has local POST/OIDC wiring plus SMTP Secret / preserved-realm reconciliation, SMTP NetworkPolicy, verify-email continuation, public-edge certificate status-patch, and public-edge TLS Secret retention unit proof, with a live home-substrate rerun still required — closed under Phase 8 Sprint 8.8 on the single ZeroSSL issuer whose certificate is retained in S3 and restored before issuance, so the high-churn gate never re-orders it) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| AWS | `prodbox pulumi eks-resources` + `prodbox pulumi aws-subzone-resources` + `prodbox pulumi test-resources` | `prodbox pulumi aws-subzone-destroy --yes` + `prodbox pulumi eks-destroy --yes` + `prodbox pulumi test-destroy --yes` | ✅ Phase 7-owned substrate parity proved live June 5, 2026 across the 15-step substrate-platform install, AWS public DNS, VS Code/API/WebSocket/admin-route validations, destructive lifecycle, and per-run postflight cleanup. Targeted `keycloak-invite --substrate aws` also passes invite capture/link-follow with the AWS substrate public FQDN, `/auth/admin` route, managed IAM harness, SMTP sync, and ZeroSSL ACME path. The formerly open Phase 8 aggregate / POST-OIDC closure work later closed under Sprints `8.5`/`8.6`/`8.8`; any future AWS aggregate rerun is tracked as a parity proof axis, not an open phase. | [phase-7-aws-substrate-foundations.md → Sprint 7.5](phase-7-aws-substrate-foundations.md) |

## Current Plan Status

As of 2026-06-16 the secrets model is **finalized to Vault-root + cluster federation** (see the
2026-06-14 Closure Status), and the Phase `1` foundation sprints `1.35`–`1.38` are ✅ **Done on
their owned surfaces**. Sprints `2.26`, `3.19`/`3.20`, and `4.29`–`4.33` have also closed their
code-owned foundations. Sprint `5.8` is ✅ Done on its code-owned surface (named validation surface
landed and proven on the home substrate) with a non-blocking 🧪 AWS-substrate live-proof pending;
remaining finalized-model work is tracked in the later owning phases on their own surfaces: Sprint
`5.8` AWS live-proof, `7.14`–`7.16`, and `8.9`. Per
[Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking) these later
items never block or reopen an earlier phase. Sprint `7.16` (✅ Done on its code-owned surface 2026-06-17) moved the `aws_admin_for_test_simulation`
test-simulation fixture out of `prodbox-config.dhall` into the test-harness-only `test-config.dhall`
and unifies elevated/admin AWS acquisition on the interactive `SecretRef.Prompt`, so
`prodbox-config.dhall` carries no admin block and the generated operational `aws.*` is minted into
Vault KV only after unseal with the file carrying only its `SecretRef.Vault` reference.

As of 2026-06-15 the MinIO/Pulumi encryption strategy is **finalized to Model B** (prodbox
object-level Vault-Transit envelope) with whole-system zero-child-info framing (see the 2026-06-15
Closure Status). This refines, it does not reverse, the 2026-06-14 model and reopens no new phase.
The Model-B code-owned foundations now landed through Sprint `4.33`: Sprint `0.14` closed the
doctrine harmony, Sprint `1.37` closed the Vault-readiness gate and production Vault-Transit
`DekCipher`, Sprint `4.30` closed the shared Model-B object-store, and Sprint `4.33` closed the
Haskell-side sealed-state residue/oracle/log scrub. The remaining Model-B implementation named at
that point later closed under Sprint `7.14`: the decrypt-to-scratch Pulumi interposition applied
uniformly to per-run and `aws-ses` backends with Pulumi's secrets provider dropped. The live
sealed-state proof for the deployed stack
is owned by Sprint `5.8` as a non-blocking 🧪 live-infra axis — it shares the AWS-substrate live
prerequisites Sprint `7.14`'s own live-proof needs, but per
[Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) neither
gates the other's code-owned closure and neither blocks an earlier phase; `vault_doctrine.md §9/§10`
is the doctrine SSoT.

The development plan remains authoritative. The repository worktree is fully closed against the
pre-reopen scope (Sprints 1.1–1.5, 2.1–2.8, 3.1–3.7, 4.1–4.4, 5.1–5.4, 6.1–6.3, 7.1–7.4), and
the doctrine-adoption reopen is now closed as well. Current worktree evidence puts Sprints
`0.7`, `1.6`–`1.27`, `2.9`–`2.16`, `3.8`–`3.12`, `4.5`–`4.8`, `4.14`, `4.15`, `5.5`,
`7.5.a`/`7.5.b.*`/`7.5.b.iii`/`7.5.c.i`–`7.5.c.iv`/`7.5.c.v.b`/`7.5.c.v.c`/`7.5.c.v.d`/
`7.5.c.v.e`/`7.5.c.v.f`/`7.5.c.v`, `7.6`, `7.7`, `7.8`, `7.9`, `7.10`, and `8.1`–`8.4` in `Done` state on their owned surfaces.
Sprints `4.10`–`4.13` have their full code bodies landed on their code-owned surfaces (May 21,
2026: Sprint 4.10's admin-credential switch + historical in-process migrate-backend body +
Pulumi.yaml backend URL, later superseded by Sprint `7.14`'s encrypted first-touch migration;
Sprint 4.11's full predicate inventory `noLivePerRunPulumiStacks`,
`noLiveLongLivedPulumiStacks`, `noLiveClusterTaggedAws`, `noUndrainedK8sAwsResources`,
`noLiveOperationalIamUser`, `noLeftoverDnsBootstrapRecords`; Sprint 4.13's
five-step nuke orchestration body + `destroyLongLivedPulumiStateBucket` helper); each was
exercised against the home substrate through `prodbox test all` runs that reached
`ready-for-external-proof` classification and ran every named canonical validation through to
the per-run Pulumi destroys. The live destructive `nuke` exercise and the live cascade exercise
against a running AWS-side cluster remain operator-driven follow-ups. A Sprint `7.5.c.v.d`
follow-up landed the same day to extend the operational IAM policy with the
`iam:CreatePolicy` / `CreateOpenIDConnectProvider` lifecycle actions the EKS Pulumi program
needs (run 3 / run 4 surfaced both gaps via live AWS AccessDenied); after the grants landed the
`aws-eks` validation provisioned EKS + LB controller IRSA + EBS CSI IRSA + OIDC provider and
destroyed cleanly. The remaining Phase `8` work that was active at that point — Sprints
`8.5`–`8.6` live substrate validation of the credential-setup POST / fresh OIDC claim assertions
plus the AWS aggregate rerun after the targeted AWS `ValidationKeycloakInvite` path passed with the
selected substrate public FQDN, `/auth/admin`, SMTP sync, ZeroSSL ACME, invite capture/link follow,
and cleanup — later closed under the Phase `8` live-closure notes. ✅ Sprint `4.24` (public-edge
certificate registered as a `LongLived` managed resource) and ✅ Sprint `7.11` (the single
ZeroSSL ACME `ClusterIssuer` `zerossl-dns01` with a DNS-01 Route 53 solver, plus the
substrate-scoped long-lived S3 cert-retention key scheme + access path) both landed 2026-06-07
and reclosed Phases `4` and `7` on their code-owned surfaces. ✅ Sprint `8.7` (chart-platform
cert retention refactor — S3 restore-before-issue) also landed 2026-06-07 on its code-owned
surface. The former Phase `8` operator-driven live gates — Sprints `8.5`/`8.6`
(live home/AWS credential-setup POST + fresh-OIDC-claim proofs and the AWS aggregate rerun) and
Sprint `8.8` (the live `keycloak-invite` gate on the ZeroSSL issuer plus the one-time certificate
round-trip and the nuke-only-removes-the-retained-cert proof) — later closed under the Phase `8`
live-closure notes. The following
implemented baseline surfaces remain current on the supported path:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding repo-root `prodbox-config.dhall` in-process through the native `dhall` library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, repository-root config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- Every runtime path by which elevated/admin AWS power enters prodbox — `config setup`, `aws setup`,
  the native IAM harness, the long-lived `aws-ses` stack ops, and `prodbox nuke` — acquires the
  ephemeral elevated credential through the interactive `SecretRef.Prompt`, uses it once, and
  discards it. The `aws_admin_for_test_simulation.*` fixture is a test-harness-only `TestPlaintext`
  fixture in `test-config.dhall` whose sole purpose is to simulate that operator prompt
  non-interactively; it is never read by a production binary and never stored in
  `prodbox-config.dhall` or Vault. (Sprint `7.16` lands this move out of `prodbox-config.dhall`.)
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`,
  and `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins, destroys validation-owned
  per-run stacks when the targeted suite may provision them, and clears those credentials again
  before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `rke2 reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from the
  `test-config.dhall` `aws_admin_for_test_simulation.*` fixture (simulating the operator's
  interactive admin-credential prompt) because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from `prodbox-config.dhall` before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  repository-root credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.12.4`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target remains Haskell-owned and Harbor-first: Harbor plus
  Harbor's storage backend bootstrap from public registries, after which required public images
  and custom images are present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries transient Harbor publication failures on the same candidate and
  then falls through to alternate configured upstreams when publication still fails after manifest
  inspection, with `mirror.gcr.io` fallbacks now covering the Docker Hub-hosted Percona and Envoy
  images used by the supported lifecycle.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on native-host-architecture image
  publication only: `amd64` hosts publish `amd64`, `arm64` hosts publish `arm64`, and no
  supported lifecycle path uses `docker buildx` or cross-arch emulation.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox charts ...` runtime now rejects internal `keycloak-postgres` and `redis`
  dependency releases directly and keeps those names reachable only through their owning root-
  chart orchestration.
- The public `prodbox pulumi ...` surface is limited to the AWS substrate stacks under
  `pulumi/aws-eks/` and `pulumi/aws-test/`. Non-secret validation inputs are synchronized through
  stack config, while AWS provider credentials stay only in `prodbox-config.dhall` and the
  Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs`: config generation, heartbeat recording, in-memory ownership
  projection, DNS-write gating, the bounded HTTP `/v1/state` observability payload, HMAC event
  signing, Orders-backed gateway-interval validation, peer-transport gossip with commit-log
  replication through `peerListenerLoop` and `peerDialerLoop`, runtime claim/yield emission under
  the `canWriteDns` predicate, bounded-clock-skew enforcement keyed off
  `daemonMaxClockSkewSeconds`, and monotonic Orders-version coordination across the mesh are all
  implemented there today.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox pulumi ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Harbor, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports the
  single union runtime image (`prodbox-runtime`, shared by the gateway daemon and the api/websocket
  workloads) during `rke2 reconcile`.
- The supported public-edge auth doctrine now makes the carrier and key-discovery boundary
  explicit: JWT-only API routes validate request-carried bearer tokens locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys, Envoy-managed browser auth returns
  through the edge redirect and cookie or session path, and direct-OIDC workloads keep their
  carrier or session state workload-owned.
- Keycloak availability now stays explicit in the plan: it is required for new logins, refresh
  flows, and later JWKS refresh, but the steady-state JWT request path does not synchronously call
  Keycloak or Redis while Envoy still has cached signing keys and the presented tokens remain
  valid.
- The current supported transport boundary now stays explicit in the plan: public TLS terminates at
  Envoy for the shipped `/vscode`, `/api`, and `/ws` routes on
  `test.resolvefintech.com`, while backend TLS or mTLS is outside the supported
  chart-workload contract unless a later doctrine revision expands that path.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host route catalog and issuer derivation
  consumed by lifecycle, DNS, chart, host-diagnostic, and native validation surfaces, keeping
  `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus the governed public-edge, gateway, chart-platform, registry, and testing
  doctrine docs now describe that same supported route catalog and command surface, and the
  earlier Phase `2`, `3`, and `4` implementation gaps are closed in the same code-backed paths.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `workload.mode = Api \| Websocket` runtime selector
  (sourced today from the `PRODBOX_WORKLOAD_MODE` env var; Sprint 3.14 migrates this to the
  mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md)),
  JWT-only API delivery, Redis-backed shared-state continuity on the WebSocket route, workload-
  managed OIDC bootstrap, real `/ws` upgrade handling, and settings-backed workload scaling.
- The current WebSocket doctrine now states that one upgraded connection remains pinned to one
  selected backend pod until disconnect, reconnect-safe state must live outside the pod, and the
  implemented runtime now closes on readiness-based drain plus revocation-driven reconnect
  behavior on the real `/ws` path.
- Redis now stays explicit as shared application state for the current WebSocket surface and any
  later explicit external rate-limit service, but the current supported worktree still does not
  ship a standalone rate-limit-service workload or validation path.
- `src/Prodbox/Host.hs` and `src/Prodbox/TestValidation.hs` now classify and validate the
  current Keycloak identity, `vscode`, `api`, `websocket`, Harbor, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox check-code`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The final Phase `6` destructive rerun and handoff validation are closed on that aggregate rerun
  contract and the supported postflight restore path.
- The legacy ledger preserves completed cleanup history. After the doctrine-adoption reopen
  closure the `Pending Removal` section was empty; the May 23, 2026 reopen of Phases `2`, `3`,
  and `4` (Sprints `2.17`, `2.18`, `2.19`, `3.13`, `4.16`, `4.17`, `4.18`) reintroduced
  doctrine-aligned residue rows (file-existence stack predicates, the `.prodbox-state/` host-side
  cache, the host-side chart-secret cache plus `.patroni-anchor-volume` marker, and the remaining
  `curl` shell-outs in `src/Prodbox/TestValidation.hs`, `Workload.hs`, and `CLI/Rke2.hs`), each
  scoped to its owning sprint.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   Pulumi orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from operator-authored
   repository-root `prodbox-config.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary admin credentials entered interactively by the
   operator.
5. `aws_admin_for_test_simulation.*` lives only in the test-harness-only `test-config.dhall`
   (`TestPlaintext`), never in `prodbox-config.dhall` or Vault, and its sole purpose is to
   simulate the operator's interactive admin-credential prompt for suite-driven destructive
   validation and long-lived stack / `prodbox nuke` flows. Public `config setup`, public
   `aws ...`, the long-lived `aws-ses` stack ops, and `prodbox nuke` all acquire the ephemeral
   elevated credential through the interactive `SecretRef.Prompt` — there is no production
   config-backed admin path.
6. `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
   validation harness that deletes any pre-existing dedicated `prodbox` IAM user and all of that
   user's access keys before provisioning, uses any pre-existing `aws.*` credentials only to
   discover and delete the IAM user associated with those credentials, proves STS-federated
   operational credentials with a compact AWS-validation session policy, waits for the dedicated
   IAM-user credentials to pass STS and repeated Route 53 hosted-zone probes, materializes
   IAM-user operational `aws.*` only from the `test-config.dhall` `aws_admin_for_test_simulation.*`
   fixture to simulate the interactive admin-credential prompt of the public CLI workflow because
   cert-manager Route 53 DNS01 credentials do not support
   an STS session-token field, destroys validation-owned per-run stacks when the targeted suite may
   provision them, and clears operational `aws.*` from `prodbox-config.dhall` before returning so
   no test-created dedicated IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.12.4`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox check-code` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close on the implemented bounded HTTP `/v1/state` observability payload, the
    Orders-backed gateway-interval relationships enforced by `src/Prodbox/Gateway/Types.hs`, and the current
    correspondence notes in `documents/engineering/tla_modelling_assumptions.md`.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox host public-edge`, `prodbox test integration charts-vscode`,
    `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and the
    named admin-route validations close on Gateway, `HTTPRoute`, auth policy, certificate, and
    one Route 53 record rather than `IngressClass`, `Ingress`, or per-FQDN state.
17. Supported config, onboarding, lifecycle, and validation surfaces remove `example.com`
    entirely and do not accept or emit placeholder public domains.
18. MetalLB supports both the L2 implementation path and a config-selected BGP implementation path
    on the supported self-managed cluster surface.
19. Envoy validates Keycloak-issued JWTs locally and applies route-level RBAC for application and
    admin routes. Issuer, audience, path-claim requirements, bearer-token carriers, browser
    return paths, and JWKS discovery or refresh ownership remain explicit.
20. Redis appears only as repo-owned app-level shared state for supported realtime or rate-limit
    workloads; it is never part of Envoy JWT validation, and the current supported worktree does
    not yet ship a standalone external rate-limit-service surface.
21. Supported WebSocket workloads authenticate at connection setup on the shared-host `/ws`
    route, keep reconnect-safe state outside the pod, keep each live upgraded connection pinned
    to one backend pod until disconnect, define token-expiry and authorization-change behavior
    explicitly, leave per-message authorization to the workload when messages need finer-grained
    permissions than the edge can enforce, scale horizontally behind Envoy, use readiness-based
    drain before pod exit, and add named validations for reconnect, connection-pinning,
    token-expiry handling, authorization-change assumptions, readiness-based drain,
    per-message authorization ownership, and shared-state assumptions.
22. Keycloak-backed public workloads stay proxy-aware behind Envoy on the shared hostname rather
    than on a dedicated identity host. Keycloak availability gates login, refresh, and later
    JWKS refresh, while cached signing keys and unexpired tokens keep the steady-state JWT hot
    path local to Envoy.
23. Public TLS terminates at Envoy on the supported path, and one certificate covers
    `test.resolvefintech.com`. Backend TLS or mTLS is not part of the current supported workload
    contract unless a later doctrine revision makes that backend transport explicit.
24. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
    storage backend during bootstrap.
25. Every later supported Helm deployment obtains its images from Harbor.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    Harbor after Harbor bootstrap and before those later deployments.
27. Supported custom-image builds and Harbor publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox pulumi ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
33. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
    cleanup.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only, the append-only commit log replicates between nodes as the canonical heartbeat-and-event
    transport, and `/v1/state` exposes per-peer transport health for operator inspection.
36. The gateway daemon emits signed `Claim` and `Yield` events on owner transitions and gates
    Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
    `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log rather than only
    on the model, and a stale owner cannot reclaim DNS write authority without first observing its
    own yield being superseded by a fresh claim.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer events from a
    peer presenting an older Orders version, a new Orders version propagates through commit-log
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
