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

import Control.Exception (IOException, try)
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
  , TestCommand (..)
  , TestScope (..)
  , WorkloadCommand (..)
  )
import Prodbox.CLI.Docs (renderCommandHelp)
import Prodbox.CLI.Json (renderCommandJson)
import Prodbox.CLI.Output
  ( writeError
  , writeOutput
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
  )
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
  , bootstrapRuntimeSocket
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.BootstrapSetup (runSelectedBootstrapSetup)
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
import Prodbox.Control.AuthorityDeploy (deployAuthority)
import Prodbox.Control.AuthorityJournalClient (AdmissionSource (..), currentAdmission)
import Prodbox.Control.Backup (backupServices, renderBackupOutcome, restoreServices)
import Prodbox.Control.BrokerClientCommand (brokerVaultStatus)
import Prodbox.Control.Delete (DeleteStep (..), deleteNewTestIdentity)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoFailure
  , DockerConnectedInfoResult (..)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..), withConnectedDockerPeer)
import Prodbox.Control.HostPorts (dockerNameRefusal, hostPortRefusal)
import Prodbox.Control.KindController
  ( kindHostCapacityRefusal
  , launchKindController
  , runKindControllerEntry
  )
import Prodbox.Control.KindDockerClient (runKindDockerClient)
import Prodbox.Control.KindLease (KindOperationOutcome (..))
import Prodbox.Control.KindRuntimeConfig (renderKindConfigForArchive)
import Prodbox.Control.KubernetesReadiness (observeKubernetesReadiness, renderKubernetesReadiness)
import Prodbox.Control.NetworkEnforcement
  ( EnforcementOutcome (..)
  , enforcementProven
  , observeNetworkEnforcement
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
import Prodbox.Control.Reconcile (ReconcileOutcome (..), reconcileNewPrerequisites)
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
import Prodbox.Control.Unlock (renderUnlockOutcome, unlockVault)
import Prodbox.Error (fatalError)
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , noChangeAllowed
  , renderVerdict
  )
import Prodbox.Native (runNativeCommand)
import Prodbox.Repo (findRepoRoot, resolveTier0ConfigPath)
import Prodbox.Settings (SelectedSettingsValidation (..), validateSelectedSettingsAtPath)
import Prodbox.Subprocess.SystemdBus (BusError, SystemDockerObservation (..), observeSystemDocker)
import Prodbox.TestRunner
  ( renderNamedLocalTestList
  , runSelectedMutationCatalog
  , runSelectedPhaseScenario
  , runSelectedPhaseThreeScenario
  , runSelectedPhaseTwoBrokerScenario
  , runSelectedPhaseTwoScenario
  )
import System.Directory (doesFileExist)
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode (ExitFailure), exitWith)
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
  RunNative (NativeConfig (ConfigSetup options)) -> runSelectedBootstrapSetup selected options >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-01") _ _ _)) -> runSelectedPhaseScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-02") _ _ _)) -> runSelectedPhaseTwoScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-02-broker") _ _ _)) -> runSelectedPhaseTwoBrokerScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-03") _ _ _)) -> runSelectedPhaseThreeScenario selected >>= exitWith
  RunNative (NativeTest (TestCommand (TestRun "phase-01-mutation") _ _ _)) -> runSelectedMutationCatalog >>= exitWith
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

runCommandRequest :: CommandRequest -> IO ()
runCommandRequest request =
  case request of
    RunTestList -> writeOutput renderNamedLocalTestList
    RunControlStatus -> resolveTier0ConfigPath "." >>= runControlStatus
    RunControlLifecycleStatus -> resolveTier0ConfigPath "." >>= runControlLifecycleStatus
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
    RunInternalKindController arguments -> runKindControllerEntry arguments >>= exitWith
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

runOrdinaryDelete :: FilePath -> IO ()
runOrdinaryDelete selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      (verdict, _) <- currentAdmission (scopeRoot (bootstrapScope projection))
      case verdict of
        NeverAdmitted ->
          writeOutput
            "Nothing to delete: no cloud capability was ever admitted for this deployment. The kind environment, local services, trust and journal are retained.\n"
        AdmittedSettled ->
          failWith
            "Refused: this deployment admitted a capability whose deletion is not delivered by this binary yet; nothing was changed.\n"
        _ ->
          failWith
            ( "Refused: deletion needs a settled, known operation history. "
                ++ renderVerdict verdict
                ++ "\nNothing was changed; resolve the journal through recovery first.\n"
            )

