{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded authenticated wire boundary for Authority-retained AWS stack
-- reader inputs.  Commit and read-back are deliberately separate: a commit
-- response carries only its create/replay disposition, while only an
-- independent identity read-back can remint 'CommittedAwsStackReaderBundle'.
module Prodbox.ControlPlane.AwsStackReaderEndpoint
  ( AwsStackReaderWireAction (..)
  , AwsStackReaderWireRequest (..)
  , awsStackReaderCommitWireRequest
  , awsStackReaderReadBackWireRequest
  , AwsStackReaderWireCommitDisposition (..)
  , AwsStackReaderWireRefusal (..)
  , AwsStackReaderWireUnavailable (..)
  , AwsStackReaderWireResponse (..)
  , AwsStackReaderEndpointResult
  , awsStackReaderEndpointFormatVersion
  , awsStackReaderEndpointMaximumBytes
  , awsStackReaderEndpointResponseMaximumBytes
  , serveAwsStackReaderEndpointRequest
  , awsStackReaderEndpointStatus
  , awsStackReaderWireResponseStatus
  , awsStackReaderEndpointBody
  , decodeAwsStackReaderEndpointResponse
  , AwsStackReaderEndpointResponseError (..)
  , confirmAwsStackReaderCommitResponse
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (decode, encode))
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import Prodbox.ControlPlane.AwsStackReaderRepository.Internal
  ( AwsStackReaderAuthorityIdentity
  , AwsStackReaderBundle
  , AwsStackReaderClient
  , AwsStackReaderClientError (..)
  , AwsStackReaderCommitResult (..)
  , AwsStackReaderError (..)
  , CommittedAwsStackReaderBundle
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityScope
  , awsStackReaderBundleBytes
  , awsStackReaderBundleDecisionInputs
  , awsStackReaderBundleIdentity
  , awsStackReaderBundleProviderBinding
  , commitAwsStackReaderBundleAttempt
  , committedAwsStackReaderBytes
  , decodeAwsStackReaderAuthorityIdentity
  , decodeAwsStackReaderBundle
  , encodeAwsStackReaderAuthorityIdentity
  , independentlyReadBackCommittedAwsStackReaderBundle
  , maximumAwsStackReaderAuthorityIdentityBytes
  , maximumAwsStackReaderBytes
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CleanupRun (CleanupDigest, CleanupRunId)
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))

data AwsStackReaderWireAction
  = AwsStackReaderWireCommitAttempt
  | AwsStackReaderWireIndependentReadBack
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireAction where
  encode action =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case action of
            AwsStackReaderWireCommitAttempt -> 0
            AwsStackReaderWireIndependentReadBack -> 1
        )
  decode = do
    requireListLength "AwsStackReaderWireAction" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure AwsStackReaderWireCommitAttempt
      1 -> pure AwsStackReaderWireIndependentReadBack
      _ -> fail "AwsStackReaderWireAction: unknown tag"

data AwsStackReaderWireRequest = AwsStackReaderWireRequest
  { awsStackReaderWireRequestVersion :: !Word16
  , awsStackReaderWireRequestAction :: !AwsStackReaderWireAction
  , awsStackReaderWireRequestIdentityBytes :: !ByteString
  , awsStackReaderWireRequestBundleBytes :: !ByteString
  }
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireRequest where
  encode request =
    Cbor.encodeListLen 4
      <> Cbor.encodeWord16 (awsStackReaderWireRequestVersion request)
      <> encode (awsStackReaderWireRequestAction request)
      <> Cbor.encodeBytes (awsStackReaderWireRequestIdentityBytes request)
      <> Cbor.encodeBytes (awsStackReaderWireRequestBundleBytes request)
  decode = do
    requireListLength "AwsStackReaderWireRequest" 4
    AwsStackReaderWireRequest
      <$> Cbor.decodeWord16
      <*> decode
      <*> Cbor.decodeBytes
      <*> Cbor.decodeBytes

awsStackReaderCommitWireRequest
  :: AwsStackReaderBundle -> AwsStackReaderWireRequest
awsStackReaderCommitWireRequest bundle =
  AwsStackReaderWireRequest
    { awsStackReaderWireRequestVersion = awsStackReaderEndpointFormatVersion
    , awsStackReaderWireRequestAction = AwsStackReaderWireCommitAttempt
    , awsStackReaderWireRequestIdentityBytes =
        encodeAwsStackReaderAuthorityIdentity (awsStackReaderBundleIdentity bundle)
    , awsStackReaderWireRequestBundleBytes = awsStackReaderBundleBytes bundle
    }

awsStackReaderReadBackWireRequest
  :: AwsStackReaderAuthorityIdentity -> AwsStackReaderWireRequest
awsStackReaderReadBackWireRequest identity =
  AwsStackReaderWireRequest
    { awsStackReaderWireRequestVersion = awsStackReaderEndpointFormatVersion
    , awsStackReaderWireRequestAction = AwsStackReaderWireIndependentReadBack
    , awsStackReaderWireRequestIdentityBytes =
        encodeAwsStackReaderAuthorityIdentity identity
    , awsStackReaderWireRequestBundleBytes = ByteString.empty
    }

data AwsStackReaderWireCommitDisposition
  = AwsStackReaderWireCommitCreated
  | AwsStackReaderWireCommitExactReplay
  | AwsStackReaderWireCommitConflict
  | AwsStackReaderWireCommitResponseLost !Text
  | AwsStackReaderWireCommitUnavailable !Text
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireCommitDisposition where
  encode disposition = case disposition of
    AwsStackReaderWireCommitCreated -> scalar 0
    AwsStackReaderWireCommitExactReplay -> scalar 1
    AwsStackReaderWireCommitConflict -> scalar 2
    AwsStackReaderWireCommitResponseLost detail -> detailed 3 detail
    AwsStackReaderWireCommitUnavailable detail -> detailed 4 detail
   where
    scalar tag = Cbor.encodeListLen 1 <> Cbor.encodeWord tag
    detailed tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 1) -> pure AwsStackReaderWireCommitCreated
      (1, 1) -> pure AwsStackReaderWireCommitExactReplay
      (2, 1) -> pure AwsStackReaderWireCommitConflict
      (3, 2) -> AwsStackReaderWireCommitResponseLost <$> Cbor.decodeString
      (4, 2) -> AwsStackReaderWireCommitUnavailable <$> Cbor.decodeString
      _ -> fail "AwsStackReaderWireCommitDisposition: invalid tag or length"

data AwsStackReaderWireRefusal
  = AwsStackReaderWireRequestTooLarge
  | AwsStackReaderWireRequestInvalid
  | AwsStackReaderWireRequestUnsupportedVersion
  | AwsStackReaderWireRequestNonCanonical
  | AwsStackReaderWireIdentityInvalid
  | AwsStackReaderWireCommitPayloadMissing
  | AwsStackReaderWireUnexpectedPayload
  | AwsStackReaderWireBundleInvalid
  | AwsStackReaderWireBundleIdentityMismatch
  | AwsStackReaderWireReadBackMissing
  | AwsStackReaderWireReadBackCorrupt !Text
  | AwsStackReaderWireReadBackUnbounded !Int !Int
  | AwsStackReaderWireReadBackIdentityMismatch !ByteString
  | AwsStackReaderWireReadBackInvalid !Text
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireRefusal where
  encode refusal = case refusal of
    AwsStackReaderWireRequestTooLarge -> scalar 0
    AwsStackReaderWireRequestInvalid -> scalar 1
    AwsStackReaderWireRequestUnsupportedVersion -> scalar 2
    AwsStackReaderWireRequestNonCanonical -> scalar 3
    AwsStackReaderWireIdentityInvalid -> scalar 4
    AwsStackReaderWireCommitPayloadMissing -> scalar 5
    AwsStackReaderWireUnexpectedPayload -> scalar 6
    AwsStackReaderWireBundleInvalid -> scalar 7
    AwsStackReaderWireBundleIdentityMismatch -> scalar 8
    AwsStackReaderWireReadBackMissing -> scalar 9
    AwsStackReaderWireReadBackCorrupt detail -> textValue 10 detail
    AwsStackReaderWireReadBackUnbounded actual maximumBytes ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 11
        <> Cbor.encodeInt actual
        <> Cbor.encodeInt maximumBytes
    AwsStackReaderWireReadBackIdentityMismatch actualIdentity ->
      Cbor.encodeListLen 2
        <> Cbor.encodeWord 12
        <> Cbor.encodeBytes actualIdentity
    AwsStackReaderWireReadBackInvalid detail -> textValue 13 detail
   where
    scalar tag = Cbor.encodeListLen 1 <> Cbor.encodeWord tag
    textValue tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 1) -> pure AwsStackReaderWireRequestTooLarge
      (1, 1) -> pure AwsStackReaderWireRequestInvalid
      (2, 1) -> pure AwsStackReaderWireRequestUnsupportedVersion
      (3, 1) -> pure AwsStackReaderWireRequestNonCanonical
      (4, 1) -> pure AwsStackReaderWireIdentityInvalid
      (5, 1) -> pure AwsStackReaderWireCommitPayloadMissing
      (6, 1) -> pure AwsStackReaderWireUnexpectedPayload
      (7, 1) -> pure AwsStackReaderWireBundleInvalid
      (8, 1) -> pure AwsStackReaderWireBundleIdentityMismatch
      (9, 1) -> pure AwsStackReaderWireReadBackMissing
      (10, 2) -> AwsStackReaderWireReadBackCorrupt <$> Cbor.decodeString
      (11, 3) ->
        AwsStackReaderWireReadBackUnbounded <$> Cbor.decodeInt <*> Cbor.decodeInt
      (12, 2) -> AwsStackReaderWireReadBackIdentityMismatch <$> Cbor.decodeBytes
      (13, 2) -> AwsStackReaderWireReadBackInvalid <$> Cbor.decodeString
      _ -> fail "AwsStackReaderWireRefusal: invalid tag or length"

