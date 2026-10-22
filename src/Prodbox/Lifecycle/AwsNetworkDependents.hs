{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The children a cluster's networking controllers leave in the stack's VPC.
--
-- A destroy ends in @DependencyViolation@ on the subnet when something in the
-- VPC still uses it, and the something is not in any checkpoint: the VPC CNI
-- attaches network interfaces to nodes to hold pod addresses, and EKS creates
-- the security group the nodes and the control plane share. Neither exists until
-- a controller acts, so no create in this repository could record it, and when a
-- node goes before its interface is released the interface outlives the cluster
-- as an @available@ interface that holds the group that holds the subnet. The
-- 2026-09-29/30 incident left exactly that pair, and it stayed until a hand
-- clearing on 2026-10-14.
--
-- This module is the closed rule for what may be cleared and the bounded
-- executor that clears it. It is neither containment nor discovery: a resource's
-- presence in the VPC admits nothing. Each candidate is read, classified by a
-- predicate closed over the stack's VPC and cluster, and one of three things
-- happens to it.
--
-- * 'Admitted' -- the predicate holds. For an interface that is: status
--   @available@, not requester-managed, an ordinary interface, inside the VPC,
--   carrying the VPC CNI's tag or its description, and tagged for no other
--   cluster. For a security group it is: the group EKS created for this
--   cluster, inside the VPC, or one exact shape of the separately registered
--   test canary family. These are deleted. The VPC is read from each row
--   and compared, as well as asked for in the listing's filter: a listing that
--   dropped its filter would otherwise reach the whole region.
-- * 'HeldByService' -- an AWS service holds it (a load balancer's interface, the
--   control plane's, an interface still attached). It is waited for under a
--   named budget and never detached, deleted, or forced.
-- * 'NotAdmitted' -- anything else. It is reported and never touched, however it
--   came to be there.
--
-- Every step observes before it mutates and is idempotent, so a rerun after a
-- kill or a partial delete makes progress. The runner and the clock are
-- arguments, so the whole executor runs over a scripted world.
module Prodbox.Lifecycle.AwsNetworkDependents
  ( -- * The runner
    AwsRun

    -- * The target the predicates are closed over
  , DependentsTarget
  , mkDependentsTarget
  , dependentsTargetVpc
  , dependentsTargetCluster

    -- * What is observed
  , DependentKind (..)
  , dependentKindLabel
  , Disposition (..)
  , Dependent (..)
  , InterfaceRow (..)
  , classifyInterface
  , SecurityGroupRow (..)
  , classifySecurityGroup
  , observeNetworkDependents
  , observeNetworkFamily

    -- * What is cleared
  , DependentsRepair (..)
  , clearNetworkDependents
  , clearNetworkFamily
  , clearNetworkFamilies
  , deleteSecurityGroupsWithin
  , deleteSecurityGroupsWith

    -- * What is reported
  , renderDependents
  , dependentsDigest
  )
where

import Control.Monad (void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Numeric (showHex)
import Prodbox.ControlPlane.OperationBudget (WaitFact (InterfacesReleased, SecurityGroupDeletable))
import Prodbox.Lifecycle.AwsNetworkFamily
import Prodbox.Lifecycle.AwsTestCanary qualified as Canary
import Prodbox.Lifecycle.AwsTestCanaryExecution qualified as CanaryExecution
import Prodbox.Lifecycle.AwsWait
  ( AwsWaitEnvironment
  , WaitFailure (..)
  , WaitStep (..)
  , awaitFact
  , awaitFactFrom
  , renderWaitFailure
  , transientPollFailure
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

-- | One @aws@ child as the executor sees it: the arguments in, the transcript
-- out. The runner is also what bounds a child.
type AwsRun m = [String] -> m ProcessOutput

-- | The stack a rule is closed over: its VPC, and for an EKS stack the cluster.
data DependentsTarget = DependentsTarget
  { targetVpc :: !Text
  , targetCluster :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | The VPC must be spelled as AWS spells one, so the identifier that reaches an
-- argument vector is never free text.
mkDependentsTarget :: Text -> Maybe Text -> Either Text DependentsTarget
mkDependentsTarget vpc cluster
  | validVpcId vpc = Right (DependentsTarget vpc cluster)
  | otherwise = Left ("not a VPC identifier: " <> Text.take 40 vpc)
 where
  validVpcId value = case Text.stripPrefix "vpc-" value of
    Just hex ->
      Text.length hex >= 8
        && Text.length hex <= 17
        && Text.all (\c -> isDigit c || c `elem` ['a' .. 'f']) hex
    Nothing -> False

dependentsTargetVpc :: DependentsTarget -> Text
dependentsTargetVpc = targetVpc

dependentsTargetCluster :: DependentsTarget -> Maybe Text
dependentsTargetCluster = targetCluster

data DependentKind
  = DependentInterface
  | DependentSecurityGroup
  deriving stock (Eq, Ord, Show, Enum, Bounded)

dependentKindLabel :: DependentKind -> Text
dependentKindLabel kind = case kind of
  DependentInterface -> "network-interface"
  DependentSecurityGroup -> "security-group"

-- | What the closed predicate says about one candidate.
data Disposition
  = -- | The predicate holds: the candidate is deleted.
    Admitted
  | -- | An AWS service holds it: waited for, never touched.
    HeldByService !Text
  | -- | Outside the predicate: reported, never touched.
    NotAdmitted !Text
  deriving stock (Eq, Show)

data Dependent = Dependent
  { dependentKind :: !DependentKind
  , dependentIdentity :: !Text
  , dependentDisposition :: !Disposition
  }
  deriving stock (Eq, Show)

-- | One interface as the listing reports it. A field the listing left out is
-- carried as the fail-safe value: an interface whose managed flag cannot be read
-- is treated as managed, so it is never deleted on a guess.
data InterfaceRow = InterfaceRow
  { interfaceId :: !Text
  , interfaceVpc :: !Text
  , interfaceStatus :: !Text
  , interfaceManaged :: !Bool
  , interfaceType :: !Text
  , interfaceDescription :: !Text
  , interfaceOwnerTag :: !(Maybe Text)
  , interfaceClusterTag :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | The closed predicate for an interface, and the reasons for everything it
-- does not admit.
classifyInterface :: DependentsTarget -> InterfaceRow -> Dependent
classifyInterface target row =
  Dependent DependentInterface (interfaceId row) disposition
 where
  disposition
    | interfaceVpc row /= targetVpc target =
        NotAdmitted ("in " <> interfaceVpc row <> ", not the stack's VPC")
    | interfaceManaged row = HeldByService "requester-managed: an AWS service holds it"
    | interfaceStatus row `elem` attachedStatuses = HeldByService ("status " <> interfaceStatus row)
    | interfaceStatus row /= "available" = NotAdmitted ("status " <> interfaceStatus row)
    | interfaceType row /= "interface" = NotAdmitted ("interface type " <> interfaceType row)
    | not cniMarked = NotAdmitted "available, but carries neither the VPC CNI's tag nor its description"
    | taggedForAnotherCluster = NotAdmitted "tagged for another cluster"
    | otherwise = Admitted
  attachedStatuses = ["in-use", "attaching", "detaching"]
  cniMarked =
    interfaceOwnerTag row == Just "amazon-vpc-cni"
      || "aws-K8S-" `Text.isPrefixOf` interfaceDescription row
  taggedForAnotherCluster = case (interfaceClusterTag row, targetCluster target) of
    (Just tagged, Just own) -> tagged /= own
    (Just _, Nothing) -> True
    (Nothing, _) -> False

data SecurityGroupRow = SecurityGroupRow
  { groupId :: !Text
  , groupVpc :: !Text
  , groupName :: !Text
  , groupClusterTag :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | The closed predicate for a security group: the group EKS created for this
-- cluster. The VPC's own default group is not a dependent (it goes with the VPC)
-- and is not listed.
classifySecurityGroup :: DependentsTarget -> SecurityGroupRow -> Maybe Dependent
classifySecurityGroup target row
  | groupName row == "default" = Nothing
  | groupVpc row /= targetVpc target =
      Just (dependent (NotAdmitted ("in " <> groupVpc row <> ", not the stack's VPC")))
  | createdByEksForThisCluster = Just (dependent Admitted)
  | otherwise = Just (dependent (NotAdmitted "not the group EKS created for this stack's cluster"))
 where
  dependent = Dependent DependentSecurityGroup (groupId row)
  createdByEksForThisCluster = case targetCluster target of
    Just cluster ->
      groupClusterTag row == Just cluster
        && clusterGroupPrefix cluster `Text.isPrefixOf` groupName row
    Nothing -> False

clusterGroupPrefix :: Text -> Text
clusterGroupPrefix cluster = "eks-cluster-sg-" <> cluster <> "-"

-- An independent controller family must not claim a stack-native group that
-- the stack observer already records. Partial marks and foreign-VPC rows stay
-- candidates and fail the full predicate; the combined VPC repair reads all.
isScopedGroupCandidate :: Maybe AwsNetworkFamily -> DependentsTarget -> SecurityGroupRow -> Bool
isScopedGroupCandidate scope target row = case scope of
  Just EksClusterSecurityGroups -> case targetCluster target of
    Nothing -> True
    Just cluster ->
      groupVpc row /= targetVpc target
        || groupClusterTag row == Just cluster
        || clusterGroupPrefix cluster `Text.isPrefixOf` groupName row
  Just EksVpcCniInterfaces -> True
  Just TestVpcCniInterfaces -> True
  Just TestCanarySecurityGroups -> False
  Nothing -> True

-- | Read the interfaces and groups in the stack's VPC and classify each. A read
-- that fails or answers in a shape this does not read is a refusal to classify,
-- never an empty listing.
observeNetworkDependents
  :: (Monad m)
  => AwsRun m
  -> DependentsTarget
  -> m (Either Text [Dependent])
observeNetworkDependents runner target =
  observeSelectedNetworkFamilies families runner target
 where
  families = case targetCluster target of
    Nothing -> [TestVpcCniInterfaces, TestCanarySecurityGroups]
    Just _ -> [EksVpcCniInterfaces, EksClusterSecurityGroups]

observeNetworkFamily
  :: (Monad m) => AwsNetworkFamily -> AwsRun m -> DependentsTarget -> m (Either Text [Dependent])
observeNetworkFamily family = case family of
  TestCanarySecurityGroups -> observeCanarySecurityGroups
  EksVpcCniInterfaces -> observeNetworkKinds [DependentInterface] (Just family)
  TestVpcCniInterfaces -> observeNetworkKinds [DependentInterface] (Just family)
  EksClusterSecurityGroups -> observeNetworkKinds [DependentSecurityGroup] (Just family)

networkFamilyKind :: AwsNetworkFamily -> DependentKind
networkFamilyKind family = case family of
  EksVpcCniInterfaces -> DependentInterface
  TestVpcCniInterfaces -> DependentInterface
  EksClusterSecurityGroups -> DependentSecurityGroup
  TestCanarySecurityGroups -> DependentSecurityGroup

observeSelectedNetworkFamilies
  :: (Monad m) => [AwsNetworkFamily] -> AwsRun m -> DependentsTarget -> m (Either Text [Dependent])
observeSelectedNetworkFamilies families runner target = do
  ordinary <- observeNetworkKinds (nub (map networkFamilyKind families)) Nothing runner target
  canary <-
    if TestCanarySecurityGroups `elem` families
      then observeCanarySecurityGroups runner target
      else pure (Right [])
  pure (mergeCanaryClassifications <$> ordinary <*> canary)

-- The dedicated family supplies the decision for its candidates. This leaves
-- the EKS group predicate unchanged, retains unrelated refusals, and admits no
-- group merely because another group had the same name prefix.
mergeCanaryClassifications :: [Dependent] -> [Dependent] -> [Dependent]
mergeCanaryClassifications ordinary canary =
  [Map.findWithDefault row (key row) canaryByKey | row <- ordinary]
    <> [row | row <- canary, not (Map.member (key row) ordinaryKeys)]
 where
  key row = (dependentKind row, dependentIdentity row)
  canaryByKey = Map.fromList [(key row, row) | row <- canary]
  ordinaryKeys = Map.fromList [(key row, ()) | row <- ordinary]

data CanaryGroupRow = CanaryGroupRow !Text !Text !Text ![(Text, Text)]

observeCanarySecurityGroups
  :: (Monad m) => AwsRun m -> DependentsTarget -> m (Either Text [Dependent])
observeCanarySecurityGroups runner target = do
  vpcs <-
    readListingBounded (Just Canary.canaryInventoryMaximumBytes) runner vpcArguments parseCanaryVpcs
  groups <-
    readListingBounded (Just Canary.canaryInventoryMaximumBytes) runner groupArguments parseCanaryGroups
  pure $ do
    vpcRows <- vpcs
    groupRows <- groups
    let candidates = filter candidate groupRows
    case vpcRows of
      []
        | null candidates -> Right []
        | otherwise -> Left "canary VPC is absent while its group candidates remain visible"
      [(vpc, tags)]
        | vpc /= targetVpc target -> Left "canary VPC read returned a different VPC"
        | not (all (owns tags) (networkFamilyVpcTags TestCanarySecurityGroups)) ->
            Left "canary VPC does not carry the registered test-stack ownership tags"
        -- A complete empty candidate superset proves the family absent even
        -- when stale VPC marker metadata cannot authorize any group mutation.
        | null candidates -> Right []
        | otherwise -> traverse (classify (Canary.canaryBindingFromVpcTags tags)) candidates
      _ -> Left "canary VPC read is ambiguous"
 where
  owns tags (key, value) = lookup key tags == Just value
  candidate (CanaryGroupRow _ vpc name tags) =
    vpc /= targetVpc target || Canary.isCanaryGroupCandidate name tags
  classify binding (CanaryGroupRow identity vpc name tags) = do
    _ <- firstCanary (Canary.validateCanaryEc2Identifier Canary.CanarySecurityGroup identity)
    let checked = do
          found <- binding
          exact <- maybe (Left Canary.CanaryVpcMarkerIncomplete) Right found
          shape <-
            case [shape | shape <- [minBound .. maxBound], Canary.canaryGroupName exact shape == name] of
              [shape] -> Right shape
              _ -> Left Canary.CanaryGroupNameMismatch
          Canary.checkCanaryGroup exact (targetVpc target) shape vpc name tags
    Right
      ( Dependent DependentSecurityGroup identity $
          either (NotAdmitted . Canary.renderTestCanaryError) (const Admitted) checked
      )
  firstCanary = either (Left . Canary.renderTestCanaryError) Right
  vpcArguments =
    [ "ec2"
    , "describe-vpcs"
    , "--vpc-ids"
    , Text.unpack (targetVpc target)
    , "--query"
    , "Vpcs[].{id:VpcId,tags:Tags}"
    , "--output"
    , "json"
    ]
  groupArguments =
    [ "ec2"
    , "describe-security-groups"
    , "--filters"
    , "Name=vpc-id,Values=" <> Text.unpack (targetVpc target)
    , "--query"
    , "SecurityGroups[].{id:GroupId,vpc:VpcId,name:GroupName,tags:Tags}"
    , "--output"
    , "json"
    ]

parseCanaryVpcs :: Value -> Either Text [(Text, [(Text, Text)])]
parseCanaryVpcs value = case value of
  Array rows -> traverse parseRow (Vector.toList rows)
  _ -> Left "canary VPC listing is not an array"
 where
  parseRow row = case row of
    Object fields -> do
      identity <- requiredText "id" fields
      tags <- canaryRowTags fields
      Right (identity, tags)
    _ -> Left "canary VPC row is not an object"

parseCanaryGroups :: Value -> Either Text [CanaryGroupRow]
parseCanaryGroups value = case value of
  Array values
    | Vector.length values > Canary.canaryInventoryMaximumRows ->
        Left "canary group listing exceeds its row bound"
    | otherwise -> do
        rows <- traverse parseRow (Vector.toList values)
        if Map.size (Map.fromList [(identity, ()) | CanaryGroupRow identity _ _ _ <- rows]) == length rows
          then Right rows
          else Left "canary group listing repeats an identity"
  _ -> Left "canary group listing is not an array"
 where
  parseRow row = case row of
    Object fields ->
      CanaryGroupRow
        <$> requiredText "id" fields
        <*> requiredText "vpc" fields
        <*> requiredText "name" fields
        <*> canaryRowTags fields
    _ -> Left "canary group row is not an object"

canaryRowTags :: KeyMap Value -> Either Text [(Text, Text)]
canaryRowTags fields = case KeyMap.lookup "tags" fields of
  Just Null -> Right []
  Just (Array values)
    | Vector.length values > Canary.canaryInventoryMaximumTags ->
        Left "canary tag set exceeds its row bound"
    | otherwise -> do
        tags <- traverse parseTag (Vector.toList values)
        if Map.size (Map.fromList tags) == length tags
          then Right tags
          else Left "canary tag set repeats a key"
  _ -> Left "canary row has no projected tag set"
 where
  parseTag row = case row of
    Object fields' -> do
      key <- requiredText "Key" fields'
      value <- maybe (Left "canary tag has no value") Right (text "Value" fields')
      Right (key, value)
    _ -> Left "canary tag is not an object"

observeNetworkKinds
  :: (Monad m)
  => [DependentKind]
  -> Maybe AwsNetworkFamily
  -> AwsRun m
  -> DependentsTarget
  -> m (Either Text [Dependent])
observeNetworkKinds kinds scope runner target = do
  interfaces <-
    if DependentInterface `elem` kinds
      then readListing runner interfaceListing parseInterfaces
      else pure (Right [])
  groups <-
    if DependentSecurityGroup `elem` kinds
      then readListing runner groupListing parseSecurityGroups
      else pure (Right [])
  pure $ do
    interfaceRows <- interfaces
    groupRows <- groups
    Right
      ( map (classifyInterface target) interfaceRows
          <> mapMaybe (classifySecurityGroup target) (filter (isScopedGroupCandidate scope target) groupRows)
      )
 where
  vpcFilter = "Name=vpc-id,Values=" <> Text.unpack (targetVpc target)
  interfaceListing =
    [ "ec2"
    , "describe-network-interfaces"
    , "--filters"
    , vpcFilter
    , "--query"
    , "NetworkInterfaces[].{id:NetworkInterfaceId,vpc:VpcId,status:Status,managed:RequesterManaged,type:InterfaceType,description:Description,owner:TagSet[?Key=='eks:eni:owner']|[0].Value,cluster:TagSet[?Key=='cluster.k8s.amazonaws.com/name']|[0].Value}"
    , "--output"
    , "json"
    ]
  groupListing =
    [ "ec2"
    , "describe-security-groups"
    , "--filters"
    , vpcFilter
    , "--query"
    , "SecurityGroups[].{id:GroupId,vpc:VpcId,name:GroupName,cluster:Tags[?Key=='aws:eks:cluster-name']|[0].Value}"
    , "--output"
    , "json"
    ]

readListing
  :: (Monad m)
  => AwsRun m
  -> [String]
  -> (Value -> Either Text [row])
  -> m (Either Text [row])
readListing = readListingBounded Nothing

readListingBounded
  :: (Monad m)
  => Maybe Int
  -> AwsRun m
  -> [String]
  -> (Value -> Either Text [row])
  -> m (Either Text [row])
readListingBounded maximumBytes runner arguments parse = do
  output <- runner arguments
  pure $ case processExitCode output of
    ExitFailure _ -> Left (failureText arguments output)
    ExitSuccess -> do
      let bytes = TextEncoding.encodeUtf8 (Text.pack (processStdout output))
      case maximumBytes of
        Nothing -> Right ()
        Just limit ->
          if ByteString.length bytes <= limit
            then Right ()
            else Left "canary inventory exceeds its 1 MiB read bound"
      decoded <- either (const (Left (unreadable arguments))) Right (eitherDecodeStrict' bytes)
      parse decoded

parseInterfaces :: Value -> Either Text [InterfaceRow]
parseInterfaces value = case value of
  Array rows -> traverse interfaceRow (Vector.toList rows)
  Null -> Left "the interface listing was null, which no empty listing is"
  _ -> Left "the interface listing was not a JSON array"
 where
  interfaceRow row = case row of
    Object object -> do
      identity <- requiredText "id" object
      vpc <- requiredText "vpc" object
      status <- requiredText "status" object
      Right
        InterfaceRow
          { interfaceId = identity
          , interfaceVpc = vpc
          , interfaceStatus = status
          , -- A flag that is missing or is not a boolean is read as managed.
            interfaceManaged = maybe True id (boolean "managed" object)
          , interfaceType = maybe "-" id (text "type" object)
          , interfaceDescription = maybe "" id (text "description" object)
          , interfaceOwnerTag = text "owner" object
          , interfaceClusterTag = text "cluster" object
          }
    _ -> Left "an interface row was not a JSON object"

parseSecurityGroups :: Value -> Either Text [SecurityGroupRow]
parseSecurityGroups value = case value of
  Array rows -> traverse groupRow (Vector.toList rows)
  Null -> Left "the security-group listing was null, which no empty listing is"
  _ -> Left "the security-group listing was not a JSON array"
 where
  groupRow row = case row of
    Object object -> do
      identity <- requiredText "id" object
      vpc <- requiredText "vpc" object
      name <- requiredText "name" object
      Right (SecurityGroupRow identity vpc name (text "cluster" object))
    _ -> Left "a security-group row was not a JSON object"

text :: Text -> KeyMap Value -> Maybe Text
text key object = case KeyMap.lookup (Key.fromText key) object of
  Just (String value) -> Just value
  _ -> Nothing

boolean :: Text -> KeyMap Value -> Maybe Bool
boolean key object = case KeyMap.lookup (Key.fromText key) object of
  Just (Bool value) -> Just value
  _ -> Nothing

requiredText :: Text -> KeyMap Value -> Either Text Text
requiredText key object = case text key object of
  Just value | not (Text.null value) -> Right value
  _ -> Left ("a row had no `" <> key <> "`")

-- | What a repair did, in the order it did it. It is a narration for the report;
-- whether the stack is clear is the audit's to say.
data DependentsRepair = DependentsRepair
  { repairDeletedInterfaces :: ![Text]
  , repairDeletedGroups :: ![Text]
  , repairNotes :: ![Text]
  , repairRemaining :: ![Dependent]
  -- ^ What the last listing still showed once the repair was done: held,
  -- not admitted, and admitted candidates whose delete did not take.
  }
  deriving stock (Eq, Show)

-- | Clear what the closed predicate admits and wait for what an AWS service
-- holds: delete the admitted interfaces, wait for the held ones to release, read
-- again (an interface that was attached while its node terminated is available
-- now), delete any that became admitted, then delete the admitted groups once
-- nothing uses them. 'Left' only when the first listing could not be taken.
clearNetworkDependents
  :: (Monad m)
  => AwsRun m
  -> AwsWaitEnvironment m
  -> DependentsTarget
  -> m (Either Text DependentsRepair)
clearNetworkDependents runner waits target =
  clearObservedNetworkDependents
    (observeNetworkDependents runner target)
    (prepareCanaryGroups (targetCluster target == Nothing) runner target)
    runner
    waits

clearNetworkFamily
  :: (Monad m)
  => AwsNetworkFamily
  -> AwsRun m
  -> AwsWaitEnvironment m
  -> DependentsTarget
  -> m (Either Text DependentsRepair)
clearNetworkFamily family runner waits target =
  clearObservedNetworkDependents
    (observeNetworkFamily family runner target)
    (prepareCanaryGroups (family == TestCanarySecurityGroups) runner target)
    runner
    waits

clearNetworkFamilies
  :: (Monad m)
  => [AwsNetworkFamily]
  -> AwsRun m
  -> AwsWaitEnvironment m
  -> DependentsTarget
  -> m (Either Text DependentsRepair)
clearNetworkFamilies families runner waits target =
  clearObservedNetworkDependents
    (observeSelectedNetworkFamilies families runner target)
    (prepareCanaryGroups (TestCanarySecurityGroups `elem` families) runner target)
    runner
    waits

-- Only the new canary family can revoke peer rules. EKS's predicate and
-- deletion program retain their existing behavior.
prepareCanaryGroups
  :: (Monad m) => Bool -> AwsRun m -> DependentsTarget -> [Text] -> m (Either Text ())
prepareCanaryGroups enabled runner target identities
  | enabled = CanaryExecution.clearTestCanaryReferences runner (targetVpc target) identities
  | otherwise = pure (Right ())

clearObservedNetworkDependents
  :: (Monad m)
  => m (Either Text [Dependent])
  -> ([Text] -> m (Either Text ()))
  -> AwsRun m
  -> AwsWaitEnvironment m
  -> m (Either Text DependentsRepair)
clearObservedNetworkDependents observe prepareGroups runner waits = do
  first' <- observe
  case first' of
    Left detail -> pure (Left detail)
    Right initial -> do
      (deletedFirst, notesFirst) <- deleteInterfaces (admittedOf DependentInterface initial)
      released <- awaitFact waits InterfacesReleased pollReleased
      let releaseNotes = either (\failure -> [renderWaitFailure failure]) (const []) released
      second' <- observe
      let settled = either (const initial) id second'
          secondNotes = either (\detail -> ["the second listing could not be taken: " <> detail]) (const []) second'
      (deletedLate, notesLate) <- deleteInterfaces (admittedOf DependentInterface settled)
      let groupIds = admittedOf DependentSecurityGroup settled
      -- A group is held by an interface, so each round of the group wait first
      -- deletes again any admitted interface that a refused or throttled delete
      -- left, instead of waiting out the budget on a group nothing will free.
      prepared <- prepareGroups groupIds
      groupResult <- case prepared of
        Left detail -> pure (Left detail)
        Right () -> deleteSecurityGroupsWith retryInterfaces runner waits groupIds
      final <- observe
      let groupNotes = either (\detail -> ["security groups: " <> detail]) (const []) groupResult
          finalNotes = either (\detail -> ["the closing listing could not be taken: " <> detail]) (const []) final
          deletedGroups = either (const []) (const groupIds) groupResult
          gone = deletedFirst <> deletedLate <> deletedGroups
      pure
        ( Right
            DependentsRepair
              { repairDeletedInterfaces = deletedFirst <> deletedLate
              , repairDeletedGroups = deletedGroups
              , repairNotes = notesFirst <> releaseNotes <> secondNotes <> notesLate <> groupNotes <> finalNotes
              , -- A listing that could not be taken leaves the last one that
                -- could, less what this repair has since deleted.
                repairRemaining =
                  either (const [d | d <- settled, dependentIdentity d `notElem` gone]) id final
              }
        )
 where
  retryInterfaces = do
    listing <- observe
    case listing of
      Left _ -> pure ()
      Right rows -> void (deleteInterfaces (admittedOf DependentInterface rows))
  admittedOf kind rows =
    [dependentIdentity d | d <- rows, dependentKind d == kind, dependentDisposition d == Admitted]
  -- Done when no interface is held by a service. Admitted interfaces that remain
  -- are the deletions' own refusals, narrated, and waiting does not change them.
  pollReleased = do
    listing <- observe
    pure $ case listing of
      Left detail -> WaitMore () ("the listing could not be taken: " <> detail)
      Right rows ->
        case [d | d <- rows, isHeld d] of
          [] -> WaitDone
          held ->
            WaitMore
              ()
              (Text.intercalate "; " [dependentIdentity d <> " " <> reasonOf d | d <- held])
  isHeld d = case dependentDisposition d of
    HeldByService _ -> True
    _ -> False
  reasonOf d = case dependentDisposition d of
    HeldByService reason -> reason
    NotAdmitted reason -> reason
    Admitted -> "admitted"
  deleteInterfaces ids = do
    outcomes <- traverse deleteOne ids
    pure
      ( [identity | (identity, Nothing) <- outcomes]
      , [note | (_, Just note) <- outcomes]
      )
  deleteOne identity = do
    output <-
      runner ["ec2", "delete-network-interface", "--network-interface-id", Text.unpack identity]
    pure $ case processExitCode output of
      ExitSuccess -> (identity, Nothing)
      ExitFailure _
        | notFound output -> (identity, Nothing)
        | otherwise -> (identity, Just (identity <> " was not deleted: " <> failureText [] output))
  notFound output =
    any
      (`Text.isInfixOf` Text.toLower (Text.pack (processStderr output <> processStdout output)))
      ["invalidnetworkinterfaceid.notfound", "invalidnetworkinterface.notfound"]

-- | Delete security groups, waiting for the network interfaces that still hold
-- them. The groups cannot be deleted until the interfaces release, which an AWS
-- service reports over minutes; each poll deletes the groups still outstanding,
-- a group that reports a dependency or a throttled call is polled again inside
-- the 'SecurityGroupDeletable' budget, and any other refusal ends the wait.
deleteSecurityGroupsWithin
  :: (Monad m)
  => ([String] -> m ProcessOutput)
  -> AwsWaitEnvironment m
  -> [Text]
  -> m (Either Text ())
deleteSecurityGroupsWithin = deleteSecurityGroupsWith (pure ())

-- | 'deleteSecurityGroupsWithin' with a step that runs at the start of every
-- round, before the groups are tried: the caller's way of repeating what frees a
-- group while the group is waited for.
--
-- A session with no window left to wait in still gets one round: a delete is a
-- single short call, and refusing to make it would leave a group that is
-- deletable standing in front of the VPC.
deleteSecurityGroupsWith
  :: (Monad m)
  => m ()
  -> ([String] -> m ProcessOutput)
  -> AwsWaitEnvironment m
  -> [Text]
  -> m (Either Text ())
deleteSecurityGroupsWith _ _ _ [] = pure (Right ())
deleteSecurityGroupsWith beforeRound runCommand waits groupIds = do
  waited <- awaitFactFrom waits SecurityGroupDeletable groupIds poll
  case waited of
    Right () -> pure (Right ())
    Left unavailable@(WaitUnavailable _ _) -> do
      once <- poll groupIds
      pure $ case once of
        WaitDone -> Right ()
        WaitAbort detail -> Left detail
        WaitMore _ observation ->
          Left (renderWaitFailure unavailable <> "; the one attempt made saw: " <> observation)
    Left failure -> pure (Left (renderWaitFailure failure))
 where
  poll [] = pure WaitDone
  poll outstanding = do
    beforeRound
    outcomes <- traverse deleteOne outstanding
    let refusals = [detail | (_, GroupRefused detail) <- outcomes]
        held = [(identity, detail) | (identity, GroupHeld detail) <- outcomes]
    pure $
      if not (null refusals)
        then WaitAbort (Text.intercalate "; " refusals)
        else case held of
          [] -> WaitDone
          _ ->
            WaitMore
              (map fst held)
              (Text.intercalate "; " [identity <> " held: " <> detail | (identity, detail) <- held])
  deleteOne identity = do
    output <- runCommand ["ec2", "delete-security-group", "--group-id", Text.unpack identity]
    pure
      ( identity
      , case processExitCode output of
          ExitSuccess -> GroupDeleted
          ExitFailure _
            | groupNotFound output -> GroupDeleted
            | dependencyViolation output || transientPollFailure output ->
                GroupHeld (Text.take 512 (failureText [] output))
            | otherwise -> GroupRefused (failureText [] output)
      )
  groupNotFound output = anyMarker ["invalidgroup.notfound", "does not exist"] output
  dependencyViolation = anyMarker ["dependencyviolation", "invalidgroup.inuse"]

data GroupOutcome
  = GroupDeleted
  | -- | Still held by an interface, or a call the service throttled: poll again.
    GroupHeld !Text
  | -- | Refused for a reason waiting cannot change.
    GroupRefused !Text

anyMarker :: [Text] -> ProcessOutput -> Bool
anyMarker markers output = any (`Text.isInfixOf` transcript) markers
 where
  transcript = Text.toLower (Text.pack (processStderr output <> " " <> processStdout output))

-- | A failed call as a bounded sentence.
failureText :: [String] -> ProcessOutput -> Text
failureText arguments output =
  Text.take
    512
    ( Text.pack (unwords (take 2 arguments))
        <> (if null arguments then "" else " failed: ")
        <> Text.pack (processStderr output <> " " <> processStdout output)
    )

unreadable :: [String] -> Text
unreadable arguments =
  Text.pack (unwords (take 2 arguments)) <> " answered in a shape this does not read"

-- | The report for a destroy that could not clear everything: the counts by kind
-- and disposition, the first identifiers, and a digest, bounded so it fits where
-- a failure detail goes.
renderDependents :: [Dependent] -> Text
renderDependents dependents =
  Text.intercalate
    "; "
    ( [ countText kind label
      | kind <- [minBound .. maxBound]
      , label <- ["held", "not admitted", "admitted"]
      , let n = countOf kind label
      , n > (0 :: Int)
      ]
        <> [ dependentKindLabel (dependentKind d) <> " " <> dependentIdentity d <> " (" <> why d <> ")"
           | d <- take shownIdentifiers dependents
           ]
        <> ["digest " <> dependentsDigest dependents]
    )
 where
  countOf kind label =
    length
      [() | d <- dependents, dependentKind d == kind, dispositionLabel (dependentDisposition d) == label]
  countText kind label =
    dependentKindLabel kind <> " x" <> Text.pack (show (countOf kind label)) <> " " <> label
  why d = dispositionLabel (dependentDisposition d) <> reasonSuffix (dependentDisposition d)
  reasonSuffix disposition = case disposition of
    Admitted -> ""
    HeldByService reason -> ": " <> Text.take 60 reason
    NotAdmitted reason -> ": " <> Text.take 60 reason
  dispositionLabel disposition = case disposition of
    Admitted -> "admitted"
    HeldByService _ -> "held"
    NotAdmitted _ -> "not admitted"

shownIdentifiers :: Int
shownIdentifiers = 5

-- | A short digest over every remaining identity and its disposition, so two
-- reports of the same residue read the same and a changed residue reads
-- differently.
dependentsDigest :: [Dependent] -> Text
dependentsDigest dependents =
  Text.pack (take 16 (concatMap hexByte (ByteString.unpack digest)))
 where
  digest = SHA256.hash (TextEncoding.encodeUtf8 (Text.intercalate "\n" (sort (map describe dependents))))
  describe d =
    dependentKindLabel (dependentKind d)
      <> "|"
      <> dependentIdentity d
      <> "|"
      <> disposition (dependentDisposition d)
  disposition d = case d of
    Admitted -> "admitted"
    HeldByService _ -> "held"
    NotAdmitted _ -> "not-admitted"
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits
