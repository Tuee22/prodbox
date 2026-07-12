# ZeroSSL Certificate Policy & Remediation

**Status**: Proposal (remediation design)
**Supersedes**: N/A — first statement of certificate-scope policy
**Referenced by**: (to be linked from `documents/engineering/acme_provider_guide.md`,
`envoy_gateway_edge_doctrine.md`, `vault_doctrine.md`, `cluster_federation_doctrine.md` on adoption)
**Generated sections**: none

> **Purpose**: Record the incident that a `vscode.resolvefintech.com` ZeroSSL certificate expired with a
> "click to renew" email, explain why that certificate was never under prodbox management, and specify the
> remediation: a pure-functional, wildcard-per-domain certificate shape with parent→child narrowing handoff
> that makes an unmanageable or over-broad certificate **impossible to represent**.

---

## 1. Incident

ZeroSSL emailed the operator that the certificate for `vscode.resolvefintech.com` had expired and asked
them to click a link to renew.

**Root cause: that certificate is not managed by prodbox.** It is a hand-issued ZeroSSL *dashboard*
(portal) certificate — a 90-day DV cert whose renewal is a manual, human, click-a-link action. It is the
only kind of ZeroSSL certificate that generates "click to renew" mail. It exists **nowhere in this
repository**; no code path references `vscode.resolvefintech.com`.

## 2. What prodbox actually does today

| Property | Current automated edge |
|---|---|
| Hostname model | **One** shared host `test.resolvefintech.com`, path routing (`/vscode`, `/auth`, `/api`, `/ws`, `/minio`) |
| Issuer | cert-manager `ClusterIssuer zerossl-dns01`, ZeroSSL ACME over **DNS-01 / Route 53** |
| Renewal | **Automatic and silent** — cert-manager renews before expiry; no email, no click |
| Durability | Issued cert retained as a Vault-Transit-wrapped envelope in S3 (`public-edge-tls/<substrate>/<fqdn>`), restored-before-issue on every rebuild so ZeroSSL quota is never re-spent |
| Wildcards | **Rejected** today (`envoy_gateway_edge_doctrine.md`): the model is one host + path routing |

So VS Code is *already* served, with an auto-renewing certificate, at
`https://test.resolvefintech.com/vscode`. The expired `vscode.resolvefintech.com` cert is redundant
drift, not a gap in the automation.

**The renewer is cert-manager, not the gateway ("amoebius") daemon.** The daemon deliberately never
touches ACME certificates, and `pure_fp_standards.md` forbids modeling externally-authoritative state
(cert-manager/ZeroSSL own renewal) as owned in-process state. The daemon/host role for certificates is
**observe + custody**, never *drive renewal*.

## 3. Immediate remediation (no code required)

1. Use `https://test.resolvefintech.com/vscode` (already live, already auto-renewing).
2. In the ZeroSSL console: **revoke** the orphan `vscode.resolvefintech.com` certificate and **unsubscribe**
   from its expiry notices. Nothing in the repo depends on it.

This closes the incident. Sections 4–7 specify the durable policy so the class of problem — a served
hostname whose certificate can silently expire out-of-band — cannot recur.

## 4. Policy: the certificate shape

Two invariants, each enforced by a **smart constructor that is the only way to build the value**, so
violations are unrepresentable rather than merely checked:

- **Coverage.** A Gateway listener / HTTPRoute hostname may only be *bound* to a certificate whose scope
  `covers` that hostname. Binding an uncovered host returns `Left`; such a listener cannot be constructed.
- **Monotone narrowing.** A `CertGrant` may only be built for a scope `impliedBy` (narrower-or-equal to)
  the holder's issued scope. Widening on handoff returns `Left`; a child can never be handed material
  broader than its delegated subdomain.

**One wildcard certificate per registrable domain.** `*.resolvefintech.com` plus an apex SAN
(`resolvefintech.com`) covers every single-label sibling (`vscode.`, `test.`, `api.`, …). DNS-01 is the
**only** ACME challenge that issues wildcards and prodbox already uses it — so wildcards require **zero
solver change**.

**One source of truth, total projections.** The certificate `dnsNames`, the Gateway listener hostnames,
the served-FQDN list, and the S3 retention key are all **total functions of one scope set**. They cannot
drift apart — which is exactly the drift that produced the orphan manual certificate.

### 4.1 Scope algebra (pure, `src/Prodbox/Tls/CertScope.hs`)

```haskell
newtype Fqdn   = Fqdn Text            -- validated DNS name, smart-constructed
newtype Domain = Domain Fqdn          -- registrable anchor for a wildcard
data    CertScope = ScopeExact Fqdn | ScopeWildcard Domain
type    CertScopeSet = NonEmpty CertScope        -- e.g. { *.d , d }  (apex is its own SAN)

covers    :: CertScope -> Fqdn -> Bool           -- TOTAL
impliedBy :: CertScope -> CertScope -> Bool       -- partial order (narrower-or-equal)
mkGrant       :: HeldCert -> CertScopeSet -> Either ScopeError CertGrant   -- reuse; rejects widening
bindListener  :: CertGrant -> Fqdn        -> Either ScopeError BoundListener -- rejects uncovered host
```

**Coverage / narrowing truth (the resolved edge cases):**

| relation | result | why |
|---|---|---|
| `ScopeWildcard d` covers `x.d` | ✅ | one label under `d` |
| `ScopeWildcard d` covers apex `d` | ❌ | a wildcard never matches the apex — apex needs its own SAN |
| `ScopeWildcard d` covers `a.b.d` | ❌ | a wildcard matches exactly one label |
| `ScopeExact (x.d)` impliedBy `ScopeWildcard d` | ✅ | an exact host reuses the wildcard material |
| `ScopeWildcard (a.d)` impliedBy `ScopeWildcard d` | ❌ | **trap**: `*.d` covers `a.d` but not `foo.a.d` |

