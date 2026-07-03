{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.TestTopology
  ( FailoverScenario (..)
  , FixtureId (..)
  , RunVariant (..)
  , TestBudget (..)
  , TestSuite (..)
  , TestTopology (..)
  , TestTopologyError (..)
  , defaultTestTopology
  , renderFixtureId
  , renderTestTopologyDhall
  , renderTestTopologyError
  , validateTestTopology
  )
where

import Data.Char qualified as Char
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall
  ( Encoder
  , FromDhall (..)
  , InterpretOptions (..)
  , ToDhall (..)
  , defaultInterpretOptions
  , embed
  , genericAutoWith
  , genericToDhallWith
  , inject
  )
import Dhall.Core qualified as Core
import Dhall.Src (Src)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Cluster.Topology
  ( ClusterTopology
  , defaultClusterTopology
  , renderTopologyError
  , validateClusterTopology
  )

data FailoverScenario
  = FailoverLeaderKill
  | FailoverNetworkPartition
  deriving (Eq, Ord, Show, Generic)

instance FromDhall FailoverScenario where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {constructorModifier = stripPrefix "Failover"}

instance ToDhall FailoverScenario where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {constructorModifier = stripPrefix "Failover"}

data FixtureId
  = FixtureAwsAdminForTestSimulation
  | FixtureAcmeEab
  | FixtureVaultUnlockBundle
  deriving (Eq, Ord, Show, Generic)

instance FromDhall FixtureId where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {constructorModifier = stripPrefix "Fixture"}

instance ToDhall FixtureId where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {constructorModifier = stripPrefix "Fixture"}

data TestBudget = TestBudget
  { budgetMaxNodes :: Natural
  , budgetWallClockSeconds :: Natural
  }
  deriving (Eq, Show, Generic)

instance FromDhall TestBudget where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "budget"}

instance ToDhall TestBudget where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "budget"}

data RunVariant = RunVariant
  { variantCluster :: ClusterTopology
  , variantReplicas :: Natural
  , variantFailover :: Maybe FailoverScenario
  }
  deriving (Eq, Show, Generic)

instance FromDhall RunVariant where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "variant"}

instance ToDhall RunVariant where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "variant"}

data TestSuite = TestSuite
  { suiteName :: Text
  , suiteVariants :: [RunVariant]
  , suiteBudget :: TestBudget
  , suiteFixtures :: [FixtureId]
  }
  deriving (Eq, Show, Generic)

instance FromDhall TestSuite where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "suite"}

instance ToDhall TestSuite where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = dropPrefixDhallField "suite"}

data TestTopology = TestTopology
  { topologySuites :: [TestSuite]
  , topologyFixtures :: [FixtureId]
  }
  deriving (Eq, Show, Generic)

instance FromDhall TestTopology where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = testTopologyFieldModifier}

instance ToDhall TestTopology where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = testTopologyFieldModifier}

data TestTopologyError
  = TestTopologyHasNoSuites
  | TestSuiteNameEmpty
  | TestSuiteNameReserved Text
  | TestSuiteHasNoVariants Text
  | TestBudgetMaxNodesZero Text
  | TestBudgetWallClockSecondsZero Text
  | TestVariantReplicasZero Text
  | TestVariantReplicasExceedBudget Text Natural Natural
  | TestVariantClusterInvalid Text String
  | TestFixtureNotDeclared Text FixtureId
  deriving (Eq, Show)

defaultTestTopology :: TestTopology
defaultTestTopology =
  TestTopology
    { topologySuites =
        [ TestSuite
            { suiteName = "unit"
            , suiteVariants =
                [ RunVariant
                    { variantCluster = defaultClusterTopology
                    , variantReplicas = 1
                    , variantFailover = Nothing
                    }
                ]
            , suiteBudget =
                TestBudget
                  { budgetMaxNodes = 1
                  , budgetWallClockSeconds = 1800
                  }
            , suiteFixtures = []
            }
        ]
    , topologyFixtures = []
    }

validateTestTopology :: TestTopology -> Either TestTopologyError ()
validateTestTopology topology = do
  if null (topologySuites topology)
    then Left TestTopologyHasNoSuites
    else traverse_ (validateSuite (topologyFixtures topology)) (topologySuites topology)

validateSuite :: [FixtureId] -> TestSuite -> Either TestTopologyError ()
validateSuite declaredFixtures suite = do
  validateSuiteName (suiteName suite)
  if null (suiteVariants suite)
    then Left (TestSuiteHasNoVariants (suiteName suite))
    else pure ()
  validateBudget (suiteName suite) (suiteBudget suite)
  traverse_ (validateFixtureDeclared (suiteName suite) declaredFixtures) (suiteFixtures suite)
  traverse_ (validateVariant (suiteName suite) (suiteBudget suite)) (suiteVariants suite)

validateSuiteName :: Text -> Either TestTopologyError ()
validateSuiteName name
  | Text.null name = Left TestSuiteNameEmpty
  | name == "all" = Left (TestSuiteNameReserved name)
  | otherwise = Right ()

