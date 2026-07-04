module CliSuite
  ( integrationCliSuite
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (void, when)
import Data.ByteString.Char8 qualified as BS8
import Data.List (find, findIndex, isInfixOf, sort)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , listen
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.Http.Client
  ( HttpConfig (..)
  , defaultHttpConfig
  , httpGetText
  , renderHttpError
  )
import System.Directory
  ( Permissions (..)
  , copyFile
  , createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , listDirectory
  , setPermissions
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (cwd, env)
  , ProcessHandle
  , createProcess
  , getProcessExitCode
  , proc
  , readCreateProcessWithExitCode
  , terminateProcess
  , waitForProcess
  )
import TestSupport

integrationCliSuite :: SuiteBuilder ()
integrationCliSuite = do
  describe "native Haskell config CLI" $ do
    it "shows masked settings from a repo-root Dhall config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "show"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "aws.access_key_id=Vault:secret/gateway/gateway/aws#access_key_id"
        stdoutText `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))

    it "validates config without requiring any Python backend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""

    it "fails fast with setup guidance when the repo Dhall config is missing" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "Missing required repository config"
        stderrText `shouldContain` "./.build/prodbox config setup"

    it "runs native host info directly from the built Haskell frontend" $ do
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["host", "info"]) {cwd = Just repoRoot}
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Linux"

    it "renders native aws policy JSON directly from the built Haskell frontend" $ do
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["aws", "policy", "--tier", "full"]) {cwd = Just repoRoot}
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "\"Sid\": \"Ec2TestStackLifecycle\""
      stdoutText `shouldContain` "\"Sid\": \"IamEksRoleLifecycle\""
      stdoutText `shouldContain` "\"Sid\": \"EksTestStackLifecycle\""
      stdoutText `shouldContain` "\"Sid\": \"SesCaptureBucketRead\""
      stdoutText `shouldContain` "\"Sid\": \"SesCaptureObjectRead\""
      stdoutText `shouldContain` "\"Sid\": \"SesReadOnly\""

    it "runs native gateway config-gen through the built frontend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        let outputPath = tmpDir </> "gateway.dhall"

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["gateway", "config-gen", outputPath, "--node-id", "node-a"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldBe` ""
        rendered <- readFile outputPath
        rendered `shouldContain` "node_id = \"node-a\""
        rendered `shouldContain` "fqdn = \"test.resolvefintech.com\""
        rendered `shouldContain` "zone_id = \"Z1234567890ABC\""

    it "runs native gateway status against a loopback HTTP server through the native HTTP client" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort ->
          withGatewayStateServer gatewayStateResponseJson $ \port requestRef -> do
            binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
            writeRepoMarkers tmpDir
            let configPath = tmpDir </> "gateway.dhall"
                tokenPath = tmpDir </> "vault-token.jwt"
            writeFakeVaultToken tokenPath
            writeFile configPath (gatewayStatusConfig vaultPort tokenPath)
            writeFile (tmpDir </> "orders.dhall") (gatewayOrdersAt port)

            (exitCode, stdoutText, stderrText) <-
              readCreateProcessWithExitCode
                (proc binary ["gateway", "status", "--config", configPath]) {cwd = Just tmpDir}
                ""

            exitCode `shouldBe` ExitSuccess
            stderrText `shouldBe` ""
            stdoutText `shouldContain` "Gateway status"
            stdoutText `shouldContain` "DNS_WRITE_GATE=test.resolvefintech.com@Z123 ttl=60"
            stdoutText `shouldContain` "HEARTBEAT_NODE_B=1.5"
            requestLine <- takeMVar requestRef
            requestLine `shouldContain` "GET /v1/state"

    it "Sprint 2.26: gateway federation endpoints read parent-custodied child inventory" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          writeRepoMarkers tmpDir
          writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
          (restPort, socketPort) <- allocateTwoLoopbackTcpPorts
          let tokenPath = tmpDir </> "gateway.jwt"
              ordersPath = tmpDir </> "orders.dhall"
              configPath = tmpDir </> "gateway.dhall"
              stdoutPath = tmpDir </> "gateway.stdout"
              stderrPath = tmpDir </> "gateway.stderr"
              certPath = tmpDir </> "node-a.crt"
              keyPath = tmpDir </> "node-a.key"
              caPath = tmpDir </> "ca.crt"
          writeFakeVaultToken tokenPath
          writeFile certPath "fake-cert"
          writeFile keyPath "fake-key"
          writeFile caPath "fake-ca"
          writeFile ordersPath (gatewayOrdersAtPorts restPort socketPort)
          writeFile configPath (gatewayStartConfig vaultPort tokenPath ordersPath certPath keyPath caPath)

          (_, _, _, processHandle) <-
            createProcess
              ( proc
                  "bash"
                  [ "-c"
                  , "exec \"$1\" gateway start --config \"$2\" >\"$3\" 2>\"$4\""
                  , "bash"
                  , binary
                  , configPath
                  , stdoutPath
                  , stderrPath
                  ]
              )
                { cwd = Just tmpDir
                }
          let stopGateway = do
                terminateProcess processHandle
                void (waitForProcess processHandle)

          flip finally stopGateway $ do
            waitForGatewayReadyProcess restPort processHandle stdoutPath stderrPath
            childrenBody <- expectHttpText ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children")
            childrenBody `shouldContain` "\"cluster_id\":\"child-a\""
            childrenBody `shouldContain` "\"kubeconfig_reference\":\"vault:secret/clusters/child-a/kubeconfig\""
            childrenBody `shouldContain` "\"aws-eks\":\"org/prodbox-child-a/aws-eks\""
            childrenBody `shouldNotContain` "s.child-transit"

            bootstrapBody <-
              expectHttpText
                ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children/child-a/bootstrap")
            bootstrapBody `shouldContain` "\"cluster_id\":\"child-a\""
            bootstrapBody `shouldContain` "\"parent_vault_address\":\"http://parent-vault.example:8200\""
            bootstrapBody `shouldContain` "\"transit_key\":\"prodbox-child-opaque\""
            bootstrapBody `shouldContain` "\"token\":\"s.child-transit\""

    it "fails fast when gateway start is missing required trust material" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          writeRepoMarkers tmpDir
          let ordersPath = tmpDir </> "orders.dhall"
              configPath = tmpDir </> "gateway-start.dhall"
              tokenPath = tmpDir </> "vault-token.jwt"
          writeFile ordersPath gatewayOrders
          writeFakeVaultToken tokenPath
          writeFile
            configPath
            ( gatewayStartConfig
                vaultPort
                tokenPath
                ordersPath
                (tmpDir </> "missing.crt")
                (tmpDir </> "missing.key")
                (tmpDir </> "missing-ca.crt")
            )

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
              ""

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "Failed to validate gateway startup inputs"
          stderrText `shouldContain` "cert_file does not exist"
          stderrText `shouldContain` "key_file does not exist"
          stderrText `shouldContain` "ca_file does not exist"

    it "runs native gateway-partition through the built frontend without delegating to tla-check" $ do
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "gateway-partition"]) {cwd = Just repoRoot}
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldContain` "[validation=gateway-partition substrate=home-local] entering body"
      stderrText
        `shouldContain` "[validation=gateway-partition substrate=home-local] body exit=ExitSuccess"
      stdoutText `shouldContain` "Validation: gateway-partition"
      stdoutText `shouldContain` "FORMAL_MODEL_DELEGATED=false"
      stdoutText `shouldContain` "SINGLE_WRITER_AFTER_TAKEOVER=true"

    it "runs native resource-guardrails validation through fake Kubernetes resource JSON" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeFile (tmpDir </> ".build" </> "prodbox.dhall") (wrapTier0 validConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "resource-guardrails"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let output =
              unlines
                [ "resource-guardrails stdout:"
                , stdoutText
                , "resource-guardrails stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure output)
        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=resource-guardrails substrate=home-local] entering body"
        stderrText
          `shouldContain` "[validation=resource-guardrails substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "Validation: resource-guardrails"
        stdoutText `shouldContain` "RESOURCE_GUARDRAILS_VALIDATION"
        stdoutText `shouldContain` "PODS_CHECKED=5"
        stdoutText `shouldContain` "CONTAINERS_CHECKED=5"
        stdoutText `shouldContain` "QUOTA_NAMESPACES=keycloak,vscode,api,websocket,gateway"
        stdoutText `shouldContain` "LIMIT_RANGE_NAMESPACES=keycloak,vscode,api,websocket,gateway"
        stdoutText `shouldContain` "BESTEFFORT_PODS=0"
        stdoutText `shouldContain` "UNCAPPED_CONTAINERS=0"

    it
      "runs native charts list, status, deploy, and delete through the built frontend with fake helm and kubectl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        envVars <- fakeChartEnvironment tmpDir

        (listExitCode, listStdout, listStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "list"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        listExitCode `shouldBe` ExitSuccess
        listStderr `shouldBe` ""
        listStdout `shouldContain` "CHART_LIST"
        listStdout `shouldContain` "NAME=vscode"

        (statusExitCode, statusStdout, statusStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "status", "vscode"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "CHART_STATUS"
        statusStdout `shouldContain` "NAME=vscode"
        statusStdout `shouldContain` "STORAGE_BINDING"

        (deployExitCode, deployStdout, deployStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "reconcile", "vscode"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        when
          (deployExitCode /= ExitSuccess)
          (expectationFailure ("deploy STDOUT:\n" ++ deployStdout ++ "\ndeploy STDERR:\n" ++ deployStderr))
        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"
        deployStdout `shouldContain` "ROOT_CHART=vscode"

        -- Sprint 3.19: host-side Secret pre-apply is retired; chart deploy
        -- storage manifests are still asserted by content rather than apply
        -- ordinal.
        appliedManifest <- readAppliedManifestContaining (tmpDir </> "fake-chart-state") "data-vscode-0"
        appliedManifest `shouldContain` "PersistentVolumeClaim"
        patroniManifest <-
          readAppliedManifestContaining
            (tmpDir </> "fake-chart-state")
            "prodbox-vscode-pg-instance1-0-pgdata"
        patroniManifest `shouldContain` "PersistentVolume"
        patroniManifest `shouldNotContain` "PersistentVolumeClaim"

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|keycloak"
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|vscode"

        kubectlRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl.txt")
        kubectlRecord `shouldContain` "get|crd|perconapgclusters.pgv2.percona.com|-o|name"
        kubectlRecord
          `shouldContain` "get|deployment|postgres-operator|--namespace|postgres-operator|-o|name"
        kubectlRecord
          `shouldContain` "get|pvc|--namespace|vscode|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|-o|json"
        kubectlRecord
          `shouldContain` "get|perconapgclusters.pgv2.percona.com|prodbox-vscode-pg|-n|vscode|-o|jsonpath={.status.state}"
        kubectlRecord
          `shouldContain` "get|perconapgclusters.pgv2.percona.com|prodbox-vscode-pg|-n|vscode|-o|jsonpath={.status.postgres.ready}"

        initialChartStateFiles <- listDirectory (tmpDir </> "fake-chart-state")
        let initialApplyTargetCount =
              length
                [ path
                | path <- initialChartStateFiles
                , take 13 path == "kubectl-apply"
                ]
            -- The second reconcile models the fully-deployed steady state, so
            -- ALL THREE releases of the `vscode` chart root must appear in the
            -- helm list — including `keycloak-postgres`. Under the deploy-missing
            -- reconcile (`chartReleasesToDeploy`), omitting any release marks it
            -- as needing (re)deployment; leaving `keycloak-postgres` out would
            -- drive a redundant Patroni redeploy instead of the intended
            -- idempotent no-op. (The partial-rollback heal — deploy only the
            -- missing release — is covered by the `chartReleasesToDeploy` unit
            -- test.)
            alreadyDeployedEnvVars =
              ( "PRODBOX_FAKE_HELM_LIST_JSON"
              , "[{\"name\":\"keycloak-postgres\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"keycloak\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"vscode\",\"namespace\":\"vscode\",\"status\":\"deployed\"}]"
              )
                : filter ((/= "PRODBOX_FAKE_HELM_LIST_JSON") . fst) envVars

        (secondDeployExitCode, secondDeployStdout, secondDeployStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "reconcile", "vscode"])
              { cwd = Just tmpDir
              , env = Just alreadyDeployedEnvVars
              }
            ""

        when
          (secondDeployExitCode /= ExitSuccess)
          ( expectationFailure
              ("secondDeploy STDOUT:\n" ++ secondDeployStdout ++ "\nsecondDeploy STDERR:\n" ++ secondDeployStderr)
          )
        secondDeployExitCode `shouldBe` ExitSuccess
        secondDeployStderr `shouldBe` ""
        secondDeployStdout `shouldContain` "CHART_DEPLOYMENT"
        secondDeployStdout `shouldContain` "ROOT_CHART=vscode"

        upgradeRecordAfterSecondDeploy <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        upgradeRecordAfterSecondDeploy `shouldBe` upgradeRecord

        chartStateFilesAfterSecondDeploy <- listDirectory (tmpDir </> "fake-chart-state")
        length
          [ path
          | path <- chartStateFilesAfterSecondDeploy
          , take 13 path == "kubectl-apply"
          ]
          `shouldBe` initialApplyTargetCount

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "delete", "vscode", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        when
          (deleteExitCode /= ExitSuccess)
          (expectationFailure ("delete STDOUT:\n" ++ deleteStdout ++ "\ndelete STDERR:\n" ++ deleteStderr))
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "CHART_DELETION"
        deleteStdout `shouldContain` "HOST_STORAGE_PRESERVED=true"

        uninstallRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-uninstall.txt")
        uninstallRecord `shouldContain` "uninstall|vscode|--namespace|vscode"
        uninstallRecord `shouldContain` "uninstall|keycloak|--namespace|vscode"

        deleteRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-delete.txt")
        deleteRecord
          `shouldContain` "delete|pod|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|--namespace|vscode|--ignore-not-found=true|--wait=true"
        deleteRecord
          `shouldContain` "delete|pvc|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|--namespace|vscode|--ignore-not-found=true|--wait=true"
        deleteRecord
          `shouldContain` "delete|pv|prodbox-retained-vscode-prodbox-vscode-pg-0"
        deleteRecord `shouldContain` "delete|pvc|data-vscode-0|--namespace|vscode"
        deleteRecord `shouldContain` "delete|pv|prodbox-retained-vscode-vscode-0"
        deleteRecord `shouldContain` "delete|namespace|vscode"

    it "stages retained Patroni restore from ordinal-0 host data when no live primary exists" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        -- Sprint 4.31: the retained ordinal-0 host data lives at the unified
        -- `.data/<namespace>/<StatefulSet>/<ordinal>` path (no `<release>` /
        -- `<claim>` segment), so the restore-staging detects it here.
        createDirectoryIfMissing
          True
          (tmpDir </> ".data" </> "vscode" </> "prodbox-vscode-pg" </> "0")
        baseEnvVars <- fakeChartEnvironment tmpDir
        let envVars = ("PRODBOX_FAKE_PATRONI_STAGED_RESTORE", "true") : baseEnvVars

        (deployExitCode, deployStdout, deployStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "reconcile", "vscode"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"
        deployStdout `shouldContain` "ROOT_CHART=vscode"

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        let upgradeLines = lines upgradeRecord
            keycloakPostgresUpgrades =
              filter ("|keycloak-postgres|" `isInfixOf`) upgradeLines
        length keycloakPostgresUpgrades `shouldBe` 2
        length upgradeLines `shouldBe` 4

    it "rejects internal dependency charts on the public charts surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        envVars <- fakeChartEnvironment tmpDir

        (statusExitCode, _, statusStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "status", "keycloak-postgres"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        statusExitCode `shouldBe` ExitFailure 1
        statusStderr `shouldContain` "Unsupported public chart 'keycloak-postgres'"
        statusStderr `shouldContain` "Supported root charts: keycloak, vscode, api, websocket, gateway"
        statusStderr `shouldContain` "internal dependency release"

        (deleteExitCode, _, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "delete", "redis", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deleteExitCode `shouldBe` ExitFailure 1
        deleteStderr `shouldContain` "Unsupported public chart 'redis'"
        deleteStderr `shouldContain` "Supported root charts: keycloak, vscode, api, websocket, gateway"
        deleteStderr `shouldContain` "internal dependency release"

    it
      "runs native rke2 status, start, and logs through the built frontend with fake systemctl and journalctl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        envVars <- fakeRke2Environment tmpDir

        (statusExitCode, statusStdout, statusStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "status"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "active"
        statusStdout `shouldContain` "Vault: initialized=True, sealed=False"

        (startExitCode, startStdout, startStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "start"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        startExitCode `shouldBe` ExitSuccess
        startStdout `shouldBe` ""
        startStderr `shouldBe` ""

        (logsExitCode, logsStdout, logsStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "logs", "--lines", "25"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        logsExitCode `shouldBe` ExitSuccess
        logsStderr `shouldBe` ""
        logsStdout `shouldContain` "RKE2_LOG_LINES"

        systemctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "systemctl.txt")
        systemctlRecord `shouldContain` "is-active|rke2-server.service"
        systemctlRecord `shouldContain` "start|rke2-server.service"

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "systemctl|start|rke2-server.service"

        journalctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "journalctl.txt")
        journalctlRecord `shouldContain` "-u|rke2-server.service|-n|25|--no-pager"

    it
      "runs native rke2 reconcile and delete through the built frontend with fake host, kubectl, helm, docker, and native AWS destroy helpers"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        -- Sprint 1.42 Part B: with the Tier-0 prodbox.dhall floor present, the
        -- post-MinIO settings reload obtains the host Vault root token; supply
        -- the test seam so it does not try to decrypt an unlock bundle (none
        -- exists in this temp repo). The in-force SSoT seed against the real
        -- Vault fail-WARNs and the config read falls back to .parameters.
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir

        (installExitCode, installStdout, installStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let installOutput =
              unlines
                [ "install stdout:"
                , installStdout
                , "install stderr:"
                , installStderr
                ]
        when (installExitCode /= ExitSuccess) (expectationFailure installOutput)
        installExitCode `shouldBe` ExitSuccess
        installStdout `shouldContain` "Kubernetes control plane is running"
        installStdout `shouldContain` "RKE2 resource guardrails: host capacity ok"
        installStdout `shouldContain` "RKE2 kubelet resource guardrails: written"
        installStdout `shouldContain` "RKE2 systemd resource guardrails: written"
        -- The first reconcile host-prep step raises the inotify limits so the
        -- systemd manager does not exhaust the per-user instance cap during RKE2
        -- lifecycle operations (see streaming_doctrine.md § 6).
        installStdout `shouldContain` "Host inotify limits:"
        installStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Local RKE2 substrate: cleanup complete"
        deleteStdout `shouldContain` "Managed kubeconfig: removed"
        deleteStdout `shouldContain` "Preserved host state:"
        deleteStdout `shouldNotContain` "Logged in to fake-rke2"
        kubeconfigExists <- doesFileExist (tmpDir </> ".kube" </> "config")
        kubeconfigExists `shouldBe` False

        systemctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "systemctl.txt")
        systemctlRecord `shouldContain` "enable|rke2-server.service"
        systemctlRecord `shouldContain` "restart|rke2-server.service"
        systemctlRecord `shouldContain` "disable|--now|rke2-server.service"

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "env|INSTALL_RKE2_TYPE=server|sh|"
        sudoRecord `shouldContain` "/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml"
        sudoRecord
          `shouldContain` "/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf"
        sudoRecord `shouldContain` "systemctl|daemon-reload"
        sudoRecord `shouldContain` "cp|/etc/rancher/rke2/rke2.yaml|"
        sudoRecord `shouldContain` "ctr|--address|"
        sudoRecord
          `shouldContain` "rm|-rf|/var/lib/rancher/rke2|/var/lib/rancher|/etc/rancher/rke2|/usr/local/bin/rke2|/usr/local/bin/rke2-killall.sh|/usr/local/bin/rke2-uninstall.sh"

        -- The first delete host-prep step persists the inotify sysctl drop-in and
        -- applies it via `sysctl --system` before systemd unwinds the RKE2 units,
        -- so PID 1 never logs `Failed to allocate directory watch: Too many open
        -- files` to the console (see streaming_doctrine.md § 6).
        deleteStdout `shouldContain` "Host inotify limits:"
        sudoRecord `shouldContain` "/etc/sysctl.d/99-prodbox-inotify.conf"
        sudoRecord `shouldContain` "sysctl|--system"
        sysctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sysctl.txt")
        sysctlRecord `shouldContain` "--system"

        kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
        kubectlRecord `shouldContain` "cluster-info"
        kubectlRecord `shouldContain` "get|nodes|-o|name"
        kubectlRecord `shouldContain` "wait|--for=condition=Ready|node|--all|--timeout=300s"
        kubectlRecord `shouldContain` "rollout|status|statefulset/vault|-n|vault|--timeout=300s"
        kubectlRecord `shouldContain` "get|storageclass|-o|name"
        kubectlRecord
          `shouldContain` "delete|storageclass|storageclass.storage.k8s.io/local-path|--ignore-not-found=true"
        kubectlRecord
          `shouldContain` "patch|configmap|harbor-nginx|-n|harbor|--type|merge|--field-manager=helm|--patch|"
        kubectlRecord
          `shouldContain` "patch|deployment|harbor-nginx|-n|harbor|--type|strategic|--field-manager=helm|--patch|"
        kubectlRecord `shouldContain` "/readyz"
        kubectlRecord `shouldContain` "annotate|namespace/prodbox|prodbox.io/id=prodbox-"
        kubectlRecord `shouldContain` "label|namespace/prodbox|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldContain` "annotate|clusterroles.rbac.authorization.k8s.io|-l|app.kubernetes.io/instance=harbor|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldContain` "label|clusterroles.rbac.authorization.k8s.io|-l|app.kubernetes.io/instance=harbor|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldNotContain` "delete|namespace|harbor|--ignore-not-found=true|--wait=true|--timeout=300s"
        kubectlRecord `shouldNotContain` "jsonpath={.metadata.labels.app\\.kubernetes\\.io/name}"
        kubectlRecord
          `shouldNotContain` "delete|namespace|traefik-system|--ignore-not-found=true|--wait=true|--timeout=300s"

        let rke2StateDir = tmpDir </> "fake-rke2-state"

        applyIdentity <- readFile (rke2StateDir </> "kubectl-apply-1.json")
        applyIdentity `shouldContain` "prodbox-identity"
        applyStorage <- readFile (rke2StateDir </> "kubectl-apply-2.json")
        -- Sprint 4.31: retained storage is PV-only — the MinIO and Vault
        -- StatefulSets create their own `data-<sts>-0` PVCs, which these
        -- deterministic claimRef'd PVs bind. No PVC object in the manifest.
        applyStorage `shouldNotContain` "PersistentVolumeClaim"
        applyStorage `shouldContain` "prodbox-retained-prodbox-minio-0"
        applyStorage `shouldContain` "prodbox-retained-vault-vault-0"
        applyStorage `shouldContain` "data-minio-0"
        applyStorage `shouldContain` "data-vault-0"
        applyHarborBootstrap <-
          readAppliedManifestContaining rke2StateDir harborRegistryStorageBootstrapJobName
        applyHarborBootstrap `shouldContain` harborRegistryStorageSecretName
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_ACCESSKEY"
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_SECRETKEY"
        applyHarborBootstrap `shouldContain` "quay.io/minio/mc"
        applyHarborBootstrap
          `shouldContain` ("mc mb --ignore-existing local/" ++ harborRegistryStorageBucket)
        applyHarborBootstrap `shouldContain` "s3:AbortMultipartUpload"
        applyHarborBootstrap `shouldContain` "s3:ListMultipartUploadParts"
        applyHarborBootstrap `shouldContain` "s3:ListBucketMultipartUploads"
        applyHarborBootstrap `shouldContain` "mc admin policy rm local prodbox-harbor-registry-policy"
        applyAdminRoutes <- readAppliedManifestContaining rke2StateDir "harbor-ui"
        applyAdminRoutes `shouldContain` "harbor-ui"
        applyAdminRoutes `shouldContain` "minio-console"
        applyAdminRoutes `shouldContain` "harbor-oidc"
        applyAdminRoutes `shouldContain` "minio-oidc"
        applyAdminRoutes
          `shouldContain` "https://test.resolvefintech.com/auth/realms/prodbox/protocol/openid-connect/auth"
        applyAdminRoutes
          `shouldContain` "http://keycloak.vscode.svc.cluster.local:8080/auth/realms/prodbox/protocol/openid-connect/token"

        helmRecord <- readFile (tmpDir </> "fake-rke2-state" </> "helm.txt")
        -- Sprint 4.31: MinIO + Vault are prodbox-owned StatefulSet charts. MinIO
        -- always uses the PUBLIC image (it backs Harbor — never the Harbor
        -- mirror), so there is no bitnami `minio` helm repo and the chart sets no
        -- `mcImage`. Vault installs from `charts/vault`. Sprint 7.25: MinIO is
        -- now brought up BEFORE Vault (it is cluster-only and serves the unlock
        -- bundle pre-unseal), so its helm install precedes Vault's.
        helmRecord `shouldNotContain` "repo|add|minio|https://charts.min.io/"
        helmRecord `shouldNotContain` "upgrade|--install|minio|minio/minio"
        helmRecord `shouldContain` "/charts/minio|--namespace|prodbox|--create-namespace"
        helmRecord `shouldContain` "image.repository=quay.io/minio/minio"
        helmRecord `shouldContain` "--set|storage.className=manual"
        helmRecord `shouldNotContain` "image.repository=127.0.0.1:30080/prodbox/minio-mirror"
        helmRecord `shouldNotContain` "mcImage.repository"
        helmRecord `shouldContain` "/charts/vault|--namespace|vault|--create-namespace"
        helmRecord `shouldContain` "repo|add|harbor|https://helm.goharbor.io"
        helmRecord `shouldContain` "upgrade|--install|harbor|harbor/harbor"
        helmRecord `shouldContain` "harbor/harbor|--force-conflicts|--namespace|harbor"
        helmRecord `shouldContain` "persistence.imageChartStorage.type=s3"
        helmRecord `shouldContain` "persistence.imageChartStorage.disableredirect=true"
        helmRecord
          `shouldContain` ("persistence.imageChartStorage.s3.bucket=" ++ harborRegistryStorageBucket)
        helmRecord
          `shouldContain` ("persistence.imageChartStorage.s3.regionendpoint=" ++ minioClusterEndpoint)
        helmRecord
          `shouldContain` ("persistence.imageChartStorage.s3.existingSecret=" ++ harborRegistryStorageSecretName)
        helmRecord `shouldContain` "repo|add|metallb|https://metallb.github.io/metallb"
        helmRecord `shouldContain` "upgrade|--install|metallb|metallb/metallb"
        helmRecord `shouldContain` "metallb/metallb|--force-conflicts|--version|0.14.9"
        helmRecord `shouldContain` "upgrade|--install|envoy-gateway|oci://docker.io/envoyproxy/gateway-helm"
        helmRecord `shouldContain` "repo|add|jetstack|https://charts.jetstack.io"
        helmRecord `shouldContain` "upgrade|--install|cert-manager|jetstack/cert-manager"
        helmRecord `shouldContain` "repo|add|percona|https://percona.github.io/percona-helm-charts/"
        helmRecord `shouldContain` "upgrade|--install|postgres-operator|percona/pg-operator"
        helmRecord `shouldNotContain` "uninstall|traefik|--namespace|traefik-system|--wait"
        helmRecord `shouldNotContain` "uninstall|postgres-operator|--namespace|postgres-operator|--wait"
        -- Sprint 7.25: MinIO is installed BEFORE Vault (cluster-only, serves the
        -- unlock bundle before Vault unseal), and both precede Harbor.
        findRecordLineIndex "/charts/minio|--namespace|prodbox" helmRecord
          `shouldSatisfy` (< findRecordLineIndex "/charts/vault|--namespace|vault" helmRecord)
        findRecordLineIndex "/charts/vault|--namespace|vault" helmRecord
          `shouldSatisfy` (< findRecordLineIndex "upgrade|--install|harbor|harbor/harbor" helmRecord)

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        -- Sprint 1.47: NO `docker login` runs at all — Harbor auth is inline in the
        -- ephemeral DOCKER_CONFIG, public pulls use the host docker.io login.
        dockerRecord `shouldNotContain` "login|127.0.0.1:30080"
        dockerRecord `shouldNotContain` "buildx|"
        dockerRecord `shouldNotContain` "docker/bitnami-postgresql-repmgr.Dockerfile"
        dockerRecord `shouldNotContain` "docker/bitnami-pgpool.Dockerfile"
        dockerRecord `shouldContain` "pull|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord `shouldContain` "pull|docker.io/percona/percona-postgresql-operator:2.9.0"
        dockerRecord
          `shouldContain` "tag|docker.io/percona/percona-postgresql-operator:2.9.0|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord `shouldContain` "push|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "tag|ghcr.io/coder/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        dockerRecord
          `shouldContain` "tag|docker.io/codercom/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        -- One union runtime image built from the single Dockerfile, consumed by
        -- the gateway daemon + api/websocket workloads (role chosen by chart args).
        dockerRecord
          `shouldContain` "build|-f|docker/prodbox.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord `shouldContain` "-t|127.0.0.1:30080/prodbox/prodbox-runtime:latest|."
        dockerRecord `shouldContain` "push|127.0.0.1:30080/prodbox/prodbox-runtime:latest"
        dockerRecord `shouldNotContain` "docker/gateway.Dockerfile"
        dockerRecord `shouldNotContain` "prodbox-public-edge-workload"
        dockerRecord `shouldNotContain` "docker/nginx-oidc.Dockerfile"
        dockerRecord `shouldContain` "save|-o|"

        -- Sprint 1.47: the build/push/mirror docker calls ran inside an
        -- EPHEMERAL DOCKER_CONFIG (a scrubbed `prodbox-docker-config` temp dir),
        -- never the operator's global ~/.docker, so prodbox cannot pollute the
        -- system Docker Hub login state.
        dockerConfigRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker-config.txt")
        dockerConfigRecord `shouldContain` "prodbox-docker-config"

        curlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "curl.txt")
        curlRecord `shouldContain` "https://get.rke2.io"
        curlRecord `shouldContain` "http://127.0.0.1:30080/readyz"
        curlRecord `shouldContain` "http://127.0.0.1:30080/v2/"
        curlRecord `shouldContain` "/api/v2.0/projects"

        pulumiRecordExists <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRecordExists `shouldBe` False

    it "falls back to mirror.gcr when Docker Hub rate-limits a supported Percona image" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ( "PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF"
              , "docker.io/percona/percona-distribution-postgresql:17.9-1"
              )
                : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                : baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let installOutput =
              unlines
                [ "install stdout:"
                , installStdout
                , "install stderr:"
                , installStderr
                ]
        when (installExitCode /= ExitSuccess) (expectationFailure installOutput)
        installExitCode `shouldBe` ExitSuccess
        installStdout `shouldContain` "Kubernetes control plane is running"

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        dockerRecord `shouldContain` "pull|docker.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord `shouldContain` "pull|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord
          `shouldContain` "tag|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
        dockerRecord
          `shouldContain` "push|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"

    it "summarizes noisy uninstall-script cleanup instead of streaming raw delete traces" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars = ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1") : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Local RKE2 substrate: cleanup complete"
        deleteStdout `shouldContain` "Managed kubeconfig: removed"
        deleteStdout `shouldContain` "Preserved host state:"
        deleteStdout `shouldNotContain` "Logged in to fake-rke2"
        deleteStdout `shouldNotContain` "Cannot find device"
        deleteStdout `shouldNotContain` "semodule: not found"
        -- Capturable-path only: the real inotify warning is out-of-band (see fakeSudoScript NOTE).
        deleteStdout `shouldNotContain` "Failed to allocate directory watch"
        deleteStdout `shouldNotContain` "Too many open files"
        deleteStdout `shouldNotContain` "Cleanup completed successfully"

        kubeconfigExists <- doesFileExist (tmpDir </> ".kube" </> "config")
        kubeconfigExists `shouldBe` False

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "/usr/local/bin/rke2-uninstall.sh"

    it "summarizes actionable uninstall failures while suppressing benign chatter" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1")
                : ("PRODBOX_FAKE_RKE2_UNINSTALL_FAIL", "1")
                : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deleteExitCode `shouldBe` ExitFailure 1
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        deleteStdout `shouldNotContain` "Local RKE2 substrate: cleanup complete"
        deleteStderr `shouldContain` "failed to clean the local RKE2 substrate"
        deleteStderr `shouldContain` "umount: /var/lib/kubelet/pods/abc: target is busy"
        -- Capturable-path only: the real inotify warning is out-of-band (see fakeSudoScript NOTE).
        deleteStderr `shouldNotContain` "Failed to allocate directory watch"
        deleteStderr `shouldNotContain` "semodule: not found"
        deleteStderr `shouldNotContain` "Cannot find device"

    it "runs native rke2 delete after the IAM harness has cleared operational aws credentials" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        envVars <- fakeRke2Environment tmpDir

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Preserved host state:"

    it "cluster delete --yes is a pure local uninstall that never refuses on per-run residue" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnvVars <- fakeRke2Environment tmpDir
        -- Even with the per-run backend forced unreachable, the default
        -- delete never queries, gates on, or destroys it — it is a pure
        -- local cluster uninstall. (All per-run AWS destruction is --cascade.)
        let envVars =
              ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
                : filter ((/= "PRODBOX_TEST_RESIDUE_ABSENT") . fst) baseEnvVars

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput = unlines ["delete stdout:", deleteStdout, "delete stderr:", deleteStderr]
            combined = deleteStdout ++ deleteStderr
        when
          (deleteExitCode /= ExitSuccess)
          (expectationFailure ("expected a clean local uninstall, got failure:\n" ++ deleteOutput))
        deleteExitCode `shouldBe` ExitSuccess
        combined `shouldContain` "Uninstalling the local cluster..."
        -- No refusal and no per-run backend interaction.
        combined `shouldNotContain` "per-run Pulumi state backend"
        combined `shouldNotContain` "Refused:"

    it "Sprint 4.25: rke2 delete --yes is a no-op success with no RKE2 install" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        -- Reproduce the real "cluster already gone" host: no RKE2 install AND an
        -- unreachable in-cluster MinIO state backend. The short-circuit must win
        -- over the residue gate's fail-closed refusal.
        envVars <- withNoRke2Install <$> fakeRke2Environment tmpDir

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitSuccess
        combined `shouldContain` "No RKE2 cluster to delete."
        -- The residue gate never ran, so neither its refusal nor a teardown
        -- narration may appear.
        combined `shouldNotContain` "per-run Pulumi state backend"
        combined `shouldNotContain` "Uninstalling the local cluster..."

    it "Sprint 4.25: rke2 delete --cascade is a no-op success with no RKE2 install" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        envVars <- withNoRke2Install <$> fakeRke2Environment tmpDir

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitSuccess
        combined `shouldContain` "No RKE2 cluster to delete."
        -- The cascade orchestration never started.
        combined `shouldNotContain` "confirm-MinIO"

    -- Sprint 8.8: the operator-only `prodbox nuke` total teardown is exercised
    -- through the same PRODBOX_ALLOW_NON_TTY_INTERACTIVE seam the other
    -- interactive surfaces (aws setup/teardown, config setup) use, feeding the
    -- typed confirmation on stdin. The retained public-edge certificate lives
    -- in the long-lived `pulumi_state_backend` bucket, which only nuke's step 5
    -- destroys; these prove the confirmation gate and that path.
    it
      "Sprint 8.8: nuke --dry-run plans to destroy the long-lived state bucket holding the retained cert"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfigForNuke)

        (exitCode, stdoutText, _) <-
          readCreateProcessWithExitCode
            (proc binary ["nuke", "--dry-run"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stdoutText `shouldContain` "PRODBOX_NUKE_PLAN"
        stdoutText `shouldContain` "STEP=5 destroy long-lived `pulumi_state_backend` S3 bucket"
        stdoutText `shouldContain` "CONFIRMATION_LITERAL=NUKE EVERYTHING"

    it "Sprint 8.8: nuke refuses the total teardown when the typed confirmation is wrong" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfigForNuke)
        envVars <- fakeRke2Environment tmpDir
        let nukeEnv = ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1") : envVars

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["nuke"]) {cwd = Just tmpDir, env = Just nukeEnv}
            "destroy please\n"

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "confirmation rejected; nothing destroyed"
        -- Nothing was destroyed: the orchestration never shelled out to pulumi.
        pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRan `shouldBe` False

    it
      "Sprint 1.36: vault lifecycle commands initialize, unseal, reconcile, rotate, issue PKI, and seal"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        writeFile (tmpDir </> "test-secrets.dhall") testSecretsDhall
        withFakeVaultLifecycleServer $ \vaultPort stateRef -> do
          -- Sprint 7.25 (disk-free): the unlock bundle is MinIO-only, so init /
          -- unseal / rotate write and read it through the durable object store.
          -- This host-only test has no cluster MinIO, so point the bootstrap
          -- bundle at a local file via the PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR test
          -- seam (mirrors the existing PRODBOX_TEST_* Vault seams).
          let bootstrapBundleDir = tmpDir </> ".bootstrap-bundle-store"
          baseEnvVars <- fakeVaultLifecycleEnvironment vaultPort
          let envVars = ("PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR", bootstrapBundleDir) : baseEnvVars
              runVault args =
                readCreateProcessWithExitCode
                  (proc binary ("vault" : args)) {cwd = Just tmpDir, env = Just envVars}
                  ""

          (initialStatusExit, initialStatusStdout, initialStatusStderr) <- runVault ["status"]
          initialStatusExit `shouldBe` ExitSuccess
          initialStatusStderr `shouldBe` ""
          initialStatusStdout `shouldContain` "Vault: initialized=False, sealed=True"

          (initExit, initStdout, initStderr) <- runVault ["init"]
          initExit `shouldBe` ExitSuccess
          initStderr `shouldBe` ""
          initStdout `shouldContain` "Vault initialized; encrypted unlock bundle written"
          -- Sprint 7.25: the bundle is written to the (test-seam) durable bundle
          -- store, NOT host disk; the cluster-established marker is stamped on disk.
          bundleExists <- doesFileExist (bootstrapBundleDir </> "bootstrap-bundle.enc")
          bundleExists `shouldBe` True
          markerExists <- doesFileExist (tmpDir </> ".data/prodbox/.cluster-established")
          markerExists `shouldBe` True

          (initAgainExit, initAgainStdout, initAgainStderr) <- runVault ["init"]
          initAgainExit `shouldBe` ExitSuccess
          initAgainStderr `shouldBe` ""
          initAgainStdout `shouldContain` "Vault is already initialized; refusing to re-initialize"

          (unsealExit, unsealStdout, unsealStderr) <- runVault ["unseal"]
          unsealExit `shouldBe` ExitSuccess
          unsealStderr `shouldBe` ""
          unsealStdout `shouldContain` "Vault unsealed."

          (reconcileExit, reconcileStdout, reconcileStderr) <- runVault ["reconcile"]
          reconcileExit `shouldBe` ExitSuccess
          reconcileStderr `shouldBe` ""
          reconcileStdout `shouldContain` "Vault reconcile complete:"
          reconcileStdout `shouldContain` "mount pki: present"
          reconcileStdout `shouldContain` "policy prodbox-gateway: written"
          reconcileStdout `shouldContain` "secret-object secret/minio/root: created"
          reconcileStdout
            `shouldContain` "secret-object secret/gateway/gateway/aws declared (managed by prodbox aws setup)"

          (rotateBundleExit, rotateBundleStdout, rotateBundleStderr) <- runVault ["rotate-unlock-bundle"]
          rotateBundleExit `shouldBe` ExitSuccess
          rotateBundleStderr `shouldBe` ""
          rotateBundleStdout `shouldContain` "Vault unlock bundle re-encrypted"

          (rotateTransitExit, rotateTransitStdout, rotateTransitStderr) <-
            runVault ["rotate-transit-key", "prodbox-minio-envelope"]
          rotateTransitExit `shouldBe` ExitSuccess
          rotateTransitStderr `shouldBe` ""
          rotateTransitStdout `shouldContain` "Vault Transit key rotated: prodbox-minio-envelope"

          (pkiStatusExit, pkiStatusStdout, pkiStatusStderr) <- runVault ["pki", "status"]
          pkiStatusExit `shouldBe` ExitSuccess
          pkiStatusStderr `shouldBe` ""
          pkiStatusStdout `shouldContain` "Vault PKI: pki mount present."

          (pkiIssueExit, pkiIssueStdout, pkiIssueStderr) <- runVault ["pki", "issue-test-cert"]
          pkiIssueExit `shouldBe` ExitSuccess
          pkiIssueStderr `shouldBe` ""
          pkiIssueStdout `shouldContain` "Vault PKI test certificate issued:"
          pkiIssueStdout `shouldContain` "-----BEGIN CERTIFICATE-----"

          (sealExit, sealStdout, sealStderr) <- runVault ["seal"]
          sealExit `shouldBe` ExitSuccess
          sealStderr `shouldBe` ""
          sealStdout `shouldContain` "Vault sealed."
          finalState <- readMVar stateRef
          fakeVaultLifecycleInitialized finalState `shouldBe` True
          fakeVaultLifecycleSealed finalState `shouldBe` True

    it "Sprint 1.37: aws stack reconcile refuses before Pulumi when Vault is sealed" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnv <- fakeRke2Environment tmpDir
        withGatewayStateServer sealedVaultStatusJson $ \port _ -> do
          let envVars =
                ("PRODBOX_TEST_PULUMI_VAULT_ADDR", fakeVaultAddress port)
                  : filter ((/= "PRODBOX_TEST_PULUMI_VAULT_GATE") . fst) baseEnv

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary ["aws", "stack", "eks", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
              ""

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "Blocked: Vault is sealed."
          stderrText `shouldContain` "No preview/update/destroy was started."
          stderrText `shouldContain` "Run: prodbox vault unseal"
          pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
          pulumiRan `shouldBe` False

    it "Sprint 4.32: cluster federation register provisions the parent-side child bootstrap surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        withFakeVaultLifecycleServer $ \vaultPort stateRef -> do
          modifyMVar stateRef $ \_ -> pure (FakeVaultLifecycleState True False 3, ())
          writeRootBasics tmpDir (fakeVaultAddress vaultPort) validConfig
          baseEnv <- fakeRke2Environment tmpDir
          let envVars =
                ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-parent-root-token")
                  : filter ((/= "PRODBOX_TEST_HOST_VAULT_TOKEN") . fst) baseEnv
              childKubeconfig = tmpDir </> "child.kubeconfig"
          writeFile childKubeconfig "apiVersion: v1\nkind: Config\n"

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              ( proc
                  binary
                  [ "cluster"
                  , "federation"
                  , "register"
                  , "child-a"
                  , "--child-vault-address"
                  , "http://child-vault.example:8200"
                  , "--child-kubeconfig"
                  , childKubeconfig
                  , "--child-kubeconfig-reference"
                  , "vault:secret/clusters/child-a/kubeconfig"
                  , "--child-account-id"
                  , "123456789012"
                  , "--child-endpoint"
                  , "api=https://api.child-a.example"
                  , "--child-pulumi-stack"
                  , "aws-eks=org/prodbox-child-a/aws-eks"
                  ]
              )
                { cwd = Just tmpDir
                , env = Just envVars
                }
              ""

          when
            (exitCode /= ExitSuccess)
            (expectationFailure (unlines ["register stdout:", stdoutText, "register stderr:", stderrText]))
          exitCode `shouldBe` ExitSuccess
          stderrText `shouldBe` ""
          stdoutText `shouldContain` "Cluster federation registration complete:"
          stdoutText `shouldContain` "child_cluster_id=child-a"
          stdoutText `shouldContain` "metadata_kv_path=secret/clusters/child-a/metadata"
          stdoutText `shouldContain` "init_kv_path=secret/clusters/child-a/init"
          stdoutText `shouldContain` "bootstrap_kv_path=secret/clusters/child-a/bootstrap"
          stdoutText `shouldContain` "children_index_kv_path=secret/clusters/index"
          stdoutText `shouldContain` "child_bootstrap_secret=vault/vault-transit-seal-token"
          stdoutText `shouldNotContain` "s.child-transit"

          kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
          kubectlRecord `shouldContain` ("--kubeconfig|" ++ childKubeconfig ++ "|apply|-f|")
          applyManifest <-
            readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "vault-transit-seal-token"
          applyManifest `shouldContain` "\"namespace\":\"vault\""
          applyManifest `shouldContain` "\"name\":\"vault-transit-seal-token\""

    it
      "Sprint 8.8: nuke runs the total teardown on the typed confirmation and destroys the retained-cert state bucket"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          repoRoot <- getCurrentDirectory
          writeRepoMarkers tmpDir
          writeFile
            (tmpDir </> "test-secrets.dhall")
            (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
          writeRootBasics tmpDir (fakeVaultAddress vaultPort) validConfigForNuke
          createDirectoryIfMissing True (tmpDir </> ".kube")
          writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"
          -- Step 1 (aws-ses destroy) runs `pulumi` in the aws-ses program dir;
          -- provide it so the long-lived backend login/destroy can chdir there.
          createDirectoryIfMissing True (tmpDir </> "pulumi" </> "aws-ses")
          mapM_
            ( \name ->
                copyFile
                  (repoRoot </> "pulumi" </> "aws-ses" </> name)
                  (tmpDir </> "pulumi" </> "aws-ses" </> name)
            )
            ["Pulumi.yaml", "Main.yaml", "Pulumi.aws-ses.yaml"]
          envVars <- fakeRke2Environment tmpDir
          let nukeEnv =
                ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
                  : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                  : envVars

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary ["nuke"]) {cwd = Just tmpDir, env = Just nukeEnv}
              "NUKE EVERYTHING\n"

          when
            (exitCode /= ExitSuccess)
            (expectationFailure (unlines ["nuke stdout:", stdoutText, "nuke stderr:", stderrText]))
          exitCode `shouldBe` ExitSuccess
          stdoutText `shouldContain` "step 1/5 aws-ses destroy complete"
          stdoutText `shouldContain` "step 2/5 cluster cascade complete"
          stdoutText `shouldContain` "step 3/5 operational IAM teardown complete"
          stdoutText `shouldContain` "step 4/5 postflight tag sweep complete"
          -- Step 5 (complete) destroyed the long-lived `pulumi_state_backend`
          -- bucket where the retained public-edge certificate lives — the only
          -- path that removes it (per the Sprint 4.24 LongLived classification).
          stdoutText `shouldContain` "step 5/5 long-lived state-bucket destroy complete"
          stdoutText `shouldContain` "prodbox nuke: total teardown complete."

    it "projects ZeroSSL external account binding into the supported ClusterIssuer reconcile" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 zeroSslConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir

        -- The refactor moved the ZeroSSL ACME ClusterIssuer (and the Route 53
        -- DNS bootstrap) behind `--with-edge`; bare `cluster reconcile` stands
        -- up a local-only cluster with no public edge. The EAB projection this
        -- test asserts therefore lives on the `--with-edge` path.
        (upExitCode, upStdout, upStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "reconcile", "--with-edge"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        when
          (upExitCode /= ExitSuccess)
          ( expectationFailure
              ( unlines
                  [ "cluster reconcile stdout:"
                  , upStdout
                  , "cluster reconcile stderr:"
                  , upStderr
                  ]
              )
          )
        upExitCode `shouldBe` ExitSuccess
        upStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        upStdout `shouldContain` "Kubernetes control plane is running"

        applyManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "\"externalAccountBinding\""
        applyManifest `shouldContain` "\"ClusterIssuer\""
        applyManifest `shouldContain` "\"externalAccountBinding\""
        -- The EAB key ID is the host-resolved (Vault-sourced) value, rendered
        -- inline on the issuer (it is not secret). The keySecretRef points at
        -- the materialized Secret.
        applyManifest `shouldContain` "\"keyID\":\"test-eab-key-id\""
        applyManifest `shouldContain` "\"name\":\"acme-eab-credentials\""
        applyManifest `shouldContain` "\"namespace\":\"cert-manager\""
        -- Sprint 7.15: the EAB HMAC key is materialized from Vault by a
        -- Vault-login Job, not rendered as inline plaintext stringData. The
        -- materializer + its RBAC are present; the HMAC value never appears.
        applyManifest `shouldContain` "acme-eab-secret-materializer"
        applyManifest `shouldContain` "vault-materialized"
        applyManifest `shouldContain` "hmac_key"
        applyManifest `shouldNotContain` "test-eab-hmac-key"
        applyManifest `shouldNotContain` "\"stringData\":{\"secret\":"

    it "runs native gateway start and fails gracefully with a missing config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        let configPath = tmpDir </> "nonexistent-gateway.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "gateway daemon Dhall config"

    it "runs native gateway start without requiring repo markers" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "nonexistent-gateway.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "gateway daemon Dhall config"
        stderrText `shouldNotContain` "Could not locate the repository root"

    it "runs native config setup through the built frontend with a fake AWS CLI" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        envVars <- fakeAwsEnvironment tmpDir

        let inputText =
              unlines
                [ ""
                , "ADMINKEY"
                , "admin-secret"
                , ""
                , ""
                , "1"
                , "1"
                , ""
                , "ops@resolvefintech.com"
                , "test-eab-key-id"
                , "test-eab-hmac-key"
                , "1"
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                ]

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "setup"]) {cwd = Just tmpDir, env = Just envVars}
            inputText

        let failureOutput =
              unlines
                [ "config setup stdout:"
                , stdoutText
                , "config setup stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure failureOutput)
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "ROUTE53_ZONE_ID=Z1234567890ABC"
        stdoutText `shouldContain` "AWS_ACCESS_KEY_ID=AKIAFAKESETUP"
        configText <- readFile (tmpDir </> "prodbox.dhall")
        -- Sprint 1.42 Part B: `config setup` now authors the operator config into
        -- prodbox.dhall's `parameters` block, rendered canonically by Dhall.inject
        -- (no `Config.SecretRef.Vault` schema-qualified syntax). The sensitive
        -- AWS access key is a Vault pointer (mount/path/field), never plaintext.
        configText `shouldContain` ">.Vault"
        configText `shouldContain` "path = \"gateway/gateway/aws\""
        configText `shouldContain` "field = \"access_key_id\""
        configText `shouldNotContain` "AKIAFAKESETUP"
        configText `shouldContain` "zone_id = \"Z1234567890ABC\""
        configText `shouldContain` "demo_fqdn = \"test.resolvefintech.com\""
        configText `shouldContain` "public_edge_advertisement_mode = Some \"l2\""
        -- Sprint 7.15: the prompted EAB key ID + HMAC key are written to Vault
        -- (secret/acme/eab), never persisted into prodbox.dhall. The
        -- config references them through a Vault SecretRef pointer.
        configText `shouldContain` "eab_hmac_key = Some"
        configText `shouldContain` "field = \"hmac_key\""
        configText `shouldNotContain` "test-eab-hmac-key"
        configText `shouldNotContain` "test-eab-key-id"
        setupVaultAccessKey <- readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "access_key_id"
        setupVaultAccessKey `shouldBe` "AKIAFAKESETUP"
        setupVaultEabKeyId <- readFakeVaultField tmpDir "secret" acmeEabVaultPath "key_id"
        setupVaultEabKeyId `shouldBe` "test-eab-key-id"
        setupVaultEabHmacKey <- readFakeVaultField tmpDir "secret" acmeEabVaultPath "hmac_key"
        setupVaultEabHmacKey `shouldBe` "test-eab-hmac-key"
        jsonExists <- doesFileExist (tmpDir </> "prodbox-config.json")
        jsonExists `shouldBe` False

    it "runs native aws setup and teardown through the built frontend with a fake AWS CLI" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
        envVars <- fakeAwsEnvironment tmpDir

        let setupInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]
        (setupExitCode, setupStdout, setupStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "setup", "--tier", "full"]) {cwd = Just tmpDir, env = Just envVars}
            setupInput

        setupExitCode `shouldBe` ExitSuccess
        setupStderr `shouldBe` ""
        setupStdout `shouldContain` "IAM_USER=prodbox"
        setupStdout `shouldContain` "POLICY_TIER=full"
        setupStdout `shouldContain` "AWS_ACCESS_KEY_ID=AKIAFAKESETUP"

        configAfterSetup <- readFile (tmpDir </> "prodbox.dhall")
        -- Sprint 1.42 Part B: the operator config is merged into prodbox.dhall's
        -- `parameters` block, canonically rendered by Dhall.inject. The AWS access
        -- key stays a Vault pointer (path/field), never a plaintext credential.
        configAfterSetup `shouldContain` "path = \"gateway/gateway/aws\""
        configAfterSetup `shouldContain` "field = \"access_key_id\""
        configAfterSetup `shouldNotContain` "AKIAFAKESETUP"
        vaultAccessKeyAfterSetup <- readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "access_key_id"
        vaultAccessKeyAfterSetup `shouldBe` "AKIAFAKESETUP"
        setupAdminKey <- readFile (tmpDir </> "fake-aws-state" </> "iam_create_user_access_key_id")
        setupAdminKey `shouldContain` "ADMINKEY"
        route53ProbeKey <-
          readFile (tmpDir </> "fake-aws-state" </> "route53_get_hosted_zone_access_key_id")
        route53ProbeKey `shouldContain` "AKIAFAKESETUP"

        let teardownInput = unlines ["ADMINKEY", "admin-secret", "", ""]
        (teardownExitCode, teardownStdout, teardownStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "teardown"]) {cwd = Just tmpDir, env = Just envVars}
            teardownInput

        teardownExitCode `shouldBe` ExitSuccess
        teardownStderr `shouldBe` ""
        teardownStdout `shouldContain` "USER_DELETED=true"
        teardownStdout `shouldContain` "DELETED_ACCESS_KEYS=1"

        configAfterTeardown <- readFile (tmpDir </> "prodbox.dhall")
        configAfterTeardown `shouldContain` "path = \"gateway/gateway/aws\""
        configAfterTeardown `shouldContain` "field = \"access_key_id\""
        configAfterTeardown `shouldNotContain` "AKIAFAKESETUP"
        configAfterTeardown `shouldNotContain` "fake-secret-access-key"
        vaultAccessKeyAfterTeardown <-
          readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "access_key_id"
        vaultSecretKeyAfterTeardown <-
          readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "secret_access_key"
        vaultAccessKeyAfterTeardown `shouldBe` ""
        vaultSecretKeyAfterTeardown `shouldBe` ""
        teardownAdminKey <- readFile (tmpDir </> "fake-aws-state" </> "iam_delete_user_access_key_id")
        teardownAdminKey `shouldContain` "ADMINKEY"

    it
      "runs native aws-iam validation through the shared harness and clears leaked operational credentials"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
        seedFakeVaultAwsCredentials
          tmpDir
          gatewayAwsVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          "us-west-2"
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "aws-iam"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldContain` "[validation=aws-iam substrate=home-local] entering body"
        stderrText `shouldContain` "[validation=aws-iam substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "Phase 1/2: validating integration prerequisites"
        stdoutText `shouldContain` "Phase 2/2: running test suites"
        stdoutText `shouldContain` "Validation: aws-iam"
        stdoutText `shouldContain` "PREEXISTING_OPERATIONAL_USER=leaked-user"
        stdoutText `shouldContain` "PREFLIGHT_OPERATIONAL_CONFIG_CLEARED=true"
        stdoutText `shouldContain` "IAM_USER=prodbox"
        stdoutText `shouldContain` "CREDENTIAL_SOURCE=iam-user"
        stdoutText `shouldContain` "IAM_PRINCIPAL=iam-user"
        stdoutText `shouldContain` "POST_RUN_OPERATIONAL_CONFIG_CLEARED=true"

        configAfterHarness <- readFile (tmpDir </> "prodbox.dhall")
        configAfterHarness `shouldContain` "path = \"gateway/gateway/aws\""
        configAfterHarness `shouldContain` "field = \"access_key_id\""
        configAfterHarness `shouldNotContain` "AKIALEAKED"
        configAfterHarness `shouldNotContain` "leaked-secret"
        vaultAccessKeyAfterHarness <- readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "access_key_id"
        vaultSecretKeyAfterHarness <-
          readFakeVaultField tmpDir "secret" gatewayAwsVaultPath "secret_access_key"
        vaultAccessKeyAfterHarness `shouldBe` ""
        vaultSecretKeyAfterHarness `shouldBe` ""

        deletedUsers <- fmap lines (readFile (tmpDir </> "fake-aws-state" </> "iam_deleted_users"))
        deletedUsers `shouldBe` ["prodbox", "leaked-user", "prodbox"]

    it
      "seeds the ACME EAB into Vault non-interactively from test-secrets.dhall's acme_eab block"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeFile
          (tmpDir </> "prodbox.dhall")
          (wrapTier0 validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          ( testSecretsDhallWithAdminAndAcmeEab
              "CONFIGADMINKEY"
              "config-admin-secret"
              "us-west-2"
              Nothing
              "test-eab-key-id"
              "test-eab-hmac-key"
          )
        seedFakeVaultAwsCredentials
          tmpDir
          gatewayAwsVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          "us-west-2"
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, _stdoutText, _stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "aws-iam"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        exitCode `shouldBe` ExitSuccess

        -- The suite-level IAM harness preflight materialized the ACME EAB into
        -- the fake Vault at secret/acme/eab from the acme_eab fixture block,
        -- the non-interactive analog of `prodbox config setup`'s EAB prompt.
        eabKeyId <- readFakeVaultField tmpDir "secret" acmeEabVaultPath "key_id"
        eabHmacKey <- readFakeVaultField tmpDir "secret" acmeEabVaultPath "hmac_key"
        eabKeyId `shouldBe` "test-eab-key-id"
        eabHmacKey `shouldBe` "test-eab-hmac-key"

    it
      "runs native aws quota inspection and request flows through the built frontend with a fake AWS CLI"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        envVars <- fakeAwsEnvironment tmpDir
        let commandInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]

        (checkExitCode, checkStdout, checkStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "quotas", "check"]) {cwd = Just tmpDir, env = Just envVars}
            commandInput

        checkExitCode `shouldBe` ExitSuccess
        checkStderr `shouldBe` ""
        checkStdout `shouldContain` "Supported AWS Quotas"
        checkStdout `shouldContain` "Running On-Demand Standard vCPU"
        checkStdout `shouldContain` "Elastic IP addresses"

        (requestExitCode, requestStdout, requestStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "quotas", "request", "--tier", "core"]) {cwd = Just tmpDir, env = Just envVars}
            commandInput

        requestExitCode `shouldBe` ExitSuccess
        requestStderr `shouldBe` ""
        requestStdout `shouldContain` "Requested AWS Quotas"
        requestStdout `shouldContain` "PENDING"
        requestStdout `shouldContain` "Running On-Demand Standard vCPU"

