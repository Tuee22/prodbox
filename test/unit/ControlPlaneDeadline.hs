-- | Sprint 1.62 deliverable 1 (process-local half): the deadline-feasibility
-- fold and the tighten-only cancellation-propagation scope. Proves no child
-- deadline can outlive or extend its parent, and that the admission-feasibility
-- boundary is strict (a cost equal to the budget misses), consistent with the
-- landed @deadlineObservation@ @>=@-is-expired boundary.
module ControlPlaneDeadline
  ( controlPlaneDeadlineSuite
  )
where

import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
import Test.Tasty.QuickCheck (NonNegative (..), Small (..))
import TestSupport

mi :: Natural -> MonotonicInstant
mi = monotonicInstantFromMicros

dl :: Natural -> Deadline
dl = deadlineFromInstant . mi

scopeMicros :: DeadlineScope -> Natural
scopeMicros = monotonicInstantMicros . deadlineInstant . scopeDeadline

tightenIsMinProperty :: NonNegative (Small Int) -> NonNegative (Small Int) -> Bool
tightenIsMinProperty (NonNegative (Small a)) (NonNegative (Small b)) =
  let da = dl (fromIntegral a)
      db = dl (fromIntegral b)
      t = tightenDeadline da db
   in t == min da db && t <= da && t <= db

grandchildBoundedProperty
  :: NonNegative (Small Int) -> NonNegative (Small Int) -> NonNegative (Small Int) -> Bool
grandchildBoundedProperty (NonNegative (Small p)) (NonNegative (Small c1)) (NonNegative (Small c2)) =
  let child = narrowScope (rootScope (dl (fromIntegral p))) (dl (fromIntegral c1))
      grandchild = narrowScope child (dl (fromIntegral c2))
   in scopeDeadline grandchild <= dl (fromIntegral p)

controlPlaneDeadlineSuite :: SuiteBuilder ()
controlPlaneDeadlineSuite =
  describe "Sprint 1.62 Deadline extensions" $ do
    describe "tightenDeadline / cancellation propagation" $ do
      propertyTest "tightenDeadline is min and <= both inputs" tightenIsMinProperty

      it "narrowScope clamps an earlier candidate" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 900)) `shouldBe` 900
      it "narrowScope keeps an equal candidate" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 1000)) `shouldBe` 1000
      it "narrowScope discards a later candidate (no extension)" $
        scopeMicros (narrowScope (rootScope (dl 1000)) (dl 1100)) `shouldBe` 1000

      it "narrowScopeToBudget clamps start+budget under the parent" $
        scopeMicros (narrowScopeToBudget (rootScope (dl 1000)) (mi 200) (RemainingDuration 500))
          `shouldBe` 700
      it "narrowScopeToBudget discards an over-parent budget" $
        scopeMicros (narrowScopeToBudget (rootScope (dl 1000)) (mi 200) (RemainingDuration 900))
          `shouldBe` 1000

      propertyTest "a grandchild scope never outlives the grandparent" grandchildBoundedProperty

    describe "deadlineAdmission feasibility fold" $ do
      it "admits with slack when the estimate is under budget" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 0)
          `shouldBe` AdmissionWithinDeadline (RemainingDuration 1000)
      it "admits with one micro of slack at estimate = budget - 1" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 999)
          `shouldBe` AdmissionWithinDeadline (RemainingDuration 1)
      it "misses by zero at estimate = budget (strict boundary)" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 1000)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 0)
      it "reports the deficit when the estimate overshoots" $
        deadlineAdmission (RemainingDuration 1000) (WorkEstimate 1500)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 500)
      it "a zero budget misses for any positive estimate" $
        deadlineAdmission (RemainingDuration 0) (WorkEstimate 1)
          `shouldBe` AdmissionMissesDeadline (RemainingDuration 1)

    describe "landed deadlineObservation boundary (regression guard)" $
      it "is expired exactly at the deadline instant (>= boundary)" $
        deadlineObservation (mi 1000) (dl 1000) `shouldBe` DeadlineExpired
