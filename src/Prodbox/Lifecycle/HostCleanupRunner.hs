{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-owned orchestration for the destructive host boundary of a
-- cascade cleanup.  The host intent is the durable control state; injected
-- effects may attempt mutations, but only exact positive read-backs advance
-- that state.
module Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerEffects (..)
  , HostCleanupEffectOutcome (..)
  , HostRecoveryPlaneCheckResult (..)
  , HostRecoveryPlaneCheck (..)
  , HostCleanupRunnerStep (..)
  , HostCleanupRunnerAction (..)
  , nextHostCleanupRunnerAction
  , HostCleanupRunnerContext
  , hostCleanupRunnerIntent
  , hostCleanupRunnerRunId
  , hostCleanupRunnerGraphDigest
  , hostCleanupRunnerObservationScope
  , hostCleanupRunnerUninstallOperationId
  , hostCleanupRunnerCompletionOperationId
  , hostCleanupRunnerTerminalIdentity
  , hostCleanupRunnerReadyPermitId
  , hostCleanupRunnerReadyReportDigest
  , HostCleanupCompletionReadBack (..)
  , HostCleanupRunnerResult (..)
  , HostCleanupRunnerBinding (..)
  , HostCleanupRunnerError (..)
  , prepareHostCleanupRunner
  , validateHostCleanupReady
  , runHostCleanupRunner
  , resumeHostCleanupRunner
  , HostCleanupRunnerProgress (..)
  , stepHostCleanupRunner
  , HostCleanupRunnerRegression
  , fixedHostCleanupRunnerRegression
  , hostCleanupRunnerRegressionUnboundRefused
  , hostCleanupRunnerRegressionFullTopology
  , hostCleanupRunnerRegressionResponseLossRecovered
  , hostCleanupRunnerRegressionConfirmedAbsenceNotRepeated
  , hostCleanupRunnerRegressionWrongReadyRefused
  , hostCleanupRunnerRegressionMissingCompletionRefused
  , hostCleanupRunnerRegressionConcurrentLeaseFenced
  , hostCleanupRunnerRegressionSteppedTopology
  , hostCleanupRunnerRegressionStepStopsAtOnePhase
  )
where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (wait, withAsync)
import Control.Monad (void)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRun (cleanupRunGraph, cleanupRunGraphDigest, cleanupRunId)
  , CleanupRunId
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupNodeOperationId
  )
