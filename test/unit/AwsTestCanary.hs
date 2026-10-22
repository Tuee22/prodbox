{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsTestCanary (awsTestCanarySuite) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Monad (forM_)
import Data.Aeson (Value (Null), encode, object, toJSON, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.Lifecycle.AwsNetworkDependents
import Prodbox.Lifecycle.AwsNetworkFamily (AwsNetworkFamily (TestCanarySecurityGroups))
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

awsTestCanarySuite :: SuiteBuilder ()
awsTestCanarySuite = describe "Sprint 5.59 closed test-VPC canary predicate" $ do
  it "round-trips its bounded public request through the wire and durable codec" $ do
    testVpcCanaryRequestFromWireText (testVpcCanaryRequestWireText request) `shouldBe` Right request
    deserialiseOrFail (serialise request) `shouldBe` Right request
  it "rejects malformed, extra-field and oversized wire inputs" $
    forM_
      [ ""
      , testVpcCanaryRequestWireText request <> ",extra"
      , Text.replace "subnet-0123456789abcdef0" "" (testVpcCanaryRequestWireText request)
      , Text.replicate 1025 "x"
      ]
      (\raw -> testVpcCanaryRequestFromWireText raw `shouldSatisfy` isLeft)
  forM_ [minBound .. maxBound] $ \kind ->
    it ("validates exact EC2 identifier lengths and alphabets for " ++ show kind) $ do
      let prefix = case kind of
            CanaryVpc -> "vpc-"
            CanarySubnet -> "subnet-"
            CanarySecurityGroup -> "sg-"
            CanaryInterface -> "eni-"
      forM_ ["1234abcd", "0123456789abcdef0"] $ \suffix ->
        validateCanaryEc2Identifier kind (prefix <> suffix) `shouldBe` Right (prefix <> suffix)
      forM_ ["1", "123456789", "123456789012345678", "1234ABCD", "1234567z", "1234567\n"] $ \suffix ->
        validateCanaryEc2Identifier kind (prefix <> suffix) `shouldBe` Left (CanaryCoordinateInvalid kind)
      validateCanaryEc2Identifier kind "other-1234abcd" `shouldBe` Left (CanaryCoordinateInvalid kind)
  it "requires three independently valid recorded markers"
    $ forM_
      ["", "unrecorded", Text.replicate 257 "x", "contains space", "comma,value", "unicode-λ", "a\nb"]
    $ \invalid -> do
      mkTestCanaryBinding invalid "stack/run" "create/submission" `shouldBe` Left CanaryRunScopeInvalid
      mkTestCanaryBinding "cleanup/run" invalid "create/submission"
        `shouldBe` Left CanaryStackRunScopeInvalid
      mkTestCanaryBinding "cleanup/run" "stack/run" invalid `shouldBe` Left CanaryStackSubmissionInvalid
  it "gives the interface a stable 256-bit client token bound to all public request coordinates" $ do
    let token = testCanaryClientToken request
        changedVpc = must (mkTestVpcCanaryRequest "vpc-1234abcd" subnet binding)
        changedSubnet = must (mkTestVpcCanaryRequest vpc "subnet-1234abcd" binding)
        changedRun = must (mkTestCanaryBinding "cleanup/other" "stack/run" "create/submission")
        changedBinding = must (mkTestVpcCanaryRequest vpc subnet changedRun)
    Text.length token `shouldBe` 64
    token `shouldSatisfy` Text.all (`elem` ("0123456789abcdef" :: String))
    testCanaryClientToken request `shouldBe` token
    forM_ [changedVpc, changedSubnet, changedBinding] $ \changed ->
      testCanaryClientToken changed `shouldNotBe` token
  it "declares three distinct exact group names within the provider name bound" $ do
    let names = map (canaryGroupName binding) [minBound .. maxBound]
    length (nub names) `shouldBe` 3
    forM_ names $ \name -> do
      name `shouldSatisfy` Text.isPrefixOf "prodbox-test-canary-"
      Text.length name `shouldSatisfy` (<= 255)
  forM_ [minBound .. maxBound] $ \shape -> describe (show shape) $ do
    it "admits only the exact name, VPC and owned marker set while accepting unrelated extra tags" $ do
      let name = canaryGroupName binding shape
          tags = canaryGroupTags binding shape
      checkCanaryGroup binding vpc shape vpc name tags `shouldBe` Right ()
      checkCanaryGroup binding vpc shape vpc name (tags ++ [("foreign-label", "retained")])
        `shouldBe` Right ()
      checkCanaryGroup binding vpc shape "vpc-1234abcd" name tags `shouldBe` Left CanaryGroupVpcMismatch
      checkCanaryGroup binding vpc shape vpc (name <> "-other") tags
        `shouldBe` Left CanaryGroupNameMismatch
    it "refuses each missing or mismatched owned tag independently" $ do
      let name = canaryGroupName binding shape
          tags = canaryGroupTags binding shape
      forM_ tags $ \(key, _) -> do
        checkCanaryGroup binding vpc shape vpc name (filter ((/= key) . fst) tags)
          `shouldBe` Left (CanaryGroupTagMismatch key)
        checkCanaryGroup binding vpc shape vpc name (map (replaceTag key "wrong-run-or-shape") tags)
          `shouldBe` Left (CanaryGroupTagMismatch key)
    it "refuses ambiguous duplicate tags even if the duplicate repeats the expected value" $ do
      let name = canaryGroupName binding shape
          tags = canaryGroupTags binding shape
      checkCanaryGroup binding vpc shape vpc name (tags ++ [("prodbox.io/managed-by", "prodbox")])
        `shouldBe` Left CanaryDuplicateTag
  it "freezes the creating stack markers on the VPC independently of a later main-marker refresh" $ do
    let markers = canaryVpcMarkerTags binding
    canaryBindingFromVpcTags markers `shouldBe` Right (Just binding)
    canaryBindingFromVpcTags
      (markers ++ [("prodbox.io/run-scope", "later-stack/run"), ("Name", "aws-test-vpc")])
      `shouldBe` Right (Just binding)
    canaryBindingFromVpcTags [("Name", "aws-test-vpc")] `shouldBe` Right Nothing
    forM_ markers $ \(key, _) ->
      canaryBindingFromVpcTags (filter ((/= key) . fst) markers) `shouldBe` Left CanaryVpcMarkerIncomplete
    canaryBindingFromVpcTags (markers ++ [("prodbox.io/test-canary-run", "cleanup/run")])
      `shouldBe` Left CanaryDuplicateTag
  it "keeps partial marks, neighboring names and unknown shapes visible as candidates" $ do
    isCanaryGroupCandidate "aws-test-ssh" [] `shouldBe` False
    isCanaryGroupCandidate "prodbox-test-canary-neighbor" [] `shouldBe` True
    isCanaryGroupCandidate
      "unexpected-name"
      [("prodbox.io/test-canary-shape", "outside-the-closed-list")]
      `shouldBe` True
    isCanaryGroupCandidate "unexpected-name" [("prodbox.io/test-canary-run", "different-run")]
      `shouldBe` True
  it "marks the unattached interface as CNI-shaped without assigning it to an EKS cluster" $ do
    canaryInterfaceDescription binding `shouldSatisfy` Text.isPrefixOf "aws-K8S-"
    lookup "eks:eni:owner" (canaryInterfaceTags binding) `shouldBe` Just "amazon-vpc-cni"
    lookup "cluster.k8s.amazonaws.com/name" (canaryInterfaceTags binding) `shouldBe` Nothing
    lookup "prodbox.io/test-canary-run" (canaryInterfaceTags binding) `shouldBe` Just "cleanup/run"
  it "bounds tag-set decoding before duplicate detection" $
    canaryBindingFromVpcTags [(Text.pack (show number), "value") | number <- [1 :: Int .. 129]]
      `shouldBe` Left CanaryTagSetTooLarge
  it "observes exactly the three canary group shapes through the native read boundary" $ do
    (observed, calls) <- observeCanary FixtureFamily completeVpc completeGroups
    observed
      `shouldBe` Right
        [Dependent DependentSecurityGroup (fixtureGroupId shape) Admitted | shape <- [minBound .. maxBound]]
    length calls `shouldBe` 2
    calls `shouldSatisfy` all (\args -> "--output" `elem` args && "json" `elem` args)
  it "adds only the canary decisions to a VPC repair while leaving the EKS group rule unchanged" $ do
    (observed, _) <- observeCanary FixtureVpcRepair completeVpc completeGroups
    observed
      `shouldBe` Right
        [Dependent DependentSecurityGroup (fixtureGroupId shape) Admitted | shape <- [minBound .. maxBound]]
    let target = must (mkDependentsTarget vpc Nothing)
        row =
          SecurityGroupRow
            (fixtureGroupId InterfaceHeldGroup)
            vpc
            (canaryGroupName binding InterfaceHeldGroup)
            Nothing
    classifySecurityGroup target row
      `shouldBe` Just
        ( Dependent
            DependentSecurityGroup
            (fixtureGroupId InterfaceHeldGroup)
            (NotAdmitted "not the group EKS created for this stack's cluster")
        )
  it "keeps a group of another run or an unknown shape as a visible refusal" $ do
    let another = must (mkTestCanaryBinding "cleanup/other" "stack/run" "create/submission")
        other = fixtureGroup another InterfaceHeldGroup vpc
        unknown =
          object
            [ "id" .= ("sg-00000009" :: Text)
            , "vpc" .= vpc
            , "name" .= ("unknown-shape" :: Text)
            , "tags" .= tagsValue [("prodbox.io/test-canary-shape", "outside-list")]
            ]
    (observed, _) <- observeCanary FixtureFamily completeVpc (toJSON [other, unknown])
    case observed of
      Right rows -> do
        length rows `shouldBe` 2
        rows `shouldSatisfy` all notAdmitted
      Left err -> expectationFailure (Text.unpack err)
  it "never admits a group outside the exact VPC even when the listing ignores its filter" $ do
    (observed, _) <-
      observeCanary
        FixtureFamily
        completeVpc
        (toJSON [fixtureGroup binding InterfaceHeldGroup "vpc-1234abcd"])
    observed
      `shouldBe` Right
        [ Dependent
            DependentSecurityGroup
            (fixtureGroupId InterfaceHeldGroup)
            (NotAdmitted "canary-group-vpc-mismatch")
        ]
  it "refuses missing projection fields and duplicate group identities" $ do
    let missingTags =
          object
            [ "id" .= fixtureGroupId InterfaceHeldGroup
            , "vpc" .= vpc
            , "name" .= canaryGroupName binding InterfaceHeldGroup
            ]
        duplicate = fixtureGroup binding InterfaceHeldGroup vpc
    forM_ [toJSON [missingTags], toJSON [duplicate, duplicate]] $ \groups -> do
      (observed, _) <- observeCanary FixtureFamily completeVpc groups
      observed `shouldSatisfy` isLeft
  it "treats an explicitly null optional tag projection as untagged rather than an unanswered read" $ do
    let ordinary =
          object
            ["id" .= ("sg-00000009" :: Text), "vpc" .= vpc, "name" .= ("default" :: Text), "tags" .= Null]
    (observed, _) <- observeCanary FixtureFamily (fixtureVpc vpc []) (toJSON [ordinary])
    observed `shouldBe` Right []
  it "refuses a wrong, ambiguous, or unowned VPC before admitting any group" $
    forM_
      [ fixtureVpc "vpc-1234abcd" (canaryVpcMarkerTags binding)
      , toJSON
          [vpcRow vpc (canaryVpcMarkerTags binding), vpcRow "vpc-1234abcd" (canaryVpcMarkerTags binding)]
      , toJSON [object ["id" .= vpc, "tags" .= tagsValue (canaryVpcMarkerTags binding)]]
      ]
      ( \vpcs -> do
          (observed, _) <- observeCanary FixtureFamily vpcs completeGroups
          observed `shouldSatisfy` isLeft
      )
  it "keeps candidates visible when VPC markers are absent or incomplete" $
    forM_ [[], take 1 (canaryVpcMarkerTags binding)] $ \markers -> do
      (observed, _) <- observeCanary FixtureFamily (fixtureVpc vpc markers) completeGroups
      case observed of
        Right rows -> do
          length rows `shouldBe` 3
          rows `shouldSatisfy` all notAdmitted
        Left err -> expectationFailure (Text.unpack err)
  it "proves an empty candidate superset even when stale VPC markers cannot authorize mutations" $ do
    (observed, _) <-
      observeCanary
        FixtureFamily
        (fixtureVpc vpc (take 1 (canaryVpcMarkerTags binding)))
        (toJSON ([] :: [Value]))
    observed `shouldBe` Right []
  it "does not erase candidates from a listing that contradicts an absent VPC" $ do
    (observed, _) <- observeCanary FixtureFamily (toJSON ([] :: [Value])) completeGroups
    observed `shouldSatisfy` isLeft
  it "refuses duplicated tags before classifying a group" $ do
    let doubled =
          object
            [ "id" .= fixtureGroupId InterfaceHeldGroup
            , "vpc" .= vpc
            , "name" .= canaryGroupName binding InterfaceHeldGroup
            , "tags"
                .= tagsValue (canaryGroupTags binding InterfaceHeldGroup ++ [("prodbox.io/managed-by", "prodbox")])
            ]
    (observed, _) <- observeCanary FixtureFamily completeVpc (toJSON [doubled])
    observed `shouldSatisfy` isLeft
  it "accepts the complete 5000-row bound and refuses the next row" $ do
    (accepted, _) <- observeCanary FixtureFamily completeVpc (ordinaryGroups 5000)
    accepted `shouldBe` Right []
    (refused, _) <- observeCanary FixtureFamily completeVpc (ordinaryGroups 5001)
    refused `shouldBe` Left "canary group listing exceeds its row bound"
  it "bounds raw UTF-8 bytes before JSON decoding" $
    forM_ [Text.replicate 1048576 "x", Text.replicate 524288 "λ"] $ \payload -> do
      (observed, _) <- observeCanary FixtureFamily completeVpc (toJSON payload)
      observed `shouldBe` Left "canary inventory exceeds its 1 MiB read bound"

binding :: TestCanaryBinding
binding = must (mkTestCanaryBinding "cleanup/run" "stack/run" "create/submission")

vpc :: Text
vpc = "vpc-0123456789abcdef0"

subnet :: Text
subnet = "subnet-0123456789abcdef0"

request :: TestVpcCanaryRequest
request = must (mkTestVpcCanaryRequest vpc subnet binding)

replaceTag :: Text -> Text -> (Text, Text) -> (Text, Text)
replaceTag wanted value pair@(key, _)
  | key == wanted = (key, value)
  | otherwise = pair

must :: (Show error) => Either error value -> value
must result = case result of
  Left err -> error (show err)
  Right value -> value

data FixtureObservation = FixtureFamily | FixtureVpcRepair

observeCanary :: FixtureObservation -> Value -> Value -> IO (Either Text [Dependent], [[String]])
observeCanary route vpcs groups = do
  calls <- newIORef []
  let runner args = do
        modifyIORef' calls (<> [args])
        pure $ case args of
          "ec2" : "describe-vpcs" : _ -> success vpcs
          "ec2" : "describe-security-groups" : _ -> success groups
          "ec2" : "describe-network-interfaces" : _ -> success (toJSON ([] :: [Value]))
          _ -> ProcessOutput (ExitFailure 64) "" "unplanned child"
      target = must (mkDependentsTarget vpc Nothing)
  observed <- case route of
    FixtureFamily -> observeNetworkFamily TestCanarySecurityGroups runner target
    FixtureVpcRepair -> observeNetworkDependents runner target
  issued <- readIORef calls
  pure (observed, issued)
 where
  success value =
    ProcessOutput
      ExitSuccess
      (Text.unpack (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode value))))
      ""

