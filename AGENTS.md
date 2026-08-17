# Repository Guidelines for Agents

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Agent-facing repository rules for structure, tooling, and coding standards.

`DEVELOPMENT_PLAN/README.md#resume-here` is the sole current sprint-status and resumption ledger;
the rest of the plan suite carries per-sprint closure and cleanup/removal ownership. Stable target
architecture and doctrine are distributed
across the per-surface engineering docs under
[documents/engineering/](./documents/engineering/README.md): command
topology and reconcilers in `cli_command_surface.md`; the target exact-keyed registry, separate
resource/checkpoint/audit observations, closed teardown programs, and durable recover-to-clean
graph in `lifecycle_reconciliation_doctrine.md` (§3); Plan / Apply and GADT-indexed state
machines in `pure_fp_standards.md`; subprocesses, error handling, capability classes, and
application environment in `haskell_code_guide.md`; generated artifacts and lint stack in
`code_quality.md`; output rules and at-least-once event processing in `streaming_doctrine.md`;
prerequisites as typed effects in `prerequisite_doctrine.md`; daemon lifecycle in
`distributed_gateway_architecture.md`; testing doctrine in `unit_testing_policy.md`;
toolchain pinning in `dependency_management.md`. The repository is Haskell-only on the
supported path.

## Live Infrastructure Deployment Is Authorized

**Agents are authorized to deploy, reconcile, and tear down live infrastructure from this
project** — both the local RKE2 Kubernetes cluster on this host and the AWS substrate (EKS, IAM,
Route 53, SES, S3, EC2/EBS) — through the documented `prodbox` entrypoints. This is expected and
supported work; it makes real, persistent state changes to this host and incurs real live AWS
spend, and it does **not** need separate approval beyond the user's original request.

The local RKE2 deployment is the mandatory retained control plane for supported operation. AWS is
an optional target substrate: selecting it never moves lifecycle authority to EKS or to the host
process. Except for the explicit total-decommission path, the local Lifecycle Authority and its
bounded workers/adapters remain available for every AWS-targeted operation.

- Local cluster: `prodbox cluster reconcile` (installs RKE2 if absent and reconciles),
  `prodbox charts reconcile ...`, `prodbox gateway ...`, `prodbox cluster delete --yes`
  and `prodbox cluster delete --cascade --yes`. Running these on this host is the supported,
  expected operation, not an unauthorized state change. The current cascade is a pre-cutover
  implementation: a non-zero result is unresolved and is not evidence that per-run AWS resources
  are absent. Target behavior and rollout status live in
  [DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here).
