# Gateway and Messaging

**Status**: Authoritative source
**Supersedes**: Pre-refactor distributed gateway, Pulsar messaging and topic lifecycle doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; preserved behavior requires real service/fault validation

> **Purpose**: Define bounded gateway convergence, DNS intent, durable emitter continuity and Pulsar contracts.

## Gateway responsibility and Orders

Gateway owns mesh observations, deterministic candidate selection and semantic continuity. It never owns Vault bootstrap, credential provisioning, lifecycle journals or generic object-store/secret RPCs. An elected gateway submits registered DNS intent; the retained Authority/Provider lane owns the actual AWS mutation and its read-back.

A validated Orders document binds version/digest, members, stable peer endpoints, ranks, permitted rule family and time/bounds parameters. Dhall is authoring; canonical CBOR is the payload wire format. Authenticate schema/signature/monotone version and reject duplicate members/ranks, oversized fields or membership before allocating runtime maps.

Preserve ranked failover with deterministic `(rank, node_id)` ordering and the all-other-peers-down self-candidate behavior under the declared heartbeat/isolation timeout. A unique candidate for one state snapshot is not proof that partitioned machines share the same snapshot. State the fault assumptions and provider fencing that bound actual DNS effects rather than promising global partition-proof single ownership from gossip alone.

## Bounded signed state and recovery

Each member authenticates canonical signed assertions. Receiver derives assertion digests from canonical bytes, rejects unknown emitters and invalid prior-digest/epoch/sequence transitions, and keeps a bounded semantic projection: latest heartbeat/liveness and ownership evidence per member, active Orders plus bounded promotion state, bounded replay suffix/cursors and a fixed diagnostic ring. Runtime state cannot grow with uptime.

Peer cursor/delta/repair exchanges have byte/assertion/connection/admission limits. Snapshot plus contiguous replay repairs a lagging peer; peer data cannot replace the local retained continuity authority. Keep inbound accepted-event freshness separate from outbound socket/push success so one-way reachability does not keep a dead emitter fresh.

One actor owns each identity-bound emitter journal: stage and sync exact signed bytes before publication, then commit/sync the resulting cursor. Preserve active/prior Orders anchors and a bounded staged assertion/suffix. On crash, restore the same identity/floor, replay the same staged bytes and observe committed state before readiness. Missing/corrupt history refuses emission instead of resetting epoch/identity. Orders promotion uses the declared restart/migration path, not an in-process field assignment that loses continuity.

Claim/yield evidence precedes registered DNS intent; yielded/stale owners cannot regain permission merely by retry. DNS admission binds exact account/zone/record/type/ownership epoch, current usable credential generation and durable continuity. Unknown or stale evidence refuses. No ambient profile, direct AWS CLI or gateway-owned cloud fallback exists.

## Runtime service behavior

One bounded supervised child scope owns listeners, peers, workers and waiters. A slow/malformed connection has its own deadline and cannot wedge others. Header/body/frame limits apply before unbounded accumulation. Drain closes admission and joins or reports unresolved children; timeout is not proof of Stopped. Health/status/metrics are bounded local observations and contain no lifecycle side effects.

A same-binary internal launcher reads mounted role configuration; ordinary operators use reconcile/status/services. Boot-field updates use explicit validated restart policy. Do not replace accepted Orders trust or unseal secrets through environment fallback.

## Pulsar and durable consumers

Keep one native Haskell client boundary and canonical CBOR payloads. No payload codec-selection field exists. Derive topic names from validated tenant/namespace/workflow/phase/lane descriptors; reject duplicate derived topics, malformed segments and report lanes without a valid input lane before effects.

Preserve correlated `WorkCommand`, `WorkEvent` and `WorkResult` envelopes using stable call IDs, typed statuses and bounded canonical decoding. Invalid wire data is a structured rejection. At-least-once consumers use durable processed/dedup state, idempotent handlers and ordering appropriate to their owned key. Duplicate delivery does not imply duplicate retained state or repeated irreversible effects.

Topics are registered resources: explicit owner, partitions/configuration, presence/readiness, retention/offload/storage budget, desired absence and independent read-back. A topic name or missing config file cannot prove broker absence. Per-run versus retained reuse policy is chosen before observation; explicit owner deletion follows its declared data policy. Keep finite capacity and supported broker behavior visible.

## Validation boundaries

Local platform delivery proves real gateway/Pulsar protocol behavior and persistence. HA/federation phase proves process/node loss, partition/rejoin, stale/duplicate/lost replies and total-peer restart. Multi-node kind proves container/node failure behavior, not independent hardware/AZ failure. EKS claims state the actual topology exercised.

Maintain useful TLA+ models and property tests for ownership/continuity laws. Bind them to actual production transitions and validate correspondence. Models, constructed witnesses and memory arithmetic do not replace live fault/persistence/high-water evidence. [Testing](testing.md) and [resource governance](resource_governance.md)
