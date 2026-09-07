{-# LANGUAGE OverloadedStrings #-}

-- | One finite relationship between the Provider Worker's child schedule and
-- the Lifecycle Authority HTTP client that waits for its response.
module Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerBudgetError (..)
  , ProviderWorkerResourceEnvelope (..)
  , ProviderWorkerCounterexampleTopology (..)
  , ProviderWorkerCounterexampleBackgroundLoad (..)
  , ProviderWorkerCounterexampleFaultSchedule (..)
  , ProviderWorkerEphemeralCausalProfile (..)
  , ProviderWorkerEphemeralObservation (..)
  , ProviderWorkerReplacementPackaging (..)
  , ProviderWorkerEphemeralCounterexample (..)
  , ProviderWorkerEphemeralDisposition (..)
  , ProviderWorkerEphemeralClosure (..)
  , ProviderWorkerEphemeralCounterexampleError (..)
  , ProviderWorkerCapacityPartition (..)
  , ProviderWorkerSchemaOomObservation (..)
  , ProviderWorkerSchemaProbeBoundary (..)
  , ProviderWorkerSchemaSizingProbe (..)
  , ProviderWorkerSchemaLiveReplacementObservation (..)
  , ProviderWorkerSchemaMemoryCounterexample (..)
  , ProviderWorkerSchemaMemoryStatus (..)
  , ProviderWorkerSchemaMemoryCounterexampleError (..)
  , providerWorkerEphemeralCounterexampleId
  , providerWorkerSchemaMemoryCounterexampleId
  , providerWorkerAwsProviderVersion
  , providerWorkerAwsProviderLinuxAmd64Sha256
  , providerWorkerAwsProviderLinuxArm64Sha256
  , providerWorkerProductionChildReserveBytes
  , providerWorkerProductionMemoryMebibytes
  , frozenProviderWorkerEphemeralCounterexample
  , validateProviderWorkerEphemeralCounterexample
  , frozenProviderWorkerSchemaMemoryCounterexample
  , validateProviderWorkerSchemaMemoryCounterexample
  , providerWorkerMaximumChildDeadlineMilliseconds
  , providerWorkerResponseOverheadMilliseconds
  , providerWorkerResponseTimeoutMicros
  , validateProviderWorkerChildDeadlineMilliseconds
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)

data ProviderWorkerBudgetError
  = ProviderWorkerChildDeadlineMustBePositive
  | ProviderWorkerChildDeadlineExceedsTransportMaximum !Natural !Natural
  deriving (Eq, Show)

-- | The topology-normalized Provider Worker envelope used by the frozen
-- counterexample. Values are millicores or bytes; persistence is deliberately
-- separate from ephemeral storage.
data ProviderWorkerResourceEnvelope = ProviderWorkerResourceEnvelope
  { providerWorkerEnvelopeCpuMillicores :: !Natural
  , providerWorkerEnvelopeMemoryBytes :: !Natural
  , providerWorkerEnvelopeEphemeralBytes :: !Natural
  , providerWorkerEnvelopeDurableBytes :: !Natural
  }
  deriving (Eq, Show)

data ProviderWorkerCounterexampleTopology
  = OneFencedProviderWorkerOneSerializedChild
  deriving (Eq, Show)

data ProviderWorkerCounterexampleBackgroundLoad
  = OneRegisteredStackReconcile
  deriving (Eq, Show)

data ProviderWorkerCounterexampleFaultSchedule
  = NoInjectedProviderFault
  deriving (Eq, Show)

data ProviderWorkerEphemeralCausalProfile = ProviderWorkerEphemeralCausalProfile
  { providerWorkerCounterexampleTopology :: !ProviderWorkerCounterexampleTopology
  , providerWorkerCounterexampleBackgroundLoad :: !ProviderWorkerCounterexampleBackgroundLoad
  , providerWorkerCounterexampleFaultSchedule :: !ProviderWorkerCounterexampleFaultSchedule
  }
  deriving (Eq, Show)

