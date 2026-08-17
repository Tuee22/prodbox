{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private recovery-plane identity, canonical profile, and evidence
-- transitions.  Authority code derives the identity only through the opaque
-- descriptor-bound cleanup-run join; fixed regressions exercise the pure
-- boundary without exporting a proof-making fixture.
module Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneProfileDigest
  , recoveryPlaneProfileDigestText
  , RecoveryPlaneComponentIdentity (..)
  , recoveryPlaneComponentIdentityText
  , RecoveryPlaneComponentFailureKind (..)
  , RecoveryPlaneComponentFailure
  , recoveryPlaneComponentFailureIdentity
  , recoveryPlaneComponentFailureKind
  , RecoveryPlaneIdentity
  , recoveryPlaneIdentitySurface
  , recoveryPlaneIdentityRunId
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityCapabilityCatalogDigest
  , recoveryPlaneIdentityRequirementDigest
  , recoveryPlaneIdentityTargetAgent
  , recoveryPlaneIdentityProfileDigest
  , recoveryPlaneIdentityComponents
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityReadBackOperationId
  , recoveryPlaneIdentityDispositionOperationId
  , RecoveryPlaneInitialReadBack
  , recoveryPlaneInitialIdentity
  , recoveryPlaneInitialEstablishAttemptId
  , recoveryPlaneInitialReadBackAttemptId
  , recoveryPlaneInitialFailures
  , recoveryPlaneInitialFactsInternal
  , RecoveryPlaneInitialDisposition (..)
  , recoveryPlaneInitialDisposition
  , recoveryPlaneInitialReady
  , RecoveryPlaneReady
  , recoveryPlaneReadyIdentity
  , recoveryPlaneReadyEstablishAttemptId
  , recoveryPlaneReadyReadBackAttemptId
  , RecoveryPlaneFinalEvidence
  , RecoveryPlaneFinalDisposition (..)
  , recoveryPlaneFinalIdentity
  , recoveryPlaneFinalEstablishAttemptId
  , recoveryPlaneFinalInitialReadBackAttemptId
  , recoveryPlaneFinalDispositionAttemptId
  , recoveryPlaneFinalDisposition
  , recoveryPlaneFinalFailures
  , recoveryPlaneFinalEstablishedReady
  , RecoveryPlaneEvidenceError (..)
  , RecoveryPlaneProfile
  , deriveRecoveryPlaneProfileInternal
  , deriveRecoveryPlaneIdentityFromCompiledInternal
  , restoreRecoveryPlaneIdentityFromCompiledInternal
  , RecoveryPlaneRawComponentResult (..)
  , RecoveryPlaneRawComponentObservation (..)
  , RecoveryPlaneComponentObservationSet
  , recoveryPlaneComponentObservationSetInternal
  , RecoveryPlaneAttemptBinding (..)
  , recoveryPlaneAttemptBindingInternal
  , recoveryPlaneAttemptBindingAfterBeginInternal
  , RecoveryPlaneNormalizedComponentFact (..)
  , RecoveryPlaneNormalizedComponentState (..)
  , RecoveryPlaneNormalizedFacts
  , recoveryPlaneNormalizedFactsEntries
  , normalizeRecoveryPlaneComponentFactsInternal
  , mkRecoveryPlaneInitialReadBackInternal
  , mkRecoveryPlaneFinalEvidenceInternal
  , RecoveryPlaneIdentityWire
  , encodeRecoveryPlaneIdentityWireInternal
  , decodeRecoveryPlaneIdentityWireInternal
  , maximumRecoveryPlaneIdentityBytes
  , RecoveryPlaneFixtureRegression
  , fixedRecoveryPlaneFixtureRegression
  , recoveryPlaneFixtureProfileCanonical
  , recoveryPlaneFixtureProfileTargetAgentSeparated
  , recoveryPlaneFixtureIdentityCanonical
  , recoveryPlaneFixtureExactCompletenessEnforced
  , recoveryPlaneFixtureEveryFailureRefused
  , recoveryPlaneFixtureDiagnosticsNormalized
  , recoveryPlaneFixtureInitialReadyExact
  , recoveryPlaneFixtureEstablishedFromReady
  , recoveryPlaneFixtureEstablishedAfterInitialFailure
  , recoveryPlaneFixtureNotEstablishedExact
  , recoveryPlaneFixtureLostExact
  , recoveryPlaneFixtureLostHidesReady
  , recoveryPlaneFixtureCrossBindingRefused
  , recoveryPlaneFixtureDynamicProfileRestored
  , fixedRecoveryPlaneIdentityInternal
  , fixedRecoveryPlaneTargetIdentityInternal
  , fixedRecoveryPlaneEstablishAttemptIdInternal
  , fixedRecoveryPlaneReadBackAttemptIdInternal
  , fixedRecoveryPlaneDispositionAttemptIdInternal
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, void, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.List (find, group, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.ComponentGraph
  ( ComponentDependency (..)
  , ComponentId
  , ComponentNode (..)
  , EdgeKind (..)
  , ReadinessProbe (..)
  , componentDagNodes
  , componentDagOrder
  , componentIdText
  )
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownCapability (..)
  , OrdinaryTeardownRecovery
  , OrdinaryTeardownRecoveryComponent (..)
  , OrdinaryTeardownRecoveryError
  , OrdinaryTeardownTargetAgent (..)
  , ordinaryTeardownRecovery
  , ordinaryTeardownRecoveryComponents
  , ordinaryTeardownRecoveryDag
  , ordinaryTeardownRequestedCapabilities
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupRunId
  , cleanupDigestText
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRecoveryCapabilityCatalogDigest
  , compiledDesiredAbsenceRunId
  , compiledDesiredAbsenceRunScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.Model qualified as TeardownModel
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness (..)
  , TeardownOperation (..)
  )
import Prodbox.Lifecycle.Teardown.RecoveryRequirement
  ( DerivedOrdinaryTeardownRecoveryRequirement
  , derivedOrdinaryTeardownTargetAgent
  , derivedRecoveryRequirementDiagnostic
  , recoveryRequirementDiagnosticCapabilityCatalogDigest
  , recoveryRequirementDiagnosticGraphDigest
  , recoveryRequirementDiagnosticIdentityDigest
  , recoveryRequirementDiagnosticRunId
  )

newtype RecoveryPlaneProfileDigest = RecoveryPlaneProfileDigest Text
  deriving stock (Eq, Ord, Show)

recoveryPlaneProfileDigestText :: RecoveryPlaneProfileDigest -> Text
recoveryPlaneProfileDigestText (RecoveryPlaneProfileDigest value) = value

data RecoveryPlaneComponentIdentity
  = RecoveryPlaneGraphComponent !ComponentId
  | RecoveryPlaneBootstrapCoreExternalCli
  deriving stock (Eq, Ord, Show)

recoveryPlaneComponentIdentityText :: RecoveryPlaneComponentIdentity -> Text
recoveryPlaneComponentIdentityText identity = case identity of
  RecoveryPlaneGraphComponent component ->
    "component/" <> Text.pack (componentIdText component)
  RecoveryPlaneBootstrapCoreExternalCli ->
    "bootstrap-core/external-cli"

data RecoveryPlaneComponentFailureKind
  = RecoveryPlaneComponentMissing
  | RecoveryPlaneComponentPartial
  | RecoveryPlaneComponentUnavailable
  | RecoveryPlaneComponentUnobservable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data RecoveryPlaneComponentFailure = RecoveryPlaneComponentFailure
  { internalRecoveryPlaneFailureIdentity :: !RecoveryPlaneComponentIdentity
  , internalRecoveryPlaneFailureKind :: !RecoveryPlaneComponentFailureKind
  }
  deriving stock (Eq, Ord, Show)

recoveryPlaneComponentFailureIdentity
  :: RecoveryPlaneComponentFailure -> RecoveryPlaneComponentIdentity
recoveryPlaneComponentFailureIdentity = internalRecoveryPlaneFailureIdentity

recoveryPlaneComponentFailureKind
  :: RecoveryPlaneComponentFailure -> RecoveryPlaneComponentFailureKind
recoveryPlaneComponentFailureKind = internalRecoveryPlaneFailureKind

data RecoveryPlaneProfile = RecoveryPlaneProfile
  { internalRecoveryPlaneProfileTargetAgent :: !OrdinaryTeardownTargetAgent
  , internalRecoveryPlaneProfileComponents :: ![RecoveryPlaneComponentIdentity]
  , internalRecoveryPlaneProfileDigest :: !RecoveryPlaneProfileDigest
  }
  deriving stock (Eq, Show)

data RecoveryPlaneIdentity (surface :: CleanupSurface) = RecoveryPlaneIdentityInternal
  { internalRecoveryPlaneIdentityWitness :: !(RecoverySurfaceWitness surface)
  , internalRecoveryPlaneIdentityRunId :: !CleanupRunId
  , internalRecoveryPlaneIdentityDescriptorDigest :: !CleanupDigest
  , internalRecoveryPlaneIdentityGraphDigest :: !CleanupDigest
  , internalRecoveryPlaneIdentityObservationScope :: !ObservationEvidenceScope
  , internalRecoveryPlaneIdentityCapabilityCatalogDigest :: !Text
  , internalRecoveryPlaneIdentityRequirementDigest :: !Text
  , internalRecoveryPlaneIdentityProfile :: !RecoveryPlaneProfile
  , internalRecoveryPlaneIdentityEstablishOperationId :: !CleanupOperationId
  , internalRecoveryPlaneIdentityReadBackOperationId :: !CleanupOperationId
  , internalRecoveryPlaneIdentityDispositionOperationId :: !CleanupOperationId
  }

instance Eq (RecoveryPlaneIdentity surface) where
  left == right =
    encodeRecoveryPlaneIdentityWireInternal left
      == encodeRecoveryPlaneIdentityWireInternal right

instance Show (RecoveryPlaneIdentity surface) where
  show identity =
    "<recovery-plane-identity:"
      <> Text.unpack (cleanupRunIdText (recoveryPlaneIdentityRunId identity))
      <> ">"

recoveryPlaneIdentitySurface :: RecoveryPlaneIdentity surface -> CleanupSurface
recoveryPlaneIdentitySurface =
  recoverySurfaceFromWitness . internalRecoveryPlaneIdentityWitness

recoveryPlaneIdentityRunId :: RecoveryPlaneIdentity surface -> CleanupRunId
recoveryPlaneIdentityRunId = internalRecoveryPlaneIdentityRunId

recoveryPlaneIdentityDescriptorDigest
  :: RecoveryPlaneIdentity surface -> CleanupDigest
recoveryPlaneIdentityDescriptorDigest =
  internalRecoveryPlaneIdentityDescriptorDigest

recoveryPlaneIdentityGraphDigest
  :: RecoveryPlaneIdentity surface -> CleanupDigest
recoveryPlaneIdentityGraphDigest = internalRecoveryPlaneIdentityGraphDigest

recoveryPlaneIdentityObservationScope
  :: RecoveryPlaneIdentity surface -> ObservationEvidenceScope
recoveryPlaneIdentityObservationScope =
  internalRecoveryPlaneIdentityObservationScope

recoveryPlaneIdentityCapabilityCatalogDigest
  :: RecoveryPlaneIdentity surface -> Text
recoveryPlaneIdentityCapabilityCatalogDigest =
  internalRecoveryPlaneIdentityCapabilityCatalogDigest

recoveryPlaneIdentityRequirementDigest
  :: RecoveryPlaneIdentity surface -> Text
recoveryPlaneIdentityRequirementDigest =
  internalRecoveryPlaneIdentityRequirementDigest

recoveryPlaneIdentityTargetAgent
  :: RecoveryPlaneIdentity surface -> OrdinaryTeardownTargetAgent
recoveryPlaneIdentityTargetAgent =
  internalRecoveryPlaneProfileTargetAgent
    . internalRecoveryPlaneIdentityProfile

recoveryPlaneIdentityProfileDigest
  :: RecoveryPlaneIdentity surface -> RecoveryPlaneProfileDigest
recoveryPlaneIdentityProfileDigest =
  internalRecoveryPlaneProfileDigest . internalRecoveryPlaneIdentityProfile

recoveryPlaneIdentityComponents
  :: RecoveryPlaneIdentity surface -> [RecoveryPlaneComponentIdentity]
recoveryPlaneIdentityComponents =
  internalRecoveryPlaneProfileComponents . internalRecoveryPlaneIdentityProfile

recoveryPlaneIdentityEstablishOperationId
  :: RecoveryPlaneIdentity surface -> CleanupOperationId
recoveryPlaneIdentityEstablishOperationId =
  internalRecoveryPlaneIdentityEstablishOperationId

recoveryPlaneIdentityReadBackOperationId
  :: RecoveryPlaneIdentity surface -> CleanupOperationId
recoveryPlaneIdentityReadBackOperationId =
  internalRecoveryPlaneIdentityReadBackOperationId

recoveryPlaneIdentityDispositionOperationId
  :: RecoveryPlaneIdentity surface -> CleanupOperationId
recoveryPlaneIdentityDispositionOperationId =
  internalRecoveryPlaneIdentityDispositionOperationId

data RecoveryPlaneNormalizedComponentState
  = RecoveryPlaneNormalizedReady
  | RecoveryPlaneNormalizedFailure !RecoveryPlaneComponentFailureKind
  deriving stock (Eq, Ord, Show)

data RecoveryPlaneNormalizedComponentFact = RecoveryPlaneNormalizedComponentFact
  { normalizedRecoveryPlaneComponentIdentity :: !RecoveryPlaneComponentIdentity
  , normalizedRecoveryPlaneComponentState :: !RecoveryPlaneNormalizedComponentState
  }
  deriving stock (Eq, Ord, Show)

data RecoveryPlaneNormalizedFacts = RecoveryPlaneNormalizedFacts
  { internalRecoveryPlaneNormalizedProfileDigest :: !RecoveryPlaneProfileDigest
  , recoveryPlaneNormalizedFactsEntries :: ![RecoveryPlaneNormalizedComponentFact]
  }
  deriving stock (Eq, Show)

data RecoveryPlaneReady (surface :: CleanupSurface)
  = RecoveryPlaneReadyInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupAttemptId
      !CleanupAttemptId
      !RecoveryPlaneNormalizedFacts

recoveryPlaneReadyIdentity
  :: RecoveryPlaneReady surface -> RecoveryPlaneIdentity surface
recoveryPlaneReadyIdentity (RecoveryPlaneReadyInternal identity _ _ _) = identity

recoveryPlaneReadyEstablishAttemptId
  :: RecoveryPlaneReady surface -> CleanupAttemptId
recoveryPlaneReadyEstablishAttemptId
  (RecoveryPlaneReadyInternal _ establishAttempt _ _) = establishAttempt

recoveryPlaneReadyReadBackAttemptId
  :: RecoveryPlaneReady surface -> CleanupAttemptId
recoveryPlaneReadyReadBackAttemptId
  (RecoveryPlaneReadyInternal _ _ readBackAttempt _) = readBackAttempt

data RecoveryPlaneInitialReadBack (surface :: CleanupSurface)
  = RecoveryPlaneInitialReadBackInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupAttemptId
      !CleanupAttemptId
      !RecoveryPlaneNormalizedFacts
      !(Maybe (RecoveryPlaneReady surface))
      !(Maybe (NonEmpty RecoveryPlaneComponentFailure))

recoveryPlaneInitialIdentity
  :: RecoveryPlaneInitialReadBack surface -> RecoveryPlaneIdentity surface
recoveryPlaneInitialIdentity
  (RecoveryPlaneInitialReadBackInternal identity _ _ _ _ _) = identity

recoveryPlaneInitialEstablishAttemptId
  :: RecoveryPlaneInitialReadBack surface -> CleanupAttemptId
recoveryPlaneInitialEstablishAttemptId
  (RecoveryPlaneInitialReadBackInternal _ establishAttempt _ _ _ _) =
    establishAttempt

recoveryPlaneInitialReadBackAttemptId
  :: RecoveryPlaneInitialReadBack surface -> CleanupAttemptId
recoveryPlaneInitialReadBackAttemptId
  (RecoveryPlaneInitialReadBackInternal _ _ readBackAttempt _ _ _) =
    readBackAttempt

recoveryPlaneInitialFailures
  :: RecoveryPlaneInitialReadBack surface
  -> Maybe (NonEmpty RecoveryPlaneComponentFailure)
recoveryPlaneInitialFailures
  (RecoveryPlaneInitialReadBackInternal _ _ _ _ _ failures) = failures

recoveryPlaneInitialFactsInternal
  :: RecoveryPlaneInitialReadBack surface -> RecoveryPlaneNormalizedFacts
recoveryPlaneInitialFactsInternal
  (RecoveryPlaneInitialReadBackInternal _ _ _ facts _ _) = facts

data RecoveryPlaneInitialDisposition
  = RecoveryPlaneInitiallyReady
  | RecoveryPlaneInitiallyNotReady
  deriving stock (Eq, Ord, Show)

recoveryPlaneInitialDisposition
  :: RecoveryPlaneInitialReadBack surface -> RecoveryPlaneInitialDisposition
recoveryPlaneInitialDisposition initial =
  case recoveryPlaneInitialReady initial of
    Just _ -> RecoveryPlaneInitiallyReady
    Nothing -> RecoveryPlaneInitiallyNotReady

recoveryPlaneInitialReady
  :: RecoveryPlaneInitialReadBack surface -> Maybe (RecoveryPlaneReady surface)
recoveryPlaneInitialReady
  (RecoveryPlaneInitialReadBackInternal _ _ _ _ ready _) = ready

data RecoveryPlaneFinalDisposition
  = RecoveryPlaneEstablished
  | RecoveryPlaneNotEstablished
  | RecoveryPlaneLost
  deriving stock (Eq, Ord, Show)

data RecoveryPlaneFinalEvidence (surface :: CleanupSurface)
  = RecoveryPlaneEstablishedInternal
      !(RecoveryPlaneReady surface)
      !CleanupAttemptId
      !RecoveryPlaneNormalizedFacts
  | RecoveryPlaneNotEstablishedInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupAttemptId
      !CleanupAttemptId
      !CleanupAttemptId
      !(NonEmpty RecoveryPlaneComponentFailure)
      !RecoveryPlaneNormalizedFacts
  | RecoveryPlaneLostInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupAttemptId
      !CleanupAttemptId
      !CleanupAttemptId
      !(NonEmpty RecoveryPlaneComponentFailure)
      !(RecoveryPlaneReady surface)
      !RecoveryPlaneNormalizedFacts

recoveryPlaneFinalIdentity
  :: RecoveryPlaneFinalEvidence surface -> RecoveryPlaneIdentity surface
recoveryPlaneFinalIdentity evidence = case evidence of
  RecoveryPlaneEstablishedInternal ready _ _ -> recoveryPlaneReadyIdentity ready
  RecoveryPlaneNotEstablishedInternal identity _ _ _ _ _ -> identity
  RecoveryPlaneLostInternal identity _ _ _ _ _ _ -> identity

recoveryPlaneFinalEstablishAttemptId
  :: RecoveryPlaneFinalEvidence surface -> CleanupAttemptId
recoveryPlaneFinalEstablishAttemptId evidence = case evidence of
  RecoveryPlaneEstablishedInternal ready _ _ ->
    recoveryPlaneReadyEstablishAttemptId ready
  RecoveryPlaneNotEstablishedInternal _ establishAttempt _ _ _ _ ->
    establishAttempt
  RecoveryPlaneLostInternal _ establishAttempt _ _ _ _ _ ->
    establishAttempt

recoveryPlaneFinalInitialReadBackAttemptId
  :: RecoveryPlaneFinalEvidence surface -> CleanupAttemptId
recoveryPlaneFinalInitialReadBackAttemptId evidence = case evidence of
  RecoveryPlaneEstablishedInternal ready _ _ ->
    recoveryPlaneReadyReadBackAttemptId ready
  RecoveryPlaneNotEstablishedInternal _ _ readBackAttempt _ _ _ ->
    readBackAttempt
  RecoveryPlaneLostInternal _ _ readBackAttempt _ _ _ _ ->
    readBackAttempt

recoveryPlaneFinalDispositionAttemptId
  :: RecoveryPlaneFinalEvidence surface -> CleanupAttemptId
recoveryPlaneFinalDispositionAttemptId evidence = case evidence of
  RecoveryPlaneEstablishedInternal _ dispositionAttempt _ ->
    dispositionAttempt
  RecoveryPlaneNotEstablishedInternal _ _ _ dispositionAttempt _ _ ->
    dispositionAttempt
  RecoveryPlaneLostInternal _ _ _ dispositionAttempt _ _ _ ->
    dispositionAttempt

recoveryPlaneFinalDisposition
  :: RecoveryPlaneFinalEvidence surface -> RecoveryPlaneFinalDisposition
recoveryPlaneFinalDisposition evidence = case evidence of
  RecoveryPlaneEstablishedInternal {} -> RecoveryPlaneEstablished
  RecoveryPlaneNotEstablishedInternal {} -> RecoveryPlaneNotEstablished
  RecoveryPlaneLostInternal {} -> RecoveryPlaneLost

recoveryPlaneFinalFailures
  :: RecoveryPlaneFinalEvidence surface
  -> Maybe (NonEmpty RecoveryPlaneComponentFailure)
recoveryPlaneFinalFailures evidence = case evidence of
  RecoveryPlaneEstablishedInternal {} -> Nothing
  RecoveryPlaneNotEstablishedInternal _ _ _ _ failures _ -> Just failures
  RecoveryPlaneLostInternal _ _ _ _ failures _ _ -> Just failures

-- | Only an established final observation exposes readiness.  The prior Ready
-- retained internally for a Lost transition cannot be recovered through this
-- or any other public eliminator.
recoveryPlaneFinalEstablishedReady
  :: RecoveryPlaneFinalEvidence surface -> Maybe (RecoveryPlaneReady surface)
recoveryPlaneFinalEstablishedReady evidence = case evidence of
  RecoveryPlaneEstablishedInternal ready _ _ -> Just ready
  RecoveryPlaneNotEstablishedInternal {} -> Nothing
  RecoveryPlaneLostInternal {} -> Nothing

data RecoveryPlaneEvidenceError
  = RecoveryPlaneProfileProjectionInvalid !OrdinaryTeardownRecoveryError
  | RecoveryPlaneProfileProjectionMismatch
  | RecoveryPlaneObservationIdentityMismatch
  | RecoveryPlaneObservationOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | RecoveryPlaneObservationAttemptMismatch !CleanupAttemptId !CleanupAttemptId
  | RecoveryPlaneObservationDuplicate
      !(NonEmpty RecoveryPlaneComponentIdentity)
  | RecoveryPlaneObservationMissing
      !(NonEmpty RecoveryPlaneComponentIdentity)
  | RecoveryPlaneObservationUnexpected
      !(NonEmpty RecoveryPlaneComponentIdentity)
  | RecoveryPlaneObservationProfileMismatch
      !RecoveryPlaneProfileDigest
      !RecoveryPlaneProfileDigest
  | RecoveryPlaneObservationHadNoDisposition
  | RecoveryPlaneBindingSurfaceMismatch !CleanupSurface !CleanupSurface
  | RecoveryPlaneBindingUnsupportedSurface !CleanupSurface
  | RecoveryPlaneBindingRunMismatch !CleanupRunId !CleanupRunId
  | RecoveryPlaneBindingDescriptorMismatch !CleanupDigest !CleanupDigest
  | RecoveryPlaneBindingGraphMismatch !CleanupDigest !CleanupDigest
  | RecoveryPlaneBindingObservationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | RecoveryPlaneBindingRunScopeMismatch
      !DurableObservationRunScope
      !DurableObservationRunScope
  | RecoveryPlaneBindingLifecycleOperationMismatch !LifecycleOperation
  | RecoveryPlaneBindingAwsScopeMissing
  | RecoveryPlaneBindingCatalogMismatch !Text !Text
  | RecoveryPlaneBindingOperationCardinality !Text !Int
  | RecoveryPlaneBindingOperationSurfaceMismatch
      !Text
      !CleanupSurface
      !CleanupSurface
  | RecoveryPlaneOperationAttemptNotBegun !CleanupOperationId
  | RecoveryPlaneOperationAttemptMismatch
      !CleanupOperationId
      !CleanupAttemptId
      !CleanupAttemptId
  | RecoveryPlaneStoredIdentityInvalid !Text
  deriving stock (Eq, Show)

data RecoveryPlaneRawComponentResult
  = RecoveryPlaneRawReady
  | RecoveryPlaneRawMissing !Text
  | RecoveryPlaneRawPartial !(NonEmpty Text)
  | RecoveryPlaneRawUnavailable !Text
  | RecoveryPlaneRawUnobservable !Text
  deriving stock (Eq, Show)

data RecoveryPlaneRawComponentObservation = RecoveryPlaneRawComponentObservation
  { rawRecoveryPlaneComponentIdentity :: !RecoveryPlaneComponentIdentity
  , rawRecoveryPlaneComponentResult :: !RecoveryPlaneRawComponentResult
  }
  deriving stock (Eq, Show)

data RecoveryPlaneComponentObservationSet (surface :: CleanupSurface)
  = RecoveryPlaneComponentObservationSetInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupOperationId
      !CleanupAttemptId
      ![RecoveryPlaneRawComponentObservation]

recoveryPlaneComponentObservationSetInternal
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> [RecoveryPlaneRawComponentObservation]
  -> RecoveryPlaneComponentObservationSet surface
recoveryPlaneComponentObservationSetInternal =
  RecoveryPlaneComponentObservationSetInternal

data RecoveryPlaneAttemptBinding (surface :: CleanupSurface)
  = RecoveryPlaneAttemptBindingInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupOperationId
      !CleanupAttemptId

-- | Internal fixture/repository reconstruction seam.  Production execution
-- binds attempts through the descriptor-bound context validators in the
-- Authority repository; direct callers are confined to fixed regressions and
-- canonical aggregate read-back.
recoveryPlaneAttemptBindingInternal
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneAttemptBinding surface
recoveryPlaneAttemptBindingInternal = RecoveryPlaneAttemptBindingInternal

-- | Bind an operation attempt only after the authoritative CleanupRun says
-- that exact node began.  A completed exact attempt is accepted for
-- response-loss replay; Pending and Blocked states never prove Begin.
recoveryPlaneAttemptBindingAfterBeginInternal
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupNodeState
  -> Either RecoveryPlaneEvidenceError (RecoveryPlaneAttemptBinding surface)
recoveryPlaneAttemptBindingAfterBeginInternal
  identity
  operationId
  expectedAttempt
  state =
    case state of
      CleanupNodeRunning actualAttempt -> exact actualAttempt
      CleanupNodeCompleted actualAttempt _ -> exact actualAttempt
      CleanupNodePending -> Left (RecoveryPlaneOperationAttemptNotBegun operationId)
      CleanupNodeBlocked _ -> Left (RecoveryPlaneOperationAttemptNotBegun operationId)
   where
    exact actualAttempt
      | actualAttempt == expectedAttempt =
          Right
            ( RecoveryPlaneAttemptBindingInternal
                identity
                operationId
                expectedAttempt
            )
      | otherwise =
          Left
            ( RecoveryPlaneOperationAttemptMismatch
                operationId
                expectedAttempt
                actualAttempt
            )

deriveRecoveryPlaneProfileInternal
  :: OrdinaryTeardownTargetAgent
  -> OrdinaryTeardownRecovery
  -> Either RecoveryPlaneEvidenceError RecoveryPlaneProfile
deriveRecoveryPlaneProfileInternal targetAgent recovery = do
  expected <-
    first
      RecoveryPlaneProfileProjectionInvalid
      (ordinaryTeardownRecovery targetAgent)
  unless
    (expected == recovery)
    (Left RecoveryPlaneProfileProjectionMismatch)
  let components = map recoveryComponentIdentity (ordinaryTeardownRecoveryComponents recovery)
      digest = RecoveryPlaneProfileDigest (profileDigest targetAgent recovery)
  pure
    RecoveryPlaneProfile
      { internalRecoveryPlaneProfileTargetAgent = targetAgent
      , internalRecoveryPlaneProfileComponents = components
      , internalRecoveryPlaneProfileDigest = digest
      }

-- | Pure half of the Authority binding.  Production supplies @compiled@ and
-- @requirement@ only after the opaque committed-descriptor / independently
-- observed CleanupRun join; no raw run or caller-selected profile enters this
-- function.
deriveRecoveryPlaneIdentityFromCompiledInternal
  :: CleanupDigest
  -> RecoverySurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> DerivedOrdinaryTeardownRecoveryRequirement
  -> Either RecoveryPlaneEvidenceError (RecoveryPlaneIdentity surface)
deriveRecoveryPlaneIdentityFromCompiledInternal
  descriptorDigest
  witness
  compiled
  requirement = do
    let expectedSurface = recoverySurfaceFromWitness witness
        scope = compiledDesiredAbsenceObservationScope compiled
        runId = compiledDesiredAbsenceRunId compiled
        graph = compiledDesiredAbsenceGraph compiled
        graphDigest = cleanupGraphDigest graph
        runScope = compiledDesiredAbsenceRunScope compiled
        catalogDigest =
          compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
        diagnostic = derivedRecoveryRequirementDiagnostic requirement
    unless
      (evidenceCleanupSurface scope == expectedSurface)
      ( Left
          ( RecoveryPlaneBindingSurfaceMismatch
              expectedSurface
              (evidenceCleanupSurface scope)
          )
      )
    unless
      (recoveryRequirementDiagnosticRunId diagnostic == runId)
      ( Left
          ( RecoveryPlaneBindingRunMismatch
              runId
              (recoveryRequirementDiagnosticRunId diagnostic)
          )
      )
    unless
      (recoveryRequirementDiagnosticGraphDigest diagnostic == graphDigest)
      ( Left
          ( RecoveryPlaneBindingGraphMismatch
              graphDigest
              (recoveryRequirementDiagnosticGraphDigest diagnostic)
          )
      )
    unless
      (evidenceDurableRunScope scope == runScope)
      ( Left
          ( RecoveryPlaneBindingRunScopeMismatch
              runScope
              (evidenceDurableRunScope scope)
          )
      )
    unless
      (durableRunScopeText scope == cleanupRunIdText runId)
      ( Left
          ( RecoveryPlaneBindingRunScopeMismatch
              (DurableObservationRunScope (cleanupRunIdText runId))
              (evidenceDurableRunScope scope)
          )
      )
    unless
      (evidenceLifecycleOperation scope == ReconcileDesiredAbsent)
      ( Left
          ( RecoveryPlaneBindingLifecycleOperationMismatch
              (evidenceLifecycleOperation scope)
          )
      )
    case evidenceAwsScope scope of
      Nothing -> Left RecoveryPlaneBindingAwsScopeMissing
      Just _ -> Right ()
    unless
      ( recoveryRequirementDiagnosticCapabilityCatalogDigest diagnostic
          == catalogDigest
      )
      ( Left
          ( RecoveryPlaneBindingCatalogMismatch
              catalogDigest
              ( recoveryRequirementDiagnosticCapabilityCatalogDigest
                  diagnostic
              )
          )
      )
    profile <- do
      recovery <-
        first
          RecoveryPlaneProfileProjectionInvalid
          ( ordinaryTeardownRecovery
              (derivedOrdinaryTeardownTargetAgent requirement)
          )
      deriveRecoveryPlaneProfileInternal
        (derivedOrdinaryTeardownTargetAgent requirement)
        recovery
    establish <- exactRecoveryOperationId witness compiled RecoveryPlaneEstablishRole
    readBack <- exactRecoveryOperationId witness compiled RecoveryPlaneReadBackRole
    disposition <-
      exactRecoveryOperationId witness compiled RecoveryPlaneDispositionRole
    pure
      RecoveryPlaneIdentityInternal
        { internalRecoveryPlaneIdentityWitness = witness
        , internalRecoveryPlaneIdentityRunId = runId
        , internalRecoveryPlaneIdentityDescriptorDigest = descriptorDigest
        , internalRecoveryPlaneIdentityGraphDigest = graphDigest
        , internalRecoveryPlaneIdentityObservationScope = scope
        , internalRecoveryPlaneIdentityCapabilityCatalogDigest = catalogDigest
        , internalRecoveryPlaneIdentityRequirementDigest =
            recoveryRequirementDiagnosticIdentityDigest diagnostic
        , internalRecoveryPlaneIdentityProfile = profile
        , internalRecoveryPlaneIdentityEstablishOperationId = establish
        , internalRecoveryPlaneIdentityReadBackOperationId = readBack
        , internalRecoveryPlaneIdentityDispositionOperationId = disposition
        }

-- | Restore the initial, durable identity only after an authenticated
-- Authority read-back has supplied its canonical bytes.  Static descriptor,
-- run, graph, scope, catalog, profile, and operation fields are recomputed
-- from the opaque descriptor-bound program.  The stored requirement digest
-- is deliberately retained: capability lifetime can progress after the
-- initial read-back, so re-deriving that dynamic requirement at disposition
-- time would make the original immutable aggregate unreachable.
restoreRecoveryPlaneIdentityFromCompiledInternal
  :: CleanupDigest
  -> RecoverySurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> ByteString
  -> Either RecoveryPlaneEvidenceError (RecoveryPlaneIdentity surface)
restoreRecoveryPlaneIdentityFromCompiledInternal
  descriptorDigest
  witness
  compiled
  bytes = do
    wire <-
      first
        RecoveryPlaneStoredIdentityInvalid
        (decodeRecoveryPlaneIdentityWireInternal bytes)
    let expectedSurface = recoverySurfaceFromWitness witness
        expectedRunId = compiledDesiredAbsenceRunId compiled
        expectedGraphDigest =
          cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
        expectedScope = compiledDesiredAbsenceObservationScope compiled
        expectedCatalog =
          compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
    storedSurface <-
      maybe
        (Left (RecoveryPlaneStoredIdentityInvalid "invalid cleanup surface"))
        Right
        (ordinarySurfaceFromTag (identityWireSurface wire))
    unless
      (storedSurface == expectedSurface)
      (Left (RecoveryPlaneBindingSurfaceMismatch expectedSurface storedSurface))
    storedRunId <- storedValue (mkCleanupRunId (identityWireRunId wire))
    unless
      (storedRunId == expectedRunId)
      (Left (RecoveryPlaneBindingRunMismatch expectedRunId storedRunId))
    storedDescriptorDigest <-
      storedValue (mkCleanupDigest (identityWireDescriptorDigest wire))
    unless
      (storedDescriptorDigest == descriptorDigest)
      ( Left
          ( RecoveryPlaneBindingDescriptorMismatch
              descriptorDigest
              storedDescriptorDigest
          )
      )
    storedGraphDigest <-
      storedValue (mkCleanupDigest (identityWireGraphDigest wire))
    unless
      (storedGraphDigest == expectedGraphDigest)
      ( Left
          ( RecoveryPlaneBindingGraphMismatch
              expectedGraphDigest
              storedGraphDigest
          )
      )
    storedScope <- scopeFromIdentityWire storedSurface wire
    unless
      (storedScope == expectedScope)
      ( Left
          ( RecoveryPlaneBindingObservationScopeMismatch
              expectedScope
              storedScope
          )
      )
    unless
      (identityWireCapabilityCatalogDigest wire == expectedCatalog)
      ( Left
          ( RecoveryPlaneBindingCatalogMismatch
              expectedCatalog
              (identityWireCapabilityCatalogDigest wire)
          )
      )
    targetAgent <-
      maybe
        (Left (RecoveryPlaneStoredIdentityInvalid "invalid Target Agent tag"))
        Right
        (targetAgentFromTag (identityWireTargetAgent wire))
    recovery <-
      first
        RecoveryPlaneProfileProjectionInvalid
        (ordinaryTeardownRecovery targetAgent)
    profile <- deriveRecoveryPlaneProfileInternal targetAgent recovery
    let expectedProfileDigest = internalRecoveryPlaneProfileDigest profile
        storedProfileDigest =
          RecoveryPlaneProfileDigest (identityWireProfileDigest wire)
    unless
      (storedProfileDigest == expectedProfileDigest)
      ( Left
          ( RecoveryPlaneObservationProfileMismatch
              expectedProfileDigest
              storedProfileDigest
          )
      )
    establish <- exactRecoveryOperationId witness compiled RecoveryPlaneEstablishRole
    readBack <- exactRecoveryOperationId witness compiled RecoveryPlaneReadBackRole
    disposition <-
      exactRecoveryOperationId witness compiled RecoveryPlaneDispositionRole
    storedEstablish <-
      storedValue (mkCleanupOperationId (identityWireEstablishOperationId wire))
    storedReadBack <-
      storedValue (mkCleanupOperationId (identityWireReadBackOperationId wire))
    storedDisposition <-
      storedValue (mkCleanupOperationId (identityWireDispositionOperationId wire))
    requireOperation establish storedEstablish
    requireOperation readBack storedReadBack
    requireOperation disposition storedDisposition
    pure
      RecoveryPlaneIdentityInternal
        { internalRecoveryPlaneIdentityWitness = witness
        , internalRecoveryPlaneIdentityRunId = expectedRunId
        , internalRecoveryPlaneIdentityDescriptorDigest = descriptorDigest
        , internalRecoveryPlaneIdentityGraphDigest = expectedGraphDigest
        , internalRecoveryPlaneIdentityObservationScope = expectedScope
        , internalRecoveryPlaneIdentityCapabilityCatalogDigest = expectedCatalog
        , internalRecoveryPlaneIdentityRequirementDigest =
            identityWireRequirementDigest wire
        , internalRecoveryPlaneIdentityProfile = profile
        , internalRecoveryPlaneIdentityEstablishOperationId = establish
        , internalRecoveryPlaneIdentityReadBackOperationId = readBack
        , internalRecoveryPlaneIdentityDispositionOperationId = disposition
        }
   where
    storedValue = first RecoveryPlaneStoredIdentityInvalid
    requireOperation expected actual =
      unless
        (expected == actual)
        (Left (RecoveryPlaneObservationOperationMismatch expected actual))

scopeFromIdentityWire
  :: CleanupSurface
  -> RecoveryPlaneIdentityWire
  -> Either RecoveryPlaneEvidenceError ObservationEvidenceScope
scopeFromIdentityWire surface wire = do
  awsScope <- case (identityWireAwsAccount wire, identityWireAwsRegion wire) of
    (Just account, Just region) ->
      Right (Just (AwsScope (AwsAccountId account) (AwsRegion region)))
    _ -> Left RecoveryPlaneBindingAwsScopeMissing
  operation <-
    maybe
      (Left (RecoveryPlaneStoredIdentityInvalid "invalid lifecycle operation"))
      Right
      (lifecycleOperationFromTag (identityWireLifecycleOperation wire))
  pure
    ( mkObservationEvidenceScope
        surface
        (RegistryRevision (identityWireRegistryRevision wire))
        (DurableObservationRunScope (identityWireRunScope wire))
        (LinuxRke2FoundationId (identityWireFoundation wire))
        awsScope
        operation
    )

data RecoveryPlaneOperationRole
  = RecoveryPlaneEstablishRole
  | RecoveryPlaneReadBackRole
  | RecoveryPlaneDispositionRole
  deriving stock (Eq, Show)

exactRecoveryOperationId
  :: RecoverySurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> RecoveryPlaneOperationRole
  -> Either RecoveryPlaneEvidenceError CleanupOperationId
exactRecoveryOperationId witness compiled expectedRole =
  case candidates of
    [(nodeId, observedSurface)] -> do
      unless
        (observedSurface == expectedSurface)
        ( Left
            ( RecoveryPlaneBindingOperationSurfaceMismatch
                roleText
                expectedSurface
                observedSurface
            )
        )
      plan <-
        maybe
          (Left (RecoveryPlaneBindingOperationCardinality roleText 0))
          Right
          (find ((== nodeId) . cleanupNodeId) graphNodes)
      pure (cleanupNodeOperationId plan)
    values ->
      Left
        ( RecoveryPlaneBindingOperationCardinality
            roleText
            (length values)
        )
 where
  expectedSurface = recoverySurfaceFromWitness witness
  graphNodes = cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
  candidates =
    [ (nodeId, recoverySurfaceFromWitness operationWitness)
    | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
    , Just (role, operationWitness) <- [recoveryOperationRole operation]
    , role == expectedRole
    ]
  roleText = recoveryOperationRoleText expectedRole

recoveryOperationRole
  :: TeardownOperation surface
  -> Maybe (RecoveryPlaneOperationRole, RecoverySurfaceWitness surface)
recoveryOperationRole operation = case operation of
  EstablishRecoveryPlane witness -> Just (RecoveryPlaneEstablishRole, witness)
  ReadBackRecoveryPlane witness -> Just (RecoveryPlaneReadBackRole, witness)
  ObserveRecoveryPlaneDisposition witness ->
    Just (RecoveryPlaneDispositionRole, witness)
  _ -> Nothing

recoveryOperationRoleText :: RecoveryPlaneOperationRole -> Text
recoveryOperationRoleText role = case role of
  RecoveryPlaneEstablishRole -> "establish"
  RecoveryPlaneReadBackRole -> "read-back"
  RecoveryPlaneDispositionRole -> "disposition"

normalizeRecoveryPlaneComponentFactsInternal
  :: RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneComponentObservationSet surface
  -> Either RecoveryPlaneEvidenceError RecoveryPlaneNormalizedFacts
normalizeRecoveryPlaneComponentFactsInternal
  (RecoveryPlaneAttemptBindingInternal expectedIdentity expectedOperation expectedAttempt)
  ( RecoveryPlaneComponentObservationSetInternal
      actualIdentity
      actualOperation
      actualAttempt
      observations
    ) = do
    unless
      (expectedIdentity == actualIdentity)
      (Left RecoveryPlaneObservationIdentityMismatch)
    unless
      (expectedOperation == actualOperation)
      ( Left
          ( RecoveryPlaneObservationOperationMismatch
              expectedOperation
              actualOperation
          )
      )
    unless
      (expectedAttempt == actualAttempt)
      (Left (RecoveryPlaneObservationAttemptMismatch expectedAttempt actualAttempt))
    case duplicateValues (map rawRecoveryPlaneComponentIdentity observations) of
      [] -> Right ()
      duplicate : rest ->
        Left (RecoveryPlaneObservationDuplicate (duplicate :| rest))
    let expectedComponents = recoveryPlaneIdentityComponents expectedIdentity
        expectedSet = Set.fromList expectedComponents
        actualSet = Set.fromList (map rawRecoveryPlaneComponentIdentity observations)
        missing = Set.toAscList (expectedSet `Set.difference` actualSet)
        unexpected = Set.toAscList (actualSet `Set.difference` expectedSet)
    case missing of
      [] -> Right ()
      firstMissing : rest ->
        Left (RecoveryPlaneObservationMissing (firstMissing :| rest))
    case unexpected of
      [] -> Right ()
      firstUnexpected : rest ->
        Left
          (RecoveryPlaneObservationUnexpected (firstUnexpected :| rest))
    let indexed =
          Map.fromList
            [ (rawRecoveryPlaneComponentIdentity observation, observation)
            | observation <- observations
            ]
        normalized =
          [ normalizeObservation observation
          | component <- expectedComponents
          , Just observation <- [Map.lookup component indexed]
          ]
    pure
      RecoveryPlaneNormalizedFacts
        { internalRecoveryPlaneNormalizedProfileDigest =
            recoveryPlaneIdentityProfileDigest expectedIdentity
        , recoveryPlaneNormalizedFactsEntries = normalized
        }

mkRecoveryPlaneInitialReadBackInternal
  :: RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneNormalizedFacts
  -> Either RecoveryPlaneEvidenceError (RecoveryPlaneInitialReadBack surface)
mkRecoveryPlaneInitialReadBackInternal
  ( RecoveryPlaneAttemptBindingInternal
      establishIdentity
      establishOperation
      establishAttempt
    )
  ( RecoveryPlaneAttemptBindingInternal
      readBackIdentity
      readBackOperation
      readBackAttempt
    )
  facts = do
    unless
      (establishIdentity == readBackIdentity)
      (Left RecoveryPlaneObservationIdentityMismatch)
    unless
      ( establishOperation
          == recoveryPlaneIdentityEstablishOperationId establishIdentity
      )
      ( Left
          ( RecoveryPlaneObservationOperationMismatch
              (recoveryPlaneIdentityEstablishOperationId establishIdentity)
              establishOperation
          )
      )
    unless
      ( readBackOperation
          == recoveryPlaneIdentityReadBackOperationId establishIdentity
      )
      ( Left
          ( RecoveryPlaneObservationOperationMismatch
              (recoveryPlaneIdentityReadBackOperationId establishIdentity)
              readBackOperation
          )
      )
    validateFactsProfile establishIdentity facts
    case normalizedFailures facts of
      Nothing ->
        let ready =
              RecoveryPlaneReadyInternal
                establishIdentity
                establishAttempt
                readBackAttempt
                facts
         in Right
              ( RecoveryPlaneInitialReadBackInternal
                  establishIdentity
                  establishAttempt
                  readBackAttempt
                  facts
                  (Just ready)
                  Nothing
              )
      Just failures ->
        Right
          ( RecoveryPlaneInitialReadBackInternal
              establishIdentity
              establishAttempt
              readBackAttempt
              facts
              Nothing
              (Just failures)
          )

mkRecoveryPlaneFinalEvidenceInternal
  :: RecoveryPlaneInitialReadBack surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneNormalizedFacts
  -> Either RecoveryPlaneEvidenceError (RecoveryPlaneFinalEvidence surface)
mkRecoveryPlaneFinalEvidenceInternal initial dispositionBinding freshFacts = do
  let identity = recoveryPlaneInitialIdentity initial
      establishAttempt = recoveryPlaneInitialEstablishAttemptId initial
      readBackAttempt = recoveryPlaneInitialReadBackAttemptId initial
      RecoveryPlaneAttemptBindingInternal
        dispositionIdentity
        dispositionOperation
        dispositionAttempt = dispositionBinding
  unless
    (identity == dispositionIdentity)
    (Left RecoveryPlaneObservationIdentityMismatch)
  unless
    (dispositionOperation == recoveryPlaneIdentityDispositionOperationId identity)
    ( Left
        ( RecoveryPlaneObservationOperationMismatch
            (recoveryPlaneIdentityDispositionOperationId identity)
            dispositionOperation
        )
    )
  validateFactsProfile identity freshFacts
  case normalizedFailures freshFacts of
    Nothing ->
      Right
        ( RecoveryPlaneEstablishedInternal
            ( RecoveryPlaneReadyInternal
                identity
                establishAttempt
                readBackAttempt
                freshFacts
            )
            dispositionAttempt
            freshFacts
        )
    Just failures -> case recoveryPlaneInitialReady initial of
      Nothing ->
        Right
          ( RecoveryPlaneNotEstablishedInternal
              identity
              establishAttempt
              readBackAttempt
              dispositionAttempt
              failures
              freshFacts
          )
      Just priorReady ->
        Right
          ( RecoveryPlaneLostInternal
              identity
              establishAttempt
              readBackAttempt
              dispositionAttempt
              failures
              priorReady
              freshFacts
          )

data RecoveryPlaneIdentityWire = RecoveryPlaneIdentityWire
  { identityWireFormatVersion :: !Int
  , identityWireSurface :: !Int
  , identityWireRunId :: !Text
  , identityWireDescriptorDigest :: !Text
  , identityWireGraphDigest :: !Text
  , identityWireRegistryRevision :: !Text
  , identityWireRunScope :: !Text
  , identityWireFoundation :: !Text
  , identityWireAwsAccount :: !(Maybe Text)
  , identityWireAwsRegion :: !(Maybe Text)
  , identityWireLifecycleOperation :: !Int
  , identityWireCapabilityCatalogDigest :: !Text
  , identityWireRequirementDigest :: !Text
  , identityWireTargetAgent :: !Int
  , identityWireProfileDigest :: !Text
  , identityWireEstablishOperationId :: !Text
  , identityWireReadBackOperationId :: !Text
  , identityWireDispositionOperationId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumRecoveryPlaneIdentityBytes :: Int
maximumRecoveryPlaneIdentityBytes = 16 * 1024

recoveryPlaneIdentityFormatVersion :: Int
recoveryPlaneIdentityFormatVersion = 1

encodeRecoveryPlaneIdentityWireInternal
  :: RecoveryPlaneIdentity surface -> ByteString
encodeRecoveryPlaneIdentityWireInternal =
  LazyByteString.toStrict . serialise . identityToWire

decodeRecoveryPlaneIdentityWireInternal
  :: ByteString -> Either Text RecoveryPlaneIdentityWire
decodeRecoveryPlaneIdentityWireInternal bytes = do
  when (ByteString.null bytes) (Left "recovery-plane identity is empty")
  when
    (ByteString.length bytes > maximumRecoveryPlaneIdentityBytes)
    (Left "recovery-plane identity exceeds its encoded bound")
  wire <-
    first
      (Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left "recovery-plane identity is non-canonical")
  validateIdentityWire wire
  pure wire

identityToWire :: RecoveryPlaneIdentity surface -> RecoveryPlaneIdentityWire
identityToWire identity =
  RecoveryPlaneIdentityWire
    { identityWireFormatVersion = recoveryPlaneIdentityFormatVersion
    , identityWireSurface = fromEnum (recoveryPlaneIdentitySurface identity)
    , identityWireRunId = cleanupRunIdText (recoveryPlaneIdentityRunId identity)
    , identityWireDescriptorDigest =
        cleanupDigestText (recoveryPlaneIdentityDescriptorDigest identity)
    , identityWireGraphDigest =
        cleanupDigestText (recoveryPlaneIdentityGraphDigest identity)
    , identityWireRegistryRevision = registryRevisionText scope
    , identityWireRunScope = durableRunScopeText scope
    , identityWireFoundation = foundationText scope
    , identityWireAwsAccount = awsAccountText <$> evidenceAwsScope scope
    , identityWireAwsRegion = awsRegionText <$> evidenceAwsScope scope
    , identityWireLifecycleOperation =
        lifecycleOperationTag (evidenceLifecycleOperation scope)
    , identityWireCapabilityCatalogDigest =
        recoveryPlaneIdentityCapabilityCatalogDigest identity
    , identityWireRequirementDigest =
        recoveryPlaneIdentityRequirementDigest identity
    , identityWireTargetAgent =
        targetAgentTag (recoveryPlaneIdentityTargetAgent identity)
    , identityWireProfileDigest =
        recoveryPlaneProfileDigestText
          (recoveryPlaneIdentityProfileDigest identity)
    , identityWireEstablishOperationId =
        cleanupOperationIdText
          (recoveryPlaneIdentityEstablishOperationId identity)
    , identityWireReadBackOperationId =
        cleanupOperationIdText
          (recoveryPlaneIdentityReadBackOperationId identity)
    , identityWireDispositionOperationId =
        cleanupOperationIdText
          (recoveryPlaneIdentityDispositionOperationId identity)
    }
 where
  scope = recoveryPlaneIdentityObservationScope identity

validateIdentityWire :: RecoveryPlaneIdentityWire -> Either Text ()
validateIdentityWire wire = do
  unless
    (identityWireFormatVersion wire == recoveryPlaneIdentityFormatVersion)
    (Left "recovery-plane identity version is unsupported")
  surface <-
    maybe
      (Left "recovery-plane identity surface is invalid")
      Right
      (ordinarySurfaceFromTag (identityWireSurface wire))
  runId <- mkCleanupRunId (identityWireRunId wire)
  _ <- mkCleanupDigest (identityWireDescriptorDigest wire)
  _ <- mkCleanupDigest (identityWireGraphDigest wire)
  validateBounded "registry revision" (identityWireRegistryRevision wire)
  validateBounded "run scope" (identityWireRunScope wire)
  validateBounded "foundation" (identityWireFoundation wire)
  unless
    (identityWireRunScope wire == identityWireRunId wire)
    (Left "recovery-plane identity run scope differs from run id")
  case (identityWireAwsAccount wire, identityWireAwsRegion wire) of
    (Just account, Just region) -> do
      validateBounded "AWS account" account
      validateBounded "AWS region" region
    _ -> Left "recovery-plane identity requires complete AWS scope"
  unless
    ( identityWireLifecycleOperation wire
        == lifecycleOperationTag ReconcileDesiredAbsent
    )
    (Left "recovery-plane identity lifecycle operation is invalid")
  mapM_
    validateDigest
    [ identityWireCapabilityCatalogDigest wire
    , identityWireRequirementDigest wire
    , identityWireProfileDigest wire
    ]
  _ <-
    maybe
      (Left "recovery-plane identity Target Agent tag is invalid")
      Right
      (targetAgentFromTag (identityWireTargetAgent wire))
  establish <- mkCleanupOperationId (identityWireEstablishOperationId wire)
  readBack <- mkCleanupOperationId (identityWireReadBackOperationId wire)
  disposition <- mkCleanupOperationId (identityWireDispositionOperationId wire)
  unless
    (length (Set.fromList [establish, readBack, disposition]) == 3)
    (Left "recovery-plane operation identities are not distinct")
  let _ = surface
      _ = runId
  pure ()

lifecycleOperationTag :: LifecycleOperation -> Int
lifecycleOperationTag operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

lifecycleOperationFromTag :: Int -> Maybe LifecycleOperation
lifecycleOperationFromTag tag = case tag of
  0 -> Just ReconcileDesiredAbsent
  1 -> Just ReconcileDesiredPresent
  2 -> Just RunTerminalEscapeAudit
  _ -> Nothing

data RecoveryPlaneFixtureRegression = RecoveryPlaneFixtureRegression
  { recoveryPlaneFixtureProfileCanonical :: !Bool
  , recoveryPlaneFixtureProfileTargetAgentSeparated :: !Bool
  , recoveryPlaneFixtureIdentityCanonical :: !Bool
  , recoveryPlaneFixtureExactCompletenessEnforced :: !Bool
  , recoveryPlaneFixtureEveryFailureRefused :: !Bool
  , recoveryPlaneFixtureDiagnosticsNormalized :: !Bool
  , recoveryPlaneFixtureInitialReadyExact :: !Bool
  , recoveryPlaneFixtureEstablishedFromReady :: !Bool
  , recoveryPlaneFixtureEstablishedAfterInitialFailure :: !Bool
  , recoveryPlaneFixtureNotEstablishedExact :: !Bool
  , recoveryPlaneFixtureLostExact :: !Bool
  , recoveryPlaneFixtureLostHidesReady :: !Bool
  , recoveryPlaneFixtureCrossBindingRefused :: !Bool
  , recoveryPlaneFixtureDynamicProfileRestored :: !Bool
  }
  deriving stock (Eq, Show)

fixedRecoveryPlaneFixtureRegression
  :: Either Text RecoveryPlaneFixtureRegression
fixedRecoveryPlaneFixtureRegression = do
  withoutRecovery <- firstShow (ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent)
  withRecovery <- firstShow (ordinaryTeardownRecovery OrdinaryTeardownWithTargetAgent)
  withoutProfile <-
    firstShow
      ( deriveRecoveryPlaneProfileInternal
          OrdinaryTeardownWithoutTargetAgent
          withoutRecovery
      )
  withProfile <-
    firstShow
      ( deriveRecoveryPlaneProfileInternal
          OrdinaryTeardownWithTargetAgent
          withRecovery
      )
  identity <- fixedIdentity withoutProfile fixtureRunId fixtureGraphDigest fixtureScope
  otherIdentity <-
    fixedIdentity
      withoutProfile
      fixtureOtherRunId
      fixtureOtherGraphDigest
      fixtureOtherScope
  dynamicProfileRestored <-
    dynamicProfileRestoreRegression withProfile withoutProfile
  establishAttempt <- firstShow (mkCleanupAttemptId "recovery-establish-attempt")
  readBackAttempt <- firstShow (mkCleanupAttemptId "recovery-read-back-attempt")
  dispositionAttempt <- firstShow (mkCleanupAttemptId "recovery-disposition-attempt")
  otherAttempt <- firstShow (mkCleanupAttemptId "recovery-other-attempt")
  let establishBinding =
        recoveryPlaneAttemptBindingInternal
          identity
          (recoveryPlaneIdentityEstablishOperationId identity)
          establishAttempt
      readBackBinding =
        recoveryPlaneAttemptBindingInternal
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
      dispositionBinding =
        recoveryPlaneAttemptBindingInternal
          identity
          (recoveryPlaneIdentityDispositionOperationId identity)
          dispositionAttempt
      readySet =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          RecoveryPlaneRawReady
      missingSet detail =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (RecoveryPlaneRawMissing detail)
      partialSet =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (RecoveryPlaneRawPartial ("partial-a" :| ["partial-b"]))
      unavailableSet =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (RecoveryPlaneRawUnavailable "endpoint unavailable")
      unobservableSet =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (RecoveryPlaneRawUnobservable "transport ambiguous")
  readyFacts <-
    firstShow
      (normalizeRecoveryPlaneComponentFactsInternal readBackBinding readySet)
  missingFacts <-
    firstShow
      ( normalizeRecoveryPlaneComponentFactsInternal
          readBackBinding
          (missingSet "first diagnostic")
      )
  missingFactsAlternate <-
    firstShow
      ( normalizeRecoveryPlaneComponentFactsInternal
          readBackBinding
          (missingSet "different diagnostic")
      )
  readyInitial <-
    firstShow
      ( mkRecoveryPlaneInitialReadBackInternal
          establishBinding
          readBackBinding
          readyFacts
      )
  failedInitial <-
    firstShow
      ( mkRecoveryPlaneInitialReadBackInternal
          establishBinding
          readBackBinding
          missingFacts
      )
  establishedFromReady <-
    firstShow
      ( mkRecoveryPlaneFinalEvidenceInternal
          readyInitial
          dispositionBinding
          readyFacts
      )
  establishedAfterFailure <-
    firstShow
      ( mkRecoveryPlaneFinalEvidenceInternal
          failedInitial
          dispositionBinding
          readyFacts
      )
  notEstablished <-
    firstShow
      ( mkRecoveryPlaneFinalEvidenceInternal
          failedInitial
          dispositionBinding
          missingFacts
      )
  lost <-
    firstShow
      ( mkRecoveryPlaneFinalEvidenceInternal
          readyInitial
          dispositionBinding
          missingFacts
      )
  let duplicateObservation = case recoveryPlaneIdentityComponents identity of
        component : _ ->
          RecoveryPlaneComponentObservationSetInternal
            identity
            (recoveryPlaneIdentityReadBackOperationId identity)
            readBackAttempt
            [ RecoveryPlaneRawComponentObservation component RecoveryPlaneRawReady
            , RecoveryPlaneRawComponentObservation component RecoveryPlaneRawReady
            ]
        [] -> readySet
      incompleteObservation =
        RecoveryPlaneComponentObservationSetInternal
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (drop 1 (rawObservationRows readySet))
      unexpectedObservation =
        RecoveryPlaneComponentObservationSetInternal
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          ( RecoveryPlaneRawComponentObservation
              (RecoveryPlaneGraphComponent maxBound)
              RecoveryPlaneRawReady
              : rawObservationRows readySet
          )
      allFailureSets = [missingSet "missing", partialSet, unavailableSet, unobservableSet]
      everyFailureRefused =
        all
          ( \set -> case normalizeRecoveryPlaneComponentFactsInternal readBackBinding set of
              Left _ -> False
              Right facts -> case mkRecoveryPlaneInitialReadBackInternal
                establishBinding
                readBackBinding
                facts of
                Right initial -> maybe True (const False) (recoveryPlaneInitialReady initial)
                Left _ -> False
          )
          allFailureSets
      crossIdentitySet =
        observationSet
          otherIdentity
          (recoveryPlaneIdentityReadBackOperationId otherIdentity)
          readBackAttempt
          RecoveryPlaneRawReady
      wrongAttemptSet =
        observationSet
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          otherAttempt
          RecoveryPlaneRawReady
      profileCanonical =
        profileDigest OrdinaryTeardownWithoutTargetAgent withoutRecovery
          == profileDigest OrdinaryTeardownWithoutTargetAgent withoutRecovery
      targetSeparated =
        internalRecoveryPlaneProfileDigest withoutProfile
          /= internalRecoveryPlaneProfileDigest withProfile
      encodedIdentity = encodeRecoveryPlaneIdentityWireInternal identity
      identityCanonical =
        ByteString.length encodedIdentity <= maximumRecoveryPlaneIdentityBytes
          && decodeRecoveryPlaneIdentityWireInternal encodedIdentity
            == Right (identityToWire identity)
          && either
            (const True)
            (const False)
            (decodeRecoveryPlaneIdentityWireInternal (encodedIdentity <> "trailing"))
      completeness =
        isDuplicate
          (normalizeRecoveryPlaneComponentFactsInternal readBackBinding duplicateObservation)
          && isMissing
            (normalizeRecoveryPlaneComponentFactsInternal readBackBinding incompleteObservation)
          && isUnexpected
            ( normalizeRecoveryPlaneComponentFactsInternal
                readBackBinding
                unexpectedObservation
            )
      initialReadyExact = case recoveryPlaneInitialReady readyInitial of
        Just ready ->
          recoveryPlaneReadyIdentity ready == identity
            && recoveryPlaneReadyEstablishAttemptId ready == establishAttempt
            && recoveryPlaneReadyReadBackAttemptId ready == readBackAttempt
        Nothing -> False
      establishedFromReadyExact =
        recoveryPlaneFinalDisposition establishedFromReady == RecoveryPlaneEstablished
          && hasEstablishedReady establishedFromReady
          && exactFinalAttempts
            establishAttempt
            readBackAttempt
            dispositionAttempt
            establishedFromReady
      establishedAfterFailureExact =
        recoveryPlaneFinalDisposition establishedAfterFailure == RecoveryPlaneEstablished
          && hasEstablishedReady establishedAfterFailure
          && exactFinalAttempts
            establishAttempt
            readBackAttempt
            dispositionAttempt
            establishedAfterFailure
      notEstablishedExact =
        recoveryPlaneFinalDisposition notEstablished == RecoveryPlaneNotEstablished
          && recoveryPlaneFinalFailures notEstablished /= Nothing
          && exactFinalAttempts
            establishAttempt
            readBackAttempt
            dispositionAttempt
            notEstablished
      lostExact =
        recoveryPlaneFinalDisposition lost == RecoveryPlaneLost
          && recoveryPlaneFinalFailures lost /= Nothing
          && exactFinalAttempts
            establishAttempt
            readBackAttempt
            dispositionAttempt
            lost
      lostHidesReady =
        maybe True (const False) (recoveryPlaneFinalEstablishedReady lost)
      crossBindingRefused =
        isIdentityMismatch
          ( normalizeRecoveryPlaneComponentFactsInternal
              readBackBinding
              crossIdentitySet
          )
          && isAttemptMismatch
            ( normalizeRecoveryPlaneComponentFactsInternal
                readBackBinding
                wrongAttemptSet
            )
  pure
    RecoveryPlaneFixtureRegression
      { recoveryPlaneFixtureProfileCanonical = profileCanonical
      , recoveryPlaneFixtureProfileTargetAgentSeparated = targetSeparated
      , recoveryPlaneFixtureIdentityCanonical = identityCanonical
      , recoveryPlaneFixtureExactCompletenessEnforced = completeness
      , recoveryPlaneFixtureEveryFailureRefused = everyFailureRefused
      , recoveryPlaneFixtureDiagnosticsNormalized =
          missingFacts == missingFactsAlternate
      , recoveryPlaneFixtureInitialReadyExact = initialReadyExact
      , recoveryPlaneFixtureEstablishedFromReady = establishedFromReadyExact
      , recoveryPlaneFixtureEstablishedAfterInitialFailure =
          establishedAfterFailureExact
      , recoveryPlaneFixtureNotEstablishedExact = notEstablishedExact
      , recoveryPlaneFixtureLostExact = lostExact
      , recoveryPlaneFixtureLostHidesReady = lostHidesReady
      , recoveryPlaneFixtureCrossBindingRefused = crossBindingRefused
      , recoveryPlaneFixtureDynamicProfileRestored = dynamicProfileRestored
      }

dynamicProfileRestoreRegression
  :: RecoveryPlaneProfile
  -> RecoveryPlaneProfile
  -> Either Text Bool
dynamicProfileRestoreRegression withProfile withoutProfile = do
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          fixtureRunId
          fixtureFoundation
          (Just fixtureAwsScope)
          TeardownModel.CascadeSurface
      )
  withIdentity <-
    compiledFixtureIdentity
      withProfile
      (Text.replicate 64 "6")
      compiled
  withoutIdentity <-
    compiledFixtureIdentity
      withoutProfile
      (Text.replicate 64 "7")
      compiled
  restored <-
    firstShow
      ( restoreRecoveryPlaneIdentityFromCompiledInternal
          fixtureDescriptorDigest
          CascadeRecoverySurface
          compiled
          (encodeRecoveryPlaneIdentityWireInternal withIdentity)
      )
  pure (restored == withIdentity && restored /= withoutIdentity)

compiledFixtureIdentity
  :: RecoveryPlaneProfile
  -> Text
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> Either Text (RecoveryPlaneIdentity 'Cascade)
compiledFixtureIdentity profile requirementDigest compiled = do
  establish <-
    firstShow
      ( exactRecoveryOperationId
          CascadeRecoverySurface
          compiled
          RecoveryPlaneEstablishRole
      )
  readBack <-
    firstShow
      ( exactRecoveryOperationId
          CascadeRecoverySurface
          compiled
          RecoveryPlaneReadBackRole
      )
  disposition <-
    firstShow
      ( exactRecoveryOperationId
          CascadeRecoverySurface
          compiled
          RecoveryPlaneDispositionRole
      )
  pure
    RecoveryPlaneIdentityInternal
      { internalRecoveryPlaneIdentityWitness = CascadeRecoverySurface
      , internalRecoveryPlaneIdentityRunId = compiledDesiredAbsenceRunId compiled
      , internalRecoveryPlaneIdentityDescriptorDigest = fixtureDescriptorDigest
      , internalRecoveryPlaneIdentityGraphDigest =
          cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
      , internalRecoveryPlaneIdentityObservationScope =
          compiledDesiredAbsenceObservationScope compiled
      , internalRecoveryPlaneIdentityCapabilityCatalogDigest =
          compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
      , internalRecoveryPlaneIdentityRequirementDigest = requirementDigest
      , internalRecoveryPlaneIdentityProfile = profile
      , internalRecoveryPlaneIdentityEstablishOperationId = establish
      , internalRecoveryPlaneIdentityReadBackOperationId = readBack
      , internalRecoveryPlaneIdentityDispositionOperationId = disposition
      }

profileDigest :: OrdinaryTeardownTargetAgent -> OrdinaryTeardownRecovery -> Text
profileDigest targetAgent recovery =
  sha256Canonical
    ( [ recoveryPlaneProfileFormatVersion
      , targetAgentText targetAgent
      ]
        <> map capabilityText (ordinaryTeardownRequestedCapabilities recovery)
        <> map
          (recoveryPlaneComponentIdentityText . recoveryComponentIdentity)
          (ordinaryTeardownRecoveryComponents recovery)
        <> concatMap canonicalNode orderedNodes
    )
 where
  dag = ordinaryTeardownRecoveryDag recovery
  nodes = componentDagNodes dag
  orderedNodes =
    [ node
    | component <- componentDagOrder dag
    , Just node <- [Map.lookup component nodes]
    ]
  canonicalNode node =
    [ "node"
    , Text.pack (componentIdText (component_id node))
    , readinessText (readiness node)
    ]
      <> concatMap canonicalDependency (sortOn dependency_on (depends_on node))
  canonicalDependency dependency =
    [ "dependency"
    , Text.pack (componentIdText (dependency_on dependency))
    , edgeKindText (dependency_edge dependency)
    ]

recoveryPlaneProfileFormatVersion :: Text
recoveryPlaneProfileFormatVersion = "ordinary-teardown-recovery-profile/v1"

recoveryComponentIdentity
  :: OrdinaryTeardownRecoveryComponent -> RecoveryPlaneComponentIdentity
recoveryComponentIdentity component = case component of
  RecoveryGraphComponent graphComponent ->
    RecoveryPlaneGraphComponent graphComponent
  RecoveryBootstrapCoreExternalCli -> RecoveryPlaneBootstrapCoreExternalCli

normalizeObservation
  :: RecoveryPlaneRawComponentObservation
  -> RecoveryPlaneNormalizedComponentFact
normalizeObservation observation =
  RecoveryPlaneNormalizedComponentFact
    (rawRecoveryPlaneComponentIdentity observation)
    ( case rawRecoveryPlaneComponentResult observation of
        RecoveryPlaneRawReady -> RecoveryPlaneNormalizedReady
        RecoveryPlaneRawMissing _ ->
          RecoveryPlaneNormalizedFailure RecoveryPlaneComponentMissing
        RecoveryPlaneRawPartial _ ->
          RecoveryPlaneNormalizedFailure RecoveryPlaneComponentPartial
        RecoveryPlaneRawUnavailable _ ->
          RecoveryPlaneNormalizedFailure RecoveryPlaneComponentUnavailable
        RecoveryPlaneRawUnobservable _ ->
          RecoveryPlaneNormalizedFailure RecoveryPlaneComponentUnobservable
    )

normalizedFailures
  :: RecoveryPlaneNormalizedFacts
  -> Maybe (NonEmpty RecoveryPlaneComponentFailure)
normalizedFailures facts =
  NonEmpty.nonEmpty
    [ RecoveryPlaneComponentFailure identity kind
    | RecoveryPlaneNormalizedComponentFact identity state <-
        recoveryPlaneNormalizedFactsEntries facts
    , kind <- case state of
        RecoveryPlaneNormalizedReady -> []
        RecoveryPlaneNormalizedFailure failureKind -> [failureKind]
    ]

validateFactsProfile
  :: RecoveryPlaneIdentity surface
  -> RecoveryPlaneNormalizedFacts
  -> Either RecoveryPlaneEvidenceError ()
validateFactsProfile identity facts =
  let expected = recoveryPlaneIdentityProfileDigest identity
      actual = internalRecoveryPlaneNormalizedProfileDigest facts
   in unless
        (expected == actual)
        (Left (RecoveryPlaneObservationProfileMismatch expected actual))

rawObservationRows
  :: RecoveryPlaneComponentObservationSet surface
  -> [RecoveryPlaneRawComponentObservation]
rawObservationRows
  (RecoveryPlaneComponentObservationSetInternal _ _ _ observations) = observations

observationSet
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneRawComponentResult
  -> RecoveryPlaneComponentObservationSet surface
observationSet identity operationId attempt firstResult =
  RecoveryPlaneComponentObservationSetInternal
    identity
    operationId
    attempt
    [ RecoveryPlaneRawComponentObservation
        component
        (if index == (0 :: Int) then firstResult else RecoveryPlaneRawReady)
    | (index, component) <- zip [0 ..] (recoveryPlaneIdentityComponents identity)
    ]

fixedIdentity
  :: RecoveryPlaneProfile
  -> CleanupRunId
  -> CleanupDigest
  -> ObservationEvidenceScope
  -> Either Text (RecoveryPlaneIdentity 'Cascade)
fixedIdentity profile runId graphDigest scope = do
  establish <- mkCleanupOperationId ("recovery-establish/" <> cleanupRunIdText runId)
  readBack <- mkCleanupOperationId ("recovery-read-back/" <> cleanupRunIdText runId)
  disposition <-
    mkCleanupOperationId ("recovery-disposition/" <> cleanupRunIdText runId)
  pure
    RecoveryPlaneIdentityInternal
      { internalRecoveryPlaneIdentityWitness = CascadeRecoverySurface
      , internalRecoveryPlaneIdentityRunId = runId
      , internalRecoveryPlaneIdentityDescriptorDigest = fixtureDescriptorDigest
      , internalRecoveryPlaneIdentityGraphDigest = graphDigest
      , internalRecoveryPlaneIdentityObservationScope = scope
      , internalRecoveryPlaneIdentityCapabilityCatalogDigest = fixtureCatalogDigest
      , internalRecoveryPlaneIdentityRequirementDigest = fixtureRequirementDigest
      , internalRecoveryPlaneIdentityProfile = profile
      , internalRecoveryPlaneIdentityEstablishOperationId = establish
      , internalRecoveryPlaneIdentityReadBackOperationId = readBack
      , internalRecoveryPlaneIdentityDispositionOperationId = disposition
      }

fixtureRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "recovery-plane-run")

fixedRecoveryPlaneIdentityInternal :: RecoveryPlaneIdentity 'Cascade
fixedRecoveryPlaneIdentityInternal =
  mustRight $ do
    recovery <- firstShow (ordinaryTeardownRecovery OrdinaryTeardownWithoutTargetAgent)
    profile <-
      firstShow
        ( deriveRecoveryPlaneProfileInternal
            OrdinaryTeardownWithoutTargetAgent
            recovery
        )
    fixedIdentity profile fixtureRunId fixtureGraphDigest fixtureScope

fixedRecoveryPlaneTargetIdentityInternal :: RecoveryPlaneIdentity 'Cascade
fixedRecoveryPlaneTargetIdentityInternal =
  mustRight $ do
    recovery <- firstShow (ordinaryTeardownRecovery OrdinaryTeardownWithTargetAgent)
    profile <-
      firstShow
        ( deriveRecoveryPlaneProfileInternal
            OrdinaryTeardownWithTargetAgent
            recovery
        )
    fixedIdentity profile fixtureRunId fixtureGraphDigest fixtureScope

fixedRecoveryPlaneEstablishAttemptIdInternal :: CleanupAttemptId
fixedRecoveryPlaneEstablishAttemptIdInternal =
  mustRight (mkCleanupAttemptId "recovery-establish-attempt")

fixedRecoveryPlaneReadBackAttemptIdInternal :: CleanupAttemptId
fixedRecoveryPlaneReadBackAttemptIdInternal =
  mustRight (mkCleanupAttemptId "recovery-read-back-attempt")

fixedRecoveryPlaneDispositionAttemptIdInternal :: CleanupAttemptId
fixedRecoveryPlaneDispositionAttemptIdInternal =
  mustRight (mkCleanupAttemptId "recovery-disposition-attempt")

fixtureOtherRunId :: CleanupRunId
fixtureOtherRunId = mustRight (mkCleanupRunId "recovery-plane-other-run")

fixtureGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "1"))

