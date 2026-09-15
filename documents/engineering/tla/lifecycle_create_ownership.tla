---- MODULE lifecycle_create_ownership ----
\* Sprint 5.48: the one invariant a type system provably cannot hold.
\*
\* Thirty-four sprints applied a type-level device to cleanup, absence and
\* residue.  Each makes a value unconstructible and each claim is true; none
\* makes an outcome in a cloud account unconstructible, because a leak is not a
\* value.  It is a property of an ordering across processes and crashes: which
\* durable writes happened before the effect that created a resource, and what
\* survives a process that dies between them.  That is a protocol property, and
\* a model checker is the instrument for it.
\*
\* The safety form is checked, not the liveness form.  "The resource is
\* eventually absent in AWS" is a claim about the world that does not belong
\* inside a model property any more than inside a type, and liveness over a
\* reconciler with no fairness assumption yields a stuttering counterexample
\* that proves nothing.  What is checked is:
\*
\*     there is no reachable state in which a provider effect has landed and no
\*     durable record names the coordinates it created.
\*
\* WriteAheadEnabled is the switch that makes the model able to fail.  With it
\* FALSE the module is the 2026-09-08 revision: a generation record names the
\* cycle, nothing names the resources, and TLC finds the trace in which a
\* transport deadline cancels the reply after the effect has landed.  With it
\* TRUE the module is the protocol Sprint `7.41` schedules, and the invariant
\* holds.  Both configurations are registered, and the check refuses if the
\* broken one passes.

EXTENDS Integers, FiniteSets

CONSTANTS
    Coordinates,
    Cycles,
    NoCycle,
    WriteAheadEnabled

ASSUME /\ Coordinates # {}
       /\ Cycles # {}
       /\ NoCycle \notin Cycles
       /\ WriteAheadEnabled \in BOOLEAN

CycleOrNone == Cycles \cup {NoCycle}

\* The states a create passes through.  `dispatched` is the window the leak
\* lives in: the provider has been asked, and the host does not yet know what
\* it did.
Phases ==
    { "idle",
      "admitted",
      "generationCommitted",
      "manifestCommitted",
      "manifestReadBack",
      "dispatched",
      "landed",
      "appended",
      "settled" }

ManifestRecords ==
    [present: BOOLEAN,
     readBack: BOOLEAN,
     cycle: CycleOrNone,
     declared: SUBSET Coordinates,
     appended: SUBSET Coordinates]

EmptyManifest ==
    [present |-> FALSE,
     readBack |-> FALSE,
     cycle |-> NoCycle,
     declared |-> {},
     appended |-> {}]

VARIABLES
    phase,
    \* The cycle the in-flight create belongs to.  Held in the process, so a
    \* crash loses it.
    runningCycle,
    \* The scratch the host holds between dispatching the effect and committing
    \* what it learned.  This is the RAM the 2026-09-08 checkpoint lived in.
    scratchCoordinates,
    \* Durable: the generation record.  It names a cycle and never a resource,
    \* which is the whole of the 2026-09-08 finding.
    durableGeneration,
    \* Durable: one write-ahead ownership manifest per cycle.  A slot per cycle
    \* rather than one slot, because a manifest is committed at the submission
    \* key and a later create must not erase an earlier one's record -- which
    \* the first draft of this model did, and TLC found it in eleven steps.
    durableManifests,
    \* The provider's own database.  This repository does not own it and cannot
    \* make a value in it unconstructible; it can only order its own writes
    \* around the effect that changes it.
    providerResources,
    \* Cycles whose create has already been attempted, so the state space is
    \* finite without a counter.
    consumedCycles

vars ==
    << phase,
       runningCycle,
       scratchCoordinates,
       durableGeneration,
       durableManifests,
       providerResources,
       consumedCycles >>

Init ==
    /\ phase = "idle"
    /\ runningCycle = NoCycle
    /\ scratchCoordinates = {}
    /\ durableGeneration = NoCycle
    /\ durableManifests = [cycle \in Cycles |-> EmptyManifest]
    /\ providerResources = {}
    /\ consumedCycles = {}

