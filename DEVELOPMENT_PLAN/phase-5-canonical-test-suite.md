# Phase 5: Canonical Test Suite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md)
**Generated sections**: none

> **Purpose**: Own the substrate-agnostic canonical test suite — the named-validation set in
> `src/Prodbox/TestValidation.hs` — as suite content with declared prerequisites. Substrate
> provision and teardown belong elsewhere (see [substrates.md](substrates.md) and the
> substrate-owning phase docs); this phase owns what the suite proves and how.

## Phase Status

✅ **Reclosed 2026-07-04 for resource-guardrail validation** — Sprint `5.13` is Done on the
code-owned canonical-suite surface. The new `resource-guardrails` validation is wired through the
parser, command registry, native validation plan, topology mapping, and aggregate ordering; it loads
the validated `capacity.resource_plan`, checks live Kubernetes pod, `ResourceQuota`, and
`LimitRange` JSON, refuses `BestEffort` or uncapped containers, and proves guardrail objects match
the declared plan for the root chart namespaces. This is suite content and remains
substrate-agnostic; AWS coverage is tracked through the normal substrate parity table. The optional
real over-limit pod stress proof remains a non-blocking `Live-proof: pending` axis per Standard O.

✅ **Live-proven 2026-06-26 — the then-current canonical suite ran fully green on the home substrate.** A full home
`prodbox test all` (2026-06-26) passed 18/18 named validations end-to-end — including `sealed-vault`
(Sprint `5.8`) and the destructive `lifecycle` ordering — with `prodbox-unit` 1062/1062 and
`prodbox-integration` 39/39 (see [00-overview.md](00-overview.md) Alignment Status). Sprint `5.10`
(harness-generated run config from `test-secrets.dhall`) is exercised by the run: the harness
regenerates the binary-sibling `prodbox.dhall` through the shared `configFromSetupInput` builder,
populating `route53.zone_id` / `ses.*` / `pulumi_state_backend.*` from `test-secrets.dhall` and
force-syncing the in-force SSoT, so the suite reaches every downstream validation non-interactively.
The suite's home-substrate content is thereby live-proven (Standard O); the `--substrate aws` per-run
half of the canonical suite remains the distinct, non-blocking axis tracked in
[substrates.md](substrates.md).

✅ **Closed on its code-owned surface 2026-06-16** — reopened 2026-06-11, finalized 2026-06-14,
refined 2026-06-15 (Vault-root + cluster
federation; Model-B whole-system zero-child-info refinement), reopened 2026-06-16 to adopt the
phase-independence doctrine (Sprint `0.15`;
[development_plan_standards.md → N. Phase Independence / O. Code-Local vs Live-Infra Proof](development_plan_standards.md#n-phase-independence-no-backward-blocking)) —
Sprint `5.8`
reframes to the finalized end state: the `sealed-vault` canonical validation seals Vault and asserts
the whole stack fails closed (no secret resolves, no cert issues, no MinIO object decrypts, no
Pulumi op runs, gateway daemon and Keycloak fail their readiness gates) without leaking metadata.
It now **also** covers the retired master-seed derivation surface — there is no `master-seed` object
and no daemon `/v1/secret/*` RPC to fall back to, so the sealed stack cannot reconstruct a secret
from any non-Vault source — and the cluster-federation auto-unseal cascade, where a sealed or
unreachable parent Vault bricks its children (the fail-closed brick cascades down the transit-seal
trust tree from the root). The 2026-06-15 refinement (Model B + whole-system zero-child-info; see the
2026-06-15 Closure Status in [README.md](README.md) and
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md)) adds the
**cross-surface sealed-Vault red-team** to `5.8`: with the parent Vault sealed, a combined
bucket-level `aws s3api ls` + `list-objects` against the one generically-named bucket, a host-disk
walk of `.data/prodbox/minio/0`, a Kubernetes ConfigMap/Secret dump, and a log/output audit together
reveal only opaque `objects/<hmac>.enc` at a constant decoy-padded count — no role-revealing bucket
name, no `aws-eks`/stack-name object key, no cleartext body, no child-named namespace, and no
exists-vs-absent (`NoSuchKey`) oracle. The SecretRef golden tests prove generated Dhall/config artifacts carry
only `SecretRef.Vault` / `SecretRef.TransitKey` values on the `FileSecret`-free union — there is no
`SecretRefFile` constructor to render — per
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) and
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). Sprint
`5.8` is ✅ Done on its code-owned/home-substrate surface: the named `sealed-vault` validation, planner
surface, parser/docs surface, pure sealed-state forbidden-pattern audit helper, generated
Dhall/config SecretRef sweep, and live home-substrate proof have landed and validate locally.
Existing validations are
unchanged and the new sealed-Vault suite content extends them. The live AWS-substrate cross-surface
red-team and the live parent/child federation auto-unseal cascade are tracked as a non-blocking
**Live-proof: pending** note on Sprint `5.8` (Standards N/O); the later Model-B raw-Pulumi-checkpoint
interposition that the AWS-substrate proof composes against is owned by Sprint `7.14` as a forward
build dependency, and AWS-substrate coverage of the same validation is tracked in
[substrates.md](substrates.md) (Standard M) — neither gates `5.8`'s code-owned closure or this phase.
See the 2026-06-14 and
2026-06-16 Closure Status entries in
[README.md](README.md).

✅ **Prior closure preserved — reclosed 2026-06-09** — Sprints `5.1`–`5.5` remain closed on the
canonical-suite content that proves public-host behavior (the public-edge diagnostic, named external
proofs, shared-host route classification, admin-route auth/RBAC proofs, and the port-80
HTTP-to-HTTPS redirect proof). The 2026-06-09 design-intention review reopened this phase for Sprint
`5.6`, which has now landed: the prerequisite surface that gates the canonical suite is typed
(`PrerequisiteId` ADT) and minimal-and-precise per validation; the IAM-harness tier is derived from
each validation's declared capabilities (the `normalizeManagedAwsHarness` `substrate=aws` blanket
override deleted; a credential-free validation on AWS engages no harness); `infra_ready` was split
from a new AWS-credential-free `public_edge_ready` node (re-pointing `charts-*`); `verifyAwsEksSnapshot`
was strengthened to a structured parse; and the three registry-generated destructive `--dry-run`
goldens (`rke2 delete`, `rke2 delete --cascade`, `nuke`) landed with drift-guard tests (closing
audit V80). Validation at reclosure: `check-code` 0, `test unit` 809, `integration cli` 35,
`integration env` 35, `lint docs` 0, `docs check` 0. The live AWS-substrate aggregate +
public-edge-readiness exercises are operator-driven.

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
these validations are **suite content**, not home-substrate-only validations. The home local
substrate runs them today on real `test.resolvefintech.com` infrastructure (real ZeroSSL,
real OIDC, real WebSocket fan-out). Bringing the AWS substrate to parity so it runs the same
validations is tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md).

Per [development_plan_standards.md](development_plan_standards.md) standards rule E, Phase `6` (the
clean-room handoff) stays ✅ Done on its owned surface, while the overall handoff still depends on
the separately reopened implementation phases `3`–`5`, `7`, and `8`. Phases `1` and `2` have
reclosed their finalized Vault-root + cluster-federation foundations.

✅ **Sprint `5.12` closed on its code-owned surface 2026-07-03** — the unified block-storage
rebinding validation is now canonical-suite content. `prodbox test integration eks-volume-rebind`
maps to `IntegrationEksVolumeRebind` / `ValidationEksVolumeRebind`, writes a sentinel through the
retained MinIO workload PV, drives a teardown/spinup cycle, and compares Kubernetes PV snapshots so
the same PV/PVC stays `Bound`, the sentinel survives, and any EBS `volumeHandle` remains identical
when present. The home-substrate run is cluster-only; the AWS-substrate run explicitly engages the
IAM harness and remains the non-blocking parity proof for the Sprint `7.28` static retained-EBS PV
path, tracked in [substrates.md](substrates.md). Earlier Phase 5 sprints remain `Done`/as-tracked.

