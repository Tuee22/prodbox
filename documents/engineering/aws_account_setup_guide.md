# AWS Account Setup Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md
**Generated sections**: none

> **Purpose**: Define the supported operator flow for creating or preparing an AWS account before
> running `prodbox config setup`.

The target credential topology is defined by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). Implementation,
cutover, and deployment-qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

---

## 1. Supported Onboarding Goal

The target onboarding path is two-stage:

```text
prodbox config setup
prodbox cluster reconcile
```

`config setup` writes and validates only non-secret Tier-0 coordinates. It may use an ephemeral
prompt for read-only account/zone discovery, but performs no IAM/S3/DNS mutation and persists no
credential. First `cluster reconcile` starts MinIO, Vault, Bootstrap Broker, the home Target Agent,
Lifecycle Authority, and Authority Backup Adapter in `GenesisFrozen`; its visible
`EstablishAuthorityBackup` action prompts for ephemeral admin power, establishes the LongLived
backup identity/store, seals/delivers/read-backs that generation, and commits the initial backup
receipt. Only then does normal Authority admission seed in-force config and issue
backup-receipted `OperatorMaterialPermit`s for Operational Lifecycle-provider/AWS-DNS01 and
LongLived TLS-retention/home Gateway-DNS/home-DNS01 identities. The prompt is admitted only to the
mode-indexed Credential Provisioner and is discarded from memory; normal provider work remains on
the separate Provider Worker.

Each generated key has its own IAM resource, Vault path, policy, generation, consumer, and cleanup
node. A newly returned key travels directly from the Credential Provisioner to the selected Target
Secret Agent. The Lifecycle Authority records only target-sealed ciphertext digest, an opaque
Agent/Vault keyed-HMAC commitment reference, generation, and outbox state—never a raw
plaintext/credential hash. The selected Target Secret Agent performs the allowlisted generation
CAS and read-back. The shared
`aws.*` credential and `secret/gateway/gateway/aws` path are pre-cutover legacy, not the target
setup result.

Access-key creation is never blindly retried. The setup operation commits an intent and finite
key-inventory observation first. If AWS created a key but its one-time secret response was lost
before target sealing, recovery deletes that uncommitted key, observes stable absence, and only then
remints.

The supported goal is full from-scratch bootstrap: `prodbox` can create every registered
role-specific AWS identity it needs once the operator supplies one ephemeral elevated credential
interactively at the prompt. See [vault_doctrine.md § 3](./vault_doctrine.md) for the `SecretRef` model and
[§ 4](./vault_doctrine.md) for the config split.

---

## 2. Create Or Prepare The AWS Account

If you do not already have an AWS account:

1. Sign up at <https://aws.amazon.com>.
2. Choose the Free Tier path during account creation.
3. Add a payment method. AWS requires it even for Free Tier usage.
4. Complete the identity-verification step.
5. Keep the Basic support plan unless you intentionally need paid support.

Free Tier context relevant to `prodbox`:

1. EC2 includes up to 750 hours/month of `t2.micro` or `t3.micro` for the first 12 months.
2. Route 53 is not fully free-tiered; hosted zones and queries are billed separately.
3. S3 includes a limited free storage allowance. The target local runtime requires the registered
   long-lived S3 Authority-backup coordinate before normal lifecycle mutation is admitted.

---

## 3. Create One Temporary Admin Access Key

`prodbox config setup` may ask for an ephemeral AWS credential only to perform read-only discovery:

1. list AWS regions
2. list Route 53 hosted zones

It performs no IAM, S3, DNS, or quota mutation. Mutating public AWS commands may ask for the same
operator credential source, but route it to one exact attested boundary:

1. the mode-indexed Credential Provisioner for Authority-backup genesis/repair or
   backup-receipted role-material installation/rotation
2. the Admin Action Runner for explicit SES destroy, legacy backend migration/retained-store
   compatibility, or quota request/status read-back
3. the post-export Decommission Runner for `prodbox nuke`

The normal Provider Worker never receives a prompt and cannot create identities.

The simplest supported operator workflow is:

1. Preferred path: open AWS console -> IAM -> Users -> your temporary admin user ->
   Security credentials -> Create access key.
2. Paste the access key ID and secret access key into the `prodbox` prompts; include the session
   token too if AWS gave you one. This is the only runtime path by which elevated/admin AWS power
   enters `prodbox` — the prompted credential is held in memory, used once, then discarded.
3. Keep the key only long enough to finish the interactive `prodbox` command you are running. A
   Credential Provisioner may reuse it across disjoint already-committed permits only while the
   same attested Pod/attach session, absolute deadline, and host heartbeat remain valid; otherwise
   re-prompt and resume the same operations.
4. Delete the key after `prodbox` reports the exact permit/action terminal and all generated
   generations or status receipts read back.

### 3.1 Two Credential Shapes — When To Paste A Session Token

AWS returns admin credentials in one of two shapes. The session-token prompt applies to only
one of them:

| Credential source | Access key ID prefix | Session token? | When to use |
|---|---|---|---|
| IAM console → Users → Security credentials → Create access key | `AKIA…` | **No, leave blank** | Long-lived IAM user keys |
| IAM Identity Center "Access keys" panel, `aws sts get-session-token`, `aws sts assume-role`, EC2 instance metadata | `ASIA…` | **Yes, required** | STS-derived temporary credentials |

