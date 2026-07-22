---- MODULE gateway_orders_rule ----
EXTENDS Integers, FiniteSets, Sequences

CONSTANTS
    Nodes,
    NoNode,
    NoIncarnation,
    NoAdmission,
    MaxIncarnation,
    MaxAdmission,
    MaxEpoch,
    MaxSequence,
    MaxOrdersVersion,
    Rank1,
    Rank2

ASSUME /\ Nodes # {}
       /\ NoNode \notin Nodes
       /\ MaxIncarnation \in Nat
       /\ MaxIncarnation >= 2
       /\ NoIncarnation \notin 1..MaxIncarnation
       /\ MaxAdmission \in Nat
       /\ MaxAdmission >= 2
       /\ NoAdmission \notin 1..MaxAdmission
       /\ MaxEpoch \in Nat \ {0}
       /\ MaxSequence \in Nat \ {0}
       /\ MaxOrdersVersion \in Nat \ {0}
       /\ {Rank1, Rank2} = Nodes
       /\ Rank1 # Rank2

\* Sprint 2.32 models one bounded single-writer actor for each emitter.  The
\* actor may write only while one process incarnation simultaneously owns the
\* journal lock and the identity-bound Kubernetes Lease.  The journal protocol
\* is deliberately non-atomic here: admission, stage completion, stage fsync,
\* publish, commit write, and commit fsync are separate transitions with a
\* crash or deadline expiry between the applicable steps.

RankOrder == <<Rank1, Rank2>>
Incarnations == 1..MaxIncarnation
IncarnationOrNone == Incarnations \cup {NoIncarnation}
Admissions == 1..MaxAdmission
AdmissionOrNone == Admissions \cup {NoAdmission}
NodeOrNone == Nodes \cup {NoNode}
Epochs == 0..MaxEpoch
Sequences == 0..MaxSequence
OrdersVersions == 0..MaxOrdersVersion
\* "claim" represents the ownership-transition class.  Claim and yield share
\* the same journal/fence path; one representative avoids a redundant semantic
\* branch while heartbeat remains independently explored.
AssertionKinds == {"none", "heartbeat", "claim", "checkpoint"}
PublishKinds == AssertionKinds \ {"none"}
JournalPhases ==
    {"idle", "staging", "stageWritten", "stageDurable", "published",
     "commitWritten"}

NoEpoch == -1
NoSequence == -1
NoOrdersVersion == -1

SemanticRecords ==
    [incarnation: IncarnationOrNone,
     orders: OrdersVersions \cup {NoOrdersVersion},
     epoch: Epochs \cup {NoEpoch},
     sequence: Sequences \cup {NoSequence},
     kind: AssertionKinds]

PendingRecords ==
    [present: BOOLEAN,
     incarnation: IncarnationOrNone,
     orders: OrdersVersions \cup {NoOrdersVersion},
     epoch: Epochs \cup {NoEpoch},
     sequence: Sequences \cup {NoSequence},
     kind: AssertionKinds]

AckRecords ==
    [incarnation: Incarnations,
     orders: OrdersVersions,
     epoch: Epochs,
     sequence: Sequences,
     pending: BOOLEAN]

CheckpointRecords ==
    [incarnation: Incarnations,
     orders: OrdersVersions,
     epoch: Epochs,
     sequence: Sequences,
     kind: AssertionKinds]

JournalRecords ==
    [phase: JournalPhases,
     committedIncarnation: Incarnations,
     committedOrders: OrdersVersions,
     committedEpoch: Epochs,
     committedSequence: Sequences,
     committedKind: AssertionKinds,
     stagedIncarnation: IncarnationOrNone,
     stagedOrders: OrdersVersions \cup {NoOrdersVersion},
     stagedEpoch: Epochs \cup {NoEpoch},
     stagedSequence: Sequences \cup {NoSequence},
     stagedKind: AssertionKinds,
     activeAdmission: AdmissionOrNone,
     stagedAdmission: AdmissionOrNone,
     nextAdmission: AdmissionOrNone,
     deadlineOpen: BOOLEAN,
     lastPrePublishAdmission: AdmissionOrNone,
     lastPrePublishWasOpen: BOOLEAN,
     lastRejectedAdmission: AdmissionOrNone,
     lastRejectedAgainstAdmission: AdmissionOrNone,
     lastRejectedRecordAdmission: AdmissionOrNone,
     lastRejectedAgainstRecordAdmission: AdmissionOrNone,
     publicationWitness: BOOLEAN,
     transitionOwner: IncarnationOrNone]

EmptySemantic ==
    [incarnation |-> NoIncarnation,
     orders |-> NoOrdersVersion,
     epoch |-> NoEpoch,
     sequence |-> NoSequence,
     kind |-> "none"]

EmptyPending ==
    [present |-> FALSE,
     incarnation |-> NoIncarnation,
     orders |-> NoOrdersVersion,
     epoch |-> NoEpoch,
     sequence |-> NoSequence,
     kind |-> "none"]

InitialAck ==
    [incarnation |-> 1,
     orders |-> 0,
     epoch |-> 0,
     sequence |-> 0,
     pending |-> FALSE]

InitialCheckpoint ==
    [incarnation |-> 1,
     orders |-> 0,
     epoch |-> 0,
     sequence |-> 0,
     kind |-> "none"]

