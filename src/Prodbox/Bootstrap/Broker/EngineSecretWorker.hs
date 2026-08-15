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
  , SecretWorkerBindingSite (..)
  , SecretWorkerBindingField (..)
  , secretWorkerBindingSiteName
  , secretWorkerBindingFieldName
  , requestBindingMismatch
  , intentBindingMismatch
  , driveSecretWorker
  , reconcileAuthoritativeSecretWorkerResult
  )
where

import Control.Monad (void)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceGeneration
  , BootstrapSessionFence
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffectPermit
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
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
import Prodbox.Bootstrap.Broker.Request (RequestDigest)
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
  , SecretWorkerIntent
  , SecretWorkerInterruption (..)
  , SecretWorkerLifecycleObservation
  , SecretWorkerOperation
  , SecretWorkerReceipt
  , SecretWorkerReceiptRefusal
  , SecretWorkerRecoveryDecision (..)
  , SecretWorkerRecoveryRefusal (..)
  , advanceSecretWorkerCleanupCheckpoint
  , attestSecretWorker
  , authoritativelyRecoveredWorkerCheckpoint
  , authorizeSecretWorkerEffect
  , captureSecretWorkerReceipt
  , decideSecretWorkerRecovery
  , executeAuthorizedSecretWorker
  , noSecretWorkerReceipt
  , receiptCapturedCheckpoint
  , secretWorkerCheckpointIntent
  , secretWorkerCheckpointReceipt
  , secretWorkerCheckpointRequest
  , secretWorkerCheckpointResult
  , secretWorkerCleanupBinding
  , secretWorkerDurableResultOperation
  , secretWorkerIntentActionDigest
  , secretWorkerIntentCheckpoint
  , secretWorkerIntentFenceGeneration
  , secretWorkerIntentOperation
  , secretWorkerIntentOperationDeadline
  , secretWorkerIntentOwnerNonce
  , secretWorkerIntentRequestDigest
  , secretWorkerIntentStorageGeneration
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestIntent
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
import Prodbox.Bootstrap.Broker.Types (ArtifactDigest, VaultStorageGeneration)
import Prodbox.ControlPlane.AuthorityClock (OperationDeadline)
import Prodbox.ControlPlane.Deadline
  ( MonotonicInstant
  , deadlineExpired
  )
import Prodbox.Lifecycle.Lease (OwnerNonce)

