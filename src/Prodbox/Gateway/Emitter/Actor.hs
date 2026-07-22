{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The live single-owner interpreter for the pure emitter kernel. Callers
-- submit typed requests to a bounded queue; one worker owns the kernel state
-- and executes every emitted effect to completion before admitting the next
-- command. A ticket is minted before enqueue, so queue wait consumes the same
-- absolute deadline as stage, fsync, publish, commit, and final fsync.
module Prodbox.Gateway.Emitter.Actor
  ( EmitterActor
  , EmitterActorConfig
  , mkEmitterActorConfig
  , emitterActorMailbox
  , EmitterInterpreter (..)
  , EmitterCompletion (..)
  , EmitterActorError (..)
  , withEmitterActor
  , submitEmitterRequest
  , acknowledgeEmitterPeerThrough
  )
where

import Control.Concurrent.Async (link, withAsync)
import Control.Concurrent.STM
  ( STM
  , TMVar
  , TVar
  , atomically
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTVar
  , retry
  , takeTMVar
  , writeTVar
  )
import Control.Exception (mask, onException)
import Control.Monad (void)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Capacity qualified as Capacity
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , MonotonicInstant
  , RemainingDuration
  , RetryAfter (..)
  , WorkEstimate
  , deadlineExpired
  , deadlineObservation
  )
import Prodbox.Gateway.Emitter.Kernel
  ( AckPoint
  , CheckpointCandidate
  , CheckpointOutcome
  , DurableEmitterProjection
  , EmitterEffect (..)
  , EmitterIntent (..)
  , EmitterPeer
  , EmitterState
  , EmitterStep (..)
  , PhaseCompletion (..)
  , RecoveryReplay
  , RejectReason (..)
  , StageOutcome
  , StagePlan
  , StagedRecord
  , StepOutcome (..)
  , TransitionAdmission
  , emitterCheckpointPending
  , emitterInFlight
  , emitterIncarnation
  , emitterLatestCommitted
  , emitterPending
  , projectDurableEmitterState
  , stagePlanIncarnation
  , step
  )
import Prodbox.Gateway.Emitter.Mailbox
  ( EmitterRequest (..)
  , Mailbox
  , emptyMailbox
  , mkMailboxCapacity
  )

newtype EmitterActorConfig = EmitterActorConfig
  { actorCapacityPlan :: Capacity.ServiceCapacityPlan
  }
  deriving stock (Eq, Show)

-- | A single-writer actor can consume only a validated one-worker capacity
-- plan. Queue size, saturation retry, and deadline feasibility all come from
-- that one plan rather than from an independent live-queue policy.
mkEmitterActorConfig :: Capacity.ServiceCapacityPlan -> Maybe EmitterActorConfig
mkEmitterActorConfig plan
  | Capacity.serviceCapacityWorkerCount plan == 1 = Just (EmitterActorConfig plan)
  | otherwise = Nothing

-- | Derive the pure kernel mailbox from the exact same capacity plan used by
-- the live admission queue. This keeps the inner safety bound and retry hint
-- from drifting from the actor's enforced policy.
emitterActorMailbox :: EmitterActorConfig -> Mailbox
emitterActorMailbox config =
  let plan = actorCapacityPlan config
      capacity = Capacity.serviceCapacityRejectionThreshold plan
      retryHint = RetryAfter (Capacity.serviceCapacityServiceTimeMicros plan)
   in case mkMailboxCapacity capacity of
        Nothing -> error "validated service capacity produced a zero mailbox bound"
        Just mailboxCapacity -> emptyMailbox mailboxCapacity retryHint

-- | Effect boundary owned by the daemon. Every callback receives the exact
-- immutable kernel record and the transition's one absolute deadline.
data EmitterInterpreter = EmitterInterpreter
  { emitterMintTicket :: IO (MonotonicInstant, Deadline)
  , emitterObserveNow :: IO MonotonicInstant
  , emitterStage
      :: TransitionAdmission
      -> Deadline
      -> StagePlan
      -> IO (Either Text StageOutcome)
  , emitterFsyncProjection
      :: Deadline
      -> DurableEmitterProjection
      -> IO (Either Text ())
  , emitterPublish :: Deadline -> StagedRecord -> IO (Either Text ())
  , emitterCommit :: Deadline -> StagedRecord -> IO (Either Text ())
  , emitterInstallCheckpoint
      :: Deadline
      -> CheckpointCandidate
      -> IO (Either Text CheckpointOutcome)
  , emitterRestoreRetained
      :: Deadline
      -> RecoveryReplay
      -> IO (Either Text ())
  }

