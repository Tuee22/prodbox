# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../AGENTS.md](../AGENTS.md),
[../documents/engineering/README.md](../documents/engineering/README.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[substrates.md](substrates.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
**Generated sections**: none

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Closure Status

> **Declarative-plan note (Standard D).** This section is a condensed milestone ledger, not a
> per-sprint changelog. The authoritative per-sprint closure detail lives in the phase documents
> ([phase-0](phase-0-planning-documentation.md) … [phase-8](phase-8-email-invite-auth.md)) and the
> cleanup history lives in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md); the
> live status is the [Phase Overview](#phase-overview) and [Current Plan Status](#current-plan-status)
> tables below. The dated blow-by-blow was consolidated here on review to keep the plan declarative.

**Current head state (2026-07-06).** All phases are ✅ `Done`/`Reclosed` on their code-owned
surfaces. The most recent work closed the **bootstrap readiness-race class** as unrepresentable
across both substrates (Sprints `1.56`, `3.23`, `4.43`, `7.31`): reconcile ordering is a pure
projection over a typed config-sourced component dependency/readiness graph, a step runs only behind
a barrier that exercises the exact dependency call path it uses (the deep registry→MinIO S3
edge-readiness gate before every image-mirror write), and the retry classifier treats
name-resolution failures as retryable. Home-substrate validation is green (unit 1216/1216,
`prodbox dev check` 0, CLI/env integration green); the live `prodbox test all --substrate aws` past
the EKS image-mirror step is the non-blocking Standard O live-proof axis (see
[Substrate Parity](#substrate-parity) and [substrates.md](substrates.md)).

### Milestone ledger

Each row is one dated reopen/closure milestone; the owning phase doc carries the per-sprint detail.

| Date | Milestone |
|------|-----------|
| 2026-07-06 | Bootstrap readiness-race class made unrepresentable — Sprints `1.56` (typed component dependency/readiness graph + `EffectDAG` lowering), `3.23` (graph-sourced chart edges, Percona `Available` gate), `4.43` (single `ReconcileStepId` table + deep registry→MinIO edge gate + retry-classifier fix), `7.31` (same deep gate on the AWS substrate). Phases 1/3/4/7 reclosed. |
| 2026-07-05 | Daemon-mediated post-bootstrap control-plane boundary — Sprints `2.29` (pre-Vault daemon loader + `POST /v1/bootstrap/vault/ensure`), `4.42` (root Vault lifecycle via the daemon, no host fallback), `5.14` (`daemon-bootstrap` validation), `7.30` (per-run Pulumi object-store via the daemon API). Phases 2/4/5/7 reclosed. |
| 2026-07-04 | Explicit resource guardrails — Sprints `1.55` (`capacity.resource_plan` schema), `3.22` (chart resource envelopes + namespace quotas), `4.41` (RKE2/kubelet reservation + systemd drop-in), `5.13` (`resource-guardrails` validation). Phases 1/3/4/5 reclosed. |
| 2026-07-03 | Pulsar broker transport + topic lifecycle (`3.21`/`4.35`), fail-closed spot-price gate (`7.27`), EKS VPC ownership hardening (`7.29`), static retained EBS PVs on EKS (`7.28`), `eks-volume-rebind` validation (`5.12`). |
| 2026-07-02 | Gateway/Orders + durable-event CBOR migration (`2.27`/`2.28`), substrate-typed placement + host-provider frame + test-EBS reaper (`4.37`/`4.38`/`4.40`), tiered-storage capacity + AWS quota preflight (`4.36`), test-topology command surface + `.test-data` isolation (`5.11`). |
| 2026-06-26 | **Home-substrate aggregate `prodbox test all` GREEN** — 18/18 named validations + both cabal suites, EKS cleanly destroyed. This is the live-infra proof satisfying the home-substrate `🧪 Live-proof: pending` axes across Phases 1–8. |
| 2026-06-16 | Vault-root + cluster-federation foundations closed on their code-owned surfaces — Sprints `1.35`–`1.38`, `2.26`, `3.19`/`3.20`, `4.29`–`4.33`. The master-seed HMAC derivation machinery is **removed** from the supported path (Sprint `3.19`). |
| 2026-06-15 | MinIO/Pulumi encryption finalized to **Model B** — prodbox object-level Vault-Transit envelope with whole-system zero-child-info framing (one generically-named bucket of opaque `objects/<hmac>.enc`, `prodbox-envelope-v2` hashed AAD, decrypt-to-scratch Pulumi interposition, Pulumi's own secrets provider dropped). Refines, does not reverse, the 2026-06-14 model; reopens no new phase. |
| 2026-06-14 | Secrets model **finalized to Vault-root + cluster federation** — Vault is the sole secrets/KMS/PKI root, a sealed Vault bricks the cluster (fail-closed), the master-seed HMAC derivation model is **retired** (not extended), and `FileSecret`/Secret-mounted plaintext Dhall is **removed**. Sprint `0.13` deleted `VAULT_REFACTOR.md` and added [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). |
| 2026-06-11 | Vault refactor Sprint `0.12` closed — [vault_doctrine.md](../documents/engineering/vault_doctrine.md) SSoT + documentation harmony. |
| 2026-06-09 | Design-intention review reopen — Sprints `0.9`/`0.10`, `1.29`–`1.32`, `2.24`/`2.25`, `3.15`/`3.16`, `4.26`/`4.27`, `5.6`, `7.12`/`7.13`; all landed. |
| 2026-06-07 | Single ZeroSSL ACME issuer (`zerossl-dns01`) + S3 cert retain-and-restore finalized — Sprints `7.11`/`4.24`/`8.7`. The earlier two-issuer/`IssuerClass` staging+production model was reverted to one ZeroSSL issuer. |
| 2026-06-05..09 | Live AWS-substrate parity proven for the then-canonical slice — Sprints `7.5`, `8.5`/`8.6`/`8.8` (NLB-target Route 53, delegated-subzone cleanup, per-run postflight teardown, OIDC redirect, `keycloak-invite` capture/link-follow on `aws.test.resolvefintech.com`, destructive lifecycle, `prodbox nuke` proof). |

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [substrates.md](substrates.md) | Authoritative inventory of substrates the canonical test suite runs against |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and public workload delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) | Phase 5: Canonical test suite — substrate-agnostic named validations |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Phase 7: AWS substrate foundations — onboarding, IAM, quota, and AWS substrate parity with the canonical suite |
| [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Phase 8: Operator-invited email authentication via Keycloak + AWS SES |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of cleanup/removal history and ownership |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated on the code-owned surface, and aligned in docs (a pending live-infra proof does not prevent `Done` — [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet **earlier-or-same-phase** sprint or **external** prerequisite — never a later phase and never a pending live-infra proof ([Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking)) | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |
| **Live-proof pending** | Code-owned surface `Done` and locally validated; a live-infra proof (live AWS / deployed cluster / unsealed Vault / operator credential) is outstanding. **Non-blocking** ([Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | 🧪 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass on the **code-owned surface** through the canonical `prodbox`
   surface (`prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env`).
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

Per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof), a
proof that requires live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an
operator-supplied credential) does **not** prevent `Done`; it is tracked as a distinct, non-blocking
`🧪 Live-proof: pending` note on the sprint. Per
[Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking), a `Blocked by`
entry may name only an earlier-or-same-phase sprint or an external prerequisite — never a later phase
or a higher-numbered sprint — and an incomplete later phase never reopens or blocks an earlier phase.

## Phase Overview

> **2026-06-26 live-proof update:** the home-substrate aggregate `prodbox test all` is **green**
> (18/18 validations + both cabal suites; see the Closure Status above and
> [00-overview.md](00-overview.md) Alignment Status). That run is the live-infra proof that satisfies
> the **home-substrate** `🧪 Live-proof: pending` axes referenced in the rows below across Phases
> 1–8 (config/secrets, gateway/DNS, charts, lifecycle, the canonical suite incl. `sealed-vault`, the
> AWS per-run resource cycles the home suite exercises, and `keycloak-invite`). Per
> [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof) these were
> already non-blocking; they are now proven. The `--substrate aws` aggregate stays a distinct axis
> ([substrates.md](substrates.md)).

| Phase | Name | Status | Document |
|-------|------|--------|----------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ **Done on owned surfaces** — planning + documentation topology; secrets model finalized to Vault-root + cluster federation (2026-06-14, Sprint `0.13`), documentation harmony machine-checked. Independent Validation + per-sprint detail: [phase-0-planning-documentation.md](phase-0-planning-documentation.md). | [phase-0-planning-documentation.md](phase-0-planning-documentation.md) |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ **Reclosed 2026-07-06** — Sprint `1.56` bootstrap-readiness config/DAG foundation; prior reclosures cover the three-tier config model, Vault-root `SecretRef`, and the capacity/host-provider/cluster-topology/test-topology schemas. Independent Validation + per-sprint detail: [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md). | [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ **Reclosed 2026-07-02** — Sprint `2.27`/`2.28` gateway/Orders/durable-event CBOR migration; prior cluster-federation custody (`2.26`) and the gateway-runtime/DNS/peer-transport surfaces through `2.25`. Independent Validation + per-sprint detail: [phase-2-gateway-dns.md](phase-2-gateway-dns.md). | [phase-2-gateway-dns.md](phase-2-gateway-dns.md) |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ **Reclosed 2026-07-06** — Sprint `3.23` graph-sourced chart edges + Percona `Available` gate; prior `3.22` resource envelopes, `3.21` Pulsar broker, `3.17`–`3.20` Vault chart-secrets. Independent Validation + per-sprint detail: [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md). | [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ **Reclosed 2026-07-06** — Sprint `4.43` single `ReconcileStepId` table + deep readiness gate; prior `4.42` daemon-mediated Vault lifecycle, `4.34`–`4.40` autoscaler/placement/EBS/topic surfaces, `4.29`–`4.33` Vault-before-MinIO + Model-B object-store. Some live-infra proofs remain non-blocking 🧪 axes. Independent Validation + per-sprint detail: [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md). | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| 5 | Canonical Test Suite | ✅ **Reclosed 2026-07-05** through Sprint `5.14` (`daemon-bootstrap`); prior `5.13` resource-guardrails, `5.12` eks-volume-rebind, `5.11` test-topology, `5.8` sealed-vault. 🧪 live-proof pending for destructive volume-rebind, resource-stress, and AWS-substrate parity rows ([substrates.md](substrates.md)). Independent Validation + per-sprint detail: [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md). | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ **Done on owned surfaces** — clean-room rerun + zero-Python handoff contract; an incomplete later phase never reopens or blocks it ([Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). Independent Validation: [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md). | [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) |
| 7 | AWS Substrate Foundations | ✅ **Reclosed 2026-07-06** — Sprint `7.31` AWS-substrate readiness-barrier parity; prior `7.30` daemon object-store, `7.27`–`7.29` spot/EBS/VPC, `7.19`–`7.26` disk-free unseal + config-model, `7.14`–`7.17` encrypted backend + Vault-only creds, `7.11`/`7.5` ACME + live AWS slice. 🧪 the live `prodbox test all --substrate aws` aggregate is the non-blocking axis ([substrates.md](substrates.md)). Independent Validation + per-sprint detail: [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md). | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ✅ **Reclosed 2026-06-14** — Vault-KV SMTP/OIDC secrets consumed via Vault Kubernetes auth, a sealed Vault bricks the invite path (Sprint `8.9`); Sprints `8.1`–`8.8` closed live (home + AWS `keycloak-invite`, OIDC claims verified, `prodbox nuke` proof). 🧪 the both-substrate live invite exercise is the non-blocking axis. Independent Validation + per-sprint detail: [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md). | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) |

**Status interpretation.** The finalized architecture: secrets are **Vault-root + cluster
federation** (2026-06-14 — the master-seed HMAC derivation model is retired, `FileSecret` /
Secret-mounted plaintext Dhall removed), and MinIO/Pulumi state uses the **Model-B** object-level
Vault-Transit envelope with whole-system zero-child-info framing (2026-06-15). Both *refined* rather
than reversed prior models and reopened no new phase. The dated reopen/closure history is
consolidated in the [Closure Status](#closure-status) milestone ledger above; per-sprint detail is in
the phase documents.

## Substrate Parity

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates,
with no fallback between them (see
[Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)).
A complete canonical-suite proof requires both the home local and AWS substrate rows below to
land independently against their own real infrastructure. The authoritative substrate
inventory is [substrates.md](substrates.md); this section is the live tracker for substrate
parity. The authoritative AWS resource inventory and per-resource lifecycle class (auto-managed
per-run stacks vs long-lived cross-substrate shared infrastructure) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Suite parity | Phase ownership |
|-----------|-----------|----------|--------------|-----------------|
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | `prodbox cluster delete --yes` (`--cascade` also destroys per-run AWS stacks) | ✅ Full canonical suite, including real ZeroSSL, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com`. Current canonical-suite membership is defined in `src/Prodbox/TestPlan.hs`; substrate-specific live-proof axes are tracked in [substrates.md](substrates.md). | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes` | 🔄 **Aggregate parity in progress** — ✅ for the then-canonical AWS slice (Phase 7-owned AWS substrate parity proved live June 5-9, 2026: public DNS, chart validations, admin routes, `keycloak-invite`, destructive lifecycle, and per-run postflight cleanup); the full `prodbox test all --substrate aws` aggregate past the EKS image-mirror step remains a non-blocking Standard O live-proof axis. Current canonical-suite membership is defined in `src/Prodbox/TestPlan.hs`; any AWS live proofs for later-added validations are tracked only in [substrates.md](substrates.md)'s per-validation coverage table as non-blocking Standard O axes. | [phase-7-aws-substrate-foundations.md → Sprint 7.5](phase-7-aws-substrate-foundations.md) |

## Current Plan Status

The development plan remains authoritative and the worktree is fully closed against every phase's
code-owned scope (see the [Closure Status](#closure-status) milestone ledger and the
[Phase Overview](#phase-overview) above). The secrets model is finalized to Vault-root + cluster
federation and MinIO/Pulumi state to the Model-B object envelope; later finalized-model live-infra
work (Sprint `5.8` AWS live-proof, `7.14`–`7.16`, `8.9`) is tracked on its owning phase's surface and
never blocks or reopens an earlier phase per
[Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking). The following
implemented baseline surfaces remain current on the supported path:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding the executable-sibling Tier-0 `prodbox.dhall` in-process through the native `dhall`
  library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, executable-sibling config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- Every runtime path by which elevated/admin AWS power enters prodbox — `config setup`, `aws setup`,
  the native IAM harness, the long-lived `aws-ses` stack ops, and `prodbox nuke` — acquires the
  ephemeral elevated credential through the interactive `SecretRef.Prompt`, uses it once, and
  discards it. The `aws_admin_for_test_simulation.*` fixture is a test-harness-only `TestPlaintext`
  fixture in `test-secrets.dhall` whose sole purpose is to simulate that operator prompt
  non-interactively; it is never read by a production binary and never stored in
  `prodbox.dhall` or Vault.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`,
  and `prodbox test all` through one shared suite-level IAM harness that provisions temporary
  operational `aws.*` before prerequisite-driven AWS validation begins, destroys validation-owned
  per-run stacks when the targeted suite may provision them, and clears those credentials again
  before the suite returns.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `rke2 reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The shared IAM harness deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from the
  `test-secrets.dhall` `aws_admin_for_test_simulation.*` fixture (simulating the operator's
  interactive admin-credential prompt) because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from Vault KV before
  returning even on later prerequisite failure.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  Vault/Tier-0 credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.12.4`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target remains Haskell-owned and Harbor-first: Harbor plus
  Harbor's storage backend bootstrap from public registries, after which required public images
  and custom images are present in Harbor before later Helm deployments proceed.
- The Harbor mirror path retries transient Harbor publication failures on the same candidate and
  then falls through to alternate configured upstreams when publication still fails after manifest
  inspection, with `mirror.gcr.io` fallbacks now covering the Docker Hub-hosted Percona and Envoy
  images used by the supported lifecycle.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on native-host-architecture image
  publication only: `amd64` hosts publish `amd64`, `arm64` hosts publish `arm64`, and no
  supported lifecycle path uses `docker buildx` or cross-arch emulation.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox charts ...` runtime now rejects internal `keycloak-postgres` and `redis`
  dependency releases directly and keeps those names reachable only through their owning root-
  chart orchestration.
- The public `prodbox aws stack ...` surface covers the AWS substrate stacks under
  `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`.
  Non-secret validation inputs are synchronized through stack config, while AWS provider
  credentials resolve through Vault/Tier-0 references and the Haskell-owned subprocess environment.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- The current gateway runtime surface is Haskell-owned and code-backed in `src/Prodbox/Gateway.hs`,
  `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs`: config generation, heartbeat recording, in-memory ownership
  projection, DNS-write gating, the bounded HTTP `/v1/state` observability payload, HMAC event
  signing, Orders-backed gateway-interval validation, peer-transport gossip with commit-log
  replication through `peerListenerLoop` and `peerDialerLoop`, runtime claim/yield emission under
  the `canWriteDns` predicate, bounded-clock-skew enforcement keyed off
  `daemonMaxClockSkewSeconds`, and monotonic Orders-version coordination across the mesh are all
  implemented there today.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox dev tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox aws stack ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Harbor, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports the
  single union runtime image (`prodbox-runtime`, shared by the gateway daemon and the api/websocket
  workloads) during `rke2 reconcile`.
- The supported public-edge auth doctrine now makes the carrier and key-discovery boundary
  explicit: JWT-only API routes validate request-carried bearer tokens locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys, Envoy-managed browser auth returns
  through the edge redirect and cookie or session path, and direct-OIDC workloads keep their
  carrier or session state workload-owned.
- Keycloak availability now stays explicit in the plan: it is required for new logins, refresh
  flows, and later JWKS refresh, but the steady-state JWT request path does not synchronously call
  Keycloak or Redis while Envoy still has cached signing keys and the presented tokens remain
  valid.
- The current supported transport boundary now stays explicit in the plan: public TLS terminates at
  Envoy for the shipped `/vscode`, `/api`, and `/ws` routes on
  `test.resolvefintech.com`, while backend TLS or mTLS is outside the supported
  chart-workload contract unless a later doctrine revision expands that path.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host route catalog and issuer derivation
  consumed by lifecycle, DNS, chart, host-diagnostic, and native validation surfaces, keeping
  `/auth`, `/vscode`, `/api`, `/ws`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus the governed public-edge, gateway, chart-platform, registry, and testing
  doctrine docs now describe that same supported route catalog and command surface, and the
  earlier Phase `2`, `3`, and `4` implementation gaps are closed in the same code-backed paths.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `workload.mode = Api \| Websocket` runtime selector
  (sourced today from the `PRODBOX_WORKLOAD_MODE` env var; Sprint 3.14 migrates this to the
  mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md)),
  JWT-only API delivery, Redis-backed shared-state continuity on the WebSocket route, workload-
  managed OIDC bootstrap, real `/ws` upgrade handling, and settings-backed workload scaling.
- The current WebSocket doctrine now states that one upgraded connection remains pinned to one
  selected backend pod until disconnect, reconnect-safe state must live outside the pod, and the
  implemented runtime now closes on readiness-based drain plus revocation-driven reconnect
  behavior on the real `/ws` path.
- Redis now stays explicit as shared application state for the current WebSocket surface and any
  later explicit external rate-limit service, but the current supported worktree still does not
  ship a standalone rate-limit-service workload or validation path.
- `src/Prodbox/Host.hs` and `src/Prodbox/TestValidation.hs` now classify and validate the
  current Keycloak identity, `vscode`, `api`, `websocket`, Harbor, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox dev check`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- The final Phase `6` destructive rerun and handoff validation are closed on that aggregate rerun
  contract and the supported postflight restore path.
- The legacy ledger preserves completed cleanup history. After the doctrine-adoption reopen
  closure the `Pending Removal` section was empty; the May 23, 2026 reopen of Phases `2`, `3`,
  and `4` (Sprints `2.17`, `2.18`, `2.19`, `3.13`, `4.16`, `4.17`, `4.18`) reintroduced
  doctrine-aligned residue rows (file-existence stack predicates, the `.prodbox-state/` host-side
  cache, the host-side chart-secret cache plus `.patroni-anchor-volume` marker, and the remaining
  `curl` shell-outs in `src/Prodbox/TestValidation.hs`, `Workload.hs`, and `CLI/Rke2.hs`), each
  scoped to its owning sprint.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   AWS stack orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from the executable-sibling
   Tier-0 `prodbox.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` and public `prodbox aws ...` paths can bootstrap all required AWS
   credentials from scratch using temporary admin credentials entered interactively by the
   operator.
5. `aws_admin_for_test_simulation.*` lives only in the test-harness-only `test-secrets.dhall`
   (`TestPlaintext`), never in `prodbox.dhall` or Vault, and its sole purpose is to
   simulate the operator's interactive admin-credential prompt for suite-driven destructive
   validation and long-lived stack / `prodbox nuke` flows. Public `config setup`, public
   `aws ...`, the long-lived `aws-ses` stack ops, and `prodbox nuke` all acquire the ephemeral
   elevated credential through the interactive `SecretRef.Prompt` — there is no production
   config-backed admin path.
6. `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
   validation harness that deletes any pre-existing dedicated `prodbox` IAM user and all of that
   user's access keys before provisioning, uses any pre-existing `aws.*` credentials only to
   discover and delete the IAM user associated with those credentials, proves STS-federated
   operational credentials with a compact AWS-validation session policy, waits for the dedicated
   IAM-user credentials to pass STS and repeated Route 53 hosted-zone probes, materializes
   IAM-user operational `aws.*` only from the `test-secrets.dhall` `aws_admin_for_test_simulation.*`
   fixture to simulate the interactive admin-credential prompt of the public CLI workflow because
   cert-manager Route 53 DNS01 credentials do not support
   an STS session-token field, destroys validation-owned per-run stacks when the targeted suite may
   provision them, and clears operational `aws.*` from Vault KV before returning so
   no test-created dedicated IAM user or key survives.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.12.4`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox dev check` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close on the implemented bounded HTTP `/v1/state` observability payload, the
    Orders-backed gateway-interval relationships enforced by `src/Prodbox/Gateway/Types.hs`, and the current
    correspondence notes in `documents/engineering/tla_modelling_assumptions.md`.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox host public-edge`, `prodbox test integration charts-vscode`,
    `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and the
    named admin-route validations close on Gateway, `HTTPRoute`, auth policy, certificate, and
    one Route 53 record rather than `IngressClass`, `Ingress`, or per-FQDN state.
17. Supported config, onboarding, lifecycle, and validation surfaces remove `example.com`
    entirely and do not accept or emit placeholder public domains.
18. MetalLB supports both the L2 implementation path and a config-selected BGP implementation path
    on the supported self-managed cluster surface.
19. Envoy validates Keycloak-issued JWTs locally and applies route-level RBAC for application and
    admin routes. Issuer, audience, path-claim requirements, bearer-token carriers, browser
    return paths, and JWKS discovery or refresh ownership remain explicit.
20. Redis appears only as repo-owned app-level shared state for supported realtime or rate-limit
    workloads; it is never part of Envoy JWT validation, and the current supported worktree does
    not yet ship a standalone external rate-limit-service surface.
21. Supported WebSocket workloads authenticate at connection setup on the shared-host `/ws`
    route, keep reconnect-safe state outside the pod, keep each live upgraded connection pinned
    to one backend pod until disconnect, define token-expiry and authorization-change behavior
    explicitly, leave per-message authorization to the workload when messages need finer-grained
    permissions than the edge can enforce, scale horizontally behind Envoy, use readiness-based
    drain before pod exit, and add named validations for reconnect, connection-pinning,
    token-expiry handling, authorization-change assumptions, readiness-based drain,
    per-message authorization ownership, and shared-state assumptions.
22. Keycloak-backed public workloads stay proxy-aware behind Envoy on the shared hostname rather
    than on a dedicated identity host. Keycloak availability gates login, refresh, and later
    JWKS refresh, while cached signing keys and unexpired tokens keep the steady-state JWT hot
    path local to Envoy.
23. Public TLS terminates at Envoy on the supported path, and one certificate covers
    `test.resolvefintech.com`. Backend TLS or mTLS is not part of the current supported workload
    contract unless a later doctrine revision makes that backend transport explicit.
24. Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
    storage backend during bootstrap.
25. Every later supported Helm deployment obtains its images from Harbor.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    Harbor after Harbor bootstrap and before those later deployments.
27. Supported custom-image builds and Harbor publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox aws stack ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. The strongest clean-room rerun passes from full local delete through final AWS teardown using
    the Haskell stack.
33. [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) contains no unresolved
    cleanup.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only, the append-only commit log replicates between nodes as the canonical heartbeat-and-event
    transport, and `/v1/state` exposes per-peer transport health for operator inspection.
36. The gateway daemon emits signed `Claim` and `Yield` events on owner transitions and gates
    Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
    `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log rather than only
    on the model, and a stale owner cannot reclaim DNS write authority without first observing its
    own yield being superseded by a fresh claim.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer events from a
    peer presenting an older Orders version, a new Orders version propagates through commit-log
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
