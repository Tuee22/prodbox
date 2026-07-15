-- | Sprint 2.34 conformance suite: the pure latched readiness projection.
--
-- Proves the three properties the daemon @/readyz@ handler relies on, all
-- pre-cluster: (1) the full 2x2x2 input table folds to the intended state; (2)
-- no admission before the first proven object-store round trip since boot
-- (Unproven or Pending is never Ready); and (3) the latch does not flap — drain
-- is absorbing, and because every input is monotone there is no transient
-- signal the projection could react to, so the only downward edge is the
-- intended Ready -> Draining at shutdown.
module GatewayReadiness
  ( gatewayReadinessSuite
  )
where

import Prodbox.Gateway.Readiness
import TestSupport

-- | Every combination of the three monotone inputs.
allInputs :: [ReadinessInputs]
allInputs =
  [ ReadinessInputs drain proof workers
  | drain <- [PhaseServing, PhaseDraining]
  , proof <- [ObjectStoreUnproven, ObjectStoreProven]
  , workers <- [WorkersPending, WorkersStarted]
  ]

gatewayReadinessSuite :: SuiteBuilder ()
gatewayReadinessSuite =
  describe "Sprint 2.34 latched readiness projection" $ do
    it "folds the full input table to the intended readiness state" $ do
      -- The one and only Ready cell: serving, proven, workers started.
      computeReadiness (ReadinessInputs PhaseServing ObjectStoreProven WorkersStarted)
        `shouldBe` Ready
      -- Serving but not yet fully admissible.
      computeReadiness (ReadinessInputs PhaseServing ObjectStoreUnproven WorkersPending)
        `shouldBe` Starting
      computeReadiness (ReadinessInputs PhaseServing ObjectStoreUnproven WorkersStarted)
        `shouldBe` Starting
      computeReadiness (ReadinessInputs PhaseServing ObjectStoreProven WorkersPending)
        `shouldBe` Starting

    it "never admits before the first proven object-store round trip" $ do
      -- No workers-status makes an unproven store Ready.
      mapM_
        ( \workers ->
            computeReadiness (ReadinessInputs PhaseServing ObjectStoreUnproven workers)
              `shouldBe` Starting
        )
        [WorkersPending, WorkersStarted]

    it "never admits before the workers have started" $ do
      computeReadiness (ReadinessInputs PhaseServing ObjectStoreProven WorkersPending)
        `shouldBe` Starting

    it "makes drain absorbing over every proof/workers combination" $ do
      mapM_
        ( \(proof, workers) ->
            computeReadiness (ReadinessInputs PhaseDraining proof workers)
              `shouldBe` Draining
        )
        [ (proof, workers)
        | proof <- [ObjectStoreUnproven, ObjectStoreProven]
        , workers <- [WorkersPending, WorkersStarted]
        ]

    it "is total and yields no state outside {Starting, Ready, Draining}" $ do
      mapM_
        ( \inputs ->
            (computeReadiness inputs `elem` [Starting, Ready, Draining])
              `shouldBe` True
        )
        allInputs

    it "has exactly one Ready cell across the whole input space" $ do
      length (filter ((== Ready) . computeReadiness) allInputs) `shouldBe` 1

    it "does not flap: draining a ready projection is the only downward edge" $ do
      -- Given the latch has fired (proven) and workers are up, only a drain
      -- transition changes the observable state; nothing else in the input
      -- space can pull a served Ready back to Starting.
      let ready = ReadinessInputs PhaseServing ObjectStoreProven WorkersStarted
      computeReadiness ready `shouldBe` Ready
      computeReadiness (ready {readinessDrainPhase = PhaseDraining}) `shouldBe` Draining