resolveBinaryPath :: IO FilePath
resolveBinaryPath = do
  repoRoot <- getCurrentDirectory
  currentEnvironment <- getEnvironment
  buildEnvironment <- addBuildSupportEnvironment repoRoot currentEnvironment
  (buildExitCode, _, buildStderr) <-
    readCreateProcessWithExitCode
      (proc "cabal" ["build", "--builddir=.build", "exe:prodbox"])
        { cwd = Just repoRoot
        , env = Just buildEnvironment
        }
      ""
  case buildExitCode of
    ExitSuccess -> pure ()
    _ -> expectationFailure buildStderr
  syncResult <- syncBuiltOperatorBinary repoRoot buildEnvironment
  case syncResult of
    Left err -> expectationFailure err >> pure ""
    Right binaryPath -> do
      binaryPath `shouldBe` canonicalOperatorBinaryPath repoRoot
      pure binaryPath

writeRepoMarkers :: FilePath -> IO ()
writeRepoMarkers repoRoot = do
  writeFile (repoRoot </> "prodbox.cabal") "name: temp\n"
  createDirectoryIfMissing True (repoRoot </> "DEVELOPMENT_PLAN")
  writeFile (repoRoot </> "DEVELOPMENT_PLAN/README.md") "# temp\n"
  createDirectoryIfMissing True (repoRoot </> "pulumi" </> "aws-test")
  writeFile (repoRoot </> "pulumi" </> "aws-test" </> "Pulumi.yaml") "name: aws-test\nruntime: yaml\n"
  createDirectoryIfMissing True (repoRoot </> "pulumi" </> "aws-eks")
  writeFile
    (repoRoot </> "pulumi" </> "aws-eks" </> "Pulumi.yaml")
    "name: aws-eks-test\nruntime: yaml\n"

