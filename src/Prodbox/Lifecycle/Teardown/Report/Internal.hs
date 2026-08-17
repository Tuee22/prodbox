{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private descriptor-bound teardown report classification.  Raw
-- compiled programs and reports enter only through the opaque authenticated
-- CleanupRun handle.  The pure fold remains here so tests can exercise fixed,
-- non-authorizing diagnostics without exporting a proof minter.
module Prodbox.Lifecycle.Teardown.Report.Internal
  ( DesiredAbsenceRecoveryInput (..)
  , TeardownFailure (..)
  , SurfaceReadBackEvidence
  , readBackEvidenceSurface
  , readBackEvidenceRunId
  , readBackEvidenceGraphDigest
  , readBackEvidenceRecoveryPlane
  , SurfaceCompletionEvidence
  , completionEvidenceSurface
  , completionEvidenceRunId
  , completionEvidenceGraphDigest
  , completeCascadeDesiredAbsence
  , SurfaceIncompleteEvidence
  , incompleteEvidenceSurface
  , incompleteEvidenceRunId
  , incompleteEvidenceGraphDigest
  , incompleteEvidenceRecoveryPlane
  , incompleteEvidenceRecoveryPlaneDisposition
  , incompleteEvidenceFailures
  , DesiredAbsenceReportClassification (..)
  , DesiredAbsenceReportError (..)
  , classifyDesiredAbsenceReport
  , classifyDesiredAbsenceReportInternal
  , DesiredAbsenceReportRegression
  , fixedDesiredAbsenceReportRegression
  , desiredAbsenceRegressionEstablishedCompletes
  , desiredAbsenceRegressionNotEstablishedRefused
  , desiredAbsenceRegressionLostRefused
  , desiredAbsenceRegressionIncompleteRetainsFinal
  , desiredAbsenceRegressionUnavailableRefused
  , desiredAbsenceRegressionExactBindingAccepted
  , desiredAbsenceRegressionCrossBindingRefused
  , desiredAbsenceRegressionAttemptBindingRefused
  , desiredAbsenceRegressionReportBindingRefused
  , desiredAbsenceRegressionLocalAndTotalDistinct
  )
where

import Data.Bifunctor (first)
import Data.Either (isLeft, isRight)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  , descriptorBoundCleanupRunReport
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupGraph
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupPrimaryOutcome (..)
  , CleanupRunError
  , CleanupRunId
  , CleanupRunReport (..)
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeCompleteEvidence
  , cascadeCompleteGraphDigest
  , cascadeCompleteRunId
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , cleanupSurfaceFromWitness
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness (..)
  , TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (..)
  , RecoveryPlaneFinalEvidence
  , recoveryPlaneFinalDisposition
  , recoveryPlaneFinalDispositionAttemptId
  , recoveryPlaneFinalEstablishAttemptId
  , recoveryPlaneFinalIdentity
  , recoveryPlaneFinalInitialReadBackAttemptId
  , recoveryPlaneIdentityDescriptorDigest
  , recoveryPlaneIdentityDispositionOperationId
  , recoveryPlaneIdentityEstablishOperationId
  , recoveryPlaneIdentityGraphDigest
  , recoveryPlaneIdentityObservationScope
  , recoveryPlaneIdentityReadBackOperationId
  , recoveryPlaneIdentityRunId
  , recoveryPlaneIdentitySurface
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal qualified as RecoveryPlaneInternal
import Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal
  ( deriveOrdinaryTeardownRecoveryRequirementInternal
  )

-- | Exact surface evidence required before a report can be classified.
-- Ordinary surfaces carry the opaque final RecoveryPlane proof, or an
-- explicit unavailable marker which is always refused.  Local-only and total
-- decommission are distinct constructors because neither owns that plane.
data DesiredAbsenceRecoveryInput surface where
  OrdinaryDesiredAbsenceRecovery
    :: !(RecoverySurfaceWitness surface)
    -> !(Maybe (RecoveryPlaneFinalEvidence surface))
    -> DesiredAbsenceRecoveryInput surface
  LocalOnlyDesiredAbsenceRecovery
    :: DesiredAbsenceRecoveryInput 'LocalOnly
  TotalDecommissionDesiredAbsenceRecovery
    :: DesiredAbsenceRecoveryInput 'TotalDecommission

data TeardownFailure
  = TeardownNodeFailed !CleanupNodeId !Text
  | TeardownEffectUnconfirmed !CleanupNodeId !Text
  | TeardownNodeBlocked !CleanupNodeId ![CleanupNodeId]
  | TeardownNodePending !CleanupNodeId
  | TeardownNodeRunning !CleanupNodeId
  | TeardownMandatoryReadBackMissing !Text
  deriving stock (Eq, Show)

-- | The constructor is private.  Ordinary evidence retains the exact final
-- RecoveryPlane proof that admitted this classification.
data SurfaceReadBackEvidence surface = SurfaceReadBackEvidence
  { internalReadBackEvidenceSurface :: !CleanupSurface
  , internalReadBackEvidenceRunId :: !CleanupRunId
  , internalReadBackEvidenceGraphDigest :: !CleanupDigest
  , internalReadBackEvidenceRecoveryPlane
      :: !(Maybe (RecoveryPlaneFinalEvidence surface))
  }

readBackEvidenceSurface :: SurfaceReadBackEvidence surface -> CleanupSurface
readBackEvidenceSurface = internalReadBackEvidenceSurface

readBackEvidenceRunId :: SurfaceReadBackEvidence surface -> CleanupRunId
readBackEvidenceRunId = internalReadBackEvidenceRunId

readBackEvidenceGraphDigest
  :: SurfaceReadBackEvidence surface -> CleanupDigest
readBackEvidenceGraphDigest = internalReadBackEvidenceGraphDigest

readBackEvidenceRecoveryPlane
  :: SurfaceReadBackEvidence surface
  -> Maybe (RecoveryPlaneFinalEvidence surface)
readBackEvidenceRecoveryPlane = internalReadBackEvidenceRecoveryPlane

data SurfaceCompletionEvidence surface where
  CascadeCompletionEvidence
    :: !CascadeCompleteEvidence
    -> SurfaceCompletionEvidence 'Cascade

completionEvidenceSurface :: SurfaceCompletionEvidence surface -> CleanupSurface
completionEvidenceSurface evidence = case evidence of
  CascadeCompletionEvidence {} -> Cascade

completionEvidenceRunId :: SurfaceCompletionEvidence surface -> CleanupRunId
completionEvidenceRunId evidence = case evidence of
  CascadeCompletionEvidence complete -> cascadeCompleteRunId complete

completionEvidenceGraphDigest
  :: SurfaceCompletionEvidence surface -> CleanupDigest
completionEvidenceGraphDigest evidence = case evidence of
  CascadeCompletionEvidence complete -> cascadeCompleteGraphDigest complete

completeCascadeDesiredAbsence
  :: SurfaceReadBackEvidence 'Cascade
  -> CascadeCompleteEvidence
  -> Either DesiredAbsenceReportError (SurfaceCompletionEvidence 'Cascade)
completeCascadeDesiredAbsence readBacks complete
  | readBackEvidenceRunId readBacks /= cascadeCompleteRunId complete =
      Left
        ( DesiredAbsenceCompletionRunMismatch
            (readBackEvidenceRunId readBacks)
            (cascadeCompleteRunId complete)
        )
  | readBackEvidenceGraphDigest readBacks /= cascadeCompleteGraphDigest complete =
      Left
        ( DesiredAbsenceCompletionGraphMismatch
            (readBackEvidenceGraphDigest readBacks)
            (cascadeCompleteGraphDigest complete)
        )
  | otherwise = Right (CascadeCompletionEvidence complete)

data SurfaceIncompleteEvidence surface = SurfaceIncompleteEvidence
  { internalIncompleteEvidenceSurface :: !CleanupSurface
  , internalIncompleteEvidenceRunId :: !CleanupRunId
  , internalIncompleteEvidenceGraphDigest :: !CleanupDigest
  , internalIncompleteEvidenceRecoveryPlane
      :: !(Maybe (RecoveryPlaneFinalEvidence surface))
  , internalIncompleteEvidenceFailures :: !(NonEmpty TeardownFailure)
  }

incompleteEvidenceSurface :: SurfaceIncompleteEvidence surface -> CleanupSurface
incompleteEvidenceSurface = internalIncompleteEvidenceSurface

incompleteEvidenceRunId :: SurfaceIncompleteEvidence surface -> CleanupRunId
incompleteEvidenceRunId = internalIncompleteEvidenceRunId

incompleteEvidenceGraphDigest
  :: SurfaceIncompleteEvidence surface -> CleanupDigest
incompleteEvidenceGraphDigest = internalIncompleteEvidenceGraphDigest

incompleteEvidenceRecoveryPlane
  :: SurfaceIncompleteEvidence surface
  -> Maybe (RecoveryPlaneFinalEvidence surface)
incompleteEvidenceRecoveryPlane = internalIncompleteEvidenceRecoveryPlane

incompleteEvidenceRecoveryPlaneDisposition
  :: SurfaceIncompleteEvidence surface
  -> Maybe RecoveryPlaneFinalDisposition
incompleteEvidenceRecoveryPlaneDisposition =
  fmap recoveryPlaneFinalDisposition . incompleteEvidenceRecoveryPlane

incompleteEvidenceFailures
  :: SurfaceIncompleteEvidence surface -> NonEmpty TeardownFailure
incompleteEvidenceFailures = internalIncompleteEvidenceFailures

data DesiredAbsenceReportClassification surface
  = DesiredAbsenceReadBacksComplete !(SurfaceReadBackEvidence surface)
  | DesiredAbsenceIncomplete !(SurfaceIncompleteEvidence surface)

data DesiredAbsenceReportError
  = DesiredAbsenceReportHandleInvalid !CleanupRunClientError
  | DesiredAbsenceReportNotTerminal !CleanupRunError
  | DesiredAbsenceReportSurfaceMismatch !CleanupSurface !CleanupSurface
  | DesiredAbsenceRecoveryEvidenceUnavailable !CleanupSurface
  | DesiredAbsenceRecoveryRunMismatch !CleanupRunId !CleanupRunId
  | DesiredAbsenceRecoveryDescriptorMismatch !CleanupDigest !CleanupDigest
  | DesiredAbsenceRecoveryGraphMismatch !CleanupDigest !CleanupDigest
  | DesiredAbsenceRecoveryScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | DesiredAbsenceRecoveryOperationCardinality !Text !Int
  | DesiredAbsenceRecoveryOperationMismatch
      !Text
      !CleanupOperationId
      !CleanupOperationId
  | DesiredAbsenceRecoveryAttemptMismatch
      !CleanupOperationId
      !CleanupAttemptId
      !(Maybe CleanupNodeState)
  | DesiredAbsenceRecoveryDispositionConflict
      !RecoveryPlaneFinalDisposition
  | DesiredAbsenceReportRunMismatch !CleanupRunId !CleanupRunId
  | DesiredAbsenceReportGraphMismatch !CleanupDigest !CleanupDigest
  | DesiredAbsenceReportNodeSetMismatch ![CleanupNodeId] ![CleanupNodeId]
  | DesiredAbsenceCompletionRunMismatch !CleanupRunId !CleanupRunId
  | DesiredAbsenceCompletionGraphMismatch !CleanupDigest !CleanupDigest
  deriving stock (Eq, Show)

-- | Fixed package-private regression result.  It deliberately exposes only
-- boolean outcomes: no compiled program, raw report, RecoveryPlane proof, or
-- evidence constructor crosses the public facade.
data DesiredAbsenceReportRegression = DesiredAbsenceReportRegression
  { desiredAbsenceRegressionEstablishedCompletes :: !Bool
  , desiredAbsenceRegressionNotEstablishedRefused :: !Bool
  , desiredAbsenceRegressionLostRefused :: !Bool
  , desiredAbsenceRegressionIncompleteRetainsFinal :: !Bool
  , desiredAbsenceRegressionUnavailableRefused :: !Bool
  , desiredAbsenceRegressionExactBindingAccepted :: !Bool
  , desiredAbsenceRegressionCrossBindingRefused :: !Bool
  , desiredAbsenceRegressionAttemptBindingRefused :: !Bool
  , desiredAbsenceRegressionReportBindingRefused :: !Bool
  , desiredAbsenceRegressionLocalAndTotalDistinct :: !Bool
  }
  deriving stock (Eq, Show)

fixedDesiredAbsenceReportRegression
  :: Either Text DesiredAbsenceReportRegression
fixedDesiredAbsenceReportRegression = do
  runId <- firstShow (mkCleanupRunId "report-regression-run")
  otherRunId <- firstShow (mkCleanupRunId "report-regression-other-run")
  owner <- firstShow (mkCleanupOwnerId "report-regression-owner")
  descriptorDigest <- firstShow (mkCleanupDigest (Text.replicate 64 "a"))
  wrongDescriptorDigest <- firstShow (mkCleanupDigest (Text.replicate 64 "b"))
  wrongGraphDigest <- firstShow (mkCleanupDigest (Text.replicate 64 "c"))
  establishAttempt <- firstShow (mkCleanupAttemptId "report-establish-attempt")
  readBackAttempt <- firstShow (mkCleanupAttemptId "report-read-back-attempt")
  dispositionAttempt <- firstShow (mkCleanupAttemptId "report-disposition-attempt")
  otherAttempt <- firstShow (mkCleanupAttemptId "report-other-attempt")
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          (LinuxRke2FoundationId "report-foundation")
          (Just fixedReportAwsScope)
          CascadeSurface
      )
  otherCompiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          otherRunId
          (LinuxRke2FoundationId "report-other-foundation")
          (Just fixedReportAwsScope)
          CascadeSurface
      )
  run <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          owner
          0
          1000000
      )
  requirement <-
    firstShow (deriveOrdinaryTeardownRecoveryRequirementInternal compiled run)
  identity <-
    firstShow
      ( RecoveryPlaneInternal.deriveRecoveryPlaneIdentityFromCompiledInternal
          descriptorDigest
          CascadeRecoverySurface
          compiled
          requirement
      )
  let establishOperation =
        recoveryPlaneIdentityEstablishOperationId identity
      readBackOperation =
        recoveryPlaneIdentityReadBackOperationId identity
      dispositionOperation =
        recoveryPlaneIdentityDispositionOperationId identity
      establishBinding =
        RecoveryPlaneInternal.recoveryPlaneAttemptBindingInternal
          identity
          establishOperation
          establishAttempt
      readBackBinding =
        RecoveryPlaneInternal.recoveryPlaneAttemptBindingInternal
          identity
          readBackOperation
          readBackAttempt
      dispositionBinding =
        RecoveryPlaneInternal.recoveryPlaneAttemptBindingInternal
          identity
          dispositionOperation
          dispositionAttempt
      readyObservations =
        fixedComponentObservations
          identity
          readBackOperation
          readBackAttempt
          RecoveryPlaneInternal.RecoveryPlaneRawReady
      missingReadBackObservations =
        fixedComponentObservations
          identity
          readBackOperation
          readBackAttempt
          (RecoveryPlaneInternal.RecoveryPlaneRawMissing "not serving")
      readyDispositionObservations =
        fixedComponentObservations
          identity
          dispositionOperation
          dispositionAttempt
          RecoveryPlaneInternal.RecoveryPlaneRawReady
      missingDispositionObservations =
        fixedComponentObservations
          identity
          dispositionOperation
          dispositionAttempt
          (RecoveryPlaneInternal.RecoveryPlaneRawMissing "not serving")
  readyInitialFacts <-
    firstShow
      ( RecoveryPlaneInternal.normalizeRecoveryPlaneComponentFactsInternal
          readBackBinding
          readyObservations
      )
  missingInitialFacts <-
    firstShow
      ( RecoveryPlaneInternal.normalizeRecoveryPlaneComponentFactsInternal
          readBackBinding
          missingReadBackObservations
      )
  readyFinalFacts <-
    firstShow
      ( RecoveryPlaneInternal.normalizeRecoveryPlaneComponentFactsInternal
          dispositionBinding
          readyDispositionObservations
      )
  missingFinalFacts <-
    firstShow
      ( RecoveryPlaneInternal.normalizeRecoveryPlaneComponentFactsInternal
          dispositionBinding
          missingDispositionObservations
      )
  readyInitial <-
    firstShow
      ( RecoveryPlaneInternal.mkRecoveryPlaneInitialReadBackInternal
          establishBinding
          readBackBinding
          readyInitialFacts
      )
  neverReadyInitial <-
    firstShow
      ( RecoveryPlaneInternal.mkRecoveryPlaneInitialReadBackInternal
          establishBinding
          readBackBinding
          missingInitialFacts
      )
  established <-
    firstShow
      ( RecoveryPlaneInternal.mkRecoveryPlaneFinalEvidenceInternal
          readyInitial
          dispositionBinding
          readyFinalFacts
      )
  notEstablished <-
    firstShow
      ( RecoveryPlaneInternal.mkRecoveryPlaneFinalEvidenceInternal
          neverReadyInitial
          dispositionBinding
          missingFinalFacts
      )
  lost <-
    firstShow
      ( RecoveryPlaneInternal.mkRecoveryPlaneFinalEvidenceInternal
          readyInitial
          dispositionBinding
          missingFinalFacts
      )
  localCompiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          (LinuxRke2FoundationId "report-foundation")
          Nothing
          LocalOnlySurface
      )
  totalCompiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          (LinuxRke2FoundationId "report-foundation")
          (Just fixedReportAwsScope)
          TotalDecommissionSurface
      )
  let graph = compiledDesiredAbsenceGraph compiled
      graphDigest = cleanupGraphDigest graph
      scope = compiledDesiredAbsenceObservationScope compiled
      successfulStates =
        fixedSuccessfulStates
          graph
          establishOperation
          establishAttempt
          readBackOperation
          readBackAttempt
          dispositionOperation
          dispositionAttempt
          otherAttempt
      successfulReport = fixedReport compiled successfulStates
      incompleteReport =
        successfulReport
          { cleanupReportNodeStates = fixedFailedState otherAttempt successfulStates
          }
      establishedClassification =
        classifyDesiredAbsenceReportInternal
          CascadeSurface
          compiled
          successfulReport
          (Just established)
      notEstablishedClassification =
        classifyDesiredAbsenceReportInternal
          CascadeSurface
          compiled
          successfulReport
          (Just notEstablished)
      lostClassification =
        classifyDesiredAbsenceReportInternal
          CascadeSurface
          compiled
          successfulReport
          (Just lost)
      incompleteClassifications =
        [
          ( RecoveryPlaneEstablished
          , classifyDesiredAbsenceReportInternal
              CascadeSurface
              compiled
              incompleteReport
              (Just established)
          )
        ,
          ( RecoveryPlaneNotEstablished
          , classifyDesiredAbsenceReportInternal
              CascadeSurface
              compiled
              incompleteReport
              (Just notEstablished)
          )
        ,
          ( RecoveryPlaneLost
          , classifyDesiredAbsenceReportInternal
              CascadeSurface
              compiled
              incompleteReport
              (Just lost)
          )
        ]
      validate =
        validateRecoveryPlaneFinalBinding
          Cascade
          runId
          descriptorDigest
          graphDigest
          scope
          establishOperation
          readBackOperation
          dispositionOperation
          graph
      crossBindingRefusals =
        [ validateRecoveryPlaneFinalBinding
            LocalOnly
            runId
            descriptorDigest
            graphDigest
            scope
            establishOperation
            readBackOperation
            dispositionOperation
            graph
            successfulStates
            established
        , validateRecoveryPlaneFinalBinding
            Cascade
            otherRunId
            descriptorDigest
            graphDigest
            scope
            establishOperation
            readBackOperation
            dispositionOperation
            graph
            successfulStates
            established
        , validateRecoveryPlaneFinalBinding
            Cascade
            runId
            wrongDescriptorDigest
            graphDigest
            scope
            establishOperation
            readBackOperation
            dispositionOperation
            graph
            successfulStates
            established
        , validateRecoveryPlaneFinalBinding
            Cascade
            runId
            descriptorDigest
            wrongGraphDigest
            scope
            establishOperation
            readBackOperation
            dispositionOperation
            graph
            successfulStates
            established
        , validateRecoveryPlaneFinalBinding
            Cascade
            runId
            descriptorDigest
            graphDigest
            (compiledDesiredAbsenceObservationScope otherCompiled)
            establishOperation
            readBackOperation
            dispositionOperation
            graph
            successfulStates
            established
        , validateRecoveryPlaneFinalBinding
            Cascade
            runId
            descriptorDigest
            graphDigest
            scope
            readBackOperation
            establishOperation
            dispositionOperation
            graph
            successfulStates
            established
        ]
      attemptRefusals =
        [ validate
            (fixedWrongAttemptState graph successfulStates operation otherAttempt)
            established
        | operation <- [establishOperation, readBackOperation, dispositionOperation]
        ]
      reportBindingRefusals =
        [ classifyDesiredAbsenceReportInternal
            CascadeSurface
            compiled
            successfulReport {cleanupReportRunId = otherRunId}
            (Just established)
        , classifyDesiredAbsenceReportInternal
            CascadeSurface
            compiled
            successfulReport {cleanupReportGraphDigest = wrongGraphDigest}
            (Just established)
        , classifyDesiredAbsenceReportInternal
            CascadeSurface
            compiled
            successfulReport
              { cleanupReportNodeStates =
                  Map.delete
                    (fst (Map.findMin successfulStates))
                    successfulStates
              }
            (Just established)
        ]
      localClassification =
        classifyDesiredAbsenceReportInternal
          LocalOnlySurface
          localCompiled
          (fixedReport localCompiled (fixedUniformSuccessfulStates localCompiled otherAttempt))
          Nothing
      totalClassification =
        classifyDesiredAbsenceReportInternal
          TotalDecommissionSurface
          totalCompiled
          (fixedReport totalCompiled (fixedUniformSuccessfulStates totalCompiled otherAttempt))
          Nothing
  pure
    DesiredAbsenceReportRegression
      { desiredAbsenceRegressionEstablishedCompletes =
          classificationCompletesWith RecoveryPlaneEstablished establishedClassification
      , desiredAbsenceRegressionNotEstablishedRefused =
          classificationRefusedDisposition
            RecoveryPlaneNotEstablished
            notEstablishedClassification
      , desiredAbsenceRegressionLostRefused =
          classificationRefusedDisposition RecoveryPlaneLost lostClassification
      , desiredAbsenceRegressionIncompleteRetainsFinal =
          all (uncurry classificationIncompleteWith) incompleteClassifications
      , desiredAbsenceRegressionUnavailableRefused =
          isLeft
            ( requireRecoveryPlaneFinal
                CascadeSurface
                (Nothing :: Maybe (RecoveryPlaneFinalEvidence 'Cascade))
            )
      , desiredAbsenceRegressionExactBindingAccepted =
          isRight (validate successfulStates established)
      , desiredAbsenceRegressionCrossBindingRefused =
          all isLeft crossBindingRefusals
      , desiredAbsenceRegressionAttemptBindingRefused =
          all isLeft attemptRefusals
      , desiredAbsenceRegressionReportBindingRefused =
          all isLeft reportBindingRefusals
      , desiredAbsenceRegressionLocalAndTotalDistinct =
          classificationSurface LocalOnly localClassification
            && classificationSurface TotalDecommission totalClassification
      }

fixedReportAwsScope :: AwsScope
fixedReportAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

fixedComponentObservations
  :: RecoveryPlaneInternal.RecoveryPlaneIdentity surface
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneInternal.RecoveryPlaneRawComponentResult
  -> RecoveryPlaneInternal.RecoveryPlaneComponentObservationSet surface
fixedComponentObservations identity operationId attempt firstResult =
  RecoveryPlaneInternal.recoveryPlaneComponentObservationSetInternal
    identity
    operationId
    attempt
    [ RecoveryPlaneInternal.RecoveryPlaneRawComponentObservation
        component
        (if index == (0 :: Int) then firstResult else RecoveryPlaneInternal.RecoveryPlaneRawReady)
    | (index, component) <-
        zip
          [(0 :: Int) ..]
          (RecoveryPlaneInternal.recoveryPlaneIdentityComponents identity)
    ]

fixedSuccessfulStates
  :: CleanupGraph
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> CleanupAttemptId
  -> Map.Map CleanupNodeId CleanupNodeState
fixedSuccessfulStates
  graph
  establishOperation
  establishAttempt
  readBackOperation
  readBackAttempt
  dispositionOperation
  dispositionAttempt
  otherAttempt =
    Map.fromList
      [ ( cleanupNodeId plan
        , CleanupNodeCompleted (attemptFor (cleanupNodeOperationId plan)) CleanupNodeSucceeded
        )
      | plan <- cleanupGraphNodes graph
      ]
   where
    attemptFor operation
      | operation == establishOperation = establishAttempt
      | operation == readBackOperation = readBackAttempt
      | operation == dispositionOperation = dispositionAttempt
      | otherwise = otherAttempt

fixedUniformSuccessfulStates
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupAttemptId
  -> Map.Map CleanupNodeId CleanupNodeState
fixedUniformSuccessfulStates compiled attempt =
  Map.fromList
    [ (cleanupNodeId plan, CleanupNodeCompleted attempt CleanupNodeSucceeded)
    | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
    ]

fixedFailedState
  :: CleanupAttemptId
  -> Map.Map CleanupNodeId CleanupNodeState
  -> Map.Map CleanupNodeId CleanupNodeState
fixedFailedState failureAttempt states =
  case Map.lookupMin states of
    Nothing -> states
    Just (nodeId, _) ->
      Map.insert
        nodeId
        (CleanupNodeCompleted failureAttempt (CleanupNodeFailed "definitive failure"))
        states

fixedWrongAttemptState
  :: CleanupGraph
  -> Map.Map CleanupNodeId CleanupNodeState
  -> CleanupOperationId
  -> CleanupAttemptId
  -> Map.Map CleanupNodeId CleanupNodeState
fixedWrongAttemptState graph states operationId wrongAttempt =
  case [cleanupNodeId plan | plan <- cleanupGraphNodes graph, cleanupNodeOperationId plan == operationId] of
    [nodeId] ->
      Map.insert
        nodeId
        (CleanupNodeCompleted wrongAttempt CleanupNodeSucceeded)
        states
    _ -> states

fixedReport
  :: CompiledDesiredAbsenceProgram surface
  -> Map.Map CleanupNodeId CleanupNodeState
  -> CleanupRunReport
fixedReport compiled states =
  CleanupRunReport
    { cleanupReportRunId = compiledDesiredAbsenceRunId compiled
    , cleanupReportGraphDigest =
        cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
    , cleanupReportPrimaryOutcome = CleanupPrimarySucceeded
    , cleanupReportNodeStates = states
    }

classificationCompletesWith
  :: RecoveryPlaneFinalDisposition
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
  -> Bool
classificationCompletesWith expected classification = case classification of
  Right (DesiredAbsenceReadBacksComplete evidence) ->
    fmap recoveryPlaneFinalDisposition (readBackEvidenceRecoveryPlane evidence)
      == Just expected
  _ -> False

classificationIncompleteWith
  :: RecoveryPlaneFinalDisposition
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
  -> Bool
classificationIncompleteWith expected classification = case classification of
  Right (DesiredAbsenceIncomplete evidence) ->
    incompleteEvidenceRecoveryPlaneDisposition evidence == Just expected
  _ -> False

classificationRefusedDisposition
  :: RecoveryPlaneFinalDisposition
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
  -> Bool
classificationRefusedDisposition expected classification = case classification of
  Left (DesiredAbsenceRecoveryDispositionConflict actual) -> actual == expected
  _ -> False

classificationSurface
  :: CleanupSurface
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
  -> Bool
classificationSurface expected classification = case classification of
  Right (DesiredAbsenceReadBacksComplete evidence) ->
    readBackEvidenceSurface evidence == expected
  _ -> False

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

-- | Classify only an independently observed, descriptor-bound terminal run.
-- The rank-2 descriptor join fixes the surface and compiled graph before any
-- report proof can be minted.
classifyDesiredAbsenceReport
  :: DescriptorBoundCleanupRun
  -> DesiredAbsenceRecoveryInput surface
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
classifyDesiredAbsenceReport bound recoveryInput = do
  joined <-
    first
      DesiredAbsenceReportHandleInvalid
      ( withDescriptorBoundCleanupProgram bound $ \witness compiled sealed -> do
          report <-
            first
              DesiredAbsenceReportNotTerminal
              (descriptorBoundCleanupRunReport sealed)
          classifyBoundReport
            witness
            compiled
            sealed
            report
            recoveryInput
      )
  joined

classifyBoundReport
  :: CleanupSurfaceWitness actual
  -> CompiledDesiredAbsenceProgram actual
  -> DescriptorBoundCleanupRun
  -> CleanupRunReport
  -> DesiredAbsenceRecoveryInput expected
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification expected)
classifyBoundReport witness compiled bound report recoveryInput =
  case (recoveryInput, witness) of
    (OrdinaryDesiredAbsenceRecovery CascadeRecoverySurface final, CascadeSurface) ->
      classifyOrdinary CascadeSurface bound compiled report final
    ( OrdinaryDesiredAbsenceRecovery ExplicitPerRunRecoverySurface final
      , ExplicitPerRunSurface
      ) -> classifyOrdinary ExplicitPerRunSurface bound compiled report final
    ( OrdinaryDesiredAbsenceRecovery OperationalRecoverySurface final
      , OperationalTeardownSurface
      ) -> classifyOrdinary OperationalTeardownSurface bound compiled report final
    ( OrdinaryDesiredAbsenceRecovery ExplicitLongLivedRecoverySurface final
      , ExplicitLongLivedSurface
      ) -> classifyOrdinary ExplicitLongLivedSurface bound compiled report final
    (LocalOnlyDesiredAbsenceRecovery, LocalOnlySurface) ->
      classifyDesiredAbsenceReportInternal LocalOnlySurface compiled report Nothing
    (TotalDecommissionDesiredAbsenceRecovery, TotalDecommissionSurface) ->
      classifyDesiredAbsenceReportInternal
        TotalDecommissionSurface
        compiled
        report
        Nothing
    _ ->
      Left
        ( DesiredAbsenceReportSurfaceMismatch
            (recoveryInputSurface recoveryInput)
            (cleanupSurfaceFromWitness witness)
        )

classifyOrdinary
  :: CleanupSurfaceWitness surface
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRunReport
  -> Maybe (RecoveryPlaneFinalEvidence surface)
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
classifyOrdinary witness bound compiled report observedFinal = do
  finalEvidence <- requireRecoveryPlaneFinal witness observedFinal
  validateRecoveryPlaneFinal witness bound compiled finalEvidence
  classifyDesiredAbsenceReportInternal witness compiled report (Just finalEvidence)

requireRecoveryPlaneFinal
  :: CleanupSurfaceWitness surface
  -> Maybe (RecoveryPlaneFinalEvidence surface)
  -> Either DesiredAbsenceReportError (RecoveryPlaneFinalEvidence surface)
requireRecoveryPlaneFinal witness =
  maybe
    ( Left
        ( DesiredAbsenceRecoveryEvidenceUnavailable
            (cleanupSurfaceFromWitness witness)
        )
    )
    Right

recoveryInputSurface :: DesiredAbsenceRecoveryInput surface -> CleanupSurface
recoveryInputSurface recoveryInput = case recoveryInput of
  OrdinaryDesiredAbsenceRecovery witness _ -> recoverySurface witness
  LocalOnlyDesiredAbsenceRecovery -> LocalOnly
  TotalDecommissionDesiredAbsenceRecovery -> TotalDecommission

recoverySurface :: RecoverySurfaceWitness surface -> CleanupSurface
recoverySurface witness = case witness of
  CascadeRecoverySurface -> Cascade
  ExplicitPerRunRecoverySurface -> ExplicitPerRun
  OperationalRecoverySurface -> OperationalTeardown
  ExplicitLongLivedRecoverySurface -> ExplicitLongLived

validateRecoveryPlaneFinal
  :: CleanupSurfaceWitness surface
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> RecoveryPlaneFinalEvidence surface
  -> Either DesiredAbsenceReportError ()
validateRecoveryPlaneFinal witness bound compiled finalEvidence = do
  expectedEstablish <- exactRecoveryOperation compiled RecoveryEstablishRole
  expectedReadBack <- exactRecoveryOperation compiled RecoveryReadBackRole
  expectedDisposition <- exactRecoveryOperation compiled RecoveryDispositionRole
  validateRecoveryPlaneFinalBinding
    (cleanupSurfaceFromWitness witness)
    (descriptorBoundCleanupRunId bound)
    (descriptorBoundCleanupRunDescriptorDigest bound)
    (descriptorBoundCleanupRunGraphDigest bound)
    (compiledDesiredAbsenceObservationScope compiled)
    expectedEstablish
    expectedReadBack
    expectedDisposition
    (descriptorBoundCleanupRunGraph bound)
    (descriptorBoundCleanupRunNodeStates bound)
    finalEvidence

validateRecoveryPlaneFinalBinding
  :: CleanupSurface
  -> CleanupRunId
  -> CleanupDigest
  -> CleanupDigest
  -> ObservationEvidenceScope
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupOperationId
  -> CleanupGraph
  -> Map.Map CleanupNodeId CleanupNodeState
  -> RecoveryPlaneFinalEvidence surface
  -> Either DesiredAbsenceReportError ()
validateRecoveryPlaneFinalBinding
  expectedSurface
  expectedRunId
  expectedDescriptor
  expectedGraph
  expectedScope
  expectedEstablish
  expectedReadBack
  expectedDisposition
  graph
  nodeStates
  finalEvidence = do
    let identity = recoveryPlaneFinalIdentity finalEvidence
        actualSurface = recoveryPlaneIdentitySurface identity
        actualRunId = recoveryPlaneIdentityRunId identity
        actualDescriptor = recoveryPlaneIdentityDescriptorDigest identity
        actualGraph = recoveryPlaneIdentityGraphDigest identity
        actualScope = recoveryPlaneIdentityObservationScope identity
    if actualSurface == expectedSurface
      then Right ()
      else Left (DesiredAbsenceReportSurfaceMismatch expectedSurface actualSurface)
    if actualRunId == expectedRunId
      then Right ()
      else Left (DesiredAbsenceRecoveryRunMismatch expectedRunId actualRunId)
    if actualDescriptor == expectedDescriptor
      then Right ()
      else
        Left
          (DesiredAbsenceRecoveryDescriptorMismatch expectedDescriptor actualDescriptor)
    if actualGraph == expectedGraph
      then Right ()
      else Left (DesiredAbsenceRecoveryGraphMismatch expectedGraph actualGraph)
    if actualScope == expectedScope
      then Right ()
      else Left (DesiredAbsenceRecoveryScopeMismatch expectedScope actualScope)
    requireOperation
      "establish"
      expectedEstablish
      (recoveryPlaneIdentityEstablishOperationId identity)
    requireOperation
      "read-back"
      expectedReadBack
      (recoveryPlaneIdentityReadBackOperationId identity)
    requireOperation
      "disposition"
      expectedDisposition
      (recoveryPlaneIdentityDispositionOperationId identity)
    requireAttempt
      graph
      nodeStates
      expectedEstablish
      (recoveryPlaneFinalEstablishAttemptId finalEvidence)
    requireAttempt
      graph
      nodeStates
      expectedReadBack
      (recoveryPlaneFinalInitialReadBackAttemptId finalEvidence)
    requireAttempt
      graph
      nodeStates
      expectedDisposition
      (recoveryPlaneFinalDispositionAttemptId finalEvidence)

data RecoveryOperationRole
  = RecoveryEstablishRole
  | RecoveryReadBackRole
  | RecoveryDispositionRole

exactRecoveryOperation
  :: CompiledDesiredAbsenceProgram surface
  -> RecoveryOperationRole
  -> Either DesiredAbsenceReportError CleanupOperationId
exactRecoveryOperation compiled role = case candidates of
  [nodeId] ->
    case find ((== nodeId) . cleanupNodeId) graphNodes of
      Just plan -> Right (cleanupNodeOperationId plan)
      Nothing -> Left (DesiredAbsenceRecoveryOperationCardinality roleName 0)
  values ->
    Left (DesiredAbsenceRecoveryOperationCardinality roleName (length values))
 where
  candidates =
    [ nodeId
    | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
    , operationHasRole role operation
    ]
  graphNodes = cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
  roleName = recoveryOperationRoleName role

operationHasRole :: RecoveryOperationRole -> TeardownOperation surface -> Bool
operationHasRole role operation = case (role, operation) of
  (RecoveryEstablishRole, EstablishRecoveryPlane _) -> True
  (RecoveryReadBackRole, ReadBackRecoveryPlane _) -> True
  (RecoveryDispositionRole, ObserveRecoveryPlaneDisposition _) -> True
  _ -> False

recoveryOperationRoleName :: RecoveryOperationRole -> Text
recoveryOperationRoleName role = case role of
  RecoveryEstablishRole -> "establish"
  RecoveryReadBackRole -> "read-back"
  RecoveryDispositionRole -> "disposition"

requireOperation
  :: Text
  -> CleanupOperationId
  -> CleanupOperationId
  -> Either DesiredAbsenceReportError ()
requireOperation role expected actual
  | expected == actual = Right ()
  | otherwise =
      Left (DesiredAbsenceRecoveryOperationMismatch role expected actual)

requireAttempt
  :: CleanupGraph
  -> Map.Map CleanupNodeId CleanupNodeState
  -> CleanupOperationId
  -> CleanupAttemptId
  -> Either DesiredAbsenceReportError ()
requireAttempt graph nodeStates operationId expectedAttempt =
  case matchingNodes of
    [nodeId] ->
      let state = Map.lookup nodeId nodeStates
       in case state of
            Just (CleanupNodeCompleted actualAttempt _)
              | actualAttempt == expectedAttempt -> Right ()
            _ ->
              Left
                ( DesiredAbsenceRecoveryAttemptMismatch
                    operationId
                    expectedAttempt
                    state
                )
    values ->
      Left
        ( DesiredAbsenceRecoveryOperationCardinality
            "attempt-state"
            (length values)
        )
 where
  matchingNodes =
    [ cleanupNodeId plan
    | plan <- cleanupGraphNodes graph
    , cleanupNodeOperationId plan == operationId
    ]

-- | Package-private pure fold.  The caller has already joined and validated
-- the descriptor-bound handle and, for an ordinary surface, its exact opaque
-- final RecoveryPlane evidence.
classifyDesiredAbsenceReportInternal
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRunReport
  -> Maybe (RecoveryPlaneFinalEvidence surface)
  -> Either
       DesiredAbsenceReportError
       (DesiredAbsenceReportClassification surface)
classifyDesiredAbsenceReportInternal witness compiled report finalEvidence = do
  validateReportBinding compiled report
  let operationStates =
        [ (nodeId, operation, state)
        | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
        , Just state <- [Map.lookup nodeId (cleanupReportNodeStates report)]
        ]
      failures = collectFailures operationStates
      missingReadBacks =
        [ TeardownMandatoryReadBackMissing (teardownOperationTag operation)
        | (_, operation, state) <- operationStates
        , operationIsMandatoryReadBack operation
        , not (stateSucceeded state)
        ]
      allFailures = failures ++ missingReadBacks
      surface = cleanupSurfaceFromWitness witness
  case allFailures of
    [] -> do
      case recoveryPlaneFinalDisposition <$> finalEvidence of
        Just RecoveryPlaneEstablished -> Right ()
        Just disposition ->
          Left (DesiredAbsenceRecoveryDispositionConflict disposition)
        Nothing -> Right ()
      Right
        ( DesiredAbsenceReadBacksComplete
            SurfaceReadBackEvidence
              { internalReadBackEvidenceSurface = surface
              , internalReadBackEvidenceRunId = cleanupReportRunId report
              , internalReadBackEvidenceGraphDigest = cleanupReportGraphDigest report
              , internalReadBackEvidenceRecoveryPlane = finalEvidence
              }
        )
    failure : remaining ->
      Right
        ( DesiredAbsenceIncomplete
            SurfaceIncompleteEvidence
              { internalIncompleteEvidenceSurface = surface
              , internalIncompleteEvidenceRunId = cleanupReportRunId report
              , internalIncompleteEvidenceGraphDigest = cleanupReportGraphDigest report
              , internalIncompleteEvidenceRecoveryPlane = finalEvidence
              , internalIncompleteEvidenceFailures = failure :| remaining
              }
        )

validateReportBinding
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupRunReport
  -> Either DesiredAbsenceReportError ()
validateReportBinding compiled report
  | cleanupReportRunId report /= compiledDesiredAbsenceRunId compiled =
      Left
        ( DesiredAbsenceReportRunMismatch
            (compiledDesiredAbsenceRunId compiled)
            (cleanupReportRunId report)
        )
  | cleanupReportGraphDigest report /= expectedDigest =
      Left
        ( DesiredAbsenceReportGraphMismatch
            expectedDigest
            (cleanupReportGraphDigest report)
        )
  | expectedNodes /= observedNodes =
      Left (DesiredAbsenceReportNodeSetMismatch expectedNodes observedNodes)
  | otherwise = Right ()
 where
  expectedDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
  expectedNodes = Map.keys (Map.fromList (compiledDesiredAbsenceOperations compiled))
  observedNodes = Map.keys (cleanupReportNodeStates report)

collectFailures
  :: [(CleanupNodeId, TeardownOperation surface, CleanupNodeState)]
  -> [TeardownFailure]
collectFailures operationStates = concatMap failureFor operationStates
 where
  failureFor (nodeId, operation, state) = case state of
    CleanupNodeCompleted _ CleanupNodeSucceeded -> []
    CleanupNodeCompleted _ (CleanupNodeFailed detail) ->
      [TeardownNodeFailed nodeId detail]
    CleanupNodeCompleted _ (CleanupNodeEffectUnconfirmed detail)
      | operationConfirmed operationStates operation -> []
      | otherwise -> [TeardownEffectUnconfirmed nodeId detail]
    CleanupNodeBlocked blockers -> [TeardownNodeBlocked nodeId blockers]
    CleanupNodePending -> [TeardownNodePending nodeId]
    CleanupNodeRunning _ -> [TeardownNodeRunning nodeId]

operationConfirmed
  :: [(CleanupNodeId, TeardownOperation surface, CleanupNodeState)]
  -> TeardownOperation surface
  -> Bool
operationConfirmed operationStates operation =
  case confirmationOperation operation of
    Nothing -> False
    Just confirmation ->
      case find (\(_, candidate, _) -> candidate == confirmation) operationStates of
        Just (_, _, state) -> stateSucceeded state
        Nothing -> False

confirmationOperation
  :: TeardownOperation surface -> Maybe (TeardownOperation surface)
confirmationOperation operation = case operation of
  EstablishRecoveryPlane recovery -> Just (ReadBackRecoveryPlane recovery)
  ReconcileRegisteredTargetAbsent target ->
    Just (ReadBackRegisteredTargetAbsent target)
  ReconcileStackCheckpointRestore target ->
    Just (ReadBackStackCheckpointRecovery target)
  CommitAwsStackReaderBundle target ->
    Just (ReadBackAwsStackReaderBundle target)
  CommitEksDrainIntent target -> Just (ReadBackEksDrainIntent target)
  DrainEksKubernetesResources target ->
    Just (ReadBackEksKubernetesDrain target)
  RetireStackCheckpointPair target ->
    Just (ReadBackStackCheckpointRetirement target)
  CommitCascadePreUninstallReport -> Just ReadBackCascadePreUninstallReport
  UninstallCascadeLocalFoundation -> Just ReadBackCascadeLocalAbsence
  CommitCascadeCompletion -> Just ReadBackCascadeCompletion
  UninstallLocalOnlyFoundation -> Just ReadBackLocalOnlyAbsence
  CommitLocalOnlyCompletion -> Just ReadBackLocalOnlyCompletion
  CommitOrdinarySurfaceReport -> Just ReadBackOrdinarySurfaceReport
  UninstallDecommissionLocalFoundation -> Just ReadBackDecommissionLocalAbsence
  ApplyDecommissionLocalDataDisposition ->
    Just ReadBackDecommissionLocalDataDisposition
  CommitDecommissionTerminalReceipt -> Just ReadBackDecommissionTerminalReceipt
  ReadBackRecoveryPlane _ -> Nothing
  ObserveRecoveryPlaneDisposition _ -> Nothing
  ObserveRegisteredTarget _ -> Nothing
  ObserveStackCheckpointPair _ -> Nothing
  ReadBackStackCheckpointRecovery _ -> Nothing
  ReadBackAwsStackReaderBundle _ -> Nothing
  ReadBackEksDrainIntent _ -> Nothing
  ReadBackEksKubernetesDrain _ -> Nothing
  ReadBackRegisteredTargetAbsent _ -> Nothing
  ReadBackStackCheckpointRetirement _ -> Nothing
  AuditCascadeEscapes -> Nothing
  ReadBackCascadePreUninstallReport -> Nothing
  ReadBackCascadeLocalAbsence -> Nothing
  ReadBackCascadeCompletion -> Nothing
  ReadBackLocalOnlyAbsence -> Nothing
  ReadBackLocalOnlyCompletion -> Nothing
  ReadBackOrdinarySurfaceReport -> Nothing
  AuditTotalDecommissionEscapes -> Nothing
  ObserveExternalDecommissionReceipt -> Nothing
  ReadBackDecommissionLocalAbsence -> Nothing
  ReadBackDecommissionLocalDataDisposition -> Nothing
  ReadBackDecommissionTerminalReceipt -> Nothing

operationIsMandatoryReadBack :: TeardownOperation surface -> Bool
operationIsMandatoryReadBack operation = case operation of
  ReadBackRecoveryPlane _ -> True
  ObserveRecoveryPlaneDisposition _ -> True
  ReadBackRegisteredTargetAbsent _ -> True
  ReadBackStackCheckpointRecovery _ -> True
  ReadBackAwsStackReaderBundle _ -> True
  ReadBackEksDrainIntent _ -> True
  ReadBackEksKubernetesDrain _ -> True
  ReadBackStackCheckpointRetirement _ -> True
  AuditCascadeEscapes -> True
  ReadBackCascadePreUninstallReport -> True
  ReadBackCascadeLocalAbsence -> True
  ReadBackCascadeCompletion -> True
  ReadBackLocalOnlyAbsence -> True
  ReadBackLocalOnlyCompletion -> True
  ReadBackOrdinarySurfaceReport -> True
  AuditTotalDecommissionEscapes -> True
  ObserveExternalDecommissionReceipt -> True
  ReadBackDecommissionLocalAbsence -> True
  ReadBackDecommissionLocalDataDisposition -> True
  ReadBackDecommissionTerminalReceipt -> True
  EstablishRecoveryPlane _ -> False
  ObserveRegisteredTarget _ -> False
  ObserveStackCheckpointPair _ -> False
  ReconcileStackCheckpointRestore _ -> False
  CommitAwsStackReaderBundle _ -> False
  CommitEksDrainIntent _ -> False
  DrainEksKubernetesResources _ -> False
  ReconcileRegisteredTargetAbsent _ -> False
  RetireStackCheckpointPair _ -> False
  CommitCascadePreUninstallReport -> False
  UninstallCascadeLocalFoundation -> False
  CommitCascadeCompletion -> False
  UninstallLocalOnlyFoundation -> False
  CommitLocalOnlyCompletion -> False
  CommitOrdinarySurfaceReport -> False
  UninstallDecommissionLocalFoundation -> False
  ApplyDecommissionLocalDataDisposition -> False
  CommitDecommissionTerminalReceipt -> False

stateSucceeded :: CleanupNodeState -> Bool
stateSucceeded state = case state of
  CleanupNodeCompleted _ CleanupNodeSucceeded -> True
  _ -> False
