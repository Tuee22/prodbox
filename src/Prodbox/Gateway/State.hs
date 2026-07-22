{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Pure bounded semantic state and cursor-delta replication for the gateway.
--
-- This module intentionally contains no compatibility representation for the
-- historical append-only commit log.  Every map is seeded from validated
-- Orders, every sequence is trimmed at insertion, and delta application is an
-- atomic fold over a bounded frame.
module Prodbox.Gateway.State
  ( -- * Bounded Orders admission
    RawGatewayMember (..)
  , RawOrders (..)
  , MemberField (..)
  , NodeId
  , nodeIdText
  , OrdersVersion
  , ordersVersionFromInt
  , ordersVersionValue
  , OrdersHash
  , OrdersAnchor
  , ordersAnchorVersion
  , ordersAnchorHashBytes
  , ValidatedOrders
  , validateOrders
  , validatedOrdersAnchor
  , validatedOrdersMemberIds
  , validatedOrdersMemberCount

    -- * Fixed-width emitter continuity
  , EventHash
  , mkEventHash
  , eventHashBytes
  , EmitterIncarnation
  , emitterIncarnationZero
  , mkEmitterIncarnation
  , emitterIncarnationValue
  , EmitterEpoch
  , emitterEpochValue
  , EmitterSequence
  , emitterSequenceValue
  , EmitterCursor
  , initialEmitterCursor
  , restoredEmitterCursor
  , emitterCursorEpoch
  , emitterCursorSequence
  , emitterCursorHash

    -- * Signed semantic assertions
  , OwnershipDecision (..)
  , OrdersMigrationScope
  , mkOrdersMigrationScope
  , ordersMigrationPreviousEpoch
  , ordersMigrationPreviousSequence
  , ordersMigrationPreviousOrdersDigest
  , AssertionKind (..)
  , GatewayAssertion
  , mkNextAssertion
  , mkNextAssertionForIncarnation
  , mkEpochRotationAssertion
  , mkEpochRotationAssertionForIncarnation
  , mkOrdersMigrationAssertionForIncarnation
  , assertionEmitter
  , assertionIncarnation
  , assertionOrdersAnchor
  , assertionKind
  , assertionPreviousHash
  , assertionResultCursor
  , assertionEncodedBytes

    -- * Bounded replica state
  , GatewayState
  , initializeGatewayState
  , restoreEmitterFromContinuity
  , restoreEmitterFromContinuityForIncarnation
  , AssertionApplyOutcome (..)
  , applyGatewayAssertion
  , gatewayStateActiveOrders
  , gatewayStateStagedOrders
  , gatewayStateEmitterCount
  , gatewayStateReplayCount
  , gatewayStateDiagnosticHashes
  , gatewayStateLatestHeartbeat
  , gatewayStateLatestOwnership
  , gatewayStateEmitterIncarnation
  , gatewayStateCursorVector
  , armOrdersMigrationAdmission
  , rearmOrdersMigrationAdmissionForEmitter
  , gatewayStateOrdersMigrationPendingCount

    -- * Deterministic semantic compaction checkpoints
  , EmitterCheckpoint
  , mkEmitterCheckpoint
  , mkEmitterCheckpointForIncarnation
  , emitterCheckpointOrdersAnchor
  , emitterCheckpointEmitter
  , emitterCheckpointIncarnation
  , emitterCheckpointCursor
  , emitterCheckpointHeartbeat
  , emitterCheckpointOwnership
  , gatewayStateEmitterCheckpoint
  , EmitterRepair
  , mkEmitterRepair
  , emitterRepairAssertionCount
  , emitterRepairEncodedBytes
  , RepairApplyOutcome (..)
  , applyEmitterRepair
  , restoreEmitterFromRetainedRepair

    -- * Orders promotion (active + one slot)
  , stageOrdersPromotion
  , activateOrdersPromotion

    -- * Cursor vectors and bounded deltas
  , CursorVector
  , mkCursorVector
  , cursorVectorSize
  , cursorVectorLookup
  , DeltaFrame
  , mkDeltaFrame
  , selectDelta
  , deltaFrameAssertionCount
  , deltaFrameEncodedBytes
  , deltaFrameBaseCursor
  , deltaFrameResultingCursor
  , DeltaApplyOutcome (..)
  , applyDelta

    -- * Bounded rejection diagnostics
  , RejectionReason (..)
  , RejectionSample (..)
  , RejectionSummary
  , rejectionCount
  , rejectionSamples
  , gatewayStateRejectionSummary

    -- * Structured failures
  , HashKind (..)
  , GatewayStateError (..)
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (foldM, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList, traverse_)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Gateway.Bounds
  ( GatewayBounds
  , gatewayDiagnosticHashCapacity
  , gatewayMaxAssertionsPerFrame
  , gatewayMaxEncodedAssertionBytes
  , gatewayMaxEncodedMemberBytes
  , gatewayMaxEndpointBytes
  , gatewayMaxFrameBytes
  , gatewayMaxMembers
  , gatewayMaxNodeIdBytes
  , gatewayMaxOrdersBytes
  , gatewayMaxRejectionSamples
  , gatewayMaxTrustKeyBytes
  , gatewayReplayPerEmitter
  )

newtype NodeId = NodeId Text
  deriving (Eq, Ord, Show)

nodeIdText :: NodeId -> Text
nodeIdText (NodeId value) = value

newtype OrdersVersion = OrdersVersion Word64
  deriving (Eq, Ord, Show)

-- | Check the signed version representation used by the existing daemon
-- before converting it to the fixed-width protocol representation.  Keeping
-- this conversion total prevents a negative 'Int' from wrapping through
-- 'fromIntegral' into a very large 'Word64'.
ordersVersionFromInt :: Int -> Either GatewayStateError OrdersVersion
ordersVersionFromInt value
  | value <= 0 = Left (OrdersVersionMustBePositive value)
  | otherwise = Right (OrdersVersion (fromIntegral value))

ordersVersionValue :: OrdersVersion -> Word64
ordersVersionValue (OrdersVersion value) = value

newtype OrdersHash = OrdersHash ByteString
  deriving (Eq, Ord, Show)

data OrdersAnchor = OrdersAnchor
  { internalOrdersAnchorVersion :: OrdersVersion
  , internalOrdersAnchorHash :: OrdersHash
  }
  deriving (Eq, Ord, Show)

ordersAnchorVersion :: OrdersAnchor -> OrdersVersion
ordersAnchorVersion = internalOrdersAnchorVersion

ordersAnchorHashBytes :: OrdersAnchor -> ByteString
ordersAnchorHashBytes (OrdersAnchor _ (OrdersHash value)) = value

data RawGatewayMember = RawGatewayMember
  { rawMemberNodeId :: Text
  , rawMemberEndpoint :: Text
  , rawMemberTrustKey :: ByteString
  , rawMemberRank :: Word64
  }
  deriving (Eq)

instance Show RawGatewayMember where
  show raw =
    "RawGatewayMember {rawMemberNodeId = "
      ++ show (rawMemberNodeId raw)
      ++ ", rawMemberEndpoint = "
      ++ show (rawMemberEndpoint raw)
      ++ ", rawMemberTrustKey = <redacted:"
      ++ show (BS.length (rawMemberTrustKey raw))
      ++ " bytes>, rawMemberRank = "
      ++ show (rawMemberRank raw)
      ++ "}"

data RawOrders = RawOrders
  { rawOrdersDocument :: ByteString
  , rawOrdersVersion :: Int
  , rawOrdersMembers :: [RawGatewayMember]
  }
  deriving (Eq)

instance Show RawOrders where
  show raw =
    "RawOrders {rawOrdersDocument = <"
      ++ show (BS.length (rawOrdersDocument raw))
      ++ " bytes>, rawOrdersVersion = "
      ++ show (rawOrdersVersion raw)
      ++ ", rawOrdersMembers = <"
      ++ show (length (rawOrdersMembers raw))
      ++ " members>}"

data AdmittedMember = AdmittedMember
  { admittedMemberNodeId :: NodeId
  , admittedMemberEndpoint :: Text
  , admittedMemberTrustKey :: ByteString
  , admittedMemberRank :: Word64
  }
  deriving (Eq)

data ValidatedOrders = ValidatedOrders
  { internalValidatedOrdersAnchor :: OrdersAnchor
  , internalValidatedOrdersMembers :: Map NodeId AdmittedMember
  , internalValidatedOrdersBytes :: Natural
  }
  deriving (Eq)

-- Deliberately omit admitted member values: their trust material must not be
-- disclosed through the transitive 'Show GatewayState' debugging surface.
instance Show ValidatedOrders where
  show orders =
    "ValidatedOrders {anchor = "
      ++ show (validatedOrdersAnchor orders)
      ++ ", memberCount = "
      ++ show (validatedOrdersMemberCount orders)
      ++ ", encodedBytes = "
      ++ show (internalValidatedOrdersBytes orders)
      ++ "}"

validatedOrdersAnchor :: ValidatedOrders -> OrdersAnchor
validatedOrdersAnchor = internalValidatedOrdersAnchor

validatedOrdersMemberIds :: ValidatedOrders -> [NodeId]
validatedOrdersMemberIds = Map.keys . internalValidatedOrdersMembers

validatedOrdersMemberCount :: ValidatedOrders -> Int
validatedOrdersMemberCount = Map.size . internalValidatedOrdersMembers

data HashKind = EventHashValue | OrdersMigrationOrdersDigest
  deriving (Eq, Show)

-- | Validate raw Orders bytes and every member before constructing the member
-- map.  Duplicate identities and ranks are rejected rather than overwritten.
validateOrders
  :: GatewayBounds
  -> RawOrders
  -> Either GatewayStateError ValidatedOrders
validateOrders bounds raw = do
  let documentBytes = fromIntegral (BS.length (rawOrdersDocument raw))
      rawMembers = rawOrdersMembers raw
      memberCount = length rawMembers
  when (documentBytes == 0) (Left OrdersDocumentMustNotBeEmpty)
  when
    (documentBytes > gatewayMaxOrdersBytes bounds)
    (Left (OrdersDocumentTooLarge documentBytes (gatewayMaxOrdersBytes bounds)))
  when (memberCount == 0) (Left OrdersMembersMustNotBeEmpty)
  when
    (memberCount > gatewayMaxMembers bounds)
    (Left (OrdersMemberCountExceeded memberCount (gatewayMaxMembers bounds)))
  ordersVersion <- ordersVersionFromInt (rawOrdersVersion raw)
  admitted <- traverse (validateMember bounds) rawMembers
  let nodeIds = map admittedMemberNodeId admitted
      ranks = map admittedMemberRank admitted
  unless
    (Set.size (Set.fromList nodeIds) == memberCount)
    (Left OrdersDuplicateMember)
  unless
    (Set.size (Set.fromList ranks) == memberCount)
    (Left OrdersDuplicateRank)
  let members =
        Map.fromList
          [(admittedMemberNodeId member, member) | member <- admitted]
      ordersHash =
        canonicalOrdersHash
          ordersVersion
          (rawOrdersDocument raw)
          members
  Right
    ValidatedOrders
      { internalValidatedOrdersAnchor =
          OrdersAnchor
            { internalOrdersAnchorVersion = ordersVersion
            , internalOrdersAnchorHash = ordersHash
            }
      , internalValidatedOrdersMembers = members
      , internalValidatedOrdersBytes = documentBytes
      }

validateMember
  :: GatewayBounds
  -> RawGatewayMember
  -> Either GatewayStateError AdmittedMember
validateMember bounds raw = do
  nodeId <- mkNodeId bounds (rawMemberNodeId raw)
  let endpointBytes = textBytes (rawMemberEndpoint raw)
      trustBytes = fromIntegral (BS.length (rawMemberTrustKey raw))
      encodedBytes =
        textBytes (rawMemberNodeId raw) + endpointBytes + trustBytes
  when (endpointBytes == 0) (Left (OrdersMemberFieldMustNotBeEmpty nodeId EndpointField))
  when
    (endpointBytes > gatewayMaxEndpointBytes bounds)
    ( Left
        ( OrdersMemberFieldTooLarge
            nodeId
            EndpointField
            endpointBytes
            (gatewayMaxEndpointBytes bounds)
        )
    )
  when (trustBytes == 0) (Left (OrdersMemberFieldMustNotBeEmpty nodeId TrustKeyField))
  when
    (trustBytes > gatewayMaxTrustKeyBytes bounds)
    ( Left
        ( OrdersMemberFieldTooLarge
            nodeId
            TrustKeyField
            trustBytes
            (gatewayMaxTrustKeyBytes bounds)
        )
    )
  when
    (encodedBytes > gatewayMaxEncodedMemberBytes bounds)
    ( Left
        ( OrdersEncodedMemberTooLarge
            nodeId
            encodedBytes
            (gatewayMaxEncodedMemberBytes bounds)
        )
    )
  Right
    AdmittedMember
      { admittedMemberNodeId = nodeId
      , admittedMemberEndpoint = rawMemberEndpoint raw
      , admittedMemberTrustKey = rawMemberTrustKey raw
      , admittedMemberRank = rawMemberRank raw
      }

data MemberField = NodeIdField | EndpointField | TrustKeyField
  deriving (Eq, Show)

mkNodeId :: GatewayBounds -> Text -> Either GatewayStateError NodeId
mkNodeId bounds raw = do
  let bytes = textBytes raw
      stripped = Text.strip raw
  when (Text.null stripped) (Left OrdersNodeIdMustNotBeEmpty)
  when
    (bytes > gatewayMaxNodeIdBytes bounds)
    (Left (OrdersNodeIdTooLarge bytes (gatewayMaxNodeIdBytes bounds)))
  Right (NodeId stripped)

-- | Derive the Orders anchor from one unambiguous encoding of the admitted
-- semantic value.  Members come from a strict Map and are therefore encoded
-- in ascending node-id order; every variable-width field is length-prefixed.
-- The caller supplies no hash witness.
canonicalOrdersHash
  :: OrdersVersion
  -> ByteString
  -> Map NodeId AdmittedMember
  -> OrdersHash
canonicalOrdersHash version canonicalDocument members =
  OrdersHash
    ( SHA256.hash
        ( LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "prodbox.gateway.orders.v1\NUL"
                    <> Builder.word64BE (ordersVersionValue version)
                    <> lengthPrefixed canonicalDocument
                    <> Builder.word64BE (fromIntegral (Map.size members))
                    <> foldMap encodeMember (Map.elems members)
                )
            )
        )
    )
 where
  encodeMember member =
    lengthPrefixed (TextEncoding.encodeUtf8 (nodeIdText (admittedMemberNodeId member)))
      <> lengthPrefixed (TextEncoding.encodeUtf8 (admittedMemberEndpoint member))
      <> lengthPrefixed (admittedMemberTrustKey member)
      <> Builder.word64BE (admittedMemberRank member)

