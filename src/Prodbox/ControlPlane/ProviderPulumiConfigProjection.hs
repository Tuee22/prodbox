{-# LANGUAGE OverloadedStrings #-}

-- | Pure projection of typed Provider stack configuration into the Pulumi
-- preview boundary, including the frozen observe-first counterexample that
-- requires it. The values are passed as individual argv entries; no ambient
-- configuration source participates.
module Prodbox.ControlPlane.ProviderPulumiConfigProjection
  ( ProviderPulumiConfigCounterexample (..)
  , ProviderPulumiConfigDisposition (..)
  , ProviderPulumiConfigClosure (..)
  , ProviderPulumiConfigCounterexampleError (..)
  , providerPulumiConfigCounterexampleId
  , providerPulumiPreviewArguments
  , providerPulumiDiffArguments
  , providerRunMarkerProgramBindings
  , providerRunMarkerConfiguration
  , frozenProviderPulumiConfigCounterexample
  , validateProviderPulumiConfigCounterexample
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerCounterexampleBackgroundLoad (OneRegisteredStackReconcile)
  , ProviderWorkerCounterexampleFaultSchedule (NoInjectedProviderFault)
  , ProviderWorkerCounterexampleTopology (OneFencedProviderWorkerOneSerializedChild)
  , ProviderWorkerEphemeralCausalProfile (..)
  , ProviderWorkerResourceEnvelope (..)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRunMarker
  , providerRunMarkerRunScope
  , providerRunMarkerSubmission
  )

data ProviderPulumiConfigCounterexample = ProviderPulumiConfigCounterexample
  { providerPulumiConfigIdentity :: !Text
  , providerPulumiConfigCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerPulumiConfigSupersededEnvelope :: !ProviderWorkerResourceEnvelope
  , providerPulumiConfigReplacementEnvelope :: !ProviderWorkerResourceEnvelope
  , providerPulumiConfigExpectedValues :: ![(String, String)]
  , providerPulumiConfigObservedMissingKeys :: ![String]
  , providerPulumiConfigSupersededPreviewArguments :: ![String]
  , providerPulumiConfigReplacementPreviewArguments :: ![String]
  }
  deriving (Eq, Show)

data ProviderPulumiConfigDisposition
  = ProviderPulumiConfigMissing ![String]
  | ProviderPulumiConfigProjected ![(String, String)]
  deriving (Eq, Show)

data ProviderPulumiConfigClosure = ProviderPulumiConfigClosure
  { providerPulumiConfigOldToNewEnvelope
      :: !(ProviderWorkerResourceEnvelope, ProviderWorkerResourceEnvelope)
  , providerPulumiConfigSupersededDisposition :: !ProviderPulumiConfigDisposition
  , providerPulumiConfigReplacementDisposition :: !ProviderPulumiConfigDisposition
  }
  deriving (Eq, Show)

data ProviderPulumiConfigCounterexampleError
  = ProviderPulumiConfigIdentityDrift
  | ProviderPulumiConfigCausalProfileDrift
  | ProviderPulumiConfigEnvelopeChanged
  | ProviderPulumiConfigExpectedValuesDrift
  | ProviderPulumiConfigObservedFailureDrift
  | ProviderPulumiConfigSupersededProjectionDrift
  | ProviderPulumiConfigReplacementProjectionDrift
  deriving (Eq, Show)

providerPulumiConfigCounterexampleId :: Text
providerPulumiConfigCounterexampleId =
  "PROVIDER-WORKER-PULUMI-STACK-CONFIG-ABSENT-2026-09-05"

-- | The exact Pulumi preview argv. Typed stack configuration is projected on
-- every observation, including after a fresh Worker image has discarded any
-- image-local @Pulumi.<stack>.yaml@ file.
providerPulumiPreviewArguments :: String -> [(String, String)] -> [String]
providerPulumiPreviewArguments selectedStack configuration =
  [ "preview"
  , "--stack"
  , selectedStack
  , "--expect-no-changes"
  , "--non-interactive"
  , "--color"
  , "never"
  ]
    <> concatMap configArgument configuration
 where
  configArgument (key, value) = ["--config", key <> "=" <> value]

-- A diagnostic preview permits changes and requests structured output. Secret
-- display is never enabled; the consumer also discards every property value.
providerPulumiDiffArguments :: String -> [(String, String)] -> [String]
providerPulumiDiffArguments selectedStack configuration =
  [ "preview"
  , "--stack"
  , selectedStack
  , "--json"
  , "--diff"
  , "--suppress-outputs"
  , "--non-interactive"
  , "--color"
  , "never"
  ]
    <> concatMap (\(key, value) -> ["--config", key <> "=" <> value]) configuration

-- | Sprint 7.41: how a run marker reaches the resources a create makes.
--
-- Each pair is a Pulumi configuration key and the provider tag key the program
-- stamps from it.  Stating both here is what lets one test assert that the
-- value this code sets and the value the committed program reads are the same
-- value: the two live in different languages, and a rename on either side is
-- otherwise a silent no-op that stamps an empty tag.
--
-- The four programs do not all take one.  @aws-ses@ is the retained long-lived
-- stack, and a per-run marker on it would tell a per-run sweep that a stack
-- nothing is allowed to reap belongs to the run currently reaping.
providerRunMarkerProgramBindings :: [(String, String)]
providerRunMarkerProgramBindings =
  [ (providerRunScopeConfigurationKey, "prodbox.io/run-scope")
  , (providerSubmissionConfigurationKey, "prodbox.io/submission")
  ]

-- | The marker projected into the configuration the preview and the apply both
-- carry.  Projecting it onto only one of the two is the defect
-- 'providerPulumiConfigCounterexampleId' froze.
providerRunMarkerConfiguration :: ProviderRunMarker -> [(String, String)]
providerRunMarkerConfiguration marker =
  [ (providerRunScopeConfigurationKey, Text.unpack (providerRunMarkerRunScope marker))
  , (providerSubmissionConfigurationKey, Text.unpack (providerRunMarkerSubmission marker))
  ]

providerRunScopeConfigurationKey :: String
providerRunScopeConfigurationKey = "prodboxRunScope"

providerSubmissionConfigurationKey :: String
providerSubmissionConfigurationKey = "prodboxSubmission"

frozenProviderPulumiConfigCounterexample :: ProviderPulumiConfigCounterexample
frozenProviderPulumiConfigCounterexample =
  ProviderPulumiConfigCounterexample
    { providerPulumiConfigIdentity = providerPulumiConfigCounterexampleId
    , providerPulumiConfigCausalProfile = frozenCausalProfile
    , providerPulumiConfigSupersededEnvelope = frozenEnvelope
    , providerPulumiConfigReplacementEnvelope = frozenEnvelope
    , providerPulumiConfigExpectedValues = frozenConfiguration
    , providerPulumiConfigObservedMissingKeys = fmap fst frozenConfiguration
    , providerPulumiConfigSupersededPreviewArguments =
        providerPulumiPreviewArguments frozenStack []
    , providerPulumiConfigReplacementPreviewArguments =
        providerPulumiPreviewArguments frozenStack frozenConfiguration
    }

validateProviderPulumiConfigCounterexample
  :: ProviderPulumiConfigCounterexample
  -> Either ProviderPulumiConfigCounterexampleError ProviderPulumiConfigClosure
validateProviderPulumiConfigCounterexample counterexample
  | providerPulumiConfigIdentity counterexample /= providerPulumiConfigCounterexampleId =
      Left ProviderPulumiConfigIdentityDrift
  | providerPulumiConfigCausalProfile counterexample /= frozenCausalProfile =
      Left ProviderPulumiConfigCausalProfileDrift
  | supersededEnvelope /= replacementEnvelope || replacementEnvelope /= frozenEnvelope =
      Left ProviderPulumiConfigEnvelopeChanged
  | expectedValues /= frozenConfiguration =
      Left ProviderPulumiConfigExpectedValuesDrift
  | providerPulumiConfigObservedMissingKeys counterexample /= fmap fst expectedValues =
      Left ProviderPulumiConfigObservedFailureDrift
  | providerPulumiConfigSupersededPreviewArguments counterexample
      /= providerPulumiPreviewArguments frozenStack [] =
      Left ProviderPulumiConfigSupersededProjectionDrift
  | providerPulumiConfigReplacementPreviewArguments counterexample
      /= providerPulumiPreviewArguments frozenStack expectedValues =
      Left ProviderPulumiConfigReplacementProjectionDrift
  | otherwise =
      Right
        ProviderPulumiConfigClosure
          { providerPulumiConfigOldToNewEnvelope =
              (supersededEnvelope, replacementEnvelope)
          , providerPulumiConfigSupersededDisposition =
              ProviderPulumiConfigMissing (fmap fst expectedValues)
          , providerPulumiConfigReplacementDisposition =
              ProviderPulumiConfigProjected expectedValues
          }
 where
  supersededEnvelope = providerPulumiConfigSupersededEnvelope counterexample
  replacementEnvelope = providerPulumiConfigReplacementEnvelope counterexample
  expectedValues = providerPulumiConfigExpectedValues counterexample

frozenStack :: String
frozenStack = "aws-eks-subzone"

frozenConfiguration :: [(String, String)]
frozenConfiguration =
  [ ("parentZoneId", "ZPARENT123")
  , ("subzoneName", "aws.example.test")
  ]

frozenCausalProfile :: ProviderWorkerEphemeralCausalProfile
frozenCausalProfile =
  ProviderWorkerEphemeralCausalProfile
    { providerWorkerCounterexampleTopology = OneFencedProviderWorkerOneSerializedChild
    , providerWorkerCounterexampleBackgroundLoad = OneRegisteredStackReconcile
    , providerWorkerCounterexampleFaultSchedule = NoInjectedProviderFault
    }

frozenEnvelope :: ProviderWorkerResourceEnvelope
frozenEnvelope =
  ProviderWorkerResourceEnvelope
    { providerWorkerEnvelopeCpuMillicores = 100
    , providerWorkerEnvelopeMemoryBytes = 1120 * 1024 * 1024
    , providerWorkerEnvelopeEphemeralBytes = 256 * 1024 * 1024
    , providerWorkerEnvelopeDurableBytes = 0
    }
