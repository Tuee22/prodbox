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
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1" True
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
    , ", storage = { manual_pv_host_root = \".data\" }"
    , ", pulumi_state_backend = { bucket_name = \"\", region = \"\", key_prefix = \"\" }"
    , "}"
    ]

invalidConfig :: String
invalidConfig =
  unlines
    [ "{ aws = " ++ awsCredentialRefDhall "gateway/gateway/aws" "us-east-1" False
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , -- Invalid by current rules: `domain.demo_fqdn` is still validated as
      -- non-empty by `config validate`. Empty operational `aws.*` is
      -- intentionally VALID now (populated on demand by the harness /
      -- `--with-edge`), so an empty `aws.access_key_id` no longer fails fast.
      ", domain = { demo_fqdn = \"\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme.zerossl.com/v2/DV90\", eab_key_id = "
        ++ eabVaultRefDhall "key_id"
        ++ ", eab_hmac_key = "
        ++ eabVaultRefDhall "hmac_key"
        ++ " }"
    , ", deployment = " ++ deploymentDhallFragment
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
    , ", envoy_gateway_controller_replicas = None Natural"
    , ", envoy_gateway_data_plane_replicas = None Natural"
    , ", api_replicas = None Natural"
    , ", websocket_replicas = None Natural"
    , " }"
    ]
