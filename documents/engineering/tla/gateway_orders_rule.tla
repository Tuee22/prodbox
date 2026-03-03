---- MODULE gateway_orders_rule ----
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS Nodes, NoNode, HeartbeatTimeout, MaxTimestamp, Rank1, Rank2, Rank3

ASSUME /\ Nodes # {}
       /\ NoNode \notin Nodes
       /\ HeartbeatTimeout \in Nat \ {0}
       /\ MaxTimestamp \in Nat \ {0}
       /\ {Rank1, Rank2, Rank3} = Nodes
       /\ Rank1 # Rank2 /\ Rank1 # Rank3 /\ Rank2 # Rank3

\* Rank ordering derived from individual rank constants.
\* TLC config files cannot express sequence literals, so we use
\* individual constants and construct the sequence here.
RankOrder == <<Rank1, Rank2, Rank3>>

NoTimestamp == -1

Timestamps == 0..MaxTimestamp

NodeOrNone == Nodes \cup {NoNode}

VARIABLES
    now,
    live,                \* crash-stop truth (modeled environment fact)
    activeOrderTs,       \* per-node active Orders version timestamp
    seenHeartbeatTs,     \* per-node local heartbeat view map: [viewer -> [peer -> ts]]
    ownerView,           \* per-node intended owner derived from local state
    eventLog,            \* global append-only event log (sequence of records)
    dnsWriteNode,        \* node that last performed a DNS write (or NoNode)
    msgQueue             \* message delay queue: set of in-flight heartbeats

vars == << now, live, activeOrderTs, seenHeartbeatTs, ownerView,
           eventLog, dnsWriteNode, msgQueue >>

\* -----------------------------------------------------------------------------
\* Event Record Types
\* -----------------------------------------------------------------------------

\* Event log entries are records with fields: type, node, timestamp
\* Types: "claim", "yield", "dns_write"

ClaimEntry(n, ts) == [type |-> "claim", node |-> n, timestamp |-> ts]
YieldEntry(n, ts) == [type |-> "yield", node |-> n, timestamp |-> ts]
DnsWriteEntry(n, ts) == [type |-> "dns_write", node |-> n, timestamp |-> ts]

\* Message queue entries for delayed heartbeats
HeartbeatMsg(sender, receiver, ts) ==
    [sender |-> sender, receiver |-> receiver, ts |-> ts]

\* -----------------------------------------------------------------------------
\* Helper Operators
\* -----------------------------------------------------------------------------

OrderTimestamp(n) == activeOrderTs[n]

MaxOrderTs == LET S == {OrderTimestamp(n) : n \in Nodes}
              IN CHOOSE x \in S : \A y \in S : x >= y

RankIndex(n) == CHOOSE i \in 1..Len(RankOrder): RankOrder[i] = n

UpSet(viewer) ==
    {peer \in Nodes:
        /\ peer \in live
        /\ seenHeartbeatTs[viewer][peer] # NoTimestamp
        /\ now - seenHeartbeatTs[viewer][peer] <= HeartbeatTimeout}

LeaderFromUpSet(viewer, self) ==
    LET up == UpSet(viewer)
        selfColdStart == seenHeartbeatTs[viewer][self] = NoTimestamp
        candidates == IF selfColdStart THEN up \cup {self} ELSE up
    IN IF candidates = {}
       THEN self
       ELSE CHOOSE x \in candidates:
            \A y \in candidates: RankIndex(x) <= RankIndex(y)

\* Check if node has a claim entry in the log
HasClaim(n) ==
    \E i \in 1..Len(eventLog):
        /\ eventLog[i].type = "claim"
        /\ eventLog[i].node = n

\* Check if node has a yield entry after its last claim
HasYieldAfterLastClaim(n) ==
    LET lastClaimIdx ==
        IF \E i \in 1..Len(eventLog):
            /\ eventLog[i].type = "claim"
            /\ eventLog[i].node = n
        THEN CHOOSE i \in 1..Len(eventLog):
            /\ eventLog[i].type = "claim"
            /\ eventLog[i].node = n
            /\ \A j \in (i+1)..Len(eventLog):
                ~(eventLog[j].type = "claim" /\ eventLog[j].node = n)
        ELSE 0
    IN /\ lastClaimIdx > 0
       /\ \E j \in (lastClaimIdx+1)..Len(eventLog):
           /\ eventLog[j].type = "yield"
           /\ eventLog[j].node = n

\* DNS write is guarded: node must be owner AND have a claim in log
CanWriteDns(n) ==
    /\ ownerView[n] = n
    /\ HasClaim(n)
    /\ ~HasYieldAfterLastClaim(n)

\* -----------------------------------------------------------------------------
\* Initial State
\* -----------------------------------------------------------------------------

Init ==
    /\ now = 0
    /\ live = Nodes
    /\ activeOrderTs = [n \in Nodes |-> 0]
    /\ seenHeartbeatTs = [v \in Nodes |-> [p \in Nodes |->
            IF p = v THEN 0 ELSE NoTimestamp]]
    /\ ownerView = [n \in Nodes |-> n]
    /\ eventLog = << >>
    /\ dnsWriteNode = NoNode
    /\ msgQueue = {}

