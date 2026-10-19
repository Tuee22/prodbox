{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.110: the audit's enumeration over a scripted AWS account.
--
-- Each case plants a resource in a scripted account and runs the enumeration the
-- Provider will run. The table plants every class of the declared field alone
-- and asks for residue in that class; the controls ask that an account with
-- nothing in it is clean, that a query that does not answer is never read as an
-- empty class, and that a catalog that cannot see its own control proves
-- nothing. The enumeration issues describe, get and list calls and nothing
-- else, which a case asserts over every command it issued.
--
-- The scripted account is an exercised model of how the CLI answers, not a
-- recording of AWS. It shows the mechanism and discharges no gate about what
-- AWS returns ([Unit Testing Policy § 5.1]).
module AwsAuditEnumeration
  ( awsAuditEnumerationSuite
  , World (..)
  , Planted (..)
  , emptyWorld
  , withVpc
  , plant
  , respond
  , vpcId
  , bucket
  , refFor
  , configFor
  , success
  , failure
  , region'
  , mentions
  , queryOf
  )
where

import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy.Char8 qualified as LazyByteStringChar8
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditField
import Prodbox.Lifecycle.AwsNativeStackFamily (AwsNativeStackFamilyRunner (..))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksIamManagedPolicyNames
  , awsEksIamRoleNames
  , awsEksProvisionedClusterName
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

-- | One resource in the scripted account.
data Planted = Planted
  { plantedClass :: AuditClass
  , plantedId :: Text
  , plantedFields :: [(Text, Text)]
  , plantedNamed :: Bool
  -- ^ Carries the name and managed-by tags the stack stamps, so the exact-name
  -- observer finds it too. A child a controller made carries neither.
  }

data World = World
  { worldVpc :: Maybe Text
  , worldPlanted :: [Planted]
  , worldBucketSeen :: Bool
  , worldBroken :: [String]
  -- ^ A command whose words contain any of these is refused.
  , worldVpcTagsLost :: Bool
  -- ^ The VPC exists, but the tags the stack stamped on it are gone, so a
  -- listing by those tags does not return it.
  }

emptyWorld :: World
emptyWorld = World Nothing [] True [] False

vpcId :: Text
vpcId = "vpc-0a1b2c3d4e5f60718"

withVpc :: World -> World
withVpc world = world {worldVpc = Just vpcId}

plant :: AuditClass -> Text -> [(Text, Text)] -> Bool -> World -> World
plant class' identity fields stamped world =
  world {worldPlanted = worldPlanted world <> [Planted class' identity fields stamped]}

success :: String -> ProcessOutput
success stdout = ProcessOutput ExitSuccess stdout ""

failure :: String -> ProcessOutput
failure stderr = ProcessOutput (ExitFailure 254) "" stderr

region' :: String
region' = fixtureAwsRegion FixtureCaCentral1

bucket :: Text
bucket = "prodbox-state-fixture"

-- | Whether a command's words mention the given fragment.
mentions :: String -> [String] -> Bool
mentions fragment = any (fragment `isInfixOf`)

-- | The word that follows a flag.
flagValue :: String -> [String] -> String
flagValue flag arguments = case dropWhile (/= flag) arguments of
  _ : value : _ -> value
  _ -> ""

queryOf :: [String] -> String
queryOf arguments = case dropWhile (/= "--query") arguments of
  _ : value : _ -> value
  _ -> ""

ofClass :: AuditClass -> World -> [Planted]
ofClass class' world = [p | p <- worldPlanted world, plantedClass p == class']

named :: AuditClass -> World -> [Text]
named class' world = [plantedId p | p <- ofClass class' world, plantedNamed p]

-- | The planted resources a describe call's state filter admits, as AWS applies
-- it: all of them when the call names no such filter. Without this the scripted
-- account would show a terminated instance whatever the audit asked for, and a
-- query that dropped its filter would look the same as one that kept it.
admittedByStateFilter :: String -> [String] -> [Planted] -> [Planted]
admittedByStateFilter name arguments planted =
  case [drop (length prefix) argument | argument <- arguments, prefix `isPrefixOf` argument] of
    values : _ ->
      [ p
      | p <- planted
      , maybe True ((`elem` splitStates values) . Text.unpack) (lookup "state" (plantedFields p))
      ]
    [] -> planted
 where
  prefix = "Name=" <> name <> ",Values="
  splitStates = words . map (\character -> if character == ',' then ' ' else character)

-- | The ids a text query prints, one line.
ids :: [Text] -> ProcessOutput
ids values = success (Text.unpack (Text.intercalate "\t" values) <> "\n")

jsonRows :: [Value] -> ProcessOutput
jsonRows = success . LazyByteStringChar8.unpack . encode

projected :: Planted -> [Text] -> Value
projected planted keys =
  object
    ( ("id" .= plantedId planted)
        : [Key.fromText key .= value | key <- keys, Just value <- [lookup key (plantedFields planted)]]
    )

emptyPage :: String
emptyPage = "{\"ResourceTagMappingList\":[],\"PaginationToken\":\"\"}"

-- | How the scripted account answers one command.
respond :: World -> [String] -> ProcessOutput
respond world arguments
  | any (`mentions` arguments) (worldBroken world) =
      failure "An error occurred (AccessDenied) when calling the operation: not authorized"
  | otherwise = case arguments of
      "ec2" : "describe-vpcs" : _
        | worldVpcTagsLost world -> ids []
        | otherwise -> ids (maybe [] pure (worldVpc world))
      "ec2" : "describe-internet-gateways" : _
        | rooted -> jsonRows (map (`projected` []) (ofClass AuditInternetGateway world))
        | otherwise -> ids (named AuditInternetGateway world)
      "ec2" : "describe-route-tables" : _
        | rooted -> jsonRows (map (`projected` []) (ofClass AuditRouteTable world))
        | queryOf arguments == "RouteTables[].RouteTableId" -> ids (named AuditRouteTable world)
        | otherwise -> ids []
      "ec2" : "describe-subnets" : _
        | rooted -> jsonRows (map (`projected` ["state"]) (ofClass AuditSubnet world))
        | otherwise -> ids (nth (nameIndex arguments) (named AuditSubnet world))
      "ec2" : "describe-security-groups" : _
        | queryOf arguments == "SecurityGroups[].VpcId" ->
            ids [vpcOfPlanted world p | p <- ofClass AuditSecurityGroup world, hasClusterMark p]
        | rooted -> jsonRows (map (`projected` ["name"]) (ofClass AuditSecurityGroup world))
        | mentions "aws:eks:cluster-name" arguments -> ids []
        | otherwise -> ids (take 1 (named AuditSecurityGroup world))
      "ec2" : "describe-instances" : _
        | rooted ->
            jsonRows
              ( map
                  (`projected` ["state"])
                  (admittedByStateFilter "instance-state-name" arguments (ofClass AuditInstance world))
              )
        | otherwise -> ids (nth (nameIndex arguments) (named AuditInstance world))
      "ec2" : "describe-network-interfaces" : _
        | queryOf arguments == "NetworkInterfaces[].VpcId" ->
            ids [vpcOfPlanted world p | p <- ofClass AuditNetworkInterface world, hasClusterMark p]
        | otherwise ->
            jsonRows
              ( map
                  (`projected` ["status", "requester_managed", "type", "description"])
                  (ofClass AuditNetworkInterface world)
              )
      "ec2" : "describe-nat-gateways" : _ ->
        jsonRows
          ( map
              (`projected` ["state"])
              (admittedByStateFilter "state" arguments (ofClass AuditNatGateway world))
          )
      "ec2" : "describe-vpc-endpoints" : _ ->
        jsonRows (map (`projected` ["state", "service"]) (ofClass AuditVpcEndpoint world))
      "elbv2" : "describe-load-balancers" : _ ->
        jsonRows
          [ loadBalancer p
          | p <- ofClass AuditLoadBalancer world
          , lookup "kind" (plantedFields p) /= Just "classic"
          ]
      "elb" : "describe-load-balancers" : _ ->
        jsonRows
          [ loadBalancer p
          | p <- ofClass AuditLoadBalancer world
          , lookup "kind" (plantedFields p) == Just "classic"
          ]
      "ec2" : "describe-volumes" : _ ->
        success
          ( LazyByteStringChar8.unpack
              ( encode
                  ( object
                      [ "Volumes"
                          .= [ object
                                 ["VolumeId" .= plantedId p, "State" .= maybe "available" id (lookup "state" (plantedFields p))]
                             | p <- ofClass AuditEbsVolume world
                             ]
                      ]
                  )
              )
          )
      "eks" : "describe-cluster" : _
        | null (ofClass AuditEksCluster world) ->
            failure "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation"
        | otherwise ->
            success
              ( "arn:aws:eks:"
                  <> region'
                  <> ":123456789012:cluster/aws-eks-test-cluster https://oidc.eks."
                  <> region'
                  <> ".amazonaws.com/id/ABC\n"
              )
      "eks" : "describe-nodegroup" : _
        | null (ofClass AuditEksNodeGroup world) ->
            failure "An error occurred (ResourceNotFoundException) when calling the DescribeNodegroup operation"
        | otherwise ->
            success ("arn:aws:eks:" <> region' <> ":123456789012:nodegroup/aws-eks-test-node-group\n")
      "eks" : "describe-addon" : _
        | null (ofClass AuditEksAddon world) ->
            failure "An error occurred (ResourceNotFoundException) when calling the DescribeAddon operation"
        | otherwise -> success ("arn:aws:eks:" <> region' <> ":123456789012:addon/aws-ebs-csi-driver\n")
      "route53" : "get-hosted-zone" : _
        | null (ofClass AuditHostedZone world) ->
            failure "An error occurred (NoSuchHostedZone) when calling the GetHostedZone operation"
        | otherwise -> success "/hostedzone/ZSUBZONE123\tAWS.EXAMPLE.TEST.\n"
      "route53" : "list-resource-record-sets" : _
        | null (ofClass AuditDelegationRecord world) -> success ""
        | otherwise -> success "aws.example.test.\tNS\n"
      "iam" : "get-role" : _ -> iamNamed AuditIamRole "--role-name"
      "iam" : "get-policy" : _ -> iamNamed AuditIamPolicy "--policy-arn"
      "resourcegroupstaggingapi" : _
        | mentions "iam:oidc-provider" arguments ->
            success
              ( "{\"ResourceTagMappingList\":["
                  <> intercalate
                    ","
                    [ "{\"ResourceARN\":\""
                        <> Text.unpack (plantedId p)
                        <> "\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"aws-eks-test-oidc-provider\"}]}"
                    | p <- ofClass AuditOidcProvider world
                    ]
                  <> "],\"PaginationToken\":\"\"}"
              )
        | mentions "long-lived-pulumi-state" arguments && worldBucketSeen world ->
            success
              ( "{\"ResourceTagMappingList\":[{\"ResourceARN\":\""
                  <> Text.unpack (stateBucketControlArn bucket)
                  <> "\",\"Tags\":[]}],\"PaginationToken\":\"\"}"
              )
        | otherwise -> success emptyPage
      _ -> failure ("unscripted command: " <> unwords arguments)
 where
  rooted = mentions "Name=vpc-id" arguments || mentions "Name=attachment.vpc-id" arguments
  nameIndex args =
    case [ read digits :: Int
         | arg <- args
         , "-" `isInfixOf` arg
         , let digits = trailingDigits arg
         , not (null digits)
         ] of
      index : _ -> index
      [] -> 0
  trailingDigits arg = reverse (takeWhile (`elem` ['0' .. '9']) (reverse arg))
  nth index values = take 1 (drop index values)
  vpcOf w = maybe vpcId id (worldVpc w)
  -- A resource lives in the VPC its @vpc@ field names, and in the account's VPC
  -- otherwise.
  vpcOfPlanted w p = maybe (vpcOf w) id (lookup "vpc" (plantedFields p))
  -- The listing filters by this cluster's name: another cluster's mark is not it.
  hasClusterMark p = lookup "cluster" (plantedFields p) == Just awsEksProvisionedClusterName
  loadBalancer p =
    object
      [ "id" .= plantedId p
      , "vpc" .= maybe vpcId id (lookup "vpc" (plantedFields p))
      , "state" .= maybe "active" id (lookup "state" (plantedFields p))
      ]
  iamNamed class' flag =
    let wanted = case dropWhile (/= flag) arguments of
          _ : value : _ -> Text.pack (reverse (takeWhile (/= '/') (reverse value)))
          _ -> ""
     in if wanted `elem` [plantedId p | p <- ofClass class' world]
          then success (Text.unpack wanted <> "\n")
          else failure "An error occurred (NoSuchEntity) when calling the operation: not found"

-- | The runner over a world, recording every command it is given.
runnerFor :: World -> IO (AwsNativeStackFamilyRunner IO, IO [[String]])
runnerFor world = do
  calls <- newIORef []
  pure
    ( AwsNativeStackFamilyRunner $ \arguments -> do
        modifyIORef' calls (<> [arguments])
        pure (respond world arguments)
    , readIORef calls
    )

refFor :: Text -> ProviderNativeStackFamilyRef
refFor stack =
  either (error . show) id $ do
    stackRef <- mkProviderStackRef stack
    mkProviderNativeStackFamilyRef
      stackRef
      "123456789012"
      (fixtureAwsRegion FixtureCaCentral1)
      (if stack == "aws-eks-subzone" then Just "ZSUBZONE123" else Nothing)

configFor :: Text -> ProviderStackConfig
configFor stack = either (error . show) id $ case stack of
  "aws-test" -> mkAwsTestProviderStackConfig "203.0.113.1/32"
  "aws-eks" -> mkAwsEksProviderStackConfig "203.0.113.1/32"
  _ -> mkAwsEksSubzoneProviderStackConfig "ZPARENT123" "aws.example.test"

-- | Audit one stack over a world: the observation, with the control taken.
auditWorld
  :: AuditStack
  -> World
  -> IO (AuditObservation, [[String]])
auditWorld stack world = do
  (runner, readCalls) <- runnerFor world
  let stackName = auditStackLabel stack
      ref = refFor stackName
  field <- auditStackField runner ref (configFor stackName)
  control <- auditPositiveControl runner ref bucket Nothing
  commands <- readCalls
  case field of
    Left detail -> fail (Text.unpack detail)
    Right (_, answers) -> case mkAuditObservation stack answers control of
      Left err -> fail (show err)
      Right observation -> pure (observation, commands)

countsOf :: AuditObservation -> [(AuditClass, Natural)]
countsOf observation = case auditVerdict observation of
  AuditResidue counts -> Map.toList counts
  _ -> []

-- | A resource of each class, planted in a world that already has its VPC where
-- the class lives inside one.
plantings :: [(String, AuditStack, World, [(AuditClass, Natural)])]
plantings =
  [
    ( "a subnet"
    , AuditAwsTest
    , plant AuditSubnet "subnet-0leak" [("state", "available")] False inVpc
    , [(AuditVpc, 1), (AuditSubnet, 1)]
    )
  ,
    ( "a route table"
    , AuditAwsTest
    , plant AuditRouteTable "rtb-0leak" [] False inVpc
    , [(AuditVpc, 1), (AuditRouteTable, 1)]
    )
  ,
    ( "an internet gateway"
    , AuditAwsTest
    , plant AuditInternetGateway "igw-0leak" [] False inVpc
    , [(AuditVpc, 1), (AuditInternetGateway, 1)]
    )
  ,
    ( "a security group"
    , AuditAwsTest
    , plant AuditSecurityGroup "sg-0leak" [("name", "k8s-elb-leak")] False inVpc
    , [(AuditVpc, 1), (AuditSecurityGroup, 1)]
    )
  ,
    ( "an available interface a controller attached"
    , AuditAwsEks
    , plant
        AuditNetworkInterface
        "eni-0leak"
        [ ("status", "available")
        , ("requester_managed", "false")
        , ("type", "interface")
        , ("description", "aws-K8S-i-0abc")
        ]
        False
        inVpc
    , [(AuditVpc, 1), (AuditNetworkInterface, 1)]
    )
  ,
    ( "a NAT gateway"
    , AuditAwsTest
    , plant AuditNatGateway "nat-0leak" [("state", "available")] False inVpc
    , [(AuditVpc, 1), (AuditNatGateway, 1)]
    )
  ,
    ( "a VPC endpoint"
    , AuditAwsTest
    , plant
        AuditVpcEndpoint
        "vpce-0leak"
        [("state", "available"), ("service", "com.amazonaws.s3")]
        False
        inVpc
    , [(AuditVpc, 1), (AuditVpcEndpoint, 1)]
    )
  ,
    ( "an instance"
    , AuditAwsTest
    , plant AuditInstance "i-0leak" [("state", "running")] False inVpc
    , [(AuditVpc, 1), (AuditInstance, 1)]
    )
  ,
    ( "a load balancer"
    , AuditAwsEks
    , plant
        AuditLoadBalancer
        "arn:aws:elasticloadbalancing:fixture:loadbalancer/app/leak"
        [("state", "active")]
        False
        inVpc
    , [(AuditVpc, 1), (AuditLoadBalancer, 1)]
    )
  ,
    ( "a classic load balancer"
    , AuditAwsEks
    , plant AuditLoadBalancer "leak-classic" [("kind", "classic")] False inVpc
    , [(AuditVpc, 1), (AuditLoadBalancer, 1)]
    )
  ,
    ( "a cluster"
    , AuditAwsEks
    , plant AuditEksCluster "aws-eks-test-cluster" [] True emptyWorld
    , [(AuditEksCluster, 1)]
    )
  ,
    ( "an OIDC provider that outlived its cluster"
    , AuditAwsEks
    , plant
        AuditOidcProvider
        ("arn:aws:iam::123456789012:oidc-provider/oidc.eks." <> Text.pack region' <> ".amazonaws.com/id/ABC")
        []
        False
        emptyWorld
    , [(AuditOidcProvider, 1)]
    )
  ,
    ( "a node group"
    , AuditAwsEks
    , plant AuditEksNodeGroup "aws-eks-test-node-group" [] True emptyWorld
    , [(AuditEksNodeGroup, 1)]
    )
  ,
    ( "an add-on"
    , AuditAwsEks
    , plant AuditEksAddon "aws-ebs-csi-driver" [] True emptyWorld
    , [(AuditEksAddon, 1)]
    )
  ,
    ( "an IAM role"
    , AuditAwsEks
    , plant AuditIamRole (firstName awsEksIamRoleNames) [] False emptyWorld
    , [(AuditIamRole, 1)]
    )
  ,
    ( "an IAM policy"
    , AuditAwsEks
    , plant AuditIamPolicy (firstName awsEksIamManagedPolicyNames) [] False emptyWorld
    , [(AuditIamPolicy, 1)]
    )
  ,
    ( "a per-run volume"
    , AuditAwsEks
    , plant AuditEbsVolume "vol-0leak" [("state", "available")] False emptyWorld
    , [(AuditEbsVolume, 1)]
    )
  ,
    ( "a subzone"
    , AuditAwsEksSubzone
    , plant AuditHostedZone "ZSUBZONE123" [] True emptyWorld
    , [(AuditHostedZone, 1)]
    )
  ,
    ( "a subzone delegation"
    , AuditAwsEksSubzone
    , plant AuditDelegationRecord "aws.example.test." [] True emptyWorld
    , [(AuditDelegationRecord, 1)]
    )
  ]
 where
  inVpc = withVpc emptyWorld

-- | A registered name, for a planted IAM resource.
firstName :: [Text] -> Text
firstName names = case names of
  name : _ -> name
  [] -> error "the registry declares no IAM names"

-- | The script holds a line that makes the query's call.
expectRead :: [Text] -> AuditQuery -> Expectation
expectRead script query = case auditQueryArgs query of
  service : operation : _ ->
    script `shouldSatisfy` any (Text.isInfixOf (Text.pack ("aws " <> service <> " " <> operation)))
  _ -> expectationFailure "a query had too few arguments"

awsAuditEnumerationSuite :: SuiteBuilder ()
awsAuditEnumerationSuite =
  describe "Sprint 4.110 the audit enumerates a scripted account" $ do
    it "finds nothing in an account that holds nothing, and licenses absence" $
      mapM_
        ( \stack -> do
            (observation, _) <- auditWorld stack emptyWorld
            auditVerdict observation `shouldBe` AuditClean
        )
        [AuditAwsTest, AuditAwsEks, AuditAwsEksSubzone]

    describe "planted-leak table: each class planted alone is residue in that class" $
      mapM_
        ( \(label, stack, world, expected) ->
            it ("finds " <> label) $ do
              (observation, _) <- auditWorld stack world
              countsOf observation `shouldBe` expected
        )
        plantings

    it "finds a child no name or tag could have declared, through the VPC" $ do
      -- The security group carries neither the stack's name nor its managed-by tag,
      -- as a controller's does not: only the VPC source can see it.
      (observation, commands) <-
        auditWorld
          AuditAwsEks
          (plant AuditSecurityGroup "sg-0controller" [("name", "k8s-elb-1234")] False (withVpc emptyWorld))
      [auditRowIdentity r | r <- auditRows observation, auditRowClass r == AuditSecurityGroup]
        `shouldBe` ["sg-0controller"]
      commands `shouldSatisfy` any (mentions ("Name=vpc-id,Values=" <> Text.unpack vpcId))

    it "counts a security group the stack names and the VPC holds once" $ do
      (observation, _) <-
        auditWorld
          AuditAwsTest
          (plant AuditSecurityGroup "sg-0both" [("name", "aws-test-sg")] True (withVpc emptyWorld))
      countsOf observation `shouldBe` [(AuditVpc, 1), (AuditSecurityGroup, 1)]

    it "asks nothing inside a VPC that does not exist" $ do
      (observation, commands) <- auditWorld AuditAwsEks emptyWorld
      auditVerdict observation `shouldBe` AuditClean
      -- The cluster-anchored location reads interfaces by the cluster's mark; nothing
      -- is read inside a VPC, because none was located.
      commands `shouldSatisfy` (not . any (mentions "Name=vpc-id"))

    it "scopes every read inside the VPC to the VPC it located" $ do
      (_, commands) <- auditWorld AuditAwsEks (withVpc emptyWorld)
      let rootedReads =
            [ c
            | c <- commands
            , any (`elem` c) ["describe-network-interfaces", "describe-nat-gateways", "describe-vpc-endpoints"]
            , -- The cluster-anchored VPC location reads interfaces by the cluster's mark.
            mentions "Name=vpc-id" c
            ]
      length rootedReads `shouldBe` 3
      rootedReads `shouldSatisfy` all (mentions ("Values=" <> Text.unpack vpcId))

    describe "what an operator reads beside an identity" $ do
      it "says whether an interface is attached, whether AWS holds it, and what it is for" $ do
        (observation, _) <-
          auditWorld
            AuditAwsEks
            ( plant
                AuditNetworkInterface
                "eni-0cni"
                [ ("status", "available")
                , ("requester_managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-05c0f66fdcd02bf20")
                ]
                False
                $ plant
                  AuditNetworkInterface
                  "eni-0held"
                  [ ("status", "in-use")
                  , ("requester_managed", "true")
                  , ("type", "interface")
                  , ("description", "ELB app/own/50dc6c495c0c9188")
                  ]
                  False
                  (withVpc emptyWorld)
            )
        [ (auditRowIdentity r, auditRowDetail r)
          | r <- auditRows observation
          , auditRowClass r == AuditNetworkInterface
          ]
          `shouldBe` [ ("eni-0cni", "available self aws-K8S-i-05c0f66fdcd02bf20")
                     , ("eni-0held", "in-use managed ELB app/own/50dc6c495c0c9188")
                     ]

      it "names an endpoint's service without the namespace every service shares" $ do
        (observation, _) <-
          auditWorld
            AuditAwsTest
            ( plant
                AuditVpcEndpoint
                "vpce-0live"
                [("state", "available"), ("service", "com.amazonaws." <> Text.pack region' <> ".s3")]
                False
                (withVpc emptyWorld)
            )
        [auditRowDetail r | r <- auditRows observation, auditRowClass r == AuditVpcEndpoint]
          `shouldBe` ["available s3"]

    describe "what the audit does not take on trust" $ do
      let leakedByCluster =
            plant
              AuditNetworkInterface
              "eni-0leak"
              [ ("status", "available")
              , ("requester_managed", "false")
              , ("type", "interface")
              , ("description", "aws-K8S-i-0abc")
              , ("cluster", "aws-eks-test-cluster")
              ]
              False

      it "reads a VPC whose tags were edited away, through the marks the cluster itself carries" $ do
        (observation, commands) <-
          auditWorld
            AuditAwsEks
            (leakedByCluster (withVpc emptyWorld)) {worldVpcTagsLost = True}
        countsOf observation `shouldBe` [(AuditVpc, 1), (AuditNetworkInterface, 1)]
        commands `shouldSatisfy` any (mentions ("Name=vpc-id,Values=" <> Text.unpack vpcId))

      it "keeps reading the VPC when an unrelated exact-name read is refused" $ do
        (observation, _) <-
          auditWorld
            AuditAwsEks
            (leakedByCluster (withVpc emptyWorld)) {worldBroken = ["describe-cluster"]}
        -- The leak is found, and the class the refusal touched says it did not answer.
        countsOf observation `shouldBe` [(AuditVpc, 1), (AuditNetworkInterface, 1)]
        fmap auditAnswerGap (Map.lookup AuditEksCluster (auditObservationAnswers observation))
          `shouldSatisfy` maybe False (/= Nothing)

      it "audits every VPC the stack's tags name" $ do
        (inner, _) <- runnerFor (withVpc emptyWorld)
        seen <- newIORef []
        let twoVpcs =
              AwsNativeStackFamilyRunner $ \arguments -> do
                modifyIORef' seen (<> [arguments])
                if queryOf arguments == "Vpcs[].VpcId"
                  then pure (success "vpc-0aaaaaaaaaaaaaaaa\tvpc-0bbbbbbbbbbbbbbbb\n")
                  else runAwsNativeStackFamilyCommand inner arguments
        field <- auditStackField twoVpcs (refFor "aws-test") (configFor "aws-test")
        either (expectationFailure . Text.unpack) (const (pure ())) field
        commands <- readIORef seen
        mapM_
          ( \vpc ->
              commands
                `shouldSatisfy` any (\c -> "describe-network-interfaces" `elem` c && mentions vpc c)
          )
          ["Name=vpc-id,Values=vpc-0aaaaaaaaaaaaaaaa", "Name=vpc-id,Values=vpc-0bbbbbbbbbbbbbbbb"]

      it "reads a null answer as a query it did not understand, not as nothing there" $ do
        (inner, _) <- runnerFor (withVpc emptyWorld)
        let nullNat =
              AwsNativeStackFamilyRunner $ \arguments ->
                if "describe-nat-gateways" `elem` arguments
                  then pure (success "null")
                  else runAwsNativeStackFamilyCommand inner arguments
        field <- auditStackField nullNat (refFor "aws-test") (configFor "aws-test")
        case field of
          Right (_, answers) ->
            fmap auditAnswerGap (lookup AuditNatGateway answers)
              `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "null"))
          Left detail -> expectationFailure (Text.unpack detail)

      it "reads a volume listing without a Volumes array as a gap, and ignores a volume already deleted" $ do
        (inner, _) <- runnerFor emptyWorld
        let bare =
              AwsNativeStackFamilyRunner $ \arguments ->
                if "describe-volumes" `elem` arguments
                  then pure (success "{}")
                  else runAwsNativeStackFamilyCommand inner arguments
        field <- auditStackField bare (refFor "aws-eks") (configFor "aws-eks")
        case field of
          Right (_, answers) ->
            fmap auditAnswerGap (lookup AuditEbsVolume answers)
              `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "Volumes"))
          Left detail -> expectationFailure (Text.unpack detail)
        (observation, _) <-
          auditWorld
            AuditAwsEks
            (plant AuditEbsVolume "vol-0gone" [("state", "deleted")] False emptyWorld)
        countsOf observation `shouldBe` []

      it "reads a row that is not an object, or that names no resource, as a query it did not understand" $
        mapM_
          ( \payload -> do
              (inner, _) <- runnerFor (withVpc emptyWorld)
              let odd' =
                    AwsNativeStackFamilyRunner $ \arguments ->
                      if "describe-nat-gateways" `elem` arguments
                        then pure (success payload)
                        else runAwsNativeStackFamilyCommand inner arguments
              field <- auditStackField odd' (refFor "aws-test") (configFor "aws-test")
              case field of
                Right (_, answers) ->
                  fmap auditAnswerGap (lookup AuditNatGateway answers)
                    `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "does not read"))
                Left detail -> expectationFailure (Text.unpack detail)
          )
          ["[1]", "[{\"state\":\"available\"}]", "\"text\""]

      it "finds the control on a later page, and refuses a cursor that repeats" $ do
        let page arns cursor =
              success
                ( "{\"ResourceTagMappingList\":["
                    <> intercalate "," ["{\"ResourceARN\":\"" <> arn <> "\",\"Tags\":[]}" | arn <- arns]
                    <> "],\"PaginationToken\":\""
                    <> cursor
                    <> "\"}"
                )
        seen <- newIORef (0 :: Int)
        let later =
              AwsNativeStackFamilyRunner $ \_ -> do
                n <- readIORef seen
                modifyIORef' seen (+ 1)
                pure
                  ( if n == 0
                      then page [] "next-page"
                      else page [Text.unpack (stateBucketControlArn bucket)] ""
                  )
            looping = AwsNativeStackFamilyRunner $ \_ -> pure (page [] "same-page")
        auditPositiveControl later (refFor "aws-test") bucket Nothing `shouldReturn` AuditControlSeen
        looped <- auditPositiveControl looping (refFor "aws-test") bucket Nothing
        looped `shouldSatisfy` isControlUnanswered

      it "names the code AWS answered with ahead of the rest, so the wire cannot cut it off" $ do
        (observation, _) <-
          auditWorld AuditAwsTest ((withVpc emptyWorld) {worldBroken = ["describe-network-interfaces"]})
        let reasons =
              [ gap
              | answer <- Map.elems (auditObservationAnswers observation)
              , Just gap <- [auditAnswerGap answer]
              ]
        reasons `shouldSatisfy` any (Text.isPrefixOf "ec2 describe-network-interfaces: AccessDenied")
        mapM_ (\gap -> (Text.length gap <= 160) `shouldBe` True) reasons

      it "looks for the control in the region the bucket lives in, and in the session's otherwise" $ do
        (runner, calls) <- runnerFor (withVpc emptyWorld)
        let elsewhere = fixtureAwsRegion FixtureUsWest2 :: Text
        _ <- auditPositiveControl runner (refFor "aws-test") bucket (Just elsewhere)
        _ <- auditPositiveControl runner (refFor "aws-test") bucket Nothing
        recorded <- calls
        [ flagValue "--region" c
          | c <- recorded
          , "resourcegroupstaggingapi" `elem` c
          ]
          `shouldBe` [Text.unpack elsewhere, region']

    describe "what the provider lists that the stack does not own" $ do
      it "does not count a load balancer that lives in another VPC" $ do
        -- The listing call has no VPC filter, so reading the VPC out of each row is
        -- what keeps another project's load balancer out of this stack's verdict.
        (observation, _) <-
          auditWorld
            AuditAwsEks
            ( plant AuditLoadBalancer "foreign-classic" [("kind", "classic"), ("vpc", "vpc-0foreign")] False
                $ plant
                  AuditLoadBalancer
                  "arn:aws:elasticloadbalancing:fixture:loadbalancer/app/foreign"
                  [("vpc", "vpc-0foreign")]
                  False
                $ plant
                  AuditLoadBalancer
                  "arn:aws:elasticloadbalancing:fixture:loadbalancer/app/own"
                  []
                  False
                  (withVpc emptyWorld)
            )
        [auditRowIdentity r | r <- auditRows observation, auditRowClass r == AuditLoadBalancer]
          `shouldBe` ["arn:aws:elasticloadbalancing:fixture:loadbalancer/app/own"]

      it "does not count an endpoint the provider reports deleted or failed" $ do
        (observation, _) <-
          auditWorld
            AuditAwsTest
            ( plant AuditVpcEndpoint "vpce-0gone" [("state", "deleted"), ("service", "com.amazonaws.s3")] False $
                plant AuditVpcEndpoint "vpce-0failed" [("state", "failed"), ("service", "com.amazonaws.s3")] False $
                  plant
                    AuditVpcEndpoint
                    "vpce-0live"
                    [("state", "available"), ("service", "com.amazonaws.s3")]
                    False
                    (withVpc emptyWorld)
            )
        [auditRowIdentity r | r <- auditRows observation, auditRowClass r == AuditVpcEndpoint]
          `shouldBe` ["vpce-0live"]

      it "does not count an instance that has terminated, which the provider keeps listing" $ do
        (observation, _) <-
          auditWorld
            AuditAwsTest
            ( plant AuditInstance "i-0gone" [("state", "terminated")] False $
                plant AuditInstance "i-0leaving" [("state", "shutting-down")] False (withVpc emptyWorld)
            )
        [auditRowIdentity r | r <- auditRows observation, auditRowClass r == AuditInstance]
          `shouldBe` ["i-0leaving"]

      it "does not count a NAT gateway that has been deleted" $ do
        (observation, _) <-
          auditWorld
            AuditAwsTest
            ( plant AuditNatGateway "nat-0gone" [("state", "deleted")] False $
                plant AuditNatGateway "nat-0leaving" [("state", "deleting")] False (withVpc emptyWorld)
            )
        [auditRowIdentity r | r <- auditRows observation, auditRowClass r == AuditNatGateway]
          `shouldBe` ["nat-0leaving"]

    describe "an unanswered query is never an empty class" $ do
      it "a refused exact-name query makes the verdict unobservable" $ do
        (observation, _) <- auditWorld AuditAwsTest (emptyWorld {worldBroken = ["describe-vpcs"]})
        auditVerdict observation `shouldSatisfy` isUnobservable
        renderAuditReport observation (auditVerdict observation)
          `shouldSatisfy` any
            ( Text.isPrefixOf
                "AWS_FIELD aws-test unanswered=vpc (observe VPC failed: An error occurred (AccessDenied) when calling the operation: not authorized"
            )

      it "classes that need the VPC are unanswered when the VPC could not be located" $ do
        (observation, _) <- auditWorld AuditAwsTest (emptyWorld {worldBroken = ["describe-vpcs"]})
        mapM_
          ( \class' ->
              fmap auditAnswerGap (Map.lookup class' (auditObservationAnswers observation))
                `shouldSatisfy` (maybe False (maybe False (Text.isInfixOf "could not be located")))
          )
          [AuditNetworkInterface, AuditNatGateway, AuditVpcEndpoint, AuditLoadBalancer]

      it "a refused read inside the VPC leaves a gap but keeps the rows already found" $ do
        (observation, _) <-
          auditWorld
            AuditAwsEks
            ((withVpc emptyWorld) {worldBroken = ["describe-network-interfaces"]})
        auditVerdict observation `shouldBe` AuditResidue (Map.fromList [(AuditVpc, 1)])
        fmap auditAnswerGap (Map.lookup AuditNetworkInterface (auditObservationAnswers observation))
          `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "ec2 describe-network-interfaces: AccessDenied"))

      it "an answer in a shape the audit does not read is a gap, not an empty class" $ do
        (runner, _) <- runnerFor (withVpc emptyWorld)
        let garbled =
              AwsNativeStackFamilyRunner $ \arguments ->
                if "describe-nat-gateways" `elem` arguments
                  then pure (success "not json")
                  else runAwsNativeStackFamilyCommand runner arguments
        field <- auditStackField garbled (refFor "aws-test") (configFor "aws-test")
        case field of
          Right (_, answers) ->
            fmap auditAnswerGap (lookup AuditNatGateway answers)
              `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "shape the audit does not read"))
          Left detail -> expectationFailure (Text.unpack detail)

      it "a refused IAM or volume read makes the cluster's field unobservable" $
        mapM_
          ( \fragment -> do
              (observation, _) <- auditWorld AuditAwsEks (emptyWorld {worldBroken = [fragment]})
              auditVerdict observation `shouldSatisfy` isUnobservable
          )
          ["get-role", "get-policy", "describe-volumes"]

      it "a refused read of any one registered IAM name makes the field unobservable" $
        mapM_
          ( \name -> do
              (observation, _) <- auditWorld AuditAwsEks (emptyWorld {worldBroken = [Text.unpack name]})
              auditVerdict observation `shouldSatisfy` isUnobservable
          )
          (awsEksIamRoleNames <> awsEksIamManagedPolicyNames)

      it "an IAM name that does not exist is an answered, empty class" $ do
        (observation, _) <- auditWorld AuditAwsEks emptyWorld
        fmap auditAnswerGap (Map.lookup AuditIamRole (auditObservationAnswers observation))
          `shouldBe` Just Nothing

    describe "the positive control" $ do
      it "makes an empty account unobservable when the state bucket does not appear" $ do
        (observation, _) <- auditWorld AuditAwsTest (emptyWorld {worldBucketSeen = False})
        auditObservationControl observation `shouldBe` AuditControlMissing
        auditVerdict observation `shouldSatisfy` isUnobservable

      it "makes it unobservable when the catalog itself is refused" $ do
        (observation, _) <-
          auditWorld AuditAwsTest (emptyWorld {worldBroken = ["resourcegroupstaggingapi"]})
        auditObservationControl observation `shouldSatisfy` isControlUnanswered
        auditVerdict observation `shouldSatisfy` isUnobservable

      it "does not turn a found leak into anything but residue when the control is missing" $ do
        (observation, _) <-
          auditWorld
            AuditAwsTest
            ( (plant AuditSubnet "subnet-0leak" [("state", "available")] False (withVpc emptyWorld))
                { worldBucketSeen = False
                }
            )
        auditVerdict observation `shouldSatisfy` isResidue

    describe "the read-only script" $ do
      let scripts =
            [ (stack, map unquoted (auditReadOnlyScript stack (Just bucket) Nothing))
            | stack <- [AuditAwsTest, AuditAwsEks]
            ]
          unquoted = Text.filter (/= '\'')
          awsCalls script =
            [ (service, operation)
            | line <- script
            , "aws" : service : operation : _ <- [Text.words (Text.replace "VPCS=$(" "" line)]
            ]

      it "is made of describe, get and list calls, and nothing that changes the account" $
        mapM_
          ( \(_, script) -> do
              awsCalls script `shouldSatisfy` (not . null)
              awsCalls script `shouldSatisfy` all readOnlyAws
          )
          scripts

      it "reads the inside of the VPC it discovers, with the reads the Provider issues" $ do
        let eks = maybe [] id (lookup AuditAwsEks scripts)
        mapM_ (expectRead eks) (vpcRootedQueries "$VPC")
        eks `shouldSatisfy` any (Text.isInfixOf "Name=vpc-id,Values=$VPC")

      it "ends with the positive control, naming the bucket it expects" $
        mapM_
          ( \(_, script) -> do
              last script `shouldSatisfy` Text.isInfixOf "control:"
              last script `shouldSatisfy` Text.isInfixOf "arn:aws:s3:::$STATE_BUCKET"
              script `shouldSatisfy` any (Text.isInfixOf ("STATE_BUCKET=${STATE_BUCKET:-" <> bucket <> "}"))
          )
          scripts

      it "asks for the bucket when the host cannot read it, and never claims the control is missing" $
        mapM_
          ( \stack -> do
              let script = auditReadOnlyScript stack Nothing Nothing
              script `shouldSatisfy` elem "STATE_BUCKET=${STATE_BUCKET:-}"
              last script `shouldSatisfy` Text.isInfixOf "control: NOT CHECKED"
              Text.unlines script `shouldSatisfy` (not . Text.isInfixOf "<state-bucket>")
          )
          [AuditAwsTest, AuditAwsEks]

      it "reads each VPC the tags name, and counts only the load balancer rows that are in it" $ do
        let script = auditReadOnlyScript AuditAwsEks (Just bucket) Nothing
        script `shouldSatisfy` elem "for VPC in $VPCS; do"
        script `shouldSatisfy` any (Text.isInfixOf "LoadBalancers[?VpcId==")
        script `shouldSatisfy` any (Text.isInfixOf "LoadBalancerDescriptions[?VPCId==")

      it
        "reads the OIDC provider listing and the cluster's own resources for an EKS stack, and no cluster otherwise"
        $ do
          let eks = Text.unlines (auditReadOnlyScript AuditAwsEks (Just bucket) Nothing)
              test = Text.unlines (auditReadOnlyScript AuditAwsTest (Just bucket) Nothing)
          eks `shouldSatisfy` Text.isInfixOf "iam:oidc-provider"
          eks `shouldSatisfy` Text.isInfixOf "describe-cluster"
          test `shouldSatisfy` (not . Text.isInfixOf "iam:oidc-provider")
          test `shouldSatisfy` (not . Text.isInfixOf "describe-cluster")

    it "issues describe, get and list calls and nothing else" $
      mapM_
        ( \(_, stack, world, _) -> do
            (_, commands) <- auditWorld stack world
            commands `shouldSatisfy` all readOnly
        )
        plantings
 where
  readOnlyAws (service, operation) =
    any (`Text.isPrefixOf` operation) ["describe-", "get-", "list-"]
      || (service, operation) == ("resourcegroupstaggingapi", "get-resources")
  readOnly command = case command of
    _ : operation : _ ->
      any (`isPrefixOf` operation) ["describe-", "get-", "list-"]
    _ -> False
  isUnobservable verdict = case verdict of
    AuditUnobservable _ _ -> True
    _ -> False
  isResidue verdict = case verdict of
    AuditResidue _ -> True
    _ -> False
  isControlUnanswered control = case control of
    AuditControlUnanswered _ -> True
    _ -> False