-- | Exact, independently timestamped facts from the evicted production Pod.
-- The path totals are not additive: kubelet sampled its peak five seconds
-- before the path fold completed.
data ProviderWorkerEphemeralObservation = ProviderWorkerEphemeralObservation
  { providerWorkerBaselineRootfsBytes :: !Natural
  , providerWorkerKubeletPeakBytes :: !Natural
  , providerWorkerTmpTotalBytes :: !Natural
  , providerWorkerPluginArchiveBytes :: !Natural
  , providerWorkerPulumiHomeTotalBytes :: !Natural
  , providerWorkerPluginDirectoryBytes :: !Natural
  , providerWorkerPluginBinaryBytes :: !Natural
  , providerWorkerPluginPartialBytes :: !Natural
  , providerWorkerPluginLockBytes :: !Natural
  , providerWorkerCheckpointScratchBytes :: !Natural
  , providerWorkerCheckpointJsonBytes :: !Natural
  , providerWorkerApplicationLogBytes :: !Natural
  }
  deriving (Eq, Show)

-- | Code-local replacement claim. Deployment qualification still measures
-- the production Pod; this record closes only the identified runtime provider
-- archive/binary overlap under the same resource envelope.
data ProviderWorkerReplacementPackaging = ProviderWorkerReplacementPackaging
  { providerWorkerPackagedAwsProviderVersion :: !Text
  , providerWorkerPackagedAwsProviderLinuxAmd64Sha256 :: !Text
  , providerWorkerPackagedAwsProviderLinuxArm64Sha256 :: !Text
  , providerWorkerReplacementRuntimeArchiveBytes :: !Natural
  , providerWorkerReplacementRuntimeProviderBinaryBytes :: !Natural
  }
  deriving (Eq, Show)

data ProviderWorkerEphemeralCounterexample = ProviderWorkerEphemeralCounterexample
  { providerWorkerCounterexampleIdentity :: !Text
  , providerWorkerCounterexampleCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerWorkerCounterexampleSupersededEnvelope :: !ProviderWorkerResourceEnvelope
  , providerWorkerCounterexampleReplacementEnvelope :: !ProviderWorkerResourceEnvelope
  , providerWorkerCounterexampleObservation :: !ProviderWorkerEphemeralObservation
  , providerWorkerCounterexampleReplacementPackaging :: !ProviderWorkerReplacementPackaging
  }
  deriving (Eq, Show)

data ProviderWorkerEphemeralDisposition
  = ProviderWorkerEphemeralLimitExceeded !Natural !Natural
  | ProviderWorkerRuntimeProviderOverlapEliminated
  deriving (Eq, Show)

data ProviderWorkerEphemeralClosure = ProviderWorkerEphemeralClosure
  { providerWorkerClosureOldToNewEnvelope
      :: !(ProviderWorkerResourceEnvelope, ProviderWorkerResourceEnvelope)
  , providerWorkerClosureSupersededDisposition :: !ProviderWorkerEphemeralDisposition
  , providerWorkerClosureReplacementDisposition :: !ProviderWorkerEphemeralDisposition
  }
  deriving (Eq, Show)

data ProviderWorkerEphemeralCounterexampleError
  = ProviderWorkerCounterexampleIdentityDrift
  | ProviderWorkerCounterexampleCausalProfileDrift !ProviderWorkerEphemeralCausalProfile
  | ProviderWorkerCounterexampleEnvelopeChanged
      !ProviderWorkerResourceEnvelope
      !ProviderWorkerResourceEnvelope
  | ProviderWorkerCounterexampleEnvelopeDrift !ProviderWorkerResourceEnvelope
  | ProviderWorkerCounterexampleObservationDrift !ProviderWorkerEphemeralObservation
  | ProviderWorkerCounterexampleDidNotExceedLimit !Natural !Natural
  | ProviderWorkerCounterexamplePackagingDrift !ProviderWorkerReplacementPackaging
  | ProviderWorkerCounterexampleRuntimeProviderWrite !Natural !Natural
  deriving (Eq, Show)

