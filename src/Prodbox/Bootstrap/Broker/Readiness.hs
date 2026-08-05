{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The Bootstrap Broker's kubelet readiness as one pure cached projection.
--
-- The broker's @\/readyz@ endpoint is a constant-time projection over
-- boundary-owned cached facts, exactly like the gateway's
-- "Prodbox.Gateway.Readiness". A background observer owns every dependency
-- observation; the request path folds the latched record and performs no
-- backend work at all
-- ([bootstrap_readiness_doctrine §0.7/§2.1](../../../../documents/engineering/bootstrap_readiness_doctrine.md)).
--
-- Two properties make the previous failure classes unrepresentable:
--
-- * A cached record carries the monotonic instant it was observed at. A record
--   older than 'brokerReadinessObservationBoundMicros' projects
--   'BrokerReadinessStarting' rather than its last-known value, so a stalled or
--   dead observer fails closed instead of pinning a stale @ready@.
-- * A dependency observation is four-valued, not a 'Bool'. An identity
--   rejection (the API server refusing the broker's own projected
--   ServiceAccount token) is a distinct absorbing constructor and can never be
--   read as "the dependency is not up yet"
--   (bootstrap_readiness_doctrine §2.4: a static wrong-scope or policy
--   mismatch is absorbing).
module Prodbox.Bootstrap.Broker.Readiness
  ( BrokerDependencyObservation (..)
  , BrokerReadinessFacts (..)
  , BrokerReadinessState (..)
  , unobservedBrokerReadinessFacts
  , brokerReadinessObserverPeriodMicros
  , brokerReadinessObservationBoundMicros
  , brokerReadinessDependencies
  , computeBrokerReadiness
  , brokerReadinessIsReady
  , renderBrokerReadinessState
  , dependencyFromOutcome
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- | One dependency's cached observation.
--
-- 'BrokerDependencyUnobserved' and 'BrokerDependencyUnavailable' are the
-- non-terminal not-yet-ready values; 'BrokerDependencyIdentityRejected' is the
-- absorbing one. Collapsing the last into either of the first two is the exact
-- defect this type removes: an API server that refuses the broker's own
-- credential is not a dependency that is still coming up.
data BrokerDependencyObservation
  = -- | No observation has been recorded yet.
    BrokerDependencyUnobserved
  | BrokerDependencyReady
  | -- | Observed and not usable yet; retrying may succeed.
    BrokerDependencyUnavailable !Text
  | -- | The dependency refused this workload's identity. Absorbing: retrying
    -- the same identity cannot succeed, so it must reach an operator rather
    -- than hide inside a generic not-ready.
    BrokerDependencyIdentityRejected !Text
  deriving stock (Eq, Show)

-- | The boundary-owned cached facts 'computeBrokerReadiness' folds.
--
-- 'brokerFactObservedAtMicros' is 'Nothing' until the first observation
-- completes, which is what makes a cold start fail closed.
data BrokerReadinessFacts = BrokerReadinessFacts
  { brokerFactCapabilityInventory :: !BrokerDependencyObservation
  , brokerFactBootstrapStore :: !BrokerDependencyObservation
  , brokerFactVaultSeal :: !BrokerDependencyObservation
  , brokerFactOpenPgp :: !BrokerDependencyObservation
  , brokerFactBootstrapLease :: !BrokerDependencyObservation
  , brokerFactControllerImage :: !BrokerDependencyObservation
  , brokerFactObservedAtMicros :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

-- | The fail-closed initial record installed before the observer's first pass.
unobservedBrokerReadinessFacts :: BrokerReadinessFacts
unobservedBrokerReadinessFacts =
  BrokerReadinessFacts
    { brokerFactCapabilityInventory = BrokerDependencyUnobserved
    , brokerFactBootstrapStore = BrokerDependencyUnobserved
    , brokerFactVaultSeal = BrokerDependencyUnobserved
    , brokerFactOpenPgp = BrokerDependencyUnobserved
    , brokerFactBootstrapLease = BrokerDependencyUnobserved
    , brokerFactControllerImage = BrokerDependencyUnobserved
    , brokerFactObservedAtMicros = Nothing
    }

-- | The complete labelled dependency inventory, in projection order. Adding a
-- field to 'BrokerReadinessFacts' without adding it here leaves it out of the
-- fold, so this list is the one place the inventory is authored.
brokerReadinessDependencies
  :: BrokerReadinessFacts -> [(Text, BrokerDependencyObservation)]
brokerReadinessDependencies facts =
  [ ("capability-inventory", brokerFactCapabilityInventory facts)
  , ("bootstrap-store", brokerFactBootstrapStore facts)
  , ("vault-seal-status", brokerFactVaultSeal facts)
  , ("openpgp-boundary", brokerFactOpenPgp facts)
  , ("bootstrap-lease", brokerFactBootstrapLease facts)
  , ("controller-image", brokerFactControllerImage facts)
  ]

-- | How often the background observer refreshes the cached record.
brokerReadinessObserverPeriodMicros :: Natural
brokerReadinessObserverPeriodMicros = 5 * 1000 * 1000

-- | The maximum age a cached record may have and still be projected.
--
-- Derived from the observer period rather than independently authored, so the
-- staleness bound cannot drift away from the refresh rate. Three periods
-- tolerates one missed pass plus one slow pass; anything older means the
-- observer is not running and readiness fails closed.
brokerReadinessObservationBoundMicros :: Natural
brokerReadinessObservationBoundMicros = 3 * brokerReadinessObserverPeriodMicros

-- | The projected readiness of the broker.
--
-- 'BrokerReadinessStarting' covers "never observed", "observation is stale",
-- and "a dependency has not reported yet". The two refusal constructors carry
-- the reason so the wire response and the operator diagnostic can name the
-- cause rather than a bare @false@.
data BrokerReadinessState
  = BrokerReadinessStarting !Text
  | BrokerReadinessReady
  | BrokerReadinessDependencyUnavailable !Text
  | BrokerReadinessIdentityRejected !Text
  deriving stock (Eq, Show)

-- | The one readiness projection. Total, pure, and free of any clock read of
-- its own: the caller supplies the monotonic instant.
--
-- Precedence is deliberate. An identity rejection is absorbing and reported
-- first even when another dependency is also down, because retrying will never
-- clear it. Staleness outranks the individual facts, because a stale record
-- says nothing about any of them.
computeBrokerReadiness :: Natural -> BrokerReadinessFacts -> BrokerReadinessState
computeBrokerReadiness nowMicros facts =
  case rejections of
    (label, detail) : _ ->
      BrokerReadinessIdentityRejected (label <> ": " <> detail)
    [] -> case brokerFactObservedAtMicros facts of
      Nothing ->
        BrokerReadinessStarting "no dependency observation has completed yet"
      Just observedAt
        | observationAge observedAt > brokerReadinessObservationBoundMicros ->
            BrokerReadinessStarting
              ( "the cached dependency observation is older than the "
                  <> Text.pack (show (brokerReadinessObservationBoundMicros `div` 1000000))
                  <> "s bound"
              )
        | otherwise -> case (unavailable, unobserved) of
            ((label, detail) : _, _) ->
              BrokerReadinessDependencyUnavailable (label <> ": " <> detail)
            ([], label : _) ->
              BrokerReadinessStarting (label <> " has not been observed yet")
            ([], []) -> BrokerReadinessReady
 where
  dependencies = brokerReadinessDependencies facts

  -- Monotonic time never runs backwards, but a record stamped after `nowMicros`
  -- must not underflow 'Natural'.
  observationAge observedAt
    | nowMicros <= observedAt = 0
    | otherwise = nowMicros - observedAt

  rejections =
    [ (label, detail)
    | (label, BrokerDependencyIdentityRejected detail) <- dependencies
    ]

  unavailable =
    [ (label, detail)
    | (label, BrokerDependencyUnavailable detail) <- dependencies
    ]

  unobserved =
    [label | (label, BrokerDependencyUnobserved) <- dependencies]

-- | The legacy @ready@ boolean the wire response keeps.
brokerReadinessIsReady :: BrokerReadinessState -> Bool
brokerReadinessIsReady state = case state of
  BrokerReadinessReady -> True
  BrokerReadinessStarting _ -> False
  BrokerReadinessDependencyUnavailable _ -> False
  BrokerReadinessIdentityRejected _ -> False

-- | Stable wire vocabulary for the readiness state. The four tags are part of
-- the broker's response contract.
renderBrokerReadinessState :: BrokerReadinessState -> Text
renderBrokerReadinessState state = case state of
  BrokerReadinessReady -> "ready"
  BrokerReadinessStarting detail -> "starting: " <> detail
  BrokerReadinessDependencyUnavailable detail -> "dependency-unavailable: " <> detail
  BrokerReadinessIdentityRejected detail -> "identity-rejected: " <> detail

-- | Lift an ordinary observation outcome into the dependency algebra. The
-- caller decides which failures are identity rejections; everything else is
-- non-terminal.
dependencyFromOutcome :: Either Text () -> BrokerDependencyObservation
dependencyFromOutcome outcome = case outcome of
  Right () -> BrokerDependencyReady
  Left detail -> BrokerDependencyUnavailable detail
