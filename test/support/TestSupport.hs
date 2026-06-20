module TestSupport
  ( Expectation
  , SuiteBuilder
  , describe
  , expectationFailure
  , goldenTest
  , it
  , mainWithSuite
  , propertyTest
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  , wrapTier0
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.List (isInfixOf)
import GHC.Stack (HasCallStack)
import Test.Tasty (TestName, TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit
  ( Assertion
  , assertBool
  , assertEqual
  , assertFailure
  , testCase
  )
import Test.Tasty.QuickCheck (Testable, testProperty)

-- | Sprint 1.42 Part B: wrap a @ConfigFile@-shaped Dhall record (the legacy
-- @prodbox-config.dhall@ payload our fixtures emit) into a Tier-0
-- @prodbox.dhall@ @{ parameters, context, witness }@ record, so a fixture that
-- authors the operator's non-secret config writes the retired file's
-- replacement. The embedded @context@ is a valid @HostOrchestrator@ binary
-- context; because the temp repo has no Vault unlock bundle, the cluster is
-- "not established", so config loading reads the @parameters@ directly —
-- exactly as a host CLI command does before bring-up.
wrapTier0 :: String -> String
wrapTier0 configRecord =
  unlines
    [ "{ parameters = " ++ configRecord
    , ", context ="
    , "  { project = \"prodbox\""
    , "  , binary = \"prodbox\""
    , "  , context_kind = < HostOrchestrator | Daemon | ClusterService | OtherContext >.HostOrchestrator"
    , "  , cluster_id = \"prodbox-home\""
    , "  , vault_address = \"http://127.0.0.1:31820\""
    , "  , minio_endpoint = \"http://minio.prodbox.svc.cluster.local:9000\""
    , "  , minio_bucket = \"prodbox-state\""
    , "  , topology ="
    , "    { seal_mode = < Tier0Shamir | Tier0Transit >.Tier0Shamir"
    , "    , parent_ref = None { parent_cluster_id : Text, parent_vault_address : Text, parent_transit_key : Text }"
    , "    }"
    , "  , capabilities = [ < DurableStore | VaultAuth | PublicEdge | OtherCapability >.DurableStore, < DurableStore | VaultAuth | PublicEdge | OtherCapability >.VaultAuth ]"
    , "  }"
    , ", witness = [] : List Text"
    , "}"
    ]

type Expectation = Assertion

newtype SuiteBuilder a = SuiteBuilder (a, [TestTree])

instance Functor SuiteBuilder where
  fmap f (SuiteBuilder (value, trees)) = SuiteBuilder (f value, trees)

instance Applicative SuiteBuilder where
  pure value = SuiteBuilder (value, [])
  SuiteBuilder (function, leftTrees) <*> SuiteBuilder (value, rightTrees) =
    SuiteBuilder (function value, leftTrees ++ rightTrees)

instance Monad SuiteBuilder where
  SuiteBuilder (value, leftTrees) >>= continue =
    let SuiteBuilder (nextValue, rightTrees) = continue value
     in SuiteBuilder (nextValue, leftTrees ++ rightTrees)

mainWithSuite :: TestName -> SuiteBuilder () -> IO ()
mainWithSuite suiteName builder =
  defaultMain (testGroup suiteName (suiteTrees builder))

describe :: TestName -> SuiteBuilder () -> SuiteBuilder ()
describe groupName builder =
  appendTree (testGroup groupName (suiteTrees builder))

it :: TestName -> Expectation -> SuiteBuilder ()
it testName expectation =
  appendTree (testCase testName expectation)

goldenTest :: TestName -> FilePath -> IO ByteString -> SuiteBuilder ()
goldenTest testName goldenPath renderAction =
  appendTree (goldenVsString testName goldenPath renderAction)

propertyTest :: (Testable prop) => TestName -> prop -> SuiteBuilder ()
propertyTest testName propertyValue =
  appendTree (testProperty testName propertyValue)

expectationFailure :: String -> Expectation
expectationFailure = assertFailure

shouldBe :: (HasCallStack, Eq a, Show a) => a -> a -> Expectation
shouldBe actual expected = assertEqual "" expected actual

shouldNotBe :: (HasCallStack, Eq a, Show a) => a -> a -> Expectation
shouldNotBe actual unexpected =
  assertBool
    ("Did not expect: " ++ show unexpected)
    (actual /= unexpected)

shouldContain :: (HasCallStack, Eq a, Show a) => [a] -> [a] -> Expectation
shouldContain actual expected =
  assertBool
    ("Expected " ++ show actual ++ " to contain " ++ show expected)
    (expected `isInfixOf` actual)

shouldNotContain :: (HasCallStack, Eq a, Show a) => [a] -> [a] -> Expectation
shouldNotContain actual expected =
  assertBool
    ("Expected " ++ show actual ++ " not to contain " ++ show expected)
    (not (expected `isInfixOf` actual))

shouldReturn :: (HasCallStack, Eq a, Show a) => IO a -> a -> Expectation
shouldReturn action expected = do
  actual <- action
  shouldBe actual expected

shouldSatisfy :: (HasCallStack) => a -> (a -> Bool) -> Expectation
shouldSatisfy actual predicate =
  assertBool "Expected predicate to return True." (predicate actual)

appendTree :: TestTree -> SuiteBuilder ()
appendTree tree = SuiteBuilder ((), [tree])

suiteTrees :: SuiteBuilder () -> [TestTree]
suiteTrees (SuiteBuilder (_, trees)) = trees