-- | One side of the schema-memory counterexample's normalized capacity
-- mapping. Idle capacity is explicit because the correction transfers memory
-- from already-declared headroom without increasing host capacity or reducing
-- any background workload.
data ProviderWorkerCapacityPartition = ProviderWorkerCapacityPartition
  { providerWorkerPartitionEnvelope :: !ProviderWorkerResourceEnvelope
  , providerWorkerPartitionIdleHeadroom :: !ProviderWorkerResourceEnvelope
  }
  deriving (Eq, Show)

-- | Exact cgroup evidence from the packaged-provider production failure.
data ProviderWorkerSchemaOomObservation = ProviderWorkerSchemaOomObservation
  { providerWorkerSchemaOomMemoryLimitBytes :: !Natural
  , providerWorkerSchemaOomMemoryPeakBytes :: !Natural
  , providerWorkerSchemaOomMaxEventCount :: !Natural
  , providerWorkerSchemaOomKillCount :: !Natural
  , providerWorkerSchemaOomDaemonRestartCount :: !Natural
  }
  deriving (Eq, Show)

data ProviderWorkerSchemaProbeBoundary
  = ProviderWorkerInvalidCredentialsAfterSchemaLoad
  deriving (Eq, Show)

-- | Non-mutating sizing evidence from the exact runtime image, a fresh local
-- file backend, and deliberately invalid AWS credentials. It independently
-- justifies the production envelope but is not a substitute for the pending
-- live registered-stack replacement pass.
data ProviderWorkerSchemaSizingProbe = ProviderWorkerSchemaSizingProbe
  { providerWorkerSchemaProbeImageDigest :: !Text
  , providerWorkerSchemaProbeUncappedPeakBytes :: !Natural
  , providerWorkerSchemaProbeUncappedOomKills :: !Natural
  , providerWorkerSchemaProbeHardLimitBytes :: !Natural
  , providerWorkerSchemaProbeHardLimitPeakBytes :: !Natural
  , providerWorkerSchemaProbeHardLimitOomKills :: !Natural
  , providerWorkerSchemaProbeBoundary :: !ProviderWorkerSchemaProbeBoundary
  }
  deriving (Eq, Show)

-- | Filled only from the exact live registered-stack replacement run. Keeping
-- this absent makes the open proof obligation explicit in the repository.
data ProviderWorkerSchemaLiveReplacementObservation = ProviderWorkerSchemaLiveReplacementObservation
  { providerWorkerSchemaLiveMemoryLimitBytes :: !Natural
  , providerWorkerSchemaLiveMemoryPeakBytes :: !Natural
  , providerWorkerSchemaLiveOomKillCount :: !Natural
  , providerWorkerSchemaLiveDaemonRestartCount :: !Natural
  , providerWorkerSchemaLiveExactProviderCompletion :: !Bool
  }
  deriving (Eq, Show)

data ProviderWorkerSchemaMemoryCounterexample = ProviderWorkerSchemaMemoryCounterexample
  { providerWorkerSchemaCounterexampleIdentity :: !Text
  , providerWorkerSchemaCounterexampleCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerWorkerSchemaCounterexampleAllocatable :: !ProviderWorkerResourceEnvelope
  , providerWorkerSchemaCounterexampleBackgroundDraw :: !ProviderWorkerResourceEnvelope
  , providerWorkerSchemaCounterexampleSupersededPartition :: !ProviderWorkerCapacityPartition
  , providerWorkerSchemaCounterexampleReplacementPartition :: !ProviderWorkerCapacityPartition
  , providerWorkerSchemaCounterexampleSupersededObservation :: !ProviderWorkerSchemaOomObservation
  , providerWorkerSchemaCounterexampleSizingProbe :: !ProviderWorkerSchemaSizingProbe
  , providerWorkerSchemaCounterexampleLiveReplacement
      :: !(Maybe ProviderWorkerSchemaLiveReplacementObservation)
  }
  deriving (Eq, Show)

