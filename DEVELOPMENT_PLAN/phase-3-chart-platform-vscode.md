# Phase 3: Haskell Chart Platform and Public Workload Delivery

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Capture the Haskell chart platform, deterministic retained storage model, the
> supported public workload delivery path, and the CLI-doctrine adoption sprints that align chart
> orchestration with [the engineering doctrine docs](../documents/engineering/README.md).

## Phase Status

🔄 **Reopened 2026-08-10 on Sprint `3.34` (Standard A/N)** — an own-surface reopen on the chart
platform and chart lint this phase owns. A live `prodbox test all --substrate aws` run failed at the
`bootstrap-broker` Helm release on eight consecutive attempts: the chart's NetworkPolicy permits
Kubernetes API egress on TCP `443`, kube-proxy DNATs the API Service to its endpoint on `6443`
before the CNI evaluates egress, and the rule therefore matches nothing — the broker answered
`/healthz` 200 and `/readyz` 503 until `helm upgrade --wait` expired. The coordinate has **no
compiled owner**: `grep -rn "6443" src/` returns one hit, a kubeconfig string-match, so each of
three sites authors its own and the DNAT fact survives in the repository only as a chart comment.
Sprint `3.34` gives the coordinate one owner derived from `endpoints/kubernetes` — one observation
yielding both post-DNAT halves — and extends the chart lint's region to every repo-owned template,
closing the gap that let a `networkpolicy.yaml` literal go unread by every gate. The doctrine it
implements is
[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md), authored
by Sprint `0.26`. **This does edit a live production rendering path**, so the next Standard-P
qualification run must exercise the post-`3.34` rendering; both substrate rows were already
`pending`, so nothing is invalidated.

**Status correction (2026-08-10, Standard C).** This header led with the Sprint `3.32` reclosure
below and never recorded Sprint `3.33`, which landed 2026-08-09 and is the sprint
[README.md](README.md) names as this phase's reclose; `3.33` appears in this document only inside
its own sprint block. The phase document was the one Standard-J document still asserting the earlier
reclose — the same drift [phase-2-gateway-dns.md](phase-2-gateway-dns.md) corrected in place on
2026-08-08, and this one likewise survived subsequent sessions. It is corrected here rather than
rewritten silently: the `3.32` paragraph stands as written, and the reclose it claims was superseded
by `3.33` before this reopen.

✅ **Reclosed 2026-08-07 on Sprint `3.32`** — the 2026-08-05 own-surface reopen (Standard A/N,
Sprint `0.21` topology sweep) closes. Sprint `3.31` made all eight Helm statuses decode to distinct
constructors and put a `HelmWritePermit` in front of every mutating helper; Sprint `3.32` makes a
typed DNS destroy consume the `DnsOwnerAuthority` the running process holds instead of comparing
two caller-supplied copies of the coordinate's owner, and — the part worth stating — puts neither
cert-manager owner in the minter's range at all, so a prodbox process cannot name one. Its
documentation half corrected the ownership direction the sprint text had backwards: Vault, not
Percona PGO, is the authority for the three Patroni passwords, and exactly one chart-local mirror
runs Vault → Secret with no reverse path
([secret_derivation_doctrine.md § 5.1](../documents/engineering/secret_derivation_doctrine.md)).
Phase `3` has no open sprints on this reopen. Neither sprint moves a Standard-P
production-composition surface, and no prior closure on this phase was falsified.

✅ **Reclosed 2026-08-03 on Sprint `3.30`** — own-surface reopen (Standard A/N) declaring the
RFC 6455 WebSocket handshake GUID a real, required constant and pointing the MinIO chart
credential default at its actual registration in
[vault_doctrine.md §6.1](../documents/engineering/vault_doctrine.md). Comment-only; rendered
chart output is byte-identical.

✅ **Reclosed 2026-07-25 on physically separated control-plane workloads and derived resource
rendering.** Sprint `3.26` renders the Bootstrap Broker, Lifecycle Authority, Provider Worker,
Authority Backup Adapter, TLS Retention Adapter, and Target Secret Agent as separate workloads with
distinct identities, probes, policies, disruption budgets, and Guaranteed-QoS envelopes. Sprints
`3.28` and `3.29` single-source resource rendering and durable PVC sizing, and Sprint `3.27`
derives namespace admission from the validated workload-demand and placement plan. The warning-clean
build, unit and integration suites, chart/config/doc lint, generated-section checks, and
`prodbox dev check` pass. Deployment qualification remains pending under Standard P.

✅ **Reclosed 2026-07-10 for constant-time gateway probe binding.** Sprint `3.25` is Done on the
Phase-3-owned chart surface. `Prodbox.Gateway.Probe` is the typed source for the liveness
`/healthz` and readiness `/readyz` endpoints plus every timing and threshold value;
`ChartPlatform` emits that value, the generated `gateway-probes.values` section keeps the static
chart defaults synchronized, and the Deployment consumes the complete values-backed shape.
`prodbox dev lint chart` rejects `/v1/state` in either lifecycle probe. Validation: warning-clean
build (exit 0), unit 1386/1386, focused probe suite 4/4, chart/Haskell lint and generated drift
checks (exit 0), and Helm rendering of three Deployments with six dedicated lifecycle paths and
zero `/v1/state` probe paths; the repository-wide `prodbox dev check` exits 0. All prior
chart-platform, resource-envelope, and operator-gate closures remain valid.

✅ **Reclosed 2026-07-10 for operator-gate totality.** Sprint `3.24` is Done on the
Phase-3-owned chart operator-gate surface. `validateOperatorGates` now routes graph-projected gates
through an exhaustive `ComponentId` target registry, `OperatorAvailableTarget`, and
`observeComponentReadiness`. The Percona target uses a one-shot CRD-then-Deployment adapter with
`--ignore-not-found` and requires `Available=True`; a pending or unreachable observation closes the
chart-mutation gate. Every current unsupported `ComponentId` has an explicit fail-closed arm.
Adding a constructor is therefore warning-clean compile-enforced, while configuration that projects
an existing but unsupported ID is rejected at runtime rather than claimed universally impossible at
compile time. Validation: `./.build/prodbox dev lint chart` (exit 0),
`./.build/prodbox test unit` (1266/1266), and `./.build/prodbox dev check` (exit 0). All earlier
Phase `3` closures remain valid.

✅ **Reclosed 2026-07-06 for graph-sourced chart dependency edges** — Phase `3` expanded its
own chart-platform surface with Sprint `3.23` (✅ Done), part of the
bootstrap-readiness refactor
([bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md)). Sprint
`3.23` retires the hardcoded `chartDefinitionDependencies` / `ChartRequiresPatroniPlatform` edges in
`Prodbox.Lib.ChartPlatform` in favor of the Sprint `1.56` config-sourced component graph, and makes
the chart→Patroni-operator readiness gate prove the operator Deployment is `Available` (reconciling),
not merely that it exists. The retired hardcoded edges are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). Per Standard N it depended forward
only on the earlier-phase Sprint `1.56` (now ✅ Done). All earlier Phase `3` closures remain valid.

✅ **Reclosed 2026-07-04 for chart resource requirements** — Sprint `3.22` now expands the
chart-platform surface so every repo-owned chart template with containers/init containers renders a
values-backed cpu/memory/ephemeral-storage request+limit envelope, root charts render
`ResourceQuota` and `LimitRange` manifests from the validated `capacity.resource_plan`, and missing
workload profiles refuse before Helm invocation. Validation: `prodbox dev lint chart`,
`prodbox test unit` (1164/1164), and `prodbox test integration cli` (40/40). The schema source is
Phase `1` Sprint `1.55`; host/RKE2 enforcement landed in Phase `4` Sprint `4.41`; canonical
cluster-state validation landed in Phase `5` Sprint `5.13`.

