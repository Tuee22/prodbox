{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Fixed-capacity registered clients for Lifecycle Authority submission.
--
-- A transport principal is registered at one numeric slot and key generation.
-- Callers supply only a stable submission key and request digest; the Authority
-- allocates the monotone sequence.  Exact replay returns the original
-- 'OperationId', while an arbitrary principal can never create a map entry.
module Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientPrincipal
  , ClientPrincipalError (..)
  , mkClientPrincipal
  , clientPrincipalForCaller
  , clientPrincipalText
  , ClientSubmissionKey
  , ClientSubmissionKeyError (..)
  , mkClientSubmissionKey
  , clientSubmissionKeyText
  , RegisteredClientSlot
  , RegisteredClientSlotError (..)
  , mkRegisteredClientSlot
  , registeredClientSlotValue
  , RegisteredClientGeneration
  , RegisteredClientGenerationError (..)
  , mkRegisteredClientGeneration
  , registeredClientGenerationValue
  , RegisteredClientSpec
  , RegisteredClientSpecError (..)
  , mkRegisteredClientSpec
  , registeredClientPrincipal
  , registeredClientSlot
  , registeredClientGeneration
  , registeredClientMaximumReservations
  , registeredClientId
  , registeredClientIdForCaller
  , RegisteredClientTable
  , RegisteredClientTableError (..)
  , mkRegisteredClientTable
  , registeredClientTableCapacity
  , registeredClientTableSize
  , registeredClientReservationCount
  , RegisteredClientTableInvariantError (..)
  , validateRegisteredClientTable
  , registeredClientTableConfigurationMatches
  , registeredClientReservationBindings
  , RegisteredSubmissionInspection (..)
  , inspectRegisteredSubmission
  , RegisteredSubmissionDecision (..)
  , reserveRegisteredSubmission
  , RegisteredSubmissionObservation (..)
  , observeRegisteredSubmission
  )
where

import Codec.Serialise (Serialise)
import Data.Char (isControl, isSpace)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal
  , allCallerPrincipals
  , callerPrincipalText
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , ClientSubmissions (..)
  , OperationId (OperationId)
  , RequestDigest
  , SubmissionLedger (..)
  , SubmissionRecord (..)
  , SubmissionStatus (StatusExpired, StatusUnknown)
  , SubmitDecision (..)
  , stepSubmit
  , submissionStatus
  )

hardMaximumRegisteredClients :: Natural
hardMaximumRegisteredClients = 1024

hardMaximumReservationsPerClient :: Natural
hardMaximumReservationsPerClient = 65536

maximumIdentityCharacters :: Int
maximumIdentityCharacters = 128

newtype ClientPrincipal = ClientPrincipal Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data ClientPrincipalError
  = ClientPrincipalEmpty
  | ClientPrincipalTooLong !Int !Int
  | ClientPrincipalInvalidCharacter
  | ClientPrincipalUnknown !Text
  deriving stock (Eq, Show)

mkClientPrincipal :: Text -> Either ClientPrincipalError ClientPrincipal
mkClientPrincipal value
  | Text.null value = Left ClientPrincipalEmpty
  | Text.length value > maximumIdentityCharacters =
      Left
        ( ClientPrincipalTooLong
            (Text.length value)
            maximumIdentityCharacters
        )
  | Text.any invalidIdentityCharacter value = Left ClientPrincipalInvalidCharacter
  | value `notElem` fmap callerPrincipalText allCallerPrincipals =
      Left (ClientPrincipalUnknown value)
  | otherwise = Right (ClientPrincipal value)

clientPrincipalForCaller :: CallerPrincipal -> ClientPrincipal
clientPrincipalForCaller = ClientPrincipal . callerPrincipalText

clientPrincipalText :: ClientPrincipal -> Text
clientPrincipalText (ClientPrincipal value) = value

newtype ClientSubmissionKey = ClientSubmissionKey Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data ClientSubmissionKeyError
  = ClientSubmissionKeyEmpty
  | ClientSubmissionKeyTooLong !Int !Int
  | ClientSubmissionKeyInvalidCharacter
  deriving stock (Eq, Show)

mkClientSubmissionKey
  :: Text -> Either ClientSubmissionKeyError ClientSubmissionKey
