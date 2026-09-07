{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic role selection for every closed Provider intent.  The
-- assuming user is credential material, not an authorization identity: every
-- Provider effect runs under the one registered role selected here.
module Prodbox.ControlPlane.ProviderAssumedRoleSession
  ( ProviderRole (..)
  , ProviderAssumedRoleCounterexample (..)
  , ProviderAssumedRoleDisposition (..)
  , ProviderAssumedRoleClosure (..)
  , ProviderAssumedRoleCounterexampleError (..)
  , providerAssumedRoleCounterexampleId
  , lifecycleProviderRoleName
  , lifecycleProviderSessionName
  , lifecycleProviderSessionDurationSeconds
  , providerRoleForIntent
  , providerAssumeRoleRequest
  , lifecycleProviderAssumeRoleRequest
  , expectedLifecycleProviderBaseUserArn
  , expectedLifecycleProviderAssumedRoleArn
  , frozenProviderAssumedRoleCounterexample
  , validateProviderAssumedRoleCounterexample
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Aws.Native.Sts (AssumeRoleRequest (..))
import Prodbox.Capacity.ProviderWorkerBudget
  ( ProviderWorkerCounterexampleBackgroundLoad (OneRegisteredStackReconcile)
  , ProviderWorkerCounterexampleFaultSchedule (NoInjectedProviderFault)
  , ProviderWorkerCounterexampleTopology (OneFencedProviderWorkerOneSerializedChild)
  , ProviderWorkerEphemeralCausalProfile (..)
  , ProviderWorkerResourceEnvelope (..)
  )
import Prodbox.Lifecycle.DnsRecord (AwsAccountId, awsAccountIdText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent (..))

-- | The closed authorization role available to normal Provider work.
data ProviderRole = LifecycleProviderRole
  deriving (Eq, Show)

data ProviderAssumedRoleCounterexample = ProviderAssumedRoleCounterexample
  { providerAssumedRoleIdentity :: !Text
  , providerAssumedRoleCausalProfile :: !ProviderWorkerEphemeralCausalProfile
  , providerAssumedRoleSupersededEnvelope :: !ProviderWorkerResourceEnvelope
  , providerAssumedRoleReplacementEnvelope :: !ProviderWorkerResourceEnvelope
  , providerAssumedRoleBaseCallerArn :: !Text
  , providerAssumedRoleRequestedRoleArn :: !Text
  , providerAssumedRoleSessionName :: !Text
  , providerAssumedRoleDurationSeconds :: !Natural
  , providerAssumedRoleReplacementCallerArn :: !Text
  }
  deriving (Eq, Show)

data ProviderAssumedRoleDisposition
  = ProviderBaseUserSignedEffects !Text
  | ProviderRegisteredRoleSignedEffects !Text
  deriving (Eq, Show)

data ProviderAssumedRoleClosure = ProviderAssumedRoleClosure
  { providerAssumedRoleOldToNewEnvelope
      :: !(ProviderWorkerResourceEnvelope, ProviderWorkerResourceEnvelope)
  , providerAssumedRoleSupersededDisposition :: !ProviderAssumedRoleDisposition
  , providerAssumedRoleReplacementDisposition :: !ProviderAssumedRoleDisposition
  , providerAssumedRoleClosedRequest :: !AssumeRoleRequest
  }
  deriving (Eq, Show)

data ProviderAssumedRoleCounterexampleError
  = ProviderAssumedRoleIdentityDrift
  | ProviderAssumedRoleCausalProfileDrift
  | ProviderAssumedRoleEnvelopeChanged
  | ProviderAssumedRoleBaseCallerDrift
  | ProviderAssumedRoleRequestedRoleDrift
  | ProviderAssumedRoleSessionNameDrift
  | ProviderAssumedRoleDurationDrift
  | ProviderAssumedRoleReplacementCallerDrift
  deriving (Eq, Show)

providerAssumedRoleCounterexampleId :: Text
providerAssumedRoleCounterexampleId =
  "LIFECYCLE-PROVIDER-ASSUME-ROLE-SESSION-NOT-BOUND-2026-09-06"

lifecycleProviderRoleName :: Text
lifecycleProviderRoleName = "prodbox-lifecycle-provider"

lifecycleProviderSessionName :: Text
lifecycleProviderSessionName = "prodbox-provider-worker"

-- | AWS STS requires at least 900 seconds.  Rank-2 callback scope, rather than
-- remote credential expiry, prevents use after the Provider action returns.
lifecycleProviderSessionDurationSeconds :: Natural
lifecycleProviderSessionDurationSeconds = 900

-- | Exhaustive selection from the closed signed intent.  There is no
-- caller-controlled role name and a new intent constructor is incomplete until
-- its role is assigned here.
providerRoleForIntent :: ProviderIntent -> ProviderRole
providerRoleForIntent intent = case intent of
  ReconcileRegisteredStack {} -> LifecycleProviderRole
  DestroyRegisteredStack {} -> LifecycleProviderRole
  ObserveRegisteredStack _ -> LifecycleProviderRole
  ReadBackRegisteredStack _ -> LifecycleProviderRole
  BoundedScratchCheckpoint _ -> LifecycleProviderRole
  ReconcileSesSendingIdentity _ -> LifecycleProviderRole
  ReconcileSesDkim _ -> LifecycleProviderRole
  ReconcileSesReceiptRules _ -> LifecycleProviderRole
  ReconcileSesCaptureBucket _ -> LifecycleProviderRole
  ReconcileSesDns _ -> LifecycleProviderRole
  ObservePublicARecord _ -> LifecycleProviderRole
  ReconcilePublicARecord _ -> LifecycleProviderRole
  ReapTestEbsVolumes _ -> LifecycleProviderRole
  ObserveSpotPrice _ -> LifecycleProviderRole
  ObserveOperationalIdentity -> LifecycleProviderRole
  ObserveProviderReadiness _ -> LifecycleProviderRole
  IssueEksClientAuth _ -> LifecycleProviderRole
  ObserveTestEbsVolumes _ -> LifecycleProviderRole
  ObserveValidationHostedZones _ -> LifecycleProviderRole
  ReapValidationHostedZones _ -> LifecycleProviderRole
  ObserveRetainedEbsVolumes _ -> LifecycleProviderRole
  ReapRetainedEbsVolumes _ -> LifecycleProviderRole
  ObserveDns01ChallengeRecords _ _ -> LifecycleProviderRole
  ObserveEksIamRoleFamily _ _ -> LifecycleProviderRole
  ReapEksIamRoleFamily _ _ -> LifecycleProviderRole
  ObserveEksLoadBalancerControllerFamily _ _ -> LifecycleProviderRole
  ReapEksLoadBalancerControllerFamily _ _ -> LifecycleProviderRole
  ObserveEksClusterIdentity _ -> LifecycleProviderRole
  ObserveProviderAwsScope -> LifecycleProviderRole
  ObserveOwnedResourceTags _ -> LifecycleProviderRole
  ObserveNativeStackFamily _ _ -> LifecycleProviderRole
  ReapNativeStackFamily {} -> LifecycleProviderRole

providerAssumeRoleRequest :: ProviderIntent -> AwsAccountId -> AssumeRoleRequest
providerAssumeRoleRequest intent =
  assumeRoleRequestFor (providerRoleForIntent intent)

lifecycleProviderAssumeRoleRequest :: AwsAccountId -> AssumeRoleRequest
lifecycleProviderAssumeRoleRequest = assumeRoleRequestFor LifecycleProviderRole

assumeRoleRequestFor :: ProviderRole -> AwsAccountId -> AssumeRoleRequest
assumeRoleRequestFor role account =
  AssumeRoleRequest
    { assumeRoleArn = providerRoleArn account role
    , assumeRoleSessionName = lifecycleProviderSessionName
    , assumeRoleDurationSeconds = lifecycleProviderSessionDurationSeconds
    }

providerRoleArn :: AwsAccountId -> ProviderRole -> Text
providerRoleArn account role =
  "arn:aws:iam::"
    <> awsAccountIdText account
    <> ":role/"
    <> roleName role

roleName :: ProviderRole -> Text
roleName role = case role of
  LifecycleProviderRole -> lifecycleProviderRoleName

expectedLifecycleProviderAssumedRoleArn :: AwsAccountId -> Text
expectedLifecycleProviderAssumedRoleArn account =
  "arn:aws:sts::"
    <> awsAccountIdText account
    <> ":assumed-role/"
    <> lifecycleProviderRoleName
    <> "/"
    <> lifecycleProviderSessionName

expectedLifecycleProviderBaseUserArn :: AwsAccountId -> Text
expectedLifecycleProviderBaseUserArn account =
  "arn:aws:iam::"
    <> awsAccountIdText account
    <> ":user/"
    <> lifecycleProviderRoleName

frozenProviderAssumedRoleCounterexample :: ProviderAssumedRoleCounterexample
frozenProviderAssumedRoleCounterexample =
  ProviderAssumedRoleCounterexample
    { providerAssumedRoleIdentity = providerAssumedRoleCounterexampleId
    , providerAssumedRoleCausalProfile = frozenCausalProfile
    , providerAssumedRoleSupersededEnvelope = frozenEnvelope
    , providerAssumedRoleReplacementEnvelope = frozenEnvelope
    , providerAssumedRoleBaseCallerArn = frozenBaseCallerArn
    , providerAssumedRoleRequestedRoleArn = frozenRequestedRoleArn
    , providerAssumedRoleSessionName = lifecycleProviderSessionName
    , providerAssumedRoleDurationSeconds = lifecycleProviderSessionDurationSeconds
    , providerAssumedRoleReplacementCallerArn = frozenReplacementCallerArn
    }

validateProviderAssumedRoleCounterexample
  :: ProviderAssumedRoleCounterexample
  -> Either ProviderAssumedRoleCounterexampleError ProviderAssumedRoleClosure
validateProviderAssumedRoleCounterexample counterexample
  | providerAssumedRoleIdentity counterexample /= providerAssumedRoleCounterexampleId =
      Left ProviderAssumedRoleIdentityDrift
  | providerAssumedRoleCausalProfile counterexample /= frozenCausalProfile =
      Left ProviderAssumedRoleCausalProfileDrift
  | supersededEnvelope /= replacementEnvelope || replacementEnvelope /= frozenEnvelope =
      Left ProviderAssumedRoleEnvelopeChanged
  | providerAssumedRoleBaseCallerArn counterexample /= frozenBaseCallerArn =
      Left ProviderAssumedRoleBaseCallerDrift
  | providerAssumedRoleRequestedRoleArn counterexample /= frozenRequestedRoleArn =
      Left ProviderAssumedRoleRequestedRoleDrift
  | providerAssumedRoleSessionName counterexample /= lifecycleProviderSessionName =
      Left ProviderAssumedRoleSessionNameDrift
  | providerAssumedRoleDurationSeconds counterexample /= lifecycleProviderSessionDurationSeconds =
      Left ProviderAssumedRoleDurationDrift
  | providerAssumedRoleReplacementCallerArn counterexample /= frozenReplacementCallerArn =
      Left ProviderAssumedRoleReplacementCallerDrift
  | otherwise =
      Right
        ProviderAssumedRoleClosure
          { providerAssumedRoleOldToNewEnvelope = (supersededEnvelope, replacementEnvelope)
          , providerAssumedRoleSupersededDisposition =
              ProviderBaseUserSignedEffects frozenBaseCallerArn
          , providerAssumedRoleReplacementDisposition =
              ProviderRegisteredRoleSignedEffects frozenReplacementCallerArn
          , providerAssumedRoleClosedRequest =
              AssumeRoleRequest
                { assumeRoleArn = frozenRequestedRoleArn
                , assumeRoleSessionName = lifecycleProviderSessionName
                , assumeRoleDurationSeconds = lifecycleProviderSessionDurationSeconds
                }
          }
 where
  supersededEnvelope = providerAssumedRoleSupersededEnvelope counterexample
  replacementEnvelope = providerAssumedRoleReplacementEnvelope counterexample

frozenAccountId :: Text
frozenAccountId = "751103452346"

frozenBaseCallerArn :: Text
frozenBaseCallerArn =
  "arn:aws:iam::" <> frozenAccountId <> ":user/prodbox-lifecycle-provider"

frozenRequestedRoleArn :: Text
frozenRequestedRoleArn =
  "arn:aws:iam::" <> frozenAccountId <> ":role/" <> lifecycleProviderRoleName

frozenReplacementCallerArn :: Text
frozenReplacementCallerArn =
  "arn:aws:sts::"
    <> frozenAccountId
    <> ":assumed-role/"
    <> lifecycleProviderRoleName
    <> "/"
    <> lifecycleProviderSessionName

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
