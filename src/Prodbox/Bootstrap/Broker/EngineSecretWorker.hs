{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

-- | Crash-safe composition of the Bootstrap Broker's one-shot secret worker.
--
-- The driver owns no Kubernetes, Vault, or object-store coordinates. Its
-- boundary contains only the exact worker lifecycle and fixed checkpoint
-- operations. The rank-2 checkpoint-permit hook forces every create/CAS
-- attempt through a newly minted, closed 'BootstrapStoreMutationPermit' and
-- supplies the fresh monotonic observation used to validate that permit.
module Prodbox.Bootstrap.Broker.EngineSecretWorker
  ( EngineSecretWorkerBoundary (..)
  , EngineSecretWorkerError (..)
  , driveSecretWorker
  , reconcileAuthoritativeSecretWorkerResult
  )
where

import Control.Monad (void)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapSessionFence
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffectPermit
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceOperationDeadline
  , bootstrapFenceOwnerNonce
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  , storeMutationPermitActionDigest
  , storeMutationPermitDeadline
  , storeMutationPermitFenceGeneration
  , storeMutationPermitMutation
  , storeMutationPermitOperationDeadline
  , storeMutationPermitOwnerNonce
  , storeMutationPermitRequestDigest
  , storeMutationPermitStorageGeneration
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( ExecutedSecretWorker
  , RawSecretWorkerReceipt
  , RunningSecretWorker
  , SecretFreeWorkerRequest
  , SecretWorkerAttestationObservation
  , SecretWorkerAttestationRefusal
  , SecretWorkerCleanupBinding
  , SecretWorkerCleanupRefusal
  , SecretWorkerDurableCheckpoint
  , SecretWorkerDurableResult
  , SecretWorkerEffectPermit
  , SecretWorkerEffectRefusal (..)
  , SecretWorkerInterruption (..)
  , SecretWorkerLifecycleObservation
  , SecretWorkerOperation
  , SecretWorkerReceipt
  , SecretWorkerReceiptRefusal
  , SecretWorkerRecoveryDecision (..)
  , SecretWorkerRecoveryRefusal
  , advanceSecretWorkerCleanupCheckpoint
  , attestSecretWorker
  , authoritativelyRecoveredWorkerCheckpoint
  , authorizeSecretWorkerEffect
  , captureSecretWorkerReceipt
  , decideSecretWorkerRecovery
  , executeAuthorizedSecretWorker
  , noSecretWorkerReceipt
  , receiptCapturedCheckpoint
  , secretWorkerCheckpointReceipt
  , secretWorkerCheckpointRequest
  , secretWorkerCheckpointResult
  , secretWorkerCleanupBinding
  , secretWorkerDurableResultOperation
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOperation
  , secretWorkerRequestOperationDeadline
  , secretWorkerRequestOwnerNonce
  , secretWorkerRequestStorageGeneration
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( StoreBoundaryError
  , StoreReadBack (..)
  , StoreVersion
  , StoreWriteResult (..)
  )
import Prodbox.Bootstrap.Broker.Types (ArtifactDigest)
import Prodbox.ControlPlane.Deadline
  ( MonotonicInstant
  , deadlineExpired
  )

-- | Exact physical and durable operations admitted to the worker driver.
-- There is no generic command, executable, Vault path, bucket, or object key.
data EngineSecretWorkerBoundary m boundaryError = EngineSecretWorkerBoundary
  { observeSecretWorkerMonotonicNow
      :: m (Either boundaryError MonotonicInstant)
  , allocateSecretWorkerRequest
      :: SecretWorkerOperation
      -> BootstrapSessionFence
      -> m (Either boundaryError SecretFreeWorkerRequest)
  , createSecretWorkerWorkload
      :: SecretFreeWorkerRequest
      -> m (Either boundaryError ())
  , observeSecretWorkerAttestation
      :: SecretFreeWorkerRequest
      -> m (Either boundaryError SecretWorkerAttestationObservation)
  , discardUnreceiptedSecretWorker
      :: SecretFreeWorkerRequest
      -> SecretWorkerInterruption
      -> m (Either boundaryError ())
  , withSecretWorkerCheckpointPermit
      :: forall result
       . BootstrapSessionFence
      -> BootstrapStoreMutation
      -> (MonotonicInstant -> BootstrapStoreMutationPermit -> m result)
      -> m (Either boundaryError result)
  , readSecretWorkerCheckpoint
      :: m (Either StoreBoundaryError (StoreReadBack SecretWorkerDurableCheckpoint))
  , createSecretWorkerCheckpoint
      :: BootstrapStoreMutationPermit
      -> SecretWorkerDurableCheckpoint
      -> m (Either StoreBoundaryError (StoreWriteResult SecretWorkerDurableCheckpoint))
  , casSecretWorkerCheckpoint
      :: BootstrapStoreMutationPermit
      -> StoreVersion
      -> SecretWorkerDurableCheckpoint
      -> m (Either StoreBoundaryError (StoreWriteResult SecretWorkerDurableCheckpoint))
  , revokeSecretWorkerSession
      :: SecretWorkerCleanupBinding
      -> m (Either boundaryError SecretWorkerLifecycleObservation)
  , observeSecretWorkerExit
      :: SecretWorkerCleanupBinding
      -> m (Either boundaryError SecretWorkerLifecycleObservation)
  , deleteSecretWorkerPod
      :: SecretWorkerCleanupBinding
      -> m (Either boundaryError SecretWorkerLifecycleObservation)
  , observeSecretWorkerAbsence
      :: SecretWorkerCleanupBinding
      -> m (Either boundaryError SecretWorkerLifecycleObservation)
  }

-- | Structured refusal surface. Secret-bearing values cannot enter any
-- constructor; underlying store and protocol refusals remain inspectable.
data EngineSecretWorkerError boundaryError
  = EngineSecretWorkerBoundaryRefused !boundaryError
  | EngineSecretWorkerStoreRefused !StoreBoundaryError
  | EngineSecretWorkerStoredRequestBindingMismatch
  | EngineSecretWorkerCheckpointPermitMutationMismatch
      !BootstrapStoreMutation
      !BootstrapStoreMutation
  | EngineSecretWorkerCheckpointPermitFenceMismatch
  | EngineSecretWorkerCheckpointPermitDeadlineElapsed
  | EngineSecretWorkerCheckpointWriteConflict
  | EngineSecretWorkerCheckpointWriteMismatch
  | EngineSecretWorkerCheckpointReadBackMismatch
  | EngineSecretWorkerCheckpointResultMissing
  | EngineSecretWorkerAuthoritativeCheckpointMissing
  | EngineSecretWorkerAuthoritativeResultMismatch
  | EngineSecretWorkerRecoveryRefused !SecretWorkerRecoveryRefusal
  | EngineSecretWorkerRecoveryDestroyedAndRefused !SecretWorkerInterruption
  | EngineSecretWorkerRecoveryDecisionUnexpected !SecretWorkerRecoveryDecision
  | EngineSecretWorkerRepromptWasNotFresh
  | EngineSecretWorkerAttestationRefused !SecretWorkerAttestationRefusal
  | EngineSecretWorkerEffectRefused !SecretWorkerEffectRefusal
  | EngineSecretWorkerReceiptRefused !SecretWorkerReceiptRefusal
  | EngineSecretWorkerCleanupRefused !SecretWorkerCleanupRefusal
  deriving stock (Eq, Show)

data PersistedCheckpoint = PersistedCheckpoint
  { persistedVersion :: !StoreVersion
  , persistedCheckpoint :: !SecretWorkerDurableCheckpoint
  }

-- | Execute or recover one secret-worker operation. The fixed checkpoint is
-- read before any request is allocated. An incomplete checkpoint can resume
-- only under the identical operation/fence/action/request/storage/deadline
-- binding. A completed, absent predecessor may be CAS-rolled to a freshly
-- allocated request. Success is returned only after the absent checkpoint is
-- durably read back.
driveSecretWorker
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> m (Either boundaryError BootstrapVaultEffectPermit)
  -> ( forall scope
        . BootstrapVaultEffectPermit
       -> SecretWorkerEffectPermit
       -> RunningSecretWorker scope
       %1 -> m
               ( Either
                   boundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
               )
     )
  -> (result -> Either boundaryError SecretWorkerDurableResult)
  -> ( SecretWorkerReceipt
       -> SecretWorkerDurableResult
       -> m (Either boundaryError result)
     )
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (SecretWorkerReceipt, result)
       )
driveSecretWorker boundary interruption operation fence refreshVaultPermit runOperation encodeResult recoverResult = do
  loaded <- loadCheckpoint boundary
  case loaded of
    Left failure -> pure (Left failure)
    Right StoreObjectAbsent ->
      beginFreshWorker
        boundary
        interruption
        operation
        fence
        refreshVaultPermit
        Nothing
        Nothing
        runOperation
        encodeResult
    Right (StoreObjectPresent version _ checkpoint) ->
      recoverStoredWorker
        boundary
        interruption
        operation
        fence
        refreshVaultPermit
        PersistedCheckpoint
          { persistedVersion = version
          , persistedCheckpoint = checkpoint
          }
        runOperation
        encodeResult
        recoverResult

-- | Reconcile the worker journal after an authoritative outer recovery has
-- established the exact encrypted/non-secret result of a physical effect.
-- A pre-receipt worker is destroyed and terminalized without replay. A
-- receipted worker resumes only mandatory cleanup, and its persisted result
-- must exactly equal the authoritative observation.
reconcileAuthoritativeSecretWorkerResult
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretWorkerDurableResult
  -> m (Either (EngineSecretWorkerError boundaryError) ())
reconcileAuthoritativeSecretWorkerResult boundary interruption operation fence authoritativeResult
  | secretWorkerDurableResultOperation authoritativeResult /= operation =
      pure (Left EngineSecretWorkerAuthoritativeResultMismatch)
  | otherwise = do
      loaded <- loadCheckpoint boundary
      case loaded of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent ->
          pure (Left EngineSecretWorkerAuthoritativeCheckpointMissing)
        Right (StoreObjectPresent version _ checkpoint) ->
          case secretWorkerCheckpointRequest checkpoint of
            Left refusal ->
              pure (Left (EngineSecretWorkerRecoveryRefused refusal))
            Right request
              | not (requestMatchesInvocation operation fence request) ->
                  pure (Left EngineSecretWorkerStoredRequestBindingMismatch)
              | otherwise ->
                  reconcileRequest
                    request
                    PersistedCheckpoint
                      { persistedVersion = version
                      , persistedCheckpoint = checkpoint
                      }
 where
  reconcileRequest request persisted =
    case ( secretWorkerCheckpointReceipt (persistedCheckpoint persisted)
         , secretWorkerCheckpointResult (persistedCheckpoint persisted)
         ) of
      (Nothing, Nothing) -> do
        discarded <- discardUnreceiptedSecretWorker boundary request interruption
        case discarded of
          Left boundaryError ->
            pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
          Right () ->
            case authoritativelyRecoveredWorkerCheckpoint
              request
              authoritativeResult of
              Left refusal ->
                pure (Left (EngineSecretWorkerReceiptRefused refusal))
              Right terminal -> do
                persistedTerminal <-
                  persistCheckpointCas
                    boundary
                    fence
                    (persistedVersion persisted)
                    terminal
                pure (void persistedTerminal)
      (Nothing, Just observedResult)
        | observedResult == authoritativeResult -> pure (Right ())
        | otherwise -> pure (Left EngineSecretWorkerAuthoritativeResultMismatch)
      (Just _, Just observedResult)
        | observedResult /= authoritativeResult ->
            pure (Left EngineSecretWorkerAuthoritativeResultMismatch)
        | otherwise -> do
            cleaned <-
              completeWorkerCleanup
                boundary
                interruption
                fence
                request
                persisted
                ( decideSecretWorkerRecovery
                    request
                    interruption
                    (persistedCheckpoint persisted)
                )
            pure (void cleaned)
      (Just _, Nothing) ->
        pure (Left EngineSecretWorkerCheckpointResultMissing)

recoverStoredWorker
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> m (Either boundaryError BootstrapVaultEffectPermit)
  -> PersistedCheckpoint
  -> ( forall scope
        . BootstrapVaultEffectPermit
       -> SecretWorkerEffectPermit
       -> RunningSecretWorker scope
       %1 -> m
               ( Either
                   boundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
               )
     )
  -> (result -> Either boundaryError SecretWorkerDurableResult)
  -> ( SecretWorkerReceipt
       -> SecretWorkerDurableResult
       -> m (Either boundaryError result)
     )
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (SecretWorkerReceipt, result)
       )
