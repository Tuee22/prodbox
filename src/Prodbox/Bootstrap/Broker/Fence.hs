{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Pure, durable fencing for Bootstrap Broker mutations.
--
-- A 'BootstrapSessionFence' binds one monotonically increasing CAS generation
-- to the exact owner, action, request, Vault storage generation, and durable
-- operation deadline.  A matching Kubernetes Lease observation is required in
-- addition to the durable store observation.  'authorizeBootstrapVaultEffect' rechecks
-- both observations and the original deadline before every Vault effect.
--
-- This module owns no Kubernetes or object-store I/O.  Sprint 3.26 renders the
-- physical Lease and workload; an interpreter supplies the observations and
-- applies the CAS plans modelled here.
module Prodbox.Bootstrap.Broker.Fence
  ( -- * Durable fence identity
    BootstrapFenceGeneration
  , mkBootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , BootstrapSessionFence
  , bootstrapFenceGeneration
  , bootstrapFenceOwnerNonce
  , bootstrapFenceActionDigest
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  , bootstrapFenceOperationDeadline
  , reloadBootstrapSessionFence
  , BootstrapFenceValueError (..)

    -- * Acquire and CAS read-back
  , BootstrapFenceAcquireRequest
  , mkBootstrapFenceAcquireRequest
  , fenceAcquireOwnerNonce
  , fenceAcquireActionDigest
  , fenceAcquireRequestDigest
  , fenceAcquireStorageGeneration
  , fenceAcquireOperationDeadline
  , BootstrapFenceStoreObservation (..)
  , BootstrapFenceCasPlan
  , fenceCasExpectedGenerationFloor
  , fenceCasProposedFence
  , BootstrapFenceAcquireRefusal (..)
  , BootstrapFenceAcquireDecision (..)
  , decideBootstrapFenceAcquire
  , BootstrapFenceCasResult (..)
  , BootstrapFenceConfirmationRefusal (..)
  , confirmBootstrapFenceCas

    -- * Expired-owner retirement
  , BootstrapFenceOwnerCleanupObservation (..)
  , BootstrapFenceRetirePlan
  , fenceRetireExpectedFence
  , fenceRetireVacantGenerationFloor
  , BootstrapFenceRetireRefusal (..)
  , decideBootstrapFenceRetire
  , BootstrapFenceRetireCasResult (..)
  , BootstrapFenceRetireConfirmationRefusal (..)
  , confirmBootstrapFenceRetireCas

    -- * Matching Lease witness
  , BootstrapLeaseBinding
  , bootstrapLeaseBindingForFence
  , reloadBootstrapLeaseBinding
  , bootstrapLeaseFenceGeneration
  , bootstrapLeaseOwnerNonce
  , bootstrapLeaseActionDigest
  , bootstrapLeaseRequestDigest
  , bootstrapLeaseStorageGeneration
  , bootstrapLeaseOperationDeadline
  , BootstrapLeaseObservation (..)
  , BootstrapLeaseWitness
  , bootstrapLeaseWitnessBinding
  , bootstrapLeaseWitnessDeadline
  , bootstrapLeaseWitnessResourceVersion
  , BootstrapLeaseRefusal (..)
  , confirmBootstrapLease

    -- * Per-effect fail-closed authorization
  , BootstrapVaultEffect (..)
  , BootstrapVaultEffectPermit
  , vaultEffectPermitEffect
  , vaultEffectPermitDeadline
  , vaultEffectPermitFenceGeneration
  , vaultEffectPermitOwnerNonce
  , vaultEffectPermitActionDigest
  , vaultEffectPermitRequestDigest
  , vaultEffectPermitStorageGeneration
  , vaultEffectPermitOperationDeadline
  , BootstrapFenceUseRefusal (..)
  , authorizeBootstrapVaultEffect

    -- * Durable-store mutation permits
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , storeMutationPermitMutation
  , storeMutationPermitDeadline
  , storeMutationPermitFenceGeneration
  , storeMutationPermitOwnerNonce
  , storeMutationPermitActionDigest
  , storeMutationPermitRequestDigest
  , storeMutationPermitStorageGeneration
  , storeMutationPermitOperationDeadline
  , authorizeBootstrapStoreMutation
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AttemptDeadlineRefusal (..)
  , AuthorityClockObservation
  , OperationDeadline
  , deriveAttemptDeadline
  , operationDeadlineFromMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineExpired
  )
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  )

-- | Positive, monotonically increasing generation of the durable bootstrap
-- fence.  The constructor is private; generation zero is only a vacant-store
-- floor and can never identify a held fence.
newtype BootstrapFenceGeneration = BootstrapFenceGeneration Natural
  deriving stock (Eq, Ord, Show)

data BootstrapFenceValueError
  = BootstrapFenceGenerationMustBePositive
  deriving stock (Eq, Show)

mkBootstrapFenceGeneration
  :: Natural -> Either BootstrapFenceValueError BootstrapFenceGeneration
mkBootstrapFenceGeneration value
  | value == 0 = Left BootstrapFenceGenerationMustBePositive
  | otherwise = Right (BootstrapFenceGeneration value)