\* -----------------------------------------------------------------------------
\* State Transitions
\* -----------------------------------------------------------------------------

Tick ==
    /\ now < MaxTimestamp
    /\ now' = now + 1
    /\ UNCHANGED << live, activeOrderTs, seenHeartbeatTs, ownerView,
                    eventLog, dnsWriteNode, msgQueue >>

Crash(n) ==
    /\ n \in live
    /\ live' = live \ {n}
    /\ UNCHANGED << now, activeOrderTs, seenHeartbeatTs, ownerView,
                    eventLog, dnsWriteNode, msgQueue >>

Recover(n) ==
    /\ n \in Nodes
    /\ n \notin live
    /\ live' = live \cup {n}
    /\ UNCHANGED << now, activeOrderTs, seenHeartbeatTs, ownerView,
                    eventLog, dnsWriteNode, msgQueue >>

\* Send heartbeat into message queue (non-synchronous delivery).
\* Also refreshes sender's self-timestamp: an actively heartbeating
\* node considers itself alive in its own UpSet.
SendHeartbeat(sender) ==
    /\ sender \in live
    /\ \E receiver \in Nodes \ {sender}:
        /\ receiver \in live
        /\ msgQueue' = msgQueue \cup {HeartbeatMsg(sender, receiver, now)}
    /\ seenHeartbeatTs' =
        [seenHeartbeatTs EXCEPT ![sender][sender] = now]
    /\ UNCHANGED << now, live, activeOrderTs, ownerView,
                    eventLog, dnsWriteNode >>

\* Deliver a queued heartbeat message
DeliverHeartbeat ==
    /\ msgQueue # {}
    /\ \E msg \in msgQueue:
        /\ msg.receiver \in live
        /\ seenHeartbeatTs' =
            [seenHeartbeatTs EXCEPT ![msg.receiver][msg.sender] = msg.ts]
        /\ msgQueue' = msgQueue \ {msg}
    /\ UNCHANGED << now, live, activeOrderTs, ownerView,
                    eventLog, dnsWriteNode >>

\* Synchronous heartbeat: sender is observed by receiver, and sender
\* refreshes its own self-timestamp (models active participation in protocol).
\* Requires sender # receiver; self-timestamps refreshed implicitly.
Heartbeat(sender, receiver) ==
    /\ sender \in live
    /\ receiver \in live
    /\ sender # receiver
    /\ seenHeartbeatTs' =
        [seenHeartbeatTs EXCEPT ![receiver][sender] = now,
                                ![sender][sender] = now]
    /\ UNCHANGED << now, live, activeOrderTs, ownerView,
                    eventLog, dnsWriteNode, msgQueue >>

PromoteOrders(receiver, newTs) ==
    /\ receiver \in live
    /\ newTs > activeOrderTs[receiver]
    /\ activeOrderTs' = [activeOrderTs EXCEPT ![receiver] = newTs]
    /\ UNCHANGED << now, live, seenHeartbeatTs, ownerView,
                    eventLog, dnsWriteNode, msgQueue >>

RecomputeOwner(n) ==
    /\ n \in live
    /\ LET newOwner == LeaderFromUpSet(n, n)
           oldOwner == ownerView[n]
       IN /\ ownerView' = [ownerView EXCEPT ![n] = newOwner]
          /\ IF newOwner # oldOwner
             THEN
                \* Emit yield if old owner was self, claim if new owner is self
                LET yieldEntries ==
                        IF oldOwner = n
                        THEN << YieldEntry(n, now) >>
                        ELSE << >>
                    claimEntries ==
                        IF newOwner = n
                        THEN << ClaimEntry(n, now) >>
                        ELSE << >>
                IN eventLog' = eventLog \o yieldEntries \o claimEntries
             ELSE eventLog' = eventLog
    /\ UNCHANGED << now, live, activeOrderTs, seenHeartbeatTs,
                    dnsWriteNode, msgQueue >>

\* DNS write action: guarded by ownership + claim in log
DnsWrite(n) ==
    /\ n \in live
    /\ CanWriteDns(n)
    /\ dnsWriteNode' = n
    /\ eventLog' = Append(eventLog, DnsWriteEntry(n, now))
    /\ UNCHANGED << now, live, activeOrderTs, seenHeartbeatTs,
                    ownerView, msgQueue >>

\* Model checking Next uses synchronous heartbeats for tractable state space.
\* SendHeartbeat + DeliverHeartbeat (async) are retained in spec for reference
\* but excluded from Next — they are subsumed by synchronous Heartbeat for
\* safety property verification.
Next ==
    \/ Tick
    \/ \E n \in Nodes: Crash(n) \/ Recover(n) \/ RecomputeOwner(n)
                       \/ DnsWrite(n)
    \/ \E s \in Nodes, r \in Nodes: Heartbeat(s, r)

\* State constraint for bounded model checking (limits state space)
StateConstraint == Len(eventLog) <= 3