copySchema :: FilePath -> FilePath -> IO ()
copySchema sourceRoot targetRoot =
  copyFile (sourceRoot </> "prodbox-config-types.dhall") (targetRoot </> "prodbox-config-types.dhall")

gatewayStateResponseJson :: String
gatewayStateResponseJson =
  "{\"node_id\":\"node-a\",\"gateway_owner\":\"node-a\",\"has_active_claim\":true,\"mesh_peers\":[\"node-b\"],\"event_count\":5,\"last_public_ip_observed\":\"203.0.113.10\",\"last_dns_write_ip\":\"203.0.113.10\",\"last_dns_write_at_utc\":\"2026-04-06T10:00:00Z\",\"dns_write_gate\":{\"zone_id\":\"Z123\",\"fqdn\":\"test.resolvefintech.com\",\"ttl\":60},\"heartbeat_age_seconds\":{\"node-a\":0.0,\"node-b\":1.5}}"

sealedVaultStatusJson :: String
sealedVaultStatusJson =
  "{\"initialized\":true,\"sealed\":true,\"t\":3,\"n\":5,\"progress\":0}"

-- | Run @action@ against an ephemeral 127.0.0.1 HTTP server that serves
-- @body@ as JSON once. Returns the loopback port and an 'MVar' holding
-- the first line of the request the server received (e.g. @GET /v1/state HTTP/1.1@).
-- Used by the gateway-status integration test to verify the native HTTP client
-- path that replaced curl shell-outs in Sprint 2.17.
withGatewayStateServer
  :: String
  -> (Int -> MVar String -> IO a)
  -> IO a
