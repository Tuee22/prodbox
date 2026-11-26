module Prodbox.App
  ( App (..)
  , Env (..)
  , askEnv
  , canRunWithoutRepoRoot
  , liftAppIO
  , main
  , runApp
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader
  ( ReaderT (..)
  , ask
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Network.Socket qualified as Socket
import Options.Applicative
  ( customExecParser
  , prefs
  , showHelpOnEmpty
  , showHelpOnError
  )
import Prodbox.CLI.Command
  ( BootstrapBrokerCommand (..)
  , CommandListingFormat (..)
  , CommandRequest (..)
  , ConfigCommand (..)
  , GatewayCommand (..)
  , NativeCommand (..)
  , OperationCommand (..)
  , TestCommand (..)
  , TestScope (..)
  , VaultMaintenanceCommand (..)
  , VaultPkiCommand (..)
  , WorkloadCommand (..)
  )
import Prodbox.CLI.Docs (renderCommandHelp)
import Prodbox.CLI.Json (renderCommandJson)
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry, findCommandSpec)
import Prodbox.CLI.Tree (renderCommandTree)
import Prodbox.CLI.Vault
  ( brokerBaselineSelected
  , brokerInitializeSelected
  , brokerUnsealSelected
  , runVaultMaintenanceSelected
  , runVaultPkiSelected
  )
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
  , bootstrapRuntimeSocket
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.BootstrapSetup (runSelectedBootstrapSetup, runSelectedFreshTestBootstrapSetup)
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeKindName
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Config.KindPlan (kindPlanHostPorts, kindPlanNodeImage, renderKindConfig)
import Prodbox.Config.SchemaDhall (materializeSchemaFilesIfStale)
import Prodbox.Control.ArtifactImport
  ( ArtifactDiscardResult (..)
  , ArtifactImportResult (..)
  , BootstrapArtifact (..)
  , discardBootstrapArtifactStaging
  , importBootstrapArtifact
  )
import Prodbox.Control.AuthorityDeploy (deployAuthority, deployAuthorityWithAdmission)
import Prodbox.Control.AuthorityJournalClient
  ( AdmissionSource (..)
  , AuthorityRemovalObservation (..)
  , admitKindTeardown
  , currentAdmission
  , currentAuthorityInitialization
  , observeAuthorityRemoval
  )
import Prodbox.Control.Backup (backupServices, renderBackupOutcome, restoreServices)
import Prodbox.Control.BrokerClientCommand (brokerVaultStatus)
import Prodbox.Control.Delete (DeleteStep (..), deleteNewTestIdentity, recoverProbeForDelete)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoFailure
  , DockerConnectedInfoResult (..)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..), withConnectedDockerPeer)
import Prodbox.Control.HostPorts (dockerNameRefusal, hostPortRefusal)
import Prodbox.Control.KindAbsenceStatus
  ( observeAbsenceInventoryStatus
  , observeAbsenceJournalStatus
  , renderAbsenceInventoryStatus
  , renderAbsenceJournalStatus
  )
import Prodbox.Control.KindController
  ( kindHostCapacityRefusal
  , runKindControllerEntry
  )
import Prodbox.Control.KindControllerInput (isKindProbeSuccessorArguments)
import Prodbox.Control.KindControllerReceipt
  ( FamilyLaunchObservation (..)
  , observeControllerFreshProvider
  , observeControllerFreshSender
  , observeControllerManagerRead
  , observeControllerSubmissionStatus
  , observeFamilyLaunch
  , observeFamilyPrePublicationCancellation
  , observeFamilyPublicationAttempt
  , observeFamilyResult
  , observeFamilyResultStatus
  )
import Prodbox.Control.KindControllerRequest (kindRequestWindow)
import Prodbox.Control.KindDockerClient (runKindDockerClient)
import Prodbox.Control.KindFamilyDispatcher
  ( dispatchKindFamilyController
  , dispatchKindProbeFamilyController
  , isKindProbeRecoveryArguments
  , kindFamilyDispatchCompleted
  , kindProbeFamilyDispatchCompleted
  , kindProbeFamilyDispatchFailureCode
  )
import Prodbox.Control.KindFamilyLaunch
  ( KindFamilyLaunchClosing (..)
  , KindFamilyLaunchOutcome (..)
  , launchFreshKindFamily
  , launchKindFamily
  , prepareFreshKindFamilyRequest
  )
import Prodbox.Control.KindFamilyRecovery
  ( KindFamilyCompletionStep (..)
  , KindFamilyCompletionWait (..)
  , KindFamilyPrePublicationOutcome (..)
  , KindFamilyPublicationState (..)
  , KindFamilyRetirementOutcome (..)
  , awaitKindFamilyCompletionWith
  , classifyKindFamilyPublication
  , kindFamilyReadinessComplete
  , observeKindFamilyCompletion
  , observeKindFamilySubmissionStatus
  , recoverNeverSentKindFamilyInputs
  , recoverNeverSentKindProbeInputs
  , recoverNeverSentKindProbeVerifierInputs
  , withCancelledPrePublicationKindFamily
  , withCancelledUnlaunchedOwnerFamily
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches, KindIntentMissing)
  , observeKindFamilyIntent
  , observeKindOwnerFamilyIntent
  , observeKindTeardownAdmission
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshot)
import Prodbox.Control.KindLease
  ( KindLeaseOutcome (KindLeaseCompleted)
  , KindOperationOutcome (..)
  , withKindLease
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindRuntimeConfig (renderKindConfigForArchive)
import Prodbox.Control.KubernetesReadiness
  ( observeKubernetesReadiness
  , renderKubernetesReadiness
  )
import Prodbox.Control.ManagementRestore
  ( CompletedRestoreObservation (..)
  , ManagementRestoreOperation (..)
  , managementRestoreIdle
  , observeCompletedManagementRestore
  , observeManagementRestoreOperation
  )
import Prodbox.Control.NetworkEnforcement
  ( ProbeJournalObservation (ProbeJournalVerifierPending)
  , observeProbeJournal
  , observeReconcileProbeRecords
  )
import Prodbox.Control.NodeArchive
  ( ArchiveReferenceFootprint (..)
  , InspectedArchiveResult (..)
  , VerifiedNodeArchive (..)
  , withInspectedNodeArchive
  )
import Prodbox.Control.NodeArchiveStage (StagedNodeResult (..))
import Prodbox.Control.NodeImageIntent
  ( NodeImageAttemptObservation (..)
  , NodeImageResultObservation (..)
  )
import Prodbox.Control.NodeImageOperation
  ( NodeImageConnectedObservation (..)
  , NodeImageConnectionResult (..)
  , NodeImageIndependentObservation (..)
  , NodeImageRecoveryPoint (..)
  , observeRecoveredConnectedNodeImage
  )
import Prodbox.Control.OperatorInput (readSecretLine)
import Prodbox.Control.ProtectedUnlock (protectedUnlock, renderProtectedOutcome)
import Prodbox.Control.Reconcile (ReconcileOutcome (..), prepareNewOwnerFamilyOperation)
import Prodbox.Control.ServiceSupport (ServiceStep (..))
import Prodbox.Control.Services (observeServices, reconcileServices, renderServicesOutcome)
import Prodbox.Control.Status
  ( ControlObservation (controlRuntime)
  , ImageArchiveComparison (..)
  , ImageIdObservation (..)
  , RuntimeObservation (RuntimeUnobservable)
  , compareImageArchive
  , observeControl
  , observeImage
  , observeImageId
  , renderControlObservation
  , renderControlStatusError
  )
import Prodbox.Control.TestRunCleanup (resumeTestRunCleanup, retireSettledTestRun)
import Prodbox.Control.Unlock (renderUnlockOutcome, unlockVault)
import Prodbox.ControlPlane.AdmissionJournalMirror (JournalInitialization (..))
import Prodbox.Error (fatalError)
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , renderVerdict
  )
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot, resolveTier0ConfigPath)
import Prodbox.Settings (SelectedSettingsValidation (..), validateSelectedSettingsAtPath)
import Prodbox.Subprocess.SystemdBus (BusError, SystemDockerObservation (..), observeSystemDocker)
import Prodbox.Subprocess.SystemdIdentity (hostExecutionOuterEnd)
import Prodbox.TestRunner
  ( namedMutationSuite
  , renderNamedLocalTestList
  , runMutationCampaignCleanup
  , runSelectedMutationCatalog
  , runSelectedMutationStatus
  , runSelectedPhaseScenario
  , runSelectedPhaseThreeScenario
  , runSelectedPhaseTwoBrokerScenario
  , runSelectedPhaseTwoScenario
  , validatePhaseOneOptions
  )
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.FilePath ((</>))

