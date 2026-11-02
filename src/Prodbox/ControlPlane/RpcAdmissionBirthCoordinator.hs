{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One registration attempt preserves its original operation identity and bound.
-- The Authority owns birth transitions; this client owns only ordered submissions,
-- independent source publication and observation of the selected serving process.
module Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
  ( RpcBirthCoordinationRequest
  , mkRpcBirthCoordinationRequest
  , rpcBirthCoordinationScope
  , rpcBirthCoordinationDeadline
  , rpcBirthCoordinationGeneration
  , rpcBirthCoordinationKey
  , RpcBirthCoordinationStage (..)
  , RpcBirthCoordinationError (..)
  , RpcBirthCoordinationEffects (..)
  , RpcBirthPublicationEffects (..)
  , RpcBirthCoordinationResult
  , coordinatedRpcBirthDescriptor
  , coordinatedRpcBirthStatus
  , coordinateRpcBirth
  , coordinateRpcBirthWithTransport
  ) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , resolveAuthenticatedClientTransportDeadline
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import System.Timeout (timeout)

data RpcBirthCoordinationRequest
  = RpcBirthCoordinationRequest !AuthorityScope !AuthorityTime !Natural !Text

rpcBirthCoordinationScope :: RpcBirthCoordinationRequest -> AuthorityScope
rpcBirthCoordinationScope (RpcBirthCoordinationRequest value _ _ _) = value

rpcBirthCoordinationDeadline :: RpcBirthCoordinationRequest -> AuthorityTime
rpcBirthCoordinationDeadline (RpcBirthCoordinationRequest _ value _ _) = value

rpcBirthCoordinationGeneration :: RpcBirthCoordinationRequest -> Natural
rpcBirthCoordinationGeneration (RpcBirthCoordinationRequest _ _ value _) = value

rpcBirthCoordinationKey :: RpcBirthCoordinationRequest -> Text
rpcBirthCoordinationKey (RpcBirthCoordinationRequest _ _ _ value) = value

mkRpcBirthCoordinationRequest
  :: AuthorityScope
  -> AuthorityTime
  -> Natural
  -> Text
  -> Either RpcBirthCoordinationError RpcBirthCoordinationRequest
mkRpcBirthCoordinationRequest scope deadline generation key = do
  unless
    ( generation > 0
        && generation <= fromIntegral (maxBound :: Word64)
        && Text.length key == 32
        && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') key
    )
    (Left RpcBirthCoordinationRequestInvalid)
  pure (RpcBirthCoordinationRequest scope deadline generation key)

data RpcBirthCoordinationStage
  = CoordinationResolveTransport
  | CoordinationAttempt
  | CoordinationObserveInitial
  | CoordinationReadSource
  | CoordinationPrepare
  | CoordinationObservePrepared
  | CoordinationPublishSource
  | CoordinationConfirmSource
  | CoordinationReconcileRuntime
  | CoordinationObserveRuntime
  | CoordinationComplete
  | CoordinationObserveCompleted
  | CoordinationConfirmCompletedSource
  deriving (Eq, Show, Enum, Bounded)

data RpcBirthCoordinationError
  = RpcBirthCoordinationRequestInvalid
  | RpcBirthCoordinationClockUnavailable !RpcBirthCoordinationStage
  | RpcBirthCoordinationDeadlineReached !RpcBirthCoordinationStage
  | RpcBirthCoordinationTransportFailed !AuthenticatedClientError
  | RpcBirthCoordinationRequestFailed !RpcBirthCoordinationStage !RpcBirthClientError
  | RpcBirthCoordinationEffectFailed !RpcBirthCoordinationStage !Text
  | RpcBirthCoordinationObservationInvalid !RpcBirthCoordinationStage
  | RpcBirthCoordinationIdentityMismatch !RpcBirthCoordinationStage
  | RpcBirthCoordinationSourceConflict
  | RpcBirthCoordinationRetirementRequired !RpcBirthDescriptor
  | RpcBirthCoordinationPreparationExpired !RpcBirthDescriptor
  deriving (Eq, Show)

-- | Interpreter boundaries. An acknowledgement never mints source/runtime proof:
-- the fold always reads each independent surface back before the next mutation.
data RpcBirthCoordinationEffects m = RpcBirthCoordinationEffects
  { coordinationReadTime :: m (Either Text AuthorityTime)
  , coordinationObserve :: AuthorityTime -> m (Either RpcBirthClientError RpcBirthDescriptorObservation)
  , coordinationSubmit
      :: AuthorityTime -> RpcBirthCommand -> m (Either RpcBirthClientError RpcBirthStatus)
  , coordinationPublication :: RpcBirthPublicationEffects m
  }

data RpcBirthPublicationEffects m = RpcBirthPublicationEffects
  { coordinationReadSource :: AuthorityTime -> m (Either Text RpcBirthConfig)
  , coordinationPublishSource :: AuthorityTime -> RpcBirthConfig -> RpcBirthConfig -> m (Either Text ())
  , coordinationReconcileRuntime :: AuthorityTime -> RpcBirthDescriptor -> m (Either Text ())
  }

-- No constructor/record selector is exported: this is exact observed registration,
-- not a backup receipt, ordinary-writer permit or deployment qualification.
data RpcBirthCoordinationResult = RpcBirthCoordinationResult !RpcBirthDescriptor !RpcBirthStatus
  deriving (Eq, Show)

coordinatedRpcBirthDescriptor :: RpcBirthCoordinationResult -> RpcBirthDescriptor
coordinatedRpcBirthDescriptor (RpcBirthCoordinationResult descriptor _) = descriptor

coordinatedRpcBirthStatus :: RpcBirthCoordinationResult -> RpcBirthStatus
coordinatedRpcBirthStatus (RpcBirthCoordinationResult _ status) = status

coordinateRpcBirth
  :: (Monad m)
  => RpcBirthCoordinationEffects m
  -> RpcBirthCoordinationRequest
  -> m (Either RpcBirthCoordinationError RpcBirthCoordinationResult)
coordinateRpcBirth effects (RpcBirthCoordinationRequest scope parent generation key) = runExceptT $ do
  initial <- observe CoordinationObserveInitial parent
  source <- readSource CoordinationReadSource parent
  prepared <- case rpcBirthStatusPhase (rpcBirthObservationStatus initial) of
    BirthLegacy -> prepare source
    BirthRetired -> prepare source
    BirthRetiring -> retirement initial
    BirthPrepared -> requireIdentity CoordinationObserveInitial initial >> pure initial
    BirthArmed -> requireIdentity CoordinationObserveInitial initial >> pure initial
    BirthCommitted -> requireIdentity CoordinationObserveInitial initial >> pure initial
  descriptor <- requireIdentity CoordinationObservePrepared prepared
  let expected = pin descriptor
      alreadyCommitted = committed prepared
      bound = if alreadyCommitted then parent else min parent (rpcBirthDescriptorDeadline descriptor)
  unless
    (source == RpcBirthConfigLegacy || source == expected)
    (throwE RpcBirthCoordinationSourceConflict)
  now <- readTime CoordinationObservePrepared
  when
    (not alreadyCommitted && now >= rpcBirthDescriptorDeadline descriptor)
    (throwE (RpcBirthCoordinationPreparationExpired descriptor))
  -- The idempotent legacy-to-pin publication also fsyncs an already visible
  -- desired source after an interrupted rename. A source read alone cannot
  -- prove that its directory entry was durably published.
  publish <-
    bounded CoordinationPublishSource bound $
      coordinationPublishSource publication bound RpcBirthConfigLegacy expected
  either (throwE . RpcBirthCoordinationEffectFailed CoordinationPublishSource) pure publish
  confirmSource CoordinationConfirmSource bound expected
  if alreadyCommitted && rpcBirthObservationRequiresRegistration prepared
    then finish bound descriptor
    else do
      reconciled <-
        bounded CoordinationReconcileRuntime bound $
          coordinationReconcileRuntime publication bound descriptor
      either (throwE . RpcBirthCoordinationEffectFailed CoordinationReconcileRuntime) pure reconciled
      running <- observe CoordinationObserveRuntime bound
      confirmDescriptor CoordinationObserveRuntime descriptor running
      unless
        (rpcBirthObservationRequiresRegistration running)
        (throwE (RpcBirthCoordinationObservationInvalid CoordinationObserveRuntime))
      confirmSource CoordinationConfirmSource bound expected
      completion <-
        bounded CoordinationComplete bound $
          coordinationSubmit effects bound (CompleteRpcBirth generation key)
      final <- observe CoordinationObserveCompleted bound
      confirmDescriptor CoordinationObserveCompleted descriptor final
      unless (committed final && rpcBirthObservationRequiresRegistration final) $
        either
          (throwE . RpcBirthCoordinationRequestFailed CoordinationComplete)
          (const (throwE (RpcBirthCoordinationObservationInvalid CoordinationObserveCompleted)))
          completion
      confirmSource CoordinationConfirmCompletedSource bound expected
      pure (RpcBirthCoordinationResult descriptor (rpcBirthObservationStatus final))
 where
  publication = coordinationPublication effects
  readTime stage =
    ExceptT
      (first (const (RpcBirthCoordinationClockUnavailable stage)) <$> coordinationReadTime effects)
  bounded stage deadline action = do
    before <- readTime stage
    when (before >= deadline) (throwE (RpcBirthCoordinationDeadlineReached stage))
    result <- ExceptT (Right <$> action)
    after <- readTime stage
    when (after >= deadline) (throwE (RpcBirthCoordinationDeadlineReached stage))
    pure result
  observe stage deadline = do
    result <- bounded stage deadline (coordinationObserve effects deadline)
    either (throwE . RpcBirthCoordinationRequestFailed stage) pure result
  readSource stage deadline = do
    result <- bounded stage deadline (coordinationReadSource publication deadline)
    either (throwE . RpcBirthCoordinationEffectFailed stage) pure result
  confirmSource stage deadline expected = do
    actual <- readSource stage deadline
    unless (actual == expected) (throwE RpcBirthCoordinationSourceConflict)
  requireIdentity stage observation = case rpcBirthObservationDescriptor observation of
    Just descriptor
      | rpcBirthDescriptorScope descriptor == scope
      , rpcBirthDescriptorGeneration descriptor == generation
      , rpcBirthDescriptorKey descriptor == key ->
          pure descriptor
    _ -> throwE (RpcBirthCoordinationIdentityMismatch stage)
  confirmDescriptor stage descriptor observation = do
    actual <- requireIdentity stage observation
    unless (actual == descriptor) (throwE (RpcBirthCoordinationIdentityMismatch stage))
  retirement observation = do
    descriptor <- requireIdentity CoordinationObserveInitial observation
    throwE (RpcBirthCoordinationRetirementRequired descriptor)
  prepare source = do
    unless (source == RpcBirthConfigLegacy) (throwE RpcBirthCoordinationSourceConflict)
    result <-
      bounded CoordinationPrepare parent $
        coordinationSubmit effects parent (PrepareRpcBirth generation key)
    fresh <- observe CoordinationObservePrepared parent
    case rpcBirthStatusPhase (rpcBirthObservationStatus fresh) of
      BirthPrepared -> requireIdentity CoordinationObservePrepared fresh >> pure fresh
      BirthArmed -> requireIdentity CoordinationObservePrepared fresh >> pure fresh
      BirthCommitted -> requireIdentity CoordinationObservePrepared fresh >> pure fresh
      _ ->
        either
          (throwE . RpcBirthCoordinationRequestFailed CoordinationPrepare)
          (const (throwE (RpcBirthCoordinationObservationInvalid CoordinationObservePrepared)))
          result
  committed observation =
    rpcBirthStatusPhase (rpcBirthObservationStatus observation) == BirthCommitted
      && rpcBirthStatusCommitted (rpcBirthObservationStatus observation)
  finish deadline descriptor = do
    closing <- observe CoordinationObserveCompleted deadline
    confirmDescriptor CoordinationObserveCompleted descriptor closing
    unless
      (committed closing && rpcBirthObservationRequiresRegistration closing)
      (throwE (RpcBirthCoordinationObservationInvalid CoordinationObserveCompleted))
    confirmSource CoordinationConfirmCompletedSource deadline (pin descriptor)
    pure (RpcBirthCoordinationResult descriptor (rpcBirthObservationStatus closing))
  pin descriptor =
    RpcBirthConfigRegistered $
      RpcBirthConfigPin
        (authorityScopeText scope)
        generation
        (rpcBirthDescriptorDigest descriptor)

-- | Resolve the provider deadline once, then reuse its bounded transport for
-- every peer refresh/request. The outer bound also covers publication effects.
-- The rollout interpreter must independently own/stop its process tree; an outer
-- asynchronous timeout alone does not provide that physical guarantee.
coordinateRpcBirthWithTransport
  :: IO (Either Text AuthorityTime)
  -> AuthorityScope
  -> AuthorityTime
  -> Natural
  -> Text
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RpcBirthPublicationEffects IO
  -> IO (Either RpcBirthCoordinationError RpcBirthCoordinationResult)
coordinateRpcBirthWithTransport readTime scope parent generation key transport publication =
  case mkRpcBirthCoordinationRequest scope parent generation key of
    Left cause -> pure (Left cause)
    Right _ -> do
      resolved <-
        within CoordinationResolveTransport parent $
          first RpcBirthCoordinationTransportFailed
            <$> resolveAuthenticatedClientTransportDeadline parent transport
      case resolved of
        Left cause -> pure (Left cause)
        Right (deadline, boundedTransport) -> within CoordinationAttempt deadline $
          case mkRpcBirthCoordinationRequest scope deadline generation key of
            Left cause -> pure (Left cause)
            Right request ->
              coordinateRpcBirth
                ( RpcBirthCoordinationEffects
                    readTime
                    (\bound -> requestRpcBirthDescriptorWithin readTime bound scope boundedTransport)
                    (\bound -> requestRpcBirthWithin readTime bound scope boundedTransport)
                    publication
                )
                request
 where
  within stage deadline action = do
    observed <- readTime
    case observed of
      Left _ -> pure (Left (RpcBirthCoordinationClockUnavailable stage))
      Right now | now >= deadline -> pure (Left (RpcBirthCoordinationDeadlineReached stage))
      Right now -> do
        let remaining = authorityTimeMicros deadline - authorityTimeMicros now
            micros = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
        outcome <- timeout micros action
        closing <- readTime
        pure $ case closing of
          Left _ -> Left (RpcBirthCoordinationClockUnavailable stage)
          Right after | after >= deadline -> Left (RpcBirthCoordinationDeadlineReached stage)
          Right _ -> maybe (Left (RpcBirthCoordinationDeadlineReached stage)) id outcome
