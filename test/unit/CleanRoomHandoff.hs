{-# LANGUAGE OverloadedStrings #-}

module CleanRoomHandoff (cleanRoomHandoffSuite) where

import Data.ByteString.Lazy.Char8 qualified as ByteString
import Prodbox.Test.CleanRoomHandoff
import Prodbox.Test.Qualification.Evidence
  ( evidenceReplacementIdentity
  , evidenceSupersededIdentity
  , mkQualificationEvidence
  )
import QualificationEvidence qualified
import TestSupport

cleanRoomHandoffSuite :: SuiteBuilder ()
cleanRoomHandoffSuite =
  describe "Sprint 6.4 clean-room handoff composition" $ do
    it "resumes every interruption prefix at the exact next boundary" $
      map
        resumeCleanRoomActions
        (init (scanl (\prefix action -> prefix ++ [action]) [] canonicalCleanRoomActions))
        `shouldBe` map (Right . (`drop` canonicalCleanRoomActions)) [0 .. length canonicalCleanRoomActions - 1]

    it "accepts the complete trace as converged" $
      resumeCleanRoomActions canonicalCleanRoomActions `shouldBe` Right []

    it "refuses a skipped boundary and a duplicate boundary" $ do
      resumeCleanRoomActions [ObserveLegacyRetainedState, VerifyAuthorityShadow]
        `shouldBe` Left
          (CleanRoomSkippedOrReordered ImportAuthorityProjections VerifyAuthorityShadow)
      resumeCleanRoomActions [ObserveLegacyRetainedState, ObserveLegacyRetainedState]
        `shouldBe` Left
          (CleanRoomSkippedOrReordered ImportAuthorityProjections ObserveLegacyRetainedState)

    it "allows only old observation retry before cutover" $ do
      rollbackDisposition [ObserveLegacyRetainedState, ImportAuthorityProjections]
        `shouldBe` RetryLegacyObservation
      rollbackDisposition (takeThrough ActivateReplacementEpoch canonicalCleanRoomActions)
        `shouldBe` RefuseRollbackBeforeMutation

    it "renders cutover refusal before destructive restoration" $ do
      let rendered = renderCleanRoomPlan (takeThrough ActivateReplacementEpoch canonicalCleanRoomActions)
      rendered `shouldContain` "ROLLBACK=refuse-before-mutation"
      rendered `shouldContain` "STEP=refuse-post-cutover-rollback"
      rendered `shouldContain` "STEP=cluster-delete"

    goldenTest
      "renders the complete versioned dry-run plan"
      "test/golden/clean-room/handoff-plan.txt"
      (pure (ByteString.pack (renderCleanRoomPlan [])))

    it "finds removed paths and forbidden transport references" $ do
      legacyResidueViolations
        ["src/Prodbox/Gateway/ObjectStore.hs"]
        [("src/Example.hs", "import Prodbox.Pulumi.HostDirectObjectStore")]
        `shouldBe` [ LegacyPathPresent "src/Prodbox/Gateway/ObjectStore.hs"
                   , LegacyFragmentPresent
                       "src/Example.hs"
                       "Prodbox.Pulumi.HostDirectObjectStore"
                   ]

    it "accepts the isolated replacement topology" $
      legacyResidueViolations
        ["src/Prodbox/ControlPlane/TargetMaterialEndpoint.hs"]
        [("src/Example.hs", "import Prodbox.ControlPlane.TargetMaterialEndpoint")]
        `shouldBe` []

    it "keeps exactly one writer across the type-indexed cutover" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      let replacement = evidenceReplacementIdentity input
          pre = initialCutoverState replacement
      cutoverStatePhase (rollbackLegacy pre) `shouldBe` PreActivation
      cutoverStateHasLegacyWriter pre `shouldBe` True
      cutoverStateHasReplacementWriter pre `shouldBe` False
      passed <- accepted (qualifyReplacement replacement evidence)
      active <- accepted (activateReplacement passed pre)
      cutoverStatePhase active `shouldBe` PostActivation
      cutoverStateHasLegacyWriter active `shouldBe` False
      cutoverStateHasReplacementWriter active `shouldBe` True
      let deleted = deleteLegacyRoute replacement active
      complete <- accepted (qualifyPostActivation passed deleted)
      cutoverStatePhase complete `shouldBe` PostActivationQualified
      cutoverStateHasLegacyWriter complete `shouldBe` False
      cutoverStateHasReplacementWriter complete `shouldBe` True

    it "refuses a qualification receipt for another replacement identity" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      qualifyReplacement (evidenceSupersededIdentity input) evidence
        `shouldBe` Left CutoverQualificationIdentityMismatch

    it "requires exact staged cutover order" $ do
      resumeCutoverPlan [] `shouldBe` Right canonicalCutoverPlan
      resumeCutoverPlan
        [PlanRunQualificationOnlyCandidate, PlanActivateSingleReplacementWriter]
        `shouldBe` Left
          (PlanActivateSingleReplacementWriter, Just PlanObserveQualificationReceipt)
      resumeCutoverPlan canonicalCutoverPlan `shouldBe` Right []

    it "bounds pre-activation legacy sites and requires zero after deletion" $ do
      let sources =
            [ (path, fragment)
            | (path, fragment) <- registeredLegacyCutoverFragments
            ]
      legacyCutoverResidueViolations LegacyScanPreActivation sources `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation [] `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation sources
        `shouldSatisfy` (not . null)

    it "covers every installed cascade terminal trace with stable bindings" $ do
      map installedTraceFault fixedInstalledCascadeTraces
        `shouldBe` [minBound .. maxBound]
      map installedTraceRunId fixedInstalledCascadeTraces
        `shouldBe` replicate 5 "cascade-candidate-regression"
      map installedTraceDisposition fixedInstalledCascadeTraces
        `shouldBe` [ InstalledCascadeComplete
                   , InstalledCascadeIncomplete
                   , InstalledCascadeIncomplete
                   , InstalledCascadeComplete
                   , InstalledCascadeComplete
                   ]
      mapM_
        ( \trace -> do
            installedTraceResourceKeys trace `shouldSatisfy` (not . null)
            installedTraceObservationAuthorities trace `shouldSatisfy` (not . null)
            renderInstalledCascadeTrace trace `shouldContain` "CLEANUP_RUN_ID="
        )
        fixedInstalledCascadeTraces

    it "resumes every replacement-cascade durable prefix exactly" $ do
      let prefixes =
            init
              ( scanl
                  (\prefix boundary -> prefix ++ [boundary])
                  []
                  canonicalReplacementCascadeBoundaries
              )
      map resumeReplacementCascadeBoundaries prefixes
        `shouldBe` map
          (Right . (`drop` canonicalReplacementCascadeBoundaries))
          [0 .. length canonicalReplacementCascadeBoundaries - 1]
      resumeReplacementCascadeBoundaries
        [StartRecoveryProfile, ObserveRegisteredTargets]
        `shouldBe` Left
          (ObserveRegisteredTargets, Just ReadBackRecoveryProfile)

takeThrough :: (Eq value) => value -> [value] -> [value]
takeThrough _ [] = []
takeThrough target (value : values)
  | target == value = [value]
  | otherwise = value : takeThrough target values

accepted :: (Show err) => Either err value -> IO value
accepted = either (fail . show) pure