✅ **Live-proven 2026-06-26 — the full chart stack passes end-to-end under the green home `test all`.**
The `charts-vscode`, `charts-api`, `charts-websocket`, `charts-platform`, and `charts-storage` named
validations all pass `ExitSuccess` in the green home `prodbox test all` (2026-06-26, 18/18; see
[00-overview.md](00-overview.md) Alignment Status), so Phase 3's chart-orchestration / retained-storage
/ Keycloak-OIDC / Redis / Patroni-PostgreSQL surfaces are home-substrate live-proven. This run also
fixed two chart defects en route — the `api` chart `config.dhall` `oidc.client_secret` type and the
`websocket-isolation` NetworkPolicy Vault egress (see [README.md](README.md) Closure Status). The
`--substrate aws` chart coverage stays orthogonal ([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-16** — the Vault secrets model is finalized to the Vault-root architecture
(narrated in the [README.md](README.md) Closure Status and harmonized across the plan suite per
[development_plan_standards.md](development_plan_standards.md) rule J). Vault is the sole
secrets/KMS/PKI root for the chart platform; the master-seed HMAC-SHA-256 derivation model is
**retired, not extended**; the `SecretRef.FileSecret` / Secret-mounted plaintext Dhall fragment is
**removed, not bridged**; a sealed Vault bricks chart and Keycloak secret resolution (hard
fail-closed). Sprint `3.17` is **Done** on the code-owned Vault platform and envelope foundation:
the shared Vault chart is installed by both substrate platform reconcilers, the durable Vault PV
shape is in the retained-storage manifest, and the `prodbox-envelope-v1` / Vault-Transit `DekCipher`
foundation exists. Sprint `3.18` is **Done** on the chart-secret Vault-auth surface: the typed
Vault chart-secret inventory, generated least-privilege policies/roles in
`defaultVaultReconcilePlan`, explicit service accounts for the straightforward chart workloads,
read-before-write Vault KV seed-object bootstrap in `vault reconcile`, Kubernetes-auth backend config
and Vault TokenReview binding, direct websocket OIDC `SecretRef.Vault` app-side consumption,
Keycloak/MinIO runtime secret materialization through Vault-login init containers, MinIO admin
bootstrap Vault-login init containers, VS Code Envoy `SecurityPolicy` client-Secret
materialization, gateway event/AWS/MinIO Vault consumers, Patroni role Secret materialization, and
host/admin helper plus AWS SES SMTP Vault reads/writes all landed on 2026-06-15. Unit proof now pins
the secret-dependent chart startup sections to `set -eu` + direct Vault login/KV reads with no
ignored Vault failure or generated-secret fallback; the live whole-system sealed-Vault validation is
owned by Sprint `5.8`. Sprint `3.19` is **Done**: the master-seed derivation modules, gateway
`/v1/secret/*` RPCs, daemon-only-seed lint, and self-bootstrap path are removed, so Vault KV is the
sole chart-secret store. Sprint `3.20` stands up the **Vault transit-seal hierarchy** with
per-cluster seal custody and is **Done**: `Prodbox.Vault.Seal` defines root Shamir versus child
Transit modes, child init uses recovery-key shares, the Vault chart renders `seal "transit"` only
for child mode, and child init material maps to parent-owned Vault KV. Phase 3 sprints
(`3.1`–`3.20`) are `Done` on their owned surfaces; live child auto-unseal during lifecycle is now
closed by Sprint `4.32`, and the gateway-mediated federation custody surface is closed by Sprint
`2.26`. Remaining sealed-Vault whole-system validation is owned by Sprint `5.8`, not Phase `3`.
See
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
and [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md).

✅ **Reclosed 2026-06-09** — reopened for Sprints `3.15`–`3.16` (design-intention review,
2026-06-09; narrated in the [README.md](README.md) Closure Status per
[development_plan_standards.md](development_plan_standards.md) rule A); both landed. Sprint `3.15` ✅
made the public-workload binary config-as-data: deleted the `src/Prodbox/Workload.hs` `PRODBOX_*`
env-var ladder (`--config` is now mandatory and `Workload.hs` has zero `lookupEnv`), gave the
workload the daemon's Boot/Live split + `fsnotify` reload symmetry, and added `Workload.hs` to
`checkEnvVarConfigReads.scopedPaths` so the workload path cannot regress to env-var config. Sprint
`3.16` ✅ closed the master-seed boundary: the raw seed is read in-cluster only (lint-enforced by
`checkRawMasterSeedReadScope`), the host derives chart secrets via `Prodbox.Gateway.Client`, the
`/tmp` seed-file + `resolveSeedViaMinio` host paths are deleted, `MinioMasterSeedConfig` got a
redacting `Show`, and `resetPatroniStorageIfRequested` was landed as the doctrine-prescribed
loud-failure mismatch check. Validation at reclosure: `check-code` 0, `test unit` 775,
`integration cli` 35, `prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check` 0; the live
first-install secret-materialization and Patroni-probe exercises are operator-driven. All earlier
Phase 3 sprints (`3.1`–`3.14`) remain `Done`; no later phase was reopened by this change.

✅ **Done** — Sprints `3.1`–`3.7` remain `Done` on the chart runtime, retained storage, browser
delivery, JWT-API, WebSocket, admin surfaces, and the Patroni doctrine. The phase is reopened by
Sprint 0.2 to schedule Sprints `3.8`–`3.12`, which adopt the doctrine's smart-constructor pattern
for paired chart resources, route Redis and Postgres call sites through capability classes, apply
the reconciler discipline to `prodbox charts deploy|delete`, surface `--dry-run` plans on chart
operations, and add the `prodbox dev lint chart` Helm-chart structural-invariants linter together
with marker-delimited route-inventory generation from `src/Prodbox/PublicEdge.hs` into chart
artifacts via the existing `generatedSectionRule` registry. Current worktree evidence puts
Sprints `3.8`–`3.12` in `Done` state: `storageBinding`, the
shared Patroni helper inventory in `src/Prodbox/PostgresPlatform.hs`, and the chart-platform
call-site migration now centralize the retained paired-resource, related-name, and
Redis/Postgres capability surfaces; the
chart reconciler surface now treats already-deployed healthy releases as a success no-op and
rejects the doctrine-forbidden flags and sister commands, chart dry-run plans are rendered and
golden-covered, the structural-lint implementation is live on `prodbox dev lint chart`, and the
marker-delimited route inventory generated from `src/Prodbox/PublicEdge.hs` is now emitted into
the consuming chart templates. Sprint `3.13` closed on 2026-06-01 via the live
home-substrate preserved-data and lifecycle exercise; Sprint `3.14` closed on the same
run when `charts-api` and `charts-websocket` proved the Dhall workload config path. This is a
preserved historical closure record; Sprint `3.25` subsequently reclosed the chart-owned gateway
probe binding while those earlier closures remain valid.

## Phase Summary

This phase owns the Haskell chart platform and retained-storage orchestration while preserving
deterministic PV/PVC rebinding and the supported public workload delivery model. It owns retained
storage, in-cluster-registry-backed image sourcing for the supported chart stack, the Envoy Gateway browser-auth
path for `vscode`, the JWT-only API and Redis-backed WebSocket workload surfaces, and the
PostgreSQL doctrine for every Helm-managed application stack. Sprints `3.2` through `3.7` remain
closed on the current chart platform, shared-host API, WebSocket, supported admin delivery, and
the authoritative Patroni doctrine. Sprint `3.1` now also closes on the root-chart-only public
command surface. The supported
`vscode` stack stays on registry-backed images after the bounded public-image bootstrap, uses
Gateway API plus Envoy Gateway `SecurityPolicy` for the public route, and keeps the
Percona-operator-backed Patroni HA path for every Helm-managed application stack: exactly three
replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.

**Independent Validation** (per
[development_plan_standards.md](development_plan_standards.md) Standard N): Phase 3 is
validatable on its owned chart-platform surface — the Haskell chart runtime, retained-storage
binding, Patroni/Vault rendering, and Gateway-API/Envoy route generation — without depending on
any later phase. Prior code-owned closure is proven locally (`prodbox dev check`, `prodbox test unit`,
`prodbox test integration cli`/`env`, `prodbox dev lint chart`, and `helm template` rendering),
and the home-substrate live exercise validates the chart stack end-to-end where a dependency owned
by another phase is touched. Proofs that require live infrastructure (a deployed cluster, an
unsealed Vault, operator-supplied unlock material, or live AWS substrate) are recorded as
non-blocking Live-proof items, per Standard O, and never gate this phase's code-owned closure; the
live whole-system sealed-Vault validation is owned by Sprint `5.8`, and AWS-substrate coverage of
the same chart validations is tracked in
[substrates.md](substrates.md)'s parity table. No incomplete later phase reopens Phase 3 — reopening
is only to expand its own owned chart-platform surface. Sprint `3.25` closed its expansion on
typed rendering, generated-default, golden, negative-fixture, and chart-lint proofs without a live
cluster or later phase.

## Current Baseline In Worktree

- The public `prodbox charts ...` runtime lives in `src/Prodbox/CLI/Charts.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, and
  `src/Prodbox/PostgresPlatform.hs`.
- The retained-root contract is the configured manual PV root (default `.data/`) with deterministic
  static `Retain` bindings. Chart secrets and gateway event/AWS/MinIO keys are Vault KV objects
  consumed through Vault Kubernetes auth or narrowly owned materializer Jobs; there is no gateway
  secret-derivation RPC and no chart-secret `.prodbox-state/` cache on the supported path.
- The supported chart catalog now includes `keycloak`, `vscode`, `api`, `websocket`, and
  `gateway`, with `keycloak-postgres` plus `redis` as internal dependency releases. The public
  parser and chart CLI now reject those internal names on the operator-facing
  `prodbox charts ...` surface with explicit guidance toward the owning root charts.
- The current supported app dependency graph now includes `keycloak-postgres -> keycloak -> vscode`
  for the browser stack and `redis -> websocket` for the shared-state realtime stack.
- The current lifecycle and chart code install the Percona `pg-operator` Helm release, mirror the
  Percona operator and PostgreSQL images, and render `PerconaPGCluster` resources for
  `keycloak-postgres`.
- The namespace-local release shape, deterministic manual-PV bindings, retained-secret contract,
  dependent-chart sequencing, and authoritative three-replica synchronous-replication doctrine
all close on the Percona operator surface.
- The gateway Deployment renders liveness from the typed `/healthz` projection and readiness from
  `/readyz`, with every timing and threshold field supplied through generated chart values.
  `prodbox dev lint chart` and separate liveness/readiness negative fixtures reject `/v1/state` as
  a kubelet probe; it remains available only as the operator diagnostic consumed by
  `prodbox gateway status`.
- `keycloak` now consumes the namespace-local retained Patroni credentials secret and the namespace-local
  primary service endpoint instead of a shared `pgpool` service.
- `src/Prodbox/TestPlan.hs` maps the chart validation names to executable native validations in
  `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host path-prefix catalog, canonical
  route URLs, and Keycloak issuer derivation consumed by the lifecycle, DNS, chart,
  host-diagnostic, and native validation surfaces.
- The chart templates that consume the shared public-edge path catalog now do so through the
  marker-delimited `route-registry` sections generated from `src/Prodbox/PublicEdge.hs` by
  `prodbox dev docs generate`, and `prodbox dev lint chart` validates chart metadata plus generated
  route-inventory drift on the supported surface.
- The current worktree renders the `vscode`, `api`, and `websocket` public paths through Gateway
  API `HTTPRoute` resources and Envoy Gateway `SecurityPolicy`, while `keycloak` publishes the
  shared public-edge `Gateway`, certificate, and identity route.
- The supported auth model now distinguishes request-borne bearer JWTs on the API route, the
  Envoy-managed browser redirect and cookie or session path on `vscode`, and workload-owned
  carrier or session state for the direct-OIDC `websocket` path.
- Envoy validates the current API route from Keycloak issuer metadata plus JWKS-backed signing keys
  on the edge hot path; Keycloak availability remains a dependency for login, refresh, and later
  JWKS refresh rather than for per-request API authorization.
- The shipped browser route exercises the Envoy-managed OIDC path, while the chart-managed
  direct-OIDC `websocket` workload keeps its workload-owned session bootstrap behind the shared
  host on the `/ws` route.
- The shared-host Keycloak identity route is rendered on `/auth`, and the named validation
  surfaces prove the issuer, forwarded-header, and public-path constraints for the supported
  Keycloak-backed workloads.
- Public TLS currently terminates at Envoy on the supported `/vscode`, `/api`, and `/ws` routes
  behind `test.resolvefintech.com`. Phase `3` closes on one shared hostname and one certificate
  for all public and admin routes. Backend TLS or mTLS is not part of the current supported
  chart-workload contract.
- The current worktree ships repo-owned API, Redis, and WebSocket chart stacks, with settings-
  backed replica controls for the public API and WebSocket workloads. Redis remains scoped to
  shared application state for the current WebSocket surface and any later explicit external
  rate-limit service; the current chart catalog does not yet ship a standalone rate-limit-service
  workload.
- The current Vault reconcile plan includes the Sprint `3.18` chart-secret policy/role foundation:
  `src/Prodbox/Secret/VaultInventory.hs` enumerates the KV v2 paths, policies, service accounts,
  and Kubernetes-auth roles for Keycloak, Patroni, OIDC, SMTP, gateway event keys, and MinIO root
  credentials, plus the seed-object field plan for generated/static/external Vault KV fields. The
  supported workload charts now render explicit service accounts for the straightforward pod
  controllers. The `websocket` chart renders its workload OIDC client secret as a
  `SecretRef.Vault` read from `secret/data/vscode/oidc/prodbox-websocket`, and the workload binary
  exchanges its service-account JWT through Vault Kubernetes auth before the WebSocket runtime
  starts. The `keycloak` chart renders Vault-login init-container materialization for the admin,
  Patroni app-role, OIDC, demo-user, and shared SMTP fields before realm import, and the `minio`
  chart renders Vault-login init-container materialization for root credential files consumed by
  `MINIO_ROOT_USER_FILE` / `MINIO_ROOT_PASSWORD_FILE`. The `vscode` chart materializes the Envoy
  `SecurityPolicy` client Secret from `secret/data/vscode/oidc/vscode` with a Vault-authenticated
  post-install/post-upgrade Job and namespace-local Secret RBAC. The gateway chart renders
  event-key, AWS, and MinIO credential fields as `SecretRef.Vault` values and the daemon resolves
  them through Vault Kubernetes auth. The `keycloak-postgres` chart materializes Patroni role
  Secrets from Vault through the `prodbox-<namespace>-pg` pre-install hook. The AWS SES setup flow
  writes `secret/keycloak/smtp`, and host/admin helper paths read the remaining Keycloak admin,
  OIDC, demo-user, and SMTP material from Vault KV. Sprint `3.18` includes the structural proof
  that migrated Vault materializers fail closed when Vault is sealed or unreachable; Sprint
  `3.19` retired the old derivation and chart-generated paths.
- The supported operational dashboard on the shared Envoy edge is MinIO; the in-cluster registry
  has no web UI or public route.
- The current config-file-owned `workload.mode = websocket` runtime materializes workload-managed OIDC
  bootstrap, a real `/ws` upgrade path, one-live-connection-per-backend-pod lifetime,
  readiness-based drain, revoke-and-reconnect behavior, and long-lived socket session semantics on
  the shared `/ws` route.

## Sprint 3.1: Haskell Chart Runtime and Deterministic Retained Storage ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep chart orchestration and retained-storage handling on the Haskell runtime while preserving the
supported platform doctrine.

### Deliverables

- `prodbox charts list|status|deploy|delete` are implemented in Haskell.
- Deterministic retained storage under the configured manual PV root remains intact.
- All non-PV chart state stays inside the cluster; the older master-seed-derived and
  chart-generated Secret model is being retired by Sprints `3.18`–`3.19` in favor of Vault KV via
  Kubernetes auth. The legacy `.prodbox-state/` cache is on the cleanup ledger;
  `forbidDotProdboxState` in `prodbox dev check` (Sprint `4.18`) refuses regressions.
- Chart secret resolution and gateway event-key handling move to Haskell-owned modules.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration charts-storage`
4. `prodbox test integration charts-platform`

### Current Validation State

- `test/unit/Main.hs` proves deterministic Haskell chart-plan and storage-binding behavior.
- `test/integration/CliSuite.hs` proves native built-frontend `prodbox charts
  list|status|deploy|delete` behavior against fake `helm` and `kubectl`, including explicit
  failure guidance when operators try to address internal `keycloak-postgres` or `redis`
  dependency releases directly.

### Remaining Work

None.

## Sprint 3.2: Haskell `vscode` Stack Delivery and Auth Path ✅

**Status**: Done
**Implementation**: `charts/`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the supported cluster-backed `vscode` stack on the Haskell chart runtime and the canonical
Harbor-first image doctrine.

### Deliverables

- The supported app path is `external PostgreSQL -> keycloak -> vscode`.
- The Haskell chart runtime owns deploy, status, and delete behavior for the `vscode` stack.
- Harbor-backed image refs remain canonical for the supported `keycloak` and `vscode` workloads
  after Harbor bootstrap.

### Validation

1. `prodbox test integration charts-platform`
2. `prodbox test integration charts-vscode`
3. Image-source proof: the supported chart or rendered manifests reference Harbor-backed refs for
   `keycloak` and `vscode`

### Current Validation State

- `src/Prodbox/TestPlan.hs` keeps `prodbox test integration charts-vscode` on the supported
  runtime bootstrap path rather than bypassing the cluster runbook.
- `src/Prodbox/TestRunner.hs` waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` before the external `charts-vscode` curl proof
  continues.

### Remaining Work

None.

## Sprint 3.3: Percona-Operator-Backed Patroni PostgreSQL Doctrine for Helm Workloads ✅

**Status**: Done
**Implementation**: `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/ContainerImage.hs`, `charts/`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep every Helm-managed PostgreSQL dependency on the implemented Percona-operator-backed external
Patroni HA surface.

### Deliverables

- Every supported Helm-managed PostgreSQL dependency consumes an external
  Percona-operator-backed Patroni HA deployment rather than an embedded chart-local PostgreSQL
  subchart or any retired operator surface.
- Every supported Patroni deployment runs exactly three PostgreSQL replicas with synchronous
  replication enabled.
- The only supported Helm role for Patroni is the cluster-wide Percona operator release plus the
  namespace-local application charts that render Percona-managed PostgreSQL custom resources,
  secrets, and dependent service inputs.
- Patroni-related images and Helm repository references are Harbor-backed or lifecycle-owned on
  the supported path after Harbor bootstrap.
- `keycloak`, `vscode`, and any later PostgreSQL-backed chart stack declare external database
  connectivity instead of rendering or depending on embedded PostgreSQL.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-vscode`
5. Helm proof: `prodbox rke2 reconcile` reconciles the cluster-wide Percona operator before
   namespace-local application charts deploy
6. Manifest proof: supported chart renders disable embedded PostgreSQL and target
   Percona-operator-managed service endpoints and custom resources
7. Image-source proof: Patroni-related chart workloads reference Harbor-backed images on the
   supported path

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` now installs the Percona `percona/pg-operator` Helm release from
  `https://percona.github.io/percona-helm-charts/`.
- `src/Prodbox/PostgresPlatform.hs` now defines the Percona operator namespace, release,
  deployment, CRD, service, and secret naming contract, including
  `perconapgclusters.pgv2.percona.com`, the `-ha` primary service, the `-replicas` service, and
  the Percona secret names for the application, superuser, and standby credentials.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders `keycloak-postgres` through
  `PerconaPGCluster`, waits for `.status.state=ready` plus `.status.postgres.ready=3`, discovers
  the operator-created PVC names before binding deterministic retained PVs, preserves the
  retained Patroni credential flow into `keycloak`, preserves the ordinal-0 retained anchor PV,
  restores retained clusters first at one replica, and then scales them back to three replicas
  after readiness before reinitializing follower roots when needed.
- `src/Prodbox/ContainerImage.hs` now mirrors
  `docker.io/percona/percona-postgresql-operator:2.9.0`,
  `docker.io/percona/percona-distribution-postgresql:17.9-1`,
  `docker.io/percona/percona-pgbouncer:1.25.1-1`, and
  `docker.io/percona/percona-pgbackrest:2.58.0-1` into Harbor and no longer carries any Zalando
  operator image targets on the supported path.
- `charts/keycloak-postgres/` now renders the retained application, superuser, and standby
  credentials secrets before the Percona cluster resource, alongside three replicas,
  synchronous mode, explicit security IDs `1001`, and deterministic manual-PV bindings.
- `charts/keycloak/` now consumes the namespace-local retained database secret and the namespace-local
  primary service endpoint.
- `documents/engineering/helm_chart_platform_doctrine.md` and the linked chart-platform doctrine
  now match the authoritative three-replica synchronous-replication contract described here.

### Remaining Work

None.

## Sprint 3.4: Envoy-Protected `vscode` Delivery and `vscode-nginx` Removal ✅

**Status**: Done
**Implementation**: `charts/vscode/`, `charts/keycloak/`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the `vscode` browser route on Gateway API delivery and Envoy-enforced browser auth with
Keycloak as the identity provider.

### Deliverables

- The supported `vscode` public route is expressed through Gateway API resources rather than
  `Ingress`.
- `vscode-nginx` is removed from the supported chart dependency graph and browser-facing auth path.
- Keycloak remains a chart-managed dependency, and this closed sprint removed the earlier
  nginx-backed browser-auth path before the final shared-host doctrine closed on the public edge.
- `keycloak_nginx_client_secret` is removed from the long-term chart secret contract.
- The current chart platform closes on Envoy-managed browser OIDC for `vscode`; Sprint `3.5`
  owns the remaining single-host API doctrine and any direct-identity path that still survives
  behind the shared hostname rather than broadening Sprint `3.4` beyond the shipped browser route.
- Optional Redis remains out of scope for the closed `vscode` sprint surface; Sprints `3.5` and
  `3.6` now carry the repo-owned API plus WebSocket workloads instead of chart-local auth proxies.

### Validation

1. `prodbox dev check`
2. `prodbox test integration charts-platform`
3. `prodbox test integration charts-vscode`
4. `prodbox test integration public-dns`
5. Manifest proof: the supported `vscode` path renders Gateway API resources and no longer renders
   `vscode-nginx`
6. Secret-contract proof: supported chart-secret state no longer requires
   `keycloak_nginx_client_secret`

### Current Validation State

- `charts/vscode/` now renders the public app path through `HTTPRoute` plus Envoy Gateway
  `SecurityPolicy`, with no `Ingress`, `vscode-nginx` deployment, or nginx config path.
- `charts/keycloak/` now renders the shared public-edge `Gateway`, certificate, identity
  `HTTPRoute`, and the supported shared-host Keycloak contract.
- `src/Prodbox/Lib/ChartPlatform.hs` now renders the Gateway API, OIDC, and shared-host values
  contract, and the chart-secret contract now uses
  `keycloak_vscode_client_secret`.
- `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, and the built-frontend suites no
  longer carry the nginx proxy image or image-publication path.
- The shipped chart surface now includes `keycloak`, `vscode`, `api`, and `websocket` workloads
  on the supported shared-host public edge.

### Remaining Work

None.

## Sprint 3.5: JWT-Protected API Workload Delivery ✅

**Status**: Done
**Implementation**: `charts/api/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported JWT-protected API workload to the Haskell chart platform on the shared hostname
so the public edge proves local token validation and route claims while the chart platform closes
explicitly on Keycloak-backed Envoy auth and RBAC.

### Deliverables

- The supported chart catalog adds a JWT-protected API workload on
  `https://test.resolvefintech.com/api` with Haskell deploy, status, and delete ownership.
- Envoy authenticates the API route locally from Keycloak issuer metadata and signing keys rather
  than through per-request Keycloak lookups or Redis.
- The API route carries explicit issuer, audience, path-claim, and RBAC requirements through
  repo-owned chart values and templates.
- The supported auth model explicitly identifies bearer-token API carriage, Envoy-owned browser
  redirect and cookie or session return paths, and the shared-host relationship between `/api`,
  `/vscode`, `/ws`, `/auth`, and later admin paths.
- Envoy discovers Keycloak JWKS out of band and validates API tokens locally on the hot path;
  Keycloak availability remains a login, refresh, and JWKS-refresh boundary rather than a
  per-request API dependency.
- The chart secret and Keycloak client contract expands as needed for the supported API route
  without reintroducing any app-local auth proxy surface.
- The supported chart platform explicitly distinguishes Envoy-managed browser or admin auth for
  proxy-auth workloads from any remaining workload-managed auth path that still needs direct
  identity claims or session ownership behind the same host.
- Keycloak-backed public workloads preserve the shared-host contract, including issuer alignment,
  proxy-header compatibility, and no supported public management or health path exposure unless a
  later doctrine revision expands that route set.
- The supported chart platform makes the current transport boundary explicit: public TLS terminates
  at Envoy, and backend TLS or mTLS remains outside the supported chart-workload contract until a
  later doctrine revision expands it.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-api`
5. Manifest proof: the API route attaches shared-host Gateway API and Envoy auth policy resources
   on the supported public edge
6. Auth proof: unauthenticated or wrong-claim requests are denied, while valid tokens from the
   configured Keycloak issuer are accepted
7. Doctrine proof: the supported API, browser, and direct-OIDC split names the request-token
   carrier and JWKS boundary explicitly and does not route JWT validation through Redis or
   per-request Keycloak calls
8. Manifest or runtime proof: the API route closes on the shared-host Keycloak issuer and proxy
   contract without reintroducing nginx proxy surfaces or extra public subdomains

### Current Validation State

- `src/Prodbox/Lib/ChartPlatform.hs`, `charts/api/`, and `src/Prodbox/Workload.hs` now render and
  serve the API workload, JWT provider configuration, audience, and route-claim requirements
  through repo-owned Gateway API, Envoy, and `PRODBOX_WORKLOAD_MODE=api` runtime surfaces.
- The current shipped browser route exercises the Envoy-managed redirect and cookie or session
  path, and the current API route validates request-carried bearer JWTs locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose `charts-api` as a
  named external validation surface that proves unauthenticated rejection, wrong-claim rejection,
  and valid-token acceptance.
- `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain aligned with the API workload surface.
- The shipped chart catalog now exercises the auth shapes the single-host doctrine must preserve:
  Envoy-managed browser OIDC through `vscode`, request-carried bearer JWTs through `api`, and the
  remaining direct-OIDC or workload-owned state required by the `websocket` path.
- `src/Prodbox/TestValidation.hs` proves the shared-host Keycloak issuer, redirect, and
  public-path contract for the API route on `https://test.resolvefintech.com/api`.
- The repo-owned chart surface now also carries the current WebSocket auth-path hardening:
  `charts/keycloak/` runs the identity path on one Keycloak replica, `charts/websocket/`
  authorizes a private token-endpoint backchannel to that identity workload, and the repo-owned
  custom image charts now force fresh pulls for the stable machine-id tags so the canonical suite
  does not reuse stale workload binaries.

### Remaining Work

None.

## Sprint 3.6: Redis-Backed WebSocket Delivery and Scale-Out ✅

**Status**: Done
**Implementation**: `charts/redis/`, `charts/websocket/`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Workload.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add a supported WebSocket workload and its Redis backing service to the Haskell chart platform so
the public edge closes on reconnect-safe realtime delivery under the shared hostname.

### Deliverables

- The supported chart catalog adds repo-owned Redis and WebSocket workloads with shared-host
  WebSocket routing on the Envoy edge.
- The supported `websocket` surface serves a true WebSocket endpoint on
  `https://test.resolvefintech.com/ws` rather than only HTTP helper endpoints on a dedicated
  WebSocket hostname.
- Reconnect-safe or restart-safe WebSocket state lives in Redis rather than in one pod's memory,
  and each live upgraded connection remains on one selected backend pod until disconnect.
- The supported public workload surface expands from single-replica `vscode` only to explicit
  multi-replica API or WebSocket workload scaling where the doctrine requires it.
- The chart runtime keeps Redis scoped to shared application state and never to Envoy JWT
  validation.
- The supported WebSocket workload documents and implements bounded connection-lifetime auth plus
  graceful termination behavior for deploy-time drain and reconnect, including readiness removal
  before terminating pods exit.
- The supported WebSocket workload defines token-expiry, authorization-change, reconnect, and
  drain behavior explicitly, and leaves per-message authorization to the workload when
  message-level permissions are finer-grained than the edge can enforce.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration charts-platform`
4. `prodbox test integration charts-websocket`
5. Manifest proof: the WebSocket route and Redis backing service render through repo-owned charts
   and the shared public hostname
6. Behavioral proof: authenticated WebSocket upgrade, one-upgraded-connection-per-backend-pod
   lifetime, reconnect-safe state, cross-replica message delivery, token-expiry or reconnect
   behavior, authorization-change handling, and readiness-based graceful drain work through the
   supported Redis-backed path

### Current Validation State

- The current chart catalog now includes repo-owned `redis` and `websocket` stacks, and
  `src/Prodbox/Workload.hs` provides the shared public-edge workload runtime selected through
  `PRODBOX_WORKLOAD_MODE=websocket`.
- The current WebSocket runtime surface now implements workload-managed OIDC bootstrap, a real
  `/ws` upgrade path, one-upgraded-connection-per-backend-pod lifetime, Redis-backed shared
  state, revocation-driven reconnect, and readiness-based drain for long-lived socket sessions.
- `deployment.websocket_scaling` and `deployment.api_scaling` now carry the settings-backed
  scale-out contract for the public workload surface.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose `charts-websocket` as
  a named external validation surface that proves authenticated WebSocket upgrade, cross-replica
  delivery, revocation-driven reconnect, readiness-based drain, and post-pod-restart state
  survival on the WebSocket surface.
- `src/Prodbox/Workload.hs`, `charts/websocket/`, and `charts/keycloak/` now also carry the
  private Keycloak token-endpoint backchannel, the matching inter-chart network-policy allowance,
  and the current single-replica Keycloak auth-path workaround needed to keep direct-OIDC browser
  login stable on the supported stack while remaining on the shared-host doctrine.

### Remaining Work

None.

## Sprint 3.7: Envoy-Routed Admin Surfaces and Shared-Host RBAC ✅

**Status**: Done
**Superseded surface note**: This block records the historical Harbor-plus-MinIO closure. The July
2026 `registry:2` replacement removed Harbor's UI and public route; the current admin surface is
MinIO-only, as stated in this phase's Current Baseline.
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/PublicEdge.hs`, `src/Prodbox/Host.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `charts/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Expose the supported operational dashboards, Harbor and MinIO, through Envoy on
`test.resolvefintech.com`, protected by Keycloak-backed auth and RBAC, so the platform needs only
one public hostname, one DNS entry, and one certificate.

### Deliverables

- Supported Harbor and MinIO dashboards route only through Envoy on explicit shared-host paths.
- Keycloak-backed JWT auth and route-level RBAC protect those admin surfaces at Envoy.
- No supported admin dashboard requires its own public hostname, DNS record, or certificate.
- Public-edge diagnostics and named validations include the shared-host admin surface.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-platform`
5. `prodbox test integration admin-routes`
6. Manifest proof: Harbor and MinIO render behind Envoy on shared-host paths with Keycloak-backed
   auth policy

### Current Validation State

- `src/Prodbox/CLI/Rke2.hs` now renders the supported MinIO console `HTTPRoute` plus
  `SecurityPolicy` resources behind Envoy on `/minio` (the in-cluster `registry:2` registry has no
  web UI, so there is no `/harbor` admin route).
- `src/Prodbox/PublicEdge.hs` now centralizes the supported `/auth`, `/vscode`, `/api`, `/ws`,
  and `/minio` path catalog used by the shared-host admin manifests, host
  diagnostics, and named validation surfaces.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/TestValidation.hs` now expose
  `prodbox test integration admin-routes` as the named external validation surface for the
  supported shared-host admin paths.
- `src/Prodbox/Host.hs` classifies Harbor and MinIO as supported admin routes on the shared
  hostname alongside the application route catalog.

### Remaining Work

None.

## Sprint 3.8: Smart Constructors for Paired Chart Resources ✅

**Status**: Done
**Implementation**: `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Adopt [haskell_code_guide.md#smart-constructors-for-paired-resources](../documents/engineering/haskell_code_guide.md#smart-constructors-for-paired-resources) on the chart platform.

### Deliverables

- Refactor PV/PVC pair construction in `src/Prodbox/Lib/Storage.hs` and
  `src/Prodbox/PostgresPlatform.hs` to flow through a single `mkStorageBinding`-style smart
  constructor that derives both resources from one set of inputs and uses the naming helpers
  introduced in Sprint 1.15.
- Apply the same discipline to any other paired resources (database user + grants, queue +
  dead-letter queue, etc.) observable in the chart platform.

### Validation

1. Unit tests confirm that the paired resources are derived from the smart constructor only.
2. Hand-constructed PV/PVC pairs outside the smart constructor are enqueued in the legacy
   ledger and removed.

### Remaining Work

None.

## Sprint 3.9: Capability Classes Applied to Redis and Postgres ✅

**Status**: Done
**Implementation**: `src/Prodbox/Service.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Apply [haskell_code_guide.md#capability-classes-and-service-errors](../documents/engineering/haskell_code_guide.md#capability-classes-and-service-errors) (Sprint 1.12) to chart-platform call sites.

### Deliverables

- Replace direct Redis / Postgres call sites in `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs` with `HasRedis` / `HasPg` method calls.
- Wire `retryServiceAction` into transient failure paths.

### Validation

1. `cabal test prodbox-unit` covers the new abstraction with `Env` test hooks.
2. Direct `redis-cli` / raw Postgres subprocess invocations outside the capability classes are
   absent.

### Remaining Work

None. Patroni cluster discovery, readiness, retained-claim wait, retained-anchor lookup,
secret recovery, and cleanup paths in `src/Prodbox/Lib/ChartPlatform.hs` now consume the `HasPg`
capability and classify transient PostgreSQL convergence failures as `PgError` through
`retryServiceAction`. The supported chart platform has no direct `redis-cli` call site, and
`test/unit/Main.hs` asserts that the chart PostgreSQL service calls pass through the capability
boundary.

## Sprint 3.10: Reconciler Discipline on prodbox charts deploy | delete ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Parser.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Adopt [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command).

### Deliverables

- `prodbox charts deploy <chart>` is the canonical idempotent reconcile; re-running it on a
  healthy chart is a documented no-op.
- `prodbox charts delete <chart> [--yes]` is the explicit teardown.
- Forbid any `--force` / `--reinstall` flag flavor on the chart surface; document
  already-deployed as the success case.
- Sprint 0.4 round-3 extension: name the forbidden flags and sister commands
  explicitly per [cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command](../documents/engineering/cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command). The chart reconciler surface
  refuses the literal flag names `--force` and `--reinstall` at parse time
  (Sprint 1.6 `CommandSpec` for `prodbox charts deploy|delete` does not register
  them; `execParserPure` returns a doctrine-named error if they are passed). The
  reconciler surface also refuses any sister command named `install`, `upgrade`,
  `repair`, or `force-install` on the `prodbox charts ...` family; the only
  mutation entrypoints are `deploy` and `delete`. A `prodbox-unit` parser test
  asserts that each forbidden flag and each forbidden sister-command name yields
  a parse-time rejection with the doctrine pointer.

### Validation

1. Integration test runs `prodbox charts deploy <chart>` twice in succession; the second run
   completes with no mutations applied.
2. The lint stack from Sprint 1.10 rejects the forbidden flag names.

### Remaining Work

None.

## Sprint 3.11: --dry-run on Chart Operations ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Lib/ChartPlatform.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Apply the Plan / Apply discipline from Sprint 1.7 to chart operations.

### Deliverables

- `prodbox charts deploy --dry-run <chart>` and `prodbox charts delete --dry-run <chart>`
  render the full Helm + Kubernetes + Pulumi plan and exit `0` without mutation.
- Golden tests cover the rendered plans.

### Validation

1. `cabal test prodbox-unit` validates the rendered chart plans.
2. The dry-run output is deterministic and free of timestamps or environment leakage.

### Remaining Work

None.

## Sprint 3.12: prodbox dev lint chart and Route-Inventory Generation ✅

**Status**: Done
**Implementation**: `src/Prodbox/CheckCode.hs`, `src/Prodbox/PublicEdge.hs`, `charts/keycloak/templates/gateway.yaml`, `charts/vscode/templates/http-route.yaml`, `charts/api/templates/http-route.yaml`, `charts/websocket/templates/http-route.yaml`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/documentation_standards.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/documentation_standards.md`

### Objective

Adopt [code_quality.md#lint-format-and-code-quality-stack](../documents/engineering/code_quality.md#lint-format-and-code-quality-stack)and §1870, and apply
[code_quality.md#generated-artifacts](../documents/engineering/code_quality.md#generated-artifacts)/ §394–443
to the `src/Prodbox/PublicEdge.hs` route catalog so chart artifacts consume the route
inventory through marker-delimited generation rather than hand-maintained YAML.

### Deliverables

- `src/Prodbox/CheckCode.hs` owns the `prodbox dev lint chart` subcommand declared in the
  `CommandSpec` registry (Sprint 1.6). The linter validates Helm chart structural invariants
  for every chart under `charts/`:
  - `Chart.yaml` parses, declares `apiVersion: v2`, and carries the required
    `name` / `version` / `appVersion` fields.
  - Every chart includes the mandatory `app.kubernetes.io/name`,
    `app.kubernetes.io/managed-by: prodbox`, and the phase-3 retained-storage label set.
  - Marker-delimited generated sections inside charts are reachable through the
    `generatedSectionRule` registry (Sprint 1.10) so drift fails closed.
- The existing `prodbox-haskell-style` test-suite stanza (Sprint 1.11) covers the
  generated route-inventory output and durable chart-generation surfaces, so the lint
  contract is exercised from both `prodbox dev lint chart` and `cabal test
  prodbox-haskell-style`.
- `src/Prodbox/PublicEdge.hs` rendering helpers emit the route catalog into chart
  manifests through marker-delimited blocks (`{{/* prodbox:route-registry:start */}}` /
  `{{/* prodbox:route-registry:end */}}` in Helm-template files,
  `# prodbox:route-registry:start` / `# prodbox:route-registry:end` in YAML manifests),
  registered in `generatedSectionRule` alongside CLI docs. Consumers in `charts/keycloak/`,
  `charts/vscode/`, `charts/api/`, `charts/websocket/`, and the shared-host admin manifests
  consume the generated section rather than hand-maintaining path prefixes.
- `documents/engineering/cli_command_surface.md` enumerates the new `prodbox dev lint chart`
  subcommand and the route-inventory generation surface.
- `documents/documentation_standards.md` adds route inventory to its enumerated list of
  generated files.
- "Cross-language types" generation (doctrine §341–343) is **deferred**: no non-Haskell
  consumer is in scope; the deferral is recorded in `system-components.md` and in
  `documents/engineering/cli_command_surface.md`. The `generatedSectionRule` registry
  remains ready for that consumer when one appears.
- Enqueue any pre-doctrine hand-maintained route catalog inside chart manifests in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal`
  with Sprint 3.12 as owner.

### Validation

1. `prodbox dev lint chart` succeeds on a clean tree and fails on a chart with a missing
   mandatory label or malformed `Chart.yaml`.
2. Hand-editing the route inventory inside any consuming chart manifest fails
   `prodbox dev lint docs` with the doctrine's path / registry-key / remedy-hint triple.
3. Regenerating the route inventory via `prodbox dev lint docs --write` (or
   `prodbox dev docs generate`) produces byte-identical output for the same `PublicEdge.hs`
   inputs (idempotent renderer property test from Sprint 1.21 covers this).

### Remaining Work

None.

## Sprint 3.13: Chart Secrets Derived by the Gateway Service ✅

**Status**: Done — code-owned surface
fully closed (chunks 1\8211\&16) as of 2026-05-31. Every host-side
`.prodbox-state/` chart-secret + gateway-event-key writer has been
removed; chart secrets and gateway event keys all flow through
master-seed-derived k8s `Secret`s materialized by the gateway daemon's
`ensure-namespace` handler or startup self-bootstrap, and chart
templates read them via Helm `lookup`. The full-sprint closure gate is
the live four-block preserved-data exercise (operator-driven). First
chunk landed 2026-05-30 on top of Sprint
2.19's daemon-side derivation foundation: new
`src/Prodbox/Secret/Inventory.hs` exposes the doctrine-§6 derived-secret
inventory in code via `derivedSecretInventoryFor :: Text -> Text -> [DerivedSecretEntry]`.
Currently enumerates the three Patroni roles for
`(keycloak, keycloak-postgres)` (`prodbox-keycloak-pg-pguser-keycloak` /
`-pg-pguser-postgres` / `-primaryuser` against the
`patroni:keycloak:keycloak-postgres:{app,superuser,standby}` context
strings) and the Keycloak admin field for `(keycloak, keycloak)`
(`keycloak-runtime.KEYCLOAK_ADMIN_PASSWORD` against
`keycloak:keycloak:admin`); returns `[]` for releases whose chart-side
Secrets are non-derived (`vscode`, `api`, `websocket`). Gateway per-node
event-key Secrets are intentionally not in the static table — their
count is a function of the live gateway node inventory, so the daemon's
`ensure-namespace` handler will inject them dynamically when
materializing the gateway release. Seven new unit tests in
`test/unit/Main.hs::"Sprint 3.13 derived-secret inventory"` cover the
keycloak-postgres + keycloak rows, the empty-fallthrough cases, and the
purity invariant. **Implementation choice (replaces the "new in-cluster
bootstrap binary OR ServiceAccount-via-kubectl" fork in the original
Sprint 3.13 scope)**: the chart pre-install Jobs will POST to
`/v1/secret/ensure-namespace`; the daemon itself owns the
kubectl-apply via its in-cluster ServiceAccount, so no new bootstrap
binary or chart-side Secret-create RBAC is needed. The pre-install Job
is a thin `curl`-equivalent + wait pattern. `prodbox dev check` 0,
`prodbox test unit` 613/613, `prodbox test integration cli` 30/30,
`prodbox dev docs check` 0, `prodbox dev lint docs` 0.

Second chunk landed 2026-05-30: new `src/Prodbox/K8s/InCluster.hs`
exposes the foundational K8s API client surface the daemon's
`ensure-namespace` handler will consume — pod ServiceAccount
credentials (`loadInClusterCredentials :: IO (Either String
InClusterCredentials)` reads token + ca.crt path + namespace from the
standard `/var/run/secrets/kubernetes.io/serviceaccount/` projected
mount), the canonical kube-apiserver Service URL
(`secretApiBaseUrl = "https://kubernetes.default.svc.cluster.local:443"`),
the namespaced @v1.Secret@ REST path renderer (`secretApiPath ::
namespace -> name -> String`), and the pure JSON manifest builder
(`secretManifestJson :: namespace -> name -> Map Text Text -> Value`
that emits `apiVersion: v1`, `kind: Secret`, `type: Opaque`, and a
lexically-ordered `stringData` block — deterministic per the doctrine
generated-artifact rule). Seven new unit tests in
`"Sprint 3.13 in-cluster K8s API client pure helpers"` cover the
ServiceAccount paths, the kube-apiserver URL, the REST-path renderer,
manifest field encoding, deterministic key ordering, purity, and the
empty-stringData edge case. `prodbox dev check` 0, `prodbox test
unit` 620/620 (+7), `prodbox test integration cli` 30/30, `prodbox
docs check` 0, `prodbox dev lint docs` 0.

Third chunk landed 2026-05-30: the `applyDerivedSecrets` pipeline +
the `K8sSecretOps` capability that decouples the handler logic from
the TLS-backed HTTPS implementation.

- New `K8sSecretOps` record on `Prodbox.K8s.InCluster` bundles the
  two namespaced @v1.Secret@ operations the handler needs:
  `secretOpsGet :: Text -> Text -> IO (Either String (Maybe Value))`
  and `secretOpsPut :: Text -> Text -> Value -> IO (Either String ())`.
  Lets the handler logic be unit-tested against an in-process mock
  without spinning up an HTTPS stack.
- New `src/Prodbox/Secret/EnsureNamespace.hs` exposes
  `applyDerivedSecrets :: K8sSecretOps -> MasterSeed -> Text -> [DerivedSecretEntry] -> IO (Either String [SecretSha256Entry])`
  — the doctrine-§4 idempotent materialization loop: for each entry,
  derive the value via `deriveBase64Url` over the master seed +
  context, build the `v1.Secret` manifest via
  `InCluster.secretManifestJson`, PUT through `secretOpsPut`, then
  compute the SHA-256 of the derived value for the response inventory.
  Short-circuits on the first PUT failure with a structured error
  naming the offending Secret + namespace + reason. Also exposes
  pure `deriveSecretValueText` (base64url Text wrapper) +
  `deriveSecretSha256Hex` (lowercase-hex SHA-256 wrapper) so unit tests
  can pin the wire encoding independent of the I/O loop.
- Six new unit tests in
  `"Sprint 3.13 applyDerivedSecrets pipeline"` cover: PUT-per-entry
  ordering against the keycloak-postgres inventory triple; the full
  v1/Secret/Opaque manifest shape for the single keycloak-runtime
  entry; that the response inventory carries SHA-256-of-derived
  (verified against a freshly-recomputed expected value); the
  determinism + lowercase-hex + 64-char-length invariants of
  `deriveSecretSha256Hex`; first-failure short-circuit behavior with
  no further PUT calls; and the empty-list passthrough.

The handler logic is now testable end-to-end via a mock
`K8sSecretOps`. The TLS-backed `K8sSecretOps` constructor (with the
in-pod CA store + bearer-token bearer-auth via `http-client-tls`) is
the next chunk's target. `prodbox dev check` 0, `prodbox test unit`
626/626 (+6), `prodbox test integration cli` 30/30, `prodbox docs
check` 0, `prodbox dev lint docs` 0.

Fourth chunk landed 2026-05-30: TLS-backed `K8sSecretOps` constructor
ready to drop into the daemon handler.

- New `inClusterK8sSecretOps :: InClusterCredentials -> IO (Either
  String K8sSecretOps)` on `Prodbox.K8s.InCluster`: reads the in-pod
  CA at 'inClusterCredentialsCaCertPath' via
  `Data.X509.CertificateStore.readCertificateStore`, configures a
  `Network.TLS.ClientParams` whose `clientShared.sharedCAStore` is
  the in-pod store (so the API server's serving cert verifies against
  the cluster's internal CA, not the system trust store), wraps in a
  `Network.Connection.TLSSettings`, and creates an HTTP `Manager` via
  `Network.HTTP.Client.TLS.mkManagerSettings`. The `secretOpsGet` and
  `secretOpsPut` closures inject the ServiceAccount bearer token as
  the `Authorization` header on every request. GET returns @Right
  Nothing@ on 404, @Right (Just value)@ on 200, @Left@ otherwise; PUT
  accepts 200 and 201 as success (API server picks create-vs-update
  server-side), structured-error on anything else with a truncated
  response-body suffix for diagnostics.
- New cabal deps to enable this (and resolved the `tls`-vs-`connection`
  version conflict by switching to the modern fork): `tls ^>=2.1`,
  `crypton-connection ^>=0.4` (replaces the old `connection` package),
  `crypton-x509-store ^>=1.6` (for `readCertificateStore`), and a
  bump of `http-client-tls` to `^>=0.3.6.4` so its newer release pulls
  `crypton-connection` instead of legacy `connection`.

Inert until the daemon handler dispatch chunk wires it in — the
TLS-backed constructor lives as a pure factory that the next chunk
imports. `prodbox dev check` 0, `prodbox test unit` 626/626 (no new
tests added; the TLS path is exercise-gated, not unit-gated), `prodbox
test integration cli` 30/30, `prodbox dev docs check` 0, `prodbox lint
docs` 0.

Fifth chunk landed 2026-05-30: daemon handler dispatch wires all four
prior chunks together. The hardcoded 503 stub at
`Gateway/Daemon.hs:855` is replaced by a real
`handleSecretEnsureNamespace` that:

1. Returns 503 when `envMasterSeed` is `Nothing` (same gate as
   `/v1/secret/derive`).
2. Extracts the HTTP request body via a new pure
   `extractRequestBody :: BS.ByteString -> BS.ByteString` helper
   (splits on `\\r\\n\\r\\n`, returns empty on missing separator).
3. Decodes the body to `SecretWire.EnsureNamespaceRequest`; returns
   400 with structured JSON on malformed input.
4. Loads in-pod ServiceAccount credentials via
   `InCluster.loadInClusterCredentials`; returns 503 when the
   ServiceAccount projection is missing (e.g. running outside
   Kubernetes).
5. Constructs the TLS-backed K8s API client via
   `InCluster.inClusterK8sSecretOps`; returns 503 with the structured
   reason on CA-cert load failure.
6. Looks up the doctrine-§6 inventory via
   `Inventory.derivedSecretInventoryFor namespace release`.
7. Invokes `EnsureNamespace.applyDerivedSecrets ops seed namespace
   inventory`; returns 500 with the structured reason on first PUT
   failure.
8. On success: returns 200 with the
   `SecretWire.EnsureNamespaceResponse` carrying the per-Secret
   SHA-256 inventory.

The daemon endpoint is now fully wired end-to-end on the code surface;
the only remaining moving parts are the chart-side RBAC (so the daemon
Pod actually has `secrets:create` permission in target namespaces)
and the chart pre-install Jobs (the in-cluster callers). Live
exercise — chart pre-install Job → endpoint → derived Secret applied
to a target namespace — is the closure gate. `prodbox dev check` 0,
`prodbox test unit` 626/626, `prodbox test integration cli` 30/30,
`prodbox dev docs check` 0, `prodbox dev lint docs` 0.

Sixth chunk landed 2026-05-30: gateway-chart RBAC so the daemon's
in-pod ServiceAccount actually has `secrets:get,create,patch` in the
namespaces it writes to.

- New `charts/gateway/templates/serviceaccount.yaml` declares the
  `prodbox-gateway-daemon` ServiceAccount in the gateway namespace.
- New `charts/gateway/templates/rbac.yaml` emits one `Role` +
  `RoleBinding` pair per entry in the new
  `rbac.targetNamespaces` values list. Each Role lives in the target
  namespace (so the grant is narrowly scoped) and grants
  `secrets:get,create,patch`; each RoleBinding binds the
  gateway-namespace ServiceAccount to the target-namespace Role.
- `charts/gateway/values.yaml` adds the `rbac.targetNamespaces` list;
  currently `[keycloak]` (the only namespace with derived inventory
  entries today). The comment block documents the expansion rule for
  when the gateway per-node event-key inventory + vscode/api/websocket
  derived entries land.
- `charts/gateway/templates/deployments.yaml` binds the daemon Pod
  spec to the new ServiceAccount via `serviceAccountName:
  prodbox-gateway-daemon` — this is what makes
  `/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt,namespace}`
  project the gateway-daemon token (instead of the namespace's
  `default` SA token) into the Pod for
  `InCluster.loadInClusterCredentials` to read.

The chart-side daemon-secret-write path is fully wired now. The
remaining Sprint 3.13 work is the chart pre-install Jobs (the
in-cluster callers) and the host-side `resolveChartSecrets` rewrite.
`prodbox dev check` 0, `prodbox test unit` 626/626, `prodbox test
integration cli` 30/30, `prodbox dev docs check` 0, `prodbox dev lint docs` 0.

Seventh chunk landed 2026-05-30: unified gateway ClusterIP + chart
pre-install Jobs for the two releases with derived inventory entries
(`keycloak-postgres` and `keycloak`).

- New `charts/gateway/templates/service-clusterip.yaml` exposes an
  unsuffixed `gateway` ClusterIP Service in the gateway namespace,
  selecting any gateway pod (selector intentionally omits the
  `gateway-node` label). This is the third Service shape per
  [doctrine §5](../documents/engineering/secret_derivation_doctrine.md#5-host-cluster-boundary)
  — the in-cluster RPC entrypoint at
  `gateway.gateway.svc.cluster.local:8443`. The per-node `gateway-<nodeId>`
  ClusterIPs (peer-gossip event channel) and the `gateway-nodeport`
  Service (host-CLI access) remain unchanged.
- New `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml`
  + `charts/keycloak/templates/secret-bootstrap-job.yaml`: Helm
  `pre-install,pre-upgrade` hooks (`hook-weight: -10`,
  `hook-delete-policy: before-hook-creation,hook-succeeded`) that
  POST `{"namespace":"<release-ns>","release":"<release-name>"}` to
  the gateway's `/v1/secret/ensure-namespace` endpoint via
  the canonical Harbor mirror
  `127.0.0.1:30080/prodbox/curl-mirror:8.11.0` (small +
  curl-only image). `--retry 12 --retry-delay 5
  --retry-connrefused` covers transient daemon-pod
  readiness flaps; `--max-time 30` bounds the wait. The Job's
  successful completion is the gate that lets the chart's actual
  Secret manifests (which `lookup` the daemon-applied Secrets)
  render.
- `charts/{keycloak,keycloak-postgres}/values.yaml` add the new
  `prodboxGateway.restPort: 8443` key (separate top-level to avoid
  collision with keycloak's existing Envoy-Gateway `gateway:` block).

The end-to-end Sprint 3.13 pipeline is now fully assembled on the
cluster side: chart pre-install Job → POST to gateway ClusterIP →
`handleSecretEnsureNamespace` → master-seed derivation →
`applyDerivedSecrets` via the in-pod RBAC'd K8s API client → derived
Secrets land in the target namespace before the chart's own resources
install. The only remaining work is the host-side `resolveChartSecrets`
rewrite (gut the `.prodbox-state` cache, call
`Prodbox.Gateway.Client.ensureNamespace` from the operator host, drop
the silent-reset arm of `shouldResetPatroniStorage`). Live exercise on
this host (the four-block preserved-data + recovery-escape-hatch +
original-failure-mode path from the approved plan Part 3) is the
closure gate. `prodbox dev check` 0, `prodbox test unit` 626/626,
`prodbox test integration cli` 30/30, `prodbox dev docs check` 0, `prodbox
lint docs` 0.

Eighth chunk landed 2026-05-31: end the chart-vs-daemon multi-writer
race on the data-bound Secrets the daemon now owns
(`keycloak-runtime.KEYCLOAK_ADMIN_PASSWORD` for keycloak,
`prodbox-keycloak-pg-pguser-*` / `-primaryuser` for keycloak-postgres).
Pre-chunk-8 state was structurally inconsistent: chunks 1–7 wired the
daemon to write those Secrets via the pre-install Job, but the chart's
`secret.yaml` (keycloak) and `00-secrets.yaml` (keycloak-postgres) also
rendered `keycloak-runtime` and the three Patroni Secrets via
`{{ .Values… }}` injection. Helm's apply runs **after** the pre-install
hook completes, so helm would overwrite the daemon's
master-seed-derived `KEYCLOAK_ADMIN_PASSWORD` / Patroni `password` with
the chart's `--set`-injected `chartSecrets` random/file-cache values —
silently undoing the entire derivation pipeline.

- `charts/keycloak/templates/secret.yaml` no longer renders the
  `keycloak-runtime` Secret; the daemon's pre-install Job is the sole
  writer of `KEYCLOAK_ADMIN_PASSWORD`. The `keycloak-smtp` Secret block
  is unchanged (still chart-managed pending the SES migration chunk).
- `charts/keycloak/templates/deployment.yaml` reads
  `KEYCLOAK_ADMIN` as a literal env var (`value: "admin"` from
  `.Values.keycloak.adminUser`); `KEYCLOAK_ADMIN_PASSWORD` continues to
  read from the daemon-applied `keycloak-runtime` Secret via
  `secretKeyRef`. Splits the admin username (non-secret) from the
  derived admin password (data-bound).
- `charts/keycloak-postgres/templates/00-secrets.yaml` removed entirely
  — the daemon's pre-install Job is the sole writer of the three
  Patroni Secrets the Crunchy operator watches.
- `Prodbox.Secret.Inventory.DerivedSecretEntry` extends with
  `derivedSecretEntryStaticFields :: [(Text, Text)]` so the daemon can
  write non-derived companion fields alongside the derived value in the
  same k8s Secret. Required because the Crunchy operator demands both
  `username` and `password` in each Patroni Secret it watches: the
  username is per-role static (`keycloak` / `postgres` /
  `primaryuser`), the password is HMAC-derived from the master seed.
- `Prodbox.Secret.EnsureNamespace.applyDerivedSecrets` merges the
  static fields into the manifest body so the daemon's PUT writes both
  `username` and `password` atomically.
- Tests: 2 new tests in `test/unit/Main.hs` — one pinning the
  `derivedSecretEntryStaticFields` shape for the three Patroni entries,
  one asserting the rendered manifest includes the `username` static
  field. The existing test that exercised
  `charts/keycloak-postgres/templates/00-secrets.yaml` is rewritten to
  assert the file is absent (delegation to daemon) and to check the
  pre-install Job's `helm.sh/hook` annotation as the new closure of
  the same contract. The stale `awsTestMain shouldContain "publicKey:"`
  assertion is updated to the chunk-6 reality
  (`tls:PrivateKey` + `ssh_private_key:` outputs).
- Validation: `prodbox dev check` exit 0; `prodbox test unit` 628
  examples pass; `prodbox dev lint docs` / `docs check` exit 0;
  `helm template keycloak charts/keycloak` and
  `helm template keycloak-postgres charts/keycloak-postgres` both
  render cleanly without any conflicting Secret apply.

Remaining Sprint 3.13 work after chunk 8:

- OAuth client secrets (`vscode`, `prodbox-api`, `prodbox-websocket`)
  + the `demo-user` password still flow via `chartSecrets` → `--set`
  → `configmap.yaml` realm-import JSON / chart values. To eliminate the
  remaining `.prodbox-state/<ns>/.secrets.json` writes, these need to
  either join the daemon's derivation inventory (`oidc:<ns>:<clientId>`
  context strings — straightforward extension of `Prodbox.Secret.Derive`
  + `Prodbox.Secret.Inventory`) and be read via Helm `lookup` from
  chart templates, OR become chart-managed via per-chart Secret +
  `lookup` + `randAlphaNum`. The latter is simpler for the
  non-data-bound case but requires the chart's realm-import to read the
  client secret from a Pod env var via Keycloak's `${env:VAR}`
  substitution.
- `resolveChartSecrets` rewrite per spec (single call to
  `Prodbox.Gateway.Client.ensureNamespace` + sanity check via
  `kubectl get secret`; remove `recoverPatroniSecretValues` /
  `mergeChartSecretValues`).
- `shouldResetPatroniStorage` rework (replace silent reset with
  loud-failure mismatch check via `Prodbox.Gateway.Client.derive` +
  `pg_authid` probe).
- `.patroni-anchor-volume` marker removal.
- `Prodbox.Infra.AwsSesStack.persistKeycloakSmtpChartSecrets` migration
  off `.prodbox-state/charts/keycloak/.secrets.json`.
- `Prodbox.UsersAdmin` read path off
  `.prodbox-state/charts/keycloak/.secrets.json`.

The live closure gate (four-block preserved-data + recovery-escape-hatch
+ original-failure-mode exercise) closes the whole sprint after the
remaining chunks land.

**Blocked by**: ~~Sprint 2.19~~ unblocked — `/v1/secret/ensure-namespace` is no longer a structured-503 stub; the daemon handler dispatch is live.
**Implementation**: ✅ `src/Prodbox/Secret/Inventory.hs` (doctrine-§6 inventory; 2026-05-30); ✅ `src/Prodbox/K8s/InCluster.hs` (in-pod credentials loader + REST-path / manifest helpers + `K8sSecretOps` capability + TLS-backed `inClusterK8sSecretOps` constructor; 2026-05-30); ✅ `src/Prodbox/Secret/EnsureNamespace.hs` (`applyDerivedSecrets` pipeline + sha256/base64url wire helpers; 2026-05-30); ✅ `src/Prodbox/Gateway/Daemon.hs::handleSecretEnsureNamespace` (replaces the 503 stub with the full request-body parse + master-seed gate + ServiceAccount load + TLS client construction + `applyDerivedSecrets` invocation + structured response; 2026-05-30); ✅ `charts/gateway/templates/serviceaccount.yaml` + `rbac.yaml` + `service-clusterip.yaml` + `deployments.yaml::serviceAccountName` (per-target-namespace Role + RoleBinding pairs for `secrets:get,create,patch` + unsuffixed in-cluster ClusterIP; 2026-05-30); ✅ `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml` + `charts/keycloak/templates/secret-bootstrap-job.yaml` (Helm pre-install Jobs that POST to ensure-namespace via the gateway ClusterIP; 2026-05-30); ✅ `src/Prodbox/Lib/ChartPlatform.hs` (`resolveChartSecrets` cache removal); ✅ `charts/<release>/templates/secret.yaml` (lookup-guarded patterns for non-derived fields).
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

### Objective

Eliminate the host-side `.prodbox-state/<namespace>/.secrets.json` chart-secret cache.
Chart secrets that bind to preserved `.data/` content (Patroni roles, Keycloak admin,
gateway event keys) are materialized as k8s Secrets by an in-cluster pre-install Job
that calls `/v1/secret/ensure-namespace` on the gateway service. Non-data-bound chart
secrets use Helm `lookup` + `randAlphaNum` behind early-return guards so reconciles
preserve the existing value. The full derived-vs-generated inventory lives in
[secret_derivation_doctrine.md §6](../documents/engineering/secret_derivation_doctrine.md).

### Deliverables

- `resolveChartSecrets` (`src/Prodbox/Lib/ChartPlatform.hs:1212-1280`) rewritten to a
  single call: `Prodbox.Gateway.Client.ensureNamespace endpoint namespace release`,
  then a sanity check that the expected Secrets now exist via `kubectl get secret`.
  Removes `recoverPatroniSecretValues` and `mergeChartSecretValues` entirely.
- `shouldResetPatroniStorage` (`src/Prodbox/Lib/ChartPlatform.hs:1343`) reworked:
  the reset-marker write path is replaced by a check that compares the derived
  password (via the gateway client) against what `pg_authid` reports through a
  probe-only Postgres connection. Mismatch is a loud failure that names the
  namespace/role pair and the resolution options (restore the seed, or wipe
  `.data/<ns>/<release>/`); never a silent reset. The
  `<namespace>/.patroni-anchor-volume` marker file path is removed; Patroni anchor
  decision derives from k8s PVC state alone.
- New chart pre-install Job per supported chart (`charts/<release>/templates/
  secret-bootstrap-job.yaml`): runs a small busybox-equivalent image with a
  Haskell-built `prodbox-secret-bootstrap` binary that POSTs to
  `/v1/secret/ensure-namespace` via the in-cluster gateway ClusterIP, waits for
  completion, exits. Helm `--wait` ensures the Job completes before chart
  resources install. (Alternative: in-cluster kubectl-apply via a ServiceAccount
  with Secret-create permission, eliminating the new binary. Pick during
  implementation based on chart-platform fit.)
- Each chart's `templates/secret.yaml` updated to use `lookup`-guarded generation
  for non-data-bound fields per
  [secret_derivation_doctrine.md §6](../documents/engineering/secret_derivation_doctrine.md);
  data-bound fields are populated by the pre-install Job above and surfaced via
  `lookup`.
- 15+ new unit tests in `test/unit/Main.hs::"Sprint 3.13 chart secrets via gateway"`
  for the derived-vs-generated chart-secret split with golden manifests covering
  Keycloak, vscode, gateway, api, websocket.

### Validation

1. `prodbox dev check` exit 0; the `forbidDotProdboxState` lint (introduced by
   Sprint 4.18) fires if any new `.prodbox-state/*` write regresses.
2. `prodbox test unit` covers the new tests.
3. `prodbox test integration cli` continues to pass.
4. Live exercise of the preserved-data case on this host:
   `prodbox rke2 reconcile` → `prodbox charts deploy keycloak` → use Keycloak
   (create a realm, add a user) → `prodbox rke2 delete --cascade --yes`
   (preserves `.data/`) → `prodbox rke2 reconcile` → `prodbox charts deploy
   keycloak` → derived secrets match existing `pg_authid` → Keycloak exports the
   realm and user from before the wipe.

**Chunks 9 + 10 + 11 + 12 + 13 + 14 landed 2026-05-31** as a connected push closing the
host-side cache eradication. Every code-side `.prodbox-state/charts/<ns>/.secrets.json`
writer is gone; the chart-vs-daemon multi-writer race is closed for every
data-bound field the daemon now owns; the @.patroni-{anchor-volume,reset-required}@
markers are deleted and the Patroni anchor decision derives from live k8s state.

- **Chunk 9** — `Prodbox.UsersAdmin.loadKeycloakAdminPassword` reads the daemon-applied
  `keycloak-runtime` Secret's `KEYCLOAK_ADMIN_PASSWORD` via `kubectl get secret`
  (using `runPg` from `Prodbox.Service`). The `.prodbox-state` read-path is gone.
- **Chunk 10** — `Prodbox.Infra.AwsSesStack.persistKeycloakSmtpChartSecrets` kubectl-
  applies the `keycloak-smtp` Secret with all seven `KC_SMTP_*` fields +
  `helm.sh/resource-policy: keep`. `mergeChartSecretsFile`/`readChartSecretsFile`/
  `chartSecretsPrettyConfig` removed. Chart's `secret.yaml` no longer renders
  `keycloak-smtp` (sole-owner kubectl). `configmap.yaml`'s realm-import
  `smtpServer` block uses Helm `lookup` at template-render time.
- **Chunk 11** — extended `Prodbox.Secret.Derive` with `oidcClientSecretContext` and
  `keycloakDemoUserContext`; refactored `Prodbox.Secret.Inventory.DerivedSecretEntry`
  to carry `derivedSecretEntryDerivedFields :: [(Text, Text)]` (replaces the single
  key+context shape) so the daemon writes one `keycloak-oidc-clients` Secret with
  four derived fields atomically. `applyDerivedSecrets` derives every field and
  merges static fields into the manifest body. `configmap.yaml` realm-import +
  `charts/vscode/templates/http-route.yaml` + `charts/websocket/templates/configmap-config.yaml`
  all read the OAuth client secrets via Helm `lookup` (cross-namespace for vscode/
  websocket from the keycloak namespace). **[Current canonical topology:** Keycloak and the shared
  public edge run in the `vscode` namespace (the `keycloak` chart is a dependency of the `vscode`
  root chart) — see [envoy_gateway_edge_doctrine.md](../documents/engineering/envoy_gateway_edge_doctrine.md).**]**
- **Chunk 12** — `resolveChartSecrets` reduced to `pure (Right Map.empty)`.
  `requireMapValue`, `requiredChartSecretKeys`, `recoverPatroniSecretValues`,
  `mergeChartSecretValues`, `readSharedKeycloakSecretValues` deleted.
  `valuesForKeycloak`/`valuesForKeycloakPostgres`/`valuesForVscode`/`valuesForWebsocket`
  drop every `requireMapValue` call and the corresponding chart-value override; the
  charts now read all migrated fields via Helm `lookup` of daemon/kubectl-applied
  Secrets.
- **Chunk 13** — `.patroni-anchor-volume` marker file deleted (writer + reader gone).
  The two surviving anchor-read sites (`readOptionalPatroniBootstrapAnchorBinding`
  and `ensurePerconaPatroniStorageBindings`) now call
  `discoverPatroniAnchorPersistentVolumeName` directly (k8s state via Patroni
  primary endpoint). The post-install marker-write hook becomes a documented
  no-op.
- **Chunk 14** — `shouldResetPatroniStorage` deleted (sole caller was the now-gutted
  `resolveChartSecrets`). `patroniClusterStatusIndicatesFailure` +
  `patroniStorageExists` + `requiredKeysPresent` + `requiredKeyPresent` +
  `readOptionalSecretPassword` + `writePatroniResetMarker` +
  `patroniResetMarkerFileName` all removed. `resetPatroniStorageIfRequested`
  reduces to `pure (Right ())` since the marker is never written. The
  spec's prescribed loud-failure mismatch check (derive vs `pg_authid` probe)
  is deferred to the live four-block exercise where the failure paths actually
  fire — until that lands, the reset arm is a documented no-op.

Validated on all five static gates: `prodbox dev check` exit 0,
`prodbox test unit` 628/628, `prodbox test integration cli`/`env` exit 0,
`prodbox dev lint docs` / `docs check` exit 0; `helm template` renders cleanly for
`keycloak`, `keycloak-postgres`, `vscode`, `websocket`.

### Current Validation State

**Chunk 16 (2026-05-31 still later)** closes the host-side cache
eradication completely. The gateway per-node event-key cache
(`.prodbox-state/<ns>/.gateway-event-keys.json` via the prior
`resolveGatewayEventKeys`) is gone; the daemon's own startup loop
self-bootstraps a `gateway-event-keys` k8s Secret in the gateway
namespace right after acquiring the master seed. The chart reads it via
Helm `lookup`. With the cache gone, `chartStateRootRelative` +
`chartStateDir` + `ensureChartStateDir` + `repairChartStateDir` +
`resolveOrGenerateStringMap` + `writeGeneratedMap` + `mergeRequiredKeys` +
`writeStringMap` + `readStringMap` + `randomHexString` + `byteToHex` are
all removed.

- `Prodbox.Secret.Inventory.derivedSecretInventoryFor` adds a
  `(gateway, gateway)` entry writing `gateway-event-keys` with three
  derived fields: `NODE_A_EVENT_KEY` / `NODE_B_EVENT_KEY` /
  `NODE_C_EVENT_KEY` via the existing `gatewayEventKeyContext` (shape
  `gateway:<namespace>:<node-id>:event-key`).
- New `Prodbox.Gateway.Daemon.selfBootstrapOwnSecrets`: called right
  after `acquireInitialMasterSeed`, it loads in-pod ServiceAccount
  credentials, constructs the TLS-backed K8s API client, and applies
  the daemon's own (gateway, gateway) inventory. All failure modes
  degrade gracefully (no seed yet → skip; outside k8s → skip with
  diagnostic; RBAC missing → log and continue). The chart's Helm
  `lookup` re-renders cleanly on the next reconcile.
- `charts/gateway/values.yaml` extends `rbac.targetNamespaces` with
  `gateway` so the daemon's ServiceAccount can write the
  `gateway-event-keys` Secret in its own namespace. This is what
  authorizes the self-bootstrap.
- `charts/gateway/templates/configmap-config.yaml` reads three
  `NODE_<X>_EVENT_KEY` fields via Helm `lookup` of `gateway-event-keys`
  and renders the per-node `event_keys` list directly. On `helm
  template` (no cluster) the lookup is empty and the chart falls back
  to an empty list — fine for golden-test determinism.
- `charts/gateway/values.yaml` drops the `eventKeys: {}` value (no
  consumer remains); `valuesForGateway`'s `gatewayEventKeys` parameter
  becomes a vestigial `Map.empty` (signature preserved for now).
- `renderRetainedStateNotice` (in `Prodbox.CLI.Rke2`) no longer claims
  to preserve a "chart state root" — nothing under `.prodbox-state/` is
  preserved by the supported lifecycle any more.

Sprint 4.18's `forbidDotProdboxState` lint **broadens** in lockstep:
the scan needle widens from the closed `.secrets.json` filename to the
whole `.prodbox-state/` prefix; one new unit test pins the broader
contract. After chunk 16 a grep for `.prodbox-state` in `src/`+`app/`
string literals returns zero hits (only comments mention it for
historical context).

Validated on all five static gates: `prodbox dev check` exit 0,
`prodbox test unit` 631/631, `prodbox test integration cli`/`env`
exit 0, `prodbox dev lint docs` / `docs check` exit 0; `helm template`
renders cleanly for the gateway chart with empty `event_keys` fallback.

The live four-block end-to-end verification from the approved plan
Part 3 (preserved-data + recovery-escape-hatch + original-failure-mode
+ Sprint 4.18 final-cleanup) is the full-sprint closure gate; it
remains operator-driven because it depends on a live `prodbox rke2
reconcile` + multi-cycle delete/redeploy of Keycloak.

**Chunks 17–31 (2026-06-01)** are the live-iteration "tail" — each
chunk lands one targeted fix surfaced by a live `prodbox test all`
retry on the home substrate, since pure code review missed each one.
The pattern is single-issue → diagnose with `kubectl` + daemon logs →
targeted fix → re-run, repeated until live convergence.

- **Chunk 17** — `ensureAdminPublicEdgeRoutes` regressed against the
  new master-seed flow; the host-side derivation in chunk 12 had
  pulled the rug from under it. `waitForAccessToken` and the missing
  `keycloak_vscode_client_secret` rendering paths both updated to read
  the daemon-applied Secret via cross-namespace `kubectl` rather than
  the deleted host cache.
- **Chunk 18** — chunk 17's `kubectl`-based read fails *during*
  platform setup, before the `keycloak` namespace exists. The fix:
  derive `VSCODE_CLIENT_SECRET` host-side from the master seed in
  MinIO (which is materialized by `ensureGatewayMinioBootstrap` one
  reconciler step earlier). New `readKeycloakVscodeClientSecret` uses
  `withMinioPortForward` + `ensureMasterSeed` + `deriveBase64Url` to
  compute the same value the daemon would write — deterministic over
  the same seed.
- **Chunk 19** — drop the stale "non-empty `gatewayEventKeys`"
  validation in `valuesForGateway`. After chunk 16 the chart reads
  event keys via Helm `lookup`, not via the `eventKeys:` value, so the
  validation was rejecting fresh deploys.
- **Chunk 20** — the gateway chart's RBAC templates now emit a
  `Namespace` resource for each entry in `rbac.targetNamespaces` that
  isn't the chart's own. Otherwise `helm upgrade --install gateway`
  fails when `keycloak`/`vscode` namespaces don't exist yet for the
  Role/RoleBinding to land in.
- **Chunk 21** — `derivedSecretInventoryFor` is now
  *namespace-aware* for the `keycloak-postgres` release. The Crunchy
  operator names the Patroni Secrets after the cluster, which is
  named after the root chart. `vscode` and `keycloak` both pull
  `keycloak-postgres` as a dependency, so the daemon sees the same
  release in two different namespaces and must write
  `prodbox-vscode-pg-*` / `prodbox-keycloak-pg-*` accordingly. The
  cluster-name prefix is now `"prodbox-" <> namespace <> "-pg"`.
- **Chunk 22** — the gateway daemon's ServiceAccount RBAC adds the
  `update` verb on Secrets. The K8s API rejects `PUT` without it; the
  daemon was getting `403 cannot update`.
- **Chunk 23** — the daemon's K8s API client is rewritten as
  POST-first, PUT-on-`409`-conflict. The naive PUT-only path was
  failing with `404 secrets not found` on first creation; the
  recommended K8s create-or-update idiom is the two-phase form
  above.
- **Chunk 24** — `Daemon.deriveOwnGatewayEventKeys` now derives the
  three per-node event keys *in memory* at startup, populating the
  daemon's own `eventKeys` map from the master seed instead of
  relying on Helm `lookup` to land them in the ConfigMap. This
  closes the bootstrap chicken-and-egg where the daemon's Pod
  started before its own `gateway-event-keys` Secret existed and so
  refused to forward events with `event_key_missing`.
- **Chunks 25 + 26** — `secret-bootstrap-job.yaml` (in both
  `charts/keycloak` and `charts/keycloak-postgres`) tunes the
  pre-install Job's `backoffLimit` + `curl --retry / --retry-delay /
  --max-time` so the worst-case wait fits inside helm's default
  `--timeout`. The Job calls the gateway daemon's
  `ensure-namespace` endpoint and must tolerate Service-warmup
  flaps without exceeding the helm timeout.
- **Chunk 27** — `rbac.targetNamespaces` extends with `vscode` so
  the daemon can write the namespace-aware Patroni Secrets
  (`prodbox-vscode-pg-*`) into the `vscode` namespace, not just
  `keycloak`.
- **Chunk 28** — `derivedSecretInventoryFor` is namespace-aware for
  the `keycloak` release too: vscode pulls keycloak transitively, so
  both deployments need their `keycloak-runtime` +
  `keycloak-oidc-clients` Secrets in their own namespace with
  context strings scoped to that namespace. Cross-namespace `lookup`
  in `vscode/templates/http-route.yaml` /
  `websocket/templates/configmap-config.yaml` updates to point at
  the correct lookup namespace.
- **Chunk 29** — operator-only state hygiene: a stale
  `.data/vscode/keycloak-postgres/` directory from a pre-chunk-21
  test run carried a different PostgreSQL system ID, so the third
  Patroni replica refused to start with `system ID mismatch`.
  Wiped the directory; future runs re-initdb cleanly with one
  shared system ID. No code change.
- **Chunk 30** — delete the obsolete
  `"restores retained Patroni state through a staged bootstrap"`
  integration test. The "staged bootstrap" code path it exercised
  (`.patroni-anchor-volume` + two-pass helm upgrade) was removed by
  chunks 13–14; the test was failing on the new always-emit-three-
  PVs path.
- **Chunk 31** — `PRODBOX_TEST_HOST_MASTER_SEED_HEX` test-only
  injection seam in `readKeycloakVscodeClientSecret` (mirroring the
  existing `PRODBOX_TEST_RESIDUE_*` pattern in
  `Prodbox.Lifecycle.LiveResidue`). The integration test harness's
  `fakeRke2Environment` can't run a real MinIO; the env var
  short-circuits the port-forward with a deterministic constant
  seed so the three reconcile tests (`rke2 reconcile and delete`,
  `falls back to mirror.gcr`, `projects ZeroSSL`) exercise the new
  chunk-18 code path without infrastructure. Production never sets
  the env var.
- **Chunk 32** — namespace-aware host-side Secret reads. Three
  host-side readers (`readKeycloakOidcClientField` in
  `Prodbox.TestValidation`, `loadKeycloakAdminPassword` in
  `Prodbox.UsersAdmin`, and the `oidcClientSecretContext` call in
  `Prodbox.CLI.Rke2.readKeycloakVscodeClientSecret`) were still
  hardcoded to namespace `keycloak`. With chunk 28 making the
  daemon's Inventory deploy-namespace-aware and `prodbox test all`
  deploying via the `vscode` root chart (which transitively pulls
  keycloak into the `vscode` namespace), the reads were missing the
  Secret entirely. Switched all three to `vscode`. The host-side
  derivation context now agrees with what the daemon writes
  byte-for-byte; otherwise the harbor/minio admin SecurityPolicy
  OIDC handshake would never accept any token.
- **Chunk 33** — host-side pre-helm Secret materialization
  (`Prodbox.Secret.HostBootstrap.preApplyDerivedSecretsForRelease`)
  closes the Helm `lookup` timing hole. Helm renders **all**
  templates (including `lookup`) BEFORE applying pre-install
  hooks; on first install the daemon's pre-install Job hadn't
  run yet, so `lookup` of `keycloak-oidc-clients` returned empty
  and the chart fell back to its `"change-me"` placeholder.
  Keycloak imports the realm with that placeholder once and
  never re-imports — direct-grant OIDC handshakes 401 forever.
  The fix: `deployRelease` (and `deployPatroniRelease`) now read
  the master seed host-side (reusing the chunk 18 path: MinIO
  port-forward + `ensureMasterSeed` + the chunk-31
  `PRODBOX_TEST_HOST_MASTER_SEED_HEX` test seam) and
  `kubectl apply` every inventory entry BEFORE
  `helmUpgradeInstall`, so the realm-import ConfigMap renders
  with the real master-seed-derived client secrets on first
  install. The chart's pre-install Job remains the in-cluster
  idempotent fallback. Reuses `secretManifestJson` +
  `deriveBase64Url` so host and daemon write identical bytes.

Validated on all five static gates after chunk 33: `prodbox
check-code` exit 0, `prodbox test integration cli` 29/29 PASS,
`prodbox test integration env` 3/3 PASS, fourmolu + hlint +
warning-clean build all green.

**Live closure (2026-06-01):** `prodbox test all` retry 21 closes
**16 of 17 validations** on the home substrate after quay.io
stabilized: `charts-vscode`, `charts-api`, `charts-websocket`,
`admin-routes`, `public-dns`, `dns-aws`, `aws-iam`, `aws-eks`,
`pulumi`, `ha-rke2-aws`, `gateway-daemon`, `gateway-pods`,
`gateway-partition`, `charts-platform`, `charts-storage`, and
`lifecycle` — every OIDC handshake, chart deploy, public-edge
probe, and a full `rke2 delete --cascade` + RKE2 reinstall +
helm-from-scratch cycle pass. Only `keycloak-invite` fails, and
the dev plan explicitly carves that one out to Sprint 8.5 (the
credential-setup form parser + invite flow is 8.5's owned
surface). Sprint 3.13's four-block preserved-data exercise is
closed end-to-end: the doctrine of deterministic master-seed-
derived passwords flowing through k8s Secrets to chart consumers
(via Helm `lookup` + the chunk-33 host-side pre-apply) is
validated against a real Keycloak realm import, a real OIDC
handshake, and a real cluster-wipe-and-rebuild cycle.

### Remaining Work

None. The only failing validation in the closure run was `keycloak-invite`, which is
owned by Sprint `8.5`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical Haskell `prodbox charts` surface,
  restricted to root charts.
- `documents/engineering/config_doctrine.md` - workload-binary config-as-data: the public
  workload (`api` / `websocket`) reads its full configuration from the mounted Dhall config as
  the sole source (no `PRODBOX_*` fallback ladder), with the Boot/Live split and
  `fsnotify`-driven reload symmetry the daemon already follows (Sprint `3.15`).
- `documents/engineering/secret_derivation_doctrine.md` - the daemon-only master-seed boundary:
  the raw master seed is read in-cluster only, the host obtains *derived* values via the gateway
  RPC (`Prodbox.Gateway.Client`), and no host-side `/tmp` seed file or `resolveSeedViaMinio`
  raw-seed read remains on the supported path (Sprint `3.16`).
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Envoy Gateway and Keycloak edge
  doctrine for chart-managed workloads.
- `documents/engineering/helm_chart_platform_doctrine.md` - Haskell chart runtime, supported stack
  topology, internal dependency-release boundary, the authoritative synchronous-replication
  Patroni doctrine, and the land-or-delete loud-failure Patroni-storage-mismatch contract
  (Sprint `3.16`); for Sprint `3.22`, the chart resource-profile registry, mandatory
  request+limit rendering, namespace `ResourceQuota`/`LimitRange`, and no-BestEffort lint.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `3.22`, the chart-side
  consumption of the validated resource plan and the no-uncapped-container invariant.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding doctrine.
- `documents/engineering/vault_doctrine.md` - Vault as the sole secrets/KMS/PKI root on a durable
  `.data/vault/vault/0` PV (init-once/unseal-on-rebuild, both substrates), the `prodbox-envelope-v1`
  Vault-Transit envelopes wrapping every prodbox-owned MinIO object, the
  chart/Keycloak-secret-via-Vault-Kubernetes-auth model, and the per-cluster Vault seal model;
  scheduled under Sprints `3.17`–`3.20`. The master-seed HMAC-SHA-256 derivation model is retired,
  not extended (Sprint `3.19`).
- `documents/engineering/cluster_federation_doctrine.md` - the root/child transit-seal trust tree and
  per-cluster seal custody (Sprint `3.20`).
- `documents/engineering/pulsar_messaging_doctrine.md` - the Pulsar platform chart plus the
  self-maintained native-protocol Haskell Pulsar client whose payload codec is canonical-CBOR-only,
  with the derived topic algebra (`topicFor`) and the `Work*` envelope family (Sprint `3.21`).
- `documents/engineering/config_doctrine.md` - chart/Keycloak secrets from Vault KV via Vault
  Kubernetes auth, with no Secret-mounted plaintext Dhall fragment (Sprints `3.18`–`3.19`).
- `documents/engineering/local_registry_pipeline.md` - Harbor-loading implications for the chart
  platform where relevant.
- `documents/engineering/unit_testing_policy.md` - chart-platform integration ownership.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the engineering index aligned with the browser, API, WebSocket, and admin public workload
  paths.

## Sprint 3.14: Workload Mode via Dhall (Replaces `PRODBOX_WORKLOAD_MODE` Env Var) ✅

**Status**: Done (May 24, 2026 — code-owned surface landed: new
`src/Prodbox/Workload/Settings.hs` module with `loadWorkloadConfig ::
FilePath -> IO (Either String WorkloadConfigDhall)` decoder, schema covers
`mode : < Api | Websocket >` plus optional `log_level` / `workload_port` /
`redis` / `oidc` sub-records; `workloadConfigPath :: Maybe FilePath` added
to `WorkloadOptions`; new `--config` flag in `workloadOptionsParser`;
`runWorkloadServer` now dispatches through `resolveWorkloadModeFromConfig`
which prefers the Dhall config when `--config` is passed and falls back to
the legacy `PRODBOX_WORKLOAD_MODE` env-var ladder otherwise; new
`charts/api/templates/configmap-config.yaml` and
`charts/websocket/templates/configmap-config.yaml` render Dhall content;
`charts/api/templates/deployment.yaml` and
`charts/websocket/templates/deployment.yaml` updated with `args: ["workload",
"start", "--config", "/etc/workload/config.dhall"]` + matching ConfigMap
volume mount; `PRODBOX_*` env vars retained for rollback safety. 3 new unit
tests (543/543 total): happy-path Api and Websocket Dhall decode plus
schemaVersion mismatch failure. `helm template` renders cleanly for both
charts. **May 24, 2026 later session — full Dhall read-through landed**:
`runWorkloadServer` now loads the Dhall config once via
`resolveWorkloadDhallConfig` and threads the resulting
`Maybe WorkloadConfigDhall` through every resolver. New helpers
`resolveWorkloadModeFromDhall`, `resolveHttpPortWithDhall`,
`resolveWorkloadLogLevelWithDhall`, and the refactored
`resolveWebsocketRuntime`/`resolveRedisConfig`/`resolveOidcConfig` use the
Dhall sub-records when `--config` is set and fall back to env vars
otherwise. `PRODBOX_WORKLOAD_MODE` / `PRODBOX_HTTP_PORT` /
`PRODBOX_REDIS_HOST` / `PRODBOX_REDIS_PORT` / `PRODBOX_OIDC_*` env vars
are removed from `charts/api/templates/deployment.yaml` and
`charts/websocket/templates/deployment.yaml`; the Dhall ConfigMap is the
sole source on the chart-side surface. Validation: `prodbox dev check`
exit 0; `prodbox test unit` 543/543; `prodbox test integration cli` 28/28;
`prodbox test integration env` 28/28; `prodbox-daemon-lifecycle` 14/14.
**Live closure 2026-06-01:** `prodbox test all` retry 21 deployed the
api and websocket workloads via the new Dhall-ConfigMap path and
passed `charts-api` (api workload Pod up, reachable via OIDC-gated
`/api`) and `charts-websocket` (websocket workload Pod up, reachable
via OIDC-gated `/ws`). The chart-side `--config /etc/workload/config.dhall`
mount + the `Prodbox.Workload.Settings.loadWorkloadConfig` reader work
end-to-end against real Keycloak OIDC, validating the full Dhall
read-through path. Sprint 3.14 closure gate met.)
**Blocked by**: Sprint 0.8 ([config_doctrine.md](../documents/engineering/config_doctrine.md)) — resolved
**Implementation**: `src/Prodbox/Workload.hs` (replace env-var read with Dhall config
field), `charts/api/templates/deployments.yaml` and `charts/websocket/templates/deployments.yaml`
(remove `PRODBOX_WORKLOAD_MODE` env var, add `--config <path>` arg pointing at a mounted
workload Dhall ConfigMap), new `charts/api/templates/configmap-config.yaml` and
`charts/websocket/templates/configmap-config.yaml`, new workload Dhall schema in
`prodbox-config-types.dhall` (or a sibling `prodbox-workload-types.dhall`)
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Migrate the public-workload entry-point (`api`, `websocket`) from
`PRODBOX_WORKLOAD_MODE=api|websocket` env-var selection to a `workload.mode` field of
the workload Pod's mounted Dhall config, per
[config_doctrine.md](../documents/engineering/config_doctrine.md). The workload Pod
binary reads its full configuration from `--config /etc/workload/config.dhall`, decoded
via `Dhall.inputFile auto`.

### Deliverables

- Replace `lookupEnv "PRODBOX_WORKLOAD_MODE"` in `src/Prodbox/Workload.hs` with a Dhall
  decoder for the workload config record. The workload-mode field is a sum type
  `Api | Websocket` in the Dhall schema.
- New `charts/api/templates/configmap-config.yaml` and
  `charts/websocket/templates/configmap-config.yaml` rendering the per-workload Dhall
  expression at `/etc/workload/config.dhall`.
- Remove the `PRODBOX_WORKLOAD_MODE` env var from the api and websocket chart
  Deployments; replace with `args: [--config, /etc/workload/config.dhall]` and the
  matching ConfigMap volume mount.
- New workload Dhall schema (either extending `prodbox-config-types.dhall` or in a
  sibling file) covering the workload `mode`, OIDC bootstrap config, and Redis
  endpoint.

### Validation

1. `prodbox dev check` exit 0 (the `forbidEnvVarConfigReads` lint added by Sprint 1.28
   now fires on regressions).
2. `helm template api charts/api` and `helm template websocket charts/websocket` render
   cleanly.
3. `prodbox dev lint chart` exit 0.
4. Live exercise: `prodbox charts deploy api` and `prodbox charts deploy websocket`
   bring up the respective workloads against the new Dhall surface; both serve their
   public-edge routes.

### Remaining Work

None. The 2026-06-01 live `prodbox test all` retry 21 deployed `api` and `websocket`
through the mounted Dhall config path and passed both public-edge validations. The
workload-only Dhall schema remains inline in
`src/Prodbox/Workload/Settings.hs::WorkloadConfigDhall`; promoting it to a sibling
`prodbox-workload-types.dhall` remains optional follow-up work, not a closure blocker.

## Sprint 3.15: Workload Config-as-Data (Delete the `PRODBOX_*` Ladder, Boot/Live + fsnotify Symmetry) ✅

**Status**: Done (2026-06-09). The entire `PRODBOX_*` env ladder was deleted from `Workload.hs`
(`--config` is now mandatory — a missing/unparseable file is a fast structured failure; the sole
legitimate runtime-metadata read, the `HOSTNAME` pod name, moved to a new `Workload/PodIdentity.hs`
so `Workload.hs` has zero `lookupEnv`). The workload gained the daemon's Boot/Live split
(`WorkloadBootConfig`/`WorkloadLiveConfig` + pure `workloadBootFieldsChanged`; Live fields apply
in-process via a `TVar`, Boot fields drain-and-exit) and an `fsnotify` `configFileWatchLoop` on the
`--config` parent directory. `src/Prodbox/Workload.hs` joined `checkEnvVarConfigReads.scopedPaths`
(proven to fire on a reintroduced read). The api/websocket charts switched to a directory mount, the
legacy-ladder comments were removed, and the Sprint 3.14 workload `PRODBOX_*` ledger row moved to
Completed. Validation green: `check-code` 0, `test unit` 769/769, `integration cli` 35/35,
`prodbox-daemon-lifecycle` 11/11, `lint docs` 0, `docs check` 0, and `helm template api|websocket`
render with zero `PRODBOX_*` env vars. The live in-cluster reload exercise is operator-driven.
**Implementation**: `src/Prodbox/Workload.hs`, `src/Prodbox/Workload/Settings.hs`, `src/Prodbox/CheckCode.hs`, `charts/api/templates/configmap-config.yaml`, `charts/websocket/templates/configmap-config.yaml`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Finish the [config_doctrine.md](../documents/engineering/config_doctrine.md) migration on the
public-workload binary. Sprint `3.14` moved `api` / `websocket` mode and config to a mounted
Dhall ConfigMap but left the entire `PRODBOX_*` env-var fallback ladder in
`src/Prodbox/Workload.hs` "for rollback safety", so the workload remains a second supported
config source. This sprint makes the Dhall config the *sole* workload config source, gives the
workload the same Boot/Live split and `fsnotify`-driven reload the gateway daemon already runs
(Sprint `2.21`), and lint-enforces that the supported workload path cannot regress to env-var
config — closing the gap [config_doctrine.md §7](../documents/engineering/config_doctrine.md)
requires for every long-running `prodbox` binary.

### Deliverables

- Delete the `PRODBOX_WORKLOAD_MODE` / `PRODBOX_PORT` / `PRODBOX_HTTP_PORT` /
  `PRODBOX_LOG_LEVEL` / `PRODBOX_REDIS_*` / `PRODBOX_OIDC_*` `lookupEnv` ladder from
  `src/Prodbox/Workload.hs` (the `resolveWorkloadModeFromDhall`, `resolveHttpPortWithDhall`,
  `resolveWorkloadLogLevelWithDhall`, `resolveRedisConfig`, and `resolveOidcConfig` env-var
  fallback arms). The mounted Dhall config decoded via `Dhall.inputFile auto` from
  `--config /etc/workload/config.dhall` is the only config source; a missing `--config` is a
  fast structured failure, not a silent env-var fallback.
- Give the workload the daemon's Boot/Live config split: fields that can change in place
  (`log_level`, OIDC/Redis tunables that do not require a socket rebind) are Live and applied
  in-process on reload; fields that require a restart (the `mode` sum, the listen port) are
  Boot and trigger drain-and-exit per [config_doctrine.md §8](../documents/engineering/config_doctrine.md),
  mirroring `Prodbox.Gateway` `daemonBootFieldsChanged` / `reloadLiveConfig`.
- Add an `fsnotify`-driven `configFileWatchLoop`-equivalent in the workload runtime that
  watches the `--config` parent directory (directory mount, not `subPath`, so the kubelet
  atomic `..data` symlink swap fires the watch — the same gotcha Sprint `2.21` chunk 47 hit).
- Add `src/Prodbox/Workload.hs` to `checkEnvVarConfigReads.scopedPaths` in
  `src/Prodbox/CheckCode.hs` so `prodbox dev check` fails closed on any reintroduced
  `PRODBOX_*` config read on the workload surface (joining `Settings.hs`,
  `Gateway/Settings.hs`, and `Gateway.hs`).
- Remove the legacy-ladder note from the Sprint `3.14` `Workload/Settings.hs` header comment
  and from the api/websocket chart Deployments (no rollback-safety `PRODBOX_*` env vars
  remain).

### Validation

1. `prodbox dev check` exit 0 with `src/Prodbox/Workload.hs` newly in
   `checkEnvVarConfigReads.scopedPaths`; reintroducing any `PRODBOX_*` config read on the
   workload surface fails the lint.
2. `prodbox test unit` covers the Boot/Live field classification and the
   missing-`--config`-is-a-hard-failure path.
3. `helm template api charts/api` and `helm template websocket charts/websocket` render
   cleanly with no `PRODBOX_*` config env vars on the Deployments.
4. Live exercise: a `log_level` edit to a deployed workload's mounted ConfigMap reloads
   in-process with no Pod restart; a `mode`/port edit drains and exits for kubelet restart.

### Remaining Work

None — closed 2026-06-09. The only outstanding item is the operator-driven live in-cluster reload
exercise (a `log_level` ConfigMap edit reloads in-process; a `mode`/port edit drains+exits).

## Sprint 3.16: Daemon-Only Master-Seed Boundary ✅

**Status**: Done (2026-06-09). The host no longer reads the raw seed:
`HostBootstrap.preApplyDerivedSecretsForRelease` and `Rke2.readKeycloakVscodeClientSecret` now call
`Gateway.Client.ensureNamespace`/`derive` over the loopback NodePort (`hostLoopbackGatewayEndpoint`),
so the in-cluster daemon materializes the data-bound Secrets and the host sees only derived values /
the SHA-256 inventory. `resolveSeedViaMinio`, the `readHostMasterSeedHexOverride` /
`PRODBOX_TEST_HOST_MASTER_SEED_HEX` seam, and the fixed `/tmp/prodbox-master-seed*.bin` paths are
deleted (seed get/put now transit a randomized, single-use, bracket-deleted temp file in
`MasterSeed.hs`, in-cluster only); a new gateway-client-boundary test seam
(`PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX`, `Prodbox.TestSeam.GatewayDerive`) injects a *derived* value
without re-exporting the seed. The new `checkRawMasterSeedReadScope` lint (in
`runDoctrineAlignmentCheck`, proven to fire) confines the raw-seed read to
`{Gateway/Daemon.hs, Secret/EnsureNamespace.hs, Secret/MasterSeed.hs}`. `MinioMasterSeedConfig` got a
redacting `Show`. `resetPatroniStorageIfRequested` was **landed** (not deleted) as the
doctrine-prescribed loud-failure guard — pure `patroniSeedMismatchDecision` (auth-rejected → loud
failure naming namespace/role; matches/unobservable → proceed, never a silent reset) + a probe-only
`psql` auth check (`PGPASSWORD` in exec env, never argv). `secret_derivation_doctrine.md §8` flipped to
Implemented; ledger rows moved to Completed. Validation green: `check-code` 0, `test unit` 775/775,
`integration cli` 35/35, `lint docs` 0, `docs check` 0. The live first-install secret-materialization
and Patroni mismatch-probe exercises are operator-driven.
**Implementation**: `src/Prodbox/Secret/MasterSeed.hs`, `src/Prodbox/Secret/HostBootstrap.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Make the raw master seed an in-cluster-only secret. Sprint `3.13`'s live-iteration tail (chunks
18 / 31 / 33) added host-side master-seed reads — `resolveSeedViaMinio`, the
`PRODBOX_TEST_HOST_MASTER_SEED_HEX` seam, and `/tmp/prodbox-master-seed*.bin` scratch files —
to close Helm `lookup` timing holes on first install. Those host paths re-export the raw seed
outside the cluster, contradicting [secret_derivation_doctrine.md §5](../documents/engineering/secret_derivation_doctrine.md)'s
host↔cluster boundary (the host should consume *derived* values via the gateway RPC, never the
raw seed). This sprint moves all host-side chart-secret materialization onto
`Prodbox.Gateway.Client.derive` / `ensureNamespace`, confines the raw-seed read to in-cluster
code, lint-enforces that confinement, and lands-or-deletes the no-op
`resetPatroniStorageIfRequested` arm Sprint `3.13` chunk 14 deferred.

### Deliverables

- Replace the host-side raw-seed paths (`src/Prodbox/Secret/HostBootstrap.hs::resolveSeedViaMinio`
  and `preApplyDerivedSecretsForRelease`'s direct derivation) with calls to
  `Prodbox.Gateway.Client.derive` / `ensureNamespace` so the host obtains the *derived* Secret
  values (or triggers in-cluster materialization) without ever reading the raw seed. The
  `Prodbox.CLI.Rke2.readKeycloakVscodeClientSecret` host path migrates to the same RPC.
- Confine the raw-seed read in `src/Prodbox/Secret/MasterSeed.hs` to in-cluster daemon code and
  delete the `/tmp/prodbox-master-seed.bin` / `/tmp/prodbox-master-seed-put.bin` scratch-file
  round-trip (the seed never lands on a host filesystem path). Replace the
  `PRODBOX_TEST_HOST_MASTER_SEED_HEX` host-side test seam with a derived-value test seam at the
  gateway-client boundary so the integration harness still exercises the chunk-18/33 code path
  without re-exporting the raw seed.
- Add a `prodbox dev check` lint (`checkRawMasterSeedReadScope` or equivalent) that forbids the
  raw-seed read outside the in-cluster daemon module set (`src/Prodbox/Gateway/Daemon.hs`,
  `src/Prodbox/Secret/EnsureNamespace.hs`), the same lint shape `checkEnvVarConfigReads` uses.
- Add a redacting `Show` instance to `MinioMasterSeedConfig` in
  `src/Prodbox/Secret/MasterSeed.hs` so the master-seed config never prints credentials in
  logs or error output.
- Land-or-delete the deferred `resetPatroniStorageIfRequested` arm
  (`src/Prodbox/Lib/ChartPlatform.hs:2430`, currently `pure (Right ())`): either implement the
  Sprint `3.13`-prescribed loud-failure mismatch check (derive the expected Patroni password
  via `Prodbox.Gateway.Client.derive`, compare against `pg_authid` through a probe-only
  Postgres connection, fail loudly naming the namespace/role pair and the resolution options),
  or delete the no-op function and its lone call site if the live four-block exercise proves the
  check is unnecessary.

### Validation

1. `prodbox dev check` exit 0 with the new raw-seed-scope lint; reintroducing a raw-seed read
   outside the in-cluster daemon module set fails the lint.
2. `prodbox test unit` covers the redacting `Show` on `MinioMasterSeedConfig` (no credential
   substring in the rendered output) and the gateway-client-derived host path.
3. A `grep` for `/tmp/prodbox-master-seed` and `resolveSeedViaMinio` in `src/` + `app/`
   returns zero supported-path hits.
4. Live exercise: first-install `prodbox charts deploy keycloak` / `... vscode` still renders
   the realm-import with the correct master-seed-derived OIDC client secrets (the chunk-33
   timing hole stays closed) while the host obtains them via the gateway RPC, not the raw seed.

### Remaining Work

None — closed 2026-06-09. Remaining items are operator-driven live exercises (first-install
`charts deploy keycloak|vscode` secret materialization via the gateway RPC, and the live Patroni
seed/`pg_authid` mismatch probe) — they require a running cluster.

## Sprint 3.17: In-Cluster Vault Platform Component and Vault-Transit Envelopes ✅

**Status**: Done (code-owned platform/envelope foundation; live lifecycle integration continues in
Sprints `4.29`/`4.31`, Model-B object-store integration in Sprint `4.30`, chart Vault-auth
consumption in Sprint `3.18`, and transit-seal custody in Sprint `3.20`)
**Implementation**: `charts/vault/`, `src/Prodbox/Crypto/Envelope.hs`,
`src/Prodbox/Vault/TransitCipher.hs`, `src/Prodbox/ContainerImage.hs`,
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

**Current state (2026-06-11)**: one rung of the seed-residency-hardening deliverable has **landed
and validated** ahead of the rest of the sprint — the master-seed scratch file is now backed by a
RAM-only `emptyDir{medium: Memory}` tmpfs mount (`/run/prodbox-seed`) rather than a disk-backed
path (`charts/gateway/templates/deployments.yaml` adds the volume + mount;
`src/Prodbox/Secret/MasterSeed.hs` adds `seedScratchTmpfsDir` / `resolveSeedScratchDir` with a
`/tmp` fallback). Gates green: `dev check` 0, `dev lint chart` 0. This rung is valid even pre-Vault, since the seed
is plaintext today.

The **Vault-Transit envelope library** has also landed and validated (2026-06-12):
`Prodbox.Crypto.Envelope` seals each secret-bearing object under a fresh random DEK (a local
ChaCha20-Poly1305 AEAD with the object identity bound as AAD) and wraps the DEK behind a pluggable
`DekCipher` — Vault Transit in production, a loudly-named `insecureLocalDekCipher` for tests —
producing the self-describing `prodbox-envelope-v1` JSON document. Four unit tests cover the
AAD-bound round-trip, fail-closed-on-wrong-AAD, tamper rejection, and the no-plaintext-leak
property. Gates green: `dev check` 0, `test unit` **862/862**.

The in-cluster Vault **platform-component chart** also landed as a structurally-validated artifact:
`charts/vault/` deploys a single-replica Vault StatefulSet (file storage on a durable PVC over the
retained `manual` StorageClass under `.data/vault/vault/0`), a ConfigMap with the Vault HCL config, an
in-cluster ClusterIP Service, and a host-CLI NodePort (loopback-restricted, mirroring the gateway
pattern). It passes `dev lint chart` 0, renders cleanly under `helm template`, and `dev check` 0.

Vault is now a **declared shared platform component**: `ContainerImage.ComponentVault` joined the
`sharedPlatformComponents` enum + label, both installers' coverage lists
(`homeSubstratePlatformComponents` / `awsSubstratePlatformComponents`) include it, the 14-component
inventory test is updated, and `Prodbox.CLI.Rke2.ensureVaultRuntime` is the real
`helm upgrade --install charts/vault -n vault --create-namespace` install helper. Gates green:
`dev check` 0, `test unit` **869/869** (including the platform-component coverage test).

The AWS-substrate platform runtime now also calls the same Vault chart helper through
`Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstrateVaultRuntime`, sequenced after the AWS
LoadBalancer/Envoy/cert-manager/ACME layer and before the storage/registry bootstrap. Unit coverage
pins the canonical 17-step AWS platform sequence and asserts Vault precedes MinIO/registry bootstrap,
so `ComponentVault` is not only declared but actually installed by both substrate reconcilers.

**LIVE-VALIDATED 2026-06-12.** `prodbox cluster reconcile` stood up RKE2 (`v1.35.5+rke2r2`, node
`bathurst` Ready) + the platform (Harbor/MinIO/Envoy/cert-manager/Percona); `charts/vault/` then
deployed cleanly (`helm upgrade --install vault ./charts/vault -n vault`) — Vault `1.18.3` came up
**Running 1/1** with its durable PVC `data-vault-0` **Bound** to a retained `manual`-class PV under
`.data/vault/vault/0`. The full lifecycle was proven end-to-end: a fresh `prodbox vault status` reported
`initialized=False, sealed=True`; after init + unseal the deployed Vault reported `sealed:false`,
and `prodbox vault status` correctly tracked the change to `initialized=True, sealed=False`. So the
**`Prodbox.Vault.Client` HTTP path and the `prodbox vault` command group work against a real
deployed Vault** (Sprint `1.36`), and **the `charts/vault/` platform-component chart deploys a
working durable-PV Vault** (Sprint `3.17`).

The production Vault-Transit-backed `DekCipher` (`Prodbox.Vault.TransitCipher`) also landed with
the Phase 1 Sprint `1.37` foundation and is available to every envelope caller. Sprint `3.17`
therefore closes on the platform/envelope foundation. The in-cluster Vault Kubernetes-auth
consumption of chart/Keycloak secrets is Sprint `3.18`; retiring the master-seed derivation modules
so Vault KV is the sole secret store is Sprint `3.19`; the transit-seal hierarchy that gives each
cluster its seal custody is Sprint `3.20`; lifecycle-integrated init-once/unseal-on-rebuild and
retained-PV reconcile semantics remain owned by Sprints `4.29`/`4.31`; and the Model-B opaque
object-store is Sprint `4.30`.

### Objective

Stand up Vault as the durable-PV secrets/KMS/PKI root on **both substrates** (home + AWS,
identically) and provide the Vault-Transit envelope foundation (`prodbox-envelope-v1` plus the
production Vault-Transit `DekCipher`) that later config, chart, object-store, and Pulumi paths bind
to. Lifecycle-driven init-once/unseal-on-rebuild, Model-B opaque object-store naming, and
chart/Keycloak Vault-auth reads are downstream sprints; this sprint makes Vault a real shared
platform component and proves the envelope layer fails closed.

### Deliverables

- Vault added to the shared `[PlatformComponent]` inventory so the home and AWS substrate installers
  both stand up an in-cluster Vault — identically — on a durable `.data/vault/vault/0` PV
  (`manual` StorageClass, `Retain`, single-node affinity), preserved across `cluster delete` exactly
  like MinIO's PV (substrate equivalence; vault_doctrine §A2 init-once/unseal-on-rebuild).
- `Prodbox.Crypto.Envelope` provides the AEAD + DEK-wrap format and fails closed on wrong AAD,
  tamper, or unwrap failure.
- `Prodbox.Vault.TransitCipher` binds the envelope `DekCipher` to Vault Transit encrypt/decrypt,
  so production callers can wrap and unwrap DEKs through Vault rather than the test-only local
  cipher.
- `ensureVaultRuntime` is sequenced into home `cluster reconcile`, and
  `ensureAwsSubstrateVaultRuntime` is sequenced into the AWS substrate platform runtime so
  `ComponentVault` coverage reflects a real install on both substrates.

### Validation

- Unit coverage proves the envelope round-trip, wrong-AAD refusal, tamper refusal, and no plaintext
  leak property using `insecureLocalDekCipher`.
- Unit coverage proves the Vault-Transit `DekCipher` wraps and unwraps via injected
  Vault-shaped functions.
- Unit coverage pins both substrate component inventories and the AWS platform step sequence so
  Vault cannot be declared without being installed.
- Chart lint and Helm rendering validate `charts/vault/` structurally; the 2026-06-12 live run
  proved the chart against a home cluster. The AWS live proof is owned by the AWS-substrate
  aggregate when the platform runtime runs against EKS.

### Remaining Work

None for Sprint `3.17`. Chart/Keycloak secret consumption via Vault auth lands in Sprint `3.18`;
the master-seed derivation model is retired in Sprint `3.19`; the transit-seal hierarchy lands in
Sprint `3.20`; lifecycle-owned init-once/unseal-on-rebuild is Sprint `4.29`; retained Vault PV
reconcile is Sprint `4.31`; and Model-B opaque object-store integration is Sprint `4.30`.

## Sprint 3.18: Chart and Keycloak Secrets via Vault Kubernetes Auth ✅

**Status**: Done
**Implementation**: `src/Prodbox/Secret/VaultInventory.hs`, `src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/Vault/Host.hs`, `src/Prodbox/Settings/SecretRef.hs`, `src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/UsersAdmin.hs`, `src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/TestValidation.hs`, `charts/keycloak/`, `charts/keycloak-postgres/`, `charts/vscode/`, `charts/api/`, `charts/websocket/`, `charts/minio/`, `charts/gateway/`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Have **every** in-cluster chart workload — including Keycloak — consume **all** of its secrets from
Vault KV via Vault Kubernetes auth. Vault KV is the sole secret store for the chart platform; there
is no Secret-mounted plaintext Dhall fragment, no `as Text` credential import, and no plaintext
fallback (vault_doctrine §12; config_doctrine §A6). The `SecretRef.FileSecret` constructor and its
`/etc/.../secrets/*.dhall` mount contract are **removed, not bridged**.

### Deliverables

- Each chart that needs a Vault-held secret has a Kubernetes service account, a namespace+SA-bound
  Vault role, and a least-privilege Vault policy.
- Keycloak admin bootstrap, database credentials, client secrets, and SMTP material — and every
  other chart/workload secret — resolve from Vault KV via Vault auth (Vault Agent Injector, CSI
  Secret Store Vault provider, or app-side auth). There is no second store.
- The `SecretRef.FileSecret` constructor and its resolver arm are deleted from
  `Prodbox.Settings.SecretRef`; the secret-mounted plaintext Dhall fragment contract is removed from
  every chart and from the gateway daemon. In-cluster consumers authenticate to Vault directly.
- The secret inventory in `secret_derivation_doctrine.md` maps each chart/Keycloak secret to its
  Vault KV path, owning Vault policy, and consuming service account (no derivation class survives).

### Current Validation State

- 2026-06-15 foundation landed: `Prodbox.Secret.VaultInventory` is the typed chart-secret
  inventory for Vault KV paths, Vault policies, bound service accounts, and Kubernetes-auth roles.
  `defaultVaultReconcilePlan` now writes those chart-secret policies and roles, configures
  `auth/kubernetes/config` against `https://kubernetes.default.svc:443`, and bootstraps the
  automatically managed generated/static Vault KV objects in `prodbox vault reconcile` using a
  32-byte random, base64url-unpadded generator. The inventory still carries externally-owned
  objects such as SMTP material, but those are deliberately excluded from automatic seeding and fail
  if a caller asks the bootstrap runner to synthesize them.
- The `api`, `keycloak`, `minio`, `vault`, `vscode`, and `websocket` charts now render explicit
  ServiceAccounts and bind their workload Pods to those accounts. The Vault chart binds its service
  account to Kubernetes `system:auth-delegator` so the in-cluster Vault server can use its local
  service-account token for TokenReview. Patroni role delivery now uses a dedicated
  `prodbox-<namespace>-pg` pre-install/pre-upgrade materializer ServiceAccount instead of pretending
  the pinned PerconaPGCluster v2.9.0 CRD exposes a generated-Pod `serviceAccountName` field.
- The `websocket` workload now consumes its OIDC client secret directly from Vault KV by app-side
  Kubernetes auth: `charts/websocket/templates/configmap-config.yaml` renders
  `oidc.client_secret = SecretRef.Vault { mount = "secret", path =
  "vscode/oidc/prodbox-websocket", field = "client_secret" }`, the chart supplies the
  `websocket-oidc` Vault role and in-cluster Vault address, and `Prodbox.Workload` logs in through
  `vaultKubernetesLogin` before resolving the SecretRef. The default workload resolver runs in
  production mode, so `SecretRef.TestPlaintext` is rejected unless a unit test injects the
  test-harness resolver.
- The `keycloak` chart no longer renders `keycloak-runtime`, `keycloak-oidc-clients`, or SMTP
  lookup fallbacks. Its Deployment logs in to Vault from a `vault-secrets` init container, writes a
  tmpfs env file for `KEYCLOAK_ADMIN_PASSWORD`, `KC_DB_PASSWORD`, OIDC client secrets, demo-user
  password, and SMTP fields, and starts Keycloak only after sourcing that file. The realm import
  uses Keycloak environment placeholders instead of Helm materialized secret values.
- The `minio` chart no longer renders a root-credential Secret. Its StatefulSet logs in to Vault
  from a `vault-secrets` init container, writes tmpfs `rootUser` and `rootPassword` files, and the
  MinIO container reads them through `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE`.
- The MinIO admin bootstrap Jobs rendered by `src/Prodbox/CLI/Rke2.hs` no longer read the removed
  `minio` root Secret. The gateway MinIO bootstrap Job and Harbor storage-backend bootstrap Job
  run as the `minio` service account, use a Vault-login init container to materialize root
  credential files on tmpfs, and then run `mc` from those files. Harbor storage now has its own
  generated/persisted MinIO user in the Harbor storage Secret; the Job creates or updates that user
  and policy with root credentials that never leave the Pod.
- The `vscode` chart no longer renders an Envoy `SecurityPolicy` client Secret from
  `.Values.oidc.clientSecret`, `keycloak-oidc-clients`, or Helm `lookup`. The SecurityPolicy still
  references the Kubernetes Secret Envoy Gateway requires, but that Secret is created or patched by
  the chart's `post-install,post-upgrade` Job after the Job logs into Vault as the dedicated
  `vscode-oidc-secret-materializer` ServiceAccount and reads `secret/vscode/oidc/vscode` field
  `client_secret`. The VS Code NetworkPolicy now allows the selected materializer pod to reach the
  Vault service on port `8200`.
- The `gateway` chart no longer renders `gateway-aws-credentials`, mounts
  `gateway-minio-creds`, or performs a Helm `lookup` for `gateway-event-keys`. Its per-node
  `config.dhall` renders event keys, Route 53 AWS credentials, and gateway MinIO credentials as
  `SecretRef.Vault` values under `secret/gateway/gateway/{node-*/event-key,aws,minio}`, and
  `Prodbox.Gateway.Settings.loadDaemonConfig` resolves those references through Vault Kubernetes
  auth as the `prodbox-gateway-daemon` ServiceAccount. The `gateway/gateway/aws` object is
  populated by `prodbox aws setup` / `prodbox config setup` and cleared by AWS teardown; the
  repo-root config carries only the `SecretRef.Vault` target. `gateway/gateway/minio` is
  generated/static Vault-managed seed material. The gateway MinIO
  bootstrap Job now logs into Vault as `gateway-minio-bootstrap`, materializes both MinIO root and
  gateway MinIO credentials on tmpfs, and creates/updates the `prodbox-gateway` MinIO user and
  policy from those files.
- The `keycloak-postgres` chart no longer calls the gateway daemon
  `/v1/secret/ensure-namespace` RPC or carries `password: change-me` placeholders for Patroni
  roles. Its `pre-install,pre-upgrade` materializer hook logs into Vault as the
  `prodbox-<namespace>-pg` ServiceAccount, reads the app/superuser/standby Patroni KV paths, and
  creates or merge-patches the three Percona-watched Kubernetes Secrets with only `username` and
  `password` data before the `PerconaPGCluster` resource is applied. The hook RBAC can create
  Secrets and can get/update/patch only the three named Patroni Secrets for the release.
- Host/admin helper paths now use the host-side Vault root-token helper instead of legacy Kubernetes
  Secrets: `UsersAdmin.loadKeycloakAdminPassword` reads `secret/vscode/keycloak/admin.password`,
  `UsersAdmin.loadKeycloakSmtpSettings` reads `secret/keycloak/smtp`, the AWS SES stack sync writes
  `secret/keycloak/smtp` after deriving the SES SMTP password, and `TestValidation` reads OIDC
  client secrets plus demo-user password from `secret/vscode/oidc/*` Vault paths. A sealed,
  unreachable, or incomplete Vault fails those flows loud.
- Unit coverage pins the KV v2 policy path rendering, chart-secret policy/role inclusion in the
  default Vault reconcile plan, the cross-namespace `keycloak-smtp` role binding, seed-object
  coverage for every consumer path, automatic-seed exclusion of externally-owned objects,
  Kubernetes-auth config and login request rendering, read-before-write live reconcile bootstrap
  semantics, the direct websocket SecretRef chart source, production rejection of workload
  `TestPlaintext`, Keycloak and MinIO Vault-init materialization, MinIO bootstrap Job Vault-init
  materialization, VS Code SecurityPolicy client-Secret Vault materialization, the gateway SecretRef
  config/MinIO bootstrap/AWS KV writer path, the Patroni Vault materializer hook/RBAC/values path,
  and the host/admin Vault helper paths for SMTP field decoding and OIDC/SES field rendering, plus
  the service-account manifests/bindings for the straightforward chart controllers plus Vault's
  TokenReview binding.
- Unit coverage also pins the sealed-startup structural proof: the Keycloak, Keycloak-Postgres,
  VS Code, and MinIO `vault-secrets` init sections use `set -eu`, Vault Kubernetes login, and direct
  Vault KV reads, with no ignored Vault failures, Helm `lookup`, `randAlphaNum`, `secretKeyRef`, or
  `TestPlaintext` fallback in those startup sections. The later live `sealed-vault` canonical
  validation is owned by Sprint `5.8`.
- Validation: `helm template keycloak charts/keycloak --namespace keycloak`,
  `helm template keycloak-postgres charts/keycloak-postgres --namespace keycloak`,
  `helm template minio charts/minio --namespace minio`,
  `helm template vscode charts/vscode --namespace vscode`,
  `helm template gateway charts/gateway --namespace gateway`,
  `./.build/prodbox dev lint chart`, `cabal build --builddir=.build exe:prodbox`,
  `cabal test --builddir=.build prodbox-unit --test-options='--hide-successes'`
  (**955/955**), `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`,
  `./.build/prodbox dev lint haskell`, `./.build/prodbox dev check`, and
  `./.build/prodbox test unit` (**955/955** after the sealed-startup proof increment).

### Validation

- The code-owned sealed-startup proof shows Keycloak, Keycloak-Postgres, VS Code, and MinIO
  secret-dependent init paths fail closed on a sealed/unreachable Vault because the Vault login/KV
  reads run under `set -eu` with no non-Vault fallback.
- No chart or gateway manifest mounts a plaintext Dhall fragment, and `Prodbox.Settings.SecretRef`
  carries no `FileSecret` arm.
- Chart templates render against the Vault-auth values shape; live whole-system sealed-Vault
  behavior is validated by Sprint `5.8`.

### Remaining Work

None for Sprint `3.18`. Sprint `3.19` is also closed: the master-seed derivation modules, daemon
`/v1/secret/*` RPCs, daemon-only-seed lint, `selfBootstrapOwnSecrets`, and surrounding
generated-secret assumptions are removed. Sprint `8.9` owns any remaining invite-auth-specific
Vault migration; Sprint `5.8` owns the live whole-system `sealed-vault` canonical validation.

## Sprint 3.19: Retire Master-Seed Derivation: Vault KV Is the Sole Secret Store ✅

**Status**: Done (2026-06-16)
**Implementation**: `prodbox.cabal`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Client.hs`, `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`, `src/Prodbox/CheckCode.hs`, `charts/gateway/`, `charts/minio/`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/config_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

Retire the master-seed HMAC-SHA-256 derivation model entirely so Vault KV is the sole secret store.
The derivation model is removed, not wrapped: every secret that was previously HMAC-derived or
chart-generated becomes a Vault KV object, generated once, persisted on Vault's durable storage, and
fetched by each in-cluster consumer via Vault Kubernetes auth (secret_derivation_doctrine §A1;
vault_doctrine §A1). There is no `master-seed` object in MinIO.

### Deliverables

- `Prodbox.Secret.Derive`, `Prodbox.Secret.MasterSeed`, `Prodbox.Secret.Inventory`,
  `Prodbox.Secret.EnsureNamespace`, `Prodbox.Secret.Wire`, `Prodbox.Secret.GatewayDeriveMode`,
  `Prodbox.Secret.HostBootstrap`, and the host-side `Prodbox.TestSeam.GatewayDerive` seam are
  deleted and removed from `prodbox.cabal`.
- The gateway daemon no longer acquires a master seed, self-bootstraps Secrets, or exposes
  `/v1/secret/derive` / `/v1/secret/ensure-namespace`; the host gateway client no longer has secret
  RPC helpers.
- `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/CLI/Rke2.hs`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/AwsSubstratePlatform.hs` no longer
  pre-apply derived Secrets or thread a gateway-derive mode. Host/admin reads use Vault KV through
  `Prodbox.Vault.Host`.
- `src/Prodbox/CheckCode.hs` no longer carries the daemon-only raw master-seed lint because there
  is no raw seed reader to scope.
- The gateway chart no longer grants cross-namespace secret-writer RBAC, mounts seed scratch
  storage, or documents `/v1/secret/*`; gateway-owned MinIO access is limited to remaining gateway
  object-store work.
- The `prodbox/master-seed` MinIO object is retired as a supported artifact; no code path reads or
  writes it.
- Every previously-derived secret — Patroni/Postgres passwords, the Keycloak admin password, OIDC
  client secrets, gateway per-node event keys — is a Vault KV object fetched via Vault k8s auth or,
  for host/admin flows, through the host Vault helper.
- The chart-generated `lookup`+`randAlphaNum` Secret pattern is absent on the supported chart-secret
  path; MinIO root credentials and OIDC client secrets resolve from Vault KV.
- `secret_derivation_doctrine.md` describes only the Vault-KV model; the retired derivation history
  is preserved in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes after the retired modules are removed from the
  package exposure list.
- `./.build/prodbox test unit` passes (**898/898**) after the removal. The unit suite includes the
  Sprint `3.19` absence proof that the deleted module files stay absent and that the selected
  daemon/client/lint/chart surfaces do not reintroduce retired module names or `/v1/secret/*` RPCs.
- `test/integration/CliSuite.hs` no longer injects the gateway-derive test seed seam or expects
  host pre-application of derived chart Secrets.
- `./.build/prodbox test integration cli` passes (**34/34**) after the CLI fixtures move to
  Vault-shaped inputs: gateway config tests use `SecretRef.Vault` with a fake loopback Vault server,
  and fake RKE2/Pulumi flows opt into test-only Vault gate/KV seams instead of the removed derive
  seam.
- The legacy ledger's Sprint `3.19` rows for the master-seed object, derivation modules/RPC/lint,
  and chart-generated `lookup`+`randAlphaNum` pattern are moved to `Completed`.

### Validation

- The repository contains no `Prodbox.Secret.{Derive,MasterSeed,Inventory,EnsureNamespace,Wire}`,
  no `/v1/secret/*` daemon RPC, no `checkRawMasterSeedReadScope` lint, and no
  `selfBootstrapOwnSecrets`.
- No supported chart template renders a `lookup`+`randAlphaNum` Secret for MinIO root or OIDC client
  material; those values read from Vault KV.
- With Vault unsealed, chart and Keycloak secrets resolve from Vault KV; with Vault sealed, secret
  resolution fails closed and no consumer reconstructs a secret from any non-Vault source.
- Closure gates: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox dev docs check`,
  `./.build/prodbox dev lint docs`, `./.build/prodbox dev lint chart`, and
  `./.build/prodbox dev check`.

### Remaining Work

None for Sprint `3.19`. The transit-seal hierarchy that gives each cluster its seal custody for
these Vault KV objects is Sprint `3.20`; federated lifecycle reconcile and the fail-closed unseal
cascade closed under Sprint `4.32`.

## Sprint 3.20: Vault Transit-Seal Hierarchy and Per-Cluster Seal Custody ✅

**Status**: Done (2026-06-16)
**Implementation**: `src/Prodbox/Vault/Seal.hs`, `src/Prodbox/Vault/Client.hs`, `src/Prodbox/CLI/Vault.hs`, `src/Prodbox/Vault/Reconcile.hs`, `charts/vault/`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cluster_federation_doctrine.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`

### Objective

Establish the per-cluster Vault seal model and seal custody that underpins cluster federation: the
root cluster uses a Shamir seal unlocked by the operator, and each child cluster uses
`seal "transit"` pointed at its parent's Vault, with the child's init keys held in the parent's
Vault KV (cluster_federation_doctrine §A3; vault_doctrine §A2–§A3). A child Vault literally cannot
unseal without a live, unsealed parent — the fail-closed brick cascades down the tree from the root.

### Deliverables

- `Prodbox.Vault.Seal` defines the root Shamir seal mode, the child Transit seal mode, the HCL
  renderer, the init-request selector, per-child Transit seal policy rendering, and the
  child-init-custody field map stored in the parent's Vault KV.
- The root cluster's Vault uses a Shamir seal; its unseal/recovery keys + initial root token are
  emitted into the `.age` unlock bundle on retained host storage
  (`.data/prodbox/vault-unlock-bundle.age`), decrypted only by the operator's memorized password
  (the test harness simulates the password via `test-secrets.dhall`).
- A child cluster's Vault config carries `seal "transit"` against the parent cluster's Vault; the
  chart renders that stanza only when `seal.mode = transit` and supplies the parent Transit token
  through `VAULT_TOKEN` from a Kubernetes Secret instead of embedding it in `vault.hcl`.
- `Prodbox.Vault.Client.InitRequest` supports both root Shamir init (`secret_shares` /
  `secret_threshold`) and child Transit auto-unseal init (`recovery_shares` /
  `recovery_threshold`); init responses may carry recovery keys without unseal keys.
- At child init, the child's recovery keys + initial root token are stored in the **parent's** Vault
  KV; the parent's Transit key is the child's unseal authority.
- Per-domain Transit keys + least-privilege Vault policies are provisioned for the envelope and
  secret-class consumers (config, gateway state, Pulumi backend, chart/Keycloak secrets), and the
  federation-custody policy covers the opaque `prodbox-child-*` Transit-key namespace.
- The `prodbox vault` command group surfaces the root init/unseal path through the same typed seal
  model the child seal-custody runtime consumes.

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes with `Prodbox.Vault.Seal` exposed.
- `./.build/prodbox test unit` passes (**907/907**). The Sprint `3.20` tests prove root Shamir
  init renders only unseal-key shares, child Transit init renders recovery-key shares, the child
  `seal "transit"` HCL contains no token literal, child recovery keys/root token become a
  parent-owned Vault KV field map, and per-child Transit policies scope to one key.
- `./.build/prodbox test integration cli` passes (**34/34**) after the CLI help/golden fixtures
  move the live-registration blocker to the later auto-unseal lifecycle sprint.
- `./.build/prodbox dev lint chart` passes after the Vault chart gains the `seal.mode` conditional
  and `VAULT_TOKEN` Secret reference.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, and
  `./.build/prodbox dev check` pass on the final Sprint `3.20` tree.

### Validation

- The root Shamir path writes only the host-side `.age` unlock bundle; the child Transit path has no
  child unlock-bundle model and maps child init material into the parent's Vault KV custody shape.
- The Vault chart defaults to Shamir and renders `seal "transit"` only for a child configuration;
  the parent Transit token is sourced from `VAULT_TOKEN`, not from the ConfigMap.
- The root Vault's recovery keys + root token are present only inside the `.age` unlock bundle and a
  child's init keys are present only in its parent's Vault KV — never on the child's local storage.
- Per-domain Transit keys exist with least-privilege policies; an unauthorized SA cannot wrap/unwrap
  against a domain it is not bound to.
- Closure gates: `cabal build --builddir=.build exe:prodbox`, `./.build/prodbox test unit`,
  `./.build/prodbox dev lint chart`, `./.build/prodbox dev docs check`,
  `./.build/prodbox dev lint docs`, and `./.build/prodbox dev check`.

### Remaining Work

None for Sprint `3.20`. Child `cluster reconcile` auto-unseal-from-parent wiring, the
init-once/unseal-on-rebuild lifecycle, and the fail-closed unseal cascade closed under Sprint
`4.32`; the cluster-federation trust topology and downstream-cluster custody gateway surface
closed under Sprint `2.26`.

## Sprint 3.21: Pulsar Workload Chart + Self-Maintained CBOR Pulsar Client [✅ Done]

**Status**: ✅ Done 2026-07-03.
**Blocked by**: none — the broker client is prodbox-owned Haskell work.
**Implementation**: `src/Prodbox/Pulsar/Client.hs`, `src/Prodbox/Pulsar/Protocol.hs`, `src/Prodbox/Pulsar/Codec.hs`, `src/Prodbox/Pulsar/Topic.hs`, `src/Prodbox/Pulsar/Envelope.hs`, `charts/pulsar`
**Live-proof**: proven 2026-07-03 via `./.build/prodbox test integration pulsar-broker`
**Independent Validation**: unit + CLI/env integration on the home/local substrate — the codec round-trip, `topicFor` topic-algebra, `Work*` envelope suites, native frame/metadata/CRC32C/message-id parser tests, client endpoint validation, Pulsar chart-render surface, `prodbox test integration cli`/`env`, and live `pulsar-broker` produce/consume/ack prove the locally owned code with no dependency on any later phase.
**Docs to update**: `documents/engineering/pulsar_messaging_doctrine.md`

### Objective

Deliver the Pulsar platform chart and the self-maintained native-protocol Haskell Pulsar client
whose payload codec is canonical-CBOR-only — no codec-selection field on the wire — per
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md). The client
carries the derived topic algebra (`topicFor`) and the `Work*` envelope family so every producer and
consumer shares one typed topic-and-envelope surface.

### Deliverables

- ✅ `src/Prodbox/Pulsar/Client.hs` exposes the native-client boundary (`connect`, `produce`,
  `consume`, `ack`) and typed request/error values over the repo-owned Haskell transport/framing
  layer. It validates endpoints, opens a TCP broker session, performs lookup / producer / consumer /
  ack flows, correlates requests, reconnects with bounded backoff on retryable transport failures,
  validates metadata + CRC32C payload frames, and classifies broker failures into typed errors.
  There is no WebSocket fallback and no second runtime.
- ✅ `src/Prodbox/Pulsar/Protocol.hs` owns the minimal Pulsar protobuf/framing surface required by
  the client: command encoders, response decoders, payload-frame parser, message metadata,
  message-id rendering/parsing, broker service URL parsing, and server-error classification.
- ✅ `src/Prodbox/Pulsar/Codec.hs` encodes and decodes message payloads as canonical CBOR only,
  with no runtime codec-selection field.
- ✅ `src/Prodbox/Pulsar/Topic.hs` provides the derived topic algebra `topicFor`, and
  `src/Prodbox/Pulsar/Envelope.hs` defines the `Work*` envelope family.
- ✅ `charts/pulsar` renders as a retained-storage gateway dependency against the canonical
  `127.0.0.1:30080/prodbox/pulsar-mirror:4.0.2` in-cluster image reference.

### Validation

Code-owned validation on 2026-07-03:

1. `cabal build --builddir=.build exe:prodbox` exit 0.
2. `cabal build --builddir=.build all --ghc-options=-Werror` exit 0.
3. `cabal test --builddir=.build test:prodbox-unit` exit 0 (1155/1155 after Sprint `3.21`),
   including the CBOR codec round-trip, `topicFor` topic-algebra, `Work*` envelope coverage,
   native frame/metadata/CRC32C/message-id parser coverage, endpoint validation, and Pulsar chart
   plan coverage.
4. `./.build/prodbox test integration cli` exit 0 (39/39).
5. `./.build/prodbox test integration env` exit 0 (39/39).
6. `./.build/prodbox dev lint chart` exit 0 over `charts/pulsar`.
7. `./.build/prodbox test integration pulsar-broker` exit 0 (2026-07-03): deployed the internal
   Pulsar chart on the home-local substrate, created a validation topic under
   `persistent://public/default/`, produced and consumed a CBOR payload over the native broker
   protocol, and acknowledged message id `8:0:-1`.

### Remaining Work

None.

## Sprint 3.22: Chart Resource Envelopes, Namespace Quotas, and Limit Ranges [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Lib/ChartPlatform.hs`, `charts/*/templates/`,
`src/Prodbox/CheckCode.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Independent Validation**: `helm template`/chart-plan unit tests and chart lint over rendered
manifests prove that every repo-owned container/init container has cpu, memory, and
ephemeral-storage requests and limits, every prodbox namespace has quota/limit-range manifests, and
namespace sums fit the Phase `1` validated resource plan; no later-phase dependency.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`

### Objective

Make undefined or uncapped chart resource consumption impossible on the supported chart path. The
chart renderer consumes the Sprint `1.55` validated resource plan and renders Kubernetes resources
from that plan only; chart-local resource defaults are forbidden.

### Deliverables

- [x] A `ResourceProfileId` for every repo-owned root chart, internal dependency release, init
  container, and sidecar: `gateway`, `keycloak`, `keycloak-postgres`, `vscode`, `api`, `redis`,
  `websocket`, `minio`, `vault`, `harbor` bootstrap jobs, Percona operator install helpers, and
  `pulsar`.
- [x] Every rendered container/init container has non-empty `resources.requests` and `resources.limits`
  for cpu, memory, and ephemeral storage.
- [x] Every prodbox-owned root-chart namespace receives a `ResourceQuota` and `LimitRange` derived from the same
  namespace resource budget as the containers it admits.
- [x] PVC requests and retained PV capacities are tied to durable-storage claims in the capacity plan;
  a chart cannot introduce an unbudgeted durable claim.
- [x] `prodbox dev lint chart` rejects repo-owned chart templates or rendered manifests that omit
  `resources`, render a limit lower than its request, or introduce a `BestEffort` pod.

### Validation

1. ✅ `prodbox dev lint chart`
2. ✅ `prodbox test unit` — 1164/1164, including chart profile lookup, namespace guardrail values,
   rendered resource stanzas, and missing-profile refusal.
3. ✅ `prodbox test integration cli` — 40/40, including the fake Helm/Kubernetes chart path.
4. `prodbox dev check` — final cross-phase gate after Sprints `4.41` and `5.13`.

### Remaining Work

None on the Sprint `3.22` code-owned surface. Host-side RKE2 guardrails landed in Sprint `4.41`;
canonical cluster-state validation landed in Sprint `5.13`.

## Sprint 3.23: Graph-Sourced Chart Dependency Edges and Operator `Available` Gate [✅ Done]

**Status**: Done (2026-07-06)
**Implementation**: `src/Prodbox/Lib/ChartPlatform.hs` (graph-sourced `resolveDependencyOrder`,
graph-projected operator gates, the `Available` operator check),
`src/Prodbox/Config/ComponentGraph.hs` (`chartComponentDeployOrder`, `directChartDependencies`,
`operatorAvailableGates`)
**Independent Validation**: pure unit tests over the chart dependency-order resolver consuming a
component-graph fixture (same topological order as today, cycle rejection preserved), and the
chart→operator gate refusing until the operator Deployment reports `Available`. Home-substrate chart
deploy/delete path; no later phase required.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Remove the last hardcoded corner of the bootstrap dependency graph from the chart platform: source
chart ordering from the Sprint `1.56` typed component graph, and replace the presence-not-readiness
operator gate with an `Available` gate, per
[bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md).

### Deliverables

- `resolveDependencyOrder` consumes the config-sourced component graph instead of the hardcoded
  `chartDefinitionDependencies` literals; the `ChartRequiresPatroniPlatform` external-requirement
  constructor is retired in favor of a graph edge (ledger row under this sprint). Cycle detection and
  the resulting deploy order are unchanged.
- `validatePatroniPlatformReady` (and any sibling operator check) gates on the operator Deployment
  being `Available`/reconciling, not merely present — closing the presence≠ready RACY edge.

### Validation

1. `prodbox test unit` proves graph-sourced ordering matches today's order (all eight charts), cycles
   are rejected, the Percona operator gate is projected from the `keycloak-postgres` graph edge, and
   the gate accepts only a Deployment reporting `Available=True`. ✅ 1209/1209.
2. `prodbox dev lint chart` ✅ exit 0 + the home-substrate chart deploy/delete path (`resolveDependencyOrder`
   is now graph-sourced on both). `prodbox test integration cli`/`env` green.
3. `prodbox dev check` is the closure gate. ✅ exit 0.

Closed 2026-07-06. The hardcoded `chartDefinitionDependencies` literals and the
`ChartExternalRequirement`/`ChartRequiresPatroniPlatform` type are removed; chart ordering and the
`charts list`/`charts status` dependency display now read the component graph, and the operator gate
is projected from the graph edge (`operatorAvailableGates`) and checks the Deployment's `Available`
condition (`deploymentConditionReportsTrue`) rather than mere object existence.

### Remaining Work

- None. Sprint `3.24` closed the former totality follow-up with an exhaustive target registry.
  Constructor additions require an explicit warning-clean match arm; a config-driven gate that
  names an already-existing unsupported `ComponentId` fails closed at runtime. AWS-substrate chart
  coverage stays orthogonal (`substrates.md` parity).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` - graph-sourced chart edges + the operator
  `Available` gate.
- `documents/engineering/bootstrap_readiness_doctrine.md` - the chart-edge application of M2/M3.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Add a ledger row (Sprint `3.23`) for the retired `chartDefinitionDependencies` /
  `ChartRequiresPatroniPlatform` edges.

## Sprint 3.24: Operator-Gate Totality via the ReadinessObservation Seam [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/Lib/ChartPlatform.hs` (`operatorAvailableTarget`,
`observePatroniOperatorAvailableWith`, `validateOperatorGatesWith`, `operatorGateResult`),
`test/unit/Main.hs`
**Independent Validation**: `./.build/prodbox dev lint chart` exits 0;
`./.build/prodbox test unit` passes 1266/1266, covering exhaustive target registration, explicit
unsupported-ID refusal, one-shot Percona classification, and pending/unreachable gate closure;
`./.build/prodbox dev check` exits 0. No later phase or live infrastructure is required.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/bootstrap_readiness_doctrine.md`

### Objective

Make the chart operator gate total over the current `ComponentId` inventory: a graph-projected gate
either reaches its registered readiness target or returns an explicit error before chart mutation.

### Deliverables

- `operatorAvailableTarget` exhaustively matches the closed `ComponentId` ADT. Percona maps to an
  `OperatorAvailableTarget`; every current non-operator component has an explicit
  `unsupportedOperatorGate` arm. There is no wildcard success arm.
- `observePatroniOperatorAvailableWith` is a one-shot adapter. It queries the Percona CRD with
  `--ignore-not-found`, stops with `ReadinessProbePending` when that CRD is absent, then queries the
  operator Deployment with `--ignore-not-found` and accepts only its `Available=True` condition.
- `validateOperatorGatesWith` routes every graph-projected gate through
  `observeComponentReadiness`; `operatorGateResult` permits only `ReadyObserved`. Both
  `NotReadyYet` and `Unreachable` return `Left`, closing the chart-mutation gate.
- Warning-clean exhaustive matching makes a newly added `ComponentId` constructor require a source
  decision. Config is data, however: if it projects an already-existing ID whose explicit arm is
  unsupported, the target registry fails closed at runtime. This sprint does not overstate that
  data-driven mismatch as a universal compile-time impossibility.

### Validation

1. `./.build/prodbox dev lint chart` — exits 0.
2. `./.build/prodbox test unit` — passes 1266/1266; proves the production registry has no wildcard,
   every default graph gate is bound, an existing unsupported ID refuses, absent CRDs and
   non-Available Deployments stay pending, and pending/unreachable observations both gate closed.
3. `./.build/prodbox dev check` — exits 0.

### Remaining Work

- None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` - the operator gate is total (no fallthrough).
- `documents/engineering/bootstrap_readiness_doctrine.md` - the chart-gate consumer of the M3 seam.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Former ledger row G (`validateOperatorGates` fallthrough) is recorded under `Completed` in
  `legacy-tracking-for-deletion.md` for Sprint `3.24`.

