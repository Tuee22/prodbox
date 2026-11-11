{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | One invocation of the fixed read-only recovery observer. These are
-- encoded response ceilings and route counts, not whole-program funding.
module Prodbox.Capacity.OrdinaryRecoveryObservationSchedule
  ( RecoveryObservationStep (..)
  , recoveryObservationSteps
  , recoveryObservationRoute
  , recoveryObservationResponseMaximumBytes
  , recoveryObservationTraffic
  , recoveryObservationTrafficCoveredBy
  , recoveryObservationCallerCost
  ) where

import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.Capacity.RegisteredCallerTraffic
  ( RegisteredCallerCost
  , RegisteredCallerCostError
  , RegisteredCallerTraffic (..)
  , registeredCallerCost
  , registeredCallerTraffic
  )
import Prodbox.ControlPlane.CleanupRunEndpoint (cleanupRunDescriptorResponseMaximumBytes)
import Prodbox.ControlPlane.Client (ControlPlaneRouteFor (..), controlPlaneRouteForValue)
import Prodbox.ControlPlane.Route (ControlPlaneRoute)

data RecoveryObservationStep = RecoveryScopeRead | RecoveryReportRead
  deriving (Eq, Show)

-- The second read occurs only after the scope read and candidate compile pass.
-- Each invocation charges one fresh request per step; any retry is separate.
recoveryObservationSteps :: [RecoveryObservationStep]
recoveryObservationSteps = [RecoveryScopeRead, RecoveryReportRead]

recoveryObservationRoute :: RecoveryObservationStep -> ControlPlaneRoute
recoveryObservationRoute step = case step of
  RecoveryScopeRead -> controlPlaneRouteForValue LifecycleProviderScopeObserveRoute
  RecoveryReportRead -> controlPlaneRouteForValue LifecycleCleanupRunRoute

recoveryObservationResponseMaximumBytes :: RecoveryObservationStep -> Int
recoveryObservationResponseMaximumBytes step = case step of
  RecoveryScopeRead -> ReplayBudget.providerScopeObservationMaximumBytes
  RecoveryReportRead -> cleanupRunDescriptorResponseMaximumBytes

-- One private signer channel and one ordinary Authority channel are opened.
-- These shared caller calculations include discovery, registry, nonce, token
-- and forward allowances; physical and heap admission remain separate.
recoveryObservationTraffic :: RegisteredCallerTraffic
recoveryObservationTraffic = registeredCallerTraffic (fromIntegral (length recoveryObservationSteps)) 1

-- A lower-bound check on the owner's declared starting counters. The shared
-- mutable budget still debits every real effect and may refuse earlier.
recoveryObservationTrafficCoveredBy :: RegisteredCallerTraffic -> Bool
recoveryObservationTrafficCoveredBy actual =
  and
    [ ordinaryFrames actual >= ordinaryFrames required
    , registryObservations actual >= registryObservations required
    , publicHints actual >= publicHints required
    , metadataSignedFrames actual >= metadataSignedFrames required
    , totalSignedFrames actual >= totalSignedFrames required
    , protocolHttpRequests actual >= protocolHttpRequests required
    , homeScopeEntries actual >= homeScopeEntries required
    , perExchangeForwards actual >= perExchangeForwards required
    ]
 where
  required = recoveryObservationTraffic

recoveryObservationCallerCost
  :: Natural -> Word64 -> Either RegisteredCallerCostError RegisteredCallerCost
recoveryObservationCallerCost logins remaining =
  registeredCallerCost (fromIntegral (length recoveryObservationSteps)) 1 logins remaining
