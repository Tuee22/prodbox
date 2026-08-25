# Analysis — `documents/engineering/shared_host_resource_protocol.md`

**Reviewed**: 2026-08-24, against worktree `2acb2c4` (clean).
**Subject**: `documents/engineering/shared_host_resource_protocol.md` (83 lines, `Status: Reference only`, marked not adopted).
**Method**: every factual claim the document makes was traced to source. Line references below are from the reviewed worktree and should be re-checked before being relied on.

---

## 1. Verdict

The document is honest about its own limits, correctly registered in the engineering index, and its headline claim about `cluster start` is **exactly right** — verified in source. Its §5 "Open before adoption" list is genuinely the right list, and its uncertified-decode claim is more precisely stated than the corresponding sentence in an Authoritative doctrine.

Three things are wrong with it:

1. **One factual claim is false** — prodbox does hold a machine-global lock (§3 below).
2. **The seam it proposes to attach to does not cover the problem it opens with.** §1 states the gap in `cluster start`; §3 attaches at a seam only `cluster reconcile` reaches. Three of the four production paths that start or arm `rke2-server.service` — one of them on the *teardown* path — never touch it.
3. **Roughly half its content restates two Authoritative doctrines** (`resource_scaling_doctrine.md` §2B/§2C and `host_platform_doctrine.md` §8) **without linking to either**, against the repository's own "Never Copy / Always Link" rule.

Adopting §3 as written would close about a quarter of the surface §1 opens, while §5 files the remainder under "cooperative between conforming invocations" without saying that it is most of the gap.

---

## 2. What the document gets right

### 2.1 The `cluster start` claim is literally true

`src/Prodbox/CLI/Rke2.hs:955-963`:

```haskell
Rke2Start ->
  requireLinux $
    runCommand
      Subprocess
        { subprocessPath = "sudo"
        , subprocessArguments = ["systemctl", "start", rke2ServiceName]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
```

with `rke2ServiceName = "rke2-server.service"` (`:569`), routed at `src/Prodbox/CLI/Spec.hs:558`.

Everything that runs before systemd, exhaustively: argv validation, `findRepoRoot` (two file-existence checks — `prodbox.cabal`, `DEVELOPMENT_PLAN/README.md`, `src/Prodbox/Repo.hs:48-53`), `materializeSchemaFilesIfStale`, and `requireLinux` (`src/Prodbox/CLI/Rke2.hs:9777-9781`).

Specifically absent: no settings load, no config validation, no prerequisite gate (`src/Prodbox/Native.hs:247-249` returns `[]` for `NativeRke2 _`), no retained-root marker read, no lock, no `is-active` probe, no wrapper unit.

### 2.2 The uncertified-decode claim is accurate and precisely stated

§5: "The production decode path compiles the plan uncertified, so the figure available to convert is an arithmetic fit rather than a measured profile."

Confirmed. The single production decode boundary is `src/Prodbox/Settings.hs:1133-1136`:

```haskell
    allocatedPlan <-
      mapLeft
        Allocation.renderCompileError
        (Allocation.compileResourcePlanUncertified (resource_plan (capacity config)))
```

and `compileResourcePlanUncertified = compileResourcePlan [] (const Text.empty) 0` (`src/Prodbox/Capacity/Allocation.hs:504-505`), so `certifyWorkload` hits `Nothing -> Right WorkloadUncertifiedUntilFirstProfile` for every workload (`:295`). The certified form appears only in tests (`test/unit/Allocation.hs:238,248`).

Stronger than the document says: `dhall/capacity/measured/` contains **only `Schema.dhall`** — zero committed profiles — so the `dev check` certification gate (`src/Prodbox/CheckCode.hs:1750-1754`) is inert regardless.

The "arithmetic fit" characterization is also exact. The CPU "demand" is a restatement of authored millicores: `src/Prodbox/Capacity/Config.hs:412-420` sets `requests_per_second = milli_cpu req`, `service_cpu_micros = 1000`, `cpu_headroom_ppm = 0`, and `derivedCpuRequest` (`src/Prodbox/Capacity/Derivation.hs:57-64`) folds it straight back to `milli_cpu req`.

