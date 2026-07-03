# CLI Command Registry

**Status**: Generated reference
**Supersedes**: N/A
**Referenced by**: documents/engineering/cli_command_surface.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, documents/engineering/vault_doctrine.md
**Generated sections**: `command-registry.markdown`

> **Purpose**: Provide the generated leaf-command registry derived from `src/Prodbox/CLI/Spec.hs`.

<!-- prodbox:command-registry.markdown:start -->
| Command | Summary |
|---------|---------|
| `prodbox aws policy` | Render IAM policy JSON |
| `prodbox aws setup` | Create or refresh operational IAM user |
| `prodbox aws teardown` | Delete operational IAM user |
| `prodbox aws quotas check` | Inspect supported AWS quotas |
| `prodbox aws quotas request` | Request supported AWS quotas |
| `prodbox aws ebs reap-test` | Delete test-scoped EBS volumes |
| `prodbox aws stack eks reconcile` | Provision or inspect the eks stack |
| `prodbox aws stack eks destroy` | Destroy the eks stack |
| `prodbox aws stack eks prune-corrupt-checkpoint` | Clear a corrupt eks per-run Pulumi checkpoint |
| `prodbox aws stack test reconcile` | Provision or inspect the test stack |
| `prodbox aws stack test destroy` | Destroy the test stack |
| `prodbox aws stack test prune-corrupt-checkpoint` | Clear a corrupt test per-run Pulumi checkpoint |
| `prodbox aws stack aws-subzone reconcile` | Provision or inspect the aws-subzone stack |
| `prodbox aws stack aws-subzone destroy` | Destroy the aws-subzone stack |
| `prodbox aws stack aws-subzone prune-corrupt-checkpoint` | Clear a corrupt aws-subzone per-run Pulumi checkpoint |
| `prodbox aws stack aws-ses reconcile` | Provision or inspect the aws-ses stack |
| `prodbox aws stack aws-ses destroy` | Destroy the aws-ses stack |
| `prodbox aws stack aws-ses migrate-backend` | Migrate aws-ses Pulumi state onto the long-lived S3 backend |
| `prodbox charts list` | List supported charts |
| `prodbox charts status` | Show detailed chart status |
| `prodbox charts reconcile` | Reconcile a root chart stack |
| `prodbox charts delete` | Delete a root chart stack |
| `prodbox cluster status` | Check cluster and Vault status |
| `prodbox cluster health` | Check Kubernetes health |
| `prodbox cluster start` | Start the cluster service |
| `prodbox cluster stop` | Stop the cluster service |
| `prodbox cluster restart` | Restart the cluster service |
| `prodbox cluster reconcile` | Reconcile the local cluster |
| `prodbox cluster delete` | Delete the local cluster |
| `prodbox cluster logs` | Show cluster service logs |
| `prodbox cluster federation register` | Register a downstream cluster |
| `prodbox cluster wait` | Wait for deployments to be ready |
| `prodbox cluster workload-logs` | Show recent workload logs |
| `prodbox commands` | Render the command registry |
| `prodbox config setup` | Interactively author config |
| `prodbox config show` | Display current config |
| `prodbox config validate` | Validate current config |
| `prodbox config schema` | Regenerate Dhall schema files |
| `prodbox config generate` | Generate the default non-secret config |
| `prodbox dev check` | Run policy, lint, and type checks |
| `prodbox dev lint all` | Run every lint surface |
| `prodbox dev lint files` | Run repository-policy lint checks |
| `prodbox dev lint docs` | Check generated documentation sections |
| `prodbox dev lint haskell` | Run Haskell formatter and lint checks |
| `prodbox dev lint chart` | Run Helm chart structural lint checks |
| `prodbox dev docs check` | Check generated docs for drift |
| `prodbox dev docs generate` | Regenerate generated docs |
| `prodbox dev tla-check` | Run TLA+ checks |
| `prodbox dns check` | Inspect Route 53 state |
| `prodbox edge reconcile` | Reconcile the public edge |
| `prodbox edge status` | Check public DNS/TLS edge state |
| `prodbox gateway start` | Start gateway daemon |
| `prodbox gateway status` | Query gateway daemon status |
| `prodbox gateway config-gen` | Generate gateway config |
| `prodbox help` | Render help for a command path |
| `prodbox host ensure-tools` | Verify required host tools |
| `prodbox host check-ports` | Check required ports |
| `prodbox host info` | Display host diagnostics |
| `prodbox host firewall gateway-restrict` | Restrict the gateway NodePort to 127.0.0.1 |
| `prodbox host firewall gateway-unrestrict` | Remove the gateway NodePort loopback restriction |
| `prodbox nuke` | Total teardown of every prodbox-owned AWS resource (operator-only) |
| `prodbox test init` | Create prodbox.test.dhall |
| `prodbox test run` | Run a topology-declared suite |
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
| `prodbox test integration eks-volume-rebind` | Run retained-volume rebinding integration tests |
| `prodbox test integration charts-storage` | Run chart-storage integration tests |
| `prodbox test integration charts-platform` | Run chart-platform integration tests |
| `prodbox test integration charts-vscode` | Run vscode stack integration tests |
| `prodbox test integration charts-api` | Run API stack integration tests |
| `prodbox test integration charts-websocket` | Run WebSocket stack integration tests |
| `prodbox test integration admin-routes` | Run shared-host admin-route integration tests |
| `prodbox test integration public-dns` | Run public DNS integration tests |
| `prodbox test integration keycloak-invite` | Run Keycloak operator-invite integration tests |
| `prodbox test integration sealed-vault` | Run sealed-Vault fail-closed integration tests |
| `prodbox users invite` | Invite an operator-owned user by email |
| `prodbox users list` | List operator-managed users |
| `prodbox users revoke` | Disable or delete an operator-managed user |
| `prodbox vault status` | Report Vault seal state |
| `prodbox vault init` | Initialize Vault |
| `prodbox vault unseal` | Unseal Vault |
| `prodbox vault seal` | Seal Vault |
| `prodbox vault reconcile` | Reconcile Vault policy |
| `prodbox vault rotate-unlock-bundle` | Re-encrypt the unlock bundle |
| `prodbox vault rotate-transit-key` | Rotate a Transit key |
| `prodbox vault pki status` | Report Vault PKI state |
| `prodbox vault pki issue-test-cert` | Issue a throwaway PKI cert |
| `prodbox workload start` | Start internal workload runtime |
<!-- prodbox:command-registry.markdown:end -->

## `prodbox vault` command group

The `prodbox vault` leaf commands are now in the generated registry above. `vault status` is fully
wired — it probes the in-cluster Vault and reports initialized / sealed / unseal-progress, or that
it is unreachable. The mutating subcommands (`init`, `unseal`, `seal`, `reconcile`,
`rotate-unlock-bundle`, `rotate-transit-key`, `pki status`, `pki issue-test-cert`) are implemented
through the Vault CLI handlers and authenticated Vault client/orchestration modules. The
[unlock bundle](../engineering/vault_doctrine.md#6-the-unlock-bundle) lives in the durable MinIO
bucket (host disk holds no unseal material) and recovers a torn-down cluster's Vault,
and a sealed Vault fails closed; the model these commands operate against is owned by
[`vault_doctrine.md`](../engineering/vault_doctrine.md) (see
[§7 Vault lifecycle commands](../engineering/vault_doctrine.md#7-vault-lifecycle-commands)).
