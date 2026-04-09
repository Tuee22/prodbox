# File: DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md
# Legacy Tracking

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)

> **Purpose**: Track every known compatibility helper, duplicate surface, deprecated path, and
> stale tooling residue that still needs removal outside the declarative phase narrative.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)

## Pending Removal

None.

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Competing implementation-status narratives in doctrine docs | Sprint 0.1 | `documents/` now defer status and blocker tracking to the development plan |
| Runtime placeholders that reported success without performing documented behavior | Sprint 1.1 | Removed inert command behavior from the supported CLI surface |
| Unconditional prerequisite success paths | Sprint 1.1 | Placeholder prerequisite success is no longer supported |
| Raw pytest passthrough from the public `prodbox test` surface | Sprint 1.1 | Only named suites remain public |
| Undocumented command-surface side paths | Sprint 1.1 | Click surface is now explicitly owned and documented |
| Ambient or shared-profile AWS auth assumptions | Sprint 1.2 | Repository-root `.env` is the sole supported source |
| Unnamed high-risk AWS real-system validation | Sprint 1.2 | AWS-backed validation now runs through named suites |
| Implicit cleanup assumptions for AWS suites | Sprint 1.2 | Teardown and cleanup proof are explicit closure work |
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
| Optional gateway daemon steady state and generated config that omits `dns_write_gate` | Sprint 4.4 | Generated gateway config now includes `dns_write_gate`, and `prodbox gateway install-service` installs the supported host supervision path |
| Missing explicit-record DNS doctrine for every supported public subdomain | Sprint 4.4 | Gateway config, status surfaces, and doctrine now treat explicit per-subdomain Route 53 records as canonical and wildcard public DNS as unsupported |
| `prodbox-chart-null-storage` StorageClass name | Sprint 4.5 | Consolidated to single `manual` StorageClass |
| `prodbox-local-retain` StorageClass name | Sprint 4.5 | Consolidated to single `manual` StorageClass |
| 4-segment `.data/<namespace>/<statefulset>/<ordinal>` path scheme | Sprint 4.5 | Migrated to 5-segment `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` |
| Missing HA-mode defaults and dev-mode anti-affinity suppression | Sprint 4.5 | Chart templates now include `replicaCount` and conditional `podAntiAffinity`; `PRODBOX_DEV_MODE` controls suppression |
| `KEYCLOAK_ADMIN_PASSWORD` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.data/<namespace>/.secrets.json` |
| `KEYCLOAK_POSTGRES_PASSWORD` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.data/<namespace>/.secrets.json` |
| `KEYCLOAK_NGINX_CLIENT_SECRET` in `.env` and Settings | Sprint 4.6 | Auto-generated and persisted in `.data/<namespace>/.secrets.json` |
| `METALLB_POOL` and `INGRESS_LB_IP` explicit `.env` override path | Sprint 4.6 | Always auto-discovered via `discover_lan_addressing()` |
| `KUBECONFIG` setting in `.env` and Settings | Sprint 4.6 | Default `~/.kube/config` always used |
| `PULUMI_STACK` setting in `.env` and Settings | Sprint 4.6 | Hardcoded to `home` |
| Cluster-gated invocation path for external public-host verification | Sprint 5.1 | `charts-vscode` no longer requires cluster prerequisite gates |
| Manual-only authoritative public DNS delegation proof | Sprint 5.1 | `poetry run prodbox test integration public-dns` is the named proof path |
| `prodbox env` command group | Sprint 4.9 | Replaced by `prodbox config` |
| `.env` loading in Settings | Sprint 4.8 | Replaced by Dhall-compiled JSON loading |
| `src/prodbox/lib/aws_auth.py` | Sprint 4.8 | AWS creds read from Settings directly |
| `dict(os.environ)` in subprocess env builders | Sprint 4.9 | Replaced by `_base_subprocess_env()` |
| `pydantic-settings` dependency | Sprint 4.8 | No longer needed after BaseModel migration |

## Related Documents

- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
