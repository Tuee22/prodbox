module Main (main) where

import System.Directory
    ( Permissions (..),
      copyFile,
      createDirectoryIfMissing,
      doesFileExist,
      getCurrentDirectory,
      getPermissions,
      setPermissions,
    )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
    ( CreateProcess (cwd, env),
      proc,
      readCreateProcessWithExitCode,
    )
import Test.Hspec
import Prodbox.BuildSupport
    ( addBuildSupportEnvironment,
      canonicalOperatorBinaryPath,
      syncBuiltOperatorBinary,
    )

main :: IO ()
main = hspec $ do
    describe "native Haskell config CLI" $ do
        it "shows masked settings from a repo-root Dhall config" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig

                (exitCode, stdoutText, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["config", "show"]){cwd = Just tmpDir}
                        ""

                exitCode `shouldBe` ExitSuccess
                stderrText `shouldBe` ""
                stdoutText `shouldContain` "aws.access_key_id=****-key"
                stdoutText `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))

        it "validates config without requiring the retained Python backend" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig

                (exitCode, _, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["config", "validate"]){cwd = Just tmpDir}
                        ""

                exitCode `shouldBe` ExitSuccess
                stderrText `shouldBe` ""

        it "runs native host info directly from the built Haskell frontend" $ do
            repoRoot <- getCurrentDirectory
            binary <- resolveBinaryPath

            (exitCode, stdoutText, stderrText) <-
                readCreateProcessWithExitCode
                    (proc binary ["host", "info"]){cwd = Just repoRoot}
                    ""

            exitCode `shouldBe` ExitSuccess
            stderrText `shouldBe` ""
            stdoutText `shouldContain` "Linux"

        it "renders native aws policy JSON directly from the built Haskell frontend" $ do
            repoRoot <- getCurrentDirectory
            binary <- resolveBinaryPath

            (exitCode, stdoutText, stderrText) <-
                readCreateProcessWithExitCode
                    (proc binary ["aws", "policy", "--tier", "full"]){cwd = Just repoRoot}
                    ""

            exitCode `shouldBe` ExitSuccess
            stderrText `shouldBe` ""
            stdoutText `shouldContain` "\"Sid\": \"Ec2HaTestStackLifecycle\""
            stdoutText `shouldContain` "\"Sid\": \"IamEksRoleLifecycle\""
            stdoutText `shouldContain` "\"Sid\": \"EksTestStackLifecycle\""

        it "runs native gateway config-gen through the built frontend" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig
                let outputPath = tmpDir </> "gateway.json"

                (exitCode, stdoutText, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["gateway", "config-gen", outputPath, "--node-id", "node-a"]){cwd = Just tmpDir}
                        ""

                exitCode `shouldBe` ExitSuccess
                stderrText `shouldBe` ""
                stdoutText `shouldBe` ""
                rendered <- readFile outputPath
                rendered `shouldContain` "\"node_id\": \"node-a\""
                rendered `shouldContain` "\"fqdn\": \"vscode.example.com\""
                rendered `shouldContain` "\"zone_id\": \"Z1234567890ABC\""

        it "runs native gateway status through the built frontend with a fake curl" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                let configPath = tmpDir </> "gateway.json"
                writeFile configPath gatewayStatusConfig
                writeFile (tmpDir </> "orders.json") gatewayOrders
                envVars <- fakeCurlEnvironment tmpDir

                (exitCode, stdoutText, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["gateway", "status", configPath]){cwd = Just tmpDir, env = Just envVars}
                        ""

                exitCode `shouldBe` ExitSuccess
                stderrText `shouldBe` ""
                stdoutText `shouldContain` "Gateway status"
                stdoutText `shouldContain` "DNS_WRITE_GATE=code.example.com@Z123 ttl=60"
                stdoutText `shouldContain` "HEARTBEAT_NODE_B=1.5"

        it "runs native charts list, status, deploy, and delete through the built frontend with fake helm and kubectl" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig
                envVars <- fakeChartEnvironment tmpDir

                (listExitCode, listStdout, listStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["charts", "list"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                listExitCode `shouldBe` ExitSuccess
                listStderr `shouldBe` ""
                listStdout `shouldContain` "CHART_LIST"
                listStdout `shouldContain` "NAME=vscode"

                (statusExitCode, statusStdout, statusStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["charts", "status", "keycloak-postgres"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                statusExitCode `shouldBe` ExitSuccess
                statusStderr `shouldBe` ""
                statusStdout `shouldContain` "CHART_STATUS"
                statusStdout `shouldContain` "NAME=keycloak-postgres"
                statusStdout `shouldContain` "STORAGE_BINDING"

                (deployExitCode, deployStdout, deployStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["charts", "deploy", "keycloak-postgres"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                deployExitCode `shouldBe` ExitSuccess
                deployStderr `shouldBe` ""
                deployStdout `shouldContain` "CHART_DEPLOYMENT"
                deployStdout `shouldContain` "ROOT_CHART=keycloak-postgres"

                appliedManifest <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-apply.json")
                appliedManifest `shouldContain` "PersistentVolumeClaim"
                appliedManifest `shouldContain` "keycloak-postgres-data-0"

                upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
                upgradeRecord `shouldContain` "upgrade|--install|--wait|--atomic|--timeout|30m0s|keycloak-postgres"

                (deleteExitCode, deleteStdout, deleteStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["charts", "delete", "keycloak-postgres", "--yes"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                deleteExitCode `shouldBe` ExitSuccess
                deleteStderr `shouldBe` ""
                deleteStdout `shouldContain` "CHART_DELETION"
                deleteStdout `shouldContain` "HOST_STORAGE_PRESERVED=true"

                uninstallRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-uninstall.txt")
                uninstallRecord `shouldContain` "uninstall|keycloak-postgres|--namespace|keycloak-postgres"

                deleteRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-delete.txt")
                deleteRecord `shouldContain` "delete|pvc|keycloak-postgres-data-0|--namespace|keycloak-postgres"
                deleteRecord `shouldContain` "delete|pv|prodbox-chart-keycloak-postgres-keycloak-postgres-keycloak-postgres-0-data"
                deleteRecord `shouldContain` "delete|namespace|keycloak-postgres"

        it "runs native rke2 status, start, and logs through the built frontend with fake systemctl and journalctl" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                envVars <- fakeRke2Environment tmpDir

                (statusExitCode, statusStdout, statusStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["rke2", "status"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                statusExitCode `shouldBe` ExitSuccess
                statusStderr `shouldBe` ""
                statusStdout `shouldContain` "active"

                (startExitCode, startStdout, startStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["rke2", "start"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                startExitCode `shouldBe` ExitSuccess
                startStdout `shouldBe` ""
                startStderr `shouldBe` ""

                (logsExitCode, logsStdout, logsStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["rke2", "logs", "--lines", "25"]){cwd = Just tmpDir, env = Just envVars}
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

        it "runs native rke2 install and delete through the built frontend with fake host, kubectl, helm, docker, and native AWS destroy helpers" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig
                envVars <- fakeRke2Environment tmpDir

                (installExitCode, installStdout, installStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["rke2", "install"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                installExitCode `shouldBe` ExitSuccess
                installStdout `shouldContain` "Kubernetes control plane is running"
                installStderr `shouldBe` ""

                createDirectoryIfMissing True (tmpDir </> ".kube")
                writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

                (deleteExitCode, deleteStdout, deleteStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["rke2", "delete", "--yes"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                deleteExitCode `shouldBe` ExitSuccess
                deleteStderr `shouldBe` ""
                deleteStdout `shouldContain` "Preserved host state:"
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
                sudoRecord `shouldContain` "rm|-rf|/var/lib/rancher/rke2|/var/lib/rancher|/etc/rancher/rke2|/usr/local/bin/rke2|/usr/local/bin/rke2-killall.sh|/usr/local/bin/rke2-uninstall.sh"

                kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
                kubectlRecord `shouldContain` "cluster-info"
                kubectlRecord `shouldContain` "get|nodes|-o|name"
                kubectlRecord `shouldContain` "wait|--for=condition=Ready|node|--all|--timeout=300s"
                kubectlRecord `shouldContain` "get|storageclass|-o|name"
                kubectlRecord `shouldContain` "delete|storageclass|storageclass.storage.k8s.io/local-path|--ignore-not-found=true"
                kubectlRecord `shouldContain` "patch|deployment|harbor-nginx|-n|harbor|--type|strategic|--patch|"
                kubectlRecord `shouldContain` "annotate|namespace/prodbox|prodbox.io/id=prodbox-"
                kubectlRecord `shouldContain` "label|namespace/prodbox|prodbox.io/id=prodbox-"

                applyIdentity <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl-apply-1.json")
                applyIdentity `shouldContain` "prodbox-identity"
                applyStorage <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl-apply-2.json")
                applyStorage `shouldContain` "PersistentVolumeClaim"
                applyStorage `shouldContain` "prodbox-minio-pv-0"
                applyHarbor <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl-apply-3.json")
                applyHarbor `shouldContain` "nginx.conf"
                applyHarbor `shouldContain` "/readyz"

                helmRecord <- readFile (tmpDir </> "fake-rke2-state" </> "helm.txt")
                helmRecord `shouldContain` "repo|add|minio|https://charts.min.io/"
                helmRecord `shouldContain` "upgrade|--install|minio|minio/minio"
                helmRecord `shouldContain` "repo|add|harbor|https://helm.goharbor.io"
                helmRecord `shouldContain` "upgrade|--install|harbor|harbor/harbor"

                dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
                dockerRecord `shouldContain` "login|127.0.0.1:30080|--username|admin|--password|Harbor12345"
                dockerRecord `shouldContain` "build|-f|docker/gateway.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-gateway:prodbox-"
                dockerRecord `shouldContain` "build|-f|docker/nginx-oidc.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-nginx-oidc:latest|."
                dockerRecord `shouldContain` "save|-o|"

                curlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "curl.txt")
                curlRecord `shouldContain` "https://get.rke2.io"
                curlRecord `shouldContain` "/api/v2.0/projects"

        it "runs native pulumi preview, up, refresh, and stack-init through the built frontend with fake pulumi and kubectl" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfig
                envVars <- fakePulumiEnvironment tmpDir

                (previewExitCode, previewStdout, previewStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["pulumi", "preview"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                previewExitCode `shouldBe` ExitSuccess
                previewStderr `shouldBe` ""
                previewStdout `shouldContain` "PULUMI_PREVIEW"

                (upExitCode, upStdout, upStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["pulumi", "up", "--yes"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                upExitCode `shouldBe` ExitSuccess
                upStderr `shouldBe` ""
                upStdout `shouldContain` "PULUMI_UP"

                (refreshExitCode, refreshStdout, refreshStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["pulumi", "refresh"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                refreshExitCode `shouldBe` ExitSuccess
                refreshStderr `shouldBe` ""
                refreshStdout `shouldContain` "PULUMI_REFRESH"

                (stackInitExitCode, stackInitStdout, stackInitStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["pulumi", "stack-init", "dev"]){cwd = Just tmpDir, env = Just envVars}
                        ""

                stackInitExitCode `shouldBe` ExitSuccess
                stackInitStderr `shouldBe` ""
                stackInitStdout `shouldContain` "STACK_INIT=dev"

                pulumiRecord <- readFile (tmpDir </> "fake-pulumi-state" </> "calls.txt")
                pulumiRecord `shouldContain` "ARGV=whoami"
                pulumiRecord `shouldContain` "ARGV=stack|select|home"
                pulumiRecord `shouldContain` "ARGV=preview|--stack|home"
                pulumiRecord `shouldContain` "ARGV=stack|select|home|--create"
                pulumiRecord `shouldContain` "ARGV=up|--yes|--stack|home"
                pulumiRecord `shouldContain` "ARGV=refresh|--stack|home"
                pulumiRecord `shouldContain` "ARGV=stack|init|dev"
                pulumiRecord `shouldContain` ("PULUMI_BACKEND_URL=file://" ++ (tmpDir </> ".pulumi-backend"))
                pulumiRecord `shouldContain` "PULUMI_CONFIG_PASSPHRASE="
                pulumiRecord `shouldContain` "AWS_ACCESS_KEY_ID=test-access-key"
                pulumiRecord `shouldContain` "AWS_SECRET_ACCESS_KEY=test-secret-key"
                pulumiRecord `shouldContain` "AWS_SESSION_TOKEN=test-session-token"
                pulumiRecord `shouldContain` "AWS_REGION=us-east-1"
                pulumiRecord `shouldContain` "PRODBOX_ID=prodbox-"

                kubectlRecord <- readFile (tmpDir </> "fake-pulumi-state" </> "kubectl.txt")
                kubectlRecord `shouldContain` "apply|-f|"
                kubectlRecord `shouldContain` "annotate|namespace/prodbox|prodbox.io/id=prodbox-"
                kubectlRecord `shouldContain` "label|namespace/prodbox|prodbox.io/id=prodbox-"
                kubectlRecord `shouldContain` "annotate|deployments.apps|--all|prodbox.io/id=prodbox-"
                kubectlRecord `shouldContain` "annotate|clusterroles.rbac.authorization.k8s.io|-l|app.kubernetes.io/instance=harbor|--all|prodbox.io/id=prodbox-"

                applyManifest <- readFile (tmpDir </> "fake-pulumi-state" </> "kubectl-apply.json")
                applyManifest `shouldContain` "\"ConfigMap\""
                applyManifest `shouldContain` "\"prodbox-identity\""
                applyManifest `shouldContain` "\"machine_id\""

        it "runs native gateway start and fails gracefully with a missing config" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                let configPath = tmpDir </> "nonexistent-gateway.json"

                (exitCode, _, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["gateway", "start", configPath]){cwd = Just tmpDir}
                        ""

                exitCode `shouldBe` ExitFailure 1
                stderrText `shouldContain` "gateway daemon config"

        it "runs native config setup through the built frontend with a fake AWS CLI" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                repoRoot <- getCurrentDirectory
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                copySchema repoRoot tmpDir
                envVars <- fakeAwsEnvironment tmpDir

                let inputText =
                        unlines
                            [ "",
                              "ADMINKEY",
                              "admin-secret",
                              "",
                              "",
                              "1",
                              "1",
                              "",
                              "",
                              "",
                              "2",
                              "ops@example.com",
                              "1",
                              "",
                              "",
                              "",
                              ""
                            ]

                (exitCode, stdoutText, stderrText) <-
                    readCreateProcessWithExitCode
                        (proc binary ["config", "setup"]){cwd = Just tmpDir, env = Just envVars}
                        inputText

                exitCode `shouldBe` ExitSuccess
                stderrText `shouldBe` ""
                stdoutText `shouldContain` "ROUTE53_ZONE_ID=Z1234567890ABC"
                stdoutText `shouldContain` "AWS_ACCESS_KEY_ID=AKIAFAKESETUP"
                configText <- readFile (tmpDir </> "prodbox-config.dhall")
                configText `shouldContain` "access_key_id = \"AKIAFAKESETUP\""
                configText `shouldContain` "route53 = { zone_id = \"Z1234567890ABC\" }"
                configText `shouldContain` "demo_fqdn = \"demo.example.com\""
                jsonExists <- doesFileExist (tmpDir </> "prodbox-config.json")
                jsonExists `shouldBe` False

        it "runs native aws setup and teardown through the built frontend with a fake AWS CLI" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                repoRoot <- getCurrentDirectory
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                copySchema repoRoot tmpDir
                writeFile (tmpDir </> "prodbox-config.dhall") validConfigWithBlankOperationalAws
                envVars <- fakeAwsEnvironment tmpDir

                let setupInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]
                (setupExitCode, setupStdout, setupStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["aws", "setup", "--tier", "full"]){cwd = Just tmpDir, env = Just envVars}
                        setupInput

                setupExitCode `shouldBe` ExitSuccess
                setupStderr `shouldBe` ""
                setupStdout `shouldContain` "IAM_USER=prodbox"
                setupStdout `shouldContain` "POLICY_TIER=full"
                setupStdout `shouldContain` "AWS_ACCESS_KEY_ID=AKIAFAKESETUP"

                configAfterSetup <- readFile (tmpDir </> "prodbox-config.dhall")
                configAfterSetup `shouldContain` "access_key_id = \"AKIAFAKESETUP\""

                let teardownInput = unlines ["ADMINKEY", "admin-secret", "", ""]
                (teardownExitCode, teardownStdout, teardownStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["aws", "teardown"]){cwd = Just tmpDir, env = Just envVars}
                        teardownInput

                teardownExitCode `shouldBe` ExitSuccess
                teardownStderr `shouldBe` ""
                teardownStdout `shouldContain` "USER_DELETED=true"
                teardownStdout `shouldContain` "DELETED_ACCESS_KEYS=1"

                configAfterTeardown <- readFile (tmpDir </> "prodbox-config.dhall")
                configAfterTeardown `shouldContain` "access_key_id = \"\""
                configAfterTeardown `shouldContain` "secret_access_key = \"\""

        it "runs native aws quota inspection and request flows through the built frontend with a fake AWS CLI" $
            withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
                binary <- resolveBinaryPath
                writeRepoMarkers tmpDir
                envVars <- fakeAwsEnvironment tmpDir
                let commandInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]

                (checkExitCode, checkStdout, checkStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["aws", "check-quotas"]){cwd = Just tmpDir, env = Just envVars}
                        commandInput

                checkExitCode `shouldBe` ExitSuccess
                checkStderr `shouldBe` ""
                checkStdout `shouldContain` "Supported AWS Quotas"
                checkStdout `shouldContain` "Running On-Demand Standard vCPU"
                checkStdout `shouldContain` "Elastic IP addresses"

                (requestExitCode, requestStdout, requestStderr) <-
                    readCreateProcessWithExitCode
                        (proc binary ["aws", "request-quotas", "--tier", "core"]){cwd = Just tmpDir, env = Just envVars}
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
            (proc "cabal" ["build", "--builddir=.build", "exe:prodbox"]){cwd = Just repoRoot, env = Just buildEnvironment}
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

copySchema :: FilePath -> FilePath -> IO ()
copySchema sourceRoot targetRoot =
    copyFile (sourceRoot </> "prodbox-config-types.dhall") (targetRoot </> "prodbox-config-types.dhall")

fakeCurlEnvironment :: FilePath -> IO [(String, String)]
fakeCurlEnvironment repoRoot = do
    fakeBin <- writeFakeCurlScript repoRoot
    currentEnvironment <- getEnvironment
    let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
        updatedPath = fakeBin ++ ":" ++ existingPath
    pure (("PATH", updatedPath) : filter ((/= "PATH") . fst) currentEnvironment)

writeFakeCurlScript :: FilePath -> IO FilePath
writeFakeCurlScript repoRoot = do
    let binDir = repoRoot </> "bin"
        scriptPath = binDir </> "curl"
    createDirectoryIfMissing True binDir
    writeFile scriptPath fakeCurlScript
    permissions <- getPermissions scriptPath
    setPermissions scriptPath permissions{executable = True}
    pure binDir

fakeCurlScript :: String
fakeCurlScript =
    unlines
        [ "#!/usr/bin/env bash",
          "set -euo pipefail",
          "cat <<'JSON'",
          "{\"node_id\":\"node-a\",\"gateway_owner\":\"node-a\",\"has_active_claim\":true,\"mesh_peers\":[\"node-b\"],\"event_count\":5,\"last_public_ip_observed\":\"203.0.113.10\",\"last_dns_write_ip\":\"203.0.113.10\",\"last_dns_write_at_utc\":\"2026-04-06T10:00:00Z\",\"dns_write_gate\":{\"zone_id\":\"Z123\",\"fqdn\":\"code.example.com\",\"ttl\":60},\"heartbeat_age_seconds\":{\"node-a\":0.0,\"node-b\":1.5}}",
          "JSON"
        ]

fakeAwsEnvironment :: FilePath -> IO [(String, String)]
fakeAwsEnvironment repoRoot = do
    fakeBin <- writeFakeAwsScript repoRoot
    currentEnvironment <- getEnvironment
    let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
        updatedPath = fakeBin ++ ":" ++ existingPath
    pure (("PATH", updatedPath) : filter ((/= "PATH") . fst) currentEnvironment)

writeFakeAwsScript :: FilePath -> IO FilePath
writeFakeAwsScript repoRoot = do
    let binDir = repoRoot </> "bin"
        stateDir = repoRoot </> "fake-aws-state"
        scriptPath = binDir </> "aws"
    createDirectoryIfMissing True binDir
    createDirectoryIfMissing True stateDir
    writeFile scriptPath (fakeAwsScript stateDir)
    permissions <- getPermissions scriptPath
    setPermissions scriptPath permissions{executable = True}
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
                (\(key, _) -> key /= "PATH" && key /= "PRODBOX_FAKE_CHART_RECORD_DIR" && key /= "PRODBOX_FAKE_HELM_LIST_JSON")
                currentEnvironment
    pure
        ( [ ("PATH", updatedPath),
            ("PRODBOX_FAKE_CHART_RECORD_DIR", recordDir),
            ("PRODBOX_FAKE_HELM_LIST_JSON", "[]")
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
    setPermissions scriptPath permissions{executable = True}

fakeHelmScript :: String
fakeHelmScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_CHART_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "record_args() {"
        , "  local target=$1"
        , "  shift"
        , "  local first=1"
        , "  : > \"$target\""
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
        , "    record_args \"$record_dir/helm-upgrade.txt\" \"$@\""
        , "    ;;"
        , "  uninstall)"
        , "    record_args \"$record_dir/helm-uninstall.txt\" \"$@\""
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
        , "mkdir -p \"$record_dir\""
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
        , "case \"${1:-} ${2:-}\" in"
        , "  'get nodes')"
        , "    cat <<'JSON'"
        , "{\"items\":[{\"metadata\":{\"name\":\"bathurst\"}}]}"
        , "JSON"
        , "    ;;"
        , "  'get pv')"
        , "    printf 'Error from server (NotFound): persistentvolumes \"%s\" not found\\n' \"${3:-pv}\" >&2"
        , "    exit 1"
        , "    ;;"
        , "  'apply -f')"
        , "    cp \"${3:?}\" \"$record_dir/kubectl-apply.json\""
        , "    ;;"
        , "  'delete pvc'|'delete pv'|'delete namespace')"
        , "    append_args \"$record_dir/kubectl-delete.txt\" \"$@\""
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
                (\(key, _) ->
                    not
                        ( key `elem`
                            [ "PATH",
                              "PRODBOX_FAKE_RKE2_RECORD_DIR",
                              "PRODBOX_RKE2_CONTAINERD_SOCKET",
                              "PRODBOX_RKE2_ENDPOINT_STATUS_ROOT",
                              "HOME"
                            ]
                        )
                )
                currentEnvironment
    pure
        ( [ ("PATH", updatedPath),
            ("PRODBOX_FAKE_RKE2_RECORD_DIR", recordDir),
            ("PRODBOX_RKE2_CONTAINERD_SOCKET", socketPath),
            ("PRODBOX_RKE2_ENDPOINT_STATUS_ROOT", endpointStatusRoot),
            ("HOME", repoRoot)
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
    pure binDir

fakeSystemctlScript :: String
fakeSystemctlScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "first=1"
        , "for arg in \"$@\"; do"
        , "  if [[ $first -eq 0 ]]; then"
        , "    printf '|' >> \"$record_dir/sudo.txt\""
        , "  fi"
        , "  first=0"
        , "  printf '%s' \"$arg\" >> \"$record_dir/sudo.txt\""
        , "done"
        , "printf '\\n' >> \"$record_dir/sudo.txt\""
        , "exec \"$@\""
        ]

fakeRke2TestScript :: String
fakeRke2TestScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "printf '%s\\n' \"$*\" >> \"$record_dir/test.txt\""
        , "case \"$*\" in"
        , "  '-x /usr/local/bin/rke2'|'-x /usr/local/bin/rke2-uninstall.sh')"
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        , "        printf 'customresourcedefinition.apiextensions.k8s.io/ingressroutes.traefik.io\\n'"
        , "        ;;"
        , "      pods)"
        , "        printf 'docker.io/library/busybox:latest\\ngoharbor/harbor-core:v2\\n'"
        , "        ;;"
        , "      *)"
        , "        ;;"
        , "    esac"
        , "    ;;"
        , "  wait)"
        , "    ;;"
        , "  apply)"
        , "    target=$(next_apply_target)"
        , "    /bin/cp \"${3:?}\" \"$target\""
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
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
        , "  manifest)"
        , "    exit 1"
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
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "printf '%s\\n' \"$*\" >> \"$record_dir/ctr.txt\""
        , "exit 0"
        ]

fakeRke2MkdirScript :: String
fakeRke2MkdirScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/mkdir.txt\""
        , "exit 0"
        ]

fakeRke2CpScript :: String
fakeRke2CpScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/cp.txt\""
        , "exit 0"
        ]

fakeRke2ChownScript :: String
fakeRke2ChownScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/chown.txt\""
        , "exit 0"
        ]

fakeRke2ChmodScript :: String
fakeRke2ChmodScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/chmod.txt\""
        , "exit 0"
        ]

fakeRke2RmScript :: String
fakeRke2RmScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/rm.txt\""
        , "exit 0"
        ]

fakeRke2CatScript :: String
fakeRke2CatScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
        , "printf '%s\\n' \"$*\" >> \"$record_dir/cat.txt\""
        , "printf 'cat: %s: No such file or directory\\n' \"${1:-file}\" >&2"
        , "exit 1"
        ]

fakePulumiEnvironment :: FilePath -> IO [(String, String)]
fakePulumiEnvironment repoRoot = do
    fakeBin <- writeFakePulumiScripts repoRoot
    let recordDir = repoRoot </> "fake-pulumi-state"
    createDirectoryIfMissing True recordDir
    currentEnvironment <- getEnvironment
    let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
        updatedPath = fakeBin ++ ":" ++ existingPath
        baseEnvironment =
            filter
                (\(key, _) ->
                    not
                        ( key `elem`
                            [ "PATH",
                              "PRODBOX_FAKE_PULUMI_RECORD_DIR",
                              "PULUMI_BACKEND_URL",
                              "PULUMI_CONFIG_PASSPHRASE",
                              "PULUMI_CONFIG_PASSPHRASE_FILE",
                              "AWS_ACCESS_KEY_ID",
                              "AWS_SECRET_ACCESS_KEY",
                              "AWS_SESSION_TOKEN",
                              "AWS_REGION",
                              "AWS_DEFAULT_REGION",
                              "PRODBOX_ID"
                            ]
                        )
                )
                currentEnvironment
    pure
        ( [ ("PATH", updatedPath),
            ("PRODBOX_FAKE_PULUMI_RECORD_DIR", recordDir)
          ]
            ++ baseEnvironment
        )

writeFakePulumiScripts :: FilePath -> IO FilePath
writeFakePulumiScripts repoRoot = do
    let binDir = repoRoot </> "bin"
    createDirectoryIfMissing True binDir
    writeExecutable (binDir </> "pulumi") fakePulumiScript
    writeExecutable (binDir </> "kubectl") fakePulumiKubectlScript
    pure binDir

fakePulumiScript :: String
fakePulumiScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_PULUMI_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "record_call() {"
        , "  {"
        , "    printf 'ARGV='"
        , "    local first=1"
        , "    for arg in \"$@\"; do"
        , "      if [[ $first -eq 0 ]]; then"
        , "        printf '|'"
        , "      fi"
        , "      first=0"
        , "      printf '%s' \"$arg\""
        , "    done"
        , "    printf '\\n'"
        , "    printf 'PULUMI_BACKEND_URL=%s\\n' \"${PULUMI_BACKEND_URL:-}\""
        , "    printf 'PULUMI_CONFIG_PASSPHRASE=%s\\n' \"${PULUMI_CONFIG_PASSPHRASE:-}\""
        , "    printf 'AWS_ACCESS_KEY_ID=%s\\n' \"${AWS_ACCESS_KEY_ID:-}\""
        , "    printf 'AWS_SECRET_ACCESS_KEY=%s\\n' \"${AWS_SECRET_ACCESS_KEY:-}\""
        , "    printf 'AWS_SESSION_TOKEN=%s\\n' \"${AWS_SESSION_TOKEN:-}\""
        , "    printf 'AWS_REGION=%s\\n' \"${AWS_REGION:-}\""
        , "    printf 'PRODBOX_ID=%s\\n\\n' \"${PRODBOX_ID:-}\""
        , "  } >> \"$record_dir/calls.txt\""
        , "}"
        , "record_call \"$@\""
        , "case \"${1:-}\" in"
        , "  whoami)"
        , "    printf 'fake-user\\n'"
        , "    ;;"
        , "  stack)"
        , "    case \"${2:-}\" in"
        , "      select)"
        , "        printf 'STACK_SELECTED=%s\\n' \"${3:-}\""
        , "        ;;"
        , "      init)"
        , "        printf 'STACK_INIT=%s\\n' \"${3:-}\""
        , "        ;;"
        , "      *)"
        , "        printf 'unsupported fake pulumi stack command: %s\\n' \"$*\" >&2"
        , "        exit 1"
        , "        ;;"
        , "    esac"
        , "    ;;"
        , "  preview)"
        , "    printf 'PULUMI_PREVIEW\\n'"
        , "    ;;"
        , "  up)"
        , "    printf 'PULUMI_UP\\n'"
        , "    ;;"
        , "  refresh)"
        , "    printf 'PULUMI_REFRESH\\n'"
        , "    ;;"
        , "  destroy)"
        , "    printf 'PULUMI_DESTROY\\n'"
        , "    ;;"
        , "  *)"
        , "    printf 'unsupported fake pulumi command: %s\\n' \"$*\" >&2"
        , "    exit 1"
        , "    ;;"
        , "esac"
        ]

fakePulumiKubectlScript :: String
fakePulumiKubectlScript =
    unlines
        [ "#!/usr/bin/env bash"
        , "set -euo pipefail"
        , "record_dir=${PRODBOX_FAKE_PULUMI_RECORD_DIR:?}"
        , "mkdir -p \"$record_dir\""
        , "append_args() {"
        , "  local first=1"
        , "  for arg in \"$@\"; do"
        , "    if [[ $first -eq 0 ]]; then"
        , "      printf '|' >> \"$record_dir/kubectl.txt\""
        , "    fi"
        , "    first=0"
        , "    printf '%s' \"$arg\" >> \"$record_dir/kubectl.txt\""
        , "  done"
        , "  printf '\\n' >> \"$record_dir/kubectl.txt\""
        , "}"
        , "append_args \"$@\""
        , "case \"${1:-}\" in"
        , "  api-resources)"
        , "    if [[ \"$*\" == *\"--namespaced=true\"* ]]; then"
        , "      printf 'deployments.apps\\nconfigmaps\\nevents.events.k8s.io\\n'"
        , "    else"
        , "      printf 'clusterroles.rbac.authorization.k8s.io\\n'"
        , "    fi"
        , "    ;;"
        , "  get)"
        , "    case \"${2:-}\" in"
        , "      deployments.apps)"
        , "        if [[ \"$*\" == *\"-n prodbox\"* ]]; then"
        , "          printf 'deployment.apps/prodbox-api\\n'"
        , "        fi"
        , "        ;;"
        , "      configmaps)"
        , "        if [[ \"$*\" == *\"-n prodbox\"* ]]; then"
        , "          printf 'configmap/existing-config\\n'"
        , "        fi"
        , "        ;;"
        , "      clusterroles.rbac.authorization.k8s.io)"
        , "        if [[ \"$*\" == *\"app.kubernetes.io/instance=harbor\"* ]]; then"
        , "          printf 'clusterrole.rbac.authorization.k8s.io/harbor-role\\n'"
        , "        fi"
        , "        ;;"
        , "      crd)"
        , "        printf 'customresourcedefinition.apiextensions.k8s.io/ingressroutes.traefik.io\\n'"
        , "        ;;"
        , "      *)"
        , "        ;;"
        , "    esac"
        , "    ;;"
        , "  apply)"
        , "    cp \"${3:?}\" \"$record_dir/kubectl-apply.json\""
        , "    ;;"
        , "  annotate|label)"
        , "    ;;"
        , "  *)"
        , "    printf 'unsupported fake kubectl command: %s\\n' \"$*\" >&2"
        , "    exit 1"
        , "    ;;"
        , "esac"
        ]

fakeAwsScript :: FilePath -> String
fakeAwsScript stateDir =
    unlines
        [ "#!/usr/bin/env bash",
          "set -euo pipefail",
          "STATE_DIR=\"" ++ stateDir ++ "\"",
          "mkdir -p \"$STATE_DIR\"",
          "if [[ $# -ge 2 && \"${@: -2:1}\" == \"--output\" ]]; then",
          "  set -- \"${@:1:$#-2}\"",
          "fi",
          "service=${1:-}",
          "action=${2:-}",
          "case \"$service $action\" in",
          "  \"ec2 describe-regions\")",
          "    cat <<'JSON'",
          "{\"Regions\":[{\"RegionName\":\"us-east-1\",\"OptInStatus\":\"opt-in-not-required\"},{\"RegionName\":\"us-west-2\",\"OptInStatus\":\"opt-in-not-required\"}]}",
          "JSON",
          "    ;;",
          "  \"route53 list-hosted-zones\")",
          "    cat <<'JSON'",
          "{\"HostedZones\":[{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"example.com.\"}]}",
          "JSON",
          "    ;;",
          "  \"iam create-user\")",
          "    touch \"$STATE_DIR/user_exists\"",
          "    printf '{}\\n'",
          "    ;;",
          "  \"iam list-access-keys\")",
          "    if [[ -f \"$STATE_DIR/access_key_id\" ]]; then",
          "      access_key_id=$(cat \"$STATE_DIR/access_key_id\")",
          "      printf '{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"%s\"}]}\\n' \"$access_key_id\"",
          "    else",
          "      printf '{\"AccessKeyMetadata\":[]}\\n'",
          "    fi",
          "    ;;",
          "  \"iam delete-access-key\")",
          "    rm -f \"$STATE_DIR/access_key_id\"",
          "    printf '{}\\n'",
          "    ;;",
          "  \"iam put-user-policy\")",
          "    printf '{}\\n'",
          "    ;;",
          "  \"iam create-access-key\")",
          "    printf 'AKIAFAKESETUP' > \"$STATE_DIR/access_key_id\"",
          "    cat <<'JSON'",
          "{\"AccessKey\":{\"AccessKeyId\":\"AKIAFAKESETUP\",\"SecretAccessKey\":\"fake-secret-access-key\"}}",
          "JSON",
          "    ;;",
          "  \"iam delete-user-policy\")",
          "    printf '{}\\n'",
          "    ;;",
          "  \"iam delete-user\")",
          "    rm -f \"$STATE_DIR/user_exists\"",
          "    printf '{}\\n'",
          "    ;;",
          "  \"service-quotas get-service-quota\")",
          "    cat <<'JSON'",
          "{\"Quota\":{\"Value\":8.0}}",
          "JSON",
          "    ;;",
          "  \"service-quotas get-aws-default-service-quota\")",
          "    cat <<'JSON'",
          "{\"Quota\":{\"Value\":8.0}}",
          "JSON",
          "    ;;",
          "  \"service-quotas request-service-quota-increase\")",
          "    cat <<'JSON'",
          "{\"RequestedQuota\":{\"Status\":\"PENDING\"}}",
          "JSON",
          "    ;;",
          "  \"sts get-caller-identity\")",
          "    cat <<'JSON'",
          "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox\",\"UserId\":\"AIDAFake\"}",
          "JSON",
          "    ;;",
          "  *)",
          "    printf 'unsupported fake aws command: %s %s\\n' \"$service\" \"$action\" >&2",
          "    exit 1",
          "    ;;",
          "esac"
        ]

gatewayStatusConfig :: String
gatewayStatusConfig =
    unlines
        [ "{",
          "  \"node_id\": \"node-a\",",
          "  \"cert_file\": \"node-a.crt\",",
          "  \"key_file\": \"node-a.key\",",
          "  \"ca_file\": \"ca.crt\",",
          "  \"orders_file\": \"orders.json\",",
          "  \"event_keys\": { \"node-a\": \"REPLACE_WITH_SECRET_KEY\" },",
          "  \"heartbeat_interval_seconds\": 1.0,",
          "  \"reconnect_interval_seconds\": 1.0,",
          "  \"sync_interval_seconds\": 5.0,",
          "  \"dns_write_gate\": {",
          "    \"zone_id\": \"Z123\",",
          "    \"fqdn\": \"code.example.com\",",
          "    \"ttl\": 60,",
          "    \"aws_region\": \"us-east-1\"",
          "  }",
          "}"
        ]

gatewayOrders :: String
gatewayOrders =
    unlines
        [ "{",
          "  \"version_utc\": 1,",
          "  \"nodes\": [",
          "    {",
          "      \"node_id\": \"node-a\",",
          "      \"stable_dns_name\": \"node-a.example.test\",",
          "      \"rest_host\": \"0.0.0.0\",",
          "      \"rest_port\": 31001,",
          "      \"socket_host\": \"0.0.0.0\",",
          "      \"socket_port\": 32001",
          "    }",
          "  ],",
          "  \"gateway_rule\": {",
          "    \"ranked_nodes\": [\"node-a\"],",
          "    \"heartbeat_timeout_seconds\": 3",
          "  }",
          "}"
        ]

validConfig :: String
validConfig =
    configWithAws "test-access-key" "test-secret-key" "Some \"test-session-token\""

validConfigWithBlankOperationalAws :: String
validConfigWithBlankOperationalAws =
    configWithAws "" "" "None Text"

configWithAws :: String -> String -> String -> String
configWithAws accessKeyId secretAccessKey sessionTokenValue =
    unlines
        [ "{ aws = { access_key_id = \"" ++ accessKeyId ++ "\", secret_access_key = \"" ++ secretAccessKey ++ "\", session_token = " ++ sessionTokenValue ++ ", region = \"us-east-1\" }",
          ", aws_admin = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }",
          ", route53 = { zone_id = \"Z1234567890ABC\" }",
          ", domain = { demo_fqdn = \"test.example.com\", demo_ttl = 60, vscode_fqdn = Some \"vscode.example.com\" }",
          ", acme = { email = \"test@example.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }",
          ", deployment = { dev_mode = True, bootstrap_public_ip_override = None Text, pulumi_enable_dns_bootstrap = True }",
          ", storage = { manual_pv_host_root = \".data\" }",
          "}"
        ]
