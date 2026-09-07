{-# LANGUAGE OverloadedStrings #-}

-- | Closed Route 53 action projection for the fenced Lifecycle-provider role.
-- The frozen counterexample keeps the live denied-create failure and its
-- resource-neutral replacement auditable independently of the IAM renderer.
module Prodbox.Lifecycle.CredentialProvisioner.ProviderRoute53Policy
  ( ProviderRoute53PolicyCounterexample (..)
  , ProviderRoute53PolicyDisposition (..)
  , ProviderRoute53PolicyClosure (..)
  , ProviderRoute53PolicyCounterexampleError (..)
  , providerRoute53PolicyCounterexampleId
  , providerRoute53RecordActions
  , providerRoute53HostedZoneLifecycleActions
  , providerRoute53Actions
  , frozenProviderRoute53PolicyCounterexample
  , validateProviderRoute53PolicyCounterexample
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

data ProviderRoute53PolicyCounterexample = ProviderRoute53PolicyCounterexample
  { providerRoute53PolicyIdentity :: !Text
  , providerRoute53PolicyCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerRoute53PolicySupersededEnvelope :: !ProviderWorkerResourceEnvelope
  , providerRoute53PolicyReplacementEnvelope :: !ProviderWorkerResourceEnvelope
  , providerRoute53PolicyRegisteredSubzoneActions :: ![Text]
  , providerRoute53PolicySupersededActions :: ![Text]
  , providerRoute53PolicyReplacementActions :: ![Text]
  }
  deriving (Eq, Show)

data ProviderRoute53PolicyDisposition
  = ProviderRoute53HostedZoneCreateDenied
  | ProviderRoute53RegisteredSubzoneAuthorized ![Text]
  deriving (Eq, Show)

data ProviderRoute53PolicyClosure = ProviderRoute53PolicyClosure
  { providerRoute53PolicyOldToNewEnvelope
      :: !(ProviderWorkerResourceEnvelope, ProviderWorkerResourceEnvelope)
  , providerRoute53PolicySupersededDisposition :: !ProviderRoute53PolicyDisposition
  , providerRoute53PolicyReplacementDisposition :: !ProviderRoute53PolicyDisposition
  }
  deriving (Eq, Show)

data ProviderRoute53PolicyCounterexampleError
  = ProviderRoute53PolicyIdentityDrift
  | ProviderRoute53PolicyCausalProfileDrift
  | ProviderRoute53PolicyEnvelopeChanged
  | ProviderRoute53PolicyRegisteredActionsDrift
  | ProviderRoute53PolicySupersededActionsDrift
  | ProviderRoute53PolicyReplacementActionsDrift
  deriving (Eq, Show)

providerRoute53PolicyCounterexampleId :: Text
providerRoute53PolicyCounterexampleId =
  "LIFECYCLE-PROVIDER-ROUTE53-HOSTED-ZONE-CREATE-DENIED-2026-09-05"

providerRoute53RecordActions :: [Text]
providerRoute53RecordActions =
  [ "route53:ChangeResourceRecordSets"
  , "route53:GetChange"
  , "route53:GetHostedZone"
  , "route53:ListResourceRecordSets"
  ]

providerRoute53HostedZoneLifecycleActions :: [Text]
providerRoute53HostedZoneLifecycleActions =
  [ "route53:ChangeTagsForResource"
  , "route53:CreateHostedZone"
  , "route53:DeleteHostedZone"
  , "route53:ListHostedZones"
  , "route53:ListTagsForResource"
  ]

providerRoute53Actions :: [Text]
providerRoute53Actions =
  providerRoute53RecordActions <> providerRoute53HostedZoneLifecycleActions

frozenProviderRoute53PolicyCounterexample :: ProviderRoute53PolicyCounterexample
frozenProviderRoute53PolicyCounterexample =
  ProviderRoute53PolicyCounterexample
    { providerRoute53PolicyIdentity = providerRoute53PolicyCounterexampleId
    , providerRoute53PolicyCausalProfile = frozenCausalProfile
    , providerRoute53PolicySupersededEnvelope = frozenEnvelope
    , providerRoute53PolicyReplacementEnvelope = frozenEnvelope
    , providerRoute53PolicyRegisteredSubzoneActions = providerRoute53Actions
    , providerRoute53PolicySupersededActions = providerRoute53RecordActions
    , providerRoute53PolicyReplacementActions = providerRoute53Actions
    }

validateProviderRoute53PolicyCounterexample
  :: ProviderRoute53PolicyCounterexample
  -> Either ProviderRoute53PolicyCounterexampleError ProviderRoute53PolicyClosure
validateProviderRoute53PolicyCounterexample counterexample
  | providerRoute53PolicyIdentity counterexample /= providerRoute53PolicyCounterexampleId =
      Left ProviderRoute53PolicyIdentityDrift
  | providerRoute53PolicyCausalProfile counterexample /= frozenCausalProfile =
      Left ProviderRoute53PolicyCausalProfileDrift
  | supersededEnvelope /= replacementEnvelope || replacementEnvelope /= frozenEnvelope =
      Left ProviderRoute53PolicyEnvelopeChanged
  | providerRoute53PolicyRegisteredSubzoneActions counterexample /= providerRoute53Actions =
      Left ProviderRoute53PolicyRegisteredActionsDrift
  | providerRoute53PolicySupersededActions counterexample /= providerRoute53RecordActions =
      Left ProviderRoute53PolicySupersededActionsDrift
  | providerRoute53PolicyReplacementActions counterexample /= providerRoute53Actions =
      Left ProviderRoute53PolicyReplacementActionsDrift
  | otherwise =
      Right
        ProviderRoute53PolicyClosure
          { providerRoute53PolicyOldToNewEnvelope =
              (supersededEnvelope, replacementEnvelope)
          , providerRoute53PolicySupersededDisposition =
              ProviderRoute53HostedZoneCreateDenied
          , providerRoute53PolicyReplacementDisposition =
              ProviderRoute53RegisteredSubzoneAuthorized providerRoute53Actions
          }
 where
  supersededEnvelope = providerRoute53PolicySupersededEnvelope counterexample
  replacementEnvelope = providerRoute53PolicyReplacementEnvelope counterexample

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
