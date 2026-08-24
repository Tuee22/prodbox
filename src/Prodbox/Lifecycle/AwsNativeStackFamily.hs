{-# LANGUAGE OverloadedStrings #-}

-- | Checkpoint-independent AWS observation and desired-absence execution for
-- the three registered per-run Pulumi stack families.  Every query is bound
-- to a deterministic name, exact hosted-zone coordinate, or exact EKS child
-- coordinate.  The boundary never enumerates an account-wide prefix or treats
-- a failed query as an empty family.
module Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
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
import Data.ByteString.Lazy.Char8 qualified as LazyByteStringChar8
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Aws.Region (awsGlobalServiceRegion)
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
  , awsEksPulumiStackName
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
observeAwsNativeStackFamily runner ref config =
  case providerStackRefText (providerNativeStackFamilyStackRef ref) of
    "aws-test" -> observeEc2Family runner "aws-test" 3 False
    "aws-eks" -> observeEksFamily runner ref
    "aws-eks-subzone" -> observeSubzoneFamily runner ref config
    _ -> pure (Left "native stack-family observer received an unsupported stack")

reapAwsNativeStackFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text ())
reapAwsNativeStackFamily runner ref config = do
  observed <- observeAwsNativeStackFamily runner ref config
  case observed of
    Left detail -> pure (Left detail)
    Right identities -> reapObservedNativeStackFamily runner ref config identities

-- | Re-observe and reap only when every currently present identity was named
-- by the independently read-back ownership manifest. Resources already absent
-- are harmless; a newly matching identity is an authority mismatch and
-- refuses before the first mutation.
reapAwsNativeStackFamilyWithin
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> m (Either Text ())
reapAwsNativeStackFamilyWithin runner ref config admitted = do
  observed <- observeAwsNativeStackFamily runner ref config
  case observed of
    Left detail -> pure (Left detail)
    Right identities
      | all (`elem` admitted) identities ->
          reapObservedNativeStackFamily runner ref config identities
      | otherwise ->
          pure
            ( Left
                "native stack-family observation contained an identity outside the manifest allowlist"
            )

reapObservedNativeStackFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> m (Either Text ())
reapObservedNativeStackFamily runner ref config identities =
  case providerStackRefText (providerNativeStackFamilyStackRef ref) of
    "aws-test" -> reapEc2Family runner identities
    "aws-eks" -> reapEksFamily runner ref identities
    "aws-eks-subzone" -> reapSubzoneFamily runner ref config
    _ -> pure (Left "native stack-family reaper received an unsupported stack")

observeEksFamily
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> m (Either Text [Text])
observeEksFamily runner ref = do
  network <- observeEc2Family runner awsEksPulumiStackName 2 True
  cluster <-
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
  nodeGroup <-
    exactTextAllowMissing
      runner
      "EKS node group"
      [ "eks"
      , "describe-nodegroup"
      , "--cluster-name"
      , Text.unpack awsEksProvisionedClusterName
      , "--nodegroup-name"
      , Text.unpack awsEksNodeGroupName
      , "--query"
      , "nodegroup.nodegroupArn"
      , "--output"
      , "text"
      ]
  addon <-
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
  -> Bool
  -> m (Either Text [Text])
