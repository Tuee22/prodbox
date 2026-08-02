{-# LANGUAGE OverloadedStrings #-}

-- | Neutral physical codec for legacy fenced target records.
--
-- This codec belongs to the Target Agent boundary, not the retired Gateway
-- route surface.  Only the closed target-material payload is lowered to Vault
-- fields; the four reserved fields are protocol metadata owned here.
module Prodbox.ControlPlane.TargetMaterialRecordCodec
  ( targetMaterialRecordToVaultFields
  , targetMaterialRecordFromVaultFields
  )
where

import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , TargetSecretPayload
  , targetSecretPayloadFromVaultFields
  , targetSecretPayloadToVaultFields
  )
import Prodbox.Lifecycle.Lease
  ( fencingTokenValue
  , mkFencingToken
  , mkOwnerNonce
  , ownerNonceText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkRecord (..)
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import Text.Read (readMaybe)

targetMaterialRecordToVaultFields
  :: TargetSinkRecord TargetSecretPayload
  -> Either Text (Map Text Text)
targetMaterialRecordToVaultFields record = do
  payload <- targetSecretPayloadToVaultFields (targetSinkRecordPayload record)
  pure
    ( Map.union
        payload
        ( Map.fromList
            [ (ownerNonceField, ownerNonceText (targetSinkRecordOwnerNonce record))
            ,
              ( fenceField
              , Text.pack (show (fencingTokenValue (targetSinkRecordFencingToken record)))
              )
            ,
              ( generationField
              , Text.pack (show (credentialGenerationValue (targetSinkRecordGeneration record)))
              )
            , (digestField, targetValueDigestText (targetSinkRecordDigest record))
            ]
        )
    )

targetMaterialRecordFromVaultFields
  :: TargetSecretId
  -> Map Text Text
  -> Either Text (TargetSinkRecord TargetSecretPayload)
targetMaterialRecordFromVaultFields target fields = do
  ownerText <- requireMetadata ownerNonceField
  fenceNatural <- requireNaturalMetadata fenceField
  generationNatural <- requireNaturalMetadata generationField
  digestText <- requireMetadata digestField
  let payloadFields = foldr Map.delete fields metadataFields
  case filter (metadataPrefix `Text.isPrefixOf`) (Map.keys payloadFields) of
    unexpected : _ ->
      Left ("unexpected reserved target metadata field `" <> unexpected <> "`")
    [] -> pure ()
  owner <- first (Text.pack . show) (mkOwnerNonce ownerText)
  fence <- first (Text.pack . show) (mkFencingToken fenceNatural)
  generation <- first (Text.pack . show) (mkCredentialGeneration generationNatural)
  digest <- first (Text.pack . show) (mkTargetValueDigest digestText)
  payload <- targetSecretPayloadFromVaultFields target payloadFields
  pure
    TargetSinkRecord
      { targetSinkRecordOwnerNonce = owner
      , targetSinkRecordFencingToken = fence
      , targetSinkRecordGeneration = generation
      , targetSinkRecordDigest = digest
      , targetSinkRecordPayload = payload
      }
 where
  requireMetadata name =
    maybe
      (Left ("target record is missing metadata field `" <> name <> "`"))
      Right
      (Map.lookup name fields)

  requireNaturalMetadata name = do
    value <- requireMetadata name
    maybe
      (Left ("target record metadata field `" <> name <> "` is not a natural number"))
      Right
      (readMaybe (Text.unpack value) :: Maybe Natural)

metadataPrefix :: Text
metadataPrefix = "prodbox_commit_"

ownerNonceField :: Text
ownerNonceField = metadataPrefix <> "owner_nonce"

fenceField :: Text
fenceField = metadataPrefix <> "fencing_token"

generationField :: Text
generationField = metadataPrefix <> "generation"

digestField :: Text
digestField = metadataPrefix <> "digest"

metadataFields :: [Text]
metadataFields = [ownerNonceField, fenceField, generationField, digestField]
