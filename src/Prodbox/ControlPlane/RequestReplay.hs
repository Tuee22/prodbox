{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained, bounded replay authority for authenticated control-plane
-- requests.  Reservation is committed under an exact object revision before an
-- effect may run.  Completed duplicates recover the recorded response; a nonce
-- collision with different authenticated bytes is a conflict; and every
-- unreadable, saturated, or ambiguous repository outcome fails closed.
module Prodbox.ControlPlane.RequestReplay
  ( -- * Validated limits and identities
    RequestReplayLimits
  , RequestReplayLimitsError (..)
  , mkRequestReplayLimits
  , requestReplayCapacity
  , requestReplayMaximumResponseBytes
  , requestReplayClockSkew
  , ReplayAttemptId
  , ReplayAttemptIdError (..)
  , mkReplayAttemptId
  , replayAttemptIdBytes
  , ReplayCasAttempts
  , ReplayCasAttemptsError (..)
  , mkReplayCasAttempts

    -- * Response and projection
  , ReplayResponse
  , ReplayResponseError (..)
  , mkReplayResponse
  , mkReplayResponseFromStoredCode
  , replayResponseStatus
  , replayResponseBody
  , RequestReplayProjection
  , initialRequestReplayProjection
  , requestReplayProjectionLimits
  , requestReplayEntryCount
  , compactRequestReplayProjection

    -- * Pure reserve / complete folds
  , ReplayReservationDecision (..)
  , ReplayReservationResult (..)
  , reserveVerifiedRequest
  , ReplayCompletionDecision (..)
  , ReplayCompletionResult (..)
  , completeVerifiedRequest

    -- * Canonical retained codec
  , RequestReplayCodecError (..)
  , encodeRequestReplayProjection
  , decodeRequestReplayProjection
  , requestReplayCodec

    -- * Exact-revision repository
  , RequestReplaySnapshot (..)
  , RequestReplayRepository (..)
  , RequestReplayRepositoryFailure (..)
  , RequestReplayCasResult (..)
  , modelBRequestReplayRepository

    -- * Durable interpreter
  , DurableReplayReservation (..)
  , reserveVerifiedRequestDurably
  , DurableReplayCompletion (..)
  , completeVerifiedRequestDurably
  , ReplayProtectedResult (..)
  , runReplayProtectedRequest
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
  , callerPrincipalCode
  , callerPrincipalFromCode
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , CoordinateError
  , authorityScopeText
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestNonceError
  , SigningKeyGeneration
  , SigningKeyGenerationError
  , VerifiedControlPlaneRequest
  , mkRequestNonce
  , mkSigningKeyGeneration
  , requestNonceBytes
  , signingKeyGenerationValue
  , verifiedRequestAuthorityEpoch
  , verifiedRequestAuthorityScope
  , verifiedRequestCallerPrincipal
  , verifiedRequestDeadline
  , verifiedRequestDigestBytes
  , verifiedRequestNonce
  , verifiedRequestSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus
  , replyStatusCode
  , replyStatusFromCode
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , addAuthorityDuration
  , authorityDurationMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  )

hardMaximumReplayCapacity :: Natural
hardMaximumReplayCapacity = 65536

hardMaximumReplayResponseBytes :: Int
hardMaximumReplayResponseBytes = 100 * 1024 * 1024

data RequestReplayLimits = RequestReplayLimits
  { requestReplayCapacity :: !Natural
  , requestReplayMaximumResponseBytes :: !Int
  , requestReplayClockSkew :: !AuthorityDuration
  }
  deriving stock (Eq, Show)

data RequestReplayLimitsError
  = RequestReplayCapacityMustBePositive
  | RequestReplayCapacityExceedsHardMaximum !Natural !Natural
  | RequestReplayResponseMaximumMustBePositive
  | RequestReplayResponseMaximumExceedsHardMaximum !Int !Int
  deriving stock (Eq, Show)

mkRequestReplayLimits
  :: Natural
  -> Int
  -> AuthorityDuration
  -> Either RequestReplayLimitsError RequestReplayLimits
mkRequestReplayLimits capacity maximumResponseBytes clockSkew
  | capacity == 0 = Left RequestReplayCapacityMustBePositive
  | capacity > hardMaximumReplayCapacity =
      Left
        ( RequestReplayCapacityExceedsHardMaximum
            capacity
            hardMaximumReplayCapacity
        )
  | maximumResponseBytes <= 0 = Left RequestReplayResponseMaximumMustBePositive
  | maximumResponseBytes > hardMaximumReplayResponseBytes =
      Left
        ( RequestReplayResponseMaximumExceedsHardMaximum
            maximumResponseBytes
            hardMaximumReplayResponseBytes
        )
  | otherwise =
      Right
        RequestReplayLimits
          { requestReplayCapacity = capacity
          , requestReplayMaximumResponseBytes = maximumResponseBytes
          , requestReplayClockSkew = clockSkew
          }

newtype ReplayAttemptId = ReplayAttemptId ByteString
  deriving stock (Eq, Ord, Show)

data ReplayAttemptIdError
  = ReplayAttemptIdTooShort !Int !Int
  | ReplayAttemptIdTooLong !Int !Int
  deriving stock (Eq, Show)

mkReplayAttemptId :: ByteString -> Either ReplayAttemptIdError ReplayAttemptId
mkReplayAttemptId bytes
  | observed < minimumBytes = Left (ReplayAttemptIdTooShort observed minimumBytes)
  | observed > maximumBytes = Left (ReplayAttemptIdTooLong observed maximumBytes)
  | otherwise = Right (ReplayAttemptId bytes)
 where
  observed = ByteString.length bytes
  minimumBytes = 16
  maximumBytes = 64

replayAttemptIdBytes :: ReplayAttemptId -> ByteString
replayAttemptIdBytes (ReplayAttemptId bytes) = bytes

newtype ReplayCasAttempts = ReplayCasAttempts Natural
  deriving stock (Eq, Ord, Show)

data ReplayCasAttemptsError
  = ReplayCasAttemptsMustBePositive
  | ReplayCasAttemptsExceedHardMaximum !Natural !Natural
  deriving stock (Eq, Show)

mkReplayCasAttempts :: Natural -> Either ReplayCasAttemptsError ReplayCasAttempts
mkReplayCasAttempts attempts
  | attempts == 0 = Left ReplayCasAttemptsMustBePositive
  | attempts > hardMaximum =
      Left (ReplayCasAttemptsExceedHardMaximum attempts hardMaximum)
  | otherwise = Right (ReplayCasAttempts attempts)
 where
  hardMaximum = 100

-- | A recorded reply, retained so a repeated request is answered with the
-- response the first attempt produced rather than re-executed.
--
-- Sprint 4.67: the status is a 'ReplyStatus'. It used to be an @Int@ admitted
-- by a @100 <= status <= 599@ range test, which accepted every code the
-- repository does not define — including the four Sprint 4.66 found reaching
-- the wire with no reason phrase.
data ReplayResponse = ReplayResponse
  { replayResponseStatus :: !ReplyStatus
  , replayResponseBody :: !ByteString
  }
  deriving stock (Eq, Show)

data ReplayResponseError
  = -- | A stored code with no constructor in the closed set. Only the durable
    -- decoder can produce this; a live producer cannot express it.
    ReplayResponseStatusInvalid !Int
  | ReplayResponseBodyTooLarge !Int !Int
  deriving stock (Eq, Show)

mkReplayResponse
  :: RequestReplayLimits -> ReplyStatus -> ByteString -> Either ReplayResponseError ReplayResponse
mkReplayResponse limits status body =
  if bodyBytes <= maximumBodyBytes
    then Right ReplayResponse {replayResponseStatus = status, replayResponseBody = body}
    else Left (ReplayResponseBodyTooLarge bodyBytes maximumBodyBytes)
 where
  bodyBytes = ByteString.length body
  maximumBodyBytes = requestReplayMaximumResponseBytes limits

-- | Admit a status recorded by an __earlier revision__ of this process.
--
-- The durable projection stores the numeric code, so the format is unchanged by
-- Sprint 4.67 and a projection written before it still decodes. This is the one
-- crossing where a raw code becomes a 'ReplyStatus', and it is a refusal rather
-- than a widening: a stored code the closed set does not define is a decode
-- failure, not a value that flows on to the renderer
-- ([chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md)).
mkReplayResponseFromStoredCode
  :: RequestReplayLimits -> Int -> ByteString -> Either ReplayResponseError ReplayResponse
mkReplayResponseFromStoredCode limits code body =
  case replyStatusFromCode code of
    Nothing -> Left (ReplayResponseStatusInvalid code)
    Just status -> mkReplayResponse limits status body

newtype ReplayRequestDigest = ReplayRequestDigest ByteString
  deriving stock (Eq, Ord, Show)

mkReplayRequestDigest :: ByteString -> Maybe ReplayRequestDigest
mkReplayRequestDigest bytes
  | ByteString.length bytes == 32 = Just (ReplayRequestDigest bytes)
  | otherwise = Nothing

replayRequestDigestBytes :: ReplayRequestDigest -> ByteString
replayRequestDigestBytes (ReplayRequestDigest bytes) = bytes

data RequestReplayKey = RequestReplayKey
  { replayKeyAuthorityScope :: !AuthorityScope
  , replayKeyAuthorityEpoch :: !AuthorityEpoch
  , replayKeyCallerPrincipal :: !CallerPrincipal
  , replayKeySigningKeyGeneration :: !SigningKeyGeneration
  , replayKeyNonce :: !RequestNonce
  }
  deriving stock (Eq, Ord, Show)

data ReplayEntry
  = ReplayReservedEntry
      !ReplayRequestDigest
      !AuthorityTime
      !ReplayAttemptId
  | ReplayCompletedEntry
      !ReplayRequestDigest
      !AuthorityTime
      !ReplayResponse
  | ReplayTombstonedEntry
      !ReplayRequestDigest
      !AuthorityTime
  deriving stock (Eq, Show)

data RequestReplayProjection = RequestReplayProjection
  { internalReplayLimits :: !RequestReplayLimits
  , internalReplayEntries :: !(Map RequestReplayKey ReplayEntry)
  }
  deriving stock (Eq, Show)

initialRequestReplayProjection :: RequestReplayLimits -> RequestReplayProjection
initialRequestReplayProjection limits =
  RequestReplayProjection
    { internalReplayLimits = limits
    , internalReplayEntries = Map.empty
    }

requestReplayProjectionLimits :: RequestReplayProjection -> RequestReplayLimits
requestReplayProjectionLimits = internalReplayLimits

requestReplayEntryCount :: RequestReplayProjection -> Natural
requestReplayEntryCount = fromIntegral . Map.size . internalReplayEntries

requestReplayKey :: VerifiedControlPlaneRequest -> RequestReplayKey
requestReplayKey verified =
  RequestReplayKey
    { replayKeyAuthorityScope = verifiedRequestAuthorityScope verified
    , replayKeyAuthorityEpoch = verifiedRequestAuthorityEpoch verified
    , replayKeyCallerPrincipal = verifiedRequestCallerPrincipal verified
    , replayKeySigningKeyGeneration = verifiedRequestSigningKeyGeneration verified
    , replayKeyNonce = verifiedRequestNonce verified
    }

verifiedReplayDigest :: VerifiedControlPlaneRequest -> ReplayRequestDigest
verifiedReplayDigest = ReplayRequestDigest . verifiedRequestDigestBytes

-- | Expire active entries into digest-only tombstones and remove a tombstone
-- only at or after @deadline + configured clock skew@.  All entries count toward
-- capacity until that retention horizon, so saturation never guesses absence.
compactRequestReplayProjection
  :: AuthorityTime -> RequestReplayProjection -> RequestReplayProjection
compactRequestReplayProjection now projection =
  projection
    { internalReplayEntries = Map.mapMaybe compactEntry (internalReplayEntries projection)
    }
 where
  skew = requestReplayClockSkew (internalReplayLimits projection)
  compactEntry entry = case entry of
    ReplayReservedEntry digest deadline attempt ->
      compactActive digest deadline (ReplayReservedEntry digest deadline attempt)
    ReplayCompletedEntry digest deadline response ->
      compactActive digest deadline (ReplayCompletedEntry digest deadline response)
    ReplayTombstonedEntry digest retainUntil
      | now >= retainUntil -> Nothing
      | otherwise -> Just (ReplayTombstonedEntry digest retainUntil)
  compactActive digest deadline active
    | now >= retainUntil = Nothing
    | now >= deadline = Just (ReplayTombstonedEntry digest retainUntil)
    | otherwise = Just active
   where
    retainUntil = addAuthorityDuration deadline skew

data ReplayReservationDecision
  = ReplayReservationFresh
  | ReplayReservationOwned
  | ReplayReservationDuplicateInFlight
  | ReplayReservationDuplicateCompleted !ReplayResponse
  | ReplayReservationDuplicateTombstoned
  | ReplayReservationDigestConflict
  | ReplayReservationRequestExpired
  | ReplayReservationCapacityExhausted
  deriving stock (Eq, Show)

data ReplayReservationResult = ReplayReservationResult
  { replayReservationDecision :: !ReplayReservationDecision
  , replayReservationProjection :: !RequestReplayProjection
  }
  deriving stock (Eq, Show)

-- | Pure reserve decision.  Clock compaction and a fresh reservation are one
-- next projection, so the exact-revision repository commits both atomically.
reserveVerifiedRequest
  :: AuthorityTime
  -> ReplayAttemptId
  -> VerifiedControlPlaneRequest
  -> RequestReplayProjection
  -> ReplayReservationResult
reserveVerifiedRequest now attempt verified projection =
  case Map.lookup key entries of
    Just entry -> ReplayReservationResult (classifyExisting entry) compacted
    Nothing
      | deadline <= now ->
          ReplayReservationResult ReplayReservationRequestExpired compacted
      | fromIntegral (Map.size entries) >= requestReplayCapacity limits ->
          ReplayReservationResult ReplayReservationCapacityExhausted compacted
      | otherwise ->
          ReplayReservationResult
            ReplayReservationFresh
            compacted
              { internalReplayEntries =
                  Map.insert key (ReplayReservedEntry digest deadline attempt) entries
              }
 where
  compacted = compactRequestReplayProjection now projection
  entries = internalReplayEntries compacted
  limits = internalReplayLimits compacted
  key = requestReplayKey verified
  digest = verifiedReplayDigest verified
  deadline = verifiedRequestDeadline verified
  classifyExisting entry = case entry of
    ReplayReservedEntry observed _ owner
      | observed /= digest -> ReplayReservationDigestConflict
      | owner == attempt -> ReplayReservationOwned
      | otherwise -> ReplayReservationDuplicateInFlight
    ReplayCompletedEntry observed _ response
      | observed /= digest -> ReplayReservationDigestConflict
      | otherwise -> ReplayReservationDuplicateCompleted response
    ReplayTombstonedEntry observed _
      | observed /= digest -> ReplayReservationDigestConflict
      | otherwise -> ReplayReservationDuplicateTombstoned

data ReplayCompletionDecision
  = ReplayCompletionRecorded !ReplayResponse
  | ReplayCompletionDuplicate !ReplayResponse
  | ReplayCompletionReservationMissing
  | ReplayCompletionOwnerMismatch
  | ReplayCompletionDigestConflict
  | ReplayCompletionResponseConflict
  | ReplayCompletionTombstoned
  | ReplayCompletionResponseInvalid !ReplayResponseError
  deriving stock (Eq, Show)

data ReplayCompletionResult = ReplayCompletionResult
  { replayCompletionDecision :: !ReplayCompletionDecision
  , replayCompletionProjection :: !RequestReplayProjection
  }
  deriving stock (Eq, Show)

completeVerifiedRequest
  :: ReplayAttemptId
  -> VerifiedControlPlaneRequest
  -> ReplayResponse
  -> RequestReplayProjection
  -> ReplayCompletionResult
completeVerifiedRequest attempt verified response projection =
  case validateReplayResponse limits response of
    Left err -> ReplayCompletionResult (ReplayCompletionResponseInvalid err) projection
    Right () -> case Map.lookup key entries of
      Nothing -> ReplayCompletionResult ReplayCompletionReservationMissing projection
      Just entry -> case entry of
        ReplayReservedEntry observed deadline owner
          | observed /= digest ->
              ReplayCompletionResult ReplayCompletionDigestConflict projection
          | owner /= attempt ->
              ReplayCompletionResult ReplayCompletionOwnerMismatch projection
          | otherwise ->
              ReplayCompletionResult
                (ReplayCompletionRecorded response)
                projection
                  { internalReplayEntries =
                      Map.insert key (ReplayCompletedEntry digest deadline response) entries
                  }
        ReplayCompletedEntry observed _ recorded
          | observed /= digest ->
              ReplayCompletionResult ReplayCompletionDigestConflict projection
          | recorded == response ->
              ReplayCompletionResult (ReplayCompletionDuplicate recorded) projection
          | otherwise ->
              ReplayCompletionResult ReplayCompletionResponseConflict projection
        ReplayTombstonedEntry observed _
          | observed /= digest ->
              ReplayCompletionResult ReplayCompletionDigestConflict projection
          | otherwise -> ReplayCompletionResult ReplayCompletionTombstoned projection
 where
  limits = internalReplayLimits projection
  entries = internalReplayEntries projection
  key = requestReplayKey verified
  digest = verifiedReplayDigest verified

validateReplayResponse
  :: RequestReplayLimits -> ReplayResponse -> Either ReplayResponseError ()
validateReplayResponse limits response =
  case mkReplayResponse limits (replayResponseStatus response) (replayResponseBody response) of
    Left err -> Left err
    Right _ -> Right ()

data RequestReplayCodecError
  = RequestReplayEnvelopeTooLarge !Int !Int
  | RequestReplayEnvelopeInvalid
  | RequestReplayEnvelopeUnsupportedVersion !Word16
  | RequestReplayEnvelopeNonCanonical
  | RequestReplayLimitsMismatch
  | RequestReplayEntriesOverCapacity !Natural !Natural
  | RequestReplayDuplicateKey
  | RequestReplayScopeInvalid !CoordinateError
  | RequestReplayEpochInvalid
  | RequestReplayCallerPrincipalInvalid !Word
  | RequestReplaySigningGenerationInvalid !SigningKeyGenerationError
  | RequestReplayNonceInvalid !RequestNonceError
  | RequestReplayDigestWidthInvalid !Int !Int
  | RequestReplayAttemptInvalid !ReplayAttemptIdError
  | RequestReplayResponseInvalid !ReplayResponseError
  deriving stock (Eq, Show)

data RequestReplayEnvelope = RequestReplayEnvelope
  { replayEnvelopeVersion :: !Word16
  , replayEnvelopeCapacity :: !Natural
  , replayEnvelopeMaximumResponseBytes :: !Int
  , replayEnvelopeClockSkewMicros :: !Natural
  , replayEnvelopeEntries :: ![RequestReplayEntryWire]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RequestReplayEntryWire = RequestReplayEntryWire
  { replayEntryScope :: !Text
  , replayEntryEpoch :: !Natural
  , replayEntryCallerPrincipal :: !Word
  , replayEntrySigningGeneration :: !Natural
  , replayEntryNonce :: !ByteString
  , replayEntryValue :: !RequestReplayValueWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RequestReplayValueWire
  = RequestReplayReservedWire !ByteString !Natural !ByteString
  | RequestReplayCompletedWire !ByteString !Natural !Int !ByteString
  | RequestReplayTombstonedWire !ByteString !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

requestReplayCodecVersion :: Word16
requestReplayCodecVersion = 8

legacyRequestReplayCodecVersions :: [Word16]
legacyRequestReplayCodecVersions = [2, 3, 4, 5, 6, 7]

encodeRequestReplayProjection
  :: Int
  -> RequestReplayLimits
  -> RequestReplayProjection
  -> Either RequestReplayCodecError ByteString
encodeRequestReplayProjection maximumBytes expectedLimits projection = do
  validateReplayProjection expectedLimits projection
  let bytes =
        LazyByteString.toStrict
          ( serialise
              RequestReplayEnvelope
                { replayEnvelopeVersion = requestReplayCodecVersion
                , replayEnvelopeCapacity = requestReplayCapacity expectedLimits
                , replayEnvelopeMaximumResponseBytes =
                    requestReplayMaximumResponseBytes expectedLimits
                , replayEnvelopeClockSkewMicros =
                    authorityDurationMicros (requestReplayClockSkew expectedLimits)
                , replayEnvelopeEntries =
                    fmap entryToWire (Map.toAscList (internalReplayEntries projection))
                }
          )
  if maximumBytes < 0 || ByteString.length bytes > maximumBytes
    then Left (RequestReplayEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
    else Right bytes

decodeRequestReplayProjection
  :: Int
  -> RequestReplayLimits
  -> ByteString
  -> Either RequestReplayCodecError RequestReplayProjection
decodeRequestReplayProjection maximumBytes expectedLimits bytes
  | maximumBytes < 0 || ByteString.length bytes > maximumBytes =
      Left (RequestReplayEnvelopeTooLarge (ByteString.length bytes) maximumBytes)
  | otherwise = do
      envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left RequestReplayEnvelopeInvalid
        Right decoded -> Right decoded
      if replayEnvelopeVersion envelope
        `elem` (requestReplayCodecVersion : legacyRequestReplayCodecVersions)
        then pure ()
        else Left (RequestReplayEnvelopeUnsupportedVersion (replayEnvelopeVersion envelope))
      if envelopeLimitsCompatible expectedLimits envelope
        then pure ()
        else Left RequestReplayLimitsMismatch
      decodedEntries <- traverse (entryFromWire expectedLimits) (replayEnvelopeEntries envelope)
      let entries = Map.fromList decodedEntries
      if Map.size entries == length decodedEntries
        then pure ()
        else Left RequestReplayDuplicateKey
      let projection =
            RequestReplayProjection
              { internalReplayLimits = expectedLimits
              , internalReplayEntries = entries
              }
      validateReplayProjection expectedLimits projection
      if LazyByteString.toStrict (serialise envelope) == bytes
        then Right projection
        else Left RequestReplayEnvelopeNonCanonical

requestReplayCodec
  :: Int -> RequestReplayLimits -> ModelBCodec RequestReplayProjection
requestReplayCodec maximumBytes expectedLimits =
  ModelBCodec
    { encodeModelBValue =
        either (Left . show) Right
          . encodeRequestReplayProjection maximumBytes expectedLimits
    , decodeModelBValue =
        either (Left . show) Right
          . decodeRequestReplayProjection maximumBytes expectedLimits
    }

validateReplayProjection
  :: RequestReplayLimits
  -> RequestReplayProjection
  -> Either RequestReplayCodecError ()
validateReplayProjection expectedLimits projection
  | internalReplayLimits projection /= expectedLimits = Left RequestReplayLimitsMismatch
  | entryCount > requestReplayCapacity expectedLimits =
      Left
        ( RequestReplayEntriesOverCapacity
            entryCount
            (requestReplayCapacity expectedLimits)
        )
  | otherwise =
      traverse_ validateEntry (Map.elems (internalReplayEntries projection))
 where
  entryCount = requestReplayEntryCount projection
  validateEntry entry = case entry of
    ReplayReservedEntry {} -> Right ()
    ReplayCompletedEntry _ _ response ->
      either
        (Left . RequestReplayResponseInvalid)
        Right
        (validateReplayResponse expectedLimits response)
    ReplayTombstonedEntry _ _ -> Right ()

envelopeLimitsCompatible :: RequestReplayLimits -> RequestReplayEnvelope -> Bool
envelopeLimitsCompatible limits envelope =
  capacityCompatible
    && replayEnvelopeMaximumResponseBytes envelope
      == requestReplayMaximumResponseBytes limits
    && replayEnvelopeClockSkewMicros envelope
      == authorityDurationMicros (requestReplayClockSkew limits)
 where
  capacityCompatible = case replayEnvelopeVersion envelope of
    version
      | version == requestReplayCodecVersion ->
          replayEnvelopeCapacity envelope == requestReplayCapacity limits
      | version `elem` legacyRequestReplayCodecVersions ->
          replayEnvelopeCapacity envelope <= requestReplayCapacity limits
      | otherwise -> False

entryToWire :: (RequestReplayKey, ReplayEntry) -> RequestReplayEntryWire
entryToWire (key, value) =
  RequestReplayEntryWire
    { replayEntryScope = authorityScopeText (replayKeyAuthorityScope key)
    , replayEntryEpoch = authorityEpochValue (replayKeyAuthorityEpoch key)
    , replayEntryCallerPrincipal =
        callerPrincipalCode (replayKeyCallerPrincipal key)
    , replayEntrySigningGeneration =
        signingKeyGenerationValue (replayKeySigningKeyGeneration key)
    , replayEntryNonce = requestNonceBytes (replayKeyNonce key)
    , replayEntryValue = valueToWire value
    }

valueToWire :: ReplayEntry -> RequestReplayValueWire
valueToWire entry = case entry of
  ReplayReservedEntry digest deadline attempt ->
    RequestReplayReservedWire
      (replayRequestDigestBytes digest)
      (authorityTimeMicros deadline)
      (replayAttemptIdBytes attempt)
  ReplayCompletedEntry digest deadline response ->
    RequestReplayCompletedWire
      (replayRequestDigestBytes digest)
      (authorityTimeMicros deadline)
      (replyStatusCode (replayResponseStatus response))
      (replayResponseBody response)
  ReplayTombstonedEntry digest retainUntil ->
    RequestReplayTombstonedWire
      (replayRequestDigestBytes digest)
      (authorityTimeMicros retainUntil)

entryFromWire
  :: RequestReplayLimits
  -> RequestReplayEntryWire
  -> Either RequestReplayCodecError (RequestReplayKey, ReplayEntry)
entryFromWire limits wire = do
  scope <-
    either
      (Left . RequestReplayScopeInvalid)
      Right
      (mkAuthorityScope (replayEntryScope wire))
  epoch <-
    maybe
      (Left RequestReplayEpochInvalid)
      Right
      (authorityEpochFromValue (replayEntryEpoch wire))
  caller <-
    maybe
      ( Left
          ( RequestReplayCallerPrincipalInvalid
              (replayEntryCallerPrincipal wire)
          )
      )
      Right
      (callerPrincipalFromCode (replayEntryCallerPrincipal wire))
  generation <-
    either
      (Left . RequestReplaySigningGenerationInvalid)
      Right
      (mkSigningKeyGeneration (replayEntrySigningGeneration wire))
  nonce <-
    either
      (Left . RequestReplayNonceInvalid)
      Right
      (mkRequestNonce (replayEntryNonce wire))
  value <- valueFromWire limits (replayEntryValue wire)
  pure
    ( RequestReplayKey
        { replayKeyAuthorityScope = scope
        , replayKeyAuthorityEpoch = epoch
        , replayKeyCallerPrincipal = caller
        , replayKeySigningKeyGeneration = generation
        , replayKeyNonce = nonce
        }
    , value
    )

valueFromWire
  :: RequestReplayLimits
  -> RequestReplayValueWire
  -> Either RequestReplayCodecError ReplayEntry
valueFromWire limits wire = case wire of
  RequestReplayReservedWire rawDigest deadlineMicros rawAttempt -> do
    digest <- decodeDigest rawDigest
    attempt <-
      either
        (Left . RequestReplayAttemptInvalid)
        Right
        (mkReplayAttemptId rawAttempt)
    pure (ReplayReservedEntry digest (authorityTimeFromMicros deadlineMicros) attempt)
  RequestReplayCompletedWire rawDigest deadlineMicros status body -> do
    digest <- decodeDigest rawDigest
    response <-
      either
        (Left . RequestReplayResponseInvalid)
        Right
        (mkReplayResponseFromStoredCode limits status body)
    pure (ReplayCompletedEntry digest (authorityTimeFromMicros deadlineMicros) response)
  RequestReplayTombstonedWire rawDigest retainUntilMicros -> do
    digest <- decodeDigest rawDigest
    pure (ReplayTombstonedEntry digest (authorityTimeFromMicros retainUntilMicros))
 where
  decodeDigest bytes =
    maybe
      (Left (RequestReplayDigestWidthInvalid (ByteString.length bytes) 32))
      Right
      (mkReplayRequestDigest bytes)

data RequestReplaySnapshot revision = RequestReplaySnapshot
  { requestReplayRevision :: !revision
  , requestReplaySnapshotProjection :: !RequestReplayProjection
  }
  deriving stock (Eq, Show)

data RequestReplayRepositoryFailure
  = RequestReplayRepositoryCorrupt !Text
  | RequestReplayRepositoryEndpointUnready !Text
  | RequestReplayRepositoryUnobservable !Text
  deriving stock (Eq, Show)

data RequestReplayCasResult
  = RequestReplayCasApplied
  | RequestReplayCasConflict
  | RequestReplayCasUnobservable !RequestReplayRepositoryFailure
  deriving stock (Eq, Show)

data RequestReplayRepository m revision = RequestReplayRepository
  { readRequestReplayProjection
      :: m (Either RequestReplayRepositoryFailure (RequestReplaySnapshot revision))
  , compareAndSwapRequestReplayProjection
      :: revision
      -> RequestReplayProjection
      -> m RequestReplayCasResult
  }

modelBRequestReplayRepository
  :: (Monad m)
  => RequestReplayProjection
  -> ModelBCasAdapter 'ClusterRetained m RequestReplayProjection
  -> ModelBObjectCoordinate 'ClusterRetained
  -> RequestReplayRepository m (Maybe ModelBObjectVersion)
modelBRequestReplayRepository initialProjection adapter coordinate =
  RequestReplayRepository
    { readRequestReplayProjection = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right
              RequestReplaySnapshot
                { requestReplayRevision = Nothing
                , requestReplaySnapshotProjection = initialProjection
                }
          ModelBObserved revision projection ->
            Right
              RequestReplaySnapshot
                { requestReplayRevision = Just revision
                , requestReplaySnapshotProjection = projection
                }
          ModelBCorrupt detail ->
            Left (RequestReplayRepositoryCorrupt detail)
          ModelBEndpointUnready detail ->
            Left (RequestReplayRepositoryEndpointUnready detail)
          ModelBUnobservable detail ->
            Left (RequestReplayRepositoryUnobservable detail)
    , compareAndSwapRequestReplayProjection = \expected projection -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate projection
            Just revision -> ModelBReplace coordinate revision projection
        pure $ case result of
          ModelBCasApplied _ _ -> RequestReplayCasApplied
          ModelBCasConflict _ -> RequestReplayCasConflict
          ModelBCasRefusedCorrupt detail ->
            RequestReplayCasUnobservable (RequestReplayRepositoryCorrupt detail)
          ModelBCasEndpointUnready detail ->
            RequestReplayCasUnobservable
              (RequestReplayRepositoryEndpointUnready detail)
          ModelBCasUnobservable detail ->
            RequestReplayCasUnobservable
              (RequestReplayRepositoryUnobservable detail)
    }

data DurableReplayReservation
  = DurableReplayReservationAcquired
  | DurableReplayReservationRecovered !ReplayResponse
  | DurableReplayReservationInFlight
  | DurableReplayReservationTombstoned
  | DurableReplayReservationDigestConflict
  | DurableReplayReservationExpired
  | DurableReplayReservationCapacityExhausted
  | DurableReplayReservationUnavailable !RequestReplayRepositoryFailure
  | DurableReplayReservationAttemptsExhausted
  deriving stock (Eq, Show)

reserveVerifiedRequestDurably
  :: (Monad m)
  => ReplayCasAttempts
  -> RequestReplayRepository m revision
  -> AuthorityTime
  -> ReplayAttemptId
  -> VerifiedControlPlaneRequest
  -> m DurableReplayReservation
reserveVerifiedRequestDurably (ReplayCasAttempts maximumAttempts) repository now attempt verified =
  go maximumAttempts
 where
  go attemptsRemaining
    | attemptsRemaining == 0 = pure DurableReplayReservationAttemptsExhausted
    | otherwise = do
        observed <- readRequestReplayProjection repository
        case observed of
          Left failure -> pure (DurableReplayReservationUnavailable failure)
          Right snapshot -> do
            let observedProjection = requestReplaySnapshotProjection snapshot
            let result =
                  reserveVerifiedRequest
                    now
                    attempt
                    verified
                    observedProjection
            if replayReservationProjection result == observedProjection
              then
                pure
                  ( durableReservationFromDecision
                      (replayReservationDecision result)
                  )
              else do
                _ <-
                  compareAndSwapRequestReplayProjection
                    repository
                    (requestReplayRevision snapshot)
                    (replayReservationProjection result)
                confirmOrRetry (attemptsRemaining - 1)
  confirmOrRetry attemptsRemaining = do
    readback <- readRequestReplayProjection repository
    case readback of
      Left failure -> pure (DurableReplayReservationUnavailable failure)
      Right snapshot ->
        case replayReservationDecision
          ( reserveVerifiedRequest
              now
              attempt
              verified
              (requestReplaySnapshotProjection snapshot)
          ) of
          ReplayReservationFresh -> go attemptsRemaining
          decision -> pure (durableReservationFromDecision decision)

durableReservationFromDecision
  :: ReplayReservationDecision -> DurableReplayReservation
durableReservationFromDecision decision = case decision of
  ReplayReservationFresh -> DurableReplayReservationAttemptsExhausted
  ReplayReservationOwned -> DurableReplayReservationAcquired
  ReplayReservationDuplicateInFlight -> DurableReplayReservationInFlight
  ReplayReservationDuplicateCompleted response ->
    DurableReplayReservationRecovered response
  ReplayReservationDuplicateTombstoned -> DurableReplayReservationTombstoned
  ReplayReservationDigestConflict -> DurableReplayReservationDigestConflict
  ReplayReservationRequestExpired -> DurableReplayReservationExpired
  ReplayReservationCapacityExhausted -> DurableReplayReservationCapacityExhausted

data DurableReplayCompletion
  = DurableReplayCompletionConfirmed !ReplayResponse
  | DurableReplayCompletionReservationMissing
  | DurableReplayCompletionOwnerMismatch
  | DurableReplayCompletionDigestConflict
  | DurableReplayCompletionResponseConflict
  | DurableReplayCompletionTombstoned
  | DurableReplayCompletionResponseInvalid !ReplayResponseError
  | DurableReplayCompletionUnavailable !RequestReplayRepositoryFailure
  | DurableReplayCompletionAttemptsExhausted
  deriving stock (Eq, Show)

completeVerifiedRequestDurably
  :: (Monad m)
  => ReplayCasAttempts
  -> RequestReplayRepository m revision
  -> ReplayAttemptId
  -> VerifiedControlPlaneRequest
  -> ReplayResponse
  -> m DurableReplayCompletion
completeVerifiedRequestDurably (ReplayCasAttempts maximumAttempts) repository attempt verified response =
  go maximumAttempts
 where
  go attemptsRemaining
    | attemptsRemaining == 0 = pure DurableReplayCompletionAttemptsExhausted
    | otherwise = do
        observed <- readRequestReplayProjection repository
        case observed of
          Left failure -> pure (DurableReplayCompletionUnavailable failure)
          Right snapshot -> do
            let result =
                  completeVerifiedRequest
                    attempt
                    verified
                    response
                    (requestReplaySnapshotProjection snapshot)
            case replayCompletionDecision result of
              ReplayCompletionRecorded _ -> do
                _ <-
                  compareAndSwapRequestReplayProjection
                    repository
                    (requestReplayRevision snapshot)
                    (replayCompletionProjection result)
                confirmOrRetry (attemptsRemaining - 1)
              decision -> pure (durableCompletionFromDecision decision)
  confirmOrRetry attemptsRemaining = do
    readback <- readRequestReplayProjection repository
    case readback of
      Left failure -> pure (DurableReplayCompletionUnavailable failure)
      Right snapshot ->
        case replayCompletionDecision
          ( completeVerifiedRequest
              attempt
              verified
              response
              (requestReplaySnapshotProjection snapshot)
          ) of
          ReplayCompletionRecorded _ -> go attemptsRemaining
          decision -> pure (durableCompletionFromDecision decision)

durableCompletionFromDecision
  :: ReplayCompletionDecision -> DurableReplayCompletion
durableCompletionFromDecision decision = case decision of
  ReplayCompletionRecorded response -> DurableReplayCompletionConfirmed response
  ReplayCompletionDuplicate response -> DurableReplayCompletionConfirmed response
  ReplayCompletionReservationMissing -> DurableReplayCompletionReservationMissing
  ReplayCompletionOwnerMismatch -> DurableReplayCompletionOwnerMismatch
  ReplayCompletionDigestConflict -> DurableReplayCompletionDigestConflict
  ReplayCompletionResponseConflict -> DurableReplayCompletionResponseConflict
  ReplayCompletionTombstoned -> DurableReplayCompletionTombstoned
  ReplayCompletionResponseInvalid err -> DurableReplayCompletionResponseInvalid err

data ReplayProtectedResult failure
  = ReplayProtectedExecuted !ReplayResponse
  | ReplayProtectedRecovered !ReplayResponse
  | ReplayProtectedInFlight
  | ReplayProtectedTombstoned
  | ReplayProtectedDigestConflict
  | ReplayProtectedExpired
  | ReplayProtectedCapacityExhausted
  | ReplayProtectedUnavailable !RequestReplayRepositoryFailure
  | ReplayProtectedAttemptsExhausted
  | ReplayProtectedEffectFailed !failure
  | ReplayProtectedCompletionUnconfirmed !DurableReplayCompletion
  deriving stock (Eq, Show)

-- | Reserve, confirm the exact owner by authoritative read-back, run the effect
-- only for that owner, then durably record/read back its response.  A duplicate
-- completed request returns the stored response without invoking the effect.
runReplayProtectedRequest
  :: (Monad m)
  => ReplayCasAttempts
  -> RequestReplayRepository m revision
  -> AuthorityTime
  -> ReplayAttemptId
  -> VerifiedControlPlaneRequest
  -> m (Either failure ReplayResponse)
  -> m (ReplayProtectedResult failure)
runReplayProtectedRequest attempts repository now attempt verified effect = do
  reservation <-
    reserveVerifiedRequestDurably attempts repository now attempt verified
  case reservation of
    DurableReplayReservationAcquired -> do
      effected <- effect
      case effected of
        Left failure -> pure (ReplayProtectedEffectFailed failure)
        Right response -> do
          completion <-
            completeVerifiedRequestDurably
              attempts
              repository
              attempt
              verified
              response
          pure $ case completion of
            DurableReplayCompletionConfirmed recorded -> ReplayProtectedExecuted recorded
            _ -> ReplayProtectedCompletionUnconfirmed completion
    DurableReplayReservationRecovered response -> pure (ReplayProtectedRecovered response)
    DurableReplayReservationInFlight -> pure ReplayProtectedInFlight
    DurableReplayReservationTombstoned -> pure ReplayProtectedTombstoned
    DurableReplayReservationDigestConflict -> pure ReplayProtectedDigestConflict
    DurableReplayReservationExpired -> pure ReplayProtectedExpired
    DurableReplayReservationCapacityExhausted -> pure ReplayProtectedCapacityExhausted
    DurableReplayReservationUnavailable failure -> pure (ReplayProtectedUnavailable failure)
    DurableReplayReservationAttemptsExhausted -> pure ReplayProtectedAttemptsExhausted