data AwsStackReaderWireUnavailable
  = AwsStackReaderWireReadBackUnobservable !Text
  | AwsStackReaderWireEndpointUnavailable !Text
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireUnavailable where
  encode reason = case reason of
    AwsStackReaderWireReadBackUnobservable detail -> detailed 0 detail
    AwsStackReaderWireEndpointUnavailable detail -> detailed 1 detail
   where
    detailed tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    requireListLength "AwsStackReaderWireUnavailable" 2
    tag <- Cbor.decodeWord
    case tag of
      0 -> AwsStackReaderWireReadBackUnobservable <$> Cbor.decodeString
      1 -> AwsStackReaderWireEndpointUnavailable <$> Cbor.decodeString
      _ -> fail "AwsStackReaderWireUnavailable: unknown tag"

data AwsStackReaderWireResponse
  = AwsStackReaderWireCommitResult
      !Word16
      !ByteString
      !AwsStackReaderWireCommitDisposition
  | AwsStackReaderWireReadBackPresent
      !Word16
      !ByteString
      !ByteString
  | AwsStackReaderWireRefused
      !Word16
      !AwsStackReaderWireRefusal
  | AwsStackReaderWireUnavailable
      !Word16
      !AwsStackReaderWireUnavailable
  deriving stock (Eq, Show)

instance Serialise AwsStackReaderWireResponse where
  encode response = case response of
    AwsStackReaderWireCommitResult version identity disposition ->
      Cbor.encodeListLen 4
        <> Cbor.encodeWord 0
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> encode disposition
    AwsStackReaderWireReadBackPresent version identity bundle ->
      Cbor.encodeListLen 4
        <> Cbor.encodeWord 1
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> Cbor.encodeBytes bundle
    AwsStackReaderWireRefused version refusal ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 2
        <> Cbor.encodeWord16 version
        <> encode refusal
    AwsStackReaderWireUnavailable version reason ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 3
        <> Cbor.encodeWord16 version
        <> encode reason
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 4) ->
        AwsStackReaderWireCommitResult
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> decode
      (1, 4) ->
        AwsStackReaderWireReadBackPresent
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> Cbor.decodeBytes
      (2, 3) -> AwsStackReaderWireRefused <$> Cbor.decodeWord16 <*> decode
      (3, 3) -> AwsStackReaderWireUnavailable <$> Cbor.decodeWord16 <*> decode
      _ -> fail "AwsStackReaderWireResponse: invalid tag or length"

