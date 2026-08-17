# Test Topology Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Single source of truth for the executable-sibling `prodbox.test.dhall`, generated
> per-run config, `.test-data/` isolation, and the `test init` / `test run` surface.

Real-resource cleanup scheduling and execution are owned by
[Lifecycle Reconciliation Doctrine §3.3](./lifecycle_reconciliation_doctrine.md#33-result-indexed-programs-and-the-durable-cleanup-graph).
[Integration Fixture Doctrine §4](./integration_fixture_doctrine.md#4-validation-as-a-cleanup-client)
owns validation-specific preparation, cleanup-obligation registration, and consumption of the
generic report.

## 1. A test run is fully described by its test Dhall

A `prodbox` test run is not a mode of the production config; it is authored by a **separate,
differently-shaped Dhall surface**. `prodbox test init` writes `prodbox.test.dhall` at the
**executable-sibling path** (`.build/prodbox.test.dhall`, beside the binary — the same resolution
rule the production config uses, [config_doctrine.md §3](./config_doctrine.md#3-canonical-paths)),
and that file **is** the run: the HA/failover cluster shape, the suite vocabulary, per-suite
budgets, and the fixtures each suite needs. Nothing about a run is implicit in ambient machine
state — the test Dhall is the audit trail of what will be stood up.

The supported topology never rewrites an operator-authored production config from
`test-secrets.dhall`. `test init` authors the distinct topology file and `test run` generates a
disposable per-variant Tier-0 `prodbox.dhall` with storage under `.test-data/<case>/`. **Target:**
before mutation, both generated artifacts become durable obligations in the lifecycle-owned
always-run cleanup DAG. **Current:** `TestRunner` still uses its pre-cutover process-local cleanup
composition and enters the cleanup wrapper after some preparation mutations. Implementation,
cutover, and qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

`prodbox.test.dhall` is the **authored** half of the per-run-vs-authored split. The **per-run**
half is the binary-sibling `prodbox.dhall` the harness renders for each variant (§3) plus the
run's `.test-data/` (§4) — both disposable. In the target composition, both are registered for
desired absence before creation (§5), and completion requires exact observed absence; a failed or
unobservable delete remains incomplete. The authored test Dhall is retained. Like jitML's `project init` (in the sibling project
`jitML/documents/engineering/durable_state_dsl.md` — mirrored in kind, no code dependency),
`test init` **refuses to overwrite** an existing `prodbox.test.dhall` unless `--force` is passed.

## 2. The test Dhall makes an illegal test topology a typecheck failure

The canonical schema artifact is `dhall/TestTopologySchema.dhall`, mirrored by
`Prodbox.TestTopology` and decoded through `Prodbox.Settings`. It mirrors in kind the sibling
project's `jitML/dhall/project/Schema.dhall` (doctrine
`jitML/documents/engineering/durable_state_dsl.md`; no code dependency). This doc describes facets
and teaching fragments; the schema and Haskell modules are the code-owned surface. The generated
`prodbox.test.dhall` imports the schema, a **closed `FixtureId` union** with an exhaustive `merge`
selector, the declared data, and a terminal `assert`, so typechecking the file is its validation:

```dhall
-- Example: the authored prodbox.test.dhall (teaching fragment; schema lives in code)
let Suite = { name : Text, variants : List RunVariant, budget : Budget }
let self =
      { suites =
          [ { name = "ha-rke2-aws"
            -- the HA/failover matrix: one variant per cluster shape, each stood
            -- up, asserted, and torn down in turn (§3)
            , variants =
                [ RunVariant::{ replicas = 3, failover = Some LeaderKill }
                , RunVariant::{ replicas = 3, failover = Some NetworkPartition }
                ]
            , budget = { max_nodes = 3, wall_clock_seconds = 5400 }
            }
          ]
      -- secrets are named, never inlined (§6)
      , fixtures = [ FixtureId.AwsAdminForTestSimulation ]
      }
in  assert : testContractOK self === True
```

| Illegal test state | Rejected by |
|---|---|
| A suite references an **undeclared** fixture | unnameable — no `FixtureId` constructor / `merge` arm exists, so it fails to typecheck |
| A variant's replica budget exceeds the declared substrate capacity | `variantFitsWithin` (the `assert` reduces to `False`) |
| A suite declares zero variants (nothing to stand up) | `variantsNonEmpty` |
| A suite is named `all` (reserved by the `test run all` verb) | `suiteNameNotReserved` |
| A secret carried inline as cleartext rather than by reference | the schema declares **no secret-shaped field at all** — a fixture is named by a closed `FixtureId` enum, so a literal secret has nowhere to go (§6) |

This is the house "illegal states unrepresentable" technique
([pure_fp_standards.md](./pure_fp_standards.md)) applied to the test surface: prefer the type that
makes the bad topology unconstructible over a runtime check.

## 3. `test run` drives the real deploy path across every variant

`prodbox test run <suite>` runs one named suite; `prodbox test run all` runs every suite (`all` is
reserved). Both run from the **outer project binary against the runtime** — distinct from the
static `dev check` gate. A suite may declare **more than one config variant** (the HA/failover
matrix of §2); the harness stands each variant up, asserts it, and tears it down **before** the
next, reusing the **same deploy path** the operator's `prodbox cluster reconcile` uses. The test
and deploy resource models therefore **cannot drift** — there is no second bring-up path that a
test could exercise a different way.

Per variant the harness **generates** that variant's binary-sibling `prodbox.dhall` through the
same builder production uses (`configFromSetupInput`,
[config_doctrine.md § "The test harness generates its run config"](./config_doctrine.md#the-test-harness-generates-its-run-config))
— never by shelling the CLI — then reconciles, runs the variant's assertions, and destroys before
moving on. The existing `TestScope` / `IntegrationSuite` ADT (`src/Prodbox/CLI/Command.hs`) is the
current-surface seed for the suite vocabulary, and `test init` authors the test Dhall those suites
read.

## 4. Fail-fast preconditions and `.test-data/` isolation

**Two hard fail-fast preconditions** run before any `test init` / `test run` work, and both refuse
rather than proceed. This is a closed gate, mirroring the three-valued residue gate of
[lifecycle_reconciliation_doctrine.md §3](./lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation):

```haskell
-- Example: the two preconditions guarding every test entrypoint
data TestGate
  = TestGateClear                    -- both observed satisfied → proceed
  | TestGateRefuse TestRefusal       -- fail fast; never touch production
  deriving (Eq, Show)

data TestRefusal
  = ProductionConfigPresent FilePath        -- a prodbox.dhall exists beside the binary
  | ProductionClusterRunning ClusterEvidence
  deriving (Eq, Show)
```

1. **Refuse if a `prodbox.dhall` exists beside the binary in `.build/`.** This is the exact
   **inversion** of production's contract: production resolves the executable-sibling
   `prodbox.dhall` (`resolveTier0ConfigPath`, `src/Prodbox/Repo.hs`) and **fails fast when it is
   absent** (`src/Prodbox/Settings.hs`); the topology-mode test surface **fails fast when it is
   present**, so a run can never clobber a real operator config. The per-variant generated
   `prodbox.dhall` (§3) is written only after this gate clears. The current runner places it in a
   process-local cleanup list and attempts direct deletion from `finally`; the target registers its
   desired-absence obligation before writing it and reports deletion only after exact absence is
   observed (§5).
2. **Refuse if a production cluster is running.** A test never mutates production cluster state.

Durable test storage is the **`.test-data/` retained root** — a `storage.manual_pv_host_root`
override ([storage_lifecycle_doctrine.md §7](./storage_lifecycle_doctrine.md#7-the-single-retained-operator-host-root);
`defaultChartDataRootRelative`, `src/Prodbox/Lib/Storage.hs`) pointed at `.test-data/` for the run
instead of the production `.data/`. Each case is isolated under `.test-data/<case>/`. Test commands
are **mechanically forbidden from touching `.data/`**, mirroring in kind the sibling project's
`guardTestDelete` never-delete-`.data` rule (`hostbootstrap/documents/engineering/testing.md`;
no code dependency). The target guard accepts only opaque, run-indexed references; it never accepts a
raw `FilePath` or stack name:

```haskell
-- Example: hypothetical target cleanup references; all referenced constructors are private.
data ThisRunTestDataPath run
data PerRunStackRef run
data GeneratedRunConfigRef run

data TestDeleteTarget run where
  GeneratedRunConfig :: GeneratedRunConfigRef run -> TestDeleteTarget run
  ThisRunTestData :: ThisRunTestDataPath run -> TestDeleteTarget run
  PerRunResidue :: PerRunStackRef run -> TestDeleteTarget run

refineThisRunTestDataPath
  :: TestRunRoot run
  -> ObservedCanonicalPath
  -> Either TestRefusal (ThisRunTestDataPath run)

projectPerRunStack
  :: CleanupScope run
  -> ManagedResource resource 'PerRun 'Stack
  -> PerRunStackRef run
```

`ThisRunTestDataPath` is minted only after the canonical observed path is proved to be inside the
exact `.test-data/<case>/` root bound to `run`; traversal, symlink escape, the production `.data/`
root, and a path from another run have no successful constructor. `PerRunStackRef` is projected only
from a registry entry already indexed `'PerRun 'Stack` and the matching cleanup scope. Because both
constructors and the `run` index are private, neither a raw path nor a `LongLived` stack can be
relabelled as a legal delete target. This is the post-cutover MISU contract; implementation and
activation status remain owned by the Development Plan.

`src/Prodbox/TestValidation.hs` resolves the sealed-Vault host-disk audit root from the topology
run's `PRODBOX_TEST_MANUAL_PV_HOST_ROOT` override when present, falling back to the production
`.data/prodbox/minio/0` root for legacy named-validation commands.

## 5. Artifact teardown and lifecycle-class projection

In the target lifecycle-client composition, the topology runner registers desired absence for its
generated `.build/prodbox.dhall` and this run's
`.test-data/` before creating them. Those artifact obligations participate in the durable
lifecycle-owned `CleanupRun`; the topology runner is a registration client, not a second scheduler.
They therefore run on success, failure, deadline exhaustion, and interruption without becoming the
cleanup mechanism for real infrastructure. Artifact cleanup deletes **only the per-run half**. It
**retains** the authored `prodbox.test.dhall` and **every long-lived resource** — the `aws-ses`
sending identity and the S3-backed `pulumi_state_backend` bucket, which take minutes to reprovision
and are shared across runs.

Retention is a cleanup rule, not an exclusion from preparation. This topology doctrine owns only
the separation: a selected capability may add a visible desired-present action for a registered
`LongLived` resource, while ordinary teardown still schedules no long-lived destroy. The
capability projection is owned by
[Integration Fixture Doctrine §2A](./integration_fixture_doctrine.md#2a-retained-desired-presence-preparation),
and the authoritative retained-SES ordering, authorities, observations, and readiness contract are
owned by
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

The test topology does not invent a parallel cleanup scheduler. It projects artifact obligations and
managed-resource lifecycle classes into the lifecycle-owned graph through typed client requests.
The target projection is defined by the
[managed-resource registry](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary):
`PerRun` resources may be selected for ordinary cleanup, while no `LongLived` resource can inhabit
that cleanup target. Independent ready nodes continue after sibling failure and the final report
aggregates the originating validation result with every cleanup failure. The two symmetric illegal
states are:

- **Destroying a long-lived resource** — a test that tore down `aws-ses` or the state bucket. No
  ordinary validation-cleanup constructor accepts that lifecycle class; unobservability remains a
  refusal rather than permission to reclassify it.
- **Leaking a per-run resource** — a per-run stack or `.test-data/` root that survives a run. The
  exact observer for each registered key must return absence before cleanup can complete. The
  terminal escape audit remains defense-in-depth and cannot prove that slice absent. A **retained
  long-lived** resource is not a leak; it is correctly retained per its class.

## 6. Secrets travel by reference; one cleartext file, flagged

The generated test Dhall names the fixtures a suite needs and carries **no secret material of any
kind** — not inline, and not by `SecretRef` either. The sole cleartext-secret-at-rest file remains
`test-secrets.dhall`, whose values are accepted only by the harness and only through the
`SecretRef.TestPlaintext` arm. This doc does not restate the reference model:
[config_doctrine.md §6.2](./config_doctrine.md#62-secretref-typed-secret-references) and
[vault_doctrine.md](./vault_doctrine.md) own it.

**Corrected 2026-08-11 (Standard C).** This section previously said a test Dhall that inlined a
credential "would be unrepresentable, because the schema's secret fields are typed `SecretRef`."
`dhall/TestTopologySchema.dhall` contains no `SecretRef` — and, more to the point, no secret field
for one to be the type *of*. Its whole vocabulary is `FixtureId`, `Budget`, `RunVariant`, `Suite`,
and `TestTopology`, of which the only `Text` is a suite name. The true property is **stronger** than
the one claimed: a literal secret is unrepresentable here for want of anywhere to put it, and a
fixture is nameable only through the closed three-constructor `FixtureId` enum (§2). The `SecretRef`
machinery is real and is the config surface's, not this schema's; the correction removes a borrowed
guarantee, not a real one.

## Intent Ownership

This SSoT owns the test-topology doctrine: the executable-sibling `prodbox.test.dhall` as the
explicit, self-validating SSoT of one test run; the `test init` overwrite-refusal; the
`test run <suite>|all` per-variant deploy-path reuse; the two fail-fast preconditions inverting the
production sibling-config contract; `.test-data/` isolation with a never-touch-`.data/` delete
guard; and artifact cleanup obligations that retain long-lived resources by lifecycle class.

- Owned target statement: a test run is fully described by its authored `prodbox.test.dhall`, drives
  the real deploy path across every declared variant, and registers and schedules teardown of its
  per-run artifacts without targeting production config, production `.data/`, or a long-lived
  resource. Target completion is constructible only after exact absence is observed; partial or
  unobservable cleanup remains explicitly incomplete. The current runner remains bounded by the
  pre-cutover correspondence in §1.
- Linked dependents: `dhall/TestTopologySchema.dhall`,
  `src/Prodbox/TestTopology.hs`, `src/Prodbox/Repo.hs` (test-Dhall sibling resolution),
  `src/Prodbox/Settings.hs` (test-Dhall decode/validation), and `src/Prodbox/TestRunner.hs`
  (topology-mode sibling-config preflight).
- Command/cleanup dependents: `src/Prodbox/CLI/Command.hs` (the `test init` /
  `test run` surface extending `TestCommand` / `TestScope`), `src/Prodbox/TestRunner.hs`
  (current per-variant generate → reconcile → assert path; target lifecycle-client registration),
  `src/Prodbox/TestValidation.hs`
  (`.test-data/` repointing), `src/Prodbox/Lib/Storage.hs` (the `.test-data/`
  `manual_pv_host_root` override), and the lifecycle registry/cleanup core linked above.

## Cross-References

- [config_doctrine.md](./config_doctrine.md) — the binary-sibling `prodbox.dhall` contract this doc inverts for tests.
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — exact keyed
  observations, lifecycle-indexed cleanup targets, result-indexed programs, and the terminal escape
  audit boundary.
- [unit_testing_policy.md](./unit_testing_policy.md) — interpreter-only mocking, named validations, and infrastructure-test proof requirements.
- [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) — fixture ownership, cleanup-failure-is-a-real-failure, and fixtures-vs-substrate-config.
- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) — the
  dedicated Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and Gateway Runtime
  boundaries used by real-system fixtures; this topology document does not redefine them.
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the `manual_pv_host_root` retained-root model that `.test-data/` overrides.
- [pure_fp_standards.md](./pure_fp_standards.md) — closed ADTs, GADT-indexed / projection state, and the Dhall `assert` illegal-states-unrepresentable technique.
- [vault_doctrine.md](./vault_doctrine.md) — the `SecretRef` model and the `test-secrets.dhall` `TestPlaintext` split.
- [Development Plan status](../../DEVELOPMENT_PLAN/README.md#resume-here) — implementation,
  migration, validation, and cleanup ownership.
- [../documentation_standards.md](../documentation_standards.md) — documentation SSoT and header rules.
