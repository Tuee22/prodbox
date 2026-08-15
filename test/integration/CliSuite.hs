module CliSuite
  ( integrationCliSuite
  , runInstalledWithFakeAuthority
  , runRke2AdmissionRefusalFixture
  , runRunbookFailureFixture
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
import Data.List (find, findIndex, intercalate, isInfixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (nominalDiffTimeToSeconds)
import Data.Time.Clock.POSIX (getPOSIXTime)
import FixtureServer (withVaultFixtureServer)
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
import Prodbox.CLI.Rke2 qualified as Rke2
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Config.ComponentGraph qualified as ComponentGraph
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetText
  )

-- Sprint 4.64: the empty admission set is package-internal so no production
-- module can begin a phase with one; a fixture driving the executor directly
-- still needs it, and the `dev check` rule barring this import is scoped to
-- `src/`.
import Prodbox.Lifecycle.DependencyAdmission.Internal (noAdmissions)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (SecretRefVault)
  , VaultSecretRef (..)
  )
import Prodbox.TestRunner qualified as TestRunner
import Prodbox.TestValidation qualified as TestValidation
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
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO qualified as IO
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
import Tier0Fixture
  ( tier0FixtureWithContext
  , tier0FixtureWithParameters
  , writeTier0Fixture
  )

integrationCliSuite :: SuiteBuilder ()
integrationCliSuite = do
  describe "native Haskell config CLI" $ do
    it "shows masked settings from a repo-root Dhall config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "show"]

        when (exitCode /= ExitSuccess) (expectationFailure stderrText)
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "aws.access_key_id=Vault:secret/aws/lifecycle-provider#access_key_id"
        stdoutText `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))

    it "validates config without requiring any Python backend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "validate"]

        when (exitCode /= ExitSuccess) (expectationFailure (stdoutText ++ stderrText))
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""

    it "accepts the generated GHC RTS heap-policy arguments" $ do
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["+RTS", "-M268435456", "-RTS", "--version"])
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "0.1.0"

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

    it "proves semantic SES readiness through the built read-only prerequisite frontend" $
      withSystemTempDirectory "prodbox-hs-ses-ready" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIASESREADY"
          "ses-ready-secret"
          Nothing
          "us-east-1"
        envVars <- fakeSesReadinessEnvironment tmpDir "ready"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["host", "check-ses-readiness"]
            envVars

        (exitCode, stderrText) `shouldBe` (ExitSuccess, "")
        stdoutText `shouldContain` "Retained SES semantic readiness: Ready"
        commands <- readFile (tmpDir </> "fake-ses-readiness-aws.txt")
        commands `shouldBe` "--version\n"
        commands `shouldNotContain` "create-"
        commands `shouldNotContain` "update-"
        commands `shouldNotContain` "put-"
        commands `shouldNotContain` "delete-"

    it "reports an exit-zero semantic SES failure with the registry remedy through the built frontend" $
      withSystemTempDirectory "prodbox-hs-ses-failed" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIASESFAILED"
          "ses-failed-secret"
          Nothing
          "us-east-1"
        envVars <- fakeSesReadinessEnvironment tmpDir "identity-failed"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["host", "check-ses-readiness"]
            envVars

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldBe` ""
        stderrText `shouldContain` "ses_sending_identity_verified"
        stderrText
          `shouldContain` "AWS credential check failed through the authenticated Lifecycle Authority/Provider Worker"
        stderrText `shouldContain` "VerifiedForSendingStatus=False"
        stderrText `shouldContain` "Remedy:"
        stderrText `shouldContain` "prodbox aws setup"
        stderrText `shouldNotContain` "aws stack aws-ses reconcile"
        stderrText `shouldNotContain` "pulumi up"
        stderrText `shouldNotContain` "manually provision"
        commands <- readFile (tmpDir </> "fake-ses-readiness-aws.txt")
        commands `shouldNotContain` "create-"
        commands `shouldNotContain` "update-"
        commands `shouldNotContain` "put-"
        commands `shouldNotContain` "delete-"

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
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        let outputPath = tmpDir </> "gateway.dhall"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority
            tmpDir
            binary
            ["gateway", "config-gen", outputPath, "--node-id", "node-a"]

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

    it "vault status uses the caller-bound Bootstrap Broker transport" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["vault", "status"]

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText
          `shouldContain` "Vault status: {\"initialization_ambiguous\":false,\"initialized\":true,\"sealed\":false,\"storage_generation\":\"1\"}"

    it "Bootstrap Broker Vault decode failures do not fall back to direct host Vault" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnv <- getEnvironment

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["vault", "status"]
            (("PRODBOX_TEST_BROKER_STATUS_MODE", "malformed") : baseEnv)

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "Vault status failed: HTTP response decode error"

    it "Sprint 4.50: removed gateway federation endpoints stay absent" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          writeRepoMarkers tmpDir
          writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
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
            -- Wait for the real listener, then prove neither fixed nor
            -- variable-suffix federation transport survived the cutover.
            waitForGatewayHealthyProcess restPort processHandle stdoutPath stderrPath
            childrenResult <-
              httpGetText
                (HttpConfig 1000000)
                ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children")
            childrenResult `shouldBe` Left (HttpStatus 404 "not found\n")
            bootstrapResult <-
              httpGetText
                (HttpConfig 1000000)
                ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children/child-a/bootstrap")
            bootstrapResult `shouldBe` Left (HttpStatus 404 "not found\n")

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

    it "Sprint 5.33: gateway-partition is no longer an integration node" $ do
      -- Standard C. This case asserted the node's integration output. The
      -- composition is a legitimate in-process property test over the real
      -- GatewayState folds, but it engaged no harness, emitted its verdict
      -- lines as literals, and was cited as numbered `Validation` evidence in
      -- eight `Done` Phase-2 sprints for peer, restart, and partition
      -- properties nothing exercised. It moved to the unit suite; the CLI must
      -- no longer advertise or accept it.
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, _, _) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "gateway-partition"]) {cwd = Just repoRoot}
          ""
      exitCode `shouldNotBe` ExitSuccess

      (helpExit, helpStdout, _) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "--help"]) {cwd = Just repoRoot}
          ""
      helpExit `shouldBe` ExitSuccess
      helpStdout `shouldNotContain` "gateway-partition"

    it "runs the frozen control-plane counterexample through an installed binary" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              }
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=control-plane-counterexample substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "COUNTEREXAMPLE=LCPC-2026-07-11"
        stdoutText `shouldContain` "SUPERSEDED_FAILURES=5"
        stdoutText `shouldContain` "REPLACEMENT_CLOSURES=5"
        stdoutText `shouldContain` "NORMALIZED_ENVELOPE_EQUAL=true"
        stdoutText `shouldContain` "INVITE_FAULT_MATRIX=23"
        stdoutText `shouldContain` "INVITE_ASSERTIONS=8"
        stdoutText `shouldContain` "DEPLOYMENT_QUALIFICATION=QualificationPendingLiveEvidence"

    it "Sprint 5.32: the frozen counterexample fails against the committed mutation fixture" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        -- The acceptance criterion. Until Sprint 5.32,
        -- `simulateFrozenCounterexample` discarded its `FrozenCounterexampleTrace`
        -- and regenerated both halves from an in-module composition constant,
        -- so `complete` was True for every input and this command could not
        -- fail. A reproducer that passes both fixtures is not a reproducer.
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        parentEnv <- getEnvironment

        (mutatedExit, _, mutatedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              , env =
                  Just (("PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE", "mutated") : parentEnv)
              }
            ""
        mutatedExit `shouldBe` ExitFailure 1
        mutatedStderr `shouldContain` "GatewayDeadlineUnderThrottle"
        mutatedStderr `shouldContain` "not recorded as failing on"

        -- An unrecognised selector refuses rather than falling back to the
        -- canonical (passing) fixture.
        (typoExit, _, typoStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              , env =
                  Just (("PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE", "canonicaal") : parentEnv)
              }
            ""
        typoExit `shouldBe` ExitFailure 1
        typoStderr `shouldContain` "is not a known frozen fixture"

    it "exposes the certificate-scope serving validation through an installed binary" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "certificate-scope", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Verify live TLS serving and the exact presented SAN scope"

    it "exposes the clean-room handoff validation through an installed binary" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "clean-room-handoff", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Verify clean-room migration, rollback refusal, and legacy absence"

    it "runs native resource-guardrails validation through fake Kubernetes resource JSON" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "resource-guardrails"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        let output =
              unlines
                [ "resource-guardrails exit: " <> show exitCode
                , "resource-guardrails stdout:"
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

    it "runs gateway-pods through the bounded runtime-stability oracle" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "gateway-pods"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        let output =
              unlines
                [ "gateway-pods stdout:"
                , stdoutText
                , "gateway-pods stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure output)
        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=gateway-pods substrate=home-local] entering body"
        stderrText
          `shouldContain` "[validation=gateway-pods substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "GATEWAY_RUNTIME_STABILITY_VALIDATION"
        stdoutText `shouldContain` "CLASSIFICATION=stable"
        stdoutText `shouldContain` "STABLE_SAMPLES=3"

    it "keeps a mid-run gateway OOM absorbing after later healthy samples" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        baseEnv <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_GATEWAY_OOM_PODS_SAMPLE", "2")
                : baseEnv
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "gateway-pods"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "Gateway runtime is unhealthy"
        stderrText `shouldContain` "oom-killed-residue"
        stderrText `shouldContain` "termination_reason=OOMKilled"
        stdoutText `shouldNotContain` "CLASSIFICATION=stable"

        gatewayPodSampleCount <-
          readFile (tmpDir </> "fake-rke2-state" </> "gateway-pods-sample.count")
        (read gatewayPodSampleCount :: Int) `shouldSatisfy` (>= 3)
        kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
        kubectlRecord
          `shouldContain` "get|pods|--namespace|gateway|-o|json|--request-timeout=5s"

    it "runs native daemon-bootstrap validation and rejects legacy transport traces" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        let fakeBin = tmpDir </> "bin"
        createDirectoryIfMissing True fakeBin
        writeExecutable (fakeBin </> "cabal") (fakeCabalListBinScript binary)
        currentEnvironment <- getEnvironment
        let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
            baseEnvironment =
              ("PATH", fakeBin ++ ":" ++ existingPath)
                : filter
                  ( \entry ->
                      fst entry
                        `notElem` [ "PATH"
                                  , "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
                                  ]
                  )
                  currentEnvironment
            envFor fixture =
              ("PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT", fixture)
                : baseEnvironment

        (passExitCode, passStdout, passStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just (envFor "pass")
              }
            ""

        let passOutput =
              unlines
                [ "daemon-bootstrap pass stdout:"
                , passStdout
                , "daemon-bootstrap pass stderr:"
                , passStderr
                ]
        when (passExitCode /= ExitSuccess) (expectationFailure passOutput)
        passStdout `shouldContain` "Validation: daemon-bootstrap"
        passStdout `shouldContain` "DAEMON_BOOTSTRAP_VALIDATION"
        passStdout `shouldContain` "LEGACY_TRANSPORTS=0"
        passStdout `shouldContain` "REDACTION=ok"
        passStderr
          `shouldContain` "[validation=daemon-bootstrap substrate=home-local] entering body"
        passStderr
          `shouldContain` "[validation=daemon-bootstrap substrate=home-local] body exit=ExitSuccess"

        (legacyExitCode, legacyStdout, legacyStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just (envFor "legacy-minio-port-forward")
              }
            ""

        legacyExitCode `shouldBe` ExitFailure 1
        legacyStdout `shouldContain` "Validation: daemon-bootstrap"
        legacyStderr `shouldContain` "legacy transport"
        legacyStderr `shouldContain` "port-forward service/minio"

        -- Sprint 5.33 unset-fixture exercise, and it is the acceptance
        -- criterion. With every PRODBOX_TEST_* fixture unset, this arm used to
        -- be byte-identical to the `"pass"` arm above and exited 0 having
        -- measured nothing. It must now refuse, naming what was absent,
        -- because no Bootstrap Broker daemon is serving in this fixture
        -- context.
        (unsetExitCode, _, unsetStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just baseEnvironment
              }
            ""

        unsetExitCode `shouldBe` ExitFailure 1
        unsetStderr `shouldContain` "measured nothing and refuses"
        unsetStderr `shouldContain` "no Bootstrap Broker daemon answered"

        -- And the fixture arm now says it was a fixture.
        passStdout `shouldContain` "AUDIT_PROVENANCE=fixture:pass"

    it
      "runs native charts list, status, deploy, and delete through the built frontend with fake helm and kubectl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        envVars <- fakeChartEnvironment tmpDir

        (listExitCode, listStdout, listStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "list"] envVars

        listExitCode `shouldBe` ExitSuccess
        listStderr `shouldBe` ""
        listStdout `shouldContain` "CHART_LIST"
        listStdout `shouldContain` "NAME=vscode"

        (statusExitCode, statusStdout, statusStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "status", "vscode"] envVars

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "CHART_STATUS"
        statusStdout `shouldContain` "NAME=vscode"
        statusStdout `shouldContain` "STORAGE_BINDING"

        (deployExitCode, deployStdout, deployStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "reconcile", "vscode"] envVars

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
        kubectlRecord
          `shouldContain` "get|crd|perconapgclusters.pgv2.percona.com|--ignore-not-found|-o|name"
        -- Sprint 3.24: the one-shot operator gate tolerates absent objects while
        -- converging and opens only on the Deployment's Available=True condition.
        kubectlRecord
          `shouldContain` "get|deployment|postgres-operator|--namespace|postgres-operator|--ignore-not-found|-o|jsonpath={.status.conditions[?(@.type==\"Available\")].status}"
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
            -- The second reconcile models the fully-deployed steady state.
            -- Sprint 3.38 deliberately converges all three releases again;
            -- Helm's three-way merge, rather than a presence filter, owns the
            -- idempotent no-change decision.
            alreadyDeployedEnvVars =
              ( "PRODBOX_FAKE_HELM_LIST_JSON"
              , "[{\"name\":\"keycloak-postgres\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"keycloak\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"vscode\",\"namespace\":\"vscode\",\"status\":\"deployed\"}]"
              )
                : filter ((/= "PRODBOX_FAKE_HELM_LIST_JSON") . fst) envVars

        (secondDeployExitCode, secondDeployStdout, secondDeployStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["charts", "reconcile", "vscode"]
            alreadyDeployedEnvVars

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
        upgradeRecordAfterSecondDeploy
          `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|keycloak-postgres"
        upgradeRecordAfterSecondDeploy
          `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|vscode"

        chartStateFilesAfterSecondDeploy <- listDirectory (tmpDir </> "fake-chart-state")
        length
          [ path
          | path <- chartStateFilesAfterSecondDeploy
          , take 13 path == "kubectl-apply"
          ]
          `shouldBe` (initialApplyTargetCount + 5)

        (deleteExitCode, deleteStdout, deleteStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["charts", "delete", "vscode", "--yes"]
            envVars

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
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        -- Sprint 4.31: the retained ordinal-0 host data lives at the unified
        -- `.data/<namespace>/<StatefulSet>/<ordinal>` path (no `<release>` /
        -- `<claim>` segment), so the restore-staging detects it here.
        createDirectoryIfMissing
          True
          (tmpDir </> ".data" </> "vscode" </> "prodbox-vscode-pg" </> "0")
        baseEnvVars <- fakeChartEnvironment tmpDir
        let envVars = ("PRODBOX_FAKE_PATRONI_STAGED_RESTORE", "true") : baseEnvVars

        (deployExitCode, deployStdout, deployStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "reconcile", "vscode"] envVars

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
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
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
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        -- Sprint 1.42 Part B: with the Tier-0 prodbox.dhall floor present, the
        -- post-MinIO settings reload obtains the host Vault root token; supply
        -- the test seam so it does not try to decrypt an unlock bundle (none
        -- exists in this temp repo). The in-force SSoT seed against the real
        -- Vault fail-WARNs and the config read falls back to .parameters.
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir

        (installExitCode, installStdout, installStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile"]
            envVars

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
        -- registry:2 is applied as a plain Deployment + NodePort Service (no
        -- Harbor nginx `/readyz` readiness patch); reconcile waits for the
        -- Deployment to become Available.
        kubectlRecord `shouldNotContain` "harbor-nginx"
        kubectlRecord
          `shouldContain` "wait|--for=condition=Available|deployment/registry|-n|harbor|--timeout=300s"
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
        -- The registry:2 runtime manifest: Deployment pulling registry:2, its
        -- config.yml ConfigMap, and the S3 storage Secret consumed via envFrom.
        applyRegistryRuntime <- readAppliedManifestContaining rke2StateDir "registry:2"
        applyRegistryRuntime `shouldContain` "registry:2"
        applyRegistryRuntime `shouldContain` "config.yml"
        applyRegistryRuntime `shouldContain` harborRegistryStorageSecretName
        applyRegistryRuntime `shouldContain` "nodePort"
        -- registry:2 has no web UI, so only the MinIO console admin route remains.
        applyAdminRoutes <- readAppliedManifestContaining rke2StateDir "minio-console"
        applyAdminRoutes `shouldContain` "minio-console"
        applyAdminRoutes `shouldContain` "minio-oidc"
        applyAdminRoutes `shouldNotContain` "harbor-ui"
        applyAdminRoutes `shouldNotContain` "harbor-oidc"
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
        -- registry:2 replaces the Harbor helm stack: no helm repo/install for the
        -- registry (it is a single kubectl-applied Deployment). The registered
        -- desired-absence program observes a legacy release, uninstalls it, and
        -- positively reads absence back before registry:2 is applied.
        helmRecord `shouldNotContain` "upgrade|--install|harbor|harbor/harbor"
        helmRecord `shouldNotContain` "persistence.imageChartStorage.type=s3"
        helmRecord `shouldContain` "status|harbor|--namespace|harbor|--output|json"
        helmRecord `shouldContain` "uninstall|harbor|--namespace|harbor|--ignore-not-found"
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
        -- unlock bundle before Vault unseal). Both precede the registry:2 runtime
        -- (applied via kubectl, not helm).
        findRecordLineIndex "/charts/minio|--namespace|prodbox" helmRecord
          `shouldSatisfy` (< findRecordLineIndex "/charts/vault|--namespace|vault" helmRecord)

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        -- NO `docker login` runs at all — the registry:2 NodePort is anonymous, so
        -- pushes carry no credential; public pulls use the host docker.io login.
        dockerRecord `shouldNotContain` "login|127.0.0.1:30080"
        dockerRecord
          `shouldContain` "buildx|imagetools|inspect|--raw|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord `shouldNotContain` "docker/bitnami-postgresql-repmgr.Dockerfile"
        dockerRecord `shouldNotContain` "docker/bitnami-pgpool.Dockerfile"
        dockerRecord `shouldContain` "pull|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|docker.io/percona/percona-postgresql-operator:2.9.0"
        dockerRecord
          `shouldContain` "tag|docker.io/percona/percona-postgresql-operator:2.9.0|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "tag|ghcr.io/coder/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        countRecordLines
          "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
          dockerRecord
          `shouldBe` 2
        dockerRecord
          `shouldNotContain` "tag|docker.io/codercom/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        -- One union runtime image built from the single Dockerfile, consumed by
        -- the gateway daemon + api/websocket workloads (role chosen by chart args).
        dockerRecord
          `shouldContain` "build|-f|docker/prodbox.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord `shouldContain` "-t|127.0.0.1:30080/prodbox/prodbox-runtime:latest|."
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/prodbox-runtime:latest"
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
        -- registry:2 readiness is a plain GET /v2/ probe — no Harbor /readyz
        -- nginx endpoint and no /api/v2.0 projects REST reconcile.
        curlRecord `shouldContain` "http://127.0.0.1:30080/v2/"
        curlRecord `shouldNotContain` "http://127.0.0.1:30080/readyz"
        curlRecord `shouldNotContain` "/api/v2.0/projects"

        pulumiRecordExists <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRecordExists `shouldBe` False

        -- Sprint 5.31 closure evidence: exercise both process-facing crossings
        -- in isolated helper processes so the assertion observes the real file
        -- descriptors rather than an injected writer. The RKE2 caller renders
        -- the exact typed refusal to stderr; the runbook wrapper then names a
        -- silent failing child on stderr without contaminating stdout.
        integrationExecutable <- getExecutablePath
        (admissionExitCode, admissionStdout, admissionStderr) <-
          readCreateProcessWithExitCode
            (proc integrationExecutable ["--fixture-rke2-admission-refusal", tmpDir])
            ""
        admissionExitCode `shouldBe` ExitFailure 1
        admissionStdout `shouldBe` ""
        admissionStderr `shouldContain` "mutating `chart_authority_backup` requires an admission"
        admissionStderr `shouldContain` "which was never observed ready in this run"

        let runbookFixtureRoot = tmpDir </> "runbook-diagnostic"
            silentFailingOperator = runbookFixtureRoot </> ".build" </> "prodbox"
        createDirectoryIfMissing True (runbookFixtureRoot </> ".build")
        writeExecutable silentFailingOperator "#!/bin/sh\nexit 23\n"
        (runbookExitCode, runbookStdout, runbookStderr) <-
          readCreateProcessWithExitCode
            (proc integrationExecutable ["--fixture-runbook-failure", runbookFixtureRoot])
            ""
        runbookExitCode `shouldBe` ExitFailure 23
        runbookStdout `shouldBe` ""
        runbookStderr
          `shouldContain` "Integration runbook step failed: prodbox cluster reconcile --with-edge (exit 23)"

    it "falls back to mirror.gcr when Docker Hub rate-limits a supported Percona image" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ( "PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF"
              , "docker.io/percona/percona-distribution-postgresql:17.9-1"
              )
                : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                : baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile"]
            envVars

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
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|docker.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord
          `shouldContain` "tag|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"

    it "summarizes noisy uninstall-script cleanup instead of streaming raw delete traces" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
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
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
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
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
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
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
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
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
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
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
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
      "nuke --dry-run renders the authenticated shared-bucket-terminal protocol"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)

        (exitCode, stdoutText, _) <-
          readCreateProcessWithExitCode
            (proc binary ["nuke", "--dry-run"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stdoutText `shouldContain` "PRODBOX_NUKE_PLAN"
        stdoutText `shouldContain` "PROTOCOL=signed-external-decommission-v1"
        stdoutText `shouldContain` "NODE=shared-object-bucket (unique terminal)"
        stdoutText `shouldContain` "CONFIRMATION_LITERAL=NUKE EVERYTHING"

    it "Sprint 8.8: nuke refuses the total teardown when the typed confirmation is wrong" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)
        envVars <- fakeRke2Environment tmpDir
        let nukeEnv = ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1") : envVars

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["nuke", "--receipt", takeDirectory tmpDir </> "nuke-receipt.json"])
              { cwd = Just tmpDir
              , env = Just nukeEnv
              }
            "destroy please\n"

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "confirmation rejected; nothing destroyed"
        -- Nothing was destroyed: the orchestration never shelled out to pulumi.
        pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRan `shouldBe` False

    it
      "Vault status and initialization use the caller-bound Bootstrap Broker state"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        writeFile (tmpDir </> "test-secrets.dhall") testSecretsDhall
        withFakeVaultLifecycleServer $ \vaultPort _stateRef -> do
          baseEnvVars <- fakeVaultLifecycleEnvironment vaultPort
          let runVault args =
                runInstalledWithFakeAuthorityEnvironment
                  tmpDir
                  binary
                  ("vault" : args)
                  baseEnvVars

          (initialStatusExit, initialStatusStdout, initialStatusStderr) <- runVault ["status"]
          initialStatusExit `shouldBe` ExitSuccess
          initialStatusStderr `shouldBe` ""
          initialStatusStdout
            `shouldContain` "Vault status: {\"initialization_ambiguous\":false,\"initialized\":true,\"sealed\":false,\"storage_generation\":\"1\"}"

          (initExit, initStdout, initStderr) <- runVault ["init"]
          initExit `shouldBe` ExitSuccess
          initStderr `shouldBe` ""
          initStdout `shouldContain` "Vault already initialized."

    it "Sprint 1.37: aws stack reconcile refuses before Pulumi when Vault is sealed" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
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

    it "Sprint 4.77: aws stack destroy without --yes refuses, and --yes is not inert" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnv <- fakeRke2Environment tmpDir
        -- Before Sprint 4.77 `--yes` was parsed, renamed `summary`, and then
        -- wildcarded at three of four sinks, so omitting it was byte-identical
        -- to passing it: the flag read as a confirmation and was not one. The
        -- command is intentionally non-interactive (CLAUDE.md), so the fix is
        -- to make the flag load-bearing rather than to add a prompt.
        (unconfirmedExit, unconfirmedStdout, unconfirmedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy"]) {cwd = Just tmpDir, env = Just baseEnv}
            ""
        unconfirmedExit `shouldBe` ExitFailure 1
        unconfirmedStdout `shouldBe` ""
        unconfirmedStderr `shouldContain` "Refusing to destroy without confirmation"
        unconfirmedStderr `shouldContain` "--yes"
        -- No Pulumi work may have started on the refusal path.
        pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRan `shouldBe` False

        -- `--dry-run` still renders a plan without `--yes`: the gate lives
        -- inside the apply closure, not around the plan.
        (dryRunExit, dryRunStdout, _) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy", "--dry-run"])
              { cwd = Just tmpDir
              , env = Just baseEnv
              }
            ""
        dryRunExit `shouldBe` ExitSuccess
        dryRunStdout `shouldContain` "COMMAND=eks-destroy"
        dryRunStdout `shouldContain` "CONFIRMED=false"

        -- And passing `--yes` is observably different: it reaches the Vault
        -- gate that the refusal never got to.
        (confirmedExit, _, confirmedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy", "--yes"])
              { cwd = Just tmpDir
              , env = Just baseEnv
              }
            ""
        confirmedStderr `shouldNotContain` "Refusing to destroy without confirmation"
        confirmedExit `shouldNotBe` ExitSuccess

    it "cluster federation register refuses the removed reusable-token bootstrap surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        withFakeVaultLifecycleServer $ \vaultPort stateRef -> do
          modifyMVar stateRef $ \_ -> pure (FakeVaultLifecycleState True False 3, ())
          writeTier0Fixture
            tmpDir
            ( tier0FixtureWithContext
                (\ctx -> ctx {Tier0.vault_address = Text.pack (fakeVaultAddress vaultPort)})
                validConfig
            )
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

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "requires the Bootstrap Broker's receipt-bound child-custody workflow"
          stderrText
            `shouldContain` "reusable parent root-token and direct Vault write transport has been removed"

    it
      "nuke refuses before admin/effects when the complete production decommission registry is unavailable"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir ->
        withFakeVaultServer $ \vaultPort ->
          withFakeGatewayDaemonServer
            []
            $ \gatewayPort requestsRef -> do
              binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
              repoRoot <- getCurrentDirectory
              writeRepoMarkers tmpDir
              writeFile
                (tmpDir </> "test-secrets.dhall")
                (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
              writeTier0Fixture
                tmpDir
                ( tier0FixtureWithContext
                    (\ctx -> ctx {Tier0.vault_address = Text.pack (fakeVaultAddress vaultPort)})
                    validConfigForNuke
                )
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
                      : ("PRODBOX_TEST_GATEWAY_NODEPORT", show gatewayPort)
                      : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                      : envVars

              (exitCode, stdoutText, stderrText) <-
                readCreateProcessWithExitCode
                  (proc binary ["nuke", "--receipt", takeDirectory tmpDir </> "nuke-receipt.json"])
                    { cwd = Just tmpDir
                    , env = Just nukeEnv
                    }
                  "NUKE EVERYTHING\n"

              exitCode `shouldBe` ExitFailure 1
              stdoutText `shouldNotContain` "step 1/5"
              stderrText `shouldContain` "decommission preparation refused"
              stderrText `shouldContain` "caller-bound Lifecycle Authority Transit signer"
              requests <- readMVar requestsRef
              requests
                `shouldSatisfy` all (not . ("POST /v1/object-store/pulumi/" `isInfixOf`))

    it "projects ZeroSSL external account binding into the supported ClusterIssuer reconcile" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters zeroSslConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir

        -- The refactor moved the ZeroSSL ACME ClusterIssuer (and the Route 53
        -- DNS bootstrap) behind `--with-edge`; bare `cluster reconcile` stands
        -- up a local-only cluster with no public edge. The EAB projection this
        -- test asserts therefore lives on the `--with-edge` path.
        (upExitCode, upStdout, upStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile", "--with-edge"]
            envVars

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

        issuerManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "\"ClusterIssuer\""
        issuerManifest `shouldContain` "\"ClusterIssuer\""
        issuerManifest `shouldNotContain` "\"externalAccountBinding\""
        materializerManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "acme-eab-secret-materializer"
        materializerManifest `shouldContain` "\"Job\""
        materializerManifest `shouldContain` "\"name\":\"acme-eab-secret-materializer\""
        materializerManifest `shouldContain` "\"namespace\":\"cert-manager\""
        -- The EAB fields are projected inside the Vault-login materializer and
        -- patched into the issuer; neither value is rendered by the host.
        -- materializer + its RBAC are present; the HMAC value never appears.
        materializerManifest `shouldContain` "vault-materialized"
        materializerManifest `shouldContain` "hmac_key"
        materializerManifest `shouldNotContain` "test-eab-hmac-key"
        materializerManifest `shouldNotContain` "\"stringData\":{\"secret\":"

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

    it "requires an explicit mounted config for native Bootstrap Broker start" $ do
      binary <- resolveBinaryPath

      (exitCode, _, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["bootstrap-broker", "start"])
          ""

      exitCode `shouldBe` ExitFailure 1
      stderrText `shouldContain` "--config PATH"

    it "runs native Bootstrap Broker start without requiring repo markers" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "nonexistent-bootstrap-broker.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            ( proc
                binary
                [ "bootstrap-broker"
                , "start"
                , "--config"
                , configPath
                ]
            )
              { cwd = Just tmpDir
              }
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "bootstrap-broker Dhall config"
        stderrText `shouldNotContain` "Could not locate the repository root"

    it "validates and renders the mounted Bootstrap Broker config in dry-run mode" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "bootstrap-broker.dhall"
            planPath = tmpDir </> "bootstrap-broker.plan"
        writeFile configPath bootstrapBrokerConfig

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            ( proc
                binary
                [ "bootstrap-broker"
                , "start"
                , "--config"
                , configPath
                , "--dry-run"
                , "--plan-file"
                , planPath
                ]
            )
              { cwd = Just tmpDir
              }
            ""

        when
          (exitCode /= ExitSuccess)
          ( expectationFailure
              ("broker dry-run stdout:\n" ++ stdoutText ++ "\nbroker dry-run stderr:\n" ++ stderrText)
          )
        persistedPlan <- readFile planPath
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldBe` persistedPlan
        stdoutText `shouldContain` "BOOTSTRAP_BROKER_START_PLAN"
        stdoutText `shouldContain` "RUNTIME_ROLE=bootstrap-broker"
        stdoutText `shouldContain` "LISTENER=127.0.0.1:18443"
        stdoutText `shouldContain` "AUTHENTICATOR=kubernetes-tokenreview"
        stdoutText `shouldContain` "MUTATION_ENGINE=production"
        stdoutText `shouldNotContain` "password"
        stdoutText `shouldNotContain` "root_token"

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
          runInstalledWithFakeAuthorityEnvironmentInput
            tmpDir
            binary
            ["config", "setup"]
            envVars
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
        stdoutText `shouldContain` "TIER0_ONLY=true"
        stdoutText `shouldNotContain` "AWS_ACCESS_KEY_ID="
        configText <- readFile (tmpDir </> "prodbox.dhall")
        -- Sprint 1.42 Part B: `config setup` now authors the operator config into
        -- prodbox.dhall's `parameters` block, rendered canonically by Dhall.inject
        -- (no `Config.SecretRef.Vault` schema-qualified syntax). The sensitive
        -- AWS access key is a Vault pointer (mount/path/field), never plaintext.
        configText `shouldContain` ">.Vault"
        configText `shouldContain` "path = \"aws/lifecycle-provider\""
        configText `shouldContain` "field = \"access_key_id\""
        configText `shouldNotContain` "AKIAFAKESETUP"
        configText `shouldContain` "zone_id = \"Z1234567890ABC\""
        configText `shouldContain` "demo_fqdn = \"test.resolvefintech.com\""
        configText `shouldContain` ".AdvertiseLayer2"
        configText `shouldNotContain` "public_edge_advertisement_mode = Some \"l2\""
        decodedConfig <- Settings.loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        case decodedConfig of
          Left err -> expectationFailure ("generated prodbox.dhall did not decode: " <> err)
          Right config ->
            Settings.public_edge_advertisement_mode (Settings.deployment config)
              `shouldBe` Just Settings.AdvertiseLayer2
        -- EAB references are non-secret schema coordinates only. Config setup
        -- neither prompts for nor writes either EAB field.
        configText `shouldContain` "eab_hmac_key = Some"
        configText `shouldContain` "field = \"hmac_key\""
        setupVaultAccessKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> lifecycleProviderVaultPath </> "access_key_id")
        setupVaultAccessKeyExists `shouldBe` False
        setupVaultEabKeyIdExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "key_id")
        setupVaultEabKeyIdExists `shouldBe` False
        setupVaultEabHmacKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "hmac_key")
        setupVaultEabHmacKeyExists `shouldBe` False
        jsonExists <- doesFileExist (tmpDir </> "prodbox-config.json")
        jsonExists `shouldBe` False

    it "refuses aws setup when the authenticated Credential Provisioner is unavailable" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
        envVars <- fakeAwsEnvironment tmpDir

        let setupInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]
        (setupExitCode, setupStdout, setupStderr) <-
          runInstalledWithFakeAuthorityEnvironmentInput
            tmpDir
            binary
            ["aws", "setup", "--tier", "full"]
            envVars
            setupInput

        setupExitCode `shouldBe` ExitFailure 1
        setupStdout `shouldContain` "AWS setup creates or refreshes"
        setupStderr
          `shouldContain` "requires the executable authenticated Credential Provisioner"
        setupStderr `shouldContain` "refusing IAM mutation"
        createUserRecord <- doesFileExist (tmpDir </> "fake-aws-state" </> "iam_create_user_access_key_id")
        createUserRecord `shouldBe` False

    it
      "refuses native aws-iam credential teardown when the authenticated Credential Provisioner is unavailable"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
        writeFile
          (tmpDir </> "test-secrets.dhall")
          (testSecretsDhallWithAdmin "CONFIGADMINKEY" "config-admin-secret" "us-west-2" Nothing)
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          "us-west-2"
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["test", "integration", "aws-iam"]
            envVars

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldContain` "Phase 1/2: validating integration prerequisites"
        stdoutText `shouldNotContain` "Phase 2/2: running test suites"
        stderrText `shouldContain` "Managed AWS IAM harness setup failed"
        stderrText `shouldContain` "cannot observe the live state of operational-aws-config"

        configAfterHarness <- readFile (tmpDir </> "prodbox.dhall")
        configAfterHarness `shouldContain` "path = \"aws/lifecycle-provider\""
        configAfterHarness `shouldContain` "field = \"access_key_id\""
        configAfterHarness `shouldNotContain` "AKIALEAKED"
        configAfterHarness `shouldNotContain` "leaked-secret"
        vaultAccessKeyAfterHarness <-
          readFakeVaultField tmpDir "secret" lifecycleProviderVaultPath "access_key_id"
        vaultSecretKeyAfterHarness <-
          readFakeVaultField tmpDir "secret" lifecycleProviderVaultPath "secret_access_key"
        vaultAccessKeyAfterHarness `shouldBe` "AKIALEAKED"
        vaultSecretKeyAfterHarness `shouldBe` "leaked-secret"

        deletedUsers <- doesFileExist (tmpDir </> "fake-aws-state" </> "iam_deleted_users")
        deletedUsers `shouldBe` False
        deletedPolicies <- fmap lines (readFile (tmpDir </> "fake-aws-state" </> "iam_deleted_policies"))
        deletedPolicies `shouldBe` ["aws-eks-test-aws-lb-controller"]
        deletedRoles <- fmap lines (readFile (tmpDir </> "fake-aws-state" </> "iam_deleted_roles"))
        deletedRoles `shouldBe` ["aws-eks-test-aws-lb-controller", "aws-eks-test-ebs-csi-driver"]

    it
      "does not bypass external-material ingress while running the IAM-only harness"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
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
          lifecycleProviderVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          "us-west-2"
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, _stdoutText, _stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["test", "integration", "aws-iam"]
            envVars

        exitCode `shouldBe` ExitFailure 1

        -- An IAM-only run has no attested ingress Job and therefore must not
        -- project the fixture through a direct host/Vault fallback.
        eabKeyIdExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "key_id")
        eabHmacKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "hmac_key")
        eabKeyIdExists `shouldBe` False
        eabHmacKeyExists `shouldBe` False

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

-- | Isolated helper mode for the process-level diagnostic assertion in the
-- RKE2 integration case. A mutation is deliberately selected without carrying
-- any of its declared dependency admissions, so the production caller must
-- render the typed refusal to stderr before returning an exit code.
runRke2AdmissionRefusalFixture :: FilePath -> IO ExitCode
runRke2AdmissionRefusalFixture repoRoot = do
  validated <-
    Settings.validateAndLoadSettingsAtPath
      (repoRoot </> "prodbox.dhall")
      repoRoot
  case validated of
    Left err -> fixtureSetupFailure err
    Right settings ->
      case ComponentGraph.validateComponentGraph
        (Settings.components (Settings.validatedConfig settings)) of
        Left err -> fixtureSetupFailure (show err)
        Right dag ->
          fst
            <$> Rke2.runAnchoredReconcileSteps
              repoRoot
              settings
              dag
              (const (pure ExitSuccess))
              noAdmissions
              [Rke2.StepAuthorityBackupChartReady]
 where
  fixtureSetupFailure detail = do
    BS8.hPutStrLn IO.stderr (BS8.pack ("admission-refusal fixture setup failed: " ++ detail))
    pure (ExitFailure 2)

-- | Isolated helper mode for the runbook diagnostic assertion. The test owns
-- a silent failing fake at the canonical child-binary path; this function runs
-- the production wrapper unchanged so stdout/stderr remain process-observable.
runRunbookFailureFixture :: FilePath -> IO ExitCode
runRunbookFailureFixture repoRoot = do
  environment <- getEnvironment
  TestRunner.runRunbookCommand
    repoRoot
    environment
    ["cluster", "reconcile", "--with-edge"]

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
  "{\"node_id\":\"node-a\",\"gateway_owner\":\"node-a\",\"has_active_claim\":true,\"mesh_peers\":[\"node-b\"],\"semantic_member_count\":2,\"signed_replay_assertion_count\":5,\"retained_assertion_count\":7,\"retained_assertion_capacity\":20,\"last_public_ip_observed\":\"203.0.113.10\",\"last_dns_write_ip\":\"203.0.113.10\",\"last_dns_write_at_utc\":\"2026-04-06T10:00:00Z\",\"dns_write_gate\":{\"zone_id\":\"Z123\",\"fqdn\":\"test.resolvefintech.com\",\"ttl\":60},\"heartbeat_age_seconds\":{\"node-a\":0.0,\"node-b\":1.5}}"

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

withFakeGatewayDaemonServer
  :: [(String, Int, String)]
  -> (Int -> MVar [String] -> IO a)
  -> IO a
withFakeGatewayDaemonServer responses action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 8
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating a fake daemon port")
          requestsRef <- newMVar []
          void $ forkIO (fakeGatewayDaemonAcceptLoop sock responses requestsRef)
          action port requestsRef
      )

fakeGatewayDaemonAcceptLoop :: Socket -> [(String, Int, String)] -> MVar [String] -> IO ()
fakeGatewayDaemonAcceptLoop sock responses requestsRef = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      let requestText = BS8.unpack requestBytes
          firstLine = takeWhile (/= '\r') requestText
          path = requestPathFromFirstLine firstLine
          (status, body) =
            case find (\(candidate, _, _) -> candidate == path) responses of
              Just (_, responseStatus, responseBody) -> (responseStatus, responseBody)
              Nothing -> (404, "not found")
      modifyMVar requestsRef (\seen -> pure (seen ++ [firstLine], ()))
      _ <-
        try (sendAll client (BS8.pack (renderFakeGatewayResponse status body)))
          :: IO (Either SomeException ())
      close client
      fakeGatewayDaemonAcceptLoop sock responses requestsRef

requestPathFromFirstLine :: String -> String
requestPathFromFirstLine firstLine =
  case words firstLine of
    _method : path : _ -> path
    _ -> "/"

renderFakeGatewayResponse :: Int -> String -> String
renderFakeGatewayResponse status body =
  "HTTP/1.1 "
    ++ show status
    ++ " "
    ++ fakeGatewayReason status
    ++ "\r\n"
    ++ "Content-Type: "
    ++ (if status >= 200 && status < 300 then "application/json" else "text/plain")
    ++ "\r\n"
    ++ "Content-Length: "
    ++ show (length body)
    ++ "\r\n"
    ++ "Connection: close\r\n\r\n"
    ++ body

fakeGatewayReason :: Int -> String
fakeGatewayReason status =
  case status of
    200 -> "OK"
    404 -> "Not Found"
    503 -> "Service Unavailable"
    _ -> "OK"

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

waitForGatewayHealthyProcess :: Int -> ProcessHandle -> FilePath -> FilePath -> IO ()
waitForGatewayHealthyProcess port processHandle stdoutPath stderrPath = go (60 :: Int)
 where
  go 0 = failWithGatewayLogs "gateway daemon did not become healthy"
  go attempts = do
    exitStatus <- getProcessExitCode processHandle
    case exitStatus of
      Just code -> failWithGatewayLogs ("gateway daemon exited before readiness: " ++ show code)
      Nothing -> pure ()
    result <-
      httpGetText
        (defaultHttpConfig {httpRequestTimeoutMicros = 250000})
        ("http://127.0.0.1:" ++ show port ++ "/healthz")
    case result of
      Right "ok\n" -> pure ()
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

-- | Reserve a loopback TCP port with NO listener (bind an OS-assigned port, read
-- it, close). A client connect then gets "connection refused". Used to point the
-- gateway-daemon probe (@PRODBOX_TEST_GATEWAY_NODEPORT@) at a definitely-down
-- endpoint so the fake-Vault-lifecycle test deterministically takes the
-- direct-host Vault seam ('UseDirectHostVaultTestSeam') instead of a *real*
-- cluster gateway daemon that may be listening on the default NodePort when this
-- suite runs inside `prodbox test all` (which would resolve
-- 'VaultDaemonReachable' → 'UseDaemonVaultLifecycle' and query the real Vault).
reserveClosedLoopbackPort :: IO Int
reserveClosedLoopbackPort =
  bracket
    (socket AF_INET Stream defaultProtocol)
    close
    ( \sock -> do
        bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
        addr <- getSocketName sock
        case addr of
          SockAddrInet p _ -> pure (fromIntegral p)
          _ -> ioError (userError "expected IPv4 socket while reserving a closed loopback port")
    )

fakeVaultLifecycleEnvironment :: Int -> IO [(String, String)]
fakeVaultLifecycleEnvironment port = do
  currentEnvironment <- getEnvironment
  closedGatewayNodePort <- reserveClosedLoopbackPort
  pure
    ( ("PRODBOX_TEST_HOST_VAULT_ADDR", fakeVaultAddress port)
        : ("PRODBOX_TEST_GATEWAY_NODEPORT", show closedGatewayNodePort)
        : filter
          ( \(key, _) ->
              key /= "PRODBOX_TEST_HOST_VAULT_ADDR"
                && key /= "PRODBOX_TEST_HOST_VAULT_TOKEN"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV"
                && key /= "PRODBOX_TEST_GATEWAY_NODEPORT"
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

lifecycleProviderVaultPath :: String
lifecycleProviderVaultPath = "aws/lifecycle-provider"

-- | The legacy fixture path used only to prove that Tier-0/IAM-only commands
-- do not write ZeroSSL EAB material around the external-ingress protocol.
acmeEabVaultPath :: String
acmeEabVaultPath = "acme/eab"

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

-- | Sprint 8.10 built-frontend fixture.  Every supported arm is read-only and
-- records its argv with an unambiguous separator so the test can reject
-- mutation verbs as well as assert the exact semantic probes were reached.
fakeSesReadinessEnvironment :: FilePath -> String -> IO [(String, String)]
fakeSesReadinessEnvironment repoRoot mode = do
  let binDir = repoRoot </> "fake-ses-readiness-bin"
      scriptPath = binDir </> "aws"
  createDirectoryIfMissing True binDir
  writeExecutable scriptPath (fakeSesReadinessAwsScript repoRoot)
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = binDir ++ ":" ++ existingPath
      filtered =
        filter
          ( \(key, _) ->
              key /= "PATH"
                && key /= "PRODBOX_FAKE_SES_READINESS_MODE"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_FAKE_SES_READINESS_MODE", mode)
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : filtered
    )

fakeSesReadinessAwsScript :: FilePath -> String
fakeSesReadinessAwsScript repoRoot =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_file=" ++ show (repoRoot </> "fake-ses-readiness-aws.txt")
    , "mode=${PRODBOX_FAKE_SES_READINESS_MODE:?}"
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then printf '|' >> \"$record_file\"; fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_file\""
    , "done"
    , "printf '\\n' >> \"$record_file\""
    , "case \"$*\" in"
    , "  '--version')"
    , "    printf 'aws-cli/2.31.0 Python/3.13 Linux/fixture\\n'"
    , "    ;;"
    , "  'sts get-caller-identity --output json')"
    , "    printf '%s\\n' '{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox\",\"UserId\":\"AIDASESREADY\"}'"
    , "    ;;"
    , "  'route53 get-hosted-zone --id Z1234567890ABC --output json')"
    , "    printf '%s\\n' '{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"resolvefintech.com.\"}}'"
    , "    ;;"
    , "  'sesv2 get-email-identity --email-identity test.resolvefintech.com --output json')"
    , "    if [[ $mode == identity-failed ]]; then"
    , "      printf '%s\\n' '{\"IdentityType\":\"DOMAIN\",\"VerifiedForSendingStatus\":false,\"VerificationStatus\":\"SUCCESS\",\"DkimAttributes\":{\"SigningEnabled\":true,\"Status\":\"SUCCESS\"}}'"
    , "    else"
    , "      printf '%s\\n' '{\"IdentityType\":\"DOMAIN\",\"VerifiedForSendingStatus\":true,\"VerificationStatus\":\"SUCCESS\",\"DkimAttributes\":{\"SigningEnabled\":true,\"Status\":\"SUCCESS\"}}'"
    , "    fi"
    , "    ;;"
    , "  'route53 list-resource-record-sets --hosted-zone-id Z1234567890ABC --output json')"
    , "    printf '%s\\n' '{\"ResourceRecordSets\":[{\"Name\":\"inbox.test.resolvefintech.com.\",\"Type\":\"MX\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"10 inbound-smtp.us-east-1.amazonaws.com\"}]}]}'"
    , "    ;;"
    , "  'ses describe-active-receipt-rule-set --output json')"
    , "    printf '%s\\n' '{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":true,\"Recipients\":[\"inbox.test.resolvefintech.com\"],\"Actions\":[{\"S3Action\":{\"BucketName\":\"prodbox-test-ses-capture\",\"ObjectKeyPrefix\":\"inbound/\"}}]}]}'"
    , "    ;;"
    , "  's3api list-objects-v2 --bucket prodbox-test-ses-capture --prefix inbound/.prodbox-readiness-capability-probe --max-keys 1 --output json')"
    , "    printf '%s\\n' '{\"KeyCount\":1,\"Contents\":[{\"Key\":\"inbound/.prodbox-readiness-capability-probe\"}]}'"
    , "    ;;"
    , "  s3api\\ get-object\\ --bucket\\ prodbox-test-ses-capture\\ --key\\ inbound/.prodbox-readiness-capability-probe\\ *\\ --output\\ json)"
    , "    printf '%s\\n' '{\"ContentLength\":38,\"ContentType\":\"text/plain\"}'"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake SES-readiness aws command: %s\\n' \"$*\" >&2"
    , "    exit 2"
    , "    ;;"
    , "esac"
    ]

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
  integrationExecutable <- getExecutablePath
  let kubeconfigPath = repoRoot </> "fake-chart-kubeconfig"
  writeFile kubeconfigPath "apiVersion: v1\nkind: Config\n"
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
      , ("PRODBOX_TEST_INTEGRATION_EXECUTABLE", integrationExecutable)
      , ("PRODBOX_TEST_AUTHORITY_CONFIG_PATH", repoRoot </> "prodbox.dhall")
      , ("KUBECONFIG", kubeconfigPath)
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
    , "if [[ \"${1:-}\" == '--kubeconfig' ]]; then shift 2; fi"
    , "if [[ \"${1:-}\" == '--namespace' ]]; then shift 2; fi"
    , "case \"${1:-} ${2:-}\" in"
    , "  'create token')"
    , "    printf 'fixture-service-account-token'"
    , "    ;;"
    , "  'auth can-i')"
    , "    printf 'yes\n'"
    , "    ;;"
    , "  'get serviceaccount')"
    , "    printf 'gateway\n%s\nfalse\n' \"${3:-}\""
    , "    ;;"
    , "  'get service')"
    , "    if [[ \"${3:-}\" == 'kubernetes' ]]; then printf '10.43.0.1'; else exit 1; fi"
    , "    ;;"
    , "  'port-forward service/lifecycle-authority'|'port-forward service/authority-backup'|'port-forward service/target-secret-agent'|'port-forward service/tls-retention')"
    , "    mapping=${!#}"
    , "    local_port=${mapping%%:*}"
    , "    exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-authority-server \"$local_port\""
    , "    ;;"
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
    , "      # Sprint 4.43: the operator gate now reads the Available condition"
    , "      # (not -o name). A ready operator reports Available=True."
    , "      if [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
    , "        printf 'True'"
    , "      else"
    , "        printf 'deployment.apps/postgres-operator\\n'"
    , "      fi"
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
    , "        : > \"$record_dir/patroni-ready.count\""
    , "        printf '3\\n'"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): perconapgclusters \"%s\" not found\\n' \"${3:-perconapgclusters.pgv2.percona.com}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get endpoints')"
    , -- Sprint 3.34 made `endpoints/kubernetes` a live observation on the
      -- chart-reconcile path (the post-DNAT Kubernetes API egress
      -- coordinate). The fake boundary did not serve it, so every fixture
      -- reconcile failed with `endpoints \"kubernetes\" not found`. The
      -- address is RFC 5737 TEST-NET-1, unmistakably synthetic; the port is
      -- the real post-DNAT API port, which is the coordinate under test.
      "    if [[ \"${3:-}\" == 'kubernetes' && \"$*\" == *'jsonpath={.subsets[*].addresses[*].ip}'* ]]; then"
    , "      printf '192.0.2.10|6443'"
    , "    elif [[ \"${3:-}\" == 'prodbox-vscode-pg-ha' && \"$*\" == *'jsonpath={.subsets[0].addresses[0].targetRef.name}'* ]] && { [[ \"${PRODBOX_FAKE_PATRONI_LIVE_ANCHOR:-}\" == 'true' ]] || [[ -f \"$record_dir/patroni-ready.count\" ]]; }; then"
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
      kubeconfigPath = repoRoot </> "fake-rke2-kubeconfig"
  createDirectoryIfMissing True recordDir
  writeFile socketPath ""
  writeFile kubeconfigPath "server: https://127.0.0.1:6443\n"
  createDirectoryIfMissing True endpointStatusRoot
  writeFile (endpointStatusRoot </> "rke2-pod.status") ""
  currentEnvironment <- getEnvironment
  integrationExecutable <- getExecutablePath
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
                          , "PRODBOX_TEST_INTEGRATION_EXECUTABLE"
                          , "PRODBOX_TEST_AUTHORITY_CONFIG_PATH"
                          , "KUBECONFIG"
                          , "HOME"
                          ]
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_RKE2_RECORD_DIR", recordDir)
      , ("PRODBOX_RKE2_CONTAINERD_SOCKET", socketPath)
      , ("PRODBOX_RKE2_ENDPOINT_STATUS_ROOT", endpointStatusRoot)
      , ("KUBECONFIG", kubeconfigPath)
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
      , ("PRODBOX_TEST_INTEGRATION_EXECUTABLE", integrationExecutable)
      , ("PRODBOX_TEST_AUTHORITY_CONFIG_PATH", repoRoot </> "prodbox.dhall")
      ,
        ( "PRODBOX_TEST_HOST_CAPACITY"
        , "milli_cpu=8000,memory_mib=15872,ephemeral_storage_mib=100000,durable_storage_mib=180000"
        )
      , ("HOME", repoRoot)
      ]
        ++ baseEnvironment
    )