data Env = Env
  { envRepoRoot :: FilePath
  }
  deriving (Eq, Show)

newtype App a = App {unApp :: ReaderT Env IO a}

instance Functor App where
  fmap f (App action) = App (fmap f action)

instance Applicative App where
  pure = App . pure
  App function <*> App value = App (function <*> value)

instance Monad App where
  App action >>= next = App (action >>= unApp . next)

runApp :: Env -> App a -> IO a
runApp env (App action) = runReaderT action env

askEnv :: App Env
askEnv = App ask

liftAppIO :: IO a -> App a
liftAppIO = App . liftIO

main :: IO ()
main = do
  -- Force UTF-8 for stdin/stdout/stderr and file handles so the Dhall
  -- decoder, log output, and any file reads work in container Pods that
  -- ship with the C/POSIX default locale (no LANG set). Without this,
  -- `Dhall.inputFile` fails on UTF-8 byte sequences such as `§` (0xC2 0xA7)
  -- that appear in chart-rendered config comments per
  -- documents/engineering/config_doctrine.md at 583443f, section 6.
  setLocaleEncoding utf8
  argv <- getArgs
  program <- getProgName
  if program == "docker"
    then runKindDockerClient argv >>= exitWith
    else runOperator argv
 where
  runOperator argv = case validateCommandArgv argv of
    Left err -> failWith err
    Right () -> do
      options <- customExecParser parserPrefs parserInfo
      case optConfig options of
        Nothing -> runCommandRequest (optRequest options)
        Just selected -> runSelectedCommand selected (optRequest options)
  parserPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

-- A selected path must never be silently ignored by a legacy handler. Only
-- the read-only authored-source validation lane currently consumes it.
runSelectedCommand :: FilePath -> CommandRequest -> IO ()
runSelectedCommand selected request = case request of
  RunControlStatus -> runControlStatus selected
  RunControlLifecycleStatus -> runControlLifecycleStatus selected
  RunLifecycleStatus -> runLifecycleStatus selected
  RunPlanDelete -> runPlanDelete selected
  RunPlanReconcile -> runPlanReconcile selected
  RunOperations action -> runOperations selected action
  RunScopedVaultPki action -> runScopedVaultPki selected action
  RunScopedVaultMaintenance action -> runScopedVaultMaintenance selected action
  RunOrdinaryDelete -> runOrdinaryDelete selected
  RunControlAuthorityDeploy -> runControlAuthorityDeploy selected
  RunControlPlan -> runControlPlan selected
  RunControlReconcile -> runControlReconcile selected
  RunControlServices -> runControlServices selected
  RunControlUnlock -> runControlUnlock selected
  RunControlProtectedUnlock -> runControlProtectedUnlock selected
  RunControlVaultStatus -> runControlVaultStatus selected
  RunControlBrokerInit -> runControlBrokerSecret BrokerInitAction selected
  RunControlBrokerUnseal -> runControlBrokerSecret BrokerUnsealAction selected
  RunControlBrokerBaseline -> runControlBrokerSecret BrokerBaselineAction selected
  RunControlBackup -> runControlBackup selected
  RunControlRestore name -> runControlRestore selected name
  RunControlDelete -> runControlDelete selected
  RunControlArtifactImport role source -> runControlArtifactImport selected role source
  RunControlArtifactDiscard role -> runControlArtifactDiscard selected role
  RunControlInspectNodeArchive -> runControlInspectNodeArchive selected
  RunControlInspectImageAttempt operation -> runControlInspectImageAttempt selected operation
  RunTestCleanup runId -> runSelectedTestRunCleanup selected runId
  RunNative (NativeConfig (ConfigSetup options)) -> runSelectedBootstrapSetup selected options >>= exitWith
  RunNative (NativeConfig (ConfigSetupFreshTest options)) -> runSelectedFreshTestBootstrapSetup selected options >>= exitWith
  RunNative (NativeTest command@(TestCommand (TestRun "phase-01") _ _ _)) -> runSelectedPhaseOneCommand selected command
  RunNative (NativeTest (TestCommand (TestRun "phase-02") _ _ _)) -> runSelectedPhaseTwoScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-02-broker") _ _ _)) -> runSelectedPhaseTwoBrokerScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-03") _ _ _)) -> runSelectedPhaseThreeScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRunAtRuntimeSocket _ _) _ _ _)) ->
    failWith "The runtime socket option requires fresh setup without a selected configuration."
  RunNative (NativeTest command@(TestCommand (TestRun suite) _ _ _))
    | namedMutationSuite suite -> runSelectedMutationCatalog command >>= exitWith
  RunNative (NativeConfig ConfigValidate) -> do
    result <- validateSelectedSettingsAtPath selected
    either
      failWith
      ( \validated -> writeOutput $ case validated of
          SelectedBootstrapOnly ->
            "Bootstrap configuration validated; application settings, deployment root and runtime state were not checked.\n"
          SelectedLegacySettings ->
            "Authored parameters and context validated; deployment root and runtime state were not checked.\n"
      )
      result
  _ -> failWith "The selected configuration is not supported by this command yet."

runSelectedPhaseOneCommand :: FilePath -> TestCommand -> IO ()
runSelectedPhaseOneCommand selected command = runPhaseOneCommand command (runSelectedPhaseScenario selected)

runPhaseOneCommand :: TestCommand -> IO ExitCode -> IO ()
runPhaseOneCommand command action = either failWith (const (action >>= exitWith)) (validatePhaseOneOptions command)