fixtureDescriptorDigest :: CleanupDigest
fixtureDescriptorDigest = mustRight (mkCleanupDigest (Text.replicate 64 "5"))

fixtureOtherGraphDigest :: CleanupDigest
fixtureOtherGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "2"))

fixtureCatalogDigest :: Text
fixtureCatalogDigest = Text.replicate 64 "3"

fixtureRequirementDigest :: Text
fixtureRequirementDigest = Text.replicate 64 "4"

fixtureFoundation :: LinuxRke2FoundationId
fixtureFoundation = LinuxRke2FoundationId "foundation/home"

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1")

fixtureScope :: ObservationEvidenceScope
fixtureScope = scopeFor fixtureRunId "foundation/home"

fixtureOtherScope :: ObservationEvidenceScope
fixtureOtherScope = scopeFor fixtureOtherRunId "foundation/other"

scopeFor :: CleanupRunId -> Text -> ObservationEvidenceScope
scopeFor runId foundation =
  mkObservationEvidenceScope
    Cascade
    (RegistryRevision "registry/v1")
    (DurableObservationRunScope (cleanupRunIdText runId))
    (LinuxRke2FoundationId foundation)
    (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1")))
    ReconcileDesiredAbsent

registryRevisionText :: ObservationEvidenceScope -> Text
registryRevisionText scope = case evidenceRegistryRevision scope of
  RegistryRevision value -> value

durableRunScopeText :: ObservationEvidenceScope -> Text
durableRunScopeText scope = case evidenceDurableRunScope scope of
  DurableObservationRunScope value -> value

foundationText :: ObservationEvidenceScope -> Text
foundationText scope = case evidenceLinuxRke2Foundation scope of
  LinuxRke2FoundationId value -> value

awsAccountText :: AwsScope -> Text
awsAccountText scope = case awsScopeAccountId scope of
  AwsAccountId value -> value

awsRegionText :: AwsScope -> Text
awsRegionText scope = case awsScopeRegion scope of
  AwsRegion value -> value

recoverySurfaceFromWitness :: RecoverySurfaceWitness surface -> CleanupSurface
recoverySurfaceFromWitness witness = case witness of
  CascadeRecoverySurface -> Cascade
  ExplicitPerRunRecoverySurface -> ExplicitPerRun
  OperationalRecoverySurface -> OperationalTeardown
  ExplicitLongLivedRecoverySurface -> ExplicitLongLived

ordinarySurfaceFromTag :: Int -> Maybe CleanupSurface
ordinarySurfaceFromTag tag = case tag of
  1 -> Just Cascade
  2 -> Just ExplicitPerRun
  3 -> Just OperationalTeardown
  4 -> Just ExplicitLongLived
  _ -> Nothing

targetAgentTag :: OrdinaryTeardownTargetAgent -> Int
targetAgentTag targetAgent = case targetAgent of
  OrdinaryTeardownWithoutTargetAgent -> 0
  OrdinaryTeardownWithTargetAgent -> 1

targetAgentFromTag :: Int -> Maybe OrdinaryTeardownTargetAgent
targetAgentFromTag tag = case tag of
  0 -> Just OrdinaryTeardownWithoutTargetAgent
  1 -> Just OrdinaryTeardownWithTargetAgent
  _ -> Nothing

targetAgentText :: OrdinaryTeardownTargetAgent -> Text
targetAgentText targetAgent = case targetAgent of
  OrdinaryTeardownWithoutTargetAgent -> "without-target-agent"
  OrdinaryTeardownWithTargetAgent -> "with-target-agent"

capabilityText :: OrdinaryTeardownCapability -> Text
capabilityText capability = case capability of
  ResumeOrdinaryCleanup -> "resume-ordinary-cleanup"
  ResolveExactTargetCleanup -> "resolve-exact-target-cleanup"

readinessText :: ReadinessProbe -> Text
readinessText probe = case probe of
  ProbeResourceExists -> "resource-exists"
  ProbeFrontDoorHttp -> "front-door-http"
  ProbeServiceActive -> "service-active"
  ProbeRolloutComplete -> "rollout-complete"
  ProbeOperatorAvailable -> "operator-available"
  ProbeVaultUnsealed -> "vault-unsealed"
  ProbeBackendRoundTrip component ->
    "backend-round-trip/" <> Text.pack (componentIdText component)

edgeKindText :: EdgeKind -> Text
edgeKindText kind = case kind of
  OrderingEdge -> "ordering"
  BackendWriteEdge -> "backend-write"

validateDigest :: Text -> Either Text ()
validateDigest raw = void (mkCleanupDigest raw)

validateBounded :: Text -> Text -> Either Text ()
validateBounded label value
  | Text.null value = Left (label <> " is empty")
  | Text.length value > 256 = Left (label <> " exceeds its bound")
  | Text.any invalid value = Left (label <> " contains an invalid character")
  | otherwise = Right ()
 where
  invalid character = isControl character || isSpace character

sha256Canonical :: [Text] -> Text
sha256Canonical fields =
  TextEncoding.decodeUtf8
    (hexSha256 (TextEncoding.encodeUtf8 (Text.concat (map frame fields))))
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ value
  | grouped@(value : _) <- group (sort values)
  , length grouped > 1
  ]

