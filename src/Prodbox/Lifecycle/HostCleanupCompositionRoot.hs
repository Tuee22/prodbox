{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the composition root for the host cleanup runner's production
-- sources.
--
-- "Prodbox.Lifecycle.HostCleanupProductionEffects" assembles twelve production
-- arms out of eleven sources, and by the time this module was written every one
-- of those sources had a production constructor and nothing built them
-- together: the record could be described but not constructed, so the closed
-- cascade host runtime the descriptor-bound dispatcher requires had no way to
-- exist.  This module builds them.
--
-- Five properties carry the design.
--
--   * __Everything decidable without a session is decided first.__  The Tier-0
--     declaration, the retained root, the inventory, the source catalog, the
--     recovery closure, and the Authority coordinate are all resolved before
--     any authenticated transport is opened.  A composition that opened a
--     session and then found a malformed digest would have taken a session it
--     cannot use, and would report an operator's typo as an Authority failure.
--
--   * __One retained root, both roots.__  The artifact store and the completion
--     journal are derived from a single located bootstrap root, so a run cannot
--     read its artifacts under one root and append its completion beside
--     another.
--
--   * __The repair inherits the declaration's architecture.__  It is taken from
--     the projected inventory rather than supplied again, so the architecture
--     the store was measured for and the architecture the installer stages for
--     are the same value.
--
--   * __Two transports, one authentication.__  The Lifecycle Authority session
--     and the Authority Backup Adapter session are opened from one
--     authenticated caller.  The second is not a convenience: it is what makes
--     re-establishment's confirmation independent of the Authority that is
--     being re-established.
--
--   * __The Tier-0 floor is the source, not the in-force projection.__  A
--     cascade repairs a control plane that may be absent, so a declaration
--     readable only through the Lifecycle Authority would be unreadable
--     precisely when the repair exists to run.  The consequence is stated
--     rather than hidden: an operator's retained-artifact change reaches a
--     recovery when it reaches @prodbox.dhall@, which is what Tier 0 is for.
--
-- What this module does not own: the content of any arm, which belongs to the
-- production surface it delegates to; the chart reconcile, which is chart
-- delivery and is supplied from above; and the decision to /run/ a cascade,
-- which is the non-public candidate entrypoint Sprint @4.86@ still owns.
-- Building these sources issues no host mutation and no wire call.
module Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( -- * What the caller supplies
    HostCleanupCompositionInputs (..)

    -- * What can go wrong before a session is opened
  , HostCleanupCompositionError (..)
  , renderHostCleanupCompositionError

    -- * The local half, resolved without a transport
  , HostCleanupLocalComposition
  , hostCleanupLocalArchitecture
  , hostCleanupLocalIntentStore
  , resolveHostCleanupLocalComposition

    -- * The whole record
  , HostCleanupProductionRuntime (..)
  , withHostCleanupProductionSources
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (join)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Config.LocalRetainedRoot
  ( BootstrapRetainedRootLocator
  , LocalRetainedRootError
  , locateBootstrapRetainedRoot
  , renderLocalRetainedRootError
  )
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownRecovery
  , OrdinaryTeardownRecoveryError
  , OrdinaryTeardownTargetAgent
  , ordinaryTeardownRecovery
  , renderOrdinaryTeardownRecoveryError
  )
import Prodbox.Config.RetainedArtifacts
  ( RetainedArtifactArchitecture
  , RetainedArtifactDeclarationError
  , RetainedArtifactInventory
  , RetainedArtifactSourceCatalog
  , declaredRetainedArtifactCatalog
  , declaredRetainedArtifactInventory
  , declaredRetainedArtifacts
  , renderRetainedArtifactDeclarationError
  , retainedArtifactInventoryArchitecture
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( authorityAggregateBackupClientWithTransport
  )
import Prodbox.ControlPlane.CascadeReportRepository
  ( CascadeReportAuthorityClient
  , modelBCascadeReportRepository
  )
import Prodbox.ControlPlane.CascadeRetainedSlotClient
  ( cascadeRetainedSlotModelBAdapter
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient
  , cleanupReportBackupClientWithTransport
  )
import Prodbox.ControlPlane.CleanupRunClient (cleanupRunClient)
import Prodbox.ControlPlane.HostCleanupReadinessRepository
  ( modelBHostCleanupReadinessRepository
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withAuthorityBackupAuthenticatedTransport
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( LifecycleAuthorityAdmissionWait
  , productionRetainedAuthorityAggregateSources
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( longLivedCheckpointAuthorityFromBasics
  )
import Prodbox.Lifecycle.CheckpointAuthority (LongLivedCheckpointAuthority)
import Prodbox.Lifecycle.HostCleanupCompletion
  ( HostCleanupCompletionJournal
  , bootstrapLocatedHostCleanupCompletionJournal
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentError
  , HostCleanupIntentStore
  , bootstrapLocatedHostCleanupIntentStore
  )
import Prodbox.Lifecycle.HostCleanupProductionEffects
  ( HostCleanupProductionSources (..)
  , productionHostCleanupRunnerEffects
  , productionHostRecoveryPlaneRepair
  )
import Prodbox.Lifecycle.HostCleanupRke2 (productionLocalRke2TerminalAdapter)
import Prodbox.Lifecycle.HostCleanupRunner (HostCleanupRunnerEffects)
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
  ( RecoveryRepairChartReconciler
  , RecoveryRepairPlatformReconciler
  , SubstrateApiWait
  , productionRecoveryRepairBoundary
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactStore
  , RetainedArtifactStoreAuthority (BootstrapLocatedStore)
  , bootstrapLocatedRetainedArtifactStore
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings
  ( ConfigFile (retained_artifacts)
  , loadConfigFile
  )

-- ---------------------------------------------------------------------------
-- What the caller supplies
-- ---------------------------------------------------------------------------

-- | The inputs a cascade brings that cannot be read off the host.
--
-- Deliberately small.  Everything an operator declared is read from Tier-0
-- config rather than passed in, so a caller cannot supply an inventory the
-- config does not carry — which is the difference between a repair the
-- repository can audit and one a call site invented.
data HostCleanupCompositionInputs = HostCleanupCompositionInputs
  { hostCleanupRepositoryRoot :: !FilePath
  , hostCleanupCaller :: !ExternalLifecycleAuthorityCaller
  , hostCleanupRecoveryTargetAgent :: !OrdinaryTeardownTargetAgent
  , hostCleanupSubstrateApiWait :: !SubstrateApiWait
  , hostCleanupAdmissionWait :: !LifecycleAuthorityAdmissionWait
  , hostCleanupPlatformReconciler :: !(RecoveryRepairPlatformReconciler IO)
  , hostCleanupChartReconciler :: !(RecoveryRepairChartReconciler IO)
  -- ^ Reconciling a recovery chart is chart delivery, which sits above the
  -- lifecycle surface; taking it as an input states that dependency rather
  -- than inverting it.
  }

-- ---------------------------------------------------------------------------
-- What can go wrong before a session is opened
-- ---------------------------------------------------------------------------

data HostCleanupCompositionError
  = HostCleanupCompositionBasicsUnreadable !String
  | HostCleanupCompositionConfigUnreadable !String
  | HostCleanupCompositionRetainedRootUnusable !LocalRetainedRootError
  | HostCleanupCompositionArtifactsUndeclarable !RetainedArtifactDeclarationError
  | HostCleanupCompositionRecoveryClosureInvalid !OrdinaryTeardownRecoveryError
  | HostCleanupCompositionAuthorityCoordinateInvalid !String
  | HostCleanupCompositionJournalUnusable !Text
  | HostCleanupCompositionIntentStoreUnusable !HostCleanupIntentError
  | HostCleanupCompositionAuthenticationFailed
      !LifecycleAuthorityAuthenticationError
  deriving stock (Eq, Show)

renderHostCleanupCompositionError :: HostCleanupCompositionError -> String
renderHostCleanupCompositionError = \case
  HostCleanupCompositionBasicsUnreadable detail ->
    "the Tier-0 basics floor could not be read: " ++ detail
  HostCleanupCompositionConfigUnreadable detail ->
    "the Tier-0 config could not be read: " ++ detail
  HostCleanupCompositionRetainedRootUnusable err ->
    "the retained root could not be located: "
      ++ Text.unpack (renderLocalRetainedRootError err)
  HostCleanupCompositionArtifactsUndeclarable err ->
    renderRetainedArtifactDeclarationError err
  HostCleanupCompositionRecoveryClosureInvalid err ->
    renderOrdinaryTeardownRecoveryError err
  HostCleanupCompositionAuthorityCoordinateInvalid detail ->
    "the retained authority coordinate is unusable: " ++ detail
  HostCleanupCompositionJournalUnusable detail ->
    "the local-completion journal could not be located: " ++ Text.unpack detail
  HostCleanupCompositionIntentStoreUnusable err ->
    "the durable host-cleanup record could not be located: " ++ show err
  HostCleanupCompositionAuthenticationFailed err ->
    renderLifecycleAuthorityAuthenticationError err

-- ---------------------------------------------------------------------------
-- The local half, resolved without a transport
-- ---------------------------------------------------------------------------

-- | Everything the record needs that the host can answer on its own.
--
-- Named and returned as a value so the transport-free half is exercisable, and
-- so the ordering property above is a fact about the types rather than a
-- comment: nothing here mentions a transport, so nothing here can have opened
-- one.
data HostCleanupLocalComposition = HostCleanupLocalComposition
  { localAuthority :: !LongLivedCheckpointAuthority
  , localAuthorityScope :: !Text
  , localRetainedRoot :: !BootstrapRetainedRootLocator
  , localArtifactStore :: !(RetainedArtifactStore 'BootstrapLocatedStore)
  , localInventory :: !RetainedArtifactInventory
  , localCatalog :: !RetainedArtifactSourceCatalog
  , localRecoveryClosure :: !OrdinaryTeardownRecovery
  , localJournal :: !HostCleanupCompletionJournal
  , localIntentStore :: !HostCleanupIntentStore
  }

-- | The durable record every cascade host node drives.
--
-- Derived from the same located root as the artifact store and the completion
-- journal, so a resumed run reads the phase it reached beside the bytes it
-- reached it with.
hostCleanupLocalIntentStore :: HostCleanupLocalComposition -> HostCleanupIntentStore
hostCleanupLocalIntentStore = localIntentStore

-- | The one architecture the declaration, the store, and the installer share.
hostCleanupLocalArchitecture
  :: HostCleanupLocalComposition -> RetainedArtifactArchitecture
hostCleanupLocalArchitecture =
  retainedArtifactInventoryArchitecture . localInventory

resolveHostCleanupLocalComposition
  :: HostCleanupCompositionInputs
  -> IO (Either HostCleanupCompositionError HostCleanupLocalComposition)
resolveHostCleanupLocalComposition inputs = do
  basicsResult <- loadUnencryptedBasics repoRoot
  configResult <- loadConfigFile repoRoot
  rootResult <- locateBootstrapRetainedRoot repoRoot
  pure $ do
    basics <- first HostCleanupCompositionBasicsUnreadable basicsResult
    config <- first HostCleanupCompositionConfigUnreadable configResult
    locator <- first HostCleanupCompositionRetainedRootUnusable rootResult
    authority <-
      first
        (HostCleanupCompositionAuthorityCoordinateInvalid . show)
        (longLivedCheckpointAuthorityFromBasics basics)
    declared <-
      first
        HostCleanupCompositionArtifactsUndeclarable
        (declaredRetainedArtifacts (retained_artifacts config))
    closure <-
      first
        HostCleanupCompositionRecoveryClosureInvalid
        (ordinaryTeardownRecovery (hostCleanupRecoveryTargetAgent inputs))
    journal <-
      first
        HostCleanupCompositionJournalUnusable
        (bootstrapLocatedHostCleanupCompletionJournal locator)
    intentStore <-
      first
        HostCleanupCompositionIntentStoreUnusable
        (bootstrapLocatedHostCleanupIntentStore locator)
    pure
      HostCleanupLocalComposition
        { localAuthority = authority
        , -- The observation scope and the retained coordinate are derived from
          -- one cluster id, so the Authority a run observes and the namespace
          -- it reads its readiness out of cannot name different clusters.
          localAuthorityScope = basicsClusterId basics
        , localRetainedRoot = locator
        , localArtifactStore = bootstrapLocatedRetainedArtifactStore locator
        , localInventory = declaredRetainedArtifactInventory declared
        , localCatalog = declaredRetainedArtifactCatalog declared
        , localRecoveryClosure = closure
        , localJournal = journal
        , localIntentStore = intentStore
        }
 where
  repoRoot = hostCleanupRepositoryRoot inputs
  first f = either (Left . f) Right

-- ---------------------------------------------------------------------------
-- The whole record
-- ---------------------------------------------------------------------------

-- | The durable record, the effects that act on it, and the session they were
-- built over.
--
-- Handed over as one value because they are only meaningful together: the
-- record says which phase a run reached, the effects perform the next one, and
-- both are scoped to the session the third field names.
data HostCleanupProductionRuntime = HostCleanupProductionRuntime
  { hostCleanupProductionIntentStore :: !HostCleanupIntentStore
  , hostCleanupProductionEffects :: !(HostCleanupRunnerEffects IO)
  , hostCleanupProductionAuthorityTransport
      :: !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
  , hostCleanupProductionCascadeReportAuthority
      :: !(CascadeReportAuthorityClient IO)
  , hostCleanupProductionCleanupReportBackup
      :: !(CleanupReportBackupClient IO)
  }

-- | Resolve the local half, open the two sessions, and hand the assembled
-- production runtime to an action.
--
-- The effects record is handed over rather than returned because both
-- transports are session-scoped: a record that outlived them would hold arms
-- that fail at their first call for a reason that says nothing about the run.
withHostCleanupProductionSources
  :: HostCleanupCompositionInputs
  -> (HostCleanupProductionRuntime -> IO value)
  -> IO (Either HostCleanupCompositionError value)
withHostCleanupProductionSources inputs action = do
  resolved <- resolveHostCleanupLocalComposition inputs
  case resolved of
    Left err -> pure (Left err)
    Right local -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication
          (hostCleanupCaller inputs)
          (hostCleanupRepositoryRoot inputs)
          ( \authentication ->
              withLifecycleAuthorityAuthenticatedTransport authentication $
                \authorityTransport ->
                  withAuthorityBackupAuthenticatedTransport authentication $
                    \backupTransport ->
                      action
                        HostCleanupProductionRuntime
                          { hostCleanupProductionIntentStore = localIntentStore local
                          , hostCleanupProductionEffects =
                              productionHostCleanupRunnerEffects
                                (sourcesFor local authorityTransport backupTransport)
                          , hostCleanupProductionAuthorityTransport = authorityTransport
                          , hostCleanupProductionCascadeReportAuthority =
                              modelBCascadeReportRepository
                                (localAuthority local)
                                (cascadeRetainedSlotModelBAdapter authorityTransport)
                          , hostCleanupProductionCleanupReportBackup =
                              cleanupReportBackupClientWithTransport backupTransport
                          }
          )
      pure (flattenAuthentication authenticated)
 where
  -- Three nested sessions, three identically typed refusals: the
  -- authenticated caller, the Authority transport, and the Backup Adapter
  -- transport.  Flattened rather than reported as nesting, because the caller
  -- has one question — did the composition reach its sessions — and the layer
  -- that failed is already named in the error it carries.
  flattenAuthentication outcome =
    case join (join outcome) of
      Left err -> Left (HostCleanupCompositionAuthenticationFailed err)
      Right value -> Right value

  sourcesFor local authorityTransport backupTransport =
    HostCleanupProductionSources
      { hostCleanupReadinessClient =
          modelBHostCleanupReadinessRepository
            (localAuthority local)
            (cascadeRetainedSlotModelBAdapter authorityTransport)
      , hostCleanupRunClient = cleanupRunClient authorityTransport
      , hostCleanupTerminalAdapter =
          productionLocalRke2TerminalAdapter (hostCleanupRepositoryRoot inputs)
      , hostCleanupCompletionJournal = localJournal local
      , hostCleanupRecoveryInventory = localInventory local
      , hostCleanupRecoveryCatalog = localCatalog local
      , hostCleanupRecoveryClosure = localRecoveryClosure local
      , hostCleanupRecoveryRepair =
          productionHostRecoveryPlaneRepair
            (localArtifactStore local)
            ( productionRecoveryRepairBoundary
                (hostCleanupLocalArchitecture local)
                (localArtifactStore local)
                (hostCleanupSubstrateApiWait inputs)
                (hostCleanupPlatformReconciler inputs)
                (hostCleanupChartReconciler inputs)
            )
      , hostCleanupAuthorityPause = threadDelay . fromIntegral
      , hostCleanupAuthorityWait = hostCleanupAdmissionWait inputs
      , hostCleanupAuthorityAggregate =
          productionRetainedAuthorityAggregateSources
            (localAuthorityScope local)
            authorityTransport
            (authorityAggregateBackupClientWithTransport backupTransport)
      }
