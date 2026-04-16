# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, README.md, documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_test_environment.md, AGENTS.md

> **Purpose**: Define how `prodbox` authenticates to AWS for integration work and how the
> supported AWS validation path creates, owns, and tears down real AWS resources.

---

## 0. Canonical Doctrine Statements

`prodbox` AWS authentication material must be stored only in the repository-root
`prodbox-config.dhall`, compiled to `prodbox-config.json` by `prodbox config compile`, and read by
`Settings`.

`prodbox` must not search upward from the current working directory or prefer alternate config
files.

Stateful AWS integration uses explicit credentials loaded from the Dhall-compiled configuration,
not ambient host AWS CLI state or shared profile discovery.

Ambient AWS auth environment variables outside the Dhall configuration are forbidden for
`prodbox` commands, fixtures, and tests.

Route 53-only AWS tests create brand-new hosted zones through fixture-owned AWS CLI commands with
subprocess auth rebuilt from `Settings`.

The Pulumi-managed AWS test stacks are created and destroyed only through named `prodbox pulumi`
surfaces. `prodbox pulumi eks-resources` and `prodbox pulumi eks-destroy --yes` own the EKS test
stack. `prodbox pulumi test-resources` and `prodbox pulumi test-destroy --yes` own the HA RKE2
test stack. Pulumi is the sole owner of the VPC, subnet, security-group, IAM, EC2, EKS, and Route
53 lifecycle for those stacks.

The local `prodbox` RKE2 cluster and its MinIO service must exist before any remote AWS test stack
is created because Pulumi state for those stacks lives only in the dedicated bucket
`prodbox-test-pulumi-backends`.

`prodbox rke2 delete --yes` must invoke the same Pulumi-owned AWS test-stack destroy paths before
it removes the local MinIO backend.

Existing AWS resources are never valid mutation targets for supported `prodbox` integration tests.

---

## 0A. Planning Ownership

This document owns AWS integration doctrine only.

Clean-room sequencing, completion status, remaining work, and legacy-path removal for AWS
validation are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 1. Scope

This doctrine applies to any `prodbox` integration test that creates, updates, or deletes real AWS
state. It also defines the auth-source contract for the read-only public Route 53 delegation proof
that compares public DNS results for `VSCODE_FQDN` against the canonical hosted zone identified by
`ROUTE53_ZONE_ID`.

Current expected users:

1. Route 53 integration tests for `prodbox dns check` and the canonical gateway Route 53 write
   client.
2. Real Pulumi integration tests that validate the Pulumi-owned AWS HA test stack surface.
3. Real EKS integration tests that validate the Pulumi-managed AWS EKS test stack.
4. Real HA RKE2 integration tests that bootstrap RKE2 over SSH against the Pulumi-managed AWS HA
   test stack.
5. Read-only public Route 53 delegation proof for `VSCODE_FQDN`.
6. Any AWS-backed integration test that follows the same Dhall-only auth and Pulumi-or-fixture
   ownership model.
7. The IAM lifecycle integration suite `poetry run prodbox test integration aws-iam`, which uses
   the test-only `aws_admin.*` credential section to drive `prodbox aws` lifecycle logic against
   real AWS.

It does not own the general multi-project AWS test-account topology, shared parent-domain strategy,
or shared-account authentication posture. Those are defined in
[AWS Test Environment](./aws_test_environment.md).

This document does not restate general integration skip/fail-fast policy. That remains owned by
[Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).

This document does not restate cluster fixture ownership rules. Those remain owned by
[Integration Fixture Doctrine](./integration_fixture_doctrine.md).

The public delegation proof does not create AWS resources, but it must still read auth only from
Dhall-compiled configuration and fail fast when `route53:GetHostedZone` on `ROUTE53_ZONE_ID` is
unavailable.

---

## 2. Authentication Source And Storage Rules

### 2.1 Dhall Configuration Ownership

AWS authentication material for `prodbox` must live only in the repository-root
`prodbox-config.dhall`, compiled to `prodbox-config.json` by `prodbox config compile`.

