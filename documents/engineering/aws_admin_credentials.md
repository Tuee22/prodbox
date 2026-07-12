# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/cli_command_surface.md, [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md), [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md), [vault_doctrine.md](./vault_doctrine.md)
**Generated sections**: none

> **Purpose**: Define the `aws_admin_for_test_simulation` test-harness fixture in
> `test-secrets.dhall` and the supported way to populate and clear it so the test harness can
> simulate the operator at the interactive temporary-admin prompt for permit-bounded credential
> provisioning, explicit admin actions, and post-export decommission validation.

Implementation and deployment-qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md); §4.1 is retained as an explicitly historical
credential-lifecycle record.

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
6. genesis/rotation/decommission coverage for LongLived Authority-backup, home Gateway-DNS/home
   DNS01, and TLS-retention identities; ordinary setup/teardown for Operational Lifecycle-provider
   and AWS DNS01; deterministic LongLived SMTP IAM identity/policy/key-family provisioning and
   repair plus retained-home SMTP source custody/rewrap; and operation-specific non-credential roles such as
   `prodbox-ses-lease-session`

Normal runtime commands resolve the distinct identity generation for their exact operation (see
§"AWS credentials under Vault"). Canonical `aws-ses reconcile` uses the Lifecycle-provider identity
only for the fixed non-credential role. It routes an admin prompt solely to Credential Provisioner
when SMTP install, rotation, or repair is required; converged reconcile and target restore from
retained-home custody do not re-prompt. No branch passes the base credential to unrelated consumers.
Every real flow that does need elevated/admin AWS power routes
the prompt to exactly one attested boundary: the mode-indexed Credential Provisioner for
genesis/backup repair/ordinary identity material, the Admin Action Runner for explicit `aws-ses`
destroy/migrate-backend, retained-store compatibility, or quota request/status read-back, and the standalone
Decommission Runner for `prodbox nuke` after export. The normal Provider Worker accepts none of
those prompts or permits. These flows must not treat
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

1. normal runtime uses separate Lifecycle-provider, LongLived Authority-backup/home Gateway-DNS/
   home-DNS01/TLS-retention/SMTP-family-and-custody, and run-scoped AWS-DNS01 generations; no shared
   `aws.*` identity exists
2. `aws_admin_for_test_simulation.*` is the `TestPlaintext` fixture in `test-secrets.dhall` that
   simulates the operator at the temporary-admin prompt for suite-driven destructive validation
3. real elevated/admin flows always source ephemeral bytes through the interactive
   `SecretRef.Prompt` arm, but route them to disjoint interpreters: Credential Provisioner for
   onboarding/Operational teardown, Admin Action Runner for explicit long-lived destroy/migration,
   retained-store compatibility, or quota request/status, and the post-export Decommission Runner
   for `prodbox nuke`; tests simulate those prompts from `test-secrets.dhall`. Canonical `aws-ses
   reconcile` is split: operational-role Provider work is non-credential only, while SMTP material
   mutation uses its own Credential Provisioner permit/prompt

---

## 4. Cleanup Rule

Do not treat `aws_admin_for_test_simulation.*` as a working credential source for any production
flow; it is a `test-secrets.dhall` fixture only. The steady state of `prodbox.dhall` has no
admin block at all.

When `prodbox test integration aws-iam`, targeted
`prodbox test integration <name> --substrate aws` validation, `prodbox test integration all`, or
`prodbox test all` runs with the native IAM harness, `prodbox` now:

1. observes the registered role-specific IAM resources and any unfinished Lifecycle Authority
   setup/revoke operation before planning mutation
2. uses the simulated prompt credential only inside the attested, mode-indexed Credential
   Provisioner, explicit Admin Action Runner, or post-export Decommission Runner selected by the
   committed permit; it is never a discovery fallback, Provider Worker input, or runtime identity
3. observes/retains LongLived backup/home identities, the SMTP IAM family, and its source custody;
   reconciles only required Operational Lifecycle-provider/AWS-DNS01 identities plus exact roles
   such as `prodbox-ses-lease-session`; and invokes SMTP material mutation only under its distinct
   `OperatorMaterialPermit`
