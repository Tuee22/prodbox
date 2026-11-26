# Phase 1 Validation Evidence

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Phase 1 acceptance, mutation and owned-removal observations.
**Phase**: 1

> **Purpose**: Bind Phase 1 acceptance and mutation observations to tested inputs and preserve their limitations.

This report describes the historical run at `0747a33`. Phase 1 was
reopened. The current recovery, recreation, simultaneous-scope and
mutation dispositions are in the [active phase](../phase_01_cli_contexts_kind_and_evidence.md).

## Scope and identity

The scenarios ran on the single development host against its real Docker daemon and a throwaway kind cluster per run; no cloud account, Vault, domain or provider credential was used or read, and `test-secrets.dhall` was neither read nor copied. The public binary was built from the worktree on top of commit `0747a33`; its SHA-256 at the last gate was `0eac058bdbede23ed7c799061316d40c0469a692b1e28631c499c73f994a6039`. Per-run identity (source manifest digest, binary digest, kind tool and node-archive digests, boot id, operation id and absolute deadlines) is bound inside each stored report under `<project>/.build/scenario-evidence/<run>/` and validated by `validateStoredScenarioReport`; those directories are scratch outputs and are not retained here.

## Acceptance observations

| Case | Where observed | Independent observer | Adverse control |
|---|---|---|---|
| A01-01 | `test run phase-01` case 1 | kubectl and `docker inspect`, Docker listings, direct root reads | cleanup absence and retained host data read back after delete |
| A01-02 | case 2 | direct reads of a Pod-written marker before and after, node container ids, `history/` listing, static PV bound by name | the first node was removed through public delete before the second reconcile |
| A01-03 | case 3 (13 observations) | outer `docker network inspect`, a TCP listener counting decoy connections, content snapshots of victim roots, image list, project directory listings | foreign same-name network, ambient kubeconfig, symlinked/foreign/nested roots, wrong generation, unavailable image, cross-environment, same-port and same-name siblings |
| A01-04 | case 4 | real TCP connections from labelled and unlabelled client Pods under the pinned management policy | removing the policy restores the connection; an earlier manual run with the CNI stopped gave "not proven" |
| A01-05 | case 5 (6 observations) | kernel cgroup counters, API-server Pod status, quota accounting, root and Docker listings | one-CPU affinity refuses before work; over-limit Pod is OOMKilled; over-quota Pod refused |
| A01-06 | case 6 | the stored case-1 report | fabricated, missing, stale, wrong-scope and missing-report variants each rejected; untampered pair accepted |
| A01-07 | `test run phase-01-mutation` | a no-network container probed before use, label listing for cleanup | M01 and M02 Killed; survivor, invalid and timeout calibrations as expected |

All six scenario reports validated as `EvidenceChecksSatisfied` in the final run and Docker volume and network inventories were identical before and after it.

## Critical mutations

M00 (unmodified baseline): every case of `test run phase-01-mutation` first builds the unmodified snapshot in the isolated container and runs the designated test, which passed (a failed or unobservable baseline classifies the case Inconclusive); the full gate also passed unmodified (10,062 plus 935 tests). M01 (overlapping-root check weakened) was Killed by `context.rejects_root_alias` and M02 (missing-report check weakened) by `evidence.rejects_unbound_result`, each re-run after the M01 source pin changed. Calibration: a compiled change the designated test cannot see Survived, a non-compiling source was Invalid, and a 1 ns test timeout was Inconclusive; none of the last three is counted as a kill. No reviewed equivalence exclusion was needed.

## Defects found by the scenarios and repaired

Records of what the real runs found, each preserved in the phase file: a root nested inside another scope's retained root was accepted and written into; a refused reconcile could strand its root (neither public command could move on); a repeated delete was not idempotent; capacity admission ran after image, network and volume effects; the controller's host-port conflict surfaced only at node create; the dash build-status mask in the mutation executor; and several of my own fixture mistakes (a replacement that silently matched nothing, a foreign network masking later refusals, generation values equal to the real one, probe scripts using binaries the helper image lacks).

## Limitations

- Admission is a narrow local permission for explicit test identities; Authority admission, Vault, MinIO and the secret workers are Phase 2 and later, so the protection of those services by the management policy and any gate that refuses secret handling when enforcement is unproven are not exercised.
- The management policy is applied to a disposable observation namespace, not installed persistently.
- Port and name admission checks are point-in-time, not reservations; no registry of admitted scopes exists.
- Claims and observers share one runner process; case 6 validates in that process.
- The controller envelope is declared and measured once per run, not qualified over long durations.
- Volume directories under the retained root must be created by the operator: a kubelet-created (`DirectoryOrCreate`) directory is root-owned and blocks unprivileged removal of the root. Files written by containers are root-owned inside an operator-owned directory.
- Only one scenario can run per host because the controller unit name is fixed.

## Owned removals

L04 and L05 are closed for the scope their rows name: the new-install path (L05 "New-install host adapter and generated mounts", absence check "New installs have no RKE2 service dependency"; L04 "No new path selects ambient or overwrites production"). Replacement evidence: cases 2 and 3 (exact host data retained across recreation; ambient decoy unused; cross-environment, foreign, symlinked, nested and sibling roots refused) and a unit suite that scans every module under `src/Prodbox/Control/` and both Phase 1 runners (comments excluded) and finds no ambient `KUBECONFIG` or `DOCKER_HOST` read, no `systemctl`, no `rke2-server` or `/etc/rancher`. Inherited rows B020, B021, B039 and B055 were audited and closed as recorded in the phase file.

What this does not remove, and why that is a different row and not a gap here: the AWS-substrate harness that sets and restores the process-global `KUBECONFIG` (`TestValidation.hs`, `Infra/SubstrateKubectl.hs`), the home-cluster resolver that still lists the RKE2 kubeconfig path and an ambient fallback (`Infra/MinioBackend.hs`, used by `ControlPlane/LocalClient.hs` and `Lifecycle/Teardown/EphemeralKubectl.hs`), and the `CLI/Cluster.hs` family. The ledger gives these their own removers: L14 (Phase 8, "Rke2 bespoke cascade and old stack observation"), L16 (Phase 8, "TestRunner/TestValidation/old dispatch") and L18 (Phase 10, "RKE2 legacy readers"). They are original-install residue; per the phase contract they must not serve new ordinary work, which the scans and case 3 show they do not. This closure is a reading of the ledger's row scopes made here, not an operator ruling; if the rows were meant to cover the legacy routes, Phase 1 should be reopened.
