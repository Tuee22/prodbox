# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, README.md, documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/aws_test_environment.md, AGENTS.md

> **Purpose**: Define how prodbox uses Dhall-configured AWS authentication for integration tests and creates, tags, isolates, and cleans up real AWS resources.

---

## 0. Canonical Doctrine Statements

`prodbox` AWS authentication material must be stored only in the repository-root `prodbox-config.dhall`, compiled to `prodbox-config.json` by `prodbox config compile`, and read by `Settings`.

`prodbox` must not search upward from the current working directory or prefer alternate config files.

Stateful AWS integration uses explicit credentials loaded from the Dhall-compiled configuration, not ambient host AWS CLI state or shared profile discovery.

The AWS test harness must rebuild subprocess AWS auth from `Settings` before test execution; it must not perform interactive login inside the repo or inside pytest.

Ambient AWS auth environment variables outside the Dhall configuration are forbidden for `prodbox` commands, fixtures, and tests.

Only the following AWS auth fields are supported in the Dhall configuration: `aws.access_key_id`, `aws.secret_access_key`, and optional `aws.session_token`.

Stateful AWS-mutating integration tests must create only brand-new ephemeral AWS resources through AWS CLI commands owned by the test fixture.

Those resources must be isolated from existing environments, clearly marked as ephemeral and safe to delete, and always cleaned up by fixture teardown even when the test body fails.

Existing AWS resources are never valid mutation targets for integration tests.

---

## 0A. Planning Ownership

This document owns AWS integration doctrine only.

Clean-room sequencing, completion status, remaining work, and legacy-path
removal for AWS validation are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 1. Scope

This doctrine applies to any integration test that creates, updates, or deletes real AWS state.
It also defines the auth-source contract for the read-only public Route 53 delegation proof
that compares public DNS results for `VSCODE_FQDN` against the canonical hosted zone
identified by `ROUTE53_ZONE_ID`.

Current expected users:

1. Route 53 integration tests for `prodbox dns check` and the canonical gateway Route 53 write client.
2. Shared-account foundation integration tests that create delegated Route 53 child zones plus tagged S3 and EC2/VPC resources and then prove selective janitor cleanup.
3. Real EKS integration tests that create a tagged control plane plus tagged IAM role and VPC dependencies.
4. Real Pulumi integration tests that require a fixture-owned Route 53 hosted zone ID.
5. Read-only public Route 53 delegation proof for `VSCODE_FQDN`.
6. Any future AWS-backed integration test that provisions temporary IAM-visible resources.

It does not own the general multi-project AWS test-account topology, shared parent-domain strategy, or shared-account authentication posture. Those are defined in [AWS Test Environment](./aws_test_environment.md).

This document does not restate general integration skip/fail-fast policy. That remains owned by [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).

This document does not restate cluster fixture ownership rules. Those remain owned by [Integration Fixture Doctrine](./integration_fixture_doctrine.md).

The public delegation proof does not create AWS resources, but it must still read auth only
from the Dhall-compiled configuration and fail fast when `route53:GetHostedZone` on
`ROUTE53_ZONE_ID` is unavailable.

---

## 2. Authentication Source And Storage Rules

### 2.1 Dhall Configuration Ownership

AWS authentication material for `prodbox` must live only in the repository-root
`prodbox-config.dhall`, compiled to `prodbox-config.json` by `prodbox config compile`.

`Settings.from_config_json()` loads only `<repository-root>/prodbox-config.json`.
If that file is absent or incomplete, settings validation must fail; nested or alternate
config files are not valid fallback sources.

Required Dhall config fields:

1. `aws.access_key_id`
2. `aws.secret_access_key`

Optional Dhall config field:

1. `aws.session_token`

Forbidden storage patterns:

1. Unversioned repo-local shell snippets that export AWS secrets.
2. Checked-in example files containing real AWS auth data.
3. Temporary credential dumps written into project directories outside the Dhall config.
4. Reliance on `~/.aws` shared config or cache as the auth source for `prodbox`.
5. Use of `.env` files for AWS credentials.

### 2.2 No Ambient Or Profile-Based AWS Auth

The system-installed `aws` CLI may be used by tests, but only with subprocess auth rebuilt from `Settings` (loaded from the Dhall-compiled configuration).

Forbidden test-harness behavior:

1. Running `aws login` interactively as part of pytest.
2. Running `aws configure` interactively inside the repo as part of test execution.
3. Generating alternate repo-local credential files for test convenience.
4. Exporting AWS auth env vars before invoking `prodbox` or pytest.
5. Relying on AWS shared config, shared credentials, or cached profile state instead of the Dhall configuration.
6. Injecting AWS auth env vars into subprocesses started by repo code or tests unless those vars were rebuilt from `Settings`.

### 2.3 Disallowed Ambient AWS Auth Variables

The following environment variables are forbidden when present outside the Dhall configuration:

1. `AWS_ACCESS_KEY_ID`
2. `AWS_SECRET_ACCESS_KEY`
3. `AWS_SESSION_TOKEN`
4. `AWS_SECURITY_TOKEN`
5. `AWS_PROFILE`
6. `AWS_DEFAULT_PROFILE`
7. `AWS_SHARED_CREDENTIALS_FILE`
8. `AWS_CONFIG_FILE`
9. `AWS_WEB_IDENTITY_TOKEN_FILE`
10. `AWS_ROLE_ARN`
11. `AWS_ROLE_SESSION_NAME`

`prodbox` code and tests must fail fast when any of these variables are set in ambient process state or used as alternate auth sources.

---

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating test body runs, the harness must prove all of the following:

1. The system `aws` CLI exists on `PATH`.
2. The Dhall-compiled configuration already defines usable AWS authentication for the identity the test will run under.
3. That configuration-defined identity can create, tag, mutate, inspect, and delete the same AWS resource types the fixture will own.

### 3.2 Required Check Semantics

The required checks map to the following concrete obligations:

1. Tool check: `aws` must be invokable by the test harness.
2. Config auth check: `aws sts get-caller-identity` must succeed with subprocess auth rebuilt from `Settings` before the suite proceeds.
3. Resource-capability check: the fixture setup must successfully execute the same create/tag/mutate/delete AWS CLI operations using configuration-defined auth that define the resource lifecycle for the suite.

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

If AWS creates untaggable child resources under a tagged parent resource, the fixture must delete the tagged parent and verify that the AWS-managed children disappear with it.

All taggable fixture-owned Route 53, S3, VPC, subnet, security-group, EKS, and IAM resources
must receive the canonical ownership/expiry/safe-delete tag set as soon as the create path
allows.

---

## 5. Fixture Ownership And Cleanup

### 5.1 Fixture Owns Setup

The fixture, not the test body, creates the AWS environment.

Before creating new resources, fixture setup must run scope-owned preflight cleanup for the same
project/suite scope the fixture is about to allocate.

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

If setup fails before the fixture yields, the helper must roll back every resource it created in
that attempt before surfacing the error.

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited.

If fixture-owned AWS cleanup fails, teardown must abort the pytest session with explicit target and error text because later AWS tests can no longer assume clean baseline state.

---

## 6. Required AWS CLI Commands

### 6.1 Common Harness Commands

All real AWS suites depend on:

1. `aws sts get-caller-identity`

### 6.2 Route 53 And Delegation Commands

The canonical Route 53 command set for hosted-zone and delegated-child-zone tests is:

1. `aws route53 create-hosted-zone`
2. `aws route53 change-tags-for-resource`
3. `aws route53 get-hosted-zone`
4. `aws route53 list-tags-for-resource`
5. `aws route53 list-resource-record-sets`
6. `aws route53 change-resource-record-sets`
7. `aws route53 delete-hosted-zone`

### 6.3 S3 And EC2/VPC Foundation Commands

The canonical shared-account foundation command set also includes:

1. `aws s3api create-bucket`
2. `aws s3api put-bucket-tagging`
3. `aws s3api get-bucket-tagging`
4. `aws s3api put-object`
5. `aws s3api get-object`
6. `aws s3api list-objects-v2`
7. `aws s3api delete-object`
8. `aws s3api delete-bucket`
9. `aws ec2 create-vpc`
10. `aws ec2 modify-vpc-attribute`
11. `aws ec2 create-subnet`
12. `aws ec2 create-security-group`
13. `aws ec2 create-network-interface`
14. `aws ec2 create-tags`
15. `aws ec2 describe-vpcs`
16. `aws ec2 describe-subnets`
17. `aws ec2 describe-security-groups`
18. `aws ec2 describe-network-interfaces`
19. `aws ec2 delete-network-interface`
20. `aws ec2 delete-security-group`
21. `aws ec2 delete-subnet`
22. `aws ec2 delete-vpc`

