{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Production fixed-coordinate MinIO interpreter for Bootstrap Broker state.
-- Logical versions live inside a bounded canonical CBOR envelope; S3 ETags are
-- used only as physical compare-and-swap witnesses.  A successful write is not
-- reported until the exact logical value has been read back.
module Prodbox.Bootstrap.Broker.ProductionStore
  ( productionBootstrapStoreBoundary
  , bootstrapStoreReady
  , maximumBootstrapStoreObjectBytes
  , ProductionSecretWorkerResult
  , productionSecretWorkerResultRequest
  , productionSecretWorkerResultReceipt
  , productionSecretWorkerResultValue
  , productionSecretWorkerReceiptDigest
  , publishProductionSecretWorkerResult
  , observeProductionSecretWorkerResult
  , ProductionTransitRotationJournal (..)
  , ProductionTransitRotationBoundary (..)
  , productionTransitRotationBoundary
  , observeProductionTransitRotationJournal
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
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
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
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapFenceStorageGeneration
  , fenceCasExpectedGenerationFloor
  , fenceCasProposedFence
  , fenceRetireExpectedFence
  , fenceRetireVacantGenerationFloor
  , storeMutationPermitMutation
  , storeMutationPermitRequestDigest
  , storeMutationPermitStorageGeneration
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
  , secretWorkerRequestDigest
  , secretWorkerRequestFenceGeneration
  , secretWorkerRequestOperation
  , secretWorkerRequestPodUid
  , secretWorkerRequestSessionAccessor
  , secretWorkerRequestSessionId
  , secretWorkerRequestStorageGeneration
  , workerSessionAccessorIssued
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
  , renderArtifactDigest
  , renderBootstrapTransactionId
  , renderDeliveryNonce
  , renderVaultStorageGeneration
  , resetAmbiguousBinding
  , rootInitStorageGeneration
  )
import Prodbox.CLI.Output (writeDiagnosticLine)
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

-- | Single fixed-coordinate write-ahead journal for Transit rotation. A
-- planned record is durable before the Vault rotate call. Recovery compares
-- Vault's exact current version with @before@/@before + 1@, so a lost HTTP
-- response cannot cause a second rotation.
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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

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
      -> m (Either StoreBoundaryError ProductionTransitRotationJournal)
  , completeTransitRotation
      :: BootstrapStoreMutationPermit
      -> SecretFreeWorkerRequest
      -> Text
      -> Natural
      -> Natural
      -> m (Either StoreBoundaryError ProductionTransitRotationJournal)
  }

productionTransitRotationBoundary
  :: Settings.BootstrapBrokerSettings
  -> ProductionTransitRotationBoundary IO
productionTransitRotationBoundary settings =
  ProductionTransitRotationBoundary
    { planTransitRotation = planProductionTransitRotation settings
    , completeTransitRotation = completeProductionTransitRotation settings
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
  -> IO (Either StoreBoundaryError ProductionTransitRotationJournal)
planProductionTransitRotation settings permit request keyName before =
  case requireTransitPermit BootstrapStorePlanTransitRotation permit request of
    Left failure -> pure (Left failure)
    Right () -> do
      observed <- observeProductionTransitRotationJournal settings
      let proposed =
            ProductionTransitRotationPlanned
              (secretWorkerRequestDigest request)
              (secretWorkerRequestStorageGeneration request)
              keyName
              before
      case observed of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent ->
          exactJournalWrite proposed
            <$> createValue config journalKey validTransitRotationJournal proposed
        Right (StoreObjectPresent _ _ current)
          | current == proposed -> pure (Right current)
        Right (StoreObjectPresent _ _ current@ProductionTransitRotationApplied {})
          | transitRotationRequestDigest current == secretWorkerRequestDigest request
              && transitRotationKeyName current == keyName
              && transitRotationBeforeVersion current == before ->
              pure (Right current)
        Right (StoreObjectPresent version _ ProductionTransitRotationApplied {}) ->
          exactJournalWrite proposed
            <$> casValue config journalKey validTransitRotationJournal version proposed
        Right (StoreObjectPresent _ _ ProductionTransitRotationPlanned {}) ->
          pure (Left BootstrapStoreVersionConflict)
 where
  config = objectStoreConfig settings
  journalKey = transitRotationJournalKey settings

completeProductionTransitRotation
  :: Settings.BootstrapBrokerSettings
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> Text
  -> Natural
  -> Natural
  -> IO (Either StoreBoundaryError ProductionTransitRotationJournal)
completeProductionTransitRotation settings permit request keyName before after =
  case requireTransitPermit BootstrapStoreCompleteTransitRotation permit request of
    Left failure -> pure (Left failure)
    Right () -> do
      observed <- observeProductionTransitRotationJournal settings
      let proposed =
            ProductionTransitRotationApplied
              (secretWorkerRequestDigest request)
              (secretWorkerRequestStorageGeneration request)
              keyName
              before
              after
          exact current =
            transitRotationRequestDigest current == secretWorkerRequestDigest request
              && transitRotationStorageGeneration current
                == secretWorkerRequestStorageGeneration request
              && transitRotationKeyName current == keyName
              && transitRotationBeforeVersion current == before
      case observed of
        Left failure -> pure (Left failure)
        Right (StoreObjectPresent _ _ current)
          | current == proposed -> pure (Right current)
        Right (StoreObjectPresent version _ current@ProductionTransitRotationPlanned {})
          | exact current ->
              exactJournalWrite proposed
                <$> casValue config journalKey validTransitRotationJournal version proposed
        _ -> pure (Left BootstrapStoreBindingMismatch)
 where
  config = objectStoreConfig settings
  journalKey = transitRotationJournalKey settings

transitRotationJournalKey :: Settings.BootstrapBrokerSettings -> Text
transitRotationJournalKey settings =
  Settings.secretWorkerCheckpointKey
    (Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings))
    <> ".transit-rotation-v1"