import Prodbox.Lifecycle.HostCleanupIntent
import Prodbox.Lifecycle.HostCleanupIntent.Internal
  ( transitionHostCleanupIntent
  , withHostCleanupExecutionLease
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeCompleteEvidence
  , CascadeEvidenceError
  , CascadeReportDigest
  , LocalCompletionPermitId
  , LocalUninstallEvidence
  , ReadyToUninstallEvidence
  , cascadeCompleteGraphDigest
  , cascadeCompletePermitId
  , cascadeCompleteReportDigest
  , cascadeCompleteRunId
  , cascadeLocalCompletionOperationId
  , cascadeLocalUninstallOperationId
  , localCompletionPermitIdText
  , localUninstallAbsenceEvidence
  , readyToUninstallGraphDigest
  , readyToUninstallOperationReferences
  , readyToUninstallPermitId
  , readyToUninstallReportDigest
  , readyToUninstallRunId
  , readyToUninstallScope
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeCompletionReceiptObservation (..)
  , mkCascadeCompleteEvidence
  , mkLocalUninstallEvidence
  , withCascadeEvidenceFixtureForRunInternal
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( DurableReceiptKind (CascadeCompletionReceipt)
  , DurableReceiptObservation (..)
  , DurableReceiptObservationResult (DurableReceiptObserved)
  , LocalFoundationObservation (..)
  , LocalFoundationObservationResult (LocalFoundationAbsent)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationEvidenceScope
  , ObservationFailure
  )
import System.Directory (createDirectory, createDirectoryLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | An effect attempt is not completion.  Every arm is followed by the
-- operation's exact read-back; a positive read-back may therefore close an
-- applied-but-response-lost attempt safely.
data HostCleanupEffectOutcome
  = HostCleanupEffectApplied
  | HostCleanupEffectResponseLost !Text
  | HostCleanupEffectRefused !Text
  deriving (Eq, Show)

-- | Host-bootstrap availability is a local orchestration check only. It is
-- deliberately distinct from the opaque, descriptor-bound lifecycle
-- RecoveryPlane evidence accepted by teardown Execution.
data HostRecoveryPlaneCheckResult
  = HostRecoveryPlaneAvailable
  | HostRecoveryPlaneUnavailable !ObservationFailure
  | HostRecoveryPlaneUnobservable !ObservationFailure
  deriving (Eq, Show)

data HostRecoveryPlaneCheck = HostRecoveryPlaneCheck
  { hostRecoveryPlaneCheckScope :: !ObservationEvidenceScope
  , hostRecoveryPlaneCheckResult :: !HostRecoveryPlaneCheckResult
  }
  deriving (Eq, Show)

data HostCleanupRunnerStep
  = HostCleanupAcceptAuthorityStep
  | HostCleanupReadBackAuthorityAcceptanceStep
  | HostCleanupLocalUninstallStep
  | HostCleanupReadBackLocalAbsenceStep
  | HostCleanupReestablishRecoveryStep
  | HostCleanupReadBackRecoveryStep
  | HostCleanupReestablishAuthorityStep
  | HostCleanupReadBackAuthorityStep
  | HostCleanupReconcileRunStep
  | HostCleanupReadBackRunStep
  | HostCleanupCommitCompletionStep
  | HostCleanupReadBackCompletionStep
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The only action selected by each durable phase.  This is deliberately
-- pure so callers and tests can audit the resume topology without executing
-- host effects.
data HostCleanupRunnerAction
  = HostCleanupAcceptAuthority
  | HostCleanupArmTerminal
  | HostCleanupIssueLocalUninstall
  | HostCleanupRecordLocalAbsence
  | HostCleanupRecoverAuthority
  | HostCleanupCommitCompletion
  | HostCleanupVerifyCompletion
  | HostCleanupFinished
  deriving (Eq, Show)

nextHostCleanupRunnerAction :: HostCleanupIntent -> HostCleanupRunnerAction
nextHostCleanupRunnerAction intent = case hostCleanupIntentPhase intent of
  HostCleanupPrepared -> HostCleanupAcceptAuthority
  HostCleanupAuthorityAccepted -> HostCleanupArmTerminal
  HostCleanupTerminalArmed -> HostCleanupIssueLocalUninstall
  HostCleanupLocalUninstallIssued -> HostCleanupRecordLocalAbsence
  HostCleanupLocalAbsenceRecorded -> HostCleanupRecoverAuthority
  HostCleanupAuthorityReconciled -> HostCleanupCommitCompletion
  HostCleanupCompletionCommitted -> HostCleanupVerifyCompletion
  HostCleanupComplete -> HostCleanupFinished

data HostCleanupRunnerContext = HostCleanupRunnerContext
  { internalRunnerIntent :: !HostCleanupIntent
  , internalRunnerUninstallOperationId :: !CleanupOperationId
  , internalRunnerCompletionOperationId :: !CleanupOperationId
  , internalRunnerReadyPermitId :: !LocalCompletionPermitId
  , internalRunnerReadyReportDigest :: !CascadeReportDigest
  }
  deriving (Eq, Show)

hostCleanupRunnerIntent :: HostCleanupRunnerContext -> HostCleanupIntent
hostCleanupRunnerIntent = internalRunnerIntent

hostCleanupRunnerRunId :: HostCleanupRunnerContext -> CleanupRunId
hostCleanupRunnerRunId = hostCleanupRunId . hostCleanupRunnerIntent

hostCleanupRunnerGraphDigest :: HostCleanupRunnerContext -> CleanupDigest
hostCleanupRunnerGraphDigest = hostCleanupGraphDigest . hostCleanupRunnerIntent

hostCleanupRunnerObservationScope
  :: HostCleanupRunnerContext -> ObservationEvidenceScope
hostCleanupRunnerObservationScope =
  hostCleanupObservationEvidenceScope
    . hostCleanupScope
    . hostCleanupRunnerIntent

hostCleanupRunnerUninstallOperationId
  :: HostCleanupRunnerContext -> CleanupOperationId
hostCleanupRunnerUninstallOperationId = internalRunnerUninstallOperationId

hostCleanupRunnerCompletionOperationId
  :: HostCleanupRunnerContext -> CleanupOperationId
hostCleanupRunnerCompletionOperationId = internalRunnerCompletionOperationId

hostCleanupRunnerTerminalIdentity
  :: HostCleanupRunnerContext -> HostCleanupTerminalIdentity
hostCleanupRunnerTerminalIdentity =
  hostCleanupTerminalIdentity . hostCleanupRunnerIntent

hostCleanupRunnerReadyPermitId
  :: HostCleanupRunnerContext -> LocalCompletionPermitId
hostCleanupRunnerReadyPermitId = internalRunnerReadyPermitId

hostCleanupRunnerReadyReportDigest
  :: HostCleanupRunnerContext -> CascadeReportDigest
hostCleanupRunnerReadyReportDigest = internalRunnerReadyReportDigest

-- | Positively observed final completion read-back.
--
-- The constructor is reachable only inside this library, because
-- 'CascadeCompletionReceiptObservation' is Cabal-hidden and no exposed module
-- can name it; the one producer is
-- "Prodbox.Lifecycle.HostCleanupCompletion", the separate observation of the
-- preserved cleanup journal.  Holding one still authorizes nothing:
-- 'validateCompletionReadBack' rebuilds the expected completion proof from the
-- run's own readiness and absence evidence and refuses any read-back that does
-- not equal it.
data HostCleanupCompletionReadBack = HostCleanupCompletionReadBack
  { hostCompletionReadBackRunId :: !CleanupRunId
  , hostCompletionReadBackGraphDigest :: !CleanupDigest
  , hostCompletionReadBackScope :: !ObservationEvidenceScope
  , hostCompletionReadBackOperationId :: !CleanupOperationId
  , hostCompletionReadBackReceiptDigest :: !CleanupDigest
  , hostCompletionReadBackObservation :: !CascadeCompletionReceiptObservation
  , hostCompletionReadBackEvidence :: !CascadeCompleteEvidence
  }
  deriving (Eq, Show)

-- | All side effects are injected at this one boundary.  Each mutation gets
-- the stable context derived from the durable intent.  The corresponding
-- observer is distinct and mandatory.
data HostCleanupRunnerEffects m = HostCleanupRunnerEffects
  { hostRunnerAcceptAuthority
      :: HostCleanupRunnerContext
      -> ReadyToUninstallEvidence
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackAuthorityAcceptance
      :: HostCleanupRunnerContext
      -> m (Either Text ReadyToUninstallEvidence)
  , hostRunnerRunLocalUninstall
      :: HostCleanupRunnerContext
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackLocalAbsence
      :: HostCleanupRunnerContext
      -> ReadyToUninstallEvidence
      -> m (Either Text (Maybe LocalUninstallEvidence))
  , hostRunnerReestablishBootstrapRecovery
      :: HostCleanupRunnerContext
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackBootstrapRecovery
      :: HostCleanupRunnerContext
      -> m (Either Text HostRecoveryPlaneCheck)
  , hostRunnerReestablishLifecycleAuthority
      :: HostCleanupRunnerContext
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackLifecycleAuthority
      :: HostCleanupRunnerContext
      -> m (Either Text ReadyToUninstallEvidence)
  , hostRunnerReconcileCleanupRun
      :: HostCleanupRunnerContext
      -> LocalUninstallEvidence
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackCleanupRun
      :: HostCleanupRunnerContext
      -> m (Either Text CleanupRun)
  , hostRunnerCommitCompletionReceipt
      :: HostCleanupRunnerContext
      -> LocalUninstallEvidence
      -> m HostCleanupEffectOutcome
  , hostRunnerReadBackCompletionReceipt
      :: HostCleanupRunnerContext
      -> m (Either Text HostCleanupCompletionReadBack)
  }

data HostCleanupRunnerResult = HostCleanupRunnerComplete
  { completedHostCleanupIntent :: !HostCleanupIntent
  , completedHostCleanupReceiptDigest :: !CleanupDigest
  }
  deriving (Eq, Show)

data HostCleanupRunnerBinding
  = HostCleanupReadyRunBinding
  | HostCleanupReadyGraphBinding
  | HostCleanupReadyScopeBinding
  | HostCleanupReadyPermitBinding
  | HostCleanupUninstallOperationBinding
  | HostCleanupReadyCompletionOperationBinding
  | HostCleanupDurableReadyBinding
  | HostCleanupAuthorityProofBinding
  | HostCleanupLocalAbsenceProofBinding
  | HostCleanupRecoveryScopeBinding
  | HostCleanupRunReadBackIdBinding
  | HostCleanupRunReadBackGraphBinding
  | HostCleanupCompletionRunBinding
  | HostCleanupCompletionGraphBinding
  | HostCleanupCompletionScopeBinding
  | HostCleanupCompletionOperationBinding
  | HostCleanupCompletionProofBinding
  deriving (Eq, Show)

data HostCleanupRunnerError
  = HostCleanupRunnerIntentError !HostCleanupIntentError
  | HostCleanupRunnerIntentMissing
  | HostCleanupRunnerExecutionLeaseUnavailable !HostCleanupIntentError
  | HostCleanupRunnerReadyBindingMissing
  | HostCleanupRunnerPreparedReadBackMismatch
  | HostCleanupRunnerBindingMismatch !HostCleanupRunnerBinding
  | HostCleanupRunnerOperationMissing !Text
  | HostCleanupRunnerObservationFailed !HostCleanupRunnerStep !Text
  | HostCleanupRunnerRecoveryUnavailable !ObservationFailure
  | HostCleanupRunnerRecoveryUnobservable !ObservationFailure
  | HostCleanupRunnerCompletionEvidenceInvalid !CascadeEvidenceError
  | HostCleanupRunnerCompletionReceiptNotObserved
  | HostCleanupRunnerCompletionReceiptDigestMissing
  deriving (Eq, Show)

-- | Persist a Prepared intent and independently observe the exact canonical
-- value before any caller is allowed to invoke a cluster/config mutation.
-- An exact read-back also resolves a lost response from the prepare write.
prepareHostCleanupRunner
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupRunnerError HostCleanupIntent)
prepareHostCleanupRunner store expected = do
  prepared <- prepareHostCleanupIntent store expected
  observed <- observeHostCleanupIntent store
  pure $ case observed of
    Right (Just actual)
      | actual == expected
          && hostCleanupIntentPhase actual == HostCleanupPrepared ->
          Right actual
      | otherwise -> Left HostCleanupRunnerPreparedReadBackMismatch
    Right Nothing -> case prepared of
      Left err -> Left (HostCleanupRunnerIntentError err)
      Right _ -> Left HostCleanupRunnerIntentMissing
    Left err -> Left (HostCleanupRunnerIntentError err)

-- | Bind the opaque Authority readiness witness to the complete host record.
-- The uninstall operation is selected from the sealed CleanupRun graph, not
-- from caller text.
validateHostCleanupReady
  :: HostCleanupIntent
  -> ReadyToUninstallEvidence
  -> Either HostCleanupRunnerError HostCleanupRunnerContext
validateHostCleanupReady intent ready = do
  requireBinding
    HostCleanupReadyRunBinding
    (readyToUninstallRunId ready == hostCleanupRunId intent)
  requireBinding
    HostCleanupReadyGraphBinding
    (readyToUninstallGraphDigest ready == hostCleanupGraphDigest intent)
  requireBinding
    HostCleanupReadyScopeBinding
    ( readyToUninstallScope ready
        == hostCleanupObservationEvidenceScope (hostCleanupScope intent)
    )
  requireBinding
    HostCleanupReadyPermitBinding
    ( localCompletionPermitIdText (readyToUninstallPermitId ready)
        == hostTerminalPermitIdText
          ( hostCleanupTerminalPermitId
              (hostCleanupTerminalIdentity intent)
          )
    )
  uninstallOperation <-
    operationForNode "lifecycle/cascade/uninstall-local" intent
  completionOperation <-
    operationForNode "lifecycle/cascade/commit-completion" intent
  let readyOperations = readyToUninstallOperationReferences ready
  requireBinding
    HostCleanupUninstallOperationBinding
    ( cascadeLocalUninstallOperationId readyOperations == uninstallOperation
        && uninstallOperation
          == hostCleanupTerminalOperationId
            (hostCleanupTerminalIdentity intent)
    )
  requireBinding
    HostCleanupReadyCompletionOperationBinding
    ( cascadeLocalCompletionOperationId readyOperations
        == completionOperation
    )
  case hostCleanupReadyBinding intent of
    Nothing -> Right ()
    Just _ -> do
      durableMatches <-
        either
          (Left . HostCleanupRunnerIntentError)
          Right
          (hostCleanupReadyMatches intent ready)
      requireBinding
        HostCleanupDurableReadyBinding
        durableMatches
  Right
    HostCleanupRunnerContext
      { internalRunnerIntent = intent
      , internalRunnerUninstallOperationId = uninstallOperation
      , internalRunnerCompletionOperationId = completionOperation
      , internalRunnerReadyPermitId = readyToUninstallPermitId ready
      , internalRunnerReadyReportDigest = readyToUninstallReportDigest ready
      }

runHostCleanupRunner
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> ReadyToUninstallEvidence
  -> IO (Either HostCleanupRunnerError HostCleanupRunnerResult)
runHostCleanupRunner store effects ready =
  runHostCleanupRunnerUnderLease store effects (Just ready) toCompletion id

-- | Resume solely from the positively read-back host intent.  There is no
-- raw byte or durable-binding ingress on this API: an unbound Prepared intent
-- refuses until the initial caller supplies the opaque Ready proof through
-- 'runHostCleanupRunner'.
resumeHostCleanupRunner
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> IO (Either HostCleanupRunnerError HostCleanupRunnerResult)
resumeHostCleanupRunner store effects =
  runHostCleanupRunnerUnderLease store effects Nothing toCompletion id

-- | What one durable phase of the runner did.
--
-- The two arms are the only outcomes a single phase has: it either made the
-- exact transition its action selects, or the run was already finished and the
-- receipt digest is available.  There is deliberately no \"nothing happened\"
-- arm: every other case is a typed 'HostCleanupRunnerError'.
data HostCleanupRunnerProgress
  = HostCleanupRunnerAdvanced !HostCleanupIntentPhase
  | HostCleanupRunnerCompleted !HostCleanupRunnerResult
  deriving (Eq, Show)

-- | Perform exactly one durable phase and stop.
--
-- Sprint 4.86: the compiled cascade graph reaches the destructive host
-- boundary through /separate/ nodes, and a node interpreter that ran the whole
-- runner would collapse those nodes into one — the durable run would record a
-- single node as having performed every later node's effect, and a resume
-- would have nothing left to attribute a failure to.  Stepping keeps the
-- durable cleanup run and the durable host intent advancing together.
--
-- The execution lease is taken for the step alone, exactly as the whole-run
-- entrypoints take it for the run: two concurrent hosts cannot interleave
-- phases, and a step that ends still leaves a resumable intent behind.
stepHostCleanupRunner
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> Maybe ReadyToUninstallEvidence
  -> IO (Either HostCleanupRunnerError HostCleanupRunnerProgress)
stepHostCleanupRunner store effects suppliedReady =
  runHostCleanupRunnerUnderLease
    store
    effects
    suppliedReady
    (\_ _ phase -> pure (Right (HostCleanupRunnerAdvanced phase)))
    HostCleanupRunnerCompleted

-- | Continue after an advance by re-entering the driver, which is what makes
-- the whole-run entrypoints a loop over the same single-phase body.
toCompletion
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> HostCleanupIntentPhase
  -> IO (Either HostCleanupRunnerError HostCleanupRunnerResult)
toCompletion store effects _ =
  runHostCleanupRunnerWithReady store effects Nothing toCompletion id

runHostCleanupRunnerUnderLease
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> Maybe ReadyToUninstallEvidence
  -> ( HostCleanupIntentStore
       -> HostCleanupRunnerEffects IO
       -> HostCleanupIntentPhase
       -> IO (Either HostCleanupRunnerError result)
     )
  -> (HostCleanupRunnerResult -> result)
  -> IO (Either HostCleanupRunnerError result)
runHostCleanupRunnerUnderLease store effects suppliedReady afterAdvance onFinished = do
  observed <- observeHostCleanupIntentForResume store
  case observed of
    Left err -> pure (Left (HostCleanupRunnerIntentError err))
    Right Nothing -> pure (Left HostCleanupRunnerIntentMissing)
    Right (Just observedIntent) -> do
      leased <-
        withHostCleanupExecutionLease
          store
          observedIntent
          ( runHostCleanupRunnerWithReady
              store
              effects
              suppliedReady
              afterAdvance
              onFinished
          )
      pure $ case leased of
        Left err -> Left (HostCleanupRunnerExecutionLeaseUnavailable err)
        Right result -> result

runHostCleanupRunnerWithReady
  :: HostCleanupIntentStore
  -> HostCleanupRunnerEffects IO
  -> Maybe ReadyToUninstallEvidence
  -> ( HostCleanupIntentStore
       -> HostCleanupRunnerEffects IO
       -> HostCleanupIntentPhase
       -> IO (Either HostCleanupRunnerError result)
     )
  -> (HostCleanupRunnerResult -> result)
  -> IO (Either HostCleanupRunnerError result)
runHostCleanupRunnerWithReady store effects suppliedReady afterAdvance onFinished = do
  observed <- observeHostCleanupIntentForResume store
  case observed of
    Left err -> pure (Left (HostCleanupRunnerIntentError err))
    Right Nothing -> pure (Left HostCleanupRunnerIntentMissing)
    Right (Just observedIntent) -> do
      selected <- selectDurableReady observedIntent
      case selected of
        Left err -> pure (Left err)
        Right durableIntent -> resume durableIntent
 where
  selectDurableReady observedIntent = case suppliedReady of
    Nothing -> case restoreObservedHostCleanupReady observedIntent of
      Left HostCleanupIntentReadyBindingRequired {} ->
        pure (Left HostCleanupRunnerReadyBindingMissing)
      Left err -> pure (Left (HostCleanupRunnerIntentError err))
      Right _ -> pure (Right observedIntent)
    Just ready -> case hostCleanupReadyBinding intent of
      Just _ -> case hostCleanupReadyMatches intent ready of
        Left err -> pure (Left (HostCleanupRunnerIntentError err))
        Right True -> pure (Right observedIntent)
        Right False ->
          pure
            ( Left
                ( HostCleanupRunnerBindingMismatch
                    HostCleanupDurableReadyBinding
                )
            )
      Nothing -> case bindHostCleanupReady intent ready of
        Left err -> pure (Left (HostCleanupRunnerIntentError err))
        Right expected -> do
          persisted <- persistHostCleanupReady store intent ready
          readBack <- observeHostCleanupIntentForResume store
          pure $ case readBack of
            Right (Just actualObserved)
              | observedHostCleanupIntent actualObserved == expected ->
                  case restoreObservedHostCleanupReady actualObserved of
                    Left err -> Left (HostCleanupRunnerIntentError err)
                    Right restored
                      | restored == ready -> Right actualObserved
                      | otherwise ->
                          Left
                            ( HostCleanupRunnerBindingMismatch
                                HostCleanupDurableReadyBinding
                            )
            Right (Just _) -> Left HostCleanupRunnerPreparedReadBackMismatch
            Right Nothing -> case persisted of
              Left err -> Left (HostCleanupRunnerIntentError err)
              Right _ -> Left HostCleanupRunnerIntentMissing
            Left err -> Left (HostCleanupRunnerIntentError err)
     where
      intent = observedHostCleanupIntent observedIntent

  resume observedIntent = case restoreObservedHostCleanupReady observedIntent of
    Left HostCleanupIntentReadyBindingRequired {} ->
      pure (Left HostCleanupRunnerReadyBindingMissing)
    Left err -> pure (Left (HostCleanupRunnerIntentError err))
    Right selectedReady -> case validateHostCleanupReady intent selectedReady of
      Left err -> pure (Left err)
      Right context -> case nextHostCleanupRunnerAction intent of
        HostCleanupAcceptAuthority -> do
          attempt <- hostRunnerAcceptAuthority effects context selectedReady
          readBack <- hostRunnerReadBackAuthorityAcceptance effects context
          case requireExactReady
            HostCleanupReadBackAuthorityAcceptanceStep
            attempt
            selectedReady
            readBack of
            Left err -> pure (Left err)
            Right () ->
              advanceAndResume intent HostCleanupAuthorityAccepted Nothing
        HostCleanupArmTerminal ->
          advanceAndResume intent HostCleanupTerminalArmed Nothing
        HostCleanupIssueLocalUninstall -> do
          beforeAttempt <-
            hostRunnerReadBackLocalAbsence effects context selectedReady
          case requireOptionalLocalAbsence selectedReady beforeAttempt of
            Left err -> pure (Left err)
            Right (Just _) ->
              -- A prior attempt may have removed the foundation and then lost
              -- its journal response.  Exact absence closes that ambiguity;
              -- never issue the destructive operation again.
              advanceAndResume intent HostCleanupLocalUninstallIssued Nothing
            Right Nothing -> do
              attempt <- hostRunnerRunLocalUninstall effects context
              readBack <-
                hostRunnerReadBackLocalAbsence effects context selectedReady
              case requireExactLocalAbsence attempt selectedReady readBack of
                Left err -> pure (Left err)
                Right _ ->
                  advanceAndResume intent HostCleanupLocalUninstallIssued Nothing
        HostCleanupRecordLocalAbsence -> do
          -- The separate absence node.  It never issues the destructive
          -- operation: a phase that could re-issue would make the record of
          -- absence and the act of removal one node again.
          local <- readBackLocal context selectedReady
          case local of
            Left err -> pure (Left err)
            Right _ ->
              advanceAndResume intent HostCleanupLocalAbsenceRecorded Nothing
        HostCleanupRecoverAuthority -> do
          local <- readBackLocal context selectedReady
          case local of
            Left err -> pure (Left err)
            Right localEvidence -> do
              recovered <-
                recoverAuthority context selectedReady localEvidence
              case recovered of
                Left err -> pure (Left err)
                Right () ->
                  advanceAndResume
                    intent
                    HostCleanupAuthorityReconciled
                    Nothing
        HostCleanupCommitCompletion -> do
          local <- readBackLocal context selectedReady
          case local of
            Left err -> pure (Left err)
            Right localEvidence -> do
              committed <-
                commitCompletion context selectedReady localEvidence
              case committed of
                Left err -> pure (Left err)
                Right _ ->
                  advanceAndResume
                    intent
                    HostCleanupCompletionCommitted
                    Nothing
        HostCleanupVerifyCompletion -> do
          verified <- verifyCompletion context selectedReady
          case verified of
            Left err -> pure (Left err)
            Right readBack ->
              advanceAndResume
                intent
                HostCleanupComplete
                (Just (hostCompletionReadBackReceiptDigest readBack))
        HostCleanupFinished -> case hostCleanupCompletionReceiptDigest intent of
          Nothing -> pure (Left HostCleanupRunnerCompletionReceiptDigestMissing)
          Just digest ->
            pure
              ( Right
                  ( onFinished
                      HostCleanupRunnerComplete
                        { completedHostCleanupIntent = intent
                        , completedHostCleanupReceiptDigest = digest
                        }
                  )
              )
   where
    intent = observedHostCleanupIntent observedIntent

  advanceAndResume intent phase receipt = do
    advanced <- persistExactTransition store intent phase receipt
    case advanced of
      Left err -> pure (Left err)
      Right _ -> afterAdvance store effects phase

  readBackLocal context selectedReady = do
    readBack <- hostRunnerReadBackLocalAbsence effects context selectedReady
    pure (requireExactLocalAbsenceReadBack selectedReady readBack)

  recoverAuthority context selectedReady localEvidence = do
    recoveryAttempt <- hostRunnerReestablishBootstrapRecovery effects context
    recovery <- hostRunnerReadBackBootstrapRecovery effects context
    case requireRecovery recoveryAttempt context recovery of
      Left err -> pure (Left err)
      Right () -> do
        authorityAttempt <- hostRunnerReestablishLifecycleAuthority effects context
        authority <- hostRunnerReadBackLifecycleAuthority effects context
        case requireExactReady
          HostCleanupReadBackAuthorityStep
          authorityAttempt
          selectedReady
          authority of
          Left err -> pure (Left err)
          Right () -> do
            runAttempt <-
              hostRunnerReconcileCleanupRun effects context localEvidence
            runReadBack <- hostRunnerReadBackCleanupRun effects context
            pure (requireRunReadBack runAttempt context runReadBack)

  commitCompletion context selectedReady localEvidence = do
    receiptAttempt <-
      hostRunnerCommitCompletionReceipt effects context localEvidence
    receipt <- hostRunnerReadBackCompletionReceipt effects context
    pure
      ( void
          ( requireCompletionReadBack
              HostCleanupReadBackCompletionStep
              receiptAttempt
              context
              selectedReady
              localEvidence
              receipt
          )
      )

  verifyCompletion context selectedReady = do
    local <- readBackLocal context selectedReady
    case local of
      Left err -> pure (Left err)
      Right localEvidence -> do
        recovery <- hostRunnerReadBackBootstrapRecovery effects context
        case requireRecoveryReadBack context recovery of
          Left err -> pure (Left err)
          Right () -> do
            authority <- hostRunnerReadBackLifecycleAuthority effects context
            case requireExactReadyReadBack
              HostCleanupReadBackAuthorityStep
              selectedReady
              authority of
              Left err -> pure (Left err)
              Right () -> do
                runReadBack <- hostRunnerReadBackCleanupRun effects context
                case requireRunReadBackOnly context runReadBack of
                  Left err -> pure (Left err)
                  Right () -> do
                    receipt <- hostRunnerReadBackCompletionReceipt effects context
                    pure
                      ( requireCompletionReadBackOnly
                          context
                          selectedReady
                          localEvidence
                          receipt
                      )

persistExactTransition
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> HostCleanupIntentPhase
  -> Maybe CleanupDigest
  -> IO (Either HostCleanupRunnerError HostCleanupIntent)
persistExactTransition store expected phase receipt =
  case advanceHostCleanupIntent phase receipt expected of
    Left err -> pure (Left (HostCleanupRunnerIntentError err))
    Right candidate -> do
      transitioned <- transitionHostCleanupIntent store expected phase receipt
      observed <- observeHostCleanupIntent store
      pure $ case observed of
        Right (Just actual)
          | actual == candidate -> Right actual
          | otherwise -> Left HostCleanupRunnerPreparedReadBackMismatch
        Right Nothing -> case transitioned of
          Left err -> Left (HostCleanupRunnerIntentError err)
          Right _ -> Left HostCleanupRunnerIntentMissing
        Left err -> Left (HostCleanupRunnerIntentError err)

operationForNode
  :: Text
  -> HostCleanupIntent
  -> Either HostCleanupRunnerError CleanupOperationId
operationForNode expectedNode intent =
  case find matchingNode (cleanupGraphNodes (cleanupRunGraph (hostCleanupRun intent))) of
    Nothing -> Left (HostCleanupRunnerOperationMissing expectedNode)
    Just node -> Right (cleanupNodeOperationId node)
 where
  matchingNode node = cleanupNodeIdText (cleanupNodeId node) == expectedNode

requireBinding
  :: HostCleanupRunnerBinding
  -> Bool
  -> Either HostCleanupRunnerError ()
requireBinding binding matches
  | matches = Right ()
  | otherwise = Left (HostCleanupRunnerBindingMismatch binding)

requireExactReady
  :: HostCleanupRunnerStep
  -> HostCleanupEffectOutcome
  -> ReadyToUninstallEvidence
  -> Either Text ReadyToUninstallEvidence
  -> Either HostCleanupRunnerError ()
requireExactReady step attempt expected observed = case observed of
  Left detail -> mutationObservationFailure step attempt detail
  Right actual ->
    requireBinding HostCleanupAuthorityProofBinding (actual == expected)

requireExactReadyReadBack
  :: HostCleanupRunnerStep
  -> ReadyToUninstallEvidence
  -> Either Text ReadyToUninstallEvidence
  -> Either HostCleanupRunnerError ()
requireExactReadyReadBack step expected observed = case observed of
  Left detail -> Left (HostCleanupRunnerObservationFailed step detail)
  Right actual ->
    requireBinding HostCleanupAuthorityProofBinding (actual == expected)

requireExactLocalAbsence
  :: HostCleanupEffectOutcome
  -> ReadyToUninstallEvidence
  -> Either Text (Maybe LocalUninstallEvidence)
  -> Either HostCleanupRunnerError LocalUninstallEvidence
requireExactLocalAbsence attempt ready observed = case observed of
  Left detail ->
    mutationObservationFailure
      HostCleanupReadBackLocalAbsenceStep
      attempt
      detail
  Right Nothing ->
    mutationObservationFailure
      HostCleanupReadBackLocalAbsenceStep
      attempt
      "local RKE2 foundation is still present"
  Right (Just evidence) -> validateLocalEvidence ready evidence

requireExactLocalAbsenceReadBack
  :: ReadyToUninstallEvidence
  -> Either Text (Maybe LocalUninstallEvidence)
  -> Either HostCleanupRunnerError LocalUninstallEvidence
requireExactLocalAbsenceReadBack ready observed = case observed of
  Left detail ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackLocalAbsenceStep
          detail
      )
  Right Nothing ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackLocalAbsenceStep
          "local RKE2 foundation is still present"
      )
  Right (Just evidence) -> validateLocalEvidence ready evidence

