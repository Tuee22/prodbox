{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A control-plane role's kubelet readiness as cached facts and one pure
-- projection.
--
-- This is the Bootstrap Broker's Sprint @2.39@ shape
-- ("Prodbox.Bootstrap.Broker.Readiness") applied to the five roles that were
-- never migrated. The broker was not special; it was the one that was measured.
--
-- Three properties, each removing a failure class the @m Bool@ seam admitted:
--
--   * __Facts, not an action.__ 'RoleReadinessSource' wraps @STM@, and @STM@
--     has no @IO@. A role cannot put a signed S3 @LIST@, a Vault read, or an
--     @aws sts get-caller-identity@ subprocess behind readiness, because those
--     do not type-check where a source is required. The request path reads a
--     latched record and folds it, against a chart-declared
--     @timeoutSeconds: 1@ budget
--     ([bootstrap_readiness_doctrine.md § 0.7](../../../../documents/engineering/bootstrap_readiness_doctrine.md)).
--
--   * __Four-valued, not @Bool@.__ An identity rejection is a distinct
--     absorbing constructor and can never be read as "not up yet"
--     (§ 0.5, and the /Distinguishability/ class of
--     [chaos_hardening_doctrine.md § 21](../../../../documents/engineering/chaos_hardening_doctrine.md)).
--
--   * __One snapshot, one instant.__ Layers compose with
--     'layerRoleReadinessSource', which joins two @STM@ reads inside one
--     transaction. The seam it replaces composed as
--     @do a <- inner; b <- own; pure (a && b)@, which does not short-circuit:
--     every layer's backend call ran on every probe regardless of an earlier
--     @False@, and the resulting verdict mixed observations taken seconds apart.
module Prodbox.ControlPlane.RoleReadiness
  ( RoleDependencyObservation (..)
  , RoleReadinessFacts (..)
  , RoleReadinessState (..)
  , RoleReadinessSource
  , unobservedRoleReadinessFacts
  , readyRoleReadinessFacts
  , observedRoleReadinessFacts
  , composeRoleReadinessFacts
  , roleReadinessSourceFromCell
  , constantRoleReadinessSource
  , noRoleReadinessContribution
  , layerRoleReadinessSource
  , roleReadinessSnapshot
  , computeRoleReadiness
  , roleReadinessIsReady
  , renderRoleReadinessState
  , roleDependencyFromOutcome
  , controlPlaneRoleReadinessSchedule
  )
where

import Control.Concurrent.STM (STM, TVar, readTVar)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Readiness.ObservationSchedule
  ( ObservationSchedule
  , mkObservationSchedule
  , observationStalenessBoundMicros
  , renderObservationScheduleError
  )

-- | One dependency's cached observation.
--
-- 'RoleDependencyUnobserved' and 'RoleDependencyUnavailable' are the
-- non-terminal not-yet-ready values; 'RoleDependencyIdentityRejected' is the
-- absorbing one. Collapsing the last into either of the first two is the exact
-- defect this type removes: a store that refuses the role's own dedicated
-- principal is not a dependency that is still coming up, and retrying the same
-- identity cannot clear it.
data RoleDependencyObservation
  = -- | No observation has been recorded yet.
    RoleDependencyUnobserved
  | RoleDependencyReady
  | -- | Observed and not usable yet; retrying may succeed.
    RoleDependencyUnavailable !Text
  | -- | The dependency refused this workload's identity. Absorbing.
    RoleDependencyIdentityRejected !Text
  deriving stock (Eq, Show)

-- | The boundary-owned cached facts 'computeRoleReadiness' folds.
--
-- The dependency list is labelled rather than a record of named fields, because
-- a role's inventory is assembled by layering: each endpoint layer contributes
-- its own dependencies and the composite is their concatenation. The labels are
-- what make a composite diagnosable.
--
-- @roleFactObservedAtMicros@ is 'Nothing' until the first observation
-- completes, which is what makes a cold start fail closed.
data RoleReadinessFacts = RoleReadinessFacts
  { roleFactDependencies :: ![(Text, RoleDependencyObservation)]
  , roleFactObservedAtMicros :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

-- | The fail-closed initial record installed before an observer's first pass.
unobservedRoleReadinessFacts :: Text -> RoleReadinessFacts
unobservedRoleReadinessFacts label =
  RoleReadinessFacts
    { roleFactDependencies = [(label, RoleDependencyUnobserved)]
    , roleFactObservedAtMicros = Nothing
    }

-- | A completed observation: every dependency ready, stamped at an instant.
readyRoleReadinessFacts :: Text -> Natural -> RoleReadinessFacts
readyRoleReadinessFacts label observedAtMicros =
  observedRoleReadinessFacts [(label, RoleDependencyReady)] observedAtMicros

-- | A completed observation over a labelled inventory.
observedRoleReadinessFacts
  :: [(Text, RoleDependencyObservation)] -> Natural -> RoleReadinessFacts
observedRoleReadinessFacts dependencies observedAtMicros =
  RoleReadinessFacts
    { roleFactDependencies = dependencies
    , roleFactObservedAtMicros = Just observedAtMicros
    }

-- | Join two layers' facts.
--
-- The composite is exactly as fresh as its __stalest__ contributing layer, and
-- an unobserved layer dominates: a composite whose outer layer has observed and
-- whose inner layer has not says nothing about the inner one, so it must not
-- present the outer layer's timestamp as the composite's. That is the same
-- fail-closed rule the broker applies to its own single record, lifted to a
-- composite.
composeRoleReadinessFacts
  :: RoleReadinessFacts -> RoleReadinessFacts -> RoleReadinessFacts
composeRoleReadinessFacts outer inner
  -- A layer with no dependency is the identity: it constrains neither the
  -- inventory nor the freshness. Without this arm, every pass-through layer in
  -- a stack would have to invent a timestamp, and 'noRoleReadinessContribution'
  -- would poison the composite with its own 'Nothing'.
  | null (roleFactDependencies outer) = inner
  | null (roleFactDependencies inner) = outer
  | otherwise =
      RoleReadinessFacts
        { roleFactDependencies = roleFactDependencies outer <> roleFactDependencies inner
        , roleFactObservedAtMicros =
            case (roleFactObservedAtMicros outer, roleFactObservedAtMicros inner) of
              (Just outerAt, Just innerAt) -> Just (min outerAt innerAt)
              _ -> Nothing
        }

-- | A role's readiness facts, readable inside one @STM@ transaction.
--
-- Opaque so that the only ways to build one are the three constructors below.
-- The type is the deliverable: @STM@ has no @IO@, so a backend call cannot hide
-- behind a readiness seam of this type.
newtype RoleReadinessSource = RoleReadinessSource (STM RoleReadinessFacts)

-- | Read a source. Callers run this inside their own transaction, so a layered
-- source resolves from one snapshot at one instant.
roleReadinessSnapshot :: RoleReadinessSource -> STM RoleReadinessFacts
roleReadinessSnapshot (RoleReadinessSource facts) = facts

-- | The production source: a cell a background observer owns and refreshes.
roleReadinessSourceFromCell :: TVar RoleReadinessFacts -> RoleReadinessSource
roleReadinessSourceFromCell cell = RoleReadinessSource (readTVar cell)

-- | A fixed record. Used by fixtures and by the fail-closed default.
constantRoleReadinessSource :: RoleReadinessFacts -> RoleReadinessSource
constantRoleReadinessSource facts = RoleReadinessSource (pure facts)

-- | The identity of 'layerRoleReadinessSource'.
--
-- A layer that observes nothing contributes nothing, rather than contributing a
-- vacuous @ready@. Note the asymmetry with 'unobservedRoleReadinessFacts': that
-- one is a layer that /has/ a dependency and has not looked at it yet, and it
-- fails closed. This one is a layer with no dependency at all, and it is what
-- every pass-through endpoint in a role's stack binds.
noRoleReadinessContribution :: RoleReadinessSource
noRoleReadinessContribution =
  constantRoleReadinessSource
    RoleReadinessFacts
      { roleFactDependencies = []
      , roleFactObservedAtMicros = Nothing
      }

-- | Layer one endpoint's facts over the handler it wraps.
--
-- Both reads happen in the same transaction, so N layers resolve from one
-- snapshot at one instant no matter how deep the stack is. This is the
-- replacement for the six non-short-circuiting @&&@ compositions.
layerRoleReadinessSource
  :: RoleReadinessSource -> RoleReadinessSource -> RoleReadinessSource
layerRoleReadinessSource outer inner =
  RoleReadinessSource
    ( composeRoleReadinessFacts
        <$> roleReadinessSnapshot outer
        <*> roleReadinessSnapshot inner
    )

-- | The projected readiness of a role.
data RoleReadinessState
  = RoleReadinessStarting !Text
  | RoleReadinessReady
  | RoleReadinessDependencyUnavailable !Text
  | RoleReadinessIdentityRejected !Text
  deriving stock (Eq, Show)

-- | The one readiness projection. Total, pure, and free of any clock read of
-- its own: the caller supplies the monotonic instant.
--
-- Precedence matches the broker's, for the same reasons. An identity rejection
-- is absorbing and is reported first even when another dependency is also down,
-- because retrying will never clear it. Staleness outranks the individual
-- facts, because a stale record says nothing about any of them.
computeRoleReadiness
  :: ObservationSchedule -> Natural -> RoleReadinessFacts -> RoleReadinessState
computeRoleReadiness schedule nowMicros facts =
  case rejections of
    (label, detail) : _ ->
      RoleReadinessIdentityRejected (label <> ": " <> detail)
    [] -> case roleFactObservedAtMicros facts of
      Nothing ->
        RoleReadinessStarting "no dependency observation has completed yet"
      Just observedAt
        | observationAge observedAt > observationStalenessBoundMicros schedule ->
            RoleReadinessStarting
              ( "the cached dependency observation is older than the "
                  <> Text.pack (show (observationStalenessBoundMicros schedule `div` 1000000))
                  <> "s bound"
              )
        | otherwise -> case (unavailable, unobserved) of
            ((label, detail) : _, _) ->
              RoleReadinessDependencyUnavailable (label <> ": " <> detail)
            ([], label : _) ->
              RoleReadinessStarting (label <> " has not been observed yet")
            ([], []) -> RoleReadinessReady
 where
  dependencies = roleFactDependencies facts

  -- Monotonic time never runs backwards, but a record stamped after `nowMicros`
  -- must not underflow 'Natural'.
  observationAge observedAt
    | nowMicros <= observedAt = 0
    | otherwise = nowMicros - observedAt

  rejections =
    [ (label, detail)
    | (label, RoleDependencyIdentityRejected detail) <- dependencies
    ]

  unavailable =
    [ (label, detail)
    | (label, RoleDependencyUnavailable detail) <- dependencies
    ]

  unobserved =
    [label | (label, RoleDependencyUnobserved) <- dependencies]

-- | The boolean the @\/readyz@ wire response keeps.
roleReadinessIsReady :: RoleReadinessState -> Bool
roleReadinessIsReady state = case state of
  RoleReadinessReady -> True
  RoleReadinessStarting _ -> False
  RoleReadinessDependencyUnavailable _ -> False
  RoleReadinessIdentityRejected _ -> False

-- | Stable diagnostic vocabulary, matching the broker's four tags.
renderRoleReadinessState :: RoleReadinessState -> Text
renderRoleReadinessState state = case state of
  RoleReadinessReady -> "ready"
  RoleReadinessStarting detail -> "starting: " <> detail
  RoleReadinessDependencyUnavailable detail -> "dependency-unavailable: " <> detail
  RoleReadinessIdentityRejected detail -> "identity-rejected: " <> detail

-- | Lift an ordinary observation outcome into the dependency algebra. The
-- caller decides which failures are identity rejections; everything else is
-- non-terminal.
roleDependencyFromOutcome :: Either Text () -> RoleDependencyObservation
roleDependencyFromOutcome outcome = case outcome of
  Right () -> RoleDependencyReady
  Left detail -> RoleDependencyUnavailable detail

-- | The shipped control-plane role schedule: a 5-second observer period and a
-- 5-second per-pass budget, so the derived staleness bound is 20 seconds — the
-- same shape the broker runs, because the roles run the same probe timings.
-- The fallback arm is unreachable; both inputs are positive literals.
controlPlaneRoleReadinessSchedule :: ObservationSchedule
controlPlaneRoleReadinessSchedule =
  case mkObservationSchedule (5 * 1000 * 1000) (5 * 1000 * 1000) of
    Right schedule -> schedule
    Left err -> error (Text.unpack (renderObservationScheduleError err))
