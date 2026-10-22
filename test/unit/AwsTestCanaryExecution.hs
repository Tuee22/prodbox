{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsTestCanaryExecution (awsTestCanaryExecutionSuite) where

import AwsCanaryFixtures
import AwsLifecycleStub
import Control.Monad (forM_)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.CliError (awsCliServiceErrorMatches)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.AwsDestroyConverge
  ( ConvergeOutcome (..)
  , DestroyPass (..)
  , PassResult (..)
  )
import Prodbox.Lifecycle.AwsNetworkDependents
import Prodbox.Lifecycle.AwsProviderRecording
import Prodbox.Lifecycle.AwsStackDestroy (StackDestroyWorld (..), pulumiDestroyPass, stackDestroy)
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Lifecycle.AwsTestCanaryExecution
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment (..))
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

awsTestCanaryExecutionSuite :: SuiteBuilder ()
awsTestCanaryExecutionSuite = describe "Sprint 5.59 stateful canary plant and native cleanup" $ do
  it "normalizes optional EC2 rule arrays using the recorded installed-CLI query" $ do
    bytes <- ByteString.readFile "test/golden/aws-lifecycle/network-projections-cli-loopback.json"
    transcript <- case must (eitherDecodeStrict' bytes) of
      Object envelope -> case KeyMap.lookup "transcript" envelope of
        Just value -> case fromJSON value of
          Success decoded -> pure decoded
          Error detail -> error detail
        Nothing -> error "recording transcript required"
      _ -> error "recording envelope required"
    let digest =
          TextEncoding.decodeUtf8 (hexSha256 (TextEncoding.encodeUtf8 (Text.pack canarySecurityGroupsQuery)))
    case transcriptOrigin transcript of
      InstalledCliLoopback detail -> detail `shouldSatisfy` Text.isInfixOf digest
      _ -> error "installed CLI fixture required"
    let captured label = case [call | call <- transcriptCalls transcript, recordedOperation call == label] of
          [call] -> case must (eitherDecodeStrict' (TextEncoding.encodeUtf8 (recordedStdout call))) of
            Array rows -> foldr (:) [] rows
            _ -> error "recorded rows required"
          _ -> error "recorded call required"
        field key rows = case rows of
          [Object fields] -> KeyMap.lookup key fields
          _ -> Nothing
    field "ingress" (captured "describe-security-groups:old-empty") `shouldBe` Just Null
    field "ingress" (captured "describe-security-groups:normalized-empty")
      `shouldBe` Just (Array mempty)
    case field "ingress" (captured "describe-security-groups:normalized-peer") of
      Just (Array permissions) -> case foldr (:) [] permissions of
        [Object rule] -> forM_ ["ipv4", "ipv6", "prefixes"] $ \key ->
          KeyMap.lookup key rule `shouldBe` Just (Array mempty)
        _ -> error "one recorded peer rule required"
      _ -> error "recorded ingress required"
  it "plants exactly three groups and one unattached interface and captures both dependency refusals" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    before <- observeTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    fmap canaryPlantComplete before `shouldBe` Right False
    planted <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    fmap (map canaryProbeShape) planted `shouldBe` Right [InterfaceHeldGroup, MutualLeftGroup]
    lifecycleStubCounts stub `shouldReturn` (3, 1)
    after <- observeTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    fmap canaryPlantComplete after `shouldBe` Right True
    calls <- lifecycleStubCalls stub
    take 2 (firstMutation calls) `shouldBe` ["ec2", "create-tags"]
    count "create-security-group" calls `shouldBe` 3
    count "create-network-interface" calls `shouldBe` 1
    count "authorize-security-group-ingress" calls `shouldBe` 2
    count "delete-security-group" calls `shouldBe` 2
    calls `shouldSatisfy` any (elem (Text.unpack (testCanaryClientToken fixtureCanaryRequest)))
  it "repeats the same invocation without duplicating any planted resource" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    first <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    first `shouldSatisfy` either (const False) ((== 2) . length)
    second <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    second `shouldSatisfy` either (const False) ((== 2) . length)
    calls <- lifecycleStubCalls stub
    count "create-security-group" calls `shouldBe` 3
    count "create-network-interface" calls `shouldBe` 1
    lifecycleStubCounts stub `shouldReturn` (3, 1)
  forM_ [LoseGroupCreateReply, LoseInterfaceCreateReply] $ \fault ->
    it ("adopts exact read-back after " ++ show fault) $ do
      stub <- newCanaryStub fixtureCanaryRequest
      setLifecycleStubFault stub fault
      result <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
      result `shouldSatisfy` either (const False) ((== 2) . length)
      lifecycleStubCounts stub `shouldReturn` (3, 1)
      calls <- lifecycleStubCalls stub
      count "create-security-group" calls `shouldBe` 3
      count "create-network-interface" calls `shouldBe` 1
  forM_ [WrongVpcRun, WrongSubnetVpc] $ \fault ->
    it ("refuses " ++ show fault ++ " before any mutation") $ do
      stub <- newCanaryStub fixtureCanaryRequest
      setLifecycleStubFault stub fault
      result <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
      result `shouldSatisfy` isLeft
      calls <- lifecycleStubCalls stub
      firstMutation calls `shouldBe` []
  it "refuses a changed owned tag instead of adopting a neighboring shape" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    _ <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    callsBefore <- lifecycleStubCalls stub
    changeLifecycleStubGroupTag
      stub
      MutualLeftGroup
      "prodbox.io/test-canary-shape"
      "outside-the-closed-list"
    result <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    result `shouldSatisfy` isLeft
    callsAfter <- lifecycleStubCalls stub
    firstMutation (drop (length callsBefore) callsAfter) `shouldBe` []
  it "clears the held interface and mutual group references through the native repair" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    _ <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    repaired <- clearNetworkDependents (runLifecycleStub stub) (lifecycleStubWaits stub) target
    fmap repairRemaining repaired `shouldBe` Right []
    lifecycleStubCounts stub `shouldReturn` (0, 0)
  forM_ [1 .. 7] $ \prefix ->
    it ("cleans the durable families after plant mutation prefix " ++ show prefix) $ do
      stub <- newCanaryStub fixtureCanaryRequest
      setLifecycleStubFault stub (FailAfterMutation prefix)
      result <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
      result `shouldSatisfy` isLeft
      setLifecycleStubFault stub NoStubFault
      repaired <- clearNetworkDependents (runLifecycleStub stub) (lifecycleStubWaits stub) target
      fmap repairRemaining repaired `shouldBe` Right []
      lifecycleStubCounts stub `shouldReturn` (0, 0)
  it "keeps a subnet behind its interface and the VPC behind its subnet" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    _ <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    subnetHeld <-
      runLifecycleStub
        stub
        ["ec2", "delete-subnet", "--subnet-id", Text.unpack (testCanarySubnet fixtureCanaryRequest)]
    awsCliServiceErrorMatches "DependencyViolation" "DeleteSubnet" subnetHeld `shouldBe` True
    vpcHeld <-
      runLifecycleStub
        stub
        ["ec2", "delete-vpc", "--vpc-id", Text.unpack (testCanaryVpc fixtureCanaryRequest)]
    awsCliServiceErrorMatches "DependencyViolation" "DeleteVpc" vpcHeld `shouldBe` True
    _ <- clearNetworkDependents (runLifecycleStub stub) (lifecycleStubWaits stub) target
    subnetGone <-
      runLifecycleStub
        stub
        ["ec2", "delete-subnet", "--subnet-id", Text.unpack (testCanarySubnet fixtureCanaryRequest)]
    processExitCode subnetGone `shouldBe` ExitSuccess
    vpcGone <-
      runLifecycleStub
        stub
        ["ec2", "delete-vpc", "--vpc-id", Text.unpack (testCanaryVpc fixtureCanaryRequest)]
    processExitCode vpcGone `shouldBe` ExitSuccess
  it "keeps an EKS cluster behind its node group in the dependency model" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    configureLifecycleStubEks stub
    held <- runLifecycleStub stub ["eks", "delete-cluster", "--name", "aws-eks-test-cluster"]
    awsCliServiceErrorMatches "ResourceInUseException" "DeleteCluster" held `shouldBe` True
    nodeGone <-
      runLifecycleStub
        stub
        [ "eks"
        , "delete-nodegroup"
        , "--cluster-name"
        , "aws-eks-test-cluster"
        , "--nodegroup-name"
        , "aws-eks-test-node-group"
        ]
    processExitCode nodeGone `shouldBe` ExitSuccess
    clusterGone <- runLifecycleStub stub ["eks", "delete-cluster", "--name", "aws-eks-test-cluster"]
    processExitCode clusterGone `shouldBe` ExitSuccess
  it "keeps a deleting load balancer visible until its recorded virtual release delay" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    configureLifecycleStubLoadBalancer stub
    _ <-
      runLifecycleStub
        stub
        ["elbv2", "delete-load-balancer", "--load-balancer-arn", "recording-load-balancer"]
    advanceLifecycleStubClock stub 45000000
    before <- runLifecycleStub stub ["elbv2", "describe-load-balancers", "--output", "json"]
    processStdout before `shouldSatisfy` (not . null)
    processStdout before `shouldNotBe` "[]"
    advanceLifecycleStubClock stub 90000000
    after <- runLifecycleStub stub ["elbv2", "describe-load-balancers", "--output", "json"]
    processStdout after `shouldBe` "[]"
  it "drives the planted test VPC through the supported two-pass destroy and closing field read" $ do
    stub <- newCanaryStub fixtureCanaryRequest
    planted <- plantTestVpcCanary (runLifecycleStub stub) fixtureCanaryRequest
    planted `shouldSatisfy` either (const False) ((== 2) . length)
    world <- lifecycleStubDestroyWorld stub
    stackDestroy world `shouldReturn` Converged
    lifecycleStubCounts stub `shouldReturn` (0, 0)
    lifecycleStubStackHeld stub `shouldReturn` False
  forM_ [RecordedCniAndGroup, RecordedOrphanGroup, AssumedManagedInterface] $ \replay -> do
    it ("the old single pass leaves the recorded dependency: " ++ show replay) $ do
      stub <- newRecordedDestroyStub replay
      world <- lifecycleStubDestroyWorld stub
      result <- pulumiDestroyPass (worldPulumi world FirstPass) (worldStackName world)
      result `shouldSatisfy` failedPass
      lifecycleStubStackHeld stub `shouldReturn` True
      calls <- lifecycleStubCalls stub
      count "delete-network-interface" calls `shouldBe` 0
      count "delete-security-group" calls `shouldBe` 0
    it ("the supported converging destroy clears the same dependency: " ++ show replay) $ do
      stub <- newRecordedDestroyStub replay
      world <- lifecycleStubDestroyWorld stub
      outcome <- stackDestroy world
      outcome `shouldBe` Converged
      lifecycleStubCounts stub `shouldReturn` (0, 0)
      lifecycleStubStackHeld stub `shouldReturn` False
      calls <- lifecycleStubCalls stub
      let deletedInterfaces = count "delete-network-interface" calls
      deletedInterfaces `shouldBe` (if replay == RecordedCniAndGroup then 1 else 0)
      count "delete-security-group" calls `shouldBe` 1
      length (filter ((== ["pulumi", "destroy"]) . take 2) calls) `shouldBe` 2
      if replay == AssumedManagedInterface
        then do
          now <- awsWaitNowMicros (lifecycleStubWaits stub)
          now `shouldSatisfy` either (const False) (>= 1090000000)
        else pure ()
  it "keeps every law tied to a recording and labels authored semantics/timing as assumptions" $ do
    forM_ [minBound .. maxBound] $ \law -> do
      bytes <- ByteString.readFile (stubLawRecording law)
      transcript <- case must (eitherDecodeStrict' bytes) of
        Object fields -> case KeyMap.lookup "transcript" fields of
          Just value -> case fromJSON value of
            Success decoded -> pure decoded
            Error detail -> expectationFailure detail >> error "unreachable"
          Nothing -> error "recording transcript required"
        _ -> error "recording object required"
      case (stubLawAssumed law, transcriptOrigin transcript) of
        (True, AssumedProviderBehaviour _) -> pure ()
        (False, OperatorInventoryTranscription _) -> pure ()
        other -> expectationFailure ("law provenance mismatch: " ++ show other)
    source <- readFile "test/support/AwsLifecycleStub.hs"
    length (lines source) `shouldSatisfy` (<= 900)

target :: DependentsTarget
target = must (mkDependentsTarget (testCanaryVpc fixtureCanaryRequest) Nothing)

count :: String -> [[String]] -> Int
count operation = length . filter ((== ["ec2", operation]) . take 2)

firstMutation :: [[String]] -> [String]
firstMutation calls = case filter (not . any ("describe-" `isInfixOf`)) calls of
  first : _ -> first
  [] -> []

must :: (Show error) => Either error a -> a
must = either (error . show) id

failedPass :: PassResult -> Bool
failedPass outcome = case outcome of
  PassFailed _ -> True
  PassSucceeded -> False
  PassStackAbsent -> False