requireOptionalLocalAbsence
  :: ReadyToUninstallEvidence
  -> Either Text (Maybe LocalUninstallEvidence)
  -> Either HostCleanupRunnerError (Maybe LocalUninstallEvidence)
requireOptionalLocalAbsence ready observed = case observed of
  Left detail ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackLocalAbsenceStep
          detail
      )
  Right Nothing -> Right Nothing
  Right (Just evidence) -> Just <$> validateLocalEvidence ready evidence

validateLocalEvidence
  :: ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> Either HostCleanupRunnerError LocalUninstallEvidence
validateLocalEvidence ready evidence = do
  expected <-
    either
      (Left . HostCleanupRunnerCompletionEvidenceInvalid)
      Right
      ( mkLocalUninstallEvidence
          ready
          LocalFoundationObservation
            { localFoundationObservationScope = readyToUninstallScope ready
            , localFoundationObservationResult =
                LocalFoundationAbsent (localUninstallAbsenceEvidence evidence)
            }
      )
  requireBinding HostCleanupLocalAbsenceProofBinding (evidence == expected)
  Right evidence

requireRecovery
  :: HostCleanupEffectOutcome
  -> HostCleanupRunnerContext
  -> Either Text HostRecoveryPlaneCheck
  -> Either HostCleanupRunnerError ()
