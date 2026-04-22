# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md

> **Purpose**: Define the test-harness-only `aws_admin` exception in `prodbox-config.dhall` and the
> supported way to populate and clear it.

---

## 1. Purpose And Scope

The repository rule is: do not store admin credentials for ordinary operator flows. The one
supported exception is `prodbox-config.dhall` `aws_admin.*`, and that exception exists only so the
native IAM lifecycle validation can run non-interactively.

The `aws_admin` section exists only for:

1. `./.build/prodbox test integration aws-iam`
2. `./.build/prodbox test all` when the aggregate runner reaches the native IAM suite

Normal runtime commands use `aws.*`. Public `prodbox config setup` and public `prodbox aws ...`
commands obtain temporary elevated credentials interactively and must not treat `aws_admin.*` as
their supported credential source.

---

## 2. Dhall Shape

The `aws_admin` section mirrors the operational `aws` section:

```dhall
let Config = ./prodbox-config-types.dhall

in  Config.default // {
      aws_admin = Config.default.aws_admin // {
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
3. Empty `aws_admin.*` values are the normal steady state when you are not running the native IAM
   lifecycle test harness.

---

## 3. How To Populate It

Populate `aws_admin.*` only when preparing the native IAM lifecycle test harness:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. root fallback only when intentionally using a break-glass path: account menu ->
   Security credentials -> Access keys -> Create access key
3. open `prodbox-config.dhall`
4. place the elevated key in `aws_admin.*`
5. keep the normal operational key in `aws.*`
6. run `./.build/prodbox config validate`
7. run `./.build/prodbox test integration aws-iam`

The native IAM suite fails in the Phase `1/2` prerequisite gate when `aws_admin.*` is missing,
partial, or paired with an otherwise incomplete harness config.

This split is deliberate:

1. `aws.*` is the operational identity used by normal `prodbox` runtime
2. `aws_admin.*` is the elevated identity used only by the native IAM lifecycle validation harness
3. public onboarding and public `prodbox aws ...` commands still use temporary interactive prompts
   when they need elevated credentials

---

## 4. Cleanup Rule

Do not treat `aws_admin.*` as the default working credential source.

After you finish the native IAM validation task:

1. remove or blank `aws_admin.access_key_id`
2. remove or blank `aws_admin.secret_access_key`
3. remove or blank `aws_admin.region`
4. clear `aws_admin.session_token` unless you intentionally keep a session-based admin harness

The repository accepts an empty `aws_admin` section specifically so elevated credentials can be
short-lived.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md](../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md)
