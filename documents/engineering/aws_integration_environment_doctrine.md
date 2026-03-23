# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_COMPLETION_PLAN.md, README.md, documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_doctrine.md, AGENTS.md

> **Purpose**: Define how prodbox uses host-level AWS CLI authentication for integration tests and creates, tags, isolates, and cleans up real AWS resources.

---

## 0. Canonical Doctrine Statements

AWS authentication material must never be stored anywhere under the repository tree, including unversioned `.env` files.

Stateful AWS integration uses the system-level `aws` CLI on the host, not repo-local auth helpers.

The AWS test harness must consume host authentication that already exists before the test run begins; it must not perform interactive login inside the repo or inside pytest.

Stateful AWS-mutating integration tests must create only brand-new ephemeral AWS resources through AWS CLI commands owned by the test fixture.

Those resources must be isolated from existing environments, clearly marked as ephemeral and safe to delete, and always cleaned up by fixture teardown even when the test body fails.

Existing AWS resources are never valid mutation targets for integration tests.

---

## 1. Scope

This doctrine applies to any integration test that creates, updates, or deletes real AWS state.

Current expected users:

1. Route 53 integration tests for `prodbox dns check` and `prodbox dns update`.
2. Any future AWS-backed integration test that provisions temporary IAM-visible resources.

This document does not restate general integration skip/fail-fast policy. That remains owned by [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).

This document does not restate cluster fixture ownership rules. Those remain owned by [Integration Fixture Doctrine](./integration_fixture_doctrine.md).

---

## 2. Authentication Source And Storage Rules

### 2.1 No Repo-Local Auth Storage

AWS authentication material must not be stored anywhere under the repository tree.

Prohibited examples:

1. `.env` files under the repo that contain AWS auth credentials.
2. Unversioned repo-local shell snippets that export AWS secrets.
3. Checked-in example files containing real AWS auth data.
4. Temporary credential dumps written into project directories.

Allowed locations:

1. System-level AWS CLI profile/config state under the operator home directory.
2. System-level AWS CLI cache state under the operator home directory.
3. Current-shell environment variables that were derived from host authentication and never written into repo files.

### 2.2 System-Level AWS CLI Ownership

The system-installed `aws` CLI is the only supported authentication entrypoint for real AWS integration tests.

Allowed host-level authentication patterns include:

1. Existing AWS CLI profiles under `~/.aws`.
2. Existing AWS CLI login state created outside the repository.
3. Existing host shell exports derived from the system AWS CLI.

Forbidden test-harness behavior:

1. Running `aws login` interactively as part of pytest.
2. Running `aws configure` interactively inside the repo as part of test execution.
3. Generating repo-local credential files for test convenience.

### 2.3 Shell Export Compatibility

Some `prodbox` commands still expect AWS auth values in the process environment. When that compatibility path is used, the values must come from host-level AWS CLI authentication and may live only in the current shell session.

Those values must not be written into any file under the repository tree.

---

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating test body runs, the harness must prove all of the following:

1. The system `aws` CLI exists on `PATH`.
2. The host already has usable AWS authentication for the identity the test will run under.
3. That authenticated identity can create, tag, mutate, inspect, and delete the same AWS resource types the fixture will own.

### 3.2 Required Check Semantics

The required checks map to the following concrete obligations:

1. Tool check: `aws` must be invokable by the test harness.
2. Host-auth check: `aws sts get-caller-identity` must succeed before the suite proceeds.
3. Resource-capability check: the fixture setup must successfully execute the same create/tag/mutate/delete AWS CLI operations that define the resource lifecycle for the suite.

### 3.3 No In-Harness Login

The harness must fail fast with an actionable prerequisite error when any required check is missing.

The harness must not:

1. Open a browser login flow.
2. Prompt for interactive AWS configuration.
3. Attempt to repair missing host authentication automatically.

### 3.4 Route 53 Capability Proof Rule

For the `dns-aws` suite, permission sufficiency is proven only when the fixture can successfully create and fully own a fresh hosted zone lifecycle using the canonical Route 53 command set in this document.

It is not sufficient to prove only `sts:GetCallerIdentity` or read-only Route 53 access.

---

## 4. Environment Creation Rules

### 4.1 Brand-New Resources Only

AWS-mutating integration tests must create new resources for the test run. They must not:

1. Reuse a long-lived hosted zone.
2. Reuse a shared stack/environment.
3. Mutate records or resources that predate the fixture.

### 4.2 Isolation Rule

The fixture owns the full lifecycle of the AWS resources it creates.

Minimum rule:

1. One fixture creates one isolated resource set.
2. Test bodies operate only on fixture-owned identifiers.
3. Teardown deletes the same identifiers before returning.

### 4.3 Required Annotation Rule

Fixture-created AWS resources must be tagged clearly enough that a human operator can safely delete them on sight.

Minimum required tagging intent:

1. The resource is ephemeral.
2. The resource is test-only.
3. The resource is safe to delete.
4. The resource has a scope or owner tag that identifies the originating suite.

---

## 5. Fixture Ownership And Cleanup

### 5.1 Fixture Owns Setup

The fixture, not the test body, creates the AWS environment.

### 5.2 Fixture Owns Teardown

The same fixture that created the resources deletes them.

Idiomatic pytest pattern:

```python
# Example: tests/integration/test_dns_route53_aws.py
@pytest.fixture
def ephemeral_route53_zone() -> Iterator[Route53HostedZoneContext]:
    context = create_ephemeral_hosted_zone(test_scope="dns-aws")
    try:
        yield context
    finally:
        delete_ephemeral_hosted_zone(context)
```

### 5.3 Cleanup Must Run After Test Failure

Fixture teardown must run even when the test body fails an assertion or raises an exception.

Required pytest idioms:

1. Yield fixtures.
2. Fixture-owned `try/finally`.
3. Fixture-owned finalizers when yield fixtures are not appropriate.

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited.

If fixture-owned AWS cleanup fails, teardown must abort the pytest session with explicit target and error text because later AWS tests can no longer assume clean baseline state.

---

## 6. Required AWS CLI Commands

The canonical AWS CLI command set for ephemeral Route 53 integration environments is:

1. `aws sts get-caller-identity`
2. `aws route53 create-hosted-zone`
3. `aws route53 change-tags-for-resource`
4. `aws route53 list-resource-record-sets`
5. `aws route53 change-resource-record-sets`
6. `aws route53 delete-hosted-zone`

These commands are sufficient to:

1. validate the caller identity
2. create an isolated hosted zone
3. annotate that zone as ephemeral test-only state
4. inspect fixture-owned records
5. delete fixture-owned records
6. delete the hosted zone itself

---

## 7. Route 53 Fixture Contract

For Route 53 tests, the fixture contract is:

1. Create a fresh hosted zone with a unique name.
2. Tag that hosted zone as ephemeral and safe to delete.
3. Point the test environment at that hosted zone only.
4. Delete any fixture-owned record sets before deleting the hosted zone.
5. Delete the hosted zone in teardown.

Tests must verify `prodbox` behavior against the fixture-owned hosted zone only.

---

## 8. Relationship To Other Doctrine

1. General unit vs integration policy and fail-fast expectations are defined in [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).
2. Cluster-backed fixture ownership is defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).
3. The explicit `prodbox test integration ...` suite surface is defined in [CLI Command Surface](./cli_command_surface.md#prodbox-test).

---

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Documentation Standards](../documentation_standards.md)
