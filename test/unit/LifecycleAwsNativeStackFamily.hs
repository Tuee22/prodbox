{-# LANGUAGE OverloadedStrings #-}

module LifecycleAwsNativeStackFamily
  ( lifecycleAwsNativeStackFamilySuite
  )
where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, findIndex, isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.AwsNativeStackFamily
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

lifecycleAwsNativeStackFamilySuite :: SuiteBuilder ()
lifecycleAwsNativeStackFamilySuite =
  describe "Sprint 7.36 native registered stack families" $ do
    it "observes the aws-test family only through exact managed names" $ do
      calls <- newIORef []
      observed <-
        observeAwsNativeStackFamily
          (recordingRunner calls awsTestResponse)
          testRef
          testConfig
      observed `shouldSatisfy` hasTestFamily
      commands <- readIORef calls
      let taggedDescriptions =
            filter
              (\arguments -> "describe-" `isInfixOf` unwords arguments)
              commands
      taggedDescriptions
        `shouldSatisfy` all
          (elem "Name=tag:prodbox.io/managed-by,Values=prodbox")

    it "keeps a failed exact provider query unobservable" $ do
      observed <-
        observeAwsNativeStackFamily
          ( AwsNativeStackFamilyRunner $ \arguments ->
              pure
                ( if "describe-subnets" `elem` arguments
                    then failure "AccessDenied"
                    else awsTestResponse arguments
                )
          )
          testRef
          testConfig
      observed `shouldSatisfy` isLeft

    it "derives EKS provider coordinates from the registered Pulumi stack" $ do
      calls <- newIORef []
      observed <-
        observeAwsNativeStackFamily
          (recordingRunner calls emptyEksResponse)
          eksRef
          eksConfig
      observed `shouldBe` Right []
      commands <- readIORef calls
      commands
        `shouldSatisfy` any
          (containsArguments ["describe-cluster", "--name", "aws-eks-test-cluster"])
      commands
        `shouldSatisfy` any
          ( containsArguments
              [ "describe-nodegroup"
              , "--cluster-name"
              , "aws-eks-test-cluster"
              , "--nodegroup-name"
              , "aws-eks-test-node-group"
              ]
          )
      concat commands
        `shouldSatisfy` elem
          "Name=tag:Name,Values=aws-eks-test-vpc"
      unwords (concat commands) `shouldNotContain` "aws-eks-cluster"

    it "observes one historical auto-named EKS role through its exact Name tag" $ do
      calls <- newIORef []
      observed <-
        observeAwsNativeStackFamily
          (recordingRunner calls historicalEksRoleResponse)
          eksRef
          eksConfig
      observed
        `shouldBe` Right
          ["iam-legacy-role/arn:aws:iam::123456789012:role/clusterRole-fixture"]
      commands <- readIORef calls
      commands
        `shouldSatisfy` any
          ( containsArguments
              [ "resourcegroupstaggingapi"
              , "get-resources"
              , "--resource-type-filters"
              , "iam:role"
              , "--tag-filters"
              , "Key=Name,Values=aws-eks-test-cluster-role"
              , "--region"
              , fixtureAwsRegion FixtureUsEast1
              ]
          )

    it "refuses ambiguous historical auto-named EKS roles" $ do
      observed <-
        observeAwsNativeStackFamily
          (AwsNativeStackFamilyRunner (pure . ambiguousHistoricalEksRoleResponse))
          eksRef
          eksConfig
      observed `shouldSatisfy` isLeft

    it "refuses a newly observed native identity outside the admitted manifest" $ do
      calls <- newIORef []
      reaped <-
        reapAwsNativeStackFamilyWithin
          (recordingRunner calls historicalEksRoleResponse)
          eksRef
          eksConfig
          []
      reaped `shouldSatisfy` isLeft
      commands <- readIORef calls
      commands `shouldSatisfy` all (not . isMutationCommand)

    it "detaches the closed policy set before deleting an admitted historical role" $ do
      calls <- newIORef []
      let roleArn = "arn:aws:iam::123456789012:role/clusterRole-fixture"
      reaped <-
        reapAwsNativeStackFamilyWithin
          (recordingRunner calls historicalEksRoleResponse)
          eksRef
          eksConfig
          ["iam-legacy-role/" <> roleArn]
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      indexOf "detach-role-policy" commands
        `shouldSatisfy` (< indexOf "delete-role" commands)
      commands
        `shouldSatisfy` any
          ( containsArguments
              [ "detach-role-policy"
              , "--role-name"
              , "clusterRole-fixture"
              , "--policy-arn"
              , "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
              ]
          )

    it "observes subzone presence jointly with its exact parent NS delegation" $ do
      observed <-
        observeAwsNativeStackFamily
          (AwsNativeStackFamilyRunner (pure . subzoneResponse))
          subzoneRef
          subzoneConfig
      observed
        `shouldBe` Right
          [ "hosted-zone/ZSUBZONE123"
          , "route53-record/ZPARENT123/NS/aws.example.test."
          ]

    it "reaps EC2 resources in dependency order" $ do
      calls <- newIORef []
      reaped <-
        reapAwsNativeStackFamily
          (recordingRunner calls awsTestResponse)
          testRef
          testConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      indexOf "terminate-instances" commands
        `shouldSatisfy` (< indexOf "disassociate-route-table" commands)
      indexOf "disassociate-route-table" commands
        `shouldSatisfy` (< indexOf "delete-route-table" commands)
      indexOf "delete-subnet" commands
        `shouldSatisfy` (< indexOf "detach-internet-gateway" commands)
      indexOf "detach-internet-gateway" commands
        `shouldSatisfy` (< indexOf "delete-vpc" commands)
      length (filter (elem "delete-internet-gateway") commands) `shouldBe` 1

    it "deletes the exact parent delegation before its hosted zone" $ do
      calls <- newIORef []
      reaped <-
        reapAwsNativeStackFamily
          (recordingRunner calls subzoneResponse)
          subzoneRef
          subzoneConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      indexOf "change-resource-record-sets" commands
        `shouldSatisfy` (< indexOf "delete-hosted-zone" commands)

    it "binds adapter requests and evidence to the typed stack config" $ do
      mkAwsNativeStackFamilyObservationRequest
        AwsTestKey
        testScope
        revision
        eksConfig
        `shouldSatisfy` isConfigMismatch
      let request =
            mustRight
              ( mkAwsNativeStackFamilyObservationRequest
                  AwsTestKey
                  testScope
                  revision
                  testConfig
              )
          evidence =
            mustRight
              ( encodeAwsNativeStackFamilyEvidence
                  (awsNativeStackFamilyObservationRequestRef request)
                  ["vpc/vpc-1", "subnet/subnet-1"]
              )
      decodeAwsNativeStackFamilyObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (awsNativeStackFamilyObservationRequestCoordinate request)
                evidence
            )
        )
        `shouldSatisfy` isRight

