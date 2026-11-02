{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Fixed-capacity registered clients for Lifecycle Authority submission.
--
-- Each origin has one numeric slot with independently retained key generations.
-- Callers supply only a stable submission key and request digest; the Authority
-- allocates the monotone sequence.  Exact replay returns the original
-- 'OperationId', while an arbitrary principal can never create a map entry.
module Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientPrincipal
  , ClientPrincipalError (..)
  , mkClientPrincipal
  , clientPrincipalForCaller
  , clientPrincipalForRpcOrigin
  , clientPrincipalCaller
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
  , mkVersionedRegisteredClientTable
  , reconcileRegisteredClientTable
  , registeredClientTableSpecifications
  , registeredClientTableRetired
  , registeredClientTableRequiresRpcRegistry
  , registeredClientTableCapacity
  , registeredClientMaximumSlots
  , registeredClientTableSize
  , registeredClientReservationCount
  , RegisteredClientTableInvariantError (..)
  , validateRegisteredClientTable
  , registeredClientTableConfigurationMatches
  , registeredClientReservationBindings
  , registeredClientReservationEntries
  , RegisteredSubmissionInspection (..)
  , inspectRegisteredSubmission
  , RegisteredSubmissionDecision (..)
  , reserveRegisteredSubmission
  , RegisteredSubmissionObservation (..)
  , observeRegisteredSubmission
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (decode, encode))
import Control.Monad (unless)
import Data.Char (isControl, isSpace)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Data.Word (Word64)
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

registeredClientMaximumSlots :: Natural
registeredClientMaximumSlots = hardMaximumRegisteredClients

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
  | clientPrincipalCaller (ClientPrincipal value) == Nothing =
      Left (ClientPrincipalUnknown value)
  | otherwise = Right (ClientPrincipal value)

clientPrincipalForCaller :: CallerPrincipal -> ClientPrincipal
clientPrincipalForCaller = ClientPrincipal . callerPrincipalText

-- | This suffix is retained Authority metadata, never a submission field.
clientPrincipalForRpcOrigin
  :: CallerPrincipal -> RegisteredClientGeneration -> Either ClientPrincipalError ClientPrincipal
clientPrincipalForRpcOrigin caller generation =
  mkClientPrincipal
    ( callerPrincipalText caller
        <> "/rpc-origin/"
        <> naturalText (registeredClientGenerationValue generation)
    )

clientPrincipalCaller :: ClientPrincipal -> Maybe CallerPrincipal
clientPrincipalCaller (ClientPrincipal value) =
  case filter matches allCallerPrincipals of
    [caller] -> Just caller
    _ -> Nothing
 where
  matches caller
    | value == callerPrincipalText caller = True
    | otherwise = case Text.stripPrefix (callerPrincipalText caller <> "/rpc-origin/") value of
        Nothing -> False
        Just suffix -> case TextRead.decimal suffix of
          Right (number, rest) ->
            Text.null rest
              && number > (0 :: Natural)
              && number <= fromIntegral (maxBound :: Word64)
              && naturalText number == suffix
          Left _ -> False

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
registeredClientIdForCaller caller generation table =
  case callerState caller generation table of
    Right (_, client) -> Just (registeredClientId (registeredClientStateSpec client))
    Left _ -> Nothing

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

type RegisteredClientIdentity = (ClientPrincipal, RegisteredClientGeneration)

data RegisteredClientTable = RegisteredClientTable
  { internalRegisteredClientCapacity :: !Natural
  , registeredClientStates :: !(Map RegisteredClientIdentity RegisteredClientState)
  , internalRegisteredClientRetired :: !(Set RegisteredClientIdentity)
  }
  deriving stock (Eq, Show)

registeredClientTableCapacity :: RegisteredClientTable -> Natural
registeredClientTableCapacity = internalRegisteredClientCapacity

registeredClientTableSpecifications :: RegisteredClientTable -> [RegisteredClientSpec]
registeredClientTableSpecifications = fmap registeredClientStateSpec . Map.elems . registeredClientStates

registeredClientTableRetired :: RegisteredClientTable -> Set RegisteredClientIdentity
registeredClientTableRetired = internalRegisteredClientRetired

