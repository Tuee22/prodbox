{-# LANGUAGE OverloadedStrings #-}

-- | Production adapter from the bounded target-intent protocol to the
-- gateway's allowlisted Vault KV v2 CAS/readback route.  It uses only the
-- explicit 'TargetClusterSecretSink'; no kube context, ambient gateway, host
-- root token, or retained-authority coordinate participates.
module Prodbox.Lifecycle.TargetSecretStore
  ( gatewayTargetSecretAdapter
  , observeGatewayTargetSecret
  , compareAndSwapGatewayTargetSecret
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Gateway.Client
  ( compareAndSwapTargetSecret
  , getTargetSecret
  , renderGatewayError
  )
import Prodbox.Gateway.TargetSecret qualified as Wire
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , targetSecretSinkGatewayEndpoint
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.Lease
  ( fencingTokenValue
  , mkFencingToken
  , mkOwnerNonce
  , ownerNonceText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkCasAdapter (..)
  , TargetSinkCasRequest (..)
  , TargetSinkCasResult (..)
  , TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetSinkVersion
  , mkTargetValueDigest
  , targetSinkVersionText
  , targetValueDigestText
  )
import Text.Read (readMaybe)

gatewayTargetSecretAdapter
  :: TargetSinkCasAdapter IO (Map Text Text)
gatewayTargetSecretAdapter =
  TargetSinkCasAdapter
    { targetSinkObserve = observeGatewayTargetSecret
    , targetSinkCompareAndSwap = compareAndSwapGatewayTargetSecret
    }

observeGatewayTargetSecret
  :: TargetClusterSecretSink
  -> IO (TargetSinkObservation (Map Text Text))
observeGatewayTargetSecret sink = do
  result <-
    getTargetSecret
      (Text.unpack (targetSecretSinkGatewayEndpoint sink))
      Wire.TargetSecretReadRequest
        { Wire.targetSecretReadCoordinate = wireCoordinate sink
        , Wire.targetSecretReadLoopbackNodePortVerified = True
        }
  pure $ case result of
    Left err -> TargetSinkUnobservable (Text.pack (renderGatewayError err))
    Right observation -> either TargetSinkUnobservable id (decodeWireObservation observation)

compareAndSwapGatewayTargetSecret
  :: TargetSinkCasRequest (Map Text Text)
  -> IO (TargetSinkCasResult (Map Text Text))
compareAndSwapGatewayTargetSecret request =
  case requestParts request of
    Left refusal -> pure (TargetSinkCasRefused refusal)
    Right (sink, record, wireRequest) -> do
      result <-
        compareAndSwapTargetSecret
          (Text.unpack (targetSecretSinkGatewayEndpoint sink))
          wireRequest
      pure $ case result of
        Left err -> TargetSinkCasUnobservable (Text.pack (renderGatewayError err))
        Right (Wire.TargetSecretCasApplied version) ->
          case targetVersion version of
            Left refusal -> TargetSinkCasRefused refusal
            Right appliedVersion -> TargetSinkCasApplied appliedVersion record
        Right (Wire.TargetSecretCasConflict observation) ->
          case decodeWireObservation observation of
            Left detail -> TargetSinkCasUnobservable detail
            Right conflict -> TargetSinkCasConflict conflict
 where
  requestParts action = case action of
    TargetSinkInitialize sink record ->
      validatedRequest sink 0 record
    TargetSinkReplace sink version record -> do
      expectedVersion <- parseTargetVersion version
      validatedRequest sink expectedVersion record

  validatedRequest sink expectedVersion record = do
    let wireRequest =
          Wire.TargetSecretCasRequest
            { Wire.targetSecretCasCoordinate = wireCoordinate sink
            , Wire.targetSecretCasExpectedVersion = expectedVersion
            , Wire.targetSecretCasRecord = encodeWireRecord record
            , Wire.targetSecretCasLoopbackNodePortVerified = True
            }
    case Wire.validateTargetSecretCasRequest wireRequest of
      Left err -> Left (Text.pack (show err))
      Right validated -> Right (sink, record, validated)

wireCoordinate :: TargetClusterSecretSink -> Wire.TargetSecretCoordinate
wireCoordinate sink =
  Wire.TargetSecretCoordinate
    { Wire.targetSecretCoordinateIdentity = targetSecretSinkIdentity sink
    , Wire.targetSecretCoordinateVaultMount = targetSecretSinkVaultMount sink
    , Wire.targetSecretCoordinateKvPath = targetSecretSinkKvPath sink
    }

encodeWireRecord
  :: TargetSinkRecord (Map Text Text) -> Wire.TargetSecretRecord
encodeWireRecord record =
  Wire.TargetSecretRecord
    { Wire.targetSecretRecordOwnerNonce = ownerNonceText (targetSinkRecordOwnerNonce record)
    , Wire.targetSecretRecordFencingToken =
        fencingTokenValue (targetSinkRecordFencingToken record)
    , Wire.targetSecretRecordGeneration =
        credentialGenerationValue (targetSinkRecordGeneration record)
    , Wire.targetSecretRecordDigest =
        targetValueDigestText (targetSinkRecordDigest record)
    , Wire.targetSecretRecordFields = targetSinkRecordPayload record
    }

decodeWireObservation
  :: Wire.TargetSecretObservation
  -> Either Text (TargetSinkObservation (Map Text Text))
decodeWireObservation observation = case observation of
  Wire.TargetSecretMissing -> Right TargetSinkMissing
  Wire.TargetSecretObserved version record -> do
    unlessPositive "Vault target-secret version" version
    decodedVersion <- targetVersion version
    decodedRecord <- decodeWireRecord record
    Right (TargetSinkObserved decodedVersion decodedRecord)

decodeWireRecord
  :: Wire.TargetSecretRecord
  -> Either Text (TargetSinkRecord (Map Text Text))
decodeWireRecord record = do
  owner <- mapLeftShow (mkOwnerNonce (Wire.targetSecretRecordOwnerNonce record))
  fence <- mapLeftShow (mkFencingToken (Wire.targetSecretRecordFencingToken record))
  generation <- mapLeftShow (mkCredentialGeneration (Wire.targetSecretRecordGeneration record))
  digest <- mapLeftShow (mkTargetValueDigest (Wire.targetSecretRecordDigest record))
  Right
    TargetSinkRecord
      { targetSinkRecordOwnerNonce = owner
      , targetSinkRecordFencingToken = fence
      , targetSinkRecordGeneration = generation
      , targetSinkRecordDigest = digest
      , targetSinkRecordPayload = Wire.targetSecretRecordFields record
      }

targetVersion :: Natural -> Either Text TargetSinkVersion
targetVersion version = do
  unlessPositive "Vault target-secret version" version
  mapLeftShow (mkTargetSinkVersion (Text.pack (show version)))

parseTargetVersion :: TargetSinkVersion -> Either Text Natural
parseTargetVersion version =
  case readMaybe (Text.unpack (targetSinkVersionText version)) of
    Just parsed | parsed > 0 -> Right parsed
    _ -> Left "target-secret CAS version is not a positive Vault KV version"

unlessPositive :: Text -> Natural -> Either Text ()
unlessPositive label value
  | value == 0 = Left (label <> " must be positive")
  | otherwise = Right ()

mapLeftShow :: (Show errorValue) => Either errorValue value -> Either Text value
mapLeftShow = either (Left . Text.pack . show) Right
