# AWS Resource Ownership and Operations

**Status**: Authoritative source
**Supersedes**: Pre-refactor AWS environment/substrate lifecycle doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; no provider adapter is changed by this document

> **Purpose**: Define complete deployment-owned AWS inventory, exact mutation scope, and independent cleanup evidence.

## Ownership boundary

All supported mutations are prodbox operations admitted by the retained local kind Authority and executed by registered workers. Tests use the same path. No ambient auth or host-direct AWS/Pulumi/eksctl/terraform mutation is a fallback when the Authority is unavailable.

The externally owned account, domain, parent hosted zone, initial elevated credential and unrelated account resources are onboarding prerequisites. Managed records within a parent zone remain deployment-owned. Exact confirmed adoption can add legacy resources; discovery alone does not grant ownership or deletion permission.

Bind environment, deployment/run, account, regions and exact resource coordinates before effects. Tags reinforce identity, including managed-by/run/operation roles, but cannot turn unknown resources into owned resources. For untaggable families, use exact registered names and service observations. Name collisions refuse or require explicit adoption.

## Required resource families

| Family | Introduced/managed dependencies and closing observation |
|---|---|
| Credential IAM | Users/roles/policies/keys/session capability; read back exact family and Vault generation retirement |
| Storage-canary/S3 family | New exact `storage-canary` identity for cheap buckets/versions/multipart lifecycle; never reinterpret the old `aws-test` three-EC2 identity as S3 |
| DNS/subzones | Exact records/delegation, child zones and validation zones; preserve external parent zone and unrelated records |
| SES/email | Sending/DKIM identities, receiving identities/rules, capture data/bucket and SMTP IAM; exact provider plus IAM absence |
| EKS/compute | Cluster, managed node groups/profiles, related IAM/OIDC, instances/launch artifacts; exact target identity and independent absence |
| VPC/controller network | Declared load balancers/listeners/targets, CNI ENIs/security groups, NAT/EIP/endpoints, routes/subnets/IGW/VPC families |
| Static EBS | Test and production-owned volumes/snapshots declared before creation; exact absence despite former retention class |
| Backup/TLS/state | Deployment-owned objects/versions/buckets and scoped IAM; local terminal reporting survives remote-store removal |
| Historical supported residue | ECR/logging/legacy exact families identified by the inventory; explicit owner/adoption/removal, never an unbounded account sweep |

The resource catalog enumerates the actual supported field and family dependencies. Adding a new family requires complete create/observe/recover/delete behavior in the same phase. A class called LongLived controls routine reuse only; it never silently exempts an owned resource from explicit deployment deletion.

The legacy `aws-test` HA-RKE2 creation surface is retired. Its exact original resources retain migration-only observation/delete/adoption until cleanup/import resolves them; its identity cannot be reassigned to the Phase 5 storage canary. Preserve gateway HA behavior on kind/EKS through the Phase 9 assertions.

## Provider effects and completion

Register intent/cleanup before any effect, including first IAM bootstrap and activation of a Kubernetes controller that can create AWS children. Capture deterministic ownership/name/family coordinates before enabling an owner; enrich with provider/UID identities after read-back. Keep partial-create and lost-response cases recoverable without a usable checkpoint.

Use exact EKS presence to select drain. Drain owners while controllers are available, then attempt eligible independent provider backstops even after an unavailable drain. Requester-managed interfaces are observed until their owner releases them, not force-deleted outside the closed predicate. Blocked dependencies retain evidence and recovery capability.

S3 deletion includes all owned versions/delete markers and incomplete multipart uploads. IAM deletion resolves policy attachments/profile dependencies and nondefault policy versions as required. Preserve the elevated bootstrap principal and externally managed AWS policies. Provider-specific details are code-owned adapters with bounded retry/read-back, not operator manual recipes.

A service-specific inventory over the predeclared field, answered queries and required positive controls proves that field only. Tag sweeps detect escapees but do not prove exact stack absence. Access denial, wrong account/region, throttling and a blind observer remain unobservable, never clean.

## SES and receiving isolation

Production and each test campaign use separate sender/receive identities, SMTP principals/material, capture buckets/data prefixes, DNS records and exact receipt rules. They may share the external parent account/domain only under explicit scopes. Campaign cases may reuse campaign-owned email resources; campaign delete removes them. There is no implicit production SES reuse or ordinary-delete exemption.

SES has one active receipt-rule-set container per account/region. If using a dedicated receiving-test account, validate that explicit configuration. In a shared account, declare a coordinated container owner before either environment uses it; add/remove only exact owned recipient rules and preserve production's rules and activation. Never deactivate/swap a production set for a test. If safe coexistence cannot be established, return the specific conflict before mutation. A shared container is deleted only by its declared owner after all registered consumers are gone.

Verification/DNS propagation and bucket reuse costs justify campaign reuse, not hiding SES from an explicit delete. Real integration proves production/test receiving isolation, activation safety and complete owned-rule/data/identity cleanup.

## Quotas, spend and operational evidence

Validate required regional quotas, explicit instance/storage shapes and cost budgets before creation. Operator quota requests use registered bounded admin operations. Ration real AWS attempts under the development standards; bank each failure as an offline regression and a real canary, not an excuse to repeat until green.

Manual authorized recovery is recorded as a hand action and cannot qualify a lifecycle run. A prior account inventory or manual clean slate does not establish the replacement's create/delete correctness. [Testing](testing.md) owns evidence, negative controls and mutation gates.