If you paste an `ASIA…` key without the matching session token, AWS rejects every subsequent
API call with `InvalidClientTokenId`. If you paste an `AKIA…` key and also fill the
session-token field, AWS rejects every call because the session token is invalid for a
long-lived key.

Sprint `7.7` (May 19, 2026 closure, see
[`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` § Sprint 7.7](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md))
made the prompt auto-detect from the access-key prefix: `AKIA…` skips the session-token
prompt entirely, `ASIA…` makes the session-token prompt required (hidden input), and any
other prefix falls back to an optional prompt with an explanatory hint. The operator no
longer has to remember when to leave the field blank.

`aws_admin_for_test_simulation.*` is **not** an operator path at all. It is a test-harness-only
fixture living in `test-secrets.dhall` (`TestPlaintext` class) whose sole purpose is to drive the
UI — feeding the same interactive prompts a real operator answers so the harness can exercise
admin-credentialed flows non-interactively. Real operators **always** paste the ephemeral
elevated credential at the interactive prompt described in section 3 above; there is no
production path that reads a stored admin credential. The fixture is never imported by
`prodbox.dhall`, never read by any production binary, and never stored in Vault. The
canonical rules live in
[aws_admin_credentials.md](./aws_admin_credentials.md).

---

## 4. Create Or Confirm A Route 53 Hosted Zone

Before running `prodbox config setup`, the account must already contain at least one public Route 53
hosted zone.

Minimum supported preparation:

1. Register a domain or delegate an existing domain to Route 53.
2. Create a public hosted zone for that domain.
3. Confirm the hosted zone appears in the Route 53 console.
4. Confirm the domain's authoritative nameservers match the Route 53 zone when public-host proof is
   part of your target validation path.

`prodbox config setup` selects from the live hosted-zone list returned by the AWS CLI. It does not
create the hosted zone for you.

---

## 5. Run The Supported Setup Flow

Once the account, hosted zone, and ephemeral elevated/admin key are ready:

```bash
prodbox config setup
```

`config setup` walks through:

1. region selection from live AWS data
2. hosted-zone selection from live AWS data
3. FQDN and deployment defaults
4. ACME provider selection
5. non-secret coordinates for future Lifecycle-provider, Authority-backup, TLS-retention,
   Gateway-DNS, and per-substrate cert-manager-DNS01 identities, plus the shared bucket's disjoint
   Authority-backup and `public-edge-tls/<substrate>/<fqdn>` prefixes; it does not create them
6. `prodbox.dhall` write carrying non-secret topology and role coordinates only, followed by
   direct-Dhall validation

`cluster reconcile` performs the post-unseal genesis/setup sequence described in §1. Each generated
role key is handed directly to its target Agent, immediately sealed, and delivered/read back;
plaintext remains inside bounded one-shot boundary memory only. The separate TLS Retention Adapter
receives ciphertext envelopes only, and the Authority Backup Adapter receives Authority ciphertext/
receipts only. This path does not read any stored admin credential;
`aws_admin_for_test_simulation.*` is a `test-secrets.dhall` fixture used only by the test harness
to simulate this prompt.

---

## 6. Post-Setup Cleanup

After first `cluster reconcile` genesis/setup succeeds:

1. delete the ephemeral elevated/admin access key you pasted at the prompt for setup
2. confirm read-back of the LongLived Authority-backup-store generation/receipt, retained home
   TLS-retention-store, Gateway-DNS/home-DNS01 generations, and the Operational
   Lifecycle-provider/AWS-DNS01 generations
3. use only `prodbox` rotate/revoke commands for generated identities; provider/IAM deletion must
   precede the corresponding Vault tombstone
4. understand ordinary `aws teardown`/suite cleanup removes only Operational
   Lifecycle-provider/AWS-DNS01 material. It retains Authority-backup/TLS-retention/home
   Gateway-DNS/home-DNS01. Deleting TLS retention removes only its registered prefix
   objects/versions and identity/policy; the shared bucket is deleted only by the final
   Authority-backup decommission tail after every registered prefix is absent
5. `aws_admin_for_test_simulation.*` is not a `prodbox.dhall` field — it lives in
   `test-secrets.dhall` as a `TestPlaintext` fixture for the native IAM lifecycle test harness (and
   other repository tests that simulate the interactive elevated-credential prompt), never in
   production config and never in Vault

The earlier `config setup` discovery prompt, if used, was read-only. Later mutation prompts are
accepted only under an exact Credential-Provisioner, Admin-Action, or post-export decommission
permit and are never persisted. Normal runtime resolves only the identity for its exact operation.
A Provider Worker, Backup Adapter, TLS Adapter, Gateway, or cert-manager instance cannot read or
substitute another role's generation.

## Related Documents

- [acme_provider_guide.md](./acme_provider_guide.md)
- [aws_admin_credentials.md](./aws_admin_credentials.md)
- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md)
- [cli_command_surface.md](./cli_command_surface.md)
- [../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md)
