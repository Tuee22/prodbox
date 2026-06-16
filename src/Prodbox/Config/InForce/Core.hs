{-# LANGUAGE OverloadedStrings #-}

-- | Cycle-free core for the in-force cluster configuration envelope.
module Prodbox.Config.InForce.Core
  ( InForceObject (..)
  , ConfigSource (..)
  , InForceConfigError (..)
  , SeedProposeDecision (..)
  , RootWriteAuthority (..)
  , RootConfigWriteDecision (..)
  , fetchInForceValueWith
  , inForceObjectName
  , inForceAad
  , renderInForceConfigError
  , sealInForcePayload
  , openInForcePayload
  , seedProposeDecision
  , storeInForcePayloadWith
  , rootConfigWriteDecision
  , renderRootConfigWriteBlock
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.Crypto.Envelope (DekCipher, EnvelopeError, openEnvelope, sealEnvelope)
import Prodbox.Minio.EncryptedObject
  ( LogicalObject (LogicalInForceConfig)
  , logicalObjectAad
  )

-- | The prodbox-owned MinIO objects whose plaintext is in-force cluster state.
-- Only 'InForceConfig' exists today; the type is extensible to the
-- Pulumi-backend object and others.
data InForceObject = InForceConfig
  deriving (Eq, Show)

inForceObjectName :: InForceObject -> Text
inForceObjectName InForceConfig = "in-force-config"

-- | The additional authenticated data binds the cluster id and object name so
-- an in-force envelope cannot be opened under a different cluster's identity.
inForceAad :: Text -> InForceObject -> ByteString
inForceAad clusterId object =
  case object of
    InForceConfig -> logicalObjectAad clusterId LogicalInForceConfig

-- | Seal in-force payload bytes into a @prodbox-envelope-v2@ envelope bound to
-- this cluster + object. Production passes a Vault-Transit 'DekCipher'; offline
-- tests pass @insecureLocalDekCipher@.
sealInForcePayload
  :: DekCipher -> Text -> ByteString -> IO (Either EnvelopeError ByteString)
sealInForcePayload cipher clusterId payload =
  sealEnvelope cipher (inForceAad clusterId InForceConfig) payload

-- | Open an in-force envelope back to its payload bytes, verifying the cluster
-- + object AAD (a mismatched cluster id fails closed).
openInForcePayload
  :: DekCipher -> Text -> ByteString -> IO (Either EnvelopeError ByteString)
openInForcePayload cipher clusterId envelope =
  openEnvelope cipher (inForceAad clusterId InForceConfig) envelope

data InForceConfigError
  = InForceConfigFetchFailed String
  | InForceConfigOpenFailed EnvelopeError
  | InForceConfigDecodeFailed String
  | InForceConfigSealFailed EnvelopeError
  | InForceConfigStoreFailed String
  deriving (Eq, Show)

renderInForceConfigError :: InForceConfigError -> String
renderInForceConfigError err = case err of
  InForceConfigFetchFailed detail -> "failed to fetch in-force config envelope: " ++ detail
  InForceConfigOpenFailed detail -> "failed to open in-force config envelope: " ++ show detail
  InForceConfigDecodeFailed detail -> "failed to decode in-force config payload: " ++ detail
  InForceConfigSealFailed detail -> "failed to seal in-force config envelope: " ++ show detail
  InForceConfigStoreFailed detail -> "failed to store in-force config envelope: " ++ detail

fetchInForceValueWith
  :: IO (Either String ByteString)
  -> DekCipher
  -> Text
  -> (ByteString -> IO (Either String value))
  -> IO (Either InForceConfigError value)
fetchInForceValueWith fetchEnvelope cipher clusterId decodePayload = do
  fetchResult <- fetchEnvelope
  case fetchResult of
    Left err -> pure (Left (InForceConfigFetchFailed err))
    Right envelope -> do
      openResult <- openInForcePayload cipher clusterId envelope
      case openResult of
        Left err -> pure (Left (InForceConfigOpenFailed err))
        Right payload -> do
          decodeResult <- decodePayload payload
          pure $ case decodeResult of
            Left err -> Left (InForceConfigDecodeFailed err)
            Right config -> Right config

storeInForcePayloadWith
  :: (ByteString -> IO (Either String ()))
  -> DekCipher
  -> Text
  -> ByteString
  -> IO (Either InForceConfigError ())
storeInForcePayloadWith storeEnvelope cipher clusterId payload = do
  sealResult <- sealInForcePayload cipher clusterId payload
  case sealResult of
    Left err -> pure (Left (InForceConfigSealFailed err))
    Right envelope -> do
      storeResult <- storeEnvelope envelope
      pure $ case storeResult of
        Left err -> Left (InForceConfigStoreFailed err)
        Right () -> Right ()

-- | Whether a filesystem config and/or an in-force MinIO envelope are present.
data ConfigSource = ConfigSource
  { configSourceFilePresent :: Bool
  , configSourceInForcePresent :: Bool
  }
  deriving (Eq, Show)

-- | What to do with the two config sources. The filesystem file seeds the
-- encrypted SSoT on first-ever bring-up and is a proposed update thereafter;
-- the in-force MinIO object is the source of truth once it exists.
data SeedProposeDecision
  = -- | No in-force object yet, file present: seed the SSoT from the file.
    SeedInForce
  | -- | In-force object and file both present: the file is a proposed update.
    ProposeUpdate
  | -- | In-force object present, no file: read the SSoT, the file is irrelevant.
    UseInForceAsIs
  | -- | Neither present: nothing to bring the cluster up with.
    NoConfigAvailable
  deriving (Eq, Show)

seedProposeDecision :: ConfigSource -> SeedProposeDecision
seedProposeDecision source =
  case (configSourceInForcePresent source, configSourceFilePresent source) of
    (False, True) -> SeedInForce
    (True, True) -> ProposeUpdate
    (True, False) -> UseInForceAsIs
    (False, False) -> NoConfigAvailable

-- | Whether the caller acts on the root cluster and whether a root Vault token
-- was presented. The root-cluster flag is derived from the unencrypted basics
-- ('Prodbox.Config.Basics.isRootCluster').
data RootWriteAuthority = RootWriteAuthority
  { rootWriteIsRootCluster :: Bool
  , rootWriteTokenPresent :: Bool
  }
  deriving (Eq, Show)

data RootConfigWriteDecision
  = RootWriteAllow
  | RootWriteBlockNoRootToken
  deriving (Eq, Show)

-- | Updating the root cluster's in-force config — which transitively governs
-- every downstream cluster — requires the root Vault token (an unsealed root
-- Vault). A child cluster's write authority is its parent's concern, so it is
-- not gated here.
rootConfigWriteDecision :: RootWriteAuthority -> RootConfigWriteDecision
rootConfigWriteDecision authority
  | rootWriteIsRootCluster authority && not (rootWriteTokenPresent authority) =
      RootWriteBlockNoRootToken
  | otherwise = RootWriteAllow

-- | The fail-closed operator message for a blocked root-config write. 'Nothing'
-- when the write is allowed.
renderRootConfigWriteBlock :: RootConfigWriteDecision -> Maybe String
renderRootConfigWriteBlock decision = case decision of
  RootWriteAllow -> Nothing
  RootWriteBlockNoRootToken ->
    Just
      ( "Blocked: writing the root cluster's in-force config requires the root"
          ++ " Vault token (an unsealed root Vault); it is the keys to every"
          ++ " downstream cluster. No write was started. Run: prodbox vault unseal"
      )
