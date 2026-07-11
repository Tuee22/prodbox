# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/cli_command_surface.md, [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md), [vault_doctrine.md](./vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Define the `aws_admin_for_test_simulation` test-harness fixture in
> `test-secrets.dhall` and the supported way to populate and clear it so the test harness can
> simulate the operator at the interactive temporary-admin prompt for suite-driven destructive
> validation plus operational-identity and fixed-role setup/teardown.

---

## 1. Purpose And Scope

The repository rule is: there is exactly one runtime path by which elevated/admin AWS power
enters `prodbox` — the interactive `SecretRef.Prompt` arm. No production binary reads a stored
admin credential from `prodbox.dhall`. The `aws_admin_for_test_simulation.*` block is a
**test-harness-only fixture** that lives solely in `test-secrets.dhall`; its sole purpose is to
simulate the operator at that interactive temporary-admin prompt, so the test harness can
exercise admin-credentialed flows non-interactively. It is not a section of
`prodbox.dhall` and not a credential source for real operator flows.

The `aws_admin_for_test_simulation` fixture exists for:

1. `prodbox test integration aws-iam`
2. `prodbox test integration all`
3. `prodbox test all` when the aggregate runner reaches the native IAM suite
4. repository tests that simulate the interactive temporary-admin-credential prompt
5. test-harness coverage of admin-authorized long-lived operations (`prodbox aws stack aws-ses
   destroy`, `prodbox aws stack aws-ses migrate-backend`) and `prodbox nuke`
6. setup/teardown coverage for the operational `prodbox` user, its account-qualified policy, and
   the fixed `prodbox-ses-lease-session` role

Normal runtime commands use the generated operational `aws.*` identity (a `SecretRef.Vault`
reference; see §"AWS credentials under Vault"). Canonical `aws-ses reconcile` uses that identity
only to assume the exact fixed role; it neither prompts for admin power nor passes the base
operational credential to mutation children. Every real flow that does need elevated/admin AWS
power — public setup/teardown, explicit `aws-ses` destroy/migrate-backend, retained-bucket
compatibility, the native IAM harness, and `prodbox nuke` — prompts for the ephemeral elevated
credential through the interactive `SecretRef.Prompt` arm. They must not treat
`aws_admin_for_test_simulation.*` as their credential source. In tests, the harness simulates
that prompt by feeding `aws_admin_for_test_simulation.*` from `test-secrets.dhall`. The
`SecretRef.Prompt` arm and config-split rule are owned by
[vault_doctrine.md §3](./vault_doctrine.md) and [§4](./vault_doctrine.md); this document owns
the `aws_admin_for_test_simulation` fixture specifics.

---

## 2. Dhall Shape

The `aws_admin_for_test_simulation` fixture is `TestPlaintext`-class and lives only in
`test-secrets.dhall` (never in `prodbox.dhall`, never in Vault). It carries the plaintext
admin key the harness types into the temporary-admin prompt on the operator's behalf:

```dhall
-- test-secrets.dhall (test-harness-only fixture; never imported by prodbox.dhall)
let TestSecrets = ./test-secrets-types.dhall

in  TestSecrets.default // {
      aws_admin_for_test_simulation = TestSecrets.default.aws_admin_for_test_simulation // {
        access_key_id = "AKIA..."
      , secret_access_key = "..."
      , session_token = None Text
      , region = "us-east-1"
      }
    }
```

Rules:

1. `access_key_id`, `secret_access_key`, and `region` must be set together or left empty together.
2. `session_token` is optional.
3. Empty `aws_admin_for_test_simulation.*` values are the normal steady state when you are not
   running the native IAM lifecycle test harness or another repository test that simulates the
   interactive temporary-admin-credential prompt.

---

## 3. How To Populate It

Populate `aws_admin_for_test_simulation.*` only when preparing the suite-level native IAM
lifecycle harness or another repository test that needs to simulate the interactive
temporary-admin-credential prompt. This is a test-harness-only step:

1. preferred path: AWS console -> IAM -> Users -> temporary admin user -> Security credentials ->
   Create access key
2. open `test-secrets.dhall`
3. place the temporary admin key in `aws_admin_for_test_simulation.*`
4. never copy it into `prodbox.dhall`, never import `test-secrets.dhall` from
   `prodbox.dhall`, and never write it to Vault
5. run the intended test entrypoint (`prodbox test integration aws-iam`,
   `prodbox test integration all`, `prodbox test all`, etc.)