4. commits each access-key create intent first; only Credential Provisioner may create/rotate/remint
   or repair-delete. If AWS applies create but the one-time secret response is lost, it deletes the
   observed uncommitted key and proves stable absence before remint instead of issuing a blind second
   create
5. sends each ordinary returned key only to its exact Agent/Vault consumer. For SMTP, Credential
   Provisioner derives the region-bound closed `SesSmtpSource` in bounded memory, discards the raw
   AWS secret-access-key bytes, and sends only that payload to a one-shot retained-home Agent for
   Transit sealing/read-back. Attested home/selected Agent workers later rewrap it to the selected
   target; Authority/outbox stores only ciphertext and opaque typed receipts/commitments, never
   plaintext, a credential hash, or a generic export coordinate
6. proves STS and the exact capability of each identity independently; one role's success cannot
   admit another role's operation
7. registers every validation-owned Operational destroy/revoke obligation before provisioning,
   then executes the always-run cleanup DAG
8. removes only Operational roles/keys after every dependent cleanup succeeds, then physically
   destroys their owned KV-v2 versions, deletes/read-backs metadata, and proves absence. Soft delete
   or writing a new logical tombstone is not cleanup. Rotation retains the current generation and
   physically destroys only dependency-free superseded versions. LongLived
   backup/home/TLS/SMTP-family-and-custody generations are observed and
   retained. `DestroyAwsSes` first quiesces consumers and deletes/read-backs the external SMTP
   family; only then, while Agents remain live, does it physically destroy every owned target/source
   custody KV-v2 version, delete/read back metadata, and prove absence. Total `nuke` uses the same ordering. Removing
   TLS retention deletes its registered prefix objects/versions and identity, not the shared
   bucket; the final Authority-backup decommission node deletes the bucket only after every
   registered prefix is absent.

After you finish the native IAM validation task, blank the fixture in `test-secrets.dhall`:

1. remove or blank `aws_admin_for_test_simulation.access_key_id`
2. remove or blank `aws_admin_for_test_simulation.secret_access_key`
3. remove or blank `aws_admin_for_test_simulation.region`
4. clear `aws_admin_for_test_simulation.session_token` unless you intentionally keep a
   session-based destructive-validation credential

The repository accepts an empty `aws_admin_for_test_simulation` fixture specifically so temporary
admin credentials can be short-lived. `prodbox.dhall` never carries this block at all.

### 4.1 Harness Teardown Residue Policy (Sprint 7.7 → superseded for the postflight by Sprint 7.9)

> **Historical pre-control-plane-cutover record.** Every `operational aws.*`/single-user statement
> and recovery command in this subsection describes the shared-credential implementation. It does
> not override the role-specific target lifecycle in §4.2; Sprint `4.50` removes the shared path.

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
state through the encrypted Model-B backend. The then-current pre-cutover desired-present contract resolves
operational `aws.*` solely to assume the exact fixed `prodbox-ses-lease-session` role, then uses a
bounded role session only for a narrow provider or credential mutation fence; readiness and target
delivery hold no session. Explicit destroy/migrate-backend and nuke remain admin-authorized. Clearing
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

1. **Init.** The harness supplies the simulated operator password to the dedicated Bootstrap
   Broker's bounded init-if-empty/unseal capability. The Gateway Runtime never receives the
   password or fronts this request. Every later credential interaction occurs only after Vault is
   authoritatively observed unsealed.
2. **Establish Authority backup.** On a pristine authority, `cluster reconcile` exposes
   `EstablishAuthorityBackup` while Authority is `GenesisFrozen`. The harness simulates the raw
   operator prompt from `aws_admin_for_test_simulation.*` only after the signed
   `GenesisBackupPermit` and attested Credential Provisioner Job exist. That Job alone creates or
   observes the deterministic shared bucket/Authority prefix/IAM identity, hands the one-time key
   directly to the home Target Secret Agent, and obtains seal/read-back evidence. The separately
   deployed Backup Adapter then writes and reads back the initial Authority state before normal
   admission opens and the genesis arm is permanently disabled. Temporary or unobservable S3/IAM
   failure freezes; only positive permanent loss may later enter the separate
   `BackupRepairFrozen`/`RepairPermit` path.
