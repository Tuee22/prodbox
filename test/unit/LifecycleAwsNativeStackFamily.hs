{-# LANGUAGE OverloadedStrings #-}

module LifecycleAwsNativeStackFamily
  ( lifecycleAwsNativeStackFamilySuite
  )
where

import AwsWaitPolling
  ( VirtualWorld
  , newVirtualWorld
  , roomyWaitEnvironment
  , virtualNowMicros
  , virtualStartMicros
  )
import Control.Monad ((>=>))
import Data.Aeson (Value, eitherDecodeStrict, object, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, findIndex, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
  )
import Prodbox.Lifecycle.AwsNativeStackFamily qualified as Native
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
    nativeFamilyEvidenceValidationCase
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
        reapWithin
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
        reapWithin
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
        reapNative
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

    it
      "waits for each EKS child to leave by polling its status, in dependency order, with no wait subcommand"
      $ do
        world <- newVirtualWorld
        calls <- newIORef []
        runner <- eksAccount world calls defaultEksScripts
        reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) eksRef eksConfig
        reaped `shouldBe` Right ()
        commands <- readIORef calls
        -- The mutations, in dependency order. The account refuses to delete the
        -- cluster while its node group exists, so the order is also enforced there.
        mutationsOf commands
          `shouldBe` [ "delete-addon"
                     , "delete-nodegroup"
                     , "delete-open-id-connect-provider"
                     , "delete-cluster"
                     ]
        any ("wait" `elem`) commands `shouldBe` False
        -- Two minutes of ten second polls, five of fifteen, four of fifteen.
        elapsedSince world `shouldReturn` ((120 + 300 + 240) * second)
        -- Each child is read once before its delete, then polled every interval from zero.
        statusPolls "addon.status" commands `shouldBe` (1 + 13)
        statusPolls "nodegroup.status" commands `shouldBe` (1 + 21)
        statusPolls "cluster.status" commands `shouldBe` (1 + 17)

    it "waits for a child that is already deleting, without deleting it a second time" $ do
      -- The rerun after a wait that ran out of budget: the service may refuse a
      -- second delete of a child it is already deleting, so it is not issued.
      -- The node group is still leaving when the add-on is done, so the case
      -- reaches the branch it is about (a child that has already left is a
      -- different branch).
      world <- newVirtualWorld
      calls <- newIORef []
      runner <-
        eksAccount
          world
          calls
          defaultEksScripts
            { nodeGroupScript = (leavesAfter 420) {childStartsDeleting = True}
            }
      reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) eksRef eksConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      mutationsOf commands
        `shouldBe` ["delete-addon", "delete-open-id-connect-provider", "delete-cluster"]
      -- It is waited for: read once, then polled from where the add-on left it
      -- (second 120) until the node group leaves (second 420).
      statusPolls "nodegroup.status" commands `shouldBe` (1 + 21)
      elapsedSince world `shouldReturn` ((120 + 300 + 240) * second)

    it
      "ends in a typed timeout naming the fact when a child never leaves, and deletes nothing behind it"
      $ do
        world <- newVirtualWorld
        calls <- newIORef []
        runner <- eksAccount world calls defaultEksScripts {nodeGroupScript = neverLeaves}
        reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) eksRef eksConfig
        reaped `shouldSatisfy` either (Text.isPrefixOf "WaitTimedOut:") (const False)
        reaped `shouldSatisfy` either (Text.isInfixOf "EKS node group absent") (const False)
        reaped `shouldSatisfy` either (Text.isInfixOf "EKS node group status DELETING") (const False)
        commands <- readIORef calls
        mutationsOf commands `shouldBe` ["delete-addon", "delete-nodegroup"]
        -- The add-on's two minutes and the node group's whole budget: a quarter of
        -- the thirty minute intent.
        elapsedSince world `shouldReturn` ((120 + 450) * second)

    it "stops at once when a child reports a terminal failure status" $ do
      world <- newVirtualWorld
      calls <- newIORef []
      runner <-
        eksAccount
          world
          calls
          defaultEksScripts {nodeGroupScript = (leavesAfter 5) {childTerminalStatus = Just "DELETE_FAILED"}}
      reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) eksRef eksConfig
      reaped `shouldSatisfy` either (Text.isPrefixOf "WaitAborted:") (const False)
      reaped `shouldSatisfy` either (Text.isInfixOf "DELETE_FAILED") (const False)
      commands <- readIORef calls
      mutationsOf commands `shouldBe` ["delete-addon", "delete-nodegroup"]
      statusPolls "nodegroup.status" commands `shouldBe` 2

    it "keeps polling through a throttled status read" $ do
      world <- newVirtualWorld
      calls <- newIORef []
      runner <-
        eksAccount world calls defaultEksScripts {throttledNodeGroupPolls = 3}
      reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) eksRef eksConfig
      reaped `shouldBe` Right ()

    it "waits for terminated instances by polling their states, then removes the network behind them" $ do
      world <- newVirtualWorld
      calls <- newIORef []
      runner <- instanceAccount world calls (Just 60)
      reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) testRef testConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      any ("wait" `elem`) commands `shouldBe` False
      -- The states are read only after the terminate request ...
      findIndex (elem "terminate-instances") commands
        `shouldSatisfy` isBefore (findIndex isInstanceStatePoll commands)
      -- ... and the network is removed only after the last state poll.
      Just (lastIndexOfStatePoll commands)
        `shouldSatisfy` isBefore (findIndex (elem "disassociate-route-table") commands)
      -- Ten second polls from zero to a minute.
      elapsedSince world `shouldReturn` (60 * second)
      length (filter isInstanceStatePoll commands) `shouldBe` 7

    it "ends in a typed timeout when an instance never terminates, and removes none of the network" $ do
      world <- newVirtualWorld
      calls <- newIORef []
      runner <- instanceAccount world calls Nothing
      reaped <- Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) testRef testConfig
      reaped `shouldSatisfy` either (Text.isInfixOf "EC2 instances terminated") (const False)
      reaped `shouldSatisfy` either (Text.isInfixOf "shutting-down") (const False)
      commands <- readIORef calls
      indexOf "disassociate-route-table" commands `shouldBe` maxBound
      indexOf "delete-vpc" commands `shouldBe` maxBound
      -- Fifteen percent of the thirty minute intent.
      elapsedSince world `shouldReturn` (270 * second)

    -- A guard, not evidence of behaviour: the cases above show the behaviour,
    -- this keeps a later edit from reintroducing the shape they replace.
    it "keeps every aws wait subcommand out of the Provider's AWS code" $
      mapM_
        (readFile >=> (`shouldNotContain` "\"wait\""))
        [ "src/Prodbox/Lifecycle/AwsNativeStackFamily.hs"
        , "src/Prodbox/Lifecycle/EbsVolume.hs"
        , "src/Prodbox/ControlPlane/ProviderProduction.hs"
        ]

    it "deletes the exact parent delegation, then the zone's records, then the zone itself" $ do
      calls <- newIORef []
      reaped <-
        reapNative
          (recordingRunner calls (subzoneResponseHolding leftoverRecordsJson))
          subzoneRef
          subzoneConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      -- All three happen, each against the zone it is for, and in that order. The
      -- zone delete is asserted by presence and by the zone id it names, because an
      -- ordering assertion against an absent command holds vacuously.
      let parentDelete = findIndex (isChangeFor "ZPARENT123") commands
          zonePrune = findIndex (isChangeFor "ZSUBZONE123") commands
          zoneDelete = findIndex (elem "delete-hosted-zone") commands
      (parentDelete, zonePrune, zoneDelete) `shouldSatisfy` inOrder
      find (elem "delete-hosted-zone") commands
        `shouldBe` Just ["route53", "delete-hosted-zone", "--id", "ZSUBZONE123"]

    it
      "empties the subzone of the records the stack does not declare, exactly as the listing printed them"
      $ do
        -- The public-edge A record and the DNS01 challenge records land in the per-run
        -- zone; Route 53 refuses to delete a zone that still holds them, and refuses a
        -- delete that does not repeat a record's values (a TXT's quoted value, an alias
        -- target), so each record travels whole.
        calls <- newIORef []
        reaped <-
          reapNative
            (recordingRunner calls (subzoneResponseHolding leftoverRecordsJson))
            subzoneRef
            subzoneConfig
        reaped `shouldBe` Right ()
        commands <- readIORef calls
        -- The listing is the one the prune is allowed to make: the zone it deletes, as JSON,
        -- with the filter that keeps the zone's own SOA and NS.
        commands `shouldSatisfy` elem pruneListingArguments
        let zoneBatches =
              [ batch
              | command <- commands
              , isChangeFor "ZSUBZONE123" command
              , batch <- changeBatchOf command
              ]
            listed =
              eitherDecodeStrict (TextEncoding.encodeUtf8 (Text.pack leftoverRecordsJson))
                :: Either String [Value]
            expected = fmap expectedDeleteBatch listed
        length zoneBatches `shouldBe` 1
        soleBatch zoneBatches `shouldBe` expected

    it "leaves an already-empty subzone to a plain delete" $ do
      calls <- newIORef []
      reaped <-
        reapNative
          (recordingRunner calls subzoneResponse)
          subzoneRef
          subzoneConfig
      reaped `shouldBe` Right ()
      commands <- readIORef calls
      length
        [ command
        | command <- commands
        , "change-resource-record-sets" `elem` command
        , "ZSUBZONE123" `elem` command
        ]
        `shouldBe` 0
      find (elem "delete-hosted-zone") commands
        `shouldBe` Just ["route53", "delete-hosted-zone", "--id", "ZSUBZONE123"]

    it "refuses to delete a subzone whose records it could not read" $ do
      calls <- newIORef []
      reaped <-
        reapNative
          (recordingRunner calls (subzoneResponseHolding "not json"))
          subzoneRef
          subzoneConfig
      reaped `shouldSatisfy` either (const True) (const False)
      commands <- readIORef calls
      indexOf "delete-hosted-zone" commands `shouldBe` maxBound

    it "names the listing when it fails or is not an array, and finds a vanished zone already gone" $ do
      let answeringTheListing listing arguments
            | arguments == pruneListingArguments = listing
            | otherwise = subzoneResponse arguments
          deletesTheZone commands =
            find (elem "delete-hosted-zone") commands
              == Just ["route53", "delete-hosted-zone", "--id", "ZSUBZONE123"]
      -- A throttled or denied listing is reported as the listing's failure, and the zone
      -- is not deleted behind it (the delete would only fail later under another name).
      deniedCalls <- newIORef []
      denied <-
        reapNative
          ( recordingRunner
              deniedCalls
              ( answeringTheListing
                  (failure "AccessDenied: not authorized to perform route53:ListResourceRecordSets")
              )
          )
          subzoneRef
          subzoneConfig
      denied `shouldSatisfy` either (Text.isInfixOf "list Route 53 hosted zone records") (const False)
      deniedCommands <- readIORef deniedCalls
      indexOf "delete-hosted-zone" deniedCommands `shouldBe` maxBound
      -- An object where the filter should have produced an array is not read as an empty zone.
      objectCalls <- newIORef []
      notAnArray <-
        reapNative
          (recordingRunner objectCalls (answeringTheListing (success "{\"ResourceRecordSets\": []}")))
          subzoneRef
          subzoneConfig
      notAnArray `shouldSatisfy` either (Text.isInfixOf "not an array") (const False)
      objectCommands <- readIORef objectCalls
      indexOf "delete-hosted-zone" objectCommands `shouldBe` maxBound
      -- A listing that says the zone no longer exists has nothing to prune; the delete
      -- is still attempted, because it is tolerant of the same answer.
      goneCalls <- newIORef []
      gone <-
        reapNative
          ( recordingRunner
              goneCalls
              (answeringTheListing (failure "NoSuchHostedZone: No hosted zone found with ID: ZSUBZONE123"))
          )
          subzoneRef
          subzoneConfig
      gone `shouldBe` Right ()
      goneCommands <- readIORef goneCalls
      deletesTheZone goneCommands `shouldBe` True

    it "declares the per-run subzone force-destroyed and tagged for the sweep that gates the uninstall" $ do
      -- The unit cases above fake the AWS runner and nothing else reads the program, so a
      -- program that lost either line would pass them and fail only on a live account.
      program <- readFile "pulumi/aws-eks-subzone/Main.yaml"
      let zoneBlock =
            takeWhile
              (not . ("  parentNsDelegation:" `isPrefixOf`))
              (dropWhile (not . ("  subzone:" `isPrefixOf`)) (lines program))
          declared wanted = wanted `elem` map (dropWhile (== ' ')) zoneBlock
      declared "forceDestroy: true" `shouldBe` True
      declared "prodbox.io/managed-by: prodbox" `shouldBe` True
      declared "prodbox.io/substrate: aws" `shouldBe` True

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

