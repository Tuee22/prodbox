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
import Data.Text qualified as Text
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
import System.Environment (lookupEnv, setEnv, unsetEnv)
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
    \pulumi_state_backend.region in prodbox-config.dhall, then run \
    \`prodbox pulumi aws-ses-migrate-backend` to migrate existing state from the \
    \in-cluster MinIO backend onto the dedicated long-lived S3 bucket."
  BackendBucketNameEmpty ->
    "pulumi_state_backend.bucket_name must not be empty for long-lived stacks."
  BackendRegionEmpty ->
    "pulumi_state_backend.region must not be empty for long-lived stacks."
  BucketEnsureFailed detail ->
    "failed to ensure long-lived Pulumi state bucket: " ++ detail

-- | Sprint 4.10: read the admin AWS credential block from
-- @aws_admin_for_test_simulation@ in @prodbox-config.dhall@. Returns
-- @Left@ when any required field (access key, secret, region) is
-- empty.
--
-- Long-lived stack operations (`prodbox pulumi aws-ses-resources`,
-- `prodbox pulumi aws-ses-destroy`) authenticate with the admin
-- credential block rather than the operational @aws.*@ block, so the
-- operational @prodbox@ IAM user does not need @s3:GetObject@ /
-- @PutObject@ on the long-lived state bucket. In test simulation the
-- harness materializes the block from the same operator workflow
-- (`prodbox aws setup`) used for operator-interactive flows.
loadAdminAwsCredentials :: FilePath -> IO (Either String Credentials)
loadAdminAwsCredentials repoRoot = do
  configResult <- loadConfigFile repoRoot
  pure $ case configResult of
    Left err -> Left err
    Right config ->
      let creds = aws_admin_for_test_simulation config
       in if adminCredentialsConfigured creds
            then Right creds
            else
              Left
                "aws_admin_for_test_simulation.access_key_id, \
                \aws_admin_for_test_simulation.secret_access_key, and \
                \aws_admin_for_test_simulation.region must all be set \
                \in prodbox-config.dhall before long-lived stack operations \
                \(`prodbox pulumi aws-ses-resources`, `aws-ses-destroy`, \
                \`aws-ses-migrate-backend`) can authenticate."

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
          purgeRemainingVersions workingDir environment bucket

-- | Purge every remaining object version and delete-marker in the
-- versioned bucket. Lists versions through @aws s3api
-- list-object-versions@, parses the JSON in-process, builds the
-- @delete@ payload, and calls @aws s3api delete-objects@. Iterates
-- to drain truncated pages. Idempotent — does nothing when the
-- bucket has no remaining versions.
purgeRemainingVersions
  :: FilePath -> [(String, String)] -> String -> IO (Either String ())
purgeRemainingVersions workingDir environment bucket = go
 where
  go :: IO (Either String ())
  go = do
    listResult <- listVersionsPage workingDir environment bucket
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
  :: FilePath -> [(String, String)] -> String -> IO (Either String [BucketVersion])
listVersionsPage workingDir environment bucket = do
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