3. **Mint, seal, and deliver normal material.** After the initial backup receipt and in-force-config
   seed, normally backup-receipted `OperatorMaterialPermit`s drive the mode-indexed Credential
   Provisioner. It creates or rotates Operational Lifecycle-provider/AWS-DNS01 and LongLived
   TLS-retention/home Gateway-DNS/home-DNS01 identities as required. For retained SES it exclusively
   creates/rotates/remints the deterministic SMTP IAM identity, least-privilege policy, and bounded
   key family; repair-time deletion of an uncommitted or unrecoverable key also remains inside that
   same permit/family fence. Provider/Pulumi owns only non-credential SES/S3/DNS resources. Each
   ordinary identity key travels over authenticated linear ingress only to its exact Agent/Vault
   consumer. SMTP is stricter: in bounded memory the Provisioner derives the region-bound closed
   `SesSmtpSource` from the one-time IAM secret, discards the raw AWS secret-access-key bytes, and
   ingresses only `SesSmtpSource` to a one-shot retained-home Agent worker. It requires a
   payload-specific Transit-sealed source-custody receipt before committing the IAM generation.
   Later one-shot home and selected-target Agent
   workers transfer the payload attestation-encrypted and perform allowlisted target generation
   CAS/read-back. Lifecycle Authority and its outbox persist only ciphertext and typed opaque
   receipts/commitments, never source plaintext, a plaintext hash, or a generic export coordinate.
   A fresh AWS Vault can therefore restore the committed SMTP generation without an admin re-prompt
   or IAM-key rotation. Closed `AcmeEabSource` follows the same retained-home custody/rewrap shape
   under its own schema-indexed `OperatorMaterialPermit`, but its values arrive through a separate
   externally supplied linear ingress—not the AWS admin prompt and not `config setup`. `prodbox.dhall` carries
   only non-secret coordinates.
4. **Validate.** The harness binds one operation-indexed Lifecycle Authority `CapabilityRef` and
   uses it unchanged for observation, admission, and execution. Canonical `aws-ses reconcile`
   submits a durable operation ID; a lost response is recovered by observing that ID. The base
   Lifecycle-provider identity is used only to assume `prodbox-ses-lease-session` for a narrow
   non-credential provider fence over registered SES/S3/DNS resources, with a session bounded by
   the operation's absolute deadline and the role's 3,600-second maximum. SMTP IAM/key work uses
   only the Credential Provisioner path in step 3. Propagation waiting and Target Secret Agent
   outbox delivery hold no mutation session. The base identity is not passed to Pulumi/AWS mutation
   children.
5. **Run explicit admin actions separately.** When a selected validation owns SES destroy, legacy
   backend migration/retained-store compatibility, or quota request/status read-back, Authority commits a distinct
   backup-receipted `AdminActionPermit`. Only the attested one-shot Admin Action Runner receives the
   simulated prompt. `DestroyAwsSes` is the sole exception to Credential Provisioner ownership of
   credential-family deletion. After consumers are quiescent, it deletes/read-backs the exact
   registered SMTP key family, identity, and policy while the non-credential provider destroy proves
   SES/S3/DNS absence; only then, while both Agents remain live, are every owned target/source
   custody KV-v2 version physically destroyed, its metadata deleted/read back, and absence proved.
   Soft delete or a new logical tombstone cannot satisfy this transition. The runner cannot create/rotate/remint
   credentials, run ordinary repair/provider work, or expose a generic export. Total `nuke` is not
   this runner; it uses the standalone Decommission Runner only after an external signed receipt
   exists and Authority has stopped.
6. **Postflight teardown.** On every suite exit, the always-run cleanup DAG first resolves recorded
   Lifecycle Authority operations to a clean or explicit recovery disposition, restores runtime,
   and attempts every credential-dependent per-run destroy. It deletes only Operational roles,
   keys, and AWS-DNS01 generation after their exact dependants are absent, then physically destroys
   their owned Vault KV-v2 versions and deletes/read-backs metadata. Authority-backup, TLS-retention, home Gateway-DNS, home DNS01, the SMTP IAM
   identity/policy/key family, and its retained-home source custody remain LongLived; `aws-ses`
   likewise remains retained. Independent cleanup continues after sibling failure, and
   the final result aggregates the original validation failure with every cleanup failure.

