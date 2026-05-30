module CliSuite
  ( integrationCliSuite
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, try)
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
  , proc
  , readCreateProcessWithExitCode
  )
import TestSupport

integrationCliSuite :: SuiteBuilder ()
integrationCliSuite = do
  describe "native Haskell config CLI" $ do
    it "shows masked settings from a repo-root Dhall config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "show"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "aws.access_key_id=****-key"
        stdoutText `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))

    it "validates config without requiring any Python backend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""

    it "fails fast with setup guidance when the repo Dhall config is missing" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
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
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
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
        withGatewayStateServer gatewayStateResponseJson $ \port requestRef -> do
          binary <- resolveBinaryPath
          writeRepoMarkers tmpDir
          let configPath = tmpDir </> "gateway.dhall"
          writeFile configPath gatewayStatusConfig
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

    it "fails fast when gateway start is missing required trust material" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        let ordersPath = tmpDir </> "orders.dhall"
            configPath = tmpDir </> "gateway-start.dhall"
        writeFile ordersPath gatewayOrders
        writeFile
          configPath
          ( gatewayStartConfig
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

    it
      "runs native charts list, status, deploy, and delete through the built frontend with fake helm and kubectl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
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
            (proc binary ["charts", "deploy", "vscode"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"
        deployStdout `shouldContain` "ROOT_CHART=vscode"

        appliedManifest <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-apply-1.json")
        appliedManifest `shouldContain` "PersistentVolumeClaim"
        appliedManifest `shouldContain` "vscode-data-0"
        patroniManifest <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-apply-2.json")
        patroniManifest `shouldContain` "PersistentVolume"
        patroniManifest `shouldContain` "prodbox-vscode-pg-instance1-0-pgdata"
        patroniManifest `shouldNotContain` "PersistentVolumeClaim"

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--atomic|--timeout|30m0s|keycloak"
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--atomic|--timeout|30m0s|vscode"

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
            alreadyDeployedEnvVars =
              ( "PRODBOX_FAKE_HELM_LIST_JSON"
              , "[{\"name\":\"keycloak\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"vscode\",\"namespace\":\"vscode\",\"status\":\"deployed\"}]"
              )
                : filter ((/= "PRODBOX_FAKE_HELM_LIST_JSON") . fst) envVars

        (secondDeployExitCode, secondDeployStdout, secondDeployStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "deploy", "vscode"]) {cwd = Just tmpDir, env = Just alreadyDeployedEnvVars}
            ""

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
          `shouldContain` "delete|pv|prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-0-data"
        deleteRecord `shouldContain` "delete|pvc|vscode-data-0|--namespace|vscode"
        deleteRecord `shouldContain` "delete|pv|prodbox-chart-vscode-vscode-vscode-0-data"
        deleteRecord `shouldContain` "delete|namespace|vscode"

    it "rejects internal dependency charts on the public charts surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
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
      "restores retained Patroni state through a staged bootstrap before scaling back to three replicas"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        envVars <- fakeChartEnvironment tmpDir
        let stagedEnvVars = ("PRODBOX_FAKE_PATRONI_STAGED_RESTORE", "true") : envVars
            stateDir = tmpDir </> ".prodbox-state" </> "vscode"
        createDirectoryIfMissing True stateDir
        writeFile
          (stateDir </> ".patroni-anchor-volume")
          "prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-1-data\n"

        (deployExitCode, deployStdout, deployStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "deploy", "vscode"]) {cwd = Just tmpDir, env = Just stagedEnvVars}
            ""

        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"

        bootstrapPatroniManifest <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-apply-2.json")
        bootstrapPatroniManifest
          `shouldContain` "prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-1-data"
        bootstrapPatroniManifest `shouldContain` "prodbox-vscode-pg-instance1-0-pgdata"
        bootstrapPatroniManifest `shouldNotContain` "prodbox-vscode-pg-instance1-1-pgdata"
        bootstrapPatroniManifest `shouldNotContain` "prodbox-vscode-pg-instance1-2-pgdata"

        fullPatroniManifest <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-apply-3.json")
        fullPatroniManifest
          `shouldContain` "prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-1-data"
        fullPatroniManifest `shouldContain` "prodbox-vscode-pg-instance1-0-pgdata"
        fullPatroniManifest `shouldContain` "prodbox-vscode-pg-instance1-1-pgdata"
        fullPatroniManifest `shouldContain` "prodbox-vscode-pg-instance1-2-pgdata"

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        length (filter (isInfixOf "|keycloak-postgres|") (lines upgradeRecord)) `shouldBe` 2

    it
      "runs native rke2 status, start, and logs through the built frontend with fake systemctl and journalctl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        envVars <- fakeRke2Environment tmpDir

        (statusExitCode, statusStdout, statusStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "status"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "active"

        (startExitCode, startStdout, startStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "start"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        startExitCode `shouldBe` ExitSuccess
        startStdout `shouldBe` ""
        startStderr `shouldBe` ""

        (logsExitCode, logsStdout, logsStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "logs", "--lines", "25"]) {cwd = Just tmpDir, env = Just envVars}
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
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        envVars <- fakeRke2Environment tmpDir

        (installExitCode, installStdout, installStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
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
        installStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
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
        deleteStdout `shouldContain` "Deleting local RKE2 environment..."
        deleteStdout
          `shouldContain` "AWS EKS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
        deleteStdout
          `shouldContain` "AWS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
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
        sudoRecord `shouldContain` "cp|/etc/rancher/rke2/rke2.yaml|"
        sudoRecord `shouldContain` "ctr|--address|"
        sudoRecord
          `shouldContain` "rm|-rf|/var/lib/rancher/rke2|/var/lib/rancher|/etc/rancher/rke2|/usr/local/bin/rke2|/usr/local/bin/rke2-killall.sh|/usr/local/bin/rke2-uninstall.sh"

        kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
        kubectlRecord `shouldContain` "cluster-info"
        kubectlRecord `shouldContain` "get|nodes|-o|name"
        kubectlRecord `shouldContain` "wait|--for=condition=Ready|node|--all|--timeout=300s"
        kubectlRecord `shouldContain` "get|storageclass|-o|name"
        kubectlRecord
          `shouldContain` "delete|storageclass|storageclass.storage.k8s.io/local-path|--ignore-not-found=true"
        kubectlRecord `shouldContain` "patch|deployment|harbor-nginx|-n|harbor|--type|strategic|--patch|"
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
        applyStorage `shouldContain` "PersistentVolumeClaim"
        applyStorage `shouldContain` "prodbox-minio-pv-0"
        applyHarborBootstrap <-
          readAppliedManifestContaining rke2StateDir harborRegistryStorageBootstrapJobName
        applyHarborBootstrap `shouldContain` harborRegistryStorageSecretName
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_ACCESSKEY"
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_SECRETKEY"
        applyHarborBootstrap `shouldContain` "quay.io/minio/mc"
        applyHarborBootstrap
          `shouldContain` ("mc mb --ignore-existing local/" ++ harborRegistryStorageBucket)
        applyHarbor <- readAppliedManifestContaining rke2StateDir "/readyz"
        applyHarbor `shouldContain` "nginx.conf"
        applyHarbor `shouldContain` "/readyz"
        applyAdminRoutes <- readAppliedManifestContaining rke2StateDir "harbor-ui"
        applyAdminRoutes `shouldContain` "harbor-ui"
        applyAdminRoutes `shouldContain` "minio-console"
        applyAdminRoutes `shouldContain` "harbor-oidc"
        applyAdminRoutes `shouldContain` "minio-oidc"

        helmRecord <- readFile (tmpDir </> "fake-rke2-state" </> "helm.txt")
        helmRecord `shouldContain` "repo|add|minio|https://charts.min.io/"
        helmRecord `shouldContain` "upgrade|--install|minio|minio/minio"
        helmRecord `shouldContain` "image.repository=quay.io/minio/minio"
        helmRecord `shouldContain` "mcImage.repository=quay.io/minio/mc"
        helmRecord `shouldContain` "image.repository=127.0.0.1:30080/prodbox/minio-mirror"
        helmRecord `shouldContain` "mcImage.repository=127.0.0.1:30080/prodbox/minio-mc-mirror"
        helmRecord `shouldContain` "repo|add|harbor|https://helm.goharbor.io"
        helmRecord `shouldContain` "upgrade|--install|harbor|harbor/harbor"
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
        helmRecord `shouldContain` "upgrade|--install|envoy-gateway|oci://docker.io/envoyproxy/gateway-helm"
        helmRecord `shouldContain` "repo|add|jetstack|https://charts.jetstack.io"
        helmRecord `shouldContain` "upgrade|--install|cert-manager|jetstack/cert-manager"
        helmRecord `shouldContain` "repo|add|percona|https://percona.github.io/percona-helm-charts/"
        helmRecord `shouldContain` "upgrade|--install|postgres-operator|percona/pg-operator"
        helmRecord `shouldNotContain` "uninstall|traefik|--namespace|traefik-system|--wait"
        helmRecord `shouldNotContain` "uninstall|postgres-operator|--namespace|postgres-operator|--wait"
        findRecordLineIndex "upgrade|--install|minio|minio/minio" helmRecord
          `shouldSatisfy` (< findRecordLineIndex "upgrade|--install|harbor|harbor/harbor" helmRecord)

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        dockerRecord `shouldContain` "login|127.0.0.1:30080|--username|admin|--password|Harbor12345"
        length
          ( filter
              (== "login|127.0.0.1:30080|--username|admin|--password|Harbor12345")
              (lines dockerRecord)
          )
          `shouldSatisfy` (>= 2)
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
        dockerRecord
          `shouldContain` "build|-f|docker/gateway.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-gateway:prodbox-"
        dockerRecord `shouldContain` "-t|127.0.0.1:30080/prodbox/prodbox-gateway:latest|."
        dockerRecord `shouldContain` "push|127.0.0.1:30080/prodbox/prodbox-gateway:latest"
        dockerRecord
          `shouldContain` "build|-f|docker/prodbox.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-public-edge-workload:prodbox-"
        dockerRecord `shouldNotContain` "docker/nginx-oidc.Dockerfile"
        dockerRecord `shouldContain` "save|-o|"

        curlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "curl.txt")
        curlRecord `shouldContain` "https://get.rke2.io"
        curlRecord `shouldContain` "http://127.0.0.1:30080/readyz"
        curlRecord `shouldContain` "http://127.0.0.1:30080/v2/"
        curlRecord `shouldContain` "/api/v2.0/projects"

        pulumiRecordExists <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRecordExists `shouldBe` False

    it "falls back to mirror.gcr when Docker Hub rate-limits a supported Percona image" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ( "PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF"
              , "docker.io/percona/percona-distribution-postgresql:17.9-1"
              )
                : baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
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
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars = ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1") : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
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
        deleteStdout `shouldContain` "Deleting local RKE2 environment..."
        deleteStdout
          `shouldContain` "AWS EKS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
        deleteStdout
          `shouldContain` "AWS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
        deleteStdout `shouldContain` "Local RKE2 substrate: cleanup complete"
        deleteStdout `shouldContain` "Managed kubeconfig: removed"
        deleteStdout `shouldContain` "Preserved host state:"
        deleteStdout `shouldNotContain` "Logged in to fake-rke2"
        deleteStdout `shouldNotContain` "Cannot find device"
        deleteStdout `shouldNotContain` "semodule: not found"
        deleteStdout `shouldNotContain` "Failed to allocate directory watch"
        deleteStdout `shouldNotContain` "Too many open files"
        deleteStdout `shouldNotContain` "Cleanup completed successfully"

        kubeconfigExists <- doesFileExist (tmpDir </> ".kube" </> "config")
        kubeconfigExists `shouldBe` False

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "/usr/local/bin/rke2-uninstall.sh"

    it "summarizes actionable uninstall failures while suppressing benign chatter" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1")
                : ("PRODBOX_FAKE_RKE2_UNINSTALL_FAIL", "1")
                : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deleteExitCode `shouldBe` ExitFailure 1
        deleteStdout `shouldContain` "Deleting local RKE2 environment..."
        deleteStdout `shouldNotContain` "Local RKE2 substrate: cleanup complete"
        deleteStderr `shouldContain` "failed to clean the local RKE2 substrate"
        deleteStderr `shouldContain` "umount: /var/lib/kubelet/pods/abc: target is busy"
        deleteStderr `shouldNotContain` "Failed to allocate directory watch"
        deleteStderr `shouldNotContain` "semodule: not found"
        deleteStderr `shouldNotContain` "Cannot find device"

    it "runs native rke2 delete after the IAM harness has cleared operational aws credentials" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithBlankOperationalAwsAndConfiguredAdmin
        envVars <- fakeRke2Environment tmpDir

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
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
        deleteStdout `shouldContain` "Deleting local RKE2 environment..."
        deleteStdout
          `shouldContain` "AWS EKS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
        deleteStdout
          `shouldContain` "AWS test stack: no local Pulumi backend or saved residue snapshot; nothing to destroy"
        deleteStdout `shouldContain` "Preserved host state:"

    it "Sprint 4.19: rke2 delete --yes refuses when the per-run Pulumi state backend is unreachable" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithBlankOperationalAwsAndConfiguredAdmin
        baseEnvVars <- fakeRke2Environment tmpDir
        -- Drop the absent-bypass and force the unreachable-bypass so the gate
        -- sees ResidueUnreachable (MinIO state backend cannot be read).
        let envVars =
              ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
                : filter ((/= "PRODBOX_TEST_RESIDUE_ABSENT") . fst) baseEnvVars

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput = unlines ["delete stdout:", deleteStdout, "delete stderr:", deleteStderr]
            combined = deleteStdout ++ deleteStderr
        when
          (deleteExitCode == ExitSuccess)
          (expectationFailure ("expected refusal, got success:\n" ++ deleteOutput))
        deleteExitCode `shouldBe` ExitFailure 1
        -- It must NOT claim a clean teardown.
        combined `shouldNotContain` "Deleting local RKE2 environment..."
        -- It must explain the unreadable state and name the explicit escape.
        combined `shouldContain` "per-run Pulumi state backend"
        combined `shouldContain` "do NOT delete `.data/`"
        combined `shouldContain` "--allow-pulumi-residue"

    it "Sprint 4.19: rke2 delete --yes --allow-pulumi-residue still proceeds when state is unreachable" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithBlankOperationalAwsAndConfiguredAdmin
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
                : filter ((/= "PRODBOX_TEST_RESIDUE_ABSENT") . fst) baseEnvVars

        (deleteExitCode, deleteStdout, _deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "delete", "--yes", "--allow-pulumi-residue"])
              { cwd = Just tmpDir
              , env = Just envVars
              }
            ""

        deleteExitCode `shouldBe` ExitSuccess
        deleteStdout `shouldContain` "Deleting local RKE2 environment..."

    it "projects ZeroSSL external account binding into the supported ClusterIssuer reconcile" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") zeroSslConfig
        envVars <- fakeRke2Environment tmpDir

        (upExitCode, upStdout, upStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["rke2", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        upExitCode `shouldBe` ExitSuccess
        upStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        upStdout `shouldContain` "Kubernetes control plane is running"

        applyManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "\"externalAccountBinding\""
        applyManifest `shouldContain` "\"ClusterIssuer\""
        applyManifest `shouldContain` "\"Secret\""
        applyManifest `shouldContain` "\"externalAccountBinding\""
        applyManifest `shouldContain` "\"keyID\":\"test-eab-key-id\""
        applyManifest `shouldContain` "\"name\":\"acme-eab-credentials\""
        applyManifest `shouldContain` "\"namespace\":\"cert-manager\""
        applyManifest `shouldContain` "\"stringData\":{\"secret\":\"test-eab-hmac-key\"}"

    it "runs native gateway start and fails gracefully with a missing config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath
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
        binary <- resolveBinaryPath
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
        binary <- resolveBinaryPath
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
                , "2"
                , "ops@resolvefintech.com"
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
        configText <- readFile (tmpDir </> "prodbox-config.dhall")
        configText `shouldContain` "sha256:"
        configText `shouldContain` "access_key_id = \"AKIAFAKESETUP\""
        configText `shouldContain` "route53.zone_id = \"Z1234567890ABC\""
        configText `shouldContain` "demo_fqdn = \"test.resolvefintech.com\""
        configText `shouldContain` "public_edge_advertisement_mode = Some \"l2\""
        jsonExists <- doesFileExist (tmpDir </> "prodbox-config.json")
        jsonExists `shouldBe` False

    it "runs native aws setup and teardown through the built frontend with a fake AWS CLI" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithBlankOperationalAwsAndConfiguredAdmin
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

        configAfterSetup <- readFile (tmpDir </> "prodbox-config.dhall")
        configAfterSetup `shouldContain` "sha256:"
        configAfterSetup `shouldContain` "access_key_id = \"AKIAFAKESETUP\""
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

        configAfterTeardown <- readFile (tmpDir </> "prodbox-config.dhall")
        configAfterTeardown `shouldContain` "sha256:"
        configAfterTeardown `shouldContain` "access_key_id = \"\""
        configAfterTeardown `shouldContain` "secret_access_key = \"\""
        teardownAdminKey <- readFile (tmpDir </> "fake-aws-state" </> "iam_delete_user_access_key_id")
        teardownAdminKey `shouldContain` "ADMINKEY"

    it
      "runs native aws-iam validation through the shared harness and clears leaked operational credentials"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithLeakedOperationalAwsAndConfiguredAdmin
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

        configAfterHarness <- readFile (tmpDir </> "prodbox-config.dhall")
        configAfterHarness `shouldContain` "access_key_id = \"\""
        configAfterHarness `shouldContain` "secret_access_key = \"\""

        deletedUsers <- fmap lines (readFile (tmpDir </> "fake-aws-state" </> "iam_deleted_users"))
        deletedUsers `shouldBe` ["prodbox", "leaked-user", "prodbox"]

    it
      "runs native aws quota inspection and request flows through the built frontend with a fake AWS CLI"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        envVars <- fakeAwsEnvironment tmpDir
        let commandInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]

        (checkExitCode, checkStdout, checkStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "check-quotas"]) {cwd = Just tmpDir, env = Just envVars}
            commandInput

        checkExitCode `shouldBe` ExitSuccess
        checkStderr `shouldBe` ""
        checkStdout `shouldContain` "Supported AWS Quotas"
        checkStdout `shouldContain` "Running On-Demand Standard vCPU"
        checkStdout `shouldContain` "Elastic IP addresses"

        (requestExitCode, requestStdout, requestStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "request-quotas", "--tier", "core"]) {cwd = Just tmpDir, env = Just envVars}
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
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_RESIDUE_ABSENT", "1")
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
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_RESIDUE_ABSENT", "1")
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
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_CHART_RECORD_DIR", recordDir)
      , ("PRODBOX_FAKE_HELM_LIST_JSON", "[]")
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
    , "    if [[ \"${3:-}\" == 'prodbox-vscode-pg-ha' && \"$*\" == *'jsonpath={.subsets[0].addresses[0].targetRef.name}'* ]]; then"
    , "      printf 'prodbox-vscode-pg-instance1-0\\n'"
    , "    else"
    , "      printf 'Error from server (NotFound): endpoints \"%s\" not found\\n' \"${3:-endpoints}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get pvc')"
    , "    if [[ \"${3:-}\" == 'prodbox-vscode-pg-instance1-0-pgdata' && \"$*\" == *'jsonpath={.spec.volumeName}'* ]]; then"
    , "      printf 'prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-0-data\\n'"
    , "    elif [[ \"$*\" == *'postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_STAGED_RESTORE:-}\" == 'true' ]]; then"
    , "        pvc_count=$(next_counter \"$record_dir/patroni-pvc-list.count\")"
    , "        if [[ \"$pvc_count\" -eq 1 ]]; then"
    , "          cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-0-pgdata\"}}]}"
    , "JSON"
    , "        else"
    , "          cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-0-pgdata\"},\"spec\":{\"volumeName\":\"prodbox-chart-vscode-keycloak-postgres-prodbox-vscode-pg-1-data\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-1-pgdata\"},\"spec\":{}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-2-pgdata\"},\"spec\":{}}]}"
    , "JSON"
    , "        fi"
    , "      else"
    , "        cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-0-pgdata\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-1-pgdata\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-2-pgdata\"}}]}"
    , "JSON"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get secret')"
    , "    if [[ \"$*\" == *'go-template={{index .data \"password\" | base64decode}}'* ]]; then"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    else"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    fi"
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
    , "  is-active)"
    , "    printf 'active\\n'"
    , "    ;;"
    , "  start|stop|restart|enable|disable)"
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
    , "case \"${1:-}\" in"
    , "  cluster-info)"
    , "    printf 'Kubernetes control plane is running\\n'"
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
    , "        if [[ \"$*\" == *'-o|name'* || \"$*\" == *'-o name'* ]]; then"
    , "          printf 'node/bathurst\\n'"
    , "        else"
    , "          printf 'bathurst'"
    , "        fi"
    , "        ;;"
    , "      storageclass)"
    , "        printf 'storageclass.storage.k8s.io/manual\\nstorageclass.storage.k8s.io/local-path\\n'"
    , "        ;;"
    , "      pv)"
    , "        ;;"
    , "      pvc)"
    , "        printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
    , "        exit 1"
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
    , "        printf 'docker.io/library/busybox:latest\\ngoharbor/harbor-core:v2\\n'"
    , "        ;;"
    , "      *)"
    , "        ;;"
    , "    esac"
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
    , "exit 0"
    ]

fakeRke2DockerScript :: String
fakeRke2DockerScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
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
    , "        if [[ \"$*\" != *'--create'* && ( \"${3:-}\" == 'aws-eks-test' || \"${3:-}\" == 'aws-test' ) ]]; then"
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
    , "  *'route53 change-resource-record-sets'*)"
    , "    printf '{\"ChangeInfo\":{\"Status\":\"INSYNC\"}}\\n'"
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

gatewayStartConfig :: FilePath -> FilePath -> FilePath -> FilePath -> String
gatewayStartConfig ordersPath certPath keyPath caPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = " ++ show certPath
    , "  , key_file = " ++ show keyPath
    , "  , ca_file = " ++ show caPath
    , "  , orders_file = " ++ show ordersPath
    , "  , event_keys ="
    , "    [ { name = \"node-a\", value = \"validation-key\" } ]"
    , "  , dns_write_gate ="
    , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
    , "  , aws_creds ="
    , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : Text, minio_secret_key : Text }"
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

gatewayStatusConfig :: String
gatewayStatusConfig =
  unlines
    [ "{ schemaVersion = 1"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = \"node-a.crt\""
    , "  , key_file = \"node-a.key\""
    , "  , ca_file = \"ca.crt\""
    , "  , orders_file = \"orders.dhall\""
    , "  , event_keys ="
    , "    [ { name = \"node-a\", value = \"REPLACE_WITH_SECRET_KEY\" } ]"
    , "  , dns_write_gate ="
    , "      Some"
    , "        { zone_id = \"Z123\""
    , "        , fqdn = \"test.resolvefintech.com\""
    , "        , ttl = 60"
    , "        , aws_region = \"us-east-1\""
    , "        }"
    , "  , aws_creds ="
    , "      None { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : Text, minio_secret_key : Text }"
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
  unlines
    [ "{ version_utc = 1"
    , ", nodes ="
    , "  [ { node_id = \"node-a\""
    , "    , stable_dns_name = \"node-a.example.test\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show port
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = 32001"
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
  configWithAws "test-access-key" "test-secret-key" "Some \"test-session-token\""

validConfigWithBlankOperationalAwsAndConfiguredAdmin :: String
validConfigWithBlankOperationalAwsAndConfiguredAdmin =
  unlines
    [ "{ aws = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"CONFIGADMINKEY\", secret_access_key = \"config-admin-secret\", session_token = None Text, region = \"us-west-2\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

validConfigWithLeakedOperationalAwsAndConfiguredAdmin :: String
validConfigWithLeakedOperationalAwsAndConfiguredAdmin =
  unlines
    [ "{ aws = { access_key_id = \"AKIALEAKED\", secret_access_key = \"leaked-secret\", session_token = None Text, region = \"us-west-2\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"CONFIGADMINKEY\", secret_access_key = \"config-admin-secret\", session_token = None Text, region = \"us-west-2\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

zeroSslConfig :: String
zeroSslConfig =
  configWithAwsAndAcme
    "test-access-key"
    "test-secret-key"
    "Some \"test-session-token\""
    "https://acme.zerossl.com/v2/DV90"
    "Some \"test-eab-key-id\""
    "Some \"test-eab-hmac-key\""

configWithAws :: String -> String -> String -> String
configWithAws accessKeyId secretAccessKey sessionTokenValue =
  configWithAwsAndAcme
    accessKeyId
    secretAccessKey
    sessionTokenValue
    "https://acme-staging-v02.api.letsencrypt.org/directory"
    "None Text"
    "None Text"

deploymentDhallFragment :: String
deploymentDhallFragment =
  concat
    [ "{ dev_mode = True"
    , ", bootstrap_public_ip_override = None Text"
    , ", pulumi_enable_dns_bootstrap = True"
    , ", public_edge_advertisement_mode = None Text"
    , ", public_edge_bgp_peers ="
    , "    None (List { peer_name : Text, peer_address : Text, peer_asn : Natural, my_asn : Natural, ebgp_multi_hop : Optional Bool })"
    , ", envoy_gateway_controller_replicas = None Natural"
    , ", envoy_gateway_data_plane_replicas = None Natural"
    , ", api_replicas = None Natural"
    , ", websocket_replicas = None Natural"
    , " }"
    ]

configWithAwsAndAcme :: String -> String -> String -> String -> String -> String -> String
configWithAwsAndAcme accessKeyId secretAccessKey sessionTokenValue acmeServer eabKeyIdValue eabHmacKeyValue =
  unlines
    [ "{ aws = { access_key_id = \""
        ++ accessKeyId
        ++ "\", secret_access_key = \""
        ++ secretAccessKey
        ++ "\", session_token = "
        ++ sessionTokenValue
        ++ ", region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
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
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]
