{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

-- | Pure protocol for the Bootstrap Broker's isolated secret workers.
--
-- The long-lived controller handles metadata, typed receipts, and only the
-- closed encrypted/sealed result artifacts needed for crash recovery. Prompt
-- bytes and decrypted shares are deliberately not represented: an interpreter
-- connects authenticated exec/attach stdin directly to an attested one-shot
-- worker after consuming the opaque 'LinearSecretIngress'. The ingress has no
-- 'Eq', 'Show', or serialization instance and cannot escape its rank-2 scope.
--
-- Kubernetes Job/Pod creation, exec/attach, session revocation, and deletion
-- are interpreter concerns.  This module supplies the exact attestation,
-- per-effect fence, cleanup, and restart decisions those effects must obey.
module Prodbox.Bootstrap.Broker.SecretWorker
  ( -- * Validated worker identity
    SecretWorkerValueError (..)
  , WorkerPodUid
  , mkWorkerPodUid
  , renderWorkerPodUid
  , WorkerImageDigest
  , mkWorkerImageDigest
  , renderWorkerImageDigest
  , WorkerServiceAccount
  , mkWorkerServiceAccount
  , renderWorkerServiceAccount
  , WorkerSessionId
  , mkWorkerSessionId
  , renderWorkerSessionId
  , WorkerSessionAccessor
  , mkWorkerSessionAccessor
  , renderWorkerSessionAccessor

    -- * Secret-free request metadata
  , SecretWorkerOperation (..)
  , SecretFreeWorkerRequest
  , mkSecretFreeWorkerRequest
  , secretWorkerRequestOperation
  , secretWorkerRequestPodUid
  , secretWorkerRequestImageDigest
  , secretWorkerRequestServiceAccount
  , secretWorkerRequestSessionId
  , secretWorkerRequestSessionAccessor
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOwnerNonce
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestStorageGeneration
  , secretWorkerRequestOperationDeadline

    -- * Exact workload attestation
  , RawSecretWorkerAttestation (..)
  , SecretWorkerAttestationObservation (..)
  , AttestedSecretWorker
  , attestedSecretWorkerRequest
  , attestedSecretWorkerEvidence
  , SecretWorkerAttestationRefusal (..)
  , attestSecretWorker

    -- * Fresh fenced effect authorization
  , SecretWorkerEffectPermit
  , secretWorkerEffectPermitOperation
  , secretWorkerEffectPermitDeadline
  , SecretWorkerEffectRefusal (..)
  , authorizeSecretWorkerEffect

    -- * Opaque one-shot secret ingress
  , RunningSecretWorker
  , ExecutedSecretWorker
  , executeAuthorizedSecretWorker
  , finishSecretWorkerExecution

    -- * Typed, secret-free receipt
  , SecretWorkerOutcome (..)
  , SecretWorkerDurableResult
  , preparedInitializationWorkerResult
  , resumedInitializationWorkerResult
  , encryptedInitializationWorkerResult
  , ambiguousInitializationWorkerResult
  , finalizedInitializationWorkerResult
  , unsealWorkerResult
  , unlockRotationWorkerResult
  , transitRotationWorkerResult
  , durablePreparedInitialization
  , durableResumedInitialization
  , durableEncryptedInitialization
  , durableInitializationIsAmbiguous
  , durableFinalizedInitialization
  , durableUnsealResult
  , durableUnlockRotationResult
  , durableTransitRotationResult
  , secretWorkerDurableResultOperation
  , RawSecretWorkerReceipt (..)
  , SecretWorkerReceipt
  , secretWorkerReceiptOperation
  , secretWorkerReceiptPodUid
  , secretWorkerReceiptSessionId
  , secretWorkerReceiptSessionAccessor
  , secretWorkerReceiptRequestDigest
  , secretWorkerReceiptStorageGeneration
  , secretWorkerReceiptFenceGeneration
  , secretWorkerReceiptOutcome
  , secretWorkerReceiptDigest
  , ReceiptCapturedSecretWorker
  , capturedSecretWorkerReceipt
  , capturedSecretWorkerResult
  , SecretWorkerReceiptRefusal (..)
  , captureSecretWorkerReceipt

    -- * Mandatory cleanup read-back
  , SecretWorkerCleanupBinding (..)
  , secretWorkerCleanupBinding
  , SecretWorkerLifecycleObservation (..)
  , SessionRevokedSecretWorker
  , ExitedSecretWorker
  , DeletedSecretWorker
  , AbsentSecretWorker
  , SecretWorkerCleanupRefusal (..)
  , confirmSecretWorkerSessionRevoked
  , confirmSecretWorkerExited
  , confirmSecretWorkerDeleted
  , confirmSecretWorkerAbsent
  , advanceSecretWorkerCleanupCheckpoint

    -- * Restart/disconnect recovery
  , SecretWorkerInterruption (..)
  , SecretWorkerDurableCheckpoint
  , noSecretWorkerReceipt
  , receiptCapturedCheckpoint
  , authoritativelyRecoveredWorkerCheckpoint
  , sessionRevokedCheckpoint
  , workerExitedCheckpoint
  , workerDeletedCheckpoint
  , workerAbsentCheckpoint
  , unobservableWorkerCheckpoint
  , secretWorkerCheckpointRequest
  , secretWorkerCheckpointReceipt
  , secretWorkerCheckpointResult
  , SecretWorkerRecoveryRefusal (..)
  , SecretWorkerRecoveryDecision (..)
  , decideSecretWorkerRecovery
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceGeneration
  , BootstrapSessionFence
  , BootstrapVaultEffect (..)
  , BootstrapVaultEffectPermit
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceOperationDeadline
  , bootstrapFenceOwnerNonce
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  , vaultEffectPermitActionDigest
  , vaultEffectPermitDeadline
  , vaultEffectPermitEffect
  , vaultEffectPermitFenceGeneration
  , vaultEffectPermitOperationDeadline
  , vaultEffectPermitOwnerNonce
  , vaultEffectPermitRequestDigest
  , vaultEffectPermitStorageGeneration
  )
import Prodbox.Bootstrap.Broker.PgpBoundary (PreparedInitRecipients)
import Prodbox.Bootstrap.Broker.Program (BootstrapMutationReceipt)
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , VaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock
  ( OperationDeadline
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineExpired
  )
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  )

data SecretWorkerValueError
  = SecretWorkerIdentityEmpty !String
  | SecretWorkerIdentityTooLong !String !Int !Int
  | SecretWorkerIdentityForbiddenCharacter !String
  | SecretWorkerImageDigestMustBeSha256
  deriving stock (Eq, Show)

newtype WorkerPodUid = WorkerPodUid Text
  deriving stock (Eq, Ord, Show)

mkWorkerPodUid :: Text -> Either SecretWorkerValueError WorkerPodUid
mkWorkerPodUid raw =
  WorkerPodUid <$> boundedIdentity "worker Pod UID" 128 raw

renderWorkerPodUid :: WorkerPodUid -> Text
renderWorkerPodUid (WorkerPodUid value) = value

-- | Immutable OCI image digest, including the @sha256:@ algorithm prefix.
newtype WorkerImageDigest = WorkerImageDigest Text
  deriving stock (Eq, Ord, Show)

mkWorkerImageDigest
  :: Text -> Either SecretWorkerValueError WorkerImageDigest
mkWorkerImageDigest raw
  | Text.length raw == 71
      && Text.take 7 raw == Text.pack "sha256:"
      && Text.all isLowerHex (Text.drop 7 raw) =
      Right (WorkerImageDigest raw)
  | otherwise = Left SecretWorkerImageDigestMustBeSha256
 where
  isLowerHex character =
    isDigit character || character >= 'a' && character <= 'f'

renderWorkerImageDigest :: WorkerImageDigest -> Text
renderWorkerImageDigest (WorkerImageDigest value) = value

newtype WorkerServiceAccount = WorkerServiceAccount Text
  deriving stock (Eq, Ord, Show)

