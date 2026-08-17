{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded, versioned wire algebra for the Lifecycle Authority EKS
-- drain-intent repository.  The central authenticated Authority route installs
-- this algebra over the retained Model-B repository; the codec remains pure so
-- its replay and recovery boundaries can be tested independently.
module Prodbox.ControlPlane.EksDrainIntentEndpoint
  ( EksDrainIntentWireAction (..)
  , EksDrainIntentWireRequest (..)
  , eksDrainIntentCommitWireRequest
  , eksDrainIntentReadBackWireRequest
  , eksDrainIntentRecoveryWireRequest
  , EksDrainIntentConfirmationKind (..)
  , EksDrainIntentWireRefusal (..)
  , EksDrainIntentWireUnavailable (..)
  , EksDrainIntentWireResponse (..)
  , EksDrainIntentEndpointResult
  , eksDrainIntentEndpointFormatVersion
  , eksDrainIntentEndpointMaximumBytes
  , eksDrainIntentEndpointResponseMaximumBytes
  , serveEksDrainIntentEndpointRequest
  , eksDrainIntentEndpointStatus
  , eksDrainIntentWireResponseStatus
  , eksDrainIntentEndpointBody
  , decodeEksDrainIntentEndpointResponse
  , EksDrainIntentEndpointResponseError (..)
  , confirmEksDrainIntentEndpointResponse
  , confirmEksDrainIntentRecoveryResponse
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (decode, encode))
import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient (..)
  , EksDrainIntentClientError (..)
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  , EksDrainIntentCommitResult (..)
  , decodeEksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityIdentity
  , encodeEksDrainIntentAuthorityIdentity
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( CommittedEksDrainIntent
  , EksDrainIntent
  , EksDrainIntentError (..)
  , EksDrainIntentReadBackObservation (EksDrainIntentReadBackPresent)
  , committedEksDrainIntent
  , committedEksDrainIntentDigest
  , confirmEksDrainIntentCommitted
  , decodeEksDrainIntent
  , eksDrainIntentDigest
  , eksDrainIntentDigestText
  , encodeEksDrainIntent
  , maximumEksDrainIntentBytes
  )

data EksDrainIntentWireAction
  = EksDrainIntentWireCommit
  | EksDrainIntentWireReadBack
  | EksDrainIntentWireRecover
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentWireAction where
  encode action =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case action of
            EksDrainIntentWireCommit -> 0
            EksDrainIntentWireReadBack -> 1
            EksDrainIntentWireRecover -> 2
        )
  decode = do
    requireListLength "EksDrainIntentWireAction" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainIntentWireCommit
      1 -> pure EksDrainIntentWireReadBack
      2 -> pure EksDrainIntentWireRecover
      _ -> fail "EksDrainIntentWireAction: unknown tag"

data EksDrainIntentWireRequest = EksDrainIntentWireRequest
  { eksDrainIntentWireRequestVersion :: !Word16
  , eksDrainIntentWireRequestAction :: !EksDrainIntentWireAction
  , eksDrainIntentWireRequestCanonicalBytes :: !ByteString
  }
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentWireRequest where
  encode request =
    Cbor.encodeListLen 3
      <> Cbor.encodeWord16 (eksDrainIntentWireRequestVersion request)
      <> encode (eksDrainIntentWireRequestAction request)
      <> Cbor.encodeBytes (eksDrainIntentWireRequestCanonicalBytes request)
  decode = do
    requireListLength "EksDrainIntentWireRequest" 3
    EksDrainIntentWireRequest
      <$> Cbor.decodeWord16
      <*> decode
      <*> Cbor.decodeBytes

eksDrainIntentCommitWireRequest :: EksDrainIntent -> EksDrainIntentWireRequest
eksDrainIntentCommitWireRequest =
  wireRequest EksDrainIntentWireCommit

eksDrainIntentReadBackWireRequest :: EksDrainIntent -> EksDrainIntentWireRequest
eksDrainIntentReadBackWireRequest =
  wireRequest EksDrainIntentWireReadBack

