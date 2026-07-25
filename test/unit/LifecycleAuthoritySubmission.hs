{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthoritySubmission
  ( lifecycleAuthoritySubmissionSuite
  )
where

import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import TestSupport

lifecycleAuthoritySubmissionSuite :: SuiteBuilder ()
lifecycleAuthoritySubmissionSuite =
  describe "Sprint 4.48 Lifecycle Authority idempotent operation submission" $ do
    it "accepts a fresh submission and binds the id to epoch/client/sequence/digest" $ do
      let (d, l) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
      d `shouldBe` SubmissionAccepted (opId c1 s1 dg1)
      submissionStatus c1 s1 l `shouldBe` StatusInFlight
      liveSubmissionCount l `shouldBe` 1

    it "is idempotent on an exact resubmission and returns the same id (response-loss safe)" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
          (d2, l2) = stepSubmit epoch l1 c1 s1 dg1
      d2 `shouldBe` SubmissionDuplicate (opId c1 s1 dg1)
      l2 `shouldBe` l1

    it "refuses a sequence reused with a different request digest" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
      decideSubmit epoch l1 c1 s1 dg2 `shouldBe` SubmissionRefusedSequenceReused

    it "refuses a new submission when the live population is at capacity" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 1) c1 s1 dg1
      decideSubmit epoch l1 c2 s1 dg2 `shouldBe` SubmissionRefusedFull
      -- a duplicate of the in-flight submission is still idempotent at capacity
      decideSubmit epoch l1 c1 s1 dg1 `shouldBe` SubmissionDuplicate (opId c1 s1 dg1)
      -- completing the in-flight one frees a slot
      let l1' = rightLedger (completeSubmission c1 s1 l1)
      decideSubmit epoch l1' c2 s1 dg2 `shouldBe` SubmissionAccepted (opId c2 s1 dg2)

    it "treats a submission at or below the compacted floor as expired, not new" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
          l2 = rightLedger (completeSubmission c1 s1 l1)
          l3 = rightLedger (compactClientTerminalsBelow c1 s1 l2)
      submissionStatus c1 s1 l3 `shouldBe` StatusExpired
      decideSubmit epoch l3 c1 s1 dg1 `shouldBe` SubmissionRefusedExpired

    it "cancels an in-flight submission, is idempotent, and refuses cancel-after-complete" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
          l2 = rightLedger (cancelSubmission c1 s1 l1)
      submissionStatus c1 s1 l2 `shouldBe` StatusSettled OperationCancelledOutcome
      cancelSubmission c1 s1 l2 `shouldBe` Right l2
      completeSubmission c1 s1 l2 `shouldBe` Left SubmissionCompleteAfterCancel

    it "completes an in-flight submission, is idempotent, and refuses complete-after-cancel" $ do
      let (_, l1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
          l2 = rightLedger (completeSubmission c1 s1 l1)
      submissionStatus c1 s1 l2 `shouldBe` StatusSettled OperationCompletedOutcome
      completeSubmission c1 s1 l2 `shouldBe` Right l2
      cancelSubmission c1 s1 l2 `shouldBe` Left SubmissionCancelAfterComplete

    it "refuses to cancel or complete an unknown submission" $ do
      let l0 = emptySubmissionLedger 10
      cancelSubmission c1 s1 l0 `shouldBe` Left SubmissionUnknown
      completeSubmission c1 s1 l0 `shouldBe` Left SubmissionUnknown

    it "compaction advances the floor and drops settled tombstones but refuses across an in-flight" $ do
      let (_, a1) = stepSubmit epoch (emptySubmissionLedger 10) c1 s1 dg1
          (_, a2) = stepSubmit epoch a1 c1 s2 dg2
          settled = rightLedger (completeSubmission c1 s1 a2)
      -- s2 is still in-flight, so compacting at/below it is refused
      compactClientTerminalsBelow c1 s2 settled
        `shouldBe` Left SubmissionCompactAcrossInFlight
      -- compacting below s2 drops the settled s1 tombstone and advances the floor
      let compacted = rightLedger (compactClientTerminalsBelow c1 s1 settled)
      submissionStatus c1 s1 compacted `shouldBe` StatusExpired
      submissionStatus c1 s2 compacted `shouldBe` StatusInFlight

    it "reports unknown status for an unseen sequence above the floor" $
      submissionStatus c1 s2 (emptySubmissionLedger 10) `shouldBe` StatusUnknown
 where
  epoch = authorityEpochGenesis
  c1 = ClientId "c1"
  c2 = ClientId "c2"
  s1 = ClientSequence 1
  s2 = ClientSequence 2
  dg1 = RequestDigest "d1"
  dg2 = RequestDigest "d2"
  opId = OperationId epoch
  rightLedger = either (const (error "unexpected submission refusal")) id
