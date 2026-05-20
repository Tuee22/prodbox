# Test Suite Substrates

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Inventory the substrates against which the canonical test suite runs, the
> provision and teardown surface each substrate owns, and the current parity status of each
> substrate against the canonical suite.

> **Authoritative Reference**:
> [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates)

## Doctrine

The canonical test suite is the named-validation set in `src/Prodbox/TestValidation.hs`,
planned by `src/Prodbox/TestPlan.hs`, orchestrated by `src/Prodbox/TestRunner.hs`, and gated by
the prerequisite DAG in `src/Prodbox/Prerequisite.hs`. The suite is substrate-agnostic.

A substrate is an environment that, for the lifetime of a suite run, stands up the same set of
DNS records, TLS certificates (real Let's Encrypt via cert-manager), ingress (Envoy Gateway plus
MetalLB or the substrate-equivalent), services, and workload charts; provides the prerequisites
declared in `src/Prodbox/Prerequisite.hs`; and is torn down on suite exit. Substrate lifecycle is
provision → run canonical suite → teardown.

## Substrate Independence (No Fallback)

The canonical test suite is composed of per-substrate runs against **both** supported
substrates listed below. A canonical-suite proof is complete only when both per-substrate runs
have been exercised. A run that exercises only one substrate covers only that substrate's row
in the parity table; the other substrate remains suite-incomplete until its own run lands.

Each per-substrate run is independent and substrate-locked: it targets exactly one substrate,
consumes only that substrate's operator-supplied config (`Required Config` row in each
substrate's table) and provisioned infrastructure, and fails fast if any required field is
missing. There is no silent substitution of home-substrate values for missing AWS-substrate
config, and no silent substitution of AWS values for missing home config. The substrate-aware
helpers `substratePublicFqdn`, `substrateHostedZoneId`, and `substrateKubeconfigPath` in
`src/Prodbox/PublicEdge.hs`, together with the prerequisite DAG and the lifecycle gates,
enforce this contract.

See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
for the authoritative doctrine.

## Substrate Inventory

