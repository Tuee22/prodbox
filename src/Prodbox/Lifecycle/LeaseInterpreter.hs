{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Effectful interpreter around the pure lease tables.  It is generic
-- over a Model-B CAS adapter, authority clock, bounded runner, and provider
-- quiescence observer, so production can supply physical storage/process
-- primitives while unit tests exercise the complete external loop in memory.
module Prodbox.Lifecycle.LeaseInterpreter
  ( LeaseAcquisition (..)
  , LeaseBoundedFailure (..)
  , LeaseExecutionError (..)
  , LeaseInterpreter (..)
  , acquireLeaseDetailedWith
  , acquireLeaseWith
  , fencedCommitPermitWith
  , releaseLeaseWith
  , runLeaseWorkWith
  , leaseAcquisitionRecoveredPredecessor
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencedCommitPermit
  , LeaseAcquireDecision (..)
  , LeaseAcquireRequest
  , LeaseCommitDecision (..)
  , LeaseGrant
  , LeaseOwnershipStatus (..)
  , LeasePolicy
  , LeaseProjection
  , LeaseRecoveryPredecessor
  , LeaseRefusal (..)
  , LeaseReleaseDecision (..)
  , LeaseUseDecision (..)
  , LeaseUsePermit
  , LeaseWork
  , QuiescenceRefusal
  , StableQuiescenceWitness
  , addAuthorityDuration
  , authorityTimeFromMicros
  , authorityTimeMicros
  , authorizeLeaseWork
  , confirmLeaseAcquired
  , decideFencedCommit
  , decideLeaseAcquire
  , decideLeaseRelease
  , leaseAcquireCoordinate
  , leaseAcquireDeadline
  , leaseGrantExpiresAt
  , leaseOwnershipStatus
  , leasePolicyAcquireTimeout
  , leaseProjectionRecoveryPredecessor
  , leaseRecoveryGrant
  , leaseUseDeadline
  , successorNotBefore
  )

-- | Failure reported by the injected bounded child runner.  A production
-- runner monitors both its authority deadline and the supplied ownership
-- probe, cancels the child on either failure, and waits only within its
-- declared cancellation bound.
data LeaseBoundedFailure
  = LeaseBoundedDeadlineExceeded !AuthorityTime
  | LeaseBoundedOwnershipLost !LeaseRefusal
  | LeaseBoundedRunnerFailed !Text
  deriving (Eq, Show)

data LeaseExecutionError
  = LeaseExecutionAcquireTimedOut !AuthorityTime
  | LeaseExecutionReleaseTimedOut !AuthorityTime
  | LeaseExecutionRefused !LeaseRefusal
  | LeaseExecutionQuiescenceRefused !QuiescenceRefusal
  | LeaseExecutionCasCorrupt !Text
  | LeaseExecutionCasUnobservable !Text
  | LeaseExecutionClockUnobservable !Text
  | LeaseExecutionBoundedFailure !LeaseBoundedFailure
  | LeaseExecutionActionFailed !Text
  | LeaseExecutionActionExceededDeadline !AuthorityTime !AuthorityTime
  deriving (Eq, Show)

-- | Confirmed acquisition plus the exact predecessor whose late effects were
-- drained before this fence was issued.  Successors use that predecessor for
-- cross-authority target-intent recovery before issuing new credential work.
data LeaseAcquisition = LeaseAcquisition
  { leaseAcquisitionGrant :: !LeaseGrant
  , leaseAcquisitionRecoveryPredecessor :: !(Maybe LeaseRecoveryPredecessor)
  }
  deriving (Eq, Show)

leaseAcquisitionRecoveredPredecessor
  :: LeaseAcquisition -> Maybe LeaseGrant
leaseAcquisitionRecoveredPredecessor =
  fmap leaseRecoveryGrant . leaseAcquisitionRecoveryPredecessor

data LeaseInterpreter m inventory = LeaseInterpreter
  { leaseInterpreterModelB :: !(ModelBCasAdapter m LeaseProjection)
  , leaseInterpreterAuthorityNow :: !(m (Either Text AuthorityTime))
  , leaseInterpreterWaitUntil :: !(AuthorityTime -> m (Either Text ()))
  , leaseInterpreterRecoverQuiescence
      :: !( LeasePolicy
            -> LeaseRecoveryPredecessor
            -> m
                 ( Either
                     QuiescenceRefusal
                     (StableQuiescenceWitness inventory)
                 )
          )
  , leaseInterpreterRunBounded
      :: !( forall result
             . AuthorityTime
            -> m LeaseOwnershipStatus
            -> m result
            -> m (Either LeaseBoundedFailure result)
          )
  }

-- | Run bounded CAS acquisition.  CAS success is never accepted directly:
-- ownership is confirmed by a fresh authority observation.  Conflicts are
-- re-observed and retried only until the request's authority deadline.
acquireLeaseWith
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> LeasePolicy
  -> LeaseAcquireRequest
  -> m (Either LeaseExecutionError LeaseGrant)
acquireLeaseWith interpreter policy request =
  fmap (fmap leaseAcquisitionGrant) (acquireLeaseDetailedWith interpreter policy request)

acquireLeaseDetailedWith
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> LeasePolicy
  -> LeaseAcquireRequest
  -> m (Either LeaseExecutionError LeaseAcquisition)
acquireLeaseDetailedWith interpreter policy request = acquireLoop Nothing
 where
  adapter = leaseInterpreterModelB interpreter
  coordinate = leaseAcquireCoordinate request

  acquireLoop maybeRecovery = do
    withAuthorityNow interpreter $ \now -> do
      observation <- modelBObserve adapter coordinate
      case decideLeaseAcquire policy now request (snd <$> maybeRecovery) observation of
        LeaseAcquireCompareAndSwap casRequest -> do
          casResult <- modelBCompareAndSwap adapter casRequest
          case casResult of
            ModelBCasApplied _ _ -> confirmAfterCas maybeRecovery
            ModelBCasConflict _ -> retryAfter maybeRecovery now
            ModelBCasRefusedCorrupt detail ->
              pure (Left (LeaseExecutionCasCorrupt detail))
            ModelBCasUnobservable detail ->
              pure (Left (LeaseExecutionCasUnobservable detail))
        LeaseAcquireAlreadyOwned _ ->
          pure
            ( acquisitionResult
                (fst <$> maybeRecovery)
                (confirmLeaseAcquired policy now request observation)
            )
        LeaseAcquireContended predecessor ->
          waitAndRetry Nothing now (successorNotBefore policy predecessor)
        LeaseAcquireRecoveryRequired notBefore
          | now < notBefore -> waitAndRetry Nothing now notBefore
          | otherwise ->
              case recoveryPredecessor policy observation of
                Left refusal -> pure (Left (LeaseExecutionRefused refusal))
                Right predecessor -> do
                  recovery <-
                    leaseInterpreterRecoverQuiescence interpreter policy predecessor
                  case recovery of
                    Left refusal ->
                      pure (Left (LeaseExecutionQuiescenceRefused refusal))
                    Right witness -> acquireLoop (Just (predecessor, witness))
        LeaseAcquireTimedOut deadline ->
          pure (Left (LeaseExecutionAcquireTimedOut deadline))
        LeaseAcquireRefused refusal ->
          pure (Left (LeaseExecutionRefused refusal))

  confirmAfterCas maybeRecovery = do
    withAuthorityNow interpreter $ \now -> do
      observation <- modelBObserve adapter coordinate
      case confirmLeaseAcquired policy now request observation of
        Right grant ->
          pure
            ( Right
                LeaseAcquisition
                  { leaseAcquisitionGrant = grant
                  , leaseAcquisitionRecoveryPredecessor = fst <$> maybeRecovery
                  }
            )
        Left (LeaseAuthorityCorrupt detail) ->
          pure (Left (LeaseExecutionCasCorrupt detail))
        Left (LeaseAuthorityUnobservable detail) ->
          pure (Left (LeaseExecutionCasUnobservable detail))
        Left _ -> retryAfter maybeRecovery now

  retryAfter maybeRecovery now =
    waitAndRetry maybeRecovery now (nextAuthorityTick now)

  waitAndRetry maybeRecovery now requestedWake
    | now >= leaseAcquireDeadline request =
        pure (Left (LeaseExecutionAcquireTimedOut (leaseAcquireDeadline request)))
    | otherwise = do
        waited <-
          leaseInterpreterWaitUntil
            interpreter
            (min requestedWake (leaseAcquireDeadline request))
        case waited of
          Left detail -> pure (Left (LeaseExecutionClockUnobservable detail))
          Right () -> acquireLoop maybeRecovery

-- | Validate current ownership, execute through the injected deadline/loss
-- monitor, then re-observe ownership before returning an action result.
runLeaseWorkWith
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> LeasePolicy
  -> ModelBObjectCoordinate
  -> LeaseWork
  -> LeaseGrant
  -> (LeaseUsePermit -> m (Either Text result))
  -> m (Either LeaseExecutionError result)
runLeaseWorkWith interpreter policy coordinate work grant action = do
  withAuthorityNow interpreter $ \now -> do
    observation <- modelBObserve adapter coordinate
    case authorizeLeaseWork policy now work grant observation of
      LeaseUseRefused refusal -> pure (Left (LeaseExecutionRefused refusal))
      LeaseUseAuthorized permit -> do
        bounded <-
          leaseInterpreterRunBounded
            interpreter
            (leaseUseDeadline permit)
            ownershipProbe
            (action permit)
        case bounded of
          Left failure -> pure (Left (LeaseExecutionBoundedFailure failure))
          Right actionResult ->
            withAuthorityNow interpreter $ \finishedAt -> do
              finalOwnership <- ownershipProbe
              case finalOwnership of
                LeaseLost refusal -> pure (Left (LeaseExecutionRefused refusal))
                LeaseStillOwned
                  | finishedAt > leaseUseDeadline permit ->
                      pure
                        ( Left
                            ( LeaseExecutionActionExceededDeadline
                                finishedAt
                                (leaseUseDeadline permit)
                            )
                        )
                  | otherwise ->
                      pure $ case actionResult of
                        Left detail -> Left (LeaseExecutionActionFailed detail)
                        Right result -> Right result
 where
  adapter = leaseInterpreterModelB interpreter
  ownershipProbe = do
    observedAtResult <- leaseInterpreterAuthorityNow interpreter
    case observedAtResult of
      Left detail ->
        pure
          ( LeaseLost
              (LeaseAuthorityUnobservable ("authority clock: " <> detail))
          )
      Right observedAt -> do
        observed <- modelBObserve adapter coordinate
        pure (leaseOwnershipStatus observedAt grant observed)

fencedCommitPermitWith
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> ModelBObjectCoordinate
  -> LeaseGrant
  -> m (Either LeaseExecutionError FencedCommitPermit)
fencedCommitPermitWith interpreter coordinate grant = do
  withAuthorityNow interpreter $ \now -> do
    observation <- modelBObserve (leaseInterpreterModelB interpreter) coordinate
    pure $ case decideFencedCommit now grant observation of
      LeaseCommitAuthorized permit -> Right permit
      LeaseCommitRefused refusal -> Left (LeaseExecutionRefused refusal)

-- | Owner/fence checked idempotent release.  A conflict is re-observed and
-- retried only within the smaller of the acquisition retry budget and the
-- grant expiry.  An already-applied release succeeds even when observed later.
releaseLeaseWith
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> LeasePolicy
  -> ModelBObjectCoordinate
  -> LeaseGrant
  -> m (Either LeaseExecutionError ())
releaseLeaseWith interpreter policy coordinate grant = do
  withAuthorityNow interpreter $ \startedAt -> do
    let releaseDeadline =
          min
            (leaseGrantExpiresAt grant)
            (addAuthorityDuration startedAt (leasePolicyAcquireTimeout policy))
    releaseLoop releaseDeadline
 where
  adapter = leaseInterpreterModelB interpreter

  releaseLoop deadline = do
    withAuthorityNow interpreter $ \now -> do
      observation <- modelBObserve adapter coordinate
      case decideLeaseRelease now coordinate grant observation of
        LeaseReleaseAlreadyApplied -> pure (Right ())
        LeaseReleaseRefused refusal ->
          pure (Left (LeaseExecutionRefused refusal))
        LeaseReleaseCompareAndSwap casRequest
          | now >= deadline -> pure (Left (LeaseExecutionReleaseTimedOut deadline))
          | otherwise -> do
              casResult <- modelBCompareAndSwap adapter casRequest
              case casResult of
                ModelBCasApplied _ _ -> releaseLoop deadline
                ModelBCasConflict _ -> do
                  waited <-
                    leaseInterpreterWaitUntil
                      interpreter
                      (min deadline (nextAuthorityTick now))
                  case waited of
                    Left detail ->
                      pure (Left (LeaseExecutionClockUnobservable detail))
                    Right () -> releaseLoop deadline
                ModelBCasRefusedCorrupt detail ->
                  pure (Left (LeaseExecutionCasCorrupt detail))
                ModelBCasUnobservable detail ->
                  pure (Left (LeaseExecutionCasUnobservable detail))

recoveryPredecessor
  :: LeasePolicy
  -> ModelBObservation LeaseProjection
  -> Either LeaseRefusal LeaseRecoveryPredecessor
recoveryPredecessor policy observation =
  case observation of
    ModelBMissing -> Left LeaseAuthorityMissing
    ModelBCorrupt detail -> Left (LeaseAuthorityCorrupt detail)
    ModelBUnobservable detail -> Left (LeaseAuthorityUnobservable detail)
    ModelBObserved _ projection ->
      case leaseProjectionRecoveryPredecessor policy projection of
        Just predecessor -> Right predecessor
        Nothing ->
          Left
            ( LeaseAuthorityCorrupt
                "lease recovery requested without an active or released predecessor"
            )

acquisitionResult
  :: Maybe LeaseRecoveryPredecessor
  -> Either LeaseRefusal LeaseGrant
  -> Either LeaseExecutionError LeaseAcquisition
acquisitionResult predecessor =
  either
    (Left . LeaseExecutionRefused)
    ( \grant ->
        Right
          LeaseAcquisition
            { leaseAcquisitionGrant = grant
            , leaseAcquisitionRecoveryPredecessor = predecessor
            }
    )

nextAuthorityTick :: AuthorityTime -> AuthorityTime
nextAuthorityTick now =
  authorityTimeFromMicros (authorityTimeMicros now + 1)

withAuthorityNow
  :: (Monad m)
  => LeaseInterpreter m inventory
  -> (AuthorityTime -> m (Either LeaseExecutionError value))
  -> m (Either LeaseExecutionError value)
withAuthorityNow interpreter continue = do
  observed <- leaseInterpreterAuthorityNow interpreter
  case observed of
    Left detail -> pure (Left (LeaseExecutionClockUnobservable detail))
    Right now -> continue now