withGatewayStateServer body action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 1
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating a test port")
          requestRef <- newEmptyMVar
          let response =
                "HTTP/1.1 200 OK\r\n"
                  ++ "Content-Type: application/json\r\n"
                  ++ "Content-Length: "
                  ++ show (length body)
                  ++ "\r\n"
                  ++ "Connection: close\r\n"
                  ++ "\r\n"
                  ++ body
          void $ forkIO $ do
            acceptResult <- try (accept sock)
            case acceptResult :: Either SomeException (Socket, SockAddr) of
              Left _ -> pure ()
              Right (client, _) -> do
                requestBytes <- recv client 8192
                let requestText = BS8.unpack requestBytes
                    firstLine = takeWhile (/= '\r') requestText
                putMVar requestRef firstLine
                _ <- try (sendAll client (BS8.pack response)) :: IO (Either SomeException ())
                close client
          action port requestRef
      )

allocateTwoLoopbackTcpPorts :: IO (Int, Int)
allocateTwoLoopbackTcpPorts =
  withSocketsDo $
    bracket
      ( do
          first <- socket AF_INET Stream defaultProtocol
          setSocketOption first ReuseAddr 1
          bind first (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          second <- socket AF_INET Stream defaultProtocol
          setSocketOption second ReuseAddr 1
          bind second (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          pure (first, second)
      )
      (\(first, second) -> close first >> close second)
      ( \(first, second) -> do
          firstAddr <- getSocketName first
          secondAddr <- getSocketName second
          case (firstAddr, secondAddr) of
            (SockAddrInet firstPort _, SockAddrInet secondPort _) ->
              pure (fromIntegral firstPort, fromIntegral secondPort)
            _ -> ioError (userError "expected IPv4 socket addresses while allocating test ports")
      )

waitForGatewayReadyProcess :: Int -> ProcessHandle -> FilePath -> FilePath -> IO ()
waitForGatewayReadyProcess port processHandle stdoutPath stderrPath = go (60 :: Int)
 where
  go 0 = failWithGatewayLogs "gateway daemon did not become ready"
  go attempts = do
    exitStatus <- getProcessExitCode processHandle
    case exitStatus of
      Just code -> failWithGatewayLogs ("gateway daemon exited before readiness: " ++ show code)
      Nothing -> pure ()
    result <-
      httpGetText
        (defaultHttpConfig {httpRequestTimeoutMicros = 250000})
        ("http://127.0.0.1:" ++ show port ++ "/readyz")
    case result of
      Right "ready\n" -> pure ()
      _ -> threadDelay 100000 >> go (attempts - 1)

  failWithGatewayLogs message = do
    stdoutText <- readFile stdoutPath
    stderrText <- readFile stderrPath
    expectationFailure
      ( unlines
          [ message
          , "gateway stdout:"
          , stdoutText
          , "gateway stderr:"
          , stderrText
          ]
      )

expectHttpText :: String -> IO String
expectHttpText url = do
  result <- httpGetText (HttpConfig 1000000) url
  case result of
    Left err -> expectationFailure (renderHttpError err) >> pure ""
    Right body -> pure body

withFakeVaultServer :: (Int -> IO a) -> IO a
withFakeVaultServer action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 16
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating fake Vault port")
          void $ forkIO (fakeVaultAcceptLoop sock)
          action port
      )

fakeVaultAcceptLoop :: Socket -> IO ()
fakeVaultAcceptLoop sock = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      let requestText = BS8.unpack requestBytes
          body = fakeVaultResponseBody requestText
          response =
            "HTTP/1.1 200 OK\r\n"
              ++ "Content-Type: application/json\r\n"
              ++ "Content-Length: "
              ++ show (length body)
              ++ "\r\n"
              ++ "Connection: close\r\n"
              ++ "\r\n"
              ++ body
      _ <- try (sendAll client (BS8.pack response)) :: IO (Either SomeException ())
      close client
      fakeVaultAcceptLoop sock

fakeVaultResponseBody :: String -> String
fakeVaultResponseBody requestText
  | "GET /v1/sys/seal-status" `isInfixOf` requestText =
      "{\"initialized\":true,\"sealed\":false,\"t\":3,\"n\":5,\"progress\":0}"
  | "POST /v1/auth/kubernetes/login" `isInfixOf` requestText =
      "{\"auth\":{\"client_token\":\"fake-vault-token\"}}"
  | "GET /v1/secret/data/clusters/index" `isInfixOf` requestText =
      fakeVaultKvPayload "{\"children\":[\"child-a\"]}"
  | "GET /v1/secret/data/clusters/child-a/metadata" `isInfixOf` requestText =
      fakeVaultKvPayload
        ( "{\"cluster_id\":\"child-a\","
            ++ "\"vault_address\":\"http://child-vault.example:8200\","
            ++ "\"transit_key\":\"prodbox-child-opaque\","
            ++ "\"vault_namespace\":\"ns-opaque\","
            ++ "\"parent_cluster_id\":\"prodbox-home\","
            ++ "\"endpoints\":{\"api\":\"https://api.child-a.example\"},"
            ++ "\"kubeconfig_reference\":\"vault:secret/clusters/child-a/kubeconfig\","
            ++ "\"account_id\":\"123456789012\","
            ++ "\"pulumi_stacks\":{\"aws-eks\":\"org/prodbox-child-a/aws-eks\"}}"
        )
  | "GET /v1/secret/data/clusters/child-a/bootstrap" `isInfixOf` requestText =
      fakeVaultKvPayload
        ( "{\"cluster_id\":\"child-a\","
            ++ "\"parent_vault_address\":\"http://parent-vault.example:8200\","
            ++ "\"transit_key\":\"prodbox-child-opaque\","
            ++ "\"vault_namespace\":\"ns-opaque\","
            ++ "\"token\":\"s.child-transit\"}"
        )
  | "GET /v1/secret/data/" `isInfixOf` requestText =
      "{\"data\":{\"data\":{\"key\":\"validation-key\",\"access_key_id\":\"test-access-key\",\"secret_access_key\":\"test-secret-key\",\"session_token\":\"test-session-token\",\"minio_access_key\":\"minio-access\",\"minio_secret_key\":\"minio-secret\",\"rootUser\":\"minio-root\",\"rootPassword\":\"minio-root-secret\"}}}"
  | otherwise =
      "{}"

fakeVaultKvPayload :: String -> String
fakeVaultKvPayload payload =
  "{\"data\":{\"data\":{\"payload_json\":" ++ show payload ++ "}}}"

data FakeVaultLifecycleState = FakeVaultLifecycleState
  { fakeVaultLifecycleInitialized :: Bool
  , fakeVaultLifecycleSealed :: Bool
  , fakeVaultLifecycleProgress :: Int
  }
  deriving (Eq, Show)

data FakeVaultHttpResponse = FakeVaultHttpResponse
  { fakeVaultHttpStatus :: Int
  , fakeVaultHttpBody :: String
  }

withFakeVaultLifecycleServer :: (Int -> MVar FakeVaultLifecycleState -> IO a) -> IO a
withFakeVaultLifecycleServer action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 32
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating fake Vault lifecycle port")
          stateRef <- newMVar (FakeVaultLifecycleState False True 0)
          void $ forkIO (fakeVaultLifecycleAcceptLoop sock stateRef)
          action port stateRef
      )

fakeVaultLifecycleAcceptLoop :: Socket -> MVar FakeVaultLifecycleState -> IO ()
fakeVaultLifecycleAcceptLoop sock stateRef = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      response <- fakeVaultLifecycleResponse (BS8.unpack requestBytes) stateRef
      _ <-
        try (sendAll client (BS8.pack (renderFakeVaultResponse response)))
          :: IO (Either SomeException ())
      close client
      fakeVaultLifecycleAcceptLoop sock stateRef

fakeVaultLifecycleResponse
  :: String -> MVar FakeVaultLifecycleState -> IO FakeVaultHttpResponse
fakeVaultLifecycleResponse requestText stateRef
  | "GET /v1/sys/seal-status" `isInfixOf` requestText = do
      state <- readMVar stateRef
      pure (fakeVaultOk (fakeVaultSealStatusJson state))
  | "POST /v1/sys/init" `isInfixOf` requestText =
      modifyMVar stateRef $ \_ -> do
        let initializedState = FakeVaultLifecycleState True True 0
        pure (initializedState, fakeVaultOk fakeVaultInitJson)
  | "POST /v1/sys/unseal" `isInfixOf` requestText =
      modifyMVar stateRef $ \state -> do
        let unsealedState = state {fakeVaultLifecycleSealed = False, fakeVaultLifecycleProgress = 3}
        pure (unsealedState, fakeVaultOk (fakeVaultSealStatusJson unsealedState))
  | "PUT /v1/sys/seal" `isInfixOf` requestText =
      modifyMVar stateRef $ \state -> do
        let sealedState = state {fakeVaultLifecycleSealed = True, fakeVaultLifecycleProgress = 0}
        pure (sealedState, fakeVaultOk "{}")
  | "GET /v1/sys/mounts" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultMountsJson)
  | "GET /v1/sys/auth" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultAuthJson)
  | "GET /v1/secret/data/federation/hmac" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"data\":{\"data\":{\"key\":\"integration-federation-hmac\"}}}")
  | "GET /v1/transit/keys/" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"data\":{\"type\":\"aes256-gcm96\"}}")
  | "GET /v1/secret/data/" `isInfixOf` requestText =
      pure (FakeVaultHttpResponse 404 "{\"errors\":[\"missing secret\"]}")
  | "POST /v1/auth/token/create" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"auth\":{\"client_token\":\"s.child-transit\"}}")
  | "POST /v1/pki/issue/prodbox-test" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultPkiCertificateJson)
  | "POST /v1/" `isInfixOf` requestText =
      pure (fakeVaultOk "{}")
  | otherwise =
      pure (fakeVaultOk "{}")

renderFakeVaultResponse :: FakeVaultHttpResponse -> String
renderFakeVaultResponse response =
  "HTTP/1.1 "
    ++ show (fakeVaultHttpStatus response)
    ++ " "
    ++ fakeVaultReasonPhrase (fakeVaultHttpStatus response)
    ++ "\r\n"
    ++ "Content-Type: application/json\r\n"
    ++ "Content-Length: "
    ++ show (length (fakeVaultHttpBody response))
    ++ "\r\n"
    ++ "Connection: close\r\n"
    ++ "\r\n"
    ++ fakeVaultHttpBody response

fakeVaultOk :: String -> FakeVaultHttpResponse
fakeVaultOk = FakeVaultHttpResponse 200

fakeVaultReasonPhrase :: Int -> String
fakeVaultReasonPhrase statusCode
  | statusCode == 200 = "OK"
  | statusCode == 404 = "Not Found"
  | otherwise = "OK"

fakeVaultSealStatusJson :: FakeVaultLifecycleState -> String
fakeVaultSealStatusJson state =
  "{\"initialized\":"
    ++ fakeJsonBool (fakeVaultLifecycleInitialized state)
    ++ ",\"sealed\":"
    ++ fakeJsonBool (fakeVaultLifecycleSealed state)
    ++ ",\"t\":3,\"n\":5,\"progress\":"
    ++ show (fakeVaultLifecycleProgress state)
    ++ "}"

fakeJsonBool :: Bool -> String
fakeJsonBool value =
  if value then "true" else "false"

fakeVaultInitJson :: String
fakeVaultInitJson =
  "{\"keys_base64\":[\"vault-unseal-key-1\",\"vault-unseal-key-2\",\"vault-unseal-key-3\",\"vault-unseal-key-4\",\"vault-unseal-key-5\"],\"root_token\":\"fake-root-token\"}"

fakeVaultMountsJson :: String
fakeVaultMountsJson =
  "{\"secret/\":{\"type\":\"kv\",\"options\":{\"version\":\"2\"}},\"transit/\":{\"type\":\"transit\",\"options\":{}},\"pki/\":{\"type\":\"pki\",\"options\":{}}}"

fakeVaultAuthJson :: String
fakeVaultAuthJson =
  "{\"kubernetes/\":{\"type\":\"kubernetes\"}}"

fakeVaultPkiCertificateJson :: String
fakeVaultPkiCertificateJson =
  "{\"data\":{\"certificate\":\"-----BEGIN CERTIFICATE-----\\nFAKE\\n-----END CERTIFICATE-----\\n\"}}"

fakeVaultAddress :: Int -> String
fakeVaultAddress port = "http://127.0.0.1:" ++ show port

