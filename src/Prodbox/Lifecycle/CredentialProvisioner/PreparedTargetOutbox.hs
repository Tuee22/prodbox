{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Versioned durable envelope for the AWS-admin prepared-target outbox.
-- The legacy payload carried only the prepared observation. New writes retain
-- the complete canonical intent so deadline/image/Agent-bound receipt identity
-- remains independently checkable after a persist-before-state interruption.
module Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
  ( PreparedCredentialTargetOutbox
  , PreparedCredentialTargetOutboxError (..)
  , mkPreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxObservation
  , preparedCredentialTargetOutboxCanonicalIntent
  , preparedCredentialTargetOutboxIsLegacy
  , encodePreparedCredentialTargetOutbox
  , decodePreparedCredentialTargetOutbox
  , preparedCredentialTargetOutboxCodec
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPreparedTargetReceiptDigest
  , decodeAwsAdminPermitIntent
  , encodeAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , decodePreparedCredentialTargetObservation
  , encodePreparedCredentialTargetObservation
  , preparedCredentialTargetFence
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetReceiptDigest
  , preparedCredentialTargetSelectedAgent
  )

data PreparedCredentialTargetOutbox
  = LegacyPreparedCredentialTargetOutbox !PreparedCredentialTargetObservation
  | CanonicalPreparedCredentialTargetOutbox !AwsAdminPermitIntent
  deriving stock (Eq, Show)

data PreparedCredentialTargetOutboxError
  = PreparedCredentialTargetOutboxTooLarge !Int !Int
  | PreparedCredentialTargetOutboxDecodeFailed
  | PreparedCredentialTargetOutboxDomainInvalid
  | PreparedCredentialTargetOutboxUnsupportedVersion !Word16
  | PreparedCredentialTargetOutboxIntentInvalid
  | PreparedCredentialTargetOutboxReceiptInvalid
  | PreparedCredentialTargetOutboxNonCanonical
  deriving stock (Eq, Show)

data WirePreparedCredentialTargetOutbox = WirePreparedCredentialTargetOutbox
  { wirePreparedTargetOutboxDomain :: !Text
  , wirePreparedTargetOutboxVersion :: !Word16
  , wirePreparedTargetOutboxIntent :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

preparedCredentialTargetOutboxDomain :: Text
preparedCredentialTargetOutboxDomain = "prodbox-aws-admin-prepared-target-outbox"

preparedCredentialTargetOutboxVersion :: Word16
preparedCredentialTargetOutboxVersion = 2

preparedCredentialTargetOutboxMaximumBytes :: Int
preparedCredentialTargetOutboxMaximumBytes = 192 * 1024

mkPreparedCredentialTargetOutbox
  :: AwsAdminPermitIntent
  -> Either PreparedCredentialTargetOutboxError PreparedCredentialTargetOutbox
mkPreparedCredentialTargetOutbox intent = do
  validated <- validateCanonicalOutboxIntent intent
  pure (CanonicalPreparedCredentialTargetOutbox validated)

preparedCredentialTargetOutboxObservation
  :: PreparedCredentialTargetOutbox
  -> PreparedCredentialTargetObservation
preparedCredentialTargetOutboxObservation outbox = case outbox of
  LegacyPreparedCredentialTargetOutbox prepared -> prepared
  CanonicalPreparedCredentialTargetOutbox intent ->
    awsAdminPermitIntentPreparedTarget intent

preparedCredentialTargetOutboxCanonicalIntent
  :: PreparedCredentialTargetOutbox
  -> Maybe AwsAdminPermitIntent
preparedCredentialTargetOutboxCanonicalIntent outbox = case outbox of
  LegacyPreparedCredentialTargetOutbox _ -> Nothing
  CanonicalPreparedCredentialTargetOutbox intent -> Just intent

preparedCredentialTargetOutboxIsLegacy :: PreparedCredentialTargetOutbox -> Bool
preparedCredentialTargetOutboxIsLegacy outbox = case outbox of
  LegacyPreparedCredentialTargetOutbox _ -> True
  CanonicalPreparedCredentialTargetOutbox _ -> False

encodePreparedCredentialTargetOutbox
  :: PreparedCredentialTargetOutbox
  -> ByteString
encodePreparedCredentialTargetOutbox outbox = case outbox of
  LegacyPreparedCredentialTargetOutbox prepared ->
    encodePreparedCredentialTargetObservation prepared
  CanonicalPreparedCredentialTargetOutbox intent ->
    LazyByteString.toStrict
      ( serialise
          WirePreparedCredentialTargetOutbox
            { wirePreparedTargetOutboxDomain = preparedCredentialTargetOutboxDomain
            , wirePreparedTargetOutboxVersion = preparedCredentialTargetOutboxVersion
            , wirePreparedTargetOutboxIntent = encodeAwsAdminPermitIntent intent
            }
      )

decodePreparedCredentialTargetOutbox
  :: ByteString
  -> Either PreparedCredentialTargetOutboxError PreparedCredentialTargetOutbox
decodePreparedCredentialTargetOutbox bytes = do
  when
    (ByteString.length bytes > preparedCredentialTargetOutboxMaximumBytes)
    ( Left
        ( PreparedCredentialTargetOutboxTooLarge
            (ByteString.length bytes)
            preparedCredentialTargetOutboxMaximumBytes
        )
    )
  case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Right wire -> decodeCurrent wire
    Left _ ->
      LegacyPreparedCredentialTargetOutbox
        <$> first
          (const PreparedCredentialTargetOutboxDecodeFailed)
          (decodePreparedCredentialTargetObservation bytes)
 where
  decodeCurrent wire = do
    unless
      (wirePreparedTargetOutboxDomain wire == preparedCredentialTargetOutboxDomain)
      (Left PreparedCredentialTargetOutboxDomainInvalid)
    unless
      (wirePreparedTargetOutboxVersion wire == preparedCredentialTargetOutboxVersion)
      ( Left
          ( PreparedCredentialTargetOutboxUnsupportedVersion
              (wirePreparedTargetOutboxVersion wire)
          )
      )
    intent <-
      first
        (const PreparedCredentialTargetOutboxIntentInvalid)
        (decodeAwsAdminPermitIntent (wirePreparedTargetOutboxIntent wire))
    validated <- validateCanonicalOutboxIntent intent
    let outbox = CanonicalPreparedCredentialTargetOutbox validated
    unless
      (encodePreparedCredentialTargetOutbox outbox == bytes)
      (Left PreparedCredentialTargetOutboxNonCanonical)
    pure outbox

validateCanonicalOutboxIntent
  :: AwsAdminPermitIntent
  -> Either PreparedCredentialTargetOutboxError AwsAdminPermitIntent
validateCanonicalOutboxIntent intent = do
  canonical <-
    first
      (const PreparedCredentialTargetOutboxIntentInvalid)
      (decodeAwsAdminPermitIntent (encodeAwsAdminPermitIntent intent))
  unless (canonical == intent) (Left PreparedCredentialTargetOutboxNonCanonical)
  let prepared = awsAdminPermitIntentPreparedTarget canonical
      expectedReceipt =
        awsAdminPreparedTargetReceiptDigest
          (preparedCredentialTargetOwnerNonce prepared)
          (preparedCredentialTargetFence prepared)
          (preparedCredentialTargetSelectedAgent prepared)
          canonical
  unless
    (preparedCredentialTargetReceiptDigest prepared == expectedReceipt)
    (Left PreparedCredentialTargetOutboxReceiptInvalid)
  pure canonical

preparedCredentialTargetOutboxCodec
  :: ModelBCodec PreparedCredentialTargetOutbox
preparedCredentialTargetOutboxCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodePreparedCredentialTargetOutbox
    , decodeModelBValue = first show . decodePreparedCredentialTargetOutbox
    }
