{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production Vault binding for the retained-home custody worker.
--
-- The only public constructor fixes the KV mount, schema-derived path, Transit
-- key, and HMAC key.  The resulting boundary therefore cannot be reused as an
-- arbitrary Vault reader, decrypt service, or secret-path writer.
module Prodbox.ControlPlane.RetainedMaterialWorkerVault
  ( retainedCustodyVaultBoundary
  )
where

import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.RetainedMaterialWorker
  ( RetainedCustodyDataObservation (..)
  , RetainedCustodyMetadataObservation (..)
  , RetainedCustodyVaultBoundary (..)
  , RetainedCustodyVersionObservation (..)
  , retainedCustodyCommitmentKey
  , retainedCustodyDataPath
  , retainedCustodyTransitKey
  )
import Prodbox.Http.Client
  ( HttpError (HttpStatus)
  , renderHttpError
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema
  )
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , KvV2ExactVersionSecret (..)
  , KvV2SecretMetadata (..)
  , KvV2VersionedSecret (..)
  , VaultCasOutcome (..)
  , VaultToken
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKvCasWriteV2
  , vaultKvDestroyVersionV2
  , vaultKvReadExactVersionV2
  , vaultKvReadMetadataV2
  , vaultKvReadVersionedV2
  , vaultKvWriteCustomMetadataV2
  , vaultTransitDecrypt
  , vaultTransitEncrypt
  , vaultTransitHmacSha256
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

retainedCustodyVaultBoundary
  :: VaultSession
  -> SRetainedMaterialSchema schema
  -> RetainedCustodyVaultBoundary schema IO
retainedCustodyVaultBoundary session schema =
  RetainedCustodyVaultBoundary
    { retainedCustodyReadCurrentData = readCurrent
    , retainedCustodyReadMetadata = readMetadata
    , retainedCustodyReadVersion = readVersion
    , retainedCustodyTransitEncrypt = transitEncrypt
    , retainedCustodyTransitDecrypt = transitDecrypt
    , retainedCustodyHmac = transitHmac
    , retainedCustodyCompareAndSwap = compareAndSwap
    , retainedCustodyWriteMetadata = writeMetadata
    , retainedCustodyTombstoneVersion = tombstoneVersion
    , retainedCustodyObserveVersionAbsent = observeVersionAbsent
    }
 where
  address = sessionAddress session
  path = retainedCustodyDataPath schema

  readCurrent = do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadVersionedV2 address token retainedCustodyMount path
    pure $ case result of
      Left (HttpStatus 404 _) -> Right RetainedCustodyDataMissing
      Left err -> Left (renderVaultError err)
      Right versioned ->
        Right
          ( RetainedCustodyDataPresent
              (kvV2VersionedSecretVersion versioned)
              (kvV2VersionedSecretData versioned)
          )

  readMetadata = do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadMetadataV2 address token retainedCustodyMount path
    pure $ case result of
      Left (HttpStatus 404 _) -> Right RetainedCustodyMetadataMissing
      Left err -> Left (renderVaultError err)
      Right metadata ->
        Right
          ( RetainedCustodyMetadataPresent
              (kvV2SecretMetadataCurrentVersion metadata)
              (kvV2SecretMetadataCustom metadata)
          )

  readVersion version = do
    result <- readExact version
    pure $ case result of
      Left err -> Left err
      Right ExactVersionPhysicallyAbsent -> Right RetainedCustodyVersionMissing
      Right (ExactVersionPresent fields) ->
        Right (RetainedCustodyVersionPresent fields)
      Right ExactVersionSoftDeleted ->
        Left "retained custody version is only soft-deleted"

  transitEncrypt plaintext =
    vaultSessionCall
      session
      (\token -> vaultTransitEncrypt address token retainedCustodyTransitKey plaintext)

  transitDecrypt ciphertext =
    vaultSessionCall
      session
      (\token -> vaultTransitDecrypt address token retainedCustodyTransitKey ciphertext)

  transitHmac input =
    vaultSessionCall
      session
      (\token -> vaultTransitHmacSha256 address token retainedCustodyCommitmentKey input)

  -- Sprint 4.74: this lane classifies rather than rendering the transport
  -- error, so the operator learns whether another writer won, the request was
  -- refused, or the attempt's outcome is unknown. `applyCas` in
  -- "Prodbox.ControlPlane.RetainedMaterialWorker" recovers by authoritative
  -- read-back on every failure, which is the right response to all three arms,
  -- so what this changes is what the failure says and not what it does — and it
  -- is the eleventh call site, found by the sprint's own `dev check` rule rather
  -- than by the ledger row, which named three.
  compareAndSwap expected fields = do
    written <-
      withSessionToken session $ \token ->
        vaultKvCasWriteV2
          address
          token
          retainedCustodyMount
          path
          (KvV2Cas expected)
          fields
    pure $ case classifyVaultCasOutcome written of
      VaultCasApplied version -> Right version
      failed -> Left (renderVaultCasOutcome failed)

  writeMetadata fields =
    vaultSessionCall
      session
      ( \token ->
          vaultKvWriteCustomMetadataV2
            address
            token
            retainedCustodyMount
            path
            fields
      )

  tombstoneVersion version =
    vaultSessionCall
      session
      ( \token ->
          vaultKvDestroyVersionV2
            address
            token
            retainedCustodyMount
            path
            version
      )

  observeVersionAbsent version = do
    result <- readExact version
    pure $ case result of
      Left err -> Left err
      Right ExactVersionPhysicallyAbsent -> Right True
      Right ExactVersionSoftDeleted -> Right False
      Right (ExactVersionPresent _) -> Right False

  readExact version = do
    result <-
      withSessionToken session $ \token ->
        vaultKvReadExactVersionV2
          address
          token
          retainedCustodyMount
          path
          version
    pure $ case result of
      Left (HttpStatus 404 _) -> Right ExactVersionPhysicallyAbsent
      Left err -> Left (renderVaultError err)
      Right exact
        | kvV2ExactVersionSecretVersion exact /= version ->
            Left "Vault returned a different retained custody version"
        | kvV2ExactVersionSecretDestroyed exact ->
            Right ExactVersionPhysicallyAbsent
        | otherwise -> case kvV2ExactVersionSecretData exact of
            Nothing -> Right ExactVersionSoftDeleted
            Just fields -> Right (ExactVersionPresent fields)

data ExactVersionObservation
  = ExactVersionPhysicallyAbsent
  | ExactVersionSoftDeleted
  | ExactVersionPresent !(Map Text Text)

retainedCustodyMount :: Text
retainedCustodyMount = "secret"

renderVaultError :: HttpError -> Text
renderVaultError = Text.pack . renderHttpError

vaultSessionCall
  :: VaultSession
  -> (VaultToken -> IO (Either HttpError value))
  -> IO (Either Text value)
vaultSessionCall session operation =
  first renderVaultError <$> withSessionToken session operation
