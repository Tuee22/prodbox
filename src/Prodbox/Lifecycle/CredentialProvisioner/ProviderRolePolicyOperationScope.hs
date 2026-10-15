{-# LANGUAGE OverloadedStrings #-}

-- | Revision-bound durable operation scope for Lifecycle-provider IAM repair.
-- A completed credential operation is immutable. Changing the canonical role
-- policy therefore selects a successor operation instead of reinterpreting the
-- retained receipt under new executable behavior.
module Prodbox.Lifecycle.CredentialProvisioner.ProviderRolePolicyOperationScope
  ( ProviderRolePolicyOperationCounterexample (..)
  , ProviderRolePolicyOperationDisposition (..)
  , ProviderRolePolicyOperationClosure (..)
  , ProviderRolePolicyOperationCounterexampleError (..)
  , providerRolePolicyOperationCounterexampleId
  , providerRolePolicyOperationRevision
  , providerRolePolicyOperationRevisionFor
  , providerRolePolicyOperationScope
  , frozenProviderRolePolicyOperationCounterexample
  , validateProviderRolePolicyOperationCounterexample
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerCounterexampleBackgroundLoad (OneRegisteredStackReconcile)
  , ProviderWorkerCounterexampleFaultSchedule (NoInjectedProviderFault)
  , ProviderWorkerCounterexampleTopology (OneFencedProviderWorkerOneSerializedChild)
  , ProviderWorkerEphemeralCausalProfile (..)
  , ProviderWorkerResourceEnvelope (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( lifecycleProviderRolePolicyDocument
  )

data ProviderRolePolicyOperationCounterexample = ProviderRolePolicyOperationCounterexample
  { providerRolePolicyOperationIdentity :: !Text
  , providerRolePolicyOperationCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerRolePolicyOperationSupersededEnvelope :: !ProviderWorkerResourceEnvelope
  , providerRolePolicyOperationReplacementEnvelope :: !ProviderWorkerResourceEnvelope
  , providerRolePolicyOperationSupersededScope :: !Text
  , providerRolePolicyOperationReplacementRevision :: !Text
  , providerRolePolicyOperationReplacementScope :: !Text
  , providerRolePolicyOperationMutatedDocument :: !Text
  }
  deriving (Eq, Show)

data ProviderRolePolicyOperationDisposition
  = ProviderCompletedCredentialReceiptReplayed !Text
  | ProviderRevisedIamProgramScheduled !Text
  deriving (Eq, Show)

data ProviderRolePolicyOperationClosure = ProviderRolePolicyOperationClosure
  { providerRolePolicyOperationOldToNewEnvelope
      :: !(ProviderWorkerResourceEnvelope, ProviderWorkerResourceEnvelope)
  , providerRolePolicyOperationSupersededDisposition
      :: !ProviderRolePolicyOperationDisposition
  , providerRolePolicyOperationReplacementDisposition
      :: !ProviderRolePolicyOperationDisposition
  }
  deriving (Eq, Show)

data ProviderRolePolicyOperationCounterexampleError
  = ProviderRolePolicyOperationIdentityDrift
  | ProviderRolePolicyOperationCausalProfileDrift
  | ProviderRolePolicyOperationEnvelopeChanged
  | ProviderRolePolicyOperationSupersededScopeDrift
  | ProviderRolePolicyOperationRevisionDrift
  | ProviderRolePolicyOperationReplacementScopeDrift
  | ProviderRolePolicyOperationMutationNotDetected
  deriving (Eq, Show)

providerRolePolicyOperationCounterexampleId :: Text
providerRolePolicyOperationCounterexampleId =
  "LIFECYCLE-PROVIDER-ASSUMED-ROLE-ROUTE53-CREATE-DENIED-2026-09-06"

-- | Hash domain and canonical policy bytes are both explicit. The value is
-- secret-free and is used only to namespace a durable operation.
providerRolePolicyOperationRevisionFor :: Text -> Text
providerRolePolicyOperationRevisionFor policyDocument =
  decodeUtf8
    ( hexSha256
        ( encodeUtf8
            ( "prodbox-lifecycle-provider-role-policy-operation-v1\NUL"
                <> policyDocument
            )
        )
    )

providerRolePolicyOperationRevision :: Text
providerRolePolicyOperationRevision =
  providerRolePolicyOperationRevisionFor lifecycleProviderRolePolicyDocument

providerRolePolicyOperationScope :: Text -> Text
providerRolePolicyOperationScope operationScope =
  operationScope
    <> ":role-policy-sha256-"
    <> providerRolePolicyOperationRevision

frozenProviderRolePolicyOperationCounterexample
  :: ProviderRolePolicyOperationCounterexample
frozenProviderRolePolicyOperationCounterexample =
  ProviderRolePolicyOperationCounterexample
    { providerRolePolicyOperationIdentity = providerRolePolicyOperationCounterexampleId
    , providerRolePolicyOperationCausalProfile = frozenCausalProfile
    , providerRolePolicyOperationSupersededEnvelope = frozenEnvelope
    , providerRolePolicyOperationReplacementEnvelope = frozenEnvelope
    , providerRolePolicyOperationSupersededScope = frozenSupersededScope
    , providerRolePolicyOperationReplacementRevision = frozenReplacementRevision
    , providerRolePolicyOperationReplacementScope =
        frozenReplacementScope
    , providerRolePolicyOperationMutatedDocument = frozenMutatedPolicyDocument
    }

validateProviderRolePolicyOperationCounterexample
  :: ProviderRolePolicyOperationCounterexample
  -> Either
       ProviderRolePolicyOperationCounterexampleError
       ProviderRolePolicyOperationClosure
validateProviderRolePolicyOperationCounterexample counterexample
  | providerRolePolicyOperationIdentity counterexample
      /= providerRolePolicyOperationCounterexampleId =
      Left ProviderRolePolicyOperationIdentityDrift
  | providerRolePolicyOperationCausalProfile counterexample /= frozenCausalProfile =
      Left ProviderRolePolicyOperationCausalProfileDrift
  | supersededEnvelope /= replacementEnvelope || replacementEnvelope /= frozenEnvelope =
      Left ProviderRolePolicyOperationEnvelopeChanged
  | providerRolePolicyOperationSupersededScope counterexample /= frozenSupersededScope =
      Left ProviderRolePolicyOperationSupersededScopeDrift
  | providerRolePolicyOperationRevision /= frozenReplacementRevision =
      Left ProviderRolePolicyOperationRevisionDrift
  | providerRolePolicyOperationReplacementRevision counterexample
      /= frozenReplacementRevision =
      Left ProviderRolePolicyOperationRevisionDrift
  | providerRolePolicyOperationReplacementScope counterexample
      /= frozenReplacementScope =
      Left ProviderRolePolicyOperationReplacementScopeDrift
  | providerRolePolicyOperationRevisionFor
      (providerRolePolicyOperationMutatedDocument counterexample)
      == providerRolePolicyOperationRevision =
      Left ProviderRolePolicyOperationMutationNotDetected
  | otherwise =
      Right
        ProviderRolePolicyOperationClosure
          { providerRolePolicyOperationOldToNewEnvelope =
              (supersededEnvelope, replacementEnvelope)
          , providerRolePolicyOperationSupersededDisposition =
              ProviderCompletedCredentialReceiptReplayed frozenSupersededScope
          , providerRolePolicyOperationReplacementDisposition =
              ProviderRevisedIamProgramScheduled frozenReplacementScope
          }
 where
  supersededEnvelope = providerRolePolicyOperationSupersededEnvelope counterexample
  replacementEnvelope = providerRolePolicyOperationReplacementEnvelope counterexample

frozenSupersededScope :: Text
frozenSupersededScope = "cascade-qualification:pre-1"

-- | The revision of the current policy document. Re-frozen when the policy was
-- completed against the CLI verbs its interpreters run (the SES receipt-rule and
-- DKIM observers, the capture-bucket tagging calls, and the owned-resource tag
-- listing); the value before that was
-- @bacc2854e31887da758e66bf3d8574e8399086511289ea57d59f75bd8e55394a@. The
-- revision is a function of the document, so it moves with every deliberate
-- policy change, and the next run selects a successor operation by it.
frozenReplacementRevision :: Text
frozenReplacementRevision =
  "209a4b7eef1842483983e994116c816ccd872070bdc210aa1f31f697fa7d34d7"

frozenReplacementScope :: Text
frozenReplacementScope =
  frozenSupersededScope
    <> ":role-policy-sha256-"
    <> frozenReplacementRevision

-- Removing the exact live-denied action is the mutation exercise. The Route
-- 53 policy counterexample separately freezes the complete action set.
frozenMutatedPolicyDocument :: Text
frozenMutatedPolicyDocument =
  Text.replace
    "\"route53:CreateHostedZone\","
    ""
    lifecycleProviderRolePolicyDocument

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
