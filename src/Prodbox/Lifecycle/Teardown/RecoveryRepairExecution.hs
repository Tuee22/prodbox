{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the Plan\/Apply composition that lets a rendered
-- ordinary-teardown repair actually run, and that makes retained-artifact
-- custody the only way it may.
--
-- "Prodbox.Config.OrdinaryTeardownRepair" renders the repair matrix from the
-- validated inventory alone, and
-- "Prodbox.Lifecycle.Teardown.RetainedArtifactCustody" acquires and verifies
-- the bytes that inventory declares.  Between the two there was no consumer:
-- a plan could be rendered and validated and nothing in the repository could
-- execute it, so the custody surface retained bytes nobody read and the repair
-- surface named bytes nobody retained.  This module is that consumer.
--
-- Three properties carry the design.
--
--   * __A repair is admitted, never merely rendered.__  An
--     'AdmittedRecoveryRepair' has no constructor reachable from a rendered
--     plan alone: the only way to build one is to join the plan against an
--     observation of the retained store in which every artifact the plan names
--     is present and hashes to its pinned digest.  A rendered plan is a claim
--     about the inventory; an admitted repair is a claim about the disk, and
--     only the second one is allowed to start.
--
--   * __A refusal names its remedy.__  When admission fails because the store
--     diverges from the inventory, the refusal carries the custody plan that
--     closes the gap, derived from the same observation the readiness check
--     rejected.  When no custody plan can close it — the inventory itself does
--     not retain what the observed state needs, or the store could not be
--     listed — the remedy is explicitly unavailable rather than an empty plan
--     that would read as \"nothing to do\".
--
--   * __The steps are sequentially dependent, and the read-back does not read
--     them.__  Unlike a custody plan, whose obligations are independent, a
--     repair's steps compose: starting a service that was never installed is
--     not a second chance but a second failure with a misleading reason.  So
--     application stops at the first failure and records the unattempted tail
--     explicitly, rather than dropping it.  Convergence is then decided from a
--     /fresh/ observation of the substrate and nothing else — a run in which
--     every step reported success and the substrate is still absent reads as
--     unconverged rather than complete.
--
-- The pure kernel admits, plans, and reads back.  The only effects live behind
-- an injected 'RecoveryRepairBoundary', so the fault matrix — a failed
-- install, a service that starts but whose API never arrives, a chart
-- reconcile that fails after the substrate is up, an unobservable substrate —
-- is exercised without a host.
--
-- This module deliberately ships no production boundary.  Installing a
-- substrate from retained bytes, starting its service, and reconciling the
-- recovery charts are host mutations that belong to the non-public candidate
-- entrypoint Sprint @4.86@ still owns; wiring one here would activate a writer
-- this sprint does not activate.  The scope of the read-back is equally
-- deliberate: it is the substrate arm only, and it makes no claim about chart
-- convergence, which the descriptor-bound component observer measures.
module Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
  ( -- * Admission
    VerifiedRetainedArtifact (..)
  , AdmittedRepairStep (..)
  , AdmittedRecoveryRepair
  , admittedRecoveryRepairState
  , admittedRecoveryRepairArchitecture
  , admittedRecoveryRepairSteps
  , admittedRecoveryRepairArtifacts
  , RecoveryRepairRefusal (..)
  , renderRecoveryRepairRefusal
  , RecoveryRepairRemedy (..)
  , renderRecoveryRepairRemedy
  , RecoveryRepairAdmission (..)
  , admitRecoveryRepair

    -- * Applying an admitted repair
  , RecoveryRepairBoundary (..)
  , RecoveryRepairStepOutcome (..)
  , renderRecoveryRepairStepOutcome
  , RecoveryRepairRun (..)
  , recoveryRepairRunFailure
  , applyRecoveryRepair

    -- * Read-back
  , RecoveryRepairSubstrateConvergence (..)
  , renderRecoveryRepairSubstrateConvergence
  , recoveryRepairSubstrateReadBack
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryStateView (..)
  )
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownRecovery
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( OrdinaryTeardownRepairError
  , OrdinaryTeardownRepairStep (..)
  , RecoveryPlatformComponent
  , RetainedArtifactArchitecture
  , RetainedArtifactInventory
  , RetainedArtifactKind
  , ordinaryTeardownRepairPlan
  , ordinaryTeardownRepairPlanArchitecture
  , ordinaryTeardownRepairPlanSteps
  , renderOrdinaryTeardownRepairError
  , retainedArtifactRefDigest
  , retainedArtifactRefKind
  , retainedArtifactRefRelativePath
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactCustodyPlan
  , RetainedArtifactCustodyResidue
  , RetainedArtifactRepairReadiness (..)
  , RetainedArtifactSourceCatalog
  , RetainedArtifactStoreObservation
  , planRetainedArtifactCustody
  , renderRetainedArtifactCustodyError
  , renderRetainedArtifactCustodyResidue
  , retainedArtifactRepairReadiness
  )

-- ---------------------------------------------------------------------------
-- Admission
-- ---------------------------------------------------------------------------

-- | Exactly one artifact a repair reads: the store-relative location the
-- admission checked, and the pinned digest that check accepted there.
--
-- The boundary is handed these rather than a @RetainedArtifactRef@ and the
-- inventory, so no execution step can re-derive which bytes a step is
-- \"really\" about from a declaration that was never observed.  A boundary
-- still joins the relative path against the one store it was built for, which
-- is the only resolution left and the same composition custody proved safe.
data VerifiedRetainedArtifact = VerifiedRetainedArtifact
  { verifiedRetainedArtifactKind :: !RetainedArtifactKind
  , verifiedRetainedArtifactRelativePath :: !FilePath
  , verifiedRetainedArtifactDigest :: !Text
  }
  deriving (Eq, Show)

-- | One step of an admitted repair.
--
-- It mirrors 'OrdinaryTeardownRepairStep' with every artifact reference
-- replaced by the verified byte source it resolved to, which is the whole
-- difference between a rendered plan and an admitted one.
data AdmittedRepairStep
  = AdmittedInstallSubstrateFromRetained !(NonEmpty VerifiedRetainedArtifact)
  | AdmittedStartSubstrateService
  | AdmittedAwaitSubstrateApi
  | AdmittedLoadRetainedImage !VerifiedRetainedArtifact
  | AdmittedReconcileRecoveryPlatform !RecoveryPlatformComponent
  | AdmittedReconcileRecoveryChart !String
  deriving (Eq, Show)

-- | An opaque repair that may start.
--
-- Construction is the proof: 'admitRecoveryRepair' is the only way in, and it
-- builds one only from a 'RetainedArtifactRepairReady' join over an observed
-- store.
data AdmittedRecoveryRepair = AdmittedRecoveryRepair
  { admittedRecoveryRepairState :: !LocalRke2RecoveryStateView
  , admittedRecoveryRepairArchitecture :: !RetainedArtifactArchitecture
  , admittedRecoveryRepairSteps :: ![AdmittedRepairStep]
  }
  deriving (Eq, Show)

-- | Every artifact an admitted repair reads, in step order.
admittedRecoveryRepairArtifacts
  :: AdmittedRecoveryRepair -> [VerifiedRetainedArtifact]
admittedRecoveryRepairArtifacts repair =
  concatMap sourcesOf (admittedRecoveryRepairSteps repair)
 where
  sourcesOf = \case
    AdmittedInstallSubstrateFromRetained artifacts -> NonEmpty.toList artifacts
    AdmittedLoadRetainedImage artifact -> [artifact]
    AdmittedStartSubstrateService -> []
    AdmittedAwaitSubstrateApi -> []
    AdmittedReconcileRecoveryPlatform _ -> []
    AdmittedReconcileRecoveryChart _ -> []

-- | Why a repair may not start.
data RecoveryRepairRefusal
  = -- | No plan could be rendered for the observed state out of this
    -- inventory.
    RecoveryRepairUnrenderable !OrdinaryTeardownRepairError
  | -- | A plan was rendered, and the store does not hold what it names.
    RecoveryRepairArtifactsUnready !(NonEmpty RetainedArtifactCustodyResidue)
  | -- | The store could not be listed.  A repair does not start against an
    -- unread store, and an unread store is not a specific gap either.
    RecoveryRepairStoreUnobservable !Text
  deriving (Eq, Show)

renderRecoveryRepairRefusal :: RecoveryRepairRefusal -> String
renderRecoveryRepairRefusal = \case
  RecoveryRepairUnrenderable err ->
    "Recovery repair is not admitted: " ++ renderOrdinaryTeardownRepairError err
  RecoveryRepairArtifactsUnready residue ->
    "Recovery repair is not admitted: "
      ++ commaSeparated
        (fmap renderRetainedArtifactCustodyResidue (NonEmpty.toList residue))
  RecoveryRepairStoreUnobservable detail ->
    "Recovery repair is not admitted: the retained artifact store could not be \
    \listed: "
      ++ Text.unpack detail

-- | What would make a refused repair admissible.
data RecoveryRepairRemedy
  = -- | Retention drift explains the refusal, and this custody plan closes it.
    RecoveryRepairRemedyCustody !RetainedArtifactCustodyPlan
  | -- | No acquisition closes the refusal.  Either the inventory does not
    -- declare what the observed state needs — an artifact nobody retains
    -- cannot be acquired into retention — or the store could not be listed, in
    -- which case neither retention nor drift is known.
    RecoveryRepairRemedyUnavailable !Text
  deriving (Eq, Show)

renderRecoveryRepairRemedy :: RecoveryRepairRemedy -> String
renderRecoveryRepairRemedy = \case
  RecoveryRepairRemedyCustody _ ->
    "retained artifact custody can close this refusal"
  RecoveryRepairRemedyUnavailable detail ->
    "no acquisition closes this refusal: " ++ Text.unpack detail

-- | The admission verdict.
data RecoveryRepairAdmission
  = RecoveryRepairAdmitted !AdmittedRecoveryRepair
  | RecoveryRepairRefused !RecoveryRepairRefusal !RecoveryRepairRemedy
  deriving (Eq, Show)

-- | Render the repair for one observed substrate state and admit it only if
-- the store already holds every artifact it names.
--
-- The readiness join deliberately asks about the plan's artifacts and not
-- about store membership: a stray file under the retained root is custody's
-- question, and letting it refuse a recovery would make an unrelated
-- housekeeping gap fatal at the one moment the recovery closure exists for.
admitRecoveryRepair
  :: RetainedArtifactInventory
  -> RetainedArtifactSourceCatalog
  -> OrdinaryTeardownRecovery
  -> LocalRke2RecoveryStateView
  -> RetainedArtifactStoreObservation
  -> RecoveryRepairAdmission
admitRecoveryRepair inventory catalog recovery state observation =
  case ordinaryTeardownRepairPlan inventory recovery state of
    Left err ->
      RecoveryRepairRefused
        (RecoveryRepairUnrenderable err)
        ( RecoveryRepairRemedyUnavailable
            "the inventory does not retain what the observed state needs, so \
            \there is no pinned digest an acquisition could be checked against"
        )
    Right plan ->
      case retainedArtifactRepairReadiness plan observation of
        RetainedArtifactRepairReady ->
          RecoveryRepairAdmitted
            AdmittedRecoveryRepair
              { admittedRecoveryRepairState = state
              , admittedRecoveryRepairArchitecture =
                  ordinaryTeardownRepairPlanArchitecture plan
              , admittedRecoveryRepairSteps =
                  fmap admitStep (ordinaryTeardownRepairPlanSteps plan)
              }
        RetainedArtifactRepairUnready residue ->
          RecoveryRepairRefused
            (RecoveryRepairArtifactsUnready residue)
            remedy
        RetainedArtifactRepairUnverifiable detail ->
          RecoveryRepairRefused
            (RecoveryRepairStoreUnobservable detail)
            ( RecoveryRepairRemedyUnavailable
                ("the retained artifact store could not be listed: " <> detail)
            )
 where
  remedy =
    case planRetainedArtifactCustody inventory catalog observation of
      Right custody -> RecoveryRepairRemedyCustody custody
      Left err ->
        RecoveryRepairRemedyUnavailable
          (Text.pack (renderRetainedArtifactCustodyError err))

  admitStep = \case
    RepairInstallSubstrateFromRetained refs ->
      AdmittedInstallSubstrateFromRetained (fmap verified refs)
    RepairStartSubstrateService -> AdmittedStartSubstrateService
    RepairAwaitSubstrateApi -> AdmittedAwaitSubstrateApi
    RepairLoadRetainedImage ref -> AdmittedLoadRetainedImage (verified ref)
    RepairReconcileRecoveryPlatform platform ->
      AdmittedReconcileRecoveryPlatform platform
    RepairReconcileRecoveryChart chart -> AdmittedReconcileRecoveryChart chart

  verified ref =
    VerifiedRetainedArtifact
      { verifiedRetainedArtifactKind = retainedArtifactRefKind ref
      , verifiedRetainedArtifactRelativePath = retainedArtifactRefRelativePath ref
      , verifiedRetainedArtifactDigest = Text.pack (retainedArtifactRefDigest ref)
      }

-- ---------------------------------------------------------------------------
-- Applying an admitted repair
-- ---------------------------------------------------------------------------

-- | The injected physical boundary.
--
-- Every arm returns a reason rather than throwing, so the fault matrix is a
-- table of values.  None of them takes an inventory reference: what a step may
-- read is already fixed to a store-relative path whose digest was observed.
data RecoveryRepairBoundary m = RecoveryRepairBoundary
  { repairInstallSubstrate
      :: NonEmpty VerifiedRetainedArtifact -> m (Either Text ())
  , repairStartSubstrateService :: m (Either Text ())
  , repairAwaitSubstrateApi :: m (Either Text ())
  , repairLoadRetainedImage :: VerifiedRetainedArtifact -> m (Either Text ())
  , repairReconcileRecoveryPlatform
      :: RecoveryPlatformComponent -> m (Either Text ())
  , repairReconcileRecoveryChart :: String -> m (Either Text ())
  }

data RecoveryRepairStepOutcome
  = RecoveryRepairStepSucceeded
  | RecoveryRepairStepFailed !Text
  deriving (Eq, Show)

renderRecoveryRepairStepOutcome :: RecoveryRepairStepOutcome -> String
renderRecoveryRepairStepOutcome = \case
  RecoveryRepairStepSucceeded -> "succeeded"
  RecoveryRepairStepFailed detail -> "failed: " ++ Text.unpack detail

-- | What one application of an admitted repair did.
--
-- The unattempted tail is carried rather than dropped, because \"the repair
-- stopped here\" and \"the repair had nothing further to do\" are different
-- facts and a report that cannot tell them apart is a report that overstates
-- coverage.
data RecoveryRepairRun = RecoveryRepairRun
  { recoveryRepairAttempted :: ![(AdmittedRepairStep, RecoveryRepairStepOutcome)]
  , recoveryRepairUnattempted :: ![AdmittedRepairStep]
  }
  deriving (Eq, Show)

-- | The failure that stopped a run, if one did.
recoveryRepairRunFailure :: RecoveryRepairRun -> Maybe (AdmittedRepairStep, Text)
recoveryRepairRunFailure run =
  case [(step, detail) | (step, RecoveryRepairStepFailed detail) <- recoveryRepairAttempted run] of
    [] -> Nothing
    failure : _ -> Just failure

-- | Apply an admitted repair, stopping at the first failed step.
--
-- Stopping is the point.  A repair's steps are sequentially dependent — an
-- image load against a substrate whose API never arrived, or a chart reconcile
-- against a substrate that was never installed, produces a second failure
-- whose reason describes the wrong boundary.  Continuing would trade one
-- accurate diagnosis for several misleading ones.
applyRecoveryRepair
  :: (Monad m)
  => RecoveryRepairBoundary m
  -> AdmittedRecoveryRepair
  -> m RecoveryRepairRun
applyRecoveryRepair boundary repair =
  go [] (admittedRecoveryRepairSteps repair)
 where
  go attempted = \case
    [] ->
      pure
        RecoveryRepairRun
          { recoveryRepairAttempted = reverse attempted
          , recoveryRepairUnattempted = []
          }
    step : remaining -> do
      outcome <- run step
      case outcome of
        RecoveryRepairStepSucceeded ->
          go ((step, outcome) : attempted) remaining
        RecoveryRepairStepFailed _ ->
          pure
            RecoveryRepairRun
              { recoveryRepairAttempted = reverse ((step, outcome) : attempted)
              , recoveryRepairUnattempted = remaining
              }

  run step = fmap outcomeOf $ case step of
    AdmittedInstallSubstrateFromRetained artifacts ->
      repairInstallSubstrate boundary artifacts
    AdmittedStartSubstrateService -> repairStartSubstrateService boundary
    AdmittedAwaitSubstrateApi -> repairAwaitSubstrateApi boundary
    AdmittedLoadRetainedImage artifact ->
      repairLoadRetainedImage boundary artifact
    AdmittedReconcileRecoveryPlatform platform ->
      repairReconcileRecoveryPlatform boundary platform
    AdmittedReconcileRecoveryChart chart ->
      repairReconcileRecoveryChart boundary chart

  outcomeOf = \case
    Left detail -> RecoveryRepairStepFailed detail
    Right () -> RecoveryRepairStepSucceeded

-- ---------------------------------------------------------------------------
-- Read-back
-- ---------------------------------------------------------------------------

-- | The verdict over a fresh substrate observation.
--
-- Scoped to the substrate arm on purpose.  A repair also loads images and
-- reconciles the recovery charts, and the local recovery-state view does not
-- observe either; claiming chart convergence from it would be exactly the kind
-- of derived-from-the-wrong-surface completion the read-back exists to
-- prevent.  Chart convergence is the descriptor-bound component observer's
-- question.
data RecoveryRepairSubstrateConvergence
  = -- | The substrate is freshly observed healthy.
    RecoveryRepairSubstrateConverged
  | -- | The substrate is freshly observed, and is not healthy.
    RecoveryRepairSubstrateUnconverged !LocalRke2RecoveryStateView
  | -- | The substrate could not be observed.  An unobservable substrate closes
    -- nothing in either direction.
    RecoveryRepairSubstrateUnverifiable !Text
  deriving (Eq, Show)

renderRecoveryRepairSubstrateConvergence
  :: RecoveryRepairSubstrateConvergence -> String
renderRecoveryRepairSubstrateConvergence = \case
  RecoveryRepairSubstrateConverged ->
    "the local substrate is healthy on a fresh observation"
  RecoveryRepairSubstrateUnconverged state ->
    "the local substrate is " ++ stateText state ++ " on a fresh observation"
  RecoveryRepairSubstrateUnverifiable detail ->
    "the local substrate could not be observed: " ++ Text.unpack detail

-- | Decide substrate convergence from a fresh observation alone.
--
-- The run is deliberately not an input.  A step that reported success is a
-- statement about a boundary call, not about the substrate, and reading
-- convergence out of the run is the defect an independent read-back exists to
-- exclude.
recoveryRepairSubstrateReadBack
  :: Either Text LocalRke2RecoveryStateView -> RecoveryRepairSubstrateConvergence
recoveryRepairSubstrateReadBack = \case
  Left detail -> RecoveryRepairSubstrateUnverifiable detail
  Right LocalRke2RecoveryHealthy -> RecoveryRepairSubstrateConverged
  Right state -> RecoveryRepairSubstrateUnconverged state

stateText :: LocalRke2RecoveryStateView -> String
stateText = \case
  LocalRke2RecoveryHealthy -> "healthy"
  LocalRke2RecoveryStopped -> "stopped"
  LocalRke2RecoveryAbsent -> "absent"

commaSeparated :: [String] -> String
commaSeparated = \case
  [] -> ""
  [single] -> single
  first : remaining -> first ++ ", " ++ commaSeparated remaining
