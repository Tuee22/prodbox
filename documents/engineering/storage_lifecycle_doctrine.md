# Retained Storage Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/cluster_federation_doctrine.md, documents/engineering/effectful_dag_architecture.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/lifecycle_control_plane_architecture.md, documents/engineering/local_registry_pipeline.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/prerequisite_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/secret_derivation_doctrine.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/vault_doctrine.md, documents/engineering/tiered_storage_capacity_doctrine.md, documents/engineering/pulsar_topic_lifecycle_doctrine.md, documents/engineering/cluster_topology_doctrine.md, documents/engineering/test_topology_doctrine.md
**Generated sections**: none

> **Purpose**: Define deterministic retained-storage behavior for `prodbox` install/delete
> lifecycles.

Implementation and deployment-qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md); dated sprint references below are historical
provenance, not a parallel status ledger.

## 1. Canonical Doctrine Statements

- The operator host retains exactly one durable directory: the configured manual PV host
  root (default `.data/`). No other operator-host state is preserved across cluster
  wipes. The legacy `.prodbox-state/` repo-local cache is removed; chart secrets, gateway
  event-key files, stack-output caches, EKS kubeconfig snapshots, and HA-RKE2 SSH key
  material no longer live on disk outside `.data/`.
- Retained storage is reconciled via the static `manual` no-provisioner `StorageClass`
  plus deterministic PV resources to guarantee stable PVC-to-PV rebinding across cluster
  delete/reinstall.
- **Substrate parity (unified block storage).** Both supported substrates use the same
  static, no-provisioner, `Retain`, `claimRef`-bound PV model; only the PV volume *source*
  differs. On the home/RKE2 substrate the source is a `hostPath` under `.data/` with
  single-node affinity. On the AWS/EKS substrate the source is a **pre-created EBS volume
  lifted in as a static PV** via the EBS CSI `volumeHandle`, `Retain`, `claimRef`-bound, and
  pinned to the volume's availability zone (`topology.ebs.csi.aws.com/zone`) exactly as the
  home PV is pinned to its node. There is **no dynamic provisioning on either substrate**,
  satisfying [cluster_topology_doctrine.md § 4](./cluster_topology_doctrine.md); the legacy
  dynamic `gp2` EKS path (Sprint `7.5.c.i`) is superseded by Sprint `7.28` and tracked for
  removal in
  [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).
- Every retained PersistentVolume follows one deterministic host-path scheme —
  `.data/<namespace>/<StatefulSet>/<replica-index>` — provisioned by a single reconciler.
  There is no per-host machine-id directory prefix. Every stateful workload is a
  StatefulSet (MinIO, the namespace-local Patroni PostgreSQL cluster, `vscode`, and
  Vault), so every retained PVC is a StatefulSet `volumeClaimTemplate` claim
  (`data-<statefulset>-<ordinal>`) that a deterministic PV `claimRef`-binds. PV
  names derive from `(namespace, StatefulSet, ordinal)` through
  `Prodbox.Naming.boundedResourceName` and render as
  `prodbox-retained-<namespace>-<statefulset>-<ordinal>` before bounded-name
  truncation.
- `prodbox cluster reconcile` recreates the cluster-scoped `manual` `StorageClass` and
  removes every other `StorageClass` before retained-storage reconciliation succeeds.
- The manual PV host root stores PV contents and the per-cluster MinIO bucket files.
  MinIO's own PV lives under `.data/prodbox/minio/0`; therefore per-run Pulumi backend
  checkpoints and the Vault-Transit-enveloped in-force cluster configuration survive cluster wipes
  whenever `.data/` is preserved. Prodbox-owned MinIO state uses the generic `prodbox-state`
  bucket and Model-B opaque object format; checkpoint and config access remains Vault-gated. See
  [vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store).
