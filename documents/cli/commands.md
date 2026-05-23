# CLI Command Registry

**Status**: Generated reference
**Supersedes**: N/A
**Referenced by**: documents/engineering/cli_command_surface.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md
**Generated sections**: `command-registry.markdown`

> **Purpose**: Provide the generated leaf-command registry derived from `src/Prodbox/CLI/Spec.hs`.

<!-- prodbox:command-registry.markdown:start -->
| Command | Summary |
|---------|---------|
| `prodbox aws policy` | Render IAM policy JSON |
| `prodbox aws setup` | Create or refresh operational IAM user |
| `prodbox aws teardown` | Delete operational IAM user |
| `prodbox aws check-quotas` | Inspect supported AWS quotas |
| `prodbox aws request-quotas` | Request supported AWS quotas |
| `prodbox charts list` | List supported charts |
| `prodbox charts status` | Show detailed chart status |
| `prodbox charts deploy` | Deploy a root chart stack |
| `prodbox charts delete` | Delete a root chart stack |
| `prodbox check-code` | Run policy, lint, and type checks |
| `prodbox commands` | Render the command registry |
| `prodbox config setup` | Interactively author config |
| `prodbox config show` | Display current config |
| `prodbox config validate` | Validate current config |
| `prodbox dns check` | Inspect Route 53 state |
| `prodbox docs check` | Check generated docs for drift |
| `prodbox docs generate` | Regenerate generated docs |
| `prodbox gateway start` | Start gateway daemon |
| `prodbox gateway status` | Query gateway daemon status |
| `prodbox gateway config-gen` | Generate gateway config |
| `prodbox help` | Render help for a command path |
| `prodbox host ensure-tools` | Verify required host tools |
| `prodbox host check-ports` | Check required ports |
| `prodbox host info` | Display host diagnostics |
| `prodbox host firewall gateway-restrict` | Restrict the gateway NodePort to 127.0.0.1 |
| `prodbox host public-edge` | Check public DNS/TLS edge state |
| `prodbox k8s health` | Check cluster health |
| `prodbox k8s wait` | Wait for deployments to be ready |
| `prodbox k8s logs` | Show recent infrastructure logs |
| `prodbox lint all` | Run every lint surface |
| `prodbox lint files` | Run repository-policy lint checks |
| `prodbox lint docs` | Check generated documentation sections |
| `prodbox lint haskell` | Run Haskell formatter and lint checks |
| `prodbox lint chart` | Run Helm chart structural lint checks |
| `prodbox nuke` | Total teardown of every prodbox-owned AWS resource (operator-only) |
| `prodbox pulumi eks-resources` | Provision or inspect EKS test stack |
| `prodbox pulumi eks-destroy` | Destroy EKS test stack |
| `prodbox pulumi test-resources` | Provision or inspect HA RKE2 test stack |
| `prodbox pulumi test-destroy` | Destroy HA RKE2 test stack |
| `prodbox pulumi aws-subzone-resources` | Provision the per-substrate Route 53 subzone |
| `prodbox pulumi aws-subzone-destroy` | Destroy the per-substrate Route 53 subzone |
| `prodbox pulumi aws-ses-resources` | Provision cross-substrate AWS SES infrastructure |
| `prodbox pulumi aws-ses-destroy` | Destroy cross-substrate AWS SES infrastructure |
| `prodbox pulumi aws-ses-migrate-backend` | Migrate aws-ses Pulumi state onto the long-lived S3 backend |
| `prodbox rke2 status` | Check RKE2 status |
| `prodbox rke2 start` | Start RKE2 |
| `prodbox rke2 stop` | Stop RKE2 |
| `prodbox rke2 restart` | Restart RKE2 |
| `prodbox rke2 reconcile` | Reconcile RKE2 |
| `prodbox rke2 delete` | Delete RKE2 |
| `prodbox rke2 logs` | Show RKE2 logs |
| `prodbox test all` | Run the full test suite |
| `prodbox test lint` | Run lint and build checks |
| `prodbox test unit` | Run unit tests |
| `prodbox test integration all` | Run all integration suites |
| `prodbox test integration cli` | Run CLI integration tests |
| `prodbox test integration aws-iam` | Run AWS IAM integration tests |
| `prodbox test integration dns-aws` | Run Route 53 integration tests |
| `prodbox test integration aws-eks` | Run EKS integration tests |
| `prodbox test integration env` | Run environment integration tests |
| `prodbox test integration gateway-daemon` | Run gateway-daemon integration tests |
| `prodbox test integration gateway-pods` | Run gateway pod integration tests |
| `prodbox test integration gateway-partition` | Run gateway partition integration tests |
| `prodbox test integration ha-rke2-aws` | Run HA RKE2 AWS integration tests |
| `prodbox test integration lifecycle` | Run lifecycle integration tests |
| `prodbox test integration pulumi` | Run Pulumi integration tests |
| `prodbox test integration charts-storage` | Run chart-storage integration tests |
| `prodbox test integration charts-platform` | Run chart-platform integration tests |
| `prodbox test integration charts-vscode` | Run vscode stack integration tests |
| `prodbox test integration charts-api` | Run API stack integration tests |
| `prodbox test integration charts-websocket` | Run WebSocket stack integration tests |
| `prodbox test integration admin-routes` | Run shared-host admin-route integration tests |
| `prodbox test integration public-dns` | Run public DNS integration tests |
| `prodbox test integration keycloak-invite` | Run Keycloak operator-invite integration tests |
| `prodbox tla-check` | Run TLA+ checks |
| `prodbox users invite` | Invite an operator-owned user by email |
| `prodbox users list` | List operator-managed users |
| `prodbox users revoke` | Disable or delete an operator-managed user |
| `prodbox workload start` | Start internal workload runtime |
<!-- prodbox:command-registry.markdown:end -->