### 2.3 The cleanup-evidence premise is well-founded — and the machinery is better than claimed

§5: "prodbox needs its existing cleanup evidence to gate the release, and must hold rather than release whenever that evidence is partial or unavailable."

The evidence family is proof-carrying, surface-indexed, and deliberately non-convertible — `src/Prodbox/Lifecycle/Teardown/CascadeEvidence/Internal.hs:1321-1339`, whose own comment reads "There is deliberately no conversion in either direction, and neither constructor is reachable outside this module." `ReadyToUninstallEvidence` (`:775-779`) carries a one-shot `LocalCompletionPermitId`.

The "partial or unavailable" distinction the document asks for already exists as first-class constructors:

```haskell
-- src/Prodbox/Lifecycle/Teardown/Observation.hs:67-82
data ExactObservationResult
  = ExactResourceAbsent      !AbsenceEvidence
  | ExactResourcePresent     !ExactResourceInventory
  | ExactResourcePartial     !PartialEvidence !(NonEmpty ObservationFailure)
  | ExactResourceUnobservable !(NonEmpty ObservationFailure)
```

with the same discipline in `LocalCompletionObservation` (`src/Prodbox/Lifecycle/HostCleanupCompletion.hs:697-704`, whose comment explicitly refuses to collapse `Unobservable` into `Missing`) and in `residueBlocksTeardownGate` — "present OR unreachable → block" (`src/Prodbox/Lifecycle/ResidueStatus.hs:60`). That module's header records the incident that produced the rule: treating `ResidueUnreachable` as absent let `cluster delete --yes` pass on a degraded cluster, after which `rm .data` orphaned live AWS resources.

### 2.4 Index registration and header metadata are correct

Registered twice — `documents/engineering/README.md:78` (Documents table) and `:193` (Quick Navigation → Resource Governance). The `:78` summary is unusually good: it names the standing `systemctl start` gap in the summary itself.

`Status: Reference only` is in the closed set enforced by `checkGovernedDocStatusValues` (`src/Prodbox/CheckCode.hs:5440-5446, 5490`). `Supersedes: N/A` and `Generated sections: none` are correct. The one outbound link `../../DEVELOPMENT_PLAN/README.md#resume-here` resolves, and the anchor is real (`DEVELOPMENT_PLAN/README.md:15`).

**The file passes `prodbox dev check` today.** Every defect below is a review obligation, which is what `documents/documentation_standards.md:427-430` says the enforcement boundary is.

---

## 3. Defect — "Every lock it takes lives beneath the repository-local retained root" is false

§1's second sentence is wrong. There is one POSIX advisory write lock whose artifact sits at a fixed machine-global path.

`src/Prodbox/Gateway/Emitter/Journal.hs:389` locks `canonicalRoot </> ".emitter.journal.lock"`. On the home substrate that root is a fixed hostPath:

- `src/Prodbox/Gateway/Emitter/Persistence.hs:64` — `homeJournalRoot = "/var/lib/prodbox/gateway-emitter-journals"`
- `src/Prodbox/Gateway/Emitter/Persistence.hs:77-79` — `SubstrateHomeLocal -> HomeNodePinnedHostPath (homeJournalRoot </> Text.unpack node)`
- `charts/gateway/templates/deployments.yaml:141-148` — `hostPath: path: {{ $emitter.journal.hostPath }} type: DirectoryOrCreate`
- `charts/gateway/values.yaml:112,118,124` — `/var/lib/prodbox/gateway-emitter-journals/node-{a,b,c}`

So the lock is physically at `/var/lib/prodbox/gateway-emitter-journals/node-a/.emitter.journal.lock` on the operator's machine — keyed by node id, not by repository, not derived from `manual_pv_host_root`. Two checkouts on one machine collide on it.

The other four locks are correctly repo-local:

| Lock | Path construction |
|---|---|
| `.cluster-established.lock` | `src/Prodbox/Config/LocalRetainedRoot/Internal.hs:368` |
| `.host-cleanup-intent.lock` | `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:289` |
| execution-lease lock | `src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs:1213` |
| `.test-artifact-intents.lock` | `src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs:214-217` |

