{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.37: production Vault-Transit binding for the envelope
-- 'DekCipher'. The cryptographic envelope stays independent of Vault for
-- tests, while production wraps and unwraps data-encryption keys with the
-- configured Transit key.
module Prodbox.Vault.TransitCipher
  ( vaultTransitDekCipher
  , vaultTransitDekCipherWith
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.Crypto.Envelope (DekCipher (..))
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Vault.Client
  ( VaultAddress
  , VaultToken
  , vaultTransitDecrypt
  , vaultTransitEncrypt
  )

-- | Build a 'DekCipher' from already-shaped wrap/unwrap functions. This is the
-- pure-test seam; production should use 'vaultTransitDekCipher'.
vaultTransitDekCipherWith
  :: (ByteString -> IO (Either String Text))
  -> (Text -> IO (Either String ByteString))
  -> DekCipher
vaultTransitDekCipherWith wrap unwrap =
  DekCipher
    { dekWrap = wrap
    , dekUnwrap = unwrap
    }

-- | Production 'DekCipher' that delegates DEK wrap/unwrap to Vault Transit.
-- Any Vault HTTP/decode failure is surfaced as a wrap/unwrap failure in the
-- envelope layer, so callers fail closed when Vault is sealed or unreachable.
vaultTransitDekCipher :: VaultAddress -> VaultToken -> Text -> DekCipher
vaultTransitDekCipher address token keyName =
  vaultTransitDekCipherWith
    ( \dek -> do
        result <- vaultTransitEncrypt address token keyName dek
        pure (mapLeft renderHttpError result)
    )
    ( \wrappedDek -> do
        result <- vaultTransitDecrypt address token keyName wrappedDek
        pure (mapLeft renderHttpError result)
    )

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f value = case value of
  Left err -> Left (f err)
  Right ok -> Right ok
