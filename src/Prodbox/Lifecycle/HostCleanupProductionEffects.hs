{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the host cleanup runner's production effects record.
--
-- "Prodbox.Lifecycle.HostCleanupRunner" performs the destructive host boundary
-- through twelve injected arms, and by the time this module was written every
-- one of them had a production surface and nothing assembled them: the runner
-- could only ever be driven by a fixture.  This module is the assembly, and it
-- is what "Prodbox.ControlPlane.CascadeHostRuntime" is handed to become a
-- closed runtime.
--
-- Four properties carry the design.
--
--   * __Every arm reads its own source.__  No arm is told another's answer and
--     the record holds no mutable state, so an arm asked twice observes twice.
--     That is what makes the runner's two readiness read-backs — the same
--     question before the uninstall and after re-establishment — two
--     observations rather than one cached value.
--
--   * __The completion read-back derives its own prerequisites.__  It needs the
--     run's readiness and its observed local-uninstall evidence, and it obtains
--     both by observing: the readiness from the Authority's durable slot, the
--     absence from a fresh marker observation.  Remembering what the commit arm
--     was handed would have been wrong in the case that matters most — a
--     resumed run reaches the verification without issuing a commit at all, so
--     a remembered value would be missing exactly when the run is closing.
--
--   * __A host that is not absent refuses the completion read-back.__  The
--     receipt's meaning is that /this run/ recorded its own local absence, so
--     asking the journal about a host whose markers are still present would
--     compare a durable entry against a proof the run does not hold.  A host
--     that could not be observed is a third answer and stays distinct from
--     both.
--
--   * __The repair closure decides with production observations.__  Everything
--     the repair needs to /decide/ — the substrate observation and the
--     retained-store listing — is production here, and listing the store is
--     available from a bootstrap-located root because listing is not a
--     mutation, which is what a recovery holds while the Authority is absent.
--     The mutations under it are
--     "Prodbox.Lifecycle.Teardown.RecoveryRepairProduction" for the install,
--     the service start, the API wait, and the image import; only the recovery
--     chart reconcile is supplied from above, because chart delivery sits above
--     the lifecycle surface rather than beside it.
--
-- What this module does not own: the content of any arm, which belongs to the
-- production surface it delegates to; the durable phase transitions, which
-- belong to "Prodbox.Lifecycle.HostCleanupIntent"; and the construction of the
-- sources themselves, which is the non-public candidate entrypoint Sprint
-- @4.86@ still owns.  Assembling this record activates no writer: nothing in
-- the repository constructs it.
module Prodbox.Lifecycle.HostCleanupProductionEffects
  ( -- * The production repair closure
    productionHostRecoveryPlaneRepair

    -- * The completion read-back's prerequisites
  , CompletionPrerequisiteRefusal (..)
  , renderCompletionPrerequisiteRefusal
  , completionReadBackPrerequisites

    -- * The record
  , HostCleanupProductionSources (..)
  , productionHostCleanupRunnerEffects

    -- * Regression over the closed prerequisite table
  , HostCleanupProductionEffectsRegression
  , fixedHostCleanupProductionEffectsRegression
  , productionEffectsRegressionBothObservedResolve
  , productionEffectsRegressionReadinessUnavailableRefused
  , productionEffectsRegressionStillInstalledRefused
  , productionEffectsRegressionUnobservableRefused
  , productionEffectsRegressionRefusalsAreDistinct
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Config.LocalRke2RecoveryState
  ( localRke2RecoveryStateView
  , observeLocalRke2RecoveryState
  , renderLocalRke2RecoveryStateError
  )
import Prodbox.Config.OrdinaryTeardownRecovery (OrdinaryTeardownRecovery)
import Prodbox.Config.OrdinaryTeardownRepair (RetainedArtifactInventory)
import Prodbox.ControlPlane.CleanupRunClient (CleanupRunClient)
import Prodbox.ControlPlane.HostCleanupReadinessRepository
  ( HostCleanupReadinessAuthorityClient
  )
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( LifecycleAuthorityAdmissionWait
  , RetainedAuthorityAggregateSources
  , productionHostCleanupAuthorityReestablish
  )
import Prodbox.Lifecycle.HostCleanupAuthorityArms
  ( productionHostCleanupAcceptAuthority
  , productionHostCleanupAuthorityReadBack
  , productionHostCleanupRunReadBack
  , productionHostCleanupRunReconcile
  )
import Prodbox.Lifecycle.HostCleanupCompletion
  ( HostCleanupCompletionJournal
  , productionHostCleanupCompletionCommit
  , productionHostCleanupCompletionReadBack
  )
import Prodbox.Lifecycle.HostCleanupLocalAbsence
  ( productionHostCleanupLocalAbsenceReadBack
  )
import Prodbox.Lifecycle.HostCleanupRecoveryPlane
  ( HostRecoveryPlaneRepair (..)
  , establishHostRecoveryPlane
  , hostRecoveryPlaneEstablishmentEffect
  , productionHostCleanupRecoveryPlaneReadBack
  )
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2TerminalAdapter
  , hostCleanupRunLocalRke2Uninstall
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerContext
  , HostCleanupRunnerEffects (..)
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( LocalUninstallEvidence
  , ReadyToUninstallEvidence
  )
import Prodbox.Lifecycle.Teardown.Model (CleanupSurface (Cascade))
import Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
  ( RecoveryRepairBoundary
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactSourceCatalog
  , RetainedArtifactStore
  , observeRetainedArtifactStore
  )

-- ---------------------------------------------------------------------------
-- The production repair closure
-- ---------------------------------------------------------------------------

-- | Everything the recovery repair needs to decide, taken from the host.
--
-- The two observations are production and the five mutations are not: a
-- repair is /rendered for an observed state/ and /admitted against an observed
-- store/, so deciding must not be injectable, while installing a substrate,
-- starting its service, awaiting its API, loading a retained image, and
-- reconciling a recovery chart are host mutations the candidate entrypoint
-- supplies.
--
-- The store is listed through whichever root the caller located, because
-- listing is not a mutation and a recovery holds a bootstrap-located root
-- precisely when the Authority is gone.
productionHostRecoveryPlaneRepair
  :: RetainedArtifactStore authority
  -> RecoveryRepairBoundary IO
  -> HostRecoveryPlaneRepair IO
productionHostRecoveryPlaneRepair store boundary =
  HostRecoveryPlaneRepair
    { hostRecoveryObserveState =
        either
          (Left . renderLocalRke2RecoveryStateError)
          (Right . localRke2RecoveryStateView)
          <$> observeLocalRke2RecoveryState
    , hostRecoveryObserveStore = observeRetainedArtifactStore store
    , hostRecoveryRepairBoundary = boundary
    }

-- ---------------------------------------------------------------------------
-- The completion read-back's prerequisites
-- ---------------------------------------------------------------------------

-- | Why the completion read-back could not be taken.
--
-- Each arm is a fact about what the run holds, not about the journal: the
-- journal is not consulted at all until both prerequisites are observed.
data CompletionPrerequisiteRefusal
  = -- | The Authority does not hold this run's accepted readiness.
    CompletionReadinessUnavailable !Text
  | -- | The host's install markers are still present, so the run holds no
    -- local-absence proof to read a completion back against.
    CompletionHostStillInstalled
  | -- | The host's install markers could not be observed, which decides
    -- neither presence nor absence.
    CompletionHostUnobservable !Text
  deriving (Eq, Show)

renderCompletionPrerequisiteRefusal :: CompletionPrerequisiteRefusal -> Text
renderCompletionPrerequisiteRefusal = \case
  CompletionReadinessUnavailable detail ->
    "the local-completion read-back has no readiness to check against: " <> detail
  CompletionHostStillInstalled ->
    "the local-completion read-back was asked for while local RKE2 install "
      <> "markers are still present, so this run holds no local-absence proof"
  CompletionHostUnobservable detail ->
    "the local-completion read-back could not observe the local RKE2 install "
      <> "markers, which decides neither presence nor absence: "
      <> detail

-- | Resolve the two values the production completion read-back needs from the
-- two observations that produce them.
--
-- The type mentions neither proof, and deliberately so: routing is all this
-- function may do, and a signature that named 'ReadyToUninstallEvidence' and
-- 'LocalUninstallEvidence' would leave room for it to inspect them.  It also
-- makes the table exercisable over stand-in values, so the four arms are
-- measured without an Authority, a host, or a proof.
completionReadBackPrerequisites
  :: Either Text ready
  -> Either Text (Maybe local)
  -> Either CompletionPrerequisiteRefusal (ready, local)
completionReadBackPrerequisites readiness absence = case readiness of
  Left detail -> Left (CompletionReadinessUnavailable detail)
  Right ready -> case absence of
    Left detail -> Left (CompletionHostUnobservable detail)
    Right Nothing -> Left CompletionHostStillInstalled
    Right (Just local) -> Right (ready, local)

-- ---------------------------------------------------------------------------
-- The record
-- ---------------------------------------------------------------------------

-- | The production surfaces every arm of the runner delegates to.
--
-- Grouped rather than passed positionally because the runner has twelve arms
-- and a positional assembly of eleven sources is a defect waiting to be
-- introduced by an insertion.
data HostCleanupProductionSources = HostCleanupProductionSources
  { hostCleanupReadinessClient :: !(HostCleanupReadinessAuthorityClient IO)
  , hostCleanupRunClient :: !(CleanupRunClient IO)
  , hostCleanupTerminalAdapter :: !(LocalRke2TerminalAdapter IO)
  , hostCleanupCompletionJournal :: !HostCleanupCompletionJournal
  , hostCleanupRecoveryInventory :: !RetainedArtifactInventory
  , hostCleanupRecoveryCatalog :: !RetainedArtifactSourceCatalog
  , hostCleanupRecoveryClosure :: !OrdinaryTeardownRecovery
  , hostCleanupRecoveryRepair :: !(HostRecoveryPlaneRepair IO)
  , hostCleanupAuthorityPause :: !(Natural -> IO ())
  , hostCleanupAuthorityWait :: !LifecycleAuthorityAdmissionWait
  , hostCleanupAuthorityAggregate :: !(RetainedAuthorityAggregateSources IO)
  }

-- | Assemble the twelve arms.
--
-- Each arm is one production surface applied to one source; the assembly adds
-- no decision of its own except the completion read-back's prerequisites,
-- which are resolved by the table above rather than here.
productionHostCleanupRunnerEffects
  :: HostCleanupProductionSources -> HostCleanupRunnerEffects IO
productionHostCleanupRunnerEffects sources =
  HostCleanupRunnerEffects
    { hostRunnerAcceptAuthority =
        productionHostCleanupAcceptAuthority (hostCleanupReadinessClient sources)
    , hostRunnerReadBackAuthorityAcceptance = readBackReadiness
    , hostRunnerRunLocalUninstall =
        hostCleanupRunLocalRke2Uninstall (hostCleanupTerminalAdapter sources)
    , hostRunnerReadBackLocalAbsence = readBackAbsence
    , hostRunnerReestablishBootstrapRecovery = \_context ->
        hostRecoveryPlaneEstablishmentEffect
          <$> establishHostRecoveryPlane
            (hostCleanupRecoveryInventory sources)
            (hostCleanupRecoveryCatalog sources)
            (hostCleanupRecoveryClosure sources)
            (hostCleanupRecoveryRepair sources)
    , hostRunnerReadBackBootstrapRecovery =
        productionHostCleanupRecoveryPlaneReadBack
    , hostRunnerReestablishLifecycleAuthority =
        productionHostCleanupAuthorityReestablish
          (hostCleanupAuthorityPause sources)
          (hostCleanupAuthorityWait sources)
          (hostCleanupAuthorityAggregate sources)
    , -- The same question the acceptance read-back asks, asked again after
      -- re-establishment.  An Authority that cannot produce the readiness it
      -- accepted has not been re-established in the sense the run needs, and a
      -- weaker second source would hide exactly that.
      hostRunnerReadBackLifecycleAuthority = readBackReadiness
    , hostRunnerReconcileCleanupRun = \context _local ->
        productionHostCleanupRunReconcile (hostCleanupRunClient sources) context
    , hostRunnerReadBackCleanupRun =
        productionHostCleanupRunReadBack (hostCleanupRunClient sources)
    , hostRunnerCommitCompletionReceipt =
        productionHostCleanupCompletionCommit (hostCleanupCompletionJournal sources)
    , hostRunnerReadBackCompletionReceipt = \context -> do
        readiness <- readBackReadiness context
        absence <- case readiness of
          Left detail -> pure (Left detail)
          Right ready -> readBackAbsence context ready
        case completionReadBackPrerequisites readiness absence of
          Left refusal -> pure (Left (renderCompletionPrerequisiteRefusal refusal))
          Right (ready, local) ->
            productionHostCleanupCompletionReadBack
              (hostCleanupCompletionJournal sources)
              ready
              local
              context
    }
 where
  readBackReadiness :: HostCleanupRunnerContext -> IO (Either Text ReadyToUninstallEvidence)
  readBackReadiness =
    productionHostCleanupAuthorityReadBack (hostCleanupReadinessClient sources)

  readBackAbsence
    :: HostCleanupRunnerContext
    -> ReadyToUninstallEvidence
    -> IO (Either Text (Maybe (LocalUninstallEvidence 'Cascade)))
  readBackAbsence =
    productionHostCleanupLocalAbsenceReadBack (hostCleanupTerminalAdapter sources)

-- ---------------------------------------------------------------------------
-- Regression over the closed prerequisite table
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without an Authority, a host, or a
-- readiness proof leaving this package.
--
-- The table is the one decision this module makes; every other arm is a
-- production surface measured by its own regression, and the end-to-end
-- exercise of the assembled record belongs to the candidate entrypoint's fault
-- matrix, which Sprint @4.86@ still owns.
data HostCleanupProductionEffectsRegression = HostCleanupProductionEffectsRegression
  { productionEffectsRegressionBothObservedResolve :: !Bool
  , productionEffectsRegressionReadinessUnavailableRefused :: !Bool
  , productionEffectsRegressionStillInstalledRefused :: !Bool
  , productionEffectsRegressionUnobservableRefused :: !Bool
  , productionEffectsRegressionRefusalsAreDistinct :: !Bool
  }

fixedHostCleanupProductionEffectsRegression
  :: HostCleanupProductionEffectsRegression
fixedHostCleanupProductionEffectsRegression =
  HostCleanupProductionEffectsRegression
    { -- Only the arm in which both observations answered produces the pair the
      -- journal is then addressed with, and it produces exactly what it was
      -- handed.
      productionEffectsRegressionBothObservedResolve =
        completionReadBackPrerequisites (Right readinessStandIn) (Right (Just absenceStandIn))
          == Right (readinessStandIn, absenceStandIn)
    , -- An Authority that holds no accepted readiness is refused before the
      -- markers are consulted, so the run is never asked about a host on
      -- behalf of a readiness nobody holds.
      productionEffectsRegressionReadinessUnavailableRefused =
        completionReadBackPrerequisites
          (Left "the Authority holds no accepted readiness" :: Either Text Int)
          (Right (Just absenceStandIn))
          == Left (CompletionReadinessUnavailable "the Authority holds no accepted readiness")
    , -- A host whose markers are present has not converged, so the run holds no
      -- local-absence proof to read a completion back against.
      productionEffectsRegressionStillInstalledRefused =
        completionReadBackPrerequisites (Right readinessStandIn) (Right absentStandIn)
          == Left CompletionHostStillInstalled
    , -- A host that could not be observed decides neither presence nor absence,
      -- and stays a third answer rather than collapsing into either.
      productionEffectsRegressionUnobservableRefused =
        completionReadBackPrerequisites
          (Right readinessStandIn)
          (Left "the install markers could not be read" :: Either Text (Maybe Int))
          == Left (CompletionHostUnobservable "the install markers could not be read")
    , productionEffectsRegressionRefusalsAreDistinct =
        length
          ( distinctRefusals
              [ CompletionReadinessUnavailable "a"
              , CompletionHostStillInstalled
              , CompletionHostUnobservable "b"
              ]
          )
          == 3
    }
 where
  -- The table routes; it never inspects.  Stand-ins are what proves that,
  -- because a resolution that read either proof could not typecheck against
  -- them.
  readinessStandIn :: Int
  readinessStandIn = 1

  absenceStandIn :: Int
  absenceStandIn = 2

  absentStandIn :: Maybe Int
  absentStandIn = Nothing

distinctRefusals :: [CompletionPrerequisiteRefusal] -> [Text]
distinctRefusals = foldr keep []
 where
  keep refusal seen =
    let rendered = renderCompletionPrerequisiteRefusal refusal
     in if rendered `elem` seen then seen else rendered : seen
