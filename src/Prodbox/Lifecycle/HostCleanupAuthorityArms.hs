{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the host cleanup runner's Lifecycle-Authority arms.
--
-- [Lifecycle Reconciliation Doctrine § 5b nodes 7, 9 and 10](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- put the Authority on both sides of the destructive host boundary: it accepts
-- the pre-uninstall readiness before local RKE2 is removed, it is
-- re-established from the independent backup afterwards, and the durable
-- cleanup run is reconciled against what the host actually observed.
-- "Prodbox.Lifecycle.HostCleanupRunner" already asked all six questions through
-- its injected boundary, and three of the pairs had no production answer at
-- all, so the destructive boundary could be exercised only against fakes.
--
-- Four properties carry the design.
--
--   * __One observation answers both readiness read-backs.__  The runner reads
--     the accepted readiness before the uninstall and again after
--     re-establishment.  That is deliberately the /same/ question asked at two
--     times, not two questions: a re-established Authority that cannot produce
--     the readiness it accepted has not been re-established in the sense the
--     run needs, and giving the second read-back a weaker source would hide
--     exactly that.
--
--   * __Re-establishment never reports readiness.__  Its answers are about what
--     the attempt did — bytes restored, a restore that failed, an Authority
--     that never admitted a request.  Whether the readiness survived is the
--     read-back's answer, from an independent observation.  This is the same
--     separation "Prodbox.Lifecycle.HostCleanupRecoveryPlane" applies to the
--     substrate.
--
--   * __Nothing is restored into an Authority that was never asked to hold
--     it.__  The acceptance captures the durable binding before any boundary
--     call, so a readiness that cannot be captured is refused rather than
--     half-written, and the read-back's restoration re-derives every field from
--     the retained bytes against the run and scope the durable intent carries.
--
--   * __The run reconciliation re-issues its own attempt.__  The
--     local-uninstall node is begun and completed under the attempt id
--     'deterministicCleanupNodeAttemptId' derives, which is the same id the
--     durable cleanup driver would derive, so a rerun after a lost response
--     replays its own attempt instead of colliding with it.
--
-- What this module does not own: the /content/ of readiness, which
-- "Prodbox.Lifecycle.Teardown.PreUninstallReadiness" composes; the retained
-- namespace it lives in, which belongs to
-- "Prodbox.ControlPlane.HostCleanupReadinessRepository"; and the host mutations
-- that re-install a control plane, which stay behind the injected restore
-- boundary because they belong to the non-public candidate entrypoint this
-- sprint still owns.
module Prodbox.Lifecycle.HostCleanupAuthorityArms
  ( -- * Accepting the readiness
    hostCleanupReadinessAcceptance
  , hostCleanupReadinessAcceptanceEffect
  , acceptHostCleanupReadiness
  , productionHostCleanupAcceptAuthority

    -- * Reading the accepted readiness back
  , hostCleanupAcceptedReadinessReadBack
  , productionHostCleanupAuthorityReadBack

    -- * Re-establishing the Authority
  , LifecycleAuthorityRestoreBoundary (..)
  , LifecycleAuthorityReestablishment (..)
  , renderLifecycleAuthorityReestablishment
  , reestablishLifecycleAuthority
  , lifecycleAuthorityReestablishmentEffect

    -- * Reconciling the cleanup run
  , hostCleanupLocalUninstallNodeId
  , HostCleanupRunReconciliation (..)
  , renderHostCleanupRunReconciliation
  , hostCleanupRunReconciliationEffect
  , reconcileHostCleanupRun
  , productionHostCleanupRunReconcile
  , productionHostCleanupRunReadBack

    -- * Regression over the package-private fixture
  , HostCleanupAuthorityArmsRegression
  , fixedHostCleanupAuthorityArmsRegression
  , authorityArmsRegressionAcceptedBecomesReadBack
  , authorityArmsRegressionAcceptIsIdempotent
  , authorityArmsRegressionConflictRefused
  , authorityArmsRegressionMissingIsNotUnobservable
  , authorityArmsRegressionAcceptResponseNotEvidence
  , authorityArmsRegressionForeignRunRefused
  , authorityArmsRegressionFailedRestoreNeverAwaits
  , authorityArmsRegressionRestoreIsNotReadiness
  , authorityArmsRegressionRunReconcileIsIdempotent
  , authorityArmsRegressionRunMissingRefused
  , authorityArmsRegressionRunTransportIsResponseLost
  )
where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (executeCleanupRunCommand)
  , CleanupRunClientError (CleanupRunClientScanResponseInvalid)
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (CleanupRunBeginNode, CleanupRunCompleteNode, CleanupRunObserve)
  )
import Prodbox.ControlPlane.HostCleanupReadinessRepository.Internal
  ( AcceptedHostCleanupReadiness
  , HostCleanupReadinessAcceptResult (..)
  , HostCleanupReadinessAuthorityClient
  , HostCleanupReadinessRepositoryError
  , acceptHostCleanupReadinessAttempt
  , acceptedHostCleanupReadinessBinding
  , hostCleanupReadinessAuthorityLogicalName
  , independentlyReadBackAcceptedHostCleanupReadiness
  , modelBHostCleanupReadinessRepository
  , renderHostCleanupReadinessRepositoryError
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (CleanupNodeSucceeded)
  , CleanupNodePlan
  , CleanupRun
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupGraphNodes
  , cleanupLeaseFence
  , cleanupLeaseOwner
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupOwnerIdText
  , cleanupRunGraph
  , cleanupRunGraphDigest
  , cleanupRunId
  , cleanupRunIdText
  , cleanupRunLease
  )
import Prodbox.Lifecycle.CleanupRunRunner (deterministicCleanupNodeAttemptId)
import Prodbox.Lifecycle.HostCleanupIntent
  ( hostCleanupRun
  , mkHostCleanupIntent
  , mkHostCleanupScope
  , mkHostCleanupTerminalIdentity
  , mkHostTerminalPermitId
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (..)
  , HostCleanupRunnerContext
  , hostCleanupRunnerIntent
  , hostCleanupRunnerObservationScope
  , hostCleanupRunnerRunId
  , validateHostCleanupReady
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( DurableReadyToUninstallBinding
  , ReadyToUninstallEvidence
  , captureDurableReadyToUninstallBinding
  , cascadeLocalUninstallOperationId
  , encodeDurableReadyToUninstallBinding
  , localCompletionPermitIdText
  , readyToUninstallOperationReferences
  , readyToUninstallPermitId
  , readyToUninstallScope
  , restoreReadyToUninstallEvidence
  , withCascadeEvidenceFixtureForRunInternal
  , withFixedCascadeEvidenceFixtureInternal
  )

-- ---------------------------------------------------------------------------
-- Accepting the readiness
-- ---------------------------------------------------------------------------

-- | Capture the durable binding the Authority is asked to hold.
--
-- This runs before any boundary call, so readiness that cannot be captured is
-- refused rather than partly written.
hostCleanupReadinessAcceptance
  :: ReadyToUninstallEvidence -> Either Text DurableReadyToUninstallBinding
hostCleanupReadinessAcceptance ready =
  case captureDurableReadyToUninstallBinding ready of
    Left err ->
      Left ("readiness could not be captured for acceptance: " <> Text.pack (show err))
    Right binding -> Right binding

-- | Project one acceptance attempt onto the runner's mutation answer.
--
-- An exact replay is applied, because a rerun accepting the readiness it
-- already accepted is the case this protocol exists for.  A conflict is a
-- refusal: two readiness proofs under one run id would be two permits.  Only
-- the genuinely ambiguous arm is a lost response.
hostCleanupReadinessAcceptanceEffect
  :: HostCleanupReadinessAcceptResult -> HostCleanupEffectOutcome
hostCleanupReadinessAcceptanceEffect = \case
  HostCleanupReadinessAccepted -> HostCleanupEffectApplied
  HostCleanupReadinessExactReplay -> HostCleanupEffectApplied
  HostCleanupReadinessConflict ->
    HostCleanupEffectRefused
      "the Lifecycle Authority already accepted a different readiness for this run"
  HostCleanupReadinessAcceptResponseLost failure ->
    HostCleanupEffectResponseLost (Text.pack (show failure))
  HostCleanupReadinessAcceptUnavailable failure ->
    HostCleanupEffectRefused (Text.pack (show failure))

-- | Capture, then accept.
acceptHostCleanupReadiness
  :: (Monad m)
  => HostCleanupReadinessAuthorityClient m
  -> CleanupRunId
  -> ReadyToUninstallEvidence
  -> m HostCleanupEffectOutcome
acceptHostCleanupReadiness client runId ready =
  case hostCleanupReadinessAcceptance ready of
    Left detail -> pure (HostCleanupEffectRefused detail)
    Right binding ->
      hostCleanupReadinessAcceptanceEffect
        <$> acceptHostCleanupReadinessAttempt client runId binding

-- | The production acceptance arm.
productionHostCleanupAcceptAuthority
  :: HostCleanupReadinessAuthorityClient IO
  -> HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> IO HostCleanupEffectOutcome
productionHostCleanupAcceptAuthority client context =
  acceptHostCleanupReadiness client (hostCleanupRunnerRunId context)

-- ---------------------------------------------------------------------------
-- Reading the accepted readiness back
-- ---------------------------------------------------------------------------

-- | Turn one observation of the Authority's readiness slot back into proof.
--
-- The run and the observation scope come from the durable host intent and the
-- rest comes from the retained bytes, so the restoration is a comparison
-- between two independent sources.  A slot that holds nothing and a slot that
-- could not be read are both refusals here, and each keeps the repository's own
-- wording so the runner's narration says which one happened.
hostCleanupAcceptedReadinessReadBack
  :: HostCleanupRunnerContext
  -> Either HostCleanupReadinessRepositoryError AcceptedHostCleanupReadiness
  -> Either Text ReadyToUninstallEvidence
hostCleanupAcceptedReadinessReadBack context = \case
  Left err -> Left (renderHostCleanupReadinessRepositoryError err)
  Right accepted ->
    case restoreReadyToUninstallEvidence
      (hostCleanupRun (hostCleanupRunnerIntent context))
      (hostCleanupRunnerObservationScope context)
      (acceptedHostCleanupReadinessBinding accepted) of
      Left err ->
        Left
          ( "the accepted readiness does not bind to this run: "
              <> Text.pack (show err)
          )
      Right ready -> Right ready

-- | The production read-back arm, used for both the acceptance read-back and
-- the post-re-establishment read-back.
--
-- They are the same observation asked at two times.  Giving the second one a
-- different source would let a re-established Authority that lost the readiness
-- still satisfy the runner.
productionHostCleanupAuthorityReadBack
  :: HostCleanupReadinessAuthorityClient IO
  -> HostCleanupRunnerContext
  -> IO (Either Text ReadyToUninstallEvidence)
productionHostCleanupAuthorityReadBack client context =
  hostCleanupAcceptedReadinessReadBack context
    <$> independentlyReadBackAcceptedHostCleanupReadiness
      client
      (hostCleanupRunnerRunId context)

-- ---------------------------------------------------------------------------
-- Re-establishing the Authority
-- ---------------------------------------------------------------------------

-- | The two host mutations that bring the Authority back.
--
-- They stay injected because installing a workload and copying an aggregate out
-- of the independent backup domain are destructive host actions belonging to
-- the non-public candidate entrypoint; wiring one here would activate a writer
-- this sprint does not activate.
data LifecycleAuthorityRestoreBoundary m = LifecycleAuthorityRestoreBoundary
  { restoreAuthorityAggregateFromBackup :: m (Either Text ())
  , awaitLifecycleAuthorityAdmission :: m (Either Text ())
  }

-- | What one re-establishment attempt did.
--
-- None of the arms says the readiness is there; that is the read-back's answer.
data LifecycleAuthorityReestablishment
  = LifecycleAuthorityRestored
  | LifecycleAuthorityRestoreFailed !Text
  | LifecycleAuthorityAdmissionUnavailable !Text
  deriving (Eq, Show)

renderLifecycleAuthorityReestablishment
  :: LifecycleAuthorityReestablishment -> Text
renderLifecycleAuthorityReestablishment = \case
  LifecycleAuthorityRestored ->
    "lifecycle authority aggregate restored and admitting requests"
  LifecycleAuthorityRestoreFailed detail ->
    "lifecycle authority aggregate was not restored: " <> detail
  LifecycleAuthorityAdmissionUnavailable detail ->
    "lifecycle authority never admitted a request: " <> detail

-- | Restore the aggregate, then wait for admission.
--
-- The order is load-bearing: waiting for admission from an Authority whose
-- bytes were not restored would accept an empty control plane that has
-- forgotten the run, so a failed restore never reaches the wait.
reestablishLifecycleAuthority
  :: (Monad m)
  => LifecycleAuthorityRestoreBoundary m
  -> m LifecycleAuthorityReestablishment
reestablishLifecycleAuthority boundary = do
  restored <- restoreAuthorityAggregateFromBackup boundary
  case restored of
    Left detail -> pure (LifecycleAuthorityRestoreFailed detail)
    Right () -> do
      admitted <- awaitLifecycleAuthorityAdmission boundary
      pure $ case admitted of
        Left detail -> LifecycleAuthorityAdmissionUnavailable detail
        Right () -> LifecycleAuthorityRestored

lifecycleAuthorityReestablishmentEffect
  :: LifecycleAuthorityReestablishment -> HostCleanupEffectOutcome
lifecycleAuthorityReestablishmentEffect = \case
  LifecycleAuthorityRestored -> HostCleanupEffectApplied
  attempt ->
    HostCleanupEffectRefused (renderLifecycleAuthorityReestablishment attempt)

-- ---------------------------------------------------------------------------
-- Reconciling the cleanup run
-- ---------------------------------------------------------------------------

-- | The compiled node the destructive host boundary owns.
hostCleanupLocalUninstallNodeId :: Text
hostCleanupLocalUninstallNodeId = "lifecycle/cascade/uninstall-local"

-- | What one reconciliation attempt did.
data HostCleanupRunReconciliation
  = HostCleanupRunReconciled
  | HostCleanupRunNodeUnknown !Text
  | HostCleanupRunAttemptInvalid !Text
  | HostCleanupRunRefused !Text
  | HostCleanupRunMissing
  | HostCleanupRunTransportFailed !CleanupRunClientError
  deriving (Eq, Show)

renderHostCleanupRunReconciliation :: HostCleanupRunReconciliation -> Text
renderHostCleanupRunReconciliation = \case
  HostCleanupRunReconciled ->
    "the durable cleanup run records the local uninstall"
  HostCleanupRunNodeUnknown node ->
    "the compiled graph has no node `" <> node <> "` to reconcile"
  HostCleanupRunAttemptInvalid detail ->
    "the local-uninstall attempt id is invalid: " <> detail
  HostCleanupRunRefused detail ->
    "the Lifecycle Authority refused the local-uninstall transition: " <> detail
  HostCleanupRunMissing ->
    "the Lifecycle Authority holds no cleanup run to reconcile"
  HostCleanupRunTransportFailed err ->
    "the cleanup-run transport failed: " <> Text.pack (show err)

-- | Project one reconciliation onto the runner's mutation answer.
--
-- A transport failure is a lost response rather than a refusal: the transition
-- may have landed, and the run read-back that follows is what decides.  Every
-- other arm knows the transition did not happen.
hostCleanupRunReconciliationEffect
  :: HostCleanupRunReconciliation -> HostCleanupEffectOutcome
hostCleanupRunReconciliationEffect reconciliation = case reconciliation of
  HostCleanupRunReconciled -> HostCleanupEffectApplied
  HostCleanupRunTransportFailed _ ->
    HostCleanupEffectResponseLost
      (renderHostCleanupRunReconciliation reconciliation)
  _ -> HostCleanupEffectRefused (renderHostCleanupRunReconciliation reconciliation)

-- | Begin and complete the local-uninstall node under its deterministic
-- attempt.
--
-- Both transitions are idempotent for the same attempt id, so a rerun replays
-- its own attempt rather than issuing a second one the Authority would read as
-- a conflict.  The owner and fence come from the lease carried by the durable
-- host intent, which is the lease the host already holds.
reconcileHostCleanupRun
  :: (Monad m)
  => (CleanupRunCommand -> m (Either CleanupRunClientError (Maybe CleanupRun)))
  -> CleanupRun
  -> m HostCleanupRunReconciliation
reconcileHostCleanupRun issue run =
  case localUninstallPlan run of
    Nothing -> pure (HostCleanupRunNodeUnknown hostCleanupLocalUninstallNodeId)
    Just plan -> case deterministicCleanupNodeAttemptId run plan of
      Left detail -> pure (HostCleanupRunAttemptInvalid detail)
      Right attempt -> do
        begun <- issue (beginCommand (cleanupNodeId plan) attempt)
        case begun of
          Left err -> pure (HostCleanupRunTransportFailed err)
          Right Nothing -> pure HostCleanupRunMissing
          Right (Just running) -> do
            completed <-
              issue (completeCommand running (cleanupNodeId plan) attempt)
            pure $ case completed of
              Left err -> HostCleanupRunTransportFailed err
              Right Nothing -> HostCleanupRunMissing
              Right (Just _) -> HostCleanupRunReconciled
 where
  beginCommand node attempt =
    CleanupRunBeginNode
      (cleanupRunIdText (cleanupRunId run))
      (cleanupOwnerIdText (cleanupLeaseOwner (cleanupRunLease run)))
      (cleanupLeaseFence (cleanupRunLease run))
      (cleanupNodeIdText node)
      (cleanupAttemptIdText attempt)

  completeCommand observed node attempt =
    CleanupRunCompleteNode
      (cleanupRunIdText (cleanupRunId observed))
      (cleanupOwnerIdText (cleanupLeaseOwner (cleanupRunLease observed)))
      (cleanupLeaseFence (cleanupRunLease observed))
      (cleanupNodeIdText node)
      (cleanupAttemptIdText attempt)
      CleanupNodeSucceeded

localUninstallPlan :: CleanupRun -> Maybe CleanupNodePlan
localUninstallPlan run =
  find
    ( \plan ->
        cleanupNodeIdText (cleanupNodeId plan) == hostCleanupLocalUninstallNodeId
    )
    (cleanupGraphNodes (cleanupRunGraph run))

-- | The production reconciliation arm.
productionHostCleanupRunReconcile
  :: CleanupRunClient IO
  -> HostCleanupRunnerContext
  -> IO HostCleanupEffectOutcome
productionHostCleanupRunReconcile client context =
  hostCleanupRunReconciliationEffect
    <$> reconcileHostCleanupRun
      (executeCleanupRunCommand client)
      (hostCleanupRun (hostCleanupRunnerIntent context))

-- | The production run read-back arm.
--
-- It observes the run by its own id at the Authority; the runner then compares
-- the observed identity and graph against the durable intent.
productionHostCleanupRunReadBack
  :: CleanupRunClient IO
  -> HostCleanupRunnerContext
  -> IO (Either Text CleanupRun)
productionHostCleanupRunReadBack client context = do
  observed <-
    executeCleanupRunCommand
      client
      (CleanupRunObserve (cleanupRunIdText (hostCleanupRunnerRunId context)))
  pure $ case observed of
    Left err ->
      Left (renderHostCleanupRunReconciliation (HostCleanupRunTransportFailed err))
    Right Nothing ->
      Left (renderHostCleanupRunReconciliation HostCleanupRunMissing)
    Right (Just run) -> Right run

-- ---------------------------------------------------------------------------
-- Regression
-- ---------------------------------------------------------------------------

-- | Fixed, non-parameterised regression booleans.
--
-- Nothing authority-bearing crosses the facade: the readiness proofs are
-- created and consumed inside the package-private cascade-evidence fixture and
-- only these booleans come back.
data HostCleanupAuthorityArmsRegression = HostCleanupAuthorityArmsRegression
  { authorityArmsRegressionAcceptedBecomesReadBack :: !Bool
  , authorityArmsRegressionAcceptIsIdempotent :: !Bool
  , authorityArmsRegressionConflictRefused :: !Bool
  , authorityArmsRegressionMissingIsNotUnobservable :: !Bool
  , authorityArmsRegressionAcceptResponseNotEvidence :: !Bool
  , authorityArmsRegressionForeignRunRefused :: !Bool
  , authorityArmsRegressionFailedRestoreNeverAwaits :: !Bool
  , authorityArmsRegressionRestoreIsNotReadiness :: !Bool
  , authorityArmsRegressionRunReconcileIsIdempotent :: !Bool
  , authorityArmsRegressionRunMissingRefused :: !Bool
  , authorityArmsRegressionRunTransportIsResponseLost :: !Bool
  }

data FixedAuthorityArmsScenario = FixedAuthorityArmsScenario
  { fixedArmsContext :: !HostCleanupRunnerContext
  , fixedArmsReady :: !ReadyToUninstallEvidence
  , fixedArmsRun :: !CleanupRun
  , fixedArmsOtherReady :: !ReadyToUninstallEvidence
  , fixedArmsAuthority :: !LongLivedCheckpointAuthority
  }

fixedHostCleanupAuthorityArmsRegression
  :: IO (Either Text HostCleanupAuthorityArmsRegression)
fixedHostCleanupAuthorityArmsRegression =
  case fixedAuthorityArmsScenario of
    Left err -> pure (Left err)
    Right scenario -> Right <$> runFixedAuthorityArmsRegression scenario

fixedAuthorityArmsScenario :: Either Text FixedAuthorityArmsScenario
fixedAuthorityArmsScenario = do
  (run, ready) <-
    withFixedCascadeEvidenceFixtureInternal
      (\_compiled run' ready' _local _complete -> (run', ready'))
  otherReady <-
    withCascadeEvidenceFixtureForRunInternal
      "cleanup-run/authority-arms-fixed-other"
      (\_compiled _run' ready' _local _complete -> ready')
  context <- fixedArmsContextFor run ready
  authority <-
    mapFixedArmsLeft
      ( mkLongLivedCheckpointAuthority
          "home-rke2"
          "prodbox-retained"
          "authority"
          "prodbox/authority"
      )
  pure
    FixedAuthorityArmsScenario
      { fixedArmsContext = context
      , fixedArmsReady = ready
      , fixedArmsRun = run
      , fixedArmsOtherReady = otherReady
      , fixedArmsAuthority = authority
      }

-- | Build the running context the destructive boundary would hold, from the
-- fixture's own run and readiness, through public host-cleanup constructors
-- only.
fixedArmsContextFor
  :: CleanupRun -> ReadyToUninstallEvidence -> Either Text HostCleanupRunnerContext
fixedArmsContextFor run ready = do
  scope <-
    mapFixedArmsLeft
      (mkHostCleanupScope (cleanupRunId run) (readyToUninstallScope ready))
  permit <-
    mapFixedArmsLeft
      ( mkHostTerminalPermitId
          (localCompletionPermitIdText (readyToUninstallPermitId ready))
      )
  intent <-
    mapFixedArmsLeft
      ( mkHostCleanupIntent
          (cleanupRunId run)
          (cleanupRunGraphDigest run)
          run
          scope
          ( mkHostCleanupTerminalIdentity
              ( cascadeLocalUninstallOperationId
                  (readyToUninstallOperationReferences ready)
              )
              permit
          )
      )
  mapFixedArmsLeft (validateHostCleanupReady intent ready)

mapFixedArmsLeft :: (Show err) => Either err value -> Either Text value
mapFixedArmsLeft = either (Left . Text.pack . show) Right

runFixedAuthorityArmsRegression
  :: FixedAuthorityArmsScenario -> IO HostCleanupAuthorityArmsRegression
runFixedAuthorityArmsRegression scenario = do
  accepted <- withStore [] $ \client store -> do
    first' <- acceptHostCleanupReadiness client runId ready
    readBack <- readBackWith client
    pure (first', readBack, store)
  idempotent <- withStore [] $ \client _ -> do
    _ <- acceptHostCleanupReadiness client runId ready
    second <- acceptHostCleanupReadiness client runId ready
    readBack <- readBackWith client
    pure (second, readBack)
  conflicted <- withStore [(coordinateName, foreignBytes)] $ \client _ -> do
    attempt <- acceptHostCleanupReadiness client runId ready
    readBack <- readBackWith client
    pure (attempt, readBack)
  missingReadBack <- withStore [] $ \client _ -> readBackWith client
  unobservableReadBack <- readBackWith (unobservableClient authority)
  responseLoss <- withStore [] $ \client store -> do
    applied <- acceptHostCleanupReadiness client runId ready
    writeIORef store []
    readBack <- readBackWith client
    pure (applied, readBack)
  restoreLog <- newIORef ([] :: [Text])
  failedRestore <-
    reestablishLifecycleAuthority
      (recordingRestore restoreLog (Left "backup domain unreachable") (Right ()))
  failedRestoreCalls <- readIORef restoreLog
  writeIORef restoreLog []
  restored <- reestablishLifecycleAuthority (recordingRestore restoreLog (Right ()) (Right ()))
  reconcileLog <- newIORef ([] :: [CleanupRunCommand])
  firstReconcile <- reconcileHostCleanupRun (recordingIssue reconcileLog (Just run)) run
  firstCommands <- readIORef reconcileLog
  writeIORef reconcileLog []
  secondReconcile <- reconcileHostCleanupRun (recordingIssue reconcileLog (Just run)) run
  secondCommands <- readIORef reconcileLog
  runMissing <- reconcileHostCleanupRun (recordingIssue reconcileLog Nothing) run
  runTransport <- reconcileHostCleanupRun (\_ -> pure (Left transportFailure)) run
  let (firstAccept, acceptedReadBack, _) = accepted
      (secondAccept, idempotentReadBack) = idempotent
      (conflictAttempt, conflictReadBack) = conflicted
      (appliedResponse, lostReadBack) = responseLoss
  pure
    HostCleanupAuthorityArmsRegression
      { authorityArmsRegressionAcceptedBecomesReadBack =
          firstAccept == HostCleanupEffectApplied
            && acceptedReadBack == Right ready
      , -- A rerun accepting the readiness it already accepted is the case the
        -- protocol exists for, so an exact replay is applied rather than a
        -- conflict.
        authorityArmsRegressionAcceptIsIdempotent =
          secondAccept == HostCleanupEffectApplied
            && idempotentReadBack == Right ready
      , authorityArmsRegressionConflictRefused =
          isRefusedOutcome conflictAttempt && isLeft conflictReadBack
      , -- The runner needs a different remedy for each, so they never collapse.
        authorityArmsRegressionMissingIsNotUnobservable =
          isLeft missingReadBack
            && isLeft unobservableReadBack
            && missingReadBack /= unobservableReadBack
      , -- The acceptance reported that it applied and the slot is then empty,
        -- so the run has only the writer's word for it.  The observation is
        -- what refuses.
        authorityArmsRegressionAcceptResponseNotEvidence =
          appliedResponse == HostCleanupEffectApplied && isLeft lostReadBack
      , authorityArmsRegressionForeignRunRefused = isLeft conflictReadBack
      , -- Awaiting admission from an Authority whose bytes were not restored
        -- would accept a control plane that has forgotten the run.
        authorityArmsRegressionFailedRestoreNeverAwaits =
          failedRestore == LifecycleAuthorityRestoreFailed "backup domain unreachable"
            && failedRestoreCalls == ["restore"]
      , authorityArmsRegressionRestoreIsNotReadiness =
          restored == LifecycleAuthorityRestored
            && lifecycleAuthorityReestablishmentEffect restored
              == HostCleanupEffectApplied
      , -- Both reruns issue the same two commands under the same deterministic
        -- attempt, which is what makes the Authority's own idempotence apply.
        authorityArmsRegressionRunReconcileIsIdempotent =
          firstReconcile == HostCleanupRunReconciled
            && secondReconcile == HostCleanupRunReconciled
            && firstCommands == secondCommands
            && length firstCommands == 2
      , authorityArmsRegressionRunMissingRefused =
          runMissing == HostCleanupRunMissing
            && isRefusedOutcome (hostCleanupRunReconciliationEffect runMissing)
      , -- A transport failure may have landed the transition, so the run
        -- read-back decides rather than this answer.
        authorityArmsRegressionRunTransportIsResponseLost =
          isResponseLost (hostCleanupRunReconciliationEffect runTransport)
      }
 where
  context = fixedArmsContext scenario
  ready = fixedArmsReady scenario
  run = fixedArmsRun scenario
  runId = cleanupRunId run
  authority = fixedArmsAuthority scenario
  coordinateName = hostCleanupReadinessAuthorityLogicalName runId
  foreignBytes =
    either
      (const "")
      encodeDurableReadyToUninstallBinding
      (captureDurableReadyToUninstallBinding (fixedArmsOtherReady scenario))
  transportFailure =
    CleanupRunClientScanResponseInvalid "fixed transport ambiguity"

  readBackWith client =
    hostCleanupAcceptedReadinessReadBack context
      <$> independentlyReadBackAcceptedHostCleanupReadiness client runId

  withStore seeded consume = do
    store <- newIORef seeded
    consume (modelBHostCleanupReadinessRepository authority (memoryAdapter store)) store

  recordingRestore journal restore admission =
    LifecycleAuthorityRestoreBoundary
      { restoreAuthorityAggregateFromBackup = do
          modifyIORef' journal (++ ["restore"])
          pure restore
      , awaitLifecycleAuthorityAdmission = do
          modifyIORef' journal (++ ["await"])
          pure admission
      }

  recordingIssue journal answer command = do
    modifyIORef' journal (++ [command])
    pure (Right answer)

memoryAdapter
  :: IORef [(Text, ByteString)] -> ModelBCasAdapter 'ClusterRetained IO ByteString
memoryAdapter store =
  ModelBCasAdapter
    { modelBObserve = \coordinate -> do
        held <- readIORef store
        pure
          ( maybe
              ModelBMissing
              (ModelBObserved memoryVersion)
              (lookup (modelBObjectLogicalName coordinate) held)
          )
    , modelBCompareAndSwap = \case
        ModelBInitialize coordinate value -> do
          let name = modelBObjectLogicalName coordinate
          existing <- atomicModifyIORef' store (initializeSlot name value)
          pure
            ( maybe
                (ModelBCasApplied memoryVersion value)
                (ModelBCasConflict . ModelBObserved memoryVersion)
                existing
            )
        _ ->
          pure
            ( ModelBCasRefusedCorrupt
                "the fixed readiness store issues only initialize"
            )
    }
 where
  initializeSlot name value held = case lookup name held of
    Just existing -> (held, Just existing)
    Nothing -> (held ++ [(name, value)], Nothing)

memoryVersion :: ModelBObjectVersion
memoryVersion =
  either (const fallbackVersion) id (mkModelBObjectVersion "fixed-version")
 where
  fallbackVersion =
    either (const memoryVersion) id (mkModelBObjectVersion "v")

unobservableClient
  :: LongLivedCheckpointAuthority -> HostCleanupReadinessAuthorityClient IO
unobservableClient authority =
  modelBHostCleanupReadinessRepository
    authority
    ModelBCasAdapter
      { modelBObserve = \_ ->
          pure (ModelBUnobservable "fixed transport ambiguity")
      , modelBCompareAndSwap = \_ ->
          pure (ModelBCasUnobservable "fixed transport ambiguity")
      }

isRefusedOutcome :: HostCleanupEffectOutcome -> Bool
isRefusedOutcome = \case
  HostCleanupEffectRefused _ -> True
  _ -> False

isResponseLost :: HostCleanupEffectOutcome -> Bool
isResponseLost = \case
  HostCleanupEffectResponseLost _ -> True
  _ -> False
