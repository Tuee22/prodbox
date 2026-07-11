{-# LANGUAGE OverloadedStrings #-}

module AwsSesReadiness
  ( awsSesReadinessSuite
  )
where

import Control.Monad (forM_)
import Data.Aeson
  ( Value
  , encode
  , object
  , (.=)
  )
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List.NonEmpty (NonEmpty (..))
import Prodbox.Result (Result (..))
import Prodbox.Ses.Readiness
  ( AwsSesPropagationPolicy
  , AwsSesPropagationPolicyError (..)
  , AwsSesProviderReadiness (..)
  , AwsSesReadiness (..)
  , AwsSesReadinessComponent (..)
  , AwsSesReadinessEnvironments (..)
  , AwsSesReadinessExpectation (..)
  , AwsSesReadinessObservation (..)
  , AwsSesReadinessPollFailure (..)
  , AwsSesReadinessProbe (..)
  , AwsSesReadinessReason (..)
  , AwsSesReadinessScope (..)
  , awsSesPropagationWindowSeconds
  , awsSesReadinessProbeArguments
  , canonicalAwsSesPropagationPolicy
  , classifyAwsSesReadiness
  , classifyAwsSesReadinessProbe
  , mkAwsSesPropagationPolicy
  , mkAwsSesReadinessExpectation
  , observeAwsSesReadinessWith
  , pollAwsSesReadinessWith
  , providerThenSemanticReadiness
  , renderAwsSesReadinessPollFailure
  , sesCaptureKeyPrefix
  , sesCaptureReadinessKey
  , sesInboundMxPriority
  , sesInboundMxTarget
  , sesReceiveRuleName
  , sesReceiveRuleSetName
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  )
import System.Exit (ExitCode (..))
import TestSupport

awsSesReadinessSuite :: SuiteBuilder ()
awsSesReadinessSuite =
  describe "Sprint 8.10 semantic SES readiness" $ do
    it "constructs one canonical expectation from validated external inputs" $ do
      mkAwsSesReadinessExpectation
        " Example.COM. "
        " /hostedzone/Z123EXACT "
        " us-west-2 "
        " Inbox.Example.COM. "
        "prodbox-ses-capture"
        `shouldBe` Right canonicalExpectation
      awsSesExpectedMxPriority canonicalExpectation `shouldBe` sesInboundMxPriority
      awsSesExpectedMxTarget canonicalExpectation `shouldBe` sesInboundMxTarget "us-west-2"
      awsSesExpectedRuleSetName canonicalExpectation `shouldBe` sesReceiveRuleSetName
      awsSesExpectedRuleName canonicalExpectation `shouldBe` sesReceiveRuleName
      awsSesExpectedCapturePrefix canonicalExpectation `shouldBe` sesCaptureKeyPrefix
      awsSesExpectedCaptureReadinessKey canonicalExpectation `shouldBe` sesCaptureReadinessKey

    it "rejects invalid sender, zone, region, receive-subdomain, and bucket inputs" $ do
      forM_
        [ mkExpectationWith "bad_domain" "Z123EXACT" "us-west-2" "inbox.example.com" "prodbox-ses-capture"
        , mkExpectationWith "example.com" "bad/zone" "us-west-2" "inbox.example.com" "prodbox-ses-capture"
        , mkExpectationWith "example.com" "Z123EXACT" "US_WEST_2" "inbox.example.com" "prodbox-ses-capture"
        , mkExpectationWith "example.com" "Z123EXACT" "us-west-2" "example.com" "prodbox-ses-capture"
        , mkExpectationWith "example.com" "Z123EXACT" "us-west-2" "other.test" "prodbox-ses-capture"
        , mkExpectationWith "example.com" "Z123EXACT" "us-west-2" "inbox.example.com" "192.168.0.1"
        , mkExpectationWith "example.com" "Z123EXACT" "us-west-2" "inbox.example.com" "Bad_Bucket"
        ]
        (`shouldSatisfy` isLeft)

    it "enforces inclusive five-to-thirty-minute propagation bounds" $ do
      mkAwsSesPropagationPolicy 1 300000000
        `shouldBe` Left (AwsSesPropagationAttemptsMustExceedOne 1)
      mkAwsSesPropagationPolicy 2 0
        `shouldBe` Left (AwsSesPropagationDelayMustBePositive 0)
      mkAwsSesPropagationPolicy 2 299000000
        `shouldBe` Left (AwsSesPropagationWindowOutsideBounds 299)
      mkAwsSesPropagationPolicy 2 1801000000
        `shouldBe` Left (AwsSesPropagationWindowOutsideBounds 1801)
      fmap awsSesPropagationWindowSeconds (mkAwsSesPropagationPolicy 2 300000000)
        `shouldBe` Right 300
      fmap awsSesPropagationWindowSeconds (mkAwsSesPropagationPolicy 2 1800000000)
        `shouldBe` Right 1800
      awsSesPropagationWindowSeconds canonicalAwsSesPropagationPolicy `shouldBe` 1200

    it "pins every AWS CLI probe to its exact argument vector" $ do
      let destination = "/tmp/readiness-object"
      awsSesReadinessProbeArguments canonicalExpectation destination AwsSesEmailIdentityProbe
        `shouldBe` [ "sesv2"
                   , "get-email-identity"
                   , "--email-identity"
                   , "example.com"
                   , "--output"
                   , "json"
                   ]
      awsSesReadinessProbeArguments canonicalExpectation destination AwsSesReceiveMxProbe
        `shouldBe` [ "route53"
                   , "list-resource-record-sets"
                   , "--hosted-zone-id"
                   , "Z123EXACT"
                   , "--output"
                   , "json"
                   ]
      awsSesReadinessProbeArguments canonicalExpectation destination AwsSesActiveReceiptRulesProbe
        `shouldBe` ["ses", "describe-active-receipt-rule-set", "--output", "json"]
      awsSesReadinessProbeArguments canonicalExpectation destination AwsSesCaptureListProbe
        `shouldBe` [ "s3api"
                   , "list-objects-v2"
                   , "--bucket"
                   , "prodbox-ses-capture"
                   , "--prefix"
                   , sesCaptureReadinessKey
                   , "--max-keys"
                   , "1"
                   , "--output"
                   , "json"
                   ]
      awsSesReadinessProbeArguments canonicalExpectation destination AwsSesCaptureGetProbe
        `shouldBe` [ "s3api"
                   , "get-object"
                   , "--bucket"
                   , "prodbox-ses-capture"
                   , "--key"
                   , sesCaptureReadinessKey
                   , destination
                   , "--output"
                   , "json"
                   ]

    it "uses the lease-role environment for control-plane probes and the capture credential for S3" $ do
      seenRef <- newIORef []
      let environments =
            AwsSesReadinessEnvironments
              { awsSesControlPlaneEnvironment = [("CREDENTIAL", "lease-role")]
              , awsSesCaptureEnvironment = [("CREDENTIAL", "capture-reader")]
              }
          runner spec = do
            modifyIORef' seenRef (++ [spec])
            pure (successfulProcess "{}")
      observation <-
        observeAwsSesReadinessWith
          runner
          "/repo"
          environments
          canonicalExpectation
          AwsSesCompleteReadiness
      map fst (awsSesReadinessProbeResults observation)
        `shouldBe` [minBound .. maxBound]
      seen <- readIORef seenRef
      map subprocessPath seen `shouldBe` replicate 5 "aws"
      map subprocessWorkingDirectory seen `shouldBe` replicate 5 (Just "/repo")
      map subprocessEnvironment seen
        `shouldBe` ( replicate 3 (Just [("CREDENTIAL", "lease-role")])
                       ++ replicate 2 (Just [("CREDENTIAL", "capture-reader")])
                   )
      map (take 2 . subprocessArguments) seen
        `shouldBe` [ ["sesv2", "get-email-identity"]
                   , ["route53", "list-resource-record-sets"]
                   , ["ses", "describe-active-receipt-rule-set"]
                   , ["s3api", "list-objects-v2"]
                   , ["s3api", "get-object"]
                   ]

    it "runs semantic probes only after provider presence is Ready" $ do
      forM_
        [ (AwsSesProviderPending "canary not visible", isPending)
        , (AwsSesProviderUnobservable "provider access denied", isUnobservable)
        ]
        $ \(provider, expectedClass) -> do
          semanticCalls <- newIORef (0 :: Int)
          result <-
            providerThenSemanticReadiness
              (pure provider)
              (modifyIORef' semanticCalls (+ 1) >> pure AwsSesReady)
          result `shouldSatisfy` expectedClass
          reasonComponents result `shouldBe` [AwsSesProviderPresenceComponent]
          readIORef semanticCalls `shouldReturn` 0
      semanticCalls <- newIORef (0 :: Int)
      readyResult <-
        providerThenSemanticReadiness
          (pure AwsSesProviderReady)
          (modifyIORef' semanticCalls (+ 1) >> pure (failedState "semantic drift"))
      readyResult `shouldBe` failedState "semantic drift"
      readIORef semanticCalls `shouldReturn` 1

    it "accepts only a verified DOMAIN with enabled successful DKIM" $ do
      classifyIdentity (identityJson "DOMAIN" True "SUCCESS" True "SUCCESS" Nothing)
        `shouldBe` AwsSesReady
      forM_
        [ identityJson "EMAIL_ADDRESS" True "SUCCESS" True "SUCCESS" Nothing
        , identityJson "DOMAIN" False "SUCCESS" True "SUCCESS" Nothing
        , identityJson "DOMAIN" True "SUCCESS" False "SUCCESS" Nothing
        , identityJson "DOMAIN" True "FAILED" True "SUCCESS" (Just "HOST_NOT_FOUND")
        , identityJson "DOMAIN" True "NOT_STARTED" True "SUCCESS" Nothing
        , identityJson "DOMAIN" True "SUCCESS" True "FAILED" Nothing
        , identityJson "DOMAIN" True "SUCCESS" True "NOT_STARTED" Nothing
        ]
        (\payload -> classifyIdentity payload `shouldSatisfy` isFailed)

    it "classifies identity and DKIM propagation states as Pending with AWS detail" $ do
      forM_
        [ identityJson "DOMAIN" False "PENDING" True "SUCCESS" (Just "HOST_NOT_FOUND")
        , identityJson "DOMAIN" False "TEMPORARY_FAILURE" True "SUCCESS" (Just "DNS_SERVER_ERROR")
        , identityJson "DOMAIN" True "SUCCESS" True "PENDING" Nothing
        , identityJson "DOMAIN" True "SUCCESS" True "TEMPORARY_FAILURE" Nothing
        ]
        (\payload -> classifyIdentity payload `shouldSatisfy` isPending)
      reasonDetails
        ( classifyIdentity
            (identityJson "DOMAIN" False "PENDING" True "SUCCESS" (Just "HOST_NOT_FOUND"))
        )
        `shouldSatisfy` any ("VerificationInfo.ErrorType=HOST_NOT_FOUND" `contains`)

    it "keeps unknown, malformed, missing, and wrong-typed exit-success identity output Unobservable" $ do
      forM_
        [ identityJson "DOMAIN" True "NEW_STATUS" True "SUCCESS" Nothing
        , identityJson "DOMAIN" True "SUCCESS" True "NEW_STATUS" Nothing
        , "None\n"
        , "{not-json"
        , "{}"
        , "{\"IdentityType\":\"DOMAIN\",\"VerifiedForSendingStatus\":\"true\",\"VerificationStatus\":\"SUCCESS\",\"DkimAttributes\":{\"SigningEnabled\":true,\"Status\":\"SUCCESS\"}}"
        ]
        (\payload -> classifyIdentity payload `shouldSatisfy` isUnobservable)
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesEmailIdentityProbe
        (Failure "aws executable missing")
        `shouldSatisfy` isUnobservable
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesEmailIdentityProbe
        (failedProcess "An error occurred (AccessDeniedException) when calling GetEmailIdentity")
        `shouldSatisfy` isUnobservable

    it "accepts one DNS-equivalent exact regional MX record" $ do
      classifyMx
        ( mxJson
            [mxRecord "INBOX.EXAMPLE.COM." "mx" (Just ["10 inbound-smtp.US-WEST-2.amazonaws.com."])]
        )
        `shouldBe` AwsSesReady
      classifyMx (mxJson []) `shouldSatisfy` isPending
      classifyMx
        (mxJson [mxRecord "unrelated.example.com." "MX" (Just ["10 mail.example.com."])])
        `shouldSatisfy` isPending

    it "rejects wrong, malformed, multiple, or duplicate matching MX semantics" $ do
      forM_
        [ mxJson [mxRecord "inbox.example.com." "MX" (Just ["20 inbound-smtp.us-west-2.amazonaws.com."])]
        , mxJson [mxRecord "inbox.example.com." "MX" (Just ["10 inbound-smtp.us-east-1.amazonaws.com."])]
        , mxJson [mxRecord "inbox.example.com." "MX" (Just ["not-an-mx-value"])]
        , mxJson
            [ mxRecord
                "inbox.example.com."
                "MX"
                (Just ["10 inbound-smtp.us-west-2.amazonaws.com.", "20 backup.example.com."])
            ]
        , mxJson
            [ mxRecord "inbox.example.com." "MX" (Just ["10 inbound-smtp.us-west-2.amazonaws.com."])
            , mxRecord "INBOX.EXAMPLE.COM" "MX" (Just ["10 inbound-smtp.us-west-2.amazonaws.com."])
            ]
        ]
        (\payload -> classifyMx payload `shouldSatisfy` isFailed)
      classifyMx (mxJson [mxRecord "inbox.example.com." "MX" Nothing])
        `shouldSatisfy` isUnobservable
      classifyMx "{not-json" `shouldSatisfy` isUnobservable
      classifyMx "{\"ResourceRecordSets\":\"wrong-type\"}" `shouldSatisfy` isUnobservable

    it "accepts only the exact enabled receipt rule, recipient, bucket, and prefix" $ do
      classifyRules
        ( receiptJson
            (Just sesReceiveRuleSetName)
            [exactReceiptRule]
        )
        `shouldBe` AwsSesReady
      classifyRules
        ( receiptJson
            (Just sesReceiveRuleSetName)
            [ receiptRule
                sesReceiveRuleName
                True
                ["INBOX.EXAMPLE.COM."]
                [s3ReceiptAction "prodbox-ses-capture" sesCaptureKeyPrefix]
            ]
        )
        `shouldBe` AwsSesReady

    it "distinguishes receipt-rule propagation from explicit drift" $ do
      classifyRules (receiptJson Nothing []) `shouldSatisfy` isPending
      classifyRules (receiptJson (Just sesReceiveRuleSetName) []) `shouldSatisfy` isPending
      classifyRules (receiptJson (Just "some-other-active-set") [exactReceiptRule])
        `shouldSatisfy` isFailed
      forM_
        [ receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName False ["inbox.example.com"] [exactS3Action]]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName True ["other.example.com"] [exactS3Action]]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName True ["inbox.example.com", "extra.example.com"] [exactS3Action]]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName True ["inbox.example.com"] []]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName True ["inbox.example.com"] [nonS3ReceiptAction]]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [ receiptRule
                sesReceiveRuleName
                True
                ["inbox.example.com"]
                [s3ReceiptAction "wrong-bucket" sesCaptureKeyPrefix]
            ]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [ receiptRule
                sesReceiveRuleName
                True
                ["inbox.example.com"]
                [s3ReceiptAction "prodbox-ses-capture" "wrong/"]
            ]
        , receiptJson
            (Just sesReceiveRuleSetName)
            [receiptRule sesReceiveRuleName True ["inbox.example.com"] [exactS3Action, nonS3ReceiptAction]]
        , receiptJson (Just sesReceiveRuleSetName) [exactReceiptRule, exactReceiptRule]
        ]
        (\payload -> classifyRules payload `shouldSatisfy` isFailed)

    it "keeps malformed or internally inconsistent exit-success receipt-rule output Unobservable" $ do
      classifyRules (receiptJson Nothing [exactReceiptRule]) `shouldSatisfy` isUnobservable
      classifyRules "{not-json" `shouldSatisfy` isUnobservable
      classifyRules
        "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":\"true\",\"Recipients\":[],\"Actions\":[]}]}"
        `shouldSatisfy` isUnobservable

    it "classifies optional receipt-rule fields omitted at API defaults as Failed" $ do
      forM_
        [ "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\"}]}"
        , "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Recipients\":[\"inbox.example.com\"],\"Actions\":[{\"S3Action\":{\"BucketName\":\"prodbox-ses-capture\",\"ObjectKeyPrefix\":\"inbound/\"}}]}]}"
        , "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":true,\"Actions\":[{\"S3Action\":{\"BucketName\":\"prodbox-ses-capture\",\"ObjectKeyPrefix\":\"inbound/\"}}]}]}"
        , "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":true,\"Recipients\":[\"inbox.example.com\"]}]}"
        , "{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":true,\"Recipients\":[\"inbox.example.com\"],\"Actions\":[{\"S3Action\":{\"BucketName\":\"prodbox-ses-capture\"}}]}]}"
        ]
        (\payload -> classifyRules payload `shouldSatisfy` isFailed)

    it "proves list capability only when the exact Pulumi-owned canary is visible" $ do
      classifyList (listObjectsJson 1 [sesCaptureReadinessKey]) `shouldBe` AwsSesReady
      classifyList (listObjectsJson 0 []) `shouldSatisfy` isPending
      classifyList (listObjectsJson 1 ["inbound/some-message"]) `shouldSatisfy` isPending
      classifyList (listObjectsJson 2 [sesCaptureReadinessKey]) `shouldSatisfy` isUnobservable
      classifyList "{}" `shouldSatisfy` isUnobservable
      classifyList "None" `shouldSatisfy` isUnobservable
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesCaptureListProbe
        (failedProcess "An error occurred (NoSuchBucket) when calling ListObjectsV2")
        `shouldSatisfy` isPending
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesCaptureListProbe
        (failedProcess "An error occurred (AccessDenied) when calling ListObjectsV2")
        `shouldSatisfy` isUnobservable

    it "proves get capability only from an exit-success object response" $ do
      classifyGet "{}" `shouldBe` AwsSesReady
      classifyGet "{\"ETag\":\"probe-etag\"}" `shouldBe` AwsSesReady
      classifyGet "None" `shouldSatisfy` isUnobservable
      classifyGet "[]" `shouldSatisfy` isUnobservable
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesCaptureGetProbe
        (failedProcess "An error occurred (NoSuchKey) when calling GetObject")
        `shouldSatisfy` isPending
      classifyAwsSesReadinessProbe
        canonicalExpectation
        AwsSesCaptureGetProbe
        (failedProcess "Could not connect to the endpoint URL")
        `shouldSatisfy` isUnobservable

    it "opens complete readiness only when all five unique probes are Ready" $ do
      classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness readyObservation
        `shouldBe` AwsSesReady
      classifyAwsSesReadiness canonicalExpectation AwsSesSendingReadiness readyObservation
        `shouldBe` AwsSesReady
      classifyAwsSesReadiness canonicalExpectation AwsSesReceivingReadiness readyObservation
        `shouldBe` AwsSesReady
      classifyAwsSesReadiness canonicalExpectation AwsSesCaptureReadiness readyObservation
        `shouldBe` AwsSesReady

    it "gives Unobservable precedence over Failed, and Failed over Pending" $ do
      let pendingIdentity = successfulProcess (identityJson "DOMAIN" False "PENDING" True "SUCCESS" Nothing)
          failedMx = successfulProcess (mxJson [mxRecord "inbox.example.com" "MX" (Just ["20 wrong.example.com"])])
          unobservableGet = successfulProcess "None"
          mixed =
            replaceProbe
              AwsSesEmailIdentityProbe
              pendingIdentity
              ( replaceProbe
                  AwsSesReceiveMxProbe
                  failedMx
                  (replaceProbe AwsSesCaptureGetProbe unobservableGet readyObservation)
              )
          withoutUnobservable = replaceProbe AwsSesCaptureGetProbe (successfulProcess "{}") mixed
      classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness mixed
        `shouldSatisfy` isUnobservable
      reasonComponents (classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness mixed)
        `shouldBe` [AwsSesCaptureGetComponent]
      classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness withoutUnobservable
        `shouldSatisfy` isFailed
      reasonComponents
        (classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness withoutUnobservable)
        `shouldBe` [AwsSesReceiveMxComponent]
      classifyAwsSesReadiness
        canonicalExpectation
        AwsSesCompleteReadiness
        (replaceProbe AwsSesReceiveMxProbe (successfulProcess (mxJson [])) readyObservation)
        `shouldSatisfy` isPending

    it "fails closed on an omitted or duplicate required probe" $ do
      let withoutMx =
            AwsSesReadinessObservation
              [ pair
              | pair@(probe, _) <- awsSesReadinessProbeResults readyObservation
              , probe /= AwsSesReceiveMxProbe
              ]
          duplicateIdentity =
            AwsSesReadinessObservation
              ( ( AwsSesEmailIdentityProbe
                , successfulProcess
                    (identityJson "DOMAIN" True "SUCCESS" True "SUCCESS" Nothing)
                )
                  : awsSesReadinessProbeResults readyObservation
              )
      classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness withoutMx
        `shouldSatisfy` hasReason AwsSesReceiveMxComponent "omitted this required probe"
      classifyAwsSesReadiness canonicalExpectation AwsSesCompleteReadiness duplicateIdentity
        `shouldSatisfy` hasReason AwsSesSendingIdentityComponent "duplicate results"

    it "polls only Pending observations and then returns Ready" $ do
      observationsRef <- newIORef [pendingState "first propagation sample", AwsSesReady]
      waitsRef <- newIORef []
      result <-
        pollAwsSesReadinessWith
          shortPolicy
          (\delay -> modifyIORef' waitsRef (++ [delay]))
          (popObservation observationsRef)
      result `shouldBe` Right ()
      readIORef waitsRef `shouldReturn` [150000000]
      readIORef observationsRef `shouldReturn` []

    it "stops immediately on terminal Failed or Unobservable observations" $ do
      forM_
        [
          ( failedState "explicit drift"
          , Left (AwsSesReadinessTerminalFailure (readinessReasons (failedState "explicit drift")))
          )
        ,
          ( unobservableState "transport unavailable"
          , Left
              ( AwsSesReadinessObservationFailure
                  (readinessReasons (unobservableState "transport unavailable"))
              )
          )
        ]
        $ \(observation, expectedResult) -> do
          observationsRef <- newIORef (0 :: Int)
          waitsRef <- newIORef []
          result <-
            pollAwsSesReadinessWith
              shortPolicy
              (\delay -> modifyIORef' waitsRef (++ [delay]))
              (modifyIORef' observationsRef (+ 1) >> pure observation)
          result `shouldBe` expectedResult
          readIORef observationsRef `shouldReturn` 1
          readIORef waitsRef `shouldReturn` []

    it "exhausts the exact bound and preserves the last structured Pending reason" $ do
      attemptsRef <- newIORef (0 :: Int)
      waitsRef <- newIORef []
      result <-
        pollAwsSesReadinessWith
          shortPolicy
          (\delay -> modifyIORef' waitsRef (++ [delay]))
          ( do
              modifyIORef' attemptsRef (+ 1)
              attempt <- readIORef attemptsRef
              pure (pendingState ("pending sample " ++ show attempt))
          )
      let lastReasons = readinessReasons (pendingState "pending sample 3")
          expected = Left (AwsSesReadinessTimedOut lastReasons)
      result `shouldBe` expected
      readIORef attemptsRef `shouldReturn` 3
      readIORef waitsRef `shouldReturn` [150000000, 150000000]
      renderAwsSesReadinessPollFailure (AwsSesReadinessTimedOut lastReasons)
        `shouldContain` "pending sample 3"

canonicalExpectation :: AwsSesReadinessExpectation
canonicalExpectation =
  expectRight
    ( mkAwsSesReadinessExpectation
        "example.com"
        "Z123EXACT"
        "us-west-2"
        "inbox.example.com"
        "prodbox-ses-capture"
    )

mkExpectationWith
  :: String -> String -> String -> String -> String -> Either String AwsSesReadinessExpectation
mkExpectationWith = mkAwsSesReadinessExpectation

shortPolicy :: AwsSesPropagationPolicy
shortPolicy = expectRight (mkAwsSesPropagationPolicy 3 150000000)

classifyIdentity :: String -> AwsSesReadiness
classifyIdentity = classifySuccess AwsSesEmailIdentityProbe

classifyMx :: String -> AwsSesReadiness
classifyMx = classifySuccess AwsSesReceiveMxProbe

classifyRules :: String -> AwsSesReadiness
classifyRules = classifySuccess AwsSesActiveReceiptRulesProbe

classifyList :: String -> AwsSesReadiness
classifyList = classifySuccess AwsSesCaptureListProbe

classifyGet :: String -> AwsSesReadiness
classifyGet = classifySuccess AwsSesCaptureGetProbe

classifySuccess :: AwsSesReadinessProbe -> String -> AwsSesReadiness
classifySuccess probe payload =
  classifyAwsSesReadinessProbe canonicalExpectation probe (successfulProcess payload)

successfulProcess :: String -> Result ProcessOutput
successfulProcess stdout =
  Success
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = stdout
      , processStderr = ""
      }

failedProcess :: String -> Result ProcessOutput
failedProcess stderr =
  Success
    ProcessOutput
      { processExitCode = ExitFailure 1
      , processStdout = ""
      , processStderr = stderr
      }

identityJson :: String -> Bool -> String -> Bool -> String -> Maybe String -> String
identityJson responseIdentityType verified verificationStatus signingEnabled dkimStatus maybeError =
  renderJson $
    object
      ( [ "IdentityType" .= responseIdentityType
        , "VerifiedForSendingStatus" .= verified
        , "VerificationStatus" .= verificationStatus
        , "DkimAttributes"
            .= object
              [ "SigningEnabled" .= signingEnabled
              , "Status" .= dkimStatus
              ]
        ]
          ++ maybe
            []
            (\errorType -> ["VerificationInfo" .= object ["ErrorType" .= errorType]])
            maybeError
      )

mxJson :: [Value] -> String
mxJson records = renderJson (object ["ResourceRecordSets" .= records])

mxRecord :: String -> String -> Maybe [String] -> Value
mxRecord name recordType maybeValues =
  object
    ( [ "Name" .= name
      , "Type" .= recordType
      , "TTL" .= (300 :: Int)
      ]
        ++ maybe
          []
          (\values -> ["ResourceRecords" .= map (\value -> object ["Value" .= value]) values])
          maybeValues
    )

receiptJson :: Maybe String -> [Value] -> String
receiptJson maybeRuleSet rules =
  renderJson $
    object
      ( maybe [] (\name -> ["Metadata" .= object ["Name" .= name]]) maybeRuleSet
          ++ ["Rules" .= rules]
      )

receiptRule :: String -> Bool -> [String] -> [Value] -> Value
receiptRule name enabled recipients actions =
  object
    [ "Name" .= name
    , "Enabled" .= enabled
    , "Recipients" .= recipients
    , "Actions" .= actions
    ]

s3ReceiptAction :: String -> String -> Value
s3ReceiptAction bucket prefix =
  object
    [ "S3Action"
        .= object
          [ "BucketName" .= bucket
          , "ObjectKeyPrefix" .= prefix
          ]
    ]

nonS3ReceiptAction :: Value
nonS3ReceiptAction = object ["StopAction" .= object ["Scope" .= ("RuleSet" :: String)]]

exactS3Action :: Value
exactS3Action = s3ReceiptAction "prodbox-ses-capture" sesCaptureKeyPrefix

exactReceiptRule :: Value
exactReceiptRule =
  receiptRule
    sesReceiveRuleName
    True
    ["inbox.example.com"]
    [exactS3Action]

listObjectsJson :: Int -> [String] -> String
listObjectsJson keyCount keys =
  renderJson $
    object
      [ "KeyCount" .= keyCount
      , "Contents" .= map (\key -> object ["Key" .= key]) keys
      ]

readyObservation :: AwsSesReadinessObservation
readyObservation =
  AwsSesReadinessObservation
    [
      ( AwsSesEmailIdentityProbe
      , successfulProcess (identityJson "DOMAIN" True "SUCCESS" True "SUCCESS" Nothing)
      )
    ,
      ( AwsSesReceiveMxProbe
      , successfulProcess
          ( mxJson
              [ mxRecord
                  "inbox.example.com."
                  "MX"
                  (Just ["10 inbound-smtp.us-west-2.amazonaws.com."])
              ]
          )
      )
    ,
      ( AwsSesActiveReceiptRulesProbe
      , successfulProcess (receiptJson (Just sesReceiveRuleSetName) [exactReceiptRule])
      )
    , (AwsSesCaptureListProbe, successfulProcess (listObjectsJson 1 [sesCaptureReadinessKey]))
    , (AwsSesCaptureGetProbe, successfulProcess "{}")
    ]

replaceProbe
  :: AwsSesReadinessProbe
  -> Result ProcessOutput
  -> AwsSesReadinessObservation
  -> AwsSesReadinessObservation
replaceProbe target replacement observation =
  AwsSesReadinessObservation
    [ if probe == target then (probe, replacement) else pair
    | pair@(probe, _) <- awsSesReadinessProbeResults observation
    ]

pendingState :: String -> AwsSesReadiness
pendingState detail =
  AwsSesPending
    (AwsSesReadinessReason AwsSesSendingIdentityComponent detail :| [])

failedState :: String -> AwsSesReadiness
failedState detail =
  AwsSesFailed
    (AwsSesReadinessReason AwsSesReceiptRuleComponent detail :| [])

unobservableState :: String -> AwsSesReadiness
unobservableState detail =
  AwsSesUnobservable
    (AwsSesReadinessReason AwsSesCaptureGetComponent detail :| [])

readinessReasons :: AwsSesReadiness -> NonEmpty AwsSesReadinessReason
readinessReasons readiness =
  case readiness of
    AwsSesPending reasons -> reasons
    AwsSesFailed reasons -> reasons
    AwsSesUnobservable reasons -> reasons
    AwsSesReady -> error "Ready has no reasons"

reasonDetails :: AwsSesReadiness -> [String]
reasonDetails = map awsSesReadinessReasonDetail . nonEmptyToList . readinessReasons

reasonComponents :: AwsSesReadiness -> [AwsSesReadinessComponent]
reasonComponents = map awsSesReadinessReasonComponent . nonEmptyToList . readinessReasons

hasReason :: AwsSesReadinessComponent -> String -> AwsSesReadiness -> Bool
hasReason component detail readiness =
  any
    ( \item ->
        awsSesReadinessReasonComponent item == component
          && detail `contains` awsSesReadinessReasonDetail item
    )
    (nonEmptyToList (readinessReasons readiness))

isPending :: AwsSesReadiness -> Bool
isPending readiness =
  case readiness of
    AwsSesPending _ -> True
    _ -> False

isFailed :: AwsSesReadiness -> Bool
isFailed readiness =
  case readiness of
    AwsSesFailed _ -> True
    _ -> False

isUnobservable :: AwsSesReadiness -> Bool
isUnobservable readiness =
  case readiness of
    AwsSesUnobservable _ -> True
    _ -> False

popObservation :: IORef [AwsSesReadiness] -> IO AwsSesReadiness
popObservation ref = do
  observations <- readIORef ref
  case observations of
    [] -> error "readiness poll observed past the scripted fixture"
    next : remaining -> writeIORef ref remaining >> pure next

renderJson :: Value -> String
renderJson = BL8.unpack . encode

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
 where
  tails [] = [[]]
  tails value@(_ : rest) = value : tails rest
  prefixOf prefix value = take (length prefix) value == prefix

nonEmptyToList :: NonEmpty value -> [value]
nonEmptyToList (first :| rest) = first : rest

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result =
  case result of
    Left err -> error ("unexpected Left in SES readiness fixture: " ++ show err)
    Right value -> value
