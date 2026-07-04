# Host Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, documents/engineering/cluster_topology_doctrine.md
**Generated sections**: none

> **Purpose**: Define how the `prodbox` binary classifies the host it runs on and reaches a Linux
> frame on every OS — a per-OS host-provider model, mirrored in kind from the operator's
> `hostbootstrap` library, that makes "run a Linux cluster tool on a non-Linux host without a VM"
> unrepresentable.

## 1. Scope and Posture

This document owns the **host** side of the boundary: what the machine `prodbox` runs on *is*, and
how the host-native binary descends into a Linux execution frame where Docker, RKE2, and kind
actually run. It does **not** own what a cluster is — node roles, control-plane/worker topology, and
the cluster-scoped substrate identity (`SubstrateHomeLocal` / `SubstrateAws`) are owned by
[cluster_topology_doctrine.md](./cluster_topology_doctrine.md). The host substrate here is a fact
about the operator's machine; the cluster substrate there is a fact about the Kubernetes control
plane the binary manages. They are orthogonal axes.

prodbox is the proven single-node specialization the amoebius umbrella substrate doctrine cites and
generalizes: "the substrate is a fact about the host, not a knob." prodbox mirrors the operator's
`hostbootstrap` library **in kind** — the Haskell value types below reproduce
`HostBootstrap.Substrate`, `HostBootstrap.HostTool`, `HostBootstrap.Lift`, and
`HostBootstrap.Ensure` structurally, with **no code dependency**. This is the mirror-now,
refactor-onto-`hostbootstrap`-later posture already established for the registry-credential seam in
[local_registry_pipeline.md § 6.1](./local_registry_pipeline.md#61-host-docker-cli-auth-isolation-harbor-login-vs-the-operators-docker-hub-login).

Sprint `1.52` landed the multi-OS host-provider config/detection surface: the `HostSubstrate`
detector, the closed `HostTool` / `AbsExe` surface, the `LiftLayer` fold, pure host-gated
reconciler plans, the rule-j Docker host-frame gate, and the `host_substrate_supported`
prerequisite root. Sprint `4.37` landed the provider reconciler selection, idempotent
ready/missing/reboot decisions, wrong-provider fail-fast refusal, and Docker Linux-frame dispatch
for native-arch build work. Live macOS-Lima and Windows-WSL2 provisioning on those hosts remains a
non-blocking proof axis. Status lives only in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md); this doc states the target shape.

## 2. The Host Substrate Is Detected, Never Configured

The first thing the binary does on a new machine is find out what the machine is. A `HostSubstrate`
is classified from `System.Info` reads plus an NVIDIA probe — it is not a Dhall knob, and no
`prodbox` binary reads a `PRODBOX_*` variable to override it
([config_doctrine.md](./config_doctrine.md)). The classification core is pure so it is unit-testable
without a host; the only `IO` is the reads that feed it (mirroring `HostBootstrap.Substrate.detect`).

```haskell
-- Example: the closed host-substrate enum prodbox mirrors from HostBootstrap.Substrate
data HostSubstrate = AppleSilicon | LinuxCpu | LinuxGpu | WindowsCpu | WindowsGpu
  deriving (Eq, Show)

-- Pure classification: OS from System.Info.os, arch from System.Info.arch, gpu
-- from an NVIDIA probe. Intel-mac is rejected BY CONSTRUCTION — there is no
-- Apple-x86 constructor to return, so a non-arm64 darwin host is a hard Left.
classifyHost :: String -> String -> Bool -> Either String HostSubstrate
classifyHost osName rawArch gpu = case map toLower osName of
  "darwin"  -> if isArm64 rawArch
                 then Right AppleSilicon
                 else Left "prodbox supports Apple Silicon (arm64) only on macOS"
  "linux"   -> Right (if gpu then LinuxGpu else LinuxCpu)
  "mingw32" -> Right (if gpu then WindowsGpu else WindowsCpu)
  other     -> Left ("unsupported host platform: " ++ other)
```

`AppleSilicon` is `arm64`-only: the illegal "Intel-Mac substrate" is unrepresentable because
`classifyHost` has no arm that yields an Apple constructor for a non-`arm64` machine — the
smart-constructor discipline of [pure_fp_standards.md](./pure_fp_standards.md) applied to host
classification, where an invalid host is a `Left`, not a warning.