mkClientSubmissionKey value
  | Text.null value = Left ClientSubmissionKeyEmpty
  | Text.length value > maximumIdentityCharacters =
      Left
        ( ClientSubmissionKeyTooLong
            (Text.length value)
            maximumIdentityCharacters
        )
  | Text.any invalidIdentityCharacter value = Left ClientSubmissionKeyInvalidCharacter
  | otherwise = Right (ClientSubmissionKey value)

clientSubmissionKeyText :: ClientSubmissionKey -> Text
clientSubmissionKeyText (ClientSubmissionKey value) = value

invalidIdentityCharacter :: Char -> Bool
invalidIdentityCharacter character = isControl character || isSpace character

newtype RegisteredClientSlot = RegisteredClientSlot Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientSlotError
  = RegisteredClientSlotMustBePositive
  | RegisteredClientSlotExceedsHardMaximum !Natural !Natural
  deriving stock (Eq, Show)

mkRegisteredClientSlot
  :: Natural -> Either RegisteredClientSlotError RegisteredClientSlot
mkRegisteredClientSlot value
  | value == 0 = Left RegisteredClientSlotMustBePositive
  | value > hardMaximumRegisteredClients =
      Left
        ( RegisteredClientSlotExceedsHardMaximum
            value
            hardMaximumRegisteredClients
        )
  | otherwise = Right (RegisteredClientSlot value)

registeredClientSlotValue :: RegisteredClientSlot -> Natural
registeredClientSlotValue (RegisteredClientSlot value) = value

newtype RegisteredClientGeneration = RegisteredClientGeneration Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientGenerationError
  = RegisteredClientGenerationMustBePositive
  deriving stock (Eq, Show)

mkRegisteredClientGeneration
  :: Natural
  -> Either RegisteredClientGenerationError RegisteredClientGeneration
mkRegisteredClientGeneration value
  | value == 0 = Left RegisteredClientGenerationMustBePositive
  | otherwise = Right (RegisteredClientGeneration value)

registeredClientGenerationValue :: RegisteredClientGeneration -> Natural
registeredClientGenerationValue (RegisteredClientGeneration value) = value