recordingRunner
  :: IORef [[String]]
  -> ([String] -> ProcessOutput)
  -> AwsNativeStackFamilyRunner IO
recordingRunner calls respond =
  AwsNativeStackFamilyRunner $ \arguments -> do
    modifyIORef' calls (<> [arguments])
    pure (respond arguments)

awsTestResponse :: [String] -> ProcessOutput
awsTestResponse arguments
  | "--output" `elem` arguments
  , "text" `elem` arguments =
      success $ case queryOf arguments of
        "Vpcs[].VpcId" -> "vpc-1\n"
        "InternetGateways[].InternetGatewayId" -> "igw-1\n"
        "RouteTables[].RouteTableId" -> "rtb-1\n"
        "RouteTables[].Associations[].RouteTableAssociationId" ->
          "rtbassoc-1\trtbassoc-2\trtbassoc-3\n"
        "Subnets[].SubnetId" -> namedId "subnet" arguments
        "SecurityGroups[].GroupId" -> "sg-1\n"
        "Reservations[].Instances[].InstanceId" -> namedId "instance" arguments
        _ -> ""
  | otherwise = success "{}"

subzoneResponse :: [String] -> ProcessOutput
subzoneResponse arguments
  | "get-hosted-zone" `elem` arguments =
      success "/hostedzone/ZSUBZONE123\tAWS.EXAMPLE.TEST.\n"
  | "list-resource-record-sets" `elem` arguments
  , "json" `elem` arguments =
      success
        "{\"ResourceRecordSets\":[{\"Name\":\"aws.example.test.\",\"Type\":\"NS\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"ns-1.example.\"}]}]}"
  | "list-resource-record-sets" `elem` arguments =
      success "aws.example.test.\tNS\n"
  | otherwise = success "{}"

emptyEksResponse :: [String] -> ProcessOutput
emptyEksResponse arguments
  | "resourcegroupstaggingapi" `elem` arguments = success emptyTaggedResourcePage
  | otherwise = success ""

historicalEksRoleResponse :: [String] -> ProcessOutput
historicalEksRoleResponse arguments
  | "resourcegroupstaggingapi" `elem` arguments
  , "Key=Name,Values=aws-eks-test-cluster-role" `elem` arguments =
      success
        ( taggedRolePage
            [
              ( "arn:aws:iam::123456789012:role/clusterRole-fixture"
              , "aws-eks-test-cluster-role"
              )
            ]
        )
  | "resourcegroupstaggingapi" `elem` arguments = success emptyTaggedResourcePage
  | otherwise = success ""

