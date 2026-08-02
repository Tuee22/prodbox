{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Persist-before-effect coordinator for one retained-material delivery.
module Prodbox.ControlPlane.RetainedMaterialDeliveryCoordinator
  ( RetainedMaterialDeliveryRequest (..)
  , coordinateRetainedMaterialDelivery
  , ensureRetainedMaterialCurrentSource
  )
where

import Data.Bifunctor (first)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationKeyPair
  , generateRetainedDestinationKeyPair
  , retainedDestinationPublicKey
  , retainedDestinationPublicKeyDigest
  )
import Prodbox.ControlPlane.RetainedMaterialRepository
  ( RetainedMaterialRepository (..)
  , applyRetainedMaterialCommand
  , retainedMaterialSnapshotAggregate
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , targetWorkerReceiptCommitment
  , targetWorkerReceiptGeneration
  , targetWorkerReceiptVaultVersion
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedCustodyObservation (RetainedCustodyPresent)
  , RetainedDeliveryIntent
  , RetainedDeliveryReceipt
  , RetainedMaterialCommand (..)
  , RetainedMaterialDecision (..)
  , RetainedMaterialRef
  , RetainedMaterialSource
  , RetainedMaterialTarget
  , mkRetainedDeliveryIntent
  , mkRetainedDeliveryReceipt
  , mkRetainedMaterialRef
  , mkRetainedSealIntent
  , retainedDeliveryDeadline
  , retainedDeliveryOperationId
  , retainedDeliveryReceiptOperationId
  , retainedDeliverySourceReceipt
  , retainedDeliveryTarget
  , retainedDeliveryTargetGeneration
  , retainedMaterialCompletedDeliveries
  , retainedMaterialCurrent
  , retainedMaterialPendingDeliveries
  , retainedSourceCiphertextDigest
  , retainedSourceCommitmentRef
  , retainedSourceGeneration
  , retainedSourceOperationId
  , retainedSourceReceiptRef
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (CredentialGeneration)

data RetainedMaterialDeliveryRequest schema = RetainedMaterialDeliveryRequest
  { retainedDeliveryRequestOperationId :: !RetainedMaterialRef
  , retainedDeliveryRequestTarget :: !(RetainedMaterialTarget schema)
  , retainedDeliveryRequestGeneration :: !CredentialGeneration
  , retainedDeliveryRequestAttestationRef :: !RetainedMaterialRef
  , retainedDeliveryRequestDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

coordinateRetainedMaterialDelivery
  :: RetainedMaterialRepository schema IO revision
  -> AuthorityTime
  -> RetainedMaterialSource schema
  -> RetainedMaterialDeliveryRequest schema
  -> ( RetainedDeliveryIntent schema
       -> IO (Either Text (Maybe TargetWorkerReceipt))
     )
  -> ( RetainedDestinationKeyPair schema
       -> RetainedDeliveryIntent schema
       -> IO (Either Text TargetWorkerReceipt)
     )
  -> IO (Either Text (RetainedDeliveryReceipt schema))
coordinateRetainedMaterialDelivery repository now source request observeDelivery runDelivery = do
  prepared <- ensureRetainedMaterialCurrentSource repository now source request
  case prepared of
    Left detail -> pure (Left detail)
    Right () -> resumeOrBegin
 where
  resumeOrBegin = do
    observed <- readRetainedMaterialSnapshot repository
    case observed of
      Left detail -> pure (Left detail)
      Right snapshot ->
        case completedForOperation (retainedMaterialSnapshotAggregate snapshot) of
          Just receipt -> pure (Right receipt)
          Nothing ->
            case pendingForOperation (retainedMaterialSnapshotAggregate snapshot) of
              Just pending -> recoverPending pending
              Nothing -> beginFresh

  beginFresh = do
    keyPair <- generateRetainedDestinationKeyPair
    let intent = deliveryIntent keyPair request source
    begun <-
      applyRetainedMaterialCommand
        repository
        (BeginRetainedMaterialDelivery (RetainedCustodyPresent source) now intent)
    case begun of
      Left detail -> pure (Left detail)
      Right (RetainedDeliveryAlreadyCompleted receipt) -> pure (Right receipt)
      Right (RetainedDeliveryBegun _) -> execute intent keyPair
      Right (RetainedMaterialRefused refusal) ->
        pure (Left ("retained delivery refused: " <> Text.pack (show refusal)))
      Right decision -> pure (Left (unexpected "begin" decision))

  execute intent keyPair = do
    delivered <- runDelivery keyPair intent
    case delivered of
      Left detail -> pure (Left detail)
      Right workerReceipt -> commitReceipt intent workerReceipt

  recoverPending intent = do
    observed <- observeDelivery intent
    case observed of
      Left detail -> pure (Left detail)
      Right (Just workerReceipt) -> commitReceipt intent workerReceipt
      Right Nothing
        | authorityTimeMicros now
            <= authorityTimeMicros (retainedDeliveryDeadline intent) ->
            pure (Left "retained delivery remains pending until its absolute deadline")
        | otherwise -> do
            expired <-
              applyRetainedMaterialCommand
                repository
                (ExpireRetainedMaterialDelivery (retainedDeliveryOperationId intent) now)
            pure $ case expired of
              Right (RetainedDeliveryExpired _) ->
                Left "retained delivery expired without an observed Target receipt; use a successor operation"
              Right decision -> Left (unexpected "expiry" decision)
              Left detail -> Left detail

  commitReceipt intent workerReceipt =
    case deliveryReceipt intent workerReceipt of
      Left detail -> pure (Left detail)
      Right receipt -> do
        committed <-
          applyRetainedMaterialCommand
            repository
            (ObserveRetainedMaterialDelivery receipt)
        pure $ case committed of
          Right (RetainedDeliveryCommitted confirmed) -> Right confirmed
          Right (RetainedDeliveryAlreadyCompleted confirmed) -> Right confirmed
          Right decision -> Left (unexpected "recovery" decision)
          Left detail -> Left detail

  pendingForOperation aggregate =
    findByOperation retainedDeliveryOperationId (retainedMaterialPendingDeliveries aggregate)

  completedForOperation aggregate =
    findByOperation retainedDeliveryReceiptOperationId (retainedMaterialCompletedDeliveries aggregate)

  findByOperation operationOf =
    find ((== retainedDeliveryRequestOperationId request) . operationOf)

ensureRetainedMaterialCurrentSource
  :: RetainedMaterialRepository schema IO revision
  -> AuthorityTime
  -> RetainedMaterialSource schema
  -> RetainedMaterialDeliveryRequest schema
  -> IO (Either Text ())
ensureRetainedMaterialCurrentSource repository now source request = do
  observed <- readRetainedMaterialSnapshot repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot -> case retainedMaterialCurrent (retainedMaterialSnapshotAggregate snapshot) of
      Just current
        | sourceIdentityMatches current source -> pure (Right ())
        | otherwise -> beginSource
      Nothing -> beginSource
 where
  beginSource = do
    let sealIntent =
          mkRetainedSealIntent
            (retainedSourceOperationId source)
            (retainedSourceGeneration source)
            (retainedSourceReceiptRef source)
            (retainedSourceCiphertextDigest source)
            (retainedDeliveryRequestDeadline request)
            (retainedDeliveryRequestDeadline request)
    case sealIntent of
      Left detail -> pure (Left detail)
      Right intent -> do
        begun <-
          applyRetainedMaterialCommand repository (BeginRetainedMaterialSeal now intent)
        case begun of
          Left detail -> pure (Left detail)
          Right (RetainedSealBegun _) -> commitSource
          Right (RetainedSealAlreadyBegun _) -> commitSource
          Right (RetainedSealAlreadyCommitted _) -> pure (Right ())
          Right decision -> pure (Left (unexpected "source-begin" decision))

  commitSource = do
    committed <-
      applyRetainedMaterialCommand repository (ObserveRetainedMaterialSeal source)
    pure $ case committed of
      Right (RetainedSealCommitted {}) -> Right ()
      Right (RetainedSealAlreadyCommitted _) -> Right ()
      Right decision -> Left (unexpected "source-commit" decision)
      Left detail -> Left detail

sourceIdentityMatches
  :: RetainedMaterialSource schema -> RetainedMaterialSource schema -> Bool
sourceIdentityMatches left right =
  retainedSourceGeneration left == retainedSourceGeneration right
    && retainedSourceOperationId left == retainedSourceOperationId right
    && retainedSourceReceiptRef left == retainedSourceReceiptRef right
    && retainedSourceCiphertextDigest left == retainedSourceCiphertextDigest right
    && retainedSourceCommitmentRef left == retainedSourceCommitmentRef right
    && retainedSourceVaultVersion left == retainedSourceVaultVersion right

deliveryIntent
  :: RetainedDestinationKeyPair schema
  -> RetainedMaterialDeliveryRequest schema
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
deliveryIntent keyPair request source =
  mkRetainedDeliveryIntent
    (retainedDeliveryRequestOperationId request)
    (retainedSourceReceiptRef source)
    (retainedDeliveryRequestTarget request)
    (retainedDeliveryRequestGeneration request)
    (retainedDeliveryRequestAttestationRef request)
    (retainedDestinationPublicKeyDigest (retainedDestinationPublicKey keyPair))
    (retainedDeliveryRequestDeadline request)

deliveryReceipt
  :: RetainedDeliveryIntent schema
  -> TargetWorkerReceipt
  -> Either Text (RetainedDeliveryReceipt schema)
deliveryReceipt intent workerReceipt = do
  if targetWorkerReceiptGeneration workerReceipt == retainedDeliveryTargetGeneration intent
    then Right ()
    else Left "Target receipt generation does not match retained delivery intent"
  commitment <-
    first
      (Text.pack . show)
      (mkRetainedMaterialRef (targetWorkerReceiptCommitment workerReceipt))
  first (Text.pack . show) $
    mkRetainedDeliveryReceipt
      (retainedDeliveryOperationId intent)
      (retainedDeliverySourceReceipt intent)
      (retainedDeliveryTarget intent)
      (retainedDeliveryTargetGeneration intent)
      (targetWorkerReceiptVaultVersion workerReceipt)
      commitment

unexpected :: (Show value) => Text -> value -> Text
unexpected phase value =
  "retained material " <> phase <> " transition refused: " <> Text.pack (show value)