data EmitterCompletion
  = EmitterNoTransition
  | EmitterCommitted !StagedRecord
  deriving stock (Eq, Show)

data EmitterActorError
  = EmitterActorOverloaded !RetryAfter
  | EmitterActorDeadlineUnmeetable !WorkEstimate !RemainingDuration
  | EmitterActorKernelRejected !RejectReason
  | EmitterActorInterpreterFailed !Text
  deriving stock (Eq, Show)

data ActorOperation
  = SubmitOperation !EmitterRequest
  | AcknowledgeOperation !EmitterPeer !AckPoint
  | ResumePendingOperation

data ActorCommandResult
  = ActorCommandFinished !(Either EmitterActorError EmitterCompletion)
  | ActorCommandNeedsContinuation

data ActorCommand = ActorCommand
  { commandOperation :: !ActorOperation
  , commandDeadline :: !Deadline
  , commandCapacityTicket :: !Capacity.QueueTicket
  , commandResponse :: !(TMVar (Either EmitterActorError EmitterCompletion))
  }

data ActorQueueState = ActorQueueState
  { queuedCommands :: ![ActorCommand]
  , queueAdmission :: !Capacity.AdmissionQueue
  , queueNextRequestId :: !Natural
  }

newtype ActorQueue = ActorQueue (TVar ActorQueueState)

data EmitterActor = EmitterActor
  { actorCommands :: !ActorQueue
  , actorTicket :: IO (MonotonicInstant, Deadline)
  }

-- | Scope the actor worker to the supplied action. Linking makes an unexpected
-- interpreter/worker exception fail the daemon's structured-concurrency scope
-- instead of silently leaving submissions blocked forever.
withEmitterActor
  :: EmitterActorConfig
  -> EmitterState
  -> EmitterInterpreter
  -> (EmitterActor -> IO result)
  -> IO result
withEmitterActor config initial interpreter action = do
  queueState <-
    newTVarIO
      ActorQueueState
        { queuedCommands = []
        , queueAdmission = Capacity.emptyAdmissionQueue (actorCapacityPlan config)
        , queueNextRequestId = 0
        }
  let queue = ActorQueue queueState
  let actor =
        EmitterActor
          { actorCommands = queue
          , actorTicket = emitterMintTicket interpreter
          }
  withAsync (actorWorker queue initial interpreter) $ \worker -> do
    link worker
    action actor

-- | Mint the absolute deadline before attempting queue admission. A full
-- queue refuses immediately with the actor's retry hint.
submitEmitterRequest
  :: EmitterActor
  -> EmitterRequest
  -> IO (Either EmitterActorError EmitterCompletion)
submitEmitterRequest actor request =
  submitActorOperation actor (SubmitOperation request)

-- | Advance one durable peer acknowledgement through the same bounded actor
-- lane as emission. The actor adopts the acknowledged state only after its
-- durable projection has been fsynced under the command's fresh ticket.
acknowledgeEmitterPeerThrough
  :: EmitterActor
  -> EmitterPeer
  -> AckPoint
  -> IO (Either EmitterActorError ())
acknowledgeEmitterPeerThrough actor peer point =
  void <$> submitActorOperation actor (AcknowledgeOperation peer point)

submitActorOperation
  :: EmitterActor
  -> ActorOperation
  -> IO (Either EmitterActorError EmitterCompletion)
submitActorOperation actor operation =
  mask $ \restore -> do
    (admittedAt, deadline) <- actorTicket actor
    response <- newEmptyTMVarIO
    case deadlineObservation admittedAt deadline of
      DeadlineExpired ->
        pure (Left (EmitterActorKernelRejected RejectDeadlineExpired))
      DeadlineOpen budget -> do
        admitted <-
          atomically
            (admitActorCommand (actorCommands actor) operation budget deadline response)
        case admitted of
          Left err -> pure (Left err)
          Right requestId ->
            restore (atomically (takeTMVar response))
              `onException` atomically (cancelPendingCommand (actorCommands actor) requestId)

admitActorCommand
  :: ActorQueue
  -> ActorOperation
  -> RemainingDuration
  -> Deadline
  -> TMVar (Either EmitterActorError EmitterCompletion)
  -> STM (Either EmitterActorError Capacity.RequestId)
admitActorCommand (ActorQueue stateVar) operation budget deadline response = do
  queueState <- readTVar stateVar
  let requestId = Capacity.RequestId (queueNextRequestId queueState)
      heartbeatSlot = pendingHeartbeatSlot operation (queuedCommands queueState)
      request = Capacity.AdmissionRequest requestId budget
      admissionResult =
        case heartbeatSlot of
          Nothing -> Just (Capacity.admit (queueAdmission queueState) request)
          Just (_, old, _) ->
            Capacity.replaceAdmission
              (Capacity.ticketRequestId (commandCapacityTicket old))
              (queueAdmission queueState)
              request
  case admissionResult of
    Nothing ->
      pure (Left (EmitterActorInterpreterFailed "capacity replacement target missing"))
    Just (Capacity.AdmissionRejected rejection, _) ->
      pure (Left (capacityRejection rejection))
    Just (Capacity.AdmissionAdmit capacityTicket, admissionAfter) -> do
      let admittedOperation =
            case heartbeatSlot of
              Nothing -> operation
              Just (_, old, _) -> freshestHeartbeatOperation (commandOperation old) operation
          command =
            ActorCommand
              { commandOperation = admittedOperation
              , commandDeadline = deadline
              , commandCapacityTicket = capacityTicket
              , commandResponse = response
              }
          commandsAfter =
            case heartbeatSlot of
              Nothing -> queuedCommands queueState ++ [command]
              Just (before, _old, after) -> before ++ command : after
      case heartbeatSlot of
        Nothing -> pure ()
        Just (_, old, _) -> putTMVar (commandResponse old) (Right EmitterNoTransition)
      writeTVar
        stateVar
        queueState
          { queuedCommands = commandsAfter
          , queueAdmission = admissionAfter
          , queueNextRequestId = queueNextRequestId queueState + 1
          }
      pure (Right requestId)

pendingHeartbeatSlot
  :: ActorOperation
  -> [ActorCommand]
  -> Maybe ([ActorCommand], ActorCommand, [ActorCommand])
pendingHeartbeatSlot operation commands =
  case operation of
    SubmitOperation (ReqHeartbeat _) ->
      case break isHeartbeatCommand commands of
        (_, []) -> Nothing
        (before, old : after) -> Just (before, old, after)
    _ -> Nothing

isHeartbeatCommand :: ActorCommand -> Bool
isHeartbeatCommand command = case commandOperation command of
  SubmitOperation (ReqHeartbeat _) -> True
  _ -> False

freshestHeartbeatOperation :: ActorOperation -> ActorOperation -> ActorOperation
freshestHeartbeatOperation
  (SubmitOperation (ReqHeartbeat old))
  (SubmitOperation (ReqHeartbeat new)) =
    SubmitOperation (ReqHeartbeat (max old new))
freshestHeartbeatOperation _ new = new

capacityRejection :: Capacity.RejectionReason -> EmitterActorError
capacityRejection rejection = case rejection of
  Capacity.RejectedSaturated retryHint -> EmitterActorOverloaded retryHint
  Capacity.RejectedDeadlineUnmeetable estimate budget ->
    EmitterActorDeadlineUnmeetable estimate budget

cancelPendingCommand :: ActorQueue -> Capacity.RequestId -> STM ()
cancelPendingCommand (ActorQueue stateVar) requestId = do
  queueState <- readTVar stateVar
  case removePendingCommand requestId (queuedCommands queueState) of
    Nothing -> pure ()
    Just commandsAfter ->
      writeTVar
        stateVar
        queueState
          { queuedCommands = commandsAfter
          , queueAdmission = Capacity.cancelRequest requestId (queueAdmission queueState)
          }

