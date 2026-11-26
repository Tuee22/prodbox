{-# LANGUAGE OverloadedStrings #-}

-- | The Phase 3 scenario runner (first slice): drive the built public binary
-- (`control reconcile`, `control lifecycle-status`, `control delete`) against
-- one explicitly selected test identity and check each claim with other
-- tools: Docker listings, direct directory listings of the retained root and
-- the journal, and direct file reads. The journal is written only through the
-- store module the Authority will use; the harness never edits a verdict. The
-- report is non-secret.
module Prodbox.Test.Phase03Runner
  ( runPhase03Scenario
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, onException, try)
import Control.Monad (void, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (artifactDigest)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeKindName
  , scopeRoot
  )
import Prodbox.Config.KindPlan (renderKindConfig)
import Prodbox.Control.JournalStore
  ( appendIntent
  , appendSettlement
  , historyMarkerPath
  , journalDirectory
  , observeJournal
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches)
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.TestRunCleanup (registerSettledTestRun)
import Prodbox.ControlPlane.ListenPort (authorityJournalReadPort, controlPlaneListenPort)
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , RecoveryReason (RecoveryHistoryMissing)
  , classifyAdmission
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.FixtureTree (captureFixtureTree, cleanupFixtureTree)
import Prodbox.Test.Phase01Runner
  ( digest
  , hex32
  , independentAbsence
  , independentClusterReady
  , independentHostData
  , publishScenario
  , readRandomBytes
  , run
  , scenarioReport
  )
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.ScenarioEvidence
  ( ScenarioBinding (..)
  , ScenarioBudget (..)
  , ScenarioCleanup (..)
  , ScenarioPrimary (..)
  , ScenarioTiming (..)
  )
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , renameDirectory
  , renameFile
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Directory qualified as PosixDirectory
import System.Posix.Files (getSymbolicLinkStatus, setFileMode)
import Text.Read (readMaybe)

runPhase03Scenario :: FilePath -> IO ExitCode
runPhase03Scenario selected = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> do
          let root = scopeRoot (bootstrapScope projection)
          vacant <-
            and
              <$> traverse
                (pathAbsent . (root </>))
                [ "authority"
                , "authority-journal"
                , "authority-journal-custody"
                , "authority-journal-intent.json"
                , "authority-journal-binding.json"
                ]
          if vacant
            then scenario selected projection
            else refuse "the selected fixture already has Authority history or its paths are unobservable"
 where
  refuse message = writeOutputLine ("phase-03 scenario refused: " ++ message) >> pure (ExitFailure 2)

pathAbsent :: FilePath -> IO Bool
pathAbsent path = do
  observed <- try (getSymbolicLinkStatus path)
  pure (either isDoesNotExistError (const False) observed)

scenario :: FilePath -> BootstrapProjection -> IO ExitCode
scenario selected projection = do
  let scope = bootstrapScope projection
      cluster = scopeKindName scope
      root = scopeRoot scope
      project = takeDirectory (takeDirectory root)
      generation = Text.unpack (bootstrapRootGeneration projection)
  executable <- getExecutablePath
  binaryBytes <- ByteString8.readFile executable
  sourceResult <- captureSourceIdentity "." []
  randomResult <- readRandomBytes
  started <- getMonotonicTimeNSec
  case (sourceResult, randomResult) of
    (Left failure, _) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    (_, Left failure) -> writeOutputLine ("scenario entropy refused: " ++ failure) >> pure (ExitFailure 2)
    (Right source, Right randomBytes) -> do
      let second = 1000000000
          budget = ScenarioBudget (started + 1200 * second) (started + 1500 * second) (1024 * 1048576) 1200000000 0
          artifacts =
            [ ("kind.tool", digest (maybe "" artifactDigest (bootstrapKindTool projection)))
            , ("node.archive", digest (maybe "" artifactDigest (bootstrapNodeArtifact projection)))
            ]
          bindingFor :: Word16 -> String -> ScenarioBinding
          bindingFor caseNumber label =
            ScenarioBinding
              3
              caseNumber
              scope
              generation
              (hex32 (randomBytes <> "run"))
              (hex32 (randomBytes <> "operation" <> ByteString8.pack label))
              (hex32 "phase-03-boot")
              source
              (digest (ByteString8.unpack (hexSha256 binaryBytes)))
              artifacts
              (digest (show (renderKindConfig (bootstrapKindPlan projection))))
              (digest ("control reconcile; lifecycle-status; delete; case " ++ label))
              budget
          public args = run executable (["--config", selected] ++ args)
          kubeconfig = root </> "control" </> "kubeconfig"
          capture program arguments input = do
            result <-
              captureSubprocessWithInputBounded
                (BoundedSubprocessLimits (64 * 1024) (1024 * 1024) (256 * 1024) 400000000)
                input
                ( Subprocess
                    program
                    arguments
                    (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("XDG_RUNTIME_DIR", "/run/user/1000")])
                    Nothing
                )
            pure $ case result of
              Right output ->
                Right
                  ( case processExitCode output of ExitSuccess -> 0 :: Int; ExitFailure code -> code
                  , processStdout output
                  , processStderr output
                  )
              Left failure -> Left (show failure)
          publicWithInput args = capture executable (["--config", selected] ++ args)
          kubectl args =
            capture
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ args)
              ByteString.empty
          textOf result = either (const "") (\(_, out, err) -> out ++ err) result
          ok result = either (const False) (\(code, _, _) -> code == 0) result
          failed result = either (const False) (\(code, _, _) -> code /= 0) result
          journal = journalDirectory root
          listJournal = do
            present <- doesDirectoryExist journal
            if present
              then sort . filter (not . isPrefixOf ".") <$> listDirectory journal
              else pure []
      -- Case 1: a never-admitted deployment reports truthfully and deletes twice.
      reconcile1 <- public ["control", "reconcile"]
      ready1 <- independentClusterReady (bootstrapRuntimeSocket projection) root cluster
      status1 <- public ["control", "lifecycle-status"]
      authorityAbsentAfterStatus <- not <$> doesDirectoryExist (root </> "authority")
      ordinary1 <- public ["delete", "--yes"]
      ordinary2 <- public ["delete", "--yes"]
      readyAfterOrdinary <- independentClusterReady (bootstrapRuntimeSocket projection) root cluster
      authorityAbsentAfterOrdinary <- not <$> doesDirectoryExist (root </> "authority")
      delete1 <- public ["control", "delete", "--yes"]
      delete2 <- public ["control", "delete", "--yes"]
      absent <- independentAbsence (bootstrapRuntimeSocket projection) cluster
      retained <- independentHostData root generation (bootstrapNodeArtifact projection)
      case1Done <- getMonotonicTimeNSec
      -- Case 2: the private synthetic journal exercises the classification.
      -- The public CLI still has a kubeconfig for the now absent API and must
      -- refuse mutation when it cannot independently observe the Authority.
      let fixtureVerdict = classifyAdmission <$> observeJournal root
      intent <- appendIntent root "op-a"
      let fixtureRoot = root </> "authority"
          fixtureOwned = absent && retained && authorityAbsentAfterOrdinary && intent == Right ()
      when fixtureOwned $ do
        setFileMode fixtureRoot 0o700
        setFileMode journal 0o700
        setFileMode (historyMarkerPath root) 0o600
      statusPending <- fixtureVerdict
      offlineAuthority <- public ["control", "lifecycle-status"]
      afterIntent <- listJournal
      deletePending <- public ["control", "delete", "--yes"]
      retainedPending <- independentHostData root generation (bootstrapNodeArtifact projection)
      ordinaryPending <- public ["delete", "--yes"]
      afterOrdinaryPending <- listJournal
      settled <- appendSettlement root "op-a"
      statusSettled <- fixtureVerdict
      afterSettle <- listJournal
      markerPresent <- doesFileExist (historyMarkerPath root)
      renameDirectory journal (journal ++ ".away")
      statusMissing <- fixtureVerdict
      markerStill <- doesFileExist (historyMarkerPath root)
      deleteUnknown <- public ["control", "delete", "--yes"]
      retainedUnknown <- independentHostData root generation (bootstrapNodeArtifact projection)
      renameDirectory (journal ++ ".away") journal
      ByteString8.writeFile (journal </> "00000050-bad.json") "not a record"
      when fixtureOwned (setFileMode (journal </> "00000050-bad.json") 0o600)
      statusCorrupt <- fixtureVerdict
      ByteString8.writeFile
        (journal </> "00000050-bad.json")
        "{\"schema_version\":1,\"operation\":\"op-b\",\"state\":\"unresolved\"}"
      statusLate <- fixtureVerdict
      setFileMode journal 0o000
      statusUnreadable <- fixtureVerdict
      setFileMode journal 0o700
      statusRestored <- fixtureVerdict
      -- These entries were written by the adverse fixture before any real
      -- Authority existed. Retire only its unchanged private tree.
      fixtureRetired <-
        if fixtureOwned && retainedPending && retainedUnknown
          then captureFixtureTree fixtureRoot >>= maybe (pure False) cleanupFixtureTree
          else pure False
      case2Done <- getMonotonicTimeNSec
      -- Case 3: the Authority runtime on kind. The adverse control comes first:
      -- before Vault is initialized the deployment must not report success.
      reconcile2 <-
        if fixtureRetired
          then public ["control", "reconcile"]
          else pure (Left "the pre-Authority test journal fixture did not settle")
      operationBefore <- observeKindOwnerFamilyIntent projection
      operationEvidence <- case operationBefore of
        KindIntentMatches operation -> do
          listed <- public ["operations", "list"]
          shown <- public ["operations", "show", operation]
          let resultPath = root </> "kind-family-dispatch-result.json"
              observeResult = try (ByteString.readFile resultPath) :: IO (Either IOException ByteString.ByteString)
              observeNodes = kubectl ["get", "nodes", "-o", "jsonpath={range .items[*]}{.metadata.uid}{\"\\n\"}{end}"]
              resume = public ["operations", "resume", operation]
          resultBefore <- observeResult
          nodesBefore <- observeNodes
          (resumed, duplicate) <- Async.concurrently resume resume
          resultAfter <- observeResult
          nodesAfter <- observeNodes
          let foreignId = if operation == replicate 32 '0' then replicate 32 '1' else replicate 32 '0'
              exactResult = case (resultBefore, resultAfter) of
                (Right before, Right after) -> not (ByteString.null before) && before == after
                _ -> False
              exactNode = case (nodesBefore, nodesAfter) of
                (Right (0, before, _), Right (0, after, _)) -> length (lines before) == 1 && before == after
                _ -> False
          foreignResume <- public ["operations", "resume", foreignId]
          lateCancel <- public ["operations", "cancel", operation]
          current <- observeKindOwnerFamilyIntent projection
          ready <- independentClusterReady (bootstrapRuntimeSocket projection) root cluster
          pure
            ( ok listed
                && ok shown
                && ok resumed
                && ok duplicate
                && failed foreignResume
                && failed lateCancel
            , all (isInfixOf operation . textOf) [listed, shown, resumed, duplicate]
                && current == operationBefore
                && exactResult
                && exactNode
                && ready
            )
        _ -> pure (False, False)
      services2 <- public ["control", "services"]
      earlyDeploy <- public ["control", "authority-deploy"]
      let password = ByteString8.pack (take 24 (hex32 (randomBytes <> "operator-password")) ++ "\n")
      initRun <- publicWithInput ["control", "broker-init"] password
      unsealRun <- publicWithInput ["control", "broker-unseal"] password
      baselineRun <- publicWithInput ["control", "broker-baseline"] password
      deployRun <- public ["control", "authority-deploy"]
      podReady <-
        kubectl
          [ "-n"
          , "lifecycle-authority"
          , "get"
          , "pods"
          , "-o"
          , "jsonpath={range .items[*]}{.status.containerStatuses[0].ready}{\" \"}{.status.containerStatuses[0].restartCount}{\";\"}{end}"
          ]
      readyz <-
        kubectl
          [ "-n"
          , "lifecycle-authority"
          , "exec"
          , "deploy/lifecycle-authority"
          , "--"
          , "/bin/bash"
          , "-c"
          , "exec 3<>/dev/tcp/127.0.0.1/"
              ++ show controlPlaneListenPort
              ++ "; printf 'GET /readyz HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' >&3; cat <&3"
          ]
      storeObjects <-
        kubectl
          [ "-n"
          , "prodbox-management"
          , "exec"
          , "mc"
          , "--"
          , "/bin/sh"
          , "-c"
          , "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && mc ls local/prodbox-state >/dev/null && mc admin user list local | wc -l"
          ]
      statusViaAuthority <- public ["control", "lifecycle-status"]
      aggregateStatus <- public ["status"]
      deletionPlan <- public ["plan", "delete"]
      -- A readable stale host projection remains deliberately empty while
      -- the actual Authority's proof of journal identity is withdrawn.
      projectionVacant <- pathAbsent fixtureRoot
      stalePrepared <-
        if fixtureRetired && projectionVacant && ok statusViaAuthority
          then do
            created <-
              try
                (PosixDirectory.createDirectory fixtureRoot 0o700 >> PosixDirectory.createDirectory journal 0o700)
                :: IO (Either IOException ())
            case created of
              Right () -> captureFixtureTree fixtureRoot
              Left _ -> pure Nothing
          else pure Nothing
      staleProjection <- fixtureVerdict
      -- A missing genesis from the actual Authority requires recovery and
      -- must block deletion despite the stale host projection.
      let genesis = root </> "authority-journal" </> "genesis.json"
          withdrawn = genesis ++ ".away"
          restoreGenesis = try (renameFile withdrawn genesis) :: IO (Either IOException ())
      withdrawnGenesis <- try (renameFile genesis withdrawn) :: IO (Either IOException ())
      genesisGap <- case withdrawnGenesis of
        Left _ -> pure Nothing
        Right () -> do
          (status, deletion, removal, live) <-
            ( (,,,)
                <$> public ["control", "lifecycle-status"]
                <*> public ["delete", "--yes"]
                <*> public ["control", "delete", "--yes"]
                <*> independentClusterReady (bootstrapRuntimeSocket projection) root cluster
            )
              `onException` void restoreGenesis
          restoredGenesis <- restoreGenesis
          pure $ case restoredGenesis of
            Left _ -> Nothing
            Right () -> Just (status, deletion, removal, live)
      staleAfter <- fixtureVerdict
      staleRetired <- maybe (pure False) cleanupFixtureTree stalePrepared
      statusGenesisBack <- public ["control", "lifecycle-status"]
      genesisSeen <- doesFileExist (root </> "authority-journal" </> "genesis.json")
      mirrorText <-
        try (ByteString.readFile (root </> "authority-journal" </> "admission.json"))
          :: IO (Either IOException ByteString.ByteString)
      -- Case 4: Vault sealed under a running Authority. The Authority keeps its
      -- store credentials in memory, so it keeps answering; a restart while Vault
      -- is sealed cannot read them and must refuse, and unsealing lets it recover.
      let vaultHealth =
            kubectl
              [ "get"
              , "--raw"
              , "/api/v1/namespaces/prodbox-management/pods/vault:8200/proxy/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
              ]
          sealedIn out = "\"sealed\":true" `isInfixOf` out
          readyzOk result = case result of
            Right (0, out, _) -> "200 OK" `isInfixOf` out
            _ -> False
          readyzProbe =
            kubectl
              [ "-n"
              , "lifecycle-authority"
              , "exec"
              , "deploy/lifecycle-authority"
              , "--"
              , "/bin/bash"
              , "-c"
              , "exec 3<>/dev/tcp/127.0.0.1/"
                  ++ show controlPlaneListenPort
                  ++ "; printf 'GET /readyz HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' >&3; cat <&3"
              ]
          waitFor attempts probe
            | attempts <= (0 :: Int) = probe
            | otherwise = do
                result <- probe
                if readyzOk result then pure result else threadDelay 4000000 >> waitFor (attempts - 1) probe
      let mintToken account =
            kubectl
              [ "-n"
              , "lifecycle-authority"
              , "create"
              , "token"
              , account
              , "--audience"
              , "prodbox-authority-journal-read"
              , "--duration"
              , "600s"
              ]
          journalRead tokenText =
            capture
              "/usr/bin/kubectl"
              ( [ "--kubeconfig"
                , kubeconfig
                , "--request-timeout=60s"
                , "-n"
                , "lifecycle-authority"
                , "exec"
                , "-i"
                , "deploy/lifecycle-authority"
                , "--"
                , "/bin/bash"
                , "-c"
                , "read -r T; exec 3<>/dev/tcp/127.0.0.1/"
                    ++ show authorityJournalReadPort
                    ++ "; if [ -n \"$T\" ]; then printf 'GET /v1/journal/admission HTTP/1.0\\r\\nAuthorization: Bearer %s\\r\\n\\r\\n' \"$T\" >&3; else printf 'GET /v1/journal/admission HTTP/1.0\\r\\n\\r\\n' >&3; fi; cat <&3"
                ]
              )
              (ByteString8.pack (tokenText ++ "\n"))
          tokenOf result = case result of
            Right (0, out, _) -> filter (`notElem` ("\r\n " :: String)) out
            _ -> ""
          answered needle result = case result of
            Right (0, out, _) -> needle `isInfixOf` out
            _ -> False
      sealCycle <- public ["control", "backup"]
      sealedHealth <- vaultHealth
      readySealed <- readyzProbe
      statusSealed <- public ["control", "lifecycle-status"]
      deletionPlanSealed <- public ["plan", "delete"]
      reconcilePlanSealed <- public ["plan", "reconcile"]
      deleteSealed <- public ["delete", "--yes"]
      _ <- kubectl ["-n", "bootstrap-broker", "scale", "deploy/bootstrap-broker", "--replicas=0"]
      _ <-
        kubectl
          [ "-n"
          , "bootstrap-broker"
          , "wait"
          , "--for=delete"
          , "pod"
          , "-l"
          , "app.kubernetes.io/name=prodbox-bootstrap-broker"
          , "--timeout=90s"
          ]
      statusBrokerDown <- public ["control", "lifecycle-status"]
      _ <- kubectl ["-n", "bootstrap-broker", "scale", "deploy/bootstrap-broker", "--replicas=1"]
      _ <-
        kubectl ["-n", "bootstrap-broker", "rollout", "status", "deploy/bootstrap-broker", "--timeout=120s"]
      healthAfterDelete <- vaultHealth
      readerToken <- tokenOf <$> mintToken "prodbox-authority-reader"
      foreignToken <- tokenOf <$> mintToken "default"
      readerSealed <- journalRead readerToken
      foreignSealed <- journalRead foreignToken
      anonymousSealed <- journalRead ""
      restarted <-
        kubectl
          [ "-n"
          , "lifecycle-authority"
          , "delete"
          , "pod"
          , "-l"
          , "app.kubernetes.io/name=prodbox-lifecycle-authority"
          , "--wait=true"
          ]
      when (ok restarted) (threadDelay 25000000)
      restartedReady <- readyzProbe
      readerRestarted <- journalRead readerToken
      restartedLogs <-
        kubectl ["-n", "lifecycle-authority", "logs", "deploy/lifecycle-authority", "--tail=5"]
      restartedState <-
        kubectl
          [ "-n"
          , "lifecycle-authority"
          , "get"
          , "pods"
          , "-o"
          , "jsonpath={range .items[*]}{.status.containerStatuses[0].ready}{\";\"}{end}"
          ]
      unsealAgain <- publicWithInput ["control", "broker-unseal"] password
      recoveredReady <-
        if ok deployRun && ok unsealAgain
          then waitFor 40 readyzProbe
          else readyzProbe
      healthAfter <- vaultHealth
      case4Done0 <- getMonotonicTimeNSec
      -- Exact cleanup of the real Authority scope through its public command.
      removalOperation <- observeKindOwnerFamilyIntent projection
      cleanup3 <- public ["control", "delete", "--yes"]
      cleanupReplay <-
        if ok cleanup3
          then public ["control", "delete", "--yes"]
          else pure (Left "initial Authority-backed removal did not complete")
      absent3 <- independentAbsence (bootstrapRuntimeSocket projection) cluster
      retained3 <- independentHostData root generation (bootstrapNodeArtifact projection)
      fenceBytes <-
        try (ByteString.readFile (root </> "authority-journal-custody" </> "control-removal.json"))
          :: IO (Either IOException ByteString.ByteString)
      let fenceMatches = case (removalOperation, fenceBytes) of
            (KindIntentMatches operation, Right bytes) ->
              Aeson.decodeStrict bytes
                == Just
                  ( Aeson.object
                      [ "schema_version" .= (1 :: Int)
                      , "kind_name" .= cluster
                      , "root_generation" .= generation
                      , "kind_operation" .= operation
                      ]
                  )
            _ -> False
          settledCleanup =
            if ok cleanup3 && ok cleanupReplay && absent3 && retained3 && fenceMatches
              then CleanupConfirmed
              else CleanupFailed
      case3Done <- getMonotonicTimeNSec
      let case1 =
            scenarioReport
              (bindingFor 1 "never-admitted")
              (ScenarioTiming started case1Done case1Done)
              ( if (ok reconcile1 || ready1) && ok status1 && ok delete1 && ok delete2
                  then PrimarySucceeded
                  else PrimaryFailed
              )
              (if absent && retained then CleanupConfirmed else CleanupFailed)
              [ "never-admitted.status-truthful"
              , "never-admitted.status-writes-nothing"
              , "delete.twice-satisfied"
              , "delete.retains-root-identity"
              , "ordinary-delete.nothing-to-delete-twice-plane-retained"
              ]
              [ "never-admitted" `isInfixOf` textOf status1
              , ok status1
              , ok delete1 && ok delete2
              , ok delete2
              , "Nothing to delete" `isInfixOf` textOf ordinary1 && "Nothing to delete" `isInfixOf` textOf ordinary2
              ]
              [ ready1 && "never-admitted" `isInfixOf` textOf status1
              , authorityAbsentAfterStatus
              , absent
              , retained
              , ok ordinary1 && ok ordinary2 && readyAfterOrdinary && authorityAbsentAfterOrdinary
              ]
          case2 =
            scenarioReport
              (bindingFor 2 "journal")
              (ScenarioTiming case1Done case2Done case2Done)
              (if intent == Right () && settled == Right () then PrimarySucceeded else PrimaryFailed)
              (if fixtureRetired then CleanupConfirmed else CleanupFailed)
              [ "journal.unresolved-intent-is-pending"
              , "journal.settlement-allows-no-change"
              , "journal.missing-history-requires-recovery"
              , "journal.corrupt-record-requires-recovery"
              , "journal.later-record-is-seen"
              , "journal.unreadable-requires-recovery"
              , "journal.pending-blocks-delete"
              , "journal.unknown-blocks-delete"
              , "ordinary-delete.refused-while-pending"
              ]
              [ statusPending == AdmittedPending ["op-a"]
              , statusSettled == AdmittedSettled
              , statusMissing == RecoveryRequired RecoveryHistoryMissing
              , requiresRecovery statusCorrupt
              , statusLate == AdmittedPending ["op-b"]
              , requiresRecovery statusUnreadable
              , "Refused" `isInfixOf` textOf deletePending
              , "Refused" `isInfixOf` textOf deleteUnknown
              , "Refused" `isInfixOf` textOf ordinaryPending
              ]
              [ afterIntent == ["00000001-op-a.json"] && statusPending == AdmittedPending ["op-a"]
              , length afterSettle == 2 && markerPresent && statusSettled == AdmittedSettled
              , markerStill && statusMissing == RecoveryRequired RecoveryHistoryMissing
              , requiresRecovery statusCorrupt
              , statusLate == AdmittedPending ["op-b"]
              , requiresRecovery statusUnreadable && statusRestored == statusLate
              , failed offlineAuthority
                  && failed deletePending
                  && retainedPending
                  && afterIntent == ["00000001-op-a.json"]
              , failed deleteUnknown && retainedUnknown && markerStill
              , failed ordinaryPending && afterOrdinaryPending == afterIntent
              ]
      let case3 =
            scenarioReport
              (bindingFor 3 "authority")
              (ScenarioTiming case2Done case3Done case3Done)
              (if ok deployRun then PrimarySucceeded else PrimaryFailed)
              settledCleanup
              [ "authority.refuses-before-vault-init"
              , "authority.runs-with-one-ready-pod"
              , "authority.answers-own-readiness"
              , "authority.store-bucket-and-user-exist"
              , "authority.journal-mirror-initialized-on-retained-root"
              , "authority.public-status-asks-the-authority"
              , "authority.aggregate-status-and-delete-plan-use-the-fresh-journal"
              , "authority.missing-genesis-is-recovery-required-and-blocks-delete"
              , "authority.stale-host-projection-cannot-license-delete-or-control-removal"
              , "authority.control-removal-resumes-the-recorded-scope-without-the-api"
              , "control.concurrent-resume-preserves-the-original-control-identity"
              ]
              [ "NOT completed" `isInfixOf` textOf earlyDeploy
              , "authority-ready: ok" `isInfixOf` textOf deployRun
              , "authority-ready: ok" `isInfixOf` textOf deployRun
              , ok deployRun
              , ok deployRun
              , ok deployRun
              , ok aggregateStatus && ok deletionPlan
              , ok deployRun
              , ok deployRun
              , ok cleanup3 && ok cleanupReplay
              , fst operationEvidence
              ]
              [ failed earlyDeploy && ok initRun && ok unsealRun && ok baselineRun
              , case podReady of
                  Right (0, out, _) -> "true 0;" `isInfixOf` out && length (filter (== ';') out) == 1
                  _ -> False
              , case readyz of
                  Right (0, out, _) -> "200 OK" `isInfixOf` out && "ready" `isInfixOf` out
                  _ -> False
              , case storeObjects of
                  Right (0, out, _) -> maybe False (>= 2) (readMaybe out :: Maybe Int)
                  _ -> False
              , genesisSeen
                  && either (const False) (\bytes -> "\"operations\":[]" `isInfixOf` ByteString8.unpack bytes) mirrorText
              , ok statusViaAuthority
                  && "never-admitted" `isInfixOf` textOf statusViaAuthority
                  && "source: the Authority" `isInfixOf` textOf statusViaAuthority
                  && "read at 20" `isInfixOf` textOf statusViaAuthority
              , all (isInfixOf "Deletion decision: satisfied" . textOf) [aggregateStatus, deletionPlan]
                  && all (isInfixOf "source: the Authority" . textOf) [aggregateStatus, deletionPlan]
              , case genesisGap of
                  Just (statusNoGenesis, deleteNoGenesis, _, _) ->
                    failed statusNoGenesis
                      && "recovery-required" `isInfixOf` textOf statusNoGenesis
                      && failed deleteNoGenesis
                      && ok statusGenesisBack
                      && "never-admitted" `isInfixOf` textOf statusGenesisBack
                  Nothing -> False
              , staleRetired
                  && staleProjection == NeverAdmitted
                  && staleAfter == NeverAdmitted
                  && case genesisGap of
                    Just (statusNoGenesis, deleteNoGenesis, removeNoGenesis, live) ->
                      failed deleteNoGenesis
                        && failed removeNoGenesis
                        && live
                        && "source: the Authority" `isInfixOf` textOf statusNoGenesis
                        && "recovery-required" `isInfixOf` textOf statusNoGenesis
                    Nothing -> False
              , absent3 && retained3 && fenceMatches
              , snd operationEvidence
              ]
      let case4 =
            scenarioReport
              (bindingFor 4 "sealed-vault")
              (ScenarioTiming case2Done case4Done0 case3Done)
              ( if either (const False) (\(code, _, _) -> code == 0) healthAfter
                  then PrimarySucceeded
                  else PrimaryFailed
              )
              settledCleanup
              [ "sealed.vault-is-sealed"
              , "sealed.full-service-not-ready-while-sealed"
              , "sealed.restart-refused-while-sealed"
              , "sealed.recovers-after-unseal"
              , "sealed.narrow-read-answers-never-admitted"
              , "sealed.foreign-and-anonymous-callers-refused"
              , "sealed.restart-keeps-serving-the-read"
              , "sealed.public-status-asks-the-authority"
              , "sealed.ordinary-delete-nothing-to-delete-vault-stays-sealed"
              , "sealed.status-answers-with-the-broker-down"
              , "sealed.fresh-plan-answers-without-initializing-vault"
              ]
              [ ok sealCycle
              , True
              , True
              , ok unsealAgain
              , True
              , True
              , True
              , "source: the Authority" `isInfixOf` textOf statusSealed
              , "Nothing to delete" `isInfixOf` textOf deleteSealed
              , "source: the Authority" `isInfixOf` textOf statusBrokerDown
              , ok deletionPlanSealed
                  && "Deletion decision: satisfied" `isInfixOf` textOf deletionPlanSealed
                  && ok reconcilePlanSealed
                  && "Reconciliation decision: observe and continue retained control operation"
                    `isInfixOf` textOf reconcilePlanSealed
              ]
              [ either (const False) (\(_, out, _) -> sealedIn out) sealedHealth
              , not (readyzOk readySealed)
              , not (readyzOk restartedReady)
                  && either (const False) (\(_, out, err) -> "startup_refused" `isInfixOf` (out ++ err)) restartedLogs
                  && either (const False) (\(_, out, _) -> "false" `isInfixOf` out) restartedState
              , readyzOk recoveredReady && either (const False) (\(_, out, _) -> not (sealedIn out)) healthAfter
              , answered "200 OK" readerSealed && answered "never-admitted" readerSealed
              , answered "403" foreignSealed && answered "401" anonymousSealed
              , answered "200 OK" readerRestarted && answered "never-admitted" readerRestarted
              , ok statusSealed
                  && "never-admitted" `isInfixOf` textOf statusSealed
                  && either (const False) (\(_, out, _) -> sealedIn out) sealedHealth
              , ok deleteSealed && either (const False) (\(_, out, _) -> sealedIn out) healthAfterDelete
              , ok statusBrokerDown && "never-admitted" `isInfixOf` textOf statusBrokerDown
              , "source: the Authority" `isInfixOf` textOf deletionPlanSealed
                  && "source: the Authority" `isInfixOf` textOf reconcilePlanSealed
                  && either (const False) (\(_, out, _) -> sealedIn out) healthAfterDelete
              ]
      writeOutputLine ("authority pod state: " ++ show (fmap (\(_, out, _) -> out) podReady))
      writeOutputLine
        ( "authority bootstrap: replacement reconcile="
            ++ take 1200 (either id (\(_, out, err) -> out ++ err) reconcile2)
            ++ " | service failures="
            ++ failedSteps services2
            ++ " | Authority deployment failures="
            ++ failedSteps deployRun
            ++ " | missing-genesis fixture restored="
            ++ show (maybe False (const True) genesisGap)
            ++ " | sealed backup-cycle failures="
            ++ failedSteps sealCycle
        )
      reports <- mapM (publishScenario project) [case1, case2, case3, case4]
      writeOutputLine (unlines (map fst reports))
      registered <- case removalOperation of
        KindIntentMatches operation
          | all snd reports ->
              registerSettledTestRun projection operation (scenarioRunId (bindingFor 3 "authority"))
        _ -> pure False
      when (all snd reports && not registered) $
        writeOutputLine "The successful scenario did not register its exact test root for cleanup."
      pure (if registered then ExitSuccess else ExitFailure 1)
 where
  failedSteps =
    take 250
      . unwords
      . map (takeWhile (/= ':'))
      . filter (isInfixOf "NOT completed")
      . lines
      . either (const "") (\(_, out, err) -> out ++ err)

requiresRecovery :: AdmissionVerdict -> Bool
requiresRecovery (RecoveryRequired _) = True
requiresRecovery _ = False
