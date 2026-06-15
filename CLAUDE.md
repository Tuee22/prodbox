# Claude Code Patterns for Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, documents/engineering/README.md, documents/documentation_standards.md, documents/engineering/dependency_management.md, documents/engineering/pure_fp_standards.md, documents/engineering/unit_testing_policy.md
**Generated sections**: none

> **Purpose**: Guide for Claude Code development on the current `prodbox` worktree baseline.

## Rewrite Posture

- `DEVELOPMENT_PLAN/README.md` is the authoritative live tracker for target architecture, status,
  blockers, and cleanup ownership.
- The authoritative CLI doctrine is distributed across per-surface engineering docs under
  [documents/engineering/](./documents/engineering/README.md): command topology, progressive
  introspection, and reconcilers in `cli_command_surface.md`; Plan / Apply and GADT-indexed
  state machines in `pure_fp_standards.md`; subprocesses, smart constructors, error
  handling, capability classes, retry policy, and application environment in
  `haskell_code_guide.md`; generated artifacts and lint stack in `code_quality.md`; output
  rules and at-least-once event processing in `streaming_doctrine.md`; prerequisites as
  typed effects in `prerequisite_doctrine.md`; daemon lifecycle in
  `distributed_gateway_architecture.md`; the Vault transit-seal trust tree and
  downstream-cluster custody in `cluster_federation_doctrine.md`; testing doctrine in
  `unit_testing_policy.md`; toolchain pinning in `dependency_management.md`. Phase documents
  in `DEVELOPMENT_PLAN/` cite doctrine sections by name when scheduling adoption work.
- The repository is Haskell-only on the supported path. The public CLI, lifecycle runtime, Pulumi
  orchestration, gateway runtime, chart platform, onboarding flow, AWS administration commands,
  and test harness all live under `app/`, `src/Prodbox/`, `test/`, `prodbox.cabal`,
  `cabal.project`, and `docker/`.
- Do not describe removed Python directories or Poetry workflows as the current supported
  architecture.

## Current Worktree Baseline

Prodbox manages a home Kubernetes cluster with a Haskell command surface.

- `app/prodbox/Main.hs` is the executable entrypoint.
- `src/Prodbox/` owns the command parser, runtime modules, infra orchestration, gateway runtime,
  chart platform, AWS administration flows, and test harness.
- `test/` contains the Haskell unit and integration suites.
- `prodbox-config.dhall` is decoded into Haskell types by the native `dhall` library;
  `prodbox-config.json` is not part of the supported interface. The in-force cluster
  configuration is the source of truth, stored as a Vault-Transit-enveloped object in
  MinIO; the filesystem `prodbox-config.dhall` is a seed/propose input only — it seeds the
  encrypted MinIO SSoT on first-ever bring-up, and thereafter supplying a file is a
  proposed update, not the live config. Each binary reads the small unencrypted basics
  locally (cluster id, this cluster's Vault address, seal mode, and for a child the parent
  reference it contacts to auto-unseal), then fetches and decrypts the in-force config from
  MinIO through Vault. In-cluster consumers authenticate to Vault directly via Vault
  Kubernetes auth; there are no Secret-mounted Dhall credential fragments and no master
  seed or HMAC derivation. Updating the root cluster's in-force config requires the root
  Vault token (which requires an unsealed root Vault). No supported binary reads `PRODBOX_*`
  environment variables. See
  [documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md).
- `pulumi/aws-eks/Pulumi.yaml` plus `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Pulumi.yaml`
  plus `pulumi/aws-test/Main.yaml` are the supported Pulumi programs for AWS validation IaC.

## Local Cluster Lifecycle Ownership

**This machine is the home Kubernetes cluster that prodbox manages.** Prodbox owns the full
local-cluster lifecycle on this host.

- `prodbox cluster reconcile` is the canonical idempotent reconcile entrypoint. Running it on this
  machine — including installing RKE2 if it is absent, or reconciling the existing cluster — is
  the supported, expected operation, not an unauthorized state change.
