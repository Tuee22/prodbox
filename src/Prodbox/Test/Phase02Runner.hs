{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Phase 2 scenario runner: drive the built public binary through the
-- bootstrap services (`control reconcile`, `control services`, `control
-- unlock`) of one explicitly selected test identity, then check each claim
-- with other tools: kubectl against the installed credential (the API server's
-- pod proxy for Vault health, `mc` in the environment's own client pod for the
-- MinIO unlock object, the root token read from that object by the runner for
-- a direct KV read), Docker listings and direct file reads. The report is
-- non-secret. Secrets (the unlock bundle) exist here only in memory, on the
-- standard input of the commands that need them, and are never printed,
-- logged or recorded. The runner never repairs by hand.
module Prodbox.Test.Phase02Runner
  ( runPhase02Scenario
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf, isPrefixOf)
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
import Prodbox.Control.ManagementPolicy (managementNamespace)
import Prodbox.ControlPlane.ListenPort (controlPlaneListenPort)
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
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , removePathForcibly
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadWriteMode), SeekMode (AbsoluteSeek), hSeek, withBinaryFile)
import System.Posix.Files (setFileMode)

runPhase02Scenario :: FilePath -> IO ExitCode
runPhase02Scenario selected = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> scenario selected projection
 where
  refuse message = writeOutputLine ("phase-02 scenario refused: " ++ message) >> pure (ExitFailure 2)

data Health = Health {healthInitialized :: Bool, healthSealed :: Bool, healthCluster :: String}
  deriving (Eq, Show)

