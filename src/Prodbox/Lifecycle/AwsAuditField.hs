{-# LANGUAGE OverloadedStrings #-}

-- | The enumeration an audit runs: what one stack's declared field holds in the
-- provider, class by class, over a runner a test can script.
--
-- Three sources answer a class, and a class is answered only when every source
-- that covers it did.
--
-- * __Exact names.__ The stack's own resources by the deterministic names and
--   managed-by tag it stamps, through the same observer the destroy decision
--   uses ("Prodbox.Lifecycle.AwsNativeStackFamily").
-- * __The VPC.__ Everything inside the VPC the first source located, whoever
--   made it: interfaces, security groups, load balancers, NAT gateways,
--   endpoints and instances. This is the source that sees a child an in-cluster
--   controller made after the plan was confirmed, which no list of identities
--   could have named in advance. A VPC that does not exist holds nothing, so an
--   absent VPC answers every class inside it as empty; a VPC that could not be
--   located answers none of them.
-- * __Registered names and tags.__ The registered IAM roles and policies by
--   exact name, and the per-run volumes the cluster owns by tag.
--
-- A query that fails, or answers in a shape the parser does not read, leaves a
-- gap on its class. It is never read as an empty answer.
module Prodbox.Lifecycle.AwsAuditField
  ( AuditQuery (..)
  , vpcRootedQueries
  , auditStackField
  , locateTaggedVpcs
  , probeStackOwners
  , auditPositiveControl
  , stateBucketControlArn
  , auditReadOnlyScript
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (isPrefixOf, nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
  , observeEksOwners
  )
import Prodbox.Lifecycle.EbsVolume
  ( EbsVolume (..)
  , EbsVolumeId (..)
  , EbsVolumeScope (..)
  , ebsDescribeVolumesArgs
  , parseDescribeVolumesPayload
  )
import Prodbox.Lifecycle.OwnedResourceTags (longLivedPulumiStateBucketTags)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderNativeStackFamilyRef
  , ProviderStackConfig
  , providerNativeStackFamilyAccountId
  , providerNativeStackFamilyRegion
  , providerNativeStackFamilyStackRef
  , providerStackRefText
  )
import Prodbox.Lifecycle.TaggedResourceQuery
  ( TaggedResourceEntry (..)
  , TaggedResourceFilter (..)
  , TaggedResourcePage (..)
  , maximumTaggedResourcePages
  , parseTaggedResourcePage
  , taggedResourceQueryArgs
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksIamManagedPolicyNames
  , awsEksIamRoleNames
  , awsEksProvisionedClusterName
  , awsEksPulumiStackName
  , awsTestPulumiStackName
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

-- | One read the VPC source issues: the class it answers, the argument vector of
-- the single @aws@ call, and how to read its JSON into rows.
data AuditQuery = AuditQuery
  { auditQueryClass :: !AuditClass
  , auditQueryArgs :: ![String]
  , auditQueryRows :: Value -> Either Text [AuditRow]
  }

-- | Every read that enumerates the inside of one VPC. All are describe calls.
vpcRootedQueries :: Text -> [AuditQuery]
vpcRootedQueries vpcId =
  [ query
      AuditSubnet
      [ "ec2"
      , "describe-subnets"
      , "--filters"
      , vpcFilter
      , "--query"
      , "Subnets[].{id:SubnetId,state:State}"
      ]
      (projection AuditSubnet "id" (fieldValue "state"))
  , query
      AuditRouteTable
      [ "ec2"
      , "describe-route-tables"
      , "--filters"
      , vpcFilter
      , "--query"
      , "RouteTables[].{id:RouteTableId}"
      ]
      (projection AuditRouteTable "id" noDetail)
  , query
      AuditInternetGateway
      [ "ec2"
      , "describe-internet-gateways"
      , "--filters"
      , "Name=attachment.vpc-id,Values=" <> Text.unpack vpcId
      , "--query"
      , "InternetGateways[].{id:InternetGatewayId}"
      ]
      (projection AuditInternetGateway "id" noDetail)
  , query
      AuditSecurityGroup
      [ "ec2"
      , "describe-security-groups"
      , "--filters"
      , vpcFilter
      , "--query"
      , "SecurityGroups[].{id:GroupId,name:GroupName}"
      ]
      (projection AuditSecurityGroup "id" (fieldValue "name"))
  , query
      AuditNetworkInterface
      [ "ec2"
      , "describe-network-interfaces"
      , "--filters"
      , vpcFilter
      , "--query"
      , "NetworkInterfaces[].{id:NetworkInterfaceId,status:Status,requester_managed:RequesterManaged,type:InterfaceType,description:Description}"
      ]
      (projection AuditNetworkInterface "id" networkInterfaceDetail)
  , query
      AuditNatGateway
      [ "ec2"
      , "describe-nat-gateways"
      , "--filter"
      , vpcFilter
      , "Name=state,Values=pending,available,deleting"
      , "--query"
      , "NatGateways[].{id:NatGatewayId,state:State}"
      ]
      (projection AuditNatGateway "id" (fieldValue "state"))
  , query
      AuditVpcEndpoint
      [ "ec2"
      , "describe-vpc-endpoints"
      , "--filters"
      , vpcFilter
      , "--query"
      , "VpcEndpoints[].{id:VpcEndpointId,state:State,service:ServiceName}"
      ]
      (liveProjection AuditVpcEndpoint "id" endpointDetail)
  , query
      AuditInstance
      [ "ec2"
      , "describe-instances"
      , "--filters"
      , vpcFilter
      , "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped"
      , "--query"
      , "Reservations[].Instances[].{id:InstanceId,state:State.Name}"
      ]
      (projection AuditInstance "id" (fieldValue "state"))
  , query
      AuditLoadBalancer
      [ "elbv2"
      , "describe-load-balancers"
      , "--query"
      , "LoadBalancers[].{id:LoadBalancerArn,vpc:VpcId,state:State.Code}"
      ]
      (insideVpc AuditLoadBalancer vpcId "id" "vpc" (fieldValue "state"))
  , query
      AuditLoadBalancer
      [ "elb"
      , "describe-load-balancers"
      , "--query"
      , "LoadBalancerDescriptions[].{id:LoadBalancerName,vpc:VPCId}"
      ]
      (insideVpc AuditLoadBalancer vpcId "id" "vpc" noDetail)
  ]
 where
  vpcFilter = "Name=vpc-id,Values=" <> Text.unpack vpcId
  query class' args rows =
    AuditQuery
      { auditQueryClass = class'
      , auditQueryArgs = args <> ["--output", "json"]
      , auditQueryRows = rows
      }

-- | The audit of one stack's field: one answer for every class the stack
-- declares. 'Left' only for a stack the audit does not know.
auditStackField
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> m (Either Text (AuditStack, [(AuditClass, AuditAnswer)]))
auditStackField runner ref config =
  case auditStackOfRef (providerStackRefText (providerNativeStackFamilyStackRef ref)) of
    Nothing -> pure (Left "the audit does not know this stack")
    Just stack -> do
      exact <- observeAwsNativeStackFamily runner ref config
      let exactAnswers = exactNamedAnswers stack exact
      -- The VPCs are located by their own reads. An unrelated refusal in the
      -- exact-name observation (a cluster that is still creating, an add-on
      -- lookup the role cannot make) must not switch off the reading of the
      -- children a controller left in the VPC, which is what the audit is for.
      located <-
        if stackHasNetwork stack
          then locateVpcs runner stack
          else pure (Right [])
      rooted <-
        if stackHasNetwork stack
          then vpcRootedAnswers runner located
          else pure Map.empty
      registered <-
        if stack == AuditAwsEks
          then registeredAnswers runner ref
          else pure Map.empty
      let sources = [exactAnswers, locatedVpcAnswers stack located, rooted, registered]
          answerFor class' =
            case [answer | source <- sources, Just answer <- [Map.lookup class' source]] of
              [] -> auditUnanswered "no query covers the class"
              answers -> mergeAuditAnswers answers
      pure (Right (stack, [(class', answerFor class') | class' <- auditStackClasses stack]))

stackHasNetwork :: AuditStack -> Bool
stackHasNetwork stack = stack /= AuditAwsEksSubzone

-- | The classes the exact-name observer covers for a stack.
exactCoveredClasses :: AuditStack -> [AuditClass]
exactCoveredClasses stack = case stack of
  AuditAwsTest ->
    [AuditVpc, AuditSubnet, AuditRouteTable, AuditInternetGateway, AuditSecurityGroup, AuditInstance]
  AuditAwsEks ->
    [ AuditVpc
    , AuditSubnet
    , AuditRouteTable
    , AuditInternetGateway
    , AuditSecurityGroup
    , AuditEksCluster
    , AuditEksNodeGroup
    , AuditEksAddon
    , AuditIamRole
    ]
  AuditAwsEksSubzone -> [AuditHostedZone, AuditDelegationRecord]

exactNamedAnswers
  :: AuditStack -> Either Text [Text] -> Map AuditClass AuditAnswer
exactNamedAnswers stack observed = case observed of
  Left detail ->
    Map.fromList [(class', auditUnanswered detail) | class' <- exactCoveredClasses stack]
  Right identities -> case traverse exactRow identities of
    Left detail ->
      Map.fromList [(class', auditUnanswered detail) | class' <- exactCoveredClasses stack]
    Right rows ->
      Map.fromList
        [ (class', auditAnswered [row | Just row <- rows, auditRowClass row == class'])
        | class' <- exactCoveredClasses stack
        ]

-- | One identity the exact-name observer reported, as a row. Route-table
-- associations are subordinate to their route tables and are not a class.
exactRow :: Text -> Either Text (Maybe AuditRow)
exactRow identity = case Text.breakOn "/" identity of
  (kind, rest)
    | Text.null rest -> Left ("the exact-name observation returned an identity with no kind: " <> kind)
    | otherwise ->
        let value = Text.drop 1 rest
         in case kind of
              "vpc" -> row AuditVpc value ""
              "subnet" -> row AuditSubnet value ""
              "route-table" -> row AuditRouteTable value ""
              "route-table-association" -> Right Nothing
              "internet-gateway" -> row AuditInternetGateway value ""
              "security-group" -> row AuditSecurityGroup value ""
              "instance" -> row AuditInstance value ""
              "eks-cluster" -> row AuditEksCluster value ""
              "eks-nodegroup" -> row AuditEksNodeGroup value ""
              "eks-addon" -> row AuditEksAddon value ""
              -- The provider is derived from the live cluster's issuer, so it is
              -- named only while the cluster is, and a provider that outlived its
              -- cluster is invisible to it. The class is read from IAM's own tag
              -- listing instead ('registeredAnswers').
              "iam-oidc-provider" -> Right Nothing
              "iam-legacy-role" -> row AuditIamRole value "legacy auto-named"
              "hosted-zone" -> row AuditHostedZone value ""
              "route53-record" -> row AuditDelegationRecord value ""
              _ -> Left ("the exact-name observation returned an unrecognized identity kind: " <> kind)
 where
  row class' value detail = Right (Just (mkAuditRow class' value detail))

-- | The VPCs a stack's field lives in: every VPC that carries the stack's exact
-- name and managed-by tags and, for an EKS stack, every VPC its cluster's own
-- marks name (the group EKS tags with the cluster, and the interfaces the CNI
-- tags with it), so a VPC whose tags were edited away is still read. More than
-- one is not an error: each is audited. A read that fails leaves the VPC
-- unlocated, never absent.
locateVpcs
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AuditStack
  -> m (Either Text [Text])
locateVpcs runner stack = do
  tagged <- locateTaggedVpcs runner stack
  anchored <- traverse (vpcIdsOf runner) (anchorQueries stack)
  pure (fmap (nub . sort . concat) (sequence (tagged : anchored)))

-- | The VPCs that carry the stack's exact name and managed-by tags, and nothing
-- else: the only VPCs a repair may act in. The cluster's marks name VPCs to
-- /read/ ('locateVpcs'); a VPC that only a mark names, such as one a previous run
-- of the same cluster left behind, is residue to report and never a place to
-- delete in. The read does not depend on the exact-name observation, so an
-- unrelated refusal in that observation does not decide where a repair may act.
locateTaggedVpcs
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AuditStack
  -> m (Either Text [Text])
locateTaggedVpcs runner stack =
  fmap (nub . sort) <$> vpcIdsOf runner (taggedQuery stack)

-- | What still owns the interfaces and groups inside the stack's VPCs: for the
-- EKS stack its cluster, node group, and add-on, and for either stack every
-- instance in the VPCs. A handful of reads, made apart from the whole field so
-- that deciding whether the owners are gone does not enumerate it; 'Left' when a
-- read failed, because an owner that could not be seen is not an owner that is
-- gone.
probeStackOwners
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AuditStack
  -> [Text]
  -> m (Either Text [Text])
probeStackOwners runner stack vpcs = do
  eks <- if stack == AuditAwsEks then observeEksOwners runner else pure (Right [])
  instances <- traverse probeInstances vpcs
  pure $ do
    eksOwners <- eks
    found <- sequence instances
    pure (eksOwners <> concat found)
 where
  probeInstances vpc = do
    answers <-
      traverse
        (runAuditQuery runner)
        [query | query <- vpcRootedQueries vpc, auditQueryClass query == AuditInstance]
    pure $ case answers of
      [(_, answer)] -> case auditAnswerGap answer of
        Just gap -> Left gap
        Nothing -> Right ["instance/" <> auditRowIdentity row | row <- auditAnswerRows answer]
      _ -> Left "the instance read is not among the queries made inside a VPC"

taggedQuery :: AuditStack -> [String]
taggedQuery stack =
  [ "ec2"
  , "describe-vpcs"
  , "--filters"
  , "Name=tag:Name,Values=" <> Text.unpack (stackNameOf stack <> "-vpc")
  , "Name=tag:prodbox.io/managed-by,Values=prodbox"
  , "--query"
  , "Vpcs[].VpcId"
  , "--output"
  , "text"
  ]

anchorQueries :: AuditStack -> [[String]]
anchorQueries stack
  | stack /= AuditAwsEks = []
  | otherwise =
      [
        [ "ec2"
        , "describe-security-groups"
        , "--filters"
        , "Name=tag:aws:eks:cluster-name,Values=" <> Text.unpack awsEksProvisionedClusterName
        , "--query"
        , "SecurityGroups[].VpcId"
        , "--output"
        , "text"
        ]
      ,
        [ "ec2"
        , "describe-network-interfaces"
        , "--filters"
        , "Name=tag:cluster.k8s.amazonaws.com/name,Values=" <> Text.unpack awsEksProvisionedClusterName
        , "--query"
        , "NetworkInterfaces[].VpcId"
        , "--output"
        , "text"
        ]
      ]

stackNameOf :: AuditStack -> Text
stackNameOf stack = case stack of
  AuditAwsTest -> awsTestPulumiStackName
  _ -> awsEksPulumiStackName

vpcIdsOf
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> [String]
  -> m (Either Text [Text])
vpcIdsOf runner args = do
  output <- runAwsNativeStackFamilyCommand runner args
  pure $ case processExitCode output of
    ExitFailure _ -> Left (queryFailure args output)
    ExitSuccess ->
      let found = Text.words (Text.pack (processStdout output))
       in if all ("vpc-" `Text.isPrefixOf`) found
            then Right found
            else Left (queryLabel args <> " answered in a shape the audit does not read")

-- | The VPC class: the VPCs located are the field's VPC rows, and a VPC that
-- could not be located leaves the class unanswered.
locatedVpcAnswers :: AuditStack -> Either Text [Text] -> Map AuditClass AuditAnswer
locatedVpcAnswers stack located
  | not (stackHasNetwork stack) = Map.empty
  | otherwise =
      Map.singleton
        AuditVpc
        ( either
            (auditUnanswered . ("the VPC could not be located: " <>))
            (auditAnswered . map (\vpc -> mkAuditRow AuditVpc vpc ""))
            located
        )

-- | The classes only the VPC source covers, plus the ones it shares with the
-- exact-name source.
vpcRootedClasses :: [AuditClass]
vpcRootedClasses =
  [ AuditSubnet
  , AuditRouteTable
  , AuditInternetGateway
  , AuditSecurityGroup
  , AuditNetworkInterface
  , AuditNatGateway
  , AuditVpcEndpoint
  , AuditInstance
  , AuditLoadBalancer
  ]

vpcRootedAnswers
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> Either Text [Text]
  -> m (Map AuditClass AuditAnswer)
vpcRootedAnswers runner located = case located of
  Left detail ->
    pure
      ( Map.fromList
          [ (class', auditUnanswered ("the VPC could not be located: " <> detail)) | class' <- vpcRootedClasses
          ]
      )
  -- A VPC that does not exist holds nothing.
  Right [] -> pure (Map.fromList [(class', auditAnswered []) | class' <- vpcRootedClasses])
  Right vpcs -> do
    answers <- traverse (runAuditQuery runner) (concatMap vpcRootedQueries vpcs)
    pure
      ( Map.fromListWith
          (\new old -> mergeAuditAnswers [old, new])
          [(class', answer) | (class', answer) <- answers]
      )

runAuditQuery
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> AuditQuery
  -> m (AuditClass, AuditAnswer)
runAuditQuery runner query = do
  output <- runAwsNativeStackFamilyCommand runner (auditQueryArgs query)
  pure
    ( auditQueryClass query
    , case processExitCode output of
        ExitFailure _ -> auditUnanswered (queryFailure (auditQueryArgs query) output)
        ExitSuccess -> case decodeJson (processStdout output) >>= auditQueryRows query of
          Left detail ->
            auditUnanswered
              (queryLabel (auditQueryArgs query) <> " answered in a shape the audit does not read: " <> detail)
          Right rows -> auditAnswered rows
    )

-- | The registered IAM names and the per-run volumes the cluster owns.
registeredAnswers
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> m (Map AuditClass AuditAnswer)
registeredAnswers runner ref = do
  roles <- traverse roleRow awsEksIamRoleNames
  policies <- traverse policyRow awsEksIamManagedPolicyNames
  volumes <- volumeAnswer
  providers <- oidcAnswer
  pure
    ( Map.fromList
        [ (AuditIamRole, collect roles)
        , (AuditIamPolicy, collect policies)
        , (AuditEbsVolume, volumes)
        , (AuditOidcProvider, providers)
        ]
    )
 where
  accountId = providerNativeStackFamilyAccountId ref
  roleRow name =
    exactName
      AuditIamRole
      name
      ["iam", "get-role", "--role-name", Text.unpack name, "--query", "Role.RoleName", "--output", "text"]
  policyRow name =
    exactName
      AuditIamPolicy
      name
      [ "iam"
      , "get-policy"
      , "--policy-arn"
      , Text.unpack ("arn:aws:iam::" <> accountId <> ":policy/" <> name)
      , "--query"
      , "Policy.PolicyName"
      , "--output"
      , "text"
      ]
  -- An IAM name that does not exist is an answered, empty class.
  exactName class' name args = do
    output <- runAwsNativeStackFamilyCommand runner args
    pure $ case processExitCode output of
      ExitSuccess -> auditAnswered [mkAuditRow class' name ""]
      ExitFailure _
        | "nosuchentity"
            `Text.isInfixOf` Text.toLower (Text.pack (processStderr output <> processStdout output)) ->
            auditAnswered []
        | otherwise -> auditUnanswered (queryFailure args output)
  collect = mergeAuditAnswers
  -- The provider is read from IAM's own tag listing. It is tagged with the
  -- stack's name, and it can outlive the cluster that named it.
  oidcAnswer = do
    collected <- collectTaggedPages runner oidcProviderListing
    pure $ case collected of
      Left detail -> auditUnanswered detail
      Right entries ->
        auditAnswered [mkAuditRow AuditOidcProvider (taggedResourceEntryArn entry) "" | entry <- entries]
  volumeAnswer = do
    let args = ebsDescribeVolumesArgs (EbsPerRunTest (Text.unpack awsEksProvisionedClusterName))
    output <- runAwsNativeStackFamilyCommand runner args
    pure $ case processExitCode output of
      ExitFailure _ -> auditUnanswered (queryFailure args output)
      ExitSuccess -> case volumesPayloadShape (processStdout output) of
        Left detail ->
          auditUnanswered (queryLabel args <> " answered in a shape the audit does not read: " <> detail)
        Right () -> case parseDescribeVolumesPayload (processStdout output) of
          Left detail ->
            auditUnanswered
              (queryLabel args <> " answered in a shape the audit does not read: " <> Text.pack detail)
          Right volumes ->
            -- A volume the provider already reports as deleted is gone.
            auditAnswered
              [ mkAuditRow
                  AuditEbsVolume
                  (Text.pack (unEbsVolumeId (ebsVolumeId volume)))
                  ("state=" <> Text.pack (ebsVolumeState volume))
              | volume <- volumes
              , ebsVolumeState volume /= "deleted"
              ]

-- | The tag listing of the OIDC providers the stack names, in IAM's global
-- region, one page at a time.
oidcProviderListing :: Maybe Text -> [String]
oidcProviderListing cursor =
  [ "resourcegroupstaggingapi"
  , "get-resources"
  , "--resource-type-filters"
  , "iam:oidc-provider"
  , "--tag-filters"
  , "Key=Name,Values=" <> Text.unpack (awsEksPulumiStackName <> "-oidc-provider")
  , "--region"
  , Text.unpack (awsGlobalServiceRegion :: Text)
  , "--output"
  , "json"
  ]
    <> concat [["--pagination-token", Text.unpack token] | Just token <- [cursor]]

-- | A volume listing is an object with a @Volumes@ array. One without the array
-- is a response the audit does not understand, not a region with no volumes.
volumesPayloadShape :: String -> Either Text ()
volumesPayloadShape payload = case decodeJson payload of
  Left detail -> Left detail
  Right (Object object) -> case KeyMap.lookup "Volumes" object of
    Just (Array _) -> Right ()
    _ -> Left "the answer had no `Volumes` array"
  Right _ -> Left "the answer was not a JSON object"

-- | Every entry of a tagging listing, following its pagination. A page that
-- does not read, a cursor that repeats and a listing past its page bound are
-- each a refusal to answer, never a short list.
collectTaggedPages
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> (Maybe Text -> [String])
  -> m (Either Text [TaggedResourceEntry])
collectTaggedPages runner arguments = go Nothing [] [] (0 :: Natural)
 where
  go cursor seen gathered pages
    | pages >= maximumTaggedResourcePages =
        pure (Left "the tagging catalog listing exceeded its page bound")
    | otherwise = do
        let args = arguments cursor
        output <- runAwsNativeStackFamilyCommand runner args
        case processExitCode output of
          ExitFailure _ -> pure (Left (queryFailure args output))
          ExitSuccess -> case parseTaggedResourcePage (processStdout output) of
            Left detail -> pure (Left (sanitizeAuditText (Text.pack detail)))
            Right page ->
              let entries = gathered <> taggedResourcePageEntries page
               in case taggedResourcePageNextToken page of
                    Nothing -> pure (Right entries)
                    Just next
                      | next `elem` seen ->
                          pure (Left "the tagging catalog repeated a pagination cursor")
                      | otherwise -> go (Just next) (next : seen) entries (pages + 1)

-- | The bucket's ARN as the tagging catalog reports it.
stateBucketControlArn :: Text -> Text
stateBucketControlArn bucket = "arn:aws:s3:::" <> bucket

-- | The positive control: the retained state bucket must appear in the tagging
-- catalog of the region it lives in. If it does not, the catalog may be blind (a
-- credential that sees nothing, the wrong account) and an empty answer elsewhere
-- proves nothing. The catalog answers per region and the bucket lives in the
-- state backend's region, which need not be the session's, so the request names
-- it when it differs.
auditPositiveControl
  :: (Monad m)
  => AwsNativeStackFamilyRunner m
  -> ProviderNativeStackFamilyRef
  -> Text
  -> Maybe Text
  -> m AuditControl
auditPositiveControl runner ref bucket controlRegion = do
  collected <- collectTaggedPages runner (taggedResourceQueryArgs catalogFilter region)
  pure $ case collected of
    Left detail -> AuditControlUnanswered detail
    Right entries
      | stateBucketControlArn bucket `elem` map taggedResourceEntryArn entries -> AuditControlSeen
      | otherwise -> AuditControlMissing
 where
  region = fromMaybe (providerNativeStackFamilyRegion ref) controlRegion
  (roleKey, roleValue) = case [pair | pair@("prodbox.io/role", _) <- longLivedPulumiStateBucketTags] of
    pair : _ -> pair
    [] -> ("prodbox.io/role", "long-lived-pulumi-state")
  catalogFilter = TaggedResourceTagPairFilter roleKey roleValue

-- | Rows of a JSON array of projected objects: one key is the identity, and the
-- detail is whatever the class needs an operator to judge the row by.
projection :: AuditClass -> Text -> (KeyMap Value -> Text) -> Value -> Either Text [AuditRow]
projection class' idKey detail = rowsOf class' idKey detail (const True)

-- | The same, dropping what the provider already reports as deleted.
liveProjection :: AuditClass -> Text -> (KeyMap Value -> Text) -> Value -> Either Text [AuditRow]
liveProjection class' idKey detail =
  rowsOf
    class'
    idKey
    detail
    (\object -> textField "state" object `notElem` [Just "deleted", Just "failed"])

-- | Rows whose object names the given VPC; the listing call has no VPC filter.
insideVpc
  :: AuditClass -> Text -> Text -> Text -> (KeyMap Value -> Text) -> Value -> Either Text [AuditRow]
insideVpc class' vpcId idKey vpcKey detail =
  rowsOf class' idKey detail (\object -> textField vpcKey object == Just vpcId)

rowsOf
  :: AuditClass
  -> Text
  -> (KeyMap Value -> Text)
  -> (KeyMap Value -> Bool)
  -> Value
  -> Either Text [AuditRow]
rowsOf class' idKey detail keep value = case value of
  Array objects -> fmap concat (traverse rowOf (Vector.toList objects))
  -- An empty listing prints @[]@. @null@ is what a projection yields when the
  -- key it projects is missing, which is the shape of a response the audit does
  -- not understand and must not be read as nothing there.
  Null -> Left "the answer was null, which no empty listing is"
  _ -> Left "the answer was not a JSON array"
 where
  rowOf item = case item of
    Object object
      | not (keep object) -> Right []
      | otherwise -> case textField idKey object of
          Just identity
            | not (Text.null identity) -> Right [mkAuditRow class' identity (detail object)]
          _ -> Left ("a row had no `" <> idKey <> "`")
    _ -> Left "a row was not a JSON object"

-- | One field of a projected row as text, or a dash when the provider left it out.
fieldValue :: Text -> KeyMap Value -> Text
fieldValue key object = case KeyMap.lookup (Key.fromText key) object of
  Just (String text) -> text
  Just (Bool True) -> "true"
  Just (Bool False) -> "false"
  Just (Number number) -> Text.pack (show number)
  _ -> "-"

noDetail :: KeyMap Value -> Text
noDetail = const ""

-- | What an operator judges an interface by: whether it is attached, whether an
-- AWS service holds it on the account's behalf (never touched), and what it says
-- it is for. The type is named only when it is not the plain kind.
networkInterfaceDetail :: KeyMap Value -> Text
networkInterfaceDetail object =
  Text.unwords $
    [ fieldValue "status" object
    , if fieldValue "requester_managed" object == "true" then "managed" else "self"
    ]
      <> ["type=" <> kind | kind <- [fieldValue "type" object], kind `notElem` ["interface", "-"]]
      <> [description | description <- [fieldValue "description" object], description `notElem` ["-", ""]]

-- | An endpoint's state and the service it reaches, without the namespace every
-- service shares.
endpointDetail :: KeyMap Value -> Text
endpointDetail object =
  Text.unwords [fieldValue "state" object, Text.takeWhileEnd (/= '.') (fieldValue "service" object)]

textField :: Text -> KeyMap Value -> Maybe Text
textField key object = case KeyMap.lookup (Key.fromText key) object of
  Just (String text) -> Just text
  _ -> Nothing

decodeJson :: String -> Either Text Value
decodeJson payload =
  either (Left . Text.pack) Right (eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack payload)))

-- | The command in words, for a gap's reason.
queryLabel :: [String] -> Text
queryLabel args = Text.pack (unwords (take 2 args))

-- | A failed query as a reason that survives the wire: the command, and the code
-- AWS answered with. A bounded gap reason that began with the whole transcript
-- lost the one word an operator needs, so the code comes first.
queryFailure :: [String] -> ProcessOutput -> Text
queryFailure args output =
  sanitizeAuditText (queryLabel args <> ": " <> failureCause output)

-- | What went wrong, in a few words: the error code AWS names, or the start of
-- the transcript when it names none.
failureCause :: ProcessOutput -> Text
failureCause output = case Text.breakOn marker transcript of
  (_, rest)
    | not (Text.null rest) -> Text.takeWhile (/= ')') (Text.drop (Text.length marker) rest)
  _ -> Text.take 60 (Text.strip (Text.replace "aws: [ERROR]:" "" transcript))
 where
  marker = "An error occurred ("
  transcript = Text.pack (processStderr output <> " " <> processStdout output)

-- | The audit as read-only AWS CLI commands, for the operator to run when the
-- Authority is unreachable. Every line is a describe, get or list call and the
-- script mutates nothing. It is a reading aid and not a second audit: it prints
-- what the Provider's audit reads inside each VPC the stack's tags name, the
-- cluster's own reads, the OIDC provider listing, and the control, and the
-- verdict is the reader's. It does not repeat the exact-name reads or the
-- cluster-anchored VPC location, and it says so.
--
-- The state bucket and its region are known to the host when it can read its
-- configuration, which is not the case when the Authority is down; the script
-- then asks for @STATE_BUCKET@ instead of claiming the control is missing.
auditReadOnlyScript :: AuditStack -> Maybe Text -> Maybe Text -> [Text]
auditReadOnlyScript stack bucket controlRegion =
  [ "#!/usr/bin/env bash"
  , "# Read-only audit of the " <> auditStackLabel stack <> " field: describe, get and list calls only."
  , "# It is a reading aid, not the Provider's audit: it reads each VPC the stack's tags name and the"
  , "# cluster's own resources, and the verdict is yours. Set REGION to the stack's region."
  , "set -u"
  , "REGION=${REGION:?set REGION to the stack region}"
  , "STATE_BUCKET=${STATE_BUCKET:-" <> maybe "" id bucket <> "}"
  , "CONTROL_REGION=${CONTROL_REGION:-" <> maybe "$REGION" id controlRegion <> "}"
  , "ACCOUNT=$(aws sts get-caller-identity --query Account --output text)"
  ]
    <> case stack of
      AuditAwsEksSubzone ->
        [ "echo 'the subzone is read by its hosted-zone id, which only the stack records:'"
        , "echo '  aws route53 get-hosted-zone --id <zone id>'"
        ]
      _ ->
        [ "VPCS=$("
            <> scriptCommand
              [ "ec2"
              , "describe-vpcs"
              , "--filters"
              , "Name=tag:Name,Values=" <> Text.unpack (stackName <> "-vpc")
              , "Name=tag:prodbox.io/managed-by,Values=prodbox"
              , "--query"
              , "Vpcs[].VpcId"
              , "--output"
              , "text"
              ]
            <> ")"
        , "echo \"vpcs: ${VPCS:-none}\""
        , "for VPC in $VPCS; do"
        ]
          <> map (("  " <>) . scriptCommand . scoped . auditQueryArgs) (vpcRootedQueries "$VPC")
          <> ["done"]
          <> eksReads
          <> [ "# the positive control: the retained state bucket must appear, or the catalog may be blind"
             , "[ -n \"$STATE_BUCKET\" ] && { "
                 <> scriptWords (controlListing "${CONTROL_REGION}")
                 <> " | grep -q \"arn:aws:s3:::$STATE_BUCKET\" && echo 'control: seen' || echo 'control: MISSING'; } || echo 'control: NOT CHECKED (set STATE_BUCKET to the retained state bucket)'"
             ]
 where
  stackName = case stack of
    AuditAwsTest -> awsTestPulumiStackName
    _ -> awsEksPulumiStackName
  controlFilter = TaggedResourceTagPairFilter "prodbox.io/role" "long-lived-pulumi-state"
  controlListing region = taggedResourceQueryArgs controlFilter region Nothing
  -- The two load balancer listings have no VPC filter, so the script filters
  -- the rows by the VPC it is reading, as the audit does.
  scoped = map scopeLoadBalancerQuery
  scopeLoadBalancerQuery word
    | "LoadBalancers[]" `isPrefixOf` word =
        "LoadBalancers[?VpcId=='$VPC']" <> drop (length ("LoadBalancers[]" :: String)) word
    | "LoadBalancerDescriptions[]" `isPrefixOf` word =
        "LoadBalancerDescriptions[?VPCId=='$VPC']"
          <> drop (length ("LoadBalancerDescriptions[]" :: String)) word
    | otherwise = word
  eksReads
    | stack /= AuditAwsEks = []
    | otherwise =
        [ scriptCommand
            ["eks", "describe-cluster", "--name", Text.unpack awsEksProvisionedClusterName, "--output", "json"]
        , scriptCommand
            [ "eks"
            , "list-nodegroups"
            , "--cluster-name"
            , Text.unpack awsEksProvisionedClusterName
            , "--output"
            , "json"
            ]
        , scriptCommand
            [ "eks"
            , "list-addons"
            , "--cluster-name"
            , Text.unpack awsEksProvisionedClusterName
            , "--output"
            , "json"
            ]
        ]
          <> [ scriptCommand ["iam", "get-role", "--role-name", Text.unpack name, "--output", "json"]
             | name <- awsEksIamRoleNames
             ]
          <> [ scriptCommand
                 [ "iam"
                 , "get-policy"
                 , "--policy-arn"
                 , "arn:aws:iam::$ACCOUNT:policy/" <> Text.unpack name
                 , "--output"
                 , "json"
                 ]
             | name <- awsEksIamManagedPolicyNames
             ]
          <> [ scriptWords (oidcProviderListing Nothing)
             , scriptCommand (ebsDescribeVolumesArgs (EbsPerRunTest (Text.unpack awsEksProvisionedClusterName)))
             ]

-- | One command as a script line, with the region appended.
scriptCommand :: [String] -> Text
scriptCommand arguments = scriptWords arguments <> " --region \"$REGION\""

scriptWords :: [String] -> Text
scriptWords arguments = Text.unwords ("aws" : map scriptWord arguments)

-- | A word that mentions a script variable is double-quoted so the variable
-- expands; every other word is single-quoted so nothing in it can be read as
-- syntax.
scriptWord :: String -> Text
scriptWord word
  | '$' `elem` word = "\"" <> Text.concatMap escapeDouble (Text.pack word) <> "\""
  | otherwise = "'" <> Text.replace "'" "'\\''" (Text.pack word) <> "'"
 where
  escapeDouble character
    | character `elem` ['"', '\\', '`'] = Text.pack ['\\', character]
    | otherwise = Text.singleton character
