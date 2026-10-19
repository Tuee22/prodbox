{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.110: what a destroy may claim.
--
-- A destroy verb used to exit zero when the Pulumi child did and the stack no
-- longer selected, neither of which looks at the provider. It now brackets the
-- destroy with an inventory of the field it is meant to empty, and may exit
-- zero only from a closing inventory that is clean. These cases run the
-- bracket over scripted inventories: residue exits 4, an inventory that could
-- not be taken exits 5, a destroy that failed keeps its own status, and a
-- baseline that could not be taken never stops the destroy.
module AwsFieldAuditExit (awsFieldAuditExitSuite) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Aws (stacksForSelection)
import Prodbox.CLI.Command (AwsAuditStack (..))
import Prodbox.Infra.AwsFieldAudit
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..))
import System.Exit (ExitCode (..))
import TestSupport

inventory :: [AuditRow] -> FieldAudit
inventory rows =
  FieldAudit
    { fieldAuditStack = AuditAwsEks
    , fieldAuditBinding = AuditBinding "123456789012" (fixtureAwsRegion FixtureCaCentral1)
    , fieldAuditObservation =
        either
          (error . show)
          id
          ( mkAuditObservation
              AuditAwsEks
              [ (class', auditAnswered [row | row <- rows, auditRowClass row == class'])
              | class' <- auditStackClasses AuditAwsEks
              ]
              AuditControlSeen
          )
    }

full :: FieldAudit
full =
  inventory
    [ mkAuditRow AuditVpc "vpc-0a1" ""
    , mkAuditRow AuditSubnet "subnet-0a1" "available"
    , mkAuditRow AuditNetworkInterface "eni-0leak" "available self cni"
    ]

empty :: FieldAudit
empty = inventory []

-- | A sink that records what it was given, tagged by stream.
recordingSink :: IORef [(Text, Text)] -> FieldSink
recordingSink written =
  FieldSink
    { fieldSinkOutput = \line -> modifyIORef' written (<> [("out", line)])
    , fieldSinkDiagnostic = \line -> modifyIORef' written (<> [("diag", line)])
    }

-- | Inventories taken one after another from a script; the last repeats.
scripted :: [Either Text FieldAudit] -> IO (IO (Either Text FieldAudit))
scripted answers = do
  remaining <- newIORef answers
  pure $ do
    next <- readIORef remaining
    case next of
      [only] -> pure only
      answer : rest -> modifyIORef' remaining (const rest) >> pure answer
      [] -> pure (Left "script exhausted")

runBracket
  :: [Either Text FieldAudit]
  -> ExitCode
  -> IO (ExitCode, [(Text, Text)], Int)
