{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private construction and validation for the Provider Worker's
-- exact operational-credential session.  The public facade deliberately
-- exposes no constructor, raw metadata parser, or wire decoder.
module Prodbox.ControlPlane.ProviderCredentialSession.Internal
  ( ProviderCredentialSessionBinding
  , providerCredentialSessionGeneration
  , providerCredentialSessionVaultVersion
  , providerCredentialSessionReceiptDigest
  , ProviderAcceptedAuthorityDigest
  , providerAcceptedAuthorityDigestText
  , ProviderCredentialSessionError (..)
  , ValidatedProviderCredentialSession
  , validatedProviderCredentialSessionBindingInternal
  , validatedProviderCredentialSessionCredentialsInternal
  , validateProviderCredentialSessionInternal
  , providerCredentialSessionBindingFromWireInternal
  , providerAcceptedAuthorityDigestFromCanonicalInternal
  , providerAcceptedAuthorityDigestFromTextInternal
  , ProviderCredentialSessionRegression
  , fixedProviderCredentialSessionRegression
  , providerCredentialSessionRegressionExactJoinAccepted
  , providerCredentialSessionRegressionMetadataRaceRefused
  , providerCredentialSessionRegressionLegacyMetadataRefused
  , providerCredentialSessionRegressionLegacyMetadataReadinessAccepted
  , providerCredentialSessionRegressionWrongExactVersionRefused
  , providerCredentialSessionRegressionDestroyedVersionRefused
  , providerCredentialSessionRegressionMissingDataRefused
  , providerCredentialSessionRegressionExtraSecretFieldRefused
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialEndpoint.Internal
  ( targetMaterialMetadataActionDigestField
  , targetMaterialMetadataCommitmentField
  , targetMaterialMetadataFencingTokenField
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataImageDigestField
  , targetMaterialMetadataOwnerNonceField
  , targetMaterialMetadataPodUidField
  , targetMaterialMetadataRequestDigestField
  , targetMaterialMetadataVaultVersionField
  , validateTargetMaterialMetadataInternal
  , validateTargetMaterialMetadataReadinessInternal
  , validatedTargetMaterialActionDigest
  , validatedTargetMaterialCommitment
  , validatedTargetMaterialGeneration
  , validatedTargetMaterialImageDigest
  , validatedTargetMaterialPodUid
  , validatedTargetMaterialRequestDigest
  , validatedTargetMaterialVaultVersion
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  , TargetSecretPayload (AwsCredentialMaterial)
  , targetSecretPayloadFromVaultFields
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( encodeTargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Settings (Credentials (..))
import Prodbox.Vault.Client
  ( KvV2ExactVersionSecret (..)
  , KvV2SecretMetadata (..)
  )

-- | Secret-free identity of one exact Provider credential generation and
-- immutable Vault KV-v2 version.  The digest covers exactly the canonical
-- Target Worker receipt.
data ProviderCredentialSessionBinding = ProviderCredentialSessionBinding
  { internalProviderCredentialSessionGeneration :: !CredentialGeneration
  , internalProviderCredentialSessionVaultVersion :: !Natural
  , internalProviderCredentialSessionReceiptDigest :: !TargetValueDigest
  }
  deriving stock (Eq, Show)

providerCredentialSessionGeneration
  :: ProviderCredentialSessionBinding -> CredentialGeneration
providerCredentialSessionGeneration =
  internalProviderCredentialSessionGeneration

providerCredentialSessionVaultVersion
  :: ProviderCredentialSessionBinding -> Natural
providerCredentialSessionVaultVersion =
  internalProviderCredentialSessionVaultVersion

providerCredentialSessionReceiptDigest
  :: ProviderCredentialSessionBinding -> TargetValueDigest
providerCredentialSessionReceiptDigest =
  internalProviderCredentialSessionReceiptDigest

-- | Digest of the exact Provider Worker trust record that admitted an
-- execution.  It is distinct from the operational AWS credential binding.
newtype ProviderAcceptedAuthorityDigest = ProviderAcceptedAuthorityDigest Text
  deriving stock (Eq, Ord, Show)

providerAcceptedAuthorityDigestText :: ProviderAcceptedAuthorityDigest -> Text
providerAcceptedAuthorityDigestText (ProviderAcceptedAuthorityDigest value) = value

data ProviderCredentialSessionError
  = ProviderCredentialSessionMetadataInvalid !Text
  | ProviderCredentialSessionExactVersionMismatch !Natural !Natural
  | ProviderCredentialSessionExactVersionDestroyed
  | ProviderCredentialSessionExactVersionDataMissing
  | ProviderCredentialSessionTargetPayloadInvalid !Text
  | ProviderCredentialSessionTargetIdentityMismatch
  | ProviderCredentialSessionReceiptInvalid !Text
  | ProviderCredentialSessionGenerationInvalid !Natural
  | ProviderCredentialSessionVaultVersionInvalid !Natural
  | ProviderCredentialSessionReceiptDigestInvalid !Text
  | ProviderAcceptedAuthorityDigestInvalid !Text
  deriving stock (Eq, Show)

-- | Package-private pair returned only after the metadata/current-version and
-- exact immutable data-version observations have been joined.
data ValidatedProviderCredentialSession = ValidatedProviderCredentialSession
  { internalValidatedProviderCredentialSessionBinding
      :: !ProviderCredentialSessionBinding
  , internalValidatedProviderCredentialSessionCredentials :: !Credentials
  }

validatedProviderCredentialSessionBindingInternal
  :: ValidatedProviderCredentialSession -> ProviderCredentialSessionBinding
validatedProviderCredentialSessionBindingInternal =
  internalValidatedProviderCredentialSessionBinding

validatedProviderCredentialSessionCredentialsInternal
  :: ValidatedProviderCredentialSession -> Credentials
validatedProviderCredentialSessionCredentialsInternal =
  internalValidatedProviderCredentialSessionCredentials

-- | Validate the fixed Lifecycle-provider target.  Metadata is observed first;
-- its explicit version field must bind the coordinate-level custom metadata to
-- Vault's current version.  Only that exact immutable data version is accepted.
validateProviderCredentialSessionInternal
  :: KvV2SecretMetadata
  -> KvV2ExactVersionSecret
  -> Either ProviderCredentialSessionError ValidatedProviderCredentialSession
validateProviderCredentialSessionInternal metadata exact = do
  validatedMetadata <-
    first
      ProviderCredentialSessionMetadataInvalid
      (validateTargetMaterialMetadataInternal metadata)
  let currentVersion = validatedTargetMaterialVaultVersion validatedMetadata
      observedExactVersion = kvV2ExactVersionSecretVersion exact
  if observedExactVersion == currentVersion
    then Right ()
    else
      Left
        ( ProviderCredentialSessionExactVersionMismatch
            currentVersion
            observedExactVersion
        )
  if kvV2ExactVersionSecretDestroyed exact
    then Left ProviderCredentialSessionExactVersionDestroyed
    else Right ()
  fields <-
    maybe
      (Left ProviderCredentialSessionExactVersionDataMissing)
      Right
      (kvV2ExactVersionSecretData exact)
  payload <-
    first
      ProviderCredentialSessionTargetPayloadInvalid
      ( targetSecretPayloadFromVaultFields
          (TargetAwsCredential AwsLifecycleProvider)
          fields
      )
  credentials <- case payload of
    AwsCredentialMaterial identity accessKey secretKey sessionToken region
      | identity == AwsLifecycleProvider ->
          Right
            Credentials
              { access_key_id = accessKey
              , secret_access_key = secretKey
              , session_token = nonEmpty sessionToken
              , region = region
              }
      | otherwise -> Left ProviderCredentialSessionTargetIdentityMismatch
    _ -> Left ProviderCredentialSessionTargetIdentityMismatch
  generation <-
    first
      (const (ProviderCredentialSessionGenerationInvalid (validatedTargetMaterialGeneration validatedMetadata)))
      (mkCredentialGeneration (validatedTargetMaterialGeneration validatedMetadata))
  requestDigest <-
    first
      (const (ProviderCredentialSessionMetadataFieldInvalid targetMaterialMetadataRequestDigestField))
      (mkTargetValueDigest (validatedTargetMaterialRequestDigest validatedMetadata))
  actionDigest <-
    first
      (const (ProviderCredentialSessionMetadataFieldInvalid targetMaterialMetadataActionDigestField))
      (mkTargetValueDigest (validatedTargetMaterialActionDigest validatedMetadata))
  receipt <-
    first
      (ProviderCredentialSessionReceiptInvalid . Text.pack . show)
      ( mkTargetWorkerReceiptProjection
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          currentVersion
          (validatedTargetMaterialCommitment validatedMetadata)
          requestDigest
          actionDigest
          (validatedTargetMaterialPodUid validatedMetadata)
          (validatedTargetMaterialImageDigest validatedMetadata)
      )
  let receiptDigest =
        sha256TargetValueDigest (encodeTargetWorkerReceipt receipt)
      binding =
        ProviderCredentialSessionBinding
          { internalProviderCredentialSessionGeneration = generation
          , internalProviderCredentialSessionVaultVersion = currentVersion
          , internalProviderCredentialSessionReceiptDigest = receiptDigest
          }
  Right
    ValidatedProviderCredentialSession
      { internalValidatedProviderCredentialSessionBinding = binding
      , internalValidatedProviderCredentialSessionCredentials = credentials
      }
 where
  nonEmpty value
    | Text.null value = Nothing
    | otherwise = Just value

providerCredentialSessionBindingFromWireInternal
  :: Natural
  -> Natural
  -> Text
  -> Either ProviderCredentialSessionError ProviderCredentialSessionBinding
providerCredentialSessionBindingFromWireInternal generationValue vaultVersion digestText = do
  generation <-
    first
      (const (ProviderCredentialSessionGenerationInvalid generationValue))
      (mkCredentialGeneration generationValue)
  if vaultVersion > 0
    then Right ()
    else Left (ProviderCredentialSessionVaultVersionInvalid vaultVersion)
  digest <-
    first
      (const (ProviderCredentialSessionReceiptDigestInvalid digestText))
      (mkTargetValueDigest digestText)
  Right
    ProviderCredentialSessionBinding
      { internalProviderCredentialSessionGeneration = generation
      , internalProviderCredentialSessionVaultVersion = vaultVersion
      , internalProviderCredentialSessionReceiptDigest = digest
      }

providerAcceptedAuthorityDigestFromCanonicalInternal
  :: ByteString -> ProviderAcceptedAuthorityDigest
providerAcceptedAuthorityDigestFromCanonicalInternal =
  ProviderAcceptedAuthorityDigest
    . targetValueDigestText
    . sha256TargetValueDigest

providerAcceptedAuthorityDigestFromTextInternal
  :: Text
  -> Either ProviderCredentialSessionError ProviderAcceptedAuthorityDigest
providerAcceptedAuthorityDigestFromTextInternal value = do
  _ <-
    first
      (const (ProviderAcceptedAuthorityDigestInvalid value))
      (mkTargetValueDigest value)
  Right (ProviderAcceptedAuthorityDigest value)

-- Fixed non-authorizing diagnostics let the separate unit component exercise
-- the hidden parser without exposing a caller-controlled binding constructor.
data ProviderCredentialSessionRegression = ProviderCredentialSessionRegression
  { providerCredentialSessionRegressionExactJoinAccepted :: !Bool
  , providerCredentialSessionRegressionMetadataRaceRefused :: !Bool
  , providerCredentialSessionRegressionLegacyMetadataRefused :: !Bool
  , providerCredentialSessionRegressionLegacyMetadataReadinessAccepted :: !Bool
  , providerCredentialSessionRegressionWrongExactVersionRefused :: !Bool
  , providerCredentialSessionRegressionDestroyedVersionRefused :: !Bool
  , providerCredentialSessionRegressionMissingDataRefused :: !Bool
  , providerCredentialSessionRegressionExtraSecretFieldRefused :: !Bool
  }
  deriving stock (Eq, Show)

fixedProviderCredentialSessionRegression :: ProviderCredentialSessionRegression
fixedProviderCredentialSessionRegression =
  ProviderCredentialSessionRegression
    { providerCredentialSessionRegressionExactJoinAccepted =
        case validateProviderCredentialSessionInternal validMetadata validExact of
          Right validated ->
            credentialGenerationValue
              ( providerCredentialSessionGeneration
                  (validatedProviderCredentialSessionBindingInternal validated)
              )
              == 7
              && providerCredentialSessionVaultVersion
                (validatedProviderCredentialSessionBindingInternal validated)
                == 11
          Left _ -> False
    , providerCredentialSessionRegressionMetadataRaceRefused =
        case validateProviderCredentialSessionInternal racedMetadata validExact of
          Left (ProviderCredentialSessionMetadataInvalid _) -> True
          _ -> False
    , providerCredentialSessionRegressionLegacyMetadataRefused =
        case validateProviderCredentialSessionInternal legacyMetadata validExact of
          Left (ProviderCredentialSessionMetadataInvalid _) -> True
          _ -> False
    , providerCredentialSessionRegressionLegacyMetadataReadinessAccepted =
        validateTargetMaterialMetadataReadinessInternal legacyMetadata == Right ()
    , providerCredentialSessionRegressionWrongExactVersionRefused =
        case validateProviderCredentialSessionInternal validMetadata wrongVersionExact of
          Left (ProviderCredentialSessionExactVersionMismatch 11 10) -> True
          _ -> False
    , providerCredentialSessionRegressionDestroyedVersionRefused =
        case validateProviderCredentialSessionInternal validMetadata destroyedExact of
          Left ProviderCredentialSessionExactVersionDestroyed -> True
          _ -> False
    , providerCredentialSessionRegressionMissingDataRefused =
        case validateProviderCredentialSessionInternal validMetadata missingDataExact of
          Left ProviderCredentialSessionExactVersionDataMissing -> True
          _ -> False
    , providerCredentialSessionRegressionExtraSecretFieldRefused =
        case validateProviderCredentialSessionInternal validMetadata extraFieldExact of
          Left (ProviderCredentialSessionTargetPayloadInvalid _) -> True
          _ -> False
    }

validMetadata :: KvV2SecretMetadata
validMetadata =
  KvV2SecretMetadata
    { kvV2SecretMetadataCurrentVersion = 11
    , kvV2SecretMetadataCustom =
        Map.fromList
          [ (targetMaterialMetadataGenerationField, "7")
          , (targetMaterialMetadataVaultVersionField, "11")
          , ( targetMaterialMetadataCommitmentField
            , "vault:v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
          , (targetMaterialMetadataOwnerNonceField, "provider-target-owner")
          , (targetMaterialMetadataFencingTokenField, "9")
          , (targetMaterialMetadataRequestDigestField, digestA)
          , (targetMaterialMetadataActionDigestField, digestB)
          , (targetMaterialMetadataPodUidField, "provider-target-pod")
          , ( targetMaterialMetadataImageDigestField
            , "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
          ]
    }

racedMetadata :: KvV2SecretMetadata
racedMetadata =
  validMetadata
    { kvV2SecretMetadataCustom =
        Map.insert
          targetMaterialMetadataVaultVersionField
          "10"
          (kvV2SecretMetadataCustom validMetadata)
    }

legacyMetadata :: KvV2SecretMetadata
legacyMetadata =
  validMetadata
    { kvV2SecretMetadataCustom =
        Map.delete
          targetMaterialMetadataVaultVersionField
          (kvV2SecretMetadataCustom validMetadata)
    }

validExact :: KvV2ExactVersionSecret
validExact =
  KvV2ExactVersionSecret
    { kvV2ExactVersionSecretData = Just validCredentialFields
    , kvV2ExactVersionSecretVersion = 11
    , kvV2ExactVersionSecretDestroyed = False
    }

wrongVersionExact :: KvV2ExactVersionSecret
wrongVersionExact = validExact {kvV2ExactVersionSecretVersion = 10}

destroyedExact :: KvV2ExactVersionSecret
destroyedExact = validExact {kvV2ExactVersionSecretDestroyed = True}

missingDataExact :: KvV2ExactVersionSecret
missingDataExact = validExact {kvV2ExactVersionSecretData = Nothing}

extraFieldExact :: KvV2ExactVersionSecret
extraFieldExact =
  validExact
    { kvV2ExactVersionSecretData =
        Just (Map.insert "unexpected" "value" validCredentialFields)
    }

validCredentialFields :: Map Text Text
validCredentialFields =
  Map.fromList
    [ ("access_key_id", "AKIAEXAMPLE")
    , ("secret_access_key", "secret-value")
    , ("session_token", "")
    , ("region", "ca-central-1")
    ]

digestA :: Text
digestA = Text.replicate 64 "a"

digestB :: Text
digestB = Text.replicate 64 "b"