requireListLength :: String -> Int -> Cbor.Decoder s ()
requireListLength label expected = do
  actual <- Cbor.decodeListLen
  unless (actual == expected) $
    fail (label <> ": expected " <> show expected <> " fields")

newtype AwsStackReaderEndpointResult
  = AwsStackReaderEndpointResult AwsStackReaderWireResponse
  deriving stock (Eq, Show)

awsStackReaderEndpointFormatVersion :: Word16
awsStackReaderEndpointFormatVersion = 1

awsStackReaderEndpointMaximumBytes :: Int
awsStackReaderEndpointMaximumBytes =
  maximumAwsStackReaderBytes
    + maximumAwsStackReaderAuthorityIdentityBytes
    + 8192

awsStackReaderEndpointResponseMaximumBytes :: Int
awsStackReaderEndpointResponseMaximumBytes = awsStackReaderEndpointMaximumBytes

serveAwsStackReaderEndpointRequest
  :: (Monad m)
  => (CleanupRunId -> CleanupDigest -> AwsStackReaderClient m)
  -> LazyByteString.ByteString
  -> m AwsStackReaderEndpointResult
serveAwsStackReaderEndpointRequest clientFor requestBytes =
  case decodeControlPlaneRequest awsStackReaderEndpointMaximumBytes requestBytes of
    Left err -> pure (endpointResult (requestCodecRefusal err))
    Right request
      | awsStackReaderWireRequestVersion request
          /= awsStackReaderEndpointFormatVersion ->
          pure (refused AwsStackReaderWireRequestUnsupportedVersion)
      | otherwise -> case decodeAwsStackReaderAuthorityIdentity
          (awsStackReaderWireRequestIdentityBytes request) of
          Left _ -> pure (refused AwsStackReaderWireIdentityInvalid)
          Right identity -> serveAction identity request
 where
  serveAction identity request =
    case awsStackReaderWireRequestAction request of
      AwsStackReaderWireCommitAttempt
        | ByteString.null payload ->
            pure (refused AwsStackReaderWireCommitPayloadMissing)
        | otherwise -> case decodeAwsStackReaderBundle payload of
            Left _ -> pure (refused AwsStackReaderWireBundleInvalid)
            Right bundle
              | awsStackReaderBundleIdentity bundle /= identity ->
                  pure (refused AwsStackReaderWireBundleIdentityMismatch)
              | otherwise -> do
                  attempted <-
                    commitAwsStackReaderBundleAttempt
                      (clientForIdentity identity)
                      (awsStackReaderBundleDecisionInputs bundle)
                      (awsStackReaderBundleProviderBinding bundle)
                  pure
                    ( either
                        clientErrorResult
                        (commitResult identity)
                        attempted
                    )
      AwsStackReaderWireIndependentReadBack
        | not (ByteString.null payload) ->
            pure (refused AwsStackReaderWireUnexpectedPayload)
        | otherwise -> do
            observed <-
              independentlyReadBackCommittedAwsStackReaderBundle
                (clientForIdentity identity)
                (awsStackReaderAuthorityOperationId identity)
                (awsStackReaderAuthorityKey identity)
                (awsStackReaderAuthorityScope identity)
            pure
              ( either
                  clientErrorResult
                  (readBackResult identity)
                  observed
              )
   where
    payload = awsStackReaderWireRequestBundleBytes request
  clientForIdentity identity =
    clientFor
      (awsStackReaderAuthorityRunId identity)
      (awsStackReaderAuthorityGraphDigest identity)

commitResult
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackReaderCommitResult
  -> AwsStackReaderEndpointResult
commitResult identity disposition =
  endpointResult
    ( AwsStackReaderWireCommitResult
        awsStackReaderEndpointFormatVersion
        (encodeAwsStackReaderAuthorityIdentity identity)
        (commitDispositionToWire disposition)
    )

readBackResult
  :: AwsStackReaderAuthorityIdentity
  -> CommittedAwsStackReaderBundle
  -> AwsStackReaderEndpointResult
readBackResult identity committed =
  endpointResult
    ( AwsStackReaderWireReadBackPresent
        awsStackReaderEndpointFormatVersion
        (encodeAwsStackReaderAuthorityIdentity identity)
        (committedAwsStackReaderBytes committed)
    )