requireRecovery attempt context observed = case observed of
  Left detail ->
    mutationObservationFailure HostCleanupReadBackRecoveryStep attempt detail
  Right recovery -> validateRecovery context recovery

requireRecoveryReadBack
  :: HostCleanupRunnerContext
  -> Either Text HostRecoveryPlaneCheck
  -> Either HostCleanupRunnerError ()
requireRecoveryReadBack context observed = case observed of
  Left detail ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackRecoveryStep
          detail
      )
  Right recovery -> validateRecovery context recovery

validateRecovery
  :: HostCleanupRunnerContext
  -> HostRecoveryPlaneCheck
  -> Either HostCleanupRunnerError ()
validateRecovery context recovery = do
  requireBinding
    HostCleanupRecoveryScopeBinding
    ( hostRecoveryPlaneCheckScope recovery
        == hostCleanupRunnerObservationScope context
    )
  case hostRecoveryPlaneCheckResult recovery of
    HostRecoveryPlaneAvailable -> Right ()
    HostRecoveryPlaneUnavailable failure ->
      Left (HostCleanupRunnerRecoveryUnavailable failure)
    HostRecoveryPlaneUnobservable failure ->
      Left (HostCleanupRunnerRecoveryUnobservable failure)

requireRunReadBack
  :: HostCleanupEffectOutcome
  -> HostCleanupRunnerContext
  -> Either Text CleanupRun
  -> Either HostCleanupRunnerError ()
