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

1. `./.build/prodbox test integration aws-iam`
2. `./.build/prodbox test all` when the aggregate runner reaches the native IAM suite
3. repository tests that simulate the interactive elevated-credential workflow

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

Populate `aws_admin_for_test_simulation.*` only when preparing the native IAM lifecycle test
harness or another repository test that needs to simulate the interactive elevated-credential
workflow:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. open `prodbox-config.dhall`
3. place the elevated key in `aws_admin_for_test_simulation.*`
4. keep the normal operational key in `aws.*`
5. run `./.build/prodbox config validate`
6. run `./.build/prodbox test integration aws-iam`

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
