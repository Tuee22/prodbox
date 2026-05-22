# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[the engineering doctrine docs](../documents/engineering/README.md)

> **Purpose**: Provide the target architecture, current baseline, clean-room sequence, and hard
> constraints for the Haskell rewrite of `prodbox`.

## Vision

Build a clean-room Haskell `prodbox` repository with:

1. One explicit `prodbox` CLI surface implemented in Haskell.
2. One supported local lifecycle operator environment: `Ubuntu 24.04 LTS` with systemd.
3. One host-owned `prodbox rke2 reconcile|delete [--yes|--cascade [--yes]|--allow-pulumi-residue [--yes]]|status|start|stop|restart|logs` surface for
   the local RKE2 cluster, plus the operator-only `prodbox nuke` total-teardown command that
   refuses non-TTY contexts and requires the typed-confirmation literal `NUKE EVERYTHING`.
4. One canonical test suite (the named-validation set in `src/Prodbox/TestValidation.hs`) that
   runs against substrates rather than against separate home-cluster and AWS validation
   surfaces. Substrates today are the home local RKE2 cluster on the operator host and the AWS
   substrate composed of the disposable Pulumi stacks `aws-eks-test` (EKS cluster + node group)
   and `aws-test` (three `Ubuntu 24.04 LTS` EC2 instances across separate AZs for HA-RKE2). The
   authoritative substrate inventory is [substrates.md](substrates.md).
5. One operator-authored repository-root `prodbox-config.dhall` as the single configuration
   source, decoded directly into Haskell types with `prodbox-config-types.dhall` as the shared
   schema and no generated JSON artifact on the supported path.
6. One host build root `.build/` with the operator-facing binary at `.build/prodbox`, produced by
   the canonical `cabal build --builddir=.build exe:prodbox` invocation followed by a copy step
   that places the binary at the root of `.build/`.
7. One container build root `/opt/build`, owned only by Dockerfiles under `docker/`.
8. One repository-owned custom-image doctrine: every custom Dockerfile needing Haskell builds is
   single-stage from `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not
   create symlinked Haskell tool shims; the supported public edge does not depend on a
   repository-owned nginx auth-proxy image.
9. One Harbor-first steady-state registry doctrine: direct public-registry pulls are permitted
   only for Harbor and Harbor's storage backend during bootstrap, and every later supported Helm
   deployment pulls from Harbor.
10. One idempotent post-bootstrap image-reconcile path: after Harbor is healthy and externally
    serving, `prodbox` ensures required public images and all custom images are present in Harbor
    before later deployment.
11. One native-architecture container-build doctrine: `amd64` hosts build `amd64` images, and
    `arm64` hosts build `arm64` images.
12. Native `arm64` container builds work on native `arm64` Docker daemons, while cross-arch
    builds, `docker buildx`, and mixed-arch clusters are unsupported.
13. One local-cluster-first Pulumi backend model: the local RKE2 cluster runs MinIO and stores AWS
    test-stack state in the dedicated bucket `prodbox-test-pulumi-backends`.
14. One in-cluster Haskell gateway runtime with config generation, bounded HTTP `/v1/state`
    observability, heartbeat recording, in-memory ownership projection, DNS-write gating,
    Orders-backed interval validation, HMAC-signed event state, peer-transport gossip with
    commit-log replication, runtime claim/yield emission under the `CanWriteDns` gate,
    operator-verifiable bounded-clock-skew enforcement through the supported-host NTP gate and
    `/v1/state` skew reporting, and atomic Orders-promotion coordination keyed off the monotonic
    `orders_version_utc` field.
15. One self-managed public-edge doctrine where MetalLB exposes Envoy Gateway, Kubernetes Gateway
    API owns Layer 7 routes, cert-manager owns listener TLS, Keycloak remains the identity
    provider, every externally reachable app or dashboard lives under the single hostname
    `test.resolvefintech.com`, Envoy enforces Keycloak-backed JWT auth and RBAC on explicit path
    prefixes such as `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths, and the
    steady-state request path does not synchronously depend on Keycloak or Redis. Port `80`
    exists only as an HTTP-to-HTTPS redirect into the same shared-host path model.
16. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
17. One retained repo-local state root under `.prodbox-state/`, including namespace-local
    chart state under `.prodbox-state/<namespace>/`, AWS stack snapshots under
    `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the HA-RKE2 validation
    SSH key under `.prodbox-state/aws-test/`.
18. One PostgreSQL doctrine for Helm-managed application data: every supported PostgreSQL
    deployment is external, Percona-operator-backed Patroni HA with exactly three PostgreSQL
    replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.
19. One supported public workload catalog comprising the cluster-backed `vscode` browser route, a
    JWT-protected API route, a WebSocket route, and path-routed operational dashboards such as
    Harbor and MinIO, all on the same public hostname.
20. One explicit single-host routing model for the public edge:
    `https://test.resolvefintech.com/<service-path>`, with one public DNS record, one public
    certificate, a port `80` redirect to the HTTPS URL, and no dedicated identity, browser-app,
    API, or WebSocket hostnames.
21. One repo-owned Redis workload path for supported realtime workloads and any later explicit
    external rate-limit service, only as shared application state and never as an Envoy JWT cache.
22. One explicit public-edge transport boundary where public TLS terminates at Envoy, backend HTTP
    remains the current supported workload default, and backend TLS or mTLS requires later
    explicit doctrine ownership.
23. One supported WebSocket connection-lifetime doctrine: auth at connection setup, one live
    upgraded connection pinned to one backend pod until disconnect, reconnect-safe state outside
    the pod, and readiness-based drain before pod exit.
24. One canonical test suite, expressed through named validation commands, with each validation
    described as substrate-agnostic suite content (no substrate-conditional branches in the
    validation logic) and exercised per substrate independently — there is no silent fallback
    between substrates, and a complete canonical-suite proof requires both supported substrates
    to land their own run.
25. One explicit ledger for compatibility or cleanup history that preserves completed removals and
    closes with zero pending supported-path residue.
26. Pulumi retained for true IaC surfaces such as AWS substrate resources, with no supported
    Python Pulumi program and no supported local-cluster public operator flow.

## Test Substrates

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates.
A substrate is an environment that, for the lifetime of a suite run, stands up the same set of
DNS records, TLS certificates, ingress, services, and workload charts; provides the
prerequisites declared in `src/Prodbox/Prerequisite.hs`; and is torn down on suite exit. The
authoritative substrate inventory is [substrates.md](substrates.md).