recoverStoredWorker boundary interruption operation fence refreshVaultPermit persisted runOperation encodeResult recoverResult =
  case secretWorkerCheckpointRequest (persistedCheckpoint persisted) of
    Left refusal -> pure (Left (EngineSecretWorkerRecoveryRefused refusal))
    Right storedRequest ->
      let decision =
            decideSecretWorkerRecovery
              storedRequest
              interruption
              (persistedCheckpoint persisted)
          bindingMatches = requestMatchesInvocation operation fence storedRequest
       in case decision of
            SecretWorkerRecoveryComplete receipt
              | bindingMatches -> recoverCompleted persisted receipt
              | otherwise ->
                  beginFreshWorker
                    boundary
                    interruption
                    operation
                    fence
                    refreshVaultPermit
                    (Just (persistedVersion persisted))
                    Nothing
                    runOperation
                    encodeResult
            authoritativeDecision@(SecretWorkerRecoveryAuthoritativeComplete _)
              | bindingMatches ->
                  pure
                    ( Left
                        ( EngineSecretWorkerRecoveryDecisionUnexpected
                            authoritativeDecision
                        )
                    )
              | otherwise ->
                  beginFreshWorker
                    boundary
                    interruption
                    operation
                    fence
                    refreshVaultPermit
                    (Just (persistedVersion persisted))
                    Nothing
                    runOperation
                    encodeResult
            _
              | not bindingMatches ->
                  pure (Left EngineSecretWorkerStoredRequestBindingMismatch)
            SecretWorkerRecoveryDestroyAndReprompt oldRequest _ -> do
              discarded <-
                discardUnreceiptedSecretWorker boundary oldRequest interruption
              case discarded of
                Left boundaryError ->
                  pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
                Right () ->
                  beginFreshWorker
                    boundary
                    interruption
                    operation
                    fence
                    refreshVaultPermit
                    (Just (persistedVersion persisted))
                    (Just oldRequest)
                    runOperation
                    encodeResult
            SecretWorkerRecoveryDestroyAndRefuse refusedInterruption -> do
              discarded <-
                discardUnreceiptedSecretWorker
                  boundary
                  storedRequest
                  refusedInterruption
              pure $ case discarded of
                Left boundaryError ->
                  Left (EngineSecretWorkerBoundaryRefused boundaryError)
                Right () ->
                  Left
                    ( EngineSecretWorkerRecoveryDestroyedAndRefused
                        refusedInterruption
                    )
            SecretWorkerRecoveryRefused refusal ->
              pure (Left (EngineSecretWorkerRecoveryRefused refusal))
            cleanupDecision -> do
              cleaned <-
                completeWorkerCleanup
                  boundary
                  interruption
                  fence
                  storedRequest
                  persisted
                  cleanupDecision
              case cleaned of
                Left failure -> pure (Left failure)
                Right (completed, receipt) -> recoverCompleted completed receipt
 where
  recoverCompleted completed receipt =
    case secretWorkerCheckpointResult (persistedCheckpoint completed) of
      Nothing -> pure (Left EngineSecretWorkerCheckpointResultMissing)
      Just durableResult -> do
        recovered <- recoverResult receipt durableResult
        pure $ case recovered of
          Left boundaryError -> Left (EngineSecretWorkerBoundaryRefused boundaryError)
          Right result -> Right (receipt, result)

