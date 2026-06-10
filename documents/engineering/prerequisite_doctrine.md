# Prerequisite Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/code_quality.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Define the fail-fast prerequisite doctrine for supported `prodbox` command flows.

## 0. Canonical Doctrine Statements

- Prerequisite nodes validate existence or readiness and fail fast with actionable fix hints.
- Manual environment repair belongs in prerequisite failures unless the prerequisite owns a
  bounded, visible self-heal for repository-managed local state and re-verifies readiness before
  reporting success.
- The canonical prerequisite registry lives in `src/Prodbox/Prerequisite.hs`.
- Runtime-stability waits that follow prerequisite success belong in explicit runbook or lifecycle
  steps, not in hidden prerequisite side effects.
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

- supported host properties such as `Ubuntu 24.04 LTS`
- required host tools such as `aws`, `curl`, `dig`, `docker`, `helm`, `kubectl`, `pulumi`, and
  `ssh`
- repository configuration readiness through in-process decoding of `prodbox-config.dhall` by
  the native `dhall` Haskell library
- cluster-backed runtime readiness
- AWS- and Route-53-backed readiness

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
  a proven steady state, such as Harbor endpoint stability before image reconcile

## 5. Anti-Patterns

Avoid:

- silently installing tools from prerequisite checks
- checking the same root condition in multiple disconnected code paths
- hiding required manual fixes inside downstream command failures
- inventing one-off prerequisite logic outside the registry

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
- Linked dependents: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/EffectDAG.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`.

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
  postflight check.

This section composes with [Plan / Apply](./pure_fp_standards.md#plan--apply)
above (prereqs gate `apply`) and
[Reconcilers](./cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command)
(prereqs gate every reconcile run).

## Cross-References

- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
