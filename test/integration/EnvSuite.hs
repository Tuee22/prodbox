{-# LANGUAGE OverloadedStrings #-}

module EnvSuite
  ( integrationEnvSuite
  )
where

import CliSuite (runInstalledWithFakeAuthority)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (isSpace)
import Data.List (find, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.Render qualified as CapacityRender
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.Lib.ChartPlatform (ResolvedCustomImage (..), valuesForLifecycleAuthorityWithRpcBirth)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (SecretRefVault)
  , VaultSecretRef (..)
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , findExecutable
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
    it "renders an Authority registration pin change as one config-only StatefulSet rollout" $
      withSystemTempDirectory "prodbox-role-config-rollout" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        helm <-
          findExecutable "helm"
            >>= maybe (fail "helm is required for the declared host-toolchain chart proof") pure
        profile <-
          maybe (fail "the canonical Authority resource profile is missing") pure $
            find
              ((== "lifecycle-authority") . Capacity.profile_id)
              (Capacity.workload_profiles Capacity.defaultResourcePlan)
        let scope = "pin-render-root"
            pin = RpcBirthConfigRegistered (RpcBirthConfigPin scope 1 (Text.replicate 64 "a"))
            image =
              ResolvedCustomImage
                "harbor.test/prodbox/runtime"
                "pin-render"
                (Just ("sha256:" ++ replicate 64 'a'))
                (Just ("sha256:" ++ replicate 64 'b'))
            envelope = Capacity.resources profile
            resources =
              object
                [ "lifecycleAuthority"
                    .= object
                      [ "requests" .= CapacityRender.resourceVectorRuntimeValue (Capacity.request envelope)
                      , "limits" .= CapacityRender.resourceVectorRuntimeValue (Capacity.limit envelope)
                      ]
                ]
            values config = do
              roleValues <-
                either
                  fail
                  pure
                  ( valuesForLifecycleAuthorityWithRpcBirth
                      config
                      scope
                      "http://minio.fixture:9000"
                      "pin-render"
                      "pin-render"
                      (Just image)
                  )
              case roleValues of
                Object entries ->
                  pure
                    ( Object
                        ( KeyMap.insert
                            "storage"
                            ( object
                                ["size" .= CapacityRender.memoryQuantity (Capacity.durable_storage_mib (Capacity.request envelope))]
                            )
                            ( KeyMap.insert
                                "kubernetesApiEgress"
                                (object ["addresses" .= (["10.0.0.1"] :: [Text]), "port" .= (6443 :: Int)])
                                (KeyMap.insert "resources" resources entries)
                            )
                        )
                    )
                _ -> fail "the canonical Authority values must be an object"
            render filename config = do
              payload <- values config
              let path = tmpDir </> filename
              Lazy.writeFile path (encode (payload :: Value))
              (code, output, errors) <-
                readCreateProcessWithExitCode
                  ( proc
                      helm
                      [ "template"
                      , "pin-render"
                      , repoRoot </> "charts" </> "lifecycle-authority"
                      , "--values"
                      , path
                      , "--show-only"
                      , "templates/statefulset.yaml"
                      ]
                  )
                  ""
              if code == ExitSuccess then pure output else fail errors
        legacy <- render "legacy.json" RpcBirthConfigLegacy
        registered <- render "registered.json" pin
        retried <- render "retried.json" pin
        oldDigest <- roleConfigChecksum legacy
        newDigest <- roleConfigChecksum registered
        retryDigest <- roleConfigChecksum retried
        newDigest `shouldNotBe` oldDigest
        retryDigest `shouldBe` newDigest
        withoutRoleConfigChecksum legacy `shouldBe` withoutRoleConfigChecksum registered
        scalarLine "kind" registered `shouldBe` ["StatefulSet"]
        scalarLine "replicas" registered `shouldBe` ["1"]
        registered `shouldContain` "    type: RollingUpdate"

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
        stdoutText `shouldContain` "acme.email=****test"
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

-- Helm validates the complete YAML. Only this one public scalar is projected;
-- comparing the remaining canonical rendering also pins image/resources and
-- every other pod-template property across the same causal input profile.
roleConfigChecksum :: String -> IO Text
roleConfigChecksum rendered = case scalarLine "checksum/role-config" rendered of
  [quoted] -> case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack quoted)) of
    Right digest
      | Text.length digest == 64 && Text.all (`elem` ("0123456789abcdef" :: String)) digest -> pure digest
    _ -> fail "Helm omitted the canonical public role-config checksum"
  _ -> fail "Helm must render exactly one role-config checksum"

scalarLine :: String -> String -> [String]
scalarLine key rendered =
  [ dropWhile isSpace (drop (length prefix) trimmed)
  | line <- lines rendered
  , let trimmed = dropWhile isSpace line
  , prefix `isPrefixOf` trimmed
  ]
 where
  prefix = key <> ":"

withoutRoleConfigChecksum :: String -> [String]
withoutRoleConfigChecksum = filter (not . isPrefixOf "checksum/role-config:" . dropWhile isSpace) . lines

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
  syntheticConfigFile
    { Settings.aws =
        (Settings.aws syntheticConfigFile)
          { Settings.awsCredentialSessionToken =
              Just (envVaultRef (Text.pack "aws/lifecycle-provider") (Text.pack "session_token"))
          , Settings.awsCredentialRegion = Text.pack (fixtureAwsRegion FixtureUsEast1)
          }
    , Settings.route53 = Settings.Route53Section {Settings.zone_id = Text.pack "Z1234567890ABC"}
    , Settings.domain =
        (Settings.domain syntheticConfigFile)
          { Settings.demo_fqdn = Text.pack "test.example.test"
          }
    , Settings.acme =
        (Settings.acme syntheticConfigFile)
          { Settings.email = Text.pack "test@example.test"
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
