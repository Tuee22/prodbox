{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.111: a destroy that converges, over a scripted account.
--
-- The account is stateful. A subnet refuses to delete while an interface sits in
-- the VPC, a security group refuses while an interface uses it, a VPC refuses
-- while anything but its default group remains, and an interface an AWS service
-- holds vanishes only when its release time comes. A Pulumi destroy walks that
-- account the way the provider does, retrying a refused subnet for most of an
-- hour, which is what the first pass's bound exists to cut off.
--
-- The shapes are the ones the 2026-10-14 hand inventory recorded, with every
-- account-bearing value replaced by a reserved example. They are not an
-- exercised model of AWS timing: every duration here is an assumption that
-- drives the mechanism (the order, the bounds, the reserve), and discharges no
-- gate about how long AWS takes ([Unit Testing Policy § 5.1]).
module AwsDestroyConverge (awsDestroyConvergeSuite) where

import AwsAuditEnumeration
import AwsWaitPolling
  ( VirtualWorld
  , advanceVirtualClock
  , newVirtualWorld
  , pausesTaken
  , virtualNowMicros
  , virtualStartMicros
  , virtualWaitEnvironment
  )
import Control.Applicative ((<|>))
import Control.Monad (replicateM_, unless, when)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteStringChar8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.ControlPlane.OperationBudget
  ( WaitFact (SecurityGroupDeletable)
  , finalPassReserveMicros
  , firstPassCeilingMicros
  , sessionGraceSeconds
  , verdictReserveMicros
  )
import Prodbox.ControlPlane.ProviderProduction
  ( destroyPassBounds
  , eksLoadBalancerControllerFamilyTags
  , pulumiChildLimitsFor
  , pulumiDestroySelected
  , stackHasVpc
  , validateEksLoadBalancerControllerFamilyProjection
  )
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsDestroyConverge
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
  , reapAwsNativeStackFamilyWithin
  )
import Prodbox.Lifecycle.AwsNetworkDependents
import Prodbox.Lifecycle.AwsStackDestroy
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment, WaitStep (..), awaitFact)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (mkProviderStackRef)
import Prodbox.Lifecycle.Teardown.Registry
  ( awsEksIamRoleNames
  , awsEksLoadBalancerControllerName
  , awsEksProvisionedClusterName
  )
import Prodbox.Subprocess (KillableSubprocessLimits (..), ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

second :: Natural
second = 1000000

minute :: Natural
minute = 60 * second

-- | The stack's cluster, as the registry spells it.
cluster :: String
cluster = Text.unpack awsEksProvisionedClusterName

-- | A stack's account: the world the audit enumerates, whether the stack record
-- is still held, every command either runner was given, and the clock.
data Account = Account
  { accountWorld :: IORef World
  , accountClock :: VirtualWorld
  , accountStackHeld :: IORef Bool
  , accountAwsCalls :: IORef [[String]]
  , accountPulumiCalls :: IORef [[String]]
  , accountPassStarts :: IORef [Natural]
  -- ^ The virtual instants each destroy pass began, in seconds from the start.
  , accountRecordedVpc :: IORef (Maybe Text)
  -- ^ A VPC the stack's outputs record that is not the account's, when set.
  , accountLock :: IORef Bool
  -- ^ The lock a Pulumi that was killed leaves in the backend; the next destroy
  -- stops on it until @pulumi cancel@ removes it.
  , accountHardKill :: IORef Bool
  -- ^ Whether a pass cut at its bound is killed, and leaves its lock, and not
  -- stopped, as a Pulumi that takes the second SIGTERM is.
  , accountOutputMode :: IORef OutputMode
  , accountCallSeconds :: IORef Natural
  -- ^ What each AWS or short Pulumi call costs, in virtual seconds. The Provider
  -- runs them one at a time under a small CPU envelope, so a call is seconds and
  -- not an instant.
  , accountCleanSeconds :: IORef Natural
  -- ^ How long a destroy pass with nothing in its way takes.
  }

-- | What reading the stack's outputs finds.
data OutputMode
  = OutputReadable
  | OutputUnreadable
  | OutputWithoutVpc
  deriving stock (Eq, Show)

newAccount :: World -> IO Account
newAccount world =
  Account
    <$> newIORef world
    <*> newVirtualWorld
    <*> newIORef True
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef Nothing
    <*> newIORef False
    <*> newIORef False
    <*> newIORef OutputReadable
    <*> newIORef 0
    <*> newIORef 240

elapsedSeconds :: Account -> IO Natural
elapsedSeconds account = do
  now <- virtualNowMicros (accountClock account)
  pure ((now - virtualStartMicros) `div` second)

fieldOr :: Text -> Text -> Planted -> Text
fieldOr key fallback planted = fromMaybe fallback (lookup key (plantedFields planted))

-- | The VPC's own default group, which goes with the VPC.
isDefaultGroup :: Planted -> Bool
isDefaultGroup planted = fieldOr "name" "" planted == "default" && inStackVpc planted

-- | A resource in a VPC other than the stack's carries a @vpc@ field.
inStackVpc :: Planted -> Bool
inStackVpc planted = fieldOr "vpc" vpcId planted == vpcId

-- | An interface an AWS service holds vanishes when its release time comes, and
-- one still attached to a terminating node becomes available when the node is
-- gone.
settle :: Account -> IO ()
settle account = do
  elapsed <- elapsedSeconds account
  modifyIORef'
    (accountWorld account)
    ( \world ->
        world
          { worldPlanted =
              [ becomeAvailable elapsed p
              | p <- worldPlanted world
              , not (releasedBy elapsed p)
              ]
          }
    )
 where
  releasedBy elapsed planted = case lookup "releaseAt" (plantedFields planted) of
    Just at -> secondsOf at <= elapsed
    Nothing -> False
  becomeAvailable elapsed planted = case lookup "availableAt" (plantedFields planted) of
    Just at
      | secondsOf at <= elapsed ->
          planted
            { plantedFields =
                ("status", "available")
                  : [kv | kv@(key, _) <- plantedFields planted, key `notElem` ["status", "availableAt"]]
            }
    _ -> planted
  secondsOf at = fromIntegral (read (Text.unpack at) :: Integer) :: Natural

-- ---------------------------------------------------------------------------
-- The AWS runner

awsAccountRunner :: Account -> AwsNativeStackFamilyRunner IO
awsAccountRunner account = AwsNativeStackFamilyRunner $ \arguments -> do
  modifyIORef' (accountAwsCalls account) (<> [arguments])
  callCost <- readIORef (accountCallSeconds account)
  advanceVirtualClock (accountClock account) (callCost * second)
  settle account
  world <- readIORef (accountWorld account)
  case arguments of
    "ec2" : "delete-network-interface" : _ -> deleteInterface account arguments
    "ec2" : "delete-security-group" : _ -> deleteGroup account arguments
    "ec2" : "describe-network-interfaces" : _
      | "json" `elem` arguments -> pure (interfaceListing world arguments)
    "ec2" : "describe-security-groups" : _
      | "json" `elem` arguments -> pure (groupListing world arguments)
    "ec2" : operation : _
      | operation `elem` chainOperations -> chainOperation account operation arguments
    _ -> pure (respond world arguments)

-- | The commands the manifest route's chain issues, which the account carries out
-- under the dependency rules the provider enforces.
chainOperations :: [String]
chainOperations =
  [ "terminate-instances"
  , "disassociate-route-table"
  , "delete-route-table"
  , "delete-subnet"
  , "detach-internet-gateway"
  , "delete-internet-gateway"
  , "delete-vpc"
  ]

chainOperation :: Account -> String -> [String] -> IO ProcessOutput
chainOperation account operation arguments = do
  world <- readIORef (accountWorld account)
  let interfaces = [p | p <- ofClassIn AuditNetworkInterface world, inStackVpc p]
      stragglers =
        [ p
        | p <- worldPlanted world
        , plantedClass p `elem` [AuditSubnet, AuditSecurityGroup, AuditInternetGateway]
        , not (isDefaultGroup p)
        , inStackVpc p
        ]
      identity flag = Text.pack (afterFlag flag arguments)
  case operation of
    "delete-subnet"
      | any (blocksSubnet (Text.pack (afterFlag "--subnet-id" arguments))) interfaces ->
          pure
            ( violation
                "DeleteSubnet"
                ( "The subnet '"
                    <> Text.unpack (identity "--subnet-id")
                    <> "' has dependencies and cannot be deleted."
                )
            )
      | otherwise -> removeAndSucceed (identity "--subnet-id")
    "delete-vpc"
      | not (null stragglers) || not (null interfaces) ->
          pure (violation "DeleteVpc" "The vpc has dependencies and cannot be deleted.")
      | otherwise -> do
          modifyIORef' (accountWorld account) (\w -> w {worldVpc = Nothing})
          pure (success "")
    "delete-route-table" -> removeAndSucceed (identity "--route-table-id")
    "delete-internet-gateway" -> removeAndSucceed (identity "--internet-gateway-id")
    _ -> pure (success "{}")
 where
  removeAndSucceed wanted = do
    modifyIORef' (accountWorld account) (removePlanted wanted)
    pure (success "")
  violation call detail =
    failure
      ( "An error occurred (DependencyViolation) when calling the "
          <> call
          <> " operation: "
          <> detail
      )

-- | The VPC a listing's filter names.
-- EC2 refuses a filter it does not know, and a listing with no filter returns the
-- whole region, so the fake does both: a listing that dropped or misspelt its VPC
-- filter must not look like one that asked for the stack's VPC.
vpcFilterOf :: [String] -> Either String (Maybe Text)
vpcFilterOf arguments = case filters of
  [] -> Right Nothing
  [one]
    | prefix `isPrefixOfString` one -> Right (Just (Text.pack (drop (length prefix) one)))
  _ ->
    Left
      ( "An error occurred (InvalidParameterValue) when calling the operation: the filter is invalid: "
          <> unwords filters
      )
 where
  prefix = "Name=vpc-id,Values="
  filters = takeWhile (\value -> take 2 value /= "--") (drop 1 (dropWhile (/= "--filters") arguments))
  isPrefixOfString needle haystack = needle == take (length needle) haystack

interfaceListing :: World -> [String] -> ProcessOutput
interfaceListing world arguments = case vpcFilterOf arguments of
  Left detail -> failure detail
  Right wanted ->
    success . LazyByteStringChar8.unpack . encode $
      [ interfaceRow p
      | p <- ofClassIn AuditNetworkInterface world
      , maybe True (== fieldOr "vpc" vpcId p) wanted
      ]

interfaceRow :: Planted -> Value
interfaceRow p =
  object
    [ "id" .= plantedId p
    , "vpc" .= fieldOr "vpc" vpcId p
    , "status" .= fieldOr "status" "available" p
    , "managed" .= isManaged p
    , "requester_managed" .= isManaged p
    , "type" .= fieldOr "type" "interface" p
    , "description" .= fieldOr "description" "" p
    , "owner" .= maybe Null String (lookup "owner" (plantedFields p))
    , "cluster" .= maybe Null String (lookup "cluster" (plantedFields p))
    ]

isManaged :: Planted -> Bool
isManaged planted = fieldOr "managed" "false" planted == "true"

groupListing :: World -> [String] -> ProcessOutput
groupListing world arguments = case vpcFilterOf arguments of
  Left detail -> failure detail
  Right wanted ->
    success . LazyByteStringChar8.unpack . encode $
      [ object
          [ "id" .= plantedId p
          , "vpc" .= fieldOr "vpc" vpcId p
          , "name" .= fieldOr "name" "" p
          , "cluster" .= maybe Null String (lookup "cluster" (plantedFields p))
          ]
      | p <- ofClassIn AuditSecurityGroup world
      , maybe True (== fieldOr "vpc" vpcId p) wanted
      ]

ofClassIn :: AuditClass -> World -> [Planted]
ofClassIn class' world = [p | p <- worldPlanted world, plantedClass p == class']

deleteInterface :: Account -> [String] -> IO ProcessOutput
deleteInterface account arguments = do
  world <- readIORef (accountWorld account)
  let wanted = Text.pack (afterFlag "--network-interface-id" arguments)
  case [p | p <- ofClassIn AuditNetworkInterface world, plantedId p == wanted] of
    [] ->
      pure
        ( failure
            "An error occurred (InvalidNetworkInterfaceID.NotFound) when calling the DeleteNetworkInterface operation"
        )
    p : _
      | fieldOr "status" "available" p /= "available" || isManaged p ->
          pure
            ( failure
                "An error occurred (InvalidParameterValue) when calling the DeleteNetworkInterface operation: Network interface is currently in use and cannot be deleted"
            )
      | otherwise -> do
          modifyIORef' (accountWorld account) (removePlanted wanted)
          pure (success "")

deleteGroup :: Account -> [String] -> IO ProcessOutput
deleteGroup account arguments = do
  world <- readIORef (accountWorld account)
  let wanted = Text.pack (afterFlag "--group-id" arguments)
      users = [p | p <- ofClassIn AuditNetworkInterface world, wanted `elem` groupsOf p]
  case [p | p <- ofClassIn AuditSecurityGroup world, plantedId p == wanted] of
    [] ->
      pure
        (failure "An error occurred (InvalidGroup.NotFound) when calling the DeleteSecurityGroup operation")
    _
      | not (null users) ->
          pure
            ( failure
                ( "An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource "
                    <> Text.unpack wanted
                    <> " has a dependent object"
                )
            )
      | otherwise -> do
          modifyIORef' (accountWorld account) (removePlanted wanted)
          pure (success "")

groupsOf :: Planted -> [Text]
groupsOf planted = filter (not . Text.null) (Text.splitOn "," (fieldOr "groups" "" planted))

removePlanted :: Text -> World -> World
removePlanted wanted world =
  world {worldPlanted = [p | p <- worldPlanted world, plantedId p /= wanted]}

afterFlag :: String -> [String] -> String
afterFlag flag arguments = case dropWhile (/= flag) arguments of
  _ : value : _ -> value
  _ -> ""

-- ---------------------------------------------------------------------------
-- The Pulumi runner

-- | A Pulumi child over the account. @bound@ is read when the child starts: a
-- child that would run past it is stopped there, as the Provider's runner stops
-- one, and says so in its transcript.
pulumiAccountRunner :: Account -> IO Natural -> [String] -> IO ProcessOutput
pulumiAccountRunner account bound arguments = do
  modifyIORef' (accountPulumiCalls account) (<> [arguments])
  callCost <- readIORef (accountCallSeconds account)
  unless (take 1 arguments == ["destroy"]) $
    advanceVirtualClock (accountClock account) (callCost * second)
  settle account
  left <- bound
  -- The Provider starts no child, of any kind, in a window its bound leaves
  -- nothing of.
  if left == 0
    then
      pure (failure "no session window is left for a Pulumi pass once the work after it is reserved for")
    else pulumiCommand account bound arguments

-- | A flag Pulumi needs in a non-interactive run; without it the real command
-- stops at a prompt, and so does the fake.
requiring :: [String] -> [String] -> IO ProcessOutput -> IO ProcessOutput
requiring flags arguments action
  | all (`elem` arguments) flags = action
  | otherwise =
      pure
        ( failure
            ( "error: "
                <> unwords [flag | flag <- flags, flag `notElem` arguments]
                <> " is required in a non-interactive run"
            )
        )

pulumiCommand :: Account -> IO Natural -> [String] -> IO ProcessOutput
pulumiCommand account bound arguments =
  case arguments of
    "stack" : "select" : _ -> do
      held <- readIORef (accountStackHeld account)
      pure
        ( if held
            then success ""
            else failure "error: no stack named 'aws-eks-test' found"
        )
    "stack" : "output" : _ -> do
      world <- readIORef (accountWorld account)
      override <- readIORef (accountRecordedVpc account)
      mode <- readIORef (accountOutputMode account)
      pure $ case mode of
        OutputUnreadable -> failure "error: the stack outputs could not be read"
        OutputWithoutVpc ->
          success . LazyByteStringChar8.unpack . encode $
            object ["cluster_name" .= (cluster :: String)]
        OutputReadable ->
          success . LazyByteStringChar8.unpack . encode $
            object
              [ "vpc_id" .= maybe Null String (override <|> worldVpc world)
              , "cluster_name" .= (cluster :: String)
              ]
    "cancel" : _ ->
      requiring ["--stack", "--yes", "--non-interactive"] arguments $ do
        writeIORef (accountLock account) False
        pure (success "The currently running update for 'aws-eks-test' has been canceled!")
    "stack" : "rm" : _ ->
      requiring ["--yes", "--non-interactive"] arguments $ do
        writeIORef (accountStackHeld account) False
        pure (success "")
    "destroy" : _ ->
      requiring ["--yes", "--non-interactive", "--refresh", "--continue-on-error"] arguments $
        destroyPass account bound
    _ -> pure (success "")

-- | Walk the account the way the provider does. A subnet refuses to delete
-- while an interface sits in the VPC and the provider retries the refusal for
-- most of an hour; a stack-owned group refuses while an interface uses it; the
-- VPC refuses while anything but its default group remains.
destroyPass :: Account -> IO Natural -> IO ProcessOutput
destroyPass account bound = do
  elapsed <- elapsedSeconds account
  modifyIORef' (accountPassStarts account) (<> [elapsed])
  locked <- readIORef (accountLock account)
  if locked
    then
      pure
        ( failure
            "error: the stack is currently locked by 1 lock(s). Either wait for the other process(es) to end or delete the lock file with `pulumi cancel`."
        )
    else destroyUnlocked account bound

destroyUnlocked :: Account -> IO Natural -> IO ProcessOutput
destroyUnlocked account bound = do
  world <- readIORef (accountWorld account)
  let interfaces = [p | p <- ofClassIn AuditNetworkInterface world, inStackVpc p]
      subnets = ofClassIn AuditSubnet world
      ownGroups = [p | p <- ofClassIn AuditSecurityGroup world, plantedNamed p]
      strayGroups =
        [ p
        | p <- ofClassIn AuditSecurityGroup world
        , not (plantedNamed p)
        , fieldOr "name" "" p /= "default"
        , inStackVpc p
        ]
      subnetErrors =
        [ violation
            "DeleteSubnet"
            ("The subnet '" <> Text.unpack (plantedId s) <> "' has dependencies and cannot be deleted.")
        | s <- subnets
        , any (blocksSubnet (plantedId s)) interfaces
        ]
      groupErrors =
        [ violation
            "DeleteSecurityGroup"
            ("resource " <> Text.unpack (plantedId g) <> " has a dependent object")
        | g <- ownGroups
        , any (\i -> plantedId g `elem` groupsOf i) interfaces
        ]
      vpcErrors =
        [ violation
            "DeleteVpc"
            ("The vpc '" <> Text.unpack vpcId' <> "' has dependencies and cannot be deleted.")
        | not (null subnetErrors && null groupErrors) || not (null strayGroups)
        , Just vpcId' <- [worldVpc world]
        ]
      errors = subnetErrors <> groupErrors <> vpcErrors
  allowed <- bound
  -- A clean destroy of what is left takes four minutes unless the account says
  -- otherwise; a pass given less is cut there, as the Provider's runner cuts one,
  -- and has destroyed nothing.
  cleanSeconds <- readIORef (accountCleanSeconds account)
  let cleanly = cleanSeconds * second
  if null errors && cleanly <= allowed * second
    then do
      advanceVirtualClock (accountClock account) cleanly
      modifyIORef'
        (accountWorld account)
        ( \w ->
            w
              { worldVpc = Nothing
              , worldPlanted =
                  [ p
                  | p <- worldPlanted w
                  , plantedClass p `notElem` [AuditSubnet, AuditRouteTable, AuditInternetGateway]
                  , not (plantedClass p == AuditSecurityGroup && (plantedNamed p || isDefaultGroup p))
                  ]
              }
        )
      pure (success "Resources:\n    - 12 deleted\n")
    else do
      -- The provider retries a refused subnet delete for twenty minutes, and the
      -- subnets nothing holds are gone in the meantime.
      let wanted = if null errors then cleanly else 20 * minute
          ran = min wanted (allowed * second)
          cut = wanted > allowed * second
      advanceVirtualClock (accountClock account) ran
      unless (null errors) $
        modifyIORef'
          (accountWorld account)
          ( \w ->
              w
                { worldPlanted =
                    [ p
                    | p <- worldPlanted w
                    , not (plantedClass p == AuditSubnet && not (any (blocksSubnet (plantedId p)) interfaces))
                    ]
                }
          )
      hard <- readIORef (accountHardKill account)
      when (cut && hard) (writeIORef (accountLock account) True)
      pure
        ( ProcessOutput
            (if cut then ExitFailure 124 else ExitFailure 255)
            ( unlines errors
                <> ( if cut
                       then "\n[child-timeout] pulumi was stopped after " <> show allowed <> " seconds"
                       else ""
                   )
            )
            ""
        )
 where
  violation operation detail =
    "    error: operation error EC2: "
      <> operation
      <> ", https response error StatusCode: 400, RequestID: 00000000-0000-0000-0000-000000000000, api error DependencyViolation: "
      <> detail

-- | Whether an interface keeps a subnet from being deleted. One that records no
-- subnet is taken to be in every one, as the earlier shapes were; one that does
-- holds only its own, which is what the 2026-10-14 inventory shows: the subnets
-- nothing used had gone and the interface's own remained.
blocksSubnet :: Text -> Planted -> Bool
blocksSubnet subnet interface = case lookup "subnet" (plantedFields interface) of
  Just own -> own == subnet
  Nothing -> True

-- ---------------------------------------------------------------------------
-- The world the loop is given

lifetime :: Natural
lifetime = providerWorkerIntentLifetimeMicros

-- | The seconds of the session that remain usable, as the loop's children are
-- bounded by them.
windowSeconds :: Account -> Natural -> IO Natural
windowSeconds account expiresAt = do
  now <- virtualNowMicros (accountClock account)
  let spoken = now + sessionGraceSeconds * second
  pure ((if expiresAt > spoken then expiresAt - spoken else 0) `div` second)

-- | A session begins when a run begins and lasts the intent's lifetime plus the
-- read-back grace, as a fresh one does; a rerun is a new intent with a new one.
sessionEndFrom :: Natural -> Natural
sessionEndFrom beganAt = beganAt + lifetime + sessionGraceSeconds * second

-- | The loop's world for a run that begins now.
destroyWorld
  :: Account
  -> Maybe (AwsWaitEnvironment IO -> IO (Either Text ()))
  -> IO (StackDestroyWorld IO)
destroyWorld account loadBalancers = do
  beganAt <- virtualNowMicros (accountClock account)
  let sessionEnd = sessionEndFrom beganAt
      -- The bound is the Provider's own, from the same functions: the window the
      -- session has left, less what the pass reserves, under the pass's ceiling.
      boundFor pass = do
        window <- windowSeconds account sessionEnd
        let (reserveMicros, ceilingMicros) = destroyPassBounds lifetime pass
        pure $ case pulumiChildLimitsFor reserveMicros ceilingMicros (window * second) of
          Left _ -> 0
          Right limits -> fromIntegral (killableSubprocessTimeoutMicros limits) `div` second
  pure
    StackDestroyWorld
      { worldStackName = "aws-eks-test"
      , worldPulumi = \pass -> pulumiAccountRunner account (boundFor pass)
      , worldPulumiShort = pulumiAccountRunner account (windowSeconds account sessionEnd)
      , worldAws = awsAccountRunner account
      , worldWaits = virtualWaitEnvironment (accountClock account) sessionEnd
      , worldFinalPassReserveMicros = finalPassReserveMicros lifetime
      , worldRef = refFor "aws-eks"
      , worldConfig = configFor "aws-eks"
      , worldCluster = Just awsEksProvisionedClusterName
      , worldLoadBalancers = loadBalancers
      }

-- ---------------------------------------------------------------------------
-- The shapes the 2026-10-14 hand inventory recorded, with reserved example
-- identifiers

eksVpc :: World
eksVpc =
  plant AuditSubnet "subnet-0aaaaaaaaaaaaaaa1" [("state", "available")] True $
    plant AuditSubnet "subnet-0aaaaaaaaaaaaaaa2" [("state", "available")] True $
      plant AuditSecurityGroup "sg-0000000000000default" [("name", "default")] False $
        withVpc emptyWorld

-- | The leaked interface: available, not requester-managed, described by the VPC
-- CNI and tagged for the cluster, and still holding the cluster's group.
leakedInterface :: World -> World
leakedInterface =
  plant
    AuditNetworkInterface
    "eni-0cccccccccccccccc"
    [ ("status", "available")
    , ("managed", "false")
    , ("type", "interface")
    , ("description", "aws-K8S-i-0aaaaaaaaaaaaaaaa")
    , ("owner", "amazon-vpc-cni")
    , ("cluster", Text.pack cluster)
    , ("groups", "sg-0bbbbbbbbbbbbbbbb")
    , ("subnet", "subnet-0aaaaaaaaaaaaaaa1")
    ]
    False

-- | The group EKS made for the cluster.
orphanedClusterGroup :: World -> World
orphanedClusterGroup =
  plant
    AuditSecurityGroup
    "sg-0bbbbbbbbbbbbbbbb"
    [ ("name", Text.pack ("eks-cluster-sg-" <> cluster <> "-1700000000"))
    , ("cluster", Text.pack cluster)
    ]
    False

recorded :: World
recorded = orphanedClusterGroup (leakedInterface eksVpc)

-- | Commands of a kind, by the operation they name.
callsTo :: String -> [[String]] -> [[String]]
callsTo operation = filter (operation `elem`)

deletedInterfaces :: Account -> IO [String]
deletedInterfaces account = do
  calls <- readIORef (accountAwsCalls account)
  pure [afterFlag "--network-interface-id" c | c <- callsTo "delete-network-interface" calls]

remainingIdentities :: Account -> AuditClass -> IO [Text]
remainingIdentities account class' = do
  world <- readIORef (accountWorld account)
  pure [plantedId p | p <- ofClassIn class' world]

awsDestroyConvergeSuite :: SuiteBuilder ()
awsDestroyConvergeSuite =
  describe "Sprint 4.111 a destroy converges over a scripted account" $ do
    describe "the closed predicates" $ do
      let target =
            either (error . show) id (mkDependentsTarget vpcId (Just awsEksProvisionedClusterName))
          row =
            InterfaceRow
              { interfaceId = "eni-0cccccccccccccccc"
              , interfaceVpc = vpcId
              , interfaceStatus = "available"
              , interfaceManaged = False
              , interfaceType = "interface"
              , interfaceDescription = "aws-K8S-i-0aaaaaaaaaaaaaaaa"
              , interfaceOwnerTag = Just "amazon-vpc-cni"
              , interfaceClusterTag = Just awsEksProvisionedClusterName
              }
          dispositionOf = dependentDisposition . classifyInterface target

      it "admits the interface the 2026-10-14 inventory recorded" $
        dispositionOf row `shouldBe` Admitted

      it "admits it by the CNI's description alone, and by the CNI's tag alone" $ do
        dispositionOf row {interfaceOwnerTag = Nothing} `shouldBe` Admitted
        dispositionOf row {interfaceDescription = "", interfaceClusterTag = Nothing} `shouldBe` Admitted

      it "never admits an interface an AWS service holds, whatever else it says" $ do
        dispositionOf row {interfaceManaged = True} `shouldSatisfy` isHeld
        dispositionOf row {interfaceManaged = True, interfaceStatus = "in-use"} `shouldSatisfy` isHeld
        mapM_
          (\status -> dispositionOf row {interfaceStatus = status} `shouldSatisfy` isHeld)
          ["in-use", "attaching", "detaching"]

      it "never admits an interface that is not plainly the CNI's" $ do
        dispositionOf row {interfaceOwnerTag = Nothing, interfaceDescription = "someone else's"}
          `shouldSatisfy` isNotAdmitted
        dispositionOf row {interfaceType = "nat_gateway"} `shouldSatisfy` isNotAdmitted
        dispositionOf row {interfaceClusterTag = Just "another-cluster"} `shouldSatisfy` isNotAdmitted
        dispositionOf row {interfaceStatus = "pending"} `shouldSatisfy` isNotAdmitted

      it "admits nothing tagged for a cluster when the stack has none" $ do
        let noCluster = either (error . show) id (mkDependentsTarget vpcId Nothing)
        dependentDisposition (classifyInterface noCluster row) `shouldSatisfy` isNotAdmitted

      it "admits the group EKS made for this cluster, and no other group" $ do
        let group name tag = SecurityGroupRow "sg-0bbbbbbbbbbbbbbbb" vpcId name tag
            clusterGroup =
              group
                ("eks-cluster-sg-" <> awsEksProvisionedClusterName <> "-1700000000")
                (Just awsEksProvisionedClusterName)
            admitted = fmap dependentDisposition . classifySecurityGroup target
        admitted clusterGroup `shouldBe` Just Admitted
        admitted (group "default" Nothing) `shouldBe` Nothing
        admitted (group "k8s-elb-1234" Nothing) `shouldSatisfy` maybe False isNotAdmitted
        admitted
          (group ("eks-cluster-sg-" <> awsEksProvisionedClusterName <> "-1") (Just "another-cluster"))
          `shouldSatisfy` maybe False isNotAdmitted
        admitted (group "eks-cluster-sg-another-cluster-1" (Just awsEksProvisionedClusterName))
          `shouldSatisfy` maybe False isNotAdmitted

      it "refuses a VPC identifier that is not spelled as AWS spells one" $
        mapM_
          (\bad -> mkDependentsTarget bad Nothing `shouldSatisfy` either (const True) (const False))
          ["", "vpc-", "vpc-XYZ", "vpc-0a1b2c3d4e5f6071822", "vpc-1", "subnet-0a1b2c3d4e5f60718", "--vpc"]

      it "never admits an interface or a group that is not in the stack's VPC" $ do
        let elsewhere = "vpc-0ffffffffffffffff"
            clusterGroup vpc =
              SecurityGroupRow
                "sg-0bbbbbbbbbbbbbbbb"
                vpc
                ("eks-cluster-sg-" <> awsEksProvisionedClusterName <> "-1700000000")
                (Just awsEksProvisionedClusterName)
        dispositionOf row {interfaceVpc = elsewhere} `shouldSatisfy` isNotAdmitted
        -- Not even a requester-managed one: it is not this stack's to wait for.
        dispositionOf row {interfaceVpc = elsewhere, interfaceManaged = True} `shouldSatisfy` isNotAdmitted
        fmap dependentDisposition (classifySecurityGroup target (clusterGroup elsewhere))
          `shouldSatisfy` maybe False isNotAdmitted
        fmap dependentDisposition (classifySecurityGroup target (clusterGroup vpcId))
          `shouldBe` Just Admitted

    describe "what the executor asks of AWS" $ do
      let target =
            either (error . show) id (mkDependentsTarget vpcId (Just awsEksProvisionedClusterName))
          asking calls reply arguments = modifyIORef' calls (<> [arguments]) >> pure (reply arguments)
          answering text = const (pure (success text))

      it "asks for the stack's VPC, projects the VPC of every row, and reads nothing else" $ do
        calls <- newIORef []
        observed <- observeNetworkDependents (asking calls (const (success "[]"))) target
        observed `shouldBe` Right []
        asked <- readIORef calls
        map (take 2) asked
          `shouldBe` [["ec2", "describe-network-interfaces"], ["ec2", "describe-security-groups"]]
        mapM_
          ( \arguments -> do
              arguments `shouldSatisfy` elem ("Name=vpc-id,Values=" <> Text.unpack vpcId)
              arguments `shouldSatisfy` elem "json"
              take 1 (drop 1 (dropWhile (/= "--query") arguments))
                `shouldSatisfy` all (isInfixOf "vpc:VpcId")
          )
          asked

      it "reads a null answer, and a row with no VPC, as a listing it did not understand" $ do
        -- Each listing alone gets the odd answer, because the other's refusal would
        -- otherwise hide whether this one's parser refuses.
        let only command text arguments =
              pure (success (if command `elem` arguments then text else "[]"))
            noVpcInterface = "[{\"id\":\"eni-0cccccccccccccccc\",\"status\":\"available\"}]"
            noVpcGroup = "[{\"id\":\"sg-0bbbbbbbbbbbbbbbb\",\"name\":\"default\"}]"
            refused = either (const True) (const False)
        nullInterfaces <- observeNetworkDependents (only "describe-network-interfaces" "null") target
        nullInterfaces `shouldSatisfy` refused
        nullGroups <- observeNetworkDependents (only "describe-security-groups" "null") target
        nullGroups `shouldSatisfy` refused
        interfaceWithoutVpc <-
          observeNetworkDependents (only "describe-network-interfaces" noVpcInterface) target
        interfaceWithoutVpc `shouldSatisfy` refused
        groupWithoutVpc <- observeNetworkDependents (only "describe-security-groups" noVpcGroup) target
        groupWithoutVpc `shouldSatisfy` refused
        both <- observeNetworkDependents (answering "null") target
        both `shouldSatisfy` refused

      it
        "treats InvalidGroup.InUse as a group still held, and a missing interface of either spelling as gone"
        $ do
          account <- newAccount recorded
          inUseOnce <- newIORef True
          let base = awsAccountRunner account
              runner arguments
                | "delete-security-group" `elem` arguments = do
                    first' <- readIORef inUseOnce
                    if first'
                      then do
                        writeIORef inUseOnce False
                        pure
                          ( failure
                              "An error occurred (InvalidGroup.InUse) when calling the DeleteSecurityGroup operation: Group sg-0bbbbbbbbbbbbbbbb is used by another group"
                          )
                      else runAwsNativeStackFamilyCommand base arguments
                | "delete-network-interface" `elem` arguments = do
                    -- It is deleted, and the answer says the other spelling of gone.
                    _ <- runAwsNativeStackFamilyCommand base arguments
                    pure
                      ( failure
                          "An error occurred (InvalidNetworkInterface.NotFound) when calling the DeleteNetworkInterface operation: x"
                      )
                | otherwise = runAwsNativeStackFamilyCommand base arguments
          beganAt <- virtualNowMicros (accountClock account)
          let waits = virtualWaitEnvironment (accountClock account) (sessionEndFrom beganAt)
          repaired <-
            clearNetworkDependents
              (runAwsNativeStackFamilyCommand (AwsNativeStackFamilyRunner runner))
              waits
              target
          case repaired of
            Left detail -> expectationFailure (Text.unpack detail)
            Right done -> do
              repairDeletedGroups done `shouldBe` ["sg-0bbbbbbbbbbbbbbbb"]
              repairNotes done `shouldSatisfy` all (not . Text.isInfixOf "was not deleted")

      it "reaches nothing outside the VPC when a listing ignores its filter" $ do
        let foreignLeak =
              plant
                AuditNetworkInterface
                "eni-0eeeeeeeeeeeeeeee"
                [ ("status", "available")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0bbbbbbbbbbbbbbbb")
                , ("owner", "amazon-vpc-cni")
                , ("vpc", "vpc-0ffffffffffffffff")
                ]
                False
        account <- newAccount (foreignLeak recorded)
        let base = awsAccountRunner account
            withoutFilters arguments = case break (== "--filters") arguments of
              (before, _ : rest) -> before <> dropWhile (\value -> take 2 value /= "--") rest
              (before, []) -> before
            -- Only the executor's own listings lose their filter.
            isExecutorListing arguments =
              any (isInfixOf "id:NetworkInterfaceId") arguments || any (isInfixOf "id:GroupId") arguments
            ignoring =
              AwsNativeStackFamilyRunner $ \arguments ->
                runAwsNativeStackFamilyCommand
                  base
                  (if isExecutorListing arguments then withoutFilters arguments else arguments)
        _ <- destroyWorld account Nothing >>= \fresh -> stackDestroy fresh {worldAws = ignoring}
        -- The unfiltered listing returned the other VPC's interface, with every
        -- mark the CNI leaves; only the stack's own was deleted.
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0eeeeeeeeeeeeeeee"]

    describe "which VPC a repair acts in" $ do
      let isRefused choice = case choice of
            RefuseVpc _ -> True
            _ -> False
          isUnreadable recorded' = case recorded' of
            RecordedVpcUnreadable _ -> True
            _ -> False

      it "requires the recorded VPC and the one its tags name to be the same" $ do
        chooseVpc (RecordedVpc "vpc-1") (Right ["vpc-1"]) `shouldBe` UseVpc "vpc-1"
        chooseVpc (RecordedVpc "vpc-1") (Right ["vpc-2"]) `shouldSatisfy` isRefused
        chooseVpc (RecordedVpc "vpc-1") (Right []) `shouldSatisfy` isRefused
        -- A leftover of an earlier run of the same stack carries the same tags; the
        -- one the stack records is its own, and the repair acts there and nowhere else.
        chooseVpc (RecordedVpc "vpc-1") (Right ["vpc-1", "vpc-2"]) `shouldBe` UseVpc "vpc-1"
        chooseVpc (RecordedVpc "vpc-3") (Right ["vpc-1", "vpc-2"]) `shouldSatisfy` isRefused
        chooseVpc (RecordedVpc "vpc-1") (Left "denied") `shouldSatisfy` isRefused

      it "falls back to the one VPC its tags name only when the stack recorded none" $ do
        chooseVpc NoRecordedVpc (Right ["vpc-2"]) `shouldBe` UseVpc "vpc-2"
        chooseVpc NoRecordedVpc (Right []) `shouldBe` NoVpc
        chooseVpc NoRecordedVpc (Right ["vpc-1", "vpc-2"]) `shouldSatisfy` isRefused
        chooseVpc NoRecordedVpc (Left "denied") `shouldSatisfy` isRefused

      it "refuses, whatever the tags say, when the recorded outputs could not be read" $ do
        chooseVpc (RecordedVpcUnreadable "x") (Right ["vpc-1"]) `shouldSatisfy` isRefused
        chooseVpc (RecordedVpcUnreadable "x") (Right []) `shouldSatisfy` isRefused

      it "reads the recorded VPC from the stack's outputs, and tells none from unreadable" $ do
        recordedVpcOf "{\"vpc_id\":\"vpc-1\"}" `shouldBe` RecordedVpc "vpc-1"
        recordedVpcOf "{}" `shouldBe` NoRecordedVpc
        recordedVpcOf "{\"vpc_id\":null}" `shouldBe` NoRecordedVpc
        recordedVpcOf "[]" `shouldSatisfy` isUnreadable
        recordedVpcOf "not json" `shouldSatisfy` isUnreadable

    describe "the blocked report" $ do
      it "keeps its heading, what remains, and its next step however long the history is" $ do
        let history = [Text.replicate 700 "x" | _ <- [1 .. 12 :: Int]]
            report = renderBlocked history "the field still holds: eni x1 (eni-0cccccccccccccccc)"
        (Text.length report <= reportBound) `shouldBe` True
        report `shouldSatisfy` Text.isPrefixOf "blocked: the destroy did not converge"
        report `shouldSatisfy` Text.isInfixOf "eni-0cccccccccccccccc"
        report `shouldSatisfy` Text.isSuffixOf "names what remains"
        report `shouldSatisfy` Text.isInfixOf "..."

      it "keeps the first and the last step of a long history, and cuts the middle" $ do
        let history =
              ["FIRST-" <> Text.replicate 700 "a"]
                <> [Text.replicate 700 "m" | _ <- [1 .. 10 :: Int]]
                <> ["LAST-" <> Text.replicate 100 "z"]
            report = renderBlocked history "the field still holds: something"
        report `shouldSatisfy` Text.isInfixOf "FIRST-"
        report `shouldSatisfy` Text.isInfixOf "LAST-zzz"
        report `shouldSatisfy` Text.isInfixOf "..."
        (Text.length report <= reportBound) `shouldBe` True

      it "is the whole history when it fits" $
        renderBlocked ["one", "two"] "" `shouldSatisfy` Text.isInfixOf "one | two"

    describe "reading the field" $ do
      let stack = AuditAwsEks
          answered = [(class', auditAnswered []) | class' <- auditStackClasses stack]
          observe overrides =
            either
              (error . show)
              id
              ( mkAuditObservation
                  stack
                  [(class', fromMaybe answer (lookup class' overrides)) | (class', answer) <- answered]
                  AuditControlSeen
              )
          leakedRow = mkAuditRow AuditNetworkInterface "eni-0cccccccccccccccc" "available"

      it "is empty only when every class the destroy answers for was answered and holds nothing" $
        fieldStateOf (observe []) `shouldBe` Right FieldEmpty

      it "is not empty when a class went unanswered and nothing else was found" $ do
        let unread = fieldStateOf (observe [(AuditIamRole, auditUnanswered "iam get-role failed")])
        unread `shouldSatisfy` either (Text.isInfixOf (auditClassLabel AuditIamRole)) (const False)

      it "stands on a row whatever else went unanswered" $
        fieldStateOf
          ( observe
              [ (AuditNetworkInterface, auditAnswered [leakedRow])
              , (AuditIamRole, auditUnanswered "iam get-role failed")
              ]
          )
          `shouldSatisfy` either (const False) (/= FieldEmpty)

      it "leaves the per-run volumes to the volume reaper, whether found or unread" $ do
        fieldStateOf
          (observe [(AuditEbsVolume, auditAnswered [mkAuditRow AuditEbsVolume "vol-0leak" "available"])])
          `shouldBe` Right FieldEmpty
        fieldStateOf (observe [(AuditEbsVolume, auditUnanswered "describe-volumes failed")])
          `shouldBe` Right FieldEmpty
        loopOwnsClass AuditEbsVolume `shouldBe` False
        mapM_
          (\class' -> loopOwnsClass class' `shouldBe` True)
          [class' | class' <- [minBound .. maxBound], class' /= AuditEbsVolume]

    describe "the stack record" $ do
      it "is kept, and the report says why, when the field is empty but the record cannot be removed" $ do
        account <- newAccount eksVpc
        world <- destroyWorld account Nothing
        let failingRm arguments
              | take 2 arguments == ["stack", "rm"] = pure (failure "error: could not remove the stack")
              | otherwise = worldPulumiShort world arguments
        outcome <- stackDestroy world {worldPulumiShort = failingRm}
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "removing the stack record failed"
          Converged -> expectationFailure "a record that could not be removed must be reported"

    describe "the bounds the Provider gives a pass" $ do
      it "cuts the first pass at its share and keeps the final pass's reserve and the kill grace" $ do
        let (reserve, ceiling') = destroyPassBounds lifetime FirstPass
        ceiling' `shouldBe` firstPassCeilingMicros lifetime
        reserve `shouldBe` (finalPassReserveMicros lifetime + 45 * second)

      it "keeps the reading's reserve and the kill grace out of the final pass" $ do
        let (reserve, ceiling') = destroyPassBounds lifetime FinalPass
        reserve `shouldBe` (verdictReserveMicros + 45 * second)
        -- The authored values, pinned so that a change to any is deliberate.
        verdictReserveMicros `shouldBe` (120 * second)
        finalPassReserveMicros lifetime `shouldBe` (540 * second)
        -- The final pass is bounded by the session and the child maximum, and not
        -- by the first pass's share.
        ceiling' `shouldBe` (1680 * second)

      it "starts no pass in a window the reserve leaves nothing of, and gives one the rest" $ do
        let (reserve, ceiling') = destroyPassBounds lifetime FinalPass
            limitOf :: Natural -> Either Text Natural
            limitOf window =
              fromIntegral . killableSubprocessTimeoutMicros <$> pulumiChildLimitsFor reserve ceiling' window
        limitOf reserve `shouldSatisfy` either (const True) (const False)
        limitOf (reserve + 7 * second) `shouldBe` Right (7 * second)

    describe "a destroy over the recorded leak" $ do
      it "ends in DependencyViolation under the single pass, which is the prior behaviour" $ do
        account <- newAccount recorded
        world <- destroyWorld account Nothing
        outcome <- pulumiDestroySelected (worldPulumi world FinalPass) "aws-eks-test"
        outcome `shouldSatisfy` either (isInfixOf "DependencyViolation") (const False)
        -- The stack record is kept, and the interface is still there.
        readIORef (accountStackHeld account) `shouldReturn` True
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0cccccccccccccccc"]
        -- The pass got as far as AWS let it: the subnet nothing held is gone and
        -- the interface's own remains, which is the state the inventory recorded.
        remainingIdentities account AuditSubnet `shouldReturn` ["subnet-0aaaaaaaaaaaaaaa1"]

      it "converges: clears the interface, then the group, then finishes the destroy" $ do
        account <- newAccount recorded
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` []
        remainingIdentities account AuditSecurityGroup `shouldReturn` []
        readIORef (accountStackHeld account) `shouldReturn` False
        world <- readIORef (accountWorld account)
        worldVpc world `shouldBe` Nothing

      it "cuts the first pass at its bound and spends the rest on the repair and the final pass" $ do
        account <- newAccount recorded
        _ <- destroyWorld account Nothing >>= stackDestroy
        starts <- readIORef (accountPassStarts account)
        starts `shouldSatisfy` ((== 2) . length)
        case starts of
          [first', final] -> do
            first' `shouldBe` 0
            -- The first pass ran to its share of the intent (450 thousandths of
            -- 1,800 seconds) and was stopped there.
            final `shouldBe` 810
          _ -> expectationFailure "expected exactly two destroy passes"
        elapsed <- elapsedSeconds account
        (elapsed < 1800) `shouldBe` True

      it "touches nothing outside the predicate" $ do
        account <- newAccount recorded
        _ <- destroyWorld account Nothing >>= stackDestroy
        calls <- readIORef (accountAwsCalls account)
        [afterFlag "--group-id" c | c <- callsTo "delete-security-group" calls]
          `shouldBe` ["sg-0bbbbbbbbbbbbbbbb"]

      it "does nothing to a stack whose destroy was clean" $ do
        account <- newAccount eksVpc
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        calls <- readIORef (accountAwsCalls account)
        callsTo "delete-network-interface" calls `shouldBe` []
        callsTo "delete-security-group" calls `shouldBe` []
        starts <- readIORef (accountPassStarts account)
        length starts `shouldBe` 1

      it "clears the lock a killed first pass left, so the final pass can start" $ do
        account <- newAccount recorded
        writeIORef (accountHardKill account) True
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        pulumi <- readIORef (accountPulumiCalls account)
        -- The lock was cleared between the passes, and not before the first.
        [command | command : _ <- pulumi, command `elem` ["destroy", "cancel"]]
          `shouldBe` ["destroy", "cancel", "destroy"]

      it "would have been stopped by that lock without the recovery" $ do
        account <- newAccount recorded
        writeIORef (accountHardKill account) True
        world <- destroyWorld account Nothing
        effects <- stackDestroyEffects world
        outcome <- convergeDestroy effects {convergeRecover = pure []}
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "locked"
          Converged -> expectationFailure "the lock a killed pass leaves must stop a final pass that does not clear it"

      it "keeps the record when the first pass succeeds but the field still holds something" $ do
        -- Pulumi believes the stack is gone; a role it did not own is not.
        let role = case awsEksIamRoleNames of
              name : _ -> name
              [] -> error "no registered role name"
        account <- newAccount (plant AuditIamRole role [] False eksVpc)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf (auditClassLabel AuditIamRole)
          Converged -> expectationFailure "a field that still holds a role must keep the stack record"
        readIORef (accountStackHeld account) `shouldReturn` True
        -- A pass that finished by itself left no lock, so nothing was cancelled.
        pulumi <- readIORef (accountPulumiCalls account)
        [command | command : _ <- pulumi, command == "cancel"] `shouldBe` []

      it "keeps the record and says the field could not be read when a class goes unanswered" $ do
        -- The destroy finishes and nothing is found, but the read of the roles is
        -- refused: a gap with no row is a field that could not be read, never an
        -- empty one.
        account <- newAccount eksVpc
        modifyIORef' (accountWorld account) (\w -> w {worldBroken = ["get-role"]})
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "could not be read"
          Converged -> expectationFailure "the record was removed from a field that could not be read"
        readIORef (accountStackHeld account) `shouldReturn` True

      it "leaves a leaked per-run volume to the volume reaper and does not hold the record for it" $ do
        account <- newAccount (plant AuditEbsVolume "vol-0leak" [("state", "available")] False eksVpc)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        readIORef (accountStackHeld account) `shouldReturn` False

    describe "what a service holds" $ do
      let held releaseAt =
            plant
              AuditNetworkInterface
              "eni-0dddddddddddddddd"
              ( [ ("status", "in-use")
                , ("managed", "true")
                , ("type", "interface")
                , ("description", "ELB app/prodbox-public-edge/50dc6c495c0c9188")
                ]
                  <> [("releaseAt", Text.pack (show s)) | Just s <- [releaseAt :: Maybe Natural]]
              )
              False

      it "waits for a held interface to release and then converges" $ do
        -- The first pass is cut at 810 seconds, so the repair begins with the
        -- interface still held and it releases ninety seconds into the wait.
        account <- newAccount (held (Just 900) recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        pauses <- pausesTaken (accountClock account)
        pauses `shouldSatisfy` (not . null)
        pauses `shouldSatisfy` all (== 15 * second)
        -- It was never deleted by us: it left when its service released it.
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` []

      it "deletes an interface that became available while the repair waited" $ do
        -- Attached to a terminating node when the repair began, so held; the node
        -- is gone ninety seconds into the wait and the interface is the CNI's leak.
        let attached =
              plant
                AuditNetworkInterface
                "eni-0aaaaaaaaaaaaaaaa"
                [ ("status", "in-use")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0eeeeeeeeeeeeeeee")
                , ("owner", "amazon-vpc-cni")
                , ("cluster", Text.pack cluster)
                , ("availableAt", "900")
                ]
                False
        account <- newAccount (attached recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        deletedInterfaces account
          `shouldReturn` ["eni-0cccccccccccccccc", "eni-0aaaaaaaaaaaaaaaa"]

      it "is blocked, and says what holds it, when it never releases" $ do
        account <- newAccount (held Nothing recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Converged -> expectationFailure "a held interface must block the destroy"
          Blocked detail -> do
            detail `shouldSatisfy` Text.isInfixOf "eni-0dddddddddddddddd"
            detail `shouldSatisfy` Text.isInfixOf "blocked"
            detail `shouldSatisfy` Text.isInfixOf "next:"
            (Text.length detail <= 4096) `shouldBe` True
        -- The stack record is kept, so a rerun continues, and the held interface
        -- was never touched.
        readIORef (accountStackHeld account) `shouldReturn` True
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0dddddddddddddddd"]

      it "still gives the final pass its reserve when the waits spend their whole budget" $ do
        account <- newAccount (held Nothing recorded)
        _ <- destroyWorld account Nothing >>= stackDestroy
        starts <- readIORef (accountPassStarts account)
        elapsed <- elapsedSeconds account
        case starts of
          [_, final] -> do
            -- The final pass began with at least its reserve left of the intent.
            (1800 - final >= finalPassReserveMicros lifetime `div` second) `shouldBe` True
            (elapsed <= 1800) `shouldBe` True
          _ -> expectationFailure "expected exactly two destroy passes"

      it "converges on a rerun once the service has released it, from where the first run stopped" $ do
        account <- newAccount (held Nothing recorded)
        first' <- destroyWorld account Nothing >>= stackDestroy
        first' `shouldSatisfy` isBlocked
        -- The service lets go between the two runs.
        modifyIORef' (accountWorld account) (removePlanted "eni-0dddddddddddddddd")
        second' <- destroyWorld account Nothing >>= stackDestroy
        second' `shouldBe` Converged
        readIORef (accountStackHeld account) `shouldReturn` False

      it "clears nothing and waits for nothing while any owner of the VPC still exists" $
        mapM_
          ( \(class', identity, fields) -> do
              account <- newAccount (plant class' identity fields True recorded)
              outcome <- destroyWorld account Nothing >>= stackDestroy
              case outcome of
                Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "still exist"
                Converged -> expectationFailure (show class' <> " that is still there must keep the destroy open")
              deletedInterfaces account `shouldReturn` []
              pausesTaken (accountClock account) `shouldReturn` []
          )
          [ (AuditEksCluster, "aws-eks-test-cluster", [])
          , (AuditEksNodeGroup, "aws-eks-test-node-group", [])
          , (AuditEksAddon, "aws-ebs-csi-driver", [])
          , (AuditInstance, "i-0aaaaaaaaaaaaaaaa", [("state", "running")])
          ]

      it "reads the owners again after one read of them failed" $ do
        account <- newAccount recorded
        failedOnce <- newIORef False
        let base = awsAccountRunner account
            runner =
              AwsNativeStackFamilyRunner $ \arguments -> do
                seen <- readIORef failedOnce
                if not seen && "describe-cluster" `elem` arguments
                  then do
                    writeIORef failedOnce True
                    pure
                      ( failure
                          "An error occurred (RequestLimitExceeded) when calling the DescribeCluster operation: Request limit exceeded."
                      )
                  else runAwsNativeStackFamilyCommand base arguments
        outcome <- destroyWorld account Nothing >>= \fresh -> stackDestroy fresh {worldAws = runner}
        outcome `shouldBe` Converged
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]

      it "reads the stack's outputs again after one read of them failed" $ do
        account <- newAccount recorded
        failedOnce <- newIORef False
        world <- destroyWorld account Nothing
        let short arguments
              | take 2 arguments == ["stack", "output"] = do
                  seen <- readIORef failedOnce
                  if seen
                    then worldPulumiShort world arguments
                    else writeIORef failedOnce True >> pure (failure "error: could not read the outputs")
              | otherwise = worldPulumiShort world arguments
        outcome <- stackDestroy world {worldPulumiShort = short}
        outcome `shouldBe` Converged
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]

      it "does not call the load balancer reaper while the cluster still exists" $ do
        called <- newIORef False
        account <- newAccount (plant AuditEksCluster "aws-eks-test-cluster" [] True recorded)
        _ <-
          destroyWorld account (Just (\_ -> writeIORef called True >> pure (Right ()))) >>= stackDestroy
        readIORef called `shouldReturn` False

      it "clears the load balancers before it touches an interface" $ do
        account <- newAccount recorded
        deletesBefore <- newIORef Nothing
        let reaping _ = do
              calls <- readIORef (accountAwsCalls account)
              writeIORef deletesBefore (Just (length (callsTo "delete-network-interface" calls)))
              pure (Right ())
        outcome <- destroyWorld account (Just reaping) >>= stackDestroy
        outcome `shouldBe` Converged
        readIORef deletesBefore `shouldReturn` Just 0

      it "narrates a load balancer reaper that failed, and still clears the dependents" $ do
        account <- newAccount (held Nothing recorded)
        outcome <- destroyWorld account (Just (\_ -> pure (Left "denied by policy"))) >>= stackDestroy
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "load balancer family: denied by policy"
          Converged -> expectationFailure "a held interface must keep the destroy open"
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]

      it "keeps the final pass its reserve when a held interface also holds the cluster's group" $ do
        let holdsGroup =
              plant
                AuditNetworkInterface
                "eni-0dddddddddddddddd"
                [ ("status", "in-use")
                , ("managed", "true")
                , ("type", "interface")
                , ("description", "ELB app/prodbox-public-edge/50dc6c495c0c9188")
                , ("groups", "sg-0bbbbbbbbbbbbbbbb")
                ]
                False
        account <- newAccount (holdsGroup recorded)
        _ <- destroyWorld account Nothing >>= stackDestroy
        starts <- readIORef (accountPassStarts account)
        case starts of
          [_, final] -> (1800 - final >= finalPassReserveMicros lifetime `div` second) `shouldBe` True
          _ -> expectationFailure "expected exactly two destroy passes"

      it "removes the record of a stack whose final pass used its whole limit" $ do
        -- The repair's waits end at the reserve, so the final pass starts with
        -- exactly its limit left; a pass that takes all of it leaves the reading's
        -- reserve and the kill grace, which the short commands may use and a pass
        -- may not.
        let burning waits = do
              replicateM_ 3 (awaitFact waits SecurityGroupDeletable (pure (WaitMore () "held")))
              pure (Right ())
        account <- newAccount recorded
        let (stopReserve, _) = destroyPassBounds lifetime FinalPass
            limitSeconds = (finalPassReserveMicros lifetime - stopReserve) `div` second
        writeIORef (accountCleanSeconds account) limitSeconds
        outcome <- destroyWorld account (Just burning) >>= stackDestroy
        outcome `shouldBe` Converged
        readIORef (accountStackHeld account) `shouldReturn` False

      it "returns the typed report inside the intent when every call is slow" $ do
        account <- newAccount (held Nothing recorded)
        writeIORef (accountCallSeconds account) 12
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Blocked detail -> do
            detail `shouldSatisfy` Text.isInfixOf "could not be read"
            detail `shouldSatisfy` Text.isInfixOf "next:"
          Converged -> expectationFailure "a held interface must keep the destroy open"
        elapsed <- elapsedSeconds account
        -- Reads stop when the session has no time left for another, instead of
        -- running on past the intent's hard stop.
        (elapsed <= 1800) `shouldBe` True

      it "does not act around a cluster or an instance it cannot see" $ do
        account <- newAccount recorded
        modifyIORef' (accountWorld account) (\w -> w {worldBroken = ["describe-instances"]})
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "could not be read"
          Converged -> expectationFailure "an owner that cannot be seen must keep the destroy open"
        deletedInterfaces account `shouldReturn` []

      it "narrates a cancel that did not complete, and a cancel that did" $ do
        refused <- pulumiCancelStack (const (pure (failure "error: no stack named 'x' found"))) "x"
        refused `shouldSatisfy` all (Text.isInfixOf "did not complete")
        done <-
          pulumiCancelStack
            (const (pure (success "The currently running update for 'x' has been canceled!")))
            "x"
        done `shouldSatisfy` all (Text.isInfixOf "cleared")

      it "keeps the final pass its reserve when the load balancer family's wait spends its whole budget" $ do
        let burning waits = do
              -- Three waits that never end: more than the session has left.
              replicateM_ 3 (awaitFact waits SecurityGroupDeletable (pure (WaitMore () "held")))
              pure (Right ())
        account <- newAccount recorded
        outcome <- destroyWorld account (Just burning) >>= stackDestroy
        outcome `shouldBe` Converged
        elapsed <- elapsedSeconds account
        (elapsed <= 1800) `shouldBe` True
        -- The window was gone by the time the repair reached the interface and its
        -- group, and each still got its one attempt.
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditSecurityGroup `shouldReturn` []

      it "deletes again, while it waits for a group, an interface whose delete was refused" $ do
        let attached =
              plant
                AuditNetworkInterface
                "eni-0aaaaaaaaaaaaaaaa"
                [ ("status", "in-use")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0eeeeeeeeeeeeeeee")
                , ("owner", "amazon-vpc-cni")
                , ("cluster", Text.pack cluster)
                , ("groups", "sg-0bbbbbbbbbbbbbbbb")
                , ("availableAt", "900")
                ]
                False
        account <- newAccount (attached recorded)
        -- The delete is refused twice: the late delete, and the first retry.
        refusals <- newIORef (2 :: Int)
        let base = awsAccountRunner account
            runner =
              AwsNativeStackFamilyRunner $ \arguments ->
                if "delete-network-interface" `elem` arguments
                  && afterFlag "--network-interface-id" arguments == "eni-0aaaaaaaaaaaaaaaa"
                  then do
                    refused <- readIORef refusals
                    if refused > 0
                      then do
                        writeIORef refusals (refused - 1)
                        pure
                          ( failure
                              "An error occurred (RequestLimitExceeded) when calling the DeleteNetworkInterface operation: Request limit exceeded."
                          )
                      else runAwsNativeStackFamilyCommand base arguments
                  else runAwsNativeStackFamilyCommand base arguments
        outcome <- destroyWorld account Nothing >>= \fresh -> stackDestroy fresh {worldAws = runner}
        -- The refused delete would have held the group for the whole of its budget.
        outcome `shouldBe` Converged
        deletedInterfaces account
          `shouldReturn` ["eni-0cccccccccccccccc", "eni-0aaaaaaaaaaaaaaaa"]

    describe "over-deletion controls" $ do
      let foreignInterface =
            plant
              AuditNetworkInterface
              "eni-0eeeeeeeeeeeeeeee"
              [ ("status", "available")
              , ("managed", "false")
              , ("type", "interface")
              , ("description", "aws-K8S-i-0bbbbbbbbbbbbbbbb")
              , ("owner", "amazon-vpc-cni")
              , ("cluster", "another-cluster")
              , ("vpc", "vpc-0ffffffffffffffff")
              ]
              False
          unmarked =
            plant
              AuditNetworkInterface
              "eni-0111111111111111"
              [("status", "available"), ("managed", "false"), ("type", "interface"), ("description", "mine")]
              False
          otherCluster =
            plant
              AuditNetworkInterface
              "eni-0222222222222222"
              [ ("status", "available")
              , ("managed", "false")
              , ("type", "interface")
              , ("description", "aws-K8S-i-0cccccccccccccccc")
              , ("owner", "amazon-vpc-cni")
              , ("cluster", "another-cluster")
              ]
              False
          foreignGroup =
            plant
              AuditSecurityGroup
              "sg-0333333333333333"
              [ ("name", "eks-cluster-sg-another-cluster-1")
              , ("cluster", "another-cluster")
              , ("vpc", "vpc-0ffffffffffffffff")
              ]
              False

      it "never touches an interface in another VPC, and is not blocked by one" $ do
        account <- newAccount (foreignInterface recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0eeeeeeeeeeeeeeee"]

      it "never touches an interface that is not plainly the CNI's or is another cluster's, and says so" $ do
        account <- newAccount (otherCluster (unmarked recorded))
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Converged -> expectationFailure "an interface outside the predicate must block the destroy"
          Blocked detail -> do
            detail `shouldSatisfy` Text.isInfixOf "eni-0111111111111111"
            detail `shouldSatisfy` Text.isInfixOf "eni-0222222222222222"
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface
          `shouldReturn` ["eni-0111111111111111", "eni-0222222222222222"]

      it "reports a leaked interface of this cluster in another VPC and leaves it alone" $ do
        -- It carries this cluster's mark, so it belongs to this stack's field; it
        -- is in a VPC the stack does not record, so the repair never acts in it.
        let ours =
              plant
                AuditNetworkInterface
                "eni-0999999999999999"
                [ ("status", "available")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0dddddddddddddddd")
                , ("owner", "amazon-vpc-cni")
                , ("cluster", Text.pack cluster)
                , ("vpc", "vpc-0ffffffffffffffff")
                ]
                False
        account <- newAccount (ours recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Converged -> expectationFailure "a leak of this cluster's in another VPC must keep the destroy open"
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "eni-0999999999999999"
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0999999999999999"]

      it "never touches the VPC's default group or a group in another VPC" $ do
        account <- newAccount (foreignGroup recorded)
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged
        calls <- readIORef (accountAwsCalls account)
        -- Only the cluster's own group was deleted by the repair; the default
        -- group left with its VPC and the other VPC's group was never named.
        [afterFlag "--group-id" c | c <- callsTo "delete-security-group" calls]
          `shouldBe` ["sg-0bbbbbbbbbbbbbbbb"]
        remainingIdentities account AuditSecurityGroup `shouldReturn` ["sg-0333333333333333"]

      it "does not act when the recorded VPC differs from the tagged one" $ do
        account <- newAccount recorded
        -- The stack's outputs record a VPC that is not the one carrying its tags.
        writeIORef (accountRecordedVpc account) (Just "vpc-0aaaaaaaaaaaaaaaa")
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldSatisfy` isBlocked
        deletedInterfaces account `shouldReturn` []

      it "does not act when the stack's recorded outputs cannot be read" $ do
        account <- newAccount recorded
        writeIORef (accountOutputMode account) OutputUnreadable
        outcome <- destroyWorld account Nothing >>= stackDestroy
        case outcome of
          Blocked detail -> detail `shouldSatisfy` Text.isInfixOf "recorded VPC could not be read"
          Converged -> expectationFailure "an unreadable record must not become permission to act"
        deletedInterfaces account `shouldReturn` []

      it "acts in the one VPC its tags name when the stack recorded none, whatever a mark names" $ do
        -- This cluster's leaked interface in another VPC widens what the audit
        -- reads and never where the repair deletes: with no record to settle it,
        -- two located VPCs would stop the repair, and only one is tagged.
        let ours =
              plant
                AuditNetworkInterface
                "eni-0999999999999999"
                [ ("status", "available")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0dddddddddddddddd")
                , ("owner", "amazon-vpc-cni")
                , ("cluster", Text.pack cluster)
                , ("vpc", "vpc-0ffffffffffffffff")
                ]
                False
        account <- newAccount (ours recorded)
        writeIORef (accountOutputMode account) OutputWithoutVpc
        _ <- destroyWorld account Nothing >>= stackDestroy
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        remainingIdentities account AuditNetworkInterface `shouldReturn` ["eni-0999999999999999"]

      it "acts in the one VPC its tags name when the stack recorded none" $ do
        account <- newAccount recorded
        writeIORef (accountOutputMode account) OutputWithoutVpc
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged

    describe "a stack with no cluster" $ do
      it "clears a leaked interface and leaves every group to its owner" $ do
        let leak =
              plant
                AuditNetworkInterface
                "eni-0cccccccccccccccc"
                [ ("status", "available")
                , ("managed", "false")
                , ("type", "interface")
                , ("description", "aws-K8S-i-0aaaaaaaaaaaaaaaa")
                , ("owner", "amazon-vpc-cni")
                , ("subnet", "subnet-0aaaaaaaaaaaaaaa1")
                ]
                False
            stray =
              plant
                AuditSecurityGroup
                "sg-0bbbbbbbbbbbbbbbb"
                [ ("name", Text.pack ("eks-cluster-sg-" <> cluster <> "-1700000000"))
                , ("cluster", Text.pack cluster)
                ]
                False
        account <- newAccount (stray (leak eksVpc))
        world <- destroyWorld account Nothing
        outcome <-
          stackDestroy
            world
              { worldRef = refFor "aws-test"
              , worldConfig = configFor "aws-test"
              , worldCluster = Nothing
              }
        deletedInterfaces account `shouldReturn` ["eni-0cccccccccccccccc"]
        calls <- readIORef (accountAwsCalls account)
        callsTo "delete-security-group" calls `shouldBe` []
        outcome `shouldSatisfy` isBlocked

    describe "a repair that cannot finish leaves a rerun able to" $ do
      it
        "keeps the record and reports the refusal when a delete is refused, then converges once it is not"
        $ do
          account <- newAccount recorded
          refusing <- newIORef True
          let base = awsAccountRunner account
              runner =
                AwsNativeStackFamilyRunner $ \arguments -> do
                  refuse <- readIORef refusing
                  if refuse && "delete-security-group" `elem` arguments
                    then
                      pure
                        ( failure
                            "An error occurred (UnauthorizedOperation) when calling the DeleteSecurityGroup operation: not authorized"
                        )
                    else runAwsNativeStackFamilyCommand base arguments
          first' <- destroyWorld account Nothing >>= \fresh -> stackDestroy fresh {worldAws = runner}
          first' `shouldSatisfy` isBlocked
          readIORef (accountStackHeld account) `shouldReturn` True
          -- The interface is already gone; the rerun starts from there.
          remainingIdentities account AuditNetworkInterface `shouldReturn` []
          writeIORef refusing False
          second' <- destroyWorld account Nothing >>= \fresh -> stackDestroy fresh {worldAws = runner}
          second' `shouldBe` Converged

      it "reports a stack with nothing to destroy as converged without reading the field" $ do
        account <- newAccount recorded
        writeIORef (accountStackHeld account) False
        outcome <- destroyWorld account Nothing >>= stackDestroy
        outcome `shouldBe` Converged

    describe "the production wiring's pure parts" $ do
      it "gives the converging destroy to the stacks with a VPC and to no other" $ do
        let stacks = ["aws-eks", "aws-test", "aws-eks-subzone", "aws-ses"]
            hasVpc name = either (const False) stackHasVpc (mkProviderStackRef name)
        map hasVpc stacks `shouldBe` [True, True, False, False]

      it "sends the load balancer family the tags its validation accepts" $
        validateEksLoadBalancerControllerFamilyProjection
          awsEksLoadBalancerControllerName
          eksLoadBalancerControllerFamilyTags
          `shouldSatisfy` either (const False) (not . null)

    describe "the manifest route's reaper" $ do
      let ownStack =
            plant AuditRouteTable "rtb-0aaaaaaaaaaaaaaaa" [] True $
              plant AuditInternetGateway "igw-0aaaaaaaaaaaaaaaa" [] True $
                plant AuditSecurityGroup "sg-0000000000000own" [("name", "aws-test-sg")] True $
                  plant AuditSubnet "subnet-0aaaaaaaaaaaaaaa1" [("state", "available")] True $
                    plant AuditSubnet "subnet-0aaaaaaaaaaaaaaa2" [("state", "available")] True $
                      plant AuditSubnet "subnet-0aaaaaaaaaaaaaaa3" [("state", "available")] True $
                        withVpc emptyWorld
          leakedCni =
            plant
              AuditNetworkInterface
              "eni-0cccccccccccccccc"
              [ ("status", "available")
              , ("managed", "false")
              , ("type", "interface")
              , ("description", "aws-K8S-i-0aaaaaaaaaaaaaaaa")
              , ("owner", "amazon-vpc-cni")
              ]
              False
          heldForever =
            plant
              AuditNetworkInterface
              "eni-0dddddddddddddddd"
              [ ("status", "in-use")
              , ("managed", "true")
              , ("type", "interface")
              , ("description", "ELB app/prodbox-public-edge/50dc6c495c0c9188")
              ]
              False
          unmarked =
            plant
              AuditNetworkInterface
              "eni-0111111111111111"
              [("status", "available"), ("managed", "false"), ("type", "interface"), ("description", "mine")]
              False

      it "clears a leaked interface before it deletes a subnet, and then finishes the chain" $ do
        account <- newAccount (leakedCni ownStack)
        outcome <- reapTestStack account
        outcome `shouldBe` Right ()
        calls <- readIORef (accountAwsCalls account)
        let at operation = findIndexOf operation calls
        (at "delete-network-interface" < at "delete-subnet") `shouldBe` True
        world <- readIORef (accountWorld account)
        worldVpc world `shouldBe` Nothing

      it "does not stop the chain for a group the manifest already names" $ do
        account <- newAccount ownStack
        reapTestStack account `shouldReturn` Right ()
        calls <- readIORef (accountAwsCalls account)
        callsTo "delete-network-interface" calls `shouldBe` []

      it "refuses before the first subnet delete when a service still holds an interface, and names it" $ do
        account <- newAccount (heldForever ownStack)
        outcome <- reapTestStack account
        case outcome of
          Right () -> expectationFailure "a held interface must block the reaper"
          Left detail -> do
            detail `shouldSatisfy` Text.isInfixOf "blocked by network dependents"
            detail `shouldSatisfy` Text.isInfixOf "eni-0dddddddddddddddd"
        calls <- readIORef (accountAwsCalls account)
        callsTo "delete-subnet" calls `shouldBe` []
        callsTo "delete-network-interface" calls `shouldBe` []

      it "refuses, and touches nothing, when an interface is outside the predicate" $ do
        account <- newAccount (unmarked ownStack)
        outcome <- reapTestStack account
        outcome `shouldSatisfy` either (Text.isInfixOf "eni-0111111111111111") (const False)
        calls <- readIORef (accountAwsCalls account)
        callsTo "delete-network-interface" calls `shouldBe` []
        callsTo "delete-subnet" calls `shouldBe` []

      it "does not count what it has just deleted as a remainder when the closing listing cannot be taken" $ do
        account <- newAccount (leakedCni ownStack)
        deleted <- newIORef False
        beganAt <- virtualNowMicros (accountClock account)
        let base = awsAccountRunner account
            isListing arguments =
              "json" `elem` arguments
                && any (`elem` arguments) ["describe-network-interfaces", "describe-security-groups"]
            runner =
              AwsNativeStackFamilyRunner $ \arguments -> do
                gone <- readIORef deleted
                if gone && isListing arguments
                  then
                    pure
                      ( failure
                          "An error occurred (RequestLimitExceeded) when calling the Describe operation: Request limit exceeded."
                      )
                  else do
                    output <- runAwsNativeStackFamilyCommand base arguments
                    when
                      ("delete-network-interface" `elem` arguments && processExitCode output == ExitSuccess)
                      (writeIORef deleted True)
                    pure output
            ref = refFor "aws-test"
            config = configFor "aws-test"
            waits = virtualWaitEnvironment (accountClock account) (sessionEndFrom beganAt)
        observed <- observeAwsNativeStackFamily base ref config
        admitted <- either (fail . Text.unpack) pure observed
        reapAwsNativeStackFamilyWithin runner waits ref config admitted `shouldReturn` Right ()
 where
  findIndexOf operation calls =
    case [index | (index, command) <- zip [0 :: Int ..] calls, operation `elem` command] of
      index : _ -> index
      [] -> maxBound
  reapTestStack account = do
    beganAt <- virtualNowMicros (accountClock account)
    let runner = awsAccountRunner account
        ref = refFor "aws-test"
        config = configFor "aws-test"
        waits = virtualWaitEnvironment (accountClock account) (sessionEndFrom beganAt)
    observed <- observeAwsNativeStackFamily runner ref config
    admitted <- either (fail . Text.unpack) pure observed
    reapAwsNativeStackFamilyWithin runner waits ref config admitted
  isHeld disposition = case disposition of
    HeldByService _ -> True
    _ -> False
  isNotAdmitted disposition = case disposition of
    NotAdmitted _ -> True
    _ -> False
  isBlocked outcome = case outcome of
    Blocked _ -> True
    Converged -> False