### 6.4 EKS Fixture Commands

The canonical EKS suite command set also includes:

1. `aws iam create-role`
2. `aws iam list-role-tags`
3. `aws iam attach-role-policy`
4. `aws iam detach-role-policy`
5. `aws iam delete-role`
6. `aws iam list-roles`
7. `aws iam list-attached-role-policies`
8. `aws eks create-cluster`
9. `aws eks describe-cluster`
10. `aws eks wait cluster-active`
11. `aws eks delete-cluster`
12. `aws eks wait cluster-deleted`
13. `aws eks list-clusters`

---

## 7. Route 53 Fixture Contract

For Route 53-backed AWS tests, the fixture contract is:

1. Create a fresh hosted zone with a unique name.
2. Tag that hosted zone as ephemeral and safe to delete.
3. Point the test environment at that hosted zone only.
4. Delete any fixture-owned record sets before deleting the hosted zone.
5. Delete the hosted zone in teardown.

Tests must verify `prodbox` behavior against the fixture-owned hosted zone only.
This applies both to direct DNS tests and to Pulumi tests that need a Route 53 hosted zone ID.

---

## 8. Shared-Account Foundation Fixture Contract

For the shared-account foundation suite, the fixture contract is:

1. Run scope-owned preflight cleanup for the same project/suite scope before creating new
   resources.
2. Create a tagged parent hosted zone.
3. Create tagged child hosted zones for each project scope and delegate them from the parent
   zone.
4. Create tagged S3 buckets and tagged EC2/VPC resources for each project scope.
5. Prove that scope-scoped preflight cleanup removes only the matching prior child zone, bucket,
   and VPC scope.
6. Prove that an expired-scope janitor sweep deletes only expired matching child zone, bucket,
   and VPC scope.
7. Prove that unexpired scopes remain intact until their fixture teardown runs.

---

## 9. EKS Fixture Contract

For the EKS suite, the fixture contract is:

1. Create a tagged IAM role for the control plane.
2. Create a tagged VPC with at least two tagged subnets and a tagged security group.
3. Create a tagged EKS control plane that depends only on those fixture-owned resources.
4. Wait for the control plane to become `ACTIVE`.
5. Delete the control plane, then the IAM role, then the VPC resources in teardown.
6. Janitor and preflight cleanup paths must be able to delete the cluster, role, and VPC
   resources without rereading deleted cluster metadata.
7. Treat AWS-managed service-linked roles as shared-account baseline state, not project-owned
   test resources.

---

## 10. Relationship To Other Doctrine

1. General unit vs integration policy and fail-fast expectations are defined in [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).
2. Cluster-backed fixture ownership is defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).
3. The explicit `prodbox test integration ...` suite surface is defined in [CLI Command Surface](./cli_command_surface.md#prodbox-test).
4. General shared-account AWS test environment design is defined in [AWS Test Environment](./aws_test_environment.md).

---

## 11. Fixture Leak Prevention

Three harness-owned controls prevent leaked ephemeral AWS resources from accumulating when
integration test processes crash before fixture teardown runs:

1. **Per-test full tagged-resource preflight**: Each AWS-mutating fixture runs
   `create_clean_fixture_scope(...)` or equivalent harness-owned cleanup before creating new
   resources. That preflight sweeps any pre-existing fixture-owned Route 53, S3, VPC, EKS, and
   IAM resources discoverable by the canonical tag set; it is not limited to one declared
   project/suite scope.
2. **Immediate tagging plus setup rollback**: Taggable fixture-owned resources receive the
   canonical ownership, expiry, and safe-delete tags as soon as the create path can apply them,
   and setup helpers roll back partial creation before fixture yield.
3. **Aggregate zero-residue proof**: `poetry run prodbox test all` finishes with a supported
   fixture inventory audit that fails if any fixture-owned Route 53, S3, VPC, EKS, or IAM
   resources remain.

No session-scoped sweep, standalone `prodbox aws ...` janitor surface, or host cron job is part
of the supported cleanup model.

---

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [CLI Command Surface](./cli_command_surface.md)
- [AWS Test Environment](./aws_test_environment.md)
- [Documentation Standards](../documentation_standards.md)
