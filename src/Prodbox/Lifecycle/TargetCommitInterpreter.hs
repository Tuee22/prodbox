{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Generic effectful interpreter for the bounded cross-authority target
-- protocol.  It treats every mutation result as provisional and closes each
-- step only through a fresh authoritative observation.  The target CAS is
-- invoked at most once in one run.
module Prodbox.Lifecycle.TargetCommitInterpreter
  ( TargetCommitInterpreter (..)
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

data TargetCommitInterpreterError
  = TargetCommitPermitUnavailable !Text
  | TargetCommitAuthorityClockUnavailable !Text
  | TargetCommitPrepareFailed !TargetCommitRefusal
  | TargetCommitPrepareNotConfirmed !TargetCommitRefusal
  | TargetCommitSinkWriteFailed !TargetSinkReadbackRefusal
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
                  _ <- modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
                  runPrepared intent
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
                    _ <- targetSinkCompareAndSwap (targetCommitSinkAdapter interpreter) request
                    completeAfterReadback intent True writePermit

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
                    _ <- modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
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
                        _ <- modelBCompareAndSwap (targetCommitGlobalAdapter interpreter) request
                        go (remaining - 1)

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
            _ <- modelBCompareAndSwap (targetCommitGlobalAdapter base) request
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