beginFreshWorker
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> m (Either boundaryError BootstrapVaultEffectPermit)
  -> Maybe StoreVersion
  -> Maybe SecretFreeWorkerRequest
  -> ( forall scope
        . BootstrapVaultEffectPermit
       -> SecretWorkerEffectPermit
       -> RunningSecretWorker scope
       %1 -> m
               ( Either
                   boundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
               )
     )
  -> (result -> Either boundaryError SecretWorkerDurableResult)
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (SecretWorkerReceipt, result)
       )
beginFreshWorker boundary interruption operation fence refreshVaultPermit previousVersion forbiddenRequest runOperation encodeResult = do
  allocated <- allocateSecretWorkerRequest boundary operation fence
  case allocated of
    Left boundaryError ->
      pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
    Right request
      | Just request == forbiddenRequest ->
          pure (Left EngineSecretWorkerRepromptWasNotFresh)
      | not (requestMatchesInvocation operation fence request) ->
          pure (Left EngineSecretWorkerStoredRequestBindingMismatch)
      | otherwise -> do
          journaled <- case previousVersion of
            Nothing ->
              persistCheckpointCreate
                boundary
                fence
                (noSecretWorkerReceipt request)
            Just version ->
              persistCheckpointCas
                boundary
                fence
                version
                (noSecretWorkerReceipt request)
          case journaled of
            Left failure -> pure (Left failure)
            Right persisted ->
              runFreshWorker
                boundary
                interruption
                fence
                refreshVaultPermit
                request
                persisted
                runOperation
                encodeResult

