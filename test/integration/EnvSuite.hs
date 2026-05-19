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
        stdoutText `shouldContain` "acme.email=****.com"
        doesFileExist (tmpDir </> "prodbox-config.json") `shouldReturn` False

    it "fails fast on invalid config authored at the repo root" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") invalidConfig

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "aws.access_key_id must not be empty"

    it "requires repo-root commands to run from the repository root instead of searching upward" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath
        let nestedDir = tmpDir </> "nested"
        writeRepoMarkers tmpDir
        writeFile (tmpDir </> "prodbox-config.dhall") validConfig
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

validConfig :: String
validConfig =
  unlines
    [ "{ aws = { access_key_id = \"test-access-key\", secret_access_key = \"test-secret-key\", session_token = Some \"test-session-token\", region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }"
    , ", deployment = { dev_mode = True, bootstrap_public_ip_override = None Text, pulumi_enable_dns_bootstrap = True }"
    , ", storage = { manual_pv_host_root = \".data\" }"
    , "}"
    ]

invalidConfig :: String
invalidConfig =
  unlines
    [ "{ aws = { access_key_id = \"\", secret_access_key = \"test-secret-key\", session_token = None Text, region = \"us-east-1\" }"
    , ", aws_admin_for_test_simulation = { access_key_id = \"\", secret_access_key = \"\", session_token = None Text, region = \"\" }"
    , ", route53 = { zone_id = \"Z1234567890ABC\" }"
    , ", aws_substrate = { hosted_zone_id = \"\", subzone_name = \"\" }"
    , ", ses = { sender_domain = \"\", receive_subdomain = \"\", capture_bucket = \"\" }"
    , ", domain = { demo_fqdn = \"test.resolvefintech.com\", demo_ttl = 60 }"
    , ", acme = { email = \"test@resolvefintech.com\", server = \"https://acme-staging-v02.api.letsencrypt.org/directory\", eab_key_id = None Text, eab_hmac_key = None Text }"
    , ", deployment = { dev_mode = True, bootstrap_public_ip_override = None Text, pulumi_enable_dns_bootstrap = True }"
    , ", storage = { manual_pv_host_root = \".data\" }"
    , "}"
    ]
