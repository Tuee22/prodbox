# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Define how `prodbox` authenticates to AWS for integration work and how the
> supported AWS validation path creates, owns, and tears down real AWS resources.

## 0. Canonical Doctrine Statements

- Operational `prodbox` AWS authentication material in Tier-0 `prodbox.dhall`
  is a `SecretRef.Vault` reference (the generated `aws.*` identity), never
  a plaintext key; test-simulation credentials live in `test-secrets.dhall`, not in
  `prodbox.dhall`. The SecretRef model, the config split, and the secret classification
  are owned by [vault_doctrine.md §3, §4, §13](./vault_doctrine.md) — this document defers to that
  SSoT rather than restating it.
- `prodbox` must not search upward from the current working directory or prefer alternate config
  files.
- There is exactly one runtime path by which elevated/admin AWS power enters `prodbox`: the
  interactive `SecretRef.Prompt`. Public setup/teardown, the native IAM harness, explicit
  long-lived destroy/migration and retained-bucket compatibility, and `prodbox nuke` prompt for the
  ephemeral temporary-admin AWS credential (historically called "elevated credentials"); none
  reads a stored admin section from `prodbox.dhall`. Canonical `aws-ses reconcile` is not in this
  prompt set: it uses operational `aws.*` only to assume its fixed role. A prompted credential is
  held in memory for one command, used once, and discarded — never written to config or Vault.
- `aws_admin_for_test_simulation.*` is a test-harness-only fixture that lives in `test-secrets.dhall`
  and exists solely to drive the interactive UI: it feeds the same temporary-admin prompt a real
  operator answers so the harness can exercise admin-credentialed flows non-interactively. It is
  `TestPlaintext`-class, is never imported by `prodbox.dhall`, never read by a production
  binary, and never stored in Vault. The block specifics are owned by
  [aws_admin_credentials.md](./aws_admin_credentials.md).
- `prodbox test integration aws-iam`, `prodbox test integration <name> --substrate aws`,
  `prodbox test integration all`, and `prodbox test all` share one suite-level IAM harness that
  provisions operational `aws.*` before prerequisite-driven AWS validation begins and clears those
  credentials again before the suite returns.
- Stateful AWS validation uses explicit credentials rebuilt from decoded settings, not ambient host
  AWS CLI state or shared profile discovery.
- Per-run validation resources are always newly allocated and owned by that run. Registered
  long-lived shared resources are the explicit exception: when a selected validation requires one,
  the harness reconciles its declared desired state through the canonical idempotent command and
  retains it after the run. Unregistered or merely discovered pre-existing resources are never
  valid mutation targets.
- The local `prodbox` RKE2 cluster and its MinIO service must exist before any remote AWS test
  stack is created because Pulumi state for those stacks lives only in
  `prodbox-state`.
- AWS-substrate canonical-suite runs (`--substrate aws`) require the operator-supplied
  `aws_substrate.hosted_zone_id` and `aws_substrate.subzone_name` Dhall fields, populated by
  `prodbox aws stack aws-subzone reconcile` provisioning a per-substrate Route 53 subzone with NS
  delegation in the parent zone. The AWS substrate must not fall back to home-substrate
  `route53.zone_id` or `domain.demo_fqdn` values; missing AWS-substrate config fails fast per
  [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback).
  The AWS-substrate hosted-zone id is sourced from settings
  (`aws_substrate.hosted_zone_id` via `Prodbox.PublicEdge.resolveSubstrateHostedZoneId`) and,
  failing that, the live `aws-eks-subzone` Pulumi stack output — never from a
  `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` environment variable (Sprint `7.13` removed that env
  read per [config_doctrine.md § 10](./config_doctrine.md); `Prodbox.PublicEdge` is now scoped
  by `checkEnvVarConfigReads` so it cannot reappear). The single public-edge ACME
  `ClusterIssuer` is named `zerossl-dns01` (DNS-01-honest; renamed from the misleading
  HTTP-01-claiming name in Sprint `7.13`).