observeEc2Family runner stackName subnetCount includeEksSecurityGroups = do
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
  eksSecurityGroups <-
    if includeEksSecurityGroups
      then
        boundedTextValues
          runner
          "EKS cluster security group"
          32
          [ "ec2"
          , "describe-security-groups"
          , "--filters"
          , "Name=tag:aws:eks:cluster-name,Values="
              <> Text.unpack awsEksProvisionedClusterName
          , "--query"
          , "SecurityGroups[].GroupId"
          , "--output"
          , "text"
          ]
      else pure (Right [])
  pure $ do
    vpcIds <- vpc
    gatewayIds <- gateway
    routeTableIds <- routeTable
    associationIds <- associations
    subnetIds <- concat <$> sequence subnets
    securityGroupIds <- securityGroup
    instanceIds <- concat <$> sequence instances
    eksSecurityGroupIds <- eksSecurityGroups
    boundedIdentities
      ( prefixed "vpc" vpcIds
          <> prefixed "internet-gateway" gatewayIds
          <> prefixed "route-table" routeTableIds
          <> prefixed "route-table-association" associationIds
          <> prefixed "subnet" subnetIds
          <> prefixed "security-group" (securityGroupIds <> eksSecurityGroupIds)
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
  -> ProviderNativeStackFamilyRef
  -> [Text]
  -> m (Either Text ())
reapEksFamily runner ref identities = do
  addon <-
    runExactLayer
      runner
      "delete EKS addon"
      [ [ "eks"
        , "delete-addon"
        , "--cluster-name"
        , Text.unpack awsEksProvisionedClusterName
        , "--addon-name"
        , "aws-ebs-csi-driver"
        ]
      | not (null (members "eks-addon" identities))
      ]
  case addon of
    Left detail -> pure (Left detail)
    Right () -> do
      addonWait <-
        runExactLayer
          runner
          "wait for EKS addon deletion"
          [ [ "eks"
            , "wait"
            , "addon-deleted"
            , "--cluster-name"
            , Text.unpack awsEksProvisionedClusterName
            , "--addon-name"
            , "aws-ebs-csi-driver"
            ]
          | not (null (members "eks-addon" identities))
          ]
      case addonWait of
        Left detail -> pure (Left detail)
        Right () -> do
          node <-
            runExactLayer
              runner
              "delete EKS node group"
              [ [ "eks"
                , "delete-nodegroup"
                , "--cluster-name"
                , Text.unpack awsEksProvisionedClusterName
                , "--nodegroup-name"
                , Text.unpack awsEksNodeGroupName
                ]
              | not (null (members "eks-nodegroup" identities))
              ]
          case node of
            Left detail -> pure (Left detail)
            Right () -> do
              nodeWait <-
                runExactLayer
                  runner
                  "wait for EKS node-group deletion"
                  [ [ "eks"
                    , "wait"
                    , "nodegroup-deleted"
                    , "--cluster-name"
                    , Text.unpack awsEksProvisionedClusterName
                    , "--nodegroup-name"
                    , Text.unpack awsEksNodeGroupName
                    ]
                  | not (null (members "eks-nodegroup" identities))
                  ]
              case nodeWait of
                Left detail -> pure (Left detail)
                Right () -> do
                  oidc <-
                    runExactLayer
                      runner
                      "delete IAM OIDC provider"
                      [ ["iam", "delete-open-id-connect-provider", "--open-id-connect-provider-arn", Text.unpack arn]
                      | arn <- members "iam-oidc-provider" identities
                      ]
                  case oidc of
                    Left detail -> pure (Left detail)
                    Right () -> do
                      cluster <-
                        runExactLayer
                          runner
                          "delete EKS cluster"
                          [ ["eks", "delete-cluster", "--name", Text.unpack awsEksProvisionedClusterName]
                          | not (null (members "eks-cluster" identities))
                          ]
                      case cluster of
                        Left detail -> pure (Left detail)
                        Right () -> do
                          clusterWait <-
                            runExactLayer
                              runner
                              "wait for EKS cluster deletion"
                              [ ["eks", "wait", "cluster-deleted", "--name", Text.unpack awsEksProvisionedClusterName]
                              | not (null (members "eks-cluster" identities))
                              ]
                          case clusterWait of
                            Left detail -> pure (Left detail)
                            Right () -> do
                              legacyRoles <-
                                reapLegacyAutoNamedEksRoles runner ref identities
                              case legacyRoles of
                                Left detail -> pure (Left detail)
                                Right () -> reapEc2Family runner identities

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

reapEc2Family
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> [Text]
  -> m (Either Text ())
reapEc2Family runner identities = do
  let instances = members "instance" identities
      associations = members "route-table-association" identities
      routeTables = members "route-table" identities
      subnets = members "subnet" identities
      securityGroups = members "security-group" identities
      gateways = members "internet-gateway" identities
      vpcs = members "vpc" identities
  terminated <- withMembers ["ec2", "terminate-instances", "--instance-ids"] instances
  continue terminated $ do
    waited <- withMembers ["ec2", "wait", "instance-terminated", "--instance-ids"] instances
    continue waited $ do
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
  withMembers action values =
    if null values
      then runExactLayer runner "empty EC2 layer" []
      else runExactLayer runner "EC2 batch mutation" [action <> map Text.unpack values]

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
      Right Nothing -> deleteZone zoneId
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
          Right () -> deleteZone zoneId
  _ -> pure (Left "native subzone reaper omitted its exact typed configuration")
 where
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

awsEksNodeGroupName :: Text
awsEksNodeGroupName = awsEksPulumiStackName <> "-node-group"

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
