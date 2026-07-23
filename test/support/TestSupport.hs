module TestSupport
  ( Expectation
  , SuiteBuilder
  , componentsDhallFragment
  , defaultComponentsDhallFragment
  , describe
  , expectationFailure
  , goldenTest
  , installOperatorBinaryInDir
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
  , wrapTier0WithDefaultComponentGraph
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.List (isInfixOf)
import GHC.Stack (HasCallStack)
import Prodbox.Config.SchemaDhall (renderDefaultComponentGraphDhall)
import System.Directory
  ( copyFile
  , getPermissions
  , setOwnerExecutable
  , setPermissions
  )
import System.FilePath ((</>))
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
-- | Sprint 1.56: supply the Tier-0 @components@ field (the component
-- dependency/readiness graph) as a __left-biased default__, so schema-less raw
-- config fixtures that predate the field still decode (they get an empty graph —
-- these fixtures do not exercise graph validity), while a fixture that DOES
-- declare @components@ (e.g. a @Config::{ … }@ completion whose default carries
-- the real graph) keeps its own value. Dhall @//@ is right-biased, so
-- @{ components = … } // config@ means "config wins where it sets a field".
wrapTier0 :: String -> String
wrapTier0 = wrapTier0WithComponents componentsDhallFragment

-- | A Tier-0 wrapper for graph-consuming command fixtures. These commands must
-- exercise the same complete default graph as production; an empty compatibility
-- graph is correctly rejected by the fail-closed native-plan compiler.
wrapTier0WithDefaultComponentGraph :: String -> String
wrapTier0WithDefaultComponentGraph =
  wrapTier0WithComponents defaultComponentsDhallFragment

wrapTier0WithComponents :: String -> String -> String
wrapTier0WithComponents componentFragment configRecord =
  unlines
    [ "{ parameters = { components = " ++ componentFragment ++ " } // (" ++ configRecord ++ ")"
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

-- | An empty typed @components@ list in the schema-less inline-union style the
-- fixtures use (Sprint 1.56).
componentsDhallFragment :: String
componentsDhallFragment = "[] : List " ++ componentNodeTypeDhall

-- | The production default component graph rendered through the same generic
-- Dhall encoder as the generated config schema. This keeps graph-consuming CLI
-- fixtures aligned without duplicating the graph as test-owned text.
defaultComponentsDhallFragment :: String
defaultComponentsDhallFragment = renderDefaultComponentGraphDhall

componentIdUnionDhall :: String
componentIdUnionDhall =
  "< ComponentClusterBase | ComponentMinio | ComponentVaultWorkload | ComponentVaultUnsealed | ComponentRegistry"
    ++ " | ComponentMetalLB | ComponentEnvoyGateway | ComponentCertManager"
    ++ " | ComponentPerconaPostgresOperator | ComponentGatewayDaemonPreVault | ComponentGatewayDaemonFull | ComponentChartPulsar"
    ++ " | ComponentChartRedis | ComponentChartKeycloakPostgres | ComponentChartKeycloak"
    ++ " | ComponentChartVscode | ComponentChartApi | ComponentChartWebsocket"
    ++ " | ComponentChartGateway | ComponentChartBootstrapBroker"
    ++ " | ComponentChartLifecycleAuthority | ComponentChartProviderWorker"
    ++ " | ComponentChartAuthorityBackup | ComponentChartTlsRetention"
    ++ " | ComponentChartTargetSecretAgent >"

componentNodeTypeDhall :: String
componentNodeTypeDhall =
  "{ component_id : "
    ++ componentIdUnionDhall
    ++ ", depends_on : List { dependency_on : "
    ++ componentIdUnionDhall
    ++ ", dependency_edge : < OrderingEdge | BackendWriteEdge > }"
    ++ ", readiness : < ProbeResourceExists | ProbeFrontDoorHttp | ProbeServiceActive | ProbeRolloutComplete"
    ++ " | ProbeOperatorAvailable | ProbeVaultUnsealed | ProbeBackendRoundTrip : "
    ++ componentIdUnionDhall
    ++ " > }"

-- | Install the built operator binary into @dir@ and return the installed
-- path. The host CLI resolves its Tier-0 @prodbox.dhall@ at the BINARY-SIBLING
-- path (config_doctrine.md §3), so an integration test that authors a fixture
-- @dir\/prodbox.dhall@ must run a binary whose sibling is that fixture — i.e. a
-- binary living in @dir@. Copies (not symlinks) because @getExecutablePath@
-- resolves symlinks back to the real build output. Sprint 1.48.
installOperatorBinaryInDir :: FilePath -> FilePath -> IO FilePath
installOperatorBinaryInDir binary dir = do
  let installedPath = dir </> "prodbox"
  copyFile binary installedPath
  perms <- getPermissions installedPath
  setPermissions installedPath (setOwnerExecutable True perms)
  pure installedPath

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