-- | Run a graph-consuming reconcile against loopback service fixtures. The
-- Gateway side exposes only its deep @/readyz@ projection; Vault status is
-- supplied by the separately authenticated Bootstrap Broker fixture.
runRke2ReconcileWithFakeGateway
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runRke2ReconcileWithFakeGateway repoRoot binary arguments environment =
  withFakeGatewayReadinessEnvironment environment $ \gatewayEnvironment ->
    readCreateProcessWithExitCode
      (proc binary arguments)
        { cwd = Just repoRoot
        , env = Just gatewayEnvironment
        }
      ""

runInstalledWithFakeAuthority
  :: FilePath
  -> FilePath
  -> [String]
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthority repoRoot binary arguments = do
  runInstalledWithFakeAuthorityEnvironment repoRoot binary arguments []

runInstalledWithFakeAuthorityEnvironment
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthorityEnvironment repoRoot binary arguments additionalEnvironment = do
  runInstalledWithFakeAuthorityEnvironmentInput repoRoot binary arguments additionalEnvironment ""

runInstalledWithFakeAuthorityEnvironmentInput
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> String
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthorityEnvironmentInput repoRoot binary arguments additionalEnvironment inputText = do
  fixtureEnvironment <- fakeRke2Environment repoRoot
  when
    ( lookup "PRODBOX_ALLOW_NON_TTY_INTERACTIVE" additionalEnvironment == Just "1"
        && lookup "PRODBOX_TEST_HOST_VAULT_KV_DIR" additionalEnvironment /= Nothing
    )
    (void (writeFakeAwsScript repoRoot))
  let mergedPath =
        case (lookup "PATH" additionalEnvironment, lookup "PATH" fixtureEnvironment) of
          (Just additionalPath, Just fixturePath)
            | lookup "PRODBOX_FAKE_SES_READINESS_MODE" additionalEnvironment /= Nothing ->
                takeWhile (/= ':') additionalPath ++ ":" ++ fixturePath
            | lookup "PRODBOX_ALLOW_NON_TTY_INTERACTIVE" additionalEnvironment == Just "1"
                && lookup "PRODBOX_TEST_HOST_VAULT_KV_DIR" additionalEnvironment /= Nothing ->
                takeWhile (/= ':') additionalPath ++ ":" ++ fixturePath
            | otherwise -> fixturePath
          (Just additionalPath, Nothing) -> additionalPath
          (Nothing, Just fixturePath) -> fixturePath
          (Nothing, Nothing) -> ""
  withVaultFixtureServer $ \vaultPort ->
    readCreateProcessWithExitCode
      (proc binary arguments)
        { cwd = Just repoRoot
        , env =
            Just
              ( ("PATH", mergedPath)
                  : ("PRODBOX_TEST_HOST_VAULT_ADDR", "http://127.0.0.1:" ++ show vaultPort)
                  : filter (not . reservedKey . fst) additionalEnvironment
                  ++ filter (not . reservedKey . fst) fixtureEnvironment
              )
        }
      inputText
 where
  reservedKey key = key `elem` ["PATH", "PRODBOX_TEST_HOST_VAULT_ADDR"]