lengthPrefixed :: ByteString -> Builder.Builder
lengthPrefixed value =
  Builder.word64BE (fromIntegral (BS.length value))
    <> Builder.byteString value

newtype EventHash = EventHash ByteString
  deriving (Eq, Ord, Show)

hashWidth :: Int
hashWidth = 32

mkEventHash :: ByteString -> Either GatewayStateError EventHash
mkEventHash raw
  | BS.length raw == hashWidth = Right (EventHash raw)
  | otherwise = Left (HashLengthInvalid EventHashValue hashWidth (BS.length raw))

eventHashBytes :: EventHash -> ByteString
eventHashBytes (EventHash raw) = raw

-- | A durable process-mount fence for one emitter.  It is deliberately
-- separate from the fixed-width continuity cursor: restarting an emitter does
-- not invent a semantic event, but every newly signed event attests the mount
-- that was allowed to emit it.
newtype EmitterIncarnation = EmitterIncarnation Word64
  deriving (Eq, Generic, Ord, Show)

instance Serialise EmitterIncarnation

emitterIncarnationZero :: EmitterIncarnation
emitterIncarnationZero = EmitterIncarnation 0

mkEmitterIncarnation :: Word64 -> EmitterIncarnation
mkEmitterIncarnation = EmitterIncarnation

emitterIncarnationValue :: EmitterIncarnation -> Word64
emitterIncarnationValue (EmitterIncarnation value) = value

newtype EmitterEpoch = EmitterEpoch Word64
  deriving (Eq, Ord, Show)

emitterEpochValue :: EmitterEpoch -> Word64
emitterEpochValue (EmitterEpoch value) = value

newtype EmitterSequence = EmitterSequence Word64
  deriving (Eq, Ord, Show)

emitterSequenceValue :: EmitterSequence -> Word64
emitterSequenceValue (EmitterSequence value) = value

data EmitterCursor = EmitterCursor
  { internalEmitterCursorEpoch :: EmitterEpoch
  , internalEmitterCursorSequence :: EmitterSequence
  , internalEmitterCursorHash :: EventHash
  }
  deriving (Eq, Ord, Show)

initialEmitterCursor :: Word64 -> EventHash -> EmitterCursor
initialEmitterCursor epoch genesisHash =
  restoredEmitterCursor epoch 0 genesisHash

-- | Hydrate the exact fixed-width cursor observed from retained continuity.
-- This does not advance or reset it; subsequent construction still enforces
-- the non-wrapping successor/rotation rules.
restoredEmitterCursor :: Word64 -> Word64 -> EventHash -> EmitterCursor
restoredEmitterCursor epoch sequenceNumber currentHash =
  EmitterCursor
    { internalEmitterCursorEpoch = EmitterEpoch epoch
    , internalEmitterCursorSequence = EmitterSequence sequenceNumber
    , internalEmitterCursorHash = currentHash
    }

emitterCursorEpoch :: EmitterCursor -> EmitterEpoch
emitterCursorEpoch = internalEmitterCursorEpoch

emitterCursorSequence :: EmitterCursor -> EmitterSequence
emitterCursorSequence = internalEmitterCursorSequence

emitterCursorHash :: EmitterCursor -> EventHash
emitterCursorHash = internalEmitterCursorHash

data OwnershipDecision = OwnershipClaim | OwnershipYield
  deriving (Eq, Ord, Show)

-- | HMAC-covered authority for the one exceptional epoch advance caused by an
-- authenticated Orders promotion. The exact prior coordinate and prior Orders
-- digest are signed, preventing the transition from being replayed from a
-- different cursor or scope.
data OrdersMigrationScope = OrdersMigrationScope
  { ordersMigrationPreviousEpoch :: !Word64
  , ordersMigrationPreviousSequence :: !Word64
  , ordersMigrationPreviousOrdersDigest :: !ByteString
  }
  deriving (Eq, Generic, Ord, Show)

instance Serialise OrdersMigrationScope

mkOrdersMigrationScope
  :: EmitterCursor
  -> ByteString
  -> Either GatewayStateError OrdersMigrationScope
mkOrdersMigrationScope previousCursor previousOrdersDigest = do
  unless
    (BS.length previousOrdersDigest == hashWidth)
    ( Left
        ( HashLengthInvalid
            OrdersMigrationOrdersDigest
            hashWidth
            (BS.length previousOrdersDigest)
        )
    )
  Right
    OrdersMigrationScope
      { ordersMigrationPreviousEpoch =
          emitterEpochValue (emitterCursorEpoch previousCursor)
      , ordersMigrationPreviousSequence =
          emitterSequenceValue (emitterCursorSequence previousCursor)
      , ordersMigrationPreviousOrdersDigest = previousOrdersDigest
      }

data AssertionKind
  = HeartbeatAssertion Word64
  | OwnershipAssertion OwnershipDecision
  | EpochRotationAssertion
  | OrdersMigrationAssertion !OrdersMigrationScope
  deriving (Eq, Ord, Show)

data GatewayAssertion = GatewayAssertion
  { internalAssertionOrdersAnchor :: OrdersAnchor
  , internalAssertionEmitter :: NodeId
  , internalAssertionIncarnation :: EmitterIncarnation
  , internalAssertionKind :: AssertionKind
  , internalAssertionPreviousHash :: EventHash
  , internalAssertionResultCursor :: EmitterCursor
  , internalAssertionEncodedBytes :: Natural
  }
  deriving (Eq, Show)

mkNextAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterCursor
  -> EventHash
  -> Natural
  -> AssertionKind
  -> Either GatewayStateError GatewayAssertion
mkNextAssertion bounds orders emitter previousCursor resultHash encodedBytes kind = do
  mkNextAssertionForIncarnation
    bounds
    orders
    emitter
    emitterIncarnationZero
    previousCursor
    resultHash
    encodedBytes
    kind

-- | Construct a semantic successor attested by the supplied durable emitter
-- incarnation.  The compatibility constructor above uses incarnation zero for
-- pre-incarnation callers; peer and emitter boundaries use this constructor.
mkNextAssertionForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> EventHash
  -> Natural
  -> AssertionKind
  -> Either GatewayStateError GatewayAssertion
mkNextAssertionForIncarnation
  bounds
  orders
  emitter
  incarnation
  previousCursor
  resultHash
  encodedBytes
  kind = do
    requireAdmittedEmitter orders emitter
    case kind of
      EpochRotationAssertion -> Left EpochRotationConstructorRequired
      OrdersMigrationAssertion _ -> Left OrdersMigrationConstructorRequired
      _ -> Right ()
    validateAssertionBytes bounds encodedBytes
    let previousSequence = emitterSequenceValue (emitterCursorSequence previousCursor)
    when
      (previousSequence == maxBound)
      (Left (EmitterRotationRequired emitter previousCursor))
    let resultCursor =
          EmitterCursor
            { internalEmitterCursorEpoch = emitterCursorEpoch previousCursor
            , internalEmitterCursorSequence = EmitterSequence (previousSequence + 1)
            , internalEmitterCursorHash = resultHash
            }
    Right
      ( assertionFromCursor
          orders
          emitter
          incarnation
          kind
          previousCursor
          resultCursor
          encodedBytes
      )

