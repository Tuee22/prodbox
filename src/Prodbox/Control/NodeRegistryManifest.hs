{-# LANGUAGE OverloadedStrings #-}

-- | Bounded, digest-bound planning for an OCI or Docker schema-2 node image
-- manifest. This pure parser authorizes no registry request or Docker effect.
module Prodbox.Control.NodeRegistryManifest
  ( NodeRegistryBlob (..)
  , NodeRegistryPlan (..)
  , NodeRegistryManifestError (..)
  , validNodeRegistryDigest
  , parseNodeRegistryManifest
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as ByteString
import Data.Char (isDigit)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text

data NodeRegistryBlob = NodeRegistryBlob
  { nodeRegistryBlobDigest :: !Text
  , nodeRegistryBlobSize :: !Integer
  , nodeRegistryBlobMediaType :: !Text
  }
  deriving (Eq, Show)

data NodeRegistryPlan = NodeRegistryPlan
  { nodeRegistryConfig :: !NodeRegistryBlob
  , nodeRegistryLayers :: ![NodeRegistryBlob]
  }
  deriving (Eq, Show)

data NodeRegistryManifestError
  = NodeRegistryInvalidDigest
  | NodeRegistryManifestTooLarge
  | NodeRegistryDigestMismatch
  | NodeRegistryMalformedManifest
  deriving (Eq, Show)

parseNodeRegistryManifest
  :: Text -> ByteString.ByteString -> Either NodeRegistryManifestError NodeRegistryPlan
parseNodeRegistryManifest expected bytes
  | not (validNodeRegistryDigest expected) = Left NodeRegistryInvalidDigest
  | ByteString.length bytes > 1048576 = Left NodeRegistryManifestTooLarge
  | "sha256:" <> Text.pack (show (hash bytes :: Digest SHA256)) /= expected =
      Left NodeRegistryDigestMismatch
  | otherwise = case Aeson.eitherDecodeStrict' bytes >>= parseEither manifestParser of
      Left _ -> Left NodeRegistryMalformedManifest
      Right plan -> Right plan

validNodeRegistryDigest :: Text -> Bool
validNodeRegistryDigest value = case Text.stripPrefix "sha256:" value of
  Nothing -> False
  Just suffix -> Text.length suffix == 64 && Text.all hexDigit suffix
 where
  hexDigit c = isDigit c && c <= '9' || c >= 'a' && c <= 'f'

manifestParser :: Aeson.Value -> Parser NodeRegistryPlan
manifestParser = Aeson.withObject "node manifest" $ \object -> do
  version <- object .: "schemaVersion" :: Parser Int
  media <- object .: "mediaType" :: Parser Text
  config <- object .: "config" >>= blobParser configTypes
  layers <- object .: "layers" >>= mapM (blobParser layerTypes)
  let blobs = config : layers
      digests = map nodeRegistryBlobDigest blobs
  if version == 2
    && media `elem` manifestTypes
    && consistentMedia media config layers
    && not (null layers)
    && length layers <= 128
    && length digests == length (nub digests)
    && sum (map nodeRegistryBlobSize blobs) <= 8589934592
    then pure (NodeRegistryPlan config layers)
    else fail "unsupported node manifest"

consistentMedia :: Text -> NodeRegistryBlob -> [NodeRegistryBlob] -> Bool
consistentMedia media config layers =
  case media of
    "application/vnd.oci.image.manifest.v1+json" ->
      nodeRegistryBlobMediaType config == "application/vnd.oci.image.config.v1+json"
        && all ((`elem` take 2 layerTypes) . nodeRegistryBlobMediaType) layers
    "application/vnd.docker.distribution.manifest.v2+json" ->
      nodeRegistryBlobMediaType config == "application/vnd.docker.container.image.v1+json"
        && all ((== "application/vnd.docker.image.rootfs.diff.tar.gzip") . nodeRegistryBlobMediaType) layers
    _ -> False

blobParser :: [Text] -> Aeson.Value -> Parser NodeRegistryBlob
blobParser allowed = Aeson.withObject "node blob" $ \object -> do
  digest <- object .: "digest"
  size <- object .: "size"
  media <- object .: "mediaType"
  if validNodeRegistryDigest digest && size > 0 && size <= 2147483648 && media `elem` allowed
    then pure (NodeRegistryBlob digest size media)
    else fail "unsupported node blob"

manifestTypes, configTypes, layerTypes :: [Text]
manifestTypes =
  [ "application/vnd.oci.image.manifest.v1+json"
  , "application/vnd.docker.distribution.manifest.v2+json"
  ]
configTypes = ["application/vnd.oci.image.config.v1+json", "application/vnd.docker.container.image.v1+json"]
layerTypes =
  [ "application/vnd.oci.image.layer.v1.tar"
  , "application/vnd.oci.image.layer.v1.tar+gzip"
  , "application/vnd.docker.image.rootfs.diff.tar.gzip"
  ]