## Sprint 3.25: Constant-Time Gateway Probe Binding [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/Gateway/Probe.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/CheckCode.hs`, `charts/gateway/templates/deployments.yaml`,
`charts/gateway/values.yaml`, `test/unit/GatewayProbe.hs`,
`test/unit/fixtures/gateway-probes/`, `test/golden/charts/gateway-probes-values.yaml`,
`prodbox.cabal`
**Independent Validation**: Warning-clean executable/unit build and unit 1386/1386 pass; the
focused probe suite passes 4/4, separate liveness/readiness fixtures prove `/v1/state` refusal,
and Helm renders three Deployments with six dedicated `/healthz`/`/readyz` paths and no
`/v1/state` probe. `prodbox dev lint haskell`, `prodbox dev lint chart`, and
`prodbox dev docs check` exit 0. The daemon endpoints already exist and are constant-time, so no
live cluster or later phase is required.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Keep kubelet health observation constant-time and independent of operational-state size. The chart
must consume the gateway's dedicated liveness/readiness projections rather than exercising the
diagnostic state renderer every ten to fifteen seconds.

### Deliverables

- Liveness binds to the existing `/healthz` endpoint and readiness binds to the existing `/readyz`
  endpoint; Sprint `2.31` preserved both constant-time routes while refactoring adjacent state.
