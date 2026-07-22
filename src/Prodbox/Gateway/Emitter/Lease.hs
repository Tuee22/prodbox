{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes-Lease fencing for one emitter-journal incarnation. Acquisition
-- distinguishes create, same-holder renewal, expired-holder takeover, and a
-- live competing holder. A mutation is read back before an opaque,
-- monotonic-expiry witness is returned.
module Prodbox.Gateway.Emitter.Lease
  ( LeaseName
  , mkLeaseName
  , leaseNameText
  , LeaseDuration
  , mkLeaseDuration
  , leaseDurationSeconds
  , LeaseBinding
  , mkLeaseBinding
  , leaseBindingHolderIdentity
  , LeaseRecord (..)
  , LeaseObservation (..)
  , LeaseMutationResult (..)
  , LeaseDecision (..)
  , decideLease
  , EmitterLeaseClient (..)
  , EmitterLeaseRuntime (..)
  , LeaseWitness
  , leaseWitnessBinding
  , leaseWitnessName
  , leaseWitnessDuration
  , leaseWitnessDeadline
  , leaseWitnessResourceVersion
  , leaseWitnessCurrent
  , acquireEmitterLease
  , renewEmitterLease
  , LeaseError (..)
  , renderLeaseError
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineExpired
  )

newtype LeaseName = LeaseName Text
  deriving stock (Eq, Ord, Show)

mkLeaseName :: Text -> Either LeaseError LeaseName
mkLeaseName raw =
  -- Kubernetes DNS labels are case-insensitive coordinates at this boundary.
  -- Strip surrounding whitespace and lowercase once, then retain only this
  -- canonical spelling in records, witnesses, and rendered API paths.
  let name = Text.toLower (Text.strip raw)
      validChar value = isAsciiLower value || isDigit value || value == '-'
      alphaNumeric value = isAsciiLower value || isDigit value
   in if Text.null name
        then Left (LeaseInputInvalid "lease name must not be empty")
        else
          if Text.length name > 63
            then Left (LeaseInputInvalid "lease name exceeds the DNS-label bound")
            else
              if not (Text.all validChar name && alphaNumeric (Text.head name) && alphaNumeric (Text.last name))
                then Left (LeaseInputInvalid "lease name must be a lowercase DNS label")
                else Right (LeaseName name)

leaseNameText :: LeaseName -> Text
leaseNameText (LeaseName value) = value

newtype LeaseDuration = LeaseDuration Natural
  deriving stock (Eq, Ord, Show)

mkLeaseDuration :: Natural -> Either LeaseError LeaseDuration
mkLeaseDuration seconds
  | seconds == 0 = Left (LeaseInputInvalid "lease duration must be positive")
  | seconds > fromIntegral (maxBound :: Int) = Left (LeaseInputInvalid "lease duration is too large")
  | otherwise = Right (LeaseDuration seconds)

leaseDurationSeconds :: LeaseDuration -> Natural
leaseDurationSeconds (LeaseDuration seconds) = seconds

data LeaseBinding = LeaseBinding
  { bindingEmitter :: !Text
  , bindingIncarnation :: !Word64
  , bindingJournalDigest :: !ByteString
  , bindingIdentityDigest :: !ByteString
  , internalHolderIdentity :: !Text
  }
  deriving stock (Eq, Show)

mkLeaseBinding
  :: Text
  -> Word64
  -> ByteString
  -> ByteString
  -> Either LeaseError LeaseBinding
mkLeaseBinding rawEmitter incarnation journalDigest identityDigest = do
  let emitter = Text.strip rawEmitter
  if Text.null emitter
    then Left (LeaseInputInvalid "emitter must not be empty")
    else Right ()
  if BS.length (TextEncoding.encodeUtf8 emitter) > 255
    then Left (LeaseInputInvalid "emitter exceeds the 255-byte bound")
    else Right ()
  if Text.any (== '\NUL') emitter
    then Left (LeaseInputInvalid "emitter must not contain NUL")
    else Right ()
  if incarnation == 0
    then Left (LeaseInputInvalid "incarnation must be positive")
    else Right ()
  requireDigest "journal" journalDigest
  requireDigest "identity" identityDigest
  let bindingBytes =
        BL.toStrict . Builder.toLazyByteString $
          "prodbox.gateway.emitter-lease.binding.v1"
            <> frame (TextEncoding.encodeUtf8 emitter)
            <> Builder.word64BE incarnation
            <> frame journalDigest
            <> frame identityDigest
      holder = "prodbox-v1-" <> hexText (SHA256.hash bindingBytes)
  Right
    LeaseBinding
      { bindingEmitter = emitter
      , bindingIncarnation = incarnation
      , bindingJournalDigest = journalDigest
      , bindingIdentityDigest = identityDigest
      , internalHolderIdentity = holder
      }
 where
  requireDigest label bytes
    | BS.length bytes == 32 = Right ()
    | otherwise = Left (LeaseInputInvalid (label ++ " digest must be exactly 32 bytes"))
  frame bytes = Builder.word64BE (fromIntegral (BS.length bytes)) <> Builder.byteString bytes

hexText :: ByteString -> Text
hexText =
  TextEncoding.decodeUtf8
    . BL.toStrict
    . Builder.toLazyByteString
    . foldMap Builder.word8HexFixed
    . BS.unpack

leaseBindingHolderIdentity :: LeaseBinding -> Text
leaseBindingHolderIdentity = internalHolderIdentity

data LeaseRecord = LeaseRecord
  { leaseRecordName :: !LeaseName
  , leaseRecordResourceVersion :: !Text
  , leaseRecordHolderIdentity :: !Text
  , leaseRecordDuration :: !LeaseDuration
  , leaseRecordAcquireTime :: !UTCTime
  , leaseRecordRenewTime :: !UTCTime
  , leaseRecordTransitions :: !Natural
  }
  deriving stock (Eq, Show)

data LeaseObservation
  = LeaseMissing
  | LeaseObserved !LeaseRecord
  | LeaseUnobservable !Text
  deriving stock (Eq, Show)

data LeaseMutationResult
  = LeaseMutationApplied !LeaseRecord
  | LeaseMutationConflict
  | LeaseMutationUnobservable !Text
  deriving stock (Eq, Show)

data LeaseDecision
  = LeaseCreate
  | LeaseRenew !LeaseRecord
  | LeaseTakeOver !LeaseRecord
  | LeaseRefuseLiveHolder !LeaseRecord
  | LeaseRefuseUnobservable !Text
  deriving stock (Eq, Show)

decideLease :: UTCTime -> LeaseBinding -> LeaseObservation -> LeaseDecision
decideLease now binding observation = case observation of
  LeaseMissing -> LeaseCreate
  LeaseUnobservable detail -> LeaseRefuseUnobservable detail
  LeaseObserved record
    | leaseRecordHolderIdentity record == leaseBindingHolderIdentity binding -> LeaseRenew record
    | leaseRecordExpiredAt now record -> LeaseTakeOver record
    | otherwise -> LeaseRefuseLiveHolder record

leaseRecordExpiredAt :: UTCTime -> LeaseRecord -> Bool
leaseRecordExpiredAt now record =
  now >= addUTCTime (durationNominal (leaseRecordDuration record)) (leaseRecordRenewTime record)

durationNominal :: LeaseDuration -> NominalDiffTime
durationNominal = fromIntegral . leaseDurationSeconds

data EmitterLeaseClient = EmitterLeaseClient
  { leaseClientObserve :: Deadline -> LeaseName -> IO LeaseObservation
  , leaseClientCreate :: Deadline -> LeaseRecord -> IO LeaseMutationResult
  , leaseClientReplace :: Deadline -> LeaseRecord -> IO LeaseMutationResult
  }

data EmitterLeaseRuntime = EmitterLeaseRuntime
  { leaseRuntimeClient :: !EmitterLeaseClient
  , leaseRuntimeWallNow :: IO UTCTime
  , leaseRuntimeMonotonicNow :: IO MonotonicInstant
  }

data LeaseWitness = LeaseWitness
  { leaseWitnessBinding :: !LeaseBinding
  , leaseWitnessName :: !LeaseName
  , leaseWitnessDuration :: !LeaseDuration
  , leaseWitnessDeadline :: !Deadline
  , leaseWitnessResourceVersion :: !Text
  }
  deriving stock (Eq, Show)

leaseWitnessCurrent
  :: MonotonicInstant
  -> LeaseName
  -> LeaseDuration
  -> LeaseBinding
  -> LeaseWitness
  -> Bool
leaseWitnessCurrent now name duration binding witness =
  leaseWitnessBinding witness == binding
    && leaseWitnessName witness == name
    && leaseWitnessDuration witness == duration
    && not (deadlineExpired now (leaseWitnessDeadline witness))

acquireEmitterLease
  :: EmitterLeaseRuntime
  -> Deadline
  -> LeaseName
  -> LeaseDuration
  -> LeaseBinding
  -> IO (Either LeaseError LeaseWitness)
acquireEmitterLease runtime callerDeadline name duration binding = do
  beforeObserve <- leaseRuntimeMonotonicNow runtime
  if deadlineExpired beforeObserve callerDeadline
    then pure (Left LeaseDeadlineExpired)
    else do
      observation <- leaseClientObserve client callerDeadline name
      afterObserve <- leaseRuntimeMonotonicNow runtime
      if deadlineExpired afterObserve callerDeadline
        then pure (Left LeaseDeadlineExpired)
        else do
          wallNow <- leaseRuntimeWallNow runtime
          case observation of
            LeaseObserved record
              | leaseRecordName record /= name ->
                  pure (Left LeaseObservationCoordinateMismatch)
            _ -> continueAcquire wallNow observation
 where
  client = leaseRuntimeClient runtime

  continueAcquire wallNow observation =
    case decideLease wallNow binding observation of
      LeaseRefuseUnobservable detail -> pure (Left (LeaseObservationFailed detail))
      LeaseRefuseLiveHolder record ->
        pure (Left (LeaseHeldByOther (leaseRecordHolderIdentity record)))
      decision -> do
        beforeMutation <- leaseRuntimeMonotonicNow runtime
        if deadlineExpired beforeMutation callerDeadline
          then pure (Left LeaseDeadlineExpired)
          else do
            let desired = desiredRecord wallNow name duration binding decision
            mutation <- case decision of
              LeaseCreate -> leaseClientCreate client callerDeadline desired
              LeaseRenew _ -> leaseClientReplace client callerDeadline desired
              LeaseTakeOver _ -> leaseClientReplace client callerDeadline desired
            afterMutation <- leaseRuntimeMonotonicNow runtime
            if deadlineExpired afterMutation callerDeadline
              then pure (Left LeaseDeadlineExpired)
              else case mutation of
                LeaseMutationConflict -> pure (Left LeaseMutationConflictFailure)
                LeaseMutationUnobservable detail -> pure (Left (LeaseMutationFailed detail))
                LeaseMutationApplied _ -> readBack desired

  readBack desired = do
    beforeReadBack <- leaseRuntimeMonotonicNow runtime
    if deadlineExpired beforeReadBack callerDeadline
      then pure (Left LeaseDeadlineExpired)
      else do
        observed <- leaseClientObserve client callerDeadline name
        -- Convert the authority wall-clock expiry into the local monotonic
        -- clock conservatively.  The wall read occurs after
        -- @monotonicBeforeWall@ and before @monotonicAfterWall@, so anchoring
        -- the remaining duration at the earlier sample cannot extend the
        -- Lease by the time spent sampling the clocks.
        monotonicBeforeWall <- leaseRuntimeMonotonicNow runtime
        readBackWall <- leaseRuntimeWallNow runtime
        monotonicAfterWall <- leaseRuntimeMonotonicNow runtime
        pure $ do
          if deadlineExpired monotonicAfterWall callerDeadline
            then Left LeaseDeadlineExpired
            else Right ()
          applied <- case observed of
            LeaseObserved value -> Right value
            LeaseMissing -> Left LeaseReadBackMissing
            LeaseUnobservable detail -> Left (LeaseReadBackFailed detail)
          if leaseRecordName applied /= name
            then Left LeaseReadBackMismatch
            else Right ()
          if leaseRecordHolderIdentity applied /= leaseRecordHolderIdentity desired
            then Left LeaseReadBackMismatch
            else Right ()
          if leaseRecordDuration applied /= leaseRecordDuration desired
            then Left LeaseReadBackMismatch
            else Right ()
          if Text.null (leaseRecordResourceVersion applied)
            then Left LeaseReadBackMismatch
            else Right ()
          if leaseRecordExpiredAt readBackWall applied
            then Left LeaseReadBackExpired
            else Right ()
          let authorityExpiry =
                addUTCTime
                  (durationNominal (leaseRecordDuration applied))
                  (leaseRecordRenewTime applied)
              remainingMicros :: Integer
              remainingMicros =
                floor (diffUTCTime authorityExpiry readBackWall * 1000000)
          if remainingMicros <= 0
            then Left LeaseReadBackExpired
            else Right ()
          let localExpiry =
                deadlineAtOffset
                  monotonicBeforeWall
                  (RemainingDuration (fromIntegral remainingMicros))
          if deadlineExpired monotonicAfterWall localExpiry
            then Left LeaseReadBackExpired
            else Right ()
          Right
            LeaseWitness
              { leaseWitnessBinding = binding
              , leaseWitnessName = name
              , leaseWitnessDuration = duration
              , -- The caller deadline bounds acquisition I/O only. Once exact
                -- read-back succeeds before that deadline, the witness carries
                -- the conservatively mapped authority expiry.
                leaseWitnessDeadline = localExpiry
              , leaseWitnessResourceVersion = leaseRecordResourceVersion applied
              }

renewEmitterLease
  :: EmitterLeaseRuntime
  -> Deadline
  -> LeaseName
  -> LeaseDuration
  -> LeaseWitness
  -> IO (Either LeaseError LeaseWitness)
renewEmitterLease runtime deadline name duration witness = do
  now <- leaseRuntimeMonotonicNow runtime
  if leaseWitnessCurrent
    now
    name
    duration
    (leaseWitnessBinding witness)
    witness
    then
      acquireEmitterLease runtime deadline name duration (leaseWitnessBinding witness)
    else
      if leaseWitnessName witness /= name || leaseWitnessDuration witness /= duration
        then pure (Left LeaseWitnessCoordinateMismatch)
        else pure (Left LeaseWitnessExpired)

desiredRecord
  :: UTCTime
  -> LeaseName
  -> LeaseDuration
  -> LeaseBinding
  -> LeaseDecision
  -> LeaseRecord
desiredRecord now name duration binding decision =
  let (resourceVersion, acquiredAt, transitions) = case decision of
        LeaseCreate -> (Text.empty, now, 0)
        LeaseRenew current ->
          ( leaseRecordResourceVersion current
          , leaseRecordAcquireTime current
          , leaseRecordTransitions current
          )
        LeaseTakeOver current ->
          ( leaseRecordResourceVersion current
          , now
          , leaseRecordTransitions current + 1
          )
        LeaseRefuseLiveHolder current ->
          ( leaseRecordResourceVersion current
          , leaseRecordAcquireTime current
          , leaseRecordTransitions current
          )
        LeaseRefuseUnobservable _ -> (Text.empty, now, 0)
   in LeaseRecord
        { leaseRecordName = name
        , leaseRecordResourceVersion = resourceVersion
        , leaseRecordHolderIdentity = leaseBindingHolderIdentity binding
        , leaseRecordDuration = duration
        , leaseRecordAcquireTime = acquiredAt
        , leaseRecordRenewTime = now
        , leaseRecordTransitions = transitions
        }

data LeaseError
  = LeaseInputInvalid !String
  | LeaseDeadlineExpired
  | LeaseObservationFailed !Text
  | LeaseObservationCoordinateMismatch
  | LeaseHeldByOther !Text
  | LeaseMutationConflictFailure
  | LeaseMutationFailed !Text
  | LeaseReadBackMissing
  | LeaseReadBackFailed !Text
  | LeaseReadBackMismatch
  | LeaseReadBackExpired
  | LeaseWitnessExpired
  | LeaseWitnessCoordinateMismatch
  deriving stock (Eq, Show)

renderLeaseError :: LeaseError -> String
renderLeaseError err = case err of
  LeaseInputInvalid detail -> "emitter lease input invalid: " ++ detail
  LeaseDeadlineExpired -> "emitter lease deadline expired"
  LeaseObservationFailed detail -> "emitter lease observation failed: " ++ Text.unpack detail
  LeaseObservationCoordinateMismatch -> "emitter lease observation used a different Lease coordinate"
  LeaseHeldByOther holder -> "emitter lease is held by another incarnation: " ++ Text.unpack holder
  LeaseMutationConflictFailure -> "emitter lease mutation conflicted"
  LeaseMutationFailed detail -> "emitter lease mutation failed: " ++ Text.unpack detail
  LeaseReadBackMissing -> "emitter lease disappeared during read-back"
  LeaseReadBackFailed detail -> "emitter lease read-back failed: " ++ Text.unpack detail
  LeaseReadBackMismatch -> "emitter lease read-back did not match the requested binding"
  LeaseReadBackExpired -> "emitter lease was already expired at read-back"
  LeaseWitnessExpired -> "emitter lease witness is expired"
  LeaseWitnessCoordinateMismatch -> "emitter lease witness name or duration does not match renewal"
