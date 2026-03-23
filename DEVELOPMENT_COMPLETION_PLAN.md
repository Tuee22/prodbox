# Development Completion Plan

**Status**: Proposed
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
- Authoritative doctrine for stateful AWS-mutating integration tests
- AWS integration fixture harness rules for ephemeral environment creation, tagging, and teardown
- Public command-surface contract audit across Click, smart constructors, DAG builders, interpreter behavior, docs, and tests
- Real Pulumi validation paths and named Pulumi integration suites
- Gateway daemon and lifecycle completion validation across process-mode, pod-mode, and cleanup flows
- Codebase completion matrix and final release-readiness verification commands
- The tests and docs that currently allow these gaps to pass unnoticed

Explicitly out of scope:

- `prodbox gateway config-gen` placeholder values in the generated file. Those are intentional template values, not an accidental runtime no-op.
- Composite predicates like `k8s_ready` and `infra_ready` may remain derived predicates if their semantics stay “dependencies passed” and the docs say so clearly.

## Placeholder Inventory

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

## AWS Integration Doctrine Debt

The current documentation says integration tests use real AWS, but it does not yet make the following mandatory with enough specificity:

1. Stateful AWS-mutating integration tests must create ephemeral test environments via AWS CLI.
2. The harness must create only brand new AWS resources isolated from existing environments.
3. Fixture-owned AWS resources must be clearly marked as ephemeral test-only and safe to delete.
4. Cleanup of those AWS resources must be fixture-owned and must still run after test-body failure.
5. One canonical doc must list the exact AWS CLI commands for create, tag, inspect, cleanup, and delete.

## Codebase Completion Debt Beyond The Placeholder Inventory

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

3. Named suite debt.
   The command-surface doctrine requires named suites, but the current plan still lacks named real-AWS and real-Pulumi suites in the required verification path.

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

This plan is not a static design note. It is a live execution tracker.

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

5. Add a canonical AWS integration environment doctrine doc.
   Recommended SSoT path: `documents/engineering/aws_integration_environment_doctrine.md`

6. Update doctrinal links so AWS integration-environment ownership is explicit and non-duplicative:
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

3. The canonical owner for AWS stateful integration-test environment doctrine is chosen and recorded.
   Recommended owner: `documents/engineering/aws_integration_environment_doctrine.md`

4. The planned doctrine explicitly requires all AWS-mutating integration tests to:
   use AWS CLI-created ephemeral environments
   create only brand new isolated resources
   tag or otherwise clearly mark them as ephemeral and safe to delete
   clean them up in pytest fixture teardown

5. Any implementation work for later sprints that would contradict these contracts is blocked until this sprint is updated first.

## Sprint 1: Fix `env show` And `env template`

Status: Completed
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Began implementation pass for Sprint 1 while reconciling dependent placeholder work in later sprints.
- 2026-03-22: Confirmed current `env show` still validates settings without rendering configuration and `env template` still returns a placeholder-only `Pure` value.
- 2026-03-22: Added deterministic settings rendering and template generation in `src/prodbox/settings.py`.
- 2026-03-22: Rebuilt `env show` to load settings and print masked or unmasked output.
- 2026-03-22: Rebuilt `env template` to print a deterministic `.env` template to stdout.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration env` -> pass
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

Status: Blocked
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Replaced `route53_accessible` with a real Route 53 access check and rebuilt `dns check` / `dns update` into explicit fetch-query-render workflows.
- 2026-03-22: Added deterministic DNS status/update reports and behavior-level mocked integration coverage.
- 2026-03-22: Added a real `dns-aws` named suite with an ephemeral Route 53 hosted-zone fixture created and tagged via AWS CLI.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-22: `poetry run prodbox test integration dns-aws` -> fail fast at Phase 1 (`tool_aws` missing in current environment)
Open issues:
- Real AWS validation is blocked in the current environment because `aws` is not installed and required AWS environment variables are unset.

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

7. Document the explicit AWS CLI command sequence in the canonical AWS doctrine doc.
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
  Recommended new file: `tests/integration/test_dns_route53_ephemeral.py`
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
7. The canonical AWS doctrine doc must list the explicit AWS CLI commands used for create, tag, inspect, cleanup, and delete.
8. At least one integration or harness verification path must prove cleanup runs when the test body fails.
9. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration cli`

## Sprint 4: Replace Pulumi Placeholder Prerequisites

Status: Blocked
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Replaced `pulumi_logged_in` with a real `pulumi whoami` validation effect.
- 2026-03-22: Removed the static `pulumi_stack_exists` placeholder and rebuilt preview/up/destroy/refresh around real stack selection.
- 2026-03-22: Added a named `pulumi` integration suite and isolated local-backend real Pulumi test coverage.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-22: `poetry run prodbox test integration pulumi` -> fail fast at Phase 1 (`tool_pulumi` missing in current environment)
Open issues:
- Real Pulumi validation is blocked in the current environment because `pulumi` is not installed.

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

