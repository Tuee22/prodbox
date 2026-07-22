-- | Conformance suite for the pure durable-authority readiness projection.
--
-- Proves the three properties the daemon @/readyz@ handler relies on, all
-- pre-cluster: the full input table, no admission before the journal lock and
-- Lease read-back witness exist, and fail-closed Lease loss with absorbing
-- drain.
module GatewayReadiness
  ( gatewayReadinessSuite
  )
where

import Prodbox.Gateway.Readiness
import TestSupport

allInputs :: [ReadinessInputs]
allInputs =
  [ ReadinessInputs drain authority workers
  | drain <- [PhaseServing, PhaseDraining]
  , authority <- [EmitterAuthorityUnavailable, EmitterAuthorityReady]
  , workers <- [WorkersPending, WorkersStarted]
  ]

gatewayReadinessSuite :: SuiteBuilder ()
gatewayReadinessSuite =
  describe "Sprint 2.32 durable emitter readiness projection" $ do
    it "folds the full input table to the intended readiness state" $ do
      computeReadiness
        (ReadinessInputs PhaseServing EmitterAuthorityReady WorkersStarted)
        `shouldBe` Ready
      computeReadiness
        (ReadinessInputs PhaseServing EmitterAuthorityUnavailable WorkersPending)
        `shouldBe` Starting
      computeReadiness
        (ReadinessInputs PhaseServing EmitterAuthorityUnavailable WorkersStarted)
        `shouldBe` Starting
      computeReadiness
        (ReadinessInputs PhaseServing EmitterAuthorityReady WorkersPending)
        `shouldBe` Starting

    it "never admits before the journal and Lease authority is current" $
      mapM_
        ( \workers ->
            computeReadiness
              (ReadinessInputs PhaseServing EmitterAuthorityUnavailable workers)
              `shouldBe` Starting
        )
        [WorkersPending, WorkersStarted]

    it "never admits before the workers have started" $
      computeReadiness
        (ReadinessInputs PhaseServing EmitterAuthorityReady WorkersPending)
        `shouldBe` Starting

    it "makes drain absorbing over every authority/workers combination" $
      mapM_
        ( \(authority, workers) ->
            computeReadiness (ReadinessInputs PhaseDraining authority workers)
              `shouldBe` Draining
        )
        [ (authority, workers)
        | authority <- [EmitterAuthorityUnavailable, EmitterAuthorityReady]
        , workers <- [WorkersPending, WorkersStarted]
        ]

    it "is total and yields no state outside {Starting, Ready, Draining}" $
      mapM_
        ( \inputs ->
            (computeReadiness inputs `elem` [Starting, Ready, Draining])
              `shouldBe` True
        )
        allInputs

    it "has exactly one Ready cell across the whole input space" $
      length (filter ((== Ready) . computeReadiness) allInputs) `shouldBe` 1

    it "fails closed on Lease loss and keeps drain absorbing" $ do
      let ready = ReadinessInputs PhaseServing EmitterAuthorityReady WorkersStarted
      computeReadiness ready `shouldBe` Ready
      computeReadiness
        (ready {readinessEmitterAuthority = EmitterAuthorityUnavailable})
        `shouldBe` Starting
      computeReadiness (ready {readinessDrainPhase = PhaseDraining})
        `shouldBe` Draining