runInstalledWithAuthorityEnvironment
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runInstalledWithAuthorityEnvironment repoRoot binary arguments environment =
  withVaultFixtureServer $ \vaultPort ->
    readCreateProcessWithExitCode
      (proc binary arguments)
        { cwd = Just repoRoot
        , env =
            Just
              ( ("PRODBOX_TEST_HOST_VAULT_ADDR", "http://127.0.0.1:" ++ show vaultPort)
                  : filter ((/= "PRODBOX_TEST_HOST_VAULT_ADDR") . fst) environment
              )
        }
      ""

withFakeGatewayReadinessEnvironment
  :: [(String, String)] -> ([(String, String)] -> IO value) -> IO value
withFakeGatewayReadinessEnvironment environment action = do
  -- Sprint 5.31: the receipt must be recent. `readinessFreshnessWindow` is 300s
  -- and the run is well inside it, so one stamp taken at fixture setup is
  -- honest evidence of a live daemon rather than a window the fixture widens.
  nowMicros <- roundTripLandedAtMicros
  withFakeGatewayDaemonServer (readinessResponses nowMicros) $ \gatewayPort _requestsRef ->
    withVaultFixtureServer $ \vaultPort ->
      action
        ( ("PRODBOX_TEST_GATEWAY_NODEPORT", show gatewayPort)
            : ("PRODBOX_TEST_HOST_VAULT_ADDR", "http://127.0.0.1:" ++ show vaultPort)
            : filter (not . overridden . fst) environment
        )
 where
  overridden key = key `elem` ["PRODBOX_TEST_GATEWAY_NODEPORT", "PRODBOX_TEST_HOST_VAULT_ADDR"]
  readinessResponses nowMicros =
    [
      ( "/v1/bootstrap/vault/status"
      , 200
      , "{\"initialized\":true,\"sealed\":false,\"t\":3,\"n\":5,\"progress\":0}"
      )
    , ("/readyz", 200, "ready\n")
    , -- Sprint 5.31: `/v1/state` carries the round-trip receipt the deep probe
      -- reads. Sprint `1.76` stopped treating a constant-time `/readyz` GET as
      -- proof of a backend write and moved the evidence here; this fixture was
      -- never given the new route, so `ProbeBackendRoundTrip ComponentMinio`
      -- observed a 404 and the component could never be admitted. Another
      -- fixture that stopped matching a contract that tightened.

      ( "/v1/state"
      , 200
      , "{\"last_backend_round_trip\":{\"object_version\":\""
          ++ fixtureRoundTripObjectVersion
          ++ "\",\"landed_at_micros\":"
          ++ show nowMicros
          ++ "}}"
      )
    ]

