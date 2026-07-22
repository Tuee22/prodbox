# ACME Provider Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, DEVELOPMENT_PLAN/phase-8-email-invite-auth.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/config_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/vault_doctrine.md
**Generated sections**: none

> **Purpose**: Define the supported ACME provider, Tier-0 coordinates, and retained EAB/TLS custody.

---

## 1. Supported Provider

`prodbox` uses exactly one public ACME provider: **ZeroSSL**.

ZeroSSL issues through public ACME DNS-01 over Route 53, EAB-authenticated. `prodbox config setup`
authors only the non-secret ZeroSSL/Tier-0 coordinates. EAB material enters later through its own
schema-indexed external linear ingress and `OperatorMaterialPermit`; there is no provider choice
because ZeroSSL is the only supported provider.

> **Issuer-name note**: the single `ClusterIssuer` is named `zerossl-dns01`, a DNS-01-honest
> name — the issuer solves ACME challenges through a **DNS-01 Route 53 solver**, never HTTP-01,
> and the name now says so. It is one SSoT constant in
> `Prodbox.PublicEdge.publicEdgeClusterIssuerName`, threaded through both chart `values.yaml`
> files and every doc/test site that names the issuer; no second hand-edited copy survives.
> Sprint 7.13 renamed it from the historically-inaccurate HTTP-01-claiming name (which named
> HTTP-01 but ran DNS-01). Because the issuer name is baked into retained ACME account and
> certificate state, the live rename lands on a wipe-and-rebuild boundary; the S3 cert
> retention key is keyed on substrate + the exact canonical certificate scope (not the issuer name), so the retained certificate
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

Supported cluster projection is a retained-source transaction, not a direct write into whichever
Vault happens to be the current target:

1. `acme.eab_key_id` and `acme.eab_hmac_key` are `SecretRef.Vault` coordinates for the selected
   target's `secret/acme/eab` object (fields `key_id` / `hmac_key`), not plaintext `Optional Text`.
   `prodbox config setup` authors/validates Tier-0 coordinates only; it never prompts for EAB bytes
   or writes a Vault object. Direct `vault kv put` is not a supported provisioning path.
2. EAB install/rotation is a separately schema-indexed externally supplied linear ingress under its
   own backup-receipted `OperatorMaterialPermit`. The attested one-shot material worker accepts only
   the closed `AcmeEabSource { keyId, hmacKey }` schema and exact target/custody coordinates. It is
   never fed from the AWS admin prompt. Tests may project only the `acme_eab` test fixture into this
   same ingress; the fixture is not a production config source.
3. A one-shot retained-home Agent worker seals `AcmeEabSource` through its payload-specific Transit
   custody lane and returns a typed source receipt. Lifecycle Authority/outbox records only
   ciphertext and opaque typed receipts/commitments. It receives no EAB plaintext, plaintext hash,
   or generic export capability.
4. For home or a rebuilt AWS target, attested one-shot home and selected-target Agent workers rewrap
   the retained payload over an attestation-encrypted channel. Only the selected worker performs the
   closed-schema generation-CAS write and mandatory read-back of `secret/acme/eab`. A fresh AWS Vault
   therefore restores EAB without asking the operator to re-enter it.
5. The **EAB key ID** is not secret, but that does not authorize a host-direct Vault read. After
   exact target generation read-back, the selected Agent returns a typed generation-bound key-ID
   projection to the issuer renderer, which places it at
   `spec.acme.externalAccountBinding.keyID`. The **EAB HMAC key** is materialized into the
   `cert-manager` namespace as `acme-eab-credentials` by a Vault-login materializer Job and is never
   rendered as inline plaintext `stringData`. The `ClusterIssuer` references it through
   `spec.acme.externalAccountBinding.keySecretRef`. Neither host nor Gateway Runtime reads the EAB
   Vault object.
6. The ZeroSSL ACME account registration is stored under the `zerossl-account-key`
   `privateKeySecretRef`.

