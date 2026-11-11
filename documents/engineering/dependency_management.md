# Dependency Management Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define current dependency-management doctrine for the Haskell `prodbox` repository.

## 0. Planning Ownership

This document defines dependency-management doctrine only.

Clean-room sequencing, completion status, remaining work, and cleanup ownership are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. Current Toolchain Split

- `prodbox.cabal` defines the Haskell library, the `prodbox` executable, and the Haskell test
  suites under `test/`.
- `cabal.project` defines the repository Cabal package set.
- The canonical closed-data token program directly depends on `primitive ==0.9.1.0`.
  Its storage accounting uses that version's `ByteArray` representation alongside the selected
  CBOR writer. The direct token comparator also uses the selected Text UTF8 layout and positive
  ghc-bignum limb representation. A version change requires reviewing the selected SDK writer and
  revalidating token equality, scalar and backing-data controls.
- Checked generalized-UTF8 String decoding directly uses the exposed
  `Codec.Serialise.Internal.GeneralisedUTF8` routine from `serialise ==0.2.6.1`, after byte
  validation. Updating that pin requires reviewing its unchecked array traversal and the CBOR
  payload-array conversion, then revalidating the complete Char domain and malformed, sliced and
  segmented payload controls.
- Captured settings charge duplicate-detection Set node construction against
  `containers ==0.6.8`. The bound uses its five-word `Bin` layout, `delta = 3`
  balance invariant and at most three new nodes per insertion-path ancestor.
  Shape measurement weights each map's entry count by the height recurrence derived from
  that invariant, rather than a rounded logarithmic estimate.
  Updating that pin requires reviewing `Dhall.Map.nubOrd`, Set insertion and both balance
  functions, then revalidating the retained insertion-history graphs and scratch checks.
- The same pin owns Strict Map construction accounting: six-word `Bin` nodes,
  four-word `create` result tuples, `fromList`'s ordered-prefix/fallback dispatch and
  `link`/`insertMin`/`insertMax` balancing. Changes require reviewing those source paths
  and revalidating actual maps, insertion histories and the ordinary input checkpoints.
- Settings extraction pins `text ==2.0.2` for guarded AWS case-converter allocation accounting.
  The bound covers its initial lookahead allocation and every prospective resize array, using
  validator-owned character limits and call counts. Changing this pin requires reviewing the
  converter's growth/shrink implementation and character mapping, then revalidating marker
  counts, grammar compatibility, extraction reservations and native input checkpoints.
- Closed type-tree data accounting pins `dhall ==1.42.3`. Its selected expected-type,
  denotation and closed-type evaluator layouts underlie the five-tree reservation. A pin change
  requires reviewing those paths, compact schema-key origins, type-only counts, syntax graphs
  and the native input checkpoints. Construction/control/update/GC/native costs remain separate.
- `cabal.project` pins `with-compiler: ghc-9.12.4` and carries the temporary
  `allow-newer: *:base, *:template-haskell` escape hatch required by the current package set.
  This clause set is what currently lets the selected `dhall ==1.42.3` build cleanly under GHC
  `9.12.4`; the clauses may be tightened when an upstream `dhall` release ships bounds that
  natively match GHC `9.12.4` and `template-haskell` 2.23.
- Fixed inspection metadata directly depends on `template-haskell ==2.23.0.0`.
  Build-time staging reads the canonical typed producer declaration and preserves the existing
  valid `containers ==0.6.8` map tree with direct strict constructor expressions.
  Its Text literals use `text ==2.0.2`'s `Lift` instance and UTF8 array copier.
  Changes to these pins require reviewing emitted code, constructor-data terms, actual returned
  graphs, schema fidelity, nominal type refusals and source-dependency rebuild controls.
  The finite-count certificate shares those pins and the same emitted template. Pin changes
  also revalidate unrestricted/exact/empty list cases, compile-time refusals and profile clients
  after removal of runtime count-bound traversal.
- Managed ByteString backing observations in `Prodbox.Capacity.PinnedByteStringData` use
  the selected GHC `ForeignPtr`/`PlainPtr` and mutable-byte-array capacity representation.
  GHC or ByteString dependency changes require revalidating owned compact buffers, offset and
  shared views, unsupported borrowed ownership, invalid lengths and compact-copy corroboration
  against independent heap graphs. These observations assume valid owned immutable producers;
  they grant no mutation permit, lifetime guarantee or memory admission.
