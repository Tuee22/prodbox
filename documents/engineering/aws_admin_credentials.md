# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md

> **Purpose**: Define the test-suite-only `aws_admin_for_test_simulation` section in
> `prodbox-config.dhall` and the supported way to populate and clear it.

---

## 1. Purpose And Scope

The repository rule is: do not store admin credentials for ordinary operator flows. The one
supported exception is `prodbox-config.dhall` `aws_admin_for_test_simulation.*`, and that section
exists only to let the test suite simulate the ephemeral elevated credential that a human would
otherwise type interactively.

The `aws_admin_for_test_simulation` section exists only for:

1. `prodbox test integration aws-iam`
2. `prodbox test integration all`
3. `prodbox test all` when the aggregate runner reaches the native IAM suite
4. repository tests that simulate the interactive elevated-credential workflow

Normal runtime commands use `aws.*`. Public `prodbox config setup` and public `prodbox aws ...`
commands obtain temporary elevated credentials interactively and must not treat
`aws_admin_for_test_simulation.*` as their supported credential source. The native IAM suite is
the only supported runtime consumer of this stored section.

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
   running the native IAM lifecycle test harness or a repository test that simulates the
   interactive elevated-credential workflow.

---

## 3. How To Populate It

Populate `aws_admin_for_test_simulation.*` only when preparing the suite-level native IAM
lifecycle harness or another repository test that needs to simulate the interactive elevated-
credential workflow:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. open `prodbox-config.dhall`
3. place the elevated key in `aws_admin_for_test_simulation.*`
4. leave `aws.*` blank or treat any pre-existing value there as disposable suite residue
5. run `prodbox config validate`
6. run `prodbox test integration aws-iam`

The native IAM suite fails in the Phase `1/2` prerequisite gate when
`aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise incomplete
harness config.

This split is deliberate:

1. `aws.*` is the operational identity used by normal `prodbox` runtime
2. `aws_admin_for_test_simulation.*` is the stored simulation of the ephemeral elevated identity
   used only by the test suite
3. the native IAM lifecycle validation harness is the only supported runtime consumer of that
   stored simulation
4. public onboarding and public `prodbox aws ...` commands still use temporary interactive prompts
   when they need elevated credentials

---

## 4. Cleanup Rule

Do not treat `aws_admin_for_test_simulation.*` as the default working credential source.

When `prodbox test integration aws-iam`, `prodbox test integration all`, or
`prodbox test all` runs with the native IAM harness, `prodbox` now:

1. deletes any pre-existing dedicated `prodbox` IAM user and that user's access keys before fresh
   provisioning
2. uses any pre-existing operational `aws.*` only to discover and delete the IAM user associated
   with those credentials when that identity can still be resolved through STS
3. materializes fresh operational `aws.*` only for the duration of the managed suite run
4. clears operational `aws.*` again before the suite returns, including prerequisite failure paths

After you finish the native IAM validation task:

1. remove or blank `aws_admin_for_test_simulation.access_key_id`
2. remove or blank `aws_admin_for_test_simulation.secret_access_key`
3. remove or blank `aws_admin_for_test_simulation.region`
4. clear `aws_admin_for_test_simulation.session_token` unless you intentionally keep a
   session-based test simulation

The repository accepts an empty `aws_admin_for_test_simulation` section specifically so elevated
credentials can be short-lived.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md](../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md)
