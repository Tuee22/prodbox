{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.109: the destroy interpreter takes its runner and its clock as
-- arguments, so its children and its waits run over a scripted world.
--
-- Before it, @runPulumiMutation@, @runAws@ and the load balancer's
-- security-group delete were concrete @IO@, and the only test that reached them
-- was a pin on the source text. The security groups a controller-made load
-- balancer held could not be deleted until its interfaces released, which is
-- reported to take minutes; the retry that answered it covered ten seconds.
module ProviderDestroyInterpreter (providerDestroyInterpreterSuite) where

import AwsWaitPolling
  ( VirtualWorld
  , advanceVirtualClock
  , newVirtualWorld
  , pausesTaken
  , roomyWaitEnvironment
  , virtualNowMicros
  , virtualStartMicros
  )
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ProviderProduction
  ( deleteSecurityGroupsWithin
  , pulumiDestroySelected
  )
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment (..))
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

second :: Natural
second = 1000000

elapsedSince :: VirtualWorld -> IO Natural
elapsedSince world = subtract virtualStartMicros <$> virtualNowMicros world

ok :: String -> ProcessOutput
ok stdout = ProcessOutput ExitSuccess stdout ""

refusedWith :: String -> ProcessOutput
refusedWith stderr = ProcessOutput (ExitFailure 254) "" stderr

dependencyViolation :: ProcessOutput
dependencyViolation =
  refusedWith
    "An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation: resource sg-0a1b2c3d4e5f60718 has a dependent object"

-- | Which security group a delete names.
groupOf :: [String] -> String
groupOf arguments = case dropWhile (/= "--group-id") arguments of
  _ : group : _ -> group
  _ -> ""

-- | The shape this replaced: ten attempts one second apart, whatever the
-- service answers. Kept as a test-only negative control.
legacyTenAttempts
  :: VirtualWorld -> ([String] -> IO ProcessOutput) -> [String] -> IO Bool
legacyTenAttempts world run groups = go (10 :: Int)
 where
  go remaining = do
    deleted <- traverse attemptOne groups
    if and deleted
      then pure True
      else
        if remaining <= 1
          then pure False
          else advanceVirtualClock world second >> go (remaining - 1)
  attemptOne group =
    (== ExitSuccess) . processExitCode
      <$> run ["ec2", "delete-security-group", "--group-id", group]

-- | A service whose interfaces release the given number of seconds after the
-- world began.
releasingAfter :: VirtualWorld -> Natural -> [String] -> IO ProcessOutput
releasingAfter world seconds _ = do
  now <- virtualNowMicros world
  pure (if now - virtualStartMicros < seconds * second then dependencyViolation else ok "")