runFreshWorker
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> BootstrapSessionFence
  -> m (Either boundaryError BootstrapVaultEffectPermit)
  -> SecretFreeWorkerRequest
  -> PersistedCheckpoint
  -> ( forall scope
        . BootstrapVaultEffectPermit
       -> SecretWorkerEffectPermit
       -> RunningSecretWorker scope
       %1 -> m
               ( Either
                   boundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
               )
     )
  -> (result -> Either boundaryError SecretWorkerDurableResult)
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (SecretWorkerReceipt, result)
       )
runFreshWorker boundary interruption fence refreshVaultPermit request persisted runOperation encodeResult = do
  created <- createSecretWorkerWorkload boundary request
  case created of
    Left boundaryError ->
      pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
    Right () -> do
      observed <- observeSecretWorkerAttestation boundary request
      case observed of
        Left boundaryError ->
          refuseBeforeReceipt
            boundary
            request
            SecretWorkerAttestationInvalidated
            (EngineSecretWorkerBoundaryRefused boundaryError)
        Right attestation ->
          case attestSecretWorker request attestation of
            Left refusal ->
              refuseBeforeReceipt
                boundary
                request
                SecretWorkerAttestationInvalidated
                (EngineSecretWorkerAttestationRefused refusal)
            Right attested -> do
              refreshed <- refreshVaultPermit
              case refreshed of
                Left boundaryError ->
                  refuseBeforeReceipt
                    boundary
                    request
                    SecretWorkerFenceLost
                    (EngineSecretWorkerBoundaryRefused boundaryError)
                Right physicalPermit -> do
                  observedNow <- observeSecretWorkerMonotonicNow boundary
                  case observedNow of
                    Left boundaryError ->
                      refuseBeforeReceipt
                        boundary
                        request
                        SecretWorkerFenceLost
                        (EngineSecretWorkerBoundaryRefused boundaryError)
                    Right now ->
                      case authorizeSecretWorkerEffect now attested physicalPermit of
                        Left refusal ->
                          refuseBeforeReceipt
                            boundary
                            request
                            (effectRefusalInterruption refusal)
                            (EngineSecretWorkerEffectRefused refusal)
                        Right effectPermit -> do
                          ran <-
                            executeAuthorizedSecretWorker
                              effectPermit
                              (runOperation physicalPermit effectPermit)
                          let
                            executed = case ran of
                              Left boundaryError ->
                                Left
                                  (EngineSecretWorkerBoundaryRefused boundaryError)
                              Right (completed, rawReceipt, result) ->
                                case encodeResult result of
                                  Left boundaryError ->
                                    Left
                                      ( EngineSecretWorkerBoundaryRefused
                                          boundaryError
                                      )
                                  Right durableResult ->
                                    case captureSecretWorkerReceipt
                                      completed
                                      rawReceipt
                                      durableResult of
                                      Left refusal ->
                                        Left
                                          ( EngineSecretWorkerReceiptRefused
                                              refusal
                                          )
                                      Right captured -> Right (captured, result)
                          case executed of
                            Left failure ->
                              refuseBeforeReceipt
                                boundary
                                request
                                interruption
                                failure
                            Right (captured, result) -> do
                              receiptPersisted <-
                                persistCheckpointCas
                                  boundary
                                  fence
                                  (persistedVersion persisted)
                                  (receiptCapturedCheckpoint captured)
                              case receiptPersisted of
                                Left failure -> pure (Left failure)
                                Right checkpoint -> do
                                  cleaned <-
                                    completeWorkerCleanup
                                      boundary
                                      interruption
                                      fence
                                      request
                                      checkpoint
                                      ( decideSecretWorkerRecovery
                                          request
                                          interruption
                                          (persistedCheckpoint checkpoint)
                                      )
                                  pure
                                    ( fmap
                                        (\(_, receipt) -> (receipt, result))
                                        cleaned
                                    )

completeWorkerCleanup
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
  -> PersistedCheckpoint
  -> SecretWorkerRecoveryDecision
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (PersistedCheckpoint, SecretWorkerReceipt)
       )
completeWorkerCleanup boundary interruption fence request persisted decision =
  case decision of
    SecretWorkerRecoveryRevokeSession receipt ->
      advanceCleanup (revokeSecretWorkerSession boundary) receipt
    SecretWorkerRecoveryAwaitExit receipt ->
      advanceCleanup (observeSecretWorkerExit boundary) receipt
    SecretWorkerRecoveryDeletePod receipt ->
      advanceCleanup (deleteSecretWorkerPod boundary) receipt
    SecretWorkerRecoveryObserveAbsence receipt ->
      advanceCleanup (observeSecretWorkerAbsence boundary) receipt
    SecretWorkerRecoveryComplete receipt -> pure (Right (persisted, receipt))
    SecretWorkerRecoveryRefused refusal ->
      pure (Left (EngineSecretWorkerRecoveryRefused refusal))
    unexpected ->
      pure (Left (EngineSecretWorkerRecoveryDecisionUnexpected unexpected))
 where
  advanceCleanup observe receipt = do
    observed <- observe (secretWorkerCleanupBinding receipt)
    case observed of
      Left boundaryError ->
        pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
      Right lifecycleObservation ->
        case advanceSecretWorkerCleanupCheckpoint
          request
          (persistedCheckpoint persisted)
          lifecycleObservation of
          Left refusal ->
            pure (Left (EngineSecretWorkerCleanupRefused refusal))
          Right nextCheckpoint -> do
            written <-
              persistCheckpointCas
                boundary
                fence
                (persistedVersion persisted)
                nextCheckpoint
            case written of
              Left failure -> pure (Left failure)
              Right nextPersisted ->
                completeWorkerCleanup
                  boundary
                  interruption
                  fence
                  request
                  nextPersisted
                  ( decideSecretWorkerRecovery
                      request
                      interruption
                      (persistedCheckpoint nextPersisted)
                  )