`Settings.from_config_json()` loads only `<repository-root>/prodbox-config.json`. If that file is
absent or incomplete, settings validation must fail; nested or alternate config files are not valid
fallback sources.

Required Dhall config fields:

1. `aws.access_key_id`
2. `aws.secret_access_key`

Optional Dhall config field:

1. `aws.session_token`
2. `aws_admin.access_key_id`
3. `aws_admin.secret_access_key`
4. `aws_admin.session_token`
5. `aws_admin.region`

`aws_admin.*` is reserved for `prodbox aws *` command flows and the dedicated IAM lifecycle
integration suite. Normal runtime commands ignore it. Population and cleanup guidance live in
[AWS Admin Credentials](./aws_admin_credentials.md).

Forbidden storage patterns:

1. Unversioned repo-local shell snippets that export AWS secrets.
2. Checked-in example files containing real AWS auth data.
3. Temporary credential dumps written into project directories outside the Dhall config.
4. Reliance on `~/.aws` shared config or cache as the auth source for `prodbox`.
5. Use of `.env` files for AWS credentials.

### 2.2 No Ambient Or Profile-Based AWS Auth

The system-installed `aws` CLI may be used by tests, but only with subprocess auth rebuilt from
`Settings` loaded from the Dhall-compiled configuration.

Forbidden test-harness behavior:

1. Running `aws login` interactively as part of pytest.
2. Running `aws configure` interactively inside the repo as part of test execution.
3. Generating alternate repo-local credential files for test convenience.
4. Exporting AWS auth env vars before invoking `prodbox` or pytest.
5. Relying on AWS shared config, shared credentials, or cached profile state instead of the Dhall
   configuration.
6. Injecting AWS auth env vars into subprocesses started by repo code or tests unless those vars
   were rebuilt from `Settings`.

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

`prodbox` code and tests must fail fast when any of these variables are set in ambient process
state or used as alternate auth sources.

---

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating test body runs, the harness must prove all of the following:

1. The system `aws` CLI exists on `PATH` when the suite uses direct AWS CLI fixtures.
2. The Dhall-compiled configuration already defines usable AWS authentication for the identity the
   suite will run under.
3. That configuration-defined identity can perform the concrete lifecycle the suite owns.

### 3.2 Required Check Semantics

The required checks map to the following concrete obligations:

1. Tool check: `aws` must be invokable by the Route 53 fixture harness.
2. Config auth check: `aws sts get-caller-identity` must succeed with subprocess auth rebuilt from
   `Settings` before an AWS-mutating suite proceeds.
3. Lifecycle-capability check: Route 53 suites must be able to create and fully own a fresh hosted
   zone lifecycle; Pulumi-backed suites must be able to drive the canonical `prodbox pulumi`
   command surface for the AWS EKS and HA stacks.

### 3.3 No In-Harness Login

The harness must fail fast with an actionable prerequisite error when any required check is
missing.

The harness must not:

1. Open a browser login flow.
2. Prompt for interactive AWS configuration.
3. Attempt to repair missing host authentication automatically.

### 3.4 Route 53 Capability Proof Rule

For the `dns-aws` suite, permission sufficiency is proven only when the fixture can successfully
create and fully own a fresh hosted zone lifecycle using the canonical Route 53 command set in this
document.

It is not sufficient to prove only `sts:GetCallerIdentity` or read-only Route 53 access.

### 3.5 Pulumi-Backed Stack Capability Proof Rule

For `aws-eks`, `pulumi`, and `ha-rke2-aws`, permission sufficiency is proven only when the local
host can reach its RKE2-backed MinIO backend and the relevant named `prodbox pulumi` surface can
select, inspect, or create the canonical AWS test stack using Dhall-configured AWS auth.

---

## 4. Environment Creation Rules

### 4.1 Brand-New Resources Only

Supported AWS tests must create new resources for the current run. They must not:

1. Reuse a long-lived hosted zone.
2. Reuse a pre-existing VPC, EC2 instance, security group, or IAM role.
3. Mutate records or resources that predate the owning fixture or Pulumi stack.