eksDrainIntentRecoveryWireRequest
  :: EksDrainIntentAuthorityIdentity -> EksDrainIntentWireRequest
eksDrainIntentRecoveryWireRequest identity =
  EksDrainIntentWireRequest
    { eksDrainIntentWireRequestVersion = eksDrainIntentEndpointFormatVersion
    , eksDrainIntentWireRequestAction = EksDrainIntentWireRecover
    , eksDrainIntentWireRequestCanonicalBytes =
        encodeEksDrainIntentAuthorityIdentity identity
    }

wireRequest
  :: EksDrainIntentWireAction
  -> EksDrainIntent
  -> EksDrainIntentWireRequest
wireRequest action intent =
  EksDrainIntentWireRequest
    { eksDrainIntentWireRequestVersion = eksDrainIntentEndpointFormatVersion
    , eksDrainIntentWireRequestAction = action
    , eksDrainIntentWireRequestCanonicalBytes = encodeEksDrainIntent intent
    }

data EksDrainIntentConfirmationKind
  = EksDrainIntentCommitConfirmed
  | EksDrainIntentReadBackConfirmed
  | EksDrainIntentRecoveryConfirmed
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentConfirmationKind where
  encode kind =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case kind of
            EksDrainIntentCommitConfirmed -> 0
            EksDrainIntentReadBackConfirmed -> 1
            EksDrainIntentRecoveryConfirmed -> 2
        )
  decode = do
    requireListLength "EksDrainIntentConfirmationKind" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainIntentCommitConfirmed
      1 -> pure EksDrainIntentReadBackConfirmed
      2 -> pure EksDrainIntentRecoveryConfirmed
      _ -> fail "EksDrainIntentConfirmationKind: unknown tag"

data EksDrainIntentWireRefusal
  = EksDrainIntentWireRequestTooLarge
  | EksDrainIntentWireRequestInvalid
  | EksDrainIntentWireRequestUnsupportedVersion
  | EksDrainIntentWireRequestNonCanonical
  | EksDrainIntentWireIntentInvalid
  | EksDrainIntentWireCommitConflict
  | EksDrainIntentWireCommitCancelled
  | EksDrainIntentWireCommitNotDurable
  | EksDrainIntentWireReadBackMissing
  | EksDrainIntentWireReadBackMismatch
  | EksDrainIntentWireRecoveryIdentityInvalid
  | EksDrainIntentWireRecoveryMissing
  | EksDrainIntentWireRecoveryMismatch
  | EksDrainIntentWireRecoveryCorrupt
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentWireRefusal where
  encode refusal =
    Cbor.encodeListLen 1 <> Cbor.encodeWord (wireRefusalTag refusal)
  decode = do
    requireListLength "EksDrainIntentWireRefusal" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainIntentWireRequestTooLarge
      1 -> pure EksDrainIntentWireRequestInvalid
      2 -> pure EksDrainIntentWireRequestUnsupportedVersion
      3 -> pure EksDrainIntentWireRequestNonCanonical
      4 -> pure EksDrainIntentWireIntentInvalid
      5 -> pure EksDrainIntentWireCommitConflict
      6 -> pure EksDrainIntentWireCommitCancelled
      7 -> pure EksDrainIntentWireCommitNotDurable
      8 -> pure EksDrainIntentWireReadBackMissing
      9 -> pure EksDrainIntentWireReadBackMismatch
      10 -> pure EksDrainIntentWireRecoveryIdentityInvalid
      11 -> pure EksDrainIntentWireRecoveryMissing
      12 -> pure EksDrainIntentWireRecoveryMismatch
      13 -> pure EksDrainIntentWireRecoveryCorrupt
      _ -> fail "EksDrainIntentWireRefusal: unknown tag"

