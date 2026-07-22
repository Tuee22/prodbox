{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Bounded, signed delta transport for the gateway peer mesh.
--
-- There is deliberately no append-only log representation in this module.
-- Peers exchange a cursor vector and at most one bounded delta frame.  The
-- result digest of an assertion is never accepted from the wire: it is the
-- SHA-256 digest of the exact canonical CBOR signed-assertion bytes.
module Prodbox.Gateway.Peer
  ( -- * Event-key boundary
    EventKey
  , EventKeyLookup
  , mkEventKey

    -- * Signed semantic assertions
  , SignedAssertion
  , signAssertion
  , signAssertionForIncarnation
  , signAndConvertAssertion
  , signAndConvertAssertionForIncarnation
  , signAndConvertOrdersMigrationForIncarnation
  , verifySignedAssertion
  , signedAssertionBytes
  , decodeSignedAssertion
  , signedAssertionEmitter
  , signedAssertionIncarnation
  , signedAssertionEpoch
  , signedAssertionSequence
  , signedAssertionKind
  , signedAssertionResultDigest

    -- * Bounded delta and cursor wire values
  , SignedDeltaFrame
  , mkSignedDeltaFrame
  , encodeSignedDeltaFrame
  , decodeSignedDeltaFrame
  , signedDeltaAssertionCount
  , selectSignedDelta
  , verifyDeltaFrame
  , applySignedDelta

    -- * Deterministic semantic snapshot repair
  , SignedSemanticSnapshot
  , SnapshotEvidenceKind (..)
  , signSemanticSnapshot
  , encodeSignedSemanticSnapshot
  , decodeSignedSemanticSnapshot
  , verifySemanticSnapshot
  , signedSemanticSnapshotEmitter
  , signedSemanticSnapshotIncarnation
  , signedSemanticSnapshotCursor
  , SignedRepairFrame
  , selectSignedRepair
  , selectSignedRepairFromCheckpoint
  , encodeSignedRepairFrame
  , decodeSignedRepairFrame
  , signedRepairAssertionCount
  , verifyRepairFrame
  , applySignedRepair
  , encodeCursorVector
  , decodeCursorVector

    -- * Peer request handling
  , PeerTransportRequest (..)
  , BoundedSignedAssertions
  , peerRequestReplayAssertions
  , peerRequestSnapshotEvidence
  , signedSemanticSnapshotEvidence
  , boundedSignedAssertionsToList
  , peerRequestSemanticSnapshot
  , peerRequestOrdersVersion
  , validatePeerRequestHeartbeatSkew
  , PeerTransportResponse
  , handlePeerRequest
  , peerErrorResponse
  , peerResponseAccepted
  , peerResponseCursorVector
  , peerResponseAckPoint

    -- * Bounded HTTP framing
  , PeerHttpPreflight
  , peerHttpHeaderLimitBytes
  , peerHttpHeaderBytes
  , peerHttpExpectedBodyBytes
  , preflightPeerHttpRequest
  , preflightPeerHttpResponse
  , parsePeerHttpRequest
  , parsePeerHttpResponse
  , renderPeerHttpResponse
  , renderPeerDeltaRequest
  , renderPeerRepairRequest
  , renderPeerCursorRequest

    -- * Structured failures
  , PeerRejectionCode (..)
  , PeerError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (foldM, foldM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit, toLower)
import Data.Foldable (traverse_)
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word64, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Gateway.Bounds
  ( GatewayBounds
  , gatewayMaxAssertionsPerFrame
  , gatewayMaxEncodedAssertionBytes
  , gatewayMaxFrameBytes
  , gatewayMaxMembers
  , gatewayMaxNodeIdBytes
  , gatewayMaxRejectionSamples
  , gatewayMaxTrustKeyBytes
  , gatewayReplayPerEmitter
  )
import Prodbox.Gateway.Continuity
  ( mkContinuityDigest
  , restoreContinuityAnchor
  )
import Prodbox.Gateway.Emitter.Kernel
  ( AckPoint
  , mkAckPoint
  )
import Prodbox.Gateway.State
  ( AssertionKind (..)
  , CursorVector
  , DeltaApplyOutcome (..)
  , DeltaFrame
  , EmitterCheckpoint
  , EmitterCursor
  , EmitterIncarnation
  , EmitterRepair
  , EventHash
  , GatewayAssertion
  , GatewayState
  , GatewayStateError
  , NodeId
  , OrdersAnchor
  , OrdersMigrationScope
  , OwnershipDecision (..)
  , RejectionReason
  , RejectionSample (..)
  , RepairApplyOutcome (..)
  , ValidatedOrders
  , applyDelta
  , applyEmitterRepair
  , cursorVectorLookup
  , emitterCheckpointCursor
  , emitterCheckpointEmitter
  , emitterCheckpointHeartbeat
  , emitterCheckpointIncarnation
  , emitterCheckpointOrdersAnchor
  , emitterCheckpointOwnership
  , emitterCursorEpoch
  , emitterCursorHash
  , emitterCursorSequence
  , emitterEpochValue
  , emitterIncarnationValue
  , emitterIncarnationZero
  , emitterSequenceValue
  , eventHashBytes
  , gatewayStateActiveOrders
  , gatewayStateCursorVector
  , gatewayStateEmitterIncarnation
  , gatewayStateRejectionSummary
  , mkCursorVector
  , mkDeltaFrame
  , mkEmitterCheckpointForIncarnation
  , mkEmitterIncarnation
  , mkEmitterRepair
  , mkEpochRotationAssertionForIncarnation
  , mkEventHash
  , mkNextAssertionForIncarnation
  , mkOrdersMigrationAssertionForIncarnation
  , mkOrdersMigrationScope
  , nodeIdText
  , ordersAnchorHashBytes
  , ordersAnchorVersion
  , ordersMigrationPreviousEpoch
  , ordersMigrationPreviousOrdersDigest
  , ordersMigrationPreviousSequence
  , ordersVersionValue
  , rejectionSamples
  , restoredEmitterCursor
  , validatedOrdersAnchor
  , validatedOrdersMemberIds
  )

protocolVersion :: Word16
protocolVersion = 4

signatureBytes :: Int
signatureBytes = 32

hashBytes :: Int
hashBytes = 32

minimumEventKeyBytes :: Natural
minimumEventKeyBytes = 32

-- | Peer event keys are opaque and are always redacted from diagnostics.
newtype EventKey = EventKey ByteString
  deriving (Eq)

instance Show EventKey where
  show (EventKey bytes) = "EventKey <redacted:" ++ show (BS.length bytes) ++ " bytes>"

-- | Lookup a validated active member's event key.
type EventKeyLookup = NodeId -> Maybe EventKey

mkEventKey :: GatewayBounds -> ByteString -> Either PeerError EventKey
mkEventKey bounds bytes = do
  let actual = byteLength bytes
      allowed = gatewayMaxTrustKeyBytes bounds
  when (BS.null bytes) (Left PeerEventKeyMustNotBeEmpty)
  when
    (actual < minimumEventKeyBytes)
    (Left (PeerEventKeyTooSmall actual minimumEventKeyBytes))
  when (actual > allowed) (Left (PeerEventKeyTooLarge actual allowed))
  Right (EventKey bytes)

data WireOrdersAnchor = WireOrdersAnchor
  { wireOrdersVersion :: Word64
  , wireOrdersHash :: ByteString
  }
  deriving (Eq, Generic, Show)

instance Serialise WireOrdersAnchor

data WireAssertionKind
  = WireHeartbeat Word64
  | WireClaim
  | WireYield
  | WireEpochInvalidation
  | WireOrdersMigration !OrdersMigrationScope
  deriving (Eq, Generic, Ord, Show)

instance Serialise WireAssertionKind

-- | The HMAC covers the canonical encoding of this exact value.  There is no
-- result-hash field: callers cannot choose the next continuity digest.
data WireUnsignedAssertion = WireUnsignedAssertion
  { wireAssertionProtocol :: Word16
  , wireAssertionOrders :: WireOrdersAnchor
  , wireAssertionEmitter :: Text
  , wireAssertionIncarnation :: Word64
  , wireAssertionEpoch :: Word64
  , wireAssertionSequence :: Word64
  , wireAssertionPreviousDigest :: ByteString
  , wireAssertionKind :: WireAssertionKind
  }
  deriving (Eq, Generic, Show)

instance Serialise WireUnsignedAssertion

data WireSignedAssertion = WireSignedAssertion
  { wireSignedUnsigned :: WireUnsignedAssertion
  , wireSignedHmac :: ByteString
  }
  deriving (Eq, Generic)

instance Serialise WireSignedAssertion

instance Show WireSignedAssertion where
  show wire =
    "WireSignedAssertion { assertion = "
      ++ show (wireSignedUnsigned wire)
      ++ ", hmac = <redacted:"
      ++ show (BS.length (wireSignedHmac wire))
      ++ " bytes> }"

-- | Opaque canonical signed assertion.
newtype SignedAssertion = SignedAssertion WireSignedAssertion
  deriving (Eq)

instance Show SignedAssertion where
  show (SignedAssertion wire) = show wire

-- | Sign one exact successor of the supplied durable cursor.  The fixed
-- epoch/sequence coordinates are derived here and then checked again through
-- the constructors in "Prodbox.Gateway.State".
signAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterCursor
  -> AssertionKind
  -> EventKey
  -> Either PeerError SignedAssertion
signAssertion bounds orders emitter previous kind (EventKey key) = do
  signAssertionForIncarnation
    bounds
    orders
    emitter
    emitterIncarnationZero
    previous
    kind
    (EventKey key)

-- | Sign one successor under the durable emitter incarnation that owns the
-- publication.  The incarnation is inside the HMAC-covered canonical bytes.
signAssertionForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> AssertionKind
  -> EventKey
  -> Either PeerError SignedAssertion
signAssertionForIncarnation
  bounds
  orders
  emitter
  incarnation
  previous
  kind
  key =
    case kind of
      OrdersMigrationAssertion _ -> Left PeerOrdersMigrationRequiresDedicatedPath
      _ ->
        signAssertionForIncarnationInternal
          bounds
          orders
          emitter
          incarnation
          previous
          kind
          key

signAssertionForIncarnationInternal
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> AssertionKind
  -> EventKey
  -> Either PeerError SignedAssertion
signAssertionForIncarnationInternal
  bounds
  orders
  emitter
  incarnation
  previous
  kind
  (EventKey key) = do
    (epoch, sequenceNumber) <- nextCoordinates emitter previous kind
    let unsigned =
          WireUnsignedAssertion
            { wireAssertionProtocol = protocolVersion
            , wireAssertionOrders = anchorToWire (validatedOrdersAnchor orders)
            , wireAssertionEmitter = nodeIdText emitter
            , wireAssertionIncarnation = emitterIncarnationValue incarnation
            , wireAssertionEpoch = epoch
            , wireAssertionSequence = sequenceNumber
            , wireAssertionPreviousDigest = eventHashBytes (emitterCursorHash previous)
            , wireAssertionKind = kindToWire kind
            }
        unsignedBytes = canonicalBytes unsigned
        signed =
          WireSignedAssertion
            { wireSignedUnsigned = unsigned
            , wireSignedHmac = SHA256.hmac key unsignedBytes
            }
        assertion = SignedAssertion signed
    validateSignedAssertionShape bounds signed
    -- Re-enter the semantic constructor before exposing the signed value.  This
    -- catches membership, sequence-exhaustion, and rotation mistakes at the
    -- production boundary rather than at the receiver.
    _ <- signedToGatewayAssertion bounds orders assertion
    Right assertion

-- | Convenience for the local durable-publication path: return both the
-- exact bytes to stage in the continuity authority and the semantic value to
-- publish after the stage is durably re-observed.
signAndConvertAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterCursor
  -> AssertionKind
  -> EventKey
  -> Either PeerError (SignedAssertion, GatewayAssertion)
signAndConvertAssertion bounds orders emitter previous kind key = do
  signAndConvertAssertionForIncarnation
    bounds
    orders
    emitter
    emitterIncarnationZero
    previous
    kind
    key

signAndConvertAssertionForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> AssertionKind
  -> EventKey
  -> Either PeerError (SignedAssertion, GatewayAssertion)
signAndConvertAssertionForIncarnation bounds orders emitter incarnation previous kind key = do
  signed <- signAssertionForIncarnation bounds orders emitter incarnation previous kind key
  semantic <- signedToGatewayAssertion bounds orders signed
  Right (signed, semantic)

-- | Dedicated mounted-Orders promotion path. The exact prior cursor and old
-- Orders digest are embedded in the HMAC-covered kind; the generic assertion
-- signer rejects this kind so ordinary callers cannot trigger a scope reset.
signAndConvertOrdersMigrationForIncarnation
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> EmitterIncarnation
  -> EmitterCursor
  -> ByteString
  -> EventKey
  -> Either PeerError (SignedAssertion, GatewayAssertion)
signAndConvertOrdersMigrationForIncarnation
  bounds
  orders
  emitter
  incarnation
  previous
  previousOrdersDigest
  key = do
    scope <- mapStateError (mkOrdersMigrationScope previous previousOrdersDigest)
    let kind = OrdersMigrationAssertion scope
    signed <-
      signAssertionForIncarnationInternal
        bounds
        orders
        emitter
        incarnation
        previous
        kind
        key
    semantic <- signedToGatewayAssertion bounds orders signed
    Right (signed, semantic)

signedAssertionBytes :: SignedAssertion -> ByteString
signedAssertionBytes (SignedAssertion wire) = canonicalBytes wire

-- | Recover one exact assertion from retained continuity bytes.  Canonical
-- equality is required so the result digest remains identical before and
-- after a crash; signature and active-Orders checks still occur at
-- 'verifySignedAssertion'.
decodeSignedAssertion
  :: GatewayBounds
  -> ByteString
  -> Either PeerError SignedAssertion
decodeSignedAssertion bounds bytes = do
  when (BS.null bytes) (Left PeerEncodedFrameMustNotBeEmpty)
  let actual = byteLength bytes
      allowed = gatewayMaxEncodedAssertionBytes bounds
  when (actual > allowed) (Left (PeerAssertionTooLarge actual allowed))
  wire <- decodeCanonical "signed assertion" bytes
  validateSignedAssertionShape bounds wire
  Right (SignedAssertion wire)

signedAssertionEmitter :: SignedAssertion -> Text
signedAssertionEmitter (SignedAssertion wire) =
  wireAssertionEmitter (wireSignedUnsigned wire)

signedAssertionIncarnation :: SignedAssertion -> Word64
signedAssertionIncarnation (SignedAssertion wire) =
  wireAssertionIncarnation (wireSignedUnsigned wire)

signedAssertionEpoch :: SignedAssertion -> Word64
signedAssertionEpoch (SignedAssertion wire) =
  wireAssertionEpoch (wireSignedUnsigned wire)

signedAssertionSequence :: SignedAssertion -> Word64
signedAssertionSequence (SignedAssertion wire) =
  wireAssertionSequence (wireSignedUnsigned wire)

signedAssertionKind :: SignedAssertion -> AssertionKind
signedAssertionKind (SignedAssertion wire) =
  case wireAssertionKind (wireSignedUnsigned wire) of
    WireHeartbeat timestamp -> HeartbeatAssertion timestamp
    WireClaim -> OwnershipAssertion OwnershipClaim
    WireYield -> OwnershipAssertion OwnershipYield
    WireEpochInvalidation -> EpochRotationAssertion
    WireOrdersMigration scope -> OrdersMigrationAssertion scope

signedAssertionResultDigest :: SignedAssertion -> ByteString
signedAssertionResultDigest = SHA256.hash . signedAssertionBytes

verifySignedAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> EventKeyLookup
  -> SignedAssertion
  -> Either PeerError GatewayAssertion
verifySignedAssertion bounds orders lookupKey signed@(SignedAssertion wire) = do
  validateSignedAssertionShape bounds wire
  validateAssertionOrders orders (wireSignedUnsigned wire)
  emitter <- resolveEmitter orders (wireAssertionEmitter (wireSignedUnsigned wire))
  key <-
    case lookupKey emitter of
      Nothing -> Left (PeerEventKeyUnavailable emitter)
      Just present -> Right present
  let EventKey keyBytes = key
      expected = SHA256.hmac keyBytes (canonicalBytes (wireSignedUnsigned wire))
      supplied = wireSignedHmac wire
  unless
    (ByteArray.constEq expected supplied)
    (Left (PeerAssertionSignatureMismatch emitter))
  signedToGatewayAssertion bounds orders signed

signedToGatewayAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> SignedAssertion
  -> Either PeerError GatewayAssertion
signedToGatewayAssertion bounds orders signed@(SignedAssertion wire) = do
  let unsigned = wireSignedUnsigned wire
  validateAssertionOrders orders unsigned
  emitter <- resolveEmitter orders (wireAssertionEmitter unsigned)
  previousHash <- mapStateError (mkEventHash (wireAssertionPreviousDigest unsigned))
  resultHash <- mapStateError (mkEventHash (SHA256.hash (signedAssertionBytes signed)))
  kind <- wireToKind (wireAssertionKind unsigned)
  previous <- previousCursorFor emitter unsigned previousHash
  let encodedBytes = byteLength (signedAssertionBytes signed)
      incarnation = mkEmitterIncarnation (wireAssertionIncarnation unsigned)
  case kind of
    EpochRotationAssertion ->
      mapStateError
        ( mkEpochRotationAssertionForIncarnation
            bounds
            orders
            emitter
            incarnation
            previous
            resultHash
            encodedBytes
        )
    OrdersMigrationAssertion scope ->
      mapStateError
        ( mkOrdersMigrationAssertionForIncarnation
            bounds
            orders
            emitter
            incarnation
            previous
            resultHash
            encodedBytes
            scope
        )
    _ ->
      mapStateError
        ( mkNextAssertionForIncarnation
            bounds
            orders
            emitter
            incarnation
            previous
            resultHash
            encodedBytes
            kind
        )

nextCoordinates
  :: NodeId
  -> EmitterCursor
  -> AssertionKind
  -> Either PeerError (Word64, Word64)
nextCoordinates emitter previous kind =
  let epoch = emitterEpochValue (emitterCursorEpoch previous)
      sequenceNumber = emitterSequenceValue (emitterCursorSequence previous)
   in case kind of
        EpochRotationAssertion
          | sequenceNumber /= maxBound ->
              Left (PeerEpochInvalidationBeforeExhaustion emitter sequenceNumber)
          | epoch == maxBound -> Left (PeerEmitterCountersExhausted emitter)
          | otherwise -> Right (epoch + 1, 0)
        OrdersMigrationAssertion scope
          | ordersMigrationPreviousEpoch scope /= epoch
              || ordersMigrationPreviousSequence scope /= sequenceNumber ->
              Left PeerOrdersMigrationScopeMismatch
          | epoch == maxBound -> Left (PeerEmitterCountersExhausted emitter)
          | otherwise -> Right (epoch + 1, 0)
        _
          | sequenceNumber == maxBound ->
              Left (PeerEpochInvalidationRequired emitter epoch)
          | otherwise -> Right (epoch, sequenceNumber + 1)

previousCursorFor
  :: NodeId
  -> WireUnsignedAssertion
  -> EventHash
  -> Either PeerError EmitterCursor
previousCursorFor emitter unsigned previousHash =
  case wireAssertionKind unsigned of
    WireEpochInvalidation
      | wireAssertionSequence unsigned /= 0 ->
          Left
            ( PeerEpochInvalidationSequenceInvalid
                emitter
                (wireAssertionSequence unsigned)
            )
      | wireAssertionEpoch unsigned == 0 ->
          Left (PeerEpochInvalidationEpochInvalid emitter)
      | otherwise ->
          Right
            ( restoredEmitterCursor
                (wireAssertionEpoch unsigned - 1)
                maxBound
                previousHash
            )
    WireOrdersMigration scope
      | wireAssertionSequence unsigned /= 0 ->
          Left
            ( PeerEpochInvalidationSequenceInvalid
                emitter
                (wireAssertionSequence unsigned)
            )
      | wireAssertionEpoch unsigned == 0 ->
          Left (PeerEpochInvalidationEpochInvalid emitter)
      | wireAssertionEpoch unsigned /= ordersMigrationPreviousEpoch scope + 1 ->
          Left PeerOrdersMigrationScopeMismatch
      | otherwise ->
          Right
            ( restoredEmitterCursor
                (ordersMigrationPreviousEpoch scope)
                (ordersMigrationPreviousSequence scope)
                previousHash
            )
    _
      | wireAssertionSequence unsigned == 0 ->
          Left (PeerSemanticSequenceInvalid emitter)
      | otherwise ->
          Right
            ( restoredEmitterCursor
                (wireAssertionEpoch unsigned)
                (wireAssertionSequence unsigned - 1)
                previousHash
            )

kindToWire :: AssertionKind -> WireAssertionKind
kindToWire kind =
  case kind of
    HeartbeatAssertion timestamp -> WireHeartbeat timestamp
    OwnershipAssertion OwnershipClaim -> WireClaim
    OwnershipAssertion OwnershipYield -> WireYield
    EpochRotationAssertion -> WireEpochInvalidation
    OrdersMigrationAssertion scope -> WireOrdersMigration scope

wireToKind :: WireAssertionKind -> Either PeerError AssertionKind
wireToKind wire =
  Right $ case wire of
    WireHeartbeat timestamp -> HeartbeatAssertion timestamp
    WireClaim -> OwnershipAssertion OwnershipClaim
    WireYield -> OwnershipAssertion OwnershipYield
    WireEpochInvalidation -> EpochRotationAssertion
    WireOrdersMigration scope -> OrdersMigrationAssertion scope

data WireCursorEntry = WireCursorEntry
  { wireCursorEmitter :: Text
  , wireCursorEpoch :: Word64
  , wireCursorSequence :: Word64
  , wireCursorDigest :: ByteString
  }
  deriving (Eq, Generic, Ord, Show)

instance Serialise WireCursorEntry

data WireCursorIncarnation = WireCursorIncarnation
  { wireCursorIncarnationEmitter :: Text
  , wireCursorIncarnationValue :: Word64
  }
  deriving (Eq, Generic, Ord, Show)

instance Serialise WireCursorIncarnation

data WireCursorVector = WireCursorVector
  { wireCursorProtocol :: Word16
  , wireCursorOrders :: WireOrdersAnchor
  , wireCursorEntries :: [WireCursorEntry]
  , wireCursorIncarnations :: [WireCursorIncarnation]
  }
  deriving (Eq, Generic, Show)

instance Serialise WireCursorVector

data WireDeltaFrame = WireDeltaFrame
  { wireDeltaProtocol :: Word16
  , wireDeltaOrders :: WireOrdersAnchor
  , wireDeltaBaseCursor :: WireCursorVector
  , wireDeltaAssertions :: [WireSignedAssertion]
  }
  deriving (Eq, Generic)

instance Serialise WireDeltaFrame

instance Show WireDeltaFrame where
  show frame =
    "WireDeltaFrame { protocol = "
      ++ show (wireDeltaProtocol frame)
      ++ ", orders = "
      ++ show (wireDeltaOrders frame)
      ++ ", cursorEntries = "
      ++ show (length (wireCursorEntries (wireDeltaBaseCursor frame)))
      ++ ", assertions = "
      ++ show (length (wireDeltaAssertions frame))
      ++ " }"

newtype SignedDeltaFrame = SignedDeltaFrame WireDeltaFrame
  deriving (Eq, Show)

-- | The signed snapshot attests one emitter's complete semantic projection at
-- its replay-compaction frontier.  The optional assertions retain their own
-- signatures; the outer HMAC additionally commits to their presence or
-- absence and to the exact checkpoint cursor, so a peer cannot splice stale
-- evidence into a newer anchor.
data WireUnsignedSemanticSnapshot = WireUnsignedSemanticSnapshot
  { wireSnapshotProtocol :: Word16
  , wireSnapshotOrders :: WireOrdersAnchor
  , wireSnapshotIncarnation :: Word64
  , wireSnapshotCursor :: WireCursorEntry
  , wireSnapshotHeartbeat :: Maybe WireSignedAssertion
  , wireSnapshotOwnership :: Maybe WireSignedAssertion
  }
  deriving (Eq, Generic)

instance Serialise WireUnsignedSemanticSnapshot

data WireSignedSemanticSnapshot = WireSignedSemanticSnapshot
  { wireSignedSnapshotUnsigned :: WireUnsignedSemanticSnapshot
  , wireSignedSnapshotHmac :: ByteString
  }
  deriving (Eq, Generic)

instance Serialise WireSignedSemanticSnapshot

instance Show WireSignedSemanticSnapshot where
  show signed =
    let snapshot = wireSignedSnapshotUnsigned signed
     in "WireSignedSemanticSnapshot { emitter = "
          ++ show (wireCursorEmitter (wireSnapshotCursor snapshot))
          ++ ", incarnation = "
          ++ show (wireSnapshotIncarnation snapshot)
          ++ ", epoch = "
          ++ show (wireCursorEpoch (wireSnapshotCursor snapshot))
          ++ ", sequence = "
          ++ show (wireCursorSequence (wireSnapshotCursor snapshot))
          ++ ", heartbeat = "
          ++ show (maybe False (const True) (wireSnapshotHeartbeat snapshot))
          ++ ", ownership = "
          ++ show (maybe False (const True) (wireSnapshotOwnership snapshot))
          ++ ", hmac = <redacted:"
          ++ show (BS.length (wireSignedSnapshotHmac signed))
          ++ " bytes> }"

newtype SignedSemanticSnapshot = SignedSemanticSnapshot WireSignedSemanticSnapshot
  deriving (Eq, Show)

data WireRepairFrame = WireRepairFrame
  { wireRepairProtocol :: Word16
  , wireRepairOrders :: WireOrdersAnchor
  , wireRepairSnapshot :: WireSignedSemanticSnapshot
  , wireRepairAssertions :: [WireSignedAssertion]
  }
  deriving (Eq, Generic)

instance Serialise WireRepairFrame

instance Show WireRepairFrame where
  show frame =
    "WireRepairFrame { protocol = "
      ++ show (wireRepairProtocol frame)
      ++ ", orders = "
      ++ show (wireRepairOrders frame)
      ++ ", snapshot = "
      ++ show (wireRepairSnapshot frame)
      ++ ", suffixAssertions = "
      ++ show (length (wireRepairAssertions frame))
      ++ " }"

newtype SignedRepairFrame = SignedRepairFrame WireRepairFrame
  deriving (Eq, Show)

mkSignedDeltaFrame
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> [SignedAssertion]
  -> Either PeerError SignedDeltaFrame
mkSignedDeltaFrame bounds orders base signedAssertions = do
  let assertionCount = length signedAssertions
  when
    (assertionCount > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( PeerDeltaAssertionCountExceeded
            assertionCount
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  traverse_
    (\(SignedAssertion wire) -> validateSignedAssertionShape bounds wire)
    signedAssertions
  baseWire <- cursorToWire orders base
  let sorted =
        sortOn signedAssertionPosition signedAssertions
      wireAssertions = [wire | SignedAssertion wire <- sorted]
      frame =
        WireDeltaFrame
          { wireDeltaProtocol = protocolVersion
          , wireDeltaOrders = anchorToWire (validatedOrdersAnchor orders)
          , wireDeltaBaseCursor = baseWire
          , wireDeltaAssertions = wireAssertions
          }
  validateWireDeltaShape bounds frame
  traverse_ (validateAssertionOrders orders . wireSignedUnsigned) wireAssertions
  Right (SignedDeltaFrame frame)

encodeSignedDeltaFrame :: SignedDeltaFrame -> ByteString
encodeSignedDeltaFrame (SignedDeltaFrame frame) = canonicalBytes frame

decodeSignedDeltaFrame
  :: GatewayBounds
  -> ByteString
  -> Either PeerError SignedDeltaFrame
decodeSignedDeltaFrame bounds bytes = do
  validateEncodedFrameBytes bounds bytes
  frame <- decodeCanonical "delta frame" bytes
  validateWireDeltaShape bounds frame
  Right (SignedDeltaFrame frame)

signedDeltaAssertionCount :: SignedDeltaFrame -> Int
signedDeltaAssertionCount (SignedDeltaFrame frame) = length (wireDeltaAssertions frame)

-- | Select the bounded suffix a peer has not observed.  The retained replay
-- input is bounded before sorting, and every per-emitter suffix must begin at
-- the peer's exact next epoch/sequence/previous-digest coordinate.  A peer
-- farther behind than the retained replay receives a distinct structured
-- failure rather than a misleading partial delta.
selectSignedDelta
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> [SignedAssertion]
  -> Either PeerError SignedDeltaFrame
selectSignedDelta bounds orders peerCursor retained = do
  _ <- cursorToWire orders peerCursor
  let replayCapacity :: Natural
      replayCapacity =
        fromIntegral (gatewayMaxMembers bounds)
          * fromIntegral (gatewayReplayPerEmitter bounds)
      retainedCount :: Natural
      retainedCount = fromIntegral (length retained)
  when
    (retainedCount > replayCapacity)
    (Left (PeerSignedReplayCapacityExceeded retainedCount replayCapacity))
  traverse_ validateRetained retained
  selectedByEmitter <-
    fmap
      concat
      (traverse selectForEmitter (validatedOrdersMemberIds orders))
  let frameCandidates =
        take
          (gatewayMaxAssertionsPerFrame bounds)
          (sortOn signedAssertionPosition selectedByEmitter)
  largestFittingDelta bounds orders peerCursor frameCandidates
 where
  validateRetained signed@(SignedAssertion wire) = do
    validateSignedAssertionShape bounds wire
    validateAssertionOrders orders (wireSignedUnsigned wire)
    _ <- resolveEmitter orders (signedAssertionEmitter signed)
    Right ()

  selectForEmitter emitter = do
    peer <-
      case cursorVectorLookup emitter peerCursor of
        Nothing -> Left (PeerCursorMissingEmitter emitter)
        Just present -> Right present
    selectReplaySuffix
      emitter
      peer
      ( sortOn
          signedAssertionPosition
          (filter ((== nodeIdText emitter) . signedAssertionEmitter) retained)
      )

largestFittingDelta
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> [SignedAssertion]
  -> Either PeerError SignedDeltaFrame
largestFittingDelta bounds orders base candidates = go [] candidates
 where
  go accepted [] = mkSignedDeltaFrame bounds orders base accepted
  go accepted (candidate : remaining) =
    case mkSignedDeltaFrame bounds orders base (accepted ++ [candidate]) of
      Right _ -> go (accepted ++ [candidate]) remaining
      Left PeerEncodedFrameTooLarge {}
        | null accepted -> Left PeerDeltaCannotFitAssertion
        | otherwise -> mkSignedDeltaFrame bounds orders base accepted
      Left err -> Left err

selectReplaySuffix
  :: NodeId
  -> EmitterCursor
  -> [SignedAssertion]
  -> Either PeerError [SignedAssertion]
selectReplaySuffix emitter initialCursor =
  selectReplaySuffixFromIncarnation emitter Nothing initialCursor

selectReplaySuffixFromIncarnation
  :: NodeId
  -> Maybe Word64
  -> EmitterCursor
  -> [SignedAssertion]
  -> Either PeerError [SignedAssertion]
selectReplaySuffixFromIncarnation emitter initialIncarnation initialCursor =
  go initialIncarnation initialCursor
 where
  go _ _ [] = Right []
  go currentIncarnation cursor (signed : remaining) = do
    resultHash <- mapStateError (mkEventHash (signedAssertionResultDigest signed))
    let targetEpoch = signedAssertionEpoch signed
        targetSequence = signedAssertionSequence signed
        targetPosition = (targetEpoch, targetSequence)
        currentEpoch = emitterEpochValue (emitterCursorEpoch cursor)
        currentSequence = emitterSequenceValue (emitterCursorSequence cursor)
        currentPosition = (currentEpoch, currentSequence)
    case compare targetPosition currentPosition of
      LT -> go currentIncarnation cursor remaining
      EQ ->
        if resultHash == emitterCursorHash cursor
          then go currentIncarnation cursor remaining
          else Left (PeerSignedReplayCursorConflict emitter targetEpoch targetSequence)
      GT -> do
        case currentIncarnation of
          Just observed
            | signedAssertionIncarnation signed < observed ->
                Left
                  ( PeerSignedReplayStaleIncarnation
                      (nodeIdText emitter)
                      (signedAssertionIncarnation signed)
                      observed
                  )
          _ -> Right ()
        unless
          (signedDirectlyFollows cursor signed)
          ( Left
              ( PeerSignedReplayUnavailable
                  emitter
                  currentEpoch
                  currentSequence
              )
          )
        let advanced = restoredEmitterCursor targetEpoch targetSequence resultHash
        rest <-
          go
            (Just (signedAssertionIncarnation signed))
            advanced
            remaining
        Right (signed : rest)

signedDirectlyFollows :: EmitterCursor -> SignedAssertion -> Bool
signedDirectlyFollows cursor (SignedAssertion wire) =
  let unsigned = wireSignedUnsigned wire
      currentEpoch = emitterEpochValue (emitterCursorEpoch cursor)
      currentSequence = emitterSequenceValue (emitterCursorSequence cursor)
      previousMatches =
        wireAssertionPreviousDigest unsigned
          == eventHashBytes (emitterCursorHash cursor)
   in previousMatches
        && case wireAssertionKind unsigned of
          WireEpochInvalidation ->
            currentSequence == maxBound
              && currentEpoch /= maxBound
              && wireAssertionEpoch unsigned == currentEpoch + 1
              && wireAssertionSequence unsigned == 0
          WireOrdersMigration scope ->
            currentEpoch /= maxBound
              && ordersMigrationPreviousEpoch scope == currentEpoch
              && ordersMigrationPreviousSequence scope == currentSequence
              && wireAssertionEpoch unsigned == currentEpoch + 1
              && wireAssertionSequence unsigned == 0
          _ ->
            currentSequence /= maxBound
              && wireAssertionEpoch unsigned == currentEpoch
              && wireAssertionSequence unsigned == currentSequence + 1

verifyDeltaFrame
  :: GatewayBounds
  -> EventKeyLookup
  -> GatewayState
  -> SignedDeltaFrame
  -> Either PeerError DeltaFrame
verifyDeltaFrame bounds lookupKey state (SignedDeltaFrame wire) = do
  let orders = gatewayStateActiveOrders state
  validateWireDeltaShape bounds wire
  validateWireAnchor orders (wireDeltaOrders wire)
  base <- wireToCursor bounds orders (wireDeltaBaseCursor wire)
  assertions <-
    traverse
      (verifySignedAssertion bounds orders lookupKey . SignedAssertion)
      (wireDeltaAssertions wire)
  mapStateError (mkDeltaFrame bounds orders base assertions)

applySignedDelta
  :: GatewayBounds
  -> EventKeyLookup
  -> SignedDeltaFrame
  -> GatewayState
  -> Either PeerError DeltaApplyOutcome
applySignedDelta bounds lookupKey signed state = do
  frame <- verifyDeltaFrame bounds lookupKey state signed
  Right (applyDelta frame state)

-- | Sign the exact State-owned compaction checkpoint.  Each present semantic
-- assertion must be supplied in its original signed form and must decode to
-- the checkpoint evidence byte-for-byte at the semantic layer.
signSemanticSnapshot
  :: GatewayBounds
  -> ValidatedOrders
  -> EmitterCheckpoint
  -> Maybe SignedAssertion
  -> Maybe SignedAssertion
  -> EventKey
  -> Either PeerError SignedSemanticSnapshot
signSemanticSnapshot bounds orders checkpoint signedHeartbeat signedOwnership key = do
  unless
    (emitterCheckpointOrdersAnchor checkpoint == validatedOrdersAnchor orders)
    (Left PeerSnapshotOrdersMismatch)
  let emitter = emitterCheckpointEmitter checkpoint
      lookupLocal candidate
        | candidate == emitter = Just key
        | otherwise = Nothing
  heartbeatWire <-
    matchCheckpointEvidence
      bounds
      orders
      lookupLocal
      emitter
      SnapshotHeartbeatEvidence
      (emitterCheckpointHeartbeat checkpoint)
      signedHeartbeat
  ownershipWire <-
    matchCheckpointEvidence
      bounds
      orders
      lookupLocal
      emitter
      SnapshotOwnershipEvidence
      (emitterCheckpointOwnership checkpoint)
      signedOwnership
  let unsigned =
        WireUnsignedSemanticSnapshot
          { wireSnapshotProtocol = protocolVersion
          , wireSnapshotOrders = anchorToWire (validatedOrdersAnchor orders)
          , wireSnapshotIncarnation =
              emitterIncarnationValue (emitterCheckpointIncarnation checkpoint)
          , wireSnapshotCursor = cursorEntry emitter (emitterCheckpointCursor checkpoint)
          , wireSnapshotHeartbeat = heartbeatWire
          , wireSnapshotOwnership = ownershipWire
          }
      EventKey keyBytes = key
      wire =
        WireSignedSemanticSnapshot
          { wireSignedSnapshotUnsigned = unsigned
          , wireSignedSnapshotHmac = SHA256.hmac keyBytes (canonicalBytes unsigned)
          }
  validateWireSemanticSnapshotShape bounds wire
  Right (SignedSemanticSnapshot wire)

-- | Canonical bounded checkpoint payload suitable for the emitter repair
-- floor. Unlike repair-frame encoding, this boundary validates the standalone
-- snapshot and its total encoded size before exposing bytes to persistence.
encodeSignedSemanticSnapshot
  :: GatewayBounds
  -> SignedSemanticSnapshot
  -> Either PeerError ByteString
encodeSignedSemanticSnapshot bounds (SignedSemanticSnapshot wire) = do
  validateWireSemanticSnapshotShape bounds wire
  let encoded = canonicalBytes wire
  validateEncodedFrameBytes bounds encoded
  Right encoded

decodeSignedSemanticSnapshot
  :: GatewayBounds
  -> ByteString
  -> Either PeerError SignedSemanticSnapshot
decodeSignedSemanticSnapshot bounds bytes = do
  validateEncodedFrameBytes bounds bytes
  wire <- decodeCanonical "semantic snapshot" bytes
  validateWireSemanticSnapshotShape bounds wire
  Right (SignedSemanticSnapshot wire)

data SnapshotEvidenceKind
  = SnapshotHeartbeatEvidence
  | SnapshotOwnershipEvidence
  deriving (Eq, Show)

matchCheckpointEvidence
  :: GatewayBounds
  -> ValidatedOrders
  -> EventKeyLookup
  -> NodeId
  -> SnapshotEvidenceKind
  -> Maybe GatewayAssertion
  -> Maybe SignedAssertion
  -> Either PeerError (Maybe WireSignedAssertion)
matchCheckpointEvidence bounds orders lookupKey emitter evidenceKind expected supplied =
  case (expected, supplied) of
    (Nothing, Nothing) -> Right Nothing
    (Just _, Nothing) -> Left (PeerSnapshotEvidenceMissing emitter evidenceKind)
    (Nothing, Just _) -> Left (PeerSnapshotEvidenceUnexpected emitter evidenceKind)
    (Just expectedAssertion, Just signed@(SignedAssertion wire)) -> do
      semantic <- verifySignedAssertion bounds orders lookupKey signed
      unless
        (semantic == expectedAssertion)
        (Left (PeerSnapshotEvidenceMismatch emitter evidenceKind))
      Right (Just wire)

signedSemanticSnapshotEmitter :: SignedSemanticSnapshot -> Text
signedSemanticSnapshotEmitter (SignedSemanticSnapshot signed) =
  wireCursorEmitter
    (wireSnapshotCursor (wireSignedSnapshotUnsigned signed))

signedSemanticSnapshotIncarnation :: SignedSemanticSnapshot -> Word64
signedSemanticSnapshotIncarnation (SignedSemanticSnapshot signed) =
  wireSnapshotIncarnation (wireSignedSnapshotUnsigned signed)

signedSemanticSnapshotCursor
  :: SignedSemanticSnapshot
  -> Either PeerError EmitterCursor
signedSemanticSnapshotCursor (SignedSemanticSnapshot signed) =
  cursorEntryToCursor
    (wireSnapshotCursor (wireSignedSnapshotUnsigned signed))

-- | Select one bounded repair for a peer whose cursor has fallen behind the
-- retained replay frontier.  The checkpoint itself must advance that peer;
-- this prevents a size-truncated suffix from producing an atomic regression.
selectSignedRepair
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> SignedSemanticSnapshot
  -> [SignedAssertion]
  -> Either PeerError SignedRepairFrame
selectSignedRepair bounds orders peerCursor snapshot@(SignedSemanticSnapshot signedSnapshot) retained = do
  _ <- cursorToWire orders peerCursor
  validateWireSemanticSnapshotShape bounds signedSnapshot
  validateWireAnchor
    orders
    (wireSnapshotOrders (wireSignedSnapshotUnsigned signedSnapshot))
  emitter <- resolveEmitter orders (signedSemanticSnapshotEmitter snapshot)
  checkpointCursor <- signedSemanticSnapshotCursor snapshot
  peer <-
    case cursorVectorLookup emitter peerCursor of
      Nothing -> Left (PeerCursorMissingEmitter emitter)
      Just present -> Right present
  requireRepairCheckpointAhead emitter peer checkpointCursor
  let replayCapacity :: Natural
      replayCapacity =
        fromIntegral (gatewayMaxMembers bounds)
          * fromIntegral (gatewayReplayPerEmitter bounds)
      retainedCount :: Natural
      retainedCount = fromIntegral (length retained)
  when
    (retainedCount > replayCapacity)
    (Left (PeerSignedReplayCapacityExceeded retainedCount replayCapacity))
  traverse_ (validateRetainedAssertion bounds orders) retained
  suffix <-
    selectReplaySuffixFromIncarnation
      emitter
      (Just (signedSemanticSnapshotIncarnation snapshot))
      checkpointCursor
      ( sortOn
          signedAssertionPosition
          (filter ((== nodeIdText emitter) . signedAssertionEmitter) retained)
      )
  largestFittingRepair bounds orders snapshot suffix

-- | Daemon-facing constructor: authenticate the State-owned checkpoint with
-- its retained signed semantic evidence, then select the contiguous replayed
-- suffix in one bounded operation.
selectSignedRepairFromCheckpoint
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> EmitterCheckpoint
  -> Maybe SignedAssertion
  -> Maybe SignedAssertion
  -> EventKey
  -> [SignedAssertion]
  -> Either PeerError SignedRepairFrame
selectSignedRepairFromCheckpoint
  bounds
  orders
  peerCursor
  checkpoint
  heartbeat
  ownership
  key
  retained = do
    snapshot <-
      signSemanticSnapshot
        bounds
        orders
        checkpoint
        heartbeat
        ownership
        key
    selectSignedRepair bounds orders peerCursor snapshot retained

requireRepairCheckpointAhead
  :: NodeId
  -> EmitterCursor
  -> EmitterCursor
  -> Either PeerError ()
requireRepairCheckpointAhead emitter peer checkpoint =
  case compare (cursorCoordinates checkpoint) (cursorCoordinates peer) of
    LT -> Left (PeerRepairCheckpointNotAhead emitter peer checkpoint)
    EQ
      | emitterCursorHash checkpoint /= emitterCursorHash peer ->
          Left (PeerRepairCheckpointConflict emitter peer checkpoint)
      | otherwise -> Left (PeerRepairNotRequired emitter)
    GT -> Right ()

cursorCoordinates :: EmitterCursor -> (Word64, Word64)
cursorCoordinates cursor =
  ( emitterEpochValue (emitterCursorEpoch cursor)
  , emitterSequenceValue (emitterCursorSequence cursor)
  )

validateRetainedAssertion
  :: GatewayBounds
  -> ValidatedOrders
  -> SignedAssertion
  -> Either PeerError ()
validateRetainedAssertion bounds orders signed@(SignedAssertion wire) = do
  validateSignedAssertionShape bounds wire
  validateAssertionOrders orders (wireSignedUnsigned wire)
  _ <- resolveEmitter orders (signedAssertionEmitter signed)
  Right ()

largestFittingRepair
  :: GatewayBounds
  -> ValidatedOrders
  -> SignedSemanticSnapshot
  -> [SignedAssertion]
  -> Either PeerError SignedRepairFrame
largestFittingRepair bounds orders snapshot = go []
 where
  go accepted [] = mkSignedRepairFrame bounds orders snapshot accepted
  go accepted (candidate : remaining) =
    case mkSignedRepairFrame bounds orders snapshot (accepted ++ [candidate]) of
      Right _ -> go (accepted ++ [candidate]) remaining
      Left PeerEncodedFrameTooLarge {}
        | null accepted -> Left PeerRepairCannotFitAssertion
        | otherwise -> mkSignedRepairFrame bounds orders snapshot accepted
      Left PeerRepairAssertionCountExceeded {}
        | null accepted -> Left PeerRepairCannotFitAssertion
        | otherwise -> mkSignedRepairFrame bounds orders snapshot accepted
      Left err -> Left err

mkSignedRepairFrame
  :: GatewayBounds
  -> ValidatedOrders
  -> SignedSemanticSnapshot
  -> [SignedAssertion]
  -> Either PeerError SignedRepairFrame
mkSignedRepairFrame bounds orders snapshot@(SignedSemanticSnapshot signedSnapshot) suffix = do
  validateWireSemanticSnapshotShape bounds signedSnapshot
  validateWireAnchor
    orders
    (wireSnapshotOrders (wireSignedSnapshotUnsigned signedSnapshot))
  emitter <- resolveEmitter orders (signedSemanticSnapshotEmitter snapshot)
  checkpointCursor <- signedSemanticSnapshotCursor snapshot
  traverse_ (validateRetainedAssertion bounds orders) suffix
  unless
    (all ((== nodeIdText emitter) . signedAssertionEmitter) suffix)
    (Left (PeerRepairSuffixEmitterMismatch emitter))
  let sorted = sortOn signedAssertionPosition suffix
  selected <-
    selectReplaySuffixFromIncarnation
      emitter
      (Just (signedSemanticSnapshotIncarnation snapshot))
      checkpointCursor
      sorted
  unless
    (length selected == length sorted)
    (Left (PeerRepairSuffixContainsStale emitter))
  let evidenceCount = signedSnapshotEvidenceCount snapshot
      assertionCount = evidenceCount + length selected
  when
    (assertionCount > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( PeerRepairAssertionCountExceeded
            assertionCount
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  let frame =
        WireRepairFrame
          { wireRepairProtocol = protocolVersion
          , wireRepairOrders = anchorToWire (validatedOrdersAnchor orders)
          , wireRepairSnapshot = signedSnapshot
          , wireRepairAssertions = [wire | SignedAssertion wire <- selected]
          }
  validateWireRepairShape bounds frame
  Right (SignedRepairFrame frame)

signedSnapshotEvidenceCount :: SignedSemanticSnapshot -> Int
signedSnapshotEvidenceCount (SignedSemanticSnapshot signed) =
  let snapshot = wireSignedSnapshotUnsigned signed
   in length
        [ ()
        | Just _ <- [wireSnapshotHeartbeat snapshot, wireSnapshotOwnership snapshot]
        ]

encodeSignedRepairFrame :: SignedRepairFrame -> ByteString
encodeSignedRepairFrame (SignedRepairFrame frame) = canonicalBytes frame

decodeSignedRepairFrame
  :: GatewayBounds
  -> ByteString
  -> Either PeerError SignedRepairFrame
decodeSignedRepairFrame bounds bytes = do
  validateEncodedFrameBytes bounds bytes
  frame <- decodeCanonical "repair frame" bytes
  validateWireRepairShape bounds frame
  Right (SignedRepairFrame frame)

signedRepairAssertionCount :: SignedRepairFrame -> Int
signedRepairAssertionCount (SignedRepairFrame frame) =
  signedSnapshotEvidenceCount (SignedSemanticSnapshot (wireRepairSnapshot frame))
    + length (wireRepairAssertions frame)

verifyRepairFrame
  :: GatewayBounds
  -> EventKeyLookup
  -> GatewayState
  -> SignedRepairFrame
  -> Either PeerError EmitterRepair
verifyRepairFrame bounds lookupKey state (SignedRepairFrame frame) = do
  let orders = gatewayStateActiveOrders state
  validateWireRepairShape bounds frame
  validateWireAnchor orders (wireRepairOrders frame)
  checkpoint <-
    verifySemanticSnapshot
      bounds
      orders
      lookupKey
      (SignedSemanticSnapshot (wireRepairSnapshot frame))
  suffix <-
    traverse
      (verifySignedAssertion bounds orders lookupKey . SignedAssertion)
      (wireRepairAssertions frame)
  mapStateError (mkEmitterRepair bounds orders checkpoint suffix)

verifySemanticSnapshot
  :: GatewayBounds
  -> ValidatedOrders
  -> EventKeyLookup
  -> SignedSemanticSnapshot
  -> Either PeerError EmitterCheckpoint
verifySemanticSnapshot bounds orders lookupKey (SignedSemanticSnapshot signed) = do
  validateWireSemanticSnapshotShape bounds signed
  let snapshot = wireSignedSnapshotUnsigned signed
  validateWireAnchor orders (wireSnapshotOrders snapshot)
  emitter <- resolveEmitter orders (wireCursorEmitter (wireSnapshotCursor snapshot))
  key <-
    case lookupKey emitter of
      Nothing -> Left (PeerEventKeyUnavailable emitter)
      Just present -> Right present
  let EventKey keyBytes = key
      expectedHmac = SHA256.hmac keyBytes (canonicalBytes snapshot)
  unless
    (ByteArray.constEq expectedHmac (wireSignedSnapshotHmac signed))
    (Left (PeerSnapshotSignatureMismatch emitter))
  cursor <- cursorEntryToCursor (wireSnapshotCursor snapshot)
  heartbeat <-
    traverse
      (verifySignedAssertion bounds orders lookupKey . SignedAssertion)
      (wireSnapshotHeartbeat snapshot)
  ownership <-
    traverse
      (verifySignedAssertion bounds orders lookupKey . SignedAssertion)
      (wireSnapshotOwnership snapshot)
  mapStateError
    ( mkEmitterCheckpointForIncarnation
        bounds
        orders
        emitter
        (mkEmitterIncarnation (wireSnapshotIncarnation snapshot))
        cursor
        heartbeat
        ownership
    )

applySignedRepair
  :: GatewayBounds
  -> EventKeyLookup
  -> SignedRepairFrame
  -> GatewayState
  -> Either PeerError RepairApplyOutcome
applySignedRepair bounds lookupKey signed state = do
  repair <- verifyRepairFrame bounds lookupKey state signed
  Right (applyEmitterRepair repair state)

encodeCursorVector
  :: GatewayBounds
  -> ValidatedOrders
  -> CursorVector
  -> Either PeerError ByteString
encodeCursorVector bounds orders cursor = do
  wire <- cursorToWire orders cursor
  let encoded = canonicalBytes wire
  validateEncodedFrameBytes bounds encoded
  Right encoded

decodeCursorVector
  :: GatewayBounds
  -> ValidatedOrders
  -> ByteString
  -> Either PeerError CursorVector
decodeCursorVector bounds orders bytes = do
  validateEncodedFrameBytes bounds bytes
  wire <- decodeCanonical "cursor vector" bytes
  wireToCursor bounds orders wire

cursorToWire
  :: ValidatedOrders
  -> CursorVector
  -> Either PeerError WireCursorVector
cursorToWire orders cursor = do
  entries <- traverse toEntry (validatedOrdersMemberIds orders)
  Right
    WireCursorVector
      { wireCursorProtocol = protocolVersion
      , wireCursorOrders = anchorToWire (validatedOrdersAnchor orders)
      , wireCursorEntries = entries
      , wireCursorIncarnations =
          [ WireCursorIncarnation (nodeIdText emitter) 0
          | emitter <- validatedOrdersMemberIds orders
          ]
      }
 where
  toEntry emitter =
    case cursorVectorLookup emitter cursor of
      Nothing -> Left (PeerCursorMissingEmitter emitter)
      Just present -> Right (cursorEntry emitter present)

cursorEntry :: NodeId -> EmitterCursor -> WireCursorEntry
cursorEntry emitter cursor =
  WireCursorEntry
    { wireCursorEmitter = nodeIdText emitter
    , wireCursorEpoch = emitterEpochValue (emitterCursorEpoch cursor)
    , wireCursorSequence = emitterSequenceValue (emitterCursorSequence cursor)
    , wireCursorDigest = eventHashBytes (emitterCursorHash cursor)
    }

cursorEntryToCursor :: WireCursorEntry -> Either PeerError EmitterCursor
cursorEntryToCursor entry = do
  digest <- mapStateError (mkEventHash (wireCursorDigest entry))
  Right
    ( restoredEmitterCursor
        (wireCursorEpoch entry)
        (wireCursorSequence entry)
        digest
    )

wireToCursor
  :: GatewayBounds
  -> ValidatedOrders
  -> WireCursorVector
  -> Either PeerError CursorVector
wireToCursor bounds orders wire = do
  validateWireCursorShape bounds wire
  validateWireAnchor orders (wireCursorOrders wire)
  resolved <- traverse resolveEntry (wireCursorEntries wire)
  let emitters = map fst resolved
  when
    (Set.size (Set.fromList emitters) /= length emitters)
    (Left PeerCursorDuplicateEmitter)
  mapStateError (mkCursorVector orders (Map.fromList resolved))
 where
  resolveEntry entry = do
    emitter <- resolveEmitter orders (wireCursorEmitter entry)
    cursor <- cursorEntryToCursor entry
    Right (emitter, cursor)

signedAssertionPosition :: SignedAssertion -> (Text, Word64, Word64, Word64)
signedAssertionPosition (SignedAssertion wire) =
  let unsigned = wireSignedUnsigned wire
   in ( wireAssertionEmitter unsigned
      , wireAssertionIncarnation unsigned
      , wireAssertionEpoch unsigned
      , wireAssertionSequence unsigned
      )

validateWireDeltaShape :: GatewayBounds -> WireDeltaFrame -> Either PeerError ()
validateWireDeltaShape bounds frame = do
  validateProtocol (wireDeltaProtocol frame)
  validateWireCursorShape bounds (wireDeltaBaseCursor frame)
  unless
    (wireCursorOrders (wireDeltaBaseCursor frame) == wireDeltaOrders frame)
    (Left PeerDeltaCursorOrdersMismatch)
  let assertions = wireDeltaAssertions frame
      count = length assertions
  when
    (count > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( PeerDeltaAssertionCountExceeded
            count
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  traverse_ (validateSignedAssertionShape bounds) assertions
  let encoded = canonicalBytes frame
  validateEncodedFrameBytes bounds encoded

validateWireSemanticSnapshotShape
  :: GatewayBounds
  -> WireSignedSemanticSnapshot
  -> Either PeerError ()
validateWireSemanticSnapshotShape bounds signed = do
  let snapshot = wireSignedSnapshotUnsigned signed
      checkpoint = wireSnapshotCursor snapshot
      emitter = wireCursorEmitter checkpoint
  validateProtocol (wireSnapshotProtocol snapshot)
  validateAnchorShape (wireSnapshotOrders snapshot)
  validateEmitterBytes bounds emitter
  validateHashWidth (wireCursorDigest checkpoint)
  when
    (BS.length (wireSignedSnapshotHmac signed) /= signatureBytes)
    ( Left
        ( PeerSnapshotSignatureWidthInvalid
            signatureBytes
            (BS.length (wireSignedSnapshotHmac signed))
        )
    )
  traverse_
    (validateWireSnapshotEvidence bounds snapshot SnapshotHeartbeatEvidence)
    (wireSnapshotHeartbeat snapshot)
  traverse_
    (validateWireSnapshotEvidence bounds snapshot SnapshotOwnershipEvidence)
    (wireSnapshotOwnership snapshot)
  validateEncodedFrameBytes bounds (canonicalBytes signed)

validateWireSnapshotEvidence
  :: GatewayBounds
  -> WireUnsignedSemanticSnapshot
  -> SnapshotEvidenceKind
  -> WireSignedAssertion
  -> Either PeerError ()
validateWireSnapshotEvidence bounds snapshot evidenceKind wire = do
  validateSignedAssertionShape bounds wire
  let unsigned = wireSignedUnsigned wire
      checkpoint = wireSnapshotCursor snapshot
      emitter = wireCursorEmitter checkpoint
      evidencePosition =
        (wireAssertionEpoch unsigned, wireAssertionSequence unsigned)
      checkpointPosition =
        (wireCursorEpoch checkpoint, wireCursorSequence checkpoint)
  unless
    (wireAssertionOrders unsigned == wireSnapshotOrders snapshot)
    (Left PeerSnapshotOrdersMismatch)
  unless
    (wireAssertionEmitter unsigned == emitter)
    (Left (PeerSnapshotEvidenceEmitterMismatch emitter (wireAssertionEmitter unsigned)))
  when
    (wireAssertionIncarnation unsigned > wireSnapshotIncarnation snapshot)
    ( Left
        ( PeerSnapshotEvidenceIncarnationAhead
            emitter
            (wireAssertionIncarnation unsigned)
            (wireSnapshotIncarnation snapshot)
        )
    )
  unless
    (wireEvidenceKindMatches evidenceKind (wireAssertionKind unsigned))
    (Left (PeerSnapshotEvidenceWireKindMismatch emitter evidenceKind))
  when
    (evidencePosition > checkpointPosition)
    (Left (PeerSnapshotEvidencePositionAhead emitter))
  when
    ( evidencePosition == checkpointPosition
        && SHA256.hash (canonicalBytes wire) /= wireCursorDigest checkpoint
    )
    (Left (PeerSnapshotEvidenceCursorConflict emitter))

wireEvidenceKindMatches :: SnapshotEvidenceKind -> WireAssertionKind -> Bool
wireEvidenceKindMatches evidenceKind kind =
  case (evidenceKind, kind) of
    (SnapshotHeartbeatEvidence, WireHeartbeat _) -> True
    (SnapshotOwnershipEvidence, WireClaim) -> True
    (SnapshotOwnershipEvidence, WireYield) -> True
    _ -> False

validateWireRepairShape :: GatewayBounds -> WireRepairFrame -> Either PeerError ()
validateWireRepairShape bounds frame = do
  validateProtocol (wireRepairProtocol frame)
  validateAnchorShape (wireRepairOrders frame)
  validateWireSemanticSnapshotShape bounds (wireRepairSnapshot frame)
  let snapshot = wireSignedSnapshotUnsigned (wireRepairSnapshot frame)
      snapshotEmitter = wireCursorEmitter (wireSnapshotCursor snapshot)
      suffix = wireRepairAssertions frame
      evidenceCount =
        length
          [ ()
          | Just _ <- [wireSnapshotHeartbeat snapshot, wireSnapshotOwnership snapshot]
          ]
      assertionCount = evidenceCount + length suffix
  unless
    (wireSnapshotOrders snapshot == wireRepairOrders frame)
    (Left PeerSnapshotOrdersMismatch)
  when
    (assertionCount > gatewayMaxAssertionsPerFrame bounds)
    ( Left
        ( PeerRepairAssertionCountExceeded
            assertionCount
            (gatewayMaxAssertionsPerFrame bounds)
        )
    )
  traverse_ (validateSignedAssertionShape bounds) suffix
  traverse_
    ( \wire -> do
        let unsigned = wireSignedUnsigned wire
        unless
          (wireAssertionOrders unsigned == wireRepairOrders frame)
          (Left PeerSnapshotOrdersMismatch)
        unless
          (wireAssertionEmitter unsigned == snapshotEmitter)
          ( Left
              ( PeerSnapshotEvidenceEmitterMismatch
                  snapshotEmitter
                  (wireAssertionEmitter unsigned)
              )
          )
    )
    suffix
  let positions = map wireSignedAssertionPosition suffix
  unless (positions == sortOn id positions) (Left PeerRepairSuffixNotCanonical)
  foldM_
    advanceWireRepairCursor
    (wireSnapshotIncarnation snapshot, wireSnapshotCursor snapshot)
    suffix
  validateEncodedFrameBytes bounds (canonicalBytes frame)

wireSignedAssertionPosition :: WireSignedAssertion -> (Text, Word64, Word64, Word64)
wireSignedAssertionPosition wire =
  let unsigned = wireSignedUnsigned wire
   in ( wireAssertionEmitter unsigned
      , wireAssertionIncarnation unsigned
      , wireAssertionEpoch unsigned
      , wireAssertionSequence unsigned
      )

advanceWireRepairCursor
  :: (Word64, WireCursorEntry)
  -> WireSignedAssertion
  -> Either PeerError (Word64, WireCursorEntry)
advanceWireRepairCursor (currentIncarnation, cursor) wire = do
  semanticCursor <- cursorEntryToCursor cursor
  let signed = SignedAssertion wire
      unsigned = wireSignedUnsigned wire
      emitter = wireCursorEmitter cursor
  when
    (wireAssertionIncarnation unsigned < currentIncarnation)
    ( Left
        ( PeerSignedReplayStaleIncarnation
            emitter
            (wireAssertionIncarnation unsigned)
            currentIncarnation
        )
    )
  unless
    (signedDirectlyFollows semanticCursor signed)
    ( Left
        ( PeerRepairSuffixDiscontinuous
            emitter
            (wireCursorEpoch cursor)
            (wireCursorSequence cursor)
        )
    )
  Right
    ( wireAssertionIncarnation unsigned
    , WireCursorEntry
        { wireCursorEmitter = emitter
        , wireCursorEpoch = wireAssertionEpoch unsigned
        , wireCursorSequence = wireAssertionSequence unsigned
        , wireCursorDigest = SHA256.hash (canonicalBytes wire)
        }
    )

validateWireCursorShape :: GatewayBounds -> WireCursorVector -> Either PeerError ()
validateWireCursorShape bounds wire = do
  validateProtocol (wireCursorProtocol wire)
  validateAnchorShape (wireCursorOrders wire)
  let entries = wireCursorEntries wire
      incarnations = wireCursorIncarnations wire
  when
    (length entries > gatewayMaxMembers bounds)
    (Left (PeerCursorMemberCountExceeded (length entries) (gatewayMaxMembers bounds)))
  traverse_ validateEntry entries
  when
    (length incarnations /= length entries)
    (Left PeerCursorIncarnationShapeMismatch)
  traverse_
    (validateEmitterBytes bounds . wireCursorIncarnationEmitter)
    incarnations
  let emitterNames = map wireCursorEmitter entries
      incarnationNames = map wireCursorIncarnationEmitter incarnations
  when
    (Set.size (Set.fromList emitterNames) /= length emitterNames)
    (Left PeerCursorDuplicateEmitter)
  unless
    (emitterNames == sortOn id emitterNames)
    (Left PeerCursorEntriesNotCanonical)
  unless
    (incarnationNames == emitterNames)
    (Left PeerCursorIncarnationShapeMismatch)
 where
  validateEntry entry = do
    validateEmitterBytes bounds (wireCursorEmitter entry)
    validateHashWidth (wireCursorDigest entry)

validateSignedAssertionShape
  :: GatewayBounds
  -> WireSignedAssertion
  -> Either PeerError ()
validateSignedAssertionShape bounds wire = do
  let unsigned = wireSignedUnsigned wire
  validateProtocol (wireAssertionProtocol unsigned)
  validateAnchorShape (wireAssertionOrders unsigned)
  validateEmitterBytes bounds (wireAssertionEmitter unsigned)
  validateHashWidth (wireAssertionPreviousDigest unsigned)
  case wireAssertionKind unsigned of
    WireOrdersMigration scope -> do
      validateHashWidth (ordersMigrationPreviousOrdersDigest scope)
      when
        (ordersMigrationPreviousEpoch scope == maxBound)
        (Left (PeerOrdersMigrationEpochExhausted (wireAssertionEmitter unsigned)))
      unless
        ( wireAssertionEpoch unsigned == ordersMigrationPreviousEpoch scope + 1
            && wireAssertionSequence unsigned == 0
        )
        (Left PeerOrdersMigrationScopeMismatch)
    _ -> Right ()
  when
    (BS.length (wireSignedHmac wire) /= signatureBytes)
    ( Left
        ( PeerAssertionSignatureWidthInvalid
            signatureBytes
            (BS.length (wireSignedHmac wire))
        )
    )
  let actual = byteLength (canonicalBytes wire)
      allowed = gatewayMaxEncodedAssertionBytes bounds
  when (actual > allowed) (Left (PeerAssertionTooLarge actual allowed))

validateAssertionOrders
  :: ValidatedOrders
  -> WireUnsignedAssertion
  -> Either PeerError ()
validateAssertionOrders orders unsigned =
  validateWireAnchor orders (wireAssertionOrders unsigned)

validateWireAnchor :: ValidatedOrders -> WireOrdersAnchor -> Either PeerError ()
validateWireAnchor orders supplied =
  let expected = anchorToWire (validatedOrdersAnchor orders)
   in unless (supplied == expected) (Left (PeerOrdersAnchorMismatch expected supplied))

validateAnchorShape :: WireOrdersAnchor -> Either PeerError ()
validateAnchorShape anchor = do
  when (wireOrdersVersion anchor == 0) (Left PeerOrdersVersionMustBePositive)
  validateHashWidth (wireOrdersHash anchor)

anchorToWire :: OrdersAnchor -> WireOrdersAnchor
anchorToWire anchor =
  WireOrdersAnchor
    { wireOrdersVersion = ordersVersionValue (ordersAnchorVersion anchor)
    , wireOrdersHash = ordersAnchorHashBytes anchor
    }

validateEmitterBytes :: GatewayBounds -> Text -> Either PeerError ()
validateEmitterBytes bounds emitter = do
  let actual = textByteLength emitter
      allowed = gatewayMaxNodeIdBytes bounds
  when (Text.null (Text.strip emitter)) (Left PeerEmitterMustNotBeEmpty)
  when (actual > allowed) (Left (PeerEmitterTooLarge actual allowed))

validateHashWidth :: ByteString -> Either PeerError ()
validateHashWidth bytes =
  when
    (BS.length bytes /= hashBytes)
    (Left (PeerDigestWidthInvalid hashBytes (BS.length bytes)))

resolveEmitter :: ValidatedOrders -> Text -> Either PeerError NodeId
resolveEmitter orders raw =
  case find ((== raw) . nodeIdText) (validatedOrdersMemberIds orders) of
    Nothing -> Left (PeerUnknownEmitter raw)
    Just emitter -> Right emitter

validateProtocol :: Word16 -> Either PeerError ()
validateProtocol observed =
  unless
    (observed == protocolVersion)
    (Left (PeerProtocolVersionMismatch protocolVersion observed))

validateEncodedFrameBytes :: GatewayBounds -> ByteString -> Either PeerError ()
validateEncodedFrameBytes bounds bytes = do
  let actual = byteLength bytes
      allowed = gatewayMaxFrameBytes bounds
  when (BS.null bytes) (Left PeerEncodedFrameMustNotBeEmpty)
  when (actual > allowed) (Left (PeerEncodedFrameTooLarge actual allowed))

decodeCanonical
  :: (Eq value, Serialise value)
  => Text
  -> ByteString
  -> Either PeerError value
decodeCanonical label bytes = do
  value <-
    first
      (PeerCborDecodeFailed label . Text.pack . show)
      (deserialiseOrFail (BL.fromStrict bytes))
  unless (canonicalBytes value == bytes) (Left (PeerNonCanonicalCbor label))
  Right value

canonicalBytes :: (Serialise value) => value -> ByteString
canonicalBytes = BL.toStrict . serialise

data PeerTransportRequest
  = PeerPushDelta SignedDeltaFrame
  | PeerPushRepair SignedRepairFrame
  | PeerPullCursor
  deriving (Eq, Show)

-- | Opaque list whose cardinality was accepted by the enclosing bounded frame
-- constructor or parser.  Daemon relay retention can consume it without
-- reopening an unbounded raw-list boundary.
newtype BoundedSignedAssertions = BoundedSignedAssertions [SignedAssertion]
  deriving (Eq, Show)

peerRequestReplayAssertions
  :: PeerTransportRequest
  -> BoundedSignedAssertions
peerRequestReplayAssertions request =
  BoundedSignedAssertions $ case request of
    PeerPushDelta (SignedDeltaFrame frame) ->
      map SignedAssertion (wireDeltaAssertions frame)
    PeerPushRepair (SignedRepairFrame frame) ->
      map SignedAssertion (wireRepairAssertions frame)
    PeerPullCursor -> []

peerRequestSnapshotEvidence
  :: PeerTransportRequest
  -> BoundedSignedAssertions
peerRequestSnapshotEvidence request =
  case peerRequestSemanticSnapshot request of
    Nothing -> BoundedSignedAssertions []
    Just snapshot -> signedSemanticSnapshotEvidence snapshot

-- | At most the two typed semantic slots (heartbeat and ownership) can be
-- present.  Their exact signed bytes are preserved for future checkpoint
-- relay after an inbound repair.
signedSemanticSnapshotEvidence
  :: SignedSemanticSnapshot
  -> BoundedSignedAssertions
signedSemanticSnapshotEvidence (SignedSemanticSnapshot signed) =
  let snapshot = wireSignedSnapshotUnsigned signed
   in BoundedSignedAssertions
        [ SignedAssertion wire
        | Just wire <-
            [wireSnapshotHeartbeat snapshot, wireSnapshotOwnership snapshot]
        ]

boundedSignedAssertionsToList
  :: BoundedSignedAssertions
  -> [SignedAssertion]
boundedSignedAssertionsToList (BoundedSignedAssertions assertions) = assertions

peerRequestSemanticSnapshot
  :: PeerTransportRequest
  -> Maybe SignedSemanticSnapshot
peerRequestSemanticSnapshot request =
  case request of
    PeerPushRepair (SignedRepairFrame frame) ->
      Just (SignedSemanticSnapshot (wireRepairSnapshot frame))
    PeerPushDelta _ -> Nothing
    PeerPullCursor -> Nothing

-- | Observe the bounded wire Orders version before exact active-anchor
-- validation.  The daemon uses this only as a restart/reclaim fence; semantic
-- application still requires the complete version+hash anchor to verify.
peerRequestOrdersVersion :: PeerTransportRequest -> Maybe Word64
peerRequestOrdersVersion request =
  case request of
    PeerPushDelta (SignedDeltaFrame frame) ->
      Just (wireOrdersVersion (wireDeltaOrders frame))
    PeerPushRepair (SignedRepairFrame frame) ->
      Just (wireOrdersVersion (wireRepairOrders frame))
    PeerPullCursor -> Nothing

-- | Validate only newly replayed heartbeat assertions.  Checkpoint heartbeat
-- evidence can be intentionally old and is authenticated as retained semantic
-- history, so it is not subjected to the live-arrival skew window.
validatePeerRequestHeartbeatSkew
  :: Word64
  -> Word64
  -> PeerTransportRequest
  -> Either PeerError ()
validatePeerRequestHeartbeatSkew now maximumSkew request =
  traverse_ validateOne replayed
 where
  replayed =
    boundedSignedAssertionsToList (peerRequestReplayAssertions request)

  validateOne assertion =
    case signedAssertionKind assertion of
      HeartbeatAssertion timestamp ->
        let observedSkew =
              if timestamp <= now
                then now - timestamp
                else timestamp - now
         in when
              (observedSkew > maximumSkew)
              ( Left
                  ( PeerHeartbeatSkewExceeded
                      (signedAssertionEmitter assertion)
                      timestamp
                      now
                      maximumSkew
                  )
              )
      OwnershipAssertion _ -> Right ()
      EpochRotationAssertion -> Right ()
      OrdersMigrationAssertion _ -> Right ()

data PeerRejectionCode
  = PeerRejectMalformedHttp
  | PeerRejectFrameBound
  | PeerRejectDecode
  | PeerRejectProtocol
  | PeerRejectOrders
  | PeerRejectEmitter
  | PeerRejectSignature
  | PeerRejectCursor
  | PeerRejectContinuity
  | PeerRejectSemanticState
  deriving (Bounded, Enum, Eq, Generic, Ord, Show)

instance Serialise PeerRejectionCode

data WireRejectionSample = WireRejectionSample
  { wireRejectionCode :: PeerRejectionCode
  , wireRejectionEmitter :: Maybe Text
  , wireRejectionEpoch :: Maybe Word64
  , wireRejectionSequence :: Maybe Word64
  }
  deriving (Eq, Generic, Show)

instance Serialise WireRejectionSample

data PeerTransportResponse
  = PeerResponseCursor WireCursorVector
  | PeerResponseDeltaApplied WireCursorVector [WireRejectionSample]
  | PeerResponseDeltaRejected
      PeerRejectionCode
      WireCursorVector
      [WireRejectionSample]
  | PeerResponseError PeerRejectionCode
  deriving (Eq, Generic, Show)

instance Serialise PeerTransportResponse

-- | Pure bounded request handler.  Signature/decode failures leave semantic
-- state unchanged.  Atomic semantic rejection returns the State module's
-- unchanged-but-diagnosed state, whose rejection ring is already bounded.
handlePeerRequest
  :: GatewayBounds
  -> EventKeyLookup
  -> PeerTransportRequest
  -> GatewayState
  -> Either PeerError (GatewayState, PeerTransportResponse)
handlePeerRequest bounds lookupKey request state =
  case request of
    PeerPullCursor -> do
      cursor <- cursorFromState state
      Right (state, PeerResponseCursor cursor)
    PeerPushDelta signed ->
      case applySignedDelta bounds lookupKey signed state of
        Left err -> do
          cursor <- cursorFromState state
          Right
            ( state
            , PeerResponseDeltaRejected
                (peerErrorCode err)
                cursor
                (boundedSamples bounds [peerErrorSample err] state)
            )
        Right outcome ->
          case outcome of
            DeltaApplied advanced -> do
              cursor <- cursorFromState advanced
              Right
                ( advanced
                , PeerResponseDeltaApplied
                    cursor
                    (boundedSamples bounds [] advanced)
                )
            DeltaRejected diagnosed _err -> do
              cursor <- cursorFromState diagnosed
              Right
                ( diagnosed
                , PeerResponseDeltaRejected
                    PeerRejectSemanticState
                    cursor
                    (boundedSamples bounds [] diagnosed)
                )
    PeerPushRepair signed ->
      case applySignedRepair bounds lookupKey signed state of
        Left err -> rejected err state
        Right outcome ->
          case outcome of
            RepairApplied advanced -> accepted advanced
            RepairDuplicate unchanged -> accepted unchanged
            RepairRejected diagnosed _err ->
              rejectedWithState PeerRejectSemanticState diagnosed
 where
  accepted advanced = do
    cursor <- cursorFromState advanced
    Right
      ( advanced
      , PeerResponseDeltaApplied
          cursor
          (boundedSamples bounds [] advanced)
      )

  rejected err unchanged =
    rejectedWithState (peerErrorCode err) unchanged

  rejectedWithState code unchanged = do
    cursor <- cursorFromState unchanged
    Right
      ( unchanged
      , PeerResponseDeltaRejected
          code
          cursor
          (boundedSamples bounds [] unchanged)
      )

peerErrorResponse :: PeerError -> PeerTransportResponse
peerErrorResponse = PeerResponseError . peerErrorCode

peerResponseAccepted :: PeerTransportResponse -> Bool
peerResponseAccepted response =
  case response of
    PeerResponseCursor _ -> True
    PeerResponseDeltaApplied _ _ -> True
    PeerResponseDeltaRejected {} -> False
    PeerResponseError _ -> False

peerResponseCursorVector
  :: GatewayBounds
  -> ValidatedOrders
  -> PeerTransportResponse
  -> Either PeerError (Maybe CursorVector)
peerResponseCursorVector bounds orders response =
  traverse (wireToCursor bounds orders) (peerResponseWireCursor response)

-- | Recover the exact incarnation-aware acknowledgement for one emitter from
-- a peer response. The incarnation is explicit response data, not inferred
-- from the receiver's current mount, and the fixed-width cursor digest is
-- re-entered through the continuity smart constructor before producing the
-- Kernel-owned 'AckPoint'.
peerResponseAckPoint
  :: GatewayBounds
  -> ValidatedOrders
  -> NodeId
  -> PeerTransportResponse
  -> Either PeerError (Maybe AckPoint)
peerResponseAckPoint bounds orders emitter response =
  case peerResponseWireCursor response of
    Nothing -> Right Nothing
    Just wire -> do
      _ <- wireToCursor bounds orders wire
      let emitterName = nodeIdText emitter
      cursor <-
        case find ((== emitterName) . wireCursorEmitter) (wireCursorEntries wire) of
          Nothing -> Left (PeerCursorMissingEmitter emitter)
          Just present -> Right present
      incarnation <-
        case find
          ((== emitterName) . wireCursorIncarnationEmitter)
          (wireCursorIncarnations wire) of
          Nothing -> Left PeerCursorIncarnationShapeMismatch
          Just present -> Right (wireCursorIncarnationValue present)
      digest <-
        first
          (const (PeerDigestWidthInvalid hashBytes (BS.length (wireCursorDigest cursor))))
          (mkContinuityDigest (wireCursorDigest cursor))
      Right
        ( Just
            ( mkAckPoint
                (mkEmitterIncarnation incarnation)
                ( restoreContinuityAnchor
                    (wireCursorEpoch cursor)
                    (wireCursorSequence cursor)
                    digest
                )
            )
        )

peerResponseWireCursor :: PeerTransportResponse -> Maybe WireCursorVector
peerResponseWireCursor response = case response of
  PeerResponseCursor cursor -> Just cursor
  PeerResponseDeltaApplied cursor _ -> Just cursor
  PeerResponseDeltaRejected _ cursor _ -> Just cursor
  PeerResponseError _ -> Nothing

cursorFromState :: GatewayState -> Either PeerError WireCursorVector
cursorFromState state = do
  let orders = gatewayStateActiveOrders state
  wire <- cursorToWire orders (gatewayStateCursorVector state)
  incarnations <- traverse exactIncarnation (validatedOrdersMemberIds orders)
  Right wire {wireCursorIncarnations = incarnations}
 where
  exactIncarnation emitter =
    case gatewayStateEmitterIncarnation emitter state of
      Nothing -> Left (PeerCursorMissingEmitter emitter)
      Just incarnation ->
        Right
          WireCursorIncarnation
            { wireCursorIncarnationEmitter = nodeIdText emitter
            , wireCursorIncarnationValue = emitterIncarnationValue incarnation
            }

boundedSamples
  :: GatewayBounds
  -> [WireRejectionSample]
  -> GatewayState
  -> [WireRejectionSample]
boundedSamples bounds immediate state =
  take
    (gatewayMaxRejectionSamples bounds)
    (immediate ++ map stateSampleToWire stateSamples)
 where
  stateSamples =
    rejectionSamples (gatewayStateRejectionSummary state)

stateSampleToWire :: RejectionSample -> WireRejectionSample
stateSampleToWire sample =
  WireRejectionSample
    { wireRejectionCode = stateReasonCode (rejectionSampleReason sample)
    , wireRejectionEmitter = nodeIdText <$> rejectionSampleEmitter sample
    , wireRejectionEpoch = rejectionSampleEpoch sample
    , wireRejectionSequence = rejectionSampleSequence sample
    }

stateReasonCode :: RejectionReason -> PeerRejectionCode
stateReasonCode _ = PeerRejectSemanticState

peerErrorSample :: PeerError -> WireRejectionSample
peerErrorSample err =
  WireRejectionSample
    { wireRejectionCode = peerErrorCode err
    , wireRejectionEmitter = peerErrorEmitter err
    , wireRejectionEpoch = Nothing
    , wireRejectionSequence = Nothing
    }

peerErrorEmitter :: PeerError -> Maybe Text
peerErrorEmitter err =
  case err of
    PeerEventKeyUnavailable emitter -> Just (nodeIdText emitter)
    PeerAssertionSignatureMismatch emitter -> Just (nodeIdText emitter)
    PeerEpochInvalidationBeforeExhaustion emitter _ -> Just (nodeIdText emitter)
    PeerEmitterCountersExhausted emitter -> Just (nodeIdText emitter)
    PeerEpochInvalidationRequired emitter _ -> Just (nodeIdText emitter)
    PeerEpochInvalidationSequenceInvalid emitter _ -> Just (nodeIdText emitter)
    PeerEpochInvalidationEpochInvalid emitter -> Just (nodeIdText emitter)
    PeerOrdersMigrationEpochExhausted emitter -> Just emitter
    PeerSemanticSequenceInvalid emitter -> Just (nodeIdText emitter)
    PeerSignedReplayUnavailable emitter _ _ -> Just (nodeIdText emitter)
    PeerSignedReplayCursorConflict emitter _ _ -> Just (nodeIdText emitter)
    PeerSignedReplayStaleIncarnation emitter _ _ -> Just emitter
    PeerSnapshotSignatureMismatch emitter -> Just (nodeIdText emitter)
    PeerSnapshotEvidenceMissing emitter _ -> Just (nodeIdText emitter)
    PeerSnapshotEvidenceUnexpected emitter _ -> Just (nodeIdText emitter)
    PeerSnapshotEvidenceMismatch emitter _ -> Just (nodeIdText emitter)
    PeerSnapshotEvidenceEmitterMismatch emitter _ -> Just emitter
    PeerSnapshotEvidenceWireKindMismatch emitter _ -> Just emitter
    PeerSnapshotEvidencePositionAhead emitter -> Just emitter
    PeerSnapshotEvidenceCursorConflict emitter -> Just emitter
    PeerSnapshotEvidenceIncarnationAhead emitter _ _ -> Just emitter
    PeerRepairCheckpointNotAhead emitter _ _ -> Just (nodeIdText emitter)
    PeerRepairCheckpointConflict emitter _ _ -> Just (nodeIdText emitter)
    PeerRepairNotRequired emitter -> Just (nodeIdText emitter)
    PeerRepairSuffixEmitterMismatch emitter -> Just (nodeIdText emitter)
    PeerRepairSuffixContainsStale emitter -> Just (nodeIdText emitter)
    PeerRepairSuffixDiscontinuous emitter _ _ -> Just emitter
    PeerHeartbeatSkewExceeded emitter _ _ _ -> Just emitter
    PeerUnknownEmitter emitter -> Just emitter
    PeerCursorMissingEmitter emitter -> Just (nodeIdText emitter)
    _ -> Nothing

-- | Maximum header bytes, including the terminating CRLFCRLF.  The daemon
-- reads no body until this preflight has accepted Content-Length.
peerHttpHeaderLimitBytes :: Int
peerHttpHeaderLimitBytes = 8192

data PeerHttpRoute = HttpPostDelta | HttpPostRepair | HttpGetCursor | HttpResponse
  deriving (Eq, Show)

data PeerHttpPreflight = PeerHttpPreflight
  { internalHttpRoute :: PeerHttpRoute
  , internalHttpHeaderBytes :: Int
  , internalHttpExpectedBodyBytes :: Int
  }
  deriving (Eq, Show)

peerHttpHeaderBytes :: PeerHttpPreflight -> Int
peerHttpHeaderBytes = internalHttpHeaderBytes

peerHttpExpectedBodyBytes :: PeerHttpPreflight -> Int
peerHttpExpectedBodyBytes = internalHttpExpectedBodyBytes

preflightPeerHttpRequest
  :: GatewayBounds
  -> ByteString
  -> Either PeerError PeerHttpPreflight
preflightPeerHttpRequest bounds raw = do
  (header, consumed) <- locateBoundedHeader raw
  headerLines <- parseHeaderLines header
  route <- case headerLines of
    [] -> Left PeerHttpMalformedRequestLine
    requestLine : _ -> parseRequestLine requestLine
  contentLength <- parseContentLength (drop 1 headerLines)
  validateRouteBodyLength route contentLength
  validateHttpBodyBound bounds contentLength
  Right
    PeerHttpPreflight
      { internalHttpRoute = route
      , internalHttpHeaderBytes = consumed
      , internalHttpExpectedBodyBytes = naturalToInt contentLength
      }

preflightPeerHttpResponse
  :: GatewayBounds
  -> ByteString
  -> Either PeerError PeerHttpPreflight
preflightPeerHttpResponse bounds raw = do
  (header, consumed) <- locateBoundedHeader raw
  headerLines <- parseHeaderLines header
  case headerLines of
    [] -> Left PeerHttpMalformedResponseLine
    statusLine : _ -> validateResponseLine statusLine
  contentLength <- parseContentLength (drop 1 headerLines)
  validateHttpBodyBound bounds contentLength
  Right
    PeerHttpPreflight
      { internalHttpRoute = HttpResponse
      , internalHttpHeaderBytes = consumed
      , internalHttpExpectedBodyBytes = naturalToInt contentLength
      }

parsePeerHttpRequest
  :: GatewayBounds
  -> ByteString
  -> Either PeerError PeerTransportRequest
parsePeerHttpRequest bounds raw = do
  preflight <- preflightPeerHttpRequest bounds raw
  body <- exactHttpBody preflight raw
  case internalHttpRoute preflight of
    HttpPostDelta -> PeerPushDelta <$> decodeSignedDeltaFrame bounds body
    HttpPostRepair -> PeerPushRepair <$> decodeSignedRepairFrame bounds body
    HttpGetCursor -> Right PeerPullCursor
    HttpResponse -> Left PeerHttpMalformedRequestLine

parsePeerHttpResponse
  :: GatewayBounds
  -> ByteString
  -> Either PeerError PeerTransportResponse
parsePeerHttpResponse bounds raw = do
  preflight <- preflightPeerHttpResponse bounds raw
  body <- exactHttpBody preflight raw
  response <- decodeCanonical "peer response" body
  validateResponseShape bounds response
  Right response

renderPeerHttpResponse
  :: GatewayBounds
  -> PeerTransportResponse
  -> Either PeerError ByteString
renderPeerHttpResponse bounds response = do
  validateResponseShape bounds response
  let body = canonicalBytes response
  validateEncodedFrameBytes bounds body
  let status = case response of
        PeerResponseCursor _ -> "200 OK"
        PeerResponseDeltaApplied _ _ -> "200 OK"
        PeerResponseDeltaRejected {} -> "409 Conflict"
        PeerResponseError _ -> "400 Bad Request"
  Right (renderHttpMessage ("HTTP/1.1 " <> status) [] body)

renderPeerDeltaRequest
  :: GatewayBounds
  -> Text
  -> SignedDeltaFrame
  -> Either PeerError ByteString
renderPeerDeltaRequest bounds host frame = do
  validateHttpHost host
  let body = encodeSignedDeltaFrame frame
  validateEncodedFrameBytes bounds body
  Right
    ( renderHttpMessage
        "POST /v1/peer/delta HTTP/1.1"
        [("Host", host), ("Content-Type", "application/cbor")]
        body
    )

renderPeerRepairRequest
  :: GatewayBounds
  -> Text
  -> SignedRepairFrame
  -> Either PeerError ByteString
renderPeerRepairRequest bounds host frame = do
  validateHttpHost host
  let body = encodeSignedRepairFrame frame
  validateEncodedFrameBytes bounds body
  Right
    ( renderHttpMessage
        "POST /v1/peer/repair HTTP/1.1"
        [("Host", host), ("Content-Type", "application/cbor")]
        body
    )

renderPeerCursorRequest :: Text -> Either PeerError ByteString
renderPeerCursorRequest host = do
  validateHttpHost host
  Right
    ( renderHttpMessage
        "GET /v1/peer/cursor HTTP/1.1"
        [("Host", host)]
        BS.empty
    )

validateResponseShape
  :: GatewayBounds
  -> PeerTransportResponse
  -> Either PeerError ()
validateResponseShape bounds response =
  case response of
    PeerResponseCursor cursor -> validateWireCursorShape bounds cursor
    PeerResponseDeltaApplied cursor samples -> do
      validateWireCursorShape bounds cursor
      validateSampleCount bounds samples
    PeerResponseDeltaRejected _ cursor samples -> do
      validateWireCursorShape bounds cursor
      validateSampleCount bounds samples
    PeerResponseError _ -> Right ()

validateSampleCount
  :: GatewayBounds
  -> [WireRejectionSample]
  -> Either PeerError ()
validateSampleCount bounds samples =
  when
    (length samples > gatewayMaxRejectionSamples bounds)
    ( Left
        ( PeerRejectionSampleCountExceeded
            (length samples)
            (gatewayMaxRejectionSamples bounds)
        )
    )

locateBoundedHeader :: ByteString -> Either PeerError (ByteString, Int)
locateBoundedHeader raw =
  let delimiter = "\r\n\r\n"
      (header, suffix) = BS.breakSubstring delimiter raw
      consumed = BS.length header + BS.length delimiter
   in if BS.null suffix
        then
          if BS.length raw >= peerHttpHeaderLimitBytes
            then
              Left
                ( PeerHttpHeaderTooLarge
                    (BS.length raw)
                    peerHttpHeaderLimitBytes
                )
            else Left PeerHttpHeaderIncomplete
        else
          if consumed > peerHttpHeaderLimitBytes
            then Left (PeerHttpHeaderTooLarge consumed peerHttpHeaderLimitBytes)
            else Right (header, consumed)

parseHeaderLines :: ByteString -> Either PeerError [ByteString]
parseHeaderLines header = do
  when (BS.elem 0 header) (Left PeerHttpHeaderContainsNul)
  let lines' = splitCrlf header
  when (any BS.null lines') (Left PeerHttpMalformedHeader)
  Right lines'

splitCrlf :: ByteString -> [ByteString]
splitCrlf bytes
  | BS.null bytes = []
  | otherwise =
      let delimiter = "\r\n"
          (line, suffix) = BS.breakSubstring delimiter bytes
       in if BS.null suffix
            then [line]
            else line : splitCrlf (BS.drop (BS.length delimiter) suffix)

parseRequestLine :: ByteString -> Either PeerError PeerHttpRoute
parseRequestLine line =
  case BS8.words line of
    ["POST", "/v1/peer/delta", "HTTP/1.1"] -> Right HttpPostDelta
    ["POST", "/v1/peer/repair", "HTTP/1.1"] -> Right HttpPostRepair
    ["GET", "/v1/peer/cursor", "HTTP/1.1"] -> Right HttpGetCursor
    [method, path, "HTTP/1.1"] ->
      Left
        ( PeerHttpUnsupportedRoute
            (decodeHeaderText method)
            (decodeHeaderText path)
        )
    _ -> Left PeerHttpMalformedRequestLine

validateResponseLine :: ByteString -> Either PeerError ()
validateResponseLine line =
  case BS8.words line of
    ("HTTP/1.1" : status : _)
      | BS.length status == 3 && BS.all (isDigit . toChar) status -> Right ()
    _ -> Left PeerHttpMalformedResponseLine
 where
  toChar = toEnum . fromEnum

parseContentLength :: [ByteString] -> Either PeerError Natural
parseContentLength headerLines = do
  headers <- traverse parseHeader headerLines
  when
    (any ((== "transfer-encoding") . fst) headers)
    (Left PeerHttpTransferEncodingForbidden)
  case [value | (name, value) <- headers, name == "content-length"] of
    [] -> Left PeerHttpContentLengthMissing
    [raw] -> parseNaturalDecimal raw
    _ -> Left PeerHttpContentLengthDuplicate

parseHeader :: ByteString -> Either PeerError (ByteString, ByteString)
parseHeader line =
  let (rawName, suffix) = BS8.break (== ':') line
   in if BS.null rawName || BS.null suffix
        then Left PeerHttpMalformedHeader
        else
          let name = BS8.map toLower rawName
              value = trimAsciiSpace (BS.drop 1 suffix)
           in if BS.any invalidHeaderNameByte name
                then Left PeerHttpMalformedHeader
                else Right (name, value)

invalidHeaderNameByte :: Word8 -> Bool
invalidHeaderNameByte byte =
  byte <= 32 || byte >= 127 || byte == fromIntegral (fromEnum ':')

trimAsciiSpace :: ByteString -> ByteString
trimAsciiSpace = BS8.dropWhileEnd isSpaceTab . BS8.dropWhile isSpaceTab
 where
  isSpaceTab char = char == ' ' || char == '\t'

parseNaturalDecimal :: ByteString -> Either PeerError Natural
parseNaturalDecimal raw = do
  when
    (BS.null raw || not (BS.all (isDigit . toChar) raw))
    (Left (PeerHttpContentLengthInvalid (decodeHeaderText raw)))
  foldM step 0 (BS.unpack raw)
 where
  toChar = toEnum . fromEnum
  step total digit =
    Right (total * 10 + fromIntegral (digit - fromIntegral (fromEnum '0')))

validateRouteBodyLength :: PeerHttpRoute -> Natural -> Either PeerError ()
validateRouteBodyLength route bodyLength =
  case route of
    HttpGetCursor ->
      when (bodyLength /= 0) (Left (PeerHttpCursorBodyMustBeEmpty bodyLength))
    HttpPostDelta -> Right ()
    HttpPostRepair -> Right ()
    HttpResponse -> Right ()

validateHttpBodyBound :: GatewayBounds -> Natural -> Either PeerError ()
validateHttpBodyBound bounds bodyLength =
  when
    (bodyLength > gatewayMaxFrameBytes bounds)
    ( Left
        ( PeerHttpContentLengthTooLarge
            bodyLength
            (gatewayMaxFrameBytes bounds)
        )
    )

exactHttpBody :: PeerHttpPreflight -> ByteString -> Either PeerError ByteString
exactHttpBody preflight raw =
  let body = BS.drop (peerHttpHeaderBytes preflight) raw
      expected = peerHttpExpectedBodyBytes preflight
      actual = BS.length body
   in if actual == expected
        then Right body
        else Left (PeerHttpBodyLengthMismatch expected actual)

renderHttpMessage
  :: ByteString
  -> [(ByteString, Text)]
  -> ByteString
  -> ByteString
renderHttpMessage firstLine extraHeaders body =
  BS.concat
    [ firstLine
    , "\r\n"
    , BS.concat (map renderHeader extraHeaders)
    , "Content-Length: "
    , BS8.pack (show (BS.length body))
    , "\r\nConnection: close\r\n\r\n"
    , body
    ]
 where
  renderHeader (name, value) =
    BS.concat [name, ": ", TextEncoding.encodeUtf8 value, "\r\n"]

validateHttpHost :: Text -> Either PeerError ()
validateHttpHost host = do
  when (Text.null (Text.strip host)) (Left PeerHttpHostMustNotBeEmpty)
  when
    (Text.any (\char -> char == '\r' || char == '\n' || char == '\NUL') host)
    (Left PeerHttpHostContainsControl)

decodeHeaderText :: ByteString -> Text
decodeHeaderText = TextEncoding.decodeUtf8With (\_ _ -> Just '\xfffd')

naturalToInt :: Natural -> Int
naturalToInt = fromIntegral

mapStateError :: Either GatewayStateError value -> Either PeerError value
mapStateError = first PeerStateError

byteLength :: ByteString -> Natural
byteLength = fromIntegral . BS.length

textByteLength :: Text -> Natural
textByteLength = byteLength . TextEncoding.encodeUtf8

peerErrorCode :: PeerError -> PeerRejectionCode
peerErrorCode err =
  case err of
    PeerHttpHeaderIncomplete -> PeerRejectMalformedHttp
    PeerHttpHeaderTooLarge {} -> PeerRejectMalformedHttp
    PeerHttpHeaderContainsNul -> PeerRejectMalformedHttp
    PeerHttpMalformedRequestLine -> PeerRejectMalformedHttp
    PeerHttpMalformedResponseLine -> PeerRejectMalformedHttp
    PeerHttpUnsupportedRoute {} -> PeerRejectMalformedHttp
    PeerHttpMalformedHeader -> PeerRejectMalformedHttp
    PeerHttpContentLengthMissing -> PeerRejectMalformedHttp
    PeerHttpContentLengthDuplicate -> PeerRejectMalformedHttp
    PeerHttpContentLengthInvalid {} -> PeerRejectMalformedHttp
    PeerHttpTransferEncodingForbidden -> PeerRejectMalformedHttp
    PeerHttpCursorBodyMustBeEmpty {} -> PeerRejectMalformedHttp
    PeerHttpBodyLengthMismatch {} -> PeerRejectMalformedHttp
    PeerHttpHostMustNotBeEmpty -> PeerRejectMalformedHttp
    PeerHttpHostContainsControl -> PeerRejectMalformedHttp
    PeerHttpContentLengthTooLarge {} -> PeerRejectFrameBound
    PeerEncodedFrameMustNotBeEmpty -> PeerRejectFrameBound
    PeerEncodedFrameTooLarge {} -> PeerRejectFrameBound
    PeerAssertionTooLarge {} -> PeerRejectFrameBound
    PeerDeltaAssertionCountExceeded {} -> PeerRejectFrameBound
    PeerSignedReplayCapacityExceeded {} -> PeerRejectFrameBound
    PeerDeltaCannotFitAssertion -> PeerRejectFrameBound
    PeerRepairAssertionCountExceeded {} -> PeerRejectFrameBound
    PeerRepairCannotFitAssertion -> PeerRejectFrameBound
    PeerCursorMemberCountExceeded {} -> PeerRejectFrameBound
    PeerRejectionSampleCountExceeded {} -> PeerRejectFrameBound
    PeerCborDecodeFailed {} -> PeerRejectDecode
    PeerNonCanonicalCbor {} -> PeerRejectDecode
    PeerProtocolVersionMismatch {} -> PeerRejectProtocol
    PeerOrdersVersionMustBePositive -> PeerRejectOrders
    PeerOrdersAnchorMismatch {} -> PeerRejectOrders
    PeerDeltaCursorOrdersMismatch -> PeerRejectOrders
    PeerEmitterMustNotBeEmpty -> PeerRejectEmitter
    PeerEmitterTooLarge {} -> PeerRejectEmitter
    PeerUnknownEmitter {} -> PeerRejectEmitter
    PeerEventKeyMustNotBeEmpty -> PeerRejectSignature
    PeerEventKeyTooSmall {} -> PeerRejectSignature
    PeerEventKeyTooLarge {} -> PeerRejectSignature
    PeerEventKeyUnavailable {} -> PeerRejectSignature
    PeerAssertionSignatureWidthInvalid {} -> PeerRejectSignature
    PeerAssertionSignatureMismatch {} -> PeerRejectSignature
    PeerSnapshotSignatureWidthInvalid {} -> PeerRejectSignature
    PeerSnapshotSignatureMismatch {} -> PeerRejectSignature
    PeerSnapshotEvidenceMissing {} -> PeerRejectSignature
    PeerSnapshotEvidenceUnexpected {} -> PeerRejectSignature
    PeerSnapshotEvidenceMismatch {} -> PeerRejectSignature
    PeerDigestWidthInvalid {} -> PeerRejectContinuity
    PeerEpochInvalidationBeforeExhaustion {} -> PeerRejectContinuity
    PeerEmitterCountersExhausted {} -> PeerRejectContinuity
    PeerEpochInvalidationRequired {} -> PeerRejectContinuity
    PeerEpochInvalidationSequenceInvalid {} -> PeerRejectContinuity
    PeerEpochInvalidationEpochInvalid {} -> PeerRejectContinuity
    PeerOrdersMigrationRequiresDedicatedPath -> PeerRejectProtocol
    PeerOrdersMigrationScopeMismatch -> PeerRejectContinuity
    PeerOrdersMigrationEpochExhausted {} -> PeerRejectContinuity
    PeerSemanticSequenceInvalid {} -> PeerRejectContinuity
    PeerSnapshotEvidencePositionAhead {} -> PeerRejectContinuity
    PeerSnapshotEvidenceCursorConflict {} -> PeerRejectContinuity
    PeerSnapshotEvidenceIncarnationAhead {} -> PeerRejectContinuity
    PeerRepairCheckpointConflict {} -> PeerRejectContinuity
    PeerRepairSuffixContainsStale {} -> PeerRejectContinuity
    PeerRepairSuffixDiscontinuous {} -> PeerRejectContinuity
    PeerHeartbeatSkewExceeded {} -> PeerRejectContinuity
    PeerCursorDuplicateEmitter -> PeerRejectCursor
    PeerCursorEntriesNotCanonical -> PeerRejectCursor
    PeerCursorIncarnationShapeMismatch -> PeerRejectCursor
    PeerCursorMissingEmitter {} -> PeerRejectCursor
    PeerSignedReplayUnavailable {} -> PeerRejectCursor
    PeerSignedReplayCursorConflict {} -> PeerRejectContinuity
    PeerSignedReplayStaleIncarnation {} -> PeerRejectContinuity
    PeerRepairCheckpointNotAhead {} -> PeerRejectCursor
    PeerRepairNotRequired {} -> PeerRejectCursor
    PeerRepairSuffixNotCanonical -> PeerRejectCursor
    PeerSnapshotOrdersMismatch -> PeerRejectOrders
    PeerSnapshotEvidenceEmitterMismatch {} -> PeerRejectEmitter
    PeerSnapshotEvidenceWireKindMismatch {} -> PeerRejectSemanticState
    PeerRepairSuffixEmitterMismatch {} -> PeerRejectEmitter
    PeerStateError {} -> PeerRejectSemanticState

data PeerError
  = PeerEventKeyMustNotBeEmpty
  | PeerEventKeyTooSmall Natural Natural
  | PeerEventKeyTooLarge Natural Natural
  | PeerEventKeyUnavailable NodeId
  | PeerProtocolVersionMismatch Word16 Word16
  | PeerOrdersVersionMustBePositive
  | PeerOrdersAnchorMismatch WireOrdersAnchor WireOrdersAnchor
  | PeerDeltaCursorOrdersMismatch
  | PeerEmitterMustNotBeEmpty
  | PeerEmitterTooLarge Natural Natural
  | PeerUnknownEmitter Text
  | PeerDigestWidthInvalid Int Int
  | PeerAssertionSignatureWidthInvalid Int Int
  | PeerAssertionSignatureMismatch NodeId
  | PeerAssertionTooLarge Natural Natural
  | PeerEpochInvalidationBeforeExhaustion NodeId Word64
  | PeerEmitterCountersExhausted NodeId
  | PeerEpochInvalidationRequired NodeId Word64
  | PeerEpochInvalidationSequenceInvalid NodeId Word64
  | PeerEpochInvalidationEpochInvalid NodeId
  | PeerOrdersMigrationRequiresDedicatedPath
  | PeerOrdersMigrationScopeMismatch
  | PeerOrdersMigrationEpochExhausted Text
  | PeerSemanticSequenceInvalid NodeId
  | PeerEncodedFrameMustNotBeEmpty
  | PeerEncodedFrameTooLarge Natural Natural
  | PeerDeltaAssertionCountExceeded Int Int
  | PeerSignedReplayCapacityExceeded Natural Natural
  | PeerDeltaCannotFitAssertion
  | PeerSignedReplayUnavailable NodeId Word64 Word64
  | PeerSignedReplayCursorConflict NodeId Word64 Word64
  | PeerSignedReplayStaleIncarnation Text Word64 Word64
  | PeerSnapshotOrdersMismatch
  | PeerSnapshotSignatureWidthInvalid Int Int
  | PeerSnapshotSignatureMismatch NodeId
  | PeerSnapshotEvidenceMissing NodeId SnapshotEvidenceKind
  | PeerSnapshotEvidenceUnexpected NodeId SnapshotEvidenceKind
  | PeerSnapshotEvidenceMismatch NodeId SnapshotEvidenceKind
  | PeerSnapshotEvidenceEmitterMismatch Text Text
  | PeerSnapshotEvidenceWireKindMismatch Text SnapshotEvidenceKind
  | PeerSnapshotEvidencePositionAhead Text
  | PeerSnapshotEvidenceCursorConflict Text
  | PeerSnapshotEvidenceIncarnationAhead Text Word64 Word64
  | PeerRepairAssertionCountExceeded Int Int
  | PeerRepairCannotFitAssertion
  | PeerRepairCheckpointNotAhead NodeId EmitterCursor EmitterCursor
  | PeerRepairCheckpointConflict NodeId EmitterCursor EmitterCursor
  | PeerRepairNotRequired NodeId
  | PeerRepairSuffixEmitterMismatch NodeId
  | PeerRepairSuffixContainsStale NodeId
  | PeerRepairSuffixNotCanonical
  | PeerRepairSuffixDiscontinuous Text Word64 Word64
  | PeerHeartbeatSkewExceeded Text Word64 Word64 Word64
  | PeerCursorMemberCountExceeded Int Int
  | PeerCursorDuplicateEmitter
  | PeerCursorEntriesNotCanonical
  | PeerCursorIncarnationShapeMismatch
  | PeerCursorMissingEmitter NodeId
  | PeerRejectionSampleCountExceeded Int Int
  | PeerCborDecodeFailed Text Text
  | PeerNonCanonicalCbor Text
  | PeerHttpHeaderIncomplete
  | PeerHttpHeaderTooLarge Int Int
  | PeerHttpHeaderContainsNul
  | PeerHttpMalformedRequestLine
  | PeerHttpMalformedResponseLine
  | PeerHttpUnsupportedRoute Text Text
  | PeerHttpMalformedHeader
  | PeerHttpContentLengthMissing
  | PeerHttpContentLengthDuplicate
  | PeerHttpContentLengthInvalid Text
  | PeerHttpContentLengthTooLarge Natural Natural
  | PeerHttpTransferEncodingForbidden
  | PeerHttpCursorBodyMustBeEmpty Natural
  | PeerHttpBodyLengthMismatch Int Int
  | PeerHttpHostMustNotBeEmpty
  | PeerHttpHostContainsControl
  | PeerStateError GatewayStateError
  deriving (Eq, Show)