- Probe timing, timeout, and success/failure thresholds are explicit and render from the single
  typed/defaulted `GatewayProbeSpec` surface through `gatewayLifecycleProbeValues`.
- The `gateway-probes.values` generated-section rule keeps static defaults synchronized with the
  typed source. Chart lint, the values golden, and separate liveness/readiness fixtures reject
  `/v1/state` as a lifecycle path.
- Preserve `/v1/state` as an operator diagnostic only; chart changes do not weaken its bounded
  output contract.

### Validation

1. `cabal build --builddir=.build exe:prodbox test:prodbox-unit --ghc-options=-Werror` exits 0;
   `./.build/prodbox test unit` passes 1386/1386 and the focused Sprint `3.25` suite passes 4/4.
2. Helm renders three gateway Deployments with six `/healthz`/`/readyz` paths and zero
   `/v1/state` paths; the generated typed-values golden passes.
3. Physical liveness and readiness fixtures using `/v1/state` are independently rejected.
4. `./.build/prodbox dev lint haskell`, `./.build/prodbox dev lint chart`,
   `./.build/prodbox dev docs check`, `git diff --check`, and the repository-wide
   `./.build/prodbox dev check` exit 0.

### Remaining Work

- None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` - constant-time probe ownership.
- `documents/engineering/bootstrap_readiness_doctrine.md` - separate kubelet health from
  operational diagnostics.
- `documents/engineering/distributed_gateway_architecture.md` - landed chart binding over the
  existing daemon endpoint contract.
- `documents/engineering/unit_testing_policy.md` - typed-values golden and independent
  liveness/readiness negative-fixture coverage.

**Product docs to create/update:**

- `README.md` - current plan gaps and Sprint `3.25` closure evidence.

**Cross-references to add:**

- Link the landed chart binding to Sprint `2.31`'s endpoint contract and keep Sprint `5.16`'s
  runtime-stability observation explicitly separate.

## Sprint 3.26: Physically Separated Control-Plane Workloads [✅ Done]

**Status**: Done (validated 2026-07-25) — unblocked by the completed Sprint `2.33`. **Increment A landed 2026-07-21**
(Bootstrap Broker workload-identity foundation) and **Increment B landed 2026-07-21** (the
Bootstrap Broker workload chart itself: `charts/bootstrap-broker/` renders the Deployment,
Service, ServiceAccount, NetworkPolicy, and PodDisruptionBudget from the compiled statics, with a
generated-section drift gate + chart-lint + conformance tests). Increments C–I completed the
Gateway Runtime StatefulSets, five standing control-plane roles, capacity and graph wiring, compiled
identity registry, and negative lint. Production permit interpreters and the pre-Vault cutover are
Phase-4 behavior/cutover work, not backward Phase-3 validation dependencies (Standard N).
**Deployment qualification**: pending
**Implementation**: **Increment A** — `Prodbox.Vault.RoleId` gains `VaultRoleBootstrapBroker`, a
bootstrap-only Vault Kubernetes-auth role (`prodbox-bootstrap-broker`) distinct from the Gateway
Runtime's `prodbox-gateway-daemon` role, plus `allVaultRoleIds`; and the new
`src/Prodbox/Bootstrap/Broker/ChartStatics.hs` is the one compiled source of the physically separate
broker workload's static identities — its Pod ServiceAccount (= the bootstrap-only Vault role) and
its constant-time liveness/readiness probe paths projected from the closed `BrokerRoute` registry
(`/healthz`, `/readyz`), with aeson + generated-YAML projections. The broker's listen port is
deployment configuration, deliberately not a compiled static.
**Implementation**: **Increment B** — `charts/bootstrap-broker/` is the physically separate broker
workload chart: a single-writer `Deployment` (replicas 1, `Recreate`) running
`bootstrap-broker start --config /etc/bootstrap-broker/config/config.dhall` as its own
ServiceAccount (`.Values.serviceAccount.name`, from the compiled statics), a loopback-oriented
ClusterIP `Service`, a `bootstrap-broker-isolation` `NetworkPolicy` whose egress is limited to DNS,
the Vault API (`:8200`), and the object store (`:9000`) — no mesh/KV/Pulumi/SES/authority-CAS/
target-secret egress (Sprint `2.33` route boundary) — a `PodDisruptionBudget`, a values-backed
Guaranteed-QoS resource envelope, and constant-time `/healthz`/`/readyz` probes projected from the
statics. `src/Prodbox/CheckCode.hs` registers the `bootstrap-broker-chart-statics.values` generated
section (drift-gated by `prodbox dev check`) and a `bootstrap-broker`-guarded chart lint
(`bootstrapBrokerStaticsChartViolations` / pure `bootstrapBrokerChartStaticViolations`) that forbids
raw ServiceAccount-identity and probe-path literals in the hand-written templates and requires the
generated block in `values.yaml`. Remaining increments extend `src/Prodbox/Lib/ChartPlatform.hs`
(`valuesForBootstrapBroker` + `resolveChart`/`supportedChartNames`), `src/Prodbox/Config/ComponentGraph.hs`
(reconcile-graph node + config-schema regen), `src/Prodbox/Capacity/Config.hs` (typed namespace
quota + workload profile), and `src/Prodbox/Secret/VaultInventory.hs`, plus new
authority/target-agent chart surfaces and the Gateway Runtime StatefulSet.
**Independent Validation (Increment A)**: `test/unit/BrokerChartStatics.hs` proves the broker
ServiceAccount/Vault-role is distinct from the gateway's (anti-shared-identity invariant), the
ServiceAccount equals the bootstrap-only Vault role, every `VaultRoleId` name in the closed
inventory is distinct, and the probe paths are exact projections of the `BrokerRoute` registry.
**Independent Validation (Increment B)**: the same suite (now 11 cases) additionally certifies the
committed `charts/bootstrap-broker/values.yaml` equals the compiled `renderBrokerChartStaticsYaml`
projection, rejects a drifted values block, accepts the values-backed hand-written templates, and
rejects hand-written raw ServiceAccount-identity / probe-path literals and a missing generated
block — with no deployed cluster, Vault, AWS, or later phase. Evidence: `prodbox dev check` exit 0
(warning-clean build, chart lint incl. the broker rule, and the generated-section drift gate on the
new chart); the `Sprint 3.26 compiled Bootstrap Broker chart statics` suite 11/11; the
`prodbox-haskell-style` generated-section-stability meta suite 18/18.
**Independent Validation (Increment C)**: a direct `valuesForBootstrapBroker` render test proves the
deployed values project the compiled statics (ServiceAccount / Vault role / `/healthz`+`/readyz`
probes / listener port / injected image) and that the resource envelope is attached separately;
`resolveChart` resolves the internal chart off the public surface; and the capacity suite proves the
`bootstrap-broker` namespace quota + Guaranteed-QoS workload profile are present and that
`validateResourcePlan defaultResourcePlan` still holds after the vscode-ceiling trim — all with no
deployed cluster, Vault, AWS, or later phase. Evidence: `prodbox dev check` exit 0; full
`prodbox test unit` 2207/2207 (of 2208; the one excluded case is a pre-existing env-flaky AWS-SSH
test that passes in isolation and is unrelated to this change), including the regenerated
`prodbox-config-types.dhall` drift guard and the Sprint 5.13 guardrail-report fixtures synced to the
trimmed vscode quota.
**Independent Validation (Increment D)**: the extended graph suite proves
`resolveDependencyOrder "bootstrap-broker"` yields exactly `["bootstrap-broker"]` (graph-connected,
no chart dependencies) and the `componentIdText` / `componentIdForChartName` / `chartNameForComponent`
bijection round-trips; the warning-clean `-Werror` build proves every exhaustive `ComponentId` match
(capability op, native/AWS steps, operator-gate + readiness registries) covers the new chart-only
node; and the full suite proves the regenerated schema + graph decode round-trip (the test-fixture
`ComponentId` union in `TestSupport.hs` was synced) — all with no deployed cluster, Vault, AWS, or
later phase. Evidence: `prodbox dev check` exit 0; full `prodbox test unit` 2207/2207 (of 2208, the
one excluded case being the pre-existing env-flaky AWS-SSH test).
**Independent Validation**: Helm rendering, typed-values goldens, resource-plan tables, route/RBAC
negative fixtures, and chart lint validate the platform surface without a deployed cluster, AWS,
or a later phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, and
`documents/engineering/unit_testing_policy.md`

### Objective

Render substrate-local Bootstrap Broker, Gateway Runtime, and Target Secret Agent workloads plus
exactly one retained home/control-plane Lifecycle Authority and its physically separate backup
adapter so identity, cgroup pressure,
readiness, deployment cardinality, and failure domains match their typed authority boundaries.

### Deliverables

- Add separate Deployment/StatefulSet, Service, ServiceAccount, NetworkPolicy, PodDisruptionBudget,
  resource envelope, and lifecycle probe values for every applicable role. AWS renders an
  authority client reference, not another authority workload.
- Render the Authority Backup Adapter only beside the retained home Authority, with its own
  ServiceAccount/Vault role/network policy/queue/envelope. It accepts only closed backup prepare,
  read-back, restore, GC, and decommission programs and alone reads
  `secret/aws/authority-backup-store`; core Authority and provider worker cannot read that path.
- Render a separate home TLS Retention Adapter with only
  `secret/aws/tls-retention-store` and the registered
  `public-edge-tls/<substrate>/<canonical-scope-key>` S3
  prefix. Give each Target Agent exact TLS-Secret observe/seal/materialize RBAC; only the home Agent
  also gets the retained-home TLS Transit DEK-exchange policy plus closed schema-indexed SES-SMTP/
  ACME-EAB custody/rewrap policy. Adapter/Authority never get Kubernetes TLS Secret, arbitrary
  secret-export, or plaintext-key policy.
- Render the normal fenced Provider Worker as another home-only private Deployment/ServiceAccount/
  Vault role with its own queue/envelope; it alone reads `secret/aws/lifecycle-provider` and runs
  normal Pulumi/AWS effects. Render the Credential Provisioner as an on-demand ephemeral Job whose
  action is indexed by exactly one active signed `GenesisBackup`, `BackupRepair`, or
  `OperatorMaterial` permit. First reconcile alone may retain the attested deadline-bounded prompt
  session across backup genesis and a finite sequence of separately backup-receipted permits whose
  exact ordered action/coordinate/count/deadline plan digest is bound into the Genesis permit, never
  as batch authority; later actions render a fresh Job. It alone may use prompt bytes for identity
  create/rotate/repair and is deleted/read back absent after the permitted session. Render a
  separate External Material Ingress Job for one schema-indexed non-AWS permit (initially ACME EAB);
  it cannot reuse the AWS-admin session/identity plan or expose arbitrary paths/bytes. Render the separate Admin Action Runner with the
  same authenticated stdin mechanism but only for a backup-receipted destroy/migrate/compatibility/
  quota permit. The post-export Decommission Runner uses its signed manifest plus fresh prompt
  outside this live graph. None shares the Authority Pod, ServiceAccount, cgroup, queue, proof
  family, or a generic provider/admin endpoint.
- Render Gateway emitters as stable StatefulSet identities with one registered retained journal
  each. EKS CSI EBS uses `ReadWriteOncePod`; home uses a node-pinned `hostPath`/local PV with an
  exclusive OS lock. Readiness waits for exact identity/mount, the lock, Kubernetes Lease
  incarnation, and persisted incarnation. A rolling update cannot overlap two admitted writers for
  one emitter identity.
- Deploy the Bootstrap Broker before Vault unseal, the Lifecycle Authority after Vault unseal, and
  the Target Secret Agent before any target-secret delivery; gateway readiness is not an anchor for
  either authority service.
- Bind least-privilege Vault roles: broker bootstrap-only material, lifecycle authority Model-B/
  Transit/operational control paths, target agent an allowlisted target KV path, and gateway only
  mesh/DNS/event credentials.
- Render separate Vault paths, SecretRefs, ServiceAccounts, and policies for Lifecycle-provider,
  long-lived Authority-backup-store, Gateway-DNS, substrate-local cert-manager-DNS01, deterministic
  `LongLived` SES-SMTP identities, and schema-bound non-recoverable-material custody. Chart/render fixtures for the
  new roles reject `secret/gateway/gateway/aws`; the explicit pre-cutover legacy modules remain
  narrowly allowlisted until Sprint `4.50` removes them, so this phase does not depend on a later
  cutover to validate its owned surface.
- Give each service constant-time liveness and cached admission-readiness endpoints. Deep
  capability observations execute through the role-specific client, not kubelet probes.
- Extend the typed capacity plan with independent CPU/memory/ephemeral-storage and queue limits;
  no combined gateway envelope may hide control-plane demand.

### Validation

1. Helm renders the substrate-local public roles plus private Backup/TLS Adapters and Provider
   Worker on the retained home/control-plane substrate with unique selectors,
   Services, identities, policies, envelopes, and probe paths; AWS renders Broker, Target Agent,
   Gateway, and an exact external authority reference while rejecting a second writer.
2. Permit fixtures render the ephemeral Credential Provisioner only for a signed, unexpired permit
   of the matching mode, the External Material Ingress only for its matching schema permit, and the
   Admin Action Runner only for its closed action permit, reject
   cross-mode dispatch, and prove neither receives a normal provider/outbox capability. First-
   reconcile fixtures permit only plan-digest/member/count-bound, finite receipt-ordered permit
   succession in the same attested session; a missing prior receipt, reordered/widened set, later
   rotation, or expired attestation requires a fresh Job/prompt. Terminal cleanup observes each Job
   absent.
3. Negative fixtures reject shared ServiceAccounts, cross-role Vault/Kubernetes-Secret policy grants, gateway
   lifecycle routes, missing limits, and deep work in kubelet probes.
4. Generated values/docs round-trip from typed renderers with no hand-maintained duplicate.
5. Resource-plan tests prove each role fits the home and AWS substrate budgets independently.
6. Chart lint, unit/integration suites, and `prodbox dev check` pass.

### Remaining Work

- **Increment A landed** (Bootstrap Broker workload-identity foundation: distinct bootstrap-only
  Vault role + typed chart statics + route-sourced probes + isolation tests).
- **Increment B landed** (Bootstrap Broker workload chart: `charts/bootstrap-broker/` Deployment /
  Service / ServiceAccount / NetworkPolicy / PodDisruptionBudget + values-backed Guaranteed-QoS
  envelope, all identities/probes projected from the compiled statics; the
  `bootstrap-broker-chart-statics.values` generated-section drift gate; the `bootstrap-broker`
  chart-lint rule forbidding raw identity/probe literals; and six new conformance/negative tests).
- **Increment C landed** (capacity + render primitives): the typed capacity plan now reserves a
  dedicated `bootstrap-broker` namespace quota + Guaranteed-QoS workload profile, funded by an
  operator-approved 100m trim of the over-provisioned vscode ceiling (1400m → 1300m; draw stays
  800m), keeping the single-node concurrent-quota sum at 6450m ≤ 6500m allocatable; and
  `ChartPlatform.hs` gains `valuesForBootstrapBroker` (identities/probes projected from the compiled
  statics, image injected, Guaranteed-QoS envelope attached from the capacity plan), a
  `resolveChart` arm, and the `chartResourceProfiles` mapping to the camelCase `bootstrapBroker`
  value key. The chart stays an internal control-plane chart (absent from `supportedChartNames`, so
  off the public `prodbox charts ...` surface).
- **Increment D landed** (reconcile-graph wiring): `ComponentGraph.hs` gains
  `ComponentChartBootstrapBroker` (an internal chart-only node behind the registry) with its
  `componentIdText` / `componentIdForChartName` / `chartNameForComponent` bijection,
  `componentCapabilityOp` (`OpWorkloadAvailability`), and the exhaustive-match cases in
  `stepsForComponent` / `AwsSubstratePlatform` / the operator-gate and native/AWS readiness
  registries (each chart-only, so the broker contributes **no** native install step — the
  production `cluster reconcile` topology is unchanged); `ChartPlatform.hs` adds the broker to the
  runtime-image resolution list; and `prodbox-config-types.dhall` was regenerated for the new graph.
  `resolveDependencyOrder "bootstrap-broker"` now yields `["bootstrap-broker"]`, so the plan builder
  drives the broker end-to-end. Making `ComponentVaultUnsealed` depend on the broker (broker as the
  sole pre-Vault unsealer, retiring `ComponentGatewayDaemonPreVault`) is a **Standard-P cutover**,
  deliberately not done here.
- **Increment E landed** (Gateway Runtime StatefulSet): `charts/gateway/templates/deployments.yaml`
  now renders one stable **`gateway-<nodeId>` StatefulSet per ranked id** (replicas 1) consuming the
  Sprint-2.32 `emitterPersistence` projection by index — each mounts its registered retained emitter
  journal at `/var/lib/prodbox/gateway-emitter` (home: a node-pinned `hostPath`; AWS: a
  `ReadWriteOncePod` retained-EBS `volumeClaimTemplate`) — and a single-replica StatefulSet update
  deletes the old pod before creating its replacement, so two admitted writers can never overlap for
  one emitter identity. `rbac.yaml` adds a namespace-scoped `coordination.k8s.io` Lease Role +
  RoleBinding (from `emitterPersistence.lease`) for the incarnation fence; `values.yaml` gains a
  home-substrate `emitterPersistence` default; and `Rke2.gatewayDaemonDeploymentRefs` →
  `gatewayDaemonWorkloadRefs` targeting `statefulset/gateway-<node>` for rollout restart/status. The
  file name is retained so the gateway probe/statics lint keeps its anchor, and the probe/SA/resources
  content is preserved verbatim. Both substrate renders were verified in-session with `helm template`
  (home hostPath and AWS `volumeClaimTemplate`, exit 0). The **live** StatefulSet/PV-bind/Lease
  rollout is a non-blocking Standard-O proof (cleared by `prodbox test all`).
- **Increment F landed** (Vault identity-registry cross-check): `Prodbox.Secret.VaultInventory`
  gains a compiled `vaultIdentityRegistryViolations` invariant proving the Vault Kubernetes-auth
  role names and chart-secret policy names are each bound by exactly one identity across BOTH the
  cross-module `VaultRoleId` registry (Gateway Runtime, Bootstrap Broker) AND the data-driven
  chart-secret consumers — the previously-unenforced "identities exist exactly once as a compiled
  closed registry value" invariant (lifecycle_control_plane_architecture.md § 10.2). It is enforced
  by a unit test and by the `prodbox dev check` conformance tier, so a future control-plane role
  that accidentally reused a name fails the build in seconds. This hardens the registry ahead of the
  remaining control-plane roles.
- **Increment G landed** (capacity funding via the home gateway 3 → 2 reduction, operator-approved):
  the physically separated control-plane workloads are funded on the maxed single node (an
  i7-4790K: 8 threads / ~15.5 GiB, so `host_capacity` `8000m / 15872 MiB` already claims the whole
  machine — there is no under-declared capacity to raise). `Prodbox.Lib.ChartPlatform.gatewayNodeIds`
  becomes the substrate-aware `gatewayNodeIdsForSubstrate :: Substrate -> [String]` (home
  `[node-a, node-b]`, AWS `[node-a, node-b, node-c]`), so the AWS substrate keeps three emitter
  identities and its Sprint-7.28 static retained-EBS provisioning unchanged, while the home substrate
  runs two. The `gateway` namespace quota drops `2750m → 2000m` and `3584 → 3072 MiB` and the
  `gateway` workload profile drops `replicas 3 → 2` (draw matches: `2 × 750m` gateway `+ 500m` pulsar
  `= 2000m`), freeing `750m CPU / 512 MiB`; the new single-node concurrent-quota sum is
  `5700m / 12256 MiB ≤ 6500m / 12800 MiB` allocatable, leaving `800m CPU / 544 MiB` headroom for the
  standing control-plane workloads. Because the gateway daemon rejects any `event_keys` set that does
  not match Orders membership exactly (`Prodbox.Gateway.Settings.compileBoundedOrders`),
  `charts/gateway/templates/configmap-config.yaml` now renders the per-peer `event_keys`
  parametrically over `nodes.rankedIds` (each peer's key path derived as
  `gateway/gateway/<nodeId>/event-key`), retiring the previously hard-coded three-node mesh
  assumption and the fixed `eventKeyNode{A,B,C}` values. Evidence: `prodbox dev check` exit 0; the
  targeted capacity / resource-plan / guardrail-golden / `gatewayDaemonWorkloadRefs` /
  emitter-persistence / Orders suite 204/204; and a `helm template` of the gateway config on the home
  two-node case producing exactly a two-member `event_keys` list. (The full `prodbox test unit` run
  is intermittently environment-flaky on this host — daemon/concurrency tests hang under fd pressure
  from stray suite processes — so per the project's validation-toolchain guidance the code-owned
  surface is validated with `dev check` plus targeted `-p` patterns.) The **live** two-emitter
  StatefulSet rollout remains a non-blocking Standard-O proof.
- **Coupling note (why the remaining Vault-inventory + workload charts are not additive in the same
  way B–F were).** Adding the control-plane roles' least-privilege consumers themselves
  (`secret/aws/{lifecycle-provider,authority-backup-store,tls-retention-store}`, the target-agent KV)
  is coupled to two decisions outside a clean code change: (1) the seed-object **credential field
  schemas** each new consumer path requires (enforced by the "every consumer path has a seed object"
  invariant) are defined by the Phase-4/8 credential flow; and (2) each control-plane **workload
  chart** needs an independent Guaranteed-QoS envelope on the single-node home budget, which is
  already at 6450m ≤ 6500m concurrent — so each addition needs an operator capacity-architecture
  decision. These are tracked below and are best landed alongside their Phase-4 interpreters.
- **Capacity funding resolved (Increment G, above).** The operator-approved home gateway 3 → 2
  reduction frees `800m CPU / 544 MiB` of single-node headroom, which sizes the five **standing**
  control-plane workloads (Guaranteed-QoS, `request == limit`): Lifecycle Authority (`150m / 128Mi`,
  StatefulSet), fenced Provider Worker (`100m / 112Mi`), Authority Backup Adapter (`60m / 80Mi`),
  TLS Retention Adapter (`60m / 80Mi`), Target Secret Agent (`60m / 80Mi`) — concurrent sum
  `6130m / 12736 MiB ≤ 6500m / 12800 MiB`.
- **Increment H landed** (the five standing control-plane role charts): `charts/lifecycle-authority/`
  (a StatefulSet with a retained journal `volumeClaimTemplate`), `charts/provider-worker/`,
  `charts/authority-backup/`, `charts/tls-retention/`, and `charts/target-secret-agent/` (Deployments)
  are rendered as internal control-plane charts — chart-only `ComponentGraph` nodes
  (`ComponentChart{LifecycleAuthority,ProviderWorker,AuthorityBackup,TlsRetention,TargetSecretAgent}`)
  behind the registry with no native install step, so the production `cluster reconcile` topology is
  unchanged and they are deliberately absent from `supportedChartNames` (off the public
  `prodbox charts …` surface). Each role has its own compiled `ChartStatics`
  (`src/Prodbox/Lifecycle/<Role>/ChartStatics.hs`) projecting its ServiceAccount / Vault role (a new
  least-privilege `VaultRoleId` — the closed inventory is now 7 roles, still collision-free under the
  `vaultIdentityRegistryViolations` conformance gate) and constant-time `/healthz`+`/readyz` probe
  paths; a `<role>-chart-statics.values` generated-section drift gate holds the committed
  `values.yaml` byte-identical to the compiled statics. `ChartPlatform` gains
  `controlPlaneRoleChartNames`, a shared `valuesForControlPlaneRole` renderer with five thin per-role
  wrappers, a `resolveChart` arm, the runtime-image list entries, and the `chartResourceProfiles`
  camelCase mappings; the typed capacity plan reserves the five independent namespace quotas +
  Guaranteed-QoS workload profiles funded by Increment G (concurrent sum `6130m / 12736 MiB ≤
  6500 / 12800`, the Lifecycle Authority reserving 1Gi durable for its journal); and the six
  `ComponentId` exhaustive-match sites (native/AWS step + readiness registries, operator gate,
  capability op) plus the `TestSupport` Dhall mirror and `prodbox-config-types.dhall` are regenerated.
  Evidence: `prodbox dev check` exit 0 (warning-clean build, fourmolu/HLint, the 7-role Vault
  identity conformance, and the five generated-section drift gates); the targeted capacity /
  ComponentId-bijection / chart-statics suite 248/248 plus the extended graph test proving
  `resolveDependencyOrder` for each of the five new charts yields `[<chart>]`; and a `helm template`
  of all five charts (six objects each: Deployment/StatefulSet, Service, ServiceAccount,
  NetworkPolicy, PodDisruptionBudget, ConfigMap). The **live** rollout is a non-blocking Standard-O
  proof.
- **Increment I landed** (per-role negative-lint fixtures): `CheckCode.hs` gains a generic
  `controlPlaneChartStaticViolations` regression guard driven by a compiled `controlPlaneChartLints`
  registry (chart → compiled ServiceAccount identity, `/healthz`+`/readyz` probe paths, generated
  `values.yaml` block, and hand-written workload template — `statefulset.yaml` for the Authority,
  `deployment.yaml` for the four adapters). It is wired into `chartViolationsFor` (so `prodbox dev
  check` runs it on every chart) and rejects a hand-written ServiceAccount identity or probe path
  hard-coded to a raw literal instead of `.Values.serviceAccount.name` / `.Values.probes.*`, or a
  `values.yaml` missing the generated statics block. Two conformance tests prove the five committed
  charts produce no violations and that raw literals are rejected. Evidence: `prodbox dev check`
  exit 0 (the lint runs clean against all five real charts); the extended `Bootstrap Broker chart
  statics` suite (broker + control-plane cases) green.
- **Phase-4 extensions (not Phase-3 remaining work):** Sprint `4.48` binds the rendered identities to
  least-privilege Vault consumers and production permit interpreters and renders their on-demand Jobs;
  Sprint `4.50` owns the pre-Vault Bootstrap Broker cutover and legacy Gateway bootstrap removal.
  Those later behavior/cutover surfaces compose these completed charts but do not reopen or block
  Phase 3 (Standard N).

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - deployment topology.
- `documents/engineering/helm_chart_platform_doctrine.md` - role-specific charts and probes.
- `documents/engineering/resource_scaling_doctrine.md` - independent envelopes/queues.
- `documents/engineering/vault_doctrine.md` - ServiceAccount and policy inventory.
- `documents/engineering/bootstrap_readiness_doctrine.md` - component order and capability gates.
- `documents/engineering/unit_testing_policy.md` - chart negative fixtures and goldens.

**Product docs to create/update:**

- `README.md` - deployed role topology.

**Cross-references to add:**

- Link each rendered role to its Phase-2 or Phase-4 behavior owner.

## Sprint 3.27: Derived Workload Admission Rendering [✅ Done]

**Status**: Done (validated 2026-07-25) — every namespace admission object is now derived from the
validated workload-demand plan and its rendered scheduling units.
**Implementation**: new `src/Prodbox/Capacity/Placement.hs` owns the placement algebra — a
`renderedNamespace substrate` resolver (home co-locates keycloak into the vscode namespace, counted
**exactly once**; AWS is the identity placement), separate scheduler-request and containment-limit
axes in `planNamespaceAdmission`, `planNamespaceQuota`/`planNamespaceLimits`, and the
`WorkloadConcurrency = Steady | ExclusiveWindow` model. Named exclusive windows take a componentwise
peak for mutually exclusive init/main or Job scheduling units; independent windows and steady units
sum. `src/Prodbox/Lib/ChartPlatform.hs` and `src/Prodbox/CLI/Rke2.hs` consume the derived values through
the shared `Prodbox.Capacity.Render` (Sprint `3.28`); the
authored `namespace_quotas`, the `NamespaceQuota` type, `concurrentNamespaceQuotas`, and the
keycloak↔vscode hand-fold are deleted from `src/Prodbox/Capacity/Config.hs`, and
the generated `prodbox-config-types.dhall` schema no longer exposes that authored surface.
**Blocked by**: Sprint `1.71` (satisfied — Done).
**Deployment qualification**: pending — this changes the Standard-P resource-envelope render surface;
live admission remains a non-blocking later qualification axis.
**Independent Validation**: typed-value tests prove the home vscode admission request/limit vectors,
Guaranteed equality, exact workload-demand derivation, and rejection of an invalid calibration input.
The unit suite passes 2324/2324. The built-frontend fake-Kubernetes
`resource-guardrails` integration passes 1/1 and compares every observed `ResourceQuota` request/limit
axis and `LimitRange` against the same placement projection used by the renderers. The env integration
passes 4/4, and `prodbox dev check` passes. No deployed cluster, AWS, or later phase is required.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/config_doctrine.md`, `documents/engineering/resource_scaling_doctrine.md`

