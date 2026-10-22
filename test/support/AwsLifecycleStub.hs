{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- A bounded stateful account at the existing command/clock seams. Dependency
-- semantics are assumption-labelled until a live canary supplies a recording.
-- The installed-CLI recording supplies error framing, never provider semantics.
module AwsLifecycleStub
  ( AwsLifecycleStub
  , StubFault (..)
  , StubLaw (..)
  , stubLawRecording
  , stubLawAssumed
  , newCanaryStub
  , RecordedDestroyCase (..)
  , newRecordedDestroyStub
  , runLifecycleStubPulumi
  , lifecycleStubDestroyWorld
  , lifecycleStubStackHeld
  , runLifecycleStub
  , lifecycleStubWaits
  , lifecycleStubCalls
  , lifecycleStubCounts
  , setLifecycleStubFault
  , changeLifecycleStubGroupTag
  , configureLifecycleStubEks
  , configureLifecycleStubLoadBalancer
  , advanceLifecycleStubClock
  ) where

import AwsAuditEnumeration qualified as Fixture
import Control.Monad (forM)
import Data.Aeson
  ( Result (..)
  , ToJSON
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , fromJSON
  , object
  , (.=)
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither, withObject, (.:))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.Lifecycle.AwsAudit (AuditClass (..))
import Prodbox.Lifecycle.AwsNativeStackFamily (AwsNativeStackFamilyRunner (..))
import Prodbox.Lifecycle.AwsProviderRecording
import Prodbox.Lifecycle.AwsStackDestroy (StackDestroyWorld (..))
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment (..))
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksProvisionedClusterName
  , awsEksProvisionedNodeGroupName
  , awsEksPulumiStackName
  , awsTestPulumiStackName
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

data StubLaw
  = RecordedCniAndClusterGroupShapes
  | InterfaceHoldsSecurityGroup
  | PeerReferenceHoldsSecurityGroup
  | RequesterManagedReleaseLag
  | SubnetHeldByInterface
  | VpcHeldBySubnet
  | ClusterHeldByNodeGroup
  | LoadBalancerReleaseLag
  deriving stock (Eq, Show, Enum, Bounded)

stubLawRecording :: StubLaw -> FilePath
stubLawRecording law =
  "test/golden/aws-lifecycle/" ++ case law of
    RecordedCniAndClusterGroupShapes -> "operator-inventory-2026-10-14.json"
    InterfaceHoldsSecurityGroup -> "dependency-contract-assumptions.json"
    PeerReferenceHoldsSecurityGroup -> "dependency-contract-assumptions.json"
    RequesterManagedReleaseLag -> "requester-managed-release-assumption.json"
    SubnetHeldByInterface -> "stack-dependency-assumptions.json"
    VpcHeldBySubnet -> "stack-dependency-assumptions.json"
    ClusterHeldByNodeGroup -> "stack-dependency-assumptions.json"
    LoadBalancerReleaseLag -> "stack-dependency-assumptions.json"

stubLawAssumed :: StubLaw -> Bool
stubLawAssumed law = case law of
  RecordedCniAndClusterGroupShapes -> False
  InterfaceHoldsSecurityGroup -> True
  PeerReferenceHoldsSecurityGroup -> True
  RequesterManagedReleaseLag -> True
  SubnetHeldByInterface -> True
  VpcHeldBySubnet -> True
  ClusterHeldByNodeGroup -> True
  LoadBalancerReleaseLag -> True

data StubFault
  = NoStubFault
  | WrongVpcRun
  | WrongSubnetVpc
  | LoseGroupCreateReply
  | LoseInterfaceCreateReply
  | FailAfterMutation !Int
  deriving stock (Eq, Show)

