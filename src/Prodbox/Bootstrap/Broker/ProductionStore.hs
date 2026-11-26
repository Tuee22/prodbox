{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Production fixed-coordinate MinIO interpreter for Bootstrap Broker state.
-- Logical versions live inside a bounded canonical CBOR envelope; S3 ETags are
-- used only as physical compare-and-swap witnesses.  A successful write is not
-- reported until the exact logical value has been read back.
module Prodbox.Bootstrap.Broker.ProductionStore
  ( productionBootstrapStoreBoundary
  , productionExistingBootstrapStoreBoundary
  , bootstrapStoreReady
  , maximumBootstrapStoreObjectBytes
  , ProductionSecretWorkerResult
  , productionSecretWorkerResultRequest
  , productionSecretWorkerResultReceipt
  , productionSecretWorkerResultValue
  , productionSecretWorkerReceiptDigest
  , publishProductionSecretWorkerResult
  , observeProductionSecretWorkerResult
  , observeProductionSecretWorkerResultForRecovery
  , ProductionTransitRotationJournal (..)
  , FreshTransitRotationClaim
  , DispatchedTransitRotation
  , ConfirmedTransitRotation
  , dispatchProductionTransitRotation
  , confirmProductionTransitRotation
  , ProductionTransitRotationBoundary (..)
  , productionTransitRotationBoundary
  , observeProductionTransitRotationJournal
  , observeProductionTransitRotationJournalWithinPermit
  , planProductionTransitRotation
  , completeProductionTransitRotation

    -- * Durable-value validity (Sprint 2.45)
  , validArtifactDigest
  , validRootInitBinding
  , validChildCustodyBinding
  , validChildEncryptedReceipt
  , validFinalUnlockBundle
  , validUnlockShareThreshold
  , validSecretWorkerCheckpoint
  , rootInitReadMatches
  , rootInitResetReadMatches
  , rootInitJournalMutationGeneration
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (evaluate)
import Control.Monad (void)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Custody
  ( ChildCustodyState (..)
  , ChildRecoveryState (..)
  , RootInitPhase (..)
  , RootInitState (..)
  , childCustodyInvariantViolations
  , childRecoveryInvariantViolations
  , rootInitInvariantViolations
  )
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceCasPlan
  , BootstrapFenceCasResult (..)
  , BootstrapFenceRetireCasResult (..)
  , BootstrapFenceRetirePlan
  , BootstrapFenceStoreObservation (..)
  , BootstrapSessionFence
  , BootstrapStoreMutation (..)
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffect (BootstrapVaultRotateTransitKey)
  , BootstrapVaultEffectPermit
  , bootstrapFenceActionDigest
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapFenceOperationDeadline
  , bootstrapFenceOwnerNonce
  , bootstrapFenceRequestDigest
  , bootstrapFenceStorageGeneration
  , fenceCasDeadline
  , fenceCasExpectedGenerationFloor
  , fenceCasProposedFence
  , fenceRetireDeadline
  , fenceRetireExpectedFence
  , fenceRetireVacantGenerationFloor
  , storeMutationPermitActionDigest
  , storeMutationPermitDeadline
  , storeMutationPermitFenceGeneration
  , storeMutationPermitMutation
  , storeMutationPermitOperationDeadline
  , storeMutationPermitOwnerNonce
  , storeMutationPermitRequestDigest
  , storeMutationPermitStorageGeneration
  , vaultEffectPermitActionDigest
  , vaultEffectPermitDeadline
  , vaultEffectPermitEffect
  , vaultEffectPermitFenceGeneration
  , vaultEffectPermitOperationDeadline
  , vaultEffectPermitOwnerNonce
  , vaultEffectPermitRequestDigest
  , vaultEffectPermitStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Model
  ( PostUnsealHandoffPhase (..)
  , PostUnsealHandoffState (..)
  , RootSessionState (..)
  , rootSessionInvariantViolations
  , rootSessionStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Request (RequestDigest)
import Prodbox.Bootstrap.Broker.SecretWorker
  ( RawSecretWorkerReceipt (..)
  , SecretFreeWorkerRequest
  , SecretWorkerDurableCheckpoint
  , SecretWorkerDurableResult
  , SecretWorkerOperation (..)
  , SecretWorkerOutcome (..)
  , durableWorkerSessionAccessor
  , secretWorkerCheckpointInvariantViolations
  , secretWorkerDurableResultOperation
  , secretWorkerRequestActionDigest
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOperation
  , secretWorkerRequestOperationDeadline
  , secretWorkerRequestOwnerNonce
  , secretWorkerRequestPodUid
  , secretWorkerRequestSessionAccessor
  , secretWorkerRequestSessionId
  , secretWorkerRequestStorageGeneration
  , workerSessionNotIssued
  )
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , StoreBoundaryError (..)
  , StoreReadBack (..)
  , StoreWriteResult (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , ChildCustodyBinding (..)
  , ChildEncryptedReceipt (..)
  , ChildRecoveryDelivery (..)
  , EncryptedInitResponseReceipt
  , FinalUnlockBundle
  , PreparedInitEnvelope
  , RootInitBinding (..)
  , StoreVersion (..)
  , VaultStorageGeneration
  , childCustodyStorageGeneration
  , childRecoveryDeliveryBinding
  , encryptedResponseBinding
  , encryptedResponseReceiptDigest
  , encryptedResponseShares
  , finalUnlockBundleBinding
  , finalUnlockBundleDigest
  , finalUnlockBundleShareCount
  , finalUnlockBundleThreshold
  , mkArtifactDigest
  , mkBootstrapTransactionId
  , mkDeliveryNonce
  , mkVaultStorageGeneration
  , postUnsealHandoffGeneration
  , preparedInitBinding
  , preparedInitEnvelopeDigest
  , preparedInitPristineObservationDigest
  , pristineStorageBinding
  , renderArtifactDigest
  , renderBootstrapTransactionId
  , renderDeliveryNonce
  , renderVaultStorageGeneration
  , resetAmbiguousBinding
  , resetReplacementPristine
  , rootInitStorageGeneration
  )
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , RemainingDuration (..)
  , deadlineObservation
  )
import Prodbox.ControlPlane.Interpreter
  ( DeadlineEffectResult (..)
  , observeDeadlineEffect
  , observeDeadlineEffectWithin
  , realMonotonicNow
  )
import Prodbox.Http.Client (HttpConfig (..), defaultHttpConfig)
import Prodbox.Minio.ObjectStoreNative qualified as Native
import Prodbox.Minio.ObjectStoreTypes
  ( ConditionalDeleteResult (..)
  , ConditionalPutResult (..)
  , ObjectStoreConfig (..)
  , ObjectVersion
  , VersionedObject (..)
  )
import Prodbox.Minio.RootCredential
  ( minioRootPassword
  , minioRootUser
  )
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile (bootstrapBrokerRotatableTransitKeys)
import System.Timeout (timeout)

maximumBootstrapStoreObjectBytes :: Int
maximumBootstrapStoreObjectBytes = 32 * 1024 * 1024

data StoredEnvelope value = StoredEnvelope
  { storedEnvelopeSchema :: !Natural
  , storedEnvelopeVersion :: !Natural
  , storedEnvelopeValue :: !value
  }
  deriving (Eq, Show, Generic, Serialise)

data PhysicalRead value
  = PhysicalAbsent
  | PhysicalPresent !ObjectVersion !StoreVersion !ArtifactDigest !value

-- | Immutable, fixed-key handoff from the attested one-shot Pod to the
-- controller.  It contains only the already-closed durable result family and
-- the secret-free receipt/request binding; prompt bytes and recovered
-- plaintext are structurally absent.
data ProductionSecretWorkerResult = ProductionSecretWorkerResult
  { productionSecretWorkerResultRequest :: !SecretFreeWorkerRequest
  , productionSecretWorkerResultReceipt :: !RawSecretWorkerReceipt
  , productionSecretWorkerResultValue :: !SecretWorkerDurableResult
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Single fixed-coordinate write-ahead journal for Transit rotation. Legacy
-- planned and applied values remain decodable but do not establish settlement.
-- Only a freshly written claim authorizes dispatch; a claim observed later
-- remains unresolved even if the Vault version has changed.
data ProductionTransitRotationJournal
  = ProductionTransitRotationPlanned
      { transitRotationRequestDigest :: !RequestDigest
      , transitRotationStorageGeneration :: !VaultStorageGeneration
      , transitRotationKeyName :: !Text
      , transitRotationBeforeVersion :: !Natural
      }
  | ProductionTransitRotationApplied
      { transitRotationRequestDigest :: !RequestDigest
      , transitRotationStorageGeneration :: !VaultStorageGeneration
      , transitRotationKeyName :: !Text
      , transitRotationBeforeVersion :: !Natural
      , transitRotationAfterVersion :: !Natural
      }
  | ProductionTransitRotationClaimed
      { transitRotationRequestDigest :: !RequestDigest
      , transitRotationStorageGeneration :: !VaultStorageGeneration
      , transitRotationKeyName :: !Text
      , transitRotationBeforeVersion :: !Natural
      }
  | ProductionTransitRotationCompleted
      { transitRotationRequestDigest :: !RequestDigest
      , transitRotationStorageGeneration :: !VaultStorageGeneration
      , transitRotationKeyName :: !Text
      , transitRotationBeforeVersion :: !Natural
      , transitRotationAfterVersion :: !Natural
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- These values are process-local: neither a decoded journal nor a copied
-- request can create a dispatch or completion witness. The shared latch
-- prevents two aliases of one fresh claim from issuing two POSTs.
data FreshTransitRotationClaim
  = FreshTransitRotationClaim
      !SecretFreeWorkerRequest
      !ProductionTransitRotationJournal
      !Settings.BootstrapBrokerSettings
      !(IORef Bool)

newtype DispatchedTransitRotation = DispatchedTransitRotation FreshTransitRotationClaim
newtype ConfirmedTransitRotation = ConfirmedTransitRotation FreshTransitRotationClaim

-- | The two independently authorized mutations of the fixed-coordinate
-- Transit-rotation write-ahead journal.  Keeping them in an explicit record
-- lets the Broker's production-capability registry prove that both the
-- pre-effect plan and the post-effect completion arms are installed.  The
-- observation used for response-loss recovery remains internal to each arm,
-- so callers cannot replace it with a weaker observation.
data ProductionTransitRotationBoundary m = ProductionTransitRotationBoundary
  { planTransitRotation
      :: BootstrapStoreMutationPermit
      -> SecretFreeWorkerRequest
      -> Text
      -> Natural
      -> m (Either StoreBoundaryError FreshTransitRotationClaim)
  , completeTransitRotation
      :: BootstrapStoreMutationPermit
      -> ConfirmedTransitRotation
      -> m (Either StoreBoundaryError ProductionTransitRotationJournal)
  }

productionTransitRotationBoundary
  :: Settings.BootstrapBrokerSettings
  -> ProductionTransitRotationBoundary IO
productionTransitRotationBoundary settings =
  ProductionTransitRotationBoundary
    { planTransitRotation = planProductionTransitRotation settings
    , completeTransitRotation = completeProductionTransitRotation
    }

observeProductionTransitRotationJournal
  :: Settings.BootstrapBrokerSettings
  -> IO
       ( Either
           StoreBoundaryError
           (StoreReadBack ProductionTransitRotationJournal)
       )
observeProductionTransitRotationJournal settings =
  readValue
    (objectStoreConfig settings)
    (transitRotationJournalKey settings)
    validTransitRotationJournal

planProductionTransitRotation
  :: Settings.BootstrapBrokerSettings
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> Text
  -> Natural
  -> IO (Either StoreBoundaryError FreshTransitRotationClaim)
planProductionTransitRotation settings permit request keyName before =
  case requireTransitPermit BootstrapStorePlanTransitRotation permit request of
    Left failure -> pure (Left failure)
    Right ()
      | keyName `notElem` bootstrapBrokerRotatableTransitKeys -> pure (Left BootstrapStoreBindingMismatch)
    Right () | not (validTransitRotationJournal proposed) -> pure (Left BootstrapStoreBindingMismatch)
    Right () -> do
      observed <- observeTransitJournalWithinPermit settings permit
      written <- case observed of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent ->
          freshJournalWrite proposed
            <$> createValueBefore
              (storeMutationPermitDeadline permit)
              config
              journalKey
              validTransitRotationJournal
              proposed
        Right (StoreObjectPresent version _ current@ProductionTransitRotationCompleted {})
          | transitRotationRequestDigest current /= secretWorkerRequestDigest request ->
              freshJournalWrite proposed
                <$> casValueBefore
                  (storeMutationPermitDeadline permit)
                  config
                  journalKey
                  validTransitRotationJournal
                  version
                  proposed
        Right (StoreObjectPresent {}) -> pure (Left BootstrapStoreVersionConflict)
      case written of
        Left failure -> pure (Left failure)
        Right journal -> do
          latch <- newIORef False
          pure
            ( Right
                ( FreshTransitRotationClaim
                    request
                    journal
                    settings
                    latch
                )
            )
 where
  proposed =
    ProductionTransitRotationClaimed
      (secretWorkerRequestDigest request)
      (secretWorkerRequestStorageGeneration request)
      keyName
      before
  config = objectStoreConfig settings
  journalKey = transitRotationJournalKey settings

dispatchProductionTransitRotation
  :: BootstrapVaultEffectPermit
  -> FreshTransitRotationClaim
  -> Vault.VaultToken
  -> IO (Either StoreBoundaryError DispatchedTransitRotation)
dispatchProductionTransitRotation permit claim@(FreshTransitRotationClaim request journal settings latch) token =
  case requireTransitEffectPermit permit request of
    Left failure -> pure (Left failure)
    Right () -> do
      alreadyUsed <- atomicModifyIORef' latch (True,)
      if alreadyUsed
        then pure (Left BootstrapStoreVersionConflict)
        else do
          result <- transitVaultCallWithinPermit permit $ \config ->
            either (const (Left BootstrapStoreUnavailable)) Right
              <$> Vault.vaultRotateTransitKeyWith
                config
                (Vault.VaultAddress (Settings.brokerVaultAddress settings))
                token
                (transitRotationKeyName journal)
          pure (DispatchedTransitRotation claim <$ result)

confirmProductionTransitRotation
  :: BootstrapVaultEffectPermit
  -> DispatchedTransitRotation
  -> Vault.VaultToken
  -> IO (Either StoreBoundaryError ConfirmedTransitRotation)
confirmProductionTransitRotation permit (DispatchedTransitRotation claim@(FreshTransitRotationClaim request journal settings _)) token =
  case requireTransitEffectPermit permit request of
    Left failure -> pure (Left failure)
    Right () -> do
      result <- transitVaultCallWithinPermit permit $ \config -> do
        observed <-
          Vault.vaultReadTransitKeyWith
            config
            (Vault.VaultAddress (Settings.brokerVaultAddress settings))
            token
            (transitRotationKeyName journal)
        pure $ case observed of
          Right current
            | Vault.transitKeyName current == transitRotationKeyName journal
                && Vault.transitKeyLatestVersion current == transitRotationBeforeVersion journal + 1 ->
                Right ()
          _ -> Left BootstrapStoreReadBackMismatch
      pure (ConfirmedTransitRotation claim <$ result)

-- Timeouts leave an issued mutation unresolved; they never mint a witness.
transitVaultCallWithinPermit
  :: BootstrapVaultEffectPermit
  -> (HttpConfig -> IO (Either StoreBoundaryError value))
  -> IO (Either StoreBoundaryError value)
transitVaultCallWithinPermit permit action = do
  now <- realMonotonicNow
  case deadlineObservation now (vaultEffectPermitDeadline permit) of
    DeadlineExpired -> pure (Left BootstrapStoreUnavailable)
    DeadlineOpen (RemainingDuration remaining) -> do
      let timeoutMicros = fromIntegral (min remaining (fromIntegral (httpRequestTimeoutMicros defaultHttpConfig)))
          config = defaultHttpConfig {httpRequestTimeoutMicros = timeoutMicros}
      observed <-
        observeDeadlineEffect realMonotonicNow (vaultEffectPermitDeadline permit) $
          timeout timeoutMicros (action config >>= evaluate)
      pure $ case observed of
        DeadlineEffectCompleted _ (Just result) -> result
        DeadlineEffectNotStarted -> Left BootstrapStoreUnavailable
        DeadlineEffectCompletedLate _ -> Left BootstrapStoreUnavailable
        DeadlineEffectCompleted _ Nothing -> Left BootstrapStoreUnavailable

requireTransitEffectPermit
  :: BootstrapVaultEffectPermit
  -> SecretFreeWorkerRequest
  -> Either StoreBoundaryError ()
requireTransitEffectPermit permit request
  | vaultEffectPermitEffect permit /= BootstrapVaultRotateTransitKey =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitFenceGeneration permit /= secretWorkerRequestFenceGeneration request =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitOwnerNonce permit /= secretWorkerRequestOwnerNonce request =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitActionDigest permit /= secretWorkerRequestActionDigest request =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitRequestDigest permit /= secretWorkerRequestDigest request =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitStorageGeneration permit /= secretWorkerRequestStorageGeneration request =
      Left BootstrapStoreBindingMismatch
  | vaultEffectPermitOperationDeadline permit /= secretWorkerRequestOperationDeadline request =
      Left BootstrapStoreBindingMismatch
  | secretWorkerRequestOperation request /= SecretWorkerRotateTransitKey =
      Left BootstrapStoreBindingMismatch
  | otherwise = Right ()

completeProductionTransitRotation
  :: BootstrapStoreMutationPermit
  -> ConfirmedTransitRotation
  -> IO (Either StoreBoundaryError ProductionTransitRotationJournal)
completeProductionTransitRotation permit (ConfirmedTransitRotation (FreshTransitRotationClaim request journal settings _)) =
  case requireTransitPermit BootstrapStoreCompleteTransitRotation permit request of
    Left failure -> pure (Left failure)
    Right () | not (validTransitRotationJournal proposed) -> pure (Left BootstrapStoreBindingMismatch)
    Right () -> do
      observed <- observeTransitJournalWithinPermit settings permit
      case observed of
        Left failure -> pure (Left failure)
        Right (StoreObjectPresent _ _ current)
          | current == proposed -> pure (Right current)
        Right (StoreObjectPresent version _ current@ProductionTransitRotationClaimed {})
          | current == journal ->
              exactJournalWrite proposed
                <$> casValueBefore
                  (storeMutationPermitDeadline permit)
                  config
                  journalKey
                  validTransitRotationJournal
                  version
                  proposed
        _ -> pure (Left BootstrapStoreBindingMismatch)
 where
  proposed =
    ProductionTransitRotationCompleted
      (secretWorkerRequestDigest request)
      (secretWorkerRequestStorageGeneration request)
      (transitRotationKeyName journal)
      (transitRotationBeforeVersion journal)
      (transitRotationBeforeVersion journal + 1)
  config = objectStoreConfig settings
  journalKey = transitRotationJournalKey settings

transitRotationJournalKey :: Settings.BootstrapBrokerSettings -> Text
transitRotationJournalKey settings =
  Settings.transitRotationJournalKeyFromCheckpoint $
    Settings.secretWorkerCheckpointKey
      (Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings))

-- | A journal read that outlives the permit cannot authorize a following
-- write. Subsequent store preflight and the conditional PUT still need their
-- own deadline and in-flight settlement guarantees.
observeTransitJournalWithinPermit
  :: Settings.BootstrapBrokerSettings
  -> BootstrapStoreMutationPermit
  -> IO (Either StoreBoundaryError (StoreReadBack ProductionTransitRotationJournal))
observeTransitJournalWithinPermit settings permit =
  storeResultBefore
    (storeMutationPermitDeadline permit)
    (observeProductionTransitRotationJournal settings)

-- | The worker's pre-plan observation uses the same request-bound permit as
-- planning, but does not itself authorize a journal mutation.
observeProductionTransitRotationJournalWithinPermit
  :: Settings.BootstrapBrokerSettings
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> IO (Either StoreBoundaryError (StoreReadBack ProductionTransitRotationJournal))
observeProductionTransitRotationJournalWithinPermit settings permit request =
  case requireTransitPermit BootstrapStorePlanTransitRotation permit request of
    Left failure -> pure (Left failure)
    Right () -> observeTransitJournalWithinPermit settings permit

validTransitRotationJournal :: ProductionTransitRotationJournal -> Bool
validTransitRotationJournal journal =
  not (Text.null (transitRotationKeyName journal))
    && Text.length (transitRotationKeyName journal) <= 256
    && case journal of
      ProductionTransitRotationPlanned {} -> True
      ProductionTransitRotationApplied {transitRotationBeforeVersion, transitRotationAfterVersion} ->
        transitRotationAfterVersion == transitRotationBeforeVersion + 1
      ProductionTransitRotationClaimed {} -> True
      ProductionTransitRotationCompleted {transitRotationBeforeVersion, transitRotationAfterVersion} ->
        transitRotationAfterVersion == transitRotationBeforeVersion + 1

requireTransitPermit
  :: BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> Either StoreBoundaryError ()
requireTransitPermit mutation permit request = do
  requireWorkerPermit mutation permit request
  if secretWorkerRequestOperation request == SecretWorkerRotateTransitKey
    then Right ()
    else Left BootstrapStoreBindingMismatch

requireWorkerPermit
  :: BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> Either StoreBoundaryError ()
requireWorkerPermit mutation permit request
  | storeMutationPermitMutation permit /= mutation = Left BootstrapStoreBindingMismatch
  | storeMutationPermitFenceGeneration permit /= secretWorkerRequestFenceGeneration request =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitOwnerNonce permit /= secretWorkerRequestOwnerNonce request =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitActionDigest permit /= secretWorkerRequestActionDigest request =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitStorageGeneration permit
      /= secretWorkerRequestStorageGeneration request =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitRequestDigest permit
      /= secretWorkerRequestDigest request =
      Left BootstrapStoreBindingMismatch
  | secretWorkerRequestSessionAccessor request /= workerSessionNotIssued =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitOperationDeadline permit /= secretWorkerRequestOperationDeadline request =
      Left BootstrapStoreBindingMismatch
  | otherwise = Right ()

exactJournalWrite
  :: ProductionTransitRotationJournal
  -> Either StoreBoundaryError (StoreWriteResult ProductionTransitRotationJournal)
  -> Either StoreBoundaryError ProductionTransitRotationJournal
exactJournalWrite expected written = do
  result <- written
  case result of
    StoreWriteApplied _ _ actual | actual == expected -> Right actual
    StoreWriteConflict (StoreObjectPresent _ _ actual) | actual == expected -> Right actual
    StoreWriteConflict StoreObjectAbsent -> Left BootstrapStoreVersionConflict
    _ -> Left BootstrapStoreReadBackMismatch

-- A matching conflict proves only that another writer's claim exists. It
-- cannot confer that writer's one-shot right to dispatch the Vault mutation.
freshJournalWrite
  :: ProductionTransitRotationJournal
  -> Either StoreBoundaryError (StoreWriteResult ProductionTransitRotationJournal)
  -> Either StoreBoundaryError ProductionTransitRotationJournal
freshJournalWrite expected written = do
  result <- written
  case result of
    StoreWriteApplied _ _ actual | actual == expected -> Right actual
    StoreWriteConflict _ -> Left BootstrapStoreVersionConflict
    _ -> Left BootstrapStoreReadBackMismatch

-- | Canonical request/result digest placed in the durable worker receipt.
-- Keeping this constructor beside the result validator prevents a worker and
-- controller from silently accepting different receipt preimages.
productionSecretWorkerReceiptDigest
  :: SecretFreeWorkerRequest
  -> SecretWorkerDurableResult
  -> Either StoreBoundaryError ArtifactDigest
productionSecretWorkerReceiptDigest request result =
  digestBytes (LazyByteString.toStrict (serialise (request, result)))

publishProductionSecretWorkerResult
  :: Settings.BootstrapBrokerSettings
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> RawSecretWorkerReceipt
  -> SecretWorkerDurableResult
  -> IO (Either StoreBoundaryError ProductionSecretWorkerResult)
publishProductionSecretWorkerResult settings permit request receipt result =
  let value = ProductionSecretWorkerResult request receipt result
      config = objectStoreConfig settings
      key = secretWorkerResultKey settings
      deadline = storeMutationPermitDeadline permit
   in case requireWorkerPermit BootstrapStorePublishSecretWorkerResult permit request of
        Left failure -> pure (Left failure)
        Right () ->
          if validWorkerResult value
            then storeResultBefore deadline $ do
              written <- createValueBefore deadline config key validWorkerResult value
              case written of
                Left failure -> pure (Left failure)
                Right (StoreWriteApplied _ _ actual) -> pure (Right actual)
                Right (StoreWriteConflict (StoreObjectPresent version _ actual))
                  | actual == value -> pure (Right actual)
                  | productionSecretWorkerResultRequest actual == request ->
                      pure (Left BootstrapStoreVersionConflict)
                  | secretWorkerRequestFenceGeneration (productionSecretWorkerResultRequest actual)
                      > secretWorkerRequestFenceGeneration request ->
                      pure (Left BootstrapStoreVersionConflict)
                  | otherwise -> do
                      replaced <- casValueBefore deadline config key validWorkerResult version value
                      pure $ case replaced of
                        Left failure -> Left failure
                        Right (StoreWriteApplied _ _ observed) | observed == value -> Right observed
                        Right (StoreWriteConflict (StoreObjectPresent _ _ observed))
                          | observed == value -> Right observed
                        Right _ -> Left BootstrapStoreVersionConflict
                Right _ -> pure (Left BootstrapStoreVersionConflict)
            else pure (Left BootstrapStoreBindingMismatch)

observeProductionSecretWorkerResult
  :: Settings.BootstrapBrokerSettings
  -> SecretFreeWorkerRequest
  -> IO (Either StoreBoundaryError (Maybe ProductionSecretWorkerResult))
observeProductionSecretWorkerResult settings request = do
  observed <-
    readValue
      (objectStoreConfig settings)
      (secretWorkerResultKey settings)
      validWorkerResult
  pure $ case observed of
    Left failure -> Left failure
    Right StoreObjectAbsent -> Right Nothing
    Right (StoreObjectPresent _ _ value)
      | productionSecretWorkerResultRequest value == request -> Right (Just value)
      -- The coordinate is deliberately fixed.  A result for the preceding
      -- request is therefore absence for this request; the newly authorized
      -- worker will CAS-replace it when its result is durable.
      | otherwise -> Right Nothing

-- | An absent shared result does not prove that the exact worker has settled.
-- Bound the whole local read and retain that absence as unavailable.
observeProductionSecretWorkerResultForRecovery
  :: Deadline
  -> Settings.BootstrapBrokerSettings
  -> SecretFreeWorkerRequest
  -> IO (Either StoreBoundaryError SecretWorkerDurableResult)
observeProductionSecretWorkerResultForRecovery deadline settings request =
  storeResultBefore deadline $ do
    observed <- observeProductionSecretWorkerResult settings request
    case observed of
      Left failure -> pure (Left failure)
      Right Nothing -> pure (Left BootstrapStoreUnavailable)
      Right (Just result) -> Right <$> evaluate (productionSecretWorkerResultValue result)

secretWorkerResultKey :: Settings.BootstrapBrokerSettings -> Text
secretWorkerResultKey settings =
  Settings.secretWorkerResultKeyFromCheckpoint $
    Settings.secretWorkerCheckpointKey
      (Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings))

validWorkerResult :: ProductionSecretWorkerResult -> Bool
validWorkerResult value =
  let request = productionSecretWorkerResultRequest value
      receipt = productionSecretWorkerResultReceipt value
      result = productionSecretWorkerResultValue value
      operation = secretWorkerRequestOperation request
   in rawWorkerReceiptOperation receipt == operation
        && rawWorkerReceiptPodUid receipt == secretWorkerRequestPodUid request
        && rawWorkerReceiptSessionId receipt == secretWorkerRequestSessionId request
        && secretWorkerRequestSessionAccessor request == workerSessionNotIssued
        && rawWorkerReceiptSessionAccessor receipt
          == durableWorkerSessionAccessor result
        && rawWorkerReceiptRequestDigest receipt == secretWorkerRequestDigest request
        && rawWorkerReceiptStorageGeneration receipt
          == secretWorkerRequestStorageGeneration request
        && rawWorkerReceiptFenceGeneration receipt
          == secretWorkerRequestFenceGeneration request
        && secretWorkerDurableResultOperation result == operation
        && outcomeMatches operation (rawWorkerReceiptOutcome receipt)
        && productionSecretWorkerReceiptDigest request result
          == Right (rawWorkerReceiptDigest receipt)

outcomeMatches :: SecretWorkerOperation -> SecretWorkerOutcome -> Bool
outcomeMatches operation outcome = case operation of
  SecretWorkerPrepareInitialization -> outcome == SecretWorkerInitialized
  SecretWorkerResumeInitialization -> outcome == SecretWorkerInitialized
  SecretWorkerInitialize -> outcome == SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> outcome == SecretWorkerInitialized
  SecretWorkerUnseal -> outcome == SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> outcome == SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> outcome == SecretWorkerTransitKeyRotated
  SecretWorkerCompleteGeneratedRoot -> outcome == SecretWorkerGeneratedRootCompleted

productionBootstrapStoreBoundary
  :: Settings.BootstrapBrokerSettings
  -> IO (Either StoreBoundaryError (BootstrapStoreBoundary IO))
productionBootstrapStoreBoundary = openBootstrapStore InitializeGeneration

-- | A one-shot worker is admitted by an existing Broker fence and therefore
-- cannot create either its bucket or its retained generation.
productionExistingBootstrapStoreBoundary
  :: Settings.BootstrapBrokerSettings
  -> IO (Either StoreBoundaryError (BootstrapStoreBoundary IO))
productionExistingBootstrapStoreBoundary = openBootstrapStore RequireExistingGeneration

data BootstrapStoreOpenMode = InitializeGeneration | RequireExistingGeneration

openBootstrapStore
  :: BootstrapStoreOpenMode
  -> Settings.BootstrapBrokerSettings
  -> IO (Either StoreBoundaryError (BootstrapStoreBoundary IO))
openBootstrapStore mode settings = do
  let config = objectStoreConfig settings
      keys = Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings)
      generationKey = Settings.vaultStorageGenerationKey keys
  bucket <- case mode of
    InitializeGeneration -> Native.ensureObjectStoreBucket config
    -- This checks listability only; the returned page is not an absence proof.
    RequireExistingGeneration -> fmap void (Native.listKeys config)
  case bucket of
    -- The wire vocabulary is deliberately opaque -- a client learns only
    -- that the store is unavailable. The operator needs the cause, and
    -- collapsing it into the constructor destroyed it: a bring-up failure
    -- here reported `BootstrapStoreUnavailable` and nothing else, which is
    -- indistinguishable between a wrong endpoint, a rejected credential, an
    -- unroutable Service, and a bucket that exists but is not listable.
    Left detail -> do
      writeDiagnosticLine
        ( "Bootstrap Broker store unavailable at "
            ++ objectStoreEndpoint config
            ++ " (bucket "
            ++ objectStoreBucket config
            ++ "): "
            ++ detail
        )
      pure (Left BootstrapStoreUnavailable)
    Right () -> do
      generation <- case mode of
        InitializeGeneration ->
          observeOrCreateStorageGeneration config generationKey (Settings.bootstrapSessionFenceKey keys)
        RequireExistingGeneration -> observeExistingStorageGeneration config generationKey
      pure $ case generation of
        Left failure -> Left failure
        Right _ -> Right (boundary config keys generationKey)

bootstrapStoreReady :: Settings.BootstrapBrokerSettings -> IO Bool
bootstrapStoreReady settings = do
  let config = objectStoreConfig settings
      keys = Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings)
  listed <- Native.listKeys config
  generation <-
    readValue
      config
      (Settings.vaultStorageGenerationKey keys)
      validRootInitBinding
      :: IO (Either StoreBoundaryError (StoreReadBack RootInitBinding))
  pure $ case (listed, generation) of
    (Right _, Right (StoreObjectPresent {})) -> True
    _ -> False