InitialJournal ==
    [phase |-> "idle",
     committedIncarnation |-> 1,
     committedOrders |-> 0,
     committedEpoch |-> 0,
     committedSequence |-> 0,
     committedKind |-> "none",
     stagedIncarnation |-> NoIncarnation,
     stagedOrders |-> NoOrdersVersion,
     stagedEpoch |-> NoEpoch,
     stagedSequence |-> NoSequence,
     stagedKind |-> "none",
     activeAdmission |-> NoAdmission,
     stagedAdmission |-> NoAdmission,
     nextAdmission |-> 1,
     deadlineOpen |-> FALSE,
     lastPrePublishAdmission |-> NoAdmission,
     lastPrePublishWasOpen |-> TRUE,
     lastRejectedAdmission |-> NoAdmission,
     lastRejectedAgainstAdmission |-> NoAdmission,
     lastRejectedRecordAdmission |-> NoAdmission,
     lastRejectedAgainstRecordAdmission |-> NoAdmission,
     publicationWitness |-> FALSE,
     transitionOwner |-> NoIncarnation]

VARIABLES
    running,
    journalLockHolder,
    durableIncarnation,
    leaseHolder,
    activeOrders,
    ownerView,
    semantic,
    pending,
    journal,
    acknowledgements,
    checkpoint,
    continuityObservable,
    credentialReady,
    dnsWriteNode

vars ==
    << running,
       journalLockHolder,
       durableIncarnation,
       leaseHolder,
       activeOrders,
       ownerView,
       semantic,
       pending,
       journal,
       acknowledgements,
       checkpoint,
       continuityObservable,
       credentialReady,
       dnsWriteNode >>

PositionNewer(a, b) ==
    \/ a.incarnation > b.incarnation
    \/ /\ a.incarnation = b.incarnation
       /\ \/ a.epoch > b.epoch
          \/ /\ a.epoch = b.epoch
             /\ a.sequence > b.sequence

ImmediateSuccessor(a, b) ==
    /\ a.incarnation >= b.incarnation
    /\ ( \/ /\ a.epoch = b.epoch
             /\ b.sequence < MaxSequence
             /\ a.sequence = b.sequence + 1
         \/ /\ b.epoch < MaxEpoch
             /\ b.sequence = MaxSequence
             /\ a.epoch = b.epoch + 1
             /\ a.sequence = 0
             /\ a.kind = "checkpoint" )

CommittedRecord(n) ==
    [incarnation |-> journal[n].committedIncarnation,
     orders |-> journal[n].committedOrders,
     epoch |-> journal[n].committedEpoch,
     sequence |-> journal[n].committedSequence,
     kind |-> journal[n].committedKind]

StagedRecord(n) ==
    [incarnation |-> journal[n].stagedIncarnation,
     orders |-> journal[n].stagedOrders,
     epoch |-> journal[n].stagedEpoch,
     sequence |-> journal[n].stagedSequence,
     kind |-> journal[n].stagedKind]

DurableRecord(n) ==
    IF journal[n].phase \in {"stageDurable", "published", "commitWritten"}
    THEN StagedRecord(n)
    ELSE CommittedRecord(n)

RecoveredRecord(viewer, emitter) ==
    [incarnation |-> journal[emitter].committedIncarnation,
     orders |-> activeOrders[viewer],
     epoch |-> journal[emitter].committedEpoch,
     sequence |-> journal[emitter].committedSequence,
     kind |->
         IF journal[emitter].committedOrders = activeOrders[viewer]
         THEN journal[emitter].committedKind
         ELSE "none"]

Fenced(n, incarnation) ==
    /\ incarnation \in running[n]
    /\ journalLockHolder[n] = incarnation
    /\ durableIncarnation[n] = incarnation
    /\ leaseHolder[n] = incarnation

LiveNodes ==
    {n \in Nodes: \E incarnation \in Incarnations: Fenced(n, incarnation)}

RankIndex(n) == CHOOSE i \in 1..Len(RankOrder): RankOrder[i] = n

Leader ==
    IF LiveNodes = {}
    THEN NoNode
    ELSE CHOOSE n \in LiveNodes:
           \A other \in LiveNodes: RankIndex(n) <= RankIndex(other)

CanWriteDns(n) ==
    /\ n \in LiveNodes
    /\ ownerView[n] = n
    /\ semantic[n][n].kind = "claim"
    /\ activeOrders[n] = MaxOrdersVersion
    /\ n \in credentialReady
    /\ n \in continuityObservable
    /\ journal[n].phase = "idle"
    /\ journal[n].committedOrders = activeOrders[n]
    /\ journal[n].committedIncarnation = semantic[n][n].incarnation
    /\ journal[n].committedEpoch = semantic[n][n].epoch
    /\ journal[n].committedSequence = semantic[n][n].sequence
    /\ journal[n].committedKind = "claim"

ClearPendingForNode(n) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF receiver = n \/ emitter = n
        THEN EmptyPending
        ELSE pending[receiver][emitter]]]

ClearPendingForEmitter(emitterToClear) ==
    [receiver \in Nodes |->
      [emitter \in Nodes |->
        IF emitter = emitterToClear
        THEN EmptyPending
        ELSE pending[receiver][emitter]]]

NextAdmission(admission) ==
    IF admission = MaxAdmission THEN NoAdmission ELSE admission + 1

ClearTransition(record) ==
    [record EXCEPT
      !.stagedIncarnation = NoIncarnation,
      !.stagedOrders = NoOrdersVersion,
      !.stagedEpoch = NoEpoch,
      !.stagedSequence = NoSequence,
      !.stagedKind = "none",
      !.activeAdmission = NoAdmission,
      !.stagedAdmission = NoAdmission,
      !.deadlineOpen = FALSE]