-- | An opaque object-store version string for the fixture's round-trip receipt.
-- It has to satisfy `mkModelBObjectVersion`, so it is a value the production
-- smart constructor accepts rather than arbitrary text.
fixtureRoundTripObjectVersion :: String
fixtureRoundTripObjectVersion = "fixture-round-trip-version"

roundTripLandedAtMicros :: IO Integer
roundTripLandedAtMicros = do
  posix <- getPOSIXTime
  pure (max 0 (floor (nominalDiffTimeToSeconds posix * 1000000)))

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
    , "  show)"
    , "    if [[ \"$*\" == *'LoadState'* ]]; then"
    , "      printf 'loaded\\n'"
    , "    elif [[ \"$*\" == *'ActiveState'* ]]; then"
    , "      printf 'active\\n'"
    , "    else"
    , "      printf 'loaded\\n'"
    , "    fi"
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
    , "if [[ \"$*\" == *'/blobs/uploads/'* ]]; then"
    , "  # Sprint 4.43 deep registry->MinIO gate: a POST blob-upload session"
    , "  # succeeds (202), modelling a registry that reached its MinIO S3 backend."
    , "  #"
    , "  # Sprint 5.30: Sprint `1.76` made that 202 insufficient on its own — the"
    , "  # probe dumps headers with `-D -` and requires the registry to NAME the"
    , "  # session it allocated, because the identifier is the receipt of the"
    , "  # backend write. A 2xx naming no session is not a round trip. This fake"
    , "  # emitted only the status, so it modelled a registry that cannot have"
    , "  # written; the drift was invisible while the suite could not get here."
    , "  printf 'HTTP/1.1 202 Accepted\\r\\n'"
    , "  printf 'Docker-Upload-UUID: 00000000-0000-4000-8000-00000000fake\\r\\n'"
    , "  printf '\\r\\n'"
    , "  printf '202'"
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
    , "next_gateway_pods_sample() {"
    , "  local counter_file=\"$record_dir/gateway-pods-sample.count\""
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s' \"$count\""
    , "}"
    , "append_args \"$record_dir/kubectl.txt\" \"$@\""
    , "if [[ \"${1:-}\" == '--kubeconfig' ]]; then"
    , "  shift 2"
    , "fi"
    , "if [[ \"${1:-}\" == '--namespace' ]]; then"
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
    , "  auth)"
    , "    if [[ \"${2:-}\" == 'can-i' ]]; then"
    , "      printf 'yes\\n'"
    , "    else"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  get)"
    , "    case \"${2:-}\" in"
    , "      serviceaccount)"
    , "        printf 'gateway\\n%s\\nfalse\\n' \"${3:-}\""
    , "        ;;"
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
    , renderFakeResourceQuotaItems
    , "JSON"
    , "        fi"
    , "        ;;"
    , "      limitrange)"
    , "        if [[ \"$*\" == *'-o json'* ]]; then"
    , "          /bin/cat <<'JSON'"
    , renderFakeLimitRangeItems
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
    , "      secret|secret/*)"
    , "        if [[ \"$*\" == *'secret/minio-oidc-client'* && \"$*\" == *'metadata.resourceVersion'* ]]; then"
    , "          printf 'fixture-resource-version-1'"
    , "        elif [[ \"$*\" == *'secret/'* && \"$*\" == *'metadata.uid'* ]]; then"
    , "          printf 'fixture-secret-uid:fixture-resource-version-1'"
    , "        elif [[ \"${3:-}\" == 'minio' && \"$*\" == *'rootUser'* ]]; then"
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
    , -- Sprint 3.34 made `endpoints/kubernetes` a live observation on the
      -- reconcile path (the post-DNAT Kubernetes API egress coordinate).
      -- This inner case's `*)` arm answers an unknown resource with empty
      -- stdout and exit 0, so before this arm existed the observer read
      -- "" and refused with "observation was not in the expected form".
      -- The address is RFC 5737 TEST-NET-1, unmistakably synthetic; the
      -- port is the real post-DNAT API port, which is the coordinate the
      -- chart rule under test is derived from.
      "      endpoints)"
    , "        if [[ \"${3:-}\" == 'kubernetes' ]]; then"
    , "          printf '192.0.2.10|6443'"
    , "        else"
    , "          printf 'Error from server (NotFound): endpoints \"%s\" not found\\n' \"${3:-endpoints}\" >&2"
    , "          exit 1"
    , "        fi"
    , "        ;;"
    , "      deployment)"
    , "        if [[ \"$*\" == *'jsonpath={.metadata.generation}'* ]]; then"
    , "          printf '1:1:1:1'"
    , "        elif [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
    , "          printf 'True'"
    , "        fi"
    , "        ;;"
    , "      statefulset)"
    , "        if [[ \"$*\" == *'jsonpath={.spec.replicas}'* ]]; then"
    , "          printf '1:1:1'"
    , "        fi"
    , "        ;;"
    , "      daemonset)"
    , "        if [[ \"$*\" == *'jsonpath={.status.desiredNumberScheduled}'* ]]; then"
    , "          printf '1:1:1'"
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
    , "        if [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
    , "          printf 'True'"
    , "        else"
    , "          printf 'customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io\\n'"
    , "        fi"
    , "        ;;"
    , "      pods)"
    , "        if [[ \"$*\" == *'--selector=job-name='* && \"$*\" == *'--output=name'* ]]; then"
    , "          exit 0"
    , "        elif [[ \"$*\" == *'-o json'* ]]; then"
    , "          if [[ \"$*\" == *'--namespace gateway'* ]]; then"
    , "            gateway_pods_sample=$(next_gateway_pods_sample)"
    , "            if [[ \"${PRODBOX_FAKE_GATEWAY_OOM_PODS_SAMPLE:-0}\" == \"$gateway_pods_sample\" ]]; then"
    , "              /bin/cat <<'JSON'"
    , renderFakeGatewayPodItems True
    , "JSON"
    , "            else"
    , "              /bin/cat <<'JSON'"
    , renderFakeGatewayPodItems False
    , "JSON"
    , "            fi"
    , "          else"
    , "            /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"namespace\":\"keycloak\",\"name\":\"keycloak-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"keycloak\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"2048Mi\"}}}]}},{\"metadata\":{\"namespace\":\"vscode\",\"name\":\"vscode-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"vscode\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"4096Mi\"}}}]}},{\"metadata\":{\"namespace\":\"api\",\"name\":\"api-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"api\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"websocket\",\"name\":\"websocket-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"websocket\",\"resources\":{\"requests\":{\"cpu\":\"100m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"gateway-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"gateway\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}}]}"
    , "JSON"
    , "          fi"
    , "        else"
    , "          printf 'docker.io/library/busybox:latest\\ngoharbor/harbor-core:v2\\n'"
    , "        fi"
    , "        ;;"
    , "      events)"
    , "        printf '{\"items\":[]}'"
    , "        ;;"
    , "      --raw)"
    , "        /bin/cat <<'JSON'"
    , renderFakeGatewayMetricItems
    , "JSON"
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
    , "  logs)"
    , "    printf 'gateway fake workload logs are diagnostic-only\n'"
    , "    ;;"
    , "  port-forward)"
    , "    if [[ \"$*\" == *'service/bootstrap-broker'* ]]; then"
    , "      mapping=${!#}"
    , "      local_port=${mapping%%:*}"
    , "      exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-broker-server \"$local_port\""
    , "    elif [[ \"$*\" == *'service/lifecycle-authority'* || \"$*\" == *'service/authority-backup'* ]]; then"
    , "      mapping=${!#}"
    , "      local_port=${mapping%%:*}"
    , "      exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-authority-server \"$local_port\""
    , "    else"
    , "      trap 'exit 0' TERM INT"
    , "      while true; do"
    , "        sleep 1"
    , "      done"
    , "    fi"
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
    , "      token)"
    , "        printf 'fixture-service-account-token\\n'"
    , "        ;;"
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
    , "  status)"
    , "    if [[ \"${2:-}\" == 'harbor' && ! -f \"$record_dir/harbor-uninstalled\" ]]; then"
    , -- Sprint 5.30: Sprint `3.31` made `helm status --output json` decode
      -- `.info.status` into a closed constructor set and fail closed on an
      -- unrecognised shape. This fake omitted `.info` entirely, so it decoded
      -- before that sprint and refuses after it — the same second-encoder drift
      -- as the Tier-0 fixtures, one artifact over. It never surfaced because the
      -- test could not get this far.
      "      printf '{\"name\":\"harbor\",\"namespace\":\"harbor\",\"info\":{\"status\":\"deployed\"}}\\n'"
    , "    elif [[ \"${2:-}\" == 'harbor' ]]; then"
    , "      printf 'Error: release: not found\\n' >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  uninstall)"
    , "    if [[ \"${2:-}\" == 'harbor' ]]; then"
    , "      : > \"$record_dir/harbor-uninstalled\""
    , "    fi"
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
    , "  image)"
    , "    if [[ \"${2:-}\" == 'inspect' ]]; then"
    , "      printf 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n'"
    , "      exit 0"
    , "    fi"
    , "    exit 1"
    , "    ;;"
    , "  buildx)"
    , "    if [[ \"${2:-}\" == 'imagetools' && \"${3:-}\" == 'inspect' && \"${4:-}\" == '--raw' ]]; then"
    , "      printf '{\"config\":{\"digest\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}}\\n'"
    , "      exit 0"
    , "    fi"
    , "    exit 1"
    , "    ;;"
    , -- Sprint 3.36: the fake parses flags rather than positions. Production
      -- now publishes host-architecture-scoped (`docker pull --platform \<p\>
      -- \<ref\>`), and a fixture that reads the image reference from `$2`
      -- silently reads `--platform` instead. The `save` arm below already
      -- parsed this way; `pull` and `push` did not, which is why a correct
      -- production change presented as `manifest unknown` in six cases.
      "  pull)"
    , "    shift"
    , "    while [[ \"${1:-}\" == --* ]]; do"
    , "      if [[ \"$1\" == '--platform' ]]; then shift 2; else shift; fi"
    , "    done"
    , "    ref=${1:-}"
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
    , "    shift"
    , "    while [[ \"${1:-}\" == --* ]]; do"
    , "      if [[ \"$1\" == '--platform' ]]; then shift 2; else shift; fi"
    , "    done"
    , "    target_ref=${1:-}"
    , "    tag_file=\"$record_dir/tag-$(target_key \"$target_ref\")\""
    , "    source_ref=''"
    , "    if [[ -f \"$tag_file\" ]]; then"
    , "      source_ref=$(/bin/cat \"$tag_file\")"
    , "    fi"
    , -- Sprint 5.30: the upstream code-server image is published from a
      -- rate-limited registry, and `pushDockerImageWithRetry` classifies its 429
      -- as RETRYABLE. Model it the way production treats it — transient: one 429,
      -- then success. A fake that returns 429 forever models a permanent limit,
      -- which refutes the very retry the two tests asserting "Retrying Harbor
      -- publication …" plus `ExitSuccess` exist to exercise, and takes down every
      -- other case that merely passes through the runbook on its way elsewhere.
      "    if [[ \"$source_ref\" == ghcr.io/coder/code-server:4.98.2 ]]; then"
    , "      attempt_file=\"$record_dir/push-attempts-$(target_key \"$target_ref\")\""
    , "      attempts=0"
    , "      if [[ -f \"$attempt_file\" ]]; then"
    , "        attempts=$(/bin/cat \"$attempt_file\")"
    , "      fi"
    , "      attempts=$((attempts + 1))"
    , "      printf '%s' \"$attempts\" > \"$attempt_file\""
    , "      if [[ \"$attempts\" -le 1 ]]; then"
    , "        echo '429 Too Many Requests' >&2"
    , "        exit 1"
    , "      fi"
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
    , "  # Sprint 8.8: prodbox nuke step 3 (operational IAM teardown) — the"
    , "  # SES lease role and operational `prodbox` user are absent in this"
    , "  # fixture, so the teardown is a no-op after observing both states."
    , "  *'sts get-caller-identity'*)"
    , "    printf '{\"Account\":\"123456789012\",\"UserId\":\"AIDAFAKEADMIN\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox-admin-temp\"}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'iam get-role'*)"
    , "    printf 'An error occurred (NoSuchEntity) when calling the GetRole operation: The role with name prodbox-aws-ses-lease cannot be found.\\n' >&2"
    , "    exit 254"
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
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "export PATH=/usr/bin:/bin"
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
    , "policy_file() {"
    , "  printf '%s/policy-%s-exists' \"$STATE_DIR\" \"$1\""
    , "}"
    , "role_file() {"
    , "  printf '%s/role-%s-exists' \"$STATE_DIR\" \"$1\""
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
    , "{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"resolvefintech.com\"},\"DelegationSet\":{\"NameServers\":[\"ns-1.example.com\"]}}"
    , "JSON"
    , "    else"
    , "      aws_error 'InvalidClientTokenId' 'GetHostedZone' 'The security token included in the request is invalid.'"
    , "    fi"
    , "    ;;"
    , "  \"iam list-entities-for-policy\")"
    , "    policy_arn=${4:-}"
    , "    policy_name=${policy_arn##*/}"
    , "    if [[ ! -f \"$(policy_file \"$policy_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'ListEntitiesForPolicy' \"Policy $policy_arn was not found.\""
    , "    fi"
    , "    if [[ -f \"$(role_file 'aws-eks-test-aws-lb-controller')\" ]]; then"
    , "      cat <<'JSON'"
    , "{\"PolicyRoles\":[{\"RoleName\":\"aws-eks-test-aws-lb-controller\"}],\"PolicyUsers\":[],\"PolicyGroups\":[]}"
    , "JSON"
    , "    else"
    , "      cat <<'JSON'"
    , "{\"PolicyRoles\":[],\"PolicyUsers\":[],\"PolicyGroups\":[]}"
    , "JSON"
    , "    fi"
    , "    ;;"
    , "  \"iam detach-role-policy\")"
    , "    role_name=${4:-}"
    , "    policy_arn=${6:-}"
    , "    append_line \"$STATE_DIR/iam_detached_role_policies\" \"$role_name:$policy_arn\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam delete-policy\")"
    , "    policy_arn=${4:-}"
    , "    policy_name=${policy_arn##*/}"
    , "    if [[ ! -f \"$(policy_file \"$policy_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'DeletePolicy' \"Policy $policy_arn was not found.\""
    , "    fi"
    , "    rm -f \"$(policy_file \"$policy_name\")\""
    , "    append_line \"$STATE_DIR/iam_deleted_policies\" \"$policy_name\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam get-role\")"
    , "    role_name=${4:-}"
    , "    if [[ ! -f \"$(role_file \"$role_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'GetRole' \"The role with name $role_name cannot be found.\""
    , "    fi"
    , "    printf '{\"Role\":{\"RoleName\":\"%s\",\"Arn\":\"arn:aws:iam::123456789012:role/%s\"}}\\n' \"$role_name\" \"$role_name\""
    , "    ;;"
    , "  \"iam list-attached-role-policies\")"
    , "    role_name=${4:-}"
    , "    if [[ ! -f \"$(role_file \"$role_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'ListAttachedRolePolicies' \"The role with name $role_name cannot be found.\""
    , "    fi"
    , "    cat <<'JSON'"
    , "{\"AttachedPolicies\":[]}"
    , "JSON"
    , "    ;;"
    , "  \"iam list-role-policies\")"
    , "    role_name=${4:-}"
    , "    if [[ ! -f \"$(role_file \"$role_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'ListRolePolicies' \"The role with name $role_name cannot be found.\""
    , "    fi"
    , "    cat <<'JSON'"
    , "{\"PolicyNames\":[]}"
    , "JSON"
    , "    ;;"
    , "  \"iam delete-role-policy\")"
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam delete-role\")"
    , "    role_name=${4:-}"
    , "    if [[ ! -f \"$(role_file \"$role_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'DeleteRole' \"The role with name $role_name cannot be found.\""
    , "    fi"
    , "    rm -f \"$(role_file \"$role_name\")\""
    , "    append_line \"$STATE_DIR/iam_deleted_roles\" \"$role_name\""
    , "    printf '{}\\n'"
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
  writeFile (stateDir </> "policy-aws-eks-test-aws-lb-controller-exists") ""
  writeFile (stateDir </> "role-aws-eks-test-aws-lb-controller-exists") ""
  writeFile (stateDir </> "role-aws-eks-test-ebs-csi-driver-exists") ""