mkWorkerServiceAccount
  :: Text -> Either SecretWorkerValueError WorkerServiceAccount
mkWorkerServiceAccount raw =
  WorkerServiceAccount <$> boundedIdentity "worker ServiceAccount" 253 raw

renderWorkerServiceAccount :: WorkerServiceAccount -> Text
renderWorkerServiceAccount (WorkerServiceAccount value) = value

-- | Exact managed Vault/session identity created for one attested worker.
-- These identifiers are non-secret and become part of the durable cleanup
-- binding; a Pod absence cannot stand in for session/accessor revocation.
newtype WorkerSessionId = WorkerSessionId Text
  deriving stock (Eq, Ord, Show)

mkWorkerSessionId :: Text -> Either SecretWorkerValueError WorkerSessionId
mkWorkerSessionId raw =
  WorkerSessionId <$> boundedIdentity "worker session ID" 128 raw

renderWorkerSessionId :: WorkerSessionId -> Text
renderWorkerSessionId (WorkerSessionId value) = value

newtype WorkerSessionAccessor = WorkerSessionAccessor Text
  deriving stock (Eq, Ord, Show)

mkWorkerSessionAccessor
  :: Text -> Either SecretWorkerValueError WorkerSessionAccessor
mkWorkerSessionAccessor raw =
  WorkerSessionAccessor <$> boundedIdentity "worker session accessor" 256 raw

renderWorkerSessionAccessor :: WorkerSessionAccessor -> Text
renderWorkerSessionAccessor (WorkerSessionAccessor value) = value

