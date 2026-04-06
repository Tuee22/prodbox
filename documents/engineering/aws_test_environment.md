# AWS Test Environment

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN.md, documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md

> **Purpose**: Define the canonical shared AWS account, DNS, isolation, lifecycle, and authentication model for ephemeral multi-project testing.

---

## 0. Canonical Doctrine Statements

Stateful AWS testing across projects must use a dedicated AWS Organizations member account reserved for testing, not a production, staging, or personal account.

The shared AWS test account may host concurrent ephemeral environments for multiple projects, but persistent workload state is limited to the permanent test domain and its parent hosted zone.

Administrative baseline state such as IAM Identity Center assignments, SCPs, budgets, logging, and optional janitor automation is intentionally long-lived and is not considered project workload state.

Each project test run must own its own AWS resource set, including DNS namespace, network boundary, storage, and compute resources, and must delete that resource set in teardown.

No test may mutate, depend on, or clean up resources that were created by a different project or a different test run.

Human and automation access must use temporary credentials. Long-lived IAM user access keys are prohibited for normal testing workflows.

Within one AWS account, resource ownership can be isolated, but account-level quotas and some service-wide control-plane limits remain shared. Workloads that require hard blast-radius isolation must use separate AWS accounts.

---

## 1. Scope

This doctrine applies to any shared AWS test environment that is intended to host ephemeral spin-up/tear-down tests for multiple projects at the same time.

Expected service coverage includes at least:

1. Amazon S3
2. Amazon EC2 and VPC
3. Amazon EKS
4. Amazon Route 53

Other AWS services may be used in the same shared test account only when they can follow the same ownership, tagging, cleanup, and safety requirements defined here.

This document owns the general AWS test-account model, DNS namespace strategy, cross-project isolation rules, and authentication posture.

Project-specific harness rules remain owned by project documents. For `prodbox`, the repository-`.env` CLI/test-harness doctrine is defined in [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md).

---

## 2. Shared Account Strategy

### 2.1 Dedicated Member Account

The recommended topology is:

1. One existing AWS account remains the AWS Organizations management account.
2. One new AWS Organizations member account is created specifically for shared ephemeral testing.
3. That member account is placed in a dedicated testing OU with guardrail SCPs attached.

This shared test account is the only account in scope for project test workloads.

Production, staging, sandbox, and personal experimentation must not share this account.

### 2.2 Why A Shared Test Account Exists

The shared account exists to make ephemeral integration and end-to-end testing inexpensive and operationally simple:

1. one billing boundary
2. one set of guardrails
3. one shared DNS parent domain
4. one place to monitor cost, quotas, and cleanup health

### 2.3 Isolation Limit Statement

Resource ownership can be isolated inside one account, but some limits remain shared:

1. service quotas
2. account-wide API throttles
3. global naming namespaces such as S3 bucket names
4. service-linked roles and some service-wide control-plane settings

Therefore:

1. the shared account is acceptable for ephemeral test workloads
2. the shared account is not equivalent to account-per-project blast-radius isolation
3. a project that needs hard quota isolation, legal isolation, or privileged control-plane testing must receive a dedicated AWS account instead

---

## 3. Account Creation And Baseline

### 3.1 Create The Account

Create the shared test account as a member account in AWS Organizations.

Required properties:

1. unique account email address
2. explicit account name such as `shared-aws-test`
3. placement in a dedicated testing OU
4. management by the organization management account, not as a standalone account

### 3.2 Baseline Guardrails

Attach baseline guardrails to the testing OU or directly to the account.

Minimum recommended guardrail categories:

1. deny account-management and organizations changes from normal project roles
2. deny billing mutation from normal project roles
3. deny domain-registration mutation after the permanent test domain is established
4. deny mutation of the permanent parent hosted zone except through the approved delegation workflow
5. optionally deny use outside approved AWS Regions to control cost and sprawl
6. optionally deny creation of IAM users and long-lived access keys

Broad use of workload services is acceptable in this account, including S3, EC2, EKS, Route 53, and other application services, but the persistent account baseline must stay protected.

### 3.3 Long-Lived Baseline Resources

The only long-lived workload resources should be:

1. the reserved test domain registration
2. the permanent public hosted zone for that parent domain

Long-lived administrative baseline resources may also exist by design:

1. IAM Identity Center assignments and permission sets
2. SCPs and tag policies
3. budgets and billing alarms
4. CloudTrail, Config, and logging baselines if enabled
5. optional janitor automation that deletes expired test resources
6. AWS-managed service-linked roles that are created the first time a supported shared-account service such as EKS is enabled

No long-lived VPCs, EKS clusters, EC2 instances, S3 buckets, child hosted zones, or project-owned databases are allowed in the shared test account.

