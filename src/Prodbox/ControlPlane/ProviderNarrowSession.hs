{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes #-}

-- | Provider-Worker-local closed effects and rank-2 narrow session.
--
-- The capability registry is exhaustive over the eight normal provider
-- actions.  It contains no credential/admin/SMTP-IAM, generic AWS, Vault,
-- object-store, subprocess, or Authority-state escape arm.
module Prodbox.ControlPlane.ProviderNarrowSession
  ( ApplyFailure (..)
  , ProviderEffectObservation (..)
  , ProviderMutation (..)
  , ProviderReadOnly (..)
  , ProviderIntentCapabilities (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderIntentOperation (..)
  , operationForProviderIntent
  )
where

import Data.Text (Text)
import Prodbox.Ses.InviteEvidence (InviteMailPublicKey)

import Prodbox.ControlPlane.ProviderCredentialSession
  ( ProviderCredentialSessionBinding
  )
import Prodbox.Lifecycle.AwsTestCanary (TestVpcCanaryRequest)
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( ProviderEvidence
  , ProviderEvidenceBound
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
  , ProviderAuditControl
  , ProviderAuditTarget
  , ProviderCheckpointRef
  , ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderNativeStackFamilyRef
  , ProviderOwnedTagQuery
  , ProviderReadinessProbe
  , ProviderRevision
  , ProviderRunMarker
  , ProviderSpotPriceQuery
  , ProviderStackConfig
  , ProviderStackRef
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  )
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings

-- | Authoritative observation of one mutation's exact postcondition.
data ProviderEffectObservation
  = ProviderEffectSatisfied !Text
  | ProviderEffectNeedsApply !Text
  | ProviderEffectUnobservable !Text
  deriving stock (Eq, Show)

-- | Why one mutation's apply callback did not succeed: the effect ran and
-- reported a failure, and the text is the rendered cause and consequence.
--
-- Whether the effect nevertheless landed is not this type's to say. The worker
-- boundary observes again after every apply, whatever the apply reported, so
-- the read-back is the only thing that settles it. Sprint @4.109@ deleted the
-- second arm, which was declared by Sprint @4.103@ for a response that never
-- arrived and constructed by no production path: the one production source of
-- a missing response is a child stopped at its bound, and the failure summary
-- already names that as a typed @ChildTimedOut@ finding in this text.
newtype ApplyFailure = ApplyFailed Text
  deriving stock (Eq, Show)

-- | One mutation arm.  Both callbacks receive the stable signed intent
-- coordinate and the same rank-2-scoped narrow session.
data ProviderMutation m session = ProviderMutation
  { observeProviderMutation
      :: session
      -> ProviderIntentCoordinate
      -> m ProviderEffectObservation
  , applyProviderMutation
      :: session
      -> ProviderIntentCoordinate
      -> m (Either ApplyFailure ())
  }

-- | One observation-only arm.  There is structurally no mutation callback.
--
-- Sprint @4.99@: the arm returns sealed 'ProviderEvidence' and is handed the
-- bound for the intent it is serving.  Before that it returned a bare 'Text',
-- so every 'Text' was a legal answer and the rule an encoder had to satisfy
-- lived in a function 900 lines away that the author never had to name.  Six
-- encoders were written against that signature and all six emitted a character
-- the rule refuses.  Handing the bound in rather than letting a codec look one
-- up is the other half: an encoder now has exactly one bound available, the one
-- belonging to the intent it is answering.
newtype ProviderReadOnly m session = ProviderReadOnly
  { runProviderReadOnly
      :: session
      -> ProviderIntentCoordinate
      -> ProviderEvidenceBound
      -> m (Either Text ProviderEvidence)
  }

-- | Total role-separated capability registry for the closed
-- 'ProviderIntent' constructors.
data ProviderIntentCapabilities m session = ProviderIntentCapabilities
  { reconcileRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderRevision
      -> ProviderStackConfig
      -> ProviderRunMarker
      -> ProviderMutation m session
  , destroyRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderRevision
      -> ProviderStackConfig
      -> ProviderMutation m session
  , observeRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderReadOnly m session
  , readBackRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderReadOnly m session
  , previewRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderStackConfig
      -> ProviderReadOnly m session
  , boundedScratchCheckpointCapability
      :: ProviderCheckpointRef
      -> ProviderMutation m session
  , reconcileSesSendingIdentityCapability
      :: SesIdentityRef
      -> ProviderMutation m session
  , reconcileSesDkimCapability
      :: SesIdentityRef
      -> ProviderMutation m session
  , reconcileSesReceiptRulesCapability
      :: SesRuleSetRef
      -> ProviderMutation m session
  , reconcileSesCaptureBucketCapability
      :: SesBucketRef
      -> ProviderMutation m session
  , reconcileSesDnsCapability
      :: SesDnsRef
      -> ProviderMutation m session
  , observePublicARecordCapability
      :: PublicARecordRef
      -> ProviderReadOnly m session
  , reconcilePublicARecordCapability
      :: PublicARecordRef
      -> ProviderMutation m session
  , reapTestEbsVolumesCapability
      :: Text
      -> ProviderMutation m session
  , observeTestEbsVolumesCapability
      :: Text
      -> ProviderReadOnly m session
  , observeValidationHostedZonesCapability
      :: Text
      -> ProviderReadOnly m session
  , reapValidationHostedZonesCapability
      :: Text
      -> ProviderMutation m session
  , observeRetainedEbsVolumesCapability
      :: Text
      -> ProviderReadOnly m session
  , reapRetainedEbsVolumesCapability
      :: Text
      -> ProviderMutation m session
  , observeEksIamRoleFamilyCapability
      :: Text
      -> Text
      -> ProviderReadOnly m session
  , reapEksIamRoleFamilyCapability
      :: Text
      -> Text
      -> ProviderMutation m session
  , observeEksLoadBalancerControllerFamilyCapability
      :: Text
      -> Text
      -> ProviderReadOnly m session
  , reapEksLoadBalancerControllerFamilyCapability
      :: Text
      -> Text
      -> ProviderMutation m session
  , observeDns01ChallengeRecordsCapability
      :: Text
      -> Text
      -> ProviderReadOnly m session
  -- ^ Sprint 7.36: the DNS01 challenge record family, read-only.  There is no
  -- reap capability beside it: cert-manager's solver owns the record, so the
  -- removal is a Kubernetes owner delete outside the Provider's capability set.
  , observeGlobalOwnedResourceTagsCapability :: ProviderOwnedTagQuery -> ProviderReadOnly m session
  , observeOwnedResourceTagsCapability
      :: ProviderOwnedTagQuery
      -> ProviderReadOnly m session
  -- ^ Sprint 7.36: the cascade terminal audit's single-filter owned-resource
  -- tag listing.  Read-only by construction: the audit is the surface that
  -- proves nothing escaped, and it never removes what it finds.
  , observeSpotPriceCapability
      :: ProviderSpotPriceQuery
      -> ProviderReadOnly m session
  , observeOperationalIdentityCapability
      :: ProviderReadOnly m session
  , observeProviderAwsScopeCapability
      :: ProviderReadOnly m session
  , observeProviderReadinessCapability
      :: ProviderReadinessProbe
      -> ProviderReadOnly m session
  , issueEksClientAuthCapability
      :: EksClientAuthRequest
      -> ProviderReadOnly m session
  , observeEksClusterIdentityCapability
      :: EksClusterIdentityRequest
      -> ProviderReadOnly m session
  , observeNativeStackFamilyCapability
      :: ProviderNativeStackFamilyRef
      -> ProviderStackConfig
      -> ProviderReadOnly m session
  , reapNativeStackFamilyCapability
      :: ProviderNativeStackFamilyRef
      -> ProviderStackConfig
      -> [Text]
      -> ProviderMutation m session
  , observeAwsAuditCapability
      :: ProviderAuditTarget
      -> ProviderStackConfig
      -> ProviderAuditControl
      -> ProviderReadOnly m session
  -- ^ Sprint 4.110: the provider-enumerated audit of one stack's declared
  -- field. Read-only by construction.
  , ensureValidationHostedZoneCapability
      :: Text
      -> Text
      -> ProviderMutation m session
  -- ^ Sprint 5.50: the @dns-aws@ validation's throwaway zone, created beneath a
  -- base zone name from a run nonce.
  , observeHomeDns01RecordsCapability :: HomeDns01Scope -> ProviderReadOnly m session
  , observeSesInviteMailResidueCapability :: InviteMailScope -> ProviderReadOnly m session
  , reapSesInviteMailResidueCapability :: InviteMailScope -> ProviderMutation m session
  , observeSealedSesInviteMailCapability
      :: Text
      -> Text
      -> InviteMailPublicKey
      -> ProviderReadOnly m session
  -- ^ Sprint 5.50: the captured invite message for one recipient, read-only.
  , plantTestVpcCanaryCapability
      :: ProviderNativeStackFamilyRef -> TestVpcCanaryRequest -> ProviderMutation m session
  , ensureRetainedEbsVolumesCapability
      :: Text
      -> Text
      -> ProviderMutation m session
  -- ^ Sprint 5.50: the retained EBS volumes the AWS substrate's PersistentVolumes
  -- bind to.
  }

-- | Rank-2 scoping prevents an assumed-role/session handle from escaping the
-- exact signed provider action.
newtype ProviderNarrowSessionRunner m session = ProviderNarrowSessionRunner
  { withProviderNarrowSession
      :: forall result
       . ProviderIntent
      -> AuthorityTime
      -> (Maybe ProviderCredentialSessionBinding -> session -> m (Either Text result))
      -> m (Either Text result)
  }

data ProviderIntentOperation m session
  = ProviderIntentRetired
  | ProviderIntentMutation !(ProviderMutation m session)
  | ProviderIntentReadOnly !(ProviderReadOnly m session)

-- | Exhaustive dispatch.  Adding a ninth provider action requires extending
-- both this function and the capability record; there is no default branch.
operationForProviderIntent
  :: ProviderIntentCapabilities m session
  -> ProviderIntent
  -> ProviderIntentOperation m session
operationForProviderIntent capabilities intent = case intent of
  ReconcileRegisteredStack ref revision config marker ->
    ProviderIntentMutation
      (reconcileRegisteredStackCapability capabilities ref revision config marker)
  DestroyRegisteredStack ref revision config ->
    ProviderIntentMutation
      (destroyRegisteredStackCapability capabilities ref revision config)
  ObserveRegisteredStack ref ->
    ProviderIntentReadOnly (observeRegisteredStackCapability capabilities ref)
  ReadBackRegisteredStack ref ->
    ProviderIntentReadOnly (readBackRegisteredStackCapability capabilities ref)
  BoundedScratchCheckpoint ref ->
    ProviderIntentMutation (boundedScratchCheckpointCapability capabilities ref)
  ReconcileSesSendingIdentity ref ->
    ProviderIntentMutation (reconcileSesSendingIdentityCapability capabilities ref)
  ReconcileSesDkim ref ->
    ProviderIntentMutation (reconcileSesDkimCapability capabilities ref)
  ReconcileSesReceiptRules ref ->
    ProviderIntentMutation (reconcileSesReceiptRulesCapability capabilities ref)
  ReconcileSesCaptureBucket ref ->
    ProviderIntentMutation (reconcileSesCaptureBucketCapability capabilities ref)
  ReconcileSesDns ref ->
    ProviderIntentMutation (reconcileSesDnsCapability capabilities ref)
  ObservePublicARecord ref ->
    ProviderIntentReadOnly (observePublicARecordCapability capabilities ref)
  ReconcilePublicARecord ref ->
    ProviderIntentMutation (reconcilePublicARecordCapability capabilities ref)
  ReapTestEbsVolumes clusterName ->
    ProviderIntentMutation (reapTestEbsVolumesCapability capabilities clusterName)
  ObserveValidationHostedZones purpose ->
    ProviderIntentReadOnly
      (observeValidationHostedZonesCapability capabilities purpose)
  ReapValidationHostedZones purpose ->
    ProviderIntentMutation
      (reapValidationHostedZonesCapability capabilities purpose)
  ObserveDns01ChallengeRecords zoneId recordNamePrefix ->
    ProviderIntentReadOnly
      (observeDns01ChallengeRecordsCapability capabilities zoneId recordNamePrefix)
  ObserveRetainedEbsVolumes lifecycleValue ->
    ProviderIntentReadOnly
      (observeRetainedEbsVolumesCapability capabilities lifecycleValue)
  ReapRetainedEbsVolumes lifecycleValue ->
    ProviderIntentMutation
      (reapRetainedEbsVolumesCapability capabilities lifecycleValue)
  ObserveEksIamRoleFamily roleNames policyNames ->
    ProviderIntentReadOnly
      (observeEksIamRoleFamilyCapability capabilities roleNames policyNames)
  ReapEksIamRoleFamily roleNames policyNames ->
    ProviderIntentMutation
      (reapEksIamRoleFamilyCapability capabilities roleNames policyNames)
  ObserveEksLoadBalancerControllerFamily loadBalancerName tags ->
    ProviderIntentReadOnly
      ( observeEksLoadBalancerControllerFamilyCapability
          capabilities
          loadBalancerName
          tags
      )
  ReapEksLoadBalancerControllerFamily loadBalancerName tags ->
    ProviderIntentMutation
      ( reapEksLoadBalancerControllerFamilyCapability
          capabilities
          loadBalancerName
          tags
      )
  PlantTestVpcCanary ref request -> ProviderIntentMutation (plantTestVpcCanaryCapability capabilities ref request)
  ObserveGlobalOwnedResourceTags query -> ProviderIntentReadOnly (observeGlobalOwnedResourceTagsCapability capabilities query)
  ObserveOwnedResourceTags query ->
    ProviderIntentReadOnly
      (observeOwnedResourceTagsCapability capabilities query)
  ObserveSpotPrice query ->
    ProviderIntentReadOnly (observeSpotPriceCapability capabilities query)
  ObserveOperationalIdentity ->
    ProviderIntentReadOnly (observeOperationalIdentityCapability capabilities)
  ObserveProviderAwsScope ->
    ProviderIntentReadOnly (observeProviderAwsScopeCapability capabilities)
  ObserveProviderReadiness probe ->
    ProviderIntentReadOnly (observeProviderReadinessCapability capabilities probe)
  IssueEksClientAuth request ->
    ProviderIntentReadOnly (issueEksClientAuthCapability capabilities request)
  ObserveTestEbsVolumes clusterName ->
    ProviderIntentReadOnly (observeTestEbsVolumesCapability capabilities clusterName)
  ObserveEksClusterIdentity request ->
    ProviderIntentReadOnly (observeEksClusterIdentityCapability capabilities request)
  ObserveNativeStackFamily ref config ->
    ProviderIntentReadOnly
      (observeNativeStackFamilyCapability capabilities ref config)
  ReapNativeStackFamily ref config admittedIdentities ->
    ProviderIntentMutation
      (reapNativeStackFamilyCapability capabilities ref config admittedIdentities)
  ObserveAwsAudit target config control ->
    ProviderIntentReadOnly (observeAwsAuditCapability capabilities target config control)
  PreviewRegisteredStack ref config ->
    ProviderIntentReadOnly (previewRegisteredStackCapability capabilities ref config)
  EnsureValidationHostedZone nonce baseZone ->
    ProviderIntentMutation
      (ensureValidationHostedZoneCapability capabilities nonce baseZone)
  ObserveHomeDns01Records scope -> ProviderIntentReadOnly (observeHomeDns01RecordsCapability capabilities scope)
  ObserveSesInviteMailResidue scope -> ProviderIntentReadOnly (observeSesInviteMailResidueCapability capabilities scope)
  ReapSesInviteMailResidue scope -> ProviderIntentMutation (reapSesInviteMailResidueCapability capabilities scope)
  RetiredSesInviteMailObservation {} -> ProviderIntentRetired
  ObserveSealedSesInviteMail bucket recipient destination ->
    ProviderIntentReadOnly
      (observeSealedSesInviteMailCapability capabilities bucket recipient destination)
  RetiredSesInviteMailCleanup {} -> ProviderIntentRetired
  EnsureRetainedEbsVolumes volumeType specs ->
    ProviderIntentMutation
      (ensureRetainedEbsVolumesCapability capabilities volumeType specs)