wireRefusalTag :: EksDrainIntentWireRefusal -> Word
wireRefusalTag refusal = case refusal of
  EksDrainIntentWireRequestTooLarge -> 0
  EksDrainIntentWireRequestInvalid -> 1
  EksDrainIntentWireRequestUnsupportedVersion -> 2
  EksDrainIntentWireRequestNonCanonical -> 3
  EksDrainIntentWireIntentInvalid -> 4
  EksDrainIntentWireCommitConflict -> 5
  EksDrainIntentWireCommitCancelled -> 6
  EksDrainIntentWireCommitNotDurable -> 7
  EksDrainIntentWireReadBackMissing -> 8
  EksDrainIntentWireReadBackMismatch -> 9
  EksDrainIntentWireRecoveryIdentityInvalid -> 10
  EksDrainIntentWireRecoveryMissing -> 11
  EksDrainIntentWireRecoveryMismatch -> 12
  EksDrainIntentWireRecoveryCorrupt -> 13

data EksDrainIntentWireUnavailable
  = EksDrainIntentWireCommitUnavailable
  | EksDrainIntentWireReadBackUnavailable
  | EksDrainIntentWireRecoveryUnobservable
  | EksDrainIntentWireRecoveryUnbounded
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentWireUnavailable where
  encode unavailable =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case unavailable of
            EksDrainIntentWireCommitUnavailable -> 0
            EksDrainIntentWireReadBackUnavailable -> 1
            EksDrainIntentWireRecoveryUnobservable -> 2
            EksDrainIntentWireRecoveryUnbounded -> 3
        )
  decode = do
    requireListLength "EksDrainIntentWireUnavailable" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainIntentWireCommitUnavailable
      1 -> pure EksDrainIntentWireReadBackUnavailable
      2 -> pure EksDrainIntentWireRecoveryUnobservable
      3 -> pure EksDrainIntentWireRecoveryUnbounded
      _ -> fail "EksDrainIntentWireUnavailable: unknown tag"

data EksDrainIntentWireResponse
  = EksDrainIntentWireConfirmed
      !Word16
      !EksDrainIntentConfirmationKind
      !ByteString
      !Text
  | EksDrainIntentWireRefused
      !Word16
      !EksDrainIntentWireRefusal
  | EksDrainIntentWireEndpointUnavailable
      !Word16
      !EksDrainIntentWireUnavailable
  deriving stock (Eq, Show)

instance Serialise EksDrainIntentWireResponse where
  encode response = case response of
    EksDrainIntentWireConfirmed version kind bytes digest ->
      Cbor.encodeListLen 5
        <> Cbor.encodeWord 0
        <> Cbor.encodeWord16 version
        <> encode kind
        <> Cbor.encodeBytes bytes
        <> Cbor.encodeString digest
    EksDrainIntentWireRefused version refusal ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 1
        <> Cbor.encodeWord16 version
        <> encode refusal
    EksDrainIntentWireEndpointUnavailable version unavailable ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 2
        <> Cbor.encodeWord16 version
        <> encode unavailable
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case tag of
      0 -> do
        unless (fields == 5) $ fail "EksDrainIntentWireResponse: invalid confirmation length"
        EksDrainIntentWireConfirmed
          <$> Cbor.decodeWord16
          <*> decode
          <*> Cbor.decodeBytes
          <*> Cbor.decodeString
      1 -> do
        unless (fields == 3) $ fail "EksDrainIntentWireResponse: invalid refusal length"
        EksDrainIntentWireRefused <$> Cbor.decodeWord16 <*> decode
      2 -> do
        unless (fields == 3) $ fail "EksDrainIntentWireResponse: invalid unavailable length"
        EksDrainIntentWireEndpointUnavailable <$> Cbor.decodeWord16 <*> decode
      _ -> fail "EksDrainIntentWireResponse: unknown tag"

requireListLength :: String -> Int -> Cbor.Decoder s ()
requireListLength label expected = do
  actual <- Cbor.decodeListLen
  unless (actual == expected) $
    fail (label <> ": expected " <> show expected <> " fields")

newtype EksDrainIntentEndpointResult = EksDrainIntentEndpointResult
  { internalEksDrainIntentEndpointResponse :: EksDrainIntentWireResponse
  }
  deriving stock (Eq, Show)

eksDrainIntentEndpointFormatVersion :: Word16
eksDrainIntentEndpointFormatVersion = 1

