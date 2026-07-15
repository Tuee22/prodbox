{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.65: measured-capacity certification.
--
-- Guaranteed-QoS envelopes are honest only when the authored envelope is
-- justified by measured demand. A committed 'MeasuredResourceProfile' (one per
-- profile id, all-Natural fields; ratios in parts per million) records the
-- sampling evidence, CPU demand, memory high-water marks, backend latency, the
-- profiled hot-path source digest, and the capture time for one workload. The
-- certification check (wired into @prodbox dev check@'s conformance tier) fails
-- when an authored CPU value is below measured @cpu_p99_milli@ × 4/3 headroom,
-- when @throttled_periods_ppm@ exceeds 20000 while a CPU cap is authored, when
-- the measured memory high-water × 4/3 exceeds the authored memory limit, or when
-- the profile is stale (hot-path digest mismatch or older than 30 days).
--
-- Every comparison is one-sided, so a measured improvement (lower p99, less
-- throttle, a lower high-water mark) never fails the check. The check activates
-- for a workload only once a committed profile exists for it under
-- @dhall/capacity/measured/@ (the recorder that produces the first profile is
-- owned by Sprint 5.21); until then it is a no-op. Certification rules are pure
-- ('certifyMeasuredProfile') and unit tested with fixture profiles. The field
-- set and rules mirror
-- [resource_scaling_doctrine.md § 2F](../../../documents/engineering/resource_scaling_doctrine.md).
module Prodbox.Capacity.MeasuredProfile
  ( MeasuredResourceProfile (..)
  , MeasuredProfileDefect (..)
  , stalenessHorizonSeconds
  , cpuHeadroomNumerator
  , cpuHeadroomDenominator
  , throttlePpmCeiling
  , requiredCpuMillicores
  , requiredMemoryLimitMib
  , certifyMeasuredProfile
  , renderMeasuredProfileDefect
  , measuredProfilesDir
  , hotPathSourceFilesFor
  , computeHotPathDigest
  , readMeasuredProfiles
  , certifyMeasuredProfiles

    -- * Sprint 5.21: the profile recorder gate
  , MeasuredProfileRecorderInput (..)
  , MeasuredProfileRecorderRefusal (..)
  , recorderMinimumWindowSeconds
  , recorderMinimumSampleCount
  , recordMeasuredProfile
  , renderMeasuredProfileRecorderRefusal
  , renderMeasuredResourceProfileDhall
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.List (find, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config qualified as Cap
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeFileName, (</>))

-- | A committed measured profile for one authored workload. Field names match
-- the Dhall record (verbatim generic 'Dhall.FromDhall'); every numeric field is
-- a 'Natural' and @throttled_periods_ppm@ is parts per million.
data MeasuredResourceProfile = MeasuredResourceProfile
  { profile_id :: Text
  , recorded_at :: Natural
  , hot_path_digest :: Text
  , sample_window_seconds :: Natural
  , sample_count :: Natural
  , cpu_p95_milli :: Natural
  , cpu_p99_milli :: Natural
  , throttled_periods_ppm :: Natural
  , rss_high_water_mib :: Natural
  , heap_high_water_bytes :: Natural
  , object_store_op_p99_millis :: Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data MeasuredProfileDefect
  = -- | The profile names a workload absent from the authored plan.
    MeasuredProfileUnknownWorkload Text
  | -- | Authored CPU is below measured p99 × 4/3 (profile id, authored, required).
    InsufficientCpuHeadroom Text Natural Natural
  | -- | Throttle exposure exceeds the ceiling while a CPU cap is authored.
    ExcessiveThrottle Text Natural
  | -- | Measured memory high-water × 4/3 exceeds the authored memory limit
    -- (profile id, authored limit, required).
    InsufficientMemoryHeadroom Text Natural Natural
  | -- | The profiled hot-path source digest no longer matches the current source.
    StaleDigest Text
  | -- | The profile is older than the staleness horizon (profile id, age seconds).
    StaleAge Text Natural
  deriving (Eq, Show)

-- | 30 days.
stalenessHorizonSeconds :: Natural
stalenessHorizonSeconds = 2592000

-- | The 4/3 headroom factor (CPU and memory).
cpuHeadroomNumerator :: Natural
cpuHeadroomNumerator = 4

cpuHeadroomDenominator :: Natural
cpuHeadroomDenominator = 3

-- | 20000 ppm = 2% of CFS periods throttled.
throttlePpmCeiling :: Natural
throttlePpmCeiling = 20000

-- | The minimum authored CPU (millicores) that certifies against a measured p99:
-- @ceil(p99 × 4 / 3)@. One-sided — a lower p99 lowers the bar.
requiredCpuMillicores :: Natural -> Natural
requiredCpuMillicores p99 =
  ceilDiv (p99 * cpuHeadroomNumerator) cpuHeadroomDenominator

-- | The minimum authored memory limit (MiB) that certifies against a measured
-- high-water mark: @ceil(rss_high_water × 4 / 3)@. One-sided.
requiredMemoryLimitMib :: Natural -> Natural
requiredMemoryLimitMib highWater =
  ceilDiv (highWater * cpuHeadroomNumerator) cpuHeadroomDenominator

ceilDiv :: Natural -> Natural -> Natural
ceilDiv numerator denominator
  | denominator == 0 = numerator
  | otherwise = (numerator + denominator - 1) `div` denominator

-- | Certify one measured profile against the authored plan, given the current
-- hot-path digest for that workload and the current epoch time. Pure and
-- exhaustive; returns every defect it finds.
certifyMeasuredProfile
  :: Text
  -- ^ current hot-path source digest for this workload
  -> Natural
  -- ^ now, epoch seconds
  -> Cap.ResourcePlan
  -> MeasuredResourceProfile
  -> [MeasuredProfileDefect]
certifyMeasuredProfile currentDigest now plan profile =
  case find ((== profile_id profile) . Cap.profile_id) (Cap.workload_profiles plan) of
    Nothing -> [MeasuredProfileUnknownWorkload (profile_id profile)]
    Just workload ->
      cpuDefect ++ throttleDefect ++ memoryDefect ++ digestDefect ++ ageDefect
     where
      envelope = Cap.resources workload
      authoredCpu = Cap.milli_cpu (Cap.request envelope)
      authoredMemoryLimit = Cap.memory_mib (Cap.limit envelope)
      hasCpuCap = Cap.milli_cpu (Cap.limit envelope) > 0
      requiredCpu = requiredCpuMillicores (cpu_p99_milli profile)
      requiredMemory = requiredMemoryLimitMib (rss_high_water_mib profile)
      cpuDefect =
        [ InsufficientCpuHeadroom (profile_id profile) authoredCpu requiredCpu
        | authoredCpu < requiredCpu
        ]
      throttleDefect =
        [ ExcessiveThrottle (profile_id profile) (throttled_periods_ppm profile)
        | hasCpuCap && throttled_periods_ppm profile > throttlePpmCeiling
        ]
      memoryDefect =
        [ InsufficientMemoryHeadroom (profile_id profile) authoredMemoryLimit requiredMemory
        | requiredMemory > authoredMemoryLimit
        ]
      digestDefect =
        [ StaleDigest (profile_id profile)
        | hot_path_digest profile /= currentDigest
        ]
      ageDefect =
        [ StaleAge (profile_id profile) (now - recorded_at profile)
        | now > recorded_at profile + stalenessHorizonSeconds
        ]

renderMeasuredProfileDefect :: MeasuredProfileDefect -> String
renderMeasuredProfileDefect defect = case defect of
  MeasuredProfileUnknownWorkload pid ->
    "measured profile `" ++ Text.unpack pid ++ "` names no authored workload profile."
  InsufficientCpuHeadroom pid authored required ->
    "measured profile `"
      ++ Text.unpack pid
      ++ "`: authored CPU "
      ++ show authored
      ++ "m is below the certified minimum "
      ++ show required
      ++ "m (measured p99 × 4/3)."
  ExcessiveThrottle pid ppm ->
    "measured profile `"
      ++ Text.unpack pid
      ++ "`: "
      ++ show ppm
      ++ " throttled periods ppm exceeds the "
      ++ show throttlePpmCeiling
      ++ " ppm ceiling while a CPU cap is authored."
  InsufficientMemoryHeadroom pid authored required ->
    "measured profile `"
      ++ Text.unpack pid
      ++ "`: authored memory limit "
      ++ show authored
      ++ "Mi is below the certified minimum "
      ++ show required
      ++ "Mi (measured high-water × 4/3)."
  StaleDigest pid ->
    "measured profile `"
      ++ Text.unpack pid
      ++ "`: hot-path source digest no longer matches; recapture the profile (Sprint 5.21 recorder)."
  StaleAge pid ageSeconds ->
    "measured profile `"
      ++ Text.unpack pid
      ++ "`: captured "
      ++ show ageSeconds
      ++ "s ago, older than the "
      ++ show stalenessHorizonSeconds
      ++ "s horizon; recapture the profile."

-- | Repo-relative home of committed measured profiles.
measuredProfilesDir :: FilePath
measuredProfilesDir = "dhall/capacity/measured"

-- | The hot-path source files whose digest a workload's measurement pins. A
-- workload with no declared hot path digests the empty string (the recorder and
-- this list evolve together; Sprint 5.21 seeds the first committed profile).
hotPathSourceFilesFor :: Text -> [FilePath]
hotPathSourceFilesFor pid = case pid of
  "gateway" ->
    [ "src/Prodbox/Gateway/Daemon.hs"
    , "src/Prodbox/Http/Client.hs"
    , "src/Prodbox/Vault/Session.hs"
    , "src/Prodbox/Minio/ObjectStore.hs"
    ]
  _ -> []

-- | The current SHA-256 (hex) of a workload's concatenated hot-path source.
computeHotPathDigest :: FilePath -> Text -> IO Text
computeHotPathDigest repoRoot pid = do
  chunks <- traverse (BS.readFile . (repoRoot </>)) (hotPathSourceFilesFor pid)
  pure (sha256Hex (BS.concat chunks))

sha256Hex :: ByteString -> Text
sha256Hex = toHexText . SHA256.hash

toHexText :: ByteString -> Text
toHexText = Text.pack . concatMap renderByte . BS.unpack
 where
  renderByte byteValue =
    case showHex byteValue "" of
      [singleDigit] -> ['0', toLower singleDigit]
      digits -> map toLower digits

-- | Read every committed profile under @dhall/capacity/measured/@ (excluding the
-- @Schema.dhall@ type). A missing or empty directory yields no profiles, so the
-- certification check is inert until the first profile is committed.
readMeasuredProfiles :: FilePath -> IO [MeasuredResourceProfile]
readMeasuredProfiles repoRoot = do
  let dir = repoRoot </> measuredProfilesDir
  present <- doesDirectoryExist dir
  if not present
    then pure []
    else do
      entries <- sort <$> listDirectory dir
      let profilePaths =
            [ dir </> entry
            | entry <- entries
            , ".dhall" `isDhallSuffix` entry
            , takeFileName entry /= "Schema.dhall"
            ]
      traverse (Dhall.inputFile Dhall.auto) profilePaths

isDhallSuffix :: String -> String -> Bool
isDhallSuffix suffix entry =
  suffix == drop (length entry - length suffix) entry

-- | Effectful certification for the conformance tier: read committed profiles,
-- certify each against the authored plan using its current hot-path digest and
-- the supplied @now@, and return every rendered defect.
certifyMeasuredProfiles
  :: FilePath -> Natural -> Cap.ResourcePlan -> IO [String]
certifyMeasuredProfiles repoRoot now plan = do
  profiles <- readMeasuredProfiles repoRoot
  fmap concat $
    traverse
      ( \profile -> do
          digest <- computeHotPathDigest repoRoot (profile_id profile)
          pure (map renderMeasuredProfileDefect (certifyMeasuredProfile digest now plan profile))
      )
      profiles

-- | Sprint 5.21: the minimum steady-window (30 minutes) a run must sustain
-- before the recorder may commit a measured profile. A shorter window is not a
-- representative sample of steady-state demand
-- ([resource_scaling_doctrine.md § 2F](../../../documents/engineering/resource_scaling_doctrine.md)).
recorderMinimumWindowSeconds :: Natural
recorderMinimumWindowSeconds = 1800

-- | Sprint 5.21: the minimum sample count a run must have collected over its
-- window; fewer samples are too sparse to be representative demand (doctrine
-- § 2F recorder gate).
recorderMinimumSampleCount :: Natural
recorderMinimumSampleCount = 300

-- | Sprint 5.21: the aggregated evidence a single run offers the recorder. The
-- health verdict and the sustained-window duration are the two gates; the
-- remaining fields are the measured demand aggregated from the run's samples
-- (percentiles, high-water marks, throttle exposure). The recorder is pure over
-- this input; collecting it from a live run is the effectful boundary owned by
-- the gateway-runtime-stability suite.
data MeasuredProfileRecorderInput = MeasuredProfileRecorderInput
  { recorderProfileId :: Text
  , recorderRecordedAt :: Natural
  , recorderHotPathDigest :: Text
  , recorderRunHealthy :: Bool
  , recorderSampleWindowSeconds :: Natural
  , recorderSampleCount :: Natural
  , recorderCpuP95Milli :: Natural
  , recorderCpuP99Milli :: Natural
  , recorderThrottledPeriodsPpm :: Natural
  , recorderRssHighWaterMib :: Natural
  , recorderHeapHighWaterBytes :: Natural
  , recorderObjectStoreOpP99Millis :: Natural
  }
  deriving stock (Eq, Show)

-- | Sprint 5.21: why the recorder refused to commit a profile.
data MeasuredProfileRecorderRefusal
  = -- | The run was not healthy over its whole window (a fatal runtime-stability
    -- observation is absorbing), so its demand is not certifiable evidence.
    RecorderRunNotHealthy
  | -- | The sustained steady window (actual, required seconds) was too short.
    RecorderWindowTooShort Natural Natural
  | -- | Too few samples were collected over the window (actual, required).
    RecorderTooFewSamples Natural Natural
  deriving (Eq, Show)

-- | Sprint 5.21: the pure recorder gate. A profile is committed ONLY from a
-- healthy run with at least a 'recorderMinimumWindowSeconds' steady window; an
-- unhealthy run or a short window is refused, never silently written. When both
-- gates pass, the aggregated demand becomes a 'MeasuredResourceProfile' that
-- 'certifyMeasuredProfile' can subsequently check the authored envelope against.
recordMeasuredProfile
  :: MeasuredProfileRecorderInput
  -> Either MeasuredProfileRecorderRefusal MeasuredResourceProfile
recordMeasuredProfile input
  | not (recorderRunHealthy input) = Left RecorderRunNotHealthy
  | recorderSampleWindowSeconds input < recorderMinimumWindowSeconds =
      Left
        ( RecorderWindowTooShort
            (recorderSampleWindowSeconds input)
            recorderMinimumWindowSeconds
        )
  | recorderSampleCount input < recorderMinimumSampleCount =
      Left
        ( RecorderTooFewSamples
            (recorderSampleCount input)
            recorderMinimumSampleCount
        )
  | otherwise =
      Right
        MeasuredResourceProfile
          { profile_id = recorderProfileId input
          , recorded_at = recorderRecordedAt input
          , hot_path_digest = recorderHotPathDigest input
          , sample_window_seconds = recorderSampleWindowSeconds input
          , sample_count = recorderSampleCount input
          , cpu_p95_milli = recorderCpuP95Milli input
          , cpu_p99_milli = recorderCpuP99Milli input
          , throttled_periods_ppm = recorderThrottledPeriodsPpm input
          , rss_high_water_mib = recorderRssHighWaterMib input
          , heap_high_water_bytes = recorderHeapHighWaterBytes input
          , object_store_op_p99_millis = recorderObjectStoreOpP99Millis input
          }

renderMeasuredProfileRecorderRefusal :: MeasuredProfileRecorderRefusal -> String
renderMeasuredProfileRecorderRefusal refusal = case refusal of
  RecorderRunNotHealthy ->
    "measured-profile recorder refused: the run was not healthy over its whole "
      ++ "window; only a healthy run's demand is certifiable evidence."
  RecorderWindowTooShort actual required ->
    "measured-profile recorder refused: the steady window was "
      ++ show actual
      ++ "s, shorter than the required "
      ++ show required
      ++ "s minimum."
  RecorderTooFewSamples actual required ->
    "measured-profile recorder refused: only "
      ++ show actual
      ++ " samples were collected, fewer than the required "
      ++ show required
      ++ " minimum."

-- | Sprint 5.21: render a committed profile as the Dhall record literal the
-- @dhall/capacity/measured/@ artifact home holds. It round-trips through the
-- generic 'Dhall.FromDhall' 'readMeasuredProfiles' reads back, so the recorded
-- artifact is exactly what the certification check consumes.
renderMeasuredResourceProfileDhall :: MeasuredResourceProfile -> Text
renderMeasuredResourceProfileDhall profile =
  Text.unlines
    [ "{ profile_id = " <> dhallText (profile_id profile)
    , ", recorded_at = " <> natLit (recorded_at profile)
    , ", hot_path_digest = " <> dhallText (hot_path_digest profile)
    , ", sample_window_seconds = " <> natLit (sample_window_seconds profile)
    , ", sample_count = " <> natLit (sample_count profile)
    , ", cpu_p95_milli = " <> natLit (cpu_p95_milli profile)
    , ", cpu_p99_milli = " <> natLit (cpu_p99_milli profile)
    , ", throttled_periods_ppm = " <> natLit (throttled_periods_ppm profile)
    , ", rss_high_water_mib = " <> natLit (rss_high_water_mib profile)
    , ", heap_high_water_bytes = " <> natLit (heap_high_water_bytes profile)
    , ", object_store_op_p99_millis = " <> natLit (object_store_op_p99_millis profile)
    , "}"
    ]
 where
  natLit value = Text.pack (show value)
  dhallText value = "\"" <> value <> "\""
