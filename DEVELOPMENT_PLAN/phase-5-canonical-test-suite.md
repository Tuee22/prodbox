# Phase 5: Canonical Test Suite

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[substrates.md](substrates.md),
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Own the substrate-agnostic canonical test suite — the named-validation set in
> `src/Prodbox/TestValidation.hs` — as suite content with declared prerequisites. Substrate
> provision and teardown belong elsewhere (see [substrates.md](substrates.md) and the
> substrate-owning phase docs); this phase owns what the suite proves and how.

## Phase Status

✅ **Done on owned surfaces** — Sprints `5.1`–`5.5` are closed on the canonical-suite content
that proves public-host behavior — the public-edge diagnostic, named external proofs, shared-host
route classification, admin-route auth and RBAC proofs, and the HTTP-to-HTTPS redirect proof.
Sprint `5.5` added the public HTTP listener on port `80` and proved that it only redirects to
the canonical HTTPS edge.

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
these validations are **suite content**, not home-substrate-only validations. The home local
substrate runs them today on real `test.resolvefintech.com` infrastructure (real Let's Encrypt,
real OIDC, real WebSocket fan-out). Bringing the AWS substrate to parity so it runs the same
validations is tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md).

Per [development_plan_standards.md](development_plan_standards.md) standards rule E, Phases `6`
and `7` remain `Done` on their owned surfaces, while the overall handoff still depends on the
separately reopened implementation phases `1`–`4`.

## Phase Summary

This phase owns the canonical test suite as substrate-agnostic content. Each validation in
`src/Prodbox/TestValidation.hs` is a member of one suite, planned by `src/Prodbox/TestPlan.hs`
(as `NativeValidation` variants), gated by prerequisites declared in
`src/Prodbox/Prerequisite.hs`, and orchestrated by `src/Prodbox/TestRunner.hs`. The same
validation runs against every substrate that satisfies its declared prerequisites; what differs
between substrates is provision and teardown, not the validation itself.

The suite content owned by this phase covers public DNS delegation, real TLS issuance via
cert-manager and Let's Encrypt, Envoy Gateway readiness, shared-host application routing
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
| `charts-vscode` | `infra_ready`, `public_edge_ready` | Real HTTPS curl to `https://<publicFqdn>/vscode`; redirect to OIDC callback with expected fragments |
| `charts-api` | `infra_ready`, `public_edge_ready` | Real HTTPS curl to `https://<publicFqdn>/api`; bearer-token validation; 401/403 contract |
| `charts-websocket` | `infra_ready`, `public_edge_ready` | Real WebSocket upgrade against `/ws`; cross-pod broadcast; revocation-driven reconnect; readiness-based drain |
| `admin-routes` | `infra_ready`, `public_edge_ready` | Harbor and MinIO auth + RBAC on the shared public edge |
| `keycloak-invite` | `aws_credentials_valid`, `route53_accessible`, `ses_sending_identity_verified`, `ses_receive_rule_set_active`, `ses_receive_bucket_accessible`, `pulumi_logged_in` | Operator-invited Keycloak flow end-to-end: `prodbox users invite` → SES capture-bucket poll → invite link follow → credential setup → OIDC login |

## Substrate Independence

Suite content does not name a substrate. It names prerequisites that any substrate must satisfy
to run the validation. When the AWS substrate stands up real DNS, cert-manager, ingress, and
the chart set (tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)),
the same `charts-vscode`, `charts-api`, `charts-websocket`, `public-dns`, `admin-routes`, and
public-edge readiness validations run against it without modification.

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
- Validations historically named "public-edge proofs" exercise real Let's Encrypt certificates
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
- `documents/engineering/unit_testing_policy.md` - external-only public-host validation doctrine.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep public-host closure linked back to [README.md](README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [substrates.md](substrates.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
