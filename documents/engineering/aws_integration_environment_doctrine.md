# AWS Integration Environment Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Define how `prodbox` authenticates to AWS for integration work and how the
> supported AWS validation path creates, owns, and tears down real AWS resources.

## 0. Canonical Doctrine Statements

- Runtime AWS authentication is split across Operational Lifecycle-provider/AWS-DNS01 and
  LongLived Authority-backup/TLS-retention/home Gateway-DNS/home-DNS01 identities, plus the
  deterministic LongLived SMTP IAM identity/policy/bounded-key family and its retained-home
  Transit-sealed source custody. Tier-0
  `prodbox.dhall` carries only non-secret role coordinates, never plaintext, a plaintext-secret
  hash, or a shared credential pointer; test-simulation credentials live in
  `test-secrets.dhall`. The SecretRef model, config split, and secret classification
  are owned by [vault_doctrine.md §3, §4, §13](./vault_doctrine.md) — this document defers to that
  SSoT rather than restating it.
- `prodbox` must not search upward from the current working directory or prefer alternate config
  files.
- There is exactly one runtime path by which elevated/admin AWS power enters `prodbox`: the
  interactive `SecretRef.Prompt` and its authenticated linear ingress. A mode-indexed Credential
  Provisioner receives genesis/backup-repair/operator-material prompts; a separate Admin Action
  Runner receives explicit long-lived destroy/migration, retained-store compatibility, or quota
  prompts; and post-export `prodbox nuke` uses a standalone Decommission Runner. None reads a
  stored admin section from `prodbox.dhall`, and the normal Provider Worker accepts none of those
  permits. Canonical `aws-ses reconcile` does not send an admin prompt to Provider Worker: its
  durable non-credential provider intent uses the Lifecycle-provider generation only to assume its
  fixed role, while a separate backup-receipted `OperatorMaterialPermit` sends deterministic SMTP
  IAM-family work only to Credential Provisioner. A prompted credential is
  held in memory for one command, used once, and discarded — never written to config or Vault.
- `aws_admin_for_test_simulation.*` is a test-harness-only fixture that lives in `test-secrets.dhall`
  and exists solely to drive the interactive UI: it feeds the same temporary-admin prompt a real
  operator answers so the harness can exercise admin-credentialed flows non-interactively. It is
  `TestPlaintext`-class, is never imported by `prodbox.dhall`, never read by a production
  binary, and never stored in Vault. The block specifics are owned by
  [aws_admin_credentials.md](./aws_admin_credentials.md).
- `prodbox test integration aws-iam`, `prodbox test integration <name> --substrate aws`,
  `prodbox test integration all`, and `prodbox test all` share one suite-level IAM harness. It
  observes and retains LongLived identities, reconciles only required missing/explicitly rotating
  material, and revokes Operational identities only after credential-dependent cleanup succeeds or
  observes absence.
- Stateful AWS validation uses explicit credentials rebuilt from decoded settings, not ambient host
  AWS CLI state or shared profile discovery.
- Per-run validation resources are always newly allocated and owned by that run. Registered
  long-lived shared resources are the explicit exception: when a selected validation requires one,
  the harness reconciles its declared desired state through the canonical idempotent command and
  retains it after the run. Unregistered or merely discovered pre-existing resources are never
  valid mutation targets.
- The retained home control plane—Vault, MinIO, Bootstrap Broker when unseal is required, home
  Target Secret Agent, Lifecycle Authority, Authority Backup Adapter, and TLS Retention Adapter
  when TLS custody is involved—must be available before a remote AWS lifecycle operation is
  submitted. Normal Authority admission additionally requires fresh independent backup
  commit/read-back evidence.
  Pulumi checkpoint blobs live in `prodbox-state`, while the Lifecycle Authority aggregate owns
  the operation/fence/outbox state and immutable checkpoint references. A ready gateway is not a
  prerequisite for this capability.
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

### 0.1 Historical Implementation and Correction Record