providerDestroyInterpreterSuite :: SuiteBuilder ()
providerDestroyInterpreterSuite =
  describe "Sprint 4.109 the destroy interpreter runs over a scripted world" $ do
    describe "the load balancer's security groups" $ do
      it "deletes each group as its interfaces release, polling only those still outstanding" $ do
        world <- newVirtualWorld
        calls <- newIORef []
        let run arguments = do
              modifyIORef' calls (<> [groupOf arguments])
              now <- virtualNowMicros world
              pure $ case groupOf arguments of
                "sg-held"
                  | now - virtualStartMicros < 90 * second -> dependencyViolation
                _ -> ok ""
        result <- deleteSecurityGroupsWithin run (roomyWaitEnvironment world) ["sg-free", "sg-held"]
        result `shouldBe` Right ()
        recorded <- readIORef calls
        -- The first round deletes both; the free group is not asked again.
        take 2 recorded `shouldBe` ["sg-free", "sg-held"]
        length (filter (== "sg-free") recorded) `shouldBe` 1
        -- Ten second polls from zero to ninety seconds.
        length (filter (== "sg-held") recorded) `shouldBe` 10
        elapsedSince world `shouldReturn` (90 * second)

      it "finds a group that is already gone deleted" $ do
        world <- newVirtualWorld
        let run _ =
              pure
                ( refusedWith
                    "An error occurred (InvalidGroup.NotFound) when calling the DeleteSecurityGroup operation"
                )
        deleteSecurityGroupsWithin run (roomyWaitEnvironment world) ["sg-gone"]
          `shouldReturn` Right ()

      it "ends in a typed timeout naming the fact when the interfaces never release" $ do
        world <- newVirtualWorld
        calls <- newIORef (0 :: Int)
        let run _ = modifyIORef' calls (+ 1) >> pure dependencyViolation
        result <- deleteSecurityGroupsWithin run (roomyWaitEnvironment world) ["sg-held"]
        result `shouldSatisfy` either (Text.isPrefixOf "WaitTimedOut:") (const False)
        result `shouldSatisfy` either (Text.isInfixOf "security group deletable") (const False)
        result `shouldSatisfy` either (Text.isInfixOf "DependencyViolation") (const False)
        -- Nine minutes of ten second polls: the first at zero and the last at the deadline.
        readIORef calls `shouldReturn` 55
        elapsedSince world `shouldReturn` (540 * second)

      it "ends the wait at once on a refusal that waiting cannot change" $ do
        world <- newVirtualWorld
        calls <- newIORef (0 :: Int)
        let run _ =
              modifyIORef' calls (+ 1)
                >> pure
                  ( refusedWith
                      "An error occurred (UnauthorizedOperation) when calling the DeleteSecurityGroup operation"
                  )
        result <- deleteSecurityGroupsWithin run (roomyWaitEnvironment world) ["sg-a"]
        result `shouldSatisfy` either (Text.isPrefixOf "WaitAborted:") (const False)
        result `shouldSatisfy` either (Text.isInfixOf "UnauthorizedOperation") (const False)
        readIORef calls `shouldReturn` 1

      it "polls again after a throttled call" $ do
        world <- newVirtualWorld
        calls <- newIORef (0 :: Int)
        let run _ = do
              modifyIORef' calls (+ 1)
              count <- readIORef calls
              pure
                ( if count < 3
                    then
                      refusedWith
                        "An error occurred (Throttling) when calling the DeleteSecurityGroup operation: Rate exceeded"
                    else ok ""
                )
        deleteSecurityGroupsWithin run (roomyWaitEnvironment world) ["sg-a"] `shouldReturn` Right ()
        readIORef calls `shouldReturn` 3

      it "reads no clock when there is nothing to delete" $ do
        world <- newVirtualWorld
        let environment = (roomyWaitEnvironment world) {awsWaitNowMicros = pure (Left "no clock")}
        deleteSecurityGroupsWithin (const (pure (ok ""))) environment [] `shouldReturn` Right ()

      it "makes one attempt when the session has no window left to wait in" $ do
        world <- newVirtualWorld
        calls <- newIORef (0 :: Int)
        let run _ = modifyIORef' calls (+ 1) >> pure (ok "")
            exhausted = (roomyWaitEnvironment world) {awsWaitSessionExpiresAtMicros = virtualStartMicros}
        deleteSecurityGroupsWithin run exhausted ["sg-free"] `shouldReturn` Right ()
        readIORef calls `shouldReturn` 1

      it "says the group is still held after its one attempt, and waits no longer" $ do
        world <- newVirtualWorld
        calls <- newIORef (0 :: Int)
        let run _ = modifyIORef' calls (+ 1) >> pure dependencyViolation
            exhausted = (roomyWaitEnvironment world) {awsWaitSessionExpiresAtMicros = virtualStartMicros}
        result <- deleteSecurityGroupsWithin run exhausted ["sg-held"]
        result `shouldSatisfy` either (Text.isInfixOf "one attempt") (const False)
        readIORef calls `shouldReturn` 1
        pausesTaken world `shouldReturn` []

      describe "negative control: the shape this replaced" $ do
        it "gives up while the interfaces are still attached, and the budgeted wait does not" $ do
          legacyWorld <- newVirtualWorld
          legacyDeleted <- legacyTenAttempts legacyWorld (releasingAfter legacyWorld 90) ["sg-held"]
          legacyDeleted `shouldBe` False
          budgetedWorld <- newVirtualWorld
          budgeted <-
            deleteSecurityGroupsWithin
              (releasingAfter budgetedWorld 90)
              (roomyWaitEnvironment budgetedWorld)
              ["sg-held"]
          budgeted `shouldBe` Right ()

        it "agrees with the budgeted wait when the interfaces release within seconds" $ do
          legacyWorld <- newVirtualWorld
          legacyDeleted <- legacyTenAttempts legacyWorld (releasingAfter legacyWorld 5) ["sg-held"]
          legacyDeleted `shouldBe` True
          budgetedWorld <- newVirtualWorld
          deleteSecurityGroupsWithin
            (releasingAfter budgetedWorld 5)
            (roomyWaitEnvironment budgetedWorld)
            ["sg-held"]
            `shouldReturn` Right ()

    describe "the Pulumi destroy" $ do
      let scripted answer = do
            calls <- newIORef []
            let run arguments = modifyIORef' calls (<> [arguments]) >> pure (answer arguments)
            pure (run, calls)
          commandOf = take 1

      it "removes the stack only after a destroy that exited cleanly" $ do
        (run, calls) <- scripted (const (ok ""))
        pulumiDestroySelected run "aws-eks-test" `shouldReturn` Right ()
        recorded <- readIORef calls
        map commandOf recorded `shouldBe` [["stack"], ["destroy"], ["stack"]]
        map (take 2) recorded `shouldBe` [["stack", "select"], ["destroy", "--stack"], ["stack", "rm"]]
        -- The destroy refreshes first and does not stop at the first resource it
        -- cannot delete; the exit status is then the only partial-failure signal.
        recorded !! 1 `shouldSatisfy` elem "--refresh"
        recorded !! 1 `shouldSatisfy` elem "--continue-on-error"

      it "finds a stack that is not there already destroyed" $ do
        (run, calls) <- scripted (const (refusedWith "error: no stack named 'aws-eks-test' found"))
        pulumiDestroySelected run "aws-eks-test" `shouldReturn` Right ()
        (length <$> readIORef calls) `shouldReturn` 1

      it "keeps the stack's record when the destroy failed" $ do
        (run, calls) <-
          scripted
            ( \arguments ->
                if take 1 arguments == ["destroy"]
                  then refusedWith "error: update failed: DependencyViolation on sg-0a1b2c3d4e5f60718"
                  else ok ""
            )
        result <- pulumiDestroySelected run "aws-eks-test"
        result `shouldSatisfy` either (isInfixOf' "DependencyViolation") (const False)
        recorded <- readIORef calls
        map commandOf recorded `shouldBe` [["stack"], ["destroy"]]

      it "treats a destroy stopped at its bound as a failure and removes nothing" $ do
        (run, calls) <-
          scripted
            ( \arguments ->
                if take 1 arguments == ["destroy"]
                  then
                    ProcessOutput
                      (ExitFailure 124)
                      "deleting ...\n[child-timeout] pulumi was stopped after 1680 seconds"
                      ""
                  else ok ""
            )
        result <- pulumiDestroySelected run "aws-eks-test"
        result `shouldSatisfy` either (isInfixOf' "ChildTimedOut") (const False)
        recorded <- readIORef calls
        map commandOf recorded `shouldBe` [["stack"], ["destroy"]]

      it "stops at the first child that fails" $ do
        (run, calls) <- scripted (const (refusedWith "error: could not read the backend"))
        result <- pulumiDestroySelected run "aws-eks-test"
        result `shouldSatisfy` either (isInfixOf' "backend") (const False)
        (length <$> readIORef calls) `shouldReturn` 1
 where
  isInfixOf' needle haystack = Text.isInfixOf needle (Text.pack haystack)
