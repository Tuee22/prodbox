# Phase 2 Validation Evidence

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Phase 2 acceptance, mutation and owned-removal observations.
**Phase**: 2

> **Purpose**: Bind Phase 2 acceptance and mutation observations to tested inputs and preserve their limitations.

## Scope and identity

The scenarios ran on the single development host against its real Docker daemon and a throwaway kind cluster per run, with Phase 1's confined worker and broker. No cloud account, domain, registry or provider credential was used or read, and `test-secrets.dhall` was neither read nor modified. Services run from locally imported artifacts: a source-built MinIO and client, HashiCorp Vault 1.18.3 and a locally built Bootstrap Broker runtime image, all with pull policy `Never`. Secret values never appear in an observation or this record.

## Acceptance observations

| Case | Where observed | Independent observer | Adverse control |
|---|---|---|---|
| A02-01 | `test run phase-02` case 1 (nine observations) | kubectl pod readiness, Vault's health endpoint read through the API-server proxy, a scoped reader reading the MinIO object, the stored bundle's fields, the Broker's readiness route | no registry workload exists and every container's pull policy is `Never` (case 6); the stored object carries no root-token field |
| A02-02 | case 2 | Vault health while sealed and after unseal, the cluster id before and after, a marker read after the restart | a second unlock does not re-initialize |
| A02-03 | case 3 (five observations) | Vault health before and after, a prompt exercised on a real pseudo-terminal with a typed key | no input answers needs-input and changes nothing; a wrong key is refused; production policy is refused before any material is read; unlock succeeds with MinIO deleted |
| A02-04 | cases 4 and 8, and `test run phase-02-broker` cases 1 to 4 | Vault health, object presence read through the reader, status output per component | wrong key, missing object, generation mismatch, interrupted upload (continued from the private pending record), MinIO outage, Broker outage, wrong operator password |
| A02-05 | cases 5, 6 and 7 | the cluster id and marker across a full recreation, eight concurrent workers' read-back, Pod restart counts and declared limits, throwaway client Pods with and without the management label | the unlabelled client is refused; a corrupt backup is refused; restore keeps the replaced data |

All eight reports of `test run phase-02` and the five of `test run phase-02-broker` validated as `EvidenceChecksSatisfied` in the final runs, and Docker container, volume and network inventories were identical before and after each.

## Critical mutations

M03 has two source-bound variants of `Control/Unlock.hs`, M03a (production policy) and M03b (Vault incarnation). The mutation catalog was re-run after every change to that file, most recently against source digest `29374f1c...f5f07`: M01, M02, M03a and M03b Killed on their intended assertions, and the survivor, invalid-build and timeout controls Survived, Invalid and Inconclusive as expected. The unmodified baseline builds and passes first.

## Defects found by the scenarios and repaired

Preserved in the phase file: `mc pipe` of a stream of unknown length buffered a part-sized allocation and OOM-killed the client container (found only by logging the process's command line at its peak); the unlock bundle carried the initial root token (now a limited client token, root revoked); Vault ran as the default ServiceAccount and could not validate the Broker's tokens; the Broker's stale pooled connection to MinIO; several Broker deployment preconditions; and fixture mistakes in the harness itself, including observation lists shorter than their claim lists.

## Limitations

- The Broker's post-unseal handoff reconcile is not wired: its target is the control-plane Authority, which Phase 3 delivers.
- The MinIO root credential is a compiled bootstrap-floor constant because the Broker's store code requires it.
- The Broker runtime image is built locally from this binary and host gnupg tools and is not reproducible.
- The pseudo-terminal check needs `/usr/bin/python3`; the right-key path is exercised through standard input only.
- A process that dies after the unlock-object upload but before the client token is minted loses the root token; a later unlock unseals but reports no client token.
- Claims and observers share one runner process.

## Owned removals

L06 (no management cold path pulls from a dependent registry) and L07 (direct degraded status and distinct unlock policies, no implicit test-policy production fallback) are closed for the new bootstrap path by the observations above. The inherited rows B026, B041, B053 and B054 are closed for the ordinary path; their original-install residuals are enumerated under ledger row L18.