\* An un-fsynced stage disappears.  Every later crash point rolls back to the
\* exact durable stage, so restart republishes the same record before committing.
RewindJournal(record) ==
    CASE record.phase \in {"staging", "stageWritten"} ->
           [ClearTransition(record) EXCEPT
             !.phase = "idle",
             !.publicationWitness = FALSE,
             !.transitionOwner = NoIncarnation]
      [] record.phase \in {"stageDurable", "published", "commitWritten"} ->
           [record EXCEPT
             !.phase = "stageDurable",
             !.deadlineOpen = FALSE,
             !.publicationWitness = FALSE,
             !.transitionOwner = NoIncarnation]
      [] OTHER ->
           [record EXCEPT
             !.deadlineOpen = FALSE,
             !.transitionOwner = NoIncarnation]

Init ==
    \* Incarnation one has completed the lock/incarnation/Lease admission.  The
    \* second finite incarnation exercises overlap, crash, and restart.
    /\ running = [n \in Nodes |-> {1}]
    /\ journalLockHolder = [n \in Nodes |-> 1]
    /\ durableIncarnation = [n \in Nodes |-> 1]
    /\ leaseHolder = [n \in Nodes |-> 1]
    \* Orders admission, ranked ownership, credentials, and journal visibility
    \* begin in their established state.  Sprint 2.31 checked their churn; this
    \* refinement isolates the new actor/durability/fencing interleavings.
    /\ activeOrders = [n \in Nodes |-> MaxOrdersVersion]
    /\ ownerView = [n \in Nodes |-> Rank1]
    /\ semantic =
          [viewer \in Nodes |->
            [emitter \in Nodes |->
              [incarnation |-> 1,
               orders |-> MaxOrdersVersion,
               epoch |-> 0,
               sequence |-> 0,
               kind |-> "none"]]]
    /\ pending =
          [receiver \in Nodes |-> [emitter \in Nodes |-> EmptyPending]]
    /\ journal = [n \in Nodes |-> InitialJournal]
    /\ acknowledgements =
          [emitter \in Nodes |-> [peer \in Nodes |-> InitialAck]]
    /\ checkpoint = [n \in Nodes |-> InitialCheckpoint]
    /\ continuityObservable = Nodes
    /\ credentialReady = Nodes
    /\ dnsWriteNode = NoNode

\* A replacement Pod may overlap the old process, but it has no write authority
\* until the old OS lock is released and its greater incarnation is fsynced.
StartActor(n, incarnation) ==
    /\ incarnation \in Incarnations
    /\ incarnation \notin running[n]
    /\ incarnation > durableIncarnation[n]
    /\ running' = [running EXCEPT ![n] = @ \cup {incarnation}]
    /\ UNCHANGED << journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

AcquireJournalLock(n, incarnation) ==
    /\ incarnation \in running[n]
    /\ incarnation > durableIncarnation[n]
    /\ journalLockHolder[n] = NoIncarnation
    /\ leaseHolder[n] = NoIncarnation
    /\ journal[n].transitionOwner = NoIncarnation
    /\ journalLockHolder' = [journalLockHolder EXCEPT ![n] = incarnation]
    /\ UNCHANGED << running, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

FsyncIncarnation(n, incarnation) ==
    /\ incarnation \in running[n]
    /\ journalLockHolder[n] = incarnation
    /\ incarnation > durableIncarnation[n]
    /\ leaseHolder[n] = NoIncarnation
    /\ journal[n].transitionOwner = NoIncarnation
    /\ durableIncarnation' = [durableIncarnation EXCEPT ![n] = incarnation]
    /\ UNCHANGED << running, journalLockHolder, leaseHolder,
                    activeOrders, ownerView, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

AcquireLease(n, incarnation) ==
    /\ incarnation \in running[n]
    /\ journalLockHolder[n] = incarnation
    /\ durableIncarnation[n] = incarnation
    /\ leaseHolder[n] = NoIncarnation
    /\ journal[n].transitionOwner = NoIncarnation
    /\ leaseHolder' = [leaseHolder EXCEPT ![n] = incarnation]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation,
                    activeOrders, ownerView, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

\* Expiry revokes the actor immediately.  An un-fsynced stage is discarded;
\* publish/commit-before-final-fsync rolls back to the durable staged record.
ExpireLease(n, incarnation) ==
    /\ leaseHolder[n] = incarnation
    /\ leaseHolder' = [leaseHolder EXCEPT ![n] = NoIncarnation]
    /\ journal' =
          IF journal[n].transitionOwner = incarnation
          THEN [journal EXCEPT ![n] = RewindJournal(@)]
          ELSE journal
    /\ ownerView' = [ownerView EXCEPT ![n] = NoNode]
    /\ credentialReady' = credentialReady \ {n}
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation,
                    activeOrders, semantic, pending, acknowledgements,
                    checkpoint, continuityObservable >>

CrashActor(n, incarnation) ==
    /\ incarnation \in running[n]
    /\ running' = [running EXCEPT ![n] = @ \ {incarnation}]
    /\ journalLockHolder' =
          IF journalLockHolder[n] = incarnation
          THEN [journalLockHolder EXCEPT ![n] = NoIncarnation]
          ELSE journalLockHolder
    /\ leaseHolder' =
          IF leaseHolder[n] = incarnation
          THEN [leaseHolder EXCEPT ![n] = NoIncarnation]
          ELSE leaseHolder
    /\ journal' =
          IF journal[n].transitionOwner = incarnation
          THEN [journal EXCEPT ![n] = RewindJournal(@)]
          ELSE journal
    /\ semantic' =
          IF journalLockHolder[n] = incarnation
          THEN [semantic EXCEPT ![n] = [emitter \in Nodes |-> EmptySemantic]]
          ELSE semantic
    /\ pending' =
          IF journalLockHolder[n] = incarnation
          THEN ClearPendingForNode(n)
          ELSE pending
    /\ ownerView' =
          IF journalLockHolder[n] = incarnation
          THEN [ownerView EXCEPT ![n] = NoNode]
          ELSE ownerView
    /\ credentialReady' =
          IF journalLockHolder[n] = incarnation
          THEN credentialReady \ {n}
          ELSE credentialReady
    /\ dnsWriteNode' =
          IF dnsWriteNode = n /\ journalLockHolder[n] = incarnation
          THEN NoNode
          ELSE dnsWriteNode
    /\ UNCHANGED << durableIncarnation, activeOrders, acknowledgements,
                    checkpoint, continuityObservable >>