-- | Sprint 4.99: the reproducer, now asserting the repair.
--
-- It was registered by Sprint @4.98@'s reconnaissance asserting the defect:
-- @encodeAwsNativeStackFamilyEvidence@ joined its fields with @Text.unlines@,
-- so every value it produced carried newlines, and
-- 'validateProviderIntentEvidence' refuses any character at or below @0x1f@.
-- The encoder and the validator disagreed, and this is the wired decision
-- observation -- Sprint @4.97@ established that @ObserveNativeStackFamily@ is
-- what the desired-absence decision actually runs.
--
-- The same case now asserts the opposite, against the same intent and the same
-- family. That is deliberate: a reproducer that is deleted when it passes
-- leaves nothing behind to notice a regression, and this one is cheap to keep.
nativeFamilyEvidenceValidationCase :: SuiteBuilder ()
nativeFamilyEvidenceValidationCase =
  it "native-family evidence is admitted by the Provider validator" $ do
    let request =
          mustRight
            ( mkAwsNativeStackFamilyObservationRequest
                AwsTestKey
                testScope
                revision
                testConfig
            )
        ref = awsNativeStackFamilyObservationRequestRef request
        evidence =
          mustRight (encodeAwsNativeStackFamilyEvidence ref ["vpc/vpc-1"])
        intent = ObserveNativeStackFamily ref testConfig
    Text.any (\character -> character <= '\x1f' || character == '\x7f') evidence
      `shouldBe` False
    validateProviderIntentEvidence intent evidence `shouldBe` Right evidence
    -- An empty family states its absence rather than implying it from a header
    -- with no rows after it, which the superseded form could not distinguish
    -- from a listing truncated mid-stream.
    let absent = mustRight (encodeAwsNativeStackFamilyEvidence ref [])
    validateProviderIntentEvidence intent absent `shouldBe` Right absent