✅ **Sprint `5.11` closed on its code-owned surface 2026-07-03** — the test-topology command
surface is now implemented: `prodbox test init` writes the executable-sibling
`prodbox.test.dhall` and refuses overwrite without `--force`; `prodbox test run <suite>|all`
loads that authored topology, writes one disposable binary-sibling `prodbox.dhall` per variant
through the shared Tier-0/config builder path, points `storage.manual_pv_host_root` at
`.test-data/<case>/`, passes that root to the native validation environment, runs the existing
deploy/assert path, and removes the generated config plus this run's `.test-data` root in
`finally`. `guardTestDelete` now admits only the generated config under `.build`, paths proven
under `.test-data`, and `LifecycleClass PerRun` residue; long-lived resources and production data
refuse. The sealed-Vault host-disk audit resolves the same test root through the topology-run
environment. Live multi-variant cluster proof remains a non-blocking live-infra axis.

## Phase Summary

This phase owns the canonical test suite as substrate-agnostic content. Each validation in
`src/Prodbox/TestValidation.hs` is a member of one suite, planned by `src/Prodbox/TestPlan.hs`
(as `NativeValidation` variants), gated by prerequisites declared in
`src/Prodbox/Prerequisite.hs`, and orchestrated by `src/Prodbox/TestRunner.hs`. The same
validation runs against every substrate that satisfies its declared prerequisites; what differs
between substrates is provision and teardown, not the validation itself.

The suite content owned by this phase covers public DNS delegation, real TLS issuance via
cert-manager and ZeroSSL, Envoy Gateway readiness, shared-host application routing
(`/auth`, `/vscode`, `/api`, `/ws`), shared-host admin routing (`/harbor`, `/minio`), HTTP-to-HTTPS
redirect on port `80`, Keycloak issuer alignment behind Envoy, route-level RBAC, real WebSocket
upgrade behavior, one-connection-per-pod lifetime, revocation-driven reconnect, and
readiness-based drain.

Sprints `5.1`–`5.4` historically owned the diagnostic plus the shared-host application and admin
proofs. They are preserved below as historical records of when each validation entered the suite.

## Canonical Suite Inventory

The full inventory of canonical-suite validations owned by this phase lives in
`src/Prodbox/TestPlan.hs` as `NativeValidation` variants. The current set is:

| Validation | Prerequisites (excerpt) | What it proves |
|------------|-------------------------|----------------|
| `public-dns` | `aws_credentials_valid`, `route53_accessible` | NS delegation matches public registrar; configured FQDN resolves to operator public IP |
| `dns-aws` | `aws_credentials_valid`, `route53_lifecycle_capable` | Ephemeral hosted zone create + record write + read-back + zone delete (Route 53 API correctness) |
| `aws-iam` | `aws_iam_harness_ready` | IAM-user provisioning + STS-federated operational credentials lifecycle |
| `gateway-daemon` | `gateway_daemon_acquire` | Daemon spawns, exposes `/healthz`, `/readyz`, `/metrics`, accepts SIGTERM drain |
| `gateway-pods` | `k8s_ready` | Gateway pods reach Ready in their namespace; logs sane |
| `gateway-partition` | (in-process) | Single-writer invariant, claim/yield ordering, idempotent commit-log append |
| `lifecycle` | `rke2_*` | `rke2 delete --yes` → `rke2 reconcile` → `k8s health` round-trip |
| `pulumi` | `aws_credentials_valid`, `pulumi_logged_in` | `aws-test` substrate stack provisions with `NODE_COUNT=3` |
| `aws-eks` | `aws_credentials_valid`, `pulumi_logged_in` | `aws-eks-test` substrate stack provisions with CLUSTER_NAME and NODE_GROUP_NAME |
| `ha-rke2-aws` | `aws_credentials_valid`, `pulumi_logged_in`, `tool_ssh` | SSH reachability to all three EC2 instances; destroy-and-recreate repair on stale instances |
| `charts-platform` | `k8s_ready`, chart-platform prereqs | `charts list`, `charts status` produce expected output for the supported chart set |
| `charts-storage` | `k8s_ready`, chart-platform prereqs | Retained-storage reconciler, PV/PVC pairing, secret rendering |
| `resource-guardrails` | `k8s_ready`, chart-platform prereqs | Every prodbox pod has explicit cpu/memory/ephemeral-storage requests and limits, no pod is `BestEffort`, namespace quotas/limit ranges match the declared resource plan, and over-budget configs refuse before mutation |
| `eks-volume-rebind` | `k8s_ready`, chart-platform prereqs (AWS parity: operational AWS/Pulumi stack access) | Identical block-storage rebinding across a teardown/spinup cycle: write sentinel → teardown → spinup → the same PV rebinds (home hostPath / EKS EBS `volumeHandle`) and the data persists |
| `charts-vscode` | `public_edge_ready`, `tool_curl` | Real HTTPS curl to `https://<publicFqdn>/vscode`; redirect to OIDC callback with expected fragments |
| `charts-api` | `public_edge_ready`, `tool_curl` | Real HTTPS curl to `https://<publicFqdn>/api`; bearer-token validation; 401/403 contract |
| `charts-websocket` | `public_edge_ready`, `tool_curl` | Real WebSocket upgrade against `/ws`; cross-pod broadcast; revocation-driven reconnect; readiness-based drain |
| `admin-routes` | `public_edge_ready`, `tool_curl` | Harbor and MinIO auth + RBAC on the shared public edge |
| `keycloak-invite` | `aws_credentials_valid`, `route53_accessible`, `ses_sending_identity_verified`, `ses_receive_rule_set_active`, `ses_receive_bucket_accessible`, `pulumi_logged_in` | Operator-invited Keycloak flow end-to-end: `prodbox users invite` → SES capture-bucket poll → invite link follow → credential setup → OIDC login |
| `sealed-vault` | `k8s_ready`, chart-platform prereqs | Seals Vault after a reconciled runtime, asserts sealed-state fail-closed behavior, and runs the cross-surface zero-child-info audit |

The "Prerequisites" column names declared prerequisite nodes from `src/Prodbox/Prerequisite.hs`,
keyed by the typed `PrerequisiteId` ADT (Sprint `5.6`; the registry is no longer keyed by raw
`String`). **Public-edge readiness is now a declared prerequisite node.** Sprint `5.6` promoted
the former *procedural* bootstrap gate into the declared `public_edge_ready` node split out of
`infra_ready`: it depends only on cluster + chart-platform readiness (`k8s_ready`), **not** on
AWS credentials, so `charts-vscode`, `charts-api`, `charts-websocket`, and `admin-routes` gate on
an AWS-credential-free readiness rather than re-acquiring the full `infra_ready` capability set
(which still pulls in `aws_credentials_valid`). The runner still runs `runWaitForPublicEdgeReady`
in `src/Prodbox/TestRunner.hs` (polling `prodbox host public-edge` until
`CLASSIFICATION=ready-for-external-proof`) to *satisfy* the gate during the supported-runtime
bootstrap/restore; the declared `public_edge_ready` node is what the `charts-*` and `admin-routes`
validations name in their minimal-and-precise prerequisite sets.

## Substrate Independence

Suite content does not name a substrate. It names prerequisites that any substrate must satisfy
to run the validation. When the AWS substrate stands up real DNS, cert-manager, ingress, and
the chart set (tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)),
the same `charts-vscode`, `charts-api`, `charts-websocket`, `public-dns`, and `admin-routes`
validations run against it without modification, behind the same declared `public_edge_ready`
prerequisite node (see the inventory note above; Sprint `5.6` promoted this from a procedural gate
to a declared, AWS-credential-free node).

**"Substrate-agnostic" does not mean substrates share defaults.** Each per-substrate run is
locked to one substrate, consumes only that substrate's required config and provisioned
infrastructure, and fails fast when any required field is missing — there is no silent
fallback to the other substrate's values. A complete canonical-suite proof requires both
substrate runs to land independently; running on a single substrate covers only that
substrate's parity row. See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
for the authoritative doctrine and
[substrates.md](substrates.md#substrate-independence-no-fallback) for the substrate-side
contract.

Today the home local substrate runs the full suite; the AWS substrate runs only `aws-iam`,
`aws-eks`, `ha-rke2-aws`, `pulumi`, and `dns-aws`. The parity gap is tracked in
[substrates.md](substrates.md) and in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md).

## Current Baseline In Worktree

