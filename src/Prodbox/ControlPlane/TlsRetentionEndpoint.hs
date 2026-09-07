{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed ciphertext-envelope protocol served by the TLS Retention Adapter.
-- Certificate/key plaintext never crosses this boundary.  The Adapter stores
-- only the selected Agent's certificate ciphertext plus the retained-home
-- Transit-wrapped DEK, under the exact configured scope prefix and immutable
-- retention version, then reads the bytes back before returning a receipt.
module Prodbox.ControlPlane.TlsRetentionEndpoint
  ( TlsSealedEnvelope
  , TlsStorePayload (..)
  , TlsRestorePayload (..)
  , TlsObserveVersionPayload (..)
  , TlsRetentionReceipt (..)
  , TlsEnvelopeObservation (..)
  , TlsVersionEnvelopeObservation (..)
  , TlsStorePutDisposition (..)
  , TlsStoreConfirmationFailure (..)
  , TlsStoreRepositoryFailure (..)
  , TlsRestoreRepositoryFailure (..)
  , allTlsStoreRepositoryFailures
  , allTlsRestoreRepositoryFailures
  , renderTlsStoreRepositoryFailure
  , renderTlsRestoreRepositoryFailure
  , TlsRetentionRepository (..)
  , TlsStoreResult (..)
  , TlsRestoreResult (..)
  , TlsObserveVersionResult (..)
  , TlsRetentionPlainResponseCause (..)
  , TlsRetentionPlainResponseObservation (..)
  , allTlsRetentionPlainResponseCauses
  , tlsRetentionPlainResponse
  , classifyTlsRetentionPlainResponse
  , renderTlsRetentionPlainResponseCause
  , tlsMaximumCertificateCiphertextBytes
  , tlsMaximumWrappedDekBytes
  , mkTlsSealedEnvelope
  , tlsCertificateCiphertextBytes
  , tlsWrappedDekBytes
  , tlsSealedEnvelopeDigest
  , validateTlsSealedEnvelope
  , serveTlsStoreRequest
  , serveTlsRestoreRequest
  , serveTlsObserveVersionRequest
  , tlsStoreHttpStatus
  , tlsStoreSummary
  , tlsRestoreHttpStatus
  , tlsRestoreSummary
  , tlsStoreResponseBody
  , tlsRestoreResponseBody
  , tlsObserveVersionHttpStatus
  , tlsObserveVersionSummary
  , tlsObserveVersionResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.TlsRetention
  ( RetainedTlsRef (..)
  , RetentionVersion
  , TlsSealedEnvelope
  , mkTlsSealedEnvelope
  , tlsCertificateCiphertextBytes
  , tlsMaximumCertificateCiphertextBytes
  , tlsMaximumWrappedDekBytes
  , tlsSealedEnvelopeDigest
  , tlsWrappedDekBytes
  , validateTlsSealedEnvelope
  )

data TlsStorePayload = TlsStorePayload
  { tlsStoreCandidate :: !RetainedTlsRef
  , tlsStoreEnvelope :: !TlsSealedEnvelope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TlsRestorePayload = TlsRestorePayload
  { tlsRestoreReference :: RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TlsObserveVersionPayload = TlsObserveVersionPayload
  { tlsObserveVersion :: RetentionVersion
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsRetentionReceipt = TlsRetentionReceipt
  { tlsRetentionReceiptReference :: !RetainedTlsRef
  , tlsRetentionReceiptEnvelopeDigest :: !Text
  , tlsRetentionReceiptObjectVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsEnvelopeObservation
  = TlsEnvelopeMissing
  | TlsEnvelopePresent !TlsSealedEnvelope !TlsRetentionReceipt
  | TlsEnvelopeCorrupt !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Exact-key observation used only to recover a pre-outbox immutable object.
-- It deliberately carries no candidate reference: the Authority must prove the
-- certificate/source AAD before it may adopt the observed envelope.
data TlsVersionEnvelopeObservation
  = TlsVersionEnvelopeMissing
  | TlsVersionEnvelopePresent !TlsSealedEnvelope !Text
  | TlsVersionEnvelopeCorrupt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | What the immutable PUT boundary established before the mandatory
-- confirmation read-back.  An unobservable reply deliberately does not claim
-- absence: the write may have landed before the response was lost.
data TlsStorePutDisposition
  = TlsStorePutUnobservable
  | TlsStorePutApplied
  | TlsStorePutConflict
  deriving stock (Bounded, Enum, Eq, Show)

-- | Closed, payload-free failure classes for the authoritative confirmation
-- read-back.  Transport bodies, object bytes, and decoder details cannot enter
-- an endpoint response through this type.
data TlsStoreConfirmationFailure
  = TlsStoreConfirmationUnobservable
  | TlsStoreConfirmationMissing
  | TlsStoreConfirmationBytesMismatch
  | TlsStoreConfirmationEnvelopeInvalid
  | TlsStoreConfirmationEnvelopeMismatch
  | TlsStoreConfirmationDigestMismatch
  deriving stock (Bounded, Enum, Eq, Show)

-- | Closed repository-side store failure.  The PUT disposition is retained
-- for every confirmation failure so an applied-response loss remains distinct
-- from an observed conflict and an ordinary applied reply.
data TlsStoreRepositoryFailure
  = TlsStoreRepositoryEnvelopeInvalid
  | TlsStoreRepositoryDigestMismatch
  | TlsStoreRepositoryObjectNameInvalid
  | TlsStoreRepositoryEncodedEnvelopeTooLarge
  | TlsStoreRepositoryConfirmationFailed
      !TlsStorePutDisposition
      !TlsStoreConfirmationFailure
  deriving stock (Eq, Show)

-- | Closed repository-side restore refusal.  Corrupt but readable bytes are a
-- successful 'TlsEnvelopeCorrupt' observation, not a transport failure.
data TlsRestoreRepositoryFailure
  = TlsRestoreRepositoryObjectNameInvalid
  | TlsRestoreRepositoryObservationUnobservable
  deriving stock (Bounded, Enum, Eq, Show)

allTlsStoreRepositoryFailures :: [TlsStoreRepositoryFailure]
allTlsStoreRepositoryFailures =
  [ TlsStoreRepositoryEnvelopeInvalid
  , TlsStoreRepositoryDigestMismatch
  , TlsStoreRepositoryObjectNameInvalid
  , TlsStoreRepositoryEncodedEnvelopeTooLarge
  ]
    <> [ TlsStoreRepositoryConfirmationFailed putDisposition confirmationFailure
       | putDisposition <- [minBound .. maxBound]
       , confirmationFailure <- [minBound .. maxBound]
       ]

allTlsRestoreRepositoryFailures :: [TlsRestoreRepositoryFailure]
allTlsRestoreRepositoryFailures = [minBound .. maxBound]

renderTlsStoreRepositoryFailure :: TlsStoreRepositoryFailure -> Text
renderTlsStoreRepositoryFailure failure = case failure of
  TlsStoreRepositoryEnvelopeInvalid -> "precondition/envelope-invalid"
  TlsStoreRepositoryDigestMismatch -> "precondition/digest-mismatch"
  TlsStoreRepositoryObjectNameInvalid -> "object-name-invalid"
  TlsStoreRepositoryEncodedEnvelopeTooLarge -> "encoded-envelope-too-large"
  TlsStoreRepositoryConfirmationFailed putDisposition confirmationFailure ->
    "put/"
      <> renderPutDisposition putDisposition
      <> "/confirmation/"
      <> renderConfirmationFailure confirmationFailure
 where
  renderPutDisposition disposition = case disposition of
    TlsStorePutUnobservable -> "unobservable"
    TlsStorePutApplied -> "applied"
    TlsStorePutConflict -> "conflict"

  renderConfirmationFailure confirmationFailure = case confirmationFailure of
    TlsStoreConfirmationUnobservable -> "unobservable"
    TlsStoreConfirmationMissing -> "missing"
    TlsStoreConfirmationBytesMismatch -> "bytes-mismatch"
    TlsStoreConfirmationEnvelopeInvalid -> "envelope-invalid"
    TlsStoreConfirmationEnvelopeMismatch -> "envelope-mismatch"
    TlsStoreConfirmationDigestMismatch -> "digest-mismatch"

renderTlsRestoreRepositoryFailure :: TlsRestoreRepositoryFailure -> Text
renderTlsRestoreRepositoryFailure failure = case failure of
  TlsRestoreRepositoryObjectNameInvalid -> "object-name-invalid"
  TlsRestoreRepositoryObservationUnobservable -> "observation-unobservable"

data TlsRetentionRepository m = TlsRetentionRepository
  { storeTlsEnvelope
      :: RetainedTlsRef
      -> TlsSealedEnvelope
      -> m (Either TlsStoreRepositoryFailure TlsRetentionReceipt)
  , restoreTlsEnvelope
      :: RetainedTlsRef
      -> m (Either TlsRestoreRepositoryFailure TlsEnvelopeObservation)
  , observeTlsEnvelopeVersion
      :: RetentionVersion
      -> m (Either TlsRestoreRepositoryFailure TlsVersionEnvelopeObservation)
  }

data TlsStoreResult
  = TlsStoreSucceeded !TlsRetentionReceipt
  | TlsStoreFailed !TlsStoreRepositoryFailure
  | TlsStoreBadRequest !ControlPlaneRequestCodecError
  | TlsStoreInvalidEnvelope
  | TlsStoreDigestMismatch
  deriving stock (Eq, Show)

data TlsRestoreResult
  = TlsRestoreObserved !TlsEnvelopeObservation
  | TlsRestoreReadFailed !TlsRestoreRepositoryFailure
  | TlsRestoreBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsObserveVersionResult
  = TlsObserveVersionObserved !TlsVersionEnvelopeObservation
  | TlsObserveVersionReadFailed !TlsRestoreRepositoryFailure
  | TlsObserveVersionBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

-- | Every plaintext failure response authored by the TLS Retention endpoint.
-- Successful, missing, and corrupt observations use the canonical response
-- codec instead; repository details never enter this closed projection.
data TlsRetentionPlainResponseCause
  = TlsRetentionStoreRepositoryFailed !TlsStoreRepositoryFailure
  | TlsRetentionStoreRequestRefused !ControlPlaneRequestCodecError
  | TlsRetentionStoreEnvelopeInvalid
  | TlsRetentionStoreDigestMismatch
  | TlsRetentionRestoreRepositoryReadFailed !TlsRestoreRepositoryFailure
  | TlsRetentionRestoreRequestRefused !ControlPlaneRequestCodecError
  | TlsRetentionObserveVersionRepositoryReadFailed !TlsRestoreRepositoryFailure
  | TlsRetentionObserveVersionRequestRefused !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

data TlsRetentionPlainResponseObservation
  = TlsRetentionPlainResponseKnown !TlsRetentionPlainResponseCause
  | TlsRetentionPlainResponseOther
  deriving stock (Eq, Show)

allTlsRetentionPlainResponseCauses :: [TlsRetentionPlainResponseCause]
allTlsRetentionPlainResponseCauses =
  (TlsRetentionStoreRepositoryFailed <$> allTlsStoreRepositoryFailures)
    <> (TlsRetentionStoreRequestRefused <$> allCodecErrors)
    <> [ TlsRetentionStoreEnvelopeInvalid
       , TlsRetentionStoreDigestMismatch
       ]
    <> (TlsRetentionRestoreRepositoryReadFailed <$> allTlsRestoreRepositoryFailures)
    <> (TlsRetentionRestoreRequestRefused <$> allCodecErrors)
    <> (TlsRetentionObserveVersionRepositoryReadFailed <$> allTlsRestoreRepositoryFailures)
    <> (TlsRetentionObserveVersionRequestRefused <$> allCodecErrors)
 where
  allCodecErrors = [minBound .. maxBound]

-- | The single source of truth for the endpoint's plaintext response pairs.
tlsRetentionPlainResponse
  :: TlsRetentionPlainResponseCause -> (ReplyStatus, ByteString)
tlsRetentionPlainResponse cause = case cause of
  TlsRetentionStoreRepositoryFailed failure ->
    ( ReplyServiceUnavailable
    , TextEncoding.encodeUtf8
        ("tls-store:failed/" <> renderTlsStoreRepositoryFailure failure)
    )
  TlsRetentionStoreRequestRefused err ->
    ( ReplyBadRequest
    , TextEncoding.encodeUtf8
        ("tls-store:bad-request:" <> controlPlaneRequestCodecToken err)
    )
  TlsRetentionStoreEnvelopeInvalid ->
    (ReplyBadRequest, "tls-store:invalid-envelope")
  TlsRetentionStoreDigestMismatch ->
    (ReplyConflict, "tls-store:digest-mismatch")
  TlsRetentionRestoreRepositoryReadFailed failure ->
    ( ReplyServiceUnavailable
    , TextEncoding.encodeUtf8
        ("tls-restore:read-failed/" <> renderTlsRestoreRepositoryFailure failure)
    )
  TlsRetentionRestoreRequestRefused err ->
    ( ReplyBadRequest
    , TextEncoding.encodeUtf8
        ("tls-restore:bad-request:" <> controlPlaneRequestCodecToken err)
    )
  TlsRetentionObserveVersionRepositoryReadFailed failure ->
    ( ReplyServiceUnavailable
    , TextEncoding.encodeUtf8
        ("tls-observe-version:read-failed/" <> renderTlsRestoreRepositoryFailure failure)
    )
  TlsRetentionObserveVersionRequestRefused err ->
    ( ReplyBadRequest
    , TextEncoding.encodeUtf8
        ("tls-observe-version:bad-request:" <> controlPlaneRequestCodecToken err)
    )

classifyTlsRetentionPlainResponse
  :: Int -> ByteString -> TlsRetentionPlainResponseObservation
classifyTlsRetentionPlainResponse status body =
  maybe
    TlsRetentionPlainResponseOther
    TlsRetentionPlainResponseKnown
    (find matches allTlsRetentionPlainResponseCauses)
 where
  matches cause =
    let (authoredStatus, authoredBody) = tlsRetentionPlainResponse cause
     in replyStatusCode authoredStatus == status && authoredBody == body

renderTlsRetentionPlainResponseCause :: TlsRetentionPlainResponseCause -> Text
renderTlsRetentionPlainResponseCause cause = case cause of
  TlsRetentionStoreRepositoryFailed failure ->
    "store/repository-failed/" <> renderTlsStoreRepositoryFailure failure
  TlsRetentionStoreRequestRefused err ->
    "store/request-refused/" <> controlPlaneRequestCodecToken err
  TlsRetentionStoreEnvelopeInvalid -> "store/envelope-invalid"
  TlsRetentionStoreDigestMismatch -> "store/digest-mismatch"
  TlsRetentionRestoreRepositoryReadFailed failure ->
    "restore/read-failed/" <> renderTlsRestoreRepositoryFailure failure
  TlsRetentionRestoreRequestRefused err ->
    "restore/request-refused/" <> controlPlaneRequestCodecToken err
  TlsRetentionObserveVersionRepositoryReadFailed failure ->
    "observe-version/read-failed/" <> renderTlsRestoreRepositoryFailure failure
  TlsRetentionObserveVersionRequestRefused err ->
    "observe-version/request-refused/" <> controlPlaneRequestCodecToken err

serveTlsStoreRequest
  :: (Monad m)
  => Int
  -> TlsRetentionRepository m
  -> LazyByteString.ByteString
  -> m TlsStoreResult
serveTlsStoreRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsStoreBadRequest err)
    Right payload ->
      case validateTlsSealedEnvelope (tlsStoreEnvelope payload) of
        Left _ -> pure TlsStoreInvalidEnvelope
        Right ()
          | retainedCiphertextDigest (tlsStoreCandidate payload)
              /= tlsSealedEnvelopeDigest (tlsStoreEnvelope payload) ->
              pure TlsStoreDigestMismatch
          | otherwise -> do
              stored <-
                storeTlsEnvelope
                  repository
                  (tlsStoreCandidate payload)
                  (tlsStoreEnvelope payload)
              pure $ case stored of
                Left failure -> TlsStoreFailed failure
                Right receipt -> TlsStoreSucceeded receipt

serveTlsRestoreRequest
  :: (Monad m)
  => Int
  -> TlsRetentionRepository m
  -> LazyByteString.ByteString
  -> m TlsRestoreResult
serveTlsRestoreRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsRestoreBadRequest err)
    Right payload -> do
      observed <- restoreTlsEnvelope repository (tlsRestoreReference payload)
      pure $ case observed of
        Left failure -> TlsRestoreReadFailed failure
        Right observation -> TlsRestoreObserved observation

serveTlsObserveVersionRequest
  :: (Monad m)
  => Int
  -> TlsRetentionRepository m
  -> LazyByteString.ByteString
  -> m TlsObserveVersionResult
serveTlsObserveVersionRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (TlsObserveVersionBadRequest err)
    Right payload -> do
      observed <- observeTlsEnvelopeVersion repository (tlsObserveVersion payload)
      pure $ case observed of
        Left failure -> TlsObserveVersionReadFailed failure
        Right observation -> TlsObserveVersionObserved observation

tlsStoreHttpStatus :: TlsStoreResult -> ReplyStatus
tlsStoreHttpStatus result = case result of
  TlsStoreSucceeded _ -> ReplyOk
  TlsStoreFailed failure ->
    plainStatus (TlsRetentionStoreRepositoryFailed failure)
  TlsStoreBadRequest err -> plainStatus (TlsRetentionStoreRequestRefused err)
  TlsStoreInvalidEnvelope -> plainStatus TlsRetentionStoreEnvelopeInvalid
  TlsStoreDigestMismatch -> plainStatus TlsRetentionStoreDigestMismatch

tlsStoreSummary :: TlsStoreResult -> Text
tlsStoreSummary result = case result of
  TlsStoreSucceeded _ -> "tls-store:read-back-confirmed"
  TlsStoreFailed failure ->
    plainSummary (TlsRetentionStoreRepositoryFailed failure)
  TlsStoreBadRequest err -> plainSummary (TlsRetentionStoreRequestRefused err)
  TlsStoreInvalidEnvelope -> plainSummary TlsRetentionStoreEnvelopeInvalid
  TlsStoreDigestMismatch -> plainSummary TlsRetentionStoreDigestMismatch

tlsRestoreHttpStatus :: TlsRestoreResult -> ReplyStatus
tlsRestoreHttpStatus result = case result of
  TlsRestoreObserved TlsEnvelopeMissing -> ReplyNotFound
  TlsRestoreObserved (TlsEnvelopePresent _ _) -> ReplyOk
  TlsRestoreObserved (TlsEnvelopeCorrupt _) -> ReplyInternalError
  TlsRestoreReadFailed failure ->
    plainStatus (TlsRetentionRestoreRepositoryReadFailed failure)
  TlsRestoreBadRequest err -> plainStatus (TlsRetentionRestoreRequestRefused err)

tlsRestoreSummary :: TlsRestoreResult -> Text
tlsRestoreSummary result = case result of
  TlsRestoreObserved TlsEnvelopeMissing -> "tls-restore:missing"
  TlsRestoreObserved (TlsEnvelopePresent _ _) -> "tls-restore:present"
  TlsRestoreObserved (TlsEnvelopeCorrupt _) -> "tls-restore:corrupt"
  TlsRestoreReadFailed failure ->
    plainSummary (TlsRetentionRestoreRepositoryReadFailed failure)
  TlsRestoreBadRequest err -> plainSummary (TlsRetentionRestoreRequestRefused err)

tlsStoreResponseBody :: TlsStoreResult -> ByteString
tlsStoreResponseBody result = case result of
  TlsStoreSucceeded receipt ->
    LazyByteString.toStrict (encodeControlPlaneResponse receipt)
  TlsStoreFailed failure ->
    plainBody (TlsRetentionStoreRepositoryFailed failure)
  TlsStoreBadRequest err -> plainBody (TlsRetentionStoreRequestRefused err)
  TlsStoreInvalidEnvelope -> plainBody TlsRetentionStoreEnvelopeInvalid
  TlsStoreDigestMismatch -> plainBody TlsRetentionStoreDigestMismatch

tlsRestoreResponseBody :: TlsRestoreResult -> ByteString
tlsRestoreResponseBody result = case result of
  TlsRestoreObserved observation ->
    LazyByteString.toStrict (encodeControlPlaneResponse observation)
  TlsRestoreReadFailed failure ->
    plainBody (TlsRetentionRestoreRepositoryReadFailed failure)
  TlsRestoreBadRequest err -> plainBody (TlsRetentionRestoreRequestRefused err)

tlsObserveVersionHttpStatus :: TlsObserveVersionResult -> ReplyStatus
tlsObserveVersionHttpStatus result = case result of
  TlsObserveVersionObserved TlsVersionEnvelopeMissing -> ReplyNotFound
  TlsObserveVersionObserved (TlsVersionEnvelopePresent _ _) -> ReplyOk
  TlsObserveVersionObserved TlsVersionEnvelopeCorrupt -> ReplyInternalError
  TlsObserveVersionReadFailed failure ->
    plainStatus (TlsRetentionObserveVersionRepositoryReadFailed failure)
  TlsObserveVersionBadRequest err ->
    plainStatus (TlsRetentionObserveVersionRequestRefused err)

tlsObserveVersionSummary :: TlsObserveVersionResult -> Text
tlsObserveVersionSummary result = case result of
  TlsObserveVersionObserved TlsVersionEnvelopeMissing ->
    "tls-observe-version:missing"
  TlsObserveVersionObserved (TlsVersionEnvelopePresent _ _) ->
    "tls-observe-version:present"
  TlsObserveVersionObserved TlsVersionEnvelopeCorrupt ->
    "tls-observe-version:corrupt"
  TlsObserveVersionReadFailed failure ->
    plainSummary (TlsRetentionObserveVersionRepositoryReadFailed failure)
  TlsObserveVersionBadRequest err ->
    plainSummary (TlsRetentionObserveVersionRequestRefused err)

tlsObserveVersionResponseBody :: TlsObserveVersionResult -> ByteString
tlsObserveVersionResponseBody result = case result of
  TlsObserveVersionObserved observation ->
    LazyByteString.toStrict (encodeControlPlaneResponse observation)
  TlsObserveVersionReadFailed failure ->
    plainBody (TlsRetentionObserveVersionRepositoryReadFailed failure)
  TlsObserveVersionBadRequest err ->
    plainBody (TlsRetentionObserveVersionRequestRefused err)

plainStatus :: TlsRetentionPlainResponseCause -> ReplyStatus
plainStatus = fst . tlsRetentionPlainResponse

plainBody :: TlsRetentionPlainResponseCause -> ByteString
plainBody = snd . tlsRetentionPlainResponse

plainSummary :: TlsRetentionPlainResponseCause -> Text
plainSummary = TextEncoding.decodeUtf8 . plainBody
