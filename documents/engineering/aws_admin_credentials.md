# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md
**Generated sections**: none

> **Purpose**: Define the `aws_admin_for_test_simulation` section in
> `prodbox-config.dhall` and the supported way to populate and clear it for suite-driven
> destructive validation and long-lived teardown flows.

---

## 1. Purpose And Scope

The repository rule is: do not store admin credentials for ordinary operator flows. The supported
exception is `prodbox-config.dhall` `aws_admin_for_test_simulation.*`, used by suite-driven
destructive validation and by long-lived teardown/provisioning flows that need the same admin
credential class.

The `aws_admin_for_test_simulation` section exists for:

1. `prodbox test integration aws-iam`
2. `prodbox test integration all`
3. `prodbox test all` when the aggregate runner reaches the native IAM suite
4. repository tests that simulate the interactive temporary-admin-credential workflow
5. long-lived stack operations (`prodbox pulumi aws-ses-resources`,
   `prodbox pulumi aws-ses-destroy`, `prodbox pulumi aws-ses-migrate-backend`) and
   `prodbox nuke`

Normal runtime commands use `aws.*`. Public `prodbox config setup` and public `prodbox aws ...`
commands obtain temporary admin credentials interactively and must not treat
`aws_admin_for_test_simulation.*` as their supported credential source. The native IAM suite,
long-lived stack operations, and `prodbox nuke` are the supported runtime consumers of this
stored section.

---

## 2. Dhall Shape

The `aws_admin_for_test_simulation` section mirrors the operational `aws` section:

```dhall
let Config = ./prodbox-config-types.dhall

in  Config.default // {
      aws_admin_for_test_simulation = Config.default.aws_admin_for_test_simulation // {
        access_key_id = "AKIA..."
      , secret_access_key = "..."
      , session_token = None Text
      , region = "us-east-1"
      }
    }
```

Rules:

1. `access_key_id`, `secret_access_key`, and `region` must be set together or left empty together.
2. `session_token` is optional.
3. Empty `aws_admin_for_test_simulation.*` values are the normal steady state when you are not
   running the native IAM lifecycle test harness, a repository test that simulates the
   interactive temporary-admin-credential workflow, a long-lived stack operation, or
   `prodbox nuke`.

---

## 3. How To Populate It

Populate `aws_admin_for_test_simulation.*` only when preparing the suite-level native IAM
lifecycle harness, another repository test that needs to simulate the interactive
temporary-admin-credential workflow, a long-lived stack operation, or `prodbox nuke`:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. open `prodbox-config.dhall`
3. place the temporary admin key in `aws_admin_for_test_simulation.*`
4. leave `aws.*` blank unless the workflow explicitly needs operational credentials
5. run `prodbox config validate`
6. run the intended entrypoint (`prodbox test integration aws-iam`,
   `prodbox pulumi aws-ses-destroy --yes`, `prodbox nuke`, etc.)

