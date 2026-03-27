# Development Completion Plan

**Status**: Completed
**Purpose**: Finish the public prodbox codebase to a release-ready state by removing accidental runtime placeholders, aligning every public command with its documented contract, replacing fake prerequisite checks with real behavior, and adding a comprehensive test suite with explicit real-system validation.

## Goal

After this plan is complete:

- No public CLI command should return success without performing the behavior described by its help text and docs.
- No prerequisite named like a real validation step should be implemented as unconditional `Pure(True)` unless it is an explicitly documented derived/composite predicate.
- Every documented command argument and option should be propagated into the executed behavior or intentionally removed from the public surface.
- Unit and integration tests should verify real behavior, rendered output, side-effect sequencing, and cleanup behavior.
- Real stateful integrations should be validated through explicit named suites, not implied by ad hoc local commands.
- The plan should end with a codebase-completion matrix and a deterministic verification set that proves feature, documentation, and test alignment.

## Scope

In scope:

- All public `prodbox` CLI command groups:
  `env`
  `host`
  `rke2`
  `pulumi`
  `dns`
  `k8s`
  `gateway`
  `test`
- `prodbox env show`
- `prodbox env template`
- `prodbox host check-ports`
- `prodbox dns check`
- `prodbox dns update`
- `route53_accessible`
- `pulumi_logged_in`
- `pulumi_stack_exists`
- `src/prodbox/infra/dns.py` bootstrap IP placeholder fallback
- Authoritative doctrine for the shared multi-project AWS test environment account, DNS, quota, and auth model
- Authoritative doctrine for `prodbox`-specific stateful AWS-mutating integration tests
- AWS integration fixture harness rules for ephemeral environment creation, tagging, and teardown
- Public command-surface contract audit across Click, smart constructors, DAG builders, interpreter behavior, docs, and tests
- Real Pulumi validation paths and named Pulumi integration suites
- Gateway daemon and lifecycle completion validation across process-mode, pod-mode, and cleanup flows
- Codebase completion matrix and final release-readiness verification commands
- The tests and docs that currently allow these gaps to pass unnoticed
- Documentation-topology, metadata, and conceptual-alignment reconciliation across `README.md`,
  `documents/`, root plan files, and guard coverage under the updated
  `documents/documentation_standards.md`

Explicitly out of scope:

- `prodbox gateway config-gen` placeholder values in the generated file. Those are intentional template values, not an accidental runtime no-op.
- Composite predicates like `k8s_ready` and `infra_ready` may remain derived predicates if their semantics stay “dependencies passed” and the docs say so clearly.

## Latest Reconciliation Audit

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-26: Reopened the plan after audit found that the placeholder inventory is largely fixed but the repo is not yet fully aligned with the plan's claimed completion state.
- 2026-03-26: Confirmed that `prodbox env show --show-secrets` is still effectively a no-op because the current settings surface has no secret-marked values and the tests explicitly lock in identical masked/unmasked output.
- 2026-03-26: Confirmed that the real Pulumi suite currently covers `stack-init` and `preview`, but not a real `up`/`destroy` lifecycle, so Sprint 8 and the final matrix are overstated.
- 2026-03-26: Confirmed documentation drift in `README.md`, including the missing `STACK` argument for `prodbox pulumi stack-init` and omission of supported settings exposed by `src/prodbox/settings.py`.
- 2026-03-26: Marked `ACME_EMAIL` as sensitive so `env show` now renders masked output by default and reveals the full value under `--show-secrets`.
- 2026-03-26: Rebuilt the real Pulumi suite around a fixture-owned Route 53 TXT record lifecycle so `stack-init`, `preview`, `up`, and `destroy` all run against isolated local-backend state.
- 2026-03-26: Synchronized `README.md` and Sprint 10 validation text with the actual command surface and final verification set.
- 2026-03-27: Reconciled this plan against the current dirty worktree and did not find any new unfinished, stubbed, or placeholder regressions within the tracked scope.
- 2026-03-27: Confirmed that the only remaining placeholder language in the tracked feature set is the intentional template output from `prodbox gateway config-gen`, which remains explicitly out of scope.
- 2026-03-27: Kept the placeholder and debt inventories below as historical context, but they are all resolved and no longer describe active remaining work.
- 2026-03-27: Reopened final verification on the current dirty worktree and confirmed `check-code`, unit, `integration env`, and `integration cli` still pass before rerunning the remaining real-system suites.
- 2026-03-27: Revalidated the cluster-backed real suites `gateway-daemon`, `gateway-pods`, and `lifecycle` on the current dirty worktree.
- 2026-03-27: The first `gateway-pods` wrapper invocation failed transiently during the runbook/wrapper path, but a raw pytest reproduction and a second canonical `prodbox test integration gateway-pods` run both passed without code changes, so no deterministic repo regression was found.
- 2026-03-27: Revalidated the AWS-backed real suites `aws-foundation`, `dns-aws`, and `pulumi` on the current dirty worktree; only the final `aws-eks` rerun remains.
- 2026-03-27: Completed the full 2026-03-27 release-readiness rerun on the current dirty worktree, including `aws-eks`; no new deterministic regressions were found within the tracked plan scope.
- 2026-03-27: Manually audited the shared AWS test account with the ambient `aws` CLI after the reruns and confirmed that no Route 53, S3, IAM, EKS, or EC2 resources still carry the fixture owner tag `managed_by=prodbox-integration`.
- 2026-03-27: Closed the stale Sprint 0 operator-task note after reconciling it with the later recorded shared-account provisioning and host-auth completion evidence from 2026-03-26.
- 2026-03-27: Re-audited the acceptance criteria against the current code, docs, and test files and did not find any additional unimplemented tracked items or active stubbed behavior.
- 2026-03-27: Compared the documented public CLI surface and the completion matrix row-for-row and confirmed they cover the same 42 `prodbox` commands with no omissions or extras.
- 2026-03-27: Revalidated `check-code`, `test unit`, `test integration env`, and `test integration cli` during the current plan-sync pass; the higher-cost real-system suite evidence in this file still comes from the already-recorded 2026-03-27 rerun set.
- 2026-03-27: Reopened the plan for conceptual documentation alignment after audit found remaining contradictions across `README.md`, `documents/engineering/prerequisite_doctrine.md`, documentation metadata/backlink headers, and legacy `PRODBOX_PLAN.md` references.
- 2026-03-27: Updated `documents/documentation_standards.md` so root `UPPER_CASE_PLAN.md` files are explicit ephemeral plans and not subject to the standards in that document.
- 2026-03-27: This plan is now the temporary SSoT for resolving the remaining documentation contradictions until the owning docs, metadata, and any guard coverage are reconciled.
- 2026-03-27: Resolved the remaining Sprint 11 documentation contradictions by aligning `README.md` install/development guidance with Poetry, removing the misleading Pulumi destroy-preview wording, reconciling `documents/engineering/prerequisite_doctrine.md` with the implemented `rke2 ensure` boundary, replacing stale `PRODBOX_PLAN.md` guard/doc references, and normalizing `Referenced by` metadata across the tracked markdown set.
- 2026-03-27: Extended `src/prodbox/lib/lint/doc_lint_guard.py` and its unit tests so missing `Referenced by` backlinks are now enforced automatically for the tracked documentation set.
- 2026-03-27: Re-reviewed this plan and the tracked markdown suite against the current working tree during the documentation-standards audit; no new complete/incomplete drift or standards misalignment was found, and the 42-command CLI/matrix parity still holds.
Validation notes:
- 2026-03-26: `poetry run prodbox test unit` -> pass
- 2026-03-26: `poetry run prodbox test integration env` -> pass
- 2026-03-26: `poetry run prodbox test integration pulumi` -> pass
- 2026-03-26: `poetry run prodbox check-code` -> pass
- 2026-03-27: `poetry run prodbox check-code` -> pass
- 2026-03-27: `poetry run prodbox test unit` -> pass
- 2026-03-27: `poetry run prodbox test integration env` -> pass
- 2026-03-27: `poetry run prodbox test integration cli` -> pass
- 2026-03-27: `poetry run prodbox test integration gateway-daemon` -> pass
- 2026-03-27: `poetry run prodbox test integration gateway-pods` -> pass
- 2026-03-27: `poetry run prodbox test integration lifecycle` -> pass
- 2026-03-27: `poetry run prodbox test integration aws-foundation` -> pass
- 2026-03-27: `poetry run prodbox test integration dns-aws` -> pass
- 2026-03-27: `poetry run prodbox test integration pulumi` -> pass
- 2026-03-27: `poetry run prodbox test integration aws-eks` -> pass
- 2026-03-27: manual AWS CLI cleanup audit (`aws sts get-caller-identity`; `aws resourcegroupstaggingapi get-resources --tag-filters Key=managed_by,Values=prodbox-integration`; direct Route 53/S3/IAM checks; enabled-region EC2/EKS sweeps) -> pass
- 2026-03-27: `poetry run prodbox check-code` -> pass
- 2026-03-27: `poetry run prodbox test unit` -> pass
- 2026-03-27: `poetry run prodbox test integration env` -> pass
- 2026-03-27: `poetry run prodbox test integration cli` -> pass
- 2026-03-27: manual markdown metadata/naming audit against `documents/documentation_standards.md` -> pass
Open issues:
- None.