refuseBeforeReceipt
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretFreeWorkerRequest
  -> SecretWorkerInterruption
  -> EngineSecretWorkerError boundaryError
  -> m (Either (EngineSecretWorkerError boundaryError) result)
refuseBeforeReceipt boundary request interruption originalFailure = do
  discarded <- discardUnreceiptedSecretWorker boundary request interruption
  pure $ case discarded of
    Left boundaryError -> Left (EngineSecretWorkerBoundaryRefused boundaryError)
    Right () -> Left originalFailure

effectRefusalInterruption
  :: SecretWorkerEffectRefusal -> SecretWorkerInterruption
effectRefusalInterruption refusal = case refusal of
  SecretWorkerEffectDeadlineElapsed -> SecretWorkerDeadlineElapsed
  _ -> SecretWorkerFenceLost

requestMatchesInvocation
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
  -> Bool
requestMatchesInvocation operation fence request =
  secretWorkerRequestOperation request == operation
    && secretWorkerRequestFenceGeneration request
      == bootstrapFenceGeneration fence
    && secretWorkerRequestOwnerNonce request == bootstrapFenceOwnerNonce fence
    && secretWorkerRequestActionDigest request
      == bootstrapFenceActionDigest fence
    && secretWorkerRequestDigest request == bootstrapFenceRequestDigest fence
    && secretWorkerRequestStorageGeneration request
      == bootstrapFenceStorageGeneration fence
    && secretWorkerRequestOperationDeadline request
      == bootstrapFenceOperationDeadline fence

loadCheckpoint
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> m
       ( Either
           (EngineSecretWorkerError boundaryError)
           (StoreReadBack SecretWorkerDurableCheckpoint)
       )
loadCheckpoint boundary = do
  loaded <- readSecretWorkerCheckpoint boundary
  pure (either (Left . EngineSecretWorkerStoreRefused) Right loaded)

persistCheckpointCreate
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> BootstrapSessionFence
  -> SecretWorkerDurableCheckpoint
  -> m (Either (EngineSecretWorkerError boundaryError) PersistedCheckpoint)
persistCheckpointCreate boundary fence checkpoint =
  persistCheckpoint
    boundary
    fence
    BootstrapStoreCreateSecretWorkerCheckpoint
    (\permit -> createSecretWorkerCheckpoint boundary permit checkpoint)
    checkpoint