objectStoreConfig :: Settings.BootstrapBrokerSettings -> ObjectStoreConfig
objectStoreConfig settings =
  ObjectStoreConfig
    { objectStoreEndpoint =
        Text.unpack
          (Settings.bootstrapStoreEndpoint (Settings.brokerBootstrapStore settings))
    , objectStoreBucket =
        Text.unpack
          (Settings.bootstrapStoreBucket (Settings.brokerBootstrapStore settings))
    , objectStoreAccessKey = minioRootUser
    , objectStoreSecretKey = minioRootPassword
    }

boundary
  :: ObjectStoreConfig
  -> Settings.BootstrapStorageKeys
  -> Text
  -> BootstrapStoreBoundary IO
boundary config keys generationKey =
  BootstrapStoreBoundary
    { observeBootstrapSessionFence = observeFence config fenceKey
    , casBootstrapSessionFence = casFence config fenceKey
    , casRetireBootstrapSessionFence = retireFence config fenceKey
    , releaseBootstrapSessionFence = releaseFence config fenceKey
    , observeVaultStorageGeneration =
        observeExistingStorageGeneration config generationKey
    , advanceVaultStorageGeneration = \permit expected replacement ->
        advanceStorageGeneration
          config
          generationKey
          permit
          expected
          replacement
    , readRootInitJournal = \binding ->
        readBound
          config
          rootInitJournalKey
          validRootInit
          (rootInitReadMatches binding)
    , readRootInitJournalForReset = \generation ->
        readBound
          config
          rootInitJournalKey
          validRootInit
          (rootInitResetReadMatches generation)
    , createRootInitJournal = \permit value ->
        createBound
          config
          rootInitJournalKey
          BootstrapStoreCreateRootInitJournal
          permit
          (rootInitStorageGeneration (rootInitStateBinding value))
          validRootInit
          value
    , casRootInitJournal = \permit version value ->
        casBound
          config
          rootInitJournalKey
          BootstrapStoreCasRootInitJournal
          permit
          (rootInitJournalMutationGeneration value)
          validRootInit
          version
          value
    , readPreparedInitEnvelope = \binding ->
        readBound config preparedKey validPreparedInit ((== binding) . preparedInitBinding)
    , createPreparedInitEnvelope = \permit value ->
        createBound
          config
          preparedKey
          BootstrapStoreCreatePreparedInitEnvelope
          permit
          (rootInitStorageGeneration (preparedInitBinding value))
          validPreparedInit
          value
    , deletePreparedInitEnvelope = \permit binding version ->
        deleteBound
          config
          preparedKey
          BootstrapStoreDeletePreparedInitEnvelope
          permit
          (rootInitStorageGeneration binding)
          version
          (Proxy :: Proxy PreparedInitEnvelope)
    , readEncryptedInitResponse = \binding ->
        readBound config responseKey validEncryptedResponse ((== binding) . encryptedResponseBinding)
    , createEncryptedInitResponse = \permit value ->
        createBound
          config
          responseKey
          BootstrapStoreCreateEncryptedInitResponse
          permit
          (rootInitStorageGeneration (encryptedResponseBinding value))
          validEncryptedResponse
          value
    , readFinalUnlockBundle = \binding ->
        readBound config bundleKey validFinalUnlockBundle ((== binding) . finalUnlockBundleBinding)
    , promoteFinalUnlockBundle = \permit response value -> storeResultBefore (storeMutationPermitDeadline permit) $ do
        observed <-
          readBound
            config
            responseKey
            validEncryptedResponse
            ((== encryptedResponseBinding response) . encryptedResponseBinding)
        case observed of
          Right (StoreObjectPresent _ _ actual)
            | actual == response ->
                createBound
                  config
                  bundleKey
                  BootstrapStorePromoteFinalUnlockBundle
                  permit
                  (rootInitStorageGeneration (finalUnlockBundleBinding value))
                  validFinalUnlockBundle
                  value
          Right _ -> pure (Left BootstrapStoreBindingMismatch)
          Left failure -> pure (Left failure)
    , casFinalUnlockBundle = \permit version value ->
        casBound
          config
          bundleKey
          BootstrapStoreCasFinalUnlockBundle
          permit
          (rootInitStorageGeneration (finalUnlockBundleBinding value))
          validFinalUnlockBundle
          version
          value
    , readRootSessionJournal = \generation ->
        readBound
          config
          rootSessionJournalKey
          validRootSession
          ((== generation) . rootSessionStorageGeneration . rootSessionStateBinding)
    , createRootSessionJournal = \permit value ->
        createBound
          config
          rootSessionJournalKey
          BootstrapStoreCreateRootSessionJournal
          permit
          (rootSessionStorageGeneration (rootSessionStateBinding value))
          validRootSession
          value
    , casRootSessionJournal = \permit version value ->
        casBound
          config
          rootSessionJournalKey
          BootstrapStoreCasRootSessionJournal
          permit
          (rootSessionStorageGeneration (rootSessionStateBinding value))
          validRootSession
          version
          value
    , readChildEncryptedReceipt = \binding ->
        readBound
          config
          childReceiptKey
          validChildEncryptedReceipt
          ((== binding) . childEncryptedReceiptBinding)
    , createChildEncryptedReceipt = \permit value ->
        createBound
          config
          childReceiptKey
          BootstrapStoreCreateChildEncryptedReceipt
          permit
          ( childCustodyStorageGeneration
              (childEncryptedReceiptBinding value)
          )
          validChildEncryptedReceipt
          value
    , deleteChildEncryptedReceipt = \permit binding version ->
        deleteBound
          config
          childReceiptKey
          BootstrapStoreDeleteChildEncryptedReceipt
          permit
          (childCustodyStorageGeneration binding)
          version
          (Proxy :: Proxy ChildEncryptedReceipt)
    , readChildCustodyJournal = \binding ->
        readBound
          config
          childCustodyJournalKey
          validChildCustody
          ((== binding) . childCustodyStateBinding)
    , createChildCustodyJournal = \permit value ->
        createBound
          config
          childCustodyJournalKey
          BootstrapStoreCreateChildCustodyJournal
          permit
          (childCustodyStorageGeneration (childCustodyStateBinding value))
          validChildCustody
          value
    , casChildCustodyJournal = \permit version value ->
        casBound
          config
          childCustodyJournalKey
          BootstrapStoreCasChildCustodyJournal
          permit
          (childCustodyStorageGeneration (childCustodyStateBinding value))
          validChildCustody
          version
          value
    , readChildRecoveryDelivery = \binding ->
        readBound
          config
          childRecoveryDeliveryKey
          validChildRecoveryDelivery
          ((== binding) . childRecoveryDeliveryBinding)
    , createChildRecoveryDelivery = \permit value ->
        createBound
          config
          childRecoveryDeliveryKey
          BootstrapStoreCreateChildRecoveryDelivery
          permit
          ( childCustodyStorageGeneration
              (childRecoveryDeliveryBinding value)
          )
          validChildRecoveryDelivery
          value
    , deleteChildRecoveryDelivery = \permit binding version ->
        deleteBound
          config
          childRecoveryDeliveryKey
          BootstrapStoreDeleteChildRecoveryDelivery
          permit
          (childCustodyStorageGeneration binding)
          version
          (Proxy :: Proxy ChildRecoveryDelivery)
    , readChildRecoveryJournal = \binding ->
        readBound
          config
          childRecoveryJournalKey
          validChildRecovery
          ((== binding) . childRecoveryStateBinding)
    , createChildRecoveryJournal = \permit value ->
        createBound
          config
          childRecoveryJournalKey
          BootstrapStoreCreateChildRecoveryJournal
          permit
          (childCustodyStorageGeneration (childRecoveryStateBinding value))
          validChildRecovery
          value
    , casChildRecoveryJournal = \permit version value ->
        casBound
          config
          childRecoveryJournalKey
          BootstrapStoreCasChildRecoveryJournal
          permit
          (childCustodyStorageGeneration (childRecoveryStateBinding value))
          validChildRecovery
          version
          value
    , readPostUnsealHandoff = \binding ->
        readBound
          config
          postUnsealHandoffKey
          validPostUnsealHandoff
          ( (== rootInitStorageGeneration binding)
              . postUnsealHandoffStateGeneration
          )
    , createPostUnsealHandoff = \permit value ->
        createBound
          config
          postUnsealHandoffKey
          BootstrapStoreCreatePostUnsealHandoff
          permit
          (postUnsealHandoffStateGeneration value)
          validPostUnsealHandoff
          value
    , casPostUnsealHandoff = \permit version value ->
        casBound
          config
          postUnsealHandoffKey
          BootstrapStoreCasPostUnsealHandoff
          permit
          (postUnsealHandoffStateGeneration value)
          validPostUnsealHandoff
          version
          value
    , readSecretWorkerCheckpoint =
        readValue config secretWorkerCheckpointKey validSecretWorkerCheckpoint
    , createSecretWorkerCheckpoint = \permit value ->
        createBound
          config
          secretWorkerCheckpointKey
          BootstrapStoreCreateSecretWorkerCheckpoint
          permit
          (storeMutationPermitStorageGeneration permit)
          validSecretWorkerCheckpoint
          value
    , casSecretWorkerCheckpoint = \permit version value ->
        casBound
          config
          secretWorkerCheckpointKey
          BootstrapStoreCasSecretWorkerCheckpoint
          permit
          (storeMutationPermitStorageGeneration permit)
          validSecretWorkerCheckpoint
          version
          value
    }
 where
  fenceKey = Settings.bootstrapSessionFenceKey keys
  preparedKey = Settings.preparedInitEnvelopeKey keys
  responseKey = Settings.encryptedInitResponseKey keys
  bundleKey = Settings.finalUnlockBundleKey keys
  childReceiptKey = Settings.childCustodyReceiptKey keys
  childRecoveryDeliveryKey = Settings.childRecoveryDeliveryKey keys
  rootInitJournalKey = Settings.rootInitJournalKey keys
  rootSessionJournalKey = Settings.rootSessionJournalKey keys
  childCustodyJournalKey = Settings.childCustodyJournalKey keys
  childRecoveryJournalKey = Settings.childRecoveryJournalKey keys
  postUnsealHandoffKey = Settings.postUnsealHandoffKey keys
  secretWorkerCheckpointKey = Settings.secretWorkerCheckpointKey keys