registeredClientTableRequiresRpcRegistry :: RegisteredClientTable -> Bool
registeredClientTableRequiresRpcRegistry table =
  not (Set.null (internalRegisteredClientRetired table))
    || length principals /= Set.size (Set.fromList principals)
    || any
      (\principal -> clientPrincipalText principal `notElem` fmap callerPrincipalText allCallerPrincipals)
      principals
 where
  principals = map registeredClientPrincipal (registeredClientTableSpecifications table)

-- Preserve the exact legacy product/map encoding while that shape suffices.
-- A versioned table keeps prior generations and retired reservations in place.
instance Serialise RegisteredClientTable where
  encode table
    | Set.null (internalRegisteredClientRetired table)
        && length principals == Set.size (Set.fromList principals)
        && all legacy principals =
        Cbor.encodeListLen 3
          <> Cbor.encodeWord 0
          <> encode (registeredClientTableCapacity table)
          <> encode (Map.fromList [(principal, state) | ((principal, _), state) <- states])
    | otherwise =
        Cbor.encodeListLen 5
          <> Cbor.encodeWord 0
          <> Cbor.encodeWord 2
          <> encode (registeredClientTableCapacity table)
          <> encode (registeredClientStates table)
          <> encode (internalRegisteredClientRetired table)
   where
    states = Map.toAscList (registeredClientStates table)
    principals = fmap (fst . fst) states
    legacy principal = clientPrincipalText principal `elem` fmap callerPrincipalText allCallerPrincipals
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    unless (tag == (0 :: Word)) (fail "RegisteredClientTable: unknown constructor")
    case fields of
      3 -> do
        capacity <- decode
        states <- decode
        pure (RegisteredClientTable capacity (restoreLegacy states) Set.empty)
      5 -> do
        version <- Cbor.decodeWord
        unless (version == (2 :: Word)) (fail "RegisteredClientTable: unknown schema")
        RegisteredClientTable <$> decode <*> decode <*> decode
      _ -> fail "RegisteredClientTable: unknown field count"
   where
    restoreLegacy states =
      Map.fromList
        [ ((principal, registeredClientGeneration (registeredClientStateSpec state)), state)
        | (principal, state) <- Map.toAscList states
        ]

data RegisteredClientTableError
  = RegisteredClientTableCapacityMustBePositive
  | RegisteredClientTableCapacityExceedsHardMaximum !Natural !Natural
  | RegisteredClientTableOverCapacity !Natural !Natural
  | RegisteredClientPrincipalDuplicated !ClientPrincipal
  | RegisteredClientSlotDuplicated !RegisteredClientSlot
  | RegisteredClientGenerationDuplicated !ClientPrincipal !RegisteredClientGeneration
  | RegisteredClientPrincipalSlotChanged !ClientPrincipal
  | RegisteredClientCallerGenerationDuplicated !CallerPrincipal !RegisteredClientGeneration
  | RegisteredClientPrincipalDefinitionInvalid !ClientPrincipal
  | RegisteredClientRetirementMissing !ClientPrincipal !RegisteredClientGeneration
  | RegisteredClientDefinitionChanged !ClientPrincipal !RegisteredClientGeneration
  | RegisteredClientRetirementRegressed !ClientPrincipal !RegisteredClientGeneration
  | RegisteredClientCapacityChanged
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
  | otherwise = mkVersionedRegisteredClientTable capacity specs Set.empty
 where
  observedSize = fromIntegral (length specs)
  principals = fmap registeredClientPrincipal specs
  slots = fmap registeredClientSlot specs

mkVersionedRegisteredClientTable
  :: Natural
  -> [RegisteredClientSpec]
  -> Set RegisteredClientIdentity
  -> Either RegisteredClientTableError RegisteredClientTable