runCommandRequest :: CommandRequest -> IO ()
runCommandRequest request =
  case request of
    RunTestList -> writeOutput renderNamedLocalTestList
    RunTestStatus runId -> runSelectedMutationStatus runId >>= exitWith
    RunTestCleanup runId -> runTestRunCleanup runId
    RunControlStatus -> resolveTier0ConfigPath "." >>= runControlStatus
    RunControlLifecycleStatus -> resolveTier0ConfigPath "." >>= runControlLifecycleStatus
    RunLifecycleStatus -> resolveTier0ConfigPath "." >>= runLifecycleStatus
    RunPlanDelete -> resolveTier0ConfigPath "." >>= runPlanDelete
    RunPlanReconcile -> resolveTier0ConfigPath "." >>= runPlanReconcile
    RunOperations action -> resolveTier0ConfigPath "." >>= (\selected -> runOperations selected action)
    RunScopedVaultPki action -> resolveTier0ConfigPath "." >>= (\selected -> runScopedVaultPki selected action)
    RunScopedVaultMaintenance action -> resolveTier0ConfigPath "." >>= (\selected -> runScopedVaultMaintenance selected action)
    RunOrdinaryDelete -> resolveTier0ConfigPath "." >>= runOrdinaryDelete
    RunControlAuthorityDeploy -> resolveTier0ConfigPath "." >>= runControlAuthorityDeploy
    RunControlPlan -> resolveTier0ConfigPath "." >>= runControlPlan
    RunControlReconcile -> resolveTier0ConfigPath "." >>= runControlReconcile
    RunControlServices -> resolveTier0ConfigPath "." >>= runControlServices
    RunControlUnlock -> resolveTier0ConfigPath "." >>= runControlUnlock
    RunControlProtectedUnlock -> resolveTier0ConfigPath "." >>= runControlProtectedUnlock
    RunControlVaultStatus -> resolveTier0ConfigPath "." >>= runControlVaultStatus
    RunControlBrokerInit -> resolveTier0ConfigPath "." >>= runControlBrokerSecret BrokerInitAction
    RunControlBrokerUnseal -> resolveTier0ConfigPath "." >>= runControlBrokerSecret BrokerUnsealAction
    RunControlBrokerBaseline -> resolveTier0ConfigPath "." >>= runControlBrokerSecret BrokerBaselineAction
    RunControlBackup -> resolveTier0ConfigPath "." >>= runControlBackup
    RunControlRestore name -> resolveTier0ConfigPath "." >>= \selected -> runControlRestore selected name
    RunControlDelete -> resolveTier0ConfigPath "." >>= runControlDelete
    RunControlArtifactImport role source -> resolveTier0ConfigPath "." >>= \selected -> runControlArtifactImport selected role source
    RunControlArtifactDiscard role -> resolveTier0ConfigPath "." >>= \selected -> runControlArtifactDiscard selected role
    RunControlInspectNodeArchive -> resolveTier0ConfigPath "." >>= runControlInspectNodeArchive
    RunControlInspectImageAttempt operation -> resolveTier0ConfigPath "." >>= \selected -> runControlInspectImageAttempt selected operation
    RunNative (NativeTest command@(TestCommand (TestRun suite) _ _ _))
      | namedMutationSuite suite -> runSelectedMutationCatalog command >>= exitWith
    RunInternalKindController arguments -> runKindControllerEntry arguments >>= exitWith
    RunInternalKindFamilyController arguments ->
      if isKindProbeRecoveryArguments arguments
        then do
          outcome <- dispatchKindProbeFamilyController arguments
          if kindProbeFamilyDispatchCompleted outcome
            then exitSuccess
            else do
              successor <- isKindProbeSuccessorArguments arguments
              if successor
                then do
                  writeError
                    (fatalError (Text.pack "Kind probe recovery incomplete; inspect the retained operation."))
                  exitWith (ExitFailure (kindProbeFamilyDispatchFailureCode outcome))
                else failWith "Kind probe recovery incomplete; inspect the retained operation."
        else do
          outcome <- dispatchKindFamilyController arguments
          if kindFamilyDispatchCompleted outcome
            then exitSuccess
            else failWith "Kind family controller incomplete; inspect the retained operation."
    RunNative command@(NativeRpcBirthController _) -> dispatch "." command
    RunNative command -> do
      repoRootResult <- findRepoRoot
      case repoRootResult of
        Right repoRoot -> do
          -- Sprint 7.17/7.18: ALL Dhall is generated or locally authored and
          -- NONE is version-controlled — including the two `*-types.dhall`
          -- schemas. Materialize them from the Haskell source of truth before
          -- dispatch so any command that decodes a config importing
          -- `./prodbox-config-types.dhall` (e.g. `cluster reconcile` via
          -- `validateAndLoadBootstrapSettings`) resolves the schema even on a
          -- fresh checkout that never committed it. Idempotent + cheap (writes
          -- only when absent/stale).
          materializeSchemaFilesIfStale repoRoot
          dispatch repoRoot command
        Left err ->
          if canRunWithoutRepoRoot command
            then dispatch "." command
            else failWith err
    ShowCommands listingFormat ->
      case listingFormat of
        CommandsPlain -> writeOutput (renderCommandsPlain commandRegistry)
        CommandsTree -> writeOutput (renderCommandTree commandRegistry)
        CommandsJson -> writeOutput (renderCommandJson commandRegistry)
    ShowHelp commandPath ->
      case findCommandSpec commandPath of
        Nothing -> failWith ("Unknown help path: " ++ unwords commandPath)
        Just spec -> writeOutput (renderCommandHelp commandPath spec)
 where
  dispatch repoRoot command = do
    exitCode <- runNativeCommand repoRoot command
    exitWith exitCode

runControlAuthorityDeploy :: FilePath -> IO ()
runControlAuthorityDeploy selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control authority-deploy currently supports only test identities."
      | otherwise -> do
          steps <- deployAuthority projection
          let rendered =
                concatMap
                  ( \step ->
                      "  "
                        ++ serviceStepName step
                        ++ ": "
                        ++ (if serviceStepOk step then "ok" else "NOT completed")
                        ++ " - "
                        ++ serviceStepDetail step
                        ++ "\n"
                  )
                  steps
          if all serviceStepOk steps
            then writeOutput ("The Authority runtime is deployed.\n" ++ rendered)
            else
              failWith ("The Authority deployment is incomplete; nothing was repaired by hand.\n" ++ rendered)

withLifecycleScope :: FilePath -> (BootstrapProjection -> IO ()) -> IO ()
withLifecycleScope selected action = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> action projection

data DeletionAssessment
  = DeletionSatisfied
  | DeletionNeedsAdapter
  | DeletionNeedsSettlement !AdmissionVerdict
  | DeletionRestorePending !String
  | DeletionRestoreUnconfirmed

assessDeletion :: AdmissionVerdict -> DeletionAssessment
assessDeletion verdict = case verdict of
  NeverAdmitted -> DeletionSatisfied
  AdmittedSettled -> DeletionNeedsAdapter
  AdmittedPending _ -> DeletionNeedsSettlement verdict
  RecoveryRequired _ -> DeletionNeedsSettlement verdict

observeDeletionAssessment :: BootstrapProjection -> AdmissionVerdict -> IO DeletionAssessment
observeDeletionAssessment projection verdict = do
  storage <- observeManagementRestoreOperation projection
  pure $ case storage of
    NoManagementRestoreOperation -> assessDeletion verdict
    PendingManagementRestore operation _ -> DeletionRestorePending operation
    UnconfirmedManagementRestoreOperation -> DeletionRestoreUnconfirmed

renderAdmissionRead :: AdmissionVerdict -> AdmissionSource -> String
renderAdmissionRead verdict source =
  renderVerdict verdict
    ++ ( case source of
           FromAuthority observedAt
             | observedAt == Text.pack "not read" -> " [source: the Authority's journal, fresh read unavailable]"
             | otherwise -> " [source: the Authority's journal, read at " ++ Text.unpack observedAt ++ "]"
           FromLocalControlJournal -> " [source: local control journal; no Authority is deployed]"
       )
    ++ "\n"

renderDeletionPlan :: BootstrapProjection -> DeletionAssessment -> String
renderDeletionPlan projection assessment =
  "Deployment: "
    ++ scopeKindName (bootstrapScope projection)
    ++ "\n"
    ++ "Deletion scope: all AWS resources owned by this deployment.\n"
    ++ case assessment of
      DeletionSatisfied -> "Deletion decision: satisfied, with no AWS capability ever admitted.\n"
      DeletionNeedsAdapter -> "Deletion decision: requires the supported AWS deletion capability.\n"
      DeletionNeedsSettlement (AdmittedPending _) -> "Deletion decision: settle the pending Authority operation first.\n"
      DeletionNeedsSettlement _ -> "Deletion decision: recover the Authority journal before proceeding.\n"
      DeletionRestorePending operation -> "Deletion decision: settle management restore " ++ operation ++ " first.\n"
      DeletionRestoreUnconfirmed -> "Deletion decision: the retained management restore state requires recovery.\n"

runOrdinaryDelete :: FilePath -> IO ()
runOrdinaryDelete selected = withLifecycleScope selected $ \projection -> do
  observed <- withKindLease projection $ \stable -> do
    (verdict, _) <- currentAdmission projection
    assessment <- observeDeletionAssessment projection verdict
    held <- stable
    pure (if held then Just assessment else Nothing)
  case observed of
    Right (KindLeaseCompleted (Just DeletionSatisfied)) ->
      writeOutput
        "Nothing to delete: no cloud capability was ever admitted for this deployment. The kind environment, local services, trust and journal are retained.\n"
    Right (KindLeaseCompleted (Just DeletionNeedsAdapter)) ->
      failWith
        "Refused: this deployment admitted a capability whose deletion is not delivered by this binary yet; nothing was changed.\n"
    Right (KindLeaseCompleted (Just (DeletionNeedsSettlement unresolved))) ->
      failWith
        ( "Refused: deletion needs a settled, known operation history. "
            ++ renderVerdict unresolved
            ++ "\nNothing was changed; resolve the journal through recovery first.\n"
        )
    Right (KindLeaseCompleted (Just (DeletionRestorePending operation))) ->
      failWith ("Refused: settle the retained management restore " ++ operation ++ " before deletion.")
    Right (KindLeaseCompleted (Just DeletionRestoreUnconfirmed)) ->
      failWith "Refused: the retained management restore state requires recovery."
    _ -> failWith "Refused: the selected control lease or operation history could not be confirmed."

