-- | Validated finite bounds for the gateway's semantic state and delta
-- transport.  This module is deliberately below the gateway runtime: it
-- consumes the Phase-1 runtime-memory proof but owns no sockets, threads, or
-- external effects.
module Prodbox.Gateway.Bounds
  ( RawGatewayBounds (..)
  , defaultRawGatewayBounds
  , GatewayBoundField (..)
  , GatewayBoundsError (..)
  , GatewayBounds
  , validateGatewayBounds
  , gatewayMaxOrdersBytes
  , gatewayMaxMembers
  , gatewayMaxNodeIdBytes
  , gatewayMaxEndpointBytes
  , gatewayMaxTrustKeyBytes
  , gatewayMaxEncodedMemberBytes
  , gatewayMaxAssertionPayloadBytes
  , gatewayMaxEncodedAssertionBytes
  , gatewayMaxFrameBytes
  , gatewayMaxAssertionsPerFrame
  , gatewayReplayPerEmitter
  , gatewayMaxInFlightFrames
  , gatewayMaxInFlightFramesPerPeer
  , gatewayMaxRejectionSamples
  , gatewayDiagnosticHashCapacity
  , gatewayRetainedBytesRequired
  , gatewayScratchBytesRequired
  , gatewayChildDeadlineMicros
  , gatewayChildPeakBytes
  )
where

import Control.Monad (unless)
import Data.Foldable (traverse_)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory
  ( RuntimeMemoryPlan
  , childProcessDeadlineMicros
  , childProcessPermitCount
  , childProcessReservedPeakBytes
  , positiveBytesValue
  , runtimeMemoryChildBudget
  , runtimeMemoryRetainedHeapBytes
  , runtimeMemoryScratchBytes
  )

-- | Raw authored bounds.  Every field is required to be positive, and every
-- cardinality is checked against 'Int' before it can reach a Map, Seq, or list
-- operation.
data RawGatewayBounds = RawGatewayBounds
  { rawMaxOrdersBytes :: Natural
  , rawMaxMembers :: Natural
  , rawMaxNodeIdBytes :: Natural
  , rawMaxEndpointBytes :: Natural
  , rawMaxTrustKeyBytes :: Natural
  , rawMaxEncodedMemberBytes :: Natural
  , rawMaxAssertionPayloadBytes :: Natural
  , rawMaxFrameBytes :: Natural
  , rawMaxAssertionsPerFrame :: Natural
  , rawReplayPerEmitter :: Natural
  , rawMaxInFlightFrames :: Natural
  , rawMaxInFlightFramesPerPeer :: Natural
  , rawMaxRejectionSamples :: Natural
  }
  deriving (Eq, Show)

-- | Protocol defaults for one gateway process.  These are validated against
-- the selected Sprint-1.60 runtime-memory profile before any Orders map,
-- parser buffer, peer task, or child interpreter is constructed.
defaultRawGatewayBounds :: RawGatewayBounds
defaultRawGatewayBounds =
  RawGatewayBounds
    { rawMaxOrdersBytes = 256 * 1024
    , rawMaxMembers = 32
    , rawMaxNodeIdBytes = 64
    , rawMaxEndpointBytes = 512
    , rawMaxTrustKeyBytes = 256
    , rawMaxEncodedMemberBytes = 1024
    , rawMaxAssertionPayloadBytes = 4096
    , rawMaxFrameBytes = 64 * 1024
    , rawMaxAssertionsPerFrame = 16
    , rawReplayPerEmitter = 8
    , rawMaxInFlightFrames = 8
    , rawMaxInFlightFramesPerPeer = 2
    , rawMaxRejectionSamples = 64
    }

data GatewayBoundField
  = MaxOrdersBytes
  | MaxMembers
  | MaxNodeIdBytes
  | MaxEndpointBytes
  | MaxTrustKeyBytes
  | MaxEncodedMemberBytes
  | MaxAssertionPayloadBytes
  | MaxFrameBytes
  | MaxAssertionsPerFrame
  | ReplayPerEmitter
  | MaxInFlightFrames
  | MaxInFlightFramesPerPeer
  | MaxRejectionSamples
  deriving (Bounded, Enum, Eq, Show)