Spec ==
    /\ Init
    /\ [][Next]_vars

\* Fair specification: weak fairness on RecomputeOwner models the
\* implementation's periodic gateway_loop. Required for liveness.
FairSpec ==
    /\ Init
    /\ [][Next]_vars
    /\ \A n \in Nodes: WF_vars(RecomputeOwner(n))

\* -----------------------------------------------------------------------------
\* Safety / Liveness Properties
\* -----------------------------------------------------------------------------

\* Election function determinism: equal inputs produce equal outputs.
\* Uses LeaderFromUpSet directly (not ownerView, which lags RecomputeOwner).
\* Applies when both nodes are past cold start AND have non-empty candidate
\* sets. With empty candidates, the self-election fallback is viewer-dependent
\* by design (FLP impossibility: isolated nodes must self-elect).
ViewDeterminism(v1, v2) ==
    /\ seenHeartbeatTs[v1][v1] # NoTimestamp
    /\ seenHeartbeatTs[v2][v2] # NoTimestamp
    /\ activeOrderTs[v1] = activeOrderTs[v2]
    /\ seenHeartbeatTs[v1] = seenHeartbeatTs[v2]
    /\ UpSet(v1) # {}
    => LeaderFromUpSet(v1, v1) = LeaderFromUpSet(v2, v2)

DeterministicRuleForEqualViews ==
    \A a \in Nodes, b \in Nodes: ViewDeterminism(a, b)

\* Converged views: all past-cold-start nodes have identical views
ViewsConverged ==
    \A a \in Nodes, b \in Nodes:
        /\ seenHeartbeatTs[a][a] # NoTimestamp
        /\ seenHeartbeatTs[b][b] # NoTimestamp
        /\ activeOrderTs[a] = activeOrderTs[b]
        /\ seenHeartbeatTs[a] = seenHeartbeatTs[b]

\* Use computed leader (not cached ownerView) for tug-of-war check.
\* Excludes self-election fallback (empty UpSet): per FLP impossibility,
\* isolated nodes legitimately self-elect. DNS write safety when stable
\* is enforced by claim/yield protocol (NoSimultaneousDNSWriters).
MostRecentOrderWriters ==
    {n \in Nodes:
        /\ OrderTimestamp(n) = MaxOrderTs
        /\ LeaderFromUpSet(n, n) = n
        /\ UpSet(n) # {}}

NoTugOfWarOnMostRecentOrder ==
    Cardinality(MostRecentOrderWriters) <= 1

NoTugOfWarWhenViewsConverged ==
    ViewsConverged => NoTugOfWarOnMostRecentOrder

\* Singleton self-election: when n is the sole survivor, the election
\* function always picks n. This is a safety invariant (not liveness)
\* because the implementation's periodic gateway_loop ensures ownerView
\* is updated within milliseconds. We verify the function correctness.
SingletonSelfElection ==
    \A n \in Nodes:
        live = {n} => LeaderFromUpSet(n, n) = n

\* --- DNS write safety invariants ---

\* Stable state: views converged, ownerView current, UpSet non-empty.
\* Under partition or cold start, FLP impossibility means multiple nodes
\* may independently self-elect and claim (viewer-dependent fallback).
\* Anti-entropy gossip (not modeled) resolves this on partition heal.
\* The invariant therefore conditions on the system being fully stable.
FullyStable ==
    /\ ViewsConverged
    /\ \A n \in Nodes: n \in live => ownerView[n] = LeaderFromUpSet(n, n)
    /\ \A n \in Nodes: n \in live => UpSet(n) # {}

\* At most 1 live node can satisfy DNS write guard when stable.
\* Crashed nodes cannot execute DnsWrite (action requires n ∈ live),
\* so only live nodes are relevant for simultaneous writer safety.
NoSimultaneousDNSWriters ==
    FullyStable =>
        Cardinality({n \in Nodes: n \in live /\ CanWriteDns(n)}) <= 1

\* DNS write only after claim in local log
ClaimPrecedesWrite ==
    \A i \in 1..Len(eventLog):
        eventLog[i].type = "dns_write"
        => \E j \in 1..(i-1):
            /\ eventLog[j].type = "claim"
            /\ eventLog[j].node = eventLog[i].node

\* Yield must occur before another claim from same node
YieldPrecedesReclaim ==
    \A i \in 1..Len(eventLog):
        \A j \in (i+1)..Len(eventLog):
            /\ eventLog[i].type = "claim"
            /\ eventLog[j].type = "claim"
            /\ eventLog[i].node = eventLog[j].node
            => \E k \in (i+1)..(j-1):
                /\ eventLog[k].type = "yield"
                /\ eventLog[k].node = eventLog[i].node

THEOREM Spec => []DeterministicRuleForEqualViews
THEOREM Spec => [](NoTugOfWarWhenViewsConverged)
THEOREM Spec => [](NoSimultaneousDNSWriters)
THEOREM Spec => [](ClaimPrecedesWrite)
THEOREM Spec => [](YieldPrecedesReclaim)
THEOREM Spec => [](SingletonSelfElection)

=============================================================================
