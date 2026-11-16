# Recovery and Incomplete Operations

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target recovery behavior; original-install recovery remains explicitly fenced until import.

> **Purpose**: Turn failure observations into a bounded action without inventing absence or requiring internal service choreography.

| Observation | Required behavior |
|---|---|
| Known deployment never admitted AWS | Cloud deletion is satisfied without provider credentials |
| Recorded nonterminal operation | Show stable operation ID and resume it through the same engine |
| Initialized sealed Vault with usable custody | Unlock, verify and continue only if the operation needs it |
| Protected input unavailable | NeedsInput names the exact prompt/input requirement |
| Registry unavailable | Recover management from pinned retained images, not dependent application rollout |
| Wrong/unlinked/missing existing storage generation | Preserve original identity and diagnose the exact mismatch; no automatic reinitialization |
| Provider mutation reply lost | Independently observe its actual postcondition before retry or successor admission |
| Checkpoint missing while resource remains | Recover exact registered/adopted ownership; missing bookkeeping is not absence |
| Query denied or scope unknown | Report Incomplete/RecoveryRequired and retain recovery capability |
| Foreign/untracked candidate | Bounded explicit adoption/recovery plan; discovery alone grants no deletion authority |

Read-only status may show an aged projection while the Authority is down; label it. Mutating operations restore the minimal local management path and obtain fresh authoritative state. Do not rebuild the full application set just to inspect or clean cloud work.

Every durable refusal names one supported remedy: bounded self-heal, exact input, scoped repair or explicit irrecoverable custody disposition. Do not round unknown up to clean. An earlier terminal failure remains attributable; a new operator attempt links it rather than rewriting it as success.

All supported mutations remain prodbox-surface-owned unless the operator explicitly authorizes a separate manual task. Hand repairs must be recorded and never qualify a lifecycle scenario. The November manual AWS cleanup is [historical evidence](../history/aws_cleanup_2026_11.md), not permanent permission or current provider truth.