data GatewayBoundsError
  = GatewayBoundMustBePositive GatewayBoundField
  | GatewayBoundExceedsInt GatewayBoundField Natural
  | GatewayPerPeerInFlightExceedsProcess
      { perPeerInFlightFrames :: Natural
      , processInFlightFrames :: Natural
      }
  | GatewayMemberEncodingBoundTooSmall
      { requiredMemberBytes :: Natural
      , configuredMemberBytes :: Natural
      }
  | GatewayAssertionExceedsFrame
      { requiredAssertionBytes :: Natural
      , configuredFrameBytes :: Natural
      }
  | GatewayChildPermitMustBeOne Natural
  | GatewayRetainedBudgetExceeded
      { requiredRetainedBytes :: Natural
      , availableRetainedBytes :: Natural
      }
  | GatewayScratchBudgetExceeded
      { requiredScratchBytes :: Natural
      , availableScratchBytes :: Natural
      }
  deriving (Eq, Show)

-- | Opaque validated bounds.  Byte limits stay in 'Natural'; cardinalities are
-- stored as checked 'Int' values so downstream folds never perform unchecked
-- conversions.
data GatewayBounds = GatewayBounds
  { validatedMaxOrdersBytes :: Natural
  , validatedMaxMembers :: Int
  , validatedMaxNodeIdBytes :: Natural
  , validatedMaxEndpointBytes :: Natural
  , validatedMaxTrustKeyBytes :: Natural
  , validatedMaxEncodedMemberBytes :: Natural
  , validatedMaxAssertionPayloadBytes :: Natural
  , validatedMaxEncodedAssertionBytes :: Natural
  , validatedMaxFrameBytes :: Natural
  , validatedMaxAssertionsPerFrame :: Int
  , validatedReplayPerEmitter :: Int
  , validatedMaxInFlightFrames :: Int
  , validatedMaxInFlightFramesPerPeer :: Int
  , validatedMaxRejectionSamples :: Int
  , validatedRetainedBytesRequired :: Natural
  , validatedScratchBytesRequired :: Natural
  , validatedChildDeadlineMicros :: Natural
  , validatedChildPeakBytes :: Natural
  }
  deriving (Eq, Show)

-- | The diagnostic ring is a protocol constant, not an authored tuning knob.
-- Keeping exactly 64 hashes makes diagnostic memory independent of uptime.
gatewayDiagnosticHashCapacity :: Int
gatewayDiagnosticHashCapacity = 64

eventHashBytes :: Natural
eventHashBytes = 32

cursorBytes :: Natural
cursorBytes = 8 + 8 + eventHashBytes

fixedAssertionBytes :: Natural
fixedAssertionBytes =
  -- protocol + Orders version/hash + epoch/sequence + previous hash +
  -- timestamp + kind tag + resulting hash + signature
  2 + 8 + 32 + 8 + 8 + 32 + 8 + 1 + 32 + 32

-- | Validate the authored bounds against each other and against the Phase-1
-- retained/scratch/child-process proof.
validateGatewayBounds
  :: RuntimeMemoryPlan
  -> RawGatewayBounds
  -> Either GatewayBoundsError GatewayBounds