## 3. Host Tools Are a Closed Enum Resolved to Absolute Paths

Every external tool the host binary shells out to is a constructor of a closed `HostTool` type, and
every invocation reads an absolute path. Windows-only tools are `CPP`-gated so they do not exist as
resolvable constructors off-Windows (mirroring `HostBootstrap.HostTool`).

```haskell
{-# LANGUAGE CPP #-}
-- Example: closed host-tool enum; Windows-only entries compiled only on Windows
data HostTool = Docker | Rke2 | Kubectl | Helm | Kind | Sudo | Sysctl | Limactl | Incus
#ifdef mingw32_HOST_OS
              | Wsl | Bcdedit
#endif
  deriving (Eq, Ord, Show)

-- A resolved tool is an absolute path BY TYPE: the constructor is not exported,
-- and mkAbsExe rejects a bare command name (mirrors HostBootstrap.HostTool.AbsExe).
newtype AbsExe = AbsExe { absExePath :: FilePath }
mkAbsExe :: FilePath -> Either String AbsExe
mkAbsExe fp
  | isAbsolute fp = Right (AbsExe fp)
  | otherwise     = Left ("not an absolute path: " ++ fp)
```

A bare command name is used only for discovery, never as an invocation target — the host binary
never resolves a tool against the host's own `$PATH`.

## 4. The Lift: Everything Docker-Inward Is OS-Agnostic Linux

Crossing an OS boundary is the binary re-invoking a subcommand of *itself* inside a Linux frame. The
frame is one layer of a `LiftLayer` stack, folded by a **pure** `foldHostLift` into a host
invocation (mirroring `HostBootstrap.Lift`).

```haskell
-- Example: the host-provider lift. Only the outermost launcher is OS-specific.
data LiftLayer
  = ViaVM IncusVM       -- Linux: a nested Incus VM (or no layer at all → native)
  | ViaLimaVM LimaVM    -- macOS: a Lima-managed Ubuntu 24.04 VM
  | ViaWsl2VM Wsl2VM    -- Windows: a WSL2 Ubuntu 24.04 distro
  | ViaContainer ContainerLift
  deriving (Eq, Show)

foldHostLift :: SelfRef -> [LiftLayer] -> [String] -> HostDispatch
```

**The load-bearing invariant: everything Docker-inward is OS-agnostic Linux.** Only the pre-binary
launcher and the per-provider argv builder (`limactl shell … --`, `wsl -d … --`, `incus exec …`)
are OS-specific. Once inside the Linux frame the binary runs Docker, RKE2, kind, and its own
subcommands with the *guest's* bare `$PATH` names — the absolute-path rule (§3) governs the **host**
invocation surface only. The Ubuntu-24.04 VM the Apple/Windows providers synthesize is an ordinary
Linux host to every layer above it: the same charts, the same `cluster reconcile`, the same chart
platform.

## 5. Illegal States This Doctrine Owns

The frame a Linux cluster tool must run in is not a free-form argument checked at a call site — it is
computed by a single total function whose type range excludes the illegal cases. These are the rules
this doc owns; each is discharged by construction, not by a runtime guard.

### Rule a & Rule b — RKE2 on Apple/Windows admits only a VM frame

```haskell
-- Example: the only way to obtain the frame for a Linux cluster tool (rke2/kind).
-- It is exhaustive and total; there is NO arm that returns a host-direct
-- (empty) context for Apple or Windows, so "rke2 on Apple without a VM"
-- (rule a) and "rke2 on Windows without WSL2" (rule b) are unconstructible.
clusterFrame :: HostSubstrate -> [LiftLayer]
clusterFrame AppleSilicon = [ViaLimaVM defaultLimaVM]   -- rule a: Lima VM mandatory
clusterFrame WindowsCpu   = [ViaWsl2VM defaultWsl2VM]    -- rule b: WSL2 mandatory
clusterFrame WindowsGpu   = [ViaWsl2VM defaultWsl2VM]    -- rule b
clusterFrame LinuxCpu     = []                           -- native Linux frame, host-direct OK
clusterFrame LinuxGpu     = []                           -- native Linux frame
```

