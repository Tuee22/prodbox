# Cluster Federation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [vault_doctrine.md](./vault_doctrine.md),
[config_doctrine.md](./config_doctrine.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)
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
| **Root cluster** | Shamir | The operator only, via the `.age` unlock bundle decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

The root cluster is the only tier a human ever unseals. Its Vault uses Shamir seal mode; its
unseal/recovery keys live only inside the host-side `.age` unlock bundle on retained host storage
(`.data/prodbox/vault-unlock-bundle.age`), and the only secret the operator memorizes is the
bundle password (see [vault_doctrine.md § 6](./vault_doctrine.md#6-the-unlock-bundle)). The
test harness simulates the operator at the unseal prompt by reading that password from
`test-secrets.dhall`; there is no production path that stores or logs it.

A child cluster never holds its own unseal keys and never prompts a human. Its Vault is configured
with Vault `seal "transit"` whose target is its parent cluster's Vault Transit mount. At startup
the child Vault calls the parent's Transit key to wrap/unwrap its own seal — so a child literally
cannot unseal without a live, unsealed parent (Sprint `3.20`).

```text
root cluster Vault (Shamir)
  unsealed by operator password -> .age unlock bundle -> Shamir unseal keys
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

## 3. Parent custody of child init keys

"Parents own the init keys for child clusters" is a hard custody rule, not a convenience.

At child cluster initialization (`vault init` running exactly once against an empty child Vault PV;
see [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md § 5](./vault_doctrine.md#5-vault-deployment-model)), the child produces recovery
keys and an initial root token. prodbox captures that material exactly once and writes it directly
into the **parent's** Vault KV — never to the child's own host disk, never to a child unlock bundle,
never to logs (Sprint `2.26`, Sprint `3.20`):

```text
parent Vault KV
  secret/clusters/<child-id>/init     recovery keys + initial root token (custodied for the child)
  secret/clusters/<child-id>/meta     child identity, endpoints, kubeconfig, account id, stacks
transit/<child-seal-key>              the child's transit-seal unseal authority
```

Consequences:

- The child's unseal authority is the parent's Transit key; the child's recovery material is in the
  parent's KV. Both are unreachable while the parent is sealed.
- Recovering, rotating, or re-keying a child cluster is a parent-side, root-token-gated operation
  against the parent's Vault — it cannot be done from the child alone.
- A child cluster that loses its Vault PV is re-provisioned with help from the parent's custodied
  init material; a child cannot self-recover its own root authority.

## 4. Downstream-cluster metadata is secret

A cluster's knowledge of its children is secret data, not topology that may live in plaintext
config. The names, endpoints, kubeconfigs, account IDs, DNS names, and Pulumi stack identities of
every downstream cluster a cluster manages are stored only as Vault KV objects and as
Vault-Transit-enveloped MinIO objects ([vault_doctrine.md § 8–§9](./vault_doctrine.md#8-envelope-encryption-with-vault-transit)),
encrypted under the `transit/prodbox-downstream-cluster-config` domain key. Object names and
indexes use opaque IDs so a sealed-Vault MinIO dump reveals only opaque object IDs, never a
downstream cluster's identity (Sprint `2.26`, Sprint `4.32`).

This is the **cluster-metadata-is-secret invariant** of
[vault_doctrine.md § 2](./vault_doctrine.md#2-the-fail-closed-invariant) applied to federation:
a sealed cluster reveals nothing about the clusters below it. Logs never emit a downstream
cluster's identifying name on a sealed-state failure path; prefer redacted structured logs
(`vault_status=sealed component=federation operation=child-unseal result=blocked`) over
identifying messages.

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

A filesystem `prodbox-config.dhall` is a **seed/propose input only, not the SSoT**. On first-ever
bring-up it seeds the encrypted MinIO SSoT; thereafter supplying a file is a *proposed update*
applied through Vault, not a direct read of the in-force config. The host CLI reads the basics
locally and fetches + decrypts the in-force config from MinIO via Vault; it does not read a
repo-root Dhall file directly as the live config (Sprint `1.38`).

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

Federated `cluster reconcile` honors the cascade: a child `prodbox cluster reconcile` auto-unseals
from its parent before any secret-dependent reconcile step runs, and refuses to proceed — with a
clear, safe error and no partial state mutation — when the parent is sealed or unreachable
(Sprint `4.32`). Init-once / unseal-on-rebuild holds per cluster: a child's Vault is initialized
exactly once (the first time its PV is empty), and every subsequent reconcile only auto-unseals it
against the parent (see [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md § 5](./vault_doctrine.md#5-vault-deployment-model)).

## 8. What stays outside Vault (the federation floor)

Federation does not enlarge the chicken-and-egg floor of
[vault_doctrine.md § 7 / the SecretRef model](./vault_doctrine.md#3-the-secretref-model). The only
material that may live outside Vault is the minimum needed to reach and unseal each cluster's own
Vault:

- **Root cluster only:** the operator unseal-bundle password (memorized, persisted nowhere) plus
  the `.age` unlock bundle on retained host storage (`.data/prodbox/vault-unlock-bundle.age`).
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
| `2.26` | Cluster federation trust topology and downstream-cluster custody: the parent/child hierarchy; downstream-cluster config/identities as secret; the CLI/gateway surface to register a child cluster and custody its init keys (§2–§4). |
| `3.20` | Vault transit-seal hierarchy and per-cluster seal custody: root Shamir + `.age` bundle; child `seal "transit"` against the parent; child init keys stored in the parent's Vault KV; per-domain Transit keys + policies (§2, §3). |
| `4.32` | Federated lifecycle reconcile and fail-closed unseal cascade: child `cluster reconcile` auto-unseals from its parent; init-once/unseal-on-rebuild; the brick cascade when a parent is sealed/unreachable; root-token-gated root-config mutation wired into lifecycle (§6, §7). |

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
