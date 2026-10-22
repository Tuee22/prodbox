{-# LANGUAGE OverloadedStrings #-}

-- | The actual publication/Agent observer is the sole producer of the
-- transient credential-admission proof. Caller observations and wire bytes
-- cannot construct the proof consumed by the pure aggregate.
module Prodbox.ControlPlane.ProviderCredentialAdmissionEvidence
  ( ObservedProviderCredentialAdmission
  , ProviderCredentialAdmissionKind (..)
  , ProviderCredentialAdmissionEvidenceError (..)
  , observeProviderCredentialAdmission
  , providerCredentialMutationReservationForIntent
  , observedProviderCredentialAdmissionArchive
  , observedProviderCredentialAdmissionKind
  ) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Prodbox.ControlPlane.ProviderCredentialPublication
  ( ObservedAwsAdminProviderLineage
  , observedAwsAdminProviderLineageArchive
  , observedAwsAdminProviderLineagePermit
  , observedAwsAdminProviderLineageReceipt
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (..)
  , targetWorkerReceiptFromMaterialObservation
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint (TargetMaterialObservation)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.ControlPlane.TargetSecretWorker (decodeTargetWorkerReceipt)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderCredentialMutationReservation
  , mkProviderCredentialMutationReservation
  , mkProviderCredentialRevocationReceipt
  )
import Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence.Internal
  ( ObservedProviderCredentialAdmission (..)
  , ProviderCredentialAdmissionKind (..)
  , observedProviderCredentialAdmissionArchive
  , observedProviderCredentialAdmissionKind
  )
import Prodbox.Lifecycle.CleanupRun (cleanupDigestOfBytes)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceiptKind (..)
  , awsAdminWorkerReceiptKind
  , awsAdminWorkerReceiptTargetReadBack
  , encodeAwsAdminWorkerReceipt
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentTarget
  , signedAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , OperatorMaterialAction (..)
  )

data ProviderCredentialAdmissionEvidenceError
  = ProviderCredentialAdmissionClassMismatch
  | ProviderCredentialAdmissionActionMismatch
  | ProviderCredentialAdmissionReceiptInvalid
  | ProviderCredentialAdmissionAgentUnavailable
  | ProviderCredentialAdmissionTargetMissing
  | ProviderCredentialAdmissionTargetPresent
  | ProviderCredentialAdmissionTargetInvalid
  | ProviderCredentialAdmissionTargetMismatch
  deriving (Eq, Show)

observeProviderCredentialAdmission
  :: (Monad m)
  => TargetMaterialClient m
  -> ObservedAwsAdminProviderLineage
  -> m (Either ProviderCredentialAdmissionEvidenceError ObservedProviderCredentialAdmission)
observeProviderCredentialAdmission agent publication =
  case validatePublication of
    Left cause -> pure (Left cause)
    Right kind -> do
      observed <- observeRegisteredTargetMaterial agent target
      pure $ do
        metadata <- first (const ProviderCredentialAdmissionAgentUnavailable) observed
        confirmTarget kind metadata
        Right
          (ObservedProviderCredentialAdmission (observedAwsAdminProviderLineageArchive publication) kind)
 where
  permit = observedAwsAdminProviderLineagePermit publication
  receipt = observedAwsAdminProviderLineageReceipt publication
  intent = signedAwsAdminPermitIntent permit
  target = TargetAwsCredential AwsLifecycleProvider
  validatePublication = do
    unless
      ( awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential
          && awsAdminPermitIntentTarget intent == target
      )
      (Left ProviderCredentialAdmissionClassMismatch)
    first
      (const ProviderCredentialAdmissionReceiptInvalid)
      (validateAwsAdminWorkerReceiptForPermit permit receipt)
    case (awsAdminPermitIntentAction intent, awsAdminWorkerReceiptKind receipt) of
      (InstallOperatorMaterial, AwsAdminInstalled) -> Right ProviderCredentialAdmissionInstalled
      (RotateOperatorMaterial, AwsAdminInstalled) -> Right ProviderCredentialAdmissionInstalled
      (RevokeOperatorMaterial, AwsAdminRevoked) ->
        ProviderCredentialAdmissionRevoked
          <$> first
            (const ProviderCredentialAdmissionReceiptInvalid)
            ( mkProviderCredentialRevocationReceipt
                (cleanupDigestOfBytes (encodeAwsAdminWorkerReceipt receipt))
                (cleanupDigestOfBytes (awsAdminWorkerReceiptTargetReadBack receipt))
            )
      _ -> Left ProviderCredentialAdmissionActionMismatch
  confirmTarget kind metadata = case kind of
    ProviderCredentialAdmissionInstalled -> confirmInstalled metadata
    ProviderCredentialAdmissionRevoked _ -> case metadata of
      Nothing -> Right ()
      Just _ -> Left ProviderCredentialAdmissionTargetPresent
  confirmInstalled
    :: Maybe TargetMaterialObservation -> Either ProviderCredentialAdmissionEvidenceError ()
  confirmInstalled observed = do
    metadata <- maybe (Left ProviderCredentialAdmissionTargetMissing) Right observed
    actual <-
      first
        (const ProviderCredentialAdmissionTargetInvalid)
        (targetWorkerReceiptFromMaterialObservation target metadata)
    expected <-
      first
        (const ProviderCredentialAdmissionReceiptInvalid)
        (decodeTargetWorkerReceipt (awsAdminWorkerReceiptTargetReadBack receipt))
    unless (actual == expected) (Left ProviderCredentialAdmissionTargetMismatch)

providerCredentialMutationReservationForIntent
  :: AwsAdminPermitIntent
  -> Either ProviderCredentialAdmissionEvidenceError ProviderCredentialMutationReservation
providerCredentialMutationReservationForIntent intent = do
  unless
    (awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential)
    (Left ProviderCredentialAdmissionClassMismatch)
  first
    (const ProviderCredentialAdmissionReceiptInvalid)
    ( mkProviderCredentialMutationReservation
        (awsAdminPermitIntentAction intent)
        (awsAdminPermitIntentOperationId intent)
        (awsAdminPermitIntentGeneration intent)
        (awsAdminPermitIntentRequestDigest intent)
    )