The native IAM suite and every managed AWS-substrate run that must mint operational credentials
fail in the initial prerequisite gate when
`aws_admin_for_test_simulation.*` is missing, partial, or paired with an otherwise incomplete
harness fixture.

This split is deliberate:

1. the generated operational `aws.*` identity (a `SecretRef.Vault` reference) is used by normal
   `prodbox` runtime
2. `aws_admin_for_test_simulation.*` is the `TestPlaintext` fixture in `test-secrets.dhall` that
   simulates the operator at the temporary-admin prompt for suite-driven destructive validation
3. real elevated/admin flows (public onboarding/teardown, explicit long-lived destroy/migration,
   retained-bucket compatibility, and `prodbox nuke`) always prompt for the ephemeral elevated
   credential through the interactive `SecretRef.Prompt` arm; in tests the harness simulates that
   prompt from `test-secrets.dhall`; canonical `aws-ses reconcile` is operational-role based

---

## 4. Cleanup Rule

Do not treat `aws_admin_for_test_simulation.*` as a working credential source for any production
flow; it is a `test-secrets.dhall` fixture only. The steady state of `prodbox.dhall` has no
admin block at all.

When `prodbox test integration aws-iam`, targeted
`prodbox test integration <name> --substrate aws` validation, `prodbox test integration all`, or
`prodbox test all` runs with the native IAM harness, `prodbox` now:

1. observes and deletes any pre-existing fixed SES lease role before deleting the trusted
   `prodbox` IAM user and that user's access keys during fresh preflight reconciliation
2. uses any pre-existing operational `aws.*` only to discover and delete the IAM user associated
   with those credentials when that identity can still be resolved through STS
3. creates the dedicated `prodbox` user, installs its compact account-qualified policy, and, when
   the complete account/hosted-zone/capture-bucket scope is configured, reconciles the exact-trust
   `prodbox-ses-lease-session` role with a 3,600-second maximum session duration
4. proves STS-federated operational credentials from the temporary admin test identity with a
   compact AWS-validation session policy
5. waits for both STS and repeated Route 53 hosted-zone probes to succeed with the dedicated
   IAM-user access key before selecting it as the operational key
6. materializes fresh operational `aws.*` only for the duration of the managed suite run; the
   selected runtime key is the dedicated IAM-user key because cert-manager Route 53 DNS01
   credentials do not support an STS session-token field
7. destroys validation-owned per-run stacks when the targeted suite may provision them
8. deletes the fixed role before the operational user, clears operational `aws.*`, and re-observes
   all three registered operational resources as absent before the suite returns, including
   prerequisite failure paths

After you finish the native IAM validation task, blank the fixture in `test-secrets.dhall`:

1. remove or blank `aws_admin_for_test_simulation.access_key_id`
2. remove or blank `aws_admin_for_test_simulation.secret_access_key`
3. remove or blank `aws_admin_for_test_simulation.region`
4. clear `aws_admin_for_test_simulation.session_token` unless you intentionally keep a
   session-based destructive-validation credential

The repository accepts an empty `aws_admin_for_test_simulation` fixture specifically so temporary
admin credentials can be short-lived. `prodbox.dhall` never carries this block at all.

### 4.1 Harness Teardown Residue Policy (Sprint 7.7 → superseded for the postflight by Sprint 7.9)

**Sprint 7.7 history (correct pre-Sprint-4.10).** When Sprint 7.7 (May 19, 2026) introduced
the harness-internal `BypassPerRunResidueOnly` policy, the long-lived `aws-ses` Pulumi stack
was managed with *operational* `aws.*` credentials, so clearing operational `aws.*` at the end
of a run genuinely stranded `aws-ses` from its destroy surface. Refusing to clear `aws.*`
while `aws-ses` was live was therefore the correct behavior at that time: per-run stacks
(`aws-eks`, `aws-eks-subzone`, `aws-test`) were bypassed because `awsPostflightDestroyActions`
handles them in the same suite-exit unwind, but `aws-ses` caused an actionable refusal.

