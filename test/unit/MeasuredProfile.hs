{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.65 conformance suite: measured-capacity certification. Pure
-- certification rules are exercised against the authored default plan with
-- fixture profiles; the final cases prove the check is inert (green) on the real
-- repository, where no measured profile is committed yet.
module MeasuredProfile
  ( measuredProfileSuite
  )
where

import Dhall qualified
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config (defaultResourcePlan)
import Prodbox.Capacity.MeasuredProfile
import System.Directory (getCurrentDirectory)
import TestSupport

-- | A baseline gateway profile that certifies cleanly against the authored
-- gateway envelope (750m CPU request/limit, 512Mi memory limit): p99 500m
-- (required 667m ≤ 750m), rss high-water 300Mi (required 400Mi ≤ 512Mi), low
-- throttle, matching digest, recently captured.
baseGatewayProfile :: MeasuredResourceProfile
baseGatewayProfile =
  MeasuredResourceProfile
    { profile_id = "gateway"
    , recorded_at = referenceNow - 1000
    , hot_path_digest = "current-digest"
    , sample_window_seconds = 1800
    , sample_count = 300
    , cpu_p95_milli = 400
    , cpu_p99_milli = 500
    , throttled_periods_ppm = 1000
    , rss_high_water_mib = 300
    , heap_high_water_bytes = 268435456
    , object_store_op_p99_millis = 50
    }

referenceNow :: Natural
referenceNow = 1_000_000_000

-- | The recorder input aggregated from a healthy run at the 30-minute steady
-- window; it records exactly 'baseGatewayProfile'.
baseRecorderInput :: MeasuredProfileRecorderInput
baseRecorderInput =
  MeasuredProfileRecorderInput
    { recorderProfileId = "gateway"
    , recorderRecordedAt = referenceNow - 1000
    , recorderHotPathDigest = "current-digest"
    , recorderRunHealthy = True
    , recorderSampleWindowSeconds = 1800
    , recorderSampleCount = 300
    , recorderCpuP95Milli = 400
    , recorderCpuP99Milli = 500
    , recorderThrottledPeriodsPpm = 1000
    , recorderRssHighWaterMib = 300
    , recorderHeapHighWaterBytes = 268435456
    , recorderObjectStoreOpP99Millis = 50
    }

certifyGateway :: MeasuredResourceProfile -> [MeasuredProfileDefect]
certifyGateway = certifyMeasuredProfile "current-digest" referenceNow defaultResourcePlan

measuredProfileSuite :: SuiteBuilder ()
measuredProfileSuite =
  describe "Sprint 1.65 measured-capacity certification" $ do
    describe "headroom arithmetic" $ do
      it "rounds measured p99 × 4/3 up" $ do
        requiredCpuMillicores 500 `shouldBe` 667
        requiredCpuMillicores 600 `shouldBe` 800
        requiredCpuMillicores 0 `shouldBe` 0
        requiredCpuMillicores 750 `shouldBe` 1000
      it "rounds measured memory high-water × 4/3 up" $ do
        requiredMemoryLimitMib 300 `shouldBe` 400
        requiredMemoryLimitMib 384 `shouldBe` 512

    describe "certification against the authored plan" $ do
      it "passes a well-justified gateway profile" $ do
        certifyGateway baseGatewayProfile `shouldBe` []

      it "fails when authored CPU is below measured p99 × 4/3" $ do
        -- p99 600 requires 800m; the authored gateway envelope is 750m.
        certifyGateway baseGatewayProfile {cpu_p99_milli = 600}
          `shouldSatisfy` any isCpuDefect

      it "is one-sided: a measured CPU improvement never fails on headroom" $ do
        certifyGateway baseGatewayProfile {cpu_p99_milli = 100}
          `shouldBe` []

      it "fails when throttle exceeds the ppm ceiling under a CPU cap" $ do
        certifyGateway baseGatewayProfile {throttled_periods_ppm = 25000}
          `shouldSatisfy` any isThrottleDefect

      it "accepts throttle at the ceiling" $ do
        certifyGateway baseGatewayProfile {throttled_periods_ppm = throttlePpmCeiling}
          `shouldBe` []

      it "fails when measured memory high-water × 4/3 exceeds the authored limit" $ do
        -- rss 400Mi requires 534Mi; the authored gateway memory limit is 512Mi.
        certifyGateway baseGatewayProfile {rss_high_water_mib = 400}
          `shouldSatisfy` any isMemoryDefect

      it "fails a stale digest" $ do
        certifyMeasuredProfile "different-digest" referenceNow defaultResourcePlan baseGatewayProfile
          `shouldSatisfy` any isStaleDigest

      it "fails a profile older than the staleness horizon" $ do
        certifyGateway baseGatewayProfile {recorded_at = referenceNow - stalenessHorizonSeconds - 1}
          `shouldSatisfy` any isStaleAge

      it "flags a profile that names no authored workload" $ do
        certifyGateway baseGatewayProfile {profile_id = "no-such-workload"}
          `shouldSatisfy` any isUnknownWorkload

    describe "conformance-tier wiring" $ do
      it "reads no committed profiles from the real repo (check is inert)" $ do
        repoRoot <- getCurrentDirectory
        profiles <- readMeasuredProfiles repoRoot
        profiles `shouldBe` []

      it "certifies green on the real repo (no committed profiles)" $ do
        repoRoot <- getCurrentDirectory
        violations <- certifyMeasuredProfiles repoRoot referenceNow defaultResourcePlan
        violations `shouldBe` []

    describe "defect rendering" $ do
      it "renders a headroom defect with both millicore values" $ do
        renderMeasuredProfileDefect (InsufficientCpuHeadroom "gateway" 750 800)
          `shouldContain` "750m"

    describe "Sprint 5.21 measured profile recorder gate" $ do
      it "records a profile from a healthy run with a 30-minute steady window" $
        recordMeasuredProfile baseRecorderInput `shouldBe` Right baseGatewayProfile

      it "refuses an unhealthy run rather than committing its demand" $
        recordMeasuredProfile (baseRecorderInput {recorderRunHealthy = False})
          `shouldBe` Left RecorderRunNotHealthy

      it "refuses a run whose steady window is shorter than the 30-minute minimum" $
        recordMeasuredProfile (baseRecorderInput {recorderSampleWindowSeconds = 1799})
          `shouldBe` Left (RecorderWindowTooShort 1799 recorderMinimumWindowSeconds)

      it "refuses a run with too few samples over the window" $
        recordMeasuredProfile (baseRecorderInput {recorderSampleCount = 299})
          `shouldBe` Left (RecorderTooFewSamples 299 recorderMinimumSampleCount)

      it "renders the committed profile as Dhall that round-trips to the certified type" $ do
        parsed <- Dhall.input Dhall.auto (renderMeasuredResourceProfileDhall baseGatewayProfile)
        parsed `shouldBe` baseGatewayProfile

      it "a recorded profile certifies cleanly against the authored plan (closes the loop)" $
        case recordMeasuredProfile baseRecorderInput of
          Left refusal -> expectationFailure (renderMeasuredProfileRecorderRefusal refusal)
          Right recorded -> certifyGateway recorded `shouldBe` []

isCpuDefect :: MeasuredProfileDefect -> Bool
isCpuDefect InsufficientCpuHeadroom {} = True
isCpuDefect _ = False

isThrottleDefect :: MeasuredProfileDefect -> Bool
isThrottleDefect ExcessiveThrottle {} = True
isThrottleDefect _ = False

isMemoryDefect :: MeasuredProfileDefect -> Bool
isMemoryDefect InsufficientMemoryHeadroom {} = True
isMemoryDefect _ = False

isStaleDigest :: MeasuredProfileDefect -> Bool
isStaleDigest StaleDigest {} = True
isStaleDigest _ = False

isStaleAge :: MeasuredProfileDefect -> Bool
isStaleAge StaleAge {} = True
isStaleAge _ = False

isUnknownWorkload :: MeasuredProfileDefect -> Bool
isUnknownWorkload MeasuredProfileUnknownWorkload {} = True
isUnknownWorkload _ = False
