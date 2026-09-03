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
import Prodbox.Capacity.RetainedMaterialDeliveryBudget
  ( retainedMaterialDeliveryOperationLifetimeMicros
  )
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
  , RetainedMaterialRefusal (..)
  , RetainedMaterialSource
  , RetainedMaterialTarget
  , mkRetainedDeliveryIntent
  , mkRetainedDeliveryReceipt
  , mkRetainedMaterialRef
  , mkRetainedSealIntent
  , retainedDeliveryAttestationRef
  , retainedDeliveryDeadline
  , retainedDeliveryOperationId
  , retainedDeliveryReceiptGeneration
  , retainedDeliveryReceiptOperationId
  , retainedDeliveryReceiptSource
  , retainedDeliveryReceiptTarget
  , retainedDeliverySourceReceipt
  , retainedDeliverySuccessorOperationId
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
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
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
  prepared <- ensureRetainedMaterialCurrentSource repository now source
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
    let intent = deliveryIntent now keyPair request source
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
            keyPair <- generateRetainedDestinationKeyPair
            let successor = successorDeliveryIntent now keyPair source intent
                replacement =
                  ReplaceExpiredRetainedMaterialDelivery
                    (retainedDeliveryOperationId intent)
                    now
                    successor
            replaced <- applyRetainedMaterialCommand repository replacement
            confirmed <- case replaced of
              Left _ -> applyRetainedMaterialCommand repository replacement
              Right decision -> pure (Right decision)
            case confirmed of
              Right (RetainedDeliveryReplaced _ persisted)
                | persisted == successor -> execute successor keyPair
              Right (RetainedDeliveryAlreadyReplaced persisted)
                | persisted == successor -> execute successor keyPair
              Right (RetainedMaterialRefused refusal) ->
                pure (Left ("retained delivery successor refused: " <> Text.pack (show refusal)))
              Right decision -> pure (Left (unexpected "successor" decision))
              Left detail -> pure (Left detail)

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
    find pendingMatchesRequest (retainedMaterialPendingDeliveries aggregate)

  completedForOperation aggregate =
    find completedMatchesRequest (retainedMaterialCompletedDeliveries aggregate)

  pendingMatchesRequest intent =
    operationBelongsToRequest (retainedDeliveryOperationId intent)
      && pendingSourceMatchesRequest intent
      && retainedDeliveryTarget intent == retainedDeliveryRequestTarget request
      && retainedDeliveryTargetGeneration intent == retainedDeliveryRequestGeneration request
      && retainedDeliveryAttestationRef intent == retainedDeliveryRequestAttestationRef request

  pendingSourceMatchesRequest intent =
    retainedDeliverySourceReceipt intent == retainedSourceReceiptRef source
      || ( retainedDeliverySourceReceipt intent == retainedSourceOperationId source
             && retainedSourceReceiptRef source /= retainedSourceOperationId source
         )

  completedMatchesRequest receipt =
    operationBelongsToRequest (retainedDeliveryReceiptOperationId receipt)
      && retainedDeliveryReceiptSource receipt == retainedSourceReceiptRef source
      && retainedDeliveryReceiptTarget receipt == retainedDeliveryRequestTarget request
      && retainedDeliveryReceiptGeneration receipt == retainedDeliveryRequestGeneration request

  operationBelongsToRequest operationId =
    operationId `elem` take retainedDeliverySuccessorSearchBound operationLineage

  operationLineage =
    iterate retainedDeliverySuccessorOperationId (retainedDeliveryRequestOperationId request)

ensureRetainedMaterialCurrentSource
  :: RetainedMaterialRepository schema IO revision
  -> AuthorityTime
  -> RetainedMaterialSource schema
  -> IO (Either Text ())