Escape from the repo root is actively refused (`src/Prodbox/Config/LocalRetainedRoot/Internal.hs:679-694`, "configured root escapes the canonical repository").

**The useful form of this finding**: prodbox's only machine-global mutual-exclusion primitive already exists — at the emitter-journal layer, by accident of a `DirectoryOrCreate` hostPath mount, rather than at the layer §1 needs it.

### 3.1 Related: the document has no claim-keying story

prodbox's machine identity is `"prodbox-" ++ machineId`, read from `/etc/machine-id` (`src/Prodbox/CLI/Rke2.hs:9583-9596`) and stamped into the cluster at `:9151-9177`. **Two checkouts on one machine derive the same id.** So prodbox's existing identity cannot distinguish the two participants §1 names, and the document never says how a claim would be keyed.

---

## 4. Defect — the attachment seam does not cover the stated problem

`compileResourcePlanAgainstObserved` has two production call sites. The mutating one is `ensureRke2ResourceGuardrails` (`src/Prodbox/CLI/Rke2.hs:8686`), reached only as `StepRke2ResourceGuardrails` → `HostPrepBefore ComponentClusterBase` (`:1637`), first in the bootstrap step list (`:1690-1702`). That step exists **only on the reconcile path**.

(The other site, `:1094`, is read-only `cluster status` — and it compiles `Capacity.defaultResourcePlan`, not the deployed config, `:1056-1058`.)

Four production paths start or arm the unit:

| # | Path | Site | Passes the seam? |
|---|---|---|---|
| 1 | `prodbox cluster start` | `src/Prodbox/CLI/Rke2.hs:955-963`; `Spec.hs:558` | **No** |
| 2 | `prodbox cluster restart` | `src/Prodbox/CLI/Rke2.hs:973-981`; `Spec.hs:560` | **No** |
| 3 | `cluster reconcile` — `StepRke2ServerInstalled` (`enable`) + `StepRestartRke2Service` (`restart`) | `src/Prodbox/CLI/Rke2.hs:2035-2047` | Yes |
| 4 | teardown recovery-repair — `systemctl enable --now rke2-server.service` | `src/Prodbox/Lifecycle/Teardown/RecoveryRepairProduction.hs:447-449` | **No** |

Path 4 counts twice: it is on the *teardown* path, and its `enable` is what arms the boot-start. Reconcile does the same at `:2039`, and `src/Prodbox/Config/LocalRke2RecoveryState/Internal.hs:690` expects `/etc/systemd/system/multi-user.target.wants/rke2-server.service`. **prodbox itself authors the "reboot" bypass vector §1 names.**

### 4.1 The typed refusal §3 proposes is new work, not reuse

§3 says participation "adds one more reason for it to refuse, and adds it in the one place a refusal is already expected" — implying reuse of an existing typed channel.

The typed failure exists (`src/Prodbox/Capacity/Allocation.hs:380-381`):

```haskell
  | ObservedHostDimensionInsufficient Text Natural Natural
  | ObservedHostSharedStorageInsufficient Natural Natural
```

but it does not survive the seam. `ensureRke2ResourceGuardrails` lowers it immediately through `failWith`, which is one bit (`src/Prodbox/CLI/Rke2.hs:9783-9786` → `ExitFailure 1`). "A typed outcome distinguishing a momentarily contended machine from one that cannot fit the request at all" has to be built.

### 4.2 The seam is not a pure check

After the check passes, the same function writes root-owned host files and reloads systemd (`src/Prodbox/CLI/Rke2.hs:8709-8730`): `/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml`, `/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf`, then `sudo systemctl daemon-reload`.

"Before reconcile mutates anything" is true. "The seam is a check" is not — a ledger read placed there sits inside a function that then mutates `/etc`.

---

## 5. Defect — the cleanup deadlock

§3: "read the ledger before any host or cluster mutation."
§5: "prodbox needs its existing cleanup evidence to gate the release, and must hold rather than release whenever that evidence is partial or unavailable."