-- | Sprint 2.45: the validity predicate every durable read and CAS applies.
--
-- Until this sprint it was @validValue _ = True@, so any structurally-decodable
-- record was accepted as valid and @BootstrapStoreCorrupt@ was unreachable for
-- the seven payload types below. The fix is not per-payload invention: these
-- records are persisted and read back through @Serialise@ (CBOR), which
-- reconstructs each field positionally and __bypasses every smart constructor
-- the type is otherwise built through__. That is the conversion class
-- chaos_hardening_doctrine.md at 583443f, section 23
-- names, and the same seam Sprint 1.86 closed for Dhall decoding of the cluster
-- topology.
--
-- So the rule each predicate implements is one rule: __re-run the constructors
-- the decode bypassed__, plus the record's own cross-field arithmetic where it
-- has any. A digest that is not lower-hex SHA-256, an identifier that is empty
-- or over its length bound, or an unlock bundle whose threshold exceeds its
-- share count now reaches the caller as @BootstrapStoreCorrupt@ rather than as
-- a value the broker acts on.
validSmartConstructedText
  :: (value -> Text) -> (Text -> Either err value) -> value -> Bool
validSmartConstructedText render construct value =
  case construct (render value) of
    Left _ -> False
    Right _ -> True

validArtifactDigest :: ArtifactDigest -> Bool
validArtifactDigest = validSmartConstructedText renderArtifactDigest mkArtifactDigest