## Historical Placeholder Inventory (Resolved)

All entries below were part of the original unfinished-state inventory and are retained for audit history only. They are resolved in the current tracked scope.

1. `src/prodbox/cli/dag_builders.py`
   `env_show` only runs `ValidateSettings`, so it validates but does not display configuration or honor `show_secrets`.

2. `src/prodbox/cli/dag_builders.py`
   `env_template` returns a `Pure` value containing a path string, but the CLI help says the command prints a template.

3. `src/prodbox/cli/dag_builders.py`
   `host_check_ports` returns a `Pure` tuple of ports and never checks actual bindings.

4. `src/prodbox/cli/dag_builders.py`
   `dns_check` only fetches the public IP even though the command help promises Route 53 status.

5. `src/prodbox/cli/dag_builders.py`
   `dns_update` only fetches the public IP even though the command help promises conditional Route 53 updates.

6. `src/prodbox/cli/prerequisite_registry.py`
   `route53_accessible` is `Pure(True)` instead of a real Route 53 accessibility check.

7. `src/prodbox/cli/prerequisite_registry.py`
   `pulumi_logged_in` is `Pure(True)` instead of a real Pulumi login check.

8. `src/prodbox/cli/prerequisite_registry.py`
   `pulumi_stack_exists` is `Pure(True)` even though stack existence depends on command-local `stack` and `cwd`.

9. `src/prodbox/infra/dns.py`
   `get_public_ip()` falls back to `0.0.0.0`, which is a literal placeholder value.

## Historical AWS Doctrine Debt (Resolved)

This section records the AWS doctrine gaps that the plan had to close. They are resolved and retained here to document the final ownership split.

AWS testing doctrine has two ownership layers and both must remain explicit:

1. General shared AWS test-environment doctrine.
   Canonical owner: `documents/engineering/aws_test_environment.md`
   Scope:
   dedicated AWS Organizations member account
   permanent parent test domain and hosted zone
   delegated child subdomain per test run
   cross-project isolation rules
   quota bootstrap and concurrency planning
   IAM Identity Center and temporary-credential authentication model

2. `prodbox`-specific AWS integration harness doctrine.
   Canonical owner: `documents/engineering/aws_integration_environment_doctrine.md`
   Scope:
   host-level AWS CLI auth rules for `prodbox`
   AWS CLI-created ephemeral resources
   fixture ownership, tagging, and teardown
   explicit AWS CLI command list used by the harness

As of 2026-03-23, the general shared test-environment doctrine has been implemented in `documents/engineering/aws_test_environment.md`.

The completed implementation treats `documents/engineering/aws_test_environment.md` as the owner for shared-account topology, shared-domain strategy, quota bootstrap, and auth posture, and treats `documents/engineering/aws_integration_environment_doctrine.md` as the owner for `prodbox`-specific harness behavior.

## Historical Codebase Completion Debt Beyond The Placeholder Inventory (Resolved)

The debt classes below explain why the plan expanded beyond the original placeholder list. They are resolved and retained as historical rationale for the later sprints and final matrix.

The original placeholder program is not sufficient by itself to declare the codebase finished. The expanded completion plan must also close the following classes of debt:

1. Public command-surface contract debt.
   Every public command, argument, and option in the Click surface and docs must be audited against:
   smart constructors
   DAG builders
   effect payloads
   interpreter behavior
   behavior-level tests

2. Known contract-propagation debt.
   Current example already identified during audit:
   `k8s wait` and `k8s logs` accept namespaces at the CLI/ADT layer but the DAG builders currently do not propagate those namespaces into executed effects.

3. Named suite verification debt.
   The command-surface doctrine now includes named real-AWS and real-Pulumi suites, but the current plan still requires passing host-level validation for those suites in the required verification path.

4. Completion-matrix debt.
   The plan currently describes work sprint-by-sprint, but codebase completion also requires one final matrix mapping each public surface to:
   owning docs
   implementation files
   unit tests
   mocked integration tests
   real integration tests
   required verification commands

5. Release-readiness debt.
   The final verification set must exercise every high-risk real system:
   Kubernetes runtime
   AWS/Route 53
   Pulumi
   gateway process mode
   gateway pod mode
   lifecycle cleanup/reconcile paths

## LLM Progress Tracking Contract

This plan began as a live execution tracker. With all sprints complete, it now serves as the historical execution record and the checklist to reopen if future work invalidates the completion state.

Mandatory rules for any LLM or agent implementing this plan:

1. The implementing LLM must update this file as work progresses.
2. The implementing LLM must add or update a status block under the active sprint before starting implementation work for that sprint.
3. The implementing LLM must append progress notes during the sprint as meaningful milestones are completed.
4. The implementing LLM must update the sprint notes before moving to the next sprint.
5. The implementing LLM must record validation commands and results in this file as they are run, not only at final completion.
6. If implementation reveals that the plan is stale, incomplete, or contradicted by the codebase, the implementing LLM must update the plan before continuing on the affected work.
7. At most one sprint should be marked `In progress` at a time unless this file explicitly documents an approved parallel-work exception.

Required per-sprint tracking block:

```text
Status: Planned | In progress | Blocked | Completed
Last updated: YYYY-MM-DD
Owner: LLM / agent name
Progress notes:
- YYYY-MM-DD: ...
Validation notes:
- YYYY-MM-DD: command -> pass/fail
Open issues:
- ...
```

## Sprint 0: Lock The Intended Contracts

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-23: Added `documents/engineering/aws_test_environment.md` as the canonical shared multi-project AWS test environment doctrine.
- 2026-03-23: Updated doctrinal cross-links so shared AWS test-account design is owned by `documents/engineering/aws_test_environment.md` and `prodbox`-specific harness behavior remains owned by `documents/engineering/aws_integration_environment_doctrine.md`.
- 2026-03-27: Closed the stale Sprint 0 open issue because the shared-account provisioning and host-auth setup later recorded in this file were completed on 2026-03-26 and no longer represent an active repo-tracked gap.
Validation notes:
- 2026-03-23: Documentation-only plan update for shared AWS test environment doctrine -> no code/test commands run
Open issues:
- None for the repository-tracked scope. Shared-account provisioning and host authentication were completed on 2026-03-26; ongoing account operations remain outside the repo by doctrine.

Resolve the user-visible contracts before touching code:

1. Decide the canonical behavior of `prodbox env template`.
   Recommended choice: print the template to stdout.
   Reason: the CLI exposes no output-path argument, and current docs already describe it as a printing command.

2. Decide the bootstrap DNS behavior for Pulumi.
   Recommended choice: use a real public IP when available, allow an explicit override setting for bootstrap-only cases, and fail fast when neither is available.

3. Record the intentional exception for `gateway config-gen`.
   It is a template generator and may continue to emit placeholder values that the operator must fill in.

4. Update the relevant docs as part of the same sprint:
   `README.md`
   `documents/engineering/cli_command_surface.md`
   `documents/engineering/prerequisite_doctrine.md`

5. Add canonical AWS doctrine docs with explicit scope ownership:
   Shared multi-project AWS test environment SSoT:
   `documents/engineering/aws_test_environment.md`
   `prodbox`-specific AWS integration harness SSoT:
   `documents/engineering/aws_integration_environment_doctrine.md`

6. Update doctrinal links so AWS doctrine ownership is explicit and non-duplicative:
   `documents/engineering/aws_test_environment.md`
   `documents/engineering/unit_testing_policy.md`
   `documents/engineering/integration_fixture_doctrine.md`
   `documents/engineering/README.md`
   `AGENTS.md` if test guidance needs a short top-level reference

Hard validation criteria:

1. The intended runtime contract for `prodbox env template` is documented in this file and aligned with:
   `README.md`
   `documents/engineering/cli_command_surface.md`
   `documents/engineering/prerequisite_doctrine.md`

2. This file explicitly distinguishes:
   accidental placeholders to remove
   intentional template placeholders to keep

3. The canonical owners for AWS testing doctrine are chosen and recorded.
   General shared AWS test-environment owner:
   `documents/engineering/aws_test_environment.md`
   `prodbox`-specific AWS integration-harness owner:
   `documents/engineering/aws_integration_environment_doctrine.md`

4. The planned shared AWS test-environment doctrine explicitly requires:
   a dedicated AWS Organizations member account for shared test workloads
   one permanent parent test domain and hosted zone
   delegated child subdomains per project test run
   quota bootstrap and concurrency planning in the new account
   temporary-credential authentication for humans and automation

5. The planned `prodbox` AWS integration doctrine explicitly requires all AWS-mutating integration tests to:
   use AWS CLI-created ephemeral environments
   create only brand new isolated resources
   tag or otherwise clearly mark them as ephemeral and safe to delete
   clean them up in pytest fixture teardown

6. Any implementation work for later sprints that would contradict these contracts is blocked until this sprint is updated first.

