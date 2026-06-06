# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md

> **Purpose**: Define how `prodbox` authenticates to AWS for integration work and how the
> supported AWS validation path creates, owns, and tears down real AWS resources.

## 0. Canonical Doctrine Statements

- `prodbox` AWS authentication material must be stored only in the repository-root
  `prodbox-config.dhall` and decoded directly into Haskell settings.
- `prodbox` must not search upward from the current working directory or prefer alternate config
  files.
- Public `prodbox config setup` and public `prodbox aws ...` flows obtain temporary admin AWS
  credentials (historically called "elevated credentials") from interactive prompts; they must
  not rely on config-backed `aws_admin_for_test_simulation.*`.
- `aws_admin_for_test_simulation.*` is the single stored-admin-credential exception and is consumed
  by suite-driven destructive validation plus the long-lived stack / `prodbox nuke` teardown
  surfaces that need the same admin credential class.
- `prodbox test integration aws-iam`, `prodbox test integration <name> --substrate aws`,
  `prodbox test integration all`, and `prodbox test all` share one suite-level IAM harness that
  provisions operational `aws.*` before prerequisite-driven AWS validation begins and clears those
  credentials again before the suite returns.
- Stateful AWS validation uses explicit credentials rebuilt from decoded settings, not ambient host
  AWS CLI state or shared profile discovery.
- Existing AWS resources are never valid mutation targets for supported `prodbox` integration
  validations.
- The local `prodbox` RKE2 cluster and its MinIO service must exist before any remote AWS test
  stack is created because Pulumi state for those stacks lives only in
  `prodbox-test-pulumi-backends`.
- AWS-substrate canonical-suite runs (`--substrate aws`) require the operator-supplied
  `aws_substrate.hosted_zone_id` and `aws_substrate.subzone_name` Dhall fields, populated by
  `prodbox pulumi aws-subzone-resources` provisioning a per-substrate Route 53 subzone with NS
  delegation in the parent zone. The AWS substrate must not fall back to home-substrate
  `route53.zone_id` or `domain.demo_fqdn` values; missing AWS-substrate config fails fast per
  [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback).
