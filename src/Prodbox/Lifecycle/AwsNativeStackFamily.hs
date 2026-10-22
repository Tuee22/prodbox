{-# LANGUAGE OverloadedStrings #-}

-- | Checkpoint-independent AWS observation and desired-absence execution for
-- the three registered per-run Pulumi stack families.  Every query is bound
-- to a deterministic name, exact hosted-zone coordinate, or exact EKS child
-- coordinate.  The boundary never enumerates an account-wide prefix or treats
-- a failed query as an empty family.
module Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
  , observeEksOwners
  , observeEksClusterAbsent
  , locateNetworkFamily
  , reapAwsNativeStackFamily
  , reapAwsNativeStackFamilyWithin
  )
where

import Control.Monad (foldM)
import Data.Aeson
  ( Value (Array, Object, String)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyByteStringChar8
import Data.List (intercalate, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Aws.CliError (awsCliServiceErrorMatches)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.ControlPlane.OperationBudget (WaitFact (..))
import Prodbox.Lifecycle.AwsNetworkDependents
  ( Dependent (..)
  , DependentKind (..)
  , DependentsRepair (..)
  , DependentsTarget
  , Disposition (..)
  , clearNetworkFamilies
  , clearNetworkFamily
  , mkDependentsTarget
  , observeNetworkFamily
  , renderDependents
  )
import Prodbox.Lifecycle.AwsNetworkFamily
import Prodbox.Lifecycle.AwsWait
  ( AwsWaitEnvironment
  , WaitStep (..)
  , awaitFact
  , renderWaitFailure
  , transientPollFailure
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.TaggedResourceQuery
  ( TaggedResourceEntry (..)
  , TaggedResourcePage (..)
  , maximumTaggedResourcePages
  , parseTaggedResourcePage
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksIamRoleNames
  , awsEksProvisionedClusterName
  , awsEksProvisionedNodeGroupName
  , awsEksPulumiStackName
  , awsNetworkFamiliesForStack
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

newtype AwsNativeStackFamilyRunner m = AwsNativeStackFamilyRunner
  { runAwsNativeStackFamilyCommand :: [String] -> m ProcessOutput
  }

observeAwsNativeStackFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text [Text])
observeAwsNativeStackFamily runner ref config
  | Just family <- providerNativeStackFamilyNetworkFamily ref = do
      located <- locateNetworkFamily runner family
      case located of
        Left detail -> pure (Left detail)
        Right Nothing -> pure (Right [])
        Right (Just target) -> do
          observed <- observeNetworkFamily family (runAwsNativeStackFamilyCommand runner) target
          pure $ do
            rows <- observed
            case filter unadmittedNetworkDependent rows of
              [] -> Right (map networkDependentIdentity rows)
              blocked -> Left (networkFamilyBlocked family blocked)
  | otherwise = case providerStackRefText (providerNativeStackFamilyStackRef ref) of
      "aws-test" -> observeEc2Family runner "aws-test" 3
      "aws-eks" -> observeEksFamily runner ref
      "aws-eks-subzone" -> observeSubzoneFamily runner ref config
      _ -> pure (Left "native stack-family observer received an unsupported stack")

reapAwsNativeStackFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text ())
reapAwsNativeStackFamily runner waits ref config = do
  observed <- observeAwsNativeStackFamily runner ref config
  case observed of
    Left detail -> pure (Left detail)
    Right identities -> reapObservedNativeStackFamily runner waits ref config identities

-- | Re-observe and reap only when every currently present identity was named
-- by the independently read-back ownership manifest. Resources already absent
-- are harmless; a newly matching identity is an authority mismatch and
-- refuses before the first mutation.
reapAwsNativeStackFamilyWithin
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> m (Either Text ())
reapAwsNativeStackFamilyWithin runner waits ref config admitted
  | Just family <- providerNativeStackFamilyNetworkFamily ref =
      if null admitted
        then reapDeclaredNetworkFamily runner waits family
        else pure (Left "declared network family forbids a member allowlist")
  | otherwise = do
      observed <- observeAwsNativeStackFamily runner ref config
      case observed of
        Left detail -> pure (Left detail)
        Right identities
          | all (`elem` admitted) identities ->
              reapObservedNativeStackFamily runner waits ref config identities
          | otherwise ->
              pure
                ( Left
                    "native stack-family observation contained an identity outside the manifest allowlist"
                )

networkDependentIdentity :: Dependent -> Text
networkDependentIdentity row = case dependentKind row of
  DependentInterface -> "network-interface/" <> dependentIdentity row
  DependentSecurityGroup -> "security-group/" <> dependentIdentity row

-- The listing filter and every returned row must agree on the declared tags.
-- More than one VPC is ambiguous, including a remnant of an earlier run.
locateNetworkFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m -> AwsNetworkFamily -> m (Either Text (Maybe DependentsTarget))
locateNetworkFamily runner family = do
  output <-
    runAwsNativeStackFamilyCommand
      runner
      ( ["ec2", "describe-vpcs", "--filters"]
          ++ [ "Name=tag:" ++ Text.unpack key ++ ",Values=" ++ Text.unpack value
             | (key, value) <- networkFamilyVpcTags family
             ]
          ++ ["--query", "Vpcs[].{id:VpcId,tags:Tags}", "--output", "json"]
      )
  pure $
    if processExitCode output /= ExitSuccess
      then Left (renderFailure "locate declared network-family VPC" output)
      else do
        value <-
          first Text.pack (eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack (processStdout output))))
        rows <- case value of
          Array values -> traverse parseVpc (Vector.toList values)
          _ -> Left "network-family VPC listing was not an array"
        case rows of
          [] -> Right Nothing
          [vpc] -> Just <$> mkDependentsTarget vpc (networkFamilyCluster family)
          _ -> Left "network-family VPC tags matched more than one VPC"
 where
  parseVpc (Object row) = do
    vpc <- case KeyMap.lookup "id" row of
      Just (String value) -> Right value
      _ -> Left "network-family VPC identifier missing"
    tags <- case KeyMap.lookup "tags" row of
      Just (Array values) -> traverse parseTag (Vector.toList values)
      _ -> Left "network-family VPC tags missing"
    if all (`elem` tags) (networkFamilyVpcTags family)
      then Right vpc
      else Left "network-family VPC listing exceeded its exact tag predicate"
  parseVpc _ = Left "network-family VPC row malformed"
  parseTag (Object row) = case (KeyMap.lookup "Key" row, KeyMap.lookup "Value" row) of
    (Just (String key), Just (String value)) -> Right (key, value)
    _ -> Left "network-family VPC tag malformed"
  parseTag _ = Left "network-family VPC tag malformed"

reapDeclaredNetworkFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m -> AwsWaitEnvironment m -> AwsNetworkFamily -> m (Either Text ())
reapDeclaredNetworkFamily runner waits family = do
  located <- locateNetworkFamily runner family
  case located of
    Left detail -> pure (Left detail)
    Right Nothing -> pure (Right ())
    Right (Just target) -> do
      result <- clearNetworkFamily family (runAwsNativeStackFamilyCommand runner) waits target
      pure $ case result of
        Left detail -> Left detail
        Right repaired | null (repairRemaining repaired) -> Right ()
        Right repaired -> Left (networkFamilyBlocked family (repairRemaining repaired))

unadmittedNetworkDependent :: Dependent -> Bool
unadmittedNetworkDependent row = case dependentDisposition row of
  Admitted -> False
  HeldByService _ -> False
  NotAdmitted _ -> True

networkFamilyBlocked :: AwsNetworkFamily -> [Dependent] -> Text
networkFamilyBlocked family remaining =
  "blocked by declared network family: "
    <> renderDependents remaining
    <> "; next safe command: prodbox aws stack "
    <> (if family == TestVpcCniInterfaces then "test" else "eks")
    <> " destroy --yes"

reapObservedNativeStackFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> m (Either Text ())
reapObservedNativeStackFamily runner waits ref config identities
  | Just family <- providerNativeStackFamilyNetworkFamily ref =
      reapDeclaredNetworkFamily runner waits family
  | otherwise = case providerStackRefText (providerNativeStackFamilyStackRef ref) of
      "aws-test" -> reapEc2Family runner waits Nothing identities
      "aws-eks" -> reapEksFamily runner waits ref identities
      "aws-eks-subzone" -> reapSubzoneFamily runner ref config
      _ -> pure (Left "native stack-family reaper received an unsupported stack")

observeEksFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> m (Either Text [Text])
observeEksFamily runner ref = do
  network <- observeEc2Family runner awsEksPulumiStackName 2
  cluster <- observeEksCluster runner
  nodeGroup <- observeEksNodeGroup runner
  addon <- observeEksAddon runner
  legacyIamRoles <- observeLegacyAutoNamedEksRoles runner ref
  pure $ do
    networkRows <- network
    clusterFields <- cluster
    clusterRows <- case clusterFields of
      [] -> Right []
      [clusterArn, issuer] ->
        Right
          [ "eks-cluster/" <> clusterArn
          , "iam-oidc-provider/" <> oidcProviderArn ref issuer
          ]
      _ -> Left "EKS cluster observation returned an invalid exact tuple"
    nodeRows <- prefixSingleton "eks-nodegroup" =<< nodeGroup
    addonRows <- prefixSingleton "eks-addon" =<< addon
    legacyIamRoleRows <- legacyIamRoles
    boundedIdentities
      (networkRows <> clusterRows <> nodeRows <> addonRows <> legacyIamRoleRows)

-- | What of the EKS stack's own children still exists: the cluster, its node
-- group, and its add-on. Three reads that belong to the family's observation and
-- are made apart from the rest of it, so that a refusal in the rest (the legacy
-- roles, the network) does not decide whether the cluster is gone. A read that
-- fails is 'Left', never an absent child.
observeEksOwners
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> m (Either Text [Text])
observeEksOwners runner = do
  cluster <- observeEksCluster runner
  nodeGroup <- observeEksNodeGroup runner
  addon <- observeEksAddon runner
  pure $ do
    clusterFields <- cluster
    nodeRows <- prefixSingleton "eks-nodegroup" =<< nodeGroup
    addonRows <- prefixSingleton "eks-addon" =<< addon
    pure (["eks-cluster" | not (null clusterFields)] <> nodeRows <> addonRows)

-- | Repair admission requires AWS's exact absence response. A successful
-- empty/malformed projection is never positive evidence that a cluster is gone.
observeEksClusterAbsent :: (Monad m) => AwsNativeStackFamilyRunner m -> m (Either Text Bool)
observeEksClusterAbsent runner = do
  output <-
    runAwsNativeStackFamilyCommand
      runner
      ["eks", "describe-cluster", "--name", Text.unpack awsEksProvisionedClusterName, "--output", "json"]
  pure $ case processExitCode output of
    ExitSuccess -> Right False
    ExitFailure _
      | awsCliServiceErrorMatches "ResourceNotFoundException" "DescribeCluster" output ->
          Right True
      | otherwise -> Left "could not observe EKS cluster absence"

observeEksCluster
  :: (Monad m) => AwsNativeStackFamilyRunner m -> m (Either Text [Text])
observeEksCluster runner =
  exactTextAllowMissing
    runner
    "EKS cluster"
    [ "eks"
    , "describe-cluster"
    , "--name"
    , Text.unpack awsEksProvisionedClusterName
    , "--query"
    , "[cluster.arn,cluster.identity.oidc.issuer]"
    , "--output"
    , "text"
    ]

observeEksNodeGroup
  :: (Monad m) => AwsNativeStackFamilyRunner m -> m (Either Text [Text])
