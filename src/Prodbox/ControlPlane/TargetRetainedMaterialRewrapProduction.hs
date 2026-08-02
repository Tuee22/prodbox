{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Production, schema-closed retained-home rewrap composition.
module Prodbox.ControlPlane.TargetRetainedMaterialRewrapProduction
  ( productionTargetRetainedMaterialRewrapBoundary
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationPublicKey
  , encodeRetainedDestinationEnvelope
  , mkRetainedDestinationPublicKey
  , retainedDestinationPublicKeyDigest
  )
import Prodbox.ControlPlane.RetainedMaterialWorker
  ( RetainedCustodyRewrapResult (..)
  , observeRetainedCustody
  , retainedCustodyDestinationReceipt
  , retainedCustodyRewrapEnvelopeDigest
  , retainedCustodyRewrapReceiptRef
  , rewrapRetainedCustody
  )
import Prodbox.ControlPlane.RetainedMaterialWorkerVault
  ( retainedCustodyVaultBoundary
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab, TargetSesSmtp)
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapBoundary (..)
  , TargetRetainedMaterialRewrapRequest (..)
  , TargetRetainedMaterialRewrapResponse (..)
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedCustodyObservation (..)
  , RetainedDeliveryIntent
  , RetainedMaterialSource
  , SRetainedMaterialSchema (..)
  , mkRetainedDeliveryIntent
  , mkRetainedMaterialRef
  , mkRetainedMaterialTarget
  , retainedMaterialRefText
  , retainedSourceCiphertextDigest
  , retainedSourceGeneration
  , retainedSourceReceiptRef
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Vault.Session (VaultSession)

productionTargetRetainedMaterialRewrapBoundary
  :: VaultSession
  -> Text
  -> TargetRetainedMaterialRewrapBoundary IO
productionTargetRetainedMaterialRewrapBoundary session targetIdentity =
  TargetRetainedMaterialRewrapBoundary dispatch
 where
  dispatch now request = case targetRetainedRewrapTarget request of
    TargetSesSmtp -> runFor SRetainedSesSmtpMaterial now request
    TargetAcmeEab -> runFor SRetainedAcmeEabMaterial now request
    _ -> pure (refused "target is not a retained-material schema")

  runFor
    :: forall schema
     . SRetainedMaterialSchema schema
    -> AuthorityTime
    -> TargetRetainedMaterialRewrapRequest
    -> IO TargetRetainedMaterialRewrapResponse
  runFor schema now request
    | authorityTimeFromMicros (targetRetainedRewrapDeadlineMicros request) <= now =
        pure (refused "retained-material delivery deadline elapsed")
    | otherwise = do
        observed <- observeRetainedCustody schema now (retainedCustodyVaultBoundary session schema)
        case observed of
          RetainedCustodyPresent source -> case prepare schema request source of
            Left detail -> pure (refused detail)
            Right (intent, destinationPublic) -> do
              result <-
                rewrapRetainedCustody
                  schema
                  (retainedCustodyVaultBoundary session schema)
                  source
                  intent
                  destinationPublic
              pure $ case result of
                Left err -> unavailable (Text.take 256 (Text.pack (show err)))
                Right rewrapped -> case encodeRetainedDestinationEnvelope
                  schema
                  (retainedCustodyDestinationEnvelope rewrapped) of
                  Left err -> unavailable (Text.take 256 (Text.pack (show err)))
                  Right envelope ->
                    let receipt = retainedCustodyDestinationReceipt rewrapped
                     in TargetRetainedMaterialRewrapped
                          envelope
                          (retainedMaterialRefText (retainedCustodyRewrapReceiptRef receipt))
                          ( targetValueDigestText
                              (retainedCustodyRewrapEnvelopeDigest receipt)
                          )
          RetainedCustodyPositivelyAbsent _ -> pure (refused "retained source is absent")
          RetainedCustodyDigestMismatch _ _ ->
            pure (unavailable "retained source digest mismatches metadata")
          RetainedCustodyCorrupt _ -> pure (unavailable "retained source is corrupt")
          RetainedCustodyUnobservable _ -> pure (unavailable "retained source is unobservable")

  prepare
    :: forall schema
     . SRetainedMaterialSchema schema
    -> TargetRetainedMaterialRewrapRequest
    -> RetainedMaterialSource schema
    -> Either
         Text
         (RetainedDeliveryIntent schema, RetainedDestinationPublicKey schema)
  prepare schema request source = do
    validateSource request source
    operation <- mkRetainedMaterialRef (targetRetainedRewrapOperationId request)
    attestation <- mkRetainedMaterialRef (targetRetainedRewrapAttestationRef request)
    generation <-
      first
        (Text.pack . show)
        (mkCredentialGeneration (targetRetainedRewrapTargetGeneration request))
    target <- mkRetainedMaterialTarget schema targetIdentity
    destinationPublic <-
      first
        (Text.pack . show)
        (mkRetainedDestinationPublicKey (targetRetainedRewrapDestinationPublicKey request))
    let intent =
          mkRetainedDeliveryIntent
            operation
            (retainedSourceReceiptRef source)
            target
            generation
            attestation
            (retainedDestinationPublicKeyDigest destinationPublic)
            (authorityTimeFromMicros (targetRetainedRewrapDeadlineMicros request))
    pure (intent, destinationPublic)

validateSource
  :: TargetRetainedMaterialRewrapRequest
  -> RetainedMaterialSource schema
  -> Either Text ()
validateSource request source = do
  expectedReceipt <- mkRetainedMaterialRef (targetRetainedRewrapExpectedSourceReceipt request)
  expectedDigest <-
    first
      (Text.pack . show)
      (mkTargetValueDigest (targetRetainedRewrapExpectedSourceDigest request))
  if retainedSourceReceiptRef source == expectedReceipt
    && credentialGenerationValue (retainedSourceGeneration source)
      == targetRetainedRewrapExpectedSourceGeneration request
    && retainedSourceVaultVersion source
      == targetRetainedRewrapExpectedSourceVaultVersion request
    && retainedSourceCiphertextDigest source == expectedDigest
    then Right ()
    else Left "retained source binding mismatch"

refused :: Text -> TargetRetainedMaterialRewrapResponse
refused = TargetRetainedMaterialRewrapRefused

unavailable :: Text -> TargetRetainedMaterialRewrapResponse
unavailable = TargetRetainedMaterialRewrapUnavailable