runPlanDelete :: FilePath -> IO ()
runPlanDelete selected = withLifecycleScope selected $ \projection -> do
  (verdict, source) <- currentAdmission projection
  assessment <- observeDeletionAssessment projection verdict
  writeOutput
    (renderAdmissionRead verdict source ++ renderDeletionPlan projection assessment)
  failOnUnobservableAdmission verdict

runLifecycleStatus :: FilePath -> IO ()
runLifecycleStatus selected = withLifecycleScope selected $ \projection -> do
  (verdict, source) <- currentAdmission projection
  assessment <- observeDeletionAssessment projection verdict
  writeOutput
    (renderAdmissionRead verdict source ++ renderDeletionPlan projection assessment)
  control <- observeControl projection
  writeOutput (either ((++ "\n") . renderControlStatusError) renderControlObservation control)
  readiness <- observeKubernetesReadiness projection
  writeOutput (renderKubernetesReadiness readiness)
  failOnUnobservableAdmission verdict

runControlLifecycleStatus :: FilePath -> IO ()
runControlLifecycleStatus selected = withLifecycleScope selected $ \projection -> do
  (verdict, source) <- currentAdmission projection
  writeOutput (renderAdmissionRead verdict source)
  failOnUnobservableAdmission verdict

failOnUnobservableAdmission :: AdmissionVerdict -> IO ()
failOnUnobservableAdmission verdict = case verdict of
  RecoveryRequired _ -> exitWith (ExitFailure 1)
  _ -> pure ()

runControlStatus :: FilePath -> IO ()
runControlStatus selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      observed <- observeControl projection
      manager <-
        if bootstrapRuntimeSocket projection == "/run/docker.sock"
          then do
            now <- getMonotonicTimeNSec
            Just
              <$> withConnectedDockerPeer 4000000 "/run/docker.sock" (observeManagerOnPeer (now + 2000000000))
          else pure Nothing
      probeRecords <- observeReconcileProbeRecords projection
      submissionStatus <- observeControllerSubmissionStatus projection
      familyStatus <- observeFamilyResultStatus projection
      familySubmissionStatus <- observeKindFamilySubmissionStatus projection
      absenceStatus <- renderAbsenceJournalStatus <$> observeAbsenceJournalStatus projection
      absenceInventoryStatus <- renderAbsenceInventoryStatus <$> observeAbsenceInventoryStatus projection
      freshProvider <- observeControllerFreshProvider projection
      freshSender <- observeControllerFreshSender projection
      managerRead <- observeControllerManagerRead projection
      let managerReadStatus =
            "Kind controller manager read: "
              ++ show managerRead
              ++ "; job processing and worker settlement not established.\n"
          senderStatus =
            "Kind controller sender observation: "
              ++ show freshSender
              ++ "; job processing and worker settlement not observed.\n"
          freshProviderStatus =
            "Kind controller fresh provider observation: "
              ++ show freshProvider
              ++ "; worker settlement not observed.\n"
      either
        ( \failure ->
            failWith
              ( "Cannot observe local control: "
                  ++ renderControlStatusError failure
                  ++ "\n"
                  ++ submissionStatus
                  ++ familyStatus
                  ++ familySubmissionStatus
                  ++ absenceStatus
                  ++ absenceInventoryStatus
                  ++ freshProviderStatus
                  ++ senderStatus
                  ++ managerReadStatus
                  ++ probeRecords
              )
        )
        ( \value -> do
            writeOutput
              ( "Docker socket: "
                  ++ bootstrapRuntimeSocket projection
                  ++ "\n"
                  ++ renderControlObservation value
                  ++ renderSystemDockerManager manager
              )
            readiness <- observeKubernetesReadiness projection
            writeOutput (renderKubernetesReadiness readiness)
            writeOutput submissionStatus
            writeOutput familyStatus
            writeOutput familySubmissionStatus
            writeOutput absenceStatus
            writeOutput absenceInventoryStatus
            writeOutput freshProviderStatus
            writeOutput senderStatus
            writeOutput managerReadStatus
            writeOutput probeRecords
            observeServices (scopeRoot (bootstrapScope projection) </> "control" </> "kubeconfig")
              >>= writeOutput
            case controlRuntime value of
              RuntimeUnobservable failure -> failWith ("Cannot observe local control: " ++ renderControlStatusError failure)
              _ -> pure ()
        )
        observed

observeManagerOnPeer
  :: Word64
  -> Socket.Socket
  -> DockerPeer
  -> IO Bool
  -> IO (DockerPeer, Either BusError SystemDockerObservation)
observeManagerOnPeer deadline _ peer _ = do
  snapshot <- observeSystemDocker deadline
  pure (peer, snapshot)

renderSystemDockerManager
  :: Maybe (DockerPeerResult (DockerPeer, Either BusError SystemDockerObservation)) -> String
renderSystemDockerManager manager = case manager of
  Nothing -> "System Docker manager: not observed for selected socket\n"
  Just (DockerPeerCompleted (peer, Right snapshot)) -> renderSnapshot peer snapshot
  Just _ -> "System Docker manager: unobservable or changed; daemon authentication unverified\n"

renderSnapshot :: DockerPeer -> SystemDockerObservation -> String
renderSnapshot (DockerPeer peerPid peerUid _ _) snapshot =
  "System Docker manager: PID "
    ++ show (systemDockerManagerPid snapshot)
    ++ ", held peer PID "
    ++ show peerPid
    ++ ", held peer UID "
    ++ show peerUid
    ++ ", peer PID matches manager PID "
    ++ show (peerPid == toInteger (systemDockerManagerPid snapshot))
    ++ ", socket "
    ++ systemDockerSocketState snapshot
    ++ ", triggers "
    ++ show (systemDockerSocketTriggers snapshot)
    ++ ", listeners "
    ++ show (systemDockerSocketListeners snapshot)
    ++ ", accept="
    ++ show (systemDockerSocketAccept snapshot)
    ++ ", service "
    ++ systemDockerServiceState snapshot
    ++ ", PID "
    ++ show (systemDockerServicePid snapshot)
    ++ "; daemon authentication unverified\n"

-- This is the same structured projection recorded by the kind intent; it
-- does not inspect the selected root, artifacts, sockets or existing nodes.
runControlPlan :: FilePath -> IO ()
runControlPlan selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      let rendered =
            Text.unpack
              (TextEncoding.decodeUtf8 (LazyByteString.toStrict (renderKindConfig (bootstrapKindPlan projection))))
      writeOutput $
        "Candidate kind configuration (JSON):\n"
          ++ rendered
          ++ "\nRoot ownership, artifacts, ports, runtime, CNI and cluster state were not checked; no resources were changed.\n"

-- Early removal for a new test identity. Exit zero only when every step
-- completed; the independent inventory is `control status`.
runTestRunCleanup :: String -> IO ()
runTestRunCleanup runId = do
  found <- findRepoRoot
  case found of
    Left reason -> failWith reason
    Right project -> runInProject project
 where
  runInProject project = do
    recovered <- resumeTestRunCleanup project runId
    case recovered of
      Left reason -> failWith ("Test cleanup refused: " ++ reason)
      Right True -> writeOutputLine "The test root is absent and its cleanup receipts are retained."
      Right False
        | all (\digit -> digit >= '0' && digit <= '9') runId ->
            runMutationCampaignCleanup runId >>= exitWith
        | otherwise ->
            runSelectedTestRunCleanup
              (project </> ".test-data" </> runId </> "config" </> "prodbox.dhall")
              runId