observeEksNodeGroup runner =
  exactTextAllowMissing
    runner
    "EKS node group"
    [ "eks"
    , "describe-nodegroup"
    , "--cluster-name"
    , Text.unpack awsEksProvisionedClusterName
    , "--nodegroup-name"
    , Text.unpack awsEksProvisionedNodeGroupName
    , "--query"
    , "nodegroup.nodegroupArn"
    , "--output"
    , "text"
    ]

observeEksAddon
  :: (Monad m) => AwsNativeStackFamilyRunner m -> m (Either Text [Text])
observeEksAddon runner =
  exactTextAllowMissing
    runner
    "EKS addon"
    [ "eks"
    , "describe-addon"
    , "--cluster-name"
    , Text.unpack awsEksProvisionedClusterName
    , "--addon-name"
    , "aws-ebs-csi-driver"
    , "--query"
    , "addon.addonArn"
    , "--output"
    , "text"
    ]

-- | The two IAM roles Pulumi auto-named before Sprint 7.33 are discoverable
-- only by their exact historical @Name@ tag. The Tagging API query is bounded,
-- pinned to IAM's global-service region, restricted to @iam:role@, and then
-- client-side checked against the signed account and the closed old/current
-- physical-name set. More than one historical candidate for either logical
-- role is ambiguity, never a wider cleanup family.
observeLegacyAutoNamedEksRoles
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> m (Either Text [Text])
observeLegacyAutoNamedEksRoles runner ref = do
  candidates <- traverse observeSpec legacyAutoNamedRoleSpecs
  pure (concat <$> sequence candidates)
 where
  accountId = providerNativeStackFamilyAccountId ref
  observeSpec spec = do
    listing <- collectTaggedRolePages runner (legacyRoleNameTag spec)
    pure $ do
      entries <- listing
      let classified = map (classifyEntry spec) entries
      roles <- sequence classified
      case concat roles of
        [] -> Right []
        [arn] -> Right ["iam-legacy-role/" <> arn]
        _ -> Left "legacy EKS IAM role observation was ambiguous"

  classifyEntry spec entry
    | ("Name", legacyRoleNameTag spec) `notElem` taggedResourceEntryTags entry =
        Left "legacy EKS IAM role query returned a row without its exact Name tag"
    | arn == currentArn spec = Right []
    | legacyArnPrefix spec `Text.isPrefixOf` arn = Right [arn]
    | otherwise =
        Left "legacy EKS IAM role query returned a role outside the closed physical-name family"
   where
    arn = taggedResourceEntryArn entry
    currentArn roleSpec =
      "arn:aws:iam::"
        <> accountId
        <> ":role/"
        <> legacyRoleCurrentName roleSpec
    legacyArnPrefix roleSpec =
      "arn:aws:iam::"
        <> accountId
        <> ":role/"
        <> legacyRoleArnPrefix roleSpec

data LegacyAutoNamedRoleSpec = LegacyAutoNamedRoleSpec
  { legacyRoleNameTag :: !Text
  , legacyRoleCurrentName :: !Text
  , legacyRoleArnPrefix :: !Text
  , legacyRoleManagedPolicyArns :: ![Text]
  }

legacyAutoNamedRoleSpecs :: [LegacyAutoNamedRoleSpec]
legacyAutoNamedRoleSpecs =
  [ roleSpec "cluster-role" "clusterRole-" ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
  , roleSpec
      "node-role"
      "nodeRole-"
      [ "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
      , "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      , "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      ]
  ]
 where
  roleSpec suffix physicalPrefix policies =
    let taggedName = awsEksPulumiStackName <> "-" <> suffix
        currentName = case [name | name <- awsEksIamRoleNames, suffix `Text.isSuffixOf` name] of
          [name] -> name
          _ -> error "registered EKS IAM role family omitted an exact legacy-role successor"
     in LegacyAutoNamedRoleSpec
          { legacyRoleNameTag = taggedName
          , legacyRoleCurrentName = currentName
          , legacyRoleArnPrefix = physicalPrefix
          , legacyRoleManagedPolicyArns = policies
          }

collectTaggedRolePages
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> m (Either Text [TaggedResourceEntry])
collectTaggedRolePages runner nameTag = collect Nothing [] [] 0
 where
  collect cursor seen accumulated pages
    | pages >= maximumTaggedResourcePages =
        pure (Left "legacy EKS IAM role listing exceeded its page bound")
    | otherwise = do
        output <- runAwsNativeStackFamilyCommand runner (arguments cursor)
        case processExitCode output of
          ExitFailure _ ->
            pure (Left (renderFailure "legacy EKS IAM role observation" output))
          ExitSuccess -> case parseTaggedResourcePage (processStdout output) of
            Left detail -> pure (Left (Text.pack detail))
            Right page ->
              let gathered = accumulated <> taggedResourcePageEntries page
                  consumed = pages + 1
               in case taggedResourcePageNextToken page of
                    Nothing -> pure (Right gathered)
                    Just next
                      | next `elem` seen ->
                          pure (Left "legacy EKS IAM role listing repeated a pagination cursor")
                      | otherwise -> collect (Just next) (next : seen) gathered consumed

  arguments cursor =
    [ "resourcegroupstaggingapi"
    , "get-resources"
    , "--resource-type-filters"
    , "iam:role"
    , "--tag-filters"
    , "Key=Name,Values=" <> Text.unpack nameTag
    , "--region"
    , Text.unpack (awsGlobalServiceRegion :: Text)
    , "--output"
    , "json"
    ]
      <> concat
        [ ["--pagination-token", Text.unpack token]
        | Just token <- [cursor]
        ]

observeEc2Family
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> Int
  -> m (Either Text [Text])
