{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the exact host-absence read-back of the recover-to-clean
-- cascade's terminal node.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 8](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- requires that the local uninstall is followed by an exact host observation,
-- and that only that observation plus the matching completion receipt can
-- construct completion.  Two halves of that already existed and could not be
-- joined: "Prodbox.Lifecycle.HostCleanupRke2" observes the canonical install
-- markers with @lstat(2)@ and is deliberately forbidden from naming
-- 'LocalUninstallEvidence', while the evidence constructor that turns an
-- observation into that proof is private to the cascade-evidence ownership
-- set.  This module is the join, and it is a member of that set for exactly
-- that reason.
--
-- Three properties carry the design.
--
--   * __The scope comes from the durable record, not from the proof.__  The
--     observation is scoped by the running host-cleanup intent, and the
--     readiness carries its own scope; the evidence constructor compares them.
--     Deriving the observation's scope from the readiness instead would make
--     that comparison vacuous — the record and the proof are two independent
--     sources, and the point of the check is that they agree.
--
--   * __Still-present and unobservable are different answers.__  A host whose
--     markers are present has not converged and the caller may act on that; a
--     host whose markers could not be read has told the caller nothing, and
--     treating it as either absence or presence would invent a fact.  Presence
--     wins over an unrelated read failure, which is the observation module's
--     rule and is preserved here rather than re-decided.
--
--   * __The proof is constructed, never inferred.__  Absence evidence reaches
--     'LocalUninstallEvidence' only through the private constructor, so a
--     refusal there — a scope mismatch, an unobservable foundation — is
--     reported as a refusal rather than smoothed into "not yet absent".
module Prodbox.Lifecycle.HostCleanupLocalAbsence
  ( LocalAbsenceReadBackRefusal (..)
  , renderLocalAbsenceReadBackRefusal
  , LocalAbsenceReadBack (..)
  , projectLocalFoundationObservation
  , readBackLocalRke2Absence
  , localAbsenceReadBackEffect
  , productionHostCleanupLocalAbsenceReadBack
  , LocalAbsenceReadBackRegression
  , fixedLocalAbsenceReadBackRegression
  , localAbsenceRegressionAbsentBecomesEvidence
  , localAbsenceRegressionPresentIsNotAbsence
  , localAbsenceRegressionUnconfirmedIsNotAbsence
  , localAbsenceRegressionForeignScopeRefused
  , localAbsenceRegressionPresenceOutranksReadFailure
  , localAbsenceRegressionEffectMapping
  )
where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallMarker
  , LocalRke2InstallObservation (..)
  , LocalRke2MarkerFailure (..)
  , LocalRke2TerminalAdapter
  , observeLocalRke2Install
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerContext
  , hostCleanupRunnerObservationScope
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeEvidenceError
  , LocalUninstallEvidence
  , ReadyToUninstallEvidence
  , mkLocalUninstallEvidence
  , readyToUninstallScope
  , withCascadeEvidenceFixtureForRunInternal
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( LocalFoundationObservation (..)
  , LocalFoundationObservationResult (..)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , ObservationEvidenceScope
  , ObservationFailure (ObservationFailure)
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (AbsenceEvidence))

-- ---------------------------------------------------------------------------
-- Reading local absence back
-- ---------------------------------------------------------------------------

-- | Why an observation produced no absence proof and is not simply "still
-- installed" either.
data LocalAbsenceReadBackRefusal
  = -- | The canonical markers could not be read.  An unread host is not an
    -- absent one.
    LocalAbsenceUnconfirmed !(NonEmpty LocalRke2MarkerFailure)
  | -- | The observation was definite and the proof constructor refused it —
    -- most usefully when the durable record's scope and the readiness scope
    -- disagree.
    LocalAbsenceEvidenceRefused !CascadeEvidenceError
  deriving (Eq, Show)

renderLocalAbsenceReadBackRefusal :: LocalAbsenceReadBackRefusal -> Text
renderLocalAbsenceReadBackRefusal = \case
  LocalAbsenceUnconfirmed failures ->
    "local RKE2 absence is unconfirmed: "
      <> Text.intercalate
        ", "
        [ Text.pack (show (localRke2MarkerFailureMarker failure))
            <> ": "
            <> localRke2MarkerFailureDetail failure
        | failure <- NonEmpty.toList failures
        ]
  LocalAbsenceEvidenceRefused err ->
    "local RKE2 absence evidence was refused: " <> Text.pack (show err)

-- | What one exact host observation established.
data LocalAbsenceReadBack
  = LocalAbsenceObserved !(LocalUninstallEvidence 'Cascade)
  | -- | At least one canonical marker is present, so the foundation has not
    -- converged.  The markers are carried because the caller reports them.
    LocalFoundationStillInstalled !(NonEmpty LocalRke2InstallMarker)
  | LocalAbsenceRefused !LocalAbsenceReadBackRefusal
  deriving (Eq, Show)

-- | Project the install observation onto the lifecycle's foundation
-- observation, under the scope the durable host-cleanup record carries.
--
-- The three arms map one-to-one and nothing is collapsed: a present marker set
-- is presence, a complete absent marker set is absence with its evidence, and
-- an unread marker set is unobservable with the first failure's detail.
projectLocalFoundationObservation
  :: ObservationEvidenceScope
  -> LocalRke2InstallObservation
  -> LocalFoundationObservation
projectLocalFoundationObservation scope observation =
  LocalFoundationObservation
    { localFoundationObservationScope = scope
    , localFoundationObservationResult = case observation of
        LocalRke2InstallPresent _ _ -> LocalFoundationPresent
        LocalRke2InstallAbsent evidence -> LocalFoundationAbsent evidence
        LocalRke2InstallUnconfirmed failures ->
          LocalFoundationUnobservable (firstFailure failures)
    }
 where
  firstFailure (failure :| _) =
    ObservationFailure
      ( Text.pack (show (localRke2MarkerFailureMarker failure))
          <> ": "
          <> localRke2MarkerFailureDetail failure
      )

-- | Turn one exact host observation into the terminal node's read-back.
--
-- The scope is the caller's — in production, the running host-cleanup
-- intent's — so the proof constructor's scope comparison is a comparison of
-- two independent sources rather than of a value with itself.
readBackLocalRke2Absence
  :: ObservationEvidenceScope
  -> ReadyToUninstallEvidence
  -> LocalRke2InstallObservation
  -> LocalAbsenceReadBack
readBackLocalRke2Absence scope ready observation =
  case observation of
    LocalRke2InstallPresent markers _ -> LocalFoundationStillInstalled markers
    LocalRke2InstallUnconfirmed failures ->
      LocalAbsenceRefused (LocalAbsenceUnconfirmed failures)
    LocalRke2InstallAbsent _ ->
      case mkLocalUninstallEvidence
        ready
        (projectLocalFoundationObservation scope observation) of
        Left err -> LocalAbsenceRefused (LocalAbsenceEvidenceRefused err)
        Right evidence -> LocalAbsenceObserved evidence

-- | Adapt the read-back to the host cleanup runner's effect arm.
--
-- The runner's contract has three answers and so does this type: absence with
-- its proof, no absence yet, and an observation that decided nothing.  The
-- middle case is deliberately not a failure — the runner acts on it by issuing
-- the uninstall — and the third deliberately is.
localAbsenceReadBackEffect
  :: LocalAbsenceReadBack -> Either Text (Maybe (LocalUninstallEvidence 'Cascade))
localAbsenceReadBackEffect = \case
  LocalAbsenceObserved evidence -> Right (Just evidence)
  LocalFoundationStillInstalled _ -> Right Nothing
  LocalAbsenceRefused refusal -> Left (renderLocalAbsenceReadBackRefusal refusal)

-- | The production read-back arm: observe the canonical markers, then
-- construct.
productionHostCleanupLocalAbsenceReadBack
  :: LocalRke2TerminalAdapter IO
  -> HostCleanupRunnerContext
  -> ReadyToUninstallEvidence
  -> IO (Either Text (Maybe (LocalUninstallEvidence 'Cascade)))
productionHostCleanupLocalAbsenceReadBack adapter context ready = do
  observation <- observeLocalRke2Install adapter
  pure
    ( localAbsenceReadBackEffect
        ( readBackLocalRke2Absence
            (hostCleanupRunnerObservationScope context)
            ready
            observation
        )
    )

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

data LocalAbsenceReadBackRegression = LocalAbsenceReadBackRegression
  { localAbsenceRegressionAbsentBecomesEvidence :: !Bool
  , localAbsenceRegressionPresentIsNotAbsence :: !Bool
  , localAbsenceRegressionUnconfirmedIsNotAbsence :: !Bool
  , localAbsenceRegressionForeignScopeRefused :: !Bool
  , localAbsenceRegressionPresenceOutranksReadFailure :: !Bool
  , localAbsenceRegressionEffectMapping :: !Bool
  }

fixedLocalAbsenceReadBackRegression
  :: Either Text LocalAbsenceReadBackRegression
fixedLocalAbsenceReadBackRegression = do
  ready <-
    withCascadeEvidenceFixtureForRunInternal
      "cleanup-run/local-absence-fixed-regression"
      (\_compiled _run readyEvidence _local _complete -> readyEvidence)
  foreignScope <-
    withCascadeEvidenceFixtureForRunInternal
      "cleanup-run/local-absence-fixed-regression-other"
      (\_compiled _run readyEvidence _local _complete -> readyToUninstallScope readyEvidence)
  let scope = readyToUninstallScope ready
      readBack observation = readBackLocalRke2Absence scope ready observation
      absent = fixedAbsentObservation
      present = fixedPresentObservation []
      presentDespiteFailure = fixedPresentObservation [fixedFailure "unreadable"]
      unconfirmed = LocalRke2InstallUnconfirmed (fixedFailure "permission denied" :| [])
  pure
    LocalAbsenceReadBackRegression
      { localAbsenceRegressionAbsentBecomesEvidence =
          isObserved (readBack absent)
      , localAbsenceRegressionPresentIsNotAbsence =
          readBack present == LocalFoundationStillInstalled fixedPresentMarkers
      , localAbsenceRegressionUnconfirmedIsNotAbsence =
          readBack unconfirmed
            == LocalAbsenceRefused
              (LocalAbsenceUnconfirmed (fixedFailure "permission denied" :| []))
      , -- The record's scope and the readiness disagree, which is the one
        -- disagreement this join exists to catch.
        localAbsenceRegressionForeignScopeRefused =
          isEvidenceRefusal (readBackLocalRke2Absence foreignScope ready absent)
      , localAbsenceRegressionPresenceOutranksReadFailure =
          readBack presentDespiteFailure
            == LocalFoundationStillInstalled fixedPresentMarkers
      , localAbsenceRegressionEffectMapping =
          isRightJust (localAbsenceReadBackEffect (readBack absent))
            && localAbsenceReadBackEffect (readBack present) == Right Nothing
            && isLeftEffect (localAbsenceReadBackEffect (readBack unconfirmed))
      }

fixedPresentMarkers :: NonEmpty LocalRke2InstallMarker
fixedPresentMarkers = minBound :| []

fixedPresentObservation :: [LocalRke2MarkerFailure] -> LocalRke2InstallObservation
fixedPresentObservation = LocalRke2InstallPresent fixedPresentMarkers

fixedAbsentObservation :: LocalRke2InstallObservation
fixedAbsentObservation =
  LocalRke2InstallAbsent (AbsenceEvidence "local-rke2-fixed-authoritative-not-found")

fixedFailure :: Text -> LocalRke2MarkerFailure
fixedFailure detail =
  LocalRke2MarkerFailure
    { localRke2MarkerFailureMarker = minBound
    , localRke2MarkerFailureDetail = detail
    }

isObserved :: LocalAbsenceReadBack -> Bool
isObserved = \case
  LocalAbsenceObserved _ -> True
  _ -> False

isEvidenceRefusal :: LocalAbsenceReadBack -> Bool
isEvidenceRefusal = \case
  LocalAbsenceRefused (LocalAbsenceEvidenceRefused _) -> True
  _ -> False

isRightJust :: Either Text (Maybe (LocalUninstallEvidence 'Cascade)) -> Bool
isRightJust = \case
  Right (Just _) -> True
  _ -> False

isLeftEffect :: Either Text (Maybe (LocalUninstallEvidence 'Cascade)) -> Bool
isLeftEffect = \case
  Left _ -> True
  Right _ -> False
