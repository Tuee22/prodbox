{-# LANGUAGE OverloadedStrings #-}

module CleanRoomHandoff (cleanRoomHandoffSuite) where

import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy.Char8 qualified as ByteString
import Data.Text qualified as Text
import Prodbox.Test.CleanRoomHandoff
import Prodbox.Test.Qualification.Evidence
  ( QualificationEvidence
  , QualificationEvidenceInput (..)
  , QualificationIdentity (..)
  , mkQualificationEvidence
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (ManifestRegularFile)
  , SourceCandidate (SourceCandidate)
  , SourceIdentity
  , WorktreeState (WorktreeDirty)
  , mkGitHead
  , mkSourceIdentity
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
      afterDeletion <- postDeletionIdentity input
      deleted <- accepted (deleteLegacyRoute passed afterDeletion active)
      postEvidence <- postDeletionEvidence input
      postPassed <- accepted (qualifyReplacement afterDeletion postEvidence)
      complete <- accepted (qualifyPostActivation postPassed deleted)
      cutoverStatePhase complete `shouldBe` PostActivationQualified
      cutoverStateHasLegacyWriter complete `shouldBe` False
      cutoverStateHasReplacementWriter complete `shouldBe` True

    it "refuses a deletion that leaves the source identity unchanged" $ do
      -- The deletion is what returns the deployment to qualification-pending.
      -- If it could keep the identity, the witness that authorized activation
      -- would still satisfy `qualifyPostActivation`, and the deployment would
      -- stay called qualified after the source it was qualified on had gone.
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      let replacement = evidenceReplacementIdentity input
      passed <- accepted (qualifyReplacement replacement evidence)
      active <- accepted (activateReplacement passed (initialCutoverState replacement))
      cutoverRefusal (deleteLegacyRoute passed replacement active)
        `shouldBe` Just CutoverDeletionIdentityUnchanged

    it "refuses a deletion carrying another identity's witness" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      let replacement = evidenceReplacementIdentity input
      passed <- accepted (qualifyReplacement replacement evidence)
      active <- accepted (activateReplacement passed (initialCutoverState replacement))
      postEvidence <- postDeletionEvidence input
      afterDeletion <- postDeletionIdentity input
      elsewhere <- accepted (qualifyReplacement afterDeletion postEvidence)
      cutoverRefusal (deleteLegacyRoute elsewhere afterDeletion active)
        `shouldBe` Just (CutoverStageWitnessMismatch PlanDeleteLegacyRouteAndIdentity)

    it "refuses a qualification receipt for another replacement identity" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      qualifyReplacement (evidenceSupersededIdentity input) evidence
        `shouldBe` Left CutoverQualificationIdentityMismatch

    it "requires exact staged cutover order" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      let replacement = evidenceReplacementIdentity input
      passed <- accepted (qualifyReplacement replacement evidence)
      admitted <- accepted (admitCutoverPlan replacement (Just passed) canonicalCutoverPlan)
      resumeCutoverPlan [] `shouldBe` Right canonicalCutoverPlan
      outOfOrder <-
        accepted
          ( admitCutoverPlan
              replacement
              (Just passed)
              [PlanRunQualificationOnlyCandidate, PlanActivateSingleReplacementWriter]
          )
      resumeCutoverPlan outOfOrder
        `shouldBe` Left
          (PlanActivateSingleReplacementWriter, Just PlanObserveQualificationReceipt)
      resumeCutoverPlan admitted `shouldBe` Right []

    it "refuses to admit the two witness-bearing stages without a witness" $ do
      -- The whole staged plan used to be an ordering fold over constructors
      -- anyone could name, so a run containing activation and deletion was
      -- constructible with no witness in existence anywhere. The resume fold
      -- can no longer be handed one.
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
      filter cutoverStageRequiresWitness canonicalCutoverPlan
        `shouldBe` [PlanActivateSingleReplacementWriter, PlanDeleteLegacyRouteAndIdentity]
      map
        (fmap admittedCutoverStage . admitCutoverStage replacement Nothing)
        canonicalCutoverPlan
        `shouldBe` map
          ( \stage ->
              if cutoverStageRequiresWitness stage
                then Left (CutoverStageWitnessMissing stage)
                else Right stage
          )
          canonicalCutoverPlan

    it "refuses to admit a witness-bearing stage for another identity" $ do
      input <- QualificationEvidence.validInput
      evidence <- accepted (mkQualificationEvidence input)
      passed <- accepted (qualifyReplacement (evidenceReplacementIdentity input) evidence)
      admitCutoverStage
        (evidenceSupersededIdentity input)
        (Just passed)
        PlanActivateSingleReplacementWriter
        `shouldBe` Left (CutoverStageWitnessMismatch PlanActivateSingleReplacementWriter)

    it "bounds pre-activation legacy sites and requires zero after deletion" $ do
      let sources =
            [ (path, fragment)
            | (path, fragment) <- registeredLegacyCutoverFragments
            ]
      legacyCutoverResidueViolations LegacyScanPreActivation sources `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation [] `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation sources
        `shouldSatisfy` (not . null)

    it "reports a half-deleted legacy route rather than calling it a duplicate" $ do
      -- The bounded set is still bounded when a registered path stops mentioning
      -- a fragment that survives elsewhere, so the scan used to call that a
      -- duplication and carry a count that was not a duplication count. A
      -- partial removal is the more dangerous event of the two: the pre-
      -- activation scan would otherwise read the tree as unchanged while the
      -- legacy route had already been half-deleted underneath it.
      let halfDeleted =
            [ (path, fragment)
            | (path, fragment) <- registeredLegacyCutoverFragments
            , (path, fragment) /= ("src/Prodbox/CLI/Rke2.hs", "runNativeDeleteCascade")
            ]
      legacyCutoverResidueViolations LegacyScanPreActivation halfDeleted
        `shouldBe` [ LegacyCutoverFragmentAbsentFromPath
                       "src/Prodbox/CLI/Rke2.hs"
                       "runNativeDeleteCascade"
                   ]

    it "matches a registered fragment as a token, never as a substring" $ do
      -- `CascadePhaseOutcome` is a prefix of any longer constructor that starts
      -- with it, and a substring rule gets the answer wrong in both directions:
      -- it invents a site before activation and refuses to call the tree clean
      -- after deletion.
      legacyCutoverFragmentOccurs "CascadePhaseOutcome" "data CascadePhaseOutcome ="
        `shouldBe` True
      legacyCutoverFragmentOccurs "CascadePhaseOutcome" "data CascadePhaseOutcomeFrame ="
        `shouldBe` False
      legacyCutoverFragmentOccurs "runNativeDeleteCascade" "runNativeDeleteCascadeTwice x"
        `shouldBe` False
      legacyCutoverResidueViolations
        LegacyScanPostActivation
        [("src/Prodbox/CLI/Rke2.hs", "data CascadePhaseOutcomeFrame =")]
        `shouldBe` []

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

-- | The refusal a cutover step returned, if it refused.
--
-- A 'CutoverState' has no 'Eq': its whole point is that holding one is the
-- proof, so comparing two of them would be comparing proofs rather than
-- outcomes. The refusal is the part a test has anything to say about.
cutoverRefusal :: Either CutoverRefusal state -> Maybe CutoverRefusal
cutoverRefusal = either Just (const Nothing)

-- | The identity a qualified deletion produces.
--
-- Deleting the legacy route changes the source tree, so the resulting
-- deployment is a different identity from the one activation was qualified on
-- — which is the whole reason deletion returns qualification to pending. The
-- change has to be in the source manifest rather than in a digest field,
-- because that manifest digest is what `mkQualificationEvidence` compares when
-- it refuses a reused identity, and a deletion that left it equal would be a
-- deletion that removed no source.
postDeletionIdentity :: QualificationEvidenceInput -> IO QualificationIdentity
postDeletionIdentity input = do
  deletedSource <- fixtureSourceIdentity "src/Prodbox/Test/New.hs" "new-without-legacy-route"
  pure
    ( (evidenceReplacementIdentity input)
        { qualificationSourceIdentity = deletedSource
        }
    )

-- | The artifact a post-deletion campaign would emit: the activated deployment
-- is now the superseded side, and the post-deletion identity is the replacement.
postDeletionEvidence :: QualificationEvidenceInput -> IO QualificationEvidence
postDeletionEvidence input = do
  afterDeletion <- postDeletionIdentity input
  accepted
    ( mkQualificationEvidence
        input
          { evidenceSupersededIdentity = evidenceReplacementIdentity input
          , evidenceReplacementIdentity = afterDeletion
          }
    )

fixtureSourceIdentity :: String -> String -> IO SourceIdentity
fixtureSourceIdentity path contents = do
  headId <- accepted (mkGitHead "0123456789abcdef0123456789abcdef01234567")
  accepted
    ( mkSourceIdentity
        headId
        WorktreeDirty
        []
        [ SourceCandidate
            (Text.pack path)
            ManifestRegularFile
            0o644
            (ByteString8.pack contents)
        ]
    )

accepted :: (Show err) => Either err value -> IO value
accepted = either (fail . show) pure