observeEc2Family runner stackName subnetCount = do
  vpc <- exactTaggedIds runner "VPC" "ec2" "describe-vpcs" "Vpcs[].VpcId" (stackName <> "-vpc") []
  gateway <-
    exactTaggedIds
      runner
      "internet gateway"
      "ec2"
      "describe-internet-gateways"
      "InternetGateways[].InternetGatewayId"
      (stackName <> "-igw")
      []
  routeTable <-
    exactTaggedIds
      runner
      "route table"
      "ec2"
      "describe-route-tables"
      "RouteTables[].RouteTableId"
      (stackName <> "-public-rt")
      []
  associations <-
    boundedTaggedIds
      runner
      "route-table association"
      subnetCount
      "ec2"
      "describe-route-tables"
      "RouteTables[].Associations[].RouteTableAssociationId"
      (stackName <> "-public-rt")
      []
  subnets <-
    traverse
      ( \index ->
          exactTaggedIds
            runner
            "subnet"
            "ec2"
            "describe-subnets"
            "Subnets[].SubnetId"
            (stackName <> "-public-subnet-" <> Text.pack (show index))
            []
      )
      [0 .. subnetCount - 1]
  securityGroup <-
    exactTaggedIds
      runner
      "security group"
      "ec2"
      "describe-security-groups"
      "SecurityGroups[].GroupId"
      (stackName <> "-sg")
      []
  instances <-
    if stackName == "aws-test"
      then
        traverse
          ( \index ->
              exactTaggedIds
                runner
                "instance"
                "ec2"
                "describe-instances"
                "Reservations[].Instances[].InstanceId"
                (stackName <> "-node-" <> Text.pack (show index))
                ["Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped"]
          )
          [0 .. 2 :: Int]
      else pure []
  -- Controller-created cluster groups have their own registry declaration and
  -- observer. Claiming them here too makes legacy adoption cross-claim an ID.
  pure $ do
    vpcIds <- vpc
    gatewayIds <- gateway
    routeTableIds <- routeTable
    associationIds <- associations
    subnetIds <- concat <$> sequence subnets
    securityGroupIds <- securityGroup
    instanceIds <- concat <$> sequence instances
    boundedIdentities
      ( prefixed "vpc" vpcIds
          <> prefixed "internet-gateway" gatewayIds
          <> prefixed "route-table" routeTableIds
          <> prefixed "route-table-association" associationIds
          <> prefixed "subnet" subnetIds
          <> prefixed "security-group" securityGroupIds
          <> prefixed "instance" instanceIds
      )

observeSubzoneFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text [Text])
observeSubzoneFamily runner ref config = case (providerNativeStackFamilyHostedZoneId ref, providerStackConfigView config) of
  (Just zoneId, AwsEksSubzoneConfig parentZoneId subzoneName) -> do
    zone <-
      exactTextAllowMissing
        runner
        "Route 53 hosted zone"
        [ "route53"
        , "get-hosted-zone"
        , "--id"
        , Text.unpack zoneId
        , "--query"
        , "HostedZone.[Id,Name]"
        , "--output"
        , "text"
        ]
    delegation <- observeParentDelegation runner parentZoneId subzoneName
    pure $ do
      zoneFields <- zone
      zoneRows <- case zoneFields of
        [] -> Right []
        [returnedId, returnedName]
          | normalizeHostedZoneId returnedId == zoneId
          , canonicalDnsName returnedName == canonicalDnsName subzoneName ->
              Right ["hosted-zone/" <> zoneId]
          | otherwise -> Left "Route 53 hosted-zone observation returned another coordinate"
        _ -> Left "Route 53 hosted-zone observation returned an invalid exact tuple"
      delegationRows <- delegation
      boundedIdentities (zoneRows <> delegationRows)
  _ -> pure (Left "native subzone family omitted its exact typed configuration")

observeParentDelegation
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> Text
  -> m (Either Text [Text])
observeParentDelegation runner parentZoneId subzoneName = do
  values <-
    exactText
      runner
      "Route 53 parent NS delegation"
      [ "route53"
      , "list-resource-record-sets"
      , "--hosted-zone-id"
      , Text.unpack parentZoneId
      , "--start-record-name"
      , Text.unpack (canonicalDnsName subzoneName)
      , "--start-record-type"
      , "NS"
      , "--max-items"
      , "1"
      , "--query"
      , "ResourceRecordSets[0].[Name,Type]"
      , "--output"
      , "text"
      ]
  pure $ do
    fields <- values
    case fields of
      [] -> Right []
      [name, recordType]
        | canonicalDnsName name == canonicalDnsName subzoneName
        , recordType == "NS" ->
            Right
              [ "route53-record/"
                  <> parentZoneId
                  <> "/NS/"
                  <> canonicalDnsName subzoneName
              ]
        | otherwise -> Right []
      _ -> Left "Route 53 parent delegation observation returned an invalid tuple"

reapEksFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> ProviderNativeStackFamilyRef
  -> [Text]
  -> m (Either Text ())
reapEksFamily runner waits ref identities =
  inSequence
    [ reapEksChild
        runner
        waits
        AddonAbsent
        "EKS add-on"
        (not (null (members "eks-addon" identities)))
        eksAddonStatusArguments
        [ "eks"
        , "delete-addon"
        , "--cluster-name"
        , Text.unpack awsEksProvisionedClusterName
        , "--addon-name"
        , awsEksStorageAddonName
        ]
    , reapEksChild
        runner
        waits
        NodeGroupAbsent
        "EKS node group"
        (not (null (members "eks-nodegroup" identities)))
        eksNodeGroupStatusArguments
        [ "eks"
        , "delete-nodegroup"
        , "--cluster-name"
        , Text.unpack awsEksProvisionedClusterName
        , "--nodegroup-name"
        , Text.unpack awsEksProvisionedNodeGroupName
        ]
    , runExactLayer
        runner
        "delete IAM OIDC provider"
        [ ["iam", "delete-open-id-connect-provider", "--open-id-connect-provider-arn", Text.unpack arn]
        | arn <- members "iam-oidc-provider" identities
        ]
    , reapEksChild
        runner
        waits
        ClusterAbsent
        "EKS cluster"
        (not (null (members "eks-cluster" identities)))
        eksClusterStatusArguments
        ["eks", "delete-cluster", "--name", Text.unpack awsEksProvisionedClusterName]
    , reapLegacyAutoNamedEksRoles runner ref identities
    , reapEc2Family runner waits (Just awsEksProvisionedClusterName) identities
    ]

