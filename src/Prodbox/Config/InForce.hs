{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.38: the in-force cluster configuration as a Vault-Transit-enveloped
-- MinIO object — the configuration source of truth (config_doctrine.md §1a).
-- The filesystem @prodbox-config.dhall@ is a seed/propose input only; the
-- authoritative in-force config lives encrypted in MinIO and is opaque when
-- Vault is sealed.
module Prodbox.Config.InForce
  ( module Prodbox.Config.InForce.Core
  , fetchInForceConfigWith
  , renderInForcePayload
  , storeInForceConfigWith
  )
where

import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.InForce.Core
import Prodbox.Crypto.Envelope (DekCipher)
import Prodbox.Settings (ConfigFile, renderConfigDhall)

-- | Serialize a 'ConfigFile' to the in-force payload bytes (its Dhall text).
-- The reverse decode goes through the Dhall import resolver and is a live edge,
-- so this is intentionally one-way at the pure layer.
renderInForcePayload :: ConfigFile -> ByteString
renderInForcePayload = TextEncoding.encodeUtf8 . Text.pack . renderConfigDhall

fetchInForceConfigWith
  :: IO (Either String ByteString)
  -> DekCipher
  -> Text.Text
  -> (ByteString -> IO (Either String ConfigFile))
  -> IO (Either InForceConfigError ConfigFile)
fetchInForceConfigWith =
  fetchInForceValueWith

storeInForceConfigWith
  :: (ByteString -> IO (Either String ()))
  -> DekCipher
  -> Text.Text
  -> ConfigFile
  -> IO (Either InForceConfigError ())
storeInForceConfigWith storeEnvelope cipher clusterId config =
  storeInForcePayloadWith storeEnvelope cipher clusterId (renderInForcePayload config)