**Sprint 4.10 invalidated the premise; Sprint 4.47 later narrowed reconcile.** Sprint 4.10
(May 21, 2026) moved every `aws-ses` operation off operational `aws.*` and onto the elevated/admin
credential class. Sprint `7.14` retained that credential split while routing Pulumi checkpoint
state through the encrypted Model-B backend. Sprint `4.47` supersedes only the desired-present
side of that history: canonical `aws-ses reconcile` now resolves operational `aws.*` solely to
assume the exact fixed `prodbox-ses-lease-session` role, then uses one bounded role session per
lease stage. Explicit destroy/migrate-backend and nuke remain admin-authorized. Clearing
operational `aws.*`, deleting the operational user, and deleting the role therefore cannot strand
the retained stack's teardown; setup must simply re-establish the operational identity and role
before a later canonical reconcile (see
[lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md)).

> **Corrective (Sprint 7.16, refined by Sprint 4.47).** Admin-authorized destroy,
> migrate-backend, retained-bucket compatibility, and `prodbox nuke` prompt for the ephemeral
> elevated credential through the interactive `SecretRef.Prompt` arm; the test harness simulates
> that prompt from `aws_admin_for_test_simulation.*` in `test-secrets.dhall`. There is no stored
> admin section in `prodbox.dhall`. Canonical `aws-ses reconcile` is no longer in this prompt set:
> Sprint `4.47` binds it to operational credentials narrowed through the fixed role.

**Sprint 7.5.c.v.c fixed the preflight only.** Sprint 7.5.c.v.c (May 20, 2026) switched the
harness *preflight* (`runAwsIamHarnessSetup`) to the new `BypassAllResidueForHarnessRefresh`
policy (bypass both per-run AND long-lived residue) but deliberately left the *postflight*
(`runAwsIamHarnessTeardown`) on `BypassPerRunResidueOnly`, on the now-stale premise that the
operator might need operational `aws.*` preserved to destroy `aws-ses`.

**Sprint 7.9 corrects the postflight.** Because the Sprint 7.5.c.v.c "preserve `aws.*` to
destroy `aws-ses`" rationale was a pre-4.10 premise that is now false, the postflight stranded
a freshly-created operational `prodbox` IAM user on every run where `aws-ses` was live (its
retained-by-design steady state) — the opposite of the leak-free goal. Sprint 7.9
(2026-05-29) switches `runAwsIamHarnessTeardown` to `BypassAllResidueForHarnessRefresh`,
matching the preflight: the postflight now clears operational `aws.*` and deletes the
operational `prodbox` IAM user unconditionally with respect to Pulumi residue. Per-run stacks
are still destroyed separately by `awsPostflightDestroyActions` before the teardown runs; the
long-lived `aws-ses` stack is correctly *not* stranded because its explicit destroy is still
admin-credentialed. The
`BypassPerRunResidueOnly` constructor remains a valid ADT member (it still refuses on long-lived
residue) but no longer has a production caller. See
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.9](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md).

If a pre-Sprint-7.9 run stranded your operational creds (the May 19, 2026 reproduction
scenario was the pre-7.7 variant; the pre-7.9 variant is an `aws-ses`-live postflight
refusal), `aws-ses` resources in AWS are unaffected — only the operational `aws.*` material in
Vault was emptied. Recovery:

1. `prodbox aws setup` (interactive) — paste the temporary admin key. `prodbox` recreates
   the dedicated `prodbox` IAM user and writes operational `aws.*`. `aws-ses` continues to
   be retained as designed.
2. Optional, only if you want `aws-ses` destroyed (note the 5–30 min SES DKIM
   re-verification cost on next reprovision and the ~24-hour S3 bucket name reuse
   cooldown): either `prodbox aws stack aws-ses destroy --yes` (admin-credentialed; does not
   require operational `aws.*`) followed by `prodbox aws teardown`, or — Sprint 7.7 —
   `prodbox aws teardown --destroy-pulumi-residue` in one step (warns about the SES costs
   before dispatching).

### 4.2 Canonical Test-Harness Credential Lifecycle