### Home Local Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox rke2 reconcile` followed by `prodbox charts deploy <chart>` for the canonical chart set |
| Teardown | `prodbox rke2 delete --yes` (preserves retained host roots per the lifecycle doctrine) |
| Inventory | Local RKE2 cluster on the operator host, MetalLB L2/BGP, Envoy Gateway, cert-manager (real Let's Encrypt), Keycloak, Patroni-backed Postgres via the Percona operator, the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` charts |
| Required Config | `route53.zone_id`, `domain.demo_fqdn`, `acme.*` (server, account email, ZeroSSL EAB if applicable), `deployment.*`, `ses.*` (sender_domain, receive_subdomain, capture_bucket — required for `keycloak-invite` validation), `aws_admin_for_test_simulation.*` (for the shared IAM harness only). Missing any required field fails fast; the home substrate does not fall back to AWS-substrate values. |
| Prerequisites satisfied | `platform_linux`, `systemd_available`, `supported_ubuntu_2404`, `machine_identity`, `tool_*`, `settings_*`, `aws_iam_harness_ready`, `kubeconfig_*`, `rke2_*`, `k8s_*`, `pulumi_logged_in`, `infra_ready`, `gateway_daemon_acquire`, `aws_credentials_valid`, `route53_*` |
| Phase ownership (provision/teardown) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| Suite parity | ✅ Full canonical suite, including the public-edge proofs that exercise real Let's Encrypt certs, real OIDC redirects through Keycloak, real WebSocket fan-out, and the configured public Route 53 record on `test.resolvefintech.com` |
| Notes | The home cluster is both the production runtime for the Haskell gateway daemon and a substrate for the canonical test suite. The same chart deploys serve both roles. |

### AWS Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox pulumi eks-resources` (EKS test cluster), `prodbox pulumi aws-subzone-resources` (per-substrate Route 53 subzone), and `prodbox pulumi test-resources` (three Ubuntu 24.04 EC2 instances for HA-RKE2) |
| Teardown | `prodbox pulumi eks-destroy --yes`, `prodbox pulumi aws-subzone-destroy --yes`, and `prodbox pulumi test-destroy --yes` |
| Inventory today | Two disposable Pulumi stacks: `aws-eks-test` (VPC, subnets, EKS cluster, node group, IAM, security group) and `aws-test` (VPC, subnets, three EC2 instances, security group, key pair). State stored in MinIO-backed Pulumi backend on the local cluster under `prodbox-test-pulumi-backends`. |
| Target inventory | Same canonical chart deploy set as the home substrate: cert-manager + real Let's Encrypt, Envoy Gateway or substrate-equivalent ingress with MetalLB or NLB, Keycloak, Patroni Postgres, `gateway`, `vscode`, `api`, `websocket`, plus the per-substrate Route 53 subzone provisioned by `pulumi/aws-eks-subzone/` for the AWS-substrate public-edge proofs. |
| Required Config | `aws_substrate.hosted_zone_id` (the AWS-substrate Route 53 subzone ID, after `prodbox pulumi aws-subzone-resources` provisions it), `aws_substrate.subzone_name` (the AWS-substrate public FQDN, e.g. `aws.test.resolvefintech.com`), `ses.*` (sender_domain, receive_subdomain, capture_bucket — shared cross-substrate; same values as home substrate), AWS operator credentials, plus the same `acme.*` settings the home substrate uses. Missing any required field fails fast; the AWS substrate does not fall back to `route53.zone_id` or `domain.demo_fqdn` from the home substrate. |
| Prerequisites satisfied today | `aws_credentials_valid`, `route53_accessible`, `route53_lifecycle_capable`, `pulumi_logged_in`, the AWS-stack snapshot prereqs |
| Phase ownership (provision/teardown) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| Suite parity | 🔄 Provisioning + SSH reachability only. As of Sprint `7.5.b.i` (May 17, 2026) the supported `Substrate` ADT, `--substrate {home-local\|aws}` CLI surface, and per-validation routing layer are in place; EKS kubeconfig extraction (`materializeAwsEksKubeconfig`), substrate-aware helpers (`substrateKubeconfigPath`, `substrateHostedZoneId`, `substratePublicFqdn`), and the `aws_substrate` Dhall block (`hosted_zone_id`, `subzone_name`) are wired. `prodbox test integration ... --substrate aws` still surfaces an explicit "not yet implemented" remedy for chart-deploy / public-edge / WebSocket validations because the AWS LB Controller, per-substrate Route 53 subzone, cert-manager DNS01 ClusterIssuer, and chart-deploy substrate branching land in Sprint `7.5.b.ii`. Live canonical-suite proof on the AWS substrate lands in Sprint `7.5.c`. Parity sprint is tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md). |
| Notes | The AWS substrate is exclusively a test substrate. There is no production EKS cluster that `prodbox` manages. The literal stack names (`aws-eks-test`, `aws-test`) reflect that. |

## Resource Lifecycle Classes

Every AWS resource any `prodbox` flow creates falls into exactly one of two lifecycle classes.
This section is the authoritative classification — when adding a new AWS resource to any
`prodbox` code path, it must land in one of these two classes (and in the matching inventory
table below).

The per-run vs long-lived partition is mirrored in code by `Prodbox.Aws.perRunStackNames`
and `Prodbox.Aws.longLivedStackNames` (Sprint `7.7`), which the
`Prodbox.Aws.partitionResidueByLifecycle` predicate and the `PulumiResiduePolicy`
`BypassPerRunResidueOnly` arm consume. The lists in this doc and the lists in
`src/Prodbox/Aws.hs` must match verbatim — adding a new stack to any `prodbox` code path
requires updating both this section and the code-side helpers in the same change. The
`prodbox aws teardown` flag surface (`--destroy-pulumi-residue`, `--allow-pulumi-residue`)
and the harness-internal `BypassPerRunResidueOnly` mode both depend on the partition being
authoritative here.