eksDrainIntentEndpointMaximumBytes :: Int
eksDrainIntentEndpointMaximumBytes = maximumEksDrainIntentBytes + 4096

eksDrainIntentEndpointResponseMaximumBytes :: Int
eksDrainIntentEndpointResponseMaximumBytes = maximumEksDrainIntentBytes + 4096

serveEksDrainIntentEndpointRequest
  :: (Monad m)
  => EksDrainIntentClient m
  -> LazyByteString.ByteString
  -> m EksDrainIntentEndpointResult
serveEksDrainIntentEndpointRequest client requestBytes =
  case decodeControlPlaneRequest
    eksDrainIntentEndpointMaximumBytes
    requestBytes of
    Left err -> pure (endpointResponse (requestCodecRefusal err))
    Right request
      | eksDrainIntentWireRequestVersion request
          /= eksDrainIntentEndpointFormatVersion ->
          pure
            ( refusedResponse
                EksDrainIntentWireRequestUnsupportedVersion
            )
      | otherwise -> case eksDrainIntentWireRequestAction request of
          EksDrainIntentWireRecover ->
            case decodeEksDrainIntentAuthorityIdentity
              (eksDrainIntentWireRequestCanonicalBytes request) of
              Left _ ->
                pure
                  ( refusedResponse
                      EksDrainIntentWireRecoveryIdentityInvalid
                  )
              Right identity -> serveRecovery identity
          EksDrainIntentWireCommit -> serveIntentAction request
          EksDrainIntentWireReadBack -> serveIntentAction request
 where
  serveIntentAction request =
    case decodeEksDrainIntent
      (eksDrainIntentWireRequestCanonicalBytes request) of
      Left _ -> pure (refusedResponse EksDrainIntentWireIntentInvalid)
      Right intent -> serveAction request intent

  serveAction request intent = do
    result <- case eksDrainIntentWireRequestAction request of
      EksDrainIntentWireCommit ->
        commitAndReadBackEksDrainIntent client intent
      EksDrainIntentWireReadBack ->
        readBackCommittedEksDrainIntent client intent
      EksDrainIntentWireRecover ->
        pure
          ( Left
              ( EksDrainIntentClientRemoteProofInvalid
                  "recovery action reached intent decoder"
              )
          )
    pure $ case result of
      Right committed ->
        confirmedResponse
          (confirmationKind (eksDrainIntentWireRequestAction request))
          committed
      Left err -> clientErrorResponse err

  serveRecovery identity = do
    result <- recoverCommittedEksDrainIntent client identity
    pure $ case result of
      Right committed ->
        confirmedResponse EksDrainIntentRecoveryConfirmed committed
      Left err -> clientErrorResponse err

confirmationKind
  :: EksDrainIntentWireAction -> EksDrainIntentConfirmationKind
confirmationKind action = case action of
  EksDrainIntentWireCommit -> EksDrainIntentCommitConfirmed
  EksDrainIntentWireReadBack -> EksDrainIntentReadBackConfirmed
  EksDrainIntentWireRecover -> EksDrainIntentRecoveryConfirmed

confirmedResponse
  :: EksDrainIntentConfirmationKind
  -> CommittedEksDrainIntent
  -> EksDrainIntentEndpointResult
confirmedResponse kind committed =
  endpointResponse
    ( EksDrainIntentWireConfirmed
        eksDrainIntentEndpointFormatVersion
        kind
        (encodeEksDrainIntent (committedEksDrainIntent committed))
        (eksDrainIntentDigestText (committedEksDrainIntentDigest committed))
    )

clientErrorResponse
  :: EksDrainIntentClientError -> EksDrainIntentEndpointResult
