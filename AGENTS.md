# Repository Guidelines for Agents

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Current agent rules for implementing the adopted refactor and operating the existing binary safely.

> **Purpose**: Give agents one execution entrypoint, operating boundary and evidence standard.

## Start here

Read [DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here). Implement the first incomplete phase in numerical order, following its tasks, acceptance cases, critical mutations and owned legacy removals. The [plan standards](DEVELOPMENT_PLAN/development_plan_standards.md) govern completion; [engineering/README.md](documents/engineering/README.md) indexes accepted contracts.

Do not resume the superseded fractional-sprint queue or import historical Done labels into the new phases. Reuse correct existing code and tests after validating their new owned scope. A future-phase dependency means the phase boundary needs correction, not a fake implementation or hidden alternate queue.

A request restricted to Markdown authorizes Markdown edits only. It does not authorize changing Haskell, schemas, generated non-Markdown artifacts, runtime configuration or infrastructure. The documentation adoption leaves Phase 0 open for code-side checker/generated-artifact migration and its actual negative/mutation proof. A subsequent request to implement open phases includes that code work in order.

## Target versus current behavior

The accepted target retains local kind for Lifecycle Authority, Vault, MinIO and management roles. The canonical application service set remains available locally and on optional EKS. Target ordinary `prodbox delete --yes` removes all deployment-owned AWS resources, including SES/EBS/backing stores/generated IAM, and records absence on the retained control plane. Local control removal and local data purge are separate operations.

These are adopted contracts, not a claim that the current executable has changed. The source/current binary still contains RKE2-era commands and legacy cleanup paths. Before a live operation, inspect the installed binary's actual help and supported handler. Do not run proposed target commands as if they were implemented, rewrite current help by hand, or delete an original-install recovery path before its owning migration/removal condition passes.

If the unchanged checker rejects the new documentation grammar or paths, that is explicit Phase 0 work. Do not restore contradictory old doctrine, invent old phase status, disable checks, or make forbidden code edits merely to get green output.

## Current worktree structure

```text
app/prodbox/Main.hs      Haskell executable entrypoint
src/Prodbox/             Haskell CLI, runtime, lifecycle and interpreters
test/                    Haskell tests and acceptance support
prodbox.cabal            Cabal package
cabal.project            Cabal project configuration
docker/                  Canonical container builds
documents/               Accepted architecture and operator documentation
DEVELOPMENT_PLAN/        One numerical queue, contracts, evidence and removal ownership
```

The supported implementation is Haskell-only. Do not describe removed Python runtime directories as current or target architecture.

## Current worktree commands

Build the existing operator binary through the current toolchain:

```bash
cabal build --builddir=.build exe:prodbox
mkdir -p .build
cp "$(cabal list-bin --builddir=.build exe:prodbox)" .build/prodbox
chmod +x .build/prodbox
```

The canonical quality entrypoint remains `./.build/prodbox dev check`. Until command migration lands, the existing binary exposes `test unit`, `test integration cli`, `test integration env`, and `test all`; the target single `test run NAME` path is delivered by the owning phases. Inspect actual help before invoking other live commands.

Run checks appropriate to the authorized change. Do not claim the full gate passed when only document structure was checked. A phase cannot close while its required real evidence, mutation cases, cleanup or removal obligations remain open.

## Live Infrastructure Deployment Is Authorized

When the user's implementation or validation request requires a real local cluster, Vault, AWS target or public TLS proof, establishing it through the documented **implemented prodbox entrypoint** is authorized. Expected AWS spend, EKS/EBS/NAT/load-balancer lifetime and DNS/SES provisioning do not require an extra permission request beyond the task. Drive an in-hand lifecycle operation through completion or an honestly observed recovery disposition.