- The `prodbox` test harness is the **exclusive owner** of every AWS resource any `prodbox`
  flow creates or destroys. Every AWS API call flows through the harness via the `prodbox`
  command surface; ad-hoc `pulumi`, `aws` CLI, `eksctl`, or `terraform` invocations outside
  the harness are forbidden. The authoritative AWS resource inventory and per-resource
  lifecycle classification — auto-managed **per-run stacks** vs **long-lived cross-substrate
  shared infrastructure that is retained by design** — live in
  [`DEVELOPMENT_PLAN/substrates.md` → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
  See [`CLAUDE.md`](../../CLAUDE.md) and [`AGENTS.md`](../../AGENTS.md) for the rule that
  invoking a documented `prodbox` AWS entrypoint (`prodbox pulumi <stack>-resources/-destroy`,
  `prodbox aws setup/teardown`, `prodbox test integration ... --substrate aws`,
  `prodbox test all`) does not require separate user approval beyond the original request —
  live AWS spend and shared-infrastructure mutation are *expected* outcomes of asking the
  harness to provision the AWS substrate, not separate gates.
- Two orphan-safety guards close the `prodbox aws teardown` / managed test postflight
  contract (Sprint `7.6`, May 19, 2026): (a) `prodbox aws teardown` **refuses** to delete
  the operational IAM user while any Pulumi-managed stack (`aws-eks`, `aws-eks-subzone`,
  `aws-test`, `aws-ses`) still reports live resources, with an actionable failure message
  naming the offending stack(s) and the canonical destroy command; (b) the managed test-runner
  postflight **auto-destroys** every per-run Pulumi stack that a suite may have provisioned on
  test-run exit (success / failure / Ctrl-C) before clearing operational `aws.*`. This applies to
  aggregate runs and targeted `prodbox test integration <name> --substrate aws` runs that
  bootstrap or directly provision per-run stacks. The `aws-ses` stack is explicitly excluded from
  auto-destroy per the long-lived shared-infrastructure class. The
  `--allow-pulumi-residue` flag on `prodbox aws teardown` provides an operator-acknowledged
  escape hatch when recovery from a partial state requires deleting operational creds with
  stacks still up.
- **Sprint `4.19` (May 28, 2026)** closes a silent-pass defect in the per-run residue
  gate. `prodbox rke2 delete` (default) and `prodbox aws teardown` previously treated
  per-run `ResidueUnreachable` (the in-cluster MinIO Pulumi-state backend could not be
  read — e.g. the MinIO pod is down on a degraded cluster while the state is still intact
  on `.data/`) the same as `ResidueAbsent` and proceeded silently — reporting a clean
  teardown that then justified an operator `rm .data`, destroying the only record of
  still-live AWS resources. The gate now **fails closed on per-run `ResidueUnreachable`**
  with a distinct refusal ("cannot read the per-run Pulumi state backend … do NOT delete
  `.data/` until confirmed destroyed … or re-run with `--allow-pulumi-residue` to accept
  the orphan risk"). `--allow-pulumi-residue` remains the explicit operator escape. The
  `--cascade` path is unchanged (its `perRunCascadeInventory` keeps graceful degradation
  with the postflight tag sweep as backstop); the deliberate gate-vs-cascade asymmetry is
  documented in
  [lifecycle_reconciliation_doctrine.md §3](lifecycle_reconciliation_doctrine.md).
- **Sprint `7.8` (scheduled; Phase 7 reopened 2026-05-28)** brings the operational-credential
  lifecycle under the managed-resource registry. The operational `prodbox` IAM user and the
  operational `aws.*` block in `prodbox-config.dhall` become registered `Operational`-class
  resources (each with a `discover` + `destroy`), and `prodbox aws setup`/`teardown` are
  re-expressed as `reconcileAbsent` reconciliations over the registry — idempotent on re-run,
  `Unreachable`-fails-closed. This closes the coverage gap that let an interrupted run leak the
  operational IAM user *and* leave its stale `aws.*` config entry behind (the 2026-05-28
  incident). Doctrine:
  [lifecycle_reconciliation_doctrine.md § 3.1](./lifecycle_reconciliation_doctrine.md);
  schedule:
  [DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
  Sprint 7.8.
- Sprint `7.7` (May 19, 2026) generalizes the teardown residue contract and closes the
  test-harness orphan-safety hole that Sprint `7.6` left open. The `Bool`
  `awsTeardownAllowPulumiResidue` field on `AwsTeardownInput` was replaced by a
  `PulumiResiduePolicy` enum with `RefuseOnAnyResidue` (default,
  operator-driven), `DestroyPulumiResidueFirst` (operator-driven via the new
  `--destroy-pulumi-residue` flag, mutually exclusive with `--allow-pulumi-residue`),
  `AcceptOrphanResidue` (operator-driven via `--allow-pulumi-residue`, the Sprint `7.6`
  escape hatch), and `BypassPerRunResidueOnly` (harness-internal only, never CLI-settable).
  Sprint `7.5.c.v.c` later added a fifth constructor, `BypassAllResidueForHarnessRefresh`
  (also harness-internal only), which bypasses both per-run AND long-lived residue.
  The per-run partition (`aws-eks`, `aws-eks-subzone`, `aws-test`) vs long-lived partition
  (`aws-ses`) is fixed by `Prodbox.Aws.perRunStackNames` / `longLivedStackNames` and must
  match `DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes` verbatim.
  - At Sprint 7.7 the test-harness teardown paths both used `BypassPerRunResidueOnly`, so the
    harness refused on `aws-ses` residue the way the operator-driven path does. That was
    correct *only* pre-Sprint-4.10, when `aws-ses` was operationally credentialed (clearing
    operational `aws.*` then genuinely stranded it).
  - Sprint `4.10` moved `aws-ses` to admin credentials
    (`aws_admin_for_test_simulation.*`); Sprint `7.5.c.v.c` then switched the preflight
    (`runAwsIamHarnessSetup`) to `BypassAllResidueForHarnessRefresh` but left the postflight
    on `BypassPerRunResidueOnly`. Sprint `7.9` (2026-05-29) finishes the reconciliation:
    the postflight (`runAwsIamHarnessTeardown`) also uses `BypassAllResidueForHarnessRefresh`.
    The harness no longer refuses on `aws-ses` residue at all — `aws-ses` is admin-managed,
    so clearing operational `aws.*` cannot strand it, and per-run residue is destroyed by
    `awsPostflightDestroyActions` in the same suite-exit unwind. `BypassPerRunResidueOnly`
    remains a valid ADT member (it still refuses on long-lived residue) but has no production
    caller after Sprint 7.9.
- Sprint `7.7` also moved the file-based residue check **before** the credential prompt in
  `interactiveAwsTeardownInput`, so operators on the refuse path never enter credentials
  the tool was about to discard, and added a "nothing to do" early-exit when residue is
  empty AND operational `aws.*` is empty. The admin-credential prompt now auto-detects
  the access-key prefix (`sessionTokenPromptShape`): `AKIA…` skips the session-token
  prompt entirely; `ASIA…` makes it a required hidden field; any other prefix falls back
  to an optional prompt with an explanatory hint. The four user-facing prompt strings
  were renamed from "Elevated AWS …" / "elevated operations" to "Temporary admin AWS …"
  / "admin operations" inline with the May 2026 doctrine alignment.
- **Sprint `4.10` (planned)**: long-lived Pulumi state is decoupled from the in-cluster
  MinIO backend onto a dedicated AWS S3 bucket configured via the new
  `pulumi_state_backend` block in `prodbox-config.dhall`. The `aws-ses` stack moves to
  the new backend so its state survives arbitrary `rke2 delete + rke2 reconcile` cycles.
  Per-run stacks continue using MinIO. State lifetime matches resource lifetime per class.
  See [lifecycle_reconciliation_doctrine.md → §2 State-Lifetime Rule](lifecycle_reconciliation_doctrine.md).
- **Sprint `4.11` (planned)**: `prodbox rke2 delete` carries a symmetric refuse-path
  scoped to per-run Pulumi stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`). `aws-ses`
  is excluded because Sprint `4.10` places its state outside the cluster. The new
  `--cascade` flag is the positive-framed "clean teardown" path; `--allow-pulumi-residue`
  matches the `aws teardown` escape hatch.
- **Sprint `4.12` (planned)**: K8s drain phase + postflight tag sweep close the
  K8s-controller-created AWS leak classes (CSI volumes, ALBs, cert-manager DNS01 TXTs,
  direct-aws-CLI shell-out Route 53 records). Together with Sprint `4.11`'s refuse-path
  these make `prodbox rke2 delete --cascade` structurally leak-safe.
- **Sprint `4.13` (planned)**: `prodbox nuke` is the operator-only total-teardown command
  that destroys long-lived shared infrastructure transitively, including the `aws-ses`
  stack and the long-lived `pulumi_state_backend` bucket. TTY-only, typed-confirmation
  literal `NUKE EVERYTHING`, no `--yes` shorthand.
- Every interactive `prodbox` entry point (`prodbox config setup`,
  `prodbox aws setup`, `prodbox aws teardown`, `prodbox aws check-quotas`,
  `prodbox aws request-quotas`, and the `prodbox charts delete` confirmation prompt)
  **refuses to run when stdin is not a TTY** and exits 1 with a guidance message naming
  the automation equivalent. Implementation in `src/Prodbox/CLI/Interactive.hs`; full
  contract in
  [`cli_command_surface.md` § 3A — Interactive vs Non-Interactive Surfaces](cli_command_surface.md#3a-interactive-vs-non-interactive-surfaces).
  This closes the long-standing failure mode where automation agents would hit the
  prompt and report it as a blocker instead of switching to `prodbox test all` /
  `prodbox test integration ... --substrate aws`.

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
frontend and explicit AWS CLI subprocess environments, but they prompt for temporary admin
credentials instead of consuming stored `aws_admin_for_test_simulation.*` at runtime. The stored
admin block is reserved for managed suite-driven validation, targeted AWS-substrate validation,
and long-lived stack / `prodbox nuke` teardown surfaces.

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

Optional admin validation fields:

1. `aws_admin_for_test_simulation.access_key_id`
2. `aws_admin_for_test_simulation.secret_access_key`
3. `aws_admin_for_test_simulation.session_token`
4. `aws_admin_for_test_simulation.region`

Stored admin credentials are otherwise forbidden. `aws_admin_for_test_simulation.*` is the one
supported exception, and it is reserved for `prodbox test integration aws-iam`, targeted
`prodbox test integration <name> --substrate aws` validation, aggregate-harness execution of
that suite, repository tests that simulate the interactive temporary-admin-credential prompt,
long-lived `aws-ses` / state-backend operations, and `prodbox nuke`.

Public `prodbox config setup` and public `prodbox aws ...` commands must not consume
`aws_admin_for_test_simulation.*` from config on the supported path; they prompt for temporary
admin credentials when needed.

Supported config-backed admin consumers load `aws_admin_for_test_simulation.*` directly; missing
admin credentials must fail fast with an actionable config error rather than falling back to
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

The same forbidden-env-var posture extends to the in-cluster gateway daemon: AWS
credentials reach the daemon Pod via a k8s Secret mounted as a Dhall file at
`/etc/gateway/secrets/aws.dhall`, imported by the main Dhall config per
[config_doctrine.md](./config_doctrine.md). No `AWS_*` environment variable is read by
supported daemon paths; the subprocess that calls `aws route53 ...` receives credentials
through an explicit subprocess-environment overlay assembled from the decoded Dhall
config, not from the Pod environment.

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating validation runs, the harness must prove:

1. the system `aws` CLI exists when direct AWS CLI operations are required
2. decoded settings define usable AWS authentication for the identity the validation will run under
3. that identity can perform the lifecycle the validation owns
4. for managed suite-driven runs (`aws-iam`, aggregate suites, and targeted
   `prodbox test integration <name> --substrate aws` validations), the native IAM harness config
   is complete enough to materialize operational `aws.*` from
   `aws_admin_for_test_simulation.*` without falling back to pre-existing operational credentials

### 3.2 Required Check Semantics

The required checks map to:

1. tool check: `aws` must be invokable
2. config auth check: `aws sts get-caller-identity` must succeed with subprocess auth rebuilt from
   decoded settings
3. lifecycle-capability check:
   Route 53 validations must be able to create and fully own a fresh hosted-zone lifecycle;
   Pulumi-backed validations must be able to drive the canonical `prodbox pulumi` command surface
4. native IAM harness check: managed suite-driven runs must fail before their validation bodies
   when `aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise
   incomplete harness config

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
6. `prodbox rke2 delete` opens with the Sprint `4.11` per-run refuse-path: it refuses when
   any of `aws-eks`, `aws-eks-subzone`, `aws-test` reports live resources, naming each
   stack and the canonical destroy command. The `--cascade` flag orchestrates K8s drain
   (Sprint `4.12`) + per-run destroys + cluster uninstall + postflight tag sweep as one
   atomic operator action — the canonical "wipe and rebuild" path. `aws-ses` is ignored
   throughout because its Pulumi state lives outside the cluster (Sprint `4.10`) and may
   only be destroyed by `prodbox pulumi aws-ses-destroy --yes` or `prodbox nuke`
7. the AWS validation Pulumi programs take non-secret operator-CIDR and SSH-public-key inputs
   through explicit stack config synchronized by the Haskell orchestration layer, while AWS
   provider credentials stay in the Haskell-owned subprocess environment
8. both retained AWS destroy paths refresh Pulumi state and retry destroy once before surfacing a
   cleanup failure
9. the HA-RKE2 validation destroys and recreates the retained AWS test stack once when stack
   reconcile succeeds but SSH validation still fails, so stale EC2 instances left by an
   interrupted run or operator network move do not survive as terminal validation state
10. the local `prodbox-pulumi` Cabal stanza proves the retained ephemeral-stack harness and
   typed-output contract around those stack flows, while end-to-end AWS provisioning is exercised
   by the named `prodbox pulumi ...` and `prodbox test integration ...` surfaces plus the aggregate
   test suite

### 4.4 Stored Admin Credential Harness

The IAM lifecycle validation and long-lived teardown surfaces use the same repository-root Dhall
configuration file but a separate credential section:

1. `aws.*` remains the normal operational identity
2. `aws_admin_for_test_simulation.*` is the stored simulation of the ephemeral temporary-admin
   identity used by `prodbox test integration aws-iam`,
   `prodbox test integration <name> --substrate aws`, `prodbox test integration all`,
   `prodbox test all`, long-lived `aws-ses` / state-backend operations, and `prodbox nuke`
3. the validation must fail fast when `aws_admin_for_test_simulation.*` is missing or partial
4. public `prodbox config setup` and public `prodbox aws ...` commands remain outside this
   config-backed test harness and use interactive temporary admin credentials instead
5. the managed test harness proves that the temporary-admin test identity can mint an
   STS-federated validation session, but it persists the dedicated IAM-user access key for
   downstream runtime setup because the cert-manager Route 53 DNS01 solver has no
   session-token field
6. freshly-created operational IAM-user credentials are not released to downstream runtime setup
   until both STS identity probing and repeated Route 53 hosted-zone probing succeed with that
   access key; runtime Route 53 bootstrap changes also keep a bounded retry window for later IAM
   propagation

### 4.5 Pulumi State Backend Prerequisite

Every `prodbox pulumi <stack>-resources` and `prodbox pulumi <stack>-destroy` invocation
(`aws-eks`, `aws-eks-subzone`, `aws-test`, `aws-ses`) projects the home substrate's in-cluster
MinIO as its Pulumi state backend. The projection happens through `withMinioPortForward` in
`src/Prodbox/Infra/AwsEksTestStack.hs` (and the analogous wrappers in the sibling
`Infra/Aws*.hs` modules). Concretely, this means:

1. The home substrate must be running before any AWS-substrate or AWS-shared `prodbox pulumi`
   call. Operator runs `prodbox rke2 reconcile` once; the command is idempotent and a no-op
   when the home substrate is already up.
2. The MinIO `prodbox-test-pulumi-backends` bucket must exist before the first stack is
   created. The reconcile contract ensures this — see § 0 above for the canonical statement.
3. AWS-substrate work does not bootstrap its own Pulumi backend; there is no AWS-side
   alternative to the home MinIO state store on the supported path.

The standalone Sprint `7.5.c.v` workflow makes this prerequisite explicit as
[Sprint Workflow Step `0.5`](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
suite-driven runs (`prodbox test all`) cover it through the Sprint `7.6`
auto-managed lifecycle.

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
3. Managed suite postflight repair is owned by the test runner for aggregate suites and targeted
   `prodbox test integration <name> --substrate aws` validations
4. The shared IAM harness still attempts teardown and `aws.*` clearing when prerequisite
   validation fails after harness setup has already materialized operational credentials

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited.

If validation-owned Route 53 cleanup or Pulumi-owned stack destroy fails, the suite must abort with
explicit target and error text.

### 5.5 Cascade Drain Phase Against EKS

The `prodbox rke2 delete --cascade --yes` drain phase
([`lifecycle_reconciliation_doctrine.md` §5b](lifecycle_reconciliation_doctrine.md))
must run against the **substrate's own kubeconfig**, not the operator-host
RKE2 kubeconfig, when the cascade is tearing down resources on the AWS substrate.
A drain that hard-codes `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` walks the
local cluster's namespaces (which do not contain the EKS-side LoadBalancer
Services, ALB Ingresses, or Delete-reclaim PVCs), reports nothing to drain,
and lets the next cascade phase (per-run Pulumi destroys) fail with
`DependencyViolation: The subnet '<id>' has dependencies and cannot be deleted`
because the EKS-side controllers (AWS Load Balancer Controller, EBS CSI
driver) still have orphan ENIs / ALBs / EBS volumes attached to the subnets
Pulumi is trying to delete.

The canonical bracket is
`Prodbox.PublicEdge.withSubstrateKubectlEnvironment` (exported from
`src/Prodbox/PublicEdge.hs`). On `SubstrateAws` it wraps the action in
`Prodbox.Infra.AwsEksTestStack.withEksKubeconfig`, which materializes
the EKS kubeconfig per-invocation into a scoped temp file via
`aws eks update-kubeconfig --kubeconfig <openTempFile>` (Sprint
`4.18` fifth chunk; no cross-invocation file persistence), then sets
`KUBECONFIG` to the temp path plus the `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` / `AWS_SESSION_TOKEN`
env vars that the EKS kubeconfig's `aws eks get-token` exec provider
needs. Any kubectl
subprocess that the cascade drain phase (or any other AWS-substrate-aware
diagnostic) invokes must be wrapped in this bracket.

A drain that reports `DrainSkipped` on the AWS substrate is **not**
success-with-reason — it is a hard failure. The EKS cluster is the source
of the AWS resources the per-run destroys will try to delete; skipping
the drain because "the local cluster is unreachable" guarantees the
next phase will fail.

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
5. `prodbox pulumi aws-subzone-resources`
6. `prodbox pulumi aws-subzone-destroy --yes`
7. `prodbox pulumi aws-ses-resources`
8. `prodbox pulumi aws-ses-destroy --yes`

### 6.4 Cross-Substrate Shared SES Infrastructure

Per [`DEVELOPMENT_PLAN/phase-8-email-invite-auth.md`](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md)
and [`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md#cross-substrate-shared-resources),
the AWS SES sending identity, receive subdomain MX records, receive rule set, S3 capture bucket,
and SMTP IAM user are account-scoped resources shared across every substrate that runs
`ValidationKeycloakInvite`. The supported provisioning entrypoints are
`prodbox pulumi aws-ses-resources` and `prodbox pulumi aws-ses-destroy --yes`, sourced from
`pulumi/aws-ses/` and operated through
`src/Prodbox/Infra/AwsSesStack.hs`. The operator-supplied inputs are
`ses.sender_domain`, `ses.receive_subdomain`, and `ses.capture_bucket` in
`prodbox-config.dhall`; the parent Route 53 zone (`route53.zone_id`) carries the MX records for
the receive subdomain.

The SMTP IAM user's `aws:iam:AccessKey` is exported by the Pulumi stack as
`smtp_iam_access_key_id` / `smtp_iam_secret_access_key`; the Keycloak chart (Sprint `8.2`)
consumes the SES IAM-to-SMTP-credentials derivation as a Kubernetes secret. Fresh per-run AWS
clusters and invite-aware home-runtime bootstraps must sync that retained stack output into the
current Kubernetes context before Helm renders Keycloak: the test bootstrap reads the long-lived
`aws-ses` outputs via `aws_admin_for_test_simulation.*`, first running the same idempotent
`ensureLongLivedPulumiStateBucket` precondition used by `aws-ses-resources`, and applies
`keycloak-smtp` into the supported Keycloak release namespaces (`vscode` for the canonical
shared-edge stack, `keycloak` for the standalone root chart). Because Keycloak's realm import does
not update an already-created realm, `prodbox users invite` also patches the live realm's
`smtpServer` from `keycloak-smtp` before it sends an execute-actions email. If the long-lived stack
state is missing while retained fixed-name SES/S3/IAM resources still exist, `aws-ses-resources`
repairs state by importing the retained capture bucket, SMTP IAM user, SES receipt rule set, and receipt
rule, rotating stale SMTP access keys so Pulumi owns a fresh retrievable secret, and reconciling
overwrite-tolerant Route 53 verification/DKIM/MX records. The `ValidationKeycloakInvite`
canonical-suite member (Sprint `8.5`) reads inbound capture from the S3 bucket via the same IAM
user (`s3:ListBucket`, `s3:GetObject`, `s3:DeleteObject` on the bucket and its objects).
In aggregate runs, `ValidationKeycloakInvite` must run before destructive
`ValidationChartsStorage` and `ValidationLifecycle` so AWS-substrate invite proof still has
the live `vscode` root chart/Keycloak deployment, a live EKS stack snapshot, and a live
kubeconfig. The Keycloak chart's shared-host auth `HTTPRoute` must include `/auth/admin` because
the operator-owned invite flow creates users through the Keycloak admin API after acquiring its
token from `/auth/realms/master`. `ValidationLifecycle` remains the terminal destructive validation.
The Pulumi program is the exclusive provisioning surface; ad-hoc `aws ses *` and `aws s3 *`
mutations are not part of the supported path.

## Cross-References

- [AWS Admin Credentials](./aws_admin_credentials.md)
- [AWS Test Environment](./aws_test_environment.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
