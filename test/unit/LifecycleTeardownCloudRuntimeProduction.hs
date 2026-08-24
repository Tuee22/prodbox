{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.86: the production cloud runtime is constructible on a host, and
-- every cloud-owned node it dispatches reaches the Lifecycle Authority and
-- nothing else.
--
-- The transport is a fake wire rather than a fake component: each arm is the
-- real production client, so a node that stopped reaching the Authority — or
-- that reached some other boundary instead — shows up here as a missing or
-- extra recorded route rather than as a passing test over a stub.
module LifecycleTeardownCloudRuntimeProduction
  ( lifecycleTeardownCloudRuntimeProductionSuite

    -- * Shared with the frozen-composition suite
  , ProductionCloudEffects (..)
  , buildRuntime
  , cloudOwnedPlans
  , tagFor
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedClientTransport
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli))
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
import Prodbox.ControlPlane.RequestAuthentication
  ( localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (ReplyServiceUnavailable)
  , replyStatusCode
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.PulumiCheckpoint
  ( RegisteredPulumiCheckpointError (PulumiCheckpointNameUnregistered)
  )
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
  ( AwsCheckpointInterpreterError (AwsCheckpointRegistrationMissing)
  )
import Prodbox.Lifecycle.Teardown.CloudRuntime
  ( CloudRuntime
  , executeCloudOperation
  )
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
import Prodbox.Lifecycle.Teardown.Execution
  ( LifecycleTeardownEffects (..)
  , TeardownNodeResult (TeardownNodeRefused)
  , runCompiledTeardownNode
  )
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

lifecycleTeardownCloudRuntimeProductionSuite :: SuiteBuilder ()
lifecycleTeardownCloudRuntimeProductionSuite =
  describe "Sprint 4.86 production cloud runtime" $ do
    it "bounds the drain lease at both ends and keeps the accepted value" $ do
      fmap eksDrainLeaseSecondsValue (mkEksDrainLeaseSeconds 1) `shouldBe` Right 1
      fmap eksDrainLeaseSecondsValue (mkEksDrainLeaseSeconds 900)
        `shouldBe` Right 900
      mkEksDrainLeaseSeconds 0
        `shouldBe` Left (ProductionCloudDrainLeaseInvalid 0)
      mkEksDrainLeaseSeconds (-1)
        `shouldBe` Left (ProductionCloudDrainLeaseInvalid (-1))
      mkEksDrainLeaseSeconds 901
        `shouldBe` Left (ProductionCloudDrainLeaseInvalid 901)

    it "renders every refusal as a bounded operator-readable line" $ do
      let cases :: [(ProductionCloudRuntimeError, String)]
          cases =
            [ (ProductionCloudDrainLeaseInvalid 0, "1..900")
            ,
              ( ProductionCloudCheckpointUnregistered
                  "aws-eks"
                  (PulumiCheckpointNameUnregistered "aws-eks")
              , "aws-eks"
              )
            ,
              ( ProductionCloudCheckpointAuthoritiesInvalid
                  ( AwsCheckpointRegistrationMissing
                      AwsEksKey
                      "prodbox"
                      "aws-eks"
                  )
              , "registrations"
              )
            ]
      forM_ cases $ \(err, expected) -> do
        let line = renderProductionCloudRuntimeError err
        line `shouldSatisfy` (not . null)
        length line `shouldSatisfy` (< 4096)
        line `shouldSatisfy` isInfixOfString expected

    it "is constructible on a host from one authenticated Authority transport" $ do
      calls <- newIORef []
      runtime <- buildRuntime calls
      runtime `shouldSatisfy` isRight

    it "routes every cloud-owned cascade node to the Lifecycle Authority" $ do
      calls <- newIORef []
      built <- buildRuntime calls
      runtime <- mustRightIO built
      let compiled = compiledFor CascadeSurface
      forM_ (cloudOwnedPlans compiled) $ \plan -> do
        _ <-
          runProductionCloudEffects
            (runCompiledTeardownNode compiled plan)
            runtime
        pure ()
      observed <- readIORef calls
      -- Every recorded call went to the local Lifecycle Authority endpoint.
      -- An arm that had opened an object store, a Vault session, or a provider
      -- CLI of its own would leave no call here at all, so a shrinking list is
      -- how an escape path shows up.
      observed `shouldSatisfy` (not . null)
      forM_ observed (`shouldSatisfy` Text.isPrefixOf authorityEndpointPrefix)
      -- A node whose predecessor proofs are absent refuses before any boundary
      -- is reached, so the count is deliberately not the node count; what is
      -- measured is that the reachable ones reach exactly one authority.
      length (nub (map authorityHostOf observed)) `shouldBe` 1

    it "closes no cloud node beyond the observation that records the outage" $ do
      calls <- newIORef []
      built <- buildRuntime calls
      runtime <- mustRightIO built
      let compiled = compiledFor CascadeSurface
      outcomes <-
        mapM
          ( \plan ->
              runProductionCloudEffects
                (runCompiledTeardownNode compiled plan)
                runtime
          )
          (awsScopedCloudPlans compiled)
      -- Nothing succeeds against an Authority that answers 503: an outcome
      -- that closed a node here would be a component deciding a mutation from
      -- its own request rather than from a durable answer.
      -- An unreachable Authority is an observation, not a decision.  The
      -- three checkpoint-pair observers close by recording that the pair is
      -- unobservable, which is exactly their job; every node that would have
      -- had to *decide* something from that outage fails instead.  Pinning the
      -- succeeding set rather than merely "something failed" is what would
      -- catch a component closing a mutation from its own request.
      sort (succeedingTags compiled outcomes)
        `shouldBe` [ "observe-checkpoint-pair/aws-eks"
                   , "observe-checkpoint-pair/aws-eks-subzone"
                   , "observe-checkpoint-pair/aws-test"
                   ]
      outcomes `shouldSatisfy` any isFailedNode

-- ---------------------------------------------------------------------------
-- The runtime under test
-- ---------------------------------------------------------------------------

buildRuntime
  :: IORef [Text]
  -> IO (Either ProductionCloudRuntimeError (CloudRuntime IO))
buildRuntime calls = do
  transport <- mustRightIO (fakeAuthorityTransport calls)
  lease <- mustRightIO (mkEksDrainLeaseSeconds 300)
  let compiled = compiledFor CascadeSurface
      inputs =
        ProductionCloudRuntimeInputs
          { productionCloudRepositoryRoot = "/nonexistent/prodbox-repository"
          , productionCloudCaller = LifecycleAuthorityOperator
          , productionCloudKubectlPath = "/nonexistent/kubectl"
          , productionCloudKubectlEnvironment = []
          , productionCloudKubectlWorkingDirectory = Nothing
          , productionCloudDrainLease = lease
          }
  pure
    ( productionCloudRuntime
        inputs
        transport
        fixtureRunId
        (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled))
    )