hasEstablishedReady :: RecoveryPlaneFinalEvidence surface -> Bool
hasEstablishedReady = maybe False (const True) . recoveryPlaneFinalEstablishedReady

exactFinalAttempts
  :: CleanupAttemptId
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneFinalEvidence surface
  -> Bool
exactFinalAttempts establishAttempt readBackAttempt dispositionAttempt evidence =
  recoveryPlaneFinalEstablishAttemptId evidence == establishAttempt
    && recoveryPlaneFinalInitialReadBackAttemptId evidence == readBackAttempt
    && recoveryPlaneFinalDispositionAttemptId evidence == dispositionAttempt

isDuplicate :: Either RecoveryPlaneEvidenceError value -> Bool
isDuplicate result = case result of
  Left RecoveryPlaneObservationDuplicate {} -> True
  _ -> False

isMissing :: Either RecoveryPlaneEvidenceError value -> Bool
isMissing result = case result of
  Left RecoveryPlaneObservationMissing {} -> True
  _ -> False

isUnexpected :: Either RecoveryPlaneEvidenceError value -> Bool
isUnexpected result = case result of
  Left RecoveryPlaneObservationUnexpected {} -> True
  _ -> False

isIdentityMismatch :: Either RecoveryPlaneEvidenceError value -> Bool
isIdentityMismatch result = case result of
  Left RecoveryPlaneObservationIdentityMismatch -> True
  _ -> False

isAttemptMismatch :: Either RecoveryPlaneEvidenceError value -> Bool
isAttemptMismatch result = case result of
  Left RecoveryPlaneObservationAttemptMismatch {} -> True
  _ -> False

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