ambiguousHistoricalEksRoleResponse :: [String] -> ProcessOutput
ambiguousHistoricalEksRoleResponse arguments
  | "resourcegroupstaggingapi" `elem` arguments
  , "Key=Name,Values=aws-eks-test-cluster-role" `elem` arguments =
      success
        ( taggedRolePage
            [
              ( "arn:aws:iam::123456789012:role/clusterRole-first"
              , "aws-eks-test-cluster-role"
              )
            ,
              ( "arn:aws:iam::123456789012:role/clusterRole-second"
              , "aws-eks-test-cluster-role"
              )
            ]
        )
  | "resourcegroupstaggingapi" `elem` arguments = success emptyTaggedResourcePage
  | otherwise = success ""

taggedRolePage :: [(Text, Text)] -> String
taggedRolePage entries =
  Text.unpack
    ( "{\"ResourceTagMappingList\":["
        <> Text.intercalate "," (map renderEntry entries)
        <> "],\"PaginationToken\":\"\"}"
    )
 where
  renderEntry (arn, nameTag) =
    "{\"ResourceARN\":\""
      <> arn
      <> "\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\""
      <> nameTag
      <> "\"}]}"

emptyTaggedResourcePage :: String
emptyTaggedResourcePage =
  "{\"ResourceTagMappingList\":[],\"PaginationToken\":\"\"}"

isMutationCommand :: [String] -> Bool
isMutationCommand arguments =
  any
    (`elem` arguments)
    [ "detach-role-policy"
    , "delete-role"
    , "delete-cluster"
    , "delete-nodegroup"
    , "delete-addon"
    , "delete-vpc"
    ]

namedId :: Text -> [String] -> String
namedId kind arguments =
  let nameFilter =
        maybe
          "unknown"
          ( maybe "unknown" id
              . Text.stripPrefix "Name=tag:Name,Values="
              . Text.pack
          )
          (find ("Name=tag:Name,Values=" `isInfixOf`) arguments)
      suffix = maybe nameFilter id (Text.stripPrefix "aws-test-" nameFilter)
   in Text.unpack (kind <> "-" <> suffix <> "\n")

queryOf :: [String] -> String
queryOf arguments = case dropWhile (/= "--query") arguments of
  _ : value : _ -> value
  _ -> ""

indexOf :: String -> [[String]] -> Int
indexOf operation commands =
  maybe maxBound id (findIndex (elem operation) commands)

containsArguments :: [String] -> [String] -> Bool
containsArguments expected arguments = expected `isInfixOf` arguments

hasTestFamily :: Either Text [Text] -> Bool
hasTestFamily value = case value of
  Right identities ->
    "vpc/vpc-1" `elem` identities
      && length (filter (Text.isPrefixOf "instance/") identities) == 3
      && length (filter (Text.isPrefixOf "route-table-association/") identities) == 3
  Left _ -> False

isConfigMismatch
  :: Either AwsNativeStackFamilyAdapterError value -> Bool
isConfigMismatch value = case value of
  Left (AwsNativeStackFamilyConfigInvalid _) -> True
  _ -> False

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isRight :: Either left right -> Bool
isRight value = case value of
  Right _ -> True
  Left _ -> False

success :: String -> ProcessOutput
success stdout = ProcessOutput ExitSuccess stdout ""

failure :: String -> ProcessOutput
failure stderr = ProcessOutput (ExitFailure 1) "" stderr

testRef :: ProviderNativeStackFamilyRef
testRef =
  mustRight
    ( mkProviderNativeStackFamilyRef
        (mustRight (mkProviderStackRef "aws-test"))
        "123456789012"
        region
        Nothing
    )

eksRef :: ProviderNativeStackFamilyRef
eksRef =
  mustRight
    ( mkProviderNativeStackFamilyRef
        (mustRight (mkProviderStackRef "aws-eks"))
        "123456789012"
        region
        Nothing
    )

subzoneRef :: ProviderNativeStackFamilyRef
subzoneRef =
  mustRight
    ( mkProviderNativeStackFamilyRef
        (mustRight (mkProviderStackRef "aws-eks-subzone"))
        "123456789012"
        region
        (Just "ZSUBZONE123")
    )

testConfig :: ProviderStackConfig
testConfig = mustRight (mkAwsTestProviderStackConfig "203.0.113.1/32")

eksConfig :: ProviderStackConfig
eksConfig = mustRight (mkAwsEksProviderStackConfig "203.0.113.1/32")

subzoneConfig :: ProviderStackConfig
subzoneConfig =
  mustRight (mkAwsEksSubzoneProviderStackConfig "ZPARENT123" "aws.example.test")

testScope :: ObservationEvidenceScope
testScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    (DurableObservationRunScope "native-stack-family-run")
    (LinuxRke2FoundationId "home-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion region)))
    ReconcileDesiredAbsent

revision :: ObservationRevision
revision = ObservationRevision 79

region :: Text
region = fixtureAwsRegion FixtureCaCentral1

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Right result -> result
  Left err -> error ("expected Right, got " <> show err)