removePendingCommand :: Capacity.RequestId -> [ActorCommand] -> Maybe [ActorCommand]
removePendingCommand requestId commands =
  case break ((== requestId) . Capacity.ticketRequestId . commandCapacityTicket) commands of
    (_, []) -> Nothing
    (before, _command : after) -> Just (before ++ after)

readActorCommand :: ActorQueue -> STM ActorCommand
readActorCommand (ActorQueue stateVar) = do
  queueState <- readTVar stateVar
  case queuedCommands queueState of
    [] -> retry
    command : remaining -> do
      writeTVar stateVar queueState {queuedCommands = remaining}
      pure command

completeActorCommand
  :: ActorQueue
  -> ActorCommand
  -> Either EmitterActorError EmitterCompletion
  -> STM ()
completeActorCommand (ActorQueue stateVar) command outcome = do
  queueState <- readTVar stateVar
  let requestId = Capacity.ticketRequestId (commandCapacityTicket command)
  writeTVar
    stateVar
    queueState
      { queueAdmission = Capacity.completeService requestId (queueAdmission queueState)
      }
  putTMVar (commandResponse command) outcome

actorWorker :: ActorQueue -> EmitterState -> EmitterInterpreter -> IO ()
actorWorker queue = loop
 where
  loop state interpreter = do
    command <- atomically (readActorCommand queue)
    now <- emitterObserveNow interpreter
    (next, result) <- runCommand interpreter state now command
    case result of
      ActorCommandFinished outcome ->
        atomically (completeActorCommand queue command outcome)
      ActorCommandNeedsContinuation ->
        scheduleContinuation queue interpreter command
    loop next interpreter

scheduleContinuation :: ActorQueue -> EmitterInterpreter -> ActorCommand -> IO ()
scheduleContinuation queue interpreter previous = do
  (admittedAt, deadline) <- emitterMintTicket interpreter
  case deadlineObservation admittedAt deadline of
    DeadlineExpired ->
      atomically
        ( completeActorCommand
            queue
            previous
            (Left (EmitterActorKernelRejected RejectDeadlineExpired))
        )
    DeadlineOpen budget ->
      atomically (replaceWithContinuation queue previous budget deadline)

replaceWithContinuation
  :: ActorQueue
  -> ActorCommand
  -> RemainingDuration
  -> Deadline
  -> STM ()
replaceWithContinuation (ActorQueue stateVar) previous budget deadline = do
  queueState <- readTVar stateVar
  let oldRequestId = Capacity.ticketRequestId (commandCapacityTicket previous)
      newRequestId = Capacity.RequestId (queueNextRequestId queueState)
      request = Capacity.AdmissionRequest newRequestId budget
      replacement =
        Capacity.replaceAdmission
          oldRequestId
          (queueAdmission queueState)
          request
  case replacement of
    Nothing -> finishFailure queueState oldRequestId "capacity continuation target missing"
    Just (Capacity.AdmissionRejected rejection, _) -> do
      let admissionAfter = Capacity.completeService oldRequestId (queueAdmission queueState)
      writeTVar stateVar queueState {queueAdmission = admissionAfter}
      putTMVar (commandResponse previous) (Left (capacityRejection rejection))
    Just (Capacity.AdmissionAdmit capacityTicket, admissionAfter) -> do
      let continuation =
            ActorCommand
              { commandOperation = ResumePendingOperation
              , commandDeadline = deadline
              , commandCapacityTicket = capacityTicket
              , commandResponse = commandResponse previous
              }
      writeTVar
        stateVar
        queueState
          { queuedCommands = continuation : queuedCommands queueState
          , queueAdmission = admissionAfter
          , queueNextRequestId = queueNextRequestId queueState + 1
          }
 where
  finishFailure queueState oldRequestId detail = do
    let admissionAfter = Capacity.completeService oldRequestId (queueAdmission queueState)
    writeTVar stateVar queueState {queueAdmission = admissionAfter}
    putTMVar
      (commandResponse previous)
      (Left (EmitterActorInterpreterFailed detail))

runCommand
  :: EmitterInterpreter
  -> EmitterState
  -> MonotonicInstant
  -> ActorCommand
  -> IO (EmitterState, ActorCommandResult)
