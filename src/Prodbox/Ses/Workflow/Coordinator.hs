{-# LANGUAGE DerivingStrategies #-}

-- | One-command coordinator for the retained SES aggregate. State is read
-- before every decision, effects converge by observe/apply/read-back, and the
-- resulting event is committed with exact-revision CAS.
module Prodbox.Ses.Workflow.Coordinator
  ( SesWorkflowRunResult (..)
  , runSesWorkflowCommand
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Ses.Workflow.Interpreter
  ( SesWorkflowEffectResult (..)
  , SesWorkflowInterpreters
  , runSesWorkflowEffect
  )
import Prodbox.Ses.Workflow.Model
  ( SesWorkflowCommand
  , SesWorkflowDecision (..)
  , SesWorkflowEffect
  , SesWorkflowEvent
  , decideSesWorkflow
  )
import Prodbox.Ses.Workflow.Repository
  ( SesWorkflowRepository (..)
  , SesWorkflowSnapshot (..)
  , applySesWorkflowEvent
  )

data SesWorkflowRunResult
  = SesWorkflowEffectCommitted !SesWorkflowEffect !SesWorkflowEvent
  | SesWorkflowEventCommitted !SesWorkflowEvent
  | SesWorkflowCommandAlreadyApplied
  | SesWorkflowCommandRefused !Text
  | SesWorkflowDestroyed !Text
  deriving stock (Eq, Show)

runSesWorkflowCommand
  :: (Monad m)
  => SesWorkflowRepository m revision
  -> SesWorkflowInterpreters m
  -> SesWorkflowCommand
  -> m (Either Text SesWorkflowRunResult)
runSesWorkflowCommand repository interpreters command = do
  observed <- readSesWorkflowSnapshot repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot ->
      case decideSesWorkflow (sesWorkflowSnapshotState snapshot) command of
        RefuseSesWorkflow refusal -> pure (Right (SesWorkflowCommandRefused (showText refusal)))
        SesAlreadyApplied -> pure (Right SesWorkflowCommandAlreadyApplied)
        RecordSesEvent event -> commitEvent (SesWorkflowEventCommitted event) event
        EmitSesEffect effect -> do
          result <- runSesWorkflowEffect interpreters effect
          case result of
            Left detail -> pure (Left detail)
            Right (SesWorkflowDestroyResult receipt) -> pure (Right (SesWorkflowDestroyed receipt))
            Right (SesWorkflowEventResult event) ->
              commitEvent (SesWorkflowEffectCommitted effect event) event
 where
  commitEvent result event = do
    committed <- applySesWorkflowEvent repository event
    pure (result <$ committed)

showText :: (Show value) => value -> Text
showText = Text.pack . show
