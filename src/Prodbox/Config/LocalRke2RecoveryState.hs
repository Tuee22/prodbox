-- | Read-only production observation of the local RKE2 substrate state used
-- by ordinary-teardown recovery.  The observer has no caller-selected path,
-- service, endpoint, or raw-fact input.  Its result is opaque; consumers can
-- inspect only the closed recovery view or a typed refusal.
module Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryState
  , LocalRke2RecoveryStateView (..)
  , LocalRke2RecoveryObservationSurface (..)
  , LocalRke2RecoveryObservationFailure (..)
  , LocalRke2RecoveryContradiction (..)
  , LocalRke2RecoveryStateError (..)
  , localRke2RecoveryStateView
  , renderLocalRke2RecoveryStateError
  , observeLocalRke2RecoveryState
  , LocalRke2RecoveryStateFixtureRegression
  , fixedLocalRke2RecoveryStateFixtureRegression
  , localRke2RecoveryFixtureAcceptedViews
  , localRke2RecoveryFixtureDefinitiveCombinationCount
  , localRke2RecoveryFixtureContradictoryCombinationCount
  , localRke2RecoveryFixtureUnobservableCombinationCount
  , localRke2RecoveryFixtureServiceParserClosed
  , localRke2RecoveryFixtureApiParserClosed
  , localRke2RecoveryFixtureMixedMarkersRefused
  , localRke2RecoveryFixtureProductionBoundaryCanonical
  , localRke2RecoveryFixtureHealthyEliminatorClosed
  )
where

import Prodbox.Config.LocalRke2RecoveryState.Internal
