# Unit Testing Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md,
DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md,
DEVELOPMENT_PLAN/phase-0-planning-documentation.md,
DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md,
DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md,
DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md,
DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md,
DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md,
DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md,
DEVELOPMENT_PLAN/phase-8-email-invite-auth.md,
documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md,
documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md,
documents/engineering/code_quality.md, documents/engineering/dependency_management.md,
documents/engineering/distributed_gateway_architecture.md,
documents/engineering/effectful_dag_architecture.md,
documents/engineering/effect_interpreter.md,
documents/engineering/envoy_gateway_edge_doctrine.md,
documents/engineering/helm_chart_platform_doctrine.md,
documents/engineering/integration_fixture_doctrine.md,
documents/engineering/lifecycle_reconciliation_doctrine.md,
documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md,
documents/engineering/pure_fp_standards.md, documents/engineering/refactoring_patterns.md,
documents/engineering/streaming_doctrine.md, documents/engineering/test_topology_doctrine.md
**Generated sections**: none

> **Purpose**: Define the interpreter-only mocking doctrine and public test-runner contract for
> `prodbox`.

## 0. Canonical Skip Policy Statement

Skip/xfail is prohibited by default; missing prerequisites must fail fast with actionable errors.

The public `prodbox test` surface uses a two-stage model:

- Phase `1/2`: prerequisite validation
- optional Phase `1.5/2` or `1.6/2`: runbook and supported-runtime preparation
- Phase `2/2`: Haskell test suites and named validation payloads

This document defines testing doctrine only. Sequencing, completion status, and cleanup ownership
are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md). The test-run topology,
the executable-sibling `prodbox.test.dhall` SSoT, `.test-data/` isolation, and the two fail-fast
preconditions are owned by [test_topology_doctrine.md](./test_topology_doctrine.md).
The `prodbox test init` / `prodbox test run <suite>|all` topology surface now uses that SSoT:
each variant gets a generated binary-sibling `prodbox.dhall`, a `.test-data/<case>/`
`storage.manual_pv_host_root`, and finally-guaranteed cleanup of only the per-run half.

## 1. The Interpreter-Only Mocking Doctrine

### Core Rule

**Pure code never touches mocks. All mocking happens at the subprocess or interpreter boundary.**

In the current repository:

- pure helpers, DAG logic, renderers, and validation helpers should be testable without mocks
- subprocess fakes belong in the built-frontend integration suite under `test/integration/`
- prerequisite and runtime orchestration belong in native Haskell modules under `src/Prodbox/`

## 2. Unit vs Integration Tests

| Aspect | Unit Test | Integration Test |
|--------|-----------|------------------|
| External systems | Faked or avoided | Real or built-frontend |
| Speed | Fast | Slower |
| Dependencies | Minimal | Tooling, cluster, AWS, or DNS as required |
| Where mocks live | Boundary only | N/A or fake-tool harness |

### Test Categories

