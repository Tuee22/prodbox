{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Resolve the retained host root and the pre-uninstall Authority/Backup
-- sources.  The local composition contains no authenticated transport and
-- separately constructs the native terminal effects used after sessions close.
-- The inventory, source catalog, recovery declaration and Authority coordinate
-- are validated from the Tier-0 floor before authentication.  Every host record,
-- artifact and completion journal is derived from the same located root.
-- Recovery and chart reconciliation belong before the terminal handoff; this
-- composition never rebuilds RKE2 after its local absence was observed.
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
  , hostCleanupLocalRunnerEffects
  , resolveHostCleanupLocalComposition
  , HostCleanupTerminalComposition
  , hostCleanupLocalTerminalComposition
  , hostCleanupTerminalIntentStore
  , hostCleanupTerminalRunnerEffects
  , resolveHostCleanupTerminalComposition
  , resolveHostCleanupBootstrapPredecessor
  , reconcileHostCleanupBootstrapPredecessor

    -- * The whole record
  , HostCleanupProductionRuntime (..)
  , withHostCleanupProductionSources
  )
where

import Control.Monad (join, void)
import Data.Bifunctor qualified as Bifunctor
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Config.LocalRetainedRoot
  ( BootstrapRetainedRootLocator
  , LocalRetainedRootError
  , locateBootstrapRetainedRoot
  , locateBootstrapRetainedRootForHostCleanup
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
import Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClientError
  , observeProviderBootstrapPredecessorWithTransport
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
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError (CleanupRunClientDescriptorTombstoned)
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunTerminal
  , observeDescriptorBoundCleanupRun
  , observeDescriptorBoundCleanupRunCompletion
  )
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
  , withTargetSecretAgentAuthenticatedTransport
  )
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( LifecycleAuthorityAdmissionWait
  )
import Prodbox.ControlPlane.TargetMaterialClient
  ( observeRegisteredTargetMaterial
  , targetMaterialClient
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (targetMaterialObservedGeneration)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderBootstrapPredecessor
  , ProviderBootstrapPredecessorPhase (..)
  , providerBootstrapPredecessorGraphDigest
  , providerBootstrapPredecessorPhase
  , providerBootstrapPredecessorRunId
  , providerBootstrapPredecessorScopeDigest
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( longLivedCheckpointAuthorityFromBasics
  )
import Prodbox.Lifecycle.CheckpointAuthority (LongLivedCheckpointAuthority)
import Prodbox.Lifecycle.CleanupRun (cleanupReportGraphDigest)
import Prodbox.Lifecycle.HostCleanupCompletion
  ( HistoricalHostCleanupCompletion
  , HistoricalHostCleanupCompletionError (..)
  , HostCleanupCompletionJournal
  , bootstrapLocatedHostCleanupCompletionJournal
  , historicalHostCleanupIntent
  , observeHistoricalHostCleanupCompletion
  , observeHistoricalHostCleanupCompletionForRun
  )
import Prodbox.Lifecycle.HostCleanupHistoryReconcile
  ( HistoricalCleanupImportError (HistoricalCleanupAuthorityReadFailed)
  , reconcileHistoricalHostCleanup
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentError
  , HostCleanupIntentStore
  , bootstrapLocatedHostCleanupIntentStore
  , hostCleanupGraphDigest
  , hostCleanupObservationEvidenceScope
  , hostCleanupRunId
  , hostCleanupScope
  )
import Prodbox.Lifecycle.HostCleanupProductionEffects
  ( HostCleanupProductionSources (..)
  , productionHostCleanupLocalRunnerEffects
  , productionHostCleanupRunnerEffects
  )
import Prodbox.Lifecycle.HostCleanupRke2 (productionLocalRke2TerminalAdapter)
import Prodbox.Lifecycle.HostCleanupRunner (HostCleanupRunnerEffects)
import Prodbox.Lifecycle.Teardown.Observation (terminalAuditEvidenceScopeDigest)
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
  ( RecoveryRepairChartReconciler
  , RecoveryRepairPlatformReconciler
  , SubstrateApiWait
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactStore
  , RetainedArtifactStoreAuthority (BootstrapLocatedStore)
  , bootstrapLocatedRetainedArtifactStore
  )
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForCascadeTerminalAudit)
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
  | HostCleanupCompositionPredecessorUnresolved !HistoricalHostCleanupCompletionError
  | HostCleanupCompositionPredecessorImportFailed !HistoricalCleanupImportError
  | HostCleanupCompositionAuthorityPredecessorUnobservable !AuthorityControlClientError
  | HostCleanupCompositionAuthorityPredecessorMismatch
  | HostCleanupCompositionPredecessorNeedsRecovery !ProviderBootstrapPredecessor
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
  HostCleanupCompositionPredecessorUnresolved err ->
    "the previous host cleanup must finish before bootstrap: "
      ++ show err
      ++ ". "
      ++ predecessorRemedy err
  HostCleanupCompositionPredecessorImportFailed err ->
    "the restored Authority could not confirm the previous host cleanup: "
      ++ show err
      ++ ". Retry prodbox cluster reconcile; the exact journals and completed nodes are preserved."
  HostCleanupCompositionAuthorityPredecessorUnobservable err ->
    "the restored Authority predecessor could not be observed: "
      ++ show err
      ++ ". Restore Authority availability, then retry prodbox cluster reconcile."
  HostCleanupCompositionAuthorityPredecessorMismatch ->
    "NukeOnly: the retained Authority reservation and host completion history disagree; "
      ++ "operator-only prodbox nuke is the total-decommission remedy. This run cannot qualify."
  HostCleanupCompositionPredecessorNeedsRecovery predecessor ->
    "the previous cascade remains "
      ++ show (providerBootstrapPredecessorPhase predecessor)
      ++ " for run "
      ++ show (providerBootstrapPredecessorRunId predecessor)
      ++ ". Resume prodbox test integration cascade-qualification with its original "
      ++ "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE before fresh credentials or bootstrap continuation."
  HostCleanupCompositionAuthenticationFailed err ->
    renderLifecycleAuthorityAuthenticationError err

