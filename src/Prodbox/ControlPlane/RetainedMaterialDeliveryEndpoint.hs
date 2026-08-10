{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for the two retained material
-- delivery schemas.  The wire carries only opaque source evidence and Target
-- coordinates; repository revisions and ephemeral private keys remain inside
-- the Authority composition.
module Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( RetainedMaterialDeliveryWireRequest (..)
  , RetainedMaterialDeliveryWireFields (..)
  , RetainedMaterialDeliveryWireResponse (..)
  , RetainedMaterialDeliveryBoundary (..)
  , retainedMaterialDeliveryWireRequest
  , retainedMaterialDeliveryMaximumBytes
  , retainedMaterialDeliveryAuthenticatedHandler
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryCoordinator qualified as Coordinator
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleRetainedMaterialDelivery)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedDeliveryReceipt
  , RetainedMaterialSchema (..)
  , RetainedMaterialSource
  , SRetainedMaterialSchema (..)
  , mkRetainedMaterialRef
  , mkRetainedMaterialSource
  , mkRetainedMaterialTarget
  , retainedDeliveryReceiptCommitmentRef
  , retainedDeliveryReceiptGeneration
  , retainedDeliveryReceiptOperationId
  , retainedDeliveryReceiptSource
  , retainedDeliveryReceiptTarget
  , retainedDeliveryReceiptTargetVersion
  , retainedMaterialRefText
  , retainedMaterialTargetText
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
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

data RetainedMaterialDeliveryWireRequest
  = DeliverRetainedSesSmtp !RetainedMaterialDeliveryWireFields
  | DeliverRetainedAcmeEab !RetainedMaterialDeliveryWireFields
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedMaterialDeliveryWireFields = RetainedMaterialDeliveryWireFields
  { wireRetainedSourceGeneration :: !Natural
  , wireRetainedSourceOperationId :: !Text
  , wireRetainedSourceReceipt :: !Text
  , wireRetainedSourceCiphertextDigest :: !Text
  , wireRetainedSourceCommitment :: !Text
  , wireRetainedSourceVaultVersion :: !Natural
  , wireRetainedDeliveryOperationId :: !Text
  , wireRetainedDeliveryTarget :: !Text
  , wireRetainedDeliveryGeneration :: !Natural
  , wireRetainedDeliveryAttestation :: !Text
  , wireRetainedDeliveryDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedMaterialDeliveryWireResponse
  = RetainedMaterialDeliveryApplied
      { wireRetainedReceiptOperationId :: !Text
      , wireRetainedReceiptSource :: !Text
      , wireRetainedReceiptTarget :: !Text
      , wireRetainedReceiptGeneration :: !Natural
      , wireRetainedReceiptTargetVersion :: !Natural
      , wireRetainedReceiptCommitment :: !Text
      }
  | RetainedMaterialDeliveryRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RetainedMaterialDeliveryBoundary m = RetainedMaterialDeliveryBoundary
  { deliverRetainedSesSmtp
      :: AuthorityTime
      -> RetainedMaterialSource 'RetainedSesSmtpMaterial
      -> Coordinator.RetainedMaterialDeliveryRequest 'RetainedSesSmtpMaterial
      -> m (Either Text (RetainedDeliveryReceipt 'RetainedSesSmtpMaterial))
  , deliverRetainedAcmeEab
      :: AuthorityTime
      -> RetainedMaterialSource 'RetainedAcmeEabMaterial
      -> Coordinator.RetainedMaterialDeliveryRequest 'RetainedAcmeEabMaterial
      -> m (Either Text (RetainedDeliveryReceipt 'RetainedAcmeEabMaterial))
  }

retainedMaterialDeliveryMaximumBytes :: Int
retainedMaterialDeliveryMaximumBytes = 32 * 1024

retainedMaterialDeliveryWireRequest
  :: SRetainedMaterialSchema schema
  -> RetainedMaterialSource schema
  -> Text
  -> Text
  -> Natural
  -> Text
  -> AuthorityTime
  -> RetainedMaterialDeliveryWireRequest
retainedMaterialDeliveryWireRequest schema source operationId target generation attestation deadline =
  case schema of
    SRetainedSesSmtpMaterial -> DeliverRetainedSesSmtp fields
    SRetainedAcmeEabMaterial -> DeliverRetainedAcmeEab fields
 where
  fields =
    RetainedMaterialDeliveryWireFields
      { wireRetainedSourceGeneration =
          credentialGenerationValue (retainedSourceGeneration source)
      , wireRetainedSourceOperationId =
          retainedMaterialRefText (retainedSourceOperationId source)
      , wireRetainedSourceReceipt =
          retainedMaterialRefText (retainedSourceReceiptRef source)
      , wireRetainedSourceCiphertextDigest =
          targetValueDigestText (retainedSourceCiphertextDigest source)
      , wireRetainedSourceCommitment =
          retainedMaterialRefText (retainedSourceCommitmentRef source)
      , wireRetainedSourceVaultVersion = retainedSourceVaultVersion source
      , wireRetainedDeliveryOperationId = operationId
      , wireRetainedDeliveryTarget = target
      , wireRetainedDeliveryGeneration = generation
      , wireRetainedDeliveryAttestation = attestation
      , wireRetainedDeliveryDeadlineMicros = authorityTimeMicros deadline
      }

retainedMaterialDeliveryAuthenticatedHandler
  :: (Monad m)
  => Int
  -> m (Either Text AuthorityTime)
  -> RetainedMaterialDeliveryBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
retainedMaterialDeliveryAuthenticatedHandler maximumBytes observeNow boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleRetainedMaterialDelivery -> do
      response <- case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (RetainedMaterialDeliveryRefused "request-codec-rejected")
        Right request -> do
          nowResult <- observeNow
          case nowResult of
            Left _ -> pure (RetainedMaterialDeliveryRefused "authority-clock-unavailable")
            Right now -> serve now request
      pure (Just (responseStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

  serve now request = case request of
    DeliverRetainedSesSmtp fields ->
      withRequest SRetainedSesSmtpMaterial now fields (deliverRetainedSesSmtp boundary)
    DeliverRetainedAcmeEab fields ->
      withRequest SRetainedAcmeEabMaterial now fields (deliverRetainedAcmeEab boundary)

withRequest
  :: (Monad m)
  => SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedMaterialDeliveryWireFields
  -> ( AuthorityTime
       -> RetainedMaterialSource schema
       -> Coordinator.RetainedMaterialDeliveryRequest schema
       -> m (Either Text (RetainedDeliveryReceipt schema))
     )
  -> m RetainedMaterialDeliveryWireResponse
withRequest schema now fields deliver = case decodeFields schema now fields of
  Left detail -> pure (RetainedMaterialDeliveryRefused detail)
  Right (source, request) -> do
    result <- deliver now source request
    pure $ either RetainedMaterialDeliveryRefused appliedResponse result

decodeFields
  :: SRetainedMaterialSchema schema
  -> AuthorityTime
  -> RetainedMaterialDeliveryWireFields
  -> Either
       Text
       ( RetainedMaterialSource schema
       , Coordinator.RetainedMaterialDeliveryRequest schema
       )
decodeFields schema now fields = do
  sourceGeneration <- value (mkCredentialGeneration (wireRetainedSourceGeneration fields))
  sourceOperation <- mkRetainedMaterialRef (wireRetainedSourceOperationId fields)
  sourceReceipt <- mkRetainedMaterialRef (wireRetainedSourceReceipt fields)
  sourceDigest <- value (mkTargetValueDigest (wireRetainedSourceCiphertextDigest fields))
  sourceCommitment <- mkRetainedMaterialRef (wireRetainedSourceCommitment fields)
  source <-
    mkRetainedMaterialSource
      sourceGeneration
      sourceOperation
      sourceReceipt
      sourceDigest
      sourceCommitment
      (wireRetainedSourceVaultVersion fields)
      now
  operationId <- mkRetainedMaterialRef (wireRetainedDeliveryOperationId fields)
  target <- mkRetainedMaterialTarget schema (wireRetainedDeliveryTarget fields)
  generation <- value (mkCredentialGeneration (wireRetainedDeliveryGeneration fields))
  attestation <- mkRetainedMaterialRef (wireRetainedDeliveryAttestation fields)
  pure
    ( source
    , Coordinator.RetainedMaterialDeliveryRequest
        { Coordinator.retainedDeliveryRequestOperationId = operationId
        , Coordinator.retainedDeliveryRequestTarget = target
        , Coordinator.retainedDeliveryRequestGeneration = generation
        , Coordinator.retainedDeliveryRequestAttestationRef = attestation
        , Coordinator.retainedDeliveryRequestDeadline =
            authorityTimeFromMicros (wireRetainedDeliveryDeadlineMicros fields)
        }
    )
 where
  value = first (Text.pack . show)

appliedResponse
  :: RetainedDeliveryReceipt schema -> RetainedMaterialDeliveryWireResponse
appliedResponse receipt =
  RetainedMaterialDeliveryApplied
    { wireRetainedReceiptOperationId =
        retainedMaterialRefText (retainedDeliveryReceiptOperationId receipt)
    , wireRetainedReceiptSource =
        retainedMaterialRefText (retainedDeliveryReceiptSource receipt)
    , wireRetainedReceiptTarget =
        retainedMaterialTargetText (retainedDeliveryReceiptTarget receipt)
    , wireRetainedReceiptGeneration =
        credentialGenerationValue (retainedDeliveryReceiptGeneration receipt)
    , wireRetainedReceiptTargetVersion = retainedDeliveryReceiptTargetVersion receipt
    , wireRetainedReceiptCommitment =
        retainedMaterialRefText (retainedDeliveryReceiptCommitmentRef receipt)
    }

responseStatus :: RetainedMaterialDeliveryWireResponse -> ReplyStatus
responseStatus response = case response of
  RetainedMaterialDeliveryApplied {} -> ReplyOk
  RetainedMaterialDeliveryRefused _ -> ReplyConflict

responseBody :: RetainedMaterialDeliveryWireResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse
