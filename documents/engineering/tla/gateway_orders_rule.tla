---- MODULE gateway_orders_rule ----
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    Nodes,
    NoNode,
    MaxEpoch,
    MaxSequence,
    MaxOrdersVersion,
    Rank1,
    Rank2

ASSUME /\ Nodes # {}
       /\ NoNode \notin Nodes
       /\ MaxEpoch \in Nat \ {0}
       /\ MaxSequence \in Nat \ {0}
       /\ MaxOrdersVersion \in Nat \ {0}
       /\ {Rank1, Rank2} = Nodes
       /\ Rank1 # Rank2

\* This model corresponds to the bounded production representation.  There is
\* no event-log variable.  Each viewer retains one semantic checkpoint and one
\* cursor per configured emitter.  Each directed peer link has one
\* overwriteable delta slot; a gap caused by overwrite is repaired from one
\* bounded per-emitter semantic checkpoint rather than accepted as a delta.

RankOrder == <<Rank1, Rank2>>
NodeOrNone == Nodes \cup {NoNode}
Epochs == 0..MaxEpoch
Sequences == 0..MaxSequence
OrdersVersions == 0..MaxOrdersVersion
AssertionKinds == {"none", "heartbeat", "claim", "yield", "checkpoint"}
PublishKinds == AssertionKinds \ {"none"}
AuthorityPhases == {"idle", "staged"}

NoEpoch == -1
NoSequence == -1
NoOrdersVersion == -1

VARIABLES
    live,
    activeOrders,
    promotionSlot,
    ownerView,
    latestEpoch,
    latestSequence,
    latestKind,
    cursorEpoch,
    cursorSequence,
    deltaPresent,
    deltaOrders,
    deltaEpoch,
    deltaSequence,
    deltaKind,
    authorityOrders,
    authorityEpoch,
    authoritySequence,
    authorityKind,
    authorityPhase,
    stagedOrders,
    stagedEpoch,
    stagedSequence,
    stagedKind,
    stageObserved,
    publishAcknowledged,
    continuityObservable,
    credentialReady,
    dnsWriteNode

vars ==
    << live,
       activeOrders,
       promotionSlot,
       ownerView,
       latestEpoch,
       latestSequence,
       latestKind,
       cursorEpoch,
       cursorSequence,
       deltaPresent,
       deltaOrders,
       deltaEpoch,
       deltaSequence,
       deltaKind,
       authorityOrders,
       authorityEpoch,
       authoritySequence,
       authorityKind,
       authorityPhase,
       stagedOrders,
       stagedEpoch,
       stagedSequence,
       stagedKind,
       stageObserved,
       publishAcknowledged,
       continuityObservable,
       credentialReady,
       dnsWriteNode >>

RankIndex(n) == CHOOSE i \in 1..Len(RankOrder): RankOrder[i] = n

Leader ==
    IF live = {}
    THEN NoNode
    ELSE CHOOSE n \in live: \A other \in live: RankIndex(n) <= RankIndex(other)

PositionNewer(e1, s1, e0, s0) ==
    \/ e1 > e0
    \/ /\ e1 = e0
       /\ s1 > s0

ImmediateSuccessor(e1, s1, kind1, e0, s0) ==
    \/ /\ e1 = e0
       /\ s0 < MaxSequence
       /\ s1 = s0 + 1
    \/ /\ e0 < MaxEpoch
       /\ s0 = MaxSequence
       /\ e1 = e0 + 1
       /\ s1 = 0
       /\ kind1 = "checkpoint"

DurableEpoch(n) ==
    IF authorityPhase[n] = "staged" THEN stagedEpoch[n] ELSE authorityEpoch[n]

DurableSequence(n) ==
    IF authorityPhase[n] = "staged" THEN stagedSequence[n] ELSE authoritySequence[n]