data SecretWorkerOperation
  = SecretWorkerPrepareInitialization
  | SecretWorkerResumeInitialization
  | SecretWorkerInitialize
  | SecretWorkerFinalizeInitialization
  | SecretWorkerUnseal
  | SecretWorkerRotateUnlockBundle
  | SecretWorkerRotateTransitKey
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Controller-owned metadata for exactly one worker.  Every field is an
-- identifier, digest, generation, or absolute deadline; secret bytes cannot
-- be placed in this type.
data SecretFreeWorkerRequest = SecretFreeWorkerRequest
  { internalWorkerRequestOperation :: !SecretWorkerOperation
  , internalWorkerRequestPodUid :: !WorkerPodUid
  , internalWorkerRequestImageDigest :: !WorkerImageDigest
  , internalWorkerRequestServiceAccount :: !WorkerServiceAccount
  , internalWorkerRequestSessionId :: !WorkerSessionId
  , internalWorkerRequestSessionAccessor :: !WorkerSessionAccessor
  , internalWorkerRequestFenceGeneration :: !BootstrapFenceGeneration
  , internalWorkerRequestOwnerNonce :: !OwnerNonce
  , internalWorkerRequestActionDigest :: !ArtifactDigest
  , internalWorkerRequestDigest :: !RequestDigest
  , internalWorkerRequestStorageGeneration :: !VaultStorageGeneration
  , internalWorkerRequestOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

mkSecretFreeWorkerRequest
  :: SecretWorkerOperation
  -> WorkerPodUid
  -> WorkerImageDigest
  -> WorkerServiceAccount
  -> WorkerSessionId
  -> WorkerSessionAccessor
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
mkSecretFreeWorkerRequest operation podUid imageDigest serviceAccount sessionId sessionAccessor fence =
  SecretFreeWorkerRequest
    { internalWorkerRequestOperation = operation
    , internalWorkerRequestPodUid = podUid
    , internalWorkerRequestImageDigest = imageDigest
    , internalWorkerRequestServiceAccount = serviceAccount
    , internalWorkerRequestSessionId = sessionId
    , internalWorkerRequestSessionAccessor = sessionAccessor
    , internalWorkerRequestFenceGeneration = bootstrapFenceGeneration fence
    , internalWorkerRequestOwnerNonce = bootstrapFenceOwnerNonce fence
    , internalWorkerRequestActionDigest = bootstrapFenceActionDigest fence
    , internalWorkerRequestDigest = bootstrapFenceRequestDigest fence
    , internalWorkerRequestStorageGeneration = bootstrapFenceStorageGeneration fence
    , internalWorkerRequestOperationDeadline = bootstrapFenceOperationDeadline fence
    }

secretWorkerRequestOperation :: SecretFreeWorkerRequest -> SecretWorkerOperation
secretWorkerRequestOperation = internalWorkerRequestOperation

secretWorkerRequestPodUid :: SecretFreeWorkerRequest -> WorkerPodUid
secretWorkerRequestPodUid = internalWorkerRequestPodUid

secretWorkerRequestImageDigest :: SecretFreeWorkerRequest -> WorkerImageDigest
secretWorkerRequestImageDigest = internalWorkerRequestImageDigest

secretWorkerRequestServiceAccount
  :: SecretFreeWorkerRequest -> WorkerServiceAccount
secretWorkerRequestServiceAccount = internalWorkerRequestServiceAccount

secretWorkerRequestSessionId :: SecretFreeWorkerRequest -> WorkerSessionId
secretWorkerRequestSessionId = internalWorkerRequestSessionId

secretWorkerRequestSessionAccessor
  :: SecretFreeWorkerRequest -> WorkerSessionAccessor
secretWorkerRequestSessionAccessor = internalWorkerRequestSessionAccessor

secretWorkerRequestFenceGeneration
  :: SecretFreeWorkerRequest -> BootstrapFenceGeneration
secretWorkerRequestFenceGeneration = internalWorkerRequestFenceGeneration

secretWorkerRequestOwnerNonce :: SecretFreeWorkerRequest -> OwnerNonce
secretWorkerRequestOwnerNonce = internalWorkerRequestOwnerNonce

secretWorkerRequestActionDigest :: SecretFreeWorkerRequest -> ArtifactDigest
secretWorkerRequestActionDigest = internalWorkerRequestActionDigest

secretWorkerRequestDigest :: SecretFreeWorkerRequest -> RequestDigest
secretWorkerRequestDigest = internalWorkerRequestDigest

secretWorkerRequestStorageGeneration
  :: SecretFreeWorkerRequest -> VaultStorageGeneration
secretWorkerRequestStorageGeneration = internalWorkerRequestStorageGeneration

secretWorkerRequestOperationDeadline
  :: SecretFreeWorkerRequest -> OperationDeadline
secretWorkerRequestOperationDeadline = internalWorkerRequestOperationDeadline

-- | Raw, untrusted Kubernetes/process observation.  Its full binding is
-- checked before an opaque 'AttestedSecretWorker' can exist.
data RawSecretWorkerAttestation = RawSecretWorkerAttestation
  { rawWorkerPodUid :: !WorkerPodUid
  , rawWorkerImageDigest :: !WorkerImageDigest
  , rawWorkerServiceAccount :: !WorkerServiceAccount
  , rawWorkerSessionId :: !WorkerSessionId
  , rawWorkerSessionAccessor :: !WorkerSessionAccessor
  , rawWorkerOperation :: !SecretWorkerOperation
  , rawWorkerFenceGeneration :: !BootstrapFenceGeneration
  , rawWorkerOwnerNonce :: !OwnerNonce
  , rawWorkerActionDigest :: !ArtifactDigest
  , rawWorkerRequestDigest :: !RequestDigest
  , rawWorkerStorageGeneration :: !VaultStorageGeneration
  , rawWorkerOperationDeadline :: !OperationDeadline
  }
  deriving stock (Eq, Show)

data SecretWorkerAttestationObservation
  = SecretWorkerAttestationMissing
  | SecretWorkerAttestationObserved !RawSecretWorkerAttestation
  | SecretWorkerAttestationUnobservable !Text
  deriving stock (Eq, Show)

data AttestedSecretWorker = AttestedSecretWorker
  { internalAttestedRequest :: !SecretFreeWorkerRequest
  , internalAttestedEvidence :: !RawSecretWorkerAttestation
  }
  deriving stock (Eq, Show)

attestedSecretWorkerRequest :: AttestedSecretWorker -> SecretFreeWorkerRequest
attestedSecretWorkerRequest = internalAttestedRequest

attestedSecretWorkerEvidence
  :: AttestedSecretWorker -> RawSecretWorkerAttestation
attestedSecretWorkerEvidence = internalAttestedEvidence

data SecretWorkerAttestationRefusal
  = SecretWorkerAttestationNotFound
  | SecretWorkerAttestationObservationUnobservable !Text
  | SecretWorkerPodUidMismatch !WorkerPodUid !WorkerPodUid
  | SecretWorkerImageDigestMismatch !WorkerImageDigest !WorkerImageDigest
  | SecretWorkerServiceAccountMismatch
      !WorkerServiceAccount
      !WorkerServiceAccount
  | SecretWorkerSessionIdMismatch !WorkerSessionId !WorkerSessionId
  | SecretWorkerSessionAccessorMismatch
      !WorkerSessionAccessor
      !WorkerSessionAccessor
  | SecretWorkerOperationMismatch !SecretWorkerOperation !SecretWorkerOperation
  | SecretWorkerFenceGenerationMismatch
      !BootstrapFenceGeneration
      !BootstrapFenceGeneration
  | SecretWorkerOwnerNonceMismatch !OwnerNonce !OwnerNonce
  | SecretWorkerActionDigestMismatch !ArtifactDigest !ArtifactDigest
  | SecretWorkerRequestDigestMismatch !RequestDigest !RequestDigest
  | SecretWorkerStorageGenerationMismatch
      !VaultStorageGeneration
      !VaultStorageGeneration
  | SecretWorkerOperationDeadlineMismatch
      !OperationDeadline
      !OperationDeadline
  deriving stock (Eq, Show)

attestSecretWorker
  :: SecretFreeWorkerRequest
  -> SecretWorkerAttestationObservation
  -> Either SecretWorkerAttestationRefusal AttestedSecretWorker
attestSecretWorker request observation = case observation of
  SecretWorkerAttestationMissing -> Left SecretWorkerAttestationNotFound
  SecretWorkerAttestationUnobservable detail ->
    Left (SecretWorkerAttestationObservationUnobservable detail)
  SecretWorkerAttestationObserved evidence -> do
    requireEqual
      SecretWorkerPodUidMismatch
      (secretWorkerRequestPodUid request)
      (rawWorkerPodUid evidence)
    requireEqual
      SecretWorkerImageDigestMismatch
      (secretWorkerRequestImageDigest request)
      (rawWorkerImageDigest evidence)
    requireEqual
      SecretWorkerServiceAccountMismatch
      (secretWorkerRequestServiceAccount request)
      (rawWorkerServiceAccount evidence)
    requireEqual
      SecretWorkerSessionIdMismatch
      (secretWorkerRequestSessionId request)
      (rawWorkerSessionId evidence)
    requireEqual
      SecretWorkerSessionAccessorMismatch
      (secretWorkerRequestSessionAccessor request)
      (rawWorkerSessionAccessor evidence)
    requireEqual
      SecretWorkerOperationMismatch
      (secretWorkerRequestOperation request)
      (rawWorkerOperation evidence)
    requireEqual
      SecretWorkerFenceGenerationMismatch
      (secretWorkerRequestFenceGeneration request)
      (rawWorkerFenceGeneration evidence)
    requireEqual
      SecretWorkerOwnerNonceMismatch
      (secretWorkerRequestOwnerNonce request)
      (rawWorkerOwnerNonce evidence)
    requireEqual
      SecretWorkerActionDigestMismatch
      (secretWorkerRequestActionDigest request)
      (rawWorkerActionDigest evidence)
    requireEqual
      SecretWorkerRequestDigestMismatch
      (secretWorkerRequestDigest request)
      (rawWorkerRequestDigest evidence)
    requireEqual
      SecretWorkerStorageGenerationMismatch
      (secretWorkerRequestStorageGeneration request)
      (rawWorkerStorageGeneration evidence)
    requireEqual
      SecretWorkerOperationDeadlineMismatch
      (secretWorkerRequestOperationDeadline request)
      (rawWorkerOperationDeadline evidence)
    pure
      AttestedSecretWorker
        { internalAttestedRequest = request
        , internalAttestedEvidence = evidence
        }

-- | Opaque proof that the attested worker and a freshly revalidated durable
-- fence/Lease permit authorize the same one-shot operation.
data SecretWorkerEffectPermit = SecretWorkerEffectPermit
  { internalWorkerEffectPermitOperation :: !SecretWorkerOperation
  , internalWorkerEffectPermitDeadline :: !Deadline
  , internalWorkerEffectPermitAttestation :: !AttestedSecretWorker
  }
  deriving stock (Eq, Show)

secretWorkerEffectPermitOperation
  :: SecretWorkerEffectPermit -> SecretWorkerOperation
secretWorkerEffectPermitOperation = internalWorkerEffectPermitOperation

secretWorkerEffectPermitDeadline :: SecretWorkerEffectPermit -> Deadline
secretWorkerEffectPermitDeadline = internalWorkerEffectPermitDeadline

data SecretWorkerEffectRefusal
  = SecretWorkerEffectDeadlineElapsed
  | SecretWorkerEffectOperationRefused
      !BootstrapVaultEffect
      !BootstrapVaultEffect
  | SecretWorkerEffectFenceGenerationRefused
      !BootstrapFenceGeneration
      !BootstrapFenceGeneration
  | SecretWorkerEffectOwnerNonceRefused !OwnerNonce !OwnerNonce
  | SecretWorkerEffectActionDigestRefused !ArtifactDigest !ArtifactDigest
  | SecretWorkerEffectRequestDigestRefused !RequestDigest !RequestDigest
  | SecretWorkerEffectStorageGenerationRefused
      !VaultStorageGeneration
      !VaultStorageGeneration
  | SecretWorkerEffectOperationDeadlineRefused
      !OperationDeadline
      !OperationDeadline
  deriving stock (Eq, Show)

authorizeSecretWorkerEffect
  :: MonotonicInstant
  -> AttestedSecretWorker
  -> BootstrapVaultEffectPermit
  -> Either SecretWorkerEffectRefusal SecretWorkerEffectPermit
authorizeSecretWorkerEffect now attested fencePermit = do
  let request = attestedSecretWorkerRequest attested
      expectedEffect = workerOperationEffect (secretWorkerRequestOperation request)
  if deadlineExpired now (vaultEffectPermitDeadline fencePermit)
    then Left SecretWorkerEffectDeadlineElapsed
    else pure ()
  requireEqual
    SecretWorkerEffectOperationRefused
    expectedEffect
    (vaultEffectPermitEffect fencePermit)
  requireEqual
    SecretWorkerEffectFenceGenerationRefused
    (secretWorkerRequestFenceGeneration request)
    (vaultEffectPermitFenceGeneration fencePermit)
  requireEqual
    SecretWorkerEffectOwnerNonceRefused
    (secretWorkerRequestOwnerNonce request)
    (vaultEffectPermitOwnerNonce fencePermit)
  requireEqual
    SecretWorkerEffectActionDigestRefused
    (secretWorkerRequestActionDigest request)
    (vaultEffectPermitActionDigest fencePermit)
  requireEqual
    SecretWorkerEffectRequestDigestRefused
    (secretWorkerRequestDigest request)
    (vaultEffectPermitRequestDigest fencePermit)
  requireEqual
    SecretWorkerEffectStorageGenerationRefused
    (secretWorkerRequestStorageGeneration request)
    (vaultEffectPermitStorageGeneration fencePermit)
  requireEqual
    SecretWorkerEffectOperationDeadlineRefused
    (secretWorkerRequestOperationDeadline request)
    (vaultEffectPermitOperationDeadline fencePermit)
  pure
    SecretWorkerEffectPermit
      { internalWorkerEffectPermitOperation = secretWorkerRequestOperation request
      , internalWorkerEffectPermitDeadline = vaultEffectPermitDeadline fencePermit
      , internalWorkerEffectPermitAttestation = attested
      }

-- | Unforgeable token for the direct authenticated stdin channel.  It carries
-- no bytes and intentionally has no instances.  The rank-2 scope prevents a
-- worker-specific ingress token from entering controller state.
data LinearSecretIngress (scope :: Type) = LinearSecretIngress

-- | The same generative scope ties the ingress to its exact fenced permit.
data IngressReadySecretWorker (scope :: Type) = IngressReadySecretWorker

data RunningSecretWorker (scope :: Type) = RunningSecretWorker

-- | Terminal witness returned after the interpreter has consumed the one-shot
-- ingress while performing the exact physical call. It has no execution
-- eliminator and is consumed by receipt capture.
data ExecutedSecretWorker = ExecutedSecretWorker !SecretWorkerEffectPermit

withLinearSecretIngress
  :: SecretWorkerEffectPermit
  -> ( forall scope
        . LinearSecretIngress scope
       %1 -> IngressReadySecretWorker scope
       %1 -> result
     )
  -> result
withLinearSecretIngress permit use =
  permit `seq` use LinearSecretIngress IngressReadySecretWorker

-- | Consume the one-shot ingress and its scope-matched worker readiness.  An
-- interpreter performs direct stdin transfer while consuming these values;
-- neither the controller nor the returned running state contains plaintext.
startSecretWorker
  :: LinearSecretIngress scope
  %1 -> IngressReadySecretWorker scope
  %1 -> RunningSecretWorker scope
startSecretWorker LinearSecretIngress IngressReadySecretWorker =
  RunningSecretWorker

-- | Consume an ingress authority that cannot be used because a fresh
-- authorization/readiness check failed before physical transfer.
discardRunningSecretWorker :: RunningSecretWorker scope %1 -> ()
discardRunningSecretWorker RunningSecretWorker = ()

-- | Allocate one generative, one-shot ingress for the trusted physical
-- interpreter. The running authority cannot occur in the result type because
-- the callback is rank-2, and the linear arrow requires the interpreter to
-- consume it exactly once.
executeAuthorizedSecretWorker
  :: (Monad m)
  => SecretWorkerEffectPermit
  -> ( forall scope
        . RunningSecretWorker scope
       %1 -> m
               ( Either
                   boundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
               )
     )
  -> m
       ( Either
           boundaryError
           (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
       )
executeAuthorizedSecretWorker permit execute =
  withLinearSecretIngress permit $ \ingress ready ->
    execute (startSecretWorker ingress ready)

-- | Trusted terminal step for a direct stdin transfer. Consuming the scoped
-- running authority arms exactly one evaluation of the supplied physical
-- action. An 'ExecutedSecretWorker' is constructed only after that action
-- returns a receipt and result; refusal returns no terminal witness.
finishSecretWorkerExecution
  :: (Monad m)
  => SecretWorkerEffectPermit
  -> m (Either boundaryError (RawSecretWorkerReceipt, result))
  -> RunningSecretWorker scope
  %1 -> m
          ( Either
              boundaryError
              (ExecutedSecretWorker, RawSecretWorkerReceipt, result)
          )
finishSecretWorkerExecution permit physical running =
  case discardRunningSecretWorker running of
    () -> do
      observed <- physical
      pure $ case observed of
        Left failure -> Left failure
        Right (receipt, result) ->
          Right (ExecutedSecretWorker permit, receipt, result)

data SecretWorkerOutcome
  = SecretWorkerInitialized
  | SecretWorkerUnsealed
  | SecretWorkerUnlockBundleRotated
  | SecretWorkerTransitKeyRotated
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Closed durable output family for one-shot workers. Constructors remain
-- private so callers can neither introduce a generic result nor confuse two
-- operations. Every retained value is public metadata or ciphertext: prepared
-- recipients contain only public evidence plus the password-AEAD-sealed
-- recovery private key; init shares/token remain PGP ciphertext; the final
-- bundle is password-AEAD ciphertext; mutation receipts are non-secret.
data SecretWorkerDurableResult
  = InternalPreparedInitializationResult !PreparedInitRecipients
  | InternalResumedInitializationResult !PreparedInitRecipients
  | InternalEncryptedInitializationResult !EncryptedInitResponseReceipt
  | InternalAmbiguousInitializationResult
  | InternalFinalizedInitializationResult !FinalUnlockBundle
  | InternalUnsealResult !BootstrapMutationReceipt
  | InternalUnlockRotationResult !BootstrapMutationReceipt
  | InternalTransitRotationResult !BootstrapMutationReceipt
  deriving stock (Eq, Show)

preparedInitializationWorkerResult
  :: PreparedInitRecipients -> SecretWorkerDurableResult
preparedInitializationWorkerResult = InternalPreparedInitializationResult

resumedInitializationWorkerResult
  :: PreparedInitRecipients -> SecretWorkerDurableResult
resumedInitializationWorkerResult = InternalResumedInitializationResult

encryptedInitializationWorkerResult
  :: EncryptedInitResponseReceipt -> SecretWorkerDurableResult
encryptedInitializationWorkerResult = InternalEncryptedInitializationResult

ambiguousInitializationWorkerResult :: SecretWorkerDurableResult
ambiguousInitializationWorkerResult = InternalAmbiguousInitializationResult

finalizedInitializationWorkerResult
  :: FinalUnlockBundle -> SecretWorkerDurableResult
finalizedInitializationWorkerResult = InternalFinalizedInitializationResult

unsealWorkerResult :: BootstrapMutationReceipt -> SecretWorkerDurableResult
unsealWorkerResult = InternalUnsealResult

unlockRotationWorkerResult
  :: BootstrapMutationReceipt -> SecretWorkerDurableResult
unlockRotationWorkerResult = InternalUnlockRotationResult

transitRotationWorkerResult
  :: BootstrapMutationReceipt -> SecretWorkerDurableResult
transitRotationWorkerResult = InternalTransitRotationResult

durablePreparedInitialization
  :: SecretWorkerDurableResult -> Maybe PreparedInitRecipients
durablePreparedInitialization result = case result of
  InternalPreparedInitializationResult recipients -> Just recipients
  _ -> Nothing

durableResumedInitialization
  :: SecretWorkerDurableResult -> Maybe PreparedInitRecipients
durableResumedInitialization result = case result of
  InternalResumedInitializationResult recipients -> Just recipients
  _ -> Nothing

durableEncryptedInitialization
  :: SecretWorkerDurableResult -> Maybe EncryptedInitResponseReceipt
durableEncryptedInitialization result = case result of
  InternalEncryptedInitializationResult receipt -> Just receipt
  _ -> Nothing

durableInitializationIsAmbiguous :: SecretWorkerDurableResult -> Bool
durableInitializationIsAmbiguous result = case result of
  InternalAmbiguousInitializationResult -> True
  _ -> False

durableFinalizedInitialization
  :: SecretWorkerDurableResult -> Maybe FinalUnlockBundle
durableFinalizedInitialization result = case result of
  InternalFinalizedInitializationResult bundle -> Just bundle
  _ -> Nothing

durableUnsealResult
  :: SecretWorkerDurableResult -> Maybe BootstrapMutationReceipt
durableUnsealResult result = case result of
  InternalUnsealResult receipt -> Just receipt
  _ -> Nothing

durableUnlockRotationResult
  :: SecretWorkerDurableResult -> Maybe BootstrapMutationReceipt
durableUnlockRotationResult result = case result of
  InternalUnlockRotationResult receipt -> Just receipt
  _ -> Nothing

durableTransitRotationResult
  :: SecretWorkerDurableResult -> Maybe BootstrapMutationReceipt
durableTransitRotationResult result = case result of
  InternalTransitRotationResult receipt -> Just receipt
  _ -> Nothing

secretWorkerDurableResultOperation
  :: SecretWorkerDurableResult -> SecretWorkerOperation
secretWorkerDurableResultOperation result = case result of
  InternalPreparedInitializationResult _ -> SecretWorkerPrepareInitialization
  InternalResumedInitializationResult _ -> SecretWorkerResumeInitialization
  InternalEncryptedInitializationResult _ -> SecretWorkerInitialize
  InternalAmbiguousInitializationResult -> SecretWorkerInitialize
  InternalFinalizedInitializationResult _ -> SecretWorkerFinalizeInitialization
  InternalUnsealResult _ -> SecretWorkerUnseal
  InternalUnlockRotationResult _ -> SecretWorkerRotateUnlockBundle
  InternalTransitRotationResult _ -> SecretWorkerRotateTransitKey

-- | Raw, secret-free worker-boundary receipt.  It is not trusted merely by
-- decoding: 'captureSecretWorkerReceipt' checks every field against the
-- attested running request before producing an opaque durable receipt.
data RawSecretWorkerReceipt = RawSecretWorkerReceipt
  { rawWorkerReceiptOperation :: !SecretWorkerOperation
  , rawWorkerReceiptPodUid :: !WorkerPodUid
  , rawWorkerReceiptSessionId :: !WorkerSessionId
  , rawWorkerReceiptSessionAccessor :: !WorkerSessionAccessor
  , rawWorkerReceiptRequestDigest :: !RequestDigest
  , rawWorkerReceiptStorageGeneration :: !VaultStorageGeneration
  , rawWorkerReceiptFenceGeneration :: !BootstrapFenceGeneration
  , rawWorkerReceiptOutcome :: !SecretWorkerOutcome
  , rawWorkerReceiptDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

-- | Typed controller receipt.  The digest covers the secret-free receipt
-- encoding, not prompt plaintext or an unkeyed hash of secret material.
data SecretWorkerReceipt = SecretWorkerReceipt
  { internalWorkerReceiptOperation :: !SecretWorkerOperation
  , internalWorkerReceiptPodUid :: !WorkerPodUid
  , internalWorkerReceiptSessionId :: !WorkerSessionId
  , internalWorkerReceiptSessionAccessor :: !WorkerSessionAccessor
  , internalWorkerReceiptRequestDigest :: !RequestDigest
  , internalWorkerReceiptStorageGeneration :: !VaultStorageGeneration
  , internalWorkerReceiptFenceGeneration :: !BootstrapFenceGeneration
  , internalWorkerReceiptOutcome :: !SecretWorkerOutcome
  , internalWorkerReceiptDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

secretWorkerReceiptOperation :: SecretWorkerReceipt -> SecretWorkerOperation
secretWorkerReceiptOperation = internalWorkerReceiptOperation

secretWorkerReceiptPodUid :: SecretWorkerReceipt -> WorkerPodUid
secretWorkerReceiptPodUid = internalWorkerReceiptPodUid

secretWorkerReceiptSessionId :: SecretWorkerReceipt -> WorkerSessionId
secretWorkerReceiptSessionId = internalWorkerReceiptSessionId

secretWorkerReceiptSessionAccessor
  :: SecretWorkerReceipt -> WorkerSessionAccessor
secretWorkerReceiptSessionAccessor = internalWorkerReceiptSessionAccessor

secretWorkerReceiptRequestDigest :: SecretWorkerReceipt -> RequestDigest
secretWorkerReceiptRequestDigest = internalWorkerReceiptRequestDigest

secretWorkerReceiptStorageGeneration
  :: SecretWorkerReceipt -> VaultStorageGeneration
secretWorkerReceiptStorageGeneration = internalWorkerReceiptStorageGeneration

secretWorkerReceiptFenceGeneration
  :: SecretWorkerReceipt -> BootstrapFenceGeneration
secretWorkerReceiptFenceGeneration = internalWorkerReceiptFenceGeneration

secretWorkerReceiptOutcome :: SecretWorkerReceipt -> SecretWorkerOutcome
secretWorkerReceiptOutcome = internalWorkerReceiptOutcome

secretWorkerReceiptDigest :: SecretWorkerReceipt -> ArtifactDigest
secretWorkerReceiptDigest = internalWorkerReceiptDigest

data ReceiptCapturedSecretWorker = ReceiptCapturedSecretWorker
  { internalCapturedRequest :: !SecretFreeWorkerRequest
  , internalCapturedReceipt :: !SecretWorkerReceipt
  , internalCapturedResult :: !SecretWorkerDurableResult
  }
  deriving stock (Eq, Show)

capturedSecretWorkerReceipt
  :: ReceiptCapturedSecretWorker -> SecretWorkerReceipt
capturedSecretWorkerReceipt = internalCapturedReceipt

capturedSecretWorkerResult
  :: ReceiptCapturedSecretWorker -> SecretWorkerDurableResult
capturedSecretWorkerResult = internalCapturedResult

data SecretWorkerReceiptRefusal
  = SecretWorkerReceiptOperationMismatch
      !SecretWorkerOperation
      !SecretWorkerOperation
  | SecretWorkerReceiptPodUidMismatch !WorkerPodUid !WorkerPodUid
  | SecretWorkerReceiptSessionIdMismatch !WorkerSessionId !WorkerSessionId
  | SecretWorkerReceiptSessionAccessorMismatch
      !WorkerSessionAccessor
      !WorkerSessionAccessor
  | SecretWorkerReceiptRequestDigestMismatch !RequestDigest !RequestDigest
  | SecretWorkerReceiptStorageGenerationMismatch
      !VaultStorageGeneration
      !VaultStorageGeneration
  | SecretWorkerReceiptFenceGenerationMismatch
      !BootstrapFenceGeneration
      !BootstrapFenceGeneration
  | SecretWorkerOutcomeMismatch !SecretWorkerOperation !SecretWorkerOutcome
  | SecretWorkerResultOperationMismatch
      !SecretWorkerOperation
      !SecretWorkerOperation
  deriving stock (Eq, Show)

captureSecretWorkerReceipt
  :: ExecutedSecretWorker
  -> RawSecretWorkerReceipt
  -> SecretWorkerDurableResult
  -> Either SecretWorkerReceiptRefusal ReceiptCapturedSecretWorker
captureSecretWorkerReceipt (ExecutedSecretWorker permit) observed durableResult = do
  let
    operation = secretWorkerEffectPermitOperation permit
    request =
      attestedSecretWorkerRequest
        (internalWorkerEffectPermitAttestation permit)
  requireEqual
    SecretWorkerReceiptOperationMismatch
    operation
    (rawWorkerReceiptOperation observed)
  requireEqual
    SecretWorkerReceiptPodUidMismatch
    (secretWorkerRequestPodUid request)
    (rawWorkerReceiptPodUid observed)
  requireEqual
    SecretWorkerReceiptSessionIdMismatch
    (secretWorkerRequestSessionId request)
    (rawWorkerReceiptSessionId observed)
  requireEqual
    SecretWorkerReceiptSessionAccessorMismatch
    (secretWorkerRequestSessionAccessor request)
    (rawWorkerReceiptSessionAccessor observed)
  requireEqual
    SecretWorkerReceiptRequestDigestMismatch
    (secretWorkerRequestDigest request)
    (rawWorkerReceiptRequestDigest observed)
  requireEqual
    SecretWorkerReceiptStorageGenerationMismatch
    (secretWorkerRequestStorageGeneration request)
    (rawWorkerReceiptStorageGeneration observed)
  requireEqual
    SecretWorkerReceiptFenceGenerationMismatch
    (secretWorkerRequestFenceGeneration request)
    (rawWorkerReceiptFenceGeneration observed)
  if outcomeMatchesOperation operation (rawWorkerReceiptOutcome observed)
    then
      if secretWorkerDurableResultOperation durableResult == operation
        then
          Right
            ReceiptCapturedSecretWorker
              { internalCapturedRequest = request
              , internalCapturedReceipt =
                  SecretWorkerReceipt
                    { internalWorkerReceiptOperation = operation
                    , internalWorkerReceiptPodUid = secretWorkerRequestPodUid request
                    , internalWorkerReceiptSessionId = secretWorkerRequestSessionId request
                    , internalWorkerReceiptSessionAccessor =
                        secretWorkerRequestSessionAccessor request
                    , internalWorkerReceiptRequestDigest = secretWorkerRequestDigest request
                    , internalWorkerReceiptStorageGeneration =
                        secretWorkerRequestStorageGeneration request
                    , internalWorkerReceiptFenceGeneration =
                        secretWorkerRequestFenceGeneration request
                    , internalWorkerReceiptOutcome = rawWorkerReceiptOutcome observed
                    , internalWorkerReceiptDigest = rawWorkerReceiptDigest observed
                    }
              , internalCapturedResult = durableResult
              }
        else
          Left
            ( SecretWorkerResultOperationMismatch
                operation
                (secretWorkerDurableResultOperation durableResult)
            )
    else
      Left
        (SecretWorkerOutcomeMismatch operation (rawWorkerReceiptOutcome observed))

-- | Exact identity repeated by every cleanup observation, preventing a stale
-- Pod/session acknowledgment from completing a newer request.
data SecretWorkerCleanupBinding = SecretWorkerCleanupBinding
  { cleanupWorkerPodUid :: !WorkerPodUid
  , cleanupWorkerSessionId :: !WorkerSessionId
  , cleanupWorkerSessionAccessor :: !WorkerSessionAccessor
  , cleanupWorkerRequestDigest :: !RequestDigest
  , cleanupWorkerStorageGeneration :: !VaultStorageGeneration
  , cleanupWorkerFenceGeneration :: !BootstrapFenceGeneration
  , cleanupWorkerReceiptDigest :: !ArtifactDigest
  }
  deriving stock (Eq, Show)

secretWorkerCleanupBinding
  :: SecretWorkerReceipt -> SecretWorkerCleanupBinding
secretWorkerCleanupBinding receipt =
  SecretWorkerCleanupBinding
    { cleanupWorkerPodUid = secretWorkerReceiptPodUid receipt
    , cleanupWorkerSessionId = secretWorkerReceiptSessionId receipt
    , cleanupWorkerSessionAccessor = secretWorkerReceiptSessionAccessor receipt
    , cleanupWorkerRequestDigest = secretWorkerReceiptRequestDigest receipt
    , cleanupWorkerStorageGeneration = secretWorkerReceiptStorageGeneration receipt
    , cleanupWorkerFenceGeneration = secretWorkerReceiptFenceGeneration receipt
    , cleanupWorkerReceiptDigest = secretWorkerReceiptDigest receipt
    }

data SecretWorkerLifecycleObservation
  = SecretWorkerSessionRevoked !SecretWorkerCleanupBinding
  | SecretWorkerProcessExited !SecretWorkerCleanupBinding !Int
  | SecretWorkerPodDeleted !SecretWorkerCleanupBinding
  | SecretWorkerPodAbsent !SecretWorkerCleanupBinding
  | SecretWorkerLifecycleUnobservable !Text
  deriving stock (Eq, Show)

data SessionRevokedSecretWorker = SessionRevokedSecretWorker
  { internalRevokedCaptured :: !ReceiptCapturedSecretWorker
  }
  deriving stock (Eq, Show)

data ExitedSecretWorker = ExitedSecretWorker
  { internalExitedRevoked :: !SessionRevokedSecretWorker
  }
  deriving stock (Eq, Show)

data DeletedSecretWorker = DeletedSecretWorker
  { internalDeletedExited :: !ExitedSecretWorker
  }
  deriving stock (Eq, Show)

data AbsentSecretWorker = AbsentSecretWorker
  { internalAbsentDeleted :: !DeletedSecretWorker
  }
  deriving stock (Eq, Show)

data SecretWorkerCleanupRefusal
  = SecretWorkerCleanupObservationUnobservable !Text
  | SecretWorkerCleanupUnexpectedObservation !SecretWorkerLifecycleObservation
  | SecretWorkerCleanupBindingMismatch
      !SecretWorkerCleanupBinding
      !SecretWorkerCleanupBinding
  | SecretWorkerCleanupNonZeroExit !Int
  | SecretWorkerCleanupCheckpointRequestMismatch
  | SecretWorkerCleanupCheckpointNotAdvanceable
  | SecretWorkerCleanupCheckpointUnobservable !Text
  deriving stock (Eq, Show)

confirmSecretWorkerSessionRevoked
  :: ReceiptCapturedSecretWorker
  -> SecretWorkerLifecycleObservation
  -> Either SecretWorkerCleanupRefusal SessionRevokedSecretWorker
confirmSecretWorkerSessionRevoked captured observation =
  case observation of
    SecretWorkerLifecycleUnobservable detail ->
      Left (SecretWorkerCleanupObservationUnobservable detail)
    SecretWorkerSessionRevoked observed -> do
      requireCleanupBinding (capturedBinding captured) observed
      pure SessionRevokedSecretWorker {internalRevokedCaptured = captured}
    _ -> Left (SecretWorkerCleanupUnexpectedObservation observation)

confirmSecretWorkerExited
  :: SessionRevokedSecretWorker
  -> SecretWorkerLifecycleObservation
  -> Either SecretWorkerCleanupRefusal ExitedSecretWorker
confirmSecretWorkerExited revoked observation =
  case observation of
    SecretWorkerLifecycleUnobservable detail ->
      Left (SecretWorkerCleanupObservationUnobservable detail)
    SecretWorkerProcessExited observed exitCode -> do
      requireCleanupBinding (revokedBinding revoked) observed
      if exitCode == 0
        then pure ExitedSecretWorker {internalExitedRevoked = revoked}
        else Left (SecretWorkerCleanupNonZeroExit exitCode)
    _ -> Left (SecretWorkerCleanupUnexpectedObservation observation)

confirmSecretWorkerDeleted
  :: ExitedSecretWorker
  -> SecretWorkerLifecycleObservation
  -> Either SecretWorkerCleanupRefusal DeletedSecretWorker
confirmSecretWorkerDeleted exited observation =
  case observation of
    SecretWorkerLifecycleUnobservable detail ->
      Left (SecretWorkerCleanupObservationUnobservable detail)
    SecretWorkerPodDeleted observed -> do
      requireCleanupBinding (exitedBinding exited) observed
      pure DeletedSecretWorker {internalDeletedExited = exited}
    _ -> Left (SecretWorkerCleanupUnexpectedObservation observation)

confirmSecretWorkerAbsent
  :: DeletedSecretWorker
  -> SecretWorkerLifecycleObservation
  -> Either SecretWorkerCleanupRefusal AbsentSecretWorker
confirmSecretWorkerAbsent deleted observation =
  case observation of
    SecretWorkerLifecycleUnobservable detail ->
      Left (SecretWorkerCleanupObservationUnobservable detail)
    SecretWorkerPodAbsent observed -> do
      requireCleanupBinding (deletedBinding deleted) observed
      pure AbsentSecretWorker {internalAbsentDeleted = deleted}
    _ -> Left (SecretWorkerCleanupUnexpectedObservation observation)

-- | Advance exactly one durable cleanup phase after restart.  The opaque
-- staged witnesses remain inside this module, so an interpreter cannot
-- reconstruct or skip a revoke/exit/delete/absence confirmation.  The
-- expected request is checked before the lifecycle observation is consumed.
advanceSecretWorkerCleanupCheckpoint
  :: SecretFreeWorkerRequest
  -> SecretWorkerDurableCheckpoint
  -> SecretWorkerLifecycleObservation
  -> Either SecretWorkerCleanupRefusal SecretWorkerDurableCheckpoint
advanceSecretWorkerCleanupCheckpoint expected checkpoint observation =
  case checkpoint of
    InternalReceiptCaptured captured -> do
      requireCheckpointRequest expected captured
      sessionRevokedCheckpoint
        <$> confirmSecretWorkerSessionRevoked captured observation
    InternalSessionRevoked revoked -> do
      requireCheckpointRequest expected (revokedCaptured revoked)
      workerExitedCheckpoint <$> confirmSecretWorkerExited revoked observation
    InternalWorkerExited exited -> do
      requireCheckpointRequest expected (exitedCaptured exited)
      workerDeletedCheckpoint <$> confirmSecretWorkerDeleted exited observation
    InternalWorkerDeleted deleted -> do
      requireCheckpointRequest expected (deletedCaptured deleted)
      workerAbsentCheckpoint <$> confirmSecretWorkerAbsent deleted observation
    InternalWorkerCheckpointUnobservable detail ->
      Left (SecretWorkerCleanupCheckpointUnobservable detail)
    InternalNoWorkerReceipt _ ->
      Left SecretWorkerCleanupCheckpointNotAdvanceable
    InternalWorkerAuthoritativelyRecovered _ _ ->
      Left SecretWorkerCleanupCheckpointNotAdvanceable
    InternalWorkerAbsent _ ->
      Left SecretWorkerCleanupCheckpointNotAdvanceable
 where
  requireCheckpointRequest request captured
    | receiptMatchesRequest request (capturedSecretWorkerReceipt captured) =
        Right ()
    | otherwise = Left SecretWorkerCleanupCheckpointRequestMismatch

data SecretWorkerInterruption
  = SecretWorkerControllerRestarted
  | SecretWorkerClientDisconnected
  | SecretWorkerPodLost
  | SecretWorkerAttestationInvalidated
  | SecretWorkerFenceLost
  | SecretWorkerDeadlineElapsed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Durable controller progress.  Constructors are private: later cleanup
-- checkpoints can only be projected from the corresponding exact read-back.
data SecretWorkerDurableCheckpoint
  = InternalNoWorkerReceipt !SecretFreeWorkerRequest
  | InternalWorkerAuthoritativelyRecovered
      !SecretFreeWorkerRequest
      !SecretWorkerDurableResult
  | InternalReceiptCaptured !ReceiptCapturedSecretWorker
  | InternalSessionRevoked !SessionRevokedSecretWorker
  | InternalWorkerExited !ExitedSecretWorker
  | InternalWorkerDeleted !DeletedSecretWorker
  | InternalWorkerAbsent !AbsentSecretWorker
  | InternalWorkerCheckpointUnobservable !Text
  deriving stock (Eq, Show)

noSecretWorkerReceipt
  :: SecretFreeWorkerRequest -> SecretWorkerDurableCheckpoint
noSecretWorkerReceipt = InternalNoWorkerReceipt

receiptCapturedCheckpoint
  :: ReceiptCapturedSecretWorker -> SecretWorkerDurableCheckpoint
receiptCapturedCheckpoint = InternalReceiptCaptured

-- | Terminal no-replay checkpoint used only after an authoritative outer
-- recovery has proved that the physical effect completed but no worker
-- receipt was durably captured. The exact request/result operation binding is
-- checked before the checkpoint can be constructed.
authoritativelyRecoveredWorkerCheckpoint
  :: SecretFreeWorkerRequest
  -> SecretWorkerDurableResult
  -> Either SecretWorkerReceiptRefusal SecretWorkerDurableCheckpoint
authoritativelyRecoveredWorkerCheckpoint request result
  | secretWorkerRequestOperation request
      == secretWorkerDurableResultOperation result =
      Right (InternalWorkerAuthoritativelyRecovered request result)
  | otherwise =
      Left
        ( SecretWorkerResultOperationMismatch
            (secretWorkerRequestOperation request)
            (secretWorkerDurableResultOperation result)
        )

sessionRevokedCheckpoint
  :: SessionRevokedSecretWorker -> SecretWorkerDurableCheckpoint
sessionRevokedCheckpoint = InternalSessionRevoked

workerExitedCheckpoint
  :: ExitedSecretWorker -> SecretWorkerDurableCheckpoint
workerExitedCheckpoint = InternalWorkerExited

workerDeletedCheckpoint
  :: DeletedSecretWorker -> SecretWorkerDurableCheckpoint
workerDeletedCheckpoint = InternalWorkerDeleted

workerAbsentCheckpoint
  :: AbsentSecretWorker -> SecretWorkerDurableCheckpoint
workerAbsentCheckpoint = InternalWorkerAbsent

unobservableWorkerCheckpoint :: Text -> SecretWorkerDurableCheckpoint
unobservableWorkerCheckpoint = InternalWorkerCheckpointUnobservable

secretWorkerCheckpointRequest
  :: SecretWorkerDurableCheckpoint
  -> Either SecretWorkerRecoveryRefusal SecretFreeWorkerRequest
secretWorkerCheckpointRequest checkpoint = case checkpoint of
  InternalNoWorkerReceipt request -> Right request
  InternalWorkerAuthoritativelyRecovered request _ -> Right request
  InternalReceiptCaptured captured -> Right (internalCapturedRequest captured)
  InternalSessionRevoked revoked ->
    Right (internalCapturedRequest (revokedCaptured revoked))
  InternalWorkerExited exited ->
    Right (internalCapturedRequest (exitedCaptured exited))
  InternalWorkerDeleted deleted ->
    Right (internalCapturedRequest (deletedCaptured deleted))
  InternalWorkerAbsent absent ->
    Right
      ( internalCapturedRequest
          (deletedCaptured (internalAbsentDeleted absent))
      )
  InternalWorkerCheckpointUnobservable detail ->
    Left (SecretWorkerRecoveryCheckpointUnobservable detail)

secretWorkerCheckpointReceipt
  :: SecretWorkerDurableCheckpoint -> Maybe SecretWorkerReceipt
secretWorkerCheckpointReceipt checkpoint = case checkpoint of
  InternalNoWorkerReceipt _ -> Nothing
  InternalWorkerAuthoritativelyRecovered _ _ -> Nothing
  InternalReceiptCaptured captured -> Just (capturedSecretWorkerReceipt captured)
  InternalSessionRevoked revoked ->
    Just (capturedSecretWorkerReceipt (revokedCaptured revoked))
  InternalWorkerExited exited ->
    Just (capturedSecretWorkerReceipt (exitedCaptured exited))
  InternalWorkerDeleted deleted ->
    Just (capturedSecretWorkerReceipt (deletedCaptured deleted))
  InternalWorkerAbsent absent ->
    Just (capturedSecretWorkerReceipt (deletedCaptured (internalAbsentDeleted absent)))
  InternalWorkerCheckpointUnobservable _ -> Nothing

secretWorkerCheckpointResult
  :: SecretWorkerDurableCheckpoint -> Maybe SecretWorkerDurableResult
secretWorkerCheckpointResult checkpoint = case checkpoint of
  InternalNoWorkerReceipt _ -> Nothing
  InternalWorkerAuthoritativelyRecovered _ result -> Just result
  InternalReceiptCaptured captured -> Just (capturedSecretWorkerResult captured)
  InternalSessionRevoked revoked ->
    Just (capturedSecretWorkerResult (revokedCaptured revoked))
  InternalWorkerExited exited ->
    Just (capturedSecretWorkerResult (exitedCaptured exited))
  InternalWorkerDeleted deleted ->
    Just (capturedSecretWorkerResult (deletedCaptured deleted))
  InternalWorkerAbsent absent ->
    Just
      ( capturedSecretWorkerResult
          (deletedCaptured (internalAbsentDeleted absent))
      )
  InternalWorkerCheckpointUnobservable _ -> Nothing

data SecretWorkerRecoveryRefusal
  = SecretWorkerRecoveryCheckpointUnobservable !Text
  | SecretWorkerRecoveryRequestMismatch
  deriving stock (Eq, Show)

-- | Recovery never resumes a pre-receipt ingress.  Restart, disconnect, or
-- Pod loss destroys it and requires a fresh worker/prompt for the same durable
-- request.  Invalid attestation, fence loss, and expiry destroy it and refuse.
-- Once a typed receipt exists, recovery resumes only the mandatory cleanup
-- sequence and completes solely after Pod absence is read back.
data SecretWorkerRecoveryDecision
  = SecretWorkerRecoveryDestroyAndReprompt
      !SecretFreeWorkerRequest
      !SecretWorkerInterruption
  | SecretWorkerRecoveryDestroyAndRefuse !SecretWorkerInterruption
  | SecretWorkerRecoveryRevokeSession !SecretWorkerReceipt
  | SecretWorkerRecoveryAwaitExit !SecretWorkerReceipt
  | SecretWorkerRecoveryDeletePod !SecretWorkerReceipt
  | SecretWorkerRecoveryObserveAbsence !SecretWorkerReceipt
  | SecretWorkerRecoveryComplete !SecretWorkerReceipt
  | SecretWorkerRecoveryAuthoritativeComplete !SecretWorkerDurableResult
  | SecretWorkerRecoveryRefused !SecretWorkerRecoveryRefusal
  deriving stock (Eq, Show)

decideSecretWorkerRecovery
  :: SecretFreeWorkerRequest
  -> SecretWorkerInterruption
  -> SecretWorkerDurableCheckpoint
  -> SecretWorkerRecoveryDecision
decideSecretWorkerRecovery expectedRequest interruption checkpoint =
  case checkpoint of
    InternalWorkerCheckpointUnobservable detail ->
      SecretWorkerRecoveryRefused
        (SecretWorkerRecoveryCheckpointUnobservable detail)
    InternalNoWorkerReceipt observedRequest
      | observedRequest /= expectedRequest -> requestMismatch
      | interruptionRequiresRefusal interruption ->
          SecretWorkerRecoveryDestroyAndRefuse interruption
      | otherwise ->
          SecretWorkerRecoveryDestroyAndReprompt observedRequest interruption
    InternalWorkerAuthoritativelyRecovered observedRequest result
      | observedRequest == expectedRequest ->
          SecretWorkerRecoveryAuthoritativeComplete result
      | otherwise -> requestMismatch
    InternalReceiptCaptured captured ->
      continueWithReceipt
        captured
        (SecretWorkerRecoveryRevokeSession . capturedSecretWorkerReceipt)
    InternalSessionRevoked revoked ->
      let captured = internalRevokedCaptured revoked
       in continueWithReceipt
            captured
            (SecretWorkerRecoveryAwaitExit . capturedSecretWorkerReceipt)
    InternalWorkerExited exited ->
      let captured = revokedCaptured (internalExitedRevoked exited)
       in continueWithReceipt
            captured
            (SecretWorkerRecoveryDeletePod . capturedSecretWorkerReceipt)
    InternalWorkerDeleted deleted ->
      let captured = exitedCaptured (internalDeletedExited deleted)
       in continueWithReceipt
            captured
            (SecretWorkerRecoveryObserveAbsence . capturedSecretWorkerReceipt)
    InternalWorkerAbsent absent ->
      let captured = deletedCaptured (internalAbsentDeleted absent)
       in continueWithReceipt
            captured
            (SecretWorkerRecoveryComplete . capturedSecretWorkerReceipt)
 where
  requestMismatch =
    SecretWorkerRecoveryRefused SecretWorkerRecoveryRequestMismatch

  continueWithReceipt captured next
    | receiptMatchesRequest expectedRequest (capturedSecretWorkerReceipt captured) =
        next captured
    | otherwise = requestMismatch

workerOperationEffect :: SecretWorkerOperation -> BootstrapVaultEffect
workerOperationEffect operation = case operation of
  SecretWorkerPrepareInitialization -> BootstrapVaultInitialize
  SecretWorkerResumeInitialization -> BootstrapVaultInitialize
  SecretWorkerInitialize -> BootstrapVaultInitialize
  SecretWorkerFinalizeInitialization -> BootstrapVaultInitialize
  SecretWorkerUnseal -> BootstrapVaultSubmitUnsealShare
  SecretWorkerRotateUnlockBundle -> BootstrapVaultRotateUnlockBundle
  SecretWorkerRotateTransitKey -> BootstrapVaultRotateTransitKey

outcomeMatchesOperation :: SecretWorkerOperation -> SecretWorkerOutcome -> Bool
outcomeMatchesOperation operation outcome = case (operation, outcome) of
  (SecretWorkerPrepareInitialization, SecretWorkerInitialized) -> True
  (SecretWorkerResumeInitialization, SecretWorkerInitialized) -> True
  (SecretWorkerInitialize, SecretWorkerInitialized) -> True
  (SecretWorkerFinalizeInitialization, SecretWorkerInitialized) -> True
  (SecretWorkerUnseal, SecretWorkerUnsealed) -> True
  (SecretWorkerRotateUnlockBundle, SecretWorkerUnlockBundleRotated) -> True
  (SecretWorkerRotateTransitKey, SecretWorkerTransitKeyRotated) -> True
  _ -> False

interruptionRequiresRefusal :: SecretWorkerInterruption -> Bool
interruptionRequiresRefusal interruption = case interruption of
  SecretWorkerControllerRestarted -> False
  SecretWorkerClientDisconnected -> False
  SecretWorkerPodLost -> False
  SecretWorkerAttestationInvalidated -> True
  SecretWorkerFenceLost -> True
  SecretWorkerDeadlineElapsed -> True

receiptMatchesRequest
  :: SecretFreeWorkerRequest -> SecretWorkerReceipt -> Bool
receiptMatchesRequest request receipt =
  secretWorkerReceiptOperation receipt == secretWorkerRequestOperation request
    && secretWorkerReceiptPodUid receipt == secretWorkerRequestPodUid request
    && secretWorkerReceiptRequestDigest receipt == secretWorkerRequestDigest request
    && secretWorkerReceiptStorageGeneration receipt
      == secretWorkerRequestStorageGeneration request
    && secretWorkerReceiptFenceGeneration receipt
      == secretWorkerRequestFenceGeneration request

capturedBinding :: ReceiptCapturedSecretWorker -> SecretWorkerCleanupBinding
capturedBinding = secretWorkerCleanupBinding . capturedSecretWorkerReceipt

revokedCaptured :: SessionRevokedSecretWorker -> ReceiptCapturedSecretWorker
revokedCaptured = internalRevokedCaptured

revokedBinding :: SessionRevokedSecretWorker -> SecretWorkerCleanupBinding
revokedBinding = capturedBinding . revokedCaptured

exitedCaptured :: ExitedSecretWorker -> ReceiptCapturedSecretWorker
exitedCaptured = revokedCaptured . internalExitedRevoked

exitedBinding :: ExitedSecretWorker -> SecretWorkerCleanupBinding
exitedBinding = capturedBinding . exitedCaptured

deletedCaptured :: DeletedSecretWorker -> ReceiptCapturedSecretWorker
deletedCaptured = exitedCaptured . internalDeletedExited

deletedBinding :: DeletedSecretWorker -> SecretWorkerCleanupBinding
deletedBinding = capturedBinding . deletedCaptured

requireCleanupBinding
  :: SecretWorkerCleanupBinding
  -> SecretWorkerCleanupBinding
  -> Either SecretWorkerCleanupRefusal ()
requireCleanupBinding expected observed
  | observed == expected = Right ()
  | otherwise = Left (SecretWorkerCleanupBindingMismatch expected observed)

requireEqual :: (Eq value) => (value -> value -> refusal) -> value -> value -> Either refusal ()
requireEqual mismatch expected observed
  | observed == expected = Right ()
  | otherwise = Left (mismatch expected observed)

boundedIdentity
  :: String -> Int -> Text -> Either SecretWorkerValueError Text
boundedIdentity label maximumLength raw
  | Text.null value = Left (SecretWorkerIdentityEmpty label)
  | Text.length value > maximumLength =
      Left
        (SecretWorkerIdentityTooLong label maximumLength (Text.length value))
  | Text.all allowed value = Right value
  | otherwise = Left (SecretWorkerIdentityForbiddenCharacter label)
 where
  value = Text.strip raw
  allowed character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("-._" :: String)
