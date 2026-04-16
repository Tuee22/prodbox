# prodbox Haskell Rewrite Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: N/A

> **Purpose**: Define the phase-by-phase refactor of `DEVELOPMENT_PLAN/` required to rewrite
> `prodbox` in Haskell, remove Python from the supported architecture, and retain Pulumi as an
> external infrastructure engine.

## Rewrite Intent

As of April 16, 2026, the canonical `DEVELOPMENT_PLAN/` suite closes phases `0-7` against the
current Python implementation. This document intentionally reopens phases `0-7` against a new end
state:

- `prodbox` is a compiled Haskell executable rather than a Python package.
- Python is not part of the supported runtime, test harness, build chain, or infrastructure
  implementation.
- Pulumi remains part of the supported architecture, but no Pulumi program depends on Python.
- The repository keeps the same clean-room narrative and the same phase numbering so
  `DEVELOPMENT_PLAN/` can be rewritten rather than replaced with an unrelated roadmap.

This is not a "port enough to coexist" plan. The final handoff is a Haskell-only repository with
zero Python implementation residue on the supported path.

## Non-Negotiable End State

- The only supported public CLI remains `prodbox`.
- The repository-root `prodbox-config.dhall` remains the single configuration source unless a
  later explicit plan change replaces it.
- Host-side Haskell builds write all build artifacts, including the `prodbox` binary, under the
  repository-local `.build/` root. `cabal.project` explicitly sets this location; the default
  Cabal output path is not part of the supported architecture.
- Container-side Haskell builds write build artifacts under `/opt/build`. The Dockerfile declares
  this location explicitly; container builds do not infer or silently vary their output root.
- The product scope remains intact: local RKE2 lifecycle, Pulumi-backed AWS validation, in-cluster
  gateway ownership, chart deployment, public-host proof, interactive onboarding, and AWS IAM or
  quota automation all survive the rewrite.
- `pyproject.toml`, `poetry.lock`, `.python-version`, Python test harnesses, Python type stubs,
  and Python source trees are removal targets rather than permanent compatibility layers.
- No long-lived split-runtime doctrine is allowed. Temporary hybrid implementation is acceptable
  only while a phase is open; Phase 6 closes only when the supported path no longer depends on
  Python.

## Recommended Target Topology

```text
prodbox/
├── .build/
├── app/prodbox/Main.hs
├── src/Prodbox/
│   ├── CLI/
│   ├── Infra/
│   ├── Lib/
│   ├── Gateway/
│   └── Settings.hs
├── test/
│   ├── unit/
│   └── integration/
├── pulumi/
│   ├── home/
│   ├── aws-eks/
│   └── aws-ha-rke2/
├── prodbox.cabal
├── cabal.project
├── DEVELOPMENT_PLAN/
└── documents/
```

Recommended implementation choices for the rewrite:

- `cabal` as the canonical Haskell build entrypoint
- `cabal.project` explicitly routes host build outputs to `.build/`
- `optparse-applicative` for CLI parsing
- `dhall` for native config decoding
- `aeson` for JSON interchange with Pulumi, Kubernetes, and AWS CLI subprocesses
- `typed-process` for subprocess ownership
- `tasty` plus `HUnit`/`hedgehog` for unit and integration test organization
- `fourmolu` and `hlint` behind `prodbox check-code`

Phase 1 may revise these choices only if it records a concrete blocker and an explicit replacement.

## Build Artifact Contract

- The supported host build root is `.build/`.
- `cabal.project` explicitly points all host builds to `.build/`; `dist-newstyle/` is not a
  supported artifact location.
- The supported container build root is `/opt/build`.
- The Dockerfile build declares `/opt/build` explicitly and copies or promotes the built `prodbox`
  artifact from that path.
- Any rewritten doctrine or Docker build instructions must use these two locations verbatim unless
  a later plan revision changes the contract.

## Pulumi Retention Model

Pulumi stays, but Python does not.

- `prodbox pulumi ...` remains the canonical operator surface.
- Haskell owns Pulumi orchestration, stack selection, preview or up or destroy invocation, output
  parsing, and failure classification.
- Existing Python Pulumi programs are replaced by non-Python Pulumi definitions. The preferred
  model is Pulumi YAML plus Haskell-generated config or asset material when dynamic input is
  required.
