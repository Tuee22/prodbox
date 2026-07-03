{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Scaling.Spot
  ( UsdPerHour (..)
  , SpotPriceThreshold (..)
  , UnobservableReason (..)
  , SpotObservation (..)
  , SpotDeferReason (..)
  , SpotDecision (..)
  , SpotGate (..)
  , parseUsdPerHour
  , admitSpotDeploy
  , spotGateForScalingPolicy
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Substrate
  ( ScalingPolicy (..)
  , Substrate (..)
  )
import Text.Read (readMaybe)

newtype UsdPerHour = UsdPerHour
  { unUsdPerHour :: Double
  }
  deriving (Eq, Ord, Show)

newtype SpotPriceThreshold = SpotPriceThreshold
  { spotPriceThresholdUsdPerHour :: UsdPerHour
  }
  deriving (Eq, Show)

newtype UnobservableReason = UnobservableReason
  { unobservableReasonText :: Text
  }
  deriving (Eq, Show)

data SpotObservation
  = SpotObserved UsdPerHour
  | SpotUnobservable UnobservableReason
  deriving (Eq, Show)

data SpotDeferReason
  = SpotPriceAboveThreshold UsdPerHour SpotPriceThreshold
  deriving (Eq, Show)

data SpotDecision
  = SpotAdmit
  | SpotDefer SpotDeferReason
  | SpotRefuse UnobservableReason
  deriving (Eq, Show)

data SpotGate
  = SpotGateNotApplicable
  | SpotGateRequired SpotPriceThreshold
  deriving (Eq, Show)

parseUsdPerHour :: Text -> Either UnobservableReason UsdPerHour
parseUsdPerHour raw =
  case readMaybe (Text.unpack (Text.strip raw)) of
    Just value
      | value >= 0 -> Right (UsdPerHour value)
    _ -> Left (UnobservableReason ("invalid USD/hour spot price: " <> raw))

admitSpotDeploy :: SpotPriceThreshold -> SpotObservation -> SpotDecision
admitSpotDeploy threshold@(SpotPriceThreshold priceCeiling) observation =
  case observation of
    SpotObserved price
      | price < priceCeiling -> SpotAdmit
      | otherwise -> SpotDefer (SpotPriceAboveThreshold price threshold)
    SpotUnobservable reason -> SpotRefuse reason

spotGateForScalingPolicy :: Substrate -> ScalingPolicy -> Maybe SpotPriceThreshold -> SpotGate
spotGateForScalingPolicy substrate policy threshold =
  case (substrate, policy, threshold) of
    (SubstrateAws, ScalingPolicyElastic _, Just requiredThreshold) ->
      SpotGateRequired requiredThreshold
    _ -> SpotGateNotApplicable