This is the authoritative description of the end-to-end credential lifecycle the suite-level
IAM harness drives whenever a managed AWS-substrate run engages it (`prodbox test integration
aws-iam`, targeted `prodbox test integration <name> --substrate aws`, `prodbox test integration
all`, `prodbox test all`). Other documents reference this subsection rather than restating it.
The fixture-and-prompt simulation rules (§1–§4.1) and the Vault storage rules ("AWS credentials
under Vault" below) are unchanged; this subsection is the single place that names the full
ordered lifecycle.

1. **Init.** The harness drives `vault init` for the run using the operator password carried in
   `test-secrets.dhall`. This stands in for the operator who unseals Vault before any
   credential-supplying interaction, and it is why every step below happens against an unsealed
   Vault.
2. **Mint.** The harness simulates the interactive temporary-admin prompt by feeding the
   elevated `aws_admin_for_test_simulation.*` fixture from `test-secrets.dhall` — the
   non-interactive stand-in for the operator's ephemeral elevated CLI credential. `prodbox` uses
   that elevated identity once to mint the dedicated least-privilege operational `prodbox` IAM
   user and its access key, install the account-qualified user policy, and reconcile the fixed SES
   lease role when the complete role scope is configured.
3. **Write to Vault.** The generated operational `aws.*` access key is written **directly** to
   Vault KV at `secret/gateway/gateway/aws` and is referenced from Dhall only by a
   `SecretRef.Vault` pointer. It is **never** written to `prodbox.dhall`, which carries
   only the non-secret `SecretRef.Vault` coordinates that resolve here at use time (the Tier 2
   operational-secret rule in
   [config_doctrine.md §0](./config_doctrine.md)). The simulated elevated credential is held in
   memory for the one mint and then discarded.
4. **Validate.** The harness runs the validation body using the freshly-minted operational
   `aws.*` identity (gated on STS and Route 53 hosted-zone probes per §4 item 5). Canonical
   `aws-ses reconcile` uses that base identity only to assume the exact
   `prodbox-ses-lease-session` role; each bounded lease stage receives a new session that expires
   no later than its permit/grant and never exceeds the role's 3,600-second maximum. The base
   identity is not passed to Pulumi/AWS mutation children. Sprint `5.17` invokes this
   already-composed reconcile from invite-capable selected-suite preparation. Sprint `8.10` adds
   `Prodbox.Ses.Readiness` inside its await: a lease-scoped role session observes provider state,
   sender/DKIM, MX, and receipt rules, while the base operational credential separately proves
   list/get access to the capture-canary object used by invite polling. The selected cluster's
   separate `TargetClusterSecretSink` receives fenced derived SMTP material only after Ready.
5. **Postflight teardown.** On suite exit — success, failure, and Ctrl-C — the harness deletes the
   fixed SES lease role before the operational `prodbox` IAM user and its access keys, clears the
   operational `aws.*` credentials in Vault, and re-observes the three registered operational
   resources as absent. The same teardown is idempotent on preflight, so a re-run first removes any
   residue a prior interrupted run left behind before minting fresh.
   The retained-by-design long-lived `aws-ses` stack is intentionally **not** torn down here
   (see §4.1 and §5).

Long-lived retention in step 5 is independent of preparation in step 4. Invite-capable suites must
ensure the registered `aws-ses` desired state idempotently; they must not require an operator to
pre-provision it, and must not destroy it on success, failure, or Ctrl-C. Sprints `4.47`, `5.17`,
and `8.10` own the shared lease, capability-derived preparation action, and semantic SES readiness
respectively. The ordering is defined in
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

Sprint `4.47` has completed the typed authority/sink split, Model-B CAS, bounded lease policy and
interpreter, fixed-role session runtime, fenced checkpoint boundary, target-intent recovery,
SMTP-key repair, and their composition in the registered canonical `aws-ses` desired-present
command. Sprint `5.17` has landed selection from the validation set and exact home/EKS harness
ordering; Sprint `8.10` has landed provider-then-semantic bounded readiness.

> **Nuance (Vault clear is an empty-value write, not a hard delete).** The Vault clear in step 5
> is currently implemented by writing empty-string values to `secret/gateway/gateway/aws`
> (`clearOperationalAwsConfig` → `writeOperationalAwsVaultCredentials` with empty credentials in
> `src/Prodbox/Aws.hs`), **not** by issuing a true Vault KV delete. The operational key material
> is overwritten so it can no longer be resolved, but the KV path itself is left present with
> blank fields. Converting this to a genuine KV delete is an **optional future refinement**; do
> not describe the current behavior as a hard delete.

The operational IAM mint/write/clear lifecycle is the current credential boundary. The retained
SES preparation described in step 4 is doctrine split across Sprints `4.47`, `5.17`, and `8.10`;
the Sprint `4.47` canonical transaction, Sprint `5.17` plan placement, and Sprint `8.10` semantic
readiness stage are complete on their code-owned surfaces. Fresh-account propagation remains a
non-blocking live-proof axis. Implementation status remains in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md). The harness fixture-ownership and
explicit-cleanup obligations this lifecycle obeys are owned by
[integration_fixture_doctrine.md §2](./integration_fixture_doctrine.md); the operational-secret
classification it writes into Vault is owned by
[config_doctrine.md §0](./config_doctrine.md).