harborRegistryStorageSecretName :: String
harborRegistryStorageSecretName = "harbor-registry-s3"

harborRegistryStorageBucket :: String
harborRegistryStorageBucket = "prodbox-harbor-registry"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

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

countRecordLines :: String -> String -> Int
countRecordLines expected = length . filter (== expected) . lines

bootstrapBrokerConfig :: String
bootstrapBrokerConfig =
  unlines
    [ "{ schemaVersion = 2"
    , ", cluster_id = \"cluster-a\""
    , ", vault_address = \"http://127.0.0.1:8200\""
    , ", service_identity = \"gateway-service\""
    , ", listener = { listen_host = \"127.0.0.1\", listen_port = 18443 }"
    , ", bootstrap_store ="
    , "    { store_endpoint = \"http://127.0.0.1:9000\""
    , "    , store_bucket = \"bootstrap-state\""
    , "    , vault_storage_generation_key = \"vault-storage-generation\""
    , "    , bootstrap_session_fence_key = \"bootstrap-session-fence\""
    , "    , prepared_init_envelope_key = \"prepared-init-envelope\""
    , "    , encrypted_init_response_key = \"encrypted-init-response\""
    , "    , final_unlock_bundle_key = \"final-unlock-bundle\""
    , "    , child_custody_receipt_key = \"child-custody-receipt\""
    , "    , child_recovery_delivery_key = \"child-recovery-delivery\""
    , "    , root_init_journal_key = \"root-init-journal\""
    , "    , root_session_journal_key = \"root-session-journal\""
    , "    , child_custody_journal_key = \"child-custody-journal\""
    , "    , child_recovery_journal_key = \"child-recovery-journal\""
    , "    , post_unseal_handoff_key = \"post-unseal-handoff\""
    , "    , secret_worker_checkpoint_key = \"secret-worker-checkpoint\""
    , "    }"
    , ", limits ="
    , "    { queue_capacity = 8"
    , "    , max_request_body_bytes = 4096"
    , "    , request_deadline_milliseconds = 30000"
    , "    , drain_deadline_milliseconds = 5000"
    , "    }"
    , ", parent_registration = None { parent_cluster_id : Text, parent_authority_endpoint : Text }"
    , "}"
    ]

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
    , "  , lifecycle_authority = None { authority_scope : Text, endpoint : Text }"
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
    , "  , lifecycle_authority = None { authority_scope : Text, endpoint : Text }"
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

