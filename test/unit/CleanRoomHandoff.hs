{-# LANGUAGE OverloadedStrings #-}

module CleanRoomHandoff (cleanRoomHandoffSuite) where

import Data.ByteString.Lazy.Char8 qualified as ByteString
import Prodbox.Test.CleanRoomHandoff
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

takeThrough :: (Eq value) => value -> [value] -> [value]
takeThrough _ [] = []
takeThrough target (value : values)
  | target == value = [value]
  | otherwise = value : takeThrough target values
