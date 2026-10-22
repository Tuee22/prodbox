{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The canary's closed names and ownership predicate. The worker may plant
-- exactly three groups and one CNI-shaped interface. Cleanup uses this rule,
-- independently of the production EKS security-group rule.
module Prodbox.Lifecycle.AwsTestCanary
  ( TestCanaryBinding
  , mkTestCanaryBinding
  , testCanaryRunScope
  , testCanaryStackRunScope
  , testCanaryStackSubmission
  , TestVpcCanaryRequest
  , mkTestVpcCanaryRequest
  , testCanaryVpc
  , testCanarySubnet
  , testCanaryBinding
  , testVpcCanaryRequestWireText
  , testVpcCanaryRequestFromWireText
  , testCanaryClientToken
  , CanaryGroupShape (..)
  , canaryGroupName
  , canaryInventoryMaximumBytes
  , canaryInventoryMaximumRows
  , canaryInventoryMaximumTags
  , canaryFamilyPredicate
  , canaryGroupTags
  , canaryInterfaceTags
  , canaryInterfaceDescription
  , canaryVpcMarkerTags
  , canaryBindingFromVpcTags
  , isCanaryGroupCandidate
  , checkCanaryGroup
  , CanaryEc2Kind (..)
  , validateCanaryEc2Identifier
  , TestCanaryError (..)
  , renderTestCanaryError
  ) where

import Codec.Serialise (Serialise)
import Data.Char (isAlphaNum, isAscii)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)

data TestCanaryBinding = TestCanaryBinding !Text !Text !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

testCanaryRunScope :: TestCanaryBinding -> Text
testCanaryRunScope (TestCanaryBinding run _ _) = run

testCanaryStackRunScope :: TestCanaryBinding -> Text
testCanaryStackRunScope (TestCanaryBinding _ run _) = run

testCanaryStackSubmission :: TestCanaryBinding -> Text
testCanaryStackSubmission (TestCanaryBinding _ _ submission) = submission

data TestVpcCanaryRequest = TestVpcCanaryRequest !Text !Text !TestCanaryBinding
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

testCanaryVpc :: TestVpcCanaryRequest -> Text
testCanaryVpc (TestVpcCanaryRequest vpc _ _) = vpc

testCanarySubnet :: TestVpcCanaryRequest -> Text
testCanarySubnet (TestVpcCanaryRequest _ subnet _) = subnet

testCanaryBinding :: TestVpcCanaryRequest -> TestCanaryBinding
testCanaryBinding (TestVpcCanaryRequest _ _ binding) = binding

data CanaryGroupShape = InterfaceHeldGroup | MutualLeftGroup | MutualRightGroup
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data CanaryEc2Kind = CanaryVpc | CanarySubnet | CanarySecurityGroup | CanaryInterface
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data TestCanaryError
  = CanaryCoordinateInvalid !CanaryEc2Kind
  | CanaryRunScopeInvalid
  | CanaryStackRunScopeInvalid
  | CanaryStackSubmissionInvalid
  | CanaryWireMalformed
  | CanaryDuplicateTag
  | CanaryTagSetTooLarge
  | CanaryVpcMarkerIncomplete
  | CanaryGroupVpcMismatch
  | CanaryGroupNameMismatch
  | CanaryGroupTagMismatch !Text
  deriving stock (Eq, Show)

mkTestCanaryBinding :: Text -> Text -> Text -> Either TestCanaryError TestCanaryBinding
mkTestCanaryBinding run stackRun submission
  | not (validMarker run) = Left CanaryRunScopeInvalid
  | not (validMarker stackRun) = Left CanaryStackRunScopeInvalid
  | not (validMarker submission) = Left CanaryStackSubmissionInvalid
  | otherwise = Right (TestCanaryBinding run stackRun submission)
 where
  validMarker value =
    not (Text.null value)
      && value /= "unrecorded"
      && Text.length value <= 256
      && Text.all (\char -> isAscii char && (isAlphaNum char || char `elem` ("+-=._:/@" :: String))) value

mkTestVpcCanaryRequest
  :: Text -> Text -> TestCanaryBinding -> Either TestCanaryError TestVpcCanaryRequest
