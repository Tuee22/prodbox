module EnvSuite
  ( integrationEnvSuite
  )
where

import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getCurrentDirectory
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

integrationEnvSuite :: SuiteBuilder ()
integrationEnvSuite = do
  describe "native Haskell env integration suite" $ do
    it "shows masked settings without materializing JSON from the operator-facing binary" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
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
        stdoutText `shouldContain` "acme.email=****.com"
        doesFileExist (tmpDir </> "prodbox-config.json") `shouldReturn` False

    it "fails fast on invalid config authored beside the binary" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 invalidConfig)

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "domain.demo_fqdn must not be empty"

    it "fails fast when resource reservations exceed host capacity" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 invalidResourceConfig)

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "rke2_reserved + eviction_floor must fit within host_capacity"

    it "requires repo-root commands to run from the repository root instead of searching upward" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let nestedDir = tmpDir </> "nested"
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox.dhall") (wrapTier0 validConfig)
        createDirectoryIfMissing True nestedDir

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just nestedDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "Current working directory is not the repository root."

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
  writeFile (repoRoot </> "prodbox-config-types.dhall") "-- temp schema marker\n"
  createDirectoryIfMissing True (repoRoot </> "DEVELOPMENT_PLAN")
  writeFile (repoRoot </> "DEVELOPMENT_PLAN/README.md") "# temp\n"

secretRefTypeDhall :: String
secretRefTypeDhall =
  "< Vault : { mount : Text, path : Text, field : Text }"
    ++ " | TransitKey : Text"
    ++ " | Prompt : { name : Text, purpose : Text }"
    ++ " | TestPlaintext : Text"
    ++ " >"

vaultSecretRefDhall :: String -> String -> String
vaultSecretRefDhall path field =
  unlines
    [ secretRefTypeDhall ++ ".Vault"
    , "  { mount = \"secret\""
    , "  , path = " ++ show path
    , "  , field = " ++ show field
    , "  }"
    ]

-- | Sprint 7.15: a @Some SecretRef.Vault@ expression into @secret/acme/eab@
-- for the given field (the EAB material now references Vault, not plaintext).
eabVaultRefDhall :: String -> String
eabVaultRefDhall field =
  "Some (" ++ vaultSecretRefDhall "acme/eab" field ++ ")"

awsCredentialRefDhall :: String -> String -> Bool -> String
awsCredentialRefDhall path regionValue includeSessionToken =
  concat
    [ "{ access_key_id = "
    , vaultSecretRefDhall path "access_key_id"
    , ", secret_access_key = "
    , vaultSecretRefDhall path "secret_access_key"
    , ", session_token = "
    , if includeSessionToken
        then "Some (" ++ vaultSecretRefDhall path "session_token" ++ ")"
        else "None (" ++ secretRefTypeDhall ++ ")"
    , ", region = "
    , show regionValue
    , " }"
    ]

validConfig :: String
validConfig =
  configWithDomainAndCapacity "test.resolvefintech.com" capacityDhallFragment

invalidConfig :: String
invalidConfig =
  configWithDomainAndCapacity "" capacityDhallFragment

invalidResourceConfig :: String
invalidResourceConfig =
  configWithDomainAndCapacity "test.resolvefintech.com" overReservedCapacityDhallFragment

configWithDomainAndCapacity :: String -> String -> String
configWithDomainAndCapacity domainName capacityFragment =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1" True
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = " ++ show domainName ++ ", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = "
        ++ eabVaultRefDhall "key_id"
        ++ ", eab_hmac_key = "
        ++ eabVaultRefDhall "hmac_key"
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
    , ", capacity = " ++ capacityFragment
    , ", cluster_topology = " ++ clusterTopologyDhallFragment
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

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
  capacityWithResourcePlan resourcePlanDhallFragment

overReservedCapacityDhallFragment :: String
overReservedCapacityDhallFragment =
  capacityWithResourcePlan overReservedResourcePlanDhallFragment

capacityWithResourcePlan :: String -> String
capacityWithResourcePlan resourcePlanFragment =
  unlines
    [ "{ node_budget = { cpu = 8, memory = 16, storage = 100 }"
    , ", workload_budget = { cpu = 4, memory = 8, storage = 40 }"
    , ", region_quota = { cpu = 32, memory = 64, storage = 500 }"
    , ", resource_plan = " ++ resourcePlanFragment
    , ", runtime_memory_profiles = " ++ runtimeMemoryProfilesDhallFragment
    , "}"
    ]

