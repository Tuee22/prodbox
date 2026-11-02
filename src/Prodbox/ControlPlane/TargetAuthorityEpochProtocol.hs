{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded staging messages carried by the existing public-trust route.
-- The prefix is distinct from every canonical legacy accepted-authority CBOR.
module Prodbox.ControlPlane.TargetAuthorityEpochProtocol
  ( TargetEpochRequest (..)
  , TargetEpochResponse (..)
  , TargetEpochProtocolError (..)
  , targetEpochRequestMaximumBytes
  , targetEpochResponseMaximumBytes
  , isTargetEpochRequest
  , encodeTargetEpochRequest
  , decodeTargetEpochRequest
  , encodeTargetEpochResponse
  , decodeTargetEpochResponse
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochCodec
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
  ( TargetEpochMutationDisposition (..)
  , TargetEpochMutationResult (..)
  , TargetEpochObservation
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)

data TargetEpochRequest
  = TargetEpochMutate !TargetAuthorityEpochAction
  | TargetEpochObserve !TargetSecretId
  deriving stock (Eq, Show)

data TargetEpochResponse
  = TargetEpochMutated !TargetEpochMutationResult
  | TargetEpochObserved !TargetSecretId !TargetEpochObservation
  deriving stock (Eq, Show)

data TargetEpochProtocolError
  = TargetEpochProtocolTooLarge
  | TargetEpochProtocolPrefixMissing
  | TargetEpochProtocolWireInvalid !ControlPlaneRequestCodecError
  | TargetEpochProtocolStateInvalid !TargetAuthorityEpochCodecError
  | TargetEpochProtocolReadBackInvalid
  deriving stock (Eq, Show)

targetEpochRequestMaximumBytes, targetEpochResponseMaximumBytes :: Int
targetEpochRequestMaximumBytes = targetAuthorityEpochStateMaximumBytes
-- Record plus framing fits inside the existing 16-KiB outer trust response.
targetEpochResponseMaximumBytes = targetAuthorityEpochStateMaximumBytes + 1024

stagingPrefix :: ByteString
stagingPrefix = "prodbox-target-epoch\NUL"

isTargetEpochRequest :: ByteString -> Bool
isTargetEpochRequest = ByteString.isPrefixOf stagingPrefix

data WireRequest
  = WirePrepare !ByteString
  | WirePromote !ByteString
  | WireRetire !ByteString
  | WireObserve !TargetSecretId
  deriving stock (Generic)
  deriving anyclass (Serialise)

data WireDisposition = WireAlreadyObserved | WireApplied | WireRecovered
  deriving stock (Generic)
  deriving anyclass (Serialise)

data WireResponse
  = WireMutated !WireDisposition !Natural !ByteString
  | WireObserved !TargetSecretId !(Maybe (Natural, ByteString))
  deriving stock (Generic)
  deriving anyclass (Serialise)

encodeTargetEpochRequest :: TargetEpochRequest -> Either TargetEpochProtocolError ByteString
encodeTargetEpochRequest request = do
  wire <- case request of
    TargetEpochObserve target -> pure (WireObserve target)
    TargetEpochMutate action -> case action of
      PrepareTargetAuthorityEpoch preparation -> WirePrepare <$> encodePreparation preparation
      PromoteTargetAuthorityEpoch preparation -> WirePromote <$> encodePreparation preparation
      RetireTargetAuthorityEpoch preparation -> WireRetire <$> encodePreparation preparation
  let bytes = stagingPrefix <> LazyByteString.toStrict (encodeControlPlaneRequest wire)
  requireSize targetEpochRequestMaximumBytes bytes
  pure bytes
 where
  encodePreparation = first TargetEpochProtocolStateInvalid . encodeTargetAuthorityEpochPreparation

decodeTargetEpochRequest :: ByteString -> Either TargetEpochProtocolError TargetEpochRequest
decodeTargetEpochRequest bytes = do
  requireSize targetEpochRequestMaximumBytes bytes
  payload <-
    maybe (Left TargetEpochProtocolPrefixMissing) Right (ByteString.stripPrefix stagingPrefix bytes)
  wire <-
    first
      TargetEpochProtocolWireInvalid
      (decodeControlPlaneRequest targetEpochRequestMaximumBytes (LazyByteString.fromStrict payload))
  case wire of
    WireObserve target -> pure (TargetEpochObserve target)
    WirePrepare encoded -> TargetEpochMutate . PrepareTargetAuthorityEpoch <$> decodePreparation encoded
    WirePromote encoded -> TargetEpochMutate . PromoteTargetAuthorityEpoch <$> decodePreparation encoded
    WireRetire encoded -> TargetEpochMutate . RetireTargetAuthorityEpoch <$> decodePreparation encoded
 where
  decodePreparation = first TargetEpochProtocolStateInvalid . decodeTargetAuthorityEpochPreparation

encodeTargetEpochResponse :: TargetEpochResponse -> Either TargetEpochProtocolError ByteString
encodeTargetEpochResponse response = do
  wire <- case response of
    TargetEpochObserved target observed -> WireObserved target <$> traverse (encodeObservation target) observed
    TargetEpochMutated result -> do
      requireVersion (targetEpochMutationVersion result)
      encoded <- encodeRecord (targetEpochMutationRecord result)
      pure
        ( WireMutated
            (toWireDisposition (targetEpochMutationDisposition result))
            (targetEpochMutationVersion result)
            encoded
        )
  let bytes = LazyByteString.toStrict (encodeControlPlaneResponse wire)
  requireSize targetEpochResponseMaximumBytes bytes
  pure bytes
 where
  encodeObservation target (version, record) = do
    requireVersion version
    requireTarget target record
    encoded <- encodeRecord record
    pure (version, encoded)
  encodeRecord = first TargetEpochProtocolStateInvalid . encodeTargetAuthorityEpochRecord

decodeTargetEpochResponse :: ByteString -> Either TargetEpochProtocolError TargetEpochResponse
decodeTargetEpochResponse bytes = do
  requireSize targetEpochResponseMaximumBytes bytes
  wire <-
    first
      TargetEpochProtocolWireInvalid
      (decodeControlPlaneResponse targetEpochResponseMaximumBytes (LazyByteString.fromStrict bytes))
  case wire of
    WireObserved target observed -> TargetEpochObserved target <$> traverse (decodeObservation target) observed
    WireMutated disposition version encoded -> do
      requireVersion version
      record <- decodeRecord encoded
      pure
        (TargetEpochMutated (TargetEpochMutationResult (fromWireDisposition disposition) version record))
 where
  decodeObservation target (version, encoded) = do
    requireVersion version
    record <- decodeRecord encoded
    requireTarget target record
    pure (version, record)
  decodeRecord = first TargetEpochProtocolStateInvalid . decodeTargetAuthorityEpochRecord

toWireDisposition :: TargetEpochMutationDisposition -> WireDisposition
toWireDisposition disposition = case disposition of
  TargetEpochMutationAlreadyObserved -> WireAlreadyObserved
  TargetEpochMutationApplied -> WireApplied
  TargetEpochMutationRecovered -> WireRecovered

fromWireDisposition :: WireDisposition -> TargetEpochMutationDisposition
fromWireDisposition disposition = case disposition of
  WireAlreadyObserved -> TargetEpochMutationAlreadyObserved
  WireApplied -> TargetEpochMutationApplied
  WireRecovered -> TargetEpochMutationRecovered

requireVersion :: Natural -> Either TargetEpochProtocolError ()
requireVersion version = unless (version > 0) (Left TargetEpochProtocolReadBackInvalid)

requireTarget :: TargetSecretId -> TargetAuthorityEpochRecord -> Either TargetEpochProtocolError ()
requireTarget target record = unless (targetEpochRecordTarget record == target) (Left TargetEpochProtocolReadBackInvalid)

requireSize :: Int -> ByteString -> Either TargetEpochProtocolError ()
requireSize maximumBytes bytes = unless (ByteString.length bytes <= maximumBytes) (Left TargetEpochProtocolTooLarge)
