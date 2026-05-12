# Prerequisite Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/code_quality.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Define the fail-fast prerequisite doctrine for supported `prodbox` command flows.

## 0. Canonical Doctrine Statements

- Prerequisite nodes validate existence or readiness and fail fast with actionable fix hints.
- Manual environment repair belongs in prerequisite failures unless the prerequisite owns a
  bounded, visible self-heal for repository-managed local state and re-verifies readiness before
  reporting success.
- The canonical prerequisite registry lives in `src/Prodbox/Prerequisite.hs`.
- Runtime-stability waits that follow prerequisite success belong in explicit runbook or lifecycle
  steps, not in hidden prerequisite side effects.

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
- repository configuration readiness through the Haskell-owned `dhall-to-json` decode bridge
- cluster-backed runtime readiness
- AWS- and Route-53-backed readiness

## 3. Registry

`src/Prodbox/Prerequisite.hs` is the authoritative prerequisite registry.

Important registry properties:

- each prerequisite has a stable ID
- dependencies are explicit
- root sets are selected by command planning code such as `src/Prodbox/TestPlan.hs`
- the registry is shared by the public test harness and other prerequisite-aware command flows

Examples of supported prerequisite IDs in the current repository include:

- `supported_ubuntu_2404`
- `settings_object`
- `tool_aws`
- `tool_curl`
- `tool_dhall`
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

## Cross-References

- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
