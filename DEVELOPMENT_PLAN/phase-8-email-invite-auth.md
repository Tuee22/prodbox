# Phase 8: Operator-Invited Email Authentication via Keycloak + AWS SES

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Switch Keycloak from the current hardcoded-`emailVerified` state to operator-invited,
> email-verified authentication. Use AWS SES as the email transport, with SES receive rules + S3
> capture as the canonical-suite testing mechanism. Add `prodbox users invite|list|revoke` as the
> operator-facing command surface and `ValidationKeycloakInvite` as a canonical-suite member that
> proves the flow end-to-end on every substrate.

## Phase Status

🔄 **Active** — Sprints `8.1`–`8.4` are ✅ Done on their owned surfaces; Sprints `8.5` and
`8.6` are 🔄 Active. The shared SES infrastructure is provisioned, the Keycloak realm chart
is deployed with the operator-invited flow + SES SMTP password derivation, the
`prodbox users invite|list|revoke` CLI is live, and the `ValidationKeycloakInvite`
canonical-suite member drives invite → S3 capture → link follow → cleanup end-to-end.
Remaining work on the owned surface: the Sprint `8.5` credential-setup form POST plus
fresh OIDC token round-trip and `email_verified=true` claim assertions, and the Sprint
`8.6` live cross-substrate `keycloak-invite` run that depends on Sprint `7.5.c`'s
substrate-platform extension landing on the AWS substrate.

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
- `prodbox-config.dhall` is re-frozen against the current `prodbox-config-types.dhall`
  hash and populated with `ses.sender_domain = "test.resolvefintech.com"`,
  `ses.receive_subdomain = "inbox.test.resolvefintech.com"`,
  `ses.capture_bucket = "prodbox-ses-capture"`.
- Test fixtures (`test/unit/Main.hs::validConfig` and `invalidZeroSslConfig`) updated for
  the new schema; `prodbox check-code` (exit 0) and `prodbox test unit` (300/300) pass.

### Current Validation State (Code + Doctrine Landed)

- `src/Prodbox/Infra/AwsSesStack.hs` exports `AwsSesStackSnapshot`,
  `awsSesStackName`, `ensureAwsSesStackResources`, `destroyAwsSesStack`,
  `loadAwsSesStackSnapshot`, `saveAwsSesStackSnapshot`, `clearAwsSesStackSnapshot`,
  `assertNoAwsSesStackResidue`, and `renderAwsSesStackReport`. The reconcile path
  brings up `pulumi/aws-ses/` against the MinIO-backed local Pulumi backend, syncs
  `parentZoneId` / `senderDomain` / `receiveSubdomain` / `captureBucket` to the stack,
  runs `pulumi up`, parses the JSON outputs into a snapshot under
  `.prodbox-state/aws-ses/stack-snapshot.json`, and emits a `STACK=…` report. Destroy
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
- [DEVELOPMENT_PLAN/substrates.md](../substrates.md#cross-substrate-shared-resources)
  Cross-Substrate Shared Resources table names
  `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` as the provisioning surface
  for the SES sending identity, receive subdomain + MX, receive rule set + S3 capture
  bucket, and SMTP IAM user.
- [documents/engineering/aws_integration_environment_doctrine.md](../../documents/engineering/aws_integration_environment_doctrine.md)
  § 6.4 records the cross-substrate shared SES infrastructure doctrine and names
  `src/Prodbox/Infra/AwsSesStack.hs` as the exclusive provisioning surface.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (300/300) on May 18, 2026.

### Live Validation (Landed May 18, 2026)

`prodbox pulumi aws-ses-resources` provisioned 17 resources (13 initial + 4 follow-up
DNS records added when the Pulumi program was extended to write the `_amazonses` TXT
verification record and the three DKIM `_domainkey` CNAMEs into the parent Route 53
zone — without those Route 53 records the SES sending identity stays in `Pending`
forever). `pulumi/aws-ses/Main.yaml` and `src/Prodbox/Infra/AwsSesStack.hs` also
gained an explicit `awsRegion` stack config input (sourced from `aws.region` in
`prodbox-config.dhall`) so the SES MX target and SMTP endpoint hostnames interpolate
correctly without depending on the `aws:region` provider config.

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
  reads `.prodbox-state/charts/keycloak/.secrets.json::keycloak_admin_password` (owned
  by `Prodbox.Lib.ChartPlatform.resolveChartSecrets`) so the admin module stays free
  of the chart-platform module graph. `inviteUser` creates the user, then triggers
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

## Sprint 8.5: `ValidationKeycloakInvite` Canonical-Suite Content 🔄

**Status**: Active (suite content + dispatch arm + live invite + capture + link-follow steps landed May 18, 2026; credential-setup form POST + fresh OIDC login + claim assertions remain as a future sub-sprint)
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
  `canonicalNativeValidations` at the end so `prodbox test all` exercises it after the
  existing canonical suite.
- `src/Prodbox/CLI/Command.hs` adds `IntegrationKeycloakInvite` to `IntegrationSuite`.
  `src/Prodbox/CLI/Spec.hs` registers the parser rule and the `integrationLeaf` for
  `prodbox test integration keycloak-invite`.
- `src/Prodbox/TestValidation.hs` adds the dispatch arm
  (`ValidationKeycloakInvite -> runKeycloakInviteValidation repoRoot environment`)
  and the matching `runKeycloakInviteValidation` body. The body currently emits the
  documented operator workflow as a fail-fast remedy hint: the full end-to-end flow
  requires the Sprint 8.5 Keycloak admin API HTTP integration in
  `src/Prodbox/UsersAdmin.hs` plus an S3-polling helper for the SES capture bucket.
- `test/unit/Parser.hs::commandPathOfRequest` covers
  `IntegrationKeycloakInvite -> ["keycloak-invite"]`. The auto-generated parser
  happy-/unhappy-path tests exercise the new leaf.
- `test/unit/Main.hs` aggregate-suite goldens are updated:
  `nativeInitialIntegrationGatePrerequisites` ends with `route53_accessible`,
  `nativeDeferredIntegrationGatePrerequisites` adds the three SES prereqs,
  `nativeValidationId`s end with `keycloak-invite`, and `last (nativeValidations
  suitePlan)` is `ValidationKeycloakInvite`.
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
  the action-token URL via `Prodbox.Keycloak.Email.parseKeycloakInviteLink`, and
  follows the link via `followInviteLink` (http-client, asserts 2xx/3xx). Cleanup
  runs unconditionally: `Prodbox.UsersAdmin.revokeUser <id> --delete` plus
  `Prodbox.Ses.Capture.deleteCapturedEmail` to remove the captured S3 object.
- New helpers: `src/Prodbox/Ses/Capture.hs::pollSesCapture` /
  `deleteCapturedEmail` (built on the `aws s3api` subprocess shape already used by
  the Route 53 validators), `src/Prodbox/Keycloak/Email.hs::parseKeycloakInviteLink`
  (RFC-822 scan with quoted-printable soft-wrap handling; rejects on zero or
  multiple distinct matches), and `generateInviteNonce` /  `followInviteLink`
  inlined in `Prodbox.TestValidation`.
- `test/unit/Main.hs` adds three new fixtures + tests for `parseKeycloakInviteLink`
  (plain-text happy path, quoted-printable soft-wrap, missing-link).
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (315/315) on May 18, 2026.

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
  derived SMTP password into the Keycloak chart-secrets file immediately after
  the Pulumi `up` succeeds: `pulumiStackOutputSecret` fetches
  `smtp_iam_secret_access_key` via `pulumi stack output --show-secrets`,
  `derivedSesSmtpPassword` derives the password using the configured
  `aws.region`, and `persistKeycloakSmtpChartSecrets` merges four keys
  (`ses_smtp_endpoint`, `ses_smtp_user`, `ses_smtp_password`, `ses_smtp_from`)
  into `.prodbox-state/charts/keycloak/.secrets.json`. The IAM secret access key
  never lands on disk.
- `src/Prodbox/Lib/ChartPlatform.hs::valuesForKeycloak` adds a new
  `keycloakSmtpValues` helper that renders the chart's `smtp` block from the
  four `ses_smtp_*` chart-secret keys when all four are present. Without them
  (home substrate before SES Pulumi reconcile), the helper falls through to a
  disabled-SMTP block carrying the chart's existing placeholder values so chart
  deploy still functions.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), and `prodbox test unit` (320/320, up from 315
  through the five new SES SMTP password derivation cases) on May 18, 2026.

