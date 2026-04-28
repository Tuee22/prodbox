# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/aws_test_environment.md

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
   temporary operational `aws.*` for `prodbox test integration aws-iam`,
   `prodbox test integration all`, and `prodbox test all`.
5. Cleanup failures must be surfaced explicitly to the operator.

## 3. Isolation Modes

Supported isolation patterns include:

- fake-tool built-frontend proof in `test/integration/cli/Main.hs`
- repository-local config proof in `test/integration/env/Main.hs`
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

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