-- | Run the steps in order, stopping at the first failure.
inSequence :: (Monad m) => [m (Either Text ())] -> m (Either Text ())
inSequence =
  foldr
    (\step rest -> step >>= either (pure . Left) (const rest))
    (pure (Right ()))

-- | The add-on the cluster's storage depends on.
awsEksStorageAddonName :: String
awsEksStorageAddonName = "aws-ebs-csi-driver"

-- | The status of the cluster's storage add-on, or its absence.
eksAddonStatusArguments :: [String]
eksAddonStatusArguments =
  [ "eks"
  , "describe-addon"
  , "--cluster-name"
  , Text.unpack awsEksProvisionedClusterName
  , "--addon-name"
  , awsEksStorageAddonName
  , "--query"
  , "addon.status"
  , "--output"
  , "text"
  ]

-- | The status of the cluster's node group, or its absence.
eksNodeGroupStatusArguments :: [String]
eksNodeGroupStatusArguments =
  [ "eks"
  , "describe-nodegroup"
  , "--cluster-name"
  , Text.unpack awsEksProvisionedClusterName
  , "--nodegroup-name"
  , Text.unpack awsEksProvisionedNodeGroupName
  , "--query"
  , "nodegroup.status"
  , "--output"
  , "text"
  ]

-- | The status of the cluster, or its absence.
eksClusterStatusArguments :: [String]
eksClusterStatusArguments =
  [ "eks"
  , "describe-cluster"
  , "--name"
  , Text.unpack awsEksProvisionedClusterName
  , "--query"
  , "cluster.status"
  , "--output"
  , "text"
  ]

-- | Delete one EKS child, then wait for it to be gone.
--
-- The describe comes first. A child already in @DELETING@ is waited for and not
-- deleted again, so the rerun after a wait that ran out of budget reaches the
-- same wait instead of a second delete the service may refuse. The wait is a
-- loop of describe calls under the fact's budget, not an @aws eks wait@ child,
-- which the Provider's thirty-second bound would stop long before an EKS child
-- finishes deleting.
reapEksChild
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> WaitFact
  -> Text
  -> Bool
  -> [String]
  -> [String]
  -> m (Either Text ())
reapEksChild runner waits fact label present describe delete
  | not present = pure (Right ())
  | otherwise = do
      status <- eksChildStatus runner label describe
      case status of
        Left detail -> pure (Left detail)
        Right Nothing -> pure (Right ())
        Right (Just current)
          | current == "DELETING" -> await
          | otherwise -> do
              deleted <- runExactLayer runner ("delete " <> label) [delete]
              case deleted of
                Left detail -> pure (Left detail)
                Right () -> await
 where
  await = first renderWaitFailure <$> awaitFact waits fact (pollEksChild runner label describe)

-- | The child's status, or 'Nothing' once the service answers that it is gone.
eksChildStatus
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> [String]
  -> m (Either Text (Maybe Text))
eksChildStatus runner label describe = do
  output <- runAwsNativeStackFamilyCommand runner describe
  pure $ case processExitCode output of
    ExitSuccess -> Right (Just (Text.toUpper (Text.strip (Text.pack (processStdout output)))))
    ExitFailure _
      | knownMissing output -> Right Nothing
      | otherwise -> Left (renderFailure ("describe " <> label) output)

pollEksChild
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> [String]
  -> m (WaitStep ())
pollEksChild runner label describe = do
  output <- runAwsNativeStackFamilyCommand runner describe
  pure $ case processExitCode output of
    ExitSuccess ->
      let current = Text.toUpper (Text.strip (Text.pack (processStdout output)))
       in if "FAILED" `Text.isInfixOf` current
            then WaitAbort (label <> " reported status " <> current)
            else WaitMore () (label <> " status " <> current)
    ExitFailure _
      | knownMissing output -> WaitDone
      | transientPollFailure output ->
          WaitMore () (renderFailure ("describe " <> label) output)
      | otherwise -> WaitAbort (renderFailure ("describe " <> label) output)

reapLegacyAutoNamedEksRoles
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> [Text]
  -> m (Either Text ())
reapLegacyAutoNamedEksRoles runner ref identities =
  case traverse roleAndPolicies (members "iam-legacy-role" identities) of
    Left detail -> pure (Left detail)
    Right roles -> foldM reapOne (Right ()) roles
 where
  accountPrefix =
    "arn:aws:iam::"
      <> providerNativeStackFamilyAccountId ref
      <> ":role/"

  roleAndPolicies arn = do
    roleName <-
      maybe
        (Left "legacy EKS IAM role ARN was outside the signed account")
        Right
        (Text.stripPrefix accountPrefix arn)
    if Text.any (== '/') roleName
      then Left "legacy EKS IAM role ARN contained an unsupported path"
      else Right ()
    case [ legacyRoleManagedPolicyArns spec
         | spec <- legacyAutoNamedRoleSpecs
         , legacyRoleArnPrefix spec `Text.isPrefixOf` roleName
         ] of
      [policies] -> Right (roleName, policies)
      _ -> Left "legacy EKS IAM role name was outside the closed auto-name family"

  reapOne (Left detail) _ = pure (Left detail)
  reapOne (Right ()) (roleName, policies) = do
    detached <-
      runExactLayer
        runner
        "detach legacy EKS IAM role policies"
        [ [ "iam"
          , "detach-role-policy"
          , "--role-name"
          , Text.unpack roleName
          , "--policy-arn"
          , Text.unpack policyArn
          ]
        | policyArn <- policies
        ]
    case detached of
      Left detail -> pure (Left detail)
      Right () ->
        runExactLayer
          runner
          "delete legacy EKS IAM role"
          [["iam", "delete-role", "--role-name", Text.unpack roleName]]