\* The Authority admits a create and allocates the cycle it belongs to.
Admit(cycle) ==
    /\ phase = "idle"
    /\ cycle \in Cycles
    /\ cycle \notin consumedCycles
    /\ phase' = "admitted"
    /\ runningCycle' = cycle
    /\ consumedCycles' = consumedCycles \cup {cycle}
    /\ UNCHANGED << scratchCoordinates, durableGeneration, durableManifests,
                    providerResources >>

\* The generation record commits.  It is addressable and it names no resource.
CommitGeneration ==
    /\ phase = "admitted"
    /\ runningCycle \in Cycles
    /\ durableGeneration' = runningCycle
    /\ phase' = "generationCommitted"
    /\ UNCHANGED << runningCycle, scratchCoordinates, durableManifests,
                    providerResources, consumedCycles >>

\* The write-ahead ownership manifest commits, naming every coordinate the
\* effect may create.  Sprint `7.41`'s first deliverable.
CommitWriteAheadManifest(declared) ==
    /\ WriteAheadEnabled
    /\ phase = "generationCommitted"
    /\ runningCycle \in Cycles
    /\ declared \in SUBSET Coordinates
    /\ declared # {}
    /\ durableManifests' =
          [durableManifests EXCEPT
            ![runningCycle] =
              [present |-> TRUE,
               readBack |-> FALSE,
               cycle |-> runningCycle,
               declared |-> declared,
               appended |-> {}]]
    /\ phase' = "manifestCommitted"
    /\ UNCHANGED << runningCycle, scratchCoordinates, durableGeneration,
                    providerResources, consumedCycles >>

\* The independent read-back before the effect.  A commit whose read-back never
\* happens is not authority, so the execute step consumes the witness this
\* action mints and not the commit.
ReadBackManifest ==
    /\ WriteAheadEnabled
    /\ phase = "manifestCommitted"
    /\ runningCycle \in Cycles
    /\ durableManifests[runningCycle].present
    /\ durableManifests[runningCycle].cycle = runningCycle
    /\ durableManifests' =
          [durableManifests EXCEPT ![runningCycle].readBack = TRUE]
    /\ phase' = "manifestReadBack"
    /\ UNCHANGED << runningCycle, scratchCoordinates, durableGeneration,
                    providerResources, consumedCycles >>

\* The step the whole model exists to order: the host asks the provider.  From
\* here until the return route, the provider may have created anything the
\* request authorized and the host knows nothing.
DispatchEffect ==
    /\ \/ /\ WriteAheadEnabled
          /\ phase = "manifestReadBack"
          /\ runningCycle \in Cycles
          /\ durableManifests[runningCycle].readBack
       \/ /\ ~WriteAheadEnabled
          /\ phase = "generationCommitted"
    /\ phase' = "dispatched"
    /\ UNCHANGED << runningCycle, scratchCoordinates, durableGeneration,
                    durableManifests, providerResources, consumedCycles >>

\* The provider creates a non-empty subset of what the request authorized.  A
\* partial create is the ordinary case, not the exotic one: the 2026-09-08
\* cluster existed while its own create was still running.
LandEffect(created) ==
    /\ phase = "dispatched"
    /\ created \in SUBSET Coordinates
    /\ created # {}
    /\ WriteAheadEnabled =>
          /\ runningCycle \in Cycles
          /\ created \subseteq durableManifests[runningCycle].declared
    /\ providerResources' = providerResources \cup created
    /\ scratchCoordinates' = created
    /\ phase' = "landed"
    /\ UNCHANGED << runningCycle, durableGeneration, durableManifests,
                    consumedCycles >>

\* The append the host performs on the return route, giving the manifest the
\* exact identities the provider returned.  It may only add coordinates the
\* write-ahead already declared: an append is a narrowing, never a new claim.
AppendIdentities ==
    /\ WriteAheadEnabled
    /\ phase = "landed"
    /\ runningCycle \in Cycles
    /\ durableManifests[runningCycle].present
    /\ scratchCoordinates \subseteq durableManifests[runningCycle].declared
    /\ durableManifests' =
          [durableManifests EXCEPT
            ![runningCycle].appended = @ \cup scratchCoordinates]
    /\ phase' = "appended"
    /\ UNCHANGED << runningCycle, scratchCoordinates, durableGeneration,
                    providerResources, consumedCycles >>