Long-lived retention in step 6 is independent of preparation in step 4. Invite-capable suites must
ensure the registered `aws-ses` desired state idempotently; they must not require an operator to
pre-provision it, and must not destroy it on success, failure, or Ctrl-C. Lifecycle Reconciliation
Doctrine owns durable operation/fence/outbox semantics and Integration
Fixture Doctrine owns cleanup scheduling. The ordering is defined in
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

Physical capability identity and isolation are defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Implementation
and deployment-qualification status live only in the Development Plan.

> **Historical pre-cutover implementation record.** The old Vault clear is implemented by writing
> empty-string values to `secret/gateway/gateway/aws`
> (`clearOperationalAwsConfig` → `writeOperationalAwsVaultCredentials` with empty credentials in
> `src/Prodbox/Aws.hs`), **not** by issuing a true Vault KV delete. The operational key material
> is overwritten so it can no longer be resolved, but the KV path itself is left present with
> blank fields. Sprint `4.50` removes this shared path after split-generation cutover; it is not a
> target cleanup primitive and must not be described as a hard delete.

The operational IAM mint/write/clear lifecycle is the credential boundary. Implementation status
and fresh-account propagation evidence remain in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md). The harness fixture-ownership and
explicit-cleanup obligations this lifecycle obeys are owned by
[integration_fixture_doctrine.md §2](./integration_fixture_doctrine.md); the operational-secret
classification it writes into Vault is owned by
[config_doctrine.md §0](./config_doctrine.md).

---

## 5. Standalone Substrate-Provisioning Credentials

There is no steady-state `prodbox.aws.*` super-credential in the target. The required identity is a
property of the operation:

| Operation | Identity |
|-----------|----------|
| Pulumi, SES, EBS, or explicit AWS-edge provider intent | `Operational` Lifecycle-provider identity, narrowed through the exact role committed in the intent |
| Home public A-record observe/ensure/delete/read-back | `LongLived` Gateway-DNS identity scoped to the registered account/zone/name/type |
| DNS01 TXT work on one substrate | That substrate's cert-manager-DNS01 identity: `LongLived` on home, `Operational` on AWS |
| Authority backup S3 copies | LongLived Authority-backup-store identity, consumed only by Backup Adapter |
| Retained TLS ciphertext objects/versions | LongLived TLS-retention-store identity, consumed only by TLS Retention Adapter under exact `public-edge-tls/<substrate>/<fqdn>` prefixes |
| Retained SES SMTP IAM identity/policy/key family | LongLived deterministic family; Credential Provisioner exclusively creates/rotates/remints and performs repair-time key deletion under `OperatorMaterialPermit`; its derived closed SMTP payload has retained-home Transit-sealed source custody for attested target rewrap without re-prompt/rotation |
| ACME EAB source payload | Separately externally supplied closed `AcmeEabSource` schema under its own `OperatorMaterialPermit`; retained-home Transit-sealed custody supports attested selected-target restore and is never sourced from the AWS admin prompt or Tier-0 config |
| Explicit destructive compatibility or quota request/status read-back | Ephemeral prompt delivered only to the attested Admin Action Runner under an exact committed permit |
| Identity genesis/rotation | Ephemeral prompt delivered only to the attested Credential Provisioner under an exact committed permit |
| `nuke` after exported manifest | Ephemeral prompt held only by the standalone Decommission Runner |

Every command fails fast when its exact generation is absent, stale, revoked, or unobservable.
There is no fallback to another role, host AWS state, profiles, instance metadata, or a shared key.
Named AWS validations are the automation exception only to interactivity: the harness simulates the
same prompt, reconciles run-scoped identities, and observes retained identities without deleting
them through ordinary cleanup.