-- | Reap the EC2 chain. Sprint 4.111: between the instances and the layers they
-- held, the children a cluster's controllers left in the VPC are cleared by the
-- family's closed rule ("Prodbox.Lifecycle.AwsNetworkDependents"), because a
-- subnet or group deleted first ends in @DependencyViolation@. This does widen
-- what the chain removes, by class and not by name: an interface or a cluster
-- group that no manifest names is removed when the closed predicate admits it.
-- The doctrine admits that only for a registry-declared family, and the registry
-- declares none yet; the second increment of Sprint @4.111@ closes that gap. The
-- allowlist rule for every other identity is unchanged.
reapEc2Family
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AwsWaitEnvironment m
  -> Maybe Text
  -> [Text]
  -> m (Either Text ())
reapEc2Family runner waits cluster identities = do
  let instances = members "instance" identities
      associations = members "route-table-association" identities
      routeTables = members "route-table" identities
      subnets = members "subnet" identities
      securityGroups = members "security-group" identities
      gateways = members "internet-gateway" identities
      vpcs = members "vpc" identities
  terminated <- withMembers ["ec2", "terminate-instances", "--instance-ids"] instances
  continue terminated $ do
    waited <- awaitInstancesTerminated
    continue waited $ do
      cleared <- clearDependents vpcs securityGroups
      continue cleared $ do
        disassociated <-
          runExactLayer
            runner
            "disassociate route tables"
            [["ec2", "disassociate-route-table", "--association-id", Text.unpack value] | value <- associations]
        continue disassociated $ do
          deletedRoutes <-
            runExactLayer
              runner
              "delete route tables"
              [["ec2", "delete-route-table", "--route-table-id", Text.unpack value] | value <- routeTables]
          continue deletedRoutes $ do
            deletedSubnets <-
              runExactLayer
                runner
                "delete subnets"
                [["ec2", "delete-subnet", "--subnet-id", Text.unpack value] | value <- subnets]
            continue deletedSubnets $ do
              deletedGroups <-
                runExactLayer
                  runner
                  "delete security groups"
                  [["ec2", "delete-security-group", "--group-id", Text.unpack value] | value <- securityGroups]
              continue deletedGroups $ do
                detached <-
                  runExactLayer
                    runner
                    "detach internet gateways"
                    [ [ "ec2"
                      , "detach-internet-gateway"
                      , "--internet-gateway-id"
                      , Text.unpack gateway
                      , "--vpc-id"
                      , Text.unpack vpc
                      ]
                    | gateway <- gateways
                    , vpc <- vpcs
                    ]
                continue detached $ do
                  deletedGateways <-
                    runExactLayer
                      runner
                      "delete internet gateways"
                      [["ec2", "delete-internet-gateway", "--internet-gateway-id", Text.unpack value] | value <- gateways]
                  continue deletedGateways $
                    runExactLayer
                      runner
                      "delete VPCs"
                      [["ec2", "delete-vpc", "--vpc-id", Text.unpack value] | value <- vpcs]
 where
  continue result next = case result of
    Left detail -> pure (Left detail)
    Right () -> next
  -- Sprint 4.111: clear what the family's closed rule admits and wait for what a
  -- service holds, in the one VPC the manifest names. A remainder is a refusal
  -- that names it, taken here and not left to a subnet delete that cannot say
  -- what holds it. The groups this chain deletes itself are not a remainder.
  clearDependents vpcs ownedGroups = case vpcs of
    [vpc] -> case mkDependentsTarget vpc cluster of
      Left reason -> pure (Left ("network dependents: " <> reason))
      Right target -> do
        repaired <-
          clearNetworkFamilies
            (awsNetworkFamiliesForStack (maybe "aws-test" (const awsEksPulumiStackName) cluster))
            (runAwsNativeStackFamilyCommand runner)
            waits
            target
        pure (judgeRepair ownedGroups repaired)
    _ -> pure (Right ())
  judgeRepair ownedGroups repaired = case repaired of
    Left detail -> Left ("network dependents could not be listed: " <> detail)
    Right done
      | null (blockingOf ownedGroups done) -> Right ()
      | otherwise ->
          Left
            ( "blocked by network dependents the family cannot clear: "
                <> renderDependents (blockingOf ownedGroups done)
                <> " | "
                <> Text.intercalate "; " (map (Text.take 200) (repairNotes done))
            )
  blockingOf ownedGroups done =
    [d | d <- repairRemaining done, dependentIdentity d `notElem` ownedGroups]
  withMembers action values =
    if null values
      then runExactLayer runner "empty EC2 layer" []
      else runExactLayer runner "EC2 batch mutation" [action <> map Text.unpack values]
  awaitInstancesTerminated
    | null instanceIds = pure (Right ())
    | otherwise =
        first renderWaitFailure
          <$> awaitFact waits InstancesTerminated (pollInstancesTerminated runner instanceIds)
   where
    instanceIds = members "instance" identities

-- | The instances' states, by id filter so that an instance the service no
-- longer lists is simply absent from the answer and not an error that hides the
-- states of the others.
ec2InstanceStatesArguments :: [Text] -> [String]
ec2InstanceStatesArguments instanceIds =
  [ "ec2"
  , "describe-instances"
  , "--filters"
  , "Name=instance-id,Values=" <> intercalate "," (map Text.unpack instanceIds)
  , "--query"
  , "Reservations[].Instances[].State.Name"
  , "--output"
  , "text"
  ]

