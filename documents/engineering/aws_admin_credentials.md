# AWS Admin Credentials

**Status**: Authoritative source
**Supersedes**: N/A
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
   repair plus retained-home SMTP source custody/rewrap; and the sole registered non-credential
   Provider role `prodbox-lifecycle-provider`

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
   reconciles only required Operational Lifecycle-provider/AWS-DNS01 identities plus the exact
   account-bound `prodbox-lifecycle-provider` role; and invokes SMTP material mutation only under its distinct
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
operational `prodbox` IAM user unconditionally with respect to Pulumi residue. **Current revision
(Sprint `5.36`).** The later descriptor-bound harness cleanup supersedes the historical
`awsPostflightDestroyActions`: exact selected per-run nodes run through the closed lifecycle
dispatcher, and the legacy operational teardown is released only by the lifecycle-owned node-state
decision. The long-lived `aws-ses` stack is correctly *not* stranded because its explicit destroy
is still admin-credentialed. The
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
   only non-secret coordinates. In a cluster-backed automated recovery, the pre-Gateway
   Lifecycle-provider repair is triggered through the retained bootstrap-core operator caller while
   using the simulated prompt and a fresh invocation lineage. The command boundary obtains 256 bits
   of entropy and binds the substrate/suite and optional qualification cycle; it fails if it cannot
   obtain that lineage. Install and revoke use distinct fixed slots within it. Their lookup index
   stays constant when the Target disappears, while each intent carries its actual generation. The
   canonical, secret-free Lifecycle-provider role-policy digest revisions the scope before lookup.
   A retry reuses an exact retained intent and validates a completed receipt against the current
   Target; a new invocation selects a fresh operation even after the previous Target was removed.
   A changed policy selects a different operation and, when a Target exists, its next generation,
   which must put and exactly read back the role policy before key creation. A completed operation
   is never reinterpreted or mutated under new policy code. The
   Gateway-owned harness caller remains removable with Gateway and is not a prerequisite for
   restoring the credential needed by the ordinary reconcile graph.
