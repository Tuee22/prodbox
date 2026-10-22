{-# LANGUAGE OverloadedStrings #-}

-- | Package-private Authority observation of an exact completed cascade.
module Prodbox.ControlPlane.CompletedProviderPredecessor
  ( ObservedCompletedProviderPredecessor
  , CompletedProviderPredecessorError (..)
  , observeCompletedProviderPredecessor
  , completedProviderPredecessorReportDigest
  ) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Prodbox.ControlPlane.AuthorityBackupClient
import Prodbox.ControlPlane.AuthorityBackupEndpoint
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
import Prodbox.Lifecycle.Authority.CompletedProviderPredecessor.Internal
  ( ObservedCompletedProviderPredecessor (..)
  , ProviderPredecessorCoordinates (..)
  , completedProviderPredecessorReportDigest
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.Model (CleanupSurface (Cascade), evidenceCleanupSurface)
import Prodbox.Lifecycle.Teardown.Observation (terminalAuditEvidenceScopeDigest)
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForCascadeTerminalAudit)

data CompletedProviderPredecessorError
  = CompletedProviderPredecessorDescriptorUnavailable
  | CompletedProviderPredecessorRunUnavailable
  | CompletedProviderPredecessorMissing
  | CompletedProviderPredecessorLegacyState
  | CompletedProviderPredecessorBindingMismatch
  | CompletedProviderPredecessorScopeMismatch
  | CompletedProviderPredecessorNotCascade
  | CompletedProviderPredecessorIncomplete
  | CompletedProviderPredecessorNodeSetMismatch
  | CompletedProviderPredecessorNodeNotSuccessful
  | CompletedProviderPredecessorReportInvalid
  | CompletedProviderPredecessorBackupUnavailable
  | CompletedProviderPredecessorBackupMissing
  | CompletedProviderPredecessorBackupCorrupt
  | CompletedProviderPredecessorBackupReceiptMismatch
  | CompletedProviderPredecessorReportDigestMismatch
  | CompletedProviderPredecessorChanged
  deriving (Eq, Show)

-- The runtime supplies its own descriptor, run and authenticated Backup
-- observers. A compacted report must match both its receipt and actual bytes.
observeCompletedProviderPredecessor
  :: (Monad m)
  => CleanupProgramDescriptorAuthorityClient m
  -> DescriptorBoundCleanupRunRepository m revision
  -> AuthorityAggregateBackupClient m
  -> ProviderPredecessorCoordinates
  -> m (Either CompletedProviderPredecessorError ObservedCompletedProviderPredecessor)
observeCompletedProviderPredecessor descriptors runs backup coordinates = do
  firstObservation <- observeOne
  case firstObservation of
    Left cause -> pure (Left cause)
    Right expected -> do
      finalObservation <- observeOne
      pure $ do
        actual <- finalObservation
        unless (actual == expected) (Left CompletedProviderPredecessorChanged)
        Right (ObservedCompletedProviderPredecessor coordinates actual)
 where
  ProviderPredecessorCoordinates runId descriptorDigest graphDigest scopeDigest = coordinates
  observeOne = do
    descriptor <- independentlyReadBackCommittedCleanupProgramDescriptor descriptors runId
    case descriptor of
      Left _ -> pure (Left CompletedProviderPredecessorDescriptorUnavailable)
      Right committed -> case validateDescriptor committed of
        Left cause -> pure (Left cause)
        Right nodes -> do
          observed <- readDescriptorBoundCleanupRun runs
          case observed of
            Left _ -> pure (Left CompletedProviderPredecessorRunUnavailable)
            Right snapshot -> observeSnapshot nodes snapshot
  validateDescriptor committed = do
    unless
      ( committedCleanupProgramDescriptorRunId committed == runId
          && committedCleanupProgramDescriptorDigest committed == descriptorDigest
          && committedCleanupProgramDescriptorGraphDigest committed == graphDigest
      )
      (Left CompletedProviderPredecessorBindingMismatch)
    scope <-
      first
        (const CompletedProviderPredecessorScopeMismatch)
        (committedCleanupProgramDescriptorObservationScope committed)
    unless (evidenceCleanupSurface scope == Cascade) (Left CompletedProviderPredecessorNotCascade)
    unless
      ( terminalAuditEvidenceScopeDigest (scopeForCascadeTerminalAudit scope)
          == cleanupDigestText scopeDigest
      )
      (Left CompletedProviderPredecessorScopeMismatch)
    first
      (const CompletedProviderPredecessorDescriptorUnavailable)
      (committedCleanupProgramDescriptorNodeIds committed)
  observeSnapshot nodes snapshot = case snapshot of
    DescriptorBoundCleanupRunMissing -> pure (Left CompletedProviderPredecessorMissing)
    DescriptorBoundCleanupRunLegacyState _ -> pure (Left CompletedProviderPredecessorLegacyState)
    DescriptorBoundCleanupRunObserved _ storedDescriptor run -> pure $ do
      unless
        ( storedDescriptor == descriptorDigest
            && cleanupRunId run == runId
            && cleanupRunGraphDigest run == graphDigest
        )
        (Left CompletedProviderPredecessorBindingMismatch)
      bytes <- first (const CompletedProviderPredecessorReportInvalid) (encodeCleanupRun reportLimit run)
      checked <-
        first (const CompletedProviderPredecessorReportInvalid) (decodeCleanupRun reportLimit bytes)
      report <- first (const CompletedProviderPredecessorIncomplete) (compactCleanupRun checked)
      validateReport nodes report
    DescriptorBoundCleanupRunTombstoned _ storedDescriptor tombstone
      | storedDescriptor /= descriptorDigest || cleanupRunTombstoneId tombstone /= runId ->
          pure (Left CompletedProviderPredecessorBindingMismatch)
      | otherwise -> do
          response <- observeAuthorityAggregateBackup backup (cleanupRunTombstoneReportDigest tombstone)
          pure $ do
            observed <- first (const CompletedProviderPredecessorBackupUnavailable) response
            (ciphertext, receipt) <- case observed of
              AuthorityAggregateBackupMissing -> Left CompletedProviderPredecessorBackupMissing
              AuthorityAggregateBackupCorrupt _ -> Left CompletedProviderPredecessorBackupCorrupt
              AuthorityAggregateBackupCurrent body confirmation -> Right (body, confirmation)
            expected <-
              first
                (const CompletedProviderPredecessorReportDigestMismatch)
                (mkCleanupDigest (cleanupRunTombstoneReportDigest tombstone))
            unless
              ( authorityBackupDigestText (authorityBackupReceiptDigest receipt) == cleanupDigestText expected
                  && authorityBackupReceiptClass receipt == AuthorityAggregateEnvelope
              )
              (Left CompletedProviderPredecessorBackupReceiptMismatch)
            let bytes = authorityBackupCiphertextBytes ciphertext
            unless
              (cleanupDigestOfBytes bytes == expected)
              (Left CompletedProviderPredecessorReportDigestMismatch)
            report <-
              first (const CompletedProviderPredecessorReportInvalid) (decodeCleanupRunReport reportLimit bytes)
            actual <- validateReport nodes report
            unless (actual == expected) (Left CompletedProviderPredecessorReportDigestMismatch)
            Right actual
  validateReport nodes report = do
    unless
      (cleanupReportRunId report == runId && cleanupReportGraphDigest report == graphDigest)
      (Left CompletedProviderPredecessorBindingMismatch)
    unless
      (sort nodes == Map.keys (cleanupReportNodeStates report))
      (Left CompletedProviderPredecessorNodeSetMismatch)
    unless
      (all successful (Map.elems (cleanupReportNodeStates report)))
      (Left CompletedProviderPredecessorNodeNotSuccessful)
    bytes <-
      first (const CompletedProviderPredecessorReportInvalid) (encodeCleanupRunReport reportLimit report)
    Right (cleanupDigestOfBytes bytes)
  successful state = case state of CleanupNodeCompleted _ CleanupNodeSucceeded -> True; _ -> False
  reportLimit = 1024 * 1024