- Publisher stat-data observations additionally depend on the installed `unix ==2.8.8.0`
  `FileStatus` newtype and its owned `mallocForeignPtrBytes` producer, plus GHC's MallocPtr,
  unpacked finalizer cell and `NoFinalizers` representation. PlainPtr has a separate data term.
  Pin changes require independent backing/owner graphs, empty-cell checks, borrowed and attached-
  finalizer refusals, settled MVar/latch shape checks and the native combined-reservation boundary.
  These are immutable-producer contracts and selected data terms, not proof of arbitrary stat
  validity, active ownership, allocation/GC/native peaks or complete admission.
- Host build doctrine uses `cabal build --builddir=.build exe:prodbox`; the `.build/` contract is
  intentionally command-line owned.
- Repository-owned container builds live under `docker/`. There is a **single** custom Haskell
  Dockerfile, `docker/prodbox.Dockerfile`, which builds one **union runtime image**
  (`prodbox/prodbox-runtime`) under `/opt/build`. It is the same compiled `prodbox` binary for
  every in-cluster role — the gateway daemon and the `api`/`websocket` workloads — and each chart
  selects its role through the pod `args:` (`gateway start` vs `workload start`); the image's
  `ENTRYPOINT` is bare `tini -- prodbox`. The image uses separate `ubuntu:24.04` builder and
  runtime stages, with a small
  manifest-preparation stage that removes Cabal module lists before the dependency boundary. The
  builder installs in-image `ghcup`, pinned GHC `9.12.4`, and Cabal `3.16.1.0`, with no symlinked
  Haskell tool shims; the runtime uses `tini` as PID 1. The image includes the official AWS CLI
  bundle and pins Pulumi CLI `3.228.0` together
  with that same release archive's `pulumi-language-yaml` host. It also installs the exact Pulumi
  AWS provider `7.44.0` into the immutable image layer with release-asset SHA-256 verification for
  both supported architectures; every checked-in Pulumi project declares `aws@7.44.0`. Runtime
  provider discovery therefore downloads neither the provider archive nor its binary. The image
  copies the four checked-in YAML programs to `/opt/build/pulumi/`. The Provider Worker can select only
  the three compiled non-SES program paths (`aws-eks`, `aws-eks-subzone`, and `aws-test`); its four
  SES resource arms use the exact native client and cannot construct SMTP IAM. Target Gateway
  Runtime and Credential Provisioner never shell out
  to either tool. Provider/Admin Action workers may retain only operation-scoped Pulumi child use;
  native home DNS and IAM/S3/STS/Route53/ServiceQuotas adapters do not depend on the CLI. The
  supported custom-image publish path
  uses ordinary host-native `docker build` plus `docker push` to the canonical in-cluster registry endpoint (`127.0.0.1:30080`).
- The dependency layer runs `cabal build --builddir=.build --only-dependencies exe:prodbox`
  against the normalized manifests before project sources enter the builder. A source or module-list
  change preserves that layer; a dependency or solver-policy change invalidates it. The complete
  manifest and sources then compile the executable. Only the executable, runtime tools, and exact
  provider plugin cross into the runtime stage; the checked-in YAML programs are copied separately
  and the binary generates its portable sibling configuration there. No GHC, Cabal store, project
  source, or compilation output enters the shipped image. Builder caches remain available without
  global Docker build-cache deletion.
- The final runtime stage installs GnuPG for the Bootstrap Broker's recovery-recipient and
  encrypted-share operations. A builder-only installation does not satisfy that role. The
  runtime package step runs `/usr/bin/gpg --batch --no-tty --version` and checks its agent/config
  helpers before the image can finish. Artifact validation additionally exercises an isolated
  encryption/decryption round trip in `/dev/shm`; it needs no credential or provider access and
  leaves no persistent private material. The Broker's existing readiness gate remains unchanged.
- The build uses **basic `docker` commands only** with the daemon's default builder. There is no
  supported `docker buildx`, no `docker-container`-driver builder, and no multi-arch publication
  (native-host-architecture only). The Dockerfiles carry **no BuildKit-only features**: no
  `# syntax=` frontend pin and no `RUN --mount` cache/bind mounts, so they build with any basic
  builder. The unit suite enforces this (the `docker/prodbox.Dockerfile` invariants forbid
  `# syntax=`, `--mount=`, and `type=cache`).
- Pulumi programs are YAML-based under `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`,
  `pulumi/aws-test/`, and `pulumi/aws-ses/` only and do not introduce a Python runtime
  dependency.