RecoverSemantic(n, incarnation) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ journal[n].transitionOwner = NoIncarnation
    /\ semantic' =
          [semantic EXCEPT
            ![n] = [emitter \in Nodes |-> RecoveredRecord(n, emitter)]]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, pending, journal, acknowledgements,
                    checkpoint, continuityObservable, credentialReady,
                    dnsWriteNode >>

BeginAssertion(n, incarnation, kind) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ kind \in PublishKinds \ {"checkpoint"}
    /\ journal[n].phase = "idle"
    /\ journal[n].nextAdmission # NoAdmission
    /\ semantic[n][n].epoch = journal[n].committedEpoch
    /\ semantic[n][n].sequence = journal[n].committedSequence
    /\ journal[n].committedSequence < MaxSequence
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "staging",
            ![n].stagedIncarnation = incarnation,
            ![n].stagedOrders = activeOrders[n],
            ![n].stagedEpoch = journal[n].committedEpoch,
            ![n].stagedSequence = journal[n].committedSequence + 1,
            ![n].stagedKind = kind,
            ![n].activeAdmission = journal[n].nextAdmission,
            ![n].stagedAdmission = NoAdmission,
            ![n].nextAdmission = NextAdmission(journal[n].nextAdmission),
            ![n].deadlineOpen = TRUE,
            ![n].publicationWitness = FALSE,
            ![n].transitionOwner = incarnation]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady >>

BeginEpochCheckpoint(n, incarnation) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ journal[n].phase = "idle"
    /\ journal[n].nextAdmission # NoAdmission
    /\ semantic[n][n].epoch = journal[n].committedEpoch
    /\ semantic[n][n].sequence = journal[n].committedSequence
    /\ journal[n].committedSequence = MaxSequence
    /\ journal[n].committedEpoch < MaxEpoch
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "staging",
            ![n].stagedIncarnation = incarnation,
            ![n].stagedOrders = activeOrders[n],
            ![n].stagedEpoch = journal[n].committedEpoch + 1,
            ![n].stagedSequence = 0,
            ![n].stagedKind = "checkpoint",
            ![n].activeAdmission = journal[n].nextAdmission,
            ![n].stagedAdmission = NoAdmission,
            ![n].nextAdmission = NextAdmission(journal[n].nextAdmission),
            ![n].deadlineOpen = TRUE,
            ![n].publicationWitness = FALSE,
            ![n].transitionOwner = incarnation]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady >>

\* The signing callback is fenced by its monotonically issued transition
\* admission.  Only this callback creates the exact immutable staged-record
\* identity subsequently carried by every phase completion.
CompleteStage(n, incarnation, admission) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ admission \in Admissions
    /\ journal[n].phase = "staging"
    /\ journal[n].transitionOwner = incarnation
    /\ journal[n].activeAdmission = admission
    /\ journal[n].deadlineOpen
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "stageWritten",
            ![n].stagedAdmission = admission,
            ![n].lastPrePublishAdmission = admission,
            ![n].lastPrePublishWasOpen = journal[n].deadlineOpen]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

ExactCompletionFenced(n, incarnation, admission, recordAdmission) ==
    /\ Fenced(n, incarnation)
    /\ journal[n].transitionOwner = incarnation
    /\ journal[n].activeAdmission = admission
    /\ journal[n].stagedAdmission = recordAdmission
    /\ admission = recordAdmission

LiveCompletionFenced(n, incarnation, admission, recordAdmission) ==
    /\ ExactCompletionFenced(n, incarnation, admission, recordAdmission)
    /\ journal[n].deadlineOpen

FsyncStage(n, incarnation, admission, recordAdmission) ==
    /\ admission \in Admissions
    /\ recordAdmission \in Admissions
    /\ LiveCompletionFenced(n, incarnation, admission, recordAdmission)
    /\ n \in continuityObservable
    /\ journal[n].phase = "stageWritten"
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "stageDurable",
            ![n].lastPrePublishAdmission = admission,
            ![n].lastPrePublishWasOpen = journal[n].deadlineOpen]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

\* A restarted actor takes ownership only of an already-fsynced exact stage.
ResumeDurableStage(n, incarnation) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ journal[n].phase = "stageDurable"
    /\ journal[n].transitionOwner = NoIncarnation
    /\ ~journal[n].deadlineOpen
    /\ semantic[n][n].epoch = journal[n].committedEpoch
    /\ semantic[n][n].sequence = journal[n].committedSequence
    /\ journal' = [journal EXCEPT ![n].transitionOwner = incarnation]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

\* Expiry before signing discards the unsigned plan.  Once exact staged bytes
\* exist, expiry keeps that record and ticket but closes the deadline; recovery
\* must explicitly install a fresh absolute deadline before any phase advances.
ExpireAdmission(n, incarnation, admission) ==
    /\ Fenced(n, incarnation)
    /\ admission \in Admissions
    /\ journal[n].phase # "idle"
    /\ journal[n].transitionOwner = incarnation
    /\ journal[n].activeAdmission = admission
    /\ journal[n].deadlineOpen
    /\ journal' =
          IF journal[n].phase = "staging"
          THEN
            [journal EXCEPT
              ![n] =
                [ClearTransition(@) EXCEPT
                  !.phase = "idle",
                  !.publicationWitness = FALSE,
                  !.transitionOwner = NoIncarnation]]
          ELSE [journal EXCEPT ![n].deadlineOpen = FALSE]
    /\ dnsWriteNode' = IF dnsWriteNode = n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady >>