-- | Sprint 7.16: the test-harness cleartext fixture (@test-secrets.dhall@).
-- Carries the unlock-bundle password plus the EPHEMERAL admin AWS credential
-- the harness feeds into the same interactive admin prompt a real operator
-- would answer. Decoded structurally by @inputFile auto@, so no schema import
-- is required. This base value leaves the admin block empty (the vault
-- lifecycle test only needs the password).
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
-- @acme_eab@ block for the separate external-material ingress fixture.
-- Placeholder EAB values only — never real ZeroSSL credentials.
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

testSecretsDhall :: String
testSecretsDhall = testSecretsDhallWithAdmin "" "" "" Nothing

-- | Sprint 5.30: the integration fixtures are 'Settings.ConfigFile' values now,
-- not hand-authored Dhall. They were one of four encoders of a record that has
-- exactly one decoder, and Sprint `1.80`'s type tightening made three of them
-- wrong rather than updating them
-- (chaos_hardening_doctrine.md section 23). Every field not named here is the
-- production default, which also retires a second, silent drift: the fixture
-- capacity plan had diverged from `defaultResourcePlan`.
validConfig :: Settings.ConfigFile
validConfig =
  configWithAwsAndAcme
    lifecycleProviderVaultPath
    "us-east-1"
    True
    "https://acme.zerossl.com/v2/DV90"

