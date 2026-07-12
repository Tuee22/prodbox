# Prerequisite Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/cli_command_surface.md, documents/engineering/code_quality.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/unit_testing_policy.md, documents/engineering/host_platform_doctrine.md, documents/engineering/bootstrap_readiness_doctrine.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md
**Generated sections**: none

> **Purpose**: Define the fail-fast prerequisite doctrine for supported `prodbox` command flows.

## 0. Canonical Doctrine Statements

- Prerequisite nodes validate existence or readiness and fail fast with actionable fix hints.
- Manual environment repair belongs only to requirements outside prodbox's managed-resource
  ownership. A doctrine-assigned bounded self-heal for repository-managed **local** state may be
  visible and re-verified inside its existing gate; externally authoritative resource mutation is
  instead a separate plan action (§4A).
- The canonical prerequisite registry lives in `src/Prodbox/Prerequisite.hs`.
- Runtime-stability waits that follow prerequisite success belong in explicit runbook or lifecycle
  steps, not in hidden prerequisite side effects.
- External desired-state mutation is never a prerequisite side effect. When a selected validation
  requires a registered retained resource, a read-only prerequisite gates a separately visible
  preparation reconcile; absence is an input to that plan, not a prerequisite failure demanding
  manual provisioning.
- Substrate-required prerequisites are total. When a per-substrate canonical-suite run is
  selected via `--substrate {home-local|aws}`, every prerequisite that the active substrate
  requires must be satisfied for that substrate's real infrastructure; missing config or
  unmet readiness fails fast with an explicit error naming the missing field. Prerequisites
  must not silently substitute the other substrate's values. See
  [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback).

## 1. Philosophy

Prerequisites exist to prevent expensive runtime work from starting in a known-bad environment.

The supported doctrine is:

1. check early
2. fail fast
3. emit one actionable root-cause message
4. do not silently auto-install tools from prerequisite checks

## 2. Prerequisite Categories

Typical prerequisite categories include:

- supported host properties such as the detected `host_substrate_supported` multi-OS host gate;
  `supported_ubuntu_2404` remains as an explicit compatibility node, not the cluster prerequisite
  root
- required host tools such as `aws`, `curl`, `dig`, `docker`, `helm`, `kubectl`, `pulumi`, and
  `ssh`
- repository configuration readiness through in-process decoding of executable-sibling
  `prodbox.dhall` by the native `dhall` Haskell library
- cluster-backed runtime readiness, including exact Bootstrap Broker, Lifecycle Authority,
  Authority Backup Adapter, TLS Retention Adapter, fenced Provider Worker, Target Secret Agent,
  and permit-bound one-shot Job capability references
- AWS- and Route-53-backed readiness

The Ubuntu-only host gate (`platform_linux` / `supported_ubuntu_2404`) is generalized to the
multi-OS `host_substrate_supported` host-provider gate per
[host_platform_doctrine.md](./host_platform_doctrine.md). The Ubuntu node remains available for
direct compatibility checks, but cluster prerequisite expansion starts from the host-substrate gate.

## 3. Registry

`src/Prodbox/Prerequisite.hs` is the authoritative prerequisite registry.

Important registry properties:

- each prerequisite is an `EffectNode` with a stable ID (`effectNodeId`)
- dependencies are explicit (`effectNodePrerequisites`)
- root sets are selected by command planning code such as `src/Prodbox/TestPlan.hs`
- the registry is shared by the public test harness and other prerequisite-aware command flows

IDs are presently raw `String`s. The intended target is a typed `PrerequisiteId` ADT, so root
selection and dependency edges are compiler-checked rather than string-matched, with
per-validation prerequisite sets kept minimal and precise (Sprint 5.6).

Examples of supported prerequisite IDs in the current repository include:

- `host_substrate_supported`
- `supported_ubuntu_2404`
- `settings_object`
- `tool_aws`
- `tool_curl`
- `tool_dig`
- `tool_docker`
- `tool_helm`
- `tool_kubectl`
- `tool_pulumi`
- `tool_ssh`
- `tool_sudo`
- `tool_systemctl`

## 4. Patterns

Recommended patterns:

- keep prerequisite checks narrow and explicit
- use stable IDs and explicit dependencies
- separate prerequisite validation from the real validation payload
- model cluster-backed runbooks separately from the prerequisite DAG when the operator-facing flow
  needs a visible intermediate step
- split prerequisite ownership into initial fail-fast host/tool/config checks and deferred
  cluster-backed backend proofs when the deferred proof depends on runtime created by that visible
  runbook, such as the RKE2-backed MinIO Pulumi backend
- keep any repository-local self-heal bounded, logged, and followed by the same final readiness
  proof, such as recreating a deleted MinIO export host path before retrying Pulumi backend login
- use explicit runtime-stability gates after prerequisite success when a long-running command needs
  a proven steady state, such as registry endpoint stability before image reconcile — and per the
  [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md), that steady-state gate must
  exercise the **exact dependency call path** the next step uses (a front-door proxy such as
  `GET /v2/` does not prove the registry → MinIO S3 write edge)

## 4A. Prerequisite/Preparation Boundary

Prerequisites answer whether the command may safely begin a plan step; preparation reconcilers make
the desired state true. The boundary is strict:

1. An initial prerequisite may inspect tools, decoded configuration, credentials, an exact typed
   capability, or externally authoritative state. It does not create, import, update, or delete a
   resource.
2. The pure command/test planner derives required preparation actions from selected capabilities.
3. The interpreter narrates and runs each mutating action through its canonical reconciler.
4. A read-only postcondition or readiness observer rechecks the exact dependency edge before the
   dependent action proceeds.

Clean first bring-up follows the same rule. Read-only prerequisites validate Tier-0 coordinates,
host/cluster reachability, Vault/Broker state, and the exact frozen Authority/Backup-Adapter/Target-
Agent identities. `BackupNotEstablished` is not repaired inside a check: the plan exposes
`EstablishAuthorityBackup`, narrates the attested Credential-Provisioner prompt action, and requires
target-generation plus S3 backup read-back before config seeding. A later positive backup loss
similarly produces visible `BackupRepairFrozen`; unobservable S3/IAM state remains a refusal. No
prerequisite creates a bucket/key or hides an admin prompt.

`prodbox config setup` is limited to Tier-0 authoring/validation and optional read-only AWS
discovery. Credential genesis/repair/rotation, explicit SES destroy, legacy backend
migration/retained-store compatibility, and quota request/status read-back are separate visible actions executed by
the permit-indexed Credential Provisioner or Admin Action Runner. The normal Provider Worker is not
a fallback interpreter for either. Before first Vault `/sys/init`, the Broker's read-only gate must
observe the password-AEAD `PreparedInitEnvelope` read back for the exact empty storage generation;
writing it and invoking init are visible bootstrap actions, not prerequisite effects.

TLS restore/issuance uses the same separation. Read-only observation resolves the TLS Retention
Adapter, the selected Agent's exact TLS Secret lane, and the home Agent's distinct
`TlsEnvelopeKeyExchange` lane. Positive absence or policy-valid expiry may select the subsequent
issuance action; corrupt, identity-mismatched, rollback, or unobservable TLS/S3/Transit state keeps
the gate closed and never masquerades as absence. TLS prefix deletion is likewise a registered
decommission action, not a check, and cannot delete the shared bucket.

Cross-substrate preparation supplies two caller-facing non-interchangeable capability references: the retained
home/control-plane Lifecycle Authority and the selected substrate's Target Secret Agent. Each is an
operation-indexed `CapabilityRef`; observation, admission, and execution use that same opaque value,
including service identity, authority scope, and coordinate. A caller may not probe one endpoint and
execute against another, nor resolve either from ambient kubeconfig, current context, environment
variables, or an active-gateway singleton. The Gateway Runtime is not a prerequisite proxy for
bootstrap, lifecycle CAS, or target-secret operations. Internally, normal Lifecycle Authority
admission additionally requires the exact fresh Backup Adapter commit/read-back capability; its
absence cannot be masked by either caller-facing reference.