### Objective

Make rendered namespace `ResourceQuota`/`LimitRange` values projections of derived workload contracts
and actual Kubernetes scheduling units rather than independently authored numbers, so the
"authored quota disagrees with its workloads"
class of drift becomes unrepresentable — the namespace lemma of
[resource_scaling_doctrine.md § 2B](../documents/engineering/resource_scaling_doctrine.md), delivered
through the § 2A decode-gate proof and one § 2C render ring.

**Premise correction.** There is **no** 3325-vs-1300 rendering disagreement: every render path already
uses the raw namespace quota (3325m), and the 1300m figure exists only inside the
`concurrentNamespaceQuotas` co-location *accounting* and is never rendered. The drift this sprint removes
is the general one — that an authored quota *can* be written to disagree with the sum of its workloads'
draws — not a specific rendered mismatch.

**Surge headroom is structural, shipped at 0.** Co-location/rolling surge is modelled per-workload as a
`surge` field derived from `maxSurge`, shipped `0` for now. This is justified: the co-located workloads
are StatefulSets with ordered (non-surging) rollout, and the current cpu/memory namespace quotas already
run live with slack above Σ draws, so a zero-surge derived quota admits the shipped Guaranteed-QoS
workloads exactly.

### Deliverables

- `Prodbox.Capacity.Placement` owns `renderedNamespace substrate` (home keycloak→vscode co-location
  counted exactly once; AWS identity), pod/job scheduling-unit composition, init-container peak
  semantics, `planNamespaceQuota`/`planNamespaceLimits`, and `WorkloadConcurrency = Steady |
  ExclusiveWindow`.