CanWriteDns(n) ==
    /\ n \in live
    /\ ownerView[n] = n
    /\ latestKind[n][n] = "claim"
    /\ activeOrders[n] = MaxOrdersVersion
    /\ promotionSlot[n] = NoOrdersVersion
    /\ n \in credentialReady
    /\ n \in continuityObservable
    /\ authorityPhase[n] = "idle"
    /\ authorityOrders[n] = activeOrders[n]
    /\ authorityKind[n] = "claim"

ClearDeltaPresence(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN FALSE
        ELSE deltaPresent[receiver][emitter]]]

ClearDeltaOrders(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN NoOrdersVersion
        ELSE deltaOrders[receiver][emitter]]]

ClearDeltaEpoch(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN NoEpoch
        ELSE deltaEpoch[receiver][emitter]]]

ClearDeltaSequence(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN NoSequence
        ELSE deltaSequence[receiver][emitter]]]

ClearDeltaKind(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN "none"
        ELSE deltaKind[receiver][emitter]]]

Init ==
    /\ live = Nodes
    \* Version zero is a real active version, leaving version one reachable as
    \* the one bounded promotion candidate in the checked configuration.
    /\ activeOrders = [n \in Nodes |-> 0]
    /\ promotionSlot = [n \in Nodes |-> NoOrdersVersion]
    /\ ownerView = [n \in Nodes |-> NoNode]
    /\ latestEpoch = [v \in Nodes |-> [e \in Nodes |-> 0]]
    /\ latestSequence = [v \in Nodes |-> [e \in Nodes |-> 0]]
    /\ latestKind = [v \in Nodes |-> [e \in Nodes |-> "none"]]
    /\ cursorEpoch = [v \in Nodes |-> [e \in Nodes |-> 0]]
    /\ cursorSequence = [v \in Nodes |-> [e \in Nodes |-> 0]]
    /\ deltaPresent = [v \in Nodes |-> [e \in Nodes |-> FALSE]]
    /\ deltaOrders = [v \in Nodes |-> [e \in Nodes |-> NoOrdersVersion]]
    /\ deltaEpoch = [v \in Nodes |-> [e \in Nodes |-> NoEpoch]]
    /\ deltaSequence = [v \in Nodes |-> [e \in Nodes |-> NoSequence]]
    /\ deltaKind = [v \in Nodes |-> [e \in Nodes |-> "none"]]
    /\ authorityOrders = [n \in Nodes |-> 0]
    /\ authorityEpoch = [n \in Nodes |-> 0]
    /\ authoritySequence = [n \in Nodes |-> 0]
    /\ authorityKind = [n \in Nodes |-> "none"]
    /\ authorityPhase = [n \in Nodes |-> "idle"]
    /\ stagedOrders = [n \in Nodes |-> NoOrdersVersion]
    /\ stagedEpoch = [n \in Nodes |-> NoEpoch]
    /\ stagedSequence = [n \in Nodes |-> NoSequence]
    /\ stagedKind = [n \in Nodes |-> "none"]
    /\ stageObserved = [n \in Nodes |-> FALSE]
    /\ publishAcknowledged = [n \in Nodes |-> FALSE]
    /\ continuityObservable = Nodes
    /\ credentialReady = {}
    /\ dnsWriteNode = NoNode

\* A crash erases process-owned semantic/cursor state, promotion work,
\* credentials, peer-frame slots involving the process, and volatile
\* read-back/publication acknowledgements.  It does not mutate retained
\* authority fields or the mounted active Orders version.
Crash(n) ==
    /\ n \in live
    /\ live' = live \ {n}
    /\ promotionSlot' = [promotionSlot EXCEPT ![n] = NoOrdersVersion]
    /\ ownerView' = [ownerView EXCEPT ![n] = NoNode]
    /\ latestEpoch' = [latestEpoch EXCEPT ![n] = [e \in Nodes |-> NoEpoch]]
    /\ latestSequence' = [latestSequence EXCEPT ![n] = [e \in Nodes |-> NoSequence]]
    /\ latestKind' = [latestKind EXCEPT ![n] = [e \in Nodes |-> "none"]]
    /\ cursorEpoch' = [cursorEpoch EXCEPT ![n] = [e \in Nodes |-> NoEpoch]]
    /\ cursorSequence' = [cursorSequence EXCEPT ![n] = [e \in Nodes |-> NoSequence]]
    /\ deltaPresent' = ClearDeltaPresence(n)
    /\ deltaOrders' = ClearDeltaOrders(n)
    /\ deltaEpoch' = ClearDeltaEpoch(n)
    /\ deltaSequence' = ClearDeltaSequence(n)
    /\ deltaKind' = ClearDeltaKind(n)
    /\ stageObserved' = [stageObserved EXCEPT ![n] = FALSE]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = FALSE]
    /\ credentialReady' = credentialReady \ {n}
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << activeOrders,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    continuityObservable >>

