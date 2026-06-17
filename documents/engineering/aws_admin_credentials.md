# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md, [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md), [vault_doctrine.md](./vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Define the `aws_admin_for_test_simulation` test-harness fixture in
> `test-config.dhall` and the supported way to populate and clear it so the test harness can
> simulate the operator at the interactive temporary-admin prompt for suite-driven destructive
> validation.

---

## 1. Purpose And Scope

The repository rule is: there is exactly one runtime path by which elevated/admin AWS power
enters `prodbox` — the interactive `SecretRef.Prompt` arm. No production binary reads a stored
admin credential from `prodbox-config.dhall`. The `aws_admin_for_test_simulation.*` block is a
**test-harness-only fixture** that lives solely in `test-config.dhall`; its sole purpose is to
simulate the operator at that interactive temporary-admin prompt, so the test harness can
exercise admin-credentialed flows non-interactively. It is not a section of
`prodbox-config.dhall` and not a credential source for real operator flows.

The `aws_admin_for_test_simulation` fixture exists for:

1. `prodbox test integration aws-iam`
2. `prodbox test integration all`
3. `prodbox test all` when the aggregate runner reaches the native IAM suite
4. repository tests that simulate the interactive temporary-admin-credential prompt
5. test-harness coverage of the long-lived stack operations (`prodbox aws stack aws-ses
   reconcile`, `prodbox aws stack aws-ses destroy`, `prodbox aws stack aws-ses
   migrate-backend`) and `prodbox nuke`

Normal runtime commands use the generated operational `aws.*` identity (a `SecretRef.Vault`
reference; see §"AWS credentials under Vault"). Every real flow that needs elevated/admin AWS
power — public `prodbox config setup`, public `prodbox aws ...`, the native IAM harness, the
long-lived `aws-ses` stack operations, and `prodbox nuke` — prompts for the ephemeral elevated
credential through the interactive `SecretRef.Prompt` arm. They must not treat
`aws_admin_for_test_simulation.*` as their credential source. In tests, the harness simulates
that prompt by feeding `aws_admin_for_test_simulation.*` from `test-config.dhall`. The
`SecretRef.Prompt` arm and config-split rule are owned by
[vault_doctrine.md §3](./vault_doctrine.md) and [§4](./vault_doctrine.md); this document owns
the `aws_admin_for_test_simulation` fixture specifics.

---

## 2. Dhall Shape

The `aws_admin_for_test_simulation` fixture is `TestPlaintext`-class and lives only in
`test-config.dhall` (never in `prodbox-config.dhall`, never in Vault). It carries the plaintext
admin key the harness types into the temporary-admin prompt on the operator's behalf:

```dhall
-- test-config.dhall (test-harness-only fixture; never imported by prodbox-config.dhall)
let TestConfig = ./test-config-types.dhall

in  TestConfig.default // {
      aws_admin_for_test_simulation = TestConfig.default.aws_admin_for_test_simulation // {
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
   running the native IAM lifecycle test harness or another repository test that simulates the
   interactive temporary-admin-credential prompt.

---

## 3. How To Populate It

Populate `aws_admin_for_test_simulation.*` only when preparing the suite-level native IAM
lifecycle harness or another repository test that needs to simulate the interactive
temporary-admin-credential prompt. This is a test-harness-only step:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. open `test-config.dhall`
3. place the temporary admin key in `aws_admin_for_test_simulation.*`
4. never copy it into `prodbox-config.dhall`, never import `test-config.dhall` from
   `prodbox-config.dhall`, and never write it to Vault
5. run the intended test entrypoint (`prodbox test integration aws-iam`,
   `prodbox test integration all`, `prodbox test all`, etc.)

The native IAM suite fails in the Phase `1/2` prerequisite gate when
`aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise incomplete
harness fixture.

This split is deliberate:

1. the generated operational `aws.*` identity (a `SecretRef.Vault` reference) is used by normal
   `prodbox` runtime