-- | Construct the only legal sequence-exhaustion transition.  Ordinary
-- assertions may occupy @maxBound@; only the signed invalidating checkpoint
-- increments the epoch without modular wrap and starts its successor at zero.
mkEpochRotationAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterCursor
  -> EventHash
  -> Natural
  -> Either GatewayStateError GatewayAssertion
mkEpochRotationAssertion bounds orders emitter previousCursor resultHash encodedBytes = do
  mkEpochRotationAssertionForIncarnation
    bounds
    orders
    emitter
    emitterIncarnationZero
    previousCursor
    resultHash
    encodedBytes

-- | Construct the signed epoch invalidation for one durable emitter
-- incarnation.
mkEpochRotationAssertionForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> EventHash
  -> Natural
  -> Either GatewayStateError GatewayAssertion
mkEpochRotationAssertionForIncarnation
  bounds
  orders
  emitter
  incarnation
  previousCursor
  resultHash
  encodedBytes = do
    requireAdmittedEmitter orders emitter
    validateAssertionBytes bounds encodedBytes
    let previousSequence = emitterSequenceValue (emitterCursorSequence previousCursor)
        previousEpoch = emitterEpochValue (emitterCursorEpoch previousCursor)
    unless
      (previousSequence == maxBound)
      (Left (EmitterRotationNotRequired emitter previousCursor))
    when (previousEpoch == maxBound) (Left (EmitterEpochExhausted emitter))
    let resultCursor =
          EmitterCursor
            { internalEmitterCursorEpoch = EmitterEpoch (previousEpoch + 1)
            , internalEmitterCursorSequence = EmitterSequence 0
            , internalEmitterCursorHash = resultHash
            }
    Right
      ( assertionFromCursor
          orders
          emitter
          incarnation
          EpochRotationAssertion
          previousCursor
          resultCursor
          encodedBytes
      )

-- | Construct the dedicated Orders-scope invalidation. Unlike ordinary epoch
-- rotation, this transition is legal at any prior sequence, but only when the
-- HMAC-covered migration scope names that exact prior cursor. It cannot wrap
-- the epoch and is intentionally unavailable through 'mkNextAssertion'.
mkOrdersMigrationAssertionForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> EventHash
  -> Natural
  -> OrdersMigrationScope
  -> Either GatewayStateError GatewayAssertion
mkOrdersMigrationAssertionForIncarnation
  bounds
  orders
  emitter
  incarnation
  previousCursor
  resultHash
  encodedBytes
  scope = do
    requireAdmittedEmitter orders emitter
    validateAssertionBytes bounds encodedBytes
    let previousEpoch = emitterEpochValue (emitterCursorEpoch previousCursor)
        previousSequence = emitterSequenceValue (emitterCursorSequence previousCursor)
    unless
      ( ordersMigrationPreviousEpoch scope == previousEpoch
          && ordersMigrationPreviousSequence scope == previousSequence
      )
      ( Left
          ( OrdersMigrationScopeMismatch
              emitter
              previousCursor
              (ordersMigrationPreviousEpoch scope)
              (ordersMigrationPreviousSequence scope)
          )
      )
    unless
      (BS.length (ordersMigrationPreviousOrdersDigest scope) == hashWidth)
      ( Left
          ( HashLengthInvalid
              OrdersMigrationOrdersDigest
              hashWidth
              (BS.length (ordersMigrationPreviousOrdersDigest scope))
          )
      )
    when (previousEpoch == maxBound) (Left (EmitterEpochExhausted emitter))
    let resultCursor =
          EmitterCursor
            { internalEmitterCursorEpoch = EmitterEpoch (previousEpoch + 1)
            , internalEmitterCursorSequence = EmitterSequence 0
            , internalEmitterCursorHash = resultHash
            }
    Right
      ( assertionFromCursor
          orders
          emitter
          incarnation
          (OrdersMigrationAssertion scope)
          previousCursor
          resultCursor
          encodedBytes
      )

assertionFromCursor
  :: ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> AssertionKind
  -> EmitterCursor
  -> EmitterCursor
  -> Natural
  -> GatewayAssertion
assertionFromCursor orders emitter incarnation kind previousCursor resultCursor encodedBytes =
  GatewayAssertion
    { internalAssertionOrdersAnchor = validatedOrdersAnchor orders
    , internalAssertionEmitter = emitter
    , internalAssertionIncarnation = incarnation
    , internalAssertionKind = kind
    , internalAssertionPreviousHash = emitterCursorHash previousCursor
    , internalAssertionResultCursor = resultCursor
    , internalAssertionEncodedBytes = encodedBytes
    }

validateAssertionBytes :: GatewayBounds -> Natural -> Either GatewayStateError ()
validateAssertionBytes bounds encodedBytes = do
  when (encodedBytes == 0) (Left AssertionEncodedBytesMustBePositive)
  when
    (encodedBytes > gatewayMaxEncodedAssertionBytes bounds)
    ( Left
        ( AssertionEncodedBytesExceeded
            encodedBytes
            (gatewayMaxEncodedAssertionBytes bounds)
        )
    )
  when
    (encodedBytes > gatewayMaxFrameBytes bounds)
    (Left (DeltaFrameBytesExceeded encodedBytes (gatewayMaxFrameBytes bounds)))

assertionEmitter :: GatewayAssertion -> NodeId
assertionEmitter = internalAssertionEmitter

assertionIncarnation :: GatewayAssertion -> EmitterIncarnation
assertionIncarnation = internalAssertionIncarnation

assertionOrdersAnchor :: GatewayAssertion -> OrdersAnchor
assertionOrdersAnchor = internalAssertionOrdersAnchor

assertionKind :: GatewayAssertion -> AssertionKind
assertionKind = internalAssertionKind

assertionPreviousHash :: GatewayAssertion -> EventHash
assertionPreviousHash = internalAssertionPreviousHash

assertionResultCursor :: GatewayAssertion -> EmitterCursor
assertionResultCursor = internalAssertionResultCursor

assertionEncodedBytes :: GatewayAssertion -> Natural
assertionEncodedBytes = internalAssertionEncodedBytes

data EmitterReplica = EmitterReplica
  { replicaIncarnation :: EmitterIncarnation
  , replicaCursor :: EmitterCursor
  , replicaLatestHeartbeat :: Maybe GatewayAssertion
  , replicaLatestOwnership :: Maybe GatewayAssertion
  , replicaCheckpoint :: EmitterCheckpoint
  , replicaReplay :: Seq GatewayAssertion
  }
  deriving (Eq, Show)

-- | A complete semantic projection for one emitter at the exact cursor just
-- before its retained replay suffix.  It is opaque so callers cannot pair a
-- cursor with unrelated semantic evidence.  The peer layer authenticates the
-- canonical wire representation before constructing one received from the
-- network.
data EmitterCheckpoint = EmitterCheckpoint
  { internalCheckpointOrdersAnchor :: OrdersAnchor
  , internalCheckpointEmitter :: NodeId
  , internalCheckpointIncarnation :: EmitterIncarnation
  , internalCheckpointCursor :: EmitterCursor
  , internalCheckpointHeartbeat :: Maybe GatewayAssertion
  , internalCheckpointOwnership :: Maybe GatewayAssertion
  }
  deriving (Eq, Show)

mkEmitterCheckpoint
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterCursor
  -> Maybe GatewayAssertion
  -> Maybe GatewayAssertion
  -> Either GatewayStateError EmitterCheckpoint
mkEmitterCheckpoint bounds orders emitter cursor heartbeat ownership = do
  mkEmitterCheckpointForIncarnation
    bounds
    orders
    emitter
    emitterIncarnationZero
    cursor
    heartbeat
    ownership

-- | Construct a semantic checkpoint bound to the emitter incarnation at its
-- exact compaction frontier.
mkEmitterCheckpointForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> Maybe GatewayAssertion
  -> Maybe GatewayAssertion
  -> Either GatewayStateError EmitterCheckpoint
mkEmitterCheckpointForIncarnation
  bounds
  orders
  emitter
  incarnation
  cursor
  heartbeat
  ownership = do
    requireAdmittedEmitter orders emitter
    traverse_
      (validateCheckpointEvidence bounds orders emitter incarnation cursor HeartbeatEvidence)
      heartbeat
    traverse_
      (validateCheckpointEvidence bounds orders emitter incarnation cursor OwnershipEvidence)
      ownership
    Right
      EmitterCheckpoint
        { internalCheckpointOrdersAnchor = validatedOrdersAnchor orders
        , internalCheckpointEmitter = emitter
        , internalCheckpointIncarnation = incarnation
        , internalCheckpointCursor = cursor
        , internalCheckpointHeartbeat = heartbeat
        , internalCheckpointOwnership = ownership
        }

data CheckpointEvidenceKind = HeartbeatEvidence | OwnershipEvidence

validateCheckpointEvidence
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> CheckpointEvidenceKind
  -> GatewayAssertion
  -> Either GatewayStateError ()
validateCheckpointEvidence
  bounds
  orders
  emitter
  checkpointIncarnation
  checkpointCursor
  evidenceKind
  assertion = do
    unless
      (assertionOrdersAnchor assertion == validatedOrdersAnchor orders)
      ( Left
          ( AssertionOrdersMismatch
              (validatedOrdersAnchor orders)
              (assertionOrdersAnchor assertion)
          )
      )
    unless
      (assertionEmitter assertion == emitter)
      (Left (CheckpointEvidenceEmitterMismatch emitter (assertionEmitter assertion)))
    unless
      (checkpointKindMatches evidenceKind (assertionKind assertion))
      (Left (CheckpointEvidenceKindMismatch emitter (assertionKind assertion)))
    validateAssertionBytes bounds (assertionEncodedBytes assertion)
    when
      (assertionIncarnation assertion > checkpointIncarnation)
      ( Left
          ( CheckpointEvidenceIncarnationAhead
              emitter
              (assertionIncarnation assertion)
              checkpointIncarnation
          )
      )
    let evidenceCursor = assertionResultCursor assertion
    when
      (cursorPosition evidenceCursor > cursorPosition checkpointCursor)
      (Left (CheckpointEvidenceAhead emitter evidenceCursor checkpointCursor))
    when
      ( cursorPosition evidenceCursor == cursorPosition checkpointCursor
          && emitterCursorHash evidenceCursor /= emitterCursorHash checkpointCursor
      )
      (Left (CheckpointEvidenceCursorConflict emitter evidenceCursor checkpointCursor))

checkpointKindMatches :: CheckpointEvidenceKind -> AssertionKind -> Bool
checkpointKindMatches evidenceKind kind =
  case (evidenceKind, kind) of
    (HeartbeatEvidence, HeartbeatAssertion _) -> True
    (OwnershipEvidence, OwnershipAssertion _) -> True
    _ -> False