data ProviderWorkerSchemaMemoryStatus
  = ProviderWorkerSchemaMemoryPendingLiveReplacement
  | ProviderWorkerSchemaMemoryClosed
  deriving (Eq, Show)

data ProviderWorkerSchemaMemoryCounterexampleError
  = ProviderWorkerSchemaMemoryArtifactDrift
  | ProviderWorkerSchemaMemoryNormalizedTotalChanged
  | ProviderWorkerSchemaMemoryAllocatableMismatch
  | ProviderWorkerSchemaMemorySupersededFailureMissing
  | ProviderWorkerSchemaMemorySizingProbeInsufficient
  | ProviderWorkerSchemaMemoryLiveReplacementInsufficient
  deriving (Eq, Show)

providerWorkerEphemeralCounterexampleId :: Text
providerWorkerEphemeralCounterexampleId =
  "PROVIDER-WORKER-PULUMI-EPHEMERAL-STORAGE-EVICTION-256MI-2026-09-05"

providerWorkerSchemaMemoryCounterexampleId :: Text
providerWorkerSchemaMemoryCounterexampleId =
  "PROVIDER-WORKER-PACKAGED-AWS-SCHEMA-OOM-176MIB-2026-09-05"

providerWorkerAwsProviderVersion :: Text
providerWorkerAwsProviderVersion = "7.44.0"

providerWorkerAwsProviderLinuxAmd64Sha256 :: Text
providerWorkerAwsProviderLinuxAmd64Sha256 =
  "7aacb02491864f126b9bb2bc8d308c8781817169a90a12c0b3855fa5e79c7115"

providerWorkerAwsProviderLinuxArm64Sha256 :: Text
providerWorkerAwsProviderLinuxArm64Sha256 =
  "48f6800eb6922b23a3acb65f65b945f25cdd0e607fc442f6ff4675a75bbf7c6b"

-- | The 976.9765625 MiB uncapped schema/preview observation rounded upward to
-- one binary capacity unit rather than fitted to the sample.
providerWorkerProductionChildReserveBytes :: Natural
providerWorkerProductionChildReserveBytes = mebibytes 1024

-- | 64 MiB heap + 16 MiB native + 1024 MiB child + 8 MiB kernel/cgroup
-- reserve + 8 MiB safety.
providerWorkerProductionMemoryMebibytes :: Natural
providerWorkerProductionMemoryMebibytes = 1120

providerWorkerAuthoredEnvelope :: ProviderWorkerResourceEnvelope
providerWorkerAuthoredEnvelope =
  ProviderWorkerResourceEnvelope
    { providerWorkerEnvelopeCpuMillicores = 100
    , providerWorkerEnvelopeMemoryBytes = mebibytes 176
    , providerWorkerEnvelopeEphemeralBytes = mebibytes 256
    , providerWorkerEnvelopeDurableBytes = 0
    }

providerWorkerFrozenCausalProfile :: ProviderWorkerEphemeralCausalProfile
providerWorkerFrozenCausalProfile =
  ProviderWorkerEphemeralCausalProfile
    { providerWorkerCounterexampleTopology = OneFencedProviderWorkerOneSerializedChild
    , providerWorkerCounterexampleBackgroundLoad = OneRegisteredStackReconcile
    , providerWorkerCounterexampleFaultSchedule = NoInjectedProviderFault
    }

frozenProviderWorkerEphemeralObservation :: ProviderWorkerEphemeralObservation
frozenProviderWorkerEphemeralObservation =
  ProviderWorkerEphemeralObservation
    { providerWorkerBaselineRootfsBytes = 69632
    , providerWorkerKubeletPeakBytes = 337674240
    , providerWorkerTmpTotalBytes = kibibytes 200804
    , providerWorkerPluginArchiveBytes = kibibytes 200792
    , providerWorkerPulumiHomeTotalBytes = kibibytes 231264
    , providerWorkerPluginDirectoryBytes = kibibytes 231244
    , providerWorkerPluginBinaryBytes = kibibytes 231216
    , providerWorkerPluginPartialBytes = 0
    , providerWorkerPluginLockBytes = 0
    , providerWorkerCheckpointScratchBytes = kibibytes 12
    , providerWorkerCheckpointJsonBytes = kibibytes 4
    , providerWorkerApplicationLogBytes = 24576
    }

