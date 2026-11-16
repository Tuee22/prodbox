# Operator Guides

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted target workflows; implementation availability follows the numerical plan.

> **Purpose**: Keep ordinary operation understandable without requiring knowledge of internal microservice launch order.

The installed binary still has the older command surface. Check its real `help`/`commands` before operating it. The workflows below are implementation contracts and are activated by their owning phases, not by this Markdown refactor.

| Guide | Purpose |
|---|---|
| [Setup](setup.md) | Explicit configuration, retained kind bootstrap and application target selection |
| [Everyday operation](workflows.md) | Status, plan, reconcile, delete and service diagnostics |
| [Credentials and unlock](credentials.md) | Ephemeral elevation, generated Vault credentials, production/test unlock policies |
| [Recovery](recovery.md) | Specific observations, pending operations, uncertainty and safe resume |
| [Testing](testing.md) | Isolated plans/fixtures, real acceptance and targeted mutations |
| [Migration](migration.md) | Original RKE2-era identity/state import and single-writer cutover |

Accepted architecture lives in [engineering](../engineering/README.md). Current implementation work lives only in [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here).