- Vault runs in-cluster on a durable PV under `.data/vault/vault/0`, preserved across cluster
  wipes exactly like MinIO's PV; cluster teardown never destroys Vault state. The cluster is
  ephemeral but its storage is not: **a cluster rebuild is not a fresh Vault.** `vault init`
  runs exactly once, ever (the first time the PV is empty); every subsequent
  `prodbox cluster reconcile` redeploys the Vault chart against the existing data and only
  **unseals** it — no re-init, no key regeneration — so Vault KV, Transit, and PKI material is
  as durable across rebuilds as any retained PV.
- Model-B MinIO logical objects in the generically-named bucket are stored as Vault-Transit
  ciphertext envelopes (`prodbox-envelope-v2`, hashed stored AAD) under the flat opaque-named
  layout (`objects/<opaque-id>.enc`; encrypted index payloads use the same envelope discipline),
  per [vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store). Sharing the codec
  does not share authority: the Lifecycle Authority alone mutates its one bounded CAS aggregate and
  writes immutable content-addressed checkpoint blobs; the Gateway Runtime exposes no lifecycle or
  generic object-store writer. The Gateway Runtime instead persists its own encrypted,
  identity-bound continuity journal on a registered retained volume and owns the complete
  `stage -> fsync -> publish -> commit -> fsync` transition through one local actor. There is no
  master-seed object; every persisted post-unseal operational-secret source of truth is a Vault
  object. For cross-substrate SMTP and ACME EAB, that source is the retained home Agent's
  payload-specific Transit-sealed `SesSmtpSource`/`AcmeEabSource` custody; a selected substrate Vault
  holds only a bounded materialization restored by attestation-encrypted one-shot Agent rewrap.
  Authority sees ciphertext/typed receipts only, a fresh AWS Vault needs no operator re-entry or
  SMTP-key rotation, and no generic export exists. Exact cert-manager TLS Secrets are bounded
  materializations, and retained public-edge TLS is Agent-encrypted ciphertext plus a
  retained-home-Transit-wrapped DEK—not a second plaintext
  secret store. The password-AEAD Tier-1 prepared/encrypted-response/final bootstrap envelopes are the deliberate
  pre-unseal exception. Implementation and qualification status live only in the Development Plan.
- Namespace-local Patroni PostgreSQL clusters created for Helm-managed application stacks
  use deterministic CLI-owned PVs rooted at
  `.data/<namespace>/prodbox-<root-chart>-pg/<ordinal>`.
- The shipped `api`, `redis`, and `websocket` workloads do not add new manual-PV
  contracts; the Redis-backed WebSocket path keeps shared state at the application layer
  rather than extending the retained PV inventory.
- Chart secrets and the gateway peer-event signing keys are k8s Secrets, never host-disk
  files. Every chart secret (Patroni roles, Keycloak admin, OIDC client secrets, gateway
  event keys) is a Vault KV object fetched in-cluster via Vault Kubernetes auth per
  [secret_derivation_doctrine.md](./secret_derivation_doctrine.md); the master-seed
  HMAC-derivation model and the `lookup`-guarded chart-generated secret idiom are retired.
- `prodbox cluster delete --yes` and `prodbox cluster delete --cascade --yes` both preserve
  `.data/`. No `prodbox` command removes `.data/` on its own; deletion is operator-only.
- The same retain-on-teardown policy governs the AWS/EKS pre-created EBS volumes: they are the
  EBS analog of `.data/`. `prodbox cluster delete`, `prodbox aws stack eks destroy`, and per-run
  Pulumi destroy never delete the retained EBS volumes (they are `Retain` and are not owned by
  the per-run `aws-eks` Pulumi stack). Only the test-scoped EBS reaper paths delete EBS volumes:
  suite postflight, `cluster delete --cascade`, and `prodbox aws ebs reap-test --yes`; all three
  delete only volumes tagged as test-scoped — so production workflows never lose block storage and
  test runs never leak it (Sprints `4.39`, `4.40`).
