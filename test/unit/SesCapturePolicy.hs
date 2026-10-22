{-# LANGUAGE OverloadedStrings #-}

module SesCapturePolicy (sesCapturePolicySuite) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector qualified as Vector
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
import Prodbox.Lifecycle.CredentialProvisioner.ProviderRolePolicyOperationScope
  ( providerRolePolicyOperationRevision
  )
import Prodbox.Ses.CaptureLifecycle
import Prodbox.Settings.Coordinate (S3BucketName, mkS3BucketName)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

sesCapturePolicySuite :: SuiteBuilder ()
sesCapturePolicySuite = describe "Sprint 5.53 capture bucket policy and expiry" $ do
  it "grants no S3 access without an explicitly bound capture bucket" $ do
    let legacy = must (mkLifecycleProviderIamProgram fixtureRegion "123456789012" "fixture-provider-role")
        absent =
          must
            (mkScopedLifecycleProviderIamProgram fixtureRegion "123456789012" "fixture-provider-role" Nothing)
    s3Grants (rolePolicy legacy) `shouldBe` []
    rolePolicy absent `shouldBe` rolePolicy legacy
  it "binds every S3 grant to the exact capture bucket or its objects" $ do
    let grants = s3Grants (rolePolicy scopedProgram)
        bucketArn = "arn:aws:s3:::fixture-capture-mail"
    grants `shouldSatisfy` (not . null)
    map snd grants `shouldSatisfy` all (\resource -> resource `elem` [bucketArn, bucketArn <> "/*"])
    map fst grants `shouldContain` ["s3:GetLifecycleConfiguration"]
    map fst grants `shouldContain` ["s3:PutLifecycleConfiguration"]
    [resource | (action, resource) <- grants, action == "s3:GetObject"] `shouldBe` [bucketArn <> "/*"]
    map snd grants `shouldNotContain` ["*"]
    map snd grants `shouldNotContain` ["arn:aws:s3:::fixture-other-bucket/*"]
  it "rejects a wildcard or invalid bucket before a signed program can be built" $
    mapM_
      ( \bucket ->
          mkScopedLifecycleProviderIamParameters
            fixtureRegion
            "123456789012"
            "fixture-provider-role"
            (Just bucket)
            `shouldSatisfy` isLeft
      )
      [ "*"
      , "fixture-*"
      , ""
      , "https://fixture-capture-mail"
      , "fixture/capture"
      , "${prodbox:bound-ses-capture-bucket}"
      ]
  it "preserves historical parameter CBOR and round-trips the appended scoped constructor" $ do
    let legacy = must (mkLifecycleProviderIamParameters fixtureRegion "123456789012" "fixture-provider-role")
        parameters =
          must
            ( mkScopedLifecycleProviderIamParameters
                fixtureRegion
                "123456789012"
                "fixture-provider-role"
                (Just "fixture-capture-mail")
            )
        historical =
          LazyByteString.pack
            [ 132
            , 0
            , 108
            , 99
            , 97
            , 45
            , 99
            , 101
            , 110
            , 116
            , 114
            , 97
            , 108
            , 45
            , 49
            , 108
            , 49
            , 50
            , 51
            , 52
            , 53
            , 54
            , 55
            , 56
            , 57
            , 48
            , 49
            , 50
            , 117
            , 102
            , 105
            , 120
            , 116
            , 117
            , 114
            , 101
            , 45
            , 112
            , 114
            , 111
            , 118
            , 105
            , 100
            , 101
            , 114
            , 45
            , 114
            , 111
            , 108
            , 101
            ]
    serialise legacy `shouldBe` historical
    deserialiseOrFail historical `shouldBe` Right legacy
    deserialiseOrFail (serialise parameters) `shouldBe` Right parameters
    credentialIamParametersClass parameters `shouldBe` credentialIamParametersClass legacy
    rolePolicy (must (credentialIamParametersProgram parameters)) `shouldBe` rolePolicy scopedProgram
  it "revisions the operation namespace from the measured pre-landing policy" $
    providerRolePolicyOperationRevision
      `shouldNotBe` "209a4b7eef1842483983e994116c816ccd872070bdc210aa1f31f697fa7d34d7"
  it "recognizes the complete lifecycle independent of rule order and irrelevant response metadata" $ do
    classifyCaptureLifecycle (successful desiredCaptureLifecycle) `shouldBe` CaptureLifecycleCurrent
    let reordered = modifyRules reverse desiredCaptureLifecycle
        response = case reordered of
          Object fields ->
            Object
              (KeyMap.insert "TransitionDefaultMinimumObjectSize" (String "all_storage_classes_128K") fields)
          _ -> error "expected desired object"
    classifyCaptureLifecycle (successful response) `shouldBe` CaptureLifecycleCurrent
  it "requires all rules, their exact prefix, enabled state and expiration values" $
    mapM_
      (\policy -> classifyCaptureLifecycle (successful policy) `shouldBe` CaptureLifecycleDifferent)
      [ modifyRules (take 1) desiredCaptureLifecycle
      , modifyRules (const []) desiredCaptureLifecycle
      , modifyFirst "Status" (String "Disabled")
      , modifyFirst "Filter" (object ["Prefix" .= ("elsewhere/" :: Text)])
      , modifyFirst "Expiration" (object ["Days" .= (7 :: Int)])
      ]
  it "treats only the named AWS error as missing, never denied or unknown reads" $ do
    classifyCaptureLifecycle missing `shouldBe` CaptureLifecycleMissing
    let measured = missing {processStderr = "\naws: [ERROR]: " <> processStderr missing}
    classifyCaptureLifecycle measured `shouldBe` CaptureLifecycleMissing
    classifyCaptureLifecycle
      ( missing
          { processStderr =
              "aws: [ERROR]: An error occurred (AccessDenied) when calling the GetBucketLifecycleConfiguration operation: NoSuchLifecycleConfiguration"
          }
      )
      `shouldSatisfy` unobservable
    mapM_
      (\output -> classifyCaptureLifecycle output `shouldSatisfy` unobservable)
      [ ProcessOutput (ExitFailure 1) "" "AccessDenied: missing lifecycle configuration"
      , ProcessOutput (ExitFailure 1) "NoSuchLifecycleConfiguration" "connection lost"
      , ProcessOutput (ExitFailure 1) "" "unexpected NoSuchLifecycleConfiguration"
      ]
  it "refuses malformed or oversized lifecycle observations" $ do
    mapM_
      (\body -> classifyCaptureLifecycle (ProcessOutput ExitSuccess body "") `shouldSatisfy` unobservable)
      ["{", "{}", "[]", "{\"Rules\":false}", "{\"Rules\":[null]}", "{\"Rules\":[{\"ID\":7}]}"]
    let body = processStdout (successful desiredCaptureLifecycle)
        atBound = replicate (maximumCaptureLifecycleChars - length body) ' ' <> body
    classifyCaptureLifecycle (ProcessOutput ExitSuccess atBound "") `shouldBe` CaptureLifecycleCurrent
    classifyCaptureLifecycle (ProcessOutput ExitSuccess (' ' : atBound) "") `shouldSatisfy` unobservable
  it "expires mail and version residue without expiring the retained readiness marker" $ do
    sesCaptureMailPrefix `shouldBe` "inbound/"
    (sesCaptureMailPrefix `isPrefixOf` sesCaptureReadinessObjectKey) `shouldBe` False
    let rules = policyRules desiredCaptureLifecycle
    map (field "Filter") rules `shouldBe` replicate 2 (Just (object ["Prefix" .= sesCaptureMailPrefix]))
    map (field "Expiration") rules `shouldContain` [Just (object ["Days" .= (1 :: Int)])]
    map (field "Expiration") rules `shouldContain` [Just (object ["ExpiredObjectDeleteMarker" .= True])]
    map (field "NoncurrentVersionExpiration") rules
      `shouldContain` [Just (object ["NoncurrentDays" .= (1 :: Int)])]
  it "keeps an acknowledged write provisional when its independent read cannot observe the policy" $ do
    calls <- newIORef ([] :: [[String]])
    let run arguments = do
          modifyIORef' calls (<> [arguments])
          pure $ case arguments of
            "s3api" : "put-bucket-lifecycle-configuration" : _ -> ProcessOutput ExitSuccess "" ""
            "s3api" : "get-bucket-lifecycle-configuration" : _ -> ProcessOutput (ExitFailure 1) "" "AccessDenied"
            _ -> ProcessOutput (ExitFailure 1) "" "unexpected capture lifecycle request"
    applyCaptureLifecycle run captureBucket `shouldReturn` Right ()
    (observed, _) <- observeCaptureLifecycle run captureBucket
    observed `shouldSatisfy` unobservable
    (length <$> readIORef calls) `shouldReturn` 2
  it "recovers a response-lost write only from a new actual read, using the same fenced runner" $ do
    calls <- newIORef []
    stored <- newIORef Nothing
    let run arguments = do
          modifyIORef' calls (<> [arguments])
          case arguments of
            [ "s3api"
              , "get-bucket-lifecycle-configuration"
              , "--bucket"
              , "fixture-capture-mail"
              , "--output"
              , "json"
              ] -> do
                current <- readIORef stored
                pure (maybe missing successful current)
            [ "s3api"
              , "put-bucket-lifecycle-configuration"
              , "--bucket"
              , "fixture-capture-mail"
              , "--lifecycle-configuration"
              , policy
              , "--output"
              , "json"
              ] -> do
                case eitherDecodeStrict' (encodeUtf8 (Text.pack policy)) of
                  Left _ -> pure (ProcessOutput (ExitFailure 1) "" "bad lifecycle JSON")
                  Right value -> do
                    writeIORef stored (Just value)
                    pure (ProcessOutput (ExitFailure 1) "" "response lost after effect")
            _ -> pure (ProcessOutput (ExitFailure 1) "" "unexpected capture lifecycle request")
    (before, _) <- observeCaptureLifecycle run captureBucket
    before `shouldBe` CaptureLifecycleMissing
    applyCaptureLifecycle run captureBucket >>= (`shouldSatisfy` isLeft)
    (after, actual) <- observeCaptureLifecycle run captureBucket
    after `shouldBe` CaptureLifecycleCurrent
    actual `shouldBe` successful desiredCaptureLifecycle
    recorded <- readIORef calls
    length recorded `shouldBe` 3
    length [() | "s3api" : "put-bucket-lifecycle-configuration" : _ <- recorded] `shouldBe` 1

fixtureRegion :: Text
fixtureRegion = Text.pack (fixtureAwsRegion FixtureCaCentral1)

scopedProgram :: CredentialIamProgram
scopedProgram =
  must
    ( mkScopedLifecycleProviderIamProgram
        fixtureRegion
        "123456789012"
        "fixture-provider-role"
        (Just "fixture-capture-mail")
    )

captureBucket :: S3BucketName
captureBucket = must (mkS3BucketName "fixture-capture-mail")

rolePolicy :: CredentialIamProgram -> Value
rolePolicy program =
  must
    ( eitherDecodeStrict'
        (encodeUtf8 (maybe (error "role policy missing") id (credentialIamProgramRolePolicyDocument program)))
    )

s3Grants :: Value -> [(Text, Text)]
s3Grants policy =
  sort
    [ (action, resource)
    | statement <- policyRulesFor "Statement" policy
    , Just (Array actions) <- [field "Action" statement]
    , String action <- Vector.toList actions
    , "s3:" `Text.isPrefixOf` action
    , Just (Array resources) <- [field "Resource" statement]
    , String resource <- Vector.toList resources
    ]

field :: Key -> Value -> Maybe Value
field key value = case value of
  Object fields -> KeyMap.lookup key fields
  _ -> Nothing

policyRulesFor :: Key -> Value -> [Value]
policyRulesFor key value = case field key value of
  Just (Array rules) -> Vector.toList rules
  _ -> []

policyRules :: Value -> [Value]
policyRules = policyRulesFor "Rules"

modifyRules :: ([Value] -> [Value]) -> Value -> Value
modifyRules change value = case value of
  Object fields -> Object (KeyMap.insert "Rules" (Array (Vector.fromList (change (policyRules value)))) fields)
  _ -> error "expected policy object"

modifyFirst :: Key -> Value -> Value
modifyFirst key replacement = modifyRules change desiredCaptureLifecycle
 where
  change (Object fields : rest) = Object (KeyMap.insert key replacement fields) : rest
  change _ = error "expected first policy rule"

successful :: Value -> ProcessOutput
successful value = ProcessOutput ExitSuccess (Text.unpack (decodeUtf8 (LazyByteString.toStrict (encode value)))) ""

missing :: ProcessOutput
missing =
  ProcessOutput
    (ExitFailure 255)
    ""
    "An error occurred (NoSuchLifecycleConfiguration) when calling the GetBucketLifecycleConfiguration operation: The lifecycle configuration does not exist"

unobservable :: CaptureLifecycleObservation -> Bool
unobservable observation = case observation of
  CaptureLifecycleUnobservable _ -> True
  _ -> False

must :: (Show err) => Either err value -> value
must = either (error . show) id
