{-# LANGUAGE OverloadedStrings #-}

-- | Model-B logical object layer: logical names are HMACed into opaque MinIO
-- keys and bodies are Vault-Transit envelopes.
module Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalObject (..)
  , decoyObjectKeys
  , decodeIndex
  , encodeIndex
  , getLogical
  , getLogicalWith
  , logicalObjectAad
  , logicalObjectName
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogical
  , putLogicalWith
  , renderEncryptedObjectError
  )
where

import Crypto.Hash.SHA256 (hmac)
import Data.Aeson
  ( eitherDecodeStrict'
  , encode
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString, word8HexFixed)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Crypto.Envelope
  ( DekCipher
  , EnvelopeError
  , openEnvelope
  , sealEnvelope
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig
  , getObject
  , putObject
  )

data LogicalObject
  = LogicalInForceConfig
  | LogicalGatewayState Text
  | LogicalPulumiStack Text
  | LogicalDownstreamCluster Text
  deriving (Eq, Ord, Show)

data EncryptedObjectError
  = EncryptedObjectFetchFailed String
  | EncryptedObjectMissing Text
  | EncryptedObjectOpenFailed EnvelopeError
  | EncryptedObjectSealFailed EnvelopeError
  | EncryptedObjectStoreFailed String
  | EncryptedObjectIndexMalformed String
  deriving (Eq, Show)

renderEncryptedObjectError :: EncryptedObjectError -> String
renderEncryptedObjectError err = case err of
  EncryptedObjectFetchFailed detail -> "failed to fetch encrypted object: " ++ detail
  EncryptedObjectMissing key -> "encrypted object missing at " ++ Text.unpack key
  EncryptedObjectOpenFailed detail -> "failed to open encrypted object: " ++ show detail
  EncryptedObjectSealFailed detail -> "failed to seal encrypted object: " ++ show detail
  EncryptedObjectStoreFailed detail -> "failed to store encrypted object: " ++ detail
  EncryptedObjectIndexMalformed detail -> "encrypted object index is malformed: " ++ detail

logicalObjectName :: LogicalObject -> Text
logicalObjectName object = case object of
  LogicalInForceConfig -> "in-force-config"
  LogicalGatewayState name -> "gateway-state/" <> Text.strip name
  LogicalPulumiStack stackId -> "pulumi-stack/" <> Text.strip stackId
  LogicalDownstreamCluster childId -> "downstream-cluster/" <> Text.strip childId

logicalObjectAad :: Text -> LogicalObject -> ByteString
logicalObjectAad clusterId object =
  TextEncoding.encodeUtf8 (clusterId <> "|" <> logicalObjectName object)

opaqueObjectId :: ByteString -> LogicalObject -> Text
opaqueObjectId hmacKey object =
  hexBytes (hmac hmacKey (TextEncoding.encodeUtf8 (logicalObjectName object)))

objectKeyForOpaqueId :: Text -> Text
objectKeyForOpaqueId opaqueId =
  "objects/" <> opaqueId <> ".enc"

putLogical
  :: ObjectStoreConfig
  -> DekCipher
  -> ByteString
  -> Text
  -> LogicalObject
  -> ByteString
  -> IO (Either EncryptedObjectError ())
putLogical config =
  putLogicalWith (putObject config)

putLogicalWith
  :: (Text -> ByteString -> IO (Either String ()))
  -> DekCipher
  -> ByteString
  -> Text
  -> LogicalObject
  -> ByteString
  -> IO (Either EncryptedObjectError ())
putLogicalWith putOpaque cipher hmacKey clusterId object plaintext = do
  sealResult <- sealEnvelope cipher (logicalObjectAad clusterId object) plaintext
  case sealResult of
    Left err -> pure (Left (EncryptedObjectSealFailed err))
    Right envelope -> do
      let key = objectKeyForOpaqueId (opaqueObjectId hmacKey object)
      storeResult <- putOpaque key envelope
      pure $ case storeResult of
        Left err -> Left (EncryptedObjectStoreFailed err)
        Right () -> Right ()

getLogical
  :: ObjectStoreConfig
  -> DekCipher
  -> ByteString
  -> Text
  -> LogicalObject
  -> IO (Either EncryptedObjectError ByteString)
getLogical config =
  getLogicalWith (getObject config)

getLogicalWith
  :: (Text -> IO (Either String (Maybe ByteString)))
  -> DekCipher
  -> ByteString
  -> Text
  -> LogicalObject
  -> IO (Either EncryptedObjectError ByteString)
getLogicalWith getOpaque cipher hmacKey clusterId object = do
  let key = objectKeyForOpaqueId (opaqueObjectId hmacKey object)
  fetchResult <- getOpaque key
  case fetchResult of
    Left err -> pure (Left (EncryptedObjectFetchFailed err))
    Right Nothing -> pure (Left (EncryptedObjectMissing key))
    Right (Just envelope) -> do
      openResult <- openEnvelope cipher (logicalObjectAad clusterId object) envelope
      pure $ case openResult of
        Left err -> Left (EncryptedObjectOpenFailed err)
        Right plaintext -> Right plaintext

encodeIndex :: Map Text Text -> ByteString
encodeIndex =
  BL.toStrict . encode

decodeIndex :: ByteString -> Either EncryptedObjectError (Map Text Text)
decodeIndex bytes =
  case eitherDecodeStrict' bytes of
    Left err -> Left (EncryptedObjectIndexMalformed err)
    Right index -> Right index

decoyObjectKeys :: Int -> [Text]
decoyObjectKeys count =
  [ objectKeyForOpaqueId ("decoy-" <> leftPad index)
  | index <- [1 .. count]
  ]
 where
  leftPad index =
    let rendered = Text.pack (show index)
     in Text.replicate (max 0 (4 - Text.length rendered)) "0" <> rendered

hexBytes :: ByteString -> Text
hexBytes bytes =
  TextEncoding.decodeUtf8
    ( BL.toStrict
        ( toLazyByteString
            (foldMap word8HexFixed (BS.unpack bytes))
        )
    )