- **The home substrate and the AWS substrate stand up the same shared service set** (Sprint
  `7.12` substrate equivalence): The in-cluster registry (registry:2) + MinIO + the Percona PostgreSQL operator are installed
  on **both** substrates — the AWS substrate is **not** a "no-registry on EKS" cluster. The AWS
  registry is the EKS-side registry reached through the node-local registry proxy (the EKS containerd
  registry-mirror DaemonSet that makes `127.0.0.1:30080/prodbox/...` resolve on EKS, mirroring
  the home NodePort-on-`127.0.0.1` pattern), so the canonical chart image refs are identical
  across substrates. The two installers differ only in their LOWER layer (MetalLB on home, the
  AWS Load Balancer Controller on EKS; parent zone on home, the delegated subzone on AWS; and
  the block-storage volume source — hostPath on home, pre-created EBS on EKS — though the static
  `Retain` storage discipline is identical across both, see
  [storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md#1-canonical-doctrine-statements)). The
  shared platform-component pins (Envoy Gateway, cert-manager, the registry, MinIO, Percona) come from
  the single `Prodbox.ContainerImage` SSoT and are enforced by the `checkSubstrateImagePinning`
  lint plus the `[PlatformComponent]` coverage test. See
  [`DEVELOPMENT_PLAN/substrates.md` → Substrate Equivalence (Structural Invariant)](../../DEVELOPMENT_PLAN/substrates.md#substrate-equivalence-structural-invariant).
- The `prodbox` test harness is the **exclusive owner** of every AWS resource any `prodbox`
  flow creates or destroys. Every AWS API call flows through the harness via the `prodbox`
  command surface; ad-hoc `pulumi`, `aws` CLI, `eksctl`, or `terraform` invocations outside
  the harness are forbidden. The authoritative AWS resource inventory and per-resource
  lifecycle classification — auto-managed **per-run stacks** vs **long-lived cross-substrate
  shared infrastructure that is retained by design** — live in
  [`DEVELOPMENT_PLAN/substrates.md` → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
  See [`CLAUDE.md`](../../CLAUDE.md) and [`AGENTS.md`](../../AGENTS.md) for the rule that
  invoking a documented `prodbox` AWS entrypoint (`prodbox aws stack <stack> reconcile/-destroy`,
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
  gate. `prodbox cluster delete` (default) and `prodbox aws teardown` previously treated
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
- The operational-credential lifecycle is brought under the managed-resource registry. The
  operational `prodbox` IAM user and the operational `aws.*` Vault KV material referenced by
  `prodbox.dhall`
  are registered `Operational`-class resources (each with a `discover` + `destroy`), and
  `prodbox aws setup`/`teardown` are expressed as `reconcileAbsent` reconciliations over the
  registry — idempotent on re-run, `Unreachable`-fails-closed. This is the current enforced
  structure and closes the coverage gap that previously let an interrupted run leak the
  operational IAM user *and* leave its stale `aws.*` config entry behind (the 2026-05-28
  incident). Doctrine:
  [lifecycle_reconciliation_doctrine.md § 3.1](./lifecycle_reconciliation_doctrine.md);
  phase ownership:
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
  (`aws-ses` + the non-stack `public-edge-tls` cert) is fixed by
  `Prodbox.Aws.perRunStackNames` (derived from the `Prodbox.Infra.StackDescriptor` SSoT,
  Sprint `4.27`) / `Prodbox.Aws.longLivedResourceNames` and must
  match `DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes` verbatim.
  - At Sprint 7.7 the test-harness teardown paths both used `BypassPerRunResidueOnly`, so the
    harness refused on `aws-ses` residue the way the operator-driven path does. That was
    correct *only* pre-Sprint-4.10, when `aws-ses` was operationally credentialed (clearing
    operational `aws.*` then genuinely stranded it).
  - Sprint `4.10` moved `aws-ses` to the temporary-admin credential class — real ops prompted for
    the ephemeral elevated credential, and the harness simulated that prompt from
    `aws_admin_for_test_simulation.*` in `test-secrets.dhall`; Sprint `7.5.c.v.c` then switched the preflight
    (`runAwsIamHarnessSetup`) to `BypassAllResidueForHarnessRefresh` but left the postflight
    on `BypassPerRunResidueOnly`. Sprint `7.9` (2026-05-29) finishes the reconciliation:
    the postflight (`runAwsIamHarnessTeardown`) also uses `BypassAllResidueForHarnessRefresh`.
    The harness no longer refuses on `aws-ses` residue at all — its explicit destroy remains
    admin-authorized, so clearing operational `aws.*` and the registered SES lease role cannot
    strand teardown, and per-run residue is destroyed by
    `awsPostflightDestroyActions` in the same suite-exit unwind. `BypassPerRunResidueOnly`
    remains a valid ADT member (it still refuses on long-lived residue) but has no production
    caller after Sprint 7.9.
    Sprint `4.47` later moved canonical desired-present reconcile to the fixed operational role;
    explicit destroy/migration remain on the temporary-admin path, so the Sprint 7.9 teardown
    conclusion remains valid.
- Sprint `7.7` also moved the file-based residue check **before** the credential prompt in
  `interactiveAwsTeardownInput`, so operators on the refuse path never enter credentials
  the tool was about to discard, and added a "nothing to do" early-exit when residue is
  empty AND operational `aws.*` is empty. The admin-credential prompt now auto-detects
  the access-key prefix (`sessionTokenPromptShape`): `AKIA…` skips the session-token
  prompt entirely; `ASIA…` makes it a required hidden field; any other prefix falls back
  to an optional prompt with an explanatory hint. The four user-facing prompt strings
  were renamed from "Elevated AWS …" / "elevated operations" to "Temporary admin AWS …"
  / "admin operations" inline with the May 2026 doctrine alignment.
- **Sprints `4.10`, `7.14`, and `4.47`**: Pulumi checkpoint state is routed through the encrypted
  Model-B backend. Sprint `7.14` made the main `aws-ses` reconcile/destroy/read paths use the same
  decrypt-to-scratch wrapper as the per-run stacks. Sprint `4.47` narrowed the canonical
  desired-present reconcile further: Vault-resolved operational `aws.*` may only assume the fixed
  same-account `prodbox-ses-lease-session` role, and every lease stage uses a separately bounded
  role session. Setup/admin credentials reconcile that role and the operational-user policy;
  explicit destroy, migrate-backend, retained-bucket compatibility, and nuke remain admin-powered.
  The `pulumi_state_backend` S3 bucket remains for retained public-edge TLS objects and as the
  optional first-touch source for old `aws-ses` checkpoints; the `aws-ses migrate-backend`
  compatibility command drives the encrypted wrapper instead of raw MinIO-to-S3 export/import.
  See [lifecycle_reconciliation_doctrine.md → §2 State-Lifetime Rule](lifecycle_reconciliation_doctrine.md).
- **Sprints `4.47`, `5.17`, and `8.10`**: lifecycle class controls teardown, not
  desired-presence preparation. Sprint `4.47` completes the canonical retained-SES transaction and
  provider-presence gate. Sprint `5.17` derives one nested atomic bracketed plan from an
  invite-capable selected validation set and places it before dependent charts on the selected home
  or explicit EKS target. Sprint `8.10` completes exhaustive semantic SES readiness inside that
  bracketed await. Ordinary suite postflight never destroys `aws-ses`. See §4.6.
- Cross-substrate retained state has an explicit authority split: `aws-ses` checkpoint and lease
  operations always use the retained home/control-plane `LongLivedCheckpointAuthority`, while
  derived SMTP KV is written only through the selected substrate's `TargetClusterSecretSink`. The
  active target gateway is never an implicit checkpoint backend. See §4.5.
- **Sprint `4.11`**: `prodbox cluster delete` carries a symmetric refuse-path
  scoped to per-run Pulumi stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`). `aws-ses`
  is excluded because its `LongLived` cleanup class is outside cluster teardown. Its current
  checkpoint uses the encrypted Model-B/MinIO path and persists with preserved `.data/`; the new
  `--cascade` flag is the positive-framed "clean teardown" path; `--allow-pulumi-residue`
  matches the `aws teardown` escape hatch.
- **Sprint `4.12`**: K8s drain phase + postflight tag sweep close the
  K8s-controller-created AWS leak classes (CSI volumes, ALBs, cert-manager DNS01 TXTs,
  direct-aws-CLI shell-out Route 53 records). Together with Sprint `4.11`'s refuse-path
  these make `prodbox cluster delete --cascade` structurally leak-safe.
- **Sprint `4.13`**: `prodbox nuke` is the operator-only total-teardown command
  that destroys long-lived shared infrastructure transitively, including the `aws-ses`
  stack and the long-lived `pulumi_state_backend` bucket. TTY-only, typed-confirmation
  literal `NUKE EVERYTHING`, no `--yes` shorthand.
- Every interactive `prodbox` entry point (`prodbox config setup`,
  `prodbox aws setup`, `prodbox aws teardown`, `prodbox aws quotas check`,
  `prodbox aws quotas request`, and the `prodbox charts delete` confirmation prompt)
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
7. The supporting `prodbox aws stack ...` and `prodbox aws ...` command surfaces those validations
   rely on, plus the credential-boundary rules those validations depend on

The public surfaces route through the native Haskell frontend and explicit AWS CLI subprocess
environments. Admin-authorized setup and destructive/compatibility flows prompt for the ephemeral
temporary-admin credential through the interactive `SecretRef.Prompt`; there is no production
config-backed admin path. The test harness simulates that prompt from
`aws_admin_for_test_simulation.*` in `test-secrets.dhall` when it mints/tears down operational
identity. The canonical `prodbox aws stack aws-ses reconcile` is deliberately different: it
resolves operational `aws.*` from Vault only to assume the exact fixed SES lease role and never
loads or prompts for an admin credential.

## 2. Authentication Source And Storage Rules

### 2.1 Dhall Configuration Ownership

Operational AWS authentication material referenced by `prodbox.dhall` is a
`SecretRef.Vault` reference, not a plaintext key. The generated operational `prodbox` IAM
identity is minted into Vault KV (`secret/gateway/gateway/aws`) the instant it is created;
`prodbox.dhall` carries only the reference to it. The config-split and SecretRef model are
owned by [vault_doctrine.md §3, §4](./vault_doctrine.md).

Operational config fields (each a `SecretRef.Vault` reference, never plaintext):

1. `aws.access_key_id`
2. `aws.secret_access_key`
3. `aws.region`
4. `aws.session_token` (optional)

Test-simulation admin fixture (in `test-secrets.dhall`, `TestPlaintext`-class — NOT in
`prodbox.dhall`):

1. `aws_admin_for_test_simulation.access_key_id`
2. `aws_admin_for_test_simulation.secret_access_key`
3. `aws_admin_for_test_simulation.session_token`
4. `aws_admin_for_test_simulation.region`

`prodbox.dhall` holds no plaintext secrets and no `aws_admin_for_test_simulation` block.
The `aws_admin_for_test_simulation.*` fixture is a test-harness-only simulation of the interactive
temporary-admin-credential prompt; it lives only in `test-secrets.dhall`, is never imported by
`prodbox.dhall`, and is never stored in Vault. It exists so the harness can drive
`prodbox test integration aws-iam`, targeted `prodbox test integration <name> --substrate aws`
validation, aggregate-harness execution of that suite, long-lived `aws-ses` / state-backend
destroy/migration operations, and `prodbox nuke` non-interactively. Canonical `aws-ses reconcile`
does not consume this fixture directly; it uses the operational identity minted by harness setup to
assume its fixed role. The block specifics are owned by
[aws_admin_credentials.md](./aws_admin_credentials.md).

Public `prodbox config setup`, `prodbox aws setup`/`teardown`, explicit long-lived
destroy/migration, `prodbox nuke`, and every other admin-credentialed flow prompt for the ephemeral
temporary-admin credential through `SecretRef.Prompt`; none reads a stored admin section from
`prodbox.dhall`. Operational commands, including canonical `aws-ses reconcile`, do not prompt.

The harness simulates that prompt from `aws_admin_for_test_simulation.*` in `test-secrets.dhall`;
a missing or partial fixture must fail fast with an actionable error rather than falling back to
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
credentials reach the daemon Pod from Vault KV, fetched at startup through Vault Kubernetes
auth — there is no Secret-mounted `aws.dhall` fragment in the delivery path. The
prodbox-created AWS identities are `SecretRef.Vault` references resolved against the
in-cluster Vault per [config_doctrine.md](./config_doctrine.md) and
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth). No `AWS_*`
environment variable is read by supported daemon paths; the subprocess that calls
`aws route53 ...` receives credentials through an explicit subprocess-environment overlay
assembled from the Vault-resolved material, not from the Pod environment. A sealed Vault
fails this credential fetch closed.

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating validation runs, the harness must prove:

1. the system `aws` CLI exists when direct AWS CLI operations are required
2. decoded settings define usable AWS authentication for the identity the validation will run under
3. that identity can perform the lifecycle the validation owns
4. for managed suite-driven runs (`aws-iam`, aggregate suites, and targeted
   `prodbox test integration <name> --substrate aws` validations), the native IAM harness config
   is complete enough to mint the generated operational `aws.*` identity (written straight into
   Vault) from the harness-simulated temporary-admin prompt sourced from
   `aws_admin_for_test_simulation.*` in `test-secrets.dhall`, without falling back to pre-existing
   operational credentials

These are read-only prerequisite checks. A prerequisite may establish that the encrypted backend
can be reached or that required configuration is decodable; it must not reconcile `aws-ses` or any
other AWS resource. Required mutation is a separately narrated preparation-plan action after the
gate. See [Prerequisite Doctrine §4A](./prerequisite_doctrine.md#4a-prerequisitepreparation-boundary).

### 3.2 Required Check Semantics

The required checks map to:

1. tool check: `aws` must be invokable
2. config auth check: `aws sts get-caller-identity` must succeed with subprocess auth rebuilt from
   decoded settings
3. lifecycle-capability check:
   Route 53 validations must be able to create and fully own a fresh hosted-zone lifecycle;
   Pulumi-backed validations must be able to drive the canonical `prodbox aws stack` command surface
4. native IAM harness check: managed suite-driven runs must fail before their validation bodies
   when the `aws_admin_for_test_simulation.*` fixture in `test-secrets.dhall` (the source the
   harness uses to simulate the temporary-admin prompt) is missing, partial, or paired with an
   otherwise incomplete harness config

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
host can reach its RKE2-backed MinIO backend and the relevant named `prodbox aws stack` surface can
select, inspect, or create the canonical AWS test stack using settings-defined AWS auth.

The supported path synchronizes only non-secret validation inputs such as operator-CIDR and
SSH-public-key into the stack with `pulumi config set`. AWS provider credentials must remain in
the binary-sibling `prodbox.dhall` (as `SecretRef.Vault` pointers) and be projected into Pulumi
through the Haskell-owned subprocess environment, not copied into stack-local config files.

The prerequisite proof for that backend is a bounded `pulumi login ... --non-interactive` against
a hydrated scratch backend after the Haskell helper confirms the daemon-mediated encrypted Model-B
checkpoint authority is reachable and usable.
If the running MinIO pod still points at a deleted retained host-path mount, the helper recreates
the declared host path, reapplies the ownership and mode contract, restarts `statefulset/minio`,
and then reruns the login proof before stack operations continue.

On aggregate or cluster-backed suite paths, the public test runner may satisfy the local backend
contract by running the visible `prodbox cluster reconcile` phase before it executes the deferred
`pulumi_logged_in` prerequisite proof. The local-cluster-first rule still holds: remote AWS stack
creation does not begin until that post-runbook backend proof succeeds.

## 4. Environment Creation Rules

### 4.1 Brand-New Per-Run Resources Only

Supported AWS validations must create new **per-run** resources for the current run. They must not:

1. reuse a long-lived hosted zone
2. reuse a pre-existing VPC, EC2 instance, security group, or IAM role
3. mutate records or resources that predate the owning validation

The registered `aws-ses` stack is the deliberate long-lived exception. Invite-capable suites may
reconcile that fixed-name, harness-owned resource through §4.6 because the managed-resource registry
defines its desired state and cleanup policy. This exception does not authorize adoption or mutation
of arbitrary pre-existing AWS resources.

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

1. `prodbox cluster reconcile` creates or reconciles the local backend cluster first
2. `prodbox aws stack eks reconcile` is the only supported surface for creating or inspecting the AWS
   EKS test stack
3. `prodbox aws stack eks destroy --yes` is the only supported surface for destroying that stack
4. `prodbox aws stack test reconcile` is the only supported surface for creating or inspecting the AWS
   HA stack
5. `prodbox aws stack test destroy --yes` is the only supported surface for destroying that stack
6. `prodbox cluster delete` opens with the Sprint `4.11` per-run refuse-path: it refuses when
   any of `aws-eks`, `aws-eks-subzone`, `aws-test` reports live resources, naming each
   stack and the canonical destroy command. The `--cascade` flag orchestrates K8s drain
   (Sprint `4.12`) + per-run destroys + cluster uninstall + postflight tag sweep as one
   atomic operator action — the canonical "wipe and rebuild" path. `aws-ses` is ignored
   throughout because its `LongLived` cleanup class is retained across cluster teardown and may
   only be destroyed by `prodbox aws stack aws-ses destroy --yes` or `prodbox nuke`; its main
   checkpoint remains the encrypted Model-B object in MinIO described by §4.5
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
   by the named `prodbox aws stack ...` and `prodbox test integration ...` surfaces plus the aggregate
   test suite

### 4.4 Temporary-Admin Credential Harness

The IAM lifecycle validation and long-lived teardown surfaces prompt for the ephemeral
temporary-admin credential through `SecretRef.Prompt`; the test harness automates that prompt from
a test-only fixture. The sequencing matters: Vault is brought up and unsealed first, then the
ephemeral elevated credential is supplied (by an operator at the prompt, or by the harness
simulating it), then `prodbox` mints the dedicated least-privilege `prodbox` IAM identity, writes
the generated `aws.*` credential straight into Vault KV, installs its account-qualified policy,
and reconciles the fixed `prodbox-ses-lease-session` role whenever the complete SES scope is
configured. The prompted elevated credential is then discarded; it never transits cleartext
storage. Config setup refreshes the user policy and role after configuration changes without
rotating the access key.

The full ordered init → mint → write-to-Vault → postflight-delete-and-clear lifecycle the
suite-level IAM harness drives (the harness drives `vault init` with the `test-secrets.dhall`
operator password; the elevated `aws_admin_for_test_simulation.*` fixture mints the operational
IAM user/keys; those keys are written directly to Vault at `secret/gateway/gateway/aws`, never to
`prodbox.dhall`; and postflight deletes the IAM user/keys from AWS and clears the Vault
creds on success/failure/Ctrl-C with preflight idempotency, the Vault clear being an empty-value
write rather than a hard delete) is canonicalized in
[aws_admin_credentials.md §4.2](./aws_admin_credentials.md). This document defers to that SSoT for
the lifecycle; the items below state the credential-boundary invariants the lifecycle obeys.

1. `aws.*` remains the normal operational identity, minted into Vault KV and referenced from
   `prodbox.dhall` as a `SecretRef.Vault` value
2. `aws_admin_for_test_simulation.*` is the test-harness-only fixture in `test-secrets.dhall`
   (`TestPlaintext`-class) that simulates the ephemeral temporary-admin prompt the real flows
   answer interactively — driving `prodbox test integration aws-iam`,
   `prodbox test integration <name> --substrate aws`, `prodbox test integration all`,
   `prodbox test all`, long-lived `aws-ses` destroy/migration and state-backend operations, and
   `prodbox nuke`; real ops of those admin-authorized surfaces prompt for the credential rather
   than reading any stored section. Canonical `aws-ses reconcile` uses operational `aws.*` only to
   assume the fixed role and does not consume the simulation fixture directly
3. the validation must fail fast when the `aws_admin_for_test_simulation.*` fixture is missing or
   partial
4. public setup/teardown and explicit admin-authorized destroy/migration commands use the same
   interactive temporary-admin prompt; there is no production config-backed admin path
5. the managed test harness proves that the temporary-admin test identity can mint an
   STS-federated validation session, but it persists the dedicated IAM-user access key for
   downstream runtime setup because the cert-manager Route 53 DNS01 solver has no
   session-token field
6. freshly-created operational IAM-user credentials are not released to downstream runtime setup
   until both STS identity probing and repeated Route 53 hosted-zone probing succeed with that
   access key; runtime Route 53 bootstrap changes also keep a bounded retry window for later IAM
   propagation
7. the installed operational-user policy permits only the exact same-account SES role assumption,
   exact SMTP-user observation, and configured capture-bucket reads for the retained transaction;
   the role trust names only `arn:aws:iam::<account>:user/prodbox`, and its maximum session duration
   is 3,600 seconds

### 4.5 Pulumi State Backend Prerequisite

Pulumi checkpoint state is a Vault-sealed Model-B object-store concern. Sprint `7.14` routes the
main per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) and the main long-lived
`aws-ses` reconcile/destroy/read paths through `Prodbox.Pulumi.EncryptedBackend`: the command
hydrates the checkpoint into a RAM-backed `file://` scratch backend, runs Pulumi there, and stores
the resulting checkpoint back as an opaque object in the home substrate's `prodbox-state` MinIO
bucket.

Backend uniformity does not imply credential uniformity. Per-run stack operations use operational
credentials directly; canonical `aws-ses reconcile` narrows them through the registered fixed SES
lease role before any mutation; explicit `aws-ses destroy` and `migrate-backend` remain
admin-authorized compatibility/destructive surfaces. All of those paths still use the same
encrypted scratch-backend interposition.

For a cross-substrate long-lived stack, “home substrate” is an explicit retained control-plane
authority, not whichever target gateway is active. `LongLivedCheckpointAuthority` carries the
decoded home/control-plane gateway endpoint, `prodbox-state` namespace, and Vault/Transit keyspace
for checkpoint and lease operations. `TargetClusterSecretSink` separately carries the selected
home-or-AWS substrate gateway/Vault endpoint and the `secret/keycloak/smtp` KV destination. The
first is used for `aws-ses` checkpoint hydration/writeback and lease ownership; the second is used
only for the post-readiness SMTP commit. Neither may be inferred from ambient kubeconfig, current
context, environment variables, or an “active gateway” singleton.

`Prodbox.Lifecycle.CheckpointAuthority` implements those unrelated coordinate types and the flat
`ModelBObservation` domain. `Prodbox.Lifecycle.CheckpointAuthorityStore.gatewayModelBCasAdapter`
binds only the retained authority endpoint to the gateway's bounded opaque
`/v1/object-store/authority/get` and `/v1/object-store/authority/cas` routes. Missing state uses
put-if-absent; replacement carries the previously observed opaque object-store version; conflicts
return a new observation. Payload bytes remain Vault-enveloped under HMAC-derived object names, and
the opaque storage version is not reused as a lifecycle fence.

The lifecycle class still matters, but it no longer means a separate raw Pulumi backend for
`aws-ses`. Per-run stacks remain harness-owned and auto-destroyed by suite postflight; `aws-ses`
remains long-lived and is destroyed only by an explicit long-lived teardown command. The dedicated
`pulumi_state_backend` S3 bucket configured in `prodbox.dhall` remains supported for retained
public-edge TLS material and as the optional first-touch source for old `aws-ses` checkpoints.

Concretely, this means:

1. For Pulumi stack operations, the home substrate must be running before any
   `prodbox aws stack` call. Operator runs `prodbox cluster reconcile` once; the command is
   idempotent and a no-op when the home substrate is already up.
2. The MinIO `prodbox-state` bucket must exist before the first stack is created. The reconcile
   contract ensures this — see § 0 above for the canonical statement.
3. AWS-substrate work does not bootstrap an AWS-side Pulumi backend on the supported path; Pulumi
   sees only the scratch `file://` backend prepared by the encrypted backend wrapper.
4. The long-lived `pulumi_state_backend` bucket is no longer the main `aws-ses` Pulumi checkpoint
   backend. It remains the retained public-edge TLS store and an optional first-touch import source
   for old `aws-ses` state while `prodbox aws stack aws-ses migrate-backend` exists.
5. An AWS-targeted validation still reads and writes the `aws-ses` checkpoint through
   `LongLivedCheckpointAuthority` on the retained home control plane. It never seeds long-lived
   state into the per-run EKS gateway or that target cluster's object-store namespace.

The per-run partition (`aws-eks`, `aws-eks-subzone`, `aws-test`) vs long-lived partition
(`aws-ses` + the non-stack `public-edge-tls` cert) is fixed by `Prodbox.Aws.perRunStackNames` /
`Prodbox.Aws.longLivedResourceNames` and must match
[`DEVELOPMENT_PLAN/substrates.md` → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
verbatim.

Every Pulumi-managed substrate stack is described by one `Prodbox.Infra.StackDescriptor`
SSoT record (Sprint `4.27`): `stackRegistryName`, `stackPulumiStackId` (e.g. the registry
name `aws-eks` is provisioned under the Pulumi stack id `aws-eks-test`), `stackProjectSubdir`
under `pulumi/`, `stackCliVerb` (the `<stem>` in `prodbox aws stack <stem> reconcile` /
`<stem> destroy`), and `stackLifecycleClass`. `perRunStackNames`, the CLI verbs, and the
project dirs all **derive** from `stackDescriptors`, removing the drift the
documentation-harmony audit flagged between the registry names, the CLI verbs, and the
project directories. The registry-name↔CLI-command inventory is rendered from this SSoT into
the `stack-command-surface` generated section of
[`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
by `prodbox dev docs generate`; `prodbox dev docs check` fails the build if it drifts.

The standalone Sprint `7.5.c.v` workflow makes the per-run prerequisite explicit as
[Sprint Workflow Step `0.5`](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
suite-driven runs (`prodbox test all`) cover it through the Sprint `7.6`
auto-managed lifecycle.

### 4.6 Retained SES Desired-Presence Preparation

`LongLived` specifies that ordinary suite cleanup retains `aws-ses`; it does not make live SES state
an operator-prepared prerequisite. Sprint `5.17` makes the selected validation set the source of the
requirement: any plan containing `ValidationKeycloakInvite` derives one visible nested atomic
`RestorePrepareRetainedSes RetainedSesPreparationPlan` action on either substrate. The nested plan
carries the target gateway object-store precondition plus the exact five-stage transaction trace;
the injected interpreter owns only that readiness check and one call to the registered ensure.
Duplicate invite selections still reduce to one requirement; a plan without an invite-capable
validation derives no SES action.

The action executes in this order:

1. Project the marker exactly once. A home-local suite places it after the home gateway reconcile.
   An AWS suite suppresses it in the home/control-plane restore and places it after the EKS gateway
   reconcile, using a private EKS kubeconfig, an explicit Vault-derived AWS subprocess environment,
   and a scoped EKS gateway port-forward. Both projections place it before VS Code, API, and
   WebSocket reconcile.
2. Resolve the explicit `LongLivedCheckpointAuthority` and `TargetClusterSecretSink`, and prove the
   exact selected target's gateway object-store round trip. On home, the target sink has the
   retained authority identity and endpoint but remains a separate typed value. On AWS, the target
   identity is canonical `aws-eks` and its endpoint is the scoped port-forward. No ambient
   kubeconfig, active-gateway singleton, or endpoint inference selects either role.
3. Acquire the shared cross-process SES lease through `LongLivedCheckpointAuthority`, keyed by AWS
   account, region, and the registered `aws-ses` resource name. The returned owner/fencing grant is
   non-renewable and its validated safe-use deadline covers bounded reconcile, provider-then-semantic
   observation, SMTP commit, cancellation, clock-skew, and safety margins.
4. Invoke the same canonical idempotent reconciler as `prodbox aws stack aws-ses reconcile`, using
   the Vault-resolved operational `aws.*` credential solely to assume the exact same-account
   `prodbox-ses-lease-session` role. Reconcile, provider/semantic readiness, and SMTP
   repair/materialization each mint a separate session whose duration is at most 3,600 seconds and
   whose expiry cannot outlive its lease-work permit or the grant. The base operational credential
   never enters a mutation child environment, and this operation neither loads nor prompts for an
   admin credential.
   Session expiry prevents new AWS authorization but cannot revoke an API request or provider
   operation AWS accepted before expiry; fencing applies to checkpoint/SMTP CAS, not AWS itself.
   The reconciler observes AWS presence and checkpoint state separately: positively present
   fixed-name resources plus missing/corrupt state plan import/repair; positively absent AWS state
   may plan create; either authority being unobservable refuses. It applies drift and re-observes.
   The harness must not duplicate this logic with ad-hoc AWS calls.
5. Await provider and semantic readiness under the bounded lease-work permit. Every attempt first
   proves that the registered capture bucket, SMTP IAM user, receipt rule set, receipt rule, and
   capture-canary object are present. Only then does `Prodbox.Ses.Readiness` observe the exact sender
   identity/DKIM state, receive MX, active receipt rule, and capture list/get capability. The
   control-plane observations use a fresh lease-scoped role session, including the exact
   `ses:GetEmailIdentity` permission; the capture canary is listed and fetched with the operational
   credential used by invite polling.
6. While still holding the home/control-plane lease, CAS-record a global `TargetCommitIntent`
   naming the selected `TargetClusterSecretSink`, credential generation, value digest, deadline,
   owner, and fence. Revalidate the intent, perform one bounded target-Vault KV CAS carrying that
   metadata, read it back, and mark the global intent committed by owner/fence CAS; then release.
   A sink-local CAS is not represented as an atomic global fence.
7. Reconcile dependent charts after target SMTP sync. Deferred SES prerequisite nodes remain
   read-only observations of the prepared result and never dispatch another reconcile. Ordinary
   postflight uses `SesNotRequired` and never schedules retained-SES destruction.

`Prodbox.Ses.Readiness` accepts only the configured domain identity with
`VerifiedForSendingStatus = true`, verification and DKIM status `SUCCESS`, and DKIM signing enabled;
the single exact priority-10 regional inbound MX target; the configured active rule set with one
enabled exact-recipient S3 action targeting the configured bucket and `inbound/` prefix; and
operational-credential list/get access to
`inbound/.prodbox-readiness-capability-probe`. Missing resources and explicit propagation states are
`AwsSesPending`; wrong identity, disabled or terminal status, wrong MX/rule/action, or other
authoritative mismatch is `AwsSesFailed`; denial, malformed output, unknown status, transport
failure, and other observation uncertainty are `AwsSesUnobservable`. Only Pending repeats under the
bounded 5–30 minute policy. Failed and Unobservable terminate immediately; timeout reports the last
Pending reason, releases the lease through the surrounding bracket, and retains the long-lived
resources for the next idempotent run.

`prodbox host check-ses-readiness` exposes the same sending, receiving, and capture classifications
as a read-only single-observation diagnostic. It reports the structured current state and never
reconciles SES resources. The fresh-account propagation and real invite exercise remain a distinct,
non-blocking live-proof axis.

The AWS observation boundary uses the flat `Absent | Present snapshot | Unobservable reason` shape,
while checkpoint authority independently reports `Missing | Valid snapshot | Corrupt reason |
Unobservable reason`, as defined by
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#desired-present-reconciliation-for-long-lived-resources).
Access denial, throttling, malformed output, and transport failure are `Unobservable`, never
`Absent`/`Missing`. This is especially important during missing-checkpoint recovery: only positive
AWS absence or named present resources may drive create/import; either unobservable authority
prevents mutation.

The completed Sprint `4.47` implementation maps this doctrine to concrete modules without collapsing the
roles: `ResidueStatus` supplies the flat observations; `DesiredPresence` supplies the total
six-action planner/interpreter and mandatory re-observation; `ResourceRegistry` registers
`awsSesPulumiResource` in `desiredPresentManagedResources`; and `AwsSesStack` supplies typed AWS
presence/checkpoint observers plus the registered ensure interpreter. `Lease` / `LeaseInterpreter`,
`TargetCommitIntent`, `SmtpKeyRepair` / `SmtpKeyRepairInterpreter`, and
`EncryptedBackend.withFencedDecryptedStackEnvironment` supply the bounded Model-B transaction
primitives described below. `Prodbox.Ses.Readiness` supplies the pure exhaustive semantic fold,
captured AWS observation boundary, and bounded Pending poll. `AwsSesStack` composes them on the
supported command: it acquires and releases the lease on every exit, performs successor
target-intent recovery, mints fixed-role sessions per bounded stage, reconciles through the fenced
encrypted backend, re-observes provider then semantic readiness, and repairs/materializes SMTP
through the typed IAM and selected-sink adapters. Setup owns the registered fixed role and exact
operational-user policy; teardown deletes the role before the trusted user. This is the Sprint
`4.47` end-to-end completion claim. Sprint `5.17` now consumes
that transaction through selected-suite plan placement; Sprint `8.10` completes its semantic
readiness stage.

SMTP access-key repair never treats create as retry-safe. The fenced committed state includes the
IAM access-key ID. Repair compares the authoritative finite key inventory for the exact SMTP user
with that committed ID, deletes owned uncommitted or unrecoverable keys, waits for deletion to become
authoritatively visible, and re-observes before creating one replacement and committing its ID and
SMTP secret through the global target-intent protocol. A sole committed key with recoverable SMTP material is reused without creation; only
a stable empty inventory permits replacement creation. An unobservable, still-changing, or
over-bound key inventory refuses. In
particular, a key created by provider work accepted under an expired lease must first become visible
to the successor's quiescence observation; it is never bypassed by blindly issuing another create.

Preparation is idempotent, but it is not silently concurrent. The lease spans checkpoint recovery,
`pulumi up`, provider-then-semantic readiness, and SMTP-secret commit because an AWS account has one
active SES receipt-rule set and SMTP access-key recovery may rotate a secret. A lease or readiness
timeout fails the suite but does not destroy the retained SES resources.
Lease loss or an insufficient remaining safe-use interval cancels the bounded child and prevents
the process from issuing subsequent writes, but accepted AWS/provider work may still complete. A
successor waits authority expiry plus validated clock-skew, cancellation, conservative provider
grace, and target-write grace, then proves stable authoritative quiescence before idempotently
converging. It resolves every nonterminal global target intent, even one naming a different
substrate sink, by stable read-back or authoritative target retirement before issuing a new
credential generation. Pending, unbounded, or unobservable provider/target state refuses. A stale
owner cannot CAS the global checkpoint/intent forward; a target write already accepted may finish
late and is therefore handled by grace plus re-observation, not denied by prose.
Partial success remains retained and is repaired by the next reconcile; ordinary success, failure,
and Ctrl-C postflight all exclude `aws-ses` from destruction.

The authority split is invariant across substrates: on home-local, the two typed values may resolve
to services in the same physical cluster but remain distinct roles; on AWS, they necessarily point
to the retained home/control-plane state authority and the per-run EKS secret sink respectively.

Sprint ownership is split without duplicating status here: Sprint `4.47` owns the generic
desired-present/lease lifecycle primitive, Sprint `5.17` has landed capability-derived test
preparation, and Sprint `8.10` has landed semantic SES readiness. Code-owned Sprint `5.17` evidence is
10/10 focused plan/recovery tests, 6/6 explicit target-selection API tests, 12/12 global
target-commit tests, and 1508/1508 full unit tests. Completion status remains in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 5. Ownership And Cleanup

### 5.1 Route 53 Validation Owns Setup And Teardown

The `dns-aws` validation, not ambient machine state, creates the Route 53 environment and cleans it
up again.

### 5.2 Pulumi Owns Multi-Resource Stack Lifecycles

The same public CLI surfaces used by operators own the AWS test-stack lifecycles during validation:

1. `prodbox aws stack eks reconcile`
2. `prodbox aws stack eks destroy --yes`
3. `prodbox aws stack test reconcile`
4. `prodbox aws stack test destroy --yes`
5. `prodbox cluster delete --yes` as the final automatic destroy path before backend teardown

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

The `prodbox cluster delete --cascade --yes` drain phase
([`lifecycle_reconciliation_doctrine.md` §5b](lifecycle_reconciliation_doctrine.md))
must run against the **substrate's own kubeconfig**, not the operator-host
RKE2 kubeconfig, when the cascade is tearing down resources on the AWS substrate.
A drain that hard-codes `KUBECONFIG=/etc/rancher/rke2/rke2.yaml` walks the
local cluster's namespaces (which do not contain the EKS-side LoadBalancer
Services, ALB Ingresses, or Delete-reclaim PVCs), reports nothing to drain,
and lets the next cascade phase (per-run Pulumi destroys) fail with
`DependencyViolation: The subnet '<id>' has dependencies and cannot be deleted`
because the EKS-side controllers (AWS Load Balancer Controller) still have
orphan ENIs / ALBs attached to the subnets Pulumi is trying to delete. EBS
volumes are **not** in that orphan class: durable EKS storage is pre-created
static `Retain` PVs (CSI `volumeHandle`, AZ-pinned) that teardown **retains**
rather than drains — only the test harness deletes test-scoped-tagged EBS at
suite postflight (Sprints `4.39`, `4.40`; see
[storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md#1-canonical-doctrine-statements)).

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

1. `prodbox aws stack eks reconcile`
2. `prodbox aws stack eks destroy --yes`
3. `prodbox aws stack test reconcile`
4. `prodbox aws stack test destroy --yes`
5. `prodbox aws stack aws-subzone reconcile`
6. `prodbox aws stack aws-subzone destroy --yes`
7. `prodbox aws stack aws-ses reconcile`
8. `prodbox aws stack aws-ses destroy --yes`

### 6.4 Cross-Substrate Shared SES Infrastructure

Per [`DEVELOPMENT_PLAN/phase-8-email-invite-auth.md`](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md)
and [`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md#cross-substrate-shared-resources),
the AWS SES sending identity, receive subdomain MX records, receive rule set, S3 capture bucket,
and SMTP IAM user are account-scoped resources shared across every substrate that runs
`ValidationKeycloakInvite`. The supported provisioning entrypoints are
`prodbox aws stack aws-ses reconcile` and `prodbox aws stack aws-ses destroy --yes`, sourced from
`pulumi/aws-ses/` and operated through
`src/Prodbox/Infra/AwsSesStack.hs`. The operator-supplied inputs are
`ses.sender_domain`, `ses.receive_subdomain`, and `ses.capture_bucket` in
`prodbox.dhall`; the parent Route 53 zone (`route53.zone_id`) carries the MX records for
the receive subdomain.

The suite preparation and retention contract is §4.6. In particular, invite-capable suites invoke
the canonical reconcile themselves after the encrypted backend is ready; a missing stack is not an
operator-repair prerequisite. The corresponding read-only prerequisites only validate tools,
configuration, and observable readiness boundaries.

Pulumi owns the SMTP IAM user and its policy, but `pulumi/aws-ses/Main.yaml` declares no
`aws:iam:AccessKey` and exports no access-key ID or secret. Haskell is the sole key creator:
`Prodbox.Lifecycle.SmtpKeyRepairInterpreter` loads the guarded Model-B committed projection,
observes the exact user's bounded IAM inventory, performs every planned cleanup, proves stable
expected inventory, derives generation `1` or committed `N + 1`, obtains one fresh fenced permit,
and issues at most one create. It guarded-CAS commits the recoverable key material and mandates
re-observation; a conflict, pre-apply failure, or interruption deletes the uncommitted created key,
and every cleanup failure is propagated. The committed outcome supplies the SES
IAM-to-SMTP-credentials derivation written through the selected target's Vault KV
`secret/keycloak/smtp`. Because Keycloak's realm import does not update an
already-created realm, `prodbox users invite` also patches the live realm's `smtpServer` from
`secret/keycloak/smtp` before it sends an execute-actions email. If the long-lived stack state is
missing while retained fixed-name SES/S3/IAM resources still exist, `aws-ses reconcile` repairs
state by importing the retained capture bucket, SMTP IAM user, SES receipt rule set, and receipt
rule, applying §4.6's fenced committed-key comparison and delete/wait/re-observe/create protocol so
the Haskell interpreter owns at most one fresh retrievable secret, and reconciling
overwrite-tolerant Route 53 verification/DKIM/MX records. The `ValidationKeycloakInvite`
canonical-suite member (Sprint `8.5`) reads inbound capture from the S3 bucket via the same IAM
user (`s3:ListBucket`, `s3:GetObject`, `s3:DeleteObject` on the bucket and its objects).
In aggregate runs, `ValidationKeycloakInvite` must run before destructive
`ValidationChartsStorage` and `ValidationLifecycle` so AWS-substrate invite proof still has
the live `vscode` root chart/Keycloak deployment, a live EKS stack snapshot, and a live
kubeconfig. The Keycloak chart's shared-host auth `HTTPRoute` must include `/auth/admin` because
the operator-owned invite flow creates users through the Keycloak admin API after acquiring its
token from `/auth/realms/master`. `ValidationLifecycle` remains the terminal destructive validation.
The Pulumi program is the exclusive multi-resource stack provisioning surface; SMTP IAM access-key
mutation is exclusively Haskell-interpreted through the harness. Ad-hoc `aws ses *`, `aws s3 *`,
and `aws iam create-access-key|delete-access-key` mutations are not part of the supported path.

## Cross-References

- [AWS Admin Credentials](./aws_admin_credentials.md)
- [AWS Test Environment](./aws_test_environment.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
