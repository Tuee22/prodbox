{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.10: dedicated S3 backend for long-lived Pulumi state.
--
-- Per-substrate Pulumi stacks (@aws-eks@, @aws-eks-subzone@,
-- @aws-test@) live in the in-cluster MinIO backend; the @aws-ses@
-- stack and any other cross-substrate long-lived stack live in a
-- dedicated operator-account S3 bucket so the state survives
-- @rke2 delete + rke2 reconcile@ cycles and operator-machine churn.
--
-- The state-lifetime rule from
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 2@
-- becomes the implemented behaviour: state lifetime matches resource
-- lifetime per class.
module Prodbox.Infra.LongLivedPulumiBackend
  ( LongLivedBackendError (..)
  , adminCredentialsConfigured
  , longLivedBackendErrorMessage
  , loadAdminAwsCredentials
  , longLivedPulumiBackendUrl
  , longLivedPulumiBackendUrlEither
  , ensureLongLivedPulumiStateBucket
  , destroyLongLivedPulumiStateBucket
  , renderDeletePayload
  , withLongLivedPulumiBackendEnv

    -- * Sprint 4.24: object-level access for the retained public-edge TLS cert
  , listLongLivedObjectKeysUnderPrefix
  , purgeLongLivedObjectsUnderPrefix
  , parseObjectKeysPayload

    -- * Sprint 7.11: single-object put/get for the substrate-scoped cert retention store
  , putLongLivedObject
  , getLongLivedObject
  , renderLongLivedObjectVaultGateBlock
  , isLongLivedNoSuchKeyMessage
  , resolveLongLivedAdminS3Context
  )
where

import Control.Exception (bracket_)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Aws.AdminCredentials (acquireAdminAwsCredentials)
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ConfigFile (..)
  , Credentials (..)
  , PulumiStateBackendSection (..)
  , loadConfigFile
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Vault.Client (vaultSealStatus)
import Prodbox.Vault.Gate
  ( VaultGateDecision (..)
  , vaultGateAllows
  , vaultGateDecision
  )
import Prodbox.Vault.Host (resolveHostVaultAddress)
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))

-- | Errors returned by long-lived backend operations. Distinct
-- constructors so callers can produce structured error rendering at
-- the CLI boundary instead of pattern-matching on raw text.
data LongLivedBackendError
  = BackendNotConfigured
  | BackendBucketNameEmpty
  | BackendRegionEmpty
  | BucketEnsureFailed String
  deriving (Eq, Show)

longLivedBackendErrorMessage :: LongLivedBackendError -> String
longLivedBackendErrorMessage err = case err of
  BackendNotConfigured ->
    "pulumi_state_backend is not configured. Set pulumi_state_backend.bucket_name and \
    \pulumi_state_backend.region in prodbox.dhall, then run \
    \`prodbox aws stack aws-ses migrate-backend` to migrate existing state from the \
    \in-cluster MinIO backend onto the dedicated long-lived S3 bucket."
  BackendBucketNameEmpty ->
    "pulumi_state_backend.bucket_name must not be empty for long-lived stacks."
  BackendRegionEmpty ->
    "pulumi_state_backend.region must not be empty for long-lived stacks."
  BucketEnsureFailed detail ->
    "failed to ensure long-lived Pulumi state bucket: " ++ detail

-- | Sprint 7.16: acquire the EPHEMERAL admin AWS credential. This is the
-- canonical loader every long-lived / teardown consumer calls. It delegates
-- to 'Prodbox.Aws.AdminCredentials.acquireAdminAwsCredentials', which runs the
-- doctrine cascade: a populated @aws_admin_for_test_simulation@ block in
-- @test-secrets.dhall@ (the harness simulating the prompt) → an interactive TTY
-- prompt for a temporary admin key → fail loud. The admin credential is never
-- read from @prodbox.dhall@ or Vault.
--
-- Long-lived stack operations (`prodbox aws stack aws-ses reconcile`,
-- `prodbox aws stack aws-ses destroy`) and `prodbox nuke` authenticate with
-- this ephemeral admin credential rather than the operational @aws.*@ block,
-- so the operational @prodbox@ IAM user does not need @s3:GetObject@ /
-- @PutObject@ on the long-lived state bucket.
loadAdminAwsCredentials :: FilePath -> IO (Either String Credentials)
loadAdminAwsCredentials repoRoot = do
  credentialsResult <- acquireAdminAwsCredentials repoRoot
  pure $ case credentialsResult of
    Left err ->
      Left
        ( "an ephemeral admin AWS credential is required before long-lived \
          \stack operations (`prodbox aws stack aws-ses reconcile`, \
          \`aws-ses-destroy`, `aws-ses-migrate-backend`) or `prodbox nuke` \
          \can authenticate: "
            ++ err
        )
    Right creds ->
      if adminCredentialsConfigured creds
        then Right creds
        else
          Left
            "the acquired admin AWS credential must have a non-empty access \
            \key id, secret access key, and region before long-lived stack \
            \operations (`prodbox aws stack aws-ses reconcile`, \
            \`aws-ses-destroy`, `aws-ses-migrate-backend`) or `prodbox nuke` \
            \can authenticate."

adminCredentialsConfigured :: Credentials -> Bool
adminCredentialsConfigured creds =
  not (Text.null (Text.strip (access_key_id creds)))
    && not (Text.null (Text.strip (secret_access_key creds)))
    && not (Text.null (Text.strip (region creds)))

-- | Render the Pulumi backend URL for the configured long-lived S3
-- bucket, or 'Nothing' when no backend is configured (operator has
-- not yet provisioned the long-lived bucket and is still on the MinIO
-- backend for everything).
longLivedPulumiBackendUrl :: PulumiStateBackendSection -> Maybe String
longLivedPulumiBackendUrl section =
  let bucket = Text.strip (psbBucketName section)
      regionValue = Text.strip (psbRegion section)
      keyPrefix = Text.strip (psbKeyPrefix section)
   in if Text.null bucket || Text.null regionValue
        then Nothing
        else
          Just
            ( "s3://"
                ++ Text.unpack bucket
                ++ "?region="
                ++ Text.unpack regionValue
                ++ "&awssdk=v2"
                ++ ( if Text.null keyPrefix
                       then ""
                       else "&prefix=" ++ Text.unpack keyPrefix
                   )
            )

longLivedPulumiBackendUrlEither
  :: PulumiStateBackendSection -> Either LongLivedBackendError String
longLivedPulumiBackendUrlEither section
  | Text.null (Text.strip (psbBucketName section)) = Left BackendBucketNameEmpty
  | Text.null (Text.strip (psbRegion section)) = Left BackendRegionEmpty
  | otherwise = case longLivedPulumiBackendUrl section of
      Just url -> Right url
      Nothing -> Left BackendNotConfigured

-- | Idempotent: head-bucket, on miss create with versioning,
-- AES256 SSE, block-public-access, the prodbox tags, and a 90-day
-- non-current-version expiration lifecycle rule. Returns 'Right ()'
-- when the bucket is present (after this call) and reachable.
--
-- The implementation issues @aws s3api@ subprocesses authenticated by
-- the supplied environment. Long-lived backend operations consume
-- admin credentials (`aws_admin_for_test_simulation.*`) rather than
-- the operational @aws.*@ block, so the operational @prodbox@ IAM
-- user does not need @s3:GetObject@/@PutObject@ on the state bucket.
ensureLongLivedPulumiStateBucket
  :: FilePath
  -- ^ Working directory for the @aws@ subprocesses (the repo root
  -- works; this only matters for credential file discovery when the
  -- environment is sparse).
  -> [(String, String)]
  -- ^ Environment for @aws@ subprocesses (must carry
  -- @AWS_ACCESS_KEY_ID@, @AWS_SECRET_ACCESS_KEY@, optionally
  -- @AWS_SESSION_TOKEN@, and @AWS_REGION@/@AWS_DEFAULT_REGION@).
  -> PulumiStateBackendSection
  -> IO (Either LongLivedBackendError ())
ensureLongLivedPulumiStateBucket workingDir environment section = case longLivedPulumiBackendUrlEither section of
  Left err -> pure (Left err)
  Right _url -> do
    let bucket = Text.unpack (Text.strip (psbBucketName section))
        regionValue = Text.unpack (Text.strip (psbRegion section))
    headResult <- runAwsS3Api workingDir environment ["head-bucket", "--bucket", bucket]
    case headResult of
      Right () -> pure (Right ())
      Left _ -> do
        createExit <-
          runAwsS3Api
            workingDir
            environment
            [ "create-bucket"
            , "--bucket"
            , bucket
            , "--region"
            , regionValue
            , "--create-bucket-configuration"
            , "LocationConstraint=" ++ regionValue
            ]
        case createExit of
          Left err -> pure (Left (BucketEnsureFailed err))
          Right () -> do
            postSetupExit <- configureBucketPostCreate workingDir environment bucket
            pure $ case postSetupExit of
              Left err -> Left (BucketEnsureFailed err)
              Right () -> Right ()

configureBucketPostCreate
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String ())
configureBucketPostCreate workingDir environment bucket = do
  versioningExit <-
    runAwsS3Api
      workingDir
      environment
      [ "put-bucket-versioning"
      , "--bucket"
      , bucket
      , "--versioning-configuration"
      , "Status=Enabled"
      ]
  case versioningExit of
    Left err -> pure (Left ("put-bucket-versioning failed: " ++ err))
    Right () -> do
      encryptionExit <-
        runAwsS3Api
          workingDir
          environment
          [ "put-bucket-encryption"
          , "--bucket"
          , bucket
          , "--server-side-encryption-configuration"
          , "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":\
            \{\"SSEAlgorithm\":\"AES256\"}}]}"
          ]
      case encryptionExit of
        Left err -> pure (Left ("put-bucket-encryption failed: " ++ err))
        Right () -> do
          publicAccessExit <-
            runAwsS3Api
              workingDir
              environment
              [ "put-public-access-block"
              , "--bucket"
              , bucket
              , "--public-access-block-configuration"
              , "BlockPublicAcls=true,IgnorePublicAcls=true,\
                \BlockPublicPolicy=true,RestrictPublicBuckets=true"
              ]
          case publicAccessExit of
            Left err -> pure (Left ("put-public-access-block failed: " ++ err))
            Right () -> do
              tagsExit <-
                runAwsS3Api
                  workingDir
                  environment
                  [ "put-bucket-tagging"
                  , "--bucket"
                  , bucket
                  , "--tagging"
                  , "TagSet=[\
                    \{Key=prodbox.io/managed-by,Value=prodbox},\
                    \{Key=prodbox.io/role,Value=long-lived-pulumi-state}\
                    \]"
                  ]
              case tagsExit of
                Left err -> pure (Left ("put-bucket-tagging failed: " ++ err))
                Right () ->
                  runAwsS3Api
                    workingDir
                    environment
                    [ "put-bucket-lifecycle-configuration"
                    , "--bucket"
                    , bucket
                    , "--lifecycle-configuration"
                    , "{\"Rules\":[{\
                      \\"ID\":\"prodbox-noncurrent-90d-expiry\",\
                      \\"Status\":\"Enabled\",\
                      \\"Filter\":{\"Prefix\":\"\"},\
                      \\"NoncurrentVersionExpiration\":\
                      \{\"NoncurrentDays\":90}}]}"
                    ]

runAwsS3Api
  :: FilePath -> [(String, String)] -> [String] -> IO (Either String ())
runAwsS3Api workingDir environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = "s3api" : arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err -> Left ("failed to start `aws s3api`: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure code ->
        Left
          ( "`aws s3api "
              ++ unwords arguments
              ++ "` exited with code "
              ++ show code
              ++ ": "
              ++ processStderr output
              ++ processStdout output
          )

-- | Sprint 4.13: total-teardown helper used by `prodbox nuke` to
-- destroy the long-lived Pulumi state bucket. Idempotent:
-- @head-bucket@ → empty all object versions (delete-markers + current
-- + non-current) → @delete-bucket@. Returns 'Right ()' when the
-- bucket is absent after this call.
--
-- The bucket is the operator-account-owned long-lived
-- @pulumi_state_backend@ S3 bucket. After this destroy completes,
-- AWS imposes a ~24-hour name cooldown before the bucket name can be
-- reused, so this is **last-step in the nuke sequence** — every
-- earlier nuke step that needs Pulumi state must complete first.
destroyLongLivedPulumiStateBucket
  :: FilePath
  -- ^ Working directory for the @aws@ subprocesses.
  -> [(String, String)]
  -- ^ Environment for @aws@ subprocesses (admin AWS creds).
  -> PulumiStateBackendSection
  -> IO (Either LongLivedBackendError ())
destroyLongLivedPulumiStateBucket workingDir environment section = case longLivedPulumiBackendUrlEither section of
  Left err -> pure (Left err)
  Right _url -> do
    let bucket = Text.unpack (Text.strip (psbBucketName section))
    headResult <- runAwsS3Api workingDir environment ["head-bucket", "--bucket", bucket]
    case headResult of
      Left _ -> pure (Right ())
      Right () -> do
        emptyResult <- emptyVersionedBucket workingDir environment bucket
        case emptyResult of
          Left err -> pure (Left (BucketEnsureFailed err))
          Right () -> do
            deleteExit <-
              runAwsS3Api workingDir environment ["delete-bucket", "--bucket", bucket]
            pure $ case deleteExit of
              Left err -> Left (BucketEnsureFailed ("delete-bucket failed: " ++ err))
              Right () -> Right ()

emptyVersionedBucket
  :: FilePath -> [(String, String)] -> String -> IO (Either String ())
emptyVersionedBucket workingDir environment bucket = do
  -- `aws s3 rm s3://<bucket> --recursive` only removes current
  -- versions; for a versioned bucket we additionally need to delete
  -- every version + delete marker, which the `aws s3api` recursive
  -- removal does not handle. The bucket was created with versioning
  -- enabled (see `ensureLongLivedPulumiStateBucket`), so use the
  -- versioned-aware loop.
  rmResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "s3"
            , "rm"
            , "s3://" ++ bucket
            , "--recursive"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  case rmResult of
    Failure err -> pure (Left ("failed to start `aws s3 rm`: " ++ err))
    Success output ->
      case processExitCode output of
        ExitFailure code ->
          pure
            ( Left
                ( "`aws s3 rm s3://"
                    ++ bucket
                    ++ " --recursive` exited with code "
                    ++ show code
                    ++ ": "
                    ++ processStderr output
                )
            )
        ExitSuccess ->
          purgeRemainingVersions workingDir environment bucket Nothing

-- | Purge every remaining object version and delete-marker in the
-- versioned bucket (optionally restricted to a key prefix). Lists
-- versions through @aws s3api list-object-versions@, parses the JSON
-- in-process, builds the @delete@ payload, and calls @aws s3api
-- delete-objects@. Iterates to drain truncated pages. Idempotent —
-- does nothing when the bucket has no remaining versions under the
-- (optional) prefix.
purgeRemainingVersions
  :: FilePath -> [(String, String)] -> String -> Maybe String -> IO (Either String ())
purgeRemainingVersions workingDir environment bucket prefix = go
 where
  go :: IO (Either String ())
  go = do
    listResult <- listVersionsPage workingDir environment bucket prefix
    case listResult of
      Left err -> pure (Left err)
      Right [] -> pure (Right ())
      Right entries -> do
        deleteResult <- deleteVersionsBatch workingDir environment bucket entries
        case deleteResult of
          Left err -> pure (Left err)
          Right () -> go

-- | One bucket-version listing entry. The pair @(key, versionId)@ is
-- the canonical input to @aws s3api delete-objects@.
type BucketVersion = (String, String)

listVersionsPage
  :: FilePath
  -> [(String, String)]
  -> String
  -> Maybe String
  -> IO (Either String [BucketVersion])
listVersionsPage workingDir environment bucket prefix = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "s3api"
            , "list-object-versions"
            , "--bucket"
            , bucket
            , "--max-items"
            , "1000"
            , "--output"
            , "json"
            ]
              ++ maybe [] (\p -> ["--prefix", p]) prefix
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err -> Left ("failed to start `aws s3api list-object-versions`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure code ->
          Left
            ( "list-object-versions on `"
                ++ bucket
                ++ "` exited with code "
                ++ show code
                ++ ": "
                ++ processStderr output
            )
        ExitSuccess -> parseVersionsPayload (processStdout output)

parseVersionsPayload :: String -> Either String [BucketVersion]
parseVersionsPayload payload = do
  value <-
    eitherDecode (BL8.pack payload)
      :: Either String Value
  case value of
    Object obj ->
      Right (extract "Versions" obj ++ extract "DeleteMarkers" obj)
    _ -> Right []
 where
  extract :: String -> KeyMap.KeyMap Value -> [BucketVersion]
  extract fieldName obj = case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (Array entries) -> concatMap entryToVersion (vectorToList entries)
    _ -> []
  entryToVersion :: Value -> [BucketVersion]
  entryToVersion (Object entry) = case (KeyMap.lookup (Key.fromString "Key") entry, KeyMap.lookup (Key.fromString "VersionId") entry) of
    (Just (String keyText), Just (String versionText)) ->
      [(Text.unpack keyText, Text.unpack versionText)]
    _ -> []
  entryToVersion _ = []
  -- Array is a Vector; avoid pulling in Data.Vector by treating it
  -- through the Foldable instance.
  vectorToList :: (Foldable t) => t a -> [a]
  vectorToList = foldr (:) []

deleteVersionsBatch
  :: FilePath
  -> [(String, String)]
  -> String
  -> [BucketVersion]
  -> IO (Either String ())
deleteVersionsBatch workingDir environment bucket entries = do
  let deletePayload = renderDeletePayload entries
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "s3api"
            , "delete-objects"
            , "--bucket"
            , bucket
            , "--delete"
            , deletePayload
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just workingDir
        }
  pure $ case result of
    Failure err -> Left ("failed to start `aws s3api delete-objects`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure code ->
          Left
            ( "delete-objects on `"
                ++ bucket
                ++ "` exited with code "
                ++ show code
                ++ ": "
                ++ processStderr output
            )

-- | Build the @--delete@ JSON payload that @aws s3api delete-objects@
-- expects. Public so the unit suite can pin the shape without forcing
-- a live S3 round-trip.
renderDeletePayload :: [BucketVersion] -> String
renderDeletePayload entries =
  let objectField (key, versionId) =
        object
          [ Key.fromString "Key" .= key
          , Key.fromString "VersionId" .= versionId
          ]
      payload = object [Key.fromString "Objects" .= map objectField entries]
   in BL8.unpack (encode payload)

-- | Sprint 4.24: list the object keys under a prefix in the long-lived
-- @pulumi_state_backend@ bucket. Used by the retained public-edge TLS
-- certificate managed resource's @discover@ to decide present vs absent.
-- Returns @Right keys@ on success (empty list when nothing matches),
-- and @Left detail@ on failure. A @NoSuchBucket@ failure surfaces in
-- @detail@ so the caller can treat a deleted long-lived backend as the
-- authoritative "nothing retained" state via
-- 'Prodbox.Lifecycle.LiveResidue.isMissingStateBackendBucketMessage'.
listLongLivedObjectKeysUnderPrefix
  :: FilePath
  -> [(String, String)]
  -> PulumiStateBackendSection
  -> String
  -> IO (Either String [String])
listLongLivedObjectKeysUnderPrefix workingDir environment section prefix =
  case longLivedPulumiBackendUrlEither section of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right _url -> do
      let bucket = Text.unpack (Text.strip (psbBucketName section))
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                [ "s3api"
                , "list-objects-v2"
                , "--bucket"
                , bucket
                , "--prefix"
                , prefix
                , "--query"
                , "Contents[].Key"
                , "--output"
                , "json"
                ]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just workingDir
            }
      pure $ case result of
        Failure err -> Left ("failed to start `aws s3api list-objects-v2`: " ++ err)
        Success output -> case processExitCode output of
          ExitSuccess -> parseObjectKeysPayload (processStdout output)
          ExitFailure code ->
            Left
              ( "`aws s3api list-objects-v2 --bucket "
                  ++ bucket
                  ++ " --prefix "
                  ++ prefix
                  ++ "` exited with code "
                  ++ show code
                  ++ ": "
                  ++ processStderr output
                  ++ processStdout output
              )

-- | Parse the JSON emitted by @aws s3api list-objects-v2 --query
-- 'Contents[].Key' --output json@: a JSON array of key strings, or
-- @null@ \/ an empty array when nothing matches the prefix. Public so
-- the unit suite can pin the shape without a live S3 round-trip.
parseObjectKeysPayload :: String -> Either String [String]
parseObjectKeysPayload payload =
  case eitherDecode (BL8.pack payload) :: Either String Value of
    Left err -> Left ("failed to decode list-objects-v2 payload: " ++ err)
    Right Null -> Right []
    Right (Array entries) ->
      Right [Text.unpack keyText | String keyText <- foldr (:) [] entries]
    Right _ -> Right []

-- | Sprint 4.24: purge every object version and delete-marker under a
-- key prefix in the long-lived @pulumi_state_backend@ bucket. The
-- @destroy@ action for the retained public-edge TLS certificate managed
-- resource. Idempotent: a missing bucket (long-lived backend already
-- gone) returns 'Right ()', and an empty prefix is a no-op.
purgeLongLivedObjectsUnderPrefix
  :: FilePath
  -> [(String, String)]
  -> PulumiStateBackendSection
  -> String
  -> IO (Either String ())
purgeLongLivedObjectsUnderPrefix workingDir environment section prefix =
  case longLivedPulumiBackendUrlEither section of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right _url -> do
      let bucket = Text.unpack (Text.strip (psbBucketName section))
      headResult <- runAwsS3Api workingDir environment ["head-bucket", "--bucket", bucket]
      case headResult of
        Left _ -> pure (Right ())
        Right () -> purgeRemainingVersions workingDir environment bucket (Just prefix)

-- | Sprint 7.11: write a local file to a key in the long-lived
-- @pulumi_state_backend@ bucket — the @store@ half of the
-- substrate-scoped public-edge production-certificate retention path.
-- @aws s3api put-object@ reads the body from a file path, so callers
-- materialize the cert bytes to a temp file first. Idempotent: a put
-- overwrites the prior version (the bucket is versioned).
putLongLivedObject
  :: FilePath
  -> [(String, String)]
  -> PulumiStateBackendSection
  -> String
  -- ^ Object key, e.g. @public-edge-tls/\<substrate\>/\<fqdn\>@.
  -> FilePath
  -- ^ Local body file to upload.
  -> IO (Either String ())
putLongLivedObject workingDir environment section key bodyPath =
  case longLivedPulumiBackendUrlEither section of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right _url -> do
      let bucket = Text.unpack (Text.strip (psbBucketName section))
      runAwsS3Api
        workingDir
        environment
        ["put-object", "--bucket", bucket, "--key", key, "--body", bodyPath]

-- | Sprint 7.11: read a key from the long-lived @pulumi_state_backend@
-- bucket into a local file — the @restore@ half of the retention path.
-- Returns @Right True@ when the object was written to @outputPath@,
-- @Right False@ when the key is absent (no retained cert yet — the next
-- deploy triggers a fresh order), and @Left@ on any other failure
-- (fail-closed: an unreadable backend is not "absent").
getLongLivedObject
  :: FilePath
  -> [(String, String)]
  -> PulumiStateBackendSection
  -> String
  -> FilePath
  -- ^ Local path the object body is written to.
  -> IO (Either String Bool)
getLongLivedObject workingDir environment section key outputPath =
  do
    gate <- queryLongLivedObjectVaultGate
    if vaultGateAllows gate
      then getLongLivedObjectUnlocked workingDir environment section key outputPath
      else pure (Left (renderLongLivedObjectVaultGateBlock gate))

getLongLivedObjectUnlocked
  :: FilePath
  -> [(String, String)]
  -> PulumiStateBackendSection
  -> String
  -> FilePath
  -> IO (Either String Bool)
getLongLivedObjectUnlocked workingDir environment section key outputPath =
  case longLivedPulumiBackendUrlEither section of
    Left err -> pure (Left (longLivedBackendErrorMessage err))
    Right _url -> do
      let bucket = Text.unpack (Text.strip (psbBucketName section))
      result <-
        captureSubprocessResult
          Subprocess
            { subprocessPath = "aws"
            , subprocessArguments =
                ["s3api", "get-object", "--bucket", bucket, "--key", key, outputPath]
            , subprocessEnvironment = Just environment
            , subprocessWorkingDirectory = Just workingDir
            }
      pure $ case result of
        Failure err -> Left ("failed to start `aws s3api get-object`: " ++ err)
        Success output -> case processExitCode output of
          ExitSuccess -> Right True
          ExitFailure code
            | isLongLivedNoSuchKeyMessage (processStderr output) -> Right False
            | otherwise ->
                Left
                  ( "`aws s3api get-object --bucket "
                      ++ bucket
                      ++ " --key "
                      ++ key
                      ++ "` exited with code "
                      ++ show code
                      ++ ": "
                      ++ processStderr output
                  )

queryLongLivedObjectVaultGate :: IO VaultGateDecision
queryLongLivedObjectVaultGate = do
  address <- resolveHostVaultAddress
  vaultGateDecision <$> vaultSealStatus address

renderLongLivedObjectVaultGateBlock :: VaultGateDecision -> String
renderLongLivedObjectVaultGateBlock gate =
  "vault_status="
    ++ vaultStatusLabel gate
    ++ " component=long-lived-object result=unobservable"

vaultStatusLabel :: VaultGateDecision -> String
vaultStatusLabel gate = case gate of
  VaultGateAllow -> "unsealed"
  VaultGateBlockSealed -> "sealed"
  VaultGateBlockUninitialized -> "uninitialized"
  VaultGateBlockUnreachable _ -> "unreachable"

-- | Sprint 8.7: resolve everything needed for a long-lived bucket
-- object operation from @prodbox.dhall@: the admin AWS @aws
-- s3api@ environment and the configured 'PulumiStateBackendSection'.
-- Returns @Left@ (for graceful degradation by the caller) when admin
-- credentials are not configured, the config cannot be read, or no
-- long-lived backend bucket is configured — so a chart deploy on a host
-- without the retention store simply skips retention rather than failing.
resolveLongLivedAdminS3Context
  :: FilePath -> IO (Either String ([(String, String)], PulumiStateBackendSection))
resolveLongLivedAdminS3Context repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> pure (Left err)
    Right adminCreds -> do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err -> pure (Left err)
        Right config -> do
          let section = pulumi_state_backend config
          case longLivedPulumiBackendUrlEither section of
            Left backendErr -> pure (Left (longLivedBackendErrorMessage backendErr))
            Right _url -> do
              environment <- buildAdminS3Environment adminCreds
              pure (Right (environment, section))

-- | Build the @aws s3api@ environment for admin-credentialed long-lived
-- bucket operations. Mirrors the AWS env projection used by the residue
-- queries without depending on them.
buildAdminS3Environment :: Credentials -> IO [(String, String)]
buildAdminS3Environment adminCreds = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
      adminRegion = Text.unpack (region adminCreds)
      sessionTokenEntries = case session_token adminCreds of
        Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]
        Nothing -> []
  pure
    ( [ ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id adminCreds))
      , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key adminCreds))
      , ("AWS_REGION", adminRegion)
      , ("AWS_DEFAULT_REGION", adminRegion)
      , ("AWS_EC2_METADATA_DISABLED", "true")
      , ("PATH", path)
      , ("HOME", home)
      , ("LANG", "C.UTF-8")
      ]
        ++ sessionTokenEntries
    )

-- | Pure: does an @aws s3api get-object@ failure message indicate the
-- key is simply absent (vs. a real backend failure)? Public so the unit
-- suite can pin the discrimination. Matches the canonical @NoSuchKey@
-- blob case-insensitively.
isLongLivedNoSuchKeyMessage :: String -> Bool
isLongLivedNoSuchKeyMessage detail =
  "nosuchkey" `isInfixOf` normalized
    || ("not found" `isInfixOf` normalized && "key" `isInfixOf` normalized)
 where
  normalized = map toLower detail

-- | Bracket the action with the long-lived backend's
-- @PULUMI_BACKEND_URL@ exported into the process environment, then
-- restore the prior value when the action exits. The action runs
-- whether or not the bucket exists; the caller is responsible for
-- calling 'ensureLongLivedPulumiStateBucket' before invoking actions
-- that require the bucket.
withLongLivedPulumiBackendEnv
  :: PulumiStateBackendSection -> IO a -> IO (Either LongLivedBackendError a)
withLongLivedPulumiBackendEnv section action = case longLivedPulumiBackendUrlEither section of
  Left err -> pure (Left err)
  Right url -> do
    previous <- lookupEnv "PULUMI_BACKEND_URL"
    result <-
      bracket_
        (setEnv "PULUMI_BACKEND_URL" url)
        (maybe (unsetEnv "PULUMI_BACKEND_URL") (setEnv "PULUMI_BACKEND_URL") previous)
        action
    pure (Right result)