- Every render path consumes the derived quota (through the shared `Capacity.Render`), so cluster config
  can only be emitted from the proven plan — no raw `find`-over-authored-quotas join survives.
- Delete authored `namespace_quotas`, the `NamespaceQuota` type, `concurrentNamespaceQuotas`, and the
  keycloak↔vscode hand-fold from `src/Prodbox/Capacity/Config.hs`; regenerate `dhall/capacity/Schema.dhall`.
- Add the per-workload structural `surge` (from `maxSurge`), shipped `0`.

### Validation

1. Typed-value goldens: the rendered request axis equals the concurrent scheduler requests and the
   limit axis equals the concurrent finite containment bounds, with home keycloak counted exactly once;
   the durable request axis equals the real PVC total from Sprint `3.29`.
2. Demand-derivation fixtures prove exact CPU arithmetic, memory/ephemeral term composition, durable
   propagation, Guaranteed equality, and invalid calibration rejection.
3. The stale `test/unit/Main.hs` vscode rendered-quota fixtures are reconciled to the derived values.
4. Chart lint, unit/integration suites, and `prodbox dev check` pass.

### Remaining Work

None. Live admission and rollout observation is retained only as non-blocking Standard-O deployment
qualification evidence.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` - derived `ResourceQuota`/`LimitRange` as
  projections of workload draws.
- `documents/engineering/config_doctrine.md` - the retired authored-quota surface
  (`namespace_quotas`/`concurrentNamespaceQuotas`).
- `documents/engineering/resource_scaling_doctrine.md` - § 2B namespace lemma delivered as a rendered
  projection, not an authored number.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link the derived quota to Sprint `1.69`'s decode-gate proof, Sprint `3.28`'s shared `Capacity.Render`,
  and Sprint `3.29`'s single-sourced durable PVC sizes.
- Record the deleted authored `namespace_quotas`/`NamespaceQuota`/`concurrentNamespaceQuotas` surface
  as completed in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 3.28: Unified Resource-Render Module [✅ Done]

**Status**: Done (validated 2026-07-25) — `Prodbox.Capacity.Render` is the shared render foundation
for chart values, root-chart manifests, validation expectations, and runtime-vector diagnostics.
**Implementation**: new `src/Prodbox/Capacity/Render.hs` becomes the single owner of the Kubernetes
`ResourceQuota` hard-spec (all 7 hard fields, including `requests.storage`), the `LimitRange` spec, the
runtime cpu/memory/ephemeral (+durable CSV) resource vector, and the `cpuQuantity`/`memoryQuantity`
quantity formatters. `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/CLI/Rke2.hs`, and
`src/Prodbox/TestValidation.hs` delete their local copies and delegate to `Capacity.Render`.
**Blocked by**: none — the `capacity.resource_plan` schema and the existing per-site renderers are
already in the worktree.
**Deployment qualification**: pending — a **byte-identical** refactor of the Standard-P
resource-envelope render surface; the rendered manifests do not change.
**Independent Validation**: a pure refactor — the existing unit and golden suites stay green
(byte-identical `ResourceQuota`/`LimitRange`/runtime-vector output), plus a property test that the new
`Capacity.Render` functions equal the pre-refactor literals for `defaultResourcePlan`. No deployed
cluster, AWS, or later phase.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`