---

## 5. Standalone Substrate-Provisioning Credentials

Operational `prodbox.aws.*` is the steady-state credential surface for operator-driven
AWS-touching `prodbox` commands. It is consumed by, at minimum:

- `prodbox cluster reconcile` (cert-manager Route 53 DNS01 issuance)
- `prodbox aws stack <stack> reconcile` and `prodbox aws stack <stack> destroy` for the **per-run**
  stacks under `pulumi/`: `aws-eks`, `aws-eks-subzone`, `aws-test`
- `prodbox charts reconcile ... --substrate aws` and `prodbox charts delete ... --substrate aws`
- `prodbox edge status` when the host's substrate selection points at AWS

Outside a managed test harness, the above fail fast with `aws.access_key_id must not be empty`
when the operational section is unpopulated. There is no fallback to host AWS state, host
profiles, or instance metadata — see
[aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) for the
no-ambient-auth rule. Named validations under
`prodbox test integration <name> --substrate aws` are the automation exception: the test runner
first mints the operational `prodbox` IAM identity by simulating the temporary-admin prompt from
`aws_admin_for_test_simulation.*` in `test-secrets.dhall` (writing the generated `aws.*` into
Vault), runs the validation, destroys any per-run stacks the validation may have provisioned, and
clears the materialized operational credentials again.

The long-lived stack has an operation-specific split. Canonical
`prodbox aws stack aws-ses reconcile` requires operational `aws.*`, but uses it solely for
same-account `sts:AssumeRole` on `prodbox-ses-lease-session`; the base key is never a provider
credential for that transaction. The installed user policy names only the exact role, exact SMTP
user observations, and configured capture-bucket reads. The role has exact trust in
`arn:aws:iam::<account>:user/prodbox`, a resource-bounded inline policy, and a 3,600-second maximum
session duration. By contrast, explicit `aws-ses destroy`, `migrate-backend`, retained-bucket
compatibility, and `nuke` prompt for the ephemeral elevated credential and do not require
operational `aws.*`. This is why harness postflight can remove the operational identity and role
while retained SES is live without stranding its supported teardown. The credential-class
assignment is owned by
[lifecycle_reconciliation_doctrine.md §2](./lifecycle_reconciliation_doctrine.md).

The retained-SES preparation contract reuses the already-minted operational identity, not the admin
fixture. Under Sprint `5.17`, when `ValidationKeycloakInvite` is selected, the nested harness-plan
action invokes the canonical leased reconcile after the encrypted backend becomes ready through
`LongLivedCheckpointAuthority`. `LongLived` determines that postflight retains the result; it does
not exclude the resource from preparation. The selected substrate is represented separately by
`TargetClusterSecretSink`; it never becomes the checkpoint/lease authority. Only the registered
`aws-ses` resource may use this retained role—discovery of another pre-existing AWS resource never
authorizes mutation. Sprint `4.47` completed the transaction, and Sprint `5.17` completed its
selected-plan placement.

There is exactly one runtime way elevated/admin power enters `prodbox` — the interactive
`SecretRef.Prompt` arm. Real flows prompt; the test harness simulates that prompt. The rows below
distinguish *who answers the prompt*, not separate credential stores:

| Workflow shape | How elevated/admin power is supplied | Entrypoints |
|----------------|-----------------|-------------|
| Standalone substrate provisioning (e.g. the [Sprint 7.5.c.v operator workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)) | **Public prompt path**: `prodbox aws setup` — prompts interactively (the `SecretRef.Prompt` arm) for one ephemeral elevated credential pasted from the AWS console; mints the dedicated least-privilege `prodbox` IAM identity via STS federation; writes the generated `aws.*` into Vault KV (`SecretRef.Vault`). The prompted elevated credential is held in memory for the one command and then discarded — never written to `prodbox.dhall`, never stored in Vault. | `prodbox aws setup` at start; `prodbox aws teardown` at end |
| Suite-driven runs (the canonical test surface) | **Test-harness simulation path**: the harness simulates the setup/teardown prompt by feeding `aws_admin_for_test_simulation.*` from `test-secrets.dhall` (a `TestPlaintext` fixture); `runAwsIamHarnessSetup` performs prompt-mint-policy/role-reconcile-write-to-Vault-discard non-interactively. Canonical retained-SES reconcile then consumes operational `aws.*` only through the fixed role; it does not replay the prompt. | `prodbox test integration aws-iam`, `prodbox test integration keycloak-invite`, `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, `prodbox test all` |
| Canonical retained desired-present operation | **Operational fixed-role path**: resolve `aws.*` from Vault, assume only `prodbox-ses-lease-session`, and mint one lease-bounded session per stage. No admin prompt or simulation-fixture read occurs. | `prodbox aws stack aws-ses reconcile` |
| Long-lived destructive/compatibility operations | **Same prompt path as standalone setup**: `aws-ses destroy`, `migrate-backend`, retained-bucket compatibility, and `prodbox nuke` prompt for the ephemeral elevated credential through `SecretRef.Prompt` (the harness simulates it where a repository test owns that flow). | `prodbox aws stack aws-ses destroy --yes`, `prodbox aws stack aws-ses migrate-backend`, `prodbox nuke` |

These credential paths remain distinct even when one suite uses both. A standalone substrate run
uses `prodbox aws setup` and `prodbox aws teardown` symmetrically. A suite-driven run lets the
harness own operational setup, per-run-stack cleanup when applicable, and teardown end-to-end. The
planned invite-capable preparation reuses its operational identity through the fixed role rather
than invoking a separate harness-simulated prompt. Per Sprint
`7.3`, the standalone and suite-driven paths clear
operational
`aws.*` before they return, so a standalone workflow's intermediate steps (`cluster reconcile`,
`aws stack <stack> reconcile`, `charts reconcile --substrate aws`) must all run between the operator's
`prodbox aws setup` and the operator's `prodbox aws teardown`. A targeted AWS-substrate test is
not part of that manual window; `prodbox test integration <name> --substrate aws` owns the
temporary operational credential lifecycle itself.

The standalone substrate-provisioning step list is owned by
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.5.c Sprint Workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
this section is the credentials-side contract that workflow cites.

## AWS credentials under Vault

Vault holds production secrets only; none of our testing secrets live in Vault. The generated
operational `prodbox` IAM identity — the least-privilege `aws.*` access key `prodbox` mints — is
written straight into Vault KV (`secret/gateway/gateway/aws`) the instant it is created and is
referenced from Dhall only by `SecretRef.Vault`, never stored as plaintext in
`prodbox.dhall` and never transiting cleartext storage.

The credential-supplying interaction happens **after** Vault is set up and unsealed, because the
generated credential is minted directly into Vault. The order is:

1. bring up and unseal Vault
2. the operator at the interactive `SecretRef.Prompt` (or, in tests, the harness simulating it
   from `aws_admin_for_test_simulation.*` in `test-secrets.dhall`) supplies the ephemeral elevated
   credential
3. `prodbox` uses it once to mint the dedicated least-privilege `prodbox` IAM identity
4. `prodbox` writes the generated `aws.*` credential into Vault KV (`secret/gateway/gateway/aws`)
5. `prodbox` discards the prompted elevated credential

Prompt-use-discard is the only handling for the ephemeral elevated credential: it is never written
to `prodbox.dhall`, never stored in Vault, never persisted to disk. (AWS secrets moved into
Vault KV under Sprint 7.14. For the root AWS schema, **only** the generated operational `aws.*` is
a `SecretRef.Vault` reference; Pulumi provider resolution requires `secret/gateway/gateway/aws`
through `Prodbox.Infra.AwsProviderCredentials`, and there is no raw config fallback.)

In-cluster consumers of these AWS credentials authenticate to Vault directly via Vault Kubernetes
auth; there is no gateway-side Secret-mounted `aws.dhall` fragment in the delivery path.

The `aws_admin_for_test_simulation.*` fixture is **not** part of the Vault model. It is a
`TestPlaintext`-class fixture that lives only in `test-secrets.dhall` — never imported by
`prodbox.dhall`, never read by any production binary, never stored in Vault, never copied
into generated cluster config or MinIO. It is a retained test-harness simulation input (not
deletable residue); its meaning, population, and cleanup rules in §1–§4 are unchanged. See
[vault_doctrine.md §13](./vault_doctrine.md#13-config-and-state-classification) for the
authoritative config-and-state classification, and [vault_doctrine.md §4](./vault_doctrine.md) for
the `prodbox.dhall` / `test-secrets.dhall` split this fixture obeys.

## Related Documents

- [aws_account_setup_guide.md](./aws_account_setup_guide.md)
- [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