persistCheckpointCas
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> BootstrapSessionFence
  -> StoreVersion
  -> SecretWorkerDurableCheckpoint
  -> m (Either (EngineSecretWorkerError boundaryError) PersistedCheckpoint)
persistCheckpointCas boundary fence expectedVersion checkpoint =
  persistCheckpoint
    boundary
    fence
    BootstrapStoreCasSecretWorkerCheckpoint
    ( \permit ->
        casSecretWorkerCheckpoint boundary permit expectedVersion checkpoint
    )
    checkpoint

persistCheckpoint
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> BootstrapSessionFence
  -> BootstrapStoreMutation
  -> ( BootstrapStoreMutationPermit
       -> m
            ( Either
                StoreBoundaryError
                (StoreWriteResult SecretWorkerDurableCheckpoint)
            )
     )
  -> SecretWorkerDurableCheckpoint
  -> m (Either (EngineSecretWorkerError boundaryError) PersistedCheckpoint)
persistCheckpoint boundary fence mutation write checkpoint = do
  attempted <-
    withSecretWorkerCheckpointPermit boundary fence mutation $ \now permit -> do
      let permitValidation = validateCheckpointPermit now fence mutation permit
      case permitValidation of
        Left failure -> pure (Left failure)
        Right () -> do
          result <- write permit
          pure $ do
            writeResult <-
              either (Left . EngineSecretWorkerStoreRefused) Right result
            exactWriteEvidence checkpoint writeResult
  case attempted of
    Left boundaryError ->
      pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
    Right (Left failure) -> pure (Left failure)
    Right (Right (version, digest)) -> do
      readBack <- readSecretWorkerCheckpoint boundary
      pure $ do
        observed <-
          either (Left . EngineSecretWorkerStoreRefused) Right readBack
        case observed of
          StoreObjectPresent observedVersion observedDigest observedCheckpoint
            | observedVersion == version
                && observedDigest == digest
                && observedCheckpoint == checkpoint ->
                Right
                  PersistedCheckpoint
                    { persistedVersion = version
                    , persistedCheckpoint = checkpoint
                    }
          _ -> Left EngineSecretWorkerCheckpointReadBackMismatch

exactWriteEvidence
  :: SecretWorkerDurableCheckpoint
  -> StoreWriteResult SecretWorkerDurableCheckpoint
  -> Either
       (EngineSecretWorkerError boundaryError)
       (StoreVersion, ArtifactDigest)
exactWriteEvidence expected result = case result of
  StoreWriteApplied version digest observed
    | observed == expected -> Right (version, digest)
    | otherwise -> Left EngineSecretWorkerCheckpointWriteMismatch
  StoreWriteConflict (StoreObjectPresent version digest observed)
    | observed == expected -> Right (version, digest)
    | otherwise -> Left EngineSecretWorkerCheckpointWriteConflict
  StoreWriteConflict StoreObjectAbsent ->
    Left EngineSecretWorkerCheckpointWriteConflict

validateCheckpointPermit
  :: MonotonicInstant
  -> BootstrapSessionFence
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> Either (EngineSecretWorkerError boundaryError) ()
validateCheckpointPermit now fence expectedMutation permit
  | storeMutationPermitMutation permit /= expectedMutation =
      Left
        ( EngineSecretWorkerCheckpointPermitMutationMismatch
            expectedMutation
            (storeMutationPermitMutation permit)
        )
  | deadlineExpired now (storeMutationPermitDeadline permit) =
      Left EngineSecretWorkerCheckpointPermitDeadlineElapsed
  | storeMutationPermitFenceGeneration permit /= bootstrapFenceGeneration fence
      || storeMutationPermitOwnerNonce permit /= bootstrapFenceOwnerNonce fence
      || storeMutationPermitActionDigest permit /= bootstrapFenceActionDigest fence
      || storeMutationPermitRequestDigest permit /= bootstrapFenceRequestDigest fence
      || storeMutationPermitStorageGeneration permit
        /= bootstrapFenceStorageGeneration fence
      || storeMutationPermitOperationDeadline permit
        /= bootstrapFenceOperationDeadline fence =
      Left EngineSecretWorkerCheckpointPermitFenceMismatch
  | otherwise = Right ()