### Per-run stacks (auto-managed by the harness)

| Stack | Provisioned by | Destroyed by |
|-------|----------------|--------------|
| `aws-eks` | `prodbox pulumi eks-resources` (and implicitly by `prodbox test all` / `prodbox test integration … --substrate aws` when needed) | `prodbox pulumi eks-destroy --yes`; auto-destroyed by the test-harness postflight on success, failure, **and** Ctrl-C (Sprint `7.6`) |
| `aws-eks-subzone` | `prodbox pulumi aws-subzone-resources` | `prodbox pulumi aws-subzone-destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`) |
| `aws-test` (HA-RKE2 EC2) | `prodbox pulumi test-resources` | `prodbox pulumi test-destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`) |

Per-run stacks exist only for the lifetime of a suite run that needs them. The harness owns
the full create/destroy lifecycle; operators do not normally invoke the destroy commands by
hand because the harness already does so on every exit path.

### Long-lived cross-substrate shared infrastructure (retained by design)

| Resource | Provisioned by | Destroyed by |
|----------|----------------|--------------|
| `aws-ses` stack (sending identity, DKIM, MX, receive rule set, S3 capture bucket, SMTP IAM user) | `prodbox pulumi aws-ses-resources` | `prodbox pulumi aws-ses-destroy --yes` — **only on explicit invocation**; never auto-destroyed by the test-harness postflight |
| Operator-owned Route 53 parent zone for the configured public FQDN | Operator-managed in Route 53 (no `prodbox pulumi` flow) | Operator action against Route 53 — outside the harness surface |

Retained by design — not orphaned. SES domain identity + DKIM verification requires 5–30 min
of DNS propagation per provision; only one receive rule set may be active per AWS account; S3
bucket names have a ~24-hour reuse cooldown. Per-run re-provision is impractical at suite
cadence. The harness explicitly carves these resources out of postflight auto-destroy so
operators can run the suite at a sane cadence without rebuilding shared infrastructure each
time.

When an operator wants the long-lived resources gone (e.g., decommissioning the project or
account), the supported path is the explicit destroy command in the table above. There is no
"managed-by-someone-else" category — the harness still owns the create/destroy lifecycle; it
simply does not invoke destroy on its own for this class.

## Cross-Substrate Shared Resources

This table is the **authoritative inventory** of every AWS resource any `prodbox` flow may
create or destroy under the long-lived shared-infrastructure class above. No `prodbox` code
path may add a new AWS resource type without first appearing in this table (or in the
per-run-stacks table above for the auto-managed class). Both substrates depend on the
resources listed here; provisioning and teardown stay per-substrate for the per-run stacks
and one-time/on-demand for the resources below.

| Resource | Owner | Phase ownership | Provisioning surface | Used by |
|----------|-------|-----------------|----------------------|---------|
| Route 53 hosted zone for the configured public FQDN | Operator AWS account | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Operator-managed in Route 53 (no `prodbox pulumi` flow) | Both substrates (home substrate for the live public record; AWS substrate when its parity sprint adds public-edge proofs) |
| AWS SES sending identity (domain) | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` | Both substrates running `ValidationKeycloakInvite` |
| AWS SES receive subdomain + MX records + receive rule set + S3 capture bucket | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` | Both substrates running `ValidationKeycloakInvite` |
| SMTP IAM user + access key for Keycloak SES SMTP | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` (`ses:SendRawEmail` + capture-bucket read/delete) | Keycloak chart `smtpServer` block (Sprint `8.2`); native validation harness for `ValidationKeycloakInvite` (Sprint `8.5`) |

## Canonical Suite Composition (Substrate-Agnostic)

The full inventory of named validations and their dispatch lives in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) and
[system-components.md](system-components.md). Substrates do not contribute or remove validations;
they only stand up or tear down the substrate that the suite runs against.

## Related Documents

- [development_plan_standards.md](development_plan_standards.md)
- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
