{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded authenticated wire boundary for Authority-owned ownership
-- manifests.  Its read-back protocol carries the complete Authority
-- observation algebra.  In particular, Missing becomes Absent only after an
-- authenticated response is validated against the caller's exact target.
module Prodbox.ControlPlane.OwnershipManifestEndpoint
  ( OwnershipManifestWireAction (..)
  , OwnershipManifestWireRequest (..)
  , ownershipManifestCommitWireRequest
  , ownershipManifestReadBackWireRequest
  , OwnershipManifestWireCommitDisposition (..)
  , OwnershipManifestWireRefusal (..)
  , OwnershipManifestWireUnavailable (..)
  , OwnershipManifestWireResponse (..)
  , OwnershipManifestEndpointResult
  , ownershipManifestEndpointFormatVersion
  , ownershipManifestEndpointMaximumBytes
  , ownershipManifestEndpointResponseMaximumBytes
  , serveOwnershipManifestEndpointRequest
  , ownershipManifestEndpointStatus
  , ownershipManifestWireResponseStatus
  , ownershipManifestEndpointBody
  , decodeOwnershipManifestEndpointResponse
  , OwnershipManifestEndpointResponseError (..)
  , confirmOwnershipManifestCommitResponse
  , confirmOwnershipManifestReadBackResponse
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
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( AuthorityOwnershipManifestWrite
  , OwnershipManifestAuthorityIdentity
  , OwnershipManifestAuthorityReadBack (..)
  , OwnershipManifestCommitResult (..)
  , OwnershipManifestRepository (..)
  , OwnershipManifestRepositoryError
  , authorityOwnershipManifestWriteBytes
  , authorityOwnershipManifestWriteIdentity
  , confirmAuthorityOwnershipManifestWriteBytes
  , decodeOwnershipManifestAuthorityIdentity
  , encodeOwnershipManifestAuthorityIdentity
  , maximumOwnershipManifestAuthorityIdentityBytes
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CheckpointAuthority
  ( mkModelBObjectVersion
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( maximumDurableWriteAheadOwnershipManifestBytes
  )

data OwnershipManifestWireAction
  = OwnershipManifestWireCommitAttempt
  | OwnershipManifestWireIndependentReadBack
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireAction where
  encode action =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case action of
            OwnershipManifestWireCommitAttempt -> 0
            OwnershipManifestWireIndependentReadBack -> 1
        )
  decode = do
    requireListLength "OwnershipManifestWireAction" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure OwnershipManifestWireCommitAttempt
      1 -> pure OwnershipManifestWireIndependentReadBack
      _ -> fail "OwnershipManifestWireAction: unknown tag"

data OwnershipManifestWireRequest = OwnershipManifestWireRequest
  { ownershipManifestWireRequestVersion :: !Word16
  , ownershipManifestWireRequestAction :: !OwnershipManifestWireAction
  , ownershipManifestWireRequestIdentityBytes :: !ByteString
  , ownershipManifestWireRequestManifestBytes :: !ByteString
  }
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireRequest where
  encode request =
    Cbor.encodeListLen 4
      <> Cbor.encodeWord16 (ownershipManifestWireRequestVersion request)
      <> encode (ownershipManifestWireRequestAction request)
      <> Cbor.encodeBytes (ownershipManifestWireRequestIdentityBytes request)
      <> Cbor.encodeBytes (ownershipManifestWireRequestManifestBytes request)
  decode = do
    requireListLength "OwnershipManifestWireRequest" 4
    OwnershipManifestWireRequest
      <$> Cbor.decodeWord16
      <*> decode
      <*> Cbor.decodeBytes
      <*> Cbor.decodeBytes

ownershipManifestCommitWireRequest
  :: AuthorityOwnershipManifestWrite -> OwnershipManifestWireRequest
ownershipManifestCommitWireRequest write =
  OwnershipManifestWireRequest
    { ownershipManifestWireRequestVersion = ownershipManifestEndpointFormatVersion
    , ownershipManifestWireRequestAction = OwnershipManifestWireCommitAttempt
    , ownershipManifestWireRequestIdentityBytes =
        encodeOwnershipManifestAuthorityIdentity
          (authorityOwnershipManifestWriteIdentity write)
    , ownershipManifestWireRequestManifestBytes =
        authorityOwnershipManifestWriteBytes write
    }

ownershipManifestReadBackWireRequest
  :: OwnershipManifestAuthorityIdentity -> OwnershipManifestWireRequest
ownershipManifestReadBackWireRequest identity =
  OwnershipManifestWireRequest
    { ownershipManifestWireRequestVersion = ownershipManifestEndpointFormatVersion
    , ownershipManifestWireRequestAction =
        OwnershipManifestWireIndependentReadBack
    , ownershipManifestWireRequestIdentityBytes =
        encodeOwnershipManifestAuthorityIdentity identity
    , ownershipManifestWireRequestManifestBytes = ByteString.empty
    }

data OwnershipManifestWireCommitDisposition
  = OwnershipManifestWireCommitCreated
  | OwnershipManifestWireCommitExactReplay
  | OwnershipManifestWireCommitConflict
  | OwnershipManifestWireCommitResponseLost !Text
  | OwnershipManifestWireCommitUnavailable !Text
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireCommitDisposition where
  encode disposition = case disposition of
    OwnershipManifestWireCommitCreated -> scalar 0
    OwnershipManifestWireCommitExactReplay -> scalar 1
    OwnershipManifestWireCommitConflict -> scalar 2
    OwnershipManifestWireCommitResponseLost detail -> detailed 3 detail
    OwnershipManifestWireCommitUnavailable detail -> detailed 4 detail
   where
    scalar tag = Cbor.encodeListLen 1 <> Cbor.encodeWord tag
    detailed tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 1) -> pure OwnershipManifestWireCommitCreated
      (1, 1) -> pure OwnershipManifestWireCommitExactReplay
      (2, 1) -> pure OwnershipManifestWireCommitConflict
      (3, 2) -> OwnershipManifestWireCommitResponseLost <$> Cbor.decodeString
      (4, 2) -> OwnershipManifestWireCommitUnavailable <$> Cbor.decodeString
      _ -> fail "OwnershipManifestWireCommitDisposition: invalid tag or length"

data OwnershipManifestWireRefusal
  = OwnershipManifestWireRequestTooLarge
  | OwnershipManifestWireRequestInvalid
  | OwnershipManifestWireRequestUnsupportedVersion
  | OwnershipManifestWireRequestNonCanonical
  | OwnershipManifestWireIdentityInvalid !Text
  | OwnershipManifestWireCommitPayloadMissing
  | OwnershipManifestWireUnexpectedPayload
  | OwnershipManifestWireManifestInvalid !Text
  | OwnershipManifestWireManifestIdentityMismatch !ByteString
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireRefusal where
  encode refusal = case refusal of
    OwnershipManifestWireRequestTooLarge -> scalar 0
    OwnershipManifestWireRequestInvalid -> scalar 1
    OwnershipManifestWireRequestUnsupportedVersion -> scalar 2
    OwnershipManifestWireRequestNonCanonical -> scalar 3
    OwnershipManifestWireIdentityInvalid detail -> textValue 4 detail
    OwnershipManifestWireCommitPayloadMissing -> scalar 5
    OwnershipManifestWireUnexpectedPayload -> scalar 6
    OwnershipManifestWireManifestInvalid detail -> textValue 7 detail
    OwnershipManifestWireManifestIdentityMismatch actual ->
      Cbor.encodeListLen 2 <> Cbor.encodeWord 8 <> Cbor.encodeBytes actual
   where
    scalar tag = Cbor.encodeListLen 1 <> Cbor.encodeWord tag
    textValue tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 1) -> pure OwnershipManifestWireRequestTooLarge
      (1, 1) -> pure OwnershipManifestWireRequestInvalid
      (2, 1) -> pure OwnershipManifestWireRequestUnsupportedVersion
      (3, 1) -> pure OwnershipManifestWireRequestNonCanonical
      (4, 2) -> OwnershipManifestWireIdentityInvalid <$> Cbor.decodeString
      (5, 1) -> pure OwnershipManifestWireCommitPayloadMissing
      (6, 1) -> pure OwnershipManifestWireUnexpectedPayload
      (7, 2) -> OwnershipManifestWireManifestInvalid <$> Cbor.decodeString
      (8, 2) -> OwnershipManifestWireManifestIdentityMismatch <$> Cbor.decodeBytes
      _ -> fail "OwnershipManifestWireRefusal: invalid tag or length"

newtype OwnershipManifestWireUnavailable
  = OwnershipManifestWireEndpointUnavailable Text
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireUnavailable where
  encode (OwnershipManifestWireEndpointUnavailable detail) =
    Cbor.encodeListLen 2 <> Cbor.encodeWord 0 <> Cbor.encodeString detail
  decode = do
    requireListLength "OwnershipManifestWireUnavailable" 2
    tag <- Cbor.decodeWord
    case tag of
      0 -> OwnershipManifestWireEndpointUnavailable <$> Cbor.decodeString
      _ -> fail "OwnershipManifestWireUnavailable: unknown tag"

data OwnershipManifestWireResponse
  = OwnershipManifestWireCommitResult
      !Word16
      !ByteString
      !OwnershipManifestWireCommitDisposition
  | OwnershipManifestWireReadBackPresent
      !Word16
      !ByteString
      !Text
      !ByteString
  | OwnershipManifestWireReadBackMissing !Word16 !ByteString
  | OwnershipManifestWireReadBackPartial !Word16 !ByteString ![Text]
  | OwnershipManifestWireReadBackCorrupt !Word16 !ByteString !Text
  | OwnershipManifestWireReadBackUnobservable !Word16 !ByteString !Text
  | OwnershipManifestWireReadBackUnbounded !Word16 !ByteString !Int !Int
  | OwnershipManifestWireRefused !Word16 !OwnershipManifestWireRefusal
  | OwnershipManifestWireUnavailable !Word16 !OwnershipManifestWireUnavailable
  deriving stock (Eq, Show)

instance Serialise OwnershipManifestWireResponse where
  encode response = case response of
    OwnershipManifestWireCommitResult version identity disposition ->
      Cbor.encodeListLen 4
        <> Cbor.encodeWord 0
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> encode disposition
    OwnershipManifestWireReadBackPresent version identity objectVersion bytes ->
      Cbor.encodeListLen 5
        <> Cbor.encodeWord 1
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> Cbor.encodeString objectVersion
        <> Cbor.encodeBytes bytes
    OwnershipManifestWireReadBackMissing version identity ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 2
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
    OwnershipManifestWireReadBackPartial version identity failures ->
      Cbor.encodeListLen 4
        <> Cbor.encodeWord 3
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> encode failures
    OwnershipManifestWireReadBackCorrupt version identity detail ->
      readBackDetail 4 version identity detail
    OwnershipManifestWireReadBackUnobservable version identity detail ->
      readBackDetail 5 version identity detail
    OwnershipManifestWireReadBackUnbounded version identity actual maximumBytes ->
      Cbor.encodeListLen 5
        <> Cbor.encodeWord 6
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> Cbor.encodeInt actual
        <> Cbor.encodeInt maximumBytes
    OwnershipManifestWireRefused version refusal ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 7
        <> Cbor.encodeWord16 version
        <> encode refusal
    OwnershipManifestWireUnavailable version reason ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 8
        <> Cbor.encodeWord16 version
        <> encode reason
   where
    readBackDetail tag version identity detail =
      Cbor.encodeListLen 4
        <> Cbor.encodeWord tag
        <> Cbor.encodeWord16 version
        <> Cbor.encodeBytes identity
        <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 4) ->
        OwnershipManifestWireCommitResult
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> decode
      (1, 5) ->
        OwnershipManifestWireReadBackPresent
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> Cbor.decodeString
          <*> Cbor.decodeBytes
      (2, 3) ->
        OwnershipManifestWireReadBackMissing
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
      (3, 4) ->
        OwnershipManifestWireReadBackPartial
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> decode
      (4, 4) ->
        OwnershipManifestWireReadBackCorrupt
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> Cbor.decodeString
      (5, 4) ->
        OwnershipManifestWireReadBackUnobservable
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> Cbor.decodeString
      (6, 5) ->
        OwnershipManifestWireReadBackUnbounded
          <$> Cbor.decodeWord16
          <*> Cbor.decodeBytes
          <*> Cbor.decodeInt
          <*> Cbor.decodeInt
      (7, 3) -> OwnershipManifestWireRefused <$> Cbor.decodeWord16 <*> decode
      (8, 3) -> OwnershipManifestWireUnavailable <$> Cbor.decodeWord16 <*> decode
      _ -> fail "OwnershipManifestWireResponse: invalid tag or length"