### 3.4 Root Credential Policy

The management account root user remains a management-account concern and must be protected with MFA and used only for tasks that require root access.

For the shared test member account:

1. create it as an Organizations member account
2. bootstrap its baseline from the management account
3. enable centralized root access management
4. remove or avoid member-account root credentials after bootstrap

The shared test account root user must not be used for daily operations.

### 3.5 Quota Bootstrap

The shared test account does not inherit raised service quotas from any existing AWS account.

Operational rule:

1. create the member account
2. assume it starts with AWS default service quotas
3. apply AWS Organizations Service Quotas templates where supported
4. request account-specific quota increases in the shared test account before projects depend on them

The quota bootstrap must be performed before the account is opened for normal project testing.

### 3.6 Minimum Quota Bootstrap Checklist

The following quotas must be reviewed explicitly for the shared test account because they commonly constrain ephemeral concurrent testing.

#### VPC / EC2

Review and raise as needed:

1. VPCs per Region
2. subnets per VPC
3. internet gateways per Region
4. NAT gateways per Availability Zone or Region, depending on the architecture used by the projects
5. elastic IP addresses per Region
6. running On-Demand EC2 instance capacity and vCPU-based quotas for the instance families the projects use
7. security groups per Region and per network interface where high concurrency is expected

#### EKS

Review and raise as needed:

1. EKS clusters per Region
2. managed node groups per cluster
3. Fargate profiles per cluster if Fargate-backed tests are expected
4. associated elastic load balancer quotas used by EKS services and ingress paths

#### Route 53

Review and raise as needed:

1. hosted zones per account
2. record-set scale expectations for delegated child zones
3. health checks per account if health-check-based tests are expected

#### S3

Review and raise as needed:

1. general purpose buckets per account
2. any account-level quota that could constrain concurrent bucket-per-run isolation

#### Supporting Shared Services

Review and raise as needed for the supporting architecture actually used in the account:

1. application or network load balancers
2. target groups
3. IAM roles, if projects create many short-lived roles
4. CloudWatch log groups or other observability resources when tests create them per run

### 3.7 Quota Planning Rule

Quota bootstrap must be sized to expected concurrency, not only to one happy-path test run.

Minimum planning inputs:

1. number of projects expected to run in parallel
2. worst-case concurrent test runs per project
3. maximum AWS footprint per run, including VPC, EKS, EC2, load balancer, Route 53, and S3 resources
4. cleanup lag tolerance when failed runs leak resources temporarily

The platform owner must maintain a documented concurrency budget for the shared account and revise quotas before projects begin to saturate them.

---

## 4. Authentication Model

### 4.1 Human Access

Human access must use AWS IAM Identity Center with workforce identities and MFA.

Required pattern:

1. users authenticate to IAM Identity Center
2. IAM Identity Center grants access to permission sets in the shared test account
3. CLI access uses `aws configure sso` and temporary cached credentials
4. users do not store long-lived IAM access keys for normal work

### 4.2 Human Permission Sets

Define at least three human access levels:

1. `AwsTestEnvironmentAdmin`
2. `AwsTestEnvironmentProjectOperator`
3. `AwsTestEnvironmentReadOnly`

Expected responsibilities:

1. `AwsTestEnvironmentAdmin` manages the shared account baseline, DNS parent domain, guardrails, quotas, and emergency cleanup.
2. `AwsTestEnvironmentProjectOperator` can create and destroy ephemeral test resources for assigned projects inside the shared account.
3. `AwsTestEnvironmentReadOnly` can inspect resources, logs, and cost data without mutation authority.

### 4.3 Automation Access

Automation outside AWS must use temporary credentials through federation, not long-lived IAM user keys.

Preferred patterns:

1. OIDC or other federated CI-to-AWS role assumption
2. STS `AssumeRole` from an approved runner identity

Forbidden by default:

1. shared IAM users for CI
2. long-lived access keys stored in repositories
3. plaintext credentials in `.env` files, CI variables, or project trees when federation is available

### 4.4 In-Account Workload Access

Workloads running in the shared test account must use roles, not embedded credentials:

1. EC2 uses instance profiles
2. EKS uses IRSA or EKS Pod Identity
3. Lambda and other managed services use their execution roles

### 4.5 Permission Boundaries And Guardrails

Project automation roles may be broad within the shared test account, but they must still be bounded.

Minimum expectations:

1. identity-based policy grants only the service access that project tests require
2. permissions boundaries cap the maximum permissions for project-created roles when delegated IAM creation is necessary
3. SCPs enforce account-wide guardrails that project roles cannot bypass
4. roles that touch shared baseline resources are separate from normal project test roles

### 4.6 Break-Glass Access

Break-glass access must be rare, audited, and separate from daily operations.