RecoverAdmission(n, incarnation, admission) ==
    /\ Fenced(n, incarnation)
    /\ n \in continuityObservable
    /\ admission \in Admissions
    /\ journal[n].phase \in
          {"stageWritten", "stageDurable", "published", "commitWritten"}
    /\ journal[n].transitionOwner = incarnation
    /\ journal[n].activeAdmission = admission
    /\ journal[n].stagedAdmission = admission
    /\ ~journal[n].deadlineOpen
    /\ journal' = [journal EXCEPT ![n].deadlineOpen = TRUE]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

\* A delayed callback may target an older transition admission, or carry the
\* exact record from that older admission while naming the current ticket.  It
\* records a rejection witness but changes no journal phase or staged record.
RejectDelayedCompletion(
    n,
    incarnation,
    offeredAdmission,
    offeredRecordAdmission) ==
    /\ Fenced(n, incarnation)
    /\ offeredAdmission \in Admissions
    /\ offeredRecordAdmission \in Admissions
    /\ journal[n].phase # "idle"
    /\ journal[n].transitionOwner = incarnation
    /\ journal[n].activeAdmission \in Admissions
    /\ \/ offeredAdmission < journal[n].activeAdmission
       \/ /\ offeredAdmission = journal[n].activeAdmission
          /\ journal[n].phase # "staging"
          /\ journal[n].stagedAdmission \in Admissions
          /\ offeredRecordAdmission < journal[n].stagedAdmission
    /\ journal' =
          [journal EXCEPT
            ![n].lastRejectedAdmission = offeredAdmission,
            ![n].lastRejectedAgainstAdmission = journal[n].activeAdmission,
            ![n].lastRejectedRecordAdmission = offeredRecordAdmission,
            ![n].lastRejectedAgainstRecordAdmission =
                journal[n].stagedAdmission]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

PublishStaged(n, incarnation, admission, recordAdmission) ==
    /\ admission \in Admissions
    /\ recordAdmission \in Admissions
    /\ LiveCompletionFenced(n, incarnation, admission, recordAdmission)
    /\ n \in continuityObservable
    /\ journal[n].phase = "stageDurable"
    /\ activeOrders[n] = journal[n].stagedOrders
    /\ semantic' = [semantic EXCEPT ![n][n] = StagedRecord(n)]
    /\ pending' =
          [receiver \in Nodes |->
            IF receiver = n
            THEN pending[receiver]
            ELSE [pending[receiver] EXCEPT
                    ![n] =
                      [present |-> TRUE,
                       incarnation |-> journal[n].stagedIncarnation,
                       orders |-> journal[n].stagedOrders,
                       epoch |-> journal[n].stagedEpoch,
                       sequence |-> journal[n].stagedSequence,
                       kind |-> journal[n].stagedKind]]]
    /\ acknowledgements' =
          [emitter \in Nodes |->
            IF emitter = n
            THEN [peer \in Nodes |->
                   IF peer = n
                   THEN acknowledgements[emitter][peer]
                   ELSE [acknowledgements[emitter][peer] EXCEPT !.pending = TRUE]]
            ELSE acknowledgements[emitter]]
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "published",
            ![n].lastPrePublishAdmission = admission,
            ![n].lastPrePublishWasOpen = journal[n].deadlineOpen,
            ![n].publicationWitness = TRUE]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

WriteCommit(n, incarnation, admission, recordAdmission) ==
    /\ admission \in Admissions
    /\ recordAdmission \in Admissions
    /\ LiveCompletionFenced(n, incarnation, admission, recordAdmission)
    /\ n \in continuityObservable
    /\ journal[n].phase = "published"
    /\ journal[n].publicationWitness
    /\ journal' = [journal EXCEPT ![n].phase = "commitWritten"]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

FsyncCommit(n, incarnation, admission, recordAdmission) ==
    /\ admission \in Admissions
    /\ recordAdmission \in Admissions
    /\ LiveCompletionFenced(n, incarnation, admission, recordAdmission)
    /\ n \in continuityObservable
    /\ journal[n].phase = "commitWritten"
    /\ journal[n].publicationWitness
    /\ journal' =
          [journal EXCEPT
            ![n].phase = "idle",
            ![n].committedOrders = journal[n].stagedOrders,
            ![n].committedIncarnation = journal[n].stagedIncarnation,
            ![n].committedEpoch = journal[n].stagedEpoch,
            ![n].committedSequence = journal[n].stagedSequence,
            ![n].committedKind = journal[n].stagedKind,
            ![n].stagedIncarnation = NoIncarnation,
            ![n].stagedOrders = NoOrdersVersion,
            ![n].stagedEpoch = NoEpoch,
            ![n].stagedSequence = NoSequence,
            ![n].stagedKind = "none",
            ![n].activeAdmission = NoAdmission,
            ![n].stagedAdmission = NoAdmission,
            ![n].deadlineOpen = FALSE,
            ![n].publicationWitness = FALSE,
            ![n].transitionOwner = NoIncarnation]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