The long-lived `aws-ses` reconcile submits a durable operation to the retained Lifecycle Authority
and uses the Lifecycle-provider identity only to assume the exact
`prodbox-ses-lease-session` role for a narrow non-credential SES/S3/DNS mutation fence. A separate
`OperatorMaterialPermit` sends deterministic SMTP IAM identity/policy/key-family work only to
Credential Provisioner. That Provisioner commits the generation only after it has derived the
region-bound closed `SesSmtpSource`, discarded raw AWS secret-access-key bytes, and obtained its
retained-home Transit-sealed source receipt. Propagation and attested Agent-to-Agent
target materialization hold no AWS session and need no re-prompt/key rotation. Explicit
`DestroyAwsSes` sends exact registered-family deletion only to Admin Action Runner; after consumer
quiescence and external family absence, every owned target/source-custody KV-v2 version is
physically destroyed and its metadata deleted/read back while the Agents remain live. Migration and
nuke remain separately admin-authorized. Lifecycle
class controls retention; it never licenses credential sharing or adoption of a discovered
resource.

There is exactly one runtime way elevated/admin power enters `prodbox` — the interactive
`SecretRef.Prompt` arm. Real flows prompt; the test harness simulates that prompt. The rows below
distinguish *who answers the prompt*, not separate credential stores:

| Workflow shape | How elevated/admin power is supplied | Entrypoints |
|----------------|-----------------|-------------|
| Standalone substrate provisioning | **Public prompt path**: submit mode-indexed permits to the attested Credential Provisioner, seal/read back ordinary keys at their exact consumer and SMTP `SesSmtpSource` at retained-home custody, then discard admin material. Ordinary teardown removes only Operational identities. | `prodbox aws setup` at start; `prodbox aws teardown` at end |
| Suite-driven runs | **Test-harness simulation path**: feed `aws_admin_for_test_simulation.*` from `test-secrets.dhall` to the same permit-bound Jobs, register cleanup before mutation, revoke Operational identities only after their dependants are absent, and retain the LongLived set. | `prodbox test integration aws-iam`, `prodbox test integration keycloak-invite`, `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, `prodbox test all` |
| Canonical retained desired-present operation | **Split provider/material path**: submit one durable operation ID; Provider Worker assumes only `prodbox-ses-lease-session` for non-credential SES/S3/DNS, while Credential Provisioner receives separate `OperatorMaterialPermit`s for the deterministic SMTP IAM family and commits only after retained-home source custody. One absolute deadline bounds queue and effect work; propagation and attested Agent-to-Agent target materialization hold no AWS session and expose no generic export. | `prodbox aws stack aws-ses reconcile` |
| Long-lived destructive/compatibility operations | **Admin Action Runner prompt path**: after consumers quiesce, `DestroyAwsSes` deletes/read-backs the exact registered SMTP IAM family and composes it with non-credential stack absence; while Agents remain live, every owned target/retained-home custody KV-v2 version is then physically destroyed and its metadata deleted/read back. `migrate-backend`, retained-store compatibility, and quota request/status read-back use their own exact `AdminActionPermit`. `prodbox nuke` uses the same external-first/Agent-physical-deletion ordering through its standalone Decommission Runner only after signed external-receipt export; neither path is a generic secret export. | `prodbox aws stack aws-ses destroy --yes`, `prodbox aws stack aws-ses migrate-backend`, `prodbox aws quotas request`, `prodbox nuke` |

These paths remain distinct even when one suite uses all of them. A standalone substrate run uses
`prodbox aws setup` and `prodbox aws teardown` symmetrically. A suite-driven run owns setup,
per-run cleanup, identity revocation, and physical Vault version/metadata deletion end-to-end. The invite-capable
preparation uses its Lifecycle-provider generation only for the fixed non-credential role; SMTP
install/repair uses Credential Provisioner, while converged target restore uses retained
`SesSmtpSource` custody without re-prompt. A standalone workflow's intermediate steps (`cluster reconcile`,
`aws stack <stack> reconcile`, `charts reconcile --substrate aws`) must all run between the operator's
`prodbox aws setup` and the operator's `prodbox aws teardown`. A targeted AWS-substrate test is
not part of that manual window; `prodbox test integration <name> --substrate aws` owns the
temporary operational credential lifecycle itself.

The standalone substrate-provisioning step list is owned by
[DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md → Sprint 7.5.c Sprint Workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md);
this section is the credentials-side contract that workflow cites.

## AWS credentials under Vault

Vault holds production secrets only; none of our testing secrets live in Vault. Runtime AWS
material is split across:

- `secret/aws/lifecycle-provider` — `Operational`, fenced Provider Worker only;
- `secret/aws/authority-backup-store` — `LongLived`, Authority Backup Adapter only;
- `secret/aws/tls-retention-store` — `LongLived`, TLS Retention Adapter only;
- `secret/aws/gateway-dns` — `LongLived`, home Gateway DNS writer only;
- `secret/aws/cert-manager/home/dns01` — `LongLived`, home cert-manager only; and
- `secret/aws/cert-manager/aws/dns01` — `Operational`, AWS cert-manager only.

Each path has a distinct IAM resource, Vault policy, generation, consumer, and cleanup node.
`prodbox.dhall` contains only non-secret role coordinates.

The retained SMTP IAM family is not another reusable AWS-key Vault path. Lifecycle Authority keeps
only its key ID and typed receipts. Credential Provisioner derives region-bound `SesSmtpSource` in
bounded memory and discards the raw AWS secret-access-key bytes; the retained-home Agent stores the
payload-specific Transit-sealed source and each selected target materializes only
`secret/keycloak/smtp` through attested one-shot rewrap.

The credential-supplying interaction happens **after** Vault is set up and unsealed. A newly
returned AWS key is not "minted directly into Vault": it exists briefly in the Credential
Provisioner's bounded memory and crosses authenticated linear ingress only to its exact payload
consumer. Raw SMTP AWS secret-access-key bytes never cross into retained custody. The order is:

1. bring up and unseal Vault
2. if Authority backup is not established, Authority enters `GenesisFrozen`, commits the
   deterministic backup intent, and signs one `GenesisBackupPermit`; a positive later permanent
   loss instead uses `BackupRepairFrozen` and one `RepairPermit`
3. for normal identity work, Authority commits and backup-read-backs one
   `OperatorMaterialPermit`; an attested mode-indexed Credential Provisioner—not Provider Worker—
   receives that permit plus the raw prompt
4. the Provisioner reconciles only the permit's registered IAM/S3 identity and hands ordinary
   identity material directly to its exact Agent/Vault consumer; for SMTP it derives the
   region-bound closed `SesSmtpSource`, discards the raw AWS secret-access-key bytes, and requires a
   retained-home Transit-sealed source-custody receipt
5. payload-specific one-shot Agent workers seal/CAS/read back the role-specific target. SMTP and
   ACME EAB restore use attestation-encrypted home-to-selected-worker rewrap from retained custody;
   the Agents return opaque receipts/commitments rather than plaintext or a credential digest
6. `prodbox` discards the prompted elevated credential and records no plaintext in Authority state

Prompt-use-discard is the only handling for the ephemeral elevated credential: it is never written
to `prodbox.dhall`, Vault, the Authority aggregate, a serializable capability program, logs, or
disk. Explicit SES destroy, migration/retained-store compatibility, and quota request/status use the
separate Admin Action Runner; `nuke` uses only the post-export Decommission Runner. The pre-cutover shared
`secret/gateway/gateway/aws` path and `Prodbox.Infra.AwsProviderCredentials` fallback are deletion
surfaces owned by Sprint `4.50`.

In-cluster consumers authenticate through distinct Vault Kubernetes-auth roles. Provider Worker,
Backup Adapter, TLS Adapter, Gateway DNS writer, and each cert-manager instance receive only their
own generation; Target Secret Agent can write the allowlisted paths but cannot consume the AWS
capability. Sharing a cluster confers no cross-role authority. Ordinary suite cleanup and
`aws teardown` remove only Operational Lifecycle-provider/AWS-DNS01 identities. LongLived backup,
TLS, home Gateway-DNS, home DNS01, retained SMTP IAM identity/policy/key-family state, and its
retained-home source custody remain.
Only Credential Provisioner may create/rotate/remint or perform repair-time key deletion; only
Admin Action Runner under `DestroyAwsSes` may delete/read-back the entire registered SMTP family.
That destroy first quiesces consumers and proves the external family absent, then physically
destroys every owned target/retained-home custody KV-v2 version and deletes/read-backs its metadata
while the Agents remain live. Total `nuke` uses
the same ordering; neither operation admits a generic export.
TLS deletion means exact TLS prefix
objects/versions plus its identity/policy; the shared bucket is deleted only by the final
Authority-backup decommission tail after every registered prefix is absent.

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
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