The dated Sprint and incident bullets below preserve the implemented path that produced the
current migration inventory. Where they mention one operational IAM user, `aws.*`, gateway-backed
state, or direct AWS CLI writers, that wording is historical and does not override the target
identity, authority, DNS-owner, or cleanup boundaries above.

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
- Historical Sprint target, superseded by the final lifecycle split: the credential lifecycle
  moved under the managed-resource registry, but it is not true that every identity is
  `Operational`. Each Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS, and
  cert-manager-DNS01 IAM identity, key, role, Vault generation, and physical-deletion receipt is separately
  registered with exact observe/destroy/read-back. Lifecycle-provider/AWS-DNS01 are `Operational`;
  Authority-backup/TLS-retention/home Gateway-DNS/home-DNS01 are `LongLived`. In that model,
  `prodbox aws setup`/`teardown` are expressed as `reconcileAbsent` reconciliations over the
  appropriate lifecycle-class projection — idempotent on re-run, `Unreachable`-fails-closed. This
  structure prevents an
  interrupted run from leaking one role or deleting a credential needed by another cleanup node.
  The then-current single-user/`aws.*` implementation and the 2026-05-28 incident described in
  this historical section remain provenance, not evidence that the target is already cut over. Doctrine:
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
  same-account `prodbox-ses-lease-session` role, and every provider stage uses a separately bounded
  role session. In the final ownership split Provider/Pulumi reconciles only non-credential
  SES/S3/DNS resources. Credential Provisioner exclusively creates, rotates, remints, or performs
  repair-time key deletion for the deterministic SMTP IAM family and commits its generation only
  after retained-home source-custody read-back. Only Admin Action Runner under `DestroyAwsSes` may
  delete/read back that entire family; explicit destroy, migrate-backend, retained-bucket
  compatibility, and nuke remain separately admin-authorized.
  That historical implementation used the `pulumi_state_backend` S3 bucket for retained
  public-edge TLS objects and as the optional first-touch source for old `aws-ses` checkpoints.
  In the final design the same long-lived bucket also carries mandatory independently credentialed
  Authority ciphertext/receipt copies under a disjoint prefix; it is not the primary Pulumi
  backend or a second Authority SSoT. The `aws-ses migrate-backend`
  compatibility command drives the encrypted wrapper instead of raw MinIO-to-S3 export/import.
  See [lifecycle_reconciliation_doctrine.md → §2 State-Lifetime Rule](lifecycle_reconciliation_doctrine.md).
- **Sprints `4.47`, `5.17`, and `8.10`**: lifecycle class controls teardown, not
  desired-presence preparation. Sprint `4.47` completes the canonical retained-SES transaction and
  provider-presence gate. Sprint `5.17` derives one nested atomic bracketed plan from an
  invite-capable selected validation set and places it before dependent charts on the selected home
  or explicit EKS target. Sprint `8.10` completes exhaustive semantic SES readiness inside that
  bracketed await. Ordinary suite postflight never destroys `aws-ses`. See §4.6.
- Cross-substrate retained state has an explicit authority split. Lifecycle Authority owns the
  durable operation journal, authority epoch/time, narrow mutation fences, Model-B aggregate,
  immutable checkpoint references, provider workflow, and delivery outbox. Its
  `LongLivedCheckpointAuthority` identity contains no gateway URL. The retained-home Target Secret
  Agent owns closed `SesSmtpSource` Transit-sealed custody/rewrap; the selected substrate's one-shot
  Agent worker alone performs allowlisted generation-checked SMTP Vault KV CAS/read-back. Their
  transfer is attestation-encrypted and exposes only ciphertext/typed receipts to Authority. Gateway
  Runtime owns neither role. Observation, admission, and execution use the same operation-indexed
  `CapabilityRef`; a target gateway or separately supplied probe endpoint cannot select authority.
  See §4.5 and
  [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).
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
`aws_admin_for_test_simulation.*` in `test-secrets.dhall` when it reconciles and tears down the
registered role-specific identities. The canonical `prodbox aws stack aws-ses reconcile` is
deliberately split: Provider Worker resolves only the Lifecycle-provider generation to assume the
exact fixed role for non-credential SES/S3/DNS work. Only when SMTP IAM install, rotation, or repair
is required does a separate `OperatorMaterialPermit` route an admin prompt to Credential
Provisioner; a converged family or target restore from retained-home custody requires no re-prompt.

## 2. Authentication Source And Storage Rules

### 2.1 Dhall Configuration Ownership

Tier-0 `prodbox.dhall` carries non-secret account, region, zone, role, and capability coordinates.
Generated provider/DNS AWS keys live only at the role-specific Vault generations
`secret/aws/lifecycle-provider`, `secret/aws/authority-backup-store`,
`secret/aws/tls-retention-store`, `secret/aws/gateway-dns`, and
`secret/aws/cert-manager/<substrate>/dns01`. Lifecycle-provider/AWS-DNS01 are `Operational`;
Authority-backup/TLS-retention/home Gateway-DNS/home-DNS01 are `LongLived`. Authority-backup
genesis/repair uses its dedicated frozen protocol; each normal material generation is delivered by
the Target Secret Agent after a durable backup-receipted `OperatorMaterialPermit`. The config-split and SecretRef model are owned by
[vault_doctrine.md §3, §4](./vault_doctrine.md). The pre-cutover root `aws.*` fields and
`secret/gateway/gateway/aws` path have no target consumer.