newtype OwnershipManifestEndpointResult
  = OwnershipManifestEndpointResult OwnershipManifestWireResponse
  deriving stock (Eq, Show)

ownershipManifestEndpointFormatVersion :: Word16
ownershipManifestEndpointFormatVersion = 1

ownershipManifestEndpointMaximumBytes :: Int
ownershipManifestEndpointMaximumBytes =
  maximumDurableWriteAheadOwnershipManifestBytes
    + maximumOwnershipManifestAuthorityIdentityBytes
    + 8192

ownershipManifestEndpointResponseMaximumBytes :: Int
ownershipManifestEndpointResponseMaximumBytes =
  ownershipManifestEndpointMaximumBytes

serveOwnershipManifestEndpointRequest
  :: (Monad m)
  => OwnershipManifestRepository m
  -> LazyByteString.ByteString
  -> m OwnershipManifestEndpointResult
serveOwnershipManifestEndpointRequest repository requestBytes =
  case decodeControlPlaneRequest ownershipManifestEndpointMaximumBytes requestBytes of
    Left err -> pure (endpointResult (requestCodecRefusal err))
    Right request
      | ownershipManifestWireRequestVersion request
          /= ownershipManifestEndpointFormatVersion ->
          pure (refused OwnershipManifestWireRequestUnsupportedVersion)
      | otherwise ->
          case decodeOwnershipManifestAuthorityIdentity
            (ownershipManifestWireRequestIdentityBytes request) of
            Left err ->
              pure
                ( refused
                    (OwnershipManifestWireIdentityInvalid (renderError err))
                )
            Right identity -> serveAction identity request
 where
  serveAction identity request =
    case ownershipManifestWireRequestAction request of
      OwnershipManifestWireCommitAttempt
        | ByteString.null payload ->
            pure (refused OwnershipManifestWireCommitPayloadMissing)
        | otherwise ->
            case confirmAuthorityOwnershipManifestWriteBytes identity payload of
              Left err -> pure (manifestErrorResult err)
              Right write -> do
                attempted <- createOrReplayOwnershipManifest repository write
                pure (commitResult write attempted)
      OwnershipManifestWireIndependentReadBack
        | not (ByteString.null payload) ->
            pure (refused OwnershipManifestWireUnexpectedPayload)
        | otherwise -> do
            observed <- independentlyReadBackOwnershipManifest repository identity
            pure (readBackResult identity observed)
   where
    payload = ownershipManifestWireRequestManifestBytes request