EAB revocation/decommission first quiesces issuance consumers, then, while the Agent workers remain
available, physically destroys every owned target/source KV-v2 version, deletes/read-backs metadata,
and proves absence. Soft delete or writing a new logical tombstone is not revocation. Rotation keeps
the current generation and physically destroys only dependency-free superseded versions. This is a
closed revoke program, never a generic secret export.

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
resource as ciphertext in the long-lived `pulumi_state_backend` S3 bucket under the
substrate-scoped key `public-edge-tls/<substrate>/<canonical-scope-key>`. Sprint `2.35` makes the
final component a path-safe encoding of the canonical scope-set serialization, so retention is
keyed by `(substrate, exact canonical scope-set)` rather than independently supplied hostname text
(see
[lifecycle_control_plane_architecture.md §5.4](./lifecycle_control_plane_architecture.md#54-retained-tls-envelope-workflow)).
The selected Target Secret Agent encrypts
the exact cert-manager TLS Secret locally; the retained home Agent's
`transit/keys/prodbox-tls-envelope` lane wraps its DEK; and the separately credentialed TLS
Retention Adapter stores/read-backs only that envelope. Restore follows the reverse Agent-mediated
path before issuance evaluation on every rebuild, so each exact canonical SAN set is issued once
and restored thereafter rather than re-ordered each cycle. Corrupt, mismatched, rollback, or unobservable retention state
fails closed and is never treated as absence.

For the retention, restore-before-issuance, and bucket-key mechanics, see
[helm_chart_platform_doctrine.md § 10](./helm_chart_platform_doctrine.md#10-required-settings-and-auto-generated-secrets)
and [envoy_gateway_edge_doctrine.md § 5](./envoy_gateway_edge_doctrine.md#5-authentication-doctrine).
For the `LongLived` classification in the managed-resource registry and why the retained
certificate is correctly retained rather than treated as a leak, see
[lifecycle_reconciliation_doctrine.md § 2](./lifecycle_reconciliation_doctrine.md#2-state-lifetime-rule)
and
[../../DEVELOPMENT_PLAN/substrates.md § Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
Explicit TLS consumer decommission deletes/read-backs the registered TLS prefix objects/versions
and TLS identity/policy only. It never deletes the shared bucket; final bucket deletion belongs to
the Authority-backup decommission tail after every registered prefix is absent.

## 5. Configurable Certificate Scope

The public-edge certificate scope is operator-configurable: a Tier-0 `CertScopeSet` of exact and
wildcard scopes, not a hardcoded wildcard anchor. The certificate `dnsNames` and the
`public-edge-tls/<substrate>/<canonical-scope-key>` retention coordinate are total projections of
that set. Each substrate still has one explicit served hostname; Gateway listeners, HTTPRoutes,
and DNS records project that bound host rather than attempting to enumerate a wildcard's infinite
coverage. `bindListener` makes the relationship total: a served hostname with no covering scope,
or a wildcard anchored at a zone the operator has not delegated in config, is rejected by smart
constructors plus fail-fast config validation. The default configured scope set is the selected
substrate's exact served host, so there is no behavior change until an operator widens scope.

### Coverage and narrowing semantics

A wildcard scope must be anchored at a config-declared delegated zone (the home parent zone or
`aws_substrate.subzone_name`), never the Public Suffix List, and apex coverage requires an explicit
exact scope because a wildcard never matches the apex or more than one label. Coverage (`covers`)
and the narrower-or-equal partial order (`impliedBy`) are RFC-6125-correct:

| relation | result | why |
|---|---|---|
| `Wildcard z` covers `x.z` | yes | one label under the delegated zone `z` |
| `Wildcard z` covers apex `z` | no | a wildcard never matches the apex — apex needs its own exact scope |
| `Wildcard z` covers `a.b.z` | no | a wildcard matches exactly one label |
| `Exact x.z` impliedBy `Wildcard z` | yes | every host admitted by the exact scope is covered by the wildcard scope |
| `Wildcard a.z` impliedBy `Wildcard z` | no | `*.z` covers `a.z` but not `foo.a.z`; a child wildcard needs its own order |

Doctrine advises delegated-zone anchoring and discourages org-apex wildcards: an org-apex wildcard
key sitting in a home-cluster Secret can silently impersonate every org subdomain, covers
non-prodbox services, and cannot even cover the AWS substrate's `aws.test.resolvefintech.com` host
since a wildcard matches exactly one label.

### Wildcard DNS-01 issuance

Wildcard scopes need no new solver. ZeroSSL over ACME DNS-01 / Route 53 already issues wildcard
certificates, and the existing `zerossl-dns01` DNS-01 solver is unchanged (zero solver change). No
repo-documented ZeroSSL wildcard prohibition exists.

### Scope-change: exact restore vs reissue

Restore-before-issue reuses retained material only when the retained certificate has the exact
canonical scope set requested by `Certificate.spec.dnsNames`. cert-manager treats a different SAN
set as an issuance-spec mismatch; restoring a wider certificate for a narrower spec would therefore
trigger another order rather than reuse it. A new canonical scope set gets its own path-safe
retention coordinate and one quota-conscious ACME order; once retain-on-ready stores that exact set,
subsequent rebuilds reuse it. Returning later to an exact set whose still-valid retained object
already exists may reuse that object. `impliedBy` remains the narrower-or-equal coverage/admission
order used to prove that explicit served hosts are covered; it does not make distinct SAN sets
interchangeable. The canonical (deduped, ordered) serialization generalizes the `<fqdn>` key of
[§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention).

### Standing rules

- ZeroSSL is the sole ACME provider; certificates are issued only through the `zerossl-dns01`
  `ClusterIssuer` over DNS-01 / Route 53.
- Dashboard, portal, and click-to-renew certificates are **not** part of the supported model. Any
  that exist are drift and must be revoked on sight — the configured scope set removes the motive
  by covering plausible siblings on the prodbox-managed side.
- Renewal is cert-manager's alone. prodbox observes expiry fail-closed (`edge status`
  `certificate-renew-due` / `certificate-expired`, with an absent cert-manager `status.renewalTime`
  treated as `certificate-unobservable`, never as "not due") and never drives ACME renewal from the
  Gateway daemon.
- Every served public hostname is an explicit binding admitted only when the configured scope set
  covers it; a hostname with no covering scope is unrepresentable (bind-time `Left` plus config
  fail-fast). Wildcard coverage never creates listeners, routes, or DNS records by enumeration.

### CA-layer investigation note

"Unrepresentable" is scoped honestly to the prodbox-managed side. A human dashboard-issuing an
orphan certificate is a CA/human-layer event no type can prevent. Under investigation as a
detection backstop — not a shipped or guaranteed mechanism — are CAA restriction plus RFC 8657
`accounturi` binding (effective only if the CA enforces `accounturi`, which is unverified for
ZeroSSL/Sectigo; plain CAA does not block same-CA dashboard issuance) together with CT-log
observation. These are recorded as investigation, not a shipped control.

Implementation of the scope algebra and its derived edge projections is complete in Sprint
[`2.35`](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md). The unblocked serving-level validation is
Planned Sprint [`5.22`](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).

## ACME credentials and TLS key material under Vault

Vault is the TLS authority for the entire stack. Each selected target's ZeroSSL EAB Key ID and EAB
HMAC key are Vault KV fields (`secret/acme/eab`, fields `key_id` / `hmac_key`), referenced from Dhall by
`SecretRef.Vault` rather than carried as plaintext in the `acme.eab_key_id` / `acme.eab_hmac_key`
config fields. Retained-home payload-specific Transit custody is the source for every selected
target generation. **Sprint 7.15 landed the pre-cutover EAB-to-Vault move**: the fields became
`Optional SecretRef`, the HMAC key was materialized in-cluster by a Vault-login Job (see §2), and
`prodbox config validate` rejected plaintext EAB. The target removes direct/manual Vault seeding and
adds the permit-bound retained-source/attested-rewrap transaction above. The ZeroSSL public-edge
certificate follows the encrypted S3 retain-and-restore contract of
[§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention).

The authority split is closed: cert-manager/ZeroSSL remains the public-edge issuer, while native
Vault PKI is the internal-cert authority. The retained home Agent owns closed-schema EAB custody and
rewrap plus TLS DEK wrapping; selected Target Agents own exact EAB target and TLS Secret plaintext
boundaries; TLS Retention Adapter owns ciphertext-only S3 retention. See
[vault_doctrine.md §18](./vault_doctrine.md#18-vault-design-decisions). Implementation and live
issuance evidence remain solely in the Development Plan.

Certificate issuance fails closed when the selected target Vault is sealed or when retained-home
custody/Agent attestation is corrupt, mismatched, rolled back, or unobservable. The typed EAB key-ID
projection is then unavailable and the materializer Job cannot read the HMAC key, so the
`ClusterIssuer` cannot authenticate to ZeroSSL. Reconcile surfaces the exact custody/target error; it never falls back to
operator re-entry, another target, config plaintext, or generic export.

ZeroSSL remains the sole public ACME provider, and the single-issuer (`zerossl-dns01`) plus
encrypted S3 retain-restore behavior of
[§ 4](#4-single-issuer-and-rebuild-safe-certificate-retention) remains one contract: EAB is a
target-Vault reference backed by retained-home `AcmeEabSource` custody, home Transit also protects
the retention DEK, and plaintext EAB/TLS material remains confined to attested one-shot Agent
workers.

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
