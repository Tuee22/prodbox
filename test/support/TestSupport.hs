{-# LANGUAGE OverloadedStrings #-}

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
  , testRetryPolicy
  , fixtureReadyRoleReadinessSource
  , fixtureUnreadyRoleReadinessSource
  , fixtureReadinessNowMicros
  , fixtureRoleReadinessResolver
  , verifiedCallerSlotFixture
  )
where

import Control.Concurrent.STM (atomically)
import Data.ByteString.Char8 qualified as StrictByteString8
import Data.ByteString.Lazy (ByteString)
import Data.List (isInfixOf)
import GHC.Stack (HasCallStack)
import Numeric.Natural (Natural)
import Prodbox.Config.SchemaDhall (renderDefaultComponentGraphDhall)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , decodeAndVerifyControlPlaneRequest
  , encodeSignedControlPlaneRequest
  , mkRequestNonce
  , mkRequestSigner
  , mkRequestVerificationContext
  , mkSigningKeyGeneration
  , signControlPlaneRequest
  , trustedRequestKeyFromSigner
  , verifiedRequestCallerSlot
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , constantRoleReadinessSource
  , controlPlaneRoleReadinessSchedule
  , readyRoleReadinessFacts
  , unobservedRoleReadinessFacts
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecyclePulumiCheckpoint))
import Prodbox.ControlPlane.Server
  ( RoleReadinessResolver
  , mkRoleReadinessResolver
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease
  ( authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Retry qualified as Retry
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
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

-- | Construct an opaque caller slot only by exercising the real signed-request
-- verifier.  Endpoint and repository fixtures use this instead of exposing a
-- test-only constructor for the production authentication capability.
verifiedCallerSlotFixture :: CallerPrincipal -> Natural -> VerifiedCallerSlot
verifiedCallerSlotFixture caller rawGeneration =
  verifiedRequestCallerSlot
    ( mustFixture
        ( decodeAndVerifyControlPlaneRequest
            65536
            verificationContext
            (encodeSignedControlPlaneRequest signed)
        )
    )
 where
  body = StrictByteString8.empty
  scope = mustFixture (mkAuthorityScope "test-authority")
  deadline = authorityTimeFromMicros 2000
  nonce = mustFixture (mkRequestNonce "verified-caller-slot-fixture")
  now = authorityTimeFromMicros 1000
  lifetime = mustFixture (authorityDurationFromMicros 5000)
  generation = mustFixture (mkSigningKeyGeneration rawGeneration)
  signer =
    mustFixture
      ( mkRequestSigner
          caller
          generation
          "0123456789abcdef0123456789abcdef"
      )
  signed =
    mustFixture
      ( signControlPlaneRequest
          signer
          LifecyclePulumiCheckpoint
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadline
          nonce
          body
      )
  verificationContext =
    mustFixture
      ( mkRequestVerificationContext
          (trustedRequestKeyFromSigner signer)
          LifecyclePulumiCheckpoint
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadline
          nonce
          now
          lifetime
      )

mustFixture :: (Show err) => Either err value -> value
mustFixture result = case result of
  Left err -> error (show err)
  Right value -> value

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

-- | Sprint 1.77: a retry policy for a fixture.
--
-- 'Prodbox.Retry.RetryPolicy' hides its constructor, so a test builds one the
-- same way production data does — through the validating smart constructor —
-- and a fixture that authors an impossible schedule fails loudly here rather
-- than quietly exercising one. The jitter fraction is the compiled default, so
-- a fixture never accidentally pins a schedule to the un-jittered path.
testRetryPolicy :: Int -> Int -> Int -> Int -> Retry.RetryPolicy
testRetryPolicy maxAttempts baseDelay multiplier maxDelay =
  case Retry.mkRetryPolicy maxAttempts baseDelay multiplier maxDelay Retry.defaultJitterFraction of
    Right policy -> policy
    Left err -> error ("test retry policy is not a policy: " ++ Retry.renderRetryPolicyError err)

-- | Sprint 4.55: a fixture readiness source that has observed everything it
-- needs, stamped at the fixture instant, plus the resolver a test serves with.
fixtureReadyRoleReadinessSource :: RoleReadinessSource
fixtureReadyRoleReadinessSource =
  constantRoleReadinessSource (readyRoleReadinessFacts "fixture" fixtureReadinessNowMicros)

fixtureUnreadyRoleReadinessSource :: RoleReadinessSource
fixtureUnreadyRoleReadinessSource =
  constantRoleReadinessSource (unobservedRoleReadinessFacts "fixture")

fixtureReadinessNowMicros :: Natural
fixtureReadinessNowMicros = 1000000000

fixtureRoleReadinessResolver :: RoleReadinessResolver IO
fixtureRoleReadinessResolver =
  mkRoleReadinessResolver
    controlPlaneRoleReadinessSchedule
    (pure fixtureReadinessNowMicros)
    atomically