- AWS substrate + end-to-end: `prodbox test all`, `prodbox test all --substrate aws`,
  `prodbox test integration <name> --substrate aws`, and `prodbox aws stack <cli-verb>
  reconcile` / `destroy --yes` (see [AWS Mutation Is Prodbox-Surface-Owned](#aws-mutation-is-prodbox-surface-owned)).
- When a task needs a running cluster, an unsealed Vault, provisioned AWS, or a live serving/TLS
  proof to validate or qualify, **stand up the live infrastructure through these entrypoints and
  run it — do not report live infrastructure as an out-of-reach blocker.** A long-running
  lifecycle command (a multi-hour `test all` or clean-room deployment-qualification run) is
  in-scope work; launch it (background it if needed) and drive it to completion rather than
  stopping short.

This authorization is scoped to the `prodbox` command surface only. It does **not** relax
the standing guardrails: ad-hoc `aws` / `pulumi` / `eksctl` / `terraform` / `kubectl` mutations
that bypass `prodbox` stay forbidden (AWS) or confirmation-gated (see below), `prodbox nuke`
stays operator-only and TTY-only, and the [Commit Guidelines](#commit-guidelines) (agents never
commit or push) still apply.

## Current Worktree Structure

```text
prodbox/
├── app/prodbox/Main.hs   # Haskell executable entrypoint
├── src/Prodbox/          # Haskell runtime, CLI, infra, and library modules
├── test/                 # Haskell unit and integration test suites
├── documents/            # Engineering documentation
├── DEVELOPMENT_PLAN/     # Plan, phase status, and cleanup ownership
├── docker/               # Canonical container builds under /opt/build
├── prodbox.cabal         # Cabal package definition
├── cabal.project         # Cabal project config
```

Do not describe removed Python directories as the current or target architecture.

## Current Worktree Commands

```bash
# Build the operator binary
cabal build --builddir=.build exe:prodbox
mkdir -p .build
cp "$(cabal list-bin --builddir=.build exe:prodbox)" .build/prodbox
chmod +x .build/prodbox

# Run the canonical quality gate
./.build/prodbox dev check

# Run tests
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
./.build/prodbox test all
```

`prodbox dev check` is the required single entrypoint for doctrine enforcement in local
development.

## Coding Style

### Haskell Baseline

- Use explicit data types and pattern matches.
- Keep side effects at command or interpreter boundaries.
- Prefer small pure helpers around subprocess or rendering logic.
- Add brief comments only when the control flow is non-obvious.

### Data And Control-Flow Doctrine

> **SSoT**: [Pure FP Standards](documents/engineering/pure_fp_standards.md)

- Favor explicit ADTs over stringly-typed control flow.
- Handle all known cases explicitly in pattern matches.
- Return structured errors instead of relying on exceptions for ordinary control flow.
- Keep configuration decoding and validation separate from command execution.

## Testing Guidelines

### Unit Tests

- Test pure helpers in isolation.
- Keep mocks at the subprocess or interpreter boundary.
- Prefer table-shaped assertions over incidental output snapshots.

### Integration Tests

- `test/integration/Main.hs` is the built-frontend Haskell suite entrypoint, with
  `test/integration/CliSuite.hs` and `test/integration/EnvSuite.hs` covering the CLI and
  repository-config proof surfaces.
- Named `prodbox test integration ...` commands run real native Haskell validation flows through
  `src/Prodbox/TestValidation.hs`.
- Missing prerequisites must fail fast with actionable errors.
- Use `./.build/prodbox test unit` when integration prerequisites are unavailable.

### AWS Mutation Is Prodbox-Surface-Owned

- The `prodbox` command surface is the **exclusive mutation boundary** for every prodbox-managed
  AWS resource — IAM, ECR, S3, Route 53, SES, EKS, EC2/EBS, the lot. In the target lifecycle
  design, the CLI, validation harness, recovery flow, cascade, and explicit stack commands are peer
  clients of the registered lifecycle core and its role-specific interpreters. There is no second
  supported mutation owner:
  no "operator runs `aws` CLI on the side", ad-hoc `eksctl`, `terraform`, or `pulumi up`.
- The operator-owned AWS account/domain, externally owned parent hosted zone, and one temporary
  bootstrap credential source are narrow onboarding prerequisites, not prodbox-managed runtime
  resources. Their documented account-console creation is permitted before Authority admission;
  it is neither a Provider fallback nor harness-owned cleanup. Once onboarding hands control to
  the retained Authority, every project-managed AWS mutation remains `prodbox`-surface-owned.
- Every supported AWS command is an authenticated client submission to the retained local
  Lifecycle Authority. Provider effects run only through the fenced Provider Worker or the exact
  permit-indexed adapter/runner assigned to that operation. If the local control plane cannot
  authenticate, durably register, or observe the operation, the command fails closed. It never
  falls back to host-direct `pulumi`, `aws`, `eksctl`, or `terraform` mutation.
- Supported entrypoints: `prodbox aws stack <cli-verb> reconcile` /
  `prodbox aws stack <cli-verb> destroy --yes` for every Pulumi-managed substrate stack:
  `eks` for registry stack `aws-eks`, `aws-subzone` for `aws-eks-subzone`, `test` for
  `aws-test`, and `aws-ses` for `aws-ses`; `prodbox aws setup` /
  `prodbox aws teardown` for the IAM user provisioning loop; `prodbox test integration
  ... --substrate aws` and `prodbox test all` for end-to-end substrate-aware runs.
- Do not run `pulumi up`, `pulumi destroy`, `aws` CLI mutations, `eksctl`, or any other
  ad-hoc tool to create, modify, or delete AWS resources outside the `prodbox` command
  surface. If a needed resource isn't being created, that's a bug in the substrate-platform
  install (extend `Prodbox.Lib.AwsSubstratePlatform`), not an invitation to fix it
  manually.
- Do not manually provision before, or clean up after, a harness run. Use the returned
  `CleanupRunId`/recovery disposition where available, re-run the canonical harness operation, or
  use `prodbox aws stack <stack> destroy --yes`. Invocation or provider exit alone is not a clean
  result; only the command's exact terminal absence evidence proves cleanup.
- Read-only AWS diagnostics (`aws sts get-caller-identity`, `aws route53 list-hosted-zones`,
  console inspection) are acceptable when investigating a harness-reported failure.

When a `prodbox` AWS subcommand is the documented entrypoint — `prodbox aws stack
<stack> reconcile`, `prodbox aws stack <stack> destroy --yes`, `prodbox aws setup`,
`prodbox aws teardown`, `prodbox test integration ... --substrate aws`, or `prodbox
test all` — invoking it does not need separate user approval beyond the original
request. Live AWS spend, EBS / NAT / ALB provisioning, EKS cluster lifetime, and
SES sending-identity creation are *expected* outcomes of asking `prodbox` to
provision the AWS substrate, not separate gates. The "confirm before mutating
shared infrastructure" rule applies only to ad-hoc tooling that bypasses the
`prodbox` surface — not to invoking a documented `prodbox` command.

Lifecycle classes and their exact cleanup owners are not restated here. See
[DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
for the inventory and
[Lifecycle Reconciliation Doctrine §3](documents/engineering/lifecycle_reconciliation_doctrine.md#3-exact-keyed-desired-absence-reconciliation)
for the target completion contract. Entering a cleanup wrapper that schedules work on success,
failure, or Ctrl-C does not turn a partial or unobservable result into proven absence.

### Substrate Equivalence

- The home local substrate and the AWS substrate stand up the **same application/platform service
  set**:
  the canonical chart set (`gateway`, `keycloak`, `keycloak-postgres`, `vscode`, `api`,
  `redis`, `websocket`) plus the same supporting platform pieces — MinIO, the in-cluster
  registry (single-binary `registry:2`), the Percona PostgreSQL operator, Envoy Gateway,
  cert-manager, real ZeroSSL via
  cert-manager DNS01. The two substrates differ in their load-balancer (MetalLB on home,
  AWS Load Balancer Controller on EKS) and their Route 53 hosting (parent zone on home,
  dedicated subzone provisioned by `prodbox aws stack aws-subzone reconcile` on AWS), plus their
  block-storage volume source (`hostPath` on home, pre-created EBS on EKS). Nothing else differs
  within that application/platform projection. Lifecycle control-plane placement is
  intentionally outside this equivalence claim: Lifecycle Authority and Provider Worker remain on
  mandatory local RKE2 while they provision and manage the optional AWS target.
- The in-cluster registry (`registry:2`) + MinIO + Percona are installed on **both**
  substrates. The AWS substrate is not a "no-registry" cluster. If
  `prodbox charts reconcile ... --substrate aws` fails because chart pods can't reach
  `127.0.0.1:30080/prodbox/...`, the fix is to bring the registry
  (and its MinIO storage backend, and the Percona operator) up on EKS via the
  substrate-platform install in `Prodbox.Lib.AwsSubstratePlatform` — not to render
  different image references. The registry has no web UI (no admin route); for continuity
  its namespace and front-door Service are still named `harbor`.
- Chart templates and `Prodbox.Lib.ChartPlatform` use one set of image refs across both
  substrates. Substrate-aware code is responsible for making `127.0.0.1:30080` resolve
  on EKS too (via an EKS-side registry plus a node-local registry-mirror pattern
  matching the home cluster's NodePort-on-127.0.0.1 layout).
- When something on the AWS substrate looks "missing", the fix is almost always
  "extend the harness's substrate-platform install" — never "operator workaround".

### Development Tooling Policy

- Do not use `.github/` workflows or CI automation for this repository during active development.
- Do not use git hooks (including pre-commit); run CLI entrypoints directly.
- See [Code Quality Doctrine](documents/engineering/code_quality.md#2a-development-tooling-policy).

## Commit Guidelines

**CRITICAL: Agents NEVER commit or push.**

- Leave all changes as uncommitted working directory changes.
- Do not run `git commit`, `git push`, or `git add`.
- Do not run git commands that modify repository state.

## Security

- Elevated/admin AWS auth enters `prodbox` only through the interactive `SecretRef.Prompt`.
  Automation may simulate that prompt only through the `aws_admin_for_test_simulation.*`
  fixture in `test-secrets.dhall`; production config never contains that credential.
- Generated operational `aws.*` credentials are written to Vault KV and referenced by typed
  `SecretRef.Vault` values. Ambient AWS auth env vars, shared-profile discovery, and system
  `aws` CLI host auth state are not valid auth sources for supported `prodbox` flows.
- Daemon bootstrap config comes only from a mounted Dhall file at `--config <path>`;
  env-var fallbacks (`PRODBOX_*`, `MINIO_*`, `AWS_*` on the daemon Pod) are forbidden on
  supported paths. See [documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md).
- Validate all external input, especially FQDN and IP address values.
- Keep IAM scopes least-privilege.

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
| Attempt operational `aws.*` + per-run cleanup and preserve/report unresolved results | exercised automatically by `prodbox test ...` postflight | `prodbox aws teardown` |
| Provision a Pulumi stack | exercised by the harness; no standalone automation alias | `prodbox aws stack <cli-verb> reconcile` |
| Destroy a Pulumi stack | `prodbox aws stack <cli-verb> destroy --yes` (already non-interactive) | same |
| Author repo config | edit the binary-sibling `prodbox.dhall` against `prodbox-config-types.dhall` | `prodbox config setup` |
| Inspect AWS state | `aws sts get-caller-identity`, `prodbox aws quotas check` (after `aws.*` populated) | same |

The automation path simulates the operator admin-credential prompt from
`aws_admin_for_test_simulation.*` in `test-secrets.dhall` via the
suite-level IAM harness, mints the operational `aws.*` credential into Vault KV, runs validations, then clears `aws.*` and
uses its cleanup wrapper. Once `runWithAwsHarnessCleanup` is entered, the current
Lifecycle-Authority-backed durable wrapper schedules per-run cleanup on success, failure, or
Ctrl-C. Some preparation mutations still precede that wrapper, so the current harness does not
promise every-exit durable registration.
Scheduling alone never proves resource absence; the target completion contract requires exact
terminal evidence.
The retained `aws-ses` long-lived stack remains intentionally present as cross-substrate shared
infrastructure. Live AWS spend is
expected; no separate approval needed beyond the user's original request.

**Common mistake**: running `prodbox aws setup` from a non-TTY context and
reporting the interactive prompt as a blocker. The correct response is to
run `prodbox test all --substrate aws` (or the targeted integration
command) — the harness handles credentials non-interactively. The
interactive command will refuse with `exit 1` and the message names the
automation equivalent.

## Cross-References

- **[CLAUDE.md](./CLAUDE.md)**: Claude-specific navigation and evidence posture; operational rules remain authoritative here
- **[documents/engineering/README.md](./documents/engineering/README.md)**: Engineering docs index (canonical CLI doctrine is distributed across these per-surface docs)
- **documents/documentation_standards.md**: Documentation rules
- **documents/engineering/**: Architecture and doctrine documentation
- **[DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here)**: sole current sprint-status/resumption ledger and links to cleanup ownership