fakeVaultLifecycleEnvironment :: Int -> IO [(String, String)]
fakeVaultLifecycleEnvironment port = do
  currentEnvironment <- getEnvironment
  pure
    ( ("PRODBOX_TEST_HOST_VAULT_ADDR", fakeVaultAddress port)
        : filter
          ( \(key, _) ->
              key /= "PRODBOX_TEST_HOST_VAULT_ADDR"
                && key /= "PRODBOX_TEST_HOST_VAULT_TOKEN"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV"
          )
          currentEnvironment
    )

writeFakeVaultToken :: FilePath -> IO ()
writeFakeVaultToken path = writeFile path "fake-service-account-jwt\n"

-- | Sprint 7.18 / Sprint 1.42 Part B: establish the root sealed-Vault bootstrap
-- floor by writing the Tier-0 @prodbox.dhall@ at the repo root. The floor is
-- projected straight off @prodbox.dhall@'s @context@ (there is no separate
-- @prodbox-basics.json@), so a root context with the supplied Vault address,
-- Shamir seal mode, and no parent ref is the whole floor surface the binary's
-- 'loadUnencryptedBasics' reads. The same file now also carries the operator
-- config under @parameters@ (the retired @prodbox-config.dhall@ payload), so a
-- command that loads the operator config — federation register, nuke — reads it
-- from the one Tier-0 file. @prodbox.dhall@ is self-contained (no imports), so
-- this single record is sufficient.
writeRootBasics :: FilePath -> String -> String -> IO ()
writeRootBasics repoRoot vaultAddress configParameters =
  writeFile
    (repoRoot </> "prodbox.dhall")
    ( unlines
        [ "{ parameters = " ++ configParameters
        , ", context ="
        , "    { project = \"prodbox\""
        , "    , binary = \"prodbox\""
        , "    , context_kind = < HostOrchestrator | Daemon | ClusterService | OtherContext >.HostOrchestrator"
        , "    , cluster_id = \"prodbox-home\""
        , "    , vault_address = \"" ++ vaultAddress ++ "\""
        , "    , minio_endpoint = \"http://minio.prodbox.svc.cluster.local:9000\""
        , "    , minio_bucket = \"prodbox-state\""
        , "    , topology ="
        , "        { seal_mode = < Tier0Shamir | Tier0Transit >.Tier0Shamir"
        , "        , parent_ref ="
        , "            None"
        , "              { parent_cluster_id : Text"
        , "              , parent_vault_address : Text"
        , "              , parent_transit_key : Text"
        , "              }"
        , "        }"
        , "    , capabilities = [ < DurableStore | VaultAuth | PublicEdge | OtherCapability >.DurableStore, < DurableStore | VaultAuth | PublicEdge | OtherCapability >.VaultAuth ]"
        , "    }"
        , ", witness = [] : List Text"
        , "}"
        ]
    )

-- | Sprint 7.16: the test-harness cleartext fixture (@test-secrets.dhall@).
-- Carries the unlock-bundle password plus the EPHEMERAL admin AWS credential
-- the harness feeds into the same interactive admin prompt a real operator
-- would answer. Decoded structurally by @inputFile auto@, so no schema import
-- is required. This base value leaves the admin block empty (the vault
-- lifecycle test only needs the password).
testSecretsDhall :: String
testSecretsDhall = testSecretsDhallWithAdmin "" "" "" Nothing

-- | Sprint 5.10 follow-up: the deferred operator-id fields the harness injects
-- from @test-secrets.dhall@ (the Route 53 zone, the SES sending/receive/capture
-- identifiers, and the long-lived Pulumi state backend). A bare Dhall record
-- literal must carry every field the Haskell @TestSecrets@ decoder expects;
-- these CLI flows don't exercise those substrates, so the values are empty.
testSecretsOperatorIdFields :: [String]
testSecretsOperatorIdFields =
  [ ", route53_zone_id = \"\""
  , ", ses_sender_domain = \"\""
  , ", ses_receive_subdomain = \"\""
  , ", ses_capture_bucket = \"\""
  , ", pulumi_state_backend_bucket_name = \"\""
  , ", pulumi_state_backend_region = \"\""
  ]

-- | A @test-secrets.dhall@ with a populated @aws_admin_for_test_simulation@
-- block, so the suite-level IAM harness acquires the ephemeral admin credential
-- non-interactively (the harness simulating the prompt).
testSecretsDhallWithAdmin :: String -> String -> String -> Maybe String -> String
testSecretsDhallWithAdmin accessKeyId secretAccessKey regionValue sessionTokenValue =
  unlines $
    ["{ vault_operator_password = \"test-vault-unlock-password\""]
      ++ testSecretsOperatorIdFields
      ++ [ ", aws_admin_for_test_simulation ="
         , "    { access_key_id = " ++ show accessKeyId
         , "    , secret_access_key = " ++ show secretAccessKey
         , "    , session_token = "
             ++ maybe "None Text" (\token -> "Some " ++ show token) sessionTokenValue
         , "    , region = " ++ show regionValue
         , "    }"
         , -- Sprint 7.18: the optional ACME EAB block. A bare Dhall record literal
           -- must still carry every field the Haskell decoder expects, so the
           -- Optional `acme_eab` is rendered explicitly as `None`. Tests that
           -- exercise EAB seeding use `testSecretsDhallWithAdminAndAcmeEab`.
           ", acme_eab = None { key_id : Text, hmac_key : Text }"
         , "}"
         ]

-- | Sprint 7.18: a @test-secrets.dhall@ that also populates the optional
-- @acme_eab@ block, so the suite-level IAM harness seeds @secret/acme/eab@
-- non-interactively (the harness simulating the interactive @config setup@ EAB
-- prompt). Placeholder EAB values only — never real ZeroSSL credentials.
testSecretsDhallWithAdminAndAcmeEab
  :: String -> String -> String -> Maybe String -> String -> String -> String
testSecretsDhallWithAdminAndAcmeEab accessKeyId secretAccessKey regionValue sessionTokenValue eabKeyId eabHmacKey =
  unlines $
    ["{ vault_operator_password = \"test-vault-unlock-password\""]
      ++ testSecretsOperatorIdFields
      ++ [ ", aws_admin_for_test_simulation ="
         , "    { access_key_id = " ++ show accessKeyId
         , "    , secret_access_key = " ++ show secretAccessKey
         , "    , session_token = "
             ++ maybe "None Text" (\token -> "Some " ++ show token) sessionTokenValue
         , "    , region = " ++ show regionValue
         , "    }"
         , ", acme_eab = Some { key_id = " ++ show eabKeyId ++ ", hmac_key = " ++ show eabHmacKey ++ " }"
         , "}"
         ]

secretRefTypeDhall :: String
secretRefTypeDhall =
  "< Vault : { mount : Text, path : Text, field : Text }"
    ++ " | TransitKey : Text"
    ++ " | Prompt : { name : Text, purpose : Text }"
    ++ " | TestPlaintext : Text"
    ++ " >"

vaultSecretRefDhall :: String -> String -> String -> String
vaultSecretRefDhall mount path field =
  unlines
    [ secretRefTypeDhall ++ ".Vault"
    , "  { mount = " ++ show mount
    , "  , path = " ++ show path
    , "  , field = " ++ show field
    , "  }"
    ]

gatewayAwsVaultPath :: String
gatewayAwsVaultPath = "gateway/gateway/aws"

-- | Sprint 7.15: the Vault KV logical path that holds the ZeroSSL EAB
-- material (key ID + HMAC key) seeded by @prodbox config setup@.
acmeEabVaultPath :: String
acmeEabVaultPath = "acme/eab"

-- | Sprint 7.15: a @Some SecretRef.Vault@ expression into @secret/acme/eab@
-- for the given field, in the schema-less inline-union style the integration
-- fixtures use. The EAB material now references Vault rather than carrying
-- plaintext.
eabVaultRefDhall :: String -> String
eabVaultRefDhall field =
  "Some (" ++ vaultSecretRefDhall "secret" acmeEabVaultPath field ++ ")"

awsCredentialRefDhall :: String -> String -> Bool -> String
awsCredentialRefDhall path regionValue includeSessionToken =
  concat
    [ "{ access_key_id = "
    , vaultSecretRefDhall "secret" path "access_key_id"
    , ", secret_access_key = "
    , vaultSecretRefDhall "secret" path "secret_access_key"
    , ", session_token = "
    , if includeSessionToken
        then "Some (" ++ vaultSecretRefDhall "secret" path "session_token" ++ ")"
        else "None (" ++ secretRefTypeDhall ++ ")"
    , ", region = "
    , show regionValue
    , " }"
    ]

fakeVaultKvDir :: FilePath -> FilePath
fakeVaultKvDir repoRoot = repoRoot </> "fake-vault-kv"

seedFakeVaultAwsCredentials
  :: FilePath -> String -> String -> String -> Maybe String -> String -> IO ()
seedFakeVaultAwsCredentials repoRoot path accessKeyId secretAccessKey sessionTokenValue regionValue = do
  writeFakeVaultField repoRoot "secret" path "access_key_id" accessKeyId
  writeFakeVaultField repoRoot "secret" path "secret_access_key" secretAccessKey
  writeFakeVaultField repoRoot "secret" path "session_token" (maybe "" id sessionTokenValue)
  writeFakeVaultField repoRoot "secret" path "region" regionValue

writeFakeVaultField :: FilePath -> String -> String -> String -> String -> IO ()
writeFakeVaultField repoRoot mount path field value = do
  let objectDir = fakeVaultKvDir repoRoot </> mount </> path
  createDirectoryIfMissing True objectDir
  writeFile (objectDir </> field) value

readFakeVaultField :: FilePath -> String -> String -> String -> IO String
readFakeVaultField repoRoot mount path field =
  readFile (fakeVaultKvDir repoRoot </> mount </> path </> field)

indentFixture :: Int -> String -> String
indentFixture spaces =
  unlines . map (replicate spaces ' ' ++) . lines

fakeAwsEnvironment :: FilePath -> IO [(String, String)]
fakeAwsEnvironment repoRoot = do
  fakeBin <- writeFakeAwsScript repoRoot
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      filtered =
        filter
          ( \(k, _) ->
              k /= "PATH"
                && k /= "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"
                && k /= "PRODBOX_TEST_RESIDUE_ABSENT"
                && k /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_RESIDUE_ABSENT", "1")
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : filtered
    )

fakeAwsHarnessEnvironment :: FilePath -> FilePath -> IO [(String, String)]
fakeAwsHarnessEnvironment repoRoot binaryPath = do
  fakeBin <- writeFakeAwsScript repoRoot
  writeExecutable (fakeBin </> "cabal") (fakeCabalListBinScript binaryPath)
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      filtered =
        filter
          ( \(k, _) ->
              k /= "PATH"
                && k /= "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"
                && k /= "PRODBOX_TEST_RESIDUE_ABSENT"
                && k /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_RESIDUE_ABSENT", "1")
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : filtered
    )

writeFakeAwsScript :: FilePath -> IO FilePath
writeFakeAwsScript repoRoot = do
  let binDir = repoRoot </> "bin"
      stateDir = repoRoot </> "fake-aws-state"
      scriptPath = binDir </> "aws"
  createDirectoryIfMissing True binDir
  createDirectoryIfMissing True stateDir
  writeFile scriptPath (fakeAwsScript stateDir)
  permissions <- getPermissions scriptPath
  setPermissions scriptPath permissions {executable = True}
  pure binDir

fakeChartEnvironment :: FilePath -> IO [(String, String)]
fakeChartEnvironment repoRoot = do
  fakeBin <- writeFakeChartScripts repoRoot
  let recordDir = repoRoot </> "fake-chart-state"
  createDirectoryIfMissing True recordDir
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      baseEnvironment =
        filter
          ( \(key, _) ->
              key /= "PATH"
                && key /= "PRODBOX_FAKE_CHART_RECORD_DIR"
                && key /= "PRODBOX_FAKE_HELM_LIST_JSON"
                && key /= "PRODBOX_FAKE_PATRONI_STAGED_RESTORE"
                && key /= "PRODBOX_FAKE_PATRONI_LIVE_ANCHOR"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV"
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_CHART_RECORD_DIR", recordDir)
      , ("PRODBOX_FAKE_HELM_LIST_JSON", "[]")
      , ("PRODBOX_TEST_HOST_VAULT_KV", "allow")
      ]
        ++ baseEnvironment
    )

writeFakeChartScripts :: FilePath -> IO FilePath
writeFakeChartScripts repoRoot = do
  let binDir = repoRoot </> "bin"
  createDirectoryIfMissing True binDir
  writeExecutable (binDir </> "helm") fakeHelmScript
  writeExecutable (binDir </> "kubectl") fakeKubectlScript
  pure binDir

writeExecutable :: FilePath -> String -> IO ()
writeExecutable scriptPath scriptContents = do
  writeFile scriptPath scriptContents
  permissions <- getPermissions scriptPath
  setPermissions scriptPath permissions {executable = True}

fakeHelmScript :: String
fakeHelmScript =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_CHART_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "case \"${1:-}\" in"
    , "  list)"
    , "    printf '%s\\n' \"${PRODBOX_FAKE_HELM_LIST_JSON:-[]}\""
    , "    ;;"
    , "  upgrade)"
    , "    append_args \"$record_dir/helm-upgrade.txt\" \"$@\""
    , "    ;;"
    , "  uninstall)"
    , "    append_args \"$record_dir/helm-uninstall.txt\" \"$@\""
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake helm command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeKubectlScript :: String
fakeKubectlScript =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_CHART_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "next_apply_target() {"
    , "  local counter_file=\"$record_dir/kubectl-apply.count\""
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s/kubectl-apply-%s.json' \"$record_dir\" \"$count\""
    , "}"
    , "next_counter() {"
    , "  local counter_file=$1"
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s' \"$count\""
    , "}"
    , "append_args \"$record_dir/kubectl.txt\" \"$@\""
    , "case \"${1:-} ${2:-}\" in"
    , "  'get nodes')"
    , "    cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"bathurst\"}}]}"
    , "JSON"
    , "    ;;"
    , "  'get crd')"
    , "    if [[ \"${3:-}\" == 'perconapgclusters.pgv2.percona.com' ]]; then"
    , "      printf 'customresourcedefinition.apiextensions.k8s.io/perconapgclusters.pgv2.percona.com\\n'"
    , "    else"
    , "      printf 'Error from server (NotFound): customresourcedefinitions \"%s\" not found\\n' \"${3:-crd}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get deployment')"
    , "    if [[ \"${3:-}\" == 'postgres-operator' && \"$*\" == *'--namespace postgres-operator'* ]]; then"
    , "      printf 'deployment.apps/postgres-operator\\n'"
    , "    else"
    , "      printf 'Error from server (NotFound): deployments \"%s\" not found\\n' \"${3:-deployment}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get perconapgclusters.pgv2.percona.com')"
    , "    if [[ \"$*\" == *'jsonpath={.status.state}'* ]]; then"
    , "      printf 'ready\\n'"
    , "    elif [[ \"$*\" == *'jsonpath={.status.postgres.ready}'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_STAGED_RESTORE:-}\" == 'true' ]]; then"
    , "        ready_count=$(next_counter \"$record_dir/patroni-ready.count\")"
    , "        if [[ \"$ready_count\" -eq 1 ]]; then"
    , "          printf '1\\n'"
    , "        else"
    , "          printf '3\\n'"
    , "        fi"
    , "      else"
    , "        printf '3\\n'"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): perconapgclusters \"%s\" not found\\n' \"${3:-perconapgclusters.pgv2.percona.com}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get endpoints')"
    , "    if [[ \"${3:-}\" == 'prodbox-vscode-pg-ha' && \"$*\" == *'jsonpath={.subsets[0].addresses[0].targetRef.name}'* ]] && { [[ \"${PRODBOX_FAKE_PATRONI_LIVE_ANCHOR:-}\" == 'true' ]] || [[ -f \"$record_dir/patroni-ready.count\" ]]; }; then"
    , "      printf 'prodbox-vscode-pg-instance1-0\\n'"
    , "    else"
    , "      printf 'Error from server (NotFound): endpoints \"%s\" not found\\n' \"${3:-endpoints}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get pvc')"
    , "    if [[ \"${3:-}\" == 'prodbox-vscode-pg-instance1-0-pgdata' && \"$*\" == *'jsonpath={.spec.volumeName}'* ]]; then"
    , "      printf 'prodbox-retained-vscode-prodbox-vscode-pg-0\\n'"
    , "    elif [[ \"$*\" == *'postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_STAGED_RESTORE:-}\" == 'true' ]]; then"
    , "        claim_list_count=$(next_counter \"$record_dir/patroni-claim-list.count\")"
    , "        if [[ \"$claim_list_count\" -eq 1 ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-0-pgdata\"}}]}"
    , "JSON"
    , "          exit 0"
    , "        fi"
    , "      fi"
    , "      cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-0-pgdata\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-1-pgdata\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-2-pgdata\"}}]}"
    , "JSON"
    , "    else"
    , "      printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get secret')"
    , "    if [[ \"$*\" == *'--ignore-not-found=true'* ]]; then"
    , "      # Sprint 8.7 public-edge cert preserve/restore reads the"
    , "      # public-edge-tls Secret with --ignore-not-found=true. Real kubectl"
    , "      # returns exit 0 with empty output for an absent resource; the Secret"
    , "      # is modeled absent in the charts suite, so honor the flag."
    , "      exit 0"
    , "    elif [[ \"$*\" == *'go-template={{index .data \"password\" | base64decode}}'* ]]; then"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    else"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get certificate.cert-manager.io')"
    , "    if [[ \"$*\" == *'--ignore-not-found=true'* ]]; then"
    , "      # Sprint 8.7 public-edge cert preserve reads the Certificate with"
    , "      # --ignore-not-found=true; modeled absent, so exit 0 with empty output."
    , "      exit 0"
    , "    fi"
    , "    printf 'Error from server (NotFound): certificates \"%s\" not found\\n' \"${3:-certificate}\" >&2"
    , "    exit 1"
    , "    ;;"
    , "  'get pv')"
    , "    printf 'Error from server (NotFound): persistentvolumes \"%s\" not found\\n' \"${3:-pv}\" >&2"
    , "    exit 1"
    , "    ;;"
    , "  'apply -f')"
    , "    target=$(next_apply_target)"
    , "    if [[ \"${3:-}\" == \"-\" ]]; then"
    , "      # Sprint 2.19: `kubectl apply -f -` (stdin) is the second leg of the"
    , "      # `create namespace --dry-run | apply -f -` and `create secret"
    , "      # generic --dry-run | apply -f -` pipelines used by"
    , "      # ensureGatewayMinioBootstrap. Capture stdin to the apply-target file."
    , "      cat > \"$target\""
    , "    else"
    , "      cp \"${3:?}\" \"$target\""
    , "    fi"
    , "    ;;"
    , "  'delete pod'|'delete pvc'|'delete pv'|'delete namespace')"
    , "    append_args \"$record_dir/kubectl-delete.txt\" \"$@\""
    , "    ;;"
    , "  'create namespace')"
    , "    # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the gateway"
    , "    # namespace via `kubectl create namespace ... --dry-run=client -o yaml`"
    , "    # piped to `kubectl apply -f -`. The fake replies with a minimal"
    , "    # namespace manifest so the dry-run leg succeeds; the apply-f-stdin"
    , "    # leg is handled by the existing `apply -f -` arm."
    , "    append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "    printf 'apiVersion: v1\\nkind: Namespace\\nmetadata:\\n  name: %s\\n' \"${3:-}\""
    , "    ;;"
    , "  'create secret')"
    , "    # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the"
    , "    # gateway-minio-creds Secret via `kubectl create secret generic ...`"
    , "    # with --dry-run=client. The fake replies with a minimal Secret"
    , "    # manifest so the dry-run leg succeeds."
    , "    append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "    printf 'apiVersion: v1\\nkind: Secret\\nmetadata:\\n  name: %s\\ntype: Opaque\\n' \"${4:-secret}\""
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake kubectl command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

