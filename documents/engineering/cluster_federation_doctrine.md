# Cluster Federation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [vault_doctrine.md](./vault_doctrine.md),
[config_doctrine.md](./config_doctrine.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md),
[cluster_topology_doctrine.md](./cluster_topology_doctrine.md)
**Generated sections**: none

> **Purpose**: Single source of truth for prodbox cluster federation — the root/child Vault
> transit-seal trust tree, per-cluster seal custody, parent custody of child init keys,
> downstream-cluster metadata as secret data, the root-token config-write authority, and the
> fail-closed unseal cascade.

## 1. Why this doctrine exists

prodbox manages a hierarchy of clusters: one root cluster and zero or more downstream (child)
clusters. Every cluster runs its own in-cluster Vault as its fail-closed secrets / KMS / PKI root
([vault_doctrine.md](./vault_doctrine.md)). Federation is the contract that binds those
per-cluster Vaults into a single tree of trust and unseal authority, so that the liveness of the
entire fleet roots in one operator unsealing one Vault.

The load-bearing consequence: a cluster's knowledge of its child clusters — their existence,
identities, endpoints, kubeconfigs, account IDs, and Pulumi stacks — is **secret data**, legible
only behind an unsealed Vault. A `.data/` snapshot, a MinIO dump, or a Kubernetes Secret export of
any cluster reveals nothing about the clusters below it while that cluster's Vault is sealed.

This doctrine is the SSoT for the federation topology. It composes with, and does not weaken, the
fail-closed Vault model: [vault_doctrine.md](./vault_doctrine.md) owns the single-cluster Vault
contract; this doctrine owns the cross-cluster trust tree, the per-tier seal mode, and the config
SSoT inversion that makes downstream inventory unrecoverable from a sealed parent. The
cluster-federation surface — child registration, init-key custody, and the federated unseal
cascade — lands under Sprints `2.26`, `3.20`, `4.32`, and `1.38`; where this doctrine describes
structure the worktree does not yet honor, it names the owning sprint, and until that sprint lands
the statement is the intended end state, not a present-tense fact.

## 2. The transit-seal trust tree

Trust and unseal authority form a strict tree rooted at the root cluster. Each tier has exactly one
Vault seal mode, exactly one unseal authority, and exactly one owner of its init keys (recovery
keys + initial root token):

| Tier | Vault seal mode | Who unseals it | Init keys owned by |
|------|-----------------|----------------|--------------------|
| **Root cluster** | Shamir | The operator only, via the password-AEAD unlock bundle in durable MinIO, decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

