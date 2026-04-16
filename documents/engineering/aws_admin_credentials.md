# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md

> **Purpose**: Define the test-only `aws_admin` credential harness and the supported way to populate
> it in `prodbox-config.dhall`.

---

## 1. Purpose And Scope

The `aws_admin` section exists only for elevated administrative flows:

1. `prodbox aws setup`
2. `prodbox aws teardown`
3. `prodbox aws check-quotas`
4. `prodbox aws request-quotas`
5. `poetry run prodbox test integration aws-iam`

Normal runtime commands ignore `aws_admin.*`. The supported steady-state AWS credentials for normal
`prodbox` operation live only in `aws.*`.

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
3. Empty `aws_admin.*` values are valid when you are not running admin flows.

---

## 3. How To Populate It

Use one temporary elevated credential set from the AWS account:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. root fallback only when intentionally using a break-glass path: account menu ->
   Security credentials -> Access keys -> Create access key
3. open `prodbox-config.dhall`
4. place the elevated key in `aws_admin.*`
5. keep the normal operational key in `aws.*`
6. run `poetry run prodbox config validate`

This split is deliberate:

1. `aws.*` is the operational identity used by normal `prodbox` runtime
2. `aws_admin.*` is the elevated identity used only when an admin lifecycle command or the IAM
   lifecycle integration suite needs it

---

## 4. Cleanup Rule

Do not treat `aws_admin.*` as the default working credential source.

After you finish the administrative task:

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