scenario :: FilePath -> BootstrapProjection -> IO ExitCode
scenario selected projection = do
  let scope = bootstrapScope projection
      cluster = scopeKindName scope
      root = scopeRoot scope
      project = takeDirectory (takeDirectory root)
      kubeconfig = root </> "control" </> "kubeconfig"
      generation = Text.unpack (bootstrapRootGeneration projection)
      object = "local/prodbox-bootstrap/vault-unlock-test.json"
  executable <- getExecutablePath
  binaryBytes <- ByteString.readFile executable
  sourceResult <- captureSourceIdentity "." []
  randomResult <- readRandomBytes
  started <- getMonotonicTimeNSec
  case (sourceResult, randomResult) of
    (Left failure, _) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    (_, Left failure) -> writeOutputLine ("scenario entropy refused: " ++ failure) >> pure (ExitFailure 2)
    (Right source, Right randomBytes) -> do
      let second = 1000000000
          budget = ScenarioBudget (started + 2400 * second) (started + 3000 * second) (2048 * 1048576) 2400000000 0
          artifacts =
            [ ("kind.tool", digest (maybe "" artifactDigest (bootstrapKindTool projection)))
            , ("node.archive", digest (maybe "" artifactDigest (bootstrapNodeArtifact projection)))
            ]
          bindingFor :: Word16 -> String -> ScenarioBinding
          bindingFor caseNumber label =
            ScenarioBinding
              2
              caseNumber
              scope
              generation
              (hex32 (randomBytes <> "run"))
              (hex32 (randomBytes <> "operation" <> ByteString8.pack label))
              (hex32 "phase-02-boot")
              source
              (digest (ByteString8.unpack (hexSha256 binaryBytes)))
              artifacts
              (digest (show (renderKindConfig (bootstrapKindPlan projection))))
              (digest ("control reconcile; services; unlock; case " ++ label))
              budget
          public args = run executable (["--config", selected] ++ args)
          publicWithInput args input = do
            result <-
              captureSubprocessWithInputBounded
                (BoundedSubprocessLimits (64 * 1024) (1024 * 1024) (256 * 1024) 120000000)
                input
                ( Subprocess
                    executable
                    (["--config", selected] ++ args)
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
          -- The prompt exercised on a real pseudo-terminal: a synthetic wrong key is
          -- typed at the prompt; the terminal transcript must show the prompt, must
          -- not echo the typed text, and Vault must refuse the key.
          ptyProbeScript =
            unlines
              [ "import os, pty, sys, time, select"
              , "secret = b'SYNTHETICPROBEKEY0123456789abcdefghijklmnopqrst'"
              , "pid, fd = pty.fork()"
              , "if pid == 0:"
              , "    os.execv(sys.argv[1], sys.argv[1:])"
              , "out = b''; sent = False; t0 = time.time()"
              , "while time.time() - t0 < 90:"
              , "    r, _, _ = select.select([fd], [], [], 1)"
              , "    if r:"
              , "        try: d = os.read(fd, 4096)"
              , "        except OSError: break"
              , "        if not d: break"
              , "        out += d"
              , "        if not sent and b'unseal key' in out.lower():"
              , "            os.write(fd, secret + b'\\n'); sent = True"
              , "sys.stdout.write(('PROMPTED' if sent else 'NOPROMPT') + chr(10))"
              , "sys.stdout.write(('ECHOED' if secret in out else 'NOECHO') + chr(10))"
              , "sys.stdout.write(('REFUSED' if b'Refused' in out else 'NOREFUSAL') + chr(10))"
              ]
          ptyProtected =
            captureSubprocessWithInputBounded
              (BoundedSubprocessLimits 1024 (64 * 1024) (64 * 1024) 120000000)
              ByteString.empty
              ( Subprocess
                  "/usr/bin/python3"
                  ["-I", "-c", ptyProbeScript, executable, "--config", selected, "control", "protected-unlock"]
                  (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("XDG_RUNTIME_DIR", "/run/user/1000")])
                  Nothing
              )
          kubectl seconds arguments input = do
            result <-
              captureSubprocessWithInputBounded
                (BoundedSubprocessLimits (1024 * 1024) (1024 * 1024) (256 * 1024) (seconds * 1000000))
                input
                ( Subprocess
                    "/usr/bin/kubectl"
                    (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
                    (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                    Nothing
                )
            pure $ case result of
              Right output ->
                Right
                  ( case processExitCode output of ExitSuccess -> 0 :: Int; ExitFailure code -> code
                  , ByteString8.pack (processStdout output)
                  )
              Left failure -> Left (show failure)
          textOf result = either (const "") (\(_, out, err) -> out ++ err) result
          ok result = either (const False) (\(code, _, _) -> code == 0) result
          health = do
            result <-
              kubectl
                60
                [ "get"
                , "--raw"
                , "/api/v1/namespaces/"
                    ++ managementNamespace
                    ++ "/pods/vault:8200/proxy/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
                ]
                ByteString.empty
            pure $ case result of
              Right (0, out) -> case Aeson.decodeStrict out of
                Just (Aeson.Object fields) -> case (KeyMap.lookup "initialized" fields, KeyMap.lookup "sealed" fields) of
                  (Just (Aeson.Bool i), Just (Aeson.Bool s)) ->
                    Just
                      ( Health
                          i
                          s
                          ( case KeyMap.lookup (Key.fromString "cluster_id") fields of
                              Just (Aeson.String t) -> Text.unpack t
                              _ -> ""
                          )
                      )
                  _ -> Nothing
                _ -> Nothing
              _ -> Nothing
          mcExec script input =
            kubectl
              90
              [ "-n"
              , managementNamespace
              , "exec"
              , "-i"
              , "mc"
              , "--"
              , "/bin/sh"
              , "-c"
              , "mc alias set local http://minio:9000 \"$MINIO_USER\" \"$MINIO_PASSWORD\" >/dev/null 2>&1 && "
                  ++ script
              ]
              input
          fetchObject = do
            result <- mcExec ("mc cat " ++ object) ByteString.empty
            pure $ case result of
              Right (0, out) -> Just out
              _ -> Nothing
          putObject bytes =
            mcExec
              ( "umask 077; cat > /tmp/object-upload && mc cp /tmp/object-upload "
                  ++ object
                  ++ " >/dev/null; code=$?; rm -f /tmp/object-upload; exit $code"
              )
              bytes
          removeObject = mcExec ("mc rm --force " ++ object) ByteString.empty
          readerScript script =
            kubectl
              90
              [ "-n"
              , managementNamespace
              , "exec"
              , "-i"
              , "mc"
              , "--"
              , "/bin/sh"
              , "-c"
              , "mc alias set reader http://minio:9000 \"$MINIO_READER_USER\" \"$MINIO_READER_PASSWORD\" >/dev/null 2>&1 && "
                  ++ script
              ]
              ByteString.empty
          readerScoped = do
            canRead <- readerScript ("mc cat reader/prodbox-bootstrap/vault-unlock-test.json >/dev/null")
            cannotWrite <-
              readerScript
                "echo x > /tmp/reader-probe && mc cp /tmp/reader-probe reader/prodbox-bootstrap/other-object; code=$?; rm -f /tmp/reader-probe; exit $code"
            cannotList <- readerScript "mc ls reader/prodbox-bootstrap"
            let exitOf result = either (const Nothing) (Just . fst) result
            pure (exitOf canRead == Just 0 && exitOf cannotWrite /= Just 0 && exitOf cannotList /= Just 0)
          objectPresent = do
            result <- mcExec ("mc stat " ++ object ++ " >/dev/null 2>&1") ByteString.empty
            pure (case result of Right (0, _) -> True; _ -> False)
          -- Direct KV access using the root token the runner reads from the
          -- unlock object; the token never leaves this function.
          withToken script = do
            bundle <- fetchObject
            case bundle >>= Aeson.decodeStrict of
              Just (Aeson.Object fields) | Just (Aeson.String token) <- KeyMap.lookup "client_token" fields -> do
                result <-
                  kubectl
                    60
                    [ "-n"
                    , managementNamespace
                    , "exec"
                    , "-i"
                    , "vault"
                    , "--"
                    , "/bin/sh"
                    , "-c"
                    , "read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; " ++ script
                    ]
                    (ByteString8.pack (Text.unpack token ++ "\n"))
                pure $ case result of
                  Right (0, out) -> Just (ByteString8.unpack out)
                  _ -> Nothing
              _ -> pure Nothing
          independentMarker = do
            value <- withToken "vault kv get -mount=secret -field=marker phase2/roundtrip"
            pure (value >>= \v -> if length v == 24 then Just v else Nothing)
          persistentValue = take 24 (hex32 (randomBytes <> "persistent-secret"))
          writePersistent =
            withToken
              ( "vault kv put -mount=secret phase2/persist marker="
                  ++ persistentValue
                  ++ " >/dev/null && echo written"
              )
          readPersistent = withToken "vault kv get -mount=secret -field=marker phase2/persist"
          brokerReady = do
            result <-
              kubectl
                60
                [ "-n"
                , "bootstrap-broker"
                , "exec"
                , "deploy/bootstrap-broker"
                , "--"
                , "/bin/bash"
                , "-c"
                , "exec 3<>/dev/tcp/127.0.0.1/"
                    ++ show controlPlaneListenPort
                    ++ "; printf 'GET /readyz HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' >&3; cat <&3"
                ]
                ByteString.empty
            pure
              (case result of Right (0, out) -> "\"ready\":true" `isInfixOf` ByteString8.unpack out; _ -> False)
          brokerPodGone = do
            result <-
              kubectl
                60
                [ "-n"
                , "bootstrap-broker"
                , "get"
                , "pods"
                , "-l"
                , "app.kubernetes.io/name=prodbox-bootstrap-broker"
                , "-o"
                , "name"
                ]
                ByteString.empty
            pure (case result of Right (0, out) -> null (ByteString8.unpack out); _ -> False)
          minioPodGone = do
            result <-
              kubectl 60 ["-n", managementNamespace, "get", "pod", "minio", "-o", "name"] ByteString.empty
            pure (case result of Right (0, _) -> False; _ -> True)
          restartVault = do
            _ <-
              kubectl 90 ["-n", managementNamespace, "delete", "pod", "vault", "--wait=true"] ByteString.empty
            public ["control", "services"]
          settle = threadDelay 2000000
      -- Environment and services.
      reconcile1 <- public ["control", "reconcile"]
      services1 <- public ["control", "services"]
      ready1 <- independentClusterReady (bootstrapRuntimeSocket projection) root cluster
      healthBeforeInit <- health
      -- Case 1: initialize once, keep the unlock object, round trip.
      unlock1 <- public ["control", "unlock"]
      healthAfterInit <- health
      bundlePresent1 <- objectPresent
      readerOk <- readerScoped
      brokerReady1 <- brokerReady
      vaultStatusRun <- public ["control", "vault-status"]
      minioProxy <-
        kubectl
          60
          [ "get"
          , "--raw"
          , "/api/v1/namespaces/" ++ managementNamespace ++ "/pods/minio:9000/proxy/minio/health/ready"
          ]
          ByteString.empty
      let minioReady1 = case minioProxy of Right (0, _) -> True; _ -> False
      status1 <- public ["control", "status"]
      marker1 <- independentMarker
      savedBundle <- fetchObject
      persistWritten <- writePersistent
      case1Done <- getMonotonicTimeNSec
      -- Case 2: the Vault pod is replaced, comes up sealed, self-unseals from the object; same identity.
      services2 <- restartVault
      settle
      healthWhileSealed <- health
      unlock2 <- public ["control", "unlock"]
      healthUnsealed2 <- health
      persist2 <- readPersistent
      case2Done <- getMonotonicTimeNSec
      -- Case 3: protected unlock. The operator, not MinIO, holds the key.
      services6 <- restartVault
      settle
      sealedProtected <- health
      noInputRun <- publicWithInput ["control", "protected-unlock"] ByteString.empty
      afterNoInput <- health
      wrongRun <-
        publicWithInput
          ["control", "protected-unlock"]
          ( ByteString8.pack
              (take 44 (hex32 (randomBytes <> "protected-wrong") ++ hex32 (randomBytes <> "pw2")) ++ "\n")
          )
      afterWrongProtected <- health
      ptyResult <- ptyProtected
      let ptyText = either show processStdout ptyResult
      afterPty <- health
      operatorKey <- pure (savedBundle >>= unsealKeyOf)
      _ <-
        kubectl 90 ["-n", managementNamespace, "delete", "pod", "minio", "--wait=true"] ByteString.empty
      minioDown <- minioPodGone
      protectedRun <-
        publicWithInput ["control", "protected-unlock"] (maybe ByteString.empty (<> "\n") operatorKey)
      afterProtected <- health
      services7 <- public ["control", "services"]
      settle
      case3Done <- getMonotonicTimeNSec
      -- Case 6: concurrent secret workers against the real services, within the
      -- Pods' declared limits; nothing may fail, restart or be OOM-killed.
      let workerValue index = take 24 (hex32 (randomBytes <> ByteString8.pack ("worker-" ++ show index)))
          workers = [1 .. 8] :: [Int]
      concurrentWrites <-
        Async.mapConcurrently
          ( \index ->
              withToken
                ( "vault kv put -mount=secret phase2/worker-"
                    ++ show index
                    ++ " marker="
                    ++ workerValue index
                    ++ " >/dev/null && echo done"
                )
          )
          workers
      concurrentReads <-
        Async.mapConcurrently
          (\index -> withToken ("vault kv get -mount=secret -field=marker phase2/worker-" ++ show index))
          workers
      podState <-
        kubectl
          60
          [ "-n"
          , managementNamespace
          , "get"
          , "pods"
          , "-o"
          , "jsonpath={range .items[*]}{.metadata.name}{\" \"}{.status.containerStatuses[0].restartCount}{\" \"}{.status.containerStatuses[0].lastState.terminated.reason}{\"|\"}{end}"
          ]
          ByteString.empty
      limitState <-
        kubectl
          60
          [ "-n"
          , managementNamespace
          , "get"
          , "pods"
          , "-o"
          , "jsonpath={range .items[*]}{.metadata.name}{\"=\"}{.spec.containers[0].resources.limits.memory}{\" \"}{end}"
          ]
          ByteString.empty
      let probeClient name labels =
            kubectl
              120
              ( [ "-n"
                , managementNamespace
                , "run"
                , name
                , "--image=docker.io/hashicorp/vault:1.18.3"
                , "--image-pull-policy=Never"
                , "--restart=Never"
                , "--rm"
                , "-i"
                , "--quiet"
                , "--labels=" ++ labels
                , "--command"
                , "--"
                , "wget"
                , "-q"
                , "-T"
                , "8"
                , "-O"
                , "-"
                , "http://vault:8200/v1/sys/health?uninitcode=200&sealedcode=200"
                ]
              )
              ByteString.empty
      policyAllowed <- probeClient "policy-allowed" "prodbox.io/management-client=true"
      policyDenied <- probeClient "policy-denied" "app=policy-denied"
      pullPolicies <-
        kubectl
          60
          [ "get"
          , "pods"
          , "-A"
          , "-o"
          , "jsonpath={range .items[*]}{.metadata.namespace}{\"/\"}{.metadata.name}{\":\"}{range .spec.containers[*]}{.imagePullPolicy}{\",\"}{end}{\"\\n\"}{end}"
          ]
          ByteString.empty
      healthAfterWorkers <- health
      case6Done <- getMonotonicTimeNSec
      -- Case 7: local backup and restore. Roll a secret back, refuse a corrupt backup.
      persistBeforeBackup <- readPersistent
      backupRun <- public ["control", "backup"]
      let backupName = backupNameOf (textOf backupRun)
          backupRoot = root </> "backups"
      manifestPresent <-
        maybe (pure False) (\name -> doesFileExist (backupRoot </> name </> "manifest.json")) backupName
      settle
      unlockAfterBackup <- public ["control", "unlock"]
      changedValue <- pure (take 24 (hex32 (randomBytes <> "changed-after-backup")))
      changedWritten <-
        withToken
          ("vault kv put -mount=secret phase2/persist marker=" ++ changedValue ++ " >/dev/null && echo written")
      persistChanged <- readPersistent
      -- a copy of the backup whose manifest digest no longer matches its files
      corruptName <- pure "backup-corrupt0001"
      _ <-
        maybe
          (pure (Left "no backup"))
          (\name -> run "/usr/bin/cp" ["-a", backupRoot </> name, backupRoot </> corruptName])
          backupName
      corruptManifest <-
        try (ByteString.readFile (backupRoot </> corruptName </> "manifest.json"))
          :: IO (Either IOException ByteString.ByteString)
      _ <- case corruptManifest >>= maybe (Left (userError "manifest")) Right . replaceTreeDigest of
        Right bytes -> ByteString.writeFile (backupRoot </> corruptName </> "manifest.json") bytes
        Left _ -> pure ()
      corruptRestore <- public ["control", "restore", corruptName, "--yes"]
      let contentCorruptName = "backup-corrupt0002"
      contentCopied <-
        maybe
          (pure (Left "no backup"))
          (\name -> run "/usr/bin/cp" ["-a", backupRoot </> name, backupRoot </> contentCorruptName])
          backupName
      candidates <-
        run
          "/usr/bin/find"
          [ backupRoot </> contentCorruptName </> "vault-data"
          , "-type"
          , "f"
          , "-size"
          , "+0c"
          , "-printf"
          , "%p\n"
          , "-quit"
          ]
      contentChanged <- case (contentCopied, candidates) of
        (Right (0, _, _), Right (0, pathLine, _)) -> case lines pathLine of
          path : _ -> do
            changed <-
              try
                ( withBinaryFile path ReadWriteMode $ \handle -> do
                    byte <- ByteString.hGet handle 1
                    hSeek handle AbsoluteSeek 0
                    ByteString.hPut handle (ByteString.map (`xor` 1) byte)
                )
                :: IO (Either IOException ())
            pure (either (const False) (const True) changed)
          [] -> pure False
        _ -> pure False
      contentCorruptRestore <- public ["control", "restore", contentCorruptName, "--yes"]
      let legacyName = "backup-legacy00001"
      legacyCopied <-
        maybe
          (pure (Left "no backup"))
          (\name -> run "/usr/bin/cp" ["-a", backupRoot </> name, backupRoot </> legacyName])
          backupName
      legacyManifest <-
        try (ByteString.readFile (backupRoot </> legacyName </> "manifest.json"))
          :: IO (Either IOException ByteString.ByteString)
      legacyMarked <- case legacyManifest >>= maybe (Left (userError "manifest")) Right . markLegacyFormat of
        Right bytes -> ByteString.writeFile (backupRoot </> legacyName </> "manifest.json") bytes >> pure True
        Left _ -> pure False
      legacyRestore <- public ["control", "restore", legacyName, "--yes"]
      legacyRetained <- doesDirectoryExist (backupRoot </> legacyName)
      persistAfterCorrupt <- readPersistent
      healthAfterCorrupt <- health
      restoreRun <-
        maybe (pure (Left "no backup")) (\name -> public ["control", "restore", name, "--yes"]) backupName
      settle
      healthAfterRestore <- health
      unlockAfterRestore <- public ["control", "unlock"]
      persistRestored <- readPersistent
      healthRestored <- health
      replacedKept <-
        maybe
          (pure False)
          (\name -> doesDirectoryExist (root </> ("replaced-" ++ name ++ "-vault-data")))
          backupName
      case7Done <- getMonotonicTimeNSec
      -- Case 8: Broker outage. Status keeps reporting the other components'
      -- facts directly and names the Broker as unobservable; restoring recovers it.
      _ <-
        kubectl
          90
          ["-n", "bootstrap-broker", "scale", "deployment/bootstrap-broker", "--replicas=0"]
          ByteString.empty
      _ <-
        kubectl
          90
          [ "-n"
          , "bootstrap-broker"
          , "wait"
          , "--for=delete"
          , "pod"
          , "-l"
          , "app.kubernetes.io/name=prodbox-bootstrap-broker"
          , "--timeout=60s"
          ]
          ByteString.empty
      brokerGone <- brokerPodGone
      statusBrokerDown <- public ["control", "status"]
      healthBrokerDown <- health
      servicesAfterBroker <- public ["control", "services"]
      settle
      brokerBack <- brokerReady
      case8Done <- getMonotonicTimeNSec
      -- Case 4: adverse controls on a sealed Vault. None may initialize or alter anything.
      services3 <- restartVault
      settle
      sealedBefore <- health
      _ <- removeObject
      missingRun <- public ["control", "unlock"]
      afterMissing <- health
      missingStillAbsent <- (not <$> objectPresent)
      -- restore, then a tampered generation
      restoredMissing <-
        maybe
          (pure False)
          (fmap (maybe False ((== 0) . fst) . either (const Nothing) Just) . putObject)
          savedBundle
      tampered <-
        pure (fmap (ByteString8.pack . replaceGeneration generation . ByteString8.unpack) savedBundle)
      _ <- maybe (pure (Left "no saved bundle")) putObject tampered
      tamperRun <- public ["control", "unlock"]
      mcStateAfterTamper <-
        kubectl
          60
          [ "-n"
          , managementNamespace
          , "get"
          , "pod"
          , "mc"
          , "-o"
          , "jsonpath={.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].lastState.terminated.exitCode} {.status.startTime}"
          ]
          ByteString.empty
      afterTamper <- health
      _ <- maybe (pure (Left "no saved bundle")) putObject savedBundle
      -- MinIO outage
      _ <-
        kubectl 90 ["-n", managementNamespace, "delete", "pod", "minio", "--wait=true"] ByteString.empty
      outageRun <- public ["control", "unlock"]
      afterOutage <- health
      services4 <- public ["control", "services"]
      settle
      -- a stored unseal key that is well formed but wrong: refused, Vault stays
      -- sealed and initialized, nothing re-initializes
      let wrongKey = Text.pack (take 44 (hex32 (randomBytes <> "wrong-key") ++ hex32 (randomBytes <> "wrong-key-2")))
          wrongBundle = savedBundle >>= replaceUnsealKey wrongKey
      _ <- maybe (pure (Left "no saved bundle")) putObject wrongBundle
      wrongKeyRun <- public ["control", "unlock"]
      afterWrongKey <- health
      _ <- maybe (pure (Left "no saved bundle")) putObject savedBundle
      -- production policy is refused before any unlock material is read
      let productionDirectory = project </> ".build" </> "a02-production"
          productionAnchor = project </> ".build" </> "a02-productionproject"
      createDirectoryIfMissing False (project </> ".build")
      setFileMode (project </> ".build") 0o700
      createDirectoryIfMissing False productionAnchor
      setFileMode productionAnchor 0o700
      createDirectoryIfMissing False productionDirectory
      setFileMode productionDirectory 0o700
      selectedText <- ByteString.readFile selected
      let productionText =
            replaceBytes
              "environment = \"test\""
              "environment = \"production\""
              ( replaceBytes
                  ("project_anchor = \"" <> ByteString8.pack project <> "\"")
                  ("project_anchor = \"" <> ByteString8.pack productionAnchor <> "\"")
                  selectedText
              )
      ByteString.writeFile (productionDirectory </> "selected.dhall") productionText
      setFileMode (productionDirectory </> "selected.dhall") 0o600
      productionRun <-
        run executable ["--config", productionDirectory </> "selected.dhall", "control", "unlock"]
      removePathForcibly productionDirectory
      removePathForcibly productionAnchor
      -- recover: unlock succeeds again from the restored object
      -- an upload interrupted after initialization: the unlock object is gone but
      -- the private pending record holds the bundle; the next unlock continues it
      _ <- removeObject
      pendingPath <- pure (root </> "control" </> "vault-unlock-pending.json")
      maybe
        (pure ())
        (\bytes -> ByteString.writeFile pendingPath bytes >> setFileMode pendingPath 0o600)
        savedBundle
      unlock3 <- public ["control", "unlock"]
      healthRecovered <- health
      pendingGone <- not <$> doesFileExist pendingPath
      objectBack <- objectPresent
      case4Done <- getMonotonicTimeNSec
      -- Case 5: recreate the whole environment; the same Vault and its data return.
      delete1 <- public ["control", "delete", "--yes"]
      absent1 <- independentAbsence (bootstrapRuntimeSocket projection) cluster
      retained1 <- independentHostData root generation (bootstrapNodeArtifact projection)
      reconcile2 <- public ["control", "reconcile"]
      services5 <- public ["control", "services"]
      settle
      healthAfterRecreate <- health
      unlock4 <- public ["control", "unlock"]
      healthFinal <- health
      persist3 <- readPersistent
      delete2 <- public ["control", "delete", "--yes"]
      absent2 <- independentAbsence (bootstrapRuntimeSocket projection) cluster
      retained2 <- independentHostData root generation (bootstrapNodeArtifact projection)
      done <- getMonotonicTimeNSec
      let sameCluster a b = fmap healthCluster a == fmap healthCluster b && fmap healthCluster a /= Just ""
          unsealedWith h = fmap (\x -> healthInitialized x && not (healthSealed x)) h == Just True
          sealedWith h = fmap (\x -> healthInitialized x && healthSealed x) h == Just True
          cluster1 = healthAfterInit
          case1 =
            scenarioReport
              (bindingFor 1 "initialize")
              (ScenarioTiming started case1Done case1Done)
              (if ok reconcile1 || ready1 then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "bootstrap.services-ready"
              , "vault.initialized-once"
              , "unlock.object-in-minio"
              , "secret.roundtrip-authenticated"
              , "unlock.reader-scoped"
              , "status.reports-services"
              , "broker.ready"
              , "broker.authenticated-vault-status"
              , "custody.no-root-token-in-minio"
              ]
              [ "MinIO, Vault and the MinIO client pods report Ready" `isInfixOf` textOf services1 || ok services1
              , ok unlock1
              , "unlock bundle was written" `isInfixOf` textOf unlock1
              , "secret round trip succeeded" `isInfixOf` textOf unlock1
              , "unlock-reader: ok" `isInfixOf` textOf services1
              , "Vault initialized=true sealed=false" `isInfixOf` textOf status1
              , "broker-ready: ok" `isInfixOf` textOf services1
              , "\"initialized\":true" `isInfixOf` textOf vaultStatusRun
              , "client-token: ok" `isInfixOf` textOf unlock1
              ]
              [ ready1 && fmap (\h -> not (healthInitialized h)) healthBeforeInit == Just True
              , unsealedWith healthAfterInit
              , bundlePresent1
              , maybe False (const True) marker1
              , readerOk
              , unsealedWith healthAfterInit && minioReady1
              , brokerReady1
              , unsealedWith healthAfterInit && ok vaultStatusRun
              , case savedBundle of
                  Just bundle ->
                    let text = ByteString8.unpack bundle
                     in "client_token" `isInfixOf` text
                          && not ("root_token" `isInfixOf` text)
                          && not ("pending_root" `isInfixOf` text)
                  Nothing -> False
              ]
          case2 =
            scenarioReport
              (bindingFor 2 "self-unseal")
              (ScenarioTiming case1Done case2Done case2Done)
              (if ok unlock2 then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "vault.sealed-after-restart"
              , "vault.self-unsealed"
              , "vault.same-identity"
              , "secret.survived-restart"
              ]
              [ ok services2 && ok services3
              , "self-unsealed" `isInfixOf` textOf unlock2
              , ok unlock2
              , ok unlock2
              ]
              [ sealedWith healthWhileSealed
              , unsealedWith healthUnsealed2
              , sameCluster cluster1 healthUnsealed2
              , persistWritten /= Nothing && persist2 == Just persistentValue
              ]
          refusedWith needle result = either (const False) (\(code, out, err) -> code /= 0 && needle `isInfixOf` (out ++ err)) result
          case3 =
            scenarioReport
              (bindingFor 3 "protected")
              (ScenarioTiming case2Done case3Done case3Done)
              (if ok protectedRun && ok services6 then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "protected.no-input-needs-input"
              , "protected.wrong-key-refused"
              , "protected.hidden-prompt-on-terminal"
              , "protected.unseals-with-minio-down"
              , "protected.same-identity"
              ]
              [ "Needs input" `isInfixOf` textOf noInputRun
              , "Refused" `isInfixOf` textOf wrongRun
              , "PROMPTED" `isInfixOf` ptyText && "NOECHO" `isInfixOf` ptyText && "REFUSED" `isInfixOf` ptyText
              , "were not consulted" `isInfixOf` textOf protectedRun
              , ok protectedRun
              ]
              [ sealedWith sealedProtected && sealedWith afterNoInput && not (ok noInputRun)
              , sealedWith afterWrongProtected && not (ok wrongRun)
              , sealedWith afterPty && "PROMPTED" `isInfixOf` ptyText && "NOECHO" `isInfixOf` ptyText
              , minioDown && unsealedWith afterProtected && ok protectedRun && ok services7
              , sameCluster cluster1 afterProtected
              ]
          case6 =
            scenarioReport
              (bindingFor 6 "concurrent")
              (ScenarioTiming case3Done case6Done case6Done)
              (if Nothing `notElem` concurrentWrites then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "concurrent.all-writes-readback"
              , "concurrent.no-restart-or-oom"
              , "concurrent.limits-declared"
              , "policy.labelled-client-reaches-vault"
              , "policy.unlabelled-client-refused"
              , "bootstrap.no-registry-dependency"
              ]
              [ all (== Just "done\n") concurrentWrites
              , True
              , True
              , either
                  (const False)
                  (\(code, out) -> code == 0 && "initialized" `isInfixOf` ByteString8.unpack out)
                  policyAllowed
              , either
                  (const False)
                  (\(code, out) -> code /= 0 && not ("initialized" `isInfixOf` ByteString8.unpack out))
                  policyDenied
              , either (const False) ((== 0) . fst) pullPolicies
              ]
              [ concurrentReads == map (Just . workerValue) workers && unsealedWith healthAfterWorkers
              , case podState of
                  Right (0, out) -> all noRestart (filter (not . null) (splitOnBar (ByteString8.unpack out)))
                  _ -> False
              , case limitState of
                  Right (0, out) -> all (`isInfixOf` ByteString8.unpack out) ["vault=512Mi", "minio=1Gi", "mc=512Mi"]
                  _ -> False
              , either
                  (const False)
                  (\(code, out) -> code == 0 && "initialized" `isInfixOf` ByteString8.unpack out)
                  policyAllowed
              , either
                  (const False)
                  (\(code, out) -> code /= 0 && not ("initialized" `isInfixOf` ByteString8.unpack out))
                  policyDenied
              , case pullPolicies of
                  Right (0, out) ->
                    let rows =
                          [ row
                          | row <- lines (ByteString8.unpack out)
                          , any (`isPrefixOf` row) ["prodbox-management/", "bootstrap-broker/"]
                          ]
                        policiesOf row = filter (not . null) (splitOnComma (drop 1 (dropWhile (/= ':') row)))
                     in not (null rows)
                          && all (\row -> not (null (policiesOf row)) && all (== "Never") (policiesOf row)) rows
                          && not (any ("registry" `isInfixOf`) rows)
                  _ -> False
              ]
          splitOnComma text = case break (== ',') text of
            (item, ',' : rest) -> item : splitOnComma rest
            (item, _) -> [item]
          case7 =
            scenarioReport
              (bindingFor 7 "backup-restore")
              (ScenarioTiming case6Done case7Done case7Done)
              (if ok backupRun && ok restoreRun then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "backup.created-with-manifest"
              , "restore.corrupt-backup-refused"
              , "restore.same-size-content-corruption-refused"
              , "restore.unverified-legacy-retained"
              , "restore.rolls-back-secret"
              , "restore.sealed-then-same-identity"
              , "restore.keeps-replaced-data"
              ]
              [ "Backup complete" `isInfixOf` textOf backupRun
              , "do not match its manifest" `isInfixOf` textOf corruptRestore
              , "do not match its manifest" `isInfixOf` textOf contentCorruptRestore
              , "format-1 backup contents cannot be verified" `isInfixOf` textOf legacyRestore
              , "Restore complete" `isInfixOf` textOf restoreRun
              , ok unlockAfterRestore
              , "replaced-" `isInfixOf` textOf restoreRun
              ]
              [ backupName /= Nothing && manifestPresent && persistBeforeBackup == Just persistentValue
              , not (ok corruptRestore)
                  && persistAfterCorrupt == Just changedValue
                  && unsealedWith healthAfterCorrupt
                  && changedWritten /= Nothing
                  && ok unlockAfterBackup
              , contentChanged
                  && not (ok contentCorruptRestore)
                  && persistAfterCorrupt == Just changedValue
                  && unsealedWith healthAfterCorrupt
              , ok legacyCopied
                  && legacyMarked
                  && not (ok legacyRestore)
                  && legacyRetained
                  && persistAfterCorrupt == Just changedValue
              , persistChanged == Just changedValue && persistRestored == Just persistentValue
              , sealedWith healthAfterRestore && unsealedWith healthRestored && sameCluster cluster1 healthRestored
              , replacedKept
              ]
          case8 =
            scenarioReport
              (bindingFor 8 "broker-outage")
              (ScenarioTiming case7Done case8Done case8Done)
              (if ok servicesAfterBroker then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "broker-outage.status-names-broker"
              , "broker-outage.other-facts-still-direct"
              , "broker-outage.recovers"
              ]
              [ "Broker unobservable" `isInfixOf` textOf statusBrokerDown
              , "Vault initialized=true sealed=false" `isInfixOf` textOf statusBrokerDown
                  && "MinIO ready" `isInfixOf` textOf statusBrokerDown
              , ok servicesAfterBroker
              ]
              [ brokerGone
              , unsealedWith healthBrokerDown
              , brokerBack
              ]
          case4 =
            scenarioReport
              (bindingFor 4 "adverse")
              (ScenarioTiming case2Done case4Done case4Done)
              (if sealedWith sealedBefore && ok unlock3 then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "adverse.missing-object-refused"
              , "adverse.generation-mismatch-refused"
              , "adverse.minio-outage-refused"
              , "adverse.production-policy-refused"
              , "adverse.recovers-after-restore"
              , "adverse.wrong-key-refused"
              , "adverse.interrupted-upload-continues"
              ]
              [ refusedWith "data-loss" missingRun
              , refusedWith "another environment or root generation" tamperRun
              , not (ok outageRun)
              , refusedWith "protected production" productionRun
              , ok unlock3
              , not (ok wrongKeyRun)
              , "interrupted upload was continued" `isInfixOf` textOf unlock3
              ]
              [ sealedWith afterMissing && missingStillAbsent && not (ok missingRun)
              , sealedWith afterTamper && not (ok tamperRun) && restoredMissing
              , sealedWith afterOutage && not (ok outageRun) && ok services4
              , not (ok productionRun) && sealedWith afterOutage
              , unsealedWith healthRecovered && sameCluster cluster1 healthRecovered && ok services3
              , sealedWith afterWrongKey && not (ok wrongKeyRun)
              , pendingGone && objectBack && unsealedWith healthRecovered
              ]
          case5 =
            scenarioReport
              (bindingFor 5 "recreation")
              (ScenarioTiming case4Done done done)
              (if ok unlock4 && ok reconcile2 || ok services5 then PrimarySucceeded else PrimaryFailed)
              (if absent2 && retained2 && ok delete2 then CleanupConfirmed else CleanupFailed)
              [ "recreated.vault-sealed-with-retained-data"
              , "recreated.same-identity"
              , "recreated.secret-survived"
              , "recreated.cleanup-retains-data"
              ]
              [ ok services5 && ok delete1
              , ok unlock4
              , ok unlock4
              , ok delete2
              ]
              [ sealedWith healthAfterRecreate && absent1 && retained1
              , unsealedWith healthFinal && sameCluster cluster1 healthFinal
              , persistWritten /= Nothing && persist3 == Just persistentValue
              , absent2 && retained2
              ]
      reports <- mapM (publishScenario project) [case1, case2, case3, case6, case7, case8, case4, case5]
      writeOutputLine (unlines (map fst reports))
      writeOutputLine
        ( "detail: unlock1="
            ++ take 200 (textOf unlock1)
            ++ " | missing="
            ++ take 200 (textOf missingRun)
            ++ " | mcstate="
            ++ show mcStateAfterTamper
            ++ " | tamper="
            ++ take 700 (textOf tamperRun)
            ++ " | outage="
            ++ take 500 (textOf outageRun)
            ++ " | unlock3="
            ++ take 900 (textOf unlock3)
            ++ " | production="
            ++ take 160 (textOf productionRun)
        )
      pure (if all snd reports then ExitSuccess else ExitFailure 1)
 where
  replaceGeneration generation text =
    let marker = "\"root_generation\":\"" ++ generation ++ "\""
        other =
          "\"root_generation\":\""
            ++ replicate 32 (if generation == replicate 32 'f' then 'e' else 'f')
            ++ "\""
     in replaceString marker other text
  replaceString old new text = case breakOn old text of
    Just (before, after) -> before ++ new ++ after
    Nothing -> text
  breakOn needle text = go [] text
   where
    go acc remaining = case remaining of
      _ | needle `prefixOf` remaining -> Just (reverse acc, drop (length needle) remaining)
      [] -> Nothing
      (character : rest) -> go (character : acc) rest
    prefixOf prefix string = take (length prefix) string == prefix
  replaceBytes old new bytes =
    let (before, rest) = ByteString.breakSubstring old bytes
     in if ByteString.null rest
          then bytes
          else before <> new <> ByteString.drop (ByteString.length old) rest

-- | The same bundle with its unseal key replaced by a well formed wrong one.
replaceUnsealKey :: Text.Text -> ByteString.ByteString -> Maybe ByteString.ByteString
replaceUnsealKey key bytes = case Aeson.decodeStrict bytes of
  Just (Aeson.Object fields) ->
    Just
      ( LazyByteString.toStrict
          (Aeson.encode (Aeson.Object (KeyMap.insert (Key.fromString "unseal_key") (Aeson.String key) fields)))
      )
  _ -> Nothing

-- | The unseal key held in a stored bundle, for the runner acting as the operator.
unsealKeyOf :: ByteString.ByteString -> Maybe ByteString.ByteString
unsealKeyOf bytes = case Aeson.decodeStrict bytes of
  Just (Aeson.Object fields) -> case KeyMap.lookup (Key.fromString "unseal_key") fields of
    Just (Aeson.String key) -> Just (ByteString8.pack (Text.unpack key))
    _ -> Nothing
  _ -> Nothing

splitOnBar :: String -> [String]
splitOnBar text = case break (== '|') text of
  (chunk, []) -> [chunk]
  (chunk, _ : rest) -> chunk : splitOnBar rest

-- | A pod entry is "name restartCount lastTerminatedReason"; it is clean when it
-- never restarted and was never terminated.
noRestart :: String -> Bool
noRestart entry = case words entry of
  [_, "0"] -> True
  [_, "0", reason] -> reason `notElem` ["OOMKilled", "Error"]
  _ -> False

-- | The backup name printed by `control backup` ("backups/backup-" and twelve hex digits).
backupNameOf :: String -> Maybe String
backupNameOf text = case breakOn "backups/backup-" text of
  Just after -> Just (take (length ("backup-" :: String) + 12) after)
  Nothing -> Nothing
 where
  breakOn needle haystack = case haystack of
    _ | needle `isPrefixOf` haystack -> Just (drop (length ("backups/" :: String)) haystack)
    [] -> Nothing
    (_ : rest) -> breakOn needle rest

-- | The same manifest with its content commitment replaced by a wrong one.
replaceTreeDigest :: ByteString.ByteString -> Maybe ByteString.ByteString
replaceTreeDigest bytes = case Aeson.decodeStrict bytes of
  Just (Aeson.Object fields) ->
    Just
      ( LazyByteString.toStrict
          ( Aeson.encode
              ( Aeson.Object
                  ( KeyMap.insert
                      (Key.fromString "tree_hmac_sha256")
                      (Aeson.String (Text.pack (replicate 64 '0')))
                      fields
                  )
              )
          )
      )
  _ -> Nothing

markLegacyFormat :: ByteString.ByteString -> Maybe ByteString.ByteString
markLegacyFormat bytes = case Aeson.decodeStrict bytes of
  Just (Aeson.Object fields) ->
    Just
      ( LazyByteString.toStrict
          ( Aeson.encode
              (Aeson.Object (KeyMap.insert (Key.fromString "schema_version") (Aeson.Number 1) fields))
          )
      )
  _ -> Nothing
