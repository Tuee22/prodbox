{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The operator-authored AWS resource and network envelope.
--
-- The Dhall surface carries this type under @aws_substrate.profile@.  Its
-- constructor is private and its decoder crosses 'mkAwsSubstrateProfile', so a
-- present profile is already narrowed.  Absence is represented by the outer
-- 'Maybe' in 'Prodbox.Settings.AwsSubstrateSection'; there is no compiled
-- production envelope.
module Prodbox.Settings.AwsSubstrateProfile
  ( AwsSubstrateProfile
  , AwsSubstrateProfileInput (..)
  , AwsSubstrateProfileError (..)
  , AwsEbsVolumeType
  , mkAwsSubstrateProfile
  , mkAwsEbsVolumeType
  , awsEbsVolumeTypeText
  , awsSubstrateOperatorCidr
  , awsSubstrateStaticEbsVolumeType
  , awsEksStackConfiguration
  , awsTestStackConfiguration
  , renderAwsSubstrateProfileError
  )
where

import Codec.Serialise (Serialise)
import Data.Bits (shiftL, (.&.))
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( Decoder (..)
  , FromDhall (..)
  , InterpretOptions (fieldModifier)
  , ToDhall (..)
  , defaultInterpretOptions
  , extractError
  , genericAutoWith
  , genericToDhallWith
  )
import Dhall.Marshal.Decode (fromMonadic, toMonadic)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | The exact authored Dhall record.  It is deliberately a wide DTO: only
-- 'AwsSubstrateProfile' crosses into provider or AWS request construction.
data AwsSubstrateProfileInput = AwsSubstrateProfileInput
  { operator_cidr :: !Text
  , eks_node_instance_type :: !Text
  , eks_node_disk_size_gib :: !Natural
  , eks_node_min_size :: !Natural
  , eks_node_max_size :: !Natural
  , aws_test_instance_types :: ![Text]
  , aws_test_root_volume_types :: ![Text]
  , aws_test_root_volume_sizes_gib :: ![Natural]
  , static_ebs_volume_type :: !Text
  , eks_vpc_cidr :: !Text
  , eks_subnet_cidrs :: ![Text]
  , aws_test_vpc_cidr :: !Text
  , aws_test_subnet_cidrs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromDhall, ToDhall)

newtype AwsEbsVolumeType = AwsEbsVolumeType {awsEbsVolumeTypeText :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsSubstrateProfile = AwsSubstrateProfile
  { internalOperatorCidr :: !Text
  , internalEksNodeInstanceType :: !Text
  , internalEksNodeDiskSizeGib :: !Natural
  , internalEksNodeMinSize :: !Natural
  , internalEksNodeMaxSize :: !Natural
  , internalAwsTestInstanceTypes :: ![Text]
  , internalAwsTestRootVolumeTypes :: ![Text]
  , internalAwsTestRootVolumeSizesGib :: ![Natural]
  , internalStaticEbsVolumeType :: !Text
  , internalEksVpcCidr :: !Text
  , internalEksSubnetCidrs :: ![Text]
  , internalAwsTestVpcCidr :: !Text
  , internalAwsTestSubnetCidrs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsSubstrateProfileError
  = AwsSubstrateProfileFieldEmpty !Text
  | AwsSubstrateProfileFieldZero !Text
  | AwsSubstrateProfileListLength !Text !Int !Int
  | AwsSubstrateProfileMalformedCidr !Text
  | AwsSubstrateProfileHostCidrForNetwork !Text
  | AwsSubstrateProfileUnsupportedVolumeType !Text
  | AwsSubstrateProfileDesiredBelowMinimum !Natural !Natural
  | AwsSubstrateProfileMaximumBelowDesired !Natural !Natural
  deriving stock (Eq, Show)

instance FromDhall AwsSubstrateProfile where
  autoWith _ =
    narrowingDecoder
      (genericAutoWith defaultInterpretOptions)
      mkAwsSubstrateProfile

instance ToDhall AwsSubstrateProfile where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = profileFieldName}

narrowingDecoder
  :: Decoder input
  -> (input -> Either AwsSubstrateProfileError output)
  -> Decoder output
narrowingDecoder base narrow =
  base
    { extract = \expression -> fromMonadic $ do
        wide <- toMonadic (extract base expression)
        case narrow wide of
          Right narrowed -> pure narrowed
          Left err -> toMonadic (extractError (Text.pack (renderAwsSubstrateProfileError err)))
    }

mkAwsSubstrateProfile
  :: AwsSubstrateProfileInput -> Either AwsSubstrateProfileError AwsSubstrateProfile
mkAwsSubstrateProfile input = do
  operator <- validatedHostCidr "operator_cidr" (operator_cidr input)
  eksInstance <- validatedToken "eks_node_instance_type" (eks_node_instance_type input)
  eksDisk <- positive "eks_node_disk_size_gib" (eks_node_disk_size_gib input)
  eksMinimum <- positive "eks_node_min_size" (eks_node_min_size input)
  eksMaximum <- positive "eks_node_max_size" (eks_node_max_size input)
  testInstances <- exactList 3 "aws_test_instance_types" (aws_test_instance_types input)
  validatedTestInstances <- traverse (validatedToken "aws_test_instance_types") testInstances
  testVolumeTypeTexts <-
    exactList 3 "aws_test_root_volume_types" (aws_test_root_volume_types input)
  testVolumeTypes <- traverse mkAwsEbsVolumeType testVolumeTypeTexts
  testVolumeSizes <-
    exactList 3 "aws_test_root_volume_sizes_gib" (aws_test_root_volume_sizes_gib input)
      >>= traverse (positive "aws_test_root_volume_sizes_gib")
  staticVolumeType <- mkAwsEbsVolumeType (static_ebs_volume_type input)
  eksVpc <- validatedNetworkCidr "eks_vpc_cidr" (eks_vpc_cidr input)
  eksSubnets <- exactList 2 "eks_subnet_cidrs" (eks_subnet_cidrs input)
  validatedEksSubnets <- traverse (validatedNetworkCidr "eks_subnet_cidrs") eksSubnets
  testVpc <- validatedNetworkCidr "aws_test_vpc_cidr" (aws_test_vpc_cidr input)
  testSubnets <- exactList 3 "aws_test_subnet_cidrs" (aws_test_subnet_cidrs input)
  validatedTestSubnets <- traverse (validatedNetworkCidr "aws_test_subnet_cidrs") testSubnets
  pure
    AwsSubstrateProfile
      { internalOperatorCidr = operator
      , internalEksNodeInstanceType = eksInstance
      , internalEksNodeDiskSizeGib = eksDisk
      , internalEksNodeMinSize = eksMinimum
      , internalEksNodeMaxSize = eksMaximum
      , internalAwsTestInstanceTypes = validatedTestInstances
      , internalAwsTestRootVolumeTypes = map awsEbsVolumeTypeText testVolumeTypes
      , internalAwsTestRootVolumeSizesGib = testVolumeSizes
      , internalStaticEbsVolumeType = awsEbsVolumeTypeText staticVolumeType
      , internalEksVpcCidr = eksVpc
      , internalEksSubnetCidrs = validatedEksSubnets
      , internalAwsTestVpcCidr = testVpc
      , internalAwsTestSubnetCidrs = validatedTestSubnets
      }

mkAwsEbsVolumeType :: Text -> Either AwsSubstrateProfileError AwsEbsVolumeType
mkAwsEbsVolumeType raw
  | normalized `elem` supported = Right (AwsEbsVolumeType normalized)
  | otherwise = Left (AwsSubstrateProfileUnsupportedVolumeType raw)
 where
  normalized = Text.toLower (Text.strip raw)
  supported = ["gp2", "gp3", "io1", "io2", "st1", "sc1", "standard"]

awsSubstrateOperatorCidr :: AwsSubstrateProfile -> Text
awsSubstrateOperatorCidr = internalOperatorCidr

awsSubstrateStaticEbsVolumeType :: AwsSubstrateProfile -> AwsEbsVolumeType
awsSubstrateStaticEbsVolumeType = AwsEbsVolumeType . internalStaticEbsVolumeType

-- | Compile every EKS-program input.  The desired count comes from the
-- committed @cluster_topology.Eks.node_group_size@ wire; the profile supplies
-- the authored lower and upper bounds.  This makes the formerly ignored
-- topology field load-bearing without duplicating the desired value.
awsEksStackConfiguration
  :: AwsSubstrateProfile
  -> Natural
  -> Either AwsSubstrateProfileError [(String, String)]
awsEksStackConfiguration profile desired = do
  desired' <- positive "cluster_topology.Eks.node_group_size" desired
  if desired' < internalEksNodeMinSize profile
    then Left (AwsSubstrateProfileDesiredBelowMinimum desired' (internalEksNodeMinSize profile))
    else Right ()
  if internalEksNodeMaxSize profile < desired'
    then Left (AwsSubstrateProfileMaximumBelowDesired (internalEksNodeMaxSize profile) desired')
    else Right ()
  case internalEksSubnetCidrs profile of
    [subnet0, subnet1] ->
      Right
        [ ("operatorCidr", Text.unpack (internalOperatorCidr profile))
        , ("nodeInstanceType", Text.unpack (internalEksNodeInstanceType profile))
        , ("nodeDiskSizeGiB", show (internalEksNodeDiskSizeGib profile))
        , ("nodeDesiredSize", show desired')
        , ("nodeMinSize", show (internalEksNodeMinSize profile))
        , ("nodeMaxSize", show (internalEksNodeMaxSize profile))
        , ("vpcCidr", Text.unpack (internalEksVpcCidr profile))
        , ("subnet0Cidr", Text.unpack subnet0)
        , ("subnet1Cidr", Text.unpack subnet1)
        ]
    subnets ->
      Left (AwsSubstrateProfileListLength "eks_subnet_cidrs" 2 (length subnets))

awsTestStackConfiguration
  :: AwsSubstrateProfile
  -> Either AwsSubstrateProfileError [(String, String)]
awsTestStackConfiguration profile =
  case ( internalAwsTestInstanceTypes profile
       , internalAwsTestRootVolumeTypes profile
       , internalAwsTestRootVolumeSizesGib profile
       , internalAwsTestSubnetCidrs profile
       ) of
    ( [instance0, instance1, instance2]
      , [volumeType0, volumeType1, volumeType2]
      , [volumeSize0, volumeSize1, volumeSize2]
      , [subnet0, subnet1, subnet2]
      ) ->
        Right
          [ ("operatorCidr", Text.unpack (internalOperatorCidr profile))
          , ("node0InstanceType", Text.unpack instance0)
          , ("node1InstanceType", Text.unpack instance1)
          , ("node2InstanceType", Text.unpack instance2)
          , ("node0RootVolumeType", Text.unpack volumeType0)
          , ("node1RootVolumeType", Text.unpack volumeType1)
          , ("node2RootVolumeType", Text.unpack volumeType2)
          , ("node0RootVolumeSizeGiB", show volumeSize0)
          , ("node1RootVolumeSizeGiB", show volumeSize1)
          , ("node2RootVolumeSizeGiB", show volumeSize2)
          , ("vpcCidr", Text.unpack (internalAwsTestVpcCidr profile))
          , ("subnet0Cidr", Text.unpack subnet0)
          , ("subnet1Cidr", Text.unpack subnet1)
          , ("subnet2Cidr", Text.unpack subnet2)
          ]
    (instances, volumeTypes, volumeSizes, subnets)
      | length instances /= 3 ->
          Left (AwsSubstrateProfileListLength "aws_test_instance_types" 3 (length instances))
      | length volumeTypes /= 3 ->
          Left (AwsSubstrateProfileListLength "aws_test_root_volume_types" 3 (length volumeTypes))
      | length volumeSizes /= 3 ->
          Left (AwsSubstrateProfileListLength "aws_test_root_volume_sizes_gib" 3 (length volumeSizes))
      | otherwise ->
          Left (AwsSubstrateProfileListLength "aws_test_subnet_cidrs" 3 (length subnets))

profileFieldName :: Text -> Text
profileFieldName fieldName = case fieldName of
  "internalOperatorCidr" -> "operator_cidr"
  "internalEksNodeInstanceType" -> "eks_node_instance_type"
  "internalEksNodeDiskSizeGib" -> "eks_node_disk_size_gib"
  "internalEksNodeMinSize" -> "eks_node_min_size"
  "internalEksNodeMaxSize" -> "eks_node_max_size"
  "internalAwsTestInstanceTypes" -> "aws_test_instance_types"
  "internalAwsTestRootVolumeTypes" -> "aws_test_root_volume_types"
  "internalAwsTestRootVolumeSizesGib" -> "aws_test_root_volume_sizes_gib"
  "internalStaticEbsVolumeType" -> "static_ebs_volume_type"
  "internalEksVpcCidr" -> "eks_vpc_cidr"
  "internalEksSubnetCidrs" -> "eks_subnet_cidrs"
  "internalAwsTestVpcCidr" -> "aws_test_vpc_cidr"
  "internalAwsTestSubnetCidrs" -> "aws_test_subnet_cidrs"
  other -> other

positive :: Text -> Natural -> Either AwsSubstrateProfileError Natural
positive fieldName value
  | value == 0 = Left (AwsSubstrateProfileFieldZero fieldName)
  | otherwise = Right value

exactList :: Int -> Text -> [value] -> Either AwsSubstrateProfileError [value]
exactList expected fieldName values
  | length values == expected = Right values
  | otherwise = Left (AwsSubstrateProfileListLength fieldName expected (length values))

validatedToken :: Text -> Text -> Either AwsSubstrateProfileError Text
validatedToken fieldName raw
  | Text.null normalized = Left (AwsSubstrateProfileFieldEmpty fieldName)
  | Text.length normalized > 64 = Left (AwsSubstrateProfileFieldEmpty fieldName)
  | Text.all tokenCharacter normalized = Right normalized
  | otherwise = Left (AwsSubstrateProfileFieldEmpty fieldName)
 where
  normalized = Text.toLower (Text.strip raw)
  tokenCharacter character =
    isAsciiLower character || isDigit character || character `elem` (".-_" :: String)

validatedHostCidr :: Text -> Text -> Either AwsSubstrateProfileError Text
validatedHostCidr fieldName raw = do
  (_, prefix) <- parsedCidr fieldName raw
  if prefix == 32
    then Right (Text.strip raw)
    else Left (AwsSubstrateProfileMalformedCidr fieldName)

validatedNetworkCidr :: Text -> Text -> Either AwsSubstrateProfileError Text
validatedNetworkCidr fieldName raw = do
  (address, prefix) <- parsedCidr fieldName raw
  if prefix == 32
    then Left (AwsSubstrateProfileHostCidrForNetwork fieldName)
    else
      if address .&. hostMask prefix == 0
        then Right (Text.strip raw)
        else Left (AwsSubstrateProfileMalformedCidr fieldName)

parsedCidr :: Text -> Text -> Either AwsSubstrateProfileError (Integer, Int)
parsedCidr fieldName raw =
  case Text.splitOn "/" (Text.strip raw) of
    [addressText, prefixText] -> do
      octets <- maybe malformed Right (traverse parseOctet (Text.splitOn "." addressText))
      prefix <- maybe malformed Right (parseDecimal prefixText)
      case octets of
        [a, b, c, d]
          | prefix >= 0 && prefix <= 32 ->
              Right (a * 16777216 + b * 65536 + c * 256 + d, fromInteger prefix)
        _ -> malformed
    _ -> malformed
 where
  malformed = Left (AwsSubstrateProfileMalformedCidr fieldName)
  parseOctet value = do
    if Text.length value > 3 then Nothing else Just ()
    number <- parseDecimal value
    if number <= 255 && (Text.length value == 1 || Text.head value /= '0')
      then Just number
      else Nothing
  parseDecimal value
    | Text.null value || Text.length value > 3 || not (Text.all isDigit value) = Nothing
    | otherwise = Just (read (Text.unpack value))

hostMask :: Int -> Integer
hostMask prefix
  | prefix == 32 = 0
  | otherwise = (1 `shiftL` (32 - prefix)) - 1

renderAwsSubstrateProfileError :: AwsSubstrateProfileError -> String
renderAwsSubstrateProfileError err = case err of
  AwsSubstrateProfileFieldEmpty fieldName ->
    Text.unpack fieldName ++ " must be a non-empty AWS token"
  AwsSubstrateProfileFieldZero fieldName -> Text.unpack fieldName ++ " must be greater than zero"
  AwsSubstrateProfileListLength fieldName expected actual ->
    Text.unpack fieldName
      ++ " must contain exactly "
      ++ show expected
      ++ " values (got "
      ++ show actual
      ++ ")"
  AwsSubstrateProfileMalformedCidr fieldName -> Text.unpack fieldName ++ " is not a canonical IPv4 CIDR"
  AwsSubstrateProfileHostCidrForNetwork fieldName ->
    Text.unpack fieldName ++ " requires a network CIDR, not a /32 host CIDR"
  AwsSubstrateProfileUnsupportedVolumeType value ->
    "unsupported EBS volume type: " ++ Text.unpack value
  AwsSubstrateProfileDesiredBelowMinimum desired minimumValue ->
    "EKS desired node count " ++ show desired ++ " is below authored minimum " ++ show minimumValue
  AwsSubstrateProfileMaximumBelowDesired maximumValue desired ->
    "EKS authored maximum " ++ show maximumValue ++ " is below desired node count " ++ show desired