emitterCheckpointEmitter :: EmitterCheckpoint -> NodeId
emitterCheckpointEmitter = internalCheckpointEmitter

emitterCheckpointIncarnation :: EmitterCheckpoint -> EmitterIncarnation
emitterCheckpointIncarnation = internalCheckpointIncarnation

emitterCheckpointOrdersAnchor :: EmitterCheckpoint -> OrdersAnchor
emitterCheckpointOrdersAnchor = internalCheckpointOrdersAnchor

emitterCheckpointCursor :: EmitterCheckpoint -> EmitterCursor
emitterCheckpointCursor = internalCheckpointCursor

emitterCheckpointHeartbeat :: EmitterCheckpoint -> Maybe GatewayAssertion
emitterCheckpointHeartbeat = internalCheckpointHeartbeat

emitterCheckpointOwnership :: EmitterCheckpoint -> Maybe GatewayAssertion
emitterCheckpointOwnership = internalCheckpointOwnership

data RejectionReason
  = RejectOrdersMismatch
  | RejectUnknownEmitter
  | RejectStaleIncarnation
  | RejectDelayedOldEpoch
  | RejectEpochGap
  | RejectSequenceGap
  | RejectPreviousHashMismatch
  | RejectCursorConflict
  | RejectCursorVector
  | RejectReplayUnavailable
  | RejectDeltaBound
  deriving (Bounded, Enum, Eq, Ord, Show)

data RejectionSample = RejectionSample
  { rejectionSampleReason :: RejectionReason
  , rejectionSampleEmitter :: Maybe NodeId
  , rejectionSampleEpoch :: Maybe Word64
  , rejectionSampleSequence :: Maybe Word64
  }
  deriving (Eq, Show)

data RejectionSummary = RejectionSummary
  { internalRejectionCounts :: Map RejectionReason Word64
  , internalRejectionSamples :: Seq RejectionSample
  }
  deriving (Eq, Show)

emptyRejectionSummary :: RejectionSummary
emptyRejectionSummary = RejectionSummary Map.empty Seq.empty

rejectionCount :: RejectionReason -> RejectionSummary -> Word64
rejectionCount reason summary =
  Map.findWithDefault 0 reason (internalRejectionCounts summary)

rejectionSamples :: RejectionSummary -> [RejectionSample]
rejectionSamples = toList . internalRejectionSamples

data GatewayState = GatewayState
  { internalGatewayBounds :: GatewayBounds
  , internalGatewayActiveOrders :: ValidatedOrders
  , internalGatewayStagedOrders :: Maybe ValidatedOrders
  , internalGatewayOrdersMigrationAdmission :: Maybe OrdersMigrationAdmission
  , internalGatewayEmitters :: Map NodeId EmitterReplica
  , internalGatewayRecentHashes :: Seq EventHash
  , internalGatewayRejections :: RejectionSummary
  }
  deriving (Eq, Show)

-- | A process may bridge the one same-coordinate/different-hash restart edge
-- only when its own authenticated journal proves the prior Orders digest.
-- Pending identities are bounded by the active Orders member set and are
-- consumed independently after their signed migration is admitted.
data OrdersMigrationAdmission = OrdersMigrationAdmission
  { internalMigrationPriorOrdersDigest :: !ByteString
  , internalMigrationPendingEmitters :: !(Set.Set NodeId)
  }
  deriving (Eq, Show)

initializeGatewayState
  :: GatewayBounds
  -> ValidatedOrders
  -> Map NodeId EmitterCursor
  -> Either GatewayStateError GatewayState
initializeGatewayState bounds orders cursorSeeds = do
  emitters <- seedEmitters orders cursorSeeds
  Right
    GatewayState
      { internalGatewayBounds = bounds
      , internalGatewayActiveOrders = orders
      , internalGatewayStagedOrders = Nothing
      , internalGatewayOrdersMigrationAdmission = Nothing
      , internalGatewayEmitters = emitters
      , internalGatewayRecentHashes = Seq.empty
      , internalGatewayRejections = emptyRejectionSummary
      }

-- | Arm the narrow Orders-restart bridge from a digest read from an
-- authenticated local journal. This does not permit an arbitrary cursor jump:
-- the exceptional assertion must still name the receiver's exact current
-- coordinates, and its result must be the dedicated next-epoch sequence-zero
-- migration. A process without this authority remains fail-closed and must
-- first install an authenticated peer repair.
armOrdersMigrationAdmission
  :: ByteString
  -> GatewayState
  -> Either GatewayStateError GatewayState
armOrdersMigrationAdmission priorOrdersDigest state = do
  validateOrdersMigrationAdmissionDigest priorOrdersDigest state
  case internalGatewayOrdersMigrationAdmission state of
    Just existing
      | internalMigrationPriorOrdersDigest existing /= priorOrdersDigest ->
          Left
            ( OrdersMigrationAdmissionConflict
                (internalMigrationPriorOrdersDigest existing)
                priorOrdersDigest
            )
      | otherwise -> Right state
    Nothing ->
      Right
        state
          { internalGatewayOrdersMigrationAdmission =
              Just
                OrdersMigrationAdmission
                  { internalMigrationPriorOrdersDigest = priorOrdersDigest
                  , internalMigrationPendingEmitters =
                      Map.keysSet (internalGatewayEmitters state)
                  }
          }

-- | Re-arm exactly one emitter from authenticated local-journal recovery.
-- Unlike 'armOrdersMigrationAdmission', this never grants the bridge to every
-- member when no admission exists. It is the narrow rollback companion used
-- after a volatile migration publication consumed the local admission before
-- its durable transition committed.
rearmOrdersMigrationAdmissionForEmitter
  :: NodeId
  -> ByteString
  -> GatewayState
  -> Either GatewayStateError GatewayState
rearmOrdersMigrationAdmissionForEmitter emitter priorOrdersDigest state = do
  validateOrdersMigrationAdmissionDigest priorOrdersDigest state
  unless
    (Map.member emitter (internalGatewayEmitters state))
    (Left (AssertionUnknownEmitter emitter))
  case internalGatewayOrdersMigrationAdmission state of
    Just existing
      | internalMigrationPriorOrdersDigest existing /= priorOrdersDigest ->
          Left
            ( OrdersMigrationAdmissionConflict
                (internalMigrationPriorOrdersDigest existing)
                priorOrdersDigest
            )
      | otherwise ->
          Right
            state
              { internalGatewayOrdersMigrationAdmission =
                  Just
                    existing
                      { internalMigrationPendingEmitters =
                          Set.insert emitter (internalMigrationPendingEmitters existing)
                      }
              }
    Nothing ->
      Right
        state
          { internalGatewayOrdersMigrationAdmission =
              Just
                OrdersMigrationAdmission
                  { internalMigrationPriorOrdersDigest = priorOrdersDigest
                  , internalMigrationPendingEmitters = Set.singleton emitter
                  }
          }

validateOrdersMigrationAdmissionDigest
  :: ByteString
  -> GatewayState
  -> Either GatewayStateError ()
validateOrdersMigrationAdmissionDigest priorOrdersDigest state = do
  unless
    (BS.length priorOrdersDigest == hashWidth)
    ( Left
        ( HashLengthInvalid
            OrdersMigrationOrdersDigest
            hashWidth
            (BS.length priorOrdersDigest)
        )
    )
  when
    ( priorOrdersDigest
        == ordersAnchorHashBytes
          (validatedOrdersAnchor (internalGatewayActiveOrders state))
    )
    (Left (OrdersMigrationAdmissionCurrentOrdersDigest priorOrdersDigest))

gatewayStateOrdersMigrationPendingCount :: GatewayState -> Int
gatewayStateOrdersMigrationPendingCount state =
  maybe
    0
    (Set.size . internalMigrationPendingEmitters)
    (internalGatewayOrdersMigrationAdmission state)

-- | Replace one emitter replica from the retained continuity authority during
-- startup recovery.  Semantic/replay slots are cleared because the authority
-- proves only the cursor anchor; bounded peer checkpoint repair repopulates
-- current heartbeat/ownership evidence.
restoreEmitterFromContinuity
  :: NodeId
  -> EmitterCursor
  -> GatewayState
  -> Either GatewayStateError GatewayState
restoreEmitterFromContinuity emitter cursor state =
  restoreEmitterFromContinuityForIncarnation
    emitter
    emitterIncarnationZero
    cursor
    state

-- | Restore the retained cursor together with its durable mount fence.
restoreEmitterFromContinuityForIncarnation
  :: NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> GatewayState
  -> Either GatewayStateError GatewayState
restoreEmitterFromContinuityForIncarnation emitter incarnation cursor state =
  if Map.member emitter (internalGatewayEmitters state)
    then
      let checkpoint =
            emptyEmitterCheckpoint
              (validatedOrdersAnchor (internalGatewayActiveOrders state))
              emitter
              incarnation
              cursor
       in Right
            state
              { internalGatewayEmitters =
                  Map.insert
                    emitter
                    EmitterReplica
                      { replicaIncarnation = incarnation
                      , replicaCursor = cursor
                      , replicaLatestHeartbeat = Nothing
                      , replicaLatestOwnership = Nothing
                      , replicaCheckpoint = checkpoint
                      , replicaReplay = Seq.empty
                      }
                    (internalGatewayEmitters state)
              }
    else Left (AssertionUnknownEmitter emitter)

seedEmitters
  :: ValidatedOrders
  -> Map NodeId EmitterCursor
  -> Either GatewayStateError (Map NodeId EmitterReplica)
seedEmitters orders cursorSeeds = do
  let admitted = Map.keysSet (internalValidatedOrdersMembers orders)
      seeded = Map.keysSet cursorSeeds
      missing = Set.toAscList (admitted `Set.difference` seeded)
      unknown = Set.toAscList (seeded `Set.difference` admitted)
  unless
    (null missing && null unknown)
    (Left (CursorSeedMembershipMismatch missing unknown))
  Right
    ( Map.mapWithKey
        ( \emitter cursor ->
            EmitterReplica
              { replicaIncarnation = emitterIncarnationZero
              , replicaCursor = cursor
              , replicaLatestHeartbeat = Nothing
              , replicaLatestOwnership = Nothing
              , replicaCheckpoint =
                  emptyEmitterCheckpoint
                    (validatedOrdersAnchor orders)
                    emitter
                    emitterIncarnationZero
                    cursor
              , replicaReplay = Seq.empty
              }
        )
        cursorSeeds
    )

emptyEmitterCheckpoint
  :: OrdersAnchor
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> EmitterCheckpoint
emptyEmitterCheckpoint ordersAnchor emitter incarnation cursor =
  EmitterCheckpoint
    { internalCheckpointOrdersAnchor = ordersAnchor
    , internalCheckpointEmitter = emitter
    , internalCheckpointIncarnation = incarnation
    , internalCheckpointCursor = cursor
    , internalCheckpointHeartbeat = Nothing
    , internalCheckpointOwnership = Nothing
    }

