# ACME Provider Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md

> **Purpose**: Define the supported ACME provider choices for `prodbox config setup`.

---

## 1. Supported Providers

`prodbox config setup` supports exactly two public ACME providers:

1. ZeroSSL
2. Let's Encrypt

Both use public ACME DNS-01 issuance through Route 53. The operator chooses the provider during the
interactive setup flow.

---

## 2. ZeroSSL

ZeroSSL is the recommended guided option in `prodbox config setup`.

Required preparation:

1. Create an account at <https://app.zerossl.com>.
2. Open **Developer** settings.
3. Generate EAB credentials.
4. Capture both the EAB Key ID and the EAB HMAC key.

Canonical production server URL:

```text
https://acme.zerossl.com/v2/DV90
```

Use ZeroSSL when:

1. you want the wizard's default recommended path
2. you already operate ZeroSSL credentials
3. you are comfortable storing EAB values in the Dhall config

---

## 3. Let's Encrypt

Let's Encrypt is the simpler no-account path.

Required preparation:

1. No account creation is required.
2. No EAB credentials are required.
3. Provide one valid email address for expiry notices.

Canonical production server URL:

```text
https://acme-v02.api.letsencrypt.org/directory
```

Use Let's Encrypt when:

1. you want the fewest setup steps
2. you do not want to manage EAB credentials
3. you only need the standard public ACME production endpoint

---

## 4. Operator Choice Rule

Choose one provider per environment and keep the matching fields coherent:

1. ZeroSSL requires `acme.eab_key_id` and `acme.eab_hmac_key`.
2. Let's Encrypt requires both EAB fields to remain unset.
3. Both providers require a valid `acme.email`.

`prodbox config setup` enforces the supported field combinations before it writes the config.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md](../../DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md)