- When the MinIO-backed Pulumi backend is still running but kubelet reports its `/export`
  mount as deleted, the Haskell backend helper recreates the declared retained host path,
  reapplies the `1000:1000` plus `0770` contract, and restarts `statefulset/minio` before
  backend validation or stack operations continue.

## 2. Scope

This doctrine governs:

1. retained local storage resources created by `prodbox cluster reconcile`
2. retained local storage resources created by `prodbox charts reconcile keycloak|vscode`
   for the namespace-local Patroni PostgreSQL cluster and `vscode` data
3. rebinding guarantees expected after `prodbox cluster delete --yes` plus
   `prodbox cluster reconcile`
4. the `.data/` host root as the sole preserved operator-host directory, and the
   pin that MinIO's PV lives inside it
5. MinIO persistence behavior on the supported single-node RKE2 machine
6. deleted-export-mount repair for the Lifecycle Authority's encrypted aggregate/checkpoint store
7. the Vault-Transit-enveloped in-force cluster configuration plus Lifecycle Authority aggregate
   and immutable checkpoint blobs in MinIO, which live on MinIO's PV under
   `.data/prodbox/minio/0` and are therefore in scope of this doctrine for persistence
   (encryption, access control, and the in-force-config SSoT
   contract are governed by
   [vault_doctrine.md](./vault_doctrine.md) and
   [config_doctrine.md](./config_doctrine.md))
8. the Vault durable PV under `.data/vault/vault/0` and its preservation across
   delete/reinstall — persistence is in scope here; the Vault model itself (seal/unseal,
   Transit, KV, PKI, Kubernetes auth) is owned by
   [vault_doctrine.md](./vault_doctrine.md) (implemented by Sprints 3.17 / 4.29)
9. retained EBS-backed storage on the AWS/EKS substrate: pre-created EBS volumes lifted in as
   static `Retain` PVs (CSI `volumeHandle`, AZ affinity) and their deterministic rebinding
   across `prodbox aws stack eks destroy` plus `prodbox aws stack eks reconcile` (Sprint `7.28`)
10. retained-home payload-specific Transit-sealed `SesSmtpSource` and `AcmeEabSource` objects plus
    their typed source receipts, and the bounded selected-target Vault generations restored from
    them by attestation-encrypted one-shot Agent rewrap. These are operational-secret Vault objects,
    not generic exports or a second plaintext store.
11. the production-retain / test-delete EBS lifecycle — EBS volumes are `Retain` and never
    deleted by cluster/stack teardown; only the test-scoped EBS reaper paths delete test-scoped EBS
    at suite postflight, cascade teardown, or `prodbox aws ebs reap-test --yes` (Sprints `4.39`,
    `4.40`). The managed-resource registry entry, tag markers, and
    reaper are owned by [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) § 1
12. EKS VPC ownership visibility: the AWS substrate's dedicated, non-default VPC plus its IGW,
    route table, and public subnets carry `prodbox.io/managed-by=prodbox` so the postflight tag
    sweep can surface escaped VPC-scoped residue after failed teardown (Sprint `7.29`)

In-cluster registry (registry:2) details remain in
[Local Registry Pipeline](./local_registry_pipeline.md).

## 3. eDAG Contract

`rke2 reconcile` reconciles the in-cluster registry (registry:2), retained storage, and MinIO using the Haskell
lifecycle runtime. The registry portion of that lifecycle must reach a stable
external-serving state before public-image mirror, custom-image publication, or
registry-backed steady-state workload reconcile continues. The bootstrap MinIO install
that establishes the local backend may pull its images from public registries first.

Any control-plane consumer represented in this eDAG carries an operation-indexed
`CapabilityRef`; readiness observation, admission, and execution use that same opaque reference.
Each boundary call consumes the remaining budget from one absolute deadline, so a successful probe
cannot be paired with a different service binding or a fresh execution timeout. Physical service
ownership is defined in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

The retained-storage effect must reconcile:

1. `StorageClass` `manual` with `kubernetes.io/no-provisioner`, `Retain`, and
   `WaitForFirstConsumer` — shared by both substrates; the PV volume source differs per
   substrate (`hostPath` on home, a pre-created EBS volume via CSI `volumeHandle` on EKS)
2. deterministic `PersistentVolume` objects with `claimRef` and placement affinity —
   single-node (`kubernetes.io/hostname`) on home, availability-zone
   (`topology.ebs.csi.aws.com/zone`) on EKS
3. StatefulSet `volumeClaimTemplate` PVCs (`data-<statefulset>-<ordinal>`) on the `manual`
   StorageClass, which the deterministic PVs in (2) `claimRef`-bind on first pod schedule
4. post-install Percona PostgreSQL PVC discovery plus staged retained-cluster restore so
   deterministic PVs bind to the operator-created claim names, the preserved ordinal
   `0` anchor comes up first, and follower ordinals `1` and `2` rejoin only after their
   retained roots are reset
5. host storage directories rooted at `storage.manual_pv_host_root`
6. registry publication admission through the exact operation-indexed capability used for image
   writes, including storage-edge mutation/read-back and the front-door `GET /v2/` diagnostic;
   the diagnostic alone cannot authorize publication
7. deleted MinIO export-mount detection and a bounded recreate-plus-restart repair before
   MinIO-backed Pulumi validation continues
8. MinIO IAM bootstrap (the single generically-named object-store bucket and separate
   least-privilege principals, including the Lifecycle Authority principal) per
   [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §7 so supported object-store
   access uses the same `prodbox-state` bucket without a gateway-owned generic proxy. The authority
   principal may reach only its aggregate and immutable blob namespace; registry storage retains
   its distinct bucket/user.

`rke2 delete` must preserve the configured manual PV host root and nothing else on the
operator host.

## 4. Deterministic Rebinding Rules

Deterministic rebinding is guaranteed only when all of these hold:

1. PVC name and namespace remain unchanged across reinstall
2. PV name and `claimRef` are reconciled deterministically
3. direct-workload PVCs set `spec.volumeName` to the canonical PV name, or the Percona
   operator recreates the same PVC names that the Haskell runtime later binds through
   deterministic PVs
4. the configured manual PV host path remains present on disk (home substrate); or, on the
   AWS/EKS substrate, the pre-created EBS volume still exists in its availability zone and is
   retained across teardown (Sprint `7.28`)
5. the workload remains scheduled to the same single node (home substrate) or to a node in the
   EBS volume's availability zone (AWS/EKS substrate, via the PV's
   `topology.ebs.csi.aws.com/zone` affinity)
6. the Vault KV holding each secret (Patroni roles, Keycloak admin, OIDC client secrets)
   re-attaches to the same material that was active when the preserved data was written.
   Those secrets survive cluster wipes via the Vault PV under `.data/vault/vault/0`; a
   mismatch against the preserved data surfaces as a loud failure per
   [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §8, never a silent
   data reset.
7. the Vault PV at `.data/vault/vault/0` rebinds across reinstall exactly like the MinIO PV,
   so the rebuild only unseals the existing Vault — it never re-inits — and the unsealed Vault
   re-attaches to the same Transit keys, KV, and PKI material that were active when the
   preserved data was written.

## 5. Delete Contract

`prodbox cluster delete --cascade --yes` is the canonical operator-driven teardown. The
cascade order is authoritatively defined in
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) §5b
("Canonical Cascade Order") — that table is the single source of truth and this section
must not restate the phase sequence independently. For storage context the order is:

1. Confirm MinIO is reachable (or treat per-run Pulumi state as already gone if not).
2. K8s drain phase (LoadBalancer Services, Ingresses, Delete-reclaim PVCs) so the
   in-cluster controllers are still alive to unwind their AWS-side state.
