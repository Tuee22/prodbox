{-# LANGUAGE OverloadedStrings #-}

-- | Exact Vault KV-v2 repository for one retained service-session role lane.
-- The accessor-free batch auditor for that lane is the only writer.  The
-- journal contains only bounded, secret-free CBOR; the worker bearer itself is
-- never persisted.
module Prodbox.ControlPlane.VaultServiceSessionJournal
  ( vaultServiceSessionJournalRepository
  , serviceSessionJournalVaultPath
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionJournal
  , ServiceSessionJournalRepository (..)
  , ServiceSessionJournalSnapshot (..)
  , decodeServiceSessionJournal
  , encodeServiceSessionJournal
  , mkInitialServiceSessionJournal
  , serviceSessionJournalRole
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , KvV2VersionedSecret (..)
  , VaultAddress
  , VaultToken
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )

vaultServiceSessionJournalRepository
  :: VaultAddress
  -> VaultToken
  -> Text
  -> ServiceSessionJournalRepository IO Natural
vaultServiceSessionJournalRepository address token role =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        observed <-
          vaultKvReadVersionedV2
            address
            token
            serviceSessionJournalVaultMount
            (serviceSessionJournalVaultPath role)
        pure $ case observed of
          Left (HttpStatus 404 _) -> do
            initial <- firstText (mkInitialServiceSessionJournal role)
            Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = 0
                , serviceSessionJournalObserved = initial
                }
          Left err -> Left (renderVaultError err)
          Right versioned -> decodeVersioned versioned
    , compareAndSwapServiceSessionJournal = \expected journal ->
        if serviceSessionJournalRole journal /= role
          then pure (Left "service-session journal role mismatch")
          else do
            written <-
              vaultKvCasWriteV2
                address
                token
                serviceSessionJournalVaultMount
                (serviceSessionJournalVaultPath role)
                (KvV2Cas expected)
                (Map.singleton serviceSessionJournalField (encodeJournalField journal))
            pure $ case written of
              Left err -> Left (renderVaultError err)
              Right _ -> Right ()
    }
 where
  decodeVersioned versioned = do
    encoded <- case Map.toList (kvV2VersionedSecretData versioned) of
      [(field, value)]
        | field == serviceSessionJournalField -> Right value
      _ -> Left "service-session journal fields are invalid"
    bytes <- case Base64.decode (TextEncoding.encodeUtf8 encoded) of
      Left _ -> Left "service-session journal base64 is invalid"
      Right value -> Right value
    journal <- firstText (decodeServiceSessionJournal bytes)
    if serviceSessionJournalRole journal == role
      then
        Right
          ServiceSessionJournalSnapshot
            { serviceSessionJournalRevision = kvV2VersionedSecretVersion versioned
            , serviceSessionJournalObserved = journal
            }
      else Left "service-session journal role mismatch"

serviceSessionJournalVaultPath :: Text -> Text
serviceSessionJournalVaultPath role =
  "control-plane/service-sessions/" <> role

serviceSessionJournalVaultMount :: Text
serviceSessionJournalVaultMount = "secret"

serviceSessionJournalField :: Text
serviceSessionJournalField = "journal_cbor_base64"

encodeJournalField :: ServiceSessionJournal -> Text
encodeJournalField =
  TextEncoding.decodeUtf8 . Base64.encode . encodeServiceSessionJournal

renderVaultError :: HttpError -> Text
renderVaultError = Text.take 256 . Text.pack . renderHttpError

firstText :: (Show errorValue) => Either errorValue value -> Either Text value
firstText = either (Left . Text.pack . show) Right
