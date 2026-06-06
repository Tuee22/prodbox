{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.19: MinIO-backed read\/write for the gateway-owned master
-- seed.
--
-- The master seed (32 bytes) is the entropy source from which every
-- data-bound chart secret is derived via 'Prodbox.Secret.Derive'.
-- It lives at a fixed object path under the @prodbox@ MinIO bucket,
-- reachable only by the @prodbox-gateway@ MinIO user (see Sprint
-- 2.19's MinIO IAM bootstrap deliverable).
--
-- This module exposes:
--
--   * 'MinioMasterSeedConfig' — endpoint URL, bucket, key, and the
--     MinIO credentials required to read or write the seed.
--   * 'ensureMasterSeed' — the canonical read-or-create entrypoint
--     used by the gateway daemon at startup. Implements the
--     list-then-put concurrent-creation guard prescribed by the
--     doctrine: read the object first; on @NoSuchKey@ generate fresh
--     bytes from @\/dev\/urandom@ and PUT them with @If-None-Match: *@
--     so two concurrent first-start races resolve to a single winner.
--   * 'generateFreshSeedBytes' — pure-IO helper that reads 32 bytes
--     from @\/dev\/urandom@. Exposed for testability and for any
--     future call site that needs fresh entropy outside the
--     ensure-flow.
--
-- The implementation shells out to @aws s3api@ via
-- 'Prodbox.Service.runMinIOWithEnv', matching the existing pattern in
-- 'Prodbox.Infra.MinioBackend'. That avoids adding @amazonka-s3@ or
-- @minio-hs@ as a new dependency at this stage; the daemon already
-- ships the AWS CLI in its container image.
module Prodbox.Secret.MasterSeed
  ( MinioMasterSeedConfig (..)
  , minioMasterSeedConfigFromUrl
  , MasterSeedError (..)
  , masterSeedObjectKey
  , defaultMinioMasterSeedConfig
  , renderMasterSeedError
  , generateFreshSeedBytes
  , ensureMasterSeed

    -- ** Test seams
  , awsS3ApiHeadArgs
  , awsS3ApiPutArgs
  , awsS3ApiGetArgs
  , isAwsCliNoSuchKeyMessage
  , isAwsCliHeadObjectForbiddenMessage
  , isAwsCliPreconditionFailedMessage
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Infra.MinioBackend (minioAwsEnv, minioEndpointUrl)
import Prodbox.Secret.Derive
  ( MasterSeed
  , masterSeed
  )
import Prodbox.Service
  ( MinIOError
  , runMinIOWithEnv
  , serviceErrorMessage
  , toServiceError
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import System.IO
  ( IOMode (..)
  , hClose
  , openBinaryFile
  )

-- | Where to find the master seed in MinIO and how to authenticate.
-- The endpoint is resolved as @http:\/\/127.0.0.1:\<localPort\>@ via
-- 'minioEndpointUrl' so this record stays free of the
-- port-forward implementation detail.
data MinioMasterSeedConfig = MinioMasterSeedConfig
  { minioMasterSeedEndpoint :: !String
  -- ^ Full @http:\/\/host:port@ URL of the in-pod MinIO listener.
  , minioMasterSeedBucket :: !String
  -- ^ Bucket name. Doctrine pins this to @prodbox@.
  , minioMasterSeedKey :: !String
  -- ^ Object key. Doctrine pins this to @master-seed@.
  , minioMasterSeedAccessKey :: !String
  , minioMasterSeedSecretKey :: !String
  }
  deriving (Eq, Show)

-- | Canonical object key under the @prodbox@ bucket. Pinned so every
-- daemon instance and every test fixture agrees on the storage
-- coordinate.
masterSeedObjectKey :: String
masterSeedObjectKey = "master-seed"

-- | Canonical 'MinioMasterSeedConfig' for the in-pod gateway daemon.
-- The @localPort@ argument lets test fixtures or alternate deployments
-- override the MinIO local port; production callers pass the in-pod
-- port the daemon resolves at startup.
defaultMinioMasterSeedConfig
  :: Int
  -> String
  -- ^ MinIO access key id.
  -> String
  -- ^ MinIO secret access key.
  -> MinioMasterSeedConfig
defaultMinioMasterSeedConfig localPort accessKey secretKey =
  MinioMasterSeedConfig
    { minioMasterSeedEndpoint = minioEndpointUrl localPort
    , minioMasterSeedBucket = "prodbox"
    , minioMasterSeedKey = masterSeedObjectKey
    , minioMasterSeedAccessKey = accessKey
    , minioMasterSeedSecretKey = secretKey
    }

-- | Sprint 2.19: build a 'MinioMasterSeedConfig' from a fully-qualified
-- endpoint URL string. Used by the gateway daemon when
-- @boot.minio_endpoint_url@ is bound in the mounted Dhall config, so the
-- in-cluster MinIO Service DNS (rather than @127.0.0.1:\<port\>@) drives
-- master-seed acquisition. The bucket and key remain pinned to the
-- doctrine values.
minioMasterSeedConfigFromUrl
  :: String
  -- ^ Full @http(s):\/\/host:port@ URL of the MinIO endpoint.
  -> String
  -- ^ MinIO access key id.
  -> String
  -- ^ MinIO secret access key.
  -> MinioMasterSeedConfig
minioMasterSeedConfigFromUrl endpoint accessKey secretKey =
  MinioMasterSeedConfig
    { minioMasterSeedEndpoint = endpoint
    , minioMasterSeedBucket = "prodbox"
    , minioMasterSeedKey = masterSeedObjectKey
    , minioMasterSeedAccessKey = accessKey
    , minioMasterSeedSecretKey = secretKey
    }

-- | Structured failure modes for the read-or-create flow. Each
-- constructor carries the operator-visible detail; doctrine §8
-- prescribes that the gateway daemon translates these into the
-- canonical structured 503 response shape, so the rendering here is
-- intentionally human-readable rather than wire-shaped.
data MasterSeedError
  = -- | @\/dev\/urandom@ read failed. The 'String' carries the IO
    -- exception message.
    MasterSeedEntropyUnavailable !String
  | -- | The seed bytes returned from MinIO did not pass the 32-byte
    -- size check from 'Prodbox.Secret.Derive.masterSeed'. The
    -- 'String' carries the validator message.
    MasterSeedInvalidSize !String
  | -- | The @aws s3api@ subprocess failed at the system level (fork
    -- error, missing binary, etc.).
    MasterSeedSubprocessFailed !String
  | -- | @aws s3api get-object@ failed with an exit code other than
    -- @NoSuchKey@. The 'String' carries the combined stderr \/ stdout.
    MasterSeedGetFailed !String
  | -- | @aws s3api put-object@ failed. The 'String' carries the
    -- combined stderr \/ stdout.
    MasterSeedPutFailed !String
  | -- | Failure to read or write the temporary file the @--body@ /
    -- @get-object@ arguments need.
    MasterSeedFileIoFailed !String
  deriving (Eq, Show)

renderMasterSeedError :: MasterSeedError -> String
renderMasterSeedError err = case err of
  MasterSeedEntropyUnavailable detail ->
    "master seed entropy source unavailable: " ++ detail
  MasterSeedInvalidSize detail ->
    "master seed validator rejected MinIO payload: " ++ detail
  MasterSeedSubprocessFailed detail ->
    "failed to start `aws s3api`: " ++ detail
  MasterSeedGetFailed detail ->
    "`aws s3api get-object` failed: " ++ detail
  MasterSeedPutFailed detail ->
    "`aws s3api put-object` failed: " ++ detail
  MasterSeedFileIoFailed detail ->
    "master seed temporary file IO failed: " ++ detail

-- | Read 32 bytes from @\/dev\/urandom@. Returns
-- 'MasterSeedEntropyUnavailable' on any IO exception so callers do
-- not have to catch around it themselves.
generateFreshSeedBytes :: IO (Either MasterSeedError ByteString)
generateFreshSeedBytes = do
  result <- try $ do
    handle <- openBinaryFile "/dev/urandom" ReadMode
    bytes <- BS.hGet handle 32
    hClose handle
    pure bytes
  case result of
    Left (ioErr :: IOException) ->
      pure (Left (MasterSeedEntropyUnavailable (show ioErr)))
    Right bytes
      | BS.length bytes == 32 -> pure (Right bytes)
      | otherwise ->
          pure
            ( Left
                ( MasterSeedEntropyUnavailable
                    ("/dev/urandom returned " ++ show (BS.length bytes) ++ " bytes, expected 32")
                )
            )

-- | Build the canonical @aws s3api head-object@ argument vector for
-- the configured master-seed coordinates. Pure so the test suite can
-- pin the wire shape.
awsS3ApiHeadArgs :: MinioMasterSeedConfig -> [String]
awsS3ApiHeadArgs config =
  [ "--endpoint-url"
  , minioMasterSeedEndpoint config
  , "s3api"
  , "head-object"
  , "--bucket"
  , minioMasterSeedBucket config
  , "--key"
  , minioMasterSeedKey config
  ]

-- | Build the canonical @aws s3api get-object@ argument vector for
-- the configured master-seed coordinates and an output @--body@ path.
-- Pure so the test suite can pin the wire shape.
awsS3ApiGetArgs :: MinioMasterSeedConfig -> FilePath -> [String]
awsS3ApiGetArgs config outputPath =
  [ "--endpoint-url"
  , minioMasterSeedEndpoint config
  , "s3api"
  , "get-object"
  , "--bucket"
  , minioMasterSeedBucket config
  , "--key"
  , minioMasterSeedKey config
  , outputPath
  ]

-- | Build the canonical @aws s3api put-object@ argument vector for
-- the configured master-seed coordinates, an input @--body@ path,
-- and the conditional @--if-none-match@ guard. The @*@ value asks
-- MinIO to refuse the PUT if any object already exists at the key,
-- so two concurrent first-start races resolve to a single winner.
-- Pure so the test suite can pin the wire shape.
awsS3ApiPutArgs :: MinioMasterSeedConfig -> FilePath -> [String]
awsS3ApiPutArgs config bodyPath =
  [ "--endpoint-url"
  , minioMasterSeedEndpoint config
  , "s3api"
  , "put-object"
  , "--bucket"
  , minioMasterSeedBucket config
  , "--key"
  , minioMasterSeedKey config
  , "--body"
  , bodyPath
  , "--if-none-match"
  , "*"
  ]

-- | True when the AWS CLI error blob describes a @NoSuchKey@ result.
-- The CLI prints these as e.g.
-- @"An error occurred (NoSuchKey) when calling the HeadObject
-- operation: Not Found"@. Pure so the test suite can pin recognition
-- without forcing a live MinIO round-trip.
isAwsCliNoSuchKeyMessage :: String -> Bool
isAwsCliNoSuchKeyMessage message =
  "NoSuchKey" `isInfixOf` message || "Not Found" `isInfixOf` message

-- | Some S3-compatible servers surface a first-read @HeadObject@ miss
-- as @403 Forbidden@ rather than @NoSuchKey@ when the caller has the
-- object-level permissions needed for the guarded first write but the
-- server declines to reveal object absence. Treat only the @HeadObject@
-- shape as absent; real credential or policy failures still fail during
-- the subsequent guarded @PutObject@ or authoritative @GetObject@.
isAwsCliHeadObjectForbiddenMessage :: String -> Bool
isAwsCliHeadObjectForbiddenMessage message =
  "HeadObject" `isInfixOf` message
    && ( "Forbidden" `isInfixOf` message
           || "403" `isInfixOf` message
       )

-- | Read the master seed from MinIO if it exists; otherwise generate
-- 32 fresh bytes and PUT them under @If-None-Match: *@. The PUT can
-- race against another daemon's first-start; the post-PUT GET
-- re-reads whatever the bucket holds and returns those bytes so all
-- racing callers converge to one master seed.
--
-- This is the canonical entrypoint the gateway daemon invokes at
-- startup. It is idempotent: subsequent calls return the same
-- 'MasterSeed' value.
ensureMasterSeed :: MinioMasterSeedConfig -> IO (Either MasterSeedError MasterSeed)
ensureMasterSeed config = do
  presentResult <- runHead config
  case presentResult of
    Left err -> pure (Left err)
    Right Present -> readSeedBytes config
    Right Absent -> do
      freshResult <- generateFreshSeedBytes
      case freshResult of
        Left err -> pure (Left err)
        Right freshBytes -> do
          putResult <- runPut config freshBytes
          case putResult of
            Left err -> pure (Left err)
            -- Always re-read after a PUT — even when we believed the
            -- PUT succeeded, another daemon may have raced us under
            -- the If-None-Match guard. The bucket's authoritative
            -- value is what every daemon must agree on.
            Right () -> readSeedBytes config

-- | Did the bucket contain the master-seed object when we last looked?
data SeedPresence = Present | Absent
  deriving (Eq, Show)

runHead :: MinioMasterSeedConfig -> IO (Either MasterSeedError SeedPresence)
runHead config = do
  let environment =
        minioAwsEnv
          (minioMasterSeedAccessKey config)
          (minioMasterSeedSecretKey config)
      args = awsS3ApiHeadArgs config
  result <- runMinIOWithEnv (Just environment) args
  case result of
    Left err -> pure (Left (MasterSeedSubprocessFailed (renderMinIOError err)))
    Right output ->
      case processExitCode output of
        ExitSuccess -> pure (Right Present)
        ExitFailure _ ->
          let stderrTxt = processStderr output
              stdoutTxt = processStdout output
              combined = stderrTxt ++ "\n" ++ stdoutTxt
           in if isAwsCliNoSuchKeyMessage combined
                || isAwsCliHeadObjectForbiddenMessage combined
                then pure (Right Absent)
                else pure (Left (MasterSeedGetFailed (trim combined)))

readSeedBytes :: MinioMasterSeedConfig -> IO (Either MasterSeedError MasterSeed)
readSeedBytes config = do
  -- The AWS CLI's get-object writes the body to a file path argument.
  -- We round-trip through a fixed temporary file under /tmp; the
  -- caller should hold this entire flow inside a bracket that wipes
  -- the file. Today the daemon's startup path is the only caller, so
  -- the file lives only as long as the startup decoding step.
  let tmpPath = "/tmp/prodbox-master-seed.bin"
      environment =
        minioAwsEnv
          (minioMasterSeedAccessKey config)
          (minioMasterSeedSecretKey config)
      args = awsS3ApiGetArgs config tmpPath
  result <- runMinIOWithEnv (Just environment) args
  case result of
    Left err -> pure (Left (MasterSeedSubprocessFailed (renderMinIOError err)))
    Right output ->
      case processExitCode output of
        ExitFailure _ ->
          pure
            ( Left
                ( MasterSeedGetFailed
                    (trim (processStderr output ++ "\n" ++ processStdout output))
                )
            )
        ExitSuccess -> do
          readResult <- try (BS.readFile tmpPath)
          case readResult of
            Left (ioErr :: IOException) ->
              pure (Left (MasterSeedFileIoFailed (show ioErr)))
            Right bytes -> case masterSeed bytes of
              Left detail -> pure (Left (MasterSeedInvalidSize detail))
              Right seed -> pure (Right seed)

runPut :: MinioMasterSeedConfig -> ByteString -> IO (Either MasterSeedError ())
runPut config bodyBytes = do
  -- Write the body to a temp file because aws s3api put-object reads
  -- the body from a path argument, not from stdin.
  let tmpPath = "/tmp/prodbox-master-seed-put.bin"
      environment =
        minioAwsEnv
          (minioMasterSeedAccessKey config)
          (minioMasterSeedSecretKey config)
      args = awsS3ApiPutArgs config tmpPath
  writeResult <- try (BS.writeFile tmpPath bodyBytes)
  case writeResult of
    Left (ioErr :: IOException) ->
      pure (Left (MasterSeedFileIoFailed (show ioErr)))
    Right () -> do
      result <- runMinIOWithEnv (Just environment) args
      case result of
        Left err -> pure (Left (MasterSeedSubprocessFailed (renderMinIOError err)))
        Right output ->
          case processExitCode output of
            ExitSuccess -> pure (Right ())
            ExitFailure _ ->
              let stderrTxt = processStderr output
                  stdoutTxt = processStdout output
                  combined = stderrTxt ++ "\n" ++ stdoutTxt
               in -- A concurrent first-start race surfaces here as a
                  -- 412 PreconditionFailed / "At least one of the
                  -- pre-conditions you specified did not hold". That
                  -- is success for our purposes — the bucket now
                  -- holds a seed, and the post-PUT GET will read it.
                  if isAwsCliPreconditionFailedMessage combined
                    then pure (Right ())
                    else pure (Left (MasterSeedPutFailed (trim combined)))

-- | True when the AWS CLI error blob describes a 412
-- PreconditionFailed (the @If-None-Match: *@ guard fired). Exported
-- via the @-- ** Test seams@ block above for unit-test visibility.
-- Recognises both the structured @PreconditionFailed@ error code
-- name, the long-form @pre-conditions@ blob the S3 SDK emits
-- (\"At least one of the pre-conditions you specified did not
-- hold\"), and any message mentioning the @If-None-Match@ header
-- explicitly.
isAwsCliPreconditionFailedMessage :: String -> Bool
isAwsCliPreconditionFailedMessage message =
  "PreconditionFailed" `isInfixOf` message
    || "pre-condition" `isInfixOf` message
    || "If-None-Match" `isInfixOf` message

renderMinIOError :: MinIOError -> String
renderMinIOError = Text.unpack . serviceErrorMessage . toServiceError

trim :: String -> String
trim = reverse . dropWhile isWs . reverse . dropWhile isWs
 where
  isWs c = c == '\n' || c == '\r' || c == ' ' || c == '\t'