Minimum break-glass rules:

1. management-account administrators hold the break-glass path
2. break-glass is used only for account recovery or baseline repair
3. root access keys are never created for either the management account or the shared test account

---

## 5. DNS And Domain Model

### 5.1 Permanent Parent Domain

Reserve one low-cost public domain specifically for testing. It does not need to be memorable.

Examples of acceptable naming intent:

1. random or low-significance label
2. no production branding requirement
3. no reuse for production, staging, or corporate email

The permanent parent domain and its parent hosted zone are the only long-lived workload DNS assets.

### 5.2 Permanent Parent Hosted Zone

Create one permanent Route 53 public hosted zone for the reserved domain.

Rules:

1. the parent zone contains only durable baseline records and short-lived delegation records
2. production records must never exist in this zone
3. normal project test roles must not have unrestricted write access to this zone

### 5.3 Ephemeral Child Subdomains

Every project test run receives its own unique subdomain under the permanent parent domain.

Preferred naming shape:

`<run-id>.<project>.<test-domain>`

Example:

`r-20260323-4f7c.orders.t-9f3a.net`

The preferred implementation is a delegated child hosted zone per run:

1. create a child hosted zone for the run subdomain
2. add temporary NS delegation records in the permanent parent zone
3. grant the run full control over the child zone only
4. delete the child zone and its parent delegation records during teardown

This design gives each run its own DNS authority boundary and avoids cross-project mutation in a shared parent zone.

### 5.4 Parent-Zone Mutation Model

The permanent parent zone is shared state, so it must be protected.

Preferred model:

1. a platform-owned admin role or allocator workflow creates the child zone and parent NS delegation
2. the project test role receives authority over the child zone only
3. the project test role does not receive unrestricted parent-zone edit access

If a simpler model is used temporarily, parent-zone writes must still be constrained to the project's own namespace and reviewed as an explicit exception.

### 5.5 DNS Cleanup Contract

For each run:

1. delete all records in the child zone
2. remove the NS delegation from the parent zone
3. delete the child zone itself
4. verify that no residual records remain under that run subdomain

The permanent parent domain and parent hosted zone remain.

---

## 6. Cross-Project Isolation Contract

### 6.1 Required Ownership Metadata

Every ephemeral resource must carry a standard ownership tag set as early as the service allows.

Minimum required tags:

| Tag Key | Purpose |
|---------|---------|
| `environment` | Fixed value such as `aws-test` |
| `project` | Stable project slug |
| `repository` | Source repository or system name |
| `test_run_id` | Unique run identifier |
| `owner` | Team, service, or CI identity |
| `managed_by` | Tool or framework creating the resource |
| `expires_at` | UTC expiration timestamp |
| `safe_to_delete` | Fixed value `true` for ephemeral resources |
| `data_class` | Fixed value such as `ephemeral-test` |

Tags must not contain secrets or sensitive data.

### 6.2 Naming Rules

Human-readable names must embed project and run ownership.

Preferred shape:

`<project>-<run-id>-<purpose>`

Examples:

1. `orders-r20260323a-vpc`
2. `orders-r20260323a-eks`
3. `orders-r20260323a-artifacts`

### 6.3 Network Isolation

Each test run that needs networking must create its own VPC and supporting network resources.

Rules:

1. no project shares a VPC with another project's test run
2. no test uses the account default VPC
3. route tables, subnets, security groups, NAT gateways, internet gateways, and elastic IPs are run-owned resources
4. VPC peering, transit connectivity, or shared subnets between projects are forbidden by default

### 6.4 S3 Isolation

The default isolation unit for S3 is a bucket per run.

Preferred rules:

1. create a unique bucket per run when practical
2. delete all objects and delete the bucket in teardown
3. if a shared bucket is unavoidable, isolate by project-specific prefix and explicit bucket policy, and treat this as an exception, not the default

### 6.5 EC2 And EKS Isolation

The default isolation unit for EC2 and EKS is the run-owned VPC plus run-owned compute resources.

Rules:

1. EC2 instances live only inside a run-owned VPC
2. EKS clusters are ephemeral and belong to a single project run
3. shared long-lived EKS clusters for unrelated projects are not considered full isolation and are forbidden for this shared-account doctrine

### 6.6 Service-Specific Isolation Table

| Service | Required Isolation Unit | Persistent Allowed | Required Teardown |
|---------|-------------------------|--------------------|-------------------|
| Route 53 | Delegated child zone per run | Parent domain and parent hosted zone only | Delete records, remove delegation, delete child zone |
| S3 | Bucket per run | None | Empty and delete bucket |
| VPC / EC2 | VPC per run | None | Delete instances, ENIs, gateways, route tables, subnets, security groups, VPC |
| EKS | Cluster per run | None | Delete workloads, node groups, load balancers, cluster, VPC dependencies |
| Other services | Project/run-owned namespace | None by default | Delete all fixture-owned resources before teardown returns |

