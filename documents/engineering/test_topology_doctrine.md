# Test Topology Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](./README.md), [../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md), [unit_testing_policy.md](./unit_testing_policy.md), [integration_fixture_doctrine.md](./integration_fixture_doctrine.md)
**Generated sections**: none

> **Purpose**: Single source of truth for the executable-sibling `prodbox.test.dhall` — the explicit, self-describing SSoT of one test run — and the `test init` / `test run` surface that stands each declared cluster variant up, asserts it, and always tears down per-run state without touching production config/`.data/` or destroying a long-lived resource.

## 1. A test run is fully described by its test Dhall

A `prodbox` test run is not a mode of the production config; it is authored by a **separate,
differently-shaped Dhall surface**. `prodbox test init` writes `prodbox.test.dhall` at the
**executable-sibling path** (`.build/prodbox.test.dhall`, beside the binary — the same resolution
rule the production config uses, [config_doctrine.md §3](./config_doctrine.md#3-canonical-paths)),
and that file **is** the run: the HA/failover cluster shape, the suite vocabulary, per-suite
budgets, and the fixtures each suite needs. Nothing about a run is implicit in ambient machine
state — the test Dhall is the audit trail of what will be stood up.

This inverts today's transitional shape. Today the legacy harness still **regenerates the production
binary-sibling `prodbox.dhall` in place** from `test-secrets.dhall` before validations run
(`regenerateConfigFromTestSecrets`, `src/Prodbox/TestRunner.hs`; `src/Prodbox/Aws.hs`). Sprint
`1.54` landed the distinct authored test-topology schema, Haskell mirror, executable-sibling
decoder, and topology-mode sibling-Dhall fail-fast inversion in
`dhall/TestTopologySchema.dhall`, `src/Prodbox/TestTopology.hs`, `src/Prodbox/Repo.hs`,
`src/Prodbox/Settings.hs`, and `src/Prodbox/TestRunner.hs`. Sprint `5.11` landed the command
surface: `test init` authors the topology file; `test run` generates a disposable per-variant
Tier-0 `prodbox.dhall`, points storage at `.test-data/<case>/`, runs the existing deploy/assert
path, and deletes the generated config plus this run's `.test-data` root in `finally` per
[Phase 5 Sprint 5.11](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).

`prodbox.test.dhall` is the **authored** half of the per-run-vs-authored split. The **per-run**
half is the binary-sibling `prodbox.dhall` the harness renders for each variant (§3) plus the
run's `.test-data/` (§4) — both disposable, both deleted on teardown (§5). The authored test
Dhall is retained. Like jitML's `project init` (in the sibling project
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
| A secret carried inline as cleartext rather than by reference | the field type is `SecretRef`, so a literal secret is unrepresentable (§6) |

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
[lifecycle_reconciliation_doctrine.md §3](./lifecycle_reconciliation_doctrine.md#3-the-reconciler-with-predicates-pattern):

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
   present**, so a run can never clobber a real operator config. Sprint `1.54` landed this
   topology-mode gate for authored `prodbox.test.dhall` runs. Sprint `5.11` added the
   topology-run command surface: the per-variant generated `prodbox.dhall` (§3) is written only
   after this gate clears and is deleted on teardown (§5).
2. **Refuse if a production cluster is running.** A test never mutates production cluster state.

Durable test storage is the **`.test-data/` retained root** — a `storage.manual_pv_host_root`
override ([storage_lifecycle_doctrine.md §7](./storage_lifecycle_doctrine.md#7-the-single-retained-operator-host-root);
`defaultChartDataRootRelative`, `src/Prodbox/Lib/Storage.hs`) pointed at `.test-data/` for the run
instead of the production `.data/`. Each case is isolated under `.test-data/<case>/`. Test commands
are **mechanically forbidden from touching `.data/`**, mirroring in kind the sibling project's
`guardTestDelete` never-delete-`.data` rule (`hostbootstrap/documents/engineering/testing.md`;
no code dependency). The guard's delete target is a closed ADT that cannot name `.data/`:

```haskell
-- Example: teardown can only name this-run generated artifacts and PerRun residue;
-- deleting .data/, the authored prodbox.test.dhall, or a LongLived resource is unconstructible.
data TestDeleteTarget
  = GeneratedRunConfig        -- .build/prodbox.dhall for this run
  | ThisRunTestData FilePath  -- a path proven under .test-data/
  | PerRunResidue StackName   -- LifecycleClass PerRun stacks only
  deriving (Eq, Show)

guardTestDelete :: FilePath -> Either TestRefusal TestDeleteTarget  -- refuses any path outside .test-data/
```

`src/Prodbox/TestValidation.hs` resolves the sealed-Vault host-disk audit root from the topology
run's `PRODBOX_TEST_MANUAL_PV_HOST_ROOT` override when present, falling back to the production
`.data/prodbox/minio/0` root for legacy named-validation commands.

## 5. Teardown is finally-guaranteed and reuses the lifecycle classes

Teardown runs on **every** exit — success, failure, and Ctrl-C — via structured `finally`, exactly
as [unit_testing_policy.md § Pulumi-Orchestrated Infrastructure Tests](./unit_testing_policy.md#pulumi-orchestrated-infrastructure-tests)
and [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) require. It deletes **only
the per-run half**: the generated `.build/prodbox.dhall` and this run's `.test-data/`. It
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

Teardown does not invent a parallel cleanup mechanism; it reuses the managed-resource registry.
The `LifecycleClass PerRun | LongLived | Operational` partition
(`src/Prodbox/Lifecycle/ResourceClass.hs`), `partitionResidueByLifecycle` (`src/Prodbox/Aws.hs`),
and the `noLiveLongLivedPulumiStacks` gate (`src/Prodbox/Lifecycle/Preconditions.hs`) are the same
values [lifecycle_reconciliation_doctrine.md §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
owns. Teardown reconciles the `PerRun` slice to absent and **gates** the `LongLived` slice so a test
can never destroy it. The two symmetric illegal states are:

- **Destroying a long-lived resource** — a test that tore down `aws-ses` or the state bucket. The
  `LongLived` gate refuses; `noLiveLongLivedPulumiStacks`'s `Unreachable → refuse` soundness rule
  means "could not observe" is never silently treated as "safe to delete."
- **Leaking a per-run resource** — a per-run stack or `.test-data/` root that survives a run. The
  postflight sweep asserts the `PerRun` slice is empty; a non-empty sweep is a hard test failure
  with the leak list in the record. A **retained long-lived** resource is *not* a leak — it is
  correctly retained per its class.

## 6. Secrets travel by reference; one cleartext file, flagged

The generated test Dhall carries secrets **only by `SecretRef` name**, never inline — the same
`SecretRef` contract every `prodbox` config obeys. The sole cleartext-secret-at-rest file remains
`test-secrets.dhall`, whose values are accepted only by the harness and only through the
`SecretRef.TestPlaintext` arm. This doc does not restate that model:
[config_doctrine.md §6.2](./config_doctrine.md#62-secretref-typed-secret-references) and
[vault_doctrine.md](./vault_doctrine.md) own it. A test Dhall that inlined a credential would be
unrepresentable, because the schema's secret fields are typed `SecretRef` (§2).

## Intent Ownership

This SSoT owns the test-topology doctrine: the executable-sibling `prodbox.test.dhall` as the
explicit, self-validating SSoT of one test run; the `test init` overwrite-refusal; the
`test run <suite>|all` per-variant deploy-path reuse; the two fail-fast preconditions inverting the
production sibling-config contract; `.test-data/` isolation with a never-touch-`.data/` delete
guard; and finally-guaranteed teardown that retains long-lived resources by lifecycle class.

- Owned statement: a test run is fully described by its authored `prodbox.test.dhall`, drives the
  real deploy path across every declared variant, and always tears down its per-run artifacts
  without touching production config, production `.data/`, or a long-lived resource.
- Linked dependents (Sprint `1.54` landed): `dhall/TestTopologySchema.dhall`,
  `src/Prodbox/TestTopology.hs`, `src/Prodbox/Repo.hs` (test-Dhall sibling resolution),
  `src/Prodbox/Settings.hs` (test-Dhall decode/validation), and `src/Prodbox/TestRunner.hs`
  (topology-mode sibling-config preflight).
- Linked dependents (Sprint `5.11` landed): `src/Prodbox/CLI/Command.hs` (the `test init` /
  `test run` surface extending `TestCommand` / `TestScope`), `src/Prodbox/TestRunner.hs`
  (per-variant generate → reconcile → assert → `finally` teardown), `src/Prodbox/TestValidation.hs`
  (`.test-data/` repointing), `src/Prodbox/Lib/Storage.hs` (the `.test-data/`
  `manual_pv_host_root` override), `src/Prodbox/Lifecycle/ResourceClass.hs` + `src/Prodbox/Aws.hs` +
  `src/Prodbox/Lifecycle/Preconditions.hs` (the lifecycle-class teardown reuse).

## Cross-References

- [config_doctrine.md](./config_doctrine.md) — the binary-sibling `prodbox.dhall` contract this doc inverts for tests.
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) — `LifecycleClass`, `partitionResidueByLifecycle`, the `Unreachable → refuse` soundness rule, and the postflight sweep the teardown reuses.
- [unit_testing_policy.md](./unit_testing_policy.md) — interpreter-only mocking, the named-validation suite, and the `finally`/tagging infrastructure-test rules.
- [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) — fixture ownership, cleanup-failure-is-a-real-failure, and fixtures-vs-substrate-config.
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the `manual_pv_host_root` retained-root model that `.test-data/` overrides.
- [pure_fp_standards.md](./pure_fp_standards.md) — closed ADTs, GADT-indexed / projection state, and the Dhall `assert` illegal-states-unrepresentable technique.
- [vault_doctrine.md](./vault_doctrine.md) — the `SecretRef` model and the `test-secrets.dhall` `TestPlaintext` split.
- [../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md) — Sprint 1.54 (schema + sibling-Dhall fail-fast inversion).
- [../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md) — Sprint 5.11 (command topology, `.test-data/` isolation, finally teardown, never-touch-`.data/`).
- [../documentation_standards.md](../documentation_standards.md) — documentation SSoT and header rules.