Teardown *is* a host mutation. Composed, those rules are circular:

```
ledger refuses
  -> no host mutation permitted
  -> cleanup cannot run
  -> no cleanup evidence
  -> claim cannot be released
  -> contention persists
  -> ledger refuses
```

This is not hypothetical: start path 4 above is literally on the teardown path. Any claim protocol needs an explicit carve-out that release-directed work is always admitted. The document has none and does not name the hazard.

---

## 6. Defect — "No enforcement changes" is not sustainable

### 6.1 The over-claim is already inside prodbox's own proof, one layer in from where §2 puts it

§2 cautions that reinterpreting the authored physical-host figure as an allocation "would let the in-cluster scheduler reason about more capacity than the outer claim permits."

The Kubernetes scheduler never reads `host_capacity`:

- kubelet allocatable comes from `rke2_reserved` / `eviction_floor` only — `renderRke2ResourceGuardrailConfig`, `src/Prodbox/CLI/Rke2.hs:8596-8616`; the systemd drop-in, `:8618-8631`
- `ResourceQuota` / `LimitRange` are derived from per-namespace workload draws — `src/Prodbox/Capacity/Placement.hs:39-60`, called at `src/Prodbox/CLI/Rke2.hs:7975-7990`
- nothing feeds `host_capacity` to kube-scheduler

The over-claim happens earlier. `config generate` sets `host_capacity` to the **whole observed machine** on the CPU and memory axes — `src/Prodbox/Capacity/HostProbe.hs:135-136`:

```haskell
  fitAxis label available required
    | required <= available = Right available    -- the machine, not the demand
```

with the header comment at `:87-90` saying so outright ("CPU and memory are declared at the observed capacity"). Then `compileResourcePlan` computes the allocatable from it (`src/Prodbox/Capacity/Allocation.hs:459-470`):

```haskell
  host      <- mkHostCapacity (host_capacity plan)
  let reservation = rke2_reserved plan `plusResourceVector` eviction_floor plan
  reserved  <- reserveCluster host reservation
  threaded  <- foldM allocate reserved (Placement.concurrentPlanDraws plan)
```

So prodbox's internal allocatable is already "the entire machine minus RKE2's reservation." A charge derived from `host_capacity` would claim 100% of the machine and make the ledger useless for sharing. **The correct charge already exists as a local in `deriveHostFittingCapacity`** — `demand = rke2_reserved + eviction_floor + Σ concurrentPlanDraws` (`src/Prodbox/Capacity/HostProbe.hs:101-104`). Naming it would make §2's "one conversion, never authored a second time" concrete rather than aspirational.

### 6.2 Ring 3 is blind to claims by construction, and making it claim-aware contradicts owned doctrine

`observeHostCapacity` reads the **physical** machine — `nproc`, `/proc/meminfo` `MemTotal`, `df -Pm` for the kubelet root and the retained-PV path (`src/Prodbox/Capacity/HostProbe.hs:56-85`). Another project's claim does not shrink that observation, and `compileResourcePlanAgainstObserved` compares authored `host_capacity` against it (`src/Prodbox/Capacity/Allocation.hs:536-546`).

So bolting a ledger read next to Ring 3 does not make Ring 3 claim-aware. You would have to make the *observation* grant-aware — `observed = min(physical, granted)` — which changes what `ObservedHostRoot` means.

That collides with a currently-Authoritative owned statement: **`documents/engineering/host_platform_doctrine.md § 8` is titled "Host Capacity Is Observed, Not Configured"** (`:237-256`). A grant is precisely a configured quantity, authored by the machine's operator. §4's "What is not changed" does not acknowledge this, and it is the largest doctrinal cost of adoption.

### 6.3 §2's own caution about non-Kubernetes demand is unmeetable today

§2: "the derivation must include what sits outside Kubernetes — host-native processes, retained artifacts, provider scratch."

Correct as a warning. Two of the three are not modelled anywhere:

- **Host-native processes** — `docker build` / `docker push` run host-native (`documents/engineering/local_registry_pipeline.md:79,303`); no capacity accounting for them exists in `src/`.
- **Provider scratch is RAM** — `withRamScratch` places the decrypted Pulumi checkpoint tree in `/dev/shm` when present (`src/Prodbox/Pulumi/EncryptedBackend.hs:1524-1539`). Unbudgeted memory on the shared host, entirely outside `ResourcePlan`.
- **Retained artifacts** — modelled, but through a hardcoded table. `durableSizeFor` (`src/Prodbox/Capacity/Config.hs:399-408`) gives a non-zero durable draw to exactly six profiles (`vscode`, `keycloak-postgres`, `minio`, `pulsar`, `vault`, `lifecycle-authority`) and `withDurable` forces every other profile to `0`. `harbor` authors `ResourceVector 200 256 512 1024` (`:250`) and is charged **0** durable — the registry's on-disk bytes are uncounted.
- **The prodbox CLI process itself** — not modelled. `RuntimeMemoryProfile` exists only for `gateway` (`src/Prodbox/Capacity/Config.hs:157-178`) and is bounded against the *container* limit, not the host.

This material belongs in §5 (open before adoption), not in §2 as a design caution, because the data does not exist to satisfy it.

### 6.4 There is also a plain internal tension

§2 worries the scheduler could exceed the claim. §4 says the claim imposes no limit, which makes exceeding it meaningless. One of the two needs qualifying.

---

## 7. Defect — the claim entry is not a new category; three machine-global files already leak

§4's first bullet ("The repository-local retained root remains prodbox's only repository-local retained root. The ledger lives on the machine, holds no prodbox bytes, and is not deleted by any prodbox teardown") is defensively worded and technically true, but it invites the reader to conclude prodbox writes nothing outside its repository.

prodbox already writes three prodbox-named files into `/etc`, none with a prodbox delete site:

| Path | Defined | Written | Delete site |
|---|---|---|---|
| `/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml` | `Rke2.hs:543-544` | `:8715` | none in prodbox |
| `/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf` | `Rke2.hs:571-572` | `:8720` | none in prodbox |
| `/etc/sysctl.d/99-prodbox-inotify.conf` | `Rke2.hs:562-563` | `:8771` | **none anywhere** |

(The two RKE2-scoped files may be swept incidentally by the vendor `rke2-uninstall.sh`. The inotify drop-in is prodbox-only and is removed by nothing.)

A ledger claim entry would be a fourth member of this existing, already-unowned class. That is a stronger and more useful framing than "we have no row for this," because it names a defect that exists today — and it is the same "a claim is only as good as the release" problem §5 raises, already present.

It also sharpens the obligation. Under `documents/engineering/lifecycle_reconciliation_doctrine.md` § 3.1, a claim would need exact-keyed desired absence and a three-valued `Unreachable → refuse` observation. None of that vocabulary appears in the document.

### 7.1 A precision on §5's own wording

§5 says "No sprint, no component-inventory row, and no cleanup owner exists for this work." Verified true for the ledger participation — but `DEVELOPMENT_PLAN/system-components.md:85` **does** carry a row for resource scaling and capacity placement, listing the modules involved. What has no row is the participation, not the seam.

Also, the sentence *asserts* plan state rather than linking to it. `documents/documentation_standards.md:22-27` reserves phase order, blockers, and cleanup ownership to the Development Plan and requires documents to "link back to the development plan instead of maintaining competing status ledgers." It is true today and will silently rot.

---

## 8. Defect — the cheaper alternative is never considered

The document moves directly from "prodbox holds no machine-wide lock" to "participate in another project's ledger," skipping the option that requires no external dependency.

**prodbox already owns a systemd drop-in on the exact unit** — `/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf` (`src/Prodbox/CLI/Rke2.hs:571-572`, written at `:8720`). Its content is purely `[Service]` resource accounting — `CPUAccounting`, `MemoryAccounting`, `CPUQuota`, `MemoryHigh`, `MemoryMax`, `TasksMax` (`:8618-8631`). There is no `ExecStartPre`, no `ConditionPathExists`, no `AssertPathExists`, no `Conflicts=`.

§1's "not a wrapper unit, a drop-in guard, or a marker" therefore survives as literally true, but it understates the surface — a reader who checks that path *will* find a drop-in there.

