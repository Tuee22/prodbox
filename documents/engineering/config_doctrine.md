# Config Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Single source of truth for how every `prodbox` binary instance — host CLI,
> lifecycle control-plane services, gateway runtime, and workloads — sources, parses, watches, and
> reloads its configuration.

> **Current/target correspondence.** The current host CLI resolves the binary-sibling
> `prodbox.dhall`, and long-running workloads consume mounted Dhall through their existing runtime
> paths. The Lifecycle-Authority aggregate, immutable encrypted in-force blob, role-scoped
> projections, and separated Broker/Adapter/Worker topology below are the target contract; they are
> not yet the active production selection. Explicit “current” and “historical” paragraphs describe
> the pre-cutover source. Implementation status and cutover ownership live only in the
> [Development Plan](../../DEVELOPMENT_PLAN/README.md#current-plan-status).

## 0. Three-Tier Config Model

This section is the **one canonical home** for the three-tier config separation. Every other
prodbox doc references this section by relative link rather than restating the tier definitions.
The model partitions every value a `prodbox` binary needs into three tiers by secrecy and by the
trust state required to read it.

- **TIER 0 — NON-SECRET BINARY CONTEXT.** A binary-owned, canonically rendered, project-local
  `prodbox.dhall`
  carrying parameters + context + witness, and NEVER secrets — shaped to align with hostbootstrap's
  binary-context contract (the future base prodbox will build on). It is self-contained (no
  imports) and IS the dependency-free sealed-Vault bootstrap floor: the binary decodes it and
  projects the basics via `projectBasics`, read before Vault is reachable. There is NO separate
  JSON floor — `prodbox-basics.json` is ELIMINATED, and so is the legacy
  `.data/prodbox/unencrypted-basics.json` it replaced. `prodbox.dhall` is written in canonical form
  by the binary (`writeTier0` / `ensureBasicsFloor`) after `prodbox config generate`, `prodbox config
  setup`, or a test-harness authoring step. Its non-secret semantic fields are operator-authored and
  may be edited directly, but the canonical renderer/stamped witness remains the write contract and
  the quality gate reports an unstamped or noncanonical edit. There is **NO
  fallback default**: an operation that needs `prodbox.dhall` (e.g. the `vault init` Tier-0 floor
  stamp, `writeTier0FloorPreservingParameters`) **fails fast** when it is absent rather than
  synthesizing a default — only the generators (`config generate` / `config setup`, or the test
  harness) author it. BINARY-SIBLING, ONE FILENAME EVERYWHERE: every `prodbox` binary resolves
  `prodbox.dhall` at its own **binary-sibling path** (`takeDirectory getExecutablePath </>
  "prodbox.dhall"`, i.e. `.build/prodbox.dhall` beside the host binary) — never the repo root, never
  a `--config` flag, never `/etc/prodbox/...`. The filename is `prodbox.dhall` in every context
  (host, container, test harness), matching hostbootstrap's binary-owns-its-config contract: a
  command that needs config fails fast when the sibling file is absent, and the file is created only
  by running the binary (`config generate` / `config setup`) or by the test harness. IN-CLUSTER:
  there is **no committed or COPY-ed container default** — the image build, after building and
  installing the binary, **runs the binary** to generate a binary-sibling `prodbox.dhall` that
  serves ephemeral in-container CLI commands. Long-running cluster services are configured by
  their own ConfigMap-mounted `--config` document, Service identity, and authority scope,
  independently of the build-time binary-sibling default. Gateway Runtime retains its per-node
  directory-mount shape so kubelet's atomic `..data` swap fires fsnotify; Bootstrap Broker,
  Lifecycle Authority, Authority Backup Adapter, TLS Retention Adapter, Provider Worker, and each
  Target Secret Agent have separate mounts and identities. The mode-indexed Credential Provisioner
  and Admin Action Runner are separately configured, attested one-shot Jobs; neither borrows a
  steady workload's mount or identity.
- **TIER 1 — BOOTSTRAP SECRET (PASSWORD-GATED).** The Vault unlock material (Shamir unseal or
  recovery shares) is password-AEAD-sealed (Argon2id + ChaCha20-Poly1305) and
  lives in the DURABLE MinIO bucket — NOT on host disk, and NOT a Vault-Transit envelope (it is
  what UNSEALS Vault, so it cannot depend on an unsealed Vault). Before first `/sys/init`, the same
  Tier owns a temporary password-AEAD `PreparedInitEnvelope` containing the generated PGP
  share-recipient private key plus the exact pristine observation, transaction/storage generation,
  schema, share count, threshold, ordered canonical `pgp_keys` array/digest, recovery fingerprint,
  and compiled burn fingerprint/public-key-digest binding. It is read back before init and
  deleted/read-back absent only after Vault's encrypted response is durable and the final unlock
  bundle is atomically promoted/read-back. It is read via the **static** MinIO
  root credential (`Prodbox.Minio.RootCredential`; operator decision 2026-06-22 — the access
  credential is not the security boundary, so password-deriving it was theatre). The operator
  password is the sole operator-memorized bootstrap secret (the prepared/final-body AEAD key). A
  static MinIO credential is
  stable across rebuilds (a retained MinIO PV always matches Vault) and is one MinIO accepts (the
  bundle round-trips through MinIO, no `InvalidAccessKeyId`). **Disk-free (in force, Sprint `7.25`):**
  the bundle lives ONLY in MinIO — host disk holds no unseal material — and MinIO is reordered before
  Vault (cluster-only, so it serves the bundle pre-unseal). The only on-disk artifact is a NON-SECRET
  `.cluster-established` marker (not the bundle). Child clusters use transit-seal (no bundle; recovery
  keys in the parent's KV) —
  Tier 1 is root-cluster-only.
- **TIER 2 — OPERATIONAL SECRETS AND ENCRYPTED STATE (VAULT-GATED).** Operational secrets live in
  allowlisted Vault KV/Transit/PKI paths. Authority config/checkpoint/index state is stored as
  opaque Vault-Transit-enveloped objects: primary bytes in retained MinIO plus mandatory exact
  ciphertext copies/read-back at the independently credentialed S3 backup coordinate. The
  Lifecycle Authority generation/reference alone makes one config blob current; the backup copy is
  not another config SSoT. Public-edge TLS retention is a second, disjoint S3 prefix protocol:
  exact certificate/key ciphertext plus a retained-home-Transit-wrapped DEK is written/read back by
  the TLS Retention Adapter, while plaintext exists only in selected/home Target Agent one-shot
  workers. The shared S3 bucket is not TLS-owned: TLS deletion removes only registered TLS prefix
  objects/versions and identity, while final bucket deletion belongs to the Authority-backup
  decommission tail after every registered prefix is absent. Closed SMTP and ACME-EAB source
  payloads use a third retained-home Agent protocol: payload-specific Transit-sealed custody plus
  attestation-encrypted one-shot rewrap to an allowlisted selected-target schema. Authority/outbox
  sees only ciphertext and typed receipts; a rebuilt AWS Vault requires neither secret re-entry nor
  SMTP key rotation, and no generic export exists. Gateway emitter continuity is the
  deliberate storage exception:
  it is an encrypted identity-bound retained local journal, keyed by a managed Vault session, not a
  shared Model-B object rewritten on every heartbeat.
  Config carries only `SecretRef.Vault` POINTERS (non-secret coordinates) that resolve here at use
  time.

### All config Dhall is generated or locally-authored; none is version-controlled

Every Dhall **config and fixture** surface prodbox uses is either GENERATED by a binary or locally
authored by the operator, and none of it is version-controlled. The tracked exceptions are the four
hand-authored algebra schemas under `dhall/` and one golden fixture, which carry lemmas and schemas
rather than instance config — see the correction under the inventory below. The end-state inventory:

- `prodbox.dhall` — Tier-0 binary context, written canonically by `writeTier0` /
  `ensureBasicsFloor`, self-contained, non-secret, operator-editable, and git-ignored. It lives at
  the **binary-sibling path**
  (`.build/prodbox.dhall` beside the host binary), not the repo root. There is no separate
  committed container default; the in-container `prodbox.dhall` is generated at image-build time by
  **running the binary** at the same binary-sibling path (Sprint `1.49`).
- `prodbox-config-types.dhall` + `test-secrets-types.dhall` — GENERATED schemas, git-ignored
  (the one-time operator `git rm --cached` untracks the two currently-committed schema files;
  Sprint `1.41`).
- `prodbox-config.dhall` — **RETIRED (Sprint `1.42`, 2026-06-19)**. The operator's non-secret
  config now lives in the binary-generated, git-ignored Tier-0 `prodbox.dhall` `parameters`
  sub-record (which is structurally a `ConfigFile`); no production code reads a repo-root
  `prodbox-config.dhall`. The name survives only as the internal temp basename the in-force SSoT
  payload decoder (`Settings.decodeConfigFileAtPath`) materialises beside `prodbox-config-types.dhall`.
- `test-secrets.dhall` — test fixture (harness-only), git-ignored. **Sprint `1.43`** renamed the
  former `test-config.dhall` to `test-secrets.dhall` and made it the SOLE durable-secret fixture
  file: it carries `vault_operator_password`, `aws_admin_for_test_simulation.*`, and `acme_eab`.
  There is no separate non-secret `test-config.dhall` — the fixture carried no non-secret toggles,
  so per the sprint's "removed if empty" clause that file (and its generated
  `test-config-types.dhall` schema) is gone; the generated schema is now `test-secrets-types.dhall`.
  It is also the one file where cleartext operator ids the harness injects into the generated
  `prodbox.dhall` live — e.g. `route53_zone_id` (Sprint `5.10`; see "The test harness generates its
  run config" below).

Net: zero version-controlled `.dhall` **among the config and fixture files** — `prodbox.dhall`,
`test-secrets.dhall`, and both generated schemas are untracked. `prodbox-basics.json` is eliminated
outright.

**Correction (2026-08-07)**: this line previously read "Net: zero version-controlled `.dhall`"
without qualification, which is false. `git ls-files "*.dhall"` returns five tracked files: the
hand-authored algebra schemas `dhall/capacity/Schema.dhall`, `dhall/cluster/Schema.dhall`,
`dhall/capacity/measured/Schema.dhall`, and `dhall/TestTopologySchema.dhall`, plus the fixture
`test/golden/capacity/measured-gateway.dhall`. Those are version-controlled by design — they carry
the Ring-1 lemmas and the measured-profile schema, not instance config — and the claim was only ever
meant to cover the config surface. See [resource_scaling_doctrine.md § 2C](./resource_scaling_doctrine.md)
for what their `assert`s do and do not prove.

### The test harness generates its run config

The test harness does not require a hand-authored `prodbox.dhall`. It **generates** its run config
the same way production does — through the **same builder** `config setup` uses
(`configFromSetupInput`, the one place the `ConfigSetupInput` → `ConfigFile` construction lives,
Sprint `1.50`) — so the harness drives the real reconcile/IAM flows against a config it generated,
not a fixture it carries. This mirrors hostbootstrap's `demoTestConfig`-reuses-`demoInit` idiom.

The harness sources the builder's inputs non-interactively (Sprint `5.10`): the cleartext operator
ids that a real operator would supply at the interactive prompts come from `test-secrets.dhall`
(e.g. `route53_zone_id` — the one file where cleartext secrets are allowed), `acme.email` comes from
a baked operator-email default, and the remaining knobs come from the same defaults the generated
skeleton already carries. The harness regenerates the binary-sibling `prodbox.dhall` only when the
operator fields are empty (it refuses to clobber a populated real config), as a preflight before the
managed AWS IAM harness validates the bootstrap config (`validateAwsBootstrapConfig`). The deferred
operator ids (`aws_substrate.*`, `ses.*`, `pulumi_state_backend.*`) extend the same way when a run
needs them.

### The in-force config authority is seeded, then the seed is retired

The **in-force config** is an immutable encrypted blob whose schema, digest, reference, and
generation are current only when the Lifecycle Authority aggregate names them. On first bring-up,
the operator-authored Tier-0 payload is submitted as a visible `ConfigProposeCas` seed operation;
it is never written directly to MinIO. Once accepted, every component reads a role-scoped
projection through Lifecycle Authority, not from the filesystem seed or object store.
The seed source is now the
binary-generated Tier-0 `prodbox.dhall` `parameters` (Sprint `1.42`, 2026-06-19 — the standalone
`prodbox-config.dhall` seed file is RETIRED). `Settings.loadConfigFile` decodes
`( prodbox.dhall ).parameters` (a Dhall field-projection, keeping `Settings` free of the
`Tier0`↔`Settings` import cycle); `config generate` / `config setup` author the operator's non-secret
config (Route 53 zones, SES domains, ACME email, shared retained-bucket coordinates) into
`prodbox.dhall`'s `parameters`, preserving the established `context`/`witness`. `aws setup` and
`vault init` consume this Tier-0 surface; they do not become alternate config authors. The
non-secret seed carries no plaintext secrets or plaintext-secret hash. Role-specific credential
coordinates point to distinct Operational Lifecycle-provider/AWS-DNS01 and LongLived
Authority-backup-store/TLS-retention-store/home Gateway-DNS/home-DNS01 generations, plus ACME-EAB;
the shared `aws.*` pointer is a pre-cutover legacy shape.

**Establishment + no fallback:** Lifecycle Authority reports config absent, observed, corrupt, or
unobservable. Only `absent` permits a visible seed proposal; an unlock bundle is not config-presence
evidence. A sealed or unreachable Vault, corrupt aggregate, or failed blob read-back never falls
back to `prodbox.dhall` parameters.

### The balance principle

Tier 0 is shaped to hostbootstrap's binary-context contract TODAY, so the eventual refactor onto
hostbootstrap is a clean EXTENSION, not a rewrite. Tiers 1-2 (the obfuscated MinIO secret store +
the sealed-Vault fail-closed posture) are prodbox's ADDITIVE L1 layer that hostbootstrap deliberately
does NOT own. Neither goal is compromised: non-secret config follows the shared base; secrecy is
prodbox's additive layer.

### Typed topology / capacity fields, the test-run inversion, and serialization

The Tier-0 `prodbox.dhall` `parameters` gain typed cluster-type, host-provider, substrate,
capacity, scaling, spot-economics, and ML-storage-budget fields, each owned by its own doctrine and
not restated here: [cluster_topology_doctrine.md](./cluster_topology_doctrine.md) (cluster-type /
substrate), [host_platform_doctrine.md](./host_platform_doctrine.md) (host-provider),
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md) (scaling + spot), and
[tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md) (ML-storage / capacity
budget). A **test** run inverts §3's resolution contract: it **fails fast when a binary-sibling
`prodbox.dhall` is PRESENT** (the exact inverse of production's fail-if-absent) per
[test_topology_doctrine.md](./test_topology_doctrine.md). Dhall stays the human-authoring language
for all of these fields while CBOR is the at-rest / wire serialization per
[pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md). None of the new fields carries a
secret — secrets stay `SecretRef`-by-name (§6.2), with no literal secret at rest except the flagged
`test-secrets.dhall`.

`capacity.resource_plan` is non-secret operator-authored Dhall and carries host physical capacity,
RKE2 reservation, eviction floor, and typed workload-demand inputs. It does **not** carry an
independently authored request/limit envelope. Sprint `1.71` derives that envelope from the referenced
runtime-memory plan, service-demand/calibration contract, bounded scratch, durable storage, topology,
and QoS before `Settings.validateConfig` / `validateLocalConfig` compile the **decoded in-force**
`resource_plan` into the opaque proof-carrying `AllocatedResourcePlan`
(`Prodbox.Capacity.Allocation`) and carry it as a **required field of `ValidatedSettings`** — the
**decode gate**: an over-committed *authored* config produces no `AllocatedResourcePlan`, hence no
`ValidatedSettings`, hence no renderer input, so the illegal state is unrepresentable rather than
caught by a later inequality.

**Three precisions on that sentence (corrected 2026-08-11).** The shape is real — the field is
required, `validateConfig` short-circuits on `Either`, and `AllocatedResourcePlan` is genuinely
exported without its constructor. But read the guarantee at its actual strength:

1. **The field's type is `SomeAllocatedPlan`, not `AllocatedResourcePlan`** — an existential wrapper
   whose own constructor *is* exported. Opacity survives (matching one out still yields an
   unforgeable inner value), but the type named above is not the field's type.
2. **On this path the proof is always the weaker one.** `validateConfig` calls
   `compileResourcePlanUncertified`, which is `compileResourcePlan []` — an empty measured-profile
   list — so every workload resolves to `WorkloadUncertifiedUntilFirstProfile` and the existential
   tag is **never** `Certified`. "Proof-carrying" here means *the arithmetic fit is proven*, not that
   any workload is certified against a measured profile.
3. **`ValidatedSettings` exports its constructor**, so "no proof ⇒ no `ValidatedSettings`" holds for
   the `validateConfig` path and not for the type. There is a production construction site that
   bypasses `validateConfig` entirely and obtains its plan by `error`-ing on failure
   (`defaultResourceStatusSettings` in `src/Prodbox/CLI/Rke2.hs`), and the record's exported fields
   permit an existing value to be updated so its `validatedConfig` no longer agrees with its proof.
   The gate is a *function*, not a *type*.

The scale of what rides along unrefined is recorded as one row in
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). This supersedes the runtime-`Either` `validateResourcePlan` inequality
body (`rke2_reserved + eviction_floor <= host_capacity`, quota-fits-`cluster_allocatable`, positive
bounded envelopes); only the slim `validateRawResourcePlanShape` survives, as the decode-time shape
slice `compileResourcePlan` reuses. Namespace `ResourceQuota`/`LimitRange` are **derived**
projections of Kubernetes scheduling units built from those workload contracts rather than authored, so the authored
`namespace_quotas`/`NamespaceQuota` type and the `concurrentNamespaceQuotas` fold (historically the
keycloak–vscode hand-fold) are retired in favor of a typed `WorkloadConcurrency`
(`Steady | ExclusiveWindow`) that models co-location/burst structurally. The raw `ResourcePlan`
stays the `FromDhall` decode surface. The over-commit algebra and the honest three-ring boundary are
owned by
[resource_scaling_doctrine.md § 2A](./resource_scaling_doctrine.md#2a-resource-requirements-are-mandatory-and-capped)
and [§ 2C](./resource_scaling_doctrine.md#2c-enforcement-rings); the sprint sequencing (`1.69` decode
gate, `1.70` `GuaranteedEnvelope` wiring, `1.71` derived workload contracts, `1.72` Ring-1 `assertPlanValid`
Dhall over-commit shim, `1.73` host-fitting `config generate`, `3.27` derived namespace admission, `3.28` unified
`Capacity.Render`, `3.29` durable-PVC single source, `4.52` observed-host proof) and its status live
in the [Development Plan](../../DEVELOPMENT_PLAN/README.md). The older `node_budget` /
`workload_budget` / `region_quota` fields remain as compatibility projections for callers not yet
migrated to the resource plan.

`prodbox config generate` **derives** `host_capacity` from the observed deploy host rather than emitting a
fixed default: it covers the plan's demand and fits the real device, failing fast when the host is too
small (`--portable` opts out for host-agnostic generation — the image build, whose baked config is
overwritten from the ConfigMap at runtime). The emitted binary-sibling `prodbox.dhall` additionally
carries the Ring-1 `assertPlanValid` over-commit assert, so an over-committed hand-edit fails to load
through `decodeProjectConfigDhall`. Both the host-fitting derivation and the over-commit assert are owned
by [resource_scaling_doctrine.md § 2B](./resource_scaling_doctrine.md#2b-host-rke2-cluster-namespace-and-pod-lemmas)
/ [§ 2C](./resource_scaling_doctrine.md#2c-enforcement-rings) (Sprints `1.72`/`1.73`).

**Historical implementation record.** Sprint `1.56` extended the Tier-0 `parameters` with a typed **component dependency/readiness graph**
(`depends_on` edges plus a `ReadinessProbe` per component), owned by
[bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md) and not restated here. The graph
is non-secret operator/generated Dhall; its validity (acyclic, no dangling id, and every dependency
edge carrying a readiness node) is checked by the pure `EffectDAG` expansion when the config is
projected, so a bootstrap plan that would race a consumer ahead of its dependency's proven readiness
is not a well-formed config value.

The current component graph splits each genuinely two-phase component into two bounded graph nodes,
each with exactly one probe:

- `ComponentClusterBase` carries `ProbeServiceActive`; host-service readiness is distinct from a
  Kubernetes rollout.
- `ComponentVaultWorkload` carries `ProbeRolloutComplete`;
  `ComponentVaultUnsealed` carries the deep `ProbeVaultUnsealed` and depends on both the workload
  node and `ComponentGatewayDaemonPreVault`, because supported root bootstrap/unseal is
  daemon-mediated.
- `ComponentGatewayDaemonPreVault` carries `ProbeRolloutComplete` and depends on MinIO,
  cert-manager, and the Vault workload; `ComponentGatewayDaemonFull` carries
  `ProbeBackendRoundTrip ComponentMinio`, depends on the unsealed-Vault and pre-Vault-daemon nodes,
  and declares a `BackendWriteEdge` to MinIO matching that exact deep probe.

Because the graph is a Tier-0 `parameters` field, the ID/probe split is a **schema change**.
`prodbox config generate` regenerates the GENERATED, git-ignored `prodbox-config-types.dhall` with
the split IDs, `ProbeServiceActive`, `ProbeVaultUnsealed`, and corrected edge set; the schema
remains untracked and is never hand-edited. Sprint `1.59`'s closure audit reran generation after
those final probe/edge corrections, and `prodbox config validate` decoded the result (both commands
exit 0; unit 1259/1259 and `dev check` 0).
The generated-artifact discipline remains owned by
[code_quality.md](./code_quality.md#generated-artifacts). Phase `4` Sprint `4.45`, not this config
sprint, owns reconcile-driver consumption of the graph-derived order.

**Target graph contract.** The graph carries pure `CapabilityRequirement` values, never probe
closures or arbitrary `IO`. Each requirement names the exact operation kind, service identity,
authority scope, and latency budget. Runtime reconnaissance resolves it to one opaque
`CapabilityRef kind`; observation, admission, and execution all use that same reference, so config
cannot inject a nominal probe endpoint separately from the execution coordinate. The target graph
has distinct service identities for Bootstrap Broker, Lifecycle Authority, home Authority Backup
Adapter, TLS Retention Adapter, home Provider Worker, each substrate's Target Secret Agent, and
Gateway Runtime. It also represents permit-bound on-demand Credential Provisioner and Admin Action
Runner jobs without pretending either is a standing Service. The historical
`ComponentGatewayDaemonPreVault` /
`ComponentGatewayDaemonFull` split is superseded: Gateway Runtime has no pre-Vault authority, and
Bootstrap Broker alone owns bounded Vault init/unlock/seal/rotation. Target topology and type shape
are canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md); implementation,
cutover, and qualification status remain solely in the Development Plan.

The post-export Decommission Runner is intentionally absent from the live component graph and
cluster mount inventory. It starts only after Authority exports a signed manifest plus durable
external receipt and permanently stops. Its non-secret inputs are that verified manifest/receipt,
the compiled closed action-tag verifier, and Tier-0 trust coordinates; its fresh admin prompt uses
separate linear ingress and never becomes Dhall or target-cluster state.

## 1. Why this doctrine exists

Every `prodbox` process needs configuration: hostnames, AWS coordinates, ports, ranked-node
inventories, timing knobs, credentials, TLS material. Historically the supported architecture
collected those values from a mix of sources: a repository-root `prodbox-config.dhall` for
host-CLI bootstrap settings, a per-Pod `config.json` rendered by the gateway chart for
daemon runtime knobs, a per-Pod `orders.json` for cluster topology, environment variables for
credentials and selected overrides (`AWS_*`, `MINIO_*`, `GATEWAY_NODE_ID`,
`PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT`, `PRODBOX_WORKLOAD_MODE`), and
files mounted from k8s Secrets for cryptographic material. The reload path was different
again — SIGHUP on the daemon, full process restart on the host, no live reload for chart
workloads.

That mix is no longer the supported architecture. Every `prodbox` binary takes its
configuration from exactly one Dhall file. The in-cluster binaries — Bootstrap Broker, Lifecycle
Authority, Authority Backup Adapter, TLS Retention Adapter, Provider Worker, Target Secret Agent,
Gateway Runtime, permit-bound Credential Provisioner/Admin Action Runner Jobs, and workload Pods —
name that file with a
`--config <path>` flag (the renderer passes the mounted ConfigMap path). The **host CLI** reads the executable-sibling Tier-0 `prodbox.dhall`
as a *seed/propose input only* — never as the in-force source of truth.
Either way the rule is one Dhall file per process and nothing else, and that file carries no
secret material. Sensitive fields are typed `SecretRef` values, never inline plaintext: the
production targets are `SecretRef.Vault` / `SecretRef.TransitKey` references resolved through
Vault. In-cluster consumers authenticate to Vault directly via Vault Kubernetes auth — there
are no Secret-mounted Dhall credential fragments and no `as Text` credential imports. See
[vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model) and
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth).

The reload model is symmetric: the running binary watches the file at its `--config` path,
classifies each on-disk change as a BootConfig change (drain + exit so kubelet restarts the
Pod) or a LiveConfig change (atomic STM swap, no restart), and acts accordingly. SIGHUP is no
longer the canonical reload trigger.

One further inversion governs *what the file means*. The in-force cluster configuration is not
the on-disk Dhall — it is the immutable Vault-Transit-enveloped blob named by schema, digest,
reference, and generation in the Lifecycle Authority aggregate. The filesystem `prodbox.dhall` is
the Tier-0 seed/propose input that submits a visible update to that source of truth; the binary reads
only the unencrypted basics locally and observes a role-scoped config projection through the exact
Lifecycle Authority capability. Section
1a states this inversion in full; the
SecretRef union (Section 6.2), the import rules (Section 5), and the cluster mount contract
(Section 6) are all expressed against it.

## 1a. The in-force config is an authority-referenced encrypted blob

The **in-force cluster configuration** is stored as a prodbox object-level Vault-Transit
envelope, but the blob is current only when the bounded Lifecycle Authority aggregate names its
schema, digest, reference, and generation. The aggregate plus referenced immutable blob form the
source of truth. This is not a distinct
mechanism: the in-force config is one logical object routed through the shared Tier-2 Model-B
object store used by other Vault-gated config/checkpoint blobs. The Tier-1 unlock bundle and
Gateway's identity-bound local journal have different bounded owners. The config blob lands as an opaque, HMAC-named
`objects/<id>.enc` ciphertext in the one generically-named bucket — **never** under a literal,
role-revealing `in-force-config` key. The id↔logical map lives only in the Vault-encrypted
index, so a sealed-Vault MinIO listing exposes only opaque object IDs at a decoy-padded constant
count, never the fact that an in-force config exists. When Vault is sealed the object is opaque
ciphertext: nothing about the cluster's setup, its workloads, or its child clusters is
determinable beyond the *unencrypted basics*. This is the same fail-closed posture every other
prodbox-owned MinIO object obeys — a sealed Vault reduces prodbox to an opaque durable-data
pile. See [vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store) and
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md).

**Primary plus independent backup, authority-owned by capability.** The envelope, HMAC-naming, and index
discipline are shared, but no generic daemon proxy owns them. Bootstrap Broker alone accesses the
bounded pre-Vault prepared/encrypted-response/final-bundle transaction. Lifecycle Authority alone
owns the in-force config
generation/blob reference, durable operation records, leases/fences, Model-B CAS, immutable checkpoint references, provider workflow, and delivery
outbox. Each Target Secret Agent owns its substrate-attested allowlisted generation-checked Vault KV
read/CAS/read-back. The retained-home Agent additionally owns payload-specific Transit custody and
rewrap for the closed `SesSmtpSource` and `AcmeEabSource` schemas; attested selected-target one-shot
workers alone materialize them. Gateway Runtime owns mesh/DNS and its encrypted identity-bound local
emitter journal only; it has no generic MinIO, lifecycle, Pulumi, bootstrap, federation-custody, or
target-secret authority. Host and suite callers resolve an operation-indexed `CapabilityRef` to the
owning service, and use that same reference for observation, admission, and execution.

The Authority Backup Adapter is a separate home workload whose config carries only the exact
backup coordinate and `secret/aws/authority-backup-store`. The TLS Retention Adapter is another
separate workload whose config carries only exact registered `public-edge-tls` coordinates and
`secret/aws/tls-retention-store`; it cannot decrypt TLS bytes or address the Authority-backup
prefix. The Provider Worker has only Lifecycle-provider coordinates. Credential Provisioner and
Admin Action Runner configs contain secret-free permit/attestation bounds; raw prompt and newly
returned secret bytes arrive over separate authenticated, schema-indexed linear ingress and never
enter Dhall. The AWS admin prompt cannot satisfy the externally supplied EAB ingress, and `config
setup` authors neither input.

**Historical implementation record (legacy cutover surface).** Sprints `4.42` and `7.30` routed supported
root-lifecycle and Pulumi object-store traffic through a loopback-restricted gateway daemon
NodePort. Remaining gateway object-store routes, direct host-root-token `DekCipher` plus host MinIO
port-forward transports, and endpoint-inferred authority are migration residue tracked in the
cleanup ledger. They are not target authority. The underlying
`Prodbox.Minio.EncryptedObject` envelope remains valid behind Bootstrap Broker or Lifecycle
Authority according to operation and policy. The separate Backup Adapter stores/read-backs the
same ciphertext bytes at its S3 coordinate; it cannot decrypt config or make a reference current.
See
[vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store) and
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

**The bootstrap floor is the Tier-0 `prodbox.dhall`.** The basics are the minimal, non-revealing
bootstrap needed only to reach and unseal Vault: the cluster id, this cluster's Vault address, the
seal mode, and (for a child cluster) the parent reference it must contact to auto-unseal. They are
not an independent source and there is no separate JSON floor — the binary reads the self-contained
Tier-0 `prodbox.dhall` non-secret binary context (§0) directly and projects the basics via
`projectBasics`. `prodbox.dhall` is dependency-free (no imports) so it can be read before Vault is
reachable. The floor carries nothing about workloads, downstream clusters, or credentials, and —
like all of Tier 0 — it never carries a secret value: sensitive fields are `SecretRef.Vault`
POINTERS (non-secret coordinates) resolved against the Tier-2 store at use time, not inline
plaintext. Reads of the floor are always free — they are exactly the surface a host that cannot yet
reach an unsealed Vault is allowed to see. The legacy `.data/prodbox/unencrypted-basics.json` file
surface AND the derived `prodbox-basics.json` projection are both ELIMINATED: the floor is read
directly from `prodbox.dhall` (Sprint `1.41`; see §0).

**Filesystem Dhall is seed/propose, not SSoT.** A filesystem `prodbox.dhall` is a Tier-0
seed/propose input only. On first-ever bring-up its `parameters` are a visible proposal to the
Lifecycle Authority; thereafter supplying or updating that file is a *proposed update*, reconciled into the
in-force config rather than read as the live config. The prior host-CLI model — read the repo-root
`prodbox-config.dhall` directly as the live config — is retired and survives only as a legacy
payload/temp-decode shape. Target reads are "read the basics locally, then use the exact Lifecycle
Authority capability to fetch and decrypt the in-force config."

**Historical direct-loader implementation record (legacy cutover surface).** The Sprint `1.38` foundation has
landed the Dhall-payload decoder (`decodeConfigDhallBytes`) and the injected
`fetchInForceConfigWith` / `storeInForceConfigWith` composition. Sprint `4.30` routes the
production MinIO read through `Prodbox.Minio.EncryptedObject` / `ObjectStore`: `Settings` reads
`secret/object-store/hmac` from Vault, computes the opaque key for `LogicalInForceConfig`, and
fetches from the `prodbox-state` bucket. The global `validateAndLoadSettings` behavior flip is
implemented: once the basics exist, ordinary host settings loads use basics → ready Vault root
token → Vault KV MinIO credentials → object-store envelope fetch/decrypt/decode instead of
treating the binary-sibling Dhall as the live source of truth. The lifecycle reconcile path uses the
binary-sibling Dhall only as bootstrap/propose input for the pre-Vault/pre-MinIO steps, then reloads the in-force
settings through Vault and MinIO before chart and edge work continues; for a child cluster that
reload uses the child root token custodied in the parent Vault KV (Sprint `4.32`).
`storeInForceConfigWith` has zero production callers today — the twin of the floor-write gap;
Sprint `1.42` wires the first-bring-up seed so the cluster reads the in-force config from the
seeded SSoT rather than the seed-fallback (Sprint `1.39`'s `inForceConfigObjectAbsent` fallback is
the interim), after which the legacy `prodbox-config.dhall` seed is retired (§0).

**Generation-CAS config proposals.** Updating the root cluster's in-force config is a typed
Lifecycle Authority operation, never a root-token or direct MinIO write. The host obtains a
short-lived `prodbox-config-admin` TokenRequest proof, submits the expected generation plus
validated proposal digest through `ConfigProposeCas`, and uses the same authority reference for
admission and result observation. The Authority writes and reads back a new immutable encrypted
blob, then CAS-advances the config generation/reference. The caller never receives a Vault root
token or object-store credential. Root config governs every downstream cluster, so stale
generation, wrong authority epoch, corrupt current state, or unobservable read-back refuses. The
root/child trust tree, the
transit-seal auto-unseal, and downstream-cluster custody are owned by
[cluster_federation_doctrine.md](./cluster_federation_doctrine.md). (The local basics and
in-force-config foundation are in Sprint `1.38`; the federation surface is in Sprint `2.26`; the
root Shamir / child Transit seal model is in Sprint `3.20`. The pure root-write decision and
rendered refusal are in `Prodbox.Config.InForce`; the child lifecycle and post-MinIO settings
reload are wired under Sprint `4.32`.)

## 2. Single Dhall surface per binary instance

Each `prodbox` binary instance sources configuration from exactly one Dhall file. The
in-cluster binaries name that file with a CLI flag:

```
prodbox <in-cluster service subcommand> --config <path-to-dhall-file>
```

For the pre-Vault role that surface is exactly:

```bash
prodbox bootstrap-broker start --config /etc/bootstrap-broker/config/config.dhall
```

Runtime role selection precedes decoding: the Bootstrap Broker decoder cannot accept Gateway
fields or silently open the binary-sibling host config. Its document is strict and secret-free;
unknown fields, a non-loopback listener, malformed identities/coordinates, unbounded queue/body/
deadline values, or duplicate fixed store keys refuse before the listener starts. `--dry-run` and
`--plan-file` are the universal plan renderers, not alternate config sources.

The host CLI takes no `--config` flag at all. It resolves its **binary-sibling**
`prodbox.dhall` automatically (the file beside the executable, `.build/prodbox.dhall`), so the
operator never names the path:

```bash
# The host CLI resolves the binary-sibling prodbox.dhall via the executable path
# (takeDirectory getExecutablePath </> "prodbox.dhall", i.e. .build/prodbox.dhall);
# there is no --config flag to pass.
prodbox dev check
```

Example in the cluster:

```yaml
# charts/gateway/templates/deployments.yaml
args:
  - --config
  - /etc/gateway/config/config.dhall
```

Forbidden alternatives:

- `--config-path` env-var fallback (any spelling of `PRODBOX_CONFIG_PATH`, `GATEWAY_CONFIG_PATH`, etc.).
- `--log-level`, `--port`, `--node-id`, `--foreground` and similar runtime-override flags. Every value the binary needs lives in the Dhall file.
- `prodbox-config.json` (or any other generated JSON projection of the Dhall) on a supported path. `prodbox config compile` is not a supported subcommand.
- Reading any other Dhall file silently (the binary never falls back to `~/.config/prodbox.dhall` or `/etc/prodbox/...` if `--config` is omitted; the canonical resolution is named below).

The single-file rule is about the binary's CLI surface, not about the content of that file:
the Dhall expression may, and frequently will, import sibling Dhall files via Dhall's native
import syntax (Section 5).

## 3. Canonical paths

| Binary instance | Canonical Dhall path | Resolution |
|---|---|---|
| Host CLI (`prodbox` on the operator host) | Tier-0 **binary-sibling** `prodbox.dhall` — the file beside the executable (`.build/prodbox.dhall`), not the repo root (GENERATED, self-contained non-secret binary context AND sealed-Vault bootstrap floor AND the operator seed config in its `parameters`). The standalone `./prodbox-config.dhall` seed file is RETIRED (Sprint `1.42`). | the binary reads the sibling `prodbox.dhall`, projects the basics via `projectBasics`, and decodes `( prodbox.dhall ).parameters` as the seed; before establishment it uses those parameters, and once established it resolves the exact Lifecycle Authority capability for in-force reads/proposals |
| In-cluster ephemeral CLI (`prodbox …` run inside the container) | Tier-0 **binary-sibling** `prodbox.dhall` (beside the in-container binary) | NO committed or COPY-ed container default. The image build, after installing the binary, **runs the binary** (`prodbox config generate`) to write the binary-sibling `prodbox.dhall`; same resolution as the host CLI (Sprint `1.49`) |
| In-cluster Bootstrap Broker | `/etc/bootstrap-broker/config/config.dhall` | distinct ConfigMap directory mount; carries only bounded pre-Vault coordinates and no gateway, lifecycle, provider, or target-secret authority |
| In-cluster Lifecycle Authority | `/etc/lifecycle-authority/config/config.dhall` | distinct ConfigMap directory mount; carries Lifecycle Authority identity/scope and `SecretRef` coordinates for its managed sessions, Model-B aggregate/blob store, provider worker, and outbox |
| In-cluster Authority Backup Adapter | `/etc/authority-backup/config/config.dhall` | home-only mount carrying exact Authority identity, S3 backup coordinate, and `secret/aws/authority-backup-store`; no provider/target/DNS coordinate |
| In-cluster TLS Retention Adapter | `/etc/tls-retention/config/config.dhall` | home-control-plane mount carrying exact registered TLS prefixes and `secret/aws/tls-retention-store`; no backup/provider/Transit/plaintext-TLS coordinate |
| In-cluster Provider Worker | `/etc/provider-worker/config/config.dhall` | home-only mount carrying exact provider binding and `secret/aws/lifecycle-provider`; no authority-writer or backup credential |
| One-shot Credential Provisioner | `/etc/credential-provisioner/config/config.dhall` | one active mode-indexed `GenesisBackupPermit`, `RepairPermit`, or `OperatorMaterialPermit` plus deterministic coordinates and Job attestation; the bounded first-reconcile session also binds the secret-free ordered action/coordinate/count/deadline plan digest and may receive only the next separately signed permit after the previous receipt, never batch authority; no prompt or persisted admin secret |
| One-shot Admin Action Runner | `/etc/admin-action-runner/config/config.dhall` | one backup-receipted permit for explicit SES destroy, legacy backend migration/retained-store compatibility, or quota request/status read-back; no normal provider/provisioning authority or prompt bytes in config |
| In-cluster Target Secret Agent | `/etc/target-secret-agent/config/config.dhall` | per-substrate mount carrying substrate attestation, fixed closed payload-schema/KV/receipt allowlist, one-shot secret-worker binding, and exact TLS Secret RBAC; home alone also carries payload-specific SMTP/EAB custody/rewrap and `prodbox-tls-envelope` Transit lanes, none of which is a generic export |
| In-cluster gateway daemon | `/etc/gateway/config/config.dhall` (Tier-0 `prodbox.dhall`, the `config.dhall` file inside the directory-mounted `/etc/gateway/config`) | the long-running daemon is configured by the chart-side `gateway-config-<nodeId>` ConfigMap mount (unchanged), independent of the build-time binary-sibling default; see [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) and [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) |
| In-cluster workload Pods (`api`, `websocket`) | `/etc/workload/config.dhall` | chart-side ConfigMap mount on the owning workload chart |

The Bootstrap Broker store block enumerates its fixed coordinates. In addition to storage
generation, fence, prepared envelope, encrypted response, final bundle, child custody receipt, and
child recovery delivery, it names exactly six disjoint progress keys: `root_init_journal_key`,
`root_session_journal_key`, `child_custody_journal_key`, `child_recovery_journal_key`,
`post_unseal_handoff_key`, and `secret_worker_checkpoint_key`. The runtime validates that all fixed
keys are distinct; no request or program can supply an object-store key.

The schema files `prodbox-config-types.dhall` and `test-secrets-types.dhall` are GENERATED and
git-ignored (one-time operator `git rm --cached` untracks them; Sprint `1.41`). There is no
committed container default — the in-container `prodbox.dhall` is generated by running the binary
(Sprint `1.49`). No instance-config or secret-fixture `.dhall` surface is version-controlled; the
four algebra schemas and one golden fixture enumerated in §0 are tracked by design.

The host CLI has no `--config` flag; it always resolves the binary-sibling path via
`takeDirectory getExecutablePath </> "prodbox.dhall"` via `resolveTier0ConfigPath`. Inside the cluster
the daemon deployment passes `--config <path>` explicitly so the resolution rule is trivial.

The self-contained Tier-0 `prodbox.dhall` (§0, §1a) is the non-secret binary context the host
reads locally and IS the sealed-Vault bootstrap floor; there is no separate JSON floor. Its
`parameters` field is the proposed-update Dhall input, not the in-force config. The former
standalone `prodbox-config.dhall` seed/propose file is retired (Sprint `1.42`, §0). The in-force config is the
Vault-Transit-enveloped MinIO object (Tier 2, Section 1a); a host that cannot reach an unsealed
Vault sees only the basics projected from `prodbox.dhall`, and supplying a Tier-0 update is a proposed
update reconciled into the encrypted source of truth. Sprint `1.38` landed the local foundations
and switched host settings consumers off the `loadConfigFile` live-config path once the basics
exist.

## 4. Decoding

Every binary decodes its Dhall in-process through the native Haskell `dhall` library:

```haskell
-- src/Prodbox/Settings.hs
loadConfigFile :: FilePath -> IO (Either String ConfigFile)
loadConfigFile repoRoot = do
  configPath <- resolveTier0ConfigPath repoRoot
  configExists <- doesFileExist configPath
  if not configExists
    then pure (Left (missingConfigMessage configPath))
    else do
      result <- try (inputFile auto configPath)
      pure $ case result of
        Left (e :: SomeException) -> Left ("Failed to decode Dhall config …: " ++ displayException e)
        Right config -> Right config
```

The host loader takes the **repository root**, resolves the executable-sibling Tier-0
`prodbox.dhall` path, guards existence with `doesFileExist`, and wraps the decode in `try` so a
missing or malformed config surfaces as a `Left String` rather than an exception. The in-cluster
binaries pass their mounted `--config` path straight to `Dhall.inputFile auto`.

There is no intermediate JSON projection on the supported path. `dhall-to-json` is not part
of the supported toolchain. The on-disk artifact is the typed, operator-authored Dhall
expression; the in-memory value is a Haskell record type produced by `Dhall.inputFile auto`.

Under GHC 9.12.4, `cabal.project` carries `allow-newer` clauses for the `dhall` library's
transitive dependencies so the pinned `dhall ^>=1.42` bound continues to build cleanly on
the newer GHC. The specific `allow-newer` set is owned by
[dependency_management.md](./dependency_management.md).

### What decoding does and does not validate

Decoding produces a well-typed record. It does not produce a validated one, and the distinction is
load-bearing enough to state plainly rather than leave to the reader.

`decodeProjectConfigDhall` is `Dhall.inputFile Dhall.auto` plus exactly one refusal: it returns the
raw Tier-0 record, and the callers that stamp the basics floor or feed the daemon consume that record
directly. The validating path is separate — `loadConfigFileAtPath` decodes the `parameters`
projection and `validateConfig` is the only builder of `ValidatedSettings`.

The one refusal is the secret-free guard (Sprint `1.82`). Tier 0 is non-secret by contract (§ 10),
and `tier0CarriesNoSecretValues` was exported and documented as the guard enforcing that — with zero
production call sites, so it enforced nothing. It is now the last step of this decode, and the
refusal names the dotted fields carrying a literal value without quoting the values themselves.

State its scope rather than its name, because the two differ. The operational `aws.*` arm was already
refused by `validateAwsCredentialsRef`, but only on the *validating* path — so the in-cluster daemon
binary context (`loadDaemonBinaryContext`) and the § 4 drift gate both reached a full Tier-0 record
with no such check, and `acme.eab_*` had no local-tier check on any path at all. Its enumerator is a
**positional** pattern over `ProdboxParameters` for the same reason `validateLocalConfig` is, so a
new section carrying a `SecretRef` is a compile error rather than a silent omission.

Two honest limits on that gate:

- **It is now total over the record (Sprint `1.81`).** `validateLocalConfig` used to be a flat list
  of named checks over field accessors. It never mentioned the record, so `-Wall` had nothing to
  warn about and a field added to the config type was skipped by construction — four sections
  (`ses`, `pulumi_state_backend`, `storage`, `components`) had in fact accumulated no coverage at
  all. It is now a **positional** constructor pattern, which makes a new field a compile error at
  the one place that must decide whether it needs checking.

  The positional form matters, and the reason was established by trying the alternative first: a
  *named* record pattern (`ConfigFile{ aws = a, … }`) is not a forcing function. It silently ignores
  fields it does not mention and GHC has no warning for it — adding a field produced an objection
  only at an unrelated *construction* site, never at the validator. Recording that here so the next
  reader does not repeat the experiment.

  What the four newly-covered sections check: SES identity fields when set, a `manual_pv_host_root`
  that cannot escape the root it is joined onto, a state-backend bucket and a key prefix that is
  safe to concatenate into object keys, and the component graph validated at decode rather than at
  bring-up. The bound this paragraph used to state — that a total fold says every field is *visited*,
  not that every field is *well-typed* — was true until Sprint `1.89` and is corrected below rather
  than left standing. The counts it carried ("~30 `Text` and ~40 `Natural`") were restatements and
  both were wrong; Sprint `1.88` measured 27 and 18.
- **The payload renderer used to be partial too, and no longer is (Sprint `1.79`).**
  `renderConfigDhall` was a hand-written field-by-field emitter that produced `Config::{…}` and
  never emitted `components`; Dhall record completion then refilled the field from the schema
  default, so an operator-authored component graph was silently replaced in the canonical in-force
  config while the Tier-0 *file* — rendered through `Dhall.inject`, and total — preserved it. Two
  renderers of one record disagreed about what the record contains. The payload is now derived
  through `Dhall.inject @ConfigFile`, so a field added to `ConfigFile` is emitted because the
  instance is generic rather than because someone remembered a line. Two consequences: the payload
  is self-contained and no longer imports `prodbox-config-types.dhall`, and
  `decodeConfigDhallBytes` therefore materializes that schema **best-effort** rather than requiring
  it — a payload written by the superseded renderer still carries the import and still decodes, and
  one that does not no longer fails on a generated file it never needed.
- **One field left the raw-`Text` set entirely (Sprint `1.80`).**
  `deployment.public_edge_advertisement_mode` was a two-value enum (`l2` / `bgp`) carried as
  `Optional Text` and decided by string comparison in `validatePublicEdgeDeployment`, in the same
  record that already carries eight properly-unioned scaling policies plus `WorkerSubstrate`,
  `ClusterTopology`, and `ComponentId` as real Dhall unions. It is now
  `Optional < AdvertiseLayer2 | AdvertiseBgp >` in the generated schema, so a misspelling fails the
  Dhall type check and never reaches Ring 2 — the rejection moved out of Haskell and into Ring 1,
  which is the only field on this surface where that was possible. The `bgp ⇒ at least one peer`
  rule deliberately stays in Haskell: it is a cross-field invariant and Dhall's `assert` operates on
  closed terms, so it cannot reach an authored value. `prodbox-config-types.dhall` still contains
  zero asserts. **Operator consequence**: a sibling `prodbox.dhall` authored under the previous
  schema carries `Some "l2"` and no longer decodes; regenerate it with `prodbox config generate`.

  **Repository consequence, recorded 2026-08-08 (Standard C).** This entry originally stopped at the
  operator consequence, and that omission was the expensive half. The same tightening also invalidated
  every *test fixture* that hand-authored the field — `None Text` does not type-check against
  `Optional < AdvertiseLayer2 | AdvertiseBgp >` — and there were **four** hand-written Tier-0
  encoders in the tree, of which one was updated. Twenty integration cases broke; because the fixture
  authority server converted the resulting decode failure into an exception and then into a bare
  socket close, the reported symptom was `NoResponseDataReceived` — a transport error naming nothing.
  The suite was not compiled by `prodbox dev check` at the time (see
  [resource_scaling_doctrine.md § 2C](./resource_scaling_doctrine.md), "The region of Ring 2"), so
  nothing caught it; Sprint `5.30` has since added `--enable-tests` to that build. The general rule is
  [chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md): a typed value crossing out of a
  region must be reconstructed by exactly one derived encoder, and here there were four. Tightening a
  type does not update a second encoder; it only makes it wrong.
- **`ValidatedSettings` carries the raw record, and now also carries the parses taken over it
  (Sprint `1.89`).** It has three proofs rather than one: the opaque `AllocatedResourcePlan`
  (§ 2C Ring 2 of [resource_scaling_doctrine.md](./resource_scaling_doctrine.md)), which cannot be
  constructed without the capacity compile succeeding; `ValidatedPublicEdge` (Sprint `1.83`); and
  `ValidatedCoordinates`, which holds every Tier-0 coordinate as the type its decision established —
  `AwsRegion`, `Route53ZoneId`, `S3BucketName`, `DnsLabel`, `DnsTtl`, `IpLiteral`, `EmailAddress`,
  `AcmeDirectoryUrl`, `SafeRelativePath`, all built only through the smart constructors in
  `Prodbox.Settings.Coordinate`. `validateConfig` is the sole minter, and
  `checkTier0CoordinateReads` fails `prodbox dev check` for any `src/` module that reaches a
  registered coordinate through a `ValidatedSettings` rather than through the projection.

  Before Sprint `1.89` this paragraph read "every other field rides along as the `Text` / `Natural` /
  `List` it decoded as, and is re-read raw at the point of use". That was accurate and is no longer,
  so it is corrected here rather than left to be quietly outgrown.

  **Three bounds, because the guarantee is narrower than "validated" suggests.** First, these are
  *shape* rules: an `AwsRegion` is a well-formed region name, not a region this account can reach.
  Shape is what config validation can decide without a network. Second, the gate is a compiled rule
  over a source region, not a property of the type — a module that passed a *section* to a helper
  would escape it. Third, the narrowing happens one ring in from the authored file: Dhall has no
  refinement types, so `route53.zone_id` is still `Text` on the wire, and retyping it there would
  change every generated `prodbox.dhall` — a Standard-P generated-config identity change. The wire
  format is deliberately untouched.

  What remains raw is the rest of the record: the capacity profile identifiers, the component graph's
  interior, and the fields no coordinate rule applies to. So "validated settings" now means *the
  capacity plan is proven, the public edge is parsed, and every registered coordinate is the type its
  rule established* — not *every field is known good*.

Neither limit is a reason to distrust the config in normal operation — the generator emits sound
values. Both are reasons not to read "decoded" or "validated" as "illegal states are
unrepresentable". Dhall is Ring 1, and Ring 1 was never where that guarantee is delivered.

There is a third limit, and it is the one that has actually bitten: **Ring 2 delivers its guarantee
only over the modules the gate compiles, and only up to the point where a value is written back out
as text.** A config record that is unrepresentable-when-illegal inside `src/` is an ordinary string
the moment some other encoder writes it, and a decode failure is an ordinary exception the moment
someone throws it. See "The region of Ring 2" in
[resource_scaling_doctrine.md § 2C](./resource_scaling_doctrine.md) and
[chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md).

### Drift between the sibling file and the generator (Sprint `0.24`)

There is one canonical writer of the binary-sibling `prodbox.dhall`: `renderProjectConfigDhall`.
`config generate`, `config setup`, the `vault init` floor stamp, the self-heal reconstruction, and
the test harness all reach the disk through it. `prodbox dev check` therefore holds the file to that
writer's output — it decodes the sibling record and compares the canonical re-rendering against the
bytes on disk, reporting the differing field rather than a whole-file diff. An **absent** file is
silent (a fresh worktree has none until `config generate` runs); a **malformed** file is a finding
distinct from a drifted one, because an undecodable file has no record to re-render.

What that gate does and does not close, stated with the same care as the two limits above:

- It closes **representational** drift: a hand edit that changes the emitted text, a file left
  behind by an older schema (the record gains a field, the old file still decodes by record
  completion, and the re-render disagrees), and — the sharp case — a hand-edited resource plan that
  leaves the emitted `concurrentDraws` list stale. That list is the Ring-1 `assert`'s own input, so
  before this gate a hand-edited plan left Ring 1 quietly proving the fit of draws the plan no
  longer implies.
- It did **not** close a hand edit to a primitive that round-trips unchanged — a re-typed
  `route53.zone_id` or `acme.server` decodes to that value and re-renders to that value, so the
  edited file *is* the generator's output for the record it carries. No text comparison can
  separate the two.

### The generator-stamped witness (Sprint `0.29`)

That class is closed by making the file carry a value its own content determines.
`renderProjectConfigDhall` stamps `witness = [ "prodbox-tier0-witness-v1:<sha256>" ]`, the digest
taken over the canonical Dhall rendering of `parameters` and `context`.

**The digest excludes `witness` itself**, which is forced rather than chosen: a witness over a record
containing itself has no fixed point. It also makes stamping idempotent.

**No new gate was added.** The § 4 comparison above now catches the class on its own: after a hand
edit the file holds the *old* witness beside the *new* primitive; the gate re-renders the decoded
record, stamps a witness computed from the edited content, and the two disagree, so the comparison
reports the differing field as `witness`. The right fix was a field that cannot be edited
consistently by hand, not a second check.

**Two consequences, stated rather than implied.**

- This changes the content of every generated `prodbox.dhall`, so it is a Standard-P
  generated-config-identity change. A qualification run must bind the post-`0.29` identity and may
  not carry forward one recorded before it.
- An operator who edits a primitive *and* recomputes the witness defeats it, as they would defeat any
  in-file stamp. What is removed is the *silent* edit — the one leaving a self-consistent file and no
  evidence — not the deliberate one. Closing that needs a signature over a key the file does not
  carry.

The round-trip property is correspondingly restated: `decode ∘ render` is `stampTier0Witness`, not
`id`. Outside the witness field it remains identity, and the unit cases assert both halves.

## 5. Dhall imports

The Dhall expression at the `--config` path is free to compose itself from sibling files
using Dhall's native import system. It imports only non-secret parts — types, cluster topology,
and role-scoped capability coordinates — never another role's secret reference:

```dhall
-- /etc/gateway/config/config.dhall (rendered into the gateway-config-<nodeId> ConfigMap)
let types  = ./types.dhall
let orders = ./orders.dhall                          -- separate ConfigMap mount
in  types.BootConfig::{ node_id   = "node-a"
                      , orders    = orders
                      -- home only: exact non-secret Gateway-DNS capability coordinate;
                      -- EKS renders this field absent
                      , dns_capability = Some types.GatewayDnsCoordinate::{ … }
                      , …
                      }
```

**Historical pre-cutover shape.** The current `BootConfig` still carries shared Route 53 AWS and
MinIO-root `SecretRef.Vault` fields. They are active compatibility fields, not the target example:
Gateway MinIO/object-store access and the shared `aws.*` coordinate are deleted at authority-epoch
cutover. The target Gateway projection contains mesh/journal configuration and, on home only, the
exact Gateway-DNS coordinate; credentials are acquired by its boundary-owned role session and are
never copied into another role's projection.

The binary reads one file. That file imports the parts that have independent lifecycles —
Orders (cluster topology, monotonically versioned per Sprint 2.7) and the operator-authored
bootstrap fragment (rotated only when the operator edits the repo). The single-file rule is
preserved at the CLI surface; the on-disk layout follows the data lifecycles.

There are **no `as Text` credential imports and no Secret-mounted Dhall credential fragments.**
Sensitive fields carry `SecretRef.Vault` / `SecretRef.TransitKey` references; the value is
fetched at runtime by the in-cluster consumer authenticating to Vault directly via Vault
Kubernetes auth. The Dhall typechecker never sees a literal secret because there is no literal
secret in the config tree — only a reference to a Vault object. See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and Section 6.2.
The `SecretRef` type/resolver foundation has landed under Sprint 1.35, and the chart
Vault policy/role/service-account, Kubernetes-auth config, and generated/static seed-bootstrap
foundation is active under Sprint 3.18. The `websocket` workload config now carries
`oidc.client_secret` as `SecretRef.Vault` and resolves it through Vault Kubernetes auth at runtime;
the Keycloak and MinIO charts materialize their covered runtime fields through Vault-login init
containers, and MinIO admin bootstrap Jobs read root credentials through the same init-container
pattern. The VS Code Envoy `SecurityPolicy` client Secret is materialized from Vault by a chart
Job, and gateway event keys plus the pre-cutover shared Route 53 AWS credentials currently resolve
through Vault Kubernetes auth. The gateway MinIO/AWS fields are historical implementation fields
retained only for the plan-owned lifecycle-control-plane cutover. Patroni role Secrets are materialized from Vault by the `keycloak-postgres`
pre-install hook. Host/admin helpers and the AWS SES SMTP setup flow now read/write their remaining
Keycloak admin, OIDC, demo-user, and SMTP material through Vault KV. The Sprint 3.18 sealed-startup
foundation and Sprint 3.19 legacy derivation/RPC removal are historical milestones; current
implementation and qualification status live only in the Development Plan.

## 6. Cluster mount contract

Every long-running control-plane process receives its own generated non-secret ConfigMap directory
mount. Service identity, authority scope, substrate binding, and `SecretRef` coordinates are
validated together; a shared image default or component label cannot substitute for that identity.
Target-secret attestation belongs to the Target Secret Agent config, not the Gateway Runtime
config. The kubelet's atomic `..data` symlink swap drives fsnotify reload (§7).

| Process | Config mount | Authority-bearing config boundary |
|---|---|---|
| Bootstrap Broker | `/etc/bootstrap-broker/config` | bounded pre-Vault request surface, one loopback listener, fixed custody/fence coordinates, and the six disjoint journal/checkpoint keys only; no secret or generic store path |
| Lifecycle Authority | `/etc/lifecycle-authority/config` | authority identity/epoch scope, aggregate/blob store, provider-worker and outbox coordinates |
| Authority Backup Adapter | `/etc/authority-backup/config` | exact authority binding, S3 backup coordinate, and sole backup-store SecretRef |
| TLS Retention Adapter | `/etc/tls-retention/config` | exact Authority binding, registered TLS prefixes, and sole TLS-retention-store SecretRef; ciphertext only |
| Provider Worker | `/etc/provider-worker/config` | exact authority/provider binding and sole Lifecycle-provider SecretRef |
| Credential Provisioner | `/etc/credential-provisioner/config` | one active mode-indexed signed permit, deterministic identity/store coordinates, and Job attestation; first-reconcile permit succession is authenticated and receipt-ordered, while prompt input remains separate linear memory-only ingress |
| Admin Action Runner | `/etc/admin-action-runner/config` | one closed admin-action permit and exact registered coordinates; prompt input is separate linear memory-only ingress |
| Target Secret Agent | `/etc/target-secret-agent/config` | one substrate identity, Vault/one-shot-worker roles, fixed KV allowlist/closed payload schemas, and exact TLS Secret lanes; home alone has payload-specific SMTP/EAB custody/rewrap plus TLS-envelope Transit lanes, never generic export authority |
| Gateway Runtime | `/etc/gateway/config` | Orders/peer/DNS config, journal-volume identity and renewable journal-key `SecretRef` only |

The Broker command and strict decoder enforce this role split code-locally. Completed Sprint `3.26`
supplied the ConfigMap/identity/chart rendering foundation, but the physical TokenReview, MinIO,
Vault, and OpenPGP adapters are not the active production selection. This mount contract does not
assert deployment qualification or operational cutover; those remain plan-tracked.

The Helm materialization layout is owned by
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md). The Gateway Runtime's
directory is materialized as follows:

| Mount source | Mount path | Content |
|---|---|---|
| `gateway-config-<nodeId>` ConfigMap | `/etc/gateway/config` (directory mount; the daemon reads `config.dhall` and its `prodbox.dhall` sibling) | substrate-specific non-secret daemon-frame Tier-0 document plus the per-node runtime Dhall expression; the latter imports `orders.dhall` and carries only gateway-owned `SecretRef.Vault` references and coordinates |
| `gateway-orders` ConfigMap | `/etc/gateway/orders.dhall` | cluster-wide ranked-node + timing Dhall expression |
| `gateway-<nodeId>-tls` Secret | `/tls/` | cert-manager-issued per-node TLS keypair; referenced by file path from the Dhall config |
| Cert-manager CA Secret | `/ca/` | trust anchor for peer mTLS; referenced by file path from the Dhall config |

The chart materializes **no credential as a Dhall fragment**. There are no
`gateway-secrets-aws` / `gateway-secrets-minio` Secret-mounted Dhall fragments — those mounts
are removed. Credentials are `SecretRef.Vault` references in the ConfigMap-rendered Dhall, and
the daemon resolves them at runtime by authenticating to Vault via Vault Kubernetes auth: a
Kubernetes service account, a Vault role bound to the daemon's namespace and service account,
and a Vault policy scoping which KV paths it may read. See
[vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth) and
[helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md). The Sprint 3.18
foundation now provisions Vault roles, service accounts, Kubernetes-auth config, and
generated/static seed KV objects for this model, and the websocket workload now resolves its OIDC
client secret through that SecretRef path; Keycloak and MinIO materialize their covered runtime
fields through Vault-login init containers, and MinIO admin bootstrap Jobs read root credentials
through the same init-container pattern. The VS Code Envoy `SecurityPolicy` client Secret is
materialized from Vault by a chart Job, and gateway event/Route 53 credentials are resolved from
Vault by the daemon. **Historical implementation record (removed cutover surface):** Sprint `2.26`
used the same non-secret gateway Vault Kubernetes-auth coordinates for
`/v1/federation/children` and `/v1/federation/children/<child>/bootstrap`; Sprint `4.50` deleted both
routes and their client/daemon handlers. Current federation state is operation-bound to the
Lifecycle Authority and Target Secret Agent, not readable through Gateway Runtime. Patroni role
Secrets are materialized from Vault by a chart hook. The
sealed-startup and legacy-derivation removal statements above are historical implementation
records; current status lives only in the Development Plan. The
operator-facing `gateway-config-<nodeId>` ConfigMap therefore contains no
secret material — only the non-secret substrate-specific Tier-0 document, `SecretRef` references,
and non-secret service endpoints rendered inline. The cert-manager-issued TLS keypair and CA trust
anchor remain ordinary k8s Secret mounts referenced by file path; they are cert material under
Vault's PKI authority, not Dhall credential fragments.

### Non-secret service-endpoint fields

An endpoint is non-secret, but it is still authority-sensitive. Target config validates service
identity, authority scope, and operation coordinate together and resolves them to one opaque
operation-indexed `CapabilityRef`; it cannot accept one endpoint for a readiness probe and another
for execution. Lifecycle Authority owns the primary MinIO/Model-B reference; Backup Adapter owns
only the S3 Authority-ciphertext-copy endpoint; TLS Retention Adapter owns only exact TLS-ciphertext
prefix operations; Provider Worker owns only normal provider execution. Bootstrap Broker owns its
bounded bootstrap-store endpoint. Target Secret Agent owns its substrate-local Vault/Secret lanes,
with a distinct home-only TLS-envelope Transit lane. Credential Provisioner and Admin Action Runner
receive permit-bound Job bindings, not reusable service endpoints. Gateway Runtime has no MinIO,
lifecycle, backup, TLS-retention, or target-Vault endpoint.

**Historical implementation record (legacy cutover surface).** The current gateway config carries:

| Field | Type | Source | Canonical value |
|---|---|---|---|
| `boot.minio_endpoint_url` | `Optional Text` | rendered inline by `gateway-config-<nodeId>` ConfigMap from chart value `minio.endpointUrl` | `http://minio.prodbox.svc.cluster.local:9000` on the home substrate |

The daemon decoder (`Prodbox.Gateway.Settings.DaemonBootDhall.minio_endpoint_url`) treats
the field as `Optional Text` so chart-only smoke installs without a live MinIO can still
decode the config; the MinIO-backed config fetch falls back to `127.0.0.1:9000` and fails
closed — serving the documented unavailable response — when the field is `None` and MinIO (or
the Vault unseal the decrypt depends on) is unreachable. The MinIO objects are
Vault-Transit-enveloped, so a sealed Vault leaves the daemon with opaque ciphertext regardless
of MinIO reachability; see Section 1a and
[vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store). This field is removed
from Gateway Runtime after Lifecycle Authority and Bootstrap Broker cutover.

ConfigMap and Secret volume updates land in the Pod via the kubelet's atomic `..data`
symlink swap. The file-watch reload trigger (Section 7) follows that symlink swap rather
than the leaf-file `mtime`.

## 6.1 ACME issuer config fields

The `acme` config block carries the ACME-issuance inputs consumed by cert-manager
`ClusterIssuer` rendering. It is decoded into `AcmeSection` in
`src/Prodbox/Settings.hs`, declared in `prodbox-config-types.dhall`, and given its default
in the Tier-0 `prodbox.dhall` parameters:

| Field | Type | Purpose |
|---|---|---|
| `acme.email` | `Text` | expiry-notice email; required and non-empty |
| `acme.server` | `Text` | ZeroSSL ACME directory URL rendered into the `ClusterIssuer` |
| `acme.eab_key_id` | `Optional SecretRef` | EAB key ID (required for ZeroSSL); `SecretRef.Vault` into `secret/acme/eab#key_id` |
| `acme.eab_hmac_key` | `Optional SecretRef` | EAB HMAC key (required for ZeroSSL); `SecretRef.Vault` into `secret/acme/eab#hmac_key` |

`acme.server` is a non-empty ACME directory `Text` that defaults to the ZeroSSL directory
`https://acme.zerossl.com/v2/DV90` and feeds the single `ClusterIssuer` (`zerossl-dns01`).
ZeroSSL is the only supported ACME provider, so `acme.eab_key_id` / `acme.eab_hmac_key` are
required and `validateAcmeBinding` rejects a ZeroSSL `acme.server` with either EAB field
missing. The single-issuer model — one `ClusterIssuer` with a DNS-01 Route 53 solver plus the
S3-backed retain-and-restore of the issued certificate so rebuilds do not re-order it — is
owned by [acme_provider_guide.md](./acme_provider_guide.md) and
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md).

**Sprint 7.15 (landed):** `acme.eab_key_id` / `acme.eab_hmac_key` are `Optional SecretRef`
references into the `secret/acme/eab` Vault KV object (fields `key_id` / `hmac_key`), not
plaintext `Optional Text`. `validateAcmeBinding` rejects a plaintext (non-`Vault`) EAB reference
through the same `validateVaultRef` discipline used for `aws.*` (the rejection reads
`acme.eab_* must be a SecretRef.Vault reference`), so `prodbox config validate` fails fast on any
plaintext EAB value. In that pre-cutover path the non-secret key ID was resolved host-side and
rendered inline, while the HMAC key was materialized by a Vault-login Job. The final design removes
the host Vault read: after target generation read-back, the selected Agent returns a typed
generation-bound key-ID projection to the issuer renderer; the HMAC remains in-cluster. The field
names and required-for-ZeroSSL semantics are unchanged. The final design also keeps `config setup`
Tier-0-only: a separately schema-indexed external linear ingress under its own
`OperatorMaterialPermit` supplies closed `AcmeEabSource` to the retained-home Agent's
payload-specific Transit custody. Attested one-shot home/selected workers restore the exact target
generation without operator re-entry; Authority sees ciphertext/typed receipts only, and no direct
host Vault read/write or generic export path exists. See
[vault_doctrine.md §11](./vault_doctrine.md#11-tls-and-pki-under-vault) and
[acme_provider_guide.md](./acme_provider_guide.md).

## 6.2 SecretRef: typed secret references

Sensitive config fields carry a typed `SecretRef` value, never a plaintext secret. The Dhall
union is `< Vault | TransitKey | Prompt | TestPlaintext >`; the corresponding Haskell ADT is
`Prodbox.Settings.SecretRef`. There is **no `FileSecret` arm** — the `SecretRefFile`
constructor and its resolver are removed, and there are no Secret-mounted Dhall credential
fragments. `Vault` / `TransitKey` are the production targets, `Prompt` is CLI-only one-off
elevated material, and `TestPlaintext` is accepted only by the test harness from
`test-secrets.dhall`. The ADT, Dhall decoder, production plaintext validator, and Vault KV reader
seam (`resolveSecretRefWithVault` / `resolveSecretRefFromVault`) are implemented under Sprint
1.35; migrating the sensitive repo config fields onto that contract is scheduled under Sprint
1.38.

`Prompt` names an interaction purpose; its bytes are not part of the decoded Dhall value or any
serializable capability program. For Credential Provisioner, Admin Action Runner, and post-export
decommission, raw bytes arrive only after permit and Job attestation over a separate linear ingress,
remain bounded in memory, and are discarded. Config and Authority records may carry only opaque
Agent/Vault keyed-HMAC commitment references for equality recovery, never raw plaintext or
credential hashes.

- `prodbox config validate` rejects any plaintext secret value in production config and rejects
  `TestPlaintext` outside the test harness.
- Production config and test plaintext are split: `prodbox.dhall` holds references only,
  while `test-secrets.dhall` holds plaintext used solely by the test harness — including the
  `aws_admin_for_test_simulation.*` elevated-credential simulation — never imported by
  `prodbox.dhall` and never in Vault. See
  [vault_doctrine.md §4](./vault_doctrine.md#4-config-split-production-references-vs-test-plaintext).

This is the SSoT-deferring summary; [vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model)
owns the full SecretRef model and is the single source of truth for it.

## 7. File-watch reload trigger

Every long-running `prodbox` binary instance watches the file at its `--config` path for
changes via filesystem-watch primitives (the gateway daemon does so today; the workload Pods
are the scheduled target — see below). Concretely the supported watcher is `fsnotify` on
Linux (with `hinotify` as an acceptable equivalent inside the canonical Docker image); the
chosen library is named by the implementing sprint. The watch loop subscribes to events on
the parent directory so the `..data` symlink swap performed by the kubelet on ConfigMap or
Secret updates triggers a reload.

SIGHUP is no longer a supported reload trigger. The signal handler that previously fed the
reload queue is removed; the watcher feeds the same `TBQueue ()` reload-worker that the
existing implementation drains. The downstream STM broadcast channel that publishes
LiveConfig changes to subscribers is unchanged.

The gateway daemon and the workload Pods both implement this fsnotify-driven Boot/Live reload loop.
Sprint `3.15` (landed 2026-06-09) gave `Prodbox.Workload` the same daemon-style fsnotify watcher
(`configFileWatchLoop` / `reloadLoop` / `drainCoordinator`) plus the `WorkloadBootConfig` /
`WorkloadLiveConfig` split, so a `mode`/port change drains and exits while a `log_level`/Redis/OIDC
change reloads in place — the workload Pods watch their config file today.

This explicitly overrides the prior prohibition on `fsnotify`, `inotify`, and `mtime` as
reload triggers. The custom `forbidFsnotify` / `forbidInotify` / `forbid-mtime-polling` rules
in `src/Prodbox/CheckCode.hs` have been removed, and both the daemon and — since Sprint `3.15` —
the workload paths use the file-watch primitives. See
[code_quality.md](./code_quality.md), the lint-stack SSoT for the current state of these rules.
The legacy ledger records the CheckCode-rule removal.

## 8. Boot-vs-Live split and the restart contract

The BootConfig / LiveConfig record-level split survives. `BootConfig` carries fields that
the daemon binds once at startup and cannot meaningfully change without rebinding the
process (listener sockets, peer-transport handles, identity, cert/key paths, Orders).
`LiveConfig` carries fields the daemon can swap at runtime (log level, timing knobs, drain
deadline, max clock skew).

When the watch loop detects a change at `--config`:

1. The reload worker re-decodes the Dhall via `Dhall.inputFile auto`.
2. If decode fails, the daemon logs `config_reload_decode_failed` and keeps the previous
   in-memory config. Live traffic is unaffected.
3. If decode succeeds and only LiveConfig fields differ from the running config, the worker
   atomically swaps `envLiveConfig` via STM and publishes the change on the existing
   broadcast channel. Subscribers (log-level, timing) refresh in place. No drain, no restart.
4. If decode succeeds and any BootConfig field differs from the running config, the worker
   logs `config_reload_boot_change_detected`, calls the existing drain machinery
   (`liveDrainDeadlineSeconds` default 30s), and exits with `ExitSuccess`. The kubelet
   restarts the Pod, which decodes the new Dhall fresh at startup. This is the supported
   path for promotion of new ranked nodes, new listener ports, cert/key rotation, and any
   other boot-field change.

The "restart" semantics live in k8s, not in the daemon itself. The daemon never
self-respawns; it only ever drains and exits. Pod-level restart-on-exit is the kubelet's
job, not the binary's.

## 9. Host CLI

The host CLI applies the same contract with two simplifications: it has no `--config` flag
(it resolves the binary-sibling `prodbox.dhall`, §1–§3), and the host binary is not
long-running, so file watching is unnecessary. `prodbox` resolves the executable-sibling path, then
reads the binary-sibling `prodbox.dhall` `parameters` as first-bring-up seed input when unencrypted
basics are absent. Once established, it resolves the operation-indexed Lifecycle Authority
capability and uses that same reference for observation, admission, and the in-force read or
proposal. There is no env-var precedence ladder on the host; the on-disk file is only a
seed/propose Dhall surface, never the live SSoT after basics exist. Lifecycle reconcile validates
the file only for the RKE2/MinIO/Vault/Bootstrap-Broker steps that precede authority availability,
then obtains settings through Lifecycle Authority before secret-dependent chart and edge work.

The on-disk file is the seed/propose input, not the in-force config. Supplying a file is a proposed
update, and a write to the root cluster's in-force config requires a short-lived config-admin proof
plus expected-generation CAS inside the durable authority operation. **Historical direct-loader implementation record:** the local
decoding/fetch/store foundations landed in Sprint
`1.38`; the global host-loader flip now lands there too. Without basics, `loadConfigFile`
remains only the first-bring-up seed path.

The host case is the existing baseline (Sprint 1.2). Sprint `3.15` (landed 2026-06-09) deleted the
former `Prodbox.Workload` `PRODBOX_*` precedence ladder (`PRODBOX_WORKLOAD_MODE`, `PRODBOX_PORT`,
`PRODBOX_LOG_LEVEL`, `PRODBOX_REDIS_*`, `PRODBOX_OIDC_*`) and moved the workload to the
config-as-data Dhall surface; `Workload.hs` is now in `checkEnvVarConfigReads.scopedPaths`, so a
reintroduced `PRODBOX_*` config read fails `prodbox dev check`. No supported binary sources
configuration from an env var. See §10.

## 10. Forbidden surfaces

The following surfaces are the **target** forbidden set — the structure the supported path is
moving to. Where a surface is named "scheduled" below, the code has not finished the move yet,
so the prohibition is the intended end state rather than a present-tense fact:

- Reading configuration from environment variables in any binary code path. `lookupEnv`,
  `getEnv`, and `getEnvironment` from `System.Environment` are linted out of the supported
  config-loading paths. Sprint `3.15` (landed 2026-06-09) deleted the former `Prodbox.Workload`
  `PRODBOX_*` precedence ladder (mode, port, log level, Redis host/port, OIDC fields) and added
  `Workload.hs` to the env-var-read lint scope (`checkEnvVarConfigReads.scopedPaths`), so no
  supported binary sources configuration from an env var. The k8s Pod environment may still carry
  runtime metadata (Pod name, namespace) that the binary does not read; the lint rule is scoped to
  the config-loading paths. The narrow, sanctioned exception is the documented **test-only** hook
  class — environment variables prefixed `PRODBOX_TEST_*` (and `PRODBOX_ALLOW_NON_TTY_INTERACTIVE`).
  These are read once, in memory, outside the config-loading lint scope; they never participate in
  config resolution and are never set by any production path. Readiness has no test-only
  environment bypass: the legacy fixture earns its authority latch through the fake continuity
  interpreter, while the target journal/Lease fixture must acquire its real temporary journal lock,
  read back its fake Lease witness, and finish recovery before `/readyz` can succeed.
- Materializing `prodbox-config.json` (or any other JSON projection of the Dhall) on a
  supported path. `prodbox config compile` is not a supported subcommand.
- `--log-level`, `--port`, `--node-id`, `--foreground`, `--config-path`, and any other
  runtime-override CLI flag that fronts a non-`--config` config source. `--config` is the
  sole startup-time CLI knob.
- `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT`, `PRODBOX_WORKLOAD_MODE`, and
  any other `PRODBOX_*` env-var precedence rule. Neither the host CLI nor the workload carries any
  of these; the workload's former `PRODBOX_*` ladder was retired by Sprint `3.15` (see §9 and the
  first bullet above).
- `MINIO_ENDPOINT_URL` env var on any control-plane Pod (the attempted gateway addition rolled back
  May 24, 2026). Bootstrap Broker and Lifecycle Authority receive their validated store coordinates
  through their own mounted config; Gateway Runtime receives none in the target topology. The
  historical gateway `boot.minio_endpoint_url` field is a legacy cutover surface; see §6
  "Non-secret service-endpoint fields".
- Host-side post-bootstrap MinIO port-forwarding and direct host Vault NodePort access. After the
  owning services exist, supported bootstrap, lifecycle/Model-B, provider, and target-secret
  operations route through their exact operation-indexed `CapabilityRef`. Surviving gateway proxy
  routes and host transports are legacy/config/test implementation residue tracked in
  [DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).
- A separately supplied probe/readiness endpoint for a capability execution reference. The
  component graph carries pure operation/service/scope requirements; reconnaissance yields one
  opaque `CapabilityRef kind`, and observation, admission, and execution all use it. A component
  label, reachable socket, nominal backend name, or healthy unrelated route is not capability
  evidence.
- SIGHUP-driven reload. The signal handler is removed; SIGHUP becomes a process-level
  terminate signal again with the supported behavior `drain + exit`.
- ConfigMap-rendered credentials, and Secret-mounted Dhall credential fragments (any
  `as Text` credential import, any `gateway-secrets-*` Dhall Secret). Credentials are
  `SecretRef.Vault` references resolved at runtime through Vault Kubernetes auth, not mounted
  Dhall values (foundation active under Sprint 3.18; websocket OIDC SecretRef consumer landed;
  Keycloak and MinIO Vault-init consumers landed; the VS Code Envoy `SecurityPolicy` client Secret
  is Vault-materialized by a chart Job; gateway event/AWS Vault consumption landed, while gateway
  MinIO consumption is a historical cutover surface; Patroni
  role Secret materialization landed; host/admin helper and AWS SES SMTP Vault reads/writes landed;
  sealed-startup and Sprint 3.19 legacy derivation/RPC removal are historical milestones; see §5,
  §6, and [vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth)).
- Plaintext secret values in `prodbox.dhall` or in ConfigMap-rendered Dhall. Sensitive
  fields carry `SecretRef` references instead. The FileSecret-free `SecretRef` contract is Sprint
  `1.35`; AWS provider credential migration is Sprint `7.14`; ACME EAB migration is Sprint `7.15`
  (see §6.2 and [vault_doctrine.md §3](./vault_doctrine.md#3-the-secretref-model)).
- Any secret value in the Tier-0 non-secret binary context (§0). The Tier-0 `prodbox.dhall` (which
  IS the sealed-Vault bootstrap floor) carries
  parameters, context, witness, and `SecretRef.Vault` POINTERS only — never inline secret material.
  Bootstrap secrets are Tier 1 (password-gated MinIO bundle); operational secrets are Tier 2
  (Vault-gated, Vault-Transit-enveloped MinIO objects). A secret value appearing in any Tier-0
  surface is a doctrine violation.
- A separate JSON bootstrap floor. `prodbox-basics.json` and the legacy
  `.data/prodbox/unencrypted-basics.json` are ELIMINATED; the sealed-Vault floor is read directly
  from the self-contained Tier-0 `prodbox.dhall` via `projectBasics` (Sprint `1.41`; see §0 and §1a).
- A version-controlled **instance-config or secret-fixture** `.dhall` surface. The binary-sibling
  `prodbox.dhall`, generated `*-types.dhall` schemas, and `test-secrets.dhall` are git-ignored. The
  four algebra schemas and one golden fixture enumerated in §0 are deliberate tracked artifacts,
  not configuration instances. There is no committed container default `.dhall` — the in-container
  `prodbox.dhall` is generated by running the binary.
- Treating any Tier-0 surface as the in-force config SSoT. Tier 0 is a **read-only, non-secret
  bootstrap input**: the host reads `prodbox.dhall` locally to reach and unseal Vault, and its
  `parameters` propose updates. The in-force config SSoT is the Lifecycle Authority aggregate's
  generation/digest/reference; it selects one immutable Tier-2 Vault-Transit-enveloped MinIO blob.
  A blob alone is never current, and no on-disk or ConfigMap-mounted Dhall file is authoritative
  (the historical storage inversion began in Sprints `1.38` / `1.42`; see §0 and §1a).

## 11. Cross-references

- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) — the
  operation-indexed capability references and separate Bootstrap Broker, Lifecycle Authority,
  Provider Worker, Backup/TLS Adapters, Target Secret Agent, one-shot Credential Provisioner/Admin
  Action Runner, and Gateway Runtime config identities.
- [cli_command_surface.md](./cli_command_surface.md) — CLI flag inventory; defers
  startup-config sourcing rules to this doctrine.
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — daemon
  lifecycle; defers config-source and reload-trigger rules to this doctrine.
- [dependency_management.md](./dependency_management.md) — `dhall` library pin and
  `allow-newer` clauses under GHC 9.12.4.
- [haskell_code_guide.md](./haskell_code_guide.md) — forbidden subprocess and env-var-read
  primitives.
- [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) — ConfigMap and
  Secret mount layout for the cluster Dhall surface.
- [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) — the secret inventory
  mapping each secret to its Vault KV / PKI / Transit path (the HMAC master-seed derivation
  model is retired; secrets are Vault objects).
- [vault_doctrine.md](./vault_doctrine.md) — the finalized Vault-root model: the `SecretRef`
  contract, the production references vs. `test-secrets.dhall` plaintext split, MinIO as a
  ciphertext store, and in-cluster Vault Kubernetes auth.
- [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) — the root/child trust
  tree, transit-seal auto-unseal, parent custody of child recovery material, and the
  generation-CAS config-write authority that governs §1a.
- [unit_testing_policy.md](./unit_testing_policy.md) — file-watch reload test stanza.
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — sprint status and
  adoption schedule for this doctrine.
- [../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
  — removal ledger for the superseded JSON / env-var / SIGHUP surfaces.