-- | The reaper over a world in which nothing waits: a case that never polls
-- does not read the clock, and a case that does builds its own world.
reapNative
  :: AwsNativeStackFamilyRunner IO
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> IO (Either Text ())
reapNative runner ref config = do
  world <- newVirtualWorld
  Native.reapAwsNativeStackFamily runner (roomyWaitEnvironment world) ref config

reapWithin
  :: AwsNativeStackFamilyRunner IO
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> IO (Either Text ())
reapWithin runner ref config admitted = do
  world <- newVirtualWorld
  Native.reapAwsNativeStackFamilyWithin runner (roomyWaitEnvironment world) ref config admitted

second :: Natural
second = 1000000

elapsedSince :: VirtualWorld -> IO Natural
elapsedSince world = subtract virtualStartMicros <$> virtualNowMicros world

-- | How one EKS child leaves the account once it is deleted.
data EksChildScript = EksChildScript
  { childLeavesAfter :: Maybe Natural
  -- ^ Seconds after the delete is requested; 'Nothing' never leaves.
  , childStartsDeleting :: Bool
  -- ^ Already deleting when the reap begins, as after a wait that timed out.
  , childTerminalStatus :: Maybe String
  -- ^ A terminal status the child reports once deletion is requested.
  }

leavesAfter :: Natural -> EksChildScript
leavesAfter seconds = EksChildScript (Just seconds) False Nothing

