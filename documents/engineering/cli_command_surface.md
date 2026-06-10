# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/00-overview.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/cli/commands.md, documents/documentation_standards.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/code_quality.md, documents/engineering/dependency_management.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/pure_fp_standards.md, documents/engineering/secret_derivation_doctrine.md, documents/engineering/streaming_doctrine.md, documents/engineering/unit_testing_policy.md
**Generated sections**: `command-surface-toplevel`, `command-surface-matrix`

> **Purpose**: Define the explicit, no-passthrough command surface for `prodbox`.

## 1. Command Surface Statement

`prodbox` CLI commands accept only explicitly declared arguments and options at the parser
boundary; passthrough to downstream tools is prohibited.

The CLI surface is intentionally closed:

1. Unknown extra arguments fail at the CLI parser boundary.
2. Invoking a command group without a subcommand displays help instead of running an implicit
   default.
3. Every supported test subset is exposed as a named command, not as a raw file selector.

Current implementation:

- `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`,
  `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs` own the public parser, request ADT,
  registry, and command dispatch.
- `src/Prodbox/CLI/Spec.hs` is the typed `CommandSpec` source of truth for the supported command
  tree, and `src/Prodbox/CLI/Parser.hs` renders that registry over `optparse-applicative`.
- The frontend request ADT routes only to native Haskell commands; no Python delegation branch
  survives in the parser or entrypoint.
