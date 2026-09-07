---- MODULE gateway_legacy_liveness ----
EXTENDS Integers, FiniteSets

CONSTANTS
    Nodes,
    NoBoot,
    MaxBoot,
    MaxFrameSequence,
    MaxTime,
    HeartbeatTimeout

ASSUME /\ Nodes # {}
       /\ MaxBoot \in Nat \ {0}
       /\ MaxFrameSequence \in Nat \ {0}
       /\ MaxTime \in Nat \ {0}
       /\ HeartbeatTimeout \in Nat \ {0}
       /\ NoBoot \notin 1..MaxBoot

Boots == 1..MaxBoot
BootOrNone == Boots \cup {NoBoot}
FrameSequences == 0..MaxFrameSequence
Times == 0..MaxTime

FrameRecords ==
    [present: BOOLEAN,
     boot: BootOrNone,
     sequence: FrameSequences,
     timestamp: Times]

EmptyFrame ==
    [present |-> FALSE,
     boot |-> NoBoot,
     sequence |-> 0,
     timestamp |-> 0]

VARIABLES
    clock,
    runningBoot,
    durableBoot,
    observedBoot,
    observedCursorBoot,
    sourceFrame,
    delayedFrame,
    receivedFrame

vars ==
    << clock,
       runningBoot,
       durableBoot,
       observedBoot,
       observedCursorBoot,
       sourceFrame,
       delayedFrame,
       receivedFrame >>

FrameShape(frame) ==
    IF frame.present
    THEN /\ frame.boot \in Boots
         /\ frame.sequence \in 1..MaxFrameSequence
    ELSE frame = EmptyFrame

Fresh(frame) ==
    /\ frame.present
    /\ frame.timestamp + HeartbeatTimeout > clock

Init ==
    /\ clock = 0
    /\ runningBoot = [n \in Nodes |-> NoBoot]
    /\ durableBoot = [n \in Nodes |-> NoBoot]
    /\ observedBoot =
          [viewer \in Nodes |-> [emitter \in Nodes |-> NoBoot]]
    /\ observedCursorBoot =
          [viewer \in Nodes |-> [emitter \in Nodes |-> NoBoot]]
    /\ sourceFrame = [n \in Nodes |-> EmptyFrame]
    /\ delayedFrame = [n \in Nodes |-> EmptyFrame]
    /\ receivedFrame =
          [viewer \in Nodes |-> [emitter \in Nodes |-> EmptyFrame]]

StartProcess(n, boot) ==
    /\ n \in Nodes
    /\ boot \in Boots
    /\ runningBoot[n] = NoBoot
    /\ boot > durableBoot[n]
    /\ runningBoot' = [runningBoot EXCEPT ![n] = boot]
    /\ UNCHANGED << clock, durableBoot, observedBoot, observedCursorBoot, sourceFrame,
                    delayedFrame, receivedFrame >>

\* One persistence-first heartbeat fences a new legacy process boot.  A
\* remote viewer keeps its preceding observation until it receives this boot;
\* at that point the old liveness slot is cleared before any new frame enters.
PersistBootHeartbeat(n) ==
    /\ n \in Nodes
    /\ runningBoot[n] \in Boots
    /\ runningBoot[n] > durableBoot[n]
    /\ durableBoot' = [durableBoot EXCEPT ![n] = runningBoot[n]]
    /\ observedBoot' =
          [observedBoot EXCEPT ![n][n] = runningBoot[n]]
    /\ observedCursorBoot' =
          [observedCursorBoot EXCEPT ![n][n] = runningBoot[n]]
    /\ delayedFrame' =
          [delayedFrame EXCEPT
            ![n] = IF sourceFrame[n].present
                    THEN sourceFrame[n]
                    ELSE @]
    /\ sourceFrame' = [sourceFrame EXCEPT ![n] = EmptyFrame]
    /\ receivedFrame' =
          [receivedFrame EXCEPT ![n][n] = EmptyFrame]
    /\ UNCHANGED << clock, runningBoot >>