Substrate selection is total. Each per-substrate run targets exactly one substrate, consumes
only that substrate's operator-supplied config, and fails fast if any required substrate config
is missing. There is no silent fallback to the other substrate's values. A canonical-suite
proof is complete only when both substrate runs have landed. See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback).

The test harness is the **exclusive owner** of every AWS resource any `prodbox` flow creates
or destroys. The authoritative AWS resource inventory and per-resource lifecycle class
(auto-managed per-run stacks vs long-lived cross-substrate shared infrastructure that is
retained by design) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Suite parity today |
|-----------|-----------|----------|--------------------|
| Home local | `prodbox rke2 reconcile` + `prodbox charts deploy ...` | `prodbox rke2 delete --yes` | ✅ Full canonical suite, including real Let's Encrypt, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com` |
| AWS | `prodbox pulumi eks-resources` + `prodbox pulumi aws-subzone-resources` + `prodbox pulumi test-resources` | `prodbox pulumi aws-subzone-destroy --yes` + `prodbox pulumi eks-destroy --yes` + `prodbox pulumi test-destroy --yes` | 🔄 Provisioning + SSH reachability only; parity sprint tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |

Phase ownership separates suite content (which lives in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)) from substrate
provision/teardown and substrate foundations. No phase may own a substrate-specific validation:
validations are suite content and run against every substrate that satisfies their declared
prerequisites.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS substrate provisioning foundations, and the config contract closes on one canonical public hostname with no `example.com` residue |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, Harbor-backed gateway packaging, and the single-record Route 53 ownership contract close on the Haskell stack under the same `ubuntu:24.04` plus `ghcup` toolchain doctrine |
| 3 | Haskell Chart Platform and Public Workload Delivery | Chart orchestration, retained storage, Harbor-backed browser/API/WebSocket delivery, path-routed admin delivery, Keycloak-backed Envoy auth and RBAC, Redis-backed realtime state, and the Percona-operator-backed Patroni PostgreSQL doctrine close on the Haskell stack |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Home substrate lifecycle parity closes, Harbor bootstrap narrows to Harbor plus its storage backend, bootstrap DNS or certificate issuance collapse to the one-host doctrine, broad local-cluster Pulumi ownership is removed, and Python residue is removed |
| 5 | Canonical Test Suite | The substrate-agnostic named validation set in `src/Prodbox/TestValidation.hs` closes on one canonical suite with explicit prerequisites; suite content includes public-edge proofs (real TLS, OIDC, WebSocket) that run against whichever substrate is active |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun contract closes against every declared substrate in [substrates.md](substrates.md) with no supported Python dependency and no surviving single-host public-edge cleanup in the ledger |
| 7 | AWS Substrate Foundations | AWS substrate provisioning/teardown, AWS IAM and quota foundations, interactive onboarding, and the AWS-substrate parity sprint that brings the AWS substrate to canonical-suite parity with the home substrate close on Haskell-only paths, with `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of the ephemeral prompt input |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | Keycloak switches to operator-invited, email-verified auth via AWS SES; shared SES infrastructure (sending identity, receive subdomain, S3 capture bucket) is provisioned cross-substrate; `prodbox users invite|list|revoke` joins the public command surface; `ValidationKeycloakInvite` joins the canonical suite and runs against every substrate |

## Alignment Status

Phase `0` reopened through Sprints `0.2`–`0.7` to adopt
[the engineering doctrine docs](../documents/engineering/README.md) as the canonical CLI doctrine, align the
governed docs and plan suite with that doctrine, schedule every currently known code-level
adoption gap onto explicit downstream sprints, and (Sprint `0.7`) add the LLM/automation
guardrails on the operator-interactive command surface so every prompt-driven entry point
refuses to run on a non-TTY stdin and points the caller at the automation equivalent. That
planning and documentation work is now `Done`. Phases `1` through `4` were **reopened** on the scheduled implementation work and have
now reclosed: Sprint 0.3 extended the doctrine-adoption scope with the residual items surfaced
by the May 2026 doctrine-vs-plan audit, and Sprint 0.4 extended it again with the residual items
surfaced by the May 12, 2026 round-3 doctrine-vs-plan audit, including one new Phase `1`
sprint (1.27) plus deliverable extensions to existing planned Phase `1`, Phase `2`, Phase
`3`, and Phase `4` sprints, per
[development_plan_standards.md](development_plan_standards.md) standards rule L. Sprint 0.5
reopened Phase `4` through Sprint `4.8`, which has now landed: the
`prodbox rke2 delete --yes` success-summary contract is hermetic through the lifecycle-local
quiet path, the expanded `isIgnorableRke2DeleteNoiseLine` filter classifies inotify warnings as
benign noise, and the integration suite proves both the success and the actionable-failure
paths. Phase `5`
briefly reopened through Sprint `5.5` to add and prove a port `80` HTTP-to-HTTPS redirect for
the single-host public edge, and that redirect follow-up is now `Done`. Phases `5`, `6`, and
`7` remain `Done` on their owned surfaces (public-edge proof, clean-room rerun contract, AWS IAM
and quota administration) per standards rule E. The earlier
implementation-alignment follow-up on Phases `2`, `3`, and `4`, and the later Phase `2` cleanup
follow-up that removed the retained legacy `NTP synchronized` `timedatectl` parser branch in
`src/Prodbox/Host.hs`, remain closed in code and governed docs. The doctrine-driven reopens add
new sprints across Phases `1`–`4`; all of those reopens are now closed, and the cleanup ledger
records the delete-output residue under `Completed`.

The doctrine's cross-language type-bridge full-file generation surface
([code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)) lists cross-language type
bridges (e.g. PureScript or TypeScript contracts) as the canonical example of full-file
generation. The supported worktree intentionally keeps that registry empty today because no
non-Haskell consumer exists on the supported path; the registry will be populated when one
does. Sprint 1.23 records the equivalent deferral for the marker-delimited generation
surface; Sprint 0.4 names the full-file branch explicitly so future contributors do not
silently introduce a non-Haskell consumer without re-opening the registry.

The reopened ranges close on the following sprint sets:

- Phase 1: Sprints 1.6–1.27. Sprint 1.19 owns the pinned style-tools sandbox plus the custom
  nesting warnings and daemon-path negative-space symbol rules refusing
  `forkIO`, `unsafePerformIO`, and module-level `IORef`
  ([the engineering doctrine docs](../documents/engineering/README.md)§1370, §1450). Sprint 1.23 adds
  `dhall freeze` discipline on the committed repo-root `prodbox-config.dhall` path, the
  parser `--foreground` default plus self-daemonization-forbidden rule (§1591–1599), and the
  explicit cross-language-types generation deferral (§341–343).
  Sprints 1.24–1.26 close the audit-driven residue: durable CLI documentation artifacts
  derived from `CommandSpec` per [the engineering doctrine docs](../documents/engineering/README.md)and
  §2349–2356, the `execParserPure` parser-test category per §2116–2138, and the
  `renderError` error-rendering boundary discipline plus hlint rules refusing `print`,
  `exitFailure`, and direct terminal formatting outside the dedicated output layer per
  §815–831. Sprint 0.3 also extends Sprint 1.6 with per-leaf-command `CommandSpec` `Example`
  entries (§299–303) and Sprint 1.10 with the `cabal format` temp-file round-trip
  byte-equality compare (§1834–1837). Sprint 1.27 (added by Sprint 0.4) binds the
  cabal-manifest toolchain pin declarations `tested-with: ghc ==9.14.1` and
  `with-compiler: ghc-9.14.1`, the literal `Cabal 3.16.1.0` reference, and the
  library-first / thin-`Main.hs` layout check in `src/Prodbox/CheckCode.hs` per
  [the engineering doctrine docs](../documents/engineering/README.md)and §86–115. Sprint 0.4 also
  extends Sprint 1.6 with the `CommandSpec` / `OptionSpec` record-field bindings
  (§283–304) plus the daemon-as-typed-`Command` dispatch pattern (§1156–1196), Sprint 1.8
  with the named forbidden subprocess primitives `callProcess`, `readCreateProcess`, and
  direct `System.Process` smart constructors (§531), Sprint 1.10 with the twelve minimum
  `fourmolu.yaml` settings (§1834–1860), Sprint 1.11 with the canonical property-test
  invariants `decode . encode == id`, `render is deterministic`, and `parser roundtrips`
  (§2179–2188), Sprint 1.12 with the service-error newtype inventory `MinIOError`,
  `RedisError`, and `PgError` wrapping `ServiceError` (§867–890), Sprint 1.14 with the
  `AppError` record shape `errorKind` / `errorMsg` / `errorCause :: Maybe SomeException`
  (§1300–1340), Sprint 1.15 with the naming-helper signatures `boundedResourceName` /
  `sanitizeResourceName` / `hashSuffix` plus DNS-1123 / 63-character constraints (§565–630),
  and Sprint 1.21 with the enumerated forbidden renderer inputs — timestamps, random IDs,
  locale-dependent ordering, terminal-width-dependent wrapping, environment-dependent
  paths (§459–470).
- Phase 2: Sprints 2.9–2.16. Sprint 2.16 introduces `src/Prodbox/Daemon/Events.hs` for the
  doctrine at-least-once event-processing pattern
  ([the engineering doctrine docs](../documents/engineering/README.md)), wraps gateway peer worker loops
  in `try`/`catch` + bounded retry-with-backoff (§1244–1245), pins the atomic-swap discipline
  for `envLiveConfig` (§1533–1538), and extends the `prodbox-daemon-lifecycle` stanza with
  golden capture of `/healthz`/`/readyz`/`/metrics` responses (§1618–1619, §2252–2253) and
  the single-SIGTERM-drains-/-second-SIGTERM-forces-exit assertion (§1620, §2254). Sprint 0.3
  extends Sprints 2.9–2.12 with the audit-driven residue: the default 30 s drain deadline
  (§1235–1236) plus explicit `bracketOnError` on external-side-effect resources (§1218–1220)
  in Sprint 2.9; the `envMetrics :: MetricsRegistry` typed daemon `Env` field (§1357–1366)
  in Sprint 2.10; the STM broadcast channel for `LiveConfig` subscribers (§1528–1531) plus
  the prescribed on-disk Dhall file shape (§1551–1574) in Sprint 2.11; and the daemon log
  level refreshed from `LiveConfig` on every hot reload (§1275–1276) in Sprint 2.12.
  Sprint 0.4 extends Sprints 2.9, 2.11, 2.12, 2.13, and 2.14 with the round-3 residue:
  the enumerated structured-concurrency primitive set `withAsync` / `race` / `concurrently` /
  `replicateConcurrently` (§1313–1324) in Sprint 2.9; the forbidden reload triggers
  `fsnotify`, `inotify`, and `mtime` polling (§1491–1500), the typed Dhall field
  `schemaVersion : Natural` with mismatch-as-parse-failure (§1530–1538), and the eight-step
  reload procedure bound step-by-step (§1502–1530) in Sprint 2.11; the typed field helper
  `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` plus `logStructured`,
  `logDebug`, `logInfo`, `logWarn`, `logError` wrappers (§1370–1410) in Sprint 2.12; the
  production-no-op / test-injected hook contract pattern (§1284–1300) in Sprint 2.13; and
  the `/healthz` / `/readyz` / `/metrics` response shapes captured as golden tests inside
  the lifecycle stanza (§2243) in Sprint 2.14.
- Phase 3: Sprints 3.8–3.12. Sprint 3.12 adds the `prodbox lint chart` subcommand for Helm
  chart structural invariants through `src/Prodbox/CheckCode.hs`
  ([the engineering doctrine docs](../documents/engineering/README.md)§1870) and emits the
  `src/Prodbox/PublicEdge.hs` route catalog into chart manifests via marker-delimited
  generation under the existing `generatedSectionRule` registry (§341–343, §394–443). The
  "cross-language types" generation target (§341–343, §395–400) is explicitly deferred
  until a non-Haskell consumer enters scope; the full-file generation branch of the
  registry is intentionally empty today and is documented as such by Sprint 0.4.
  Sprint 0.4 extends Sprint 3.10 with the named forbidden reconciler flags `--force`
  and `--reinstall` plus the forbidden sister commands `install`, `upgrade`, `repair`,
  and `force-install` on the chart surface (§1781–1803).
- Phase 4: Sprints 4.5–4.8. Sprint 0.4 extends Sprint 4.5 with the same forbidden-flag
  and sister-command discipline on the lifecycle reconciler so the one-cycle deprecation
  alias preserves only the legacy name, not the forbidden flags (§1781–1803). Sprint
  4.8 hardens `prodbox rke2 delete --yes` so successful runs emit only doctrine-owned summary
  lines and no longer surface benign upstream uninstall chatter such as `Failed to allocate
  directory watch: Too many open files` as red-herring operator-visible errors.
- Phase 5: Sprint 5.5. The public edge gains a Gateway API HTTP listener on port `80` that
  returns only a permanent redirect to the canonical HTTPS URL, with no plaintext backend route,
  and the public-edge diagnostic plus named external validation prove that behavior. This
  follow-up is closed by the May 13, 2026 aggregate validation.

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Operator-authored repository-root `prodbox-config.dhall` decoded directly into Haskell types, with `prodbox-config-types.dhall` as the shared schema and no supported `prodbox-config.json` artifact | Repository root |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall|public-edge` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox rke2 reconcile|delete --yes|status|start|stop|restart|logs` | Haskell CLI with hermetic delete reporting on success and actionable failure summaries on non-zero uninstall, closed by Sprint `4.8` |
| Registry and image reconcile | Harbor-first steady-state image sourcing with a Harbor-plus-storage-backend bootstrap exception only, plus idempotent post-bootstrap public-image populate with alternate-source retry and native-host-architecture image publication for the Envoy Gateway target edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Haskell CLI |
| AWS substrate provision/teardown (EKS) | `prodbox pulumi eks-resources|eks-destroy --yes` | Haskell orchestration plus Pulumi; provisions the EKS portion of the AWS substrate. The `aws-eks` canonical suite validation runs against it. |
| AWS substrate provision/teardown (HA RKE2) | `prodbox pulumi test-resources|test-destroy --yes` | Haskell orchestration plus Pulumi; provisions the EC2 portion of the AWS substrate. The `ha-rke2-aws` canonical suite validation runs against it. |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap plus bounded repo-backed backend login and deleted-mount repair |
| Retained repo-local validation state | `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Haskell Pulumi orchestration and AWS substrate helpers |
| Gateway runtime operations | `prodbox gateway start --config <path>|status --config <path>|config-gen <output-path> --node-id <node-id>` | Haskell gateway runtime |
| Public workload runtime | `prodbox workload start` | Haskell runtime selected through `PRODBOX_WORKLOAD_MODE=api|websocket` for the supported path-routed API and real-WebSocket surfaces behind the shared public hostname |
| Gateway DNS writes | `dns_write_gate` | In-cluster Haskell gateway ownership and DNS-write gate for the single canonical public record |
| DNS check | `prodbox dns check` | Haskell CLI |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Haskell-owned shared-host path catalog and issuer derivation for application and admin routes |
| Chart delivery | `prodbox charts list|status <chart>|deploy <chart> [--dry-run] [--plan-file <path>]|delete <chart> [--yes] [--dry-run] [--plan-file <path>]` | Haskell chart platform over the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` chart surfaces, with `gateway` kept separate from the Envoy public edge and the shared-host browser, API, WebSocket, and admin paths delivered behind Envoy |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI on a single-host Gateway API and Envoy Gateway doctrine, including path-route classification for app and admin surfaces |
| Public-edge auth model | Envoy-enforced Keycloak JWT auth and RBAC on the shared hostname, with explicit bearer-token carriers, browser return paths, and JWKS metadata ownership | Keycloak issuer plus Envoy policy |
| Public-edge transport boundary | Public listener TLS terminates at Envoy on the supported path; backend HTTP remains the current workload default and backend TLS or mTLS requires later explicit doctrine ownership | Haskell lifecycle plus chart doctrine |
| Optional realtime-state model | Redis-backed shared state for supported WebSocket workloads today and any later explicit external rate-limit service | Haskell chart platform plus application workload doctrine |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary admin AWS credentials and AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses; `aws teardown` carries the Sprint `7.6`/`7.7` `PulumiResiduePolicy` contract (default refuse, `--destroy-pulumi-residue` to destroy live stacks first, `--allow-pulumi-residue` operator-acknowledged orphan escape; mutually exclusive at parse time). `aws setup` auto-detects `AKIA…` vs `ASIA…` access keys to conditionally prompt for the session token (Sprint `7.7`). |
| AWS IAM validation harness | `prodbox test integration aws-iam`, `prodbox test integration all`, `prodbox test all` | Shared Haskell validation harness with idempotent IAM-user and config cleanup. Sprint `7.6` orphan-safety guards: the harness postflight auto-destroys per-run Pulumi stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) on success / failure / Ctrl-C before clearing operational `aws.*`. Sprint `7.7` `BypassPerRunResidueOnly` mode: the harness teardown still refuses on long-lived `aws-ses` residue (was unconditionally bypassed before Sprint `7.7`). |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox check-code` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The target Haskell-only rewrite baseline is implemented in the worktree, and the repository is
closed against the current doctrine-reopened plan. Current worktree evidence puts Sprints
`0.7`, `1.6`–`1.27`, `2.9`–`2.16`, `3.8`–`3.12`, `4.5`–`4.8`, `5.5`,
`7.5.a`–`7.5.c.iv`, `7.5.c.v.b`–`7.5.c.v.e`, `7.6`, `7.7`, and `8.1`–`8.4` in `Done` state on
their owned surfaces; Sprint `7.5.c.v.f` is `Active`. The supported operator surface is `prodbox`, the
supported configuration contract is direct `Dhall -> Haskell types` rooted at
`prodbox-config.dhall`, and the supported build topology remains `.build/prodbox` on the host
plus `/opt/build` inside repository-owned Dockerfiles. `prodbox check-code` enforces the current
governed doctrine-alignment gate, the Haskell gateway runtime plus status path close on the
implemented bounded HTTP `/v1/state` payload and daemon timing-validation contract, the final
clean-room handoff closes on the canonical rerun surface, and the earlier unsupported Python
runtime and tooling surfaces remain removed.