runCommand interpreter initial now command
  | deadlineExpired now (commandDeadline command) =
      pure
        ( initial
        , ActorCommandFinished (Left (EmitterActorKernelRejected RejectDeadlineExpired))
        )
  | otherwise =
      case commandOperation command of
        SubmitOperation ReqRecover ->
          driveStep
            interpreter
            (commandDeadline command)
            (emitterLatestCommitted initial)
            (step initial (Recover now (commandDeadline command)))
        ResumePendingOperation ->
          driveStep
            interpreter
            (commandDeadline command)
            (emitterLatestCommitted initial)
            (step initial (Pump now (commandDeadline command)))
        SubmitOperation request -> runEmissionRequest interpreter initial now command request
        AcknowledgeOperation peer point ->
          runAcknowledgement interpreter initial command peer point

runEmissionRequest
  :: EmitterInterpreter
  -> EmitterState
  -> MonotonicInstant
  -> ActorCommand
  -> EmitterRequest
  -> IO (EmitterState, ActorCommandResult)
runEmissionRequest interpreter initial now command request
  | emitterInFlight initial /= Nothing =
      rejected RejectBusy
  | emitterCheckpointPending initial /= Nothing =
      rejected RejectCheckpointPending
  | emitterPending initial /= Nothing =
      rejected RejectBusy
  | otherwise =
      case acceptedStep (step initial (SubmitRequest request)) of
        Left err -> pure (initial, ActorCommandFinished (Left err))
        Right submitted -> do
          let pumped =
                step
                  (stepState submitted)
                  (Pump now (commandDeadline command))
          driveStep
            interpreter
            (commandDeadline command)
            (emitterLatestCommitted initial)
            pumped
 where
  rejected reason =
    pure
      ( initial
      , ActorCommandFinished (Left (EmitterActorKernelRejected reason))
      )

runAcknowledgement
  :: EmitterInterpreter
  -> EmitterState
  -> ActorCommand
  -> EmitterPeer
  -> AckPoint
  -> IO (EmitterState, ActorCommandResult)
runAcknowledgement interpreter initial command peer point =
  case acceptedStep (step initial (AckPeerThrough peer point)) of
    Left err -> pure (initial, ActorCommandFinished (Left err))
    Right acknowledged ->
      case stepOutcome acknowledged of
        OutcomeNoOp -> pure (initial, ActorCommandFinished (Right EmitterNoTransition))
        _ -> do
          let acknowledgedState = stepState acknowledged
          persisted <-
            emitterFsyncProjection
              interpreter
              (commandDeadline command)
              (projectDurableEmitterState acknowledgedState)
          case persisted of
            Left err ->
              pure
                ( initial
                , ActorCommandFinished (Left (EmitterActorInterpreterFailed err))
                )
            Right () ->
              pure
                ( acknowledgedState
                , ActorCommandFinished (Right EmitterNoTransition)
                )

driveStep
  :: EmitterInterpreter
  -> Deadline
  -> Maybe StagedRecord
  -> EmitterStep
  -> IO (EmitterState, ActorCommandResult)
driveStep interpreter governingDeadline before current =
  case acceptedStep current of
    Left err -> pure (stepState current, ActorCommandFinished (Left err))
    Right accepted ->
      case stepEffects accepted of
        [] ->
          driveIdleOrFinish interpreter governingDeadline before (stepState accepted)
        effects ->
          driveEffects
            interpreter
            governingDeadline
            before
            (stepState accepted)
            effects

driveEffects
  :: EmitterInterpreter
  -> Deadline
  -> Maybe StagedRecord
  -> EmitterState
  -> [EmitterEffect]
  -> IO (EmitterState, ActorCommandResult)
driveEffects interpreter governingDeadline before state effects =
  case effects of
    [] -> driveIdleOrFinish interpreter governingDeadline before state
    effect : remaining -> do
      interpreted <- interpretEffect interpreter state effect
      case interpreted of
        Left err ->
          pure
            ( state
            , ActorCommandFinished (Left (EmitterActorInterpreterFailed err))
            )
        Right completed ->
          case acceptedStep completed of
            Left err -> pure (stepState completed, ActorCommandFinished (Left err))
            Right accepted ->
              driveEffects
                interpreter
                governingDeadline
                before
                (stepState accepted)
                (remaining ++ stepEffects accepted)

