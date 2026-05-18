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
| Required Config | `route53.zone_id`, `domain.demo_fqdn`, `acme.*` (server, account email, ZeroSSL EAB if applicable), `deployment.*`, `aws_admin_for_test_simulation.*` (for the shared IAM harness only). Missing any required field fails fast; the home substrate does not fall back to AWS-substrate values. |
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
| Required Config | `aws_substrate.hosted_zone_id` (the AWS-substrate Route 53 subzone ID, after `prodbox pulumi aws-subzone-resources` provisions it), `aws_substrate.subzone_name` (the AWS-substrate public FQDN, e.g. `aws.test.resolvefintech.com`), AWS operator credentials, plus the same `acme.*` settings the home substrate uses. Missing any required field fails fast; the AWS substrate does not fall back to `route53.zone_id` or `domain.demo_fqdn` from the home substrate. |
| Prerequisites satisfied today | `aws_credentials_valid`, `route53_accessible`, `route53_lifecycle_capable`, `pulumi_logged_in`, the AWS-stack snapshot prereqs |
| Phase ownership (provision/teardown) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| Suite parity | 🔄 Provisioning + SSH reachability only. As of Sprint `7.5.b.i` (May 17, 2026) the supported `Substrate` ADT, `--substrate {home-local\|aws}` CLI surface, and per-validation routing layer are in place; EKS kubeconfig extraction (`materializeAwsEksKubeconfig`), substrate-aware helpers (`substrateKubeconfigPath`, `substrateHostedZoneId`, `substratePublicFqdn`), and the `aws_substrate` Dhall block (`hosted_zone_id`, `subzone_name`) are wired. `prodbox test integration ... --substrate aws` still surfaces an explicit "not yet implemented" remedy for chart-deploy / public-edge / WebSocket validations because the AWS LB Controller, per-substrate Route 53 subzone, cert-manager DNS01 ClusterIssuer, and chart-deploy substrate branching land in Sprint `7.5.b.ii`. Live canonical-suite proof on the AWS substrate lands in Sprint `7.5.c`. Parity sprint is tracked in [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md). |
| Notes | The AWS substrate is exclusively a test substrate. There is no production EKS cluster that `prodbox` manages. The literal stack names (`aws-eks-test`, `aws-test`) reflect that. |

## Cross-Substrate Shared Resources

Some prerequisites required by the canonical suite live in AWS but are not provisioned by any
substrate's Pulumi stack. They are long-lived, account-scoped, and shared across substrates.
Documenting them here keeps the substrate lifecycle clean (provision/teardown is per-substrate)
without losing track of resources both substrates depend on.

| Resource | Owner | Phase ownership | Used by |
|----------|-------|-----------------|---------|
| Route 53 hosted zone for the configured public FQDN | Operator AWS account | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Both substrates (home substrate for the live public record; AWS substrate when its parity sprint adds public-edge proofs) |
| AWS SES sending identity (domain) | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Both substrates running `ValidationKeycloakInvite` |
| AWS SES receive subdomain + MX records + receive rule set + S3 capture bucket | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Both substrates running `ValidationKeycloakInvite` |
| IAM policy granting the `prodbox` runner SES send, S3 list/get on the capture bucket, and capture cleanup | Operator AWS account | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) plus [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Both substrates |

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