frozenProviderWorkerReplacementPackaging :: ProviderWorkerReplacementPackaging
frozenProviderWorkerReplacementPackaging =
  ProviderWorkerReplacementPackaging
    { providerWorkerPackagedAwsProviderVersion = providerWorkerAwsProviderVersion
    , providerWorkerPackagedAwsProviderLinuxAmd64Sha256 =
        providerWorkerAwsProviderLinuxAmd64Sha256
    , providerWorkerPackagedAwsProviderLinuxArm64Sha256 =
        providerWorkerAwsProviderLinuxArm64Sha256
    , providerWorkerReplacementRuntimeArchiveBytes = 0
    , providerWorkerReplacementRuntimeProviderBinaryBytes = 0
    }

frozenProviderWorkerSchemaMemoryCounterexample :: ProviderWorkerSchemaMemoryCounterexample
frozenProviderWorkerSchemaMemoryCounterexample =
  ProviderWorkerSchemaMemoryCounterexample
    { providerWorkerSchemaCounterexampleIdentity = providerWorkerSchemaMemoryCounterexampleId
    , providerWorkerSchemaCounterexampleCausalProfile = providerWorkerFrozenCausalProfile
    , providerWorkerSchemaCounterexampleAllocatable =
        ProviderWorkerResourceEnvelope
          { providerWorkerEnvelopeCpuMillicores = 7000
          , providerWorkerEnvelopeMemoryBytes = mebibytes 13312
          , providerWorkerEnvelopeEphemeralBytes = mebibytes 80032
          , providerWorkerEnvelopeDurableBytes = mebibytes 177952
          }
    , providerWorkerSchemaCounterexampleBackgroundDraw =
        ProviderWorkerResourceEnvelope
          { providerWorkerEnvelopeCpuMillicores = 6110
          , providerWorkerEnvelopeMemoryBytes = mebibytes 8864
          , providerWorkerEnvelopeEphemeralBytes = mebibytes 15200
          , providerWorkerEnvelopeDurableBytes = mebibytes 155648
          }
    , providerWorkerSchemaCounterexampleSupersededPartition =
        ProviderWorkerCapacityPartition
          { providerWorkerPartitionEnvelope = providerWorkerAuthoredEnvelope
          , providerWorkerPartitionIdleHeadroom =
              ProviderWorkerResourceEnvelope
                { providerWorkerEnvelopeCpuMillicores = 790
                , providerWorkerEnvelopeMemoryBytes = mebibytes 4272
                , providerWorkerEnvelopeEphemeralBytes = mebibytes 64576
                , providerWorkerEnvelopeDurableBytes = mebibytes 22304
                }
          }
    , providerWorkerSchemaCounterexampleReplacementPartition =
        ProviderWorkerCapacityPartition
          { providerWorkerPartitionEnvelope =
              providerWorkerAuthoredEnvelope
                { providerWorkerEnvelopeMemoryBytes =
                    mebibytes providerWorkerProductionMemoryMebibytes
                }
          , providerWorkerPartitionIdleHeadroom =
              ProviderWorkerResourceEnvelope
                { providerWorkerEnvelopeCpuMillicores = 790
                , providerWorkerEnvelopeMemoryBytes = mebibytes 3328
                , providerWorkerEnvelopeEphemeralBytes = mebibytes 64576
                , providerWorkerEnvelopeDurableBytes = mebibytes 22304
                }
          }
    , providerWorkerSchemaCounterexampleSupersededObservation =
        ProviderWorkerSchemaOomObservation
          { providerWorkerSchemaOomMemoryLimitBytes = mebibytes 176
          , providerWorkerSchemaOomMemoryPeakBytes = mebibytes 176
          , providerWorkerSchemaOomMaxEventCount = 83
          , providerWorkerSchemaOomKillCount = 6
          , providerWorkerSchemaOomDaemonRestartCount = 0
          }
    , providerWorkerSchemaCounterexampleSizingProbe =
        ProviderWorkerSchemaSizingProbe
          { providerWorkerSchemaProbeImageDigest =
              "sha256:2dc12d0bc7f39fc78ba17c1b67bd987d48aa8578336365af66e1668db0bcd07a"
          , providerWorkerSchemaProbeUncappedPeakBytes = 1024434176
          , providerWorkerSchemaProbeUncappedOomKills = 0
          , providerWorkerSchemaProbeHardLimitBytes =
              mebibytes providerWorkerProductionMemoryMebibytes
          , providerWorkerSchemaProbeHardLimitPeakBytes = 966365184
          , providerWorkerSchemaProbeHardLimitOomKills = 0
          , providerWorkerSchemaProbeBoundary = ProviderWorkerInvalidCredentialsAfterSchemaLoad
          }
    , providerWorkerSchemaCounterexampleLiveReplacement = Nothing
    }

