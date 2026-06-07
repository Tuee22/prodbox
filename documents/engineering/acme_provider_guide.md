# ACME Provider Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/config_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md
**Generated sections**: none

> **Purpose**: Define the supported ACME provider choices for `prodbox config setup`.

---

## 1. Supported Providers

`prodbox config setup` supports exactly two public ACME providers:

1. ZeroSSL
2. Let's Encrypt

Both use public ACME DNS-01 issuance through Route 53. The operator chooses the provider during the
interactive setup flow.

The guided setup default is Let's Encrypt because it has no EAB dependency and its production ACME
directory is the stable validation path for repository-owned live tests. ZeroSSL remains supported
for operators who already manage working EAB credentials and have verified that the ZeroSSL ACME
directory returns ACME JSON from their environment.

---

## 2. ZeroSSL

ZeroSSL is the explicit EAB-backed option in `prodbox config setup`.

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

1. you already operate ZeroSSL credentials
2. you are comfortable storing EAB values in the Dhall config
3. you have verified that `https://acme.zerossl.com/v2/DV90` returns an ACME JSON directory

Supported cluster projection:

1. `acme.eab_key_id` is rendered into the supported `ClusterIssuer` as
   `spec.acme.externalAccountBinding.keyID`.
2. `acme.eab_hmac_key` is rendered into the `cert-manager` namespace as the
   `acme-eab-credentials` secret and referenced from
   `spec.acme.externalAccountBinding.keySecretRef`.
3. The Haskell lifecycle reconcile omits `externalAccountBinding` entirely when the selected
   provider does not use EAB.

---

## 3. Let's Encrypt

Let's Encrypt is the recommended no-account path.

Required preparation:

1. No account creation is required.
2. No EAB credentials are required.
3. Provide one valid email address for expiry notices.

Canonical production server URL:

```text
https://acme-v02.api.letsencrypt.org/directory
```

Use Let's Encrypt when:

1. you want the repository validation default
2. you want the fewest setup steps
3. you do not want to manage EAB credentials
4. you only need the standard public ACME production endpoint

---

## 4. Operator Choice Rule

Choose one provider per environment and keep the matching fields coherent:

1. ZeroSSL requires `acme.eab_key_id` and `acme.eab_hmac_key`.
2. Let's Encrypt requires both EAB fields to remain unset.
3. Both providers require a valid `acme.email`.

`prodbox config setup` enforces the supported field combinations before it writes the config.

---

## 5. Production Rate Limits and the Two-Issuer Model

This model is scheduled by Sprints `4.24` / `7.11` / `8.7` in
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md); it is documented here ahead
of implementation.

### The Let's Encrypt production duplicate-certificate limit

Let's Encrypt production enforces a duplicate-certificate rate limit: at most five identical
certificates per rolling seven-day **provider window** (the same set of FQDNs counts as a
duplicate regardless of how many times it is ordered). The prodbox canonical test suite is
designed to repeatedly tear down and rebuild the substrate, so a loop that orders a fresh
production certificate on every rebuild exhausts this window and then fails to issue.

### Staging for churn, production retained once

The fix renders two cert-manager `ClusterIssuer`s that share one DNS-01 Route 53 solver:

1. `letsencrypt-http01` — the production issuer, built from `acme.server`.
2. `letsencrypt-staging-http01` — the Let's Encrypt staging issuer, built from a new
   `acme.staging_server` config field (default
   `https://acme-staging-v02.api.letsencrypt.org/directory`).

The high-churn canonical validation loop uses the staging issuer. Staging is effectively
unlimited, runs the identical DNS-01 flow, and returns untrusted certificates — which is
acceptable for automated gates that only need the issuance path exercised, not browser trust.

The production certificate is issued once and retained as a `LongLived` managed resource in the
long-lived `pulumi_state_backend` S3 bucket under the substrate-scoped key
`public-edge-tls/<substrate>/<fqdn>`. It is restored before every issuance, so production is
genuinely exercised but never re-ordered on each rebuild cycle. For the retention,
restore-before-issuance, and bucket-key mechanics, see
[helm_chart_platform_doctrine.md § 10](./helm_chart_platform_doctrine.md#10-required-settings-and-auto-generated-secrets)
and [envoy_gateway_edge_doctrine.md § 5](./envoy_gateway_edge_doctrine.md#5-authentication-doctrine).
For the `LongLived` classification in the managed-resource registry and why the retained
certificate is correctly retained rather than treated as a leak, see
[lifecycle_reconciliation_doctrine.md § 2](./lifecycle_reconciliation_doctrine.md#2-state-lifetime-rule)
and
[../../DEVELOPMENT_PLAN/substrates.md § Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

### Issuer selection

An `IssuerClass` value selects which `ClusterIssuer` the keycloak chart `Certificate` references
at deploy time:

1. `Staging` — the canonical suite's high-churn rebuild loop references
   `letsencrypt-staging-http01`.
2. `Production` — the production-proof run references `letsencrypt-http01` and exercises the
   retained, restore-before-issuance production certificate.

Both classes resolve through the same shared DNS-01 Route 53 solver; only the ACME directory and
the resulting trust differ.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md)
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md)
- [envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md)
- [../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