commitResult
  :: AuthorityOwnershipManifestWrite
  -> OwnershipManifestCommitResult
  -> OwnershipManifestEndpointResult
commitResult write disposition =
  endpointResult
    ( OwnershipManifestWireCommitResult
        ownershipManifestEndpointFormatVersion
        ( encodeOwnershipManifestAuthorityIdentity
            (authorityOwnershipManifestWriteIdentity write)
        )
        (commitDispositionToWire disposition)
    )

readBackResult
  :: OwnershipManifestAuthorityIdentity
  -> OwnershipManifestAuthorityReadBack
  -> OwnershipManifestEndpointResult
readBackResult identity observation =
  endpointResult $ case observation of
    OwnershipManifestAuthorityReadBackPresent version bytes ->
      OwnershipManifestWireReadBackPresent
        ownershipManifestEndpointFormatVersion
        identityBytes
        (modelBObjectVersionText version)
        bytes
    OwnershipManifestAuthorityReadBackMissing ->
      OwnershipManifestWireReadBackMissing
        ownershipManifestEndpointFormatVersion
        identityBytes
    OwnershipManifestAuthorityReadBackPartial failures ->
      OwnershipManifestWireReadBackPartial
        ownershipManifestEndpointFormatVersion
        identityBytes
        (fmap observationFailureText (NonEmpty.toList failures))
    OwnershipManifestAuthorityReadBackCorrupt detail ->
      OwnershipManifestWireReadBackCorrupt
        ownershipManifestEndpointFormatVersion
        identityBytes
        (bounded detail)
    OwnershipManifestAuthorityReadBackUnobservable failure ->
      OwnershipManifestWireReadBackUnobservable
        ownershipManifestEndpointFormatVersion
        identityBytes
        (observationFailureText failure)
    OwnershipManifestAuthorityReadBackUnbounded actual maximumBytes ->
      OwnershipManifestWireReadBackUnbounded
        ownershipManifestEndpointFormatVersion
        identityBytes
        actual
        maximumBytes
 where
  identityBytes = encodeOwnershipManifestAuthorityIdentity identity