tagsValue :: [(Text, Text)] -> Value
tagsValue tags = toJSON [object ["Key" .= key, "Value" .= value] | (key, value) <- tags]

vpcRow :: Text -> [(Text, Text)] -> Value
vpcRow identity markers =
  object
    [ "id" .= identity
    , "tags" .= tagsValue ([("Name", "aws-test-vpc"), ("prodbox.io/managed-by", "prodbox")] ++ markers)
    ]

fixtureVpc :: Text -> [(Text, Text)] -> Value
fixtureVpc identity markers = toJSON [vpcRow identity markers]

completeVpc :: Value
completeVpc = fixtureVpc vpc (canaryVpcMarkerTags binding)

fixtureGroupId :: CanaryGroupShape -> Text
fixtureGroupId shape = case shape of
  InterfaceHeldGroup -> "sg-00000001"
  MutualLeftGroup -> "sg-00000002"
  MutualRightGroup -> "sg-00000003"

fixtureGroup :: TestCanaryBinding -> CanaryGroupShape -> Text -> Value
fixtureGroup owned shape observedVpc =
  object
    [ "id" .= fixtureGroupId shape
    , "vpc" .= observedVpc
    , "name" .= canaryGroupName owned shape
    , "tags" .= tagsValue (canaryGroupTags owned shape)
    ]

completeGroups :: Value
completeGroups = toJSON [fixtureGroup binding shape vpc | shape <- [minBound .. maxBound]]

notAdmitted :: Dependent -> Bool
notAdmitted row = case dependentDisposition row of
  NotAdmitted _ -> True
  Admitted -> False
  HeldByService _ -> False

ordinaryGroups :: Int -> Value
ordinaryGroups count =
  toJSON
    [ object
        [ "id" .= ("sg-" <> Text.justifyRight 8 '0' (Text.pack (showHex index "")))
        , "vpc" .= vpc
        , "name" .= ("ordinary-fixture" :: Text)
        , "tags" .= Null
        ]
    | index <- [1 .. count]
    ]