runBracket answers destroyExit = do
  written <- newIORef []
  destroys <- newIORef (0 :: Int)
  taker <- scripted answers
  result <-
    withFieldDiffVia
      (recordingSink written)
      AuditAwsEks
      taker
      (modifyIORef' destroys (+ 1) >> pure destroyExit)
  (,,) result <$> readIORef written <*> readIORef destroys

awsFieldAuditExitSuite :: SuiteBuilder ()
awsFieldAuditExitSuite =
  describe "Sprint 4.110 a destroy exits zero only from a clean closing inventory" $ do
    it "exits zero when the field is empty at the end, and says what left" $ do
      (code, written, destroys) <- runBracket [Right full, Right empty] ExitSuccess
      code `shouldBe` ExitSuccess
      destroys `shouldBe` 1
      map snd written
        `shouldContain` ["AWS_FIELD_DIFF aws-eks verdict=Clean removed=3 remaining=0 appeared=0"]

    it "exits 4 when the closing inventory still holds a resource, and names it" $ do
      (code, written, _) <-
        runBracket
          [Right full, Right (inventory [mkAuditRow AuditNetworkInterface "eni-0leak" "available self cni"])]
          ExitSuccess
      code `shouldBe` ExitFailure 4
      map snd written
        `shouldContain` ["AWS_FIELD_DIFF aws-eks verdict=Residue removed=2 remaining=1 appeared=0"]
      map snd written `shouldContain` ["AWS_FIELD_DIFF remaining network-interface eni-0leak"]

    it
      "exits 5 when the closing inventory cannot be taken, because completion is a claim from an inventory"
      $ do
        (code, written, destroys) <- runBracket [Right full, Left "the Provider did not answer"] ExitSuccess
        code `shouldBe` ExitFailure 5
        destroys `shouldBe` 1
        [line | ("diag", line) <- written]
          `shouldSatisfy` any (Text.isInfixOf "verdict=Unobservable")

    it "exits 5 for an unobservable closing inventory even when nothing was found" $ do
      let blind =
            inventory []
          unanswered =
            blind
              { fieldAuditObservation =
                  either
                    (error . show)
                    id
                    ( mkAuditObservation
                        AuditAwsEks
                        [(AuditNetworkInterface, auditUnanswered "AccessDenied")]
                        AuditControlSeen
                    )
              }
      (code, _, _) <- runBracket [Right full, Right unanswered] ExitSuccess
      code `shouldBe` ExitFailure 5

    it "never stops the destroy for a baseline that could not be taken" $ do
      (code, written, destroys) <- runBracket [Left "no baseline", Right empty] ExitSuccess
      destroys `shouldBe` 1
      code `shouldBe` ExitSuccess
      [line | ("diag", line) <- written]
        `shouldSatisfy` any (Text.isInfixOf "baseline unavailable")

    it "keeps the destroy's own status when it failed, and still reports the field" $ do
      (code, written, _) <- runBracket [Right full, Right full] (ExitFailure 1)
      code `shouldBe` ExitFailure 1
      map snd written `shouldSatisfy` any (Text.isInfixOf "AWS_FIELD_DIFF aws-eks verdict=Residue")

    it "keeps the destroy's own status when the closing inventory cannot be taken either" $ do
      (code, written, _) <- runBracket [Right full, Left "the Provider did not answer"] (ExitFailure 1)
      code `shouldBe` ExitFailure 1
      [line | ("diag", line) <- written] `shouldSatisfy` any (Text.isInfixOf "verdict=Unobservable")

    it "reports what appeared during the destroy, and fails the command for it" $ do
      (code, written, _) <- runBracket [Right empty, Right full] ExitSuccess
      code `shouldBe` ExitFailure 4
      map snd written
        `shouldContain` ["AWS_FIELD_DIFF aws-eks verdict=Residue removed=0 remaining=0 appeared=3"]
      map snd written `shouldContain` ["AWS_FIELD_DIFF appeared network-interface eni-0leak"]

    it "lets the closing inventory stand on its own when no baseline was taken" $ do
      (code, written, _) <- runBracket [Left "no baseline", Right full] ExitSuccess
      code `shouldBe` ExitFailure 4
      let outputs = [line | ("out", line) <- written]
      outputs
        `shouldSatisfy` any (Text.isInfixOf "no baseline was taken, so nothing is compared")
      -- With nothing to compare, it claims nothing about what left or appeared.
      outputs `shouldSatisfy` all (not . Text.isInfixOf "removed=")
      outputs `shouldSatisfy` all (not . Text.isInfixOf "AWS_FIELD_DIFF remaining")

    it "takes the baseline before the destroy and the closing inventory after it" $ do
      order <- newIORef ([] :: [Text])
      let taker = do
            modifyIORef' order (<> ["inventory"])
            pure (Right empty)
      _ <-
        withFieldDiffVia
          (FieldSink (const (pure ())) (const (pure ())))
          AuditAwsEks
          taker
          (modifyIORef' order (<> ["destroy"]) >> pure ExitSuccess)
      readIORef order `shouldReturn` ["inventory", "destroy", "inventory"]

    describe "several inventories earn one status" $ do
      it "lets residue outrank an inventory that could not be taken, as a row outranks a gap" $ do
        worstAuditExit [ExitFailure 5, ExitFailure 4] `shouldBe` ExitFailure 4
        worstAuditExit [ExitFailure 4, ExitFailure 5] `shouldBe` ExitFailure 4
        worstAuditExit [ExitSuccess, ExitFailure 4] `shouldBe` ExitFailure 4

      it "lets an inventory that could not be taken outrank success, and success stand only alone" $ do
        worstAuditExit [ExitSuccess, ExitFailure 5] `shouldBe` ExitFailure 5
        worstAuditExit [ExitSuccess, ExitSuccess] `shouldBe` ExitSuccess
        worstAuditExit [] `shouldBe` ExitSuccess

      it "selects the stacks --stack names, and both when it names none" $ do
        stacksForSelection (Just AwsAuditEks) `shouldBe` [AuditAwsEks]
        stacksForSelection (Just AwsAuditTest) `shouldBe` [AuditAwsTest]
        stacksForSelection Nothing `shouldBe` [AuditAwsEks, AuditAwsTest]
