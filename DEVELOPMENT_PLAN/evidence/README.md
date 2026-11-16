# Phase Evidence Contract

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Required result schema and availability rules; no result is minted by writing this document.

> **Purpose**: Bind phase closure to actual execution, independent observation, critical assertion failures and terminal cleanup.

## Record contents

Every result names phase/task/case/mutation IDs, baseline source-manifest policy and digest, built binary/component image digests, non-secret configuration projection, environment/deployment/operation/resource scope, command/arguments, bounded budgets, timestamps, real dependency endpoints, independent observations, primary outcome, cleanup outcome and retained-state disposition. Record unavailable observations explicitly.

Mutation results also bind the exact source patch/preconditions, unchanged selected tests, intended and actual assertion, baseline result, outcome category, duration, scratch/fixture cleanup and reviewed equivalence rationale. Invalid builds, generic timeouts, missing reports and unrelated failing tests are not kills.

Retain failed results. Do not overwrite them with a later success, reuse a stale result for changed implementation/tests or treat a stored JSON claim as independent observation. The unmodified outer validator requires source/scope bindings and adversarial missing/fabricated/wrong-scope controls. Phase 1 implements the runner; Phase 0 uses existing real tooling without that later dependency.

## Secret handling and availability

Never ingest `test-secrets.dhall`, private generated configuration, `.data`/`.test-data` payloads, credentials or plaintext secret material into public manifests or raw hashes. Source allowlists include only non-secret implementation/schema inputs. Secret-dependent identity uses opaque generation/receipt IDs or an approved keyed commitment from the secret owner.

Large local results may live under an owned ignored build/evidence root. The phase's Markdown completion record gives exact location, source/schema identity, an availability check and retention/removal owner. Another checkout cannot assume `.build` exists. Keep required immutable predecessor inputs available until their reproducer is retired through the ledger. Historical code in Git is retrievable by its recorded revision; untracked binaries are not recoverable merely because a filename was written down.

## Closure

The phase and README remain open until all owned acceptance, critical mutation, resource/credential retirement and removal obligations are terminal. Exact absence covers only its declared authority/field; it is not an empty-account claim. Two clean cycles support the declared entry criterion, not permanent reliability. Preserve the actual load/fault schedule and practical scope of any soak claim.

The existing [manual AWS cleanup](../../documents/history/aws_cleanup_2026_11.md) is a hand-action record. It neither qualifies the old lifecycle nor proves future absence. No phase has current completion evidence solely from this Markdown adoption.