The supported public edge uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
Keycloak on the single public hostname `test.resolvefintech.com`. Every externally reachable
application or operational dashboard routes through explicit shared-host paths such as `/auth`,
`/vscode`, `/api`, `/ws`, `/harbor`, and `/minio`, protected by Keycloak-backed JWT auth or RBAC
at Envoy, with one Route 53 record and one listener certificate. The shipped API route validates
bearer tokens locally at Envoy from Keycloak issuer metadata plus JWKS-backed signing keys,
browser-auth and direct-OIDC flows stay explicit on their owned paths, WebSocket workloads close
on a true `/ws` upgrade with Redis-backed shared state and readiness-based drain, and public TLS
terminates at Envoy while backend TLS or mTLS remains outside the supported chart-workload
contract.

Root guidance and the governed public-edge, gateway, chart-platform, registry, and testing docs
agree on the reclosed Haskell-only baseline and the doctrine-adoption surfaces now present in the
tree, including the service, retry, state-machine, output-option, application-environment, daemon
lifecycle, style-tool, and retained Pulumi harness work.

The authoritative lifecycle target remains Harbor-first and native-architecture only: Harbor plus
its storage backend bootstrap from public registries, every later Helm deployment pulls through
Harbor, and `amd64` or `arm64` hosts build and publish only their own architecture. The stack
closes on in-image `ghcup` with pinned GHC `9.14.1` in the frontend and gateway Dockerfiles, the
Percona operator-backed Patroni PostgreSQL doctrine, and config-selected MetalLB L2 or BGP
advertisement. The cleanup ledger preserves completed history and carries no remaining doctrine-
adoption pending-removal items. The separate Haskell
distributed gateway daemon remains distinct from the Envoy Gateway public edge.