runSelectedTestRunCleanup :: FilePath -> String -> IO ()
runSelectedTestRunCleanup selected runId = withLifecycleScope selected $ \projection -> do
  cleanup <- retireSettledTestRun projection runId
  case cleanup of
    Right True -> writeOutputLine "The test root is absent and its cleanup receipts are retained."
    Right False -> failWith "Test cleanup did not find a terminal receipt."
    Left reason -> failWith ("Test cleanup refused: " ++ reason)

runControlDelete :: FilePath -> IO ()
runControlDelete selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      admitted <- admitKindTeardown projection
      case admitted of
        Right () -> deleteAdmitted projection
        Left refusal ->
          failWith
            ( "Refused: removal needs a settled, known operation history. "
                ++ refusal
                ++ "\nNothing was removed; resolve the journal through recovery first.\n"
            )
 where
  deleteAdmitted projection = do
    initial <- deleteNewTestIdentity projection
    recovery <-
      if any
        ( \step ->
            deleteStepName step `elem` ["probe cleanup", "probe family settlement", "probe family inputs"]
              && not (deleteStepCompleted step)
        )
        initial
        then recoverProbeForDelete projection
        else pure Nothing
    steps <- case recovery of
      Nothing -> pure initial
      Just _ -> deleteNewTestIdentity projection
    let render step =
          "  "
            ++ deleteStepName step
            ++ ": "
            ++ (if deleteStepCompleted step then "completed" else "NOT completed")
            ++ " - "
            ++ take 300 (deleteStepDetail step)
            ++ "\n"
        report = concatMap render steps
    if all deleteStepCompleted steps
      then
        writeOutput
          ( "Recorded kind resources were removed or verified never created.\n"
              ++ report
              ++ "Host data, records, artifacts, the loaded node image and the retained root remain.\n"
          )
      else
        failWith
          ( "Removal is incomplete; records are retained for recovery.\n"
              ++ report
              ++ maybe
                ""
                (\detail -> "Recovery: " ++ detail ++ "\nInitial disposition:\n" ++ concatMap render initial)
                recovery
          )

-- | Capacity first, then declared host ports; each refuses before any effect.
admitReconcile :: BootstrapProjection -> IO (Maybe String)
admitReconcile projection = do
  capacity <- kindHostCapacityRefusal (scopeRoot (bootstrapScope projection))
  case capacity of
    Just reason -> pure (Just ("host capacity cannot fund the declared envelope: " ++ reason))
    Nothing -> do
      names <-
        dockerNameRefusal (bootstrapRuntimeSocket projection) (scopeKindName (bootstrapScope projection))
      case names of
        Just reason -> pure (Just reason)
        Nothing -> hostPortRefusal (kindPlanHostPorts (bootstrapKindPlan projection))

data BrokerAction = BrokerInitAction | BrokerUnsealAction | BrokerBaselineAction

runControlBrokerSecret :: BrokerAction -> FilePath -> IO ()
runControlBrokerSecret action selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control broker commands currently support only test identities."
      | otherwise -> do
          supplied <- readSecretLine "Vault operator password: "
          case supplied of
            Nothing ->
              failWith
                "Needs input: provide the Vault operator password at the prompt or on standard input. Nothing was changed."
            Just password ->
              withSelectedManagementMutation projection (runSelected password)
 where
  runSelected password environment = case action of
    BrokerInitAction -> brokerInitializeSelected "." environment password
    BrokerUnsealAction -> brokerUnsealSelected "." environment password
    BrokerBaselineAction -> brokerBaselineSelected "." environment password

withSelectedManagementMutation
  :: BootstrapProjection -> ([(String, String)] -> IO ExitCode) -> IO ()
