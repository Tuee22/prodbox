{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure write-ahead authority for one exact EKS Kubernetes-owner drain.
--
-- A present-cluster intent consumes an opaque 'EksDrainSession', but retains
-- only its safe identity projection: provider ARN, Kubernetes UID, endpoint
-- and CA digests.  The session, bearer, endpoint, CA material, and reusable
-- kubeconfig never enter this durable value.  Mutation is admitted only after
-- the canonical intent bytes have been independently read back.
--
-- The final opaque evidence proves only that the exact Kubernetes drain
-- targets are absent.  It is not evidence that the EKS cluster, an AWS child,
-- or any other physical AWS resource is absent.
module Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( EksDrainOperationBinding
  , mkEksDrainOperationBinding
  , eksDrainBindingScope
  , eksDrainBindingRunId
  , eksDrainBindingGraphDigest
  , eksDrainBindingIntentCommitOperationId
  , eksDrainBindingIntentReadBackOperationId
  , eksDrainBindingEffectOperationId
  , eksDrainBindingDrainReadBackOperationId
  , EksNamespacedName
  , mkEksNamespacedName
  , eksNamespacedNameNamespace
  , eksNamespacedNameName
  , CompleteLoadBalancerServiceClass (..)
  , CompleteIngressClass (..)
  , CompleteControllerOwnerClass (..)
  , EksDrainTargetSelectionResult (..)
  , EksDrainTargetSelectionObservation (..)
  , eksDrainTargetSelectionObservationFor
  , EksDrainIntentTarget (..)
  , EksDrainIntent
  , prepareEksKubernetesDrainIntent
  , prepareEksNoKubernetesTargetIntent
  , eksDrainIntentBinding
  , eksDrainIntentResourceKey
  , eksDrainIntentCoordinateDigest
  , eksDrainIntentTarget
  , EksDrainIntentDigest
  , eksDrainIntentDigest
  , eksDrainIntentDigestText
  , eksDrainIntentFormatVersion
  , maximumEksDrainIntentBytes
  , maximumEksDrainPvcTargets
  , encodeEksDrainIntent
  , decodeEksDrainIntent
  , EksDrainIntentReadBackObservation (..)
  , CommittedEksDrainIntent
  , confirmEksDrainIntentCommitted
  , committedEksDrainIntent
  , committedEksDrainIntentDigest
  , EksDrainAttemptOutcome (..)
  , EksDrainAttempt
  , beginEksDrainAttempt
  , eksDrainAttemptCommittedIntent
  , eksDrainAttemptId
  , EksDrainAttemptObservation (..)
  , eksDrainAttemptObservationFor
  , EksDrainAttemptEvidence
  , recordEksDrainAttempt
  , eksDrainAttemptIntent
  , eksDrainAttemptIntentDigest
  , eksDrainAttemptEvidenceAttemptId
  , eksDrainAttemptOutcome
  , EksDrainResourceClassReadBack (..)
  , LoadBalancerServiceClassReadBack (..)
  , IngressClassReadBack (..)
  , ControllerOwnerClassReadBack (..)
  , EksDrainPvcReadBackResult (..)
  , EksDrainPvcReadBack (..)
  , EksDrainKubernetesTargetReadBack (..)
  , EksDrainTargetReadBackResult (..)
  , EksDrainTargetReadBackObservation (..)
  , eksDrainTargetReadBackObservationFor
  , EksDrainTargetsAbsentDisposition (..)
  , EksDrainTargetsAbsentEvidence
  , confirmEksDrainTargetsAbsent
  , eksDrainTargetsAbsentIntent
  , eksDrainTargetsAbsentIntentDigest
  , eksDrainTargetsAbsentScope
  , eksDrainTargetsAbsentRunId
  , eksDrainTargetsAbsentGraphDigest
  , eksDrainTargetsAbsentIntentCommitOperationId
  , eksDrainTargetsAbsentIntentReadBackOperationId
  , eksDrainTargetsAbsentEffectOperationId
  , eksDrainTargetsAbsentEffectAttemptId
  , eksDrainTargetsAbsentDrainReadBackOperationId
  , eksDrainTargetsAbsentDisposition
  , EksDrainIntentError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.List (group, sort)
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word64)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( validateEksClusterArnBinding
  )
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupDigestText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.EksDrainSession
  ( EksDrainSession
  , eksClusterArnText
  , eksClusterUidText
  , eksDrainSessionCertificateAuthorityDigest
  , eksDrainSessionClusterArn
  , eksDrainSessionClusterUid
  , eksDrainSessionEndpointDigest
  , eksDrainSessionEvidenceScope
  , eksDrainSessionOperationId
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry

-- | Stable write-ahead, effect, and read-back identities for one cleanup-node
-- attempt.  The graph digest is explicit; the run identity is additionally
-- cross-checked against the durable run carried by the complete evidence
-- scope.
data EksDrainOperationBinding = EksDrainOperationBinding
  { internalEksDrainBindingScope :: !ObservationEvidenceScope
  , internalEksDrainBindingRunId :: !CleanupRunId
  , internalEksDrainBindingGraphDigest :: !CleanupDigest
  , internalEksDrainBindingIntentCommitOperationId :: !CleanupOperationId
  , internalEksDrainBindingIntentReadBackOperationId :: !CleanupOperationId
  , internalEksDrainBindingEffectOperationId :: !CleanupOperationId
  , internalEksDrainBindingDrainReadBackOperationId :: !CleanupOperationId
  }
  deriving (Eq, Show)

mkEksDrainOperationBinding
  :: ObservationEvidenceScope
  -> CleanupRunId
  -> CleanupDigest
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupOperationId
  -> Either EksDrainIntentError EksDrainOperationBinding
mkEksDrainOperationBinding scope runId graphDigest intentCommitOperation intentReadBackOperation effectOperation drainReadBackOperation = do
  validateScope runId scope
  let operations =
        [ intentCommitOperation
        , intentReadBackOperation
        , effectOperation
        , drainReadBackOperation
        ]
  case duplicateValues operations of
    duplicate : _ -> Left (EksDrainOperationIdentityReused duplicate)
    [] ->
      Right
        EksDrainOperationBinding
          { internalEksDrainBindingScope = scope
          , internalEksDrainBindingRunId = runId
          , internalEksDrainBindingGraphDigest = graphDigest
          , internalEksDrainBindingIntentCommitOperationId = intentCommitOperation
          , internalEksDrainBindingIntentReadBackOperationId = intentReadBackOperation
          , internalEksDrainBindingEffectOperationId = effectOperation
          , internalEksDrainBindingDrainReadBackOperationId = drainReadBackOperation
          }

eksDrainBindingScope :: EksDrainOperationBinding -> ObservationEvidenceScope
eksDrainBindingScope = internalEksDrainBindingScope

eksDrainBindingRunId :: EksDrainOperationBinding -> CleanupRunId
eksDrainBindingRunId = internalEksDrainBindingRunId

eksDrainBindingGraphDigest :: EksDrainOperationBinding -> CleanupDigest
eksDrainBindingGraphDigest = internalEksDrainBindingGraphDigest

eksDrainBindingIntentCommitOperationId
  :: EksDrainOperationBinding -> CleanupOperationId
eksDrainBindingIntentCommitOperationId =
  internalEksDrainBindingIntentCommitOperationId

eksDrainBindingIntentReadBackOperationId
  :: EksDrainOperationBinding -> CleanupOperationId
eksDrainBindingIntentReadBackOperationId =
  internalEksDrainBindingIntentReadBackOperationId

eksDrainBindingEffectOperationId :: EksDrainOperationBinding -> CleanupOperationId
eksDrainBindingEffectOperationId = internalEksDrainBindingEffectOperationId

eksDrainBindingDrainReadBackOperationId
  :: EksDrainOperationBinding -> CleanupOperationId
eksDrainBindingDrainReadBackOperationId =
  internalEksDrainBindingDrainReadBackOperationId

data EksNamespacedName = EksNamespacedName
  { internalEksNamespacedNameNamespace :: !Text
  , internalEksNamespacedNameName :: !Text
  }
  deriving (Eq, Ord, Show)

mkEksNamespacedName :: Text -> Text -> Either EksDrainIntentError EksNamespacedName
mkEksNamespacedName namespace name = do
  validateDnsLabel "Kubernetes namespace" namespace
  validateDnsSubdomain "Kubernetes resource name" name
  Right (EksNamespacedName namespace name)

eksNamespacedNameNamespace :: EksNamespacedName -> Text
eksNamespacedNameNamespace = internalEksNamespacedNameNamespace

eksNamespacedNameName :: EksNamespacedName -> Text
eksNamespacedNameName = internalEksNamespacedNameName

-- | Mandatory class marker: the intent covers the complete class selected by
-- @spec.type=LoadBalancer@, not a best-effort list of currently seen names.
data CompleteLoadBalancerServiceClass
  = CompleteLoadBalancerServiceClass
  deriving (Eq, Ord, Show)

-- | Mandatory class marker: the intent covers every Ingress across every
-- namespace, not a best-effort list of currently seen names.
data CompleteIngressClass
  = CompleteIngressClass
  deriving (Eq, Ord, Show)

-- | Mandatory exact controller-owner marker.  Version-2 intents always cover
-- the deterministic public-edge EnvoyProxy before the controller-created AWS
-- family can be reaped.
data CompleteControllerOwnerClass
  = CompleteControllerOwnerClass
  deriving (Eq, Ord, Show)

data EksDrainTargetSelectionResult
  = EksDrainTargetSelectionComplete ![EksNamespacedName]
  | EksDrainTargetSelectionPartial
      ![EksNamespacedName]
      !(NonEmpty ObservationFailure)
  | EksDrainTargetSelectionUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

-- | Flat pre-mutation selection returned by the Kubernetes observer.  Public
-- fields let a decoder represent stale or malformed evidence; the intent
-- constructor is the sole admission boundary.
data EksDrainTargetSelectionObservation = EksDrainTargetSelectionObservation
  { eksDrainSelectionScope :: !ObservationEvidenceScope
  , eksDrainSelectionRevision :: !ObservationRevision
  , eksDrainSelectionClusterArn :: !Text
  , eksDrainSelectionClusterUid :: !Text
  , eksDrainSelectionEndpointDigest :: !Text
  , eksDrainSelectionCertificateAuthorityDigest :: !Text
  , eksDrainSelectionServiceClass :: !CompleteLoadBalancerServiceClass
  , eksDrainSelectionIngressClass :: !CompleteIngressClass
  , eksDrainSelectionControllerOwnerClass :: !CompleteControllerOwnerClass
  , eksDrainSelectionResult :: !EksDrainTargetSelectionResult
  }
  deriving (Eq, Show)

eksDrainTargetSelectionObservationFor
  :: EksDrainSession
  -> ObservationRevision
  -> EksDrainTargetSelectionResult
  -> EksDrainTargetSelectionObservation
eksDrainTargetSelectionObservationFor session revision result =
  EksDrainTargetSelectionObservation
    { eksDrainSelectionScope = eksDrainSessionEvidenceScope session
    , eksDrainSelectionRevision = revision
    , eksDrainSelectionClusterArn =
        eksClusterArnText (eksDrainSessionClusterArn session)
    , eksDrainSelectionClusterUid =
        eksClusterUidText (eksDrainSessionClusterUid session)
    , eksDrainSelectionEndpointDigest = eksDrainSessionEndpointDigest session
    , eksDrainSelectionCertificateAuthorityDigest =
        eksDrainSessionCertificateAuthorityDigest session
    , eksDrainSelectionServiceClass = CompleteLoadBalancerServiceClass
    , eksDrainSelectionIngressClass = CompleteIngressClass
    , eksDrainSelectionControllerOwnerClass = CompleteControllerOwnerClass
    , eksDrainSelectionResult = result
    }

data EksDrainIntentTarget
  = EksDrainExactKubernetesTarget
      { eksDrainTargetProviderArn :: !Text
      , eksDrainTargetKubernetesUid :: !Text
      , eksDrainTargetEndpointDigest :: !Text
      , eksDrainTargetCertificateAuthorityDigest :: !Text
      , eksDrainTargetSelectionRevision :: !ObservationRevision
      , eksDrainTargetLoadBalancerServiceClass
          :: !CompleteLoadBalancerServiceClass
      , eksDrainTargetIngressClass :: !CompleteIngressClass
      , eksDrainTargetControllerOwnerClass :: !CompleteControllerOwnerClass
      , eksDrainTargetDeletePolicyPvcs :: ![EksNamespacedName]
      }
  | EksDrainNoKubernetesTarget
      { eksDrainNoTargetProviderRevision :: !ObservationRevision
      , eksDrainNoTargetProviderEvidence :: !AbsenceEvidence
      }
  deriving (Eq, Show)

data EksDrainIntent = EksDrainIntent
  { internalEksDrainIntentBinding :: !EksDrainOperationBinding
  , internalEksDrainIntentResourceKey :: !RegisteredResourceKey
  , internalEksDrainIntentCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalEksDrainIntentTarget :: !EksDrainIntentTarget
  }
  deriving (Eq, Show)

prepareEksKubernetesDrainIntent
  :: EksDrainOperationBinding
  -> EksDrainSession
  -> EksDrainTargetSelectionObservation
  -> Either EksDrainIntentError EksDrainIntent
prepareEksKubernetesDrainIntent binding session selection = do
  validateExactEksIdentity
  let expectedScope = eksDrainBindingScope binding
      expectedArn = eksClusterArnText (eksDrainSessionClusterArn session)
      expectedUid = eksClusterUidText (eksDrainSessionClusterUid session)
      expectedEndpoint = eksDrainSessionEndpointDigest session
      expectedCa = eksDrainSessionCertificateAuthorityDigest session
  validateProviderArn expectedScope expectedArn
  validateKubernetesUid expectedUid
  validateSha256 "EKS endpoint digest" expectedEndpoint
  validateSha256 "EKS certificate-authority digest" expectedCa
  if eksDrainSessionEvidenceScope session == expectedScope
    then Right ()
    else
      Left
        ( EksDrainSessionScopeMismatch
            expectedScope
            (eksDrainSessionEvidenceScope session)
        )
  if eksDrainSessionOperationId session == eksDrainBindingEffectOperationId binding
    then Right ()
    else
      Left
        ( EksDrainSessionEffectOperationMismatch
            (eksDrainBindingEffectOperationId binding)
            (eksDrainSessionOperationId session)
        )
  validateSelectionBinding
    expectedScope
    expectedArn
    expectedUid
    expectedEndpoint
    expectedCa
    selection
  selected <- case eksDrainSelectionResult selection of
    EksDrainTargetSelectionComplete values -> validatePvcSet values
    EksDrainTargetSelectionPartial _ failures ->
      Left (EksDrainSelectionPartial failures)
    EksDrainTargetSelectionUnobservable failures ->
      Left (EksDrainSelectionUnobservable failures)
  let intent =
        EksDrainIntent
          { internalEksDrainIntentBinding = binding
          , internalEksDrainIntentResourceKey = AwsEksKey
          , internalEksDrainIntentCoordinateDigest = exactEksCoordinateDigest
          , internalEksDrainIntentTarget =
              EksDrainExactKubernetesTarget
                { eksDrainTargetProviderArn = expectedArn
                , eksDrainTargetKubernetesUid = expectedUid
                , eksDrainTargetEndpointDigest = expectedEndpoint
                , eksDrainTargetCertificateAuthorityDigest = expectedCa
                , eksDrainTargetSelectionRevision = eksDrainSelectionRevision selection
                , eksDrainTargetLoadBalancerServiceClass =
                    eksDrainSelectionServiceClass selection
                , eksDrainTargetIngressClass = eksDrainSelectionIngressClass selection
                , eksDrainTargetControllerOwnerClass =
                    eksDrainSelectionControllerOwnerClass selection
                , eksDrainTargetDeletePolicyPvcs = selected
                }
          }
  validateEncodedIntentSize intent
  Right intent

prepareEksNoKubernetesTargetIntent
  :: EksDrainOperationBinding
  -> VerifiedAwsEksObservation purpose
  -> Either EksDrainIntentError EksDrainIntent
prepareEksNoKubernetesTargetIntent binding verified = do
  validateExactEksIdentity
  let observation = verifiedAwsEksExactObservation verified
      expectedScope = eksDrainBindingScope binding
  validateExactObservationBinding expectedScope observation
  evidence <- case exactObservationResult observation of
    ExactResourceAbsent value -> validateAbsenceEvidence value
    ExactResourcePresent _ -> Left EksDrainNoTargetObservationPresent
    ExactResourcePartial _ failures ->
      Left (EksDrainNoTargetObservationPartial failures)
    ExactResourceUnobservable failures ->
      Left (EksDrainNoTargetObservationUnobservable failures)
  let intent =
        EksDrainIntent
          { internalEksDrainIntentBinding = binding
          , internalEksDrainIntentResourceKey = AwsEksKey
          , internalEksDrainIntentCoordinateDigest = exactEksCoordinateDigest
          , internalEksDrainIntentTarget =
              EksDrainNoKubernetesTarget
                { eksDrainNoTargetProviderRevision = exactObservationRevision observation
                , eksDrainNoTargetProviderEvidence = evidence
                }
          }
  validateEncodedIntentSize intent
  Right intent

eksDrainIntentBinding :: EksDrainIntent -> EksDrainOperationBinding
eksDrainIntentBinding = internalEksDrainIntentBinding

eksDrainIntentResourceKey :: EksDrainIntent -> RegisteredResourceKey
eksDrainIntentResourceKey = internalEksDrainIntentResourceKey

eksDrainIntentCoordinateDigest
  :: EksDrainIntent -> ManagedResourceCoordinateDigest
eksDrainIntentCoordinateDigest = internalEksDrainIntentCoordinateDigest

eksDrainIntentTarget :: EksDrainIntent -> EksDrainIntentTarget
eksDrainIntentTarget = internalEksDrainIntentTarget

newtype EksDrainIntentDigest = EksDrainIntentDigest Text
  deriving (Eq, Ord, Show)

eksDrainIntentDigest :: EksDrainIntent -> EksDrainIntentDigest
eksDrainIntentDigest = EksDrainIntentDigest . sha256Bytes . encodeEksDrainIntent

eksDrainIntentDigestText :: EksDrainIntentDigest -> Text
eksDrainIntentDigestText (EksDrainIntentDigest value) = value

eksDrainIntentFormatVersion :: Word16
eksDrainIntentFormatVersion = 2

maximumEksDrainIntentBytes :: Int
maximumEksDrainIntentBytes = 64 * 1024

maximumEksDrainPvcTargets :: Int
maximumEksDrainPvcTargets = 1024

data EksDrainIntentEnvelope = EksDrainIntentEnvelope
  { envelopeVersion :: !Word16
  , envelopeResourceKey :: !Text
  , envelopeCoordinateDigest :: !Text
  , envelopeScope :: !EksDrainScopeWire
  , envelopeRunId :: !Text
  , envelopeGraphDigest :: !Text
  , envelopeIntentCommitOperationId :: !Text
  , envelopeIntentReadBackOperationId :: !Text
  , envelopeEffectOperationId :: !Text
  , envelopeDrainReadBackOperationId :: !Text
  , envelopeTarget :: !EksDrainTargetWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EksDrainScopeWire = EksDrainScopeWire
  { scopeWireSurface :: !Word16
  , scopeWireRegistryRevision :: !Text
  , scopeWireDurableRun :: !Text
  , scopeWireFoundation :: !Text
  , scopeWireAwsAccount :: !Text
  , scopeWireAwsRegion :: !Text
  , scopeWireOperation :: !Word16
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EksDrainTargetWire
  = EksDrainKubernetesTargetWire
      !Text
      !Text
      !Text
      !Text
      !Word64
      !Word16
      !Word16
      !Word16
      ![(Text, Text)]
  | EksDrainNoKubernetesTargetWire !Word64 !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeEksDrainIntent :: EksDrainIntent -> ByteString
encodeEksDrainIntent =
  LazyByteString.toStrict . serialise . intentEnvelope

decodeEksDrainIntent
  :: ByteString -> Either EksDrainIntentError EksDrainIntent
decodeEksDrainIntent bytes
  | ByteString.null bytes = Left EksDrainIntentCodecEmpty
  | ByteString.length bytes > maximumEksDrainIntentBytes =
      Left
        ( EksDrainIntentCodecTooLarge
            (ByteString.length bytes)
            maximumEksDrainIntentBytes
        )
  | otherwise = do
      envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left err -> Left (EksDrainIntentCodecMalformed (Text.pack (show err)))
        Right value -> Right value
      if LazyByteString.toStrict (serialise envelope) == bytes
        then Right ()
        else Left EksDrainIntentCodecNonCanonical
      decodeEnvelope envelope

intentEnvelope :: EksDrainIntent -> EksDrainIntentEnvelope
intentEnvelope intent =
  EksDrainIntentEnvelope
    { envelopeVersion = eksDrainIntentFormatVersion
    , envelopeResourceKey = registeredResourceKeyText (eksDrainIntentResourceKey intent)
    , envelopeCoordinateDigest =
        managedResourceCoordinateDigestText (eksDrainIntentCoordinateDigest intent)
    , envelopeScope = encodeScope (eksDrainBindingScope binding)
    , envelopeRunId = cleanupRunIdText (eksDrainBindingRunId binding)
    , envelopeGraphDigest = cleanupDigestText (eksDrainBindingGraphDigest binding)
    , envelopeIntentCommitOperationId =
        cleanupOperationIdText (eksDrainBindingIntentCommitOperationId binding)
    , envelopeIntentReadBackOperationId =
        cleanupOperationIdText (eksDrainBindingIntentReadBackOperationId binding)
    , envelopeEffectOperationId =
        cleanupOperationIdText (eksDrainBindingEffectOperationId binding)
    , envelopeDrainReadBackOperationId =
        cleanupOperationIdText (eksDrainBindingDrainReadBackOperationId binding)
    , envelopeTarget = encodeTarget (eksDrainIntentTarget intent)
    }
 where
  binding = eksDrainIntentBinding intent

encodeScope :: ObservationEvidenceScope -> EksDrainScopeWire
encodeScope scope =
  EksDrainScopeWire
    { scopeWireSurface = encodeSurface (evidenceCleanupSurface scope)
    , scopeWireRegistryRevision = registryRevisionText (evidenceRegistryRevision scope)
    , scopeWireDurableRun = durableRunScopeText (evidenceDurableRunScope scope)
    , scopeWireFoundation = foundationIdText (evidenceLinuxRke2Foundation scope)
    , scopeWireAwsAccount = maybe "" (awsAccountText . awsScopeAccountId) (evidenceAwsScope scope)
    , scopeWireAwsRegion = maybe "" (awsRegionText . awsScopeRegion) (evidenceAwsScope scope)
    , scopeWireOperation = encodeOperation (evidenceLifecycleOperation scope)
    }

encodeTarget :: EksDrainIntentTarget -> EksDrainTargetWire
encodeTarget target = case target of
  EksDrainExactKubernetesTarget arn uid endpoint ca revision serviceClass ingressClass ownerClass pvcs ->
    EksDrainKubernetesTargetWire
      arn
      uid
      endpoint
      ca
      (observationRevisionWord revision)
      (encodeServiceClass serviceClass)
      (encodeIngressClass ingressClass)
      (encodeControllerOwnerClass ownerClass)
      [ (eksNamespacedNameNamespace pvc, eksNamespacedNameName pvc)
      | pvc <- pvcs
      ]
  EksDrainNoKubernetesTarget revision (AbsenceEvidence evidence) ->
    EksDrainNoKubernetesTargetWire
      (observationRevisionWord revision)
      evidence

decodeEnvelope
  :: EksDrainIntentEnvelope -> Either EksDrainIntentError EksDrainIntent
decodeEnvelope envelope = do
  if envelopeVersion envelope == eksDrainIntentFormatVersion
    then Right ()
    else Left (EksDrainIntentCodecVersionUnsupported (envelopeVersion envelope))
  if envelopeResourceKey envelope == registeredResourceKeyText AwsEksKey
    then Right ()
    else Left (EksDrainIntentCodecResourceKeyInvalid (envelopeResourceKey envelope))
  if envelopeCoordinateDigest envelope == managedResourceCoordinateDigestText exactEksCoordinateDigest
    then Right ()
    else
      Left
        ( EksDrainIntentCodecCoordinateMismatch
            (managedResourceCoordinateDigestText exactEksCoordinateDigest)
            (envelopeCoordinateDigest envelope)
        )
  scope <- decodeScope (envelopeScope envelope)
  runId <- mapIdentityError EksDrainIntentCodecRunIdInvalid (mkCleanupRunId (envelopeRunId envelope))
  graphDigest <-
    mapIdentityError
      EksDrainIntentCodecGraphDigestInvalid
      (mkCleanupDigest (envelopeGraphDigest envelope))
  intentCommitOperation <-
    mapIdentityError
      EksDrainIntentCodecOperationIdInvalid
      (mkCleanupOperationId (envelopeIntentCommitOperationId envelope))
  intentReadBackOperation <-
    mapIdentityError
      EksDrainIntentCodecOperationIdInvalid
      (mkCleanupOperationId (envelopeIntentReadBackOperationId envelope))
  effectOperation <-
    mapIdentityError
      EksDrainIntentCodecOperationIdInvalid
      (mkCleanupOperationId (envelopeEffectOperationId envelope))
  drainReadBackOperation <-
    mapIdentityError
      EksDrainIntentCodecOperationIdInvalid
      (mkCleanupOperationId (envelopeDrainReadBackOperationId envelope))
  binding <-
    mkEksDrainOperationBinding
      scope
      runId
      graphDigest
      intentCommitOperation
      intentReadBackOperation
      effectOperation
      drainReadBackOperation
  target <- decodeTarget scope (envelopeTarget envelope)
  Right
    EksDrainIntent
      { internalEksDrainIntentBinding = binding
      , internalEksDrainIntentResourceKey = AwsEksKey
      , internalEksDrainIntentCoordinateDigest = exactEksCoordinateDigest
      , internalEksDrainIntentTarget = target
      }

decodeScope
  :: EksDrainScopeWire -> Either EksDrainIntentError ObservationEvidenceScope
decodeScope wire = do
  surface <- decodeSurface (scopeWireSurface wire)
  operation <- decodeOperation (scopeWireOperation wire)
  validateBoundedText "registry revision" 256 (scopeWireRegistryRevision wire)
  validateBoundedText "durable observation run" 256 (scopeWireDurableRun wire)
  validateBoundedText "Linux RKE2 foundation" 256 (scopeWireFoundation wire)
  validateAwsAccount (scopeWireAwsAccount wire)
  validateAwsRegion (scopeWireAwsRegion wire)
  Right
    ( mkObservationEvidenceScope
        surface
        (RegistryRevision (scopeWireRegistryRevision wire))
        (DurableObservationRunScope (scopeWireDurableRun wire))
        (LinuxRke2FoundationId (scopeWireFoundation wire))
        ( Just
            ( AwsScope
                (AwsAccountId (scopeWireAwsAccount wire))
                (AwsRegion (scopeWireAwsRegion wire))
            )
        )
        operation
    )

decodeTarget
  :: ObservationEvidenceScope
  -> EksDrainTargetWire
  -> Either EksDrainIntentError EksDrainIntentTarget
decodeTarget scope wire = case wire of
  EksDrainKubernetesTargetWire
    arn
    uid
    endpoint
    ca
    revision
    serviceMarker
    ingressMarker
    ownerMarker
    pvcWires -> do
      validateProviderArn scope arn
      validateKubernetesUid uid
      validateSha256 "EKS endpoint digest" endpoint
      validateSha256 "EKS certificate-authority digest" ca
      serviceClass <- decodeServiceClass serviceMarker
      ingressClass <- decodeIngressClass ingressMarker
      ownerClass <- decodeControllerOwnerClass ownerMarker
      pvcs <- mapM (uncurry mkEksNamespacedName) pvcWires >>= validatePvcSet
      Right
        EksDrainExactKubernetesTarget
          { eksDrainTargetProviderArn = arn
          , eksDrainTargetKubernetesUid = uid
          , eksDrainTargetEndpointDigest = endpoint
          , eksDrainTargetCertificateAuthorityDigest = ca
          , eksDrainTargetSelectionRevision = ObservationRevision revision
          , eksDrainTargetLoadBalancerServiceClass = serviceClass
          , eksDrainTargetIngressClass = ingressClass
          , eksDrainTargetControllerOwnerClass = ownerClass
          , eksDrainTargetDeletePolicyPvcs = pvcs
          }
  EksDrainNoKubernetesTargetWire revision evidence -> do
    absence <- validateAbsenceEvidence (AbsenceEvidence evidence)
    Right
      EksDrainNoKubernetesTarget
        { eksDrainNoTargetProviderRevision = ObservationRevision revision
        , eksDrainNoTargetProviderEvidence = absence
        }

data EksDrainIntentReadBackObservation
  = EksDrainIntentReadBackPresent !ByteString
  | EksDrainIntentReadBackMissing
  | EksDrainIntentReadBackUnobservable !ObservationFailure
  | EksDrainIntentReadBackUnbounded !Int !Int
  deriving (Eq, Show)

-- | Opaque proof that the exact canonical intent was present at the durable
-- boundary before the effect attempt was admitted.
data CommittedEksDrainIntent = CommittedEksDrainIntent
  { internalCommittedEksDrainIntent :: !EksDrainIntent
  , internalCommittedEksDrainIntentDigest :: !EksDrainIntentDigest
  }
  deriving (Eq, Show)

confirmEksDrainIntentCommitted
  :: EksDrainIntent
  -> EksDrainIntentReadBackObservation
  -> Either EksDrainIntentError CommittedEksDrainIntent
confirmEksDrainIntentCommitted expected observation = case observation of
  EksDrainIntentReadBackMissing -> Left EksDrainIntentReadBackMissingRefusal
  EksDrainIntentReadBackUnobservable failure ->
    Left (EksDrainIntentReadBackUnobservableRefusal failure)
  EksDrainIntentReadBackUnbounded actual maximumCardinality ->
    Left (EksDrainIntentReadBackUnboundedRefusal actual maximumCardinality)
  EksDrainIntentReadBackPresent bytes -> do
    observed <- decodeEksDrainIntent bytes
    if observed == expected && bytes == encodeEksDrainIntent expected
      then
        Right
          CommittedEksDrainIntent
            { internalCommittedEksDrainIntent = expected
            , internalCommittedEksDrainIntentDigest = eksDrainIntentDigest expected
            }
      else Left EksDrainIntentReadBackMismatch

committedEksDrainIntent :: CommittedEksDrainIntent -> EksDrainIntent
committedEksDrainIntent = internalCommittedEksDrainIntent

committedEksDrainIntentDigest
  :: CommittedEksDrainIntent -> EksDrainIntentDigest
committedEksDrainIntentDigest = internalCommittedEksDrainIntentDigest

data EksDrainAttemptOutcome
  = EksDrainMutationApplied
  | EksDrainMutationFailed !ObservationFailure
  | EksDrainMutationUnobservable !ObservationFailure
  | EksDrainSkippedNoKubernetesTarget
  deriving (Eq, Show)

-- | Mutation admission created at the drain node's Begin transition.  The
-- actual fence-bound attempt is intentionally absent from the durable intent:
-- recovery may resume the same stable effect operation under a new attempt.
data EksDrainAttempt = EksDrainAttempt
  { internalEksDrainAttemptCommittedIntent :: !CommittedEksDrainIntent
  , internalEksDrainAttemptId :: !CleanupAttemptId
  }
  deriving (Eq, Show)

beginEksDrainAttempt
  :: CommittedEksDrainIntent -> CleanupAttemptId -> EksDrainAttempt
beginEksDrainAttempt = EksDrainAttempt

eksDrainAttemptCommittedIntent
  :: EksDrainAttempt -> CommittedEksDrainIntent
eksDrainAttemptCommittedIntent = internalEksDrainAttemptCommittedIntent

eksDrainAttemptId :: EksDrainAttempt -> CleanupAttemptId
eksDrainAttemptId = internalEksDrainAttemptId

-- | Flat effect response.  Its public fields let a worker decoder represent
-- stale or cross-attempt responses; 'recordEksDrainAttempt' validates every
-- binding before producing opaque attempt evidence.
data EksDrainAttemptObservation = EksDrainAttemptObservation
  { eksDrainAttemptObservationIntentDigest :: !EksDrainIntentDigest
  , eksDrainAttemptObservationScope :: !ObservationEvidenceScope
  , eksDrainAttemptObservationIntentCommitOperationId :: !CleanupOperationId
  , eksDrainAttemptObservationIntentReadBackOperationId :: !CleanupOperationId
  , eksDrainAttemptObservationEffectOperationId :: !CleanupOperationId
  , eksDrainAttemptObservationEffectAttemptId :: !CleanupAttemptId
  , eksDrainAttemptObservationDrainReadBackOperationId :: !CleanupOperationId
  , eksDrainAttemptObservationOutcome :: !EksDrainAttemptOutcome
  }
  deriving (Eq, Show)

eksDrainAttemptObservationFor
  :: EksDrainAttempt
  -> EksDrainAttemptOutcome
  -> EksDrainAttemptObservation
eksDrainAttemptObservationFor attempt outcome =
  EksDrainAttemptObservation
    { eksDrainAttemptObservationIntentDigest = committedEksDrainIntentDigest committed
    , eksDrainAttemptObservationScope = eksDrainBindingScope binding
    , eksDrainAttemptObservationIntentCommitOperationId =
        eksDrainBindingIntentCommitOperationId binding
    , eksDrainAttemptObservationIntentReadBackOperationId =
        eksDrainBindingIntentReadBackOperationId binding
    , eksDrainAttemptObservationEffectOperationId =
        eksDrainBindingEffectOperationId binding
    , eksDrainAttemptObservationEffectAttemptId =
        eksDrainAttemptId attempt
    , eksDrainAttemptObservationDrainReadBackOperationId =
        eksDrainBindingDrainReadBackOperationId binding
    , eksDrainAttemptObservationOutcome = outcome
    }
 where
  committed = eksDrainAttemptCommittedIntent attempt
  binding = eksDrainIntentBinding (committedEksDrainIntent committed)

data EksDrainAttemptEvidence = EksDrainAttemptEvidence
  { internalEksDrainAttemptIntent :: !EksDrainIntent
  , internalEksDrainAttemptIntentDigest :: !EksDrainIntentDigest
  , internalEksDrainAttemptEvidenceAttemptId :: !CleanupAttemptId
  , internalEksDrainAttemptOutcome :: !EksDrainAttemptOutcome
  }
  deriving (Eq, Show)

recordEksDrainAttempt
  :: EksDrainAttempt
  -> EksDrainAttemptObservation
  -> Either EksDrainIntentError EksDrainAttemptEvidence
recordEksDrainAttempt attempt observation = do
  let committed = eksDrainAttemptCommittedIntent attempt
  let intent = committedEksDrainIntent committed
      binding = eksDrainIntentBinding intent
  validateAttemptObservationBinding attempt binding observation
  validateAttemptOutcome (eksDrainIntentTarget intent) (eksDrainAttemptObservationOutcome observation)
  Right
    EksDrainAttemptEvidence
      { internalEksDrainAttemptIntent = intent
      , internalEksDrainAttemptIntentDigest = committedEksDrainIntentDigest committed
      , internalEksDrainAttemptEvidenceAttemptId = eksDrainAttemptId attempt
      , internalEksDrainAttemptOutcome = eksDrainAttemptObservationOutcome observation
      }

eksDrainAttemptIntent :: EksDrainAttemptEvidence -> EksDrainIntent
eksDrainAttemptIntent = internalEksDrainAttemptIntent

eksDrainAttemptIntentDigest
  :: EksDrainAttemptEvidence -> EksDrainIntentDigest
eksDrainAttemptIntentDigest = internalEksDrainAttemptIntentDigest

eksDrainAttemptEvidenceAttemptId
  :: EksDrainAttemptEvidence -> CleanupAttemptId
eksDrainAttemptEvidenceAttemptId = internalEksDrainAttemptEvidenceAttemptId

eksDrainAttemptOutcome :: EksDrainAttemptEvidence -> EksDrainAttemptOutcome
eksDrainAttemptOutcome = internalEksDrainAttemptOutcome

data EksDrainResourceClassReadBack
  = EksDrainResourceClassAbsent !AbsenceEvidence
  | EksDrainResourceClassPresent !(NonEmpty EksNamespacedName)
  | EksDrainResourceClassPartial
      ![EksNamespacedName]
      !(NonEmpty ObservationFailure)
  | EksDrainResourceClassUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

newtype LoadBalancerServiceClassReadBack
  = LoadBalancerServiceClassReadBack EksDrainResourceClassReadBack
  deriving (Eq, Show)

newtype IngressClassReadBack
  = IngressClassReadBack EksDrainResourceClassReadBack
  deriving (Eq, Show)

newtype ControllerOwnerClassReadBack
  = ControllerOwnerClassReadBack EksDrainResourceClassReadBack
  deriving (Eq, Show)

data EksDrainPvcReadBackResult
  = EksDrainPvcAbsent !AbsenceEvidence
  | EksDrainPvcPresent
  | EksDrainPvcUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data EksDrainPvcReadBack = EksDrainPvcReadBack
  { eksDrainPvcReadBackTarget :: !EksNamespacedName
  , eksDrainPvcReadBackResult :: !EksDrainPvcReadBackResult
  }
  deriving (Eq, Show)

data EksDrainKubernetesTargetReadBack = EksDrainKubernetesTargetReadBack
  { eksDrainReadBackProviderArn :: !Text
  , eksDrainReadBackKubernetesUid :: !Text
  , eksDrainReadBackEndpointDigest :: !Text
  , eksDrainReadBackCertificateAuthorityDigest :: !Text
  , eksDrainReadBackLoadBalancerServiceClass
      :: !LoadBalancerServiceClassReadBack
  , eksDrainReadBackIngressClass :: !IngressClassReadBack
  , eksDrainReadBackControllerOwnerClass :: !ControllerOwnerClassReadBack
  , eksDrainReadBackDeletePolicyPvcs :: ![EksDrainPvcReadBack]
  }
  deriving (Eq, Show)

data EksDrainTargetReadBackResult
  = EksDrainObservedKubernetesTarget !EksDrainKubernetesTargetReadBack
  | EksDrainObservedNoKubernetesTarget
  | EksDrainTargetReadBackUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data EksDrainTargetReadBackObservation = EksDrainTargetReadBackObservation
  { eksDrainTargetReadBackIntentDigest :: !EksDrainIntentDigest
  , eksDrainTargetReadBackScope :: !ObservationEvidenceScope
  , eksDrainTargetReadBackIntentCommitOperationId :: !CleanupOperationId
  , eksDrainTargetReadBackIntentReadBackOperationId :: !CleanupOperationId
  , eksDrainTargetReadBackEffectOperationId :: !CleanupOperationId
  , eksDrainTargetReadBackEffectAttemptId :: !CleanupAttemptId
  , eksDrainTargetReadBackDrainReadBackOperationId :: !CleanupOperationId
  , eksDrainTargetReadBackResult :: !EksDrainTargetReadBackResult
  }
  deriving (Eq, Show)

eksDrainTargetReadBackObservationFor
  :: EksDrainAttemptEvidence
  -> EksDrainTargetReadBackResult
  -> EksDrainTargetReadBackObservation
eksDrainTargetReadBackObservationFor attempt result =
  EksDrainTargetReadBackObservation
    { eksDrainTargetReadBackIntentDigest = eksDrainAttemptIntentDigest attempt
    , eksDrainTargetReadBackScope = eksDrainBindingScope binding
    , eksDrainTargetReadBackIntentCommitOperationId =
        eksDrainBindingIntentCommitOperationId binding
    , eksDrainTargetReadBackIntentReadBackOperationId =
        eksDrainBindingIntentReadBackOperationId binding
    , eksDrainTargetReadBackEffectOperationId =
        eksDrainBindingEffectOperationId binding
    , eksDrainTargetReadBackEffectAttemptId =
        eksDrainAttemptEvidenceAttemptId attempt
    , eksDrainTargetReadBackDrainReadBackOperationId =
        eksDrainBindingDrainReadBackOperationId binding
    , eksDrainTargetReadBackResult = result
    }
 where
  binding = eksDrainIntentBinding (eksDrainAttemptIntent attempt)

data EksDrainTargetsAbsentDisposition
  = ExactKubernetesDrainTargetsAbsent
  | NoKubernetesDrainTargetRequired
  deriving (Eq, Show)

-- | Positive, opaque evidence concerning only the Kubernetes target set
-- recorded by this intent.  No conversion to AWS resource absence exists.
data EksDrainTargetsAbsentEvidence = EksDrainTargetsAbsentEvidence
  { internalEksDrainTargetsAbsentIntent :: !EksDrainIntent
  , internalEksDrainTargetsAbsentIntentDigest :: !EksDrainIntentDigest
  , internalEksDrainTargetsAbsentEffectAttemptId :: !CleanupAttemptId
  , internalEksDrainTargetsAbsentDisposition
      :: !EksDrainTargetsAbsentDisposition
  }
  deriving (Eq, Show)

confirmEksDrainTargetsAbsent
  :: EksDrainAttemptEvidence
  -> EksDrainTargetReadBackObservation
  -> Either EksDrainIntentError EksDrainTargetsAbsentEvidence
confirmEksDrainTargetsAbsent attempt observation = do
  let intent = eksDrainAttemptIntent attempt
      binding = eksDrainIntentBinding intent
  validateReadBackObservationBinding attempt binding observation
  disposition <- case (eksDrainIntentTarget intent, eksDrainTargetReadBackResult observation) of
    (EksDrainNoKubernetesTarget {}, EksDrainObservedNoKubernetesTarget)
      | eksDrainAttemptOutcome attempt == EksDrainSkippedNoKubernetesTarget ->
          Right NoKubernetesDrainTargetRequired
    (EksDrainNoKubernetesTarget {}, EksDrainObservedNoKubernetesTarget) ->
      Left (EksDrainNoTargetAttemptOutcomeInvalid (eksDrainAttemptOutcome attempt))
    (EksDrainNoKubernetesTarget {}, observed) ->
      Left (EksDrainReadBackTargetArmMismatch observed)
    (EksDrainExactKubernetesTarget {}, EksDrainObservedKubernetesTarget readBack) -> do
      validateKubernetesReadBack (eksDrainIntentTarget intent) readBack
      Right ExactKubernetesDrainTargetsAbsent
    (EksDrainExactKubernetesTarget {}, observed) ->
      Left (EksDrainReadBackTargetArmMismatch observed)
  Right
    EksDrainTargetsAbsentEvidence
      { internalEksDrainTargetsAbsentIntent = intent
      , internalEksDrainTargetsAbsentIntentDigest = eksDrainAttemptIntentDigest attempt
      , internalEksDrainTargetsAbsentEffectAttemptId =
          eksDrainAttemptEvidenceAttemptId attempt
      , internalEksDrainTargetsAbsentDisposition = disposition
      }

eksDrainTargetsAbsentIntent
  :: EksDrainTargetsAbsentEvidence -> EksDrainIntent
eksDrainTargetsAbsentIntent = internalEksDrainTargetsAbsentIntent

eksDrainTargetsAbsentIntentDigest
  :: EksDrainTargetsAbsentEvidence -> EksDrainIntentDigest
eksDrainTargetsAbsentIntentDigest = internalEksDrainTargetsAbsentIntentDigest

eksDrainTargetsAbsentScope
  :: EksDrainTargetsAbsentEvidence -> ObservationEvidenceScope
eksDrainTargetsAbsentScope =
  eksDrainBindingScope . eksDrainIntentBinding . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentRunId :: EksDrainTargetsAbsentEvidence -> CleanupRunId
eksDrainTargetsAbsentRunId =
  eksDrainBindingRunId . eksDrainIntentBinding . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentGraphDigest
  :: EksDrainTargetsAbsentEvidence -> CleanupDigest
eksDrainTargetsAbsentGraphDigest =
  eksDrainBindingGraphDigest . eksDrainIntentBinding . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentIntentCommitOperationId
  :: EksDrainTargetsAbsentEvidence -> CleanupOperationId
eksDrainTargetsAbsentIntentCommitOperationId =
  eksDrainBindingIntentCommitOperationId
    . eksDrainIntentBinding
    . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentIntentReadBackOperationId
  :: EksDrainTargetsAbsentEvidence -> CleanupOperationId
eksDrainTargetsAbsentIntentReadBackOperationId =
  eksDrainBindingIntentReadBackOperationId
    . eksDrainIntentBinding
    . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentEffectOperationId
  :: EksDrainTargetsAbsentEvidence -> CleanupOperationId
eksDrainTargetsAbsentEffectOperationId =
  eksDrainBindingEffectOperationId
    . eksDrainIntentBinding
    . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentEffectAttemptId
  :: EksDrainTargetsAbsentEvidence -> CleanupAttemptId
eksDrainTargetsAbsentEffectAttemptId =
  internalEksDrainTargetsAbsentEffectAttemptId

eksDrainTargetsAbsentDrainReadBackOperationId
  :: EksDrainTargetsAbsentEvidence -> CleanupOperationId
eksDrainTargetsAbsentDrainReadBackOperationId =
  eksDrainBindingDrainReadBackOperationId
    . eksDrainIntentBinding
    . eksDrainTargetsAbsentIntent

eksDrainTargetsAbsentDisposition
  :: EksDrainTargetsAbsentEvidence -> EksDrainTargetsAbsentDisposition
eksDrainTargetsAbsentDisposition = internalEksDrainTargetsAbsentDisposition

data EksDrainIntentError
  = EksDrainSurfaceInvalid !CleanupSurface
  | EksDrainRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | EksDrainRunScopeMismatch !DurableObservationRunScope !DurableObservationRunScope
  | EksDrainAwsScopeMissing
  | EksDrainScopeOperationInvalid !LifecycleOperation
  | EksDrainOperationIdentityReused !CleanupOperationId
  | EksDrainRegistryIdentityMissing
  | EksDrainRegistryIdentityMismatch !RegisteredResourceKey
  | EksDrainRegistryIdentityKindMismatch !ResourceKind
  | EksDrainRegistryCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | EksDrainObservationAuthorityMismatch !ObservationAuthority
  | EksDrainObservationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainSessionScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainSessionEffectOperationMismatch !CleanupOperationId !CleanupOperationId
  | EksDrainSelectionScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainSelectionClusterArnMismatch !Text !Text
  | EksDrainSelectionClusterUidMismatch !Text !Text
  | EksDrainSelectionEndpointDigestMismatch !Text !Text
  | EksDrainSelectionCertificateAuthorityDigestMismatch !Text !Text
  | EksDrainSelectionPartial !(NonEmpty ObservationFailure)
  | EksDrainSelectionUnobservable !(NonEmpty ObservationFailure)
  | EksDrainPvcTargetLimitExceeded !Int !Int
  | EksDrainPvcTargetDuplicate !EksNamespacedName
  | EksDrainKubernetesNameInvalid !Text !Text
  | EksDrainProviderArnInvalid !Text
  | EksDrainKubernetesUidInvalid !Text
  | EksDrainSha256Invalid !Text !Text
  | EksDrainNoTargetObservationPresent
  | EksDrainNoTargetObservationPartial !(NonEmpty ObservationFailure)
  | EksDrainNoTargetObservationUnobservable !(NonEmpty ObservationFailure)
  | EksDrainAbsenceEvidenceInvalid !Text
  | EksDrainIntentCodecEmpty
  | EksDrainIntentCodecTooLarge !Int !Int
  | EksDrainIntentCodecMalformed !Text
  | EksDrainIntentCodecNonCanonical
  | EksDrainIntentCodecVersionUnsupported !Word16
  | EksDrainIntentCodecResourceKeyInvalid !Text
  | EksDrainIntentCodecCoordinateMismatch !Text !Text
  | EksDrainIntentCodecSurfaceInvalid !Word16
  | EksDrainIntentCodecOperationInvalid !Word16
  | EksDrainIntentCodecServiceClassInvalid !Word16
  | EksDrainIntentCodecIngressClassInvalid !Word16
  | EksDrainIntentCodecControllerOwnerClassInvalid !Word16
  | EksDrainIntentCodecRunIdInvalid !Text
  | EksDrainIntentCodecGraphDigestInvalid !Text
  | EksDrainIntentCodecOperationIdInvalid !Text
  | EksDrainIntentTextInvalid !Text !Text
  | EksDrainAwsAccountInvalid !Text
  | EksDrainAwsRegionInvalid !Text
  | EksDrainIntentReadBackMissingRefusal
  | EksDrainIntentReadBackUnobservableRefusal !ObservationFailure
  | EksDrainIntentReadBackUnboundedRefusal !Int !Int
  | EksDrainIntentReadBackMismatch
  | EksDrainAttemptBindingMismatch
  | EksDrainAttemptOutcomeInvalid !EksDrainIntentTarget !EksDrainAttemptOutcome
  | EksDrainNoTargetAttemptOutcomeInvalid !EksDrainAttemptOutcome
  | EksDrainTargetReadBackBindingMismatch
  | EksDrainReadBackTargetArmMismatch !EksDrainTargetReadBackResult
  | EksDrainReadBackIdentityMismatch
  | EksDrainServiceClassNotAbsent !EksDrainResourceClassReadBack
  | EksDrainIngressClassNotAbsent !EksDrainResourceClassReadBack
  | EksDrainControllerOwnerClassNotAbsent !EksDrainResourceClassReadBack
  | EksDrainPvcReadBackDuplicate !EksNamespacedName
  | EksDrainPvcReadBackMissing !EksNamespacedName
  | EksDrainPvcReadBackUnexpected !EksNamespacedName
  | EksDrainPvcNotAbsent !EksNamespacedName !EksDrainPvcReadBackResult
  deriving (Eq, Show)

validateScope
  :: CleanupRunId
  -> ObservationEvidenceScope
  -> Either EksDrainIntentError ()
validateScope runId scope = do
  case evidenceCleanupSurface scope of
    Cascade -> Right ()
    ExplicitPerRun -> Right ()
    TotalDecommission -> Right ()
    other -> Left (EksDrainSurfaceInvalid other)
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( EksDrainRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  let expectedRunScope = DurableObservationRunScope (cleanupRunIdText runId)
  if evidenceDurableRunScope scope == expectedRunScope
    then Right ()
    else
      Left
        ( EksDrainRunScopeMismatch
            expectedRunScope
            (evidenceDurableRunScope scope)
        )
  case evidenceAwsScope scope of
    Nothing -> Left EksDrainAwsScopeMissing
    Just (AwsScope (AwsAccountId account) (AwsRegion region)) -> do
      validateAwsAccount account
      validateAwsRegion region
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (EksDrainScopeOperationInvalid (evidenceLifecycleOperation scope))

validateExactEksIdentity :: Either EksDrainIntentError ()
validateExactEksIdentity = case lookupRegisteredIdentity AwsEksKey of
  Nothing -> Left EksDrainRegistryIdentityMissing
  Just identity
    | registeredIdentityKind identity /= Stack ->
        Left (EksDrainRegistryIdentityKindMismatch (registeredIdentityKind identity))
    | registeredIdentityCoordinateDigest identity /= exactEksCoordinateDigest ->
        Left
          ( EksDrainRegistryCoordinateMismatch
              exactEksCoordinateDigest
              (registeredIdentityCoordinateDigest identity)
          )
    | otherwise -> Right ()

exactEksCoordinateDigest :: ManagedResourceCoordinateDigest
exactEksCoordinateDigest =
  Registry.managedResourceCoordinateDigest Registry.awsEksResource

validateExactObservationBinding
  :: ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either EksDrainIntentError ()
validateExactObservationBinding expectedScope observation = do
  if exactObservationResourceKey observation == AwsEksKey
    then Right ()
    else Left (EksDrainRegistryIdentityMismatch (exactObservationResourceKey observation))
  if exactObservationCoordinateDigest observation == exactEksCoordinateDigest
    then Right ()
    else
      Left
        ( EksDrainRegistryCoordinateMismatch
            exactEksCoordinateDigest
            (exactObservationCoordinateDigest observation)
        )
  if exactObservationAuthority observation == AwsResourceApiAuthority
    then Right ()
    else Left (EksDrainObservationAuthorityMismatch (exactObservationAuthority observation))
  if exactObservationEvidenceScope observation == expectedScope
    then Right ()
    else
      Left
        ( EksDrainObservationScopeMismatch
            expectedScope
            (exactObservationEvidenceScope observation)
        )

validateSelectionBinding
  :: ObservationEvidenceScope
  -> Text
  -> Text
  -> Text
  -> Text
  -> EksDrainTargetSelectionObservation
  -> Either EksDrainIntentError ()
validateSelectionBinding scope arn uid endpoint ca selection = do
  if eksDrainSelectionScope selection == scope
    then Right ()
    else Left (EksDrainSelectionScopeMismatch scope (eksDrainSelectionScope selection))
  requireEqual EksDrainSelectionClusterArnMismatch arn (eksDrainSelectionClusterArn selection)
  requireEqual EksDrainSelectionClusterUidMismatch uid (eksDrainSelectionClusterUid selection)
  requireEqual
    EksDrainSelectionEndpointDigestMismatch
    endpoint
    (eksDrainSelectionEndpointDigest selection)
  requireEqual
    EksDrainSelectionCertificateAuthorityDigestMismatch
    ca
    (eksDrainSelectionCertificateAuthorityDigest selection)

validatePvcSet
  :: [EksNamespacedName]
  -> Either EksDrainIntentError [EksNamespacedName]
validatePvcSet values
  | length values > maximumEksDrainPvcTargets =
      Left (EksDrainPvcTargetLimitExceeded (length values) maximumEksDrainPvcTargets)
  | duplicate : _ <- duplicateValues values = Left (EksDrainPvcTargetDuplicate duplicate)
  | otherwise = Right (sort values)

validateEncodedIntentSize
  :: EksDrainIntent -> Either EksDrainIntentError ()
validateEncodedIntentSize intent =
  let actual = ByteString.length (encodeEksDrainIntent intent)
   in if actual <= maximumEksDrainIntentBytes
        then Right ()
        else Left (EksDrainIntentCodecTooLarge actual maximumEksDrainIntentBytes)

validateProviderArn
  :: ObservationEvidenceScope -> Text -> Either EksDrainIntentError ()
validateProviderArn scope arn = case evidenceAwsScope scope of
  Nothing -> Left EksDrainAwsScopeMissing
  Just (AwsScope (AwsAccountId account) (AwsRegion region)) ->
    case validateEksClusterArnBinding
      account
      region
      (Text.pack awsEksCanonicalClusterName)
      arn of
      Left _ -> Left (EksDrainProviderArnInvalid arn)
      Right () -> Right ()

validateKubernetesUid :: Text -> Either EksDrainIntentError ()
validateKubernetesUid value
  | Text.null value || Text.length value > 256 =
      Left (EksDrainKubernetesUidInvalid value)
  | Text.all validIdentityCharacter value = Right ()
  | otherwise = Left (EksDrainKubernetesUidInvalid value)
 where
  validIdentityCharacter character =
    isAsciiLower character
      || isDigit character
      || character `elem` ("-._/" :: String)

validateSha256 :: Text -> Text -> Either EksDrainIntentError ()
validateSha256 label value
  | Text.length value == 64 && Text.all isLowerHex value = Right ()
  | otherwise = Left (EksDrainSha256Invalid label value)
 where
  isLowerHex character = character `elem` ("0123456789abcdef" :: String)

validateAbsenceEvidence
  :: AbsenceEvidence -> Either EksDrainIntentError AbsenceEvidence
validateAbsenceEvidence evidence@(AbsenceEvidence value)
  | Text.null value || Text.length value > 512 =
      Left (EksDrainAbsenceEvidenceInvalid value)
  | otherwise = Right evidence

validateAttemptObservationBinding
  :: EksDrainAttempt
  -> EksDrainOperationBinding
  -> EksDrainAttemptObservation
  -> Either EksDrainIntentError ()
validateAttemptObservationBinding attempt binding observation
  | eksDrainAttemptObservationIntentDigest observation /= committedEksDrainIntentDigest committed =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationScope observation /= eksDrainBindingScope binding =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationIntentCommitOperationId observation
      /= eksDrainBindingIntentCommitOperationId binding =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationIntentReadBackOperationId observation
      /= eksDrainBindingIntentReadBackOperationId binding =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationEffectOperationId observation
      /= eksDrainBindingEffectOperationId binding =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationEffectAttemptId observation
      /= eksDrainAttemptId attempt =
      Left EksDrainAttemptBindingMismatch
  | eksDrainAttemptObservationDrainReadBackOperationId observation
      /= eksDrainBindingDrainReadBackOperationId binding =
      Left EksDrainAttemptBindingMismatch
  | otherwise = Right ()
 where
  committed = eksDrainAttemptCommittedIntent attempt

validateAttemptOutcome
  :: EksDrainIntentTarget
  -> EksDrainAttemptOutcome
  -> Either EksDrainIntentError ()
validateAttemptOutcome target outcome = case (target, outcome) of
  (EksDrainExactKubernetesTarget {}, EksDrainMutationApplied) -> Right ()
  (EksDrainExactKubernetesTarget {}, EksDrainMutationFailed _) -> Right ()
  (EksDrainExactKubernetesTarget {}, EksDrainMutationUnobservable _) -> Right ()
  (EksDrainNoKubernetesTarget {}, EksDrainSkippedNoKubernetesTarget) -> Right ()
  _ -> Left (EksDrainAttemptOutcomeInvalid target outcome)

validateReadBackObservationBinding
  :: EksDrainAttemptEvidence
  -> EksDrainOperationBinding
  -> EksDrainTargetReadBackObservation
  -> Either EksDrainIntentError ()
validateReadBackObservationBinding attempt binding observation
  | eksDrainTargetReadBackIntentDigest observation /= eksDrainAttemptIntentDigest attempt =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackScope observation /= eksDrainBindingScope binding =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackIntentCommitOperationId observation
      /= eksDrainBindingIntentCommitOperationId binding =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackIntentReadBackOperationId observation
      /= eksDrainBindingIntentReadBackOperationId binding =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackEffectOperationId observation
      /= eksDrainBindingEffectOperationId binding =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackEffectAttemptId observation
      /= eksDrainAttemptEvidenceAttemptId attempt =
      Left EksDrainTargetReadBackBindingMismatch
  | eksDrainTargetReadBackDrainReadBackOperationId observation
      /= eksDrainBindingDrainReadBackOperationId binding =
      Left EksDrainTargetReadBackBindingMismatch
  | otherwise = Right ()

validateKubernetesReadBack
  :: EksDrainIntentTarget
  -> EksDrainKubernetesTargetReadBack
  -> Either EksDrainIntentError ()
validateKubernetesReadBack target readBack = case target of
  EksDrainNoKubernetesTarget {} -> Left EksDrainReadBackIdentityMismatch
  EksDrainExactKubernetesTarget arn uid endpoint ca _ _ _ _ pvcs -> do
    if ( arn
       , uid
       , endpoint
       , ca
       )
      == ( eksDrainReadBackProviderArn readBack
         , eksDrainReadBackKubernetesUid readBack
         , eksDrainReadBackEndpointDigest readBack
         , eksDrainReadBackCertificateAuthorityDigest readBack
         )
      then Right ()
      else Left EksDrainReadBackIdentityMismatch
    case eksDrainReadBackLoadBalancerServiceClass readBack of
      LoadBalancerServiceClassReadBack (EksDrainResourceClassAbsent _) -> Right ()
      LoadBalancerServiceClassReadBack observed ->
        Left (EksDrainServiceClassNotAbsent observed)
    case eksDrainReadBackIngressClass readBack of
      IngressClassReadBack (EksDrainResourceClassAbsent _) -> Right ()
      IngressClassReadBack observed -> Left (EksDrainIngressClassNotAbsent observed)
    case eksDrainReadBackControllerOwnerClass readBack of
      ControllerOwnerClassReadBack (EksDrainResourceClassAbsent _) -> Right ()
      ControllerOwnerClassReadBack observed ->
        Left (EksDrainControllerOwnerClassNotAbsent observed)
    validatePvcReadBack pvcs (eksDrainReadBackDeletePolicyPvcs readBack)

validatePvcReadBack
  :: [EksNamespacedName]
  -> [EksDrainPvcReadBack]
  -> Either EksDrainIntentError ()
validatePvcReadBack expected observations = do
  let observedTargets = map eksDrainPvcReadBackTarget observations
  case duplicateValues observedTargets of
    duplicate : _ -> Left (EksDrainPvcReadBackDuplicate duplicate)
    [] -> Right ()
  let expectedSet = Set.fromList expected
      observedSet = Set.fromList observedTargets
  case Set.lookupMin (expectedSet `Set.difference` observedSet) of
    Just missing -> Left (EksDrainPvcReadBackMissing missing)
    Nothing -> Right ()
  case Set.lookupMin (observedSet `Set.difference` expectedSet) of
    Just unexpected -> Left (EksDrainPvcReadBackUnexpected unexpected)
    Nothing -> Right ()
  mapM_ requireAbsent observations
 where
  requireAbsent observation = case eksDrainPvcReadBackResult observation of
    EksDrainPvcAbsent _ -> Right ()
    result -> Left (EksDrainPvcNotAbsent (eksDrainPvcReadBackTarget observation) result)

encodeSurface :: CleanupSurface -> Word16
encodeSurface surface = case surface of
  Cascade -> 1
  ExplicitPerRun -> 2
  TotalDecommission -> 3
  LocalOnly -> 101
  OperationalTeardown -> 102
  ExplicitLongLived -> 103

decodeSurface :: Word16 -> Either EksDrainIntentError CleanupSurface
decodeSurface tag = case tag of
  1 -> Right Cascade
  2 -> Right ExplicitPerRun
  3 -> Right TotalDecommission
  _ -> Left (EksDrainIntentCodecSurfaceInvalid tag)

encodeOperation :: LifecycleOperation -> Word16
encodeOperation operation = case operation of
  ReconcileDesiredAbsent -> 1
  ReconcileDesiredPresent -> 101
  RunTerminalEscapeAudit -> 102

decodeOperation :: Word16 -> Either EksDrainIntentError LifecycleOperation
decodeOperation tag = case tag of
  1 -> Right ReconcileDesiredAbsent
  _ -> Left (EksDrainIntentCodecOperationInvalid tag)

encodeServiceClass :: CompleteLoadBalancerServiceClass -> Word16
encodeServiceClass CompleteLoadBalancerServiceClass = 1

decodeServiceClass
  :: Word16
  -> Either EksDrainIntentError CompleteLoadBalancerServiceClass
decodeServiceClass tag = case tag of
  1 -> Right CompleteLoadBalancerServiceClass
  _ -> Left (EksDrainIntentCodecServiceClassInvalid tag)

encodeIngressClass :: CompleteIngressClass -> Word16
encodeIngressClass CompleteIngressClass = 1

decodeIngressClass :: Word16 -> Either EksDrainIntentError CompleteIngressClass
decodeIngressClass tag = case tag of
  1 -> Right CompleteIngressClass
  _ -> Left (EksDrainIntentCodecIngressClassInvalid tag)

encodeControllerOwnerClass :: CompleteControllerOwnerClass -> Word16
encodeControllerOwnerClass CompleteControllerOwnerClass = 1

decodeControllerOwnerClass
  :: Word16 -> Either EksDrainIntentError CompleteControllerOwnerClass
decodeControllerOwnerClass tag = case tag of
  1 -> Right CompleteControllerOwnerClass
  _ -> Left (EksDrainIntentCodecControllerOwnerClassInvalid tag)

validateDnsLabel
  :: Text -> Text -> Either EksDrainIntentError ()
validateDnsLabel label value
  | Text.null value || Text.length value > 63 =
      Left (EksDrainKubernetesNameInvalid label value)
  | not (isLowerAlphaNumeric (Text.head value)) =
      Left (EksDrainKubernetesNameInvalid label value)
  | not (isLowerAlphaNumeric (Text.last value)) =
      Left (EksDrainKubernetesNameInvalid label value)
  | Text.all validLabelCharacter value = Right ()
  | otherwise = Left (EksDrainKubernetesNameInvalid label value)
 where
  validLabelCharacter character =
    isLowerAlphaNumeric character || character == '-'
  isLowerAlphaNumeric character = isAsciiLower character || isDigit character

validateDnsSubdomain
  :: Text -> Text -> Either EksDrainIntentError ()
validateDnsSubdomain label value
  | Text.null value || Text.length value > 253 =
      Left (EksDrainKubernetesNameInvalid label value)
  | otherwise = mapM_ (validateDnsLabel label) (Text.splitOn "." value)

validateBoundedText
  :: Text -> Int -> Text -> Either EksDrainIntentError ()
validateBoundedText label maximumLength value
  | Text.null value || Text.length value > maximumLength =
      Left (EksDrainIntentTextInvalid label value)
  | otherwise = Right ()

validateAwsAccount :: Text -> Either EksDrainIntentError ()
validateAwsAccount value
  | Text.length value == 12 && Text.all isDigit value = Right ()
  | otherwise = Left (EksDrainAwsAccountInvalid value)

validateAwsRegion :: Text -> Either EksDrainIntentError ()
validateAwsRegion value
  | Text.null value || Text.length value > 64 = Left (EksDrainAwsRegionInvalid value)
  | Text.all validCharacter value = Right ()
  | otherwise = Left (EksDrainAwsRegionInvalid value)
 where
  validCharacter character = isAsciiLower character || isDigit character || character == '-'

mapIdentityError
  :: (Text -> EksDrainIntentError)
  -> Either Text value
  -> Either EksDrainIntentError value
mapIdentityError wrap = either (Left . wrap) Right

requireEqual
  :: (Eq value)
  => (value -> value -> EksDrainIntentError)
  -> value
  -> value
  -> Either EksDrainIntentError ()
requireEqual mismatch expected actual
  | expected == actual = Right ()
  | otherwise = Left (mismatch expected actual)

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues = foldr duplicateGroup [] . group . sort
 where
  duplicateGroup values duplicates = case values of
    duplicate : _ : _ -> duplicate : duplicates
    _ -> duplicates

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationIdText :: LinuxRke2FoundationId -> Text
foundationIdText (LinuxRke2FoundationId value) = value

awsAccountText :: AwsAccountId -> Text
awsAccountText (AwsAccountId value) = value

awsRegionText :: AwsRegion -> Text
awsRegionText (AwsRegion value) = value

observationRevisionWord :: ObservationRevision -> Word64
observationRevisionWord (ObservationRevision value) = value

sha256Bytes :: ByteString -> Text
sha256Bytes = TextEncoding.decodeUtf8 . hexSha256