-- | The generation binding every root-init-scoped payload carries. Both halves
-- are bounded identifiers minted by smart constructors the CBOR decode skips.
validRootInitBinding :: RootInitBinding -> Bool
validRootInitBinding binding =
  validSmartConstructedText
    renderBootstrapTransactionId
    mkBootstrapTransactionId
    (rootInitTransactionId binding)
    && validSmartConstructedText
      renderVaultStorageGeneration
      mkVaultStorageGeneration
      (rootInitStorageGeneration binding)

validChildCustodyBinding :: ChildCustodyBinding -> Bool
validChildCustodyBinding binding =
  validSmartConstructedText
    renderVaultStorageGeneration
    mkVaultStorageGeneration
    (childCustodyStorageGeneration binding)
    && validSmartConstructedText
      renderBootstrapTransactionId
      mkBootstrapTransactionId
      (childCustodyTransactionId binding)

validPreparedInit :: PreparedInitEnvelope -> Bool
validPreparedInit prepared =
  validRootInitBinding (preparedInitBinding prepared)
    && validArtifactDigest (preparedInitPristineObservationDigest prepared)
    && validArtifactDigest (preparedInitEnvelopeDigest prepared)

-- | The encrypted @\/sys\/init@ response. An empty share list is rejected
-- because the receipt exists to carry the recovery shares: a receipt with none
-- is the applied-but-unrecoverable state, not a valid record.
validEncryptedResponse :: EncryptedInitResponseReceipt -> Bool
validEncryptedResponse receipt =
  validRootInitBinding (encryptedResponseBinding receipt)
    && not (null (encryptedResponseShares receipt))
    && validArtifactDigest (encryptedResponseReceiptDigest receipt)