DeliverAndAcknowledge(receiver, emitter) ==
    /\ receiver \in LiveNodes
    /\ receiver # emitter
    /\ pending[receiver][emitter].present
    /\ pending[receiver][emitter].orders = activeOrders[receiver]
    /\ ImmediateSuccessor(pending[receiver][emitter], semantic[receiver][emitter])
    /\ semantic' =
          [semantic EXCEPT
            ![receiver][emitter] =
              [incarnation |-> pending[receiver][emitter].incarnation,
               orders |-> pending[receiver][emitter].orders,
               epoch |-> pending[receiver][emitter].epoch,
               sequence |-> pending[receiver][emitter].sequence,
               kind |-> pending[receiver][emitter].kind]]
    /\ pending' = [pending EXCEPT ![receiver][emitter] = EmptyPending]
    /\ acknowledgements' =
          [acknowledgements EXCEPT
            ![emitter][receiver] =
              [incarnation |-> pending[receiver][emitter].incarnation,
               orders |-> pending[receiver][emitter].orders,
               epoch |-> pending[receiver][emitter].epoch,
               sequence |-> pending[receiver][emitter].sequence,
               pending |-> FALSE]]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, journal, checkpoint,
                    continuityObservable, credentialReady, dnsWriteNode >>

DiscardUnusable(receiver, emitter) ==
    /\ receiver \in LiveNodes
    /\ receiver # emitter
    /\ pending[receiver][emitter].present
    /\ \/ pending[receiver][emitter].orders # activeOrders[receiver]
       \/ ~PositionNewer(pending[receiver][emitter], semantic[receiver][emitter])
    /\ pending' = [pending EXCEPT ![receiver][emitter] = EmptyPending]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady, dnsWriteNode >>

\* One signed checkpoint absorbs the unacknowledged prefix.  The retained
\* acknowledgement projection and one overwriteable peer slot remain fixed in
\* cardinality regardless of how long a peer is absent.
FoldCheckpoint(emitter, incarnation) ==
    /\ Fenced(emitter, incarnation)
    /\ emitter \in continuityObservable
    /\ journal[emitter].phase = "idle"
    /\ PositionNewer(CommittedRecord(emitter), checkpoint[emitter])
    /\ \E peer \in Nodes: acknowledgements[emitter][peer].pending
    /\ checkpoint' =
          [checkpoint EXCEPT ![emitter] = CommittedRecord(emitter)]
    /\ acknowledgements' =
          [acknowledgements EXCEPT
            ![emitter] =
              [peer \in Nodes |->
                [acknowledgements[emitter][peer] EXCEPT !.pending = FALSE]]]
    /\ pending' = ClearPendingForEmitter(emitter)
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, journal,
                    continuityObservable, credentialReady, dnsWriteNode >>

RepairFromCheckpoint(receiver, emitter) ==
    /\ receiver \in LiveNodes
    /\ receiver # emitter
    /\ checkpoint[emitter].orders = activeOrders[receiver]
    /\ PositionNewer(checkpoint[emitter], semantic[receiver][emitter])
    /\ semantic' = [semantic EXCEPT ![receiver][emitter] = checkpoint[emitter]]
    /\ pending' = [pending EXCEPT ![receiver][emitter] = EmptyPending]
    /\ acknowledgements' =
          [acknowledgements EXCEPT
            ![emitter][receiver] =
              [incarnation |-> checkpoint[emitter].incarnation,
               orders |-> checkpoint[emitter].orders,
               epoch |-> checkpoint[emitter].epoch,
               sequence |-> checkpoint[emitter].sequence,
               pending |-> FALSE]]
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, journal, checkpoint,
                    continuityObservable, credentialReady, dnsWriteNode >>

\* Credential and ranked-owner recomputation are one established-runtime gate
\* in this refinement.  Their independent loss/reorder cross-product was
\* exhaustively checked by Sprint 2.31; this action makes restart convergence
\* reachable without duplicating that older state space.
RestoreRuntimeGate(n) ==
    /\ n \in LiveNodes
    /\ \/ ownerView[n] # Leader
       \/ n \notin credentialReady
    /\ ownerView' = [ownerView EXCEPT ![n] = Leader]
    /\ credentialReady' = credentialReady \cup {n}
    /\ dnsWriteNode' =
          IF dnsWriteNode = n /\ Leader # n THEN NoNode ELSE dnsWriteNode
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable >>

DnsWrite(n) ==
    /\ CanWriteDns(n)
    /\ dnsWriteNode' = n
    /\ UNCHANGED << running, journalLockHolder, durableIncarnation, leaseHolder,
                    activeOrders, ownerView, semantic, pending, journal,
                    acknowledgements, checkpoint, continuityObservable,
                    credentialReady >>

