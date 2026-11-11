{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module FieldNameTableTests (fieldNameTablesSuite) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Either.Validation (Validation (..))
import Data.List (sort)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Dhall qualified
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import PinnedHeapGraph
import Prodbox.Config.FieldNameTable
import Prodbox.Config.FieldNameTable.Stage
import Prodbox.Config.FieldNameTables
import Prodbox.Config.RetainedArtifacts qualified as Retained
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import Prodbox.Substrate qualified as Scaling
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))

import TestSupport (SuiteBuilder, describe, it)

{-# NOINLINE coldTable #-}
coldTable :: FieldNameTable 'RetainedSectionFields
coldTable = $$(fieldNameTableCode SRetainedSectionFields)
fixtureTable :: FieldNameTable 'AwsProfileFields
fixtureTable =
  $$( liftFieldNameTableDefinition
        ( either
            (error . show)
            id
            (prepareFieldNameTableDefinition SAwsProfileFields [("λ\0", "\x1f642\0"), ("alias", "\x1f642\0")])
        )
    )

fieldNameTablesSuite :: SuiteBuilder ()
fieldNameTablesSuite = describe "static field-name tables" $ do
  it "numeric floor leaves literal metadata deferred" $ do
    before <- try (observeGraph coldTable) :: IO (Either SomeException GraphObservation)
    required <- evaluate (fieldNameTableDataBytes coldTable)
    after <- try (observeGraph coldTable) :: IO (Either SomeException GraphObservation)
    assertBool "cold metadata was evaluated" (isLeft before && isLeft after && required > 0)
    numeric <- observeGraph required
    observedDataBytes numeric @?= 16
  it "stages one scalar for every shared table without runtime summation" $ do
    total <- evaluate fieldNameTablesDataBytes
    total
      @?= sum
        [ fieldNameTableDataBytes awsProfileFieldNames
        , fieldNameTableDataBytes scalingSubstrateFieldNames
        , fieldNameTableDataBytes retainedDeclarationFieldNames
        , fieldNameTableDataBytes retainedSectionFieldNames
        ]
    graph <- observeGraph total
    observedDataBytes graph @?= 16
  it "keeps exact literal matches and unknown-field identity" $ do
    modifyFieldName awsProfileFieldNames "internalOperatorCidr" @?= "operator_cidr"
    modifyFieldName scalingSubstrateFieldNames "scalingHomeLocal" @?= "home_local"
    modifyFieldName retainedDeclarationFieldNames "radRetainedPath" @?= "retained_path"
    modifyFieldName retainedSectionFieldNames "rasArtifacts" @?= "artifacts"
    forM_
      [ modifyFieldName awsProfileFieldNames
      , modifyFieldName scalingSubstrateFieldNames
      , modifyFieldName retainedDeclarationFieldNames
      , modifyFieldName retainedSectionFieldNames
      ]
      checkUnknown
  it "every returned table data graph fits its constructor-data term" $ do
    checkGraph "aws" awsProfileFieldNames
    checkGraph "scaling" scalingSubstrateFieldNames
    checkGraph "retained-declaration" retainedDeclarationFieldNames
    checkGraph "retained-section" retainedSectionFieldNames
    checkGraph "unicode-nul" fixtureTable
  it "duplicate source refusal precedes target demand" $
    case prepareFieldNameTableDefinition
      SAwsProfileFields
      [("duplicate", "ok"), ("duplicate", error "target must remain deferred")] of
      Left cause -> cause @?= FieldNameTableDuplicateSource "duplicate"
      Right _ -> assertFailure "duplicate source accepted"
  it "Unicode NUL and equal target aliases retain Text semantics" $ do
    modifyFieldName fixtureTable "λ\0" @?= "\x1f642\0"
    modifyFieldName fixtureTable "alias" @?= "\x1f642\0"
    modifyFieldName fixtureTable "missing\0" @?= "missing\0"
  it "all actual SDK owner root labels retain their existing schemas" $ do
    checkSchema (Proxy @Aws.AwsSubstrateProfile) awsProfileFieldNames
    checkSchema (Proxy @Scaling.ScalingPolicyBySubstrate) scalingSubstrateFieldNames
    checkSchema (Proxy @Retained.RetainedArtifactDeclaration) retainedDeclarationFieldNames
    checkSchema (Proxy @Retained.RetainedArtifactsSection) retainedSectionFieldNames
  it "definition generation retains all declared entries" $ do
    fieldNameTableEntries awsProfileFieldNames @?= fieldNameTableDefinitionEntries SAwsProfileFields
    fieldNameTableEntries scalingSubstrateFieldNames
      @?= fieldNameTableDefinitionEntries SScalingSubstrateFields
    fieldNameTableEntries retainedDeclarationFieldNames
      @?= fieldNameTableDefinitionEntries SRetainedDeclarationFields
    fieldNameTableEntries retainedSectionFieldNames
      @?= fieldNameTableDefinitionEntries SRetainedSectionFields

checkUnknown :: (Text -> Text) -> IO ()
checkUnknown modifier = forM_ ["unknown_field", "λ😀", "", "radKindSuffix", " internalOperatorCidr "] $ \value -> modifier value @?= value

checkGraph :: String -> FieldNameTable tableRole -> IO ()
checkGraph label table = do
  value <- evaluate (force table)
  graph <- observeGraph value
  assertBool
    (show (label, observedDataBytes graph, fieldNameTableDataBytes table))
    (observedDataBytes graph <= toInteger (fieldNameTableDataBytes table))
  print
    ( "field_table_data" :: String
    , label
    , observedDataBytes graph
    , observedIndirectionBytes graph
    , fieldNameTableDataBytes table
    )
checkSchema
  :: forall owner tableRole
   . (Dhall.FromDhall owner, Dhall.ToDhall owner) => Proxy owner -> FieldNameTable tableRole -> IO ()
checkSchema _ table = do
  let targets = sort (map snd (fieldNameTableEntries table))
  case Dhall.expected (Dhall.auto :: Dhall.Decoder owner) of
    Failure _ -> assertFailure "existing expected schema refused"
    Success expression -> recordKeys expression @?= Just targets
  recordKeys (Dhall.declared (Dhall.inject :: Dhall.Encoder owner)) @?= Just targets
 where
  recordKeys expression = case expression of
    Core.Record fields -> Just (sort (DhallMap.keys fields))
    _ -> Nothing
