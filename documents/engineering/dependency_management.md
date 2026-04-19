# Dependency Management Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md

> **Purpose**: Define current dependency-management doctrine for the Haskell `prodbox` repository.

## 0. Planning Ownership

This document defines dependency-management doctrine only.

Clean-room sequencing, completion status, remaining work, and cleanup ownership are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. Current Toolchain Split

- `prodbox.cabal` defines the Haskell library, the `prodbox` executable, and the Haskell test
  suites under `test/`.
- `cabal.project` defines the repository Cabal package set.
- Host build doctrine uses `cabal build --builddir=.build exe:prodbox`; the `.build/` contract is
  intentionally command-line owned.
- Repository-owned container builds live under `docker/`. `docker/prodbox.Dockerfile` builds the
  Haskell frontend under `/opt/build`, `docker/gateway.Dockerfile` builds the gateway image under
  the same root, and both custom Haskell images follow the single-stage `ubuntu:24.04` doctrine
  while mounting the official `haskell:9.6.7-slim` image as a BuildKit toolchain context during
  publication. `docker/gateway.Dockerfile` also installs the official AWS CLI bundle per
  `TARGETARCH` because the in-cluster gateway daemon shells out to `aws route53 ...` for DNS
  writes. The supported custom-image publish path uses a host-network `docker-container` buildx
  builder so pushes to the canonical Harbor endpoint `127.0.0.1:30080` work from inside the
  builder.
- Pulumi programs are YAML-based under `pulumi/` and do not introduce a Python runtime dependency.

## 2. Lock File Policy

The repository does not rely on Poetry or a Python lockfile on the supported path.

Haskell dependency reproducibility is governed by:

1. `prodbox.cabal`
2. `cabal.project`
3. The checked-in YAML Pulumi definitions

Developers should build and test through Cabal:

```bash
cabal build --builddir=.build exe:prodbox
./.build/prodbox check-code
```

## 3. Version Constraint Standards

### Haskell Packages

- Add explicit package bounds in `prodbox.cabal` where the repository already pins them.
- Prefer stable library additions over ad-hoc shell dependencies.
- Keep the executable and test-suite dependency lists minimal and scoped to the modules that need
  them.

### External Tools

- The supported operator toolchain must be documented in `README.md` and in the relevant doctrine
  docs.
- Tool prerequisites that gate command execution belong in `src/Prodbox/Prerequisite.hs`.
- Do not add new required host tools without updating the prerequisite inventory and the affected
  validation docs.

## 4. Current Dependencies

### Haskell Repository Surface

- Core CLI and runtime: `base`, `text`, `bytestring`, `aeson`, `dhall`, `optparse-applicative`,
  `process`, `directory`, `filepath`
- Gateway runtime: network, TLS, concurrency, hashing, and JSON support required by
  `src/Prodbox/Gateway/`
- Test suites: `hspec`, `temporary`, and the same core runtime packages needed to exercise the
  built frontend

### External Command Dependencies

- Host/runtime tools: `kubectl`, `helm`, `docker`, `ctr`, `sudo`, `systemctl`
- Network and AWS tooling: `aws`, `curl`, `dig`, `ssh`
- Infrastructure tooling: `pulumi`
- Formal verification tooling: Docker plus the TLA+ runtime documented in `documents/engineering/tla/`

## 5. Adding New Dependencies

Checklist:

1. Check whether an existing module or external tool already solves the need.
2. Add Haskell library dependencies to `prodbox.cabal`, not to an unsupported sidecar toolchain.
3. Update prerequisite doctrine when a new host tool becomes mandatory.
4. Update the relevant engineering docs when the command surface or validation contract changes.
5. Run `./.build/prodbox check-code` and the affected test suites.

## 6. Upgrading Dependencies

- Keep Cabal changes small and isolated.
- Re-run `./.build/prodbox check-code` after dependency upgrades.
- Re-run the affected named validation suites when an upgrade touches AWS, gateway, chart, Pulumi,
  or public-edge behavior.
- Update doctrine when an upgrade changes the supported external tool version expectations.

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Code Quality Doctrine](./code_quality.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