The canonical validation contract for this worktree is the `prodbox` command surface documented
below; environment-dependent AWS and public-edge proof remain attached to those commands rather
than restated here as a fresh rerun log.

### Supported Haskell Surface

- The Haskell sources, Cabal definitions, and tests that build the supported `prodbox` binary and
  own the CLI frontend, lifecycle runtime, chart platform, public-workload runtime, gateway
  runtime, AWS integrations, and test harness live under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- Python source, Python packaging, Python tests, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` is not
  materialized on the supported path.
- `src/Prodbox/BuildSupport.hs` owns the `.build/prodbox` copy step and `.build/support`
  linker-support shim, while `src/Prodbox/Repo.hs` owns repository-root discovery plus canonical
  config-path resolution for the direct-Dhall command surface.
- `src/Prodbox/CheckCode.hs` now fails on repository-owned workflow or git-hook surfaces before it
  runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary sync step, closing on
  the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`. The repo-owned policy scan excludes generated or
  retained runtime roots such as `.build/`, `dist-newstyle/`, `.prodbox-state/`, and `.data/`.
- `src/Prodbox/Aws.hs` owns both the public onboarding flow and the standalone AWS administration
  command family, with prompt-driven temporary admin credentials on public paths and stored
  `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of that prompt input,
  with the native IAM validation harness as the only supported runtime consumer.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all` through one suite-level Haskell IAM harness.