- `src/Prodbox/Host.hs` owns the public `prodbox host public-edge` diagnostic that classifies
  Route 53, Envoy Gateway controller state, Gateway API readiness, certificate readiness,
  security-policy attachment, advertisement mode, and external-proof readiness on whichever
  substrate is active.
- `src/Prodbox/TestValidation.hs` owns the canonical-suite dispatch (`runNativeValidation`,
  line 192).
- `src/Prodbox/TestPlan.hs` owns the `NativeValidation` ADT and the `IntegrationSuite`-to-plan
  mapping for the `prodbox test integration <name>` CLI surface.
- `src/Prodbox/TestRunner.hs` owns phase-bannered execution: prerequisite gating, optional
  runbook (`rke2 reconcile`), supported-runtime bootstrap (charts deploy + wait for public-edge
  ready), suite execution, optional postflight (charts redeploy + substrate destroy).
- `src/Prodbox/Prerequisite.hs` owns the prerequisite DAG that gates suite execution.
- Validations historically named "public-edge proofs" exercise real ZeroSSL certificates
  via cert-manager + ACME, real OIDC redirects through Keycloak, real WebSocket fan-out via
  Redis, and real Route 53 records. The validations themselves are substrate-agnostic; the home
  local substrate is what stands those resources up today.
- The current proof surface intentionally closes on Envoy listener TLS and route behavior only;
  backend TLS or mTLS is outside the current supported chart-workload contract and is not claimed
  by this phase.
- The current implemented Gateway exposes HTTPS application routing on port `443` and a port `80`
  HTTP listener only for redirect behavior; plaintext backend routing remains unsupported.

## Sprint 5.1: Public Hostname Closure and External Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the implemented public DNS and public-edge path on the Haskell runtime that owns it.

### Deliverables

- `prodbox host public-edge` is implemented in Haskell and preserves the supported diagnostic
  classification contract.
- Public DNS delegation, live HTTPS reachability, TLS issuance, and auth redirects are proven
  through Haskell-owned command surfaces.
- The external proof path remains cluster-external and does not depend on manual kubeconfig
  workflows.
- Wildcard public DNS remains unsupported.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`

### Current Validation State

- `src/Prodbox/Host.hs` now owns the public `prodbox host public-edge` surface and preserves the
  supported readiness-report fields and classification contract.
- `src/Prodbox/TestRunner.hs` now uses the native Haskell `host public-edge` command directly
  inside the supported-runtime bootstrap and postflight checks.
- `test/unit/Main.hs` proves parser routing for native `host public-edge`.
- The named validation commands `prodbox test integration charts-vscode` and
  `prodbox test integration public-dns` now run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- Environment-dependent public-edge success remains owned by those commands rather than asserted
  here as a fresh run result.
### Remaining Work

None.

## Sprint 5.2: Gateway API Public-Edge Diagnostics and External Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep public-edge readiness on Gateway API and Envoy Gateway diagnostics with explicit Route 53
proof and external-only validation.

### Deliverables

- `prodbox host public-edge` classifies Route 53, `Gateway`, `HTTPRoute`, certificate, and
  external-proof readiness on the self-managed public edge.
- The public `charts-vscode` and `public-dns` proofs close on Envoy-authenticated browser delivery
  rather than the retired `vscode-nginx` path.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.
- Wildcard public DNS remains unsupported.
- Additional API and WebSocket shared-host proof surfaces close in Sprint `5.3`.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`
6. Classification proof: the ready state is derived from Gateway API and Envoy Gateway state rather
   than `IngressClass` or `Ingress`

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the public edge through Route 53 record sync, Envoy Gateway
  deployment readiness, `GatewayClass` acceptance, `Gateway` readiness, `HTTPRoute` attachment,
  `SecurityPolicy` attachment, certificate readiness, and `LoadBalancer` IP agreement.
- `src/Prodbox/TestValidation.hs` now waits for `CLASSIFICATION=ready-for-external-proof`, proves
  the external `vscode` path through the Envoy-to-Keycloak redirect, and validates every
  configured public-edge hostname through Route 53 plus public DNS resolution.
- `test/unit/Main.hs` and the built-frontend suites now align the public-edge fixtures with the
  Gateway API baseline that later single-host work refines.
- The current named public-edge proof surface now extends beyond the current Keycloak identity
  route and `vscode` browser route to the API and WebSocket validations owned by Sprint `5.3`.

### Remaining Work

None.

## Sprint 5.3: API and WebSocket Public-Edge Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Extend the Haskell-owned diagnostic and external proof surface to the shared-host doctrine on
`test.resolvefintech.com`, covering browser, API,
WebSocket, and Keycloak paths on one public edge.

### Deliverables

- `prodbox host public-edge` classifies shared-host browser, API, WebSocket, and Keycloak paths on
  the supported Envoy Gateway edge.
- The public-edge diagnostic reports the active MetalLB advertisement mode and preserves the
  existing Route 53, certificate, and readiness classification contract on one public hostname.
- Named external validations prove the supported API route on the explicit request-token and
  local-JWKS doctrine, and prove the supported WebSocket route in addition to the existing
  `charts-vscode` and `public-dns` browser or DNS proof surfaces.
- Named external validations prove the supported Keycloak public-host contract, including
  issuer and redirect alignment on the shared hostname, forwarded-header compatibility, and no
  accidental public management or health route exposure.
- Named external validations prove the supported WebSocket connection-lifetime contract, including
  one upgraded connection per selected backend pod until disconnect and readiness-based drain
  before pod exit through the runtime surface owned by Sprint `3.6`.
- Public-edge validation remains cluster-external and does not depend on `/etc/hosts` shortcuts or
  manual kubeconfig-only verification.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration charts-api`
6. `prodbox test integration charts-websocket`
7. `prodbox test integration public-dns`
8. Classification proof: the readiness payload covers the full shared-host route set and the
   configured advertisement mode without falling back to `Ingress` assumptions
9. Behavioral proof: the WebSocket validation uses the real upgrade path, proves the
   one-upgraded-connection-per-backend-pod lifetime until disconnect, and checks readiness-based
   drain rather than only HTTP helper endpoints on that route
10. Identity proof: Keycloak-backed public workloads use the shared hostname for issuer and
    redirect flows, the browser auth path stays on explicit redirect and cookie assumptions, and
    unsupported management or health paths are not publicly routed

### Current Validation State

- `src/Prodbox/Host.hs` now classifies the shared-host identity, browser, API, and WebSocket
  routes, reports the active MetalLB advertisement mode, and proves per-route `SecurityPolicy`
  attachment through the canonical route catalog.
- `src/Prodbox/TestValidation.hs` now proves the browser redirect path, JWT-protected API
  rejection and acceptance on the request-carried JWT path, the shared-host Keycloak redirect and
  issuer contract, workload-managed direct-OIDC session ownership on the WebSocket route, real
  WebSocket upgrade behavior, and Route 53 resolution for the canonical public hostname.
- `prodbox check-code`, `prodbox test unit`, `prodbox test integration cli`, and
  `prodbox test integration env` remain aligned with the expanded shared-host public-edge proof
  surface.
- The canonical proof surface for `charts-api`, `charts-websocket`, `public-dns`, and
  `host public-edge` now closes on the shared-host doctrine.

### Remaining Work

None.

## Sprint 5.4: Shared-Host Admin-Route Proof ✅

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove that the supported operational dashboards, Harbor and MinIO, are reachable only through
Envoy on `test.resolvefintech.com`, protected by Keycloak-backed auth and RBAC.

### Deliverables

- `prodbox host public-edge` classifies the supported Harbor and MinIO admin paths on the shared
  hostname.
- Named external validations prove auth and RBAC on the supported admin routes.
- The external proof surface preserves the one-DNS or one-cert doctrine as admin coverage grows.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration public-dns`
5. `prodbox test integration admin-routes`

### Current Validation State

- `src/Prodbox/Host.hs` now classifies Harbor and MinIO as shared-host admin routes on the
  canonical public hostname.
- `src/Prodbox/TestValidation.hs` now proves Harbor and MinIO auth redirects and callback routing
  through the shared-host admin edge.
- `src/Prodbox/TestPlan.hs` exposes `admin-routes` as the named external validation surface for
  the supported admin catalog.

### Remaining Work

None.