validateBudget :: Text -> TestBudget -> Either TestTopologyError ()
validateBudget suiteName' budget = do
  if budgetMaxNodes budget == 0
    then Left (TestBudgetMaxNodesZero suiteName')
    else pure ()
  if budgetWallClockSeconds budget == 0
    then Left (TestBudgetWallClockSecondsZero suiteName')
    else pure ()

validateFixtureDeclared :: Text -> [FixtureId] -> FixtureId -> Either TestTopologyError ()
validateFixtureDeclared suiteName' declared fixture =
  case find (== fixture) declared of
    Just _ -> Right ()
    Nothing -> Left (TestFixtureNotDeclared suiteName' fixture)

validateVariant :: Text -> TestBudget -> RunVariant -> Either TestTopologyError ()
validateVariant suiteName' budget variant = do
  if variantReplicas variant == 0
    then Left (TestVariantReplicasZero suiteName')
    else pure ()
  if variantReplicas variant > budgetMaxNodes budget
    then
      Left
        ( TestVariantReplicasExceedBudget
            suiteName'
            (variantReplicas variant)
            (budgetMaxNodes budget)
        )
    else pure ()
  case validateClusterTopology (variantCluster variant) of
    Left err -> Left (TestVariantClusterInvalid suiteName' (renderTopologyError err))
    Right () -> Right ()

renderTestTopologyError :: TestTopologyError -> String
renderTestTopologyError err =
  case err of
    TestTopologyHasNoSuites ->
      "test topology must declare at least one suite"
    TestSuiteNameEmpty ->
      "test topology suite name must not be empty"
    TestSuiteNameReserved name ->
      "test topology suite name `" ++ Text.unpack name ++ "` is reserved"
    TestSuiteHasNoVariants name ->
      "test topology suite `" ++ Text.unpack name ++ "` must declare at least one variant"
    TestBudgetMaxNodesZero name ->
      "test topology suite `" ++ Text.unpack name ++ "` budget.max_nodes must be greater than zero"
    TestBudgetWallClockSecondsZero name ->
      "test topology suite `"
        ++ Text.unpack name
        ++ "` budget.wall_clock_seconds must be greater than zero"
    TestVariantReplicasZero name ->
      "test topology suite `" ++ Text.unpack name ++ "` variant replicas must be greater than zero"
    TestVariantReplicasExceedBudget name replicas maxNodes ->
      "test topology suite `"
        ++ Text.unpack name
        ++ "` variant replicas "
        ++ show replicas
        ++ " exceed budget.max_nodes "
        ++ show maxNodes
    TestVariantClusterInvalid name clusterErr ->
      "test topology suite `" ++ Text.unpack name ++ "` has invalid cluster topology: " ++ clusterErr
    TestFixtureNotDeclared name fixture ->
      "test topology suite `"
        ++ Text.unpack name
        ++ "` references undeclared fixture `"
        ++ Text.unpack (renderFixtureId fixture)
        ++ "`"

renderFixtureId :: FixtureId -> Text
renderFixtureId fixture =
  case fixture of
    FixtureAwsAdminForTestSimulation -> "aws_admin_for_test_simulation"
    FixtureAcmeEab -> "acme_eab"
    FixtureVaultUnlockBundle -> "vault_unlock_bundle"

-- | Sprint 5.11: render the executable-sibling @prodbox.test.dhall@ from the
-- Haskell test-topology SSoT. The import gives authored files a stable schema
-- handle for edits; the value itself is rendered via the same Dhall encoder the
-- decoder consumes, so @test init@ cannot drift from 'TestTopology'.
renderTestTopologyDhall :: FilePath -> TestTopology -> String
renderTestTopologyDhall schemaPath topology =
  Text.unpack $
    Text.unlines
      [ "let TestTopology = " <> Text.pack schemaPath
      , ""
      , "in  " <> Core.pretty (injectedValue (inject :: Encoder TestTopology) topology)
      ]

type DhallExpr = Core.Expr Src Void

injectedValue :: Encoder a -> a -> DhallExpr
injectedValue encoder value = Core.denote (embed encoder value)

testTopologyFieldModifier :: Text -> Text
testTopologyFieldModifier = dropPrefixDhallField "topology"

dropPrefixDhallField :: Text -> Text -> Text
dropPrefixDhallField prefix name =
  case Text.stripPrefix prefix name of
    Just stripped -> haskellCamelToDhallSnake (lowerFirst stripped)
    Nothing -> name

lowerFirst :: Text -> Text
lowerFirst value =
  case Text.uncons value of
    Nothing -> value
    Just (first, rest) -> Text.cons (Char.toLower first) rest

stripPrefix :: Text -> Text -> Text
stripPrefix prefix name =
  fromMaybe name (Text.stripPrefix prefix name)

haskellCamelToDhallSnake :: Text -> Text
haskellCamelToDhallSnake value =
  Text.dropWhile (== '_') $
    Text.concatMap camelCharToDhall value

camelCharToDhall :: Char -> Text
camelCharToDhall char
  | Char.isUpper char = Text.pack ['_', Char.toLower char]
  | otherwise = Text.singleton char
