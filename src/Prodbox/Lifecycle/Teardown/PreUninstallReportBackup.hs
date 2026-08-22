{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the production reader half of Stage C.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- requires the independent Backup Adapter to read back the exact pre-uninstall
-- cleanup report the Authority committed.
-- "Prodbox.Lifecycle.Teardown.PreUninstallReadiness" states that requirement as
-- a boundary and deliberately owns no client; this module is the join between
-- that boundary and
-- "Prodbox.ControlPlane.CleanupReportBackupClient", which reaches the separate
-- failure domain.
--
-- Four properties carry the design.
--
--   * __The digest is never handed over by either half.__  It is derived from
--     the report's own bytes by the caller that rendered them, told to the
--     Authority as the thing to commit, and asked of the adapter as the thing
--     to confirm.  Neither authority-side surface supplies the value the two
--     are joined on, which is the same shape the Authority restore boundary
--     uses for its @BackupReceipt@.
--
--   * __Absent and unreadable are different answers.__  A report the adapter
--     has never seen is a commit that did not reach the independent domain, and
--     is reported as a missing receipt.  A report whose bytes no longer hash to
--     their own name, or a domain that could not be reached at all, decides
--     nothing and is reported as unobservable.  Collapsing them would let an
--     unreachable adapter read as a clean refusal, which is the fail-open shape
--     an independent read-back exists to exclude.
--
--   * __An observation is bound to the run that asked for it.__  The receipt
--     carries this compiled run's observation scope and graph digest, so
--     'Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal.mkCascadePreUninstallReportEvidence'
--     compares it against the binding rather than against itself, and a report
--     durable under some /other/ run cannot satisfy this one.
--
--   * __The reported identity is the one the adapter confirmed.__  A present
--     observation reports the digest carried on the adapter's own receipt, not
--     the digest the caller asked about, so Stage C's drift check compares two
--     independently sourced values.
--
-- __An honest bound on the drift arm.__  The adapter is content-addressed: an
-- object is named by the digest of its bytes and its read path re-hashes what
-- it read.  A report identity that differs from the committed one therefore
-- presents here as /missing/ (nothing is stored under that name) or as
-- /corrupt/ (the bytes under that name do not hash to it), never as a
-- successfully observed different digest.  Stage C's
-- @PreUninstallReportDigestDrift@ arm stays reachable — the pure kernel is
-- exercised against a boundary that returns one — but this production reader
-- cannot produce it, and saying so is better than implying the refusal is load
-- bearing against this backend.
module Prodbox.Lifecycle.Teardown.PreUninstallReportBackup
  ( cascadeReportReadBackBoundary
  , cascadeReportBackupObservation

    -- * Regression over the package-private fixture
  , PreUninstallReportBackupRegression
  , fixedPreUninstallReportBackupRegression
  , reportBackupRegressionPresentIsObserved
  , reportBackupRegressionPresentCarriesReceiptIdentity
  , reportBackupRegressionMissingIsNotUnobservable
  , reportBackupRegressionCorruptIsUnobservable
  , reportBackupRegressionTransportIsUnobservable
  , reportBackupRegressionObservationSatisfiesItsOwnRun
  , reportBackupRegressionObservationRefusedByAnotherRun
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError (AuthenticatedClientSignerUnavailable)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityCleanupReportBlob)
  , AuthorityBackupCiphertext
  , AuthorityBackupDigest
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient (..)
  , CleanupReportBackupClientError (..)
  , CleanupReportBackupObservation (..)
  , renderCleanupReportBackupClientError
  )
import Prodbox.Lifecycle.CleanupRun (cleanupGraphDigest)

-- The observation type and the report-digest constructor live in the
-- library-internal module, beside the private evidence constructors that
-- consume them; the lifecycle-owned joins ("Prodbox.Lifecycle.HostCleanup*",
-- "Prodbox.Lifecycle.Teardown.PreUninstallReadiness") all reach them there.
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadePreUninstallReportObservation (..)
  , CascadeReportDigest
  , cascadeReportDigestText
  , mkCascadePreUninstallReportEvidence
  , mkCascadeReportDigest
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( DurableReceiptKind (CascadePreUninstallReportReceipt)
  , DurableReceiptObservation (..)
  , DurableReceiptObservationResult (..)
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , ObservationFailure (..)
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( CascadeReportReadBackBoundary (..)
  )

-- | The production Stage-C read-back boundary over the independent adapter.
--
-- The committed digest is closed over rather than passed, because the boundary
-- Stage C injects takes no argument: the question the reader is asked is
-- always "is /this/ report durable in the other failure domain", and the
-- identity is fixed before the commit is attempted.
cascadeReportReadBackBoundary
  :: CleanupReportBackupClient IO
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeReportDigest
  -> CascadeReportReadBackBoundary IO
cascadeReportReadBackBoundary client compiled committedDigest =
  CascadeReportReadBackBoundary
    { readBackPreUninstallReport = do
        observed <-
          observeCleanupReportBackup client (cascadeReportDigestText committedDigest)
        pure (cascadeReportBackupObservation compiled committedDigest observed)
    }

-- | Pure projection of one adapter answer onto the Stage-C observation.
--
-- Exposed so the mapping is exercised without a control plane: every arm the
-- client can return is a case here, and the three dispositions Stage C
-- distinguishes — observed, missing, unobservable — are decided in one place.
cascadeReportBackupObservation
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeReportDigest
  -> Either CleanupReportBackupClientError CleanupReportBackupObservation
  -> CascadePreUninstallReportObservation
cascadeReportBackupObservation compiled committedDigest observed =
  case observed of
    Left err ->
      reported
        committedDigest
        ( DurableReceiptUnobservable
            ( ObservationFailure
                ( "the independent cleanup-report backup domain answered nothing: "
                    <> renderCleanupReportBackupClientError err
                )
            )
        )
    Right CleanupReportBackupMissing ->
      reported committedDigest DurableReceiptMissing
    Right (CleanupReportBackupCorrupt detail) ->
      reported
        committedDigest
        ( DurableReceiptUnobservable
            (ObservationFailure ("the independent cleanup-report backup is corrupt: " <> detail))
        )
    Right (CleanupReportBackupCurrent _ receipt) ->
      case mkCascadeReportDigest
        (authorityBackupDigestText (authorityBackupReceiptDigest receipt)) of
        Left detail ->
          reported
            committedDigest
            ( DurableReceiptUnobservable
                (ObservationFailure ("the independent cleanup-report receipt is malformed: " <> detail))
            )
        Right observedDigest -> reported observedDigest DurableReceiptObserved
 where
  reported digest result =
    CascadePreUninstallReportObservation
      { cascadePreUninstallReportDigest = digest
      , cascadePreUninstallReportReceipt =
          DurableReceiptObservation
            { durableReceiptObservationKind = CascadePreUninstallReportReceipt
            , durableReceiptObservationScope =
                compiledDesiredAbsenceObservationScope compiled
            , durableReceiptObservationGraphDigest =
                cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
            , durableReceiptObservationResult = result
            }
      }

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without a compiled cascade program,
-- an evidence value, or a report digest leaving this package.
data PreUninstallReportBackupRegression = PreUninstallReportBackupRegression
  { reportBackupRegressionPresentIsObserved :: !Bool
  , reportBackupRegressionPresentCarriesReceiptIdentity :: !Bool
  , reportBackupRegressionMissingIsNotUnobservable :: !Bool
  , reportBackupRegressionCorruptIsUnobservable :: !Bool
  , reportBackupRegressionTransportIsUnobservable :: !Bool
  , reportBackupRegressionObservationSatisfiesItsOwnRun :: !Bool
  , reportBackupRegressionObservationRefusedByAnotherRun :: !Bool
  }

-- | Every arm the adapter can answer with, projected against one fixed
-- compiled cascade run.
--
-- The last two are the point of the fixture rather than an extra: an
-- observation is only worth anything if the evidence constructor accepts it
-- for the run that asked and refuses it for a different one, and neither fact
-- is visible from the projection's own result.
fixedPreUninstallReportBackupRegression
  :: Either Text PreUninstallReportBackupRegression
fixedPreUninstallReportBackupRegression = do
  scenario <- fixedReportBackupScenario "cleanup-run/report-backup-fixed-regression"
  other <- fixedReportBackupScenario "cleanup-run/report-backup-fixed-regression-other"
  let compiled = fixedReportBackupCompiled scenario
      committed = fixedReportBackupDigest scenario
      project = cascadeReportBackupObservation compiled committed
      present = project (Right (currentFor scenario))
      missing = project (Right CleanupReportBackupMissing)
      corrupt = project (Right (CleanupReportBackupCorrupt "digest mismatch"))
      unreachable =
        project
          ( Left
              ( CleanupReportBackupTransportFailed
                  (fixedReportBackupTransportFailure scenario)
              )
          )
      resultOf = durableReceiptObservationResult . cascadePreUninstallReportReceipt
      unobservable observation = case resultOf observation of
        DurableReceiptUnobservable _ -> True
        _ -> False
  pure
    PreUninstallReportBackupRegression
      { reportBackupRegressionPresentIsObserved =
          resultOf present == DurableReceiptObserved
      , -- The reported identity is the adapter's, not the caller's question.
        reportBackupRegressionPresentCarriesReceiptIdentity =
          cascadePreUninstallReportDigest present
            == fixedReportBackupReceiptDigest scenario
      , -- Absent is a decided answer; unobservable is not.
        reportBackupRegressionMissingIsNotUnobservable =
          resultOf missing == DurableReceiptMissing && not (unobservable missing)
      , reportBackupRegressionCorruptIsUnobservable = unobservable corrupt
      , -- An adapter that could not be reached decides nothing.  Reporting it
        -- as missing would let an unreachable failure domain read as a clean
        -- "the commit never landed".
        reportBackupRegressionTransportIsUnobservable =
          unobservable unreachable && resultOf unreachable /= DurableReceiptMissing
      , reportBackupRegressionObservationSatisfiesItsOwnRun =
          isRight (mkCascadePreUninstallReportEvidence compiled present)
      , reportBackupRegressionObservationRefusedByAnotherRun =
          not
            ( isRight
                ( mkCascadePreUninstallReportEvidence
                    (fixedReportBackupCompiled other)
                    present
                )
            )
      }
 where
  isRight = either (const False) (const True)

-- | Everything one fixed compiled cascade run supplies to this projection.
data FixedReportBackupScenario = FixedReportBackupScenario
  { fixedReportBackupCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedReportBackupDigest :: !CascadeReportDigest
  , fixedReportBackupReceiptDigest :: !CascadeReportDigest
  , fixedReportBackupCiphertext :: !AuthorityBackupCiphertext
  , fixedReportBackupBackupDigest :: !AuthorityBackupDigest
  , fixedReportBackupTransportFailure :: !AuthenticatedClientError
  }

-- | The adapter's present answer for this scenario.
--
-- Its receipt is built from the ciphertext's own digest, which is what the
-- production client has already checked against the digest it asked for, so
-- the fixture cannot describe a receipt the client would have refused.
currentFor :: FixedReportBackupScenario -> CleanupReportBackupObservation
currentFor scenario =
  CleanupReportBackupCurrent
    (fixedReportBackupCiphertext scenario)
    AuthorityBackupReceipt
      { authorityBackupReceiptClass = AuthorityCleanupReportBlob
      , authorityBackupReceiptDigest = fixedReportBackupBackupDigest scenario
      , authorityBackupReceiptObjectVersion = "fixed-report-backup-version"
      }

fixedReportBackupScenario :: Text -> Either Text FixedReportBackupScenario
fixedReportBackupScenario rawRunId = do
  compiled <-
    withCascadePreUninstallInputsInternal
      rawRunId
      (\program _run _absence _credentials _audit _custody -> program)
  ciphertext <- mkAuthorityBackupCiphertext "fixed-pre-uninstall-report-bytes"
  let backupDigest = authorityBackupCiphertextDigest ciphertext
  receiptDigest <- mkCascadeReportDigest (authorityBackupDigestText backupDigest)
  committed <- mkCascadeReportDigest (authorityBackupDigestText backupDigest)
  pure
    FixedReportBackupScenario
      { fixedReportBackupCompiled = compiled
      , fixedReportBackupDigest = committed
      , fixedReportBackupReceiptDigest = receiptDigest
      , fixedReportBackupCiphertext = ciphertext
      , fixedReportBackupBackupDigest = backupDigest
      , fixedReportBackupTransportFailure =
          AuthenticatedClientSignerUnavailable "the backup adapter route is not reachable"
      }
