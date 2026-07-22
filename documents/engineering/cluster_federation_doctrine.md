# Cluster Federation Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md),
[README.md](./README.md),
[vault_doctrine.md](./vault_doctrine.md),
[config_doctrine.md](./config_doctrine.md),
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md](../../DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md),
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md),
[cluster_topology_doctrine.md](./cluster_topology_doctrine.md),
[lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md)
**Generated sections**: none

> **Purpose**: Single source of truth for prodbox cluster federation — the root/child Vault
> transit-seal trust tree, per-cluster seal custody, parent custody of encrypted child recovery
> material and revocation attestations,
> downstream-cluster metadata as secret data, generation-CAS config authority, and the
> fail-closed unseal cascade, interpreted through the separated lifecycle control-plane
> authorities.

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
structure the worktree does not yet honor, it names the owning sprint as a historical delivery
record. Current implementation, cutover, and deployment-qualification status live only in the
Development Plan.

## 2. The transit-seal trust tree

Trust and unseal authority form a strict tree rooted at the root cluster. Each tier has exactly one
Vault seal mode, exactly one unseal authority, and exactly one owner of its durable recovery
material. Initial root tokens are encrypted to a pinned burn public key whose private material
existed only inside an isolated destructive ceremony, was never exported, was destroyed before
adoption, is never accepted, retained, or available to `prodbox`, and has no known holder; the
encrypted token is never decrypted or used:

| Tier | Vault seal mode | Who unseals it | Durable recovery material owned by |
|------|-----------------|----------------|--------------------|
| **Root cluster** | Shamir | The operator only, via the password-AEAD unlock bundle in durable MinIO, decrypted by a memorized password stored nowhere persistent (`test-secrets.dhall` simulates it in tests) | The operator (the password) |
| **Child cluster** | `seal "transit"` pointed at the **parent** cluster's Vault | Auto-unseals against the parent — no human, no local unseal keys | The **parent** cluster's Vault KV |

