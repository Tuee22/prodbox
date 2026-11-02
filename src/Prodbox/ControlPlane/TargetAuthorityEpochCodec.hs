{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One CAS row with a checked projection for legacy active-only workers.
-- A present malformed epoch field is never interpreted as a legacy row.
module Prodbox.ControlPlane.TargetAuthorityEpochCodec
  ( TargetAuthorityEpochCodecError (..)
  , targetAuthorityEpochStateMaximumBytes
  , targetAuthorityEpochFieldsMaximumBytes
  , targetAuthorityEpochStateField
  , encodeTargetAuthorityEpochPreparation
  , decodeTargetAuthorityEpochPreparation
  , encodeTargetAuthorityEpochRecord
  , decodeTargetAuthorityEpochRecord
  , encodeTargetAuthorityEpochFields
  , decodeTargetAuthorityEpochFields
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , acceptedTargetAuthorityMaximumEncodedBytes
  , decodeAcceptedTargetAuthority
  , encodeAcceptedTargetAuthority
  )
import Prodbox.Lifecycle.Authority.EpochTopology (cutoverDigestText, mkCutoverDigest)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)

data TargetAuthorityEpochCodecError
  = TargetEpochCodecTooLarge
  | TargetEpochCodecInvalid
  | TargetEpochCodecUnsupportedVersion
  | TargetEpochCodecNonCanonical
  | TargetEpochCodecProjectionMismatch
  | TargetEpochCodecStateInvalid !TargetAuthorityEpochRefusal
  deriving stock (Eq, Show)

-- The state retains the existing accepted-record bound. The entire field map
-- must also fit the existing 16-KiB public-trust response envelope.
targetAuthorityEpochStateMaximumBytes, targetAuthorityEpochFieldsMaximumBytes :: Int
targetAuthorityEpochStateMaximumBytes = acceptedTargetAuthorityMaximumEncodedBytes
targetAuthorityEpochFieldsMaximumBytes = 2 * acceptedTargetAuthorityMaximumEncodedBytes

targetAuthorityEpochStateField :: Text
targetAuthorityEpochStateField = "authority_epoch_state"

activeField :: Text
activeField = "accepted_authority"

data WirePreparation = WirePreparation !Word !Word !Text !Natural !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireTransition
  = WireStable
  | WirePrepared !WirePreparation
  | WirePromoted !WirePreparation
  | WireRetired !WirePreparation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data WireEpochRecord
  = WireEpochRecord
      !Word16
      !TargetSecretId
      !(Maybe ByteString)
      !Word
      !WireTransition
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeTargetAuthorityEpochPreparation
  :: TargetAuthorityEpochPreparation -> Either TargetAuthorityEpochCodecError ByteString
encodeTargetAuthorityEpochPreparation preparation = do
  let bytes = LazyByteString.toStrict (serialise (1 :: Word16, preparationToWire preparation))
  requireSize targetAuthorityEpochStateMaximumBytes bytes
  pure bytes

decodeTargetAuthorityEpochPreparation
  :: ByteString -> Either TargetAuthorityEpochCodecError TargetAuthorityEpochPreparation