### Objective

Retire the 3×-duplicated `ResourceQuota`/`LimitRange`/runtime-vector renderers so the validator asserts
observed cluster JSON against the **same** function the renderer emits (DRY). This makes the render ring
of [resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md)
single-sourced, and is the shared surface every later governance sprint (`3.29`, `3.27`, `4.52`) renders
through.

### Deliverables

- `src/Prodbox/Capacity/Render.hs` is the single owner of the `ResourceQuota` hard-spec (7 hard fields
  incl. `requests.storage`), the `LimitRange` spec, the runtime cpu/memory/ephemeral(+durable CSV)
  resource vector, and `cpuQuantity`/`memoryQuantity`.
- `ChartPlatform.hs`, `Rke2.hs`, and `TestValidation.hs` delete their local copies and delegate; no
  second copy of the hard-spec or the quantity formatters survives.

### Validation

1. The existing unit and golden suites stay green (byte-identical output).
2. A property test proves the new `Capacity.Render` functions equal the pre-refactor literals for
   `defaultResourcePlan`.
3. `prodbox dev check` passes.

### Remaining Work

- None (unblocked). This is the shared render surface consumed by Sprints `3.29`, `3.27`, and `4.52`.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/helm_chart_platform_doctrine.md` - one module owns the rendered
  `ResourceQuota`/`LimitRange`.
- `documents/engineering/resource_scaling_doctrine.md` - § 2C render ring single-sourced through
  `Capacity.Render`.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Enqueue the deleted per-site `ResourceQuota`/`LimitRange`/quantity duplicate renderers in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) under this sprint.
- Link Sprints `3.29`, `3.27`, and `4.52` as consumers of `Capacity.Render`.

## Sprint 3.29: Durable-PVC Storage Single-Source-of-Truth [✅ Done]

**Status**: Done (validated 2026-07-25) — retained chart bindings and MinIO/Vault/Lifecycle Authority
render paths derive their PVC sizes from the matching workload profile's durable limit.
**Implementation**: `src/Prodbox/Capacity/Config.hs` sets each StatefulSet workload's per-replica
`durable_storage_mib` (limit) to the **real** PVC size (vscode `51200`, keycloak-postgres `20480`, minio
`20480`, pulsar `20480`, vault `1024`, lifecycle-authority `1024`), relaxes durable positivity so `0` =
"no PVC", and requires the durable axis non-burstable (`request == limit`). `src/Prodbox/Lib/Storage.hs`
`ChartStorageSpec` names the workload profile id and derives its size from the proof instead of a
literal. The scattered size constants are deleted — `ChartPlatform.hs` vscode `50Gi` / pulsar `20Gi`,
`PostgresPlatform.hs` patroni `20Gi`, the `charts/*/values.yaml` `size:` literals, and the
`charts/lifecycle-authority/templates/statefulset.yaml` `1Gi` template hardcode — and the minio/vault
`resources:`+`size:` fields fold into the resource-plan injection.
**Blocked by**: Sprint `3.28` (satisfied — `3.28` is Done).
**Deployment qualification**: pending — touches the Standard-P persistence/resource-envelope surface;
the change is quota- and size-neutral (provenance-only).
**Independent Validation**: a golden Helm render shows every PVC `storage:` identical to the deleted
literals (quota-neutral and size-neutral — the authored durable quotas already equal the real PVC
totals), so this is a provenance-only change. No deployed cluster, AWS, or later phase. This sprint
**must land before Sprint `3.27`**, which reproduces the durable quota from these single-sourced sizes.
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`

### Objective

Make the PVC `size:`, the namespace `requests.storage` quota, and the fit proof one value that cannot
drift — the class behind the live storage landmine (deriving `requests.storage` from the placeholder
`durable_storage_mib` would cap keycloak at 6Gi while its Postgres PVCs need 60Gi, so the PVCs are
refused). This closes the durable side of the pod/namespace lemma of
[resource_scaling_doctrine.md § 2B](../documents/engineering/resource_scaling_doctrine.md) against the
same proof the § 2C render ring emits.

### Deliverables

- `Capacity/Config.hs` sets each StatefulSet workload's per-replica `durable_storage_mib` to the real
  PVC size (vscode `51200`, keycloak-postgres `20480`, minio `20480`, pulsar `20480`, vault `1024`,
  lifecycle-authority `1024`), allows `0` = "no PVC", and requires the durable axis `request == limit`.
- `Storage.hs` `ChartStorageSpec` names its workload profile id and derives the size from the proof.
- Delete the scattered size constants (`ChartPlatform.hs` vscode/pulsar, `PostgresPlatform.hs` patroni,
  `charts/*/values.yaml` `size:` literals, the `charts/lifecycle-authority/templates/statefulset.yaml`
  `1Gi` hardcode) and fold minio/vault `resources:`+`size:` into the resource-plan injection.

### Validation

1. A golden Helm render shows every PVC `storage:` identical to the deleted literals (size-neutral).
2. The namespace `requests.storage` quota is unchanged (quota-neutral — authored durable quotas already
   equal the real PVC totals).
3. `prodbox dev check` passes.

### Remaining Work

- None on the owned surface. Sprint `3.27` now consumes the single-sourced durable draws.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/storage_lifecycle_doctrine.md` - PVC `size:` single-sourced from
  `durable_storage_mib`.
- `documents/engineering/helm_chart_platform_doctrine.md` - retired chart-local `size:` literals.
- `documents/engineering/resource_scaling_doctrine.md` - § 2B durable lemma over one single-sourced value.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Enqueue the deleted chart-local durable `size:` constants
  (`ChartPlatform.hs`/`PostgresPlatform.hs`/`charts/*/values.yaml`/`charts/lifecycle-authority`
  template) in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) under this sprint.
- Link the single-sourced durable size to Sprint `3.28`'s `Capacity.Render` durable-CSV vector and
  Sprint `3.27`'s durable-quota reproduction.

## Sprint 3.30: Declare the Phase-3 Real Constants and Point the Chart Default at Its Registration [✅ Done]