runControlLifecycleStatus :: FilePath -> IO ()
runControlLifecycleStatus selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      (verdict, source) <- currentAdmission (scopeRoot (bootstrapScope projection))
      writeOutput
        ( renderVerdict verdict
            ++ ( case source of
                   FromAuthority observedAt -> " [source: the Authority's journal, read at " ++ Text.unpack observedAt ++ "]"
                   FromLocalControlJournal -> " [source: local control journal; no Authority is deployed]"
               )
            ++ "\n"
        )
      case verdict of
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
      either
        (failWith . ("Cannot observe local control: " ++) . renderControlStatusError)
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
runControlDelete :: FilePath -> IO ()
runControlDelete selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection -> do
      (verdict, _) <- currentAdmission (scopeRoot (bootstrapScope projection))
      if noChangeAllowed verdict
        then deleteAdmitted projection
        else
          failWith
            ( "Refused: removal needs a settled, known operation history. "
                ++ renderVerdict verdict
                ++ "\nNothing was removed; resolve the journal through recovery first.\n"
            )
 where
  deleteAdmitted projection = do
    steps <- deleteNewTestIdentity projection
    let render step =
          "  "
            ++ deleteStepName step
            ++ ": "
            ++ (if deleteStepCompleted step then "removal reply recorded" else "NOT completed")
            ++ " - "
            ++ take 300 (deleteStepDetail step)
            ++ "\n"
        report = concatMap render steps
    if all deleteStepCompleted steps
      then
        writeOutput
          ( "Recorded kind resources were removed; replies are not proof of absence, so read `control status`.\n"
              ++ report
              ++ "Host data, records, artifacts, the loaded node image and the retained root remain.\n"
          )
      else failWith ("Removal is incomplete; records are retained for recovery.\n" ++ report)

-- Run the real-socket policy observation when the kubeconfig was installed.
observeEnforcementReport :: BootstrapProjection -> String -> IO String
observeEnforcementReport projection operation = do
  let kubeconfig = scopeRoot (bootstrapScope projection) </> "control" </> "kubeconfig"
  present <- doesFileExist kubeconfig
  if not present
    then pure "Network policy enforcement: not observed (no installed kubeconfig)."
    else do
      outcome <- observeNetworkEnforcement kubeconfig ("prodbox-netcheck-" ++ take 12 operation)
      pure $
        "Network policy enforcement: "
          ++ ( case enforcementObservation outcome of
                 Just observation
                   | enforcementProven observation -> "PROVEN with real connections (" ++ show observation ++ ")"
                   | otherwise -> "NOT proven (" ++ show observation ++ ")"
                 Nothing -> "not observed (" ++ maybe "unknown" id (enforcementFailure outcome) ++ ")"
             )
          ++ "; cleanup: "
          ++ enforcementCleanup outcome
          ++ "."

-- Always ends Incomplete: the cluster is not initialized, no kubeconfig or
-- readiness exists, and no remover is delivered. Created resources are kept.

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
            Just password -> do
              let kubeconfig = scopeRoot (bootstrapScope projection) </> "control" </> "kubeconfig"
                  environment = [("KUBECONFIG", kubeconfig), ("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
              code <- case action of
                BrokerInitAction -> brokerInitializeSelected "." environment password
                BrokerUnsealAction -> brokerUnsealSelected "." environment password
                BrokerBaselineAction -> brokerBaselineSelected "." environment password
              exitWith code

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
          steps <- restoreServices projection name
          let (ok, rendered) = renderBackupOutcome steps
          if ok
            then writeOutput ("Restore complete; run `control unlock` to unseal Vault.\n" ++ rendered)
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

runControlReconcile :: FilePath -> IO ()
runControlReconcile selected = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> failWith ("Cannot read control bootstrap: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          failWith "Control reconcile currently supports only test identities."
      | otherwise -> do
          outcome <-
            reconcileNewPrerequisites
              (admitReconcile projection)
              projection
          case outcome of
            ReconcileNodeReady operation -> do
              let resultPath = scopeRoot (bootstrapScope projection) </> ("kind-controller-result-" ++ operation)
              launched <- launchKindController selected operation resultPath
              result <- try (readFile resultPath) :: IO (Either IOException String)
              network <- observeEnforcementReport projection operation
              failWith $
                "Incomplete: operation "
                  ++ operation
                  ++ ". Prerequisites were created and retained; managed node attempt: "
                  ++ either ("failed: " ++) ("ok: " ++) launched
                  ++ "; controller result: "
                  ++ either (const "unavailable") (takeWhile (/= '\n')) result
                  ++ ". "
                  ++ network
                  ++ " Readiness read-back and recreation are not delivered."
            ReconcileCapacityRefused reason ->
              failWith ("Refused before any work: " ++ reason)
            other -> failWith ("Incomplete before node creation; records are retained: " ++ show other)

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