An `ExecStartPre` in that same file is the one intercept that covers **all four** start paths, plus a direct operator `systemctl start`, plus the boot-start — because systemd enforces at the unit rather than at a command. It composes with a ledger rather than competing with it, and it closes the vectors §5's final bullet declares permanently open. The document should evaluate it and either adopt it as the first step or reject it with a stated reason.

Caveat worth recording alongside it: the drop-in is written to a fixed path by byte-compare-then-`sudo cp` (`writeRootFile`, `src/Prodbox/CLI/Rke2.hs:9513-9531`), so a second checkout would simply overwrite it. Any guard placed there needs to be checkout-independent — which loops back to the claim-keying gap in §3.1.

---

## 9. Defect — the named authority does not exist

§2 grounds the entire protocol in an external authority: "Its authority is the installed root and the `spec-version` that root carries — never a copy of a document in any repository, including this one."

Checked:

- **No installed root.** Nothing matching a claim ledger under `/etc` or `/var/lib` on this machine.
- **No sibling specification.** None of `~/amoebius`, `~/hostbootstrap`, `~/jitML`, `~/daemon-substrate`, `~/infernix` defines this protocol or uses the `Persistent` / `Transient` claim-kind vocabulary.
- **`spec-version` appears exactly once in the entire prodbox repository** — line 17 of this document. Zero hits in `src/`, `app/`, `test/`, `DEVELOPMENT_PLAN/`, `dhall/`, `charts/`.
- **"ledger" and "claim" in prodbox mean other things** — the `Resume Here` execution ledger, the in-cluster global target-intent ledger (`src/Prodbox/Lifecycle/TargetCommitInterpreter.hs:89,114-116`), the Authority submission ledger (`src/Prodbox/Lifecycle/Authority/ClientRegistry.hs:362-364`); and JWT/OIDC claims, `PersistentVolumeClaim`, cleanup-run ownership claims, gateway anchor claims. Zero hits for `hostClaim`, `claimResource`, `resource.?claim`, or `claim.?protocol` anywhere.

So §2's load-bearing sentence — "`Persistent` is the correct kind and **the weaker one is not available**" — is currently unverifiable against its own named authority.

This does not make the document wrong. It makes it a promise to a specification with no discoverable definition, which is a shorter-lived kind of artifact than the neighbouring doctrine, and the header should say so.

---

## 10. Doctrine and documentation hygiene

### 10.1 Duplication without linking — the most load-bearing gap

Three of the document's claims restate material already owned elsewhere:

| Document claim | Already owned by |
|---|---|
| §3, the observed-host recheck at reconcile | `resource_scaling_doctrine.md:194-232` (§2B rule b), `:258` (§2C Ring 3); `host_platform_doctrine.md:237-256` (§8); `lifecycle_reconciliation_doctrine.md:1606-1635` (§5a.2, which names both written file paths) |
| §2, the authored physical-host figure vs. allocation | `resource_scaling_doctrine.md:232-247` (host-fitting generation) |
| §5, the production decode compiles uncertified | `resource_scaling_doctrine.md:257` (§2C Ring 2 row states it nearly verbatim) |

The document cites **none of them**, and has no `## Cross-References` section (33 of 42 engineering documents have one). `documents/documentation_standards.md` §5 is "Never Copy / Always Link."

The genuinely new content is small but real: §1's no-machine-wide-lock observation, §2's `Persistent`-vs-`Transient` argument, and §3's contended-vs-cannot-fit refusal typing. Everything else should be a link.

### 10.2 `> **Not adopted.**` is a ninth marker spelling, and a regression

`documents/documentation_standards.md:391` blesses one marker — `> **Target.**`, with `**Current revision.**` as its counterpart. `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md:1304` carries a live `Pending Removal` row about exactly this accumulation:

> "Eight competing spellings for one marker, where Sprint `0.31` blessed a single convention. … Every surviving alternate spelling is a second way to say the same thing, which is how eight of them accumulated in the first place, and a future mechanical scan can only anchor on one line form."