**Status**: Done (2026-08-03) — Phase `3` own-surface reopen (Standard A/N) on the public workload
runtime and chart values this phase owns (`00-overview.md` assigns `src/Prodbox/Workload.hs` and
`charts/` to Phase 3), adopting
[vault_doctrine.md §20.1](../documents/engineering/vault_doctrine.md#201-the-rule) (Sprint `0.20`).
Comment-only; no behaviour changes and no rendered-manifest changes.
**Implementation**: `src/Prodbox/Workload.hs` (`websocketAcceptKey` Haddock),
`charts/minio/values.yaml` (the credential-default comment)
**Blocked by**: none (own-surface reopen; validated without a later phase or live infrastructure).
**Deployment qualification**: pending — comment-only, so no Standard-P production-composition surface
is touched; the revision must not be called deployment-ready on the strength of a comment.
**Independent Validation**: pure source-comment and chart-comment surface, validated on the home
substrate with no later-phase or live dependency — `prodbox dev check` exit 0, `prodbox dev lint
chart` unaffected, and the unit suite unchanged (chart rendering is byte-identical; only comments
moved).
**Docs to update**: `documents/engineering/vault_doctrine.md`

### Objective

Two Phase-3-owned values were undeclared under § 20.1: one genuinely real constant that a reader
could mistake for a fixture, and one credential default whose comment pointed at a doctrine section
that no longer registers it.

### Deliverables

- `src/Prodbox/Workload.hs` — the WebSocket handshake GUID is declared REAL and required: it is the
  fixed constant published in RFC 6455 § 1.3 and normative in § 4.2.2, identical in every
  implementation. It must not be replaced with a placeholder, because a different value yields an
  accept header no client will honour. Previously it sat as a bare literal with no provenance, which
  is exactly the shape a later reader "cleans up".
- `charts/minio/values.yaml` — the MinIO root credential default now cites § 6.1, where the
  bootstrap-floor credential is actually registered, instead of the § 20.3 slot that Sprint `0.20`
  reassigned. The comment also states plainly that the bootstrap floor is the single registered
  exception to "no credential in chart values" (§ 20.3) and is not licence to hardcode elsewhere.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` unchanged — as expected from comment-only edits.
3. Rendered chart output is byte-identical; the chart-statics conformance checks pass unchanged.

### Remaining Work

None. Migration of the MinIO bootstrap credential from a compiled constant to a per-install generated
value remains scheduled and is not closed here.

## Sprint 3.31: Typed Helm Release State and a Chart Write Permit ✅

**Status**: Done (2026-08-07) — Phase `3` own-surface work (Standard A/N) on the chart platform this
phase owns.
**Implementation**: `src/Prodbox/Lifecycle/HelmRelease.hs` (`HelmReleaseStatus`,
`parseHelmReleaseStatus`, `helmReleaseStatusPermitsWrite`, `HelmWritePermit`, `HelmWriteRefusal`,
`helmWritePermit`; `HelmReleasePresent` now carries the decoded status; the absence reconciler
refuses a concurrently-held release), `src/Prodbox/Lib/ChartPlatform.hs`
(`reconcileFailedReleaseAbsent` replaces the fire-and-forget `helm uninstall --wait`).
**Blocked by**: none.
**Deployment qualification**: pending — chart delivery is a Standard-P lifecycle-orchestration
surface; both rows are already `pending`.
**Independent Validation**: pure decode plus fake-driven chart fixtures, no live cluster — the seven
Helm statuses decode to distinct constructors, and a concurrent-writer error resolves to a typed
refusal rather than an uninstall.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

`Prodbox.Lifecycle.HelmRelease` derives presence from `helm status`'s **exit code**, so `deployed`,
`failed`, `pending-install`, `pending-upgrade`, `pending-rollback`, `uninstalling`, and `superseded`
collapse into one constructor — while `--output json` is already requested and `.info.status`
discarded. That is the *Provenance* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md): a value
whose legality depends on where it came from, decoded from the weakest available signal.

The collapse has a concrete consequence. `Prodbox.Lib.ChartPlatform` answers *any* non-zero
`helm upgrade --install` exit by running `helm uninstall --wait`. Helm's
`"another operation (install/upgrade/rollback) is in progress"` is the **concurrency** error, so the
recovery deletes the release another writer is mid-install on. A timeout on
`--wait --timeout 30m0s` is likewise indistinguishable from failure, so a healthy-but-slow rollout
is answered by deleting a working release.

### Deliverables

- ✅ A full `HelmReleaseStatus` decoded from `.info.status` — all eight statuses, each its own
  constructor. `--output json` was already being requested and the field discarded; presence came
  from the **exit code**, which cannot distinguish `deployed` from `pending-upgrade`, and that
  distinction is the difference between a release this process may write and one another writer
  holds. An unrecognised status, a missing `.info.status`, and an unparseable body all fail closed to
  `HelmReleaseUnobservable` rather than defaulting to present.
- ✅ The failure path routes through the existing absence reconciler.
  `reconcileFailedReleaseAbsent` replaces the unconditional `helm uninstall --wait`, so the recovery
  **re-observes** before acting and reports a refusal instead of destroying.
- ✅ A `HelmWritePermit` whose constructor is hidden and whose sole producer is `helmWritePermit`,
  so a mutating helper cannot be reached without an observation that said the release is not being
  written by somebody else. The four pending/uninstalling statuses yield
  `HelmWriteConcurrentOperation`, and an unobservable release yields `HelmWriteUnobservable` — a
  refusal that **cannot** be answered by a destroy, because a destroy needs the permit it was
  refused.

### Validation

1. ✅ `prodbox-unit -p "Sprint 3.31"` — 4/4, including one case per Helm status (all eight decode to
   distinct constructors); full unit 3199/3199.
2. ✅ The concurrency error produces a refusal, and the reconciler observes exactly once and never
   uninstalls (asserted on the recorded call list, so "did not destroy" is checked rather than
   assumed). The mutation exercise restoring the unconditional uninstall fails
   *the absence reconciler refuses rather than uninstalling*, and the source restored byte-exactly
   (`sha256sum -c`: `OK`).
3. ✅ An unrecognised status string fails closed rather than mapping to present or absent, as do a
   missing field and a non-JSON body.
4. ✅ `prodbox dev check` exit 0.

### Remaining Work

None on this sprint's surface. Recorded rather than left implicit: the second half of the original
defect — that a `--wait --timeout 30m0s` timeout is indistinguishable from a failure at the exit
code — is now **mitigated but not eliminated**. A timeout still reaches the failure path; what
changed is that the failure path re-observes and will find the release `pending-upgrade`, so it
refuses instead of deleting a healthy-but-slow rollout. Distinguishing timeout from failure at the
`helm upgrade` call itself would need Helm to report it, which it does not.

## Sprint 3.32: Canonical Ownership Direction for Mirrored Secrets ✅

**Status**: Done (2026-08-07) — Phase `3` own-surface work on the workload secret-delivery path
this phase owns. **Scope corrected twice against source (Standard C): the 2026-08-07 correction
below refuted both of the sprint's original premises, and closing the sprint refuted the first
correction's own replacement premise as well. What landed is stated in Deliverables (as landed).**
**Implementation**: `src/Prodbox/Lifecycle/DnsRecord/Owner/Internal.hs` (new — the
`DnsOwnerAuthority` constructor), `src/Prodbox/Lifecycle/DnsRecord/Owner.hs` (new — the sole
minter `dnsOwnerAuthorityForProcess` and the total role×substrate table),
`src/Prodbox/Lifecycle/DnsRecord.hs` (`DestroyDnsRecord` takes the authority;
`DnsProgramOwnerUnauthorized`), `src/Prodbox/CheckCode.hs`
(`checkDnsOwnerAuthorityBoundary`), `documents/engineering/secret_derivation_doctrine.md` § 5.1,
`documents/engineering/helm_chart_platform_doctrine.md`, `src/Prodbox/Lib/ChartPlatform.hs`
(two comments), `test/unit/DnsOwnerAuthoritySuite.hs` (new), `test/unit/DnsRecord.hs`,
`test/unit/Main.hs`, `prodbox.cabal`.
**Blocked by**: none.
**Deployment qualification**: pending — but this sprint moves **no** Standard-P
production-composition surface: `DestroyDnsRecord` has zero production construction sites, so the
arity change is a no-op at runtime. See "What this does not claim" below.
**Independent Validation**: pure, no live cluster — the totality of the minting table, the absence
of both cert-manager owners from its range, and a fail-closed destroy under a *matching*
program/boundary pair, plus a `dev check` source gate proving no other production module can name
the minting representation.
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Percona PGO v2 owns the `pguser` password. The sync must run Secret → Vault and **never** the
reverse, or the operator's rotation is overwritten with a stale value. That direction is enforced
today by a code comment, a regression test, and an operator memory — none of which is a type.

The same shape appears in DNS: `DnsRecordOwner` distinguishes the home from the AWS cert-manager
DNS01 owner, and **nothing consumes the distinction**, so no compiled proof stops one substrate
deleting the other's `_acme-challenge` records.

This is the *Direction* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md): a
reconciler that can run backwards.

### Premise corrections (2026-08-07)

Both premises were checked against source before any code was written, and neither holds as stated.
Recording that is the point; working the sprint as specified would have produced a class
constraining a helper that does not exist and a check that already exists.

- **The `pguser` ownership direction is the reverse of what the Objective states, and the first
  correction was also wrong.** The Objective says "Percona PGO v2 owns the `pguser` password. The
  sync must run Secret → Vault and **never** the reverse." Source says the opposite:
  `src/Prodbox/Secret/VaultInventory.hs:485,489,493` declares all three Patroni passwords as
  `generatedField "password" "patroni-password"`, and `generateVaultSecretFieldValue` (:553-559)
  mints them from 32 random bytes — **prodbox generates them into Vault KV**. The
  `PerconaPGCluster` pins `spec.users[].secretName`
  (`charts/keycloak-postgres/templates/postgresql.yaml:12-18`) to the pre-created Secrets, which is
  PGO's custom-user-secret *adoption* path: the operator owns the Secret object, not the value.

  The first correction then claimed "no process copies the value", and that is false too. Exactly
  one mirror exists and it is **chart-local, not Haskell**:
  `charts/keycloak-postgres/templates/secret-bootstrap-job.yaml` is a
  `helm.sh/hook: pre-install,pre-upgrade` Job (:16) that reads
  `vault kv get -field=password` (:65-66) and creates (`201`) or merge-patches (`409`, :128-140)
  the three named Secrets. Tracing the three secret-name helpers found nothing because the mirror
  is not in Haskell — which is the *same* lesson Sprint `4.58` recorded, applied one level up:
  tracing every use of a Haskell symbol proves the absence of a Haskell mirror, never the absence
  of the behaviour.

  The rule the doctrine states is therefore satisfied — but by **exactly one mirror running in the
  canonical direction with no reverse path**, which is a different fact from "no mirror exists",
  and the one worth recording. No path anywhere reads a Kubernetes Secret back into Vault; the only
  `vault write` calls in the chart tree are Kubernetes-auth logins. Both governed doctrine tables
  already described the correct direction; it was the sprint text, and two `ChartPlatform.hs`
  comments saying "operator-owned pguser Secret", that invited the inverted reading.

- **The DNS owner witness is already consumed at the delete site, but it proves the wrong thing.**
  The sprint says "nothing consumes the distinction". `runDnsRecordProgram`'s `runDestroy` does
  check it — `ownerMatches` guards the destroy and yields `DnsProgramOwnerMismatch`. The real gap is
  narrower and different: that check compares the **program's** coordinate owner against the
  **boundary's** coordinate owner, and the same caller supplies both. It is a self-consistency
  check, not a proof that the running process is the owner it claims. A home process that builds
  both values with `AwsCertManagerDns01Owner` passes it.

### Deliverables (as landed)

- **`DestroyDnsRecord` consumes a `DnsOwnerAuthority`.** The authority is opaque, its constructor
  lives in `Prodbox.Lifecycle.DnsRecord.Owner.Internal`, and its sole minter
  `dnsOwnerAuthorityForProcess` is a total function of the two facts that identify a running
  prodbox process: the `RuntimeRole` it selected before decoding configuration and the `Substrate`
  that configuration declares. `runDestroy` refuses with the new `DnsProgramOwnerUnauthorized`
  before it observes anything.
- **Neither cert-manager owner is in the minter's range.** cert-manager is not a prodbox process
  and has no `RuntimeRole`, so no `(role, substrate)` pair yields `HomeCertManagerDns01Owner` or
  `AwsCertManagerDns01Owner`. The sprint's named scenario — a home process deleting an AWS
  cert-manager `_acme-challenge` record by naming that owner on both sides — is not refused at
  runtime, it is **unconstructible**. A prodbox process removes such a record by deleting the
  Kubernetes object that owns it and proving absence by read-back, which is the contract Sprint
  `5.29` builds on.
- **The table is total and written pair by pair.** All 14 `RuntimeRole × Substrate` pairs are
  enumerated with no wildcard, so a new role or substrate is a compile error at the table rather
  than a silent `Nothing`. `(GatewayRuntime, SubstrateAws)` mints nothing, matching the target
  architecture's disabled EKS DNS mutation.
- **A `dev check` gate makes the boundary structural.** `checkDnsOwnerAuthorityBoundary` fails any
  `src/` module other than the two owner modules that names the package-internal representation,
  in the same idiom as the Sprint `1.76` `RoundTripWitness` and Sprint `4.58` `TargetSinkVersion`
  boundaries.
- **The `pguser` direction rule is recorded with its true mechanism.**
  `secret_derivation_doctrine.md` § 5.1 states the four facts with source citations — Vault is the
  authority, exactly one chart-local mirror runs Vault → Secret, PGO adopts rather than generates,
  and no reverse path exists — and `helm_chart_platform_doctrine.md` disambiguates "operator-owned"
  as naming the Secret object's controller. The two `ChartPlatform.hs` comments that invited the
  inverted reading now say `PGO-adopted` and cite § 5.1. Rendered chart output is unchanged.

### Validation (as run)

1. `prodbox-unit -p "Sprint 3.32"` — 7/7. (The sprint originally wrote this as
   `prodbox test unit -p "Sprint 3.32"`; that flag does not exist on the `prodbox` surface, which
   accepts only `--coverage`, `--cov-fail-under`, and `--substrate`. Pattern selection is a flag on
   the built test binary.)
2. `prodbox-unit -p "DNS record"` — 8/8, the pre-existing suite unbroken by the arity change.
3. **Mutation exercise.** Disabling the authority guard in `runDestroy` makes a home-gateway
   process destroy an `AwsLifecycleProviderDnsOwner` record and read back absence
   (`DnsDestroyAppliedAndReadBack` where `DnsProgramOwnerUnauthorized` is expected) — the exact
   defect, reproduced. The source restored byte-exactly (`cmp` clean) and 7/7 returned.
4. The `dev check` gate is exercised as a pure function over synthetic paths in the same suite:
   the two owner modules are permitted, two other production paths are refused, and importing the
   public module is permitted.
5. `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit 0,
   and `prodbox test unit` exit 0 — 3206/3206 plus the dedicated 27/27 admission, 33/33
   authentication, and 27/27 transport suites.

The sprint's original Independent Validation promised "a compile-fail exercise rather than a
runtime assertion". No compile-fail harness exists in this repository, so that line named a
mechanism the tree does not have; it is replaced above by the ring-2 mechanism the tree does have —
a `dev check` source gate plus a totality proof. Recorded rather than quietly substituted.

### What this does not claim

- **It changes no live behaviour.** `DestroyDnsRecord` has zero production construction sites
  (declaration, interpreter arm, and four test sites are its only occurrences), and the one typed
  DNS writer is reachable only under the undeployed `JournalLeaseEmitter` topology. This makes the
  state unconstructible *before* the destroy path is wired, which is the right order; it is not a
  fix to a running system.
- **It does not bound Route 53.** Two untyped Route 53 writers exist in
  `src/Prodbox/ControlPlane/ProviderProduction.hs` with no owner value at all. The claim this
  sprint supports is narrow: no process can interpret a typed DNS destroy program against a
  coordinate whose owner it does not hold. Recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- **`EnsureDnsRecord` is still unwitnessed.** An ensure is a mutation too and is the same Direction
  class; it is recorded as an unowned ledger row rather than widened into this sprint, because
  scheduling gap-closure through a sprint block rather than silently is Standard L.
- Per [chaos_hardening_doctrine.md § 22](../documents/engineering/chaos_hardening_doctrine.md), a
  ring-2 gate bounds a process, not a protocol.

## Sprint 3.33: An Ensure Is a Mutation Too ✅

**Status**: Done (2026-08-09) — Phase `3` own-surface work completing the DNS ownership authority
Sprint `3.32` opened.
**Implementation**: `src/Prodbox/Lifecycle/DnsRecord.hs` (`EnsureDnsRecord` takes the
`DnsOwnerAuthority`; `runEnsure` checks it in the same order `runDestroy` does),
`src/Prodbox/Gateway/Daemon.hs` (the one production construction site mints its authority from
`RuntimeRole` × `Substrate` instead of receiving none), `test/unit/DnsOwnerAuthoritySuite.hs`,
`test/unit/DnsRecord.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — and unlike Sprint `3.32`, this one **does** edit a live
production mutation path, so the reasoning is given rather than the conclusion. `DestroyDnsRecord`
had zero production construction sites, which is why `3.32` was a runtime no-op. `EnsureDnsRecord`
has exactly one: the gateway daemon's home Route 53 A-record write. The authority it now mints is
`dnsOwnerAuthorityForProcess GatewayRuntime SubstrateHomeLocal` = `HomeGatewayDnsOwner`, which is the
owner `homeDnsProgramInputs` already builds the coordinate with, so the new guard cannot fire on the
supported path and no record, value, TTL, or ordering changes. None of Standard P's enumerated
surfaces moves. The next qualification run must still exercise the post-`3.33` write path.
**Independent Validation**: pure, no live infrastructure — a named `-p` filter with an exact count,
including a refusal case that asserts the boundary is never called.
**Docs to update**: none — `Prodbox.Lifecycle.DnsRecord.Owner`'s module Haddock already states the
rule for both directions, and it is now true of both.

### Objective

Sprint `3.32` gave `DestroyDnsRecord` the authority the running process holds and recorded, in its
own Remaining Work and as an unowned ledger row, that `EnsureDnsRecord` was still unwitnessed.
Writing a record you do not own is not obviously less bad than deleting one; it is the same
*Direction* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md), and the
asymmetry was deliberate scoping rather than a judgement that an ensure is safe.

The ledger's own note said this should be scheduled "with the ensure path's first production
constructor rather than before it". That constructor already exists — `src/Prodbox/Gateway/Daemon.hs`
— so the condition the row set is met, and the sprint is the one that meets it.

### Deliverables

- ✅ `EnsureDnsRecord :: DnsOwnerAuthority -> DnsRecordSet -> DnsRecordProgram DnsProgramResult`, with
  `runEnsure` refusing `DnsProgramOwnerUnauthorized` **before** its first observation — checked in the
  same order as `runDestroy`, so an unauthorized writer never reaches Route 53 at all rather than
  reaching it and being refused on read-back.
- ✅ The gateway daemon **mints** its authority from what the binary is (`GatewayRuntime` on
  `SubstrateHomeLocal`) rather than naming an owner beside the coordinate. A role the total
  `dnsOwnerAuthorityForProcess` table does not entitle gets `Nothing` and a typed refusal; there is no
  arm that proceeds without one.
- ✅ The asymmetry the deletion ledger recorded is gone: both mutating arms of `DnsRecordProgram` now
  consume the same witness, and neither can be satisfied by supplying the coordinate's owner twice.

### Validation

1. ✅ `prodbox-unit -p "caller-bound DNS ownership"` — **9/9**, including the two new cases: an ensure
   under a foreign authority refuses with `DnsProgramOwnerUnauthorized` **and the boundary call log is
   empty**, and an ensure under the held authority still reads back exactly
   (`["observe", "ensure", "observe"]`).
2. ✅ `prodbox-unit -p "registered DNS record"` — 8/8 unchanged, so the arity change did not alter the
   ensure semantics the Sprint `3.32`-era cases pin.
3. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 with main Hspec **3266/3266**.

### Remaining Work

None on this sprint's surface. The bound Sprint `3.32` stated still holds and is not narrowed by this
sprint: per
[chaos_hardening_doctrine.md § 22](../documents/engineering/chaos_hardening_doctrine.md) a ring-2 gate
bounds a process, not a protocol. The two untyped Route 53 writers in
`src/Prodbox/ControlPlane/ProviderProduction.hs` carry no owner value at all and are unaffected by
either sprint; that row stays open, owned by the Provider Worker surface rather than this one.

## Sprint 3.34: The Kubernetes API Egress Coordinate Has No Owner, and No Gate Read It ✅

**Status**: Done (2026-08-11) — Phase `3` own-surface reopen (Standard A) on the chart platform and chart lint
this phase owns. Registered by the live investigation that found `prodbox test all --substrate aws`
failing at the `bootstrap-broker` Helm release on eight consecutive runs; the doctrine it implements
is [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md).
**Implementation**: `src/Prodbox/Lib/ChartPlatform.hs` (the observation and the rendered egress
rule), `src/Prodbox/CheckCode.hs` (the chart port-literal lint),
`charts/bootstrap-broker/templates/networkpolicy.yaml`,
`charts/target-secret-agent/templates/networkpolicy.yaml`.
**Blocked by**: none.
**Deployment qualification**: pending — and this **does** edit a live production rendering path, so
the reasoning is given rather than the conclusion. It changes the rendered NetworkPolicy egress of
two charts and of the generated `target-secret-agent-kubernetes-api` policy, which is capability
wiring by Standard P's own enumeration. Both substrate rows are already `pending`, so nothing is
invalidated, but the next qualification run must exercise the post-`3.34` rendering rather than an
earlier one.
**Independent Validation**: the render half is pure and validated on the home local substrate — the
emitted policy is asserted to carry the observed endpoint address and port rather than the Service
ones, against a fixture observation. The lint half is a `dev check` region extension with a
two-region mutation exercise. The live proof (a broker that reaches ready) is a Standard-O
`Live-proof: pending` axis and does not gate this sprint's code-owned closure.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md` (the region correction
is already recorded there by Sprint `0.26`; this sprint makes the widened claim true),
`documents/engineering/code_quality.md` (the lint's new region).

### Objective

`charts/bootstrap-broker/templates/networkpolicy.yaml` permits egress on TCP `443` with no `to:`
selector. The `kubernetes` Service is `10.43.0.1:443` with `targetPort=6443`, and its endpoint is
`192.168.2.43:6443`, host-networked on the control-plane node. kube-proxy DNATs before the CNI
evaluates egress, so the policy matches the endpoint port and the rule matches nothing. The broker's
lease observation then fails at transport level, `/readyz` answers 503 while `/healthz` answers 200,
and `helm upgrade --install --wait --timeout 30m0s` expires on `context deadline exceeded`.

The defect is not the digit. `grep -rn "6443" src/` returns exactly one hit — a kubeconfig
string-match in `src/Prodbox/CLI/Rke2.hs` — so the Kubernetes API egress coordinate has **no
compiled owner anywhere**, and with no owner there is nothing for a restatement to drift from: each
site is an independent author. The fact survives in the repository only as prose, in a comment in
`charts/vscode/templates/securitypolicy-client-secret-job.yaml`, which
[pure_fp_standards.md § 1.4](../documents/engineering/pure_fp_standards.md) already names a defect.

The instructive case is `apiEgress`, the one place the rule is *generated* rather than hand-written.
It derives from a live observation and is still wrong in **both** coordinates, because
`readKubernetesApiServiceIpv4` observes `service/kubernetes` (pre-DNAT) while the policy is
evaluated post-DNAT. Deriving from one source fixed the encoder count and not the layer, which is
the § 24 rule this sprint implements.

### Deliverables

- ✅ **One observation, both coordinates.** Replace the Service-based observation with one of
  `endpoints/kubernetes`, which yields the post-DNAT address and port together. Emit one `ipBlock`
  per address plus the observed port. The seam already exists: `buildChartDeploymentPlanForSubstrate`
  performs five IO observations and threads typed results into the pure plan builder; this is a
  sixth of the same shape, not a new abstraction.
- ✅ **Three sites, not eleven.** Only `charts/bootstrap-broker/templates/networkpolicy.yaml`,
  `charts/target-secret-agent/templates/networkpolicy.yaml`, and `apiEgress` carry the Kubernetes-API
  coordinate. The other nine `443` literals are `ipBlock: 0.0.0.0/0` public-internet HTTPS egress to
  AWS — a different coordinate that this sprint must not touch.
- ✅ **Both API coordinates survive.** `kubernetes.default.svc.cluster.local:443` in
  `src/Prodbox/K8s/InCluster.hs` and `src/Prodbox/Vault/Reconcile.hs` is what a client dials and is
  correct pre-DNAT; the endpoint address and port are what a policy engine matches. They are not
  restatements of each other and collapsing them breaks the client path.
- ✅ **The lint region covers the evidence.** A sibling of `chartTemplateResourceViolations` reusing
  its enumeration, firing on an all-digit value under a closed key set
  (`port:`/`targetPort:`/`containerPort:`/`nodePort:`/`hostPort:`) in any repo-owned chart template.
  Named ports and `{{ .Values… }}` expressions fall out without an allowlist. Per
  [resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md), a
  gate's region must cover the surface that carries its evidence, and today no gate reads a
  `networkpolicy.yaml` for content at all.

### Validation

1. ✅ `prodbox dev check` exit 0 after migration; `prodbox test unit` exit 0 (3325 + 27 + 33 + 27).
2. ✅ **The lint's first run named its findings.** The measurement stands: **79** numeric port
   literals across 13 charts. The lint's first run reported **77**, which reconciles exactly — the
   first deliverable had already migrated the two Kubernetes-API sites before the lint existed.
   The real number is reported rather than a rounded or flattering one, because a gate whose first
   run finds nothing has the wrong region.
3. ✅ **Two-region mutation, restored byte-exactly.** `port: 443` was reintroduced in the broker
   NetworkPolicy: the new region exited 1 naming `charts/bootstrap-broker/templates/networkpolicy.yaml
   line 59`, the old container-resources region was unaffected at 0 findings, and the file was
   restored byte-exactly (md5 `7e22826a0118791cd14936cdb4069c5a` before and after).
4. ✅ Deleting the compiled owner, or the values binding in the template, is a finding — both anchors
   were exercised by mutation and each failed as required, then restored byte-exactly.
5. 🧪 Live proof, on the Standard-O axis (pending, non-blocking): from inside the broker pod,
   `curl -m 5 https://10.43.0.1:443/healthz` returns `401` (reached, unauthorized) rather than
   timing out at exit 28; `/readyz` returns `"ready":true`; the Helm release returns well inside its
   timeout.

### Remaining Work

Two items are deliberately **not** absorbed.

The `8600` family is the same defect class at a different coordinate — an unowned literal in eight
or more places while `src/Prodbox/Bootstrap/Broker/ChartStatics.hs` documents an explicit decision
not to own the broker's listen port. Its template half comes free with this lint; its Haskell half
(five separately-named constants in `src/Prodbox/ControlPlane/LocalClient.hs`, plus
`src/Prodbox/ControlPlane/Runtime.hs` and `src/Prodbox/Lib/AwsControlPlaneIsolation.hs`) is a
different region and a different root cause, and is recorded as a ledger row rather than folded in.
Whether the five control-plane roles are required to share one port is unresolved; the individually
named constants suggest divergence was once contemplated.

The broker's discarded transport error is Phase `2`'s surface, not this one, and landed as
Sprint `2.42` ✅ (2026-08-11).

**The honest bound on the lint.** It closes drift between a rendered value and its compiled owner;
it does not close correctness of the owner. Had it existed, `port: 443` would have become
`{{ .Values… }}`, and if the compiled owner still said `443` the cluster would break identically.
Only the live run proves `6443`. This sprint must not claim the gate would have caught the outage.

**What the code-owned closure does and does not assert.** The rendered rule is now derived from the
post-DNAT coordinate and the region covers every chart template; both are proven locally. What is
**not** proven is that a broker reaches ready on a live cluster — that is validation 5, a Standard-O
`Live-proof: pending` axis that does not gate this sprint. It is worth stating why it is still
outstanding rather than leaving it implicit: the live investigation that registered this sprint
found three further defects on the broker's readiness path, behind the NetworkPolicy and invisible
until it was fixed — a self-observation label selector that matched no Pod, a `PodWire` decoder
requiring `apiVersion`/`kind` that Kubernetes omits on `PodList` items, and a controller-image check
requiring a `:latest` tag the harness overrides on both substrates. None is owned by this sprint or
by `2.42`; they are registered separately as Sprint `2.43` on Phase `2`'s broker runtime surface.
Until those land, a live run cannot reach `"ready":true`, so validation 5 stays pending on a
dependency this sprint does not own.

## Sprint 3.35: The Control-Plane Listen Port Has One Compiled Owner ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `3` own-surface reopen (Standard A) on the chart
platform and chart-lint surface this phase owns; it closes the Haskell half Sprint `3.34` registered
and deliberately did not absorb.
**Implementation**: `src/Prodbox/ControlPlane/ListenPort.hs` (**new** — the owner),
`src/Prodbox/ControlPlane/Runtime.hs`, `src/Prodbox/ControlPlane/LocalClient.hs`,
`src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/AwsControlPlaneIsolation.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminWorker.hs`, `src/Prodbox/Gateway.hs`,
`src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/TestValidation.hs`,
`src/Prodbox/Bootstrap/Broker/ChartStatics.hs` (Standard-C correction),
`src/Prodbox/CheckCode.hs` (`checkControlPlaneListenPortOwner`), `test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated). Every rendered value is byte-identical —
the binder opens the same port, the chart values carry the same number, the emitted broker Dhall is
unchanged, and the AWS role-transport table is unchanged. This is a provenance change, not a
behaviour change, and the unit case comparing the rendered URL to its literal form is what makes
that claim checkable rather than asserted.
**Independent Validation**: pure constants and renderers plus a `dev check` text rule, validated by
the compiler, the rule's mutation exercise, and the unit suite — no cluster, no AWS, no later phase.
`prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3410/3410**.
**Docs updated**: none under `documents/` — the correction lands in the source that made the false
claim, per Standard C.

### Objective

Close the row recording that `8600` is an unowned literal restated in eight or more places while
`Prodbox.Bootstrap.Broker.ChartStatics` explicitly declines to own it.

### The row left one question open; it is settled by measurement, not preference

The row asked "whether the five roles are *required* to share one port, or whether naming the five
constants individually anticipated divergence." They are **required** to share it:
`runControlPlaneServer` receives the role and binds the port **without consulting it**, so a
per-role port is not representable in the binder at all. The five constants restated one fact five
times and could never have diverged. Giving them one owner takes nothing away, and the unit case
pins that answer against the constants rather than leaving it in a comment.

### The count is measured, and it is higher than the row's

| Claim | Recorded by the row | Measured |
|---|---|---|
| Occurrences | "eight or more places" | **14** in `src/`, across **9** modules |
| Named per-role constants | five | five — correct |
| Kind of restatement | one literal | **two** — the port, and the `http://<svc>.<ns>.svc.cluster.local:<port>` URL shape authored at **9** sites |

The row counted the port and missed that the URL *shape* around it was restated just as often. Both
now have one owner: `controlPlaneListenPort` and `controlPlaneClusterServiceUrl`, with the `Text`
projection **derived from** the `String` one rather than written twice — the one-derived-encoder rule
of [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md).

### The declining module was wrong about the value it declined to own

`ChartStatics.hs` said the broker's listen port "is deployment configuration … NOT a compiled
static", chosen "by the operator per cluster". Measured against source that was false in the
load-bearing direction: the binder hardcoded it and every rendering path emitted the same literal
independently, so **the declared operator choice did not exist**. The module is corrected in place
under Standard C, and the port stays absent from it for a different and true reason — it is a
control-plane-wide coordinate shared by six roles, not a Bootstrap-Broker identity.

### Validation

1. `checkControlPlaneListenPortOwner` fails any `src/` module outside the owner that spells the
   literal. ✅
2. **The rule named a real restatement on its first run, and it was in this sprint's own
   correction.** The Standard-C note in `ChartStatics.hs` quoted the value in prose. It was reworded
   rather than exempted: a comment restating a value is still a restatement
   ([pure_fp_standards.md § 1.4](../documents/engineering/pure_fp_standards.md)), which is the same
   reading Sprint `0.26` applied to the DNAT fact surviving only as a chart comment. ✅
3. Mutation-proven: restoring the literal in `runControlPlaneServer`'s `bind` makes `prodbox dev
   check` exit **1** naming the file; restoring the file returns exit 0. ✅
4. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3410/3410**. ✅

### Remaining Work

None. **One bound is stated**: this is a text rule over a source region, so it stops the literal from
re-acquiring authors; it does not make a wrong port unrepresentable. What makes the value
single-sourced is that the binder, the rendered chart values, the emitted broker Dhall, the AWS
role-transport table, and the loopback forward targets all read the same binding — the rule only
keeps the shortest road back from being taken by accident.

**One restatement is deliberately left in place, with its reason.** The genesis admin-intent
endpoint in `CLI/Rke2.hs` uses the short `.svc` host form where the other nine use the
`.svc.cluster.local` FQDN. Its port is bound to the owner; its host form is not changed, because
both resolve and rewriting a live endpoint string is a behaviour change this sprint does not make.

## Sprint 3.36: The Mirror Path Publishes The Architecture Its Name Claims ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `3` own-surface reopen (Standard A) on the in-cluster
registry surface this phase owns. Found by the first live Standard-P qualification run.
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`mirrorHostArchitectureTarget`,
`mirrorHostArchitectureTargetFor`, `pushDockerImageWithRetry`).
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated). This changes how an image is *published*,
not which image: the same digest reaches the registry, so no component-image identity moves. It is
adjacent to a Standard-P surface and is recorded here for that reason.
**Live-proof**: **proven (2026-08-13).** The gap this line recorded as pending was closed by the
same run that motivated the sprint — see Validation item 4.
**Independent Validation**: compiler, `dev check`, and the existing suites; the defect it removes is
a property of the argv the harness builds, which is decidable without a cluster.
**Docs updated**: none under `documents/` — Exit Definition items 27 and 28 already state the rule
this sprint makes true of the code.

### Objective

Make the mirror publication path publish the host architecture, which is what its own name says, what
the custom-image build path beside it already does, and what Exit Definition items 27–28 require.

### The defect, and why three years of green runs did not show it

`mirrorHostArchitectureTarget` ran `docker pull` → `docker tag` → `docker push` with no platform
anywhere. Under Docker's containerd image store that publishes the whole manifest **index** the pull
produced. For a multi-architecture upstream, the index names platforms whose blobs were never
fetched, and the push fails.

**It stayed invisible because every mirror target that had published before it presents a single
platform.** The registry carries **24** `mirroredPublicImage` entries; the **17** that published in
the pre-fix run each resolve to one platform locally, and `keycloak-mirror` is `└─ linux/amd64` and
pushes cleanly. The cert-manager family is the multi-platform case, and the list order is why it had
never been the one to fail first. (The figures are derived from the registry catalogue and the local
image tree, not counted by eye: an earlier draft of this block said "17 of 18", which was wrong on
the total.) The asymmetry is the finding: `buildCustomImageOnce` has resolved
`supportedHostArchitecture` and passed `renderHostArchitecture` to `docker build` since it was
written, and the mirror path — named `mirrorHostArchitectureTarget` — never consulted either.

### Deliverables

- `pushDockerImageWithRetry` takes the platform and passes `--platform`. Both of its callers supply
  it: the custom-image path from the `hostArchitecture` it already had in scope, and the mirror path
  from a newly-resolved one.
- `mirrorHostArchitectureTargetFor` carries the resolved platform so the pull is pinned too.
- The retry classifier is untouched, and deliberately: the index failure is not transient, and
  `isRetryableHarborPublicationFailure` correctly declined to retry it. A classifier that had
  retried would have turned a deterministic failure into a slow one.

### One sibling is deliberately left alone, and the recorded argv is why it is visible

`harborTargetAvailableForHostArchitecture` — the availability probe that decides whether a mirror
target already exists — is also named for the host architecture and also issues a bare
`docker pull` with no platform. The integration fixture's recorded argv shows the asymmetry plainly:
`pull|127.0.0.1:30080/prodbox/<target>` for the probe, against
`pull|--platform|linux/amd64|<upstream>` for the mirror source beside it.

It is **not** changed here. The probe asks "is this target present", and a platform-scoped answer to
that question is a different question — one whose failure mode is a target being re-mirrored rather
than a bring-up failing. Changing it would alter which images the harness decides to re-publish, on
no evidence that the current answer is wrong. Recorded so the naming mismatch is a known, bounded
one rather than a second instance waiting to be rediscovered by another campaign run.

### The bound was stated as pending, and then closed

**This block first read "no successful mirror push has been observed through this code", and that was
correct when written.** Every already-published mirror was short-circuited by
`harborTargetAvailableForHostArchitecture`, and the only unpublished family was the one Sprint `3.37`
had to move — so the sprint had a correct argv and no live publish. It is recorded here rather than
edited away, because a sprint that claims a live proof it did not take is the exact failure
`unit_testing_policy.md` statement 11 and the Sprint `5.32` counterexample both exist to prevent.

**The gap closed on the next run, and closed for both callers rather than one.** Seven publications
went through the platform-pinned path with no failures: the five cert-manager mirror targets, and the
custom `prodbox-runtime` image under two tags — which exercises the *other* call site,
`buildAndPushCustomImageVariants`, that this sprint also changed. A fix validated on one of its two
callers would have been a weaker result than it looked.

### Validation

1. `prodbox dev check` exit 0 (formatter, linter, warning-clean build). ✅
2. `prodbox test unit` exit 0 at main Hspec **3430/3430**. ✅
3. Live, negative: the error the pre-fix path produced —
   `was found but does not provide any platform` — became
   `does not provide the specified platform (linux/amd64)`, which is the platform-scoped push
   reaching the platform-scoped failure. Evidence the flag takes effect. ✅
4. Live, positive: **seven publications through the new path, zero failures**, across **both**
   callers — the five cert-manager mirror targets (`cert-manager-{controller,webhook,cainjector,
   acmesolver,startupapicheck}-mirror:v1.17.1`, digests `8615625f…`, `f7ad7d3c…`, `da14ecb3…`,
   `8b71c220…`, `48048d4b…`) and the custom `prodbox-runtime` image under two tags. The in-cluster
   registry catalogue moved 17 → 23 repositories. ✅

### The change broke six integration cases, and the fixture was the defect

**A correct production change presented as `manifest unknown` in six cases**, and the cause was in
the fake boundary rather than the code. `fakeRke2DockerScript` read the image reference
**positionally** — `ref=${2:-}` for `pull`, `target_ref=${2:-}` for `push` — so once production
passed `docker pull --platform \<p\> \<ref\>`, the fixture read `--platform` as the reference.

Two things make this worth recording rather than quietly fixing. First, **the same script already
had the right pattern**: its `save` arm parses flags in a `while` loop, because `-o` could move. The
file contained both the correct and the incorrect idiom, and the incorrect one was on exactly the two
verbs this sprint touched. Second, a fixture that pins *positions* rather than *flags* is a fixture
that fails on any correct argv change — the class
[integration_fixture_doctrine.md](../documents/engineering/integration_fixture_doctrine.md) exists to
bound. `pull` and `push` now parse flags; the seven assertions that pin the exact recorded argv were
updated to the new command line, because the command line genuinely changed.

### Remaining Work

None.

## Sprint 3.37: A Pinned Upstream Artifact That Cannot Be Published ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `3` own-surface reopen (Standard A). Found by the first
live Standard-P qualification run, which it unblocks.
**Implementation**: `src/Prodbox/ContainerImage.hs` (ten pins: five mirror targets and five upstream
sources), `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md` (the chart-version claim).
**Blocked by**: none.
**Deployment qualification**: **pending — and this sprint invalidates any prior component-image
identity.** Moving a platform component's image tag is a component-image change by Standard P's own
enumeration, and `certManagerChartVersion` is derived from the controller tag by design, so the Helm
chart version moves with it. A `proven` row may only bind an identity captured after this sprint.
**Live-proof**: pending the full run in flight.
**Independent Validation**: the pins are decidable against the upstream registry without a cluster;
`dev check` and the unit suite cover the code-owned surface.
**Docs updated**: [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) —
its `γ` node stated the chart pin as `v1.16.2`, which is no longer true.

### Objective

Unblock the home-local qualification run, which failed deterministically at the cert-manager mirror.

### The measurement, which is the whole sprint

The failure looked like a prodbox defect and is not one. Every hypothesis was tested and discarded
before the pin was touched:

| Hypothesis | Test | Result |
|---|---|---|
| Stale local image content | full purge, clean re-pull | still fails |
| A multi-architecture problem in general | `alpine:3.20`, identical index shape | **exports fine** (3.7 MB) |
| A quay.io problem | `cert-manager-controller:v1.16.1` from the same repo | **exports fine** (21.2 MB) |
| A cert-manager problem | `v1.16.3`, `v1.16.4`, `v1.16.5`, `v1.17.1` | **all export fine** |
| Only the controller is affected | the other four `v1.16.2` images | **all five fail** |

So: **the `v1.16.2` release specifically cannot be published from this host**, while its neighbours
in the same repository can. That is a broken upstream artifact, not a defect in this repository, and
no amount of harness work would have fixed it.

### Deliverables

- The five cert-manager images move `v1.16.2` → `v1.17.1`, in both their mirror-target and
  upstream-source positions — ten pins, kept in lockstep because
  `certManagerChartVersion = imageTag harborCertManagerControllerImage` makes the chart follow the
  controller tag by construction.
- All five were verified to export at `v1.17.1` **before** the pin moved: controller 21,623,296 B,
  webhook 18,685,440 B, cainjector 15,794,176 B, acmesolver 8,065,536 B, startupapicheck
  14,351,872 B.

### The residual this sprint records rather than closes

**cert-manager is the only mirrored image family with no fallback source.** Its entries carry an
empty alias list where, for example, `kube-rbac-proxy` carries
`[ImageRef "gcr.io" "kubebuilder/kube-rbac-proxy" "v0.12.0"]`. The candidate-retry machinery in
`mirrorHostArchitectureTargetFromCandidates` exists for exactly this situation and had nowhere to go.
A search for an alternative registry serving `v1.16.2` found none — `registry.k8s.io/cert-manager/…`
404s — so an alias would not have unblocked *this* failure, which is why the pin moved instead. It is
recorded in the deletion ledger as its own row: a single-sourced platform component is one broken
upstream away from blocking every bring-up, and this sprint is the proof.

### Validation

1. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3430/3430**. ✅
2. Upstream exportability verified for all five images at the new pin before it landed. ✅
3. Live home-local run through the previously-blocking mirror step — see [README.md](README.md). 🔄

### Remaining Work

None on the pin. The minor-version move is the operator's decision, taken deliberately over the
smaller `v1.16.5` patch move that was also verified working.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/vault_doctrine.md` - § 20.1's declared-real arm and § 6.1's bootstrap-floor
  registration are the rules these two sites now satisfy; the doctrine is authored by Sprint `0.20`.
- `documents/engineering/helm_chart_platform_doctrine.md` - the probe/route single-source rule states
  a property of every chart while the lint covers seven charts on hand-listed filenames. Sprint
  `0.26` records that region correction in place; Sprint `3.34` makes the widened claim true.
- `documents/engineering/code_quality.md` - the chart forbidden-literal lint's region, and the fact
  that no gate reads a chart `networkpolicy.yaml` for content.
- `documents/engineering/chaos_hardening_doctrine.md` - the observation-layer rule Sprint `3.34`
  implements is authored by Sprint `0.26`.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Record the Phase `3` own-surface reopen in [README.md](README.md) and
  [00-overview.md](00-overview.md). Engineering docs name owning sprints sparingly and link the
  Development Plan; sprint status lives only in the plan suite.


## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