-- | Override a fake RKE2 environment to model the real already-deleted-cluster
-- host: no RKE2 install present, and the in-cluster MinIO residue backend
-- unreachable. Used by the Sprint 4.25 no-op-success delete tests to prove the
-- short-circuit wins over the Sprint 4.19 fail-closed residue gate.
withNoRke2Install :: [(String, String)] -> [(String, String)]
withNoRke2Install baseEnvVars =
  ("PRODBOX_TEST_RKE2_PRESENT", "0")
    : ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
    : filter (not . overridden . fst) baseEnvVars
 where
  overridden key =
    key
      `elem` [ "PRODBOX_TEST_RKE2_PRESENT"
             , "PRODBOX_TEST_RESIDUE_ABSENT"
             , "PRODBOX_TEST_RESIDUE_UNREACHABLE"
             ]

fakeRke2Environment :: FilePath -> IO [(String, String)]
fakeRke2Environment repoRoot = do
  fakeBin <- writeFakeRke2Scripts repoRoot
  let recordDir = repoRoot </> "fake-rke2-state"
      socketPath = repoRoot </> "fake-rke2-containerd.sock"
      endpointStatusRoot = repoRoot </> "fake-endpoint-status"
  createDirectoryIfMissing True recordDir
  writeFile socketPath ""
  createDirectoryIfMissing True endpointStatusRoot
  writeFile (endpointStatusRoot </> "rke2-pod.status") ""
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      baseEnvironment =
        filter
          ( \(key, _) ->
              key
                `notElem` [ "PATH"
                          , "PRODBOX_FAKE_RKE2_RECORD_DIR"
                          , "PRODBOX_RKE2_CONTAINERD_SOCKET"
                          , "PRODBOX_RKE2_ENDPOINT_STATUS_ROOT"
                          , "PRODBOX_TEST_RESIDUE_ABSENT"
                          , "PRODBOX_TEST_RESIDUE_UNREACHABLE"
                          , "PRODBOX_TEST_RKE2_PRESENT"
                          , "PRODBOX_TEST_PULUMI_VAULT_GATE"
                          , "PRODBOX_TEST_HOST_VAULT_KV"
                          , "PRODBOX_TEST_ROOT_VAULT_LIFECYCLE"
                          , "PRODBOX_TEST_CLUSTER_VAULT_STATUS"
                          , "PRODBOX_TEST_HOST_CAPACITY"
                          , "HOME"
                          ]
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_RKE2_RECORD_DIR", recordDir)
      , ("PRODBOX_RKE2_CONTAINERD_SOCKET", socketPath)
      , ("PRODBOX_RKE2_ENDPOINT_STATUS_ROOT", endpointStatusRoot)
      , -- These reconcile/delete tests model a no-AWS-substrate host where the
        -- per-run Pulumi stacks are genuinely absent. Declare that so the
        -- Sprint 4.19 fail-closed delete gate sees ResidueAbsent (pass) rather
        -- than ResidueUnreachable (refuse) from the fake/unreachable MinIO.
        ("PRODBOX_TEST_RESIDUE_ABSENT", "1")
      , -- These reconcile/delete tests model a host with an RKE2 install
        -- present, so the no-cluster short-circuit in 'rke2 delete' must NOT
        -- fire and the gate/cascade paths run as before. Production probes the
        -- real on-disk markers; see 'rke2InstallPresent' in 'Prodbox.CLI.Rke2'.
        ("PRODBOX_TEST_RKE2_PRESENT", "1")
      , ("PRODBOX_TEST_PULUMI_VAULT_GATE", "allow")
      , ("PRODBOX_TEST_HOST_VAULT_KV", "allow")
      , ("PRODBOX_TEST_ROOT_VAULT_LIFECYCLE", "ready")
      , ("PRODBOX_TEST_CLUSTER_VAULT_STATUS", "ready")
      ,
        ( "PRODBOX_TEST_HOST_CAPACITY"
        , "milli_cpu=16000,memory_mib=49152,ephemeral_storage_mib=300000,durable_storage_mib=800000"
        )
      , ("HOME", repoRoot)
      ]
        ++ baseEnvironment
    )

writeFakeRke2Scripts :: FilePath -> IO FilePath
writeFakeRke2Scripts repoRoot = do
  let binDir = repoRoot </> "bin"
  createDirectoryIfMissing True binDir
  writeExecutable (binDir </> "systemctl") fakeSystemctlScript
  writeExecutable (binDir </> "journalctl") fakeJournalctlScript
  writeExecutable (binDir </> "sudo") fakeSudoScript
  writeExecutable (binDir </> "test") fakeRke2TestScript
  writeExecutable (binDir </> "curl") fakeRke2CurlScript
  writeExecutable (binDir </> "kubectl") fakeRke2KubectlScript
  writeExecutable (binDir </> "helm") fakeRke2HelmScript
  writeExecutable (binDir </> "docker") fakeRke2DockerScript
  writeExecutable (binDir </> "ctr") fakeRke2CtrScript
  writeExecutable (binDir </> "mkdir") fakeRke2MkdirScript
  writeExecutable (binDir </> "cp") fakeRke2CpScript
  writeExecutable (binDir </> "chown") fakeRke2ChownScript
  writeExecutable (binDir </> "chmod") fakeRke2ChmodScript
  writeExecutable (binDir </> "rm") fakeRke2RmScript
  writeExecutable (binDir </> "cat") fakeRke2CatScript
  writeExecutable (binDir </> "sysctl") fakeRke2SysctlScript
  writeExecutable (binDir </> "pulumi") fakeRke2PulumiScript
  writeExecutable (binDir </> "aws") fakeRke2AwsScript
  writeExecutable (binDir </> "bash") fakeRke2BashScript
  pure binDir

fakeSystemctlScript :: String
fakeSystemctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "append_args \"$record_dir/systemctl.txt\" \"$@\""
    , "case \"${1:-}\" in"
    , "  --version)"
    , "    printf 'systemd 255\\n'"
    , "    ;;"
    , "  is-active)"
    , "    printf 'active\\n'"
    , "    ;;"
    , "  start|stop|restart|enable|disable|daemon-reload)"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake systemctl command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeJournalctlScript :: String
fakeJournalctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , ": > \"$record_dir/journalctl.txt\""
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/journalctl.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/journalctl.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/journalctl.txt\""
    , "printf 'RKE2_LOG_LINES\\n'"
    ]

-- NOTE: This fake uninstaller emits `Failed to allocate directory watch: Too many open
-- files` on the child's own stderr (`>&2`), which exercises only the CAPTURABLE path that
-- `captureToolOutput` suppresses on success / `isIgnorableRke2DeleteNoiseLine` filters on
-- failure. The real warning is emitted out-of-band by the systemd manager (PID 1) / journald
-- to the console and is NOT reproduced here, so the `shouldNotContain` assertions below prove
-- only that the quiet path hides the line when it lands on the uninstaller's own streams —
-- not that operators never see the out-of-band emission. See streaming_doctrine.md §6.
fakeSudoScript :: String
fakeSudoScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/sudo.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/sudo.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/sudo.txt\""
    , "if [[ \"${1:-}\" == '--version' ]]; then"
    , "  printf 'sudo 1.9.15\\n'"
    , "  exit 0"
    , "fi"
    , "if [[ \"${1:-}\" == '/usr/local/bin/rke2-uninstall.sh' && \"${PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS:-0}\" == '1' ]]; then"
    , "  printf '+ systemctl stop rke2-server.service\\n'"
    , "  printf 'Cannot find device \"cni0\"\\n' >&2"
    , "  printf '/usr/local/bin/rke2-uninstall.sh: 162: semodule: not found\\n' >&2"
    , "  printf 'Failed to allocate directory watch: Too many open files\\n' >&2"
    , "  printf '[2026-04-20 09:17:01] Cleanup completed successfully\\n'"
    , "  if [[ \"${PRODBOX_FAKE_RKE2_UNINSTALL_FAIL:-0}\" == '1' ]]; then"
    , "    printf 'umount: /var/lib/kubelet/pods/abc: target is busy\\n' >&2"
    , "    exit 1"
    , "  fi"
    , "  exit 0"
    , "fi"
    , "exec \"$@\""
    ]

fakeRke2TestScript :: String
fakeRke2TestScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/test.txt\""
    , "case \"$*\" in"
    , "  '-x /usr/local/bin/rke2')"
    , "    exit 1"
    , "    ;;"
    , "  '-x /usr/local/bin/rke2-uninstall.sh')"
    , "    if [[ \"${PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS:-0}\" == '1' ]]; then"
    , "      exit 0"
    , "    fi"
    , "    exit 1"
    , "    ;;"
    , "  *)"
    , "    exec /usr/bin/test \"$@\""
    , "    ;;"
    , "esac"
    ]

fakeRke2CurlScript :: String
fakeRke2CurlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/curl.txt\""
    , "if [[ \"$*\" == *'https://get.rke2.io'* ]]; then"
    , "  out=''"
    , "  while [[ $# -gt 0 ]]; do"
    , "    if [[ \"${1:-}\" == '-o' ]]; then"
    , "      out=${2:-}"
    , "      break"
    , "    fi"
    , "    shift"
    , "  done"
    , "  printf '#!/usr/bin/env bash\\nexit 0\\n' > \"$out\""
    , "  exit 0"
    , "fi"
    , "if [[ \"$*\" == *'https://api.ipify.org'* ]]; then"
    , "  printf '198.51.100.24'"
    , "  exit 0"
    , "fi"
    , "if [[ \"$*\" == *'/api/v2.0/projects/'* && \"$*\" == *'-X DELETE'* ]]; then"
    , "  printf '200'"
    , "  exit 0"
    , "fi"
    , "if [[ \"$*\" == *'http://127.0.0.1:30080/readyz'* ]]; then"
    , "  printf '200'"
    , "  exit 0"
    , "fi"
    , "if [[ \"$*\" == *'http://127.0.0.1:30080/v2/'* ]]; then"
    , "  printf '401'"
    , "  exit 0"
    , "fi"
    , "if [[ \"$*\" == *'/api/v2.0/projects'* ]]; then"
    , "  printf '201'"
    , "  exit 0"
    , "fi"
    , "printf 'unsupported fake curl command: %s\\n' \"$*\" >&2"
    , "exit 1"
    ]

fakeRke2KubectlScript :: String
fakeRke2KubectlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:-${HOME:?}/fake-rke2-state}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "next_apply_target() {"
    , "  local counter_file=\"$record_dir/kubectl-apply.count\""
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s/kubectl-apply-%s.json' \"$record_dir\" \"$count\""
    , "}"
    , "append_args \"$record_dir/kubectl.txt\" \"$@\""
    , "if [[ \"${1:-}\" == '--kubeconfig' ]]; then"
    , "  shift 2"
    , "fi"
    , "case \"${1:-}\" in"
    , "  cluster-info)"
    , "    printf 'Kubernetes control plane is running\\n'"
    , "    ;;"
    , "  version)"
    , "    if [[ \"$*\" == *'--client=true'* ]]; then"
    , "      printf 'Client Version: v1.33.0\\n'"
    , "    else"
    , "      printf 'unsupported fake kubectl version command: %s\\n' \"$*\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  api-resources)"
    , "    if [[ \"$*\" == *'--namespaced=true'* ]]; then"
    , "      printf 'deployments.apps\\nconfigmaps\\n'"
    , "    else"
    , "      printf 'clusterroles.rbac.authorization.k8s.io\\n'"
    , "    fi"
    , "    ;;"
    , "  get)"
    , "    case \"${2:-}\" in"
    , "      nodes)"
    , "        if [[ \"$*\" == *'-o|json'* || \"$*\" == *'-o json'* ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"bathurst\"}}]}"
    , "JSON"
    , "        elif [[ \"$*\" == *'-o|name'* || \"$*\" == *'-o name'* ]]; then"
    , "          printf 'node/bathurst\\n'"
    , "        else"
    , "          printf 'bathurst'"
    , "        fi"
    , "        ;;"
    , "      storageclass)"
    , "        printf 'storageclass.storage.k8s.io/manual\\nstorageclass.storage.k8s.io/local-path\\n'"
    , "        ;;"
    , "      pv)"
    , "        if [[ \"${3:-}\" == '-o' && \"$*\" == *'jsonpath={range .items'* ]]; then"
    , "          # Empty success for the drain-time Delete-reclaim PV listing."
    , "          exit 0"
    , "        else"
    , "          printf 'Error from server (NotFound): persistentvolumes \"%s\" not found\\n' \"${3:-pv}\" >&2"
    , "          exit 1"
    , "        fi"
    , "        ;;"
    , "      pvc)"
    , "        printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
    , "        exit 1"
    , "        ;;"
    , "      resourcequota)"
    , "        if [[ \"$*\" == *'-o json'* ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"namespace\":\"keycloak\",\"name\":\"keycloak-resource-quota\"},\"spec\":{\"hard\":{\"requests.cpu\":\"3000m\",\"limits.cpu\":\"3000m\",\"requests.memory\":\"10000Mi\",\"limits.memory\":\"10000Mi\",\"requests.ephemeral-storage\":\"50000Mi\",\"limits.ephemeral-storage\":\"50000Mi\",\"requests.storage\":\"150000Mi\"}}},{\"metadata\":{\"namespace\":\"vscode\",\"name\":\"vscode-resource-quota\"},\"spec\":{\"hard\":{\"requests.cpu\":\"2000m\",\"limits.cpu\":\"2000m\",\"requests.memory\":\"5000Mi\",\"limits.memory\":\"5000Mi\",\"requests.ephemeral-storage\":\"30000Mi\",\"limits.ephemeral-storage\":\"30000Mi\",\"requests.storage\":\"100000Mi\"}}},{\"metadata\":{\"namespace\":\"api\",\"name\":\"api-resource-quota\"},\"spec\":{\"hard\":{\"requests.cpu\":\"1500m\",\"limits.cpu\":\"1500m\",\"requests.memory\":\"2000Mi\",\"limits.memory\":\"2000Mi\",\"requests.ephemeral-storage\":\"10000Mi\",\"limits.ephemeral-storage\":\"10000Mi\",\"requests.storage\":\"1000Mi\"}}},{\"metadata\":{\"namespace\":\"websocket\",\"name\":\"websocket-resource-quota\"},\"spec\":{\"hard\":{\"requests.cpu\":\"1000m\",\"limits.cpu\":\"1000m\",\"requests.memory\":\"2000Mi\",\"limits.memory\":\"2000Mi\",\"requests.ephemeral-storage\":\"10000Mi\",\"limits.ephemeral-storage\":\"10000Mi\",\"requests.storage\":\"1000Mi\"}}},{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"gateway-resource-quota\"},\"spec\":{\"hard\":{\"requests.cpu\":\"4000m\",\"limits.cpu\":\"4000m\",\"requests.memory\":\"10000Mi\",\"limits.memory\":\"10000Mi\",\"requests.ephemeral-storage\":\"60000Mi\",\"limits.ephemeral-storage\":\"60000Mi\",\"requests.storage\":\"100000Mi\"}}}]}"
    , "JSON"
    , "        fi"
    , "        ;;"
    , "      limitrange)"
    , "        if [[ \"$*\" == *'-o json'* ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"namespace\":\"keycloak\",\"name\":\"keycloak-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\",\"defaultRequest\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"default\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"2048Mi\"}}]}},{\"metadata\":{\"namespace\":\"vscode\",\"name\":\"vscode-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\",\"defaultRequest\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"default\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"4096Mi\"}}]}},{\"metadata\":{\"namespace\":\"api\",\"name\":\"api-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\",\"defaultRequest\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"default\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}]}},{\"metadata\":{\"namespace\":\"websocket\",\"name\":\"websocket-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\",\"defaultRequest\":{\"cpu\":\"100m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"default\":{\"cpu\":\"250m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}]}},{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"gateway-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\",\"defaultRequest\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"default\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}]}}]}"
    , "JSON"
    , "        fi"
    , "        ;;"
    , "      configmap)"
    , "        /bin/cat <<'EOF'"
    , "server {"
    , "  location / {"
    , "    proxy_pass http://core;"
    , "  }"
    , "}"
    , "EOF"
    , "        ;;"
    , "      secret)"
    , "        if [[ \"${3:-}\" == 'minio' && \"$*\" == *'rootUser'* ]]; then"
    , "          printf 'minioadmin'"
    , "        elif [[ \"${3:-}\" == 'minio' && \"$*\" == *'rootPassword'* ]]; then"
    , "          printf 'minioadmin123'"
    , "        elif [[ \"${3:-}\" == 'gateway-minio-creds' ]]; then"
    , "          # Sprint 2.19: readGatewayMinioCredsSecret probes for an existing"
    , "          # Secret; absence is the happy path for first reconcile (fresh"
    , "          # credentials get generated)."
    , "          printf 'Error from server (NotFound): secrets \"gateway-minio-creds\" not found\\n' >&2"
    , "          exit 1"
    , "        elif [[ \"${3:-}\" == *'-pguser-keycloak' && \"$*\" == *'--ignore-not-found=true'* ]]; then"
    , "          # The chart platform treats the Percona operator pguser Secret as"
    , "          # optional during a fresh reconcile; absent means the post-readiness"
    , "          # sync is a no-op and will be retried later."
    , "          exit 0"
    , "        else"
    , "          printf 'unsupported fake secret lookup: %s\\n' \"$*\" >&2"
    , "          exit 1"
    , "        fi"
    , "        ;;"
    , "      deployments.apps)"
    , "        if [[ \"$*\" == *'-n prodbox'* ]]; then"
    , "          printf 'deployment.apps/prodbox-api\\n'"
    , "        fi"
    , "        ;;"
    , "      configmaps)"
    , "        if [[ \"$*\" == *'-n prodbox'* ]]; then"
    , "          printf 'configmap/existing-config\\n'"
    , "        fi"
    , "        ;;"
    , "      clusterroles.rbac.authorization.k8s.io)"
    , "        if [[ \"$*\" == *'app.kubernetes.io/instance=harbor'* ]]; then"
    , "          printf 'clusterrole.rbac.authorization.k8s.io/harbor-role\\n'"
    , "        fi"
    , "        ;;"
    , "      crd)"
    , "        printf 'customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io\\n'"
    , "        ;;"
    , "      pods)"
    , "        if [[ \"$*\" == *'-o json'* ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"namespace\":\"keycloak\",\"name\":\"keycloak-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"keycloak\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"2048Mi\"}}}]}},{\"metadata\":{\"namespace\":\"vscode\",\"name\":\"vscode-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"vscode\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"4096Mi\"}}}]}},{\"metadata\":{\"namespace\":\"api\",\"name\":\"api-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"api\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"websocket\",\"name\":\"websocket-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"websocket\",\"resources\":{\"requests\":{\"cpu\":\"100m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"gateway-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"gateway\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}}]}"
    , "JSON"
    , "        else"
    , "          printf 'docker.io/library/busybox:latest\\ngoharbor/harbor-core:v2\\n'"
    , "        fi"
    , "        ;;"
    , "      *)"
    , "        ;;"
    , "    esac"
    , "    ;;"
    , "  exec)"
    , "    if [[ \"$*\" == *'statefulset/minio'* && \"$*\" == *'/proc/self/mountinfo'* ]]; then"
    , "      printf '14443 14435 8:2 /tmp/prodbox/minio/0 /export rw,relatime - ext4 /dev/sda2 rw\\n'"
    , "    else"
    , "      printf 'unsupported fake kubectl exec command: %s\\n' \"$*\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  wait|rollout)"
    , "    ;;"
    , "  port-forward)"
    , "    trap 'exit 0' TERM INT"
    , "    while true; do"
    , "      sleep 1"
    , "    done"
    , "    ;;"
    , "  apply)"
    , "    target=$(next_apply_target)"
    , "    if [[ \"${3:-}\" == \"-\" ]]; then"
    , "      # Sprint 2.19: `kubectl apply -f -` (stdin) is the second leg of the"
    , "      # `create namespace --dry-run | apply -f -` and `create secret"
    , "      # generic --dry-run | apply -f -` pipelines used by"
    , "      # ensureGatewayMinioBootstrap. Capture stdin to the apply-target file."
    , "      /bin/cat > \"$target\""
    , "    else"
    , "      /bin/cp \"${3:?}\" \"$target\""
    , "    fi"
    , "    ;;"
    , "  create)"
    , "    case \"${2:-}\" in"
    , "      namespace)"
    , "        # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the gateway"
    , "        # namespace via `kubectl create namespace ... --dry-run=client -o yaml`"
    , "        # piped to `kubectl apply -f -`. The fake replies with a minimal"
    , "        # namespace manifest so the dry-run leg succeeds; the apply-f-stdin"
    , "        # leg is handled by the `apply` arm above."
    , "        append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "        printf 'apiVersion: v1\\nkind: Namespace\\nmetadata:\\n  name: %s\\n' \"${3:-}\""
    , "        ;;"
    , "      secret)"
    , "        # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the"
    , "        # gateway-minio-creds Secret via `kubectl create secret generic ...`"
    , "        # with --dry-run=client. The fake replies with a minimal Secret"
    , "        # manifest so the dry-run leg succeeds."
    , "        append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "        printf 'apiVersion: v1\\nkind: Secret\\nmetadata:\\n  name: %s\\ntype: Opaque\\n' \"${4:-secret}\""
    , "        ;;"
    , "      *)"
    , "        printf 'unsupported fake kubectl create command: %s\\n' \"$*\" >&2"
    , "        exit 1"
    , "        ;;"
    , "    esac"
    , "    ;;"
    , "  patch|annotate|label)"
    , "    ;;"
    , "  delete)"
    , "    append_args \"$record_dir/kubectl-delete.txt\" \"$@\""
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake kubectl command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeRke2HelmScript :: String
fakeRke2HelmScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/helm.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/helm.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/helm.txt\""
    , "case \"${1:-}\" in"
    , "  list)"
    , "    printf '[]\\n'"
    , "    ;;"
    , "  *)"
    , "    ;;"
    , "esac"
    ]