validConfigWithBlankOperationalAwsAndConfiguredAdmin :: Settings.ConfigFile
validConfigWithBlankOperationalAwsAndConfiguredAdmin =
  (fixtureBaseConfig lifecycleProviderVaultPath "us-east-1" False)
    { Settings.pulumi_state_backend = fixturePulumiBackend "prodbox-fixture-state" "us-east-1"
    }

validConfigForNuke :: Settings.ConfigFile
validConfigForNuke =
  (fixtureBaseConfig lifecycleProviderVaultPath "us-east-1" False)
    { -- Sprint 5.30: the AWS-tier validator Sprint `1.81` introduced requires a
      -- non-empty subzone, and the SES readiness command validates at that tier.
      -- The pre-migration fixture left it empty; the fixture never decoded, so
      -- no test could observe the refusal. Synthetic values, per the repository
      -- value-hygiene rule.
      Settings.aws_substrate = fixtureAwsSubstrate
    , Settings.ses =
        Settings.SesSection
          { Settings.sender_domain = Text.pack "test.resolvefintech.com"
          , -- Sprint 5.30: a single DNS label, not an FQDN. The pre-migration fixture
            -- carried "inbox.test.resolvefintech.com" here, which
            -- `validateOptionalDnsLabelField` rejects — but the fixture never decoded,
            -- so no test could observe it. Surfacing a latent invalid fixture value is
            -- the migration working, not migration damage.
            Settings.receive_subdomain = Text.pack "inbox"
          , Settings.capture_bucket = Text.pack "prodbox-test-ses-capture"
          }
    , Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-test-pulumi-long-lived" "us-west-2"
    }

