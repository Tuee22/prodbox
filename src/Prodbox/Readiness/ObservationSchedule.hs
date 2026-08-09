{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The readiness observer's schedule, and the staleness bound __derived__ from
-- it.
--
-- Extracted from "Prodbox.Bootstrap.Broker.Readiness" by Sprint @4.55@ so the
-- five control-plane roles and the Bootstrap Broker share one definition rather
-- than two that can drift. Sprint @2.40@ is the reason the bound is derived at
-- all, and its reasoning is the contract:
--
-- The observer stamps @observedAt@ __after__ a pass, so its inter-stamp interval
-- is @period + passDuration@, not @period@. With a 5 s period and a 5 s budget
-- the interval reaches 10 s, and a bound that tolerates one missed pass must be
-- at least @2 * (5 + 5)@ = 20 s. The bound that had been authored beside those
-- constants was 15 s, and the consequence was not a slow failure but a
-- self-inflicted one: a workload whose dependencies are all ready projects
-- @Starting@ for most of every cycle, and @failureThreshold: 6@ at
-- @periodSeconds: 10@ removes the Pod after 60 s.
--
-- The constructor is hidden and the bound is not a parameter. It is computed by
-- 'mkObservationSchedule' from the period and the budget, so a bound the
-- observer cannot meet is not constructible. That is the /Containment/ class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md):
-- bounds are computed, never authored.
module Prodbox.Readiness.ObservationSchedule
  ( ObservationSchedule
  , ObservationScheduleError (..)
  , mkObservationSchedule
  , observerPeriodMicros
  , observationBudgetMicros
  , observationStalenessBoundMicros
  , renderObservationScheduleError
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)

-- | An observer period, a per-pass budget, and the staleness bound the two
-- imply. Built only through 'mkObservationSchedule'.
data ObservationSchedule = ObservationSchedule
  { observerPeriodMicros :: !Natural
  , observationBudgetMicros :: !Natural
  , observationStalenessBoundMicros :: !Natural
  }
  deriving stock (Eq, Show)

-- | Why a proposed schedule is not one.
data ObservationScheduleError
  = ObservationPeriodZero
  | ObservationBudgetZero
  deriving stock (Eq, Show)

renderObservationScheduleError :: ObservationScheduleError -> Text
renderObservationScheduleError err = case err of
  ObservationPeriodZero -> "readiness observer period must be positive"
  ObservationBudgetZero -> "readiness observation budget must be positive"

-- | Build a schedule, deriving the staleness bound.
--
-- The bound is @2 * (period + budget)@: one inter-stamp interval is at most
-- @period + budget@ because the stamp lands after the pass, and tolerating one
-- missed pass doubles it. A zero period or a zero budget is refused rather than
-- normalised — a zero period is a spin and a zero budget is a pass that cannot
-- complete, and both would make the derived bound meaningless.
mkObservationSchedule
  :: Natural -> Natural -> Either ObservationScheduleError ObservationSchedule
mkObservationSchedule periodMicros budgetMicros
  | periodMicros == 0 = Left ObservationPeriodZero
  | budgetMicros == 0 = Left ObservationBudgetZero
  | otherwise =
      Right
        ObservationSchedule
          { observerPeriodMicros = periodMicros
          , observationBudgetMicros = budgetMicros
          , observationStalenessBoundMicros = 2 * (periodMicros + budgetMicros)
          }