predecessorRemedy :: HistoricalHostCleanupCompletionError -> String
predecessorRemedy cause = case cause of
  HistoricalHostCleanupNotComplete _ ->
    "Resume prodbox test integration cascade-qualification with its original "
      ++ "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE; it uses the preserved terminal journals."
  HistoricalHostCleanupIntentUnobservable _ -> retryObservation
  HistoricalHostCleanupJournalUnobservable _ -> retryObservation
  HistoricalHostCleanupIntentChanged -> retryObservation
  HistoricalHostCleanupHandoffMissing -> lostProof
  HistoricalHostCleanupBindingMismatch -> lostProof
  HistoricalHostCleanupReadinessInvalid _ -> lostProof
  HistoricalHostCleanupJournalMissing -> lostProof
  HistoricalHostCleanupReceiptMismatch -> lostProof
  HistoricalHostCleanupReportInvalid _ -> lostProof
  HistoricalHostCleanupRetirementMissing -> lostProof
 where
  retryObservation =
    "Restore read access to the preserved journals, then retry prodbox cluster reconcile."
  lostProof =
    "NukeOnly: independent completion evidence is missing or inconsistent; "
      ++ "operator-only prodbox nuke is the total-decommission remedy. This run cannot qualify."

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

-- | Build only host-native effects from the retained local composition.
-- No authenticated transport can be captured by this constructor.
hostCleanupLocalRunnerEffects
  :: FilePath
  -> HostCleanupLocalComposition
  -> HostCleanupRunnerEffects IO
hostCleanupLocalRunnerEffects repositoryRoot local =
  productionHostCleanupLocalRunnerEffects
    (productionLocalRke2TerminalAdapter repositoryRoot)
    (localJournal local)

-- | Only the two preserved local journals. Resolving a terminal resume needs
-- no service settings, artifact inventory, recovery declaration or transport.
data HostCleanupTerminalComposition
  = HostCleanupTerminalComposition
      !HostCleanupIntentStore
      !HostCleanupCompletionJournal

hostCleanupLocalTerminalComposition :: HostCleanupLocalComposition -> HostCleanupTerminalComposition
hostCleanupLocalTerminalComposition local = HostCleanupTerminalComposition (localIntentStore local) (localJournal local)

hostCleanupTerminalIntentStore :: HostCleanupTerminalComposition -> HostCleanupIntentStore
hostCleanupTerminalIntentStore (HostCleanupTerminalComposition store _) = store

hostCleanupTerminalRunnerEffects
  :: FilePath -> HostCleanupTerminalComposition -> HostCleanupRunnerEffects IO