requireRunReadBack attempt context observed = case observed of
  Left detail ->
    mutationObservationFailure HostCleanupReadBackRunStep attempt detail
  Right run -> validateRunReadBack context run

requireRunReadBackOnly
  :: HostCleanupRunnerContext
  -> Either Text CleanupRun
  -> Either HostCleanupRunnerError ()
requireRunReadBackOnly context observed = case observed of
  Left detail ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackRunStep
          detail
      )
  Right run -> validateRunReadBack context run

validateRunReadBack
  :: HostCleanupRunnerContext
  -> CleanupRun
  -> Either HostCleanupRunnerError ()
validateRunReadBack context observed = do
  requireBinding
    HostCleanupRunReadBackIdBinding
    (cleanupRunId observed == hostCleanupRunnerRunId context)
  requireBinding
    HostCleanupRunReadBackGraphBinding
    ( cleanupRunGraphDigest observed == hostCleanupRunnerGraphDigest context
        && cleanupRunGraph observed
          == cleanupRunGraph (hostCleanupRun (hostCleanupRunnerIntent context))
    )

requireCompletionReadBack
  :: HostCleanupRunnerStep
  -> HostCleanupEffectOutcome
  -> HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> Either Text HostCleanupCompletionReadBack
  -> Either HostCleanupRunnerError HostCleanupCompletionReadBack
requireCompletionReadBack step attempt context ready local observed = case observed of
  Left detail -> mutationObservationFailure step attempt detail
  Right readBack -> validateCompletionReadBack context ready local readBack

requireCompletionReadBackOnly
  :: HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> Either Text HostCleanupCompletionReadBack
  -> Either HostCleanupRunnerError HostCleanupCompletionReadBack
requireCompletionReadBackOnly context ready local observed = case observed of
  Left detail ->
    Left
      ( HostCleanupRunnerObservationFailed
          HostCleanupReadBackCompletionStep
          detail
      )
  Right readBack -> validateCompletionReadBack context ready local readBack

validateCompletionReadBack
  :: HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> HostCleanupCompletionReadBack
  -> Either HostCleanupRunnerError HostCleanupCompletionReadBack
