# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, README.md, documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_test_environment.md, AGENTS.md

> **Purpose**: Define how `prodbox` authenticates to AWS for integration work and how the
> supported AWS validation path creates, owns, and tears down real AWS resources.

## 0. Canonical Doctrine Statements

- `prodbox` AWS authentication material must be stored only in the repository-root
  `prodbox-config.dhall` and decoded directly into Haskell settings.
- `prodbox` must not search upward from the current working directory or prefer alternate config
  files.
- Public `prodbox config setup` and public `prodbox aws ...` flows obtain temporary elevated AWS
  credentials from interactive prompts; they must not rely on config-backed
  `aws_admin_for_test_simulation.*`.
- `aws_admin_for_test_simulation.*` is the single stored-admin-credential exception and exists
  only for test-suite simulation of that ephemeral prompt input; the native `aws-iam` validation
  harness is the only supported runtime consumer.
- `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`
  share one suite-level IAM harness that provisions operational `aws.*` before prerequisite-driven
  AWS validation begins and clears those credentials again before the suite returns.
- Stateful AWS validation uses explicit credentials rebuilt from decoded settings, not ambient host
  AWS CLI state or shared profile discovery.
- Existing AWS resources are never valid mutation targets for supported `prodbox` integration
  validations.
- The local `prodbox` RKE2 cluster and its MinIO service must exist before any remote AWS test
  stack is created because Pulumi state for those stacks lives only in
  `prodbox-test-pulumi-backends`.

## 0A. Planning Ownership

This document owns AWS integration doctrine only.

Clean-room sequencing, completion status, remaining work, and cleanup ownership for AWS validation
are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. Scope

This doctrine applies to any supported `prodbox` validation flow that creates, updates, or deletes
real AWS state, including:

1. `prodbox test integration dns-aws`
2. `prodbox test integration aws-eks`
3. `prodbox test integration pulumi`
4. `prodbox test integration ha-rke2-aws`
5. `prodbox test integration public-dns`
6. `prodbox test integration aws-iam`
7. The supporting `prodbox pulumi ...` and `prodbox aws ...` command surfaces those validations
   rely on, plus the credential-boundary rules those validations depend on

The public `prodbox config setup` and `prodbox aws ...` surfaces route through the native Haskell
frontend and explicit AWS CLI subprocess environments, but only the native IAM validation harness
may consume stored `aws_admin_for_test_simulation.*` at runtime.

## 2. Authentication Source And Storage Rules

### 2.1 Dhall Configuration Ownership

AWS authentication material for `prodbox` must live only in the repository-root
`prodbox-config.dhall`.

Required operational config fields:

1. `aws.access_key_id`
2. `aws.secret_access_key`
3. `aws.region`

Optional operational config field:

1. `aws.session_token`

Optional elevated validation fields:

1. `aws_admin_for_test_simulation.access_key_id`
2. `aws_admin_for_test_simulation.secret_access_key`
3. `aws_admin_for_test_simulation.session_token`
4. `aws_admin_for_test_simulation.region`

Stored admin credentials are otherwise forbidden. `aws_admin_for_test_simulation.*` is the one
supported exception, and it is reserved for `prodbox test integration aws-iam`,
aggregate-harness execution of that suite, and repository tests that simulate the interactive
elevated-credential prompt.

Public `prodbox config setup` and public `prodbox aws ...` commands must not consume
`aws_admin_for_test_simulation.*` from config on the supported path; they prompt for temporary
elevated credentials when needed.

Supported non-interactive validation consumes `aws_admin_for_test_simulation.*` directly; missing
elevated credentials must fail fast with an actionable config error rather than falling back to
ambient AWS auth.

Forbidden storage patterns:

1. Repo-local shell snippets exporting AWS secrets
2. Checked-in example files containing real AWS auth data
3. Temporary credential dumps written into project directories outside the Dhall config
4. Reliance on `~/.aws` shared config or cache as the auth source for supported `prodbox` flows
5. `.env` files for AWS credentials