### Remaining Work

- The Sprint 8.5 phase-doc deliverables describe two end-to-end steps that
  remain operator-driven (must be exercised against a live Keycloak deploy
  whose credential-setup HTML form structure differs by chart version /
  required-actions configuration): (5) POSTing the Keycloak credential-setup
  form with a generated password and asserting the post-activation redirect,
  and (6) performing a fresh OIDC token request against
  `/realms/<realm>/protocol/openid-connect/token` with the new credentials and
  asserting `email_verified=true` plus `email=<recipient>` claims. The form
  behavior is chart-template-specific and is best landed after a live deploy
  run captures the form action URL + hidden inputs so the form-parser unit
  fixtures can match Keycloak's real output. The optional negative path
  (step 7: revoke-before-activation) lands in the same future sub-sprint.

## Sprint 8.6: Per-Substrate Parity for `keycloak-invite` 🔄

**Status**: Active (doc parity rows updated May 18, 2026; live cross-substrate proof pending Sprint 7.5.c live closure + Sprint 8.5 HTTP integration)
**Blocked by**: Sprints `8.5`, `7.5` (AWS substrate parity from
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md))
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
- The substrate parity table flip to ✅ on both substrates is blocked on the Sprint
  `7.5.c` live AWS-substrate canonical-suite proof (Phase 7 operator-driven workflow)
  and the Sprint 8.5 Keycloak admin API HTTP integration. When both close, this row
  flips and Phase 8 closes.

### Remaining Work

- Sprint `7.5.c` live AWS-substrate canonical-suite operator workflow (multi-hour real
  AWS run: `prodbox aws setup` → `pulumi eks-resources` → `pulumi
  aws-subzone-resources` → copy hosted_zone_id → five `--substrate aws` validations →
  teardown).
- Sprint `8.1` live SES infrastructure operator workflow (`prodbox aws setup` →
  `prodbox pulumi aws-ses-resources` → verify SES identity, MX, receive rule set,
  S3 capture).
- Sprint `8.5` Keycloak admin API HTTP integration in `src/Prodbox/UsersAdmin.hs` and
  the live end-to-end body of `runKeycloakInviteValidation` in
  `src/Prodbox/TestValidation.hs`.
- Once all three land, run `prodbox test integration keycloak-invite` on both
  substrates and flip the substrate-parity rows to ✅ on both substrates.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` — operator-invited Keycloak realm
  contract and the SES SMTP secret pattern.
- `documents/engineering/envoy_gateway_edge_doctrine.md` — interaction between Envoy auth
  policy and the new email-verified user state.
- `documents/engineering/cli_command_surface.md` — the new `prodbox users invite|list|revoke`
  command family.
- `documents/engineering/prerequisite_doctrine.md` — the new SES prerequisite nodes.
- `documents/engineering/aws_integration_environment_doctrine.md` — shared cross-substrate
  SES infrastructure ownership.
- `documents/engineering/unit_testing_policy.md` — `ValidationKeycloakInvite` as canonical
  suite content; SES receive-rules-and-S3 as the canonical email-verification test
  mechanism.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- `substrates.md` adds the SES shared resources to its cross-substrate shared-resource table.
- `system-components.md` adds `ValidationKeycloakInvite` to the canonical test-suite
  inventory.
- `phase-5-canonical-test-suite.md` adds `keycloak-invite` to its canonical-suite inventory
  table when Sprint `8.5` closes.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [substrates.md](substrates.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
