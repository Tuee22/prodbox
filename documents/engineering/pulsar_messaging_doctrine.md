# Pulsar Messaging Doctrine

**Status**: Authoritative source
**Supersedes**: the "protobuf" wire-format language in
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md) — §1 item 3
(line 33, "a typed global Orders document exists (protobuf)"), §3.1 (line 68, "`Orders`
protobuf is the declarative configuration object"), and §3.2 (line 84, "payload protobuf").
Protobuf is removed as a sanctioned prodbox wire format; those envelopes are CBOR.
**Referenced by**: documents/engineering/README.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md, documents/engineering/pulsar_topic_lifecycle_doctrine.md, documents/engineering/tiered_storage_capacity_doctrine.md
**Generated sections**: none

> **Purpose**: SSoT for prodbox's self-maintained native-protocol Pulsar client, its
> non-optional CBOR-always payload codec, the derived topic algebra, and the `Work*` envelope
> family — the proven single-node specialization that the amoebius umbrella
> `pulsar_client_doctrine.md` cites and generalizes.

> **Implementation status.** The gateway peer-gossip batch, `Orders` serialized envelope, and
> `SignedEvent` payload field moved to canonical CBOR in Phase 2 Sprint `2.27`. The durable
> at-least-once event store moved to CBOR in Sprint `2.28`. Phase 3 Sprint `3.21` has landed the
> shared Pulsar CBOR codec, derived topic algebra, `Work*` envelopes, chart, and native-client
> boundary; broker I/O remains explicitly blocked until a compatible generated Apache Pulsar
> `BaseCommand` / `PulsarApi.proto` protocol layer is imported. Per
> [development_plan_standards §D](../../DEVELOPMENT_PLAN/development_plan_standards.md) this doc
> states the target shape in present-tense doctrine; delivery sequencing and status are owned only
> by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. Scope — what this document owns

This doc is the SSoT for **the payload codec and the message-shape algebra**. It owns:

1. The **CBOR-always** wire rule and the `CborPayload` type that makes any other codec
   unrepresentable (§2).
2. The **topic algebra**: `topicFor` derivation from a typed descriptor; hand-written topic
   strings forbidden (§3).
3. The **`Work*` envelope family** (`WorkCommand` / `WorkEvent` / `WorkResult`, correlated by
   `callId`) mirrored in-kind from jitML, with the codec swapped to CBOR (§4).

It deliberately does **not** own, and only references:

| Concern | Owner |
|---------|-------|
| At-least-once delivery, idempotent handlers, first-write-wins dedup | [streaming_doctrine.md § At-Least-Once Event Processing](./streaming_doctrine.md#at-least-once-event-processing) |
| Topic create / validate / reconcile / teardown lifecycle and retention | [pulsar_topic_lifecycle_doctrine.md](./pulsar_topic_lifecycle_doctrine.md) |
| Tiered storage, capacity, and offload for Pulsar-backed topics | [tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md) |
| Gateway leadership, Orders semantics, commit-log hash chaining | [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) |
| Dhall as the human config-authoring language | [config_doctrine.md](./config_doctrine.md) |
| Phase order, sprint status, validation closure | [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md) |

## 2. CBOR is the payload codec, always

prodbox has **exactly one** payload wire codec: CBOR. It is built in and non-optional. This is a
project-wide operator decision, not a per-message negotiation, and it is expressed as a type-level
invariant rather than a runtime convention.

### 2.1 The codec-selection field does not exist

The illegal-state technique here is *absence*: the message payload type admits no alternative
constructor and no codec tag, so "protobuf payload" or "JSON payload" is **unconstructible** — a
compile error, not a validated-away runtime case. (This is the same "make the illegal state
unrepresentable" discipline as [pure_fp_standards.md § GADT-Indexed State
Machines](./pure_fp_standards.md#gadt-indexed-state-machines); here the state is eliminated by a
closed newtype with no variants rather than by a GADT index.)

```haskell
-- Example: the sole wire-payload type — there is no `data Payload = Cbor … | Proto … | Json …`
newtype CborPayload = CborPayload {cborPayloadBytes :: ByteString}
  deriving stock (Eq, Show)
```

There is no `data PayloadCodec = Cbor | Protobuf | Json`, no `payloadContentType :: Text` field
on any envelope, and no `WorkCommand { wcCodec :: … }`. Because the only way to hold a payload is a
`CborPayload`, a non-CBOR payload cannot be represented, transmitted, or persisted.

### 2.2 Canonical, deterministic encoding

Encoding and decoding go through `cborg` / `serialise`, under a **canonical-encoding rule**: equal
Haskell values encode to byte-identical output (definite-length items, shortest-form integers,
lexicographically sorted map keys — RFC 8949 §4.2 core-deterministic form).

```haskell
-- Example: canonical CBOR — the encoded bytes are a pure, deterministic function of the value
encodeCanonical :: Serialise a => a -> CborPayload
encodeCanonical = CborPayload . toStrictByteString . encode

decodeCanonical :: Serialise a => CborPayload -> Either DeserialiseFailure a
decodeCanonical (CborPayload bytes) =
  bimap snd snd (deserialiseFromBytes decode (fromStrict bytes))
```

Determinism is **load-bearing**, not cosmetic. The gateway commit log hash-chains events by
`eventHash` and the at-least-once store dedups by content
([streaming_doctrine.md](./streaming_doctrine.md#at-least-once-event-processing)); a
nondeterministic encoding would make equal payloads hash differently and silently break both the
chain and dedup. The canonical rule is therefore consistent with — and checked by — the repo's
no-nondeterminism lint over serialization-source modules
([code_quality.md](./code_quality.md), [pure_fp_standards.md § 6.3](./pure_fp_standards.md)):
timestamps, locale-dependent ordering, and map-iteration order must never leak into encoded bytes.

## 3. Topic algebra — names are derived, never written

Every topic name is a pure function of a **typed descriptor**; a hand-written topic string is
forbidden. This mirrors jitML's `topicFor` (see the sibling contract
`jitML/documents/engineering/pulsar_ml_workflow.md § Topic algebra`) in kind, not by import.

```haskell
-- Example: the derivation and its typed inputs (closed ADTs + validated newtypes)
newtype Tenant = Tenant Text deriving stock (Eq, Show)
newtype Namespace = Namespace Text deriving stock (Eq, Show)
newtype Lane = Lane Text deriving stock (Eq, Show)
newtype TopicName = TopicName Text deriving stock (Eq, Show)

data Workflow = Reconcile | Gossip | DomainEvent
  deriving stock (Eq, Show)

data Phase = Command | Event | Result
  deriving stock (Eq, Show)

topicFor :: Tenant -> Namespace -> Workflow -> Phase -> Lane -> TopicName
```

`Tenant` / `Namespace` / `Lane` are constructed only through validating smart constructors
(`mkTenant :: Text -> Either TopicError Tenant`, etc.), so an ill-formed segment fails at the
decode boundary rather than surfacing as a broker error. The reconciled topic set is *derived* from
a list of typed descriptor entries; adding a workflow or a lane edits the descriptor, never a
literal-string table. The descriptor's static invariants (no duplicate derived topic, no
report-lane without an input-lane) are enforced by a scheduled canonical Dhall schema —
`dhall/pulsar/Schema.dhall`, mirroring `jitML/dhall/project/Schema.dhall` — that carries an
`assert`-form lemma so an unroutable topology is a Dhall typecheck failure:

```dhall
-- Example: teaching fragment — a descriptor typechecks only when routing is two-sided
let TopicDescriptor = { workflow : Text, inputLanes : List Text, reportLanes : List Text }
let laneCovered =
      \(d : TopicDescriptor) -> Natural/isZero (List/length Text d.inputLanes) == False
in  assert : laneCovered descriptor === True
```

The Dhall schema is the SCHEDULED code SSoT for the descriptor shape; this doc describes its facets
and shows teaching fragments only — it is not the schema.

## 4. The `Work*` envelope family

Command, progress, and result share one shape correlated by `callId`, mirrored in-kind from
jitML's envelope family. Each carries a `CborPayload` and **no codec field** (§2.1).

```haskell
-- Example: the correlated envelope family — payloads are always CBOR
newtype CallId = CallId Text deriving stock (Eq, Ord, Show)

data WorkCommand = WorkCommand
  { wcCallId :: CallId
  , wcWorkflow :: Workflow
  , wcLane :: Lane
  , wcPayload :: CborPayload
  }
  deriving stock (Eq, Show)

data WorkEvent = WorkEvent {weCallId :: CallId, wePayload :: CborPayload}
  deriving stock (Eq, Show)

data WorkResult = WorkResult {wrCallId :: CallId, wrStatus :: WorkStatus, wrPayload :: CborPayload}
  deriving stock (Eq, Show)

data WorkStatus = WorkSucceeded | WorkRejected RejectReason
  deriving stock (Eq, Show)
```

Parse, don't validate, at the wire boundary: a malformed frame is always possible on the wire; the
consumer decodes it into a total `WorkCommand`/`WorkEvent`/`WorkResult` or emits a typed
`WorkRejected` — never a silent bad state.

### 4.1 Deliberate divergence from jitML

prodbox mirrors jitML's **format-agnostic** envelope and topic structure. It diverges in exactly
one axis, on purpose: jitML serializes its `Work*` payloads as **protobuf** on Pulsar; prodbox
serializes them as **CBOR**. Nothing else in the shape changes — the three-envelope family, the
`callId` correlation, and the derived topic algebra are identical in kind. "Mirror the structure,
swap the codec to CBOR" is the whole of the specialization; a later refactor onto a shared
`hostbootstrap` core keeps this same seam.

## 5. Application to the current gateway envelopes

The gateway already carries the exact envelopes this doctrine governs.
[`src/Prodbox/Cbor.hs`](../../src/Prodbox/Cbor.hs) defines the shared `CborPayload`;
[`src/Prodbox/Gateway/Types.hs`](../../src/Prodbox/Gateway/Types.hs) serializes `Orders` and
`SignedEvent` through `serialise` and keeps the event payload opaque at the signed-event boundary:

```haskell
-- File: src/Prodbox/Gateway/Types.hs
newtype CborPayload = CborPayload { cborPayloadBytes :: ByteString }

data SignedEvent = SignedEvent
  { eventHash :: String
  , emitterNodeId :: String
  , timestampUtc :: String
  , eventType :: String
  , payloadCbor :: CborPayload
  , signatureHex :: String
  }
  deriving (Eq, Show)
```

Sprint `2.27` landed the gateway gossip transport and `Orders` document on canonical CBOR (adding
the `cborg` / `serialise` dependencies). `src/Prodbox/Gateway/Peer.hs` now sends
`POST /v1/peer/events` as `application/cbor`, and event hashes/HMAC signatures are derived from the
same canonical unsigned CBOR payload bytes. Sprint `2.28` moved the durable at-least-once event
store (`src/Prodbox/Daemon/Events.hs`) to the shared `CborPayload`, with `StoredEvent` CBOR
round-trip helpers and the first-write-wins `processed_at` marker unchanged. The hash-chain and
dedup guarantees are preserved precisely because the encoding is canonical (§2.2). This is the
concrete removal of the superseded "protobuf" language: neither JSON nor protobuf is a sanctioned
prodbox wire format for these envelopes — CBOR is.

## 6. Dhall-authoring vs CBOR-at-rest boundary

CBOR-always governs the **wire and at-rest** serialization only. It does **not** displace Dhall:
Dhall remains prodbox's human-authoring configuration language
([config_doctrine.md](./config_doctrine.md)). The boundary is clean and one-directional — a human
authors Dhall, the binary decodes it to typed Haskell values, and only serialized/persisted
artifacts (the gateway `Orders` serialized envelope, commit-log events, at-least-once records, and
`Work*` payloads) are CBOR. There is no CBOR configuration surface and no Dhall on the wire; the
topic descriptor is authored in Dhall (§3) and its *derived* topics travel as CBOR-encoded control
envelopes.

## 7. The self-maintained native client

prodbox owns a single native-protocol Haskell Pulsar client boundary — no WebSocket gateway, no
second language runtime — the single-node realization of the amoebius umbrella
`amoebius/documents/engineering/pulsar_client_doctrine.md`, which cites this doc for the CBOR-always
payload rule. The client's capability surface (lookup / produce / consume / subscribe / seek) and
its broker-side dedup contract are the umbrella doc's concern; what this doctrine fixes for the
client is unconditional: every payload it produces or consumes is a `CborPayload` (§2). Sprint
`3.21` has landed `Prodbox.Pulsar.Codec`, `Prodbox.Pulsar.Topic`, `Prodbox.Pulsar.Envelope`, the
`charts/pulsar` retained-storage chart, and `Prodbox.Pulsar.Client`'s typed `connect` / `produce` /
`consume` / `ack` boundary. Until the Apache Pulsar `BaseCommand` layer is generated for this
toolchain, broker I/O fails closed with `PulsarBrokerProtocolUnavailable`; that explicit guard is
the only supported interim state, not a fallback transport.

## Intent Ownership

This SSoT owns the prodbox message-codec and message-shape doctrine.

- **Owned statement**: prodbox's one payload wire codec is CBOR, always and non-optionally — the
  message types admit no codec-selection field, so any non-CBOR payload is unrepresentable — and
  every topic name is derived from a typed descriptor, never hand-written.
- **Linked dependents**:
  `src/Prodbox/Gateway/Types.hs` (Orders / SignedEvent / CommitLog → CBOR, landed in Sprint `2.27`),
  `src/Prodbox/Gateway/Peer.hs` (anti-entropy gossip transport → CBOR, landed in Sprint `2.27`),
  `src/Prodbox/Daemon/Events.hs` (durable at-least-once store → CBOR, landed in Sprint `2.28`),
  `src/Prodbox/Pulsar/Codec.hs`, `src/Prodbox/Pulsar/Topic.hs`,
  `src/Prodbox/Pulsar/Envelope.hs`, and `src/Prodbox/Pulsar/Client.hs` (CBOR/topic/`Work*` client
  boundary landed in Sprint `3.21`; broker `BaseCommand` I/O still blocked).

## Cross-References

- [Engineering Doctrine Index](./README.md)
- [Streaming Doctrine § At-Least-Once Event Processing](./streaming_doctrine.md#at-least-once-event-processing)
- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [Pure FP Standards § GADT-Indexed State Machines](./pure_fp_standards.md#gadt-indexed-state-machines)
- [Config Doctrine](./config_doctrine.md)
- [Code Quality](./code_quality.md)
- [Pulsar Topic Lifecycle Doctrine](./pulsar_topic_lifecycle_doctrine.md)
- [Tiered Storage & Capacity Doctrine](./tiered_storage_capacity_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Phase 2 — Gateway & DNS](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md)
- [Phase 3 — Chart Platform & VSCode](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md)
- Sibling contract mirrored in kind: `jitML/documents/engineering/pulsar_ml_workflow.md`
- Umbrella doctrine this doc feeds: `amoebius/documents/engineering/pulsar_client_doctrine.md`