- That shared harness now deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys before provisioning, uses any pre-existing `aws.*` only to discover and delete the
  IAM user associated with those credentials, proves STS-federated operational credentials with a
  compact AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS
  and repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from
  `aws_admin_for_test_simulation.*` because cert-manager Route 53 DNS01 credentials do not
  support an STS session-token field, and clears `aws.*` from `prodbox-config.dhall` before
  returning even when later prerequisites fail.
- Phase `7` keeps `pulumi_logged_in` behind the visible local runbook on aggregate and
  cluster-backed suite paths.
- `src/Prodbox/AwsEnvironment.hs` now isolates supported AWS subprocesses from ambient host AWS
  auth and profile state before projecting repository-root credentials into the supported command
  paths.
- The target container topology lives entirely under `docker/`. Every Haskell-build Dockerfile is
  single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and avoids
  symlinked Haskell tool shims.
- `src/Prodbox/CLI/Rke2.hs` owns the Harbor-first lifecycle, readiness gates, Harbor population,
  post-bootstrap Harbor-backed workload reconcile, native-host-architecture custom-image
  publication, and alternate-source retry during Harbor mirror publication, including
  `mirror.gcr.io` fallbacks for the Docker Hub-hosted Percona and Envoy images used by the
  supported lifecycle. The current lifecycle installs Envoy Gateway and the Harbor-backed Envoy
  image set for the supported public edge.
- The Helm-driven lifecycle restore now retries transient upstream chart-fetch failures before
  failing the supported path.
- `docker/prodbox.Dockerfile`, `docker/gateway.Dockerfile`, and `src/Prodbox/CLI/Rke2.hs` now
  close on the `ghcup` plus `ghc-9.14.1` toolchain path with no symlinked GHC shims and no
  mounted `haskell:9.6.7-slim` BuildKit context.
- `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `charts/keycloak-postgres/` now close on namespace-local Patroni PostgreSQL HA through the
  Percona operator while preserving the three-replica, synchronous-replication,
  retained-credential, deterministic manual-PV rebinding, retained secret rendering,
  convergence gate, retained-follower reinitialization, and no-embedded-PostgreSQL guarantees.
- `src/Prodbox/CLI/Pulumi.hs` plus the stack-local YAML Pulumi definitions under
  `pulumi/aws-eks/` and `pulumi/aws-test/` retain the public Pulumi command surface for AWS
  validation IaC, while `src/Prodbox/CLI/Rke2.hs` keeps bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection on the lifecycle path.
- `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/EffectInterpreter.hs`,
  `src/Prodbox/Infra/AwsTestStack.hs`, and `src/Prodbox/Infra/AwsEksTestStack.hs` now keep the
  repo-backed Pulumi backend on a bounded `pulumi login ... --non-interactive` path and repair a
  deleted MinIO export host-path mount by recreating the declared retained directory plus
  restarting `deployment/minio` before backend validation continues.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS substrate stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`; the HA-RKE2 validation destroys and recreates the retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Envoy Gateway
  and Percona reconcile path with no retained Traefik or pre-Percona operator migration shims.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi AWS
  provider-key layouts on the supported path.
- `src/Prodbox/PublicEdge.hs` now centralizes the single-host route catalog, canonical route
  URLs, and Keycloak issuer derivation consumed by lifecycle, DNS, chart, workload, host-
  diagnostic, and native validation surfaces.
- `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs` own the current Haskell gateway surface, including the HTTP
  `/v1/state` payload with total `event_count`, a bounded recent `event_hashes` tail,
  `heartbeat_age_seconds`, `peer_transport`, `can_write_dns`, `node_disposition`,
  `peer_dispositions`, `max_clock_skew_seconds_observed`, `max_clock_skew_seconds_bound`,
  `orders_version_utc`, and `latest_observed_orders_version_utc`, plus Orders-backed interval
  validation. The certificate, key, CA, and socket metadata in `DaemonConfig` and `Orders` are
  materialized at runtime through `peerListenerLoop` and
  `peerDialerLoop`, which replicate the append-only commit log between nodes, update
  `stateLastHeartbeatTimes` from inbound peer events, refuse heartbeats outside the configured
  skew bound, and reject inbound batches that present an older Orders version.