-- | Exact physical and durable operations admitted to the worker driver.
-- There is no generic command, executable, Vault path, bucket, or object key.
data EngineSecretWorkerBoundary m boundaryError = EngineSecretWorkerBoundary
  { observeSecretWorkerMonotonicNow
      :: m (Either boundaryError MonotonicInstant)
  , allocateSecretWorkerIntent
      :: SecretWorkerOperation
      -> BootstrapSessionFence
      -> m (Either boundaryError SecretWorkerIntent)
  , createSecretWorkerWorkload
      :: SecretWorkerIntent
      -> m (Either boundaryError SecretFreeWorkerRequest)
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

-- | Sprint 2.50: which comparison produced a binding mismatch.
--
-- 'EngineSecretWorkerStoredRequestBindingMismatch' was payload-free and
-- produced at five distinct sites, so a durable checkpoint written by an
-- earlier invocation, a boundary that minted an intent for the wrong
-- invocation, and a boundary that created a workload for a different intent
-- all reached the operator as one word. That is the fifth instance of the
-- collapse Sprints 2.46 through 2.49 each closed one layer up, and the cost was
-- measured rather than assumed: this plan's own description of the stuck
-- checkpoint named the wrong number of differing fields, and the refusal was
-- the one thing that could have said so.
data SecretWorkerBindingSite
  = -- | A durable checkpoint's stored request against this invocation. The
    -- only site a stale-checkpoint wedge can reach.
    StoredRequestBinding
  | -- | A durable checkpoint's stored intent against this invocation, before
    -- any Pod UID was bound.
    StoredIntentBinding
  | -- | The boundary minted a fresh intent that does not match the invocation
    -- it was minted for. A caller or boundary defect, never stale state.
    FreshlyAllocatedIntentBinding
  | -- | The boundary created a workload for an intent other than the one it
    -- was handed. A boundary defect.
    CreatedWorkloadIntentBinding
  | -- | The authoritative outer recovery's checkpoint belongs to a different
    -- invocation than the result being reconciled.
    AuthoritativeStoredRequestBinding
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Which of the seven compared fields disagreed.
--
-- Field __labels__ only, never values. Sprint 2.49 established that this needs
-- no new rule: @requireCreateEqual@ renders neither side of a comparison, so
-- these reasons are payload-free by construction, and every field named here
-- is drawn from the secret-free fence binding.
data SecretWorkerBindingField
  = BindingOperation
  | -- | Freshly minted on every fence acquisition by construction.
    BindingFenceGeneration
  | -- | Freshly minted on every fence acquisition by construction.
    BindingOwnerNonce
  | BindingActionDigest
  | BindingRequestDigest
  | BindingStorageGeneration
  | -- | @acceptedAt + budget@, so freshly minted on every invocation by
    -- construction. The third such field, which this plan had recorded as two.
    BindingOperationDeadline
  | -- | The compared values disagree outside the fence binding entirely —
    -- image digest, service account, or session identity. Reachable only from
    -- 'CreatedWorkloadIntentBinding'.
    BindingWorkloadIdentity
  deriving stock (Bounded, Enum, Eq, Ord, Show)

secretWorkerBindingSiteName :: SecretWorkerBindingSite -> String
secretWorkerBindingSiteName site = case site of
  StoredRequestBinding -> "stored-request"
  StoredIntentBinding -> "stored-intent"
  FreshlyAllocatedIntentBinding -> "freshly-allocated-intent"
  CreatedWorkloadIntentBinding -> "created-workload-intent"
  AuthoritativeStoredRequestBinding -> "authoritative-stored-request"

secretWorkerBindingFieldName :: SecretWorkerBindingField -> String
secretWorkerBindingFieldName field = case field of
  BindingOperation -> "operation"
  BindingFenceGeneration -> "fence-generation"
  BindingOwnerNonce -> "owner-nonce"
  BindingActionDigest -> "action-digest"
  BindingRequestDigest -> "request-digest"
  BindingStorageGeneration -> "storage-generation"
  BindingOperationDeadline -> "operation-deadline"
  BindingWorkloadIdentity -> "workload-identity"

-- | Structured refusal surface. Secret-bearing values cannot enter any
-- constructor; underlying store and protocol refusals remain inspectable.
data EngineSecretWorkerError boundaryError
  = EngineSecretWorkerBoundaryRefused !boundaryError
  | EngineSecretWorkerStoreRefused !StoreBoundaryError
  | EngineSecretWorkerStoredRequestBindingMismatch
      !SecretWorkerBindingSite
      ![SecretWorkerBindingField]
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
-- only under the identical operation\/fence\/action\/request\/storage\/deadline
-- binding. A completed, absent predecessor may be CAS-rolled to a freshly
-- allocated request. Success is returned only after the absent checkpoint is
-- durably read back.
--
-- Sprint 2.50 added exactly one exception to the identical-binding rule, and
-- bounded it three ways. A __pre-receipt__ checkpoint — one carrying no receipt
-- and no result — whose stored fence generation is __strictly older__ than the
-- fence this invocation holds is discarded through a UID-preconditioned delete
-- and CAS-rolled to a freshly allocated request. Within one fence generation
-- nothing changes, and a checkpoint that carries a receipt is never discarded
-- on any binding. Before this, a bring-up abandoned after its first worker was
-- created left a durable checkpoint that no later invocation could match — two
-- of the seven compared fields being freshly minted per acquisition by
-- construction, and the operation deadline a third — so the host refused
-- @StoredRequestBindingMismatch@ forever. See the arm itself for the argument.
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
              | mismatched <- requestBindingMismatch operation fence request
              , not (null mismatched) ->
                  pure
                    ( Left
                        ( EngineSecretWorkerStoredRequestBindingMismatch
                            AuthoritativeStoredRequestBinding
                            mismatched
                        )
                    )
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
    Left SecretWorkerRecoveryPodUidUnbound ->
      case secretWorkerCheckpointIntent (persistedCheckpoint persisted) of
        Left refusal -> pure (Left (EngineSecretWorkerRecoveryRefused refusal))
        Right intent
          -- Sprint 2.50: the same wedge one stage earlier, and strictly safer
          -- to roll. An intent checkpoint has no bound Pod UID, no receipt and
          -- no result, so there is nothing to discard and nothing to lose; a
          -- stale Pod still occupying the sole coordinate makes the fresh
          -- create fail closed exactly as it does on the matching-binding path.
          -- Rolling is decided here rather than inside 'resumeWorkerIntent',
          -- because that function is also reached from 'beginFreshWorker' with
          -- an intent minted moments earlier, where a mismatch is a boundary
          -- defect and must stay a hard refusal.
          | supersededByHeldFence (secretWorkerIntentFenceGeneration intent) ->
              rollToFreshWorker Nothing
          | otherwise ->
              resumeWorkerIntent
                boundary
                interruption
                operation
                fence
                refreshVaultPermit
                persisted
                intent
                runOperation
                encodeResult
    Left refusal -> pure (Left (EngineSecretWorkerRecoveryRefused refusal))
    Right storedRequest ->
      let decision =
            decideSecretWorkerRecovery
              storedRequest
              interruption
              (persistedCheckpoint persisted)
          mismatched = requestBindingMismatch operation fence storedRequest
          bindingMatches = null mismatched
       in case decision of
            SecretWorkerRecoveryComplete receipt
              | bindingMatches -> recoverCompleted persisted receipt
              | otherwise -> rollToFreshWorker Nothing
            authoritativeDecision@(SecretWorkerRecoveryAuthoritativeComplete _)
              | bindingMatches ->
                  pure
                    ( Left
                        ( EngineSecretWorkerRecoveryDecisionUnexpected
                            authoritativeDecision
                        )
                    )
              | otherwise -> rollToFreshWorker Nothing
            -- Sprint 2.50: this arm now sits ABOVE the binding guard, and takes
            -- a guard of its own. That guard is the whole behavioural change.
            --
            -- __Three independent facts, mirroring Sprint 2.47's retirement,
            -- and refusing closed on ambiguity in each.__
            --
            -- 1. __No result exists to lose.__ The bound Sprint 2.50 was scoped
            --    by is that a fence is an exclusion record while a checkpoint is
            --    a /result/ record — retiring an exclusion loses nothing,
            --    discarding a result can lose work that already happened. That
            --    bound is a statement about checkpoints which carry a result.
            --    This decision is returned only for @InternalNoWorkerReceipt@,
            --    whose entire meaning is that no receipt was captured: its
            --    receipt and its result are both 'Nothing' by construction. The
            --    caution that motivated the refusal is measurably inapplicable
            --    to the state that was actually stuck.
            --
            -- 2. __The checkpoint belongs to a strictly superseded fence.__ Not
            --    merely "some compared field differs". Within one fence
            --    generation the identical-binding requirement is __unchanged__:
            --    an incomplete checkpoint for a /different operation/ under the
            --    same fence still fails closed, because the worker operations of
            --    one bootstrap session are ordered and discarding an interrupted
            --    predecessor could skip a stage. A checkpoint from a /newer/
            --    generation than the one held is likewise refused — that would
            --    mean this invocation is the stale one, and the strict
            --    comparison makes it fail closed rather than roll.
            --
            -- 3. __The predecessor's worker is destroyed, not assumed absent.__
            --    'discardUnreceiptedSecretWorker' issues a UID-preconditioned
            --    delete and then waits for absence, refusing outright if a
            --    replacement worker occupies the fixed coordinate. That is
            --    stronger than the worker-absence /observation/ Sprint 2.47
            --    built: it does not infer absence, it causes it. Holding the
            --    current fence is what makes it safe to do so — every Vault
            --    effect and durable mutation re-reads that exact fence
            --    immediately before acting, so a surviving predecessor bound to
            --    an earlier generation fails closed at its next effect.
            --
            -- __What stays refused.__ Every checkpoint that carries a receipt.
            -- Those are result records mid-cleanup, and their cleanup binding
            -- names a Pod UID, session id and session accessor a successor
            -- cannot reconstruct; discarding one could leak a live Vault
            -- session. They fall through to the binding guard below.
            --
            -- The replay hazard is unchanged and still gated where it was:
            -- 'interruptionRequiresRefusal' decides whether an un-receipted
            -- worker may be re-prompted at all, and a refusing interruption
            -- yields 'SecretWorkerRecoveryDestroyAndRefuse' instead, which this
            -- arm never sees.
            SecretWorkerRecoveryDestroyAndReprompt oldRequest _
              | bindingMatches
                  || supersededByHeldFence
                    (secretWorkerRequestFenceGeneration oldRequest) -> do
                  discarded <-
                    discardUnreceiptedSecretWorker
                      boundary
                      oldRequest
                      interruption
                  case discarded of
                    Left boundaryError ->
                      pure
                        (Left (EngineSecretWorkerBoundaryRefused boundaryError))
                    Right () -> rollToFreshWorker (Just oldRequest)
            _
              | not bindingMatches ->
                  pure
                    ( Left
                        ( EngineSecretWorkerStoredRequestBindingMismatch
                            StoredRequestBinding
                            mismatched
                        )
                    )
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
  -- Sprint 2.50: strictly older than the fence this invocation holds.
  -- Generations are monotonic and CAS-allocated, so "older" is the only reading
  -- under which the stored checkpoint can be a superseded predecessor's.
  -- Equality is not superseded (that is the same session, where the ordering of
  -- worker operations still matters) and greater is refused outright.
  supersededByHeldFence storedGeneration =
    bootstrapFenceGenerationValue storedGeneration
      < bootstrapFenceGenerationValue (bootstrapFenceGeneration fence)

  -- CAS the durable checkpoint from whatever a superseded invocation left
  -- behind onto a freshly allocated request bound to the fence this invocation
  -- holds.
  rollToFreshWorker forbiddenRequest =
    beginFreshWorker
      boundary
      interruption
      operation
      fence
      refreshVaultPermit
      (Just (persistedVersion persisted))
      forbiddenRequest
      runOperation
      encodeResult

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
  allocated <- allocateSecretWorkerIntent boundary operation fence
  case allocated of
    Left boundaryError ->
      pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
    Right intent
      | Just intent == fmap secretWorkerRequestIntent forbiddenRequest ->
          pure (Left EngineSecretWorkerRepromptWasNotFresh)
      -- A boundary defect, not stale state: this intent was minted for this
      -- invocation moments ago. It stays a hard refusal and is named apart from
      -- the durable-checkpoint sites.
      | mismatched <- intentBindingMismatch operation fence intent
      , not (null mismatched) ->
          pure
            ( Left
                ( EngineSecretWorkerStoredRequestBindingMismatch
                    FreshlyAllocatedIntentBinding
                    mismatched
                )
            )
      | otherwise -> do
          journaled <- case previousVersion of
            Nothing ->
              persistCheckpointCreate
                boundary
                fence
                (secretWorkerIntentCheckpoint intent)
            Just version ->
              persistCheckpointCas
                boundary
                fence
                version
                (secretWorkerIntentCheckpoint intent)
          case journaled of
            Left failure -> pure (Left failure)
            Right persisted ->
              resumeWorkerIntent
                boundary
                interruption
                operation
                fence
                refreshVaultPermit
                persisted
                intent
                runOperation
                encodeResult

resumeWorkerIntent
  :: (Monad m)
  => EngineSecretWorkerBoundary m boundaryError
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> m (Either boundaryError BootstrapVaultEffectPermit)
  -> PersistedCheckpoint
  -> SecretWorkerIntent
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
resumeWorkerIntent boundary interruption operation fence refreshVaultPermit persisted intent runOperation encodeResult
  -- Reached with a durable intent only after 'recoverStoredWorker' has already
  -- established that it matches, and with a freshly minted one from
  -- 'beginFreshWorker'. Either way a mismatch here is a defect rather than
  -- stale state, so this stays a hard refusal.
  | mismatched <- intentBindingMismatch operation fence intent
  , not (null mismatched) =
      pure
        ( Left
            ( EngineSecretWorkerStoredRequestBindingMismatch
                StoredIntentBinding
                mismatched
            )
        )
  | otherwise = do
      created <- createSecretWorkerWorkload boundary intent
      case created of
        Left boundaryError ->
          pure (Left (EngineSecretWorkerBoundaryRefused boundaryError))
        Right request
          | secretWorkerRequestIntent request /= intent ->
              -- The boundary created a workload for a different intent. Report
              -- the binding fields that disagree; an empty list here means the
              -- intents differ outside the fence binding — image digest,
              -- service account, or session identity.
              pure
                ( Left
                    ( EngineSecretWorkerStoredRequestBindingMismatch
                        CreatedWorkloadIntentBinding
                        ( case requestBindingMismatch operation fence request of
                            [] -> [BindingWorkloadIdentity]
                            fields -> fields
                        )
                    )
                )
          | otherwise -> do
              boundCheckpoint <-
                persistCheckpointCas
                  boundary
                  fence
                  (persistedVersion persisted)
                  (noSecretWorkerReceipt request)
              case boundCheckpoint of
                Left failure -> pure (Left failure)
                Right boundPersisted ->
                  runFreshWorker
                    boundary
                    interruption
                    fence
                    refreshVaultPermit
                    request
                    boundPersisted
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

-- | Sprint 2.50: which binding fields disagree, rather than whether any does.
-- An empty list is a match; the predicate that used to return 'Bool' discarded
-- exactly the information a stuck host needs.
requestBindingMismatch
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
  -> [SecretWorkerBindingField]
requestBindingMismatch operation fence request =
  bindingMismatch
    operation
    fence
    ObservedBinding
      { observedOperation = secretWorkerRequestOperation request
      , observedFenceGeneration = secretWorkerRequestFenceGeneration request
      , observedOwnerNonce = secretWorkerRequestOwnerNonce request
      , observedActionDigest = secretWorkerRequestActionDigest request
      , observedRequestDigest = secretWorkerRequestDigest request
      , observedStorageGeneration = secretWorkerRequestStorageGeneration request
      , observedOperationDeadline = secretWorkerRequestOperationDeadline request
      }

intentBindingMismatch
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretWorkerIntent
  -> [SecretWorkerBindingField]
intentBindingMismatch operation fence intent =
  bindingMismatch
    operation
    fence
    ObservedBinding
      { observedOperation = secretWorkerIntentOperation intent
      , observedFenceGeneration = secretWorkerIntentFenceGeneration intent
      , observedOwnerNonce = secretWorkerIntentOwnerNonce intent
      , observedActionDigest = secretWorkerIntentActionDigest intent
      , observedRequestDigest = secretWorkerIntentRequestDigest intent
      , observedStorageGeneration = secretWorkerIntentStorageGeneration intent
      , observedOperationDeadline = secretWorkerIntentOperationDeadline intent
      }

-- | The seven fields a request and an intent compare identically, projected so
-- one comparison serves both and the two can never drift apart.
data ObservedBinding = ObservedBinding
  { observedOperation :: !SecretWorkerOperation
  , observedFenceGeneration :: !BootstrapFenceGeneration
  , observedOwnerNonce :: !OwnerNonce
  , observedActionDigest :: !ArtifactDigest
  , observedRequestDigest :: !RequestDigest
  , observedStorageGeneration :: !VaultStorageGeneration
  , observedOperationDeadline :: !OperationDeadline
  }

bindingMismatch
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> ObservedBinding
  -> [SecretWorkerBindingField]
bindingMismatch operation fence observed =
  [ field
  | (field, differs) <-
      [ (BindingOperation, observedOperation observed /= operation)
      ,
        ( BindingFenceGeneration
        , observedFenceGeneration observed /= bootstrapFenceGeneration fence
        )
      ,
        ( BindingOwnerNonce
        , observedOwnerNonce observed /= bootstrapFenceOwnerNonce fence
        )
      ,
        ( BindingActionDigest
        , observedActionDigest observed /= bootstrapFenceActionDigest fence
        )
      ,
        ( BindingRequestDigest
        , observedRequestDigest observed /= bootstrapFenceRequestDigest fence
        )
      ,
        ( BindingStorageGeneration
        , observedStorageGeneration observed
            /= bootstrapFenceStorageGeneration fence
        )
      ,
        ( BindingOperationDeadline
        , observedOperationDeadline observed
            /= bootstrapFenceOperationDeadline fence
        )
      ]
  , differs
  ]

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