validateCompletionReadBack context ready local readBack = do
  requireBinding
    HostCleanupCompletionRunBinding
    (hostCompletionReadBackRunId readBack == hostCleanupRunnerRunId context)
  requireBinding
    HostCleanupCompletionGraphBinding
    ( hostCompletionReadBackGraphDigest readBack
        == hostCleanupRunnerGraphDigest context
    )
  requireBinding
    HostCleanupCompletionScopeBinding
    ( hostCompletionReadBackScope readBack
        == hostCleanupRunnerObservationScope context
    )
  requireBinding
    HostCleanupCompletionOperationBinding
    ( hostCompletionReadBackOperationId readBack
        == hostCleanupRunnerCompletionOperationId context
    )
  let receipt = hostCompletionReadBackObservation readBack
      durable = cascadeCompletionReceipt receipt
  if durableReceiptObservationResult durable == DurableReceiptObserved
    then Right ()
    else Left HostCleanupRunnerCompletionReceiptNotObserved
  if durableReceiptObservationKind durable == CascadeCompletionReceipt
    then Right ()
    else Left HostCleanupRunnerCompletionReceiptNotObserved
  requireBinding
    HostCleanupCompletionGraphBinding
    ( durableReceiptObservationGraphDigest durable
        == hostCleanupRunnerGraphDigest context
    )
  requireBinding
    HostCleanupCompletionScopeBinding
    ( durableReceiptObservationScope durable
        == hostCleanupRunnerObservationScope context
    )
  expectedEvidence <-
    either
      (Left . HostCleanupRunnerCompletionEvidenceInvalid)
      Right
      (mkCascadeCompleteEvidence ready local receipt)
  requireBinding
    HostCleanupCompletionProofBinding
    (hostCompletionReadBackEvidence readBack == expectedEvidence)
  requireBinding
    HostCleanupCompletionRunBinding
    (cascadeCompleteRunId expectedEvidence == hostCleanupRunnerRunId context)
  requireBinding
    HostCleanupCompletionGraphBinding
    ( cascadeCompleteGraphDigest expectedEvidence
        == hostCleanupRunnerGraphDigest context
    )
  requireBinding
    HostCleanupReadyPermitBinding
    ( cascadeCompletePermitId expectedEvidence
        == hostCleanupRunnerReadyPermitId context
    )
  requireBinding
    HostCleanupCompletionProofBinding
    ( cascadeCompleteReportDigest expectedEvidence
        == hostCleanupRunnerReadyReportDigest context
    )
  Right readBack

mutationObservationFailure
  :: HostCleanupRunnerStep
  -> HostCleanupEffectOutcome
  -> Text
  -> Either HostCleanupRunnerError value
mutationObservationFailure step attempt detail =
  Left
    ( HostCleanupRunnerObservationFailed
        step
        (renderAttempt attempt <> ": " <> detail)
    )

renderAttempt :: HostCleanupEffectOutcome -> Text
renderAttempt outcome = case outcome of
  HostCleanupEffectApplied -> "mutation applied; read-back failed"
  HostCleanupEffectResponseLost detail ->
    "mutation response lost (" <> detail <> "); read-back failed"
  HostCleanupEffectRefused detail ->
    "mutation refused (" <> detail <> "); read-back failed"

-- | Fixed package-owned runner regression.  Positive Ready/local/completion
-- proofs are created and consumed entirely inside the hidden evidence owner;
-- callers receive only these non-authorizing booleans.
data HostCleanupRunnerRegression = HostCleanupRunnerRegression
  { hostCleanupRunnerRegressionUnboundRefused :: !Bool
  , hostCleanupRunnerRegressionFullTopology :: !Bool
  , hostCleanupRunnerRegressionResponseLossRecovered :: !Bool
  , hostCleanupRunnerRegressionConfirmedAbsenceNotRepeated :: !Bool
  , hostCleanupRunnerRegressionWrongReadyRefused :: !Bool
  , hostCleanupRunnerRegressionMissingCompletionRefused :: !Bool
  , hostCleanupRunnerRegressionConcurrentLeaseFenced :: !Bool
  , hostCleanupRunnerRegressionSteppedTopology :: !Bool
  , hostCleanupRunnerRegressionStepStopsAtOnePhase :: !Bool
  }

fixedHostCleanupRunnerRegression
  :: IO (Either Text HostCleanupRunnerRegression)
fixedHostCleanupRunnerRegression =
  case withFixedCascadeEvidenceFixtureInternal
    ( \_ run ready local complete ->
        withCascadeEvidenceFixtureForRunInternal
          "cleanup-run/host-runner-fixed-other"
          ( \_ _ otherReady _ _ ->
              runFixedHostCleanupRunnerRegression
                run
                ready
                local
                complete
                otherReady
          )
    ) of
    Left err -> pure (Left err)
    Right (Left err) -> pure (Left err)
    Right (Right action) -> action

runFixedHostCleanupRunnerRegression
  :: CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> ReadyToUninstallEvidence
  -> IO (Either Text HostCleanupRunnerRegression)
runFixedHostCleanupRunnerRegression run ready local complete otherReady =
  case fixedRunnerIntent run ready of
    Left err -> pure (Left err)
    Right intent ->
      withSystemTempDirectory "prodbox-host-runner-fixed" $ \temporaryRoot -> do
        unbound <- fixedUnboundScenario temporaryRoot intent run ready local complete
        full <-
          fixedSuccessfulScenario
            (temporaryRoot </> "full")
            intent
            run
            ready
            local
            complete
            HostCleanupEffectApplied
        responseLoss <-
          fixedSuccessfulScenario
            (temporaryRoot </> "response-loss")
            intent
            run
            ready
            local
            complete
            (HostCleanupEffectResponseLost "fixed response loss")
        notRepeated <-
          fixedNoRepeatScenario temporaryRoot intent run ready local complete
        wrongReady <-
          fixedWrongReadyScenario temporaryRoot intent run ready local complete otherReady
        missingCompletion <-
          fixedMissingCompletionScenario temporaryRoot intent run ready local complete
        leaseFenced <-
          fixedConcurrentLeaseScenario temporaryRoot intent run ready local complete
        (steppedTopology, stoppedAtOnePhase) <-
          fixedSteppedScenario
            (temporaryRoot </> "stepped")
            intent
            run
            ready
            local
            complete
        pure
          ( Right
              HostCleanupRunnerRegression
                { hostCleanupRunnerRegressionUnboundRefused = unbound
                , hostCleanupRunnerRegressionFullTopology = full
                , hostCleanupRunnerRegressionResponseLossRecovered = responseLoss
                , hostCleanupRunnerRegressionConfirmedAbsenceNotRepeated =
                    notRepeated
                , hostCleanupRunnerRegressionWrongReadyRefused = wrongReady
                , hostCleanupRunnerRegressionMissingCompletionRefused =
                    missingCompletion
                , hostCleanupRunnerRegressionConcurrentLeaseFenced = leaseFenced
                , hostCleanupRunnerRegressionSteppedTopology = steppedTopology
                , hostCleanupRunnerRegressionStepStopsAtOnePhase =
                    stoppedAtOnePhase
                }
          )

data FixedHostRunnerState = FixedHostRunnerState
  { fixedHostAuthorityAccepted :: !Bool
  , fixedHostLocalAbsent :: !Bool
  , fixedHostRecoveryAvailable :: !Bool
  , fixedHostAuthorityAvailable :: !Bool
  , fixedHostRunReconciled :: !Bool
  , fixedHostReceiptCommitted :: !Bool
  , fixedHostUninstallCount :: !Int
  , fixedHostEffectCount :: !Int
  }

freshFixedHostRunnerState :: FixedHostRunnerState
freshFixedHostRunnerState =
  FixedHostRunnerState
    { fixedHostAuthorityAccepted = False
    , fixedHostLocalAbsent = False
    , fixedHostRecoveryAvailable = False
    , fixedHostAuthorityAvailable = False
    , fixedHostRunReconciled = False
    , fixedHostReceiptCommitted = False
    , fixedHostUninstallCount = 0
    , fixedHostEffectCount = 0
    }

