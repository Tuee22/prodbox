{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.5: what the receipt says, as lines for the plan.
--
-- The observer's work is over a repository and a tree, so these cases cover the
-- part that is a function: given a verdict and the facts around it, which
-- lines are shown, that a refusal can never be read as a qualification, and
-- what the typed cutover machine would admit from the witness the observer
-- mints.
module CascadeQualificationReceiptTests
  ( cascadeQualificationReceiptSuite
  )
where

import CycleIdentityFixtures
import CycleLedgerFixtures
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.CascadeQualificationReceipt
import Prodbox.Test.CleanRoomHandoff (qualifyReplacement)
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( assembleCurrentIdentity
  , canonicalKeyPolicy
  )
import Prodbox.Test.Qualification.Evidence (QualificationIdentity (..))
import TestSupport

cascadeQualificationReceiptSuite :: SuiteBuilder ()
cascadeQualificationReceiptSuite =
  describe "Sprint 6.5 cascade qualification receipt" $ do
    reportCases
    dryRunCases

reportCases :: SuiteBuilder ()
reportCases = do
  it "reports a qualifying verdict with the facts the plan records" $
    case verdictOf [Pass "pre-1" DeploymentA, Pass "pre-2" DeploymentA] of
      Left refusal -> expectationFailure ("expected a proof, got " ++ show refusal)
      Right proof -> do
        let report = renderReceiptReport (Right proof) facts
        receiptQualified report `shouldBe` True
        receiptLines report `shouldSatisfy` startsWith "CASCADE_QUALIFICATION_RECEIPT"
        mapM_
          (\expected -> receiptLines report `shouldContain` [expected])
          [ "REQUIRED=2"
          , "CONSECUTIVE=2"
          , "VERDICT=QUALIFIED"
          , "LABELS=pre-1,pre-2"
          , "LEDGER_ENTRIES=4"
          , "ANCHOR=present@3"
          , "DOC_DRIFT=moved"
          , "BINARY=same"
          ]

  it "never reads a refusal as a qualification, and says why" $ do
    let report = renderReceiptReport (Left "only 1 of 2 consecutive qualifying cycles") facts
    receiptQualified report `shouldBe` False
    receiptLines report
      `shouldContain` ["VERDICT=REFUSED:only 1 of 2 consecutive qualifying cycles"]
    receiptLines report `shouldContain` ["IDENTITY_KEY=none"]
    receiptLines report `shouldContain` ["LABELS=none"]

  it "states what is recomputed and what is only compared, in every report" $ do
    let refused = renderReceiptReport (Left "the ledger records no cycle") emptyReceiptFacts
    mapM_
      (\prefix -> any (prefix `Text.isPrefixOf`) (receiptLines refused) `shouldBe` True)
      ["RECOMPUTED=", "COMPARE_ONLY=", "UNLEDGERED_ARTIFACTS=", "GIT_HEAD_NOW=", "WORKTREE_NOW="]
    receiptLines refused `shouldContain` ["GIT_HEAD_NOW=unavailable"]
    receiptLines refused
      `shouldContain` ["COMPARE_ONLY=component-images,topology-wiring-shape,aws-scope"]
 where
  facts =
    emptyReceiptFacts
      { factsConsecutive = 2
      , factsEntries = 4
      , factsTip = "tip"
      , factsAnchor = "present@3"
      , factsDocumentationDrift = "moved"
      , factsBinary = "same"
      }

dryRunCases :: SuiteBuilder ()
dryRunCases = do
  it "admits both witness stages for the identity the witness was minted for" $ do
    let identity = fixtureQualificationIdentity
    passed <- either (fail . show) pure (qualifyReplacement identity (proofForIdentity identity))
    let rendered = dryRunStageLines (Just (identity, passed))
    rendered `shouldContain` ["SIMULATED_PHASE=PostActivation"]
    mapM_
      (\stage -> rendered `shouldContain` ["STAGE=" <> stage <> " ADMISSION=admitted"])
      allStages

  it "refuses the witness stages when the witness is for another identity" $ do
    let identity = fixtureQualificationIdentity
        elsewhere = identity {qualificationGeneratedConfigDigest = digestOf 'Z'}
    passed <- either (fail . show) pure (qualifyReplacement identity (proofForIdentity identity))
    let rendered = dryRunStageLines (Just (elsewhere, passed))
    rendered `shouldContain` ["SIMULATED_PHASE=refused:CutoverQualificationIdentityMismatch"]
    rendered
      `shouldContain` [ "STAGE=PlanActivateSingleReplacementWriter ADMISSION=refused:CutoverStageWitnessMismatch PlanActivateSingleReplacementWriter"
                      ]
    -- The stages that produce a witness need none, so the dry run still admits them.
    rendered `shouldContain` ["STAGE=PlanRunQualificationOnlyCandidate ADMISSION=admitted"]

  it "refuses the two witness stages with no witness and admits the rest" $ do
    let rendered = dryRunStageLines Nothing
    rendered `shouldContain` ["SIMULATED_PHASE=none"]
    rendered
      `shouldContain` ["STAGE=PlanActivateSingleReplacementWriter ADMISSION=refused:witness-missing"]
    rendered
      `shouldContain` ["STAGE=PlanDeleteLegacyRouteAndIdentity ADMISSION=refused:witness-missing"]
    rendered `shouldContain` ["STAGE=PlanObserveQualificationReceipt ADMISSION=admitted"]
    length rendered `shouldBe` (1 + length allStages)

allStages :: [Text]
allStages =
  [ "PlanRunQualificationOnlyCandidate"
  , "PlanObserveQualificationReceipt"
  , "PlanActivateSingleReplacementWriter"
  , "PlanDeleteLegacyRouteAndIdentity"
  , "PlanRunPostActivationQualification"
  , "PlanObservePostActivationQualificationReceipt"
  ]

-- | The identity the fixture tree has under the canonical key policy.
fixtureQualificationIdentity :: QualificationIdentity
fixtureQualificationIdentity =
  assembleCurrentIdentity canonicalKeyPolicy fixtureLocal fixtureCompared

startsWith :: Text -> [Text] -> Bool
startsWith first = (== [first]) . take 1
