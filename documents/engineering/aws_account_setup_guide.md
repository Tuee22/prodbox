# AWS Account Setup Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md

> **Purpose**: Define the supported operator flow for creating or preparing an AWS account before
> running `prodbox config setup`.

---

## 1. Supported Onboarding Goal

The supported onboarding path is:

```text
prodbox config setup
```

That flow expects one AWS account, one accessible Route 53 hosted zone, and one temporary admin
credential set (historically called "elevated credential") that exists only long enough for
`prodbox` to create the dedicated operational IAM user and write the steady-state `aws.*`
section in `prodbox-config.dhall`.

The supported goal is full from-scratch bootstrap: `prodbox` can create the operational AWS
credentials it needs once the operator supplies one temporary admin credential interactively.

---

## 2. Create Or Prepare The AWS Account

If you do not already have an AWS account:

1. Sign up at <https://aws.amazon.com>.
2. Choose the Free Tier path during account creation.
3. Add a payment method. AWS requires it even for Free Tier usage.
4. Complete the identity-verification step.
5. Keep the Basic support plan unless you intentionally need paid support.

Free Tier context relevant to `prodbox`:

1. EC2 includes up to 750 hours/month of `t2.micro` or `t3.micro` for the first 12 months.
2. Route 53 is not fully free-tiered; hosted zones and queries are billed separately.
3. S3 includes a limited free storage allowance, but `prodbox` does not depend on S3 for the
   supported local-runtime path.

---

## 3. Create One Temporary Admin Access Key

`prodbox config setup` and the public `prodbox aws ...` command family need one temporary admin
AWS credential set presented interactively so they can:

1. list AWS regions
2. list Route 53 hosted zones
3. create or refresh the dedicated `prodbox` IAM user
4. attach the supported inline policy
5. request baseline service quota increases when required

The simplest supported operator workflow is:

1. Preferred path: open AWS console -> IAM -> Users -> your temporary admin user ->
   Security credentials -> Create access key.
2. Paste the access key ID and secret access key into the `prodbox` prompts; include the session
   token too if AWS gave you one.
3. Keep the key only long enough to finish the interactive `prodbox` command you are running.
4. Delete the key after `prodbox` has written its own operational `aws.*` credentials.

### 3.1 Two Credential Shapes — When To Paste A Session Token

AWS returns admin credentials in one of two shapes. The session-token prompt applies to only
one of them:

| Credential source | Access key ID prefix | Session token? | When to use |
|---|---|---|---|
| IAM console → Users → Security credentials → Create access key | `AKIA…` | **No, leave blank** | Long-lived IAM user keys |
| IAM Identity Center "Access keys" panel, `aws sts get-session-token`, `aws sts assume-role`, EC2 instance metadata | `ASIA…` | **Yes, required** | STS-derived temporary credentials |

If you paste an `ASIA…` key without the matching session token, AWS rejects every subsequent
API call with `InvalidClientTokenId`. If you paste an `AKIA…` key and also fill the
session-token field, AWS rejects every call because the session token is invalid for a
long-lived key.

Sprint `7.7` (May 19, 2026 closure, see
[`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` § Sprint 7.7](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md))
made the prompt auto-detect from the access-key prefix: `AKIA…` skips the session-token
prompt entirely, `ASIA…` makes the session-token prompt required (hidden input), and any
other prefix falls back to an optional prompt with an explanatory hint. The operator no
longer has to remember when to leave the field blank.

Do not treat `aws_admin_for_test_simulation.*` as the ordinary operator path for this workflow.
That section is reserved for suite-driven destructive validation and long-lived teardown /
provisioning flows (`aws-ses` and `prodbox nuke`) that need the same admin credential class. The
canonical rules live in
[aws_admin_credentials.md](./aws_admin_credentials.md).

---

## 4. Create Or Confirm A Route 53 Hosted Zone

Before running `prodbox config setup`, the account must already contain at least one public Route 53
hosted zone.

Minimum supported preparation:

1. Register a domain or delegate an existing domain to Route 53.
2. Create a public hosted zone for that domain.
3. Confirm the hosted zone appears in the Route 53 console.
4. Confirm the domain's authoritative nameservers match the Route 53 zone when public-host proof is
   part of your target validation path.

`prodbox config setup` selects from the live hosted-zone list returned by the AWS CLI. It does not
create the hosted zone for you.

---

## 5. Run The Supported Setup Flow

Once the account, hosted zone, and temporary admin key are ready:

```bash
prodbox config setup
```

The wizard walks through:

1. region selection from live AWS data
2. hosted-zone selection from live AWS data
3. FQDN and deployment defaults
4. ACME provider selection
5. dedicated IAM user creation
6. `prodbox-config.dhall` write and direct-Dhall validation

The supported public setup path prompts for the temporary admin credential when needed. It does
not require pre-populating `aws_admin_for_test_simulation.*`.

---

## 6. Post-Setup Cleanup

After the wizard succeeds:

1. delete the temporary admin access key you used for setup
2. keep the generated `aws.*` operational credentials in `prodbox-config.dhall`
3. leave `aws_admin_for_test_simulation.*` empty unless you are intentionally preparing the native
   IAM lifecycle test harness, another repository test that simulates the interactive
   temporary-admin-credential prompt, a long-lived stack operation, or `prodbox nuke`

Normal `prodbox` runtime uses only the operational `aws.*` section.

## Related Documents

- [acme_provider_guide.md](./acme_provider_guide.md)
- [aws_admin_credentials.md](./aws_admin_credentials.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