Each IAM access-key create is a journaled non-idempotent Credential Provisioner action. Lifecycle
Authority records the finite inventory and create intent first. If AWS applies the create but its
one-time secret response is lost before retained-home sealing, only Credential Provisioner may
delete the observed uncommitted or unrecoverable key during repair, wait for stable absence, and
then remint. Blind create retry and an uncommitted surviving key are forbidden. `DestroyAwsSes` is
the sole separate deletion authority: Admin Action Runner may delete/read back the exact entire
registered SMTP IAM family, but cannot create, rotate, remint, or perform ordinary repair.

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
uses the fixture only when the harness must simulate an SMTP install/rotation/repair prompt for
Credential Provisioner. Its Provider Worker never consumes the fixture and uses the
Lifecycle-provider generation only to assume its fixed non-credential role. The block specifics are owned by
[aws_admin_credentials.md](./aws_admin_credentials.md).

`prodbox config setup` writes/validates Tier-0 and may prompt only for read-only AWS discovery; it
performs no IAM/S3/DNS mutation. `prodbox aws setup`/`teardown`, explicit long-lived
destroy/migration, `prodbox nuke`, and every other admin-credentialed mutation prompt for the
ephemeral temporary-admin credential through `SecretRef.Prompt`; none reads a stored admin section
from `prodbox.dhall`. The raw bytes go only to the permit-selected Credential Provisioner, Admin
Action Runner, or Decommission Runner, never the normal Provider Worker. Canonical `aws-ses
reconcile` prompts only when its distinct material program requires Credential Provisioner; a
non-credential provider reconcile or target restore from retained custody does not.

The harness simulates that prompt from `aws_admin_for_test_simulation.*` in `test-secrets.dhall`;
a missing or partial fixture must fail fast with an actionable error rather than falling back to
ambient AWS auth.

Forbidden storage patterns:

1. Repo-local shell snippets exporting AWS secrets
2. Checked-in example files containing real AWS auth data
3. Temporary credential dumps written into any project directory or config file
4. Reliance on `~/.aws` shared config or cache as the auth source for supported `prodbox` flows
5. `.env` files for AWS credentials

### 2.2 No Ambient Or Profile-Based AWS Auth

The system-installed `aws` CLI may be used by boundary interpreters, but only with a short-lived
subprocess environment built from the already admitted exact identity generation.

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

The same forbidden-env-var posture extends in cluster. On home only, Gateway Runtime obtains the
dedicated Gateway-DNS generation through its Kubernetes-auth role. EKS Gateway DNS mutation is
disabled and receives no Gateway-DNS secret. The provider worker and cert-manager have different
roles and paths. No `AWS_*` environment variable or Secret-mounted `aws.dhall` fragment
selects identity. A boundary interpreter may construct a short-lived subprocess environment from
the already admitted exact generation, but no daemon handler parses config or logs into Vault per
request. A sealed Vault or stale generation fails closed.

## 3. Harness Preflight Contract

### 3.1 Required Harness Checks

Before an AWS-mutating validation runs, the harness must prove:

1. the system `aws` CLI exists when direct AWS CLI operations are required
2. the exact operation resolves one current role-specific identity generation and authority scope
3. that same identity can perform only the lifecycle the validation owns
4. for managed suite-driven runs (`aws-iam`, aggregate suites, and targeted
   `prodbox test integration <name> --substrate aws` validations), the native IAM harness config
   is complete enough to reconcile, seal/read back each ordinary role-specific identity at its exact
   consumer, retain/read back SMTP `SesSmtpSource` custody, and deliver selected-target generations
   from the harness-simulated temporary-admin prompt sourced from
   `aws_admin_for_test_simulation.*` in `test-secrets.dhall`, without falling back to pre-existing
   operational credentials

These are read-only prerequisite checks. A prerequisite may establish that the encrypted backend
can be reached or that required configuration is decodable; it must not reconcile `aws-ses` or any
other AWS resource. Required mutation is a separately narrated preparation-plan action after the
gate. See [Prerequisite Doctrine §4A](./prerequisite_doctrine.md#4a-prerequisitepreparation-boundary).

### 3.2 Required Check Semantics

The required checks map to:

1. tool check: `aws` must be invokable
2. identity auth check: `aws sts get-caller-identity` must succeed with the exact admitted
   generation, and the returned principal must match the capability reference
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

For `aws-eks`, `pulumi`, and `ha-rke2-aws`, permission sufficiency is proven only when the caller can
resolve and use the exact Lifecycle Authority operation capability and the relevant named
`prodbox aws stack` surface can select, inspect, or create the canonical AWS test stack using
settings-defined AWS auth. A raw MinIO socket or ready gateway is not equivalent evidence.

The supported path synchronizes only non-secret validation inputs such as operator-CIDR and
SSH-public-key into the stack with `pulumi config set`. The fenced provider worker acquires the
Lifecycle-provider generation through its own Vault role and projects only its bounded role session
into Pulumi's subprocess environment; no AWS credential lives in Dhall or stack-local config.

The target prerequisite proof submits or observes through the same operation-indexed
`CapabilityRef` used for execution; the provider worker may then run bounded
`pulumi login ... --non-interactive` against its hydrated scratch backend. The historical helper
first confirmed a gateway-mediated encrypted Model-B endpoint; that adapter is a legacy cutover surface and
cannot define target readiness.
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
6. Plain `prodbox cluster delete --yes` is a local-cluster uninstall and neither preflights nor
   mutates AWS stacks. `prodbox cluster delete --cascade --yes` orchestrates typed K8s drain,
   exact DNS cleanup, per-run destroys, cluster uninstall, and fail-closed postflight observation
   as one always-run cleanup plan — the canonical whole-system "wipe and rebuild" path. `aws-ses`
   is retained
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
a test-only fixture. Vault and the dedicated control-plane services become available first. On a
pristine authority, a `GenesisBackupPermit` admits only the mode-indexed Credential Provisioner to
establish the deterministic backup identity/prefix; the separate Backup Adapter must read back the
initial S3 copy before normal admission. Later `OperatorMaterialPermit`s admit the same Job role to
create/rotate the remaining registered identities. For retained SES, it exclusively creates,
rotates, or remints the deterministic SMTP IAM identity, least-privilege policy, and bounded key
family and performs repair-time deletion of uncommitted/unrecoverable keys. In bounded memory it
derives the region-bound closed `SesSmtpSource` from the one-time IAM secret, discards the raw AWS
secret-access-key bytes, and requires a retained-home Transit-sealed source-custody receipt before
committing that family generation. A distinct Admin Action Runner owns explicit SES destroy, legacy
migration/retained-store compatibility, and quota request/status read-back. `DestroyAwsSes` may
delete/read back the exact whole SMTP family only after consumers quiesce, but cannot create,
rotate, remint, or perform ordinary repair. The fenced Provider Worker owns neither prompt nor
identity provisioning. Ordinary generated keys travel only to their exact Agent/Vault consumer;
SMTP target delivery instead uses attestation-encrypted one-shot home/selected Agent workers from
retained custody. Prompted credentials are discarded and never become config, Authority, or disk
state; no path exposes a generic secret export.

The full ordered init → durable setup → mint/seal/deliver → capability proof → dependency-ordered
revoke lifecycle is canonicalized in
[aws_admin_credentials.md §4.2](./aws_admin_credentials.md). This document defers to that SSoT for
the lifecycle; the items below state the credential-boundary invariants the lifecycle obeys.

1. runtime identity is split by operation; shared `aws.*` and `secret/gateway/gateway/aws` are
   pre-cutover legacy
2. `aws_admin_for_test_simulation.*` is the test-harness-only fixture in `test-secrets.dhall`
   (`TestPlaintext`-class) that simulates the ephemeral temporary-admin prompt the real flows
   answer interactively — driving `prodbox test integration aws-iam`,
   `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, and
   `prodbox test all`; where a repository test owns long-lived destroy/migration, quota, or nuke,
   it feeds the corresponding Admin Action/Decommission Runner prompt. Real operations prompt
   rather than reading any stored section. Canonical `aws-ses reconcile` uses the
   Lifecycle-provider generation only to assume the fixed non-credential role; it consumes the
   simulation fixture solely when an install/rotation/repair `OperatorMaterialPermit` requires a
   Credential Provisioner prompt, never for converged target restore from retained custody
3. the validation must fail fast when the `aws_admin_for_test_simulation.*` fixture is missing or
   partial
4. public setup/teardown and explicit admin-authorized destroy/migration commands share the
   interactive temporary-admin source but use disjoint permit/Job interpreters; there is no
   production config-backed admin path
5. every freshly created key remains unusable until its exact target/custody read-back and an
   identity-specific STS/capability proof succeed; SMTP additionally requires retained-home
   source-custody read-back before any selected-target materialization
6. Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS, cert-manager-DNS01, and SMTP IAM
   policies, users/roles, Vault paths, and cleanup nodes are disjoint; a failed or missing role
   cannot fall back to another
7. IAM/key deletion precedes physical destruction of every owned Vault KV-v2 version plus
   metadata deletion/read-back, and credential cleanup waits for every dependent provider/DNS/EBS
   operation. Soft deletion or a new logical tombstone does not count; rotation retains the current
   generation and destroys only dependency-free superseded versions
8. ordinary suite postflight deletes only Operational Lifecycle-provider/AWS-DNS01 identities and
   retains LongLived Authority-backup/TLS-retention/home Gateway-DNS/home-DNS01 identities plus the
   SMTP IAM family and retained-home source custody

### 4.5 Pulumi State Backend Prerequisite

Pulumi checkpoint state is owned through Lifecycle Authority, not a gateway endpoint. The
authority's one bounded CAS aggregate contains the authority epoch, durable operation state,
narrow mutation fence, provider revision/readiness, credential generation, target-delivery outbox,
and references to immutable encrypted checkpoint blobs in `prodbox-state`. Checkpoint bytes are
content-addressed blobs; ordinary workflow transitions update references rather than rewriting a
large checkpoint inside every aggregate CAS.

Every promoted Authority transition and referenced blob also has a mandatory exact ciphertext/
receipt copy in the independently credentialed long-lived S3 backup prefix. The separate Authority
Backup Adapter writes and reads back that copy; core Authority never receives its AWS credential,
and the S3 copy is not a second current-state selector. The shared retained bucket also contains
disjoint `public-edge-tls/<substrate>/<canonical-scope-key>` ciphertext prefixes owned only by the TLS Retention
Adapter. TLS retention stores certificate ciphertext plus a retained-home-Transit-wrapped DEK;
neither S3 lane is a raw Pulumi backend.

`LongLivedCheckpointAuthority` is an authority identity and object namespace, never a transport URL.
Runtime reconnaissance resolves the required observe/submit/CAS operation plus service identity and
scope into one opaque `CapabilityRef kind`; observation, admission, and execution use that same
reference under one absolute deadline. A separately injected health probe, current kube context,
active gateway, or reachable nominal backend cannot redirect the operation. Target-secret custody
uses different capability references: the retained-home Agent owns only the closed
`SesSmtpSource` Transit-sealed source/rewrap lane, and a selected substrate's one-shot worker owns
only closed-schema generation-checked SMTP Vault KV read/CAS/read-back. Authority transports only
attestation-encrypted ciphertext and typed receipts between them; no gateway or generic export
selects either endpoint.

The Lifecycle Authority's fenced provider worker may hydrate an immutable checkpoint into a
RAM-backed scratch backend and invoke the canonical Pulumi program. It commits the outbox intent
before external work, records the observed provider revision afterward, and resolves a lost
response by durable `OperationId`. Gateway Runtime has no MinIO/Pulumi checkpoint routes or
permissions in the target topology.

#### Historical gateway-backed implementation record (legacy cutover surface)

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
for checkpoint and lease operations. `TargetSecretSink` separately carries the selected
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

#### Lifecycle-class and substrate facts that remain in force

The lifecycle class still matters, but it no longer means a separate raw Pulumi backend for
`aws-ses`. Per-run stacks remain harness-owned and auto-destroyed by suite postflight; `aws-ses`
remains long-lived and is destroyed only by an explicit long-lived teardown command. The dedicated
`pulumi_state_backend` S3 bucket configured in `prodbox.dhall` remains the shared long-lived
container for mandatory Authority backup copies and disjoint retained public-edge TLS envelopes,
plus the optional first-touch source for old `aws-ses` checkpoints.

Concretely, this means:

1. For Pulumi stack operations, the retained home control plane and Lifecycle Authority capability
   must be available before any `prodbox aws stack` call. Operator runs `prodbox cluster reconcile`
   once; the command is idempotent and a no-op when the home substrate is already up.
2. The MinIO `prodbox-state` bucket must exist before the first stack is created. The reconcile
   contract ensures this — see § 0 above for the canonical statement.
3. AWS-substrate work does not bootstrap an AWS-side Pulumi backend on the supported path; Pulumi
   sees only the scratch `file://` backend prepared by the encrypted backend wrapper.
4. The long-lived `pulumi_state_backend` bucket is no longer the main `aws-ses` Pulumi checkpoint
   backend. It carries mandatory independent Authority ciphertext/receipt copies and separately
   registered public-edge TLS envelopes, and remains an optional first-touch import source for old
   `aws-ses` state while `prodbox aws stack aws-ses migrate-backend` exists. Migration strips legacy
   secret-bearing Pulumi outputs before the sanitized current checkpoint is committed/read back.
   Once the Authority reference graph proves no operation/current-checkpoint/rollback reference and
   the bounded rollback window expires, fenced GC deletes/read-backs the old immutable primary and
   mandatory-backup blobs; they are never retained as a secret recovery/export surface.
5. An AWS-targeted validation reads and writes the `aws-ses` aggregate and checkpoint references
   through Lifecycle Authority on the retained home control plane. It never seeds long-lived state
   into Gateway Runtime or the target cluster's object-store namespace.
6. Deleting retained TLS means deleting/read-backing only its registered prefix objects/versions
   and TLS identity/policy. The shared bucket is the last Authority-backup decommission node and may
   be deleted only after every registered prefix is authoritatively absent.

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

An invite-capable selected validation derives one durable idempotent SES operation request. The
request is submitted to Lifecycle Authority with an `OperationId`, retained-home SMTP-custody
identity, selected-target identity, exact non-credential provider intent, closed `SesSmtpSource`
schema/generation coordinates, and one absolute deadline that includes queue wait, credential
refresh, provider I/O, propagation observation, custody/target read-back, and response serialization.
A retry with the same ID observes or resumes the same durable operation; a lost response is never
guessed from a timeout.

The target operation evolves through these durable stages:

1. Resolve one `CapabilityRef 'LifecycleSubmit` for the retained Lifecycle Authority, one
   operation-indexed retained-home custody-Agent reference, and one operation-indexed Target Secret
   Agent reference for the explicitly selected substrate. For each capability, the same reference
   used to observe admission is used to execute; no gateway URL, ambient kube context, or separate readiness
   endpoint may be supplied.
2. Commit `OperationStarted` and the non-credential provider-mutation outbox intent before provider
   work begins. Acquire only the narrow provider-mutation permit and a bounded role session, run the
   registered idempotent SES/S3/DNS reconciler, observe the exact provider revision, then commit that
   revision. Provider/Pulumi never creates, imports, adopts, updates, or deletes SMTP IAM resources.
   Release the mutation permit; provider propagation does not hold it.
3. Observe semantic readiness for that committed revision under the remaining absolute deadline.
   `Pending`, `Failed`, and `Unobservable` remain distinct exhaustive states; a ready Pod, reachable
   endpoint, or nominal resource name is not semantic readiness.
4. Under a separate backup-receipted `OperatorMaterialPermit`, Credential Provisioner exclusively
   reconciles the deterministic SMTP IAM identity, least-privilege policy, and bounded key family.
   It alone creates, rotates, or remints material and deletes an uncommitted or unrecoverable key
   during repair. In bounded memory it derives the region-bound closed `SesSmtpSource` from the
   one-time IAM secret and discards the raw AWS secret-access-key bytes; only `SesSmtpSource` crosses
   authenticated linear ingress to a one-shot retained-home Agent worker. It commits the
   credential-family generation only after a payload-specific Transit-sealed source-custody receipt.
   A create with an ambiguous response
   enters durable recovery rather than blind retry.
5. Atomically commit one per-target delivery outbox intent in the authority aggregate. One-shot home
   and selected-target Agent workers transfer the retained payload attestation-encrypted; Authority
   and its outbox see only ciphertext and typed opaque receipts/commitments. Delivery is at least
   once; the selected worker accepts an identical generation as a duplicate, rejects regression or
   same-generation secret change, performs the closed-schema allowlisted Vault KV CAS, and mandates
   read-back. No generic export exists, and a fresh AWS Vault needs neither an admin re-prompt nor
   IAM-key rotation.
6. Record delivery complete only after Lifecycle Authority re-observes the exact target generation
   and version. Then close the operation cleanly after provider and target quiescence. Cancellation,
   expiry, or ambiguity records an explicit recoverable disposition instead of releasing authority
   based on an in-memory assumption.
7. Reconcile dependent charts only after the durable operation reports target delivery complete.
   Ordinary postflight retains `aws-ses`, the entire SMTP IAM identity/policy/key family, and
   retained-home source custody; always-run cleanup observes and resolves nonterminal operations
   without destroying them.

Explicit `DestroyAwsSes` is a distinct backup-receipted `AdminActionPermit`. After consumers are
quiescent, its attested Admin Action Runner is the sole exception to Credential Provisioner's
deletion ownership: it deletes/read-backs the exact registered SMTP IAM key family, identity, and
policy while Provider/Pulumi proves non-credential SES/S3/DNS absence. Only after external
credential absence, and while both Agents remain live, the operation physically destroys every
owned target/source-custody KV-v2 version, deletes/read-backs metadata, and proves absence. Soft
delete or a new logical tombstone cannot close the transition. The runner cannot create, rotate, remint,
or run ordinary repair, and neither it nor `nuke` exposes a generic secret export.

Provider propagation polling and target delivery never hold one 70-minute account-wide lease.
Correctness comes from the durable aggregate, narrow fences, committed outbox, generation checks,
and re-observation. Implementation, epoch cutover, legacy removal, and deployment-qualification
status is owned only by the Development Plan.

#### Historical bracketed implementation record (legacy cutover surface)

> The combined SES lease, operational-credential SMTP sessions, direct selected-target sealing, and
> `SmtpKeyRepairInterpreter` binding below describe the pre-redesign implementation. They do not
> override stages 1–7 above: the target separates non-credential Provider work, Credential
> Provisioner ownership, retained-home `SesSmtpSource` custody, and attested Agent-to-Agent rewrap.

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
2. Resolve the explicit `LongLivedCheckpointAuthority` and `TargetSecretSink`, and prove the
   exact selected target's gateway object-store round trip. On home, the target sink has the
   retained authority identity and endpoint but remains a separate typed value. On AWS, the target
   identity is canonical `aws-eks` and its endpoint is the scoped port-forward. No ambient
   kubeconfig, active-gateway singleton, or endpoint inference selects either role.
3. Acquire the shared cross-process SES lease through `LongLivedCheckpointAuthority`, keyed by AWS
   account, region, and the registered `aws-ses` resource name. The returned owner/fencing grant is
   non-renewable and its validated safe-use deadline covers bounded reconcile, provider-then-semantic
   observation, SMTP commit, cancellation, clock-skew, and safety margins.
4. Invoke the then-canonical idempotent reconciler as `prodbox aws stack aws-ses reconcile`, using
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
   naming the selected `TargetSecretSink`, credential generation, sealed receipt/opaque Agent-HMAC
   commitment reference, deadline, owner, and fence. The pre-cutover `value digest` field is a
   legacy deletion surface and must not contain or expose a raw plaintext/credential hash.
   Revalidate the intent, perform one bounded target-Vault KV CAS carrying only safe metadata, read
   it back, and mark the global intent committed by owner/fence CAS; then release. A sink-local CAS
   is not represented as an atomic global fence.
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

The completed pre-redesign Sprint `4.47` implementation mapped the then-current doctrine to concrete
modules: `ResidueStatus` supplies the flat observations; `DesiredPresence` supplies the total
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
readiness stage. The target cutover preserves its total observations, finite-inventory repair, and
read-back properties while removing combined Provider/SMTP authority and direct target-only custody.

The safety fold retained from that implementation never treats SMTP access-key create as retry-safe.
In the target, Credential Provisioner alone interprets that repair fold. The committed state includes the
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
5. the suite's durable always-run cleanup plan, or operator
   `prodbox cluster delete --cascade --yes`, as the whole-system destroy path before backend
   teardown; plain `cluster delete --yes` is local-only

### 5.3 Cleanup Must Run After Validation Failure

Cleanup must still run when a validation fails part-way through.

Before each mutation, the runner registers its cleanup obligation in a pure validated cleanup DAG.
The interpreter stops new suite operations, resolves nonterminal Lifecycle Authority operations,
restores the retained home control plane/application charts, destroys per-run stacks and test EBS,
removes each `Operational` role-specific IAM identity only after its credential-dependent cleanup,
physically destroys each owned Vault KV-v2 version and deletes/read-backs its metadata, observes the
`LongLived` backup/TLS/home DNS identities
retained, then re-observes every owned
lifecycle class. Every ready cleanup node runs even if an independent sibling fails; only a node
whose dependency failed is skipped, with an explicit reason.

Route 53 and Pulumi cleanup still use the public command surfaces. Aggregate suites and targeted
`prodbox test integration <name> --substrate aws` validations use the same plan. If prerequisite
validation fails after IAM setup, every role-specific IAM/key/Vault-generation cleanup obligation
remains registered with its lifecycle class: Operational deletion runs after all
credential-dependent cleanup that can still be attempted, while LongLived obligations verify
retention and current consumers rather than delete them.

### 5.4 Cleanup Failure Handling

Cleanup must always be attempted. Warning-only teardown is prohibited. The final report preserves
the original suite failure and aggregates every cleanup failure; one failed destroy cannot suppress
independent cleanup. Dependency-blocked nodes report the exact blocker. A Route 53 cleanup, Pulumi
destroy, authority recovery, target read-back, or final residue observation failure therefore makes
the suite fail with explicit target and error text.

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

These are provider-interpreter leaves, not prerequisite effects or operator runbook steps. The
hosted-zone canary is a visible Sprint-`5.18` preparation resource registered before create with
always-run delete/absence read-back; exact A/TXT record changes likewise execute only through their
registered owner. The current `bracketOnError` canary carve-out is pre-cutover legacy.

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
and deterministic SMTP IAM identity/policy/bounded-key family are account-scoped resources shared
across every substrate that runs `ValidationKeycloakInvite`. Their ownership is deliberately split.
The Provider/Pulumi program sourced from `pulumi/aws-ses/` owns only non-credential SES/S3/DNS
resources; it must never declare, import, adopt, update, or delete the SMTP IAM family. Credential
Provisioner exclusively installs, rotates, remints, and repair-deletes that family under
`OperatorMaterialPermit`; Admin Action Runner may delete/read back the entire family only under
`DestroyAwsSes`. The supported orchestration entrypoints remain `prodbox aws stack aws-ses
reconcile` and `prodbox aws stack aws-ses destroy --yes`, operated through
`src/Prodbox/Infra/AwsSesStack.hs`. The operator-supplied non-secret inputs are
`ses.sender_domain`, `ses.receive_subdomain`, and `ses.capture_bucket` in
`prodbox.dhall`; the parent Route 53 zone (`route53.zone_id`) carries the MX records for
the receive subdomain.

The suite preparation and retention contract is §4.6. In particular, invite-capable suites invoke
the canonical durable lifecycle operation themselves after Lifecycle Authority and the selected
Target Secret Agent capability are admissible; a missing stack is not an operator-repair
prerequisite. The corresponding read-only prerequisites validate tools, configuration, and the
exact operation-indexed capability references—not nominal endpoints or separately injected probes.

In the target implementation Lifecycle Authority's pure `decide`/`evolve` aggregate commits the
provider revision, semantic-readiness result, SMTP credential-family generation, retained-home
source-custody receipt, and per-target delivery outbox. Its interpreters remain disjoint:

- Provider Worker receives only the typed non-credential SES/S3/DNS intent and bounded role session.
- Credential Provisioner receives only the exact SMTP-family `OperatorMaterialPermit` and admin
  prompt. It derives the region-bound closed `SesSmtpSource` in bounded memory from the one-time IAM
  secret, then discards the raw AWS secret-access-key bytes; the retained-home Agent receives and
  Transit-seals only `SesSmtpSource`.
- One-shot retained-home and selected-target Agent workers transfer that payload
  attestation-encrypted. Authority/outbox sees only ciphertext and typed opaque receipts; the
  selected worker alone materializes/read-backs `secret/keycloak/smtp`. A fresh AWS Vault therefore
  needs neither an admin re-prompt nor IAM-key rotation, and no generic secret export exists.
- After consumer quiescence, `DestroyAwsSes` deletes/read-backs the external SMTP key/identity/policy
  and proves the non-credential family absent. Only then, while both Agents remain live, it
  physically destroys every owned target/custody KV-v2 version, deletes/read-backs metadata, and
  proves absence. Soft delete or a new logical tombstone is forbidden; rotation retains the current
  generation and destroys only dependency-free superseded versions. `nuke` obeys the same external-first order through its signed decommission manifest.

Destructive `ValidationLifecycle` remains terminal after invite proof. In aggregate runs,
`ValidationKeycloakInvite` must precede `ValidationChartsStorage` and `ValidationLifecycle` so the
selected Keycloak deployment and capture proof remain live. The shared-host auth `HTTPRoute`
includes `/auth/admin` because the operator-owned invite flow creates users through the Keycloak
admin API after acquiring its token from `/auth/realms/master`.

#### Historical module binding (legacy cutover surface)

The pre-redesign binding made Pulumi own/import the SMTP IAM user and policy, placed access-key
repair in `Prodbox.Lifecycle.SmtpKeyRepairInterpreter` under the combined `AwsSesStack` lease, wrote
the derived SMTP payload directly to the selected target, and reused that IAM user for capture
bucket reads. Those are cutover/deletion surfaces, not target ownership. The replacement must retain
the finite-inventory/delete-wait-reobserve safety fold while moving the entire SMTP identity,
least-privilege policy, key family, and repair deletion behind Credential Provisioner and adding
retained-home `SesSmtpSource` custody. Missing-checkpoint provider recovery imports only the
registered non-credential capture bucket, SES identity/rules, and DNS records. Ad-hoc `aws ses *`,
`aws s3 *`, and `aws iam create-access-key|delete-access-key` mutations remain unsupported.

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [AWS Admin Credentials](./aws_admin_credentials.md)
- [AWS Test Environment](./aws_test_environment.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
