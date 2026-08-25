# Shared Host Resource Protocol

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Record how prodbox would participate in the shared host claim ledger installed on a
> development machine, and the exact seam it would attach to.
> **Read this if**: you are deciding whether prodbox may start a local control plane on a machine it shares
> with another project.
>
> **Not adopted.** No prodbox code reads or writes the ledger, no supported command depends on it, and no
> sprint owns the work. Status remains owned by
> [Development Plan → Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here).

The ledger is host configuration owned by the machine's operator, in the same category as an `/etc` file. Its
authority is the installed root and the `spec-version` that root carries — never a copy of a document in any
repository, including this one. This file records only what prodbox would do, so prodbox acquires no
dependency on another project by writing it.

## Contents

- [1. The problem here](#1-the-problem-here)
- [2. What prodbox would claim](#2-what-prodbox-would-claim)
- [3. Where it would attach](#3-where-it-would-attach)
- [4. What is not changed](#4-what-is-not-changed)
- [5. Open before adoption](#5-open-before-adoption)

## 1. The problem here

prodbox holds no machine-wide lock of any kind. Every lock it takes lives beneath the repository-local
retained root. `prodbox cluster start` reduces to `sudo systemctl start rke2-server.service`, and nothing —
not a wrapper unit, a drop-in guard, or a marker — prevents an operator, a second checkout, or a reboot from
starting the same unit while another project believes it owns the machine's memory.

That is the gap. It is not solved by a Kubernetes request, a namespace quota, a systemd resource drop-in, or
an observed-host check, because none of those is visible to a program in another repository.

## 2. What prodbox would claim

One `Persistent` claim covering the retained local control plane and everything that outlives the invoking
command: the RKE2 server, its containers, the in-cluster Lifecycle Authority, retained volumes, and the bytes
already on disk.

`Persistent` is the correct kind and the weaker one is not available. The claim declares that prodbox's death
proves nothing about what it left running, so no other participant may reclaim that capacity — only prodbox
releases it, after its own cleanup path establishes the cluster is gone. A `Transient` claim would be a false
statement about a control plane that survives the process.

Charges are derived from the resource plan prodbox already compiles, by one conversion, and never authored a
second time. Two cautions travel with that derivation. The authored physical-host figure describes the
machine, not prodbox's allocation, and reinterpreting it as an allocation would let the in-cluster scheduler
reason about more capacity than the outer claim permits. And the derivation must include what sits outside
Kubernetes — host-native processes, retained artifacts, provider scratch — since that is exactly the demand
that causes trouble when it is omitted.

## 3. Where it would attach

At the existing observed-host seam, where the compiled plan is already re-checked against the machine before
reconcile mutates anything. That check already runs at the right moment and already refuses; participation
adds one more reason for it to refuse, and adds it in the one place a refusal is already expected.

Ordering, if adopted: read the ledger before any host or cluster mutation, and treat a refusal as a typed
outcome distinguishing a momentarily contended machine from one that cannot fit the request at all.

## 4. What is not changed

- The repository-local retained root remains prodbox's only repository-local retained root. The ledger lives
  on the machine, holds no prodbox bytes, and is not deleted by any prodbox teardown.
- Lifecycle Authority, the Provider Worker, the cleanup graph, and AWS desired state keep their authority. A
  claim is not lifecycle truth: it never asserts that a cluster, a provider resource, or a retained volume
  exists or is absent.
- No enforcement changes. Charging the ledger applies no limit; the existing walls remain the only walls.

## 5. Open before adoption

- No sprint, no component-inventory row, and no cleanup owner exists for this work.
- The production decode path compiles the plan uncertified, so the figure available to convert is an
  arithmetic fit rather than a measured profile. The conversion must not describe it as more than that.
- A claim is only as good as the release. prodbox needs its existing cleanup evidence to gate the release,
  and must hold rather than release whenever that evidence is partial or unavailable.
- Nothing here closes the direct `systemctl start` path. Until that path is closed, participation is
  cooperative between conforming invocations and does not cover a hand-started control plane.