pollInstancesTerminated
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> [Text]
  -> m (WaitStep ())
pollInstancesTerminated runner instanceIds = do
  output <- runAwsNativeStackFamilyCommand runner (ec2InstanceStatesArguments instanceIds)
  pure $ case processExitCode output of
    ExitSuccess ->
      case filter (/= "terminated") (textValues (processStdout output)) of
        [] -> WaitDone
        outstanding ->
          WaitMore () ("EC2 instances still " <> Text.intercalate ", " (nub (sort outstanding)))
    ExitFailure _
      | transientPollFailure output ->
          WaitMore () (renderFailure "describe EC2 instances" output)
      | otherwise -> WaitAbort (renderFailure "describe EC2 instances" output)

reapSubzoneFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text ())
reapSubzoneFamily runner ref config = case (providerNativeStackFamilyHostedZoneId ref, providerStackConfigView config) of
  (Just zoneId, AwsEksSubzoneConfig parentZoneId subzoneName) -> do
    delegation <- exactParentDelegationValue runner parentZoneId subzoneName
    case delegation of
      Left detail -> pure (Left detail)
      Right Nothing -> pruneThenDeleteZone zoneId
      Right (Just recordSet) -> do
        let changeBatch =
              object
                [ "Comment" .= ("prodbox exact native stack-family cleanup" :: Text)
                , "Changes"
                    .= [object ["Action" .= ("DELETE" :: Text), "ResourceRecordSet" .= recordSet]]
                ]
            encoded = LazyByteStringChar8.unpack (encode changeBatch)
        deleted <-
          runExactLayer
            runner
            "delete Route 53 parent NS delegation"
            [
              [ "route53"
              , "change-resource-record-sets"
              , "--hosted-zone-id"
              , Text.unpack parentZoneId
              , "--change-batch"
              , encoded
              ]
            ]
        case deleted of
          Left detail -> pure (Left detail)
          Right () -> pruneThenDeleteZone zoneId
  _ -> pure (Left "native subzone reaper omitted its exact typed configuration")
 where
  pruneThenDeleteZone zoneId = do
    pruned <- pruneZoneRecordSets zoneId
    case pruned of
      Left detail -> pure (Left detail)
      Right () -> deleteZone zoneId

  -- Route 53 refuses to delete a hosted zone that still holds any record other
  -- than its SOA and NS (HostedZoneNotEmpty). The per-run subzone collects the
  -- public-edge A record and the DNS01 challenge records, none of which the stack
  -- declares, so the zone is emptied before it is deleted. What is deleted is every
  -- record set the listing returns other than a SOA or NS, whoever wrote it: this
  -- runs only for the zone the ownership manifest admitted and whose name matched
  -- the observation, which is what bounds it. Measured with the installed AWS CLI
  -- against a mock endpoint: it pages the listing itself and applies @--query@ to
  -- the merged result, so the output is one array. A non-apex NS record (a child
  -- delegation, which nothing here writes) is kept by the filter and would make the
  -- zone delete fail closed with HostedZoneNotEmpty.
  pruneZoneRecordSets zoneId = do
    listed <-
      runAwsNativeStackFamilyCommand
        runner
        [ "route53"
        , "list-resource-record-sets"
        , "--hosted-zone-id"
        , Text.unpack zoneId
        , "--query"
        , "ResourceRecordSets[?Type != 'SOA' && Type != 'NS']"
        , "--output"
        , "json"
        ]
    case processExitCode listed of
      ExitFailure _
        | knownMissing listed -> pure (Right ())
        | otherwise -> pure (Left (renderFailure "list Route 53 hosted zone records" listed))
      ExitSuccess ->
        case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack (processStdout listed))) of
          Right (Array records)
            | Vector.null records -> pure (Right ())
            | otherwise ->
                runExactLayer
                  runner
                  "delete Route 53 hosted zone records"
                  [
                    [ "route53"
                    , "change-resource-record-sets"
                    , "--hosted-zone-id"
                    , Text.unpack zoneId
                    , "--change-batch"
                    , LazyByteStringChar8.unpack
                        ( encode
                            ( object
                                [ "Comment" .= ("prodbox exact native stack-family cleanup" :: Text)
                                , "Changes"
                                    .= [ object ["Action" .= ("DELETE" :: Text), "ResourceRecordSet" .= record]
                                       | record <- Vector.toList records
                                       ]
                                ]
                            )
                        )
                    ]
                  ]
          Right _ -> pure (Left "native subzone reaper read a record listing that was not an array")
          Left detail ->
            pure (Left ("native subzone reaper could not read the zone's records: " <> Text.pack detail))

  deleteZone zoneId =
    runExactLayer
      runner
      "delete Route 53 hosted zone"
      [["route53", "delete-hosted-zone", "--id", Text.unpack zoneId]]

exactParentDelegationValue
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> Text
  -> m (Either Text (Maybe Value))