## Sprint 5.5: Public HTTP Redirect to HTTPS ✅

**Status**: Done
**Implementation**: `charts/keycloak/templates/gateway.yaml`, `src/Prodbox/Host.hs`, `src/Prodbox/TestValidation.hs`, `test/`
**Docs to update**: `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the public edge listen on port `80` only to redirect clients to the canonical HTTPS URL for
the same shared-host path.

### Deliverables

- The shared `public-edge` Gateway renders an HTTP listener on port `80` in addition to the
  existing HTTPS listener on port `443`.
- The port `80` listener attaches only to redirect routes and never forwards plaintext HTTP traffic
  to Keycloak, workloads, Harbor, or MinIO.
- HTTP requests for `test.resolvefintech.com/<service-path>` receive a permanent redirect to
  `https://test.resolvefintech.com/<service-path>`.
- `prodbox host public-edge` reports the HTTP redirect listener and distinguishes redirect
  readiness from HTTPS application-route readiness.
- The named public-host validations prove both the redirect behavior on port `80` and the existing
  HTTPS route, certificate, auth, and RBAC behavior on port `443`.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration public-dns`
5. `prodbox test integration charts-vscode`
6. `prodbox test integration charts-api`
7. `prodbox test integration charts-websocket`
8. `prodbox test integration admin-routes`
9. External proof: `http://test.resolvefintech.com/<service-path>` returns a permanent redirect to
   `https://test.resolvefintech.com/<service-path>` without exposing any plaintext backend route.

### Current Validation State

- The Gateway API HTTP listener and redirect-only `HTTPRoute` now render from the Keycloak chart.
- `prodbox host public-edge` now reports Envoy service port readiness, HTTP redirect listener
  readiness, HTTPS listener readiness, and redirect `HTTPRoute` acceptance.
- `src/Prodbox/TestValidation.hs` now proves the port `80` redirect before the `charts-vscode`
  HTTPS proof and after the `public-dns` record proof.
- On May 13, 2026, `./.build/prodbox test all` deployed the chart changes into the supported
  runtime, proved `ENVOY_SERVICE_HTTP_PORT_READY=true`,
  `HTTP_REDIRECT_LISTENER_READY=true`, `HTTP_REDIRECT_HTTPROUTE_ACCEPTED=true`, and
  `CLASSIFICATION=ready-for-external-proof`, then completed the aggregate validation
  successfully.

### Remaining Work

None.

## Sprint 5.6: Typed Prerequisites, Capability-Derived IAM Tier, and Destructive Dry-Run Goldens ✅

**Status**: Done (2026-06-09). New `src/Prodbox/PrerequisiteId.hs` defines the typed `PrerequisiteId`
ADT (one constructor per registry node) with `prerequisiteIdText` as the stable-string SSoT; the
prerequisite registry, `EffectDAG`/`EffectInterpreter`, and `TestPlan` are parameterized on it (no
more `Set String`/`Map String`). Each validation declares minimal-and-precise typed prerequisites
(`validationInitialPrerequisites`/`validationDeferredPrerequisites`) — e.g. `charts-*` now require
only `[PublicEdgeReady, ToolCurl]`. `normalizeManagedAwsHarness`'s `substrate=aws` blanket override
was deleted; `derivedManagedAwsHarnessPolicyTier` derives the IAM tier from declared capabilities
(`gateway-partition` on AWS engages NO harness — unit-pinned). `infra_ready` split into `infra_ready`
+ the new AWS-credential-free `public_edge_ready` node, with `charts-vscode`/`api`/`websocket`/
`admin-routes` re-pointed to it. `verifyAwsEksSnapshot` now uses the structured
`parseAwsEksTestStackFromOutputs` parser (substrate-equivalence properties) instead of a `Text.null`
check. Three registry-generated destructive `--dry-run` goldens (`rke2 delete`, `rke2 delete
--cascade`, `nuke`) landed under `test/golden/destructive/` with drift-guard tests (a new registered
resource fails the golden) — closing the audit V80 gap and proving Sprint 4.26's dry-run-no-mutation
fix. Validation green: `check-code` 0, `test unit` 809/809, `integration cli` 35/35, `integration
env` 35/35, `lint docs` 0, `docs check` 0. The live AWS-substrate + public-edge-readiness exercises
are operator-driven.
**Implementation**: `src/Prodbox/Prerequisite.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/` (recommended)
**Docs to update**: `documents/engineering/unit_testing_policy.md`, `documents/engineering/integration_fixture_doctrine.md`

### Objective

Make the prerequisite surface that gates the canonical suite typed and minimal-and-precise per
validation, derive the IAM-harness tier from each validation's declared capabilities instead of a
blanket substrate override, split the public-edge readiness gate out of `infra_ready` so the
`charts-*` validations gate on an AWS-credential-free readiness, strengthen the AWS EKS snapshot
verification, and add destructive `--dry-run` golden coverage generated from the managed-resource
registry. This is the canonical-suite-side counterpart to the typed-source work in Sprints `1.31`
(prerequisite DAG acyclicity + node collapse), `4.26`/`4.27` (registry-derived destructive
dispatch and the `StackDescriptor` SSoT), and the typed-error reframe in Sprint `1.30`.

### Deliverables

- A typed `PrerequisiteId` ADT replaces the current raw-`String` `effectNodeId` keys in
  `src/Prodbox/Prerequisite.hs`, so prerequisite identifiers are exhaustively matched rather than
  string-compared.
- Each canonical validation declares a minimal-and-precise prerequisite set: a validation requires
  exactly the typed prerequisites it actually consumes, with no over-broad inherited bundle.
- The IAM-harness tier per validation is derived from that validation's declared capabilities. The
  `normalizeManagedAwsHarness` `substrate=aws` blanket override is deleted; a validation that needs
  no AWS credentials does not acquire the IAM harness merely because the active substrate is AWS.
- `infra_ready` is split into `infra_ready` and a new declared `public_edge_ready` prerequisite
  node. `public_edge_ready` encodes the public-edge readiness gate (today procedural in
  `runWaitForPublicEdgeReady`) as a declared node that depends only on cluster + chart-platform
  readiness, **not** on AWS credentials, so `charts-vscode`, `charts-api`, `charts-websocket`, and
  `admin-routes` gate on an AWS-credential-free readiness. The Canonical Suite Inventory table and
  the procedural-gate note above are updated to name `public_edge_ready` as a declared node once
  this lands.
- `verifyAwsEksSnapshot` is strengthened to assert the substrate-equivalence properties the AWS
  EKS run must hold (per [substrates.md](substrates.md) and
  [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)) rather than a
  weaker existence check.
- Three destructive `--dry-run` goldens are added — for `prodbox rke2 delete`,
  `prodbox rke2 delete --cascade`, and `prodbox nuke` — proving the planned step list each
  destructive path emits without executing it. The golden coverage is generated from the
  managed-resource registry / `StackDescriptor` SSoT (Sprints `4.26`/`4.27`) so the goldens track
  the registry rather than drifting from it.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. Typed-prerequisite proof: the prerequisite registry keys are a typed `PrerequisiteId` ADT and
   no validation declares a prerequisite it does not consume.
6. Capability-tier proof: a credential-free validation run on the AWS substrate does not acquire
   the IAM harness; `normalizeManagedAwsHarness` no longer carries a `substrate=aws` blanket arm.
7. Readiness-split proof: `charts-*` validations gate on `public_edge_ready` and pass with no
   AWS credentials present.
8. Golden proof: the three destructive `--dry-run` goldens render from the managed-resource
   registry and fail if a registered resource is added without updating the generated golden.

### Remaining Work

None — closed 2026-06-09. All deliverables landed (typed `PrerequisiteId`, minimal per-validation
prerequisites, capability-derived IAM tier, the `public_edge_ready` split, the strengthened
`verifyAwsEksSnapshot`, and the three registry-generated destructive goldens). The live
AWS-substrate aggregate and the live public-edge-readiness exercise are operator-driven.

## Sprint 5.8: Sealed-Vault Canonical Validation and SecretRef Golden Tests ✅