mkTestVpcCanaryRequest vpc subnet binding = do
  checkedVpc <- validateCanaryEc2Identifier CanaryVpc vpc
  checkedSubnet <- validateCanaryEc2Identifier CanarySubnet subnet
  checkedBinding <-
    mkTestCanaryBinding
      (testCanaryRunScope binding)
      (testCanaryStackRunScope binding)
      (testCanaryStackSubmission binding)
  Right (TestVpcCanaryRequest checkedVpc checkedSubnet checkedBinding)

validateCanaryEc2Identifier :: CanaryEc2Kind -> Text -> Either TestCanaryError Text
validateCanaryEc2Identifier kind value = case Text.stripPrefix prefix value of
  Just suffix
    | Text.length suffix `elem` [8, 17]
    , Text.all (`elem` ("0123456789abcdef" :: String)) suffix ->
        Right value
  _ -> Left (CanaryCoordinateInvalid kind)
 where
  prefix = case kind of
    CanaryVpc -> "vpc-"
    CanarySubnet -> "subnet-"
    CanarySecurityGroup -> "sg-"
    CanaryInterface -> "eni-"

testVpcCanaryRequestWireText :: TestVpcCanaryRequest -> Text
testVpcCanaryRequestWireText request =
  Text.intercalate
    ","
    [testCanaryVpc request, testCanarySubnet request, bindingWireText (testCanaryBinding request)]

testVpcCanaryRequestFromWireText :: Text -> Either TestCanaryError TestVpcCanaryRequest
testVpcCanaryRequestFromWireText raw
  | Text.length raw > 1024 = Left CanaryWireMalformed
  | otherwise = case Text.splitOn "," raw of
      [vpc, subnet, run, stackRun, submission] -> do
        binding <- mkTestCanaryBinding run stackRun submission
        mkTestVpcCanaryRequest vpc subnet binding
      _ -> Left CanaryWireMalformed

bindingWireText :: TestCanaryBinding -> Text
bindingWireText binding =
  Text.intercalate
    ","
    [testCanaryRunScope binding, testCanaryStackRunScope binding, testCanaryStackSubmission binding]

bindingDigest :: TestCanaryBinding -> Text
bindingDigest =
  TextEncoding.decodeUtf8
    . hexSha256
    . TextEncoding.encodeUtf8
    . ("prodbox-test-vpc-canary/v1," <>)
    . bindingWireText

testCanaryClientToken :: TestVpcCanaryRequest -> Text
testCanaryClientToken =
  TextEncoding.decodeUtf8
    . hexSha256
    . TextEncoding.encodeUtf8
    . ("prodbox-test-vpc-canary-interface/v1," <>)
    . testVpcCanaryRequestWireText

canaryInventoryMaximumBytes :: Int
canaryInventoryMaximumBytes = 1024 * 1024

canaryInventoryMaximumRows :: Int
canaryInventoryMaximumRows = 5000

canaryInventoryMaximumTags :: Int
canaryInventoryMaximumTags = 128

canaryFamilyPredicate :: Text
canaryFamilyPredicate = "v1:exact-vpc:dedicated-vpc-run-markers:exact-name-shape-and-owned-tags:held,left,right"

canaryNamePrefix :: Text
canaryNamePrefix = "prodbox-test-canary-"

shapeLabel :: CanaryGroupShape -> Text
shapeLabel shape = case shape of
  InterfaceHeldGroup -> "held"
  MutualLeftGroup -> "left"
  MutualRightGroup -> "right"

canaryGroupName :: TestCanaryBinding -> CanaryGroupShape -> Text
canaryGroupName binding shape = canaryNamePrefix <> bindingDigest binding <> "-" <> shapeLabel shape

canaryInterfaceDescription :: TestCanaryBinding -> Text
canaryInterfaceDescription binding = "aws-K8S-" <> canaryNamePrefix <> bindingDigest binding

canaryPurposeTag :: Text
canaryPurposeTag = "prodbox.io/test-canary"

canaryRunTag :: Text
canaryRunTag = "prodbox.io/test-canary-run"

canarySharedTags :: TestCanaryBinding -> [(Text, Text)]
canarySharedTags binding =
  [ ("prodbox.io/managed-by", "prodbox")
  , (canaryPurposeTag, "network-dependency-v1")
  , (canaryRunTag, testCanaryRunScope binding)
  , ("prodbox.io/run-scope", testCanaryStackRunScope binding)
  , ("prodbox.io/submission", testCanaryStackSubmission binding)
  ]