Settle ==
    /\ \/ /\ WriteAheadEnabled
          /\ phase = "appended"
       \/ /\ ~WriteAheadEnabled
          /\ phase = "landed"
    /\ phase' = "settled"
    /\ scratchCoordinates' = {}
    /\ runningCycle' = NoCycle
    /\ UNCHANGED << durableGeneration, durableManifests, providerResources,
                    consumedCycles >>

\* The transport deadline cancels the reply.  Every durable write already made
\* survives; the scratch does not, and neither does the knowledge of what the
\* provider did.  This is the exact 2026-09-08 shape and it is deliberately
\* enabled from `dispatched` onward.
CancelReply ==
    /\ phase \in { "dispatched", "landed", "appended" }
    /\ phase' = "idle"
    /\ runningCycle' = NoCycle
    /\ scratchCoordinates' = {}
    /\ UNCHANGED << durableGeneration, durableManifests, providerResources,
                    consumedCycles >>

\* The host process dies.  Indistinguishable from a cancelled reply as far as
\* durability is concerned, and separate because a crash may also happen before
\* the effect is dispatched.
Crash ==
    /\ phase # "idle"
    /\ phase' = "idle"
    /\ runningCycle' = NoCycle
    /\ scratchCoordinates' = {}
    /\ UNCHANGED << durableGeneration, durableManifests, providerResources,
                    consumedCycles >>

\* A later teardown destroys exactly what a durable record names.  It cannot
\* destroy what nothing names, which is why the invariant is about naming and
\* not about absence.
Reconcile ==
    /\ phase = "idle"
    /\ providerResources # {}
    /\ providerResources' =
          providerResources \ UNION { durableManifests[cycle].declared
                                     : cycle \in { c \in Cycles
                                                  : durableManifests[c].present } }
    /\ UNCHANGED << phase, runningCycle, scratchCoordinates, durableGeneration,
                    durableManifests, consumedCycles >>

Next ==
    \/ \E cycle \in Cycles: Admit(cycle)
    \/ CommitGeneration
    \/ \E declared \in SUBSET Coordinates: CommitWriteAheadManifest(declared)
    \/ ReadBackManifest
    \/ DispatchEffect
    \/ \E created \in SUBSET Coordinates: LandEffect(created)
    \/ AppendIdentities
    \/ Settle
    \/ CancelReply
    \/ Crash
    \/ Reconcile

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in Phases
    /\ runningCycle \in CycleOrNone
    /\ scratchCoordinates \in SUBSET Coordinates
    /\ durableGeneration \in CycleOrNone
    /\ durableManifests \in [Cycles -> ManifestRecords]
    /\ providerResources \in SUBSET Coordinates
    /\ consumedCycles \in SUBSET Cycles

\* THE INVARIANT.  Every coordinate that exists in the provider is named by a
\* durable record, so a later run can reach it.  Nothing here claims the
\* resource is absent, or will become absent; absence is a fact about someone
\* else's database and this model does not assert one.
EveryProviderResourceIsDurablyNamed ==
    \A resource \in providerResources:
      \E cycle \in Cycles:
        /\ durableManifests[cycle].present
        /\ resource \in durableManifests[cycle].declared

\* The generation record is addressable and says nothing about resources.
\* Stated as an invariant rather than as prose because it is the precise sense
\* in which the 2026-09-08 cycle "was addressable" while its cluster was not.
GenerationNamesACycleAndNeverAResource ==
    durableGeneration \in CycleOrNone

\* An effect may not be dispatched until the manifest that declares its
\* coordinates has been committed and independently read back.
DispatchFollowsReadBackWriteAhead ==
    WriteAheadEnabled =>
      ( phase \in { "dispatched", "landed", "appended" } =>
          /\ runningCycle \in Cycles
          /\ durableManifests[runningCycle].present
          /\ durableManifests[runningCycle].readBack )

\* An append narrows to what was declared; it never widens the claim.
AppendedIdentitiesAreDeclared ==
    \A cycle \in Cycles:
      durableManifests[cycle].appended \subseteq durableManifests[cycle].declared

\* Scratch is never authority.  A coordinate held only in the process is not a
\* record, which is the property the retired checkpoint interpreter violated.
ScratchIsNeverTheOnlyRecord ==
    WriteAheadEnabled =>
      \A resource \in scratchCoordinates:
        \E cycle \in Cycles:
          /\ durableManifests[cycle].present
          /\ resource \in durableManifests[cycle].declared

====