- `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, and `src/Prodbox/TestValidation.hs`
  own the aggregate reruns, named Haskell-owned validation flows, and destructive postflight restore
  path.

### Canonical Validation Gates

- Build and sync the operator binary through `cabal build --builddir=.build exe:prodbox` plus the
  `.build/prodbox` copy step.
- Run `prodbox check-code`.
- Run `prodbox test unit`.
- Run `prodbox test integration cli`.
- Run `prodbox test integration env`.
- Run the named Haskell-owned validation flows owned by `src/Prodbox/TestValidation.hs`.
- Run the aggregate reruns `prodbox test integration all` and `prodbox test all`.

### Interpretation

The supported architecture closes on the Haskell-only clean-room lifecycle, the AWS-validation-
only `prodbox pulumi ...` surface, the Harbor-first registry doctrine, and the Percona-backed
Patroni application-database path. Compatibility-cleanup history now lives only in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, plus generated state under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Phase 3 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `charts/`, plus generated retained non-PV state under `.prodbox-state/` and the Percona-operator-backed Patroni application-database contract | Phase 3 |
| Public workload runtime | `src/Prodbox/Workload.hs` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs`, `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phases 1 and 4 |

## Current Execution State

The pre-reopen Phases `0`–`7` remain closed on the implemented repository architecture. Phase
`0` has now re-closed after Sprints `0.2`–`0.7` landed the doctrine-adoption planning work
(Sprint 0.6 introduced the substrate doctrine and renamed phase-5 and phase-7 to their
substrate-aware names; Sprint 0.7, May 20, 2026, added the non-TTY guardrails on the
operator-interactive command surface). Phases `1`–`4` have also reclosed on the downstream
implementation scope scheduled by those sprints: Sprints `1.6`–`1.27`, `2.9`–`2.16`,
`3.8`–`3.12`, and `4.5`–`4.8` are locally validated and doc-aligned, and Sprint 1.2 was
revised May 20, 2026 to replace the external `dhall-to-json` subprocess decode bridge with
in-process decoding through the native Haskell `dhall` library (`Dhall.inputFile auto`).
Phase `5` reclosed after Sprint `5.5` added the port-80 HTTPS-redirect listener (May 13,
2026). Phase `7` reopened for substrate parity: Sprints `7.5.a`–`7.5.c.iv`, `7.5.c.v.b`,
`7.5.c.v.c`, `7.5.c.v.d`, and `7.5.c.v.e` are `Done` on their owned code surfaces (May 17–20,
2026); Sprint `7.5.c.v.f` is `Active` to diagnose and fix the May 20 silent-exit failure mode
in `runChartsVscodeValidation` and its `runCharts*Validation` / `runAdminRoutesValidation` /
`runPublicDnsValidation` siblings under `substrate=aws`; Sprint `7.5.c.v` (the live
AWS-substrate canonical-suite re-run) is blocked on `7.5.c.v.f`. Sprint `7.6` (orphan-safety
refuse-path + auto-destroy) and Sprint `7.7` (generalized `aws teardown` +
`PulumiResiduePolicy` ADT + harness teardown bug closure + admin-credential prompt UX) are
both `Done` (May 19, 2026). Phase `8` opened May 18, 2026; Sprints `8.1`–`8.4` are `Done`
and `8.5`–`8.6` carry the remaining operator-driven live OIDC closure work.

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, the
  Haskell test and quality framework, the local edge foundations, the one-host config contract,
  and config-selected MetalLB BGP support. The Phase `1` doctrine-adoption reopen covers
  Sprints 1.6–1.27, including `CommandSpec`, Plan / Apply, Subprocess ADT, prerequisite
  remedy-hint contract, the lint/generated-section/forbidden-path stack, the tasty stanza
  migration, capability classes and `AsServiceError`, `RetryPolicy`, `Recoverable` / `Fatal`
  errors, naming helpers, GADT-indexed state machines, one-shot output discipline with
  `--format` / `--color` / `--no-color`, the shared one-shot `Env` plus `ReaderT App`, the
  pinned style-tools sandbox and custom nesting warnings plus negative-space symbol
  rules refusing `forkIO`, `unsafePerformIO`, and module-level `IORef` in daemon paths, the
  aggregate `prodbox test lint` dispatch with lint-first ordering, the
  `trackingGeneratedPaths` registry plus renderer determinism property test, the
  standardized library audit of `prodbox.cabal`, the residual doctrine cleanup in
  Sprint 1.23 covering `dhall freeze` discipline on the committed repo-root config path, the
  parser `--foreground` default plus self-daemonization-forbidden rule, and the explicit
  cross-language-types generation deferral, and — added by Sprint 0.3 —
  the durable CLI documentation artifacts under `documents/cli/`, `share/man/`, and
  `share/completion/` (Sprint 1.24), the `execParserPure` parser-test category in the
  `prodbox-unit` stanza (Sprint 1.25), and the `renderError` error-rendering boundary
  discipline plus hlint rules refusing `print`, `exitFailure`, and direct terminal
  formatting outside the dedicated output layer (Sprint 1.26). Sprint 0.4 adds Sprint 1.27
  (cabal-manifest `tested-with: ghc ==9.14.1`, `with-compiler: ghc-9.14.1`, the literal
  `Cabal 3.16.1.0` reference, and the library-first / thin-`Main.hs` audit) and threads
  round-3 extensions through Sprints 1.6, 1.8, 1.10, 1.11, 1.12, 1.14, 1.15, and 1.21
  binding the `CommandSpec` / `OptionSpec` record shape, daemon-as-typed-`Command`
  dispatch, forbidden subprocess primitives (`callProcess`, `readCreateProcess`, direct
  `System.Process` constructors), the twelve minimum `fourmolu.yaml` settings, the
  canonical property-test invariants (`decode . encode == id`, `render is deterministic`,
  `parser roundtrips`), the service-error newtype inventory (`MinIOError`, `RedisError`,
  `PgError`), the `AppError` record shape (`errorKind`, `errorMsg`, `errorCause :: Maybe
  SomeException`), the naming-helper signatures with DNS-1123 / 63-character constraints,
  and the enumerated forbidden renderer inputs.
- Phase 2 owns the gateway runtime, DNS inspection surface, the single-record Route 53 doctrine,
  and the TLA+ validation entrypoint. The Phase `2` gateway surfaces close on the bounded HTTP
  `/v1/state` payload, a distinct native `gateway-partition` validation path, peer-transport
  gossip through `Prodbox.Gateway.Peer`, runtime claim/yield emission under the `canWriteDns`
  predicate, operator-verifiable bounded-clock-skew enforcement, config-relative trust-material
  validation, listener-host closure from Orders, Orders-version coordination across the mesh, and
  the host-info parser cleanup that limits `parseTimedatectlNtpDisposition` to the supported
  `System clock synchronized` field. The Phase `2` doctrine-adoption reopen covers Sprints
  2.9–2.16, including the explicit daemon lifecycle with worker loops wrapped in
  `try`/`catch` + bounded retry-with-backoff, `/healthz` / `/readyz` / `/metrics` endpoints
  with response shapes captured as golden tests, the `BootConfig` / `LiveConfig` split with
  `SIGHUP` hot reload and atomic-swap discipline on `envLiveConfig`, `co-log` structured
  logging, test hooks in `Env`, the `prodbox-daemon-lifecycle` stanza asserting single
  SIGTERM begins drain and second SIGTERM (or drain deadline) forces exit, the daemon CLI
  plumbing (`--config`, `--log-level`, `--port`, `--foreground`) plus `PRODBOX_*` env-var
  precedence rule, and the at-least-once event-processing module
  (`src/Prodbox/Daemon/Events.hs`) introduced in Sprint 2.16 covering `StoredEvent`,
  `recordEvent`, `markEventProcessed`, `fetchUnprocessedEvents`, and the idempotent
  `EventHandler` precondition. Sprint 0.3 extends Sprints 2.9–2.12 with the audit-driven
  residue: the default 30 s drain deadline plus explicit `bracketOnError` on
  external-side-effect resources (Sprint 2.9), the `envMetrics :: MetricsRegistry` typed
  daemon `Env` field backing `/metrics` (Sprint 2.10), the STM broadcast channel for
  `LiveConfig` subscribers plus the prescribed on-disk Dhall file shape (Sprint 2.11), and
  the daemon log level refreshed from `LiveConfig` on every hot reload (Sprint 2.12).
  Sprint 0.4 extends Sprints 2.9, 2.11, 2.12, 2.13, and 2.14 with the round-3 residue:
  the enumerated structured-concurrency primitive set `withAsync` / `race` /
  `concurrently` / `replicateConcurrently` (Sprint 2.9); the forbidden reload triggers
  `fsnotify`, `inotify`, and `mtime` polling, the typed Dhall field
  `schemaVersion : Natural` with mismatch-as-parse-failure, and the eight-step reload
  procedure bound step-by-step (Sprint 2.11); the typed field helper
  `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` plus `logStructured`,
  `logDebug`, `logInfo`, `logWarn`, and `logError` wrappers (Sprint 2.12); the
  production-no-op / test-injected hook contract pattern (Sprint 2.13); and the
  `/healthz` / `/readyz` / `/metrics` response shapes captured as golden tests inside the
  lifecycle stanza (Sprint 2.14).
- Phase 3 owns the chart platform, retained state model, supported public workload delivery, and
  the Percona-operator-backed Patroni PostgreSQL doctrine for Helm-managed workloads. The Phase
  `3` surfaces include the root-chart-only public `prodbox charts ...` surface, the JWT-protected
  API route, the Redis-backed
  WebSocket runtime, the shared public-workload runtime, multi-replica public workload scaling,
  the mixed-auth doctrine boundary between Envoy-managed browser auth and app-managed OIDC
  workloads, the explicit JWT carrier plus Keycloak JWKS-availability boundary, the shared-host
  Keycloak contract, real WebSocket upgrade handling, one-connection-per-pod lifetime,
  readiness-based drain, and path-routed Harbor plus MinIO admin delivery. The Phase `3`
  doctrine-adoption reopen has closed across Sprints 3.8–3.12, including smart constructors
  for paired chart resources, capability classes on chart Redis and Postgres call sites,
  reconciler discipline on `prodbox charts deploy` / `delete`, `--dry-run` on chart operations, the
  `prodbox lint chart` Helm-chart structural-invariants linter in Sprint 3.12, and
  marker-delimited route-inventory generation from `src/Prodbox/PublicEdge.hs` into chart
  artifacts via the `generatedSectionRule` registry. Sprint 0.4 extends Sprint 3.10 with
  the named forbidden reconciler flags `--force` and `--reinstall` plus the forbidden
  sister commands `install`, `upgrade`, `repair`, and `force-install` on the chart surface.
- Phase 4 owns Harbor-first lifecycle hardening, the narrowed Harbor-plus-storage-backend
  bootstrap exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  The Phase `4` lifecycle now installs MinIO first, bootstraps Harbor's registry bucket plus
  credential secret, reconciles Harbor on S3-backed registry storage, and keeps its later AWS-
  validation and Python-removal surfaces closed on the supported path. Sprint 0.4 extends
  Sprint 4.5 with the same forbidden-flag and sister-command discipline on the lifecycle
  reconciler; the one-cycle `install` alias has been retired, and `install`, `upgrade`,
  `repair`, and `force-install` are rejected at parse time.
- Phase 5 owns public-edge diagnostics and external proof on Route 53, Envoy Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  Harbor, and MinIO route classification plus named external proofs for those workloads. Sprint
  `5.5` closes this phase's redirect-only port `80` handling and proof while preserving HTTPS as
  the only application-traffic route.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria,
  closed through the aggregate rerun, postflight restore, `config show`, `config validate`,
  `host public-edge`, and supported-path repository review gates for placeholder-domain and Python
  residue.
- Phase 7 owns interactive onboarding, IAM automation, quota management, and the temporary-admin
  credential proof harness on one canonical public hostname with no placeholder-domain residue.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The rewrite preserves the full supported command matrix in
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
  unless a later plan revision changes it explicitly.
- The only supported local lifecycle host runtime is `Ubuntu 24.04 LTS` with systemd.
- The host build root is `.build/` with the operator-facing binary at `.build/prodbox`, enforced
  by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
- The container build root is `/opt/build`, and the only supported home for repository-owned
  Dockerfiles is `docker/`.
- Repository-root Dockerfiles are not part of the target architecture.
- `prodbox check-code` must fail on governed doctrine-alignment violations, not only on
  formatter, linter, build, or operator-binary sync failures.
- Every custom Dockerfile needing Haskell builds is single-stage from `ubuntu:24.04`, installs
  `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims. No
  supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