fixedRunnerIntent
  :: CleanupRun
  -> ReadyToUninstallEvidence
  -> Either Text HostCleanupIntent
fixedRunnerIntent run ready = do
  scope <-
    mapFixedRunnerLeft
      (mkHostCleanupScope (cleanupRunId run) (readyToUninstallScope ready))
  permit <-
    mapFixedRunnerLeft
      ( mkHostTerminalPermitId
          (localCompletionPermitIdText (readyToUninstallPermitId ready))
      )
  let operations = readyToUninstallOperationReferences ready
  mapFixedRunnerLeft
    ( mkHostCleanupIntent
        (cleanupRunId run)
        (cleanupRunGraphDigest run)
        run
        scope
        ( mkHostCleanupTerminalIdentity
            (cascadeLocalUninstallOperationId operations)
            permit
        )
    )

mapFixedRunnerLeft :: (Show err) => Either err value -> Either Text value
mapFixedRunnerLeft result = case result of
  Left err -> Left (Text.pack (show err))
  Right value -> Right value

fixedStoreAt :: FilePath -> IO (Either Text HostCleanupIntentStore)
fixedStoreAt root = do
  createDirectory root
  pure (mapFixedRunnerLeft (mkHostCleanupIntentStore root))

fixedUnboundScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IO Bool
fixedUnboundScenario root intent run ready local complete = do
  storeResult <- fixedStoreAt (root </> "unbound")
  case storeResult of
    Left _ -> pure False
    Right store -> do
      prepared <- prepareHostCleanupRunner store intent
      state <- newIORef freshFixedHostRunnerState
      resumed <-
        resumeHostCleanupRunner
          store
          (fixedHostRunnerEffects run ready local complete state HostCleanupEffectApplied False)
      finalState <- readIORef state
      pure
        ( isRightRunner prepared
            && resumed == Left HostCleanupRunnerReadyBindingMissing
            && fixedHostEffectCount finalState == 0
        )

fixedSuccessfulScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> HostCleanupEffectOutcome
  -> IO Bool
fixedSuccessfulScenario root intent run ready local complete outcome = do
  storeResult <- fixedStoreAt root
  case storeResult of
    Left _ -> pure False
    Right store -> do
      prepared <- prepareHostCleanupRunner store intent
      state <- newIORef freshFixedHostRunnerState
      result <-
        runHostCleanupRunner
          store
          (fixedHostRunnerEffects run ready local complete state outcome False)
          ready
      finalState <- readIORef state
      pure
        ( isRightRunner prepared
            && isCompletedWith (cleanupRunGraphDigest run) result
            && fixedHostUninstallCount finalState == 1
            && fixedHostReceiptCommitted finalState
        )

-- | Drive the same successful topology one phase at a time.
--
-- The two facts it measures are different.  The first is that stepping reaches
-- the same completion the whole-run entrypoint reaches, over the same effects
-- and with the destructive uninstall still issued exactly once — stepping is a
-- different /caller/, not a different protocol.  The second is that one step
-- advances one phase: the first step over a Prepared intent leaves the durable
-- record at `AuthorityAccepted` and goes no further, which is what lets the
-- compiled graph attribute each node's effect to that node.
fixedSteppedScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IO (Bool, Bool)
fixedSteppedScenario root intent run ready local complete = do
  storeResult <- fixedStoreAt root
  case storeResult of
    Left _ -> pure (False, False)
    Right store -> do
      prepared <- prepareHostCleanupRunner store intent
      state <- newIORef freshFixedHostRunnerState
      let effects =
            fixedHostRunnerEffects
              run
              ready
              local
              complete
              state
              HostCleanupEffectApplied
              False
      firstStep <- stepHostCleanupRunner store effects (Just ready)
      afterFirst <- observeHostCleanupIntent store
      steps <- driveSteps store effects (fixedHostCleanupStepBudget :: Int)
      finalState <- readIORef state
      pure
        ( isRightRunner prepared
            && maybe False (isCompletedWith (cleanupRunGraphDigest run) . Right) steps
            && fixedHostUninstallCount finalState == 1
            && fixedHostReceiptCommitted finalState
        , firstStep == Right (HostCleanupRunnerAdvanced HostCleanupAuthorityAccepted)
            && fmap
              (fmap hostCleanupIntentPhase)
              afterFirst
              == Right (Just HostCleanupAuthorityAccepted)
        )
 where
  driveSteps store effects budget
    | budget <= 0 = pure Nothing
    | otherwise = do
        stepped <- stepHostCleanupRunner store effects Nothing
        case stepped of
          Left _ -> pure Nothing
          Right (HostCleanupRunnerCompleted result) -> pure (Just result)
          Right (HostCleanupRunnerAdvanced _) ->
            driveSteps store effects (budget - 1)

-- | One more than the number of durable phases, so a stepping loop that failed
-- to advance terminates instead of spinning.
fixedHostCleanupStepBudget :: Int
fixedHostCleanupStepBudget = 10

fixedNoRepeatScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IO Bool
fixedNoRepeatScenario root intent run ready local complete = do
  storeResult <- fixedStoreAt (root </> "no-repeat")
  case storeResult of
    Left _ -> pure False
    Right store -> do
      armed <- fixedPersistArmed store intent ready
      state <-
        newIORef
          freshFixedHostRunnerState
            { fixedHostAuthorityAccepted = True
            , fixedHostLocalAbsent = True
            }
      result <-
        resumeHostCleanupRunner
          store
          ( fixedHostRunnerEffects
              run
              ready
              local
              complete
              state
              HostCleanupEffectApplied
              False
          )
      finalState <- readIORef state
      pure
        ( armed
            && isCompletedWith (cleanupRunGraphDigest run) result
            && fixedHostUninstallCount finalState == 0
        )

fixedWrongReadyScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> ReadyToUninstallEvidence
  -> IO Bool
fixedWrongReadyScenario root intent run ready local complete otherReady = do
  storeResult <- fixedStoreAt (root </> "wrong-ready")
  case storeResult of
    Left _ -> pure False
    Right store -> do
      prepared <- prepareHostCleanupRunner store intent
      state <- newIORef freshFixedHostRunnerState
      result <-
        runHostCleanupRunner
          store
          ( fixedHostRunnerEffects
              run
              ready
              local
              complete
              state
              HostCleanupEffectApplied
              False
          )
          otherReady
      finalState <- readIORef state
      pure
        (isRightRunner prepared && isLeftRunner result && fixedHostEffectCount finalState == 0)

fixedMissingCompletionScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IO Bool
fixedMissingCompletionScenario root intent run ready local complete = do
  storeResult <- fixedStoreAt (root </> "missing-completion")
  case storeResult of
    Left _ -> pure False
    Right store -> do
      prepared <- prepareHostCleanupRunner store intent
      state <- newIORef freshFixedHostRunnerState
      result <-
        runHostCleanupRunner
          store
          ( fixedHostRunnerEffects
              run
              ready
              local
              complete
              state
              HostCleanupEffectApplied
              True
          )
          ready
      pure (isRightRunner prepared && isMissingCompletion result)

fixedConcurrentLeaseScenario
  :: FilePath
  -> HostCleanupIntent
  -> CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IO Bool
