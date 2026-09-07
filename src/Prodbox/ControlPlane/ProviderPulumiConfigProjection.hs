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
  , frozenProviderPulumiConfigCounterexample
  , validateProviderPulumiConfigCounterexample
  )
where

import Data.Text (Text)
import Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerCounterexampleBackgroundLoad (OneRegisteredStackReconcile)
  , ProviderWorkerCounterexampleFaultSchedule (NoInjectedProviderFault)
  , ProviderWorkerCounterexampleTopology (OneFencedProviderWorkerOneSerializedChild)
  , ProviderWorkerEphemeralCausalProfile (..)
  , ProviderWorkerResourceEnvelope (..)
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