fakeRke2DockerScript :: String
fakeRke2DockerScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , -- Harbor login isolation: record the DOCKER_CONFIG every prodbox docker
      -- call runs with, so the suite can prove it is the repo-local `.docker`
      -- (never the operator's global ~/.docker).
      "printf '%s\\n' \"${DOCKER_CONFIG:-UNSET}\" >> \"$record_dir/docker-config.txt\""
    , "target_key() {"
    , "  printf '%s' \"$1\" | tr '/:' '__'"
    , "}"
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/docker.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/docker.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/docker.txt\""
    , "case \"${1:-}\" in"
    , "  pull)"
    , "    ref=${2:-}"
    , "    if [[ \"$ref\" == 127.0.0.1:30080/* ]]; then"
    , "      if [[ -f \"$record_dir/pushed-$(target_key \"$ref\")\" ]]; then"
    , "        exit 0"
    , "      fi"
    , "      echo 'manifest unknown' >&2"
    , "      exit 1"
    , "    fi"
    , "    rate_limit_ref=${PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF:-}"
    , "    if [[ -n \"$rate_limit_ref\" && \"$ref\" == \"$rate_limit_ref\" ]]; then"
    , "      echo 'toomanyrequests: rate limit exceeded' >&2"
    , "      exit 1"
    , "    fi"
    , "    exit 0"
    , "    ;;"
    , "  tag)"
    , "    source_ref=${2:-}"
    , "    target_ref=${3:-}"
    , "    printf '%s' \"$source_ref\" > \"$record_dir/tag-$(target_key \"$target_ref\")\""
    , "    exit 0"
    , "    ;;"
    , "  push)"
    , "    target_ref=${2:-}"
    , "    tag_file=\"$record_dir/tag-$(target_key \"$target_ref\")\""
    , "    source_ref=''"
    , "    if [[ -f \"$tag_file\" ]]; then"
    , "      source_ref=$(/bin/cat \"$tag_file\")"
    , "    fi"
    , "    if [[ \"$source_ref\" == ghcr.io/coder/code-server:4.98.2 ]]; then"
    , "      echo '429 Too Many Requests' >&2"
    , "      exit 1"
    , "    fi"
    , "    : > \"$record_dir/pushed-$(target_key \"$target_ref\")\""
    , "    exit 0"
    , "    ;;"
    , "  build)"
    , "    ;;"
    , "  save)"
    , "    out=''"
    , "    while [[ $# -gt 0 ]]; do"
    , "      if [[ \"${1:-}\" == '-o' ]]; then"
    , "        out=${2:-}"
    , "        break"
    , "      fi"
    , "      shift"
    , "    done"
    , "    printf 'FAKE IMAGE ARCHIVE\\n' > \"$out\""
    , "    ;;"
    , "  *)"
    , "    ;;"
    , "esac"
    ]

fakeRke2CtrScript :: String
fakeRke2CtrScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/ctr.txt\""
    , "exit 0"
    ]

fakeRke2MkdirScript :: String
fakeRke2MkdirScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/mkdir.txt\""
    , "exit 0"
    ]

fakeRke2CpScript :: String
fakeRke2CpScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/cp.txt\""
    , "exit 0"
    ]

fakeRke2ChownScript :: String
fakeRke2ChownScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/chown.txt\""
    , "exit 0"
    ]

fakeRke2ChmodScript :: String
fakeRke2ChmodScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/chmod.txt\""
    , "exit 0"
    ]

fakeRke2RmScript :: String
fakeRke2RmScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/rm.txt\""
    , "exit 0"
    ]

fakeRke2CatScript :: String
fakeRke2CatScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/cat.txt\""
    , "printf 'cat: %s: No such file or directory\\n' \"${1:-file}\" >&2"
    , "exit 1"
    ]

fakeRke2SysctlScript :: String
fakeRke2SysctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/sysctl.txt\""
    , "exit 0"
    ]

fakeRke2PulumiScript :: String
fakeRke2PulumiScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${HOME:?}/fake-rke2-state"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/pulumi.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/pulumi.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/pulumi.txt\""
    , "case \"${1:-}\" in"
    , "  login)"
    , "    printf 'Logged in to fake-rke2 as matthewnowak (%s)\\n' \"${2:-}\""
    , "    ;;"
    , "  stack)"
    , "    case \"${2:-}\" in"
    , "      select)"
    , "        if [[ \"$*\" != *'--create'* && ( \"${3:-}\" == 'aws-eks-test' || \"${3:-}\" == 'aws-test' || \"${3:-}\" == 'aws-ses' ) ]]; then"
    , "          printf \"error: no stack named '%s' found\\n\" \"${3:-}\" >&2"
    , "          exit 1"
    , "        fi"
    , "        printf 'STACK_SELECTED=%s\\n' \"${3:-}\""
    , "        ;;"
    , "      rm)"
    , "        ;;"
    , "      *)"
    , "        printf 'unsupported fake pulumi stack command: %s\\n' \"$*\" >&2"
    , "        exit 1"
    , "        ;;"
    , "    esac"
    , "    ;;"
    , "  destroy|refresh)"
    , "    printf 'PULUMI_%s\\n' \"${1^^}\""
    , "    ;;"
    , "  config)"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake pulumi command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeRke2AwsScript :: String
fakeRke2AwsScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:-/tmp/prodbox-fake-rke2-state}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/aws.txt\""
    , "case \"$*\" in"
    , "  *'s3api head-bucket'*|*'s3api create-bucket'*)"
    , "    exit 0"
    , "    ;;"
    , "  *'s3api get-object'*)"
    , "    printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Not Found\\n' >&2"
    , "    exit 254"
    , "    ;;"
    , "  *'s3api delete-object'*)"
    , "    exit 0"
    , "    ;;"
    , "  *'route53 change-resource-record-sets'*)"
    , "    printf '{\"ChangeInfo\":{\"Status\":\"INSYNC\"}}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 3 (operational IAM teardown) — the"
    , "  # operational `prodbox` user is absent in this fixture, so the teardown"
    , "  # is a no-op."
    , "  *'sts get-caller-identity'*)"
    , "    printf '{\"Account\":\"123456789012\",\"UserId\":\"AIDAFAKEADMIN\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox-admin-temp\"}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'iam get-user'*)"
    , "    printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: The user with name prodbox cannot be found.\\n' >&2"
    , "    exit 254"
    , "    ;;"
    , "  *'iam list-access-keys'*)"
    , "    printf '{\"AccessKeyMetadata\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 4 (postflight tag sweep) — clean."
    , "  *'ec2 describe-volumes'*)"
    , "    printf '{\"Volumes\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'ec2 delete-volume'*)"
    , "    exit 0"
    , "    ;;"
    , "  *'resourcegroupstaggingapi get-resources'*)"
    , "    printf '{\"ResourceTagMappingList\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 5 (long-lived state-bucket destroy that"
    , "  # removes the retained public-edge cert)."
    , "  *'s3api list-object-versions'*)"
    , "    printf '{}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'s3 rm '*|*'s3api delete-objects'*|*'s3api delete-bucket'*)"
    , "    exit 0"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake aws command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeRke2BashScript :: String
fakeRke2BashScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/bash.txt\""
    , "if [[ \"${1:-}\" == '-c' && \"${2:-}\" == *'/dev/tcp/127.0.0.1/39000'* ]]; then"
    , "  exit 0"
    , "fi"
    , "exec /bin/bash \"$@\""
    ]

fakeAwsScript :: FilePath -> String
fakeAwsScript stateDir =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "STATE_DIR=\"" ++ stateDir ++ "\""
    , "/bin/mkdir -p \"$STATE_DIR\""
    , "user_exists_file() {"
    , "  printf '%s/user-%s-exists' \"$STATE_DIR\" \"$1\""
    , "}"
    , "user_policy_file() {"
    , "  printf '%s/user-%s-policy' \"$STATE_DIR\" \"$1\""
    , "}"
    , "user_key_file() {"
    , "  printf '%s/user-%s-access-key-id' \"$STATE_DIR\" \"$1\""
    , "}"
    , "identity_file() {"
    , "  printf '%s/identity-%s' \"$STATE_DIR\" \"$1\""
    , "}"
    , "append_line() {"
    , "  printf '%s\\n' \"$2\" >> \"$1\""
    , "}"
    , "aws_error() {"
    , "  local code=${1:?}"
    , "  local operation=${2:?}"
    , "  local message=${3:?}"
    , "  printf 'An error occurred (%s) when calling the %s operation: %s\\n' \"$code\" \"$operation\" \"$message\" >&2"
    , "  exit 254"
    , "}"
    , "if [[ \"${1:-}\" == \"--version\" ]]; then"
    , "  printf 'aws-cli/2.17.0 Python/3.12.0 Linux/6.8.0 exe/x86_64\\n'"
    , "  exit 0"
    , "fi"
    , "if [[ $# -ge 2 && \"${@: -2:1}\" == \"--output\" ]]; then"
    , "  set -- \"${@:1:$#-2}\""
    , "fi"
    , "service=${1:-}"
    , "action=${2:-}"
    , "case \"$service $action\" in"
    , "  \"ec2 describe-regions\")"
    , "    cat <<'JSON'"
    , "{\"Regions\":[{\"RegionName\":\"us-east-1\",\"OptInStatus\":\"opt-in-not-required\"},{\"RegionName\":\"us-west-2\",\"OptInStatus\":\"opt-in-not-required\"}]}"
    , "JSON"
    , "    ;;"
    , "  \"route53 list-hosted-zones\")"
    , "    cat <<'JSON'"
    , "{\"HostedZones\":[{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"resolvefintech.com\"}]}"
    , "JSON"
    , "    ;;"
    , "  \"route53 get-hosted-zone\")"
    , "    access_key_id=${AWS_ACCESS_KEY_ID:-}"
    , "    if [[ -f \"$(identity_file \"$access_key_id\")\" || \"$access_key_id\" == 'ASIAFAKEFED' || \"$access_key_id\" == 'ADMINKEY' || \"$access_key_id\" == 'CONFIGADMINKEY' ]]; then"
    , "      printf '%s\\n' \"$access_key_id\" > \"$STATE_DIR/route53_get_hosted_zone_access_key_id\""
    , "      cat <<'JSON'"
    , "{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"resolvefintech.com\"},\"DelegationSet\":{\"NameServers\":[\"ns-1.awsdns-01.com\"]}}"
    , "JSON"
    , "    else"
    , "      aws_error 'InvalidClientTokenId' 'GetHostedZone' 'The security token included in the request is invalid.'"
    , "    fi"
    , "    ;;"
    , "  \"iam create-user\")"
    , "    user_name=${4:-}"
    , "    if [[ -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'EntityAlreadyExists' 'CreateUser' \"User with name $user_name already exists.\""
    , "    fi"
    , "    printf '%s\\n' \"${AWS_ACCESS_KEY_ID:-}\" > \"$STATE_DIR/iam_create_user_access_key_id\""
    , "    touch \"$(user_exists_file \"$user_name\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam get-user\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'GetUser' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    printf '{\"User\":{\"UserName\":\"%s\",\"Arn\":\"arn:aws:iam::123456789012:user/%s\"}}\\n' \"$user_name\" \"$user_name\""
    , "    ;;"
    , "  \"iam list-access-keys\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'ListAccessKeys' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    if [[ -f \"$(user_key_file \"$user_name\")\" ]]; then"
    , "      access_key_id=$(cat \"$(user_key_file \"$user_name\")\")"
    , "      printf '{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"%s\"}]}\\n' \"$access_key_id\""
    , "    else"
    , "      printf '{\"AccessKeyMetadata\":[]}\\n'"
    , "    fi"
    , "    ;;"
    , "  \"iam delete-access-key\")"
    , "    user_name=${4:-}"
    , "    access_key_id=${6:-}"
    , "    append_line \"$STATE_DIR/iam_deleted_access_keys\" \"$user_name:$access_key_id\""
    , "    rm -f \"$(user_key_file \"$user_name\")\""
    , "    rm -f \"$(identity_file \"$access_key_id\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam put-user-policy\")"
    , "    user_name=${4:-}"
    , "    touch \"$(user_policy_file \"$user_name\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam create-access-key\")"
    , "    user_name=${4:-}"
    , "    printf 'AKIAFAKESETUP' > \"$(user_key_file \"$user_name\")\""
    , "    printf '%s' \"$user_name\" > \"$(identity_file 'AKIAFAKESETUP')\""
    , "    cat <<'JSON'"
    , "{\"AccessKey\":{\"AccessKeyId\":\"AKIAFAKESETUP\",\"SecretAccessKey\":\"fake-secret-access-key\"}}"
    , "JSON"
    , "    ;;"
    , "  \"iam delete-user-policy\")"
    , "    user_name=${4:-}"
    , "    if [[ -f \"$(user_policy_file \"$user_name\")\" ]]; then"
    , "      rm -f \"$(user_policy_file \"$user_name\")\""
    , "      printf '{}\\n'"
    , "    else"
    , "      aws_error 'NoSuchEntity' 'DeleteUserPolicy' \"The policy with name prodbox-inline cannot be found.\""
    , "    fi"
    , "    ;;"
    , "  \"iam delete-user\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'DeleteUser' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    printf '{}\\n'"
    , "    printf '%s\\n' \"${AWS_ACCESS_KEY_ID:-}\" > \"$STATE_DIR/iam_delete_user_access_key_id\""
    , "    append_line \"$STATE_DIR/iam_deleted_users\" \"$user_name\""
    , "    if [[ -f \"$(user_key_file \"$user_name\")\" ]]; then"
    , "      existing_access_key=$(cat \"$(user_key_file \"$user_name\")\")"
    , "      rm -f \"$(identity_file \"$existing_access_key\")\""
    , "    fi"
    , "    rm -f \"$(user_exists_file \"$user_name\")\" \"$(user_policy_file \"$user_name\")\" \"$(user_key_file \"$user_name\")\""
    , "    ;;"
    , "  \"service-quotas get-service-quota\")"
    , "    cat <<'JSON'"
    , "{\"Quota\":{\"Value\":8.0}}"
    , "JSON"
    , "    ;;"
    , "  \"service-quotas get-aws-default-service-quota\")"
    , "    cat <<'JSON'"
    , "{\"Quota\":{\"Value\":8.0}}"
    , "JSON"
    , "    ;;"
    , "  \"service-quotas request-service-quota-increase\")"
    , "    cat <<'JSON'"
    , "{\"RequestedQuota\":{\"Status\":\"PENDING\"}}"
    , "JSON"
    , "    ;;"
    , "  \"sts get-caller-identity\")"
    , "    access_key_id=${AWS_ACCESS_KEY_ID:-}"
    , "    if [[ \"$access_key_id\" == 'ASIAFAKEFED' ]]; then"
    , "      cat <<'JSON'"
    , "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:sts::123456789012:federated-user/prodbox\",\"UserId\":\"AIDAFederated:prodbox\"}"
    , "JSON"
    , "    elif [[ -f \"$(identity_file \"$access_key_id\")\" ]]; then"
    , "      user_name=$(cat \"$(identity_file \"$access_key_id\")\")"
    , "      printf '{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/%s\",\"UserId\":\"AIDAFake\"}\\n' \"$user_name\""
    , "    elif [[ \"$access_key_id\" == 'ADMINKEY' || \"$access_key_id\" == 'CONFIGADMINKEY' ]]; then"
    , "      cat <<'JSON'"
    , "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/temp-admin\",\"UserId\":\"AIDADmin\"}"
    , "JSON"
    , "    else"
    , "      aws_error 'InvalidClientTokenId' 'GetCallerIdentity' 'The security token included in the request is invalid.'"
    , "    fi"
    , "    ;;"
    , "  \"sts get-federation-token\")"
    , "    cat <<'JSON'"
    , "{\"Credentials\":{\"AccessKeyId\":\"ASIAFAKEFED\",\"SecretAccessKey\":\"fake-federated-secret\",\"SessionToken\":\"fake-federated-session\"}}"
    , "JSON"
    , "    ;;"
    , "  \"ec2 describe-volumes\")"
    , "    cat <<'JSON'"
    , "{\"Volumes\":[]}"
    , "JSON"
    , "    ;;"
    , "  \"ec2 delete-volume\")"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake aws command: %s %s\\n' \"$service\" \"$action\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeCabalListBinScript :: FilePath -> String
