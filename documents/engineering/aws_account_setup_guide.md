# AWS Account Setup Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md
**Generated sections**: none

> **Purpose**: Define the supported operator flow for creating or preparing an AWS account before
> running `prodbox config setup`.

---

## 1. Supported Onboarding Goal

The supported onboarding path is:

```text
prodbox config setup
```

That flow expects one AWS account, one accessible Route 53 hosted zone, and one ephemeral
elevated/admin credential set that the operator pastes at the interactive prompt
(`SecretRef.Prompt`). That credential is held in memory for one command, used once to mint the
dedicated least-privilege operational `prodbox` IAM identity, then discarded — it is never
written to `prodbox.dhall`, never stored in Vault, and never persisted to disk. The
generated operational `aws.*` credential is minted straight into Vault KV
(`secret/gateway/gateway/aws`); `prodbox.dhall` carries only a `SecretRef.Vault`
reference to it.

The supported goal is full from-scratch bootstrap: `prodbox` can create the operational AWS
credentials it needs once the operator supplies one ephemeral elevated credential interactively
at the prompt. See [vault_doctrine.md § 3](./vault_doctrine.md) for the `SecretRef` model and
[§ 4](./vault_doctrine.md) for the config split.

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

`prodbox config setup` and the public `prodbox aws ...` command family need one ephemeral
elevated/admin AWS credential set presented interactively at the prompt (`SecretRef.Prompt`) so
they can:

1. list AWS regions
2. list Route 53 hosted zones
3. create or refresh the dedicated `prodbox` IAM user
4. attach the supported inline policy
5. request baseline service quota increases when required

The simplest supported operator workflow is:

1. Preferred path: open AWS console -> IAM -> Users -> your temporary admin user ->
   Security credentials -> Create access key.
2. Paste the access key ID and secret access key into the `prodbox` prompts; include the session
   token too if AWS gave you one. This is the only runtime path by which elevated/admin AWS power
   enters `prodbox` — the prompted credential is held in memory, used once, then discarded.
3. Keep the key only long enough to finish the interactive `prodbox` command you are running.
4. Delete the key after `prodbox` has minted its own operational `aws.*` credential into Vault KV.

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

`aws_admin_for_test_simulation.*` is **not** an operator path at all. It is a test-harness-only
fixture living in `test-secrets.dhall` (`TestPlaintext` class) whose sole purpose is to drive the
UI — feeding the same interactive prompts a real operator answers so the harness can exercise
admin-credentialed flows non-interactively. Real operators **always** paste the ephemeral
elevated credential at the interactive prompt described in section 3 above; there is no
production path that reads a stored admin credential. The fixture is never imported by
`prodbox.dhall`, never read by any production binary, and never stored in Vault. The
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

Once the account, hosted zone, and ephemeral elevated/admin key are ready:

```bash
prodbox config setup
```

The wizard walks through:

1. region selection from live AWS data
2. hosted-zone selection from live AWS data
3. FQDN and deployment defaults
4. ACME provider selection
5. dedicated least-privilege `prodbox` IAM identity creation — performed after Vault is set up and
   unsealed, using the prompted elevated credential, with the generated `aws.*` credential minted
   straight into Vault KV (`secret/gateway/gateway/aws`)
6. `prodbox.dhall` write (carrying only a `SecretRef.Vault` reference to the generated
   `aws.*` credential) and direct-Dhall validation

The supported public setup path prompts for the ephemeral elevated credential when needed
(`SecretRef.Prompt`). The credential-supplying interaction happens after Vault is unsealed, and
the moment the generated `prodbox` IAM credential exists it is written straight into Vault — it
never transits cleartext storage. This path does not read any stored admin credential;
`aws_admin_for_test_simulation.*` is a `test-secrets.dhall` fixture used only by the test harness
to simulate this prompt.

---

## 6. Post-Setup Cleanup

After the wizard succeeds:

1. delete the ephemeral elevated/admin access key you pasted at the prompt for setup
2. the generated `aws.*` operational credential lives in Vault KV (`secret/gateway/gateway/aws`);
   `prodbox.dhall` carries only a `SecretRef.Vault` reference to it, never the plaintext key
3. `aws_admin_for_test_simulation.*` is not a `prodbox.dhall` field — it lives in
   `test-secrets.dhall` as a `TestPlaintext` fixture for the native IAM lifecycle test harness (and
   other repository tests that simulate the interactive elevated-credential prompt), never in
   production config and never in Vault

Normal `prodbox` runtime resolves the operational `aws.*` section from Vault via its
`SecretRef.Vault` reference.

## Related Documents

- [acme_provider_guide.md](./acme_provider_guide.md)
- [aws_admin_credentials.md](./aws_admin_credentials.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