withSelectedManagementMutation projection action = do
  leased <- withKindLease projection $ \stable -> do
    teardown <- observeKindTeardownAdmission projection
    idle <- managementRestoreIdle projection
    held <- stable
    if held && teardown == KindIntentMissing && idle
      then do
        snapshot <- withKindKubeconfigSnapshot projection $ \credential ->
          action [("KUBECONFIG", credential), ("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
        pure (either (const (Left "The selected control kubeconfig was refused.")) Right snapshot)
      else pure (Left "The selected management storage or control removal requires settlement.")
  case leased of
    Right (KindLeaseCompleted (Right code)) -> exitWith code
    Right (KindLeaseCompleted (Left reason)) -> failWith reason
    _ -> failWith "The selected scope lease could not be held through the management operation."

runControlVaultStatus :: FilePath -> IO ()
runControlVaultStatus selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control vault-status currently supports only test identities."
      | otherwise -> do
          result <- brokerVaultStatus (scopeRoot (bootstrapScope projection) </> "control" </> "kubeconfig")
          either
            (\detail -> failWith ("The Broker did not answer: " ++ detail))
            (\text -> writeOutput ("Vault status through the Bootstrap Broker: " ++ text ++ "\n"))
            result

runScopedVaultPki :: FilePath -> VaultPkiCommand -> IO ()
runScopedVaultPki selected action = withLifecycleScope selected runSelected
 where
  runSelected projection = case action of
    IssueVaultTestCertificate
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "The Vault test certificate is available only for a test identity."
      | otherwise -> withSelectedManagementMutation projection runPki
    ObserveVaultPki -> withSelectedVaultRead projection runPki
  runPki environment = runVaultPkiSelected "." environment action

runScopedVaultMaintenance :: FilePath -> VaultMaintenanceCommand -> IO ()
runScopedVaultMaintenance selected action = withLifecycleScope selected $ \projection -> do
  let runSelected environment = runVaultMaintenanceSelected "." environment action
  case action of
    ObserveScopedVault -> withSelectedVaultRead projection runSelected
    _ -> withSelectedManagementMutation projection runSelected

withSelectedVaultRead :: BootstrapProjection -> ([(String, String)] -> IO ExitCode) -> IO ()
withSelectedVaultRead projection action = do
  outcome <- withKindKubeconfigSnapshot projection $ \snapshot ->
    action [("KUBECONFIG", snapshot), ("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
  either (const (failWith "The selected control kubeconfig was refused.")) exitWith outcome

runControlBackup :: FilePath -> IO ()
runControlBackup selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control backup currently supports only test identities."
      | otherwise -> do
          steps <- backupServices projection
          let (ok, rendered) = renderBackupOutcome steps
          if ok
            then writeOutput ("Backup complete.\n" ++ rendered)
            else failWith ("Backup incomplete.\n" ++ rendered)

runControlRestore :: FilePath -> String -> IO ()
runControlRestore selected name = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control restore currently supports only test identities."
      | otherwise -> do
          restoreSelectedOperation projection name

restoreSelectedOperation :: BootstrapProjection -> String -> IO ()
restoreSelectedOperation projection name = do
  steps <- restoreServices projection name
  let (ok, rendered) = renderBackupOutcome steps
  if ok
    then writeOutput ("Restore complete. Run `control unlock` to unseal Vault.\n" ++ rendered)
    else failWith ("Restore incomplete.\n" ++ rendered)

runControlProtectedUnlock :: FilePath -> IO ()
runControlProtectedUnlock selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control protected-unlock currently supports only test identities."
      | otherwise -> do
          outcome <- protectedUnlock projection
          let (ok, rendered) = renderProtectedOutcome outcome
          if ok then writeOutput rendered else failWith rendered

runControlUnlock :: FilePath -> IO ()
runControlUnlock selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      outcome <- unlockVault projection
      let (ok, rendered) = renderUnlockOutcome outcome
      if ok
        then writeOutput ("Vault is unsealed and a secret round trip succeeded.\n" ++ rendered)
        else failWith ("Unlock is incomplete; nothing was repaired by hand.\n" ++ rendered)

runControlServices :: FilePath -> IO ()
runControlServices selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control services currently supports only test identities."
      | otherwise -> do
          outcome <- reconcileServices projection
          let (ok, rendered) = renderServicesOutcome outcome
          if ok
            then
              writeOutput
                ("MinIO and Vault are deployed and read back directly; Vault is uninitialized.\n" ++ rendered)
            else failWith ("Services are incomplete; nothing was repaired by hand.\n" ++ rendered)

data ControlReconcileDecision
  = ControlReconcileUndelivered
  | ControlReconcilePrepare
  | ControlReconcileRestorePending
  | ControlReconcileAuthorityRemovalUnconfirmed
  | ControlReconcileResume !String
  | ControlReconcileRecover !KindIntentObservation

assessControlReconcile :: BootstrapProjection -> IO ControlReconcileDecision
assessControlReconcile projection
  | scopeEnvironment (bootstrapScope projection) /= Test = pure ControlReconcileUndelivered
  | otherwise = do
      idle <- managementRestoreIdle projection
      if idle then observeControlOperation else pure ControlReconcileRestorePending
 where
  observeControlOperation = do
    family <- observeKindFamilyIntent projection
    case family of
      KindIntentMatches operation -> do
        teardown <- observeKindTeardownAdmission projection
        if teardown == KindIntentMatches operation
          then pure ControlReconcilePrepare
          else do
            removal <- observeAuthorityRemoval projection
            pure $ case removal of
              NoAuthorityRemoval -> ControlReconcileResume operation
              BoundAuthorityRemoval original | original == operation -> ControlReconcilePrepare
              _ -> ControlReconcileAuthorityRemovalUnconfirmed
      KindIntentMissing -> pure ControlReconcilePrepare
      unconfirmed -> pure (ControlReconcileRecover unconfirmed)

runPlanReconcile :: FilePath -> IO ()
runPlanReconcile selected = withLifecycleScope selected $ \projection -> do
  let scope = bootstrapScope projection
  (verdict, source) <- currentAdmission projection
  writeOutput ("Deployment: " ++ scopeKindName scope ++ "\n" ++ renderAdmissionRead verdict source)
  decision <- assessControlReconcile projection
  case decision of
    ControlReconcileUndelivered ->
      writeOutput "Reconciliation decision: the local reconcile adapter requires a test identity.\n"
    ControlReconcileRestorePending ->
      writeOutput
        "Reconciliation decision: settle the retained management restore before reconciling control.\n"
    ControlReconcileAuthorityRemovalUnconfirmed ->
      writeOutput "Reconciliation decision: resolve the selected Authority's retained control removal.\n"
    ControlReconcileResume operation ->
      writeOutput
        ("Reconciliation decision: observe and continue retained control operation " ++ operation ++ ".\n")
    ControlReconcilePrepare ->
      writeOutput
        "Reconciliation decision: verify scope, prior operation settlement, declared artifacts, capacity and ports before preparing a control operation.\n"
    ControlReconcileRecover unconfirmed ->
      writeOutput
        ( "Reconciliation decision: resolve the retained control operation observation ("
            ++ show unconfirmed
            ++ ").\n"
        )
  failOnUnobservableAdmission verdict

runControlReconcile :: FilePath -> IO ()
runControlReconcile selected = withLifecycleScope selected $ \projection -> do
  decision <- assessControlReconcile projection
  case decision of
    ControlReconcileUndelivered -> failWith "Control reconcile currently supports only test identities."
    ControlReconcileRestorePending -> failWith "Settle the retained management restore before reconciling control."
    ControlReconcileAuthorityRemovalUnconfirmed -> failWith "The retained Authority removal could not be confirmed."
    ControlReconcileResume operation -> resumeControlOperation projection operation
    ControlReconcilePrepare -> runFreshControlReconcile projection
    ControlReconcileRecover _ -> runFreshControlReconcile projection

runOperations :: FilePath -> OperationCommand -> IO ()
runOperations selected command = withLifecycleScope selected (runScopedOperation command)

runScopedOperation :: OperationCommand -> BootstrapProjection -> IO ()
runScopedOperation command projection = case command of
  ListOperations -> do
    current <- observeKindOwnerFamilyIntent projection
    writeOutputLine $ case current of
      KindIntentMatches operation -> "Current control operation: " ++ operation
      KindIntentMissing -> "No current control operation is recorded."
      _ -> "The current control operation could not be confirmed."
    storage <- observeManagementRestoreOperation projection
    case storage of
      NoManagementRestoreOperation -> pure ()
      PendingManagementRestore operation backup ->
        writeOutputLine ("Pending management restore: " ++ operation ++ " for " ++ backup)
      UnconfirmedManagementRestoreOperation ->
        writeOutputLine "Management restore operation could not be confirmed."
    (verdict, source) <- currentAdmission projection
    writeOutput (renderAdmissionRead verdict source)
    failOnUnobservableAdmission verdict
  ShowOperation operation ->
    withOperation
      operation
      (showControl operation)
      ( \backup ->
          writeOutputLine
            ("Management restore operation " ++ operation ++ " is pending for backup " ++ backup ++ ".")
      )
      (showCompletedRestore operation)
  ResumeOperation operation ->
    withOperation
      operation
      (resumeControl operation)
      (restoreSelectedOperation projection)
      (showCompletedRestore operation)
  CancelOperation operation ->
    withOperation
      operation
      (cancelControlOperation projection operation)
      (const (failWith "The admitted management restore must settle with its original backup."))
      (const (failWith "The management restore already settled."))
 where
  showCompletedRestore operation backup =
    writeOutputLine
      ("Management restore operation " ++ operation ++ " completed for backup " ++ backup ++ ".")
  withOperation operation control restore replay
    | not (validRootGeneration operation) =
        failWith "An operation ID must be 32 lowercase hexadecimal characters."
    | scopeEnvironment (bootstrapScope projection) /= Test =
        failWith "The local control operation adapter requires a test identity."
    | otherwise = do
        storage <- observeManagementRestoreOperation projection
        case storage of
          PendingManagementRestore active backup | active == operation -> restore backup
          _ -> do
            completed <- observeCompletedManagementRestore projection operation
            case completed of
              CompletedRestore backup -> replay backup
              UnconfirmedCompletedRestore -> failWith "The retained management restore completion could not be confirmed."
              NoCompletedRestore -> do
                current <- observeKindOwnerFamilyIntent projection
                if current == KindIntentMatches operation
                  then control
                  else runAuthorityInitializationOperation projection operation command
  showControl operation = do
    publication <- observeControlPublication projection operation
    recorded <-
      withRecoveredKindOperation projection operation (observeFamilyResult projection operation)
    case (publication, recorded) of
      (KindOperationCallbackReturned (_, observed), KindOperationCallbackReturned retained) -> do
        writeOutputLine ("Control operation " ++ operation ++ ": " ++ show observed)
        writeOutputLine ("Retained local result: " ++ show retained)
      _ -> failWith "The selected operation publication could not be observed."
  resumeControl operation = do
    decision <- assessControlReconcile projection
    case decision of
      ControlReconcileResume current | current == operation -> resumeControlOperation projection operation
      _ -> failWith "The selected operation is unavailable for reconcile recovery."

runAuthorityInitializationOperation :: BootstrapProjection -> String -> OperationCommand -> IO ()
runAuthorityInitializationOperation projection operation command = do
  observed <- currentAuthorityInitialization projection
  case observed of
    Right (JournalInitializationArmed active) | active == identifier -> pending
    Right (JournalInitializationComplete settled) | settled == identifier -> completed
    Right JournalInitializationUnconfirmed -> failWith "The retained Authority operation could not be confirmed."
    Right _ -> failWith "The selected scope has no operation with that ID."
    Left reason -> failWith ("The Authority operation could not be observed: " ++ reason)
 where
  identifier = Text.pack operation
  label = "Authority journal initialization " ++ operation
  pending = case command of
    ShowOperation _ -> writeOutputLine (label ++ " is pending.")
    ResumeOperation _ -> do
      steps <- deployAuthorityWithAdmission projection $ do
        current <- currentAuthorityInitialization projection
        pure (current == Right (JournalInitializationArmed identifier))
      readBack <- currentAuthorityInitialization projection
      case readBack of
        Right (JournalInitializationComplete settled)
          | settled == identifier -> writeOutputLine (label ++ " completed.")
        _ -> do
          mapM_ writeOutputLine [serviceStepDetail step | step <- steps, not (serviceStepOk step)]
          failWith (label ++ " is still unconfirmed. Retry the same operation ID.")
    CancelOperation _ -> failWith (label ++ " is armed and must settle under its original identity.")
    ListOperations -> failWith "Select an exact Authority operation ID."
  completed = case command of
    CancelOperation _ -> failWith (label ++ " already settled.")
    _ -> writeOutputLine (label ++ " completed.")

observeControlPublication
  :: BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (FamilyLaunchObservation, KindFamilyPublicationState))
observeControlPublication projection operation =
  withRecoveredKindOperation projection operation $ \stable -> do
    launch <- observeFamilyLaunch projection operation stable
    attempt <- observeFamilyPublicationAttempt projection operation stable
    cancellation <- observeFamilyPrePublicationCancellation projection operation stable
    pure (launch, classifyKindFamilyPublication launch attempt cancellation)

resumeControlOperation :: BootstrapProjection -> String -> IO ()
resumeControlOperation projection operation = do
  owner <- observeKindOwnerFamilyIntent projection
  publication <- observeControlPublication projection operation
  case (owner == KindIntentMatches operation, publication) of
    (True, KindOperationCallbackReturned (_, KindFamilyPublicationNotRecorded)) ->
      launchFreshKindFamily projection operation >>= finishControlLaunch projection operation
    ( True
      , KindOperationCallbackReturned (FamilyLaunchObserved request, KindFamilyPublicationBeforeAttempt)
      ) ->
        launchKindFamily (hostExecutionOuterEnd (kindRequestWindow request)) projection request
          >>= finishControlLaunch projection operation
    (_, KindOperationCallbackReturned (_, KindFamilyPublicationCancelled)) ->
      failWith ("Control operation " ++ operation ++ " was cancelled before publication.")
    _ -> finishFamilyReconcile projection operation

cancelControlOperation :: BootstrapProjection -> String -> IO ()
cancelControlOperation projection operation = do
  publication <- observeControlPublication projection operation
  let mark = withCancelledPrePublicationKindFamily projection operation (const (pure ()))
  cancelled <- case publication of
    KindOperationCallbackReturned (_, KindFamilyPublicationNotRecorded) -> do
      prepared <- prepareFreshKindFamilyRequest projection operation
      case prepared of
        Right (request, _) -> withCancelledUnlaunchedOwnerFamily projection request (const (pure ()))
        Left _ -> pure KindFamilyPrePublicationRefused
    KindOperationCallbackReturned (_, KindFamilyPublicationBeforeAttempt) -> mark
    KindOperationCallbackReturned (_, KindFamilyPublicationCancelled) -> mark
    _ -> pure KindFamilyPrePublicationRefused
  case cancelled of
    KindFamilyPrePublicationReturned () True ->
      writeOutputLine ("Control operation " ++ operation ++ " was cancelled before publication.")
    _ ->
      failWith
        "Cancellation could not be confirmed before publication. The original operation remains available for settlement."

finishFamilyReconcile :: BootstrapProjection -> String -> IO ()
finishFamilyReconcile projection operation = do
  now <- getMonotonicTimeNSec
  let budget = 600000000000 :: Word64
  if now > maxBound - budget
    then failWith "Incomplete: completion deadline unavailable."
    else do
      outcome <-
        awaitKindFamilyCompletionWith
          getMonotonicTimeNSec
          threadDelay
          (now + budget)
          (observeKindFamilyCompletion (now + budget) projection operation)
      case outcome of
        KindFamilyCompletionObserved
          ( KindFamilyRetirementReturned
              (KindOperationCallbackReturned (KindFamilyCompletionReturned observed))
              (Right ())
              True
            )
            | kindFamilyReadinessComplete observed ->
                writeOutputLine
                  ( "Control reconcile completed for operation "
                      ++ operation
                      ++ ".\nNetwork policy enforcement: PROVEN"
                  )
        _ -> do
          familyResult <- observeFamilyResultStatus projection
          familyInputs <- recoverNeverSentKindFamilyInputs (now + budget) projection operation
          neverSent <- recoverNeverSentKindProbeInputs (now + budget) projection operation
          journal <- withRecoveredKindOperation projection operation $ \stable ->
            observeProbeJournal projection operation ("prodbox-netcheck-" ++ take 12 operation) stable
          verifier <- case journal of
            KindOperationCallbackReturned ProbeJournalVerifierPending {} ->
              Just <$> recoverNeverSentKindProbeVerifierInputs (now + budget) projection operation
            _ -> pure Nothing
          failWith
            ( "Incomplete: operation "
                ++ operation
                ++ "; family completion or probe cleanup unconfirmed: "
                ++ show outcome
                ++ "; "
                ++ familyResult
                ++ "; never-sent family input recovery: "
                ++ show familyInputs
                ++ "; never-sent cleanup publication recovery: "
                ++ show neverSent
                ++ maybe "" (\result -> "; never-sent verifier publication recovery: " ++ show result) verifier
            )

runFreshControlReconcile :: BootstrapProjection -> IO ()
runFreshControlReconcile projection = do
  outcome <- prepareNewOwnerFamilyOperation (admitReconcile projection) projection
  case outcome of
    ReconcileFamilyOperationReady operation -> do
      launched <- launchFreshKindFamily projection operation
      finishControlLaunch projection operation launched
    ReconcileCapacityRefused reason -> failWith ("Refused before any work: " ++ reason)
    other -> failWith ("Incomplete before family launch; records are retained: " ++ show other)

finishControlLaunch :: BootstrapProjection -> String -> KindFamilyLaunchOutcome -> IO ()
finishControlLaunch projection operation outcome = case outcome of
  KindFamilyLaunchLease
    (KindOperationCallbackReturned (Right (Right (), KindFamilyLaunchPossiblySent))) ->
      finishFamilyReconcile projection operation
  _ ->
    failWith
      ( "Incomplete: operation "
          ++ operation
          ++ "; managed family launch: "
          ++ show outcome
          ++ ". Records and any published input disposition are retained for recovery."
      )

runControlArtifactImport :: FilePath -> String -> FilePath -> IO ()
runControlArtifactImport selected role source = case role of
  "kind-tool" -> run BootstrapKindTool
  "node-archive" -> run BootstrapNodeArchive
  _ -> failWith "Artifact role must be kind-tool or node-archive."
 where
  run artifact = do
    bootstrap <- readBootstrapProjection selected
    case bootstrap of
      Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
      Right projection -> do
        result <- importBootstrapArtifact projection artifact source
        case result of
          ArtifactImported ->
            writeOutput
              "Declared artifact retained and read back; image contents and provenance were not verified.\n"
          ArtifactAlreadyPresent ->
            writeOutput "Declared artifact already matches; image contents and provenance were not verified.\n"
          failure -> failWith ("Artifact import was not confirmed: " ++ show failure)

runControlInspectNodeArchive :: FilePath -> IO ()
runControlInspectNodeArchive selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      let reference = kindPlanNodeImage (bootstrapKindPlan projection)
          selectedDigest = drop 1 (dropWhile (/= '@') reference)
      observation <- withInspectedNodeArchive projection $ \verified _ _ -> do
        daemon <- observeImage (bootstrapRuntimeSocket projection) reference
        configId <- observeImageId (bootstrapRuntimeSocket projection) (nodeConfigDigest verified)
        manifestId <- observeImageId (bootstrapRuntimeSocket projection) (nodeManifestDigest verified)
        pure
          ( verified
          , daemon
          , configId
          , manifestId
          , renderKindConfigForArchive (bootstrapKindPlan projection) verified
          )
      case observation of
        InspectedArchiveCompleted
          ( VerifiedNodeArchive _ digest configDigest architecture footprint _
            , daemon
            , configId
            , manifestId
            , localConfig
            ) -> do
            let comparison = case compareImageArchive selectedDigest digest configDigest architecture daemon of
                  ImageArchiveUnobservable -> "Daemon image metadata: unobservable."
                  ImageArchiveConfigMatches -> "Daemon image metadata: matches the archive config, platform and configured digest."
                  ImageArchiveDescriptorMatches ->
                    "Daemon image metadata: matches the archive descriptor, platform and configured digest; daemon config digest was not observed."
                  ImageArchiveMetadataDiffers -> "Daemon image metadata: differs from the archive config, platform or configured digest."
            writeOutput $
              "Selected image manifest and platform blobs match: "
                ++ digest
                ++ " (linux/"
                ++ architecture
                ++ "). Config digest: "
                ++ configDigest
                ++ ".\n"
                ++ "Archive top-level entries: "
                ++ show (archiveTopLevelDescriptors footprint)
                ++ "; entries with recognized image-name metadata: "
                ++ show (archiveDescriptorsWithNameMetadata footprint)
                ++ ". This is not a complete inventory of load effects.\n"
                ++ comparison
                ++ "\nLocal kind image configuration: "
                ++ (case localConfig of Just _ -> "matches the selected archive config ID."; Nothing -> "unavailable.")
                ++ "\nConfig image ID: "
                ++ renderImageId configId
                ++ "\nManifest image ID: "
                ++ renderImageId manifestId
                ++ " The observations are not atomic; Docker executable identity, publisher, daemon loadability and cluster state were not verified.\n"
        InspectedArchiveRefused failure -> failWith ("Node archive inspection was not confirmed: " ++ show failure)
        InspectedArchiveChanged _ -> failWith "Node archive inspection was not confirmed: NodeArchiveChanged"
        InspectedArchiveUnconfirmed failure -> failWith ("Node archive observation was interrupted: " ++ show failure)
        InspectedArchiveUnconfirmedAfter _ failure -> failWith ("Node archive observation was interrupted: " ++ show failure)
 where
  renderImageId ImageIdUnobservable = "unobservable."
  renderImageId (ImageIdObserved os arch tags) =
    "observed " ++ os ++ "/" ++ arch ++ " with " ++ show tags ++ " daemon tags."

runControlInspectImageAttempt :: FilePath -> String -> IO ()
runControlInspectImageAttempt selected operation
  | not (validRootGeneration operation) =
      failWith "Operation must be a valid retained operation identifier."
  | otherwise = do
      bootstrap <- readBootstrapProjection selected
      case bootstrap of
        Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
        Right projection -> do
          result <- observeRecoveredConnectedNodeImage projection operation
          case result of
            KindOperationCallbackReturned
              ( InspectedArchiveCompleted
                  ( StagedNodeCompleted
                      ( NodeImageConnectedObserved
                          (DockerPeerCompleted (DockerConnectedInfoCompleted (NodeImageConnectionReady point)))
                        )
                    )
                ) -> writeOutput (renderImageAttemptObservation operation point)
            _ -> failWith ("Image attempt observation was not confirmed: " ++ show result)

renderImageAttemptObservation :: String -> NodeImageRecoveryPoint -> String
renderImageAttemptObservation operation point =
  unlines
    [ "Operation: " ++ operation
    , "Exact image ID: " ++ recoveryImageId point
    , "Attempt before image query: " ++ attemptText (recoveryAttemptBefore point)
    , "Recorded transport observation: " ++ resultText (recoveryRecordedResult point)
    , "Image metadata: " ++ imageText (recoveryImageObservation point)
    , "Separate Docker CLI observation: " ++ independentText (recoveryIndependentImage point)
    , "Attempt after image query: " ++ attemptText (recoveryAttemptAfter point)
    , "Observations are not atomic; image absence, ownership, daemon authentication and worker settlement are unverified. No retry or image load was submitted."
    ]
 where
  attemptText NodeImageAttemptMissing = "not found locally"
  attemptText NodeImageAttemptMatches = "matching local marker"
  attemptText NodeImageAttemptConflict = "conflicting local marker"
  attemptText NodeImageAttemptInvalid = "invalid or incomplete local marker"
  attemptText NodeImageAttemptUnobservable = "unobservable"
  resultText NodeImageResultMissing = "not found locally"
  resultText NodeImageResultConflict = "conflicts with the selected attempt"
  resultText NodeImageResultInvalid = "invalid or incomplete"
  resultText NodeImageResultUnobservable = "unobservable"
  resultText (NodeImageResultObserved DockerImageLoadNotStarted) = "submission did not start"
  resultText (NodeImageResultObserved DockerImageLoadUnconfirmed) = "submission unconfirmed"
  resultText (NodeImageResultObserved (DockerImageLoadReply status stream)) =
    "HTTP " ++ show status ++ "; " ++ streamText stream
  streamText (DockerImageLoadMessages count) = show count ++ if count == 1 then " progress message" else " progress messages"
  streamText DockerImageLoadErrorMessage = "daemon reported an error"
  streamText DockerImageLoadInvalidStream = "response stream unobservable"
  imageText :: Either DockerConnectedInfoFailure ImageIdObservation -> String
  imageText (Left failure) = "unobservable (" ++ show failure ++ ")"
  imageText (Right ImageIdUnobservable) = "unobservable"
  imageText (Right (ImageIdObserved os arch tags)) =
    "observed " ++ os ++ "/" ++ arch ++ " with " ++ show tags ++ " daemon tags"
  independentText NodeImageIndependentUnobservable = "unobservable"
  independentText (NodeImageIndependentObserved observed) = imageText (Right observed)
  independentText (NodeImageIndependentChanged observed) = "scope or daemon changed after " ++ imageText (Right observed)

runControlArtifactDiscard :: FilePath -> String -> IO ()
runControlArtifactDiscard selected role = case role of
  "kind-tool" -> run BootstrapKindTool
  "node-archive" -> run BootstrapNodeArchive
  _ -> failWith "Artifact role must be kind-tool or node-archive."
 where
  run artifact = do
    bootstrap <- readBootstrapProjection selected
    case bootstrap of
      Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
      Right projection -> do
        result <- discardBootstrapArtifactStaging projection artifact
        case result of
          ArtifactStagingDiscarded -> writeOutput "Selected artifact staging discarded; retained artifacts were not changed.\n"
          failure -> failWith ("Artifact staging discard was not confirmed: " ++ show failure)

canRunWithoutRepoRoot :: NativeCommand -> Bool
canRunWithoutRepoRoot (NativeBootstrapBroker (BootstrapBrokerStart _)) = True
canRunWithoutRepoRoot (NativeBootstrapBroker (BootstrapBrokerSecretWorker _ _)) = True
canRunWithoutRepoRoot (NativeControlPlane _ _) = True
canRunWithoutRepoRoot (NativeRpcBirthController _) = True
canRunWithoutRepoRoot (NativeCredentialProvisioner _) = True
canRunWithoutRepoRoot (NativeGateway (GatewayDaemonCommand _)) = True
canRunWithoutRepoRoot (NativeGateway (GatewayStatusCommand _)) = True
canRunWithoutRepoRoot (NativeWorkload (WorkloadStart _)) = True
-- Sprint 1.49: `config generate` is binary-owned — it writes the
-- binary-sibling `prodbox.dhall` (`resolveTier0ConfigPath`, which ignores the
-- repo root), so it must run in a non-repo context such as the in-container
-- image build (`RUN prodbox config generate`).
canRunWithoutRepoRoot (NativeConfig (ConfigGenerate _)) = True
canRunWithoutRepoRoot _ = False

failWith :: String -> IO ()
failWith message = do
  writeError (fatalError (Text.pack message))
  exitWith (ExitFailure 1)

renderCommandsPlain :: CommandSpec -> String
renderCommandsPlain = unlines . go []
 where
  go prefix spec =
    case children spec of
      [] ->
        [ unwords ("prodbox" : prefix ++ [name spec])
            ++ " - "
            ++ summary spec
        ]
      nested ->
        concatMap
          ( \child ->
              let nextPrefix =
                    if name spec == "prodbox"
                      then prefix
                      else prefix ++ [name spec]
               in go nextPrefix child
          )
          nested