3. Per-run Pulumi destroys against MinIO with the
   `withMaterializedOperationalCreds` bracket materializing the operational creds for the
   run (in tests, via the harness-simulated admin prompt sourced from `test-secrets.dhall`)
   — only after the drain so subnet / VPC / cluster deletes have no live ENI / ALB / EBS
   dependency to trip on.
4. RKE2 uninstall, removing the substrate and managed kubeconfig.
5. Postflight cluster-tag sweep that fails the command with the leak list if anything
   cluster-tagged survives.

The drain-before-destroy ordering is load-bearing: see
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) §5b for
the substrate-aware drain and the `DependencyViolation` failure mode that an inverted
order produces on the AWS substrate.

`prodbox cluster delete --yes` (without `--cascade`) is local-only and unconditionally preserves
Pulumi checkpoint blobs and any corresponding live AWS resources. Reconcile plus the exact
per-stack destroy, or the durable always-run cleanup plan, is the supported recovery path because
MinIO's PV under `.data/` keeps the encrypted state alive across the cluster cycle. There is no
`cluster delete --allow-pulumi-residue` flag.

Both `prodbox cluster delete --yes` and `prodbox cluster delete --cascade --yes` preserve
the Vault PV (`.data/vault/vault/0`) just as they preserve `.data/` and the MinIO PV; cluster
teardown never destroys Vault state. Because Vault state survives teardown, the rebuild path
after a delete never re-inits Vault — the next `prodbox cluster reconcile` redeploys the chart
against the preserved data and only unseals it.

On the AWS/EKS substrate the retained EBS volumes are preserved by teardown exactly as
`.data/`, the MinIO PV, and the Vault PV are on home. Neither `prodbox cluster delete`,
`prodbox aws stack eks destroy`, nor the per-run Pulumi destroy deletes them: they are
`Retain`, and they are not owned by the per-run `aws-eks` Pulumi stack, so `pulumi destroy`
cannot remove them. The K8s drain deletes only `Delete`-reclaim PVCs, so the `Retain` EBS PVs
survive the drain untouched. Only the test-scoped EBS reaper paths delete EBS volumes: suite
postflight, `cluster delete --cascade`, and `prodbox aws ebs reap-test --yes`. Each deletes only
volumes tagged as test-scoped — production workflows never lose block storage, and test runs never
leak it. The EBS managed-resource class (`aws-ebs-volumes`) owns typed `discover`/`destroy`,
retained-vs-test-scoped tags, the test reaper, cascade hook, and retain-safe drain guard. See
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) § 1.

Both delete shapes preserve `.data/` and remove nothing else on the operator host. The
host iptables rule installed by reconcile (per
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md) §5) is removed as part
of clean teardown.

`prodbox cluster delete` captures the upstream `/usr/local/bin/rke2-uninstall.sh` stdout
and stderr through the lifecycle-local quiet path so that successful uninstall runs
surface only the doctrine-owned summary lines, while non-zero uninstall exits still
surface actionable upstream context through `summarizeRke2DeleteFailure`. Benign
upstream chatter the uninstaller writes to its own stdout/stderr — `Cannot find device`,
`semodule: not found`, and `Cleanup completed successfully` — is classified as ignorable
noise and does not reach the operator on success. The inotify warning
`Failed to allocate directory watch: Too many open files` is the exception: the systemd
manager (PID 1) / journald emits it out-of-band to the console, not through the
uninstaller's captured fds, so the quiet path cannot suppress it and it may still appear
on the operator terminal on a successful run (benign — teardown still succeeds).

## 6. Test Expectations

Lifecycle-oriented validation should prove:

1. the real MinIO PVC remains bound to the same PV across delete/reinstall, and the
   Vault-Transit-enveloped in-force config object inside MinIO is unchanged
2. only the `manual` `StorageClass` remains after `prodbox cluster reconcile`
3. the `keycloak-postgres` and `vscode` storage bindings remain deterministic for their
   root namespaces
4. Percona PostgreSQL PVC discovery binds retained PVs to the operator-created claim
   names before dependent charts continue