`> **Not adopted.**` is the ninth, and the only occurrence of that string in the repository. It is a **regression**: the previous revision of this same file (`cea6305`) used the compliant marker.

The marker-spelling gate that `documentation_standards.md:427-430` names is **not implemented** — no such check exists in `CheckCode.hs` — so nothing caught it.

### 10.3 `Status: Reference only` contradicts its own definition

`documents/documentation_standards.md:88` defines the value as "Points to authoritative sources." This document originates its content and simultaneously disclaims it. It is the only non-index `Reference only` document in the repository; the other four are two directory indexes, a generated command reference, and a before/after patterns catalog.

**No legal `Status:` value describes an unadopted proposal.** That is a gap in the standard, not only in the document. `documents/engineering/README.md:20-24` permits "a target before cutover" — which presupposes a planned cutover. A document whose own §5 says no sprint owns the work is not that.

### 10.4 Zero references from the Development Plan

Counting references from `DEVELOPMENT_PLAN/*.md` to each of the 42 engineering documents: this is the **only one with zero**. Every other document has at least one. It appears in no phase's `Documentation Requirements` (Standard G, `DEVELOPMENT_PLAN/development_plan_standards.md:118-123`) and in no `system-components.md` row (Standard F, `:107-116`).

### 10.5 Formatting

- **The Purpose blockquote renders as a run-on.** There is no blank `>` between line 8 and line 9, so `**Read this if**:` is a lazy continuation of the Purpose paragraph and renders inline with it.
- **`**Read this if**` and `## Contents` each appear exactly once repo-wide** — in this file. Two zero-precedent conventions; no other governed document carries a TOC in any form, and the documentation standard never mentions one.
- Line wrap is ~110 columns against a ~100 house norm. No markdown lint exists in the repository (no `.markdownlint*`, no `.mdlrc`), so this is style, not rule.

### 10.6 Silent scope gaps

Nothing on the AWS substrate (probably out of scope — but say so). Nothing on how `prodbox test all`, which cycles clusters repeatedly, would behave holding a `Persistent` claim on a shared machine.

---

## 11. File history — why the document reads the way it does

Three rewrites in seven hours on 2026-08-24, all authored by Matt Nowak, all with the commit message `development`:

| Commit | Time | Change |
|---|---|---|
| `b0804fa` | 15:27:41 | Added at **869 lines**, titled *Finite Resource Execution Authority Protocol*, `Status: Authoritative source`, header metadata buried inside a `<details><summary>Link-graph metadata</summary>` block, cross-project scope ("amoebius and its seed projects"). Landed **alone** — no index row, no plan update. |
| `cea6305` | 19:52:43 | Rewritten to **1883 lines**, retitled *Shared Host Resource Protocol*, downgraded to `Reference only`, index row added, using the **compliant** `> **Target.**` marker. |
| `2acb2c4` | 22:12:47 | Cut to **83 lines**, index row rewritten wholesale, `> **Target.**` replaced with `> **Not adopted.**`. |

A root-level `SHARED_HOST_RESOURCE_PROTOCOL_ANALYSIS.md` scratch file was added and deleted twice across that sequence (`aab2137` add, `cea6305` delete, `9f0c9e2` re-add, `2acb2c4` delete).

What survives is the residue of a much larger cross-project proposal. That explains both the terseness and the missing links, and it is why the remaining claims are worth re-checking rather than inherited.

---

## 12. Findings unrelated to this document

Three defects surfaced during verification that stand on their own.

### 12.1 A stale sentence in an Authoritative doctrine

`documents/engineering/lifecycle_reconciliation_doctrine.md:1620-1623` (§5a.2) says the reconcile proof is "built by the total `compileResourcePlan`". The value actually consumed at that seam is `validatedAllocatedPlan settings`, built by `compileResourcePlanUncertified` (`src/Prodbox/Settings.hs:1136`). `resource_scaling_doctrine.md:257` carries the corrected version.

**The document under review is right and the lifecycle doctrine is stale.**

### 12.2 Three unowned machine-global `/etc` files

