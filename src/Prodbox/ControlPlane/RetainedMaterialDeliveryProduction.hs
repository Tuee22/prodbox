{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Ciphertext-only Authority composition from retained-home custody to one
-- selected Target worker.
module Prodbox.ControlPlane.RetainedMaterialDeliveryProduction
  ( RetainedMaterialDeliveryResult (..)
  , productionRetainedMaterialDelivery
  , productionRetainedMaterialDeliveryWithKeyPair
  , retainedTargetIntentReceiptDigest
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationKeyPair
  , decodeRetainedDestinationEnvelope
  , encodeRetainedDestinationOpening
  , generateRetainedDestinationKeyPair
  , retainedDestinationPublicKey
  , retainedDestinationPublicKeyBytes
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab, TargetSesSmtp)
  )
import Prodbox.ControlPlane.TargetMaterializationProduction
  ( ProductionTargetMaterializationBoundary
  , productionRewrappedTargetMaterializer
  )
import Prodbox.ControlPlane.TargetMaterializationWorkflow
  ( TargetMaterializationRequest (..)
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapClient
  ( TargetRetainedMaterialRewrapClient
  , requestTargetRetainedMaterialRewrap
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapRequest (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerImageDigest
  , TargetWorkerReceipt
  , targetWorkerSchemaForTarget
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedDeliveryIntent
  , RetainedMaterialRef
  , RetainedMaterialSource
  , SRetainedMaterialSchema (..)
  , mkRetainedMaterialRef
  , retainedDeliveryAttestationRef
  , retainedDeliveryDeadline
  , retainedDeliveryOperationId
  , retainedDeliveryTargetGeneration
  , retainedMaterialRefText
  , retainedSourceCiphertextDigest
  , retainedSourceGeneration
  , retainedSourceReceiptRef
  , retainedSourceVaultVersion
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetValueDigest
  , credentialGenerationValue
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )

data RetainedMaterialDeliveryResult schema = RetainedMaterialDeliveryResult
  { retainedMaterialDeliveryTargetReceipt :: !TargetWorkerReceipt
  , retainedMaterialDeliveryRewrapReceipt :: !RetainedMaterialRef
  , retainedMaterialDeliveryEnvelopeDigest :: !TargetValueDigest
  }
  deriving stock (Eq, Show)

productionRetainedMaterialDelivery
  :: SRetainedMaterialSchema schema
  -> ProductionTargetMaterializationBoundary
  -> TargetRetainedMaterialRewrapClient IO
  -> TargetAgentIdentity
  -> TargetWorkerImageDigest
  -> AuthorityTime
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
  -> IO (Either Text (RetainedMaterialDeliveryResult schema))
productionRetainedMaterialDelivery schema boundary rewrapClient agent image now source intent
  | now > retainedDeliveryDeadline intent =
      pure (Left "retained material delivery deadline elapsed")
  | otherwise = do
      keyPair <- generateRetainedDestinationKeyPair
      productionRetainedMaterialDeliveryWithKeyPair
        schema
        boundary
        rewrapClient
        agent
        image
        now
        keyPair
        source
        intent

productionRetainedMaterialDeliveryWithKeyPair
  :: SRetainedMaterialSchema schema
  -> ProductionTargetMaterializationBoundary
  -> TargetRetainedMaterialRewrapClient IO
  -> TargetAgentIdentity
  -> TargetWorkerImageDigest
  -> AuthorityTime
  -> RetainedDestinationKeyPair schema
  -> RetainedMaterialSource schema
  -> RetainedDeliveryIntent schema
  -> IO (Either Text (RetainedMaterialDeliveryResult schema))
productionRetainedMaterialDeliveryWithKeyPair schema boundary rewrapClient agent image now keyPair source intent
  | now > retainedDeliveryDeadline intent =
      pure (Left "retained material delivery deadline elapsed")
  | otherwise = do
      let target = schemaTarget schema
          publicKey = retainedDestinationPublicKey keyPair
          request =
            TargetRetainedMaterialRewrapRequest
              { targetRetainedRewrapTarget = target
              , targetRetainedRewrapOperationId =
                  retainedMaterialRefText (retainedDeliveryOperationId intent)
              , targetRetainedRewrapExpectedSourceReceipt =
                  retainedMaterialRefText (retainedSourceReceiptRef source)
              , targetRetainedRewrapExpectedSourceGeneration =
                  credentialGenerationValue (retainedSourceGeneration source)
              , targetRetainedRewrapExpectedSourceVaultVersion =
                  retainedSourceVaultVersion source
              , targetRetainedRewrapExpectedSourceDigest =
                  targetValueDigestText (retainedSourceCiphertextDigest source)
              , targetRetainedRewrapTargetGeneration =
                  credentialGenerationValue (retainedDeliveryTargetGeneration intent)
              , targetRetainedRewrapAttestationRef =
                  retainedMaterialRefText (retainedDeliveryAttestationRef intent)
              , targetRetainedRewrapDestinationPublicKey =
                  retainedDestinationPublicKeyBytes publicKey
              , targetRetainedRewrapDeadlineMicros =
                  authorityTimeMicros (retainedDeliveryDeadline intent)
              }
      rewrapped <- requestTargetRetainedMaterialRewrap rewrapClient request
      case rewrapped of
        Left err -> pure (Left (Text.take 256 (Text.pack (show err))))
        Right (envelopeBytes, receiptText, digestText) ->
          case prepareOpening schema keyPair envelopeBytes receiptText digestText of
            Left detail -> pure (Left detail)
            Right (opening, receiptRef, envelopeDigest) -> do
              workerSchema <- pure (first (Text.take 256 . Text.pack . show) (targetWorkerSchemaForTarget target))
              case workerSchema of
                Left detail -> pure (Left detail)
                Right ingressSchema -> do
                  case retainedTargetIntentReceiptDigest intent of
                    Left detail -> pure (Left detail)
                    Right receiptDigest -> do
                      let operationText = retainedMaterialRefText (retainedDeliveryOperationId intent)
                          materialization =
                            TargetMaterializationRequest
                              { targetMaterializationTarget = target
                              , targetMaterializationAgentIdentity = agent
                              , targetMaterializationGeneration = retainedDeliveryTargetGeneration intent
                              , targetMaterializationReceiptDigest = receiptDigest
                              , targetMaterializationOperationId = operationText
                              , targetMaterializationActionIndex = 0
                              , targetMaterializationIdempotencyKey = operationText
                              , targetMaterializationIngressSchema = ingressSchema
                              , targetMaterializationWorkerImage = image
                              , targetMaterializationNow = now
                              }
                      delivered <-
                        productionRewrappedTargetMaterializer boundary materialization opening
                      pure $ do
                        targetReceipt <- delivered
                        Right
                          RetainedMaterialDeliveryResult
                            { retainedMaterialDeliveryTargetReceipt = targetReceipt
                            , retainedMaterialDeliveryRewrapReceipt = receiptRef
                            , retainedMaterialDeliveryEnvelopeDigest = envelopeDigest
                            }

-- | The retained outbox's attestation is the digest of the prepared custody
-- receipt authorized by the Target-intent issuer. The rewrapped opening has a
-- separate worker-material digest and cannot substitute for that receipt.
retainedTargetIntentReceiptDigest
  :: RetainedDeliveryIntent schema -> Either Text TargetValueDigest
retainedTargetIntentReceiptDigest =
  first (Text.pack . show)
    . mkTargetValueDigest
    . retainedMaterialRefText
    . retainedDeliveryAttestationRef

prepareOpening
  :: SRetainedMaterialSchema schema
  -> RetainedDestinationKeyPair schema
  -> ByteString
  -> Text
  -> Text
  -> Either Text (ByteString, RetainedMaterialRef, TargetValueDigest)
prepareOpening schema keyPair envelopeBytes receiptText digestText = do
  receiptRef <- retainedRef receiptText
  responseDigest <- first (Text.pack . show) (mkTargetValueDigest digestText)
  let actualDigest = sha256TargetValueDigest envelopeBytes
  if responseDigest == actualDigest
    then Right ()
    else Left "retained rewrap envelope digest mismatch"
  envelope <-
    first
      (Text.pack . show)
      (decodeRetainedDestinationEnvelope schema envelopeBytes)
  opening <-
    first
      (Text.pack . show)
      (encodeRetainedDestinationOpening schema keyPair envelope)
  pure (opening, receiptRef, actualDigest)
 where
  retainedRef =
    first (Text.pack . show)
      . mkRetainedMaterialRef

schemaTarget :: SRetainedMaterialSchema schema -> TargetSecretId
schemaTarget schema = case schema of
  SRetainedSesSmtpMaterial -> TargetSesSmtp
  SRetainedAcmeEabMaterial -> TargetAcmeEab