mkVersionedRegisteredClientTable capacity specs retired = do
  unless (capacity > 0) (Left RegisteredClientTableCapacityMustBePositive)
  unless
    (capacity <= hardMaximumRegisteredClients)
    (Left (RegisteredClientTableCapacityExceedsHardMaximum capacity hardMaximumRegisteredClients))
  unless
    (fromIntegral (length specs) <= capacity)
    (Left (RegisteredClientTableOverCapacity (fromIntegral (length specs)) capacity))
  case firstDuplicate (map specIdentity specs) of
    Just (principal, generation) -> Left (RegisteredClientGenerationDuplicated principal generation)
    Nothing -> Right ()
  traverse_ validPrincipal specs
  traverse_
    checkPair
    [(left, right) | (index, left) <- zip [0 :: Int ..] specs, right <- drop (index + 1) specs]
  let states =
        Map.fromList
          [(specIdentity spec, RegisteredClientState spec 0 Map.empty) | spec <- specs]
  case Set.lookupMin (Set.difference retired (Map.keysSet states)) of
    Just (principal, generation) -> Left (RegisteredClientRetirementMissing principal generation)
    Nothing -> Right (RegisteredClientTable capacity states retired)
 where
  validPrincipal spec = case mkClientPrincipal (clientPrincipalText (registeredClientPrincipal spec)) of
    Left _ -> Left (RegisteredClientPrincipalDefinitionInvalid (registeredClientPrincipal spec))
    Right _ -> Right ()
  checkPair (left, right)
    | registeredClientPrincipal left == registeredClientPrincipal right
        && registeredClientSlot left /= registeredClientSlot right =
        Left (RegisteredClientPrincipalSlotChanged (registeredClientPrincipal left))
    | registeredClientPrincipal left /= registeredClientPrincipal right
        && registeredClientSlot left == registeredClientSlot right =
        Left (RegisteredClientSlotDuplicated (registeredClientSlot left))
    | clientPrincipalCaller (registeredClientPrincipal left)
        == clientPrincipalCaller (registeredClientPrincipal right)
        && registeredClientGeneration left == registeredClientGeneration right =
        case clientPrincipalCaller (registeredClientPrincipal left) of
          Just caller -> Left (RegisteredClientCallerGenerationDuplicated caller (registeredClientGeneration left))
          Nothing -> Left (RegisteredClientPrincipalDefinitionInvalid (registeredClientPrincipal left))
    | otherwise = Right ()

specIdentity :: RegisteredClientSpec -> RegisteredClientIdentity
specIdentity spec = (registeredClientPrincipal spec, registeredClientGeneration spec)

-- | Add definitions and retire membership without dropping any cursor/history.
-- Capacity and all previous definitions are immutable; retirement is monotone.
reconcileRegisteredClientTable
  :: RegisteredClientTable
  -> RegisteredClientTable
  -> Either RegisteredClientTableError RegisteredClientTable
reconcileRegisteredClientTable desired previous = do
  unless
    (registeredClientTableCapacity desired == registeredClientTableCapacity previous)
    (Left RegisteredClientCapacityChanged)
  traverse_ preserve (Map.toAscList (registeredClientStates previous))
  case Set.lookupMin
    (Set.difference (internalRegisteredClientRetired previous) (internalRegisteredClientRetired desired)) of
    Just (principal, generation) -> Left (RegisteredClientRetirementRegressed principal generation)
    Nothing -> Right ()
  pure
    desired
      { registeredClientStates =
          Map.union (registeredClientStates previous) (registeredClientStates desired)
      }
 where
  preserve (identity@(principal, generation), state) =
    unless
      ( fmap registeredClientStateSpec (Map.lookup identity (registeredClientStates desired))
          == Just (registeredClientStateSpec state)
      )
      (Left (RegisteredClientDefinitionChanged principal generation))

registeredClientTableSize :: RegisteredClientTable -> Natural
registeredClientTableSize = fromIntegral . Map.size . registeredClientStates

registeredClientReservationCount
  :: ClientPrincipal -> RegisteredClientTable -> Maybe Natural
registeredClientReservationCount principal table =
  case [state | ((owner, _), state) <- Map.toList (registeredClientStates table), owner == principal] of
    [] -> Nothing
    states -> Just (sum (map (fromIntegral . Map.size . registeredClientReservations) states))

data RegisteredClientTableInvariantError
  = RegisteredClientTableDefinitionInvalid !RegisteredClientTableError
  | RegisteredClientStateGenerationMismatch !ClientPrincipal
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
  case mkVersionedRegisteredClientTable
    (registeredClientTableCapacity table)
    specs
    (internalRegisteredClientRetired table) of
    Left err -> Left (RegisteredClientTableDefinitionInvalid err)
    Right _ -> Right ()
  traverse_ validateState states
 where
  validateState ((mapPrincipal, mapGeneration), client) = do
    let spec = registeredClientStateSpec client
        specPrincipal = registeredClientPrincipal spec
        reservationCount = fromIntegral (Map.size (registeredClientReservations client))
        maximumReservations = registeredClientMaximumReservations spec
        highWater = registeredClientSequenceHighWater client
    if mapPrincipal == specPrincipal
      then Right ()
      else Left (RegisteredClientStateKeyMismatch mapPrincipal specPrincipal)
    unless
      (mapGeneration == registeredClientGeneration spec)
      (Left (RegisteredClientStateGenerationMismatch specPrincipal))
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
-- key generations, retired membership, and per-client reservation ceilings.  Evolving cursors and
-- reservations are deliberately ignored.
registeredClientTableConfigurationMatches
  :: RegisteredClientTable -> RegisteredClientTable -> Bool