-- | A closed carrier whose environment is exactly the cloud runtime.  There is
-- no injected operation callback, so a node that this suite drives cannot be
-- answered by anything other than the runtime under test.
newtype ProductionCloudEffects value = ProductionCloudEffects
  { runProductionCloudEffects :: CloudRuntime IO -> IO value
  }

instance Functor ProductionCloudEffects where
  fmap transform action =
    ProductionCloudEffects $ \runtime ->
      fmap transform (runProductionCloudEffects action runtime)

instance Applicative ProductionCloudEffects where
  pure value = ProductionCloudEffects (const (pure value))
  function <*> value =
    ProductionCloudEffects $ \runtime -> do
      transform <- runProductionCloudEffects function runtime
      input <- runProductionCloudEffects value runtime
      pure (transform input)

instance Monad ProductionCloudEffects where
  action >>= next =
    ProductionCloudEffects $ \runtime -> do
      value <- runProductionCloudEffects action runtime
      runProductionCloudEffects (next value) runtime

instance LifecycleTeardownEffects ProductionCloudEffects where
  executeLifecycleTeardownOperation context operation =
    ProductionCloudEffects $ \runtime -> do
      dispatched <- executeCloudOperation runtime context operation
      pure
        ( case dispatched of
            Just result -> result
            Nothing ->
              TeardownNodeRefused "the suite drove a non-cloud operation"
        )

-- ---------------------------------------------------------------------------
-- The fake wire
-- ---------------------------------------------------------------------------