| Category | What Gets Tested | Location |
|----------|------------------|----------|
| Pure helper tests | Parsing, rendering, ADTs, DAG logic, validation helpers | `test/unit/Main.hs` |
| Parser tests | `argv -> Command` coverage through `execParserPure`, including happy-path and unhappy-path leaf-command cases | `test/unit/Parser.hs` via `prodbox-unit` |
| Built-frontend integration tests | CLI routing, fake-tool subprocess behavior, and direct-Dhall config masking or validation behavior | `test/integration/Main.hs`, `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs` via `cabal test prodbox-integration` |
| Canonical test suite (named validations) | `charts-vscode`, `charts-api`, `charts-websocket`, `admin-routes`, `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`, `pulumi`, `ha-rke2-aws`, `gateway-daemon`, `gateway-pods`, `gateway-partition`, `charts-platform`, `resource-guardrails`, `pulsar-broker`, `keycloak-invite`, `charts-storage`, `eks-volume-rebind`, `sealed-vault`, and `lifecycle`. The suite content is substrate-agnostic (no substrate-conditional branches in validation logic), but the suite as a whole is composed of per-substrate runs against both supported substrates; per [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback) and [`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md), each per-substrate run is substrate-locked and fails fast on missing per-substrate config — there is no silent fallback from one substrate to the other, and a complete canonical-suite proof requires both the home local and AWS substrate runs to land independently. | `src/Prodbox/TestValidation.hs` via `prodbox test integration ...` |
| Daemon lifecycle tests | Daemon startup and reload coverage per [config_doctrine.md](../../documents/engineering/config_doctrine.md): the `--config <path>` Dhall-load contract, file-watch reload trigger (write a new Dhall to the watched path and assert the daemon picks up the change), boot-vs-live classification (boot-field change drains and exits with `ExitSuccess`; live-field change atomic-swaps `envLiveConfig`), real process startup through the repository subprocess boundary, `/readyz` waits through the shared retry helper, SIGTERM drain, second-SIGTERM forced-exit assertions, and daemon health endpoint goldens | `test/daemon-lifecycle/Main.hs` via `cabal test prodbox-daemon-lifecycle` |
| Pulumi harness tests | Ephemeral stack-state ownership, typed output handoff, and forced-failure cleanup around the AWS substrate's Pulumi provisioning helpers | `test/pulumi/Main.hs` via `cabal test prodbox-pulumi` |
| Golden tests | `/healthz`, `/readyz`, and `/metrics` response shapes; CLI `--help`, `commands --tree`, `commands --json` output; rendered Plans; generated docs | `test/golden/` via `prodbox-unit` |

Daemon lifecycle and golden treatment of health-endpoint responses are owned by
Sprints `2.10`, `2.14`, and `2.16` per
[Daemon Lifecycle Tests](../../documents/engineering/README.md)
and `Test Categories → Daemon Lifecycle Tests` §2252–2254. Filesystem readiness markers,
`sd_notify(READY=1)`, and `threadDelay`-based readiness probes are explicitly forbidden;
`/readyz` is the only supported readiness signal, and lifecycle waits use the shared retry helper
rather than direct sleeps. The lifecycle stanza covers the real process and signal contract,
captures `/healthz`, `/readyz`, and `/metrics` response shapes under
`test/golden/daemon-health/`, and the style suite rejects direct `threadDelay` plus raw
`terminateProcess` in the stanza.

### Integration Execution Policy (Fail-Fast)

- Integration selections must fail fast when prerequisites are missing.
- Platform and environment gating belongs in prerequisite validation, not in skips.
- Use `prodbox test unit` when integration prerequisites are unavailable.

### Two-Phase Test Command Doctrine

Integration-selected `prodbox test` commands execute in two phases:

1. **Phase 1 - prerequisite gate**: validate integration prerequisites before deeper work starts.
   Suites may split this gate into an initial fail-fast prerequisite pass plus a deferred
   cluster-backed backend proof when the deferred proof depends on a visible runbook-created local
   runtime such as the RKE2-backed MinIO Pulumi backend.
2. **Phase 1.5 - integration runbook gate**: cluster-backed suites may enforce
   `prodbox cluster reconcile`.
3. **Phase 1.6 - supported runtime bootstrap**: aggregate or destructive flows may repair the
   supported runtime before validation. When Phase 1.5 already ran the runbook reconcile,
   Phase 1.6 reuses that reconciled local runtime and performs the chart reset/deploy work
   without repeating the full `prodbox cluster reconcile` image-publication path.
4. **Phase 2 - test execution**: run Haskell suites and named validation payloads only after the
   earlier phases succeed.

When Phase `1.6/2` restores a cluster-backed supported runtime for external proof, it may wait for
`prodbox edge status` to report `CLASSIFICATION=ready-for-external-proof` before the payload
starts. That readiness is derived from Gateway API, Envoy Gateway, Route 53, and certificate
state.

When a Phase `1/2` prerequisite owns a deterministic local backend proof, it may perform a
visible, bounded repair of repository-managed state before re-running the same readiness check. The
canonical current example is the MinIO-backed Pulumi prerequisite recreating a deleted retained
export host path and restarting `statefulset/minio` before retrying backend login.

The retained-volume rebinding validation keeps its live cluster mutation thin around a pure
oracle: `VolumeRebindSnapshot` parses Kubernetes PV JSON, and `volumeRebindReport` checks same
PV/PVC, `Bound` before and after, same EBS `volumeHandle` when present, and sentinel preservation.
Unit coverage must pin those invariants separately from the destructive live
`eks-volume-rebind` run.

The resource-guardrails validation follows the same boundary split: the live command gathers
Kubernetes pod, `ResourceQuota`, and `LimitRange` JSON through `kubectl`, while the pure
`resourceGuardrailReport` oracle checks non-`BestEffort` QoS, explicit cpu/memory/ephemeral-storage
requests and limits for every checked container/init container, and root-chart namespace guardrail
objects matching the validated `capacity.resource_plan`. Unit tests pin the oracle; built-frontend
integration fakes only the subprocess boundary.

If Phase 1 fails, Phase 2 is not started. This is an all-or-nothing gate, not a skip.

### Phase Banner Rendering Contract

`prodbox test` phase banners are operator-facing progress records. Their visible order is part of
the command contract.

1. Visible banner order is exact: `Phase 1/2`, optional `Phase 1.5/2`, optional `Phase 1.6/2`,
   then `Phase 2/2`.
2. Each phase banner is emitted as its own stdout line.
3. Deferred Phase `1/2` checks may run after Phase `1.5/2` or `1.6/2`, but `Phase 2/2` is
   emitted only after every Phase `1` gate succeeds.
4. Post-test repair banners are also part of the visible contract when aggregate runtime repair is
   required.

### Command-Scope Prerequisite Aggregation

`prodbox test` applies prerequisite gates at command scope:

1. The selected suite determines the root prerequisite set.
2. Unit-only scope bypasses integration gates.
3. Cluster-backed suites may keep initial host, tool, config, and AWS checks in the front half of
   Phase `1/2`, then defer cluster-backed backend proofs such as `pulumi_logged_in` until after
   the visible runbook has created or repaired the local runtime they depend on.
4. `charts-vscode`, `charts-api`, and `charts-websocket` are supported-runtime cluster-backed
   suites and therefore enforce the cluster runbook plus supported-runtime bootstrap before their
   external proof, and that bootstrap waits for `prodbox edge status` readiness rather than
   using a one-shot assertion. Public-host suites such as `public-dns` may avoid the cluster
   runbook only when their test plan does not require it, but still prove the external port `80`
   HTTP-to-HTTPS redirect after DNS records resolve to the configured public address.
5. The sealed-Vault suite (`prodbox test integration sealed-vault`, Sprint `5.8`) is a
   cluster-backed named validation. The code-owned surface is present as `ValidationSealedVault`
   with the pure `sealedVaultAuditReport` forbidden-pattern oracle; full live closure remains gated
   on deployed Vault state and the Sprint `7.14` Pulumi checkpoint interposition.
6. Aggregate suites use the canonical validation ordering defined in `src/Prodbox/TestPlan.hs`.

Sprint `5.6` makes this prerequisite surface **typed and minimal-and-precise**:

- Prerequisite identifiers are a typed `PrerequisiteId` ADT
  (`src/Prodbox/PrerequisiteId.hs`) that keys the registry
  (`src/Prodbox/Prerequisite.hs`) and threads through `EffectDAG` /
  `EffectInterpreter` and the `TestPlan` declarations — exhaustively matched,
  not string-compared.
- Each validation declares **exactly** the typed prerequisites it consumes
  (`validationInitialPrerequisites` / `validationDeferredPrerequisites` in
  `src/Prodbox/TestPlan.hs`) — no over-broad inherited bundle.
- `infra_ready` is split into `infra_ready` (cluster + AWS credentials) and a
  new declared `public_edge_ready` node that depends only on cluster +
  chart-platform readiness (`k8s_ready`), **not** on AWS credentials.
  `charts-vscode`, `charts-api`, `charts-websocket`, and `admin-routes` gate on
  `public_edge_ready` + `tool_curl` so they require an AWS-credential-free
  readiness rather than re-acquiring the full `infra_ready` capability set.
- The managed AWS IAM-harness tier is **derived from declared capabilities**
  (`derivedManagedAwsHarnessPolicyTier`), not from a `substrate=aws` blanket
  override. A credential-free validation (e.g. `gateway-partition`) never
  acquires the harness merely because the active substrate is AWS.

Supported WebSocket validations must prove shared-host Keycloak issuer and redirect alignment when
the workload owns direct OIDC bootstrap on the shared host under `/ws/oidc`, connection-time auth,
real `/ws` upgrade, reconnect-safe or
restart-safe shared state, cross-replica behavior, revocation or forced-reconnect handling,
readiness-based drain, token-expiry expectations when the workload requires them, and any
required shared-state backend assumptions.

Supported public API routes that rely on Envoy JWT validation must prove unauthenticated
rejection, wrong-claim rejection, the shared-host Keycloak issuer plus JWKS contract, and the
intended issuer, audience, and claim-enforcement contract for the selected token transport.

### Session Fixtures vs Test DAG (SSoT)

Session-style hidden setup is not the supported orchestration model for command-level prerequisites.

- prerequisite behavior belongs in the native DAG and runner
- resource setup and cleanup ownership for real validations belongs in
  `src/Prodbox/TestValidation.hs` and the relevant infrastructure modules
- the suite-level managed IAM credential harness for `prodbox test integration aws-iam`,
  targeted `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` belongs in
  `src/Prodbox/TestRunner.hs` plus `src/Prodbox/Aws.hs`
- cleanup doctrine is defined by [Integration Fixture Doctrine](./integration_fixture_doctrine.md)

### Timeout Budget Separation

Prerequisite and runtime-preparation time should not be confused with payload execution time.

- earlier phases own readiness checks and runbook work
- Phase 2 owns Haskell suites and named validation payloads

## 3. Forbidden Patterns

Avoid:

- silent `skip` or `xfail` behavior for missing prerequisites
- hidden prerequisite setup outside the supported test runner
- mocking deep inside pure planning code
- raw ad-hoc file selectors as the public test interface
- undocumented destructive setup or teardown in named validations

## 4. Allowed Patterns

Allowed patterns include:

- pure helper tests in `test/unit/Main.hs`
- fake-tool built-frontend proof in `test/integration/CliSuite.hs`
- repository-local config proof in `test/integration/EnvSuite.hs`
- real named validation flows behind `prodbox test integration ...`
- explicit prerequisite and cleanup ownership in native Haskell modules

## 5. Test Data vs Mocks

Prefer concrete test data over mocks when the code under test is pure.

- use real ADT values for parsing and rendering tests
- use fake tool binaries or controlled subprocess environments for built-frontend proof
- reserve mocking-style indirection for true effect boundaries

## 6. pytest-subprocess Usage

The repository no longer uses a Python pytest harness on the supported path.

The equivalent doctrine in the current Haskell repository is:

- keep subprocess faking at the boundary
- test built-frontend command behavior through dedicated Haskell integration suites
- keep pure logic free of subprocess concerns

## 7. Coverage Targets

Coverage remains a repository expectation, but the supported local closure gate is the Haskell
build-plus-suite contract:

- `prodbox dev check`
- `prodbox test unit`
- `prodbox test integration cli`
- `prodbox test integration env`

Named real-world validation commands provide operational proof rather than synthetic line coverage.

## 7A. Destroy-Path Validation

Every destructive lifecycle command carries explicit unit and integration test
obligations.

- **Unit tests of preflight predicates.** The `Precondition` library at
  `src/Prodbox/Lifecycle/Preconditions.hs` (planned in Sprint `4.11`) must be
  pure-testable: each predicate's diff and rendering logic is exercised in
  `test/unit/` with synthetic stack snapshots, no AWS, no kubectl. See
  [lifecycle_reconciliation_doctrine.md → §4 Predicate Library Inventory](./lifecycle_reconciliation_doctrine.md).
- **Postflight tag-sweep assertion.** Every destructive lifecycle integration
  test (`prodbox cluster delete`, `prodbox aws teardown`, `prodbox aws stack
  <stack> destroy`, `prodbox nuke`) must assert that the postflight tag sweep
  returns empty after success. A non-empty sweep is a hard test failure with
  the leak list in the failure record.
- **`--dry-run` golden snapshots.** `prodbox cluster delete --dry-run`,
  `prodbox cluster delete --cascade --dry-run`, and `prodbox nuke --dry-run`
  outputs are captured as golden tests so changes to the plan rendering
  require an explicit golden update. Sprint `5.6` lands these three goldens
  under `test/golden/destructive/` (rendered from the pure plan renderers
  `renderNativeDeletePlan` / `Nuke.renderNukePlan` in `test/unit/Main.hs`),
  proving each destructive path's planned step list **without executing it**
  (the audit V80 found these missing; they validate Sprint `4.26`'s dry-run
  fix). The goldens are **registry-generated**: the per-run, `aws-ses`, and
  long-lived destroy lines are derived from the managed-resource registry /
  `StackDescriptor` SSoT (Sprints `4.26`/`4.27`), and a drift guard fails if
  a registered resource is added without regenerating the golden.
- **`prodbox nuke` opt-in suite.** Because `prodbox nuke` destroys long-lived
  shared infrastructure (`aws-ses`, the long-lived `pulumi_state_backend`
  bucket), its end-to-end integration test is **not** part of the default
  canonical suite. It is gated behind an explicit nuke-validation suite
  invocation; CI runs it only on explicit operator request.

## 8. Intent Ownership

This SSoT co-owns the public testing doctrine.

- Owned statement: `prodbox test` is a prerequisite-aware, phase-bannered Haskell test runner with
  explicit named validation ownership.
- Linked dependents: `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`,
  `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`, `test/integration/Main.hs`,
  `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs`.

## Testing Doctrine

The canonical developer-facing test command is `prodbox test all`. The
canonical package-level test command is `cabal test`. `prodbox test all`
delegates to `cabal test` via subprocess execution. There must not be
multiple independent test systems; the CLI-level test command is a
convenience and orchestration layer over Cabal rather than a replacement.

The complete test suite includes pure logic tests, parser tests, property
tests, golden tests, local integration tests, Pulumi-orchestrated
infrastructure tests, and lint and style checks (per-artifact lints plus
the Haskell-style suite). There is no separate developer workflow for
cloud-backed tests.

Lint and style checks are part of the canonical test suite rather than a
parallel CI-only workflow. The `<project>-haskell-style` `test-suite`
stanza makes `cabal test` self-sufficient for style enforcement, so
contributors and CI run the same command and fail in the same way.

### Standard Testing Stack

```text
Cabal
+ exitcode-stdio-1.0
+ tasty
+ tasty-hunit
+ tasty-quickcheck
+ tasty-golden
+ typed-process
+ temporary
+ Pulumi
+ fourmolu
+ hlint
+ cabal format
```

Responsibilities:

| Component | Responsibility |
|---|---|
| Cabal | Build and execute test suites |
| exitcode-stdio-1.0 | Standard test process interface |
| tasty | Unified test runner and organization |
| tasty-hunit | Assertions |
| tasty-quickcheck | Property testing |
| tasty-golden | Golden/snapshot testing |
| typed-process | CLI subprocess execution |
| temporary | Temporary directories/files |
| Pulumi | Infrastructure orchestration and teardown |
| fourmolu | Haskell source formatter |
| hlint | Haskell linter |
| cabal format | Cabal manifest formatter |

### Test Categories

#### Pure Logic Tests

Pure business logic should be tested directly, avoiding IO whenever
possible. Targets: configuration merging, command planning, rendering
logic, validation rules, serialization behavior.

#### Parser Tests

Parser tests verify `argv -> Command ADT`. The parser layer is real
application logic and should be tested explicitly. Use `execParserPure`
or equivalent parser-level APIs rather than spawning subprocesses.

#### Property Tests

Use `tasty-quickcheck` for property testing. Appropriate for parsers,
serialization, normalization, transformations, formatting invariants.
Example properties: `decode . encode == id`, render is deterministic,
parser roundtrips.

#### Golden Tests

Golden tests compare current output against committed reference output.
Especially valuable for CLI tooling because CLIs generate large amounts of
structured text. Typical targets: `tool --help`, `tool users --help`,
`tool commands --tree`, `tool commands --json`, generated Markdown docs,
generated manpages.

Golden outputs must be deterministic. Avoid embedding timestamps, random
IDs, nondeterministic ordering, or terminal-width-dependent wrapping.

#### Integration Tests

Integration tests execute the real CLI binary as a subprocess. Use
`typed-process` for subprocess management. Typical targets: stdin/stdout
behavior, filesystem interactions, config loading, subprocess execution,
exit codes, JSON output behavior.

#### Pulumi-Orchestrated Infrastructure Tests

Infrastructure tests provision real infrastructure using Pulumi, execute
tests against deployed systems, then destroy all resources. Pulumi owns
infrastructure lifecycle management. These tests must use isolated
ephemeral stacks, generate unique stack names per run, aggressively tag
all infrastructure, always perform teardown, and use `bracket`, `finally`,
or equivalent structured cleanup.

#### Daemon Lifecycle Tests

When the binary hosts a long-running daemon, lifecycle tests live in their
own `test-suite <project>-daemon-lifecycle` stanza. Each test spawns the
daemon as a subprocess via `typed-process`, polls `/readyz` until ready,
exercises the protocol surface, sends SIGTERM, asserts graceful shutdown
within the configured drain deadline, and asserts exit code 0.

Health-endpoint response shapes (`/healthz`, `/readyz`, `/metrics`) belong
in the golden-test category. Shutdown signal tests assert that a single
SIGTERM begins drain and a second SIGTERM (or timeout) forces exit.

Forbidden test patterns: `terminateProcess` without first attempting
graceful shutdown, `threadDelay`-based readiness probes, polling for
filesystem readiness markers when `/readyz` exists.

See
[distributed_gateway_architecture.md → Daemon Lifecycle](./distributed_gateway_architecture.md#daemon-lifecycle)
for the lifecycle these tests validate.

### Test Organization

Each test tier is a separate Cabal `test-suite` stanza with
`type: exitcode-stdio-1.0`:

```text
test-suite <project>-unit
test-suite <project>-integration
test-suite <project>-haskell-style
test-suite <project>-daemon-lifecycle  (when the binary hosts a daemon)
test-suite <project>-pulumi            (when infrastructure tests apply)
```

`cabal test` runs every stanza. A single `tasty` tree spanning all tiers
is forbidden: separate stanzas give Cabal-native parallelism, let CI and
developers target one tier (`cabal test <project>-unit`), and isolate
dependency creep so heavy integration deps do not leak into the unit
suite.

Each stanza's `main-is` is a small `Main.hs` that calls into a library
module where the actual tests live; tasty (or HUnit / QuickCheck used
directly) builds the in-stanza test tree.

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Code Quality Doctrine](./code_quality.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Streaming Doctrine](./streaming_doctrine.md)