manifestErrorResult
  :: OwnershipManifestRepositoryError -> OwnershipManifestEndpointResult
manifestErrorResult err =
  refused (OwnershipManifestWireManifestInvalid (renderError err))

requestCodecRefusal
  :: ControlPlaneRequestCodecError -> OwnershipManifestWireResponse
requestCodecRefusal err =
  OwnershipManifestWireRefused
    ownershipManifestEndpointFormatVersion
    ( case err of
        ControlPlaneRequestTooLarge -> OwnershipManifestWireRequestTooLarge
        ControlPlaneRequestInvalid -> OwnershipManifestWireRequestInvalid
        ControlPlaneRequestUnsupportedVersion ->
          OwnershipManifestWireRequestUnsupportedVersion
        ControlPlaneRequestNonCanonical -> OwnershipManifestWireRequestNonCanonical
    )

refused :: OwnershipManifestWireRefusal -> OwnershipManifestEndpointResult
refused refusal =
  endpointResult
    ( OwnershipManifestWireRefused
        ownershipManifestEndpointFormatVersion
        refusal
    )

endpointResult
  :: OwnershipManifestWireResponse -> OwnershipManifestEndpointResult
endpointResult = OwnershipManifestEndpointResult

ownershipManifestEndpointStatus
  :: OwnershipManifestEndpointResult -> ReplyStatus