neverLeaves :: EksChildScript
neverLeaves = EksChildScript Nothing False Nothing

data EksScripts = EksScripts
  { addonScript :: EksChildScript
  , nodeGroupScript :: EksChildScript
  , clusterScript :: EksChildScript
  , throttledNodeGroupPolls :: Int
  }

defaultEksScripts :: EksScripts
defaultEksScripts =
  EksScripts
    { addonScript = leavesAfter 120
    , nodeGroupScript = leavesAfter 300
    , clusterScript = leavesAfter 240
    , throttledNodeGroupPolls = 0
    }

-- | The cluster's OIDC issuer URL in the fixture region.
oidcIssuer :: String
oidcIssuer = "https://oidc.eks." <> Text.unpack region <> ".amazonaws.com/id/ABC"

-- | An EKS ARN in the fixture region and account.
eksArn :: String -> String
eksArn resource = "arn:aws:eks:" <> Text.unpack region <> ":123456789012:" <> resource

-- | A scripted EKS account. Each child is present until its deletion has been
-- requested and its script says it has left; the cluster cannot be deleted
-- while its node group is still there, as in the service.
--
-- The durations are exercised assumptions that drive the mechanism (the order,
-- the polls, the timeout), not recorded AWS behaviour, and they discharge no
-- gate about how long AWS takes; the budgets are tightened from recordings
-- (Unit Testing Policy § 5.1).
eksAccount
  :: VirtualWorld
  -> IORef [[String]]
  -> EksScripts
  -> IO (AwsNativeStackFamilyRunner IO)
eksAccount world calls scripts = do
  requests <- newIORef ([] :: [(String, Natural)])
  throttles <- newIORef (throttledNodeGroupPolls scripts)
  let stateOf kind script = do
        now <- virtualNowMicros world
        asked <- readIORef requests
        pure $ case (lookup kind asked, childStartsDeleting script) of
          (Nothing, False) -> Just "ACTIVE"
          (since, _) ->
            let began = maybe virtualStartMicros id since
             in case (childTerminalStatus script, childLeavesAfter script) of
                  (Just terminal, _) -> Just terminal
                  (Nothing, Just duration)
                    | now - began >= duration * second -> Nothing
                  _ -> Just "DELETING"
      describeChild kind script arn query = do
        state <- stateOf kind script
        pure $ case state of
          Nothing -> failure "An error occurred (ResourceNotFoundException) when calling the Describe operation"
          Just status
            | ".status" `isSuffixOf` query -> success (status <> "\n")
            | otherwise -> success arn
      request kind = do
        now <- virtualNowMicros world
        modifyIORef' requests ((kind, now) :)
        pure (success "{}")
  pure $
    AwsNativeStackFamilyRunner $ \arguments -> do
      modifyIORef' calls (<> [arguments])
      case arguments of
        "eks" : "describe-addon" : _ ->
          describeChild
            "addon"
            (addonScript scripts)
            (eksArn "addon/aws-ebs-csi-driver" <> "\n")
            (queryOf arguments)
        "eks" : "describe-nodegroup" : _ -> do
          throttling <- readIORef throttles
          asked <- readIORef requests
          let statusPoll = ".status" `isSuffixOf` queryOf arguments && lookup "nodegroup" asked /= Nothing
          if statusPoll && throttling > 0
            then do
              modifyIORef' throttles (subtract 1)
              pure
                (failure "An error occurred (Throttling) when calling the DescribeNodegroup operation: Rate exceeded")
            else
              describeChild
                "nodegroup"
                (nodeGroupScript scripts)
                (eksArn "nodegroup/aws-eks-test-node-group" <> "\n")
                (queryOf arguments)
        "eks" : "describe-cluster" : _ ->
          describeChild
            "cluster"
            (clusterScript scripts)
            (eksArn "cluster/aws-eks-test-cluster" <> " " <> oidcIssuer <> "\n")
            (queryOf arguments)
        "eks" : "delete-addon" : _ -> request "addon"
        "eks" : "delete-nodegroup" : _ -> request "nodegroup"
        "eks" : "delete-cluster" : _ -> do
          remaining <- stateOf "nodegroup" (nodeGroupScript scripts)
          case remaining of
            Nothing -> request "cluster"
            Just _ ->
              pure
                ( failure
                    "An error occurred (ResourceInUseException) when calling the DeleteCluster operation: cluster has nodegroups attached"
                )
        "resourcegroupstaggingapi" : _ -> pure (success emptyTaggedResourcePage)
        _
          | isNetworkListing arguments -> pure (success "[]")
          | otherwise -> pure (success "")

-- | A scripted aws-test account: its instances report shutting-down from the
-- terminate request until the given number of seconds later, then terminated;
-- 'Nothing' never terminates. Everything else is the usual aws-test answers.
instanceAccount
  :: VirtualWorld
  -> IORef [[String]]
  -> Maybe Natural
  -> IO (AwsNativeStackFamilyRunner IO)
instanceAccount world calls terminatesAfter = do
  terminatedAt <- newIORef Nothing
  pure $
    AwsNativeStackFamilyRunner $ \arguments -> do
      modifyIORef' calls (<> [arguments])
      now <- virtualNowMicros world
      case arguments of
        "ec2" : "terminate-instances" : _ -> do
          modifyIORef' terminatedAt (const (Just now))
          pure (success "{}")
        _
          | isInstanceStatePoll arguments -> do
              requested <- readIORef terminatedAt
              pure . success $ case (requested, terminatesAfter) of
                (Nothing, _) -> "running\trunning\trunning\n"
                (Just began, Just duration)
                  | now - began >= duration * second -> "terminated\tterminated\tterminated\n"
                _ -> "shutting-down\tshutting-down\tshutting-down\n"
          | otherwise -> pure (awsTestResponse arguments)

-- | Whether a command reads the instances' states.
isInstanceStatePoll :: [String] -> Bool
isInstanceStatePoll arguments =
  "describe-instances" `elem` arguments
    && queryOf arguments == "Reservations[].Instances[].State.Name"

-- | The commands that change the account, by AWS operation name.
mutationsOf :: [[String]] -> [String]
mutationsOf commands =
  [ operation
  | command <- commands
  , operation <- take 1 (filter (`elem` mutationOperations) command)
  ]
 where
  mutationOperations =
    [ "delete-addon"
    , "delete-nodegroup"
    , "delete-open-id-connect-provider"
    , "delete-cluster"
    ]

-- | How many times a command asked for the given status query.
statusPolls :: String -> [[String]] -> Int
statusPolls query commands = length [() | command <- commands, queryOf command == query]

-- | Whether the first position is known and strictly before the second.
isBefore :: Maybe Int -> Maybe Int -> Bool
isBefore later earlier = case (earlier, later) of
  (Just before, Just after) -> before < after
  _ -> False

-- | The index of the last command that read the instances' states.
lastIndexOfStatePoll :: [[String]] -> Int
lastIndexOfStatePoll commands =
  maximum (-1 : [index | (index, command) <- zip [0 ..] commands, isInstanceStatePoll command])

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
        "Vpcs[].VpcId" -> "vpc-0a1b2c3d4e5f60718\n"
        "InternetGateways[].InternetGatewayId" -> "igw-1\n"
        "RouteTables[].RouteTableId" -> "rtb-1\n"
        "RouteTables[].Associations[].RouteTableAssociationId" ->
          "rtbassoc-1\trtbassoc-2\trtbassoc-3\n"
        "Subnets[].SubnetId" -> namedId "subnet" arguments
        "SecurityGroups[].GroupId" -> "sg-1\n"
        "Reservations[].Instances[].InstanceId" -> namedId "instance" arguments
        _ -> ""
  | isNetworkListing arguments = success "[]"
  | otherwise = success "{}"

-- | The listings of the interfaces and groups in the stack's VPC, which the
-- reaper reads before it deletes a subnet. Nothing is there.
isNetworkListing :: [String] -> Bool
isNetworkListing arguments =
  "json" `elem` arguments
    && any (`elem` arguments) ["describe-network-interfaces", "describe-security-groups"]

subzoneResponse :: [String] -> ProcessOutput
subzoneResponse = subzoneResponseHolding "[]"

-- | The subzone family's responses, with the given JSON listing of the records the
-- zone holds beside its SOA and NS.
subzoneResponseHolding :: String -> [String] -> ProcessOutput
subzoneResponseHolding leftoverRecords arguments
  | "get-hosted-zone" `elem` arguments =
      success "/hostedzone/ZSUBZONE123\tAWS.EXAMPLE.TEST.\n"
  | arguments == pruneListingArguments = success leftoverRecords
  | "list-resource-record-sets" `elem` arguments
  , "json" `elem` arguments =
      success
        "{\"ResourceRecordSets\":[{\"Name\":\"aws.example.test.\",\"Type\":\"NS\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"ns-1.example.\"}]}]}"
  | "list-resource-record-sets" `elem` arguments =
      success "aws.example.test.\tNS\n"
  | otherwise = success "{}"

-- | The one listing the prune is allowed to make: the zone it goes on to delete, as
-- JSON, through the filter that keeps the zone's own SOA and NS. The fake answers
-- this exact call with the leftover records and every other listing with something
-- the prune refuses, so a prune that listed another zone, asked for another format
-- or dropped the filter fails a case instead of passing against a forgiving fake.
pruneListingArguments :: [String]
pruneListingArguments =
  [ "route53"
  , "list-resource-record-sets"
  , "--hosted-zone-id"
  , "ZSUBZONE123"
  , "--query"
  , "ResourceRecordSets[?Type != 'SOA' && Type != 'NS']"
  , "--output"
  , "json"
  ]

-- | What a leftover zone holds beside its SOA and NS: a plain A record, a TXT
-- challenge with a quoted value, and an alias, each as the listing prints it.
leftoverRecordsJson :: String
leftoverRecordsJson =
  "[{\"Name\":\"edge.aws.example.test.\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"192.0.2.10\"}]},"
    <> "{\"Name\":\"_acme-challenge.aws.example.test.\",\"Type\":\"TXT\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"\\\"token-a\\\"\"}]},"
    <> "{\"Name\":\"alias.aws.example.test.\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"ZALIASFIXTURE\",\"DNSName\":\"lb.example.test.\",\"EvaluateTargetHealth\":false}}]"

-- | The change batch the prune must send for those records: one DELETE per record,
-- each carrying the record whole.
expectedDeleteBatch :: [Value] -> Value
expectedDeleteBatch records =
  object
    [ "Comment" .= ("prodbox exact native stack-family cleanup" :: Text)
    , "Changes"
        .= [ object ["Action" .= ("DELETE" :: Text), "ResourceRecordSet" .= record]
           | record <- records
           ]
    ]

-- | Whether a command is a record change against the given hosted zone.
isChangeFor :: String -> [String] -> Bool
isChangeFor zoneId command = "change-resource-record-sets" `elem` command && zoneId `elem` command

-- | The change batch a command carries.
changeBatchOf :: [String] -> [String]
changeBatchOf command =
  [batch | (flag, batch) <- zip command (drop 1 command), flag == "--change-batch"]

-- | The single change batch decoded, or why there is not exactly one.
soleBatch :: [String] -> Either String Value
soleBatch batches = case batches of
  [batch] -> eitherDecodeStrict (TextEncoding.encodeUtf8 (Text.pack batch))
  _ -> Left "expected exactly one zone-level change batch"

-- | Three steps that all happened, in ascending order.
inOrder :: (Maybe Int, Maybe Int, Maybe Int) -> Bool
inOrder (Just earlier, Just middle, Just later) = earlier < middle && middle < later
inOrder _ = False

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
    "vpc/vpc-0a1b2c3d4e5f60718" `elem` identities
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
