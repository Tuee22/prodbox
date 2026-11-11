{-# LANGUAGE DerivingStrategies #-}

-- | Staged promotion orchestration. The physical interpreter must fence each
-- action against the exact context, prove its own result, and preserve the
-- original deadline. This program alone supplies neither admission nor a
-- physical interpreter and is not wired to runtime dispatch.
module Prodbox.Lifecycle.Authority.EpochPromotionCoordinator
  ( PromotionContext (..)
  , PromotionIntent (..)
  , PhysicalTransition (..)
  , PromotionBoundary (..)
  , PromotionFailure (..)
  , PromotionOutcome (..)
  , runPromotion
  ) where

import Control.Monad (forM_, unless, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Set qualified as Set
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochPromotionObservation
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Lease (AuthorityTime)

data PromotionContext = PromotionContext
  { contextPredecessor :: !Word
  , contextTarget :: !Word
  , contextTopology :: !EpochTopology
  , contextDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

data PromotionIntent = CompletePromotion | RetirePreparation
  deriving stock (Eq, Show)

-- The physical interpreter owns exact identity, fencing, idempotence and
-- ambiguous-effect recovery. It may not report success from caller metadata.
data PhysicalTransition = PreparePhysical | PromotePhysical | RetirePhysical
  deriving stock (Eq, Show)

data PromotionBoundary m failure = PromotionBoundary
  { boundaryTime :: m (Either failure AuthorityTime)
  , boundaryObserve :: m (Either failure EpochPromotionObservation)
  , boundaryPhysical
      :: PromotionContext -> PhysicalTransition -> EpochTopologyBinding -> m (Either failure ())
  , boundarySubmit :: PromotionContext -> EpochPromotionRequest -> m (Either failure ())
  }

data PromotionFailure failure
  = PromotionBoundaryRefused !failure
  | PromotionExpired
  | PromotionObservationInvalid !EpochPromotionObservationError
  | PromotionContextMismatch
  | PromotionPhaseChanged !EpochPromotionPhase
  | PromotionMissingBinding !EpochTopologyBinding
  | PromotionForwardRecoveryRequired
  | PromotionRollbackRequired
  | PromotionAdmissionUnobservable
  deriving stock (Eq, Show)

data PromotionOutcome = PromotionAdmissionObserved | PreparationRetiredNeedsWriterRecovery
  deriving stock (Eq, Show)

-- Each iteration begins with a fresh, validated snapshot. Retrying a partial
-- phase replays its finite binding inventory; each physical action and each
-- signed readback must therefore implement the stated idempotence contract.
runPromotion
  :: (Monad m)
  => PromotionBoundary m failure
  -> PromotionContext
  -> PromotionIntent
  -> m (Either (PromotionFailure failure) PromotionOutcome)
runPromotion boundary context intent = runExceptT $ do
  when
    (contextPredecessor context == 0 || contextTarget context <= contextPredecessor context)
    (throwE PromotionContextMismatch)
  case validateEpochTopology (contextTopology context) of
    Left _ -> throwE PromotionContextMismatch
    Right () -> pure ()
  snapshot <- observe
  prepared <- maybe (throwE PromotionContextMismatch) pure (observedPreparedEpoch snapshot)
  case (intent, observedPreparationPhase prepared) of
    (CompletePromotion, EpochPrepared) -> preparePhase >> frozenPhase >> admitted
    (CompletePromotion, EpochFrozen) -> frozenPhase >> admitted
    (CompletePromotion, EpochAdmissionOpen) -> admitted
    (CompletePromotion, EpochPreparedRollback) -> throwE PromotionRollbackRequired
    (CompletePromotion, EpochPreparedBindingsRetired) -> throwE PromotionRollbackRequired
    (RetirePreparation, EpochPrepared) -> do
      submitAt EpochPrepared BeginPreparedEpochRollback
      retirePhase
    (RetirePreparation, EpochPreparedRollback) -> retirePhase
    (RetirePreparation, EpochPreparedBindingsRetired) -> retired
    (RetirePreparation, EpochFrozen) -> throwE PromotionForwardRecoveryRequired
    (RetirePreparation, EpochAdmissionOpen) -> throwE PromotionForwardRecoveryRequired
 where
  topology = contextTopology context
  bindings = Set.toAscList (epochTopologyBindings topology)
  oldWriters = Set.toAscList (epochTopologyOldWriterBindings topology)
  request action = EpochPromotionRequest (contextTarget context) (epochTopologyDigest topology) action

  before = do
    time <- ExceptT (fmap (either (Left . PromotionBoundaryRefused) Right) (boundaryTime boundary))
    when (time >= contextDeadline context) (throwE PromotionExpired)

  observe = do
    before
    snapshot <-
      ExceptT (fmap (either (Left . PromotionBoundaryRefused) Right) (boundaryObserve boundary))
    before
    case validateEpochPromotionObservation snapshot of
      Left failure -> throwE (PromotionObservationInvalid failure)
      Right () -> pure ()
    prepared <- maybe (throwE PromotionContextMismatch) pure (observedPreparedEpoch snapshot)
    unless
      ( observedPreparationPredecessor prepared == contextPredecessor context
          && observedPreparationTarget prepared == contextTarget context
          && observedPreparationTopology prepared == topology
          && observedPreparationTopologyDigest prepared == epochTopologyDigest topology
      )
      (throwE PromotionContextMismatch)
    let expectedRetained = case observedPreparationPhase prepared of
          EpochPrepared -> contextPredecessor context
          EpochPreparedRollback -> contextPredecessor context
          EpochPreparedBindingsRetired -> contextPredecessor context
          EpochFrozen -> contextTarget context
          EpochAdmissionOpen -> contextTarget context
    unless (observedRetainedEpoch snapshot == expectedRetained) (throwE PromotionContextMismatch)
    pure snapshot

  phase expected = do
    snapshot <- observe
    prepared <- maybe (throwE PromotionContextMismatch) pure (observedPreparedEpoch snapshot)
    unless
      (observedPreparationPhase prepared == expected)
      (throwE (PromotionPhaseChanged (observedPreparationPhase prepared)))
    pure snapshot

  physicalAt expected transition binding = do
    _ <- phase expected
    before
    ExceptT
      ( fmap
          (either (Left . PromotionBoundaryRefused) Right)
          (boundaryPhysical boundary context transition binding)
      )
    before

  submitAt expected action = do
    _ <- phase expected
    before
    ExceptT
      ( fmap
          (either (Left . PromotionBoundaryRefused) Right)
          (boundarySubmit boundary context (request action))
      )
    before

  readback binding = case epochTopologyBindingDigest topology binding of
    Nothing -> throwE (PromotionMissingBinding binding)
    Just digest -> pure (EpochBindingReadback binding digest)

  preparePhase = do
    forM_ bindings $ \binding -> do
      physicalAt EpochPrepared PreparePhysical binding
      receipt <- readback binding
      submitAt EpochPrepared (ObservePreparedEpochBinding receipt)
    forM_ oldWriters $ \binding -> do
      receipt <- readback binding
      submitAt EpochPrepared (ObserveOldEpochRejected receipt (contextPredecessor context))
    submitAt EpochPrepared CommitFrozenEpoch
    _ <- phase EpochFrozen
    pure ()

  frozenPhase = do
    forM_ bindings $ \binding -> do
      physicalAt EpochFrozen PromotePhysical binding
      receipt <- readback binding
      submitAt EpochFrozen (ObservePromotedEpochBinding receipt)
    forM_ oldWriters $ \binding -> do
      receipt <- readback binding
      submitAt EpochFrozen (ObserveOldEpochRejected receipt (contextPredecessor context))
    submitAt EpochFrozen OpenEpochAdmission

  retirePhase = do
    forM_ bindings $ \binding -> do
      physicalAt EpochPreparedRollback RetirePhysical binding
      submitAt EpochPreparedRollback (ObservePreparedEpochBindingAbsent binding)
    submitAt EpochPreparedRollback FinishPreparedEpochRollback
    retired

  retired = phase EpochPreparedBindingsRetired >> pure PreparationRetiredNeedsWriterRecovery
  admitted = do
    snapshot <- phase EpochAdmissionOpen
    unless
      (observedNormalAdmissionEpoch snapshot == Just (contextTarget context))
      (throwE PromotionAdmissionUnobservable)
    pure PromotionAdmissionObserved