validConfigWithLeakedOperationalAwsAndConfiguredAdmin :: Settings.ConfigFile
validConfigWithLeakedOperationalAwsAndConfiguredAdmin =
  (fixtureBaseConfig lifecycleProviderVaultPath "us-west-2" False)
    { -- This fixture drives the AWS-tier IAM harness. Keep its substrate
      -- coordinates valid so the named unavailable-Credential-Provisioner
      -- refusal is the first failure, rather than an unrelated config refusal.
      Settings.aws_substrate = fixtureAwsSubstrate
    , Settings.pulumi_state_backend = fixturePulumiBackend "" ""
    }

fixtureAwsSubstrate :: Settings.AwsSubstrateSection
fixtureAwsSubstrate =
  Settings.AwsSubstrateSection
    { Settings.hosted_zone_id = Text.pack "Z0987654321XYZ"
    , Settings.subzone_name = Text.pack "aws.test.resolvefintech.com"
    }

zeroSslConfig :: Settings.ConfigFile
zeroSslConfig = validConfig

configWithAwsAndAcme :: String -> String -> Bool -> String -> Settings.ConfigFile
configWithAwsAndAcme awsVaultPath regionValue includeSessionToken acmeServer =
  (fixtureBaseConfig awsVaultPath regionValue includeSessionToken)
    { Settings.acme = fixtureAcme {Settings.server = Text.pack acmeServer}
    , Settings.pulumi_state_backend = fixturePulumiBackend "prodbox-fixture-state" "us-east-1"
    }

-- | The shared fixture shape: production defaults plus the handful of fields
-- every integration fixture overrides.
fixtureBaseConfig :: String -> String -> Bool -> Settings.ConfigFile
fixtureBaseConfig awsVaultPath regionValue includeSessionToken =
  Settings.defaultConfigFile
    { Settings.aws = fixtureAwsCredentials awsVaultPath regionValue includeSessionToken
    , Settings.route53 = Settings.Route53Section {Settings.zone_id = Text.pack "Z1234567890ABC"}
    , Settings.domain =
        (Settings.domain Settings.defaultConfigFile)
          { Settings.demo_fqdn = Text.pack "test.resolvefintech.com"
          }
    , Settings.acme = fixtureAcme
    , Settings.pulumi_state_backend = fixturePulumiBackend "prodbox-fixture-state" "us-east-1"
    }

fixtureAwsCredentials :: String -> String -> Bool -> Settings.AwsCredentialsRef
fixtureAwsCredentials awsVaultPath regionValue includeSessionToken =
  Settings.AwsCredentialsRef
    { Settings.awsCredentialAccessKeyId = fixtureVaultRef vaultPath (Text.pack "access_key_id")
    , Settings.awsCredentialSecretAccessKey = fixtureVaultRef vaultPath (Text.pack "secret_access_key")
    , Settings.awsCredentialSessionToken =
        if includeSessionToken
          then Just (fixtureVaultRef vaultPath (Text.pack "session_token"))
          else Nothing
    , Settings.awsCredentialRegion = Text.pack regionValue
    }
 where
  vaultPath = Text.pack awsVaultPath

fixtureAcme :: Settings.AcmeSection
fixtureAcme =
  (Settings.acme Settings.defaultConfigFile)
    { Settings.email = Text.pack "test@resolvefintech.com"
    , Settings.eab_key_id = Just (fixtureVaultRef (Text.pack acmeEabVaultPath) (Text.pack "key_id"))
    , Settings.eab_hmac_key = Just (fixtureVaultRef (Text.pack acmeEabVaultPath) (Text.pack "hmac_key"))
    }

fixturePulumiBackend :: String -> String -> Settings.PulumiStateBackendSection
fixturePulumiBackend bucket regionValue =
  Settings.PulumiStateBackendSection
    { Settings.psbBucketName = Text.pack bucket
    , Settings.psbRegion = Text.pack regionValue
    , Settings.psbKeyPrefix = Text.pack "pulumi/"
    }

-- | Sprint 5.30: `Settings.vaultRef` is not exported, so the fixture builds the
-- same shape from the exported constructors.
fixtureVaultRef :: Text -> Text -> SecretRef
fixtureVaultRef path field =
  SecretRefVault
    VaultSecretRef
      { vaultSecretMount = Text.pack "secret"
      , vaultSecretPath = path
      , vaultSecretField = field
      }

-- | Sprint 5.31: the fake cluster's ResourceQuota objects, rendered from the
-- same capacity projection the validator compares against.
--
-- These used to be a hand-written JSON literal restating the numbers — a second
-- encoder of the production plan, and one that had already drifted: it declared
-- the keycloak namespace at @1430m@ where the plan projects @1330m@. Deriving
-- it makes the fixture agree with the plan by construction, so a capacity
-- change is reflected rather than contradicted.
renderFakeResourceQuotaItems :: String
renderFakeResourceQuotaItems =
  "{\"items\":[" ++ intercalate "," (map renderQuotaItem resourceGuardrailFakeNamespaces) ++ "]}"
 where
  renderQuotaItem namespace =
    case TestValidation.namespaceResourceQuotaHardFields defaultResourcePlan namespace of
      Left err ->
        error ("fake ResourceQuota fixture cannot project namespace " ++ namespace ++ ": " ++ err)
      Right fields ->
        "{\"metadata\":{\"namespace\":\""
          ++ namespace
          ++ "\",\"name\":\""
          ++ namespace
          ++ "-resource-quota\"},\"spec\":{\"hard\":{"
          ++ intercalate "," [renderField name value | (name, value) <- fields]
          ++ "}}}"
  renderField name value = "\"" ++ name ++ "\":\"" ++ value ++ "\""

resourceGuardrailFakeNamespaces :: [String]
resourceGuardrailFakeNamespaces = ["keycloak", "vscode", "api", "websocket", "gateway"]

defaultResourcePlan :: Capacity.ResourcePlan
defaultResourcePlan = Capacity.resource_plan (Settings.capacity Settings.defaultConfigFile)

-- | The fake cluster's LimitRange objects, rendered from the same projection the
-- validator compares against (Sprint 5.31). This is where the gateway's
-- 250m × 3 versus 750m × 2 drift had been sitting.
renderFakeLimitRangeItems :: String
renderFakeLimitRangeItems =
  "{\"items\":[" ++ intercalate "," (map renderLimitItem resourceGuardrailFakeNamespaces) ++ "]}"
 where
  renderLimitItem namespace =
    case TestValidation.namespaceLimitRangeContainerFields defaultResourcePlan namespace of
      Left err ->
        error ("fake LimitRange fixture cannot project namespace " ++ namespace ++ ": " ++ err)
      Right fields ->
        "{\"metadata\":{\"namespace\":\""
          ++ namespace
          ++ "\",\"name\":\""
          ++ namespace
          ++ "-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\","
          ++ intercalate "," (map renderGroup (groupFields fields))
          ++ "}]}}"
  groupFields fields =
    [ (prefix, [(name, value) | (candidate, name, value) <- fields, candidate == prefix])
    | prefix <- [["defaultRequest"], ["default"]]
    ]
  renderGroup (prefix, entries) =
    "\""
      ++ concat prefix
      ++ "\":{"
      ++ intercalate "," ["\"" ++ name ++ "\":\"" ++ value ++ "\"" | (name, value) <- entries]
      ++ "}"

-- | The gateway stability fake represents the same complete replica set the
-- production stability policy expects. Derive its cardinality through that
-- policy's projection so a capacity-plan change cannot leave a second authored
-- replica count behind in the fixture.
gatewayRuntimeFakeReplicaIndices :: [Int]
gatewayRuntimeFakeReplicaIndices =
  case TestValidation.gatewayRuntimeExpectedReplicas defaultResourcePlan of
    Left err -> error ("fake gateway fixture cannot project replica count: " ++ err)
    Right replicas -> [0 .. fromIntegral replicas - 1]

gatewayRuntimeFakeMemoryLimitQuantity :: String
gatewayRuntimeFakeMemoryLimitQuantity =
  case Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection (Text.pack "gateway") of
    Left err -> error ("fake gateway fixture cannot project memory limit: " ++ err)
    Right runtimePlan ->
      show
        ( RuntimeMemory.positiveBytesValue
            (RuntimeMemory.runtimeMemoryContainerLimitBytes runtimePlan)
        )

renderFakeGatewayPodItems :: Bool -> String
renderFakeGatewayPodItems firstPodOomKilled =
  "{\"items\":[" ++ intercalate "," (map renderPod gatewayRuntimeFakeReplicaIndices) ++ "]}"
 where
  renderPod index =
    "{\"metadata\":{\"namespace\":\"gateway\",\"name\":\""
      ++ podName
      ++ "\",\"uid\":\""
      ++ podUid
      ++ "\"},\"spec\":{\"containers\":[{\"name\":\"gateway\",\"resources\":{\"limits\":{\"memory\":\""
      ++ gatewayRuntimeFakeMemoryLimitQuantity
      ++ "\"}}}]},\"status\":{\"phase\":\"Running\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}],\"containerStatuses\":[{\"name\":\"gateway\",\"restartCount\":"
      ++ show restartCount
      ++ ",\"lastState\":"
      ++ lastState
      ++ "}]}}"
   where
    podName = "gateway-" ++ show index
    podUid = "gateway-uid-" ++ show index
    isOomKilled = firstPodOomKilled && index == 0
    restartCount = if isOomKilled then (1 :: Int) else 0
    lastState =
      if isOomKilled
        then
          "{\"terminated\":{\"reason\":\"OOMKilled\",\"exitCode\":137,\"finishedAt\":\"2026-07-11T00:00:00Z\"}}"
        else "{}"

renderFakeGatewayMetricItems :: String
renderFakeGatewayMetricItems =
  "{\"items\":[" ++ intercalate "," (map renderMetric gatewayRuntimeFakeReplicaIndices) ++ "]}"
 where
  renderMetric index =
    "{\"metadata\":{\"name\":\"gateway-"
      ++ show index
      ++ "\"},\"containers\":[{\"name\":\"gateway\",\"usage\":{\"memory\":\"128Mi\"}}]}"
