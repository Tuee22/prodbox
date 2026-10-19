{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.52: the retained-EBS ensure's order, its waits, and what it says
-- when it fails, over scripted effects.
--
-- EC2 describe calls are eventually consistent, so an apply that created a
-- volume can fail to find it a moment later. The ensure therefore waits for what
-- it created, reads back until the listing is stable, polls the volumes' state
-- (Sprint 4.109: a loop of short describes under a budget, no longer an
-- @aws ec2 wait@ child the Provider stops at thirty seconds) while the API says
-- only that they are not available yet, and names the volumes it created in
-- every failure after the first create, because a create is not idempotent and a
-- rerun that reads "never created" creates them again. None of that needs an AWS
-- account: the effects are a record, and the cases below script it.
module EbsEnsure (ebsEnsureSuite) where

import AwsWaitPolling
  ( newVirtualWorld
  , roomyWaitEnvironment
  , virtualNowMicros
  , virtualStartMicros
  )
import Data.Either (fromLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderNarrowSession (ProviderEffectObservation (..))
import Prodbox.ControlPlane.ProviderProduction qualified as ProviderProduction
import Prodbox.Lib.Storage (StaticEbsVolumeBinding (..))
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Result (Result (..))
import Prodbox.Subprocess (ProcessOutput (..), boundedSubprocessTimeoutDetail)
import System.Exit (ExitCode (..))
import TestSupport

-- | The availability zone every fixture volume lives in.
fixtureZone :: String
fixtureZone = fixtureAwsRegion FixtureCaCentral1 <> "a"

requiredVolume :: String -> EbsVolume.EbsRequiredVolume
requiredVolume name = EbsVolume.EbsRequiredVolume name 1 fixtureZone

-- | A listed volume, tagged for the persistent volume it backs, of exactly the
-- size 'requiredVolume' asks for.
listedVolume :: String -> String -> EbsVolume.EbsVolume
listedVolume = listedVolumeOfSize 1

-- | A listed volume of a given size in GiB.
listedVolumeOfSize :: Int -> String -> String -> EbsVolume.EbsVolume
listedVolumeOfSize sizeGiB identifier persistentVolume =
  EbsVolume.EbsVolume
    { EbsVolume.ebsVolumeId = EbsVolume.EbsVolumeId identifier
    , EbsVolume.ebsVolumeState = "available"
    , EbsVolume.ebsVolumeTags = [(EbsVolume.ebsPersistentVolumeTagKey, persistentVolume)]
    , EbsVolume.ebsVolumeAvailabilityZone = Just fixtureZone
    , EbsVolume.ebsVolumeSizeGiB = Just sizeGiB
    }

-- | A required volume of a given size in GiB.
requiredVolumeOfSize :: Int -> String -> EbsVolume.EbsRequiredVolume
requiredVolumeOfSize sizeGiB name = EbsVolume.EbsRequiredVolume name sizeGiB fixtureZone

-- | Answers popped one per call; the last one answers every call after it.
popping :: IORef [answer] -> answer -> IO answer
popping remaining fallback = do
  next <- readIORef remaining
  case next of
    [only] -> pure only
    answer : rest -> writeIORef remaining rest >> pure answer
    [] -> pure fallback

-- | Answers popped one per call, then a fixed answer once they run out.
poppingThenExhausted :: IORef [answer] -> answer -> IO answer
poppingThenExhausted remaining exhausted = do
  next <- readIORef remaining
  case next of
    answer : rest -> writeIORef remaining rest >> pure answer
    [] -> pure exhausted

-- | What one scripted ensure did, in the order it did it.
data Trace = Trace
  { traceReads :: IORef Int
  , tracePauses :: IORef Int
  , traceCreated :: IORef [String]
  , traceWaited :: IORef [[String]]
  }

newTrace :: IO Trace
newTrace = Trace <$> newIORef 0 <*> newIORef 0 <*> newIORef [] <*> newIORef []

-- | Effects that answer each listing from a script, create under a given name
-- table, and wait with a given answer.
scriptedEffects
  :: Trace
  -> [Either String [EbsVolume.EbsVolume]]
  -> (EbsVolume.EbsRequiredVolume -> Either String EbsVolume.EbsVolumeId)
  -> Either String ()
  -> IO (EbsVolume.EbsEnsureEffects IO)
scriptedEffects trace listings createAnswer waitAnswer = do
  remaining <- newIORef listings
  pure
    EbsVolume.EbsEnsureEffects
      { EbsVolume.ebsEffectDiscover = do
          modifyIORef' (traceReads trace) (+ 1)
          popping remaining (Right [])
      , EbsVolume.ebsEffectCreate = \volume -> do
          modifyIORef' (traceCreated trace) (++ [EbsVolume.ebsRequiredPersistentVolumeName volume])
          pure (createAnswer volume)
      , EbsVolume.ebsEffectWaitAvailable = \identifiers -> do
          modifyIORef' (traceWaited trace) (++ [map EbsVolume.unEbsVolumeId identifiers])
          pure waitAnswer
      , EbsVolume.ebsEffectPause = modifyIORef' (tracePauses trace) (+ 1)
      }

-- | A create that always succeeds, naming each volume after the persistent
-- volume it backs.
createsByName :: EbsVolume.EbsRequiredVolume -> Either String EbsVolume.EbsVolumeId
createsByName volume =
  Right (EbsVolume.EbsVolumeId ("vol-" <> EbsVolume.ebsRequiredPersistentVolumeName volume))

counts :: Trace -> IO (Int, Int)
counts trace = (,) <$> readIORef (traceReads trace) <*> readIORef (tracePauses trace)

failureText :: Either String value -> String
failureText = fromLeft ""

ebsEnsureSuite :: SuiteBuilder ()
ebsEnsureSuite =
  describe "Sprint 5.52 retained-EBS ensure waits for what it created and says what it created" $ do
    it "waits, bounded, for a volume it just created to be listed on consecutive reads" $ do
      let required = [requiredVolume "pv-a"]
          tagged = listedVolume "vol-0aaa" "pv-a"
          scripted answers = do
            remaining <- newIORef answers
            reads' <- newIORef (0 :: Int)
            pauses <- newIORef (0 :: Int)
            let discover = modifyIORef' reads' (+ 1) >> poppingThenExhausted remaining (Right [])
            pure (discover, modifyIORef' pauses (+ 1), reads', pauses)
          stable = EbsVolume.retainedEbsVisibilityStableReads
      -- The production setting asks for two consecutive complete reads.
      stable `shouldBe` 2
      -- Not listed on the first two reads, listed on the third and again on the
      -- fourth: three pauses, four reads.
      (discover, pause, reads', pauses) <- scripted [Right [], Right [], Right [tagged], Right [tagged]]
      EbsVolume.awaitRequiredVolumesVisible discover pause required 12 stable
        `shouldReturn` Right [tagged]
      ((,) <$> readIORef reads' <*> readIORef pauses) `shouldReturn` (4, 3)
      -- A complete read followed by an incomplete one starts the count over: the
      -- replica that answered "complete" was ahead of the one that answered next.
      (discoverFlip, pauseFlip, readsFlip, pausesFlip) <-
        scripted [Right [tagged], Right [], Right [tagged], Right [tagged]]
      EbsVolume.awaitRequiredVolumesVisible discoverFlip pauseFlip required 12 stable
        `shouldReturn` Right [tagged]
      ((,) <$> readIORef readsFlip <*> readIORef pausesFlip) `shouldReturn` (4, 3)
      -- One consecutive read is the old behaviour: the first complete listing ends it.
      (discoverOne, pauseOne, readsOne, pausesOne) <- scripted [Right [], Right [], Right [tagged]]
      EbsVolume.awaitRequiredVolumesVisible discoverOne pauseOne required 12 1
        `shouldReturn` Right [tagged]
      ((,) <$> readIORef readsOne <*> readIORef pausesOne) `shouldReturn` (3, 2)
      -- A complete listing on the last attempt cannot be confirmed by a second read
      -- inside the budget, so it is returned as it stands.
      (discoverLast, pauseLast, readsLast, pausesLast) <- scripted [Right [], Right [tagged]]
      EbsVolume.awaitRequiredVolumesVisible discoverLast pauseLast required 2 stable
        `shouldReturn` Right [tagged]
      ((,) <$> readIORef readsLast <*> readIORef pausesLast) `shouldReturn` (2, 1)
      -- Never listed: the attempts are spent, and the last read is what the caller names.
      (discover2, pause2, reads2, pauses2) <- scripted []
      EbsVolume.awaitRequiredVolumesVisible discover2 pause2 required 4 stable
        `shouldReturn` Right []
      ((,) <$> readIORef reads2 <*> readIORef pauses2) `shouldReturn` (4, 3)
      -- A failed read is not evidence about visibility: it ends the wait at once.
      (discover3, pause3, reads3, pauses3) <- scripted [Left "Unable to locate credentials"]
      EbsVolume.awaitRequiredVolumesVisible discover3 pause3 required 12 stable
        `shouldReturn` Left "Unable to locate credentials"
      ((,) <$> readIORef reads3 <*> readIORef pauses3) `shouldReturn` (1, 0)
      -- An apply that created nothing reads once, whatever it asks for.
      (discover4, pause4, reads4, pauses4) <- scripted [Right [tagged]]
      EbsVolume.awaitRequiredVolumesVisible discover4 pause4 required 1 stable
        `shouldReturn` Right [tagged]
      ((,) <$> readIORef reads4 <*> readIORef pauses4) `shouldReturn` (1, 0)

    it "creates only what is missing, waits only for what it created, and binds every volume" $ do
      let required = [requiredVolume "pv-a", requiredVolume "pv-b"]
          listedA = listedVolume "vol-0a" "pv-a"
          listedB = listedVolume "vol-0b" "pv-b"
      -- Everything is already there: no create, no wait, no pause, and one read after
      -- the first listing.
      satisfied <- newTrace
      satisfiedEffects <-
        scriptedEffects satisfied [Right [listedA, listedB]] createsByName (Right ())
      EbsVolume.ensureRetainedEbsVolumesWith satisfiedEffects required
        `shouldReturn` Right
          [ StaticEbsVolumeBinding "pv-a" "vol-0a" fixtureZone
          , StaticEbsVolumeBinding "pv-b" "vol-0b" fixtureZone
          ]
      counts satisfied `shouldReturn` (2, 0)
      readIORef (traceCreated satisfied) `shouldReturn` []
      readIORef (traceWaited satisfied) `shouldReturn` []
      -- One is missing: only it is created, the wait names only it, and the read-back
      -- needs two consecutive complete listings (an incomplete read, then two complete).
      healing <- newTrace
      healingEffects <-
        scriptedEffects
          healing
          [Right [listedA], Right [listedA], Right [listedA, listedB], Right [listedA, listedB]]
          createsByName
          (Right ())
      EbsVolume.ensureRetainedEbsVolumesWith healingEffects required
        `shouldReturn` Right
          [ StaticEbsVolumeBinding "pv-a" "vol-0a" fixtureZone
          , StaticEbsVolumeBinding "pv-b" "vol-0b" fixtureZone
          ]
      readIORef (traceCreated healing) `shouldReturn` ["pv-b"]
      readIORef (traceWaited healing) `shouldReturn` [["vol-pv-b"]]
      counts healing `shouldReturn` (4, 2)

    it "names the volumes it created when a later step fails, and never when it created none" $ do
      let required = [requiredVolume "pv-a", requiredVolume "pv-b"]
          createsFirstOnly volume
            | EbsVolume.ebsRequiredPersistentVolumeName volume == "pv-a" =
                Right (EbsVolume.EbsVolumeId "vol-0a")
            | otherwise = Left "aws ec2 create-volume failed for pv-b: VolumeLimitExceeded"
      -- The second create fails after the first succeeded: the first is named, and
      -- nothing waits.
      secondFails <- newTrace
      secondFailsEffects <- scriptedEffects secondFails [Right []] createsFirstOnly (Right ())
      createFailure <- EbsVolume.ensureRetainedEbsVolumesWith secondFailsEffects required
      failureText createFailure `shouldSatisfy` isInfixOf "VolumeLimitExceeded"
      failureText createFailure `shouldSatisfy` isInfixOf "vol-0a"
      failureText createFailure `shouldSatisfy` isInfixOf "before creating them again"
      readIORef (traceWaited secondFails) `shouldReturn` []
      -- The waiter fails after both were created: both are named, in creation order.
      waiterFails <- newTrace
      waiterFailsEffects <-
        scriptedEffects
          waiterFails
          [Right []]
          createsByName
          (Left "aws ec2 wait volume-available failed: Max attempts exceeded")
      waitFailure <- EbsVolume.ensureRetainedEbsVolumesWith waiterFailsEffects required
      failureText waitFailure `shouldSatisfy` isInfixOf "Max attempts exceeded"
      failureText waitFailure `shouldSatisfy` isInfixOf "vol-pv-a, vol-pv-b"
      -- Created, waited for, and never listed: the read-back spends its attempts and the
      -- refusal that names the missing volume also names what this call created.
      neverListed <- newTrace
      neverListedEffects <- scriptedEffects neverListed [Right []] createsByName (Right ())
      listingFailure <-
        EbsVolume.ensureRetainedEbsVolumesWith neverListedEffects [requiredVolume "pv-a"]
      failureText listingFailure `shouldSatisfy` isInfixOf "missing retained EBS volume tagged"
      failureText listingFailure `shouldSatisfy` isInfixOf "vol-pv-a"
      counts neverListed
        `shouldReturn` (1 + EbsVolume.retainedEbsVisibilityAttempts, EbsVolume.retainedEbsVisibilityAttempts - 1)
      -- A failure with nothing created is not annotated: there is nothing to warn about.
      nothingCreated <- newTrace
      nothingCreatedEffects <-
        scriptedEffects nothingCreated [Left "Unable to locate credentials"] createsByName (Right ())
      readFailure <- EbsVolume.ensureRetainedEbsVolumesWith nothingCreatedEffects required
      readFailure `shouldBe` Left "Unable to locate credentials"
      readIORef (traceCreated nothingCreated) `shouldReturn` []
      -- The very first create fails: nothing was created before it, so the failure is
      -- the create's own and unannotated.
      firstFails <- newTrace
      firstFailsEffects <-
        scriptedEffects
          firstFails
          [Right []]
          (const (Left "aws ec2 create-volume failed for pv-a: VolumeLimitExceeded"))
          (Right ())
      firstFailure <- EbsVolume.ensureRetainedEbsVolumesWith firstFailsEffects required
      firstFailure `shouldBe` Left "aws ec2 create-volume failed for pv-a: VolumeLimitExceeded"
      -- An ensure that found everything and then fails to read it back created nothing,
      -- so that failure is not annotated either.
      readBackOnly <- newTrace
      readBackOnlyEffects <-
        scriptedEffects
          readBackOnly
          [Right [listedVolume "vol-0a" "pv-a", listedVolume "vol-0b" "pv-b"], Left "throttled"]
          createsByName
          (Right ())
      readBackFailure <- EbsVolume.ensureRetainedEbsVolumesWith readBackOnlyEffects required
      readBackFailure `shouldBe` Left "throttled"
      -- A read-back that fails after a complete listing, with a volume created by this
      -- call, is annotated: that is the path the two-consecutive-reads rule makes reachable.
      listsThenFails <- newTrace
      listsThenFailsEffects <-
        scriptedEffects
          listsThenFails
          [Right [], Right [listedVolume "vol-pv-a" "pv-a"], Left "throttled"]
          createsByName
          (Right ())
      failedAfterComplete <-
        EbsVolume.ensureRetainedEbsVolumesWith listsThenFailsEffects [requiredVolume "pv-a"]
      failureText failedAfterComplete `shouldSatisfy` isInfixOf "throttled"
      failureText failedAfterComplete `shouldSatisfy` isInfixOf "vol-pv-a"

    it "polls the created volumes until they are available, and waits only while the answer is not yet" $ do
      let describing state =
            Success
              ( ProcessOutput
                  ExitSuccess
                  ("{\"Volumes\":[{\"VolumeId\":\"vol-0new\",\"State\":\"" <> state <> "\"}]}")
                  ""
              )
          failing code stderr = Success (ProcessOutput (ExitFailure code) "" stderr)
          notFound =
            failing 255 "An error occurred (InvalidVolume.NotFound) when calling the DescribeVolumes operation"
          refused =
            failing 254 "An error occurred (UnauthorizedOperation) when calling the DescribeVolumes operation"
          throttled =
            failing
              255
              "An error occurred (Throttling) when calling the DescribeVolumes operation: Rate exceeded"
          boundEnded = failing 1 boundedSubprocessTimeoutDetail
          available = describing "available"
          scripted answers = do
            world <- newVirtualWorld
            remaining <- newIORef answers
            calls <- newIORef []
            let run arguments = do
                  modifyIORef' calls (++ [arguments])
                  poppingThenExhausted remaining (Failure "script exhausted")
            pure (world, run, calls)
          waitFor world run =
            EbsVolume.waitForCreatedVolumesVia
              (roomyWaitEnvironment world)
              run
              [EbsVolume.EbsVolumeId "vol-0new"]
          elapsed world = subtract virtualStartMicros <$> virtualNowMicros world
      -- Not listed twice, then creating, then available: four polls, three five-second pauses.
      (world, run, calls) <- scripted [notFound, notFound, describing "creating", available]
      waitFor world run `shouldReturn` Right ()
      readIORef calls
        >>= (`shouldBe` replicate 4 (EbsVolume.ebsDescribeVolumesByIdArgs [EbsVolume.EbsVolumeId "vol-0new"]))
      elapsed world `shouldReturn` 15000000
      -- Throttling and a child the bound stopped are not yet: they are polled again.
      (worldBusy, runBusy, callsBusy) <- scripted [throttled, boundEnded, available]
      waitFor worldBusy runBusy `shouldReturn` Right ()
      (length <$> readIORef callsBusy) `shouldReturn` 3
      -- Never listed: the budget is spent and the failure names the fact and the last answer.
      (worldSpent, runSpent, callsSpent) <- scripted (replicate 100 notFound)
      spent <- waitFor worldSpent runSpent
      failureText spent `shouldSatisfy` isInfixOf "WaitTimedOut"
      failureText spent `shouldSatisfy` isInfixOf "EBS volumes available"
      failureText spent `shouldSatisfy` isInfixOf "InvalidVolume.NotFound"
      -- A three minute ceiling of five second polls: the first at zero and the last at the deadline.
      (length <$> readIORef callsSpent) `shouldReturn` 37
      elapsed worldSpent `shouldReturn` 180000000
      -- A volume that is gone or in error, a refused call and a process that cannot
      -- start end the wait at once, in their own words.
      (worldGone, runGone, callsGone) <- scripted [describing "deleted", available]
      gone <- waitFor worldGone runGone
      failureText gone `shouldSatisfy` isInfixOf "WaitAborted"
      failureText gone `shouldSatisfy` isInfixOf "deleted"
      (length <$> readIORef callsGone) `shouldReturn` 1
      (worldDenied, runDenied, callsDenied) <- scripted [refused, available]
      denied <- waitFor worldDenied runDenied
      failureText denied `shouldSatisfy` isInfixOf "UnauthorizedOperation"
      (length <$> readIORef callsDenied) `shouldReturn` 1
      (worldMissing, runMissing, callsMissing) <- scripted [Failure "no such file or directory"]
      missing <- waitFor worldMissing runMissing
      failureText missing
        `shouldSatisfy` isInfixOf "failed to start `aws ec2 describe-volumes`: no such file or directory"
      (length <$> readIORef callsMissing) `shouldReturn` 1

    it "issues no wait subcommand for the volumes it created" $
      mapM_
        (`shouldNotContain` ["wait"])
        [ EbsVolume.ebsDescribeVolumesByIdArgs [EbsVolume.EbsVolumeId "vol-0new"]
        , EbsVolume.ebsDescribeVolumesArgs EbsVolume.EbsRetainedProduction
        ]

    it "decides the Provider's observation of the retained-EBS ensure from what is listed" $ do
      let required = [requiredVolume "pv-a", requiredVolume "pv-b"]
          listedA = listedVolume "vol-0a" "pv-a"
          listedB = listedVolume "vol-0b" "pv-b"
          observed = ProviderProduction.retainedEbsEnsureObservation required
          wrongZone = listedA {EbsVolume.ebsVolumeAvailabilityZone = Just "elsewhere"}
      -- Every volume listed and bindable: satisfied, and the evidence is the bindings.
      observed (Right [listedA, listedB])
        `shouldBe` ProviderEffectSatisfied
          ( ProviderProduction.retainedEbsBindingsEvidence
              [ StaticEbsVolumeBinding "pv-a" "vol-0a" fixtureZone
              , StaticEbsVolumeBinding "pv-b" "vol-0b" fixtureZone
              ]
          )
      -- One or both missing: the apply is needed, and the text says a created volume
      -- can lag the listing (it is what a confirming read that lags reports).
      observed (Right [listedA]) `shouldSatisfy` needsApplyAboutLag
      observed (Right []) `shouldSatisfy` needsApplyAboutLag
      -- Listed but not bindable (a wrong zone), or a listing that failed: neither is a
      -- claim about presence, so neither is satisfied and neither asks for an apply.
      observed (Right [wrongZone, listedB]) `shouldSatisfy` isUnobservable
      observed (Left "Unable to locate credentials")
        `shouldBe` ProviderEffectUnobservable "Unable to locate credentials"

    it "Sprint 5.53 refuses a retained volume smaller than the plan before it creates anything" $ do
      let required = [requiredVolumeOfSize 50 "pv-a", requiredVolumeOfSize 10 "pv-b"]
          undersized = listedVolumeOfSize 20 "vol-0a" "pv-a"
      trace <- newTrace
      effects <- scriptedEffects trace [Right [undersized]] createsByName (Right ())
      refused <- EbsVolume.ensureRetainedEbsVolumesWith effects required
      -- The refusal names the volume and both sizes ...
      failureText refused `shouldSatisfy` isInfixOf "vol-0a"
      failureText refused `shouldSatisfy` isInfixOf "is 20 GiB but the plan requires 50 GiB"
      -- ... and leaves the account as it found it: pv-b was missing, and is not created
      -- for the sake of a set of bindings that cannot be returned.
      readIORef (traceCreated trace) `shouldReturn` []
      readIORef (traceWaited trace) `shouldReturn` []
      counts trace `shouldReturn` (1, 0)
      -- The Provider's confirming read treats it as a volume it cannot bind, not as a
      -- request to create another one.
      ProviderProduction.retainedEbsEnsureObservation
        required
        (Right [undersized, listedVolumeOfSize 10 "vol-0b" "pv-b"])
        `shouldSatisfy` isUnobservable

    it
      "Sprint 5.53 binds a retained volume at the planned size or larger and refuses one that reports none"
      $ do
        let required = [requiredVolumeOfSize 50 "pv-a"]
            bindingFor volume =
              EbsVolume.retainedEbsVolumeBindingsFromDiscovered required [volume]
            bound = Right [StaticEbsVolumeBinding "pv-a" "vol-0a" fixtureZone]
        -- A table over the planned size: one under refuses, equal and larger bind.
        bindingFor (listedVolumeOfSize 49 "vol-0a" "pv-a") `shouldSatisfy` isLeftNamingBothSizes 49 50
        bindingFor (listedVolumeOfSize 50 "vol-0a" "pv-a") `shouldBe` bound
        bindingFor (listedVolumeOfSize 51 "vol-0a" "pv-a") `shouldBe` bound
        bindingFor (listedVolumeOfSize 100 "vol-0a" "pv-a") `shouldBe` bound
        -- EC2 always reports a size; a listing that does not cannot be shown to be large
        -- enough, so it is refused rather than assumed.
        let unreported = (listedVolumeOfSize 50 "vol-0a" "pv-a") {EbsVolume.ebsVolumeSizeGiB = Nothing}
        failureText (bindingFor unreported) `shouldSatisfy` isInfixOf "did not report a size"
        -- A volume listed twice is the duplicate-tag refusal's, not the size check's.
        EbsVolume.retainedVolumeSizeProblems
          required
          [listedVolumeOfSize 20 "vol-0a" "pv-a", listedVolumeOfSize 20 "vol-0b" "pv-a"]
          `shouldBe` []
        failureText
          ( EbsVolume.retainedEbsVolumeBindingsFromDiscovered
              required
              [listedVolumeOfSize 20 "vol-0a" "pv-a", listedVolumeOfSize 20 "vol-0b" "pv-a"]
          )
          `shouldSatisfy` isInfixOf "multiple retained EBS volumes"

-- | A request to apply whose text says a created volume can lag the listing.
needsApplyAboutLag :: ProviderEffectObservation -> Bool
needsApplyAboutLag observation = case observation of
  ProviderEffectNeedsApply text -> "can lag it" `Text.isInfixOf` text
  _ -> False

isUnobservable :: ProviderEffectObservation -> Bool
isUnobservable observation = case observation of
  ProviderEffectUnobservable _ -> True
  _ -> False

-- | A refusal whose text says the volume is the first size and the plan the second.
isLeftNamingBothSizes :: Int -> Int -> Either String value -> Bool
isLeftNamingBothSizes actual planned result = case result of
  Left detail ->
    ("is " <> show actual <> " GiB but the plan requires " <> show planned <> " GiB") `isInfixOf` detail
  Right _ -> False
