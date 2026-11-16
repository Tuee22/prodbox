# Federation

**Status**: Authoritative source
**Supersedes**: Pre-refactor cluster federation doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; implemented federation scope is owned by Phase 9

> **Purpose**: Define explicit child registration, trust, secret custody and recovery without duplicating lifecycle authority.

## Identity and registration

Federation is explicit `admin federation register/status`, not an incidental consequence of ordinary reconcile. Register a child's stable identity, exact parent relation, validated endpoint/trust material, target/account/region and required operations under the retained local kind Authority. No child or host fallback becomes a second writer for the same deployment scope.

The federation graph is acyclic. Reject unknown/mismatched parent/child identity, repeated or conflicting registration, endpoint changes outside the registered operation and production/test cross-binding. Membership/metadata is authenticated non-secret lifecycle information; secret access remains Vault-gated. This intentionally removes whole-system concealment of whether registered children exist.

## Vault and custody

A root uses its configured protected unlock policy; an admitted child can use parent Transit seal under an exact parent capability. Parent outage/seal withholds that capability and yields a specific readiness/input/recovery state. Never fall back to a test MinIO secret or initialize a replacement child Vault over existing identity.

Custody holds only encrypted/restricted recovery material and exact generation/receipt bindings. Do not persist a child root token as a reusable bootstrap credential. Child initialization, recovery share handling, bounded worker identity and authorized secret delivery follow [security_and_credentials.md](security_and_credentials.md).

A selected Target Agent writes only allowlisted child secret generations and reads them back. Parent/Authority sees ciphertext/references and confirmation, not a generic child-secret export. A stale peer key/generation/epoch or unauthenticated endpoint hint supplies no mutation authority.

## Configuration and operation ownership

Use the selected authored specification for desired federation topology and record accepted digest/applied generation in the Authority. Do not restore a second hidden in-force configuration database or independent child writer. Exact child operations, credential generations, workers and cleanup are registered before effects and resume through the common journal.

Registration is not permission to delete an external child or parent account. Declare whether a child target is owned, adopted or external. An owned child AWS family joins the same complete delete graph; external resources require their own supported owner/disposition. The final report states unresolved children rather than releasing credentials early.

## Recovery and proof

Phase 9 composes previously proven kind/Authority/credentials/service paths. Use at least two real disposable registered clusters/contexts to test parent/child unavailable and sealed states, wrong trust and stale generation, interrupted init/delivery, recovery, duplicate registration and exact cleanup. Keep each context/root/cloud scope independent.

Physical worker settlement precedes successor effects. Time expiry or a fabricated local witness is not settlement. Targeted source mutations that accept stale identity or competing ownership must fail the designated unchanged assertion; real unmodified-cluster evidence remains separately required. [Acceptance](../../DEVELOPMENT_PLAN/acceptance_cases.md) and [mutations](../../DEVELOPMENT_PLAN/mutation_cases.md)