Next ==
    \* The actor protocol is emitter-local, so Rank1 is the representative
    \* emitter and Rank2 is its independently fenced peer/acknowledger.  This
    \* avoids multiplying the same state machine by an interchangeable second
    \* copy while retaining a real directed peer boundary.
    \/ \E n \in {Rank1}, incarnation \in Incarnations:
          \/ StartActor(n, incarnation)
          \/ AcquireJournalLock(n, incarnation)
          \/ FsyncIncarnation(n, incarnation)
          \/ AcquireLease(n, incarnation)
          \/ ExpireLease(n, incarnation)
          \/ CrashActor(n, incarnation)
          \/ RecoverSemantic(n, incarnation)
          \/ ResumeDurableStage(n, incarnation)
          \/ FoldCheckpoint(n, incarnation)
          \/ BeginEpochCheckpoint(n, incarnation)
          \/ \E kind \in PublishKinds \ {"checkpoint"}:
                 BeginAssertion(n, incarnation, kind)
          \/ \E admission \in Admissions:
               \/ CompleteStage(n, incarnation, admission)
               \/ ExpireAdmission(n, incarnation, admission)
               \/ RecoverAdmission(n, incarnation, admission)
               \/ \E recordAdmission \in Admissions:
                    \/ FsyncStage(
                         n, incarnation, admission, recordAdmission)
                    \/ PublishStaged(
                         n, incarnation, admission, recordAdmission)
                    \/ WriteCommit(
                         n, incarnation, admission, recordAdmission)
                    \/ FsyncCommit(
                         n, incarnation, admission, recordAdmission)
                    \/ RejectDelayedCompletion(
                         n, incarnation, admission, recordAdmission)
    \/ \E n \in Nodes:
          \/ RestoreRuntimeGate(n)
          \/ DnsWrite(n)
    \/ \E receiver \in Nodes, emitter \in {Rank1}:
          \/ DeliverAndAcknowledge(receiver, emitter)
          \/ DiscardUnusable(receiver, emitter)
          \/ RepairFromCheckpoint(receiver, emitter)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ running \in [Nodes -> SUBSET Incarnations]
    /\ journalLockHolder \in [Nodes -> IncarnationOrNone]
    /\ durableIncarnation \in [Nodes -> Incarnations]
    /\ leaseHolder \in [Nodes -> IncarnationOrNone]
    /\ activeOrders \in [Nodes -> OrdersVersions]
    /\ ownerView \in [Nodes -> NodeOrNone]
    /\ semantic \in [Nodes -> [Nodes -> SemanticRecords]]
    /\ pending \in [Nodes -> [Nodes -> PendingRecords]]
    /\ journal \in [Nodes -> JournalRecords]
    /\ acknowledgements \in [Nodes -> [Nodes -> AckRecords]]
    /\ checkpoint \in [Nodes -> CheckpointRecords]
    /\ continuityObservable \subseteq Nodes
    /\ credentialReady \subseteq Nodes
    /\ dnsWriteNode \in NodeOrNone

LeaseBindsDurableIncarnation ==
    \A n \in Nodes:
      /\ journalLockHolder[n] # NoIncarnation =>
           /\ journalLockHolder[n] \in running[n]
           /\ journalLockHolder[n] >= durableIncarnation[n]
      /\ leaseHolder[n] # NoIncarnation =>
           /\ leaseHolder[n] = journalLockHolder[n]
           /\ leaseHolder[n] = durableIncarnation[n]
           /\ leaseHolder[n] \in running[n]

SingleWriterActorIsFenced ==
    \A n \in Nodes:
      /\ Cardinality(
           {incarnation \in Incarnations:
              journal[n].transitionOwner = incarnation}) <= 1
      /\ journal[n].transitionOwner # NoIncarnation =>
           Fenced(n, journal[n].transitionOwner)

JournalProtocolShape ==
    \A n \in Nodes:
      \/ /\ journal[n].phase = "idle"
         /\ journal[n].stagedIncarnation = NoIncarnation
         /\ journal[n].stagedOrders = NoOrdersVersion
         /\ journal[n].stagedEpoch = NoEpoch
         /\ journal[n].stagedSequence = NoSequence
         /\ journal[n].stagedKind = "none"
         /\ ~journal[n].publicationWitness
         /\ journal[n].transitionOwner = NoIncarnation
      \/ /\ journal[n].phase = "staging"
         /\ journal[n].stagedIncarnation \in Incarnations
         /\ journal[n].stagedOrders \in OrdersVersions
         /\ journal[n].stagedEpoch \in Epochs
         /\ journal[n].stagedSequence \in Sequences
         /\ journal[n].stagedKind \in PublishKinds
         /\ ~journal[n].publicationWitness
         /\ journal[n].transitionOwner \in Incarnations
      \/ /\ journal[n].phase = "stageWritten"
         /\ journal[n].stagedIncarnation \in Incarnations
         /\ journal[n].stagedOrders \in OrdersVersions
         /\ journal[n].stagedEpoch \in Epochs
         /\ journal[n].stagedSequence \in Sequences
         /\ journal[n].stagedKind \in PublishKinds
         /\ ~journal[n].publicationWitness
         /\ journal[n].transitionOwner \in Incarnations
      \/ /\ journal[n].phase = "stageDurable"
         /\ journal[n].stagedIncarnation \in Incarnations
         /\ journal[n].stagedOrders \in OrdersVersions
         /\ journal[n].stagedEpoch \in Epochs
         /\ journal[n].stagedSequence \in Sequences
         /\ journal[n].stagedKind \in PublishKinds
         /\ ~journal[n].publicationWitness
      \/ /\ journal[n].phase \in {"published", "commitWritten"}
         /\ journal[n].stagedIncarnation \in Incarnations
         /\ journal[n].stagedOrders \in OrdersVersions
         /\ journal[n].stagedEpoch \in Epochs
         /\ journal[n].stagedSequence \in Sequences
         /\ journal[n].stagedKind \in PublishKinds
         /\ journal[n].publicationWitness
         /\ journal[n].transitionOwner \in Incarnations

AdmissionIdentityFencesCompletions ==
    \A n \in Nodes:
      /\ (journal[n].activeAdmission # NoAdmission =>
            journal[n].nextAdmission =
              NextAdmission(journal[n].activeAdmission))
      /\ \/ /\ journal[n].phase = "idle"
             /\ journal[n].activeAdmission = NoAdmission
             /\ journal[n].stagedAdmission = NoAdmission
             /\ ~journal[n].deadlineOpen
          \/ /\ journal[n].phase = "staging"
             /\ journal[n].activeAdmission \in Admissions
             /\ journal[n].stagedAdmission = NoAdmission
             /\ journal[n].deadlineOpen
          \/ /\ journal[n].phase \in
                   {"stageWritten", "stageDurable", "published",
                    "commitWritten"}
             /\ journal[n].activeAdmission \in Admissions
             /\ journal[n].stagedAdmission = journal[n].activeAdmission