data AssertionApplyOutcome
  = AssertionApplied GatewayState
  | AssertionDuplicate GatewayState
  | AssertionRejected GatewayState GatewayStateError
  deriving (Eq, Show)

applyGatewayAssertion :: GatewayAssertion -> GatewayState -> AssertionApplyOutcome
applyGatewayAssertion assertion state =
  case applyAssertionSemantic assertion state of
    Left err ->
      AssertionRejected (recordStateRejection err (Just assertion) state) err
    Right (ApplyDuplicate, unchanged) -> AssertionDuplicate unchanged
    Right (ApplyAdvanced, advanced) -> AssertionApplied advanced

data SemanticApply = ApplyDuplicate | ApplyAdvanced
  deriving (Eq, Show)

applyAssertionSemantic
  :: GatewayAssertion
  -> GatewayState
  -> Either GatewayStateError (SemanticApply, GatewayState)
applyAssertionSemantic assertion state = do
  unless
    (assertionOrdersAnchor assertion == validatedOrdersAnchor (internalGatewayActiveOrders state))
    ( Left
        ( AssertionOrdersMismatch
            (validatedOrdersAnchor (internalGatewayActiveOrders state))
            (assertionOrdersAnchor assertion)
        )
    )
  replica <-
    case Map.lookup (assertionEmitter assertion) (internalGatewayEmitters state) of
      Nothing -> Left (AssertionUnknownEmitter (assertionEmitter assertion))
      Just present -> Right present
  case compare (assertionIncarnation assertion) (replicaIncarnation replica) of
    LT ->
      Left
        ( AssertionStaleIncarnation
            (assertionEmitter assertion)
            (assertionIncarnation assertion)
            (replicaIncarnation replica)
        )
    GT ->
      when
        ( cursorPosition (assertionResultCursor assertion)
            <= cursorPosition (replicaCursor replica)
        )
        ( Left
            ( AssertionIncarnationRequiresAdvance
                (assertionEmitter assertion)
                (replicaIncarnation replica)
                (assertionIncarnation assertion)
            )
        )
    EQ -> Right ()
  disposition <-
    cursorDispositionWithOrdersMigrationAdmission state replica assertion
  let admissionAdvanced =
        consumeOrdersMigrationAdmission disposition assertion state
  case disposition of
    CursorDuplicate -> Right (ApplyDuplicate, admissionAdvanced)
    CursorAdvance -> do
      let updatedReplica = advanceReplica (internalGatewayBounds state) assertion replica
          updatedEmitters =
            Map.adjust
              (const updatedReplica)
              (assertionEmitter assertion)
              (internalGatewayEmitters admissionAdvanced)
          updatedHashes =
            trimSeq
              gatewayDiagnosticHashCapacity
              ( internalGatewayRecentHashes admissionAdvanced
                  |> emitterCursorHash (assertionResultCursor assertion)
              )
      Right
        ( ApplyAdvanced
        , admissionAdvanced
            { internalGatewayEmitters = updatedEmitters
            , internalGatewayRecentHashes = updatedHashes
            }
        )

cursorDispositionWithOrdersMigrationAdmission
  :: GatewayState
  -> EmitterReplica
  -> GatewayAssertion
  -> Either GatewayStateError CursorDisposition
cursorDispositionWithOrdersMigrationAdmission state replica assertion =
  case ( internalGatewayOrdersMigrationAdmission state
       , assertionKind assertion
       ) of
    (Just admission, OrdersMigrationAssertion scope)
      | Set.member
          (assertionEmitter assertion)
          (internalMigrationPendingEmitters admission) -> do
          unless
            ( ordersMigrationPreviousOrdersDigest scope
                == internalMigrationPriorOrdersDigest admission
            )
            ( Left
                ( OrdersMigrationAdmissionDigestMismatch
                    (assertionEmitter assertion)
                    (internalMigrationPriorOrdersDigest admission)
                    (ordersMigrationPreviousOrdersDigest scope)
                )
            )
          let current = replicaCursor replica
              currentEpoch = emitterEpochValue (emitterCursorEpoch current)
              currentSequence = emitterSequenceValue (emitterCursorSequence current)
          if assertionResultCursor assertion == current
            then Right CursorDuplicate
            else do
              unless
                ( ordersMigrationPreviousEpoch scope == currentEpoch
                    && ordersMigrationPreviousSequence scope == currentSequence
                )
                ( Left
                    ( OrdersMigrationAdmissionCoordinateMismatch
                        (assertionEmitter assertion)
                        current
                        (ordersMigrationPreviousEpoch scope)
                        (ordersMigrationPreviousSequence scope)
                    )
                )
              -- The journal authority bridges only a genesis-hash conflict at
              -- the receiver's exact coordinate. The signed assertion still
              -- has to directly follow its own prior hash and satisfy the
              -- dedicated epoch transition.
              cursorDisposition (migrationPreviousCursor assertion) assertion
    _ -> cursorDisposition (replicaCursor replica) assertion

consumeOrdersMigrationAdmission
  :: CursorDisposition
  -> GatewayAssertion
  -> GatewayState
  -> GatewayState
consumeOrdersMigrationAdmission disposition assertion state =
  case disposition of
    CursorAdvance ->
      consumeOrdersMigrationAdmissionForEmitter (assertionEmitter assertion) state
    CursorDuplicate ->
      case assertionKind assertion of
        OrdersMigrationAssertion _ ->
          consumeOrdersMigrationAdmissionForEmitter (assertionEmitter assertion) state
        _ -> state

consumeOrdersMigrationAdmissionForEmitter
  :: NodeId
  -> GatewayState
  -> GatewayState
consumeOrdersMigrationAdmissionForEmitter emitter state =
  case internalGatewayOrdersMigrationAdmission state of
    Nothing -> state
    Just admission ->
      let pending = Set.delete emitter (internalMigrationPendingEmitters admission)
       in state
            { internalGatewayOrdersMigrationAdmission =
                if Set.null pending
                  then Nothing
                  else
                    Just admission {internalMigrationPendingEmitters = pending}
            }

data CursorDisposition = CursorDuplicate | CursorAdvance
  deriving (Eq, Show)

cursorDisposition
  :: EmitterCursor
  -> GatewayAssertion
  -> Either GatewayStateError CursorDisposition
cursorDisposition current assertion =
  let target = assertionResultCursor assertion
      currentEpoch = emitterEpochValue (emitterCursorEpoch current)
      targetEpoch = emitterEpochValue (emitterCursorEpoch target)
      currentSequence = emitterSequenceValue (emitterCursorSequence current)
      targetSequence = emitterSequenceValue (emitterCursorSequence target)
   in if target == current
        then Right CursorDuplicate
        else
          if targetEpoch < currentEpoch
            then Left (AssertionDelayedOldEpoch (assertionEmitter assertion) targetEpoch currentEpoch)
            else
              if targetEpoch == currentEpoch
                then
                  if targetSequence <= currentSequence
                    then
                      if targetSequence == currentSequence
                        then Left (AssertionCursorConflict (assertionEmitter assertion) current target)
                        else Right CursorDuplicate
                    else
                      if targetSequence /= currentSequence + 1
                        then
                          Left
                            ( AssertionSequenceGap
                                (assertionEmitter assertion)
                                (currentSequence + 1)
                                targetSequence
                            )
                        else requirePreviousHash current assertion
                else
                  if targetEpoch == currentEpoch + 1
                    && targetSequence == 0
                    && validEpochAdvance currentEpoch currentSequence (assertionKind assertion)
                    then requirePreviousHash current assertion
                    else
                      Left
                        ( AssertionEpochGap
                            (assertionEmitter assertion)
                            currentEpoch
                            targetEpoch
                        )
 where
  validEpochAdvance currentEpoch currentSequence kind =
    case kind of
      EpochRotationAssertion -> currentSequence == maxBound
      OrdersMigrationAssertion scope ->
        currentEpoch /= maxBound
          && ordersMigrationPreviousEpoch scope == currentEpoch
          && ordersMigrationPreviousSequence scope == currentSequence
      _ -> False

requirePreviousHash
  :: EmitterCursor
  -> GatewayAssertion
  -> Either GatewayStateError CursorDisposition
requirePreviousHash current assertion =
  if assertionPreviousHash assertion == emitterCursorHash current
    then Right CursorAdvance
    else
      Left
        ( AssertionPreviousHashMismatch
            (assertionEmitter assertion)
            (emitterCursorHash current)
            (assertionPreviousHash assertion)
        )

advanceReplica
  :: GatewayBounds
  -> GatewayAssertion
  -> EmitterReplica
  -> EmitterReplica
advanceReplica bounds assertion replica =
  let isMigration = case assertionKind assertion of
        OrdersMigrationAssertion _ -> True
        _ -> False
      appendedReplay =
        if isMigration
          then Seq.singleton assertion
          else replicaReplay replica |> assertion
      overflow =
        max
          0
          (Seq.length appendedReplay - gatewayReplayPerEmitter bounds)
      (compacted, replay) = Seq.splitAt overflow appendedReplay
      checkpoint =
        if isMigration
          then
            -- The migration commit is itself the first current-Orders repair
            -- floor. A fresh member can therefore install an authenticated
            -- snapshot immediately, including when the old and new genesis
            -- coordinates are both (1,0), without waiting for later traffic
            -- to trigger incidental compaction.
            emptyEmitterCheckpoint
              (assertionOrdersAnchor assertion)
              (assertionEmitter assertion)
              (assertionIncarnation assertion)
              (assertionResultCursor assertion)
          else foldl advanceCheckpoint (replicaCheckpoint replica) compacted
      (latestHeartbeat, latestOwnership) =
        case assertionKind assertion of
          HeartbeatAssertion _ -> (Just assertion, replicaLatestOwnership replica)
          OwnershipAssertion _ -> (replicaLatestHeartbeat replica, Just assertion)
          EpochRotationAssertion ->
            (replicaLatestHeartbeat replica, replicaLatestOwnership replica)
          OrdersMigrationAssertion _ -> (Nothing, Nothing)
   in EmitterReplica
        { replicaIncarnation = assertionIncarnation assertion
        , replicaCursor = assertionResultCursor assertion
        , replicaLatestHeartbeat = latestHeartbeat
        , replicaLatestOwnership = latestOwnership
        , replicaCheckpoint = checkpoint
        , replicaReplay = replay
        }

-- The evicted prefix was admitted through 'cursorDisposition' before it could
-- enter replay, so advancing the checkpoint is a total projection update and
-- needs no partial error path.
advanceCheckpoint :: EmitterCheckpoint -> GatewayAssertion -> EmitterCheckpoint
advanceCheckpoint checkpoint assertion =
  let (heartbeat, ownership) =
        case assertionKind assertion of
          HeartbeatAssertion _ ->
            (Just assertion, internalCheckpointOwnership checkpoint)
          OwnershipAssertion _ ->
            (internalCheckpointHeartbeat checkpoint, Just assertion)
          EpochRotationAssertion ->
            ( internalCheckpointHeartbeat checkpoint
            , internalCheckpointOwnership checkpoint
            )
          OrdersMigrationAssertion _ -> (Nothing, Nothing)
   in checkpoint
        { internalCheckpointIncarnation = assertionIncarnation assertion
        , internalCheckpointCursor = assertionResultCursor assertion
        , internalCheckpointHeartbeat = heartbeat
        , internalCheckpointOwnership = ownership
        }