- AWS test-stack doctrine, MinIO-backed state, and destroy-before-local-delete rules remain part
  of the supported architecture.

## Phase Refactor Summary

| Phase | Refactored Name | Status | Closure Result |
|-------|-----------------|--------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | 📋 Planned | `DEVELOPMENT_PLAN/` describes the Haskell end state rather than the Python closure state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | 📋 Planned | One supported Haskell binary owns local lifecycle, settings, tests, and AWS validation foundations |
| 2 | Haskell Gateway Runtime and DNS Ownership | 📋 Planned | Gateway runtime, leader election, and Route 53 ownership move to Haskell |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | 📋 Planned | Chart deployment and retained-storage orchestration move to Haskell |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | 📋 Planned | Remaining lifecycle helpers are rewritten, Pulumi is Python-free, and repository-level Python residue is deleted |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | 📋 Planned | Public DNS, TLS, ingress, and external proof rerun through Haskell surfaces only |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | 📋 Planned | A full destructive rerun passes without Poetry, pytest, or Python implementation dependencies |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | 📋 Planned | All interactive and administrative AWS flows close through Haskell-only command paths |

## Phase 0: Planning and Documentation Topology for Haskell Rewrite

**Status**: Planned
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`

### Objective

Reopen the canonical plan suite so it describes a Haskell clean-room build rather than a completed
Python system.

### Deliverables

- `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, and `system-components.md` explicitly state that
  the Python implementation is no longer the target handoff.
- All phase documents keep the existing `0-7` topology but are rewritten around the Haskell end
  state defined in this document.
- `legacy-tracking-for-deletion.md` is reopened with Python-specific pending-removal items rather
  than remaining empty.
- Root guidance docs point at the rewritten plan suite and stop describing Poetry or Python as the
  canonical development surface.

### Validation

1. Cross-references between root docs, `DEVELOPMENT_PLAN/`, and `documents/engineering/` remain
   consistent.
2. `prodbox check-code`

## Phase 1: Haskell Runtime, CLI, Config, and Pulumi Foundations

**Status**: Planned
**Implementation**: `app/prodbox/Main.hs`, `src/Prodbox/CLI/`, `src/Prodbox/Settings.hs`, `src/Prodbox/Lib/`, `src/Prodbox/Infra/`, `test/unit/`, `test/integration/`, `prodbox.cabal`, `cabal.project`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`

### Objective

Establish the Haskell binary, module layout, test harness, config loader, subprocess runtime, and
Pulumi bridge needed to replace the Python foundations without shrinking product scope.

### Deliverables

- One compiled Haskell `prodbox` executable replaces Click entrypoints and preserves the supported
  command matrix.
- Host builds are configured by `cabal.project` to emit all build outputs into `.build/`, and the
  supported local binary artifact lives under that root.
- Container builds are configured by the Dockerfile to compile under `/opt/build`, with that path
  treated as part of the supported container build contract rather than an implementation detail.
- Native Haskell settings loading decodes `prodbox-config.dhall`, preserves current config
  semantics, and continues the auto-compile or materialize path for `prodbox-config.json` when the
  compiled artifact is required by downstream tools.
- The current interpreter, DAG, streaming, and command-result contracts are re-expressed as
  Haskell ADTs rather than Python dataclasses and exceptions.
- `prodbox test unit`, `prodbox test integration ...`, and `prodbox check-code` are reimplemented
  on a Haskell-native test and quality stack.
- Local RKE2 lifecycle, supported-host gating, MinIO-backed Pulumi bootstrap, HA RKE2 AWS proof,
  and EKS AWS proof all move onto Haskell-owned command paths.
- The canonical Pulumi integration path invokes `pulumi` from Haskell and does not import or shell
  into Python programs.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox test integration lifecycle`
6. `prodbox pulumi test-resources`
7. `prodbox pulumi test-destroy --yes`
8. `prodbox pulumi eks-resources`
9. `prodbox pulumi eks-destroy --yes`
10. Host build proof: `cabal build` places the binary under `.build/`
11. Container build proof: the Dockerfile build places build artifacts under `/opt/build`

## Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Planned
**Implementation**: `src/Prodbox/Gateway/`, `src/Prodbox/CLI/Gateway.hs`, `test/unit/gateway/`, `test/integration/gateway/`, `charts/gateway/`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Replace the Python gateway daemon and gateway-related command surfaces with Haskell while
preserving leader election, partition tolerance, and Route 53 write discipline.

