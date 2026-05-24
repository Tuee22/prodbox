# Repository Guidelines for Agents

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/pure_fp_standards.md
**Generated sections**: none

> **Purpose**: Agent-facing repository rules for structure, tooling, and coding standards.

`DEVELOPMENT_PLAN/README.md` is the authoritative source for target architecture, sprint status,
and cleanup ownership. The authoritative CLI doctrine is distributed across per-surface
engineering docs under [documents/engineering/](./documents/engineering/README.md): command
topology and reconcilers in `cli_command_surface.md`; Plan / Apply and GADT-indexed state
machines in `pure_fp_standards.md`; subprocesses, error handling, capability classes, and
application environment in `haskell_code_guide.md`; generated artifacts and lint stack in
`code_quality.md`; output rules and at-least-once event processing in `streaming_doctrine.md`;
prerequisites as typed effects in `prerequisite_doctrine.md`; daemon lifecycle in
`distributed_gateway_architecture.md`; testing doctrine in `unit_testing_policy.md`;
toolchain pinning in `dependency_management.md`. The repository is Haskell-only on the
supported path.

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
./.build/prodbox check-code

# Run tests
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
./.build/prodbox test all
```

`prodbox check-code` is the required single entrypoint for doctrine enforcement in local
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

### AWS Substrate Provisioning Is Harness-Owned

- The prodbox test harness is the **exclusive owner** of every AWS resource the project
  touches — IAM, ECR, S3, Route 53, SES, EKS, EC2, the lot. Every AWS API call flows
  through the harness via the `prodbox` command surface. There is no second supported
  owner of AWS resources; no "operator runs `aws` CLI on the side", no ad-hoc `eksctl`
  or `terraform` or `pulumi up`. Resources the harness needs are created by the harness;
  resources the harness no longer needs are destroyed by the harness.
- Supported entrypoints: `prodbox pulumi <stack>-resources` /
  `prodbox pulumi <stack>-destroy --yes` for every Pulumi-managed substrate stack
  (`aws-eks`, `aws-eks-subzone`, `aws-test`, `aws-ses`); `prodbox aws setup` /
  `prodbox aws teardown` for the IAM user provisioning loop; `prodbox test integration
  ... --substrate aws` and `prodbox test all` for end-to-end substrate-aware runs.
- Do not run `pulumi up`, `pulumi destroy`, `aws` CLI mutations, `eksctl`, or any other
  ad-hoc tool to create, modify, or delete AWS resources outside the harness. If a
  needed resource isn't being created, that's a bug in the harness's substrate-platform
  install (extend `Prodbox.Lib.AwsSubstratePlatform`), not an invitation to fix it
  manually.
- Do not manually provision before, or clean up after, a harness run. Re-run the harness
  on failure (its destroy paths are idempotent) or use the canonical
  `prodbox pulumi <stack>-destroy --yes` entrypoint.
- Read-only AWS diagnostics (`aws sts get-caller-identity`, `aws route53 list-hosted-zones`,
  console inspection) are acceptable when investigating a harness-reported failure.

When a `prodbox` AWS subcommand is the documented entrypoint — `prodbox pulumi
<stack>-resources`, `prodbox pulumi <stack>-destroy --yes`, `prodbox aws setup`,
`prodbox aws teardown`, `prodbox test integration ... --substrate aws`, or `prodbox
test all` — invoking it does not need separate user approval beyond the original
request. Live AWS spend, EBS / NAT / ALB provisioning, EKS cluster lifetime, and
SES sending-identity creation are *expected* outcomes of asking the harness to
provision the AWS substrate, not separate gates. The "confirm before mutating
shared infrastructure" rule applies only to ad-hoc tooling that bypasses the
harness — not to invoking the harness itself.

Two AWS resource lifecycle classes — see
[DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
for the authoritative inventory:

- **Per-run stacks** (`aws-eks`, `aws-eks-subzone`, `aws-test`) are auto-managed by
  the harness — provisioned at run start, destroyed at run end on success, failure,
  and Ctrl-C (Sprint `7.6`).
- **Long-lived cross-substrate shared infrastructure** (`aws-ses` + the operator-owned
  Route 53 parent zone) is provisioned once and retained by design (5–30 min DKIM
  propagation per re-provision; single active receive rule set per account; ~24-hour
  S3 bucket name reuse cooldown). Destruction is still through the harness
  (`prodbox pulumi aws-ses-destroy --yes`), just never automatically. A retained SES
  capture bucket is **not orphaned** — it is correctly retained per this class.

### Substrate Equivalence

- The home local substrate and the AWS substrate stand up the **same set of services**:
  the canonical chart set (`gateway`, `keycloak`, `keycloak-postgres`, `vscode`, `api`,
  `redis`, `websocket`) plus the same supporting platform pieces — MinIO, Harbor, the
  Percona PostgreSQL operator, Envoy Gateway, cert-manager, real Let's Encrypt via
  cert-manager DNS01. The two substrates differ in their load-balancer (MetalLB on home,
  AWS Load Balancer Controller on EKS) and their Route 53 hosting (parent zone on home,
  dedicated subzone provisioned by `prodbox pulumi aws-subzone-resources` on AWS).
  Nothing else.
- Harbor + MinIO + Percona are installed on **both** substrates. The AWS substrate is
  not a "no-Harbor" cluster. If `prodbox charts deploy ... --substrate aws` fails because
  chart pods can't reach `127.0.0.1:30080/prodbox/...`, the fix is to bring Harbor
  (and its MinIO storage backend, and the Percona operator) up on EKS via the
  substrate-platform install in `Prodbox.Lib.AwsSubstratePlatform` — not to render
  different image references.
- Chart templates and `Prodbox.Lib.ChartPlatform` use one set of image refs across both
  substrates. Substrate-aware code is responsible for making `127.0.0.1:30080` resolve
  on EKS too (via an EKS-side Harbor plus a node-local registry-mirror pattern
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

- Store AWS auth only in the repository Dhall config (`prodbox-config.dhall`).
- AWS auth must come only from Dhall config; ambient AWS auth env vars, shared-profile discovery,
  and system `aws` CLI host auth state are not valid auth sources for supported `prodbox` flows.
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
| Tear down operational `aws.*` + per-run stacks | exercised automatically by `prodbox test ...` postflight | `prodbox aws teardown` |
| Provision a Pulumi stack | exercised by the harness; no standalone automation alias | `prodbox pulumi <stack>-resources` |
| Destroy a Pulumi stack | `prodbox pulumi <stack>-destroy --yes` (already non-interactive) | same |
| Author repo config | edit `prodbox-config.dhall` against `prodbox-config-types.dhall` | `prodbox config setup` |
| Inspect AWS state | `aws sts get-caller-identity`, `prodbox aws check-quotas` (after `aws.*` populated) | same |

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

## Cross-References

- **CLAUDE.md**: Detailed AI assistant guidelines
- **[documents/engineering/README.md](./documents/engineering/README.md)**: Engineering docs index (canonical CLI doctrine is distributed across these per-surface docs)
- **documents/documentation_standards.md**: Documentation rules
- **documents/engineering/**: Architecture and doctrine documentation
- **[DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md)**: Development plan, sprint status, and cleanup ownership