\* Recovery reads the complete bounded retained checkpoint set.  It does not
\* infer the local emitter anchor from a peer.  A pending retained assertion
\* remains pending; the process must re-observe and publish those exact staged
\* bytes again before it may commit them.
Recover(n) ==
    /\ n \notin live
    /\ n \in continuityObservable
    /\ live' = live \cup {n}
    /\ latestEpoch' = [latestEpoch EXCEPT ![n] = [e \in Nodes |-> authorityEpoch[e]]]
    /\ latestSequence' =
          [latestSequence EXCEPT ![n] = [e \in Nodes |-> authoritySequence[e]]]
    /\ latestKind' =
          [latestKind EXCEPT
            ![n] = [e \in Nodes |->
                      IF authorityOrders[e] = activeOrders[n]
                      THEN authorityKind[e]
                      ELSE "none"]]
    /\ cursorEpoch' = [cursorEpoch EXCEPT ![n] = [e \in Nodes |-> authorityEpoch[e]]]
    /\ cursorSequence' =
          [cursorSequence EXCEPT ![n] = [e \in Nodes |-> authoritySequence[e]]]
    /\ stageObserved' = [stageObserved EXCEPT ![n] = FALSE]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = FALSE]
    /\ UNCHANGED << activeOrders, promotionSlot, ownerView,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    continuityObservable, credentialReady, dnsWriteNode >>

\* The retained CAS stages the exact signed assertion and next anchor.  It is
\* durable but not yet a publication witness.
StageAssertion(n, kind) ==
    /\ n \in live
    /\ n \in continuityObservable
    /\ kind \in PublishKinds \ {"checkpoint"}
    /\ authorityPhase[n] = "idle"
    /\ authoritySequence[n] < MaxSequence
    /\ cursorEpoch[n][n] = authorityEpoch[n]
    /\ cursorSequence[n][n] = authoritySequence[n]
    /\ authorityPhase' = [authorityPhase EXCEPT ![n] = "staged"]
    /\ stagedOrders' = [stagedOrders EXCEPT ![n] = activeOrders[n]]
    /\ stagedEpoch' = [stagedEpoch EXCEPT ![n] = authorityEpoch[n]]
    /\ stagedSequence' = [stagedSequence EXCEPT ![n] = authoritySequence[n] + 1]
    /\ stagedKind' = [stagedKind EXCEPT ![n] = kind]
    /\ stageObserved' = [stageObserved EXCEPT ![n] = FALSE]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = FALSE]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence, authorityKind,
                    continuityObservable, credentialReady >>

\* Sequence exhaustion cannot wrap.  Only a signed invalidating checkpoint may
\* move to sequence zero in the next epoch.
StageEpochRotation(n) ==
    /\ n \in live
    /\ n \in continuityObservable
    /\ authorityPhase[n] = "idle"
    /\ authoritySequence[n] = MaxSequence
    /\ authorityEpoch[n] < MaxEpoch
    /\ cursorEpoch[n][n] = authorityEpoch[n]
    /\ cursorSequence[n][n] = authoritySequence[n]
    /\ authorityPhase' = [authorityPhase EXCEPT ![n] = "staged"]
    /\ stagedOrders' = [stagedOrders EXCEPT ![n] = activeOrders[n]]
    /\ stagedEpoch' = [stagedEpoch EXCEPT ![n] = authorityEpoch[n] + 1]
    /\ stagedSequence' = [stagedSequence EXCEPT ![n] = 0]
    /\ stagedKind' = [stagedKind EXCEPT ![n] = "checkpoint"]
    /\ stageObserved' = [stageObserved EXCEPT ![n] = FALSE]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = FALSE]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence, authorityKind,
                    continuityObservable, credentialReady >>

