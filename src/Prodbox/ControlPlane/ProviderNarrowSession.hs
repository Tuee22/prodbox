{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RankNTypes #-}

-- | Provider-Worker-local closed effects and rank-2 narrow session.
--
-- The capability registry is exhaustive over the eight normal provider
-- actions.  It contains no credential/admin/SMTP-IAM, generic AWS, Vault,
-- object-store, subprocess, or Authority-state escape arm.
module Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (..)
  , ProviderMutation (..)
  , ProviderReadOnly (..)
  , ProviderIntentCapabilities (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderIntentOperation (..)
  , operationForProviderIntent
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.ProviderCredentialSession
  ( ProviderCredentialSessionBinding
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
  , ProviderCheckpointRef
  , ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderOwnedTagQuery
  , ProviderReadinessProbe
  , ProviderRevision
  , ProviderSpotPriceQuery
  , ProviderStackConfig
  , ProviderStackRef
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  )

-- | Authoritative observation of one mutation's exact postcondition.
data ProviderEffectObservation
  = ProviderEffectSatisfied !Text
  | ProviderEffectNeedsApply !Text
  | ProviderEffectUnobservable !Text
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
      -> m (Either Text ())
  }

-- | One observation-only arm.  There is structurally no mutation callback.
newtype ProviderReadOnly m session = ProviderReadOnly
  { runProviderReadOnly
      :: session
      -> ProviderIntentCoordinate
      -> m (Either Text Text)
  }

-- | Total role-separated capability registry for the closed
-- 'ProviderIntent' constructors.
data ProviderIntentCapabilities m session = ProviderIntentCapabilities
  { reconcileRegisteredStackCapability
      :: ProviderStackRef
      -> ProviderRevision
      -> ProviderStackConfig
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
  , observeDns01ChallengeRecordsCapability
      :: Text
      -> Text
      -> ProviderReadOnly m session
  -- ^ Sprint 7.36: the DNS01 challenge record family, read-only.  There is no
  -- reap capability beside it: cert-manager's solver owns the record, so the
  -- removal is a Kubernetes owner delete outside the Provider's capability set.
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
  = ProviderIntentMutation !(ProviderMutation m session)
  | ProviderIntentReadOnly !(ProviderReadOnly m session)

-- | Exhaustive dispatch.  Adding a ninth provider action requires extending
-- both this function and the capability record; there is no default branch.
operationForProviderIntent
  :: ProviderIntentCapabilities m session
  -> ProviderIntent
  -> ProviderIntentOperation m session
operationForProviderIntent capabilities intent = case intent of
  ReconcileRegisteredStack ref revision config ->
    ProviderIntentMutation
      (reconcileRegisteredStackCapability capabilities ref revision config)
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