-- | Records the route of every authenticated call and answers each with the
-- Authority being unavailable.  Recording the route rather than the payload
-- keeps this fixture free of any secret-shaped bytes.
fakeAuthorityTransport
  :: IORef [Text]
  -> Either Text (AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
fakeAuthorityTransport calls = do
  endpoint <-
    firstShow
      ( mkLifecycleAuthorityEndpoint
          ( "http://lifecycle-authority:"
              <> Text.pack (show controlPlaneListenPort)
          )
      )
  rawClient <-
    firstShow
      ( controlPlaneClientWithTransport
          maximumFakeResponseBytes
          endpoint
          ( \_ _ url _ ->
              recordRoute url
                >> pure
                  ( Right
                      ( replyStatusCode ReplyServiceUnavailable
                      , ByteString.empty
                      )
                  )
          )
      )
  bounds <-
    firstShow
      ( mkAuthenticatedTransportBounds
          maximumFakeResponseBytes
          256
          (maximumFakeResponseBytes - 1024)
      )
  providers <- fakeClientProviders
  Right (mkAuthenticatedClientTransport bounds providers rawClient)
 where
  -- The URL is the route the client selected.  Recording it rather than the
  -- payload keeps this fixture free of any secret-shaped bytes.
  recordRoute :: String -> IO ()
  recordRoute url = modifyIORef' calls (<> [Text.take 256 (Text.pack url)])

maximumFakeResponseBytes :: Int
maximumFakeResponseBytes = 1_048_576

fakeClientProviders :: Either Text (AuthenticatedClientProviders IO)
fakeClientProviders = do
  generation <- firstShow (mkSigningKeyGeneration 1)
  signer <-
    firstShow
      ( mkRequestSigner
          CallerOperatorCli
          generation
          (ByteString.pack [0 .. 31])
      )
  nonce <- firstShow (mkRequestNonce (ByteString.pack [32 .. 47]))
  scope <- firstShow (mkAuthorityScope "cluster-a")
  Right
    AuthenticatedClientProviders
      { provideAuthenticatedClientSigner =
          pure (Right (localRequestSigningCapability signer))
      , provideAuthenticatedClientScope = pure (Right scope)
      , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
      , provideAuthenticatedClientDeadline =
          pure (Right (authorityTimeFromMicros 2_000))
      , provideAuthenticatedClientNonce = pure (Right nonce)
      }

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------

-- | The compiled cascade nodes the cloud runtime claims.  The recovery-plane,
-- audit, report, and host nodes belong to other runtimes and are deliberately
-- not driven here.
cloudOwnedPlans
  :: CompiledDesiredAbsenceProgram surface -> [CleanupNodePlan]
cloudOwnedPlans compiled =
  [ plan
  | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
  , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
  , isCloudOwned operation
  ]

-- | The cloud-owned nodes whose target is an AWS resource.  The registered
-- observe arm also answers for the local RKE2 foundation, which is a host
-- observation and reaches no Authority at all; including it here would measure
-- the local observer rather than the cloud runtime.
awsScopedCloudPlans
  :: CompiledDesiredAbsenceProgram surface -> [CleanupNodePlan]
awsScopedCloudPlans compiled =
  [ plan
  | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
  , Just operation <- [compiledOperationForNode (cleanupNodeId plan) compiled]
  , isCloudOwned operation
  , operationTargetsAws operation
  ]

operationTargetsAws :: TeardownOperation surface -> Bool
operationTargetsAws operation = case operation of
  ObserveRegisteredTarget target -> notLocalFoundation target
  ReconcileRegisteredTargetAbsent target -> notLocalFoundation target
  ReadBackRegisteredTargetAbsent target -> notLocalFoundation target
  _ -> True
 where
  notLocalFoundation target = registeredTargetKey target /= LocalLinuxRke2Key

succeedingTags
  :: CompiledDesiredAbsenceProgram surface
  -> [CleanupNodeOutcome]
  -> [Text]
succeedingTags compiled outcomes =
  [ tag
  | (tag, outcome) <-
      zip (map (tagFor compiled) (awsScopedCloudPlans compiled)) outcomes
  , outcome == CleanupNodeSucceeded
  ]

tagFor :: CompiledDesiredAbsenceProgram surface -> CleanupNodePlan -> Text
tagFor compiled plan =
  maybe "?" teardownOperationTag (compiledOperationForNode (cleanupNodeId plan) compiled)

isCloudOwned :: TeardownOperation surface -> Bool
isCloudOwned operation = case operation of
  ObserveRegisteredTarget _ -> True
  ReconcileRegisteredTargetAbsent _ -> True
  ReadBackRegisteredTargetAbsent _ -> True
  ObserveStackCheckpointPair _ -> True
  ReconcileStackCheckpointRestore _ -> True
  ReadBackStackCheckpointRecovery _ -> True
  RetireStackCheckpointPair _ -> True
  ReadBackStackCheckpointRetirement _ -> True
  CommitAwsStackReaderBundle _ -> True
  ReadBackAwsStackReaderBundle _ -> True
  CommitEksDrainIntent _ -> True
  ReadBackEksDrainIntent _ -> True
  DrainEksKubernetesResources _ -> True
  ReadBackEksKubernetesDrain _ -> True
  _ -> False

compiledFor
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
compiledFor surface =
  mustRight
    ( compileDesiredAbsenceGraph
        fixtureRunId
        fixtureFoundation
        (Just fixtureAwsScope)
        Nothing
        surface
    )

authorityEndpointPrefix :: Text
authorityEndpointPrefix =
  "http://lifecycle-authority:" <> Text.pack (show controlPlaneListenPort)

authorityHostOf :: Text -> Text
authorityHostOf url = Text.takeWhile (/= '/') (Text.drop 7 url)

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "production-cloud-runtime-run")

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "home-rke2"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "123456789012")
    (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

isFailedNode :: CleanupNodeOutcome -> Bool
isFailedNode outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

isRight :: Either left right -> Bool
isRight result = case result of
  Right _ -> True
  Left _ -> False

isInfixOfString :: String -> String -> Bool
isInfixOfString needle haystack =
  Text.isInfixOf (Text.pack needle) (Text.pack haystack)

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = either (Left . Text.pack . show) Right

mustRight :: (Show left) => Either left right -> right
mustRight result = case result of
  Left err -> error ("expected Right, got Left " <> show err)
  Right value -> value

mustRightIO :: (Show left) => Either left right -> IO right
mustRightIO result = case result of
  Left err -> expectationFailure (show err) >> fail "expected Right"
  Right value -> pure value
