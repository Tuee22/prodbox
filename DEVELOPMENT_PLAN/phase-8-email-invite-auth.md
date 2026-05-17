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

📋 **Planned** — No sprints have started. This phase is sequenced after the substrate doctrine
(Sprint `0.6`) lands so that its sprints can use the substrate vocabulary, the canonical-suite
framing, and the cross-substrate shared-resource pattern. The phase is blocked on:

- Phase `3` (chart platform) — closed; the Keycloak chart exists at `charts/keycloak/` with
  `"emailVerified": true` hardcoded in `charts/keycloak/templates/configmap.yaml:117` and no
  SMTP/SES wiring.
- Phase `5` (canonical test suite) — closed on the substrate-agnostic framing.
- Phase `7` (AWS substrate foundations) — Sprint `7.5` (AWS substrate parity) is not blocked
  by Phase `8`; Phase `8` adds shared cross-substrate SES infrastructure that the AWS
  substrate's chart-set deploy can rely on.

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

## Sprint 8.1: Shared AWS SES Infrastructure 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

## Sprint 8.2: Keycloak Realm Config — Operator-Invited, Email-Verified 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

## Sprint 8.3: `prodbox users invite|list|revoke` CLI 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

## Sprint 8.4: Substrate SES Prerequisites 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

## Sprint 8.5: `ValidationKeycloakInvite` Canonical-Suite Content 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

## Sprint 8.6: Per-Substrate Parity for `keycloak-invite` 📋

**Status**: Planned
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

### Remaining Work

Planned. Implementation has not started.

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