The table in §7 above. No prodbox delete site for any of them; `/etc/sysctl.d/99-prodbox-inotify.conf` is removed by nothing, anywhere. Closing this is a `lifecycle_reconciliation_doctrine.md` §3.1 managed-resource question (exact-keyed desired absence, three-valued observation), not a one-line `rm`.

### 12.3 Four unguarded `rke2-server.service` start paths

The table in §4 above. prodbox holds no host-level exclusion on the unit, and two of the four paths `enable` it for boot — so prodbox creates a reboot-start it cannot then observe. Real and worth working whether or not any claim ledger is ever adopted.

### 12.4 The relative-link lint never verifies anchors

`relativeLinkResolves` (`src/Prodbox/CheckCode.hs:5332-5338`) does `pathPart = takeWhile (/= '#') …` before resolving. Every `#anchor` in every governed document is unchecked. Noted because §10.1's remedy adds several.

---

## 13. Recommended disposition

**Shrink the document to what is genuinely new, and link the rest.**

1. **§1** — retract the lock claim and cite the emitter-journal lock; replace the single `cluster start` example with the four-site table; note that prodbox itself arms the reboot vector; soften "not a drop-in guard" to say what is actually in the drop-in; add the `/etc/machine-id` claim-keying gap.
2. **§2** — name `rke2_reserved + eviction_floor + Σ concurrentPlanDraws` (`HostProbe.hs:101-104`) as the charge; move the over-claim from "the in-cluster scheduler" to `reserveCluster` (`Allocation.hs:459-470`); move the outside-Kubernetes caution to §5.
3. **§3** — state that the seam is reconcile-only and covers 1 of 4; that the typed refusal is new work; that the seam then mutates `/etc`; add the release-work carve-out that resolves the deadlock; add the `ExecStartPre` alternative.
4. **§4** — retract "No enforcement changes"; record the `host_platform_doctrine.md` §8 tension; replace the retained-root implication with the three existing `/etc` files.
5. **§5** — add the unmodelled-demand items, the missing ledger root, and the `system-components.md:85` precision; rewrite the plan-state sentence as a link.
6. **Hygiene** — restore `> **Target.**`; fix the Purpose blockquote separator; drop `## Contents` and `**Read this if**`; add `## Cross-References` to `resource_scaling_doctrine.md` §2B/§2C, `host_platform_doctrine.md` §8, `lifecycle_reconciliation_doctrine.md` §3.1, `storage_lifecycle_doctrine.md` §7, and `documents/documentation_standards.md`.
7. **Separately** — correct §12.1 in place with a dated note, and open two `Unowned` `Pending Removal` rows for §12.2 and §12.3 (recount the ledger tables mechanically; do not carry the published totals forward).

Keep `Status: Reference only` — it passes `checkGovernedDocStatusValues` — and note the definitional gap in the header rather than inventing a sixth status value.

---

## 14. How to re-verify

Documentation-only work; the doc gate is the verification.

```bash
# from /home/matthewnowak/prodbox
prodbox dev lint docs                                     # header <-> markers <-> registry + links
grep -rn 'Not adopted' documents/
grep -rn 'shared_host_resource_protocol' documents/ DEVELOPMENT_PLAN/
```

Re-check the citations directly — `documents/documentation_standards.md:411-413` requires enforcement claims to name the function, and the link lint strips anchors, so `§`-anchors must be checked by hand:

```bash
sed -n '955,963p;973,981p;2035,2047p;8686,8730p' src/Prodbox/CLI/Rke2.hs
sed -n '447,449p'          src/Prodbox/Lifecycle/Teardown/RecoveryRepairProduction.hs
sed -n '101,107p;133,136p' src/Prodbox/Capacity/HostProbe.hs
sed -n '385,392p'          src/Prodbox/Gateway/Emitter/Journal.hs
sed -n '61,79p'            src/Prodbox/Gateway/Emitter/Persistence.hs
sed -n '459,470p'          src/Prodbox/Capacity/Allocation.hs
sed -n '1133,1136p'        src/Prodbox/Settings.hs
```

`prodbox dev check` is not required for documentation-only edits, and it does not run `test integration` in any case.