\* This is volatile proof that the process read back the exact retained staged
\* record.  A crash erases it without erasing the stage.
ReobserveStaged(n) ==
    /\ n \in live
    /\ n \in continuityObservable
    /\ authorityPhase[n] = "staged"
    /\ ~stageObserved[n]
    /\ stageObserved' = [stageObserved EXCEPT ![n] = TRUE]
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    publishAcknowledged,
                    continuityObservable, credentialReady, dnsWriteNode >>

\* Publication advances volatile semantic state and bounded peer slots but
\* deliberately leaves the retained stage intact.  A crash here loses the
\* acknowledgement and forces exact idempotent re-publication.
PublishStaged(n) ==
    /\ n \in live
    /\ n \in continuityObservable
    /\ authorityPhase[n] = "staged"
    /\ stageObserved[n]
    /\ ~publishAcknowledged[n]
    /\ activeOrders[n] = stagedOrders[n]
    /\ latestEpoch' = [latestEpoch EXCEPT ![n][n] = stagedEpoch[n]]
    /\ latestSequence' = [latestSequence EXCEPT ![n][n] = stagedSequence[n]]
    /\ latestKind' = [latestKind EXCEPT ![n][n] = stagedKind[n]]
    /\ cursorEpoch' = [cursorEpoch EXCEPT ![n][n] = stagedEpoch[n]]
    /\ cursorSequence' = [cursorSequence EXCEPT ![n][n] = stagedSequence[n]]
    /\ deltaPresent' = [receiver \in Nodes |->
            IF receiver = n THEN deltaPresent[receiver]
            ELSE [deltaPresent[receiver] EXCEPT ![n] = TRUE]]
    /\ deltaOrders' = [receiver \in Nodes |->
            IF receiver = n THEN deltaOrders[receiver]
            ELSE [deltaOrders[receiver] EXCEPT ![n] = stagedOrders[n]]]
    /\ deltaEpoch' = [receiver \in Nodes |->
            IF receiver = n THEN deltaEpoch[receiver]
            ELSE [deltaEpoch[receiver] EXCEPT ![n] = stagedEpoch[n]]]
    /\ deltaSequence' = [receiver \in Nodes |->
            IF receiver = n THEN deltaSequence[receiver]
            ELSE [deltaSequence[receiver] EXCEPT ![n] = stagedSequence[n]]]
    /\ deltaKind' = [receiver \in Nodes |->
            IF receiver = n THEN deltaKind[receiver]
            ELSE [deltaKind[receiver] EXCEPT ![n] = stagedKind[n]]]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = TRUE]
    /\ dnsWriteNode' =
          IF dnsWriteNode = n /\ stagedKind[n] # "claim"
          THEN NoNode
          ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, continuityObservable, credentialReady >>

\* Only a successfully published assertion can replace the committed anchor
\* and clear the retained pending slot.
CommitPublished(n) ==
    /\ n \in live
    /\ n \in continuityObservable
    /\ authorityPhase[n] = "staged"
    /\ stageObserved[n]
    /\ publishAcknowledged[n]
    /\ authorityOrders' = [authorityOrders EXCEPT ![n] = stagedOrders[n]]
    /\ authorityEpoch' = [authorityEpoch EXCEPT ![n] = stagedEpoch[n]]
    /\ authoritySequence' = [authoritySequence EXCEPT ![n] = stagedSequence[n]]
    /\ authorityKind' = [authorityKind EXCEPT ![n] = stagedKind[n]]
    /\ authorityPhase' = [authorityPhase EXCEPT ![n] = "idle"]
    /\ stagedOrders' = [stagedOrders EXCEPT ![n] = NoOrdersVersion]
    /\ stagedEpoch' = [stagedEpoch EXCEPT ![n] = NoEpoch]
    /\ stagedSequence' = [stagedSequence EXCEPT ![n] = NoSequence]
    /\ stagedKind' = [stagedKind EXCEPT ![n] = "none"]
    /\ stageObserved' = [stageObserved EXCEPT ![n] = FALSE]
    /\ publishAcknowledged' = [publishAcknowledged EXCEPT ![n] = FALSE]
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    continuityObservable, credentialReady, dnsWriteNode >>

