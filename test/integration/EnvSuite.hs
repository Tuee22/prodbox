module EnvSuite
  ( integrationEnvSuite
  )
where

import CliSuite (runInstalledWithFakeAuthority)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (SecretRefVault)
  , VaultSecretRef (..)
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
import Tier0Fixture (tier0FixtureWithParameters, writeTier0Fixture)

integrationEnvSuite :: SuiteBuilder ()
integrationEnvSuite = do
  describe "native Haskell env integration suite" $ do
    it "shows masked settings without materializing JSON from the operator-facing binary" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "show"]

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "aws.access_key_id=Vault:secret/aws/lifecycle-provider#access_key_id"
        stdoutText `shouldContain` "acme.email=****.com"
        doesFileExist (tmpDir </> "prodbox-config.json") `shouldReturn` False

    it "fails fast on invalid config authored beside the binary" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters invalidConfig)

        (exitCode, _, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "validate"]

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "domain.demo_fqdn must not be empty"

    it "fails fast when resource reservations exceed host capacity" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters invalidResourceConfig)

        (exitCode, _, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "validate"]

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "rke2_reserved + eviction_floor"
        stderrText `shouldContain` "exceeds host_capacity"

    it "requires repo-root commands to run from the repository root instead of searching upward" $
      withSystemTempDirectory "prodbox-hs-env" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let nestedDir = tmpDir </> "nested"
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
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

-- | Sprint 5.30: typed fixtures rendered through the one canonical Tier-0
-- encoder. Both "invalid" fixtures below are Dhall-VALID and Haskell-invalid,
-- so they are expressible as well-typed values — the raw-text escape is for
-- fixtures that must not type-check at all, which these are not.
validConfig :: Settings.ConfigFile
validConfig = envFixtureConfig

-- | Refused by `validateLocalConfig`: an empty served hostname.
invalidConfig :: Settings.ConfigFile
invalidConfig =
  envFixtureConfig
    { Settings.domain = (Settings.domain envFixtureConfig) {Settings.demo_fqdn = Text.pack ""}
    }

-- | Refused by the capacity compile: reservations exceed the host.
--
-- Note the property this depends on, which Sprint 5.30 pins with a unit test:
-- because the plan does not compile, `renderProjectConfigDhall` takes its
-- totality fallback and emits NO Ring-1 `assert`, so the file still loads and
-- the refusal still comes from the Haskell validator — which is what this case
-- asserts.
invalidResourceConfig :: Settings.ConfigFile
invalidResourceConfig =
  envFixtureConfig
    { Settings.capacity =
        Capacity.defaultCapacitySection
          { Capacity.resource_plan =
              Capacity.defaultResourcePlan
                { Capacity.rke2_reserved = Capacity.ResourceVector 64000 131072 1000000 1000000
                }
          }
    }

-- | Sprint 1.91: the fixture states its own region.
--
-- It used to inherit one from `defaultConfigFile`, which seeded a literal.
-- Emptying that seed left this fixture describing an AWS-capable host with no
-- region -- the enumeration of every `defaultConfigFile` consumer found this
-- one, and `CliSuite` already overrode the whole `aws` block.
envFixtureConfig :: Settings.ConfigFile
envFixtureConfig =
  Settings.defaultConfigFile
    { Settings.aws =
        (Settings.aws Settings.defaultConfigFile)
          { Settings.awsCredentialSessionToken =
              Just (envVaultRef (Text.pack "aws/lifecycle-provider") (Text.pack "session_token"))
          , Settings.awsCredentialRegion = Text.pack "us-east-1"
          }
    , Settings.route53 = Settings.Route53Section {Settings.zone_id = Text.pack "Z1234567890ABC"}
    , Settings.domain =
        (Settings.domain Settings.defaultConfigFile)
          { Settings.demo_fqdn = Text.pack "test.resolvefintech.com"
          }
    , Settings.acme =
        (Settings.acme Settings.defaultConfigFile)
          { Settings.email = Text.pack "test@resolvefintech.com"
          }
    }

envVaultRef :: Text -> Text -> SecretRef
envVaultRef path field =
  SecretRefVault
    VaultSecretRef
      { vaultSecretMount = Text.pack "secret"
      , vaultSecretPath = path
      , vaultSecretField = field
      }