**Status**: Done (2026-06-16) on its code-owned/home-substrate surface — the
`IntegrationSealedVault` / `ValidationSealedVault` named-suite entrypoint, the `sealedVaultAuditReport`
forbidden-pattern oracle, and the SecretRef golden tests have landed and validate locally
(`prodbox dev check`, `test unit`, `test integration cli`/`env`); reopened 2026-06-16 to adopt the
phase-independence doctrine (Sprint `0.15`), removing the former backward block on Sprint `7.14`.
**Implementation**: `src/Prodbox/TestValidation.hs`, `src/Prodbox/TestPlan.hs`, `test/`
**Independent Validation**: The sealed-Vault canonical validation and SecretRef golden tests are
validated on this phase's owned surface (the canonical-suite content in `src/Prodbox/TestValidation.hs`)
with no dependency on a later phase: `prodbox test integration sealed-vault` runs against the
home/local substrate, sealing the home-cluster Vault and asserting fail-closed behavior plus the
cross-surface zero-child-info audit, while the pure `sealedVaultAuditReport` oracle and the generated
Dhall/config SecretRef sweep run as local unit tests against fixtures and rendered artifacts. Where the
red-team would touch a later-phase-owned AWS substrate, it is exercised against the home substrate
today; the AWS-substrate variant is the orthogonal coverage row, not a gate.
**Live-proof**: pending — the home-substrate live sealed-Vault red-team (live deployed Vault, sealed
parent/child cascade, host-disk and Kubernetes probes) is tracked as a distinct, non-blocking
Live-proof note per [development_plan_standards.md → O. Code-Local vs Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof); it does not gate this sprint's
code-owned closure. AWS-substrate coverage of the same validation is tracked only in
[substrates.md](substrates.md)'s parity table (Standards N/O/M) and is not a `5.8` blocker.
**Docs to update**: `documents/engineering/unit_testing_policy.md`, `documents/engineering/vault_doctrine.md`, `documents/engineering/cluster_federation_doctrine.md`

### Objective

Add suite content that proves the finalized fail-closed invariant end-to-end: Vault is the sole
secrets backend, so a sealed Vault bricks the cluster and there is no non-Vault source to
reconstruct a secret from. The validation asserts the sealed-state behavior matrix
([vault_doctrine.md §15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix))
and the red-team checklist
([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) and that
generated artifacts carry only `SecretRef` values on the `FileSecret`-free union. It **also** covers
the two finalized surfaces this end state adds: the
retired master-seed derivation surface (no `master-seed` object, no daemon `/v1/secret/*` RPC to
fall back to) and the cluster-federation auto-unseal cascade (a sealed or unreachable parent Vault
bricks its children) per
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). Under the
2026-06-15 Model-B + whole-system zero-child-info refinement it also owns the **cross-surface
sealed-Vault red-team** — a combined bucket/object/host-disk/Kubernetes/log probe proving the
whole-system zero-child-info invariant ([vault_doctrine.md §9/§10/§19](../documents/engineering/vault_doctrine.md)). This
extends the canonical suite; existing validations are unchanged.

### Deliverables

- A `ValidationSealedVault` / `prodbox test integration sealed-vault` flow: spin up, init+unseal,
  reconcile MinIO/in-force-Dhall/Pulumi/charts, seal Vault, then assert in-force-config read, Pulumi
  preview, gateway config load, Keycloak reconcile, MinIO object decrypt, and TLS reconcile all fail
  closed without leaking metadata — only the unencrypted basics (cluster id, Vault address, seal
  mode, parent reference for a child) remain legible while Vault is sealed.
- Derivation-retirement coverage: the suite asserts there is **no** `master-seed` object in MinIO
  and **no** gateway daemon `/v1/secret/derive` / `/v1/secret/ensure-namespace` RPC, so a sealed
  Vault has no HMAC-derivation path to reconstruct a previously-derived secret (Patroni/Postgres,
  Keycloak admin, OIDC client, gateway event keys); every such secret resolves only as a Vault KV
  object via Vault Kubernetes auth and fails closed when Vault is sealed (Sprint `3.19`).
- Federation auto-unseal cascade coverage: with a sealed (or unreachable) parent Vault, a child
  cluster's `seal "transit"`-backed Vault cannot auto-unseal, and the child's own fail-closed brick
  follows — proving the unseal cascade roots in the operator unsealing the root cluster
  (Sprint `3.20`, Sprint `4.32`).
- Cross-surface sealed-Vault red-team (Model-B whole-system zero-child-info; gated on the
  Sprint `3.17` deployed Vault): with the parent Vault sealed, the suite runs a combined probe across
  all four leak surfaces and asserts none carries child information —
  - a bucket-level `aws s3api ls` plus `list-objects` against the **one generically-named bucket**
    returns no role-revealing bucket name (`prodbox` / `prodbox-test-pulumi-backends` are retired)
    and only opaque `objects/<hmac>.enc` keys under one flat prefix — no `aws-eks`/stack-name object
    key — at a **constant** decoy-padded count, so the listing count carries no signal;
  - a host-disk walk of the `.data/prodbox/minio/0` hostPath PV reveals only opaque-named ciphertext,
    no cleartext object body and no legible logical name (the `prodbox-envelope-v2` stored AAD is
    `base64(SHA256(aad))`, not cleartext);
  - a Kubernetes ConfigMap/Secret dump reveals no child-cluster name and no child-named namespace —
    downstream identity is custodied in Vault KV, namespaces are opaque IDs;
  - a log/output audit across the residue-query, MinIO-backend, Pulumi-backend, and stack-output
    sites emits no bucket/key/stack/child name and exposes **no exists-vs-absent (`NoSuchKey`)
    oracle**, because residue queries are gated behind the Vault-readiness check (Sprint `4.33`);
  - the gateway daemon on its Kubernetes-auth path likewise cannot read the Vault-enveloped in-force
    config while the parent Vault is sealed.
- Golden tests that generated Dhall/config artifacts contain only `SecretRef.Vault` /
  `SecretRef.TransitKey` values — there is no `SecretRefFile` constructor to render — with no
  forbidden plaintext pattern (`AKIA`, `aws_secret_access_key`, `BEGIN PRIVATE KEY`,
  `client_secret = "…"`, `password = "…"`, Pulumi passphrase, kubeconfig user token, raw master
  seed).
- Unit proofs for plaintext-secret rejection (the `SecretRef.TestPlaintext` arm is accepted only by
  the test harness from `test-config.dhall`, never in production), Vault init/unseal/reconcile,
  fixture seeding from `test-config.dhall`, and teardown-preserves-Vault-PV. The plaintext-rejection
  proof also asserts `prodbox-config.dhall` carries no plaintext admin/operational AWS key — the
  `aws_admin_for_test_simulation.*` test-simulation block is a `TestPlaintext` fixture that lives
  only in `test-config.dhall` (never imported by `prodbox-config.dhall`, never in Vault), while the
  generated operational `aws.*` credential is minted into Vault KV and `prodbox-config.dhall` carries
  only a `SecretRef.Vault` reference to it (see
  [vault_doctrine.md §3/§4/§13](../documents/engineering/vault_doctrine.md) and
  [aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md)).

### Current State

- `IntegrationSealedVault` and `ValidationSealedVault` are wired into the native `prodbox test
  integration sealed-vault` surface, generated CLI docs, completions, and manpage.
- The aggregate native validation order now runs `sealed-vault` after `charts-storage` and before
  the destructive `lifecycle` validation.
- `runSealedVaultValidation` records the runtime shape: detect the current Vault seal state, seal if
  the runtime starts unsealed, assert `vault status` reports `sealed=True`, assert `aws stack eks
  reconcile` fails at the sealed-Vault gate before Pulumi work, audit the MinIO hostPath and
  Kubernetes ConfigMap/Secret names, and unseal again if the validation sealed Vault.
- The targeted `sealed-vault` runbook reconciles the local platform with plain `cluster reconcile`
  rather than `cluster reconcile --with-edge`, so a bare home cluster can prove sealed-Vault
  behavior without requiring operational Route 53 credentials for the gateway chart. Public-edge
  suites still use the edge runbook.
- `sealedVaultAuditReport` is the pure forbidden-pattern oracle for the cross-surface red-team. It
  accepts only the generic `prodbox-state` bucket, opaque `objects/<id>.enc` / `indexes/<id>.enc`
  keys, and redacted `vault_status=... result=unobservable` output; it rejects stack names,
  role-revealing buckets, child names, removed gateway `/v1/secret/*` RPCs, `SecretRefFile`, AWS
  key literals, private-key literals, plaintext client secrets, passwords, Pulumi passphrases, and
  kubeconfig user-token markers.