### 2.2 No Ambient Or Profile-Based AWS Auth

The system-installed `aws` CLI may be used by validations, but only with subprocess auth rebuilt
from decoded settings.

Forbidden behavior:

1. Interactive `aws configure` or similar login repair as part of validation
2. Alternate repo-local credential files for convenience
3. Exporting ambient AWS auth env vars before invoking supported `prodbox` validation flows
4. Shared-profile or cached host state as the supported auth source

### 2.3 Disallowed Ambient AWS Auth Variables

The following variables are forbidden as ambient auth sources:

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

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating validation runs, the harness must prove:

1. the system `aws` CLI exists when direct AWS CLI operations are required
2. decoded settings define usable AWS authentication for the identity the validation will run under
3. that identity can perform the lifecycle the validation owns
4. for `aws-iam`, the native IAM harness config is complete enough to materialize operational
   `aws.*` from `aws_admin_for_test_simulation.*` without falling back to pre-existing
   operational credentials

### 3.2 Required Check Semantics

The required checks map to:

1. tool check: `aws` must be invokable
2. config auth check: `aws sts get-caller-identity` must succeed with subprocess auth rebuilt from
   decoded settings
3. lifecycle-capability check:
   Route 53 validations must be able to create and fully own a fresh hosted-zone lifecycle;
   Pulumi-backed validations must be able to drive the canonical `prodbox pulumi` command surface
4. native IAM harness check: `aws-iam` must fail before its validation body when
   `aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise incomplete
   harness config

### 3.3 No In-Harness Login

The harness must fail fast when any required check is missing.

It must not:

1. open a browser login flow
2. prompt for interactive AWS configuration
3. attempt to repair missing host authentication automatically

### 3.4 Route 53 Capability Proof Rule

For `dns-aws`, permission sufficiency is proven only when the validation can create and fully own a
fresh hosted-zone lifecycle using the canonical Route 53 command set.

### 3.5 Pulumi-Backed Stack Capability Proof Rule

For `aws-eks`, `pulumi`, and `ha-rke2-aws`, permission sufficiency is proven only when the local
host can reach its RKE2-backed MinIO backend and the relevant named `prodbox pulumi` surface can
select, inspect, or create the canonical AWS test stack using settings-defined AWS auth.

The supported path synchronizes only non-secret validation inputs such as operator-CIDR and
SSH-public-key into the stack with `pulumi config set`. AWS provider credentials must remain in
repository-root `prodbox-config.dhall` and be projected into Pulumi through the Haskell-owned
subprocess environment, not copied into stack-local config files.

The prerequisite proof for that backend is a bounded `pulumi login ... --non-interactive` against
the repo-backed MinIO backend after the Haskell helper confirms bucket existence and listability.
If the running MinIO pod still points at a deleted retained host-path mount, the helper recreates
the declared host path, reapplies the ownership and mode contract, restarts `deployment/minio`,
and then reruns the login proof before stack operations continue.

On aggregate or cluster-backed suite paths, the public test runner may satisfy the local backend
contract by running the visible `prodbox rke2 reconcile` phase before it executes the deferred
`pulumi_logged_in` prerequisite proof. The local-cluster-first rule still holds: remote AWS stack
creation does not begin until that post-runbook backend proof succeeds.

## 4. Environment Creation Rules

### 4.1 Brand-New Resources Only

Supported AWS validations must create new resources for the current run. They must not:

1. reuse a long-lived hosted zone
2. reuse a pre-existing VPC, EC2 instance, security group, or IAM role
3. mutate records or resources that predate the owning validation

### 4.2 Route 53 Validation-Owned Resources

`dns-aws` may create only the fresh hosted zone and record-set lifecycle it owns directly.

Minimum rule:

1. one validation run creates one isolated hosted-zone context
2. validation logic operates only on that run-owned identifier set
3. cleanup deletes the same identifiers before returning

### 4.3 Pulumi-Owned AWS Test Stacks

`aws-eks`, `pulumi`, and `ha-rke2-aws` must not open-code AWS resource creation outside the
canonical Pulumi stack flows.

Minimum rule:

1. `prodbox rke2 reconcile` creates or reconciles the local backend cluster first
2. `prodbox pulumi eks-resources` is the only supported surface for creating or inspecting the AWS
   EKS test stack
3. `prodbox pulumi eks-destroy --yes` is the only supported surface for destroying that stack
4. `prodbox pulumi test-resources` is the only supported surface for creating or inspecting the AWS
   HA stack
5. `prodbox pulumi test-destroy --yes` is the only supported surface for destroying that stack
6. `prodbox rke2 delete --yes` must invoke both destroy paths before backend teardown
7. the AWS validation Pulumi programs take non-secret operator-CIDR and SSH-public-key inputs
   through explicit stack config synchronized by the Haskell orchestration layer, while AWS
   provider credentials stay in the Haskell-owned subprocess environment

### 4.4 Test-Only Elevated IAM Harness

The IAM lifecycle validation uses the same repository-root Dhall configuration file but a separate
credential section:

1. `aws.*` remains the normal operational identity
2. `aws_admin_for_test_simulation.*` is the stored simulation of the ephemeral elevated identity
   used only by `prodbox test integration aws-iam`, `prodbox test integration all`, and
   `prodbox test all`
3. the validation must fail fast when `aws_admin_for_test_simulation.*` is missing or partial
4. public `prodbox config setup` and public `prodbox aws ...` commands remain outside this
   config-backed test harness and use interactive temporary elevated credentials instead

## 5. Ownership And Cleanup

### 5.1 Route 53 Validation Owns Setup And Teardown

The `dns-aws` validation, not ambient machine state, creates the Route 53 environment and cleans it
up again.

### 5.2 Pulumi Owns Multi-Resource Stack Lifecycles

The same public CLI surfaces used by operators own the AWS test-stack lifecycles during validation:

1. `prodbox pulumi eks-resources`
2. `prodbox pulumi eks-destroy --yes`
3. `prodbox pulumi test-resources`
4. `prodbox pulumi test-destroy --yes`
5. `prodbox rke2 delete --yes` as the final automatic destroy path before backend teardown

### 5.3 Cleanup Must Run After Validation Failure

Cleanup must still run when a validation fails part-way through.

Required patterns:

1. Route 53 lifecycle code attempts teardown after mid-validation failure when safe
2. Pulumi-backed validations use the public destroy surfaces
3. Aggregate-suite postflight repair is owned by `prodbox test all`
4. The shared IAM harness still attempts teardown and `aws.*` clearing when prerequisite
   validation fails after harness setup has already materialized operational credentials

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited.

If validation-owned Route 53 cleanup or Pulumi-owned stack destroy fails, the suite must abort with
explicit target and error text.

## 6. Required Command Surfaces

### 6.1 Common Auth Probe

All AWS-mutating validations depend on:

1. `aws sts get-caller-identity`

### 6.2 Route 53 Validation Commands

Route 53 lifecycle validation uses the canonical AWS CLI command family:

1. `aws route53 create-hosted-zone`
2. `aws route53 change-resource-record-sets`
3. `aws route53 wait resource-record-sets-changed`
4. `aws route53 list-resource-record-sets`
5. `aws route53 delete-hosted-zone`

### 6.3 Pulumi Validation Commands

Pulumi-backed validations depend on:

1. `prodbox pulumi eks-resources`
2. `prodbox pulumi eks-destroy --yes`
3. `prodbox pulumi test-resources`
4. `prodbox pulumi test-destroy --yes`

## Cross-References

- [AWS Admin Credentials](./aws_admin_credentials.md)
- [AWS Test Environment](./aws_test_environment.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
