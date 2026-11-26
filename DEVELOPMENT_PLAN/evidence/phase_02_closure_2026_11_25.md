# Phase 2 Validation Evidence, 2026-11-25

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Phase 2 evidence for real bootstrap, retained-state recovery, cleanup and critical mutations.
**Phase**: 2

> **Purpose**: Identify the real test runs, their independent observations and the retained records needed for verification.

## Public bootstrap and recovery

The fresh reader-repair run used operator SHA-256
`949bc98a9bd292ad2c3eb4aad91501edeb945af624f09f730e1c1f89776216b5`
and full source manifest SHA-256
`9a5a06948b569e47840874cd234d089f171060690fd24e6049da4630eeb7faef`.
It enrolled test scope `run-6aa4721f444f4ce20916c72c64b13fae` and generation
`5b797c872e48a09d30f1828afece110a` through the public setup and artifact
import commands, then ran the operator's `test run phase-02` against the
selected config. The config projection and artifact bindings are included
in all eight reports under
`.build/scenario-evidence/fda9580c961d88c09f4d93a5fa4debb1/`.
All eight report successful primary work, confirmed cleanup and satisfied
evidence checks. The public process exited zero at 15:28 America/Toronto.

| Case | Independent observation |
|---|---|
| A02-01 | Actual MinIO, Vault and Broker Pods were ready from pinned local images. Vault initialized once and an authenticated secret write and read succeeded. The scoped MinIO reader could read its object and was refused for writes and listing. |
| A02-02 | The replacement Vault Pod was initialized and sealed over the original storage. The same Vault identity and marker returned after self-unseal. |
| A02-03 | A correct key supplied through the hidden terminal unsealed Vault while MinIO was down. Missing and wrong input were refused, and protected production rejected the test policy. |
| A02-04 | Denied access to an existing MinIO object left Vault uninitialized and the object intact. Wrong input, missing bundle, generation mismatch, outages and interrupted upload each produced directly observed results. The resumed upload retired its private pending file. |
| A02-05 | Two real workers were Ready together with Guaranteed QoS and pull policy `Never`. Each completed its put/read. Real policy traffic exercised the allow and deny cases, and Vault identity and secret data survived same-root kind recreation. |
| A02-06 | The same-size backup change was refused before replacing live data. The unmodified backup restored and produced an authenticated round trip on the same Vault identity. The previous data and unverified legacy format were retained as specified. |

Each one-shot worker requested and was limited to 250m CPU, 256 MiB RAM
and 256 MiB ephemeral storage. The runs exercised one kind node at a time
per test scope, with two concurrent test workers and deliberate Vault,
MinIO and Broker outages. The primary and cleanup deadlines were 40 and
50 minutes from scenario start, and the budget recorded zero AWS spend.
Logs are `.build/phase2-reader-policy-fresh-20261125.log`,
`.build/phase2-reader-policy-fresh-independent-20261125.log` and
`.build/phase2-reader-policy-fresh-worker-envelope-20261125.log`.

The second clean public cycle used the same operator on scope
`run-634cff211cdaf72bd00f509646be3281`, generation
`0aa488558f78900d613549335cc04612`, with source manifest
`2138cd9aad8f0c52e37778331685bb1e1b9a1526b56b42960ca7344c64fb3227`.
All eight reports in `.build/scenario-evidence/66fc71c7cbd628e28592a723376002fb/`
passed, and the public command exited zero at 15:51 America/Toronto.
Both exact kind operations reached readiness, the replacement reused
the verified retained reader and the original secret survived the
recreation. Independent runtime reads confirmed exact node, volume and
network absence after supported teardown. Logs are
`.build/phase2-reader-policy-repeat-20261125.log`,
`.build/phase2-reader-policy-repeat-independent-20261125.log` and
`.build/phase2-reader-policy-repeat-worker-envelope-20261125.log`.
These two cycles cover the stated local failure schedule and resource
envelope.

A separate public Broker run exited zero with five reports in
`.build/scenario-evidence/0683d9a6a00598f36ae96282a1340392/`. It proved
real initialization and custody, refused absent input and the wrong
password, waited for the 300-second fence, then unsealed the same Vault
after Pod replacement and verified actual role allow and deny behavior.
Its binary and source digests, exact operation and cleanup are recorded
in the phase file. The service-interruption canary proved that a killed
service caller left an exact retained attempt, a retry refused before
new effects, and the original kind operation could be settled and
recreated without losing the attempt. Logs begin
`.build/phase2-broker-real-20261125.log` and
`.build/phase2-service-interruption-retry-20261125.log`. [Phase 2 record](../phase_02_vault_minio_and_bootstrap.md)

## Critical mutations

- M03a qualified on the current unlock source in campaign `1860706730629614`
  with only `bootstrap.production_rejects_test_unlock` failing.
- M03b qualified on the current unlock source in campaign `1858395770368435`
  with only `bootstrap.preserves_vault_incarnation` failing.
- M03c qualified in campaign `1850537365253977` with only
  `backup.rejects_same_size_corruption` failing. Its pinned backup source
  and selected assertion remain the current ones.
- The affected M01 cases qualified on their updated source pins.
  `M01-unknown-recreate`, `M01-foreign-namespace-cleanup` and
  `M01-replaced-namespace` each failed its intended assertion. Independent
  observers confirmed exact worker and quota volume absence and
  workspace retirement for each case. [Phase 2 record](../phase_02_vault_minio_and_bootstrap.md)

The three M03 executions each retired eight exact Docker workers and
their quota volume. Independent absence checks used the original daemon
and bridge as positive controls and verified both case workspace paths
absent. The prior inconclusive M03a result remains attributable to its
failed baseline and retained source snapshot.

## Canonical gate

The installed reader-repair operator exited zero from
`./.build/prodbox dev check` at 15:33 America/Toronto with 11,218 tests
passing. Source policy, formatting, lint, the warning-clean build and
cumulative mutation-binding checks passed. The log is
`.build/phase2-reader-canary-canonical-20261125.log`.

## Cleanup and availability

Supported teardown removed the exact node, node volume and network for
both current operations, under the same daemon and bridge. It preserved
the host data required for recovery. Once the scopes were settled, the
standing local cleanup authorization covered disposal of the test-only
Vault, MinIO, backup and reader payloads. Those hand actions are reported
separately in `.build/phase2-reader-policy-fresh-custody-hand-action-20261125.log`
`.build/phase2-reader-policy-repeat-custody-hand-action-20261125.log` and
`.build/phase2-reader-regression-custody-hand-action-20261125.log`. Owned
rows L06, L07, B026, B041, B053 and B054 are Removed. [Legacy ledger](../legacy_tracking_for_deletion.md)

Failed results, case journals and retained source identities remain
available under their recorded scopes. The referenced `.build` artifacts
were available on the development host. Their use and retirement remain
governed by the repository evidence and removal ledgers. [Evidence contract](README.md), [Legacy ledger](../legacy_tracking_for_deletion.md)
