{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Map qualified as Map
import Dhall.Parser qualified as Parser
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef (SecretRef (SecretRefTestPlaintext))
import TestSupport (syntheticConfigFile, syntheticProjectConfig)

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
main :: IO ()
main = do
  let root = "/home/matthewnowak/prodbox"
      context = Tier0.context syntheticProjectConfig
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
  scope <- right (mkAuthorityScope (Tier0.cluster_id context))
  settings <- right =<< Settings.validateConfigWithContext root input syntheticConfigFile
  bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  decoded <- right =<< decodeRpcBirthControllerSettings scope root bytes
  unless
    ( Settings.validatedConfig decoded == syntheticConfigFile
        && Settings.validatedDeploymentContext decoded == Settings.validatedDeploymentContext settings
    )
    (fail "settings changed")
  putStrLn ("PASS complete settings/context roundtrip: " ++ show (BS.length bytes) ++ " bytes")
  expression <-
    right
      ( Binary.decodeExpression (Lazy.fromStrict bytes)
          :: Either Binary.DecodingFailure (Core.Expr Void Void)
      )
  let replace name value = case expression of
        Core.RecordLit fields ->
          Lazy.toStrict
            (Binary.encodeExpression (Core.RecordLit (Map.insert name (Core.makeRecordField value) fields)))
        _ -> error "producer did not encode a record"
      badConfig =
        syntheticConfigFile
          { Settings.domain = (Settings.domain syntheticConfigFile) {Settings.demo_ttl = 0}
          }
      plaintext =
        syntheticConfigFile
          { Settings.acme =
              (Settings.acme syntheticConfigFile)
                { Settings.eab_hmac_key = Just (SecretRefTestPlaintext "synthetic-only-never-rendered")
                }
          }
      invalidContext = input {Settings.contextInputVaultAddress = "file:///invalid-control-endpoint"}
      extraParameters = case Core.denote (Dhall.embed (Dhall.inject @Settings.ConfigFile) syntheticConfigFile) of
        Core.RecordLit fields -> Core.RecordLit (Map.insert "unexpected" (Core.makeRecordField (Core.BoolLit True)) fields)
        _ -> error "fixture configuration is not a record"
  imported <- right (Parser.exprFromText "payload-probe" "./disallowed-payload-import.dhall")
  forM_
    [ ("malformed", "bad CBOR")
    , ("deep-record-at-input-ceiling", deep (BS.pack [0x82, 8, 0xa1, 0x61, 0x78]))
    , ("deep-list-at-input-ceiling", deep (BS.pack [0x83, 4, 0xf6]))
    , ("oversized", BS.replicate (rpcBirthSettingsMaximumBytes + 1) 0)
    , ("trailing-data", bytes <> "\NUL")
    , ("unknown-version", replace "schema_version" (Core.NaturalLit 2))
    , ("extra-field", replace "unexpected" (Core.BoolLit True))
    , ("extra-nested-field", replace "parameters" extraParameters)
    ,
      ( "invalid-context"
      , replace "context" (Core.normalize (Core.denote (Dhall.embed Dhall.inject invalidContext)))
      )
    ,
      ( "non-normal-value"
      , Lazy.toStrict
          (Binary.encodeExpression (Core.Let (Core.makeBinding "unused" (Core.NaturalLit 0)) expression))
      )
    ,
      ( "invalid-settings"
      , replace
          "parameters"
          (Core.normalize (Core.denote (Dhall.embed (Dhall.inject @Settings.ConfigFile) badConfig)))
      )
    ,
      ( "plaintext-settings"
      , replace
          "parameters"
          (Core.normalize (Core.denote (Dhall.embed (Dhall.inject @Settings.ConfigFile) plaintext)))
      )
    , ("import", Lazy.toStrict (Binary.encodeExpression (Core.denote imported)))
    ]
    $ \(label, forged) -> do
      refused <- decodeRpcBirthControllerSettings scope root forged
      unless (isLeft refused) (fail ("accepted " ++ label))
      putStrLn ("PASS refuse " ++ label)
  forM_ [0 .. 255] $ \byte -> do
    refused <- decodeRpcBirthControllerSettings scope root (BS.singleton byte)
    unless (isLeft refused) (fail "accepted single-byte input")
  forM_ [0x9b, 0x7b, 0xdb] $ \header -> do
    refused <- decodeRpcBirthControllerSettings scope root (BS.pack (header : replicate 8 0xff))
    unless (isLeft refused) (fail "accepted overflowing CBOR length/tag")
  putStrLn "PASS 256 single-byte and three overflowing CBOR controls"
  foreignScope <- right (mkAuthorityScope "foreign")
  wrong <- decodeRpcBirthControllerSettings foreignScope root bytes
  unless (isLeft wrong) (fail "accepted foreign scope")
  forM_ ["relative", root ++ "/..", root ++ "/.", root ++ "\NULsuffix", replicate 4097 'x'] $ \path -> do
    refused <- decodeRpcBirthControllerSettings scope path bytes
    unless (isLeft refused) (fail "accepted unsafe root")
  unless
    (isLeft (encodeRpcBirthControllerSettings settings {Settings.validatedConfig = plaintext}))
    (fail "encoded plaintext")
  let huge =
        syntheticConfigFile
          { Settings.domain =
              (Settings.domain syntheticConfigFile)
                { Settings.demo_fqdn = Text.replicate (rpcBirthSettingsMaximumBytes + 1) "a"
                }
          }
  unless
    (isLeft (encodeRpcBirthControllerSettings settings {Settings.validatedConfig = huge}))
    (fail "encoded over-limit settings")
  putStrLn "PASS scope/root/producer refusal controls"

-- Construct the hostile input as bytes so the fixture does not allocate the
-- very expression tree whose early rejection it exercises.
deep :: BS.ByteString -> BS.ByteString
deep prefix =
  let width = BS.length prefix
      count = (rpcBirthSettingsMaximumBytes - 1) `div` width
      (body, _) =
        BS.unfoldrN
          (count * width)
          (\offset -> Just (BS.index prefix (offset `mod` width), offset + 1))
          (0 :: Int)
   in body <> BS.singleton 0xf5