4. **Validate.** The harness binds one operation-indexed Lifecycle Authority `CapabilityRef` and
   uses it unchanged for observation, admission, and execution. Canonical `aws-ses reconcile`
   submits a durable operation ID; a lost response is recovered by observing that ID. The base
   Lifecycle-provider identity is used only to assume the account-bound
   `prodbox-lifecycle-provider` role deterministically selected by the closed intent for a narrow
   non-credential provider fence over registered SES/S3/DNS resources. Native STS validates both
   the base-user and assumed-role ARNs before any capability runs. Its remote
   credential duration is derived from the operation's signed deadline and does not widen the
   operation: the opaque handle and temporary subprocess
   projection cannot escape the rank-2 callback, and effect work remains bounded by the absolute
   deadline. SMTP IAM/key work uses
   only the Credential Provisioner path in step 3. Propagation waiting and Target Secret Agent
   outbox delivery hold no mutation session. The base identity is not passed to Pulumi/AWS mutation
   children. The role's permissions policy is held complete against the AWS CLI verbs its interpreters
   run: `Prodbox.Lifecycle.CredentialProvisioner.ProviderCliActions` names the IAM actions each verb is
   authorized by, and `prodbox dev check` fails when a Provider-run module invokes a verb the table
   does not name or when the policy does not allow a named action, so a missing action is a gate
   finding rather than a denial found by a live run. Pulumi programs the Provider runs are outside
   that rule. The validations and the AWS substrate platform reach AWS through closed intents rather
   than a host credential: `EnsureValidationHostedZone` creates the `dns-aws` validation zone,
   `ObserveSealedSesInviteMail` and `ReapSesInviteMail` read and remove the captured invite message (and
   require the SES capture-bucket owned tags as well as the role's exact configured-bucket scope), and `EnsureRetainedEbsVolumes` creates the retained volumes the
   AWS substrate's PersistentVolumes bind to. Invite observations bind an invocation-only receiver
   public key and return only authenticated ciphertext; no invite action token enters new Authority
   evidence or Provider replay records. The historical plaintext observation slot returns a retired
   marker and has no executable mail-reading capability. Their families (`ses:invite-mail`, `ebs-ensure:retained`)
   join the production resource allowlist, which is compiled into the control-plane runtime image, so
   an Authority or Provider image built with the older list refuses them until it is rebuilt and rolled.
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
   exists and Authority has stopped. Legacy migration reaches retained state only through the
   runner-authenticated Authority execution route: Authority persists preparation and confirms the
   registered checkpoint plus backup before the Runner deletes the exact legacy source. Quota
   request intent is likewise Authority-CAS-persisted before the native Service Quotas call;
   ambiguous recovery uses current quota and the complete paginated exact-tuple history, with two
   stable absence observations before the one permitted retry. Because that AWS API has no client
   token, no invented idempotency token is accepted as proof.
6. **Postflight teardown.** On every suite exit, the always-run cleanup DAG first resolves recorded
   Lifecycle Authority operations to a clean or explicit recovery disposition, restores runtime,
   and attempts every credential-dependent per-run destroy. It deletes only Operational roles,
   keys, and AWS-DNS01 generation after their exact dependants are absent, then physically destroys
   their owned Vault KV-v2 versions and deletes/read-backs metadata. Authority-backup, TLS-retention, home Gateway-DNS, home DNS01, the SMTP IAM
   identity/policy/key family, and its retained-home source custody remain LongLived; `aws-ses`
   likewise remains retained. Independent cleanup continues after sibling failure, and
   the final result aggregates the original validation failure with every cleanup failure.
   The ordinary cleanup client registers/adopts before credential preparation, including a fresh
   install lineage on resume. It withholds the fixed Lifecycle-provider revoke slot unless every
   nonempty resource result succeeds and zone evidence is complete. After the worker receipt, an
   independent Agent metadata read must confirm absence before it reports `revoked`; failure stays
   unresolved and fails the suite. Cancellation attempts this eligible tail before being rethrown.
   The separate cascade-qualification runner retains its credential until Sprint `6.5` composes
   retirement before local control-plane uninstall; it cannot call the Agent after that uninstall.

Lifecycle-provider IAM parameters explicitly bind the optional configured SES capture bucket.
Bucket and object S3 grants name only that bucket's ARN and its object ARN; no configured capture
bucket means no S3 grant. The Credential Provisioner validates and signs the scope, installs the
literal policy and reads it back before key creation. Historical no-capture parameter encoding
remains readable and grants no S3 access. A symbolic policy template is used only for the durable
operation revision and action-coverage checks; it is never an applied IAM program. The capture
lifecycle APIs add exact `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration` actions
within the same bucket scope, and change the policy revision rather than reusing an old completion.

Within an ordinary AWS-admin revoke, request construction and permit decoding admit only
Operational or RunScoped classes. The worker destroys the complete IAM family, waits its bounded
visibility grace and independently reads absence before invoking Target revocation. IAM failure,
continued presence or an unobservable read leaves the Target boundary untouched. The Target's
own independent absence read-back is still required; its revoke response alone cannot complete
the joint revocation proof. The dedicated decommission and retained-destruction protocols own
LongLived and retained-custody families.

Long-lived retention in step 6 is independent of preparation in step 4. Invite-capable suites must
ensure the registered `aws-ses` desired state idempotently; they must not require an operator to
pre-provision it, and must not destroy it on success, failure, or Ctrl-C. Lifecycle Reconciliation
Doctrine owns durable operation/fence/outbox semantics and Integration
Fixture Doctrine owns cleanup scheduling. The ordering is defined in
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

Physical capability identity and isolation are defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Implementation
and deployment-qualification status live only in the Development Plan.

> **Historical pre-cutover implementation record.** The former cleanup overwrote the shared Vault
> object with empty fields rather than deleting it. Sprint `4.50` physically removes that writer;
> current cleanup uses the generation-bound Target Agent tombstone/delete/read-back protocol. The
> historical behavior is retained only in the cleanup ledger and is not a target primitive.

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
| Pulumi, SES, EBS, or explicit AWS-edge provider intent | `Operational` Lifecycle-provider base identity, narrowed through native STS to the sole account-bound registered role deterministically selected by the closed intent |
| Home public A-record observe/ensure/delete/read-back | `LongLived` Gateway-DNS identity scoped to the registered account/zone/name/type |
| DNS01 TXT work on one substrate | That substrate's cert-manager-DNS01 identity: `LongLived` on home, `Operational` on AWS |
| Authority backup S3 copies | LongLived Authority-backup-store identity, consumed only by Backup Adapter |
| Retained TLS ciphertext objects/versions | LongLived TLS-retention-store identity, consumed only by TLS Retention Adapter under exact `public-edge-tls/<substrate>/<canonical-scope-key>` prefixes |
| Retained SES SMTP IAM identity/policy/key family | LongLived deterministic family; Credential Provisioner exclusively creates/rotates/remints and performs repair-time key deletion under `OperatorMaterialPermit`; its derived closed SMTP payload has retained-home Transit-sealed source custody for attested target rewrap without re-prompt/rotation |
| ACME EAB source payload | Separately externally supplied closed `AcmeEabSource` schema under its own `OperatorMaterialPermit`; retained-home Transit-sealed custody supports attested selected-target restore and is never sourced from the AWS admin prompt or Tier-0 config |
| Explicit destructive compatibility or quota request/status read-back | Ephemeral prompt delivered only to the attested Admin Action Runner under an exact committed permit |
| Identity genesis/rotation | Ephemeral prompt delivered only to the attested Credential Provisioner under an exact committed permit |
| `nuke` after exported manifest | Ephemeral prompt held only by the standalone Decommission Runner |

Every command fails fast when its exact generation is absent, stale, revoked, or unobservable.
There is no fallback to another role, host AWS state, profiles, instance metadata, or a shared key.
The completed worker receipt's kind matches its signed action: install/rotate require an installed
receipt, and revoke requires a revoked receipt. Matching operation, Target and generation alone
cannot substitute for this action check.

Credential succession preserves the predecessor in a canonical metadata archive bounded to
64 KiB. The completed Provisioner operation retains those bytes before admission advances; a
separate final read checks the entire permit/receipt/archive state. A transient server-owned proof
then performs its own fresh authenticated Agent read. It has no wire decoder or serialization
instance. The aggregate completion fold accepts this proof rather than caller-supplied observations.
Both positive IO producers remain package-private: exporting a constructor-free builder that accepts
a caller's repository or observer would still let that caller manufacture evidence. Public facades
expose the proof types and read-only projections; fixed diagnostics return assertions only.
Ordinary credential retirement remains distinct from cascade revocation: the former permits a later
generation-1 install after exact absence, while the latter retains its clean audit and frozen
reservation. Immutable operation/archive links preserve earlier evidence across subsequent cycles.
The Authority reserves the Provider credential epoch before issuing the worker challenge, rechecks
the reservation before signing, and admits the exact maximum-width terminal outbox before returning
the permit. It settles completion only after publication, an independent full outbox read and a
fresh Agent observation. A lost aggregate CAS reply is settled by an independent read and an
idempotent replay of the same fold.
Before the first reservation in a legacy/untracked epoch, bounded namespace Job and Pod lists
must independently show complete emptiness. A failed, partial or continued observation cannot
establish this worker quiescence. Existing signed permits bind exact Job/Pod UIDs, so a newly
created workload cannot consume an old attestation after those objects are absent.
When a completed worker journal outlives a lost Authority completion reply, the Authority reads
the exact permit-derived journal twice and validates the unchanged receipt before settling its
outbox. Completed observation and preparation also re-confirm the exact first-reconcile journal
receipt. An outbox completion cannot bypass a failed first-reconcile update. Recovery then uses
the ordinary publication, fresh Agent observation and aggregate-settlement path; it issues no new
worker permit merely because a journal claims completion.

An expired interrupted install or rotation has one deterministic revoke-only cleanup child.
Admission binds the actual parent reservation and signed permit, requires exact Job and Pod
absence plus an observable execution journal, and reads the current Agent generation.
The child revokes that exact generation, bounded above by its parent; an absent Target uses the
parent generation. A second parent-outbox read must agree before the aggregate CAS. The child
archive retains the parent reservation, permit digest and a closed nonrecursive predecessor
snapshot. It cannot admit another child, and the superseded parent cannot complete over it.
First-reconcile metadata preparation permits this cleanup without advancing the unfinished
provisioning journal. Successful cleanup still requires the ordinary IAM-first revoke, independent
publication readback and fresh Agent absence proof before ordinary retirement permits a new install.
For a completed parent or completed worker journal, the exact receipt must validate against the
signed permit and agree with the retained outbox receipt when both exist. A current Agent that
matches that installed receipt refuses cleanup and resumes normal completion. Missing or changed
Target material may select cleanup only after the same expiry, workload, generation and unchanged
parent checks. The explicit metadata lookup carries retained intent/phase bytes without invoking
journal confirmation or Agent settlement; those bytes cannot establish completion or admission.
The read-only retained-state query distinguishes idle, pending, serving, ordinarily retired,
revoked predecessor and closed cascade admission. Serving and retirement include their retained generation and carry
a deterministic scope digest over the canonical epoch metadata. Neither is a Target observation.
A generation-one install after ordinary retirement may be prepared while another first-reconcile
member is pending. It advances that journal only when it is the matching Provider member; otherwise
it carries no plan binding. Exact pending-reservation replay preserves this rule. Legacy, serving
and different pending reservations cannot assert ordinary retirement to use this preparation lane.

The retained first-reconcile journal separates its receipt cursor from recovery settlement.
Version 2 keeps recovery pending after the final receipt, through an interrupted cleanup or
replacement install. Its settlement endpoint independently confirms the current completed Provider
outbox, immutable lineage publication, fresh Agent metadata and unchanged serving operation before
committing and independently reading the settled journal. A subsequent ordinary postflight revoke
does not reopen this marker. Version-1 objects retain canonical byte identity; incomplete objects
upgrade on the next receipt, while already complete legacy objects remain settled.
The bootstrap consumer resumes at most one reserved credential operation and performs at most two
additional repairs: an exact-generation serving revoke and a retirement-scoped generation-one
install. It then resumes the remaining journal members and requests settlement. A repair revoke
may be prepared alongside a later member only while recovery is pending and the serving generation,
or the exact retained revoke reservation, agrees. Neither repair advances an unrelated member.
For an absent serving Target, the harness first proposes a distinct revoke at the retained
generation, scoped to that serving epoch. The ordinary invocation slot is resolved only after the
coordinator returns its exact revoke receipt and a fresh Agent read confirms absence. One repair
is permitted; another repair request refuses. Postflight revoke also uses the retained serving or
retired generation when Target material is absent. A revoked cascade permits an install proposal
whose admission still requires the Authority's exact completed-predecessor proof. A recorded audit
exposes its retained generation only for the final revoke proposal; the Authority still requires
the exact clean audit. Frozen admission refuses both operations.

A cascade successor additionally requires server-owned observations of the exact run, descriptor,
graph and terminal-audit scope. Both independent observations require the complete expected node
set with every node successfully completed. A failed primary outcome does not invalidate separately
successful cleanup. Compacted history requires the actual canonical report from authenticated
Backup, its matching receipt and a byte-level digest check; a tombstone digest alone proves nothing.
The successor archive retains that completed-report digest together with the original audit,
revocation and lineage evidence. The transient proof remains positional, package-private and
non-serializable. Sprint `6.5` owns validation and interrupted-operation recovery for this lane.
Named AWS validations are the automation exception only to interactivity: the harness simulates the
same prompt, reconciles run-scoped identities, and observes retained identities without deleting
them through ordinary cleanup.

The long-lived `aws-ses` reconcile submits a durable operation to the retained Lifecycle Authority
and uses the Lifecycle-provider identity only to assume the exact account-bound
`prodbox-lifecycle-provider` role for a narrow non-credential SES/S3/DNS mutation fence. A separate
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
| Standalone substrate provisioning | **Public prompt path**: with retained local RKE2 and Lifecycle Authority already serving, submit mode-indexed permits to the attested Credential Provisioner, seal/read back ordinary keys at their exact consumer and SMTP `SesSmtpSource` at retained-home custody, then discard admin material. Ordinary teardown removes only Operational identities. | `prodbox cluster reconcile` first; `prodbox aws setup` starts the AWS window; `prodbox aws teardown` ends it |
| Suite-driven runs | **Test-harness simulation path**: feed `aws_admin_for_test_simulation.*` from `test-secrets.dhall` to the same permit-bound Jobs, register cleanup before mutation, revoke Operational identities only after their dependants are absent, and retain the LongLived set. | `prodbox test integration aws-iam`, `prodbox test integration keycloak-invite`, `prodbox test integration <name> --substrate aws`, `prodbox test integration all`, `prodbox test all` |
| Canonical retained desired-present operation | **Split provider/material path**: submit one durable operation ID; Provider Worker assumes only the account-bound `prodbox-lifecycle-provider` role for non-credential SES/S3/DNS, while Credential Provisioner receives separate `OperatorMaterialPermit`s for the deterministic SMTP IAM family and commits only after retained-home source custody. One absolute deadline bounds queue and effect work; propagation and attested Agent-to-Agent target materialization hold no AWS session and expose no generic export. | `prodbox aws stack aws-ses reconcile` |
| Long-lived destructive/compatibility operations | **Admin Action Runner prompt path**: after consumers quiesce, `DestroyAwsSes` deletes/read-backs the exact registered SMTP IAM family and composes it with non-credential stack absence; while Agents remain live, every owned target/retained-home custody KV-v2 version is then physically destroyed and its metadata deleted/read back. `migrate-backend`, retained-store compatibility, and quota request/status read-back use their own exact `AdminActionPermit`. `prodbox nuke` uses the same external-first/Agent-physical-deletion ordering through its standalone Decommission Runner only after signed external-receipt export; neither path is a generic secret export. | `prodbox aws stack aws-ses destroy --yes`, `prodbox aws stack aws-ses migrate-backend`, `prodbox aws quotas request`, `prodbox nuke` |

A suite-driven run that sends an invite submits the retained SES SMTP permit itself: the harness,
not the retained SES preparation (which reconciles only the non-credential Provider resources),
requests the deterministic SMTP identity, so the permit, the sealed retained-home custody and the
delivery to `secret/keycloak/smtp` exist on the home cluster before the Keycloak chart is deployed.

These paths remain distinct even when one suite uses all of them. A standalone substrate run first
reconciles the mandatory local RKE2 control plane, then uses `prodbox aws setup` and
`prodbox aws teardown` symmetrically. A suite-driven run owns setup,
per-run cleanup, identity revocation, and physical Vault version/metadata deletion end-to-end. The invite-capable
preparation uses its Lifecycle-provider generation only for the fixed non-credential role; SMTP
install/repair uses Credential Provisioner, while converged target restore uses retained
`SesSmtpSource` custody without re-prompt. Once setup succeeds, a standalone workflow's AWS
intermediate steps (`aws stack <stack> reconcile`, `charts reconcile --substrate aws`) run between
the operator's `prodbox aws setup` and `prodbox aws teardown`; `cluster reconcile` is not inside
that window because it establishes the Authority that admits setup. A targeted AWS-substrate test is
not part of that manual window; `prodbox test integration <name> --substrate aws` owns the
temporary operational credential lifecycle itself.

This retained-control-plane-first order is the stable credentials-side contract. The old
[Sprint 7.5.c workflow](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md) is historical
closure evidence and cannot override it.

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
separate Admin Action Runner; `nuke` uses only the post-export Decommission Runner. The pre-cutover
shared Vault coordinate and `Prodbox.Infra.AwsProviderCredentials` fallback are deletion surfaces
owned by Sprint `4.50` and have no place in the target credential topology.

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

Before a harness credential Job starts, its admin credential region must match the validated
`pulumi_state_backend.region`. An absent backend region, invalid fixture region or mismatch is a
host-side refusal; it exposes only region metadata, never key material. This check also guards
the lazy credential loader used by Authority-backup admission and first-reconcile continuation,
so an initial backup Job receives the same preflight as Lifecycle-provider and SES Job preparation.

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
