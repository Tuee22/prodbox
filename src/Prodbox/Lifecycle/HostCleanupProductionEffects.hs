{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production effects for the host terminal boundary.  Authority readiness
-- is accepted before the handoff is armed.  The separate local effects record
-- captures only the native RKE2 adapter and preserved completion journal, so
-- it can outlive authenticated sessions without retaining remote closures.
-- Every completion read takes a fresh native absence observation and compares
-- the journal receipt with the opaque readiness restored by the host runner.
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
  , productionHostCleanupLocalRunnerEffects

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
import Prodbox.Config.LocalRke2RecoveryState
  ( localRke2RecoveryStateView
  , observeLocalRke2RecoveryState
  , renderLocalRke2RecoveryStateError
  )
import Prodbox.ControlPlane.HostCleanupReadinessRepository
  ( HostCleanupReadinessAuthorityClient
  )
import Prodbox.Lifecycle.HostCleanupAuthorityArms
  ( productionHostCleanupAcceptAuthority
  , productionHostCleanupAuthorityReadBack
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
  )
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2TerminalAdapter
  , hostCleanupRunLocalRke2Uninstall
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (HostCleanupEffectRefused)
  , HostCleanupRunnerContext
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
  ( RetainedArtifactStore
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

-- | Sources needed while Authority readiness is accepted.  Recovery and
-- credential retirement belong to the remote prefix, before these effects
-- arm the terminal handoff.
data HostCleanupProductionSources = HostCleanupProductionSources
  { hostCleanupReadinessClient :: !(HostCleanupReadinessAuthorityClient IO)
  , hostCleanupTerminalAdapter :: !(LocalRke2TerminalAdapter IO)
  , hostCleanupCompletionJournal :: !HostCleanupCompletionJournal
  }

productionHostCleanupRunnerEffects
  :: HostCleanupProductionSources -> HostCleanupRunnerEffects IO
productionHostCleanupRunnerEffects sources =
  ( productionHostCleanupLocalRunnerEffects
      (hostCleanupTerminalAdapter sources)
      (hostCleanupCompletionJournal sources)
  )
    { hostRunnerAcceptAuthority =
        productionHostCleanupAcceptAuthority (hostCleanupReadinessClient sources)
    , hostRunnerReadBackAuthorityAcceptance =
        productionHostCleanupAuthorityReadBack (hostCleanupReadinessClient sources)
    }

-- | The post-session record has no Authority, Backup or Agent transport.
-- An unarmed record refuses rather than recovering or installing a cluster.
productionHostCleanupLocalRunnerEffects
  :: LocalRke2TerminalAdapter IO
  -> HostCleanupCompletionJournal
  -> HostCleanupRunnerEffects IO
productionHostCleanupLocalRunnerEffects terminal journal =
  HostCleanupRunnerEffects
    { hostRunnerAcceptAuthority = \_ _ -> pure (HostCleanupEffectRefused unarmed)
    , hostRunnerReadBackAuthorityAcceptance = \_ -> pure (Left unarmed)
    , hostRunnerRunLocalUninstall = hostCleanupRunLocalRke2Uninstall terminal
    , hostRunnerReadBackLocalAbsence = readBackAbsence
    , hostRunnerCommitCompletionReceipt = productionHostCleanupCompletionCommit journal
    , hostRunnerReadBackCompletionReceipt = \context ready -> do
        absence <- readBackAbsence context ready
        case completionReadBackPrerequisites (Right ready) absence of
          Left refusal -> pure (Left (renderCompletionPrerequisiteRefusal refusal))
          Right (observedReady, local) ->
            productionHostCleanupCompletionReadBack journal observedReady local context
    }
 where
  unarmed = "the local terminal tail requires an Authority-accepted, armed handoff"

  readBackAbsence
    :: HostCleanupRunnerContext
    -> ReadyToUninstallEvidence
    -> IO (Either Text (Maybe (LocalUninstallEvidence 'Cascade)))
  readBackAbsence = productionHostCleanupLocalAbsenceReadBack terminal

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
