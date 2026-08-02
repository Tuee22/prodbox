{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Credential-Provisioner-specific, closed material handoff boundary.  The
-- Provisioner never receives an arbitrary Vault coordinate or field map.  A
-- production implementation must be an attested one-shot worker; long-lived
-- control-plane transports are deliberately not adapted here.
module Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( CreatedAwsAccessKey
  , TargetMaterialValueError (..)
  , mkCreatedAwsAccessKey
  , createdAwsAccessKeyIdText
  , ProvisionedTargetMaterial
  , mkAwsCredentialMaterial
  , deriveSesSmtpSource
  , mkAcmeEabSource
  , provisionedTargetMaterialTarget
  , provisionedTargetMaterialGeneration
  , withProvisionedTargetMaterial
  , TargetMaterialHandoff
  , mkTargetMaterialHandoff
  , targetMaterialHandoffTarget
  , targetMaterialHandoffGeneration
  , withTargetMaterialHandoff
  , TargetMaterialReceipt
  , mkTargetMaterialReceipt
  , targetMaterialReceiptTarget
  , targetMaterialReceiptGeneration
  , targetMaterialReceiptReadBackVersion
  , TargetMaterialClient
  , mkTargetMaterialClient
  , TargetMaterialClientError (..)
  , handoffTargetMaterialWithReadBack
  )
where

import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , CredentialTarget (..)
  , OperatorMaterialIngressSchema (..)
  , OperatorMaterialPermit
  , OperatorMaterialPermitId
  , awsCredentialDescriptor
  , awsCredentialDescriptorTarget
  , operatorMaterialPermitId
  , operatorMaterialPermitRequest
  , operatorMaterialPermitRequestDigest
  , operatorMaterialRequestGeneration
  , operatorMaterialRequestTarget
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  )
import Prodbox.Ses.SmtpPassword (derivedSesSmtpPassword)

data CreatedAwsAccessKey = CreatedAwsAccessKey !Text !Text

data TargetMaterialValueError
  = TargetMaterialFieldEmpty !Text
  | TargetMaterialFieldTooLong !Text !Int !Int
  | TargetMaterialFieldContainsControl !Text
  | SesSmtpMustUseDerivedSource
  | TargetMaterialClassMismatch
  | TargetMaterialGenerationMismatch
  deriving (Eq, Show)

mkCreatedAwsAccessKey
  :: Text -> Text -> Either TargetMaterialValueError CreatedAwsAccessKey
mkCreatedAwsAccessKey keyId secret =
  CreatedAwsAccessKey
    <$> validateField "access key ID" 256 keyId
    <*> validateField "secret access key" 2048 secret

createdAwsAccessKeyIdText :: CreatedAwsAccessKey -> Text
createdAwsAccessKeyIdText (CreatedAwsAccessKey keyId _) = keyId

data
  ProvisionedTargetMaterial
    (schema :: OperatorMaterialIngressSchema)
  where
  AwsCredentialSource
    :: !AwsCredentialClass
    -> !Text
    -> !Text
    -> !Text
    -> !CredentialGeneration
    -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
  SesSmtpSource
    :: !Text
    -> !Text
    -> !Text
    -> !CredentialGeneration
    -> ProvisionedTargetMaterial 'AwsAdminProvisioningIngress
  AcmeEabSource
    :: !Text
    -> !Text
    -> !CredentialGeneration
    -> ProvisionedTargetMaterial 'ExternalAcmeEabIngress

mkAwsCredentialMaterial
  :: AwsCredentialClass
  -> Text
  -> CredentialGeneration
  -> CreatedAwsAccessKey
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'AwsAdminProvisioningIngress)
mkAwsCredentialMaterial credentialClass region generation created = case credentialClass of
  SesSmtpRetainedCustodyCredential -> Left SesSmtpMustUseDerivedSource
  _ -> do
    validRegion <- validateField "AWS region" 128 region
    case created of
      CreatedAwsAccessKey keyId secret ->
        pure (AwsCredentialSource credentialClass keyId secret validRegion generation)

