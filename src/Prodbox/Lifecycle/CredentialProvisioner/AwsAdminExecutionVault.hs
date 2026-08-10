{-# LANGUAGE OverloadedStrings #-}

-- | Permit-scoped Vault KV-v2 repository for the secret-free AWS-admin
-- execution journal. The path is a SHA-256 coordinate, never a caller
-- identifier, and every write is CAS-confirmed by an exact canonical readback.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionVault
  ( vaultAwsAdminExecutionJournalBoundary
  , awsAdminExecutionJournalVaultPath
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminExecutionJournalBoundary
  , mkAwsAdminExecutionJournalBoundary
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionJournal
  ( AwsAdminExecutionJournal
  , awsAdminExecutionJournalPermit
  , decodeAwsAdminExecutionJournal
  , encodeAwsAdminExecutionJournal
  , initialAwsAdminExecutionJournal
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , encodeSignedAwsAdminPermit
  )
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , KvV2VersionedSecret (..)
  , VaultAddress
  , VaultCasOutcome (..)
  , VaultToken
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )

vaultAwsAdminExecutionJournalBoundary
  :: VaultAddress
  -> VaultToken
  -> SignedAwsAdminPermit
  -> AwsAdminExecutionJournalBoundary IO
vaultAwsAdminExecutionJournalBoundary address token permit =
  mkAwsAdminExecutionJournalBoundary
    readOrInitialize
    commitExact
 where
  initial = initialAwsAdminExecutionJournal permit
  path = awsAdminExecutionJournalVaultPath permit

  readOrInitialize = do
    observed <- observeJournal address token path
    case observed of
      Left detail -> pure (Left detail)
      Right (Just (_, journal)) ->
        pure
          ( if journal == initial || journalPermitMatches permit journal
              then Right journal
              else Left "AWS-admin execution journal permit mismatch"
          )
      Right Nothing -> do
        attempted <- writeJournal address token path 0 initial
        confirmJournal address token path initial attempted

  commitExact expected next = do
    observed <- observeJournal address token path
    case observed of
      Left detail -> pure (Left detail)
      Right (Just (_, current))
        | current == next -> pure (Right next)
      Right (Just (version, current))
        | current == expected -> do
            attempted <- writeJournal address token path version next
            confirmJournal address token path next attempted
        | otherwise -> pure (Left "AWS-admin execution journal CAS conflict")
      Right Nothing
        | expected == initial -> do
            attempted <- writeJournal address token path 0 next
            confirmJournal address token path next attempted
        | otherwise -> pure (Left "AWS-admin execution journal disappeared")

-- The journal decoder already validates the embedded permit. This extra
-- canonical equality check keeps the repository's permit scope explicit.
journalPermitMatches
  :: SignedAwsAdminPermit -> AwsAdminExecutionJournal -> Bool
journalPermitMatches expected = (== expected) . awsAdminExecutionJournalPermit

observeJournal
  :: VaultAddress
  -> VaultToken
  -> Text
  -> IO (Either Text (Maybe (Natural, AwsAdminExecutionJournal)))
observeJournal address token path = do
  observed <-
    vaultKvReadVersionedV2
      address
      token
      executionJournalVaultMount
      path
  pure $ case observed of
    Left (HttpStatus 404 _) -> Right Nothing
    Left err -> Left (renderVaultError err)
    Right versioned -> Just <$> decodeVersioned versioned

decodeVersioned
  :: KvV2VersionedSecret
  -> Either Text (Natural, AwsAdminExecutionJournal)
decodeVersioned versioned = do
  encoded <- case Map.toList (kvV2VersionedSecretData versioned) of
    [(field, value)]
      | field == executionJournalField -> Right value
    _ -> Left "AWS-admin execution journal fields are invalid"
  bytes <- case Base64.decode (TextEncoding.encodeUtf8 encoded) of
    Left _ -> Left "AWS-admin execution journal base64 is invalid"
    Right value -> Right value
  journal <-
    either
      (Left . Text.take 256 . Text.pack . show)
      Right
      (decodeAwsAdminExecutionJournal bytes)
  pure (kvV2VersionedSecretVersion versioned, journal)

writeJournal
  :: VaultAddress
  -> VaultToken
  -> Text
  -> Natural
  -> AwsAdminExecutionJournal
  -> IO (Either Text ())
writeJournal address token path expectedVersion journal = do
  written <-
    vaultKvCasWriteV2
      address
      token
      executionJournalVaultMount
      path
      (KvV2Cas expectedVersion)
      ( Map.singleton
          executionJournalField
          ( TextEncoding.decodeUtf8
              (Base64.encode (encodeAwsAdminExecutionJournal journal))
          )
      )
  -- Sprint 4.74: the confirm step below reads back, so this arm only has to
  -- name which of the three failures occurred rather than decide recovery.
  pure $ case classifyVaultCasOutcome written of
    VaultCasApplied _ -> Right ()
    failed -> Left (renderVaultCasOutcome failed)

-- A successful write response is provisional, while a failed response may
-- have been lost after commit. Only exact canonical readback closes the CAS.
confirmJournal
  :: VaultAddress
  -> VaultToken
  -> Text
  -> AwsAdminExecutionJournal
  -> Either Text ()
  -> IO (Either Text AwsAdminExecutionJournal)
confirmJournal address token path expected attempted = do
  observed <- observeJournal address token path
  pure $ case observed of
    Right (Just (_, actual))
      | actual == expected -> Right actual
    Right _ ->
      Left
        ( either
            (<> "; exact readback mismatched")
            (const "AWS-admin execution journal exact readback mismatched")
            attempted
        )
    Left detail ->
      Left
        ( either
            (<> "; readback failed: " <> detail)
            (const detail)
            attempted
        )

awsAdminExecutionJournalVaultPath :: SignedAwsAdminPermit -> Text
awsAdminExecutionJournalVaultPath permit =
  "control-plane/aws-admin-executions/" <> sha256Text (encodeSignedAwsAdminPermit permit)

executionJournalVaultMount :: Text
executionJournalVaultMount = "secret"

executionJournalField :: Text
executionJournalField = "journal_cbor_base64"

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

renderVaultError :: HttpError -> Text
renderVaultError = Text.take 256 . Text.pack . renderHttpError