-- | The final unlock bundle. This is the one payload carrying arithmetic the
-- type does not state: a Shamir threshold above the share count describes a
-- bundle that can never be reassembled, and a zero threshold describes one that
-- needs no share at all.
validFinalUnlockBundle :: FinalUnlockBundle -> Bool
validFinalUnlockBundle bundle =
  validRootInitBinding (finalUnlockBundleBinding bundle)
    && validArtifactDigest (finalUnlockBundleDigest bundle)
    && validUnlockShareThreshold
      (finalUnlockBundleThreshold bundle)
      (finalUnlockBundleShareCount bundle)

-- | The Shamir arithmetic 'Prodbox.Bootstrap.Broker.Types.mkInitRecipientCommitment'
-- already enforces at the mint site, restated here because the CBOR decode does
-- not go through it.
--
-- It is a separate named function rather than an inline conjunct for a reason
-- worth stating: a bundle violating it is __unconstructible__ through the
-- smart constructors, so a test could only reach it by crafting CBOR bytes.
-- Exposing the decision over its two 'Natural' inputs makes the rule itself
-- falsifiable, which the composed predicate over an unconstructible value would
-- not be (unit_testing_policy.md (historical unit_testing_policy.md at revision `583443f`)
-- canonical statement 10).
validUnlockShareThreshold :: Natural -> Natural -> Bool
validUnlockShareThreshold threshold shareCount =
  threshold > 0 && threshold <= shareCount

