# Phase 8: Operator-Invited Email Authentication via Keycloak + AWS SES

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Switch Keycloak from the current hardcoded-`emailVerified` state to operator-invited,
> email-verified authentication. Use AWS SES as the email transport, with SES receive rules + S3
> capture as the canonical-suite testing mechanism. Add `prodbox users invite|list|revoke` as the
> operator-facing command surface and `ValidationKeycloakInvite` as a canonical-suite member that
> proves the flow end-to-end on every substrate.

## Phase Status

🔄 **Reopened 2026-06-11, finalized 2026-06-14** (Vault-root + cluster federation) — the
Vault-root finalization (narrated in [README.md → Closure Status](README.md) per rule A) makes
Vault the sole, finalized secrets / KMS / PKI root for the whole stack. Sprint `8.9` (📋 Planned)
is **reframed** to own that finalized end state for the invite-auth surface: the `keycloak-smtp`
SMTP credential and the invite-flow OIDC client secrets are Vault KV objects referenced by
`SecretRef.Vault` and consumed by Keycloak via Vault Kubernetes auth. The master-seed HMAC-derivation
model is **retired** (not extended), the chart-generated `lookup`+`randAlphaNum` Secrets behind the
OIDC client secrets are **removed** (not bridged), and a sealed Vault **bricks** Keycloak bootstrap
and the invite-send / secret-dependent startup paths — no SMTP or OIDC material is reconstructed
from any non-Vault source. The invite-auth flow itself is unchanged; only its secret delivery moves
under Vault. Sprint `8.9` is blocked on the cross-phase Vault platform and derivation-retirement
sprints (`3.18`, `3.19`, `7.14`). Honest status: 📋 Planned — the Vault-root invite-secret
implementation is not yet validated. Sprints `8.1`–`8.8` stay ✅ Done on their owned surfaces. See
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md), and the
[legacy ledger](legacy-tracking-for-deletion.md).

✅ **Done** (2026-06-09) — All sprints `8.1`–`8.8` are closed on their owned surfaces.
Sprints `8.5`/`8.6` closed live (home + AWS `keycloak-invite` end-to-end with
`OIDC_CLAIMS_VERIFIED=true` on both substrates, clean teardown, no leak). Sprint `8.8` closed via
the home **and** AWS `prodbox test all` aggregates (both green: all 16 canonical validations +
cabal suites), the certificate round-trip restore-no-reorder proof (a rebuild restores the cert
from the long-lived S3 store and cert-manager adopts it with zero new ACME orders), and the
operator-invited `prodbox nuke` total-teardown proof — the last exercised end-to-end through the
interactive integration harness (the same `PRODBOX_ALLOW_NON_TTY_INTERACTIVE` + stdin seam the
other interactive surfaces use): the typed-confirmation gate is enforced, and the only path that
destroys the long-lived `pulumi_state_backend` bucket holding the retained cert is nuke's step 5.
The dated notes below record the per-sprint live closures and the defects the live runs surfaced.
The historical status detail in the rest of this section is superseded by those notes.

The shared SES infrastructure is provisioned, the Keycloak realm chart
is deployed with the operator-invited flow + SES SMTP password derivation, the
`prodbox users invite|list|revoke` CLI is live, and `ValidationKeycloakInvite` is
implemented through invite → S3 capture → credential setup → invited-user OIDC claim assertion
→ cleanup, with the June 6 local unit proof green after the SMTP-reconcile, SMTP
NetworkPolicy, verify-email continuation, public-edge certificate status-patch renderer, and
public-edge TLS Secret retention fixes (674/674).
Remaining work on the owned surface: live home and AWS substrate validation of the Sprint `8.5`
POST/OIDC body, plus the Sprint `8.6` AWS
aggregate rerun that exercises the now-green targeted AWS `keycloak-invite` path inside the full
suite. The Phase 7 AWS substrate
proof is now closed; the active Sprint `8.6` residual is the Keycloak invite public-edge closure
exposed by the June 5 AWS aggregate runs.
The first run scheduled `ValidationKeycloakInvite` after destructive `ValidationLifecycle`;
the follow-up run reached `ValidationKeycloakInvite` before lifecycle and exposed that the
admin client still targeted the home `domain.demo_fqdn` instead of the selected substrate public
FQDN, while `ValidationChartsStorage` also deletes the `vscode` root chart that hosts Keycloak.
The current aggregate run validated the ordering and `substratePublicFqdn` selection, then
exposed that the Keycloak chart's public auth `HTTPRoute` omitted the `/auth/admin` path used by
the operator invite admin API. The first targeted `keycloak-invite --substrate aws` rerun after
the route fix then failed in phase 1 because the standalone AWS-substrate validation still
expected pre-populated operational `aws.*`; the targeted-harness fix now wraps targeted
AWS-substrate validations in the same `aws_admin_for_test_simulation.*`-driven IAM harness as
aggregate runs. The follow-up targeted AWS run proved that credential materialization path and
reached the Keycloak admin invite flow, then failed because the per-run EKS cluster did not have
the retained SES SMTP settings synced into the Keycloak release namespace before Helm rendered the
realm import. The active fix syncs the long-lived `aws-ses` SMTP outputs into the fresh cluster's
supported Keycloak release namespaces before AWS chart deployment. The June 6 targeted AWS rerun
proved the sync hook is invoked before AWS chart deployment, then failed at `pulumi login` because
the configured long-lived Pulumi state bucket had been removed by the prior total-teardown cycle.
The active follow-up fix runs the same idempotent `ensureLongLivedPulumiStateBucket` precondition
on the SMTP sync path before reading the retained `aws-ses` stack. The live `aws-ses-resources`
repair then imported the retained capture bucket, SMTP IAM user, SES receipt rule set, and receipt
rule into the recreated long-lived stack, rotated stale SMTP access keys so Pulumi owns a
recoverable secret again, reconciled overwrite-tolerant Route 53 verification/DKIM/MX records, and
restored `keycloak-smtp` in both supported local release namespaces. The next June 6 targeted AWS
rerun failed before AWS provisioning during Phase `1.6/2` local supported-runtime restore after a
duplicate `rke2 reconcile` repeated Harbor image publication and exhausted the transient Harbor
login retry window. The active follow-up fix keeps the Phase `1.5/2` runbook reconcile as the
single local runtime reconcile for suites that already require it, then lets Phase `1.6/2` reset
and redeploy the supported chart set without rerunning the full local image-publication path. The
next targeted AWS rerun proved that guard in the live harness, reached AWS chart deployment, and
then failed at the `gateway` Helm install because the SMTP sync had pre-created the `keycloak`
namespace without the Helm ownership metadata required for the gateway chart's RBAC Namespace
resource to adopt it. The active follow-up fix stamps gateway-release Helm ownership and
`helm.sh/resource-policy: keep` on SMTP pre-created Keycloak release namespaces, and renders the
same metadata on the gateway chart's RBAC Namespace resources. The next targeted AWS rerun proved
that namespace-adoption fix live by moving past the gateway install, deploying the AWS chart set,
and entering the invite validation body. It then failed because the captured Keycloak multipart
email exposed the same action-token URL in text and HTML forms that differ only by URL-local
quoted-printable encoding. The active parser fix normalizes extracted invite URLs for
Keycloak's `=3D` query-delimiter encoding and HTML `&amp;` entity before distinct-link
detection, while still rejecting genuinely ambiguous emails with multiple distinct links. The
next targeted AWS rerun was interrupted before AWS provisioning because the home-local
public-edge certificate reissue helper deleted stale ACME child resources after a failed order
but did not mark the `Certificate` for immediate reissuance, leaving cert-manager in its failed
issuance backoff while the readiness loop waited. The active harness fix keeps the stale
resource cleanup and patches the Certificate status with an `Issuing=True` manual-trigger
condition after cleanup, and also when a prior cleanup already removed every stale child
resource, matching cert-manager's manual-renewal behavior without requiring an out-of-band
operator cleanup. The follow-up targeted AWS rerun reached the public-edge readiness loop again
with a fresh active ACME Order, then exposed a provider-side issue instead of a stale-resource
issue: the configured ZeroSSL ACME directory returned Sectigo HTML for both the documented
directory URL and the `/directory` variant. The config/doc fix repairs `prodbox-config.dhall`
and the guided setup default to use the ZeroSSL ACME endpoint (with the required EAB credentials)
for repository validation once the endpoint serves ACME JSON from the operator's environment. The first
targeted AWS rerun after that switch failed before AWS provisioning because the local host had
entered DiskPressure and MetalLB rollout timed out; cleanup stayed harness-owned, and only
generated temp image artifacts plus dangling Docker/build cache were pruned. The follow-up
targeted AWS rerun on June 6 recovered the local runtime through the harness `rke2 reconcile`,
validated MetalLB/Envoy/cert-manager/Percona readiness with the ZeroSSL ClusterIssuer,
provisioned the per-run AWS substrate, deployed the AWS chart set, reached
`ValidationKeycloakInvite`, captured the SES invite email, parsed and followed the normalized
invite link, and exited the validation body successfully. Post-run cleanup destroyed the per-run
AWS stacks with residue checks and cleared the operational IAM/config material.
The first live home-substrate Sprint `8.5` POST/OIDC rerun reached the Keycloak admin invite body
and then failed because the local supported-runtime bootstrap had not synced the retained
`keycloak-smtp` Secret into the `vscode` namespace, so the rendered realm import omitted
`smtpServer`. The active fix makes invite-aware local supported-runtime bootstrap run the same
retained `aws-ses` SMTP sync before chart deployment, and makes `prodbox users invite` reconcile
the existing Keycloak realm's `smtpServer` from the live `keycloak-smtp` Secret before creating the
invited user. That second step covers preserved Keycloak databases where `--import-realm` has
already skipped the existing realm. Local validation: `cabal build --builddir=.build exe:prodbox`,
refreshed `.build/prodbox`, `./.build/prodbox test unit` (669/669), `./.build/prodbox lint docs`,
`./.build/prodbox docs check`, `git diff --check`, and `./.build/prodbox check-code`.
The next live home-substrate rerun proved the local SMTP sync and realm patch, then failed in
Keycloak's SMTP client with a connect timeout to the SES SMTP endpoint. Root cause: the
Keycloak chart's `NetworkPolicy` allowed external TCP `443` egress but not the configured SMTP
port. The active chart fix adds egress to `.Values.smtp.port` (currently SES TCP `587`) and a
unit guard for the network-policy template. Local validation passed with
`./.build/prodbox test unit` (670/670), `./.build/prodbox lint chart`,
`./.build/prodbox lint docs`, `./.build/prodbox docs check`, `git diff --check`, and
`./.build/prodbox check-code`.
The follow-up live home-substrate rerun proved SMTP delivery by reaching SES capture and invite
link parsing with the NetworkPolicy fix applied, then failed because Keycloak `26.0.0` renders
`VERIFY_EMAIL` as an intermediate required-action page with a continuation anchor before the
`UPDATE_PASSWORD` form. The active harness fix parses that required-action continuation link,
follows it with the same cookie jar, and then parses/posts the password form. Local validation
passed with `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
`./.build/prodbox test unit` (672/672), `git diff --check`, and
`./.build/prodbox check-code`.
The next live home-substrate rerun reached the public-edge readiness repair path before the
invite body and exposed that the certificate reissue status patch renderer emitted malformed JSON
while marking a failed Certificate for immediate reissuance. The active harness fix renders that
status patch with Aeson instead of string concatenation and adds a direct unit decode guard.
Local validation passed with `cabal build --builddir=.build exe:prodbox`, refreshed
`.build/prodbox`, `./.build/prodbox test unit` (673/673), `git diff --check`, and
`./.build/prodbox check-code`.
The follow-up live home-substrate rerun proved the malformed status patch was fixed and reached
cert-manager reissue retry, then hit the ACME provider's certificate issuance rate limit for
the public-edge hostname. The active chart-platform fix preserves an issued `public-edge-tls`
Secret into a retained Kubernetes backup Secret in the `prodbox` namespace before deleting the
`vscode` chart namespace, then restores it into `vscode` before the Keycloak/Gateway chart is
re-applied. That keeps certificate material in Kubernetes while preventing routine home chart
resets from forcing fresh production ACME orders. Local validation passed with
`cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
`./.build/prodbox test unit` (674/674), `./.build/prodbox lint docs`,
`./.build/prodbox docs check`, `git diff --check`, and `./.build/prodbox check-code`. Sprints
`8.7` and `8.8` supersede this in-cluster Secret-retention approach with an S3-backed LongLived
retention store: the issued public-edge certificate is retained durably across cluster wipes and
restored before every issuance, so the high-churn rebuild loop never re-orders it against the
ZeroSSL ACME provider.