The native IAM suite fails in the Phase `1/2` prerequisite gate when
`aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise incomplete
harness config.

This split is deliberate:

1. `aws.*` is the operational identity used by normal `prodbox` runtime
2. `aws_admin_for_test_simulation.*` is the stored admin identity used by suite-driven
   destructive validation and long-lived stack / `prodbox nuke` flows
3. the native IAM lifecycle validation harness, long-lived stack operations, and
   `prodbox nuke` are the supported runtime consumers of that stored section
4. public onboarding and public `prodbox aws ...` commands still use temporary interactive prompts
   when they need temporary admin credentials

---

## 4. Cleanup Rule

Do not treat `aws_admin_for_test_simulation.*` as the default working credential source.

When `prodbox test integration aws-iam`, targeted
`prodbox test integration <name> --substrate aws` validation, `prodbox test integration all`, or
`prodbox test all` runs with the native IAM harness, `prodbox` now:

1. deletes any pre-existing dedicated `prodbox` IAM user and that user's access keys before fresh
   provisioning
2. uses any pre-existing operational `aws.*` only to discover and delete the IAM user associated
   with those credentials when that identity can still be resolved through STS
3. proves STS-federated operational credentials from the temporary admin test identity with a
   compact AWS-validation session policy
4. waits for both STS and repeated Route 53 hosted-zone probes to succeed with the dedicated
   IAM-user access key before selecting it as the operational key
5. materializes fresh operational `aws.*` only for the duration of the managed suite run; the
   selected runtime key is the dedicated IAM-user key because cert-manager Route 53 DNS01
   credentials do not support an STS session-token field
6. destroys validation-owned per-run stacks when the targeted suite may provision them
7. clears operational `aws.*` again before the suite returns, including prerequisite failure paths

After you finish the native IAM validation task, long-lived stack operation, or `prodbox nuke`
closure:

1. remove or blank `aws_admin_for_test_simulation.access_key_id`
2. remove or blank `aws_admin_for_test_simulation.secret_access_key`
3. remove or blank `aws_admin_for_test_simulation.region`
4. clear `aws_admin_for_test_simulation.session_token` unless you intentionally keep a
   session-based destructive-validation credential

The repository accepts an empty `aws_admin_for_test_simulation` section specifically so temporary
admin credentials can be short-lived.

### 4.1 Harness Teardown Residue Policy (Sprint 7.7 → superseded for the postflight by Sprint 7.9)

**Sprint 7.7 history (correct pre-Sprint-4.10).** When Sprint 7.7 (May 19, 2026) introduced
the harness-internal `BypassPerRunResidueOnly` policy, the long-lived `aws-ses` Pulumi stack
was managed with *operational* `aws.*` credentials, so clearing operational `aws.*` at the end
of a run genuinely stranded `aws-ses` from its destroy surface. Refusing to clear `aws.*`
while `aws-ses` was live was therefore the correct behavior at that time: per-run stacks
(`aws-eks`, `aws-eks-subzone`, `aws-test`) were bypassed because `awsPostflightDestroyActions`
handles them in the same suite-exit unwind, but `aws-ses` caused an actionable refusal.

**Sprint 4.10 invalidated the premise.** Sprint 4.10 (May 21, 2026) moved `aws-ses` to *admin*
credentials (`aws_admin_for_test_simulation.*`) and the long-lived S3 state backend.
`ensureAwsSesStackResources` / `destroyAwsSesStackStatus` now authenticate via
`pulumiSesAdminBaseEnv` / `loadAdminAwsCredentials` (admin), never operational `aws.*`. After
this change, clearing operational `aws.*` can no longer strand `aws-ses` — the admin
credentials that drive `aws-ses` outlive any single run and are never cleared by any teardown
command (see [lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md)).

**Sprint 7.5.c.v.c fixed the preflight only.** Sprint 7.5.c.v.c (May 20, 2026) switched the
harness *preflight* (`runAwsIamHarnessSetup`) to the new `BypassAllResidueForHarnessRefresh`
policy (bypass both per-run AND long-lived residue) but deliberately left the *postflight*
(`runAwsIamHarnessTeardown`) on `BypassPerRunResidueOnly`, on the now-stale premise that the
operator might need operational `aws.*` preserved to destroy `aws-ses`.

**Sprint 7.9 corrects the postflight.** Because the Sprint 7.5.c.v.c "preserve `aws.*` to
destroy `aws-ses`" rationale was a pre-4.10 premise that is now false, the postflight stranded
a freshly-created operational `prodbox` IAM user on every run where `aws-ses` was live (its
retained-by-design steady state) — the opposite of the leak-free goal. Sprint 7.9
(2026-05-29) switches `runAwsIamHarnessTeardown` to `BypassAllResidueForHarnessRefresh`,
matching the preflight: the postflight now clears operational `aws.*` and deletes the
operational `prodbox` IAM user unconditionally with respect to Pulumi residue. Per-run stacks
are still destroyed separately by `awsPostflightDestroyActions` before the teardown runs; the
long-lived `aws-ses` stack is correctly *not* stranded because it is admin-credentialed. The
`BypassPerRunResidueOnly` constructor remains a valid ADT member (it still refuses on long-lived
residue) but no longer has a production caller. See
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.9](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md).

If a pre-Sprint-7.9 run stranded your operational creds (the May 19, 2026 reproduction
scenario was the pre-7.7 variant; the pre-7.9 variant is an `aws-ses`-live postflight
refusal), `aws-ses` resources in AWS are unaffected — only `prodbox-config.dhall::aws.*`
was emptied. Recovery:

1. `prodbox aws setup` (interactive) — paste the temporary admin key. `prodbox` recreates
   the dedicated `prodbox` IAM user and writes operational `aws.*`. `aws-ses` continues to
   be retained as designed.
2. Optional, only if you want `aws-ses` destroyed (note the 5–30 min SES DKIM
   re-verification cost on next reprovision and the ~24-hour S3 bucket name reuse
   cooldown): either `prodbox pulumi aws-ses-destroy --yes` (admin-credentialed; does not
   require operational `aws.*`) followed by `prodbox aws teardown`, or — Sprint 7.7 —
   `prodbox aws teardown --destroy-pulumi-residue` in one step (warns about the SES costs
   before dispatching).

---

## 5. Standalone Substrate-Provisioning Credentials

Operational `prodbox.aws.*` is the steady-state credential surface for operator-driven
AWS-touching `prodbox` commands. It is consumed by, at minimum:

- `prodbox rke2 reconcile` (cert-manager Route 53 DNS01 issuance)
- `prodbox pulumi <stack>-resources` and `prodbox pulumi <stack>-destroy` for the **per-run**
  stacks under `pulumi/`: `aws-eks`, `aws-eks-subzone`, `aws-test`
- `prodbox charts deploy ... --substrate aws` and `prodbox charts delete ... --substrate aws`
- `prodbox host public-edge` when the host's substrate selection points at AWS

Outside a managed test harness, the above fail fast with `aws.access_key_id must not be empty`
when the operational section is unpopulated. There is no fallback to host AWS state, host
profiles, or instance metadata — see
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) for the
no-ambient-auth rule. Named validations under
`prodbox test integration <name> --substrate aws` are the automation exception: the test runner
first materializes operational `aws.*` from `aws_admin_for_test_simulation.*`, runs the
validation, destroys any per-run stacks the validation may have provisioned, and clears the
materialized operational credentials again.

The **long-lived** stack `aws-ses` is the exception: per Sprint 4.10 it is admin-credentialed
(`aws_admin_for_test_simulation.*` + the long-lived S3 state backend), not operationally
credentialed. `prodbox pulumi aws-ses-resources` and `prodbox pulumi aws-ses-destroy`
authenticate through `loadAdminAwsCredentials` / `pulumiSesAdminBaseEnv` and therefore do
**not** require operational `aws.*` to be populated — they do not fail fast on an empty
operational section. This is why the Sprint 7.9 harness postflight can clear operational
`aws.*` even while `aws-ses` is live without stranding it (§4.1). The credential-class
assignment is owned by
[lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md) (long-lived
stacks + bucket bootstrap → admin creds; per-run stacks → operational `aws.*`).

Three supported population paths exist; pick exactly one per workflow shape:

| Workflow shape | Population path | Entrypoints |
|----------------|-----------------|-------------|
| Standalone substrate provisioning (e.g. the [Sprint 7.5.c.v operator workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)) | **Public path**: `prodbox aws setup` — prompts interactively for one temporary admin credential pasted from the AWS console; derives the dedicated `prodbox` IAM user via STS federation; writes operational `aws.*` to `prodbox-config.dhall`. The temporary admin credential is not persisted. | `prodbox aws setup` at start; `prodbox aws teardown` at end |
| Suite-driven runs (the canonical test surface) | **Test-harness simulation path**: `aws_admin_for_test_simulation.*` populated in `prodbox-config.dhall`; consumed non-interactively by `runAwsIamHarnessSetup` to simulate the prompt input. The same provision-derive-write contract runs. | `prodbox test integration aws-iam`, `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, `prodbox test all` |
| Long-lived shared-infrastructure operations | **Config-backed admin path**: `aws_admin_for_test_simulation.*` populated in `prodbox-config.dhall`; consumed directly by `loadAdminAwsCredentials` / `pulumiSesAdminBaseEnv` without materializing operational `aws.*`. | `prodbox pulumi aws-ses-resources`, `prodbox pulumi aws-ses-destroy --yes`, `prodbox pulumi aws-ses-migrate-backend`, `prodbox nuke` |

These paths are not mixed in a single workflow. A standalone substrate run uses
`prodbox aws setup` and `prodbox aws teardown` symmetrically; a suite-driven run lets the
harness own setup, per-run-stack cleanup when applicable, and teardown end-to-end; long-lived
shared-infrastructure operations consume the admin block directly and do not materialize
operational `aws.*`. Per Sprint `7.3`, the standalone and suite-driven paths clear operational
`aws.*` before they return, so a standalone workflow's intermediate steps (`rke2 reconcile`,
`pulumi <stack>-resources`, `charts deploy --substrate aws`) must all run between the operator's
`prodbox aws setup` and the operator's `prodbox aws teardown`. A targeted AWS-substrate test is
not part of that manual window; `prodbox test integration <name> --substrate aws` owns the
temporary operational credential lifecycle itself.

The standalone substrate-provisioning step list is owned by
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.5.c Sprint Workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
this section is the credentials-side contract that workflow cites.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
