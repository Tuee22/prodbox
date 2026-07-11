{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded admission for gateway Orders documents.
--
-- Raw source size and literal-only syntax are checked before the generic Dhall
-- decoder runs. The decoded document is then validated against positive member
-- and field bounds before an opaque 'AdmittedOrders' value is exposed.
module Prodbox.Gateway.Orders
  ( OrdersLimits (..)
  , OrdersLimitField (..)
  , OrdersMemberField (..)
  , RawOrdersDocument (..)
  , RawOrdersMember (..)
  , OrdersAdmissionBasis (..)
  , LiteralOrdersSource
  , AdmittedOrders
  , AdmittedOrdersMember
  , OrdersAnchor
  , OrdersHashWitness
  , FirstAdmissionWitness
  , OrdersAdmissionError (..)
  , preflightOrdersSource
  , admitDecodedOrders
  , admitOrdersDhall
  , admittedOrdersVersion
  , admittedOrdersMembers
  , admittedOrdersRankedMembers
  , admittedOrdersHeartbeatTimeoutSeconds
  , admittedOrdersAnchor
  , admittedOrdersHashWitness
  , admittedOrdersFirstAdmissionWitness
  , admittedMemberNodeId
  , admittedMemberEndpoint
  , admittedMemberTrustKey
  , admittedMemberEncodedState
  , ordersAnchorVersion
  , ordersAnchorHash
  , ordersHashHex
  )
where

import Control.Exception (SomeException, displayException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (find, sortOn)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall (FromDhall)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import Dhall.Parser qualified as DhallParser
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)

-- | Authored bounds for one Orders document. Every field is required to be
-- strictly positive before source parsing or decoding begins.
data OrdersLimits = OrdersLimits
  { ordersMaxRawBytes :: Natural
  , ordersMaxMembers :: Natural
  , ordersMaxNodeIdBytes :: Natural
  , ordersMaxEndpointBytes :: Natural
  , ordersMaxTrustKeyBytes :: Natural
  , ordersMaxEncodedStateBytes :: Natural
  }
  deriving (Eq, Show)

data OrdersLimitField
  = MaxRawOrdersBytes
  | MaxOrdersMembers
  | MaxMemberNodeIdBytes
  | MaxMemberEndpointBytes
  | MaxMemberTrustKeyBytes
  | MaxMemberEncodedStateBytes
  deriving (Bounded, Enum, Eq, Show)

data OrdersMemberField
  = MemberNodeId
  | MemberEndpoint
  | MemberTrustKey
  | MemberEncodedState
  | RankedMemberNodeId
  deriving (Bounded, Enum, Eq, Show)

-- | Decode-boundary DTO. It intentionally contains no maps or snapshots: all
-- cardinality and byte validation happens before those structures are built.
data RawOrdersDocument = RawOrdersDocument
  { version_utc :: Natural
  , members :: [RawOrdersMember]
  , ranked_members :: [Text]
  , heartbeat_timeout_seconds :: Natural
  }
  deriving (Eq, Generic, FromDhall)

instance Show RawOrdersDocument where
  show orders =
    "RawOrdersDocument { version_utc = "
      ++ show (version_utc orders)
      ++ ", members = <redacted>, ranked_members = "
      ++ show (ranked_members orders)
      ++ ", heartbeat_timeout_seconds = "
      ++ show (heartbeat_timeout_seconds orders)
      ++ " }"

data RawOrdersMember = RawOrdersMember
  { node_id :: Text
  , endpoint :: Text
  , trust_key :: Text
  , encoded_state :: Text
  }
  deriving (Eq, Generic, FromDhall)

instance Show RawOrdersMember where
  show member =
    "RawOrdersMember { node_id = "
      ++ show (node_id member)
      ++ ", endpoint = "
      ++ show (endpoint member)
      ++ ", trust_key = <redacted>, encoded_state = <redacted> }"

-- | First admission is explicit. A successor must carry the opaque anchor
-- obtained from the previously admitted document.
data OrdersAdmissionBasis
  = FirstOrdersAdmission
  | SuccessorOrdersAdmission OrdersAnchor
  deriving (Eq, Show)

data ValidatedOrdersLimits = ValidatedOrdersLimits
  { validatedMaxRawBytes :: Natural
  , validatedMaxMembers :: Natural
  , validatedMaxNodeIdBytes :: Natural
  , validatedMaxEndpointBytes :: Natural
  , validatedMaxTrustKeyBytes :: Natural
  , validatedMaxEncodedStateBytes :: Natural
  }
  deriving (Eq, Show)

-- | Proof that the source passed the raw-byte and literal-syntax gate. Its
-- constructor is hidden, so generic decoding cannot be invoked through this
-- module for imported, computed, or oversized Dhall.
data LiteralOrdersSource = LiteralOrdersSource
  { literalOrdersSourceText :: Text
  , literalOrdersSourceLimits :: ValidatedOrdersLimits
  }
  deriving (Eq)

instance Show LiteralOrdersSource where
  show source =
    "LiteralOrdersSource { source = <redacted>, limits = "
      ++ show (literalOrdersSourceLimits source)
      ++ " }"

data AdmittedOrdersMember = AdmittedOrdersMember
  { validatedMemberNodeId :: Text
  , validatedMemberEndpoint :: Text
  , validatedMemberTrustKey :: Text
  , validatedMemberEncodedState :: Text
  }
  deriving (Eq)

instance Show AdmittedOrdersMember where
  show member =
    "AdmittedOrdersMember { node_id = "
      ++ show (validatedMemberNodeId member)
      ++ ", endpoint = "
      ++ show (validatedMemberEndpoint member)
      ++ ", trust_key = <redacted>, encoded_state = <redacted> }"

newtype OrdersHashWitness = OrdersHashWitness Text
  deriving (Eq, Ord, Show)

data OrdersAnchor = OrdersAnchor
  { validatedAnchorVersion :: Natural
  , validatedAnchorHash :: OrdersHashWitness
  }
  deriving (Eq, Show)

newtype FirstAdmissionWitness = FirstAdmissionWitness OrdersAnchor
  deriving (Eq, Show)

data AdmittedOrders = AdmittedOrders
  { validatedOrdersVersion :: Natural
  , validatedOrdersMembers :: [AdmittedOrdersMember]
  , validatedOrdersRankedMembers :: [Text]
  , validatedOrdersHeartbeatTimeoutSeconds :: Natural
  , validatedOrdersAnchor :: OrdersAnchor
  , validatedOrdersHashWitness :: OrdersHashWitness
  , validatedOrdersFirstAdmissionWitness :: Maybe FirstAdmissionWitness
  }
  deriving (Eq)

instance Show AdmittedOrders where
  show orders =
    "AdmittedOrders { version = "
      ++ show (validatedOrdersVersion orders)
      ++ ", members = <redacted>, ranked_members = "
      ++ show (validatedOrdersRankedMembers orders)
      ++ ", heartbeat_timeout_seconds = "
      ++ show (validatedOrdersHeartbeatTimeoutSeconds orders)
      ++ ", anchor = "
      ++ show (validatedOrdersAnchor orders)
      ++ " }"

data OrdersAdmissionError
  = OrdersLimitMustBePositive OrdersLimitField
  | OrdersRawSourceTooLarge
      { actualRawOrdersBytes :: Natural
      , allowedRawOrdersBytes :: Natural
      }
  | OrdersSourceParseFailed Text
  | OrdersSourceMustBeLiteral
  | OrdersDhallDecodeFailed Text
  | OrdersVersionMustBePositive
  | OrdersHeartbeatTimeoutMustBePositive
  | OrdersMemberCountMustBePositive
  | OrdersMemberCountExceedsLimit
      { actualOrdersMemberCount :: Natural
      , allowedOrdersMemberCount :: Natural
      }
  | OrdersMemberFieldMustNotBeEmpty
      { invalidOrdersMemberIndex :: Natural
      , invalidOrdersMemberField :: OrdersMemberField
      }
  | OrdersMemberFieldExceedsLimit
      { invalidOrdersMemberIndex :: Natural
      , invalidOrdersMemberField :: OrdersMemberField
      , actualOrdersMemberFieldBytes :: Natural
      , allowedOrdersMemberFieldBytes :: Natural
      }
  | DuplicateOrdersMemberId Text
  | DuplicateRankedMemberId Text
  | RankedMemberUnknown Text
  | OrdersMemberMissingFromRanking Text
  | OrdersVersionNotNewer
      { previousOrdersVersion :: Natural
      , proposedOrdersVersion :: Natural
      }
  | OrdersHashMatchesPreviousAnchor
  deriving (Eq, Show)

-- | Validate bounds, enforce the raw UTF-8 byte ceiling, parse only enough to
-- prove literal syntax, and return the opaque token accepted by the decoder.
-- Size rejection deliberately precedes syntax parsing.
preflightOrdersSource
  :: OrdersLimits
  -> Text
  -> Either OrdersAdmissionError LiteralOrdersSource
preflightOrdersSource limits source = do
  validatedLimits <- validateOrdersLimits limits
  let sourceBytes = TextEncoding.encodeUtf8 source
      actualBytes = fromIntegral (BS.length sourceBytes)
      allowedBytes = validatedMaxRawBytes validatedLimits
  if actualBytes > allowedBytes
    then
      Left
        OrdersRawSourceTooLarge
          { actualRawOrdersBytes = actualBytes
          , allowedRawOrdersBytes = allowedBytes
          }
    else do
      expression <-
        case DhallParser.exprFromText "gateway-orders" source of
          Left parseError -> Left (OrdersSourceParseFailed (Text.pack (show parseError)))
          Right parsed -> Right parsed
      if isLiteralOrdersExpression expression
        then
          Right
            LiteralOrdersSource
              { literalOrdersSourceText = source
              , literalOrdersSourceLimits = validatedLimits
              }
        else Left OrdersSourceMustBeLiteral

-- | Admit an already-decoded DTO. This is the pure validation seam used by
-- unit tests and by 'admitOrdersDhall' after the opaque source gate.
admitDecodedOrders
  :: LiteralOrdersSource
  -> OrdersAdmissionBasis
  -> RawOrdersDocument
  -> Either OrdersAdmissionError AdmittedOrders
admitDecodedOrders literalSource admissionBasis rawOrders = do
  let limits = literalOrdersSourceLimits literalSource
      rawMembers = members rawOrders
      memberCount = fromIntegral (length rawMembers)
  if version_utc rawOrders > 0
    then Right ()
    else Left OrdersVersionMustBePositive
  if heartbeat_timeout_seconds rawOrders > 0
    then Right ()
    else Left OrdersHeartbeatTimeoutMustBePositive
  if memberCount > 0
    then Right ()
    else Left OrdersMemberCountMustBePositive
  if memberCount <= validatedMaxMembers limits
    then Right ()
    else
      Left
        OrdersMemberCountExceedsLimit
          { actualOrdersMemberCount = memberCount
          , allowedOrdersMemberCount = validatedMaxMembers limits
          }
  validatedMembers <-
    traverse
      (uncurry (validateOrdersMember limits))
      (zip [0 ..] rawMembers)
  validateUniqueMemberIds validatedMembers
  validateRanking limits validatedMembers (ranked_members rawOrders)
  let hashWitness =
        hashAdmittedOrders
          (version_utc rawOrders)
          validatedMembers
          (ranked_members rawOrders)
          (heartbeat_timeout_seconds rawOrders)
      anchor = OrdersAnchor (version_utc rawOrders) hashWitness
  firstWitness <- validateAdmissionBasis admissionBasis anchor
  Right
    AdmittedOrders
      { validatedOrdersVersion = version_utc rawOrders
      , validatedOrdersMembers = validatedMembers
      , validatedOrdersRankedMembers = ranked_members rawOrders
      , validatedOrdersHeartbeatTimeoutSeconds = heartbeat_timeout_seconds rawOrders
      , validatedOrdersAnchor = anchor
      , validatedOrdersHashWitness = hashWitness
      , validatedOrdersFirstAdmissionWitness = firstWitness
      }

-- | Complete source-gate, generic-decode, and structural admission path.
admitOrdersDhall
  :: OrdersLimits
  -> OrdersAdmissionBasis
  -> Text
  -> IO (Either OrdersAdmissionError AdmittedOrders)
admitOrdersDhall limits admissionBasis source =
  case preflightOrdersSource limits source of
    Left admissionError -> pure (Left admissionError)
    Right literalSource -> do
      decodeResult <-
        try (Dhall.input Dhall.auto (literalOrdersSourceText literalSource))
          :: IO (Either SomeException RawOrdersDocument)
      pure $ case decodeResult of
        Left decodeError ->
          Left (OrdersDhallDecodeFailed (Text.pack (displayException decodeError)))
        Right rawOrders -> admitDecodedOrders literalSource admissionBasis rawOrders

admittedOrdersVersion :: AdmittedOrders -> Natural
admittedOrdersVersion = validatedOrdersVersion

admittedOrdersMembers :: AdmittedOrders -> [AdmittedOrdersMember]
admittedOrdersMembers = validatedOrdersMembers

admittedOrdersRankedMembers :: AdmittedOrders -> [Text]
admittedOrdersRankedMembers = validatedOrdersRankedMembers

admittedOrdersHeartbeatTimeoutSeconds :: AdmittedOrders -> Natural
admittedOrdersHeartbeatTimeoutSeconds = validatedOrdersHeartbeatTimeoutSeconds

admittedOrdersAnchor :: AdmittedOrders -> OrdersAnchor
admittedOrdersAnchor = validatedOrdersAnchor

admittedOrdersHashWitness :: AdmittedOrders -> OrdersHashWitness
admittedOrdersHashWitness = validatedOrdersHashWitness

admittedOrdersFirstAdmissionWitness :: AdmittedOrders -> Maybe FirstAdmissionWitness
admittedOrdersFirstAdmissionWitness = validatedOrdersFirstAdmissionWitness

admittedMemberNodeId :: AdmittedOrdersMember -> Text
admittedMemberNodeId = validatedMemberNodeId

admittedMemberEndpoint :: AdmittedOrdersMember -> Text
admittedMemberEndpoint = validatedMemberEndpoint

admittedMemberTrustKey :: AdmittedOrdersMember -> Text
admittedMemberTrustKey = validatedMemberTrustKey

admittedMemberEncodedState :: AdmittedOrdersMember -> Text
admittedMemberEncodedState = validatedMemberEncodedState

ordersAnchorVersion :: OrdersAnchor -> Natural
ordersAnchorVersion = validatedAnchorVersion

ordersAnchorHash :: OrdersAnchor -> OrdersHashWitness
ordersAnchorHash = validatedAnchorHash

ordersHashHex :: OrdersHashWitness -> Text
ordersHashHex (OrdersHashWitness hashText) = hashText

validateOrdersLimits :: OrdersLimits -> Either OrdersAdmissionError ValidatedOrdersLimits
validateOrdersLimits limits = do
  requirePositiveLimit MaxRawOrdersBytes (ordersMaxRawBytes limits)
  requirePositiveLimit MaxOrdersMembers (ordersMaxMembers limits)
  requirePositiveLimit MaxMemberNodeIdBytes (ordersMaxNodeIdBytes limits)
  requirePositiveLimit MaxMemberEndpointBytes (ordersMaxEndpointBytes limits)
  requirePositiveLimit MaxMemberTrustKeyBytes (ordersMaxTrustKeyBytes limits)
  requirePositiveLimit MaxMemberEncodedStateBytes (ordersMaxEncodedStateBytes limits)
  Right
    ValidatedOrdersLimits
      { validatedMaxRawBytes = ordersMaxRawBytes limits
      , validatedMaxMembers = ordersMaxMembers limits
      , validatedMaxNodeIdBytes = ordersMaxNodeIdBytes limits
      , validatedMaxEndpointBytes = ordersMaxEndpointBytes limits
      , validatedMaxTrustKeyBytes = ordersMaxTrustKeyBytes limits
      , validatedMaxEncodedStateBytes = ordersMaxEncodedStateBytes limits
      }

requirePositiveLimit
  :: OrdersLimitField -> Natural -> Either OrdersAdmissionError ()
requirePositiveLimit field value
  | value > 0 = Right ()
  | otherwise = Left (OrdersLimitMustBePositive field)

isLiteralOrdersExpression :: Core.Expr s a -> Bool
isLiteralOrdersExpression expression =
  case expression of
    Core.Note _ nested -> isLiteralOrdersExpression nested
    Core.RecordLit fields ->
      all
        (isLiteralOrdersExpression . Core.recordFieldValue . snd)
        (DhallMap.toList fields)
    Core.ListLit Nothing values -> all isLiteralOrdersExpression values
    Core.TextLit (Core.Chunks interpolations _) -> null interpolations
    Core.NaturalLit _ -> True
    Core.BoolLit _ -> True
    Core.BytesLit _ -> True
    _ -> False

validateOrdersMember
  :: ValidatedOrdersLimits
  -> Natural
  -> RawOrdersMember
  -> Either OrdersAdmissionError AdmittedOrdersMember
validateOrdersMember limits memberIndex rawMember = do
  validateMemberField memberIndex MemberNodeId (validatedMaxNodeIdBytes limits) (node_id rawMember)
  validateMemberField
    memberIndex
    MemberEndpoint
    (validatedMaxEndpointBytes limits)
    (endpoint rawMember)
  validateMemberField
    memberIndex
    MemberTrustKey
    (validatedMaxTrustKeyBytes limits)
    (trust_key rawMember)
  validateMemberField
    memberIndex
    MemberEncodedState
    (validatedMaxEncodedStateBytes limits)
    (encoded_state rawMember)
  Right
    AdmittedOrdersMember
      { validatedMemberNodeId = node_id rawMember
      , validatedMemberEndpoint = endpoint rawMember
      , validatedMemberTrustKey = trust_key rawMember
      , validatedMemberEncodedState = encoded_state rawMember
      }

validateMemberField
  :: Natural
  -> OrdersMemberField
  -> Natural
  -> Text
  -> Either OrdersAdmissionError ()
validateMemberField memberIndex field allowedBytes value =
  let actualBytes = utf8Length value
   in if actualBytes == 0
        then
          Left
            OrdersMemberFieldMustNotBeEmpty
              { invalidOrdersMemberIndex = memberIndex
              , invalidOrdersMemberField = field
              }
        else
          if actualBytes > allowedBytes
            then
              Left
                OrdersMemberFieldExceedsLimit
                  { invalidOrdersMemberIndex = memberIndex
                  , invalidOrdersMemberField = field
                  , actualOrdersMemberFieldBytes = actualBytes
                  , allowedOrdersMemberFieldBytes = allowedBytes
                  }
            else Right ()

validateUniqueMemberIds
  :: [AdmittedOrdersMember] -> Either OrdersAdmissionError ()
validateUniqueMemberIds admittedMembers =
  case firstDuplicate (map admittedMemberNodeId admittedMembers) of
    Nothing -> Right ()
    Just duplicateId -> Left (DuplicateOrdersMemberId duplicateId)

validateRanking
  :: ValidatedOrdersLimits
  -> [AdmittedOrdersMember]
  -> [Text]
  -> Either OrdersAdmissionError ()
validateRanking limits admittedMembers rankedIds = do
  mapM_
    (uncurry validateRankedId)
    (zip [0 ..] rankedIds)
  case firstDuplicate rankedIds of
    Nothing -> Right ()
    Just duplicateId -> Left (DuplicateRankedMemberId duplicateId)
  let memberIds = Set.fromList (map admittedMemberNodeId admittedMembers)
      rankedSet = Set.fromList rankedIds
  case find (`Set.notMember` memberIds) rankedIds of
    Just unknownId -> Left (RankedMemberUnknown unknownId)
    Nothing -> Right ()
  case Set.lookupMin (memberIds `Set.difference` rankedSet) of
    Just missingId -> Left (OrdersMemberMissingFromRanking missingId)
    Nothing -> Right ()
 where
  validateRankedId index rankedId =
    validateMemberField
      index
      RankedMemberNodeId
      (validatedMaxNodeIdBytes limits)
      rankedId

validateAdmissionBasis
  :: OrdersAdmissionBasis
  -> OrdersAnchor
  -> Either OrdersAdmissionError (Maybe FirstAdmissionWitness)
validateAdmissionBasis admissionBasis proposedAnchor =
  case admissionBasis of
    FirstOrdersAdmission -> Right (Just (FirstAdmissionWitness proposedAnchor))
    SuccessorOrdersAdmission previousAnchor ->
      if ordersAnchorVersion proposedAnchor <= ordersAnchorVersion previousAnchor
        then
          Left
            OrdersVersionNotNewer
              { previousOrdersVersion = ordersAnchorVersion previousAnchor
              , proposedOrdersVersion = ordersAnchorVersion proposedAnchor
              }
        else
          if ordersAnchorHash proposedAnchor == ordersAnchorHash previousAnchor
            then Left OrdersHashMatchesPreviousAnchor
            else Right Nothing

-- | Hash a canonical semantic encoding rather than source text. Record-field
-- order, whitespace, and the non-semantic order of the member declaration list
-- therefore cannot fork continuity anchors for equivalent admitted Orders.
hashAdmittedOrders
  :: Natural
  -> [AdmittedOrdersMember]
  -> [Text]
  -> Natural
  -> OrdersHashWitness
hashAdmittedOrders version admittedMembers rankedIds heartbeatTimeout =
  OrdersHashWitness
    (Text.pack (concatMap renderHexByte (BS.unpack (SHA256.hash canonicalBytes))))
 where
  canonicalBytes =
    LazyByteString.toStrict
      ( Builder.toLazyByteString
          ( Builder.string8 "prodbox.gateway.orders.v1;"
              <> encodeCanonicalNatural version
              <> encodeCanonicalList encodeCanonicalMember canonicalMembers
              <> encodeCanonicalList encodeCanonicalText rankedIds
              <> encodeCanonicalNatural heartbeatTimeout
          )
      )
  canonicalMembers = sortOn admittedMemberNodeId admittedMembers

encodeCanonicalMember :: AdmittedOrdersMember -> Builder.Builder
encodeCanonicalMember member =
  encodeCanonicalText (admittedMemberNodeId member)
    <> encodeCanonicalText (admittedMemberEndpoint member)
    <> encodeCanonicalText (admittedMemberTrustKey member)
    <> encodeCanonicalText (admittedMemberEncodedState member)

encodeCanonicalNatural :: Natural -> Builder.Builder
encodeCanonicalNatural value =
  Builder.char8 'n'
    <> Builder.string8 (show value)
    <> Builder.char8 ';'

encodeCanonicalText :: Text -> Builder.Builder
encodeCanonicalText value =
  Builder.char8 't'
    <> Builder.string8 (show (BS.length encoded))
    <> Builder.char8 ':'
    <> Builder.byteString encoded
 where
  encoded = TextEncoding.encodeUtf8 value

encodeCanonicalList
  :: (value -> Builder.Builder)
  -> [value]
  -> Builder.Builder
encodeCanonicalList encodeValue values =
  Builder.char8 '['
    <> encodeCanonicalNatural (fromIntegral (length values))
    <> foldMap encodeValue values
    <> Builder.char8 ']'

renderHexByte :: (Integral value, Show value) => value -> String
renderHexByte value =
  case showHex value "" of
    [digit] -> ['0', digit]
    digits -> digits

utf8Length :: Text -> Natural
utf8Length = fromIntegral . BS.length . TextEncoding.encodeUtf8

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
 where
  go :: (Ord value) => Set value -> [value] -> Maybe value
  go _ [] = Nothing
  go seen (value : remaining)
    | value `Set.member` seen = Just value
    | otherwise = go (Set.insert value seen) remaining