**2026-06-09 — AWS substrate parity ✅ (Sprint `8.6` closed) + certificate round-trip
restore-no-reorder ✅ proven (Sprint `8.8`).** Targeted
`prodbox test integration keycloak-invite --substrate aws` passed end-to-end
(`KCINVITE_AWS_EXIT=0`): invite → SES capture → action-token proceed page → credential set →
invited-user OIDC claims verified (`OIDC_CLAIMS_VERIFIED=true`) on `aws.test.resolvefintech.com`,
with a clean postflight teardown (`aws-eks-subzone` / `aws-eks` / `aws-test` all destroyed +
residue checks passed, operational IAM user deleted, no leak — zero EKS clusters remain). So
`keycloak-invite` is now green on **both** substrates (the live POST/OIDC substrate proof that was
Sprint `8.5`/`8.6`'s open item). Separately, the **fifth** defect — the certificate round-trip
re-ordering against ZeroSSL on every rebuild — is fixed and proven: `retainReadyPublicEdgeCertificate`
captures the issued cert to the long-lived S3 store at the readiness gate, and
`retainedPublicEdgeTlsSecretManifest` now carries the original Secret's `cert-manager.io/*`
adoption annotations (via the pure, unit-tested `certManagerAdoptionAnnotations`) onto the restored
Secret — so on rebuild cert-manager **adopts** the restored cert instead of re-issuing. Verified
live on a home run: the Phase 1.6 rebuild (which deletes the `vscode` namespace + cert Secret)
brought the `Certificate` Ready **with zero ACME orders created and zero readiness-wait cycles**
(`kubectl get order -n vscode` → none), then `keycloak-invite` passed (`KCINVITE5_EXIT=0`). Gates:
`check-code` 0, `test unit` 695/695 (the `certManagerAdoptionAnnotations` + `newUserCreationPayload`
+ credential-setup-parser regression tests). The full AWS aggregate then closed ✅ **GREEN**
(`TESTALL_AWS_EXIT=0`, 2026-06-09): all 16 canonical native validations on the EKS substrate —
including `keycloak-invite` (`OIDC_CLAIMS_VERIFIED=true`) and the destructive `lifecycle` — plus
both cabal suites (`prodbox-unit` 695/695, `prodbox-integration` 32/32); postflight destroyed
`aws-eks` / `aws-test` / `aws-eks-subzone` with residue checks passing, cleared operational creds,
and deleted the IAM user with no leak. So the **complete canonical suite is now green on both
substrates** (home `TESTALL_HOME4_EXIT=0` + AWS `TESTALL_AWS_EXIT=0`). The final Sprint `8.8` deliverable — the
`prodbox nuke` nuke-only-removes-the-retained-cert proof — then closed via the **interactive
integration harness** (2026-06-09). `prodbox nuke` is operator-only (TTY + typed confirmation),
but the integration suite drives it through the same `PRODBOX_ALLOW_NON_TTY_INTERACTIVE` + stdin
seam the other interactive surfaces (`aws setup`/`teardown`, `config setup`) use. Three new
`test/integration/CliSuite.hs` cases prove it: (1) `nuke --dry-run` plans the step-5 long-lived
`pulumi_state_backend` bucket destroy (where the retained cert lives); (2) the typed-confirmation
gate rejects a wrong literal and destroys nothing; (3) on `NUKE EVERYTHING` the full five-step
total-teardown orchestration runs end-to-end (cluster cascade → `aws-ses` destroy → operational
IAM teardown → tag sweep → long-lived state-bucket destroy) and completes, with step 5 removing
the bucket. Combined with the Sprint `4.24` `LongLived` registry classification (the cert is
carved out of `rke2 delete` / `aws teardown`, so only `nuke` / the explicit registered destroy
removes it; unit-tested), this completes the nuke-only proof. Gates: `check-code` 0,
`test unit` 695/695, `test integration cli` 35/35, `lint docs` / `docs check` 0. With this,
**Phase `8` is closed** on all owned deliverables.

**2026-06-08 — Home `keycloak-invite` live gate ✅ GREEN (Sprint `8.5` home POST/OIDC proof
closed); four real defects fixed that the live run surfaced.** The first end-to-end live
home-substrate `prodbox test integration keycloak-invite --substrate home-local` run passed:
`KEYCLOAK_INVITE_LINK_PARSED` / `VERIFY_CONTINUATION_FOLLOWED` / `CREDENTIAL_SET` /
`OIDC_CLAIMS_VERIFIED` / `CLEANUP` all `true`, exit `0`, postflight clean (operational `aws.*`
cleared, IAM user deleted, no leak). Getting there required four fixes, each verified
(`check-code` 0, `test unit` 693/693, `test integration cli` 32/32):

1. **Test-fixture regression that silently blocked `prodbox test all` entirely.** The fake
   `kubectl` in `test/integration/CliSuite.hs` did not honor `--ignore-not-found=true`, so the
   Sprint `8.7` cert preserve/restore reads (`kubectl get secret|certificate.cert-manager.io …
   --ignore-not-found=true`) made `charts deploy vscode` exit 1 → the cabal `prodbox-integration`
   suite exited 1 → `runPhaseTwo` aborted **before any native validation ever ran**. (This is the
   true cause of the two failures the plan had mislabeled "pre-existing environmental /
   behavior-preserving"; they were a Sprint `8.7` regression and they gated the whole aggregate.)
   Fixed the fake `kubectl` to honor the flag + handle `get certificate.cert-manager.io`.
2. **`keycloak-invite` credential-setup parser** (`src/Prodbox/Keycloak/CredentialSetupForm.hs`).
   Captured the live Keycloak 26 flow: the invite action-token link lands on a bundled "Perform
   the following action(s) … Click here to proceed" page whose proceed anchor is a
   `/login-actions/action-token` URL (NOT `/login-actions/required-action`). The parser only
   matched `required-action`, so it failed with "no required-action anchor". Broadened the
   continuation matcher to accept `action-token`; added 2 regression tests; refreshed the fixture
   to the live capture (both pages).
3. **Sprint `8.8` cert-retention core — retain-on-ready.** The S3 retention store
   (`s3://…/public-edge-tls/<substrate>/<fqdn>`) was never being populated: retain ran only on
   `charts delete` of an already-present cert, and the delete plan carries no public FQDN
   (`retainPublicEdgeSecretToStore` skipped with "no public FQDN resolved"), so under flaky
   issuance the cert was never captured → every rebuild re-ordered against ZeroSSL. Added
   `retainReadyPublicEdgeCertificate` (`src/Prodbox/Lib/ChartPlatform.hs`), called from the harness
   public-edge readiness gate (`TestRunner.runWaitForPublicEdgeReady`): it resolves the FQDN
   itself and captures the issued cert to S3 the moment it is confirmed ready. Confirmed live:
   "public-edge cert retain-on-ready: retained to the long-lived S3 store". Also surfaced the
   previously-discarded delete-path preserve outcome in the delete summary (the Sprint `8.7`
   "never silent" deliverable).
4. **Invited-user not "fully set up" → OIDC claim 400.** After credential setup, the invited-user
   password-grant returned `400 invalid_grant: "Account is not fully set up"`. Root cause
   (confirmed by direct admin-API testing): Keycloak 26's user-profile validation requires
   `firstName`/`lastName`, and `createUser` omitted them. `newUserCreationPayload`
   (`src/Prodbox/Keycloak/Admin.hs`) now sets `firstName` (email local part) + `lastName`; pure +
   exported + unit-tested.

The full home `prodbox test all` aggregate then closed the Sprint `8.8` home deliverable
✅ **GREEN** (`TESTALL_HOME4_EXIT=0`, 2026-06-08): all 16 canonical native validations passed
including `keycloak-invite` (`OIDC_CLAIMS_VERIFIED=true`) and the destructive `lifecycle`
(`rke2 delete --cascade` + full reconcile + re-validate = the live cluster-wipe-and-rebuild
cycle), plus both cabal suites (`prodbox-unit` 693/693, `prodbox-integration` 32/32); postflight
destroyed the per-run AWS stacks, cleared operational `aws.*`, and deleted the operational IAM
user with no leak. Remaining for Phase `8` closure: AWS substrate parity (Sprint `8.6` —
`keycloak-invite --substrate aws` and the AWS aggregate), the certificate round-trip
restore-no-reorder proof (Sprint `8.8`; retain-on-ready bootstraps S3, but cert-manager re-issues
on rebuild rather than adopting the restored Secret — root cause: `retainedPublicEdgeTlsSecretManifest`
strips the `cert-manager.io/*` adoption annotations; fix pending), and the operator-only
`prodbox nuke` retained-cert proof (Sprint `8.8`; TTY-only, cannot run non-interactively).

**2026-06-07 — ZeroSSL is the sole supported ACME provider.** The earlier model that built two
ACME `ClusterIssuer`s and selected between them was reverted to a single ZeroSSL `ClusterIssuer`
(`zerossl-dns01`): ZeroSSL has no separate test endpoint, and the S3 retain-and-restore of the
issued certificate already covers rebuild churn. The prior alternate ACME provider, its extra
config field, the second `ClusterIssuer`, and the issuer-selection machinery are removed from the
codebase and docs. The home `keycloak-invite` live gate (Sprint `8.8`) now runs against the
single ZeroSSL issuer.

Per-sprint status, deliverables, and remaining work are tracked in the sprint blocks
below. The authoritative status row is in
[`README.md`](README.md#phase-overview).

## Phase Summary

Today the Keycloak chart deploys a realm with `"emailVerified": true` hardcoded for any seeded
user, no SMTP server configured, no SES integration, and (per current `charts/keycloak/` review)
no self-registration or invite flow on the supported path. Phase `8` switches this to:

1. **Auth flow**: operator-invited only. No self-registration. Operator runs
   `prodbox users invite <email>`; Keycloak sends an invite email via SES; user follows the
   link, sets a password, and can log in. `prodbox users list` and `prodbox users revoke`
   complete the user-management surface.
2. **Email transport**: real AWS SES SMTP. Keycloak's `smtpServer` config points at
   `email-smtp.<region>.amazonaws.com:587` with SMTP credentials derived from an IAM user via
   the SES IAM-to-SMTP credentials algorithm, kept in a K8s secret.
3. **Test mechanism**: SES receive rules route incoming mail for a per-substrate receive
   subdomain (e.g. `inbox.<substrate-zone>`) into an S3 capture bucket. The
   `ValidationKeycloakInvite` validation generates a per-test recipient, invokes
   `prodbox users invite`, polls the S3 bucket for the email, extracts the invite link from
   the raw RFC-822 body, follows the link, sets a credential, and asserts subsequent OIDC
   login succeeds.
4. **Cross-substrate consistency**: the SES infrastructure (sending identity, receive
   subdomain, receive rule set, S3 capture bucket, IAM policy) is provisioned ONCE per
   AWS account and reused by every substrate. This is documented as a cross-substrate
   shared resource in [substrates.md](substrates.md), not as either substrate's
   per-stack provisioning.

The canonical-suite framing keeps `ValidationKeycloakInvite` substrate-agnostic. The home
local substrate runs it against the operator's AWS account (which it already needs for Route 53
DNS validation). The AWS substrate runs it against the same SES infrastructure when Sprint
`7.5` brings the AWS substrate to suite parity.

## Sprint 8.1: Shared AWS SES Infrastructure ✅

**Status**: Done (scaffolding + operational orchestration + live validation landed May 18, 2026)
**Blocked by**: Phase `7` (AWS substrate foundations) — needs the IAM and Route 53 foundations to
exist.
**Implementation**: `pulumi/aws-ses/` (new) or extension to existing AWS administration paths;
`src/Prodbox/Aws.hs`; `src/Prodbox/Settings.hs`; `prodbox-config-types.dhall`;
`prodbox-config.dhall`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Provision the long-lived, account-scoped SES resources both substrates depend on:

- SES sending identity (domain-level verification on the configured Route 53 zone or a
  dedicated SES subdomain).
- SES receive subdomain (e.g. `inbox.<configured_zone>`) with MX records pointing at SES,
  owned in Route 53.
- SES receive rule set + active receive rule that captures all inbound mail to the receive
  subdomain into an S3 bucket (one S3 object per email, keyed by message ID).
- IAM policy granting the `prodbox` runner SES send permission, S3 list/get on the capture
  bucket, and capture-object delete permission.
- An IAM user with SES SMTP credentials translated via the SES IAM-to-SMTP credentials
  algorithm, surfaced as a K8s secret consumed by the Keycloak chart's `smtpServer` block.

### Deliverables

- SES sending identity status is `Success` for the configured sending domain.
- The receive subdomain resolves to SES, MX records are in Route 53, the receive rule set is
  active, and mail to a test recipient at the subdomain lands as an S3 object within seconds.
- The IAM user and SES SMTP credentials are reachable from the supported chart deploy paths.
- `prodbox-config.dhall` carries the SES sender, receive subdomain, capture bucket, and the
  IAM credentials reference; the dhall schema in `prodbox-config-types.dhall` is extended
  to require these fields when phase-8 functionality is enabled.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `aws ses get-identity-verification-attributes` → `VerificationStatus: Success`
4. `dig MX inbox.<configured_zone>` → SES MX targets
5. `aws ses describe-active-receipt-rule-set` → active rule set captures the test recipient
6. Send a test message via SES to a recipient at the receive subdomain; assert the message
   lands as an S3 object in the capture bucket within 30 s.

### Current Validation State (Scaffolding Landed)

- `pulumi/aws-ses/Pulumi.yaml` and `pulumi/aws-ses/Main.yaml` exist and provision the
  Phase-8 SES inventory: SES domain identity (`senderDomain`), DKIM token resource, S3
  capture bucket with `ses.amazonaws.com` `PutObject` policy, Route 53 MX record on the
  receive subdomain pointing at `inbound-smtp.<aws:region>.amazonaws.com`, SES receive
  rule set + capture rule (S3 action with `inbound/` key prefix), active receive rule set
  resource, SMTP IAM user with `ses:SendRawEmail`/`ses:SendEmail` permissions and capture
  bucket access, IAM access key. Outputs cover the sending identity verification token,
  DKIM tokens, MX FQDN, capture bucket name/ARN, SMTP IAM access key ID/secret, and the
  regional SMTP endpoint.
- `prodbox-config-types.dhall` adds the `ses : { sender_domain : Text, receive_subdomain
  : Text, capture_bucket : Text }` block with empty defaults.
- `src/Prodbox/Settings.hs` exposes `SesSection`, the matching `ses` `ConfigFile` field,
  defaults, and surfaces the new fields in `renderConfigDhall` plus `renderSettingsDisplay`.
- `prodbox-config.dhall` is populated with `ses.sender_domain = "test.resolvefintech.com"`,
  `ses.receive_subdomain = "inbox.test.resolvefintech.com"`,
  `ses.capture_bucket = "prodbox-ses-capture"`.
- Test fixtures (`test/unit/Main.hs::validConfig` and `invalidZeroSslConfig`) updated for
  the new schema; `prodbox check-code` (exit 0) and `prodbox test unit` (300/300) pass.

### Current Validation State (Code + Doctrine Landed)

- `src/Prodbox/Infra/AwsSesStack.hs` exports `AwsSesStackSnapshot`,
  `awsSesStackName`, `ensureAwsSesStackResources`, `destroyAwsSesStack`,
  `parseAwsSesStackFromOutputs`, `assertNoAwsSesStackResidue`, and
  `renderAwsSesStackReport`. (The legacy `save`/`load`/`clear`
  file-cache helpers were removed by Sprint `4.18` fourth chunk; the
  snapshot is now read live from the long-lived S3 backend via
  `Prodbox.Lifecycle.LiveResidue.fetchAwsSesStackOutputs`.) The reconcile path
  brings up `pulumi/aws-ses/` against the dedicated long-lived S3 backend (per
  Sprint `4.10`), syncs `parentZoneId` / `senderDomain` / `receiveSubdomain` /
  `captureBucket` to the stack, runs `pulumi up`, and emits a `STACK=…` report.
  Output values are read on demand via `Prodbox.Infra.StackOutputs.fetch` (Sprint
  `4.16`) and `<stack>ResidueStatus` queries the long-lived S3 backend directly;
  the legacy `.prodbox-state/aws-ses/stack-snapshot.json` output cache is removed. Destroy
  mirrors `AwsEksSubzoneStack`'s idempotent destroy path with summary-mode quiet output
  and post-destroy residue scan (S3 capture bucket existence check via `aws s3api
  head-bucket`).
- `src/Prodbox/CLI/Command.hs` adds `PulumiAwsSesResources PlanOptions` and
  `PulumiAwsSesDestroy Bool PlanOptions`. `src/Prodbox/CLI/Spec.hs` registers the
  matching parser rules and `CommandSpec` leaves (`aws-ses-resources`,
  `aws-ses-destroy`). `src/Prodbox/CLI/Pulumi.hs` dispatches both through the
  `runPlanWithOptions` + `buildPulumiExecutionPlan` shape used by the existing
  pulumi commands.
- Generated CLI artifacts regenerated via `prodbox docs generate`:
  `documents/cli/commands.md`, `share/man/man1/prodbox-pulumi-aws-ses-resources.1`
  and `prodbox-pulumi-aws-ses-destroy.1`, and the bash/zsh/fish completions all
  surface the two new commands.
- [DEVELOPMENT_PLAN/substrates.md](substrates.md#cross-substrate-shared-resources)
  Cross-Substrate Shared Resources table names
  `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` as the provisioning surface
  for the SES sending identity, receive subdomain + MX, receive rule set + S3 capture
  bucket, and SMTP IAM user.
- [documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md) records the cross-substrate shared SES infrastructure doctrine and names
  `src/Prodbox/Infra/AwsSesStack.hs` as the exclusive provisioning surface.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (300/300) on May 18, 2026.

### Live Validation (Landed May 18, 2026)

`prodbox pulumi aws-ses-resources` provisioned 17 resources (13 initial + 4 follow-up
DNS records added when the Pulumi program was extended to write the `_amazonses` TXT
verification record and the three DKIM `_domainkey` CNAMEs into the parent Route 53
zone — without those Route 53 records the SES sending identity stays in `Pending`
forever). `pulumi/aws-ses/Main.yaml` and `src/Prodbox/Infra/AwsSesStack.hs` also
gained an explicit `awsRegion` stack config input (now sourced from
`aws_admin_for_test_simulation.region` in `prodbox-config.dhall`) so the SES MX target
and SMTP endpoint hostnames interpolate correctly without depending on the `aws:region`
provider config.

Validation gate against the live install:
- `aws ses get-identity-verification-attributes --identities test.resolvefintech.com`
  → `VerificationStatus: Success`.
- `dig +short MX inbox.test.resolvefintech.com` →
  `10 inbound-smtp.us-west-2.amazonaws.com.`.
- `aws ses describe-active-receipt-rule-set --query Metadata.Name --output text` →
  `prodbox-receive-rule-set`.
- `aws ses send-email` from `noreply@test.resolvefintech.com` to a unique recipient
  at the receive subdomain succeeded with `MessageId:
  0101019e3c65792f-83619cf6-…`; the captured object appeared in
  `s3://prodbox-ses-capture/inbound/…` within seconds.

### Remaining Work

None. The Phase-8 SES infrastructure is live and parity-ready as a cross-substrate
shared resource per [substrates.md](substrates.md).

## Sprint 8.2: Keycloak Realm Config — Operator-Invited, Email-Verified ✅

**Status**: Done (chart + doctrine landed May 18, 2026; live deploy proof on home substrate confirmed same day)
**Blocked by**: Sprint `8.1`
**Implementation**: `charts/keycloak/values.yaml`, `charts/keycloak/templates/configmap.yaml`,
`charts/keycloak/templates/*-secret.yaml` (new for SES SMTP creds),
`src/Prodbox/Lib/ChartPlatform.hs` (if chart-platform helpers need extension)
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`

### Objective

Update the Keycloak chart so the realm enforces operator-invited, email-verified auth and
delivers email via SES SMTP.

### Deliverables

- `charts/keycloak/templates/configmap.yaml` realm definition:
  - `registrationAllowed: false`.
  - `verifyEmail: true`.
  - Remove or scope the hardcoded `"emailVerified": true` block to fixture users only; new
    users created via the admin API start with `enabled: true`, `emailVerified: false`,
    `requiredActions: ["VERIFY_EMAIL"]`.
  - `smtpServer` block populated from substrate config: `host`, `port`, `auth: true`,
    `starttls: true`, `from`, `user`, `password` (sourced from a K8s secret rendered by the
    chart from the SES SMTP credentials in `prodbox-config.dhall`).
- A K8s secret in the chart that materializes the SES SMTP credentials at deploy time, with
  a chart-helper marker so the secret is regenerated when the underlying credential rotates.
- The chart still deploys cleanly against the existing `keycloak-postgres` dependency.

### Validation

1. `prodbox check-code`
2. `prodbox lint chart`
3. `prodbox charts deploy keycloak` against the home substrate succeeds and the realm has
   `registrationAllowed=false`, `verifyEmail=true`.
4. The SMTP secret is present in the namespace and contains the expected fields.

### Current Validation State (Chart + Doctrine Landed)

- `charts/keycloak/values.yaml` adds `keycloak.requireEmailVerification` (default `true`)
  and a `smtp` block (`enabled`, `host`, `port`, `starttls`, `auth`, `from`,
  `fromDisplayName`, `replyTo`, `user`, `password`) consumed from the operator's chart
  values. The Pulumi outputs from Sprint `8.1` (`smtp_endpoint`,
  `smtp_iam_access_key_id`, `smtp_iam_secret_access_key`, plus the SES IAM-to-SMTP
  derivation for the password) are the doctrine source for these values.
- `charts/keycloak/templates/configmap.yaml` realm.json now sets
  `"verifyEmail": true`, retains `"registrationAllowed": false`, and includes an
  `"smtpServer"` block rendered from `.Values.smtp` when `smtp.enabled` is true. The
  seeded `oidc.demoUserName` fixture user keeps `"emailVerified": true` and
  `"requiredActions": []` so the existing canonical-suite OIDC validations
  (`charts-vscode`, `charts-api`, `charts-websocket`) continue to log in without an
  invite round-trip; only non-fixture users created through `prodbox users invite`
  (Sprint `8.3`) start with `emailVerified=false` and the `VERIFY_EMAIL` required
  action.
- `charts/keycloak/templates/secret.yaml` now renders an additional `keycloak-smtp`
  `Opaque` secret with `KC_SMTP_HOST`, `KC_SMTP_PORT`, `KC_SMTP_FROM`,
  `KC_SMTP_FROM_DISPLAY_NAME`, `KC_SMTP_REPLY_TO`, `KC_SMTP_USER`, and
  `KC_SMTP_PASSWORD` stringData fields. The secret carries the
  `prodbox.io/ses-pulumi-source: pulumi/aws-ses` annotation as the chart-helper marker
  the phase doc names so the secret is regenerated when the underlying SES IAM
  access-key rotates.
- Validated with `prodbox check-code` (exit 0), `prodbox lint chart` (exit 0), and
  `prodbox test unit` (300/300) on May 18, 2026.

### Live Deploy Proof (May 18, 2026)

The home-cluster `prodbox rke2 reconcile` deploys the keycloak chart as part of the
runtime restore. Verified post-reconcile against the live home substrate:
- `kubectl get configmap keycloak-realm-import -n vscode -o jsonpath='{.data.realm\.json}'`
  contains `"registrationAllowed": false`, `"verifyEmail": true`, and an
  `"smtpServer"` block rendered from the chart values.
- `kubectl get secret keycloak-smtp -n vscode -o json` exposes the seven expected
  fields: `KC_SMTP_HOST`, `KC_SMTP_PORT`, `KC_SMTP_FROM`, `KC_SMTP_FROM_DISPLAY_NAME`,
  `KC_SMTP_REPLY_TO`, `KC_SMTP_USER`, `KC_SMTP_PASSWORD`. The placeholder values from
  `charts/keycloak/values.yaml` are present; threading the SES-derived IAM-to-SMTP
  password into the chart values (so Keycloak can authenticate to
  `email-smtp.us-west-2.amazonaws.com:587`) is a follow-up item owned by Sprint
  `8.5`'s remaining OIDC follow-up.

### Remaining Work

None at the chart-level for Sprint `8.2`. The actual end-to-end email send from
Keycloak's SMTP client through SES depends on the IAM-to-SMTP credential derivation
(HMAC-SHA256 transform of the SMTP IAM user's secret access key into the
SES-specific SMTP password format), which is scoped under Sprint `8.5`'s follow-up.

## Sprint 8.3: `prodbox users invite|list|revoke` CLI ✅

**Status**: Done (CLI surface + live Keycloak admin API HTTP integration landed May 18, 2026)
**Blocked by**: Sprint `8.2`
**Implementation**: `src/Prodbox/CLI/Users.hs` (new), `src/Prodbox/UsersAdmin.hs` (new),
`src/Prodbox/CLI/Command.hs` (add `UsersCommand` constructor),
`src/Prodbox/CLI/Spec.hs` (register the new command tree),
`src/Prodbox/CLI/Parser.hs`, `test/unit/Parser.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/cli/commands.md`, generated manpages under `share/man/man1/`,
generated shell completions under `share/completion/`

### Objective

Add an operator-facing user management surface that wraps the Keycloak admin API.

### Deliverables

- `prodbox users invite <email> [--role <role>]` creates a Keycloak user via the admin API
  with `enabled: true`, `emailVerified: false`, `requiredActions: ["VERIFY_EMAIL"]`, then
  triggers Keycloak's invite email via SES. CLI prints the user ID on success.
- `prodbox users list [--status <status>]` lists users with their email-verified status and
  last-login time.
- `prodbox users revoke <email|userId>` disables or deletes the user (decision: disable by
  default; `--delete` flag to fully delete).
- All three commands route through the `CommandSpec` registry, generate Markdown docs,
  manpages, and shell completions per the existing CLI doctrine.
- Parser tests in `test/unit/Parser.hs` cover happy and unhappy paths.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli` covers parse-time happy and unhappy paths for the new
   commands.
4. `prodbox users invite test-<nonce>@inbox.<configured_zone>` against the home substrate
   succeeds and surfaces the user ID; subsequent `prodbox users list` shows the user with
   `emailVerified=false`.

### Current Validation State (CLI + Tests Landed)

- `src/Prodbox/CLI/Command.hs` adds the `UsersCommand` ADT (`UsersInvite String (Maybe
  String) PlanOptions`, `UsersList UsersListStatus`, `UsersRevoke String Bool PlanOptions`)
  and the `NativeUsers UsersCommand` constructor on `NativeCommand`.
- `src/Prodbox/CLI/Spec.hs` adds the `usersGroup` `CommandSpec` (three leaves with
  doctrine-shaped descriptions, examples, and option lists) and the matching
  `commandRequestParser` cases (`users invite EMAIL [--role ROLE]`,
  `users list [--status | --status-unverified]`, `users revoke EMAIL_OR_USER_ID
  [--delete]`).
- `src/Prodbox/CLI/Users.hs` (new) exports `runUsersCommand` and dispatches the three
  variants through `runPlanWithOptions`, surfacing the configured user summary as
  `USER_ID=`, `EMAIL_VERIFIED=`, `REQUIRED_ACTIONS=`, `LAST_LOGIN=` key=value reports.
- `src/Prodbox/UsersAdmin.hs` (new) holds the `UserSummary` / `UserVerificationStatus`
  types and the doctrine-shaped `inviteUser` / `listUsers` / `revokeUser` API. Each
  function currently emits an actionable error pointing operators at the Sprint 8.5
  Keycloak admin API integration; the function signatures and report rendering are
  ready for that integration to land without further CLI changes.
- `src/Prodbox/Native.hs` dispatches `NativeUsers` through `runUsersCommand`.
- `prodbox.cabal` registers `Prodbox.CLI.Users` and `Prodbox.UsersAdmin`.
- `test/unit/Parser.hs` adds `UsersCommand (..)` import and the matching
  `commandPathOfRequest` arm for the three variants, so the auto-generated parser
  happy- and unhappy-path coverage exercises every registered `users` leaf example.
- Generated CLI artifacts regenerated via `prodbox docs generate`:
  `documents/cli/commands.md` (users surface listed), `share/man/man1/prodbox-users-*.1`,
  and the bash/zsh/fish completions all carry the new commands. The
  `test/golden/cli/` fixtures (command tree, commands JSON, leaf help pages) are
  refreshed to match the new registry.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (310/310, up from 300/300
  through the new auto-generated parser cases) on May 18, 2026.

### Live HTTP Integration (Landed May 18, 2026)

- New module `src/Prodbox/Keycloak/Admin.hs` owns the wire-protocol layer:
  `KeycloakClient` (TLS-managed `http-client` manager + base URL + realm + admin
  credentials), `acquireAdminToken` (password grant against `/realms/master/protocol/openid-connect/token`),
  `createUser` (`POST /admin/realms/<realm>/users`), `listUsers`
  (`GET /admin/realms/<realm>/users?max=200`), `disableUser` and `deleteUser`
  (`PUT|DELETE /admin/realms/<realm>/users/<id>`), and `executeActionsEmail`
  (`PUT /admin/realms/<realm>/users/<id>/execute-actions-email?client_id=account`).
  Failure bodies surface a 200-character excerpt to keep operator diagnostics
  actionable. Pure named handlers (`parseAccessToken`, `handleCreateUserResponse`,
  `expect204`, …) satisfy the doctrine's "Avoid case inside lambda body" guard.
- `src/Prodbox/UsersAdmin.hs` now composes the admin client: `loadKeycloakAdminPassword`
  reads the `keycloak-runtime.admin` field from the namespace-local k8s Secret
  (materialized by the gateway service per Sprint `3.13`; derived from the master
  seed at MinIO `prodbox/master-seed` per
  [secret_derivation_doctrine.md](../documents/engineering/secret_derivation_doctrine.md))
  so the admin module stays free of the chart-platform module graph. `inviteUser` creates the user, then triggers
  `["VERIFY_EMAIL", "UPDATE_PASSWORD"]` via `executeActionsEmail`. `listUsers` filters
  by `UsersListStatus`. `revokeUser` accepts either an email or a user id and
  defaults to disable; `--delete` performs a hard delete.
- `src/Prodbox/CLI/Users.hs` threads `repoRoot` through to the admin module so the
  three subcommands now return real `UserSummary` payloads instead of remedy hints.
- `prodbox.cabal` adds `http-client ^>=0.7.17`, `http-client-tls ^>=0.3.6`,
  `http-types ^>=0.12.4`, and `temporary ^>=1.3` to the library `build-depends`.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (315/315) on May 18, 2026.

### Remaining Work

None at the code level. Live behavior of the three subcommands requires Keycloak to be
deployed (Sprint `8.2` live workflow); that operator-driven run is tracked under
Bucket B in the active development plan.

## Sprint 8.4: Substrate SES Prerequisites ✅

**Status**: Done (code + tests, May 18, 2026)
**Blocked by**: Sprint `8.1`
**Implementation**: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Effect.hs`,
`src/Prodbox/EffectInterpreter.hs`
**Docs to update**: `documents/engineering/prerequisite_doctrine.md`,
`DEVELOPMENT_PLAN/substrates.md`

### Objective

Make the SES-side prerequisites first-class members of the prerequisite DAG so the canonical
suite can gate `ValidationKeycloakInvite` (Sprint `8.5`) on them.

### Deliverables

- New `EffectNode`s in `src/Prodbox/Prerequisite.hs`:
  - `ses_sending_identity_verified` — SES domain identity status = `Success` for the
    configured sending domain.
  - `ses_receive_rule_set_active` — at least one receive rule set is active and captures
    mail for the configured receive subdomain to the configured S3 bucket.
  - `ses_receive_bucket_accessible` — the runner can list and get from the capture bucket.
- Each prerequisite has a description, remedy hint (pointing operators to Sprint `8.1`
  provisioning), prerequisite dependencies (`aws_credentials_valid`, `route53_accessible`),
  and a `Validate` effect.
- The prerequisites land in the deferred-prereq list of every plan that includes
  `ValidationKeycloakInvite`, so they're checked after substrate provisioning has run.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers the new prerequisite nodes.
3. Manually breaking the SES setup (e.g. disabling the receive rule set) makes
   `prodbox test integration keycloak-invite` fail fast with the remedy hint.

### Current Validation State

- `src/Prodbox/Effect.hs` adds three `Validation` constructors:
  `RequireSesSendingIdentityVerified`, `RequireSesReceiveRuleSetActive`,
  `RequireSesReceiveBucketAccessible`.
- `src/Prodbox/Prerequisite.hs` exposes the matching `EffectNode`s
  (`ses_sending_identity_verified`, `ses_receive_rule_set_active`,
  `ses_receive_bucket_accessible`) with doctrine-shaped descriptions, Sprint-8.1-pointing
  remedy hints, prerequisite dependencies on `aws_credentials_valid` /
  `route53_accessible`, and `Validate` effects.
- `src/Prodbox/EffectInterpreter.hs` implements the three validators against the AWS CLI:
  `requireSesSendingIdentityVerified` runs
  `aws ses get-identity-verification-attributes --identities <ses.sender_domain> --query
  VerificationAttributes.<domain>.VerificationStatus --output text`;
  `requireSesReceiveRuleSetActive` runs `aws ses describe-active-receipt-rule-set --query
  Metadata.Name --output text`; `requireSesReceiveBucketAccessible` runs `aws s3api
  head-bucket --bucket <ses.capture_bucket>`. Each validator uses the same
  `awsCommandEnvironment` projection and `requireAwsValidationCommandSuccess` failure
  shaping used by the existing Route 53 validators, and fails fast on empty
  `ses.sender_domain` / `ses.capture_bucket`.
- `test/unit/Main.hs::"covers the full shared prerequisite inventory"` is extended to
  cover the three new keys; the auto-generated registry-shape, dependency-chain, and
  effect-shape tests all pass against the new nodes.
- Validated with `prodbox check-code` (exit 0) and `prodbox test unit` (310/310) on May
  18, 2026.

### Remaining Work

None at the code + test level. Sprint `8.5`'s `ValidationKeycloakInvite` deferred-prereq
list consumes these nodes; the integration with `Prodbox.TestPlan` happens there.

## Sprint 8.5: `ValidationKeycloakInvite` Canonical-Suite Content ✅

**Status**: Done — closed live on the home substrate 2026-06-08 and the AWS substrate 2026-06-09 (`OIDC_CLAIMS_VERIFIED=true` on both; `KCINVITE3_EXIT=0` / `KCINVITE_AWS_EXIT=0`), after the five live-surfaced fixes recorded in the 2026-06-08/09 Phase Status notes. Historical detail: (suite content + dispatch arm + live invite + capture + link-follow steps landed May 18, 2026; credential-setup form parser scaffold landed May 21, 2026 in `src/Prodbox/Keycloak/CredentialSetupForm.hs`; June 6, 2026 code wire-in now parses the live credential page, POSTs the generated password with a cookie jar, requests a fresh invited-user OIDC token through `prodbox-api`, and asserts issuer / `email=<recipient>` / `email_verified=true` claims. The June 6 home SMTP-reconcile fix adds invite-aware local `keycloak-smtp` sync plus realm-level SMTP patching before invite sends; the follow-up chart fix permits Keycloak NetworkPolicy egress to the configured SES SMTP port. Local validation for the new POST/OIDC body, SMTP-reconcile path, network-policy guard, Keycloak 26 verify-email continuation parser, public-edge certificate reissue status-patch renderer, and public-edge TLS Secret retention is green; live home and AWS substrate validation remain the current Sprint 8.5 gate, run against the single ZeroSSL issuer whose certificate is retained in S3 and restored before issuance.)
**Blocked by**: Sprints `8.1`, `8.2`, `8.3`, `8.4`
**Implementation**: `src/Prodbox/TestPlan.hs` (add `ValidationKeycloakInvite` variant and
`IntegrationKeycloakInvite` integration suite), `src/Prodbox/TestValidation.hs` (add the
dispatch arm in `runNativeValidation`), `src/Prodbox/CLI/Command.hs` (add
`IntegrationKeycloakInvite`), `test/unit/Main.hs`
**Docs to update**: `DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md` (add the new
validation to the inventory), `DEVELOPMENT_PLAN/system-components.md` (add to the canonical
test-suite inventory), `documents/engineering/unit_testing_policy.md`

### Objective

Add a canonical-suite validation that proves the operator-invited email-auth flow end-to-end
on whichever substrate is active.

### Deliverables

- New `NativeValidation` variant: `ValidationKeycloakInvite`.
- New `IntegrationSuite` variant: `IntegrationKeycloakInvite` mapped to a `NativeSuitePlan`
  with `[ValidationKeycloakInvite]`, the SES prerequisites from Sprint `8.4`, the runbook
  requirement, and the supported-runtime bootstrap requirement.
- The dispatch arm in `runNativeValidation`:
  1. Generates a unique per-test recipient
     (`test-<nonce>@inbox.<configured_substrate_zone>`).
  2. Invokes `prodbox users invite <email>` as a subprocess; asserts exit success and
     captures the returned user ID.
  3. Polls the configured S3 capture bucket on a bounded interval (suggested: 1 s interval,
     60 s timeout) until an object appears whose RFC-822 `To:` header matches the recipient.
  4. Parses the email body, locates the Keycloak invite link (URL containing `?key=...` or
     equivalent action-token parameter), follows it via HTTP GET, asserts Keycloak returns
     the credential-setup page.
  5. POSTs the credential-setup form with a test password; asserts the response is the
     post-activation redirect.
  6. Performs a fresh OIDC login with the new credentials against the public-edge `/auth`
     route (reusing the existing OIDC machinery from `ValidationChartsVscode`); asserts the
     login succeeds and the resulting session has the expected claims.
  7. (Optional negative path, gated by a flag) Invites a second user, runs
     `prodbox users revoke` before activation, asserts the link no longer activates.
  8. Cleanup: deletes the Keycloak user via `prodbox users revoke --delete`; deletes the
     captured email object from S3.

### Validation

1. `prodbox check-code`
2. `prodbox test unit` covers the dispatch arm's parsing logic with fixture emails.
3. `prodbox test integration keycloak-invite` against the home substrate succeeds and
   leaves no residue.
4. Aggregate `prodbox test all` includes `keycloak-invite` in its canonical-suite run and
   succeeds.

### Current Validation State (Suite Content + Dispatch Landed)

- `src/Prodbox/TestPlan.hs` adds `ValidationKeycloakInvite` to `NativeValidation`,
  `IntegrationKeycloakInvite` to `IntegrationSuite`, the matching `nativeNamedSuite`
  shape (initial prereqs reuse `chartsVscodeInitialPrerequisites` plus
  `aws_credentials_valid`, `route53_accessible`, `tool_curl`; deferred prereqs reuse
  `pulumiDeferredPrerequisites` plus the three Sprint 8.4 SES prereqs), and the
  `keycloak-invite` validation id. The validation joins
  `canonicalNativeValidations` immediately after `ValidationChartsPlatform` and before
  destructive `ValidationChartsStorage` / `ValidationLifecycle` so `prodbox test all
  --substrate aws` exercises it while the `vscode` root chart, Keycloak deployment, EKS
  substrate, and Pulumi stack snapshots still exist, and leaves the destructive lifecycle
  validation last. June 6 follow-up: targeted `IntegrationKeycloakInvite` now requests the
  suite-level managed AWS harness (`PolicyFull`) on every substrate, because the validation
  always needs SES/S3/Route 53 credentials; home-substrate targeted runs still schedule no
  AWS per-run stack destroys.
- `src/Prodbox/CLI/Command.hs` adds `IntegrationKeycloakInvite` to `IntegrationSuite`.
  `src/Prodbox/CLI/Spec.hs` registers the parser rule and the `integrationLeaf` for
  `prodbox test integration keycloak-invite`.
- `src/Prodbox/TestValidation.hs` adds the dispatch arm
  (`ValidationKeycloakInvite -> runKeycloakInviteValidation repoRoot substrate environment`)
  and the matching `runKeycloakInviteValidation` body. The body gates on the selected
  substrate's public edge, calls the Keycloak admin invite/revoke flow through the selected
  substrate public FQDN, polls the SES capture bucket, parses the invite email, follows the
  action-token link with a cookie jar, parses and POSTs the credential-setup form, requests a
  fresh invited-user OIDC token through the public realm token endpoint, asserts issuer /
  email / `email_verified=true` claims, and deletes the captured email after cleanup.
- `test/unit/Parser.hs::commandPathOfRequest` covers
  `IntegrationKeycloakInvite -> ["keycloak-invite"]`. The auto-generated parser
  happy-/unhappy-path tests exercise the new leaf.
- `test/unit/Main.hs` aggregate-suite goldens are updated:
  `nativeInitialIntegrationGatePrerequisites` ends with `route53_accessible`,
  `nativeDeferredIntegrationGatePrerequisites` adds the three SES prereqs,
  `nativeValidationId`s place `charts-platform`, `keycloak-invite`, `charts-storage`, and
  `lifecycle` in that order, and `last (nativeValidations suitePlan)` is
  `ValidationLifecycle`.
- Generated CLI artifacts regenerated via `prodbox docs generate`:
  `documents/cli/commands.md` lists `keycloak-invite`, manpages and
  bash/zsh/fish completions carry the new leaf, `test/golden/cli/*` fixtures are
  refreshed.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (312/312, up from 310 through
  the new auto-generated parser cases) on May 18, 2026.

### Live Integration (Landed May 18, 2026)

- `src/Prodbox/TestValidation.hs::runKeycloakInviteValidation` now drives the live
  flow: it projects the AWS-CLI environment via `settingsAwsEnvironment`, generates
  a unique recipient `test-<hex-nonce>@<ses.receive_subdomain>`, calls
  `Prodbox.UsersAdmin.inviteUser` (live admin-API HTTP), polls the SES capture bucket
  via `Prodbox.Ses.Capture.pollSesCapture` (1 s interval, 60 s deadline), extracts
  the action-token URL via `Prodbox.Keycloak.Email.parseKeycloakInviteLink`, follows
  the link with `curl -L` and a temporary cookie jar, follows Keycloak 26's verify-email
  continuation anchor when present, parses `kc-passwd-update-form` through
  `Prodbox.Keycloak.CredentialSetupForm`, POSTs the generated password to the form action URL,
  requests a fresh invited-user token from
  `/realms/prodbox/protocol/openid-connect/token` through `prodbox-api`, and asserts the
  selected issuer plus `email=<recipient>` and `email_verified=true` claims. Cleanup runs after
  the outcome is recorded: `Prodbox.UsersAdmin.revokeUser <id> --delete` plus
  `Prodbox.Ses.Capture.deleteCapturedEmail` when a capture object was observed.
- New helpers: `src/Prodbox/Ses/Capture.hs::pollSesCapture` /
  `deleteCapturedEmail` (built on the `aws s3api` subprocess shape already used by
  the Route 53 validators), `src/Prodbox/Keycloak/Email.hs::parseKeycloakInviteLink`
  (RFC-822 scan with quoted-printable soft-wrap handling, URL-local `=3D` /
  `&amp;` normalization for Keycloak multipart text/html duplicates, and zero /
  multiple-distinct-link rejection), `src/Prodbox/Keycloak/CredentialSetupForm.hs`
  (form parser and URL-encoded POST renderer, now decoding HTML attribute entities like a browser
  submit and extracting Keycloak 26 verify-email continuation links), and the invited-user OIDC
  claim assertion helpers in `Prodbox.TestValidation`.
- `test/unit/Main.hs` adds three new fixtures + tests for `parseKeycloakInviteLink`
  (plain-text happy path, quoted-printable soft-wrap, missing-link).
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (315/315) on May 18, 2026.
- June 6, 2026 parser hardening adds fixtures for the real Keycloak multipart shape:
  a text/html duplicate whose HTML URL encodes the query delimiter as `=3D`, and a
  separate multiple-distinct-link failure case. Local validation:
  `cabal build --builddir=.build exe:prodbox` and `./.build/prodbox test unit`
  (661/661).

### SES SMTP Password Derivation Landed (May 18, 2026)

- New module `src/Prodbox/Ses/SmtpPassword.hs` exposes
  `derivedSesSmtpPassword :: Text -> Text -> Text` implementing the AWS-published
  IAM-to-SMTP credentials algorithm (fixed date `11111111`, signed via
  HMAC-SHA256 across region/`ses`/`aws4_request`, then signs the `SendRawEmail`
  action, prepends version byte `0x04`, base64-encodes the resulting 33 bytes).
  Unit-tested in `test/unit/Main.hs` against three Python-cross-checked vectors
  (us-west-2, us-east-1, eu-west-1) plus region-sensitivity and determinism
  invariants.
- `src/Prodbox/Infra/AwsSesStack.hs::ensureAwsSesStackResources` now persists the
  derived SMTP password into Kubernetes immediately after the Pulumi `up` succeeds:
  `pulumiStackOutputSecret` fetches `smtp_iam_secret_access_key` via
  `pulumi stack output --show-secrets`, `derivedSesSmtpPassword` derives the password
  using `aws_admin_for_test_simulation.region`, and
  `persistKeycloakSmtpChartSecrets` applies the seven `KC_SMTP_*` fields directly into
  the `keycloak-smtp` k8s Secret in every supported Keycloak release namespace
  (`vscode` for the canonical shared-edge chart stack, `keycloak` for standalone
  `charts deploy keycloak`). The Secret is k8s-source-of-truth per Sprint `3.13`, is
  not data-bound, and is recomputed from the Pulumi-managed IAM secret access key on
  each sync. The IAM secret access key never lands on disk.
- `src/Prodbox/Infra/AwsSesStack.hs::syncKeycloakSmtpChartSecrets` re-applies the
  retained long-lived `aws-ses` outputs into the current Kubernetes context without
  mutating the long-lived SES stack. AWS-substrate validation bootstrap calls this after
  per-run EKS provisioning and before `charts deploy ... --substrate aws`, so a fresh
  EKS cluster has `keycloak-smtp` in the Keycloak release namespace before Helm
  evaluates `charts/keycloak/templates/configmap.yaml`'s `lookup`. Invite-aware home-local
  supported-runtime bootstrap now calls the same sync before local chart deployment. Because
  this sync may create `keycloak` / `vscode` before the gateway chart renders its RBAC Namespace
  resources, it stamps the namespaces with gateway-release Helm ownership metadata and
  `helm.sh/resource-policy: keep`; the gateway chart renders matching metadata so Helm can
  adopt those pre-created namespaces without owning their eventual deletion.
- `src/Prodbox/UsersAdmin.hs::inviteUser` now decodes `keycloak-smtp` from the live
  `vscode` namespace and calls `src/Prodbox/Keycloak/Admin.hs::ensureRealmSmtpSettings`
  before user creation. The admin call patches the existing realm representation with the
  Secret-derived `smtpServer`, covering preserved Keycloak databases where the realm import
  already skipped the existing realm before SMTP was present.
- `charts/keycloak/templates/networkpolicy.yaml` permits Keycloak egress to
  `.Values.smtp.port` in addition to HTTPS, DNS, PostgreSQL, and internal Keycloak traffic, so
  the SES SMTP client can connect on TCP `587` while the chart retains explicit egress policy.
- `charts/keycloak/templates/configmap.yaml` reads `keycloak-smtp` from
  `.Release.Namespace` and renders the realm-import `smtpServer` block only when that
  Secret exists; missing SMTP remains an explicit deferred-invite state for chart deploys
  that are not running the invite-auth validation.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (320/320, up from 315
  through the five new SES SMTP password derivation cases) on May 18, 2026.

### Remaining Work

- Local validation for the June 6 credential-setup POST / invited-user OIDC claim code path
  and the home SMTP-reconcile fix passed with `cabal build --builddir=.build exe:prodbox`,
  refreshed `.build/prodbox`, `./.build/prodbox test unit` (669/669), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, and `./.build/prodbox check-code`.
- Local validation for the SMTP NetworkPolicy fix passed with `./.build/prodbox test unit`
  (670/670), `./.build/prodbox lint chart`, `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, and `./.build/prodbox check-code`.
  The live home rerun then proved SMTP delivery and failed at Keycloak 26's verify-email
  continuation page before the password form.
- Local validation for the verify-email continuation fix passed with
  `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
  `./.build/prodbox test unit` (672/672), `git diff --check`, and
  `./.build/prodbox check-code`. The live home rerun then reached public-edge certificate
  repair before the invite body and failed because the status patch used to trigger immediate
  cert-manager reissuance was malformed JSON.
- Local validation for the public-edge certificate reissue status-patch renderer passed with
  `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
  `./.build/prodbox test unit` (673/673), `git diff --check`, and
  `./.build/prodbox check-code`. The live home rerun proved the status patch no longer emits
  malformed JSON, then hit the ACME provider's certificate issuance rate limit because the
  already-issued public-edge TLS Secret had been lost during chart namespace reset.
- Local validation for the public-edge TLS Secret retention fix passed with
  `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
  `./.build/prodbox test unit` (674/674), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, and `./.build/prodbox check-code`. The live
  home `keycloak-invite` rerun remains the next gate before Sprint `8.5` moves to AWS validation;
  Sprints `8.7`/`8.8` replace the in-cluster Secret backup with the durable S3 retain-and-restore
  store so the rebuild loop restores the issued certificate rather than re-ordering it against
  ZeroSSL.
- Exercise `prodbox test integration keycloak-invite` against live home and AWS substrates so the
  new POST/OIDC body proves against Keycloak's rendered form and public token endpoint.
- The optional negative path (step 7: revoke-before-activation) remains a follow-on sub-sprint.

## Sprint 8.6: Per-Substrate Parity for `keycloak-invite` ✅

**Status**: Done — `keycloak-invite` is ✅ on both substrates (home 2026-06-08, AWS 2026-06-09, OIDC claims verified), and the AWS aggregate `prodbox test all --substrate aws` closed green (`TESTALL_AWS_EXIT=0`). Historical detail: (doc parity rows updated May 18, 2026; June 5 live AWS aggregate and targeted
runs moved the active residual to canonical validation ordering, substrate public-FQDN selection,
the Keycloak `/auth/admin` public-route match used by operator invites, and targeted
AWS-substrate validation credential materialization from `aws_admin_for_test_simulation.*`, then
to fresh-cluster `keycloak-smtp` sync before AWS Keycloak chart render, Phase `1.6/2` local
restore deduplication, gateway Namespace adoption for SMTP pre-created Keycloak release
namespaces, Keycloak multipart invite-link normalization, public-edge certificate reissue repair,
and ZeroSSL repository-validation ACME selection. The June 6 targeted AWS
`keycloak-invite` rerun now passes through invite capture/link-follow and cleanup; AWS aggregate
rerun plus live Sprint `8.5` POST/OIDC substrate validation remain open.)
**Blocked by**: Live Sprint `8.5` POST/OIDC substrate validation for full claim assertions
**Implementation**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/system-components.md`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`

### Objective

Confirm `ValidationKeycloakInvite` runs against every substrate and update the substrate
parity rows accordingly.

### Deliverables

- `prodbox test integration keycloak-invite` against the AWS substrate succeeds end-to-end
  using the same shared SES infrastructure as the home substrate.
- The substrate parity row in [substrates.md](substrates.md) reflects `keycloak-invite` as
  ✅ on both substrates.
- The aggregate `prodbox test all` flow, when run against both substrates, exercises
  `keycloak-invite` on each.

### Validation

1. `prodbox test integration keycloak-invite` against the home substrate.
2. `prodbox test integration keycloak-invite` against the AWS substrate.
3. Verification grep confirms no `keycloak-invite` reference frames it as
   substrate-specific anywhere in the plan or governed docs.

### Current Validation State (Doc Parity Landed)

- [substrates.md](substrates.md) home and AWS substrate `Required Config` rows now name
  `ses.*` (sender_domain, receive_subdomain, capture_bucket) as required for the
  `keycloak-invite` validation. The substrate-independence cross-reference (no
  fallback) continues to apply: each substrate consumes its own `ses.*` block (the
  cross-substrate shared SES infrastructure is the same AWS account, but no doctrine
  bypass).
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) canonical-suite
  inventory adds the `keycloak-invite` row naming the AWS-credential, Route 53,
  Sprint 8.4 SES, and pulumi-login prerequisites and the operator-invited
  end-to-end flow.
- The June 5, 2026 live AWS aggregate run proved the Phase 7 AWS substrate path through
  `admin-routes`, `public-dns`, and destructive `lifecycle`, then failed when
  `ValidationKeycloakInvite` tried to materialize the AWS EKS kubeconfig after
  `ValidationLifecycle` had already destroyed the `aws-eks-test` stack snapshot. The
  first code fix moved `ValidationKeycloakInvite` before `ValidationLifecycle`.
- The follow-up June 5 AWS aggregate run reached `ValidationKeycloakInvite` before
  `ValidationLifecycle`, then failed while acquiring the Keycloak admin token from the home
  FQDN (`test.resolvefintech.com`) during an AWS-substrate run. The active code fix gives the
  Keycloak admin client an explicit public-host entrypoint, calls invite/revoke with
  `substratePublicFqdn settings substrate`, waits for the substrate-specific public-edge gate,
  and moves `ValidationKeycloakInvite` before `ValidationChartsStorage` so the validation runs
  while the `vscode` root chart and Keycloak are still deployed.
- The next June 5 AWS aggregate run validated that ordering/host fix through
  `KEYCLOAK_INVITE_PUBLIC_FQDN=aws.test.resolvefintech.com` and then failed at Keycloak user
  creation with HTTP 404. Root cause: `charts/keycloak/templates/gateway.yaml` routed
  `/auth/realms` and `/auth/resources`, so token acquisition worked while the admin API path
  `/auth/admin/realms/<realm>/users` had no matching public-edge route. The active code fix adds
  the `/auth/admin` match to the Keycloak `HTTPRoute` and a unit guard for the template.
- The first targeted rerun,
  `./.build/prodbox test integration keycloak-invite --substrate aws`, failed before provisioning
  with `settings_loaded ... aws.access_key_id must not be empty`. Root cause: standalone
  AWS-substrate native validation plans still ran their initial `aws_credentials_valid` prerequisite
  before the suite-level IAM harness could materialize operational `aws.*` from
  `aws_admin_for_test_simulation.*`. The active code fix normalizes non-empty native validation
  suites on `SubstrateAws` into the managed IAM harness and gives the runner a per-run-stack
  cleanup classifier so targeted AWS-substrate suites that bootstrap or directly provision per-run
  stacks destroy them before clearing operational credentials.
- The follow-up targeted AWS rerun proved that mismatch fixed: the run materialized operational
  `aws.*` from `aws_admin_for_test_simulation.*`, provisioned the per-run AWS substrate, deployed
  the chart set, selected `KEYCLOAK_INVITE_PUBLIC_FQDN=aws.test.resolvefintech.com`, and reached
  Keycloak's admin invite-email call. It then failed with Keycloak HTTP 500 because the realm had
  no configured email sender. Root cause: the retained `aws-ses` stack is account-scoped while the
  `keycloak-smtp` Kubernetes Secret is per-cluster/per-release-namespace; a fresh EKS cluster did
  not receive the `KC_SMTP_*` fields in the `vscode` Keycloak release namespace before Helm
  rendered the realm import. The active code fix syncs the long-lived `aws-ses` SMTP outputs into
  `vscode` and `keycloak` before AWS chart deployment.
- The June 6 targeted AWS rerun proved that the SMTP sync hook runs after per-run EKS provisioning
  and before AWS chart deployment, then failed at `pulumi login` with the configured long-lived
  Pulumi state bucket absent. Root cause: `syncKeycloakSmtpChartSecrets` read the retained
  `aws-ses` stack through the long-lived backend but did not run the bucket-ensure precondition
  that `aws-ses-resources` already uses. The active code fix shares that idempotent
  `ensureLongLivedPulumiStateBucket` step before login; if the bucket is repaired but the
  `aws-ses` stack itself is absent, the supported recovery is `prodbox pulumi aws-ses-resources`
  before re-running `keycloak-invite`.
- The follow-up live `./.build/prodbox pulumi aws-ses-resources` run repaired the missing-state /
  retained-resource condition without ad-hoc AWS mutation: it recreated the long-lived state stack,
  imported the retained capture bucket, SMTP IAM user, SES receipt rule set, and receipt rule,
  rotated stale SMTP access keys so the stack owns a fresh retrievable secret, reconciled
  overwrite-tolerant Route 53 records, and restored `keycloak-smtp` in both local supported
  Keycloak release namespaces.
- The next June 6 targeted `./.build/prodbox test integration keycloak-invite --substrate aws`
  rerun failed before AWS provisioning during Phase `1.6/2` local supported-runtime restore. The
  run completed Phase `1.5/2` runbook reconcile, then repeated the full `rke2 reconcile` in Phase
  `1.6/2`; that second reconcile repeated local Harbor image publication, exhausted the transient
  Harbor docker-login retry window, and unwound through the harness cleanup path. Per-run stack
  destroys reported no live residue and the operational IAM/config teardown completed. The active
  code fix removes that duplicate Phase `1.6/2` reconcile when Phase `1.5/2` already ran it.
- Local validation for the Phase `1.6/2` duplicate-reconcile guard passed on June 6, 2026:
  `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit` (658/658),
  `./.build/prodbox check-code`, `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, and
  `./.build/prodbox test integration cli` (30/30).
- The follow-up targeted AWS rerun proved the Phase `1.6/2` guard live: after Phase `1.5/2`
  completed the local runbook reconcile, Phase `1.6/2` reset/deployed charts without rerunning
  full `rke2 reconcile`; the harness then synced `keycloak-smtp`, provisioned the per-run AWS
  substrate, and reached AWS chart deployment. It failed at the `gateway` Helm install because the
  SMTP sync had pre-created `keycloak` without the Helm ownership metadata required for the
  gateway chart's RBAC Namespace resource to adopt it. Per-run EKS/test stack cleanup and
  operational IAM/config teardown completed through the harness.
- Local validation for the namespace-adoption fix passed on June 6, 2026:
  `cabal build --builddir=.build exe:prodbox`, `helm template gateway charts/gateway --namespace
  gateway`, `./.build/prodbox test unit` (659/659), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, `./.build/prodbox check-code`, and
  `./.build/prodbox test integration cli` (30/30).
- The follow-up targeted AWS rerun proved the namespace-adoption fix live: the `gateway`
  Helm install moved past the prior ownership failure, AWS `vscode`, `api`, and `websocket`
  chart deployment completed far enough for `ValidationKeycloakInvite` to enter its body, and
  the run failed at invite-link parsing because the captured Keycloak multipart message exposed
  the same action-token URL in text and HTML copies that differed only by URL-local
  quoted-printable encoding. The harness cleanup completed through the documented path:
  per-run EKS/test stacks were destroyed with residue checks, the operational IAM user/key was
  removed, and operational `aws.*` config was cleared. The active code fix normalizes extracted
  invite URLs for Keycloak's `=3D` query-delimiter encoding and HTML `&amp;` before
  de-duplication, while preserving the multiple-distinct-link failure mode.
- Local validation for the invite-link parser normalization fix passed on June 6, 2026:
  `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`, and
  `./.build/prodbox test unit` (661/661), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, `./.build/prodbox check-code`, and
  `./.build/prodbox test integration cli` (30/30).
- The next targeted AWS rerun was interrupted before AWS provisioning because the home-local
  public-edge readiness gate stalled after an ACME order failure: the existing repair helper
  deleted stale CertificateRequest/Order/Challenge objects, but the `Certificate` still carried
  failed-issuance state and no new Order was active. The SIGINT cleanup path completed through
  the harness: per-run stacks were already absent, the operational IAM user/key was deleted, and
  operational `aws.*` config was cleared. The active code fix extends the repair helper to patch
  the `Certificate` status with an `Issuing=True` manual-trigger condition after stale resource
  deletion so cert-manager starts a fresh CertificateRequest immediately. Initial local
  validation: `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`, and
  `./.build/prodbox test unit` (661/661), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, `./.build/prodbox check-code`, and
  `./.build/prodbox test integration cli` (30/30). The follow-up targeted AWS rerun proved the
  first half of the repair but remained in the same local certificate readiness loop when the
  stale ACME children had already been removed before the helper retried. The second harness fix
  triggers the same `Issuing=True` status patch when the failed Certificate has no remaining
  stale CertificateRequest/Order/Challenge objects. The second SIGINT cleanup path completed
  through the harness: per-run stacks were already absent or destroyed, the operational IAM
  user/key was deleted, and operational `aws.*` config was cleared. Local validation for the
  no-target branch passed: `cabal build --builddir=.build exe:prodbox`, refreshed
  `.build/prodbox`, and `./.build/prodbox test unit` (661/661),
  `./.build/prodbox lint docs`, `./.build/prodbox docs check`, `git diff --check`,
  `./.build/prodbox check-code`, and `./.build/prodbox test integration cli` (30/30). The AWS
  targeted rerun reached the public-edge readiness loop again with a fresh active ACME Order,
  then stalled because the configured ZeroSSL ACME endpoint returned HTML to cert-manager's
  new-order flow instead of ACME JSON. The SIGINT cleanup path completed through the harness:
  per-run stacks were already absent or destroyed, the operational IAM user/key was deleted, and
  operational `aws.*` config was cleared. The active follow-up repairs the repo config and
  `prodbox config setup` default to use the ZeroSSL ACME endpoint for validation. Local validation passed:
  `cabal build --builddir=.build exe:prodbox`, refreshed `.build/prodbox`,
  `./.build/prodbox test unit` (661/661), `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, `./.build/prodbox check-code`, and
  `./.build/prodbox test integration cli` (30/30). The first AWS targeted rerun after this switch
  failed before AWS provisioning because local DiskPressure caused MetalLB rollout timeout. The
  harness cleanup completed, and only generated temp image artifacts plus dangling Docker/build
  cache were pruned to restore local disk headroom. The follow-up targeted AWS rerun recovered the
  local runtime through the harness `rke2 reconcile`, re-published the Harbor image inventory,
  validated MetalLB, Envoy Gateway, cert-manager, the ZeroSSL ClusterIssuer, and the Percona
  operator, then provisioned the per-run AWS substrate. The AWS chart deploy path installed the
  substrate platform, mirrored/published images into EKS-side Harbor, deployed `gateway`, `vscode`,
  `api`, and `websocket`, entered `ValidationKeycloakInvite`, found the SES capture, parsed and
  followed the normalized invite link, and exited the validation body successfully. Postflight
  cleanup destroyed the per-run AWS stacks with residue checks and cleared operational IAM/config
  material.
- Local validation for the fresh-cluster SMTP sync fix passed after the code/doc update:
  `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit` (657/657),
  `./.build/prodbox check-code`, `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`,
  live `./.build/prodbox pulumi aws-ses-resources` state repair, and
  `./.build/prodbox test integration cli` (30/30).
- Local validation for the `/auth/admin` route plus targeted AWS-substrate harness fix passed on
  June 5, 2026: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit`
  (655/655), `./.build/prodbox check-code`, `./.build/prodbox lint docs`,
  `./.build/prodbox docs check`, `git diff --check`, and
  `./.build/prodbox test integration cli` (30/30).
- The substrate parity table flip to ✅ on both substrates is still blocked on live substrate
  validation of the Sprint `8.5` credential-setup form POST / fresh OIDC claim assertions and a
  fresh AWS aggregate validation run proving the targeted-green harness credential
  materialization, ordering, host selection, admin-route match, SMTP sync, ZeroSSL ACME
  path, invite-link normalization, local preserved-realm SMTP reconciliation, and POST/OIDC body
  in the full suite. When both close, this row flips and Phase 8 closes.

### Remaining Work

- Run an AWS aggregate validation so `ValidationKeycloakInvite` exercises the now-targeted-green
  path inside the full suite: operational credentials materialize from
  `aws_admin_for_test_simulation.*`, the validation executes before destructive
  `ValidationChartsStorage` / `ValidationLifecycle`, uses the selected substrate public FQDN,
  reaches the Keycloak admin invite-email endpoint, adopts SMTP pre-created Keycloak release
  namespaces during gateway deployment, uses the ZeroSSL ACME path, and accepts text/html
  duplicate copies of the same invite link.
- Live substrate validation of the Sprint `8.5` credential-setup form POST and fresh OIDC token
  assertion now wired into `src/Prodbox/TestValidation.hs::runKeycloakInviteValidation`.
- Run `prodbox test integration keycloak-invite` on both substrates and flip the
  substrate-parity rows to ✅ on both substrates once the full invite-auth proof closes.

## Sprint 8.7: Chart-Platform Cert Retention Refactor — S3 Restore-Before-Issue ✅

**Status**: Done (2026-06-07 on the code-owned surface)
**Implementation**:
`src/Prodbox/Lib/ChartPlatform.hs` (`PublicEdgePreserveOutcome` ADT + pure
`classifyPublicEdgePreserve` + `renderPublicEdgePreserveOutcome`;
`preservePublicEdgeTlsSecretBeforeDelete` → S3 retain via `retainPublicEdgeSecretToStore`;
`restorePublicEdgeTlsSecretAfterNamespaceCreate` → S3 restore via
`restorePublicEdgeSecretFromStore`; `readOptionalKubernetesCertificate`; the in-cluster
`public-edge-tls-retained` constants/manifest removed; the chart `Certificate` issuer set to the
single `Prodbox.PublicEdge.publicEdgeClusterIssuerName`),
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (`resolveLongLivedAdminS3Context`),
`charts/keycloak/values.yaml` + `charts/vscode/values.yaml` (issuer → `zerossl-dns01`)
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/acme_provider_guide.md`

> **Supersession note.** This sprint originally also added an issuer-selection ADT and a matching
> environment override that chose among multiple ACME `ClusterIssuer`s. That selection machinery
> was reverted to the single ZeroSSL issuer when ZeroSSL became the sole supported ACME provider
> (2026-06-07); the surviving Sprint 8.7 scope is the S3 retain-and-restore refactor and the
> silent-success-gap closure below.

### Objective

Replace the in-cluster `prodbox/public-edge-tls-retained` Secret store with the S3-backed
LongLived retention introduced in Sprint `7.11` / registered in Sprint `4.24`; close the
silent-success gap in `preservePublicEdgeTlsSecretBeforeDelete` (which previously returned
success when the owned cert Secret was absent at preserve time, violating the
[`lifecycle_reconciliation_doctrine.md` § 3](../documents/engineering/lifecycle_reconciliation_doctrine.md)
soundness rule); and make restore-before-issue run on EVERY rebuild path (including fresh-cluster /
post-`rke2 delete`), not only the chart-delete→redeploy path.

### Deliverables

- S3 put/get retention: preserve writes the live cert Secret to the
  long-lived `pulumi_state_backend` bucket under the substrate-scoped key
  `public-edge-tls/<substrate>/<fqdn>` (Sprint 7.11's `putLongLivedObject`); restore reads it
  back (`getLongLivedObject`). Both degrade gracefully when the retention store (admin creds /
  bucket / FQDN) is unavailable, so a host without the store skips retention rather than failing
  the deploy. ✅
- A typed preserve outcome (`PublicEdgePreserveOutcome`) distinguishing (a) Secret present →
  `PreservedToRetentionStore` (or `PreserveSkippedNoRetentionStore` when the store is
  unavailable), (b) Secret absent but a `Certificate` exists → `PreserveDeferredIssuanceInFlight`,
  (c) neither → `PreserveNothingToRetain`. The prior silent `Right ()`-on-absent is gone: the
  outcome is a returned typed value (with a `renderPublicEdgePreserveOutcome` surfacing string),
  and an *unobservable* owned cert (`kubectl get` failure) still returns `Left` (refuses), per
  the §3 soundness rule. The pure `classifyPublicEdgePreserve` is unit-tested for all three. ✅
- Restore-before-issue wired into deploy independent of how the prior teardown happened: because
  the retention store is the durable S3 bucket (not an in-cluster Secret that dies with the
  namespace/cluster), the existing `deployChartPlan` restore now works on EVERY rebuild path —
  including a fresh cluster after `prodbox rke2 delete`. ✅
- The keycloak **and** vscode chart `Certificate` issuers reference the single ZeroSSL
  `ClusterIssuer` (`zerossl-dns01`) as a deploy-time value, replacing the hardcoded constant
  (the `charts/keycloak/values.yaml` + `charts/vscode/values.yaml` defaults point at it). ✅

### Validation

Closure gates (passed 2026-06-07):

1. `./.build/prodbox check-code` exit `0`.
2. `./.build/prodbox test unit` → `690/690` (the
   `public-edge typed preserve outcome` describe block covers the three-way
   `classifyPublicEdgePreserve` discrimination and `renderPublicEdgePreserveOutcome` surfacing
   the absent states; the `ZeroSSL ACME ClusterIssuer + cert retention key scheme` block covers
   the single-issuer rendering and the `zerossl-dns01` constant).
3. `./.build/prodbox test integration cli` — only the 2 pre-existing `charts deploy vscode`
   environmental failures (`CliSuite.hs:256`/`:376`) remain; they reproduce identically on the
   pre-8.7 tree (the graceful-degradation S3 retention is a no-op without admin creds, so the
   deploy path is behavior-preserving in the test environment).
4. `./.build/prodbox test integration env` — runs with `cli` above; the ZeroSSL `acme`
   fixtures decode and the masked-settings/invalid-config paths pass.
5. `./.build/prodbox docs check` / `./.build/prodbox lint docs` exit `0`.

The engineering docs (`helm_chart_platform_doctrine.md`, `envoy_gateway_edge_doctrine.md`
§ cert-manager, `acme_provider_guide.md`) match the landed behavior.

### Remaining Work

- Live closure under Sprint `8.8` (the durable S3 round-trip is exercised live there; it cannot
  be validated on the fast gates).

## Sprint 8.8: Live keycloak-invite Gate Closure + Certificate Round-Trip ✅

**Status**: Done (2026-06-09) — home `prodbox test all` green (`TESTALL_HOME4_EXIT=0`) including `keycloak-invite`; AWS aggregate `prodbox test all --substrate aws` green (`TESTALL_AWS_EXIT=0`); the certificate round-trip restore-no-reorder proven live (a rebuild restores the cert from the long-lived S3 store and cert-manager adopts it with zero new ACME orders, via `retainReadyPublicEdgeCertificate` + `certManagerAdoptionAnnotations`); and the `prodbox nuke` nuke-only-removes-the-retained-cert proof exercised through the interactive integration harness (three `CliSuite.hs` cases) plus the Sprint 4.24 `LongLived` registry classification. Gates: `check-code` 0, `test unit` 695/695, `test integration cli` 35/35.
**Blocked by**: Sprint `4.24`, Sprint `7.11`, Sprint `8.7`
**Implementation**: exercises `prodbox test all` / `prodbox test integration keycloak-invite`
(suite content; no new validation added)
**Docs to update**: `DEVELOPMENT_PLAN/README.md` (Substrate Parity + Phase Overview),
`DEVELOPMENT_PLAN/substrates.md`

### Objective

Close the ordered home `keycloak-invite` live gate by running it against the single ZeroSSL
`ClusterIssuer` — the issued certificate is retained in the long-lived S3 store and restored
before issuance, so the high-churn rebuild loop never re-orders it against ZeroSSL — then prove
AWS parity. Separately prove ONE certificate round-trip: issue the cert once → retain to the
long-lived S3 bucket → `prodbox rke2 delete --cascade` → rebuild → confirm restore-before-issue
lands the Secret and cert-manager does NOT re-order; and confirm `prodbox nuke` is the only path
that removes the retained certificate. Per
[development_plan_standards.md § M](development_plan_standards.md) this sprint does NOT own a
substrate-specific validation — `keycloak-invite` is canonical suite content; `8.8` is the
invite-auth closure gate that exercises it plus the operational certificate round-trip.

### Deliverables

- Home `prodbox test all` green including `keycloak-invite` on the ZeroSSL issuer.
- Targeted `keycloak-invite --substrate aws` then AWS aggregate green.
- Documented certificate round-trip proof.
- Nuke-only-removes-retained-cert proof.

### Validation

The live runs above; home gate first (ordering), then AWS parity.

### Remaining Work

- This is the live closure gate; Phase `8` stays Active until it lands.

## Sprint 8.9: Keycloak SMTP and Invite Secrets via Vault 📋

**Status**: Planned
**Implementation**: `src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/UsersAdmin.hs`, `charts/keycloak/`
**Blocked by**: Sprints `3.18`, `3.19`, `7.14`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Make the invite-flow secrets — the `keycloak-smtp` SMTP credential and the OIDC client secrets the
invite path uses — Vault KV objects consumed by Keycloak via Vault Kubernetes auth, with fail-closed
bootstrap (vault_doctrine §11–§12, §15). Under the finalized Vault-root model Vault is the sole
secrets store: there is no kubectl-applied plaintext `keycloak-smtp` Secret, no Secret-mounted Dhall
fragment, and no master-seed derivation behind these secrets. The SMTP password is computed once
from the retained `aws-ses` IAM secret access key and persisted as a Vault KV object — not
re-derived from any non-Vault source on each consumer.

### Deliverables

- The SMTP password (computed from the retained `aws-ses` IAM secret access key via the AWS SES
  IAM-to-SMTP algorithm) is a Vault KV object referenced by `SecretRef.Vault` and consumed by
  Keycloak via Vault Kubernetes auth — there is no kubectl-applied plaintext `keycloak-smtp` Secret.
- The invite-flow OIDC client secrets are Vault KV objects (no chart-generated `lookup`+`randAlphaNum`
  Secrets, no master-seed derivation).
- The invite-send (`prodbox users invite`) and Keycloak bootstrap paths fail closed when Vault is
  sealed: a sealed Vault blocks the invite send and Keycloak's secret-dependent startup without
  reconstructing the SMTP or OIDC material from any non-Vault source.

### Validation

- A sealed Vault fails the invite send and Keycloak bootstrap closed without leaking SMTP or OIDC
  material from any non-Vault source.
- `keycloak-invite` passes on both substrates with the SMTP and OIDC client secrets sourced from
  Vault KV.

### Remaining Work

- The both-substrate live invite exercise is operator-driven.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` — operator-invited Keycloak realm
  contract and the SES SMTP secret pattern; the S3-backed LongLived public-edge cert retention
  + restore-before-issue contract (Sprint `8.7`).
- `documents/engineering/envoy_gateway_edge_doctrine.md` — interaction between Envoy auth
  policy and the new email-verified user state; the single ZeroSSL `ClusterIssuer` on the
  public-edge path (Sprint `8.7`).
- `documents/engineering/acme_provider_guide.md` — the single ZeroSSL ACME issuer, its retained
  certificate, and the one-time certificate round-trip proof (Sprint `8.7`).
- `documents/engineering/cli_command_surface.md` — the new `prodbox users invite|list|revoke`
  command family.
- `documents/engineering/prerequisite_doctrine.md` — the new SES prerequisite nodes.
- `documents/engineering/aws_integration_environment_doctrine.md` — shared cross-substrate
  SES infrastructure ownership.
- `documents/engineering/unit_testing_policy.md` — `ValidationKeycloakInvite` as canonical
  suite content; SES receive-rules-and-S3 as the canonical email-verification test
  mechanism.
- [`documents/engineering/vault_doctrine.md`](../documents/engineering/vault_doctrine.md) — the
  `keycloak-smtp` SMTP credential and invite-flow OIDC client secrets sourced from Vault KV via
  Vault Kubernetes auth, with the invite-send and Keycloak bootstrap paths failing closed when
  Vault is sealed (scheduled under Sprint `8.9`; see
  [§11](../documents/engineering/vault_doctrine.md#11-tls-and-pki-under-vault),
  [§12](../documents/engineering/vault_doctrine.md#12-in-cluster-service-auth), and
  [§15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix)).

**Product docs to create/update:**

- None.

**Cross-references to add:**

- `substrates.md` adds the SES shared resources to its cross-substrate shared-resource table.
- `system-components.md` adds `ValidationKeycloakInvite` to the canonical test-suite
  inventory.
- `phase-5-canonical-test-suite.md` adds `keycloak-invite` to its canonical-suite inventory
  table when Sprint `8.5` closes.
- `README.md` updates the Substrate Parity and Phase Overview rows when Sprint `8.8` flips
  `keycloak-invite` to ✅ on both substrates.
- `substrates.md` flips the `keycloak-invite` substrate-parity rows to ✅ when Sprint `8.8`
  closes the live gate.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [substrates.md](substrates.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