fixedConcurrentLeaseScenario root intent run ready local complete = do
  let canonicalRoot = root </> "lease-canonical"
      aliasRoot = root </> "lease-alias"
  storeResult <- fixedStoreAt canonicalRoot
  case storeResult of
    Left _ -> pure False
    Right store -> do
      createDirectoryLink canonicalRoot aliasRoot
      let aliasStoreResult = mkHostCleanupIntentStore aliasRoot
      armed <- fixedPersistArmed store intent ready
      case aliasStoreResult of
        Left _ -> pure False
        Right aliasStore -> do
          entered <- newEmptyMVar
          release <- newEmptyMVar
          firstState <- newIORef freshFixedHostRunnerState {fixedHostAuthorityAccepted = True}
          secondState <- newIORef freshFixedHostRunnerState
          let baseEffects =
                fixedHostRunnerEffects
                  run
                  ready
                  local
                  complete
                  firstState
                  HostCleanupEffectApplied
                  False
              blockingEffects =
                baseEffects
                  { hostRunnerRunLocalUninstall = \context -> do
                      putMVar entered ()
                      takeMVar release
                      hostRunnerRunLocalUninstall baseEffects context
                  }
          withAsync (resumeHostCleanupRunner store blockingEffects) $ \first -> do
            takeMVar entered
            second <-
              resumeHostCleanupRunner
                aliasStore
                ( fixedHostRunnerEffects
                    run
                    ready
                    local
                    complete
                    secondState
                    HostCleanupEffectApplied
                    False
                )
            putMVar release ()
            firstResult <- wait first
            firstFinal <- readIORef firstState
            secondFinal <- readIORef secondState
            pure
              ( armed
                  && second
                    == Left
                      ( HostCleanupRunnerExecutionLeaseUnavailable
                          HostCleanupIntentExecutionLeaseAlreadyHeld
                      )
                  && isCompletedWith (cleanupRunGraphDigest run) firstResult
                  && fixedHostUninstallCount firstFinal == 1
                  && fixedHostEffectCount secondFinal == 0
              )

fixedPersistArmed
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> ReadyToUninstallEvidence
  -> IO Bool
fixedPersistArmed store intent ready = do
  prepared <- prepareHostCleanupRunner store intent
  case prepared of
    Left _ -> pure False
    Right exact -> do
      bound <- persistHostCleanupReady store exact ready
      case bound of
        Left _ -> pure False
        Right durable -> do
          accepted <-
            transitionHostCleanupIntent
              store
              durable
              HostCleanupAuthorityAccepted
              Nothing
          case accepted of
            Left _ -> pure False
            Right acceptedIntent -> do
              armed <-
                transitionHostCleanupIntent
                  store
                  acceptedIntent
                  HostCleanupTerminalArmed
                  Nothing
              pure (isRightRunner armed)

fixedHostRunnerEffects
  :: CleanupRun
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompleteEvidence
  -> IORef FixedHostRunnerState
  -> HostCleanupEffectOutcome
  -> Bool
  -> HostCleanupRunnerEffects IO
fixedHostRunnerEffects run ready local complete stateRef outcome missingCompletion =
  HostCleanupRunnerEffects
    { hostRunnerAcceptAuthority = \_ _ -> do
        fixedModify stateRef $ \state -> state {fixedHostAuthorityAccepted = True}
        pure outcome
    , hostRunnerReadBackAuthorityAcceptance = \_ -> do
        state <- fixedObserve stateRef
        pure (if fixedHostAuthorityAccepted state then Right ready else Left "not accepted")
    , hostRunnerRunLocalUninstall = \_ -> do
        fixedModify stateRef $ \state ->
          state
            { fixedHostLocalAbsent = True
            , fixedHostRecoveryAvailable = False
            , fixedHostAuthorityAvailable = False
            , fixedHostUninstallCount = fixedHostUninstallCount state + 1
            }
        pure outcome
    , hostRunnerReadBackLocalAbsence = \_ _ -> do
        state <- fixedObserve stateRef
        pure (Right (if fixedHostLocalAbsent state then Just local else Nothing))
    , hostRunnerReestablishBootstrapRecovery = \_ -> do
        fixedModify stateRef $ \state -> state {fixedHostRecoveryAvailable = True}
        pure outcome
    , hostRunnerReadBackBootstrapRecovery = \context -> do
        state <- fixedObserve stateRef
        pure
          ( if fixedHostRecoveryAvailable state
              then
                Right
                  HostRecoveryPlaneCheck
                    { hostRecoveryPlaneCheckScope =
                        hostCleanupRunnerObservationScope context
                    , hostRecoveryPlaneCheckResult = HostRecoveryPlaneAvailable
                    }
              else Left "recovery unavailable"
          )
    , hostRunnerReestablishLifecycleAuthority = \_ -> do
        fixedModify stateRef $ \state -> state {fixedHostAuthorityAvailable = True}
        pure outcome
    , hostRunnerReadBackLifecycleAuthority = \_ -> do
        state <- fixedObserve stateRef
        pure (if fixedHostAuthorityAvailable state then Right ready else Left "authority unavailable")
    , hostRunnerReconcileCleanupRun = \_ _ -> do
        fixedModify stateRef $ \state -> state {fixedHostRunReconciled = True}
        pure outcome
    , hostRunnerReadBackCleanupRun = \_ -> do
        state <- fixedObserve stateRef
        pure (if fixedHostRunReconciled state then Right run else Left "run unavailable")
    , hostRunnerCommitCompletionReceipt = \_ _ -> do
        fixedModify stateRef $ \state -> state {fixedHostReceiptCommitted = True}
        pure outcome
    , hostRunnerReadBackCompletionReceipt = \context -> do
        state <- fixedObserve stateRef
        pure
          ( if missingCompletion
              then Left "completion unavailable"
              else
                if fixedHostReceiptCommitted state
                  then Right (fixedCompletionReadBack context ready complete)
                  else Left "completion missing"
          )
    }

fixedModify
  :: IORef FixedHostRunnerState
  -> (FixedHostRunnerState -> FixedHostRunnerState)
  -> IO ()
fixedModify stateRef update =
  modifyIORef' stateRef $ \state ->
    (update state) {fixedHostEffectCount = fixedHostEffectCount state + 1}

fixedObserve :: IORef FixedHostRunnerState -> IO FixedHostRunnerState
fixedObserve stateRef =
  atomicModifyIORef' stateRef $ \state ->
    let updated = state {fixedHostEffectCount = fixedHostEffectCount state + 1}
     in (updated, updated)

fixedCompletionReadBack
  :: HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> CascadeCompleteEvidence
  -> HostCleanupCompletionReadBack
fixedCompletionReadBack context ready complete =
  HostCleanupCompletionReadBack
    { hostCompletionReadBackRunId = hostCleanupRunnerRunId context
    , hostCompletionReadBackGraphDigest = hostCleanupRunnerGraphDigest context
    , hostCompletionReadBackScope = hostCleanupRunnerObservationScope context
    , hostCompletionReadBackOperationId =
        hostCleanupRunnerCompletionOperationId context
    , hostCompletionReadBackReceiptDigest = hostCleanupRunnerGraphDigest context
    , hostCompletionReadBackObservation =
        CascadeCompletionReceiptObservation
          { cascadeCompletionReceiptPermitId = readyToUninstallPermitId ready
          , cascadeCompletionReceiptReportDigest = readyToUninstallReportDigest ready
          , cascadeCompletionReceipt =
              DurableReceiptObservation
                { durableReceiptObservationKind = CascadeCompletionReceipt
                , durableReceiptObservationScope = readyToUninstallScope ready
                , durableReceiptObservationGraphDigest = readyToUninstallGraphDigest ready
                , durableReceiptObservationResult = DurableReceiptObserved
                }
          }
    , hostCompletionReadBackEvidence = complete
    }

isCompletedWith
  :: CleanupDigest
  -> Either HostCleanupRunnerError HostCleanupRunnerResult
  -> Bool
isCompletedWith digest result = case result of
  Right completed -> completedHostCleanupReceiptDigest completed == digest
  Left _ -> False

isRightRunner :: Either left value -> Bool
isRightRunner result = case result of
  Right _ -> True
  Left _ -> False

isLeftRunner :: Either left value -> Bool
isLeftRunner result = case result of
  Left _ -> True
  Right _ -> False

isMissingCompletion
  :: Either HostCleanupRunnerError value -> Bool
isMissingCompletion result = case result of
  Left
    ( HostCleanupRunnerObservationFailed
        HostCleanupReadBackCompletionStep
        _
      ) -> True
  _ -> False