Authorization is not an instruction to rerun until green. Follow the live-campaign limits in the [plan standards](DEVELOPMENT_PLAN/development_plan_standards.md#evidence-and-live-campaigns): batch fixes, bank reproducible failures, and stop for class review when the stated attempt/boundary limits are reached.

Normal AWS mutation remains prodbox-surface-owned. Do not use ad-hoc `aws`, `pulumi up/destroy`, `eksctl`, Terraform or other provider mutations to work around a missing/failed implementation. Add the required resource adapter and recovery behavior in its owning phase. Read-only provider diagnostics are permitted and must report their actual scope.

A user may explicitly request an exceptional manual cleanup. Record it as a hand action and preserve exact scope/read-back; it does not qualify the supported lifecycle. Such a request is not standing authorization for later manual provisioning or cleanup.

Never automate the legacy operator-only/TTY-only `nuke` ceremony. New target delete, control removal and data purge do not become available by documentation alone. Ordinary deletion must not delete its own evidence or credentials before their dependants finish.

## Environment and credential isolation

Production uses `.data/`; testing uses `.test-data/` under distinct deployment/run identities. Bind roots, mounts, kubeconfigs, endpoints, cloud names/tags and credentials to that scope. Never rewrite the production sibling config for tests, infer the target from ambient kubeconfig, or reuse a production SES identity/bucket as an unnamed test dependency.

The elevated AWS credential enters through the real operator prompt. Automation simulates that input only from the authorized `aws_admin_for_test_simulation` fixture in `test-secrets.dhall`, through the same bounded credential implementation. Keep the runtime elevated value ephemeral; never write it to configuration, Vault, MinIO, Kubernetes objects, argv, environment, logs or evidence. Generated least-privilege operational credentials live in scoped Vault state.

`test-secrets.dhall` must be a regular, non-symlink file owned by the effective user with no group/other mode bits. Check and read the same descriptor; refuse unsafe files without changing their permissions. Never print its values or include it in source/evidence hashes. Ambient AWS environment/profile/host CLI credentials are not substitutes for either supported ingress.

Test-only MinIO self-unseal is permitted only in an explicitly bound test policy. Production uses protected configured unlock custody or requests input within the operation. Do not initialize Vault over missing/replaced retained storage or infer absence of AWS resources from an uninitialized Vault. Local non-secret lifecycle metadata may be readable to the authenticated operator; secrets remain protected.

Validate external input, especially FQDNs, IPs, roots and account/region identities. Daemon configuration comes from an explicit mounted Dhall file, not ambient secret environment fallbacks.

## Coding style and implementation ownership

Use explicit ADTs, exhaustive matches, structured ordinary errors and small pure helpers. Keep side effects in command/interpreter boundaries. Decode and validate configuration separately from execution. Prefer one catalog/model with generated projections over duplicated renderer and test setup paths.

One retained Authority owns mutation admission for a deployment. Preserve write-before-effect, bounded execution, independent resource read-back, cancellation settlement and recoverable operation identity. Checkpoint readability, resource presence, credentials and audit scope are separate observations. A missing file, successful provider exit or global tag sweep cannot silently become exact resource absence.

Keep all canonical application/platform services in the supported projection. Fix image distribution, service installation and networking at their owning substrate adapter; do not make tests pass through different images or omitted services on EKS. Bootstrap/recovery images must be available independently of the registry they recover.

## Testing and mutation discipline

Run real owned composition through the public binary and independent observers. Fakes support pure/protocol tests and controlled fault cases; they cannot substitute for the real provider/Kubernetes behavior a phase claims. Every introduced resource family must have cleanup and postcondition evidence in the same phase.

Critical source mutations must trigger the expected unchanged assertion. Compilation errors, unrelated failures and timeouts do not count as kills. Mutants execute in isolated non-secret workspaces without production roots, current kubeconfig, unrestricted container sockets, elevated/AWS credentials, publication authority or provider egress. Actual cloud acceptance uses the separately identified unmodified build.

Do not perform hand setup/cleanup to manufacture a passing run. Preserve primary and cleanup failures, incomplete observations and stable recovery IDs. Historic reports remain tied to the revisions they exercised.

## Development tooling policy

Do not add `.github/` workflows, repository CI automation or Git hooks during active development. Run the CLI checks directly. Do not add an alternate quality command that bypasses `prodbox dev check`.

## Commit Guidelines

**Agents never commit or push.** Leave changes uncommitted. Do not run `git add`, `git commit`, `git push`, or other Git commands that modify repository state. Read-only status, diff and history inspection are permitted.

## Documentation handoff

Follow [Documentation Standards](documents/documentation_standards.md). Keep the queue in one place, use the canonical Markdown objective/command/acceptance/mutation manifests, and assign every obsolete path to a numerical remover in [legacy_tracking_for_deletion.md](DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md). Do not close a phase with pending owned rows or a private replacement that the public command cannot use.
