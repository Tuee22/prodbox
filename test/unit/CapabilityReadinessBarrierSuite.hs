{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.61 driver cutover: the capability readiness barrier end-to-end
-- through a FAKE probe. Proves the routing (probe reading -> ExternalEvidence ->
-- classifyObservation -> PollOutcome) opens/closes the gate exactly as the legacy
-- seam did, including the GET-vs-write axis (an availability op's ready GET opens;
-- a round-trip op's ready reading is treated as a proven round trip), and pins the
-- round-trip component set. No cluster required.
module CapabilityReadinessBarrierSuite
  ( capabilityReadinessBarrierSuite
  )
where

import Data.Text (Text)
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
import Prodbox.Lifecycle.CapabilityReadinessBarrier
  ( newReadinessObservationClient
  , observeReadinessThroughCapability
  )
import Prodbox.Lifecycle.ReadinessObservation
  ( ComponentReadinessTarget (..)
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
fastPolicy = RetryPolicy 2 0 1 0

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

runBarrier :: CapabilityOp -> ReadinessProbe -> ComponentReadinessTarget -> IO (Either Text ())
runBarrier op probe target =
  observeReadinessThroughCapability
    fastPolicy
    (newReadinessObservationClient gen probe target)
    (requirementFor op)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

capabilityReadinessBarrierSuite :: SuiteBuilder ()
capabilityReadinessBarrierSuite =
  describe "Sprint 1.61 capability readiness barrier" $ do
    it "opens on an availability op's ready reading (read-shaped evidence)" $
      runBarrier
        OpProcessAvailability
        ProbeServiceActive
        (ServiceActiveTarget ComponentMinio (pure (Right ReadinessProbeReady)))
        `shouldReturn` Right ()

    it "opens on a round-trip op's ready reading (treated as a proven round trip)" $
      runBarrier
        OpLifecycleCas
        (ProbeBackendRoundTrip ComponentMinio)
        (BackendRoundTripTarget ComponentGatewayDaemonFull ComponentMinio (pure (Right ReadinessProbeReady)))
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
