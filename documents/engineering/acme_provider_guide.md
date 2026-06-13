# ACME Provider Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/config_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/vault_doctrine.md
**Generated sections**: none

> **Purpose**: Define the supported ACME provider for `prodbox config setup`.

---

## 1. Supported Provider

`prodbox` uses exactly one public ACME provider: **ZeroSSL**.

ZeroSSL issues through public ACME DNS-01 over Route 53, EAB-authenticated. `prodbox config setup`
configures ZeroSSL credentials during the interactive setup flow; there is no provider choice
because ZeroSSL is the only supported provider.

> **Issuer-name note**: the single `ClusterIssuer` is named `zerossl-dns01`, a DNS-01-honest
> name — the issuer solves ACME challenges through a **DNS-01 Route 53 solver**, never HTTP-01,
> and the name now says so. It is one SSoT constant in
> `Prodbox.PublicEdge.publicEdgeClusterIssuerName`, threaded through both chart `values.yaml`
> files and every doc/test site that names the issuer; no second hand-edited copy survives.
> Sprint 7.13 renamed it from the historically-inaccurate HTTP-01-claiming name (which named
> HTTP-01 but ran DNS-01). Because the issuer name is baked into retained ACME account and
> certificate state, the live rename lands on a wipe-and-rebuild boundary; the S3 cert
> retention key is keyed on substrate + FQDN (not the issuer name), so the retained certificate
> restores under the new issuer name without re-ordering from ZeroSSL.

---

## 2. ZeroSSL

ZeroSSL is the EAB-backed ACME provider.

Required preparation:

1. Create an account at <https://app.zerossl.com>.
2. Open **Developer** settings.
3. Generate EAB credentials.
4. Capture both the EAB Key ID and the EAB HMAC key.

Canonical server URL:

```text
https://acme.zerossl.com/v2/DV90
```

Supported cluster projection:

1. `acme.eab_key_id` is rendered into the supported `ClusterIssuer` as
   `spec.acme.externalAccountBinding.keyID`.
2. `acme.eab_hmac_key` is rendered into the `cert-manager` namespace as the
   `acme-eab-credentials` secret and referenced from
   `spec.acme.externalAccountBinding.keySecretRef`.
3. The ZeroSSL ACME account registration is stored under the `zerossl-account-key`
   `privateKeySecretRef`.

---

## 3. Operator Field Rule

Keep the ZeroSSL fields coherent:

1. ZeroSSL requires both `acme.eab_key_id` and `acme.eab_hmac_key`.
2. `acme.server` must be the ZeroSSL ACME directory URL above (an `https://` URL).
3. A valid `acme.email` is required for expiry notices.

`prodbox config setup` and settings validation (`validateAcmeBinding`) enforce these combinations
before the config is accepted: a ZeroSSL `acme.server` with a missing EAB field is rejected.

---

## 4. Single Issuer and Rebuild-Safe Certificate Retention

The Haskell lifecycle reconcile renders one cert-manager `ClusterIssuer`:

```text
zerossl-dns01 — built from acme.server, EAB-authenticated, DNS-01 Route 53 solver
```

The name is DNS-01-honest (the solver is DNS-01 Route 53, and the name says so); it is one SSoT
`Prodbox.PublicEdge.publicEdgeClusterIssuerName` constant. Sprint 7.13 renamed it from the
historically-inaccurate HTTP-01-claiming name (which named HTTP-01 but ran DNS-01); the live
rename lands on a wipe-and-rebuild boundary. Both substrates (home local and AWS) render and
wait on
this single issuer; the `keycloak` chart `Certificate` for the shared listener references it
(`Prodbox.PublicEdge.publicEdgeClusterIssuerName`).

### Rebuild churn and issuance quota

The prodbox canonical test suite repeatedly tears down and rebuilds the substrate. Ordering a
fresh certificate for the same FQDN on every rebuild would consume ZeroSSL issuance quota
needlessly. Instead, the issued public-edge certificate is retained once as a `LongLived` managed
resource in the long-lived `pulumi_state_backend` S3 bucket under the substrate-scoped key
`public-edge-tls/<substrate>/<fqdn>`, and restored before issuance on every rebuild — so the
certificate is issued once and restored thereafter rather than re-ordered each cycle.

For the retention, restore-before-issuance, and bucket-key mechanics, see
[helm_chart_platform_doctrine.md § 10](./helm_chart_platform_doctrine.md#10-required-settings-and-auto-generated-secrets)
and [envoy_gateway_edge_doctrine.md § 5](./envoy_gateway_edge_doctrine.md#5-authentication-doctrine).
For the `LongLived` classification in the managed-resource registry and why the retained
certificate is correctly retained rather than treated as a leak, see
[lifecycle_reconciliation_doctrine.md § 2](./lifecycle_reconciliation_doctrine.md#2-state-lifetime-rule)
and
[../../DEVELOPMENT_PLAN/substrates.md § Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

## ACME credentials under Vault

The ZeroSSL EAB Key ID and EAB HMAC key are scheduled to move out of the plaintext
`acme.eab_key_id` / `acme.eab_hmac_key` config fields into Vault KV, referenced from Dhall by
`SecretRef.Vault` rather than carried as plaintext (scheduled under Sprint 7.15). Certificate
issuance fails closed when Vault is sealed: with the EAB material behind a sealed Vault, the
`ClusterIssuer` cannot authenticate to ZeroSSL and the reconcile surfaces a sealed-Vault error
rather than proceeding.

This extends — and does not replace — the existing ACME model. ZeroSSL remains the sole ACME
provider, and the single-issuer (`zerossl-dns01`) plus S3 retain-restore behavior of
[§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention) is unchanged; only the at-rest EAB
secret gains a Vault home and a `SecretRef.Vault` indirection.

For the TLS and PKI model behind Vault — how the EAB material and TLS private-key paths live under
Vault and why issuance is fail-closed — see
[vault_doctrine.md §11](./vault_doctrine.md#11-tls-and-pki-under-vault).

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md)
- [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md)
- [envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