validChildEncryptedReceipt :: ChildEncryptedReceipt -> Bool
validChildEncryptedReceipt receipt =
  validChildCustodyBinding (childEncryptedReceiptBinding receipt)
    && not (null (childEncryptedReceiptShares receipt))
    && validArtifactDigest (childEncryptedReceiptDigest receipt)

validChildRecoveryDelivery :: ChildRecoveryDelivery -> Bool
validChildRecoveryDelivery delivery =
  validChildCustodyBinding (childRecoveryDeliveryBinding delivery)
    && validSmartConstructedText
      renderDeliveryNonce
      mkDeliveryNonce
      (childRecoveryDeliveryNonce delivery)
    && validArtifactDigest (childRecoveryDeliveryDigest delivery)

-- | The secret-worker checkpoint. Its arms carry no smart-constructed scalar of
-- their own, but one of them carries a free-text reason for an unobservable
-- checkpoint — and a persisted \"cannot observe\" that says nothing is the
-- distinguishability defect
-- chaos_hardening_doctrine.md at 583443f, section 23
-- names, durably recorded. Every other arm is accepted.
validSecretWorkerCheckpoint :: SecretWorkerDurableCheckpoint -> Bool
validSecretWorkerCheckpoint = null . secretWorkerCheckpointInvariantViolations

validRootInit :: RootInitState -> Bool
validRootInit = null . rootInitInvariantViolations

rootInitReadMatches :: RootInitBinding -> RootInitState -> Bool
rootInitReadMatches requested state =
  rootInitStateBinding state == requested
    || case rootInitStatePhase state of
      RootResetPristine proof -> resetAmbiguousBinding proof == requested
      RootResetInFlight proof _ ->
        resetAmbiguousBinding proof == requested
          || pristineStorageBinding (resetReplacementPristine proof) == requested
      _ -> False

-- | Reset recovery is the one root-journal lookup whose action names the old
-- storage generation but cannot carry the transaction identifier.  The fixed
-- journal key is still accepted only when its typed phase proves that exact
-- old generation (including after the storage-generation CAS has advanced).
rootInitResetReadMatches :: VaultStorageGeneration -> RootInitState -> Bool
rootInitResetReadMatches requested state =
  rootInitStorageGeneration (rootInitStateBinding state) == requested
    || case rootInitStatePhase state of
      RootResetPristine proof ->
        rootInitStorageGeneration (resetAmbiguousBinding proof) == requested
      RootResetInFlight proof _ ->
        rootInitStorageGeneration (resetAmbiguousBinding proof) == requested
      _ -> False

-- | The reset journal CAS is authorized by the still-held old-generation
-- fence, even though the value it publishes becomes the replacement binding.
-- Every other root transition remains authorized by its phase binding.
rootInitJournalMutationGeneration :: RootInitState -> VaultStorageGeneration
rootInitJournalMutationGeneration state =
  case rootInitStatePhase state of
    RootResetPristine proof ->
      rootInitStorageGeneration (resetAmbiguousBinding proof)
    _ -> rootInitStorageGeneration (rootInitStateBinding state)

validRootSession :: RootSessionState -> Bool
validRootSession = null . rootSessionInvariantViolations

validChildCustody :: ChildCustodyState -> Bool
validChildCustody = null . childCustodyInvariantViolations

validChildRecovery :: ChildRecoveryState -> Bool
validChildRecovery = null . childRecoveryInvariantViolations

validPostUnsealHandoff :: PostUnsealHandoffState -> Bool
validPostUnsealHandoff state = case postUnsealHandoffStatePhase state of
  PostUnsealHandoffWaiting -> True
  PostUnsealHandoffObservationPending -> True
  PostUnsealHandoffObserved receipt ->
    postUnsealHandoffStateGeneration state
      == postUnsealHandoffGeneration receipt