The root cluster is the only tier a human ever unseals. Its Vault uses Shamir seal mode; its
unseal/recovery keys live only inside the password-AEAD unlock bundle in the durable MinIO bucket,
and the only secret the operator memorizes is the bundle password (see
[vault_doctrine.md § 6](./vault_doctrine.md#6-the-unlock-bundle)). The target host path posts that
password to the loopback-restricted daemon bootstrap endpoint; the daemon reads MinIO and unseals
Vault in-cluster. The test harness simulates the operator at the unseal prompt by reading that
password from `test-secrets.dhall`; there is no production path that stores or logs it.

A child cluster never holds its own unseal keys and never prompts a human. Its Vault is configured
with Vault `seal "transit"` whose target is its parent cluster's Vault Transit mount. At startup
the child Vault calls the parent's Transit key to wrap/unwrap its own seal — so a child literally
cannot unseal without a live, unsealed parent (Sprint `3.20`).

```text
root cluster Vault (Shamir)
  unsealed by operator password -> MinIO unlock bundle -> Shamir unseal keys
    |
    +-- child cluster A Vault (seal "transit" -> root's Transit key)
    |     auto-unseals against root; init keys custodied in root's Vault KV
    |
    +-- child cluster B Vault (seal "transit" -> root's Transit key)
          auto-unseals against root; init keys custodied in root's Vault KV
            |
            +-- grandchild cluster Vault (seal "transit" -> child B's Transit key)
                  auto-unseals against child B; init keys custodied in child B's Vault KV
```

The tree may be deeper than one level: a child cluster may itself be the parent of further
downstream clusters, in which case it custodies their init keys and serves their transit-seal
unseal authority exactly as the root does for its direct children.

Cross-cluster **workload placement** rides on this same trust tree: a placing cluster may target
only clusters within its own subtree — a child spec cannot reach beyond it, and a sealed or
unreachable target is never an eligible placement destination — per
[resource_scaling_doctrine.md § 6 (rule t)](./resource_scaling_doctrine.md#6-federation-scoped-placement-rule-t-and-untouched-gateway-leadership).
Sprint `4.34` implements the pure trust-tree admission check in
`Prodbox.Scaling.Autoscaler.clusterInTrustTree`; live multi-cluster placement remains a
non-blocking proof axis.

## 3. Parent custody of child init keys

"Parents own the init keys for child clusters" is a hard custody rule, not a convenience.

At child cluster initialization (`vault init` running exactly once against an empty child Vault PV;
see [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md § 5](./vault_doctrine.md#5-vault-deployment-model)), the child produces recovery
keys and an initial root token. prodbox captures that material exactly once and writes it directly
into the **parent's** Vault KV — never to the child's own host disk, never to a child unlock bundle,
never to a Kubernetes Secret, never to logs (Sprint `2.26`, Sprint `3.20`):

```text
parent Vault KV
  secret/data/clusters/<child-id>/init       recovery keys + initial root token (custodied for the child)
  secret/data/clusters/<child-id>/metadata   child identity, endpoints, kubeconfig, account id, stacks
  secret/data/clusters/<child-id>/bootstrap  child transit-seal bootstrap credential
  secret/data/clusters/index                 parent child index for gateway listing
transit/<child-seal-key>              the child's transit-seal unseal authority
```

Sprint `1.36`'s base `vault reconcile` plan creates the parent-side Transit foundation
(`prodbox-downstream-cluster-config`) and federation-custody policy. The child registration
surface's typed foundation is in `Prodbox.Cluster.Federation`: it pins the KV v2 API paths above,
the child metadata/init JSON payloads, the opaque child namespace / Transit-key derivation, the
root-token write gate, and the `prodbox cluster federation register <child>` plan/apply surface.
Sprint `4.32` adds the direct parent-side live registration writer: the parent loads its root Vault
token, reads the Vault-owned federation HMAC key, ensures the per-child Transit key, writes a scoped
child token policy, creates the child transit-seal token, writes child metadata/bootstrap/index KV
objects to parent Vault, and applies the child-side `vault/vault-transit-seal-token` Secret without
printing that token. Sprint `2.26` closes the gateway-mediated read path: the gateway daemon keeps
its non-secret Vault Kubernetes-auth coordinates from `/etc/gateway/config.dhall`, logs in through
Vault on demand, serves `/v1/federation/children` from `secret/data/clusters/index` plus each
metadata object, and serves `/v1/federation/children/<child>/bootstrap` from the child bootstrap KV
object. The listing response never returns the transit-seal token; token-bearing custody values have
redacted `Show` instances so incidental debug rendering does not print the child bootstrap token,
the child root token, or recovery keys (Sprint `4.33`). The bootstrap response is
available only through the unsealed parent Vault-backed path. The
per-cluster seal model is in `Prodbox.Vault.Seal`: root Shamir init uses unseal-key shares, child
Transit init uses recovery-key shares, the Vault chart renders `seal "transit"` only for child mode,
and child init material maps to a parent-owned Vault KV field set. The child `cluster reconcile`
interpreter initializes an empty child Vault once, writes the resulting recovery keys and initial
root token directly to the parent KV, and reuses that parent-custodied root token for later child
Vault reconcile and in-force-config reads.

All downstream kubeconfig and identity material is custodied **only** under
`secret/data/clusters/<child-id>/*` in the parent's Vault KV (KV v2 API path; the logical mount path
is `secret/clusters/<child-id>/*`). There is **no Kubernetes Secret** holding a child's kubeconfig,
init keys, or identity — a k8s Secret is cluster-legible regardless of Vault seal state, so it
cannot custody material the sealed-parent invariant requires to be opaque. Where the parent must
materialize a child-scoped Kubernetes object, the **namespace and object names use the same opaque
IDs** as the object-store (a Vault-keyed HMAC of the child id), so a `kubectl get ns` / Secret dump
on the parent never advertises a downstream cluster's identity
([vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store)).

Consequences:

- The child's unseal authority is the parent's Transit key; the child's recovery material and
  kubeconfig are in the parent's Vault KV, never in a k8s Secret. Both are unreachable while the
  parent is sealed.
- Recovering, rotating, or re-keying a child cluster is a parent-side, root-token-gated operation
  against the parent's Vault — it cannot be done from the child alone.
- A child cluster that loses its Vault PV is re-provisioned with help from the parent's custodied
  init material; a child cannot self-recover its own root authority.

## 4. Downstream-cluster metadata is secret

A cluster's knowledge of its children is secret data, not topology that may live in plaintext
config and not material that may rest in a cluster-legible Kubernetes Secret. The names,
endpoints, kubeconfigs, account IDs, DNS names, and Pulumi stack identities of every downstream
cluster a cluster manages are custodied only as Vault KV objects under
`secret/data/clusters/<child-id>/*` (§3) and as Vault-Transit-enveloped MinIO objects
([vault_doctrine.md § 8–§9](./vault_doctrine.md#8-envelope-encryption-with-vault-transit)),
encrypted under the `transit/prodbox-downstream-cluster-config` domain key and routed through the
one generically-named object-store. The MinIO objects are HMAC-named `objects/<id>.enc`
ciphertext with a Vault-encrypted index, so a sealed-Vault MinIO dump reveals only opaque object
IDs at a decoy-padded constant count — never a downstream cluster's identity, never even how many
children exist (Sprint `2.26`, Sprint `4.32`).

A child id is itself a metadata leak on any sealed-legible surface. Every Kubernetes object the
parent materializes for a child — namespaces above all — is named by the **same opaque ID** the
object-store uses (a Vault-keyed HMAC of the child id), never the child's logical name, so a
parent-side `kubectl get ns` reveals only opaque identifiers
([vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store)).

This is the **cluster-metadata-is-secret invariant** of
[vault_doctrine.md § 2](./vault_doctrine.md#2-the-fail-closed-invariant) applied to federation:
a sealed cluster reveals nothing about the clusters below it. Logs and command output **never
emit a downstream cluster's identifying name on a sealed-state path** — not on a failure, not on a
blocked-unseal status, and not via an exists-vs-absent oracle that would distinguish "this child
is registered" from "no such child." Prefer redacted structured logs
(`vault_status=sealed component=federation operation=child-unseal result=blocked`) over
identifying messages; opaque IDs, not child names, are what may appear on a sealed path.

## 5. Config SSoT inversion and the unencrypted basics

The in-force cluster configuration is **not** a filesystem file — it is the
Vault-Transit-enveloped object in MinIO under `transit/prodbox-active-config`, and that encrypted
object is the source of truth ([config_doctrine.md](./config_doctrine.md), Sprint `1.38`). When a
cluster's Vault is sealed, the in-force config is opaque ciphertext: nothing about the cluster's
setup or its child clusters is determinable beyond the **unencrypted basics**.

The unencrypted basics are the minimal, non-revealing bootstrap a cluster needs only to reach and
unseal its own Vault — and nothing more:

| Basic | Purpose | Reveals |
|-------|---------|---------|
| Cluster id | Identify which cluster this host is operating | A non-secret identifier only |
| This cluster's Vault address | Reach the local Vault to unseal it | A reachability hint only |
| Seal mode (`shamir` / `transit`) | Decide whether to prompt the operator or auto-unseal against the parent | The unseal mechanism only |
| Parent reference (child clusters only) | Locate the parent Vault this cluster must contact to auto-unseal | The existence of one parent, no downstream inventory |

The basics carry nothing about workloads, downstream clusters, or credentials. Everything else —
the full in-force config, the downstream-cluster inventory, every secret — is behind the
cluster's unsealed Vault.

The unencrypted basics are projected from the non-secret binary-context tier defined in
[config_doctrine.md § 0](./config_doctrine.md#0-three-tier-config-model). That tier is
**orthogonal** to the SSoT inversion described here: it is non-secret context the binary carries
locally, never a route around the sealed-Vault posture, and it never widens what a sealed cluster
reveals beyond the four basics above. The SSoT inversion and the fail-closed seal model are
prodbox's additive secrecy layer on top of that non-secret tier; neither displaces the other.

A child cluster's federation **orders** — the downstream-cluster inventory, identities, endpoints,
kubeconfigs, account IDs, and Pulumi stacks — likewise live entirely within the operational-secret
tier: the existing `LogicalDownstreamCluster` Vault-Transit object in the shared object-store (§3,
§4), never a new on-disk encrypted file. There is no separate child-orders artifact on host disk;
the non-secret basics locate the parent Vault, and the orders themselves resolve only behind an
unsealed Vault.

A filesystem `prodbox-config.dhall` is a **seed/propose input only, not the SSoT**. On first-ever
bring-up it seeds the encrypted MinIO SSoT; thereafter supplying a file is a *proposed update*
applied through Vault, not a direct read of the in-force config. The host CLI reads the basics
locally and fetches + decrypts the in-force config from MinIO via Vault; it does not read a
repo-root Dhall file directly as the live config (Sprint `1.38`). The Sprint `1.38` local
foundations and global host-loader switch are landed; when unencrypted basics exist, host settings
loads go through Vault and MinIO instead of direct repo-root Dhall.

## 6. Root-token config-write authority

Reads of the basics are always free. Full reads of a cluster's in-force config require that
cluster's Vault to be unsealed. **Writes to the root cluster's in-force config require the root
Vault token** — which requires an unsealed root Vault (Sprint `1.38`, Sprint `4.32`).

The root config governs every downstream cluster — it is the keys to the kingdom — so mutating it
is the most privileged operation in the fleet:

```text
read basics            -> always available (no Vault)
read in-force config   -> requires this cluster's Vault unsealed
write in-force config  -> requires this cluster's Vault unsealed AND the privileged root token
```

A child cluster's in-force config is written under the privileged token custodied for it in its
parent's Vault KV (§3); a child cannot rewrite its own governing config without the parent's
custodied authority. This keeps the authority to reconfigure any cluster anchored in the parent
chain, terminating at the operator who unseals the root.

## 7. The fail-closed unseal cascade

Fail-closed is absolute and it cascades down the tree. A child Vault cannot unseal without a live,
unsealed parent; if any parent is sealed or unreachable, its children cannot auto-unseal, and the
brick propagates downward from the point of failure (Sprint `4.32`):

```text
operator does not unseal the root
  -> root Vault stays sealed
    -> every child's transit-seal call to the root fails
      -> no child can auto-unseal
        -> every grandchild's transit-seal call to its (sealed) child fails
          -> the entire subtree is bricked, fail-closed, leaking nothing
```

Cluster liveness for the whole tree therefore roots in one operator unsealing the root. The cascade
is the intended safety property, not a fault: a sealed parent must brick its descendants rather
than let them come up with secrets recovered from any non-Vault source. Each cluster surfaces a
sealed or unreachable parent as a first-class status, never hidden:

```text
Vault: initialized, sealed (transit seal: parent unreachable)
Parent cluster Vault: unreachable
Auto-unseal: blocked; parent sealed or unreachable
In-force config: unavailable; Vault sealed
Downstream clusters: unavailable; Vault sealed
```

Federated `cluster reconcile` honors the cascade: a child `prodbox cluster reconcile` checks parent
Vault readiness before any secret-dependent reconcile step runs, requires the parent-provisioned
transit-seal token Secret, renders the Vault chart with `seal "transit"`, and refuses to proceed —
with a clear, safe error and no local unseal fallback — when the parent is sealed or unreachable
(Sprint `4.32`). Init-once / unseal-on-rebuild holds per cluster: a child's Vault is initialized
exactly once (the first time its PV is empty), writes its recovery shares and initial root token to
the parent KV, and every subsequent reconcile only auto-unseals it against the parent (see
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md § 5](./vault_doctrine.md#5-vault-deployment-model)).

Sprint `5.8` wires the named `sealed-vault` canonical validation surface for this proof. Its
code-owned planner/parser surface is active; the deployed parent/child cascade proof remains part of
the live sealed-Vault red-team closure.

## 8. What stays outside Vault (the federation floor)

Federation does not enlarge the chicken-and-egg floor of
[vault_doctrine.md § 7 / the SecretRef model](./vault_doctrine.md#3-the-secretref-model). The only
material that may live outside Vault is the minimum needed to reach and unseal each cluster's own
Vault:

- **Root cluster only:** the operator unseal-bundle password (memorized, persisted nowhere) plus
  the password-AEAD unlock bundle in the durable MinIO bucket.
- **Child cluster only:** the bootstrap reference + transit-seal credential the child uses to reach
  its parent's Vault to auto-unseal — itself provisioned and owned by the parent (§3).
- The unencrypted basics (§5): cluster id, this cluster's Vault address, seal mode, and (for a
  child) the parent reference.

Everything else — the in-force config, the downstream-cluster inventory and identities, child
init keys, every credential — is Vault-owned and unrecoverable from a sealed cluster.

## 9. Owning sprints

| Sprint | Surface this doctrine prescribes |
|--------|----------------------------------|
| `1.38` | Config SSoT inversion: the Vault-Transit-enveloped MinIO object is the in-force config; filesystem Dhall is seed/propose only; the unencrypted-basics local surface; root-token-gated root-config writes (§5, §6). |
| `2.26` | Cluster federation trust topology and downstream-cluster custody: the parent/child hierarchy; downstream-cluster config/identities as secret; the CLI/gateway surface to register a child cluster, custody its init keys, record full downstream inventory, and expose Vault-backed child-listing / bootstrap-reference endpoints (§2–§4). |
| `3.20` | Vault transit-seal hierarchy and per-cluster seal custody: root Shamir + `.age` bundle; child `seal "transit"` chart rendering against the parent; child recovery-key init request shape; child init keys mapped to parent-owned Vault KV; per-domain Transit keys + policies (§2, §3). |
| `4.32` | Federated lifecycle reconcile and fail-closed unseal cascade: direct parent-side live child registration; child `cluster reconcile` auto-unseals from its parent; init-once/unseal-on-rebuild; the brick cascade when a parent is sealed/unreachable; lifecycle settings reload after Vault/MinIO uses the child root token custodied in the parent KV (§6, §7). |
| `5.8` | Canonical sealed-Vault validation: `prodbox test integration sealed-vault` proves the deployed parent/child fail-closed cascade and cross-surface no-child-info invariant during the live red-team closure (§7). |

## Cross-References

- [vault_doctrine.md](./vault_doctrine.md) — the per-cluster fail-closed Vault contract this
  federation tree is built on
- [config_doctrine.md](./config_doctrine.md) — the config SSoT inversion and the unencrypted-basics
  local surface
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — the gateway daemon
  whose downstream-cluster state is Vault-enveloped and parent-custodied
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained per-cluster Vault
  PV and the init-once / unseal-on-rebuild durability that federation depends on
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — Closure Status and the
  per-surface federation sprints (`1.38`, `2.26`, `3.20`, `4.32`)
