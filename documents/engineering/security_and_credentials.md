# Security, Credentials and Vault

**Status**: Authoritative source
**Supersedes**: Pre-refactor Vault, secret derivation and AWS credential doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; existing runtime transitions remain phase-owned work

> **Purpose**: Define credential ingress/custody, Vault bootstrap/unlock, role isolation and secret-safe evidence.

## Security boundary

Trust the authenticated local operator with non-secret installation/resource metadata. Keep credentials, sensitive checkpoint payloads, private keys and custody material protected. This explicitly replaces the sealed-Vault policy that hid whether any children existed; useful lifecycle metadata can remain readable while secret access is unavailable.

Vault remains the operational secret/KMS/PKI authority. Production consumers use typed Vault references and role-scoped Kubernetes authentication, not plaintext Dhall/Kubernetes Secret credential fragments, environment fallback or a gateway secret service. Broker/Provisioner/Provider/Agents have separate RBAC, Vault policies and network access. Internal command visibility does not grant authorization.

## Ephemeral elevated AWS input

Production prompts and the test fixture supply the same bounded Credential Provisioner implementation. The Authority durably records the exact IAM creation/retirement intent before the first possible elevated effect, including bootstrap. No preparation mutation is allowed before registration.

`test-secrets.dhall` intentionally retains the operator-owned simulation credential as its test input source. The loader opens a regular non-symlink file, checks effective-user ownership and no group/other permission bits (`0600`), and reads that same descriptor. Refusal never chmods the file or falls back to ambient AWS credentials.

The runtime keeps elevated input in the selected worker's bounded memory/secure stdin only. It is never copied into config, Vault, MinIO, operation records, Kubernetes objects, argv, environment, logs or evidence. Production config cannot reference the test fixture as an auth source. On interrupted recovery, reacquire input for the existing recorded operation, not an untracked new identity.

Generated operational material is written to exact deployment-scoped Vault generations. Keep Provider, backup, TLS, DNS01/gateway and SMTP capabilities least-privilege and separate. Bind sessions to the verified account, explicit regions, operation and allowed resource families. No shared AWS profiles or host AWS CLI login supply supported auth.

Retain credentials while dependants need them. Remove remote backing resources while their authority remains available; verify IAM retirement independently using the ephemeral verifier when necessary; retire exact Vault generations last. A worker exit, token expiry or revocation request alone is not confirmation. Handle actual Vault token semantics rather than assuming every token type supports revoke-self.

## Vault bootstrap and unlock

Mount and verify the recorded Vault storage before initialization. Fresh init is allowed only for an established new identity with definitive uninitialized state. Existing initialized history plus a blank/unlinked/mismatched mount enters recovery, never automatic re-init. Preserve init response/custody transaction state sufficiently to resume an ambiguous reply without regenerating keys.

| Explicit policy | Behavior |
|---|---|
| Production protected unlock | Protected/password-encrypted bundle or configured external custody; use available authorized material or prompt in the requesting operation |
| Test MinIO self-unseal | Broker reads the exact run-owned MinIO bootstrap object containing test unlock material and unseals the same Vault automatically |

The test policy intentionally relaxes custody and is unrepresentable in a production context. Its MinIO object/read capability must work before Vault; encryption whose only decrypting key is inside sealed Vault cannot establish that capability. Scope bootstrap credentials to the run/object/local endpoint, keep them distinct from elevated AWS input, and retire object/access on run cleanup. Steady-state MinIO credentials still come from Vault.

Preload bootstrap images independently of the registry. Direct read-only Vault state must remain observable when Broker is unavailable. Classify absent, uninitialized, initialized-sealed, ready, unreachable and inconsistent-storage states distinctly. [Control bootstrap](control_plane.md#dependency-order)

## Secret delivery, encryption and rotation

Vault Transit protects sensitive objects; MinIO is object transport/storage, not another plaintext secret authority. Authority records identifiers, ciphertext/digests and generation receipts; bounded Agents own exact allowlisted plaintext writes/read-backs. Preserve PKI, unlock-bundle and Transit rotation capabilities with explicit custody/consumer recovery. No generic secret export endpoint exists.

Use authenticated context/scope, stable operation IDs and actual worker identity. Settle predecessor work before permitting successor effects; wall-clock expiry alone cannot prove physical worker absence. Quiesce secret consumers before generation retirement. Ordinary delete cannot destroy management trust needed to report its own outcome.

## Production/test ownership and SES

Use distinct production/test Vault identities, IAM principals, SES sending identities/subdomains, SMTP material, capture buckets/prefixes, DNS records and exact receipt rules. A test never reuses production SES identity or deletes its email resources. A campaign may reuse its own resources across cases until explicit scoped cleanup.

SES receiving has one active rule-set container per account/region. A dedicated receiving-test account is an option, not a hidden prerequisite. In a shared account, predeclare/co-ordinate the active container's ownership and separate exact production/test rules; never switch or deactivate a production set to run a test. If coexistence cannot be proved, refuse the disruptive operation. Shared container ownership cannot be invented during deletion. See [AWS ownership](aws_resources.md#ses-and-receiving-isolation).

## Redaction and validation

Do not log secrets or hash plaintext secrets into public evidence. Report logical operation/capability causes and metadata allowed by this contract, not credential bodies or raw provider payloads. Keep synthetic fixtures unmistakably synthetic and real inputs out of source/build contexts. Preserve `.gitignore`/container-context exclusions when files move.

Real init/unseal/restart, prompt/fixture IAM creation/use/revocation and same-generation delivery evidence belong to their introducing phases. Mutants that admit test unlock in production, omit write-ahead IAM intent or retire credentials too early must trigger the intended unchanged assertion. [Mutation policy](testing.md#targeted-mutation-testing)

## Implemented through Phase 2

Test and production unlock policies are distinct and a production identity cannot select the test self-unseal policy. The test path reads one object through a per-environment reader credential scoped to `GetObject` on that object; production uses `control protected-unlock`, which takes the unseal key at a hidden prompt (or one line of standard input), never touches MinIO and treats absent input as a distinct needs-input result. The initial root token is used once in memory to mint a limited, policy-scoped client token and is then revoked; it is never recorded in MinIO. Vault's Kubernetes authentication binds the Broker's roles to named ServiceAccounts, and the worker role is refused for the Broker's own account.

Test self-unseal requires a positive missing-key metadata response before it can initialize Vault. It records a retained initialization intent under the exact deployment generation before the call and preserves private pending custody until authenticated client read-back. A failed observation gives a recovery result. Service reconciliation verifies the enabled reader and exact single-object policy through MinIO's structured API, reuses a matching retained attachment, and reads back any new attachment.