clientErrorResponse err = case err of
  EksDrainIntentClientRequestInvalid _ ->
    refusedResponse EksDrainIntentWireIntentInvalid
  EksDrainIntentClientCommitUnconfirmed commitResult intentError ->
    commitFailureResponse commitResult intentError
  EksDrainIntentClientReadBackInvalid intentError ->
    readBackFailureResponse intentError
  EksDrainIntentClientRecoveryMissing ->
    refusedResponse EksDrainIntentWireRecoveryMissing
  EksDrainIntentClientRecoveryUnobservable _ ->
    unavailableResponse EksDrainIntentWireRecoveryUnobservable
  EksDrainIntentClientRecoveryUnbounded _ _ ->
    unavailableResponse EksDrainIntentWireRecoveryUnbounded
  EksDrainIntentClientRecoveryCorrupt _ ->
    refusedResponse EksDrainIntentWireRecoveryCorrupt
  EksDrainIntentClientRecoveryStoreCorrupt _ ->
    refusedResponse EksDrainIntentWireRecoveryCorrupt
  EksDrainIntentClientRecoveryIdentityMismatch {} ->
    refusedResponse EksDrainIntentWireRecoveryMismatch
  EksDrainIntentClientRecoveryProofInvalid _ ->
    refusedResponse EksDrainIntentWireRecoveryCorrupt
  EksDrainIntentClientTransportFailed _ ->
    unavailableResponse EksDrainIntentWireCommitUnavailable
  EksDrainIntentClientResponseInvalid _ ->
    unavailableResponse EksDrainIntentWireCommitUnavailable
  EksDrainIntentClientHttpStatusMismatch _ _ ->
    unavailableResponse EksDrainIntentWireCommitUnavailable
  EksDrainIntentClientRemoteRefused _ ->
    refusedResponse EksDrainIntentWireReadBackMismatch
  EksDrainIntentClientRemoteUnavailable _ ->
    unavailableResponse EksDrainIntentWireReadBackUnavailable
  EksDrainIntentClientRemoteProofInvalid _ ->
    refusedResponse EksDrainIntentWireReadBackMismatch

commitFailureResponse
  :: EksDrainIntentCommitResult
  -> EksDrainIntentError
  -> EksDrainIntentEndpointResult
commitFailureResponse commitResult intentError = case commitResult of
  EksDrainIntentCommitConflict ->
    refusedResponse EksDrainIntentWireCommitConflict
  EksDrainIntentCommitCancelled ->
    refusedResponse EksDrainIntentWireCommitCancelled
  EksDrainIntentCommitResponseLost _ ->
    unavailableResponse EksDrainIntentWireCommitUnavailable
  EksDrainIntentCommitUnavailable _ ->
    unavailableResponse EksDrainIntentWireCommitUnavailable
  EksDrainIntentCommitCreated -> committedButUnconfirmed intentError
  EksDrainIntentCommitExactReplay -> committedButUnconfirmed intentError

committedButUnconfirmed
  :: EksDrainIntentError -> EksDrainIntentEndpointResult
committedButUnconfirmed intentError = case intentError of
  EksDrainIntentReadBackUnobservableRefusal _ ->
    unavailableResponse EksDrainIntentWireReadBackUnavailable
  EksDrainIntentReadBackMissingRefusal ->
    refusedResponse EksDrainIntentWireCommitNotDurable
  _ -> refusedResponse EksDrainIntentWireReadBackMismatch

readBackFailureResponse
  :: EksDrainIntentError -> EksDrainIntentEndpointResult
readBackFailureResponse intentError = case intentError of
  EksDrainIntentReadBackMissingRefusal ->
    refusedResponse EksDrainIntentWireReadBackMissing
  EksDrainIntentReadBackUnobservableRefusal _ ->
    unavailableResponse EksDrainIntentWireReadBackUnavailable
  _ -> refusedResponse EksDrainIntentWireReadBackMismatch

requestCodecRefusal
  :: ControlPlaneRequestCodecError -> EksDrainIntentWireResponse
requestCodecRefusal err =
  EksDrainIntentWireRefused
    eksDrainIntentEndpointFormatVersion
    ( case err of
        ControlPlaneRequestTooLarge -> EksDrainIntentWireRequestTooLarge
        ControlPlaneRequestInvalid -> EksDrainIntentWireRequestInvalid
        ControlPlaneRequestUnsupportedVersion ->
          EksDrainIntentWireRequestUnsupportedVersion
        ControlPlaneRequestNonCanonical ->
          EksDrainIntentWireRequestNonCanonical
    )