migrationPreviousCursor :: GatewayAssertion -> EmitterCursor
migrationPreviousCursor assertion =
  case assertionKind assertion of
    OrdersMigrationAssertion scope ->
      restoredEmitterCursor
        (ordersMigrationPreviousEpoch scope)
        (ordersMigrationPreviousSequence scope)
        (assertionPreviousHash assertion)
    _ -> assertionResultCursor assertion

gatewayStateActiveOrders :: GatewayState -> ValidatedOrders
gatewayStateActiveOrders = internalGatewayActiveOrders

gatewayStateStagedOrders :: GatewayState -> Maybe ValidatedOrders
gatewayStateStagedOrders = internalGatewayStagedOrders

gatewayStateEmitterCount :: GatewayState -> Int
gatewayStateEmitterCount = Map.size . internalGatewayEmitters

gatewayStateReplayCount :: NodeId -> GatewayState -> Int
gatewayStateReplayCount emitter state =
  case Map.lookup emitter (internalGatewayEmitters state) of
    Nothing -> 0
    Just replica -> Seq.length (replicaReplay replica)

gatewayStateDiagnosticHashes :: GatewayState -> [EventHash]
gatewayStateDiagnosticHashes = toList . internalGatewayRecentHashes

gatewayStateLatestHeartbeat :: NodeId -> GatewayState -> Maybe GatewayAssertion
gatewayStateLatestHeartbeat emitter state =
  replicaLatestHeartbeat =<< Map.lookup emitter (internalGatewayEmitters state)

gatewayStateLatestOwnership :: NodeId -> GatewayState -> Maybe GatewayAssertion
gatewayStateLatestOwnership emitter state =
  replicaLatestOwnership =<< Map.lookup emitter (internalGatewayEmitters state)

gatewayStateEmitterIncarnation :: NodeId -> GatewayState -> Maybe EmitterIncarnation
gatewayStateEmitterIncarnation emitter state =
  replicaIncarnation <$> Map.lookup emitter (internalGatewayEmitters state)

gatewayStateEmitterCheckpoint :: NodeId -> GatewayState -> Maybe EmitterCheckpoint
gatewayStateEmitterCheckpoint emitter state =
  replicaCheckpoint <$> Map.lookup emitter (internalGatewayEmitters state)

gatewayStateRejectionSummary :: GatewayState -> RejectionSummary
gatewayStateRejectionSummary = internalGatewayRejections

stageOrdersPromotion
  :: ValidatedOrders
  -> GatewayState
  -> Either GatewayStateError GatewayState
stageOrdersPromotion candidate state =
  let activeAnchor = validatedOrdersAnchor (internalGatewayActiveOrders state)
      candidateAnchor = validatedOrdersAnchor candidate
   in case compareAnchors candidateAnchor activeAnchor of
        AnchorSame -> Right state
        AnchorConflict -> Left (OrdersVersionHashConflict candidateAnchor activeAnchor)
        AnchorOlder -> Right state
        AnchorNewer ->
          case internalGatewayStagedOrders state of
            Nothing -> Right state {internalGatewayStagedOrders = Just candidate}
            Just staged ->
              case compareAnchors candidateAnchor (validatedOrdersAnchor staged) of
                AnchorSame -> Right state
                AnchorConflict ->
                  Left
                    ( OrdersVersionHashConflict
                        candidateAnchor
                        (validatedOrdersAnchor staged)
                    )
                AnchorOlder -> Right state
                AnchorNewer -> Right state {internalGatewayStagedOrders = Just candidate}

data AnchorOrder = AnchorOlder | AnchorSame | AnchorNewer | AnchorConflict

compareAnchors :: OrdersAnchor -> OrdersAnchor -> AnchorOrder
compareAnchors left right =
  case compare (ordersAnchorVersion left) (ordersAnchorVersion right) of
    LT -> AnchorOlder
    GT -> AnchorNewer
    EQ -> if left == right then AnchorSame else AnchorConflict

activateOrdersPromotion
  :: Map NodeId EmitterCursor
  -> GatewayState
  -> Either GatewayStateError GatewayState
activateOrdersPromotion cursorSeeds state =
  case internalGatewayStagedOrders state of
    Nothing -> Left OrdersPromotionSlotEmpty
    Just staged -> do
      emitters <- seedEmitters staged cursorSeeds
      let oldMembers = Map.keysSet (internalGatewayEmitters state)
          continuingMembers = oldMembers `Set.intersection` Map.keysSet emitters
          priorOrdersDigest =
            ordersAnchorHashBytes
              (validatedOrdersAnchor (internalGatewayActiveOrders state))
      Right
        state
          { internalGatewayActiveOrders = staged
          , internalGatewayStagedOrders = Nothing
          , internalGatewayOrdersMigrationAdmission =
              if Set.null continuingMembers
                then Nothing
                else
                  Just
                    OrdersMigrationAdmission
                      { internalMigrationPriorOrdersDigest = priorOrdersDigest
                      , internalMigrationPendingEmitters = continuingMembers
                      }
          , internalGatewayEmitters = emitters
          , internalGatewayRecentHashes = Seq.empty
          }

newtype CursorVector = CursorVector (Map NodeId EmitterCursor)
  deriving (Eq, Show)

mkCursorVector
  :: ValidatedOrders
  -> Map NodeId EmitterCursor
  -> Either GatewayStateError CursorVector
mkCursorVector orders cursors = do
  _ <- seedEmitters orders cursors
  Right (CursorVector cursors)

gatewayStateCursorVector :: GatewayState -> CursorVector
gatewayStateCursorVector state =
  CursorVector (Map.map replicaCursor (internalGatewayEmitters state))

cursorVectorSize :: CursorVector -> Int
cursorVectorSize (CursorVector cursors) = Map.size cursors

cursorVectorLookup :: NodeId -> CursorVector -> Maybe EmitterCursor
cursorVectorLookup emitter (CursorVector cursors) = Map.lookup emitter cursors

data DeltaFrame = DeltaFrame
  { internalDeltaOrdersAnchor :: OrdersAnchor
  , internalDeltaBaseCursor :: CursorVector
  , internalDeltaAssertions :: Seq GatewayAssertion
  , internalDeltaResultingCursor :: CursorVector
  , internalDeltaEncodedBytes :: Natural
  }
  deriving (Eq, Show)

mkDeltaFrame
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> [GatewayAssertion]
  -> Either GatewayStateError DeltaFrame
