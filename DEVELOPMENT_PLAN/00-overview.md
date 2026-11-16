# Development Plan Navigation

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Static navigation for the adopted refactor; no independent status or execution queue.

> **Purpose**: Connect the accepted product contracts to the one numerical implementation plan.

Start at [README.md → Resume Here](README.md#resume-here). The [Development Plan Standards](development_plan_standards.md) define order and closure. [Engineering documentation](../documents/engineering/README.md) owns the accepted target, and [AGENTS.md](../AGENTS.md) owns operating rules.

The buildout is contract/tooling adoption, kind/context isolation, real Vault/MinIO bootstrap, retained Authority and local lifecycle, real ephemeral credentials, a complete cheap AWS lifecycle, the canonical local platform, real public edge/email/users, EKS parity, HA/federation recovery, then existing-install migration and cumulative regression.

Each phase delivers its completed public slice and the deletion/recovery path for every resource family it introduces. A later phase uses actual earlier capabilities. No phase waits for a larger-numbered phase to validate its own claim, and later work does not silently reverse earlier contracts.

| Need | Canonical source |
|---|---|
| What to implement next | [Current queue](README.md#resume-here) |
| Product decisions and responsibility boundaries | [Product architecture](../documents/engineering/product_architecture.md) |
| Target command structure and ordinary delete semantics | [CLI contract](../documents/engineering/cli_command_surface.md) |
| Full objective coverage | [Objective dispositions](objective_dispositions.md) |
| Existing command/option mapping | [Command dispositions](command_dispositions.md) |
| Real scenario and negative-control requirements | [Acceptance cases](acceptance_cases.md) |
| Targeted source mutation requirements | [Mutation cases](mutation_cases.md) |
| Remover of an obsolete path | [Legacy ledger](legacy_tracking_for_deletion.md) |
| Supported services and local/AWS projection | [Components](system-components.md), [substrates](substrates.md) |
| Historical source and evidence | [History](../documents/history/README.md), [evidence](evidence/README.md) |

The target has been adopted in Markdown; its implementation is not implied. The existing binary and checker remain code-owned migration work. Only the queue and phase evidence can establish completion.
