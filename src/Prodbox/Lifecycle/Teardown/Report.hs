{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | Descriptor-bound proof-carrying teardown report facade.  Proof-making
-- implementation details stay package-private; public classification starts
-- from an opaque authenticated run handle and, for ordinary surfaces, an
-- opaque final RecoveryPlane observation.
module Prodbox.Lifecycle.Teardown.Report
  ( DesiredAbsenceRecoveryInput (..)
  , RecoveryPlaneFinalDisposition (..)
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
  , completeExplicitPerRunDesiredAbsence
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
  , desiredAbsenceRegressionExplicitPerRunCompletes
  , desiredAbsenceRegressionExplicitPerRunUnavailableRefused
  , desiredAbsenceRegressionExplicitPerRunSurfaceMismatchRefused
  , desiredAbsenceRegressionExplicitPerRunObligationNonEmpty
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (..)
  )
import Prodbox.Lifecycle.Teardown.Report.Internal
  ( DesiredAbsenceRecoveryInput (..)
  , DesiredAbsenceReportClassification (..)
  , DesiredAbsenceReportError (..)
  , DesiredAbsenceReportRegression
  , SurfaceCompletionEvidence
  , SurfaceIncompleteEvidence
  , SurfaceReadBackEvidence
  , TeardownFailure (..)
  , classifyDesiredAbsenceReport
  , completeCascadeDesiredAbsence
  , completeExplicitPerRunDesiredAbsence
  , completionEvidenceGraphDigest
  , completionEvidenceRunId
  , completionEvidenceSurface
  , desiredAbsenceRegressionAttemptBindingRefused
  , desiredAbsenceRegressionCrossBindingRefused
  , desiredAbsenceRegressionEstablishedCompletes
  , desiredAbsenceRegressionExactBindingAccepted
  , desiredAbsenceRegressionExplicitPerRunCompletes
  , desiredAbsenceRegressionExplicitPerRunObligationNonEmpty
  , desiredAbsenceRegressionExplicitPerRunSurfaceMismatchRefused
  , desiredAbsenceRegressionExplicitPerRunUnavailableRefused
  , desiredAbsenceRegressionIncompleteRetainsFinal
  , desiredAbsenceRegressionLocalAndTotalDistinct
  , desiredAbsenceRegressionLostRefused
  , desiredAbsenceRegressionNotEstablishedRefused
  , desiredAbsenceRegressionReportBindingRefused
  , desiredAbsenceRegressionUnavailableRefused
  , fixedDesiredAbsenceReportRegression
  , incompleteEvidenceFailures
  , incompleteEvidenceGraphDigest
  , incompleteEvidenceRecoveryPlane
  , incompleteEvidenceRecoveryPlaneDisposition
  , incompleteEvidenceRunId
  , incompleteEvidenceSurface
  , readBackEvidenceGraphDigest
  , readBackEvidenceRecoveryPlane
  , readBackEvidenceRunId
  , readBackEvidenceSurface
  )