validateGatewayBounds memoryPlan raw = do
  traverse_ validateRawBound (rawBounds raw)
  unless
    (rawMaxInFlightFramesPerPeer raw <= rawMaxInFlightFrames raw)
    ( Left
        GatewayPerPeerInFlightExceedsProcess
          { perPeerInFlightFrames = rawMaxInFlightFramesPerPeer raw
          , processInFlightFrames = rawMaxInFlightFrames raw
          }
    )
  let memberBytesRequired =
        rawMaxNodeIdBytes raw
          + rawMaxEndpointBytes raw
          + rawMaxTrustKeyBytes raw
  unless
    (memberBytesRequired <= rawMaxEncodedMemberBytes raw)
    ( Left
        GatewayMemberEncodingBoundTooSmall
          { requiredMemberBytes = memberBytesRequired
          , configuredMemberBytes = rawMaxEncodedMemberBytes raw
          }
    )
  let assertionBytes =
        fixedAssertionBytes
          + rawMaxNodeIdBytes raw
          + rawMaxAssertionPayloadBytes raw
  unless
    (assertionBytes <= rawMaxFrameBytes raw)
    ( Left
        GatewayAssertionExceedsFrame
          { requiredAssertionBytes = assertionBytes
          , configuredFrameBytes = rawMaxFrameBytes raw
          }
    )
  let childBudget = runtimeMemoryChildBudget memoryPlan
      permitCount = childProcessPermitCount childBudget
  unless (permitCount == 1) (Left (GatewayChildPermitMustBeOne permitCount))
  let retainedRequired = retainedBytes raw assertionBytes
      retainedAvailable =
        positiveBytesValue (runtimeMemoryRetainedHeapBytes memoryPlan)
  unless
    (retainedRequired <= retainedAvailable)
    ( Left
        GatewayRetainedBudgetExceeded
          { requiredRetainedBytes = retainedRequired
          , availableRetainedBytes = retainedAvailable
          }
    )
  let scratchRequired = scratchBytes raw assertionBytes
      scratchAvailable = positiveBytesValue (runtimeMemoryScratchBytes memoryPlan)
  unless
    (scratchRequired <= scratchAvailable)
    ( Left
        GatewayScratchBudgetExceeded
          { requiredScratchBytes = scratchRequired
          , availableScratchBytes = scratchAvailable
          }
    )
  maxMembers <- checkedInt MaxMembers (rawMaxMembers raw)
  maxAssertions <- checkedInt MaxAssertionsPerFrame (rawMaxAssertionsPerFrame raw)
  replayCapacity <- checkedInt ReplayPerEmitter (rawReplayPerEmitter raw)
  maxInFlight <- checkedInt MaxInFlightFrames (rawMaxInFlightFrames raw)
  maxInFlightPerPeer <-
    checkedInt MaxInFlightFramesPerPeer (rawMaxInFlightFramesPerPeer raw)
  rejectionCapacity <- checkedInt MaxRejectionSamples (rawMaxRejectionSamples raw)
  Right
    GatewayBounds
      { validatedMaxOrdersBytes = rawMaxOrdersBytes raw
      , validatedMaxMembers = maxMembers
      , validatedMaxNodeIdBytes = rawMaxNodeIdBytes raw
      , validatedMaxEndpointBytes = rawMaxEndpointBytes raw
      , validatedMaxTrustKeyBytes = rawMaxTrustKeyBytes raw
      , validatedMaxEncodedMemberBytes = rawMaxEncodedMemberBytes raw
      , validatedMaxAssertionPayloadBytes = rawMaxAssertionPayloadBytes raw
      , validatedMaxEncodedAssertionBytes = assertionBytes
      , validatedMaxFrameBytes = rawMaxFrameBytes raw
      , validatedMaxAssertionsPerFrame = maxAssertions
      , validatedReplayPerEmitter = replayCapacity
      , validatedMaxInFlightFrames = maxInFlight
      , validatedMaxInFlightFramesPerPeer = maxInFlightPerPeer
      , validatedMaxRejectionSamples = rejectionCapacity
      , validatedRetainedBytesRequired = retainedRequired
      , validatedScratchBytesRequired = scratchRequired
      , validatedChildDeadlineMicros = childProcessDeadlineMicros childBudget
      , validatedChildPeakBytes =
          positiveBytesValue (childProcessReservedPeakBytes childBudget)
      }

rawBounds :: RawGatewayBounds -> [(GatewayBoundField, Natural)]
rawBounds raw =
  [ (MaxOrdersBytes, rawMaxOrdersBytes raw)
  , (MaxMembers, rawMaxMembers raw)
  , (MaxNodeIdBytes, rawMaxNodeIdBytes raw)
  , (MaxEndpointBytes, rawMaxEndpointBytes raw)
  , (MaxTrustKeyBytes, rawMaxTrustKeyBytes raw)
  , (MaxEncodedMemberBytes, rawMaxEncodedMemberBytes raw)
  , (MaxAssertionPayloadBytes, rawMaxAssertionPayloadBytes raw)
  , (MaxFrameBytes, rawMaxFrameBytes raw)
  , (MaxAssertionsPerFrame, rawMaxAssertionsPerFrame raw)
  , (ReplayPerEmitter, rawReplayPerEmitter raw)
  , (MaxInFlightFrames, rawMaxInFlightFrames raw)
  , (MaxInFlightFramesPerPeer, rawMaxInFlightFramesPerPeer raw)
  , (MaxRejectionSamples, rawMaxRejectionSamples raw)
  ]

validateRawBound :: (GatewayBoundField, Natural) -> Either GatewayBoundsError ()
validateRawBound (field, value)
  | value == 0 = Left (GatewayBoundMustBePositive field)
  | value > fromIntegral (maxBound :: Int) =
      Left (GatewayBoundExceedsInt field value)
  | otherwise = Right ()

checkedInt :: GatewayBoundField -> Natural -> Either GatewayBoundsError Int
checkedInt field value
  | value > fromIntegral (maxBound :: Int) =
      Left (GatewayBoundExceedsInt field value)
  | otherwise = Right (fromIntegral value)