registeredClientTableConfigurationMatches expected observed =
  registeredClientTableCapacity expected == registeredClientTableCapacity observed
    && internalRegisteredClientRetired expected == internalRegisteredClientRetired observed
    && specifications expected == specifications observed
 where
  specifications = Map.map registeredClientStateSpec . registeredClientStates

registeredClientReservationBindings
  :: RegisteredClientTable
  -> [(ClientId, ClientSequence, RequestDigest, AuthorityEpoch)]
registeredClientReservationBindings table =
  [ (client, sequenceNumber, digest, epoch)
  | (_, client, sequenceNumber, digest, epoch) <-
      registeredClientReservationEntries table
  ]

-- | Exact retained key-to-operation join for future admission-epoch
-- validation. This is a read-only projection: it cannot reserve, settle, or
-- compact an operation.
registeredClientReservationEntries
  :: RegisteredClientTable
  -> [ ( ClientSubmissionKey
       , ClientId
       , ClientSequence
       , RequestDigest
       , AuthorityEpoch
       )
     ]
registeredClientReservationEntries table =
  [ ( submissionKey
    , registeredClientId (registeredClientStateSpec client)
    , registeredReservationSequence reservation
    , registeredReservationDigest reservation
    , registeredReservationEpoch reservation
    )
  | client <- Map.elems (registeredClientStates table)
  , (submissionKey, reservation) <-
      Map.toAscList (registeredClientReservations client)
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
  case callerState caller generation table of
    Left refusal -> RegisteredSubmissionKnown refusal
    Right (_, client) -> case Map.lookup submissionKey (registeredClientReservations client) of
      Nothing -> RegisteredSubmissionFresh
      Just reservation -> RegisteredSubmissionKnown (replayExistingSubmission ledger client reservation digest)

callerState
  :: CallerPrincipal
  -> RegisteredClientGeneration
  -> RegisteredClientTable
  -> Either RegisteredSubmissionDecision (RegisteredClientIdentity, RegisteredClientState)
callerState caller generation table =
  case filter ((== generation) . snd . fst) candidates of
    [entry@(identity, _)]
      | identity `Set.member` internalRegisteredClientRetired table ->
          Left RegisteredSubmissionRefusedUnregistered
      | otherwise -> Right entry
    [] -> case [ keyGeneration
               | (identity@(_, keyGeneration), _) <- candidates
               , identity `Set.notMember` internalRegisteredClientRetired table
               ] of
      [] -> Left RegisteredSubmissionRefusedUnregistered
      active -> Left (RegisteredSubmissionRefusedGenerationMismatch (maximum active) generation)
    _ -> Left RegisteredSubmissionRefusedUnregistered
 where
  candidates =
    [ (identity, state)
    | (identity@(principal, _), state) <- Map.toAscList (registeredClientStates table)
    , clientPrincipalCaller principal == Just caller
    ]

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
      case callerState caller generation table of
        Left refusal -> unchanged refusal
        Right (identity, client) -> reserveFresh identity client
 where
  unchanged decision = (decision, ledger, table)
  reserveFresh identity client
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
                            Map.insert identity nextClient (registeredClientStates table)
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
  = RegisteredSubmissionObserved !OperationId !SubmissionStatus
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
  case callerState caller generation table of
    Left (RegisteredSubmissionRefusedGenerationMismatch expected actual) ->
      RegisteredSubmissionObserveRefusedGenerationMismatch expected actual
    Left _ -> RegisteredSubmissionObserveRefusedUnregistered
    Right (_, client) -> case Map.lookup submissionKey (registeredClientReservations client) of
      Nothing -> RegisteredSubmissionUnknown
      Just reservation ->
        let operationId = operationIdFor client reservation
         in case submissionStatus
              (registeredClientId (registeredClientStateSpec client))
              (registeredReservationSequence reservation)
              ledger of
              StatusUnknown -> RegisteredSubmissionObserveDiverged
              status -> RegisteredSubmissionObserved operationId status

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