### Deliverables

- `prodbox gateway start|status|config-gen` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary rather than a Python entrypoint.
- Existing ownership invariants stay intact: one active Route 53 writer, explicit
  `dns_write_gate`, and deterministic reconvergence after partitions heal.
- Gateway event-key persistence, cluster inspection, and status rendering move to Haskell-owned
  modules and tests.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-pods`
5. `prodbox test integration gateway-partition`
6. `prodbox tla-check`

## Phase 3: Haskell Chart Platform and Cluster-Backed `vscode` Delivery

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `test/unit/charts/`, `test/integration/charts/`, `charts/`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Move chart rendering, deploy/delete orchestration, retained-state handling, and `vscode` stack
delivery to Haskell without changing the supported platform doctrine.

### Deliverables

- `prodbox charts list|status|deploy|delete` are implemented in Haskell.
- Deterministic PV or PVC naming, `.prodbox-state/` handling, and manual-storage doctrine survive
  the rewrite unchanged at the operator surface.
- The Haskell implementation owns chart secrets, gateway event-key resolution, and Helm invocation.
- The cluster-backed `vscode` path remains the only supported application-delivery model.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration charts-storage`
4. `prodbox test integration charts-platform`
5. `prodbox test integration charts-vscode`

## Phase 4: Lifecycle Hardening, Pulumi Decoupling, and Python Removal

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/`, `test/integration/lifecycle/`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, `docker/Dockerfile`

### Objective

Finish the hard parts of the rewrite: eliminate Python from lifecycle-critical code paths, remove
Python-specific toolchain ownership, and ensure Pulumi-backed infrastructure remains fully
supported without Python.

### Deliverables

- All lifecycle-critical command paths, including delete/install/bootstrap flows, are Haskell-only.
- Python Pulumi stack programs are replaced with non-Python Pulumi definitions plus Haskell-owned
  orchestration and output parsing.
- The legacy ledger explicitly tracks and then removes Python source trees, Poetry files,
  `.python-version`, `typings/`, pytest-only helpers, and Python-specific doctrine.
- `prodbox check-code` no longer shells out to `ruff`, `mypy`, or other Python-specific quality
  tools.
- Repository docs stop presenting Python, Poetry, pytest, Click, or Pydantic as supported
  architecture.
- The repository no longer has ambiguous Haskell artifact locations: host builds remain under
  `.build/` by explicit `cabal.project` policy, and container builds remain under `/opt/build` by
  explicit Dockerfile policy.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration lifecycle`
4. `prodbox pulumi preview`
5. `prodbox pulumi up --yes`
6. `prodbox pulumi destroy --yes`
7. `rg -n "poetry|pytest|mypy|ruff|click|pydantic|python" .`

The final grep does not need to reach zero during the phase, but every remaining match must be
intentional, current, and recorded in `legacy-tracking-for-deletion.md`.

## Phase 5: Public Hostname Closure and External Proof on the Haskell Stack

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Host.hs`, `src/Prodbox/Infra/Ingress.hs`, `src/Prodbox/Infra/CertManager.hs`, `test/integration/public_host/`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_test_environment.md`

### Objective

Re-prove the public DNS, ingress, TLS, and external reachability story through Haskell-only
surfaces after gateway, chart, and infrastructure ownership have moved.

### Deliverables

- `prodbox host public-edge` is implemented in Haskell and preserves the current diagnostic
  classification contract.
- cert-manager, Traefik, MetalLB, and Route 53 proof surfaces are exercised without Python-owned
  helpers.
