-- | Public cascade-evidence boundary.
--
-- Durable Ready values can be captured only from an already-opaque readiness
-- proof.  Their decoder and restoration bridge are deliberately kept in the
-- library-internal module used by the host journal, so raw fields cannot mint
-- readiness evidence through this public API.
module Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeReportDigest
  , cascadeReportDigestText
  , LocalCompletionPermitId
  , localCompletionPermitIdText
  , CascadeLocalOperationReferences
  , cascadeLocalUninstallOperationId
  , cascadeLocalCompletionOperationId
  , CascadeEvidenceComponent (..)
  , CascadeEvidenceError (..)
  , cascadeIntentionallyRetainedProjectionDigest
  , ReadyToUninstallEvidence
  , readyToUninstallRunId
  , readyToUninstallGraphDigest
  , readyToUninstallScope
  , readyToUninstallReportDigest
  , readyToUninstallPermitId
  , readyToUninstallOperationReferences
  , ReadyToUninstallBindingObservation
  , readyBindingObservationRunId
  , readyBindingObservationGraphDigest
  , readyBindingObservationScope
  , readyBindingObservationReportDigest
  , readyBindingObservationPermitId
  , readyBindingObservationOperationReferences
  , DurableReadyToUninstallBinding
  , maximumDurableReadyToUninstallBindingBytes
  , captureDurableReadyToUninstallBinding
  , observeDurableReadyToUninstallBinding
  , encodeDurableReadyToUninstallBinding
  , LocalUninstallEvidence
  , localUninstallAbsenceEvidence
  , CascadeCompleteEvidence
  , cascadeCompleteRunId
  , cascadeCompleteGraphDigest
  , cascadeCompleteReportDigest
  , cascadeCompletePermitId
  , CascadeEvidenceRegression
  , fixedCascadeEvidenceRegression
  , cascadeEvidenceRegressionCompleteChain
  , cascadeEvidenceRegressionAbsenceRefused
  , cascadeEvidenceRegressionCredentialRefused
  , cascadeEvidenceRegressionAuditRefused
  , cascadeEvidenceRegressionPreUninstallRefused
  , cascadeEvidenceRegressionPermitRefused
  , cascadeEvidenceRegressionMixedBindingRefused
  , cascadeEvidenceRegressionLocalAbsenceRefused
  , cascadeEvidenceRegressionCompletionRefused
  , cascadeEvidenceRegressionDurableReadyCanonical
  , cascadeEvidenceRegressionDurableReadyCorruptionRefused
  )
where

import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeCompleteEvidence
  , CascadeEvidenceComponent (..)
  , CascadeEvidenceError (..)
  , CascadeEvidenceRegression
  , CascadeLocalOperationReferences
  , CascadeReportDigest
  , DurableReadyToUninstallBinding
  , LocalCompletionPermitId
  , LocalUninstallEvidence
  , ReadyToUninstallBindingObservation
  , ReadyToUninstallEvidence
  , captureDurableReadyToUninstallBinding
  , cascadeCompleteGraphDigest
  , cascadeCompletePermitId
  , cascadeCompleteReportDigest
  , cascadeCompleteRunId
  , cascadeEvidenceRegressionAbsenceRefused
  , cascadeEvidenceRegressionAuditRefused
  , cascadeEvidenceRegressionCompleteChain
  , cascadeEvidenceRegressionCompletionRefused
  , cascadeEvidenceRegressionCredentialRefused
  , cascadeEvidenceRegressionDurableReadyCanonical
  , cascadeEvidenceRegressionDurableReadyCorruptionRefused
  , cascadeEvidenceRegressionLocalAbsenceRefused
  , cascadeEvidenceRegressionMixedBindingRefused
  , cascadeEvidenceRegressionPermitRefused
  , cascadeEvidenceRegressionPreUninstallRefused
  , cascadeIntentionallyRetainedProjectionDigest
  , cascadeLocalCompletionOperationId
  , cascadeLocalUninstallOperationId
  , cascadeReportDigestText
  , encodeDurableReadyToUninstallBinding
  , fixedCascadeEvidenceRegression
  , localCompletionPermitIdText
  , localUninstallAbsenceEvidence
  , maximumDurableReadyToUninstallBindingBytes
  , observeDurableReadyToUninstallBinding
  , readyBindingObservationGraphDigest
  , readyBindingObservationOperationReferences
  , readyBindingObservationPermitId
  , readyBindingObservationReportDigest
  , readyBindingObservationRunId
  , readyBindingObservationScope
  , readyToUninstallGraphDigest
  , readyToUninstallOperationReferences
  , readyToUninstallPermitId
  , readyToUninstallReportDigest
  , readyToUninstallRunId
  , readyToUninstallScope
  )
