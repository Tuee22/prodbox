{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Prodbox.Config.FieldNameTable.Stage (fieldNameTableCode, fieldNameTableDefinitionEntries, fieldNameTablesDataCode) where

import Data.Text (Text)
import Language.Haskell.TH.Syntax
  ( Code (..)
  , Lift (liftTyped)
  , Q
  , addDependentFile
  , loc_filename
  , location
  , runIO
  )
import Numeric.Natural (Natural)
import Prodbox.Config.FieldNameTable
import Prodbox.Config.SchemaSourceDependencies (discoverSchemaSourceDependencies)

fieldNameTableCode :: SFieldNameTableRole tableRole -> Code Q (FieldNameTable tableRole)
fieldNameTableCode tableRole = Code $ do
  here <- location
  observed <- runIO (discoverSchemaSourceDependencies (loc_filename here))
  sources <- either (fail . show) pure observed
  mapM_ addDependentFile sources
  definition <-
    either
      (fail . show)
      pure
      (prepareFieldNameTableDefinition tableRole (fieldNameTableDefinitionEntries tableRole))
  examineCode (liftFieldNameTableDefinition definition)
fieldNameTableDefinitionEntries :: SFieldNameTableRole tableRole -> [(Text, Text)]
fieldNameTableDefinitionEntries tableRole = case tableRole of
  SAwsProfileFields ->
    [ ("internalOperatorCidr", "operator_cidr")
    , ("internalEksNodeInstanceType", "eks_node_instance_type")
    , ("internalEksNodeDiskSizeGib", "eks_node_disk_size_gib")
    , ("internalEksNodeMinSize", "eks_node_min_size")
    , ("internalEksNodeMaxSize", "eks_node_max_size")
    , ("internalAwsTestInstanceTypes", "aws_test_instance_types")
    , ("internalAwsTestRootVolumeTypes", "aws_test_root_volume_types")
    , ("internalAwsTestRootVolumeSizesGib", "aws_test_root_volume_sizes_gib")
    , ("internalStaticEbsVolumeType", "static_ebs_volume_type")
    , ("internalEksVpcCidr", "eks_vpc_cidr")
    , ("internalEksSubnetCidrs", "eks_subnet_cidrs")
    , ("internalAwsTestVpcCidr", "aws_test_vpc_cidr")
    , ("internalAwsTestSubnetCidrs", "aws_test_subnet_cidrs")
    ]
  SScalingSubstrateFields ->
    [ ("scalingHomeLocal", "home_local")
    , ("scalingAws", "aws")
    ]
  SRetainedDeclarationFields ->
    [ ("radKind", "kind")
    , ("radVersion", "version")
    , ("radDigest", "digest")
    , ("radRetainedPath", "retained_path")
    , ("radSourceUrl", "source_url")
    ]
  SRetainedSectionFields ->
    [ ("rasArchitecture", "architecture")
    , ("rasArtifacts", "artifacts")
    ]

fieldNameTablesDataCode :: Code Q Natural
fieldNameTablesDataCode = Code $ do
  here <- location
  observed <- runIO (discoverSchemaSourceDependencies (loc_filename here))
  sources <- either (fail . show) pure observed
  mapM_ addDependentFile sources
  parts <- either (fail . show) pure (traverse roleDataBytes [minBound .. maxBound])
  let total = sum parts
  if total <= fromIntegral (maxBound :: Int)
    then examineCode [||fromInteger $$(liftTyped (toInteger total))||]
    else fail (show FieldNameTableDataExceedsAddressSpace)

roleDataBytes :: FieldNameTableRole -> Either FieldNameTableError Natural
roleDataBytes tableRole = case tableRole of
  AwsProfileFields -> definitionData SAwsProfileFields
  ScalingSubstrateFields -> definitionData SScalingSubstrateFields
  RetainedDeclarationFields -> definitionData SRetainedDeclarationFields
  RetainedSectionFields -> definitionData SRetainedSectionFields
 where
  definitionData :: SFieldNameTableRole tableRole -> Either FieldNameTableError Natural
  definitionData roleTag =
    fieldNameTableDefinitionDataBytes
      <$> prepareFieldNameTableDefinition roleTag (fieldNameTableDefinitionEntries roleTag)
