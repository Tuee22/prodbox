# Haskell Code Guide

**Status**: Authoritative source
**Supersedes**: Pre-refactor overlapping Haskell, pure-FP and effect-pattern guidance
**Generated sections**: none
**Applicability**: Adopted coding contract; mechanical enforcement changes remain Phase 0 work

> **Purpose**: Define simple typed boundaries, explicit effects, safe concurrency/subprocesses and honest errors.

## Structure and types

The supported implementation remains Haskell in `app/`, `src/Prodbox/` and `test/`, built through Cabal. Keep the executable entrypoint and CLI dispatch thin. A module owns a coherent domain/interpreter; extracting from a large command file is useful only when ownership becomes clearer, not when orchestration is duplicated.

Use explicit ADTs, exhaustive pattern matches and validated smart constructors for configuration, context, resource keys, capabilities, observations and errors. Avoid string parsing to make lifecycle decisions. Keep configuration decode/validation separate from execution. Reject malformed FQDN/IP/resource names, zero/out-of-range numeric values, duplicate keys and overflow/underflow at the boundary.

Use GADTs/type indices for program-owned legal transitions and capability/results where they simplify actual callers. Independent external facts remain flat fallible observations; do not index a global world state that assumes simultaneous complete AWS/Vault/Kubernetes truth. A constructed witness is not evidence of an external effect.

One typed catalog is the source for shared command, service, route, topic, resource and generated-config facts. Do not maintain parallel literal tables or import the CLI layer into domain logic to get a constant. Prefer a small pure helper and explicit interpreter over a new general protocol framework.

## Effects and errors

Keep planning/rendering/decision folds pure. Perform IO at application/interpreter/subprocess boundaries with explicit scoped dependencies and a narrow application environment. Ordinary unavailable/denied/conflicting/input-required outcomes are structured values. Exceptions handle exceptional IO failure and cancellation, not everyday business branching.

Do not swallow asynchronous cancellation in a broad exception handler or relabel it as a synchronous transport failure. Retain the primary failure while attempting eligible cleanup, and return all unresolved outcomes. `finally` or bracket entry does not prove cleanup succeeded.

Retries are bounded by the operation's original budget, typed transient causes and backoff; they never refresh an expired operation window or retry uncertain irreversible effects without observing them. An HTTP 503 is not automatically proof of sealed Vault; observe init/seal/reachability as needed. Unanswered queries never become absence.

## Concurrency and resource ownership

Supervise and bound all long-lived children, request queues, listeners and background processes. Keep handles until joined/cancelled/observed terminal; no discarded `forkIO`/Async work. Drain closes new admission, settles accepted work and reports incomplete shutdown when children/resources remain. A timeout cannot produce Stopped or release a credential still needed by a child.

Bind ownership and registration before creation, and settle predecessor effects before successor admission. Preserve context/operation identity across callbacks and restart. Do not hold broad locks across arbitrary remote effects or infer cross-process exclusion from an in-memory mutex.

## Subprocess boundary

Use the repository's structured subprocess API with explicit executable/argv, environment projection, working directory, stdin/output policy and deadline. No shell string interpolation, unbounded capture or secret argv/environment. Temporary decrypted material stays in bounded memory/tmpfs and has explicit ownership/retirement.

Credential delivery through stdin/descriptor/FIFO requires actual rendezvous and child settlement; opening a pipe or starting a process is not delivery. Observe the owned process family on cancellation/timeout. Keep platform-specific containment in the host adapter; do not spread systemd/RKE2 assumptions into kind domain logic.

## Data, logging and testing

Canonical CBOR is the message payload codec; Dhall is authored configuration. External codecs validate framing/size before allocation and return structured errors for corrupt/truncated/oversized input. Bound parser scratch, collections, replay state and lifetime as well as logical payload size.

Use typed structured logs and the central CLI output boundary. Exclude credentials/private keys/plaintext payloads and their public raw hashes. Redacted `Show` protects secret/opaque handles from incidental logging. Comments explain non-obvious control flow; they do not carry sprint diaries or claim checks the gate does not implement.

Test pure helpers independently and mock at actual interpreter boundaries. Use table/property assertions for semantics, actual process/service cases for effects, targeted mutation for critical detection, and real provider cases for provider claims. [Testing](testing.md), [quality](code_quality.md), [dependencies](dependency_management.md)

## Mechanical versus review obligations

Formatting, lint, warnings, generated drift and documented structural checks are mechanical. Ownership coherence, meaningful observer independence, adequate real evidence and correct threat-model limits remain review obligations. Do not describe a scan, formatter or typecheck as a proof of physical cleanup, resource sufficiency or production correctness.