- When the pinned Haskell toolchain changes, `prodbox.cabal`, `cabal.project`, and the canonical
  build/test surfaces must be explicitly upgraded in the same change, including any required
  cabal-bound changes and full canonical validation reruns.
- The operator-authored repository-root `prodbox-config.dhall` is the single configuration source.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- Public `prodbox config setup` and public `prodbox aws ...` paths must be able to bootstrap all
  needed AWS credentials from scratch by prompting the operator for one temporary admin
  credential set (historically called "elevated credential").
- Stored admin credentials are otherwise disallowed. The one supported exception is
  `prodbox-config.dhall` `aws_admin_for_test_simulation.*`, and that section exists only for
  test-suite simulation of the ephemeral temporary-admin credential prompt, with the native IAM
  test harness as the only supported runtime consumer.
- The named and aggregate IAM validation surfaces share one joint idempotent harness that deletes
  any pre-existing dedicated `prodbox` IAM user and all of that user's access keys before
  provisioning, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, materializes IAM-user operational `aws.*` only from
  `aws_admin_for_test_simulation.*` to simulate the interactive public CLI workflow because
  cert-manager Route 53 DNS01 credentials do not support an STS session-token field, and clears
  operational `aws.*` from `prodbox-config.dhall` before returning.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV root and
  the repo-local `.prodbox-state/` root.
- Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
  storage backend during bootstrap.
- Every later Helm deployment must obtain its images through Harbor.
- `prodbox` must idempotently ensure required public images are present in Harbor after Harbor
  bootstrap and before they are referenced by later supported cluster workloads.
- Supported custom-image builds and Harbor publication use only the native architecture of the
  machine running `prodbox`: `amd64` hosts build `amd64` images, and `arm64` hosts build `arm64`
  images.
- Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
  cross-arch emulation, and mixed-arch clusters are unsupported on the canonical lifecycle,
  gateway, and chart-delivery path.
- All supported Patroni use must flow through the cluster-wide Percona operator installed on the
  canonical lifecycle path.
- The self-managed public edge target uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
  Keycloak-backed edge auth rather than Traefik `Ingress` plus `vscode-nginx`.
- Supported public workloads and operational dashboards route only through Envoy on the shared
  hostname `test.resolvefintech.com`. The supported auth doctrine keeps the token carrier
  explicit across those paths: bearer tokens on JWT-protected routes, explicit browser return
  paths for proxy-auth surfaces, and workload-owned carrier or session state only where a route
  still needs direct-OIDC behavior behind the same host.
- Keycloak-backed public workloads must stay proxy-aware behind Envoy on the shared hostname,
  including issuer alignment, forwarded `X-Forwarded-*` header compatibility, and no supported
  public management or health route exposure unless a later doctrine revision makes that exposure
  explicit. Keycloak availability may gate login, refresh, and JWKS refresh, but the steady-state
  JWT hot path at Envoy must not depend on per-request Keycloak calls while cached signing keys
  and unexpired tokens suffice.
- The supported public-host doctrine uses one shared hostname, one DNS entry, and one
  certificate.
- Redis may appear only as repo-owned shared app state for supported realtime or rate-limit
  workloads; it is not part of Envoy JWT validation, and the current supported worktree does not
  yet ship a standalone external rate-limit service surface.
- Supported public API and admin routes must validate JWTs locally at Envoy from Keycloak issuer
  metadata and signing keys, with explicit bearer-token carriage, route-level RBAC, and
  JWKS-discovery ownership, rather than through per-request identity-provider lookups or Redis.
- Public listener TLS terminates at Envoy on the supported path. Backend TLS or mTLS is not part
  of the current chart-workload contract unless a later plan revision expands it explicitly.
- Supported WebSocket workloads authenticate at connection setup, keep reconnect-safe state
  outside the pod, keep each live upgraded connection pinned to one selected backend pod until
  disconnect, define token-expiry and authorization-change behavior explicitly, use readiness-
  based drain before pod exit, and leave per-message authorization to the application workload
  when message-level permissions are finer-grained than the edge can enforce.
- Every supported Helm-managed PostgreSQL deployment must be external, Percona-operator-backed
  Patroni HA with exactly three PostgreSQL replicas, synchronous replication, and no embedded
  chart-local PostgreSQL subchart.
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources on the public
  `prodbox pulumi ...` surface, while bootstrap DNS reconcile and ACME `ClusterIssuer`
  projection remain lifecycle-owned in `src/Prodbox/CLI/Rke2.hs`.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The gateway daemon, `prodbox gateway status`, and daemon config parsing must close on the
  implemented bounded HTTP `/v1/state` surface, the Orders-backed interval-validation contract, and the
  current runtime-to-model notes in `documents/engineering/tla_modelling_assumptions.md`.
- The gateway daemon must materialize peer transport from the certificate, key, CA, and socket
  fields already retained in `DaemonConfig` and `Orders`, so `stateLastHeartbeatTimes` is updated
  from inbound peer events rather than from the local heartbeat loop alone, the append-only commit
  log replicates between nodes as the canonical heartbeat-and-event transport, and `/v1/state`
  exposes per-peer transport health.
- The gateway daemon must emit signed `Claim` and `Yield` events on owner transitions and gate
  Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
  `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log and a stale owner
  cannot reclaim DNS write authority without first observing its own yield being superseded by a
  fresh claim.
- The supported-host gate must fail fast on unhealthy NTP synchronization, the gateway daemon
  must record the maximum observed inter-node clock skew on `/v1/state` and refuse inbound
  heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
  correspondence docs must name that bound, the operator response, and how the model's
  bounded-delay assumption maps to a runtime-enforced skew limit.
- Orders documents must carry a monotonic version field, daemons must reject inbound peer events
  from a peer presenting an older Orders version, a new Orders version must propagate through the
  commit-log gossip surface and be adopted by every live daemon before the next election tick,
  and a daemon rebooting against a stale Orders version must refuse to claim ownership until its
  Orders view catches up.
- The only supported DNS model is one explicit Route 53 record for `test.resolvefintech.com`;
  wildcard public DNS and per-service public hostnames are not part of the supported
  architecture.
- The supported public workload catalog includes the cluster-backed `vscode` stack, a
  JWT-protected API route, a WebSocket route, and path-routed operational dashboards; none may
  depend on app-local nginx auth proxies or dedicated public subdomains.
- `example.com` must be completely removed from the supported codebase, defaults, fixtures, and
  documented runtime contracts.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