- Runtime ownership lives in Haskell modules under `src/Prodbox/`.
- Named test validations live in `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and
  `src/Prodbox/TestValidation.hs`.

This document defines the supported command contract only. Sequencing, completion status, and
cleanup ownership are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 2. Global Surface

Top-level invocation:

```text
prodbox [--verbose|-v] [--version] <command> ...
```

Top-level commands (generated from `commandRegistry`; the `Purpose` column
is each command's registry summary):

<!-- prodbox:command-surface-toplevel:start -->
| Command | Kind | Purpose |
|---------|------|---------|
| `aws` | Group | AWS IAM and quota management |
| `charts` | Group | Bespoke Helm chart lifecycle |
| `check-code` | Command | Run policy, lint, and type checks |
| `commands` | Command | Render the command registry |
| `config` | Group | Configuration management |
| `dns` | Group | Route 53 inspection |
| `docs` | Group | Generated-documentation maintenance |
| `gateway` | Group | Gateway daemon operations |
| `help` | Command | Render help for a command path |
| `host` | Group | Host prerequisite checks |
| `k8s` | Group | Kubernetes helpers |
| `lint` | Group | Doctrine lint surfaces |
| `nuke` | Command | Total teardown of every prodbox-owned AWS resource (operator-only) |
| `pulumi` | Group | AWS validation stack lifecycle |
| `rke2` | Group | Local cluster lifecycle |
| `test` | Group | Named test suites |
| `tla-check` | Command | Run TLA+ checks |
| `users` | Group | Operator-invited user management |
| `workload` | Group | Internal public workload runtime |
<!-- prodbox:command-surface-toplevel:end -->

## 2A. Operator Vocabulary Contract

Every string the operator can read at the terminal must use **operator
vocabulary**, not development-plan tracking vocabulary. Sprint
identifiers, phase numbers, and other dev-plan tracking labels are
confined to `DEVELOPMENT_PLAN/` and the governed engineering docs;
they must not leak into the binary or its generated artifacts.

### Operator-facing surfaces

The contract applies to every one of these surfaces:

- `prodbox <command> --help` output and any text in
  `src/Prodbox/CLI/Spec.hs` that contributes to it (flag-help
  strings, leaf descriptions, example help, group descriptions).
- Manpages under `share/man/man1/*.1`.
- Shell completions under `share/completion/{bash,zsh,fish}/*`.
- The generated CLI command reference at `documents/cli/commands.md`.
- Test goldens that capture operator-facing output at
  `test/golden/cli/*` (`commands.json`, `commands-tree.txt`,
  `help-all.txt`).
- Anything the binary writes to `stdout` / `stderr` at runtime,
  including phase banners, refusal messages, and the dry-run /
  plan-file renderers (`runNativeDeleteCascade`, `renderNukePlan`,
  `renderPreconditionFailures`, `renderTagSweepRefusal`,
  `renderDrainTimeoutRefusal`).

### Forbidden vocabulary in operator-facing strings

- Literal `Sprint <number>` or `Sprints <list>` (regardless of decimal
  depth: `4.11`, `7.5.c.v.f`, etc.).
- Phase numbers in the form `Phase <N>` when used as a tracking
  identifier rather than as part of an operator-visible "phase
  banner" the binary itself writes (e.g., `Phase 1/2 prerequisites`
  is fine; `Phase 7 substrate work` is not — the latter is a
  dev-plan label).
- Direct cross-references to `DEVELOPMENT_PLAN/` from the binary's
  output (operator should not have to read the dev-plan to act on a
  message; if the operator needs guidance, the message links to
  governed engineering docs under `documents/engineering/`).

### Required operator vocabulary

- Describe what the command does, what flags mean, what failure
  modes look like, what state changed.
- For refusals, name the canonical remedy command (`prodbox pulumi
  <stack>-destroy --yes`, `prodbox rke2 delete --cascade`, etc.) so
  the operator can re-run.
- For runbook references, link to operator-meaningful entries under
  `documents/` or operator-facing manpages — never `DEVELOPMENT_PLAN/`.

### Enforcement

`prodbox check-code` enforces this contract with a regex scan over
the operator-facing surfaces listed above. Any literal `Sprint
[0-9]` (case-sensitive, word-boundaried) or `Sprints [0-9]` outside
of comments-in-code or governed dev-plan files fails the gate. The
scan is implemented in `src/Prodbox/CheckCode.hs` alongside the
existing doctrine-alignment scans (forbidden subprocess primitives,
direct-stderr-write rules, generated-section integrity).

The contract does **not** apply to:

- Source-code comments and Haddock haddocks. These are developer
  documentation and routinely cite sprint identifiers for
  archaeology.
- `DEVELOPMENT_PLAN/` and every file under it.
- The governed engineering docs under `documents/engineering/`.
- `legacy-tracking-for-deletion.md` cleanup-ledger entries.

## 3. Command Matrix

> §2 (top-level command list) and the per-group matrix below are the
> **registry-derived operator surface** — every row is generated from the
> typed `commandRegistry` in `src/Prodbox/CLI/Spec.hs`, not hand-edited.
> `prodbox docs generate` rewrites the marker-delimited generated section
> below from `commandRegistry` (rendered by
> `renderCommandSurfaceMatrix` in `src/Prodbox/CLI/Docs.hs`), and
> `prodbox docs check` / `prodbox check-code` fail the build if it drifts
> from the parser. The "Arguments" column is sourced from each leaf
> command's typed positional `ArgumentSpec` list; the "Options" column
> lists each leaf's long flags. The per-command prose notes that follow
> each generated group table — owner modules, refuse-path semantics,
> lifecycle ordering, and the operator-vocabulary contract — are
> hand-maintained and intentionally live OUTSIDE the markers.

The per-group command matrix (generated; do not edit by hand):

<!-- prodbox:command-surface-matrix:start -->
### `prodbox aws`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox aws policy` | none | `--tier` |
| `prodbox aws setup` | none | `--tier`, `--dry-run`, `--plan-file` |
| `prodbox aws teardown` | none | `--dry-run`, `--plan-file`, `--destroy-pulumi-residue`, `--allow-pulumi-residue` |
| `prodbox aws check-quotas` | none | none |
| `prodbox aws request-quotas` | none | `--tier` |

### `prodbox charts`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox charts list` | none | none |
| `prodbox charts status` | `CHART` | none |
| `prodbox charts deploy` | `CHART` | `--dry-run`, `--plan-file`, `--substrate` |
| `prodbox charts delete` | `CHART` | `--yes`, `--dry-run`, `--plan-file`, `--substrate` |

### `prodbox check-code`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox check-code` | none | none |

### `prodbox commands`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox commands` | none | `--tree`, `--json` |

### `prodbox config`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox config setup` | none | `--dry-run`, `--plan-file` |
| `prodbox config show` | none | `--show-secrets` |
| `prodbox config validate` | none | none |

### `prodbox dns`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox dns check` | none | none |

### `prodbox docs`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox docs check` | none | none |
| `prodbox docs generate` | none | none |

### `prodbox gateway`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox gateway start` | none | `--config`, `--dry-run`, `--plan-file` |
| `prodbox gateway status` | none | `--config` |
| `prodbox gateway config-gen` | `OUTPUT_PATH` | `--node-id` |

### `prodbox help`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox help` | `COMMAND_PATH...` | none |

### `prodbox host`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox host ensure-tools` | none | none |
| `prodbox host check-ports` | none | none |
| `prodbox host info` | none | none |
| `prodbox host firewall gateway-restrict` | none | `--port` |
| `prodbox host firewall gateway-unrestrict` | none | `--port` |
| `prodbox host public-edge` | none | `--substrate` |

### `prodbox k8s`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox k8s health` | none | none |
| `prodbox k8s wait` | none | `--timeout`, `--namespace` |
| `prodbox k8s logs` | none | `--namespace`, `--tail` |

### `prodbox lint`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox lint all` | none | none |
| `prodbox lint files` | none | `--write` |
| `prodbox lint docs` | none | `--write` |
| `prodbox lint haskell` | none | `--write` |
| `prodbox lint chart` | none | none |

### `prodbox nuke`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox nuke` | none | `--dry-run`, `--plan-file` |

### `prodbox pulumi`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox pulumi eks-resources` | none | `--dry-run`, `--plan-file` |
| `prodbox pulumi eks-destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox pulumi test-resources` | none | `--dry-run`, `--plan-file` |
| `prodbox pulumi test-destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox pulumi aws-subzone-resources` | none | `--dry-run`, `--plan-file` |
| `prodbox pulumi aws-subzone-destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox pulumi aws-ses-resources` | none | `--dry-run`, `--plan-file` |
| `prodbox pulumi aws-ses-destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox pulumi aws-ses-migrate-backend` | none | `--dry-run`, `--plan-file` |

### `prodbox rke2`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox rke2 status` | none | none |
| `prodbox rke2 start` | none | none |
| `prodbox rke2 stop` | none | none |
| `prodbox rke2 restart` | none | none |
| `prodbox rke2 reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox rke2 delete` | none | `--yes`, `--cascade`, `--allow-pulumi-residue`, `--dry-run`, `--plan-file` |
| `prodbox rke2 logs` | none | `--lines` |

### `prodbox test`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox test all` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test lint` | none | none |
| `prodbox test unit` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration all` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration cli` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration aws-iam` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration dns-aws` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration aws-eks` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration env` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration gateway-daemon` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration gateway-pods` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration gateway-partition` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration ha-rke2-aws` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration lifecycle` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration pulumi` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-storage` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-platform` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-vscode` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-api` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-websocket` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration admin-routes` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration public-dns` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration keycloak-invite` | none | `--coverage`, `--cov-fail-under`, `--substrate` |

### `prodbox tla-check`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox tla-check` | none | none |

### `prodbox users`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox users invite` | `EMAIL` | `--role`, `--dry-run`, `--plan-file` |
| `prodbox users list` | none | `--status`, `--status-unverified` |
| `prodbox users revoke` | `EMAIL_OR_USER_ID` | `--delete`, `--dry-run`, `--plan-file` |

### `prodbox workload`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox workload start` | none | `--config` |
<!-- prodbox:command-surface-matrix:end -->

### `prodbox config` notes

`src/Prodbox/Aws.hs` owns `config setup`. `src/Prodbox/Settings.hs` owns `config show` and
`config validate`. `prodbox config compile` is not part of the supported command surface. The
supported public `config setup` path prompts for one temporary admin AWS credential set when
needed; stored `aws_admin_for_test_simulation.*` remains reserved for suite-driven destructive
validation and long-lived stack/`prodbox nuke` flows, not ordinary onboarding.

### `prodbox aws` notes

`src/Prodbox/Aws.hs` owns the full public `prodbox aws ...` surface. The supported public contract
is prompt-driven for temporary admin AWS credentials; stored
`aws_admin_for_test_simulation.*` is not part of the intended public `aws setup` flow.

`prodbox aws teardown` carries the Sprint `7.6` orphan-safety refuse-path: it refuses to delete
the operational IAM user while any Pulumi-managed stack (`aws-eks`, `aws-eks-subzone`,
`aws-test`, `aws-ses`) still reports live resources, naming the offending stack(s) and the
canonical destroy command. Three residue-policy outcomes are available, all driven by
mutually-exclusive flags:

- (default, no flag) → **refuse** with actionable message.
- `--destroy-pulumi-residue` → **destroy first**: dispatch `prodbox pulumi <stack>-destroy
  --yes` for each live stack in canonical order (`aws-subzone`, `aws-eks`, `aws-test`,
  `aws-ses` if live) before continuing with the IAM teardown. A stderr warning fires before
  the `aws-ses` destroy because reprovisioning it costs 5-30 min of SES DKIM re-verification
  + ~24h of S3 bucket-name cooldown.
- `--allow-pulumi-residue` → **accept orphan**: operator-acknowledged bypass.

The two flags are mutually exclusive at parse time: passing both produces "Invalid option"
exit 1 from optparse-applicative via the `flag' <|> flag' <|> pure RefuseOnAnyResidue` idiom
in `awsTeardownFlagsParser`. The `prodbox aws teardown --help` usage line displays them as
`[--destroy-pulumi-residue | --allow-pulumi-residue]` to make the exclusivity visible.

Sprint `7.7` also moved the file-based residue check **before** the temporary-admin-credential
prompt and added a "Nothing to do." exit (zero) when residue is empty AND operational
`aws.*` is empty, so the operator never enters credentials that the tool was about to refuse.
The credential prompt itself auto-detects the access-key prefix and only asks for a session
token when the operator pastes an `ASIA…` (STS-derived) key — `AKIA…` (long-lived IAM user
key) skips the session-token prompt entirely.

### `prodbox host` notes

`src/Prodbox/Host.hs` owns the full public `prodbox host ...` surface.

`prodbox host firewall gateway-restrict` (Sprint `2.18`) is the idempotent installer for
the iptables INPUT-DROP rule that restricts the gateway-service NodePort to `127.0.0.1`
on the operator host. `prodbox host firewall gateway-unrestrict` is its inverse — the
idempotent remover of that INPUT-DROP rule. Both take an optional `--port` knob
(default the pinned gateway NodePort) so the rule and its removal target the same port.
`prodbox rke2 reconcile` invokes the installer as part of the host post-install phase;
`prodbox rke2 delete --yes` removes the rule on clean teardown. The rule survives reboot
via `iptables-save` to the host's persistence path. Authoritative contract:
[Secret Derivation Doctrine](./secret_derivation_doctrine.md) §5.

The target public-edge doctrine for that surface is defined in
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md). `prodbox host public-edge`
classifies Route 53 ownership, Envoy Gateway readiness, Gateway API attachment, HTTP redirect
listener readiness, HTTPS listener readiness, redirect `HTTPRoute` acceptance, `SecurityPolicy`
attachment, certificate readiness, the shared-host `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`,
and `/minio` routes, and readiness for named external proof.

### `prodbox rke2` notes

`src/Prodbox/CLI/Rke2.hs` owns the full public `prodbox rke2 ...` surface.

`prodbox rke2 reconcile` is the canonical lifecycle reconciler. `install`, `upgrade`, `repair`,
and `force-install` are forbidden sister commands rejected at parse time.

`prodbox rke2 delete --yes` is hermetic on success: when
`/usr/local/bin/rke2-uninstall.sh` exits `0`, only the doctrine-owned summary lines reach the
operator terminal — `Deleting local RKE2 environment...`, the AWS EKS and AWS test stack destroy
dispositions, `Local RKE2 substrate: cleanup complete`, the kubeconfig disposition, and the
`Preserved host state:` boundary. Benign upstream uninstall chatter the uninstaller writes to its
own stdout/stderr — `Cannot find device "cni0"`, `semodule: not found`, and
`Cleanup completed successfully` — is captured through the lifecycle-local quiet path in
`src/Prodbox/CLI/Rke2.hs` (`captureToolOutput` plus `isIgnorableRke2DeleteNoiseLine`) and never
surfaces as a red-herring error. The inotify warning `Failed to allocate directory watch: Too many
open files` is the exception: the systemd manager (PID 1) / journald emits it out-of-band to the
console rather than through the uninstaller's captured fds, so `captureToolOutput` cannot suppress
it and it may still appear on the operator terminal on a successful run (benign — teardown still
succeeds; the filter entry only catches the line on the rare path where systemd routes it to the
captured stderr). When the uninstaller exits non-zero, the actionable upstream lines are still
surfaced through `summarizeRke2DeleteFailure` so the operator can act on the real failure.

`prodbox rke2 delete` carries the Sprint `4.11` refuse-path (planned; symmetric to the Sprint
`7.6` `aws teardown` refuse-path). It refuses to proceed when any per-run Pulumi stack
(`aws-eks`, `aws-eks-subzone`, `aws-test`) reports live resources, naming each offending stack
and the canonical destroy command. Three mutating modes are available; they are mutually
exclusive at parse time:

Before any of the three modes below, `prodbox rke2 delete` probes for an installed RKE2 (the
on-disk markers `/usr/local/bin/rke2`, `/usr/local/bin/rke2-uninstall.sh`,
`/var/lib/rancher/rke2`, `/etc/rancher/rke2`). When none is present — there is no cluster to
delete — it prints `No RKE2 cluster to delete.` and exits `0` without consulting the residue
gate or starting the cascade. This is a no-op short-circuit, not a weakening of the fail-closed
gate: an installed-but-stopped RKE2 still flows through the full path below. See
[lifecycle_reconciliation_doctrine.md](lifecycle_reconciliation_doctrine.md) §5a.

- (default, no flag) → **refuse** with the actionable per-stack remedy list. The cluster is
  not touched; the operator runs the named `prodbox pulumi <stack>-destroy --yes` commands
  while the MinIO backend for those stacks is still up.
- `--cascade` → **orchestrate the full clean teardown**. Sprints `4.17.a` / `4.17.b`
  establish the doctrine-canonical drain-before-destroys order with substrate-aware
  drain kubeconfig handling. Canonical order: (1) confirm MinIO reachable and query
  `<stack>ResidueStatus` (Sprint `4.16`) for each per-run stack; (2) K8s drain phase
  (Sprint `4.12`) — delete LoadBalancer Services, Ingresses, and Delete-reclaim PVCs
  cluster-wide, against the substrate's own kubeconfig (the local RKE2 kubeconfig for
  `SubstrateHomeLocal`, the EKS kubeconfig wrapped in
  `Prodbox.PublicEdge.withSubstrateKubectlEnvironment` for `SubstrateAws`), so the
  in-cluster controllers unwind their AWS-side ENIs / ALBs / EBS volumes while still
  alive; (3) `prodbox pulumi <stack>-destroy --yes` for stacks reporting
  `ResiduePresent`, wrapped in `withMaterializedOperationalCreds` so empty operational
  `aws.*` is filled transparently from `aws_admin_for_test_simulation.*` and restored
  on exit; (4) cluster uninstall; (5) postflight tag sweep that fails the command if
  any cluster-tagged AWS resource survives. The
  [Lifecycle Reconciliation Doctrine](lifecycle_reconciliation_doctrine.md) §5b is the
  authoritative cascade-order reference. This is the recommended path for
  wipe-and-rebuild cycles.
- `--allow-pulumi-residue` → **operator-acknowledged orphan**. Bypass the refuse-path; per-run
  stacks become orphaned (their MinIO backend dies with the cluster). Recovery-only.

All three modes route through `runPlanWithOptions` (Sprint `4.26`), so `--dry-run` renders the
full destructive plan and exits `0` **without mutating** (the no-RKE2 short-circuit, the
refuse-gate, and the cascade orchestration all live inside the apply closure), and `--plan-file`
writes the rendered plan. The default-delete per-run sweep and the rendered plan's
`per_run_destroy` steps are derived from the managed-resource registry's `PerRun` class, so they
cannot omit `aws-eks-subzone`. The `checkPlanOptionsHonored` lint
([code_quality.md](code_quality.md)) forbids any destructive dispatch arm from wildcarding its
`PlanOptions` away, the regression guard for the historical
`rke2 delete --yes --dry-run`-silently-mutates bug.

`aws-ses` is **explicitly excluded** from `prodbox rke2 delete`'s residue scope regardless of
flag. Its Pulumi state lives in the dedicated long-lived S3 bucket (Sprint `4.10`), so cluster
wipes do not orphan it. Sanctioned destroy paths for `aws-ses` are
`prodbox pulumi aws-ses-destroy --yes` (explicit) and `prodbox nuke` (total teardown). See
[lifecycle_reconciliation_doctrine.md](lifecycle_reconciliation_doctrine.md) for the
predicate library and the full leak-class inventory.

### `prodbox nuke` notes

`src/Prodbox/CLI/Nuke.hs` (Sprint `4.13`, planned) owns the operator-only total-teardown
surface. `prodbox nuke` is the **only** sanctioned command that destroys long-lived shared
infrastructure transitively (`aws-ses` stack, the long-lived `pulumi_state_backend` bucket).
For per-stack teardown of `aws-ses` alone, use `prodbox pulumi aws-ses-destroy --yes`.
Its admin AWS credential source is `prodbox-config.dhall::aws_admin_for_test_simulation.*`,
matching the long-lived stack operations and suite-driven destructive validations; it does not
prompt for admin credentials after the typed confirmation gate.

Discipline (mirrors `aws teardown`):

- **TTY-only.** Refuses non-interactive contexts with a message naming the canonical command
  sequence to compose manually. There is no automation path.
- **Typed confirmation.** Operator must type the literal string `NUKE EVERYTHING` (not `yes`)
  at the confirmation prompt. The unusual shape is the safety feature.
- **No `--yes` shorthand.** Deliberate omission.
- **`--dry-run` / `--plan-file`** render the exact sequence without mutating. Sprint `4.26`
  routes `prodbox nuke` through `runPlanWithOptions` (reading `nukeDryRun` / `nukePlanFile`),
  so the TTY guard, the typed-confirmation prompt, and the orchestration all live inside the
  apply closure — `--dry-run` never prompts or mutates.

Order of operations: K8s drain (Sprint `4.12`) → destroy all Pulumi stacks (`aws-eks-subzone`,
`aws-eks`, `aws-test`, `aws-ses`) → `prodbox aws teardown`-equivalent IAM cleanup → step-4
postflight tag sweep → long-lived `pulumi_state_backend` bucket destruction. The step-4 tag
sweep is **fail-closed** (Sprint `4.26`,
[lifecycle_reconciliation_doctrine.md §6](lifecycle_reconciliation_doctrine.md)): a non-empty
leak list *or* an unconfirmable sweep aborts nuke with a non-zero exit and the surfaced residue
*before* the step-5 bucket destroy, never "report clean and proceed." See
[lifecycle_reconciliation_doctrine.md → §7](lifecycle_reconciliation_doctrine.md) for the
full doctrine.

### `prodbox pulumi` notes

`src/Prodbox/CLI/Pulumi.hs` owns the full public `prodbox pulumi ...` surface.

`prodbox pulumi aws-ses-migrate-backend` is the operator-interactive (TTY-only) command that
migrates the `aws-ses` stack's Pulumi state from the in-cluster MinIO backend onto the
dedicated long-lived S3 bucket named by `pulumi_state_backend` in `prodbox-config.dhall` —
so the SES sending identity and receive-rule-set state outlives cluster wipes. It is
idempotent (a no-op when the stack already lives in the long-lived backend) and refuses
non-interactive contexts. See
[aws_integration_environment_doctrine.md §4.5](./aws_integration_environment_doctrine.md)
for the per-run-vs-long-lived backend contract.

This matrix is the supported entrypoint set for AWS substrate provisioning and teardown.
Invoking any entry does not require additional user approval beyond the original request —
the test harness is the exclusive owner of every AWS resource any `prodbox` flow creates or
destroys (see [`CLAUDE.md`](../../CLAUDE.md) § AWS Substrate Provisioning Ownership and
[`AGENTS.md`](../../AGENTS.md) § AWS Substrate Provisioning Is Harness-Owned). Per-resource
lifecycle classification (auto-managed per-run stacks vs long-lived cross-substrate shared
infrastructure retained by design) lives in
[`DEVELOPMENT_PLAN/substrates.md` → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

Each Pulumi-managed substrate stack's registry name, Pulumi stack id, project subdir, CLI verb
stem, and lifecycle class are a single `Prodbox.Infra.StackDescriptor` SSoT record (Sprint
`4.27`); the `prodbox pulumi <stem>-resources` / `<stem>-destroy` verbs above all derive from it.
The registry-name↔CLI-command inventory is rendered from that SSoT into the
`stack-command-surface` generated section of
[`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
and kept in sync by `prodbox docs generate` / `docs check`.

`prodbox pulumi eks-destroy --yes`, `prodbox pulumi aws-subzone-destroy --yes`,
`prodbox pulumi test-destroy --yes`, and `prodbox pulumi aws-ses-destroy --yes` report one-line
stack destroy disposition instead of replaying Pulumi login chatter on successful cleanup. On
destroy failure, each path refreshes Pulumi state and retries destroy once before surfacing the
cleanup error.

No supported local-cluster platform or application deployment depends on a root Pulumi project.

### `prodbox dns` notes

`src/Prodbox/Dns.hs` owns the public DNS inspection surface.

### `prodbox k8s` notes

`src/Prodbox/K8s.hs` owns the public Kubernetes helper surface.

### `prodbox gateway` notes

`src/Prodbox/Gateway.hs` owns the public gateway surface and `src/Prodbox/Gateway/Daemon.hs`
owns the daemon runtime. `prodbox gateway status` queries the daemon's operator-facing
bounded `/v1/state` endpoint over HTTP on the configured REST port.

`prodbox gateway start` takes a single startup-time knob — `--config <path>` — plus the
universal `--dry-run` / `--plan-file` plan renderers, per
[config_doctrine.md §2](./config_doctrine.md#2-single-dhall-surface-per-binary-instance)
and §3B's [Daemon-launching flags](#daemon-launching-flags) contract. Sprint 2.24 removed
the legacy `--log-level`, `--port`, and `--foreground` override flags (and the `workload
start` equivalents) along with their daemon threading; the daemon now sources `log_level`
from the mounted Dhall (`live.log_level`, defaulting to `info`) and its REST port from the
Orders file exclusively (see
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)).
Every value the daemon needs already lives in the Dhall file, so the override flags were
redundant, not load-bearing. This matrix row and the §3B prose are now the same
single-`--config` contract.

This `gateway` command group refers to the Haskell distributed gateway daemon, not to the
Kubernetes Gateway API or Envoy Gateway controller.

### `prodbox workload` notes

`src/Prodbox/Workload.hs` owns the internal public workload runtime used by the `api` and
`websocket` chart surfaces. It is repo-rootless and selects its runtime mode (api vs.
websocket) from the `workload.mode` field of its mounted Dhall config (see
[config_doctrine.md](./config_doctrine.md)). The current `websocket` runtime owns the
workload-managed OIDC bootstrap under `/ws/oidc`, the JWT-protected `/ws` upgrade path, and
readiness-based drain for live upgraded connections.

### `prodbox charts` notes

`src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/Lib/Storage.hs`, and `src/Prodbox/PostgresPlatform.hs` own the public chart surface
and its canonical external Patroni naming contract.

For `prodbox charts status|deploy|delete`, `CHART` must be one of the
root chart names `gateway`, `keycloak`, `vscode`, `api`, or
`websocket`. Internal `keycloak-postgres` and `redis` dependency
releases are runtime-owned implementation details and are not supported
public CLI arguments.

`prodbox charts deploy <chart>` is the canonical idempotent reconcile for the chart surface:
rerunning it against an already-deployed healthy release is a success no-op rather than a force
or reinstall path.

The supported chart doctrine does not permit embedded chart-local PostgreSQL subcharts.
`keycloak-postgres` is an internal namespace-local Patroni dependency release, and chart deploy
fails fast until `prodbox rke2 reconcile` has reconciled the cluster-wide `postgres-operator`
platform.

The current public chart surface ships:

- Keycloak on the shared hostname `test.resolvefintech.com` under `/auth`
- redirect-only HTTP on port `80`, which permanently redirects to the same shared-host path over
  HTTPS
- `vscode` on `/vscode`, protected by Envoy Gateway `SecurityPolicy`
- `api` on `/api`, protected by Envoy-local JWT validation plus route claims
- `websocket` on `/ws`, with workload-managed OIDC bootstrap on `/ws/oidc`, a JWT-protected `/ws`
  upgrade path, and an internal `redis` dependency for shared state
- the separate Haskell distributed `gateway` chart, which is not the Envoy Gateway public edge

### `prodbox users` notes

`src/Prodbox/CLI/Users.hs` owns the operator-facing Keycloak user-management surface for the
Phase 8 invite flow. `prodbox users invite <email>` creates a Keycloak user with
`emailVerified=false` and triggers the SES-backed invite email; `--role` assigns an
operator-defined role on invite. `prodbox users list` reports users with their
email-verification status and last-login time, optionally filtered by status (`--status`
alone selects verified users; `--status-unverified` restricts to users awaiting invite
activation; the default lists all). `prodbox users revoke <email-or-id>` disables an
operator-managed user by default, or fully deletes it with `--delete`.

### `prodbox commands` and `prodbox help` notes

`src/Prodbox/App.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`,
`src/Prodbox/CLI/Tree.hs`, and `src/Prodbox/CLI/Json.hs` own the introspection surface. The
registry-backed `commands`, `commands --tree`, `commands --json`, and `help <path>` outputs are
the canonical in-process CLI documentation surface.

### `prodbox test` notes

`prodbox test` and `prodbox test integration` are help groups only. They do not run an implicit
default suite. The per-command rows (options column) live in the generated matrix above; the
tables below add the test-only `Scope` and shared-option semantics.

Shared executable-suite options:

| Option | Meaning |
|--------|---------|
| `--coverage` | Enable coverage mode for the selected scope |
| `--cov-fail-under INTEGER` | Require a minimum coverage percentage; valid only with `--coverage` |
| `--substrate {home-local\|aws}` | Select the substrate the run targets; default `home-local`. Each per-substrate run is substrate-locked: it consumes only that substrate's operator-supplied config (the `Required Config` row in [`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md)) and fails fast if any required field is missing. There is no fallback between substrates. A complete canonical-suite proof requires both substrate runs to land independently; see [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback). |

Named suite commands:

| Command | Scope |
|---------|-------|
| `prodbox test all` | Aggregate Haskell unit and integration surface |
| `prodbox test lint` | `prodbox check-code` plus `cabal build --builddir=.build all` |
| `prodbox test unit` | `test:prodbox-unit` |
| `prodbox test integration all` | Aggregate integration surface |
| `prodbox test integration cli` | `test:prodbox-integration` |
| `prodbox test integration env` | `test:prodbox-integration` |
| `prodbox test integration aws-iam` | Native IAM lifecycle validation |
| `prodbox test integration dns-aws` | Native Route 53 lifecycle validation |
| `prodbox test integration aws-eks` | Native EKS validation |
| `prodbox test integration gateway-daemon` | Native gateway daemon validation |
| `prodbox test integration gateway-pods` | Native gateway pod validation |
| `prodbox test integration gateway-partition` | Native gateway partition validation |
| `prodbox test integration ha-rke2-aws` | Native HA RKE2 AWS validation |
| `prodbox test integration lifecycle` | Native destructive lifecycle validation |
| `prodbox test integration pulumi` | Native Pulumi validation |
| `prodbox test integration charts-storage` | Native chart storage validation |
| `prodbox test integration charts-platform` | Native chart platform validation |
| `prodbox test integration charts-vscode` | Native external `vscode` validation |
| `prodbox test integration charts-api` | Native external API validation |
| `prodbox test integration charts-websocket` | Native external WebSocket validation |
| `prodbox test integration admin-routes` | Native shared-host Harbor and MinIO route validation |
| `prodbox test integration public-dns` | Native public DNS delegation validation |
| `prodbox test integration keycloak-invite` | Native Keycloak operator-invite validation (Phase 8 invite flow) |

`src/Prodbox/TestRunner.hs` owns the public `prodbox test` entrypoint. It:

- runs Haskell suites through `cabal test`
- runs `prodbox test lint` before any Haskell or native validation payload when `prodbox test all`
  is selected
- enforces an initial fail-fast prerequisite gate, visible runbook/bootstrap steps when required,
  and deferred cluster-backed backend proofs such as `pulumi_logged_in` before payload execution
- provisions the shared IAM harness for `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` before AWS-backed prerequisite checks
  begin, then clears operational `aws.*` again before the suite returns
- applies the canonical aggregate ordering
- keeps stored `aws_admin_for_test_simulation.*` confined to suite-driven destructive validation
  and long-lived stack/`nuke` flows rather than the ordinary public onboarding surface
- performs supported-runtime bootstrap and postflight when required
- waits for `prodbox host public-edge` to report `CLASSIFICATION=ready-for-external-proof` before
  external `charts-vscode`, `charts-api`, `charts-websocket`, or `admin-routes` proof continues
  on the supported-runtime path
- proves the public HTTP-to-HTTPS redirect on port `80` as part of the public-host validation
  surface, while preserving the HTTPS auth, route, certificate, and RBAC proofs on port `443`
- dispatches named real-world validations through `src/Prodbox/TestValidation.hs`

### `prodbox check-code` notes

`src/Prodbox/CheckCode.hs` owns the public `check-code` entrypoint.

The supported command runs the repository-owned workflow or hook policy scan, Fourmolu, HLint,
warning-clean `cabal build`, and the final operator binary sync. Detailed Haskell quality doctrine
is defined in
[Haskell Code Guide](./haskell_code_guide.md).

The policy-scan portion is scoped to repo-owned surfaces and excludes generated or retained
runtime roots such as `.build/`, `dist-newstyle/`, and `.data/`.

### `prodbox tla-check` notes

`src/Prodbox/Tla.hs` owns the public TLA+ validation surface.

## 3A. Interactive vs Non-Interactive Surfaces

`prodbox` has two parallel paths for operator-credential work. The
**operator-interactive surface** (`prodbox config setup`,
`prodbox aws setup`, `prodbox aws teardown`, `prodbox aws check-quotas`,
`prodbox aws request-quotas`, and the `prodbox charts delete`
confirmation prompt) reads input from stdin. The **non-interactive
automation surface** (the managed test harness — `prodbox test all`,
`prodbox test integration all`, `prodbox test integration aws-iam`, and targeted
`prodbox test integration <name> --substrate aws` validations) reads operational
`aws.*` from `prodbox-config.dhall`'s `aws_admin_for_test_simulation.*` block
through the suite-level IAM harness and clears it on suite exit.

`prodbox nuke` is TTY-confirmed because of the typed `NUKE EVERYTHING` guard, but its
admin AWS credential source is non-prompting: it loads
`aws_admin_for_test_simulation.*` from `prodbox-config.dhall`, matching the long-lived
`aws-ses` and state-bucket paths.

The interactive surface **refuses to run when stdin is not a TTY**. Each
interactive entry point calls `Prodbox.CLI.Interactive.requireInteractiveTty`
before any prompt fires; on a non-TTY stdin it writes a structured
guidance message to stderr naming the automation equivalent and exits 1.
The guidance is rendered by `Prodbox.CLI.Interactive.renderNonTtyError`
from a per-command `InteractiveGuard` value
(`awsSetupGuard`, `awsTeardownGuard`, `awsCheckQuotasGuard`,
`awsRequestQuotasGuard`, `configSetupGuard`, `chartsDeleteGuard`), keeping
the message under unit test.

Automation contexts (CI, agents, scripted workflows) **must** use the
non-interactive surface. The cross-reference table in
[`CLAUDE.md`](../../CLAUDE.md) and [`AGENTS.md`](../../AGENTS.md) maps
each operator task to its automation equivalent.

### Test-only opt-in: `PRODBOX_ALLOW_NON_TTY_INTERACTIVE`

Integration tests that exercise the interactive surface end-to-end
(`test/integration/CliSuite.hs` fixtures for `prodbox config setup`,
`prodbox aws setup`, `prodbox aws teardown`, `prodbox aws check-quotas`,
`prodbox aws request-quotas`) spawn `prodbox` as a subprocess with
controlled stdin input. Their stdin is a pipe, not a TTY, so the guard
would otherwise refuse. These tests set the env var
`PRODBOX_ALLOW_NON_TTY_INTERACTIVE=1` before spawning, which makes
`requireInteractiveTty` skip the refusal.

The env var is **test-only**. Production agents must never set it. The
test fixtures set it through the `fakeAwsEnvironment` /
`fakeAwsHarnessEnvironment` helpers in `test/integration/CliSuite.hs`,
which is the only sanctioned consumer. Any other set site is a doctrine
violation and should be flagged.

## 4. Doctrine-Adoption Command Surface

The CLI doctrine in [the engineering doctrine docs](../../documents/engineering/README.md) introduces several
commands that land through the Phase `1`–`3` reopens. They are listed here as the canonical
surface; per-sprint deliverables live in
[../../DEVELOPMENT_PLAN/](../../DEVELOPMENT_PLAN/).

### `prodbox lint`

| Command | Arguments | Options | Owning Sprint |
|---------|-----------|---------|---------------|
| `prodbox lint files` | none | `--write` | Sprint 1.10 |
| `prodbox lint docs` | none | `--write` | Sprint 1.10 |
| `prodbox lint haskell` | none | `--write` | Sprint 1.19 |
| `prodbox lint chart` | none | none | Sprint 3.12 |
| `prodbox lint all` | none | none | Sprint 1.10 / Sprint 1.20 |

`src/Prodbox/CheckCode.hs` currently owns the lint surfaces and the canonical
policy scan, marker-delimited generated-section registry, and fully generated path registry.
`prodbox lint chart` validates `Chart.yaml` metadata, required chart-label helpers
(`app.kubernetes.io/name`, `app.kubernetes.io/managed-by: prodbox`, and
`prodbox.io/chart-root`), and route-inventory drift inside the chart templates that consume the
generated public-edge catalog.

### `prodbox docs`

| Command | Arguments | Options | Owning Sprint |
|---------|-----------|---------|---------------|
| `prodbox docs check` | none | none | Sprint 1.10 |
| `prodbox docs generate` | none | none | Sprint 1.10 |

`prodbox lint docs [--write]` is implemented as a thin alias over the same Haskell function
that backs `prodbox docs check` / `prodbox docs generate`; both surfaces consume the same
in-code generation registry per
[code_quality.md → Generated Artifacts](./code_quality.md#generated-artifacts).
The generator owns both marker-delimited artifacts and fully generated files:

- `documents/cli/commands.md`
- `share/man/man1/prodbox.1`
- `share/man/man1/prodbox-<group>.1`
- `share/completion/bash/prodbox`
- `share/completion/zsh/_prodbox`
- `share/completion/fish/prodbox.fish`
- marker-delimited `route-registry` sections in the chart templates that consume the canonical
  public-edge route catalog

Operators may use either name; future contributors must not split the surfaces or add a third
validator command.

### Daemon-launching flags

`prodbox gateway start`, `prodbox gateway status`, and `prodbox workload start` accept
exactly one startup-time CLI knob — `--config <path>` — per
[config_doctrine.md §2](./config_doctrine.md#2-single-dhall-surface-per-binary-instance)
(`gateway start` additionally exposes only the universal `--dry-run` / `--plan-file` plan
renderers). Foreground execution is the only supported mode; self-daemonization (`--detach`,
double-fork, `setsid`, `forkProcess`) is forbidden per
[CLI-to-Daemon Plumbing](../../documents/engineering/README.md).
`--log-level`, `--port`, `--node-id`, and similar runtime-override flags are **not part of
the surface**; every value the daemon needs lives in the Dhall file. Environment-variable
precedence is forbidden on supported paths: no `PRODBOX_*` startup fallback ladder. See
[config_doctrine.md §10](./config_doctrine.md#10-forbidden-surfaces) for the authoritative
forbidden-surface list.

Sprint 2.24 removed the legacy `--log-level`, `--port`, and `--foreground` override flags
from both `prodbox gateway start` and `prodbox workload start`, along with the
`src/Prodbox/Gateway.hs` threading. The gateway daemon now sources its log level from the
mounted Dhall (`live.log_level`, defaulting to `info`) and its REST port from the Orders
file; the workload daemon sources its port and log level from its mounted Dhall config.
Both daemon-launch surfaces conform to the single-`--config` contract (see the
[generated command matrix](#3-command-matrix)).

### One-shot output flags

Sprint 1.17 is closed. The shared output layer owns `OutputOptions`, typed
`--format {json,table,plain}`, `--color {auto,always,never}`, the `--no-color` alias, and the
stdout/stderr writer boundary for one-shot commands. `prodbox check-code` rejects direct terminal
writes outside that boundary. Daemon-launching commands stay on the structured-logging exception
path; daemons emit structured JSON logs to stderr per Sprint 2.12.

### Cross-language types generation deferral

[Generated Artifacts](../../documents/engineering/README.md)
enumerates "cross-language types" as a generation surface (e.g. TypeScript or Go type
mirrors of Haskell ADTs). No non-Haskell consumer is currently in scope; the supported
plan does not schedule cross-language-type generation. The generated-artifact registry remains
ready when such a consumer enters scope.

## Command Topology

Represent commands as ordinary Haskell data types:

```haskell
data Command
  = Users UsersCommand
  | Projects ProjectsCommand
  | Config ConfigCommand
  deriving stock (Show, Eq)

data UsersCommand
  = UsersList UsersListOptions
  | UsersCreate UsersCreateOptions
  | UsersDelete UsersDeleteOptions
  deriving stock (Show, Eq)
```

This gives a typed model of the CLI surface. Define a separate `CommandSpec`
and generate the parser from it. The parser is never the source of truth.

`optparse-applicative` can automatically generate `--help` output, usage text,
subcommand help, and shell completion support. For durable external
documentation (Markdown, manpages, HTML, JSON command schemas), define a
first-class command specification:

```haskell
data CommandSpec = CommandSpec
  { name        :: Text
  , summary     :: Text
  , description :: Text
  , children    :: [CommandSpec]
  , options     :: [OptionSpec]
  , examples    :: [Example]
  }

data OptionSpec = OptionSpec
  { longName    :: Text
  , shortName   :: Maybe Char
  , metavar     :: Maybe Text
  , description :: Text
  , required    :: Bool
  }
```

Use the specification as the source of truth:

```text
CommandSpec
  -> optparse-applicative Parser
  -> Markdown documentation
  -> manpage
  -> JSON schema
  -> shell completion metadata
  -> command tree output
```

This avoids duplicating command descriptions across code, README files, and
generated help text. See
[code_quality.md → Generated Artifacts](./code_quality.md#generated-artifacts)
for the full discipline (markers, paired check/write commands, drift
enforcement).

## Progressive Introspection

A good CLI should be introspectable at every level:

```bash
tool --help
tool users --help
tool users create --help
tool projects archive --help
```

Expose explicit introspection commands:

```bash
tool commands
tool commands --tree
tool commands --json
tool help users
tool help users create
```

Example tree output:

```text
tool
├── users
│   ├── list
│   ├── create
│   └── delete
├── projects
│   ├── list
│   └── archive
└── config
    ├── get
    └── set
```

## Reconcilers: Idempotent Mutation as a Single Command

Tools that manage state in the world expose a single canonical reconcile
command. Re-running it is a no-op when current state already matches desired
state. There is no separate `install` / `upgrade` / `repair` / `force-install`
split — those are different verbs for the same underlying operation.

Standard shape:

```haskell
data Command
  = ...
  | Reconcile ReconcileOptions
  | ...
```

Internally the reconcile is composed of independently idempotent steps. Each
step is safe to skip when its postcondition is already satisfied, and safe to
run when it is not.

Composition with prior sections:

- [Plan / Apply](./pure_fp_standards.md#plan--apply). A reconcile is built as
  a Plan/Apply pair. `build` reads current state, computes the diff against
  desired state, and emits a plan listing only the steps that still need to
  run. An empty plan is the steady state and `apply` is a no-op.
- [Prerequisites as Typed Effects](./prerequisite_doctrine.md#prerequisites-as-typed-effects).
  The prerequisite DAG runs before any mutating step. A reconcile on a host
  missing required tools or credentials fails fast at the gate.
- `--dry-run` prints the plan and exits. This is the operator's contract for
  "what will change if I run this against this host."

A worked example: a hypothetical reconcile that provisions a local
systemd-managed service.

```text
Step 1: install package    -- skip if package already at target version
Step 2: write config       -- skip if on-disk config matches desired content
Step 3: enable unit        -- skip if `systemctl is-enabled` returns enabled
Step 4: start unit         -- skip if `systemctl is-active` returns active
Step 5: assert healthy     -- always run; fail the reconcile if unhealthy
```

Each step is checked-before-mutated. Re-running the command performs zero
work when the system is already in the desired state.

**Forbidden patterns:**

- Sister commands like `install` / `upgrade` / `repair` / `force-install`.
  If the reconcile is correct, repeating it is the repair.
- `--force`, `--reinstall`, or any flag whose purpose is "ignore that the
  step is already done." The check-then-mutate discipline replaces this.
- Steps that mutate before checking their own postcondition. Mutation without
  a precondition check leaks work into the steady state.
- Steps that exit non-zero with an "already installed" error. Already-installed
  is the success case, not a failure.
- Reconcilers that mutate state not described in the plan. The plan is the
  audit trail of what will change.

Operators run the reconcile freely. When a tool publishes a reconcile
command, that command is the canonical mutation entrypoint, and running it on
a host — whether to bring up fresh state, reconcile drift, or recover from
partial state — is the supported operation, not an unauthorized change.

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Code Quality Doctrine](./code_quality.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Haskell Code Guide](./haskell_code_guide.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Pure FP Standards](./pure_fp_standards.md)
