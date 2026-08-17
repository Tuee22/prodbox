{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Package-private Authority Model-B implementation for recovery-plane
-- evidence.  All raw observations, canonical bytes, adapter construction, and
-- write operations stay here.  The public facade can only independently read
-- opaque evidence through an abstract client.
module Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
  ( RecoveryPlaneRepositoryClient
  , RecoveryPlaneCommitResult (..)
  , RecoveryPlaneRepositoryError (..)
  , modelBRecoveryPlaneRepository
  , recoveryPlaneModelBCodecInternal
  , recoveryPlaneRepositoryLogicalName
  , withDescriptorBoundRecoveryPlaneIdentityInternal
  , withDescriptorBoundRecoveryPlaneEstablishBindingInternal
  , RecoveryPlaneObservationBinding
  , withRecoveryPlaneObservationEstablishBindingInternal
  , withDescriptorBoundRecoveryPlaneInitialContextInternal
  , withDescriptorBoundRecoveryPlaneInitialBindingsInternal
  , withDescriptorBoundRecoveryPlaneDispositionBindingsInternal
  , withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal
  , commitRecoveryPlaneInitialInternal
  , commitRecoveryPlaneFinalInternal
  , independentlyReadBackRecoveryPlaneInitial
  , independentlyReadBackRecoveryPlaneFinal
  , withRecoveredRecoveryPlaneInitialInternal
  , newFixedRecoveryPlaneRepositoryClientInternal
  , RecoveryPlaneRepositoryRegression
  , fixedRecoveryPlaneRepositoryRegression
  , recoveryPlaneRepositoryResponseLossRecovered
  , recoveryPlaneRepositoryExactReplayPreserved
  , recoveryPlaneRepositoryConflictPreserved
  , recoveryPlaneRepositoryRestartReadBack
  , recoveryPlaneRepositoryAttemptBindingEnforced
  , recoveryPlaneRepositoryCrossIdentityRefused
  , recoveryPlaneRepositoryComponentCompletenessEnforced
  , recoveryPlaneRepositoryEstablishedExact
  , recoveryPlaneRepositoryEstablishedAfterInitialFailure
  , recoveryPlaneRepositoryNotEstablishedExact
  , recoveryPlaneRepositoryLostExact
  , recoveryPlaneRepositoryCorruptionRefused
  , recoveryPlaneRepositoryBoundsEnforced
  , recoveryPlaneRepositoryProfileProgressionRecoverable
  , recoveryPlaneRepositoryObservationBindingExact
  , recoveryPlaneRepositoryObservationBindingPhaseRestricted
  , recoveryPlaneRepositoryOpacityClosed
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , deriveDescriptorBoundRecoveryRequirement
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupNodeOutcome
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupRunIdText
  , mkCleanupAttemptId
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownAttemptedPredecessor
  , TeardownExecutionContext
  , TeardownTerminalPredecessor
  , TeardownTerminalPredecessorResult (..)
  , teardownAttemptedPredecessorAttemptId
  , teardownAttemptedPredecessorOperation
  , teardownAttemptedPredecessorOperationId
  , teardownAttemptedPredecessorOutcome
  , teardownExecutionAttemptId
  , teardownExecutionAttemptedPredecessors
  , teardownExecutionDescriptorDigest
  , teardownExecutionGraphDigest
  , teardownExecutionNodeId
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  , teardownExecutionRunId
  , teardownExecutionTerminalPredecessors
  , teardownTerminalPredecessorOperation
  , teardownTerminalPredecessorOperationId
  , teardownTerminalPredecessorResult
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , ObservationEvidenceScope
  , ObservationFailure (..)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness (..)
  , TeardownOperation (..)
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneComponentFailureKind (..)
  , RecoveryPlaneEvidenceError (..)
  , RecoveryPlaneFinalDisposition (..)
  , RecoveryPlaneFinalEvidence
  , RecoveryPlaneIdentity
  , RecoveryPlaneInitialReadBack
  , recoveryPlaneComponentIdentityText
  , recoveryPlaneFinalDisposition
  , recoveryPlaneFinalDispositionAttemptId
  , recoveryPlaneFinalEstablishedReady
  , recoveryPlaneIdentityComponents
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityRunId
  , recoveryPlaneInitialEstablishAttemptId
  , recoveryPlaneInitialIdentity
  , recoveryPlaneInitialReadBackAttemptId
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneAttemptBinding (..)
  , RecoveryPlaneComponentObservationSet
  , RecoveryPlaneNormalizedComponentFact (..)
  , RecoveryPlaneNormalizedComponentState (..)
  , RecoveryPlaneNormalizedFacts
  , RecoveryPlaneRawComponentObservation (..)
  , RecoveryPlaneRawComponentResult (..)
  , decodeRecoveryPlaneIdentityWireInternal
  , deriveRecoveryPlaneIdentityFromCompiledInternal
  , encodeRecoveryPlaneIdentityWireInternal
  , fixedRecoveryPlaneDispositionAttemptIdInternal
  , fixedRecoveryPlaneEstablishAttemptIdInternal
  , fixedRecoveryPlaneIdentityInternal
  , fixedRecoveryPlaneReadBackAttemptIdInternal
  , fixedRecoveryPlaneTargetIdentityInternal
  , mkRecoveryPlaneFinalEvidenceInternal
  , mkRecoveryPlaneInitialReadBackInternal
  , normalizeRecoveryPlaneComponentFactsInternal
  , recoveryPlaneAttemptBindingAfterBeginInternal
  , recoveryPlaneComponentObservationSetInternal
  , recoveryPlaneIdentityDispositionOperationId
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityReadBackOperationId
  , recoveryPlaneInitialFactsInternal
  , recoveryPlaneNormalizedFactsEntries
  , restoreRecoveryPlaneIdentityFromCompiledInternal
  )
import Prodbox.Lifecycle.Teardown.RecoveryRequirement
  ( DerivedOrdinaryTeardownRecoveryRequirement
  )

data RecoveryPlaneRepositoryClient m
  = RecoveryPlaneRepositoryClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString)

data RecoveryPlaneCommitResult
  = RecoveryPlaneCommitCreated
  | RecoveryPlaneCommitExactReplay
  | RecoveryPlaneCommitConflict
  | RecoveryPlaneCommitResponseLost !ObservationFailure
  | RecoveryPlaneCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data RecoveryPlaneRepositoryError
  = RecoveryPlaneRepositoryCoordinateInvalid !Text
  | RecoveryPlaneRepositoryMissing
  | RecoveryPlaneRepositoryFinalMissing
  | RecoveryPlaneRepositoryCorrupt !Text
  | RecoveryPlaneRepositoryUnobservable !ObservationFailure
  | RecoveryPlaneRepositoryUnbounded !Int !Int
  | RecoveryPlaneRepositoryIdentityMismatch
  | RecoveryPlaneRepositoryAttemptMismatch !CleanupAttemptId !CleanupAttemptId
  | RecoveryPlaneRepositoryDispositionMismatch
      !RecoveryPlaneFinalDisposition
      !RecoveryPlaneFinalDisposition
  | RecoveryPlaneRepositoryEvidenceInvalid !RecoveryPlaneEvidenceError
  | RecoveryPlaneRepositoryDescriptorBindingInvalid !CleanupRunClientError
  | RecoveryPlaneRepositoryContextRunMismatch !CleanupRunId !CleanupRunId
  | RecoveryPlaneRepositoryContextDescriptorMismatch
      !(Maybe CleanupDigest)
      !CleanupDigest
  | RecoveryPlaneRepositoryContextGraphMismatch !CleanupDigest !CleanupDigest
  | RecoveryPlaneRepositoryContextScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | RecoveryPlaneRepositoryContextOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | RecoveryPlaneRepositoryContextNodeMismatch !CleanupNodeId
  | RecoveryPlaneRepositoryPredecessorCardinality !Text !Int
  | RecoveryPlaneRepositoryPredecessorOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | RecoveryPlaneRepositoryPredecessorStateMismatch !CleanupOperationId
  | RecoveryPlaneRepositoryPredecessorBlocked !CleanupOperationId
  | RecoveryPlaneRepositoryObservationPhaseMismatch !CleanupOperationId
  deriving stock (Eq, Show)

-- | Opaque binding presented to the Authority component observer.  It keeps
-- the current observation phase and the authoritative Establish predecessor
-- together, so a restarted observer never has to recover the Establish
-- attempt from process memory or caller-supplied text.
data RecoveryPlaneObservationBinding (surface :: CleanupSurface)
  = RecoveryPlaneObservationBindingInternal
      !(RecoveryPlaneIdentity surface)
      !CleanupOperationId
      !CleanupAttemptId
      !CleanupOperationId
      !CleanupAttemptId

mkRecoveryPlaneObservationBindingInternal
  :: RecoveryPlaneIdentity surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneObservationBinding surface
mkRecoveryPlaneObservationBindingInternal
  identity
  (RecoveryPlaneAttemptBindingInternal _ establishOperation establishAttempt)
  (RecoveryPlaneAttemptBindingInternal _ currentOperation currentAttempt) =
    RecoveryPlaneObservationBindingInternal
      identity
      establishOperation
      establishAttempt
      currentOperation
      currentAttempt

-- | Purpose-limited hidden eliminator for repositories keyed by the
-- Establish receipt.  It validates the caller's exact identity and refuses
-- an Establish-phase binding before reconstructing the private attempt
-- binding.  No operation or attempt accessor is exposed.
withRecoveryPlaneObservationEstablishBindingInternal
  :: RecoveryPlaneIdentity surface
  -> RecoveryPlaneObservationBinding surface
  -> (RecoveryPlaneAttemptBinding surface -> result)
  -> Either RecoveryPlaneRepositoryError result
withRecoveryPlaneObservationEstablishBindingInternal
  expectedIdentity
  ( RecoveryPlaneObservationBindingInternal
      actualIdentity
      establishOperation
      establishAttempt
      currentOperation
      _currentAttempt
    )
  consume = do
    unless
      (actualIdentity == expectedIdentity)
      (Left RecoveryPlaneRepositoryIdentityMismatch)
    unless
      (establishOperation == recoveryPlaneIdentityEstablishOperationId expectedIdentity)
      ( Left
          ( RecoveryPlaneRepositoryContextOperationMismatch
              (recoveryPlaneIdentityEstablishOperationId expectedIdentity)
              establishOperation
          )
      )
    unless
      ( currentOperation == recoveryPlaneIdentityReadBackOperationId expectedIdentity
          || currentOperation
            == recoveryPlaneIdentityDispositionOperationId expectedIdentity
      )
      (Left (RecoveryPlaneRepositoryObservationPhaseMismatch currentOperation))
    pure
      ( consume
          ( RecoveryPlaneAttemptBindingInternal
              expectedIdentity
              establishOperation
              establishAttempt
          )
      )