-- | Repository-owned Standard-P counterexample for the production eviction.
-- One registered stack reconcile, one serialized Provider child, no injected
-- fault, and the complete resource envelope are held constant. The replacement
-- pass is deliberately narrow: it proves the identified provider archive and
-- binary are image content rather than runtime writes; the live production
-- profile must still prove the complete Pod stays within the authored limit.
frozenProviderWorkerEphemeralCounterexample :: ProviderWorkerEphemeralCounterexample
frozenProviderWorkerEphemeralCounterexample =
  ProviderWorkerEphemeralCounterexample
    { providerWorkerCounterexampleIdentity = providerWorkerEphemeralCounterexampleId
    , providerWorkerCounterexampleCausalProfile = providerWorkerFrozenCausalProfile
    , providerWorkerCounterexampleSupersededEnvelope = providerWorkerAuthoredEnvelope
    , providerWorkerCounterexampleReplacementEnvelope = providerWorkerAuthoredEnvelope
    , providerWorkerCounterexampleObservation = frozenProviderWorkerEphemeralObservation
    , providerWorkerCounterexampleReplacementPackaging =
        frozenProviderWorkerReplacementPackaging
    }

validateProviderWorkerEphemeralCounterexample
  :: ProviderWorkerEphemeralCounterexample
  -> Either ProviderWorkerEphemeralCounterexampleError ProviderWorkerEphemeralClosure
validateProviderWorkerEphemeralCounterexample counterexample
  | providerWorkerCounterexampleIdentity counterexample
      /= providerWorkerEphemeralCounterexampleId =
      Left ProviderWorkerCounterexampleIdentityDrift
  | causalProfile /= providerWorkerFrozenCausalProfile =
      Left (ProviderWorkerCounterexampleCausalProfileDrift causalProfile)
  | supersededEnvelope /= replacementEnvelope =
      Left
        ( ProviderWorkerCounterexampleEnvelopeChanged
            supersededEnvelope
            replacementEnvelope
        )
  | supersededEnvelope /= providerWorkerAuthoredEnvelope =
      Left (ProviderWorkerCounterexampleEnvelopeDrift supersededEnvelope)
  | observedPeak <= ephemeralLimit =
      Left (ProviderWorkerCounterexampleDidNotExceedLimit observedPeak ephemeralLimit)
  | observation /= frozenProviderWorkerEphemeralObservation =
      Left (ProviderWorkerCounterexampleObservationDrift observation)
  | replacementMetadata /= frozenProviderWorkerReplacementPackaging =
      Left (ProviderWorkerCounterexamplePackagingDrift replacement)
  | runtimeArchiveBytes /= 0 || runtimeProviderBinaryBytes /= 0 =
      Left
        ( ProviderWorkerCounterexampleRuntimeProviderWrite
            runtimeArchiveBytes
            runtimeProviderBinaryBytes
        )
  | otherwise =
      Right
        ProviderWorkerEphemeralClosure
          { providerWorkerClosureOldToNewEnvelope =
              (supersededEnvelope, replacementEnvelope)
          , providerWorkerClosureSupersededDisposition =
              ProviderWorkerEphemeralLimitExceeded observedPeak ephemeralLimit
          , providerWorkerClosureReplacementDisposition =
              ProviderWorkerRuntimeProviderOverlapEliminated
          }
 where
  causalProfile = providerWorkerCounterexampleCausalProfile counterexample
  supersededEnvelope = providerWorkerCounterexampleSupersededEnvelope counterexample
  replacementEnvelope = providerWorkerCounterexampleReplacementEnvelope counterexample
  observation = providerWorkerCounterexampleObservation counterexample
  observedPeak = providerWorkerKubeletPeakBytes observation
  ephemeralLimit = providerWorkerEnvelopeEphemeralBytes supersededEnvelope
  replacement = providerWorkerCounterexampleReplacementPackaging counterexample
  runtimeArchiveBytes = providerWorkerReplacementRuntimeArchiveBytes replacement
  runtimeProviderBinaryBytes = providerWorkerReplacementRuntimeProviderBinaryBytes replacement
  replacementMetadata =
    replacement
      { providerWorkerReplacementRuntimeArchiveBytes = 0
      , providerWorkerReplacementRuntimeProviderBinaryBytes = 0
      }