- Public-host validation still forbids `/etc/hosts`-based closure.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox host public-edge`
4. `prodbox test integration charts-vscode`
5. `prodbox test integration public-dns`

## Phase 6: Final Clean-Room Rerun and Zero-Python Handoff

**Status**: Planned
**Implementation**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `src/Prodbox/CLI/Test.hs`, `src/Prodbox/CLI/Rke2.hs`, `test/integration/`
**Docs to update**: `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/unit_testing_policy.md`, `documents/engineering/dependency_management.md`

### Objective

Close the rewrite with the same level of destructive confidence as the current plan, but from a
baseline where Python is not required or supported.

### Deliverables

- The authoritative rerun starts from full local cluster delete, missing compiled config, and no
  Poetry or virtualenv bootstrap assumptions.
- The supported operator flow reinstalls the local cluster, restores the Pulumi backend, exercises
  both AWS-backed validation paths, reruns public-host proof, and destroys AWS residue through
  Haskell-only command surfaces.
- The repository handoff no longer depends on Python source files, Python packaging metadata,
  Python test runners, or Python Pulumi programs.
- The legacy ledger is empty in `Pending Removal`.

### Validation

1. `prodbox rke2 delete --yes`
2. `rm -f prodbox-config.json`
3. `prodbox rke2 install`
4. `prodbox config show`
5. `prodbox config validate`
6. `prodbox pulumi eks-resources`
7. `prodbox test integration aws-eks`
8. `prodbox pulumi test-resources`
9. `prodbox test integration ha-rke2-aws`
10. `prodbox pulumi eks-destroy --yes`
11. `prodbox pulumi test-destroy --yes`
12. `prodbox test all`
13. `prodbox host public-edge`
14. `prodbox check-code`
15. `rg --files . | rg '\\.py$|pyproject\\.toml|poetry\\.lock|\\.python-version'`

Phase 6 closes only when the final file search returns no supported-path Python artifacts.

## Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation in Haskell

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Config.hs`, `src/Prodbox/CLI/Aws.hs`, `src/Prodbox/Lib/AwsAdmin.hs`, `test/unit/aws_admin/`, `test/integration/aws_iam/`
**Docs to update**: `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/aws_admin_credentials.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Finish the rewrite on the highest-friction operator paths: interactive configuration, IAM user
setup or teardown, policy generation, and service-quota inspection or requests.

### Deliverables

- `prodbox config setup` is implemented in Haskell with the same scope as the current guided flow.
- `prodbox aws policy|setup|teardown|check-quotas|request-quotas` are implemented in Haskell.
- Test-only elevated credential handling survives the rewrite, but its implementation and tests are
  Haskell-only.
- AWS CLI subprocess ownership, prompt flows, and Dhall mutation rules are rewritten without
  Python helpers.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration aws-iam`
4. `prodbox config setup`
5. `prodbox aws policy --tier full`

## Mandatory Python-Removal Ledger Seeds

When `legacy-tracking-for-deletion.md` is reopened for this rewrite, it should contain at least
these pending-removal categories:

- `src/prodbox/**/*.py` - all Python implementation modules
- `tests/**/*.py` - Python unit and integration harnesses
- `typings/` - Python-specific stub inventory
- `pyproject.toml`, `poetry.lock`, `.python-version` - Python packaging and toolchain ownership
- Python-specific doctrine in `documents/engineering/` - any doc that names Poetry, pytest,
  mypy, ruff, Click, or Pydantic as current architecture
- Python Pulumi programs under `src/prodbox/infra/` or `pulumi/` - replace with non-Python
  Pulumi definitions before final handoff

## Required Rewrite Order for `DEVELOPMENT_PLAN/`

To stay aligned with `DEVELOPMENT_PLAN/development_plan_standards.md`, rewrite the plan suite in
this order:

1. `DEVELOPMENT_PLAN/README.md`
2. `DEVELOPMENT_PLAN/00-overview.md`
3. `DEVELOPMENT_PLAN/system-components.md`
4. `DEVELOPMENT_PLAN/phase-0-planning-documentation.md`
5. `DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md`
6. `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`
7. `DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md`
8. `DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md`
9. `DEVELOPMENT_PLAN/phase-5-public-host-validation.md`
10. `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`
11. `DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md`
12. `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
13. Governed doctrine docs under `documents/engineering/`

## Exit Definition

This rewrite is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` describes the Haskell architecture rather than the Python architecture.
2. The supported operator flow is `prodbox`, implemented in Haskell, across lifecycle, Pulumi,
   gateway, charts, validation, config, and AWS administration.
3. Pulumi remains supported, but no supported Pulumi program or orchestration path depends on
   Python.
4. The strongest clean-room rerun passes from full local delete through final AWS teardown on the
   Haskell stack.
5. `legacy-tracking-for-deletion.md` is empty in `Pending Removal`.
6. The repository has no supported-path Python implementation or Python toolchain ownership
   artifacts left.