clientErrorResult :: AwsStackReaderClientError -> AwsStackReaderEndpointResult
clientErrorResult err = case err of
  AwsStackReaderClientRequestInvalid _ -> refused AwsStackReaderWireBundleInvalid
  AwsStackReaderClientCommitUnconfirmed {} ->
    unavailable (AwsStackReaderWireEndpointUnavailable "commit-unconfirmed")
  AwsStackReaderClientMissing -> refused AwsStackReaderWireReadBackMissing
  AwsStackReaderClientCorrupt detail ->
    refused (AwsStackReaderWireReadBackCorrupt (bounded detail))
  AwsStackReaderClientUnobservable (ObservationFailure detail) ->
    unavailable (AwsStackReaderWireReadBackUnobservable (bounded detail))
  AwsStackReaderClientUnbounded actual maximumBytes ->
    refused (AwsStackReaderWireReadBackUnbounded actual maximumBytes)
  AwsStackReaderClientReadBackInvalid
    (AwsStackReaderIdentityMismatch _ actual) ->
      refused
        ( AwsStackReaderWireReadBackIdentityMismatch
            (encodeAwsStackReaderAuthorityIdentity actual)
        )
  AwsStackReaderClientReadBackInvalid detail ->
    refused (AwsStackReaderWireReadBackInvalid (bounded (Text.pack (show detail))))
  AwsStackReaderClientTransportFailed _ -> remoteUnavailable
  AwsStackReaderClientResponseInvalid _ -> remoteUnavailable
  AwsStackReaderClientHttpStatusMismatch _ _ -> remoteUnavailable
  AwsStackReaderClientRemoteRefused detail ->
    refused (AwsStackReaderWireReadBackInvalid (bounded detail))
  AwsStackReaderClientRemoteUnavailable _ -> remoteUnavailable
 where
  remoteUnavailable =
    unavailable (AwsStackReaderWireEndpointUnavailable "authority-client-unavailable")

requestCodecRefusal
  :: ControlPlaneRequestCodecError -> AwsStackReaderWireResponse
requestCodecRefusal err =
  AwsStackReaderWireRefused
    awsStackReaderEndpointFormatVersion
    ( case err of
        ControlPlaneRequestTooLarge -> AwsStackReaderWireRequestTooLarge
        ControlPlaneRequestInvalid -> AwsStackReaderWireRequestInvalid
        ControlPlaneRequestUnsupportedVersion ->
          AwsStackReaderWireRequestUnsupportedVersion
        ControlPlaneRequestNonCanonical -> AwsStackReaderWireRequestNonCanonical
    )

refused :: AwsStackReaderWireRefusal -> AwsStackReaderEndpointResult
refused refusal =
  endpointResult
    (AwsStackReaderWireRefused awsStackReaderEndpointFormatVersion refusal)

unavailable :: AwsStackReaderWireUnavailable -> AwsStackReaderEndpointResult
unavailable reason =
  endpointResult
    (AwsStackReaderWireUnavailable awsStackReaderEndpointFormatVersion reason)

endpointResult :: AwsStackReaderWireResponse -> AwsStackReaderEndpointResult
endpointResult = AwsStackReaderEndpointResult

awsStackReaderEndpointStatus :: AwsStackReaderEndpointResult -> ReplyStatus
awsStackReaderEndpointStatus (AwsStackReaderEndpointResult response) =
  awsStackReaderWireResponseStatus response

awsStackReaderWireResponseStatus :: AwsStackReaderWireResponse -> ReplyStatus
awsStackReaderWireResponseStatus response = case response of
  AwsStackReaderWireCommitResult {} -> ReplyOk
  AwsStackReaderWireReadBackPresent {} -> ReplyOk
  AwsStackReaderWireUnavailable {} -> ReplyServiceUnavailable
  AwsStackReaderWireRefused _ refusal -> case refusal of
    AwsStackReaderWireReadBackMissing -> ReplyNotFound
    AwsStackReaderWireReadBackCorrupt {} -> ReplyConflict
    AwsStackReaderWireReadBackUnbounded {} -> ReplyConflict
    AwsStackReaderWireReadBackIdentityMismatch {} -> ReplyConflict
    AwsStackReaderWireReadBackInvalid {} -> ReplyConflict
    AwsStackReaderWireBundleIdentityMismatch -> ReplyConflict
    _ -> ReplyBadRequest

