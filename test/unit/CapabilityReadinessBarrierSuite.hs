{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.61 driver cutover: the capability readiness barrier end-to-end
-- through a FAKE probe. Proves the routing (probe reading -> ExternalEvidence ->
-- classifyObservation -> PollOutcome) opens/closes the gate, including the
-- GET-vs-write axis, and pins the round-trip component set. No cluster required.
--
-- Sprint 1.76 corrected the write half of that axis. The superseded suite
-- asserted that a round-trip op's ready reading was "treated as a proven round
-- trip"; that was the defect, not the contract. A read-shaped reading now holds
-- the gate closed for a round-trip op, and only a witness minted by an
-- interpreter that performed a conditional write opens it.
module CapabilityReadinessBarrierSuite
  ( capabilityReadinessBarrierSuite
  )
where

import Control.Monad (void)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Config.ComponentGraph
  ( ComponentId (..)
  , ReadinessProbe (..)
  , componentCapabilityOp
  )
import Prodbox.ControlPlane.CapabilityKind
  ( CapabilityOp (..)
  , requiresRoundTripEvidence
  )
import Prodbox.ControlPlane.CapabilityRequirement
  ( CapabilityRequirementSpec (..)
  , SomeCapabilityRequirement
  , resolveRequirement
  )
import Prodbox.ControlPlane.Observation (RoundTripWitness)
import Prodbox.ControlPlane.Observation.Internal (mintRoundTripWitness)
import Prodbox.Lifecycle.CapabilityReadinessBarrier
  ( newReadinessObservationClient
  , observeReadinessThroughCapability
  )
import Prodbox.Lifecycle.CheckpointAuthority (mkModelBObjectVersion)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ReadinessObservation
  ( BackendRoundTripResult (..)
  , ComponentReadinessTarget (..)
  , ReadinessProbeResult (..)
  )
import Prodbox.Lifecycle.TargetCommitIntent (CredentialGeneration, mkCredentialGeneration)
import Prodbox.Retry (RetryPolicy (..))
import TestSupport

expectRight :: (Show err) => Either err value -> value
expectRight = either (error . show) id

gen :: CredentialGeneration
gen = expectRight (mkCredentialGeneration 1)

-- | A fast policy (2 attempts, no delay) so the retry-then-Left cases stay quick.
fastPolicy :: RetryPolicy
fastPolicy = testRetryPolicy 2 0 1 0

requirementFor :: CapabilityOp -> SomeCapabilityRequirement
requirementFor op =
  expectRight
    ( resolveRequirement
        CapabilityRequirementSpec
          { specRequireCapability = op
          , specRequireService = "svc"
          , specRequireScope = "home/prodbox"
          , specRequireEndpoint = "component/x"
          , specRequireLogical = "readiness"
          , specRequireGeneration = 1
          , specRequireLatencyMicros = 30_000_000
          }
    )

-- Sprint 4.56: the barrier now returns the admission it minted. These cases are
-- about whether it opens at all, so they discard it; the admission's own
-- properties are exercised by the Sprint 4.56 suite.
runBarrier :: CapabilityOp -> ReadinessProbe -> ComponentReadinessTarget -> IO (Either Text ())
runBarrier op probe target =
  fmap
    void
    ( observeReadinessThroughCapability
        fastPolicy
        (newReadinessObservationClient gen probe target)
        ComponentVaultUnsealed
        (requirementFor op)
    )

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

capabilityReadinessBarrierSuite :: SuiteBuilder ()
capabilityReadinessBarrierSuite = do
  describe "Sprint 1.61 capability readiness barrier" $ do
    it "opens on an availability op's ready reading (read-shaped evidence)" $
      runBarrier
        OpProcessAvailability
        ProbeServiceActive
        (ServiceActiveTarget ComponentMinio (pure (Right ReadinessProbeReady)))
        `shouldReturn` Right ()

    it "stays closed (retries then Left) on a pending reading" $ do
      result <-
        runBarrier
          OpProcessAvailability
          ProbeServiceActive
          (ServiceActiveTarget ComponentMinio (pure (Right (ReadinessProbePending "not yet"))))
      result `shouldSatisfy` isLeft

    it "stays closed on an unreachable probe (fail-closed)" $ do
      result <-
        runBarrier
          OpProcessAvailability
          ProbeServiceActive
          (ServiceActiveTarget ComponentMinio (pure (Left "kubectl failed")))
      result `shouldSatisfy` isLeft

    it "requires round-trip evidence for exactly the registry and full gateway daemon" $
      filter (requiresRoundTripEvidence . componentCapabilityOp) [minBound .. maxBound]
        `shouldBe` [ComponentRegistry, ComponentGatewayDaemonFull]

  describe "Sprint 1.76 provenance-carrying readiness evidence" $ do
    it "opens only on a witness minted by an interpreter that wrote" $ do
      witness <- freshWitness
      result <-
        runBarrier
          OpLifecycleCas
          (ProbeBackendRoundTrip ComponentMinio)
          ( BackendRoundTripTarget
              ComponentGatewayDaemonFull
              ComponentMinio
              (pure (Right (BackendRoundTripConfirmed witness)))
          )
      result `shouldBe` Right ()

    it "holds the gate closed when no write has landed" $ do
      -- The shape the superseded code could not express: the daemon is up and
      -- answering, and has landed no conditional write. Before this sprint the
      -- probe had no way to say so, because a healthy /readyz was the evidence.
      result <-
        runBarrier
          OpLifecycleCas
          (ProbeBackendRoundTrip ComponentMinio)
          ( BackendRoundTripTarget
              ComponentGatewayDaemonFull
              ComponentMinio
              (pure (Right (BackendRoundTripPending "no round trip landed yet")))
          )
      result `shouldSatisfy` isLeft

    it "refuses a witness older than the freshness window" $ do
      -- The window is 300s and the witness carries the instant the write
      -- LANDED, so an ancient round trip is no longer current evidence. Under
      -- the superseded code the instant was a clock read taken after the probe,
      -- which made every witness eternally fresh by construction.
      result <-
        runBarrier
          OpLifecycleCas
          (ProbeBackendRoundTrip ComponentMinio)
          ( BackendRoundTripTarget
              ComponentGatewayDaemonFull
              ComponentMinio
              (pure (Right (BackendRoundTripConfirmed (witnessLandedAt 0))))
          )
      result `shouldSatisfy` isLeft

-- | A witness the way an interpreter mints one: a store-reported version plus
-- the instant its write landed. A test fixture standing in for a store may mint
-- (the boundary lint is scoped to @src\/@), which is the point — production
-- code cannot.
witnessLandedAt :: Natural -> RoundTripWitness
witnessLandedAt landedMicros =
  mintRoundTripWitness
    (expectRight (mkModelBObjectVersion "fixture-cas-etag"))
    (authorityTimeFromMicros landedMicros)

-- | A witness whose write landed just now, so it is inside the barrier's
-- 300-second freshness window. The barrier folds against a real wall-clock read,
-- so \"fresh\" has to mean fresh against that clock rather than against a
-- fixture constant.
freshWitness :: IO RoundTripWitness
freshWitness = do
  posix <- getPOSIXTime
  pure (witnessLandedAt (fromInteger (max 0 (floor (toRational posix * 1000000) :: Integer))))