canaryGroupTags :: TestCanaryBinding -> CanaryGroupShape -> [(Text, Text)]
canaryGroupTags binding shape =
  canarySharedTags binding
    <> [("Name", canaryGroupName binding shape), ("prodbox.io/test-canary-shape", shapeLabel shape)]

canaryInterfaceTags :: TestCanaryBinding -> [(Text, Text)]
canaryInterfaceTags binding =
  canarySharedTags binding
    <> [ ("Name", canaryNamePrefix <> bindingDigest binding <> "-interface")
       , ("prodbox.io/test-canary-shape", "interface")
       , ("eks:eni:owner", "amazon-vpc-cni")
       ]

-- The creating stack marker is frozen separately from the VPC's mutable main
-- run marker, so a later ordinary reconcile cannot orphan a registered canary.
canaryVpcMarkerTags :: TestCanaryBinding -> [(Text, Text)]
canaryVpcMarkerTags binding =
  [ (canaryRunTag, testCanaryRunScope binding)
  , ("prodbox.io/test-canary-stack-run", testCanaryStackRunScope binding)
  , ("prodbox.io/test-canary-stack-submission", testCanaryStackSubmission binding)
  ]

canaryBindingFromVpcTags :: [(Text, Text)] -> Either TestCanaryError (Maybe TestCanaryBinding)
canaryBindingFromVpcTags tags = do
  indexed <- uniqueTags tags
  case map (`Map.lookup` indexed) keys of
    [Nothing, Nothing, Nothing] -> Right Nothing
    [Just run, Just stackRun, Just submission] -> Just <$> mkTestCanaryBinding run stackRun submission
    _ -> Left CanaryVpcMarkerIncomplete
 where
  keys = [canaryRunTag, "prodbox.io/test-canary-stack-run", "prodbox.io/test-canary-stack-submission"]

isCanaryGroupCandidate :: Text -> [(Text, Text)] -> Bool
isCanaryGroupCandidate name tags =
  canaryNamePrefix `Text.isPrefixOf` name
    || any (Text.isPrefixOf "prodbox.io/test-canary" . fst) tags

checkCanaryGroup
  :: TestCanaryBinding
  -> Text
  -> CanaryGroupShape
  -> Text
  -> Text
  -> [(Text, Text)]
  -> Either TestCanaryError ()
checkCanaryGroup binding expectedVpc shape observedVpc name tags = do
  _ <- validateCanaryEc2Identifier CanaryVpc expectedVpc
  if observedVpc == expectedVpc then Right () else Left CanaryGroupVpcMismatch
  if name == canaryGroupName binding shape then Right () else Left CanaryGroupNameMismatch
  indexed <- uniqueTags tags
  mapM_ (requireTag indexed) (canaryGroupTags binding shape)
 where
  requireTag indexed (key, value)
    | Map.lookup key indexed == Just value = Right ()
    | otherwise = Left (CanaryGroupTagMismatch key)

uniqueTags :: [(Text, Text)] -> Either TestCanaryError (Map.Map Text Text)
uniqueTags tags
  | length tags > canaryInventoryMaximumTags = Left CanaryTagSetTooLarge
  | length tags /= length (nub (map fst tags)) = Left CanaryDuplicateTag
  | otherwise = Right (Map.fromList tags)

renderTestCanaryError :: TestCanaryError -> Text
renderTestCanaryError err = case err of
  CanaryCoordinateInvalid kind -> "canary-coordinate-invalid:" <> Text.pack (show kind)
  CanaryRunScopeInvalid -> "canary-run-scope-invalid"
  CanaryStackRunScopeInvalid -> "canary-stack-run-scope-invalid"
  CanaryStackSubmissionInvalid -> "canary-stack-submission-invalid"
  CanaryWireMalformed -> "canary-wire-malformed"
  CanaryDuplicateTag -> "canary-duplicate-tag"
  CanaryTagSetTooLarge -> "canary-tag-set-too-large"
  CanaryVpcMarkerIncomplete -> "canary-vpc-marker-incomplete"
  CanaryGroupVpcMismatch -> "canary-group-vpc-mismatch"
  CanaryGroupNameMismatch -> "canary-group-name-mismatch"
  CanaryGroupTagMismatch key -> "canary-group-tag-mismatch:" <> key