2. `aws_admin_for_test_simulation.*` is the `TestPlaintext` fixture in `test-config.dhall` that
   simulates the operator at the temporary-admin prompt for suite-driven destructive validation
3. real elevated/admin flows (public onboarding, `prodbox aws ...`, the long-lived `aws-ses`
   stack operations, `prodbox nuke`) always prompt for the ephemeral elevated credential through
   the interactive `SecretRef.Prompt` arm; in tests the harness simulates that prompt from
   `test-config.dhall`

---

## 4. Cleanup Rule

Do not treat `aws_admin_for_test_simulation.*` as a working credential source for any production
flow; it is a `test-config.dhall` fixture only. The steady state of `prodbox-config.dhall` has no
admin block at all.

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

After you finish the native IAM validation task, blank the fixture in `test-config.dhall`:

1. remove or blank `aws_admin_for_test_simulation.access_key_id`
2. remove or blank `aws_admin_for_test_simulation.secret_access_key`
3. remove or blank `aws_admin_for_test_simulation.region`
4. clear `aws_admin_for_test_simulation.session_token` unless you intentionally keep a
   session-based destructive-validation credential

The repository accepts an empty `aws_admin_for_test_simulation` fixture specifically so temporary
admin credentials can be short-lived. `prodbox-config.dhall` never carries this block at all.

### 4.1 Harness Teardown Residue Policy (Sprint 7.7 → superseded for the postflight by Sprint 7.9)

**Sprint 7.7 history (correct pre-Sprint-4.10).** When Sprint 7.7 (May 19, 2026) introduced
the harness-internal `BypassPerRunResidueOnly` policy, the long-lived `aws-ses` Pulumi stack
was managed with *operational* `aws.*` credentials, so clearing operational `aws.*` at the end
of a run genuinely stranded `aws-ses` from its destroy surface. Refusing to clear `aws.*`
while `aws-ses` was live was therefore the correct behavior at that time: per-run stacks
(`aws-eks`, `aws-eks-subzone`, `aws-test`) were bypassed because `awsPostflightDestroyActions`
handles them in the same suite-exit unwind, but `aws-ses` caused an actionable refusal.

**Sprint 4.10 invalidated the premise.** Sprint 4.10 (May 21, 2026) moved `aws-ses` off
operational `aws.*` and onto the elevated/admin credential class. Sprint `7.14` kept the main
`aws-ses` reconcile/destroy/sync paths on that admin credential class while routing Pulumi
checkpoint state through the encrypted Model-B backend (`pulumiSesProviderBaseEnv` +
`Prodbox.Pulumi.EncryptedBackend`); `pulumiSesAdminBaseEnv` remains only as the optional
first-touch legacy checkpoint source for old long-lived S3 state. Clearing operational `aws.*` can
no longer strand `aws-ses` — the elevated admin credential that drives it is supplied per
operation and is never derived from operational `aws.*` (see
[lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md)).

> **Corrective (Sprint 7.16).** The code these history notes describe still reads the admin
> credential from a stored config section (`loadAdminAwsCredentials`) rather than prompting for
> the ephemeral elevated credential. Under the corrected model, real `aws-ses` reconcile/destroy/
> migrate-backend and `prodbox nuke` prompt for the ephemeral elevated credential through the
> interactive `SecretRef.Prompt` arm — exactly as `prodbox aws setup` does — and the test harness
> simulates that prompt from `aws_admin_for_test_simulation.*` in `test-config.dhall`. There is no
> stored admin section in `prodbox-config.dhall`. Reconciling these code paths with the corrected
> model is scheduled as Sprint 7.16; the dated notes below describe the pre-7.16 behavior.

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
   cooldown): either `prodbox aws stack aws-ses destroy --yes` (admin-credentialed; does not
   require operational `aws.*`) followed by `prodbox aws teardown`, or — Sprint 7.7 —
   `prodbox aws teardown --destroy-pulumi-residue` in one step (warns about the SES costs
   before dispatching).

