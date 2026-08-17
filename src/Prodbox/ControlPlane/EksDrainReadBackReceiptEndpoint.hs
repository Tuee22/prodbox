{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Canonical bounded wire algebra for the Authority-owned EKS drain
-- read-back receipt.  Commit payloads are locally prepared opaque receipts;
-- the Authority independently recovers the retained intent and remints the
-- proof before create-or-replay.  Read-back and recovery use only the stable
-- intent identity, never a process-local attempt map.
module Prodbox.ControlPlane.EksDrainReadBackReceiptEndpoint
  ( EksDrainReadBackReceiptWireAction (..)
  , EksDrainReadBackReceiptWireRequest (..)
  , eksDrainReadBackReceiptCommitWireRequest
  , eksDrainReadBackReceiptReadBackWireRequest
  , eksDrainReadBackReceiptRecoveryWireRequest
  , EksDrainReadBackReceiptConfirmationKind (..)
  , EksDrainReadBackReceiptWireRefusal (..)
  , EksDrainReadBackReceiptWireUnavailable (..)
  , EksDrainReadBackReceiptWireResponse (..)
  , EksDrainReadBackReceiptEndpointResult
  , eksDrainReadBackReceiptEndpointFormatVersion
  , eksDrainReadBackReceiptEndpointMaximumBytes
  , eksDrainReadBackReceiptEndpointResponseMaximumBytes
  , serveEksDrainReadBackReceiptEndpointRequest
  , eksDrainReadBackReceiptEndpointStatus
  , eksDrainReadBackReceiptWireResponseStatus
  , eksDrainReadBackReceiptEndpointBody
  , decodeEksDrainReadBackReceiptEndpointResponse
  , EksDrainReadBackReceiptEndpointResponseError (..)
  , confirmEksDrainReadBackReceiptEndpointResponse
  , confirmEksDrainReadBackReceiptIdentityResponse
  , confirmEksDrainReadBackReceiptRecoveryResponse
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
import Data.Word (Word16)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClientError (..)
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( EksDrainIntentAuthorityIdentity
  , decodeEksDrainIntentAuthorityIdentity
  , eksDrainIntentAuthorityIdentity
  , encodeEksDrainIntentAuthorityIdentity
  , maximumEksDrainIntentAuthorityIdentityBytes
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
  ( EksDrainReadBackReceiptClient (..)
  , EksDrainReadBackReceiptClientError (..)
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
  ( CommittedEksDrainReadBackReceipt
  , EksDrainReadBackReceiptCommitResult (..)
  , EksDrainReadBackReceiptError (..)
  , committedEksDrainReadBackReceiptBytes
  , committedEksDrainReadBackReceiptDigest
  , committedEksDrainReadBackReceiptEvidenceDigest
  , committedEksDrainTargetsAbsentEvidence
  , eksDrainReadBackEvidenceDigestText
  , eksDrainReadBackReceiptCommitRequestBytes
  , eksDrainReadBackReceiptDigestText
  , eksDrainReadBackReceiptMaximumBytes
  , prepareEksDrainReadBackReceiptCommitRequest
  , recoverCommittedEksDrainReadBackReceipt
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( CommittedEksDrainIntent
  , EksDrainAttemptEvidence
  , EksDrainIntentError
  , EksDrainIntentReadBackObservation (EksDrainIntentReadBackPresent)
  , EksDrainTargetReadBackObservation
  , committedEksDrainIntent
  , confirmEksDrainIntentCommitted
  , decodeEksDrainIntent
  , eksDrainTargetsAbsentIntent
  , encodeEksDrainIntent
  , maximumEksDrainIntentBytes
  )

data EksDrainReadBackReceiptWireAction
  = EksDrainReadBackReceiptWireCommit
  | EksDrainReadBackReceiptWireReadBack
  | EksDrainReadBackReceiptWireRecover
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptWireAction where
  encode action =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case action of
            EksDrainReadBackReceiptWireCommit -> 0
            EksDrainReadBackReceiptWireReadBack -> 1
            EksDrainReadBackReceiptWireRecover -> 2
        )
  decode = do
    requireListLength "EksDrainReadBackReceiptWireAction" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainReadBackReceiptWireCommit
      1 -> pure EksDrainReadBackReceiptWireReadBack
      2 -> pure EksDrainReadBackReceiptWireRecover
      _ -> fail "EksDrainReadBackReceiptWireAction: unknown tag"

data EksDrainReadBackReceiptWireRequest = EksDrainReadBackReceiptWireRequest
  { eksDrainReadBackReceiptWireRequestVersion :: !Word16
  , eksDrainReadBackReceiptWireRequestAction
      :: !EksDrainReadBackReceiptWireAction
  , eksDrainReadBackReceiptWireRequestIntentIdentityBytes :: !ByteString
  , eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes :: !ByteString
  }
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptWireRequest where
  encode request =
    Cbor.encodeListLen 4
      <> Cbor.encodeWord16 (eksDrainReadBackReceiptWireRequestVersion request)
      <> encode (eksDrainReadBackReceiptWireRequestAction request)
      <> Cbor.encodeBytes
        (eksDrainReadBackReceiptWireRequestIntentIdentityBytes request)
      <> Cbor.encodeBytes
        (eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes request)
  decode = do
    requireListLength "EksDrainReadBackReceiptWireRequest" 4
    EksDrainReadBackReceiptWireRequest
      <$> Cbor.decodeWord16
      <*> decode
      <*> Cbor.decodeBytes
      <*> Cbor.decodeBytes

eksDrainReadBackReceiptCommitWireRequest
  :: CommittedEksDrainIntent
  -> EksDrainAttemptEvidence
  -> EksDrainTargetReadBackObservation
  -> Either EksDrainReadBackReceiptError EksDrainReadBackReceiptWireRequest
eksDrainReadBackReceiptCommitWireRequest committed attempt observation = do
  request <-
    prepareEksDrainReadBackReceiptCommitRequest committed attempt observation
  Right
    EksDrainReadBackReceiptWireRequest
      { eksDrainReadBackReceiptWireRequestVersion =
          eksDrainReadBackReceiptEndpointFormatVersion
      , eksDrainReadBackReceiptWireRequestAction =
          EksDrainReadBackReceiptWireCommit
      , eksDrainReadBackReceiptWireRequestIntentIdentityBytes =
          encodeEksDrainIntentAuthorityIdentity
            (eksDrainIntentAuthorityIdentity (committedEksDrainIntent committed))
      , eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes =
          eksDrainReadBackReceiptCommitRequestBytes request
      }

eksDrainReadBackReceiptReadBackWireRequest
  :: CommittedEksDrainIntent -> EksDrainReadBackReceiptWireRequest
eksDrainReadBackReceiptReadBackWireRequest committed =
  identityOnlyRequest
    EksDrainReadBackReceiptWireReadBack
    (eksDrainIntentAuthorityIdentity (committedEksDrainIntent committed))

eksDrainReadBackReceiptRecoveryWireRequest
  :: EksDrainIntentAuthorityIdentity
  -> EksDrainReadBackReceiptWireRequest
eksDrainReadBackReceiptRecoveryWireRequest =
  identityOnlyRequest EksDrainReadBackReceiptWireRecover

identityOnlyRequest
  :: EksDrainReadBackReceiptWireAction
  -> EksDrainIntentAuthorityIdentity
  -> EksDrainReadBackReceiptWireRequest
identityOnlyRequest action identity =
  EksDrainReadBackReceiptWireRequest
    { eksDrainReadBackReceiptWireRequestVersion =
        eksDrainReadBackReceiptEndpointFormatVersion
    , eksDrainReadBackReceiptWireRequestAction = action
    , eksDrainReadBackReceiptWireRequestIntentIdentityBytes =
        encodeEksDrainIntentAuthorityIdentity identity
    , eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes = ByteString.empty
    }

data EksDrainReadBackReceiptConfirmationKind
  = EksDrainReadBackReceiptCommitConfirmed
  | EksDrainReadBackReceiptReadBackConfirmed
  | EksDrainReadBackReceiptRecoveryConfirmed
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptConfirmationKind where
  encode kind =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case kind of
            EksDrainReadBackReceiptCommitConfirmed -> 0
            EksDrainReadBackReceiptReadBackConfirmed -> 1
            EksDrainReadBackReceiptRecoveryConfirmed -> 2
        )
  decode = do
    requireListLength "EksDrainReadBackReceiptConfirmationKind" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainReadBackReceiptCommitConfirmed
      1 -> pure EksDrainReadBackReceiptReadBackConfirmed
      2 -> pure EksDrainReadBackReceiptRecoveryConfirmed
      _ -> fail "EksDrainReadBackReceiptConfirmationKind: unknown tag"

data EksDrainReadBackReceiptWireRefusal
  = EksDrainReadBackReceiptWireRequestTooLarge
  | EksDrainReadBackReceiptWireRequestInvalid
  | EksDrainReadBackReceiptWireRequestUnsupportedVersion
  | EksDrainReadBackReceiptWireRequestNonCanonical
  | EksDrainReadBackReceiptWireIdentityInvalid
  | EksDrainReadBackReceiptWireCommitPayloadMissing
  | EksDrainReadBackReceiptWireUnexpectedPayload
  | EksDrainReadBackReceiptWireReceiptInvalid
  | EksDrainReadBackReceiptWireCommitConflict
  | EksDrainReadBackReceiptWireReceiptMissing
  | EksDrainReadBackReceiptWireProofMismatch
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptWireRefusal where
  encode refusal = Cbor.encodeListLen 1 <> Cbor.encodeWord (refusalTag refusal)
  decode = do
    requireListLength "EksDrainReadBackReceiptWireRefusal" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainReadBackReceiptWireRequestTooLarge
      1 -> pure EksDrainReadBackReceiptWireRequestInvalid
      2 -> pure EksDrainReadBackReceiptWireRequestUnsupportedVersion
      3 -> pure EksDrainReadBackReceiptWireRequestNonCanonical
      4 -> pure EksDrainReadBackReceiptWireIdentityInvalid
      5 -> pure EksDrainReadBackReceiptWireCommitPayloadMissing
      6 -> pure EksDrainReadBackReceiptWireUnexpectedPayload
      7 -> pure EksDrainReadBackReceiptWireReceiptInvalid
      8 -> pure EksDrainReadBackReceiptWireCommitConflict
      9 -> pure EksDrainReadBackReceiptWireReceiptMissing
      10 -> pure EksDrainReadBackReceiptWireProofMismatch
      _ -> fail "EksDrainReadBackReceiptWireRefusal: unknown tag"

refusalTag :: EksDrainReadBackReceiptWireRefusal -> Word
refusalTag refusal = case refusal of
  EksDrainReadBackReceiptWireRequestTooLarge -> 0
  EksDrainReadBackReceiptWireRequestInvalid -> 1
  EksDrainReadBackReceiptWireRequestUnsupportedVersion -> 2
  EksDrainReadBackReceiptWireRequestNonCanonical -> 3
  EksDrainReadBackReceiptWireIdentityInvalid -> 4
  EksDrainReadBackReceiptWireCommitPayloadMissing -> 5
  EksDrainReadBackReceiptWireUnexpectedPayload -> 6
  EksDrainReadBackReceiptWireReceiptInvalid -> 7
  EksDrainReadBackReceiptWireCommitConflict -> 8
  EksDrainReadBackReceiptWireReceiptMissing -> 9
  EksDrainReadBackReceiptWireProofMismatch -> 10

data EksDrainReadBackReceiptWireUnavailable
  = EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  | EksDrainReadBackReceiptWireCommitUnavailable
  | EksDrainReadBackReceiptWireReadBackUnavailable
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptWireUnavailable where
  encode reason =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case reason of
            EksDrainReadBackReceiptWireIntentRecoveryUnavailable -> 0
            EksDrainReadBackReceiptWireCommitUnavailable -> 1
            EksDrainReadBackReceiptWireReadBackUnavailable -> 2
        )
  decode = do
    requireListLength "EksDrainReadBackReceiptWireUnavailable" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure EksDrainReadBackReceiptWireIntentRecoveryUnavailable
      1 -> pure EksDrainReadBackReceiptWireCommitUnavailable
      2 -> pure EksDrainReadBackReceiptWireReadBackUnavailable
      _ -> fail "EksDrainReadBackReceiptWireUnavailable: unknown tag"

data EksDrainReadBackReceiptWireResponse
  = EksDrainReadBackReceiptWireConfirmed
      !Word16
      !EksDrainReadBackReceiptConfirmationKind
      !ByteString
      !ByteString
      !Text
      !Text
  | EksDrainReadBackReceiptWireRefused
      !Word16
      !EksDrainReadBackReceiptWireRefusal
  | EksDrainReadBackReceiptWireEndpointUnavailable
      !Word16
      !EksDrainReadBackReceiptWireUnavailable
  deriving stock (Eq, Show)

instance Serialise EksDrainReadBackReceiptWireResponse where
  encode response = case response of
    EksDrainReadBackReceiptWireConfirmed version kind intent receipt receiptDigest evidenceDigest ->
      Cbor.encodeListLen 7
        <> Cbor.encodeWord 0
        <> Cbor.encodeWord16 version
        <> encode kind
        <> Cbor.encodeBytes intent
        <> Cbor.encodeBytes receipt
        <> Cbor.encodeString receiptDigest
        <> Cbor.encodeString evidenceDigest
    EksDrainReadBackReceiptWireRefused version refusal ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 1
        <> Cbor.encodeWord16 version
        <> encode refusal
    EksDrainReadBackReceiptWireEndpointUnavailable version reason ->
      Cbor.encodeListLen 3
        <> Cbor.encodeWord 2
        <> Cbor.encodeWord16 version
        <> encode reason
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case tag of
      0 -> do
        unless (fields == 7) $ fail "receipt response: invalid confirmation length"
        EksDrainReadBackReceiptWireConfirmed
          <$> Cbor.decodeWord16
          <*> decode
          <*> Cbor.decodeBytes
          <*> Cbor.decodeBytes
          <*> Cbor.decodeString
          <*> Cbor.decodeString
      1 -> do
        unless (fields == 3) $ fail "receipt response: invalid refusal length"
        EksDrainReadBackReceiptWireRefused <$> Cbor.decodeWord16 <*> decode
      2 -> do
        unless (fields == 3) $ fail "receipt response: invalid unavailable length"
        EksDrainReadBackReceiptWireEndpointUnavailable <$> Cbor.decodeWord16 <*> decode
      _ -> fail "receipt response: unknown tag"

requireListLength :: String -> Int -> Cbor.Decoder s ()
requireListLength label expected = do
  actual <- Cbor.decodeListLen
  unless (actual == expected) $
    fail (label <> ": expected " <> show expected <> " fields")

newtype EksDrainReadBackReceiptEndpointResult
  = EksDrainReadBackReceiptEndpointResult EksDrainReadBackReceiptWireResponse
  deriving stock (Eq, Show)

eksDrainReadBackReceiptEndpointFormatVersion :: Word16
eksDrainReadBackReceiptEndpointFormatVersion = 1

eksDrainReadBackReceiptEndpointMaximumBytes :: Int
eksDrainReadBackReceiptEndpointMaximumBytes =
  eksDrainReadBackReceiptMaximumBytes
    + maximumEksDrainIntentAuthorityIdentityBytes
    + 8192

eksDrainReadBackReceiptEndpointResponseMaximumBytes :: Int
eksDrainReadBackReceiptEndpointResponseMaximumBytes =
  eksDrainReadBackReceiptMaximumBytes + maximumEksDrainIntentBytes + 8192

serveEksDrainReadBackReceiptEndpointRequest
  :: (Monad m)
  => EksDrainReadBackReceiptClient m
  -> LazyByteString.ByteString
  -> m EksDrainReadBackReceiptEndpointResult
serveEksDrainReadBackReceiptEndpointRequest client requestBytes =
  case decodeControlPlaneRequest eksDrainReadBackReceiptEndpointMaximumBytes requestBytes of
    Left err -> pure (endpointResult (requestCodecRefusal err))
    Right request
      | eksDrainReadBackReceiptWireRequestVersion request
          /= eksDrainReadBackReceiptEndpointFormatVersion ->
          pure (refused EksDrainReadBackReceiptWireRequestUnsupportedVersion)
      | otherwise -> case decodeEksDrainIntentAuthorityIdentity
          (eksDrainReadBackReceiptWireRequestIntentIdentityBytes request) of
          Left _ -> pure (refused EksDrainReadBackReceiptWireIdentityInvalid)
          Right identity -> serveAction identity request
 where
  serveAction identity request =
    case eksDrainReadBackReceiptWireRequestAction request of
      EksDrainReadBackReceiptWireCommit
        | ByteString.null payload ->
            pure (refused EksDrainReadBackReceiptWireCommitPayloadMissing)
        | otherwise -> do
            result <-
              commitCanonicalEksDrainReceiptFromIntentIdentity
                client
                identity
                payload
            pure
              ( either
                  clientErrorResult
                  (confirmed EksDrainReadBackReceiptCommitConfirmed)
                  result
              )
      EksDrainReadBackReceiptWireReadBack
        | not (ByteString.null payload) ->
            pure (refused EksDrainReadBackReceiptWireUnexpectedPayload)
        | otherwise -> recover identity EksDrainReadBackReceiptReadBackConfirmed
      EksDrainReadBackReceiptWireRecover
        | not (ByteString.null payload) ->
            pure (refused EksDrainReadBackReceiptWireUnexpectedPayload)
        | otherwise -> recover identity EksDrainReadBackReceiptRecoveryConfirmed
   where
    payload = eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes request
  recover identity kind = do
    result <- recoverEksDrainReceiptFromIntentIdentity client identity
    pure (either clientErrorResult (confirmed kind) result)

confirmed
  :: EksDrainReadBackReceiptConfirmationKind
  -> CommittedEksDrainReadBackReceipt
  -> EksDrainReadBackReceiptEndpointResult
confirmed kind receipt =
  endpointResult
    ( EksDrainReadBackReceiptWireConfirmed
        eksDrainReadBackReceiptEndpointFormatVersion
        kind
        ( encodeEksDrainIntent
            ( eksDrainTargetsAbsentIntent
                (committedEksDrainTargetsAbsentEvidence receipt)
            )
        )
        (committedEksDrainReadBackReceiptBytes receipt)
        ( eksDrainReadBackReceiptDigestText
            (committedEksDrainReadBackReceiptDigest receipt)
        )
        ( eksDrainReadBackEvidenceDigestText
            (committedEksDrainReadBackReceiptEvidenceDigest receipt)
        )
    )

clientErrorResult
  :: EksDrainReadBackReceiptClientError
  -> EksDrainReadBackReceiptEndpointResult
clientErrorResult err = case err of
  EksDrainReadBackReceiptClientRecoveryMissing ->
    refused EksDrainReadBackReceiptWireReceiptMissing
  EksDrainReadBackReceiptClientIntentRecoveryFailed intentError ->
    intentErrorResult intentError
  EksDrainReadBackReceiptClientReceiptFailed receiptError ->
    receiptErrorResult receiptError
  EksDrainReadBackReceiptClientTransportFailed _ ->
    endpointUnavailable EksDrainReadBackReceiptWireReadBackUnavailable
  EksDrainReadBackReceiptClientResponseInvalid _ ->
    endpointUnavailable EksDrainReadBackReceiptWireReadBackUnavailable
  EksDrainReadBackReceiptClientHttpStatusMismatch _ _ ->
    endpointUnavailable EksDrainReadBackReceiptWireReadBackUnavailable
  EksDrainReadBackReceiptClientRemoteRefused _ ->
    refused EksDrainReadBackReceiptWireProofMismatch
  EksDrainReadBackReceiptClientRemoteUnavailable _ ->
    endpointUnavailable EksDrainReadBackReceiptWireReadBackUnavailable
  EksDrainReadBackReceiptClientRemoteProofInvalid _ ->
    refused EksDrainReadBackReceiptWireProofMismatch

intentErrorResult :: EksDrainIntentClientError -> EksDrainReadBackReceiptEndpointResult
intentErrorResult err = case err of
  EksDrainIntentClientRecoveryMissing ->
    refused EksDrainReadBackReceiptWireReceiptMissing
  EksDrainIntentClientRecoveryUnobservable _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  EksDrainIntentClientRecoveryUnbounded _ _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  EksDrainIntentClientTransportFailed _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  EksDrainIntentClientResponseInvalid _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  EksDrainIntentClientHttpStatusMismatch _ _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  EksDrainIntentClientRemoteUnavailable _ ->
    endpointUnavailable EksDrainReadBackReceiptWireIntentRecoveryUnavailable
  _ -> refused EksDrainReadBackReceiptWireIdentityInvalid

receiptErrorResult
  :: EksDrainReadBackReceiptError -> EksDrainReadBackReceiptEndpointResult
receiptErrorResult err = case err of
  EksDrainReadBackReceiptCommitNotConfirmed EksDrainReadBackReceiptCommitConflict ->
    refused EksDrainReadBackReceiptWireCommitConflict
  EksDrainReadBackReceiptCommitNotConfirmed
    (EksDrainReadBackReceiptCommitResponseLost _) ->
      endpointUnavailable EksDrainReadBackReceiptWireCommitUnavailable
  EksDrainReadBackReceiptCommitNotConfirmed
    (EksDrainReadBackReceiptCommitUnavailable _) ->
      endpointUnavailable EksDrainReadBackReceiptWireCommitUnavailable
  EksDrainReadBackReceiptReadBackMissing ->
    refused EksDrainReadBackReceiptWireReceiptMissing
  EksDrainReadBackReceiptReadBackUnobservable _ ->
    endpointUnavailable EksDrainReadBackReceiptWireReadBackUnavailable
  EksDrainReadBackReceiptCodecTooLarge _ _ ->
    refused EksDrainReadBackReceiptWireRequestTooLarge
  EksDrainReadBackReceiptCommitReadBackConflict ->
    refused EksDrainReadBackReceiptWireProofMismatch
  _ -> refused EksDrainReadBackReceiptWireReceiptInvalid

requestCodecRefusal
  :: ControlPlaneRequestCodecError -> EksDrainReadBackReceiptWireResponse
requestCodecRefusal err =
  EksDrainReadBackReceiptWireRefused
    eksDrainReadBackReceiptEndpointFormatVersion
    ( case err of
        ControlPlaneRequestTooLarge -> EksDrainReadBackReceiptWireRequestTooLarge
        ControlPlaneRequestInvalid -> EksDrainReadBackReceiptWireRequestInvalid
        ControlPlaneRequestUnsupportedVersion ->
          EksDrainReadBackReceiptWireRequestUnsupportedVersion
        ControlPlaneRequestNonCanonical ->
          EksDrainReadBackReceiptWireRequestNonCanonical
    )

refused
  :: EksDrainReadBackReceiptWireRefusal
  -> EksDrainReadBackReceiptEndpointResult
refused refusal =
  endpointResult
    ( EksDrainReadBackReceiptWireRefused
        eksDrainReadBackReceiptEndpointFormatVersion
        refusal
    )

endpointUnavailable
  :: EksDrainReadBackReceiptWireUnavailable
  -> EksDrainReadBackReceiptEndpointResult
endpointUnavailable reason =
  endpointResult
    ( EksDrainReadBackReceiptWireEndpointUnavailable
        eksDrainReadBackReceiptEndpointFormatVersion
        reason
    )

endpointResult
  :: EksDrainReadBackReceiptWireResponse
  -> EksDrainReadBackReceiptEndpointResult
endpointResult = EksDrainReadBackReceiptEndpointResult

eksDrainReadBackReceiptEndpointStatus
  :: EksDrainReadBackReceiptEndpointResult -> ReplyStatus
eksDrainReadBackReceiptEndpointStatus (EksDrainReadBackReceiptEndpointResult response) =
  eksDrainReadBackReceiptWireResponseStatus response

eksDrainReadBackReceiptWireResponseStatus
  :: EksDrainReadBackReceiptWireResponse -> ReplyStatus
eksDrainReadBackReceiptWireResponseStatus response = case response of
  EksDrainReadBackReceiptWireConfirmed {} -> ReplyOk
  EksDrainReadBackReceiptWireEndpointUnavailable {} -> ReplyServiceUnavailable
  EksDrainReadBackReceiptWireRefused _ refusal -> case refusal of
    EksDrainReadBackReceiptWireCommitConflict -> ReplyConflict
    EksDrainReadBackReceiptWireReceiptMissing -> ReplyNotFound
    EksDrainReadBackReceiptWireProofMismatch -> ReplyConflict
    _ -> ReplyBadRequest

eksDrainReadBackReceiptEndpointBody
  :: EksDrainReadBackReceiptEndpointResult -> ByteString
eksDrainReadBackReceiptEndpointBody (EksDrainReadBackReceiptEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeEksDrainReadBackReceiptEndpointResponse
  :: ByteString
  -> Either
       ControlPlaneResponseCodecError
       EksDrainReadBackReceiptWireResponse
decodeEksDrainReadBackReceiptEndpointResponse =
  decodeControlPlaneResponse eksDrainReadBackReceiptEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data EksDrainReadBackReceiptEndpointResponseError
  = EksDrainReadBackReceiptEndpointResponseVersionMismatch !Word16 !Word16
  | EksDrainReadBackReceiptEndpointResponseKindMismatch
      !EksDrainReadBackReceiptConfirmationKind
      !EksDrainReadBackReceiptConfirmationKind
  | EksDrainReadBackReceiptEndpointResponseIntentInvalid !EksDrainIntentError
  | EksDrainReadBackReceiptEndpointResponseIdentityMismatch
      !EksDrainIntentAuthorityIdentity
      !EksDrainIntentAuthorityIdentity
  | EksDrainReadBackReceiptEndpointResponseExpectedIntentMismatch
  | EksDrainReadBackReceiptEndpointResponseReceiptInvalid
      !EksDrainReadBackReceiptError
  | EksDrainReadBackReceiptEndpointResponseReceiptDigestMismatch !Text !Text
  | EksDrainReadBackReceiptEndpointResponseEvidenceDigestMismatch !Text !Text
  | EksDrainReadBackReceiptEndpointResponseRefused
      !EksDrainReadBackReceiptWireRefusal
  | EksDrainReadBackReceiptEndpointResponseUnavailable
      !EksDrainReadBackReceiptWireUnavailable
  deriving stock (Eq, Show)

confirmEksDrainReadBackReceiptEndpointResponse
  :: EksDrainReadBackReceiptConfirmationKind
  -> CommittedEksDrainIntent
  -> EksDrainReadBackReceiptWireResponse
  -> Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
confirmEksDrainReadBackReceiptEndpointResponse expectedKind committed =
  confirmResponse
    expectedKind
    (eksDrainIntentAuthorityIdentity (committedEksDrainIntent committed))
    (Just committed)

confirmEksDrainReadBackReceiptRecoveryResponse
  :: EksDrainIntentAuthorityIdentity
  -> EksDrainReadBackReceiptWireResponse
  -> Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
confirmEksDrainReadBackReceiptRecoveryResponse identity =
  confirmEksDrainReadBackReceiptIdentityResponse
    EksDrainReadBackReceiptRecoveryConfirmed
    identity

confirmEksDrainReadBackReceiptIdentityResponse
  :: EksDrainReadBackReceiptConfirmationKind
  -> EksDrainIntentAuthorityIdentity
  -> EksDrainReadBackReceiptWireResponse
  -> Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
confirmEksDrainReadBackReceiptIdentityResponse expectedKind identity =
  confirmResponse expectedKind identity Nothing

confirmResponse
  :: EksDrainReadBackReceiptConfirmationKind
  -> EksDrainIntentAuthorityIdentity
  -> Maybe CommittedEksDrainIntent
  -> EksDrainReadBackReceiptWireResponse
  -> Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
confirmResponse expectedKind expectedIdentity maybeExpected response = case response of
  EksDrainReadBackReceiptWireRefused version refusal
    | version /= eksDrainReadBackReceiptEndpointFormatVersion -> versionMismatch version
    | otherwise -> Left (EksDrainReadBackReceiptEndpointResponseRefused refusal)
  EksDrainReadBackReceiptWireEndpointUnavailable version reason
    | version /= eksDrainReadBackReceiptEndpointFormatVersion -> versionMismatch version
    | otherwise -> Left (EksDrainReadBackReceiptEndpointResponseUnavailable reason)
  EksDrainReadBackReceiptWireConfirmed
    version
    observedKind
    intentBytes
    receiptBytes
    storedReceiptDigest
    storedEvidenceDigest
      | version /= eksDrainReadBackReceiptEndpointFormatVersion -> versionMismatch version
      | observedKind /= expectedKind ->
          Left
            ( EksDrainReadBackReceiptEndpointResponseKindMismatch
                expectedKind
                observedKind
            )
      | otherwise -> do
          intent <-
            first
              EksDrainReadBackReceiptEndpointResponseIntentInvalid
              (decodeEksDrainIntent intentBytes)
          let observedIdentity = eksDrainIntentAuthorityIdentity intent
          if observedIdentity == expectedIdentity
            then Right ()
            else
              Left
                ( EksDrainReadBackReceiptEndpointResponseIdentityMismatch
                    expectedIdentity
                    observedIdentity
                )
          case maybeExpected of
            Just expected
              | committedEksDrainIntent expected /= intent ->
                  Left EksDrainReadBackReceiptEndpointResponseExpectedIntentMismatch
            _ -> Right ()
          committed <-
            first
              EksDrainReadBackReceiptEndpointResponseIntentInvalid
              ( confirmEksDrainIntentCommitted
                  intent
                  (EksDrainIntentReadBackPresent intentBytes)
              )
          receipt <-
            first
              EksDrainReadBackReceiptEndpointResponseReceiptInvalid
              (recoverCommittedEksDrainReadBackReceipt committed receiptBytes)
          let actualReceiptDigest =
                eksDrainReadBackReceiptDigestText
                  (committedEksDrainReadBackReceiptDigest receipt)
              actualEvidenceDigest =
                eksDrainReadBackEvidenceDigestText
                  (committedEksDrainReadBackReceiptEvidenceDigest receipt)
          if storedReceiptDigest == actualReceiptDigest
            then Right ()
            else
              Left
                ( EksDrainReadBackReceiptEndpointResponseReceiptDigestMismatch
                    storedReceiptDigest
                    actualReceiptDigest
                )
          if storedEvidenceDigest == actualEvidenceDigest
            then Right receipt
            else
              Left
                ( EksDrainReadBackReceiptEndpointResponseEvidenceDigestMismatch
                    storedEvidenceDigest
                    actualEvidenceDigest
                )
 where
  versionMismatch observed =
    Left
      ( EksDrainReadBackReceiptEndpointResponseVersionMismatch
          eksDrainReadBackReceiptEndpointFormatVersion
          observed
      )