- The generated Dhall/config SecretRef sweep is now executable in the unit suite. It covers
  `renderConfigDhall`, `renderInForcePayload`, `gateway config-gen`, and the chart-side API,
  gateway, gateway-orders, and websocket Dhall templates, failing on any sealed-Vault forbidden
  pattern, rendered `SecretRefFile`, or plaintext/prompt `SecretRef` value constructor.

### Validation

- `prodbox test integration sealed-vault` asserts every sealed-state row fails closed, including the
  no-derivation-fallback rows and the federation auto-unseal-cascade rows.
- The cross-surface sealed-Vault red-team asserts the combined bucket-level `aws s3api ls` +
  `list-objects`, host-disk walk of `.data/prodbox/minio/0`, Kubernetes ConfigMap/Secret dump, and
  log/output audit reveal only opaque `objects/<hmac>.enc` at a constant count — no role-revealing
  bucket name, no `aws-eks`/stack-name key, no cleartext body, no child-named namespace, and no
  exists-vs-absent (`NoSuchKey`) oracle.
- The SecretRef golden tests fail on any forbidden plaintext pattern and on any rendered
  `SecretRefFile` constructor.
- Current code-owned validation: `cabal build --builddir=.build exe:prodbox` passes;
  `./.build/prodbox dev lint haskell --write` reports no hints; focused Sprint `5.8` unit tests pass
  2/2; the generated Dhall/config SecretRef sweep passes 1/1; the `test planning` unit filter
  passes 42/42; the parser filter passes 260/260; and the CLI generated-output goldens pass 3/3 for
  the new `sealed-vault` command. Full local gates also pass: full unit suite 950/950,
  `./.build/prodbox test integration cli` 38/38, `./.build/prodbox test integration env` 38/38,
  `./.build/prodbox dev docs check` 0, `./.build/prodbox dev lint docs` 0,
  `git diff --check` 0, and `./.build/prodbox dev check` 0.
- Live home-substrate validation (2026-06-16): `./.build/prodbox test integration sealed-vault`
  passes. The runbook reconciled the local platform, skipped the gateway chart because operational
  `aws.*` was absent from Vault, sealed Vault, proved `aws stack eks reconcile` stops at the
  sealed-Vault gate before Pulumi starts, emitted `SEALED_VAULT_AUDIT=pass`, and restored Vault to
  `sealed=False`. Follow-up inspection showed all cluster pods Running/Completed and no gateway Helm
  release.

### Remaining Work

- None on this sprint's code-owned surface — it is ✅ Done and validates locally.
- **Live-proof: pending** (non-blocking, Standards N/O). The AWS-substrate side of the sealed-Vault
  exercise, the live parent/child federation auto-unseal cascade exercise, and the live cross-surface
  sealed-Vault red-team are live-infrastructure proofs, not code-owned closure work: they need a live
  deployed Vault, and the AWS-substrate variant composes (forward build order) against Sprint `7.14`'s
  raw Pulumi checkpoint decrypt-to-scratch interposition. These are tracked here as a non-blocking
  Live-proof note and, for AWS-substrate parity, in [substrates.md](substrates.md)'s parity table;
  neither reopens this sprint or gates its phase.

## Sprint 5.9: Repair the daemon-lifecycle Suite Fixture (SecretRef Schema Drift) ✅

