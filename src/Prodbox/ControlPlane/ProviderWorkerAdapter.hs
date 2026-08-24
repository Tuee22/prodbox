{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Authority-side compatibility retained state and Provider Worker
-- orchestration.
--
-- This module's 'ProviderWorkerAdapter' owns a global Model-B journal and must
-- not be installed in the production Provider Worker.  The isolated production
-- boundary is "Prodbox.ControlPlane.ProviderWorkerExecution", with its closed
-- rank-2 effect vocabulary in "Prodbox.ControlPlane.ProviderNarrowSession".
--
-- The retained envelope stores the exact admitted 'ProviderIntent', not only
-- its display coordinate. Every transition is an exact-revision Model-B CAS and
-- is confirmed by an authoritative read-back, including when the write response
-- was lost. An external mutation is therefore impossible before its exact
-- intent is durable.
--
-- Execution is exhaustive over the closed intent vocabulary. One scoped narrow
-- session encloses the initial observation, optional mutation, and mandatory
-- post-mutation read-back. Recovery re-observes an in-flight intent before it
-- can retry with the same stable coordinate; a recovering/ambiguous intent is
-- observation-only and blocks a successor until positive evidence closes it.
module Prodbox.ControlPlane.ProviderWorkerAdapter
  ( ProviderEffectObservation (..)
  , ProviderMutation (..)
  , ProviderReadOnly (..)
  , ProviderIntentCapabilities (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderWorkCompletion (..)
  , ProviderWorkDurableState
  , initialProviderWorkDurableState
  , providerWorkDurableState
  , providerWorkDurableActiveIntent
  , providerWorkDurableLastCompletion
  , ProviderWorkStateCodecError (..)
  , providerWorkMaximumEncodedBytes
  , providerWorkStateCodec
  , ProviderWorkRetainedSnapshot (..)
  , ProviderWorkRetainedRepository (..)
  , modelBProviderWorkRetainedRepository
  , ProviderWorkerAdapter (..)
  , ProviderWorkerResumeResult (..)
  , commitProviderWorkTransition
  , executeProviderIntent
  , resumeProviderWorker
  , providerWorkerAdapterReady
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
  , ProviderCheckpointRef
  , ProviderIntent (..)
  , ProviderIntentCoordinate
  , ProviderNativeStackFamilyRef
  , ProviderOwnedTagQuery (..)
  , ProviderReadinessProbe (..)
  , ProviderRevision
  , ProviderSpotPriceQuery
  , ProviderStackConfig
  , ProviderStackRef
  , ProviderWorkCommand (..)
  , ProviderWorkState (..)
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  , eksClientAuthRequestAccountId
  , eksClientAuthRequestClusterName
  , eksClientAuthRequestDestinationPublicKey
  , eksClientAuthRequestRegion
  , eksClusterIdentityRequestAccountId
  , eksClusterIdentityRequestClusterName
  , eksClusterIdentityRequestRegion
  , eksClusterIdentityRequestStackRef
  , initialProviderWorkState
  , mkEksClientAuthRequest
  , mkEksClusterIdentityRequest
  , mkProviderCheckpointRef
  , mkProviderNativeStackFamilyRef
  , mkProviderRevision
  , mkProviderSpotPriceQuery
  , mkProviderStackRef
  , mkPublicARecordRef
  , mkSesBucketRef
  , mkSesDnsRef
  , mkSesIdentityRef
  , mkSesRuleSetRef
  , providerCheckpointRefText
  , providerIntentCoordinate
  , providerNativeStackFamilyAccountId
  , providerNativeStackFamilyHostedZoneId
  , providerNativeStackFamilyRegion
  , providerNativeStackFamilyStackRef
  , providerRevisionNatural
  , providerSpotPriceInstanceType
  , providerSpotPriceProductDescription
  , providerStackRefText
  , publicARecordFqdn
  , publicARecordHostedZoneId
  , publicARecordTtl
  , publicARecordValues
  , sesBucketRefText
  , sesDnsHostedZoneId
  , sesDnsIdentityDomain
  , sesDnsReceiveSubdomain
  , sesIdentityRefText
  , sesRuleSetCaptureBucket
  , sesRuleSetRecipient
  , sesRuleSetRefText
  , validateProviderStackConfig
  )

-- | Authoritative observation of one mutation's exact postcondition.
data ProviderEffectObservation
  = ProviderEffectSatisfied !Text
  | ProviderEffectNeedsApply !Text
  | ProviderEffectUnobservable !Text
  deriving stock (Eq, Show)

-- | One mutation arm. Both callbacks receive the stable intent coordinate and
-- the same scoped narrow session.
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

-- | One observation-only arm. There is structurally no mutation callback.
newtype ProviderReadOnly m session = ProviderReadOnly
  { runProviderReadOnly
      :: session
      -> ProviderIntentCoordinate
      -> m (Either Text Text)
  }

-- | Total, role-separated capability registry for the closed
-- 'ProviderIntent' constructors. There is no generic AWS, IAM, command, or
-- caller-supplied operation arm.
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
  }

-- | Bracket-like session capability. Rank-2 scoping prevents the credential or
-- assumed-role handle from escaping the exact observe/apply/read-back action.
newtype ProviderNarrowSessionRunner m session = ProviderNarrowSessionRunner
  { withProviderNarrowSession
      :: forall result
       . ProviderIntent
      -> AuthorityTime
      -> (session -> m (Either Text result))
      -> m (Either Text result)
  }

-- | Durable positive terminal evidence for the most recently closed intent.
data ProviderWorkCompletion = ProviderWorkCompletion
  { providerWorkCompletedIntent :: !ProviderIntent
  , providerWorkCompletionEvidence :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | One retained Provider Worker object. The active intent is required in every
-- non-idle phase so restart never has to parse or rediscover it from a string.
data ProviderWorkDurableState = ProviderWorkDurableState
  { internalProviderWorkState :: !ProviderWorkState
  , internalProviderWorkActiveIntent :: !(Maybe ProviderIntent)
  , internalProviderWorkLastCompletion :: !(Maybe ProviderWorkCompletion)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialProviderWorkDurableState :: ProviderWorkDurableState
initialProviderWorkDurableState =
  ProviderWorkDurableState
    { internalProviderWorkState = initialProviderWorkState
    , internalProviderWorkActiveIntent = Nothing
    , internalProviderWorkLastCompletion = Nothing
    }

providerWorkDurableState :: ProviderWorkDurableState -> ProviderWorkState
providerWorkDurableState = internalProviderWorkState

providerWorkDurableActiveIntent :: ProviderWorkDurableState -> Maybe ProviderIntent
providerWorkDurableActiveIntent = internalProviderWorkActiveIntent

providerWorkDurableLastCompletion :: ProviderWorkDurableState -> Maybe ProviderWorkCompletion
providerWorkDurableLastCompletion = internalProviderWorkLastCompletion

data ProviderWorkStateCodecError
  = ProviderWorkStateTooLarge !Int !Int
  | ProviderWorkStateInvalid
  | ProviderWorkStateUnsupportedVersion !Word16
  | ProviderWorkStateNonCanonical
  | ProviderWorkStateActiveIntentMissing
  | ProviderWorkStateIdleHasActiveIntent
  | ProviderWorkStateIntentCoordinateMismatch
  | ProviderWorkStateIntentInvalid !Text
  | ProviderWorkStateEvidenceInvalid
  deriving stock (Eq, Show)

data ProviderWorkEnvelope = ProviderWorkEnvelope
  { providerWorkEnvelopeVersion :: !Word16
  , providerWorkEnvelopeState :: !ProviderWorkDurableState
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

providerWorkMaximumEncodedBytes :: Int
providerWorkMaximumEncodedBytes = 128 * 1024

providerWorkCodecVersion :: Word16
providerWorkCodecVersion = 1

providerWorkStateCodec :: Int -> ModelBCodec ProviderWorkDurableState
providerWorkStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = either (Left . show) Right . encodeProviderWorkState maximumBytes
    , decodeModelBValue = either (Left . show) Right . decodeProviderWorkState maximumBytes
    }

encodeProviderWorkState
  :: Int
  -> ProviderWorkDurableState
  -> Either ProviderWorkStateCodecError StrictByteString.ByteString
encodeProviderWorkState maximumBytes state = do
  validateProviderWorkDurableState state
  let bytes =
        LazyByteString.toStrict
          ( serialise
              ProviderWorkEnvelope
                { providerWorkEnvelopeVersion = providerWorkCodecVersion
                , providerWorkEnvelopeState = state
                }
          )
  if maximumBytes < 0 || StrictByteString.length bytes > maximumBytes
    then Left (ProviderWorkStateTooLarge (StrictByteString.length bytes) maximumBytes)
    else Right bytes

decodeProviderWorkState
  :: Int
  -> StrictByteString.ByteString
  -> Either ProviderWorkStateCodecError ProviderWorkDurableState
decodeProviderWorkState maximumBytes bytes
  | maximumBytes < 0 || StrictByteString.length bytes > maximumBytes =
      Left (ProviderWorkStateTooLarge (StrictByteString.length bytes) maximumBytes)
  | otherwise = do
      envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left ProviderWorkStateInvalid
        Right decoded -> Right decoded
      if providerWorkEnvelopeVersion envelope /= providerWorkCodecVersion
        then Left (ProviderWorkStateUnsupportedVersion (providerWorkEnvelopeVersion envelope))
        else Right ()
      validateProviderWorkDurableState (providerWorkEnvelopeState envelope)
      if LazyByteString.toStrict (serialise envelope) /= bytes
        then Left ProviderWorkStateNonCanonical
        else Right (providerWorkEnvelopeState envelope)

validateProviderWorkDurableState
  :: ProviderWorkDurableState
  -> Either ProviderWorkStateCodecError ()
validateProviderWorkDurableState durable = do
  traverse_ validateProviderIntent (internalProviderWorkActiveIntent durable)
  traverse_ validateCompletion (internalProviderWorkLastCompletion durable)
  case (internalProviderWorkState durable, internalProviderWorkActiveIntent durable) of
    (ProviderIdle, Nothing) -> Right ()
    (ProviderIdle, Just _) -> Left ProviderWorkStateIdleHasActiveIntent
    (_, Nothing) -> Left ProviderWorkStateActiveIntentMissing
    (ProviderInFlight coordinate, Just intent) -> validateActiveCoordinate coordinate intent
    (ProviderRecovering coordinate, Just intent) -> validateActiveCoordinate coordinate intent
    (ProviderGrace coordinate, Just intent) -> validateActiveCoordinate coordinate intent
 where
  validateCompletion completion = do
    validateProviderIntent (providerWorkCompletedIntent completion)
    validateEvidence (providerWorkCompletionEvidence completion)
  validateActiveCoordinate coordinate intent
    | coordinate == providerIntentCoordinate intent = Right ()
    | otherwise = Left ProviderWorkStateIntentCoordinateMismatch

validateProviderIntent :: ProviderIntent -> Either ProviderWorkStateCodecError ()
validateProviderIntent intent = case intent of
  ReconcileRegisteredStack ref revision config -> do
    validateRef "stack" (mkProviderStackRef (providerStackRefText ref)) ref
    validateRevision revision
    validateStackConfig ref config
  DestroyRegisteredStack ref revision config -> do
    validateRef "stack" (mkProviderStackRef (providerStackRefText ref)) ref
    validateRevision revision
    validateStackConfig ref config
  ObserveRegisteredStack ref ->
    validateRef "stack" (mkProviderStackRef (providerStackRefText ref)) ref
  ReadBackRegisteredStack ref ->
    validateRef "stack" (mkProviderStackRef (providerStackRefText ref)) ref
  BoundedScratchCheckpoint ref ->
    validateRef "checkpoint" (mkProviderCheckpointRef (providerCheckpointRefText ref)) ref
  ReconcileSesSendingIdentity ref ->
    validateRef "ses-identity" (mkSesIdentityRef (sesIdentityRefText ref)) ref
  ReconcileSesDkim ref ->
    validateRef "ses-identity" (mkSesIdentityRef (sesIdentityRefText ref)) ref
  ReconcileSesReceiptRules ref ->
    validateRef
      "ses-rules"
      ( mkSesRuleSetRef
          (sesRuleSetRefText ref)
          (sesRuleSetRecipient ref)
          (sesBucketRefText (sesRuleSetCaptureBucket ref))
      )
      ref
  ReconcileSesCaptureBucket ref ->
    validateRef "ses-bucket" (mkSesBucketRef (sesBucketRefText ref)) ref
  ReconcileSesDns ref ->
    validateRef
      "ses-dns"
      ( mkSesDnsRef
          (sesDnsHostedZoneId ref)
          (sesDnsIdentityDomain ref)
          (sesDnsReceiveSubdomain ref)
      )
      ref
  ObservePublicARecord ref -> validatePublicARecord ref
  ReconcilePublicARecord ref -> validatePublicARecord ref
  ReapTestEbsVolumes clusterName ->
    validateTextRef "cluster-name" clusterName
  ObserveSpotPrice query ->
    case mkProviderSpotPriceQuery
      (providerSpotPriceInstanceType query)
      (providerSpotPriceProductDescription query) of
      Left _ -> Left (ProviderWorkStateIntentInvalid "spot-price")
      Right actual
        | actual == query -> Right ()
        | otherwise -> Left (ProviderWorkStateIntentInvalid "spot-price")
  ObserveOperationalIdentity -> Right ()
  ObserveProviderAwsScope -> Right ()
  ObserveProviderReadiness probe -> case probe of
    ProviderReadinessStsIdentity -> Right ()
    ProviderReadinessRoute53Zone zoneId -> validateTextRef "route53-zone" zoneId
  IssueEksClientAuth request ->
    case mkEksClientAuthRequest
      (eksClientAuthRequestAccountId request)
      (eksClientAuthRequestRegion request)
      (eksClientAuthRequestClusterName request)
      (eksClientAuthRequestDestinationPublicKey request) of
      Left _ -> Left (ProviderWorkStateIntentInvalid "eks-client-auth")
      Right actual
        | actual == request -> Right ()
        | otherwise -> Left (ProviderWorkStateIntentInvalid "eks-client-auth")
  ObserveTestEbsVolumes clusterName ->
    validateTextRef "cluster-name" clusterName
  ObserveValidationHostedZones purpose ->
    validateTextRef "validation-zone-purpose" purpose
  ReapValidationHostedZones purpose ->
    validateTextRef "validation-zone-purpose" purpose
  ObserveDns01ChallengeRecords zoneId recordNamePrefix -> do
    validateTextRef "dns01-challenge-zone" zoneId
    validateTextRef "dns01-challenge-record-prefix" recordNamePrefix
  ObserveRetainedEbsVolumes lifecycleValue ->
    validateTextRef "retained-ebs-lifecycle" lifecycleValue
  ReapRetainedEbsVolumes lifecycleValue ->
    validateTextRef "retained-ebs-lifecycle" lifecycleValue
  ObserveEksIamRoleFamily roleNames policyNames -> do
    validateTextRef "eks-iam-role-family-roles" roleNames
    validateTextRef "eks-iam-role-family-policies" policyNames
  ReapEksIamRoleFamily roleNames policyNames -> do
    validateTextRef "eks-iam-role-family-roles" roleNames
    validateTextRef "eks-iam-role-family-policies" policyNames
  ObserveEksLoadBalancerControllerFamily loadBalancerName tags -> do
    validateTextRef "eks-load-balancer-controller-name" loadBalancerName
    validateTextRef "eks-load-balancer-controller-tags" tags
  ReapEksLoadBalancerControllerFamily loadBalancerName tags -> do
    validateTextRef "eks-load-balancer-controller-name" loadBalancerName
    validateTextRef "eks-load-balancer-controller-tags" tags
  ObserveOwnedResourceTags query -> case query of
    ProviderOwnedTagKeyQuery key -> validateTextRef "owned-resource-tag-key" key
    ProviderOwnedTagPairQuery key value -> do
      validateTextRef "owned-resource-tag-key" key
      validateTextRef "owned-resource-tag-value" value
  ObserveEksClusterIdentity request ->
    case mkEksClusterIdentityRequest
      (eksClusterIdentityRequestStackRef request)
      (eksClusterIdentityRequestAccountId request)
      (eksClusterIdentityRequestRegion request)
      (eksClusterIdentityRequestClusterName request) of
      Left _ -> Left (ProviderWorkStateIntentInvalid "eks-cluster-identity")
      Right actual
        | actual == request -> Right ()
        | otherwise -> Left (ProviderWorkStateIntentInvalid "eks-cluster-identity")
  ObserveNativeStackFamily ref config -> do
    validateNativeStackFamilyRef ref
    validateStackConfig (providerNativeStackFamilyStackRef ref) config
  ReapNativeStackFamily ref config admittedIdentities -> do
    validateNativeStackFamilyRef ref
    validateStackConfig (providerNativeStackFamilyStackRef ref) config
    validateNativeStackFamilyIdentities admittedIdentities
 where
  validateRef label rebuilt expected = case rebuilt of
    Left _ -> Left (ProviderWorkStateIntentInvalid label)
    Right actual
      | actual == expected -> Right ()
      | otherwise -> Left (ProviderWorkStateIntentInvalid label)
  validateRevision revision =
    case mkProviderRevision (providerRevisionNatural revision) of
      Left _ -> Left (ProviderWorkStateIntentInvalid "revision")
      Right actual
        | actual == revision -> Right ()
        | otherwise -> Left (ProviderWorkStateIntentInvalid "revision")
  validateStackConfig ref config =
    case validateProviderStackConfig ref config of
      Left _ -> Left (ProviderWorkStateIntentInvalid "stack-config")
      Right () -> Right ()
  validatePublicARecord ref =
    validateRef
      "public-a-record"
      ( mkPublicARecordRef
          (publicARecordHostedZoneId ref)
          (publicARecordFqdn ref)
          (publicARecordTtl ref)
          (publicARecordValues ref)
      )
      ref
  validateTextRef label value =
    case mkProviderStackRef value of
      Left _ -> Left (ProviderWorkStateIntentInvalid label)
      Right _ -> Right ()
  validateNativeStackFamilyRef ref =
    validateRef
      "native-stack-family"
      ( mkProviderNativeStackFamilyRef
          (providerNativeStackFamilyStackRef ref)
          (providerNativeStackFamilyAccountId ref)
          (providerNativeStackFamilyRegion ref)
          (providerNativeStackFamilyHostedZoneId ref)
      )
      ref
  validateNativeStackFamilyIdentities identities
    | null identities = Left (ProviderWorkStateIntentInvalid "native-stack-family-empty-allowlist")
    | length identities > 4096 =
        Left (ProviderWorkStateIntentInvalid "native-stack-family-allowlist-bound")
    | length identities /= length (nub identities) =
        Left (ProviderWorkStateIntentInvalid "native-stack-family-allowlist-duplicate")
    | any invalid identities =
        Left (ProviderWorkStateIntentInvalid "native-stack-family-allowlist-identity")
    | otherwise = Right ()
   where
    invalid identity =
      Text.null identity
        || Text.length identity > 2048
        || Text.any (\character -> character == '|' || character == '\n' || character == '\r') identity

validateEvidence :: Text -> Either ProviderWorkStateCodecError ()
validateEvidence evidence
  | Text.null evidence = Left ProviderWorkStateEvidenceInvalid
  | Text.length evidence > 4096 = Left ProviderWorkStateEvidenceInvalid
  | Text.any isControl evidence = Left ProviderWorkStateEvidenceInvalid
  | otherwise = Right ()
 where
  isControl character = character <= '\x1f' || character == '\x7f'

traverse_ :: (a -> Either errorValue ()) -> Maybe a -> Either errorValue ()
traverse_ validate maybeValue = case maybeValue of
  Nothing -> Right ()
  Just value -> validate value

-- | One exact retained observation, including the opaque object-store revision.
data ProviderWorkRetainedSnapshot = ProviderWorkRetainedSnapshot
  { providerWorkRetainedRevision :: !(Maybe ModelBObjectVersion)
  , providerWorkRetainedState :: !ProviderWorkDurableState
  }
  deriving stock (Eq, Show)

data ProviderWorkRetainedRepository m = ProviderWorkRetainedRepository
  { readProviderWorkRetainedState
      :: m (Either Text ProviderWorkRetainedSnapshot)
  , compareAndSwapProviderWorkRetainedState
      :: Maybe ModelBObjectVersion
      -> ProviderWorkDurableState
      -> m (Either Text ())
  }

-- | Bind the retained envelope to one ClusterRetained Model-B coordinate.
modelBProviderWorkRetainedRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ProviderWorkDurableState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> ProviderWorkRetainedRepository m
modelBProviderWorkRetainedRepository adapter coordinate =
  ProviderWorkRetainedRepository
    { readProviderWorkRetainedState = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right
              ProviderWorkRetainedSnapshot
                { providerWorkRetainedRevision = Nothing
                , providerWorkRetainedState = initialProviderWorkDurableState
                }
          ModelBObserved revision state ->
            Right
              ProviderWorkRetainedSnapshot
                { providerWorkRetainedRevision = Just revision
                , providerWorkRetainedState = state
                }
          ModelBCorrupt detail -> Left ("provider work state is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("provider work state is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("provider work state is unobservable: " <> detail)
    , compareAndSwapProviderWorkRetainedState = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "provider work state CAS conflict"
          ModelBCasRefusedCorrupt detail -> Left ("provider work CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("provider work CAS is not ready: " <> detail)
          ModelBCasUnobservable detail -> Left ("provider work CAS is unobservable: " <> detail)
    }

-- | Complete adapter composition. Authority-owned registration/revision/time
-- inputs are injected separately from the retained object and effect/session
-- capabilities; none can be supplied by the request body.
data ProviderWorkerAdapter m session = ProviderWorkerAdapter
  { providerWorkerRetainedRepository :: !(ProviderWorkRetainedRepository m)
  , providerWorkerAuthorityNow :: m (Either Text AuthorityTime)
  , providerWorkerSessionDeadline :: m (Either Text AuthorityTime)
  , providerWorkerNarrowSession :: !(ProviderNarrowSessionRunner m session)
  , providerWorkerIntentCapabilities :: !(ProviderIntentCapabilities m session)
  , providerWorkerExternalReady :: m Bool
  }

data ProviderWorkerResumeResult
  = ProviderWorkerNothingPending
  | ProviderWorkerResumed !ProviderWorkCompletion
  | ProviderWorkerStillRecovering !ProviderIntentCoordinate !Text
  deriving stock (Eq, Show)

-- | Exact-revision retained transition used by the endpoint repository hook.
-- The submitted command supplies the exact intent stored alongside an admitted
-- in-flight coordinate. A stale expected state or illegal transition refuses.
commitProviderWorkTransition
  :: (Monad m)
  => ProviderWorkerAdapter m session
  -> ProviderWorkState
  -> ProviderWorkCommand
  -> ProviderWorkState
  -> m (Either Text ())
commitProviderWorkTransition adapter expected command next = do
  observed <- readProviderWorkRetainedState repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot
      | providerWorkDurableState current /= expected ->
          pure (Left "provider work state changed before exact-revision commit")
      | otherwise ->
          case transitionDurableState current command next of
            Left detail -> pure (Left detail)
            Right desired -> commitAndConfirm repository snapshot desired
     where
      current = providerWorkRetainedState snapshot
 where
  repository = providerWorkerRetainedRepository adapter

transitionDurableState
  :: ProviderWorkDurableState
  -> ProviderWorkCommand
  -> ProviderWorkState
  -> Either Text ProviderWorkDurableState
transitionDurableState current command next = case command of
  SubmitProviderIntent intent -> case next of
    ProviderInFlight coordinate
      | coordinate == providerIntentCoordinate intent ->
          validated current {internalProviderWorkState = next, internalProviderWorkActiveIntent = Just intent}
      | otherwise -> Left "admitted provider intent coordinate drifted"
    _ -> Left "provider submit did not transition to in-flight"
  CloseProviderWork coordinate -> case (next, internalProviderWorkActiveIntent current) of
    (ProviderIdle, Just intent)
      | coordinate == providerIntentCoordinate intent ->
          validated
            current {internalProviderWorkState = ProviderIdle, internalProviderWorkActiveIntent = Nothing}
      | otherwise -> Left "provider close coordinate drifted"
    _ -> Left "provider close did not transition an active intent to idle"
  RecoverProviderWork coordinate ->
    preserveActive coordinate next isRecovering "provider recover transition drifted"
  ResolveProviderRecovery coordinate ->
    preserveActive coordinate next isGrace "provider recovery resolution drifted"
 where
  preserveActive coordinate desired phaseMatches failure =
    case internalProviderWorkActiveIntent current of
      Just intent
        | coordinate == providerIntentCoordinate intent
            && phaseMatches desired ->
            validated current {internalProviderWorkState = desired}
      _ -> Left failure
  isRecovering state = case state of
    ProviderRecovering _ -> True
    _ -> False
  isGrace state = case state of
    ProviderGrace _ -> True
    _ -> False
  validated desired =
    case validateProviderWorkDurableState desired of
      Left err -> Left (Text.pack (show err))
      Right () -> Right desired

commitAndConfirm
  :: (Monad m)
  => ProviderWorkRetainedRepository m
  -> ProviderWorkRetainedSnapshot
  -> ProviderWorkDurableState
  -> m (Either Text ())
commitAndConfirm repository snapshot desired = do
  attempted <-
    compareAndSwapProviderWorkRetainedState
      repository
      (providerWorkRetainedRevision snapshot)
      desired
  readBack <- readProviderWorkRetainedState repository
  pure $ case readBack of
    Right confirmed
      | providerWorkRetainedState confirmed == desired -> Right ()
    Left detail -> Left ("provider work state read-back failed: " <> detail)
    Right _ -> case attempted of
      Left detail -> Left detail
      Right () -> Left "provider work state CAS was not confirmed by read-back"

-- | Execute or recover one exact durable intent. Fresh/in-flight work observes
-- before applying; a recovering intent is observation-only. Positive evidence
-- is durably read back into the completion record before returning success.
executeProviderIntent
  :: (Monad m)
  => ProviderWorkerAdapter m session
  -> ProviderIntent
  -> m (Either Text ProviderWorkCompletion)
executeProviderIntent adapter requested = do
  observed <- readProviderWorkRetainedState repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot ->
      case activeExecutionMode (providerWorkRetainedState snapshot) requested of
        Left detail -> pure (Left detail)
        Right mode -> executeSnapshot snapshot mode
 where
  repository = providerWorkerRetainedRepository adapter

  executeSnapshot snapshot mode = do
    nowResult <- providerWorkerAuthorityNow adapter
    deadlineResult <- providerWorkerSessionDeadline adapter
    case (nowResult, deadlineResult) of
      (Left detail, _) -> recoverAfterFailure snapshot ("provider authority clock unavailable: " <> detail)
      (_, Left detail) -> recoverAfterFailure snapshot ("provider session deadline unavailable: " <> detail)
      (Right now, Right deadline)
        | authorityTimeMicros now >= authorityTimeMicros deadline ->
            recoverAfterFailure snapshot "provider session deadline reached"
        | otherwise -> do
            execution <-
              withProviderNarrowSession
                (providerWorkerNarrowSession adapter)
                requested
                deadline
                (runIntentUnderSession adapter mode requested)
            case execution of
              Left detail -> recoverAfterFailure snapshot detail
              Right evidence -> completeSnapshot snapshot requested evidence

  recoverAfterFailure snapshot detail = do
    marked <- markSnapshotRecovering adapter snapshot requested
    pure $ case marked of
      Left markDetail -> Left (detail <> "; recovery fence failed: " <> markDetail)
      Right () -> Left detail

  completeSnapshot snapshot intent evidence =
    case validateEvidence evidence of
      Left err -> recoverAfterFailure snapshot (Text.pack (show err))
      Right () -> do
        let completion =
              ProviderWorkCompletion
                { providerWorkCompletedIntent = intent
                , providerWorkCompletionEvidence = evidence
                }
            desired =
              (providerWorkRetainedState snapshot)
                { internalProviderWorkState = ProviderIdle
                , internalProviderWorkActiveIntent = Nothing
                , internalProviderWorkLastCompletion = Just completion
                }
        committed <- commitAndConfirm repository snapshot desired
        pure (completion <$ committed)

data ActiveExecutionMode = ExecuteIfNeeded | ObserveRecoveryOnly

activeExecutionMode
  :: ProviderWorkDurableState
  -> ProviderIntent
  -> Either Text ActiveExecutionMode
activeExecutionMode durable requested =
  case (internalProviderWorkState durable, internalProviderWorkActiveIntent durable) of
    (ProviderInFlight _, Just active)
      | active == requested -> Right ExecuteIfNeeded
      | otherwise -> Left "provider in-flight intent differs from requested intent"
    (ProviderRecovering _, Just active)
      | active == requested -> Right ObserveRecoveryOnly
      | otherwise -> Left "provider recovering intent differs from requested intent"
    _ -> Left "provider intent is not durably active"

runIntentUnderSession
  :: (Monad m)
  => ProviderWorkerAdapter m session
  -> ActiveExecutionMode
  -> ProviderIntent
  -> session
  -> m (Either Text Text)
runIntentUnderSession adapter mode intent session =
  case operationForIntent (providerWorkerIntentCapabilities adapter) intent of
    IntentReadOnly operation -> runProviderReadOnly operation session coordinate
    IntentMutation operation -> do
      before <- observeProviderMutation operation session coordinate
      case before of
        ProviderEffectSatisfied evidence -> pure (validateRuntimeEvidence evidence)
        ProviderEffectUnobservable detail -> pure (Left ("provider observation unavailable: " <> detail))
        ProviderEffectNeedsApply detail -> case mode of
          ObserveRecoveryOnly -> pure (Left ("provider recovery still requires apply: " <> detail))
          ExecuteIfNeeded -> do
            applied <- applyProviderMutation operation session coordinate
            case applied of
              Left applyDetail -> pure (Left ("provider apply failed or was ambiguous: " <> applyDetail))
              Right () -> do
                after <- observeProviderMutation operation session coordinate
                pure $ case after of
                  ProviderEffectSatisfied evidence -> validateRuntimeEvidence evidence
                  ProviderEffectNeedsApply postDetail ->
                    Left ("provider read-back did not confirm the effect: " <> postDetail)
                  ProviderEffectUnobservable postDetail ->
                    Left ("provider read-back unavailable: " <> postDetail)
 where
  coordinate = providerIntentCoordinate intent
  validateRuntimeEvidence evidence =
    case validateEvidence evidence of
      Left err -> Left (Text.pack (show err))
      Right () -> Right evidence

data ProviderIntentOperation m session
  = IntentMutation !(ProviderMutation m session)
  | IntentReadOnly !(ProviderReadOnly m session)

operationForIntent
  :: ProviderIntentCapabilities m session
  -> ProviderIntent
  -> ProviderIntentOperation m session
operationForIntent capabilities intent = case intent of
  ReconcileRegisteredStack ref revision config ->
    IntentMutation (reconcileRegisteredStackCapability capabilities ref revision config)
  DestroyRegisteredStack ref revision config ->
    IntentMutation (destroyRegisteredStackCapability capabilities ref revision config)
  ObserveRegisteredStack ref ->
    IntentReadOnly (observeRegisteredStackCapability capabilities ref)
  ReadBackRegisteredStack ref ->
    IntentReadOnly (readBackRegisteredStackCapability capabilities ref)
  BoundedScratchCheckpoint ref ->
    IntentMutation (boundedScratchCheckpointCapability capabilities ref)
  ReconcileSesSendingIdentity ref ->
    IntentMutation (reconcileSesSendingIdentityCapability capabilities ref)
  ReconcileSesDkim ref ->
    IntentMutation (reconcileSesDkimCapability capabilities ref)
  ReconcileSesReceiptRules ref ->
    IntentMutation (reconcileSesReceiptRulesCapability capabilities ref)
  ReconcileSesCaptureBucket ref ->
    IntentMutation (reconcileSesCaptureBucketCapability capabilities ref)
  ReconcileSesDns ref ->
    IntentMutation (reconcileSesDnsCapability capabilities ref)
  ObservePublicARecord ref ->
    IntentReadOnly (observePublicARecordCapability capabilities ref)
  ReconcilePublicARecord ref ->
    IntentMutation (reconcilePublicARecordCapability capabilities ref)
  ReapTestEbsVolumes clusterName ->
    IntentMutation (reapTestEbsVolumesCapability capabilities clusterName)
  ObserveOwnedResourceTags query ->
    IntentReadOnly (observeOwnedResourceTagsCapability capabilities query)
  ObserveSpotPrice query ->
    IntentReadOnly (observeSpotPriceCapability capabilities query)
  ObserveOperationalIdentity ->
    IntentReadOnly (observeOperationalIdentityCapability capabilities)
  ObserveProviderAwsScope ->
    IntentReadOnly (observeProviderAwsScopeCapability capabilities)
  ObserveProviderReadiness probe ->
    IntentReadOnly (observeProviderReadinessCapability capabilities probe)
  IssueEksClientAuth request ->
    IntentReadOnly (issueEksClientAuthCapability capabilities request)
  ObserveTestEbsVolumes clusterName ->
    IntentReadOnly (observeTestEbsVolumesCapability capabilities clusterName)
  ObserveValidationHostedZones purpose ->
    IntentReadOnly (observeValidationHostedZonesCapability capabilities purpose)
  ReapValidationHostedZones purpose ->
    IntentMutation (reapValidationHostedZonesCapability capabilities purpose)
  ObserveDns01ChallengeRecords zoneId recordNamePrefix ->
    IntentReadOnly
      (observeDns01ChallengeRecordsCapability capabilities zoneId recordNamePrefix)
  ObserveRetainedEbsVolumes lifecycleValue ->
    IntentReadOnly (observeRetainedEbsVolumesCapability capabilities lifecycleValue)
  ReapRetainedEbsVolumes lifecycleValue ->
    IntentMutation (reapRetainedEbsVolumesCapability capabilities lifecycleValue)
  ObserveEksIamRoleFamily roleNames policyNames ->
    IntentReadOnly
      (observeEksIamRoleFamilyCapability capabilities roleNames policyNames)
  ReapEksIamRoleFamily roleNames policyNames ->
    IntentMutation
      (reapEksIamRoleFamilyCapability capabilities roleNames policyNames)
  ObserveEksLoadBalancerControllerFamily loadBalancerName tags ->
    IntentReadOnly
      ( observeEksLoadBalancerControllerFamilyCapability
          capabilities
          loadBalancerName
          tags
      )
  ReapEksLoadBalancerControllerFamily loadBalancerName tags ->
    IntentMutation
      ( reapEksLoadBalancerControllerFamilyCapability
          capabilities
          loadBalancerName
          tags
      )
  ObserveEksClusterIdentity request ->
    IntentReadOnly (observeEksClusterIdentityCapability capabilities request)
  ObserveNativeStackFamily ref config ->
    IntentReadOnly (observeNativeStackFamilyCapability capabilities ref config)
  ReapNativeStackFamily ref config admittedIdentities ->
    IntentMutation
      (reapNativeStackFamilyCapability capabilities ref config admittedIdentities)

markSnapshotRecovering
  :: (Monad m)
  => ProviderWorkerAdapter m session
  -> ProviderWorkRetainedSnapshot
  -> ProviderIntent
  -> m (Either Text ())
markSnapshotRecovering adapter snapshot intent =
  case internalProviderWorkState current of
    ProviderRecovering _ -> pure (Right ())
    ProviderInFlight coordinate
      | internalProviderWorkActiveIntent current == Just intent ->
          commitAndConfirm
            (providerWorkerRetainedRepository adapter)
            snapshot
            current {internalProviderWorkState = ProviderRecovering coordinate}
    _ -> pure (Left "provider recovery fence no longer owns the active intent")
 where
  current = providerWorkRetainedState snapshot

-- | Startup/crash recovery. In-flight work re-observes and may retry; an
-- explicitly recovering intent only re-observes and never mutates blindly.
resumeProviderWorker
  :: (Monad m)
  => ProviderWorkerAdapter m session
  -> m (Either Text ProviderWorkerResumeResult)
resumeProviderWorker adapter = do
  observed <- readProviderWorkRetainedState (providerWorkerRetainedRepository adapter)
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot ->
      case (internalProviderWorkState durable, internalProviderWorkActiveIntent durable) of
        (ProviderInFlight _, Just intent) -> resume intent
        (ProviderRecovering coordinate, Just intent) -> do
          result <- executeProviderIntent adapter intent
          pure $ case result of
            Right completion -> Right (ProviderWorkerResumed completion)
            Left detail -> Right (ProviderWorkerStillRecovering coordinate detail)
        _ -> pure (Right ProviderWorkerNothingPending)
     where
      durable = providerWorkRetainedState snapshot
      resume intent = do
        result <- executeProviderIntent adapter intent
        pure (ProviderWorkerResumed <$> result)

-- | Readiness requires both the external provider/session boundary and an
-- authoritative retained-state observation. Socket liveness alone is not ready.
providerWorkerAdapterReady :: (Monad m) => ProviderWorkerAdapter m session -> m Bool
providerWorkerAdapterReady adapter = do
  externalReady <- providerWorkerExternalReady adapter
  if not externalReady
    then pure False
    else do
      retained <- readProviderWorkRetainedState (providerWorkerRetainedRepository adapter)
      pure (either (const False) (const True) retained)
