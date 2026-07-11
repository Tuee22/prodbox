# Dependency Management Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/system-components.md, DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md, DEVELOPMENT_PLAN/phase-0-planning-documentation.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md, DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md, documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/haskell_code_guide.md, documents/engineering/pure_fp_standards.md, documents/engineering/pulsar_messaging_doctrine.md, documents/engineering/host_platform_doctrine.md
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
- `cabal.project` pins `with-compiler: ghc-9.12.4` and carries the temporary
  `allow-newer: *:base, *:template-haskell` escape hatch required by the current package set.
  This clause set is what currently lets the `dhall ^>=1.42` bound build cleanly under GHC
  `9.12.4`; the clauses may be tightened when an upstream `dhall` release ships bounds that
  natively match GHC `9.12.4` and `template-haskell` 2.23.
- Host build doctrine uses `cabal build --builddir=.build exe:prodbox`; the `.build/` contract is
  intentionally command-line owned.
- Repository-owned container builds live under `docker/`. There is a **single** custom Haskell
  Dockerfile, `docker/prodbox.Dockerfile`, which builds one **union runtime image**
  (`prodbox/prodbox-runtime`) under `/opt/build`. It is the same compiled `prodbox` binary for
  every in-cluster role — the gateway daemon and the `api`/`websocket` workloads — and each chart
  selects its role through the pod `args:` (`gateway start` vs `workload start`); the image's
  `ENTRYPOINT` is bare `tini -- prodbox`. The image follows the single-stage `ubuntu:24.04`
  doctrine with in-image `ghcup`, pinned GHC `9.12.4`, no symlinked Haskell tool shims, `tini` as
  PID 1, and the official AWS CLI bundle from the image's native Debian architecture (the gateway
  daemon shells out to `aws route53 ...` for DNS writes). The supported custom-image publish path
  uses ordinary host-native `docker build` plus `docker push` to the canonical in-cluster registry endpoint (`127.0.0.1:30080`).
- The build uses **basic `docker` commands only** with the daemon's default builder. There is no
  supported `docker buildx`, no `docker-container`-driver builder, and no multi-arch publication
  (native-host-architecture only). The Dockerfiles carry **no BuildKit-only features**: no
  `# syntax=` frontend pin and no `RUN --mount` cache/bind mounts, so they build with any basic
  builder. The unit suite enforces this (the `docker/prodbox.Dockerfile` invariants forbid
  `# syntax=`, `--mount=`, and `type=cache`).
- Pulumi programs are YAML-based under `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`,
  `pulumi/aws-test/`, and `pulumi/aws-ses/` only and do not introduce a Python runtime
  dependency.

## 2. Lock File Policy

The repository does not rely on Poetry or a Python lockfile on the supported path.

Haskell dependency reproducibility is governed by:

1. `prodbox.cabal`
2. `cabal.project`
3. The checked-in YAML Pulumi definitions

Developers should build and test through Cabal:

```bash
cabal build --builddir=.build exe:prodbox
prodbox dev check
```

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

### External Command Dependencies

- Haskell quality tools: `fourmolu`, `hlint`
- Host/runtime tools: `kubectl`, `helm`, `docker`, `ctr`, `sudo`, `systemctl`
- Network and AWS tooling: `aws`, `curl`, `dig`, `ssh`
- Infrastructure tooling: `pulumi`
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

The exact GHC and Cabal versions every project under this doctrine builds with:

```text
GHC 9.12.4
Cabal 3.16.1.0
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