fakeCabalListBinScript binaryPath =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "if [[ \"$*\" == 'list-bin --builddir=.build exe:prodbox' ]]; then"
    , "  printf '%s\\n' '" ++ binaryPath ++ "'"
    , "else"
    , "  printf 'unsupported fake cabal command: %s\\n' \"$*\" >&2"
    , "  exit 1"
    , "fi"
    ]

seedFakeAwsHarnessState :: FilePath -> IO ()
seedFakeAwsHarnessState repoRoot = do
  let stateDir = repoRoot </> "fake-aws-state"
  createDirectoryIfMissing True stateDir
  writeFile (stateDir </> "user-prodbox-exists") ""
  writeFile (stateDir </> "user-prodbox-policy") ""
  writeFile (stateDir </> "user-prodbox-access-key-id") "AKIAOLDPRODBOX"
  writeFile (stateDir </> "identity-AKIAOLDPRODBOX") "prodbox"
  writeFile (stateDir </> "user-leaked-user-exists") ""
  writeFile (stateDir </> "user-leaked-user-policy") ""
  writeFile (stateDir </> "user-leaked-user-access-key-id") "AKIALEAKED"
  writeFile (stateDir </> "identity-AKIALEAKED") "leaked-user"

harborRegistryStorageSecretName :: String
harborRegistryStorageSecretName = "harbor-registry-s3"

harborRegistryStorageBucket :: String
harborRegistryStorageBucket = "prodbox-harbor-registry"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

minioClusterEndpoint :: String
minioClusterEndpoint = "http://minio.prodbox.svc.cluster.local:9000"

readAppliedManifestContaining :: FilePath -> String -> IO String
readAppliedManifestContaining stateDir needle = do
  applyFiles <- sort . filter ("kubectl-apply-" `isInfixOf`) <$> listDirectory stateDir
  manifests <- mapM (\fileName -> readFile (stateDir </> fileName)) applyFiles
  case find (isInfixOf needle) manifests of
    Just manifest -> pure manifest
    Nothing ->
      expectationFailure ("expected applied manifest containing " ++ show needle)
        >> pure ""

findRecordLineIndex :: String -> String -> Int
findRecordLineIndex needle haystack =
  case findIndex (isInfixOf needle) (lines haystack) of
    Just indexValue -> indexValue
    Nothing -> error ("missing record line containing " ++ show needle)

gatewayStartConfig :: Int -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> String
gatewayStartConfig vaultPort tokenPath ordersPath certPath keyPath caPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    Some"
    , "      { address = " ++ show (fakeVaultAddress vaultPort)
    , "      , auth_path = \"kubernetes\""
    , "      , role = \"gateway-gateway\""
    , "      , service_account_token_file = Some " ++ show tokenPath
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = " ++ show certPath
    , "  , key_file = " ++ show keyPath
    , "  , ca_file = " ++ show caPath
    , "  , orders_file = " ++ show ordersPath
    , "  , event_keys ="
    , "    [ { name = \"node-a\""
    , "      , value ="
    , indentFixture 10 (vaultSecretRefDhall "secret" "gateway/gateway/node-a/event-key" "key")
    , "      }"
    , "    ]"
    , "  , dns_write_gate ="
    , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
    , "  , aws_creds ="
    , "      None { access_key_id : "
        ++ secretRefTypeDhall
        ++ ", secret_access_key : "
        ++ secretRefTypeDhall
        ++ ", session_token : Optional "
        ++ secretRefTypeDhall
        ++ ", region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : "
        ++ secretRefTypeDhall
        ++ ", minio_secret_key : "
        ++ secretRefTypeDhall
        ++ " }"
    , "  , minio_endpoint_url = None Text"
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 1.0"
    , "  , reconnect_interval_seconds = 1.0"
    , "  , sync_interval_seconds = 5.0"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some 30"
    , "  , log_level = Some \"info\""
    , "  }"
    , "}"
    ]

gatewayStatusConfig :: Int -> FilePath -> String
gatewayStatusConfig vaultPort tokenPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    Some"
    , "      { address = " ++ show (fakeVaultAddress vaultPort)
    , "      , auth_path = \"kubernetes\""
    , "      , role = \"gateway-gateway\""
    , "      , service_account_token_file = Some " ++ show tokenPath
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = \"node-a.crt\""
    , "  , key_file = \"node-a.key\""
    , "  , ca_file = \"ca.crt\""
    , "  , orders_file = \"orders.dhall\""
    , "  , event_keys ="
    , "    [ { name = \"node-a\""
    , "      , value ="
    , indentFixture 10 (vaultSecretRefDhall "secret" "gateway/gateway/node-a/event-key" "key")
    , "      }"
    , "    ]"
    , "  , dns_write_gate ="
    , "      Some"
    , "        { zone_id = \"Z123\""
    , "        , fqdn = \"test.resolvefintech.com\""
    , "        , ttl = 60"
    , "        , aws_region = \"us-east-1\""
    , "        }"
    , "  , aws_creds ="
    , "      None { access_key_id : "
        ++ secretRefTypeDhall
        ++ ", secret_access_key : "
        ++ secretRefTypeDhall
        ++ ", session_token : Optional "
        ++ secretRefTypeDhall
        ++ ", region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : "
        ++ secretRefTypeDhall
        ++ ", minio_secret_key : "
        ++ secretRefTypeDhall
        ++ " }"
    , "  , minio_endpoint_url = None Text"
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 1.0"
    , "  , reconnect_interval_seconds = 1.0"
    , "  , sync_interval_seconds = 5.0"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some 30"
    , "  , log_level = Some \"info\""
    , "  }"
    , "}"
    ]

gatewayOrders :: String
gatewayOrders = gatewayOrdersAt 31001

-- | Orders fixture pointing at 127.0.0.1:port. Used by integration tests that
-- spin up a loopback HTTP server to exercise the native HTTP client path.
gatewayOrdersAt :: Int -> String
gatewayOrdersAt port =
  gatewayOrdersAtPorts port 32001

gatewayOrdersAtPorts :: Int -> Int -> String
gatewayOrdersAtPorts restPort socketPort =
  unlines
    [ "{ version_utc = 1"
    , ", nodes ="
    , "  [ { node_id = \"node-a\""
    , "    , stable_dns_name = \"node-a.example.test\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show restPort
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = " ++ show socketPort
    , "    }"
    , "  ]"
    , ", gateway_rule ="
    , "    { ranked_nodes = [ \"node-a\" ]"
    , "    , heartbeat_timeout_seconds = 3"
    , "    }"
    , "}"
    ]

validConfig :: String
validConfig =
  configWithAwsAndAcme
    gatewayAwsVaultPath
    "us-east-1"
    True
    "https://acme.zerossl.com/v2/DV90"
    (eabVaultRefDhall "key_id")
    (eabVaultRefDhall "hmac_key")

validConfigWithBlankOperationalAwsAndConfiguredAdmin :: String
validConfigWithBlankOperationalAwsAndConfiguredAdmin =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall gatewayAwsVaultPath "us-east-1" False
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = "
        ++ eabVaultRefDhall "key_id"
        ++ ", eab_hmac_key = "
        ++ eabVaultRefDhall "hmac_key"
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

-- | Sprint 8.8: like 'validConfigWithBlankOperationalAwsAndConfiguredAdmin'
-- but with a populated long-lived @pulumi_state_backend@ bucket, so the
-- @prodbox nuke@ step-5 state-bucket destroy (which removes the retained
-- public-edge certificate stored under that bucket) has a bucket to target.
validConfigForNuke :: String
validConfigForNuke =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall gatewayAwsVaultPath "us-east-1" False
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"test.resolvefintech.com\", receive_subdomain = \"inbox.test.resolvefintech.com\", capture_bucket = \"prodbox-test-ses-capture\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = "
        ++ eabVaultRefDhall "key_id"
        ++ ", eab_hmac_key = "
        ++ eabVaultRefDhall "hmac_key"
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"prodbox-test-pulumi-long-lived\", region = \"us-west-2\", key_prefix = \"pulumi/\" }"
    , "}"
    ]

validConfigWithLeakedOperationalAwsAndConfiguredAdmin :: String
validConfigWithLeakedOperationalAwsAndConfiguredAdmin =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall gatewayAwsVaultPath "us-west-2" False
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = "
        ++ eabVaultRefDhall "key_id"
        ++ ", eab_hmac_key = "
        ++ eabVaultRefDhall "hmac_key"
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

zeroSslConfig :: String
zeroSslConfig =
  configWithAwsAndAcme
    gatewayAwsVaultPath
    "us-east-1"
    True
    "https://acme.zerossl.com/v2/DV90"
    (eabVaultRefDhall "key_id")
    (eabVaultRefDhall "hmac_key")

deploymentDhallFragment :: String
deploymentDhallFragment =
  concat
    [ "{ dev_mode = True"
    , ", bootstrap_public_ip_override = None Text"
    , ", pulumi_enable_dns_bootstrap = True"
    , ", public_edge_advertisement_mode = None Text"
    , ", public_edge_bgp_peers ="
    , "    None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    , ", envoy_gateway_controller_scaling = " ++ fixedScalingDhall 1
    , ", envoy_gateway_data_plane_scaling = " ++ fixedScalingDhall 1
    , ", api_scaling = " ++ fixedScalingDhall 2
    , ", websocket_scaling = " ++ fixedScalingDhall 2
    , " }"
    ]

scalingPolicyTypeDhall :: String
scalingPolicyTypeDhall =
  "< Fixed : Natural | Elastic : { min : Natural, max : Natural } >"

fixedScalingDhall :: Int -> String
fixedScalingDhall count =
  "{ home_local = "
    ++ scalingPolicyTypeDhall
    ++ ".Fixed "
    ++ show count
    ++ ", aws = "
    ++ scalingPolicyTypeDhall
    ++ ".Fixed "
    ++ show count
    ++ " }"

capacityDhallFragment :: String
capacityDhallFragment =
  unlines
    [ "{ node_budget = { cpu = 8, memory = 16, storage = 100 }"
    , ", workload_budget = { cpu = 4, memory = 8, storage = 40 }"
    , ", region_quota = { cpu = 32, memory = 64, storage = 500 }"
    , ", resource_plan = " ++ resourcePlanDhallFragment
    , "}"
    ]

resourcePlanDhallFragment :: String
resourcePlanDhallFragment =
  unlines
    [ "{ host_capacity = { milli_cpu = 16000, memory_mib = 49152, ephemeral_storage_mib = 300000, durable_storage_mib = 800000 }"
    , ", rke2_reserved = { milli_cpu = 1000, memory_mib = 2048, ephemeral_storage_mib = 10240, durable_storage_mib = 1024 }"
    , ", eviction_floor = { milli_cpu = 500, memory_mib = 1024, ephemeral_storage_mib = 10240, durable_storage_mib = 1024 }"
    , ", namespace_quotas ="
    , "  [ { namespace_name = \"keycloak\", quota = { milli_cpu = 3000, memory_mib = 10000, ephemeral_storage_mib = 50000, durable_storage_mib = 150000 } }"
    , "  , { namespace_name = \"vscode\", quota = { milli_cpu = 2000, memory_mib = 5000, ephemeral_storage_mib = 30000, durable_storage_mib = 100000 } }"
    , "  , { namespace_name = \"api\", quota = { milli_cpu = 1500, memory_mib = 2000, ephemeral_storage_mib = 10000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"websocket\", quota = { milli_cpu = 1000, memory_mib = 2000, ephemeral_storage_mib = 10000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"gateway\", quota = { milli_cpu = 4000, memory_mib = 10000, ephemeral_storage_mib = 60000, durable_storage_mib = 100000 } }"
    , "  , { namespace_name = \"prodbox\", quota = { milli_cpu = 2000, memory_mib = 4000, ephemeral_storage_mib = 40000, durable_storage_mib = 250000 } }"
    , "  , { namespace_name = \"vault\", quota = { milli_cpu = 1000, memory_mib = 2000, ephemeral_storage_mib = 20000, durable_storage_mib = 100000 } }"
    , "  ]"
    , ", workload_profiles ="
    , "  [ " ++ resourceProfileDhall "keycloak" "keycloak" 1 (500, 1024, 1024, 1) (1000, 2048, 2048, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-vault-secrets" "keycloak" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-postgres" "keycloak" 3 (250, 512, 1024, 1024) (500, 1024, 4096, 2048)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-vault-secrets"
          "keycloak"
          1
          (50, 128, 256, 1)
          (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-secret-materializer"
          "keycloak"
          1
          (50, 128, 256, 1)
          (100, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "vscode" "vscode" 1 (500, 1024, 1024, 1024) (1000, 2048, 4096, 2048)
    , "  , "
        ++ resourceProfileDhall "vscode-vault-secrets" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "vscode-secret-materializer" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "api" "api" 2 (250, 256, 512, 1) (500, 512, 1024, 1)
    , "  , " ++ resourceProfileDhall "websocket" "websocket" 2 (100, 256, 512, 1) (250, 512, 1024, 1)
    , "  , " ++ resourceProfileDhall "redis" "websocket" 1 (100, 256, 512, 1) (250, 512, 1024, 1)
    , "  , " ++ resourceProfileDhall "gateway" "gateway" 3 (250, 256, 512, 1) (500, 512, 1024, 1)
    , "  , " ++ resourceProfileDhall "pulsar" "gateway" 1 (250, 1024, 1024, 1) (500, 2048, 4096, 1)
    , "  , " ++ resourceProfileDhall "minio" "prodbox" 1 (500, 1024, 2048, 1024) (1000, 2048, 4096, 2048)
    , "  , " ++ resourceProfileDhall "harbor" "prodbox" 1 (250, 512, 1024, 1024) (500, 1024, 4096, 2048)
    , "  , "
        ++ resourceProfileDhall "percona-postgres-operator" "prodbox" 1 (100, 256, 512, 1) (250, 512, 1024, 1)
    , "  , " ++ resourceProfileDhall "vault" "vault" 1 (250, 512, 1024, 1) (500, 1024, 2048, 1)
    , "  ]"
    , "}"
    ]

resourceProfileDhall
  :: String
  -> String
  -> Int
  -> (Int, Int, Int, Int)
  -> (Int, Int, Int, Int)
  -> String
resourceProfileDhall profile namespace count req lim =
  "{ profile_id = "
    ++ show profile
    ++ ", profile_namespace = "
    ++ show namespace
    ++ ", replicas = "
    ++ show count
    ++ ", resources = { request = "
    ++ resourceVectorDhall req
    ++ ", limit = "
    ++ resourceVectorDhall lim
    ++ " } }"

resourceVectorDhall :: (Int, Int, Int, Int) -> String
resourceVectorDhall (cpuMilli, memoryMib, ephemeralMib, durableMib) =
  "{ milli_cpu = "
    ++ show cpuMilli
    ++ ", memory_mib = "
    ++ show memoryMib
    ++ ", ephemeral_storage_mib = "
    ++ show ephemeralMib
    ++ ", durable_storage_mib = "
    ++ show durableMib
    ++ " }"

clusterTopologyDhallFragment :: String
clusterTopologyDhallFragment =
  clusterTopologyDhallType
    ++ ".Rke2 { machines = [ "
    ++ clusterTopologyMachineDhall
    ++ " ] : List "
    ++ clusterTopologyMachineTypeDhall
    ++ " }"

clusterTopologyDhallType :: String
clusterTopologyDhallType =
  "< Kind : { machine : "
    ++ clusterTopologyMachineTypeDhall
    ++ ", node_count : Natural } | Rke2 : { machines : List "
    ++ clusterTopologyMachineTypeDhall
    ++ " } | Eks : { node_group_size : Natural, eks_substrate : "
    ++ workerSubstrateDhallType
    ++ " } >"

clusterTopologyMachineTypeDhall :: String
clusterTopologyMachineTypeDhall =
  "{ machine_id : Text, machine_substrate : "
    ++ workerSubstrateDhallType
    ++ ", compute_worker : { worker_substrate : "
    ++ workerSubstrateDhallType
    ++ ", manages_all_local_devices : Bool } }"

clusterTopologyMachineDhall :: String
clusterTopologyMachineDhall =
  "{ machine_id = \"prodbox-home\", machine_substrate = "
    ++ workerSubstrateDhallType
    ++ ".LinuxCpu, compute_worker = { worker_substrate = "
    ++ workerSubstrateDhallType
    ++ ".LinuxCpu, manages_all_local_devices = True } }"

workerSubstrateDhallType :: String
workerSubstrateDhallType =
  "< LinuxCpu | LinuxCuda | AppleMetal | CudaWindows >"

configWithAwsAndAcme :: String -> String -> Bool -> String -> String -> String -> String
configWithAwsAndAcme awsVaultPath regionValue includeSessionToken acmeServer eabKeyIdValue eabHmacKeyValue =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall awsVaultPath regionValue includeSessionToken
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \""
        ++ acmeServer
        ++ "\", eab_key_id = "
        ++ eabKeyIdValue
        ++ ", eab_hmac_key = "
        ++ eabHmacKeyValue
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityDhallFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]