\* A delta is accepted only as the immediate cursor successor.  An overwritten
\* slot that creates a gap is repaired by RepairFromSemanticCheckpoint.
DeliverDelta(receiver, emitter) ==
    /\ receiver \in live
    /\ receiver # emitter
    /\ deltaPresent[receiver][emitter]
    /\ deltaOrders[receiver][emitter] = activeOrders[receiver]
    /\ ImmediateSuccessor(deltaEpoch[receiver][emitter],
                          deltaSequence[receiver][emitter],
                          deltaKind[receiver][emitter],
                          cursorEpoch[receiver][emitter],
                          cursorSequence[receiver][emitter])
    /\ cursorEpoch' = [cursorEpoch EXCEPT
            ![receiver][emitter] = deltaEpoch[receiver][emitter]]
    /\ cursorSequence' = [cursorSequence EXCEPT
            ![receiver][emitter] = deltaSequence[receiver][emitter]]
    /\ latestEpoch' = [latestEpoch EXCEPT
            ![receiver][emitter] = deltaEpoch[receiver][emitter]]
    /\ latestSequence' = [latestSequence EXCEPT
            ![receiver][emitter] = deltaSequence[receiver][emitter]]
    /\ latestKind' = [latestKind EXCEPT
            ![receiver][emitter] = deltaKind[receiver][emitter]]
    /\ deltaPresent' = [deltaPresent EXCEPT ![receiver][emitter] = FALSE]
    /\ deltaOrders' = [deltaOrders EXCEPT
            ![receiver][emitter] = NoOrdersVersion]
    /\ deltaEpoch' = [deltaEpoch EXCEPT ![receiver][emitter] = NoEpoch]
    /\ deltaSequence' = [deltaSequence EXCEPT
            ![receiver][emitter] = NoSequence]
    /\ deltaKind' = [deltaKind EXCEPT ![receiver][emitter] = "none"]
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady, dnsWriteNode >>

DiscardUnusableDelta(receiver, emitter) ==
    /\ receiver \in live
    /\ receiver # emitter
    /\ deltaPresent[receiver][emitter]
    /\ \/ deltaOrders[receiver][emitter] # activeOrders[receiver]
       \/ ~PositionNewer(deltaEpoch[receiver][emitter],
                         deltaSequence[receiver][emitter],
                         cursorEpoch[receiver][emitter],
                         cursorSequence[receiver][emitter])
    /\ deltaPresent' = [deltaPresent EXCEPT ![receiver][emitter] = FALSE]
    /\ deltaOrders' = [deltaOrders EXCEPT
            ![receiver][emitter] = NoOrdersVersion]
    /\ deltaEpoch' = [deltaEpoch EXCEPT ![receiver][emitter] = NoEpoch]
    /\ deltaSequence' = [deltaSequence EXCEPT
            ![receiver][emitter] = NoSequence]
    /\ deltaKind' = [deltaKind EXCEPT ![receiver][emitter] = "none"]
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady, dnsWriteNode >>