ownershipManifestEndpointStatus (OwnershipManifestEndpointResult response) =
  ownershipManifestWireResponseStatus response

ownershipManifestWireResponseStatus
  :: OwnershipManifestWireResponse -> ReplyStatus
ownershipManifestWireResponseStatus response = case response of
  OwnershipManifestWireCommitResult {} -> ReplyOk
  OwnershipManifestWireReadBackPresent {} -> ReplyOk
  OwnershipManifestWireReadBackMissing {} -> ReplyNotFound
  OwnershipManifestWireReadBackPartial {} -> ReplyOk
  OwnershipManifestWireReadBackCorrupt {} -> ReplyConflict
  OwnershipManifestWireReadBackUnobservable {} -> ReplyServiceUnavailable
  OwnershipManifestWireReadBackUnbounded {} -> ReplyConflict
  OwnershipManifestWireRefused {} -> ReplyBadRequest
  OwnershipManifestWireUnavailable {} -> ReplyServiceUnavailable

ownershipManifestEndpointBody :: OwnershipManifestEndpointResult -> ByteString
ownershipManifestEndpointBody (OwnershipManifestEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeOwnershipManifestEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError OwnershipManifestWireResponse
decodeOwnershipManifestEndpointResponse =
  decodeControlPlaneResponse ownershipManifestEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data OwnershipManifestEndpointResponseError
  = OwnershipManifestEndpointResponseVersionMismatch !Word16 !Word16
  | OwnershipManifestEndpointResponseKindMismatch
  | OwnershipManifestEndpointResponseIdentityInvalid
      !OwnershipManifestRepositoryError
  | OwnershipManifestEndpointResponseIdentityMismatch
      !OwnershipManifestAuthorityIdentity
      !OwnershipManifestAuthorityIdentity
  | OwnershipManifestEndpointResponseObjectVersionInvalid !Text
  | OwnershipManifestEndpointResponsePartialEmpty
  | OwnershipManifestEndpointResponseRefused !OwnershipManifestWireRefusal
  | OwnershipManifestEndpointResponseUnavailable
      !OwnershipManifestWireUnavailable
  deriving stock (Eq, Show)

confirmOwnershipManifestCommitResponse
  :: OwnershipManifestAuthorityIdentity
  -> OwnershipManifestWireResponse
  -> Either
       OwnershipManifestEndpointResponseError
       OwnershipManifestCommitResult
confirmOwnershipManifestCommitResponse expected response = case response of
  OwnershipManifestWireCommitResult version identityBytes disposition -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure (commitDispositionFromWire disposition)
  OwnershipManifestWireRefused version refusal -> do
    validateVersion version
    Left (OwnershipManifestEndpointResponseRefused refusal)
  OwnershipManifestWireUnavailable version reason -> do
    validateVersion version
    Left (OwnershipManifestEndpointResponseUnavailable reason)
  _ -> validateReadBackArmVersion response

confirmOwnershipManifestReadBackResponse
  :: OwnershipManifestAuthorityIdentity
  -> OwnershipManifestWireResponse
  -> Either
       OwnershipManifestEndpointResponseError
       OwnershipManifestAuthorityReadBack
confirmOwnershipManifestReadBackResponse expected response = case response of
  OwnershipManifestWireReadBackPresent version identityBytes versionText bytes -> do
    validateVersion version
    validateIdentity expected identityBytes
    objectVersion <-
      first
        (const (OwnershipManifestEndpointResponseObjectVersionInvalid versionText))
        (mkModelBObjectVersion versionText)
    pure (OwnershipManifestAuthorityReadBackPresent objectVersion bytes)
  OwnershipManifestWireReadBackMissing version identityBytes -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure OwnershipManifestAuthorityReadBackMissing
  OwnershipManifestWireReadBackPartial version identityBytes failures -> do
    validateVersion version
    validateIdentity expected identityBytes
    nonEmpty <-
      maybe
        (Left OwnershipManifestEndpointResponsePartialEmpty)
        Right
        (NonEmpty.nonEmpty failures)
    pure
      ( OwnershipManifestAuthorityReadBackPartial
          (fmap (ObservationFailure . bounded) nonEmpty)
      )
  OwnershipManifestWireReadBackCorrupt version identityBytes detail -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure (OwnershipManifestAuthorityReadBackCorrupt (bounded detail))
  OwnershipManifestWireReadBackUnobservable version identityBytes detail -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure
      ( OwnershipManifestAuthorityReadBackUnobservable
          (ObservationFailure (bounded detail))
      )
  OwnershipManifestWireReadBackUnbounded version identityBytes actual maximumBytes -> do
    validateVersion version
    validateIdentity expected identityBytes
    pure (OwnershipManifestAuthorityReadBackUnbounded actual maximumBytes)
  OwnershipManifestWireRefused version refusal -> do
    validateVersion version
    Left (OwnershipManifestEndpointResponseRefused refusal)
  OwnershipManifestWireUnavailable version reason -> do
    validateVersion version
    Left (OwnershipManifestEndpointResponseUnavailable reason)
  OwnershipManifestWireCommitResult version _ _ -> do
    validateVersion version
    Left OwnershipManifestEndpointResponseKindMismatch

-- Commit confirmation rejects every read-back constructor, but still checks
-- its protocol version first so no wrong-version error arm is silently
-- flattened into a kind mismatch.
validateReadBackArmVersion
  :: OwnershipManifestWireResponse
  -> Either OwnershipManifestEndpointResponseError value
validateReadBackArmVersion response = do
  validateVersion $ case response of
    OwnershipManifestWireReadBackPresent version _ _ _ -> version
    OwnershipManifestWireReadBackMissing version _ -> version
    OwnershipManifestWireReadBackPartial version _ _ -> version
    OwnershipManifestWireReadBackCorrupt version _ _ -> version
    OwnershipManifestWireReadBackUnobservable version _ _ -> version
    OwnershipManifestWireReadBackUnbounded version _ _ _ -> version
    OwnershipManifestWireCommitResult version _ _ -> version
    OwnershipManifestWireRefused version _ -> version
    OwnershipManifestWireUnavailable version _ -> version
  Left OwnershipManifestEndpointResponseKindMismatch

validateVersion
  :: Word16 -> Either OwnershipManifestEndpointResponseError ()
validateVersion actual
  | actual == ownershipManifestEndpointFormatVersion = Right ()
  | otherwise =
      Left
        ( OwnershipManifestEndpointResponseVersionMismatch
            ownershipManifestEndpointFormatVersion
            actual
        )

validateIdentity
  :: OwnershipManifestAuthorityIdentity
  -> ByteString
  -> Either OwnershipManifestEndpointResponseError ()
validateIdentity expected bytes = do
  actual <-
    first
      OwnershipManifestEndpointResponseIdentityInvalid
      (decodeOwnershipManifestAuthorityIdentity bytes)
  unless
    (actual == expected)
    ( Left
        ( OwnershipManifestEndpointResponseIdentityMismatch
            expected
            actual
        )
    )

commitDispositionToWire
  :: OwnershipManifestCommitResult -> OwnershipManifestWireCommitDisposition
commitDispositionToWire disposition = case disposition of
  OwnershipManifestCommitCreated -> OwnershipManifestWireCommitCreated
  OwnershipManifestCommitExactReplay -> OwnershipManifestWireCommitExactReplay
  OwnershipManifestCommitConflict -> OwnershipManifestWireCommitConflict
  OwnershipManifestCommitResponseLost failure ->
    OwnershipManifestWireCommitResponseLost (observationFailureText failure)
  OwnershipManifestCommitUnavailable failure ->
    OwnershipManifestWireCommitUnavailable (observationFailureText failure)

commitDispositionFromWire
  :: OwnershipManifestWireCommitDisposition -> OwnershipManifestCommitResult
commitDispositionFromWire disposition = case disposition of
  OwnershipManifestWireCommitCreated -> OwnershipManifestCommitCreated
  OwnershipManifestWireCommitExactReplay -> OwnershipManifestCommitExactReplay
  OwnershipManifestWireCommitConflict -> OwnershipManifestCommitConflict
  OwnershipManifestWireCommitResponseLost detail ->
    OwnershipManifestCommitResponseLost (ObservationFailure (bounded detail))
  OwnershipManifestWireCommitUnavailable detail ->
    OwnershipManifestCommitUnavailable (ObservationFailure (bounded detail))

observationFailureText :: ObservationFailure -> Text
observationFailureText (ObservationFailure detail) = bounded detail

renderError :: OwnershipManifestRepositoryError -> Text
renderError = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024

requireListLength :: String -> Int -> Cbor.Decoder s ()
requireListLength label expected = do
  actual <- Cbor.decodeListLen
  unless (actual == expected) $
    fail (label <> ": expected " <> show expected <> " fields")