mkDeltaFrame bounds orders base assertions = do
  validateCursorVectorOrders orders base
  let assertionCount = length assertions
      encodedBytes = sum (map assertionEncodedBytes assertions)
  when
    (assertionCount > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( DeltaAssertionCountExceeded
            assertionCount
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  when
    (encodedBytes > gatewayMaxFrameBytes bounds)
    (Left (DeltaFrameBytesExceeded encodedBytes (gatewayMaxFrameBytes bounds)))
  resulting <-
    foldM
      advanceCursorVector
      base
      (sortAssertions assertions)
  Right
    DeltaFrame
      { internalDeltaOrdersAnchor = validatedOrdersAnchor orders
      , internalDeltaBaseCursor = base
      , internalDeltaAssertions = Seq.fromList assertions
      , internalDeltaResultingCursor = resulting
      , internalDeltaEncodedBytes = encodedBytes
      }

advanceCursorVector
  :: CursorVector
  -> GatewayAssertion
  -> Either GatewayStateError CursorVector
advanceCursorVector (CursorVector cursors) assertion = do
  current <-
    case Map.lookup (assertionEmitter assertion) cursors of
      Nothing -> Left (AssertionUnknownEmitter (assertionEmitter assertion))
      Just present -> Right present
  disposition <- cursorDisposition current assertion
  case disposition of
    CursorDuplicate -> Right (CursorVector cursors)
    CursorAdvance ->
      Right
        ( CursorVector
            (Map.adjust (const (assertionResultCursor assertion)) (assertionEmitter assertion) cursors)
        )

selectDelta
  :: CursorVector
  -> GatewayState
  -> Either GatewayStateError DeltaFrame
selectDelta peerCursor state = do
  validateCursorVectorOrders (internalGatewayActiveOrders state) peerCursor
  available <-
    fmap
      concat
      (traverse (availableForEmitter peerCursor) (Map.toAscList (internalGatewayEmitters state)))
  let selected =
        takeBoundedAssertions
          (gatewayMaxAssertionsPerFrame (internalGatewayBounds state))
          (gatewayMaxFrameBytes (internalGatewayBounds state))
          available
  mkDeltaFrame
    (internalGatewayBounds state)
    (internalGatewayActiveOrders state)
    peerCursor
    selected

availableForEmitter
  :: CursorVector
  -> (NodeId, EmitterReplica)
  -> Either GatewayStateError [GatewayAssertion]
availableForEmitter peerVector (emitter, replica) = do
  peer <-
    case cursorVectorLookup emitter peerVector of
      Nothing -> Left (CursorVectorMissingEmitter emitter)
      Just present -> Right present
  let current = replicaCursor replica
  when
    (cursorPosition peer > cursorPosition current)
    (Left (CursorVectorAhead emitter peer current))
  if peer == current
    then Right []
    else do
      let available =
            filter
              ((> cursorPosition peer) . cursorPosition . assertionResultCursor)
              (toList (replicaReplay replica))
      case available of
        [] -> Left (DeltaReplayUnavailable emitter peer current)
        first : _ ->
          case cursorDisposition peer first of
            Left _ -> Left (DeltaReplayUnavailable emitter peer current)
            Right _ -> Right available

takeBoundedAssertions :: Int -> Natural -> [GatewayAssertion] -> [GatewayAssertion]
takeBoundedAssertions maxCount maxBytes = go 0 0
 where
  go _ _ [] = []
  go count bytes (assertion : remaining)
    | count >= maxCount = []
    | bytes + assertionEncodedBytes assertion > maxBytes = []
    | otherwise =
        assertion
          : go
            (count + 1)
            (bytes + assertionEncodedBytes assertion)
            remaining

sortAssertions :: [GatewayAssertion] -> [GatewayAssertion]
sortAssertions =
  sortOn
    ( \assertion ->
        ( assertionEmitter assertion
        , assertionIncarnation assertion
        , emitterCursorEpoch (assertionResultCursor assertion)
        , emitterCursorSequence (assertionResultCursor assertion)
        )
    )

cursorPosition :: EmitterCursor -> (EmitterEpoch, EmitterSequence)
cursorPosition cursor =
  (emitterCursorEpoch cursor, emitterCursorSequence cursor)

deltaFrameAssertionCount :: DeltaFrame -> Int
deltaFrameAssertionCount = Seq.length . internalDeltaAssertions

deltaFrameEncodedBytes :: DeltaFrame -> Natural
deltaFrameEncodedBytes = internalDeltaEncodedBytes

deltaFrameBaseCursor :: DeltaFrame -> CursorVector
deltaFrameBaseCursor = internalDeltaBaseCursor

deltaFrameResultingCursor :: DeltaFrame -> CursorVector
deltaFrameResultingCursor = internalDeltaResultingCursor

-- | One-emitter repair is deliberately independent of the all-member cursor
-- vector.  A sender repairs exactly one compacted emitter per bounded frame;
-- repeated rounds converge without requiring a snapshot proportional to all
-- members times their replay windows.
data EmitterRepair = EmitterRepair
  { internalRepairEmitter :: NodeId
  , internalRepairCheckpoint :: EmitterCheckpoint
  , internalRepairAssertions :: Seq GatewayAssertion
  , internalRepairResultReplica :: EmitterReplica
  , internalRepairEncodedBytes :: Natural
  }
  deriving (Eq, Show)

mkEmitterRepair
  :: GatewayBounds
  -> ValidatedOrders
  -> EmitterCheckpoint
  -> [GatewayAssertion]
  -> Either GatewayStateError EmitterRepair
mkEmitterRepair bounds orders checkpoint assertions = do
  unless
    (internalCheckpointOrdersAnchor checkpoint == validatedOrdersAnchor orders)
    ( Left
        ( CheckpointOrdersMismatch
            (validatedOrdersAnchor orders)
            (internalCheckpointOrdersAnchor checkpoint)
        )
    )
  validatedCheckpoint <-
    mkEmitterCheckpointForIncarnation
      bounds
      orders
      (emitterCheckpointEmitter checkpoint)
      (emitterCheckpointIncarnation checkpoint)
      (emitterCheckpointCursor checkpoint)
      (emitterCheckpointHeartbeat checkpoint)
      (emitterCheckpointOwnership checkpoint)
  let sorted = sortAssertions assertions
      evidence =
        [ present
        | Just present <-
            [ emitterCheckpointHeartbeat validatedCheckpoint
            , emitterCheckpointOwnership validatedCheckpoint
            ]
        ]
      assertionCount = length evidence + length sorted
      encodedBytes = sum (map assertionEncodedBytes (evidence ++ sorted))
  when
    (assertionCount > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( RepairAssertionCountExceeded
            assertionCount
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  when
    (encodedBytes > gatewayMaxFrameBytes bounds)
    (Left (RepairFrameBytesExceeded encodedBytes (gatewayMaxFrameBytes bounds)))
  repaired <-
    foldM
      (advanceRepairReplica bounds orders (emitterCheckpointEmitter validatedCheckpoint))
      (checkpointReplica validatedCheckpoint)
      sorted
  Right
    EmitterRepair
      { internalRepairEmitter = emitterCheckpointEmitter validatedCheckpoint
      , internalRepairCheckpoint = validatedCheckpoint
      , internalRepairAssertions = Seq.fromList sorted
      , internalRepairResultReplica = repaired
      , internalRepairEncodedBytes = encodedBytes
      }

checkpointReplica :: EmitterCheckpoint -> EmitterReplica
checkpointReplica checkpoint =
  EmitterReplica
    { replicaIncarnation = emitterCheckpointIncarnation checkpoint
    , replicaCursor = emitterCheckpointCursor checkpoint
    , replicaLatestHeartbeat = emitterCheckpointHeartbeat checkpoint
    , replicaLatestOwnership = emitterCheckpointOwnership checkpoint
    , replicaCheckpoint = checkpoint
    , replicaReplay = Seq.empty
    }

advanceRepairReplica
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterReplica
  -> GatewayAssertion
  -> Either GatewayStateError EmitterReplica
advanceRepairReplica bounds orders emitter replica assertion = do
  unless
    (assertionOrdersAnchor assertion == validatedOrdersAnchor orders)
    ( Left
        ( AssertionOrdersMismatch
            (validatedOrdersAnchor orders)
            (assertionOrdersAnchor assertion)
        )
    )
  unless
    (assertionEmitter assertion == emitter)
    (Left (RepairAssertionEmitterMismatch emitter (assertionEmitter assertion)))
  case compare (assertionIncarnation assertion) (replicaIncarnation replica) of
    LT ->
      Left
        ( AssertionStaleIncarnation
            emitter
            (assertionIncarnation assertion)
            (replicaIncarnation replica)
        )
    GT ->
      when
        ( cursorPosition (assertionResultCursor assertion)
            <= cursorPosition (replicaCursor replica)
        )
        ( Left
            ( AssertionIncarnationRequiresAdvance
                emitter
                (replicaIncarnation replica)
                (assertionIncarnation assertion)
            )
        )
    EQ -> Right ()
  disposition <- cursorDisposition (replicaCursor replica) assertion
  case disposition of
    CursorDuplicate ->
      Left
        ( RepairAssertionNotAdvancing
            emitter
            (replicaCursor replica)
            (assertionResultCursor assertion)
        )
    CursorAdvance -> Right (advanceReplica bounds assertion replica)

emitterRepairAssertionCount :: EmitterRepair -> Int
emitterRepairAssertionCount repair =
  Seq.length (internalRepairAssertions repair)
    + length
      [ ()
      | Just _ <-
          [ emitterCheckpointHeartbeat (internalRepairCheckpoint repair)
          , emitterCheckpointOwnership (internalRepairCheckpoint repair)
          ]
      ]

emitterRepairEncodedBytes :: EmitterRepair -> Natural
emitterRepairEncodedBytes = internalRepairEncodedBytes

data RepairApplyOutcome
  = RepairApplied GatewayState
  | RepairDuplicate GatewayState
  | RepairRejected GatewayState GatewayStateError
  deriving (Eq, Show)

-- | Install the authenticated checkpoint and its verified contiguous suffix
-- as one pure state transition.  A failed or stale repair cannot expose a
-- partially rewound emitter.  At an equal continuity cursor the repair may
-- fill semantic slots cleared by retained-authority startup recovery, but it
-- preserves the receiver's replay window.
applyEmitterRepair :: EmitterRepair -> GatewayState -> RepairApplyOutcome
applyEmitterRepair repair state
  | internalCheckpointOrdersAnchor (internalRepairCheckpoint repair)
      /= validatedOrdersAnchor (internalGatewayActiveOrders state) =
      rejectRepair
        ( CheckpointOrdersMismatch
            (validatedOrdersAnchor (internalGatewayActiveOrders state))
            (internalCheckpointOrdersAnchor (internalRepairCheckpoint repair))
        )
  | otherwise =
      case Map.lookup (internalRepairEmitter repair) (internalGatewayEmitters state) of
        Nothing -> rejectRepair (AssertionUnknownEmitter (internalRepairEmitter repair))
        Just current -> applyAgainst current
 where
  repaired = internalRepairResultReplica repair
  emitter = internalRepairEmitter repair

  applyAgainst current =
    case compare (replicaIncarnation repaired) (replicaIncarnation current) of
      LT ->
        rejectRepair
          ( RepairResultStaleIncarnation
              emitter
              (replicaIncarnation repaired)
              (replicaIncarnation current)
          )
      GT
        | cursorPosition (replicaCursor repaired)
            <= cursorPosition (replicaCursor current) ->
            rejectRepair
              ( RepairIncarnationRequiresAdvance
                  emitter
                  (replicaIncarnation current)
                  (replicaIncarnation repaired)
              )
        | otherwise -> applyAdvancing current
      EQ -> applyAtSameIncarnation current

  applyAtSameIncarnation current =
    case compare (cursorPosition (replicaCursor repaired)) (cursorPosition (replicaCursor current)) of
      LT -> rejectRepair (RepairResultBehind emitter (replicaCursor repaired) (replicaCursor current))
      EQ
        | emitterCursorHash (replicaCursor repaired)
            /= emitterCursorHash (replicaCursor current) ->
            rejectRepair
              ( RepairResultCursorConflict
                  emitter
                  (replicaCursor repaired)
                  (replicaCursor current)
              )
        | sameSemanticProjection repaired current ->
            RepairDuplicate
              (consumeOrdersMigrationAdmissionForEmitter emitter state)
        | otherwise ->
            RepairApplied
              ( replaceReplica
                  current
                    { replicaLatestHeartbeat = replicaLatestHeartbeat repaired
                    , replicaLatestOwnership = replicaLatestOwnership repaired
                    }
              )
      GT -> applyAdvancing current

  applyAdvancing current
    | repairExtendsOrJumps current = RepairApplied (replaceReplica repaired)
    | otherwise =
        rejectRepair
          ( RepairTargetNotOnSourceChain
              emitter
              (replicaCursor current)
              (emitterCheckpointCursor (internalRepairCheckpoint repair))
          )

  repairExtendsOrJumps current =
    let target = replicaCursor current
        checkpoint = emitterCheckpointCursor (internalRepairCheckpoint repair)
     in cursorPosition checkpoint > cursorPosition target
          || checkpoint == target
          || any
            ((== target) . assertionResultCursor)
            (internalRepairAssertions repair)

  replaceReplica replacement =
    let admissionAdvanced =
          consumeOrdersMigrationAdmissionForEmitter emitter state
        updatedHashes =
          trimSeq
            gatewayDiagnosticHashCapacity
            ( internalGatewayRecentHashes admissionAdvanced
                |> emitterCursorHash (replicaCursor replacement)
            )
     in admissionAdvanced
          { internalGatewayEmitters =
              Map.insert emitter replacement (internalGatewayEmitters admissionAdvanced)
          , internalGatewayRecentHashes = updatedHashes
          }

  rejectRepair err =
    RepairRejected
      (recordStateRejection err Nothing state)
      err

-- | Restore the exact terminal replica proven by the authenticated local
-- emitter journal. This authority is deliberately distinct from peer repair:
-- a peer may never regress a cursor, while the local journal must be able to
-- discard a volatile publication that ran ahead of its last committed
-- projection. The opaque 'EmitterRepair' has already validated its checkpoint
-- and contiguous suffix; this transition checks current Orders/membership and
-- replaces only that emitter.
restoreEmitterFromRetainedRepair
  :: NodeId
  -> EmitterRepair
  -> GatewayState
  -> Either GatewayStateError GatewayState
restoreEmitterFromRetainedRepair expectedEmitter repair state = do
  unless
    (emitter == expectedEmitter)
    (Left (RepairAssertionEmitterMismatch expectedEmitter emitter))
  unless
    ( internalCheckpointOrdersAnchor (internalRepairCheckpoint repair)
        == validatedOrdersAnchor (internalGatewayActiveOrders state)
    )
    ( Left
        ( CheckpointOrdersMismatch
            (validatedOrdersAnchor (internalGatewayActiveOrders state))
            (internalCheckpointOrdersAnchor (internalRepairCheckpoint repair))
        )
    )
  unless
    (Map.member expectedEmitter (internalGatewayEmitters state))
    (Left (AssertionUnknownEmitter expectedEmitter))
  let restoredAdmission = consumeOrdersMigrationAdmissionForEmitter expectedEmitter state
      replacement = internalRepairResultReplica repair
      updatedHashes =
        trimSeq
          gatewayDiagnosticHashCapacity
          ( internalGatewayRecentHashes restoredAdmission
              |> emitterCursorHash (replicaCursor replacement)
          )
  Right
    restoredAdmission
      { internalGatewayEmitters =
          Map.insert expectedEmitter replacement (internalGatewayEmitters restoredAdmission)
      , internalGatewayRecentHashes = updatedHashes
      }
 where
  emitter = internalRepairEmitter repair

sameSemanticProjection :: EmitterReplica -> EmitterReplica -> Bool
sameSemanticProjection left right =
  replicaIncarnation left == replicaIncarnation right
    && replicaLatestHeartbeat left == replicaLatestHeartbeat right
    && replicaLatestOwnership left == replicaLatestOwnership right

data DeltaApplyOutcome
  = DeltaApplied GatewayState
  | DeltaRejected GatewayState GatewayStateError
  deriving (Eq, Show)

-- | Apply a bounded delta atomically.  The bounded frame is sorted before the
-- fold, so assertion order inside a frame is irrelevant.  Duplicate/stale
-- already-applied assertions are no-ops; any real gap/hash/order failure keeps
-- the semantic state unchanged and records one bounded rejection sample.
applyDelta :: DeltaFrame -> GatewayState -> DeltaApplyOutcome
applyDelta frame state
  | internalDeltaOrdersAnchor frame
      /= validatedOrdersAnchor (internalGatewayActiveOrders state) =
      rejectDelta
        ( DeltaOrdersMismatch
            (validatedOrdersAnchor (internalGatewayActiveOrders state))
            (internalDeltaOrdersAnchor frame)
        )
  | otherwise =
      case foldM
        applyForDelta
        state
        (sortAssertions (toList (internalDeltaAssertions frame))) of
        Left err -> rejectDelta err
        Right advanced -> DeltaApplied advanced
 where
  rejectDelta err =
    DeltaRejected
      (recordStateRejection err Nothing state)
      err

applyForDelta
  :: GatewayState
  -> GatewayAssertion
  -> Either GatewayStateError GatewayState
applyForDelta candidate assertion = do
  (_, advanced) <- applyAssertionSemantic assertion candidate
  Right advanced

validateCursorVectorOrders
  :: ValidatedOrders
  -> CursorVector
  -> Either GatewayStateError ()
validateCursorVectorOrders orders (CursorVector cursors) =
  let admitted = Map.keysSet (internalValidatedOrdersMembers orders)
      observed = Map.keysSet cursors
   in unless
        (admitted == observed)
        ( Left
            ( CursorVectorMembershipMismatch
                (Set.toAscList (admitted `Set.difference` observed))
                (Set.toAscList (observed `Set.difference` admitted))
            )
        )

recordStateRejection
  :: GatewayStateError
  -> Maybe GatewayAssertion
  -> GatewayState
  -> GatewayState
recordStateRejection err maybeAssertion state =
  let reason = rejectionReason err
      sample = rejectionSample reason maybeAssertion
      summary = internalGatewayRejections state
      counts =
        Map.alter
          (Just . maybe 1 saturatingIncrement)
          reason
          (internalRejectionCounts summary)
      samples =
        trimSeq
          (gatewayMaxRejectionSamples (internalGatewayBounds state))
          (internalRejectionSamples summary |> sample)
   in state
        { internalGatewayRejections =
            RejectionSummary
              { internalRejectionCounts = counts
              , internalRejectionSamples = samples
              }
        }

saturatingIncrement :: Word64 -> Word64
saturatingIncrement value
  | value == maxBound = maxBound
  | otherwise = value + 1

rejectionSample :: RejectionReason -> Maybe GatewayAssertion -> RejectionSample
rejectionSample reason maybeAssertion =
  case maybeAssertion of
    Nothing -> RejectionSample reason Nothing Nothing Nothing
    Just assertion ->
      RejectionSample
        { rejectionSampleReason = reason
        , rejectionSampleEmitter = Just (assertionEmitter assertion)
        , rejectionSampleEpoch =
            Just
              ( emitterEpochValue
                  (emitterCursorEpoch (assertionResultCursor assertion))
              )
        , rejectionSampleSequence =
            Just
              ( emitterSequenceValue
                  (emitterCursorSequence (assertionResultCursor assertion))
              )
        }

rejectionReason :: GatewayStateError -> RejectionReason
rejectionReason err =
  case err of
    AssertionOrdersMismatch {} -> RejectOrdersMismatch
    DeltaOrdersMismatch {} -> RejectOrdersMismatch
    AssertionUnknownEmitter {} -> RejectUnknownEmitter
    AssertionStaleIncarnation {} -> RejectStaleIncarnation
    AssertionIncarnationRequiresAdvance {} -> RejectStaleIncarnation
    AssertionDelayedOldEpoch {} -> RejectDelayedOldEpoch
    AssertionEpochGap {} -> RejectEpochGap
    AssertionSequenceGap {} -> RejectSequenceGap
    AssertionPreviousHashMismatch {} -> RejectPreviousHashMismatch
    AssertionCursorConflict {} -> RejectCursorConflict
    CursorSeedMembershipMismatch {} -> RejectCursorVector
    CursorVectorMembershipMismatch {} -> RejectCursorVector
    CursorVectorMissingEmitter {} -> RejectCursorVector
    CursorVectorAhead {} -> RejectCursorVector
    DeltaReplayUnavailable {} -> RejectReplayUnavailable
    RepairResultBehind {} -> RejectReplayUnavailable
    RepairResultStaleIncarnation {} -> RejectStaleIncarnation
    RepairIncarnationRequiresAdvance {} -> RejectStaleIncarnation
    RepairResultCursorConflict {} -> RejectCursorConflict
    RepairTargetNotOnSourceChain {} -> RejectCursorConflict
    DeltaAssertionCountExceeded {} -> RejectDeltaBound
    DeltaFrameBytesExceeded {} -> RejectDeltaBound
    RepairAssertionCountExceeded {} -> RejectDeltaBound
    RepairFrameBytesExceeded {} -> RejectDeltaBound
    _ -> RejectDeltaBound

trimSeq :: Int -> Seq a -> Seq a
trimSeq capacity values =
  Seq.drop (max 0 (Seq.length values - capacity)) values

requireAdmittedEmitter :: ValidatedOrders -> NodeId -> Either GatewayStateError ()
requireAdmittedEmitter orders emitter =
  unless
    (Map.member emitter (internalValidatedOrdersMembers orders))
    (Left (AssertionUnknownEmitter emitter))

textBytes :: Text -> Natural
textBytes = fromIntegral . BS.length . TextEncoding.encodeUtf8

data GatewayStateError
  = HashLengthInvalid HashKind Int Int
  | OrdersDocumentMustNotBeEmpty
  | OrdersDocumentTooLarge Natural Natural
  | OrdersMembersMustNotBeEmpty
  | OrdersMemberCountExceeded Int Int
  | OrdersVersionMustBePositive Int
  | OrdersNodeIdMustNotBeEmpty
  | OrdersNodeIdTooLarge Natural Natural
  | OrdersMemberFieldMustNotBeEmpty NodeId MemberField
  | OrdersMemberFieldTooLarge NodeId MemberField Natural Natural
  | OrdersEncodedMemberTooLarge NodeId Natural Natural
  | OrdersDuplicateMember
  | OrdersDuplicateRank
  | CursorSeedMembershipMismatch [NodeId] [NodeId]
  | AssertionUnknownEmitter NodeId
  | AssertionEncodedBytesMustBePositive
  | AssertionEncodedBytesExceeded Natural Natural
  | EpochRotationConstructorRequired
  | OrdersMigrationConstructorRequired
  | EmitterRotationRequired NodeId EmitterCursor
  | EmitterRotationNotRequired NodeId EmitterCursor
  | EmitterEpochExhausted NodeId
  | OrdersMigrationScopeMismatch NodeId EmitterCursor Word64 Word64
  | OrdersMigrationAdmissionCurrentOrdersDigest ByteString
  | OrdersMigrationAdmissionConflict ByteString ByteString
  | OrdersMigrationAdmissionDigestMismatch NodeId ByteString ByteString
  | OrdersMigrationAdmissionCoordinateMismatch NodeId EmitterCursor Word64 Word64
  | AssertionOrdersMismatch OrdersAnchor OrdersAnchor
  | AssertionStaleIncarnation NodeId EmitterIncarnation EmitterIncarnation
  | AssertionIncarnationRequiresAdvance NodeId EmitterIncarnation EmitterIncarnation
  | AssertionDelayedOldEpoch NodeId Word64 Word64
  | AssertionEpochGap NodeId Word64 Word64
  | AssertionSequenceGap NodeId Word64 Word64
  | AssertionPreviousHashMismatch NodeId EventHash EventHash
  | AssertionCursorConflict NodeId EmitterCursor EmitterCursor
  | OrdersVersionHashConflict OrdersAnchor OrdersAnchor
  | OrdersPromotionSlotEmpty
  | CursorVectorMembershipMismatch [NodeId] [NodeId]
  | CursorVectorMissingEmitter NodeId
  | CursorVectorAhead NodeId EmitterCursor EmitterCursor
  | DeltaReplayUnavailable NodeId EmitterCursor EmitterCursor
  | DeltaAssertionCountExceeded Int Int
  | DeltaFrameBytesExceeded Natural Natural
  | DeltaOrdersMismatch OrdersAnchor OrdersAnchor
  | CheckpointOrdersMismatch OrdersAnchor OrdersAnchor
  | CheckpointEvidenceEmitterMismatch NodeId NodeId
  | CheckpointEvidenceKindMismatch NodeId AssertionKind
  | CheckpointEvidenceIncarnationAhead NodeId EmitterIncarnation EmitterIncarnation
  | CheckpointEvidenceAhead NodeId EmitterCursor EmitterCursor
  | CheckpointEvidenceCursorConflict NodeId EmitterCursor EmitterCursor
  | RepairAssertionEmitterMismatch NodeId NodeId
  | RepairAssertionNotAdvancing NodeId EmitterCursor EmitterCursor
  | RepairAssertionCountExceeded Int Int
  | RepairFrameBytesExceeded Natural Natural
  | RepairResultBehind NodeId EmitterCursor EmitterCursor
  | RepairResultStaleIncarnation NodeId EmitterIncarnation EmitterIncarnation
  | RepairIncarnationRequiresAdvance NodeId EmitterIncarnation EmitterIncarnation
  | RepairResultCursorConflict NodeId EmitterCursor EmitterCursor
  | RepairTargetNotOnSourceChain NodeId EmitterCursor EmitterCursor
  deriving (Eq, Show)