bootstrapFenceGenerationValue :: BootstrapFenceGeneration -> Natural
bootstrapFenceGenerationValue (BootstrapFenceGeneration value) = value

-- | The exact durable exclusion record.  Its constructor is private so a use
-- proof can originate only from acquisition/read-back below.
data BootstrapSessionFence = BootstrapSessionFence
  { internalFenceGeneration :: !BootstrapFenceGeneration
  , internalFenceOwnerNonce :: !OwnerNonce
  , internalFenceActionDigest :: !ArtifactDigest
  , internalFenceRequestDigest :: !RequestDigest
  , internalFenceStorageGeneration :: !VaultStorageGeneration
  , internalFenceOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

bootstrapFenceGeneration :: BootstrapSessionFence -> BootstrapFenceGeneration
bootstrapFenceGeneration = internalFenceGeneration

bootstrapFenceOwnerNonce :: BootstrapSessionFence -> OwnerNonce
bootstrapFenceOwnerNonce = internalFenceOwnerNonce

bootstrapFenceActionDigest :: BootstrapSessionFence -> ArtifactDigest
bootstrapFenceActionDigest = internalFenceActionDigest

bootstrapFenceRequestDigest :: BootstrapSessionFence -> RequestDigest
bootstrapFenceRequestDigest = internalFenceRequestDigest

bootstrapFenceStorageGeneration :: BootstrapSessionFence -> VaultStorageGeneration
bootstrapFenceStorageGeneration = internalFenceStorageGeneration

bootstrapFenceOperationDeadline :: BootstrapSessionFence -> OperationDeadline
bootstrapFenceOperationDeadline = internalFenceOperationDeadline

-- | Trusted reconstruction from a durable record.  The persisted deadline is
-- reloaded by absolute authority-clock value; it is not derived from a fresh
-- relative budget, so restart cannot extend it.
reloadBootstrapSessionFence
  :: Natural
  -> OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> Natural
  -> Either BootstrapFenceValueError BootstrapSessionFence
reloadBootstrapSessionFence generation owner actionDigest requestDigest storageGeneration deadlineMicros = do
  validatedGeneration <- mkBootstrapFenceGeneration generation
  pure
    BootstrapSessionFence
      { internalFenceGeneration = validatedGeneration
      , internalFenceOwnerNonce = owner
      , internalFenceActionDigest = actionDigest
      , internalFenceRequestDigest = requestDigest
      , internalFenceStorageGeneration = storageGeneration
      , internalFenceOperationDeadline = operationDeadlineFromMicros deadlineMicros
      }

-- | Secret-free request to acquire or resume the durable fence.
data BootstrapFenceAcquireRequest = BootstrapFenceAcquireRequest
  { internalAcquireOwnerNonce :: !OwnerNonce
  , internalAcquireActionDigest :: !ArtifactDigest
  , internalAcquireRequestDigest :: !RequestDigest
  , internalAcquireStorageGeneration :: !VaultStorageGeneration
  , internalAcquireOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

mkBootstrapFenceAcquireRequest
  :: OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> OperationDeadline
  -> BootstrapFenceAcquireRequest
mkBootstrapFenceAcquireRequest owner actionDigest requestDigest storageGeneration operationDeadline =
  BootstrapFenceAcquireRequest
    { internalAcquireOwnerNonce = owner
    , internalAcquireActionDigest = actionDigest
    , internalAcquireRequestDigest = requestDigest
    , internalAcquireStorageGeneration = storageGeneration
    , internalAcquireOperationDeadline = operationDeadline
    }

fenceAcquireOwnerNonce :: BootstrapFenceAcquireRequest -> OwnerNonce
fenceAcquireOwnerNonce = internalAcquireOwnerNonce

fenceAcquireActionDigest :: BootstrapFenceAcquireRequest -> ArtifactDigest
fenceAcquireActionDigest = internalAcquireActionDigest

fenceAcquireRequestDigest :: BootstrapFenceAcquireRequest -> RequestDigest
fenceAcquireRequestDigest = internalAcquireRequestDigest

fenceAcquireStorageGeneration
  :: BootstrapFenceAcquireRequest -> VaultStorageGeneration
fenceAcquireStorageGeneration = internalAcquireStorageGeneration

fenceAcquireOperationDeadline
  :: BootstrapFenceAcquireRequest -> OperationDeadline
fenceAcquireOperationDeadline = internalAcquireOperationDeadline

-- | Authoritative observation of the durable CAS record.  A vacant record
-- retains the last generation as a high-water floor, preventing ABA reuse.
data BootstrapFenceStoreObservation
  = BootstrapFenceStoreVacant !Natural
  | BootstrapFenceStoreHeld !BootstrapSessionFence
  | BootstrapFenceStoreUnobservable !Text
  deriving stock (Eq, Show)

-- | Conditional create/replace plan.  The store must compare the vacant
-- generation floor and read back the proposed record exactly.
data BootstrapFenceCasPlan = BootstrapFenceCasPlan
  { internalCasExpectedGenerationFloor :: !Natural
  , internalCasProposedFence :: !BootstrapSessionFence
  }
  deriving stock (Eq, Show)

fenceCasExpectedGenerationFloor :: BootstrapFenceCasPlan -> Natural
fenceCasExpectedGenerationFloor = internalCasExpectedGenerationFloor

fenceCasProposedFence :: BootstrapFenceCasPlan -> BootstrapSessionFence
fenceCasProposedFence = internalCasProposedFence

data BootstrapFenceAcquireRefusal
  = BootstrapFenceAcquireRequestDeadlineExpired
  | BootstrapFenceAcquireDeadlineRefused !AttemptDeadlineRefusal
  | BootstrapFenceAcquireStoreUnobservable !Text
  | BootstrapFenceAcquireOverlap !BootstrapSessionFence
  | BootstrapFenceAcquireExpiredPredecessor !BootstrapSessionFence
  deriving stock (Eq, Show)

data BootstrapFenceAcquireDecision
  = BootstrapFenceAcquireCas !BootstrapFenceCasPlan
  | BootstrapFenceAcquireResume !BootstrapSessionFence
  | BootstrapFenceAcquireRefused !BootstrapFenceAcquireRefusal
  deriving stock (Eq, Show)

-- | Acquire a new monotonically increasing generation only from an observed
-- vacant floor.  An exact duplicate resumes the held record.  A different or
-- expired predecessor is never taken over implicitly.
decideBootstrapFenceAcquire
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> BootstrapFenceAcquireRequest
  -> BootstrapFenceStoreObservation
  -> BootstrapFenceAcquireDecision
decideBootstrapFenceAcquire monotonicNow requestDeadline clockObservation request observation =
  if deadlineExpired monotonicNow requestDeadline
    then BootstrapFenceAcquireRefused BootstrapFenceAcquireRequestDeadlineExpired
    else case deriveAttemptDeadline
      monotonicNow
      requestDeadline
      clockObservation
      (fenceAcquireOperationDeadline request) of
      Left refusal ->
        BootstrapFenceAcquireRefused (BootstrapFenceAcquireDeadlineRefused refusal)
      Right _ -> decideFromStore
 where
  decideFromStore = case observation of
    BootstrapFenceStoreUnobservable detail ->
      BootstrapFenceAcquireRefused (BootstrapFenceAcquireStoreUnobservable detail)
    BootstrapFenceStoreVacant generationFloor ->
      BootstrapFenceAcquireCas
        BootstrapFenceCasPlan
          { internalCasExpectedGenerationFloor = generationFloor
          , internalCasProposedFence = fenceFromRequest generationFloor request
          }
    BootstrapFenceStoreHeld held
      | requestExactlyMatchesFence request held -> BootstrapFenceAcquireResume held
      | predecessorExpired held ->
          BootstrapFenceAcquireRefused (BootstrapFenceAcquireExpiredPredecessor held)
      | otherwise -> BootstrapFenceAcquireRefused (BootstrapFenceAcquireOverlap held)

  predecessorExpired held =
    case deriveAttemptDeadline
      monotonicNow
      requestDeadline
      clockObservation
      (bootstrapFenceOperationDeadline held) of
      Left _ -> True
      Right _ -> False

data BootstrapFenceCasResult
  = BootstrapFenceCasAppliedReadBack !BootstrapSessionFence
  | BootstrapFenceCasConflict !BootstrapFenceStoreObservation
  | BootstrapFenceCasUnobservable !Text
  deriving stock (Eq, Show)

data BootstrapFenceConfirmationRefusal
  = BootstrapFenceReadBackMismatch
      !BootstrapSessionFence
      !BootstrapSessionFence
  | BootstrapFenceCasConflictRefusal !BootstrapFenceStoreObservation
  | BootstrapFenceCasResultUnobservable !Text
  deriving stock (Eq, Show)

-- | Confirm only an exact durable read-back.  If the CAS response was lost but
-- a re-observation contains the exact proposed fence, the same request resumes
-- successfully rather than creating another generation.
confirmBootstrapFenceCas
  :: BootstrapFenceCasPlan
  -> BootstrapFenceCasResult
  -> Either BootstrapFenceConfirmationRefusal BootstrapSessionFence
confirmBootstrapFenceCas plan result = case result of
  BootstrapFenceCasAppliedReadBack observed
    | observed == proposed -> Right observed
    | otherwise -> Left (BootstrapFenceReadBackMismatch proposed observed)
  BootstrapFenceCasConflict (BootstrapFenceStoreHeld observed)
    | observed == proposed -> Right observed
  BootstrapFenceCasConflict observation ->
    Left (BootstrapFenceCasConflictRefusal observation)
  BootstrapFenceCasUnobservable detail ->
    Left (BootstrapFenceCasResultUnobservable detail)
 where
  proposed = fenceCasProposedFence plan

-- | Exact Lease holder identity derived from the durable fence.  There is no
-- independent caller-authored Lease binding.
data BootstrapLeaseBinding = BootstrapLeaseBinding
  { internalLeaseFenceGeneration :: !BootstrapFenceGeneration
  , internalLeaseOwnerNonce :: !OwnerNonce
  , internalLeaseActionDigest :: !ArtifactDigest
  , internalLeaseRequestDigest :: !RequestDigest
  , internalLeaseStorageGeneration :: !VaultStorageGeneration
  , internalLeaseOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

bootstrapLeaseBindingForFence :: BootstrapSessionFence -> BootstrapLeaseBinding
bootstrapLeaseBindingForFence fence =
  BootstrapLeaseBinding
    { internalLeaseFenceGeneration = bootstrapFenceGeneration fence
    , internalLeaseOwnerNonce = bootstrapFenceOwnerNonce fence
    , internalLeaseActionDigest = bootstrapFenceActionDigest fence
    , internalLeaseRequestDigest = bootstrapFenceRequestDigest fence
    , internalLeaseStorageGeneration = bootstrapFenceStorageGeneration fence
    , internalLeaseOperationDeadline = bootstrapFenceOperationDeadline fence
    }

-- | Trusted reconstruction of Lease metadata read from Kubernetes.  The
-- generation is revalidated; generation zero cannot identify a held Lease.
reloadBootstrapLeaseBinding
  :: Natural
  -> OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> OperationDeadline
  -> Either BootstrapFenceValueError BootstrapLeaseBinding
reloadBootstrapLeaseBinding generation owner actionDigest requestDigest storageGeneration operationDeadline = do
  validatedGeneration <- mkBootstrapFenceGeneration generation
  pure
    BootstrapLeaseBinding
      { internalLeaseFenceGeneration = validatedGeneration
      , internalLeaseOwnerNonce = owner
      , internalLeaseActionDigest = actionDigest
      , internalLeaseRequestDigest = requestDigest
      , internalLeaseStorageGeneration = storageGeneration
      , internalLeaseOperationDeadline = operationDeadline
      }

bootstrapLeaseFenceGeneration
  :: BootstrapLeaseBinding -> BootstrapFenceGeneration
bootstrapLeaseFenceGeneration = internalLeaseFenceGeneration

bootstrapLeaseOwnerNonce :: BootstrapLeaseBinding -> OwnerNonce
bootstrapLeaseOwnerNonce = internalLeaseOwnerNonce

bootstrapLeaseActionDigest :: BootstrapLeaseBinding -> ArtifactDigest
bootstrapLeaseActionDigest = internalLeaseActionDigest

bootstrapLeaseRequestDigest :: BootstrapLeaseBinding -> RequestDigest
bootstrapLeaseRequestDigest = internalLeaseRequestDigest

bootstrapLeaseStorageGeneration
  :: BootstrapLeaseBinding -> VaultStorageGeneration
bootstrapLeaseStorageGeneration = internalLeaseStorageGeneration

bootstrapLeaseOperationDeadline :: BootstrapLeaseBinding -> OperationDeadline
bootstrapLeaseOperationDeadline = internalLeaseOperationDeadline

-- | Fresh raw Lease observation supplied by the Kubernetes boundary.  The
-- local deadline is a monotonic conservative expiry witness.
data BootstrapLeaseObservation
  = BootstrapLeaseMissing
  | BootstrapLeaseObserved
      !BootstrapLeaseBinding
      !Deadline
      !Text
  | BootstrapLeaseUnobservable !Text
  deriving stock (Eq, Show)

-- | Private proof that a fresh Lease observation exactly matched the fence.
data BootstrapLeaseWitness = BootstrapLeaseWitness
  { internalLeaseWitnessBinding :: !BootstrapLeaseBinding
  , internalLeaseWitnessDeadline :: !Deadline
  , internalLeaseWitnessResourceVersion :: !Text
  }
  deriving stock (Eq, Show)

bootstrapLeaseWitnessBinding :: BootstrapLeaseWitness -> BootstrapLeaseBinding
bootstrapLeaseWitnessBinding = internalLeaseWitnessBinding

bootstrapLeaseWitnessDeadline :: BootstrapLeaseWitness -> Deadline
bootstrapLeaseWitnessDeadline = internalLeaseWitnessDeadline

bootstrapLeaseWitnessResourceVersion :: BootstrapLeaseWitness -> Text
bootstrapLeaseWitnessResourceVersion = internalLeaseWitnessResourceVersion

data BootstrapLeaseRefusal
  = BootstrapLeaseNotFound
  | BootstrapLeaseObservationUnobservable !Text
  | BootstrapLeaseBindingMismatch
      !BootstrapLeaseBinding
      !BootstrapLeaseBinding
  | BootstrapLeaseExpired
  | BootstrapLeaseResourceVersionEmpty
  deriving stock (Eq, Show)

confirmBootstrapLease
  :: MonotonicInstant
  -> BootstrapSessionFence
  -> BootstrapLeaseObservation
  -> Either BootstrapLeaseRefusal BootstrapLeaseWitness
confirmBootstrapLease now fence observation = case observation of
  BootstrapLeaseMissing -> Left BootstrapLeaseNotFound
  BootstrapLeaseUnobservable detail -> Left (BootstrapLeaseObservationUnobservable detail)
  BootstrapLeaseObserved observedBinding leaseDeadline resourceVersion
    | observedBinding /= expectedBinding ->
        Left (BootstrapLeaseBindingMismatch expectedBinding observedBinding)
    | deadlineExpired now leaseDeadline -> Left BootstrapLeaseExpired
    | nullText resourceVersion -> Left BootstrapLeaseResourceVersionEmpty
    | otherwise ->
        Right
          BootstrapLeaseWitness
            { internalLeaseWitnessBinding = observedBinding
            , internalLeaseWitnessDeadline = leaseDeadline
            , internalLeaseWitnessResourceVersion = resourceVersion
            }
 where
  expectedBinding = bootstrapLeaseBindingForFence fence

-- | Trusted boundary observation used to retire an expired owner.  The
-- absence receipt is bound to the exact durable fence and to a digest of the
-- worker/session/accessor cleanup read-back.  An expired deadline or missing
-- Lease alone is never sufficient to authorize takeover.
data BootstrapFenceOwnerCleanupObservation
  = BootstrapFenceOwnerStillPresent !BootstrapSessionFence
  | BootstrapFenceOwnerAbsent !BootstrapSessionFence !ArtifactDigest
  | BootstrapFenceOwnerCleanupUnobservable !Text
  deriving stock (Eq, Show)

-- | Exact compare-and-swap retirement of a held record to its vacant
-- high-water floor.  A successor can only allocate @floor + 1@ after this CAS
-- has been read back.
data BootstrapFenceRetirePlan = BootstrapFenceRetirePlan
  { internalRetireExpectedFence :: !BootstrapSessionFence
  , internalRetireVacantGenerationFloor :: !Natural
  }
  deriving stock (Eq, Show)

fenceRetireExpectedFence :: BootstrapFenceRetirePlan -> BootstrapSessionFence
fenceRetireExpectedFence = internalRetireExpectedFence

fenceRetireVacantGenerationFloor :: BootstrapFenceRetirePlan -> Natural
fenceRetireVacantGenerationFloor = internalRetireVacantGenerationFloor

data BootstrapFenceRetireRefusal
  = BootstrapFenceRetireRequestDeadlineExpired
  | BootstrapFenceRetirePredecessorStillLive !BootstrapSessionFence
  | BootstrapFenceRetireDeadlineUnobservable !AttemptDeadlineRefusal
  | BootstrapFenceRetireLeaseStillLive !BootstrapLeaseWitness
  | BootstrapFenceRetireLeaseRefused !BootstrapLeaseRefusal
  | BootstrapFenceRetireOwnerStillPresent !BootstrapSessionFence
  | BootstrapFenceRetireOwnerMismatch
      !BootstrapSessionFence
      !BootstrapSessionFence
  | BootstrapFenceRetireCleanupUnobservable !Text
  deriving stock (Eq, Show)

-- | Produce a retirement CAS only after all three independent facts hold:
-- the original durable deadline elapsed on a trusted authority clock, its
-- exact Lease is absent/expired, and the exact owner's worker/session/accessor
-- cleanup was read back absent.  Clock, Lease, and cleanup ambiguity all
-- refuse closed.
decideBootstrapFenceRetire
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> BootstrapSessionFence
  -> BootstrapLeaseObservation
  -> BootstrapFenceOwnerCleanupObservation
  -> Either BootstrapFenceRetireRefusal BootstrapFenceRetirePlan
decideBootstrapFenceRetire monotonicNow requestDeadline clockObservation held leaseObservation cleanupObservation = do
  if deadlineExpired monotonicNow requestDeadline
    then Left BootstrapFenceRetireRequestDeadlineExpired
    else Right ()
  case deriveAttemptDeadline
    monotonicNow
    requestDeadline
    clockObservation
    (bootstrapFenceOperationDeadline held) of
    Right _ -> Left (BootstrapFenceRetirePredecessorStillLive held)
    Left AttemptDeadlineElapsed {} -> Right ()
    Left refusal -> Left (BootstrapFenceRetireDeadlineUnobservable refusal)
  case confirmBootstrapLease monotonicNow held leaseObservation of
    Right witness -> Left (BootstrapFenceRetireLeaseStillLive witness)
    Left BootstrapLeaseNotFound -> Right ()
    Left BootstrapLeaseExpired -> Right ()
    Left refusal -> Left (BootstrapFenceRetireLeaseRefused refusal)
  case cleanupObservation of
    BootstrapFenceOwnerStillPresent observed
      | observed == held -> Left (BootstrapFenceRetireOwnerStillPresent observed)
      | otherwise -> Left (BootstrapFenceRetireOwnerMismatch held observed)
    BootstrapFenceOwnerAbsent observed _
      | observed == held ->
          Right
            BootstrapFenceRetirePlan
              { internalRetireExpectedFence = held
              , internalRetireVacantGenerationFloor =
                  bootstrapFenceGenerationValue (bootstrapFenceGeneration held)
              }
      | otherwise -> Left (BootstrapFenceRetireOwnerMismatch held observed)
    BootstrapFenceOwnerCleanupUnobservable detail ->
      Left (BootstrapFenceRetireCleanupUnobservable detail)

data BootstrapFenceRetireCasResult
  = BootstrapFenceRetireCasAppliedReadBack !BootstrapFenceStoreObservation
  | BootstrapFenceRetireCasConflict !BootstrapFenceStoreObservation
  | BootstrapFenceRetireCasUnobservable !Text
  deriving stock (Eq, Show)

data BootstrapFenceRetireConfirmationRefusal
  = BootstrapFenceRetireReadBackMismatch
      !BootstrapFenceStoreObservation
      !BootstrapFenceStoreObservation
  | BootstrapFenceRetireCasConflictRefusal !BootstrapFenceStoreObservation
  | BootstrapFenceRetireCasResultUnobservable !Text
  deriving stock (Eq, Show)

confirmBootstrapFenceRetireCas
  :: BootstrapFenceRetirePlan
  -> BootstrapFenceRetireCasResult
  -> Either BootstrapFenceRetireConfirmationRefusal BootstrapFenceStoreObservation
confirmBootstrapFenceRetireCas plan result = case result of
  BootstrapFenceRetireCasAppliedReadBack observed
    | observed == expected -> Right observed
    | otherwise -> Left (BootstrapFenceRetireReadBackMismatch expected observed)
  BootstrapFenceRetireCasConflict observation ->
    Left (BootstrapFenceRetireCasConflictRefusal observation)
  BootstrapFenceRetireCasUnobservable detail ->
    Left (BootstrapFenceRetireCasResultUnobservable detail)
 where
  expected = BootstrapFenceStoreVacant (fenceRetireVacantGenerationFloor plan)

data BootstrapVaultEffect
  = BootstrapVaultInitialize
  | BootstrapVaultSubmitUnsealShare
  | BootstrapVaultSeal
  | BootstrapVaultRotateUnlockBundle
  | BootstrapVaultRotateTransitKey
  | BootstrapVaultResetAmbiguousInitialization
  | BootstrapVaultCancelGenerateRoot
  | BootstrapVaultInventoryRootAccessors
  | BootstrapVaultRevokeRootAccessor
  | BootstrapVaultStartGenerateRoot
  | BootstrapVaultSubmitGenerateRootShare
  | BootstrapVaultObserveGeneratedRootAccessor
  | BootstrapVaultLoginProvisioner
  | BootstrapVaultApplyBaseline
  | BootstrapVaultReadBackBaseline
  | BootstrapVaultObservePki
  | BootstrapVaultIssueTestCertificate
  | BootstrapVaultCommitChildCustody
  | BootstrapVaultConsumeChildRecovery
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Opaque proof for one effect attempt.  Interpreters obtain a fresh value by
-- calling 'authorizeBootstrapVaultEffect' immediately before each Vault call.
data BootstrapVaultEffectPermit = BootstrapVaultEffectPermit
  { internalEffectPermitEffect :: !BootstrapVaultEffect
  , internalEffectPermitDeadline :: !Deadline
  , internalEffectPermitFenceGeneration :: !BootstrapFenceGeneration
  , internalEffectPermitOwnerNonce :: !OwnerNonce
  , internalEffectPermitActionDigest :: !ArtifactDigest
  , internalEffectPermitRequestDigest :: !RequestDigest
  , internalEffectPermitStorageGeneration :: !VaultStorageGeneration
  , internalEffectPermitOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

vaultEffectPermitEffect :: BootstrapVaultEffectPermit -> BootstrapVaultEffect
vaultEffectPermitEffect = internalEffectPermitEffect

vaultEffectPermitDeadline :: BootstrapVaultEffectPermit -> Deadline
vaultEffectPermitDeadline = internalEffectPermitDeadline

vaultEffectPermitFenceGeneration
  :: BootstrapVaultEffectPermit -> BootstrapFenceGeneration
vaultEffectPermitFenceGeneration = internalEffectPermitFenceGeneration

vaultEffectPermitOwnerNonce :: BootstrapVaultEffectPermit -> OwnerNonce
vaultEffectPermitOwnerNonce = internalEffectPermitOwnerNonce

vaultEffectPermitActionDigest :: BootstrapVaultEffectPermit -> ArtifactDigest
vaultEffectPermitActionDigest = internalEffectPermitActionDigest

vaultEffectPermitRequestDigest :: BootstrapVaultEffectPermit -> RequestDigest
vaultEffectPermitRequestDigest = internalEffectPermitRequestDigest

vaultEffectPermitStorageGeneration
  :: BootstrapVaultEffectPermit -> VaultStorageGeneration
vaultEffectPermitStorageGeneration = internalEffectPermitStorageGeneration

vaultEffectPermitOperationDeadline
  :: BootstrapVaultEffectPermit -> OperationDeadline
vaultEffectPermitOperationDeadline = internalEffectPermitOperationDeadline

data BootstrapFenceUseRefusal
  = BootstrapFenceUseRequestDeadlineExpired
  | BootstrapFenceUseStoreUnobservable !Text
  | BootstrapFenceUseFenceLost !Natural
  | BootstrapFenceUseFenceStale
      !BootstrapSessionFence
      !BootstrapSessionFence
  | BootstrapFenceUseLeaseRefused !BootstrapLeaseRefusal
  | BootstrapFenceUseDeadlineRefused !AttemptDeadlineRefusal
  deriving stock (Eq, Show)

-- | Sole per-effect permit producer.  It validates an exact fresh durable
-- fence observation, a fresh matching Lease observation, and the original
-- durable deadline.  Absence, mismatch, expiry, clock regression, and
-- unobservability all refuse closed.
authorizeBootstrapVaultEffect
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> BootstrapSessionFence
  -> BootstrapFenceStoreObservation
  -> BootstrapLeaseObservation
  -> BootstrapVaultEffect
  -> Either BootstrapFenceUseRefusal BootstrapVaultEffectPermit
authorizeBootstrapVaultEffect monotonicNow requestDeadline clockObservation expectedFence storeObservation leaseObservation effect = do
  boundedDeadline <-
    authorizeFenceUse
      monotonicNow
      requestDeadline
      clockObservation
      expectedFence
      storeObservation
      leaseObservation
  Right
    BootstrapVaultEffectPermit
      { internalEffectPermitEffect = effect
      , internalEffectPermitDeadline = boundedDeadline
      , internalEffectPermitFenceGeneration = bootstrapFenceGeneration expectedFence
      , internalEffectPermitOwnerNonce = bootstrapFenceOwnerNonce expectedFence
      , internalEffectPermitActionDigest = bootstrapFenceActionDigest expectedFence
      , internalEffectPermitRequestDigest = bootstrapFenceRequestDigest expectedFence
      , internalEffectPermitStorageGeneration = bootstrapFenceStorageGeneration expectedFence
      , internalEffectPermitOperationDeadline = bootstrapFenceOperationDeadline expectedFence
      }

-- | Closed durable mutation family.  Object coordinates remain selected by
-- 'BootstrapStoreBoundary'; this tag can authorize only one reviewed mutation
-- attempt and contains no generic key or payload constructor.
data BootstrapStoreMutation
  = BootstrapStoreReleaseSessionFence
  | BootstrapStoreCreateRootInitJournal
  | BootstrapStoreCasRootInitJournal
  | BootstrapStoreCreatePreparedInitEnvelope
  | BootstrapStoreDeletePreparedInitEnvelope
  | BootstrapStoreCreateEncryptedInitResponse
  | BootstrapStorePromoteFinalUnlockBundle
  | BootstrapStoreCreateRootSessionJournal
  | BootstrapStoreCasRootSessionJournal
  | BootstrapStoreCreateChildEncryptedReceipt
  | BootstrapStoreCommitParentCustody
  | BootstrapStoreDeleteChildEncryptedReceipt
  | BootstrapStoreCreateChildCustodyJournal
  | BootstrapStoreCasChildCustodyJournal
  | BootstrapStoreCreateChildRecoveryDelivery
  | BootstrapStoreDeleteChildRecoveryDelivery
  | BootstrapStoreCreateChildRecoveryJournal
  | BootstrapStoreCasChildRecoveryJournal
  | BootstrapStoreCreatePostUnsealHandoff
  | BootstrapStoreCasPostUnsealHandoff
  | BootstrapStoreCreateSecretWorkerCheckpoint
  | BootstrapStoreCasSecretWorkerCheckpoint
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data BootstrapStoreMutationPermit = BootstrapStoreMutationPermit
  { internalStorePermitMutation :: !BootstrapStoreMutation
  , internalStorePermitDeadline :: !Deadline
  , internalStorePermitFenceGeneration :: !BootstrapFenceGeneration
  , internalStorePermitOwnerNonce :: !OwnerNonce
  , internalStorePermitActionDigest :: !ArtifactDigest
  , internalStorePermitRequestDigest :: !RequestDigest
  , internalStorePermitStorageGeneration :: !VaultStorageGeneration
  , internalStorePermitOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

storeMutationPermitMutation :: BootstrapStoreMutationPermit -> BootstrapStoreMutation
storeMutationPermitMutation = internalStorePermitMutation

storeMutationPermitDeadline :: BootstrapStoreMutationPermit -> Deadline
storeMutationPermitDeadline = internalStorePermitDeadline

storeMutationPermitFenceGeneration
  :: BootstrapStoreMutationPermit -> BootstrapFenceGeneration
storeMutationPermitFenceGeneration = internalStorePermitFenceGeneration

storeMutationPermitOwnerNonce :: BootstrapStoreMutationPermit -> OwnerNonce
storeMutationPermitOwnerNonce = internalStorePermitOwnerNonce

storeMutationPermitActionDigest :: BootstrapStoreMutationPermit -> ArtifactDigest
storeMutationPermitActionDigest = internalStorePermitActionDigest

storeMutationPermitRequestDigest :: BootstrapStoreMutationPermit -> RequestDigest
storeMutationPermitRequestDigest = internalStorePermitRequestDigest

storeMutationPermitStorageGeneration
  :: BootstrapStoreMutationPermit -> VaultStorageGeneration
storeMutationPermitStorageGeneration = internalStorePermitStorageGeneration

storeMutationPermitOperationDeadline
  :: BootstrapStoreMutationPermit -> OperationDeadline
storeMutationPermitOperationDeadline = internalStorePermitOperationDeadline

authorizeBootstrapStoreMutation
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> BootstrapSessionFence
  -> BootstrapFenceStoreObservation
  -> BootstrapLeaseObservation
  -> BootstrapStoreMutation
  -> Either BootstrapFenceUseRefusal BootstrapStoreMutationPermit
authorizeBootstrapStoreMutation monotonicNow requestDeadline clockObservation expectedFence storeObservation leaseObservation mutation = do
  boundedDeadline <-
    authorizeFenceUse
      monotonicNow
      requestDeadline
      clockObservation
      expectedFence
      storeObservation
      leaseObservation
  Right
    BootstrapStoreMutationPermit
      { internalStorePermitMutation = mutation
      , internalStorePermitDeadline = boundedDeadline
      , internalStorePermitFenceGeneration = bootstrapFenceGeneration expectedFence
      , internalStorePermitOwnerNonce = bootstrapFenceOwnerNonce expectedFence
      , internalStorePermitActionDigest = bootstrapFenceActionDigest expectedFence
      , internalStorePermitRequestDigest = bootstrapFenceRequestDigest expectedFence
      , internalStorePermitStorageGeneration = bootstrapFenceStorageGeneration expectedFence
      , internalStorePermitOperationDeadline = bootstrapFenceOperationDeadline expectedFence
      }

authorizeFenceUse
  :: MonotonicInstant
  -> Deadline
  -> AuthorityClockObservation
  -> BootstrapSessionFence
  -> BootstrapFenceStoreObservation
  -> BootstrapLeaseObservation
  -> Either BootstrapFenceUseRefusal Deadline
authorizeFenceUse monotonicNow requestDeadline clockObservation expectedFence storeObservation leaseObservation = do
  if deadlineExpired monotonicNow requestDeadline
    then Left BootstrapFenceUseRequestDeadlineExpired
    else Right ()
  case storeObservation of
    BootstrapFenceStoreUnobservable detail ->
      Left (BootstrapFenceUseStoreUnobservable detail)
    BootstrapFenceStoreVacant generationFloor ->
      Left (BootstrapFenceUseFenceLost generationFloor)
    BootstrapFenceStoreHeld observed
      | observed == expectedFence -> Right ()
      | otherwise -> Left (BootstrapFenceUseFenceStale expectedFence observed)
  leaseWitness <-
    firstEither
      BootstrapFenceUseLeaseRefused
      (confirmBootstrapLease monotonicNow expectedFence leaseObservation)
  attemptDeadline <-
    firstEither
      BootstrapFenceUseDeadlineRefused
      ( deriveAttemptDeadline
          monotonicNow
          requestDeadline
          clockObservation
          (bootstrapFenceOperationDeadline expectedFence)
      )
  let boundedDeadline = min attemptDeadline (bootstrapLeaseWitnessDeadline leaseWitness)
  if deadlineExpired monotonicNow boundedDeadline
    then Left (BootstrapFenceUseLeaseRefused BootstrapLeaseExpired)
    else Right boundedDeadline

fenceFromRequest :: Natural -> BootstrapFenceAcquireRequest -> BootstrapSessionFence
fenceFromRequest generationFloor request =
  BootstrapSessionFence
    { internalFenceGeneration = BootstrapFenceGeneration (generationFloor + 1)
    , internalFenceOwnerNonce = fenceAcquireOwnerNonce request
    , internalFenceActionDigest = fenceAcquireActionDigest request
    , internalFenceRequestDigest = fenceAcquireRequestDigest request
    , internalFenceStorageGeneration = fenceAcquireStorageGeneration request
    , internalFenceOperationDeadline = fenceAcquireOperationDeadline request
    }

requestExactlyMatchesFence
  :: BootstrapFenceAcquireRequest -> BootstrapSessionFence -> Bool
requestExactlyMatchesFence request fence =
  fenceAcquireOwnerNonce request == bootstrapFenceOwnerNonce fence
    && fenceAcquireActionDigest request == bootstrapFenceActionDigest fence
    && fenceAcquireRequestDigest request == bootstrapFenceRequestDigest fence
    && fenceAcquireStorageGeneration request == bootstrapFenceStorageGeneration fence
    && fenceAcquireOperationDeadline request == bootstrapFenceOperationDeadline fence

nullText :: Text -> Bool
nullText = Text.null

firstEither :: (left -> mapped) -> Either left right -> Either mapped right
firstEither mapLeft = either (Left . mapLeft) Right
