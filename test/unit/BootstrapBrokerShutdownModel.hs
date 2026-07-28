module BootstrapBrokerShutdownModel (bootstrapBrokerShutdownModelSuite) where

import Prodbox.Bootstrap.Broker.ShutdownModel
import TestSupport

bootstrapBrokerShutdownModelSuite :: SuiteBuilder ()
bootstrapBrokerShutdownModelSuite =
  describe "Sprint 5.23 Bootstrap Broker shutdown-race and residue oracle" $ do
    it "the frozen pre-fix model can stop while a replay waiter is still live" $
      any stoppedWithLiveWaiter frozenReachable `shouldBe` True
    it "the proof-carrying model never stops with a live replay waiter under exhaustive scheduling" $
      any stoppedWithLiveWaiter proofReachable `shouldBe` False
    it "the proof-carrying model still reaches a fully-drained stop with no residue" $ do
      any ((== Stopped) . phase) proofReachable `shouldBe` True
      all stoppedStatesAreClean proofReachable `shouldBe` True
    it "every proof-carrying terminal state is a clean stop (run-final residue check)" $
      all (\state -> phase state == Stopped && residueClean (shutdownResidue state)) proofTerminals
        `shouldBe` True
    it "a frozen terminal state leaks visible residue rather than passing silently" $
      any (not . residueClean . shutdownResidue) frozenTerminals `shouldBe` True
    it "the residue oracle flags queued connections, unfinalized workers, and live waiters" $ do
      residueClean (shutdownResidue (initialShutdownState 1 0 0)) `shouldBe` False
      residueClean (shutdownResidue (initialShutdownState 0 1 0)) `shouldBe` False
      residueClean (shutdownResidue (ShutdownState Stopped 0 0 [WaiterRunning])) `shouldBe` False
      residueClean (shutdownResidue (ShutdownState Stopped 0 0 [WaiterResolved])) `shouldBe` True
 where
  scenario = initialShutdownState 1 2 2
  frozenReachable = reachableStates FrozenPreFix scenario
  proofReachable = reachableStates ProofCarrying scenario
  frozenTerminals = terminalStates FrozenPreFix scenario
  proofTerminals = terminalStates ProofCarrying scenario
  stoppedStatesAreClean state =
    phase state /= Stopped || residueClean (shutdownResidue state)