### 1.1 Native Host Provider Processing Contract

The private host-family launch/recovery path recognizes the exact Ubuntu protocol-image profiles
in `Prodbox.Subprocess.SystemdProviderProfile`, for Linux `x86_64` and `aarch64`:

| Source package | Version | Declared protocol images |
|----------------|---------|--------------------------|
| systemd | `255.4-1ubuntu8.18` | manager executable, `libsystemd-core-255.so`, `libsystemd-shared-255.so` |
| dbus | `1.14.10-4ubuntu4.1` | `dbus-daemon`, `libdbus-1.so.3.32.4` |

The policy reference digests the architecture, exact image paths/hashes and normative processing
conditions. Ubuntu archive signatures authenticate the binary/source index checksums; package
checksums authenticate the extracted code images and source metadata. Reviewed upstream bytes and
the relevant downstream patches establish the same-UID synchronous handler, router FIFO/disconnect
ordering and manager API-owner change across reexec. This is declared source-version correspondence,
not a reconstructed reproducible build or attestation of every loaded library.

Runtime qualification holds root-owned image descriptors and matches bytes, file versions and
actual executable mappings, together with process/domain/security conditions. Unknown, upgraded,
changed or unreadable images refuse; version strings cannot bypass qualification. A new provider
profile requires the same publisher/source review and native controls before its policy reference
can be bound to a submission. The arm64 pins carry archive/source evidence without a native arm64
execution claim. Review evidence and exact image hashes are indexed in
`test/qualification/HOST-NATIVE-PROVIDER-PROCESSING-CONTRACT-2026-10-27.json`;
current validation/qualification status remains in the development-plan ledger.

The physical retirement reader additionally reviews the same pinned manager's job/GC barriers,
its native `ControlGroup` property and cached user-runtime prefix initialization. `sd_path_lookup`
resolves from the pinned `libsystemd-shared` image. Fresh native root/mount observations and bounded
startup-path metadata bind the expected physical anchors to that manager; environment bytes are
neither exported/logged/hashed nor used for configuration or authentication. The additional public
source and native evidence is indexed in
`test/qualification/HOST-OPERATION-RETIREMENT-OBSERVATION-2026-10-27.json`. This is an observation
contract, with immutable-input mutation/recovery and deployment qualification separately owned.

## 2. Lock File Policy

Home MinIO source-image adoption also reconciles the existing StatefulSet's Pod. Kubernetes
`OrderedReady` can retain an obsolete unready Pod after Helm corrects the template. Once the
verified image is seeded and Helm selects it, the home bootstrap observes the registered
controller and Pod, confirms the controller again, and gracefully retires only that obsolete
unready owned Pod with UID/resourceVersion preconditions. One 300-second monotonic deadline
covers those reads, retirement, rollout and exact ready-replacement readback. A changed
controller, partial observation or precondition conflict refuses with a retry remedy; this
operation never force-deletes a Pod or touches its PVC. The AWS bootstrap projection remains
separately owned by its substrate implementation.

The repository does not rely on Poetry or a Python lockfile on the supported path.

Haskell dependency reproducibility is governed by:

1. `prodbox.cabal`
2. `cabal.project`
3. The checked-in YAML Pulumi definitions

Developers build and test through the `prodbox` surface. `dev check` runs the warning-clean
type-checking build itself (`cabal build --builddir=.build all --enable-tests`), so it supersedes a
narrower hand-run `cabal build exe:prodbox` rather than following it:

```bash
prodbox dev check
```

The one time a bare `cabal build --builddir=.build exe:prodbox` is the right command is
bootstrapping a worktree that has no `.build/prodbox` yet — there is no binary to run `dev check`
with. See [code_quality.md](./code_quality.md) for the gate's full step sequence and scope.

## 3. Version Constraint Standards

### Haskell Packages

- Add explicit package bounds in `prodbox.cabal` where the repository already pins them.
- Prefer stable library additions over ad-hoc shell dependencies.
- Keep the executable and test-suite dependency lists minimal and scoped to the modules that need
  them.

### GHC Runtime Option Ownership