data RegisteredClientSpec = RegisteredClientSpec
  { registeredClientPrincipal :: !ClientPrincipal
  , registeredClientSlot :: !RegisteredClientSlot
  , registeredClientGeneration :: !RegisteredClientGeneration
  , registeredClientMaximumReservations :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientSpecError
  = RegisteredClientReservationsMustBePositive
  | RegisteredClientReservationsExceedHardMaximum !Natural !Natural
  deriving stock (Eq, Show)

mkRegisteredClientSpec
  :: ClientPrincipal
  -> RegisteredClientSlot
  -> RegisteredClientGeneration
  -> Natural
  -> Either RegisteredClientSpecError RegisteredClientSpec
mkRegisteredClientSpec principal slot generation maximumReservations
  | maximumReservations == 0 = Left RegisteredClientReservationsMustBePositive
  | maximumReservations > hardMaximumReservationsPerClient =
      Left
        ( RegisteredClientReservationsExceedHardMaximum
            maximumReservations
            hardMaximumReservationsPerClient
        )
  | otherwise =
      Right
        RegisteredClientSpec
          { registeredClientPrincipal = principal
          , registeredClientSlot = slot
          , registeredClientGeneration = generation
          , registeredClientMaximumReservations = maximumReservations
          }

registeredClientId :: RegisteredClientSpec -> ClientId
registeredClientId spec =
  ClientId
    ( "registered-slot/"
        <> naturalText (registeredClientSlotValue (registeredClientSlot spec))
        <> "/generation/"
        <> naturalText
          (registeredClientGenerationValue (registeredClientGeneration spec))
    )

-- | Resolve the authority-owned client identity for one authenticated caller
-- slot.  Both the transport principal and its pinned signing-key generation
-- must match the retained registry definition; an operation identifier alone
-- is therefore never a transferable checkpoint capability.
registeredClientIdForCaller
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> RegisteredClientTable
  -> Maybe ClientId
registeredClientIdForCaller caller generation table = do
  client <- Map.lookup (clientPrincipalForCaller caller) (registeredClientStates table)
  let spec = registeredClientStateSpec client
  if registeredClientGeneration spec == generation
    then Just (registeredClientId spec)
    else Nothing

data RegisteredReservation = RegisteredReservation
  { registeredReservationSequence :: !ClientSequence
  , registeredReservationDigest :: !RequestDigest
  , registeredReservationEpoch :: !AuthorityEpoch
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientState = RegisteredClientState
  { registeredClientStateSpec :: !RegisteredClientSpec
  , registeredClientSequenceHighWater :: !Natural
  , registeredClientReservations :: !(Map ClientSubmissionKey RegisteredReservation)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientTable = RegisteredClientTable
  { registeredClientTableCapacity :: !Natural
  , registeredClientStates :: !(Map ClientPrincipal RegisteredClientState)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RegisteredClientTableError
  = RegisteredClientTableCapacityMustBePositive
  | RegisteredClientTableCapacityExceedsHardMaximum !Natural !Natural
  | RegisteredClientTableOverCapacity !Natural !Natural
  | RegisteredClientPrincipalDuplicated !ClientPrincipal
  | RegisteredClientSlotDuplicated !RegisteredClientSlot
  deriving stock (Eq, Show)

mkRegisteredClientTable
  :: Natural
  -> [RegisteredClientSpec]
  -> Either RegisteredClientTableError RegisteredClientTable
mkRegisteredClientTable capacity specs
  | capacity == 0 = Left RegisteredClientTableCapacityMustBePositive
  | capacity > hardMaximumRegisteredClients =
      Left
        ( RegisteredClientTableCapacityExceedsHardMaximum
            capacity
            hardMaximumRegisteredClients
        )
  | observedSize > capacity =
      Left (RegisteredClientTableOverCapacity observedSize capacity)
  | Just duplicate <- firstDuplicate principals =
      Left (RegisteredClientPrincipalDuplicated duplicate)
  | Just duplicate <- firstDuplicate slots =
      Left (RegisteredClientSlotDuplicated duplicate)
  | otherwise =
      Right
        RegisteredClientTable
          { registeredClientTableCapacity = capacity
          , registeredClientStates =
              Map.fromList
                [ ( registeredClientPrincipal spec
                  , RegisteredClientState
                      { registeredClientStateSpec = spec
                      , registeredClientSequenceHighWater = 0
                      , registeredClientReservations = Map.empty
                      }
                  )
                | spec <- specs
                ]
          }
 where
  observedSize = fromIntegral (length specs)
  principals = fmap registeredClientPrincipal specs
  slots = fmap registeredClientSlot specs

registeredClientTableSize :: RegisteredClientTable -> Natural
registeredClientTableSize = fromIntegral . Map.size . registeredClientStates

registeredClientReservationCount
  :: ClientPrincipal -> RegisteredClientTable -> Maybe Natural
registeredClientReservationCount principal table =
  fromIntegral . Map.size . registeredClientReservations
    <$> Map.lookup principal (registeredClientStates table)

data RegisteredClientTableInvariantError
  = RegisteredClientTableDefinitionInvalid !RegisteredClientTableError
  | RegisteredClientStateKeyMismatch !ClientPrincipal !ClientPrincipal
  | RegisteredClientPrincipalInvalid !ClientPrincipal !ClientPrincipalError
  | RegisteredClientSlotInvalid !ClientPrincipal !RegisteredClientSlotError
  | RegisteredClientGenerationInvalid !ClientPrincipal !RegisteredClientGenerationError
  | RegisteredClientSpecInvalid !ClientPrincipal !RegisteredClientSpecError
  | RegisteredClientReservationsOverCapacity !ClientPrincipal !Natural !Natural
  | RegisteredClientSequenceHighWaterInvalid !ClientPrincipal !Natural !Natural
  | RegisteredClientReservationSequenceSetInvalid !ClientPrincipal
  | RegisteredClientSubmissionKeyInvalid !ClientPrincipal !ClientSubmissionKeyError
  | RegisteredClientReservationEpochInvalid !ClientPrincipal !ClientSubmissionKey
  | RegisteredClientReservationMissingFromLedger !ClientPrincipal !ClientSubmissionKey
  | RegisteredClientReservationDigestMismatch !ClientPrincipal !ClientSubmissionKey
  deriving stock (Eq, Show)

-- | Validate both the immutable registry definition and its evolving
-- reservation cursors against the submission ledger stored in the same CAS
-- aggregate.  A compacted terminal may be absent from the ledger only when the
-- ledger classifies its allocated sequence as expired.
validateRegisteredClientTable
  :: SubmissionLedger
  -> RegisteredClientTable
  -> Either RegisteredClientTableInvariantError ()
validateRegisteredClientTable ledger table = do
  let states = Map.toList (registeredClientStates table)
      specs = fmap (registeredClientStateSpec . snd) states
  case mkRegisteredClientTable (registeredClientTableCapacity table) specs of
    Left err -> Left (RegisteredClientTableDefinitionInvalid err)
    Right _ -> Right ()
  traverse_ validateState states
 where
  validateState (mapPrincipal, client) = do
    let spec = registeredClientStateSpec client
        specPrincipal = registeredClientPrincipal spec
        reservationCount = fromIntegral (Map.size (registeredClientReservations client))
        maximumReservations = registeredClientMaximumReservations spec
        highWater = registeredClientSequenceHighWater client
    if mapPrincipal == specPrincipal
      then Right ()
      else Left (RegisteredClientStateKeyMismatch mapPrincipal specPrincipal)
    case mkClientPrincipal (clientPrincipalText specPrincipal) of
      Left err -> Left (RegisteredClientPrincipalInvalid specPrincipal err)
      Right _ -> Right ()
    case mkRegisteredClientSlot (registeredClientSlotValue (registeredClientSlot spec)) of
      Left err -> Left (RegisteredClientSlotInvalid specPrincipal err)
      Right _ -> Right ()
    case mkRegisteredClientGeneration
      (registeredClientGenerationValue (registeredClientGeneration spec)) of
      Left err -> Left (RegisteredClientGenerationInvalid specPrincipal err)
      Right _ -> Right ()
    case mkRegisteredClientSpec
      specPrincipal
      (registeredClientSlot spec)
      (registeredClientGeneration spec)
      maximumReservations of
      Left err -> Left (RegisteredClientSpecInvalid specPrincipal err)
      Right _ -> Right ()
    if reservationCount <= maximumReservations
      then Right ()
      else
        Left
          ( RegisteredClientReservationsOverCapacity
              specPrincipal
              reservationCount
              maximumReservations
          )
    if highWater <= maximumReservations
      then Right ()
      else
        Left
          ( RegisteredClientSequenceHighWaterInvalid
              specPrincipal
              highWater
              maximumReservations
          )
    let observedSequences =
          Set.fromList
            (fmap registeredReservationSequence (Map.elems (registeredClientReservations client)))
        expectedSequences = Set.fromList [ClientSequence value | value <- [1 .. highWater]]
    if observedSequences == expectedSequences
      then Right ()
      else Left (RegisteredClientReservationSequenceSetInvalid specPrincipal)
    traverse_
      (validateReservation client)
      (Map.toList (registeredClientReservations client))
  validateReservation client (submissionKey, reservation) = do
    let spec = registeredClientStateSpec client
        principal = registeredClientPrincipal spec
        clientId = registeredClientId spec
        sequenceNumber = registeredReservationSequence reservation
    case mkClientSubmissionKey (clientSubmissionKeyText submissionKey) of
      Left err -> Left (RegisteredClientSubmissionKeyInvalid principal err)
      Right _ -> Right ()
    if authorityEpochValue (registeredReservationEpoch reservation) > 0
      then Right ()
      else Left (RegisteredClientReservationEpochInvalid principal submissionKey)
    case lookupSubmissionRecord ledger clientId sequenceNumber of
      Just record
        | submissionRecordDigest record == registeredReservationDigest reservation ->
            Right ()
        | otherwise ->
            Left (RegisteredClientReservationDigestMismatch principal submissionKey)
      Nothing ->
        case submissionStatus clientId sequenceNumber ledger of
          StatusExpired -> Right ()
          _ -> Left (RegisteredClientReservationMissingFromLedger principal submissionKey)

-- | Compare only immutable registry definition: capacity, principals, slots,
-- key generations, and per-client reservation ceilings.  Evolving cursors and
-- reservations are deliberately ignored.
registeredClientTableConfigurationMatches
  :: RegisteredClientTable -> RegisteredClientTable -> Bool
registeredClientTableConfigurationMatches expected observed =
  registeredClientTableCapacity expected == registeredClientTableCapacity observed
    && specifications expected == specifications observed
 where
  specifications = Map.map registeredClientStateSpec . registeredClientStates

registeredClientReservationBindings
  :: RegisteredClientTable
  -> [(ClientId, ClientSequence, RequestDigest, AuthorityEpoch)]
registeredClientReservationBindings table =
  [ ( registeredClientId (registeredClientStateSpec client)
    , registeredReservationSequence reservation
    , registeredReservationDigest reservation
    , registeredReservationEpoch reservation
    )
  | client <- Map.elems (registeredClientStates table)
  , reservation <- Map.elems (registeredClientReservations client)
  ]

data RegisteredSubmissionDecision
  = RegisteredSubmissionAccepted !OperationId
  | RegisteredSubmissionDuplicate !OperationId
  | RegisteredSubmissionRefusedUnregistered
  | RegisteredSubmissionRefusedGenerationMismatch
      !RegisteredClientGeneration
      !RegisteredClientGeneration
  | RegisteredSubmissionRefusedReservationCapacity
  | RegisteredSubmissionRefusedDigestConflict
  | RegisteredSubmissionRefusedGlobalCapacity
  | RegisteredSubmissionRefusedExpired
  | RegisteredSubmissionRefusedLedgerDiverged
  deriving stock (Eq, Show)

data RegisteredSubmissionInspection
  = RegisteredSubmissionFresh
  | RegisteredSubmissionKnown !RegisteredSubmissionDecision
  deriving stock (Eq, Show)

inspectRegisteredSubmission
  :: SubmissionLedger
  -> RegisteredClientTable
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> RegisteredSubmissionInspection
inspectRegisteredSubmission ledger table caller generation submissionKey digest =
  case Map.lookup principal (registeredClientStates table) of
    Nothing -> known RegisteredSubmissionRefusedUnregistered
    Just client
      | expectedGeneration /= generation ->
          known
            ( RegisteredSubmissionRefusedGenerationMismatch
                expectedGeneration
                generation
            )
      | otherwise ->
          case Map.lookup submissionKey (registeredClientReservations client) of
            Nothing -> RegisteredSubmissionFresh
            Just reservation -> known (replayExistingSubmission ledger client reservation digest)
 where
  principal = clientPrincipalForCaller caller
  expectedGeneration =
    maybe
      generation
      (registeredClientGeneration . registeredClientStateSpec)
      (Map.lookup principal (registeredClientStates table))
  known = RegisteredSubmissionKnown

reserveRegisteredSubmission
  :: AuthorityEpoch
  -> SubmissionLedger
  -> RegisteredClientTable
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RequestDigest
  -> (RegisteredSubmissionDecision, SubmissionLedger, RegisteredClientTable)
reserveRegisteredSubmission epoch ledger table caller generation submissionKey digest =
  case inspectRegisteredSubmission ledger table caller generation submissionKey digest of
    RegisteredSubmissionKnown decision -> unchanged decision
    RegisteredSubmissionFresh ->
      case Map.lookup principal (registeredClientStates table) of
        Nothing -> unchanged RegisteredSubmissionRefusedUnregistered
        Just client -> reserveFresh client
 where
  principal = clientPrincipalForCaller caller
  unchanged decision = (decision, ledger, table)
  reserveFresh client
    | fromIntegral (Map.size (registeredClientReservations client))
        >= registeredClientMaximumReservations (registeredClientStateSpec client) =
        unchanged RegisteredSubmissionRefusedReservationCapacity
    | otherwise =
        let nextSequenceValue = registeredClientSequenceHighWater client + 1
            nextSequence = ClientSequence nextSequenceValue
            clientId = registeredClientId (registeredClientStateSpec client)
            (submissionDecision, nextLedger) =
              stepSubmit epoch ledger clientId nextSequence digest
         in case submissionDecision of
              SubmissionAccepted operationId ->
                let reservation =
                      RegisteredReservation
                        { registeredReservationSequence = nextSequence
                        , registeredReservationDigest = digest
                        , registeredReservationEpoch = epoch
                        }
                    nextClient =
                      client
                        { registeredClientSequenceHighWater = nextSequenceValue
                        , registeredClientReservations =
                            Map.insert
                              submissionKey
                              reservation
                              (registeredClientReservations client)
                        }
                    nextTable =
                      table
                        { registeredClientStates =
                            Map.insert principal nextClient (registeredClientStates table)
                        }
                 in (RegisteredSubmissionAccepted operationId, nextLedger, nextTable)
              SubmissionDuplicate _ ->
                unchanged RegisteredSubmissionRefusedLedgerDiverged
              SubmissionRefusedFull ->
                unchanged RegisteredSubmissionRefusedGlobalCapacity
              SubmissionRefusedSequenceReused ->
                unchanged RegisteredSubmissionRefusedLedgerDiverged
              SubmissionRefusedExpired ->
                unchanged RegisteredSubmissionRefusedLedgerDiverged

replayExistingSubmission
  :: SubmissionLedger
  -> RegisteredClientState
  -> RegisteredReservation
  -> RequestDigest
  -> RegisteredSubmissionDecision
replayExistingSubmission ledger client reservation digest
  | registeredReservationDigest reservation /= digest =
      RegisteredSubmissionRefusedDigestConflict
  | otherwise =
      let operationId = operationIdFor client reservation
          status =
            submissionStatus
              (registeredClientId (registeredClientStateSpec client))
              (registeredReservationSequence reservation)
              ledger
       in case status of
            StatusUnknown -> RegisteredSubmissionRefusedLedgerDiverged
            StatusExpired -> RegisteredSubmissionRefusedExpired
            _ -> RegisteredSubmissionDuplicate operationId

data RegisteredSubmissionObservation
  = RegisteredSubmissionObserved !SubmissionStatus
  | RegisteredSubmissionUnknown
  | RegisteredSubmissionObserveRefusedUnregistered
  | RegisteredSubmissionObserveRefusedGenerationMismatch
      !RegisteredClientGeneration
      !RegisteredClientGeneration
  | RegisteredSubmissionObserveDiverged
  deriving stock (Eq, Show)

observeRegisteredSubmission
  :: SubmissionLedger
  -> RegisteredClientTable
  -> CallerPrincipal
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> RegisteredSubmissionObservation
observeRegisteredSubmission ledger table caller generation submissionKey =
  case Map.lookup principal (registeredClientStates table) of
    Nothing -> RegisteredSubmissionObserveRefusedUnregistered
    Just client
      | registeredClientGeneration (registeredClientStateSpec client) /= generation ->
          RegisteredSubmissionObserveRefusedGenerationMismatch
            (registeredClientGeneration (registeredClientStateSpec client))
            generation
      | otherwise -> case Map.lookup submissionKey (registeredClientReservations client) of
          Nothing -> RegisteredSubmissionUnknown
          Just reservation ->
            case submissionStatus
              (registeredClientId (registeredClientStateSpec client))
              (registeredReservationSequence reservation)
              ledger of
              StatusUnknown -> RegisteredSubmissionObserveDiverged
              status -> RegisteredSubmissionObserved status
 where
  principal = clientPrincipalForCaller caller

lookupSubmissionRecord
  :: SubmissionLedger -> ClientId -> ClientSequence -> Maybe SubmissionRecord
lookupSubmissionRecord ledger client seqNo =
  Map.lookup client (submissionClients ledger)
    >>= Map.lookup seqNo . clientRecords

submissionRecordDigest :: SubmissionRecord -> RequestDigest
submissionRecordDigest record = case record of
  SubmissionInFlight digest -> digest
  SubmissionSettled digest _ -> digest

operationIdFor
  :: RegisteredClientState -> RegisteredReservation -> OperationId
operationIdFor client reservation =
  OperationId
    (registeredReservationEpoch reservation)
    (registeredClientId (registeredClientStateSpec client))
    (registeredReservationSequence reservation)
    (registeredReservationDigest reservation)

naturalText :: Natural -> Text
naturalText = Text.pack . show

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
 where
  go _ [] = Nothing
  go observed (value : rest)
    | value `Set.member` observed = Just value
    | otherwise = go (Set.insert value observed) rest
