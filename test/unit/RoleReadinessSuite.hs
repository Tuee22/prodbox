{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.55: control-plane role readiness is cached facts folded by a pure
-- projection, not backend I/O on the kubelet request path.
module RoleReadinessSuite (roleReadinessSuite) where

import Control.Concurrent.STM (atomically)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.CheckCode (roleReadinessProjectionViolations)
import Prodbox.ControlPlane.RoleReadiness
import Prodbox.ControlPlane.RoleReadinessObserver
  ( RoleReadinessObserver
  , newRoleReadinessObserver
  , resolveRoleReadiness
  , roleReadinessObserverPass
  , roleReadinessObserverSource
  )
import Prodbox.Readiness.ObservationSchedule
  ( ObservationSchedule
  , ObservationScheduleError (..)
  , mkObservationSchedule
  , observationStalenessBoundMicros
  )
import TestSupport

roleReadinessSuite :: SuiteBuilder ()
roleReadinessSuite =
  describe "Sprint 4.55 control-plane role readiness as cached facts" $ do
    it "derives the staleness bound from the period and the budget" $ do
      fmap observationStalenessBoundMicros (mkObservationSchedule 5_000_000 5_000_000)
        `shouldBe` Right 20_000_000
      -- The bound authored beside these constants before Sprint 2.40 was
      -- `3 * period` = 15s, which cannot tolerate one missed pass once the
      -- inter-stamp interval reaches `period + budget` = 10s.
      observationStalenessBoundMicros schedule `shouldSatisfy` (> 3 * 5_000_000)
      mkObservationSchedule 0 5_000_000 `shouldBe` Left ObservationPeriodZero
      mkObservationSchedule 5_000_000 0 `shouldBe` Left ObservationBudgetZero

    it "keeps an identity rejection distinct from a dependency that is not up yet" $ do
      let rejected =
            observedRoleReadinessFacts
              [ ("object-store", RoleDependencyUnavailable "connection refused")
              , ("vault", RoleDependencyIdentityRejected "role is not bound to this account")
              ]
              now
      -- The absorbing case is reported even though a non-terminal one is also
      -- present: retrying will never clear it, so it must reach an operator
      -- rather than hide inside a generic not-ready.
      computeRoleReadiness schedule now rejected
        `shouldBe` RoleReadinessIdentityRejected "vault: role is not bound to this account"
      renderRoleReadinessState (computeRoleReadiness schedule now rejected)
        `shouldBe` "identity-rejected: vault: role is not bound to this account"

      let unavailable =
            observedRoleReadinessFacts
              [("object-store", RoleDependencyUnavailable "connection refused")]
              now
      computeRoleReadiness schedule now unavailable
        `shouldBe` RoleReadinessDependencyUnavailable "object-store: connection refused"

      let notLookedAtYet =
            RoleReadinessFacts
              { roleFactDependencies = [("object-store", RoleDependencyUnobserved)]
              , roleFactObservedAtMicros = Just now
              }
      computeRoleReadiness schedule now notLookedAtYet
        `shouldBe` RoleReadinessStarting "object-store has not been observed yet"

    it "fails closed before the first pass and again once the record goes stale" $ do
      computeRoleReadiness schedule now (unobservedRoleReadinessFacts "object-store")
        `shouldBe` RoleReadinessStarting "no dependency observation has completed yet"

      let fresh = readyRoleReadinessFacts "object-store" now
      computeRoleReadiness schedule now fresh `shouldBe` RoleReadinessReady
      computeRoleReadiness schedule (now + 20_000_000) fresh `shouldBe` RoleReadinessReady
      -- One microsecond past the derived bound the last-known value stops being
      -- evidence of anything.
      computeRoleReadiness schedule (now + 20_000_001) fresh
        `shouldBe` RoleReadinessStarting
          "the cached dependency observation is older than the 20s bound"

    it "makes a composite exactly as fresh as its stalest layer" $ do
      let outer = readyRoleReadinessFacts "outer" (now + 5_000_000)
          inner = readyRoleReadinessFacts "inner" now
          composite = composeRoleReadinessFacts outer inner
      roleFactObservedAtMicros composite `shouldBe` Just now
      map fst (roleFactDependencies composite) `shouldBe` ["outer", "inner"]
      -- An unobserved layer dominates: the outer layer's stamp says nothing
      -- about the inner one, so the composite must not present it as its own.
      roleFactObservedAtMicros
        (composeRoleReadinessFacts outer (unobservedRoleReadinessFacts "inner"))
        `shouldBe` Nothing

    it "resolves three layers from one snapshot and observes nothing to do it" $ do
      -- The seam this replaces composed as `do a <- inner; b <- own; pure (a && b)`
      -- at six sites: every layer's backend call ran on every probe regardless
      -- of an earlier False, and the verdict mixed observations taken seconds
      -- apart. Here the three layers are one `atomically`, and the counting
      -- fakes prove the probe performed no observation of its own.
      (outerCount, outer) <- countingObserver "outer"
      (middleCount, middle) <- countingObserver "middle"
      (innerCount, inner) <- countingObserver "inner"
      mapM_ roleReadinessObserverPass [outer, middle, inner]

      let layered =
            layerRoleReadinessSource
              (roleReadinessObserverSource outer)
              ( layerRoleReadinessSource
                  (roleReadinessObserverSource middle)
                  (roleReadinessObserverSource inner)
              )
      snapshot <- atomically (roleReadinessSnapshot layered)
      map fst (roleFactDependencies snapshot) `shouldBe` ["outer", "middle", "inner"]
      computeRoleReadiness schedule now snapshot `shouldBe` RoleReadinessReady
      mapM_ (\count -> readIORef count `shouldReturn` 1) [outerCount, middleCount, innerCount]

      -- Ten more probes, still one observation each: the layers are read, not run.
      mapM_ (const (atomically (roleReadinessSnapshot layered))) [1 :: Int .. 10]
      mapM_ (\count -> readIORef count `shouldReturn` 1) [outerCount, middleCount, innerCount]

      -- One unready layer decides the composite without any layer being asked
      -- again, and the label says which one.
      (_, unreadyInner) <- unavailableObserver "inner"
      roleReadinessObserverPass unreadyInner
      partly <-
        atomically
          ( roleReadinessSnapshot
              ( layerRoleReadinessSource
                  (roleReadinessObserverSource outer)
                  (roleReadinessObserverSource unreadyInner)
              )
          )
      computeRoleReadiness schedule now partly
        `shouldBe` RoleReadinessDependencyUnavailable "inner: still coming up"

    it "contributes nothing rather than a vacuous ready for a layer with no dependency" $ do
      let none = noRoleReadinessContribution
          ready = constantRoleReadinessSource (readyRoleReadinessFacts "object-store" now)
      composed <- atomically (roleReadinessSnapshot (layerRoleReadinessSource none ready))
      computeRoleReadiness schedule now composed `shouldBe` RoleReadinessReady
      roleFactDependencies composed `shouldBe` [("object-store", RoleDependencyReady)]

    it "lifts an ordinary outcome into the non-terminal arm" $ do
      roleDependencyFromOutcome (Right ()) `shouldBe` RoleDependencyReady
      roleDependencyFromOutcome (Left "boom") `shouldBe` RoleDependencyUnavailable "boom"
      roleReadinessIsReady RoleReadinessReady `shouldBe` True
      map
        roleReadinessIsReady
        [ RoleReadinessStarting "x"
        , RoleReadinessDependencyUnavailable "x"
        , RoleReadinessIdentityRejected "x"
        ]
        `shouldBe` [False, False, False]

    it "keeps the observation off the request path and behind one background pass" $ do
      (count, observer) <- countingObserver "provider-credential-identity"
      clockRef <- newIORef now
      let clock = readIORef clockRef

      -- Cold start: probing does not observe, and it is not ready.
      resolveRoleReadiness clock observer `shouldReturn` False
      readIORef count `shouldReturn` 0

      roleReadinessObserverPass observer
      readIORef count `shouldReturn` 1
      resolveRoleReadiness clock observer `shouldReturn` True
      mapM_ (const (resolveRoleReadiness clock observer)) [1 :: Int .. 10]
      readIORef count `shouldReturn` 1

      -- A stalled observer fails closed rather than pinning its last value.
      writeIORef clockRef (now + 20_000_001)
      resolveRoleReadiness clock observer `shouldReturn` False

    it "makes a backend call behind readiness a type error, not a review comment" $ do
      -- Validation item 2. This is the shape that used to compile and is the
      -- reason five roles ran signed S3 LISTs, Vault reads, and an `aws sts`
      -- subprocess on a `timeoutSeconds: 1` probe path:
      --
      -- > AuthenticatedRoleHandler
      -- >   { authenticatedHandlerReadiness = inClusterAuthorityReady store
      -- >   , ... }
      --
      -- `inClusterAuthorityReady store :: IO Bool` and the field is a
      -- `RoleReadinessSource`, so it no longer type-checks. The property is
      -- carried by the seam's type rather than by a runtime assertion, which is
      -- why the check below is over the module's structure instead.
      pure () :: IO ()

    it "fails the build if the projection module gains a boundary or loses its seam" $ do
      let pureModule =
            unlines
              [ "import Control.Concurrent.STM (STM, TVar, readTVar)"
              , "import Data.Text (Text)"
              , "import Prodbox.Readiness.ObservationSchedule (ObservationSchedule)"
              , "newtype RoleReadinessSource = RoleReadinessSource (STM RoleReadinessFacts)"
              ]
      roleReadinessProjectionViolations ("m.hs", Just pureModule) `shouldBe` []
      length
        ( roleReadinessProjectionViolations
            ("m.hs", Just (pureModule ++ "import Prodbox.Minio.ObjectStoreNative (listKeys)\n"))
        )
        `shouldBe` 1
      length
        ( roleReadinessProjectionViolations
            ("m.hs", Just (pureModule ++ "import System.Process (readProcess)\n"))
        )
        `shouldBe` 1
      -- Losing the seam is a violation too: a gate whose subject disappeared
      -- must fail rather than pass vacuously.
      length (roleReadinessProjectionViolations ("m.hs", Just "import Data.Text (Text)\n"))
        `shouldBe` 1
      length (roleReadinessProjectionViolations ("m.hs", Nothing)) `shouldBe` 1

-- | An observer whose pass is a counting fake reporting a ready dependency.
countingObserver :: Text -> IO (IORef Natural, RoleReadinessObserver)
countingObserver label = observerReporting label RoleDependencyReady

-- | An observer whose pass reports a non-terminal unavailable dependency.
unavailableObserver :: Text -> IO (IORef Natural, RoleReadinessObserver)
unavailableObserver label =
  observerReporting label (RoleDependencyUnavailable "still coming up")

observerReporting
  :: Text -> RoleDependencyObservation -> IO (IORef Natural, RoleReadinessObserver)
observerReporting label observation = do
  count <- newIORef 0
  observer <-
    newRoleReadinessObserver
      schedule
      label
      (pure now)
      ( do
          previous <- readIORef count
          writeIORef count (previous + 1)
          pure [(label, observation)]
      )
  pure (count, observer)

now :: Natural
now = 1_000_000_000

schedule :: ObservationSchedule
schedule = controlPlaneRoleReadinessSchedule