\* The periodic backend-proof worker commits a fresh semantic heartbeat and
\* then replaces the process-local liveness session.  A delayed frame under the
\* preceding fence is retained here so the model must prove that neither local
\* self-admission nor remote admission can revive it after rotation.
RefreshBackendProof(n, boot) ==
    /\ n \in Nodes
    /\ boot \in Boots
    /\ runningBoot[n] = durableBoot[n]
    /\ boot > durableBoot[n]
    /\ runningBoot' = [runningBoot EXCEPT ![n] = boot]
    /\ durableBoot' = [durableBoot EXCEPT ![n] = boot]
    /\ observedBoot' = [observedBoot EXCEPT ![n][n] = boot]
    /\ observedCursorBoot' =
          [observedCursorBoot EXCEPT ![n][n] = boot]
    /\ delayedFrame' =
          [delayedFrame EXCEPT
            ![n] = IF sourceFrame[n].present
                    THEN sourceFrame[n]
                    ELSE @]
    /\ sourceFrame' = [sourceFrame EXCEPT ![n] = EmptyFrame]
    /\ receivedFrame' =
          [receivedFrame EXCEPT ![n][n] = EmptyFrame]
    /\ UNCHANGED clock

ObserveBootHeartbeat(viewer, emitter) ==
    /\ viewer \in Nodes
    /\ emitter \in Nodes
    /\ viewer # emitter
    /\ durableBoot[emitter] \in Boots
    /\ observedBoot[viewer][emitter] # durableBoot[emitter]
    /\ observedBoot' =
          [observedBoot EXCEPT
            ![viewer][emitter] = durableBoot[emitter]]
    /\ observedCursorBoot' =
          [observedCursorBoot EXCEPT
            ![viewer][emitter] = durableBoot[emitter]]
    /\ receivedFrame' =
          [receivedFrame EXCEPT ![viewer][emitter] = EmptyFrame]
    /\ UNCHANGED << clock, runningBoot, durableBoot, sourceFrame,
                    delayedFrame >>

\* A restored checkpoint can prove that its semantic cursor has reached the
\* signed boot heartbeat even when compaction omitted the latest-heartbeat
\* projection.  The liveness frame carries the complete signed boot witness;
\* this action models the cursor half of the receiver's admission check without
\* fabricating a semantic heartbeat observation.
ObserveCompactedCursor(viewer, emitter) ==
    /\ viewer \in Nodes
    /\ emitter \in Nodes
    /\ viewer # emitter
    /\ durableBoot[emitter] \in Boots
    /\ observedCursorBoot[viewer][emitter] # durableBoot[emitter]
    /\ observedCursorBoot' =
          [observedCursorBoot EXCEPT
            ![viewer][emitter] = durableBoot[emitter]]
    /\ receivedFrame' =
          [receivedFrame EXCEPT ![viewer][emitter] = EmptyFrame]
    /\ UNCHANGED << clock, runningBoot, durableBoot, observedBoot,
                    sourceFrame, delayedFrame >>

EmitLiveness(n) ==
    LET current == sourceFrame[n]
        nextSequence ==
            IF current.present /\ current.boot = durableBoot[n]
            THEN current.sequence + 1
            ELSE 1
        candidate ==
            [present |-> TRUE,
             boot |-> durableBoot[n],
             sequence |-> nextSequence,
             timestamp |-> clock]
    IN /\ n \in Nodes
       /\ runningBoot[n] \in Boots
       /\ runningBoot[n] = durableBoot[n]
       /\ observedBoot[n][n] = durableBoot[n]
       /\ observedCursorBoot[n][n] = durableBoot[n]
       /\ nextSequence \in 1..MaxFrameSequence
       /\ sourceFrame' = [sourceFrame EXCEPT ![n] = candidate]
       /\ delayedFrame' =
             [delayedFrame EXCEPT
               ![n] = IF current.present THEN current ELSE @]
       /\ receivedFrame' =
             [receivedFrame EXCEPT ![n][n] = candidate]
       /\ UNCHANGED << clock, runningBoot, durableBoot, observedBoot,
                       observedCursorBoot >>

AcceptFrame(viewer, emitter, candidate) ==
    LET current == receivedFrame[viewer][emitter]
    IN /\ viewer \in Nodes
       /\ emitter \in Nodes
       /\ viewer # emitter
       /\ candidate.present
       /\ \/ candidate.boot = observedBoot[viewer][emitter]
          \/ candidate.boot = observedCursorBoot[viewer][emitter]
       /\ candidate.timestamp <= clock
       /\ ( \/ ~current.present
            \/ /\ current.boot = candidate.boot
               /\ candidate.sequence > current.sequence
               /\ candidate.timestamp >= current.timestamp )
       /\ receivedFrame' =
             [receivedFrame EXCEPT ![viewer][emitter] = candidate]
       /\ UNCHANGED << clock, runningBoot, durableBoot, observedBoot,
                       observedCursorBoot,
                       sourceFrame, delayedFrame >>