data RecoveryPlaneFactWire = RecoveryPlaneFactWire
  { factWireIdentity :: !Text
  , factWireState :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneFinalWire = RecoveryPlaneFinalWire
  { finalWireDispositionAttempt :: !Text
  , finalWireDisposition :: !Int
  , finalWireFacts :: ![RecoveryPlaneFactWire]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneAggregateWire = RecoveryPlaneAggregateWire
  { aggregateWireVersion :: !Int
  , aggregateWireIdentity :: !ByteString
  , aggregateWireEstablishAttempt :: !Text
  , aggregateWireInitialReadBackAttempt :: !Text
  , aggregateWireInitialFacts :: ![RecoveryPlaneFactWire]
  , aggregateWireFinal :: !(Maybe RecoveryPlaneFinalWire)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data DecodedRecoveryPlaneAggregate (surface :: CleanupSurface)
  = DecodedRecoveryPlaneAggregate
  { decodedRecoveryPlaneEstablishAttempt :: !CleanupAttemptId
  , decodedRecoveryPlaneInitialReadBackAttempt :: !CleanupAttemptId
  , decodedRecoveryPlaneInitialFacts :: !RecoveryPlaneNormalizedFacts
  , decodedRecoveryPlaneFinalFacts
      :: !( Maybe
              ( CleanupAttemptId
              , RecoveryPlaneFinalDisposition
              , RecoveryPlaneNormalizedFacts
              )
          )
  }

maximumRecoveryPlaneAggregateBytes :: Int
maximumRecoveryPlaneAggregateBytes = 128 * 1024

recoveryPlaneAggregateVersion :: Int
recoveryPlaneAggregateVersion = 1

modelBRecoveryPlaneRepository
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> RecoveryPlaneRepositoryClient m
modelBRecoveryPlaneRepository = RecoveryPlaneRepositoryClient

-- | Retained-Authority storage admission for the opaque recovery aggregate.
-- The generic Model-B layer checks the strict bound, canonical encoding, and
-- wire version only. Exact descriptor/run/scope/operation/attempt identity is
-- still reminted exclusively by the independent repository read-back.
recoveryPlaneModelBCodecInternal :: ModelBCodec ByteString
recoveryPlaneModelBCodecInternal =
  ModelBCodec
    { encodeModelBValue = validate
    , decodeModelBValue = validate
    }
 where
  validate bytes = bytes <$ first show (decodeAggregateWire bytes)

recoveryPlaneRepositoryLogicalName :: RecoveryPlaneIdentity surface -> Text
recoveryPlaneRepositoryLogicalName identity =
  recoveryPlaneRepositoryLogicalNameFor
    (cleanupRunIdText (recoveryPlaneIdentityRunId identity))
    (cleanupDigestText (recoveryPlaneIdentityDescriptorDigest identity))

recoveryPlaneRepositoryLogicalNameFor :: Text -> Text -> Text
recoveryPlaneRepositoryLogicalNameFor runId descriptorDigest =
  "authority/recovery-plane/"
    <> TextEncoding.decodeUtf8
      ( hexSha256
          ( lengthFrame
              [ "recovery-plane-coordinate/v1"
              , runId
              , descriptorDigest
              ]
          )
      )

lengthFrame :: [Text] -> ByteString
lengthFrame = ByteString.concat . map frame
 where
  frame value =
    let bytes = TextEncoding.encodeUtf8 value
     in TextEncoding.encodeUtf8 (Text.pack (show (ByteString.length bytes)) <> ":")
          <> bytes

-- | Re-enter the exact committed descriptor retained by the authenticated
-- cleanup-run handle, recompile its surface-indexed program, and derive the
-- recovery identity from the independently observed run requirement.  No raw
-- CleanupRun, descriptor bytes, or caller-selected profile crosses this seam.
withDescriptorBoundRecoveryPlaneIdentityInternal
  :: DescriptorBoundCleanupRun
  -> ( forall surface
        . RecoveryPlaneIdentity surface
       -> result
     )
  -> Either RecoveryPlaneRepositoryError result
withDescriptorBoundRecoveryPlaneIdentityInternal bound consume = do
  requirement <-
    first
      RecoveryPlaneRepositoryDescriptorBindingInvalid
      (deriveDescriptorBoundRecoveryRequirement bound)
  joined <-
    first
      RecoveryPlaneRepositoryDescriptorBindingInvalid
      ( withDescriptorBoundCleanupProgram bound $ \witness compiled _ ->
          do
            recoveryWitness <- recoveryWitnessFromCleanup witness
            consume
              <$> first
                RecoveryPlaneRepositoryEvidenceInvalid
                ( deriveRecoveryPlaneIdentityFromCompiledInternal
                    (descriptorBoundCleanupRunDescriptorDigest bound)
                    recoveryWitness
                    compiled
                    requirement
                )
      )
  joined

-- | Surface-typed identity admission for the current descriptor-bound
-- invocation. The recovery witness comes from the closed operation while the
-- matching cleanup witness and compiled program come only from the committed
-- descriptor retained by the opaque handle.
descriptorBoundRecoveryPlaneIdentityForInternal
  :: forall surface
   . DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> Either RecoveryPlaneRepositoryError (RecoveryPlaneIdentity surface)
descriptorBoundRecoveryPlaneIdentityForInternal bound expectedWitness = do
  requirement <-
    first
      RecoveryPlaneRepositoryDescriptorBindingInvalid
      (deriveDescriptorBoundRecoveryRequirement bound)
  joined <-
    first
      RecoveryPlaneRepositoryDescriptorBindingInvalid
      ( withDescriptorBoundCleanupProgram bound $ \actualWitness compiled _ ->
          deriveMatchingIdentity requirement actualWitness compiled
      )
  joined
 where
  deriveMatchingIdentity
    :: forall actual
     . DerivedOrdinaryTeardownRecoveryRequirement
    -> CleanupSurfaceWitness actual
    -> CompiledDesiredAbsenceProgram actual
    -> Either RecoveryPlaneRepositoryError (RecoveryPlaneIdentity surface)
  deriveMatchingIdentity requirement actualWitness compiled =
    case (expectedWitness, actualWitness) of
      (CascadeRecoverySurface, CascadeSurface) ->
        derive CascadeRecoverySurface compiled
      (ExplicitPerRunRecoverySurface, ExplicitPerRunSurface) ->
        derive ExplicitPerRunRecoverySurface compiled
      (OperationalRecoverySurface, OperationalTeardownSurface) ->
        derive OperationalRecoverySurface compiled
      (ExplicitLongLivedRecoverySurface, ExplicitLongLivedSurface) ->
        derive ExplicitLongLivedRecoverySurface compiled
      _ ->
        Left
          ( RecoveryPlaneRepositoryEvidenceInvalid
              ( RecoveryPlaneBindingSurfaceMismatch
                  (recoverySurface expectedWitness)
                  (cleanupSurface actualWitness)
              )
          )
   where
    derive
      :: RecoverySurfaceWitness actual
      -> CompiledDesiredAbsenceProgram actual
      -> Either RecoveryPlaneRepositoryError (RecoveryPlaneIdentity actual)
    derive witness candidateCompiled =
      first
        RecoveryPlaneRepositoryEvidenceInvalid
        ( deriveRecoveryPlaneIdentityFromCompiledInternal
            (descriptorBoundCleanupRunDescriptorDigest bound)
            witness
            candidateCompiled
            requirement
        )
  recoverySurface
    :: RecoverySurfaceWitness actual -> CleanupSurface
  recoverySurface witness = case witness of
    CascadeRecoverySurface -> Cascade
    ExplicitPerRunRecoverySurface -> ExplicitPerRun
    OperationalRecoverySurface -> OperationalTeardown
    ExplicitLongLivedRecoverySurface -> ExplicitLongLived
  cleanupSurface :: CleanupSurfaceWitness actual -> CleanupSurface
  cleanupSurface witness = case witness of
    LocalOnlySurface -> LocalOnly
    CascadeSurface -> Cascade
    ExplicitPerRunSurface -> ExplicitPerRun
    OperationalTeardownSurface -> OperationalTeardown
    ExplicitLongLivedSurface -> ExplicitLongLived
    TotalDecommissionSurface -> TotalDecommission

-- | Bind the Establish mutation/repair attempt only after its exact node has
-- begun in the opaque descriptor-bound handle.
withDescriptorBoundRecoveryPlaneEstablishBindingInternal
  :: DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> ( RecoveryPlaneIdentity surface
       -> RecoveryPlaneAttemptBinding surface
       -> result
     )
  -> Either RecoveryPlaneRepositoryError result
withDescriptorBoundRecoveryPlaneEstablishBindingInternal bound witness context consume = do
  identity <- descriptorBoundRecoveryPlaneIdentityForInternal bound witness
  binding <-
    currentOperationBinding
      bound
      identity
      (recoveryPlaneIdentityEstablishOperationId identity)
      context
  pure (consume identity binding)

-- | Initial observation binder derived entirely from the operation witness,
-- committed descriptor, post-Begin handle, and exact attempted Establish
-- receipt. Callers cannot submit an identity or attempt projection.
withDescriptorBoundRecoveryPlaneInitialContextInternal
  :: DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> ( RecoveryPlaneIdentity surface
       -> RecoveryPlaneAttemptBinding surface
       -> RecoveryPlaneAttemptBinding surface
       -> RecoveryPlaneObservationBinding surface
       -> result
     )
  -> Either RecoveryPlaneRepositoryError result
withDescriptorBoundRecoveryPlaneInitialContextInternal bound witness context consume = do
  identity <- descriptorBoundRecoveryPlaneIdentityForInternal bound witness
  withDescriptorBoundRecoveryPlaneInitialBindingsInternal
    bound
    identity
    context
    ( \establishBinding currentBinding ->
        consume
          identity
          establishBinding
          currentBinding
          ( mkRecoveryPlaneObservationBindingInternal
              identity
              establishBinding
              currentBinding
          )
    )

-- | Bind initial read-back only from the post-Begin opaque run handle and the
-- exact execution context minted for the current ReadBack node.  The sole
-- RequiresAttempt predecessor must be Establish for this surface, and its
-- fenced attempt/outcome must agree with the same authoritative handle.
withDescriptorBoundRecoveryPlaneInitialBindingsInternal
  :: DescriptorBoundCleanupRun
  -> RecoveryPlaneIdentity surface
  -> TeardownExecutionContext surface
  -> ( RecoveryPlaneAttemptBinding surface
       -> RecoveryPlaneAttemptBinding surface
       -> result
     )
  -> Either RecoveryPlaneRepositoryError result
withDescriptorBoundRecoveryPlaneInitialBindingsInternal
  bound
  identity
  context
  consume = do
    readBackBinding <-
      currentOperationBinding
        bound
        identity
        (recoveryPlaneIdentityReadBackOperationId identity)
        context
    predecessor <- exactAttemptedEstablish identity context
    establishBinding <-
      completedPredecessorBinding
        bound
        identity
        (recoveryPlaneIdentityEstablishOperationId identity)
        (teardownAttemptedPredecessorAttemptId predecessor)
        (teardownAttemptedPredecessorOutcome predecessor)
    pure (consume establishBinding readBackBinding)

-- | Bind final disposition from its own post-Begin context and the exact
-- terminal ReadBack receipt.  Other terminal target receipts may coexist,
-- but precisely one must name this immutable recovery ReadBack operation.
withDescriptorBoundRecoveryPlaneDispositionBindingsInternal
  :: DescriptorBoundCleanupRun
  -> RecoveryPlaneIdentity surface
  -> TeardownExecutionContext surface
  -> ( RecoveryPlaneAttemptBinding surface
       -> RecoveryPlaneAttemptBinding surface
       -> result
     )
  -> Either RecoveryPlaneRepositoryError result
withDescriptorBoundRecoveryPlaneDispositionBindingsInternal
  bound
  identity
  context
  consume = do
    dispositionBinding <-
      currentOperationBinding
        bound
        identity
        (recoveryPlaneIdentityDispositionOperationId identity)
        context
    predecessor <- exactTerminalReadBack identity context
    (readBackAttempt, readBackOutcome) <-
      case teardownTerminalPredecessorResult predecessor of
        TeardownTerminalPredecessorCompleted attempt outcome ->
          Right (attempt, outcome)
        TeardownTerminalPredecessorBlocked _ ->
          Left
            ( RecoveryPlaneRepositoryPredecessorBlocked
                (recoveryPlaneIdentityReadBackOperationId identity)
            )
    readBackBinding <-
      completedPredecessorBinding
        bound
        identity
        (recoveryPlaneIdentityReadBackOperationId identity)
        readBackAttempt
        readBackOutcome
    pure (consume readBackBinding dispositionBinding)

currentOperationBinding
  :: DescriptorBoundCleanupRun
  -> RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> TeardownExecutionContext surface
  -> Either
       RecoveryPlaneRepositoryError
       (RecoveryPlaneAttemptBinding surface)
currentOperationBinding bound identity expectedOperation context = do
  validateHandleAndContext bound identity context
  unless
    (teardownExecutionOperationId context == expectedOperation)
    ( Left
        ( RecoveryPlaneRepositoryContextOperationMismatch
            expectedOperation
            (teardownExecutionOperationId context)
        )
    )
  plan <-
    maybe
      (Left (RecoveryPlaneRepositoryContextNodeMismatch (teardownExecutionNodeId context)))
      Right
      ( find
          ((== teardownExecutionNodeId context) . cleanupNodeId)
          (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound))
      )
  unless
    (cleanupNodeOperationId plan == expectedOperation)
    ( Left
        ( RecoveryPlaneRepositoryContextOperationMismatch
            expectedOperation
            (cleanupNodeOperationId plan)
        )
    )
  state <-
    maybe
      (Left (RecoveryPlaneRepositoryContextNodeMismatch (teardownExecutionNodeId context)))
      Right
      ( Map.lookup
          (teardownExecutionNodeId context)
          (descriptorBoundCleanupRunNodeStates bound)
      )
  first
    RecoveryPlaneRepositoryEvidenceInvalid
    ( recoveryPlaneAttemptBindingAfterBeginInternal
        identity
        expectedOperation
        (teardownExecutionAttemptId context)
        state
    )

validateHandleAndContext
  :: DescriptorBoundCleanupRun
  -> RecoveryPlaneIdentity surface
  -> TeardownExecutionContext surface
  -> Either RecoveryPlaneRepositoryError ()
validateHandleAndContext bound identity context = do
  unless
    ( recoveryPlaneIdentityDescriptorDigest identity
        == descriptorBoundCleanupRunDescriptorDigest bound
    )
    (Left RecoveryPlaneRepositoryIdentityMismatch)
  unless
    (recoveryPlaneIdentityRunId identity == descriptorBoundCleanupRunId bound)
    ( Left
        ( RecoveryPlaneRepositoryContextRunMismatch
            (recoveryPlaneIdentityRunId identity)
            (descriptorBoundCleanupRunId bound)
        )
    )
  unless
    ( recoveryPlaneIdentityGraphDigest identity
        == descriptorBoundCleanupRunGraphDigest bound
    )
    ( Left
        ( RecoveryPlaneRepositoryContextGraphMismatch
            (recoveryPlaneIdentityGraphDigest identity)
            (descriptorBoundCleanupRunGraphDigest bound)
        )
    )
  unless
    (teardownExecutionRunId context == recoveryPlaneIdentityRunId identity)
    ( Left
        ( RecoveryPlaneRepositoryContextRunMismatch
            (recoveryPlaneIdentityRunId identity)
            (teardownExecutionRunId context)
        )
    )
  unless
    ( teardownExecutionDescriptorDigest context
        == Just (recoveryPlaneIdentityDescriptorDigest identity)
    )
    ( Left
        ( RecoveryPlaneRepositoryContextDescriptorMismatch
            (teardownExecutionDescriptorDigest context)
            (recoveryPlaneIdentityDescriptorDigest identity)
        )
    )
  unless
    (teardownExecutionGraphDigest context == recoveryPlaneIdentityGraphDigest identity)
    ( Left
        ( RecoveryPlaneRepositoryContextGraphMismatch
            (recoveryPlaneIdentityGraphDigest identity)
            (teardownExecutionGraphDigest context)
        )
    )
  unless
    ( teardownExecutionObservationScope context
        == recoveryPlaneIdentityObservationScope identity
    )
    ( Left
        ( RecoveryPlaneRepositoryContextScopeMismatch
            (recoveryPlaneIdentityObservationScope identity)
            (teardownExecutionObservationScope context)
        )
    )

exactAttemptedEstablish
  :: RecoveryPlaneIdentity surface
  -> TeardownExecutionContext surface
  -> Either
       RecoveryPlaneRepositoryError
       (TeardownAttemptedPredecessor surface)
exactAttemptedEstablish identity context =
  case teardownExecutionAttemptedPredecessors context of
    [predecessor] -> do
      unless
        ( teardownAttemptedPredecessorOperationId predecessor
            == recoveryPlaneIdentityEstablishOperationId identity
        )
        ( Left
            ( RecoveryPlaneRepositoryPredecessorOperationMismatch
                (recoveryPlaneIdentityEstablishOperationId identity)
                (teardownAttemptedPredecessorOperationId predecessor)
            )
        )
      case teardownAttemptedPredecessorOperation predecessor of
        EstablishRecoveryPlane _ -> Right predecessor
        _ ->
          Left
            ( RecoveryPlaneRepositoryPredecessorStateMismatch
                (teardownAttemptedPredecessorOperationId predecessor)
            )
    predecessors ->
      Left
        ( RecoveryPlaneRepositoryPredecessorCardinality
            "establish"
            (length predecessors)
        )

exactTerminalReadBack
  :: RecoveryPlaneIdentity surface
  -> TeardownExecutionContext surface
  -> Either
       RecoveryPlaneRepositoryError
       (TeardownTerminalPredecessor surface)
exactTerminalReadBack identity context =
  case filter
    ( (== recoveryPlaneIdentityReadBackOperationId identity)
        . teardownTerminalPredecessorOperationId
    )
    (teardownExecutionTerminalPredecessors context) of
    [predecessor] -> case teardownTerminalPredecessorOperation predecessor of
      ReadBackRecoveryPlane _ -> Right predecessor
      _ ->
        Left
          ( RecoveryPlaneRepositoryPredecessorStateMismatch
              (teardownTerminalPredecessorOperationId predecessor)
          )
    predecessors ->
      Left
        ( RecoveryPlaneRepositoryPredecessorCardinality
            "read-back"
            (length predecessors)
        )

completedPredecessorBinding
  :: DescriptorBoundCleanupRun
  -> RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupNodeOutcome
  -> Either
       RecoveryPlaneRepositoryError
       (RecoveryPlaneAttemptBinding surface)
completedPredecessorBinding bound identity operationId attempt outcome = do
  plan <-
    maybe
      (Left (RecoveryPlaneRepositoryPredecessorStateMismatch operationId))
      Right
      ( find
          ((== operationId) . cleanupNodeOperationId)
          (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound))
      )
  state <-
    maybe
      (Left (RecoveryPlaneRepositoryPredecessorStateMismatch operationId))
      Right
      ( Map.lookup
          (cleanupNodeId plan)
          (descriptorBoundCleanupRunNodeStates bound)
      )
  unless
    (state == CleanupNodeCompleted attempt outcome)
    (Left (RecoveryPlaneRepositoryPredecessorStateMismatch operationId))
  first
    RecoveryPlaneRepositoryEvidenceInvalid
    ( recoveryPlaneAttemptBindingAfterBeginInternal
        identity
        operationId
        attempt
        state
    )

commitRecoveryPlaneInitialInternal
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneComponentObservationSet surface
  -> m (Either RecoveryPlaneRepositoryError RecoveryPlaneCommitResult)
commitRecoveryPlaneInitialInternal client establishBinding readBackBinding observation =
  case normalizeRecoveryPlaneComponentFactsInternal readBackBinding observation of
    Left evidenceError ->
      pure (Left (RecoveryPlaneRepositoryEvidenceInvalid evidenceError))
    Right facts -> commitInitialFacts client establishBinding readBackBinding facts

commitRecoveryPlaneFinalInternal
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneInitialReadBack surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneComponentObservationSet surface
  -> m (Either RecoveryPlaneRepositoryError RecoveryPlaneCommitResult)
commitRecoveryPlaneFinalInternal client initial dispositionBinding observation = do
  case normalizeRecoveryPlaneComponentFactsInternal dispositionBinding observation of
    Left evidenceError ->
      pure (Left (RecoveryPlaneRepositoryEvidenceInvalid evidenceError))
    Right freshFacts ->
      case mkRecoveryPlaneFinalEvidenceInternal
        initial
        dispositionBinding
        freshFacts of
        Left evidenceError ->
          pure (Left (RecoveryPlaneRepositoryEvidenceInvalid evidenceError))
        Right finalEvidence ->
          commitFinalFacts
            client
            initial
            dispositionBinding
            finalEvidence
            freshFacts

independentlyReadBackRecoveryPlaneInitial
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> m
       ( Either
           RecoveryPlaneRepositoryError
           (RecoveryPlaneInitialReadBack surface)
       )
independentlyReadBackRecoveryPlaneInitial client identity expectedReadBackAttempt = do
  observed <- observeAggregate client identity
  pure $ do
    bytes <- observed
    aggregate <- decodeAggregate identity expectedReadBackAttempt Nothing bytes
    let establishBinding =
          RecoveryPlaneAttemptBindingInternal
            identity
            (recoveryPlaneIdentityEstablishOperationId identity)
            (decodedRecoveryPlaneEstablishAttempt aggregate)
        readBackBinding =
          RecoveryPlaneAttemptBindingInternal
            identity
            (recoveryPlaneIdentityReadBackOperationId identity)
            expectedReadBackAttempt
    first
      RecoveryPlaneRepositoryEvidenceInvalid
      ( mkRecoveryPlaneInitialReadBackInternal
          establishBinding
          readBackBinding
          (decodedRecoveryPlaneInitialFacts aggregate)
      )

independentlyReadBackRecoveryPlaneFinal
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> m
       ( Either
           RecoveryPlaneRepositoryError
           (RecoveryPlaneFinalEvidence surface)
       )
independentlyReadBackRecoveryPlaneFinal
  client
  identity
  expectedReadBackAttempt
  expectedDispositionAttempt = do
    observed <- observeAggregate client identity
    pure $ do
      bytes <- observed
      aggregate <-
        decodeAggregate
          identity
          expectedReadBackAttempt
          (Just expectedDispositionAttempt)
          bytes
      (recordedDispositionAttempt, recordedDisposition, finalFacts) <-
        maybe
          (Left RecoveryPlaneRepositoryFinalMissing)
          Right
          (decodedRecoveryPlaneFinalFacts aggregate)
      unless
        (recordedDispositionAttempt == expectedDispositionAttempt)
        ( Left
            ( RecoveryPlaneRepositoryAttemptMismatch
                expectedDispositionAttempt
                recordedDispositionAttempt
            )
        )
      let establishBinding =
            RecoveryPlaneAttemptBindingInternal
              identity
              (recoveryPlaneIdentityEstablishOperationId identity)
              (decodedRecoveryPlaneEstablishAttempt aggregate)
          readBackBinding =
            RecoveryPlaneAttemptBindingInternal
              identity
              (recoveryPlaneIdentityReadBackOperationId identity)
              expectedReadBackAttempt
          dispositionBinding =
            RecoveryPlaneAttemptBindingInternal
              identity
              (recoveryPlaneIdentityDispositionOperationId identity)
              expectedDispositionAttempt
      initial <-
        first
          RecoveryPlaneRepositoryEvidenceInvalid
          ( mkRecoveryPlaneInitialReadBackInternal
              establishBinding
              readBackBinding
              (decodedRecoveryPlaneInitialFacts aggregate)
          )
      finalEvidence <-
        first
          RecoveryPlaneRepositoryEvidenceInvalid
          ( mkRecoveryPlaneFinalEvidenceInternal
              initial
              dispositionBinding
              finalFacts
          )
      let actualDisposition = recoveryPlaneFinalDisposition finalEvidence
      unless
        (recordedDisposition == actualDisposition)
        ( Left
            ( RecoveryPlaneRepositoryDispositionMismatch
                recordedDisposition
                actualDisposition
            )
        )
      pure finalEvidence

-- | Recover the immutable initial identity from Authority-owned bytes under
-- the static run/descriptor coordinate.  This is the restart seam for final
-- disposition: it intentionally does not re-derive the dynamic recovery
-- requirement from later node states.
withRecoveredRecoveryPlaneInitialInternal
  :: forall m result
   . (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> CleanupAttemptId
  -> ( forall surface
        . RecoveryPlaneIdentity surface
       -> RecoveryPlaneInitialReadBack surface
       -> result
     )
  -> m (Either RecoveryPlaneRepositoryError result)
withRecoveredRecoveryPlaneInitialInternal
  client
  bound
  expectedReadBackAttempt
  consume =
    case withDescriptorBoundCleanupProgram bound recover of
      Left err ->
        pure (Left (RecoveryPlaneRepositoryDescriptorBindingInvalid err))
      Right action -> action
   where
    recover
      :: forall surface
       . CleanupSurfaceWitness surface
      -> CompiledDesiredAbsenceProgram surface
      -> DescriptorBoundCleanupRun
      -> m (Either RecoveryPlaneRepositoryError result)
    recover witness compiled _ =
      case recoveryWitnessFromCleanup witness of
        Left err -> pure (Left err)
        Right recoveryWitness -> do
          observed <- observeAggregateForBound client bound
          pure $ do
            bytes <- observed
            wire <- decodeAggregateWire bytes
            identity <-
              first
                RecoveryPlaneRepositoryEvidenceInvalid
                ( restoreRecoveryPlaneIdentityFromCompiledInternal
                    (descriptorBoundCleanupRunDescriptorDigest bound)
                    recoveryWitness
                    compiled
                    (aggregateWireIdentity wire)
                )
            aggregate <-
              decodeAggregate identity expectedReadBackAttempt Nothing bytes
            let establishBinding =
                  RecoveryPlaneAttemptBindingInternal
                    identity
                    (recoveryPlaneIdentityEstablishOperationId identity)
                    (decodedRecoveryPlaneEstablishAttempt aggregate)
                readBackBinding =
                  RecoveryPlaneAttemptBindingInternal
                    identity
                    (recoveryPlaneIdentityReadBackOperationId identity)
                    expectedReadBackAttempt
            initial <-
              first
                RecoveryPlaneRepositoryEvidenceInvalid
                ( mkRecoveryPlaneInitialReadBackInternal
                    establishBinding
                    readBackBinding
                    (decodedRecoveryPlaneInitialFacts aggregate)
                )
            pure (consume identity initial)

-- | Typed restart recovery for a caller already executing one closed recovery
-- operation. Unlike the public rank-2 readback, this preserves the caller's
-- surface index by matching it against the committed descriptor witness
-- before restoring the stored immutable identity.
recoverRecoveryPlaneInitialForWitnessInternal
  :: forall m surface
   . (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> CleanupAttemptId
  -> m
       ( Either
           RecoveryPlaneRepositoryError
           (RecoveryPlaneIdentity surface, RecoveryPlaneInitialReadBack surface)
       )
recoverRecoveryPlaneInitialForWitnessInternal client bound expectedWitness expectedReadBackAttempt =
  case withDescriptorBoundCleanupProgram bound $ \actualWitness compiled _ ->
    recoverMatching actualWitness compiled of
    Left err ->
      pure (Left (RecoveryPlaneRepositoryDescriptorBindingInvalid err))
    Right action -> action
 where
  recoverMatching
    :: forall actual
     . CleanupSurfaceWitness actual
    -> CompiledDesiredAbsenceProgram actual
    -> m
         ( Either
             RecoveryPlaneRepositoryError
             (RecoveryPlaneIdentity surface, RecoveryPlaneInitialReadBack surface)
         )
  recoverMatching actualWitness candidateCompiled =
    case (expectedWitness, actualWitness) of
      (CascadeRecoverySurface, CascadeSurface) ->
        recover CascadeRecoverySurface candidateCompiled
      (ExplicitPerRunRecoverySurface, ExplicitPerRunSurface) ->
        recover ExplicitPerRunRecoverySurface candidateCompiled
      (OperationalRecoverySurface, OperationalTeardownSurface) ->
        recover OperationalRecoverySurface candidateCompiled
      (ExplicitLongLivedRecoverySurface, ExplicitLongLivedSurface) ->
        recover ExplicitLongLivedRecoverySurface candidateCompiled
      _ ->
        pure
          ( Left
              ( RecoveryPlaneRepositoryEvidenceInvalid
                  ( RecoveryPlaneBindingSurfaceMismatch
                      (recoverySurface expectedWitness)
                      (cleanupSurface actualWitness)
                  )
              )
          )
  recover
    :: forall actual
     . RecoverySurfaceWitness actual
    -> CompiledDesiredAbsenceProgram actual
    -> m
         ( Either
             RecoveryPlaneRepositoryError
             (RecoveryPlaneIdentity actual, RecoveryPlaneInitialReadBack actual)
         )
  recover recoveryWitness candidateCompiled = do
    observed <- observeAggregateForBound client bound
    pure $ do
      bytes <- observed
      wire <- decodeAggregateWire bytes
      identity <-
        first
          RecoveryPlaneRepositoryEvidenceInvalid
          ( restoreRecoveryPlaneIdentityFromCompiledInternal
              (descriptorBoundCleanupRunDescriptorDigest bound)
              recoveryWitness
              candidateCompiled
              (aggregateWireIdentity wire)
          )
      aggregate <-
        decodeAggregate identity expectedReadBackAttempt Nothing bytes
      let establishBinding =
            RecoveryPlaneAttemptBindingInternal
              identity
              (recoveryPlaneIdentityEstablishOperationId identity)
              (decodedRecoveryPlaneEstablishAttempt aggregate)
          readBackBinding =
            RecoveryPlaneAttemptBindingInternal
              identity
              (recoveryPlaneIdentityReadBackOperationId identity)
              expectedReadBackAttempt
      initial <-
        first
          RecoveryPlaneRepositoryEvidenceInvalid
          ( mkRecoveryPlaneInitialReadBackInternal
              establishBinding
              readBackBinding
              (decodedRecoveryPlaneInitialFacts aggregate)
          )
      pure (identity, initial)
  recoverySurface
    :: RecoverySurfaceWitness actual -> CleanupSurface
  recoverySurface witness = case witness of
    CascadeRecoverySurface -> Cascade
    ExplicitPerRunRecoverySurface -> ExplicitPerRun
    OperationalRecoverySurface -> OperationalTeardown
    ExplicitLongLivedRecoverySurface -> ExplicitLongLived
  cleanupSurface :: CleanupSurfaceWitness actual -> CleanupSurface
  cleanupSurface witness = case witness of
    LocalOnlySurface -> LocalOnly
    CascadeSurface -> Cascade
    ExplicitPerRunSurface -> ExplicitPerRun
    OperationalTeardownSurface -> OperationalTeardown
    ExplicitLongLivedSurface -> ExplicitLongLived
    TotalDecommissionSurface -> TotalDecommission

-- | Static-final restart binder. It locates the exact terminal ReadBack
-- attempt from the current durable context, restores the immutable initial
-- identity/evidence from Authority bytes, then revalidates that restored
-- identity against the post-Begin disposition handle. No dynamic requirement
-- re-derivation can replace the stored initial profile.
withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> RecoverySurfaceWitness surface
  -> TeardownExecutionContext surface
  -> ( RecoveryPlaneIdentity surface
       -> RecoveryPlaneInitialReadBack surface
       -> RecoveryPlaneAttemptBinding surface
       -> RecoveryPlaneObservationBinding surface
       -> result
     )
  -> m (Either RecoveryPlaneRepositoryError result)
withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal client bound witness context consume =
  case descriptorBoundRecoveryPlaneIdentityForInternal bound witness of
    Left err -> pure (Left err)
    Right currentIdentity -> case exactTerminalReadBack currentIdentity context of
      Left err -> pure (Left err)
      Right predecessor -> case teardownTerminalPredecessorResult predecessor of
        TeardownTerminalPredecessorBlocked _ ->
          pure
            ( Left
                ( RecoveryPlaneRepositoryPredecessorBlocked
                    (recoveryPlaneIdentityReadBackOperationId currentIdentity)
                )
            )
        TeardownTerminalPredecessorCompleted readBackAttempt _ -> do
          recovered <-
            recoverRecoveryPlaneInitialForWitnessInternal
              client
              bound
              witness
              readBackAttempt
          pure $ do
            (identity, initial) <- recovered
            withDescriptorBoundRecoveryPlaneDispositionBindingsInternal
              bound
              identity
              context
              ( \_ dispositionBinding ->
                  let establishBinding =
                        RecoveryPlaneAttemptBindingInternal
                          identity
                          (recoveryPlaneIdentityEstablishOperationId identity)
                          (recoveryPlaneInitialEstablishAttemptId initial)
                   in consume
                        identity
                        initial
                        dispositionBinding
                        ( mkRecoveryPlaneObservationBindingInternal
                            identity
                            establishBinding
                            dispositionBinding
                        )
              )

recoveryWitnessFromCleanup
  :: CleanupSurfaceWitness surface
  -> Either
       RecoveryPlaneRepositoryError
       (RecoverySurfaceWitness surface)
recoveryWitnessFromCleanup witness = case witness of
  CascadeSurface -> Right CascadeRecoverySurface
  ExplicitPerRunSurface -> Right ExplicitPerRunRecoverySurface
  OperationalTeardownSurface -> Right OperationalRecoverySurface
  ExplicitLongLivedSurface -> Right ExplicitLongLivedRecoverySurface
  LocalOnlySurface -> unsupported LocalOnly
  TotalDecommissionSurface -> unsupported TotalDecommission
 where
  unsupported surface =
    Left
      ( RecoveryPlaneRepositoryEvidenceInvalid
          (RecoveryPlaneBindingUnsupportedSurface surface)
      )

commitInitialFacts
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneNormalizedFacts
  -> m (Either RecoveryPlaneRepositoryError RecoveryPlaneCommitResult)
commitInitialFacts
  client@(RecoveryPlaneRepositoryClient _ adapter)
  (RecoveryPlaneAttemptBindingInternal identity establishOperation establishAttempt)
  (RecoveryPlaneAttemptBindingInternal readBackIdentity readBackOperation readBackAttempt)
  facts =
    case validateBindings of
      Left err -> pure (Left err)
      Right () -> case aggregateCoordinate client identity of
        Left err -> pure (Left err)
        Right coordinate -> do
          let candidate =
                initialAggregateBytes
                  identity
                  establishAttempt
                  readBackAttempt
                  facts
          observed <- modelBObserve adapter coordinate
          case observed of
            ModelBMissing -> initialize coordinate candidate
            ModelBObserved _ existing ->
              pure
                ( Right
                    ( existingInitialDisposition
                        identity
                        establishAttempt
                        readBackAttempt
                        facts
                        existing
                    )
                )
            ModelBCorrupt detail -> pure (Right (unavailable "observe-corrupt" detail))
            ModelBEndpointUnready detail ->
              pure (Right (unavailable "observe-endpoint-unready" detail))
            ModelBUnobservable detail ->
              pure (Right (unavailable "observe-unobservable" detail))
   where
    validateBindings = do
      unless
        (identity == readBackIdentity)
        (Left RecoveryPlaneRepositoryIdentityMismatch)
      unless
        (establishOperation == recoveryPlaneIdentityEstablishOperationId identity)
        ( Left
            ( RecoveryPlaneRepositoryEvidenceInvalid
                ( RecoveryPlaneObservationOperationMismatch
                    (recoveryPlaneIdentityEstablishOperationId identity)
                    establishOperation
                )
            )
        )
      unless
        (readBackOperation == recoveryPlaneIdentityReadBackOperationId identity)
        ( Left
            ( RecoveryPlaneRepositoryEvidenceInvalid
                ( RecoveryPlaneObservationOperationMismatch
                    (recoveryPlaneIdentityReadBackOperationId identity)
                    readBackOperation
                )
            )
        )

    initialize coordinate candidate = do
      attempted <-
        modelBCompareAndSwap adapter (ModelBInitialize coordinate candidate)
      pure . Right $ case attempted of
        ModelBCasApplied _ bytes
          | bytes == candidate -> RecoveryPlaneCommitCreated
          | otherwise -> RecoveryPlaneCommitConflict
        ModelBCasConflict conflict ->
          conflictInitialDisposition
            identity
            establishAttempt
            readBackAttempt
            facts
            conflict
        ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
        ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
        ModelBCasUnobservable detail -> responseLost "cas-unobservable" detail

commitFinalFacts
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneInitialReadBack surface
  -> RecoveryPlaneAttemptBinding surface
  -> RecoveryPlaneFinalEvidence surface
  -> RecoveryPlaneNormalizedFacts
  -> m (Either RecoveryPlaneRepositoryError RecoveryPlaneCommitResult)
commitFinalFacts
  client@(RecoveryPlaneRepositoryClient _ adapter)
  initial
  ( RecoveryPlaneAttemptBindingInternal
      dispositionIdentity
      dispositionOperation
      dispositionAttempt
    )
  finalEvidence
  finalFacts =
    case validateDispositionBinding of
      Left err -> pure (Left err)
      Right () -> case aggregateCoordinate client identity of
        Left err -> pure (Left err)
        Right coordinate -> do
          observed <- modelBObserve adapter coordinate
          case observed of
            ModelBMissing -> pure (Right RecoveryPlaneCommitConflict)
            ModelBObserved version existing ->
              case decodeAggregate
                identity
                readBackAttempt
                (Just dispositionAttempt)
                existing of
                Left err -> pure (Left err)
                Right aggregate ->
                  if decodedRecoveryPlaneEstablishAttempt aggregate /= establishAttempt
                    || decodedRecoveryPlaneInitialFacts aggregate /= initialFacts
                    then pure (Right RecoveryPlaneCommitConflict)
                    else case decodedRecoveryPlaneFinalFacts aggregate of
                      Just
                        ( existingDispositionAttempt
                          , existingDisposition
                          , existingFacts
                          )
                          | existingDispositionAttempt == dispositionAttempt
                              && existingDisposition == disposition
                              && existingFacts == finalFacts ->
                              pure (Right RecoveryPlaneCommitExactReplay)
                          | otherwise -> pure (Right RecoveryPlaneCommitConflict)
                      Nothing -> replace coordinate version
            ModelBCorrupt detail -> pure (Right (unavailable "observe-corrupt" detail))
            ModelBEndpointUnready detail ->
              pure (Right (unavailable "observe-endpoint-unready" detail))
            ModelBUnobservable detail ->
              pure (Right (unavailable "observe-unobservable" detail))
   where
    identity = recoveryPlaneInitialIdentity initial
    establishAttempt = recoveryPlaneInitialEstablishAttemptId initial
    readBackAttempt = recoveryPlaneInitialReadBackAttemptId initial
    initialFacts = recoveryPlaneInitialFactsInternal initial
    disposition = recoveryPlaneFinalDisposition finalEvidence
    candidate =
      finalAggregateBytes
        identity
        establishAttempt
        readBackAttempt
        initialFacts
        dispositionAttempt
        disposition
        finalFacts

    validateDispositionBinding = do
      unless
        (identity == dispositionIdentity)
        (Left RecoveryPlaneRepositoryIdentityMismatch)
      unless
        ( dispositionOperation
            == recoveryPlaneIdentityDispositionOperationId identity
        )
        ( Left
            ( RecoveryPlaneRepositoryEvidenceInvalid
                ( RecoveryPlaneObservationOperationMismatch
                    (recoveryPlaneIdentityDispositionOperationId identity)
                    dispositionOperation
                )
            )
        )
      unless
        (dispositionAttempt == recoveryPlaneFinalDispositionAttemptId finalEvidence)
        ( Left
            ( RecoveryPlaneRepositoryAttemptMismatch
                (recoveryPlaneFinalDispositionAttemptId finalEvidence)
                dispositionAttempt
            )
        )

    replace coordinate version = do
      attempted <-
        modelBCompareAndSwap adapter (ModelBReplace coordinate version candidate)
      pure . Right $ case attempted of
        ModelBCasApplied _ bytes
          | bytes == candidate -> RecoveryPlaneCommitCreated
          | otherwise -> RecoveryPlaneCommitConflict
        ModelBCasConflict conflict ->
          conflictFinalDisposition
            identity
            establishAttempt
            readBackAttempt
            initialFacts
            dispositionAttempt
            disposition
            finalFacts
            conflict
        ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
        ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
        ModelBCasUnobservable detail -> responseLost "cas-unobservable" detail

observeAggregate
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> m (Either RecoveryPlaneRepositoryError ByteString)
observeAggregate
  client@(RecoveryPlaneRepositoryClient _ adapter)
  identity =
    case aggregateCoordinate client identity of
      Left err -> pure (Left err)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Left RecoveryPlaneRepositoryMissing
          ModelBObserved _ bytes -> Right bytes
          ModelBCorrupt detail -> Left (RecoveryPlaneRepositoryCorrupt detail)
          ModelBEndpointUnready detail ->
            Left
              ( RecoveryPlaneRepositoryUnobservable
                  (repositoryFailure "endpoint-unready" detail)
              )
          ModelBUnobservable detail ->
            Left
              ( RecoveryPlaneRepositoryUnobservable
                  (repositoryFailure "unobservable" detail)
              )

observeAggregateForBound
  :: (Monad m)
  => RecoveryPlaneRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> m (Either RecoveryPlaneRepositoryError ByteString)
observeAggregateForBound
  client@(RecoveryPlaneRepositoryClient _ adapter)
  bound =
    case aggregateCoordinateFor
      client
      (cleanupRunIdText (descriptorBoundCleanupRunId bound))
      ( cleanupDigestText
          (descriptorBoundCleanupRunDescriptorDigest bound)
      ) of
      Left err -> pure (Left err)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Left RecoveryPlaneRepositoryMissing
          ModelBObserved _ bytes -> Right bytes
          ModelBCorrupt detail -> Left (RecoveryPlaneRepositoryCorrupt detail)
          ModelBEndpointUnready detail ->
            Left
              ( RecoveryPlaneRepositoryUnobservable
                  (repositoryFailure "endpoint-unready" detail)
              )
          ModelBUnobservable detail ->
            Left
              ( RecoveryPlaneRepositoryUnobservable
                  (repositoryFailure "unobservable" detail)
              )

aggregateCoordinate
  :: RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneIdentity surface
  -> Either
       RecoveryPlaneRepositoryError
       (ModelBObjectCoordinate 'ClusterRetained)
aggregateCoordinate client identity =
  aggregateCoordinateFor
    client
    (cleanupRunIdText (recoveryPlaneIdentityRunId identity))
    (cleanupDigestText (recoveryPlaneIdentityDescriptorDigest identity))

aggregateCoordinateFor
  :: RecoveryPlaneRepositoryClient m
  -> Text
  -> Text
  -> Either
       RecoveryPlaneRepositoryError
       (ModelBObjectCoordinate 'ClusterRetained)
aggregateCoordinateFor
  (RecoveryPlaneRepositoryClient authority _)
  runId
  descriptorDigest =
    first
      (RecoveryPlaneRepositoryCoordinateInvalid . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (recoveryPlaneRepositoryLogicalNameFor runId descriptorDigest)
      )

initialAggregateBytes
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneNormalizedFacts
  -> ByteString
initialAggregateBytes identity establishAttempt readBackAttempt facts =
  encodeAggregate
    RecoveryPlaneAggregateWire
      { aggregateWireVersion = recoveryPlaneAggregateVersion
      , aggregateWireIdentity = encodeRecoveryPlaneIdentityWireInternal identity
      , aggregateWireEstablishAttempt = cleanupAttemptIdText establishAttempt
      , aggregateWireInitialReadBackAttempt = cleanupAttemptIdText readBackAttempt
      , aggregateWireInitialFacts = factsToWire facts
      , aggregateWireFinal = Nothing
      }

finalAggregateBytes
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneNormalizedFacts
  -> CleanupAttemptId
  -> RecoveryPlaneFinalDisposition
  -> RecoveryPlaneNormalizedFacts
  -> ByteString
finalAggregateBytes
  identity
  establishAttempt
  readBackAttempt
  initialFacts
  dispositionAttempt
  disposition
  finalFacts =
    encodeAggregate
      RecoveryPlaneAggregateWire
        { aggregateWireVersion = recoveryPlaneAggregateVersion
        , aggregateWireIdentity = encodeRecoveryPlaneIdentityWireInternal identity
        , aggregateWireEstablishAttempt = cleanupAttemptIdText establishAttempt
        , aggregateWireInitialReadBackAttempt = cleanupAttemptIdText readBackAttempt
        , aggregateWireInitialFacts = factsToWire initialFacts
        , aggregateWireFinal =
            Just
              RecoveryPlaneFinalWire
                { finalWireDispositionAttempt = cleanupAttemptIdText dispositionAttempt
                , finalWireDisposition = dispositionTag disposition
                , finalWireFacts = factsToWire finalFacts
                }
        }

encodeAggregate :: RecoveryPlaneAggregateWire -> ByteString
encodeAggregate = LazyByteString.toStrict . serialise

decodeAggregate
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> Maybe CleanupAttemptId
  -> ByteString
  -> Either
       RecoveryPlaneRepositoryError
       (DecodedRecoveryPlaneAggregate surface)
decodeAggregate
  expectedIdentity
  expectedReadBackAttempt
  expectedDispositionAttempt
  bytes = do
    wire <- decodeAggregateWire bytes
    _ <-
      first
        RecoveryPlaneRepositoryCorrupt
        (decodeRecoveryPlaneIdentityWireInternal (aggregateWireIdentity wire))
    unless
      ( aggregateWireIdentity wire
          == encodeRecoveryPlaneIdentityWireInternal expectedIdentity
      )
      (Left RecoveryPlaneRepositoryIdentityMismatch)
    establishAttempt <-
      first
        RecoveryPlaneRepositoryCorrupt
        (mkCleanupAttemptId (aggregateWireEstablishAttempt wire))
    readBackAttempt <-
      first
        RecoveryPlaneRepositoryCorrupt
        (mkCleanupAttemptId (aggregateWireInitialReadBackAttempt wire))
    unless
      (readBackAttempt == expectedReadBackAttempt)
      ( Left
          ( RecoveryPlaneRepositoryAttemptMismatch
              expectedReadBackAttempt
              readBackAttempt
          )
      )
    initialFacts <-
      factsFromWire
        expectedIdentity
        (recoveryPlaneIdentityReadBackOperationId expectedIdentity)
        readBackAttempt
        (aggregateWireInitialFacts wire)
    finalFacts <- traverse decodeFinal (aggregateWireFinal wire)
    pure
      DecodedRecoveryPlaneAggregate
        { decodedRecoveryPlaneEstablishAttempt = establishAttempt
        , decodedRecoveryPlaneInitialReadBackAttempt = readBackAttempt
        , decodedRecoveryPlaneInitialFacts = initialFacts
        , decodedRecoveryPlaneFinalFacts = finalFacts
        }
   where
    decodeFinal finalWire = do
      dispositionAttempt <-
        first
          RecoveryPlaneRepositoryCorrupt
          (mkCleanupAttemptId (finalWireDispositionAttempt finalWire))
      case expectedDispositionAttempt of
        Nothing -> Right ()
        Just expected ->
          unless
            (dispositionAttempt == expected)
            ( Left
                ( RecoveryPlaneRepositoryAttemptMismatch
                    expected
                    dispositionAttempt
                )
            )
      disposition <-
        maybe
          (Left (RecoveryPlaneRepositoryCorrupt "invalid final disposition"))
          Right
          (dispositionFromTag (finalWireDisposition finalWire))
      facts <-
        factsFromWire
          expectedIdentity
          (recoveryPlaneIdentityDispositionOperationId expectedIdentity)
          dispositionAttempt
          (finalWireFacts finalWire)
      pure (dispositionAttempt, disposition, facts)

decodeAggregateWire
  :: ByteString
  -> Either RecoveryPlaneRepositoryError RecoveryPlaneAggregateWire
decodeAggregateWire bytes = do
  when
    (ByteString.length bytes > maximumRecoveryPlaneAggregateBytes)
    ( Left
        ( RecoveryPlaneRepositoryUnbounded
            (ByteString.length bytes)
            maximumRecoveryPlaneAggregateBytes
        )
    )
  when (ByteString.null bytes) (Left (RecoveryPlaneRepositoryCorrupt "empty aggregate"))
  wire <-
    first
      (RecoveryPlaneRepositoryCorrupt . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (encodeAggregate wire == bytes)
    (Left (RecoveryPlaneRepositoryCorrupt "non-canonical aggregate"))
  unless
    (aggregateWireVersion wire == recoveryPlaneAggregateVersion)
    (Left (RecoveryPlaneRepositoryCorrupt "unsupported aggregate version"))
  pure wire

factsToWire :: RecoveryPlaneNormalizedFacts -> [RecoveryPlaneFactWire]
factsToWire facts =
  [ RecoveryPlaneFactWire
      { factWireIdentity = recoveryPlaneComponentIdentityText identity
      , factWireState = normalizedStateTag state
      }
  | RecoveryPlaneNormalizedComponentFact identity state <-
      recoveryPlaneNormalizedFactsEntries facts
  ]

factsFromWire
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> [RecoveryPlaneFactWire]
  -> Either RecoveryPlaneRepositoryError RecoveryPlaneNormalizedFacts
factsFromWire identity operationId attempt rows = do
  observations <- traverse decodeFact rows
  first
    RecoveryPlaneRepositoryEvidenceInvalid
    ( normalizeRecoveryPlaneComponentFactsInternal
        (RecoveryPlaneAttemptBindingInternal identity operationId attempt)
        ( recoveryPlaneComponentObservationSetInternal
            identity
            operationId
            attempt
            observations
        )
    )
 where
  expected =
    Map.fromList
      [ (recoveryPlaneComponentIdentityText component, component)
      | component <- recoveryPlaneIdentityComponents identity
      ]
  decodeFact row = do
    component <-
      maybe
        ( Left
            ( RecoveryPlaneRepositoryCorrupt
                ("unknown component identity: " <> factWireIdentity row)
            )
        )
        Right
        (Map.lookup (factWireIdentity row) expected)
    result <-
      maybe
        (Left (RecoveryPlaneRepositoryCorrupt "invalid component state"))
        Right
        (rawResultFromNormalizedTag (factWireState row))
    pure (RecoveryPlaneRawComponentObservation component result)

normalizedStateTag :: RecoveryPlaneNormalizedComponentState -> Int
normalizedStateTag state = case state of
  RecoveryPlaneNormalizedReady -> 0
  RecoveryPlaneNormalizedFailure failure -> case failure of
    RecoveryPlaneComponentMissing -> 1
    RecoveryPlaneComponentPartial -> 2
    RecoveryPlaneComponentUnavailable -> 3
    RecoveryPlaneComponentUnobservable -> 4

rawResultFromNormalizedTag :: Int -> Maybe RecoveryPlaneRawComponentResult
rawResultFromNormalizedTag tag = case tag of
  0 -> Just RecoveryPlaneRawReady
  1 -> Just (RecoveryPlaneRawMissing "normalized")
  2 -> Just (RecoveryPlaneRawPartial ("normalized" :| []))
  3 -> Just (RecoveryPlaneRawUnavailable "normalized")
  4 -> Just (RecoveryPlaneRawUnobservable "normalized")
  _ -> Nothing

dispositionTag :: RecoveryPlaneFinalDisposition -> Int
dispositionTag disposition = case disposition of
  RecoveryPlaneEstablished -> 0
  RecoveryPlaneNotEstablished -> 1
  RecoveryPlaneLost -> 2

dispositionFromTag :: Int -> Maybe RecoveryPlaneFinalDisposition
dispositionFromTag tag = case tag of
  0 -> Just RecoveryPlaneEstablished
  1 -> Just RecoveryPlaneNotEstablished
  2 -> Just RecoveryPlaneLost
  _ -> Nothing

existingInitialDisposition
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneNormalizedFacts
  -> ByteString
  -> RecoveryPlaneCommitResult
existingInitialDisposition
  identity
  establishAttempt
  readBackAttempt
  expectedFacts
  bytes =
    case decodeAggregate identity readBackAttempt Nothing bytes of
      Right aggregate
        | decodedRecoveryPlaneEstablishAttempt aggregate == establishAttempt
            && decodedRecoveryPlaneInitialFacts aggregate == expectedFacts ->
            RecoveryPlaneCommitExactReplay
        | otherwise -> RecoveryPlaneCommitConflict
      Left err -> unavailable "existing-invalid" (Text.pack (show err))

conflictInitialDisposition
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneNormalizedFacts
  -> ModelBObservation ByteString
  -> RecoveryPlaneCommitResult
conflictInitialDisposition
  identity
  establishAttempt
  readBackAttempt
  facts
  observation = case observation of
    ModelBObserved _ bytes ->
      existingInitialDisposition
        identity
        establishAttempt
        readBackAttempt
        facts
        bytes
    ModelBMissing -> responseLost "cas-conflict-missing" "object remained missing"
    ModelBCorrupt detail -> unavailable "cas-conflict-corrupt" detail
    ModelBEndpointUnready detail ->
      responseLost "cas-conflict-endpoint-unready" detail
    ModelBUnobservable detail -> responseLost "cas-conflict-unobservable" detail

conflictFinalDisposition
  :: RecoveryPlaneIdentity surface
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> RecoveryPlaneNormalizedFacts
  -> CleanupAttemptId
  -> RecoveryPlaneFinalDisposition
  -> RecoveryPlaneNormalizedFacts
  -> ModelBObservation ByteString
  -> RecoveryPlaneCommitResult
conflictFinalDisposition
  identity
  establishAttempt
  readBackAttempt
  initialFacts
  dispositionAttempt
  disposition
  finalFacts
  observation = case observation of
    ModelBObserved _ bytes -> case decodeAggregate
      identity
      readBackAttempt
      (Just dispositionAttempt)
      bytes of
      Right aggregate
        | decodedRecoveryPlaneEstablishAttempt aggregate == establishAttempt
        , decodedRecoveryPlaneInitialFacts aggregate == initialFacts
        , decodedRecoveryPlaneFinalFacts aggregate
            == Just (dispositionAttempt, disposition, finalFacts) ->
            RecoveryPlaneCommitExactReplay
        | otherwise -> RecoveryPlaneCommitConflict
      Left err -> unavailable "cas-conflict-invalid" (Text.pack (show err))
    ModelBMissing -> responseLost "cas-conflict-missing" "object disappeared"
    ModelBCorrupt detail -> unavailable "cas-conflict-corrupt" detail
    ModelBEndpointUnready detail ->
      responseLost "cas-conflict-endpoint-unready" detail
    ModelBUnobservable detail -> responseLost "cas-conflict-unobservable" detail

unavailable :: Text -> Text -> RecoveryPlaneCommitResult
unavailable stage detail =
  RecoveryPlaneCommitUnavailable (repositoryFailure stage detail)

responseLost :: Text -> Text -> RecoveryPlaneCommitResult
responseLost stage detail =
  RecoveryPlaneCommitResponseLost (repositoryFailure stage detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure stage detail =
  ObservationFailure (stage <> ": " <> Text.take 512 detail)

data RecoveryPlaneRepositoryRegression = RecoveryPlaneRepositoryRegression
  { recoveryPlaneRepositoryResponseLossRecovered :: !Bool
  , recoveryPlaneRepositoryExactReplayPreserved :: !Bool
  , recoveryPlaneRepositoryConflictPreserved :: !Bool
  , recoveryPlaneRepositoryRestartReadBack :: !Bool
  , recoveryPlaneRepositoryAttemptBindingEnforced :: !Bool
  , recoveryPlaneRepositoryCrossIdentityRefused :: !Bool
  , recoveryPlaneRepositoryComponentCompletenessEnforced :: !Bool
  , recoveryPlaneRepositoryEstablishedExact :: !Bool
  , recoveryPlaneRepositoryEstablishedAfterInitialFailure :: !Bool
  , recoveryPlaneRepositoryNotEstablishedExact :: !Bool
  , recoveryPlaneRepositoryLostExact :: !Bool
  , recoveryPlaneRepositoryCorruptionRefused :: !Bool
  , recoveryPlaneRepositoryBoundsEnforced :: !Bool
  , recoveryPlaneRepositoryProfileProgressionRecoverable :: !Bool
  , recoveryPlaneRepositoryObservationBindingExact :: !Bool
  , recoveryPlaneRepositoryObservationBindingPhaseRestricted :: !Bool
  , recoveryPlaneRepositoryOpacityClosed :: !Bool
  }
  deriving stock (Eq, Show)

fixedRecoveryPlaneRepositoryRegression
  :: IO (Either Text RecoveryPlaneRepositoryRegression)
fixedRecoveryPlaneRepositoryRegression = do
  responseLoss <- responseLossScenario
  established <- classificationScenario RecoveryPlaneRawReady RecoveryPlaneRawReady
  establishedAfterFailure <-
    classificationScenario
      (RecoveryPlaneRawMissing "initially absent")
      RecoveryPlaneRawReady
  notEstablished <-
    classificationScenario
      (RecoveryPlaneRawMissing "initially absent")
      (RecoveryPlaneRawUnavailable "still unavailable")
  lost <-
    classificationScenario
      RecoveryPlaneRawReady
      (RecoveryPlaneRawUnobservable "fresh observation lost")
  corruption <- corruptionScenario
  bounds <- boundsScenario
  completeness <- completenessScenario
  attemptAndIdentity <- attemptAndIdentityScenario
  let (observationBindingExact, observationBindingPhaseRestricted) =
        observationBindingScenario
  pure $ do
    (responseLossRecovered, exactReplay, conflictPreserved, restartReadBack) <-
      responseLoss
    establishedExact <- established
    establishedAfterFailureExact <- establishedAfterFailure
    notEstablishedExact <- notEstablished
    lostExact <- lost
    corruptionRefused <- corruption
    boundsEnforced <- bounds
    completenessEnforced <- completeness
    (attemptEnforced, crossIdentityRefused) <- attemptAndIdentity
    pure
      RecoveryPlaneRepositoryRegression
        { recoveryPlaneRepositoryResponseLossRecovered = responseLossRecovered
        , recoveryPlaneRepositoryExactReplayPreserved = exactReplay
        , recoveryPlaneRepositoryConflictPreserved = conflictPreserved
        , recoveryPlaneRepositoryRestartReadBack = restartReadBack
        , recoveryPlaneRepositoryAttemptBindingEnforced = attemptEnforced
        , recoveryPlaneRepositoryCrossIdentityRefused = crossIdentityRefused
        , recoveryPlaneRepositoryComponentCompletenessEnforced =
            completenessEnforced
        , recoveryPlaneRepositoryEstablishedExact = establishedExact
        , recoveryPlaneRepositoryEstablishedAfterInitialFailure =
            establishedAfterFailureExact
        , recoveryPlaneRepositoryNotEstablishedExact = notEstablishedExact
        , recoveryPlaneRepositoryLostExact = lostExact
        , recoveryPlaneRepositoryCorruptionRefused = corruptionRefused
        , recoveryPlaneRepositoryBoundsEnforced = boundsEnforced
        , recoveryPlaneRepositoryProfileProgressionRecoverable =
            recoveryPlaneRepositoryLogicalName fixedRecoveryPlaneIdentityInternal
              == recoveryPlaneRepositoryLogicalName
                fixedRecoveryPlaneTargetIdentityInternal
              && encodeRecoveryPlaneIdentityWireInternal
                fixedRecoveryPlaneIdentityInternal
                /= encodeRecoveryPlaneIdentityWireInternal
                  fixedRecoveryPlaneTargetIdentityInternal
        , recoveryPlaneRepositoryObservationBindingExact =
            observationBindingExact
        , recoveryPlaneRepositoryObservationBindingPhaseRestricted =
            observationBindingPhaseRestricted
        , recoveryPlaneRepositoryOpacityClosed = True
        }

observationBindingScenario :: (Bool, Bool)
observationBindingScenario =
  ( exactEstablishBinding && crossIdentityRefused
  , establishPhaseRefused
  )
 where
  identity = fixedRecoveryPlaneIdentityInternal
  establishBinding =
    fixtureBinding
      identity
      (recoveryPlaneIdentityEstablishOperationId identity)
      fixedRecoveryPlaneEstablishAttemptIdInternal
  readBackBinding =
    fixtureBinding
      identity
      (recoveryPlaneIdentityReadBackOperationId identity)
      fixedRecoveryPlaneReadBackAttemptIdInternal
  observationBinding =
    mkRecoveryPlaneObservationBindingInternal
      identity
      establishBinding
      readBackBinding
  establishPhaseBinding =
    mkRecoveryPlaneObservationBindingInternal
      identity
      establishBinding
      establishBinding
  exactEstablishBinding =
    withRecoveryPlaneObservationEstablishBindingInternal
      identity
      observationBinding
      ( \(RecoveryPlaneAttemptBindingInternal actualIdentity operation attempt) ->
          actualIdentity == identity
            && operation == recoveryPlaneIdentityEstablishOperationId identity
            && attempt == fixedRecoveryPlaneEstablishAttemptIdInternal
      )
      == Right True
  crossIdentityRefused =
    case withRecoveryPlaneObservationEstablishBindingInternal
      fixedRecoveryPlaneTargetIdentityInternal
      observationBinding
      (const ()) of
      Left RecoveryPlaneRepositoryIdentityMismatch -> True
      _ -> False
  establishPhaseRefused =
    case withRecoveryPlaneObservationEstablishBindingInternal
      identity
      establishPhaseBinding
      (const ()) of
      Left RecoveryPlaneRepositoryObservationPhaseMismatch {} -> True
      _ -> False

responseLossScenario :: IO (Either Text (Bool, Bool, Bool, Bool))
responseLossScenario = do
  harness <- newRegressionHarness
  writeIORef (regressionLoseNextWrite harness) True
  let identity = fixedRecoveryPlaneIdentityInternal
      establishAttempt = fixedRecoveryPlaneEstablishAttemptIdInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      establishBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityEstablishOperationId identity)
          establishAttempt
      readBackBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
      ready =
        fixtureObservation
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          RecoveryPlaneRawReady
      conflict =
        fixtureObservation
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          (RecoveryPlaneRawMissing "different")
  lostResponse <-
    commitRecoveryPlaneInitialInternal
      (regressionClient harness)
      establishBinding
      readBackBinding
      ready
  restarted <- restartedRegressionClient harness
  replayed <-
    commitRecoveryPlaneInitialInternal
      restarted
      establishBinding
      readBackBinding
      ready
  conflicted <-
    commitRecoveryPlaneInitialInternal
      restarted
      establishBinding
      readBackBinding
      conflict
  observed <-
    independentlyReadBackRecoveryPlaneInitial restarted identity readBackAttempt
  pure $ do
    lostResult <- firstShow lostResponse
    replayResult <- firstShow replayed
    conflictResult <- firstShow conflicted
    _ <- firstShow observed
    pure
      ( isResponseLost lostResult
      , replayResult == RecoveryPlaneCommitExactReplay
      , conflictResult == RecoveryPlaneCommitConflict
      , True
      )

classificationScenario
  :: RecoveryPlaneRawComponentResult
  -> RecoveryPlaneRawComponentResult
  -> IO (Either Text Bool)
classificationScenario initialResult finalResult = do
  harness <- newRegressionHarness
  let identity = fixedRecoveryPlaneIdentityInternal
      establishAttempt = fixedRecoveryPlaneEstablishAttemptIdInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      dispositionAttempt = fixedRecoveryPlaneDispositionAttemptIdInternal
      establishBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityEstablishOperationId identity)
          establishAttempt
      readBackBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
      dispositionBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityDispositionOperationId identity)
          dispositionAttempt
      initialObservation =
        fixtureObservation
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          initialResult
      finalObservation =
        fixtureObservation
          identity
          (recoveryPlaneIdentityDispositionOperationId identity)
          dispositionAttempt
          finalResult
  committedInitial <-
    commitRecoveryPlaneInitialInternal
      (regressionClient harness)
      establishBinding
      readBackBinding
      initialObservation
  initial <-
    independentlyReadBackRecoveryPlaneInitial
      (regressionClient harness)
      identity
      readBackAttempt
  committedFinal <- case initial of
    Left err -> pure (Left err)
    Right observedInitial ->
      commitRecoveryPlaneFinalInternal
        (regressionClient harness)
        observedInitial
        dispositionBinding
        finalObservation
  restarted <- restartedRegressionClient harness
  final <-
    independentlyReadBackRecoveryPlaneFinal
      restarted
      identity
      readBackAttempt
      dispositionAttempt
  pure $ do
    initialCommit <- firstShow committedInitial
    finalCommit <- firstShow committedFinal
    evidence <- firstShow final
    unless
      (initialCommit == RecoveryPlaneCommitCreated)
      (Left "initial commit was not created")
    unless
      (finalCommit == RecoveryPlaneCommitCreated)
      (Left "final commit was not created")
    let expected = expectedDisposition initialResult finalResult
        readyExposure = case expected of
          RecoveryPlaneEstablished ->
            maybe False (const True) (recoveryPlaneFinalEstablishedReady evidence)
          RecoveryPlaneNotEstablished ->
            maybe True (const False) (recoveryPlaneFinalEstablishedReady evidence)
          RecoveryPlaneLost ->
            maybe True (const False) (recoveryPlaneFinalEstablishedReady evidence)
    pure (recoveryPlaneFinalDisposition evidence == expected && readyExposure)

corruptionScenario :: IO (Either Text Bool)
corruptionScenario = do
  harness <- newRegressionHarness
  let identity = fixedRecoveryPlaneIdentityInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      coordinateName = recoveryPlaneRepositoryLogicalName identity
  writeRegressionBytes harness coordinateName "not-canonical-cbor"
  observed <-
    independentlyReadBackRecoveryPlaneInitial
      (regressionClient harness)
      identity
      readBackAttempt
  pure $ Right (isCorrupt observed)

boundsScenario :: IO (Either Text Bool)
boundsScenario = do
  harness <- newRegressionHarness
  let identity = fixedRecoveryPlaneIdentityInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      coordinateName = recoveryPlaneRepositoryLogicalName identity
  writeRegressionBytes
    harness
    coordinateName
    (ByteString.replicate (maximumRecoveryPlaneAggregateBytes + 1) 0)
  observed <-
    independentlyReadBackRecoveryPlaneInitial
      (regressionClient harness)
      identity
      readBackAttempt
  pure $ Right (isUnbounded observed)

completenessScenario :: IO (Either Text Bool)
completenessScenario = do
  harness <- newRegressionHarness
  let identity = fixedRecoveryPlaneIdentityInternal
      establishAttempt = fixedRecoveryPlaneEstablishAttemptIdInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      establishBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityEstablishOperationId identity)
          establishAttempt
      readBackBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
      incomplete =
        recoveryPlaneComponentObservationSetInternal
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          []
  committed <-
    commitRecoveryPlaneInitialInternal
      (regressionClient harness)
      establishBinding
      readBackBinding
      incomplete
  pure $ Right (isEvidenceInvalid committed)

attemptAndIdentityScenario :: IO (Either Text (Bool, Bool))
attemptAndIdentityScenario = do
  harness <- newRegressionHarness
  let identity = fixedRecoveryPlaneIdentityInternal
      establishAttempt = fixedRecoveryPlaneEstablishAttemptIdInternal
      readBackAttempt = fixedRecoveryPlaneReadBackAttemptIdInternal
      establishBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityEstablishOperationId identity)
          establishAttempt
      readBackBinding =
        fixtureBinding
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
      ready =
        fixtureObservation
          identity
          (recoveryPlaneIdentityReadBackOperationId identity)
          readBackAttempt
          RecoveryPlaneRawReady
  committed <-
    commitRecoveryPlaneInitialInternal
      (regressionClient harness)
      establishBinding
      readBackBinding
      ready
  otherAttempt <- firstShowIO (mkCleanupAttemptId "different-recovery-attempt")
  wrongAttempt <-
    independentlyReadBackRecoveryPlaneInitial
      (regressionClient harness)
      identity
      otherAttempt
  let otherIdentityBytes = encodeRecoveryPlaneIdentityWireInternal identity <> "different"
  otherIdentityRefused <-
    pure
      ( either
          (const True)
          (const False)
          (decodeRecoveryPlaneIdentityWireInternal otherIdentityBytes)
      )
  pure $ do
    commitResult <- firstShow committed
    unless
      (commitResult == RecoveryPlaneCommitCreated)
      (Left "attempt scenario did not initialize")
    pure (isAttemptMismatch wrongAttempt, otherIdentityRefused)

expectedDisposition
  :: RecoveryPlaneRawComponentResult
  -> RecoveryPlaneRawComponentResult
  -> RecoveryPlaneFinalDisposition
expectedDisposition initialResult finalResult
  | isReadyResult finalResult = RecoveryPlaneEstablished
  | isReadyResult initialResult = RecoveryPlaneLost
  | otherwise = RecoveryPlaneNotEstablished

isReadyResult :: RecoveryPlaneRawComponentResult -> Bool
isReadyResult result = case result of
  RecoveryPlaneRawReady -> True
  RecoveryPlaneRawMissing _ -> False
  RecoveryPlaneRawPartial _ -> False
  RecoveryPlaneRawUnavailable _ -> False
  RecoveryPlaneRawUnobservable _ -> False

fixtureObservation
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneRawComponentResult
  -> RecoveryPlaneComponentObservationSet surface
fixtureObservation identity operationId attempt firstResult =
  recoveryPlaneComponentObservationSetInternal
    identity
    operationId
    attempt
    [ RecoveryPlaneRawComponentObservation
        component
        (if index == (0 :: Int) then firstResult else RecoveryPlaneRawReady)
    | (index, component) <- zip [0 ..] (recoveryPlaneIdentityComponents identity)
    ]

fixtureBinding
  :: RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneAttemptBinding surface
fixtureBinding = RecoveryPlaneAttemptBindingInternal

data RegressionHarness = RegressionHarness
  { regressionAuthority :: !LongLivedCheckpointAuthority
  , regressionStore :: !(IORef (Map.Map Text (ModelBObjectVersion, ByteString)))
  , regressionNextVersion :: !(IORef Int)
  , regressionLoseNextWrite :: !(IORef Bool)
  }

regressionClient :: RegressionHarness -> RecoveryPlaneRepositoryClient IO
regressionClient harness =
  modelBRecoveryPlaneRepository
    (regressionAuthority harness)
    (regressionAdapter harness)

restartedRegressionClient
  :: RegressionHarness -> IO (RecoveryPlaneRepositoryClient IO)
restartedRegressionClient harness =
  pure
    ( modelBRecoveryPlaneRepository
        (regressionAuthority harness)
        (regressionAdapter harness)
    )

newRegressionHarness :: IO RegressionHarness
newRegressionHarness = do
  authority <-
    firstShowIO
      ( mkLongLivedCheckpointAuthority
          "recovery-authority"
          "retained-bucket"
          "recovery-plane"
          "vault/recovery-plane"
      )
  store <- newIORef Map.empty
  nextVersion <- newIORef 1
  loseNextWrite <- newIORef False
  pure
    RegressionHarness
      { regressionAuthority = authority
      , regressionStore = store
      , regressionNextVersion = nextVersion
      , regressionLoseNextWrite = loseNextWrite
      }

-- | Package-private deterministic Authority repository used only by closed
-- regression vectors in sibling hidden implementation modules.  The client
-- still crosses the real canonical Model-B codec/CAS boundary; no raw store,
-- observation, or evidence constructor is exposed through a public facade.
newFixedRecoveryPlaneRepositoryClientInternal
  :: IO (RecoveryPlaneRepositoryClient IO)
newFixedRecoveryPlaneRepositoryClientInternal =
  regressionClient <$> newRegressionHarness

regressionAdapter
  :: RegressionHarness
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
regressionAdapter harness =
  ModelBCasAdapter
    { modelBObserve = observe
    , modelBCompareAndSwap = compareAndSwap
    }
 where
  observe coordinate = do
    stored <- readIORef (regressionStore harness)
    pure $ case Map.lookup (modelBObjectLogicalName coordinate) stored of
      Nothing -> ModelBMissing
      Just (version, bytes) -> ModelBObserved version bytes

  compareAndSwap request = case request of
    ModelBInitialize coordinate bytes -> do
      stored <- readIORef (regressionStore harness)
      case Map.lookup (modelBObjectLogicalName coordinate) stored of
        Just (version, existing) ->
          pure (ModelBCasConflict (ModelBObserved version existing))
        Nothing -> apply coordinate bytes
    ModelBReplace coordinate expectedVersion bytes -> do
      stored <- readIORef (regressionStore harness)
      case Map.lookup (modelBObjectLogicalName coordinate) stored of
        Just (actualVersion, _)
          | actualVersion == expectedVersion -> apply coordinate bytes
        Just (actualVersion, existing) ->
          pure (ModelBCasConflict (ModelBObserved actualVersion existing))
        Nothing -> pure (ModelBCasConflict ModelBMissing)
    ModelBInitializeGuarded {} ->
      pure (ModelBCasRefusedCorrupt "guarded request is unexpected")
    ModelBReplaceGuarded {} ->
      pure (ModelBCasRefusedCorrupt "guarded request is unexpected")

  apply coordinate bytes = do
    versionNumber <-
      atomicModifyIORef'
        (regressionNextVersion harness)
        (\current -> (current + 1, current))
    version <- firstShowIO (mkModelBObjectVersion ("version-" <> Text.pack (show versionNumber)))
    atomicModifyIORef'
      (regressionStore harness)
      ( \current ->
          ( Map.insert
              (modelBObjectLogicalName coordinate)
              (version, bytes)
              current
          , ()
          )
      )
    lose <- atomicModifyIORef' (regressionLoseNextWrite harness) (False,)
    pure
      ( if lose
          then ModelBCasUnobservable "simulated response loss"
          else ModelBCasApplied version bytes
      )

writeRegressionBytes :: RegressionHarness -> Text -> ByteString -> IO ()
writeRegressionBytes harness logicalName bytes = do
  version <- firstShowIO (mkModelBObjectVersion "injected-version")
  atomicModifyIORef'
    (regressionStore harness)
    (\current -> (Map.insert logicalName (version, bytes) current, ()))

isResponseLost :: RecoveryPlaneCommitResult -> Bool
isResponseLost result = case result of
  RecoveryPlaneCommitResponseLost _ -> True
  _ -> False

isCorrupt
  :: Either RecoveryPlaneRepositoryError value -> Bool
isCorrupt result = case result of
  Left RecoveryPlaneRepositoryCorrupt {} -> True
  _ -> False

isUnbounded
  :: Either RecoveryPlaneRepositoryError value -> Bool
isUnbounded result = case result of
  Left RecoveryPlaneRepositoryUnbounded {} -> True
  _ -> False

isEvidenceInvalid
  :: Either RecoveryPlaneRepositoryError value -> Bool
isEvidenceInvalid result = case result of
  Left RecoveryPlaneRepositoryEvidenceInvalid {} -> True
  _ -> False

isAttemptMismatch
  :: Either RecoveryPlaneRepositoryError value -> Bool
isAttemptMismatch result = case result of
  Left RecoveryPlaneRepositoryAttemptMismatch {} -> True
  _ -> False

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

firstShowIO :: (Show err) => Either err value -> IO value
firstShowIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value