5. retained Patroni redeploy preserves the ordinal `0` anchor PV, resets retained
   follower roots for ordinals `1` and `2`, and scales from one replica back to the
   supported three-replica steady state
6. Patroni passwords fetched from Vault KV via Vault Kubernetes auth authenticate
   against the preserved `pg_authid` on a wipe-and-rebuild cycle
7. `prodbox cluster delete --yes` succeeds on the first operator invocation
8. temporary validation resources are fully removed at test end
9. baseline runtime after test completion matches the post-install state defined by
   `prodbox cluster reconcile`
10. a deleted MinIO export host-path mount is repaired back onto the declared retained
    directory before Pulumi backend login or stack operations continue
11. no `prodbox` invocation writes to `.prodbox-state/` (enforced by
    `forbidDotProdboxState` in `prodbox dev check`)
12. `prodbox test integration eks-volume-rebind` writes a sentinel through the retained
    MinIO workload PV, tears the cluster substrate down, brings it back, and verifies the
    same PV/PVC is `Bound`, the sentinel persists, and any EBS CSI `volumeHandle` is
    identical before and after the cycle. Deployment-qualification evidence is recorded only in
    the [Development Plan](../../DEVELOPMENT_PLAN/README.md).
13. destructive AWS Vault/EBS rebuild qualification preserves/read-backs the retained-home SMTP/EAB
    source receipts, recreates a fresh target Vault, materializes the exact generations through
    attested home/selected Agent workers, and proves no admin re-prompt, EAB re-entry, SMTP-key
    rotation, plaintext Authority/outbox field, or generic export path occurred.

Cleanup ownership is defined in
[Integration Fixture Doctrine](./integration_fixture_doctrine.md). Test-scoped retained-volume
deletion is a registered node in its always-run cleanup DAG; failure of one destroy does not prevent
independent cleanup, and credential teardown remains dependency-blocked until credential-dependent
storage cleanup has completed or authoritatively observed absence.

## 7. The Single Retained Operator-Host Root

`.data/` is the only repository-local retained root.

Rules:

1. `.data/` stores PV content. The MinIO PV at `.data/prodbox/minio/0` is the persistence
   anchor for the per-run Pulumi backend checkpoints and for the Vault-Transit-enveloped
   in-force cluster configuration, all held in the `prodbox-state` bucket. The Vault PV at
   `.data/vault/vault/0` anchors the secret material itself (KV, Transit, PKI), including the
   retained-home payload-specific SMTP/EAB custody objects and source receipts used to rebuild
   selected-target generations.
   - **On-disk consequence (whole-system zero-child-info).** Sprint `4.30` ensures Model-B logical
     objects use `prodbox-envelope-v2` ciphertext stored under Vault-keyed-HMAC opaque IDs
     (`objects/<opaque-id>.enc`) in the single generic bucket, with the production in-force config
     read using that opaque key. Sprint `7.14` routes main Pulumi checkpoints behind the same
     decrypt-to-scratch object-store interposition; Sprint `4.33` gates the Haskell-side
     host-disk/Kubernetes/log/oracle renderers behind Vault readiness, and Sprint `5.8` proves the
     deployed sealed-state sweep reveals no logical object name, stack key, cleartext body, or
     child-count signal across all surfaces.
2. The internal `keycloak-postgres` release uses the deterministic path
   `.data/<namespace>/prodbox-<root-chart>-pg/<ordinal>`.
3. The `vscode` StatefulSet uses the deterministic path
   `.data/vscode/vscode/0`.
4. Deterministic PV and Patroni resource names flow through `src/Prodbox/Naming.hs`;
   retained PVs use the `prodbox-retained-<namespace>-<statefulset>-<ordinal>`
   shape before bounded-name truncation.
5. Patroni service names, PVC names, and storage-spec inventory flow through
   `src/Prodbox/PostgresPlatform.hs` rather than through chart-platform string
   concatenation.
