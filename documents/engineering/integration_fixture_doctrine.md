# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/aws_test_environment.md
**Generated sections**: none

> **Purpose**: Define integration setup, teardown, and cleanup ownership for real-system
> validation.

## 0. Canonical Doctrine Statements

- Real-system validation must own its setup and cleanup behavior explicitly.
- Cleanup obligations must be visible in the validation flow, not hidden behind ambient machine
  state.
- Named `prodbox test integration ...` commands may depend on real infrastructure, but their setup
  and cleanup ownership must remain explicit and auditable.

## 1. Scope

This doctrine applies to:

- built-frontend integration suites under `test/integration/`
- native real-world validation flows in `src/Prodbox/TestValidation.hs`
- AWS- and Route-53-backed lifecycle checks
- cluster-backed validation flows that modify shared runtime state

## 2. Fixture Ownership Rules

Ownership rules:

1. The code that allocates real resources owns the primary cleanup path.
2. Command-level postflight repair in `src/Prodbox/TestRunner.hs` owns aggregate supported-runtime
   restoration for destructive suites.
3. AWS-mutating validation flows must clean up resources they create before reporting success.
4. The suite-level IAM harness in `src/Prodbox/TestRunner.hs` owns setup and teardown of
   temporary operational `aws.*` for `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all`. **The IAM-harness tier is
   capability-derived (Sprint `5.6`):** `derivedManagedAwsHarnessPolicyTier` in
   `src/Prodbox/TestPlan.hs` engages the harness exactly when a validation declares an
   AWS-credential-consuming prerequisite on the AWS substrate, or is `aws-iam` /
   `keycloak-invite` (which materialize operational credentials on every substrate). The
   former `normalizeManagedAwsHarness` `substrate=aws` blanket override is **deleted**: a
   credential-free validation (e.g. `gateway-partition`) no longer acquires the IAM harness
   merely because the active substrate is AWS.
5. Cleanup failures must be surfaced explicitly to the operator.

The destructive `--dry-run` golden fixtures under `test/golden/destructive/` (Sprint `5.6`:
`rke2-delete.txt`, `rke2-delete-cascade.txt`, `nuke.txt`) are **registry-generated** — their
per-run, `aws-ses`, and long-lived destroy lines derive from the managed-resource registry /
`StackDescriptor` SSoT, and a drift guard fails the suite if a registered resource is added
without regenerating the golden. They prove each destructive path's planned step list without
allocating or destroying any real resource.

## 3. Isolation Modes

Supported isolation patterns include:

- fake-tool built-frontend proof in `test/integration/CliSuite.hs`
- repository-local config proof in `test/integration/EnvSuite.hs`
- ephemeral AWS hosted zones or stacks created and destroyed by the named validation flow
- aggregate runtime repair through the public `prodbox` surface after destructive integration work

## 4. Cleanup Failure Handling

Cleanup failures are real failures.

- do not silently swallow cleanup errors
- prefer reporting the validation failure first if both validation and cleanup fail
- still attempt cleanup when safe to do so after a mid-validation failure

## 5. Relationship To Other Doctrine

This document works with:

- [Unit Testing Policy](./unit_testing_policy.md) for test-runner and phase-banner doctrine
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md) for real AWS
  auth and isolation rules
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md) for retained local data behavior

## 6. Fixtures Versus Substrate Config

A fixture is a boundary-injected fake-tool harness or an ephemeral resource owned for the
lifetime of one validation. A substrate is the operator-provisioned real environment a
canonical-suite run targets (DNS, certs, ingress, charts) per the inventory in
[`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md). The two are not
interchangeable:

- Fixtures may be reused across substrates because they fake a boundary (`aws` CLI, `dig`,
  `kubectl`) rather than represent the substrate itself.
- Substrate config (e.g. `aws_substrate.hosted_zone_id`, `route53.zone_id`) is required and
  substrate-locked per
  [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback).
  A validation that runs on the AWS substrate must consume only AWS-substrate config; a
  validation that runs on the home substrate must consume only home-substrate config.
  Fixtures do not silence missing-substrate-config errors, and a fake-tool harness does not
  satisfy a substrate prerequisite that requires real infrastructure.

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
