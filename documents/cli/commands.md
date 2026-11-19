# Current CLI Command Registry

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: `command-registry.markdown`
**Applicability**: Current unmodified pre-refactor binary; not the accepted target CLI.

> **Purpose**: Preserve the source-generated current leaf inventory while the numerical phases implement its explicit dispositions.

The generated payload below remains unchanged. It describes actual old command names, including RKE2-era lifecycle/runtime commands. Do not infer that accepted target commands already exist, or that obsolete surrounding doctrine still applies. Use actual binary help for current options.

[Target CLI contract](../engineering/cli_command_surface.md), [all leaf/option dispositions](../../DEVELOPMENT_PLAN/command_dispositions.md), and [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here) govern migration. The owning code change regenerates parser/help/manpages/completions/reference together; this Markdown-only adoption does not alter generated payloads to pretend success.

<!-- prodbox:command-registry.markdown:start -->
| Command | Summary |
|---------|---------|
| `prodbox admin-action run` | Run one signed Admin Action |
| `prodbox aws policy` | Render IAM policy JSON |
| `prodbox aws setup` | Create or refresh operational IAM user |
| `prodbox aws teardown` | Delete operational IAM user |
| `prodbox aws quotas check` | Inspect supported AWS quotas |
| `prodbox aws quotas request` | Request supported AWS quotas |
| `prodbox aws audit` | Inventory a stack's field in the provider |
| `prodbox aws ebs reap-test` | Delete test-scoped EBS volumes |
| `prodbox aws stack eks diff` | Show the eks stack resource and property delta |
| `prodbox aws stack eks reconcile` | Provision or inspect the eks stack |
| `prodbox aws stack eks destroy` | Destroy the eks stack |
| `prodbox aws stack eks prune-corrupt-checkpoint` | Clear a corrupt eks per-run Pulumi checkpoint |
| `prodbox aws stack eks adopt-legacy plan` | Render the eks adoption candidate plan and its digest |
| `prodbox aws stack eks adopt-legacy apply` | Adopt the eks family under a confirmed plan digest |
| `prodbox aws stack eks purge-dependents` | Plan or repair the registered EKS network dependents |
| `prodbox aws stack test diff` | Show the test stack resource and property delta |
| `prodbox aws stack test reconcile` | Provision or inspect the test stack |
| `prodbox aws stack test destroy` | Destroy the test stack |
| `prodbox aws stack test prune-corrupt-checkpoint` | Clear a corrupt test per-run Pulumi checkpoint |
| `prodbox aws stack test adopt-legacy plan` | Render the test adoption candidate plan and its digest |
| `prodbox aws stack test adopt-legacy apply` | Adopt the test family under a confirmed plan digest |
| `prodbox aws stack aws-subzone diff` | Show the aws-subzone stack resource and property delta |
| `prodbox aws stack aws-subzone reconcile` | Provision or inspect the aws-subzone stack |
| `prodbox aws stack aws-subzone destroy` | Destroy the aws-subzone stack |
| `prodbox aws stack aws-subzone prune-corrupt-checkpoint` | Clear a corrupt aws-subzone per-run Pulumi checkpoint |
| `prodbox aws stack aws-subzone adopt-legacy plan` | Render the aws-subzone adoption candidate plan and its digest |
| `prodbox aws stack aws-subzone adopt-legacy apply` | Adopt the aws-subzone family under a confirmed plan digest |
| `prodbox aws stack aws-ses diff` | Show the aws-ses stack resource and property delta |
| `prodbox aws stack aws-ses reconcile` | Provision or inspect the aws-ses stack |
| `prodbox aws stack aws-ses destroy` | Destroy the aws-ses stack |
| `prodbox aws stack aws-ses migrate-backend` | Migrate aws-ses Pulumi state onto the long-lived S3 backend |
| `prodbox bootstrap-broker start` | Start the Bootstrap Broker |
| `prodbox bootstrap-broker secret-worker` | Run one attested Bootstrap secret worker |
| `prodbox credential-provisioner run` | Run one closed Credential Provisioner worker |
| `prodbox credential-provisioner target-worker` | Run one Target materializer worker |
| `prodbox lifecycle-authority start` | Start lifecycle-authority |
| `prodbox provider-worker start` | Start provider-worker |
| `prodbox authority-backup start` | Start authority-backup |
| `prodbox tls-retention start` | Start tls-retention |
| `prodbox target-secret-agent start` | Start target-secret-agent |
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
| `prodbox control status` | Inspect local control observations |
| `prodbox control plan` | Render the selected kind configuration |
| `prodbox control reconcile` | Create a new test environment's kind prerequisites and node attempt |
| `prodbox control delete` | Remove a new test environment's recorded kind resources |
| `prodbox control import-artifact` | Import a declared bootstrap artifact |
| `prodbox control discard-artifact-staging` | Discard the selected artifact staging file |
| `prodbox control inspect-node-archive` | Inspect the retained OCI node archive |
| `prodbox control inspect-image-attempt` | Inspect a retained image attempt |
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
| `prodbox host check-ses-readiness` | Check semantic SES readiness |
| `prodbox host check-ports` | Check required ports |
| `prodbox host info` | Display host diagnostics |
| `prodbox host firewall gateway-restrict` | Restrict the gateway NodePort to 127.0.0.1 |
| `prodbox host firewall gateway-unrestrict` | Remove the gateway NodePort loopback restriction |
| `prodbox internal-kind-controller` | Run one managed kind node attempt |
| `prodbox internal-rpc-birth-controller` | Run the pinned operation-owned RPC birth controller |
| `prodbox nuke` | Total teardown of every prodbox-owned AWS resource (operator-only) |
| `prodbox test list` | List locally registered test suites |
| `prodbox test init` | Create prodbox.test.dhall |
| `prodbox test run` | Run a named test suite |
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
| `prodbox test integration control-plane-counterexample` | Run the frozen control-plane counterexample |
| `prodbox test integration teardown-recovery` | Run the frozen exact-keyed teardown recovery counterexample |
| `prodbox test integration create-interrupted` | Run the frozen interrupted registered-stack create counterexample |
| `prodbox test integration certificate-scope` | Verify live TLS serving and the exact presented SAN scope |
| `prodbox test integration clean-room-handoff` | Verify clean-room migration, rollback refusal, and legacy absence |
| `prodbox test integration cascade-qualification` | Run one named destructive recover-to-clean cascade qualification cycle |
| `prodbox test integration cascade-qualification-receipt` | Report whether the cycle ledger holds consecutive qualifying cascade cycles |
| `prodbox test integration aws-lifecycle-receipt` | Report whether the AWS lifecycle drill ledger meets every scoped claim criterion |
| `prodbox test integration aws-lifecycle` | Exercise audit-bracketed AWS stack create and destroy cycles |
| `prodbox test integration aws-lifecycle-canary` | Exercise planted test-VPC network dependencies and exact cleanup |
| `prodbox test integration ha-rke2-aws` | Run HA RKE2 AWS integration tests |
| `prodbox test integration lifecycle` | Run lifecycle integration tests |
| `prodbox test integration pulumi` | Run Pulumi integration tests |
| `prodbox test integration eks-volume-rebind` | Run retained-volume rebinding integration tests |
| `prodbox test integration charts-storage` | Run chart-storage integration tests |
| `prodbox test integration charts-platform` | Run chart-platform integration tests |
| `prodbox test integration resource-guardrails` | Run resource-guardrail integration tests |
| `prodbox test integration daemon-bootstrap` | Run daemon-bootstrap transport integration tests |
| `prodbox test integration pulsar-broker` | Run Pulsar broker transport integration tests |
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
| `prodbox vault reset-ambiguous-initialization` | Reset ambiguous Vault initialization |
| `prodbox vault unseal` | Unseal Vault |
| `prodbox vault seal` | Seal Vault |
| `prodbox vault reconcile` | Reconcile Vault policy |
| `prodbox vault rotate-unlock-bundle` | Re-encrypt the unlock bundle |
| `prodbox vault rotate-transit-key` | Rotate a Transit key |
| `prodbox vault pki status` | Report Vault PKI state |
| `prodbox vault pki issue-test-cert` | Issue a throwaway PKI cert |
| `prodbox workload start` | Start internal workload runtime |
<!-- prodbox:command-registry.markdown:end -->
