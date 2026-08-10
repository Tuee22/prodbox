{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Generic effectful interpreter for the bounded cross-authority target
-- protocol.  It treats every mutation result as provisional and closes each
-- step only through a fresh authoritative observation.  The target CAS is
-- invoked at most once in one run.
module Prodbox.Lifecycle.TargetCommitInterpreter
  ( GlobalLedgerStep (..)
  , TargetCommitInterpreter (..)
  , TargetCommitInterpreterError (..)
  , TargetCommitRun (..)
  , TargetRecoveryInterpreter (..)
  , TargetRecoveryRun (..)
  , runPreparedTargetCommit
  , runSuccessorTargetRecovery
  , runSuccessorTargetRecoveryAfter
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasResult (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , TargetClusterSecretSink
  , targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , FencedCommitPermit
  , LeaseGrant
  , LeasePolicy
  , leasePolicyProviderVisibilityGrace
  , leasePolicyStableObservationCount
  , successorNotBefore
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , RegisteredTargetSet
  , TargetCommitCompleteDecision (..)
  , TargetCommitDisposition (..)
  , TargetCommitIntent
  , TargetCommitPrepareDecision (..)
  , TargetCommitRefusal (..)
  , TargetIntentCompactDecision (..)
  , TargetIntentCoordinate
  , TargetIntentProjection
  , TargetProjectionEntry
  , TargetRecoveryDecision (..)
  , TargetSinkCasAdapter (..)
  , TargetSinkCasResult (..)
  , TargetSinkReadbackRefusal
  , TargetSinkWriteDecision (..)
  , TargetValueDigest
  , TimedTargetSinkObservation (..)
  , compactTargetIntent
  , confirmTargetSinkReadback
  , decideCompleteTargetCommit
  , decidePrepareTargetCommit
  , decideResolveOutstandingTargets
  , decideTargetSinkWrite
  , prepareTargetWrite
  , proveStableTargetReadbackAfter
  , registeredTargetByIdentity
  , registeredTargetCapacity
  , targetCommitDigest
  , targetCommitDisposition
  , targetCommitFencingToken
  , targetCommitGeneration
  , targetCommitOwnerNonce
  , targetCommitTargetIdentity
  , targetIntentCoordinateObject
  , targetProjectionEntries
  , targetProjectionEntryIntent
  , targetProjectionEntryTargetIdentity
  )

data TargetCommitInterpreter m payload = TargetCommitInterpreter
  { targetCommitGlobalAdapter :: !(ModelBCasAdapter 'ClusterRetained m TargetIntentProjection)
  , targetCommitSinkAdapter :: !(TargetSinkCasAdapter m payload)
  , targetCommitCurrentPermit :: !(m (Either Text FencedCommitPermit))
  , targetCommitCurrentAuthorityTime :: !(m (Either Text AuthorityTime))
  , targetCommitDigestPayload :: !(payload -> TargetValueDigest)
  }

-- | Which write against the global target-intent ledger a refusal came from.
--
-- Sprint 4.63. The same @ModelBCasRefusedCorrupt@ text means four different
-- things depending on which ledger step produced it, and the constructor is the
-- only place that distinction can survive: every one of the four call sites
-- previously discarded the verdict, so the operator saw a message re-derived
-- from the /next/ observation instead of the one the store gave.
data GlobalLedgerStep
  = GlobalLedgerPrepare
  | GlobalLedgerComplete
  | GlobalLedgerCompaction
  | GlobalLedgerRecoveryResolve
  deriving (Eq, Show)

data TargetCommitInterpreterError
  = TargetCommitPermitUnavailable !Text
  | TargetCommitAuthorityClockUnavailable !Text
  | TargetCommitPrepareFailed !TargetCommitRefusal
  | TargetCommitPrepareNotConfirmed !TargetCommitRefusal
  | TargetCommitSinkWriteFailed !TargetSinkReadbackRefusal
  | -- | Sprint 4.62: the target sink store answered @TargetSinkCasRefused@ — it
    -- explicitly did not write, and said why. Distinct from
    -- 'TargetCommitSinkReadbackFailed', which is what the sink looks like
    -- afterwards; this is what the sink said at the time.
    TargetCommitSinkCasRefused !Text
  | -- | Sprint 4.63: the __global__ target-intent ledger answered
    -- @ModelBCasRefusedCorrupt@ — it performed no write, and said why. Carries
    -- the ledger step that was refused, because the same refusal at prepare,
    -- complete, compaction, and recovery-resolve means four different things to
    -- an operator and the constructor is the only place that distinction can
    -- survive.
    TargetCommitGlobalCasRefused !GlobalLedgerStep !Text
  | TargetCommitSinkReadbackFailed !TargetSinkReadbackRefusal
  | TargetCommitCompleteFailed !TargetCommitRefusal
  | TargetCommitCompleteNotConfirmed !Text
  | TargetCommitCompactionFailed !TargetCommitRefusal
  | TargetCommitCompactionNotConfirmed !Text
  | TargetCommitCompactionOverBound !Int
  | TargetCommitRecoveryReadbackFailed !Text !TargetSinkReadbackRefusal
  | TargetCommitRecoveryWaitFailed !Text
  | TargetCommitRecoveryFailed !TargetCommitRefusal
  | TargetCommitRecoveryNotConfirmed ![Text]
  deriving (Eq, Show)

-- | Decide one global-ledger CAS answer, totally.
--
-- Sprint 4.63. Four of the five arms continue to the authoritative
-- re-observation the caller already performs, and that re-observation is
-- deliberately __retained rather than replaced__: it is what resolves an
-- applied-but-response-lost write, and 'ModelBCasUnobservable' is exactly that
-- case. Routing it to a refusal would reintroduce the \"unobservable is not
-- absent\" defect Sprints @4.53@, @4.62@, and @5.29@ closed elsewhere.
--
-- 'ModelBCasRefusedCorrupt' is different in kind and is the only arm that
-- refuses here. Every producer of it in this repository refuses /before/
-- reaching the object store — an encode failure, a non-registered coordinate, an
-- unsupported guarded arm, or an Authority projection refusal — so it is the one
-- answer that states no write was performed. A read-back cannot recover that
-- fact, because a read-back reports what the object looks like afterwards and
-- not what the store said at the time.
--
-- Being total is the point: a sixth 'ModelBCasResult' constructor is a
-- @-Werror@ compile error here rather than a silent fifth thing that is also
-- ignored.
globalLedgerCasRefusal
  :: GlobalLedgerStep
  -> ModelBCasResult value
  -> Maybe TargetCommitInterpreterError
globalLedgerCasRefusal step result = case result of
  ModelBCasApplied _ _ -> Nothing
  ModelBCasConflict _ -> Nothing
  ModelBCasEndpointUnready _ -> Nothing
  ModelBCasUnobservable _ -> Nothing
  ModelBCasRefusedCorrupt detail -> Just (TargetCommitGlobalCasRefused step detail)

data TargetCommitRun
  = TargetCommitRunAlreadyCommitted !Text !CredentialGeneration
  | TargetCommitRunCommitted
      { targetCommitRunTargetIdentity :: !Text
      , targetCommitRunGeneration :: !CredentialGeneration
      , targetCommitRunSinkCasAttempted :: !Bool
      }
  deriving (Eq, Show)

runPreparedTargetCommit
  :: (Monad m)
  => TargetCommitInterpreter m payload
  -> RegisteredTargetSet
  -> TargetIntentCoordinate
  -> TargetClusterSecretSink
  -> CredentialGeneration
  -> TargetValueDigest
  -> AuthorityTime
  -> payload
  -> m (Either TargetCommitInterpreterError TargetCommitRun)
runPreparedTargetCommit interpreter registered coordinate sink generation digest deadline payload = do
  compacted <- compactAllTerminalIntents interpreter registered coordinate
  case compacted of
    Left err -> pure (Left err)
    Right () -> do
      initialPermit <- targetCommitCurrentPermit interpreter
      case initialPermit of
        Left detail -> pure (Left (TargetCommitPermitUnavailable detail))
        Right permit -> do
          nowResult <- targetCommitCurrentAuthorityTime interpreter
          case nowResult of
            Left detail -> pure (Left (TargetCommitAuthorityClockUnavailable detail))
            Right now -> do
              initial <- modelBObserve (targetCommitGlobalAdapter interpreter) (coordinateObject coordinate)
              case decidePrepareTargetCommit registered coordinate now deadline permit sink generation digest initial of
                TargetCommitPrepareRefused refusal ->
                  pure (Left (TargetCommitPrepareFailed refusal))
                TargetCommitPrepareAlreadyCommitted _ ->
                  pure
                    ( Right
                        ( TargetCommitRunAlreadyCommitted
                            (targetSecretSinkIdentity sink)
                            generation
                        )
                    )
                TargetCommitPrepareCompareAndSwap request intent -> do
                  verdict <- modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
                  case globalLedgerCasRefusal GlobalLedgerPrepare verdict of
                    Just refusal -> pure (Left refusal)
                    Nothing -> runPrepared intent
 where
  runPrepared intent = do
    currentPermit <- targetCommitCurrentPermit interpreter
    case currentPermit of
      Left detail -> pure (Left (TargetCommitPermitUnavailable detail))
      Right permit -> do
        nowResult <- targetCommitCurrentAuthorityTime interpreter
        case nowResult of
          Left detail -> pure (Left (TargetCommitAuthorityClockUnavailable detail))
          Right now -> do
            preparedObservation <-
              modelBObserve (targetCommitGlobalAdapter interpreter) (coordinateObject coordinate)
            case prepareTargetWrite registered now permit sink intent preparedObservation of
              Left refusal -> pure (Left (TargetCommitPrepareNotConfirmed refusal))
              Right writePermit -> do
                sinkObservation <- targetSinkObserve (targetCommitSinkAdapter interpreter) sink
                case decideTargetSinkWrite
                  (targetCommitDigestPayload interpreter)
                  writePermit
                  payload
                  sinkObservation of
                  TargetSinkWriteRefused refusal ->
                    pure (Left (TargetCommitSinkWriteFailed refusal))
                  TargetSinkWriteAlreadyApplied -> completeAfterReadback intent False writePermit
                  TargetSinkWriteCompareAndSwap request -> do
                    -- Sprint 4.62: the store's answer was bound to `_`, so
                    -- correctness rested entirely on the read-back that follows.
                    -- The four arms are not interchangeable and are decided
                    -- separately rather than folded into "read back and see".
                    verdict <- targetSinkCompareAndSwap (targetCommitSinkAdapter interpreter) request
                    case verdict of
                      -- The store said it did not write, and why. A read-back
                      -- cannot convert that into a success: if the expected bytes
                      -- are present they are someone else's write, and this
                      -- commit did not perform it.
                      TargetSinkCasRefused detail ->
                        pure (Left (TargetCommitSinkCasRefused detail))
                      -- Applied, superseded, or unknown: all three are resolved
                      -- by the authoritative read-back, which is exactly what it
                      -- exists for. `Unobservable` is the applied-but-response-
                      -- lost case and must NOT be read as absence.
                      TargetSinkCasApplied _ _ -> completeAfterReadback intent True writePermit
                      TargetSinkCasConflict _ -> completeAfterReadback intent True writePermit
                      TargetSinkCasUnobservable _ -> completeAfterReadback intent True writePermit

  completeAfterReadback intent sinkCasAttempted writePermit = do
    readbackObservation <- targetSinkObserve (targetCommitSinkAdapter interpreter) sink
    case confirmTargetSinkReadback
      (targetCommitDigestPayload interpreter)
      writePermit
      readbackObservation of
      Left refusal -> pure (Left (TargetCommitSinkReadbackFailed refusal))
      Right readback -> do
        finalPermit <- targetCommitCurrentPermit interpreter
        case finalPermit of
          Left detail -> pure (Left (TargetCommitPermitUnavailable detail))
          Right permit -> do
            nowResult <- targetCommitCurrentAuthorityTime interpreter
            case nowResult of
              Left detail -> pure (Left (TargetCommitAuthorityClockUnavailable detail))
              Right now -> do
                global <-
                  modelBObserve (targetCommitGlobalAdapter interpreter) (coordinateObject coordinate)
                case decideCompleteTargetCommit registered coordinate now permit readback global of
                  TargetCommitCompleteRefused refusal ->
                    pure (Left (TargetCommitCompleteFailed refusal))
                  TargetCommitCompleteAlreadyApplied ->
                    compactThenReturn sinkCasAttempted
                  TargetCommitCompleteCompareAndSwap request -> do
                    verdict <- modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
                    -- Sprint 4.63: this arm is the one where discarding the
                    -- verdict could turn a refusal into a success. A refused
                    -- completion followed by a read-back that happens to show
                    -- the intent committed — reachable when a same-fence
                    -- attempt committed it — used to return `Committed` for a
                    -- write this run did not perform.
                    case globalLedgerCasRefusal GlobalLedgerComplete verdict of
                      Just refusal -> pure (Left refusal)
                      Nothing -> do
                        confirmed <-
                          modelBObserve (targetCommitGlobalAdapter interpreter) (coordinateObject coordinate)
                        case confirmed of
                          ModelBObserved _ projection
                            | projectionHasCommittedIntent intent projection ->
                                compactThenReturn sinkCasAttempted
                          _ ->
                            pure
                              ( Left
                                  ( TargetCommitCompleteNotConfirmed
                                      (targetCommitTargetIdentity intent)
                                  )
                              )

  compactThenReturn sinkCasAttempted = do
    compacted <- compactAllTerminalIntents interpreter registered coordinate
    pure (committedRun sinkCasAttempted <$ compacted)

  committedRun sinkCasAttempted =
    TargetCommitRunCommitted
      { targetCommitRunTargetIdentity = targetSecretSinkIdentity sink
      , targetCommitRunGeneration = generation
      , targetCommitRunSinkCasAttempted = sinkCasAttempted
      }

  coordinateObject = targetIntentCoordinateObject

compactAllTerminalIntents
  :: (Monad m)
  => TargetCommitInterpreter m payload
  -> RegisteredTargetSet
  -> TargetIntentCoordinate
  -> m (Either TargetCommitInterpreterError ())
compactAllTerminalIntents interpreter registered coordinate =
  go (registeredTargetCapacity registered)
 where
  go remaining = do
    observation <-
      modelBObserve
        (targetCommitGlobalAdapter interpreter)
        (targetIntentCoordinateObject coordinate)
    case observation of
      ModelBMissing -> pure (Right ())
      ModelBCorrupt detail ->
        pure (Left (TargetCommitCompactionNotConfirmed detail))
      ModelBEndpointUnready detail ->
        pure (Left (TargetCommitCompactionNotConfirmed detail))
      ModelBUnobservable detail ->
        pure (Left (TargetCommitCompactionNotConfirmed detail))
      ModelBObserved _ projection ->
        case terminalIntentIdentities projection of
          [] -> pure (Right ())
          identity : _
            | remaining <= 0 ->
                pure
                  ( Left
                      ( TargetCommitCompactionOverBound
                          (registeredTargetCapacity registered)
                      )
                  )
            | otherwise -> do
                permitResult <- targetCommitCurrentPermit interpreter
                case permitResult of
                  Left detail -> pure (Left (TargetCommitPermitUnavailable detail))
                  Right permit ->
                    case compactTargetIntent registered coordinate permit identity observation of
                      TargetIntentCompactRefused refusal ->
                        pure (Left (TargetCommitCompactionFailed refusal))
                      TargetIntentCompactAlreadyApplied -> go (remaining - 1)
                      TargetIntentCompactCompareAndSwap request -> do
                        verdict <-
                          modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
                        -- Sprint 4.63: a refusal used to consume one retry from
                        -- a budget whose exhaustion is then reported as
                        -- 'TargetCommitCompactionOverBound' — a capacity bound
                        -- named as the cause of a refusal. That misdiagnosis is
                        -- reachable in the ordinary write-denied/read-allowed
                        -- state, where every observation succeeds and every
                        -- write is refused.
                        case globalLedgerCasRefusal GlobalLedgerCompaction verdict of
                          Just refusal -> pure (Left refusal)
                          Nothing -> go (remaining - 1)

data TargetRecoveryInterpreter m payload = TargetRecoveryInterpreter
  { targetRecoveryBaseInterpreter :: !(TargetCommitInterpreter m payload)
  , targetRecoveryWaitUntil :: !(AuthorityTime -> m (Either Text ()))
  , targetRecoveryWaitFor :: !(AuthorityDuration -> m (Either Text ()))
  }

data TargetRecoveryRun
  = TargetRecoveryRunAlreadyResolved
  | TargetRecoveryRunResolved ![Text]
  deriving (Eq, Show)

runSuccessorTargetRecovery
  :: (Eq payload, Monad m)
  => TargetRecoveryInterpreter m payload
  -> RegisteredTargetSet
  -> TargetIntentCoordinate
  -> LeasePolicy
  -> LeaseGrant
  -> m (Either TargetCommitInterpreterError TargetRecoveryRun)
runSuccessorTargetRecovery recovery registered coordinate policy predecessor = do
  runSuccessorTargetRecoveryAfter
    recovery
    registered
    coordinate
    policy
    (successorNotBefore policy predecessor)

runSuccessorTargetRecoveryAfter
  :: (Eq payload, Monad m)
  => TargetRecoveryInterpreter m payload
  -> RegisteredTargetSet
  -> TargetIntentCoordinate
  -> LeasePolicy
  -> AuthorityTime
  -> m (Either TargetCommitInterpreterError TargetRecoveryRun)
runSuccessorTargetRecoveryAfter recovery registered coordinate policy recoveryNotBefore = do
  let base = targetRecoveryBaseInterpreter recovery
  compacted <- compactAllTerminalIntents base registered coordinate
  case compacted of
    Left err -> pure (Left err)
    Right () -> do
      initial <- modelBObserve (targetCommitGlobalAdapter base) (coordinateObject coordinate)
      case initial of
        ModelBMissing -> pure (Right TargetRecoveryRunAlreadyResolved)
        ModelBCorrupt detail ->
          pure (Left (TargetCommitCompactionNotConfirmed detail))
        ModelBEndpointUnready detail ->
          pure (Left (TargetCommitCompactionNotConfirmed detail))
        ModelBUnobservable detail ->
          pure (Left (TargetCommitCompactionNotConfirmed detail))
        ModelBObserved _ projection -> do
          let outstanding = preparedIntents projection
          if null outstanding
            then pure (Right TargetRecoveryRunAlreadyResolved)
            else do
              waited <-
                targetRecoveryWaitUntil recovery recoveryNotBefore
              case waited of
                Left detail -> pure (Left (TargetCommitRecoveryWaitFailed detail))
                Right () -> do
                  witnesses <- collectWitnesses base outstanding
                  case witnesses of
                    Left err -> pure (Left err)
                    Right stable -> resolve base outstanding stable
 where
  collectWitnesses base = collect []
   where
    collect accumulated [] = pure (Right (reverse accumulated))
    collect accumulated (intent : rest) =
      case registeredTargetByIdentity registered (targetCommitTargetIdentity intent) of
        Nothing ->
          pure
            ( Left
                ( TargetCommitRecoveryFailed
                    (unregisteredRecoveryRefusal intent)
                )
            )
        Just sink -> do
          sampleResult <- collectSamples base sink
          case sampleResult of
            Left err -> pure (Left err)
            Right samples ->
              case proveStableTargetReadbackAfter
                recoveryNotBefore
                (targetCommitDigestPayload base)
                registered
                policy
                intent
                samples of
                Left refusal ->
                  pure
                    ( Left
                        ( TargetCommitRecoveryReadbackFailed
                            (targetCommitTargetIdentity intent)
                            refusal
                        )
                    )
                Right witness -> collect (witness : accumulated) rest

  collectSamples base sink =
    collect 0 []
   where
    count = leasePolicyStableObservationCount policy
    visibility = leasePolicyProviderVisibilityGrace policy
    collect index accumulated
      | index >= count = pure (Right (reverse accumulated))
      | otherwise = do
          waitResult <-
            if index == 0
              then pure (Right ())
              else targetRecoveryWaitFor recovery visibility
          case waitResult of
            Left detail -> pure (Left (TargetCommitRecoveryWaitFailed detail))
            Right () -> do
              timeResult <- targetCommitCurrentAuthorityTime base
              case timeResult of
                Left detail ->
                  pure (Left (TargetCommitAuthorityClockUnavailable detail))
                Right observedAt -> do
                  observation <- targetSinkObserve (targetCommitSinkAdapter base) sink
                  collect
                    (index + 1)
                    (TimedTargetSinkObservation observedAt observation : accumulated)

  resolve base originalIntents witnesses = do
    permitResult <- targetCommitCurrentPermit base
    case permitResult of
      Left detail -> pure (Left (TargetCommitPermitUnavailable detail))
      Right permit -> do
        global <- modelBObserve (targetCommitGlobalAdapter base) (coordinateObject coordinate)
        case decideResolveOutstandingTargets registered coordinate permit witnesses global of
          TargetRecoveryRefused refusal -> pure (Left (TargetCommitRecoveryFailed refusal))
          TargetRecoveryAlreadyResolved -> pure (Right TargetRecoveryRunAlreadyResolved)
          TargetRecoveryCompareAndSwap request -> do
            verdict <- modelBCompareAndSwap (targetCommitGlobalAdapter base) request
            case globalLedgerCasRefusal GlobalLedgerRecoveryResolve verdict of
              Just refusal -> pure (Left refusal)
              Nothing -> do
                compacted <- compactAllTerminalIntents base registered coordinate
                case compacted of
                  Left err -> pure (Left err)
                  Right () -> do
                    confirmed <-
                      modelBObserve (targetCommitGlobalAdapter base) (coordinateObject coordinate)
                    let remaining = case confirmed of
                          ModelBObserved _ projection -> intentIdentities projection
                          _ -> map targetCommitTargetIdentity originalIntents
                    pure $
                      if null remaining
                        then
                          Right
                            ( TargetRecoveryRunResolved
                                (map targetCommitTargetIdentity originalIntents)
                            )
                        else Left (TargetCommitRecoveryNotConfirmed remaining)

  coordinateObject = targetIntentCoordinateObject

-- This branch is unreachable for a projection decoded through the bounded
-- registry codec, but retaining a structured refusal keeps the interpreter
-- total if a custom in-memory adapter hands it malformed state.
unregisteredRecoveryRefusal :: TargetCommitIntent -> TargetCommitRefusal
unregisteredRecoveryRefusal intent =
  TargetCommitUnregisteredTarget (targetCommitTargetIdentity intent)

preparedIntents :: TargetIntentProjection -> [TargetCommitIntent]
preparedIntents projection =
  [ intent
  | entry <- targetProjectionEntries projection
  , Just intent <- [targetProjectionEntryIntent entry]
  , targetCommitDisposition intent == TargetCommitPrepared
  ]

terminalIntentIdentities :: TargetIntentProjection -> [Text]
terminalIntentIdentities projection =
  [ targetProjectionEntryTargetIdentity entry
  | entry <- targetProjectionEntries projection
  , Just intent <- [targetProjectionEntryIntent entry]
  , targetCommitDisposition intent /= TargetCommitPrepared
  ]

intentIdentities :: TargetIntentProjection -> [Text]
intentIdentities projection =
  [ targetProjectionEntryTargetIdentity entry
  | entry <- targetProjectionEntries projection
  , Just _ <- [targetProjectionEntryIntent entry]
  ]

projectionHasCommittedIntent
  :: TargetCommitIntent -> TargetIntentProjection -> Bool
projectionHasCommittedIntent expected projection =
  any matches (targetProjectionEntries projection)
 where
  matches :: TargetProjectionEntry -> Bool
  matches entry = case targetProjectionEntryIntent entry of
    Just current ->
      targetCommitDisposition current == TargetCommitCommitted
        && targetCommitOwnerNonce current == targetCommitOwnerNonce expected
        && targetCommitFencingToken current == targetCommitFencingToken expected
        && targetCommitTargetIdentity current == targetCommitTargetIdentity expected
        && targetCommitGeneration current == targetCommitGeneration expected
        && targetCommitDigest current == targetCommitDigest expected
    Nothing -> False