data StubGroup = StubGroup
  { groupId :: !Text
  , groupName :: !Text
  , groupTags :: ![(Text, Text)]
  , groupPeers :: ![Text]
  , groupCluster :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data StubInterface = StubInterface
  { stubInterfaceId :: !Text
  , stubInterfaceHeldGroup :: !Text
  , stubInterfaceDescription :: !Text
  , stubInterfaceTags :: ![(Text, Text)]
  , stubInterfaceManaged :: !Bool
  , stubInterfaceCluster :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data StubLoadBalancer = NoStubLoadBalancer | ActiveStubLoadBalancer | ReleasingStubLoadBalancer !Natural
  deriving stock (Eq, Show)

data StubAccount = StubAccount
  { accountTags :: ![(Text, Text)]
  , accountGroups :: ![StubGroup]
  , accountInterfaces :: ![StubInterface]
  , accountNextIdentity :: !Int
  , accountMutations :: !Int
  , accountFault :: !StubFault
  , accountVpcPresent :: !Bool
  , accountSubnets :: ![Text]
  , accountClusterPresent :: !Bool
  , accountNodeGroupPresent :: !Bool
  , accountLoadBalancer :: !StubLoadBalancer
  , accountStackName :: !Text
  , accountStackHeld :: !Bool
  , accountInterfaceReleaseAt :: !(Maybe Natural)
  }

data AwsLifecycleStub = AwsLifecycleStub
  { stubRequest :: !TestVpcCanaryRequest
  , stubAccount :: !(IORef StubAccount)
  , stubNow :: !(IORef Natural)
  , stubCalls :: !(IORef [[String]])
  , stubDependencyError :: !Text
  , stubAssumedErrors :: !(Map.Map Text Text)
  , stubReleaseDelayMicros :: !Natural
  }

newCanaryStub :: TestVpcCanaryRequest -> IO AwsLifecycleStub
newCanaryStub request = do
  -- Loading the recording is mandatory. A deleted fixture cannot silently
  -- change the stub into an invented provider observation.
  recording <- loadTranscript "test/golden/aws-lifecycle/dependency-cli-loopback.json"
  diagnostic <- case (transcriptOrigin recording, transcriptCalls recording) of
    (InstalledCliLoopback _, call : _) -> pure (recordedStderr call)
    _ -> fail "expected the installed CLI loopback recording"
  assumed <- loadTranscript "test/golden/aws-lifecycle/stack-dependency-assumptions.json"
  delay <- case [ recordedDelayMicros call
                | call <- transcriptCalls assumed
                , recordedOperation call == "describe-load-balancers:released"
                ] of
    [observed] | observed > 0 -> pure observed
    _ -> fail "recorded virtual release delay required"
  let errors = Map.fromList [(recordedOperation call, recordedStderr call) | call <- transcriptCalls assumed]
      binding = testCanaryBinding request
      tags =
        [ ("Name", "aws-test-vpc")
        , ("prodbox.io/managed-by", "prodbox")
        , ("prodbox.io/run-scope", testCanaryStackRunScope binding)
        , ("prodbox.io/submission", testCanaryStackSubmission binding)
        ]
  AwsLifecycleStub request
    <$> newIORef
      StubAccount
        { accountTags = tags
        , accountGroups = []
        , accountInterfaces = []
        , accountNextIdentity = 3
        , accountMutations = 0
        , accountFault = NoStubFault
        , accountVpcPresent = True
        , accountSubnets = [testCanarySubnet request]
        , accountClusterPresent = False
        , accountNodeGroupPresent = False
        , accountLoadBalancer = NoStubLoadBalancer
        , accountStackName = "aws-test"
        , accountStackHeld = True
        , accountInterfaceReleaseAt = Nothing
        }
    <*> newIORef 1000000000
    <*> newIORef []
    <*> pure diagnostic
    <*> pure errors
    <*> pure delay

-- The recording contains normalized observer fields, not reconstructed raw tags.
-- The VPC/subnet and stack record around those fields are authored model state.
-- The managed variant layers the explicitly unmeasured release assumption on it.
data RecordedDestroyCase = RecordedCniAndGroup | RecordedOrphanGroup | AssumedManagedInterface
  deriving stock (Eq, Show)

newRecordedDestroyStub :: RecordedDestroyCase -> IO AwsLifecycleStub
newRecordedDestroyStub replay = do
  transcript <- loadTranscript (stubLawRecording RecordedCniAndClusterGroupShapes)
  case transcriptOrigin transcript of
    OperatorInventoryTranscription _ -> pure ()
    _ -> fail "hand-transcribed normalized inventory required"
  interface <- recordedRow transcript "describe-network-interfaces"
  group <- recordedRow transcript "describe-security-groups"
  (identity, vpc, subnet, description, held, owner, cluster) <-
    either fail pure $
      parseEither
        ( withObject "normalized interface" $ \fields ->
            (,,,,,,)
              <$> fields .: "id"
              <*> fields .: "vpc"
              <*> fields .: "subnet"
              <*> fields .: "description"
              <*> fields .: "groups"
              <*> fields .: "owner"
              <*> fields .: "cluster"
        )
        interface
  (status, recordedManaged, kind) <-
    either fail pure $
      parseEither
        ( withObject "normalized interface state" $ \fields ->
            (,,) <$> fields .: "status" <*> fields .: "managed" <*> fields .: "type"
        )
        interface
  if status /= ("available" :: Text) || recordedManaged || kind /= ("interface" :: Text)
    then fail "recorded interface state diverges from the modeled CNI shape"
    else pure ()
  (groupIdentity, groupVpc, name, groupClusterName) <-
    either fail pure $
      parseEither
        ( withObject "normalized group" $ \fields ->
            (,,,) <$> fields .: "id" <*> fields .: "vpc" <*> fields .: "name" <*> fields .: "cluster"
        )
        group
  binding <-
    either (fail . show) pure (mkTestCanaryBinding "recorded-replay" "stack/run" "create/submission")
  request <- either (fail . show) pure (mkTestVpcCanaryRequest vpc subnet binding)
  if held /= [groupIdentity] || groupVpc /= vpc
    then fail "recorded interface/group parent identities differ"
    else pure ()
  stub <- newCanaryStub request
  let managed = replay == AssumedManagedInterface
  release <-
    if managed
      then do
        assumption <- loadTranscript (stubLawRecording RequesterManagedReleaseLag)
        case (transcriptOrigin assumption, transcriptCalls assumption) of
          (AssumedProviderBehaviour _, [_, released])
            | recordedDelayMicros released > 0 ->
                pure (Just (recordedDelayMicros released))
          _ -> fail "explicit delayed-release assumption required"
      else pure Nothing
  -- A relative delay is armed only after the modeled cluster has been removed.
  modifyIORef' (stubAccount stub) $ \account ->
    account
      { accountTags = [("Name", "aws-eks-test-vpc"), ("prodbox.io/managed-by", "prodbox")]
      , accountGroups = [StubGroup groupIdentity name [] [] (Just groupClusterName)]
      , accountInterfaces =
          [ StubInterface identity groupIdentity description [("eks:eni:owner", owner)] managed (Just cluster)
          | replay /= RecordedOrphanGroup
          ]
      , accountStackName = "aws-eks"
      , accountClusterPresent = True
      , accountNodeGroupPresent = True
      , accountInterfaceReleaseAt = release
      }
  pure stub
 where
  recordedRow transcript operation = case [recordedStdout call | call <- transcriptCalls transcript, recordedOperation call == operation] of
    [payload] -> case eitherDecodeStrict' (TextEncoding.encodeUtf8 payload) of
      Right [row] -> pure row
      _ -> fail "one normalized recorded row required"
    _ -> fail "one recorded operation required"

-- Reuse the audit fixture's pure read projection; all mutable dependencies and
-- parent identities live in this account, independently of the cleanup predicate.
asAuditWorld :: AwsLifecycleStub -> StubAccount -> Fixture.World
asAuditWorld stub account =
  Fixture.emptyWorld
    { Fixture.worldVpc = if accountVpcPresent account then Just vpc else Nothing
    , Fixture.worldPlanted = subnets ++ groups ++ interfaces ++ owners ++ balancers
    }
 where
  vpc = testCanaryVpc (stubRequest stub)
  row class' identity fields named = Fixture.Planted class' identity (("vpc", vpc) : fields) named
  subnets = [row AuditSubnet identity [("state", "available")] True | identity <- accountSubnets account]
  groups =
    [ row
        AuditSecurityGroup
        (groupId group)
        (("name", groupName group) : maybe [] (\cluster -> [("cluster", cluster)]) (groupCluster group))
        False
    | group <- accountGroups account
    ]
  interfaces =
    [ row
        AuditNetworkInterface
        (stubInterfaceId interface)
        [ ("status", if stubInterfaceManaged interface then "in-use" else "available")
        , ("requester_managed", if stubInterfaceManaged interface then "true" else "false")
        , ("type", "interface")
        , ("description", stubInterfaceDescription interface)
        ]
        False
    | interface <- accountInterfaces account
    ]
  owners =
    [row AuditEksCluster awsEksProvisionedClusterName [] True | accountClusterPresent account]
      ++ [row AuditEksNodeGroup awsEksProvisionedNodeGroupName [] True | accountNodeGroupPresent account]
  balancers =
    [ row AuditLoadBalancer "recording-load-balancer" [("state", "active")] False
    | accountLoadBalancer account /= NoStubLoadBalancer
    ]

pulumiStackName :: StubAccount -> Text
pulumiStackName account = if accountStackName account == "aws-eks" then awsEksPulumiStackName else awsTestPulumiStackName

lifecycleStubStackHeld :: AwsLifecycleStub -> IO Bool
lifecycleStubStackHeld stub = accountStackHeld <$> readIORef (stubAccount stub)

-- A checkpoint owns the stack parents; controller-created children are absent
-- from it. Each delete goes through the same independently stateful AWS model.
runLifecycleStubPulumi :: AwsLifecycleStub -> [String] -> IO ProcessOutput
runLifecycleStubPulumi stub arguments = do
  modifyIORef' (stubCalls stub) (++ ["pulumi" : arguments])
  account <- readIORef (stubAccount stub)
  let stack = Text.unpack (pulumiStackName account)
      selected = flag "--stack" arguments == stack
  if not selected
    then pure (failed "unexpected stack identity")
    else case take 2 arguments of
      ["stack", "select"] ->
        pure
          ( if accountStackHeld account
              then json (object [])
              else failed "error: no stack named 'recorded-replay' found"
          )
      ["stack", "output"] ->
        pure
          ( json
              ( object
                  ["vpc_id" .= if accountVpcPresent account then String (testCanaryVpc (stubRequest stub)) else Null]
              )
          )
      ["stack", "rm"] ->
        if accountVpcPresent account || not (null (accountGroups account) && null (accountInterfaces account))
          then pure (failed "stack parents or controller children remain")
          else
            modifyIORef' (stubAccount stub) (\current -> current {accountStackHeld = False})
              >> pure (json (object []))
      "cancel" : _ -> pure (json (object []))
      "destroy" : _ -> do
        ownerOutputs <-
          if accountStackName account == "aws-eks"
            then do
              node <-
                runLifecycleStub
                  stub
                  [ "eks"
                  , "delete-nodegroup"
                  , "--cluster-name"
                  , Text.unpack awsEksProvisionedClusterName
                  , "--nodegroup-name"
                  , Text.unpack awsEksProvisionedNodeGroupName
                  ]
              cluster <-
                runLifecycleStub stub ["eks", "delete-cluster", "--name", Text.unpack awsEksProvisionedClusterName]
              pure [node, cluster]
            else pure []
        subnetOutputs <- forM (accountSubnets account) $ \identity -> runLifecycleStub stub ["ec2", "delete-subnet", "--subnet-id", Text.unpack identity]
        vpcOutput <-
          if accountVpcPresent account
            then
              runLifecycleStub
                stub
                ["ec2", "delete-vpc", "--vpc-id", Text.unpack (testCanaryVpc (stubRequest stub))]
            else pure (json (object []))
        pure $ case [ output
                    | output <- ownerOutputs ++ subnetOutputs ++ [vpcOutput]
                    , processExitCode output /= ExitSuccess
                    ] of
          [] -> json (object [])
          failures -> failed (concatMap processStderr failures)
      _ -> pure (failed "unsupported modeled Pulumi operation")

lifecycleStubDestroyWorld :: AwsLifecycleStub -> IO (StackDestroyWorld IO)
lifecycleStubDestroyWorld stub = do
  account <- readIORef (stubAccount stub)
  let stack = accountStackName account
  pure
    StackDestroyWorld
      { worldStackName = Text.unpack (pulumiStackName account)
      , worldPulumi = const (runLifecycleStubPulumi stub)
      , worldPulumiShort = runLifecycleStubPulumi stub
      , worldAws = AwsNativeStackFamilyRunner (runLifecycleStub stub)
      , worldWaits = lifecycleStubWaits stub
      , worldFinalPassReserveMicros = 60000000
      , worldRef = Fixture.refFor stack
      , worldConfig = Fixture.configFor stack
      , worldCluster = if stack == "aws-eks" then Just awsEksProvisionedClusterName else Nothing
      , worldLoadBalancers = Nothing
      }

loadTranscript :: FilePath -> IO ProviderTranscript
loadTranscript path = do
  bytes <- ByteString.readFile path
  value <- either fail pure (eitherDecodeStrict' bytes)
  case value of
    Object fields -> case KeyMap.lookup "transcript" fields of
      Just transcript -> case fromJSON transcript of
        Success decoded -> do
          let expectedVersion = Just (String recordingScrubberVersion)
              expectedDigest =
                Just
                  ( String
                      ( TextEncoding.decodeUtf8
                          (hexSha256 (LazyByteString.toStrict (encode (decoded :: ProviderTranscript))))
                      )
                  )
          if KeyMap.lookup "scrubber" fields == expectedVersion
            && KeyMap.lookup "payload_sha256" fields == expectedDigest
            then pure decoded
            else fail "recording scrubber version or payload digest differs"
        Error detail -> fail detail
      Nothing -> fail "recording has no transcript"
    _ -> fail "recording is not an object"

lifecycleStubWaits :: AwsLifecycleStub -> AwsWaitEnvironment IO
lifecycleStubWaits stub =
  AwsWaitEnvironment
    { awsWaitNowMicros = Right <$> readIORef (stubNow stub)
    , awsWaitPauseMicros = \micros -> modifyIORef' (stubNow stub) (+ micros)
    , awsWaitSessionExpiresAtMicros = 1000000000 + 2 * providerWorkerIntentLifetimeMicros
    , awsWaitIntentLifetimeMicros = providerWorkerIntentLifetimeMicros
    }

lifecycleStubCalls :: AwsLifecycleStub -> IO [[String]]
lifecycleStubCalls = readIORef . stubCalls

lifecycleStubCounts :: AwsLifecycleStub -> IO (Int, Int)
lifecycleStubCounts stub = do
  account <- readIORef (stubAccount stub)
  pure (length (accountGroups account), length (accountInterfaces account))

setLifecycleStubFault :: AwsLifecycleStub -> StubFault -> IO ()
setLifecycleStubFault stub fault = modifyIORef' (stubAccount stub) (\account -> account {accountFault = fault})

changeLifecycleStubGroupTag :: AwsLifecycleStub -> CanaryGroupShape -> Text -> Text -> IO ()
changeLifecycleStubGroupTag stub shape key value = modifyIORef' (stubAccount stub) $ \account ->
  account {accountGroups = map change (accountGroups account)}
 where
  change group
    | groupName group == canaryGroupName (testCanaryBinding (stubRequest stub)) shape =
        group {groupTags = (key, value) : filter ((/= key) . fst) (groupTags group)}
    | otherwise = group

configureLifecycleStubEks :: AwsLifecycleStub -> IO ()
configureLifecycleStubEks stub = modifyIORef' (stubAccount stub) $ \account ->
  account {accountClusterPresent = True, accountNodeGroupPresent = True}

configureLifecycleStubLoadBalancer :: AwsLifecycleStub -> IO ()
configureLifecycleStubLoadBalancer stub = modifyIORef' (stubAccount stub) $ \account ->
  account {accountLoadBalancer = ActiveStubLoadBalancer}

advanceLifecycleStubClock :: AwsLifecycleStub -> Natural -> IO ()
advanceLifecycleStubClock stub micros = modifyIORef' (stubNow stub) (+ micros)

runLifecycleStub :: AwsLifecycleStub -> [String] -> IO ProcessOutput
runLifecycleStub stub arguments = do
  modifyIORef' (stubCalls stub) (++ [arguments])
  modifyIORef' (stubNow stub) (+ 1000000)
  now <- readIORef (stubNow stub)
  modifyIORef' (stubAccount stub) $ \account ->
    let released = case accountLoadBalancer account of
          ReleasingStubLoadBalancer at | now >= at -> account {accountLoadBalancer = NoStubLoadBalancer}
          _ -> account
     in case accountInterfaceReleaseAt released of
          Just at
            | not (accountClusterPresent released) && now >= at ->
                released {accountInterfaces = [], accountInterfaceReleaseAt = Nothing}
          _ -> released
  account <- readIORef (stubAccount stub)
  case accountFault account of
    FailAfterMutation count | accountMutations account >= count -> pure (failed "injected interruption boundary")
    _ -> execute account
 where
  request = stubRequest stub
  expectedVpc = testCanaryVpc request
  expectedSubnet = testCanarySubnet request
  execute account = case take 2 arguments of
    ["ec2", "describe-vpcs"] | flag "--query" arguments == "Vpcs[].{id:VpcId,tags:Tags}" -> do
      let tags = case accountFault account of
            WrongVpcRun ->
              ("prodbox.io/run-scope", "other-run")
                : filter ((/= "prodbox.io/run-scope") . fst) (accountTags account)
            _ -> accountTags account
      pure $ json [object ["id" .= expectedVpc, "tags" .= tagsValue tags] | accountVpcPresent account]
    ["ec2", "describe-subnets"]
      | not (null (flag "--subnet-ids" arguments)) ->
          pure $
            json
              [ object
                  [ "id" .= expectedSubnet
                  , "vpc" .= (if accountFault account == WrongSubnetVpc then "vpc-00000000000000099" else expectedVpc)
                  ]
              | expectedSubnet `elem` accountSubnets account
              ]
    ["ec2", "describe-security-groups"]
      | "vpc:VpcId" `Text.isInfixOf` Text.pack (flag "--query" arguments) ->
          pure $ json (map groupValue (accountGroups account))
    ["ec2", "describe-network-interfaces"]
      | "vpc:VpcId" `Text.isInfixOf` Text.pack (flag "--query" arguments) ->
          pure $ json (map interfaceValue (accountInterfaces account))
    ["ec2", "delete-subnet"] -> do
      let identity = Text.pack (flag "--subnet-id" arguments)
      if identity `notElem` accountSubnets account
        then pure (failed "InvalidSubnetID.NotFound")
        else
          if identity == expectedSubnet && not (null (accountInterfaces account))
            then pure (assumedFailure "delete-subnet")
            else
              mutated account {accountSubnets = filter (/= identity) (accountSubnets account)} (json (object []))
    ["ec2", "delete-vpc"] ->
      if Text.pack (flag "--vpc-id" arguments) /= expectedVpc || not (accountVpcPresent account)
        then pure (failed "InvalidVpcID.NotFound")
        else
          if not
            (null (accountSubnets account) && null (accountInterfaces account) && null (accountGroups account))
            then pure (assumedFailure "delete-vpc")
            else mutated account {accountVpcPresent = False} (json (object []))
    ["eks", "delete-nodegroup"] ->
      if flag "--cluster-name" arguments /= Text.unpack awsEksProvisionedClusterName
        || flag "--nodegroup-name" arguments /= Text.unpack awsEksProvisionedNodeGroupName
        then pure (failed "wrong node-group identity")
        else mutated account {accountNodeGroupPresent = False} (json (object []))
    ["eks", "delete-cluster"] ->
      if flag "--name" arguments /= Text.unpack awsEksProvisionedClusterName
        then pure (failed "wrong cluster identity")
        else
          if accountNodeGroupPresent account
            then pure (assumedFailure "delete-cluster")
            else do
              now <- readIORef (stubNow stub)
              let release =
                    if accountClusterPresent account
                      then (+ now) <$> accountInterfaceReleaseAt account
                      else accountInterfaceReleaseAt account
              mutated
                account {accountClusterPresent = False, accountInterfaceReleaseAt = release}
                (json (object []))
    ["elbv2", "delete-load-balancer"] -> do
      now <- readIORef (stubNow stub)
      let next = case accountLoadBalancer account of
            ActiveStubLoadBalancer -> ReleasingStubLoadBalancer (now + stubReleaseDelayMicros stub)
            retained -> retained
      mutated account {accountLoadBalancer = next} (json (object []))
    ["ec2", "create-tags"] -> do
      let tags = map parseTag (drop 1 (dropWhile (/= "--tags") arguments))
      if flag "--resources" arguments /= Text.unpack expectedVpc || any (Text.null . fst) tags
        then pure (failed "wrong tag resource")
        else
          mutated
            account
              { accountTags = Map.toList (Map.union (Map.fromList tags) (Map.fromList (accountTags account)))
              }
            (json (object []))
    ["ec2", "create-security-group"] -> do
      let name = Text.pack (flag "--group-name" arguments)
      if not (accountVpcPresent account)
        || flag "--vpc-id" arguments /= Text.unpack expectedVpc
        || any ((== name) . groupName) (accountGroups account)
        then pure (failed "group create refused")
        else case specificationTags arguments of
          Left detail -> pure (failed detail)
          Right tags -> do
            let identity = identifier "sg-" (accountNextIdentity account)
                group = StubGroup identity name tags [] Nothing
                updated =
                  account
                    { accountGroups = accountGroups account ++ [group]
                    , accountNextIdentity = accountNextIdentity account + 1
                    }
                reply =
                  if accountFault account == LoseGroupCreateReply
                    then failed "injected create response loss"
                    else json (object ["GroupId" .= identity])
            mutated updated reply
    ["ec2", "create-network-interface"] -> case specificationTags arguments of
      Left detail -> pure (failed detail)
      Right tags -> do
        let held = Text.pack (flag "--groups" arguments)
            identity = identifier "eni-" (accountNextIdentity account)
            interface = StubInterface identity held (Text.pack (flag "--description" arguments)) tags False Nothing
        if not (accountVpcPresent account)
          || expectedSubnet `notElem` accountSubnets account
          || flag "--subnet-id" arguments /= Text.unpack expectedSubnet
          || not (any ((== held) . groupId) (accountGroups account))
          then pure (failed "interface create refused")
          else do
            let updated =
                  account
                    { accountInterfaces = accountInterfaces account ++ [interface]
                    , accountNextIdentity = accountNextIdentity account + 1
                    }
                reply =
                  if accountFault account == LoseInterfaceCreateReply
                    then failed "injected create response loss"
                    else json (object ["NetworkInterfaceId" .= identity])
            mutated updated reply
    ["ec2", "authorize-security-group-ingress"] -> alterPeer True account
    ["ec2", "revoke-security-group-ingress"] -> alterPeer False account
    ["ec2", "delete-network-interface"] -> do
      let identity = Text.pack (flag "--network-interface-id" arguments)
      if any
        (\interface -> stubInterfaceId interface == identity && stubInterfaceManaged interface)
        (accountInterfaces account)
        then pure (failed "OperationNotPermitted: requester-managed interface")
        else
          if any ((== identity) . stubInterfaceId) (accountInterfaces account)
            then
              mutated
                account {accountInterfaces = filter ((/= identity) . stubInterfaceId) (accountInterfaces account)}
                (json (object []))
            else pure (failed "InvalidNetworkInterfaceID.NotFound")
    ["ec2", "delete-security-group"] -> do
      let identity = Text.pack (flag "--group-id" arguments)
          held =
            any ((== identity) . stubInterfaceHeldGroup) (accountInterfaces account)
              || any (elem identity . groupPeers) (accountGroups account)
      if held
        then pure (failed (Text.unpack (stubDependencyError stub)))
        else
          if any ((== identity) . groupId) (accountGroups account)
            then
              mutated
                account {accountGroups = filter ((/= identity) . groupId) (accountGroups account)}
                (json (object []))
            else pure (failed "InvalidGroup.NotFound")
    _ -> pure (Fixture.respond (asAuditWorld stub account) arguments)
  assumedFailure operation = case Map.lookup operation (stubAssumedErrors stub) of
    Just diagnostic -> failed (Text.unpack diagnostic)
    Nothing -> failed "no recorded law for this stub refusal"
  mutated updated output = do
    modifyIORef' (stubAccount stub) (const updated {accountMutations = accountMutations updated + 1})
    pure output
  alterPeer add account = case permissionPeer (flag "--ip-permissions" arguments) of
    Left detail -> pure (failed detail)
    Right peer -> do
      let identity = Text.pack (flag "--group-id" arguments)
      if not (any ((== identity) . groupId) (accountGroups account))
        then pure (failed "InvalidGroup.NotFound")
        else
          mutated
            account {accountGroups = map (change identity peer) (accountGroups account)}
            (json (object []))
     where
      change identity selectedPeer group
        | groupId group == identity =
            group
              { groupPeers =
                  if add
                    then nub (groupPeers group ++ [selectedPeer])
                    else filter (/= selectedPeer) (groupPeers group)
              }
        | otherwise = group
  groupValue group =
    object
      [ "id" .= groupId group
      , "vpc" .= expectedVpc
      , "name" .= groupName group
      , "tags" .= tagsValue (groupTags group)
      , "cluster" .= groupCluster group
      , "ingress"
          .= [ object
                 [ "protocol" .= ("tcp" :: Text)
                 , "from" .= (443 :: Int)
                 , "to" .= (443 :: Int)
                 , "peers" .= [peer]
                 , "ipv4" .= ([] :: [Text])
                 , "ipv6" .= ([] :: [Text])
                 , "prefixes" .= ([] :: [Text])
                 ]
             | peer <- groupPeers group
             ]
      ]
  interfaceValue interface =
    object
      [ "id" .= stubInterfaceId interface
      , "vpc" .= expectedVpc
      , "subnet" .= expectedSubnet
      , "status" .= (if stubInterfaceManaged interface then "in-use" else "available" :: Text)
      , "managed" .= stubInterfaceManaged interface
      , "requester_managed" .= stubInterfaceManaged interface
      , "attachment" .= Null
      , "type" .= ("interface" :: Text)
      , "description" .= stubInterfaceDescription interface
      , "groups" .= [stubInterfaceHeldGroup interface]
      , "tags" .= tagsValue (stubInterfaceTags interface)
      , "owner" .= lookup "eks:eni:owner" (stubInterfaceTags interface)
      , "cluster" .= stubInterfaceCluster interface
      ]

flag :: String -> [String] -> String
flag name arguments = case dropWhile (/= name) arguments of
  _ : value : _ -> value
  _ -> ""

parseTag :: String -> (Text, Text)
parseTag raw = case Text.splitOn ",Value=" (Text.pack raw) of
  [key, value] -> (fromMaybe "" (Text.stripPrefix "Key=" key), value)
  _ -> ("", "")

specificationTags :: [String] -> Either String [(Text, Text)]
specificationTags arguments = do
  value <-
    eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack (flag "--tag-specifications" arguments)))
  case value of
    Array specifications | Vector.length specifications == 1 -> case Vector.toList specifications of
      [Object fields] -> case KeyMap.lookup "Tags" fields of
        Just (Array tags) -> traverse tag (Vector.toList tags)
        _ -> Left "tags required"
      _ -> Left "tag specification required"
    _ -> Left "one tag specification required"
 where
  tag (Object fields) = case (KeyMap.lookup "Key" fields, KeyMap.lookup "Value" fields) of
    (Just (String key), Just (String value)) -> Right (key, value)
    _ -> Left "tag key/value required"
  tag _ = Left "tag object required"

permissionPeer :: String -> Either String Text
permissionPeer raw = do
  value <- eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack raw))
  case value of
    Array permissions -> case Vector.toList permissions of
      [Object fields] -> case KeyMap.lookup "UserIdGroupPairs" fields of
        Just (Array pairs) -> case Vector.toList pairs of
          [Object pair] -> case KeyMap.lookup "GroupId" pair of
            Just (String peer) -> Right peer
            _ -> Left "group peer required"
          _ -> Left "one group peer required"
        _ -> Left "group peer list required"
      _ -> Left "one permission required"
    _ -> Left "permission list required"

identifier :: Text -> Int -> Text
identifier prefix index =
  let suffix = Text.pack (showHex index "")
   in prefix <> Text.replicate (17 - Text.length suffix) "0" <> suffix

tagsValue :: [(Text, Text)] -> Value
tagsValue tags = toJsonValue [object ["Key" .= key, "Value" .= value] | (key, value) <- tags]

toJsonValue :: (ToJSON a) => a -> Value
toJsonValue value = case eitherDecodeStrict' (LazyByteString.toStrict (encode value)) of
  Right decoded -> decoded
  Left detail -> error detail

json :: (ToJSON a) => a -> ProcessOutput
json value =
  ProcessOutput
    ExitSuccess
    (Text.unpack (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode value))))
    ""

failed :: String -> ProcessOutput
failed = ProcessOutput (ExitFailure 254) ""
