{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module InspectedRpcBirthSettings (inspectedRpcBirthSettingsSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.Either (isLeft)
import Data.Text qualified as Text
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.Settings qualified as Settings
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it, syntheticConfigFile, syntheticProjectConfig)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

fixture :: IO (AuthorityScope, Settings.ValidatedSettings, Bytes.ByteString)
fixture = do
  let context = Tier0.context syntheticProjectConfig
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
  scope <- right (mkAuthorityScope (Tier0.cluster_id context))
  settings <- right =<< Settings.validateConfigWithContext root input syntheticConfigFile
  bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  pure (scope, settings, bytes)

root :: FilePath
root = "/synthetic/prodbox"

inspectedRpcBirthSettingsSuite :: SuiteBuilder ()
inspectedRpcBirthSettingsSuite = describe "inspected controller settings" $ do
  it "preserves the complete settings and context through both public readers" $ do
    (scope, settings, bytes) <- fixture
    inspected <- right (inspectRpcBirthControllerSettings bytes)
    captured <- right =<< decodeInspectedRpcBirthControllerSettings scope root inspected
    ordinary <- right =<< decodeRpcBirthControllerSettings scope root bytes
    forM_ [captured, ordinary] $ \decoded -> do
      Settings.validatedConfig decoded @?= Settings.validatedConfig settings
      Settings.validatedDeploymentContext decoded @?= Settings.validatedDeploymentContext settings
      Settings.resolvedManualPvHostRoot decoded @?= Settings.resolvedManualPvHostRoot settings
  it "measures the held source and refuses malformed, trailing and over-limit inputs" $ do
    (_, _, bytes) <- fixture
    inspected <- right (inspectRpcBirthControllerSettings bytes)
    let usage = inspectedRpcBirthSettingsUsage inspected
    canonicalDhallInputBytes usage @?= fromIntegral (Bytes.length bytes)
    assertBool "fixture was not structurally inspected" (canonicalDhallValueVisits usage > 0)
    forM_
      [ Bytes.empty
      , "invalid CBOR"
      , bytes <> Bytes.singleton 0
      , Bytes.take (Bytes.length bytes - 1) bytes
      , Bytes.replicate (rpcBirthSettingsMaximumBytes + 1) 0
      ]
      $ \input ->
        assertBool "inspection accepted invalid source" (isLeft (inspectRpcBirthControllerSettings input))
  it "checks each decoder's scope and root after successful inspection" $ do
    (scope, _, bytes) <- fixture
    inspected <- right (inspectRpcBirthControllerSettings bytes)
    foreignScope <- right (mkAuthorityScope "foreign-scope")
    refused <- decodeInspectedRpcBirthControllerSettings foreignScope root inspected
    assertBool "inspected data bypassed scope validation" (isLeft refused)
    forM_ ["relative", root ++ "/..", root ++ "/.", root ++ "\NULsuffix", replicate 4097 'x'] $ \path -> do
      result <- decodeInspectedRpcBirthControllerSettings scope path inspected
      assertBool "inspected data bypassed root validation" (isLeft result)
  it "measures the selected storage path independently of other text fields" $ do
    (_, settings, _) <- fixture
    let config = Settings.validatedConfig settings
        selected =
          settings
            { Settings.validatedConfig =
                config
                  { Settings.storage =
                      (Settings.storage config) {Settings.manual_pv_host_root = "a/./λλ/😀😀😀"}
                  , Settings.domain =
                      (Settings.domain config) {Settings.demo_fqdn = Text.replicate 131072 "x"}
                  }
            }
    bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings selected)
    inspected <- right (inspectRpcBirthControllerSettings bytes)
    canonicalDhallPathComponentCharacters (inspectedRpcBirthSettingsUsage inspected) @?= 3
  it "retains semantic validation after a successful shape check" $ do
    (scope, settings, _) <- fixture
    let config = Settings.validatedConfig settings
        invalid =
          settings
            { Settings.validatedConfig =
                config {Settings.domain = (Settings.domain config) {Settings.demo_ttl = 0}}
            }
    bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings invalid)
    inspected <- right (inspectRpcBirthControllerSettings bytes)
    result <- decodeInspectedRpcBirthControllerSettings scope root inspected
    case result of
      Left RpcBirthSettingsValidationRefused -> pure ()
      _ -> assertFailure "shape inspection bypassed semantic validation"
  it "refuses metadata funding before parsing and accepts its exact constructor-data floor" $ do
    (_, _, bytes) <- fixture
    let required = rpcBirthSettingsShapeDataBytes
    case inspectRpcBirthControllerSettingsWithin (required - 1) "malformed CBOR" of
      Left cause -> cause @?= RpcBirthSettingsPreparationUnderfunded required (required - 1)
      Right _ -> assertFailure "underfunded metadata inspection ran"
    ordinary <- right (inspectRpcBirthControllerSettings bytes)
    bounded <- right (inspectRpcBirthControllerSettingsWithin required bytes)
    inspectedRpcBirthSettingsUsage bounded @?= inspectedRpcBirthSettingsUsage ordinary