-- | Validate the frozen failure, constant-budget mapping, independent sizing
-- probe, and (once populated) exact live replacement observation.
validateProviderWorkerSchemaMemoryCounterexample
  :: ProviderWorkerSchemaMemoryCounterexample
  -> Either ProviderWorkerSchemaMemoryCounterexampleError ProviderWorkerSchemaMemoryStatus
validateProviderWorkerSchemaMemoryCounterexample counterexample
  | counterexample /= frozenProviderWorkerSchemaMemoryCounterexample =
      Left ProviderWorkerSchemaMemoryArtifactDrift
  | supersededTotal /= replacementTotal =
      Left ProviderWorkerSchemaMemoryNormalizedTotalChanged
  | addEnvelope backgroundDraw supersededTotal /= allocatable =
      Left ProviderWorkerSchemaMemoryAllocatableMismatch
  | addEnvelope backgroundDraw replacementTotal /= allocatable =
      Left ProviderWorkerSchemaMemoryAllocatableMismatch
  | providerWorkerSchemaOomMemoryPeakBytes supersededObservation
      < providerWorkerSchemaOomMemoryLimitBytes supersededObservation
      || providerWorkerSchemaOomKillCount supersededObservation == 0
      || providerWorkerSchemaOomDaemonRestartCount supersededObservation /= 0 =
      Left ProviderWorkerSchemaMemorySupersededFailureMissing
  | providerWorkerSchemaProbeUncappedPeakBytes sizingProbe
      > providerWorkerProductionChildReserveBytes
      || providerWorkerSchemaProbeUncappedOomKills sizingProbe /= 0
      || providerWorkerSchemaProbeHardLimitBytes sizingProbe
        /= mebibytes providerWorkerProductionMemoryMebibytes
      || providerWorkerSchemaProbeHardLimitPeakBytes sizingProbe
        > providerWorkerSchemaProbeHardLimitBytes sizingProbe
      || providerWorkerSchemaProbeHardLimitOomKills sizingProbe /= 0 =
      Left ProviderWorkerSchemaMemorySizingProbeInsufficient
  | otherwise =
      case providerWorkerSchemaCounterexampleLiveReplacement counterexample of
        Nothing -> Right ProviderWorkerSchemaMemoryPendingLiveReplacement
        Just liveObservation
          | providerWorkerSchemaLiveMemoryLimitBytes liveObservation
              /= providerWorkerEnvelopeMemoryBytes
                (providerWorkerPartitionEnvelope replacementPartition)
              || providerWorkerSchemaLiveMemoryPeakBytes liveObservation
                > providerWorkerSchemaLiveMemoryLimitBytes liveObservation
              || providerWorkerSchemaLiveOomKillCount liveObservation /= 0
              || providerWorkerSchemaLiveDaemonRestartCount liveObservation /= 0
              || not (providerWorkerSchemaLiveExactProviderCompletion liveObservation) ->
              Left ProviderWorkerSchemaMemoryLiveReplacementInsufficient
          | otherwise -> Right ProviderWorkerSchemaMemoryClosed
 where
  allocatable = providerWorkerSchemaCounterexampleAllocatable counterexample
  backgroundDraw = providerWorkerSchemaCounterexampleBackgroundDraw counterexample
  supersededPartition = providerWorkerSchemaCounterexampleSupersededPartition counterexample
  replacementPartition = providerWorkerSchemaCounterexampleReplacementPartition counterexample
  supersededTotal = partitionTotal supersededPartition
  replacementTotal = partitionTotal replacementPartition
  supersededObservation = providerWorkerSchemaCounterexampleSupersededObservation counterexample
  sizingProbe = providerWorkerSchemaCounterexampleSizingProbe counterexample