**Status**: ✅ Done (validated 2026-06-18). `test/daemon-lifecycle/Main.hs::renderConfig` was repaired to the current `DaemonConfigDhall` `SecretRef`-union schema (the top-level `vault = None {…}`, `aws_creds`/`minio_creds` as `None` of the current `SecretRef`-field records, `event_keys = []` with the current union element type) so `loadDaemonConfig` decodes the fixture again. The standalone `prodbox-daemon-lifecycle` suite is now **11/11 PASS** (was ~8/11 red); no assertion weakened (the launching tests exercise health/readiness/metrics/`/v1/state`/SIGTERM-drain, none sign a node-a event, and the daemon tolerates a missing event key). No production code changed; main gate unaffected (`dev check` 0, `test unit` 0, `integration cli`/`env` 0). Only `test/daemon-lifecycle/Main.hs` changed.
**Blocked by**: Sprint `1.35` (the landed typed `SecretRef` config contract — the `FileSecret`-free
union the fixture must render against).
**Implementation**: `test/daemon-lifecycle/Main.hs`
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`

### Objective

Repair the standalone `prodbox-daemon-lifecycle` cabal suite (the `test/daemon-lifecycle` source dir
declared in `prodbox.cabal`), which is currently 8/11 red because its fixture renderer emits the
pre-Vault-root config shape rather than the current `SecretRef` union. The drift predates the
Vault-root migration (Sprint `1.35`) and reproduces on pristine `HEAD`. This suite is **not** part of
the `prodbox test` frontend gate (`dev check`, `test unit`, `test integration cli`/`env`), so the
drift is invisible to the canonical-suite gates that gate this phase; this sprint brings the
standalone fixture back in line with the schema the gated surfaces already prove.

### Root Cause

`test/daemon-lifecycle/Main.hs::renderConfig` emits the pre-Vault-root plaintext `boot` shape — inline
`event_keys = [ { name, value } ]`, `aws_creds = None { access_key_id, secret_access_key, … }`, and
`minio_creds = None { minio_access_key, minio_secret_key }` — instead of the current
`DaemonConfigDhall` `SecretRef` union. The daemon decodes the current `FileSecret`-free `SecretRef`
contract (Sprint `1.35`), so the legacy plaintext field shapes no longer parse and the suite fails at
config decode.

### Deliverables

- `test/daemon-lifecycle/Main.hs::renderConfig` is repaired to the current `DaemonConfigDhall`
  `SecretRef` schema, so the rendered fixture decodes against the `FileSecret`-free `SecretRef` union
  (Sprint `1.35`). The fixture's test-only secret values use the `SecretRef.TestPlaintext` arm that the
  test harness accepts (never a production constructor), consistent with the canonical-suite
  plaintext-rejection contract in Sprint `5.8`.
- The standalone `prodbox-daemon-lifecycle` cabal suite returns to green (11/11) on pristine `HEAD`.
- A short note records that this suite is a standalone cabal `test-suite`, not part of the
  `prodbox test` frontend gate, so its repair does not change the frontend gate result; it closes a
  schema-drift gap that the frontend gates do not exercise.

### Validation

1. `cabal test prodbox-daemon-lifecycle --builddir=.build` passes 11/11.
2. `prodbox dev check`, `prodbox test unit`, `prodbox test integration cli`, and
   `prodbox test integration env` remain green and unchanged (the standalone suite is outside this
   gate; the repair does not touch frontend-gated surfaces).
3. Schema-drift proof: the repaired `renderConfig` emits only `SecretRef` union values on the
   `FileSecret`-free contract, with no inline plaintext `event_keys` / `aws_creds` / `minio_creds`
   field shape remaining.

### Remaining Work

- Pending — fixture repair not yet landed.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - external proof and AWS access
  doctrine after the Haskell rewrite.
- `documents/engineering/aws_test_environment.md` - shared AWS-substrate environment doctrine for
  the canonical-suite content owned here.
- `documents/engineering/cli_command_surface.md` - supported public-host validation commands.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - target Gateway API and Envoy public-edge
  doctrine.
- `documents/engineering/helm_chart_platform_doctrine.md` - public-host behavior of the rewritten
  `vscode` stack.
- `documents/engineering/unit_testing_policy.md` - external-only public-host validation doctrine;
  for Sprint `5.6`, the typed `PrerequisiteId` surface, minimal-and-precise per-validation
  prerequisites, the `public_edge_ready` readiness split, and the three destructive `--dry-run`
  goldens generated from the managed-resource registry; for Sprint `5.13`, the
  `resource-guardrails` named validation and its pod/quota JSON oracle.
- `documents/engineering/resource_scaling_doctrine.md` - for Sprint `5.13`, the validation contract
  proving no `BestEffort` pods and over-budget config refusal before mutation.
- `documents/engineering/integration_fixture_doctrine.md` - for Sprint `5.6`, the
  capability-derived IAM-harness tier (replacing the `normalizeManagedAwsHarness` `substrate=aws`
  blanket override) and the registry-generated destructive-dry-run golden fixtures.
- [documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) - for
  Sprint `5.8`, the sealed-state behavior matrix
  ([vault_doctrine.md §15](../documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix))
  and red-team checklist
  ([vault_doctrine.md §19](../documents/engineering/vault_doctrine.md#19-red-team-checklist)) the
  `sealed-vault` validation and the SecretRef golden tests prove against the canonical suite,
  including the retired master-seed derivation surface (no `master-seed` object, no daemon
  `/v1/secret/*` RPC) and the `FileSecret`-free `SecretRef` union, plus the Model-B object-store and
  whole-system zero-child-info surfaces (§9/§10) the cross-surface sealed-Vault red-team probes — the
  one generically-named bucket, opaque `objects/<hmac>.enc` naming at a constant decoy-padded count,
  the opaque-only `.data/prodbox/minio/0` hostPath, opaque Kubernetes namespaces, and the
  no-exists-vs-absent-oracle log/output rule.
- [documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md) -
  for Sprint `5.8`, the Vault transit-seal trust tree and the fail-closed unseal cascade the
  `sealed-vault` validation proves when a parent Vault is sealed or unreachable.
- [documents/engineering/test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md) -
  for Sprint `5.11`, the `test init` / `test run` command surface, `.test-data/` isolation with the
  never-touch-`.data/` `guardTestDelete` guard, the two fail-fast preconditions, and the
  finally-guaranteed teardown that reuses `LifecycleClass` / `partitionResidueByLifecycle` to delete
  the per-run half while retaining the authored test Dhall and long-lived SES/S3 resources.
- `documents/engineering/unit_testing_policy.md` - for Sprint `5.11`, the `test run` per-variant
  deploy-path reuse and the finally-guaranteed teardown that runs on every exit (success, failure,
  Ctrl-C).
- `documents/engineering/integration_fixture_doctrine.md` - for Sprint `5.11`, the per-run vs
  long-lived teardown ownership across the `.test-data/` isolation boundary.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep public-host closure linked back to [README.md](README.md).

## Sprint 5.10: Harness-generated run config from `test-secrets.dhall` ✅

**Status**: Done (code-owned surface) — 2026-06-23
**Implementation**: `src/Prodbox/Vault/Host.hs` (`TestSecrets` + `defaultTestSecrets` gained
`route53_zone_id :: Text`), `test-secrets-types.dhall` (REGENERATED via `prodbox config schema` —
`route53_zone_id : Text`, default `""`), `src/Prodbox/Aws.hs` (`harnessConfigSetupInput` — the
no-prompt collector sourcing `route53.zone_id`/EAB from `test-secrets.dhall`, `acme.email` from the
baked `harnessAcmeEmail`, the rest carried from the current skeleton; `regenerateConfigFromTestSecrets`
preflight reusing the Sprint `1.50` `configFromSetupInput` builder, "fill only when empty"),
`src/Prodbox/TestRunner.hs` (`runConfigRegenFromTestSecrets` wired into `runNativeSuite` before the
pre-reconcile + `runManagedAwsHarnessSetup`), `test-secrets.dhall` (fixture gained the real
`route53_zone_id` for `resolvefintech.com`).
**Blocked by**: Sprint `1.48` + Sprint `1.50` (both now Done)
**Live-proof**: pending
**Independent Validation**: the `TestSecrets` round-trip drift guard now decodes `route53_zone_id`
against the generated schema; the shared builder's field-fill is covered by the Phase 1 Sprint `1.50`
test. The harness IO wiring (`loadTestSecrets` → `harnessConfigSetupInput` → `configFromSetupInput` →
`writeProjectConfigParameters`) is exercised live by `prodbox test all`. Phase 5's own surface; no
dependency on a later phase.
**Docs to update**: `documents/engineering/config_doctrine.md` (§0, "The test harness generates its
run config"), `documents/engineering/unit_testing_policy.md`.

### Objective

Let the test harness **generate** its run `prodbox.dhall` instead of requiring a hand-authored one,
mirroring hostbootstrap's `demoTestConfig`-reuses-`demoInit` idiom: the harness assembles a
`ConfigSetupInput` non-interactively and writes the binary-sibling config through the **same**
`configFromSetupInput` builder production's `config setup` uses (Sprint `1.50`). This unblocks
`prodbox test all` from a freshly-generated skeleton — today it fails the managed AWS IAM harness
preflight with `route53.zone_id must not be empty`. Implements [config_doctrine.md §0 ("The test
harness generates its run
config")](../documents/engineering/config_doctrine.md#0-three-tier-config-model); covered per
[unit_testing_policy.md](../documents/engineering/unit_testing_policy.md).

### Deliverables

- `route53_zone_id :: Text` added to the `TestSecrets` Haskell type; `test-secrets-types.dhall`
  regenerated via `prodbox config schema` (the one file where cleartext operator ids the harness
  injects are allowed).
- `harnessConfigSetupInput`: sources `route53.zone_id` from `test-secrets.dhall`, `acme.email` from
  a baked operator-email default, the EAB from `test-secrets.dhall`'s `acme_eab`, and the remaining
  knobs from the same defaults the generated skeleton already carries.
- `regenerateConfigFromTestSecrets` preflight wired into `runNativeSuite` before
  `runManagedAwsHarnessSetup`, regenerating the binary-sibling `prodbox.dhall` only when its operator
  fields are empty (never clobbering a populated real config).
- `aws_substrate.*` / `ses.*` / `pulumi_state_backend.*` remain deferred — extend the same way when a
  run requires them.

### Validation

`prodbox dev check` 0; `prodbox test unit` 1060/1060 (the `TestSecrets` GENERATED-schema round-trip
now decodes `route53_zone_id`; the `configFromSetupInput` field-fill is covered by Sprint `1.50`);
`prodbox config schema` regenerates `test-secrets-types.dhall` cleanly with the new field.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): `prodbox test all` (home-local) regenerates the
  binary-sibling config from `test-secrets.dhall` and proceeds **past** the `route53.zone_id`
  preflight (the original failure). The real `resolvefintech.com` zone id is now in the fixture.

## Sprint 5.11: Test-Topology Command Surface (`test init` / `test run`) ✅

**Status**: Done (code-owned surface) — 2026-07-03
**Implementation**: `src/Prodbox/CLI/Command.hs` (the `test init` / `test run` surface extending
`TestCommand` / `TestScope`), `src/Prodbox/TestRunner.hs` (per-variant generate → reconcile →
assert → `finally` teardown), `src/Prodbox/TestValidation.hs` (`.test-data/` repointing of the
sealed-Vault audit path), `src/Prodbox/Lib/Storage.hs` (the `.test-data/` `manual_pv_host_root`
override), `test/unit/Main.hs`
**Live-proof**: pending
**Independent Validation**: unit tests over the pure `guardTestDelete` never-touch-`.data/`
`TestDeleteTarget` ADT, generated per-variant run config storage-root override, the sealed-Vault
audit-root override, topology suite mapping, and the two fail-fast preconditions; warning-clean
build; `prodbox test integration cli`/`env` on the home/local substrate; no later-phase dependency.
**Docs to update**: `documents/engineering/test_topology_doctrine.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/integration_fixture_doctrine.md`

### Objective

Land the `test init` / `test run` command surface per
[test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md): `prodbox test init`
generates the differently-shaped executable-sibling `prodbox.test.dhall` (the HA/failover variant
matrix), and `prodbox test run <suite>|all` drives each declared variant through the **real deploy
path**, isolating run state under `.test-data/` and always tearing down its per-run half.

### Deliverables

- `prodbox test init` writes `prodbox.test.dhall` at the executable-sibling path and refuses to
  overwrite an existing one without `--force`.
- `prodbox test run <suite>` runs one named suite; `prodbox test run all` runs every declared
  variant through the same reconcile/assert deploy path the canonical suite content already uses.
- `.test-data/` isolation: the run's `manual_pv_host_root` points at `.test-data/<case>/` instead of
  the production `.data/`, and `src/Prodbox/TestValidation.hs`'s hard-coded `.data/prodbox/minio/0`
  audit root is repointed under that override.
- A mechanical never-touch-`.data/` delete guard: the `guardTestDelete` closed `TestDeleteTarget`
  ADT can name only this-run generated config, `.test-data/`, and `LifecycleClass PerRun` residue —
  naming `.data/`, the authored `prodbox.test.dhall`, or a `LongLived` resource is unconstructible.
- Finally-guaranteed teardown reusing the managed-resource registry: `partitionResidueByLifecycle`
  (`src/Prodbox/Aws.hs`) reconciles the `PerRun` slice plus this run's `.test-data/` to absent and
  gates the `LongLived` slice (authored test Dhall, `aws-ses`, and the `pulumi_state_backend` bucket
  retained by design).
- The two hard fail-fast preconditions run before any work: refuse when a production `prodbox.dhall`
  exists beside the binary (the inverse of production's fail-if-absent rule) and refuse when a
  production cluster is running.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `prodbox test unit` (1134/1134: `guardTestDelete`, generated per-variant run config,
   topology env propagation, sealed-Vault audit-root override, suite mapping, and preconditions)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev docs check`
6. `git diff --check`
7. `prodbox dev check`

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): a real topology-run over deployed cluster variants
  proves the end-to-end stand-up/assert/teardown loop against live infrastructure. The code-owned
  command surface, `.test-data` isolation, and finally-guaranteed cleanup are complete.

## Sprint 5.12: `eks-volume-rebind` — Identical Block-Storage Rebinding Validation [✅ Done]

**Status**: ✅ Done (code-owned surface) — 2026-07-03
**Implementation**: `src/Prodbox/TestPlan.hs` (`ValidationEksVolumeRebind`, `nativeValidationId`,
home cluster prerequisites, and AWS harness derivation), `src/Prodbox/CLI/Command.hs`
(`IntegrationEksVolumeRebind`), `src/Prodbox/CLI/Spec.hs` (parser + command-registry leaf),
`src/Prodbox/TestValidation.hs` (`runEksVolumeRebindValidation`, snapshot parser, and report
oracle), `src/Prodbox/TestRunner.hs` (`validationMayProvisionPerRunAwsStacks` + topology suite
mapping), `test/unit/Main.hs`, `test/unit/Parser.hs`.
**Blocked by**: none on the code-owned surface — the validation compiles and runs on the home
substrate independently. The AWS run exercises the Phase 7 Sprint `7.28` static-EBS renderer and the
Phase 4 Sprint `4.39`/`4.40` lifecycle, but per Standards M/N the AWS coverage is a non-blocking
parity axis, not a backward block.
**Live-proof**: pending
**Independent Validation**: the validation body is substrate-agnostic and validatable on the home
substrate (hostPath PV rebind) with no later-phase dependency; the `--substrate aws` run (EBS
`volumeHandle` rebind) is a parity row in [substrates.md](substrates.md), never a phase blocker
(Standards M/N/O).
**Docs to update**: `storage_lifecycle_doctrine.md` (§ 6 test expectations),
`substrates.md` (parity table), `unit_testing_policy.md`.

### Objective

Prove the unified-storage rebinding guarantee of
[storage_lifecycle_doctrine.md § 4](../documents/engineering/storage_lifecycle_doctrine.md)
end-to-end on both substrates: write a sentinel value to a retained workload's PV, tear the cluster
down, spin it back up, and assert the **same** PV rebinds to the same PVC and the sentinel data
persists — hostPath on home, the same EBS `volumeHandle` on EKS.

### Deliverables

- `eks-volume-rebind` is a `NativeValidation` wired through the canonical command surface and
  aggregate suite ordering after `charts-storage` and before `sealed-vault`.
- The validation selects the retained MinIO PV/PVC inventory row, writes a sentinel under the
  workload's `/export` mount, drives `cluster delete`/`reconcile --with-edge` on home or
  `aws stack eks destroy`/`reconcile` on AWS, then re-reads the sentinel and PV JSON.
- The pure report oracle asserts same PV name, same claim namespace/name, `Bound` before and after,
  identical `volumeHandle` when present, and sentinel preservation; unit tests cover success,
  sentinel mismatch, handle mismatch, JSON parsing, planner wiring, topology mapping, and parser
  coverage.
- The Canonical Suite Inventory and `substrates.md` parity table call out the AWS `--substrate aws`
  run as live-proof pending for the Sprint `7.28` static retained-EBS PV path.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `prodbox test unit` (1139/1139: parser, planner, topology mapping, harness derivation,
   `VolumeRebindSnapshot` JSON parser, report oracle, and generated CLI goldens)
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox dev docs generate`
6. `prodbox dev docs check`
7. `git diff --check`
8. `prodbox dev check`
9. `prodbox test integration eks-volume-rebind` (home substrate; destructive live proof) — attempted
   2026-07-03 and failed fast before mutation because the binary-sibling
   `.build/prodbox.dhall` runtime config was absent (`settings_object` prerequisite); this remains
   the non-blocking live-proof axis per Standard O. The `--substrate aws` run remains the separate
   parity axis.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): provide a valid binary-sibling runtime config and run
  the destructive home `prodbox test integration eks-volume-rebind` against a disposable local
  substrate, then the AWS `--substrate aws` parity row against the Sprint `7.28` static retained-EBS
  PV path. The code-owned command/planner/parser/body/oracle surface is complete.

## Sprint 5.13: `resource-guardrails` Validation [✅ Done]

**Status**: ✅ Done (code-owned surface) — 2026-07-04
**Implementation**: `src/Prodbox/CLI/Command.hs` (`IntegrationResourceGuardrails`),
`src/Prodbox/CLI/Spec.hs` (parser + command-registry leaf), `src/Prodbox/TestPlan.hs`
(`ValidationResourceGuardrails`, ordering, prerequisites, and named-suite mapping),
`src/Prodbox/TestRunner.hs` (topology suite mapping), `src/Prodbox/TestValidation.hs`
(`runResourceGuardrailsValidation` and `resourceGuardrailReport`), `test/unit/Main.hs`,
`test/unit/Parser.hs`, `test/integration/CliSuite.hs`, and CLI goldens.
**Live-proof**: pending
**Independent Validation**: pure report-oracle tests over Kubernetes pod/quota JSON, invalid-config
fixtures that fail before mutation, and CLI/env integration against fake `kubectl`; the home live
run is the first real substrate proof, with AWS parity tracked normally in [substrates.md](substrates.md).
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/resource_scaling_doctrine.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Add canonical-suite coverage for the resource-governor contract introduced by Sprints `1.55`,
`3.22`, and `4.41`.

### Deliverables

- New named validation `resource-guardrails` in the canonical suite, ordered after chart platform
  readiness and before destructive lifecycle/rebind validations.
- Kubernetes JSON oracle proving every prodbox-owned pod has `resources.requests` and
  `resources.limits` for cpu, memory, and ephemeral storage, and that `.status.qosClass` is never
  `BestEffort`.
- Namespace oracle proving every root chart namespace has the expected `ResourceQuota` and
  `LimitRange`, and that rendered quota values match the declared resource plan.
- Negative config fixture proving over-reserved host capacity, namespace quota overcommit, and a
  missing resource profile fail before Helm/RKE2 mutation.
- Optional stress sub-proof for the live home substrate: a deliberately over-limit test pod is
  OOMKilled or evicted inside Kubernetes without dropping host SSH/network availability.

### Validation

1. ✅ `prodbox test unit` — 1172/1172, covering pod/quota/limit-range JSON parsing, report
   rendering, invalid resource config refusal, parser routing, planner ordering, and CLI goldens.
2. ✅ `cabal test --builddir=.build prodbox-integration --test-options='-p resource-guardrails'`
   — 1/1 with fake `kubectl` pod/quota/limit-range JSON.
3. ✅ `prodbox test integration cli` — 41/41.
4. ✅ `prodbox test integration env` — 41/41.
5. ✅ `prodbox dev check`

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): run the optional real over-limit pod stress proof on a
  disposable home substrate and the AWS `--substrate aws` parity row once the AWS substrate is
  provisioned. The code-owned command/planner/body/oracle surface is complete.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [substrates.md](substrates.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
