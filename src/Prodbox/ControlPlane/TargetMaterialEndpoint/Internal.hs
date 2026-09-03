{-# LANGUAGE OverloadedStrings #-}

-- | Package-private strict parser for Target Worker custom metadata.  The
-- explicit Vault-version field closes the data-CAS/custom-metadata publication
-- interval: a coordinate-level metadata document is accepted only when it
-- names the same immutable version Vault reports as current.
module Prodbox.ControlPlane.TargetMaterialEndpoint.Internal
  ( ValidatedTargetMaterialMetadata
  , validatedTargetMaterialGeneration
  , validatedTargetMaterialVaultVersion
  , validatedTargetMaterialCommitment
  , validatedTargetMaterialOwnerNonce
  , validatedTargetMaterialFencingToken
  , validatedTargetMaterialRequestDigest
  , validatedTargetMaterialActionDigest
  , validatedTargetMaterialPodUid
  , validatedTargetMaterialImageDigest
  , validateTargetMaterialMetadataInternal
  , validateTargetMaterialMetadataReadinessInternal
  , targetMaterialMetadataGenerationField
  , targetMaterialMetadataVaultVersionField
  , targetMaterialMetadataCommitmentField
  , targetMaterialMetadataOwnerNonceField
  , targetMaterialMetadataFencingTokenField
  , targetMaterialMetadataRequestDigestField
  , targetMaterialMetadataActionDigestField
  , targetMaterialMetadataPodUidField
  , targetMaterialMetadataImageDigestField
  )
where

import Control.Monad (void)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.TargetCommitIntent (mkTargetValueDigest)
import Prodbox.Vault.Client (KvV2SecretMetadata (..))
import Text.Read (readMaybe)

data ValidatedTargetMaterialMetadata = ValidatedTargetMaterialMetadata
  { validatedTargetMaterialGeneration :: !Natural
  , validatedTargetMaterialVaultVersion :: !Natural
  , validatedTargetMaterialCommitment :: !Text
  , validatedTargetMaterialOwnerNonce :: !Text
  , validatedTargetMaterialFencingToken :: !Natural
  , validatedTargetMaterialRequestDigest :: !Text
  , validatedTargetMaterialActionDigest :: !Text
  , validatedTargetMaterialPodUid :: !Text
  , validatedTargetMaterialImageDigest :: !Text
  }

validateTargetMaterialMetadataInternal
  :: KvV2SecretMetadata
  -> Either Text ValidatedTargetMaterialMetadata
validateTargetMaterialMetadataInternal metadata = do
  let fields = kvV2SecretMetadataCustom metadata
      currentVersion = kvV2SecretMetadataCurrentVersion metadata
  if Map.keysSet fields == expectedMetadataFields
    then Right ()
    else Left "target metadata field set is not canonical"
  generation <- positiveNatural "generation" targetMaterialMetadataGenerationField fields
  boundVersion <- positiveNatural "Vault version" targetMaterialMetadataVaultVersionField fields
  if boundVersion == currentVersion
    then Right ()
    else Left "target metadata Vault version does not match current version"
  commitment <- boundedField "opaque commitment" targetMaterialMetadataCommitmentField 512 fields
  if "vault:v" `Text.isPrefixOf` commitment
    then Right ()
    else Left "target metadata commitment is not a Vault HMAC"
  ownerNonce <- boundedField "owner nonce" targetMaterialMetadataOwnerNonceField 128 fields
  fencing <- positiveNatural "fencing token" targetMaterialMetadataFencingTokenField fields
  requestDigest <- digestField "request digest" targetMaterialMetadataRequestDigestField fields
  actionDigest <- digestField "action digest" targetMaterialMetadataActionDigestField fields
  podUid <- boundedField "Pod UID" targetMaterialMetadataPodUidField 256 fields
  imageDigest <- boundedField "image digest" targetMaterialMetadataImageDigestField 256 fields
  Right
    ValidatedTargetMaterialMetadata
      { validatedTargetMaterialGeneration = generation
      , validatedTargetMaterialVaultVersion = boundVersion
      , validatedTargetMaterialCommitment = commitment
      , validatedTargetMaterialOwnerNonce = ownerNonce
      , validatedTargetMaterialFencingToken = fencing
      , validatedTargetMaterialRequestDigest = requestDigest
      , validatedTargetMaterialActionDigest = actionDigest
      , validatedTargetMaterialPodUid = podUid
      , validatedTargetMaterialImageDigest = imageDigest
      }

-- | Readiness-only migration check. A positive-version document with no custom
-- metadata is the exact pre-receipt legacy shape and is admitted so the
-- Lifecycle Authority can start and drive its repair. The later complete
-- eight-field legacy shape is accepted only when binding it to the current
-- Vault version makes it strict-valid. Proof observations and Provider sessions
-- continue to call 'validateTargetMaterialMetadataInternal' and therefore
-- refuse both migration arms until the Target Worker repairs metadata.
validateTargetMaterialMetadataReadinessInternal
  :: KvV2SecretMetadata -> Either Text ()
validateTargetMaterialMetadataReadinessInternal metadata =
  case validateTargetMaterialMetadataInternal metadata of
    Right _ -> Right ()
    Left strictError
      | Map.null fields && kvV2SecretMetadataCurrentVersion metadata > 0 -> Right ()
      | Map.keysSet fields == legacyMetadataFields ->
          void
            ( validateTargetMaterialMetadataInternal
                metadata
                  { kvV2SecretMetadataCustom =
                      Map.insert
                        targetMaterialMetadataVaultVersionField
                        (Text.pack (show (kvV2SecretMetadataCurrentVersion metadata)))
                        fields
                  }
            )
      | otherwise -> Left strictError
 where
  fields = kvV2SecretMetadataCustom metadata

expectedMetadataFields :: Set.Set Text
expectedMetadataFields =
  Set.fromList
    [ targetMaterialMetadataGenerationField
    , targetMaterialMetadataVaultVersionField
    , targetMaterialMetadataCommitmentField
    , targetMaterialMetadataOwnerNonceField
    , targetMaterialMetadataFencingTokenField
    , targetMaterialMetadataRequestDigestField
    , targetMaterialMetadataActionDigestField
    , targetMaterialMetadataPodUidField
    , targetMaterialMetadataImageDigestField
    ]

legacyMetadataFields :: Set.Set Text
legacyMetadataFields =
  Set.delete targetMaterialMetadataVaultVersionField expectedMetadataFields

positiveNatural
  :: Text -> Text -> Map Text Text -> Either Text Natural
positiveNatural label field fields = do
  raw <- requiredField label field fields
  case readMaybe (Text.unpack raw) of
    Just value | value > 0 -> Right value
    _ -> Left ("target metadata " <> label <> " is invalid")

digestField :: Text -> Text -> Map Text Text -> Either Text Text
digestField label field fields = do
  value <- requiredField label field fields
  case mkTargetValueDigest value of
    Left _ -> Left ("target metadata " <> label <> " is invalid")
    Right _ -> Right value

boundedField :: Text -> Text -> Int -> Map Text Text -> Either Text Text
boundedField label field maximumLength fields = do
  value <- requiredField label field fields
  if Text.null value
    || Text.length value > maximumLength
    || Text.strip value /= value
    || Text.any invalidCharacter value
    then Left ("target metadata " <> label <> " is invalid")
    else Right value
 where
  invalidCharacter character = character < '\x20' || character == '\x7f'

requiredField :: Text -> Text -> Map Text Text -> Either Text Text
requiredField label field fields =
  maybe
    (Left ("target metadata has no " <> label))
    Right
    (Map.lookup field fields)

targetMaterialMetadataGenerationField :: Text
targetMaterialMetadataGenerationField = "prodbox_generation"

targetMaterialMetadataVaultVersionField :: Text
targetMaterialMetadataVaultVersionField = "prodbox_vault_version"

targetMaterialMetadataCommitmentField :: Text
targetMaterialMetadataCommitmentField = "prodbox_commitment"

targetMaterialMetadataOwnerNonceField :: Text
targetMaterialMetadataOwnerNonceField = "prodbox_owner_nonce"

targetMaterialMetadataFencingTokenField :: Text
targetMaterialMetadataFencingTokenField = "prodbox_fencing_token"

targetMaterialMetadataRequestDigestField :: Text
targetMaterialMetadataRequestDigestField = "prodbox_request_digest"

targetMaterialMetadataActionDigestField :: Text
targetMaterialMetadataActionDigestField = "prodbox_action_digest"

targetMaterialMetadataPodUidField :: Text
targetMaterialMetadataPodUidField = "prodbox_worker_pod_uid"

targetMaterialMetadataImageDigestField :: Text
targetMaterialMetadataImageDigestField = "prodbox_worker_image_digest"