partitionTotal :: ProviderWorkerCapacityPartition -> ProviderWorkerResourceEnvelope
partitionTotal partition =
  addEnvelope
    (providerWorkerPartitionEnvelope partition)
    (providerWorkerPartitionIdleHeadroom partition)

addEnvelope
  :: ProviderWorkerResourceEnvelope
  -> ProviderWorkerResourceEnvelope
  -> ProviderWorkerResourceEnvelope
addEnvelope left right =
  ProviderWorkerResourceEnvelope
    { providerWorkerEnvelopeCpuMillicores =
        providerWorkerEnvelopeCpuMillicores left + providerWorkerEnvelopeCpuMillicores right
    , providerWorkerEnvelopeMemoryBytes =
        providerWorkerEnvelopeMemoryBytes left + providerWorkerEnvelopeMemoryBytes right
    , providerWorkerEnvelopeEphemeralBytes =
        providerWorkerEnvelopeEphemeralBytes left + providerWorkerEnvelopeEphemeralBytes right
    , providerWorkerEnvelopeDurableBytes =
        providerWorkerEnvelopeDurableBytes left + providerWorkerEnvelopeDurableBytes right
    }

kibibytes :: Natural -> Natural
kibibytes value = value * 1024

mebibytes :: Natural -> Natural
mebibytes value = kibibytes value * 1024

-- | Maximum admitted child-action deadline. Capacity configuration may select
-- a shorter deadline, but never one the fixed Provider transport cannot wait
-- out.
providerWorkerMaximumChildDeadlineMilliseconds :: Natural
providerWorkerMaximumChildDeadlineMilliseconds = 5 * 60 * 1000

-- | Bounded time after the child deadline for authenticated framing, authority
-- projection, response encoding, and the socket write.
providerWorkerResponseOverheadMilliseconds :: Natural
providerWorkerResponseOverheadMilliseconds = 30 * 1000

-- | Provider-only HTTP timeout. The arithmetic is exact and well inside 'Int'
-- on every supported architecture.
providerWorkerResponseTimeoutMicros :: Int
providerWorkerResponseTimeoutMicros =
  fromIntegral
    ( ( providerWorkerMaximumChildDeadlineMilliseconds
          + providerWorkerResponseOverheadMilliseconds
      )
        * 1000
    )

validateProviderWorkerChildDeadlineMilliseconds
  :: Natural -> Either ProviderWorkerBudgetError ()
validateProviderWorkerChildDeadlineMilliseconds deadline
  | deadline == 0 = Left ProviderWorkerChildDeadlineMustBePositive
  | deadline > providerWorkerMaximumChildDeadlineMilliseconds =
      Left
        ( ProviderWorkerChildDeadlineExceedsTransportMaximum
            deadline
            providerWorkerMaximumChildDeadlineMilliseconds
        )
  | otherwise = Right ()