The root cluster is the only tier a human ever unseals. Its Vault uses Shamir seal mode; its
unseal/recovery keys live only inside the password-AEAD unlock bundle in the durable MinIO bucket,
and the only secret the operator memorizes is the bundle password (see
[vault_doctrine.md § 6](./vault_doctrine.md#6-the-unlock-bundle)). The target host path submits the
bounded unlock proof to Bootstrap Broker, the only pre-Vault process; the broker reads the bootstrap
store and unseals Vault in-cluster. Gateway Runtime never receives the password or touches the
unlock bundle. The test harness simulates the operator at the unseal prompt by reading that
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

Federation does not collapse process authority:

- Bootstrap Broker alone owns bounded Vault init/unlock/seal/rotation, including root Shamir and
  child transit-seal bootstrap steps that must occur before the child Vault is usable.
- Lifecycle Authority owns the durable, idempotent parent/child registration operation, operation
  journal, fences, Model-B aggregate/checkpoint references, and delivery outbox.
- The selected parent or child substrate's Target Secret Agent alone performs allowlisted,
  generation-checked Vault KV read/CAS/read-back for custody material.
- Gateway Runtime owns mesh/DNS and its local emitter journal only. It neither lists federation
  custody nor returns bootstrap credentials.

Each call is resolved from operation, service identity, and authority scope to one opaque
`CapabilityRef kind`. Observation, admission, and execution reuse that same reference; a reachable
gateway, component label, or separately supplied readiness endpoint is not federation capability
evidence. The component topology is canonical in
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

## 3. Parent custody of encrypted child recovery material

Parents owning encrypted recovery material for child clusters is a hard custody rule, not a
convenience. The target custody record never contains a reusable initial root token.

At child cluster initialization (`vault init` running exactly once against an empty child Vault PV;
see [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) and
[vault_doctrine.md § 5](./vault_doctrine.md#5-vault-deployment-model)), Vault PGP-encrypts recovery
shares to the prepared parent-custody recipient and encrypts the initial root token to the pinned
burn public key. Its private material existed only inside the isolated destructive ceremony, was
never exported, was destroyed before adoption, is never accepted, retained, or available to
`prodbox`, has no known holder, and the encrypted initial token is never decrypted or used. The child journals only
the encrypted share receipt, delivers it
to parent custody, and waits for exact generation read-back before deleting the local receipt. A
separate short-lived generated root session performs/read-backs baseline and is accessor-revoked.
Usable initial-token material and plaintext recovery shares never enter child host storage, a child
unlock bundle, Kubernetes Secret, Lifecycle Authority, Gateway Runtime, or logs:

```text
parent Vault KV
  secret/data/clusters/<child-id>/recovery   encrypted share receipt + custody/root-session attestation
  secret/data/clusters/<child-id>/metadata   child identity, endpoints, kubeconfig, account id, stacks
  secret/data/clusters/<child-id>/bootstrap  child transit-seal bootstrap credential
  secret/data/clusters/index                 parent child index for federation inventory
transit/<child-seal-key>              the child's transit-seal unseal authority
```

The target registration is one durable Lifecycle Authority operation. Before any external write,
the authority commits the operation and delivery intent. Bootstrap Broker performs only the
bounded child Vault init/transit-seal/first-baseline work and never returns a usable root token or
plaintext share.
The parent Target Secret Agent conditionally writes the allowlisted
metadata/bootstrap/index/recovery-custody objects with generation checks and exact read-back.
Non-secret metadata and ciphertext may carry integrity digests; recovery-secret equality uses only
the Agent's opaque, domain-separated Vault-HMAC commitment reference and never exposes a raw
plaintext/share digest. Lifecycle Authority records delivery complete only after exact read-back and
closes the operation after re-observing the child seal state. A lost response is recovered by
`OperationId`; it is never retried as an untracked second registration. Scoped registration and
break-glass credentials are held by the owning boundary session manager, not Gateway Runtime.

#### Historical gateway-mediated implementation record (legacy cutover surface)

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
its non-secret Vault Kubernetes-auth coordinates from `/etc/gateway/config/config.dhall`, logs in through
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
- Recovering, rotating, or re-keying a child cluster is a parent-authorized one-time operation. The
  parent agent reads only the registered custody generation and re-encrypts threshold shares to an
  attested ephemeral child-Broker recipient. The child mints one short-lived root session, repairs,
  reads back, revokes, proves accessor absence, and acknowledges the delivery nonce. It cannot be
  done from the child alone and no reusable root token is custodied.
- A child cluster that loses its Vault PV is re-provisioned with help from the parent's custodied
  init material; a child cannot self-recover its own root authority.

#### Public-edge TLS is not a custody payload

A child cluster's public-edge TLS is **per-zone self-issuance**, not custodied material a parent
hands down. A parent never delivers a child's certificate private key; a child issues its own
public-edge certificates in its own delegated subzone (`aws_substrate.subzone_name`) through the
`zerossl-dns01` ClusterIssuer over DNS-01, using the delivered `AcmeEabMaterial` — which
repopulates a fresh AWS Vault without operator re-prompt or key rotation. This keeps one TLS
custody model and never copies a parent private key into a routinely-destroyed test substrate.

The child-custody record above (`secret/data/clusters/<child-id>/*`) is exhaustive:
certificate-material handoff is **not** a member of the closed `RetainedMaterialSchema`
([lifecycle_control_plane_architecture.md § 5.5](./lifecycle_control_plane_architecture.md#55-retained-operator-material-custody)),
whose only classes are `SesSmtpMaterial` and `AcmeEabMaterial` — there is no arbitrary
`secret/data/clusters/<child-id>/tls` custody path, and adding one would require a new schema
constructor, not a new KV write. The cross-substrate TLS movement that does exist is owned entirely
by the retained TLS envelope workflow
([lifecycle_control_plane_architecture.md § 5.4](./lifecycle_control_plane_architecture.md#54-retained-tls-envelope-workflow)),
never by federation custody. A child self-issues in its delegated subzone in any case: a parent
wildcard is anchored at the parent's own delegated zone and cannot cover a child's deeper labels
(`*.z` matches exactly one label, so it never covers `*.child.z`), so there is no certificate a
parent could usefully hand down even if the schema admitted the class.

## 4. Downstream-cluster metadata is secret

A cluster's knowledge of its children is secret data, not topology that may live in plaintext
config and not material that may rest in a cluster-legible Kubernetes Secret. The names,
endpoints, kubeconfigs, account IDs, DNS names, and Pulumi stack identities of every downstream
cluster a cluster manages are custodied only as Vault KV objects under
`secret/data/clusters/<child-id>/*` (§3) and as Vault-Transit-enveloped MinIO objects
([vault_doctrine.md § 8–§9](./vault_doctrine.md#8-envelope-encryption-with-vault-transit)),
encrypted under the `transit/prodbox-downstream-cluster-config` domain key and routed through the
one generically-named object store owned through Lifecycle Authority, never a gateway proxy. The
MinIO objects are HMAC-named `objects/<id>.enc`
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

The in-force cluster configuration is **not** a filesystem file. The Lifecycle Authority
aggregate's generation/digest/reference is the source of truth and selects one immutable
Vault-Transit-enveloped MinIO blob; the blob alone is never current
([config_doctrine.md](./config_doctrine.md)). When a cluster's Vault is sealed, the selected config
is opaque ciphertext: nothing about the cluster's setup or children is determinable beyond the
**unencrypted basics**.

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

The binary-sibling Tier-0 `prodbox.dhall` is a **seed/propose input only, not the SSoT**. On
first-ever bring-up it submits the initial proposal; the Authority generation/digest/reference plus
its immutable encrypted blob is authoritative. Thereafter supplying a file is a *proposed update*
submitted as a durable Lifecycle Authority operation, not a direct read of the in-force
config. The host CLI reads the basics locally and uses the operation-indexed Lifecycle Authority
capability to fetch or propose the in-force config; it does not read a repo-root Dhall file directly
as the live config or select a gateway/object-store endpoint (Sprint `1.38`). The Sprint `1.38` local
foundations and global host-loader switch are landed; Sprint `1.42` retired the repo-root
`prodbox-config.dhall` seed and moved the seed/propose payload into Tier-0 `prodbox.dhall`.

## 6. Generation-CAS config-write authority

Reads of the basics are always free. Full reads of a cluster's in-force config require that
cluster's Vault to be unsealed. Writes require a short-lived config-admin TokenRequest proof, the
exact Lifecycle Authority `ConfigProposeCas` capability, the expected authority epoch and config
generation, and immutable-blob read-back. A Vault root token is not a config credential.

The root config governs every downstream cluster — it is the keys to the kingdom — so mutating it
is the most privileged operation in the fleet:

```text
read basics            -> always available (no Vault)
read in-force config   -> requires this cluster's Vault unsealed
write in-force config  -> config-admin proof + exact authority epoch/generation CAS + read-back
```

A child cluster's in-force config is accepted only by a parent-authorized durable operation whose
target identity and expected generation are explicit. A child cannot rewrite its own governing
config merely because it can reach its Vault. This keeps reconfiguration authority anchored in the
parent chain without retaining a reusable root token.

The config-admin proof authorizes a request, not a direct write. Lifecycle Authority validates the
proposal purely, writes and reads back an immutable encrypted blob, and CAS-advances its bounded
aggregate. Neither Target Secret Agent, Gateway Runtime, nor a host-direct fallback owns config
authority. The same operation-indexed capability reference is used for observation, admission,
mutation, and read-back.

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

Federated `cluster reconcile` honors the cascade by resolving the exact parent bootstrap operation
to a Bootstrap Broker `CapabilityRef` and using that same reference for observation, admission, and
execution. `VaultUninitialized`, `VaultSealed`, `VaultUnsealed`, and unobservable failure remain
distinct; a ready Pod, reachable gateway, or nominal parent endpoint does not admit secret-dependent
work. It requires the parent-provisioned transit-seal credential, renders the Vault chart with
`seal "transit"`, and refuses—with no local unseal fallback—when the parent is sealed or
unobservable.

**Historical implementation record:** Sprint `4.32` implements the earlier direct parent-readiness
and `cluster reconcile` binding. That pre-redesign implementation wrote recovery shares and an
initial root token to parent KV; this is a deletion surface, not the target custody contract above.
Init-once / unseal-on-rebuild still holds per cluster: a child's Vault is initialized exactly once
against an empty PV and every subsequent reconcile only auto-unseals it against the parent (see
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

## 9. Historical Delivery Records

The following rows preserve original implementation ownership. They do not override the target
authority split above and do not claim current cutover or qualification status; the Development
Plan owns both.

| Sprint | Surface this doctrine prescribes |
|--------|----------------------------------|
| `1.38` | Config SSoT inversion: the Vault-Transit-enveloped MinIO object is the in-force config; filesystem Dhall is seed/propose only; the unencrypted-basics local surface; root-token-gated root-config writes (§5, §6). |
| `2.26` | Cluster federation trust topology and downstream-cluster custody, including the historical CLI/gateway registration, child-listing, and bootstrap-reference routes retained only as legacy cutover surfaces (§2–§4). The target replaces those routes with Lifecycle Authority and Target Secret Agent capabilities. |
| `3.20` | Vault transit-seal hierarchy and per-cluster seal custody: root Shamir + password-AEAD (Argon2id + ChaCha20-Poly1305) unlock bundle; child `seal "transit"` chart rendering against the parent; child recovery-key init request shape; child init keys mapped to parent-owned Vault KV; per-domain Transit keys + policies (§2, §3). |
| `4.32` | Federated lifecycle reconcile and fail-closed unseal cascade: direct parent-side live child registration; child `cluster reconcile` auto-unseals from its parent; init-once/unseal-on-rebuild; the brick cascade when a parent is sealed/unreachable; lifecycle settings reload after Vault/MinIO uses the child root token custodied in the parent KV (§6, §7). |
| `5.8` | Canonical sealed-Vault validation: `prodbox test integration sealed-vault` proves the deployed parent/child fail-closed cascade and cross-surface no-child-info invariant during the live red-team closure (§7). |

## Cross-References

- [vault_doctrine.md](./vault_doctrine.md) — the per-cluster fail-closed Vault contract this
  federation tree is built on
- [config_doctrine.md](./config_doctrine.md) — the config SSoT inversion and the unencrypted-basics
  local surface
- [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — Gateway Runtime,
  which owns federation mesh/DNS projection only and does not custody or serve child secrets
- [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) — the
  Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and operation-indexed capability
  boundaries used to interpret federation safely
- [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) — the retained per-cluster Vault
  PV and the init-once / unseal-on-rebuild durability that federation depends on
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) — Closure Status and the
  per-surface federation sprints (`1.38`, `2.26`, `3.20`, `4.32`)
