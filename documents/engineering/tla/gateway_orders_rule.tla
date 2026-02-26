---- MODULE gateway_orders_rule ----
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, NoNode, HeartbeatTimeout

ASSUME /\ Nodes # {}
       /\ NoNode \notin Nodes
       /\ HeartbeatTimeout \in Nat \ {0}

NodeOrNone == Nodes \cup {NoNode}

VARIABLES
    now,
    live,                \* crash-stop truth (modeled environment fact)
    activeOrderTs,       \* per-node active Orders version timestamp
    seenHeartbeatTs,     \* per-node local heartbeat view map: [viewer -> [peer -> ts]]
    ownerView            \* per-node intended owner derived from local state

vars == << now, live, activeOrderTs, seenHeartbeatTs, ownerView >>

\* -----------------------------------------------------------------------------
\* Helper Operators
\* -----------------------------------------------------------------------------

OrderTimestamp(n) == activeOrderTs[n]

MaxOrderTs == Max({OrderTimestamp(n) : n \in Nodes})

UpSet(viewer) ==
    {peer \in Nodes:
        /\ peer \in live
        /\ now - seenHeartbeatTs[viewer][peer] <= HeartbeatTimeout}

LeaderFromUpSet(viewer, self) ==
    IF UpSet(viewer) = {}
    THEN self
    ELSE CHOOSE x \in UpSet(viewer): \A y \in UpSet(viewer): x <= y

CanPublishGateway(viewer) ==
    /\ OrderTimestamp(viewer) = MaxOrderTs
    /\ ownerView[viewer] = viewer

ViewDeterminism(v1, v2) ==
    /\ activeOrderTs[v1] = activeOrderTs[v2]
    /\ seenHeartbeatTs[v1] = seenHeartbeatTs[v2]
    => ownerView[v1] = ownerView[v2]

\* -----------------------------------------------------------------------------
\* Initial State
\* -----------------------------------------------------------------------------

Init ==
    /\ now = 0
    /\ live = Nodes
    /\ activeOrderTs = [n \in Nodes |-> 0]
    /\ seenHeartbeatTs = [v \in Nodes |-> [p \in Nodes |-> 0]]
    /\ ownerView = [n \in Nodes |-> n]

\* -----------------------------------------------------------------------------
\* State Transitions
\* -----------------------------------------------------------------------------

Tick ==
    /\ now' = now + 1
    /\ UNCHANGED << live, activeOrderTs, seenHeartbeatTs, ownerView >>

Crash(n) ==
    /\ n \in live
    /\ live' = live \ {n}
    /\ UNCHANGED << now, activeOrderTs, seenHeartbeatTs, ownerView >>

Recover(n) ==
    /\ n \in Nodes
    /\ n \notin live
    /\ live' = live \cup {n}
    /\ UNCHANGED << now, activeOrderTs, seenHeartbeatTs, ownerView >>

Heartbeat(sender, receiver) ==
    /\ sender \in live
    /\ receiver \in live
    /\ seenHeartbeatTs' =
        [seenHeartbeatTs EXCEPT ![receiver][sender] = now]
    /\ UNCHANGED << now, live, activeOrderTs, ownerView >>

PromoteOrders(receiver, newTs) ==
    /\ receiver \in live
    /\ newTs > activeOrderTs[receiver]
    /\ activeOrderTs' = [activeOrderTs EXCEPT ![receiver] = newTs]
    /\ UNCHANGED << now, live, seenHeartbeatTs, ownerView >>

RecomputeOwner(n) ==
    /\ n \in live
    /\ ownerView' = [ownerView EXCEPT ![n] = LeaderFromUpSet(n, n)]
    /\ UNCHANGED << now, live, activeOrderTs, seenHeartbeatTs >>

Next ==
    \/ Tick
    \/ \E n \in Nodes: Crash(n) \/ Recover(n) \/ RecomputeOwner(n)
    \/ \E s \in Nodes, r \in Nodes: Heartbeat(s, r)
    \/ \E r \in Nodes, ts \in Nat: PromoteOrders(r, ts)

Spec ==
    /\ Init
    /\ [][Next]_vars

\* -----------------------------------------------------------------------------
\* Safety / Liveness Properties
\* -----------------------------------------------------------------------------

MostRecentOrderWriters ==
    {n \in Nodes: CanPublishGateway(n)}

NoTugOfWarOnMostRecentOrder ==
    Cardinality(MostRecentOrderWriters) <= 1

DeterministicRuleForEqualViews ==
    \A a \in Nodes, b \in Nodes: ViewDeterminism(a, b)

ViewsConverged ==
    \A a \in Nodes, b \in Nodes:
        /\ activeOrderTs[a] = activeOrderTs[b]
        /\ seenHeartbeatTs[a] = seenHeartbeatTs[b]

NoTugOfWarWhenViewsConverged ==
    ViewsConverged => NoTugOfWarOnMostRecentOrder

SingletonTakeover ==
    \A n \in Nodes:
        []((live = {n}) => <> (ownerView[n] = n))

THEOREM Spec => []DeterministicRuleForEqualViews
THEOREM Spec => [](NoTugOfWarWhenViewsConverged)

=============================================================================
