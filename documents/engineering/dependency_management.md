# Dependency Management

**Status**: Authoritative source
**Supersedes**: Pre-refactor toolchain correspondence diary
**Generated sections**: none
**Applicability**: Adopted dependency contract; exact kind/tool pins are Phase 1 implementation work

> **Purpose**: Define reproducible Haskell/runtime artifacts, explicit tool ownership and upgrade validation.

## Sources of truth

`prodbox.cabal` owns Haskell dependencies, modules, executable and suites; `cabal.project` owns package/solver policy; canonical Dockerfiles own container build/runtime dependencies. Exact selected versions belong in those executable manifests and generated inventories, not a second independently edited prose list.

Use pinned known tool/node/provider/runtime identities, checksums and architecture-specific artifacts. A tool discovery result is not a version or compatibility proof. Phase 1 explicitly selects and validates kind, node image, container runtime and CNI; do not imply current RKE2 pins already support the new topology.

## Host and runtime tools

The supported baseline is Linux with the chosen pinned container tooling. Host adapters own absolute tool resolution, prerequisite observation, kind lifecycle, mounts, networking and supervised subprocesses. No ambient PATH/profile/auth choice silently changes a provider target or interpreter.

Bootstrap artifacts are retained and loadable without the in-cluster registry, public edge or AWS. Manifest identity binds exact image/config/layers/platform and required worker/runtime programs. Verify bytes before loading and read back the actual running image identity; a tag alone cannot attest the worker.

Runtime images include the dependencies their shipped roles actually execute: native libraries and any registered GnuPG/cryptographic/runtime tools, plus scoped Pulumi/provider tools only where retained adapters need them. Builder-only installation does not satisfy runtime. Provider process use remains operation-scoped; gateway/credential roles do not acquire a generic shell fallback.

## Build contract

Keep host builds under the configured `.build` boundary and canonical container builds under `/opt/build`. Reuse dependency/cache layers across source-only changes; changing solver manifests invalidates the appropriate layer. Shipped images contain runtime artifacts and exact provider programs, not GHC/Cabal stores, source trees or secret/test fixtures.

Container source context and ignore rules exclude `.data`, `.test-data`, `test-secrets.dhall`, generated secrets and local operational credentials. The same exclusion applies to mutation workspaces and public source manifests. Do not destroy global build caches as a routine repair step.

## Upgrades and compatibility

A dependency change that affects codec bytes, memory representation, cryptography, token semantics, subprocess behavior, Kubernetes policy enforcement or provider results requires the corresponding pure controls and real component cases. Preserve source/binary/image/config identity and invalidate only affected current claims. A package pin cannot substitute for an observed backend contract.

For native clients and retained state, explicitly version schemas and supported migration readers. Preserve exact old bytes/evidence when required for recovery. A compatibility reader receives a numerical removal owner and actual migration conditions; new-version deployment never erases an unresolved old operation.

Dhall local co-edited schemas follow the authored configuration contract. Remote/untrusted imports require integrity pins and explicit upgrade review. Do not invent remote dependencies or regenerate unrelated schemas during a documentation refactor.

## Validation

Use real installed binaries/images and actual role dependencies, not fabricated command traces, to close tool/runtime claims. Keep deterministic offline fixtures for malformed/denied/lost-response behavior and independent live observations for cloud semantics. Re-run mutation cases affected by a dependency's behavior. [Testing](testing.md) and [quality](code_quality.md)