### 4.2 Route 53 Fixture-Owned Resources

The `dns-aws` suite may create only the fresh hosted zone and record-set lifecycle that its fixture
owns directly.

Minimum rule:

1. One fixture creates one isolated hosted zone context.
2. Test bodies operate only on fixture-owned identifiers.
3. Teardown deletes the same identifiers before returning.

### 4.3 Pulumi-Owned AWS Test Stacks

The `aws-eks`, `pulumi`, and `ha-rke2-aws` suites must not open-code AWS resource creation through
ad hoc test helpers. They use canonical Pulumi stacks rooted at the local MinIO backend.

Minimum rule:

1. `prodbox rke2 install` creates or reconciles the local backend cluster first.
2. `prodbox pulumi eks-resources` is the only supported surface for creating or inspecting the AWS
   EKS test stack.
3. `prodbox pulumi eks-destroy --yes` is the only supported surface for destroying that stack.
4. `prodbox pulumi test-resources` is the only supported surface for creating or inspecting the
   multi-resource AWS HA stack.
5. `prodbox pulumi test-destroy --yes` is the only supported surface for destroying that stack.
6. `prodbox rke2 delete --yes` must invoke both destroy semantics before it removes the backend
   cluster.

### 4.4 Test-Only Elevated IAM Harness

The AWS IAM lifecycle suite uses the same repository-root Dhall configuration file but a separate
credential section:

1. `aws.*` remains the normal operational identity.
2. `aws_admin.*` is the elevated identity used only for `prodbox aws *` and
   `prodbox test integration aws-iam`.
3. The test suite must fail fast with an actionable error when `aws_admin.*` is missing or partial.

This keeps administrative IAM lifecycle validation separate from the steady-state runtime identity.

---

## 5. Ownership And Cleanup

### 5.1 Route 53 Fixture Owns Setup And Teardown

The fixture, not the test body, creates the Route 53 environment.

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

### 5.2 Pulumi Owns Multi-Resource Stack Lifecycles

The same public CLI surfaces used by operators own the AWS test-stack lifecycles during tests:

1. `prodbox pulumi eks-resources`
2. `prodbox pulumi eks-destroy --yes`
3. `prodbox pulumi test-resources`
4. `prodbox pulumi test-destroy --yes`
5. `prodbox rke2 delete --yes` as the final automatic destroy path before backend teardown

Tests may inspect Pulumi-owned outputs and snapshots, but they must not bypass the CLI with ad hoc
AWS deletion logic for stack-owned resources.

### 5.3 Cleanup Must Run After Test Failure

Cleanup must still run when the test body fails an assertion or raises an exception.

Required patterns:

1. Yield fixtures and fixture-owned `try/finally` for Route 53 lifecycles.
2. Final explicit `prodbox pulumi eks-destroy --yes` and `prodbox pulumi test-destroy --yes`
   calls in Pulumi-backed integration tests.
3. Aggregate-suite postflight destroy via `prodbox test all`.

If setup fails before the fixture yields, the helper must roll back every resource it created in
that attempt before surfacing the error.

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited.

If fixture-owned Route 53 cleanup or Pulumi-owned stack destroy fails, the suite must abort with
explicit target and error text because later AWS tests can no longer assume a clean baseline state.

---

## 6. Required Command Surfaces

### 6.1 Common Auth Probe

All AWS-mutating suites depend on:

1. `aws sts get-caller-identity`

### 6.2 Route 53 Fixture Commands

Route 53 fixture ownership relies on the canonical AWS CLI command set:

1. `aws route53 create-hosted-zone`
2. `aws route53 change-resource-record-sets`
3. `aws route53 get-change`
4. `aws route53 list-resource-record-sets`
5. `aws route53 get-hosted-zone`
6. `aws route53 delete-hosted-zone`

### 6.3 Pulumi-Owned AWS Test Stack Surfaces

The Pulumi-managed AWS test stacks rely on the canonical `prodbox` command surface:

1. `prodbox rke2 install`
2. `prodbox pulumi eks-resources`
3. `prodbox test integration aws-eks`
4. `prodbox pulumi eks-destroy --yes`
5. `prodbox pulumi test-resources`
6. `prodbox test integration pulumi`
7. `prodbox test integration ha-rke2-aws`
8. `prodbox pulumi test-destroy --yes`
9. `prodbox rke2 delete --yes`

---

## 7. Route 53 Fixture Contract

For Route 53-backed AWS tests, the fixture contract is:

1. Create a fresh hosted zone with a unique name.
2. Point the test environment at that hosted zone only.
3. Delete any fixture-owned record sets before deleting the hosted zone.
4. Delete the hosted zone in teardown.
5. Prove `prodbox` behavior only against the fixture-owned hosted zone.

This applies both to direct DNS tests and to any future AWS test that needs an isolated Route 53
zone outside the Pulumi-owned HA stack.

---

## 8. Pulumi-Owned AWS Test Stack Contract

For `aws-eks`, `pulumi`, and `ha-rke2-aws`, the lifecycle contract is:

1. `prodbox rke2 install` must reconcile the local RKE2 cluster, MinIO service, and the dedicated
   bucket `prodbox-test-pulumi-backends` before remote AWS provisioning starts.
2. `prodbox pulumi eks-resources` must be able to create or inspect exactly one canonical AWS EKS
   stack composed of an ephemeral EKS cluster, a managed node group, VPC networking, and the IAM
   resources required by that stack.
3. `prodbox test integration aws-eks` validates the EKS stack snapshot, node readiness, and
   command surface.
4. `prodbox pulumi eks-destroy --yes` must destroy the same EKS stack cleanly.
5. `prodbox pulumi test-resources` must be able to create or inspect exactly one canonical AWS HA
   stack composed of three Ubuntu 24.04 EC2 instances in separate availability zones plus the VPC,
   subnet, security-group, IAM, and Route 53 resources required by that stack.
6. `prodbox test integration pulumi` validates the HA stack snapshot and command surface.
7. `prodbox test integration ha-rke2-aws` validates SSH-driven HA RKE2 bootstrap against the same
   Pulumi-managed stack.
8. `prodbox pulumi test-destroy --yes` must destroy the same HA stack cleanly.
9. `prodbox rke2 delete --yes` must invoke both destroy semantics automatically before local
   backend teardown.

No tag-based preflight sweep, janitor CLI, or standalone AWS audit helper is part of the supported
cleanup model for this stack.

---

## 9. Relationship To Other Doctrine

1. General unit vs integration policy and fail-fast expectations are defined in
   [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests).
2. Cluster-backed fixture ownership is defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).
3. The explicit `prodbox test integration ...` and `prodbox pulumi ...` surfaces are defined in
   [CLI Command Surface](./cli_command_surface.md).
4. General shared-account AWS test environment design is defined in
   [AWS Test Environment](./aws_test_environment.md).

---

## 10. Leak Prevention

The supported architecture prevents leaked AWS residue with explicit ownership rather than
background sweeps:

1. Route 53 suites use fixture-owned setup rollback and teardown.
2. Pulumi-backed suites use explicit destroy before and after validation when needed.
3. Aggregate postflight for `prodbox test all` ends with `prodbox pulumi eks-destroy --yes` and
   `prodbox pulumi test-destroy --yes`.
4. `prodbox rke2 delete --yes` invokes the same destroy paths before local backend teardown.

No session-scoped sweep, standalone `prodbox aws ...` janitor surface, host cron job, or
`aws_fixture_audit.py`-style final audit helper is part of the supported cleanup model.

---

## Cross-References

- [AWS Admin Credentials](./aws_admin_credentials.md)
- [AWS Account Setup Guide](./aws_account_setup_guide.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [CLI Command Surface](./cli_command_surface.md)
- [AWS Test Environment](./aws_test_environment.md)
- [Documentation Standards](../documentation_standards.md)