\* Runtime repair carries one bounded signed per-emitter semantic checkpoint,
\* then continues with a bounded replay suffix.  TLC abstracts the checkpoint
\* application as this atomic copy from a live donor on the same Orders anchor.
RepairFromSemanticCheckpoint(receiver, donor, emitter) ==
    /\ receiver \in live
    /\ donor \in live
    /\ receiver # donor
    /\ activeOrders[receiver] = activeOrders[donor]
    /\ PositionNewer(cursorEpoch[donor][emitter],
                     cursorSequence[donor][emitter],
                     cursorEpoch[receiver][emitter],
                     cursorSequence[receiver][emitter])
    /\ cursorEpoch' = [cursorEpoch EXCEPT
            ![receiver][emitter] = cursorEpoch[donor][emitter]]
    /\ cursorSequence' = [cursorSequence EXCEPT
            ![receiver][emitter] = cursorSequence[donor][emitter]]
    /\ latestEpoch' = [latestEpoch EXCEPT
            ![receiver][emitter] = latestEpoch[donor][emitter]]
    /\ latestSequence' = [latestSequence EXCEPT
            ![receiver][emitter] = latestSequence[donor][emitter]]
    /\ latestKind' = [latestKind EXCEPT
            ![receiver][emitter] = latestKind[donor][emitter]]
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady, dnsWriteNode >>

StageOrdersPromotion(n, version) ==
    /\ n \in live
    /\ authorityPhase[n] = "idle"
    /\ version \in OrdersVersions
    /\ version > activeOrders[n]
    /\ \/ promotionSlot[n] = NoOrdersVersion
       \/ version > promotionSlot[n]
    /\ promotionSlot' = [promotionSlot EXCEPT ![n] = version]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady >>

\* Promotion has exactly one slot and evicts semantic/ownership evidence from
\* the older Orders version without retaining per-version history.
CheckpointOrdersPromotion(n) ==
    /\ n \in live
    /\ authorityPhase[n] = "idle"
    /\ promotionSlot[n] # NoOrdersVersion
    /\ activeOrders' = [activeOrders EXCEPT ![n] = promotionSlot[n]]
    /\ promotionSlot' = [promotionSlot EXCEPT ![n] = NoOrdersVersion]
    /\ latestEpoch' = [latestEpoch EXCEPT ![n] = [e \in Nodes |-> authorityEpoch[e]]]
    /\ latestSequence' =
          [latestSequence EXCEPT ![n] = [e \in Nodes |-> authoritySequence[e]]]
    /\ latestKind' =
          [latestKind EXCEPT
            ![n] = [e \in Nodes |->
                      IF authorityOrders[e] = promotionSlot[n]
                      THEN authorityKind[e]
                      ELSE "none"]]
    /\ cursorEpoch' = [cursorEpoch EXCEPT ![n] = [e \in Nodes |-> authorityEpoch[e]]]
    /\ cursorSequence' =
          [cursorSequence EXCEPT ![n] = [e \in Nodes |-> authoritySequence[e]]]
    /\ ownerView' = [ownerView EXCEPT ![n] = NoNode]
    /\ deltaPresent' = ClearDeltaPresence(n)
    /\ deltaOrders' = ClearDeltaOrders(n)
    /\ deltaEpoch' = ClearDeltaEpoch(n)
    /\ deltaSequence' = ClearDeltaSequence(n)
    /\ deltaKind' = ClearDeltaKind(n)
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady >>

RecomputeOwner(n) ==
    /\ n \in live
    /\ ownerView' = [ownerView EXCEPT ![n] = Leader]
    /\ dnsWriteNode' =
          IF dnsWriteNode = n /\ Leader # n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady >>

ObserveCredential(n) ==
    /\ n \in live
    /\ credentialReady' = credentialReady \cup {n}
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, dnsWriteNode >>

LoseCredential(n) ==
    /\ n \in credentialReady
    /\ credentialReady' = credentialReady \ {n}
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable >>

LoseContinuityObservation(n) ==
    /\ n \in continuityObservable
    /\ continuityObservable' = continuityObservable \ {n}
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    credentialReady >>

RestoreContinuityObservation(n) ==
    /\ n \notin continuityObservable
    /\ continuityObservable' = continuityObservable \cup {n}
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    credentialReady, dnsWriteNode >>

