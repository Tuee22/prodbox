# File: DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md
# Legacy Tracking

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Track every known compatibility helper, duplicate surface, deprecated path, and
> stale tooling residue that still needs removal outside the declarative phase narrative.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)


## Pending Removal

None.

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Public `.env` migration shim `prodbox config init` | Sprint 6.5 | Removed from the public CLI and supporting docs; `prodbox config setup` plus `prodbox config compile` are the only supported config-authoring surfaces |
| Legacy `/var/lib/prodbox/storage` cleanup helper | Sprint 6.5 | Removed from `rke2 delete`; full cluster delete now preserves only the configured manual PV root plus `.prodbox-state/` |
| Stale `.env` AWS credential fix hint | Sprint 6.5 | Removed from the interpreter; operator guidance now points only to `prodbox config setup` or `prodbox aws setup` |
| Manual IAM user creation and ad-hoc permission assignment | Sprint 7.3 | The supported operator path is now `prodbox aws setup` with one consolidated inline policy and deterministic Dhall credential injection |
| Manual AWS credential editing in `prodbox-config.dhall` as the supported credential path | Sprint 7.2 | The supported onboarding and credential-management flows are now `prodbox config setup` and `prodbox aws setup`; manual edits remain possible but are no longer the governed operator path |
| `.env`-based `prodbox config init` as the primary onboarding path | Sprint 7.2 | `config setup` is now the supported onboarding surface, and the surviving public migration shim was removed in Sprint 6.5 |
| Janitor-coupled `tests/integration/test_aws_eks_real.py` harness | Sprint 1.4 | The old EKS real-system test harness was removed with the obsolete cleanup model; Sprint 1.5 later closed the supported EKS-backed architecture through named `prodbox` create/destroy surfaces |
| Tag-based AWS fixture cleanup contract | Sprint 4.15 | The supported architecture now uses fixture-owned Route 53 teardown for `dns-aws` plus Pulumi-owned lifecycle for the multi-resource AWS stack; no standalone final AWS audit helper remains |
| Pulumi test-state backend that is not the local-cluster MinIO bucket `prodbox-test-pulumi-backends` | Sprint 4.15 | `src/prodbox/lib/aws_test_stack.py` and `src/prodbox/infra/aws_test_stack_program.py` now harden the dedicated local MinIO backend bucket as the only supported AWS test-stack state location |
| Manual AWS test-stack teardown that is not invoked by `prodbox rke2 delete --yes` | Sprint 4.15 | `src/prodbox/cli/dag_builders.py` prepends the shared `prodbox pulumi test-destroy --yes` path during `rke2 delete --yes` before local backend teardown |
| Competing implementation-status narratives in doctrine docs | Sprint 0.1 | `documents/` now defer status and blocker tracking to the development plan |
| Runtime placeholders that reported success without performing documented behavior | Sprint 1.1 | Removed inert command behavior from the supported CLI surface |
| Unconditional prerequisite success paths | Sprint 1.1 | Placeholder prerequisite success is no longer supported |
| Raw pytest passthrough from the public `prodbox test` surface | Sprint 1.1 | Only named suites remain public |
| Undocumented command-surface side paths | Sprint 1.1 | Click surface is now explicitly owned and documented |
| Ambient or shared-profile AWS auth assumptions | Sprint 1.2 | Repository configuration is the only supported auth source; Sprint 4.8 later moved it from `.env` to Dhall-compiled JSON |
| Unnamed high-risk AWS real-system validation | Sprint 1.2 | AWS-backed validation now runs through named suites |
| Implicit cleanup assumptions for AWS suites | Sprint 1.2 | Teardown and cleanup proof are explicit closure work |
| Preinstalled RKE2 cluster assumption | Sprint 1.3 | `prodbox` now owns `rke2 install|delete` on the supported host |
| Generic Linux support language | Sprint 1.3 | The only supported operator environment is `Ubuntu 24.04 LTS` |
| Cross-namespace chart composition | Sprint 3.1 | Chart delivery is namespace-local and canonical |
| Chart-authored `PersistentVolume` creation | Sprint 3.1 | Retained storage is CLI-owned and deterministic |
| `oauth2-proxy` and Google OAuth as the supported `vscode` auth path | Sprint 3.2 | nginx OIDC plus local Keycloak users is canonical |
| Stale oauth2 or Google auth naming in chart metadata and fixtures | Sprint 3.2 | Chart and test inputs match the supported auth path |
| Unsupported `docker/vscode-dev` repository files | Sprint 3.2 | Cluster-backed `prodbox charts` is the only supported delivery model |
| `CleanupProdboxAnnotatedResources.cleanup_passes` | Sprint 4.1 | Retry-count based cleanup flow is gone |
| Multi-pass `_collect_annotated_refs` and `_delete_ref` cleanup loop | Sprint 4.1 | Namespace-first cascade cleanup is canonical |
| Retry-as-settling behavior after cleanup | Sprint 4.1 | Lifecycle validation now passes without the post-cleanup rerun shim |
| `rke2_killall_exists` prerequisite | Sprint 4.2 | Compatibility-only prerequisite residue has been removed |
| Legacy Poetry `daemon` entrypoint and compatibility container wrapper alongside `prodbox gateway start` | Sprint 4.2 | `prodbox gateway start` and `docker/gateway.Dockerfile` are the only supported startup/build paths |
| CLI/DDNS timer Route 53 path alongside gateway `dns_write_gate` | Sprint 4.2 | Route 53 updates are canonical through the gateway |
| Interpreter command-summary compatibility bridge | Sprint 4.2 | Structured DAG outcomes are canonical |
| Hook-oriented `pre-commit` workflow residue | Sprint 4.2 | Repo development doctrine forbids hook-driven tooling |
| Static `.env`-owned `METALLB_POOL` and `INGRESS_LB_IP` LAN assumptions | Sprint 4.3 | Settings auto-discovery now derives the canonical LAN pool and ingress IP, with explicit overrides kept only as a fallback |
| Pulumi assumption that cert-manager CRDs are pre-installed before canonical cluster infra reconcile | Sprint 4.3 | Canonical infra reconcile now deploys cert-manager directly and orders the ClusterIssuer after cert-manager plus Traefik |
| AWS-gated local cluster infra reconcile path | Sprint 4.3 | `PULUMI_ENABLE_DNS_BOOTSTRAP=false` decouples local edge recovery from Route 53 bootstrap ownership |
| Competing public-edge ingress ownership between canonical Traefik and bundled/live ingress-nginx | Sprint 4.3 | Canonical RKE2 config disables bundled ingress-nginx on the supported path; Traefik is the only supported cluster-edge controller |
| Manual cross-layer diagnosis for public-host failures | Sprint 4.3 | `prodbox host public-edge` is now the named diagnostic path for DNS, ingress, and certificate drift |
| Optional gateway daemon steady state and generated config that omits `dns_write_gate` | Sprint 4.4 | Generated gateway config now includes `dns_write_gate` as a canonical section. (Sprint 4.4 was redirected from host supervision to the in-cluster gateway daemon during Phase 4; the host-side `prodbox-gateway.service` was uninstalled by Sprint 4.12.) |
| Missing explicit-record DNS doctrine for every supported public subdomain | Sprint 4.4 | Gateway config, status surfaces, and doctrine now treat explicit per-subdomain Route 53 records as canonical and wildcard public DNS as unsupported |
| `prodbox-chart-null-storage` StorageClass name | Sprint 4.5 | Consolidated to single `manual` StorageClass |
| `prodbox-local-retain` StorageClass name | Sprint 4.5 | Consolidated to single `manual` StorageClass |
| 4-segment `.data/<namespace>/<statefulset>/<ordinal>` path scheme | Sprint 4.5 | Migrated to 5-segment `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` |
| Missing HA-mode defaults and dev-mode anti-affinity suppression | Sprint 4.5 | Chart templates now include `replicaCount` and conditional `podAntiAffinity`; `PRODBOX_DEV_MODE` controls suppression |
| Mixed-purpose `.data/` root that stores non-PV artifacts | Sprint 4.6 | `.data/` is reserved for PV contents only; generated secrets and gateway event keys moved to `.prodbox-state/<namespace>/` |
| Missing explicit Dhall field for the manual PV host root | Sprint 4.7 | `storage.manual_pv_host_root` is explicit in `prodbox-config.dhall` and defaults to `.data/` |
| `KEYCLOAK_ADMIN_PASSWORD` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.prodbox-state/<namespace>/.secrets.json` |
| `KEYCLOAK_POSTGRES_PASSWORD` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.prodbox-state/<namespace>/.secrets.json` |
| `KEYCLOAK_NGINX_CLIENT_SECRET` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.prodbox-state/<namespace>/.secrets.json` |
| `METALLB_POOL` and `INGRESS_LB_IP` explicit `.env` override path | Sprint 4.6 | Always auto-discovered via `discover_lan_addressing()` |
| `KUBECONFIG` setting in `.env` and Settings | Sprint 4.6 | Default `~/.kube/config` always used |
| `PULUMI_STACK` setting in `.env` and Settings | Sprint 4.6 | Hardcoded to `home` |
| Cluster-gated invocation path for external public-host verification | Sprint 5.1 | `charts-vscode` no longer requires cluster prerequisite gates |
| Manual-only authoritative public DNS delegation proof | Sprint 5.1 | `poetry run prodbox test integration public-dns` is the named proof path |
| `prodbox env` command group | Sprint 4.9 | Replaced by `prodbox config` |
| `.env` loading in Settings | Sprint 4.8 | Replaced by Dhall-compiled JSON loading |
| `src/prodbox/lib/aws_auth.py` | Sprint 4.8 | AWS creds read from Settings directly |
| `dict(os.environ)` in interpreter subprocess env builders | Sprint 4.9 | Replaced by `_base_subprocess_env()` in interpreter; Sprint 4.11 later closed the remaining command-surface env builders |
| `pydantic-settings` dependency | Sprint 4.8 | No longer needed after BaseModel migration |
| `dict(os.environ)` in `check_code.py` subprocess env builder | Sprint 4.11 | Replaced by explicit `_TOOL_PASSTHROUGH_VARS` allowlist |
| `dict(os.environ)` in `test_cmd.py` subprocess env builder | Sprint 4.11 | Replaced by explicit `_TEST_PASSTHROUGH_VARS` allowlist |
| `os.environ.get("ROUTE53_ZONE_ID")` fallback in interpreter | Sprint 4.11 | Zone ID now resolved from effect or `get_settings()` only |
| `prodbox gateway install-service` Click command | Sprint 4.12 | Removed from `src/prodbox/cli/gateway.py`; superseded by `prodbox charts deploy gateway` |
| `GatewayInstallServiceCommand` ADT, smart constructor, and DAG builder | Sprint 4.12 | Removed from `src/prodbox/cli/command_adt.py` and `src/prodbox/cli/dag_builders.py`; the in-cluster gateway chart is the canonical install surface |
| `_render_gateway_systemd_unit()` helper | Sprint 4.12 | Removed from `src/prodbox/cli/dag_builders.py`; no host systemd unit is rendered by prodbox |
| Host-supervisor and `install-service` language in `documents/engineering/distributed_gateway_architecture.md` and `documents/engineering/cli_command_surface.md` | Sprint 4.12 | Doctrine docs now describe the in-cluster `prodbox charts deploy gateway` workload as the canonical steady state |
| `prodbox-gateway.service` host systemd unit | Sprint 4.12 | `systemctl disable --now prodbox-gateway.service` and `rm /etc/systemd/system/prodbox-gateway.service` executed on `bathurst` on 2026-04-10 after the in-cluster gateway was observed converging on `node-a` and continuing to keep `vscode.resolvefintech.com` current in Route 53. Before/after evidence captured in `/tmp/prodbox-gateway-before.log`, `/tmp/prodbox-gateway-pre-removal.log`, and `/tmp/prodbox-gateway-after.log`. |
| Session-scoped AWS pre-test sweep as the only stale-resource preflight | Sprint 4.13 | Removed from the supported architecture; AWS cleanup now starts inside the owning Route 53 fixture or Pulumi lifecycle flow instead of a session-level janitor pass |
| Fixture setup paths that can create partially tagged or untagged AWS resources before fixture yield | Sprint 4.13 | Removed with the tag-based cleanup harness; the surviving Route 53 helper creates and deletes one fresh hosted zone per test, and the EC2-backed AWS stack is owned by Pulumi |
| Expired EKS janitor flow that depends on post-delete cluster metadata | Sprint 4.13 | Removed with the janitor harness; any future EKS-backed validation path must close through named `prodbox` create/destroy surfaces rather than post-delete metadata coupling |
| Session-scoped AWS pre-test sweep fixture | Sprint 4.13 | Removed from `tests/integration/conftest.py`; AWS cleanup now starts inside each owning test harness |
| Scope-scoped AWS preflight cleanup that can leave unrelated tagged test resources behind | Sprint 4.13 | `create_clean_fixture_scope()` now sweeps all tagged fixture-owned AWS resources before setup, not only scope-matching resources |
| Standalone `prodbox aws sweep-fixtures` CLI and `tests.integration.sweep_runner` | Sprint 4.13 | Deleted; no standalone AWS janitor surface remains, and aggregate zero-residue closure now relies on the explicit `prodbox pulumi test-destroy --yes` postflight in `src/prodbox/cli/test_cmd.py` |
| Host cron entry that runs `prodbox aws sweep-fixtures` | Sprint 4.13 | Removed from the supported host crontab on April 12, 2026; no host-side background cleanup worker remains |
| `prodbox rke2 ensure|cleanup` as the canonical lifecycle surface | Sprint 4.14 | Full `install|delete` semantics are canonical; delete preserves the configured manual PV host root plus `.prodbox-state/` |
| Surviving non-`manual` StorageClasses after cluster install | Sprint 4.14 | `prodbox rke2 install` recreates the cluster-scoped `manual` StorageClass and deletes every other StorageClass |
| Aggregate-suite clean-cluster bootstrap that gated on `prodbox host public-edge` before Pulumi-managed edge restore | Sprint 6.2 | `poetry run prodbox test all` now restores the Pulumi-managed edge, redeploys gateway plus `vscode`, and reaches `CLASSIFICATION=ready-for-external-proof` from a cleaned cluster |
| Stale public-edge residue after clean-cluster teardown | Sprint 6.2 | Verified closed on April 12, 2026 by an empty `crontab -l`, no `/etc/hosts` override for `vscode.resolvefintech.com`, a passing `prodbox host public-edge`, and a passing `prodbox test integration public-dns` |
| Final handoff claim that lacks a post-aggregate zero-AWS-residue proof through the supported test flow | Sprint 6.2 | Closed by the April 12, 2026 clean-cluster rerun from missing `prodbox-config.json`; `poetry run prodbox test all` now reaches explicit zero-residue closure through the supported-runtime postflight, including `prodbox pulumi test-destroy --yes`, without a standalone janitor |

## Related Documents

- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