readBound
  :: (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> (value -> Bool)
  -> IO (Either StoreBoundaryError (StoreReadBack value))
readBound config key valid bindingMatches = do
  observed <- readValue config key valid
  pure $ case observed of
    Right (StoreObjectPresent version digest value)
      | not (bindingMatches value) -> Left BootstrapStoreBindingMismatch
      | otherwise -> Right (StoreObjectPresent version digest value)
    other -> other

createBound
  :: (Eq value, Serialise value)
  => ObjectStoreConfig
  -> Text
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> VaultStorageGeneration
  -> (value -> Bool)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
createBound config key mutation permit generation valid value =
  case requirePermit mutation generation permit of
    Left failure -> pure (Left failure)
    Right () -> createValueBefore (storeMutationPermitDeadline permit) config key valid value

casBound
  :: (Eq value, Serialise value)
  => ObjectStoreConfig
  -> Text
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> VaultStorageGeneration
  -> (value -> Bool)
  -> StoreVersion
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
casBound config key mutation permit generation valid version value =
  case requirePermit mutation generation permit of
    Left failure -> pure (Left failure)
    Right () -> casValueBefore (storeMutationPermitDeadline permit) config key valid version value

deleteBound
  :: (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> VaultStorageGeneration
  -> StoreVersion
  -> Proxy value
  -> IO (Either StoreBoundaryError ())
deleteBound config key mutation permit generation version valueType =
  case requirePermit mutation generation permit of
    Left failure -> pure (Left failure)
    Right () ->
      storeResultBefore (storeMutationPermitDeadline permit) $
        deleteValue (storeMutationPermitDeadline permit) config key version valueType

requirePermit
  :: BootstrapStoreMutation
  -> VaultStorageGeneration
  -> BootstrapStoreMutationPermit
  -> Either StoreBoundaryError ()
requirePermit mutation generation permit
  | storeMutationPermitMutation permit /= mutation =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitStorageGeneration permit /= generation =
      Left BootstrapStoreBindingMismatch
  | otherwise = Right ()

readValue
  :: forall value
   . (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> IO (Either StoreBoundaryError (StoreReadBack value))
readValue config key valid = do
  physical <- readPhysical config key valid
  pure (toReadBack <$> physical)

readPhysical
  :: forall value
   . (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> IO (Either StoreBoundaryError (PhysicalRead value))
readPhysical config key valid = do
  observed <- Native.getObjectVersioned config key
  pure $ case observed of
    Left _ -> Left BootstrapStoreUnavailable
    Right Nothing -> Right PhysicalAbsent
    Right (Just VersionedObject {versionedObjectBytes, versionedObjectVersion}) -> do
      (version, digest, value) <- decodeStoredEnvelope versionedObjectBytes
      if valid value
        then Right (PhysicalPresent versionedObjectVersion version digest value)
        else Left BootstrapStoreCorrupt

toReadBack :: PhysicalRead value -> StoreReadBack value
toReadBack observed = case observed of
  PhysicalAbsent -> StoreObjectAbsent
  PhysicalPresent _ version digest value ->
    StoreObjectPresent version digest value

createValue
  :: (Eq value, Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
createValue = createValueUsing Native.putIfAbsentObserved

createValueBefore
  :: (Eq value, Serialise value)
  => Deadline
  -> ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
createValueBefore deadline config key valid value =
  storeResultBefore deadline $
    createValueUsing (Native.putIfAbsentObservedBefore deadline) config key valid value

createValueUsing
  :: (Eq value, Serialise value)
  => (ObjectStoreConfig -> Text -> ByteString -> IO (Either String ConditionalPutResult))
  -> ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
createValueUsing put config key valid value =
  case encodeStoredEnvelope (StoreVersion 1) value of
    Left failure -> pure (Left failure)
    Right encoded -> do
      attempted <- put config key encoded
      case attempted of
        Left _ -> pure (Left BootstrapStoreUnavailable)
        Right (ConditionalPutApplied _) -> confirmWrite config key valid (StoreVersion 1) value
        Right ConditionalPutConflict -> conflictResult config key valid

casValueBefore
  :: (Eq value, Serialise value)
  => Deadline
  -> ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> StoreVersion
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
casValueBefore deadline config key valid expected value =
  storeResultBefore deadline $
    casValueUsing (Native.putIfVersionObservedBefore deadline) config key valid expected value

-- | A late result is unresolved. For a mutation the conditional write may
-- already have taken effect, so expiry must not be reported as observed absence.
storeResultBefore
  :: Deadline
  -> IO (Either StoreBoundaryError value)
  -> IO (Either StoreBoundaryError value)
storeResultBefore deadline action = do
  observed <- observeDeadlineEffectWithin deadline $ do
    result <- action
    case result of
      Left failure -> evaluate failure >> pure result
      Right value -> evaluate value >> pure result
  pure $ case observed of
    Nothing -> Left BootstrapStoreUnavailable
    Just DeadlineEffectNotStarted -> Left BootstrapStoreUnavailable
    Just (DeadlineEffectCompletedLate _) -> Left BootstrapStoreUnavailable
    Just (DeadlineEffectCompleted _ result) -> result

casValueUsing
  :: (Eq value, Serialise value)
  => (ObjectStoreConfig -> Text -> ObjectVersion -> ByteString -> IO (Either String ConditionalPutResult))
  -> ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> StoreVersion
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
casValueUsing put config key valid expected value = do
  observed <- readPhysical config key valid
  case observed of
    Left failure -> pure (Left failure)
    Right PhysicalAbsent -> pure (Right (StoreWriteConflict StoreObjectAbsent))
    Right present@(PhysicalPresent etag actual _ _)
      | actual /= expected -> pure (Right (StoreWriteConflict (toReadBack present)))
      | otherwise ->
          let proposed = nextStoreVersion expected
           in case encodeStoredEnvelope proposed value of
                Left failure -> pure (Left failure)
                Right encoded -> do
                  attempted <- put config key etag encoded
                  case attempted of
                    Left _ -> pure (Left BootstrapStoreUnavailable)
                    Right (ConditionalPutApplied _) -> confirmWrite config key valid proposed value
                    Right ConditionalPutConflict -> conflictResult config key valid

deleteValue
  :: forall value
   . (Serialise value)
  => Deadline
  -> ObjectStoreConfig
  -> Text
  -> StoreVersion
  -> Proxy value
  -> IO (Either StoreBoundaryError ())
deleteValue deadline config key expected (_ :: Proxy value) = do
  observed <- readPhysical config key (const True :: value -> Bool)
  case observed of
    Left failure -> pure (Left failure)
    Right PhysicalAbsent -> pure (Right ())
    Right (PhysicalPresent etag actual _ _)
      | actual /= expected -> pure (Left BootstrapStoreVersionConflict)
      | otherwise -> do
          now <- realMonotonicNow
          case deadlineObservation now deadline of
            DeadlineExpired -> pure (Left BootstrapStoreUnavailable)
            DeadlineOpen _ -> do
              deleted <- Native.deleteIfVersionObservedBefore deadline config key etag
              case deleted of
                Left _ -> pure (Left BootstrapStoreUnavailable)
                Right ConditionalDeleteConflict ->
                  pure (Left BootstrapStoreVersionConflict)
                Right ConditionalDeleteApplied -> do
                  readBack <- Native.getObjectVersioned config key
                  pure $ case readBack of
                    Right Nothing -> Right ()
                    Right (Just _) -> Left BootstrapStoreReadBackMismatch
                    Left _ -> Left BootstrapStoreUnavailable

confirmWrite
  :: (Eq value, Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> StoreVersion
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
confirmWrite config key valid expectedVersion expectedValue = do
  observed <- readValue config key valid
  pure $ case observed of
    Right (StoreObjectPresent version digest value)
      | version == expectedVersion && value == expectedValue ->
          Right (StoreWriteApplied version digest value)
      | otherwise -> Left BootstrapStoreReadBackMismatch
    Right StoreObjectAbsent -> Left BootstrapStoreReadBackMismatch
    Left failure -> Left failure

conflictResult
  :: (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
conflictResult config key valid = do
  observed <- readValue config key valid
  pure (StoreWriteConflict <$> observed)

nextStoreVersion :: StoreVersion -> StoreVersion
nextStoreVersion (StoreVersion current) = StoreVersion (current + 1)

encodeStoredEnvelope
  :: (Serialise value)
  => StoreVersion
  -> value
  -> Either StoreBoundaryError ByteString
encodeStoredEnvelope (StoreVersion version) value
  | version == 0 = Left BootstrapStoreCorrupt
  | ByteString.length bytes > maximumBootstrapStoreObjectBytes =
      Left BootstrapStoreCorrupt
  | otherwise = Right bytes
 where
  bytes =
    LazyByteString.toStrict
      (serialise (StoredEnvelope 1 version value))

decodeStoredEnvelope
  :: forall value
   . (Serialise value)
  => ByteString
  -> Either StoreBoundaryError (StoreVersion, ArtifactDigest, value)
decodeStoredEnvelope bytes
  | ByteString.length bytes > maximumBootstrapStoreObjectBytes =
      Left BootstrapStoreCorrupt
  | otherwise =
      case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left BootstrapStoreCorrupt
        Right envelope
          | storedEnvelopeSchema envelope /= 1 -> Left BootstrapStoreCorrupt
          | storedEnvelopeVersion envelope == 0 -> Left BootstrapStoreCorrupt
          | LazyByteString.toStrict (serialise envelope) /= bytes ->
              Left BootstrapStoreCorrupt
          | otherwise -> do
              digest <- digestBytes bytes
              Right
                ( StoreVersion (storedEnvelopeVersion envelope)
                , digest
                , storedEnvelopeValue envelope
                )

digestBytes :: ByteString -> Either StoreBoundaryError ArtifactDigest
digestBytes bytes =
  case mkArtifactDigest (lowerHexBytes (SHA256.hash bytes)) of
    Left _ -> Left BootstrapStoreCorrupt
    Right digest -> Right digest

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap renderHexByte . ByteString.unpack
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | Once a boundary has started, losing the generation record is not evidence
-- of a fresh installation and must never mint a replacement during a read.
observeExistingStorageGeneration
  :: ObjectStoreConfig
  -> Text
  -> IO (Either StoreBoundaryError RootInitBinding)
observeExistingStorageGeneration config key = do
  observed <- readValue config key validRootInitBinding
  pure $ case observed of
    Left failure -> Left failure
    Right StoreObjectAbsent -> Left BootstrapStoreReadBackMismatch
    Right (StoreObjectPresent _ _ binding) -> Right binding

observeOrCreateStorageGeneration
  :: ObjectStoreConfig
  -> Text
  -> Text
  -> IO (Either StoreBoundaryError RootInitBinding)
observeOrCreateStorageGeneration config key fenceKey = do
  observed <- readValue config key validRootInitBinding
  case observed of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent _ _ binding) -> pure (Right binding)
    Right StoreObjectAbsent -> do
      fence <- readValue config fenceKey validFenceObservation
      case fence of
        Left failure -> pure (Left failure)
        Right StoreObjectPresent {} -> pure (Left BootstrapStoreBindingMismatch)
        Right StoreObjectAbsent -> createGeneration
 where
  -- Fence absence is only a necessary check. It cannot establish genesis:
  -- other retained objects, partial loss, and concurrent old writers remain.
  createGeneration = do
    entropy <- getRandomBytes 32 :: IO ByteString
    let rendered = lowerHexBytes entropy
    case ( mkBootstrapTransactionId ("bootstrap-" <> rendered)
         , mkVaultStorageGeneration ("vault-" <> rendered)
         ) of
      (Right transactionId, Right storageGeneration) -> do
        created <-
          createValue
            config
            key
            validRootInitBinding
            RootInitBinding
              { rootInitTransactionId = transactionId
              , rootInitStorageGeneration = storageGeneration
              }
        pure $ case created of
          Right (StoreWriteApplied _ _ binding) -> Right binding
          Right (StoreWriteConflict (StoreObjectPresent _ _ binding)) -> Right binding
          Right (StoreWriteConflict StoreObjectAbsent) ->
            Left BootstrapStoreReadBackMismatch
          Left failure -> Left failure
      _ -> pure (Left BootstrapStoreCorrupt)

-- | Advance the single durable Vault-storage generation exactly once.  An
-- exact replacement read-back is idempotent recovery for a response lost
-- after the CAS; any third binding is a hard conflict rather than a retry
-- target.
advanceStorageGeneration
  :: ObjectStoreConfig
  -> Text
  -> BootstrapStoreMutationPermit
  -> RootInitBinding
  -> RootInitBinding
  -> IO (Either StoreBoundaryError RootInitBinding)
advanceStorageGeneration config key permit expected replacement =
  case requirePermit
    BootstrapStoreAdvanceVaultStorageGeneration
    (rootInitStorageGeneration expected)
    permit of
    Left failure -> pure (Left failure)
    Right () -> storeResultBefore (storeMutationPermitDeadline permit) $ do
      observed <- readValue config key validRootInitBinding
      case observed of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent -> pure (Left BootstrapStoreReadBackMismatch)
        Right (StoreObjectPresent version _ actual)
          | actual == replacement -> pure (Right replacement)
          | actual /= expected -> pure (Left BootstrapStoreBindingMismatch)
          | otherwise -> do
              written <-
                casValueBefore
                  (storeMutationPermitDeadline permit)
                  config
                  key
                  validRootInitBinding
                  version
                  replacement
              pure $ case written of
                Left failure -> Left failure
                Right (StoreWriteApplied _ _ actualReplacement)
                  | actualReplacement == replacement -> Right replacement
                Right (StoreWriteConflict (StoreObjectPresent _ _ actualReplacement))
                  | actualReplacement == replacement -> Right replacement
                Right _ -> Left BootstrapStoreVersionConflict

observeFence
  :: ObjectStoreConfig
  -> Text
  -> IO (Either StoreBoundaryError BootstrapFenceStoreObservation)
observeFence config key = do
  observed <- readValue config key validFenceObservation
  pure $ case observed of
    Right StoreObjectAbsent -> Right (BootstrapFenceStoreVacant 0)
    Right (StoreObjectPresent _ _ value) -> Right value
    Left failure -> Left failure

validFenceObservation :: BootstrapFenceStoreObservation -> Bool
validFenceObservation observation = case observation of
  BootstrapFenceStoreVacant _ -> True
  BootstrapFenceStoreHeld fence ->
    bootstrapFenceGenerationValue (bootstrapFenceGeneration fence) > 0
  BootstrapFenceStoreUnobservable _ -> False

casFence
  :: ObjectStoreConfig
  -> Text
  -> BootstrapFenceCasPlan
  -> IO (Either StoreBoundaryError BootstrapFenceCasResult)
casFence config key plan = do
  result <- storeResultBefore (fenceCasDeadline plan) (casFenceWithin config key plan)
  pure $ case result of
    Left BootstrapStoreUnavailable ->
      Right (BootstrapFenceCasUnobservable "bootstrap fence CAS deadline elapsed or outcome unavailable")
    other -> other

casFenceWithin
  :: ObjectStoreConfig
  -> Text
  -> BootstrapFenceCasPlan
  -> IO (Either StoreBoundaryError BootstrapFenceCasResult)
casFenceWithin config key plan = do
  observed <- readPhysical config key validFenceObservation
  case observed of
    Left BootstrapStoreUnavailable ->
      pure (Right (BootstrapFenceCasUnobservable "bootstrap fence store unavailable"))
    Left failure -> pure (Left failure)
    Right physical ->
      case fencePhysicalObservation physical of
        BootstrapFenceStoreVacant floorValue
          | floorValue == fenceCasExpectedGenerationFloor plan -> do
              written <-
                writeFencePhysicalBefore
                  (fenceCasDeadline plan)
                  config
                  key
                  physical
                  (BootstrapFenceStoreHeld (fenceCasProposedFence plan))
              pure $ case written of
                Left BootstrapStoreVersionConflict ->
                  Right
                    ( BootstrapFenceCasConflict
                        (fencePhysicalObservation physical)
                    )
                Left BootstrapStoreUnavailable ->
                  Right (BootstrapFenceCasUnobservable "bootstrap fence CAS unavailable")
                Left failure -> Left failure
                Right (BootstrapFenceStoreHeld readBack) ->
                  Right (BootstrapFenceCasAppliedReadBack readBack)
                Right _ -> Left BootstrapStoreReadBackMismatch
        _ -> pure (Right (BootstrapFenceCasConflict (fencePhysicalObservation physical)))

retireFence
  :: ObjectStoreConfig
  -> Text
  -> BootstrapFenceRetirePlan
  -> IO (Either StoreBoundaryError BootstrapFenceRetireCasResult)
retireFence config key plan = do
  result <- storeResultBefore (fenceRetireDeadline plan) (retireFenceWithin config key plan)
  pure $ case result of
    Left BootstrapStoreUnavailable ->
      Right
        ( BootstrapFenceRetireCasUnobservable
            "bootstrap fence retirement deadline elapsed or outcome unavailable"
        )
    other -> other

retireFenceWithin
  :: ObjectStoreConfig
  -> Text
  -> BootstrapFenceRetirePlan
  -> IO (Either StoreBoundaryError BootstrapFenceRetireCasResult)
retireFenceWithin config key plan = do
  observed <- readPhysical config key validFenceObservation
  case observed of
    Left BootstrapStoreUnavailable ->
      pure
        (Right (BootstrapFenceRetireCasUnobservable "bootstrap fence store unavailable"))
    Left failure -> pure (Left failure)
    Right physical ->
      case fencePhysicalObservation physical of
        BootstrapFenceStoreHeld held
          | held == fenceRetireExpectedFence plan -> do
              written <-
                writeFencePhysicalBefore
                  (fenceRetireDeadline plan)
                  config
                  key
                  physical
                  (BootstrapFenceStoreVacant (fenceRetireVacantGenerationFloor plan))
              pure $ case written of
                Left BootstrapStoreVersionConflict ->
                  Right
                    ( BootstrapFenceRetireCasConflict
                        (fencePhysicalObservation physical)
                    )
                Left BootstrapStoreUnavailable ->
                  Right
                    (BootstrapFenceRetireCasUnobservable "bootstrap fence CAS unavailable")
                Left failure -> Left failure
                Right readBack ->
                  Right (BootstrapFenceRetireCasAppliedReadBack readBack)
        _ ->
          pure
            ( Right
                ( BootstrapFenceRetireCasConflict
                    (fencePhysicalObservation physical)
                )
            )

releaseFence
  :: ObjectStoreConfig
  -> Text
  -> BootstrapStoreMutationPermit
  -> BootstrapSessionFence
  -> IO (Either StoreBoundaryError BootstrapFenceStoreObservation)
releaseFence config key permit expected
  | storeMutationPermitMutation permit /= BootstrapStoreReleaseSessionFence =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitFenceGeneration permit /= bootstrapFenceGeneration expected =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitOwnerNonce permit /= bootstrapFenceOwnerNonce expected =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitActionDigest permit /= bootstrapFenceActionDigest expected =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitRequestDigest permit /= bootstrapFenceRequestDigest expected =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitOperationDeadline permit /= bootstrapFenceOperationDeadline expected =
      pure (Left BootstrapStoreBindingMismatch)
  | storeMutationPermitStorageGeneration permit
      /= bootstrapFenceStorageGeneration expected =
      pure (Left BootstrapStoreBindingMismatch)
  | otherwise = storeResultBefore (storeMutationPermitDeadline permit) $ do
      observed <- readPhysical config key validFenceObservation
      case observed of
        Left failure -> pure (Left failure)
        Right physical -> case fencePhysicalObservation physical of
          BootstrapFenceStoreHeld held
            | held == expected ->
                writeFencePhysicalBefore
                  (storeMutationPermitDeadline permit)
                  config
                  key
                  physical
                  ( BootstrapFenceStoreVacant
                      (bootstrapFenceGenerationValue (bootstrapFenceGeneration expected))
                  )
          current -> pure (Right current)

fencePhysicalObservation
  :: PhysicalRead BootstrapFenceStoreObservation
  -> BootstrapFenceStoreObservation
fencePhysicalObservation physical = case physical of
  PhysicalAbsent -> BootstrapFenceStoreVacant 0
  PhysicalPresent _ _ _ observation -> observation

writeFencePhysicalBefore
  :: Deadline
  -> ObjectStoreConfig
  -> Text
  -> PhysicalRead BootstrapFenceStoreObservation
  -> BootstrapFenceStoreObservation
  -> IO (Either StoreBoundaryError BootstrapFenceStoreObservation)
writeFencePhysicalBefore deadline =
  writeFencePhysicalUsing
    (Native.putIfAbsentObservedBefore deadline)
    (Native.putIfVersionObservedBefore deadline)

writeFencePhysicalUsing
  :: (ObjectStoreConfig -> Text -> ByteString -> IO (Either String ConditionalPutResult))
  -> (ObjectStoreConfig -> Text -> ObjectVersion -> ByteString -> IO (Either String ConditionalPutResult))
  -> ObjectStoreConfig
  -> Text
  -> PhysicalRead BootstrapFenceStoreObservation
  -> BootstrapFenceStoreObservation
  -> IO (Either StoreBoundaryError BootstrapFenceStoreObservation)
writeFencePhysicalUsing putAbsent putVersion config key physical proposed = do
  let logicalVersion = case physical of
        PhysicalAbsent -> StoreVersion 1
        PhysicalPresent _ version _ _ -> nextStoreVersion version
  case encodeStoredEnvelope logicalVersion proposed of
    Left failure -> pure (Left failure)
    Right encoded -> do
      attempted <- case physical of
        PhysicalAbsent -> putAbsent config key encoded
        PhysicalPresent etag _ _ _ ->
          putVersion config key etag encoded
      case attempted of
        Left _ -> pure (Left BootstrapStoreUnavailable)
        Right ConditionalPutConflict -> pure (Left BootstrapStoreVersionConflict)
        Right (ConditionalPutApplied _) -> do
          readBack <- observeFence config key
          pure $ case readBack of
            Right actual | actual == proposed -> Right actual
            Right _ -> Left BootstrapStoreReadBackMismatch
            Left failure -> Left failure