validTransitRotationJournal :: ProductionTransitRotationJournal -> Bool
validTransitRotationJournal journal =
  not (Text.null (transitRotationKeyName journal))
    && Text.length (transitRotationKeyName journal) <= 256
    && case journal of
      ProductionTransitRotationPlanned {} -> True
      ProductionTransitRotationApplied {transitRotationBeforeVersion, transitRotationAfterVersion} ->
        transitRotationAfterVersion == transitRotationBeforeVersion + 1

requireTransitPermit
  :: BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> SecretFreeWorkerRequest
  -> Either StoreBoundaryError ()
requireTransitPermit mutation permit request
  | storeMutationPermitMutation permit /= mutation = Left BootstrapStoreBindingMismatch
  | storeMutationPermitStorageGeneration permit
      /= secretWorkerRequestStorageGeneration request =
      Left BootstrapStoreBindingMismatch
  | storeMutationPermitRequestDigest permit
      /= secretWorkerRequestDigest request =
      Left BootstrapStoreBindingMismatch
  | secretWorkerRequestSessionAccessor request /= workerSessionNotIssued =
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
   in if storeMutationPermitMutation permit
        /= BootstrapStorePublishSecretWorkerResult
        || storeMutationPermitStorageGeneration permit
          /= secretWorkerRequestStorageGeneration request
        then pure (Left BootstrapStoreBindingMismatch)
        else
          if validWorkerResult value
            then do
              written <- createValue config key validWorkerResult value
              case written of
                Left failure -> pure (Left failure)
                Right (StoreWriteApplied _ _ actual) -> pure (Right actual)
                Right (StoreWriteConflict (StoreObjectPresent version _ actual))
                  | actual == value -> pure (Right actual)
                  | otherwise -> do
                      replaced <- casValue config key validWorkerResult version value
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

