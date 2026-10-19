{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.110: the audit's verdict, its report, and what a run leaves behind.
--
-- The verdict is the instrument Sprint @4.110@ adds: a provider-enumerated
-- inventory over a field declared before the query runs, with a positive control
-- that must appear. These cases hold the algebra on its own (the enumeration
-- that feeds it is in "AwsAuditEnumeration"): a clean verdict needs every class
-- answered and the control seen; an unanswered class is never an empty one; a
-- row refutes whatever else went unanswered; and the persisted record has no
-- field a raw identifier could be put in.
module AwsAuditVerdict (awsAuditVerdictSuite) where

import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.AwsAudit
import System.Exit (ExitCode (..))
import Test.Tasty.QuickCheck (Gen, choose, elements, forAll, listOf, vectorOf)
import TestSupport

observe
  :: AuditStack
  -> [(AuditClass, AuditAnswer)]
  -> AuditControl
  -> AuditObservation
observe stack answers control = case mkAuditObservation stack answers control of
  Right observation -> observation
  Left err -> error ("fixture observation refused: " <> show err)

-- | Every class of the stack answered with nothing.
allEmpty :: AuditStack -> [(AuditClass, AuditAnswer)]
allEmpty stack = [(class', auditAnswered []) | class' <- auditStackClasses stack]

-- | The stack's answers with one class replaced.
replacing :: AuditStack -> AuditClass -> AuditAnswer -> [(AuditClass, AuditAnswer)]
replacing stack class' answer =
  [(c, if c == class' then answer else a) | (c, a) <- allEmpty stack]

row :: AuditClass -> Text -> Text -> AuditRow
row = mkAuditRow

genIdentity :: Gen Text
genIdentity = do
  suffix <- vectorOf 10 (elements (['a' .. 'f'] <> ['0' .. '9']))
  pure ("zzid-" <> Text.pack suffix)

genDetail :: Gen Text
genDetail = do
  suffix <- vectorOf 8 (elements ['g' .. 'z'])
  pure ("zzdesc " <> Text.pack suffix)

genRow :: AuditStack -> Gen AuditRow
genRow stack = do
  class' <- elements (auditStackClasses stack)
  identity <- genIdentity
  detail <- genDetail
  pure (mkAuditRow class' identity detail)

genObservation :: Gen AuditObservation
genObservation = do
  stack <- elements [minBound .. maxBound]
  rows <- listOf (genRow stack)
  gapClass <- elements (auditStackClasses stack)
  gapped <- choose (0, 1 :: Int)
  let byClass class' = [r | r <- rows, auditRowClass r == class']
      answerFor class'
        | gapped == 1 && class' == gapClass = auditPartial (byClass class') "a query did not answer"
        | otherwise = auditAnswered (byClass class')
  control <- elements [AuditControlSeen, AuditControlMissing, AuditControlUnanswered "denied"]
  pure (observe stack [(c, answerFor c) | c <- auditStackClasses stack] control)

awsAuditVerdictSuite :: SuiteBuilder ()
awsAuditVerdictSuite =
  describe "Sprint 4.110 the audit verdict" $ do
    it "is clean only when every class answered, the control appeared and no class holds a row" $
      mapM_
        ( \stack ->
            auditVerdict (observe stack (allEmpty stack) AuditControlSeen) `shouldBe` AuditClean
        )
        [minBound .. maxBound]

    it "is residue when any class holds a row, and counts the rows by class" $ do
      let rows =
            [ row AuditNetworkInterface "eni-0aa1" "status=available"
            , row AuditNetworkInterface "eni-0bb2" "status=in-use"
            ]
          observation =
            observe
              AuditAwsEks
              (replacing AuditAwsEks AuditNetworkInterface (auditAnswered rows))
              AuditControlSeen
      auditVerdict observation `shouldBe` AuditResidue (Map.fromList [(AuditNetworkInterface, 2)])

    it "stands as residue even when other queries went unanswered or the control is missing" $ do
      let answers =
            replacing AuditAwsEks AuditSecurityGroup (auditAnswered [row AuditSecurityGroup "sg-0aa1" ""])
          gapped =
            [ (c, if c == AuditNetworkInterface then auditUnanswered "AccessDenied" else a)
            | (c, a) <- answers
            ]
      auditVerdict (observe AuditAwsEks gapped AuditControlMissing)
        `shouldBe` AuditResidue (Map.fromList [(AuditSecurityGroup, 1)])

    it "is unobservable, never clean, when a class did not answer" $ do
      let answers =
            replacing AuditAwsEks AuditNetworkInterface (auditUnanswered "AccessDenied")
          verdict = auditVerdict (observe AuditAwsEks answers AuditControlSeen)
      verdict `shouldSatisfy` isUnobservable
      verdict
        `shouldBe` AuditUnobservable [(AuditNetworkInterface, "AccessDenied")] Nothing

    it "is unobservable when the positive control did not appear, with its own message" $ do
      let verdict = auditVerdict (observe AuditAwsTest (allEmpty AuditAwsTest) AuditControlMissing)
      verdict `shouldSatisfy` isUnobservable
      case verdict of
        AuditUnobservable [] (Just reason) -> reason `shouldSatisfy` Text.isInfixOf "blind"
        other -> expectationFailure ("expected a control-only refusal, got " <> show other)
      case auditVerdict (observe AuditAwsTest (allEmpty AuditAwsTest) (AuditControlUnanswered "denied")) of
        AuditUnobservable [] (Just reason) -> reason `shouldSatisfy` Text.isInfixOf "denied"
        other -> expectationFailure ("expected a control-only refusal, got " <> show other)

    it "treats a class nobody answered as unanswered, never as empty" $ do
      let verdict = auditVerdict (observe AuditAwsEks [] AuditControlSeen)
      case verdict of
        AuditUnobservable unanswered Nothing ->
          map fst unanswered `shouldBe` auditStackClasses AuditAwsEks
        other -> expectationFailure ("expected every class unanswered, got " <> show other)

    it "maps the verdict to the exit statuses 0, 4 and 5" $ do
      auditExitCode AuditClean `shouldBe` ExitSuccess
      auditExitCode (AuditResidue (Map.fromList [(AuditVpc, 1)])) `shouldBe` ExitFailure 4
      auditExitCode (AuditUnobservable [] (Just "blind")) `shouldBe` ExitFailure 5

    it "refuses an observation that is not about its stack" $ do
      mkAuditObservation AuditAwsEksSubzone [(AuditVpc, auditAnswered [])] AuditControlSeen
        `shouldBe` Left (AuditClassOutsideField AuditAwsEksSubzone AuditVpc)
      mkAuditObservation
        AuditAwsTest
        [(AuditVpc, auditAnswered [row AuditSubnet "subnet-0a" ""])]
        AuditControlSeen
        `shouldBe` Left (AuditRowInWrongClass AuditVpc AuditSubnet)
      mkAuditObservation
        AuditAwsTest
        [(AuditVpc, auditAnswered []), (AuditVpc, auditAnswered [])]
        AuditControlSeen
        `shouldBe` Left (AuditClassAnsweredTwice AuditVpc)

    it "merges the answers of several queries: every row once, and a gap if any left one" $ do
      let first = auditAnswered [row AuditSecurityGroup "sg-1" "name=a"]
          second = auditAnswered [row AuditSecurityGroup "sg-1" "name=a", row AuditSecurityGroup "sg-2" ""]
          gapped = auditUnanswered "AccessDenied"
      auditAnswerRows (mergeAuditAnswers [first, second]) `shouldSatisfy` ((== 2) . length)
      auditAnswerGap (mergeAuditAnswers [first, second]) `shouldBe` Nothing
      auditAnswerGap (mergeAuditAnswers [first, gapped]) `shouldBe` Just "AccessDenied"
      auditAnswerRows (mergeAuditAnswers [first, gapped]) `shouldSatisfy` ((== 1) . length)

    it "keeps the row that says more when two queries see the same resource" $ do
      let bare = row AuditSecurityGroup "sg-0a" ""
          rich = row AuditSecurityGroup "sg-0a" "k8s-elb"
          detailsOf answers = map auditRowDetail (auditAnswerRows (mergeAuditAnswers answers))
      detailsOf [auditAnswered [bare], auditAnswered [rich]] `shouldBe` ["k8s-elb"]
      detailsOf [auditAnswered [rich], auditAnswered [bare]] `shouldBe` ["k8s-elb"]

    it "keeps a provider's description from breaking a line or a field" $ do
      let dirty = "line one\nline|two\ttabbed" <> Text.replicate 400 "x"
          sanitized = sanitizeAuditText dirty
      sanitized `shouldSatisfy` (not . Text.any (`elem` ['\n', '|', '\t']))
      Text.length sanitized `shouldBe` 160

    it "keeps a provider's name from steering the operator's terminal" $ do
      -- A C1 control (the 8-bit escape introducer) and a bidirectional override.
      let steering = Text.pack ("a" <> ['\x9b'] <> "b" <> ['\x202e'] <> "c" <> ['\DEL'] <> "d")
      sanitizeAuditText steering `shouldBe` "a b c d"

    it "keeps an ARN by its resource part, so two load balancers of one account differ" $ do
      let region = Text.pack (fixtureAwsRegion FixtureCaCentral1)
          arn name =
            "arn:aws:elasticloadbalancing:"
              <> region
              <> ":123456789012:loadbalancer/app/"
              <> name
              <> "/50dc6c495c0c9188"
      auditRowIdentity (row AuditLoadBalancer (arn "own") "")
        `shouldBe` "loadbalancer/app/own/50dc6c495c0c9188"
      auditRowIdentity (row AuditLoadBalancer (arn "own") "")
        `shouldNotBe` auditRowIdentity (row AuditLoadBalancer (arn "other") "")
      -- Text that is not an ARN, or is too short to be one, is left as it is.
      auditRowIdentity (row AuditSubnet "subnet-0a1" "") `shouldBe` "subnet-0a1"
      auditRowIdentity (row AuditLoadBalancer "arn:aws:elasticloadbalancing:x:y" "")
        `shouldBe` "arn:aws:elasticloadbalancing:x:y"

    describe "the report" $ do
      let leaked =
            observe
              AuditAwsEks
              ( replacing
                  AuditAwsEks
                  AuditNetworkInterface
                  (auditAnswered [row AuditNetworkInterface "eni-0aa1" "status=available"])
              )
              AuditControlSeen
          rendered = renderAuditReport leaked (auditVerdict leaked)

      it "carries stable tokens and names the identifiers only here" $ do
        rendered `shouldContain` ["AWS_FIELD aws-eks verdict=Residue"]
        rendered `shouldContain` ["AWS_FIELD aws-eks class=network-interface count=1"]
        rendered `shouldContain` ["AWS_FIELD aws-eks network-interface eni-0aa1 status=available"]
        rendered `shouldContain` ["AWS_FIELD aws-eks control=seen"]

      it "names the classes that did not answer and the control, and never prints an empty class" $ do
        let blind =
              observe
                AuditAwsTest
                (replacing AuditAwsTest AuditInstance (auditUnanswered "AccessDenied"))
                AuditControlMissing
            report = renderAuditReport blind (auditVerdict blind)
        report `shouldContain` ["AWS_FIELD aws-test verdict=Unobservable"]
        report `shouldContain` ["AWS_FIELD aws-test unanswered=instance (AccessDenied)"]
        report `shouldContain` ["AWS_FIELD aws-test control=missing"]
        concatMap Text.unpack report `shouldNotContain` "count=0"

      it "lists at most twenty rows of a class and says how many it left out" $ do
        let many = [row AuditNetworkInterface ("eni-" <> Text.pack (show n)) "" | n <- [1 .. 25 :: Int]]
            observation =
              observe
                AuditAwsEks
                (replacing AuditAwsEks AuditNetworkInterface (auditAnswered many))
                AuditControlSeen
            report = renderAuditReport observation (auditVerdict observation)
        length [line | line <- report, "network-interface eni-" `Text.isInfixOf` line] `shouldBe` 20
        report `shouldContain` ["AWS_FIELD aws-eks network-interface omitted=5"]

    describe "what a run leaves behind" $ do
      it "holds counts, class labels and the control, in a canonical text" $ do
        let observation =
              observe
                AuditAwsEks
                ( replacing
                    AuditAwsEks
                    AuditNetworkInterface
                    (auditAnswered [row AuditNetworkInterface "eni-0aa1" "status=available"])
                )
                AuditControlSeen
        encodeAuditRecord (auditRecord observation)
          `shouldBe` "aws-audit/v1 stack=aws-eks verdict=Residue control=seen network-interface=1"

      propertyTest "carries no raw identifier and no provider description" $
        forAll genObservation $ \observation ->
          let encoded = Text.unpack (encodeAuditRecord (auditRecord observation))
              leaks =
                [ Text.unpack text
                | r <- auditRows observation
                , text <- [auditRowIdentity r, auditRowDetail r]
                ]
           in not (any (`isInfixOf` encoded) leaks)

    describe "the diff" $ do
      it "separates what went away, what is still there and what is new" $ do
        let still = row AuditSecurityGroup "sg-still" ""
            gone = row AuditNetworkInterface "eni-gone" ""
            fresh = row AuditNatGateway "nat-new" ""
            baseline =
              observe
                AuditAwsEks
                ( [ (AuditSecurityGroup, auditAnswered [still])
                  , (AuditNetworkInterface, auditAnswered [gone])
                  ]
                    <> [ (c, auditAnswered [])
                       | c <- auditStackClasses AuditAwsEks
                       , c `notElem` [AuditSecurityGroup, AuditNetworkInterface]
                       ]
                )
                AuditControlSeen
            final =
              observe
                AuditAwsEks
                ( [ (AuditSecurityGroup, auditAnswered [still])
                  , (AuditNatGateway, auditAnswered [fresh])
                  ]
                    <> [ (c, auditAnswered [])
                       | c <- auditStackClasses AuditAwsEks
                       , c `notElem` [AuditSecurityGroup, AuditNatGateway]
                       ]
                )
                AuditControlSeen
            diff = diffAuditObservations baseline final
        diff
          `shouldBe` AuditDiff
            { auditDiffRemoved = [gone]
            , auditDiffRemaining = [still]
            , auditDiffAppeared = [fresh]
            }
        renderAuditDiff final (auditVerdict final) diff
          `shouldContain` ["AWS_FIELD_DIFF aws-eks verdict=Residue removed=1 remaining=1 appeared=1"]
        renderAuditDiff final (auditVerdict final) diff
          `shouldContain` ["AWS_FIELD_DIFF remaining security-group sg-still"]

    it "declares a field for every stack, and none shares a class by accident" $ do
      mapM_
        (\stack -> auditStackClasses stack `shouldSatisfy` (not . null))
        [minBound .. maxBound :: AuditStack]
      auditStackClasses AuditAwsEksSubzone `shouldBe` [AuditHostedZone, AuditDelegationRecord]
      auditStackOfRef "aws-eks" `shouldBe` Just AuditAwsEks
      auditStackOfRef "aws-ses" `shouldBe` Nothing
 where
  isUnobservable verdict = case verdict of
    AuditUnobservable _ _ -> True
    _ -> False