## Sprint 1: Fix `env show` And `env template`

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-22: Began implementation pass for Sprint 1 while reconciling dependent placeholder work in later sprints.
- 2026-03-22: Confirmed current `env show` still validates settings without rendering configuration and `env template` still returns a placeholder-only `Pure` value.
- 2026-03-22: Added deterministic settings rendering and template generation in `src/prodbox/settings.py`.
- 2026-03-22: Rebuilt `env show` to load settings and print masked or unmasked output.
- 2026-03-22: Rebuilt `env template` to print a deterministic `.env` template to stdout.
- 2026-03-26: Reopened Sprint 1 after audit confirmed that `env show --show-secrets` still does not produce observably different output because no current setting is marked sensitive and both unit/integration tests assert the outputs are identical.
- 2026-03-26: Marked `ACME_EMAIL` as sensitive, which makes the default `env show` path observably masked and `--show-secrets` observably unmasked.
- 2026-03-26: Updated unit/integration env coverage and `README.md` so the user-visible settings contract matches the implementation again.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration env` -> pass
- 2026-03-26: `poetry run prodbox test unit` -> pass
- 2026-03-26: `poetry run prodbox test integration env` -> pass
- 2026-03-26: `poetry run prodbox check-code` -> pass
Open issues:
- None for Sprint 1.

Implementation:

1. Add a pure renderer for settings display.
   It should support masked and unmasked output from the same data model.

2. Change `env show` to load settings and write rendered output to stdout.
   Keep validation behavior, but make successful execution produce the promised configuration display.

3. Change `env template` to render a deterministic `.env` template and write it to stdout.
   Remove or demote `output_path` from the public command contract if stdout becomes canonical.

4. Ensure `show_secrets` actually changes rendered output.

Recommended code areas:

- `src/prodbox/settings.py`
- `src/prodbox/cli/dag_builders.py`
- `src/prodbox/cli/interpreter.py`
- `src/prodbox/cli/env.py`

Unit tests to add or tighten:

- `tests/unit/test_settings.py`
  Add coverage for masked and unmasked display rendering.
- `tests/unit/test_dag_builders.py`
  Assert that `env_show` and `env_template` are no longer placeholder-only builders.
- `tests/unit/test_interpreter.py`
  Verify settings loading plus stdout rendering paths.
- `tests/unit/test_cli_commands.py`
  Stop at least some tests from being pure “`execute_command` was called” assertions and verify meaningful output expectations.

Integration tests to add or tighten:

- `tests/integration/test_cli_env.py`
  Assert that `env show` prints expected keys.
  Assert that secrets are masked by default.
  Assert that `--show-secrets` exposes the full value.
  Assert that `env template` prints required variables and defaulted variables.

Hard validation criteria:

1. `prodbox env show` must print configuration content, not only a generic success summary.
2. `prodbox env show --show-secrets` must produce observably different output from the default path.
3. `prodbox env template` must emit a deterministic template that contains required and optional variables.
4. The relevant unit tests and integration tests must assert output content, not only exit codes.
5. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration env`

## Sprint 2: Fix `host check-ports`

Status: Completed
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Replaced the placeholder host port path with a real socket/procfs-backed availability probe.
- 2026-03-22: Moved pass/fail reporting to the command root so the CLI prints deterministic availability output before returning a non-zero exit on busy ports.
- 2026-03-22: Added busy-port regression coverage in unit and integration tests.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
Open issues:
- None for Sprint 2.

Implementation:

1. Replace the `Pure` root with a real port-check effect.

2. Prefer a Python/socket-based implementation over shell parsing.
   Reason: it is easier to unit test, avoids shell-specific output parsing, and matches the repo’s “no shell unless required” direction.

3. Return structured per-port results so the CLI can render both success and failure cleanly.

4. Make the command exit non-zero when any required port is unavailable.

Recommended code areas:

- `src/prodbox/cli/effects.py`
- `src/prodbox/cli/interpreter.py`
- `src/prodbox/cli/dag_builders.py`

Unit tests to add or tighten:

- `tests/unit/test_interpreter.py`
  Add free-port and busy-port cases for the new effect.
- `tests/unit/test_dag_builders.py`
  Assert `host_check_ports` is backed by a real effect, not `Pure`.
- `tests/unit/test_cli_commands.py`
  Verify output and failure behavior, not only wiring.

Integration tests to add or tighten:

- Add a process-level integration test that opens a temporary listener on a high port and executes the port-check path against a custom `HostCheckPortsCommand`.
  This can live in a new `tests/integration/test_host_ports.py` or in `tests/integration/test_cli_commands.py` if you want to keep the suite count low.
- Keep the CLI integration for the default command surface, but do not rely on privileged ports for behavior coverage.

Hard validation criteria:

1. `host_check_ports` must no longer compile down to a lone `Pure` root.
2. The command must return success when all tested ports are free.
3. The command must return failure when at least one tested port is bound.
4. At least one behavior-level integration test must prove real port occupancy detection using a temporary listener.
5. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`

## Sprint 3: Fix DNS Commands And Route 53 Validation

Status: Complete
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-22: Replaced `route53_accessible` with a real Route 53 access check and rebuilt `dns check` / `dns update` into explicit fetch-query-render workflows.
- 2026-03-22: Added deterministic DNS status/update reports and behavior-level mocked integration coverage.
- 2026-03-22: Added a real `dns-aws` named suite with an ephemeral Route 53 hosted-zone fixture created and tagged via AWS CLI.
- 2026-03-23: Added `documents/engineering/aws_test_environment.md` and clarified that Sprint 3 owns only the `prodbox`-specific AWS fixture harness and Route 53 workflow, not the shared-account baseline doctrine.
- 2026-03-26: Configured ambient host AWS CLI auth for the dedicated shared test account and fixed two Route 53 fixture defects: reserved `example.com` hosted-zone creation and brittle AWS CLI record-query quoting.
- 2026-03-26: Expanded the AWS harness into a tagged shared-account fixture model with delegated child zones, tagged S3 buckets, tagged EC2/VPC resources, and janitor-safe expired-resource discovery/cleanup.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-26: `poetry run prodbox test integration dns-aws` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-foundation` -> pass
Open issues:
- None.

Implementation:

1. Add a real Route 53 accessibility check.
   Preferred direction: replace `route53_accessible` with an actual lightweight AWS call that validates zone access.

2. Rebuild `dns check` as a real workflow:
   load settings
   fetch public IP
   query current Route 53 A record
   render a deterministic status report

3. Rebuild `dns update` as a real workflow:
   load settings
   fetch public IP
   query current record
   compare current vs desired IP
   skip update when unchanged unless `force=True`
   perform `UpdateRoute53Record` when required
   render a deterministic summary of what happened

4. Keep the logic explicit.
   The update path should clearly distinguish:
   no-op because IP is unchanged
   forced update
   actual change from old IP to new IP
   AWS or network failure

5. Introduce an AWS integration fixture harness for stateful DNS/Route 53 tests.
   The harness must:
   create a brand new ephemeral hosted zone or equivalent isolated AWS test environment via AWS CLI
   verify the resource was created in the current test run rather than discovered from pre-existing state
   apply explicit ephemeral-test tags that mark the resource safe for deletion
   expose only fixture-owned identifiers to the test body
   delete all fixture-owned AWS resources during teardown even if the test body fails

6. Route all real stateful AWS integration setup and teardown through pytest fixtures or finalizers.
   Tests must not open-code AWS create/delete sequences in the test body.

7. Document the explicit AWS CLI command sequence in the canonical `prodbox` AWS doctrine doc.
   Minimum command coverage to document:
   `aws sts get-caller-identity`
   `aws route53 create-hosted-zone`
   `aws route53 change-tags-for-resource`
   `aws route53 list-resource-record-sets`
   `aws route53 change-resource-record-sets`
   `aws route53 delete-hosted-zone`

Recommended code areas:

- `src/prodbox/cli/dag_builders.py`
- `src/prodbox/cli/prerequisite_registry.py`
- `src/prodbox/cli/effects.py`
- `src/prodbox/cli/interpreter.py`
- `src/prodbox/cli/dns.py`
- `tests/integration/conftest.py`
- `tests/integration/helpers.py`
- `documents/engineering/aws_test_environment.md`
- `documents/engineering/aws_integration_environment_doctrine.md`
- `documents/engineering/integration_fixture_doctrine.md`
- `documents/engineering/unit_testing_policy.md`

Unit tests to add or tighten:

- `tests/unit/test_dag_builders.py`
  Assert `dns_check` and `dns_update` expand to real Route 53-aware workflows.
- `tests/unit/test_interpreter.py`
  Add cases for:
  Route 53 access validation
  status rendering inputs
  no-op update
  forced update
  changed-IP update
  AWS failure
- `tests/unit/test_prerequisite_registry.py`
  Update expectations so `route53_accessible` is no longer `Pure(True)`.
- `tests/unit/test_cli_commands.py`
  Assert user-visible output paths for success and failure cases.
- Add unit coverage for AWS fixture-harness helper code.
  Recommended new module: `tests/unit/test_aws_integration_harness.py`
  Minimum cases:
  unique ephemeral resource naming
  required tag set generation
  refusal to operate on pre-existing or unowned resources
  cleanup command planning for fixture-owned resources only
  teardown execution on raised test-body exceptions via fixture/finalizer helper tests

Integration tests to add or tighten:

- `tests/integration/test_cli_commands.py`
  Add CLI-level `dns check` and `dns update` tests that patch `httpx` and `boto3` in-process and assert rendered output plus whether the update call was made.
