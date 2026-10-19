{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.110: the audit across the wire between the Provider that took it
-- and the operator that reads it.
--
-- The evidence has room for forty rows inside the shared 4,096-character bound,
-- and a leaking VPC can hold more interfaces than that. These cases hold that
-- the encoder never refuses for size, that it carries every count and as many
-- residue rows as fit, that the decoder reads back exactly what the encoder
-- wrote, and that evidence about another stack, account or region is refused.
module AwsAuditWire (awsAuditWireSuite) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( ProviderEvidenceBound
  , providerEvidenceFamilyBound
  , providerEvidenceText
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport

refFor :: Text -> Text -> ProviderNativeStackFamilyRef
refFor stack account =
  either (error . show) id $ do
    stackRef <- mkProviderStackRef stack
    mkProviderNativeStackFamilyRef stackRef account (fixtureAwsRegion FixtureCaCentral1) Nothing

eksRef :: ProviderNativeStackFamilyRef
eksRef = refFor "aws-eks" "123456789012"

-- | The binding row of audit evidence about the EKS stack, in the fixture
-- account and region, with the digest of the field this build declares.
bindingText :: Text
bindingText =
  "prodbox-aws-audit/v2:present:binding|aws-eks|123456789012|"
    <> fixtureAwsRegion FixtureCaCentral1
    <> "|"
    <> auditFieldDigest AuditAwsEks

bound :: ProviderEvidenceBound
bound = providerIntentEvidenceBound (ObserveAwsAudit eksTarget eksConfig fixtureControl)

eksTarget :: ProviderAuditTarget
eksTarget =
  either
    (error . show)
    id
    (mkProviderStackRef "aws-eks" >>= \stackRef -> mkProviderAuditTarget stackRef Nothing)

eksConfig :: ProviderStackConfig
eksConfig = either (error . show) id (mkAwsEksProviderStackConfig "203.0.113.1/32")

fixtureControl :: ProviderAuditControl
fixtureControl = either (error . show) id (mkProviderAuditControl "prodbox-state-fixture" Nothing)

observation
  :: [(AuditClass, AuditAnswer)]
  -> AuditControl
  -> AuditObservation
observation answers control =
  either (error . show) id (mkAuditObservation AuditAwsEks answers control)

enis :: Int -> [AuditRow]
enis count =
  [ mkAuditRow
      AuditNetworkInterface
      ("eni-" <> Text.justifyRight 17 '0' (Text.pack (show n)))
      "available self cni"
  | n <- [1 .. count]
  ]

encoded :: AuditObservation -> Either Text Text
encoded obs = providerEvidenceText <$> encodeAwsAuditEvidence bound eksRef obs

-- | The observation the evidence carries, for the stack it is about.
readBack :: Text -> Either Text AuditObservation
readBack = fmap snd . decodeAwsAuditEvidence AuditAwsEks

totalOf :: AuditObservation -> AuditClass -> Natural
totalOf obs class' = case Map.lookup class' (auditObservationAnswers obs) of
  Just answer -> fromIntegral (length (auditAnswerRows answer)) + auditAnswerOmitted answer
  Nothing -> 0

awsAuditWireSuite :: SuiteBuilder ()
awsAuditWireSuite =
  describe "Sprint 4.110 the audit evidence" $ do
    it "names nothing in a clean field: the binding and the control" $ do
      let clean = observation [] AuditControlSeen
          cleanAnswers = [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks]
          obs = observation cleanAnswers AuditControlSeen
      encoded obs
        `shouldBe` Right
          ( "prodbox-aws-audit/v2:present:binding|aws-eks|123456789012|"
              <> fixtureAwsRegion FixtureCaCentral1
              <> "|"
              <> auditFieldDigest AuditAwsEks
              <> ",control|seen"
          )
      (readBack =<< encoded obs) `shouldBe` Right obs
      -- A class nobody answered is carried as a gap, so it cannot read back clean.
      fmap auditVerdict (readBack =<< encoded clean)
        `shouldSatisfy` either (const False) isUnobservable

    it "reads back exactly what it wrote, rows, counts, a partial class and the control" $ do
      let answers =
            [ (c, answerFor c)
            | c <- auditStackClasses AuditAwsEks
            ]
          answerFor c = case c of
            AuditNetworkInterface -> auditAnswered (enis 3)
            AuditSecurityGroup ->
              auditPartial
                [mkAuditRow AuditSecurityGroup "sg-0aa1" "name=k8s-elb"]
                "describe-security-groups failed"
            AuditLoadBalancer -> auditUnanswered "AccessDenied"
            _ -> auditAnswered []
          obs = observation answers (AuditControlUnanswered "catalog refused")
      (readBack =<< encoded obs) `shouldBe` Right obs

    it "carries every count and as many rows as fit when a field holds far more than forty rows" $ do
      let obs =
            observation
              ( [(AuditNetworkInterface, auditAnswered (enis 300))]
                  <> [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks, c /= AuditNetworkInterface]
              )
              AuditControlSeen
      case encoded obs of
        Left detail -> expectationFailure (Text.unpack detail)
        Right text -> do
          Text.length text `shouldSatisfy` (<= maximumProviderIntentEvidenceCharacters)
          -- The decoder reads the same total back, though not every row.
          case readBack text of
            Left detail -> expectationFailure (Text.unpack detail)
            Right decoded -> do
              totalOf decoded AuditNetworkInterface `shouldBe` 300
              auditVerdict decoded `shouldBe` AuditResidue (Map.fromList [(AuditNetworkInterface, 300)])
              length (auditRows decoded) `shouldSatisfy` (< 300)
              length (auditRows decoded) `shouldSatisfy` (> 20)

    it "shares the room among classes so one class cannot hide another" $ do
      -- The lone row is in a class that sorts after the chatty one, so a codec
      -- that filled the room class by class would drop it and only the sharing
      -- can keep it.
      let obs =
            observation
              ( [ (AuditNetworkInterface, auditAnswered (enis 300))
                , (AuditLoadBalancer, auditAnswered [mkAuditRow AuditLoadBalancer "lb-0only" "state=active"])
                ]
                  <> [ (c, auditAnswered [])
                     | c <- auditStackClasses AuditAwsEks
                     , c `notElem` [AuditNetworkInterface, AuditLoadBalancer]
                     ]
              )
              AuditControlSeen
      case (readBack =<< encoded obs) of
        Left detail -> expectationFailure (Text.unpack detail)
        Right decoded ->
          [auditRowIdentity r | r <- auditRows decoded, auditRowClass r == AuditLoadBalancer]
            `shouldBe` ["lb-0only"]

    it "never refuses for size, even with every class holding rows and every class a gap" $ do
      let busy c =
            auditPartial
              [mkAuditRow c ("id-" <> auditClassLabel c <> "-" <> Text.pack (show n)) "x" | n <- [1 .. 5 :: Int]]
              "a query did not answer"
          obs = observation [(c, busy c) | c <- auditStackClasses AuditAwsEks] AuditControlSeen
      case encoded obs of
        Left detail -> expectationFailure (Text.unpack detail)
        Right text -> do
          Text.length text `shouldSatisfy` (<= maximumProviderIntentEvidenceCharacters)
          case readBack text of
            Left detail -> expectationFailure (Text.unpack detail)
            Right decoded -> do
              -- Every class still counts and still says it had a gap.
              mapM_
                (\c -> totalOf decoded c `shouldBe` 5)
                (auditStackClasses AuditAwsEks)
              auditVerdict decoded `shouldSatisfy` isResidue

    it "reports the account and region it audited, and refuses evidence about another stack" $ do
      let obs = observation [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks] AuditControlSeen
      text <- either (fail . Text.unpack) pure (encoded obs)
      fmap fst (decodeAwsAuditEvidence AuditAwsEks text)
        `shouldBe` Right (AuditBinding "123456789012" (fixtureAwsRegion FixtureCaCentral1))
      decodeAwsAuditEvidence AuditAwsTest text `shouldSatisfy` isLeft'

    it "carries an identity of sixty-four characters and a detail of several words whole" $ do
      let identity = Text.replicate 64 "i"
          detail = "available self aws-K8S-i-05c0f66fdcd02bf20"
          obs =
            observation
              ( [(AuditNetworkInterface, auditAnswered [mkAuditRow AuditNetworkInterface identity detail])]
                  <> [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks, c /= AuditNetworkInterface]
              )
              AuditControlSeen
      case readBack =<< encoded obs of
        Left reason -> expectationFailure (Text.unpack reason)
        Right decoded ->
          [(auditRowIdentity r, auditRowDetail r) | r <- auditRows decoded]
            `shouldBe` [(identity, detail)]

    it "keeps two load balancers of one account apart through the wire and the diff" $ do
      let region = Text.pack (fixtureAwsRegion FixtureCaCentral1)
          arn name =
            "arn:aws:elasticloadbalancing:"
              <> region
              <> ":123456789012:loadbalancer/app/"
              <> name
              <> "/50dc6c495c0c9188"
          holding names =
            observation
              ( [
                  ( AuditLoadBalancer
                  , auditAnswered [mkAuditRow AuditLoadBalancer (arn name) "active" | name <- names]
                  )
                ]
                  <> [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks, c /= AuditLoadBalancer]
              )
              AuditControlSeen
          roundTrip obs = either (const obs) id (readBack =<< encoded obs)
          before = roundTrip (holding ["own", "other"])
          after = roundTrip (holding ["own"])
      length (auditRows before) `shouldBe` 2
      map auditRowIdentity (auditDiffRemoved (diffAuditObservations before after))
        `shouldBe` ["loadbalancer/app/other/50dc6c495c0c9188"]
      map auditRowIdentity (auditDiffRemaining (diffAuditObservations before after))
        `shouldBe` ["loadbalancer/app/own/50dc6c495c0c9188"]

    it "refuses evidence that contradicts itself" $ do
      let withRows rows = bindingText <> ",control|seen," <> rows
      readBack
        (withRows "count|network-interface|1,row|network-interface|eni-1|a,row|network-interface|eni-2|b")
        `shouldSatisfy` isLeft'
      readBack "prodbox-aws-audit/v2:absent" `shouldSatisfy` isLeft'

    describe "the decoder refuses what the encoder cannot have produced" $ do
      let clean = bindingText <> ",control|seen"
          withBinding binding = "prodbox-aws-audit/v2:present:" <> binding <> ",control|seen"
          region = fixtureAwsRegion FixtureCaCentral1 :: Text

      it "reads the shape the encoder produces" $
        fmap auditVerdict (readBack clean) `shouldBe` Right AuditClean

      it "refuses evidence taken over a different field than this build declares" $
        case readBack
          ( withBinding
              ("binding|aws-eks|123456789012|" <> region <> "|0000000000000000")
          ) of
          Left reason -> reason `shouldSatisfy` Text.isInfixOf "different field"
          Right _ -> expectationFailure "evidence over another field must be refused"

      it "refuses a row this build does not know, rather than ignoring it" $
        readBack (clean <> ",zzz|x") `shouldSatisfy` isLeft'

      it "refuses a class counted twice" $
        readBack (clean <> ",count|network-interface|1,count|network-interface|2")
          `shouldSatisfy` isLeft'

      it "refuses a count that is not a plain natural number, or that counts nothing" $
        mapM_
          ( \count ->
              readBack (clean <> ",count|network-interface|" <> count) `shouldSatisfy` isLeft'
          )
          ["007", "+5", "0x10", "5.0", "-1", "0", "five"]

      it "refuses rows for a class that is counted nowhere" $
        readBack (clean <> ",row|network-interface|eni-1|a") `shouldSatisfy` isLeft'

      it "refuses a binding that is not an account and a region" $
        mapM_
          (\binding -> readBack (withBinding binding) `shouldSatisfy` isLeft')
          [ "binding|aws-eks|12345|" <> region <> "|" <> auditFieldDigest AuditAwsEks
          , "binding|aws-eks|123456789012|NOT-A-REGION|" <> auditFieldDigest AuditAwsEks
          , "binding|aws-eks|123456789012|" <> region
          ]

    describe "the room and the reasons" $ do
      it "digests the field a stack declares, so a Provider and a CLI that disagree cannot agree" $ do
        Text.length (auditFieldDigest AuditAwsEks) `shouldBe` 16
        auditFieldDigest AuditAwsEks `shouldNotBe` auditFieldDigest AuditAwsTest
        auditFieldDigest AuditAwsEks `shouldBe` auditFieldDigest AuditAwsEks

      it "leaves the fixed rows room inside the family for the widest field" $
        maximum [2 + 2 * length (auditStackClasses stack) | stack <- [minBound .. maxBound]]
          `shouldSatisfy` (<= 40)

      it "never renders evidence the reader refuses, however long the identities and details" $ do
        let heavy =
              observation
                ( [ ( c
                    , auditAnswered
                        [ mkAuditRow c (Text.justifyRight 64 'x' (Text.pack (show n))) (Text.replicate 48 "d")
                        | n <- [1 .. 8 :: Int]
                        ]
                    )
                  | c <- take 10 (auditStackClasses AuditAwsEks)
                  ]
                    <> [(c, auditAnswered []) | c <- drop 10 (auditStackClasses AuditAwsEks)]
                )
                AuditControlSeen
        case encoded heavy of
          Left reason -> expectationFailure (Text.unpack reason)
          Right text -> do
            (Text.length text <= providerEvidenceFamilyBound awsAuditEvidenceFamily) `shouldBe` True
            readBack text `shouldSatisfy` either (const False) (const True)

      it "stays inside the reader's bound at every width of identity and detail" $
        -- One heavy field fits the bound by luck: the rows it packs end short of
        -- the window between the family's bound and the shared one. Sweeping the
        -- widths puts a row's end in that window for some of them, which an
        -- encoder that fits only the intent's bound would then overrun. One class
        -- holds the rows, so that the fixed rows and the forty-row cap leave the
        -- bytes to be what ends the packing.
        mapM_
          ( \(identityWidth, detailWidth) -> do
              let heavy =
                    observation
                      ( ( AuditNetworkInterface
                        , auditAnswered
                            [ mkAuditRow
                                AuditNetworkInterface
                                (Text.justifyRight identityWidth 'x' (Text.pack (show n)))
                                (Text.replicate detailWidth "d")
                            | n <- [1 .. 60 :: Int]
                            ]
                        )
                          : [ (c, auditAnswered [])
                            | c <- auditStackClasses AuditAwsEks
                            , c /= AuditNetworkInterface
                            ]
                      )
                      AuditControlSeen
              case encoded heavy of
                Left reason -> expectationFailure (Text.unpack reason)
                Right text -> do
                  (Text.length text <= providerEvidenceFamilyBound awsAuditEvidenceFamily) `shouldBe` True
                  readBack text `shouldSatisfy` either (const False) (const True)
          )
          [(identityWidth, detailWidth) | identityWidth <- [1 .. 64], detailWidth <- [1, 12, 24, 36, 48]]

      it "carries the command and the code AWS answered with, whole" $ do
        let reason = "ec2 describe-network-interfaces: AccessDenied"
            controlReason = "resourcegroupstaggingapi get-resources: AccessDenied"
            obs =
              observation
                ( (AuditNetworkInterface, auditUnanswered reason)
                    : [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks, c /= AuditNetworkInterface]
                )
                (AuditControlUnanswered controlReason)
        (readBack =<< encoded obs) `shouldBe` Right obs

    it "keeps every raw identifier out of the persisted record however large the field" $ do
      let obs =
            observation
              ( [(AuditNetworkInterface, auditAnswered (enis 300))]
                  <> [(c, auditAnswered []) | c <- auditStackClasses AuditAwsEks, c /= AuditNetworkInterface]
              )
              AuditControlSeen
      Text.unpack (encodeAuditRecord (auditRecord obs)) `shouldNotContain` "eni-0"

    describe "the control names the region of the catalog that lists it" $ do
      let elsewhere = fixtureAwsRegion FixtureUsWest2 :: Text

      it "round-trips with a region and without one" $ do
        mapM_
          ( \region -> do
              let built = mkProviderAuditControl "prodbox-state" region
              fmap providerAuditControlText built
                `shouldBe` Right ("prodbox-state" <> maybe "" ("@" <>) region)
              (parseProviderAuditControl . providerAuditControlText =<< built) `shouldBe` built
          )
          [Nothing, Just elsewhere]

      it "refuses a region that is not spelled as a region, and a control with more than one separator" $ do
        mapM_
          (\region -> mkProviderAuditControl "prodbox-state" (Just region) `shouldSatisfy` isLeft')
          ["", "us", "US-WEST-2", "us west 2", "../x", Text.replicate 65 "a"]
        mapM_
          (\text -> parseProviderAuditControl text `shouldSatisfy` isLeft')
          ["prodbox-state@", "@" <> elsewhere, "prodbox-state@" <> elsewhere <> "@x", ""]

    describe "the positive control a request carries" $ do
      it "is a bucket name, and nothing else" $ do
        mapM_
          (\name -> mkProviderAuditControl name Nothing `shouldSatisfy` isRight')
          ["prodbox-state", "a.b-c", "abc"]
        mapM_
          (\name -> mkProviderAuditControl name Nothing `shouldSatisfy` isLeft')
          ["", "ab", "Prodbox", "-state", "state-", "has space", "../etc", "a;b", Text.replicate 64 "a"]
 where
  isLeft' = either (const True) (const False)
  isRight' = either (const False) (const True)
  isUnobservable verdict = case verdict of
    AuditUnobservable _ _ -> True
    _ -> False
  isResidue verdict = case verdict of
    AuditResidue _ -> True
    _ -> False