retainedBytes :: RawGatewayBounds -> Natural -> Natural
retainedBytes raw assertionBytes =
  let perEmitterSemanticBytes =
        rawMaxEncodedMemberBytes raw
          + cursorBytes
          + (2 * assertionBytes)
          + (rawReplayPerEmitter raw * assertionBytes)
      -- The daemon retains the canonical signed bytes separately from the
      -- pure semantic fold: one bounded replay window plus the exact compacted
      -- heartbeat/ownership evidence needed to authenticate a repair
      -- checkpoint.
      perEmitterSignedBytes =
        (rawReplayPerEmitter raw + 2) * assertionBytes
      -- Heartbeat/disposition/link projections and strict Map/Seq nodes are
      -- represented conservatively rather than treated as free wrapper
      -- overhead.  Variable-width identity storage is charged at its authored
      -- node-id ceiling.
      perEmitterProjectionBytes = rawMaxNodeIdBytes raw + 512
      ordersSlotsBytes = 2 * rawMaxOrdersBytes raw
      -- Every remote peer has one all-member cursor vector.  This is the
      -- deliberate max_members² term in the live daemon representation.
      peerCursorVectorsBytes =
        rawMaxMembers raw
          * rawMaxMembers raw
          * (rawMaxNodeIdBytes raw + cursorBytes + 64)
      continuityAuthorityBytes = assertionBytes + (2 * cursorBytes) + 512
      diagnosticBytes = fromIntegral gatewayDiagnosticHashCapacity * eventHashBytes
      rejectionSampleBytes =
        rawMaxNodeIdBytes raw + 8 + 8 + 1
      rejectionBytes = rawMaxRejectionSamples raw * rejectionSampleBytes
   in ordersSlotsBytes
        + ( rawMaxMembers raw
              * ( perEmitterSemanticBytes
                    + perEmitterSignedBytes
                    + perEmitterProjectionBytes
                )
          )
        + peerCursorVectorsBytes
        + continuityAuthorityBytes
        + diagnosticBytes
        + rejectionBytes

scratchBytes :: RawGatewayBounds -> Natural -> Natural
scratchBytes raw assertionBytes =
  rawMaxInFlightFrames raw
    * ( rawMaxFrameBytes raw
          + (rawMaxAssertionsPerFrame raw * assertionBytes)
      )

gatewayMaxOrdersBytes :: GatewayBounds -> Natural
gatewayMaxOrdersBytes = validatedMaxOrdersBytes

gatewayMaxMembers :: GatewayBounds -> Int
gatewayMaxMembers = validatedMaxMembers

gatewayMaxNodeIdBytes :: GatewayBounds -> Natural
gatewayMaxNodeIdBytes = validatedMaxNodeIdBytes

gatewayMaxEndpointBytes :: GatewayBounds -> Natural
gatewayMaxEndpointBytes = validatedMaxEndpointBytes

gatewayMaxTrustKeyBytes :: GatewayBounds -> Natural
gatewayMaxTrustKeyBytes = validatedMaxTrustKeyBytes

gatewayMaxEncodedMemberBytes :: GatewayBounds -> Natural
gatewayMaxEncodedMemberBytes = validatedMaxEncodedMemberBytes

gatewayMaxAssertionPayloadBytes :: GatewayBounds -> Natural
gatewayMaxAssertionPayloadBytes = validatedMaxAssertionPayloadBytes

gatewayMaxEncodedAssertionBytes :: GatewayBounds -> Natural
gatewayMaxEncodedAssertionBytes = validatedMaxEncodedAssertionBytes

gatewayMaxFrameBytes :: GatewayBounds -> Natural
gatewayMaxFrameBytes = validatedMaxFrameBytes

gatewayMaxAssertionsPerFrame :: GatewayBounds -> Int
gatewayMaxAssertionsPerFrame = validatedMaxAssertionsPerFrame

gatewayReplayPerEmitter :: GatewayBounds -> Int
gatewayReplayPerEmitter = validatedReplayPerEmitter

gatewayMaxInFlightFrames :: GatewayBounds -> Int
gatewayMaxInFlightFrames = validatedMaxInFlightFrames

gatewayMaxInFlightFramesPerPeer :: GatewayBounds -> Int
gatewayMaxInFlightFramesPerPeer = validatedMaxInFlightFramesPerPeer

gatewayMaxRejectionSamples :: GatewayBounds -> Int
gatewayMaxRejectionSamples = validatedMaxRejectionSamples

gatewayRetainedBytesRequired :: GatewayBounds -> Natural
gatewayRetainedBytesRequired = validatedRetainedBytesRequired

gatewayScratchBytesRequired :: GatewayBounds -> Natural
gatewayScratchBytesRequired = validatedScratchBytesRequired

gatewayChildDeadlineMicros :: GatewayBounds -> Natural
gatewayChildDeadlineMicros = validatedChildDeadlineMicros

gatewayChildPeakBytes :: GatewayBounds -> Natural
gatewayChildPeakBytes = validatedChildPeakBytes