The last row is the load-bearing subtlety: a child wanting its **own** wildcard `*.child.d` cannot reuse
the parent's `*.d` — it needs a fresh ACME order for its subzone. Only an *exact* single-label host can
physically reuse the parent wildcard. This drives the provenance split:

```haskell
data CertProvenance
  = ProvenanceReuse   HeldCert          -- parent's wildcard material reused; legal iff scope impliedBy held
  | ProvenanceReissue CertOrderRequest  -- fresh narrower order (child needs *.child.d), within child's zone
```

## 5. Policy: parent→child handoff (`src/Prodbox/Tls/CertHandoff.hs`)

A parent may hand a child a certificate **narrowed to the child's delegated subdomain**, riding the
**existing** Vault transit-seal federation custody machinery (`Prodbox.Cluster.Federation`,
`applyClusterFederationRegister`, `vaultKvCasWriteV2`, `Prodbox.Crypto.Envelope`) rather than a parallel
path:

1. Parent computes `mkGrant parentWildcard childSubzoneScopeSet` (narrowing enforced; widening is `Left`).
2. Material is sealed into a `prodbox-envelope-v2` payload under the `transit/keys/prodbox-tls-envelope`
   DEK and CAS-written to the child's downstream-custody path `secret/data/clusters/<slug>/tls`.
3. The child rewraps under its own Vault transit key on pull and, at bind time, asserts `coversSet
   grantScope` for every hostname it serves.

The write is **fail-closed** (`federationWriteDecision` requires the root token on the root cluster). The
grant's scope travels in the custody record, so a child **physically cannot** present material broader
than what the parent narrowed. This is the first concrete consumer of the (today doctrine-only)
`transit/keys/prodbox-tls-envelope` lane.

## 6. Policy: expiry observation (observe, never own)

prodbox **observes** certificate expiry; it does **not** drive renewal (that stays cert-manager's job):

```haskell
data CertObservation = CertValid UTCTime | CertRenewDue UTCTime
                     | CertExpired UTCTime | CertUnobservable String   -- fail-closed, never "valid"
classifyCertExpiry :: UTCTime -> RenewWindow -> Maybe UTCTime -> CertObservation   -- pure, total
```

The live `.status.notAfter` and `now` come from an IO `discover`; classification is a pure total fold
(mirroring the `ResidueStatus` doctrine: "cannot observe ≠ absent"). `prodbox edge status` gains a
`CLASSIFICATION=certificate-renew-due` / `certificate-expired` rung so a stuck renewal is visible
**before** expiry. This is not a GADT-owned state machine — cert-manager/ZeroSSL are the authoritative
writers.

## 7. Policy: verification is mandatory and real

- **Pure algebra** is tested with **zero mocks** (`unit_testing_policy.md §1.1`): `test/unit/CertScope.hs`
  (`tasty-quickcheck`) proves the partial-order laws for `impliedBy` (reflexive/antisymmetric/transitive),
  `covers` totality, `mkGrant` rejection of widening, and coverage-preservation of handoff. Generators
  **must** include disjoint, non-covering, apex, multi-label, and single-label boundary scopes.
- **Serving is proven, not asserted** (`unit_testing_policy.md §4.1`): a named integration validation
  (`prodbox test integration wildcard-edge`) **curls multiple subdomains over TLS** (`vscode.`, `api.`,
  apex) against harness-owned infrastructure with a real ZeroSSL DNS-01 certificate — the `Ready`
  condition alone is not accepted as proof. Run on both the home and AWS substrates (substrate
  equivalence), followed by a full `prodbox test all` to confirm the green baseline is intact.

## 8. Adoption phases

1. **Algebra + pure tests** — `Prodbox.Tls.CertScope` + `test/unit/CertScope.hs`. No behavior change.
2. **Wildcard issuance + derived projections** — config scope set, `charts/keycloak/templates/gateway.yaml`
   `dnsNames`/listener derived from the scope set, `sharedPublicHostFqdns`/retention-key re-keying, the
   `wildcard-edge` validation, and the `edge status` expiry observer. **This phase ends the manual-renewal
   problem for `vscode.resolvefintech.com`.**
3. **Parent→child handoff** — `Prodbox.Tls.CertHandoff` + the `transit/keys/prodbox-tls-envelope` Vault
   policy grant + the `cert-handoff` validation. Lands with the federation sprint.

## 9. Doctrine to update on adoption

- `documents/engineering/envoy_gateway_edge_doctrine.md` — reverse the "no wildcard public DNS" stance to
  wildcard-per-domain (path routing preserved).
- `documents/engineering/acme_provider_guide.md` — wildcard DNS-01 issuance and scope-set `dnsNames`.
- `documents/engineering/vault_doctrine.md` — formalize the `transit/keys/prodbox-tls-envelope` DEK lane
  and the `CertHandoff` custody record.
- `documents/engineering/cluster_federation_doctrine.md` — certificate custody / narrowing handoff as a
  first-class downstream-custody payload.

## 10. Standing rules

- ZeroSSL is the sole ACME provider; certificates are issued only through cert-manager's `zerossl-dns01`
  ClusterIssuer over DNS-01. **No dashboard-issued / portal / click-to-renew certificates** are part of the
  supported model — any that exist are drift and must be revoked.
- Renewal is cert-manager's responsibility; prodbox observes expiry fail-closed and never drives ACME
  renewal from the daemon.
- Every served public hostname must be a total projection of the managed scope set — a hostname served
  without a covering managed certificate must be impossible to represent, not merely discouraged.