Because `clusterFrame` is the *only* source of a cluster-tool frame and it never returns `[]` for an
Apple or Windows host, a host-direct arm `rke2` invocation on those substrates cannot be written. The
guarantee is structural — the same "make the illegal state unconstructible over checking it" move the
lifecycle registry uses for creatable-but-undiscoverable resources
([lifecycle_reconciliation_doctrine.md § 3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)).

### Rule j — host-frame `docker run` is OS-gated

The host binary running `docker run --rm` directly is valid only where the host frame *is* Linux. On
macOS or Windows the host binary has no Linux Docker frame; host-frame Docker fails fast, and a real
`docker run` happens only *inside* the Lima or WSL2 frame. This mirrors the fail-stub shape of
`HostBootstrap.Registry.withEphemeralDockerConfig` — the seam prodbox mirrors as
`Prodbox.DockerConfig.withEphemeralDockerConfig`
([local_registry_pipeline.md § 6.1](./local_registry_pipeline.md#61-host-docker-cli-auth-isolation-harbor-login-vs-the-operators-docker-hub-login)).

```haskell
-- Example: host-frame docker is OS-gated. On non-Linux hosts it fails rather
-- than materialize a host DOCKER_CONFIG outside the Linux lift frame.
withHostDocker :: (AbsExe -> IO a) -> IO a
withHostDocker act = do
  substrate <- detectHostSubstrate
  case substrate of
    Right LinuxCpu -> resolveHostTool Docker >>= act
    Right LinuxGpu -> resolveHostTool Docker >>= act
    Right other -> fail ("host-frame docker is unavailable on " ++ renderHostSubstrate other)
    Left err -> fail err
```

## 6. Ensure Reconcilers Are Host-Gated and Fail Fast

A host-dependency reconciler is an idempotent value carrying its own applicability predicate over the
`HostSubstrate`, plus an install-and-verify plan (mirroring `HostBootstrap.Ensure.Reconciler`).
Sprint `1.52` represents these as pure host-gated reconciler plans; Sprint `4.37` adds the decision
fold that turns observed provider state into a no-op, an apply-plan, or a reboot-required outcome.
Running a reconciler on a host its predicate rejects fails fast — a one-line diagnostic and a
non-zero exit — **before any side effect**. The applicability and decision folds are pure so they are
tested without exiting the process; the live package-manager / VM-provider runner is the remaining
host-specific proof axis.

```haskell
-- Example: ensureLima applies only on Apple; ensureWsl2 only on Windows.
data HostReconciler = HostReconciler
  { reconcilerName :: String
  , appliesTo      :: HostSubstrate -> Bool
  , steps          :: [HostReconcileStep]   -- probe-first install-and-verify plan
  }

data HostProviderState = HostProviderReady | HostProviderMissing | HostProviderRequiresReboot String
data HostReconcileDecision = HostReconcileNoop | HostReconcileApply [HostReconcileStep] | HostReconcileRebootRequired String
```

The decision fold is probe-first and idempotent: a satisfied dependency is a verified no-op;
otherwise it returns the substrate-branched install plan and lets the effectful interpreter re-verify
after apply. The WSL2 reconciler additionally treats a required host reboot as a first-class
fail-fast outcome, not a silent hang. This is the [prerequisite_doctrine.md](./prerequisite_doctrine.md)
fail-fast contract projected onto host provisioning, composed with `Plan` / `Apply`
([pure_fp_standards.md § Plan / Apply](./pure_fp_standards.md#plan--apply)) so `--dry-run` renders
the install plan without touching a package manager.

## 7. Relationship to the Existing Host Gate and Sibling Models

**This relaxes the Ubuntu-only host gate.** [prerequisite_doctrine.md § 2](./prerequisite_doctrine.md#2-prerequisite-categories)
now treats `host_substrate_supported` as the cluster prerequisite root. The
`supported_ubuntu_2404` node remains available as an explicit compatibility property, but the cluster
bundle no longer gates on it. The `HostSubstrate` classification supersedes that host-level gate with
a five-member closed set: "Ubuntu 24.04" becomes a property of the *synthesized Linux frame* (the
Lima/WSL2 guest, §4), not a requirement on the operator's physical host. The Linux-native host still
resolves to `LinuxCpu` / `LinuxGpu`; the Apple and Windows hosts become first-class by construction
rather than rejected by a `platform_linux` prerequisite.

**This is `hostbootstrap`'s VM model, not jitML's Metal bridge.** prodbox manages Kubernetes, so the
non-Linux host must synthesize a Linux frame via a VM (Lima on Apple, WSL2 on Windows) — the
`hostbootstrap` per-OS VM-provider model mirrored in kind, **not** jitML's no-VM on-host Metal
bridge (which exists because jitML reaches Apple Metal unified memory directly). prodbox has no
host-worker/Metal path: `tart` is **not** used and never was, and there is no on-host
non-containerized worker in this doctrine.

**Unobservable is modelled, never assumed.** Where a host probe cannot determine a fact — a VM whose
status query times out, a `wsl --status` that neither confirms nor denies readiness — the result is a
distinct typed outcome (`NeedsReboot` / `Unsatisfiable` in the WSL2 readiness classifier, the same
shape as `Prodbox.Lifecycle.ResidueStatus`'s `ResidueUnreachable` and `Prodbox.Gateway.Types`'
`Disposition`). "Cannot observe" is a constructor the caller must handle, not a silent success.

## 8. Host Capacity Is Observed, Not Configured

The `HostSubstrate` says which execution frame the binary is in; host capacity is a measured fact
inside that frame. For the home RKE2 substrate, `cluster reconcile` observes cpu, memory, node
filesystem capacity, and image filesystem capacity from the Linux frame and compares that observation
with `capacity.resource_plan.host_capacity`. A host that is smaller than the authored declaration is
rejected before RKE2 files or chart workloads are mutated.

This keeps the host-provider model pure: macOS/Windows only choose the Lima/WSL2 Linux frame; the
capacity contract is then evaluated against facts observed in that frame. The resource algebra and
runtime guardrails are owned by
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md); this document owns only the rule
that those probes happen in the detected Linux frame instead of through a config override.

## Intent Ownership

This SSoT owns the host-platform doctrine intention.

- **Owned statement**: the host `prodbox` runs on is a detected `HostSubstrate`, never a configured
  knob; every OS reaches a Linux frame through a closed per-OS provider lift; and "a Linux cluster
  tool on a non-Linux host without a VM" (rules a/b) and "host-frame `docker` on Windows" (rule j)
  are unrepresentable, not runtime-checked.
- **Linked dependents** (Sprints `1.52` and `4.37` landed):
  `src/Prodbox/Host/Substrate.hs` (the `HostSubstrate` detector),
  `src/Prodbox/Host/Tool.hs` (the closed `HostTool` enum + `AbsExe`),
  `src/Prodbox/Host/Lift.hs` (`LiftLayer` / `foldHostLift` / `clusterFrame`),
  `src/Prodbox/Host/Lima.hs` and `src/Prodbox/Host/Wsl2.hs` (provider argv builders),
  `src/Prodbox/Host/Ensure.hs` (the host-gated reconciler plans and provider-state decisions),
  `src/Prodbox/DockerConfig.hs` (the rule-j Docker host-frame gate and Linux-frame dispatch), and
  `src/Prodbox/CLI/Rke2.hs` (capacity observation from the selected Linux frame),
  `src/Prodbox/Prerequisite.hs` / `src/Prodbox/TestPlan.hs` (the `host_substrate_supported` root).

## Cross-References

- [cluster_topology_doctrine.md](./cluster_topology_doctrine.md) — cluster/node topology (the frame's contents)
- [local_registry_pipeline.md § 6.1](./local_registry_pipeline.md#61-host-docker-cli-auth-isolation-harbor-login-vs-the-operators-docker-hub-login) — the mirrored registry-credential seam and rule-j fail-stub
- [prerequisite_doctrine.md](./prerequisite_doctrine.md) — the fail-fast host gate this relaxes
- [resource_scaling_doctrine.md](./resource_scaling_doctrine.md) — the host-capacity budget, RKE2 reservations, and runtime guardrails evaluated inside the selected Linux frame
- [pure_fp_standards.md](./pure_fp_standards.md) — smart constructors, exhaustive-ADT state, Plan / Apply
- [lifecycle_reconciliation_doctrine.md § 3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate) — the "make illegal states unconstructible" and unobservable-is-modelled house pattern
- [config_doctrine.md](./config_doctrine.md) · [Engineering Doctrine Index](./README.md) · [Development Plan](../../DEVELOPMENT_PLAN/README.md) · [Documentation Standards](../documentation_standards.md)