The runtime-memory policy introduces no second compiler, package manager, or chart-local tuning
surface. The `prodbox` executable stanza alone enables GHC's `-rtsopts`, which is required for the
generated `-M` argument; the library and test-suite stanzas retain their ordinary warning options.
`Prodbox.Capacity.RuntimeMemory` derives the exact byte-valued heap argument from a validated
`RuntimeMemoryPlan`, and `ChartPlatform` passes it only to the gateway role. `prodbox.cabal` carries
no `-with-rtsopts` heap value, and Docker, `GHCRTS`, and Helm defaults carry none either.

The unit suite's `ghc-heap ==9.12.4` dependency is test-only and follows that exact compiler pin.
The library's `deepseq ==1.5.1.0` pin is the selected compiler's package used to evaluate checked
closed Dhall expressions before returning decoder success. It does not supply a parser or
whole-process bound. The separate test observer checks one-shot claims, field ownership and quiescent storage graphs on the unprofiled
64-bit ABI; it adds
no heap-inspection dependency to the production library or runtime image and grants no whole-heap,
RSS or deployment qualification claim.
The update-header observer also follows GHC `9.12.4`'s evaluated `BLACKHOLE` representation.
Changing that pin requires reviewing `rts/Updates.h`, `rts/StgMiscClosures.cmm`, the `StgInd`
layout and heap-inspection API, then revalidating completed/active updates, CAF chains, sharing
and every unit/native observation client.
The pinned `areBoxesEqual` API allows distinct objects to become equal after collection. Update
head validation therefore uses bounded traversal rather than path equality; pin changes also
revalidate collection between the header observation and target validation.

Static field-name tables also depend on Text `2.0.2`'s `Lift Text` implementation in
`Data.Text`: it emits `unpackCStringLen#`, allocating and copying the exact visible UTF-8 bytes
without reconstructing a Haskell String. The table data term accounts for its explicit array,
pointer, scalar and result wrappers on the pinned ABI. A pin change revalidates emitted code,
Unicode/NUL preservation, deferred numeric queries, constructor graphs and SDK schema agreement;
compiler/update/GC/native costs and the SDK call schedule keep separate ownership.