awsStackReaderEndpointBody :: AwsStackReaderEndpointResult -> ByteString
awsStackReaderEndpointBody (AwsStackReaderEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeAwsStackReaderEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError AwsStackReaderWireResponse
decodeAwsStackReaderEndpointResponse =
  decodeControlPlaneResponse awsStackReaderEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data AwsStackReaderEndpointResponseError
  = AwsStackReaderEndpointResponseVersionMismatch !Word16 !Word16
  | AwsStackReaderEndpointResponseKindMismatch
  | AwsStackReaderEndpointResponseIdentityInvalid !AwsStackReaderError
  | AwsStackReaderEndpointResponseIdentityMismatch
      !AwsStackReaderAuthorityIdentity
      !AwsStackReaderAuthorityIdentity
  | AwsStackReaderEndpointResponseReadBackInvalid !AwsStackReaderClientError
  | AwsStackReaderEndpointResponseRefused !AwsStackReaderWireRefusal
  | AwsStackReaderEndpointResponseUnavailable !AwsStackReaderWireUnavailable
  deriving stock (Eq, Show)

confirmAwsStackReaderCommitResponse
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackReaderWireResponse
  -> Either AwsStackReaderEndpointResponseError AwsStackReaderCommitResult
confirmAwsStackReaderCommitResponse expected response = case response of
  AwsStackReaderWireCommitResult version identityBytes disposition -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure (commitDispositionFromWire disposition)
  AwsStackReaderWireRefused version refusal -> do
    validateVersion version
    Left (AwsStackReaderEndpointResponseRefused refusal)
  AwsStackReaderWireUnavailable version reason -> do
    validateVersion version
    Left (AwsStackReaderEndpointResponseUnavailable reason)
  AwsStackReaderWireReadBackPresent {} ->
    Left AwsStackReaderEndpointResponseKindMismatch

validateVersion
  :: Word16 -> Either AwsStackReaderEndpointResponseError ()
validateVersion actual
  | actual == awsStackReaderEndpointFormatVersion = Right ()
  | otherwise =
      Left
        ( AwsStackReaderEndpointResponseVersionMismatch
            awsStackReaderEndpointFormatVersion
            actual
        )

validateIdentity
  :: AwsStackReaderAuthorityIdentity
  -> ByteString
  -> Either AwsStackReaderEndpointResponseError ()
validateIdentity expected bytes = do
  actual <-
    first
      AwsStackReaderEndpointResponseIdentityInvalid
      (decodeAwsStackReaderAuthorityIdentity bytes)
  unless
    (actual == expected)
    (Left (AwsStackReaderEndpointResponseIdentityMismatch expected actual))

commitDispositionToWire
  :: AwsStackReaderCommitResult -> AwsStackReaderWireCommitDisposition
commitDispositionToWire disposition = case disposition of
  AwsStackReaderCommitCreated -> AwsStackReaderWireCommitCreated
  AwsStackReaderCommitExactReplay -> AwsStackReaderWireCommitExactReplay
  AwsStackReaderCommitConflict -> AwsStackReaderWireCommitConflict
  AwsStackReaderCommitResponseLost (ObservationFailure detail) ->
    AwsStackReaderWireCommitResponseLost (bounded detail)
  AwsStackReaderCommitUnavailable (ObservationFailure detail) ->
    AwsStackReaderWireCommitUnavailable (bounded detail)

commitDispositionFromWire
  :: AwsStackReaderWireCommitDisposition -> AwsStackReaderCommitResult
commitDispositionFromWire disposition = case disposition of
  AwsStackReaderWireCommitCreated -> AwsStackReaderCommitCreated
  AwsStackReaderWireCommitExactReplay -> AwsStackReaderCommitExactReplay
  AwsStackReaderWireCommitConflict -> AwsStackReaderCommitConflict
  AwsStackReaderWireCommitResponseLost detail ->
    AwsStackReaderCommitResponseLost (ObservationFailure (bounded detail))
  AwsStackReaderWireCommitUnavailable detail ->
    AwsStackReaderCommitUnavailable (ObservationFailure (bounded detail))

bounded :: Text -> Text
bounded = Text.take 1024
