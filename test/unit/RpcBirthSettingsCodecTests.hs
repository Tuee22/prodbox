{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module RpcBirthSettingsCodecTests (rpcBirthSettingsCodecSuite) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Dhall qualified
import Dhall.Core qualified as Core
import Prodbox.Config.CanonicalDhallDataSyntax
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.RpcBirthSettingsCodec
import Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope (..))
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import System.Mem (performGC)
import System.Mem.StableName (eqStableName, makeStableName)
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport
  ( SuiteBuilder
  , describe
  , it
  , syntheticAwsSubstrateProfileInput
  , syntheticConfigFile
  , syntheticProjectConfig
  )

rpcBirthSettingsCodecSuite :: SuiteBuilder ()
rpcBirthSettingsCodecSuite = describe "retained controller settings codecs" $ do
  it "preserves the SDK expected and declared envelope schemas" $ do
    Dhall.expected rpcBirthSettingsDecoder @?= Dhall.expected (Dhall.auto @SettingsEnvelope)
    Dhall.declared rpcBirthSettingsEncoder @?= Dhall.declared (Dhall.inject @SettingsEnvelope)
  it "retains one decoder and encoder identity across collection and concurrent borrowers" $ do
    checkRoot (evaluate rpcBirthSettingsDecoder) (evaluate rpcBirthSettingsDecoder)
    checkRoot (evaluate rpcBirthSettingsEncoder) (evaluate rpcBirthSettingsEncoder)
  it "preserves SDK embedding and extraction for home, AWS and wide Unicode values" $ do
    values <- fixtures
    forM_ values $ \value -> do
      let actual = Dhall.embed rpcBirthSettingsEncoder value
          expected = Dhall.embed (Dhall.inject @SettingsEnvelope) value
      actual @?= expected
      fmap project (Dhall.toMonadic (Dhall.extract rpcBirthSettingsDecoder actual))
        @?= Right (project value)
      fmap project (Dhall.extract rpcBirthSettingsDecoder actual)
        @?= fmap project (Dhall.extract (Dhall.auto @SettingsEnvelope) actual)
  it "preserves evaluated source erasure when the caller supplies the retained encoder" $ do
    values <- fixtures
    forM_ values $ \value -> do
      let actual =
            canonicalDhallDataSyntaxExpression
              (eraseCanonicalDhallDataSource (embedCanonicalDhallDataWith rpcBirthSettingsEncoder value))
          expected = Core.denote (Dhall.embed (Dhall.inject @SettingsEnvelope) value)
          generic =
            canonicalDhallDataSyntaxExpression (eraseCanonicalDhallDataSource (embedCanonicalDhallData value))
      actual @?= expected
      generic @?= expected

checkRoot :: IO value -> IO value -> IO ()
checkRoot borrowFirst borrowSecond = do
  first <- borrowFirst >>= makeStableName
  performGC
  (left, right) <- concurrently (borrowFirst >>= makeStableName) (borrowSecond >>= makeStableName)
  assertBool
    "a retained codec root was reconstructed"
    (eqStableName first left && eqStableName first right)

project :: SettingsEnvelope -> (Integer, Settings.DeploymentContextInput, Settings.ConfigFile)
project value = (toInteger (schema_version value), context value, parameters value)

fixtures :: IO [SettingsEnvelope]
fixtures = do
  aws <- either (fail . show) pure (Aws.mkAwsSubstrateProfile syntheticAwsSubstrateProfileInput)
  let context = Tier0.context syntheticProjectConfig
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
      configured =
        syntheticConfigFile
          { Settings.aws_substrate = (Settings.aws_substrate syntheticConfigFile) {Settings.profile = Just aws}
          }
      wide =
        syntheticConfigFile
          { Settings.domain =
              (Settings.domain syntheticConfigFile)
                { Settings.demo_fqdn = "λ\0🙂"
                , Settings.demo_ttl = 2 ^ (200 :: Int)
                }
          }
  pure [SettingsEnvelope 1 input value | value <- [syntheticConfigFile, configured, wide]]