6. The `api`, `redis`, and `websocket` workloads do not currently allocate
   deterministic `.data/` roots on the supported path.
7. The retained Patroni anchor path is
   `.data/<namespace>/prodbox-<root-chart>-pg/0`; follower
   paths for ordinals `1` and `2` are preserved on disk but must be reset before those
   replicas rejoin a restored cluster.
8. `prodbox charts delete <chart>` deletes PV/PVC objects but never removes `.data/`.
9. Cluster delete preserves `.data/` so reinstall can reconnect stateful services and
   so the MinIO `prodbox-state` bucket contents plus the Vault PV remain available across the
   cycle. The in-force config uses the opaque Model-B object key; main Pulumi checkpoints use the
   Sprint `7.14` decrypt-to-scratch interposition, with first-touch raw checkpoint migration into
   the encrypted object-store.
10. Deleting `.data/` is an operator-only action. It is the supported way to start from
    a truly empty baseline; on the next reconcile a brand-new Vault is initialized from
    the empty anchor and every secret is generated fresh as a new Vault KV object.
11. `.data/vault/vault/0` is the durable Vault storage anchor. It is preserved by cluster
    delete and only removed when the operator wipes `.data/`. A cluster rebuild against the
    preserved anchor never re-inits Vault — `vault init` runs exactly once, when the anchor
    is first empty, and every later reconcile only unseals the existing data. Vault state is
    lost only when the operator deliberately wipes `.data/`, at which point the next reconcile
    inits a brand-new Vault from an empty anchor.
12. The root Vault bootstrap transaction lives only in durable MinIO, never host disk. Before first
    `/sys/init`, the Broker writes/read-backs the password-AEAD `PreparedInitEnvelope`; after init it
    persists/read-backs Vault's PGP-encrypted response, atomically promotes/read-backs the final
    password-AEAD unlock bundle, and only then deletes/read-backs the prepared envelope. See
    [vault_doctrine.md §6](./vault_doctrine.md#6-the-unlock-bundle). The only related host-disk
    artifact is the non-secret `.cluster-established` marker.
13. Test runs use a **separate `.test-data/` retained root**, never `.data/`. A `prodbox test`
    run overrides `storage.manual_pv_host_root` to `.test-data/` (isolating each case under
    `.test-data/<case>/`), and test commands are mechanically forbidden from touching the
    production `.data/`; see
    [test_topology_doctrine.md § 4](./test_topology_doctrine.md#4-fail-fast-preconditions-and-test-data-isolation).
14. The hardcoded chart storage sizes (e.g. the 20Gi MinIO PV hint) are a transitional default:
    how much durable data each store may hold is superseded by the finite-budget capacity DSL in
    [tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md), where a sizeless
    durable claim or an over-quota topology is a Dhall typecheck failure.
15. On the AWS/EKS substrate there is no operator-host retained root; the durable block storage
    is the set of pre-created EBS volumes, which play the role `.data/` plays on home. They are
    `Retain`, AZ-pinned, and preserved across cluster/stack teardown. A production operator
    deletes them only deliberately (the EBS analog of wiping `.data/`), while the test harness
    deletes only test-scoped-tagged volumes at suite postflight, cascade teardown, or the standalone
    `aws ebs reap-test --yes` recovery command — the EBS analog of the
    `.test-data/` isolation in rule 13 (Sprints `7.28`, `4.39`, `4.40`).

## Cross-References

- [Config Doctrine](./config_doctrine.md) — storage paths and MinIO coordinates live in
  the daemon's Dhall config, not in environment variables
- [Secret Derivation Doctrine](./secret_derivation_doctrine.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Cluster Topology Doctrine](./cluster_topology_doctrine.md) — owns the "no dynamic
  provisioning anywhere" invariant and the EKS AZ/placement topology this doctrine's EBS
  PVs pin to
- [Documentation Standards](../documentation_standards.md)