DeliverCurrentFrame(viewer, emitter) ==
    AcceptFrame(viewer, emitter, sourceFrame[emitter])

DeliverDelayedFrame(viewer, emitter) ==
    AcceptFrame(viewer, emitter, delayedFrame[emitter])

CrashProcess(n) ==
    /\ n \in Nodes
    /\ runningBoot[n] \in Boots
    /\ runningBoot' = [runningBoot EXCEPT ![n] = NoBoot]
    /\ delayedFrame' =
          [delayedFrame EXCEPT
            ![n] = IF sourceFrame[n].present
                    THEN sourceFrame[n]
                    ELSE @]
    /\ sourceFrame' = [sourceFrame EXCEPT ![n] = EmptyFrame]
    /\ receivedFrame' =
          [receivedFrame EXCEPT ![n][n] = EmptyFrame]
    /\ UNCHANGED << clock, durableBoot, observedBoot,
                    observedCursorBoot >>

AdvanceClock ==
    /\ clock < MaxTime
    /\ clock' = clock + 1
    /\ UNCHANGED << runningBoot, durableBoot, observedBoot,
                    observedCursorBoot, sourceFrame,
                    delayedFrame, receivedFrame >>

Next ==
    \/ \E n \in Nodes, boot \in Boots: StartProcess(n, boot)
    \/ \E n \in Nodes: PersistBootHeartbeat(n)
    \/ \E n \in Nodes, boot \in Boots: RefreshBackendProof(n, boot)
    \/ \E viewer \in Nodes, emitter \in Nodes:
         ObserveBootHeartbeat(viewer, emitter)
    \/ \E viewer \in Nodes, emitter \in Nodes:
         ObserveCompactedCursor(viewer, emitter)
    \/ \E n \in Nodes: EmitLiveness(n)
    \/ \E viewer \in Nodes, emitter \in Nodes:
         DeliverCurrentFrame(viewer, emitter)
    \/ \E viewer \in Nodes, emitter \in Nodes:
         DeliverDelayedFrame(viewer, emitter)
    \/ \E n \in Nodes: CrashProcess(n)
    \/ AdvanceClock

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ clock \in Times
    /\ runningBoot \in [Nodes -> BootOrNone]
    /\ durableBoot \in [Nodes -> BootOrNone]
    /\ observedBoot \in [Nodes -> [Nodes -> BootOrNone]]
    /\ observedCursorBoot \in [Nodes -> [Nodes -> BootOrNone]]
    /\ sourceFrame \in [Nodes -> FrameRecords]
    /\ delayedFrame \in [Nodes -> FrameRecords]
    /\ receivedFrame \in [Nodes -> [Nodes -> FrameRecords]]
    /\ \A n \in Nodes:
         /\ FrameShape(sourceFrame[n])
         /\ FrameShape(delayedFrame[n])
    /\ \A viewer \in Nodes, emitter \in Nodes:
         FrameShape(receivedFrame[viewer][emitter])

LocalBootObservationIsExact ==
    \A n \in Nodes:
      /\ observedBoot[n][n] = durableBoot[n]
      /\ observedCursorBoot[n][n] = durableBoot[n]

SourceFrameHasLiveDurableFence ==
    \A n \in Nodes:
      sourceFrame[n].present =>
        /\ runningBoot[n] = durableBoot[n]
        /\ sourceFrame[n].boot = durableBoot[n]

AcceptedFrameHasAuthenticatedFenceEvidence ==
    \A viewer \in Nodes, emitter \in Nodes:
      receivedFrame[viewer][emitter].present =>
        \/ receivedFrame[viewer][emitter].boot = observedBoot[viewer][emitter]
        \/ receivedFrame[viewer][emitter].boot = observedCursorBoot[viewer][emitter]

FreshFrameHasAuthenticatedFenceEvidence ==
    \A viewer \in Nodes, emitter \in Nodes:
      Fresh(receivedFrame[viewer][emitter]) =>
        \/ receivedFrame[viewer][emitter].boot = observedBoot[viewer][emitter]
        \/ receivedFrame[viewer][emitter].boot = observedCursorBoot[viewer][emitter]

FreshLocalFrameRequiresLiveDurableBoot ==
    \A n \in Nodes:
      Fresh(receivedFrame[n][n]) =>
        /\ runningBoot[n] = durableBoot[n]
        /\ receivedFrame[n][n].boot = durableBoot[n]

====