refusedResponse
  :: EksDrainIntentWireRefusal -> EksDrainIntentEndpointResult
refusedResponse refusal =
  endpointResponse
    ( EksDrainIntentWireRefused
        eksDrainIntentEndpointFormatVersion
        refusal
    )

unavailableResponse
  :: EksDrainIntentWireUnavailable -> EksDrainIntentEndpointResult
unavailableResponse unavailable =
  endpointResponse
    ( EksDrainIntentWireEndpointUnavailable
        eksDrainIntentEndpointFormatVersion
        unavailable
    )

endpointResponse
  :: EksDrainIntentWireResponse -> EksDrainIntentEndpointResult
endpointResponse = EksDrainIntentEndpointResult

eksDrainIntentEndpointStatus
  :: EksDrainIntentEndpointResult -> ReplyStatus
eksDrainIntentEndpointStatus =
  eksDrainIntentWireResponseStatus
    . internalEksDrainIntentEndpointResponse

eksDrainIntentWireResponseStatus
  :: EksDrainIntentWireResponse -> ReplyStatus
eksDrainIntentWireResponseStatus response = case response of
  EksDrainIntentWireConfirmed {} -> ReplyOk
  EksDrainIntentWireEndpointUnavailable {} -> ReplyServiceUnavailable
  EksDrainIntentWireRefused _ refusal -> case refusal of
    EksDrainIntentWireRequestTooLarge -> ReplyBadRequest
    EksDrainIntentWireRequestInvalid -> ReplyBadRequest
    EksDrainIntentWireRequestUnsupportedVersion -> ReplyBadRequest
    EksDrainIntentWireRequestNonCanonical -> ReplyBadRequest
    EksDrainIntentWireIntentInvalid -> ReplyBadRequest
    EksDrainIntentWireCommitConflict -> ReplyConflict
    EksDrainIntentWireCommitCancelled -> ReplyRequestTimeout
    EksDrainIntentWireCommitNotDurable -> ReplyConflict
    EksDrainIntentWireReadBackMissing -> ReplyNotFound
    EksDrainIntentWireReadBackMismatch -> ReplyConflict
    EksDrainIntentWireRecoveryIdentityInvalid -> ReplyBadRequest
    EksDrainIntentWireRecoveryMissing -> ReplyNotFound
    EksDrainIntentWireRecoveryMismatch -> ReplyConflict
    EksDrainIntentWireRecoveryCorrupt -> ReplyInternalError

eksDrainIntentEndpointBody :: EksDrainIntentEndpointResult -> ByteString
eksDrainIntentEndpointBody =
  LazyByteString.toStrict
    . encodeControlPlaneResponse
    . internalEksDrainIntentEndpointResponse

decodeEksDrainIntentEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError EksDrainIntentWireResponse
decodeEksDrainIntentEndpointResponse =
  decodeControlPlaneResponse eksDrainIntentEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data EksDrainIntentEndpointResponseError
  = EksDrainIntentEndpointResponseVersionMismatch !Word16 !Word16
  | EksDrainIntentEndpointResponseKindMismatch
      !EksDrainIntentConfirmationKind
      !EksDrainIntentConfirmationKind
  | EksDrainIntentEndpointResponseDigestMismatch !Text !Text
  | EksDrainIntentEndpointResponseProofInvalid !EksDrainIntentError
  | EksDrainIntentEndpointResponseRecoveryIdentityMismatch
      !EksDrainIntentAuthorityIdentity
      !EksDrainIntentAuthorityIdentity
  | EksDrainIntentEndpointResponseRefused !EksDrainIntentWireRefusal
  | EksDrainIntentEndpointResponseUnavailable !EksDrainIntentWireUnavailable
  deriving stock (Eq, Show)

-- | Validate an authenticated wire response back into the opaque committed
-- proof.  A transport client must call this after the bounded response decoder;
-- it must never treat a @200@ status or a digest string as commitment evidence.
confirmEksDrainIntentEndpointResponse
  :: EksDrainIntentConfirmationKind
  -> EksDrainIntent
  -> EksDrainIntentWireResponse
  -> Either EksDrainIntentEndpointResponseError CommittedEksDrainIntent
