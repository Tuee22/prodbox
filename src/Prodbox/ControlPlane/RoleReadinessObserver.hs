{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The background observer that owns a control-plane role's readiness facts.
--
-- Sprint @4.55@ moves every role's dependency observation off the kubelet
-- request path and into a loop that runs on its own schedule. The role's
-- @\/readyz@ then reads the cell this loop writes and folds it, which is why
-- "Prodbox.ControlPlane.RoleReadiness" can afford to be a pure projection.
--
-- The observer is the only writer of its cell, and 'RoleReadinessSource' is the
-- only thing the request path receives, so a role cannot reach the observation
-- action from a probe.
module Prodbox.ControlPlane.RoleReadinessObserver
  ( RoleReadinessObserver
  , roleReadinessObserverSource
  , roleReadinessObserverPass
  , newRoleReadinessObserver
  , withRoleReadinessObservers
  , resolveRoleReadiness
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , newTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forever)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.RoleReadiness
  ( RoleDependencyObservation (RoleDependencyUnavailable)
  , RoleReadinessFacts
  , RoleReadinessSource
  , computeRoleReadiness
  , observedRoleReadinessFacts
  , roleReadinessIsReady
  , roleReadinessSnapshot
  , roleReadinessSourceFromCell
  , unobservedRoleReadinessFacts
  )
import Prodbox.Readiness.ObservationSchedule
  ( ObservationSchedule
  , observerPeriodMicros
  )

-- | A cell, the pass that refreshes it, and the schedule both were built with.
--
-- The schedule is carried rather than re-read from a top-level constant at the
-- projection site: Sprint @2.40@ recorded that reading a free constant is
-- exactly how the observer's period and the projection's staleness bound drift
-- apart.
data RoleReadinessObserver = RoleReadinessObserver
  { roleReadinessObserverSource :: !RoleReadinessSource
  , roleReadinessObserverPass :: !(IO ())
  , roleReadinessObserverSchedule :: !ObservationSchedule
  }

-- | Build an observer over a labelled dependency inventory.
--
-- The cell starts at 'unobservedRoleReadinessFacts', so a role is not ready
-- until a pass has completed — a cold start fails closed rather than reporting
-- a vacuous @ready@ before anything has been looked at.
newRoleReadinessObserver
  :: ObservationSchedule
  -> Text
  -- ^ Inventory label used until the first pass completes.
  -> IO Natural
  -- ^ Monotonic clock.
  -> IO [(Text, RoleDependencyObservation)]
  -- ^ One observation pass. Runs off the request path, so it may take as long
  -- as the schedule's budget allows.
  -> IO RoleReadinessObserver
newRoleReadinessObserver schedule label clock observe = do
  cell <- newTVarIO (unobservedRoleReadinessFacts label)
  pure
    RoleReadinessObserver
      { roleReadinessObserverSource = roleReadinessSourceFromCell cell
      , roleReadinessObserverPass = onePass cell
      , roleReadinessObserverSchedule = schedule
      }
 where
  onePass :: TVar RoleReadinessFacts -> IO ()
  onePass cell = do
    -- An observation that THROWS is still an observation: it says the
    -- dependency is not usable right now. Letting the exception escape would
    -- kill the linked observer and, through it, the role's server — turning a
    -- transient backend blip into a process death, which is the Scope-class
    -- defect Sprint 2.41 removed from the gateway. It is recorded as a
    -- non-terminal unavailable so the staleness bound and the projection decide
    -- what it means.
    attempted <- try observe
    dependencies <- case attempted of
      Right observed -> pure observed
      Left (failure :: SomeException) ->
        pure
          [
            ( label
            , RoleDependencyUnavailable
                ("readiness observation raised: " <> Text.pack (displayException failure))
            )
          ]
    -- Stamp after the pass, which is what makes the derived staleness bound
    -- `2 * (period + budget)` rather than `2 * period`.
    observedAt <- clock
    atomically (writeTVar cell (observedRoleReadinessFacts dependencies observedAt))

-- | Run every observer for the duration of an action.
--
-- The handles are linked, but a pass that throws never reaches the link:
-- 'newRoleReadinessObserver' records a raised observation as a non-terminal
-- unavailable dependency, so a transient backend failure degrades readiness
-- instead of killing the role's server. Linking therefore covers the residual
-- case — the loop itself dying — which should never happen and must be visible
-- if it does.
--
-- The staleness bound fails closed on its own if a pass hangs rather than
-- throwing.
withRoleReadinessObservers :: [RoleReadinessObserver] -> IO a -> IO a
withRoleReadinessObservers observers action = case observers of
  [] -> action
  observer : rest ->
    withAsync (observeForever observer) $ \handle -> do
      link handle
      withRoleReadinessObservers rest action
 where
  observeForever observer = forever $ do
    roleReadinessObserverPass observer
    threadDelay
      (fromIntegral (observerPeriodMicros (roleReadinessObserverSchedule observer)))

-- | The request path: read the monotonic clock and the latched facts, then
-- fold. Nothing else.
resolveRoleReadiness :: IO Natural -> RoleReadinessObserver -> IO Bool
resolveRoleReadiness clock observer = do
  now <- clock
  facts <- atomically (roleReadinessSnapshot (roleReadinessObserverSource observer))
  pure
    ( roleReadinessIsReady
        (computeRoleReadiness (roleReadinessObserverSchedule observer) now facts)
    )
