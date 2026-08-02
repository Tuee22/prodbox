{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic, secret-free initialization parameters shared by the
-- controller and each one-shot initialization worker.  Keeping this
-- derivation in one module prevents an independently reconstructed worker
-- from accepting a different schema, quorum, or recipient commitment.
module Prodbox.Bootstrap.Broker.ProductionCryptoParameters
  ( productionRootInitCryptoParameters
  , productionPristineStorageProof
  )
where

import Codec.Serialise (serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Engine
  ( RootInitCryptoParameters (..)
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , brokerBurnRecipient
  , burnRecipientFingerprint
  , burnRecipientPublicKeyBase64
  , burnRecipientPublicKeyDigest
  , unBurnRecipientFingerprint
  , unBurnRecipientPublicKeyDigest
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , PristineStorageProof
  , RootInitBinding
  , mkArtifactDigest
  , mkBootstrapSchemaVersion
  , mkPristineStorageProof
  , pristineStorageBinding
  , pristineStorageObservationDigest
  , renderVaultStorageGeneration
  , rootInitStorageGeneration
  )

productionPristineStorageProof
  :: RootInitBinding
  -> PristineStorageProof
productionPristineStorageProof binding =
  mkPristineStorageProof
    binding
    (artifactDigestForBytes pristineCommitment)
 where
  pristineCommitment =
    TextEncoding.encodeUtf8
      ( "pristine:"
          <> renderVaultStorageGeneration (rootInitStorageGeneration binding)
      )

productionRootInitCryptoParameters
  :: BootstrapBrokerSettings
  -> PristineStorageProof
  -> Either String RootInitCryptoParameters
productionRootInitCryptoParameters settings proof = do
  schema <- either (Left . show) Right (mkBootstrapSchemaVersion schemaVersion)
  let envelopeDigest = artifactDigestForBytes envelopeCommitment
  Right
    RootInitCryptoParameters
      { rootInitCryptoSchemaVersion = schema
      , rootInitCryptoCompiledBurnRecipient = burn
      , rootInitCryptoShareCount = shareCount
      , rootInitCryptoThreshold = threshold
      , rootInitCryptoEnvelopeDigest = envelopeDigest
      }
 where
  burn = brokerBurnRecipient settings
  schemaVersion = 1 :: Natural
  shareCount = 5 :: Natural
  threshold = 3 :: Natural
  envelopeCommitment =
    LazyByteString.toStrict
      ( serialise
          ( schemaVersion
          , pristineStorageBinding proof
          , pristineStorageObservationDigest proof
          , burnRecipientPublicKeyBase64 burn
          , unBurnRecipientFingerprint (burnRecipientFingerprint burn)
          , unBurnRecipientPublicKeyDigest (burnRecipientPublicKeyDigest burn)
          , shareCount
          , threshold
          )
      )

sha256Hex :: ByteString.ByteString -> Text.Text
sha256Hex = Text.pack . concatMap twoHex . ByteString.unpack . SHA256.hash
 where
  twoHex byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

artifactDigestForBytes :: ByteString.ByteString -> ArtifactDigest
artifactDigestForBytes bytes =
  case mkArtifactDigest (sha256Hex bytes) of
    Right digest -> digest
    Left failure -> error (show failure)