### 6.7 Isolation Boundary Failure Criteria

An environment is not compliant with this doctrine if any of the following are true:

1. a project can delete or mutate another project's resources
2. two projects share a VPC, bucket, cluster, or child DNS zone without an explicit exception
3. teardown intentionally leaves project workload resources behind
4. persistent project infrastructure accumulates in the shared account

---

## 7. Resource Lifecycle Contract

### 7.1 Setup Sequence

Each run must:

1. allocate a unique `test_run_id`
2. create the run-owned DNS child zone and delegation
3. create the run-owned VPC and all required service resources
4. apply required tags and names immediately
5. execute the test workload

### 7.2 Teardown Sequence

Each run must destroy resources in reverse dependency order.

Typical order:

1. application workloads
2. load balancers and service endpoints
3. EKS control plane and node groups
4. EC2 instances and attached storage
5. S3 objects and buckets
6. DNS records and child zone
7. subnets, gateways, route tables, security groups, and VPC

### 7.3 Cleanup Must Be Attempted On Failure

Test failure does not justify leaving resources behind.

Required behavior:

1. cleanup runs in `finally` or equivalent teardown logic
2. cleanup attempts every owned resource even after partial failures
3. cleanup reports explicit failures with enough information to repair them safely

### 7.4 Expiry And Janitor Model

Every run-owned resource must carry an `expires_at` tag.

The shared environment should also operate an independent janitor process that:

1. scans for expired `aws-test` resources
2. groups them by `project` and `test_run_id`
3. deletes leaked resources that are marked `safe_to_delete=true`

Janitor automation is a baseline administrative control, not project workload state.

---

## 8. Operational Guardrails

### 8.1 Cost Guardrails

The shared account must be cheap to operate and safe to use continuously.

Minimum controls:

1. account budget alarms
2. activated cost allocation tags for `project`, `test_run_id`, and `environment`
3. clear region policy to avoid accidental multi-region sprawl

### 8.2 Quota Guardrails

Because the account is shared, quota exhaustion can create cross-project interference.

Required practices:

1. define concurrency limits per project or per service
2. monitor quotas that commonly constrain ephemeral tests, such as VPCs, elastic IPs, NAT gateways, load balancers, hosted zones, and EKS clusters
3. move a project to its own account if it regularly pressures shared-account quotas

Quota monitoring must be anchored to the bootstrap expectations defined in [Quota Bootstrap](#35-quota-bootstrap) and [Minimum Quota Bootstrap Checklist](#36-minimum-quota-bootstrap-checklist).

### 8.3 Shared-Account Escalation Rule

A project must move to a dedicated AWS account when any of the following become true:

1. the project requires account-admin or organization-admin actions during normal tests
2. the project requires hard quota isolation
3. the project creates long-lived baseline resources that conflict with the shared-account model
4. the project cannot be constrained to its own project and run namespace

---

## 9. Relationship To Project-Specific Doctrine

This document defines the general shared AWS environment model for testing across projects.

Project-specific documents may add stricter rules for their own harnesses, CLI tooling, credential sources, or cleanup semantics.

For `prodbox`:

1. host-side AWS CLI credential-source restrictions and fixture behavior are defined in [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
2. general pytest fixture ownership is defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
3. unit vs integration execution policy is defined in [Unit Testing Policy](./unit_testing_policy.md#2-unit-vs-integration-tests)

---

## 10. External References

Official AWS documentation that informs this doctrine:

1. AWS Organizations account creation: <https://docs.aws.amazon.com/cli/latest/reference/organizations/create-account.html>
2. Accessing member accounts in an organization: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_access.html>
3. Service control policies: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html>
4. Tag policies: <https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_tag-policies.html>
5. Root user best practices: <https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html>
6. Centralized root access management for member accounts: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-enable-root-access.html>
7. IAM security best practices: <https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html>
8. IAM users and long-term credential guidance: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users.html>
9. IAM Identity Center for AWS CLI: <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html>
10. SDK and tool guidance for temporary credentials: <https://docs.aws.amazon.com/sdkref/latest/guide/access-users.html>
11. Permissions boundaries: <https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html>
12. User-defined cost allocation tags: <https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/custom-tags.html>
13. AWS Service Quotas templates: <https://docs.aws.amazon.com/servicequotas/latest/userguide/organization-templates.html>
14. AWS Service Quotas reference and defaults: <https://docs.aws.amazon.com/servicequotas/latest/userguide/reference_limits.html>

---

## Cross-References

- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Engineering docs index](./README.md)
- [Documentation Standards](../documentation_standards.md)