runtimeMemoryProfilesDhallFragment :: String
runtimeMemoryProfilesDhallFragment =
  "[ { runtime_profile_id = \"gateway\", bounded_application_state_bytes = 67108864, bounded_pending_persistence_state_bytes = 16777216, bounded_in_heap_transport_decode_bytes = 67108864, other_heap_reserve_bytes = 50331648, heap_cap_bytes = 268435456, native_non_heap_reserve_bytes = 67108864, child_process_budget = { permit_capacity = Some 1, action_deadline_milliseconds = Some 30000, simultaneous_peak_bytes = [ 67108864 ] }, kernel_cgroup_reserve_bytes = 33554432, safety_margin_bytes = 67108864 } ]"

resourcePlanDhallFragment :: String
resourcePlanDhallFragment =
  resourcePlanDhallFragmentWithReserved (resourceVectorDhall (1000, 2048, 10240, 1024))

overReservedResourcePlanDhallFragment :: String
overReservedResourcePlanDhallFragment =
  resourcePlanDhallFragmentWithReserved (resourceVectorDhall (8000, 2048, 10240, 1024))

resourcePlanDhallFragmentWithReserved :: String -> String
resourcePlanDhallFragmentWithReserved reservedVector =
  unlines
    [ "{ host_capacity = { milli_cpu = 8000, memory_mib = 15872, ephemeral_storage_mib = 100000, durable_storage_mib = 180000 }"
    , ", rke2_reserved = " ++ reservedVector
    , ", eviction_floor = { milli_cpu = 500, memory_mib = 1024, ephemeral_storage_mib = 10240, durable_storage_mib = 1024 }"
    , ", namespace_quotas ="
    , "  [ { namespace_name = \"keycloak\", quota = { milli_cpu = 2025, memory_mib = 4448, ephemeral_storage_mib = 12000, durable_storage_mib = 61440 } }"
    , "  , { namespace_name = \"vscode\", quota = { milli_cpu = 2425, memory_mib = 5216, ephemeral_storage_mib = 10944, durable_storage_mib = 112640 } }"
    , "  , { namespace_name = \"api\", quota = { milli_cpu = 500, memory_mib = 768, ephemeral_storage_mib = 2000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"websocket\", quota = { milli_cpu = 500, memory_mib = 768, ephemeral_storage_mib = 3000, durable_storage_mib = 1000 } }"
    , "  , { namespace_name = \"gateway\", quota = { milli_cpu = 1250, memory_mib = 3584, ephemeral_storage_mib = 6000, durable_storage_mib = 20480 } }"
    , "  , { namespace_name = \"prodbox\", quota = { milli_cpu = 1000, memory_mib = 1792, ephemeral_storage_mib = 5000, durable_storage_mib = 20480 } }"
    , "  , { namespace_name = \"vault\", quota = { milli_cpu = 300, memory_mib = 512, ephemeral_storage_mib = 2000, durable_storage_mib = 1024 } }"
    , "  ]"
    , ", workload_profiles ="
    , "  [ " ++ resourceProfileDhall "keycloak" "keycloak" 1 (500, 1024, 1024, 1) (600, 1280, 2048, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-vault-secrets" "keycloak" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "keycloak-postgres" "keycloak" 3 (250, 512, 1024, 1024) (350, 768, 2048, 2048)
    , "  , "
        ++ resourceProfileDhall
          "keycloak-postgres-replica-cert-copy"
          "keycloak"
          3
          (10, 16, 32, 1)
          (25, 32, 64, 1)
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
    , "  , " ++ resourceProfileDhall "vscode" "vscode" 1 (500, 1024, 1024, 1024) (600, 1280, 2048, 2048)
    , "  , "
        ++ resourceProfileDhall "vscode-vault-secrets" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , "
        ++ resourceProfileDhall "vscode-secret-materializer" "vscode" 1 (50, 128, 256, 1) (100, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "api" "api" 2 (250, 256, 512, 1) (250, 384, 512, 1)
    , "  , " ++ resourceProfileDhall "websocket" "websocket" 2 (100, 256, 512, 1) (150, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "redis" "websocket" 1 (100, 256, 512, 1) (150, 256, 512, 1)
    , "  , " ++ resourceProfileDhall "gateway" "gateway" 3 (250, 256, 512, 1) (250, 512, 512, 1)
    , "  , " ++ resourceProfileDhall "pulsar" "gateway" 1 (250, 1024, 1024, 1) (500, 2048, 4096, 1)
    , "  , " ++ resourceProfileDhall "minio" "prodbox" 1 (250, 512, 1024, 1024) (500, 1024, 2048, 2048)
    , "  , " ++ resourceProfileDhall "harbor" "prodbox" 1 (200, 256, 512, 1024) (300, 512, 1024, 2048)
    , "  , "
        ++ resourceProfileDhall "percona-postgres-operator" "prodbox" 1 (100, 128, 512, 1) (150, 256, 1024, 1)
    , "  , " ++ resourceProfileDhall "vault" "vault" 1 (200, 256, 1024, 1) (250, 512, 1024, 1)
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