ensureRetainedMaterialCurrentSource repository now source = do
  observed <- readRetainedMaterialSnapshot repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot -> case retainedMaterialCurrent (retainedMaterialSnapshotAggregate snapshot) of
      Just current
        | sourceIdentityMatches current source -> pure (Right ())
        | otherwise -> correctLegacyOrBegin
      Nothing -> beginSource
 where
  correctLegacyOrBegin = do
    corrected <-
      applyRetainedMaterialCommand
        repository
        (ObserveLegacyRetainedMaterialSourceReceiptCorrection source)
    confirmed <- case corrected of
      Left _ ->
        applyRetainedMaterialCommand
          repository
          (ObserveLegacyRetainedMaterialSourceReceiptCorrection source)
      Right decision -> pure (Right decision)
    case confirmed of
      Left detail -> pure (Left detail)
      Right (RetainedLegacySourceReceiptCorrected _ confirmedSource)
        | sourceIdentityMatches confirmedSource source -> pure (Right ())
      Right (RetainedLegacySourceReceiptAlreadyCorrected confirmedSource)
        | sourceIdentityMatches confirmedSource source -> pure (Right ())
      Right
        ( RetainedMaterialRefused
            RetainedLegacySourceReceiptCorrectionMismatch
          ) -> beginSource
      Right (RetainedMaterialRefused refusal) ->
        pure (Left ("retained source correction refused: " <> Text.pack (show refusal)))
      Right decision -> pure (Left (unexpected "source-correction" decision))

  beginSource = do
    let sealIntent =
          mkRetainedSealIntent
            (retainedSourceOperationId source)
            (retainedSourceGeneration source)
            (retainedSourceReceiptRef source)
            (retainedSourceCiphertextDigest source)
            (freshRetainedMaterialDeadline now)
            (freshRetainedMaterialDeadline now)
    case sealIntent of
      Left detail -> pure (Left detail)
      Right intent -> do
        begun <-
          applyRetainedMaterialCommand repository (BeginRetainedMaterialSeal now intent)
        case begun of
          Left detail -> pure (Left detail)
          Right (RetainedSealBegun _) -> commitSource
          Right (RetainedSealAlreadyBegun _) -> commitSource
          Right (RetainedSealAlreadyCommitted confirmed)
            | sourceIdentityMatches confirmed source -> pure (Right ())
          Right (RetainedSealAlreadyCommitted _) ->
            pure (Left "retained source replay did not match the exact current receipt")
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
  :: AuthorityTime
  -> RetainedDestinationKeyPair schema
  -> RetainedMaterialDeliveryRequest schema
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
deliveryIntent now keyPair request source =
  mkRetainedDeliveryIntent
    (retainedDeliveryRequestOperationId request)
    (retainedSourceReceiptRef source)
    (retainedDeliveryRequestTarget request)
    (retainedDeliveryRequestGeneration request)
    (retainedDeliveryRequestAttestationRef request)
    (retainedDestinationPublicKeyDigest (retainedDestinationPublicKey keyPair))
    (freshRetainedMaterialDeadline now)

successorDeliveryIntent
  :: AuthorityTime
  -> RetainedDestinationKeyPair schema
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
  -> RetainedDeliveryIntent schema
successorDeliveryIntent now keyPair source predecessor =
  mkRetainedDeliveryIntent
    (retainedDeliverySuccessorOperationId (retainedDeliveryOperationId predecessor))
    (retainedSourceReceiptRef source)
    (retainedDeliveryTarget predecessor)
    (retainedDeliveryTargetGeneration predecessor)
    (retainedDeliveryAttestationRef predecessor)
    (retainedDestinationPublicKeyDigest (retainedDestinationPublicKey keyPair))
    (freshRetainedMaterialDeadline now)

freshRetainedMaterialDeadline :: AuthorityTime -> AuthorityTime
freshRetainedMaterialDeadline now =
  authorityTimeFromMicros
    (authorityTimeMicros now + retainedMaterialDeliveryOperationLifetimeMicros)

retainedDeliverySuccessorSearchBound :: Int
retainedDeliverySuccessorSearchBound = 257

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