hostCleanupTerminalRunnerEffects repositoryRoot (HostCleanupTerminalComposition _ journal) =
  productionHostCleanupLocalRunnerEffects (productionLocalRke2TerminalAdapter repositoryRoot) journal

resolveHostCleanupTerminalComposition
  :: FilePath -> IO (Either HostCleanupCompositionError HostCleanupTerminalComposition)
resolveHostCleanupTerminalComposition repositoryRoot = do
  located <- locateBootstrapRetainedRoot repositoryRoot
  pure $ do
    locator <- Bifunctor.first HostCleanupCompositionRetainedRootUnusable located
    store <-
      Bifunctor.first
        HostCleanupCompositionIntentStoreUnusable
        (bootstrapLocatedHostCleanupIntentStore locator)
    journal <-
      Bifunctor.first
        HostCleanupCompositionJournalUnusable
        (bootstrapLocatedHostCleanupCompletionJournal locator)
    Right (HostCleanupTerminalComposition store journal)

-- | Observe the predecessor before any installer effect. A missing exact
-- active path permits a fresh bootstrap; a present record must have its sealed
-- handoff and independent completion journal. This is historical evidence,
-- never a claim that the host is absent now.
resolveHostCleanupBootstrapPredecessor
  :: FilePath
  -> IO
       ( Either
           HostCleanupCompositionError
           (Maybe (HostCleanupTerminalComposition, HistoricalHostCleanupCompletion))
       )
resolveHostCleanupBootstrapPredecessor repositoryRoot = do
  located <- locateBootstrapRetainedRootForHostCleanup repositoryRoot
  case Bifunctor.first HostCleanupCompositionRetainedRootUnusable located of
    Left cause -> pure (Left cause)
    Right Nothing -> pure (Right Nothing)
    Right (Just locator) ->
      case terminalComposition locator of
        Left cause -> pure (Left cause)
        Right terminal@(HostCleanupTerminalComposition store journal) -> do
          history <- observeHistoricalHostCleanupCompletion store journal
          pure $
            Bifunctor.first
              HostCleanupCompositionPredecessorUnresolved
              (fmap (fmap (terminal,)) history)
 where
  terminalComposition locator = do
    store <-
      Bifunctor.first
        HostCleanupCompositionIntentStoreUnusable
        (bootstrapLocatedHostCleanupIntentStore locator)
    journal <-
      Bifunctor.first
        HostCleanupCompositionJournalUnusable
        (bootstrapLocatedHostCleanupCompletionJournal locator)
    Right (HostCleanupTerminalComposition store journal)

-- | Called only after Authority/Backup admission has been restored, before
-- fresh operational credentials. The original local attempts are imported;
-- no uninstall or provider effect belongs to this bootstrap continuation.
reconcileHostCleanupBootstrapPredecessor
  :: FilePath
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> Natural
  -> IO (Either HostCleanupCompositionError ())
