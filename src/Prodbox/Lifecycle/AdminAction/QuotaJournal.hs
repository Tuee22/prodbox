{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Persist-before-effect recovery journal for Service Quotas Admin Actions.
-- AWS offers no client token on @RequestServiceQuotaIncrease@.  The journal
-- therefore persists an exact attempt window before dispatch, then recovers a
-- lost response from current quota plus the complete paginated history for the
-- exact service/quota/desired tuple.  Two consecutive authoritative absence
-- scans are required before the one and only retry is armed.
module Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaHistoryObservation (..)
  , QuotaExternalObservation (..)
  , QuotaAttemptIntent (..)
  , QuotaJournalOutcome (..)
  , QuotaJournalState
  , QuotaJournalError (..)
  , initialQuotaJournal
  , advanceQuotaJournal
  , recordQuotaProviderResponse
  , quotaJournalReadBack
  , quotaJournalOperationIdValue
  , quotaJournalRequestInventory
  , quotaJournalStateCodec
  )
where

import Codec.Serialise (Serialise, serialise)
import Codec.Serialise qualified as Codec
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.Ord qualified
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminQuotaItemReadBack (..)
  , AdminQuotaRequest (..)
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeMicros
  )
import Text.Read (readMaybe)

data QuotaHistoryObservation = QuotaHistoryObservation
  { quotaHistoryServiceCode :: !Text
  , quotaHistoryQuotaCode :: !Text
  , quotaHistoryDesiredValue :: !Double
  , quotaHistoryProviderRequestIdentity :: !Text
  , quotaHistoryStatus :: !Text
  , quotaHistoryCreatedEpochSeconds :: !Double
  , quotaHistoryLastUpdatedEpochSeconds :: !Double
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaExternalObservation = QuotaExternalObservation
  { quotaExternalRequest :: !AdminQuotaRequest
  , quotaExternalCurrentValue :: !Double
  , quotaExternalHistory :: ![QuotaHistoryObservation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaAttemptIntent = QuotaAttemptIntent
  { quotaAttemptRequest :: !AdminQuotaRequest
  , quotaAttemptNumber :: !Natural
  , quotaAttemptIdentity :: !Text
  , quotaAttemptStartedMicros :: !Natural
  , quotaAttemptDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaJournalOutcome
  = QuotaJournalDispatch !QuotaAttemptIntent
  | QuotaJournalAwaitingHistory !QuotaAttemptIntent !Natural
  | QuotaJournalCompleted ![AdminQuotaItemReadBack]
  | QuotaJournalRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaJournalEntry
  = QuotaEntryPending !AdminQuotaRequest
  | QuotaEntryAttempting !QuotaAttemptIntent !Natural
  | QuotaEntryCompleted !AdminQuotaRequest !AdminQuotaItemReadBack
  | QuotaEntryRefused !AdminQuotaRequest !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaJournalState = QuotaJournalState
  { quotaJournalOperationId :: !Text
  , quotaJournalEntries :: ![QuotaJournalEntry]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data QuotaJournalError
  = QuotaJournalOperationInvalid
  | QuotaJournalRequestsInvalid
  | QuotaJournalDesiredValueInvalid !Text
  | QuotaJournalDeadlineExpired
  | QuotaJournalObservationMismatch
  | QuotaJournalAttemptMismatch
  | QuotaJournalProviderResponseInvalid
  | QuotaJournalWireInvalid !Text
  deriving stock (Eq, Show)

initialQuotaJournal
  :: Text
  -> [AdminQuotaRequest]
  -> Either QuotaJournalError QuotaJournalState
initialQuotaJournal operationId requests
  | Text.null (Text.strip operationId) || Text.length operationId > 128 =
      Left QuotaJournalOperationInvalid
  | null requests || length requests > 64 = Left QuotaJournalRequestsInvalid
  | otherwise = do
      traverse_ desiredValue requests
      pure
        QuotaJournalState
          { quotaJournalOperationId = operationId
          , quotaJournalEntries = fmap QuotaEntryPending requests
          }

advanceQuotaJournal
  :: AuthorityTime
  -> AuthorityTime
  -> [QuotaExternalObservation]
  -> QuotaJournalState
  -> Either QuotaJournalError (QuotaJournalState, QuotaJournalOutcome)
advanceQuotaJournal now deadline observations state
  | authorityTimeMicros now >= authorityTimeMicros deadline =
      Left QuotaJournalDeadlineExpired
  | otherwise = do
      validateObservationInventory observations (quotaJournalEntries state)
      advanceEntries [] (quotaJournalEntries state)
 where
  advanceEntries prefix entries = case entries of
    [] -> Right (state, QuotaJournalCompleted (completedItems prefix))
    completed@QuotaEntryCompleted {} : rest ->
      advanceEntries (prefix <> [completed]) rest
    QuotaEntryRefused _ detail : _ -> Right (state, QuotaJournalRefused detail)
    QuotaEntryPending request : rest -> do
      intent <- mkAttempt request 1 now deadline
      observation <- observationFor request observations
      desired <- desiredValue request
      case classifyObservation desired intent observation of
        Just item -> do
          let nextEntry = QuotaEntryCompleted request item
              nextState = state {quotaJournalEntries = prefix <> (nextEntry : rest)}
          continueCompleted nextState (prefix <> [nextEntry]) rest
        Nothing -> do
          let nextEntry = QuotaEntryAttempting intent 0
              nextState = state {quotaJournalEntries = prefix <> (nextEntry : rest)}
          Right (nextState, QuotaJournalDispatch intent)
    QuotaEntryAttempting intent absenceScans : rest -> do
      observation <- observationFor (quotaAttemptRequest intent) observations
      desired <- desiredValue (quotaAttemptRequest intent)
      case classifyObservation desired intent observation of
        Just item -> do
          let nextEntry = QuotaEntryCompleted (quotaAttemptRequest intent) item
              nextState = state {quotaJournalEntries = prefix <> (nextEntry : rest)}
          continueCompleted nextState (prefix <> [nextEntry]) rest
        Nothing
          | absenceScans + 1 < stableAbsenceScans ->
              let nextEntry = QuotaEntryAttempting intent (absenceScans + 1)
               in Right
                    ( state {quotaJournalEntries = prefix <> (nextEntry : rest)}
                    , QuotaJournalAwaitingHistory intent (absenceScans + 1)
                    )
          | quotaAttemptNumber intent < maximumAttempts -> do
              retry <- mkAttempt (quotaAttemptRequest intent) 2 now deadline
              let nextEntry = QuotaEntryAttempting retry 0
              Right
                ( state {quotaJournalEntries = prefix <> (nextEntry : rest)}
                , QuotaJournalDispatch retry
                )
          | otherwise ->
              let detail = "stable-authoritative-absence-after-final-attempt"
                  nextEntry = QuotaEntryRefused (quotaAttemptRequest intent) detail
               in Right
                    ( state {quotaJournalEntries = prefix <> (nextEntry : rest)}
                    , QuotaJournalRefused detail
                    )

  -- A completed first member can expose/persist the next member's intent in
  -- the same CAS transition; no external effect is returned before that state.
  continueCompleted nextState prefix rest =
    case rest of
      [] ->
        Right (nextState, QuotaJournalCompleted (completedItems prefix))
      QuotaEntryPending request : remaining -> do
        intent <- mkAttempt request 1 now deadline
        observation <- observationFor request observations
        desired <- desiredValue request
        case classifyObservation desired intent observation of
          Just item -> do
            let nextEntry = QuotaEntryCompleted request item
                completedState =
                  nextState
                    { quotaJournalEntries = prefix <> (nextEntry : remaining)
                    }
            continueCompleted completedState (prefix <> [nextEntry]) remaining
          Nothing -> do
            let nextEntry = QuotaEntryAttempting intent 0
            Right
              ( nextState
                  { quotaJournalEntries =
                      prefix <> (nextEntry : remaining)
                  }
              , QuotaJournalDispatch intent
              )
      QuotaEntryRefused _ detail : _ -> Right (nextState, QuotaJournalRefused detail)
      _ -> advanceQuotaJournal now deadline observations nextState

  completedItems entries =
    [ item
    | QuotaEntryCompleted _ item <- entries
    ]

recordQuotaProviderResponse
  :: Text
  -> Text
  -> Text
  -> QuotaJournalState
  -> Either QuotaJournalError QuotaJournalState
recordQuotaProviderResponse attemptIdentity providerRequestIdentity status state
  | any (Text.null . Text.strip) [attemptIdentity, providerRequestIdentity, status] =
      Left QuotaJournalProviderResponseInvalid
  | otherwise = do
      (prefix, intent, suffix) <- findAttempt attemptIdentity [] (quotaJournalEntries state)
      let request = quotaAttemptRequest intent
          item = readBackFor request attemptIdentity providerRequestIdentity status
      pure
        state
          { quotaJournalEntries =
              reverse prefix <> (QuotaEntryCompleted request item : suffix)
          }
 where
  findAttempt identity prefix entries = case entries of
    [] -> Left QuotaJournalAttemptMismatch
    QuotaEntryAttempting intent _ : rest
      | quotaAttemptIdentity intent == identity -> Right (prefix, intent, rest)
    entry : rest -> findAttempt identity (entry : prefix) rest

quotaJournalReadBack :: QuotaJournalState -> Maybe [AdminQuotaItemReadBack]
quotaJournalReadBack state = traverse entryReadBack (quotaJournalEntries state)
 where
  entryReadBack entry = case entry of
    QuotaEntryCompleted _ item -> Just item
    _ -> Nothing

quotaJournalOperationIdValue :: QuotaJournalState -> Text
quotaJournalOperationIdValue = quotaJournalOperationId

quotaJournalRequestInventory :: QuotaJournalState -> [AdminQuotaRequest]
quotaJournalRequestInventory = fmap entryRequest . quotaJournalEntries

quotaJournalStateCodec :: Int -> ModelBCodec QuotaJournalState
quotaJournalStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \state -> do
        validateState state
        let bytes = LazyByteString.toStrict (serialise state)
        if ByteString.length bytes <= maximumBytes
          then Right bytes
          else Left "quota journal exceeds encoded-size bound"
    , decodeModelBValue = \bytes -> do
        if ByteString.length bytes <= maximumBytes
          then pure ()
          else Left "quota journal exceeds encoded-size bound"
        state <-
          case Codec.deserialiseOrFail (LazyByteString.fromStrict bytes) of
            Left _ -> Left "quota journal decode failed"
            Right value -> Right value
        if LazyByteString.toStrict (serialise state) == bytes
          then validateState state >> Right state
          else Left "quota journal is not canonical"
    }

stableAbsenceScans :: Natural
stableAbsenceScans = 2

maximumAttempts :: Natural
maximumAttempts = 2

mkAttempt
  :: AdminQuotaRequest
  -> Natural
  -> AuthorityTime
  -> AuthorityTime
  -> Either QuotaJournalError QuotaAttemptIntent
mkAttempt request number now deadline
  | number == 0 || number > maximumAttempts = Left QuotaJournalAttemptMismatch
  | authorityTimeMicros now >= authorityTimeMicros deadline = Left QuotaJournalDeadlineExpired
  | otherwise =
      Right
        QuotaAttemptIntent
          { quotaAttemptRequest = request
          , quotaAttemptNumber = number
          , quotaAttemptIdentity =
              sha256Text
                ( LazyByteString.toStrict
                    ( serialise
                        ( "prodbox-admin-quota-attempt-v1" :: Text
                        , request
                        , number
                        , authorityTimeMicros now
                        , authorityTimeMicros deadline
                        )
                    )
                )
          , quotaAttemptStartedMicros = authorityTimeMicros now
          , quotaAttemptDeadlineMicros = authorityTimeMicros deadline
          }

classifyObservation
  :: Double
  -> QuotaAttemptIntent
  -> QuotaExternalObservation
  -> Maybe AdminQuotaItemReadBack
classifyObservation desired intent observation
  | quotaExternalCurrentValue observation >= desired =
      Just
        ( readBackFor
            request
            (quotaAttemptIdentity intent)
            ("current-quota:" <> quotaAttemptIdentity intent)
            "CURRENT_SATISFIED"
        )
  | otherwise = case sortOn (Data.Ord.Down . historyOrder) matchingHistory of
      [] -> Nothing
      match : _ ->
        Just
          ( readBackFor
              request
              (quotaAttemptIdentity intent)
              (quotaHistoryProviderRequestIdentity match)
              (quotaHistoryStatus match)
          )
 where
  request = quotaAttemptRequest intent
  startSeconds = fromIntegral (quotaAttemptStartedMicros intent) / 1000000
  deadlineSeconds = fromIntegral (quotaAttemptDeadlineMicros intent) / 1000000
  matchingHistory =
    filter
      ( \history ->
          quotaHistoryServiceCode history == adminQuotaRequestServiceCode request
            && quotaHistoryQuotaCode history == adminQuotaRequestCode request
            && quotaHistoryDesiredValue history == desired
            && quotaHistoryCreatedEpochSeconds history >= startSeconds
            && quotaHistoryCreatedEpochSeconds history <= deadlineSeconds
            && quotaHistoryLastUpdatedEpochSeconds history
              >= quotaHistoryCreatedEpochSeconds history
            && not (Text.null (Text.strip (quotaHistoryProviderRequestIdentity history)))
            && not (Text.null (Text.strip (quotaHistoryStatus history)))
      )
      (quotaExternalHistory observation)
  historyOrder history =
    ( quotaHistoryCreatedEpochSeconds history
    , quotaHistoryProviderRequestIdentity history
    )

validateObservationInventory
  :: [QuotaExternalObservation]
  -> [QuotaJournalEntry]
  -> Either QuotaJournalError ()
validateObservationInventory observations entries = do
  let activeRequests = fmap entryRequest (filter (not . entryTerminal) entries)
      observedRequests = fmap quotaExternalRequest observations
  if all (`elem` observedRequests) activeRequests
    && all (`elem` fmap entryRequest entries) observedRequests
    then Right ()
    else Left QuotaJournalObservationMismatch

observationFor
  :: AdminQuotaRequest
  -> [QuotaExternalObservation]
  -> Either QuotaJournalError QuotaExternalObservation
observationFor request observations = case filter ((== request) . quotaExternalRequest) observations of
  [observation] -> Right observation
  _ -> Left QuotaJournalObservationMismatch

desiredValue :: AdminQuotaRequest -> Either QuotaJournalError Double
desiredValue request = case readMaybe (Text.unpack (adminQuotaRequestDesiredValue request)) of
  Just value | value > 0 && not (isNaN value) && not (isInfinite value) -> Right value
  _ -> Left (QuotaJournalDesiredValueInvalid (adminQuotaRequestDesiredValue request))

readBackFor :: AdminQuotaRequest -> Text -> Text -> Text -> AdminQuotaItemReadBack
readBackFor request attemptIdentity providerIdentity status =
  AdminQuotaItemReadBack
    { adminQuotaServiceCode = adminQuotaRequestServiceCode request
    , adminQuotaCode = adminQuotaRequestCode request
    , adminQuotaRegion = adminQuotaRequestRegion request
    , adminQuotaDesiredValue = adminQuotaRequestDesiredValue request
    , adminQuotaAttemptIdentity = attemptIdentity
    , adminQuotaProviderRequestIdentity = providerIdentity
    , adminQuotaStatus = status
    }

entryRequest :: QuotaJournalEntry -> AdminQuotaRequest
entryRequest entry = case entry of
  QuotaEntryPending request -> request
  QuotaEntryAttempting intent _ -> quotaAttemptRequest intent
  QuotaEntryCompleted request _ -> request
  QuotaEntryRefused request _ -> request

entryTerminal :: QuotaJournalEntry -> Bool
entryTerminal entry = case entry of
  QuotaEntryCompleted {} -> True
  QuotaEntryRefused {} -> True
  _ -> False

readBackMatchesRequest :: AdminQuotaRequest -> AdminQuotaItemReadBack -> Bool
readBackMatchesRequest request item =
  adminQuotaServiceCode item == adminQuotaRequestServiceCode request
    && adminQuotaCode item == adminQuotaRequestCode request
    && adminQuotaRegion item == adminQuotaRequestRegion request
    && adminQuotaDesiredValue item == adminQuotaRequestDesiredValue request

validateState :: QuotaJournalState -> Either String ()
validateState state = case initialQuotaJournal
  (quotaJournalOperationId state)
  (fmap entryRequest (quotaJournalEntries state)) of
  Left err -> Left (show err)
  Right _ -> traverse_ validateEntry (quotaJournalEntries state)
 where
  validateEntry entry = case entry of
    QuotaEntryPending _ -> Right ()
    QuotaEntryAttempting intent absenceScans
      | quotaAttemptNumber intent >= 1
          && quotaAttemptNumber intent <= maximumAttempts
          && quotaAttemptStartedMicros intent < quotaAttemptDeadlineMicros intent
          && absenceScans < stableAbsenceScans
          && not (Text.null (quotaAttemptIdentity intent)) ->
          Right ()
      | otherwise -> Left "invalid quota attempt state"
    QuotaEntryCompleted request item
      | readBackMatchesRequest request item
          && all
            (not . Text.null . Text.strip)
            [ adminQuotaAttemptIdentity item
            , adminQuotaProviderRequestIdentity item
            , adminQuotaStatus item
            ] ->
          Right ()
      | otherwise -> Left "invalid quota completion state"
    QuotaEntryRefused _ detail
      | not (Text.null (Text.strip detail)) -> Right ()
      | otherwise -> Left "invalid quota refusal state"

sha256Text :: ByteString.ByteString -> Text
sha256Text =
  TextEncoding.decodeUtf8
    . ByteString.pack
    . concatMap hexByte
    . ByteString.unpack
    . SHA256.hash
 where
  hexByte byte =
    let rendered = showHex byte ""
     in fmap (fromIntegral . fromEnum) (if length rendered == 1 then '0' : rendered else rendered)
