{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.13 chunk 33: host-side pre-helm derived-Secret bootstrap.
--
-- The Sprint 3.13 doctrine has the gateway daemon write the
-- @keycloak-runtime@ / @keycloak-oidc-clients@ / Patroni Secrets via its
-- @/v1/secret/ensure-namespace@ endpoint, invoked from each chart's Helm
-- pre-install Job. The chart's own ConfigMap (Keycloak realm import) then
-- reads those Secrets via Helm @lookup@ at template render time.
--
-- This breaks on first install: Helm renders ALL templates (including
-- @lookup@) BEFORE applying pre-install hooks, so the lookup sees an
-- empty cluster and falls back to the @\"change-me\"@ placeholder
-- substituted into the realm import. Keycloak imports the realm with the
-- placeholder once, and never re-imports — direct-grant OIDC handshakes
-- 401 forever.
--
-- The fix: have the host-side @prodbox charts deploy@ flow apply the
-- same derived Secrets the daemon would, BEFORE calling
-- @helm upgrade --install@. The daemon's HTTP endpoint stays as the
-- in-cluster idempotent fallback (the chart's pre-install Job still
-- runs, but on first install it sees the Secret already present and is
-- a no-op).
--
-- Reuses the same building blocks the daemon uses (the canonical
-- @derivedSecretInventoryFor@ inventory + @deriveBase64Url@) so host
-- and daemon agree byte-for-byte on what gets written.
module Prodbox.Secret.HostBootstrap
  ( preApplyDerivedSecretsForRelease
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (Value, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isHexDigit)
import Data.List (isPrefixOf, tails)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word8)
import Prodbox.Infra.MinioBackend (withMinioPortForward)
import Prodbox.K8s.InCluster (secretManifestJson)
import Prodbox.Result (Result (..))
import Prodbox.Secret.Derive (MasterSeed, deriveBase64Url, masterSeed)
import Prodbox.Secret.Inventory
  ( DerivedSecretEntry (..)
  , derivedSecretInventoryFor
  )
import Prodbox.Secret.MasterSeed
  ( defaultMinioMasterSeedConfig
  , ensureMasterSeed
  , renderMasterSeedError
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  , processExitCode
  )
import System.Directory (removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.IO.Temp (openBinaryTempFile)

-- | Materialize every @derivedSecretInventoryFor namespace release@
-- entry as a k8s @Secret@ via @kubectl apply -f <file>@, BEFORE the
-- caller invokes @helm upgrade --install@ for the release. No-op when
-- the inventory is empty (the release has no daemon-owned derived
-- Secrets). On master-seed read failure or kubectl-apply failure
-- returns 'Left' with the operator-facing detail.
preApplyDerivedSecretsForRelease :: String -> String -> IO (Either String ())
preApplyDerivedSecretsForRelease nsStr relStr =
  case derivedSecretInventoryFor namespace release of
    [] -> pure (Right ())
    entries -> do
      seedResult <- readHostMasterSeed
      case seedResult of
        Left err -> pure (Left err)
        Right seed -> applyEntriesViaKubectl seed namespace entries
 where
  namespace = Text.pack nsStr
  release = Text.pack relStr

-- | Read the master seed for host-side derivation. Honors the
-- @PRODBOX_TEST_HOST_MASTER_SEED_HEX@ test-only override
-- (Sprint 3.13 chunk 31) for the fake-env integration suite; falls
-- back to a real MinIO port-forward + S3 head/get otherwise.
readHostMasterSeed :: IO (Either String MasterSeed)
readHostMasterSeed = do
  overrideResult <- readHostMasterSeedHexOverride
  case overrideResult of
    Just result -> pure result
    Nothing -> resolveSeedViaMinio

readHostMasterSeedHexOverride :: IO (Maybe (Either String MasterSeed))
readHostMasterSeedHexOverride = do
  maybeHex <- lookupEnv "PRODBOX_TEST_HOST_MASTER_SEED_HEX"
  pure $ case maybeHex of
    Nothing -> Nothing
    Just hex ->
      case decodeHex hex of
        Left err -> Just (Left ("PRODBOX_TEST_HOST_MASTER_SEED_HEX: " ++ err))
        Right bytes ->
          case masterSeed bytes of
            Left err -> Just (Left ("PRODBOX_TEST_HOST_MASTER_SEED_HEX: " ++ err))
            Right seed -> Just (Right seed)

resolveSeedViaMinio :: IO (Either String MasterSeed)
resolveSeedViaMinio = do
  credsResult <- readGatewayMinioCredsViaKubectl
  case credsResult of
    Left err ->
      pure
        ( Left
            ( "could not resolve gateway-minio credentials for master-seed read: "
                ++ err
            )
        )
    Right (accessKey, secretKey) -> do
      portForwardResult <- withMinioPortForward $ \localPort -> do
        let cfg = defaultMinioMasterSeedConfig localPort accessKey secretKey
        ensureMasterSeed cfg
      case portForwardResult of
        Left err ->
          pure
            ( Left
                ( "could not port-forward to MinIO for master-seed read: "
                    ++ err
                )
            )
        Right (Left seedErr) ->
          pure (Left ("master-seed read failed: " ++ renderMasterSeedError seedErr))
        Right (Right seed) -> pure (Right seed)

-- | kubectl read of @gateway-minio-creds@. Mirrors
-- 'Prodbox.CLI.Rke2.readGatewayMinioCredsSecret' but lives here so this
-- module doesn't depend on CLI/.
readGatewayMinioCredsViaKubectl :: IO (Either String (String, String))
readGatewayMinioCredsViaKubectl = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "secret"
            , "gateway-minio-creds"
            , "-n"
            , "gateway"
            , "-o"
            , "go-template={{index .data \"minio.dhall\" | base64decode}}"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Failure err -> Left err
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "kubectl get secret gateway-minio-creds failed: "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess ->
          case extractMinioCredsFromDhall (processStdout output) of
            Nothing ->
              Left "gateway-minio-creds Dhall did not contain minio_access_key/minio_secret_key"
            Just creds -> Right creds

-- | Extract @(access_key, secret_key)@ from the chart-rendered Dhall
-- fragment shape @{ minio_access_key = \"<u>\", minio_secret_key = \"<p>\" }@.
extractMinioCredsFromDhall :: String -> Maybe (String, String)
extractMinioCredsFromDhall dhallText = do
  ak <- extractQuotedAfter "minio_access_key" dhallText
  sk <- extractQuotedAfter "minio_secret_key" dhallText
  pure (ak, sk)

extractQuotedAfter :: String -> String -> Maybe String
extractQuotedAfter key text =
  let matchedTails = filter (key `isPrefixOf`) (tails text)
   in case matchedTails of
        [] -> Nothing
        (tailing : _) ->
          let afterEq = dropWhile (/= '=') tailing
              afterQuoteOpen = dropWhile (/= '"') afterEq
              afterFirstQuote = drop 1 afterQuoteOpen
              quoted = takeWhile (/= '"') afterFirstQuote
           in if null quoted then Nothing else Just quoted

applyEntriesViaKubectl :: MasterSeed -> Text -> [DerivedSecretEntry] -> IO (Either String ())
applyEntriesViaKubectl seed namespace entries = do
  let manifests = map (entryToManifest seed namespace) entries
      payload = BL.intercalate "\n---\n" (map encode manifests)
  withTempManifestFile payload $ \tmpPath -> do
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "kubectl"
          , subprocessArguments = ["apply", "-f", tmpPath]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Nothing
          }
    pure $ case result of
      Failure err ->
        Left
          ( "kubectl apply failed for derived secrets in namespace `"
              ++ Text.unpack namespace
              ++ "`: "
              ++ err
          )
      Success output ->
        case processExitCode output of
          ExitSuccess -> Right ()
          ExitFailure _ ->
            Left
              ( "kubectl apply failed for derived secrets in namespace `"
                  ++ Text.unpack namespace
                  ++ "`: "
                  ++ processStderr output
                  ++ processStdout output
              )

entryToManifest :: MasterSeed -> Text -> DerivedSecretEntry -> Value
entryToManifest seed namespace entry =
  secretManifestJson
    namespace
    (derivedSecretEntryName entry)
    ( Map.fromList
        ( [(k, deriveBase64Url seed ctx) | (k, ctx) <- derivedSecretEntryDerivedFields entry]
            ++ derivedSecretEntryStaticFields entry
        )
    )

withTempManifestFile :: BL.ByteString -> (FilePath -> IO a) -> IO a
withTempManifestFile content action = do
  (tmpPath, handle) <- openBinaryTempFile "/tmp" "prodbox-host-bootstrap-.json"
  BL.hPut handle content
  hClose handle
  result <- action tmpPath
  _ <- try (removeFile tmpPath) :: IO (Either SomeException ())
  pure result

decodeHex :: String -> Either String BS.ByteString
decodeHex input
  | odd (length input) = Left "odd-length hex string"
  | not (all isHexDigit input) = Left "non-hex characters in input"
  | otherwise = Right (BS.pack (parsePairs input))
 where
  parsePairs [] = []
  parsePairs (a : b : rest) = byteFromPair a b : parsePairs rest
  parsePairs _ = []
  byteFromPair :: Char -> Char -> Word8
  byteFromPair a b = fromIntegral (hexValue a * 16 + hexValue b)
  hexValue c
    | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
    | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
    | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
    | otherwise = 0
