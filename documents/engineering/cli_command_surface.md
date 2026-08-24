# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: `command-surface-toplevel`, `command-surface-matrix`

> **Purpose**: Define the explicit, no-passthrough command surface for `prodbox`.

## 1. Command Surface Statement

`prodbox` CLI commands accept only explicitly declared arguments and options at the parser
boundary; passthrough to downstream tools is prohibited.

The CLI surface is intentionally closed:

1. Unknown extra arguments fail at the CLI parser boundary.
2. Invoking a command group without a subcommand displays help instead of running an implicit
   default.
3. Every supported test subset is exposed as a named command, not as a raw file selector.

Current implementation:

- `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`,
  `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs` own the public parser, request ADT,
  registry, and command dispatch.
- `src/Prodbox/CLI/Spec.hs` is the typed `CommandSpec` source of truth for the supported command
  tree, and `src/Prodbox/CLI/Parser.hs` renders that registry over `optparse-applicative`.
- The frontend request ADT routes only to native Haskell commands; no Python delegation branch
  survives in the parser or entrypoint.
- Runtime ownership lives in Haskell modules under `src/Prodbox/`.
- Named test validations live in `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and
  `src/Prodbox/TestValidation.hs`.

This document defines the supported command contract only. Sequencing, completion status, and
cleanup ownership are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).
Where this document labels lifecycle behavior as the **target**, it defines the post-cutover command
contract rather than claiming that the current implementation already satisfies it. Migration and
deployment-qualification status remain exclusively in the Development Plan.

## 2. Global Surface

Top-level invocation:

```text
prodbox [--verbose|-v] [--version] <command> ...
```

Top-level commands (generated from `commandRegistry`; the `Purpose` column
is each command's registry summary):

The generated `dev` summary retains the generic phrase “Developer and CI tooling.” Under
[Code Quality Doctrine §2A](./code_quality.md#2a-development-tooling-policy), that means commands
usable by developers or externally invoked automation; it does not authorize a repo-owned
`.github/` workflow or another parallel check surface.

<!-- prodbox:command-surface-toplevel:start -->
| Command | Kind | Purpose |
|---------|------|---------|
| `admin-action` | Group | Attested exceptional-action worker |
| `aws` | Group | AWS IAM and quota management |
| `bootstrap-broker` | Group | Pre-Vault Bootstrap Broker operations |
| `credential-provisioner` | Group | Attested one-shot credential workers |
| `lifecycle-authority` | Group | Dedicated lifecycle-authority runtime |
| `provider-worker` | Group | Dedicated provider-worker runtime |
| `authority-backup` | Group | Dedicated authority-backup runtime |
| `tls-retention` | Group | Dedicated tls-retention runtime |
| `target-secret-agent` | Group | Dedicated target-secret-agent runtime |
| `charts` | Group | Bespoke Helm chart lifecycle |
| `cluster` | Group | Local cluster lifecycle |
| `commands` | Command | Render the command registry |
| `config` | Group | Configuration management |
| `dev` | Group | Developer and CI tooling |
| `dns` | Group | Route 53 inspection |
| `edge` | Group | Public DNS + TLS edge |
| `gateway` | Group | Gateway daemon operations |
| `help` | Command | Render help for a command path |
| `host` | Group | Host prerequisite checks |
| `nuke` | Command | Total teardown of every prodbox-owned AWS resource (operator-only) |
| `test` | Group | Named test suites |
| `users` | Group | Operator-invited user management |
| `vault` | Group | Vault secret-management lifecycle |
| `workload` | Group | Internal public workload runtime |
<!-- prodbox:command-surface-toplevel:end -->

## 2A. Operator Vocabulary Contract

Every string the operator can read at the terminal must use **operator
vocabulary**, not development-plan tracking vocabulary. Sprint
identifiers, phase numbers, and other dev-plan tracking labels are
confined to `DEVELOPMENT_PLAN/` and the governed engineering docs;
they must not leak into the binary or its generated artifacts.

### Operator-facing surfaces

The contract applies to every one of these surfaces:

- `prodbox <command> --help` output and any text in
  `src/Prodbox/CLI/Spec.hs` that contributes to it (flag-help
  strings, leaf descriptions, example help, group descriptions).
- Manpages under `share/man/man1/*.1`.
- Shell completions under `share/completion/{bash,zsh,fish}/*`.
- The generated CLI command reference at `documents/cli/commands.md`.
- Test goldens that capture operator-facing output at
  `test/golden/cli/*` (`commands.json`, `commands-tree.txt`,
  `help-all.txt`).
- Anything the binary writes to `stdout` / `stderr` at runtime,
  including phase banners, refusal messages, and the dry-run /
  plan-file renderers (`runNativeDeleteCascade`, `renderNukePlan`,
  `renderPreconditionFailures`, `renderTagSweepRefusal`,
  `renderDrainTimeoutRefusal`).

### Forbidden vocabulary in operator-facing strings

- Literal `Sprint <number>` or `Sprints <list>` (regardless of decimal
  depth: `4.11`, `7.5.c.v.f`, etc.).
- Phase numbers in the form `Phase <N>` when used as a tracking
  identifier rather than as part of an operator-visible "phase
  banner" the binary itself writes (e.g., `Phase 1/2 prerequisites`
  is fine; `Phase 7 substrate work` is not — the latter is a
  dev-plan label).
- Direct cross-references to `DEVELOPMENT_PLAN/` from the binary's
  output (operator should not have to read the dev-plan to act on a
  message; if the operator needs guidance, the message links to
  governed engineering docs under `documents/engineering/`).

### Required operator vocabulary

- Describe what the command does, what flags mean, what failure
  modes look like, what state changed.
- For refusals, name the canonical remedy command (`prodbox aws stack
  <stack> destroy --yes`, `prodbox cluster delete --cascade`, etc.) so
  the operator can re-run.
- For runbook references, link to operator-meaningful entries under
  `documents/` or operator-facing manpages — never `DEVELOPMENT_PLAN/`.

### Enforcement

`prodbox dev check` enforces this contract with a regex scan over
the operator-facing surfaces listed above. Any literal `Sprint
[0-9]` (case-sensitive, word-boundaried) or `Sprints [0-9]` outside
of comments-in-code or governed dev-plan files fails the gate. The
scan is implemented in `src/Prodbox/CheckCode.hs` alongside the
existing doctrine-alignment scans (forbidden subprocess primitives,
direct-stderr-write rules, generated-section integrity).

The contract does **not** apply to:

- Source-code comments and Haddock haddocks. These are developer
  documentation and routinely cite sprint identifiers for
  archaeology.
- `DEVELOPMENT_PLAN/` and every file under it.
- The governed engineering docs under `documents/engineering/`.
- `legacy-tracking-for-deletion.md` cleanup-ledger entries.

## 3. Command Matrix

> §2 (top-level command list) and the per-group matrix below are the
> **registry-derived operator surface** — every row is generated from the
> typed `commandRegistry` in `src/Prodbox/CLI/Spec.hs`, not hand-edited.
> `prodbox dev docs generate` rewrites the marker-delimited generated section
> below from `commandRegistry` (rendered by
> `renderCommandSurfaceMatrix` in `src/Prodbox/CLI/Docs.hs`), and
> `prodbox dev docs check` / `prodbox dev check` fail the build if it drifts
> from the parser. The "Arguments" column is sourced from each leaf
> command's typed positional `ArgumentSpec` list; the "Options" column
> lists each leaf's long flags. The per-command prose notes that follow
> each generated group table — owner modules, refuse-path semantics,
> lifecycle ordering, and the operator-vocabulary contract — are
> hand-maintained and intentionally live OUTSIDE the markers.

The per-group command matrix (generated; do not edit by hand):

<!-- prodbox:command-surface-matrix:start -->
### `prodbox admin-action`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox admin-action run` | none | `--action`, `--operation-id`, `--deadline-micros`, `--pod-name-file`, `--pod-uid-file`, `--service-account-token-file`, `--dry-run`, `--plan-file` |

### `prodbox aws`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox aws policy` | none | `--tier` |
| `prodbox aws setup` | none | `--tier`, `--dry-run`, `--plan-file` |
| `prodbox aws teardown` | none | `--dry-run`, `--plan-file`, `--destroy-pulumi-residue`, `--allow-pulumi-residue` |
| `prodbox aws quotas check` | none | none |
| `prodbox aws quotas request` | none | `--tier` |
| `prodbox aws ebs reap-test` | none | `--yes` |
| `prodbox aws stack eks reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox aws stack eks destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox aws stack eks prune-corrupt-checkpoint` | none | `--yes` |
| `prodbox aws stack test reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox aws stack test destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox aws stack test prune-corrupt-checkpoint` | none | `--yes` |
| `prodbox aws stack aws-subzone reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox aws stack aws-subzone destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox aws stack aws-subzone prune-corrupt-checkpoint` | none | `--yes` |
| `prodbox aws stack aws-ses reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox aws stack aws-ses destroy` | none | `--yes`, `--dry-run`, `--plan-file` |
| `prodbox aws stack aws-ses migrate-backend` | none | `--dry-run`, `--plan-file` |

### `prodbox bootstrap-broker`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox bootstrap-broker start` | none | `--config`, `--dry-run`, `--plan-file` |
| `prodbox bootstrap-broker secret-worker` | none | `--operation`, `--config` |

### `prodbox credential-provisioner`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox credential-provisioner run` | none | `--ingress-schema`, `--mode`, `--operation-id`, `--permit-id`, `--request-digest`, `--deadline-micros`, `--image-digest`, `--authority-scope`, `--authority-endpoint`, `--pod-name-file`, `--pod-uid-file`, `--service-account-token-file`, `--dry-run`, `--plan-file` |
| `prodbox credential-provisioner target-worker` | none | `--target`, `--target-agent-identity`, `--material-schema`, `--image-digest`, `--request-digest`, `--deadline-micros`, `--pod-uid-file`, `--pod-name-file`, `--service-account-token-file`, `--dry-run`, `--plan-file` |

### `prodbox lifecycle-authority`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox lifecycle-authority start` | none | `--config`, `--dry-run`, `--plan-file` |

### `prodbox provider-worker`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox provider-worker start` | none | `--config`, `--dry-run`, `--plan-file` |

### `prodbox authority-backup`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox authority-backup start` | none | `--config`, `--dry-run`, `--plan-file` |

### `prodbox tls-retention`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox tls-retention start` | none | `--config`, `--dry-run`, `--plan-file` |

### `prodbox target-secret-agent`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox target-secret-agent start` | none | `--config`, `--dry-run`, `--plan-file` |

### `prodbox charts`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox charts list` | none | none |
| `prodbox charts status` | `CHART` | none |
| `prodbox charts reconcile` | `CHART` | `--dry-run`, `--plan-file`, `--substrate` |
| `prodbox charts delete` | `CHART` | `--yes`, `--dry-run`, `--plan-file`, `--substrate` |

### `prodbox cluster`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox cluster status` | none | none |
| `prodbox cluster health` | none | none |
| `prodbox cluster start` | none | none |
| `prodbox cluster stop` | none | none |
| `prodbox cluster restart` | none | none |
| `prodbox cluster reconcile` | none | `--dry-run`, `--plan-file`, `--with-edge` |
| `prodbox cluster delete` | none | `--yes`, `--cascade`, `--dry-run`, `--plan-file` |
| `prodbox cluster logs` | none | `--lines` |
| `prodbox cluster federation register` | `CHILD` | `--dry-run`, `--plan-file`, `--child-vault-address`, `--child-kubeconfig`, `--child-endpoint`, `--child-kubeconfig-reference`, `--child-account-id`, `--child-pulumi-stack` |
| `prodbox cluster wait` | none | `--timeout`, `--namespace` |
| `prodbox cluster workload-logs` | none | `--namespace`, `--tail` |

### `prodbox commands`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox commands` | none | `--tree`, `--json` |

### `prodbox config`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox config setup` | none | `--dry-run`, `--plan-file` |
| `prodbox config show` | none | none |
| `prodbox config validate` | none | none |
| `prodbox config schema` | none | none |
| `prodbox config generate` | none | none |

### `prodbox dev`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox dev check` | none | none |
| `prodbox dev lint all` | none | none |
| `prodbox dev lint files` | none | `--write` |
| `prodbox dev lint docs` | none | `--write` |
| `prodbox dev lint haskell` | none | `--write` |
| `prodbox dev lint chart` | none | none |
| `prodbox dev docs check` | none | none |
| `prodbox dev docs generate` | none | none |
| `prodbox dev tla-check` | none | none |

### `prodbox dns`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox dns check` | none | none |

### `prodbox edge`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox edge reconcile` | none | `--dry-run`, `--plan-file` |
| `prodbox edge status` | none | `--substrate` |

### `prodbox gateway`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox gateway start` | none | `--config`, `--dry-run`, `--plan-file` |
| `prodbox gateway status` | none | `--config` |
| `prodbox gateway config-gen` | `OUTPUT_PATH` | `--node-id` |

### `prodbox help`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox help` | `COMMAND_PATH...` | none |

### `prodbox host`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox host ensure-tools` | none | none |
| `prodbox host check-ses-readiness` | none | none |
| `prodbox host check-ports` | none | none |
| `prodbox host info` | none | none |
| `prodbox host firewall gateway-restrict` | none | `--port` |
| `prodbox host firewall gateway-unrestrict` | none | `--port` |

### `prodbox nuke`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox nuke` | none | `--dry-run`, `--plan-file`, `--receipt`, `--local-data` |

### `prodbox test`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox test init` | none | `--force` |
| `prodbox test run` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test all` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test lint` | none | none |
| `prodbox test unit` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration all` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration cli` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration aws-iam` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration dns-aws` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration aws-eks` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration env` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration gateway-daemon` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration gateway-pods` | none | `--coverage`, `--cov-fail-under`, `--substrate`, `--record-profile` |
| `prodbox test integration control-plane-counterexample` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration teardown-recovery` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration certificate-scope` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration clean-room-handoff` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration cascade-qualification` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration ha-rke2-aws` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration lifecycle` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration pulumi` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration eks-volume-rebind` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-storage` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-platform` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration resource-guardrails` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration daemon-bootstrap` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration pulsar-broker` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-vscode` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-api` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration charts-websocket` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration admin-routes` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration public-dns` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration keycloak-invite` | none | `--coverage`, `--cov-fail-under`, `--substrate` |
| `prodbox test integration sealed-vault` | none | `--coverage`, `--cov-fail-under`, `--substrate` |

### `prodbox users`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox users invite` | `EMAIL` | `--role`, `--dry-run`, `--plan-file` |
| `prodbox users list` | none | `--status`, `--status-unverified` |
| `prodbox users revoke` | `EMAIL_OR_USER_ID` | `--delete`, `--dry-run`, `--plan-file` |

### `prodbox vault`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox vault status` | none | none |
| `prodbox vault init` | none | none |
| `prodbox vault reset-ambiguous-initialization` | none | `--yes` |
| `prodbox vault unseal` | none | none |
| `prodbox vault seal` | none | none |
| `prodbox vault reconcile` | none | none |
| `prodbox vault rotate-unlock-bundle` | none | none |
| `prodbox vault rotate-transit-key` | `KEY` | none |
| `prodbox vault pki status` | none | none |
| `prodbox vault pki issue-test-cert` | none | none |

### `prodbox workload`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox workload start` | none | `--config` |
<!-- prodbox:command-surface-matrix:end -->

### Historical `prodbox vault` transport record

The generated matrix above is the sole command inventory. The current leaves are part of the typed
command registry and have native handlers. Combined-gateway and direct-host transports are
pre-cutover history, not the target authority boundary; the authoritative target routing is defined
in the later [`prodbox vault`](#prodbox-vault) section. Implementation and migration status live
only in the [Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

Per-command intent (authoritative model in
[vault_doctrine.md § 7](./vault_doctrine.md#7-vault-lifecycle-commands)):

- `prodbox vault status` — report whether Vault is deployed, initialized, sealed/unsealed, and
  policy-reconciled through the daemon status route.
- `prodbox vault init` — idempotent init-if-empty; capture the unseal/recovery keys and root
  token once into the password-AEAD-sealed unlock bundle in the durable MinIO bucket.
- `prodbox vault reset-ambiguous-initialization --yes` — recover only when the Broker has durably
  classified initialization as ambiguous and independently proves the exact storage generation is
  resettable. The host cannot select a storage path, generation, Pod, or proof; omitting `--yes`
  refuses without mutation.
- `prodbox vault unseal` — prompt for the unlock-bundle password and unseal Vault; it posts the
  password to the daemon bootstrap endpoint, which reads MinIO and calls Vault in-cluster.
- `prodbox vault seal` — seal Vault (fail-closed back to the sealed-state invariant).
- `prodbox vault reconcile` — idempotently reconcile the baseline auth mounts, policies, roles, KV
  mount, Transit keys, PKI mount, and Kubernetes auth roles, in keeping with the single-reconcile
  doctrine. The daemon refuses uninitialized/sealed Vaults with redacted errors, decrypts the
  unlock bundle for the root token, then applies `Prodbox.Vault.Reconcile.defaultVaultReconcilePlan`.
- `prodbox vault rotate-unlock-bundle` — re-encrypt the unlock bundle under a new password
  without re-initializing Vault, through the authenticated daemon route.
- `prodbox vault rotate-transit-key <key>` — rotate a named Transit key version (envelope
  re-wrap is forward-compatible via the `prodbox-envelope-v2` tag).
- `prodbox vault pki status` / `prodbox vault pki issue-test-cert` — inspect the Vault PKI mount
  and issue a throwaway certificate for verification against the `prodbox-test` role once the PKI
  issuer sprint has configured it.

The sealed-state invariant, the typed `SecretRef` config contract, and startup-config sourcing
that these commands operate against are owned by
[vault_doctrine.md](./vault_doctrine.md); see
[vault_doctrine.md § 6](./vault_doctrine.md#6-the-unlock-bundle-root-cluster) for the unlock bundle and
[vault_doctrine.md § 7](./vault_doctrine.md#7-vault-lifecycle-commands) for the lifecycle
command contract.

### `prodbox config` notes

**A freshly generated `prodbox.dhall` is deliberately not deployable.** `prodbox config generate`
emits every operator-owned coordinate **empty** — `aws.region` alongside `route53.zone_id`,
`aws_substrate.hosted_zone_id`, `ses.*`, and `pulumi_state_backend.*` — and the first consumer of
each refuses by name with the command that authors it. That is the intended shape, not an
incomplete generator: a pre-filled coordinate is a value in force that nobody chose, and it makes
the refusal written against the field's absence unreachable code
([config_doctrine.md](./config_doctrine.md) § 0). `config generate` therefore produces a file that
loads, decodes, and passes the local tier, and that an AWS flow refuses until the operator supplies
the coordinates.

`src/Prodbox/Aws.hs` owns `config setup`. `src/Prodbox/Settings.hs` owns `config show` and
`config validate`. `prodbox config compile` is not part of the supported command surface. Sprint
`1.61` removed the `config show --show-secrets` unrestricted-reveal flag: `config show` now always
masks sensitive fields and there is no generic secret-reveal capability or flag alias. Target
`ConfigObserve` returns only a validated role-scoped projection and defines no generic secret-reveal
operation. Target
`config setup` writes/validates non-secret Tier 0 only; an optional prompt may support read-only AWS
discovery but cannot mutate or persist a credential. First `cluster reconcile` performs the visible
`GenesisFrozen -> EstablishAuthorityBackup -> BackupEstablished` action, then uses normal durable
Authority operations for Operational Lifecycle-provider/AWS-DNS01 and LongLived
TLS-retention/home Gateway-DNS/home-DNS01 identities. Generated identity keys are sealed/read back
only at their exact consumer. Cross-substrate SMTP and ACME EAB use retained-home payload-specific
Transit custody plus attested one-shot target rewrap. EAB arrives only through its own
schema-indexed external linear ingress under `OperatorMaterialPermit`; `config setup` never prompts
for or writes it, and the AWS admin prompt cannot substitute. No shared AWS key or secret payload is
written to config. The
`aws_admin_for_test_simulation.*` block is not a
production config section: it is a test-harness-only fixture in `test-secrets.dhall` that
simulates the operator at this prompt so the suite can drive admin-credentialed flows
non-interactively. See [vault_doctrine.md § 4](./vault_doctrine.md#4-config-split-production-references-vs-test-plaintext) and
[aws_admin_credentials.md](./aws_admin_credentials.md).

### `prodbox aws` notes

**`aws setup` is named by the region refusal without becoming a config author.** The three rules
that refuse an absent `aws.region` — `requireOperationalAwsRegion`,
`validateOperationalAwsCredentials`, and `validateLifecycleProviderAwsRegion` — name
`prodbox aws setup` as the remedy, and that remains a pointer to the interactive flow the operator
runs, not a claim that the command writes coordinates behind the operator's back. `aws setup`
persists no secret payload and authors no coordinate the operator did not enter at its prompt. The
admin-credential prompt offers **no pre-filled region** when the config carries none; the four
interactive entry points that reach `promptAdminCredentialsWithRegionChoice` immediately overwrite
any pre-fill from a live `aws ec2 describe-regions` selection, so with nothing configured the
selection simply opens on the first row of a list the operator is reading.

`prodbox aws policy` **prints** the grant an operator pastes into IAM, and it names the configured
`ses.capture_bucket`. It refuses when that coordinate is unconfigured rather than substituting a
name, for the same reason as above: a printed grant naming a bucket the deployment does not own
becomes a real IAM policy, and the mistake surfaces as an `AccessDenied` from S3 rather than as a
refusal from prodbox.

`src/Prodbox/Aws.hs` owns the full public `prodbox aws ...` surface. **Target contract:** the public
flow uses the interactive `SecretRef.Prompt` arm only for setup/teardown, a permit-bound SMTP IAM
install/rotation/repair when needed, and explicit admin-authorized destructive/compatibility
operations. Canonical `aws-ses reconcile`
submits a durable provider intent and resolves the Lifecycle-provider generation solely to assume
the exact fixed SES lease role for non-credential SES/S3/DNS work. Its deterministic SMTP IAM
identity, least-privilege policy, and finite key family are a separate `OperatorMaterialPermit`
program owned only by Credential Provisioner. That Provisioner alone creates, rotates, remints, or
performs repair-time deletion of uncommitted/unrecoverable keys. In bounded memory it derives the
region-bound closed `SesSmtpSource` from the one-time IAM secret and discards the raw AWS
secret-access-key bytes; a successful create is not committed until a retained-home Agent has
Transit-sealed that payload and returned a custody receipt. Explicit
`DestroyAwsSes` is the sole exception to its deletion ownership: an `AdminActionPermit` lets Admin
Action Runner destroy/read back the entire registered IAM family, but never create, rotate, or
remint it. Provider/Pulumi never owns that family. The
`aws_admin_for_test_simulation.*` block is not part of public `aws setup` and is not a production
config section: it is a test-harness-only fixture in `test-secrets.dhall` that simulates the
operator at admin prompts.

**Historical pre-cutover residue-policy record.** `prodbox aws teardown` carries the Sprint `7.6`
orphan-safety refuse-path: it refuses to delete
the operational IAM user while any Pulumi-managed stack (`aws-eks`, `aws-eks-subzone`,
`aws-test`, `aws-ses`) still reports live resources, naming the offending stack(s) and the
canonical destroy command. Three residue-policy outcomes are available, all driven by
mutually-exclusive flags:

- (default, no flag) → **refuse** with actionable message.
- `--destroy-pulumi-residue` → **destroy first**: dispatch `prodbox aws stack <stack> destroy
  --yes` for each live stack in canonical order (`aws-subzone`, `aws-eks`, `aws-test`,
  `aws-ses` if live) before continuing with the IAM teardown. A stderr warning fires before
  the `aws-ses` destroy because reprovisioning it costs 5-30 min of SES DKIM re-verification
  + ~24h of S3 bucket-name cooldown.
- `--allow-pulumi-residue` → **accept orphan**: operator-acknowledged bypass.

The two flags are mutually exclusive at parse time: passing both produces "Invalid option"
exit 1 from optparse-applicative via the `flag' <|> flag' <|> pure RefuseOnAnyResidue` idiom
in `awsTeardownFlagsParser`. The `prodbox aws teardown --help` usage line displays them as
`[--destroy-pulumi-residue | --allow-pulumi-residue]` to make the exclusivity visible.

Sprint `7.7` also moved the file-based residue check **before** the ephemeral elevated-credential
prompt and added a "Nothing to do." exit (zero) when residue is empty AND operational
`aws.*` is empty, so the operator never enters credentials that the tool was about to refuse.
The credential prompt itself auto-detects the access-key prefix and only asks for a session
token when the operator pastes an `ASIA…` (STS-derived) key — `AKIA…` (long-lived IAM user
key) skips the session-token prompt entirely.

### `prodbox host` notes

`src/Prodbox/Host.hs` owns the full public `prodbox host ...` surface.

`prodbox host firewall gateway-restrict` (Sprint `2.18`) is the idempotent installer for
the iptables INPUT-DROP rule that restricts the gateway-service NodePort to `127.0.0.1`
on the operator host. `prodbox host firewall gateway-unrestrict` is its inverse — the
idempotent remover of that INPUT-DROP rule. Both take an optional `--port` knob
(default the pinned gateway NodePort) so the rule and its removal target the same port.
`prodbox cluster reconcile` invokes the installer as part of the host post-install phase;
`prodbox cluster delete --yes` removes the rule on clean teardown. The rule survives reboot
via `iptables-save` to the host's persistence path. Authoritative contract:
[Secret Derivation Doctrine](./secret_derivation_doctrine.md) §5.

The target public-edge doctrine for that surface is defined in
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md). `prodbox edge status`
classifies Route 53 ownership, Envoy Gateway readiness, Gateway API attachment, HTTP redirect
listener readiness, HTTPS listener readiness, redirect `HTTPRoute` acceptance, `SecurityPolicy`
attachment, certificate readiness, the shared-host `/auth`, `/vscode`, `/api`, `/ws`,
and `/minio` routes, and readiness for named external proof.

### `prodbox cluster` notes

`src/Prodbox/CLI/Rke2.hs` owns the full public `prodbox cluster ...` surface.

`prodbox cluster reconcile` is the canonical lifecycle reconciler. `install`, `upgrade`, `repair`,
and `force-install` are forbidden sister commands rejected at parse time.

`prodbox cluster delete --yes` is hermetic on success: when
`/usr/local/bin/rke2-uninstall.sh` exits `0`, only the doctrine-owned summary lines reach the
operator terminal — `Deleting local RKE2 environment...`, `Local RKE2 substrate: cleanup
complete`, the kubeconfig disposition, and the `Preserved host state:` boundary. Local-only delete
has no AWS disposition to render because it never observes or mutates AWS. Benign upstream
uninstall chatter the uninstaller writes to its
own stdout/stderr — `Cannot find device "cni0"`, `semodule: not found`, and
`Cleanup completed successfully` — is captured through the lifecycle-local quiet path in
`src/Prodbox/CLI/Rke2.hs` (`captureToolOutput` plus `isIgnorableRke2DeleteNoiseLine`) and never
surfaces as a red-herring error. The inotify warning `Failed to allocate directory watch: Too many
open files` is the exception: the systemd manager (PID 1) / journald emits it out-of-band to the
console rather than through the uninstaller's captured fds, so `captureToolOutput` cannot suppress
it and it may still appear on the operator terminal on a successful run (benign — teardown still
succeeds; the filter entry only catches the line on the rare path where systemd routes it to the
captured stderr). When the uninstaller exits non-zero, the actionable upstream lines are still
surfaced through `summarizeRke2DeleteFailure` so the operator can act on the real failure.

`prodbox cluster delete` has a shipped **pure local cluster uninstall** mode and a target
recover-to-clean `--cascade` contract. The latter is not a claim of current-revision cutover; its
implementation and qualification remain plan-owned.

Local-only delete probes for an installed RKE2 from the on-disk markers. When none is present, it
prints `No RKE2 cluster to delete.` and exits `0`.

Cascade does not use that shortcut. Local absence answers neither for AWS nor for a durable cleanup
run, so cascade enters recovery as defined by
[Lifecycle Reconciliation Doctrine §5a](lifecycle_reconciliation_doctrine.md#5a-local-only-no-install-short-circuit),
and a cascade that reached no phase exits non-zero carrying the recovery-plane disposition it
reports. The arm is selected by the delete mode over the (mode, presence) product: exactly one arm
is a no-install success and it belongs to local-only delete, so no later caller can hand the cascade
mode a success it did not observe.

No cascade exit authorizes deleting the retained root. The retained-state narration is a total
function over the command's terminal arms: only an arm carrying a completion receipt or an explicit
local-only uninstall says the root is preserved by what it did, and every other arm either says
nothing about the root or names it and states that this run establishes nothing about retiring it.

- (default, no flag) → **pure local uninstall**. It uninstalls RKE2 and preserves `.data/` (the
  MinIO-backed per-run Pulumi state) WITHOUT querying, gating on, or destroying the per-run AWS
  Pulumi backend. Per-run AWS stacks (if any) are left untouched and remain destroyable
  afterward via `--cascade` or `prodbox aws stack <name> destroy --yes` once the required recovery
  capabilities are observable. Preserving `.data/` retains the state inputs needed for recovery; it
  does not prove those inputs readable, establish Lifecycle Authority or provider observability, or
  prove that cleanup can currently proceed.
- `--cascade` (target) → **start or resume recover-to-clean teardown**. The command obtains a durable
  `CleanupRunId`, repairs the minimal teardown control plane when required, observes every per-run
  resource by exact registered key, reconciles desired absence, satisfies the terminal-audit
  requirement through either a clean scoped AWS audit or an exact no-AWS projection, and commits
  and backs up the pre-uninstall convergence report. That report, the one-shot permit, positive
  recovery-plane witness, exact convergence, and terminal-audit evidence can yield only
  `ReadyToUninstallEvidence`; after local RKE2 uninstall, exact host absence plus the scoped local
  completion receipt yields `CascadeComplete`. A missing or stopped local installation is a
  recovery case, not a cascade no-op. Incomplete cleanup exits
  non-zero with the stable run ID and renders the typed recovery-plane disposition. It may say the
  minimal profile and required credentials remain live only when establishment was positively
  confirmed; an establishment failure remains a distinct retryable failure. A global tag audit never
  selects a stack or proves one absent. The
  [Lifecycle Reconciliation Doctrine §5b](lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
  is the sole internal graph/order reference.

The current parser routes both modes through `runPlanWithOptions` (Sprint `4.26`), so `--dry-run`
renders the plan and exits `0` **without mutating**, and `--plan-file` writes it. At target cutover,
dry-run and apply are projections of the same closed result-indexed cleanup program; narration is
derived from its typed node tags rather than a separately maintained `per_run_destroy` phase list.
The pre-cutover phase renderer is migration inventory tracked in the
[legacy deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). The
`checkPlanOptionsHonored` lint ([code_quality.md](code_quality.md)) forbids any destructive
dispatch arm from wildcarding its `PlanOptions` away, the regression guard for the historical
`cluster delete --yes --dry-run`-silently-mutates bug.

`aws-ses` is **explicitly excluded** from `prodbox cluster delete`'s residue scope regardless of
flag because its `LongLived` cleanup class is retained across cluster teardown. Its main Pulumi
checkpoint now uses the encrypted Model-B object in MinIO; ordinary cluster deletion preserves the
underlying `.data/`, while the retained S3 bucket is only the public-edge TLS store and optional
first-touch source for legacy `aws-ses` checkpoints. Sanctioned destroy paths for `aws-ses` are
`prodbox aws stack aws-ses destroy --yes` (explicit) and `prodbox nuke` (total teardown). See the
[managed-resource registry](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
for the typed lifecycle-class boundary and the
[substrate inventory](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes) for the
registry-generated concrete assignments.

### `prodbox nuke` notes

`src/Prodbox/CLI/Nuke.hs` owns the operator-only total-decommission surface. `prodbox nuke` is the
**only** sanctioned command that destroys long-lived shared infrastructure transitively (`aws-ses`
stack, the long-lived `pulumi_state_backend` bucket). For per-stack teardown of `aws-ses` alone,
use `prodbox aws stack aws-ses destroy --yes`.

The current parser exposes `--receipt <path>` and `--local-data <retain|delete>`; dry-run may omit
either, while apply refuses before mutation when either is absent. `--local-data` is the operator's
explicit disposition of the retained local data root (the configured manual PV host root). It has no
default because both candidate answers silently decide the fate of retained data and one of them is
irreversible; the decision is a parameter of the signed `LocalDataDisposition` manifest node, so it
enters the manifest digest and the frame node identity and a receipt opened for a `retain` run
cannot be resumed as a `delete` run. The production composition binds the authenticated decommission
manifest to that external receipt and runs the standalone Decommission Runner. A new path is
fsynced and acknowledged before the point of no return. The external receipt sink must durably
contain and reopen the signed manifest plus the
exact digest-pinned Decommission Runner artifact, closed program/schema, and verifier outside every
manifest deletion target. Authority may permanently stop only after that full receipt is committed
and read back. An existing matching path resumes the same manifest with the same build/schema;
different runner bytes, verifier, or schema reject before prompt or mutation. The receipt is
non-secret and remains operator/harness-owned after managed storage is destroyed.

**Current-versus-target bound.** The shipped manifest/receipt graph no longer ends at its registered
shared-bucket node. An ordered terminal phase follows the last resource deletion: the final
no-retention escape audit, the home-substrate uninstall and its marker read-back, the operator's
explicit `.data` retain-or-delete disposition and its read-back, and the terminal receipt — a node
that refuses unless the receipt's own committed frames already record every other plan node as
durably terminal, so its success frame is the record's declaration that the run converged. The
out-of-band `runNukeTerminalTagSweep` tail that used to run after the receipt runner returned success
— outside the resumable graph, where a crash or a lost response could not resume through the manifest
— is gone. The remaining gap is bidirectional program-tag parity: seventeen of the twenty-one
semantic total-decommission operations are still implemented by exactly one of the two sides, so
`TotalDecommissionCompleteEvidence` is not yet constructible. Implementation and removal status live only
in the [Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here) and its
[Pending Removal ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md#pending-removal).
Like every admin-credentialed flow, it acquires elevated AWS power through the one unified
runtime path — the interactive `SecretRef.Prompt` arm: after the typed confirmation gate the
operator supplies the ephemeral elevated credential at the prompt (held in memory for the one
command, used once, discarded). The test harness automates that prompt by feeding the
`aws_admin_for_test_simulation.*` fixture from `test-secrets.dhall`. There is no stored admin
section in production config and no `SecretRef.Vault` admin ref — the simulation fixture
is `TestPlaintext` in `test-secrets.dhall`, never a Vault object.

Discipline (mirrors `aws teardown`):

- **TTY-only.** Refuses non-interactive contexts with a message naming the canonical command
  sequence to compose manually. There is no automation path.
- **Typed confirmation.** Operator must type the literal string `NUKE EVERYTHING` (not `yes`)
  at the confirmation prompt. The unusual shape is the safety feature.
- **No `--yes` shorthand.** Deliberate omission.
- **`--dry-run` / `--plan-file`** render the exact sequence without mutating. Sprint `4.26`
  routes `prodbox nuke` through `runPlanWithOptions` (reading `nukeDryRun` / `nukePlanFile`),
  so the TTY guard, the typed-confirmation prompt, and the orchestration all live inside the
  apply closure — `--dry-run` never prompts or mutates.

The target order is the signed manifest's typed dependency graph, not the pre-cutover flat
stack-first list. It quiesces/read-backs workload and SMTP consumers while the home and selected
Target Agents remain live; exports/read-backs the manifest plus pinned runner/verifier; stops
Authority; then lets the standalone runner delete/read back the external SMTP and non-credential
SES/S3 families. Only after external credential absence does it physically destroy target SMTP/EAB
and retained-home custody KV-v2 versions/metadata and read back absence through the still-live
Agents. TLS prefix/identity,
per-run stacks, Operational IAM, home control plane, and the explicit `.data` disposition follow only
after their registered dependants are absent. The final Authority-backup objects, identity, and
shared bucket are then deleted and read back through the external receipt protocol. Only after those
exact obligations does the runner perform the **terminal escape audit**, then uninstall the home
substrate, then apply the operator's signed `.data` disposition, then take the **terminal receipt**,
appending each result to the external receipt. An escaped resource or unobservable audit makes the terminal result incomplete and
non-zero, but the audit never selects an earlier deletion or substitutes for its exact evidence. See
[Lifecycle Reconciliation Doctrine §6b](lifecycle_reconciliation_doctrine.md#6b-nuke-transfers-authority-to-an-external-decommission-receipt)
for the canonical order and receipt boundary.

### `prodbox aws stack` notes

`src/Prodbox/CLI/Pulumi.hs` owns the full public `prodbox aws stack ...` surface.

The target permits one bounded Plan/Apply adoption path for a pre-cutover per-run stack; this is an
internal recovery boundary, not an invented current command. Read-only provider discovery cannot
authorize mutation. The operator must receive the complete exact candidate plan and digest and
explicitly authorize that digest; receipt/read-back then mints the legacy ownership manifest before
normal desired-absence reconciliation. Ambiguous, partial, or unobservable observation refuses. See
[Lifecycle Reconciliation Doctrine §3.2](lifecycle_reconciliation_doctrine.md#32-checkpoint-recovery-and-the-desired-absence-decision)
for the canonical protocol.

`prodbox aws stack aws-ses migrate-backend` is a legacy operator-interactive (TTY-only)
compatibility command. Sprint `7.14` moved the main `aws-ses` reconcile/destroy/read paths to the
encrypted decrypt-to-scratch backend; this command now opens the same wrapper and triggers
first-touch import/delete from the old long-lived S3 source when encrypted state is absent. It
also removes every legacy secret-bearing Pulumi output before committing/read-backing the sanitized
current checkpoint. The old immutable primary and mandatory-backup blobs are not indefinite
retention: after the Authority reference graph proves no operation/current-checkpoint/rollback
reference and the bounded rollback window expires, fenced GC deletes and reads back both copies.
Migration never exposes those outputs as a recovery or export surface. The command refuses
non-interactive contexts. See
[aws_integration_environment_doctrine.md §4.5](./aws_integration_environment_doctrine.md)
for the current backend contract and why this command is not part of the automation path.

**Target contract:** `prodbox aws stack aws-ses reconcile` is the one desired-present operation for
retained SES. It is
idempotent across first creation, converged state, ordinary drift, and the bounded missing-checkpoint
recovery that imports the stack's fixed-name capture bucket, SES identities/rules, and DNS records.
Provider/Pulumi owns only those non-credential SES/S3/DNS resources. The deterministic SMTP IAM
identity, least-privilege policy, and finite access-key family are observed/reconciled separately by
Credential Provisioner under a backup-receipted `OperatorMaterialPermit`. That Provisioner alone
creates, rotates, or remints material and deletes an uncommitted or unrecoverable key during repair.
It must classify AWS observation as `Absent | Present | Unobservable` and fail closed on the last
case; an AWS client failure is never proof of absence.

The command binds one operation-indexed Lifecycle Authority `CapabilityRef` and uses it unchanged
for observation, admission, durable submission, and result observation. It prints the durable
operation ID; if a response is lost or the caller's absolute deadline expires, retry/recovery
observes that same ID rather than inferring rollback or starting a second mutation. The committed
Lifecycle-provider generation assumes `prodbox-ses-lease-session` only for the corresponding
narrow non-credential provider fence; there is no shared operational `aws.*` identity and no
provider credential-mutation fence. Provider propagation holds no broad lease. In bounded memory,
Credential Provisioner derives the region-bound closed `SesSmtpSource` from the one-time IAM secret,
discards the raw AWS secret-access-key bytes, and sends only `SesSmtpSource` over authenticated
linear ingress to a one-shot retained-home Agent worker. That worker Transit-seals it and returns a
typed source-custody receipt. Later delivery outbox work routes only ciphertext/receipts to attested
one-shot home and selected-target Agent workers; the selected worker materializes/read-backs its
local generation.
This rebuild path requires neither an admin re-prompt nor IAM-key rotation, and exposes no generic
export. Gateway Runtime participates in none of these operations. Ordinary postflight retains
`aws-ses`, its SMTP IAM family, and source custody. Explicit `DestroyAwsSes` runs through Admin
Action Runner after consumers quiesce, destroys/read-backs the registered external SMTP
identity/policy/key family, and composes that evidence with non-credential stack absence. Only then,
while both Agents remain live, it physically destroys every owned target/source-custody KV-v2
version, deletes/read-backs metadata, and proves absence. A soft delete or new logical tombstone is
not teardown. Rotation retains the
current generation and physically destroys only dependency-free superseded versions.
This whole-family deletion is the sole exception to Credential Provisioner's
deletion ownership; Admin Action Runner cannot create, rotate, or remint SMTP credentials. `nuke`
uses the same external-first, target-then-custody physical-deletion ordering from its signed
decommission manifest, not a generic secret export. Internal transition semantics belong to Lifecycle Reconciliation
Doctrine and physical ownership to Lifecycle Control-Plane Architecture. The canonical suite ordering is
[AWS Integration Environment Doctrine §4.6](./aws_integration_environment_doctrine.md#46-retained-ses-desired-presence-preparation).

`prodbox host check-ses-readiness` is the read-only operator diagnostic for the same semantic
boundary. It performs one structured sender/DKIM, exact MX/receipt-rule, and operational capture
canary list/get observation and reports the current Ready, Pending, Failed, or Unobservable state.
It neither reconciles nor destroys SES resources and is not an automation alias for preparation.

This matrix is the supported entrypoint set for AWS substrate provisioning and teardown.
The `prodbox` surface is the exclusive AWS mutation boundary. In the target composition the CLI,
validation, recovery, and explicit stack commands are authenticated clients of the retained local
Lifecycle Authority. AWS is an optional target substrate; the local RKE2 control plane remains
mandatory and effects execute only through the exact fenced worker or permit-indexed
adapter/runner. Unavailable Authority/admission fails closed and never selects a host-direct
Pulumi/provider fallback. The
current stack commands, validation wrapper, and bespoke cascade remain separate pre-cutover
compositions; status and migration ownership live in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here). Agent/operator
authorization is not defined here; it is owned by
[AGENTS.md, “AWS Mutation Is Prodbox-Surface-Owned”](../../AGENTS.md#aws-mutation-is-prodbox-surface-owned).
Per-resource
lifecycle classification (cleanup-managed per-run stacks vs long-lived cross-substrate shared
infrastructure retained by design) lives in
[`DEVELOPMENT_PLAN/substrates.md` → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).

Each Pulumi-managed substrate stack's registry name, Pulumi stack id, project subdir, CLI verb
stem, and lifecycle class are a single `Prodbox.Infra.StackDescriptor` SSoT record (Sprint
`4.27`); the `prodbox aws stack <stem> reconcile` / `<stem> destroy` verbs above all derive from it.
The registry-name↔CLI-command inventory is rendered from that SSoT into the
`stack-command-surface` generated section of
[`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
and kept in sync by `prodbox dev docs generate` / `docs check`.

`prodbox aws stack eks destroy --yes`, `prodbox aws stack aws-subzone destroy --yes`,
`prodbox aws stack test destroy --yes`, and `prodbox aws stack aws-ses destroy --yes` report one-line
stack destroy disposition instead of replaying Pulumi login chatter on successful cleanup. On
destroy failure, each path refreshes Pulumi state and retries destroy once before surfacing the
cleanup error.

No supported local-cluster platform or application deployment depends on a root Pulumi project.

### `prodbox dns` notes

`src/Prodbox/Dns.hs` owns the public DNS inspection surface.

### `prodbox cluster` notes

`src/Prodbox/K8s.hs` owns the public Kubernetes helper surface.

### `prodbox gateway` notes

`src/Prodbox/Gateway.hs` owns the public gateway surface and `src/Prodbox/Gateway/Daemon.hs`
owns the daemon runtime. `prodbox gateway status` queries the daemon's operator-facing
bounded `/v1/state` endpoint over HTTP on the configured REST port.

`prodbox gateway start` takes a single startup-time knob — `--config <path>` — plus the
universal `--dry-run` / `--plan-file` plan renderers, per
[config_doctrine.md §2](./config_doctrine.md#2-single-dhall-surface-per-binary-instance)
and §4's [Daemon-launching flags](#daemon-launching-flags) contract. Sprint 2.24 removed
the legacy `--log-level`, `--port`, and `--foreground` override flags (and the `workload
start` equivalents) along with their daemon threading; the daemon now sources `log_level`
from the mounted Dhall (`live.log_level`, defaulting to `info`) and its REST port from the
Orders file exclusively (see
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)).
Every value the daemon needs already lives in the Dhall file, so the override flags were
redundant, not load-bearing. This matrix row and the §4 prose are now the same
single-`--config` contract.

This `gateway` command group refers to the Haskell distributed gateway daemon, not to the
Kubernetes Gateway API or Envoy Gateway controller.

### `prodbox workload` notes

`src/Prodbox/Workload.hs` owns the internal public workload runtime used by the `api` and
`websocket` chart surfaces. It is repo-rootless and selects its runtime mode (api vs.
websocket) from the `workload.mode` field of its mounted Dhall config (see
[config_doctrine.md](./config_doctrine.md)). The current `websocket` runtime owns the
workload-managed OIDC bootstrap under `/ws/oidc`, the JWT-protected `/ws` upgrade path, and
readiness-based drain for live upgraded connections.

### `prodbox charts` notes

`src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/Lib/Storage.hs`, and `src/Prodbox/PostgresPlatform.hs` own the public chart surface
and its canonical external Patroni naming contract.

For `prodbox charts status|reconcile|delete`, `CHART` must be one of the
root chart names `gateway`, `keycloak`, `vscode`, `api`, or
`websocket`. Internal `keycloak-postgres` and `redis` dependency
releases are runtime-owned implementation details and are not supported
public CLI arguments.

`prodbox charts reconcile <chart>` is the canonical idempotent reconcile for the chart surface:
rerunning it against an already-deployed healthy release is a success no-op rather than a force
or reinstall path.

The supported chart doctrine does not permit embedded chart-local PostgreSQL subcharts.
`keycloak-postgres` is an internal namespace-local Patroni dependency release, and chart deploy
fails fast until `prodbox cluster reconcile` has reconciled the cluster-wide `postgres-operator`
platform.

The current public chart surface ships:

- Keycloak on the substrate's validated shared hostname under `/auth`
- redirect-only HTTP on port `80`, which permanently redirects to the same shared-host path over
  HTTPS
- `vscode` on `/vscode`, protected by Envoy Gateway `SecurityPolicy`
- `api` on `/api`, protected by Envoy-local JWT validation plus route claims
- `websocket` on `/ws`, with workload-managed OIDC bootstrap on `/ws/oidc`, a JWT-protected `/ws`
  upgrade path, and an internal `redis` dependency for shared state
- the separate Haskell distributed `gateway` chart, which is not the Envoy Gateway public edge

### `prodbox users` notes

`src/Prodbox/CLI/Users.hs` owns the operator-facing Keycloak user-management surface for the
Phase 8 invite flow. `prodbox users invite <email>` creates a Keycloak user with
`emailVerified=false` and triggers the SES-backed invite email; `--role` assigns an
operator-defined role on invite. `prodbox users list` reports users with their
email-verification status and last-login time, optionally filtered by status (`--status`
alone selects verified users; `--status-unverified` restricts to users awaiting invite
activation; the default lists all). `prodbox users revoke <email-or-id>` disables an
operator-managed user by default, or fully deletes it with `--delete`.

### `prodbox commands` and `prodbox help` notes

`src/Prodbox/App.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Docs.hs`,
`src/Prodbox/CLI/Tree.hs`, and `src/Prodbox/CLI/Json.hs` own the introspection surface. The
registry-backed `commands`, `commands --tree`, `commands --json`, and `help <path>` outputs are
the canonical in-process CLI documentation surface.

### `prodbox test` notes

`prodbox test` and `prodbox test integration` are help groups only. They do not run an implicit
default suite. The per-command rows (options column) live in the generated matrix above; the
tables below add the test-only `Scope` and shared-option semantics.

Shared executable-suite options:

| Option | Meaning |
|--------|---------|
| `--coverage` | Enable coverage mode for the selected scope |
| `--cov-fail-under INTEGER` | Require a minimum coverage percentage; valid only with `--coverage` |
| `--substrate {home-local\|aws}` | Select the substrate the run targets; default `home-local`. Each per-substrate run is substrate-locked: it consumes only that substrate's operator-supplied config (the `Required Config` row in [`DEVELOPMENT_PLAN/substrates.md`](../../DEVELOPMENT_PLAN/substrates.md)) and fails fast if any required field is missing. There is no fallback between substrates. A complete canonical-suite proof requires both substrate runs to land independently; see [`DEVELOPMENT_PLAN/development_plan_standards.md` § M — Substrate coverage and independence (no fallback)](../../DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback). |

Named suite commands:

| Command | Scope |
|---------|-------|
| `prodbox test all` | Aggregate Haskell unit and integration surface |
| `prodbox test lint` | `prodbox dev check` plus `cabal build --builddir=.build all` |
| `prodbox test unit` | `test:prodbox-unit` |
| `prodbox test integration all` | Aggregate integration surface |
| `prodbox test integration cli` | `test:prodbox-integration` |
| `prodbox test integration env` | `test:prodbox-integration` |
| `prodbox test integration aws-iam` | Native IAM lifecycle validation |
| `prodbox test integration dns-aws` | Native Route 53 lifecycle validation |
| `prodbox test integration aws-eks` | Native EKS validation |
| `prodbox test integration gateway-daemon` | Native gateway daemon validation |
| `prodbox test integration gateway-pods` | Native gateway pod validation |
| `prodbox test integration gateway-partition` | Native gateway partition validation |
| `prodbox test integration ha-rke2-aws` | Native HA RKE2 AWS validation |
| `prodbox test integration lifecycle` | Native destructive lifecycle validation |
| `prodbox test integration pulumi` | Native Pulumi validation |
| `prodbox test integration charts-storage` | Native chart storage validation |
| `prodbox test integration charts-platform` | Native chart platform validation |
| `prodbox test integration charts-vscode` | Native external `vscode` validation |
| `prodbox test integration charts-api` | Native external API validation |
| `prodbox test integration charts-websocket` | Native external WebSocket validation |
| `prodbox test integration admin-routes` | Native shared-host MinIO console route validation |
| `prodbox test integration public-dns` | Native public DNS delegation validation |
| `prodbox test integration keycloak-invite` | Native Keycloak operator-invite validation (Phase 8 invite flow) |
| `prodbox test integration eks-volume-rebind` | Native retained-volume rebinding validation |
| `prodbox test integration resource-guardrails` | Native resource-guardrail validation |
| `prodbox test integration daemon-bootstrap` | Native daemon-bootstrap transport validation |
| `prodbox test integration pulsar-broker` | Native Pulsar broker transport validation |
| `prodbox test integration sealed-vault` | Native sealed-Vault fail-closed validation |

`src/Prodbox/TestRunner.hs` owns the public `prodbox test` entrypoint. It:

- runs Haskell suites through `cabal test`
- runs `prodbox test lint` before any Haskell or native validation payload when `prodbox test all`
  is selected
- enforces an initial fail-fast prerequisite gate, visible runbook/bootstrap steps when required,
  and deferred cluster-backed backend proofs such as `pulumi_logged_in` before payload execution;
  prerequisite checks remain read-only and never hide desired-state mutation
- runs the current shared-IAM harness for `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` before AWS-backed prerequisite checks
  begin. That pre-cutover path still materializes and clears the shared operational identity; the
  target role-specific Operational/LongLived split and dependency-ordered revocation remain
  plan-tracked
- applies the canonical aggregate ordering
- uses the `aws_admin_for_test_simulation.*` fixture from `test-secrets.dhall` only to simulate
  the operator's elevated-credential prompt for operational setup/teardown, suite-driven
  destructive validation, and long-lived destroy/migration flows; the fixture never reaches production config, Vault, or generated
  cluster config
- performs supported-runtime bootstrap and postflight when required
- derives one visible retained-SES preparation plan when the selected validation set contains
  `ValidationKeycloakInvite` and runs the current
  `acquire -> reconcile -> await-ready -> sync-target -> release` interpreter against distinct
  checkpoint-authority and target-sink inputs. The current callback-era interpreter calls the
  registered ensure directly; it does not yet submit the target durable operation ID or observe a
  target outbox. That migration remains plan-tracked
- excludes retained `aws-ses` from ordinary suite cleanup on success, failure, and Ctrl-C; only the
  explicit long-lived destroy surfaces remove it
- enters `runWithAwsHarnessCleanup` before IAM setup or any mutation that can create a selected
  per-run AWS resource. The authenticated descriptor-bound client selects exact registry keys;
  lifecycle core owns graph/operation-ID compilation, Authority registration, closed ordinary
  dispatch, same-run restart, exact terminal observation, and the node-success decision. Local
  config/RKE2/Vault desired-presence preparation necessarily precedes this ordinary descriptor
  because it establishes the retained Authority. Operational IAM teardown remains a legacy tail
  pending Sprint `6.5`, and runs only when the lifecycle-owned exact node decision permits it
- waits for `prodbox edge status` to report `CLASSIFICATION=ready-for-external-proof` before
  external `charts-vscode`, `charts-api`, `charts-websocket`, or `admin-routes` proof continues
  on the supported-runtime path
- proves the public HTTP-to-HTTPS redirect on port `80` as part of the public-host validation
  surface, while preserving the HTTPS auth, route, certificate, and RBAC proofs on port `443`
- dispatches named real-world validations through `src/Prodbox/TestValidation.hs`

### `prodbox dev check` notes

`src/Prodbox/CheckCode.hs` owns the public `prodbox dev check` entrypoint.

The supported command runs the repository-owned workflow or hook policy scan, Fourmolu, HLint,
warning-clean `cabal build`, and the final operator binary sync. Detailed Haskell quality doctrine
is defined in
[Haskell Code Guide](./haskell_code_guide.md).

The policy-scan portion is scoped to repo-owned surfaces and excludes generated or retained
runtime roots such as `.build/`, `dist-newstyle/`, and `.data/`.

### `prodbox dev tla-check` notes

`src/Prodbox/Tla.hs` owns the public TLA+ validation surface.

## 3A. Interactive vs Non-Interactive Surfaces

`prodbox` has two parallel paths for operator-credential work. The
**operator-interactive surface** (`prodbox config setup`,
`prodbox aws setup`, `prodbox aws teardown`, `prodbox aws quotas check`,
`prodbox aws quotas request`, and the `prodbox charts delete`
confirmation prompt) reads input from stdin. The **non-interactive
automation surface** (the managed test harness — `prodbox test all`,
`prodbox test integration all`, `prodbox test integration aws-iam`, and targeted
`prodbox test integration <name> --substrate aws` validations) drives the same
interactive admin-credential prompt non-interactively: the suite-level IAM harness
simulates the operator at the `SecretRef.Prompt` arm by feeding the
`aws_admin_for_test_simulation.*` fixture from `test-secrets.dhall`, reconciles and
generation-CAS delivers each required role-specific identity, revokes only Operational identities
through the cleanup DAG, and observes/retains every LongLived generation—including the SMTP IAM
family and retained-home source custody—on suite exit. EAB automation uses only the separate
`acme_eab` fixture projected into its closed external-material ingress; it cannot substitute for or
be supplied by the AWS admin fixture. There is no production "config-backed admin path" that reads
stored admin credentials from production config.

`prodbox aws stack aws-ses reconcile` is a hybrid surface whose pure plan determines the input
branch before external mutation: converged provider work and selected-target restore from retained
`SesSmtpSource` custody need no prompt, while an exact install/rotation/repair action requires a TTY
AWS-admin frame routed only to Credential Provisioner (or the harness simulation). It never begins
provider mutation and then discovers a late prompt requirement. ACME EAB uses the same authenticated
linear transport mechanism but a distinct schema-indexed external-material frame and permit.

`prodbox nuke` is TTY-confirmed because of the typed `NUKE EVERYTHING` guard, and
after that gate it acquires elevated AWS power through the same unified prompt path
as the long-lived `aws-ses` destroy/migration and state-bucket operations: the operator supplies the
ephemeral elevated credential at the interactive prompt (the harness simulates this
from the `test-secrets.dhall` fixture). It does not read a stored admin section from
production config.

The interactive surface **refuses to run when stdin is not a TTY**. Each
interactive entry point calls `Prodbox.CLI.Interactive.requireInteractiveTty`
before any prompt fires; on a non-TTY stdin it writes a structured
guidance message to stderr naming the automation equivalent and exits 1.
The guidance is rendered by `Prodbox.CLI.Interactive.renderNonTtyError`
from a per-command `InteractiveGuard` value
(`awsSetupGuard`, `awsTeardownGuard`, `awsCheckQuotasGuard`,
`awsRequestQuotasGuard`, `configSetupGuard`, `chartsDeleteGuard`), keeping
the message under unit test.

Automation contexts (CI, agents, scripted workflows) **must** use the
non-interactive surface. The
[command-selection table in `AGENTS.md`](../../AGENTS.md#command-selection-automation-vs-operator-interactive)
maps each operator task to its automation equivalent.

### Test-only opt-in: `PRODBOX_ALLOW_NON_TTY_INTERACTIVE`

Integration tests that exercise the interactive surface end-to-end
(`test/integration/CliSuite.hs` fixtures for `prodbox config setup`,
`prodbox aws setup`, `prodbox aws teardown`, `prodbox aws quotas check`,
`prodbox aws quotas request`) spawn `prodbox` as a subprocess with
controlled stdin input. Their stdin is a pipe, not a TTY, so the guard
would otherwise refuse. These tests set the env var
`PRODBOX_ALLOW_NON_TTY_INTERACTIVE=1` before spawning, which makes
`requireInteractiveTty` skip the refusal.

The env var is **test-only**. Production agents must never set it. The
test fixtures set it through the `fakeAwsEnvironment` /
`fakeAwsHarnessEnvironment` helpers in `test/integration/CliSuite.hs`,
which is the only sanctioned consumer. Any other set site is a doctrine
violation and should be flagged.

## 4. Doctrine-Adoption Command Surface

The generated [§3 Command Matrix](#3-command-matrix) is the sole command inventory. This section
explains the architecture and ownership behind selected current leaves; implementation and
migration status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here).

### `prodbox dev lint`

`src/Prodbox/CheckCode.hs` currently owns the lint surfaces and the canonical
policy scan, marker-delimited generated-section registry, and fully generated path registry.
`prodbox dev lint chart` validates `Chart.yaml` metadata, required chart-label helpers
(`app.kubernetes.io/name`, `app.kubernetes.io/managed-by: prodbox`, and
`prodbox.io/chart-root`), and route-inventory drift inside the chart templates that consume the
generated public-edge catalog.

### `prodbox dev docs`

`prodbox dev lint docs [--write]` is implemented as a thin alias over the same Haskell function
that backs `prodbox dev docs check` / `prodbox dev docs generate`; both surfaces consume the same
in-code generation registry per
[code_quality.md → Generated Artifacts](./code_quality.md#generated-artifacts).
The generator owns both marker-delimited artifacts and fully generated files:

- `documents/cli/commands.md`
- `share/man/man1/prodbox.1`
- `share/man/man1/prodbox-<group>.1`
- `share/completion/bash/prodbox`
- `share/completion/zsh/_prodbox`
- `share/completion/fish/prodbox.fish`
- marker-delimited `route-registry` sections in the chart templates that consume the canonical
  public-edge route catalog

Operators may use either name; future contributors must not split the surfaces or add a third
validator command.

### `prodbox bootstrap-broker`

`prodbox bootstrap-broker start --config <path>` is the dedicated pre-Vault controller entrypoint.
It selects the Bootstrap Broker runtime role before decoding its strict role-only Dhall document;
there is no repository-config, Gateway-config, or environment fallback. `--dry-run` validates the
document and renders the secret-free bounded listener/store/limit plan, while `--plan-file` uses the
ordinary plan-output contract.

The controller accepts only loopback listeners and a closed seventeen-route protocol. Client,
server, deterministic fake, and execution engine share that exact schema, and the engine carries
the same indexed `CapabilityRef` through admission and execution. The production APPLY boundary
includes a secret-free fixed-coordinate post-unseal handoff mutation used by native reconcile only
after Lifecycle Authority rollout; the public `vault unseal` and `vault reconcile` leaves close on
their own exact worker/baseline receipts and cannot hide that later graph effect. The command row
records the runtime surface, not deployment qualification or operational
cutover; status lives only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here). The combined gateway
bootstrap routes remain only in the
registered `LegacyModelBEmitter` rollback adapter under
[Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

### `prodbox vault`

The `prodbox vault` group is the operator-facing Vault lifecycle surface — `status`,
`init`, `unseal`, `seal`, `reconcile`, `rotate-unlock-bundle`, `rotate-transit-key`, and the
`pki` inspection leaves (full row set in [§3 Command Matrix](#3-command-matrix)). **Target
routing:** these commands
bind an operation-indexed Bootstrap Broker `CapabilityRef` for the bounded init/unseal/seal and
rotation requests it owns; observation, admission, and execution use that same reference and one
absolute deadline. They never fall back to Gateway Runtime or a host-direct Vault/MinIO route.
Post-unseal policy reconciliation remains a typed Vault interpreter rather than a generic broker or
gateway proxy. Current pre-cutover transport and migration status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here) and
[deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md#pending-removal).
Startup-config sourcing, the typed
`SecretRef` contract, and the sealed-state fail-closed invariant are not owned here; they are
owned by [vault_doctrine.md](./vault_doctrine.md) and
[config_doctrine.md](./config_doctrine.md). This surface extends the existing config and
lifecycle command groups with a Vault control plane; it does not replace the single-Dhall
config contract or the managed-resource-registry teardown.

### Daemon-launching flags

`prodbox bootstrap-broker start`, `prodbox gateway start`, `prodbox gateway status`, and
`prodbox workload start` accept exactly one startup-time CLI knob — `--config <path>` — per
[config_doctrine.md §2](./config_doctrine.md#2-single-dhall-surface-per-binary-instance)
(`bootstrap-broker start` and `gateway start` additionally expose only the universal `--dry-run` /
`--plan-file` plan renderers). Foreground execution is the only supported mode;
self-daemonization (`--detach`,
double-fork, `setsid`, `forkProcess`) is forbidden per
[CLI-to-Daemon Plumbing](./distributed_gateway_architecture.md).
`--log-level`, `--port`, `--node-id`, and similar runtime-override flags are **not part of
the surface**; every value the daemon needs lives in the Dhall file. Environment-variable
precedence is forbidden on supported paths: no `PRODBOX_*` startup fallback ladder. See
[config_doctrine.md §10](./config_doctrine.md#10-forbidden-surfaces) for the authoritative
forbidden-surface list.

Sprint 2.24 removed the legacy `--log-level`, `--port`, and `--foreground` override flags
from both `prodbox gateway start` and `prodbox workload start`, along with the
`src/Prodbox/Gateway.hs` threading. The gateway daemon now sources its log level from the
mounted Dhall (`live.log_level`, defaulting to `info`) and its REST port from the Orders
file; the workload daemon sources its port and log level from its mounted Dhall config.
All daemon-launch surfaces conform to the single-`--config` contract (see the
[generated command matrix](#3-command-matrix)).

### One-shot output flags

The shared output layer owns `OutputOptions`, typed
`--format {json,table,plain}`, `--color {auto,always,never}`, the `--no-color` alias, and the
stdout/stderr writer boundary for one-shot commands. `prodbox dev check` rejects direct terminal
writes outside that boundary. Daemon-launching commands stay on the structured-logging exception
path; daemons emit structured JSON logs to stderr per Sprint 2.12.

### Cross-language types generation deferral

[Generated Artifacts](./code_quality.md#generated-artifacts)
enumerates "cross-language types" as a generation surface (e.g. TypeScript or Go type
mirrors of Haskell ADTs). No non-Haskell consumer is currently in scope; the supported
plan does not schedule cross-language-type generation. The generated-artifact registry remains
ready when such a consumer enters scope.

## Command Topology

Represent commands as ordinary Haskell data types:

```haskell
data Command
  = Users UsersCommand
  | Projects ProjectsCommand
  | Config ConfigCommand
  deriving stock (Show, Eq)

data UsersCommand
  = UsersList UsersListOptions
  | UsersCreate UsersCreateOptions
  | UsersDelete UsersDeleteOptions
  deriving stock (Show, Eq)
```

This gives a typed model of the CLI surface. Define a separate `CommandSpec`
and generate the parser from it. The parser is never the source of truth.

`optparse-applicative` can automatically generate `--help` output, usage text,
subcommand help, and shell completion support. For durable external
documentation (Markdown, manpages, HTML, JSON command schemas), define a
first-class command specification:

```haskell
data CommandSpec = CommandSpec
  { name        :: Text
  , summary     :: Text
  , description :: Text
  , children    :: [CommandSpec]
  , options     :: [OptionSpec]
  , examples    :: [Example]
  }

data OptionSpec = OptionSpec
  { longName    :: Text
  , shortName   :: Maybe Char
  , metavar     :: Maybe Text
  , description :: Text
  , required    :: Bool
  }
```

Use the specification as the source of truth:

```text
CommandSpec
  -> optparse-applicative Parser
  -> Markdown documentation
  -> manpage
  -> JSON schema
  -> shell completion metadata
  -> command tree output
```

This avoids duplicating command descriptions across code, README files, and
generated help text. See
[code_quality.md → Generated Artifacts](./code_quality.md#generated-artifacts)
for the full discipline (markers, paired check/write commands, drift
enforcement).

## Progressive Introspection

A good CLI should be introspectable at every level:

```bash
tool --help
tool users --help
tool users create --help
tool projects archive --help
```

Expose explicit introspection commands:

```bash
tool commands
tool commands --tree
tool commands --json
tool help users
tool help users create
```

Example tree output:

```text
tool
├── users
│   ├── list
│   ├── create
│   └── delete
├── projects
│   ├── list
│   └── archive
└── config
    ├── get
    └── set
```

## Reconcilers: Idempotent Mutation as a Single Command

Tools that manage state in the world expose a single canonical reconcile
command. Re-running it is a no-op when current state already matches desired
state. There is no separate `install` / `upgrade` / `repair` / `force-install`
split — those are different verbs for the same underlying operation.

Standard shape:

```haskell
data Command
  = ...
  | Reconcile ReconcileOptions
  | ...
```

Internally the reconcile is composed of independently idempotent steps. Each
step is safe to skip when its postcondition is already satisfied, and safe to
run when it is not.

Composition with prior sections:

- [Plan / Apply](./pure_fp_standards.md#8-plan--apply). A reconcile is built as
  a Plan/Apply pair. `build` reads current state, computes the diff against
  desired state, and emits a plan listing only the steps that still need to
  run. An empty plan is the steady state and `apply` is a no-op.
- [Prerequisites as Typed Effects](./prerequisite_doctrine.md#8-prerequisites-as-typed-effects).
  The prerequisite DAG runs before any mutating step. A reconcile on a host
  missing required tools or credentials fails fast at the gate.
- `--dry-run` prints the plan and exits. This is the operator's contract for
  "what will change if I run this against this host."

A worked example: a hypothetical reconcile that provisions a local
systemd-managed service.

```text
Step 1: install package    -- skip if package already at target version
Step 2: write config       -- skip if on-disk config matches desired content
Step 3: enable unit        -- skip if `systemctl is-enabled` returns enabled
Step 4: start unit         -- skip if `systemctl is-active` returns active
Step 5: assert healthy     -- always run; fail the reconcile if unhealthy
```

Each step is checked-before-mutated. Re-running the command performs zero
work when the system is already in the desired state.

**Forbidden patterns:**

- Sister commands like `install` / `upgrade` / `repair` / `force-install`.
  If the reconcile is correct, repeating it is the repair.
- `--force`, `--reinstall`, or any flag whose purpose is "ignore that the
  step is already done." The check-then-mutate discipline replaces this.
- Steps that mutate before checking their own postcondition. Mutation without
  a precondition check leaks work into the steady state.
- Steps that exit non-zero with an "already installed" error. Already-installed
  is the success case, not a failure.
- Reconcilers that mutate state not described in the plan. The plan is the
  audit trail of what will change.

Operators run the reconcile freely. When a tool publishes a reconcile
command, that command is the canonical mutation entrypoint, and running it on
a host — whether to bring up fresh state, reconcile drift, or recover from
partial state — is the supported operation, not an unauthorized change.

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Code Quality Doctrine](./code_quality.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Haskell Code Guide](./haskell_code_guide.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