decodeTargetAuthorityEpochPreparation bytes = do
  requireSize targetAuthorityEpochStateMaximumBytes bytes
  (version, wire) <-
    first (const TargetEpochCodecInvalid) (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless (version == (1 :: Word16)) (Left TargetEpochCodecUnsupportedVersion)
  preparation <- preparationFromWire wire
  canonical <- encodeTargetAuthorityEpochPreparation preparation
  unless (canonical == bytes) (Left TargetEpochCodecNonCanonical)
  pure preparation

encodeTargetAuthorityEpochRecord
  :: TargetAuthorityEpochRecord -> Either TargetAuthorityEpochCodecError ByteString
encodeTargetAuthorityEpochRecord record = do
  first TargetEpochCodecStateInvalid (validateTargetAuthorityEpochRecord record)
  unless (notEmpty record) (Left TargetEpochCodecInvalid)
  let bytes = LazyByteString.toStrict (serialise (toWire record))
  requireSize targetAuthorityEpochStateMaximumBytes bytes
  pure bytes

decodeTargetAuthorityEpochRecord
  :: ByteString -> Either TargetAuthorityEpochCodecError TargetAuthorityEpochRecord
decodeTargetAuthorityEpochRecord bytes = do
  requireSize targetAuthorityEpochStateMaximumBytes bytes
  wire <- first (const TargetEpochCodecInvalid) (deserialiseOrFail (LazyByteString.fromStrict bytes))
  record <- fromWire wire
  canonical <- encodeTargetAuthorityEpochRecord record
  unless (canonical == bytes) (Left TargetEpochCodecNonCanonical)
  pure record

encodeTargetAuthorityEpochFields
  :: TargetAuthorityEpochRecord -> Either TargetAuthorityEpochCodecError (Map Text Text)
encodeTargetAuthorityEpochFields record = do
  state <- encodeTargetAuthorityEpochRecord record
  let fields =
        Map.fromList
          ( (targetAuthorityEpochStateField, encodeText state)
              : case targetEpochWorkerAuthority record of
                Nothing -> []
                Just active -> [(activeField, encodeText (encodeAcceptedTargetAuthority active))]
          )
  requireFieldsSize fields
  pure fields

decodeTargetAuthorityEpochFields
  :: TargetSecretId
  -> Map Text Text
  -> Either TargetAuthorityEpochCodecError TargetAuthorityEpochRecord
decodeTargetAuthorityEpochFields target fields = do
  requireFieldsSize fields
  case Map.lookup targetAuthorityEpochStateField fields of
    Nothing -> do
      encoded <- maybe (Left TargetEpochCodecInvalid) Right (Map.lookup activeField fields)
      active <- decodeText encoded >>= decodeAuthority
      first TargetEpochCodecStateInvalid (initialTargetAuthorityEpochRecord target (Just active))
    Just encoded -> do
      record <- decodeText encoded >>= decodeTargetAuthorityEpochRecord
      unless
        (targetEpochRecordTarget record == target)
        (Left (TargetEpochCodecStateInvalid TargetEpochTargetMismatch))
      let expected = encodeText . encodeAcceptedTargetAuthority <$> targetEpochWorkerAuthority record
      unless (Map.lookup activeField fields == expected) (Left TargetEpochCodecProjectionMismatch)
      pure record

toWire :: TargetAuthorityEpochRecord -> WireEpochRecord
toWire record =
  WireEpochRecord
    1
    (targetEpochRecordTarget record)
    (encodeAcceptedTargetAuthority <$> targetEpochRecordActive record)
    (targetEpochRecordRetiredThrough record)
    ( case targetEpochRecordTransition record of
        TargetEpochNoTransition -> WireStable
        TargetEpochPrepared preparation -> WirePrepared (preparationToWire preparation)
        TargetEpochPromoted preparation -> WirePromoted (preparationToWire preparation)
        TargetEpochRetired preparation -> WireRetired (preparationToWire preparation)
    )

fromWire :: WireEpochRecord -> Either TargetAuthorityEpochCodecError TargetAuthorityEpochRecord
fromWire (WireEpochRecord version target active retired transition) = do
  unless (version == 1) (Left TargetEpochCodecUnsupportedVersion)
  decodedActive <- traverse decodeAuthority active
  decodedTransition <- case transition of
    WireStable -> Right TargetEpochNoTransition
    WirePrepared preparation -> TargetEpochPrepared <$> preparationFromWire preparation
    WirePromoted preparation -> TargetEpochPromoted <$> preparationFromWire preparation
    WireRetired preparation -> TargetEpochRetired <$> preparationFromWire preparation
  first
    TargetEpochCodecStateInvalid
    (restoreTargetAuthorityEpochRecord target decodedActive retired decodedTransition)

preparationToWire :: TargetAuthorityEpochPreparation -> WirePreparation
preparationToWire preparation =
  WirePreparation
    (targetEpochPredecessor context)
    (targetEpochTarget context)
    (cutoverDigestText (targetEpochTopology context))
    (authorityTimeMicros (targetEpochDeadline context))
    (encodeAcceptedTargetAuthority (targetEpochPreparationAuthority preparation))
 where
  context = targetEpochPreparationContext preparation

preparationFromWire
  :: WirePreparation -> Either TargetAuthorityEpochCodecError TargetAuthorityEpochPreparation
preparationFromWire (WirePreparation predecessor target topology deadline authority) = do
  digest <- maybe (Left TargetEpochCodecInvalid) Right (mkCutoverDigest topology)
  context <-
    first
      TargetEpochCodecStateInvalid
      (mkTargetAuthorityEpochContext predecessor target digest (authorityTimeFromMicros deadline))
  accepted <- decodeAuthority authority
  first TargetEpochCodecStateInvalid (mkTargetAuthorityEpochPreparation context accepted)

decodeAuthority :: ByteString -> Either TargetAuthorityEpochCodecError AcceptedTargetAuthority
decodeAuthority =
  first (const TargetEpochCodecInvalid)
    . decodeAcceptedTargetAuthority acceptedTargetAuthorityMaximumEncodedBytes

encodeText :: ByteString -> Text
encodeText = TextEncoding.decodeUtf8 . Base64.encode

decodeText :: Text -> Either TargetAuthorityEpochCodecError ByteString
decodeText = first (const TargetEpochCodecInvalid) . Base64.decode . TextEncoding.encodeUtf8

requireSize :: Int -> ByteString -> Either TargetAuthorityEpochCodecError ()
requireSize maximumBytes bytes = unless (ByteString.length bytes <= maximumBytes) (Left TargetEpochCodecTooLarge)

requireFieldsSize :: Map Text Text -> Either TargetAuthorityEpochCodecError ()
requireFieldsSize = requireSize targetAuthorityEpochFieldsMaximumBytes . LazyByteString.toStrict . serialise

notEmpty :: TargetAuthorityEpochRecord -> Bool
notEmpty record = case (targetEpochRecordActive record, targetEpochRecordTransition record) of
  (Nothing, TargetEpochNoTransition) -> False
  _ -> True
