{-# LANGUAGE OverloadedStrings #-}

module TestSecretsSecurity (testSecretsSecuritySuite) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Prodbox.Aws.AdminCredentials (validateAdminAwsRegion)
import Prodbox.Config.SchemaDhall (renderTestSecretsTypesDhall)
import Prodbox.ControlPlane.TargetMaterialFixture (seedAcmeEabFromTestSecrets)
import Prodbox.Settings (Credentials (..))
import Prodbox.Settings.Coordinate (AwsRegion, mkAwsRegion)
import Prodbox.Vault.Host
  ( TestSecretsFileRefusal (..)
  , defaultTestSecrets
  , loadTestSecrets
  , testSecretsFileRefusal
  , testSecretsPath
  )
import System.Directory (createDirectory, renameFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createNamedPipe
  , createSymbolicLink
  , fileMode
  , getFileStatus
  , setFileMode
  )
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import TestSupport

testSecretsSecuritySuite :: SuiteBuilder ()
testSecretsSecuritySuite = describe "Sprint 5.53 private harness fixture boundary" $ do
  it "keeps a missing fixture distinct from a refused fixture" $
    withSystemTempDirectory "prodbox-secret-file" $ \root ->
      loadTestSecrets root `shouldReturn` Nothing
  mapM_ privateModeCase [0o400, 0o600, 0o700]
  mapM_ exposedModeCase [0o644, 0o640, 0o604, 0o601, 0o660]
  it "refuses an otherwise private file owned by another effective identity" $
    withFixture $ \root -> do
      status <- getFileStatus (testSecretsPath root)
      effectiveUser <- getEffectiveUserID
      testSecretsFileRefusal effectiveUser status `shouldBe` Nothing
      testSecretsFileRefusal (effectiveUser + 1) status `shouldBe` Just TestSecretsWrongOwner
  it "refuses a symlink without reading or modifying its private target" $
    withFixture $ \root -> do
      let target = root </> "private-source.dhall"
      renameFile (testSecretsPath root) target
      before <- readFile target
      createSymbolicLink target (testSecretsPath root)
      loadTestSecrets root >>= shouldRefuse
      readFile target `shouldReturn` before
      ((.&. 0o777) . fileMode <$> getFileStatus target) `shouldReturn` 0o600
  it "refuses a dangling symlink rather than treating it as absent" $
    withSystemTempDirectory "prodbox-secret-file" $ \root -> do
      createSymbolicLink (root </> "absent.dhall") (testSecretsPath root)
      loadTestSecrets root >>= shouldRefuse
  it "refuses a directory fixture" $
    withSystemTempDirectory "prodbox-secret-file" $ \root -> do
      createDirectory (testSecretsPath root)
      loadTestSecrets root >>= shouldRefuse
  it "refuses a FIFO without waiting for a writer" $
    withSystemTempDirectory "prodbox-secret-file" $ \root -> do
      createNamedPipe (testSecretsPath root) 0o600
      observed <- timeout 1000000 (loadTestSecrets root)
      case observed of
        Nothing -> expectationFailure "fixture reader waited for a FIFO writer"
        Just result -> shouldRefuse result
  it "still reports a private malformed Dhall fixture as a decode refusal" $
    withFixture $ \root -> do
      writeFile (testSecretsPath root) "not-a-dhall-value"
      result <- loadTestSecrets root
      case result of
        Just (Left detail) -> detail `shouldContain` "failed to decode"
        _ -> expectationFailure "expected a private fixture decode refusal"
  mapM_ eabRefusalCase [0o600, 0o644]
  describe "admin and backend regions before credential Job preparation" $ do
    it "preserves the complete credential only for the configured region" $ do
      validateAdminAwsRegion (Just expectedRegion) credential `shouldBe` Right credential
    it "refuses a fixture from another region without disclosing key material" $ do
      let other = credential {region = Text.pack (fixtureAwsRegion FixtureUsEast1)}
      case validateAdminAwsRegion (Just expectedRegion) other of
        Left detail -> do
          detail `shouldContain` "differs from pulumi_state_backend.region"
          detail `shouldNotContain` Text.unpack (access_key_id credential)
          detail `shouldNotContain` Text.unpack (secret_access_key credential)
        Right _ -> expectationFailure "expected an early region mismatch refusal"
    it "refuses an unconfigured backend region" $
      validateAdminAwsRegion Nothing credential `shouldSatisfy` isLeft
    it "refuses an invalid fixture region" $
      validateAdminAwsRegion (Just expectedRegion) credential {region = "invalid-region"}
        `shouldSatisfy` isLeft
 where
  eabRefusalCase mode = it ("propagates a fixture refusal through EAB ingress with zero deliveries at mode " <> show mode) $
    withFixture $ \root -> do
      writeFile (testSecretsPath root) "unread-secret-sentinel"
      setFileMode (testSecretsPath root) mode
      deliveries <- newIORef (0 :: Int)
      let deliver _ = modifyIORef' deliveries (+ 1) >> pure (Right ())
      result <- try (seedAcmeEabFromTestSecrets deliver root) :: IO (Either IOException ())
      result `shouldSatisfy` isLeft
      readIORef deliveries `shouldReturn` 0
  privateModeCase mode = it ("decodes an owned private regular fixture with mode " <> show mode) $
    withFixture $ \root -> do
      setFileMode (testSecretsPath root) mode
      loadTestSecrets root `shouldReturn` Just (Right defaultTestSecrets)
  exposedModeCase mode = it ("refuses group or other permission bits without changing mode " <> show mode) $
    withFixture $ \root -> do
      writeFile (testSecretsPath root) "unread-secret-sentinel"
      setFileMode (testSecretsPath root) mode
      result <- loadTestSecrets root
      shouldRefuse result
      case result of
        Just (Left detail) -> detail `shouldNotContain` "unread-secret-sentinel"
        _ -> pure ()
      ((.&. 0o777) . fileMode <$> getFileStatus (testSecretsPath root)) `shouldReturn` mode

withFixture :: (FilePath -> IO value) -> IO value
withFixture body = withSystemTempDirectory "prodbox-secret-file" $ \root -> do
  writeFile (root </> "test-secrets-types.dhall") (Text.unpack renderTestSecretsTypesDhall)
  writeFile
    (testSecretsPath root)
    "let TestSecrets = ./test-secrets-types.dhall in TestSecrets.default"
  setFileMode (testSecretsPath root) 0o600
  body root

shouldRefuse :: Maybe (Either String value) -> Expectation
shouldRefuse result = case result of
  Just (Left detail) -> detail `shouldContain` "chmod 600 test-secrets.dhall"
  _ -> expectationFailure "expected a private-file metadata refusal"

expectedRegion :: AwsRegion
expectedRegion = either (error . show) id (mkAwsRegion (Text.pack (fixtureAwsRegion FixtureCaCentral1)))

credential :: Credentials
credential =
  Credentials
    "fixture-key-identity"
    "fixture-secret-material"
    Nothing
    (Text.pack (fixtureAwsRegion FixtureCaCentral1))
