{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.109: a wait is a loop of short polls under a named budget.
--
-- Every @aws@ child the Provider starts is stopped at thirty seconds, so the
-- waits it used to ask of one child (@aws eks wait cluster-deleted@, and the
-- security-group delete's ten attempts one second apart) could not finish what
-- the service takes minutes to do. These cases run the replacement over a
-- scripted world with a virtual clock: each poll returns when the awaited fact
-- becomes true, ends in a typed timeout at its budget that names the fact, and
-- never starts a poll after its deadline. The old shape is kept as a negative
-- control and fails the assertion the new one meets.
--
-- The world is exported for the interpreters that wait: the native-family
-- reaper, the retained-volume ensure and the load balancer's security groups.
module AwsWaitPolling
  ( awsWaitPollingSuite
  , VirtualWorld
  , newVirtualWorld
  , virtualStartMicros
  , virtualNowMicros
  , advanceVirtualClock
  , pausesTaken
  , roomyWaitEnvironment
  , virtualWaitEnvironment
  )
where

import Control.Monad (when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.ControlPlane.OperationBudget
  ( WaitFact (..)
  , awsCliChildBoundMicros
  , sessionGraceSeconds
  , waitBudgetFor
  , waitBudgetPollIntervalMicros
  , waitCeilingMicros
  )
import Prodbox.Lifecycle.AwsWait
import Prodbox.Subprocess (ProcessOutput (..), boundedSubprocessTimeoutDetail)
import System.Exit (ExitCode (..))
import TestSupport

-- | A virtual clock and the pauses taken on it.
data VirtualWorld = VirtualWorld
  { worldNow :: IORef Natural
  , worldPauses :: IORef [Natural]
  }

second, minute, hour :: Natural
second = 1000000
minute = 60 * second
hour = 60 * minute

-- | The instant every world starts at.
virtualStartMicros :: Natural
virtualStartMicros = 1000 * second

newVirtualWorld :: IO VirtualWorld
newVirtualWorld = VirtualWorld <$> newIORef virtualStartMicros <*> newIORef []

virtualNowMicros :: VirtualWorld -> IO Natural
virtualNowMicros = readIORef . worldNow

advanceVirtualClock :: VirtualWorld -> Natural -> IO ()
advanceVirtualClock world micros = modifyIORef' (worldNow world) (+ micros)

pausesTaken :: VirtualWorld -> IO [Natural]
pausesTaken = readIORef . worldPauses

-- | A wait environment over the world whose session expires at the given
-- instant: pausing moves the virtual clock and is recorded.
virtualWaitEnvironment :: VirtualWorld -> Natural -> AwsWaitEnvironment IO
virtualWaitEnvironment world expiresAt =
  AwsWaitEnvironment
    { awsWaitNowMicros = Right <$> virtualNowMicros world
    , awsWaitPauseMicros = \micros -> do
        -- A pause of nothing would let a loop spin on a clock that never moves.
        when (micros == 0) (expectationFailure "a wait paused for zero microseconds")
        advanceVirtualClock world micros
        modifyIORef' (worldPauses world) (++ [micros])
    , awsWaitSessionExpiresAtMicros = expiresAt
    , awsWaitIntentLifetimeMicros = providerWorkerIntentLifetimeMicros
    }

-- | A session with more window than any budget needs.
roomyWaitEnvironment :: VirtualWorld -> AwsWaitEnvironment IO
roomyWaitEnvironment world = virtualWaitEnvironment world (virtualStartMicros + 2 * hour)

elapsedSince :: VirtualWorld -> IO Natural
elapsedSince world = subtract virtualStartMicros <$> virtualNowMicros world

failed :: String -> ProcessOutput
failed stderr = ProcessOutput (ExitFailure 254) "" stderr

awsWaitPollingSuite :: SuiteBuilder ()
awsWaitPollingSuite =
  describe "Sprint 4.109 waits are budgeted polls over a scripted world" $ do
    it "returns at the first poll that sees the fact, without pausing" $ do
      world <- newVirtualWorld
      result <- awaitFact (roomyWaitEnvironment world) NodeGroupAbsent (pure WaitDone)
      result `shouldBe` Right ()
      pausesTaken world `shouldReturn` []

    it "polls at the budget's interval and stops at the poll that sees the fact" $ do
      world <- newVirtualWorld
      polls <- newIORef (0 :: Int)
      let becomesTrueAfter = 5 * minute
          poll = do
            modifyIORef' polls (+ 1)
            elapsed <- elapsedSince world
            pure
              ( if elapsed >= becomesTrueAfter
                  then WaitDone
                  else WaitMore () "node group status DELETING"
              )
      result <- awaitFact (roomyWaitEnvironment world) NodeGroupAbsent poll
      result `shouldBe` Right ()
      -- A fifteen second interval from zero to five minutes is twenty-one polls.
      readIORef polls `shouldReturn` 21
      elapsedSince world `shouldReturn` becomesTrueAfter
      pauses <- pausesTaken world
      pauses `shouldBe` replicate 20 (waitBudgetPollIntervalMicros (waitBudgetFor NodeGroupAbsent))

    it "ends in a typed timeout that names the fact when the budget is spent" $ do
      world <- newVirtualWorld
      let budget = waitBudgetFor ClusterAbsent
          ceiling' = waitCeilingMicros providerWorkerIntentLifetimeMicros budget
      result <-
        awaitFact
          (roomyWaitEnvironment world)
          ClusterAbsent
          (pure (WaitMore () "cluster status DELETING"))
      -- Nine minutes of fifteen second polls: the first at zero and the last at the deadline.
      ceiling' `shouldBe` (9 * minute)
      result `shouldBe` Left (WaitTimedOut ClusterAbsent 37 ceiling' ceiling' "cluster status DELETING")
      elapsedSince world `shouldReturn` ceiling'
      either renderWaitFailure (const "") result
        `shouldSatisfy` Text.isInfixOf "EKS cluster absent"
      either renderWaitFailure (const "") result
        `shouldSatisfy` Text.isPrefixOf "WaitTimedOut:"

    it "never starts a poll after the deadline, and overruns it by at most one child" $ do
      world <- newVirtualWorld
      starts <- newIORef []
      let latency = 7 * second
          poll = do
            now <- virtualNowMicros world
            modifyIORef' starts (now :)
            advanceVirtualClock world latency
            pure (WaitMore () "instances still running")
          ceiling' =
            waitCeilingMicros providerWorkerIntentLifetimeMicros (waitBudgetFor InstancesTerminated)
      _ <- awaitFact (roomyWaitEnvironment world) InstancesTerminated poll
      begun <- reverse <$> readIORef starts
      all (<= virtualStartMicros + ceiling') begun `shouldBe` True
      elapsedSince world >>= \elapsed ->
        (elapsed <= ceiling' + awsCliChildBoundMicros) `shouldBe` True

    it "stops at the session window when it is nearer than the ceiling" $ do
      world <- newVirtualWorld
      -- The read-back grace is reserved first: 400 seconds of session leave 100 usable.
      let expires = virtualStartMicros + (sessionGraceSeconds + 100) * second
      result <-
        awaitFact
          (virtualWaitEnvironment world expires)
          NodeGroupAbsent
          (pure (WaitMore () "node group status DELETING"))
      result
        `shouldBe` Left (WaitTimedOut NodeGroupAbsent 8 (100 * second) (100 * second) "node group status DELETING")
      elapsedSince world `shouldReturn` (100 * second)

    it "starts no poll in a session with nothing usable left" $ do
      world <- newVirtualWorld
      polls <- newIORef (0 :: Int)
      let expires = virtualStartMicros + sessionGraceSeconds * second
      result <-
        awaitFact
          (virtualWaitEnvironment world expires)
          NodeGroupAbsent
          (modifyIORef' polls (+ 1) >> pure WaitDone)
      result `shouldSatisfy` isUnavailable
      either renderWaitFailure (const "") result
        `shouldSatisfy` Text.isInfixOf "SessionWindowExceeded"
      readIORef polls `shouldReturn` 0

    it "refuses to poll when the clock cannot be read, rather than polling with no deadline" $ do
      world <- newVirtualWorld
      polls <- newIORef (0 :: Int)
      let environment =
            (roomyWaitEnvironment world) {awsWaitNowMicros = pure (Left "authority clock unavailable")}
      result <- awaitFact environment ClusterAbsent (modifyIORef' polls (+ 1) >> pure WaitDone)
      result `shouldBe` Left (WaitUnavailable ClusterAbsent "authority clock unavailable")
      readIORef polls `shouldReturn` 0

    it "stops at once when a poll says waiting cannot help" $ do
      world <- newVirtualWorld
      result <-
        awaitFact
          (roomyWaitEnvironment world)
          NodeGroupAbsent
          (pure (WaitAbort "EKS node group reported status DELETE_FAILED"))
      result
        `shouldBe` Left (WaitAborted NodeGroupAbsent "EKS node group reported status DELETE_FAILED")
      pausesTaken world `shouldReturn` []

    it "threads state through the polls, so a wait on several members polls only those outstanding" $ do
      world <- newVirtualWorld
      seen <- newIORef []
      let step outstanding = do
            modifyIORef' seen (outstanding :)
            pure $ case outstanding of
              [_] -> WaitDone
              _ : rest -> WaitMore rest "a group is still held"
              [] -> WaitDone
      result <-
        awaitFactFrom
          (roomyWaitEnvironment world)
          SecurityGroupDeletable
          ["sg-a", "sg-b", "sg-c" :: Text]
          step
      result `shouldBe` Right ()
      readIORef seen
        >>= (`shouldBe` [["sg-c"], ["sg-b", "sg-c"], ["sg-a", "sg-b", "sg-c"]])

    it "treats throttling, an unavailable service and a stopped child as not yet, and a denial as final" $ do
      mapM_
        (\detail -> transientPollFailure (failed detail) `shouldBe` True)
        [ "An error occurred (Throttling) when calling the DescribeCluster operation: Rate exceeded"
        , "An error occurred (RequestLimitExceeded) when calling the DescribeInstances operation"
        , "An error occurred (ServiceUnavailable) when calling the DescribeVolumes operation"
        , -- EC2 spells its own as Unavailable, and the CLI words a connection it
          -- could not make or finish for itself.
          "An error occurred (Unavailable) when calling the DeleteSecurityGroup operation: try again"
        , "Could not connect to the endpoint URL: \"https://ec2.example.amazonaws.com/\""
        , "Connect timeout on endpoint URL: \"https://ec2.example.amazonaws.com/\""
        , "Connection was closed before we received a valid response from endpoint URL: \"https://ec2.example.amazonaws.com/\""
        , boundedSubprocessTimeoutDetail
        ]
      mapM_
        (\detail -> transientPollFailure (failed detail) `shouldBe` False)
        [ "An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation"
        , "An error occurred (InvalidParameterValue) when calling the DescribeVolumes operation"
        ]

    describe "negative control: the shape this replaced" $ do
      let factAfter = 5 * minute
          -- One child stopped at the bound the Provider enforces on every aws child.
          legacyChildWaiter becomesTrueAfter = pure (becomesTrueAfter <= awsCliChildBoundMicros)
          -- Ten attempts one second apart: nine pauses.
          legacyRetryWaiter becomesTrueAfter = pure (becomesTrueAfter <= 9 * second)
          budgetedWaiter becomesTrueAfter = do
            world <- newVirtualWorld
            let poll = do
                  elapsed <- elapsedSince world
                  pure (if elapsed >= becomesTrueAfter then WaitDone else WaitMore () "not yet")
            (== Right ()) <$> awaitFact (roomyWaitEnvironment world) SecurityGroupDeletable poll

      it "cannot reach a fact that is minutes away, and the budgeted poll does" $ do
        legacyChildWaiter factAfter `shouldReturn` False
        legacyRetryWaiter factAfter `shouldReturn` False
        budgetedWaiter factAfter `shouldReturn` True

      it "agrees with the budgeted poll when the fact is seconds away, so the control is not vacuous" $ do
        legacyChildWaiter (5 * second) `shouldReturn` True
        legacyRetryWaiter (5 * second) `shouldReturn` True
        budgetedWaiter (5 * second) `shouldReturn` True

isUnavailable :: Either WaitFailure () -> Bool
isUnavailable result = case result of
  Left (WaitUnavailable _ _) -> True
  _ -> False