DelayedCompletionIsRejectedByIdentity ==
    \A n \in Nodes:
      \/ /\ journal[n].lastRejectedAdmission = NoAdmission
         /\ journal[n].lastRejectedAgainstAdmission = NoAdmission
         /\ journal[n].lastRejectedRecordAdmission = NoAdmission
         /\ journal[n].lastRejectedAgainstRecordAdmission = NoAdmission
      \/ /\ journal[n].lastRejectedAdmission \in Admissions
         /\ journal[n].lastRejectedAgainstAdmission \in Admissions
         /\ journal[n].lastRejectedRecordAdmission \in Admissions
         /\ journal[n].lastRejectedAgainstRecordAdmission \in AdmissionOrNone
         /\ \/ journal[n].lastRejectedAdmission <
                  journal[n].lastRejectedAgainstAdmission
            \/ /\ journal[n].lastRejectedAdmission =
                     journal[n].lastRejectedAgainstAdmission
               /\ journal[n].lastRejectedAgainstRecordAdmission \in Admissions
               /\ journal[n].lastRejectedRecordAdmission <
                     journal[n].lastRejectedAgainstRecordAdmission

NoDeadAdmissionAdvancedPrePublish ==
    \A n \in Nodes:
      /\ journal[n].lastPrePublishWasOpen
      /\ \/ journal[n].lastPrePublishAdmission = NoAdmission
         \/ /\ journal[n].lastPrePublishAdmission \in Admissions
            /\ \/ journal[n].nextAdmission = NoAdmission
               \/ journal[n].lastPrePublishAdmission <
                    journal[n].nextAdmission

StagedTransitionIsNonWrapping ==
    \A n \in Nodes:
      journal[n].phase # "idle" =>
        /\ journal[n].stagedIncarnation >= journal[n].committedIncarnation
        /\ journal[n].stagedIncarnation <= durableIncarnation[n]
        /\ ( \/ /\ journal[n].stagedEpoch = journal[n].committedEpoch
                 /\ journal[n].committedSequence < MaxSequence
                 /\ journal[n].stagedSequence = journal[n].committedSequence + 1
                 /\ journal[n].stagedKind # "checkpoint"
             \/ /\ journal[n].committedEpoch < MaxEpoch
                 /\ journal[n].committedSequence = MaxSequence
                 /\ journal[n].stagedEpoch = journal[n].committedEpoch + 1
                 /\ journal[n].stagedSequence = 0
                 /\ journal[n].stagedKind = "checkpoint" )

SemanticIsOrdersScoped ==
    \A viewer \in Nodes, emitter \in Nodes:
      semantic[viewer][emitter].orders # NoOrdersVersion =>
        semantic[viewer][emitter].orders = activeOrders[viewer]

IncarnationFenceIsMonotonic ==
    \A emitter \in Nodes:
      /\ journal[emitter].committedIncarnation <= durableIncarnation[emitter]
      /\ \A viewer \in Nodes:
           /\ semantic[viewer][emitter].incarnation <= durableIncarnation[emitter]
           /\ pending[viewer][emitter].incarnation <= durableIncarnation[emitter]
           /\ acknowledgements[emitter][viewer].incarnation <=
                durableIncarnation[emitter]
      /\ checkpoint[emitter].incarnation <=
           journal[emitter].committedIncarnation

NoSemanticAheadOfDurableJournal ==
    \A viewer \in Nodes, emitter \in Nodes:
      ~PositionNewer(semantic[viewer][emitter], DurableRecord(emitter))

PendingSlotsAreBoundedAndDurable ==
    \A receiver \in Nodes, emitter \in Nodes:
      \/ /\ ~pending[receiver][emitter].present
         /\ pending[receiver][emitter] = EmptyPending
      \/ /\ pending[receiver][emitter].present
         /\ pending[receiver][emitter].orders \in OrdersVersions
         /\ pending[receiver][emitter].kind \in PublishKinds
         /\ ~PositionNewer(pending[receiver][emitter], DurableRecord(emitter))

AcknowledgementsAreBoundedAndDurable ==
    \A emitter \in Nodes, peer \in Nodes:
      ~PositionNewer(acknowledgements[emitter][peer], DurableRecord(emitter))

CheckpointIsCommittedAndBounded ==
    \A emitter \in Nodes:
      ~PositionNewer(checkpoint[emitter], CommittedRecord(emitter))

DnsLeaseRequiresCompleteGate ==
    dnsWriteNode # NoNode => CanWriteDns(dnsWriteNode)

FullyStable ==
    /\ LiveNodes # {}
    /\ \A n \in LiveNodes: ownerView[n] = Leader

NoSimultaneousDNSWriters ==
    FullyStable => Cardinality({n \in Nodes: CanWriteDns(n)}) <= 1

THEOREM Spec => []TypeOK
THEOREM Spec => []LeaseBindsDurableIncarnation
THEOREM Spec => []SingleWriterActorIsFenced
THEOREM Spec => []JournalProtocolShape
THEOREM Spec => []AdmissionIdentityFencesCompletions
THEOREM Spec => []DelayedCompletionIsRejectedByIdentity
THEOREM Spec => []NoDeadAdmissionAdvancedPrePublish
THEOREM Spec => []StagedTransitionIsNonWrapping
THEOREM Spec => []SemanticIsOrdersScoped
THEOREM Spec => []IncarnationFenceIsMonotonic
THEOREM Spec => []NoSemanticAheadOfDurableJournal
THEOREM Spec => []PendingSlotsAreBoundedAndDurable
THEOREM Spec => []AcknowledgementsAreBoundedAndDurable
THEOREM Spec => []CheckpointIsCommittedAndBounded
THEOREM Spec => []DnsLeaseRequiresCompleteGate
THEOREM Spec => []NoSimultaneousDNSWriters

=============================================================================