Status: In progress
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Tightened `tests/integration/test_cli_env.py` and `tests/integration/test_cli_commands.py` from exit-code-only checks into behavior assertions.
- 2026-03-22: Added real-suite command-surface coverage for `dns-aws` and `pulumi`.
- 2026-03-22: Reduced over-gating in `prodbox test integration cli` and `prodbox test integration env` so mock-only suites no longer require the RKE2 runbook.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration cli` -> pass
- 2026-03-22: `poetry run prodbox test integration env` -> pass
Open issues:
- Add an explicit generic regression test for accidental lone-`Pure` user-facing command roots if the current command-surface audit does not already make that impossible.

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

Status: Blocked
Last updated: 2026-03-22
Owner: Codex
Progress notes:
- 2026-03-22: Added named suites `prodbox test integration dns-aws` and `prodbox test integration pulumi`.
- 2026-03-22: Added real Route 53 fixture-owned integration coverage in `tests/integration/test_dns_route53_aws.py`.
- 2026-03-22: Added isolated-local-backend Pulumi integration coverage in `tests/integration/test_pulumi_real.py`.
- 2026-03-22: Updated CLI and doctrine docs to distinguish mocked integration coverage from real AWS/Pulumi suites.
Validation notes:
- 2026-03-22: `poetry run prodbox check-code` -> pass
- 2026-03-22: `poetry run prodbox test unit` -> pass
- 2026-03-22: `poetry run prodbox test integration dns-aws` -> fail fast at Phase 1 (`tool_aws` missing in current environment)
- 2026-03-22: `poetry run prodbox test integration pulumi` -> fail fast at Phase 1 (`tool_pulumi` missing in current environment)
Open issues:
- Full real-suite validation is blocked in the current environment until `aws`, `pulumi`, and the required AWS environment variables are available.

Implementation:

1. Extend the explicit `prodbox test integration ...` command surface with named suites for:
   real AWS/Route 53 validation
   real Pulumi validation

2. Update the CLI command surface doctrine and `test_cmd.py` to expose those suites explicitly.
   Recommended suite names:
   `prodbox test integration dns-aws`
   `prodbox test integration pulumi`

3. Ensure the AWS suite uses the ephemeral AWS fixture harness defined earlier in this plan.

4. Ensure the Pulumi suite validates real login, stack selection, preview, and at least one apply/destroy lifecycle against isolated test state.

5. Separate mocked integration coverage from real integration coverage in docs and tests.
   Mocked integration tests validate rendering and sequencing.
   Real integration tests validate real external state changes and cleanup.

Recommended code areas:

- `src/prodbox/cli/test_cmd.py`
- `documents/engineering/cli_command_surface.md`
- `documents/engineering/unit_testing_policy.md`
- `tests/integration/test_dns_route53_aws.py`
- new `tests/integration/test_pulumi_real.py`

Unit tests to add or tighten:

- `tests/unit/test_test_cmd.py`
- `tests/unit/test_cli_commands.py`

Integration tests to add or tighten:

- new `tests/integration/test_dns_route53_aws.py`
- new `tests/integration/test_pulumi_real.py`

Hard validation criteria:

1. The named suites `dns-aws` and `pulumi` exist in the CLI surface and documentation.
2. The AWS suite exercises real Route 53 changes only inside ephemeral fixture-owned environments.
3. The Pulumi suite exercises real login and stack lifecycle against isolated test state.
4. Mocked integration tests and real integration tests are explicitly distinguished in docs and in this plan.
5. The affected suites must pass:
   `poetry run prodbox check-code`
   `poetry run prodbox test unit`
   `poetry run prodbox test integration dns-aws`
   `poetry run prodbox test integration pulumi`

## Sprint 9: Complete Gateway, Lifecycle, And Runtime Real-World Verification

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
   `poetry run prodbox test integration dns-aws`
   `poetry run prodbox test integration pulumi`
   `poetry run prodbox test integration gateway-daemon`
   `poetry run prodbox test integration gateway-pods`
   `poetry run prodbox test integration lifecycle`

## Plan Maintenance Protocol

This file should remain the authoritative execution tracker for placeholder-removal work until all sprints are complete.

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
   add them to `Placeholder Inventory`
   assign them to an existing sprint or add a new sprint
   update downstream validation criteria if needed

6. If new AWS-mutating integration behavior is added:
   update the canonical AWS doctrine doc first or in the same change set
   add or update the explicit AWS CLI command list
   document the ownership and cleanup contract for any new AWS resource type

7. If a task is intentionally descoped or reclassified as an intentional placeholder:
   record the reason here
   link the owning code path and docs that justify the exception

8. Keep the inventory and sprint sections synchronized.
   A placeholder must not appear as “fixed” in a sprint note while still appearing unresolved in the inventory.

9. Prefer additive history over silent rewrites.
   If priorities change, update the sprint text and add a dated note explaining why.

10. Keep the AWS doctrine synchronized with the harness implementation.
    If the harness changes its AWS CLI create/tag/delete sequence, update the canonical doc and this plan in the same change set.

11. Keep the completion matrix synchronized with implementation.
    If a public command, option, named integration suite, or real-system surface changes, update the corresponding matrix row in the same change set.

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
10. A canonical AWS integration-environment doctrine doc exists and is cross-linked according to `documents/documentation_standards.md`.
11. All stateful AWS integration tests use fixture-created ephemeral AWS environments created via AWS CLI.
12. Those AWS resources are clearly marked as ephemeral safe-to-delete resources.
13. Fixture teardown always attempts cleanup of those AWS resources, including after test-body failure.
14. The exact AWS CLI commands required for the AWS test environment lifecycle are documented.
15. Every public command in `documents/engineering/cli_command_surface.md` is represented in the final completion matrix.
16. Every documented public argument and option is either:
    implemented and tested end-to-end
    or explicitly removed from the public surface and docs
17. Named real-system suites exist for AWS/Route 53 and Pulumi validation.
18. Gateway process-mode, gateway pod-mode, and lifecycle suites remain part of the required completion set.
19. The repo passes:
    `poetry run prodbox check-code`
    `poetry run prodbox test unit`
    the required integration suites:
    `poetry run prodbox test integration cli`
    `poetry run prodbox test integration env`
    `poetry run prodbox test integration dns-aws`
    `poetry run prodbox test integration pulumi`
    `poetry run prodbox test integration gateway-daemon`
    `poetry run prodbox test integration gateway-pods`
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
