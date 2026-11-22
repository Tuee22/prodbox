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
import Control.Exception (IOException, try)
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
  )
import Prodbox.ControlPlane.ListenPort (authorityJournalReadPort, controlPlaneListenPort)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
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
import System.Posix.Files (setFileMode)

runPhase03Scenario :: FilePath -> IO ExitCode
runPhase03Scenario selected = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> scenario selected projection
 where
  refuse message = writeOutputLine ("phase-03 scenario refused: " ++ message) >> pure (ExitFailure 2)

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
  randomBytes <- readRandomBytes
  started <- getMonotonicTimeNSec
  case sourceResult of
    Left failure -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    Right source -> do
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
      ready1 <- independentClusterReady root cluster
      status1 <- public ["control", "lifecycle-status"]
      authorityAbsentAfterStatus <- not <$> doesDirectoryExist (root </> "authority")
      ordinary1 <- public ["delete", "--yes"]
      ordinary2 <- public ["delete", "--yes"]
      readyAfterOrdinary <- independentClusterReady root cluster
      authorityAbsentAfterOrdinary <- not <$> doesDirectoryExist (root </> "authority")
      delete1 <- public ["control", "delete", "--yes"]
      delete2 <- public ["control", "delete", "--yes"]
      absent <- independentAbsence cluster
      retained <- independentHostData root generation (bootstrapNodeArtifact projection)
      case1Done <- getMonotonicTimeNSec
      -- Case 2: a durable journal, read directly, drives the verdict.
      intent <- appendIntent root "op-a"
      statusPending <- public ["control", "lifecycle-status"]
      afterIntent <- listJournal
      deletePending <- public ["control", "delete", "--yes"]
      retainedPending <- independentHostData root generation (bootstrapNodeArtifact projection)
      ordinaryPending <- public ["delete", "--yes"]
      afterOrdinaryPending <- listJournal
      settled <- appendSettlement root "op-a"
      statusSettled <- public ["control", "lifecycle-status"]
      afterSettle <- listJournal
      markerPresent <- doesFileExist (historyMarkerPath root)
      renameDirectory journal (journal ++ ".away")
      statusMissing <- public ["control", "lifecycle-status"]
      markerStill <- doesFileExist (historyMarkerPath root)
      deleteUnknown <- public ["control", "delete", "--yes"]
      retainedUnknown <- independentHostData root generation (bootstrapNodeArtifact projection)
      renameDirectory (journal ++ ".away") journal
      ByteString8.writeFile (journal </> "00000050-bad.json") "not a record"
      statusCorrupt <- public ["control", "lifecycle-status"]
      ByteString8.writeFile
        (journal </> "00000050-bad.json")
        "{\"schema_version\":1,\"operation\":\"op-b\",\"state\":\"unresolved\"}"
      statusLate <- public ["control", "lifecycle-status"]
      setFileMode journal 0o000
      statusUnreadable <- public ["control", "lifecycle-status"]
      setFileMode journal 0o700
      statusRestored <- public ["control", "lifecycle-status"]
      case2Done <- getMonotonicTimeNSec
      -- Case 3: the Authority runtime on kind. The adverse control comes first:
      -- before Vault is initialized the deployment must not report success.
      _ <- public ["control", "reconcile"]
      _ <- public ["control", "services"]
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
      -- A journal the Authority cannot positively identify (its genesis record is
      -- missing) is recovery-required through the Authority, and blocks deletion.
      renameFile
        (root </> "authority-journal" </> "genesis.json")
        (root </> "authority-journal" </> "genesis.json.away")
      statusNoGenesis <- public ["control", "lifecycle-status"]
      deleteNoGenesis <- public ["delete", "--yes"]
      renameFile
        (root </> "authority-journal" </> "genesis.json.away")
        (root </> "authority-journal" </> "genesis.json")
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
      _ <- kubectl ["-n", "prodbox-management", "delete", "pod", "vault", "--wait=true"]
      _ <- public ["control", "services"]
      sealedHealth <- vaultHealth
      readySealed <- readyzProbe
      statusSealed <- public ["control", "lifecycle-status"]
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
      _ <-
        kubectl
          [ "-n"
          , "lifecycle-authority"
          , "delete"
          , "pod"
          , "-l"
          , "app.kubernetes.io/name=prodbox-lifecycle-authority"
          , "--wait=true"
          ]
      threadDelay 25000000
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
      recoveredReady <- waitFor 40 readyzProbe
      healthAfter <- vaultHealth
      case4Done0 <- getMonotonicTimeNSec
      -- Exact cleanup of this scenario's own state: settle the journal record the
      -- harness left unresolved, delete through the public command and observe.
      _ <- appendSettlement root "op-b"
      cleanup3 <- public ["control", "delete", "--yes"]
      absent3 <- independentAbsence cluster
      retained3 <- independentHostData root generation (bootstrapNodeArtifact projection)
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
              CleanupConfirmed
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
              [ "admitted-pending" `isInfixOf` textOf statusPending
              , "admitted-settled" `isInfixOf` textOf statusSettled
              , "journal is missing although history existed" `isInfixOf` textOf statusMissing
              , "recovery-required" `isInfixOf` textOf statusCorrupt
              , "admitted-pending" `isInfixOf` textOf statusLate
              , "recovery-required" `isInfixOf` textOf statusUnreadable
              , "Refused" `isInfixOf` textOf deletePending
              , "Refused" `isInfixOf` textOf deleteUnknown
              , "Refused" `isInfixOf` textOf ordinaryPending
              ]
              [ afterIntent == ["00000001-op-a.json"] && ok statusPending
              , length afterSettle == 2 && markerPresent && ok statusSettled
              , markerStill && failed statusMissing
              , failed statusCorrupt
              , ok statusLate
              , failed statusUnreadable && ok statusRestored
              , failed deletePending && retainedPending && afterIntent == ["00000001-op-a.json"]
              , failed deleteUnknown && retainedUnknown && markerStill
              , failed ordinaryPending && afterOrdinaryPending == afterIntent
              ]
      let case3 =
            scenarioReport
              (bindingFor 3 "authority")
              (ScenarioTiming case2Done case3Done case3Done)
              (if ok deployRun then PrimarySucceeded else PrimaryFailed)
              (if ok cleanup3 && absent3 && retained3 then CleanupConfirmed else CleanupFailed)
              [ "authority.refuses-before-vault-init"
              , "authority.runs-with-one-ready-pod"
              , "authority.answers-own-readiness"
              , "authority.store-bucket-and-user-exist"
              , "authority.journal-mirror-initialized-on-retained-root"
              , "authority.public-status-asks-the-authority"
              , "authority.missing-genesis-is-recovery-required-and-blocks-delete"
              ]
              [ "NOT completed" `isInfixOf` textOf earlyDeploy
              , "authority-ready: ok" `isInfixOf` textOf deployRun
              , "authority-ready: ok" `isInfixOf` textOf deployRun
              , ok deployRun
              , ok deployRun
              , ok deployRun
              , ok deployRun
              ]
              [ failed earlyDeploy && ok initRun && ok unsealRun && ok baselineRun
              , case podReady of
                  Right (0, out, _) -> "true 0;" `isInfixOf` out && length (filter (== ';') out) == 1
                  _ -> False
              , case readyz of
                  Right (0, out, _) -> "200 OK" `isInfixOf` out && "ready" `isInfixOf` out
                  _ -> False
              , case storeObjects of
                  Right (0, out, _) -> (read (filter (`elem` ("0123456789" :: String)) out) :: Int) >= 2
                  _ -> False
              , genesisSeen
                  && either (const False) (\bytes -> "\"operations\":[]" `isInfixOf` ByteString8.unpack bytes) mirrorText
              , ok statusViaAuthority
                  && "never-admitted" `isInfixOf` textOf statusViaAuthority
                  && "source: the Authority" `isInfixOf` textOf statusViaAuthority
                  && "read at 20" `isInfixOf` textOf statusViaAuthority
              , failed statusNoGenesis
                  && "recovery-required" `isInfixOf` textOf statusNoGenesis
                  && failed deleteNoGenesis
                  && ok statusGenesisBack
                  && "never-admitted" `isInfixOf` textOf statusGenesisBack
              ]
      let case4 =
            scenarioReport
              (bindingFor 4 "sealed-vault")
              (ScenarioTiming case2Done case4Done0 case4Done0)
              ( if either (const False) (\(code, _, _) -> code == 0) healthAfter
                  then PrimarySucceeded
                  else PrimaryFailed
              )
              CleanupConfirmed
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
              ]
              [ ok unsealAgain
              , True
              , True
              , ok unsealAgain
              , True
              , True
              , True
              , "source: the Authority" `isInfixOf` textOf statusSealed
              , "Nothing to delete" `isInfixOf` textOf deleteSealed
              , "source: the Authority" `isInfixOf` textOf statusBrokerDown
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
              ]
      writeOutputLine ("authority pod state: " ++ show (fmap (\(_, out, _) -> out) podReady))
      reports <- mapM (publishScenario project) [case1, case2, case3, case4]
      writeOutputLine (unlines (map fst reports))
      pure (if all snd reports then ExitSuccess else ExitFailure 1)