driveIdleOrFinish
  :: EmitterInterpreter
  -> Deadline
  -> Maybe StagedRecord
  -> EmitterState
  -> IO (EmitterState, ActorCommandResult)
driveIdleOrFinish interpreter governingDeadline before state
  | emitterInFlight state == Nothing && emitterPending state /= Nothing = do
      persisted <-
        emitterFsyncProjection
          interpreter
          governingDeadline
          (projectDurableEmitterState state)
      case persisted of
        Left err ->
          pure
            ( state
            , ActorCommandFinished (Left (EmitterActorInterpreterFailed err))
            )
        Right () -> pure (state, ActorCommandNeedsContinuation)
  | emitterInFlight state /= Nothing =
      pure
        ( state
        , ActorCommandFinished (Left (EmitterActorKernelRejected RejectBusy))
        )
  | otherwise =
      let after = emitterLatestCommitted state
          completion =
            case after of
              Just record | Just record /= before -> EmitterCommitted record
              _ -> EmitterNoTransition
       in pure (state, ActorCommandFinished (Right completion))

interpretEffect
  :: EmitterInterpreter
  -> EmitterState
  -> EmitterEffect
  -> IO (Either Text EmitterStep)
interpretEffect interpreter state effect = case effect of
  EffStage admission deadline plan -> do
    result <- emitterStage interpreter admission deadline plan
    pure (step state . StageResolved (stagePlanIncarnation plan) admission <$> result)
  EffFsyncStage admission deadline record -> do
    result <-
      emitterFsyncProjection
        interpreter
        deadline
        (projectDurableEmitterState state)
    pure
      ( step state (PhaseAdvanced (currentIncarnation state) admission record DidFsyncStage)
          <$ result
      )
  EffPublish admission deadline record -> do
    result <- emitterPublish interpreter deadline record
    pure
      ( step state (PhaseAdvanced (currentIncarnation state) admission record DidPublish)
          <$ result
      )
  EffCommit admission deadline record -> do
    result <- emitterCommit interpreter deadline record
    pure
      ( step state (PhaseAdvanced (currentIncarnation state) admission record DidCommit)
          <$ result
      )
  EffFsyncCommit admission deadline record -> do
    let completed =
          step
            state
            (PhaseAdvanced (currentIncarnation state) admission record DidFsyncCommit)
    case acceptedStep completed of
      Left actorErr -> pure (Left (renderActorError actorErr))
      Right accepted -> do
        result <-
          emitterFsyncProjection
            interpreter
            deadline
            (projectDurableEmitterState (stepState accepted))
        pure (accepted <$ result)
  EffCheckpointCompaction incarnation deadline candidate -> do
    result <- emitterInstallCheckpoint interpreter deadline candidate
    case result of
      Left err -> pure (Left err)
      Right outcome -> do
        let completed = step state (CheckpointResolved incarnation deadline candidate outcome)
        case acceptedStep completed of
          Left actorErr -> pure (Left (renderActorError actorErr))
          Right accepted -> do
            persisted <-
              emitterFsyncProjection
                interpreter
                deadline
                (projectDurableEmitterState (stepState accepted))
            pure (accepted <$ persisted)
  EffRestoreRetained incarnation deadline replay -> do
    result <- emitterRestoreRetained interpreter deadline replay
    pure (step state (RecoveryRestored incarnation replay) <$ result)
 where
  currentIncarnation = emitterIncarnation

acceptedStep :: EmitterStep -> Either EmitterActorError EmitterStep
acceptedStep result = case stepOutcome result of
  OutcomeRejected rejection -> Left (EmitterActorKernelRejected rejection)
  _ -> Right result

renderActorError :: EmitterActorError -> Text
renderActorError actorErr = case actorErr of
  EmitterActorOverloaded retryHint ->
    "emitter actor overloaded: " <> Text.pack (show retryHint)
  EmitterActorDeadlineUnmeetable estimate budget ->
    "emitter actor deadline unmeetable: " <> Text.pack (show (estimate, budget))
  EmitterActorKernelRejected rejection ->
    "emitter kernel rejected completion: " <> Text.pack (show rejection)
  EmitterActorInterpreterFailed detail -> detail