secretWorkerResultKey :: Settings.BootstrapBrokerSettings -> Text
secretWorkerResultKey settings =
  Settings.secretWorkerCheckpointKey
    (Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings))
    <> ".result-v1"

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
        && case operation of
          SecretWorkerRotateTransitKey ->
            case workerSessionAccessorIssued (rawWorkerReceiptSessionAccessor receipt) of
              Just _ -> True
              Nothing -> False
          _ -> rawWorkerReceiptSessionAccessor receipt == workerSessionNotIssued
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
productionBootstrapStoreBoundary settings = do
  let config = objectStoreConfig settings
      keys = Settings.bootstrapStorageKeys (Settings.brokerBootstrapStore settings)
      generationKey = Settings.vaultStorageGenerationKey keys
  bucket <- Native.ensureObjectStoreBucket config
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
      generation <- observeOrCreateStorageGeneration config generationKey
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
        observeOrCreateStorageGeneration config generationKey
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
    , promoteFinalUnlockBundle = \permit response value -> do
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
-- [chaos_hardening_doctrine.md § 23](../../../../documents/engineering/chaos_hardening_doctrine.md)
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
-- not be ([unit_testing_policy.md](../../../../documents/engineering/unit_testing_policy.md)
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
-- [chaos_hardening_doctrine.md § 23](../../../../documents/engineering/chaos_hardening_doctrine.md)
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
    Right () -> createValue config key valid value

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
    Right () -> casValue config key valid version value

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
    Right () -> deleteValue config key version valueType

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
createValue config key valid value =
  case encodeStoredEnvelope (StoreVersion 1) value of
    Left failure -> pure (Left failure)
    Right encoded -> do
      attempted <- Native.putIfAbsentObserved config key encoded
      case attempted of
        Left _ -> pure (Left BootstrapStoreUnavailable)
        Right (ConditionalPutApplied _) -> confirmWrite config key valid (StoreVersion 1) value
        Right ConditionalPutConflict -> conflictResult config key valid

casValue
  :: (Eq value, Serialise value)
  => ObjectStoreConfig
  -> Text
  -> (value -> Bool)
  -> StoreVersion
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
casValue config key valid expected value = do
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
                  attempted <- Native.putIfVersionObserved config key etag encoded
                  case attempted of
                    Left _ -> pure (Left BootstrapStoreUnavailable)
                    Right (ConditionalPutApplied _) -> confirmWrite config key valid proposed value
                    Right ConditionalPutConflict -> conflictResult config key valid

deleteValue
  :: forall value
   . (Serialise value)
  => ObjectStoreConfig
  -> Text
  -> StoreVersion
  -> Proxy value
  -> IO (Either StoreBoundaryError ())
deleteValue config key expected (_ :: Proxy value) = do
  observed <- readPhysical config key (const True :: value -> Bool)
  case observed of
    Left failure -> pure (Left failure)
    Right PhysicalAbsent -> pure (Right ())
    Right (PhysicalPresent etag actual _ _)
      | actual /= expected -> pure (Left BootstrapStoreVersionConflict)
      | otherwise -> do
          deleted <- Native.deleteIfVersionObserved config key etag
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

observeOrCreateStorageGeneration
  :: ObjectStoreConfig
  -> Text
  -> IO (Either StoreBoundaryError RootInitBinding)
observeOrCreateStorageGeneration config key = do
  observed <- readValue config key validRootInitBinding
  case observed of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent _ _ binding) -> pure (Right binding)
    Right StoreObjectAbsent -> do
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
    Right () -> do
      observed <- readValue config key validRootInitBinding
      case observed of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent -> pure (Left BootstrapStoreReadBackMismatch)
        Right (StoreObjectPresent version _ actual)
          | actual == replacement -> pure (Right replacement)
          | actual /= expected -> pure (Left BootstrapStoreBindingMismatch)
          | otherwise -> do
              written <- casValue config key validRootInitBinding version replacement
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
                writeFencePhysical
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
                writeFencePhysical
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
  | storeMutationPermitStorageGeneration permit
      /= bootstrapFenceStorageGeneration expected =
      pure (Left BootstrapStoreBindingMismatch)
  | otherwise = do
      observed <- readPhysical config key validFenceObservation
      case observed of
        Left failure -> pure (Left failure)
        Right physical -> case fencePhysicalObservation physical of
          BootstrapFenceStoreHeld held
            | held == expected ->
                writeFencePhysical
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

writeFencePhysical
  :: ObjectStoreConfig
  -> Text
  -> PhysicalRead BootstrapFenceStoreObservation
  -> BootstrapFenceStoreObservation
  -> IO (Either StoreBoundaryError BootstrapFenceStoreObservation)
writeFencePhysical config key physical proposed = do
  let logicalVersion = case physical of
        PhysicalAbsent -> StoreVersion 1
        PhysicalPresent _ version _ _ -> nextStoreVersion version
  case encodeStoredEnvelope logicalVersion proposed of
    Left failure -> pure (Left failure)
    Right encoded -> do
      attempted <- case physical of
        PhysicalAbsent -> Native.putIfAbsentObserved config key encoded
        PhysicalPresent etag _ _ _ ->
          Native.putIfVersionObserved config key etag encoded
      case attempted of
        Left _ -> pure (Left BootstrapStoreUnavailable)
        Right ConditionalPutConflict -> pure (Left BootstrapStoreVersionConflict)
        Right (ConditionalPutApplied _) -> do
          readBack <- observeFence config key
          pure $ case readBack of
            Right actual | actual == proposed -> Right actual
            Right _ -> Left BootstrapStoreReadBackMismatch
            Left failure -> Left failure