---

## 5. Standalone Substrate-Provisioning Credentials

Operational `prodbox.aws.*` is the steady-state credential surface for operator-driven
AWS-touching `prodbox` commands. It is consumed by, at minimum:

- `prodbox cluster reconcile` (cert-manager Route 53 DNS01 issuance)
- `prodbox aws stack <stack> reconcile` and `prodbox aws stack <stack> destroy` for the **per-run**
  stacks under `pulumi/`: `aws-eks`, `aws-eks-subzone`, `aws-test`
- `prodbox charts reconcile ... --substrate aws` and `prodbox charts delete ... --substrate aws`
- `prodbox edge status` when the host's substrate selection points at AWS

Outside a managed test harness, the above fail fast with `aws.access_key_id must not be empty`
when the operational section is unpopulated. There is no fallback to host AWS state, host
profiles, or instance metadata — see
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) for the
no-ambient-auth rule. Named validations under
`prodbox test integration <name> --substrate aws` are the automation exception: the test runner
first mints the operational `prodbox` IAM identity by simulating the temporary-admin prompt from
`aws_admin_for_test_simulation.*` in `test-config.dhall` (writing the generated `aws.*` into
Vault), runs the validation, destroys any per-run stacks the validation may have provisioned, and
clears the materialized operational credentials again.

The **long-lived** stack `aws-ses` is the exception: per Sprint 4.10 it is elevated/admin-
credentialed, not operationally credentialed. `prodbox aws stack aws-ses reconcile` and
`prodbox aws stack aws-ses destroy` therefore do **not** require operational `aws.*` to be
populated — they do not fail fast on an empty operational section. Under the corrected model these
ops prompt for the ephemeral elevated credential through the interactive `SecretRef.Prompt` arm
(the harness simulates that prompt from `test-config.dhall`); reconciling the current
`loadAdminAwsCredentials` / `pulumiSesProviderBaseEnv` code paths with this model is scheduled as
Sprint 7.16 (§4.1). This is why the Sprint 7.9 harness postflight can clear operational `aws.*`
even while `aws-ses` is live without stranding it. The credential-class assignment is owned by
[lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md) (long-lived
stacks + retained-bucket compatibility → elevated/admin creds; per-run stacks → operational
`aws.*`).

There is exactly one runtime way elevated/admin power enters `prodbox` — the interactive
`SecretRef.Prompt` arm. Real flows prompt; the test harness simulates that prompt. The rows below
distinguish *who answers the prompt*, not separate credential stores:

| Workflow shape | How elevated/admin power is supplied | Entrypoints |
|----------------|-----------------|-------------|
| Standalone substrate provisioning (e.g. the [Sprint 7.5.c.v operator workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)) | **Public prompt path**: `prodbox aws setup` — prompts interactively (the `SecretRef.Prompt` arm) for one ephemeral elevated credential pasted from the AWS console; mints the dedicated least-privilege `prodbox` IAM identity via STS federation; writes the generated `aws.*` into Vault KV (`SecretRef.Vault`). The prompted elevated credential is held in memory for the one command and then discarded — never written to `prodbox-config.dhall`, never stored in Vault. | `prodbox aws setup` at start; `prodbox aws teardown` at end |
| Suite-driven runs (the canonical test surface) | **Test-harness simulation path**: the harness simulates the same prompt by feeding `aws_admin_for_test_simulation.*` from `test-config.dhall` (a `TestPlaintext` fixture); `runAwsIamHarnessSetup` runs the same prompt-mint-write-to-Vault-discard contract non-interactively. | `prodbox test integration aws-iam`, `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, `prodbox test all` |
| Long-lived shared-infrastructure operations | **Same prompt path as standalone**: `aws-ses` reconcile/destroy/migrate-backend and `prodbox nuke` prompt for the ephemeral elevated credential through the interactive `SecretRef.Prompt` arm (the harness simulates that prompt from `test-config.dhall`); no operational `aws.*` is materialized. Reconciling the current `loadAdminAwsCredentials` / `pulumiSesProviderBaseEnv` code paths with this prompt model is scheduled as Sprint 7.16 (§4.1). | `prodbox aws stack aws-ses reconcile`, `prodbox aws stack aws-ses destroy --yes`, `prodbox aws stack aws-ses migrate-backend`, `prodbox nuke` |

These paths are not mixed in a single workflow. A standalone substrate run uses
`prodbox aws setup` and `prodbox aws teardown` symmetrically; a suite-driven run lets the
harness own setup, per-run-stack cleanup when applicable, and teardown end-to-end; long-lived
shared-infrastructure operations prompt for the ephemeral elevated credential and do not
materialize operational `aws.*`. Per Sprint `7.3`, the standalone and suite-driven paths clear
operational
`aws.*` before they return, so a standalone workflow's intermediate steps (`rke2 reconcile`,
`pulumi <stack> reconcile`, `charts deploy --substrate aws`) must all run between the operator's
`prodbox aws setup` and the operator's `prodbox aws teardown`. A targeted AWS-substrate test is
not part of that manual window; `prodbox test integration <name> --substrate aws` owns the
temporary operational credential lifecycle itself.

The standalone substrate-provisioning step list is owned by
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.5.c Sprint Workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
this section is the credentials-side contract that workflow cites.

## AWS credentials under Vault

Vault holds production secrets only; none of our testing secrets live in Vault. The generated
operational `prodbox` IAM identity — the least-privilege `aws.*` access key `prodbox` mints — is
written straight into Vault KV (`secret/gateway/gateway/aws`) the instant it is created and is
referenced from Dhall only by `SecretRef.Vault`, never stored as plaintext in
`prodbox-config.dhall` and never transiting cleartext storage.

The credential-supplying interaction happens **after** Vault is set up and unsealed, because the
generated credential is minted directly into Vault. The order is:

1. bring up and unseal Vault
2. the operator at the interactive `SecretRef.Prompt` (or, in tests, the harness simulating it
   from `aws_admin_for_test_simulation.*` in `test-config.dhall`) supplies the ephemeral elevated
   credential
3. `prodbox` uses it once to mint the dedicated least-privilege `prodbox` IAM identity
4. `prodbox` writes the generated `aws.*` credential into Vault KV (`secret/gateway/gateway/aws`)
5. `prodbox` discards the prompted elevated credential

Prompt-use-discard is the only handling for the ephemeral elevated credential: it is never written
to `prodbox-config.dhall`, never stored in Vault, never persisted to disk. (AWS secrets moved into
Vault KV under Sprint 7.14. For the root AWS schema, **only** the generated operational `aws.*` is
a `SecretRef.Vault` reference; Pulumi provider resolution requires `secret/gateway/gateway/aws`
through `Prodbox.Infra.AwsProviderCredentials`, and there is no raw config fallback.)

In-cluster consumers of these AWS credentials authenticate to Vault directly via Vault Kubernetes
auth; there is no gateway-side Secret-mounted `aws.dhall` fragment in the delivery path.

The `aws_admin_for_test_simulation.*` fixture is **not** part of the Vault model. It is a
`TestPlaintext`-class fixture that lives only in `test-config.dhall` — never imported by
`prodbox-config.dhall`, never read by any production binary, never stored in Vault, never copied
into generated cluster config or MinIO. It is a retained test-harness simulation input (not
deletable residue); its meaning, population, and cleanup rules in §1–§4 are unchanged. See
[vault_doctrine.md §13](./vault_doctrine.md#13-config-and-state-classification) for the
authoritative config-and-state classification, and [vault_doctrine.md §4](./vault_doctrine.md) for
the `prodbox-config.dhall` / `test-config.dhall` split this fixture obeys.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