deriveSesSmtpSource
  :: Text
  -> CredentialGeneration
  -> CreatedAwsAccessKey
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'AwsAdminProvisioningIngress)
deriveSesSmtpSource region generation created = do
  validRegion <- validateField "AWS region" 128 region
  case created of
    CreatedAwsAccessKey keyId secret ->
      pure
        ( SesSmtpSource
            keyId
            (derivedSesSmtpPassword validRegion secret)
            validRegion
            generation
        )

mkAcmeEabSource
  :: Text
  -> Text
  -> CredentialGeneration
  -> Either
       TargetMaterialValueError
       (ProvisionedTargetMaterial 'ExternalAcmeEabIngress)
mkAcmeEabSource keyId hmacKey generation =
  AcmeEabSource
    <$> validateField "ACME EAB key ID" 1024 keyId
    <*> validateField "ACME EAB HMAC key" 4096 hmacKey
    <*> pure generation

provisionedTargetMaterialTarget
  :: ProvisionedTargetMaterial schema -> CredentialTarget
provisionedTargetMaterialTarget material = case material of
  AwsCredentialSource credentialClass _ _ _ _ ->
    awsCredentialDescriptorTarget (awsCredentialDescriptor credentialClass)
  SesSmtpSource {} -> RetainedHomeSesSmtpSourceTarget
  AcmeEabSource {} -> RetainedHomeAcmeEabSourceTarget

provisionedTargetMaterialGeneration
  :: ProvisionedTargetMaterial schema -> CredentialGeneration
provisionedTargetMaterialGeneration material = case material of
  AwsCredentialSource _ _ _ _ generation -> generation
  SesSmtpSource _ _ _ generation -> generation
  AcmeEabSource _ _ generation -> generation

withProvisionedTargetMaterial
  :: ProvisionedTargetMaterial schema
  -> (AwsCredentialClass -> Text -> Text -> Text -> CredentialGeneration -> result)
  -> (Text -> Text -> Text -> CredentialGeneration -> result)
  -> (Text -> Text -> CredentialGeneration -> result)
  -> result
withProvisionedTargetMaterial material onAws onSmtp onEab = case material of
  AwsCredentialSource credentialClass keyId secret region generation ->
    onAws credentialClass keyId secret region generation
  SesSmtpSource username password region generation ->
    onSmtp username password region generation
  AcmeEabSource keyId hmacKey generation -> onEab keyId hmacKey generation

data TargetMaterialHandoff schema = TargetMaterialHandoff
  { internalTargetMaterialHandoffPermitId :: !OperatorMaterialPermitId
  , internalTargetMaterialHandoffRequestDigest :: !TargetValueDigest
  , internalTargetMaterialHandoffTarget :: !CredentialTarget
  , internalTargetMaterialHandoffGeneration :: !CredentialGeneration
  , internalTargetMaterialHandoffPayload :: !(ProvisionedTargetMaterial schema)
  }

mkTargetMaterialHandoff
  :: OperatorMaterialPermit schema
  -> ProvisionedTargetMaterial schema
  -> Either TargetMaterialValueError (TargetMaterialHandoff schema)
mkTargetMaterialHandoff permit material
  | operatorMaterialRequestTarget request /= provisionedTargetMaterialTarget material =
      Left TargetMaterialClassMismatch
  | operatorMaterialRequestGeneration request /= provisionedTargetMaterialGeneration material =
      Left TargetMaterialGenerationMismatch
  | otherwise =
      Right
        TargetMaterialHandoff
          { internalTargetMaterialHandoffPermitId = operatorMaterialPermitId permit
          , internalTargetMaterialHandoffRequestDigest = operatorMaterialPermitRequestDigest permit
          , internalTargetMaterialHandoffTarget = provisionedTargetMaterialTarget material
          , internalTargetMaterialHandoffGeneration = provisionedTargetMaterialGeneration material
          , internalTargetMaterialHandoffPayload = material
          }
 where
  request = operatorMaterialPermitRequest permit

targetMaterialHandoffTarget :: TargetMaterialHandoff schema -> CredentialTarget
targetMaterialHandoffTarget = internalTargetMaterialHandoffTarget

targetMaterialHandoffGeneration
  :: TargetMaterialHandoff schema -> CredentialGeneration
targetMaterialHandoffGeneration = internalTargetMaterialHandoffGeneration

withTargetMaterialHandoff
  :: TargetMaterialHandoff schema
  -> ( OperatorMaterialPermitId
       -> TargetValueDigest
       -> CredentialTarget
       -> CredentialGeneration
       -> ProvisionedTargetMaterial schema
       -> result
     )
  -> result
withTargetMaterialHandoff handoff consume =
  consume
    (internalTargetMaterialHandoffPermitId handoff)
    (internalTargetMaterialHandoffRequestDigest handoff)
    (internalTargetMaterialHandoffTarget handoff)
    (internalTargetMaterialHandoffGeneration handoff)
    (internalTargetMaterialHandoffPayload handoff)

data TargetMaterialReceipt = TargetMaterialReceipt
  { internalTargetMaterialReceiptTarget :: !CredentialTarget
  , internalTargetMaterialReceiptGeneration :: !CredentialGeneration
  , internalTargetMaterialReceiptReadBackVersion :: !Natural
  }
  deriving (Eq, Show)

mkTargetMaterialReceipt
  :: CredentialTarget -> CredentialGeneration -> Natural -> TargetMaterialReceipt
mkTargetMaterialReceipt target generation readBackVersion =
  TargetMaterialReceipt
    { internalTargetMaterialReceiptTarget = target
    , internalTargetMaterialReceiptGeneration = generation
    , internalTargetMaterialReceiptReadBackVersion = readBackVersion
    }

targetMaterialReceiptTarget :: TargetMaterialReceipt -> CredentialTarget
targetMaterialReceiptTarget = internalTargetMaterialReceiptTarget

targetMaterialReceiptGeneration
  :: TargetMaterialReceipt -> CredentialGeneration
targetMaterialReceiptGeneration = internalTargetMaterialReceiptGeneration

targetMaterialReceiptReadBackVersion :: TargetMaterialReceipt -> Natural
targetMaterialReceiptReadBackVersion = internalTargetMaterialReceiptReadBackVersion

data TargetMaterialClient m = TargetMaterialClient
  { internalDirectTargetMaterialHandoff
      :: forall schema
       . TargetMaterialHandoff schema
      -> m (Either TargetMaterialClientError TargetMaterialReceipt)
  }

mkTargetMaterialClient
  :: ( forall schema
        . TargetMaterialHandoff schema
       -> m (Either TargetMaterialClientError TargetMaterialReceipt)
     )
  -> TargetMaterialClient m
mkTargetMaterialClient = TargetMaterialClient

data TargetMaterialClientError
  = TargetMaterialClientTransportFailed !Text
  | TargetMaterialClientTargetNotRegistered !CredentialTarget
  | TargetMaterialClientPayloadNotMaterializable !CredentialTarget
  | TargetMaterialClientCommitRefused !Text
  | TargetMaterialClientReadBackMissing
  | TargetMaterialClientReadBackMismatch
  deriving (Eq, Show)

handoffTargetMaterialWithReadBack
  :: TargetMaterialClient m
  -> TargetMaterialHandoff schema
  -> m (Either TargetMaterialClientError TargetMaterialReceipt)
handoffTargetMaterialWithReadBack client handoff =
  internalDirectTargetMaterialHandoff client handoff

validateField :: Text -> Int -> Text -> Either TargetMaterialValueError Text
validateField label maximumLength raw
  | Text.null value = Left (TargetMaterialFieldEmpty label)
  | Text.length value > maximumLength =
      Left (TargetMaterialFieldTooLong label (Text.length value) maximumLength)
  | Text.any isControl value = Left (TargetMaterialFieldContainsControl label)
  | otherwise = Right value
 where
  value = Text.strip raw
