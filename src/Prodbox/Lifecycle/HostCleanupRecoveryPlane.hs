{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the host cleanup runner's bootstrap recovery-plane arms.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 1](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- says that when local RKE2 is stopped the cascade repairs and starts it, and
-- that when it is absent and the retained trust root is recoverable the cascade
-- installs the minimal ordinary teardown profile against the preserved
-- @.data\/@ roots.  Sprint @3.41@ landed the renderer that says what such a
-- repair is, and Sprint @4.86@ landed the admission and execution that runs
-- one; what did not exist was the join to the runner, so the destructive host
-- boundary had no way to re-establish the plane it depends on and no way to
-- read the result back.
--
-- Three properties carry the design.
--
--   * __The re-establishment never reports availability.__  Its answers are
--     about what this attempt did — a repair applied, a repair stopped at a
--     step, a repair nothing could admit, a substrate nothing could observe.
--     Whether the plane /is/ available is decided only by the separate
--     read-back, from a fresh observation, which is the same separation the
--     repair execution already applies to substrate convergence and the reason
--     the runner asks two questions rather than one.
--
--   * __Unavailable and unobservable are different answers.__  A stopped or
--     absent substrate has told the run something, and the run acts on it by
--     repairing; a substrate that could not be observed has said nothing, and
--     calling that either available or unavailable would invent a fact.  The
--     runner has distinct errors for the two and this module keeps them
--     distinct rather than collapsing them into one failure.
--
--   * __The scope comes from the durable record.__  The check is scoped by the
--     running host-cleanup intent, and the runner compares that scope against
--     its own context, so the comparison is over a value the observation
--     carried rather than one it was handed.
--
-- What this module does not own: the /content/ of a repair, which belongs to
-- "Prodbox.Config.OrdinaryTeardownRepair"; its admission against the retained
-- store and its execution, which belong to
-- "Prodbox.Lifecycle.Teardown.RecoveryRepairExecution"; and the descriptor-bound
-- lifecycle RecoveryPlane evidence, which is a different and opaque proof that
-- teardown execution consumes.  The host check here is deliberately the local
-- orchestration one the runner declares.
--
-- Installing a substrate from retained bytes, starting its service, and
-- reconciling the recovery charts stay behind the injected repair boundary:
-- they are host mutations belonging to the non-public candidate entrypoint this
-- sprint still owns, and wiring one here would activate a writer this sprint
-- does not activate.
module Prodbox.Lifecycle.HostCleanupRecoveryPlane
  ( -- * Reading the plane back
    hostRecoveryPlaneCheckFor
  , productionHostCleanupRecoveryPlaneReadBack

    -- * Re-establishing it
  , HostRecoveryPlaneRepair (..)
  , HostRecoveryPlaneEstablishment (..)
  , renderHostRecoveryPlaneEstablishment
  , establishHostRecoveryPlane
  , hostRecoveryPlaneEstablishmentEffect

    -- * Regression over the fixed recovery closure
  , HostRecoveryPlaneRegression
  , fixedHostRecoveryPlaneRegression
  , hostRecoveryPlaneRegressionHealthyIsAvailable
  , hostRecoveryPlaneRegressionStoppedIsUnavailable
  , hostRecoveryPlaneRegressionAbsentIsUnavailable
  , hostRecoveryPlaneRegressionUnreadIsUnobservable
  , hostRecoveryPlaneRegressionCheckCarriesGivenScope
  , hostRecoveryPlaneRegressionRepairAppliedIsNotAvailability
  , hostRecoveryPlaneRegressionStoppedRepairRefused
  , hostRecoveryPlaneRegressionInadmissibleRepairRefused
  , hostRecoveryPlaneRegressionUnobservableStateNeverRepairs
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryStateView (..)
  , localRke2RecoveryStateView
  , observeLocalRke2RecoveryState
  , renderLocalRke2RecoveryStateError
  )
import Prodbox.Config.OrdinaryTeardownRecovery (OrdinaryTeardownRecovery)
import Prodbox.Config.OrdinaryTeardownRepair
  ( RetainedArtifactInventory
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (..)
  , HostCleanupRunnerContext
  , HostRecoveryPlaneCheck (..)
  , HostRecoveryPlaneCheckResult (..)
  , hostCleanupRunnerObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationEvidenceScope
  , ObservationFailure (ObservationFailure)
  )
import Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
  ( RecoveryRepairAdmission (..)
  , RecoveryRepairBoundary
  , RecoveryRepairRun (..)
  , admitRecoveryRepair
  , applyRecoveryRepair
  , recoveryRepairRunFailure
  , renderRecoveryRepairRefusal
  , renderRecoveryRepairRemedy
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactSourceCatalog
  , RetainedArtifactStoreObservation
  )

-- ---------------------------------------------------------------------------
-- Reading the plane back
-- ---------------------------------------------------------------------------

-- | Map one fresh substrate observation onto the runner's host recovery check.
--
-- The three answers are one-to-one with the observation's and nothing is
-- collapsed.  A healthy substrate is available; a stopped or absent one is
-- unavailable and says which it was, because the two need different repairs;
-- and a substrate that could not be observed is unobservable, which the runner
-- reports as a distinct error from unavailability.
hostRecoveryPlaneCheckFor
  :: ObservationEvidenceScope
  -> Either Text LocalRke2RecoveryStateView
  -> HostRecoveryPlaneCheck
hostRecoveryPlaneCheckFor scope observed =
  HostRecoveryPlaneCheck
    { hostRecoveryPlaneCheckScope = scope
    , hostRecoveryPlaneCheckResult = case observed of
        Left detail ->
          HostRecoveryPlaneUnobservable
            (ObservationFailure ("local recovery substrate is unobservable: " <> detail))
        Right LocalRke2RecoveryHealthy -> HostRecoveryPlaneAvailable
        Right LocalRke2RecoveryStopped ->
          HostRecoveryPlaneUnavailable
            (ObservationFailure "local recovery substrate is installed and stopped")
        Right LocalRke2RecoveryAbsent ->
          HostRecoveryPlaneUnavailable
            (ObservationFailure "local recovery substrate is absent")
    }

-- | The production read-back arm.
--
-- It always answers, because a substrate that could not be observed is a
-- representable answer inside the check rather than a failed read-back: the
-- runner distinguishes an unobservable plane from an unavailable one, and
-- returning a failed read-back here would erase that distinction before the
-- runner could make it.
productionHostCleanupRecoveryPlaneReadBack
  :: HostCleanupRunnerContext -> IO (Either Text HostRecoveryPlaneCheck)
productionHostCleanupRecoveryPlaneReadBack context = do
  observed <- observeLocalRke2RecoveryState
  pure
    ( Right
        ( hostRecoveryPlaneCheckFor
            (hostCleanupRunnerObservationScope context)
            ( either
                (Left . renderLocalRke2RecoveryStateError)
                (Right . localRke2RecoveryStateView)
                observed
            )
        )
    )

-- ---------------------------------------------------------------------------
-- Re-establishing it
-- ---------------------------------------------------------------------------

-- | Everything a re-establishment attempt reaches for.
--
-- The state and store observations are separate fields rather than one, because
-- they answer different questions — which repair this substrate needs, and
-- whether the bytes that repair names are retained — and a single combined
-- observation would let one failure be reported as the other.
data HostRecoveryPlaneRepair m = HostRecoveryPlaneRepair
  { hostRecoveryObserveState :: m (Either Text LocalRke2RecoveryStateView)
  , hostRecoveryObserveStore :: m RetainedArtifactStoreObservation
  , hostRecoveryRepairBoundary :: RecoveryRepairBoundary m
  }

-- | What one re-establishment attempt did.
--
-- Every arm is about the attempt.  None of them says the plane is available:
-- that is the read-back's answer, taken from a fresh observation.
data HostRecoveryPlaneEstablishment
  = -- | Every step of the admitted repair succeeded.
    HostRecoveryPlaneRepairApplied !RecoveryRepairRun
  | -- | A step failed, and the run carries the unattempted tail.
    HostRecoveryPlaneRepairStopped !RecoveryRepairRun !Text
  | -- | No repair could be admitted — the plan could not be rendered for the
    -- observed state, or the retained store does not hold what it names.  The
    -- remedy the admission produced is preserved.
    HostRecoveryPlaneRepairInadmissible !Text
  | -- | The substrate could not be observed, so no repair was even selected.
    -- Repairing an unobserved substrate would mean choosing a plan for a state
    -- nothing established.
    HostRecoveryPlaneStateUnobservable !Text
  deriving (Eq, Show)

renderHostRecoveryPlaneEstablishment :: HostRecoveryPlaneEstablishment -> Text
renderHostRecoveryPlaneEstablishment = \case
  HostRecoveryPlaneRepairApplied run ->
    "recovery-plane repair applied "
      <> Text.pack (show (length (recoveryRepairAttempted run)))
      <> " step(s)"
  HostRecoveryPlaneRepairStopped run detail ->
    "recovery-plane repair stopped after "
      <> Text.pack (show (length (recoveryRepairAttempted run)))
      <> " step(s) with "
      <> Text.pack (show (length (recoveryRepairUnattempted run)))
      <> " unattempted: "
      <> detail
  HostRecoveryPlaneRepairInadmissible detail ->
    "recovery-plane repair was not admitted: " <> detail
  HostRecoveryPlaneStateUnobservable detail ->
    "recovery-plane substrate was not observed: " <> detail

-- | Observe the substrate, admit the repair its state needs, and apply it.
--
-- The order is load-bearing.  The plan is rendered /for an observed state/, so
-- an unobservable substrate selects no plan at all rather than a default one,
-- and admission is checked against the retained store before any boundary call
-- so a repair that cannot complete is refused rather than half-run.
establishHostRecoveryPlane
  :: (Monad m)
  => RetainedArtifactInventory
  -> RetainedArtifactSourceCatalog
  -> OrdinaryTeardownRecovery
  -> HostRecoveryPlaneRepair m
  -> m HostRecoveryPlaneEstablishment
establishHostRecoveryPlane inventory catalog recovery repair = do
  observed <- hostRecoveryObserveState repair
  case observed of
    Left detail -> pure (HostRecoveryPlaneStateUnobservable detail)
    Right state -> do
      store <- hostRecoveryObserveStore repair
      case admitRecoveryRepair inventory catalog recovery state store of
        RecoveryRepairRefused refusal remedy ->
          pure
            ( HostRecoveryPlaneRepairInadmissible
                ( Text.pack (renderRecoveryRepairRefusal refusal)
                    <> "; "
                    <> Text.pack (renderRecoveryRepairRemedy remedy)
                )
            )
        RecoveryRepairAdmitted admitted -> do
          run <- applyRecoveryRepair (hostRecoveryRepairBoundary repair) admitted
          pure $ case recoveryRepairRunFailure run of
            Nothing -> HostRecoveryPlaneRepairApplied run
            Just (_, detail) -> HostRecoveryPlaneRepairStopped run detail

-- | Project the attempt onto the runner's mutation answer.
--
-- An applied repair is @Applied@ and nothing more: it makes no claim that the
-- plane came up, which the runner then reads back independently.  The other
-- three arms are refusals rather than response losses, because each of them
-- knows what happened — a step that failed, an admission that was declined, an
-- observation that returned nothing.
hostRecoveryPlaneEstablishmentEffect
  :: HostRecoveryPlaneEstablishment -> HostCleanupEffectOutcome
hostRecoveryPlaneEstablishmentEffect establishment = case establishment of
  HostRecoveryPlaneRepairApplied _ -> HostCleanupEffectApplied
  _ -> HostCleanupEffectRefused (renderHostRecoveryPlaneEstablishment establishment)

-- ---------------------------------------------------------------------------
-- Regression
-- ---------------------------------------------------------------------------

data HostRecoveryPlaneRegression = HostRecoveryPlaneRegression
  { hostRecoveryPlaneRegressionHealthyIsAvailable :: !Bool
  , hostRecoveryPlaneRegressionStoppedIsUnavailable :: !Bool
  , hostRecoveryPlaneRegressionAbsentIsUnavailable :: !Bool
  , hostRecoveryPlaneRegressionUnreadIsUnobservable :: !Bool
  , hostRecoveryPlaneRegressionCheckCarriesGivenScope :: !Bool
  , hostRecoveryPlaneRegressionRepairAppliedIsNotAvailability :: !Bool
  , hostRecoveryPlaneRegressionStoppedRepairRefused :: !Bool
  , hostRecoveryPlaneRegressionInadmissibleRepairRefused :: !Bool
  , hostRecoveryPlaneRegressionUnobservableStateNeverRepairs :: !Bool
  }

-- | Read-back behaviour measured against one supplied scope, and the effect
-- projection measured against constructed attempts.
--
-- The attempts are constructed rather than run, because running one needs the
-- repair inventory and closure that the candidate entrypoint composes; what
-- this regression owns is the mapping the runner consumes, and in particular
-- that an applied repair is not availability.
fixedHostRecoveryPlaneRegression
  :: ObservationEvidenceScope -> HostRecoveryPlaneRegression
fixedHostRecoveryPlaneRegression scope =
  HostRecoveryPlaneRegression
    { hostRecoveryPlaneRegressionHealthyIsAvailable =
        resultFor (Right LocalRke2RecoveryHealthy) == HostRecoveryPlaneAvailable
    , hostRecoveryPlaneRegressionStoppedIsUnavailable =
        isUnavailable (resultFor (Right LocalRke2RecoveryStopped))
    , hostRecoveryPlaneRegressionAbsentIsUnavailable =
        isUnavailable (resultFor (Right LocalRke2RecoveryAbsent))
    , hostRecoveryPlaneRegressionUnreadIsUnobservable =
        isUnobservable (resultFor (Left "systemd did not answer"))
    , hostRecoveryPlaneRegressionCheckCarriesGivenScope =
        hostRecoveryPlaneCheckScope
          (hostRecoveryPlaneCheckFor scope (Right LocalRke2RecoveryHealthy))
          == scope
    , -- An applied repair is @Applied@, never availability.  The plane's
      -- availability is the read-back's answer.
      hostRecoveryPlaneRegressionRepairAppliedIsNotAvailability =
        hostRecoveryPlaneEstablishmentEffect (HostRecoveryPlaneRepairApplied emptyRun)
          == HostCleanupEffectApplied
    , hostRecoveryPlaneRegressionStoppedRepairRefused =
        isRefused
          ( hostRecoveryPlaneEstablishmentEffect
              (HostRecoveryPlaneRepairStopped emptyRun "install failed")
          )
    , hostRecoveryPlaneRegressionInadmissibleRepairRefused =
        isRefused
          ( hostRecoveryPlaneEstablishmentEffect
              (HostRecoveryPlaneRepairInadmissible "retained bytes drifted")
          )
    , hostRecoveryPlaneRegressionUnobservableStateNeverRepairs =
        isRefused
          ( hostRecoveryPlaneEstablishmentEffect
              (HostRecoveryPlaneStateUnobservable "systemd did not answer")
          )
    }
 where
  resultFor = hostRecoveryPlaneCheckResult . hostRecoveryPlaneCheckFor scope
  emptyRun =
    RecoveryRepairRun
      { recoveryRepairAttempted = []
      , recoveryRepairUnattempted = []
      }

isUnavailable :: HostRecoveryPlaneCheckResult -> Bool
isUnavailable = \case
  HostRecoveryPlaneUnavailable _ -> True
  _ -> False

isUnobservable :: HostRecoveryPlaneCheckResult -> Bool
isUnobservable = \case
  HostRecoveryPlaneUnobservable _ -> True
  _ -> False

isRefused :: HostCleanupEffectOutcome -> Bool
isRefused = \case
  HostCleanupEffectRefused _ -> True
  _ -> False