reconcileHostCleanupBootstrapPredecessor repositoryRoot transport now = do
  observed <- observeProviderBootstrapPredecessorWithTransport transport
  predecessor <- case observed of
    Left cause -> pure (Left (HostCleanupCompositionAuthorityPredecessorUnobservable cause))
    Right Nothing -> resolveHostCleanupBootstrapPredecessor repositoryRoot
    Right (Just binding)
      | providerBootstrapPredecessorPhase binding /= ProviderBootstrapRevoked ->
          pure (Left (HostCleanupCompositionPredecessorNeedsRecovery binding))
      | otherwise -> do
          located <- resolveRevoked binding
          pure (located >>= validateLocated binding)

  case predecessor of
    Left cause -> pure (Left cause)
    Right Nothing -> pure (Right ())
    Right (Just (HostCleanupTerminalComposition store _, history)) -> do
      imported <-
        reconcileHistoricalHostCleanup
          (descriptorBoundCleanupRunClient transport)
          store
          now
          history
      pure (Bifunctor.first HostCleanupCompositionPredecessorImportFailed (void imported))
 where
  client = descriptorBoundCleanupRunClient transport
  resolveRevoked binding = do
    remote <- observeDescriptorBoundCleanupRun client (providerBootstrapPredecessorRunId binding)
    case remote of
      Left (CleanupRunClientDescriptorTombstoned digest _) -> do
        observed <-
          observeDescriptorBoundCleanupRunCompletion client (providerBootstrapPredecessorRunId binding) digest
        case observed of
          Left cause ->
            pure
              (Left (HostCleanupCompositionPredecessorImportFailed (HistoricalCleanupAuthorityReadFailed cause)))
          Right (Just report)
            | cleanupReportGraphDigest report == providerBootstrapPredecessorGraphDigest binding ->
                resolveActiveOrRetired binding True
          Right _ -> pure (Left HostCleanupCompositionAuthorityPredecessorMismatch)
      Left cause ->
        pure
          (Left (HostCleanupCompositionPredecessorImportFailed (HistoricalCleanupAuthorityReadFailed cause)))
      Right bound
        | descriptorBoundCleanupRunGraphDigest bound /= providerBootstrapPredecessorGraphDigest binding ->
            pure (Left HostCleanupCompositionAuthorityPredecessorMismatch)
        | otherwise -> resolveActiveOrRetired binding (descriptorBoundCleanupRunTerminal bound)
  resolveActiveOrRetired binding terminal = do
    active <- resolveHostCleanupBootstrapPredecessor repositoryRoot
    case active of
      Left cause -> pure (Left cause)
      Right (Just located) -> pure (Right (Just located))
      Right Nothing
        | not terminal -> pure (Left (HostCleanupCompositionPredecessorNeedsRecovery binding))
        | otherwise -> resolveRetired binding
  resolveRetired binding = do
    resolved <- resolveHostCleanupTerminalComposition repositoryRoot
    case resolved of
      Left cause -> pure (Left cause)
      Right terminal@(HostCleanupTerminalComposition store journal) -> do
        historical <-
          observeHistoricalHostCleanupCompletionForRun
            store
            journal
            (providerBootstrapPredecessorRunId binding)
        pure
          ( Bifunctor.first
              HostCleanupCompositionPredecessorUnresolved
              (fmap (\history -> Just (terminal, history)) historical)
          )
  validateLocated _ Nothing = Right Nothing
  validateLocated binding (Just located@(_, history)) =
    let intent = historicalHostCleanupIntent history
     in if hostCleanupRunId intent == providerBootstrapPredecessorRunId binding
          && hostCleanupGraphDigest intent == providerBootstrapPredecessorGraphDigest binding
          && terminalAuditEvidenceScopeDigest
            (scopeForCascadeTerminalAudit (hostCleanupObservationEvidenceScope (hostCleanupScope intent)))
            == providerBootstrapPredecessorScopeDigest binding
          then Right (Just located)
          else Left HostCleanupCompositionAuthorityPredecessorMismatch

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
  { hostCleanupProductionLocalComposition :: !HostCleanupLocalComposition
  , hostCleanupProductionIntentStore :: !HostCleanupIntentStore
  , hostCleanupProductionEffects :: !(HostCleanupRunnerEffects IO)
  , hostCleanupProductionAuthorityTransport
      :: !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
  , hostCleanupProductionProviderCredentialGeneration :: !(IO (Either Text (Maybe Natural)))
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
                          { hostCleanupProductionLocalComposition = local
                          , hostCleanupProductionIntentStore = localIntentStore local
                          , hostCleanupProductionEffects =
                              productionHostCleanupRunnerEffects
                                (sourcesFor local authorityTransport)
                          , hostCleanupProductionAuthorityTransport = authorityTransport
                          , hostCleanupProductionProviderCredentialGeneration = observeProviderGeneration authentication
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

  observeProviderGeneration authentication = do
    observed <- withTargetSecretAgentAuthenticatedTransport authentication $ \transport ->
      observeRegisteredTargetMaterial
        (targetMaterialClient transport)
        (TargetAwsCredential AwsLifecycleProvider)
    pure $ case observed of
      Left err -> Left (Text.pack (renderLifecycleAuthorityAuthenticationError err))
      Right (Left err) -> Left ("observe Lifecycle-provider generation: " <> Text.pack (show err))
      Right (Right metadata) -> Right (targetMaterialObservedGeneration <$> metadata)

  sourcesFor local authorityTransport =
    HostCleanupProductionSources
      { hostCleanupReadinessClient =
          modelBHostCleanupReadinessRepository
            (localAuthority local)
            (cascadeRetainedSlotModelBAdapter authorityTransport)
      , hostCleanupTerminalAdapter =
          productionLocalRke2TerminalAdapter (hostCleanupRepositoryRoot inputs)
      , hostCleanupCompletionJournal = localJournal local
      }