Profiling builds used to calibrate reserves remain diagnostic variants of the pinned GHC `9.12.4`
toolchain, not a second supported runtime artifact. See
[Resource Scaling Doctrine §2D](./resource_scaling_doctrine.md#2d-runtime-memory-decomposition-and-observation)
and [Sprint 1.60](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md) for ownership.

### External Tools

- The supported operator toolchain must be documented in `README.md` and in the relevant doctrine
  docs.
- Tool prerequisites that gate command execution belong in `src/Prodbox/Prerequisite.hs`.
- Do not add new required host tools without updating the prerequisite inventory and the affected
  validation docs.

## 4. Current Dependencies

### Haskell Repository Surface

- Core CLI and runtime: `base`, `text`, `bytestring`, `aeson`, `optparse-applicative`,
  `typed-process`, `directory`, `filepath`, `transformers`; `exceptions` supplies the generic
  `MonadMask` bracket used to delete a newly-created SMTP IAM key on synchronous/asynchronous
  interruption before its guarded committed projection is confirmed.
- Daemon structured logging: `co-log` / `co-log-core` through
  `src/Prodbox/Gateway/Logging.hs`, with gateway and workload daemon entrypoints writing JSON
  log lines to stderr.
- Repository config decoding is operator-authored `Dhall -> Haskell types`, performed in-process
  by the native `dhall` Haskell library (`Dhall.inputFile`) in `src/Prodbox/Settings.hs` and
  (per [config_doctrine.md](./config_doctrine.md)) in the gateway daemon's
  `src/Prodbox/Gateway/Settings.hs`. The decoder produces typed Haskell settings values
  directly; `prodbox-config.json` and any other JSON projection of the Dhall are never
  materialized on the supported path. Under GHC `9.12.4`, `cabal.project` carries
  `allow-newer` clauses for `dhall`'s transitive dependencies so the pinned `dhall ^>=1.42`
  bound continues to build cleanly.
- Gateway runtime: network, TLS, concurrency, hashing, and JSON support required by
  `src/Prodbox/Gateway/`
- Test suites: `tasty`, `tasty-hunit`, `tasty-quickcheck`, `tasty-golden`, `temporary`, and the
  same core runtime packages needed to exercise the built frontend

The scheduled project-wide CBOR migration adds the `cborg` / `serialise` dependencies per
[pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md), and multi-OS host support is
mirrored in-kind from `hostbootstrap` (no code dependency) per
[host_platform_doctrine.md](./host_platform_doctrine.md).

### Native AWS client boundary

Sprint `1.62` (landed 2026-07-18) supplies native IAM, STS, Route 53, and Service Quotas clients —
and Sprint `1.66` the native S3 object-store client — built on the **already-pinned** SigV4 +
`http-client`/`crypton`/`aeson` stack (`src/Prodbox/Aws/SigV4.hs` + `src/Prodbox/Minio/ObjectStoreNative.hs`
+ `src/Prodbox/Aws/Native/*`), adding **zero new dependencies**. `amazonka` is explicitly rejected:
it would pull a large transitive tree inconsistent with the in-tree hand-rolled signer, and the
existing native object-store client already establishes the pattern (pure sign/encode + a thin
`http-client` send + hand-rolled substring XML / `aeson` JSON decode). Any future addition of a
native AWS service package must clear § 5 and justify why the SigV4 + `http-client` pattern does not
suffice. Credential Provisioner and native admin actions use these typed clients with a validated,
linear in-memory credential handle (`src/Prodbox/Aws/CredentialHandle.hs`) supplied outside the
serializable program algebra: the handle is unserializable, redacts every secret on `Show`, and has
no base→session widening. They do not invoke `aws`, consult profiles/instance metadata, or write
credential files/Pod environment — a source-scan unit test
(`test/unit/AwsNativeClients.hs`) enforces the absence of every such seam across the native modules.
Pulumi remains a separately isolated child-process boundary in Provider/Admin Action workers; any
operation-scoped child environment is constructed only after permit validation and is never ambient
daemon authentication.

### External Command Dependencies

- Haskell quality tools: `fourmolu`, `hlint`
- Host/runtime tools: `kubectl`, `helm`, `docker`, `ctr`, `sudo`, `systemctl`
- Network and AWS tooling: `aws`, `curl`, `dig`, `ssh`
- Infrastructure tooling: Pulumi CLI `3.228.0`, its same-archive YAML language host, and the
  checksum-pinned Pulumi AWS provider `7.44.0` in the union runtime image; host-side `pulumi`
  remains an explicit prerequisite only for pre-cutover operator surfaces tracked for deletion
- Formal verification tooling: Docker plus the TLA+ runtime documented in `documents/engineering/tla/`

`prodbox dev lint haskell` and `prodbox dev check` bootstrap the repo-local style-tool sandbox at
`.build/prodbox-style-tools/bin/` via `src/Prodbox/Lint.hs`, using `ghcup run --install` with
formatter GHC `9.12.4`, Cabal `3.16.1.0`, Fourmolu `0.19.0.1`, and HLint `3.10`. The lint
entrypoint invokes those sandboxed binaries directly rather than consulting host-installed
`fourmolu` or `hlint`.

## 5. Adding New Dependencies

Checklist:

1. Check whether an existing module or external tool already solves the need.
2. Add Haskell library dependencies to `prodbox.cabal`, not to an unsupported sidecar toolchain.
3. Update prerequisite doctrine when a new host tool becomes mandatory.
4. Update the relevant engineering docs when the command surface or validation contract changes.
5. Run `prodbox dev check` and the affected test suites.

## 6. Upgrading Dependencies

- Keep Cabal changes small and isolated.
- Re-run `prodbox dev check` after dependency upgrades.
- Re-run the affected named validation suites when an upgrade touches AWS, gateway, chart, Pulumi,
  or public-edge behavior.
- Update doctrine when an upgrade changes the supported external tool version expectations.

## Toolchain Pinning

The exact GHC and Cabal versions every project under this doctrine builds with, plus the Provider
Worker image's exact Pulumi CLI version, are:

```text
GHC 9.12.4
Cabal 3.16.1.0
Pulumi CLI + bundled YAML language host 3.228.0 (Provider Worker image)
Pulumi AWS provider 7.44.0 (Provider Worker image; SHA-256 pinned per architecture)
```

These are not floors or recommendations. The `.cabal` file declares
`tested-with: ghc ==9.12.4`. A `cabal.project` (or equivalent) pins
`with-compiler: ghc-9.12.4`. Every supported local or externally-invoked automation run uses the
same versions. The
formatter-tools GHC under `.build/<project>-style-tools/` is a separate
sandboxed install managed by the lint stack, but it is pinned to the
*same* GHC `9.12.4` named here: the project runs one GHC version for
everything, including code checking. There is no second compiler version.

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Code Quality Doctrine](./code_quality.md)
- [Haskell Code Guide](./haskell_code_guide.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