exactParentDelegationValue runner parentZoneId subzoneName = do
  output <-
    runAwsNativeStackFamilyCommand
      runner
      [ "route53"
      , "list-resource-record-sets"
      , "--hosted-zone-id"
      , Text.unpack parentZoneId
      , "--start-record-name"
      , Text.unpack (canonicalDnsName subzoneName)
      , "--start-record-type"
      , "NS"
      , "--max-items"
      , "1"
      , "--output"
      , "json"
      ]
  pure $ case processExitCode output of
    ExitFailure _ -> Left (renderFailure "observe Route 53 parent NS delegation" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      rows <- case KeyMap.lookup "ResourceRecordSets" root of
        Just (Array values) -> Right (Vector.toList values)
        _ -> Left "Route 53 response omitted ResourceRecordSets"
      case rows of
        [] -> Right Nothing
        Object row : _ -> do
          name <- requireStringField "Name" row
          recordType <- requireStringField "Type" row
          if canonicalDnsName name == canonicalDnsName subzoneName && recordType == "NS"
            then Right (Just (Object row))
            else Right Nothing
        _ -> Left "Route 53 record-set row was not an object"

exactTaggedIds
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> String
  -> String
  -> String
  -> Text
  -> [String]
  -> m (Either Text [Text])
exactTaggedIds runner label service operation query name extraFilters =
  boundedTaggedIds runner label 1 service operation query name extraFilters

boundedTaggedIds
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> Int
  -> String
  -> String
  -> String
  -> Text
  -> [String]
  -> m (Either Text [Text])
boundedTaggedIds runner label maximumCount service operation query name extraFilters =
  boundedTextValues
    runner
    label
    maximumCount
    ( [ service
      , operation
      , "--filters"
      , "Name=tag:Name,Values=" <> Text.unpack name
      , "Name=tag:prodbox.io/managed-by,Values=prodbox"
      ]
        <> extraFilters
        <> ["--query", query, "--output", "text"]
    )

boundedTextValues
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> Int
  -> [String]
  -> m (Either Text [Text])
boundedTextValues runner label maximumCount arguments = do
  values <- exactText runner label arguments
  pure $ do
    exact <- values
    if length exact <= maximumCount
      then Right exact
      else Left (label <> " observation exceeded its exact cardinality")

exactTextAllowMissing
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> [String]
  -> m (Either Text [Text])
exactTextAllowMissing runner label arguments = do
  output <- runAwsNativeStackFamilyCommand runner arguments
  pure $ case processExitCode output of
    ExitSuccess -> Right (textValues (processStdout output))
    ExitFailure _
      | knownMissing output -> Right []
      | otherwise -> Left (renderFailure ("observe " <> label) output)

exactText
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> [String]
  -> m (Either Text [Text])
exactText runner label arguments = do
  output <- runAwsNativeStackFamilyCommand runner arguments
  pure $ case processExitCode output of
    ExitSuccess -> Right (textValues (processStdout output))
    ExitFailure _ -> Left (renderFailure ("observe " <> label) output)

runExactLayer
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Text
  -> [[String]]
  -> m (Either Text ())
runExactLayer runner label = foldM step (Right ())
 where
  step (Left detail) _ = pure (Left detail)
  step (Right ()) arguments = do
    output <- runAwsNativeStackFamilyCommand runner arguments
    pure $ case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _
        | knownMissing output -> Right ()
        | otherwise -> Left (renderFailure label output)

textValues :: String -> [Text]
textValues =
  filter (\value -> not (Text.null value) && Text.toLower value /= "none")
    . Text.words
    . Text.pack

prefixSingleton :: Text -> [Text] -> Either Text [Text]
prefixSingleton prefix values = case values of
  [] -> Right []
  [value] -> Right [prefix <> "/" <> value]
  _ -> Left (prefix <> " exact observation returned more than one member")

prefixed :: Text -> [Text] -> [Text]
prefixed prefix = map ((prefix <>) . ("/" <>))

members :: Text -> [Text] -> [Text]
members kind = foldr collect []
 where
  collect identity values = case Text.stripPrefix (kind <> "/") identity of
    Just value -> value : values
    Nothing -> values

boundedIdentities :: [Text] -> Either Text [Text]
boundedIdentities raw
  | length raw > 4096 = Left "native stack-family observation exceeded 4096 identities"
  | any invalid raw = Left "native stack-family observation returned an invalid identity"
  | length ordered /= length (nub ordered) =
      Left "native stack-family observation returned a duplicate identity"
  | otherwise = Right ordered
 where
  ordered = sort raw
  invalid value =
    Text.null value
      || Text.length value > 2048
      || Text.any (`elem` ['|', '\n', '\r']) value

oidcProviderArn :: ProviderNativeStackFamilyRef -> Text -> Text
oidcProviderArn ref issuer =
  "arn:aws:iam::"
    <> providerNativeStackFamilyAccountId ref
    <> ":oidc-provider/"
    <> maybe issuer id (Text.stripPrefix "https://" issuer)

normalizeHostedZoneId :: Text -> Text
normalizeHostedZoneId value = maybe value id (Text.stripPrefix "/hostedzone/" value)

canonicalDnsName :: Text -> Text
canonicalDnsName raw =
  let normalized = Text.toLower (Text.strip raw)
   in if Text.isSuffixOf "." normalized then normalized else normalized <> "."

knownMissing :: ProcessOutput -> Bool
knownMissing output =
  let detail = Text.toLower (Text.pack (processStderr output <> processStdout output))
   in any
        (`Text.isInfixOf` detail)
        [ "resourcenotfoundexception"
        , "invalidgroup.notfound"
        , "invalidvpcid.notfound"
        , "invalidsubnetid.notfound"
        , "invalidroute.notfound"
        , "invalidassociationid.notfound"
        , "invalidinternetgatewayid.notfound"
        , "invalidinstanceid.notfound"
        , "nosuchentity"
        , "nosuchhostedzone"
        , "does not exist"
        ]

renderFailure :: Text -> ProcessOutput -> Text
renderFailure label output =
  Text.take 2048 (label <> " failed: " <> Text.pack (processStderr output <> processStdout output))

decodeObject :: String -> Either Text (KeyMap.KeyMap Value)
decodeObject payload = case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack payload)) of
  Right (Object value) -> Right value
  _ -> Left "AWS response was not a JSON object"

requireStringField :: Text -> KeyMap.KeyMap Value -> Either Text Text
requireStringField key row = case KeyMap.lookup (fromStringKey key) row of
  Just (String value) -> Right value
  _ -> Left ("AWS response omitted text field " <> key)

fromStringKey :: Text -> Key.Key
fromStringKey = Key.fromText
