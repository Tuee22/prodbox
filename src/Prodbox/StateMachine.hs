{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}

module Prodbox.StateMachine
  ( ChartPhase (..)
  , ChartState (..)
  , GatewayOwnershipPhase (..)
  , GatewayOwnershipState (..)
  , PulumiPhase (..)
  , PulumiState (..)
  , SomeChartState (..)
  , SomeGatewayOwnershipState (..)
  , SomePulumiState (..)
  , chartApply
  , chartPlan
  , chartVerify
  , completeClaim
  , completeYield
  , markStale
  , promotePulumi
  , startClaim
  , startPulumiUpdate
  , startYield
  )
where

data GatewayOwnershipPhase
  = GatewayIdle
  | GatewayClaiming
  | GatewayOwner
  | GatewayYielding
  | GatewayStale

data GatewayOwnershipState (phase :: GatewayOwnershipPhase) where
  GatewayIdleState :: GatewayOwnershipState 'GatewayIdle
  GatewayClaimingState :: GatewayOwnershipState 'GatewayClaiming
  GatewayOwnerState :: GatewayOwnershipState 'GatewayOwner
  GatewayYieldingState :: GatewayOwnershipState 'GatewayYielding
  GatewayStaleState :: GatewayOwnershipState 'GatewayStale

data SomeGatewayOwnershipState where
  SomeGatewayOwnershipState :: GatewayOwnershipState phase -> SomeGatewayOwnershipState

startClaim :: GatewayOwnershipState 'GatewayIdle -> GatewayOwnershipState 'GatewayClaiming
startClaim GatewayIdleState = GatewayClaimingState

completeClaim :: GatewayOwnershipState 'GatewayClaiming -> GatewayOwnershipState 'GatewayOwner
completeClaim GatewayClaimingState = GatewayOwnerState

startYield :: GatewayOwnershipState 'GatewayOwner -> GatewayOwnershipState 'GatewayYielding
startYield GatewayOwnerState = GatewayYieldingState

completeYield :: GatewayOwnershipState 'GatewayYielding -> GatewayOwnershipState 'GatewayIdle
completeYield GatewayYieldingState = GatewayIdleState

markStale :: GatewayOwnershipState phase -> GatewayOwnershipState 'GatewayStale
markStale _ = GatewayStaleState

data PulumiPhase
  = PulumiSelected
  | PulumiUpdating
  | PulumiReady

data PulumiState (phase :: PulumiPhase) where
  PulumiSelectedState :: PulumiState 'PulumiSelected
  PulumiUpdatingState :: PulumiState 'PulumiUpdating
  PulumiReadyState :: PulumiState 'PulumiReady

data SomePulumiState where
  SomePulumiState :: PulumiState phase -> SomePulumiState

startPulumiUpdate :: PulumiState 'PulumiSelected -> PulumiState 'PulumiUpdating
startPulumiUpdate PulumiSelectedState = PulumiUpdatingState

promotePulumi :: PulumiState 'PulumiUpdating -> PulumiState 'PulumiReady
promotePulumi PulumiUpdatingState = PulumiReadyState

data ChartPhase
  = ChartPlanned
  | ChartApplying
  | ChartVerified

data ChartState (phase :: ChartPhase) where
  ChartPlannedState :: ChartState 'ChartPlanned
  ChartApplyingState :: ChartState 'ChartApplying
  ChartVerifiedState :: ChartState 'ChartVerified

data SomeChartState where
  SomeChartState :: ChartState phase -> SomeChartState

chartPlan :: ChartState 'ChartPlanned
chartPlan = ChartPlannedState

chartApply :: ChartState 'ChartPlanned -> ChartState 'ChartApplying
chartApply ChartPlannedState = ChartApplyingState

chartVerify :: ChartState 'ChartApplying -> ChartState 'ChartVerified
chartVerify ChartApplyingState = ChartVerifiedState
