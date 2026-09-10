{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the non-public cascade candidate entrypoint's six
-- non-authorizing diagnostics.
--
-- The entrypoint, its inputs record, its resolved plan, and both closed
-- runtimes stay package-private; this suite reads only booleans, which is the
-- same shape the descriptor-bound dispatcher and the cascade host runtime
-- already use for exactly this reason.
module LifecycleTeardownCascadeCandidate
  ( lifecycleTeardownCascadeCandidateSuite
  )
where

import Prodbox.Lifecycle.Teardown.CascadeCandidate
import TestSupport

lifecycleTeardownCascadeCandidateSuite :: SuiteBuilder ()
lifecycleTeardownCascadeCandidateSuite =
  describe "Sprint 4.86 cascade candidate entrypoint" $ do
    it "derives one program identity from one declared cascade identity" $
      cascadeCandidatePlanIsDeterministic fixedCascadeCandidateRegression
        `shouldBe` True

    it "takes its terminal operation from the compiled program" $
      cascadeCandidateTerminalOperationIsCompiled fixedCascadeCandidateRegression
        `shouldBe` True

    it "refuses a degenerate declared lease window" $
      cascadeCandidateDeclaredLeaseIsRequired fixedCascadeCandidateRegression
        `shouldBe` True

    it "binds the program descriptor to the declared run identity" $
      cascadeCandidateIdentityBindsDescriptor fixedCascadeCandidateRegression
        `shouldBe` True

    it
      "CASCADE-QUALIFICATION-RECOVERY-PRIMARY-OUTCOME-CONFLICT-2026-09-09 preserves every recorded primary outcome and resumes cleanup"
      $ cascadeCandidatePreservesRecordedPrimaryOutcome fixedCascadeCandidateRegression
        `shouldBe` True

    it
      "CASCADE-QUALIFICATION-FRESH-DECLARED-LEASE-RUNNER-LOST-2026-09-09 attaches fresh primary success before claiming the epoch lease"
      $ cascadeCandidateFreshPrimarySurvivesDeclaredLeaseClaim fixedCascadeCandidateRegression
        `shouldBe` True
