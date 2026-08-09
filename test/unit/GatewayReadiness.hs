{-# LANGUAGE OverloadedStrings #-}

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

-- | Sprint 2.41: the monotone `WorkersStatus` flag is gone. The two rosters
-- below stand in for what it used to say — every worker running and beating,
-- versus not — and the roster can additionally express a state the flag could
-- not: a worker that started and then exited or stopped beating.
liveRoster :: WorkerRoster
liveRoster = recordWorkerState "rest_server" (WorkerRunning 100) (pendingWorkerRoster ["rest_server"])

pendingRoster :: WorkerRoster
pendingRoster = pendingWorkerRoster ["rest_server"]

exitedRoster :: WorkerRoster
exitedRoster =
  recordWorkerState "rest_server" (WorkerExited "worker exited") (pendingWorkerRoster ["rest_server"])

stalledRoster :: WorkerRoster
stalledRoster = recordWorkerState "rest_server" (WorkerRunning 0) (pendingWorkerRoster ["rest_server"])

readinessAt :: DrainPhase -> EmitterAuthorityStatus -> WorkerRoster -> ReadinessInputs
readinessAt drain authority roster = ReadinessInputs drain authority roster 100 50

allInputs :: [ReadinessInputs]
allInputs =
  [ readinessAt drain authority workers
  | drain <- [PhaseServing, PhaseDraining]
  , authority <- [EmitterAuthorityUnavailable, EmitterAuthorityReady]
  , workers <- [liveRoster, pendingRoster]
  ]

gatewayReadinessSuite :: SuiteBuilder ()
gatewayReadinessSuite =
  describe "Sprint 2.32 durable emitter readiness projection" $ do
    it "folds the full input table to the intended readiness state" $ do
      computeReadiness
        (readinessAt PhaseServing EmitterAuthorityReady liveRoster)
        `shouldBe` Ready
      computeReadiness
        (readinessAt PhaseServing EmitterAuthorityUnavailable pendingRoster)
        `shouldBe` Starting
      computeReadiness
        (readinessAt PhaseServing EmitterAuthorityUnavailable liveRoster)
        `shouldBe` Starting
      computeReadiness
        (readinessAt PhaseServing EmitterAuthorityReady pendingRoster)
        `shouldBe` Starting

    it "never admits before the journal and Lease authority is current" $
      mapM_
        ( \workers ->
            computeReadiness
              (readinessAt PhaseServing EmitterAuthorityUnavailable workers)
              `shouldBe` Starting
        )
        [pendingRoster, liveRoster]

    it "never admits before the workers have started" $
      computeReadiness
        (readinessAt PhaseServing EmitterAuthorityReady pendingRoster)
        `shouldBe` Starting

    it "makes drain absorbing over every authority/workers combination" $
      mapM_
        ( \(authority, workers) ->
            computeReadiness (readinessAt PhaseDraining authority workers)
              `shouldBe` Draining
        )
        [ (authority, workers)
        | authority <- [EmitterAuthorityUnavailable, EmitterAuthorityReady]
        , workers <- [pendingRoster, liveRoster]
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
      let ready = readinessAt PhaseServing EmitterAuthorityReady liveRoster
      computeReadiness ready `shouldBe` Ready
      computeReadiness
        (ready {readinessEmitterAuthority = EmitterAuthorityUnavailable})
        `shouldBe` Starting
      computeReadiness (ready {readinessDrainPhase = PhaseDraining})
        `shouldBe` Draining

    it "Sprint 2.41: a worker that exits or stops beating un-readies the Pod" $ do
      -- The state the monotone flag could not express at all: the flag was
      -- written once, before any worker existed, so a worker that died left
      -- readiness saying `WorkersStarted` forever.
      computeReadiness (readinessAt PhaseServing EmitterAuthorityReady liveRoster)
        `shouldBe` Ready
      computeReadiness (readinessAt PhaseServing EmitterAuthorityReady exitedRoster)
        `shouldBe` Starting
      computeReadiness (readinessAt PhaseServing EmitterAuthorityReady stalledRoster)
        `shouldBe` Starting
      workerRosterStalled 100 50 exitedRoster `shouldSatisfy` (not . null)
      workerRosterStalled 100 50 liveRoster `shouldBe` []

    it "Sprint 2.41: an empty roster is never live" $
      -- A daemon that spawned no workers must not read as ready.
      workerRosterLive 100 50 (pendingWorkerRoster []) `shouldBe` False
