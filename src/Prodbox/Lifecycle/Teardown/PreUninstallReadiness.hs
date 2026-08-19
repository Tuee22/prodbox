{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: Stage C of the recover-to-clean cascade — the durability
-- protocol that turns exact convergence into 'ReadyToUninstallEvidence'.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- says the Lifecycle Authority commits the complete pre-uninstall cleanup
-- report, the independent Backup Adapter reads back that exact report, and the
-- Authority signs the one-shot local-completion permit; only readiness bound to
-- the same cleanup run admits local RKE2 uninstall.  Every value in that
-- sentence already existed as a type.  What did not exist was the sequence:
-- nothing in the repository committed a report, read it back, and composed the
-- result, so a production cascade could not reach readiness at all.
--
-- Four properties carry the design.
--
--   * __The read-back decides durability; the commit response does not.__  The
--     read-back runs after /every/ commit outcome, including a refusal.  A
--     mutation that reported success and left nothing durable is not ready, and
--     a mutation whose response was lost — or that reported a refusal while the
--     write had already landed — is disambiguated by the observation rather
--     than by the response.  This is the applied-but-response-lost case, and
--     reading readiness out of the commit response is exactly the defect an
--     independent read-back exists to exclude.
--
--   * __The reader is a separate boundary from the writer.__  Committing and
--     reading back are two records, not two fields of one, because the surface
--     that claims to have written the report must not be the surface that
--     decides it is durable.  In production the writer is the Authority and the
--     reader is the Backup Adapter; the type states the requirement, and the
--     wiring that satisfies it belongs to the composition that owns both
--     clients.
--
--   * __The permit is signed over what was read back.__  A digest that differs
--     between the commit and the observation refuses before a permit is asked
--     for, so the Authority can never sign a permit over a report identity that
--     does not exist durably.
--
--   * __Readiness is the composition, never a step.__  The absence, credential,
--     and terminal-audit evidences from the earlier nodes are inputs; this
--     module adds the report and the permit and hands all five to the private
--     readiness constructor.  It cannot mint readiness from its own two steps,
--     and it does not observe or mutate any AWS or Kubernetes resource.
--
-- The pure kernel sequences and refuses.  The only effects live behind the two
-- injected boundaries, so the fault matrix — a refused commit, a lost response,
-- a missing receipt, an unobservable durable store, a digest that changed under
-- the run, an unavailable or foreign permit — is exercised without an
-- Authority.
--
-- What this module does not own: the /content/ of the pre-uninstall report,
-- which belongs to "Prodbox.Lifecycle.Teardown.Report"; the one-shot semantics
-- of the permit, which the Authority enforces where it signs it; and the
-- uninstall itself, which consumes the readiness this produces through
-- "Prodbox.Lifecycle.HostCleanupRunner".
module Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( -- * The two boundaries
    CascadeReportCommitBoundary (..)
  , CascadeReportReadBackBoundary (..)

    -- * Running Stage C
  , PreUninstallReadinessRefusal (..)
  , renderPreUninstallReadinessRefusal
  , PreUninstallReadinessOutcome (..)
  , PreUninstallReadinessRun (..)
  , preUninstallReadinessEvidence
  , establishPreUninstallReadiness

    -- * Regression over the package-private fixture
  , PreUninstallReadinessRegression
  , fixedPreUninstallReadinessRegression
  , preUninstallReadinessRegressionReadyFromAppliedCommit
  , preUninstallReadinessRegressionReadyFromLostResponse
  , preUninstallReadinessRegressionReadyFromRefusedCommitThatLanded
  , preUninstallReadinessRegressionAppliedButNotDurableRefused
  , preUninstallReadinessRegressionUnobservableRefused
  , preUninstallReadinessRegressionDigestDriftRefused
  , preUninstallReadinessRegressionPermitUnavailableRefused
  , preUninstallReadinessRegressionForeignPermitRefused
  , preUninstallReadinessRegressionReadBackAlwaysAttempted
  , preUninstallReadinessRegressionDriftNeverRequestsPermit
  , preUninstallReadinessRegressionReadinessCarriesReadBackIdentity
  , fixedPreUninstallReadinessRefusals
  )
where

import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun (cleanupGraphDigest)
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeAbsenceEvidence
  , CascadeCredentialDispositionEvidence
  , CascadeEvidenceError
  , CascadeLocalOperationReferences (..)
  , CascadePreUninstallReportObservation (..)
  , CascadeReportDigest
  , CascadeTerminalAuditEvidence
  , LocalCompletionPermitGrant (..)
  , LocalCompletionPermitId
  , ReadyToUninstallEvidence
  , bindLocalCompletionPermit
  , cascadeLocalOperationReferences
  , cascadeReportDigestText
  , mkCascadePreUninstallReportEvidence
  , mkCascadeReportDigest
  , mkLocalCompletionPermitId
  , mkReadyToUninstallEvidence
  , readyToUninstallReportDigest
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( DurableReceiptKind (CascadePreUninstallReportReceipt)
  , DurableReceiptObservation (..)
  , DurableReceiptObservationResult (..)
  , TeardownMutationResult (..)
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , ObservationFailure (..)
  )

-- ---------------------------------------------------------------------------
-- The two boundaries
-- ---------------------------------------------------------------------------

-- | The writing half: the Lifecycle Authority.
--
-- Committing the report and signing the permit are the two authority-bearing
-- actions of Stage C, and they share a record because they share a principal.
-- Neither of them decides durability.
data CascadeReportCommitBoundary m = CascadeReportCommitBoundary
  { commitPreUninstallReport :: CascadeReportDigest -> m TeardownMutationResult
  , grantLocalCompletionPermit
      :: CascadeReportDigest -> m (Either Text LocalCompletionPermitGrant)
  }

-- | The reading half: the independent Backup Adapter.
--
-- It is a separate record rather than a third field, because the whole content
-- of node 7's read-back requirement is that the reader is not the writer.  A
-- composition that wires one client into both is visibly doing so.
newtype CascadeReportReadBackBoundary m = CascadeReportReadBackBoundary
  { readBackPreUninstallReport :: m CascadePreUninstallReportObservation
  }

-- ---------------------------------------------------------------------------
-- Running Stage C
-- ---------------------------------------------------------------------------

-- | Why Stage C did not produce readiness.
data PreUninstallReadinessRefusal
  = -- | The report identity that came back is not the one that was committed.
    -- Refused before a permit is requested, so the Authority is never asked to
    -- sign over a report identity nothing durably holds.
    PreUninstallReportDigestDrift !CascadeReportDigest !CascadeReportDigest
  | -- | The independent read-back did not establish the report.  This covers a
    -- missing receipt, an unobservable durable store, and a receipt bound to
    -- another run or scope; the evidence kernel's own error is preserved.
    PreUninstallReportNotDurable !CascadeEvidenceError
  | -- | The Authority did not produce a permit.
    PreUninstallPermitUnavailable !Text
  | -- | A permit was produced and does not bind to this compiled run.
    PreUninstallPermitUnbound !CascadeEvidenceError
  | -- | Every component was produced and the readiness constructor refused the
    -- composition.
    PreUninstallReadinessRefused !CascadeEvidenceError
  deriving (Eq, Show)

renderPreUninstallReadinessRefusal :: PreUninstallReadinessRefusal -> String
renderPreUninstallReadinessRefusal = \case
  PreUninstallReportDigestDrift committed observed ->
    "Stage C refuses: the pre-uninstall report committed as `"
      ++ Text.unpack (cascadeReportDigestText committed)
      ++ "` was independently read back as `"
      ++ Text.unpack (cascadeReportDigestText observed)
      ++ "`. A permit is not requested over a report identity that is not durable."
  PreUninstallReportNotDurable err ->
    "Stage C refuses: the pre-uninstall report is not independently durable: "
      ++ show err
  PreUninstallPermitUnavailable detail ->
    "Stage C refuses: the Authority produced no local-completion permit: "
      ++ Text.unpack detail
  PreUninstallPermitUnbound err ->
    "Stage C refuses: the local-completion permit does not bind to this run: "
      ++ show err
  PreUninstallReadinessRefused err ->
    "Stage C refuses: readiness could not be composed: " ++ show err

data PreUninstallReadinessOutcome
  = PreUninstallReady !ReadyToUninstallEvidence
  | PreUninstallNotReady !PreUninstallReadinessRefusal
  deriving (Eq, Show)

-- | One run of Stage C.
--
-- The commit result and the independent observation are both retained
-- regardless of the outcome, because an incomplete cascade reports what it
-- attempted and what it saw, and those are two different facts.
data PreUninstallReadinessRun = PreUninstallReadinessRun
  { preUninstallReadinessCommit :: !TeardownMutationResult
  , preUninstallReadinessObservation :: !CascadePreUninstallReportObservation
  , preUninstallReadinessOutcome :: !PreUninstallReadinessOutcome
  }
  deriving (Eq, Show)

preUninstallReadinessEvidence
  :: PreUninstallReadinessRun -> Maybe ReadyToUninstallEvidence
preUninstallReadinessEvidence run =
  case preUninstallReadinessOutcome run of
    PreUninstallReady ready -> Just ready
    PreUninstallNotReady _ -> Nothing

-- | Commit the pre-uninstall report, independently read it back, obtain the
-- one-shot permit, and compose readiness.
--
-- The read-back is unconditional.  A commit that reported success proves
-- nothing about durability, and a commit that reported a refusal or lost its
-- response may still have landed; the observation is what separates those
-- cases, so suppressing it on either would decide the run from the weaker
-- fact.
establishPreUninstallReadiness
  :: (Monad m)
  => CascadeReportCommitBoundary m
  -> CascadeReportReadBackBoundary m
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> CascadeReportDigest
  -> m PreUninstallReadinessRun
establishPreUninstallReadiness
  authority
  independent
  compiled
  absence
  credentials
  audit
  committedDigest = do
    commit <- commitPreUninstallReport authority committedDigest
    observation <- readBackPreUninstallReport independent
    let observedDigest = cascadePreUninstallReportDigest observation
        finish outcome =
          PreUninstallReadinessRun
            { preUninstallReadinessCommit = commit
            , preUninstallReadinessObservation = observation
            , preUninstallReadinessOutcome = outcome
            }
    if observedDigest /= committedDigest
      then
        pure
          ( finish
              ( PreUninstallNotReady
                  (PreUninstallReportDigestDrift committedDigest observedDigest)
              )
          )
      else case mkCascadePreUninstallReportEvidence compiled observation of
        Left err ->
          pure (finish (PreUninstallNotReady (PreUninstallReportNotDurable err)))
        Right report -> do
          granted <- grantLocalCompletionPermit authority observedDigest
          pure $ case granted of
            Left detail ->
              finish (PreUninstallNotReady (PreUninstallPermitUnavailable detail))
            Right grant ->
              case bindLocalCompletionPermit compiled grant of
                Left err ->
                  finish (PreUninstallNotReady (PreUninstallPermitUnbound err))
                Right permit ->
                  case mkReadyToUninstallEvidence
                    compiled
                    absence
                    credentials
                    audit
                    report
                    permit of
                    Left err ->
                      finish (PreUninstallNotReady (PreUninstallReadinessRefused err))
                    Right ready -> finish (PreUninstallReady ready)

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without any authority-bearing value
-- leaving this package.
data PreUninstallReadinessRegression = PreUninstallReadinessRegression
  { preUninstallReadinessRegressionReadyFromAppliedCommit :: !Bool
  , preUninstallReadinessRegressionReadyFromLostResponse :: !Bool
  , preUninstallReadinessRegressionReadyFromRefusedCommitThatLanded :: !Bool
  , preUninstallReadinessRegressionAppliedButNotDurableRefused :: !Bool
  , preUninstallReadinessRegressionUnobservableRefused :: !Bool
  , preUninstallReadinessRegressionDigestDriftRefused :: !Bool
  , preUninstallReadinessRegressionPermitUnavailableRefused :: !Bool
  , preUninstallReadinessRegressionForeignPermitRefused :: !Bool
  , preUninstallReadinessRegressionReadBackAlwaysAttempted :: !Bool
  , preUninstallReadinessRegressionDriftNeverRequestsPermit :: !Bool
  , preUninstallReadinessRegressionReadinessCarriesReadBackIdentity :: !Bool
  }

fixedPreUninstallReadinessRegression
  :: IO (Either Text PreUninstallReadinessRegression)
fixedPreUninstallReadinessRegression =
  case fixedStageCScenario of
    Left err -> pure (Left err)
    Right scenario -> Right <$> runFixedStageCRegression scenario

-- | One inhabitant of every refusal arm, each produced by actually running
-- Stage C against the fault that causes it.
--
-- It exists because 'CascadeReportDigest' and 'CascadeEvidenceError' are not
-- constructible outside this package, so a dependent test could otherwise
-- render only the arms some scenario happened to reach — which is exactly the
-- coverage a closed renderer is supposed to have.  Building each one by
-- running the protocol rather than by hand also keeps the list honest: an arm
-- the protocol stops producing disappears from it instead of surviving as an
-- authored constant.
fixedPreUninstallReadinessRefusals
  :: Either Text [PreUninstallReadinessRefusal]
fixedPreUninstallReadinessRefusals = do
  scenario <- fixedStageCScenario
  other <- fixedStageCScenarioFor "cleanup-run/stage-c-fixed-regression-other"
  traverse
    refusalOf
    [ runStageC
        scenario
        scenario
        (appliedWith (permitFrom scenario))
        (observedFor scenario (fixedStageCOtherDigest scenario))
    , runStageC scenario scenario (appliedWith (permitFrom scenario)) (missingFor scenario)
    , runStageC
        scenario
        scenario
        (appliedWith (const (Left "authority unavailable")))
        (observedFor scenario (fixedStageCDigest scenario))
    , runStageC
        scenario
        scenario
        (appliedWith (foreignPermitFrom scenario))
        (observedFor scenario (fixedStageCDigest scenario))
    , runStageC
        scenario
        other
        (appliedWith (permitFrom scenario))
        (observedFor scenario (fixedStageCDigest scenario))
    ]
 where
  refusalOf run = case preUninstallReadinessOutcome run of
    PreUninstallNotReady refusal -> Right refusal
    PreUninstallReady _ ->
      Left "a Stage C fault scenario reached readiness instead of refusing"

-- | Run Stage C for one scenario, optionally taking the absence evidence from
-- a second one so the readiness composition itself can be made to refuse.
runStageC
  :: FixedStageCScenario
  -> FixedStageCScenario
  -> CascadeReportCommitBoundary Identity
  -> CascadeReportReadBackBoundary Identity
  -> PreUninstallReadinessRun
runStageC scenario absenceFrom authority independent =
  runIdentity
    ( establishPreUninstallReadiness
        authority
        independent
        (fixedStageCCompiled scenario)
        (fixedStageCAbsence absenceFrom)
        (fixedStageCCredentials scenario)
        (fixedStageCAudit scenario)
        (fixedStageCDigest scenario)
    )

appliedWith
  :: (CascadeReportDigest -> Either Text LocalCompletionPermitGrant)
  -> CascadeReportCommitBoundary Identity
appliedWith permit =
  CascadeReportCommitBoundary
    { commitPreUninstallReport = \_ -> Identity TeardownMutationApplied
    , grantLocalCompletionPermit = Identity . permit
    }

permitFrom
  :: FixedStageCScenario
  -> CascadeReportDigest
  -> Either Text LocalCompletionPermitGrant
permitFrom scenario digest =
  Right (grantFor scenario digest (fixedStageCPermitId scenario))

foreignPermitFrom
  :: FixedStageCScenario
  -> CascadeReportDigest
  -> Either Text LocalCompletionPermitGrant
foreignPermitFrom scenario digest =
  Right
    (grantFor scenario digest (fixedStageCPermitId scenario))
      { localCompletionGrantOperationReferences =
          swapOperations (fixedStageCOperations scenario)
      }

observedFor
  :: FixedStageCScenario
  -> CascadeReportDigest
  -> CascadeReportReadBackBoundary Identity
observedFor scenario digest =
  CascadeReportReadBackBoundary
    { readBackPreUninstallReport =
        Identity (reportObservation scenario digest DurableReceiptObserved)
    }

missingFor :: FixedStageCScenario -> CascadeReportReadBackBoundary Identity
missingFor scenario =
  CascadeReportReadBackBoundary
    { readBackPreUninstallReport =
        Identity
          ( reportObservation
              scenario
              (fixedStageCDigest scenario)
              DurableReceiptMissing
          )
    }

-- | Everything one fixed compiled cascade run supplies to Stage C.
data FixedStageCScenario = FixedStageCScenario
  { fixedStageCCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedStageCAbsence :: !CascadeAbsenceEvidence
  , fixedStageCCredentials :: !CascadeCredentialDispositionEvidence
  , fixedStageCAudit :: !CascadeTerminalAuditEvidence
  , fixedStageCDigest :: !CascadeReportDigest
  , fixedStageCOtherDigest :: !CascadeReportDigest
  , fixedStageCOperations :: !CascadeLocalOperationReferences
  , fixedStageCPermitId :: !LocalCompletionPermitId
  }

fixedStageCScenario :: Either Text FixedStageCScenario
fixedStageCScenario = fixedStageCScenarioFor "cleanup-run/stage-c-fixed-regression"

fixedStageCScenarioFor :: Text -> Either Text FixedStageCScenario
fixedStageCScenarioFor rawRunId = do
  assembled <-
    withCascadePreUninstallInputsInternal
      rawRunId
      (\compiled _run absence credentials audit -> (compiled, absence, credentials, audit))
  let (compiled, absence, credentials, audit) = assembled
  digest <- mkCascadeReportDigest (Text.replicate 64 "b")
  otherDigest <- mkCascadeReportDigest (Text.replicate 64 "c")
  operations <-
    either (Left . Text.pack . show) Right (cascadeLocalOperationReferences compiled)
  permitId <- mkLocalCompletionPermitId (rawRunId <> "/permit")
  pure
    FixedStageCScenario
      { fixedStageCCompiled = compiled
      , fixedStageCAbsence = absence
      , fixedStageCCredentials = credentials
      , fixedStageCAudit = audit
      , fixedStageCDigest = digest
      , fixedStageCOtherDigest = otherDigest
      , fixedStageCOperations = operations
      , fixedStageCPermitId = permitId
      }

runFixedStageCRegression
  :: FixedStageCScenario -> IO PreUninstallReadinessRegression
runFixedStageCRegression scenario = do
  readBackCounter <- newIORef (0 :: Int)
  refusedRun <-
    runCounted
      readBackCounter
      (authorityWith (TeardownMutationRefused "authority refused") permitFor)
      (observedReadBack (fixedStageCDigest scenario))
  permitCounter <- newIORef (0 :: Int)
  driftRun <-
    runCountingPermits
      permitCounter
      (observedReadBack (fixedStageCOtherDigest scenario))
  permitRequests <- readIORef permitCounter
  let ready outcome = case outcome of
        PreUninstallReady _ -> True
        PreUninstallNotReady _ -> False
      refusedWith predicate outcome = case outcome of
        PreUninstallReady _ -> False
        PreUninstallNotReady refusal -> predicate refusal
      applied = TeardownMutationApplied
      lost = TeardownMutationResponseLost "response lost"
  attempts <- readIORef readBackCounter
  pure
    PreUninstallReadinessRegression
      { preUninstallReadinessRegressionReadyFromAppliedCommit =
          ready
            ( preUninstallReadinessOutcome
                (pureRun (authorityWith applied permitFor) (observedReadBack committed))
            )
      , preUninstallReadinessRegressionReadyFromLostResponse =
          ready
            ( preUninstallReadinessOutcome
                (pureRun (authorityWith lost permitFor) (observedReadBack committed))
            )
      , preUninstallReadinessRegressionReadyFromRefusedCommitThatLanded =
          ready (preUninstallReadinessOutcome refusedRun)
      , preUninstallReadinessRegressionAppliedButNotDurableRefused =
          refusedWith
            isNotDurable
            ( preUninstallReadinessOutcome
                (pureRun (authorityWith applied permitFor) (missingReadBack committed))
            )
      , preUninstallReadinessRegressionUnobservableRefused =
          refusedWith
            isNotDurable
            ( preUninstallReadinessOutcome
                (pureRun (authorityWith applied permitFor) (unobservableReadBack committed))
            )
      , preUninstallReadinessRegressionDigestDriftRefused =
          refusedWith
            isDigestDrift
            ( preUninstallReadinessOutcome
                ( pureRun
                    (authorityWith applied permitFor)
                    (observedReadBack (fixedStageCOtherDigest scenario))
                )
            )
      , preUninstallReadinessRegressionPermitUnavailableRefused =
          refusedWith
            isPermitUnavailable
            ( preUninstallReadinessOutcome
                ( pureRun
                    (authorityWith applied (const (Left "permit unavailable")))
                    (observedReadBack committed)
                )
            )
      , preUninstallReadinessRegressionForeignPermitRefused =
          refusedWith
            isPermitUnbound
            ( preUninstallReadinessOutcome
                (pureRun (authorityWith applied foreignPermitFor) (observedReadBack committed))
            )
      , -- The read-back ran even though the commit reported a refusal, which
        -- is the whole reason the refused-but-landed case above can be ready.
        preUninstallReadinessRegressionReadBackAlwaysAttempted = attempts == 1
      , -- A drifted report identity is refused before the Authority is asked
        -- for anything, so the permit boundary is never reached.  This is the
        -- observable half of \"the permit is signed over what was read back\":
        -- once a permit is requested at all, the two digests are equal by
        -- construction, so the property that can be measured is that a
        -- disagreement never gets that far.
        preUninstallReadinessRegressionDriftNeverRequestsPermit =
          permitRequests == 0 && refusedWith isDigestDrift (preUninstallReadinessOutcome driftRun)
      , preUninstallReadinessRegressionReadinessCarriesReadBackIdentity =
          readinessCarriesReadBackIdentity
            (pureRun (authorityWith applied permitFor) (observedReadBack committed))
      }
 where
  committed = fixedStageCDigest scenario

  pureRun authority independent =
    runIdentity
      ( establishPreUninstallReadiness
          authority
          independent
          (fixedStageCCompiled scenario)
          (fixedStageCAbsence scenario)
          (fixedStageCCredentials scenario)
          (fixedStageCAudit scenario)
          committed
      )

  runCountingPermits counter independent =
    establishPreUninstallReadiness
      CascadeReportCommitBoundary
        { commitPreUninstallReport = \_ -> pure TeardownMutationApplied
        , grantLocalCompletionPermit = \digest -> do
            modifyIORef' counter (+ 1)
            pure (permitFor digest)
        }
      (liftReadBackBoundary independent)
      (fixedStageCCompiled scenario)
      (fixedStageCAbsence scenario)
      (fixedStageCCredentials scenario)
      (fixedStageCAudit scenario)
      committed

  runCounted counter authority independent =
    establishPreUninstallReadiness
      (liftCommitBoundary authority)
      (countingReadBack counter independent)
      (fixedStageCCompiled scenario)
      (fixedStageCAbsence scenario)
      (fixedStageCCredentials scenario)
      (fixedStageCAudit scenario)
      committed

  authorityWith commit permit =
    CascadeReportCommitBoundary
      { commitPreUninstallReport = \_ -> Identity commit
      , grantLocalCompletionPermit = Identity . permit
      }

  permitFor digest = Right (grantFor scenario digest (fixedStageCPermitId scenario))

  foreignPermitFor digest =
    Right
      (grantFor scenario digest (fixedStageCPermitId scenario))
        { localCompletionGrantOperationReferences = swapOperations (fixedStageCOperations scenario)
        }

  observedReadBack digest =
    CascadeReportReadBackBoundary
      { readBackPreUninstallReport =
          Identity (reportObservation scenario digest DurableReceiptObserved)
      }

  missingReadBack digest =
    CascadeReportReadBackBoundary
      { readBackPreUninstallReport =
          Identity (reportObservation scenario digest DurableReceiptMissing)
      }

  unobservableReadBack digest =
    CascadeReportReadBackBoundary
      { readBackPreUninstallReport =
          Identity
            ( reportObservation
                scenario
                digest
                (DurableReceiptUnobservable (ObservationFailure "durable store unavailable"))
            )
      }

-- | Whether the readiness value carries the identity the independent read-back
-- reported, rather than a second copy of the request.
readinessCarriesReadBackIdentity :: PreUninstallReadinessRun -> Bool
readinessCarriesReadBackIdentity run =
  case preUninstallReadinessOutcome run of
    PreUninstallNotReady _ -> False
    PreUninstallReady ready ->
      readyToUninstallReportDigest ready
        == cascadePreUninstallReportDigest (preUninstallReadinessObservation run)

liftReadBackBoundary
  :: CascadeReportReadBackBoundary Identity -> CascadeReportReadBackBoundary IO
liftReadBackBoundary boundary =
  CascadeReportReadBackBoundary
    { readBackPreUninstallReport =
        pure (runIdentity (readBackPreUninstallReport boundary))
    }

reportObservation
  :: FixedStageCScenario
  -> CascadeReportDigest
  -> DurableReceiptObservationResult
  -> CascadePreUninstallReportObservation
reportObservation scenario digest result =
  CascadePreUninstallReportObservation
    { cascadePreUninstallReportDigest = digest
    , cascadePreUninstallReportReceipt =
        DurableReceiptObservation
          { durableReceiptObservationKind = CascadePreUninstallReportReceipt
          , durableReceiptObservationScope =
              compiledDesiredAbsenceObservationScope (fixedStageCCompiled scenario)
          , durableReceiptObservationGraphDigest =
              cleanupGraphDigest (compiledDesiredAbsenceGraph (fixedStageCCompiled scenario))
          , durableReceiptObservationResult = result
          }
    }

grantFor
  :: FixedStageCScenario
  -> CascadeReportDigest
  -> LocalCompletionPermitId
  -> LocalCompletionPermitGrant
grantFor scenario digest permitId =
  LocalCompletionPermitGrant
    { localCompletionGrantPermitId = permitId
    , localCompletionGrantRunId = compiledDesiredAbsenceRunId compiled
    , localCompletionGrantScope = compiledDesiredAbsenceObservationScope compiled
    , localCompletionGrantGraphDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
    , localCompletionGrantReportDigest = digest
    , localCompletionGrantOperationReferences = fixedStageCOperations scenario
    }
 where
  compiled = fixedStageCCompiled scenario

-- | Swap the two local operation references, which is the smallest way to make
-- a permit that is otherwise correct bind to nothing.
swapOperations :: CascadeLocalOperationReferences -> CascadeLocalOperationReferences
swapOperations operations =
  operations
    { cascadeLocalUninstallOperationId = cascadeLocalCompletionOperationId operations
    , cascadeLocalCompletionOperationId = cascadeLocalUninstallOperationId operations
    }

liftCommitBoundary
  :: CascadeReportCommitBoundary Identity -> CascadeReportCommitBoundary IO
liftCommitBoundary boundary =
  CascadeReportCommitBoundary
    { commitPreUninstallReport =
        pure . runIdentity . commitPreUninstallReport boundary
    , grantLocalCompletionPermit =
        pure . runIdentity . grantLocalCompletionPermit boundary
    }

countingReadBack
  :: IORef Int
  -> CascadeReportReadBackBoundary Identity
  -> CascadeReportReadBackBoundary IO
countingReadBack counter boundary =
  CascadeReportReadBackBoundary
    { readBackPreUninstallReport = do
        modifyIORef' counter (+ 1)
        pure (runIdentity (readBackPreUninstallReport boundary))
    }

isNotDurable :: PreUninstallReadinessRefusal -> Bool
isNotDurable = \case
  PreUninstallReportNotDurable _ -> True
  _ -> False

isDigestDrift :: PreUninstallReadinessRefusal -> Bool
isDigestDrift = \case
  PreUninstallReportDigestDrift {} -> True
  _ -> False

isPermitUnavailable :: PreUninstallReadinessRefusal -> Bool
isPermitUnavailable = \case
  PreUninstallPermitUnavailable _ -> True
  _ -> False

isPermitUnbound :: PreUninstallReadinessRefusal -> Bool
isPermitUnbound = \case
  PreUninstallPermitUnbound _ -> True
  _ -> False
