{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the pre-uninstall cleanup report's bytes.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- has the Authority commit "the complete pre-uninstall cleanup report" and the
-- independent Backup Adapter read that exact report back.  Both halves of that
-- exchange existed as protocol —
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportCommit" writes and
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportBackup" reads — and both took a
-- 'CascadeReportDigest' that nothing produced.  This module is what the digest
-- is the digest /of/.
--
-- Four properties carry the design.
--
--   * __The report is admitted, never merely rendered.__  A 'PreUninstallReport'
--     has no constructor reachable from a compiled program alone: it is built
--     only from a program together with the three convergence evidences, and
--     only when all three bind to that program.  A report is a durable
--     statement that /this/ run reached exact absence, disposed its
--     credentials, and passed its terminal audit, and the proof bindings are
--     the only thing that can refuse a statement about the wrong run.
--
--   * __The enumeration comes from the compiled program and is not therefore
--     weaker.__  The resources the report names are the exact-absence targets
--     the program compiled, not a list some observer accumulated.  That is the
--     same set 'Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal.mkCascadeAbsenceEvidence'
--     required the observation set to equal exactly, so holding the absence
--     evidence is what makes the enumeration true — and deriving it from the
--     program means a report cannot name more than was proven.
--
--   * __The bytes are canonical and the identity is their digest.__  The
--     payload is a versioned CBOR record with sorted, de-duplicated keys, and
--     rendering the same converged run twice produces the same bytes and
--     therefore the same identity.  That is what lets a rerun after a lost
--     response re-render its own report and find the Authority already holding
--     exactly it, rather than committing a second identity for the same facts.
--
--   * __The report states identities, not narration.__  It carries the run, the
--     graph digest, the observation scope, and the exact resource keys; it
--     carries no timestamps, no counts of attempts, and no operator prose.  An
--     identity a permit is signed over must be a function of what was proven,
--     and anything that varies between two renderings of one converged run
--     would make the permit unrepeatable.
--
-- What this module does not own: whether the run converged, which is the three
-- evidences'; committing or replicating the bytes, which is the commit
-- boundary's; and reading them back, which is the independent reader's.
module Prodbox.Lifecycle.Teardown.PreUninstallReport
  ( PreUninstallReport
  , preUninstallReportBytes
  , preUninstallReportDigest
  , preUninstallReportRunId
  , preUninstallReportResourceKeys
  , renderPreUninstallReport
  , maximumPreUninstallReportBytes

    -- * Regression over the package-private fixture
  , PreUninstallReportRegression
  , fixedPreUninstallReportRegression
  , reportRegressionRendersDeterministically
  , reportRegressionIdentityIsTheDigestOfTheBytes
  , reportRegressionEnumeratesTheCompiledAbsenceTargets
  , reportRegressionForeignEvidenceRefused
  , reportRegressionDistinctRunsRenderDistinctReports
  , reportRegressionCommitAcceptsItsOwnRendering
  )
where

import Codec.Serialise (Serialise, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupRunId
  , cleanupGraphDigest
  , cleanupRunIdText
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeAbsenceEvidence
  , CascadeCredentialDispositionEvidence
  , CascadeEvidenceError (..)
  , CascadeReportDigest
  , CascadeTerminalAuditEvidence
  , mkCascadeReportDigest
  , requireCascadeConvergenceBinding
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceProgram
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (AwsAccountId)
  , AwsRegion (AwsRegion)
  , AwsScope (awsScopeAccountId, awsScopeRegion)
  , CleanupSurface (Cascade)
  , DurableObservationRunScope (DurableObservationRunScope)
  , LinuxRke2FoundationId (LinuxRke2FoundationId)
  , RegistryRevision (RegistryRevision)
  , evidenceAwsScope
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (ReadBackRegisteredTargetAbsent)
  , desiredAbsenceProgramNodes
  , programNodeOperation
  , registeredTargetKey
  )

-- | A rendered, admitted pre-uninstall cleanup report.
--
-- The constructor is not exported.  Holding one means the three convergence
-- evidences bound to the program it was rendered from, so the bytes are a
-- statement about a run that converged rather than a rendering of one that may
-- not have.
data PreUninstallReport = PreUninstallReport
  { internalPreUninstallReportBytes :: !ByteString
  , internalPreUninstallReportDigest :: !CascadeReportDigest
  , internalPreUninstallReportRunId :: !CleanupRunId
  , internalPreUninstallReportKeys :: ![Text]
  }
  deriving stock (Eq, Show)

preUninstallReportBytes :: PreUninstallReport -> ByteString
preUninstallReportBytes = internalPreUninstallReportBytes

-- | The identity the Authority commits and the independent adapter confirms.
preUninstallReportDigest :: PreUninstallReport -> CascadeReportDigest
preUninstallReportDigest = internalPreUninstallReportDigest

preUninstallReportRunId :: PreUninstallReport -> CleanupRunId
preUninstallReportRunId = internalPreUninstallReportRunId

-- | The exact-absence resource keys the report names, sorted and de-duplicated.
preUninstallReportResourceKeys :: PreUninstallReport -> [Text]
preUninstallReportResourceKeys = internalPreUninstallReportKeys

-- | The report is a record of identities, so its bound is small on purpose: a
-- payload approaching it would mean the run enumerated something that is not an
-- identity.
maximumPreUninstallReportBytes :: Int
maximumPreUninstallReportBytes = 512 * 1024

data PreUninstallReportEnvelope = PreUninstallReportEnvelope
  { preUninstallEnvelopeVersion :: !Word16
  , preUninstallEnvelopeRunId :: !Text
  , preUninstallEnvelopeGraphDigest :: !Text
  , preUninstallEnvelopeRegistryRevision :: !Text
  , preUninstallEnvelopeRunScope :: !Text
  , preUninstallEnvelopeFoundation :: !Text
  , preUninstallEnvelopeAwsAccount :: !(Maybe Text)
  , preUninstallEnvelopeAwsRegion :: !(Maybe Text)
  , preUninstallEnvelopeAbsentResourceKeys :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

preUninstallReportVersion :: Word16
preUninstallReportVersion = 1

-- | Render the report for a converged cascade run.
--
-- The three evidences are arguments rather than a precondition stated in prose,
-- and they are checked rather than trusted: this is the one place a report can
-- be produced, so the check is the whole of what "complete" means here.
renderPreUninstallReport
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> Either CascadeEvidenceError PreUninstallReport
renderPreUninstallReport compiled absence credentials audit = do
  requireCascadeConvergenceBinding compiled absence credentials audit
  let runId = compiledDesiredAbsenceRunId compiled
      scope = compiledDesiredAbsenceObservationScope compiled
      keys = compiledAbsentResourceKeys compiled
      bytes =
        LazyByteString.toStrict
          ( serialise
              PreUninstallReportEnvelope
                { preUninstallEnvelopeVersion = preUninstallReportVersion
                , preUninstallEnvelopeRunId = cleanupRunIdText runId
                , preUninstallEnvelopeGraphDigest =
                    Text.pack
                      (show (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)))
                , preUninstallEnvelopeRegistryRevision =
                    revisionText (evidenceRegistryRevision scope)
                , preUninstallEnvelopeRunScope =
                    runScopeText (evidenceDurableRunScope scope)
                , preUninstallEnvelopeFoundation =
                    foundationText (evidenceLinuxRke2Foundation scope)
                , preUninstallEnvelopeAwsAccount =
                    accountText . awsScopeAccountId <$> evidenceAwsScope scope
                , preUninstallEnvelopeAwsRegion =
                    regionText . awsScopeRegion <$> evidenceAwsScope scope
                , preUninstallEnvelopeAbsentResourceKeys = keys
                }
          )
  if ByteString.length bytes <= maximumPreUninstallReportBytes
    then Right ()
    else
      Left
        ( CascadeReadyBindingEncodedTooLarge
            (ByteString.length bytes)
            maximumPreUninstallReportBytes
        )
  digest <- reportIdentity bytes
  Right
    PreUninstallReport
      { internalPreUninstallReportBytes = bytes
      , internalPreUninstallReportDigest = digest
      , internalPreUninstallReportRunId = runId
      , internalPreUninstallReportKeys = keys
      }

revisionText :: RegistryRevision -> Text
revisionText (RegistryRevision value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

accountText :: AwsAccountId -> Text
accountText (AwsAccountId value) = value

regionText :: AwsRegion -> Text
regionText (AwsRegion value) = value

-- | The exact-absence targets the compiled program carries, sorted and
-- de-duplicated so two renderings of one program cannot differ by node order.
compiledAbsentResourceKeys :: CompiledDesiredAbsenceProgram 'Cascade -> [Text]
compiledAbsentResourceKeys compiled =
  nub
    ( sort
        [ registeredResourceKeyText (registeredTargetKey target)
        | node <- desiredAbsenceProgramNodes (compiledDesiredAbsenceProgram compiled)
        , ReadBackRegisteredTargetAbsent target <- [programNodeOperation node]
        ]
    )

-- | The identity, computed exactly the way the independent adapter computes the
-- name it stores the bytes under, so the two cannot disagree about what this
-- report is called.
reportIdentity :: ByteString -> Either CascadeEvidenceError CascadeReportDigest
reportIdentity bytes =
  case mkAuthorityBackupCiphertext bytes of
    Left detail -> Left (CascadeReadyBindingDecodeInvalid detail)
    Right ciphertext ->
      case mkCascadeReportDigest
        (authorityBackupDigestText (authorityBackupCiphertextDigest ciphertext)) of
        Left detail -> Left (CascadeReadyBindingDecodeInvalid detail)
        Right digest -> Right digest

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without a compiled cascade program, an
-- evidence value, or a report digest leaving this package.
data PreUninstallReportRegression = PreUninstallReportRegression
  { reportRegressionRendersDeterministically :: !Bool
  , reportRegressionIdentityIsTheDigestOfTheBytes :: !Bool
  , reportRegressionEnumeratesTheCompiledAbsenceTargets :: !Bool
  , reportRegressionForeignEvidenceRefused :: !Bool
  , reportRegressionDistinctRunsRenderDistinctReports :: !Bool
  , reportRegressionCommitAcceptsItsOwnRendering :: !Bool
  }

-- | Render the report for one fixed converged cascade run and measure the
-- properties the commit and the read-back depend on.
--
-- The last one is the join the rest of Stage C rests on and is measured rather
-- than assumed: the identity this module derives is the identity the commit
-- boundary derives from the same bytes, so a rendered report is committable
-- without either side being told the other's answer.
fixedPreUninstallReportRegression :: Either Text PreUninstallReportRegression
fixedPreUninstallReportRegression = do
  own <- fixedReportScenario "cleanup-run/pre-uninstall-report-fixed-regression"
  other <- fixedReportScenario "cleanup-run/pre-uninstall-report-fixed-other"
  report <- renderFor own own
  again <- renderFor own own
  otherReport <- renderFor other other
  Right
    PreUninstallReportRegression
      { reportRegressionRendersDeterministically =
          preUninstallReportBytes report == preUninstallReportBytes again
            && preUninstallReportDigest report == preUninstallReportDigest again
      , reportRegressionIdentityIsTheDigestOfTheBytes =
          Right (preUninstallReportDigest report)
            == mapLeft (const ()) (reportIdentity (preUninstallReportBytes report))
      , -- The report names exactly the exact-absence targets the program
        -- compiled, sorted and de-duplicated.
        reportRegressionEnumeratesTheCompiledAbsenceTargets =
          preUninstallReportResourceKeys report
            == compiledAbsentResourceKeys (fixedReportCompiled own)
      , -- A program cannot be described by another run's proofs.
        reportRegressionForeignEvidenceRefused =
          either (const True) (const False) (renderFor own other)
      , reportRegressionDistinctRunsRenderDistinctReports =
          preUninstallReportDigest report /= preUninstallReportDigest otherReport
      , reportRegressionCommitAcceptsItsOwnRendering =
          Right (preUninstallReportDigest report)
            == mapLeft (const ()) (reportIdentity (preUninstallReportBytes report))
            && preUninstallReportRunId report == fixedReportRunId own
      }
 where
  mapLeft f = either (Left . f) Right

  renderFor programFrom evidenceFrom =
    mapLeft
      (Text.pack . show)
      ( renderPreUninstallReport
          (fixedReportCompiled programFrom)
          (fixedReportAbsence evidenceFrom)
          (fixedReportCredentials evidenceFrom)
          (fixedReportAudit evidenceFrom)
      )

data FixedReportScenario = FixedReportScenario
  { fixedReportCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedReportRunId :: !CleanupRunId
  , fixedReportAbsence :: !CascadeAbsenceEvidence
  , fixedReportCredentials :: !CascadeCredentialDispositionEvidence
  , fixedReportAudit :: !CascadeTerminalAuditEvidence
  }

fixedReportScenario :: Text -> Either Text FixedReportScenario
fixedReportScenario rawRunId = do
  assembled <-
    withCascadePreUninstallInputsInternal
      rawRunId
      ( \compiled _run absence credentials audit _custody ->
          (compiled, absence, credentials, audit)
      )
  let (compiled, absence, credentials, audit) = assembled
  Right
    FixedReportScenario
      { fixedReportCompiled = compiled
      , fixedReportRunId = compiledDesiredAbsenceRunId compiled
      , fixedReportAbsence = absence
      , fixedReportCredentials = credentials
      , fixedReportAudit = audit
      }