- `prodbox cluster delete --yes` is the canonical teardown. **Default mode is a pure local
  cluster uninstall**: it uninstalls RKE2 and preserves `.data/` (the MinIO-backed per-run
  Pulumi state) **without querying, gating on, or destroying the per-run AWS Pulumi backend** —
  so per-run AWS stacks (if any) are left untouched and remain destroyable afterward via
  `prodbox cluster delete --cascade` or `prodbox aws stack <name> destroy --yes`. Deleting the
  cluster never affects your ability to reason about the backend, since `.data/` is preserved. When
  no RKE2 cluster is installed at all, it is a no-op success (`No RKE2 cluster to delete.`,
  exit 0). `--cascade` is the recommended "clean teardown" path for wipe-and-rebuild cycles:
  K8s drain + per-run destroys + cluster uninstall + postflight tag sweep, all in one atomic
  operator action — it is the only `cluster delete` path that destroys per-run AWS stacks.
  `aws-ses` is never touched by `cluster delete` regardless of flag — its Pulumi state lives in
  the long-lived `pulumi_state_backend` S3 bucket (independent of cluster lifetime). See
  [documents/engineering/lifecycle_reconciliation_doctrine.md](documents/engineering/lifecycle_reconciliation_doctrine.md).
  Every AWS/cluster resource prodbox can create is a registered entry (typed `discover` +
  `destroy`) in the managed-resource registry, and teardown is one idempotent `reconcileAbsent`
  reconciler with "cannot observe" never silently treated as "absent"
  ([lifecycle_reconciliation_doctrine.md § 3.1](documents/engineering/lifecycle_reconciliation_doctrine.md);
  scheduled Sprints 4.20–4.22 / 7.8).
- `prodbox nuke` is the operator-only total-teardown command — the only sanctioned path to
  destroy long-lived shared infrastructure transitively (`aws-ses`, the
  `pulumi_state_backend` bucket). TTY-only; refuses non-interactive contexts; requires the
  typed confirmation literal `NUKE EVERYTHING`; no `--yes` shorthand. Automation contexts must
  compose the canonical commands individually instead.
- `prodbox test all` exercises the full lifecycle (install, validate, reconcile, sometimes
  delete) on this host. It is **expected to start RKE2, etcd, kubelet, containerd, and Pulumi
  flows on this machine**. Do not treat the resulting processes or the running cluster as a
  surprise or as something to roll back.
- `prodbox charts ...` and `prodbox gateway ...` mutate cluster state on this same host by
  design.

When a `prodbox` subcommand is the documented entrypoint for an operation, running it does not
need separate user approval beyond the user's original request. The "confirm before mutating
shared infrastructure" rule applies to ad-hoc shell commands and to operations that bypass the
prodbox surface — not to invoking prodbox itself.

If a `prodbox test all` or other lifecycle run is interrupted mid-flight, prefer letting the
idempotent reconcile finish (or re-running the same command) over manual cleanup.

## AWS Substrate Provisioning Ownership

**The prodbox test harness is the exclusive owner of every AWS resource the project
touches.** Every AWS API call (creates, reads, updates, deletes, IAM, ECR, S3, Route 53,
SES, EKS, EC2, …) flows through the test harness via the `prodbox` command surface.
There is no second supported owner of AWS resources — no "operator runs `aws` CLI on
the side", no "Claude provisions a test bucket", no ad-hoc `eksctl` or `terraform` or
`pulumi up` invocations. Resources the harness needs are created by the harness;
resources the harness no longer needs are destroyed by the harness.

The supported entrypoints are:

- `prodbox aws stack <stack> reconcile` / `prodbox aws stack <stack> destroy --yes` for
  every Pulumi-managed substrate stack (`aws-eks`, `aws-eks-subzone`, `aws-test`,
  `aws-ses`, and any future AWS substrate stacks).
- `prodbox aws setup` / `prodbox aws teardown` for the IAM user provisioning loop.
- `prodbox test integration ... --substrate aws` and `prodbox test all` for the
  end-to-end substrate-aware validation runs.

Rules:

- Do not invoke `pulumi up`, `pulumi destroy`, `pulumi stack`, `aws` CLI mutations,
  `eksctl`, `terraform`, or any other ad-hoc tool to create, modify, or delete AWS
  resources outside the harness. If a needed resource isn't being created, that's a
  bug in the harness's substrate-platform install, not an invitation to fix it
  manually.
- Do not manually provision AWS resources "to set up for" a test or "to fill in a
  gap"; the harness handles provisioning before validations run and teardown after.
- Do not manually clean up AWS resources after a failed run; re-run the harness (its
  destroy paths are idempotent) or use the canonical
  `prodbox aws stack <stack> destroy --yes` entrypoint.
- Read-only AWS diagnostics (`aws sts get-caller-identity`, `aws route53
  list-hosted-zones`, console inspection) are the only ad-hoc commands acceptable —
  and only when investigating why the harness reports a failure.

The same rule applies to any operator-account-shared AWS resources (e.g., the Phase 8
SES sending identity and receive-rule-set): they are owned by their dedicated Pulumi
program under `pulumi/` and reconciled only through `prodbox aws stack ...`, never by
hand.

