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

Supported cluster projection (Sprint 7.15 — EAB material is Vault-sourced, never plaintext):

1. `acme.eab_key_id` and `acme.eab_hmac_key` are `SecretRef.Vault` references into the
   `secret/acme/eab` KV object (fields `key_id` / `hmac_key`), not plaintext `Optional Text`.
   The operator/harness seeds that object via `prodbox config setup` (which prompts for the
   ZeroSSL values and writes them to Vault, never to `prodbox.dhall`) or `vault kv put`.
2. The **EAB key ID** is not secret. The host CLI resolves it from Vault
   (`secret/acme/eab#key_id`) at reconcile time and renders it inline into the `ClusterIssuer`
   as `spec.acme.externalAccountBinding.keyID`.
3. The **EAB HMAC key** is materialized into the `cert-manager` namespace as the
   `acme-eab-credentials` Secret by a Vault-login materializer Job — the same Sprint 3.18
   chart-side pattern used for the vscode OIDC client Secret (init container logs into Vault via
   Kubernetes auth, reads `secret/acme/eab#hmac_key`, the main container creates the Secret). The
   HMAC key never transits the operator host and is never rendered as inline plaintext
   `stringData`. The `ClusterIssuer` references it through
   `spec.acme.externalAccountBinding.keySecretRef`.
4. The ZeroSSL ACME account registration is stored under the `zerossl-account-key`
   `privateKeySecretRef`.

---

## 3. Operator Field Rule

Keep the ZeroSSL fields coherent:

1. ZeroSSL requires both `acme.eab_key_id` and `acme.eab_hmac_key`, and each must be a
   `SecretRef.Vault` reference (plaintext is rejected, mirroring the operational `aws.*`
   discipline).
2. `acme.server` must be the ZeroSSL ACME directory URL above (an `https://` URL).
3. A valid `acme.email` is required for expiry notices.

`prodbox config setup` and settings validation (`validateAcmeBinding`) enforce these combinations
before the config is accepted: a ZeroSSL `acme.server` with a missing EAB field is rejected, a
present-without-its-pair field is rejected, and a plaintext (non-`Vault`) EAB reference is
rejected (`acme.eab_* must be a SecretRef.Vault reference`).

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

## ACME credentials and TLS key material under Vault

Vault is the TLS authority for the entire stack. The ZeroSSL EAB Key ID and EAB HMAC key are
Vault KV objects (`secret/acme/eab`, fields `key_id` / `hmac_key`), referenced from Dhall by
`SecretRef.Vault` rather than carried as plaintext in the `acme.eab_key_id` / `acme.eab_hmac_key`
config fields. **Sprint 7.15 landed this EAB-material move** (the config-owned surface): the
fields are `Optional SecretRef`, the HMAC key is materialized in-cluster by a Vault-login Job
(see §2), and `prodbox config validate` rejects any plaintext EAB value. The public ZeroSSL
public-edge certificate keeps the S3 retain-and-restore contract of
[§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention) (unchanged).

The broader native-Vault-PKI internal-cert authority (Vault PKI minting internal certs) and live
ZeroSSL issuance against the Vault-sourced EAB are a separate, non-blocking `Live-proof: pending`
axis — the cert-manager-vs-native-Vault-PKI choice is an open design decision (see
[vault_doctrine.md §18](./vault_doctrine.md#18-open-decisions)); cert-manager remains the issuer
today and only the EAB / key material is Vault-sourced.

Certificate issuance fails closed when Vault is sealed. With the EAB material behind a sealed (or
unreachable, or uninitialized) Vault, the EAB key ID cannot be resolved host-side and the
in-cluster materializer Job cannot read the HMAC key, so the `ClusterIssuer` cannot authenticate
to ZeroSSL — the reconcile surfaces a sealed-Vault error rather than proceeding. This fail-closed
behavior is structurally guaranteed by the `SecretRef.Vault` resolver (a sealed Vault cannot
resolve the reference); there is no plaintext fallback for ACME credentials or TLS keys.

ZeroSSL remains the sole public ACME provider, and the single-issuer (`zerossl-dns01`) plus
S3 retain-restore behavior of [§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention) is
unchanged; only the at-rest key and EAB material gain a Vault home and a `SecretRef.Vault`
indirection.

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