DnsWrite(n) ==
    /\ CanWriteDns(n)
    /\ dnsWriteNode' = n
    /\ UNCHANGED << live, activeOrders, promotionSlot, ownerView,
                    latestEpoch, latestSequence, latestKind,
                    cursorEpoch, cursorSequence,
                    deltaPresent, deltaOrders, deltaEpoch, deltaSequence, deltaKind,
                    authorityOrders, authorityEpoch, authoritySequence,
                    authorityKind, authorityPhase,
                    stagedOrders, stagedEpoch, stagedSequence, stagedKind,
                    stageObserved, publishAcknowledged,
                    continuityObservable, credentialReady >>

Next ==
    \/ \E n \in Nodes:
          \/ Crash(n)
          \/ Recover(n)
          \/ RecomputeOwner(n)
          \/ ObserveCredential(n)
          \/ LoseCredential(n)
          \/ LoseContinuityObservation(n)
          \/ RestoreContinuityObservation(n)
          \/ ReobserveStaged(n)
          \/ PublishStaged(n)
          \/ CommitPublished(n)
          \/ StageEpochRotation(n)
          \/ DnsWrite(n)
          \/ CheckpointOrdersPromotion(n)
          \/ \E kind \in PublishKinds \ {"checkpoint"}: StageAssertion(n, kind)
          \/ \E version \in OrdersVersions: StageOrdersPromotion(n, version)
    \/ \E receiver \in Nodes, emitter \in Nodes:
          \/ DeliverDelta(receiver, emitter)
          \/ DiscardUnusableDelta(receiver, emitter)
    \/ \E receiver \in Nodes, donor \in Nodes, emitter \in Nodes:
          RepairFromSemanticCheckpoint(receiver, donor, emitter)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ live \subseteq Nodes
    /\ activeOrders \in [Nodes -> OrdersVersions]
    /\ promotionSlot \in [Nodes -> OrdersVersions \cup {NoOrdersVersion}]
    /\ ownerView \in [Nodes -> NodeOrNone]
    /\ latestEpoch \in [Nodes -> [Nodes -> Epochs \cup {NoEpoch}]]
    /\ latestSequence \in [Nodes -> [Nodes -> Sequences \cup {NoSequence}]]
    /\ latestKind \in [Nodes -> [Nodes -> AssertionKinds]]
    /\ cursorEpoch \in [Nodes -> [Nodes -> Epochs \cup {NoEpoch}]]
    /\ cursorSequence \in [Nodes -> [Nodes -> Sequences \cup {NoSequence}]]
    /\ deltaPresent \in [Nodes -> [Nodes -> BOOLEAN]]
    /\ deltaOrders \in [Nodes -> [Nodes -> OrdersVersions \cup {NoOrdersVersion}]]
    /\ deltaEpoch \in [Nodes -> [Nodes -> Epochs \cup {NoEpoch}]]
    /\ deltaSequence \in [Nodes -> [Nodes -> Sequences \cup {NoSequence}]]
    /\ deltaKind \in [Nodes -> [Nodes -> AssertionKinds]]
    /\ authorityOrders \in [Nodes -> OrdersVersions]
    /\ authorityEpoch \in [Nodes -> Epochs]
    /\ authoritySequence \in [Nodes -> Sequences]
    /\ authorityKind \in [Nodes -> AssertionKinds]
    /\ authorityPhase \in [Nodes -> AuthorityPhases]
    /\ stagedOrders \in [Nodes -> OrdersVersions \cup {NoOrdersVersion}]
    /\ stagedEpoch \in [Nodes -> Epochs \cup {NoEpoch}]
    /\ stagedSequence \in [Nodes -> Sequences \cup {NoSequence}]
    /\ stagedKind \in [Nodes -> AssertionKinds]
    /\ stageObserved \in [Nodes -> BOOLEAN]
    /\ publishAcknowledged \in [Nodes -> BOOLEAN]
    /\ continuityObservable \subseteq Nodes
    /\ credentialReady \subseteq Nodes
    /\ dnsWriteNode \in NodeOrNone

SemanticPositionMatchesCursor ==
    \A viewer \in Nodes, emitter \in Nodes:
      /\ latestEpoch[viewer][emitter] = cursorEpoch[viewer][emitter]
      /\ latestSequence[viewer][emitter] = cursorSequence[viewer][emitter]

DeltaSlotsCanonical ==
    \A receiver \in Nodes, emitter \in Nodes:
      \/ deltaPresent[receiver][emitter]
      \/ /\ deltaOrders[receiver][emitter] = NoOrdersVersion
         /\ deltaEpoch[receiver][emitter] = NoEpoch
         /\ deltaSequence[receiver][emitter] = NoSequence
         /\ deltaKind[receiver][emitter] = "none"

\* A cursor alone is scoped by Orders.  Within the same Orders version, equal
\* cursor positions imply equal semantic kind as well as equal position.
EqualCursorAndOrdersDetermineSemantic ==
    \A v1 \in Nodes, v2 \in Nodes, emitter \in Nodes:
      /\ activeOrders[v1] = activeOrders[v2]
      /\ cursorEpoch[v1][emitter] = cursorEpoch[v2][emitter]
      /\ cursorSequence[v1][emitter] = cursorSequence[v2][emitter]
      => /\ latestEpoch[v1][emitter] = latestEpoch[v2][emitter]
         /\ latestSequence[v1][emitter] = latestSequence[v2][emitter]
         /\ latestKind[v1][emitter] = latestKind[v2][emitter]

\* A published-but-not-yet-committed cursor may equal the retained staged
\* frontier, but no viewer can move beyond that durable record.
NoCursorAheadOfDurableAuthority ==
    \A viewer \in Nodes, emitter \in Nodes:
      ~PositionNewer(cursorEpoch[viewer][emitter],
                     cursorSequence[viewer][emitter],
                     DurableEpoch(emitter),
                     DurableSequence(emitter))

StagedTransitionIsNonWrapping ==
    \A n \in Nodes:
      \/ /\ authorityPhase[n] = "idle"
         /\ stagedOrders[n] = NoOrdersVersion
         /\ stagedEpoch[n] = NoEpoch
         /\ stagedSequence[n] = NoSequence
         /\ stagedKind[n] = "none"
         /\ ~stageObserved[n]
         /\ ~publishAcknowledged[n]
      \/ /\ authorityPhase[n] = "staged"
         /\ stagedOrders[n] \in OrdersVersions
         /\ stagedKind[n] \in PublishKinds
         /\ publishAcknowledged[n] => stageObserved[n]
         /\ \/ /\ stagedEpoch[n] = authorityEpoch[n]
                /\ authoritySequence[n] < MaxSequence
                /\ stagedSequence[n] = authoritySequence[n] + 1
                /\ stagedKind[n] # "checkpoint"
            \/ /\ stagedEpoch[n] = authorityEpoch[n] + 1
                /\ authorityEpoch[n] < MaxEpoch
                /\ authoritySequence[n] = MaxSequence
                /\ stagedSequence[n] = 0
                /\ stagedKind[n] = "checkpoint"

DnsLeaseRequiresCompleteGate ==
    dnsWriteNode # NoNode => CanWriteDns(dnsWriteNode)

ClaimPrecedesWrite ==
    dnsWriteNode # NoNode => latestKind[dnsWriteNode][dnsWriteNode] = "claim"

FullyStable ==
    /\ live # {}
    /\ \A n \in live: ownerView[n] = Leader

NoSimultaneousDNSWriters ==
    FullyStable => Cardinality({n \in Nodes: CanWriteDns(n)}) <= 1

THEOREM Spec => []TypeOK
THEOREM Spec => []SemanticPositionMatchesCursor
THEOREM Spec => []DeltaSlotsCanonical
THEOREM Spec => []EqualCursorAndOrdersDetermineSemantic
THEOREM Spec => []NoCursorAheadOfDurableAuthority
THEOREM Spec => []StagedTransitionIsNonWrapping
THEOREM Spec => []DnsLeaseRequiresCompleteGate
THEOREM Spec => []ClaimPrecedesWrite
THEOREM Spec => []NoSimultaneousDNSWriters

=============================================================================