- Keep the existing missing-config coverage, but add behavior assertions for configured runs.
- Add at least one real AWS integration path that uses the ephemeral AWS fixture harness end-to-end.
  Recommended file: `tests/integration/test_dns_route53_aws.py`
  Minimum behavior:
  create a fresh ephemeral AWS test environment via fixture
  perform Route 53 record mutation only inside that environment
  assert the created environment is clearly tagged as ephemeral test-only
  prove teardown deletes fixture-owned resources when the test succeeds

- Add a teardown-failure regression path for the AWS fixture harness.
  This may be a unit-level fixture/finalizer test if a full failing integration test is too destructive.
  The doctrine requirement is that test-body failure still triggers AWS cleanup.

Hard validation criteria:

1. `dns_check` must query Route 53 state in addition to fetching public IP.
2. `dns_update` must have distinct tested outcomes for:
   unchanged IP no-op
   forced update
   changed IP update
   AWS failure

3. `route53_accessible` must no longer be implemented as unconditional `Pure(True)`.
4. CLI-level tests must assert whether the Route 53 update call happened.
5. The AWS integration harness must create only brand new fixture-owned resources and must not target pre-existing AWS environments.
6. AWS resources created for stateful integration tests must carry explicit ephemeral safe-to-delete metadata.
   Preferred mechanism: AWS tags.
   For untaggable child resources, the harness must create them only under a tagged fixture-owned parent resource.
7. The canonical `prodbox` AWS integration doctrine doc must list the explicit AWS CLI commands used for create, tag, inspect, cleanup, and delete.
8. At least one integration or harness verification path must prove cleanup runs when the test body fails.
9. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`

## Sprint 4: Replace Pulumi Placeholder Prerequisites

Status: Complete
Last updated: 2026-03-26
Owner: Codex
Progress notes:
- 2026-03-22: Replaced `pulumi_logged_in` with a real `pulumi whoami` validation effect.
- 2026-03-22: Removed the static `pulumi_stack_exists` placeholder and rebuilt preview/up/destroy/refresh around real stack selection.
- 2026-03-22: Added a named `pulumi` integration suite and isolated local-backend real Pulumi test coverage.
- 2026-03-26: Installed Pulumi on the host, configured ambient host AWS CLI auth for the dedicated shared test account, and validated the real suite against the ephemeral Route 53 fixture harness.
- 2026-03-26: Added a dedicated `aws-eks` real suite that creates a tagged control plane plus tagged IAM/VPC dependencies and tears them down after validation.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-26: `poetry run prodbox test integration pulumi` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-eks` -> pass
Open issues:
- None.

Implementation:

1. Replace `pulumi_logged_in` with a real check.
   Recommended implementation: run `pulumi whoami` and fail fast on non-zero exit.

2. Remove the static `pulumi_stack_exists` placeholder pattern.
   Preferred direction: make stack existence a command-local real step using `PulumiStackSelect(create_if_missing=False)` or a new dedicated validation effect that takes `stack` and `cwd`.

3. Do not keep a global `Pure(True)` prerequisite for stack existence.
   Stack identity is dynamic, so a static registry node is the wrong abstraction unless it is rebuilt with caller-supplied values.

4. Keep preview, up, destroy, and refresh behavior explicit:
   verify tool
   verify login
   verify stack selection
   execute the Pulumi operation

Recommended code areas:

- `src/prodbox/cli/prerequisite_registry.py`
- `src/prodbox/cli/dag_builders.py`
- `src/prodbox/cli/interpreter.py`

Unit tests to add or tighten:

- `tests/unit/test_prerequisite_registry.py`
  Stop asserting `Pure` for Pulumi readiness checks.
- `tests/unit/test_dag_builders.py`
  Assert preview, up, destroy, and refresh contain a real stack-validation step.
- `tests/unit/test_interpreter.py`
  Add `pulumi whoami` success and failure cases if a new effect is added.

Integration tests to add or tighten:

- `tests/integration/test_cli_commands.py`
  Add CLI-level coverage for:
  login failure
  missing stack
  successful preview path with mocked subprocess results

Hard validation criteria:

1. `pulumi_logged_in` must no longer be `Pure(True)`.
2. `pulumi_stack_exists` must no longer be a static unconditional placeholder.
3. Preview, up, destroy, and refresh must each include a real login/stack validation step.
4. Missing-login and missing-stack cases must be covered by tests with explicit behavioral assertions.
5. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`

## Sprint 5: Remove The Infra DNS Bootstrap Placeholder

Status: Completed
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Removed the `0.0.0.0` bootstrap fallback from `src/prodbox/infra/dns.py`.
- 2026-03-22: Added `bootstrap_public_ip_override` to settings and fail-fast bootstrap guidance when public IP lookup fails.
- 2026-03-22: Added dedicated unit coverage for override, successful fetch, and failure-without-override behavior.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
Open issues:
- None for Sprint 5.

Implementation:

1. Replace the `0.0.0.0` fallback in `src/prodbox/infra/dns.py`.

2. Preferred behavior:
   use an explicit bootstrap override setting when provided
   otherwise fetch the current public IP
   otherwise fail fast with an actionable message

3. Make the failure mode deterministic and documented.

Recommended code areas:

- `src/prodbox/infra/dns.py`
- `src/prodbox/settings.py`
- `README.md`

Unit tests to add:

- New `tests/unit/test_infra_dns.py`
  public IP fetch success
  explicit bootstrap override
  fetch failure without override

Integration tests to add:

- If feasible, add a lightweight process-level integration test with patched `httpx.get` in the infra module.
  If not, keep this fully unit-tested and document why no integration test adds more value here.

Hard validation criteria:

1. `src/prodbox/infra/dns.py` must not fall back to `0.0.0.0`.
2. Bootstrap DNS behavior must be deterministic and documented.
3. A dedicated unit test module must cover:
   bootstrap override
   public IP success
   failure without override

4. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`

## Sprint 6: Harden The Test Suite Against Future Placeholder Regressions

Status: Completed
Last updated: 2026-03-23
Owner: Codex
Progress notes:
- 2026-03-22: Tightened `tests/integration/test_cli_env.py` and `tests/integration/test_cli_commands.py` from exit-code-only checks into behavior assertions.
- 2026-03-22: Added real-suite command-surface coverage for `dns-aws` and `pulumi`.
- 2026-03-22: Reduced over-gating in `prodbox test integration cli` and `prodbox test integration env` so mock-only suites no longer require the RKE2 runbook.
- 2026-03-23: Added a parametrized regression guard in `tests/unit/test_dag_builders.py` that fails if repaired user-facing command builders regress to a lone `Pure` root.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-22: `poetry run prodbox test integration env` -> pass
- 2026-03-23: `poetry run prodbox check-code` -> pass
- 2026-03-23: `poetry run prodbox test unit` -> pass
Open issues:
- None for Sprint 6.

Required changes:

1. Upgrade exit-code-only integration tests to assert meaningful behavior.
   Existing examples that need tightening:
   `tests/integration/test_cli_env.py`
   `tests/integration/test_cli_commands.py`

2. Upgrade unit tests that only assert “`execute_command` was called”.
   Keep those where they add CLI wiring value, but add separate behavior tests that inspect output and effect structure.

3. Add a guard test for accidental no-op command builders.
   Suggested rule: user-facing commands that promise external observation or mutation must not compile down to a lone `Pure` root.
   Keep intentional exceptions explicit and documented.

4. Add regression coverage for help-text/behavior alignment.
   If a command says it prints, validates, checks, or updates something, at least one test should prove that it does.

5. Add regression coverage for the AWS ephemeral-environment doctrine.
   At minimum, tests must fail if:
   a stateful AWS integration path reuses pre-existing resources
   required ephemeral safe-to-delete tags are missing
   fixture teardown stops cleaning AWS resources on test-body failure
   the documented AWS CLI workflow drifts from the implemented harness flow

Hard validation criteria:

1. No repaired command may be covered only by exit-code assertions.
2. At least one regression test must exist for each repaired placeholder area:
   env display/template
   port checks
   DNS status/update
   Pulumi login/stack checks
   infra DNS bootstrap behavior

3. At least one regression test must exist for each AWS doctrine rule:
   AWS-mutating integration tests create fresh isolated resources only
   fixture-owned AWS resources are explicitly marked ephemeral and safe to delete
   teardown always attempts cleanup after test-body failure
   the AWS CLI command workflow remains documented and current