For an invite-capable suite, a missing `aws-ses` stack is therefore not a failed prerequisite with
an operator-reconcile remedy. The visible preparation step submits a durable operation ID through
the exact Lifecycle Authority `CapabilityRef`; a lost response is recovered by observing that ID,
not by submitting a new mutation. Provider propagation is asynchronous, holds no broad lease, and
is observed under one absolute deadline that includes queue wait and every transport/read-back
step. Only the authority's durable outbox may deliver a committed generation through the selected
Target Secret Agent. Deferred prerequisite nodes use the same semantic classifier to observe the
prepared result and never prescribe or perform a second reconcile. The lifecycle semantics are
owned by [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md), and physical
capability ownership by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Suite ordering is owned by
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation);
the capability-derived preparation projection is owned by
[Integration Fixture Doctrine §2A](./integration_fixture_doctrine.md#2a-retained-desired-presence-preparation).

Implementation and deployment-qualification status for this boundary live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

`prodbox host check-ses-readiness` is the supported read-only diagnostic for this boundary. It runs
the sending, receiving, and capture prerequisite scopes once and renders their structured current
state. It does not poll, reconcile, import, or mutate AWS resources. Its remedies name the failed
semantic observation and direct the caller to retry the same harness-owned validation rather than
prescribing manual reconciliation or ad-hoc AWS mutation.

Externally authoritative observations do not collapse uncertainty into absence. A check or
postcondition uses the flat `Absent | Present | Unobservable` classification from
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#desired-present-reconciliation-for-long-lived-resources),
with `Unobservable` gate-closed. Semantic readiness similarly distinguishes `Ready`, `Pending`,
terminal `Failed`, and `Unobservable`. Only the explicit retained-preparation await retries
`Pending`; `Failed` and `Unobservable` fail immediately, and deadline exhaustion preserves the
operation ID and last Pending reason while leaving long-lived state recoverable. A prerequisite
must not loop while secretly reconciling the resource it probes.

## 5. Anti-Patterns

Avoid:

- silently installing tools from prerequisite checks
- checking the same root condition in multiple disconnected code paths
- hiding required manual fixes inside downstream command failures
- inventing one-off prerequisite logic outside the registry
- invoking `aws-ses reconcile`, `pulumi up`, resource import, or any other desired-state mutation
  from a prerequisite check
- reporting a missing registered long-lived resource as an operator repair when the selected suite
  owns a desired-present preparation action

## 6. Error Messages

Prerequisite failures should be actionable and specific.

- surface the failing node ID, the node description, and the node-owned remedy hint
- name the missing or invalid requirement
- explain what the operator must fix
- avoid repeating the same remediation text at every dependent node

## 7. Intent Ownership

This SSoT co-owns prerequisite doctrine intention.

- Owned statement: prerequisite checks fail fast, are registry-backed, and emit actionable
  root-cause messages.
- Linked dependents: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/PrerequisiteId.hs`,
  `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestPlan.hs`,
  `src/Prodbox/TestRunner.hs`, `src/Prodbox/Host/Substrate.hs`, and
  `src/Prodbox/Host/Ensure.hs`.

## Prerequisites as Typed Effects

Preconditions — required binaries on `$PATH`, valid credentials, reachable
endpoints, supported OS, required files on disk — are encoded as a typed
directed acyclic graph, not as scattered `unless (toolExists "kubectl") fail`
checks in command runners.

The prescribed shape (illustrative — the generic names below map to the real
`src/Prodbox/Effect.hs` / `src/Prodbox/EffectDAG.hs` types named after each block):

```haskell
-- Illustrative generic form. Real type: Prodbox.Effect.Validation, a closed
-- sum of the project's concrete checks.
data Validation
  = RequireTool FilePath [Text]       -- binary + accepted version args
  | RequireFileExists FilePath
  | RequireEnvVar Text
  | RequireReachable URI
  | RequireOS SupportedOS
  -- ...extend per project
  deriving stock (Eq, Show)

-- Illustrative generic form. Real type: Prodbox.EffectDAG.EffectNode.
data PrerequisiteNode = PrerequisiteNode
  { nodeId            :: Text
  , nodeDescription   :: Text
  , nodePrerequisites :: [Text]       -- IDs of dependency nodes
  , nodeCheck         :: Validation
  }

prerequisiteRegistry :: Map Text PrerequisiteNode
```

In the current codebase these are concretely `Prodbox.EffectDAG.EffectNode` with fields
`effectNodeId` / `effectNodeDescription` / `effectNodeRemedyHint` / `effectNodePrerequisites` /
`effectNodeEffect`, where the node action is a `Prodbox.Effect.Effect` (the `Validate Validation`
constructor carries a check; other constructors emit lines or run subprocesses). The registry is
`prerequisiteRegistry :: Map String EffectNode`, and node IDs are presently raw `String`s — the
typed `PrerequisiteId` ADT is the target (Sprint 5.6).

The registry is the single source of truth. Adding a prerequisite means
adding one entry to the map. Declaring a command's needs means listing the
root IDs that command depends on.

Expansion is pure (real signatures, `src/Prodbox/EffectDAG.hs`):

```haskell
transitiveClosureIds
  :: [String]                          -- root IDs
  -> Map String EffectNode
  -> Either String [String]

fromRootIds
  :: [String]                          -- root IDs
  -> Map String EffectNode
  -> Either String EffectDAG
```

Missing IDs are a registry error caught at expansion time, not at runtime,
so typos and stale references never reach an end user. Acyclicity is enforced
on this same construction path: a back-edge (a node that transitively depends
on itself) yields `Left` from `transitiveClosureIds`/`fromRootIds`, so a cyclic
registry can never produce an `EffectDAG` (Sprint 1.31). See
[Prerequisite DAG System § 3](./prerequisite_dag_system.md#3-reduction-and-determinism).

Interpretation lives at the IO boundary (real signature,
`src/Prodbox/EffectInterpreter.hs`):

```haskell
runEffectDAG
  :: InterpreterContext
  -> EffectDAG
  -> IO (Result ())
```

**Required error-message contract.** A prerequisite failure must include:

1. The failing `nodeId`.
2. The `nodeDescription`.
3. A remedy hint (install command, doc URL, configuration snippet).

This mirrors the **Required error-message contract** in
[code_quality.md → Generated Artifacts](./code_quality.md#generated-artifacts).
Failures that name a problem but offer no remedy are forbidden in both
lines of discipline.

Where in the lifecycle:

- One-shot commands: `transitiveClosure` runs immediately before `apply`
  (see [Plan / Apply](./pure_fp_standards.md#plan--apply)). A single unmet
  prerequisite aborts with non-zero exit before any plan step executes.
- Daemons: the prereq DAG runs between `load` and `acquire` (see
  [distributed_gateway_architecture.md → Daemon Lifecycle](./distributed_gateway_architecture.md#daemon-lifecycle)).
  The daemon refuses to enter `acquire` if any node fails.

**Forbidden patterns:**

- Inline `unless` / `when` checks of prerequisite-shaped conditions in
  command runners. Add a registry node instead.
- Multiple registries (per-command, per-module). The single
  `prerequisiteRegistry :: Map String EffectNode` is the source of truth.
- Silent fallback when a prerequisite is unmet. The command refuses to
  proceed; it does not paper over the gap.
- Checking prerequisites *after* a mutating step. The DAG is a gate, not a
  postflight check. A separately declared read-only semantic postcondition after a visible
  preparation action is a lifecycle/readiness gate, not hidden prerequisite mutation (§4A).

This section composes with [Plan / Apply](./pure_fp_standards.md#plan--apply)
above (prereqs gate `apply`) and
[Reconcilers](./cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command)
(prereqs gate every reconcile run).

## Cross-References

- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