confirmEksDrainIntentEndpointResponse expectedKind expectedIntent response =
  case response of
    EksDrainIntentWireRefused version _
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
    EksDrainIntentWireRefused _ refusal ->
      Left (EksDrainIntentEndpointResponseRefused refusal)
    EksDrainIntentWireEndpointUnavailable version _
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
    EksDrainIntentWireEndpointUnavailable _ unavailable ->
      Left (EksDrainIntentEndpointResponseUnavailable unavailable)
    EksDrainIntentWireConfirmed version observedKind bytes observedDigest
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
      | observedKind /= expectedKind ->
          Left
            ( EksDrainIntentEndpointResponseKindMismatch
                expectedKind
                observedKind
            )
      | observedDigest /= expectedDigest ->
          Left
            ( EksDrainIntentEndpointResponseDigestMismatch
                expectedDigest
                observedDigest
            )
      | otherwise ->
          first
            EksDrainIntentEndpointResponseProofInvalid
            ( confirmEksDrainIntentCommitted
                expectedIntent
                (EksDrainIntentReadBackPresent bytes)
            )
 where
  expectedDigest = eksDrainIntentDigestText (eksDrainIntentDigest expectedIntent)

-- | Reconstruct a committed proof after process loss using only the expected
-- Authority identity.  The returned canonical intent is decoded, every
-- identity field is recomputed, and the opaque proof is minted only after the
-- exact positive byte read-back check.
confirmEksDrainIntentRecoveryResponse
  :: EksDrainIntentAuthorityIdentity
  -> EksDrainIntentWireResponse
  -> Either EksDrainIntentEndpointResponseError CommittedEksDrainIntent
confirmEksDrainIntentRecoveryResponse expectedIdentity response =
  case response of
    EksDrainIntentWireRefused version _
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
    EksDrainIntentWireRefused _ refusal ->
      Left (EksDrainIntentEndpointResponseRefused refusal)
    EksDrainIntentWireEndpointUnavailable version _
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
    EksDrainIntentWireEndpointUnavailable _ unavailable ->
      Left (EksDrainIntentEndpointResponseUnavailable unavailable)
    EksDrainIntentWireConfirmed version observedKind bytes observedDigest
      | version /= eksDrainIntentEndpointFormatVersion ->
          versionMismatch version
      | observedKind /= EksDrainIntentRecoveryConfirmed ->
          Left
            ( EksDrainIntentEndpointResponseKindMismatch
                EksDrainIntentRecoveryConfirmed
                observedKind
            )
      | otherwise -> do
          observedIntent <-
            first
              EksDrainIntentEndpointResponseProofInvalid
              (decodeEksDrainIntent bytes)
          let observedIdentity =
                eksDrainIntentAuthorityIdentity observedIntent
          unlessRecovery
            (observedIdentity == expectedIdentity)
            ( EksDrainIntentEndpointResponseRecoveryIdentityMismatch
                expectedIdentity
                observedIdentity
            )
          let expectedDigest =
                eksDrainIntentDigestText
                  (eksDrainIntentDigest observedIntent)
          unlessRecovery
            (observedDigest == expectedDigest)
            ( EksDrainIntentEndpointResponseDigestMismatch
                expectedDigest
                observedDigest
            )
          first
            EksDrainIntentEndpointResponseProofInvalid
            ( confirmEksDrainIntentCommitted
                observedIntent
                (EksDrainIntentReadBackPresent bytes)
            )

unlessRecovery
  :: Bool
  -> EksDrainIntentEndpointResponseError
  -> Either EksDrainIntentEndpointResponseError ()
unlessRecovery condition err = if condition then Right () else Left err

versionMismatch
  :: Word16
  -> Either EksDrainIntentEndpointResponseError value
versionMismatch observed =
  Left
    ( EksDrainIntentEndpointResponseVersionMismatch
        eksDrainIntentEndpointFormatVersion
        observed
    )