4. A guard or equivalent regression test must fail if a user-visible command builder regresses to a lone `Pure` root without an explicit documented exception.
5. The full intended verification set must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`
   `poetry run prodbox test integration env`

## Sprint 7: Audit And Repair The Entire Public Command Surface

Status: Completed
Last updated: 2026-03-23
Owner: Codex
Progress notes:
- 2026-03-22: Audited the public Click surface against command ADTs, DAG builders, interpreter behavior, and behavior-level tests while tightening command-surface coverage.
- 2026-03-23: Confirmed `k8s wait` and `k8s logs` namespace propagation is implemented in `command_adt.py`, `dag_builders.py`, `interpreter.py`, and covered by unit tests.
- 2026-03-23: Added the command-and-feature completion matrix in Sprint 10 so every public command in `documents/engineering/cli_command_surface.md` is explicitly accounted for.
Validation notes:
- 2026-03-23: `poetry run prodbox check-code` -> pass
- 2026-03-23: `poetry run prodbox test unit` -> pass
- 2026-03-23: `poetry run prodbox test integration cli` -> pass
Open issues:
- None for Sprint 7.

Implementation:

1. Audit every public command in `documents/engineering/cli_command_surface.md` against:
   Click option/argument parsing
   command ADTs and smart constructors
   DAG builder propagation
   effect payloads
   interpreter behavior
   user-facing docs
   behavior-level tests

2. Repair any contract-propagation mismatches discovered during the audit.
   Known example that must be addressed:
   `k8s wait` and `k8s logs` namespace propagation

3. Ensure every public command with user-controlled arguments or options has:
   at least one unit-level propagation test
   at least one behavior-level CLI or integration assertion

4. Create a command-surface completion matrix in this file or a dedicated linked doc.
   Minimum matrix columns:
   surface
   implementation owner
   docs owner
   unit tests
   mocked integration tests
   real integration tests
   required validation commands

Recommended code areas:

- `src/prodbox/cli/*.py`
- `src/prodbox/cli/command_adt.py`
- `src/prodbox/cli/dag_builders.py`
- `src/prodbox/cli/interpreter.py`
- `documents/engineering/cli_command_surface.md`
- this plan or a dedicated completion matrix doc

Unit tests to add or tighten:

- `tests/unit/test_cli_commands.py`
- `tests/unit/test_command_adt.py`
- `tests/unit/test_dag_builders.py`
- `tests/unit/test_interpreter.py`

Integration tests to add or tighten:

- `tests/integration/test_cli_commands.py`
- add targeted behavior-level integration coverage for any newly discovered public-surface mismatch

Hard validation criteria:

1. Every public command listed in `documents/engineering/cli_command_surface.md` is audited and accounted for in the completion matrix.
2. Every public argument or option that affects behavior has a concrete propagation test.
3. `k8s wait` and `k8s logs` namespace propagation is implemented and tested end-to-end.
4. No audited public command may rely only on “execute_command was called” tests.
5. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`

## Sprint 8: Add Named Real-System Validation Suites For AWS And Pulumi

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-22: Added named suites `prodbox test integration dns-aws` and `prodbox test integration pulumi`.
- 2026-03-22: Added real Route 53 fixture-owned integration coverage in `tests/integration/test_dns_route53_aws.py`.
- 2026-03-22: Added isolated-local-backend Pulumi integration coverage in `tests/integration/test_pulumi_real.py`.
- 2026-03-22: Updated CLI and doctrine docs to distinguish mocked integration coverage from real AWS/Pulumi suites.
- 2026-03-23: Added the shared AWS test-account doctrine in `documents/engineering/aws_test_environment.md`; the real AWS suite is now expected to run inside that shared-account model once host prerequisites exist.
- 2026-03-23: Removed the manual `ROUTE53_ZONE_ID` requirement from the Pulumi real suite by reusing the fixture-owned ephemeral Route 53 hosted-zone harness.
- 2026-03-26: Provisioned the dedicated shared AWS test account, configured host-level AWS auth to land in that account by default, and validated both named real suites end to end.
- 2026-03-26: Added named suites `prodbox test integration aws-foundation` and `prodbox test integration aws-eks`.
- 2026-03-26: Added real shared-account foundation coverage in `tests/integration/test_aws_foundation_real.py` for delegated child zones, tagged S3 buckets, tagged EC2/VPC resources, and selective janitor cleanup.
- 2026-03-26: Added real EKS control-plane coverage in `tests/integration/test_aws_eks_real.py`.
- 2026-03-26: Reopened Sprint 8 after audit confirmed that `tests/integration/test_pulumi_real.py` currently covers real `stack-init` and `preview`, but does not yet cover a real `up`/`destroy` lifecycle.
- 2026-03-26: Replaced the preview-only Pulumi fixture project with a minimal fixture-owned Route 53 TXT record project so the real suite now exercises `stack-init`, `preview`, `up`, and `destroy` against isolated local-backend state.
- 2026-03-26: Added an explicit integration timeout override for the real Pulumi lifecycle path because the real AWS apply/destroy sequence exceeds the default per-test timeout budget.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-foundation` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-eks` -> pass
- 2026-03-26: `poetry run prodbox test integration dns-aws` -> pass
- 2026-03-26: `poetry run prodbox test integration pulumi` -> pass
Open issues:
- None.

Implementation:

1. Extend the explicit `prodbox test integration ...` command surface with named suites for:
   real shared-account AWS foundation validation
   real EKS validation
   real AWS/Route 53 validation
   real Pulumi validation

2. Update the CLI command surface doctrine and `test_cmd.py` to expose those suites explicitly.
   Recommended suite names:
   `prodbox test integration aws-foundation`
   `prodbox test integration aws-eks`
   `prodbox test integration dns-aws`
   `prodbox test integration pulumi`

3. Ensure the AWS suite uses the ephemeral AWS fixture harness defined earlier in this plan and remains compatible with the shared-account rules in `documents/engineering/aws_test_environment.md`.

4. Ensure the shared-account AWS foundation suite validates delegated Route 53 child-zone lifecycle, tagged S3 + EC2/VPC resource ownership, and selective expired-resource janitor cleanup.

5. Ensure the EKS suite validates a real tagged control plane plus tagged IAM/VPC dependencies and tears them down in reverse dependency order.

6. Ensure the Pulumi suite validates real login, stack selection, preview, and at least one apply/destroy lifecycle against isolated test state.

7. Separate mocked integration coverage from real integration coverage in docs and tests.
   Mocked integration tests validate rendering and sequencing.
   Real integration tests validate real external state changes and cleanup.

Recommended code areas:

- `src/prodbox/cli/test_cmd.py`
- `documents/engineering/cli_command_surface.md`
- `documents/engineering/aws_test_environment.md`
- `documents/engineering/aws_integration_environment_doctrine.md`
- `documents/engineering/unit_testing_policy.md`
- `tests/integration/test_aws_foundation_real.py`
- `tests/integration/test_aws_eks_real.py`
- `tests/integration/test_dns_route53_aws.py`
- new `tests/integration/test_pulumi_real.py`

Unit tests to add or tighten:

- `tests/unit/test_test_cmd.py`
- `tests/unit/test_cli_commands.py`
- `tests/unit/test_aws_integration_harness.py`

Integration tests to add or tighten:

- new `tests/integration/test_aws_foundation_real.py`
- new `tests/integration/test_aws_eks_real.py`
- new `tests/integration/test_dns_route53_aws.py`
- new `tests/integration/test_pulumi_real.py`

Hard validation criteria:

1. The named suites `aws-foundation`, `aws-eks`, `dns-aws`, and `pulumi` exist in the CLI surface and documentation.
2. The shared-account foundation suite exercises delegated Route 53 child-zone changes, tagged S3 bucket lifecycle, tagged EC2/VPC lifecycle, and selective janitor cleanup only inside fixture-owned environments that fit the shared-account AWS test-environment doctrine.
3. The EKS suite exercises a real tagged control plane lifecycle plus tagged IAM/VPC dependencies.
4. The AWS DNS suite exercises real Route 53 changes only inside ephemeral fixture-owned environments that fit the shared-account AWS test-environment doctrine.
5. The Pulumi suite exercises real login and stack lifecycle against isolated test state.
6. Mocked integration tests and real integration tests are explicitly distinguished in docs and in this plan.
7. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration aws-foundation`
   `poetry run prodbox test integration aws-eks`
   `poetry run prodbox test integration dns-aws`
   `poetry run prodbox test integration pulumi`

## Sprint 9: Complete Gateway, Lifecycle, And Runtime Real-World Verification

Status: Completed
Last updated: 2026-03-23
Owner: Codex
Progress notes:
- 2026-03-23: Validated gateway daemon process-mode runtime behavior through the named `gateway-daemon` suite.
- 2026-03-23: Validated gateway pod-mode failover, partition, crash, and ownership flows through the named `gateway-pods` suite.
- 2026-03-23: Validated lifecycle cleanup/rebind behavior through the named `lifecycle` suite; earlier false negatives came from concurrent runbook interference and disappeared when the suites were rerun sequentially.
Validation notes:
- 2026-03-23: `poetry run prodbox check-code` -> pass
- 2026-03-23: `poetry run prodbox test unit` -> pass
- 2026-03-23: `poetry run prodbox test integration gateway-daemon` -> pass
- 2026-03-23: `poetry run prodbox test integration gateway-pods` -> pass
- 2026-03-23: `poetry run prodbox rke2 ensure` -> pass
- 2026-03-23: `poetry run prodbox test integration lifecycle` -> pass
Open issues:
- None for Sprint 9.

Implementation:

1. Audit gateway daemon process-mode, pod-mode, and status/config contracts for feature completeness and doc alignment.

2. Audit RKE2 lifecycle and cleanup flows for command/help/behavior alignment.

3. Confirm lifecycle and cleanup doctrine is reflected in both tests and docs, including fixture-owned cleanup and retained-storage behavior.

4. Ensure the final completion matrix covers:
   gateway process mode
   gateway pod mode
   lifecycle cleanup/reconcile
   RKE2 runtime management
   Kubernetes health/wait/log/logging utilities

Recommended code areas:

- `src/prodbox/gateway_daemon.py`
- `src/prodbox/cli/gateway.py`
- `src/prodbox/cli/rke2.py`
- `src/prodbox/cli/k8s.py`
- `tests/integration/test_gateway_daemon_k8s.py`
- `tests/integration/test_gateway_k8s_pods.py`
- `tests/integration/test_prodbox_lifecycle.py`

Unit tests to add or tighten:

- `tests/unit/test_gateway_daemon.py`
- `tests/unit/test_cli_commands.py`
- `tests/unit/test_dag_builders.py`

Integration tests to add or tighten:

- `tests/integration/test_gateway_daemon_k8s.py`
- `tests/integration/test_gateway_k8s_pods.py`
- `tests/integration/test_prodbox_lifecycle.py`

Hard validation criteria:

1. Gateway process-mode, pod-mode, and status/config flows are each represented in the completion matrix.
2. RKE2 ensure/cleanup/status/logs flows are each represented in the completion matrix.
3. Real gateway and lifecycle suites remain required for completion, not optional side suites.
4. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration gateway-daemon`
   `poetry run prodbox test integration gateway-pods`
   `poetry run prodbox test integration lifecycle`

## Sprint 10: Final Completion Matrix And Release-Readiness Verification

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-23: Added the final command-and-feature completion matrix covering every public CLI command plus the required real-system surfaces.
- 2026-03-23: Recorded current release-readiness validation results directly in this plan.
- 2026-03-26: Completed the remaining host-external AWS authentication setup against the dedicated shared test account and reran the final real AWS-backed suites successfully.
- 2026-03-26: Extended release-readiness validation to include the shared-account AWS foundation suite and the dedicated EKS control-plane suite.
- 2026-03-26: Reopened Sprint 10 after audit found that the completion matrix and release-readiness narrative still overstate Pulumi real-suite coverage and do not fully match the current docs surface.
- 2026-03-26: Reclosed Sprint 10 after synchronizing `README.md`, the reopened sprint notes, and the final verification narrative with the actual repo state.
- 2026-03-27: Reopened Sprint 10 to rerun the final verification set against the current dirty worktree and confirm the recorded completion state still holds.
- 2026-03-27: Revalidated the cluster-backed real suites `gateway-daemon`, `gateway-pods`, and `lifecycle`; the first `gateway-pods` wrapper run failed transiently, but the canonical rerun passed and no deterministic code regression was reproduced.
- 2026-03-27: Revalidated the AWS-backed real suites `aws-foundation`, `dns-aws`, and `pulumi`; only `aws-eks` remains in the 2026-03-27 rerun set.
- 2026-03-27: Reclosed Sprint 10 after `aws-eks` passed and the full release-readiness verification set succeeded again on the current dirty worktree.
- 2026-03-27: Performed a manual post-verification AWS CLI cleanliness audit and confirmed the shared test account has no remaining fixture-owned resources tagged `managed_by=prodbox-integration`.
- 2026-03-27: Reconciled the final completion matrix against `documents/engineering/cli_command_surface.md` and confirmed row-for-row parity across all 42 documented public `prodbox` commands.
- 2026-03-27: Re-audited the acceptance criteria against the current code, docs, and test files; no additional repo-tracked completion gaps were found beyond the intentional out-of-scope `gateway config-gen` template placeholders.
Validation notes:
- 2026-03-23: `poetry run prodbox check-code` -> pass
- 2026-03-23: `poetry run prodbox test unit` -> pass
- 2026-03-23: `poetry run prodbox test integration env` -> pass
- 2026-03-23: `poetry run prodbox test integration cli` -> pass
- 2026-03-23: `poetry run prodbox test integration gateway-daemon` -> pass
- 2026-03-23: `poetry run prodbox test integration gateway-pods` -> pass
- 2026-03-23: `poetry run prodbox test integration lifecycle` -> pass
- 2026-03-26: `poetry run prodbox check-code` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-foundation` -> pass
- 2026-03-26: `poetry run prodbox test integration aws-eks` -> pass
- 2026-03-26: `poetry run prodbox test integration dns-aws` -> pass
- 2026-03-26: `poetry run prodbox test integration pulumi` -> pass
- 2026-03-27: `poetry run prodbox check-code` -> pass
- 2026-03-27: `poetry run prodbox test unit` -> pass
- 2026-03-27: `poetry run prodbox test integration env` -> pass
- 2026-03-27: `poetry run prodbox test integration cli` -> pass
- 2026-03-27: `poetry run prodbox test integration gateway-daemon` -> pass
- 2026-03-27: `poetry run prodbox test integration gateway-pods` -> pass
- 2026-03-27: `poetry run prodbox test integration lifecycle` -> pass
- 2026-03-27: `poetry run prodbox test integration aws-foundation` -> pass
- 2026-03-27: `poetry run prodbox test integration dns-aws` -> pass
- 2026-03-27: `poetry run prodbox test integration pulumi` -> pass
- 2026-03-27: `poetry run prodbox test integration aws-eks` -> pass
- 2026-03-27: manual AWS CLI cleanup audit (`aws sts get-caller-identity`; `aws resourcegroupstaggingapi get-resources --tag-filters Key=managed_by,Values=prodbox-integration`; direct Route 53/S3/IAM checks; enabled-region EC2/EKS sweeps) -> pass
Open issues:
- None.

Implementation:

1. Produce the final command-and-feature completion matrix.
   It must cover every public CLI command and every real-system integration surface.

2. Resolve any remaining mismatch between:
   code
   docs
   named test suites
   completion matrix
   actual verification commands

3. Run the full release-readiness verification set and record the results directly in this plan.

### Completion Matrix

#### `env`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox env show` | `README.md`; `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/env.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/settings.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_settings.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_env.py` | none | `poetry run prodbox test integration env` |
| `prodbox env validate` | `README.md`; `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/env.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_settings.py` | `tests/integration/test_cli_env.py` | none | `poetry run prodbox test integration env` |
| `prodbox env template` | `README.md`; `documents/engineering/cli_command_surface.md`; `documents/engineering/prerequisite_doctrine.md` | `src/prodbox/cli/env.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/settings.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_settings.py` | `tests/integration/test_cli_env.py` | none | `poetry run prodbox test integration env` |

#### `host`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox host ensure-tools` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/host.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | `tests/integration/test_cli_commands.py` | none | `poetry run prodbox test integration cli` |
| `prodbox host check-ports` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/host.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/effects.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_commands.py` | none | `poetry run prodbox test integration cli` |
| `prodbox host info` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/host.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | none | `poetry run prodbox test unit` |
| `prodbox host firewall` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/host.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | none | `poetry run prodbox test unit` |

#### `rke2`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox rke2 status` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 start` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 stop` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 restart` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 ensure` | `documents/engineering/cli_command_surface.md`; `documents/engineering/integration_fixture_doctrine.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/lib/prodbox_k8s.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | none | `tests/integration/test_gateway_daemon_k8s.py`; `tests/integration/test_gateway_k8s_pods.py`; `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration gateway-daemon`; `poetry run prodbox test integration gateway-pods`; `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 cleanup` | `documents/engineering/cli_command_surface.md`; `documents/engineering/integration_fixture_doctrine.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/lib/prodbox_k8s.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox rke2 logs` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_gateway_daemon_k8s.py`; `tests/integration/test_gateway_k8s_pods.py`; `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration gateway-daemon`; `poetry run prodbox test integration gateway-pods`; `poetry run prodbox test integration lifecycle` |

#### `pulumi`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox pulumi up` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration pulumi` |
| `prodbox pulumi destroy` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration pulumi` |
| `prodbox pulumi preview` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration pulumi` |
| `prodbox pulumi refresh` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration pulumi` |
| `prodbox pulumi stack-init` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py` | none | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration pulumi` |

#### `dns`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox dns update` | `README.md`; `documents/engineering/cli_command_surface.md`; `documents/engineering/aws_integration_environment_doctrine.md` | `src/prodbox/cli/dns.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py`; `src/prodbox/lib/aws_auth.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py`; `tests/unit/test_aws_auth.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_dns_route53_aws.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration dns-aws` |
| `prodbox dns check` | `README.md`; `documents/engineering/cli_command_surface.md`; `documents/engineering/aws_integration_environment_doctrine.md` | `src/prodbox/cli/dns.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/cli/prerequisite_registry.py`; `src/prodbox/lib/aws_auth.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_prerequisite_registry.py`; `tests/unit/test_interpreter.py`; `tests/unit/test_aws_auth.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_dns_route53_aws.py` | `poetry run prodbox test integration cli`; `poetry run prodbox test integration dns-aws` |
| `prodbox dns ensure-timer` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/dns.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | none | none | `poetry run prodbox test unit` |

#### `k8s`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox k8s health` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/k8s.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_dag_builders.py` | `tests/integration/test_cli_commands.py` | none | `poetry run prodbox test integration cli` |
| `prodbox k8s wait` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/k8s.py`; `src/prodbox/cli/command_adt.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | none | none | `poetry run prodbox test unit` |
| `prodbox k8s logs` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/k8s.py`; `src/prodbox/cli/command_adt.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_cli_commands.py`; `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | none | none | `poetry run prodbox test unit` |

#### `gateway`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox gateway start` | `documents/engineering/cli_command_surface.md`; `documents/engineering/distributed_gateway_architecture.md` | `src/prodbox/cli/gateway.py`; `src/prodbox/cli/command_adt.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/gateway_daemon.py` | `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_gateway_daemon.py` | none | `tests/integration/test_gateway_daemon_k8s.py`; `tests/integration/test_gateway_k8s_pods.py` | `poetry run prodbox test integration gateway-daemon`; `poetry run prodbox test integration gateway-pods` |
| `prodbox gateway status` | `documents/engineering/cli_command_surface.md`; `documents/engineering/distributed_gateway_architecture.md` | `src/prodbox/cli/gateway.py`; `src/prodbox/cli/command_adt.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/gateway_daemon.py` | `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_gateway_daemon.py` | none | `tests/integration/test_gateway_daemon_k8s.py`; `tests/integration/test_gateway_k8s_pods.py` | `poetry run prodbox test integration gateway-daemon`; `poetry run prodbox test integration gateway-pods` |
| `prodbox gateway config-gen` | `documents/engineering/cli_command_surface.md`; `documents/engineering/distributed_gateway_architecture.md` | `src/prodbox/cli/gateway.py`; `src/prodbox/cli/command_adt.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/gateway_daemon.py` | `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py`; `tests/unit/test_gateway_daemon.py` | none | none | `poetry run prodbox test unit` |

#### `test`

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox test all` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/unit`; `tests/integration` | `poetry run prodbox test all` |
| `prodbox test unit` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/unit` | `poetry run prodbox test unit` |
| `prodbox test integration all` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration` | `poetry run prodbox test integration all` |
| `prodbox test integration aws-foundation` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md`; `documents/engineering/aws_integration_environment_doctrine.md`; `documents/engineering/aws_test_environment.md` | `src/prodbox/cli/test_cmd.py`; `tests/integration/aws_helpers.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py`; `tests/unit/test_aws_integration_harness.py` | none | `tests/integration/test_aws_foundation_real.py` | `poetry run prodbox test integration aws-foundation` |
| `prodbox test integration aws-eks` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md`; `documents/engineering/aws_integration_environment_doctrine.md`; `documents/engineering/aws_test_environment.md` | `src/prodbox/cli/test_cmd.py`; `tests/integration/aws_helpers.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py`; `tests/unit/test_aws_integration_harness.py` | none | `tests/integration/test_aws_eks_real.py` | `poetry run prodbox test integration aws-eks` |
| `prodbox test integration cli` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_cli_commands.py` | `poetry run prodbox test integration cli` |
| `prodbox test integration dns-aws` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md`; `documents/engineering/aws_integration_environment_doctrine.md` | `src/prodbox/cli/test_cmd.py`; `tests/integration/aws_helpers.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py`; `tests/unit/test_aws_auth.py` | none | `tests/integration/test_dns_route53_aws.py` | `poetry run prodbox test integration dns-aws` |
| `prodbox test integration env` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_cli_env.py` | `poetry run prodbox test integration env` |
| `prodbox test integration gateway-daemon` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_gateway_daemon_k8s.py` | `poetry run prodbox test integration gateway-daemon` |
| `prodbox test integration gateway-pods` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_gateway_k8s_pods.py` | `poetry run prodbox test integration gateway-pods` |
| `prodbox test integration lifecycle` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |
| `prodbox test integration pulumi` | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/test_cmd.py` | `tests/unit/test_test_cmd.py`; `tests/unit/test_cli_commands.py` | none | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration pulumi` |

#### Top-level commands

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| `prodbox check-code` | `AGENTS.md`; `documents/engineering/code_quality.md`; `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/check_code.py` | `tests/unit/test_check_code_command.py`; `tests/unit/test_cli_commands.py` | none | none | `poetry run prodbox check-code` |
| `prodbox tla-check` | `documents/engineering/cli_command_surface.md` | `src/prodbox/cli/tla.py` | `tests/unit/test_tla_check.py`; `tests/unit/test_cli_commands.py` | none | none | `poetry run prodbox test unit` |

#### Real-system surfaces

| Surface | Docs owner | Implementation owner | Unit tests | Mocked integration tests | Real integration tests | Required validation |
|---------|------------|----------------------|------------|--------------------------|------------------------|---------------------|
| Infra DNS bootstrap behavior | `README.md` | `src/prodbox/infra/dns.py`; `src/prodbox/settings.py` | `tests/unit/test_infra_dns.py`; `tests/unit/test_settings.py` | none | none | `poetry run prodbox test unit` |
| AWS shared test environment doctrine | `documents/engineering/aws_test_environment.md` | `documents/engineering/aws_test_environment.md` | `tests/unit/test_aws_auth.py` | none | `tests/integration/test_aws_foundation_real.py`; `tests/integration/test_aws_eks_real.py`; `tests/integration/test_dns_route53_aws.py`; `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration aws-foundation`; `poetry run prodbox test integration aws-eks`; `poetry run prodbox test integration dns-aws`; `poetry run prodbox test integration pulumi` |
| AWS ephemeral environment doctrine | `documents/engineering/aws_integration_environment_doctrine.md`; `documents/engineering/integration_fixture_doctrine.md` | `tests/integration/aws_helpers.py`; `src/prodbox/lib/aws_auth.py`; `tests/integration/test_dns_route53_aws.py`; `tests/integration/test_aws_foundation_real.py`; `tests/integration/test_aws_eks_real.py` | `tests/unit/test_aws_auth.py`; `tests/unit/test_interpreter.py`; `tests/unit/test_aws_integration_harness.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_aws_foundation_real.py`; `tests/integration/test_aws_eks_real.py`; `tests/integration/test_dns_route53_aws.py` | `poetry run prodbox test integration aws-foundation`; `poetry run prodbox test integration aws-eks`; `poetry run prodbox test integration dns-aws` |
| Pulumi real-system validation | `documents/engineering/cli_command_surface.md`; `documents/engineering/unit_testing_policy.md` | `src/prodbox/cli/pulumi_cmd.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `tests/integration/test_pulumi_real.py` | `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py`; `tests/unit/test_prerequisite_registry.py` | `tests/integration/test_cli_commands.py` | `tests/integration/test_pulumi_real.py` | `poetry run prodbox test integration pulumi` |
| Gateway process mode | `documents/engineering/distributed_gateway_architecture.md` | `src/prodbox/gateway_daemon.py`; `src/prodbox/cli/gateway.py`; `src/prodbox/cli/interpreter.py` | `tests/unit/test_gateway_daemon.py`; `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_gateway_daemon_k8s.py` | `poetry run prodbox test integration gateway-daemon` |
| Gateway pod mode | `documents/engineering/distributed_gateway_architecture.md` | `src/prodbox/gateway_daemon.py`; `src/prodbox/cli/gateway.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/lib/prodbox_k8s.py` | `tests/unit/test_gateway_daemon.py`; `tests/unit/test_command_adt.py`; `tests/unit/test_dag_builders.py` | none | `tests/integration/test_gateway_k8s_pods.py` | `poetry run prodbox test integration gateway-pods` |
| Lifecycle cleanup/reconcile | `documents/engineering/integration_fixture_doctrine.md` | `src/prodbox/cli/rke2.py`; `src/prodbox/cli/dag_builders.py`; `src/prodbox/cli/interpreter.py`; `src/prodbox/lib/prodbox_k8s.py` | `tests/unit/test_dag_builders.py`; `tests/unit/test_interpreter.py` | none | `tests/integration/test_prodbox_lifecycle.py` | `poetry run prodbox test integration lifecycle` |

Required completion matrix coverage:

- `env`
- `host`
- `rke2`
- `pulumi`
- `dns`
- `k8s`
- `gateway`
- `test`
- infra bootstrap behavior
- AWS shared test environment doctrine
- AWS ephemeral environment doctrine
- Pulumi real-system validation
- gateway process mode
- gateway pod mode
- lifecycle cleanup/reconcile

Hard validation criteria:

1. The completion matrix exists and accounts for every public command and real-system surface.
2. Every matrix row has at least one owning doc, one unit test reference, and one required validation command.
3. Every stateful external mutation path has a real integration suite in the final verification set.
4. The final release-readiness verification set must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration env`
   `poetry run prodbox test integration cli`
   `poetry run prodbox test integration aws-foundation`
   `poetry run prodbox test integration aws-eks`
   `poetry run prodbox test integration dns-aws`
   `poetry run prodbox test integration pulumi`
   `poetry run prodbox test integration gateway-daemon`
   `poetry run prodbox test integration gateway-pods`
   `poetry run prodbox test integration lifecycle`

## Sprint 11: Resolve Documentation Topology And Conceptual Alignment Contradictions

Status: Completed
Last updated: 2026-03-27
Owner: Codex
Progress notes:
- 2026-03-27: Reopened the development plan to track the remaining documentation contradictions found after the completion audit.
- 2026-03-27: Updated `documents/documentation_standards.md` so root `UPPER_CASE_PLAN.md` files are explicit ephemeral plans and exempt from the standards in that document.
- 2026-03-27: Declared this plan the temporary SSoT for the documentation-alignment pass until the owning docs and any guard changes are updated.
- 2026-03-27: Reconciled `README.md` with the actual Poetry-managed install/development workflow and removed the misleading destroy-preview wording.
- 2026-03-27: Reconciled `documents/engineering/prerequisite_doctrine.md` with the implemented `rke2 ensure` prerequisite boundary and updated the doctrine-ownership statement to match.
- 2026-03-27: Normalized `Referenced by` metadata across the tracked markdown set, replaced stale `PRODBOX_PLAN.md` references, and added automated backlink enforcement in `src/prodbox/lib/lint/doc_lint_guard.py`.
Validation notes:
- 2026-03-27: audit-only plan and standards update -> no additional code/test commands run
- 2026-03-27: `poetry run prodbox check-code` -> pass
- 2026-03-27: `poetry run prodbox test unit` -> pass
- 2026-03-27: `poetry run prodbox test integration env` -> pass
- 2026-03-27: `poetry run prodbox test integration cli` -> pass
Open issues:
- None.

This sprint resolves all remaining documentation contradictions according to the updated
`documents/documentation_standards.md`, with this plan serving as the temporary SSoT for the
change set until the owning docs are reconciled.

1. Reconcile `README.md` installation and development workflow guidance with the actual
   Poetry-managed setup and `pyproject.toml`.
2. Reconcile `README.md` Pulumi destroy guidance so preview wording matches the actual
   `prodbox pulumi preview` contract.
3. Reconcile `documents/engineering/prerequisite_doctrine.md` with the implemented
   `rke2 ensure` prerequisite model so doctrine and code describe the same conceptual boundary.
4. Reconcile stale documentation metadata under the updated standards, including outdated
   `Referenced by` headers and legacy `PRODBOX_PLAN.md` references.
5. Decide whether `Referenced by` parity should be enforced automatically; if yes, update guard
   coverage and tests in the same change set.
6. Update the completion matrix, acceptance criteria, and validation evidence after the owning
   docs and any guard changes land.

Hard validation criteria:

1. The audited documentation contradictions from the 2026-03-27 review are resolved in the owning
   docs or explicitly reclassified by the updated documentation standards.
2. Root `UPPER_CASE_PLAN.md` handling is documented only by
   `documents/documentation_standards.md` and is applied consistently across repo docs and guards.
3. No stale `PRODBOX_PLAN.md` references remain unless a specific reference is intentionally
   retained and documented.
4. If documentation guard behavior changes, `poetry run prodbox check-code` and the affected test
   coverage pass in the same change set.

## Post-Completion Maintenance Protocol

This file is now the authoritative completion record for the placeholder-removal program and the
historical execution record for the completed 2026-03-27 documentation-alignment pass. Reopen and
update it when a new audit or implementation pass finds a regression, a new placeholder,
command-surface drift, stale validation evidence, or documentation contradiction.

LLM execution rule:

1. Any LLM or agent implementing this plan must update this file as progress is made.
2. Progress updates are required at sprint start, at meaningful milestone completion inside a sprint, and at sprint completion.
3. The implementing LLM must not defer plan updates until the very end of the project or batch multiple completed sprints into one retrospective update.
4. If implementation discovers that the current plan text is incomplete, stale, or contradicted by the codebase, the implementing LLM must update this file before proceeding further on the affected work.

Update rules:

1. Update this file in the same change set as any implementation that changes sprint scope, sequencing, or validation criteria.
2. Never mark a sprint complete based only on code review or intuition. Mark it complete only after its hard validation criteria have been met.
3. When a sprint starts, add a short dated note under that sprint:
   `Status: in progress as of YYYY-MM-DD`

3a. During implementation, append dated progress notes under the active sprint for meaningful milestones.
   Minimum examples:
   placeholder inventory confirmed
   implementation started
   unit tests added
   integration tests added
   validation commands run
   blockers discovered

4. When a sprint completes, append:
   the exact commands run
   whether they passed
   any approved deviations from the original plan

5. If new placeholders are discovered during implementation:
   add them to the placeholder inventory section
   assign them to an existing sprint or add a new sprint
   update downstream validation criteria if needed

6. If new AWS-mutating integration behavior is added:
   update the relevant canonical AWS doctrine doc first or in the same change set
   if the change affects shared-account topology, parent-domain strategy, quota bootstrap, or auth posture, update `documents/engineering/aws_test_environment.md`
   if the change affects `prodbox` fixture lifecycle or AWS CLI command sequencing, update `documents/engineering/aws_integration_environment_doctrine.md`
   add or update the explicit AWS CLI command list when the harness workflow changes
   document the ownership and cleanup contract for any new AWS resource type

7. If a task is intentionally descoped or reclassified as an intentional placeholder:
   record the reason here
   link the owning code path and docs that justify the exception

8. Keep the inventory and sprint sections synchronized.
   A placeholder must not appear as “fixed” in a sprint note while still appearing unresolved in the inventory.

9. Prefer additive history over silent rewrites.
   If priorities change, update the sprint text and add a dated note explaining why.

10. Keep the AWS doctrine synchronized with implementation.
    If the shared-account topology, quota bootstrap, or auth posture changes, update `documents/engineering/aws_test_environment.md` and this plan in the same change set.
    If the harness changes its AWS CLI create/tag/delete sequence, update `documents/engineering/aws_integration_environment_doctrine.md` and this plan in the same change set.

11. Keep the completion matrix synchronized with implementation.
    If a public command, option, named integration suite, or real-system surface changes, update the corresponding matrix row in the same change set.

12. Keep the documentation-alignment scope synchronized with the updated standards.
    If a documentation contradiction is found, either resolve it in the owning doc set or record
    the standards-based exception and rationale in this plan in the same change set.

Suggested sprint status format:

- `Planned`
- `In progress`
- `Blocked`
- `Completed`

Suggested completion note format:

- `Completed on: YYYY-MM-DD`
- `Validation commands: ...`
- `Result: pass/fail`
- `Notes: ...`

Suggested in-progress note format:

- `Progress on: YYYY-MM-DD`
- `Sprint: Sprint N`
- `Change: ...`
- `Validation so far: ...`
- `Open issues: ...`

## Acceptance Criteria

This plan is complete when all of the following are true:

1. The placeholder inventory above has been removed or explicitly reclassified as intentional.
2. `prodbox env show` prints configuration and honors `--show-secrets`.
3. `prodbox env template` emits a real template according to the final agreed contract.
4. `prodbox host check-ports` performs real port checks.
5. `prodbox dns check` reads Route 53 state.
6. `prodbox dns update` conditionally updates Route 53 and reports what it did.
7. Pulumi login and stack checks are real, not `Pure(True)`.
8. Infra DNS bootstrap no longer falls back to a placeholder IP.
9. Behavior-level unit tests and integration tests exist for every repaired area.
10. A canonical shared AWS test-environment doctrine doc exists and is cross-linked according to `documents/documentation_standards.md`.
11. A canonical `prodbox` AWS integration-environment doctrine doc exists and is cross-linked according to `documents/documentation_standards.md`.
12. All stateful AWS integration tests use fixture-created ephemeral AWS environments created via AWS CLI.
13. Those AWS resources are clearly marked as ephemeral safe-to-delete resources.
14. Fixture teardown always attempts cleanup of those AWS resources, including after test-body failure.
15. The exact AWS CLI commands required for the `prodbox` AWS test harness lifecycle are documented.
16. The shared AWS test-environment doctrine documents the dedicated member-account model, permanent parent domain, quota bootstrap, and temporary-credential auth model.
17. Every public command in `documents/engineering/cli_command_surface.md` is represented in the final completion matrix.
18. Every documented public argument and option is either:
    implemented and tested end-to-end
    or explicitly removed from the public surface and docs
19. Named real-system suites exist for shared-account AWS foundation validation, EKS validation, AWS/Route 53 validation, and Pulumi validation.
20. Gateway process-mode, gateway pod-mode, and lifecycle suites remain part of the required completion set.
21. The repo passes:
    `poetry run prodbox check-code`
    `poetry run prodbox test unit`
    the required integration suites:
    `poetry run prodbox test integration cli`
    `poetry run prodbox test integration env`
    `poetry run prodbox test integration aws-foundation`
    `poetry run prodbox test integration aws-eks`
    `poetry run prodbox test integration dns-aws`
    `poetry run prodbox test integration pulumi`
    `poetry run prodbox test integration gateway-daemon`
    `poetry run prodbox test integration gateway-pods`
22. The documentation contradictions reopened on 2026-03-27 are resolved according to the updated
    `documents/documentation_standards.md`, with no remaining conflict between the owning docs and
    the implemented code for the audited surfaces.
23. Root `UPPER_CASE_PLAN.md` files are treated as ephemeral plans according to
    `documents/documentation_standards.md`, and no stale repo guidance depends on the old
    `PRODBOX_PLAN.md`-specific exception.
24. The updated completion plan has been used as the temporary SSoT for the documentation
    reconciliation change set, and the owning docs have been synchronized back to their final
    canonical ownership boundaries.
    `poetry run prodbox test integration lifecycle`

## Recommended Delivery Order

1. Sprint 0
2. Sprint 1
3. Sprint 2
4. Sprint 3
5. Sprint 4
6. Sprint 5
7. Sprint 6
8. Sprint 7
9. Sprint 8
10. Sprint 9
11. Sprint 10

The highest-value first slice is:

1. Fix `env show`
2. Fix `env template`
3. Fix `host check-ports`
4. Fix `dns check`
5. Fix `dns update`
6. Replace Pulumi placeholder prerequisites
7. Remove the infra DNS placeholder fallback
8. Audit and repair the full public command surface
9. Add named real AWS and Pulumi suites
10. Run the final completion matrix and release-readiness verification
