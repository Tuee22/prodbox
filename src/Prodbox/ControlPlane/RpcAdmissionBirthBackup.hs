{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Backup encoding preserves every retained birth fence. Restoring the decoded
-- pair still requires the registered repair interpreter and independent config pin.
module Prodbox.ControlPlane.RpcAdmissionBirthBackup
  ( encodeRpcBirthBackup
  , decodeRpcBirthBackup
  , rpcBirthNativeBackupEnvelope
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthExecution (rpcBirthNormalAdmission)
import Prodbox.ControlPlane.RpcAdmissionBirthNative
  ( RpcBirthNativeBackend
  , observeRpcBirthNativeRecords
  )
import Prodbox.Lifecycle.Authority.Admission (AuthorityAdmissionAggregate)
import Prodbox.Lifecycle.CheckpointAuthority

data RpcBirthBackupWire = RpcBirthBackupWire !Word !ByteString !(Maybe ByteString)
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

backupPrefix :: ByteString
backupPrefix = "prodbox-rpc-birth-backup/v1\NUL"

maximumBytes :: Int
maximumBytes = 1024 * 1024

encodeRpcBirthBackup
  :: RpcBirthServingMode
  -> ModelBCodec RpcBirthRecord
  -> ModelBCodec RpcBirthMarker
  -> RpcBirthRecord
  -> Maybe RpcBirthMarker
  -> Either RpcBirthError ByteString
encodeRpcBirthBackup mode recordCodec markerCodec record marker = do
  validate mode record marker
  raw <- first (const RpcBirthStateInvalid) (encodeModelBValue recordCodec record)
  encodedMarker <-
    traverse (first (const RpcBirthStateInvalid) . encodeModelBValue markerCodec) marker
  let bytes =
        if rpcBirthPhase record == BirthLegacy
          then raw
          else backupPrefix <> Lazy.toStrict (serialise (RpcBirthBackupWire 1 raw encodedMarker))
  unless (BS.length bytes <= maximumBytes) (Left RpcBirthStateTooLarge)
  pure bytes

decodeRpcBirthBackup
  :: RpcBirthServingMode
  -> ModelBCodec RpcBirthRecord
  -> ModelBCodec RpcBirthMarker
  -> ByteString
  -> Either RpcBirthError (RpcBirthRecord, Maybe RpcBirthMarker)
decodeRpcBirthBackup mode recordCodec markerCodec bytes = do
  unless (BS.length bytes <= maximumBytes) (Left RpcBirthStateTooLarge)
  (record, marker) <- case BS.stripPrefix backupPrefix bytes of
    Nothing -> do
      legacy <- first (const RpcBirthStateInvalid) (decodeModelBValue recordCodec bytes)
      unless (rpcBirthPhase legacy == BirthLegacy) (Left RpcBirthStateInvalid)
      pure (legacy, Nothing)
    Just raw -> do
      wire@(RpcBirthBackupWire version primary anchor) <-
        first (const RpcBirthStateInvalid) (deserialiseOrFail (Lazy.fromStrict raw))
      unless (version == 1 && Lazy.toStrict (serialise wire) == raw) (Left RpcBirthStateInvalid)
      primaryRecord <- first (const RpcBirthStateInvalid) (decodeModelBValue recordCodec primary)
      unless (rpcBirthPhase primaryRecord /= BirthLegacy) (Left RpcBirthStateInvalid)
      anchorRecord <- traverse (first (const RpcBirthStateInvalid) . decodeModelBValue markerCodec) anchor
      pure (primaryRecord, anchorRecord)
  validate mode record marker
  pure (record, marker)

validate :: RpcBirthServingMode -> RpcBirthRecord -> Maybe RpcBirthMarker -> Either RpcBirthError ()
validate mode record marker = do
  version <- first (const RpcBirthStateInvalid) (mkModelBObjectVersion "backup-validation")
  _ <-
    rpcBirthNormalAdmission
      mode
      (ModelBObserved version record)
      (maybe ModelBMissing (ModelBObserved version) marker)
  pure ()

rpcBirthNativeBackupEnvelope
  :: ModelBCodec RpcBirthRecord
  -> ModelBCodec RpcBirthMarker
  -> RpcBirthNativeBackend
  -> RpcBirthServingMode
  -> AuthorityAdmissionAggregate
  -> IO (Either Text ByteString)
rpcBirthNativeBackupEnvelope recordCodec markerCodec backend mode expected = do
  (record, marker) <- observeRpcBirthNativeRecords backend
  pure $ first (Text.pack . show) $ do
    selected <- rpcBirthNormalAdmission mode record marker
    unless (fmap snd selected == Just expected) (Left RpcBirthWriteUnconfirmed)
    value <- case record of
      ModelBObserved _ value -> Right value
      _ -> Left RpcBirthAdmissionMissing
    anchor <- case marker of
      ModelBMissing -> Right Nothing
      ModelBObserved _ observedMarker -> Right (Just observedMarker)
      _ -> Left RpcBirthObservationUnavailable
    encodeRpcBirthBackup mode recordCodec markerCodec value anchor