When a `prodbox` AWS subcommand is the documented entrypoint — `prodbox aws stack
<stack> reconcile`, `prodbox aws stack <stack> destroy --yes`, `prodbox aws setup`,
`prodbox aws teardown`, `prodbox test integration ... --substrate aws`, or
`prodbox test all` — invoking it does not need separate user approval beyond the
user's original request. Live AWS spend, EBS / NAT / ALB provisioning, EKS cluster
lifetime, and SES sending-identity creation are *expected* outcomes of asking the
harness to provision the AWS substrate, not separate gates. The "confirm before
mutating shared infrastructure" rule applies only to ad-hoc tooling that bypasses
the harness — not to invoking the harness itself.

Two AWS resource lifecycle classes — see
[DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
for the authoritative inventory and the rule that no new AWS resource type may be
added by any `prodbox` code path without first appearing there:

- **Per-run stacks** (`aws-eks`, `aws-eks-subzone`, `aws-test`) are auto-managed by
  the harness — provisioned at run start, destroyed at run end on success, failure,
  and Ctrl-C (Sprint `7.6`).
- **Long-lived cross-substrate shared infrastructure** (`aws-ses` + the operator-owned
  Route 53 parent zone) is provisioned once and retained by design. The harness
  explicitly carves these resources out of postflight auto-destroy because SES domain
  identity + DKIM verification takes 5–30 min per provision, only one receive rule
  set may be active per AWS account, and S3 bucket names have a ~24-hour reuse
  cooldown. Destruction is still through the harness (`prodbox aws stack
  aws-ses destroy --yes`), just never automatically. A retained SES capture bucket
  or sending identity is **not orphaned** — it is correctly retained per this class.

## Command Selection: Automation vs Operator-Interactive

`prodbox` has two parallel paths for AWS-substrate work. Automation contexts
(CI, agents, scripted workflows) **must** use the automation column. The
operator-interactive commands refuse to run when stdin is not a TTY and exit
1 with a pointer to the automation equivalent — so if you see one of those
prompts, you have picked the wrong command, not hit a blocker.

| Task | Automation path (harness, non-interactive) | Operator-interactive path |
|------|--------------------------------------------|----------------------------|
| Drive a full AWS-substrate validation run | `prodbox test all --substrate aws` | (no single command — `aws setup` then per-validation, manual) |
| Run one AWS-substrate validation | `prodbox test integration <name> --substrate aws` | (manual after `aws setup`) |
| Initialize operational `aws.*` from `aws_admin_for_test_simulation.*` | exercised automatically by `prodbox test ...` preflight | `prodbox aws setup` |
| Tear down operational `aws.*` + per-run stacks | exercised automatically by `prodbox test ...` postflight | `prodbox aws teardown` |
| Wipe-and-rebuild the local cluster (leak-safe) | `prodbox cluster delete --cascade` (already non-interactive) | same |
| Total teardown including long-lived shared infrastructure | (no automation alias — compose `prodbox aws stack aws-ses destroy --yes` + `prodbox aws teardown` + `prodbox cluster delete --cascade` + long-lived state-bucket cleanup individually) | `prodbox nuke` |
| Provision a Pulumi stack | exercised by the harness; no standalone automation alias | `prodbox aws stack <stack> reconcile` |
| Destroy a Pulumi stack | `prodbox aws stack <stack> destroy --yes` (already non-interactive) | same |
| Author repo config | edit `prodbox-config.dhall` against `prodbox-config-types.dhall` | `prodbox config setup` |
| Inspect AWS state | `aws sts get-caller-identity`, `prodbox aws quotas check` (after `aws.*` populated) | same |

The automation path materializes operational `aws.*` from
`aws_admin_for_test_simulation.*` in `prodbox-config.dhall` via the
suite-level IAM harness, runs validations, then clears `aws.*` and
auto-destroys per-run stacks on suite exit (success, failure, or Ctrl-C).
The retained `aws-ses` long-lived stack is intentionally **not**
auto-destroyed (cross-substrate shared infrastructure). Live AWS spend is
expected; no separate approval needed beyond the user's original request.

**Common mistake**: running `prodbox aws setup` from a non-TTY context and
reporting the interactive prompt as a blocker. The correct response is to
run `prodbox test all --substrate aws` (or the targeted integration
command) — the harness handles credentials non-interactively. The
interactive command will refuse with `exit 1` and the message names the
automation equivalent.

**Common mistake**: attempting to invoke `prodbox nuke` from automation
(CI, agents, scripted workflows). The command refuses non-TTY by design;
it exists only as an operator-driven total-teardown entrypoint that
requires the typed confirmation literal `NUKE EVERYTHING`. Automation
contexts must instead compose the canonical commands individually:
`prodbox aws stack aws-ses destroy --yes`, `prodbox aws teardown`,
`prodbox cluster delete --cascade`, and (if the long-lived
`pulumi_state_backend` bucket should also be destroyed) the explicit
S3 bucket-destroy step.

## Substrate Equivalence

**The home local substrate and the AWS substrate stand up the same set of services.**
Both run the canonical chart set (`gateway`, `keycloak`, `keycloak-postgres`,
`vscode`, `api`, `redis`, `websocket`) plus the same supporting platform pieces:
MinIO, Harbor, the Percona PostgreSQL operator, Envoy Gateway, cert-manager, real
ZeroSSL via cert-manager DNS01. The two substrates differ in their lower-layer
load-balancer (MetalLB on home, AWS Load Balancer Controller on EKS) and their
Route 53 hosting (one parent zone on home, the dedicated subzone provisioned by
`prodbox aws stack aws-subzone reconcile` on AWS) — nothing else.

This means:

- Harbor + MinIO + Percona are installed on **both** substrates. The AWS substrate
  is not a "no-Harbor" cluster; if `prodbox charts reconcile ... --substrate aws`
  fails because chart pods can't reach `127.0.0.1:30080/prodbox/...`, the fix is to
  bring Harbor (and its MinIO storage backend, and the Percona operator) up on EKS
  via the substrate-platform install — not to render different image references.
- The chart templates and `Prodbox.Lib.ChartPlatform` use one set of image refs
  across both substrates: `127.0.0.1:30080/prodbox/...` (the in-cluster Harbor on
  whichever substrate is active). The substrate-aware code in
  `Prodbox.Lib.AwsSubstratePlatform` is responsible for making `127.0.0.1:30080`
  resolve on EKS too (via an EKS-side Harbor + node-local registry proxy, mirroring
  the home cluster's NodePort-on-127.0.0.1 pattern).
- `prodbox edge status`, `prodbox charts reconcile`, and the canonical
  `prodbox test integration ... --substrate aws` validations all assume substrate
  equivalence and route through the same chart-platform code paths.

When something on the AWS substrate looks "missing", the answer is almost always
"the harness needs to install it" — not "the substrates are different, work around
it". The harness owns AWS; if AWS lacks a piece the home cluster has, that's a
Sprint 7.5.b/7.5.c follow-up to extend the harness, never an operator workaround.

## Git Workflow Policy

**CRITICAL: Claude Code is NOT authorized to commit or push changes.**

- Never run `git commit`, `git push`, `git add`, or any git command that modifies repository state.
- Leave all changes as uncommitted working directory changes.

## Pure FP Doctrine

> **SSoT**: [Pure FP Standards](documents/engineering/pure_fp_standards.md)

### Purity Boundary

| Code Location | Purity | Allowed |
|---------------|--------|---------|
| DAG builders, renderers, validation helpers | Pure | No I/O |
| Interpreter and command runners | Effectful | Subprocesses, files, network |
| Main command entrypoints | Effectful | Exit orchestration and user-facing rendering |

### Key Rules

1. Keep side effects at command or interpreter boundaries.
2. Prefer explicit ADTs over ad-hoc strings.
3. Use exhaustive pattern matching.
4. Return structured errors for ordinary control flow.
5. Keep configuration decoding and validation explicit.

## Current Worktree CLI Tool

Canonical developer entrypoints:

```bash
cabal build --builddir=.build exe:prodbox
mkdir -p .build
cp "$(cabal list-bin --builddir=.build exe:prodbox)" .build/prodbox
chmod +x .build/prodbox
./.build/prodbox --help
./.build/prodbox dev check
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
```

Named infrastructure-backed validation commands such as
`./.build/prodbox test integration aws-iam` and
`./.build/prodbox test integration public-dns`
run real native Haskell validation flows and require the environment named by their prerequisite
contracts.

## Testing Philosophy

> **SSoT**: [Unit Testing Policy](documents/engineering/unit_testing_policy.md)

- Pure code should be testable without mocks.
- Built-frontend CLI and env proof lives in `test/integration/Main.hs` through
  `test/integration/CliSuite.hs` and `test/integration/EnvSuite.hs`.
- Named `prodbox test integration ...` commands execute native validation flows through
  `src/Prodbox/TestValidation.hs`.
- Missing prerequisites must fail fast with actionable errors.

## Documentation

- [Development Plan](./DEVELOPMENT_PLAN/README.md)
- [Engineering Docs Index](./documents/engineering/README.md)
- [Documentation Standards](./documents/documentation_standards.md)
- [CLI Command Surface](./documents/engineering/cli_command_surface.md)
- [Unit Testing Policy](./documents/engineering/unit_testing_policy.md)
