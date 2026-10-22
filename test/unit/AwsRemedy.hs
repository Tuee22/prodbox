{-# LANGUAGE OverloadedStrings #-}

module AwsRemedy (awsRemedySuite) where

import Data.List (isInfixOf)
import Prodbox.CLI.Spec (leafCommandPaths)
import Prodbox.Lifecycle.AwsRemedy
import TestSupport

awsRemedySuite :: SuiteBuilder ()
awsRemedySuite = describe "Sprint 4.112 AWS cause-to-remedy policy" $ do
  it "publishes every cause for every stack and resolves every repair path" $ do
    length awsRemedyRows `shouldBe` (4 * 6)
    awsRemedyViolations leafCommandPaths 1 awsRemedyRows `shouldBe` []
    nukeOnlyCauseCount awsRemedyRows `shouldBe` 1
    renderAwsRemedyTable `shouldSatisfy` isInfixOf "prodbox aws audit --stack test"
    renderAwsRemedyTable `shouldSatisfy` isInfixOf "prodbox aws stack test destroy --yes"

  it "rejects an unresolved repair path and a grown NukeOnly cause count" $ do
    awsRemedyViolations
      leafCommandPaths
      1
      [(AwsEksTarget, PreviewChanges, RepairVerb ["aws", "unregistered-repair"])]
      `shouldSatisfy` any (isInfixOf "unresolved repair verb")
    let widened =
          (AwsEksTarget, AuthorityAdmissionRefused, NukeOnly "an explicit new reason")
            : awsRemedyRows
    awsRemedyViolations leafCommandPaths 1 widened
      `shouldSatisfy` any (isInfixOf "grew from Git HEAD")

  it "requires a finite nonzero self-heal and an explicit NukeOnly reason" $ do
    awsRemedyViolations [] 1 [(AwsEksTarget, BlockedDestroy, SelfHeal 2 1800)]
      `shouldBe` []
    mapM_
      ( (`shouldSatisfy` (not . null))
          . awsRemedyViolations [] 1
          . (\remedy -> [(AwsEksTarget, BlockedDestroy, remedy)])
      )
      [SelfHeal 0 1800, SelfHeal 2 0, NukeOnly " "]

  it "reads the published HEAD table, including a ceiling that shrank to zero" $ do
    let document = awsRemedySectionStart ++ "\n" ++ renderAwsRemedyTable ++ awsRemedySectionEnd
    parseAwsRemedyBaseline document `shouldBe` Right 1
    parseAwsRemedyBaseline
      (awsRemedySectionStart ++ "\n| eks | PreviewChanges | RepairVerb | diff |\n" ++ awsRemedySectionEnd)
      `shouldBe` Right 0
    mapM_
      ((`shouldSatisfy` isLeft) . parseAwsRemedyBaseline)
      [ ""
      , awsRemedySectionStart ++ "\n" ++ awsRemedySectionEnd
      , document ++ "\n" ++ awsRemedySectionEnd
      , awsRemedySectionStart ++ "\n| eks | UnknownCause | NukeOnly | reason |\n" ++ awsRemedySectionEnd
      ]

  it "admits only the initial HEAD declaration before the module exists" $ do
    resolveAwsRemedyBaseline
      ( RegisteredInitialRemedyBaseline
          "- The retained-volume-smaller-than-the-plan refusal is registered as `NukeOnly`,"
      )
      `shouldBe` Right 1
    resolveAwsRemedyBaseline (RegisteredInitialRemedyBaseline "no declaration")
      `shouldSatisfy` isLeft
    resolveAwsRemedyBaseline (PublishedRemedyBaseline "no table")
      `shouldSatisfy` isLeft
 where
  isLeft value = case value of
    Left _ -> True
    Right _ -> False
