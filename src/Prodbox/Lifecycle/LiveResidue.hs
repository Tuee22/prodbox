{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.16: live source-of-truth residue queries.
--
-- Replaces the file-existence snapshot adapter as the authoritative
-- answer to \"is stack X present in its Pulumi backend?\". Talks to
-- the backends directly via @pulumi stack ls --json@ through
-- 'Prodbox.Infra.StackOutputs':
--
--   * Per-run stacks (@aws-eks-test@, @aws-eks-subzone@, @aws-test@)
--     query the in-cluster MinIO backend. Opens one MinIO port-forward
--     and runs the three project listings inside the bracket so
--     callers do not pay the port-forward cost three times.
--
--   * The long-lived @aws-ses@ stack queries the operator-account S3
--     backend declared by 'Prodbox.Infra.LongLivedPulumiBackend' using
--     admin AWS credentials from @aws_admin_for_test_simulation@.
--
-- On any subprocess, credential, or parse failure the result is
-- 'ResidueUnreachable'. Per
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 3@,
-- destructive teardown gates fail closed on 'ResidueUnreachable' via the
-- single 'Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate'
-- combinator ("present OR unreachable → block"; Sprint 4.20). The
-- @--cascade@ path is the deliberate exception: its own
-- 'Prodbox.Lifecycle.ResourceRegistry.resourcesToDestroy' treats per-run unreachable
-- as absent (the per-run state died with the cluster, with the
-- postflight tag sweep as backstop).
module Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (..)
  , queryPerRunResidueStatuses
  , queryAwsSesResidueStatus
  , queryPublicEdgeTlsResidueStatus
  , destroyRetainedPublicEdgeTls
  , fetchPerRunStackOutputs
  , fetchAwsSesStackOutputs

    -- * Pure helpers (exported for tests)
  , residueReasonFromMinioError
  , residueReasonFromS3Error
  , residueStatusFromListing
  , residueStatusFromS3Listing
  , residueStatusFromObjectListing
  , isMissingLongLivedS3BackendBucketMessage
  , awsEksTestStackName
  , awsEksSubzoneStackName
  , awsTestStackName
  , awsSesStackName
  , publicEdgeTlsResourceName
  , publicEdgeTlsRetentionPrefix
  )
where

import Control.Exception qualified
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Prodbox.Infra.LongLivedPulumiBackend
  ( listLongLivedObjectKeysUnderPrefix
  , loadAdminAwsCredentials
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  , purgeLongLivedObjectsUnderPrefix
  )
import Prodbox.Infra.MinioBackend
  ( pulumiBackendUrl
  , readMinioCredentials
  , withMinioPortForward
  )
import Prodbox.Infra.StackOutputs
  ( StackListEntry
  , StackName (..)
  , StackOutputsError (..)
  , fetchOutputs
  , listStacks
  , parseOutputsPayload
  , renderStackOutputsError
  , stackPresentInList
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  )
import Prodbox.Settings
  ( Credentials (..)
  , PulumiStateBackendSection
  , loadConfigFile
  , pulumi_state_backend
  )
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>))

-- | Test-only env var that makes both 'queryPerRunResidueStatuses'
-- and 'queryAwsSesResidueStatus' short-circuit to 'ResidueAbsent'
-- without consulting the live backends. The integration suite
-- ('fakeAwsEnvironment' / 'fakeAwsHarnessEnvironment') sets this so
-- the fake-AWS-CLI happy-path tests do not require a running MinIO or
-- a configured long-lived S3 backend. Production code paths never set
-- this var; the name is kept descriptive so a stray set in production
-- is loud rather than silent.
testResidueAbsentEnvVar :: String
testResidueAbsentEnvVar = "PRODBOX_TEST_RESIDUE_ABSENT"

isTestResidueAbsentSet :: IO Bool
isTestResidueAbsentSet = isJust <$> lookupEnv testResidueAbsentEnvVar

-- | Test-only env var (symmetric to 'PRODBOX_TEST_RESIDUE_ABSENT') that
-- makes 'queryPerRunResidueStatuses' short-circuit to all-'ResidueUnreachable'
-- without consulting a live backend. Lets the integration suite exercise the
-- Sprint 4.19 fail-closed delete gate (MinIO-unreachable → refuse) without a
-- real failing port-forward. Production code paths never set this var.
testResidueUnreachableEnvVar :: String
testResidueUnreachableEnvVar = "PRODBOX_TEST_RESIDUE_UNREACHABLE"

isTestResidueUnreachableSet :: IO Bool
isTestResidueUnreachableSet = isJust <$> lookupEnv testResidueUnreachableEnvVar

-- | Canonical Pulumi stack names. Centralised here so callers do not
-- import them transitively from each per-stack module.
awsEksTestStackName, awsEksSubzoneStackName, awsTestStackName, awsSesStackName :: String
awsEksTestStackName = "aws-eks-test"
awsEksSubzoneStackName = "aws-eks-subzone"
awsTestStackName = "aws-test"
awsSesStackName = "aws-ses"

-- | The three per-run AWS-substrate Pulumi stacks (per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@).
-- The fields are populated by one shared MinIO port-forward bracket
-- in 'queryPerRunResidueStatuses'; on bracket failure all three
-- carry 'ResidueUnreachable' with the same reason.
data PerRunResidueStatuses = PerRunResidueStatuses
  { perRunAwsEksTest :: !ResidueStatus
  , perRunAwsEksSubzone :: !ResidueStatus
  , perRunAwsTest :: !ResidueStatus
  }
  deriving (Eq, Show)

-- | Live MinIO-backend query for the three per-run stacks. Resolves
-- MinIO root credentials, opens one port-forward, and queries
-- @pulumi stack ls --json@ inside each per-stack project directory.
-- On any failure before or during the bracket, all three fields
-- carry 'ResidueUnreachable (ResidueBackendMinioUnreachable …)'.
queryPerRunResidueStatuses :: FilePath -> IO PerRunResidueStatuses
queryPerRunResidueStatuses repoRoot = do
  absentBypass <- isTestResidueAbsentSet
  unreachableBypass <- isTestResidueUnreachableSet
  if absentBypass
    then pure perRunAbsentTriple
    else
      if unreachableBypass
        then pure perRunUnreachableTriple
        else queryPerRunLive repoRoot

-- | All three per-run stacks reported unreachable. Used for the
-- 'PRODBOX_TEST_RESIDUE_UNREACHABLE' bypass so the integration suite can
-- exercise the fail-closed delete gate.
perRunUnreachableTriple :: PerRunResidueStatuses
perRunUnreachableTriple =
  let unreachable = ResidueUnreachable (ResidueBackendMinioUnreachable testResidueUnreachableEnvVar)
   in PerRunResidueStatuses unreachable unreachable unreachable

-- | All three per-run stacks reported absent. Used for the
-- 'PRODBOX_TEST_RESIDUE_ABSENT' bypass and as the base for tests that
-- override individual fields.
perRunAbsentTriple :: PerRunResidueStatuses
perRunAbsentTriple =
  PerRunResidueStatuses
    { perRunAwsEksTest = ResidueAbsent
    , perRunAwsEksSubzone = ResidueAbsent
    , perRunAwsTest = ResidueAbsent
    }

queryPerRunLive :: FilePath -> IO PerRunResidueStatuses
queryPerRunLive repoRoot = do
  credsResult <- readMinioCredentials
  case credsResult of
    Left err -> pure (unreachableTriple (ResidueBackendMinioUnreachable err))
    Right (accessKey, secretKey) -> do
      bracketResult <-
        withMinioPortForward $ \localPort -> do
          environment <- buildMinioBackendEnv localPort accessKey secretKey
          eks <-
            queryOne
              (repoRoot </> "pulumi" </> "aws-eks")
              environment
              awsEksTestStackName
              residueReasonFromMinioError
          subzone <-
            queryOne
              (repoRoot </> "pulumi" </> "aws-eks-subzone")
              environment
              awsEksSubzoneStackName
              residueReasonFromMinioError
          test <-
            queryOne
              (repoRoot </> "pulumi" </> "aws-test")
              environment
              awsTestStackName
              residueReasonFromMinioError
          pure (eks, subzone, test)
      pure $ case bracketResult of
        Left err -> unreachableTriple (ResidueBackendMinioUnreachable err)
        Right (eks, subzone, test) ->
          PerRunResidueStatuses
            { perRunAwsEksTest = eks
            , perRunAwsEksSubzone = subzone
            , perRunAwsTest = test
            }
 where
  unreachableTriple reason =
    let unreachable = ResidueUnreachable reason
     in PerRunResidueStatuses unreachable unreachable unreachable

-- | Live S3-backend query for the long-lived @aws-ses@ stack.
-- Authenticates with admin AWS credentials and reads the long-lived
-- bucket configuration from @prodbox-config.dhall@. Returns
-- 'ResidueUnreachable (ResidueBackendS3Unreachable …)' on any
-- credential, configuration, or subprocess failure; long-lived
-- callers treat that as still-present per the doctrine.
queryAwsSesResidueStatus :: FilePath -> IO ResidueStatus
queryAwsSesResidueStatus repoRoot = do
  bypass <- isTestResidueAbsentSet
  if bypass
    then pure ResidueAbsent
    else querySesLive repoRoot

querySesLive :: FilePath -> IO ResidueStatus
querySesLive repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> pure (ResidueUnreachable (ResidueBackendS3Unreachable err))
    Right adminCreds -> do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err ->
          pure (ResidueUnreachable (ResidueBackendS3Unreachable err))
        Right config -> case longLivedPulumiBackendUrlEither (pulumi_state_backend config) of
          Left err ->
            pure
              ( ResidueUnreachable
                  (ResidueBackendS3Unreachable (longLivedBackendErrorMessage err))
              )
          Right backendUrl -> do
            environment <- buildLongLivedBackendEnv adminCreds backendUrl
            result <- listStacks (repoRoot </> "pulumi" </> "aws-ses") environment
            pure (residueStatusFromS3Listing awsSesStackName result)

-- | Sprint 4.24: the canonical managed-resource name and the
-- substrate-scoped S3 key prefix of the retained public-edge production
-- TLS certificate material in the long-lived @pulumi_state_backend@
-- bucket. The full per-substrate key scheme
-- (@public-edge-tls/\<substrate\>/\<fqdn\>@) is filled in by the chart
-- platform writers (Sprint 7.11 \/ 8.7); the @discover@ and @destroy@
-- here operate on the whole prefix, so they observe and remove the
-- entire retained-cert class regardless of which substrate keys exist.
publicEdgeTlsResourceName :: String
publicEdgeTlsResourceName = "public-edge-tls"

publicEdgeTlsRetentionPrefix :: String
publicEdgeTlsRetentionPrefix = "public-edge-tls/"

-- | Sprint 4.24: live S3 @discover@ for the retained public-edge
-- production TLS certificate (the 'LongLived' managed resource). Lists
-- the object keys under 'publicEdgeTlsRetentionPrefix' in the
-- long-lived @pulumi_state_backend@ bucket and translates the result
-- into a typed 'ResidueStatus' via 'residueStatusFromObjectListing':
-- present when any retained object exists, absent when none do (or the
-- backend bucket is gone), and 'ResidueUnreachable' on any other
-- credential / config / S3 failure so destructive gates fail closed.
queryPublicEdgeTlsResidueStatus :: FilePath -> IO ResidueStatus
queryPublicEdgeTlsResidueStatus repoRoot = do
  bypass <- isTestResidueAbsentSet
  if bypass
    then pure ResidueAbsent
    else
      withLongLivedBucketEnv
        repoRoot
        ( \section environment ->
            residueStatusFromObjectListing publicEdgeTlsResourceName
              <$> listLongLivedObjectKeysUnderPrefix
                repoRoot
                environment
                section
                publicEdgeTlsRetentionPrefix
        )
        (\err -> ResidueUnreachable (ResidueBackendS3Unreachable err))

-- | Sprint 4.24: the @destroy@ action for the retained public-edge
-- production TLS certificate managed resource — purge every object
-- under 'publicEdgeTlsRetentionPrefix' from the long-lived
-- @pulumi_state_backend@ bucket. Idempotent: an already-absent bucket
-- or empty prefix returns @Right ()@. Invoked only by an explicit
-- destroy or transitively by @prodbox nuke@'s whole-bucket destroy;
-- never by @rke2 delete@ or @aws teardown@.
destroyRetainedPublicEdgeTls :: FilePath -> IO (Either String ())
destroyRetainedPublicEdgeTls repoRoot =
  withLongLivedBucketEnv
    repoRoot
    ( \section environment ->
        purgeLongLivedObjectsUnderPrefix
          repoRoot
          environment
          section
          publicEdgeTlsRetentionPrefix
    )
    Left

-- | Shared preamble for object-level operations on the long-lived
-- @pulumi_state_backend@ bucket: load the admin AWS credentials, load
-- the config, resolve the backend section + URL, and build the AWS
-- environment, then run @action@ with the section and environment. Any
-- credential / config / backend-URL failure short-circuits to
-- @onError@ applied to the failure detail.
withLongLivedBucketEnv
  :: FilePath
  -> (PulumiStateBackendSection -> [(String, String)] -> IO a)
  -> (String -> a)
  -> IO a
withLongLivedBucketEnv repoRoot action onError = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> pure (onError err)
    Right adminCreds -> do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err -> pure (onError err)
        Right config ->
          let section = pulumi_state_backend config
           in case longLivedPulumiBackendUrlEither section of
                Left err -> pure (onError (longLivedBackendErrorMessage err))
                Right backendUrl -> do
                  environment <- buildLongLivedBackendEnv adminCreds backendUrl
                  action section environment

-- | Run one @pulumi stack ls --json@ query in the supplied project
-- directory and translate the response into a 'ResidueStatus'. The
-- error-mapping function decides whether subprocess failures count as
-- MinIO-unreachable (per-run) or S3-unreachable (long-lived).
queryOne
  :: FilePath
  -- ^ Pulumi project directory.
  -> [(String, String)]
  -- ^ Environment for the @pulumi@ subprocess.
  -> String
  -- ^ Canonical stack name (e.g. @aws-eks-test@).
  -> (StackOutputsError -> ResidueUnreachableReason)
  -- ^ Per-backend error mapper.
  -> IO ResidueStatus
queryOne projectDir environment stackName toReason = do
  result <- listStacks projectDir environment
  pure (residueStatusFromListing stackName toReason result)

-- | Pure helper translating the 'listStacks' result into a typed
-- 'ResidueStatus'. Exposed for unit testing because the IO query is
-- hard to exercise without a live cluster.
residueStatusFromListing
  :: String
  -> (StackOutputsError -> ResidueUnreachableReason)
  -> Either StackOutputsError [StackListEntry]
  -> ResidueStatus
residueStatusFromListing stackName toReason result = case result of
  Left err -> ResidueUnreachable (toReason err)
  Right entries
    | stackPresentInList (StackName (Text.pack stackName)) entries ->
        ResiduePresent
          ResidueDetails
            { residueEvidence = "pulumi stack ls reports stack present"
            , residueStackName = stackName
            }
    | otherwise -> ResidueAbsent

-- | Long-lived S3 backends use a deleted bucket as the authoritative
-- "nothing to destroy" state during total teardown. Other S3 errors
-- still fail closed via 'ResidueUnreachable'.
residueStatusFromS3Listing
  :: String
  -> Either StackOutputsError [StackListEntry]
  -> ResidueStatus
residueStatusFromS3Listing stackName result = case result of
  Left err
    | isMissingLongLivedS3BackendBucketMessage (stackOutputsErrorDetail err) ->
        ResidueAbsent
  _ -> residueStatusFromListing stackName residueReasonFromS3Error result

-- | Sprint 4.24: translate a long-lived S3 object-key listing (from
-- 'listLongLivedObjectKeysUnderPrefix') into a typed 'ResidueStatus'
-- for the retained public-edge production TLS certificate. Pure so the
-- unit suite can pin the present \/ absent \/ unreachable discrimination
-- without a live S3 round-trip:
--
--   * @Right (_:_)@ — retained cert material present.
--   * @Right []@ — nothing retained (absent).
--   * @Left detail@ naming a missing bucket — the long-lived backend is
--     gone, the authoritative "nothing to destroy" during total
--     teardown (absent), mirroring 'residueStatusFromS3Listing'.
--   * @Left detail@ otherwise — fail closed as 'ResidueUnreachable' so
--     'Prodbox.Lifecycle.ResidueStatus.residueBlocksTeardownGate'
--     refuses rather than silently treating an unreadable backend as
--     absent.
residueStatusFromObjectListing :: String -> Either String [String] -> ResidueStatus
residueStatusFromObjectListing resourceName result = case result of
  Left detail
    | isMissingLongLivedS3BackendBucketMessage detail -> ResidueAbsent
    | otherwise -> ResidueUnreachable (ResidueBackendS3Unreachable detail)
  Right [] -> ResidueAbsent
  Right keys ->
    ResiduePresent
      ResidueDetails
        { residueEvidence =
            "long-lived S3 store holds "
              ++ show (length keys)
              ++ " retained public-edge TLS object(s)"
        , residueStackName = resourceName
        }

stackOutputsErrorDetail :: StackOutputsError -> String
stackOutputsErrorDetail err = case err of
  StackOutputsSubprocessFailed detail -> detail
  StackOutputsCommandFailed detail -> detail
  StackOutputsParseFailed detail -> detail

isMissingLongLivedS3BackendBucketMessage :: String -> Bool
isMissingLongLivedS3BackendBucketMessage detail =
  "nosuchbucket" `isInfixOf` normalized
    || ( "could not list bucket" `isInfixOf` normalized
           && "code=notfound" `isInfixOf` normalized
       )
 where
  normalized = map toLower detail

-- | Map 'StackOutputsError' values onto the MinIO-flavoured
-- 'ResidueUnreachableReason' (subprocess + command failures → backend
-- unreachable; parse failures → query failed).
residueReasonFromMinioError :: StackOutputsError -> ResidueUnreachableReason
residueReasonFromMinioError err = case err of
  StackOutputsSubprocessFailed detail -> ResidueBackendMinioUnreachable detail
  StackOutputsCommandFailed detail -> ResidueBackendMinioUnreachable detail
  StackOutputsParseFailed detail -> ResidueQueryFailed detail

-- | Map 'StackOutputsError' values onto the S3-flavoured
-- 'ResidueUnreachableReason'.
residueReasonFromS3Error :: StackOutputsError -> ResidueUnreachableReason
residueReasonFromS3Error err = case err of
  StackOutputsSubprocessFailed detail -> ResidueBackendS3Unreachable detail
  StackOutputsCommandFailed detail -> ResidueBackendS3Unreachable detail
  StackOutputsParseFailed detail -> ResidueQueryFailed detail

-- | Construct the environment the @pulumi@ subprocess needs to talk
-- to the in-cluster MinIO backend through @127.0.0.1:<port>@ after
-- 'withMinioPortForward' opens the kubectl tunnel. Mirrors the
-- per-stack @pulumiBackendBaseEnv@ helper without depending on it.
buildMinioBackendEnv :: Int -> String -> String -> IO [(String, String)]
buildMinioBackendEnv localPort minioAccessKey minioSecretKey = do
  currentEnv <- getEnvironment
  let path = maybe "" id (lookup "PATH" currentEnv)
      home = maybe "" id (lookup "HOME" currentEnv)
  pure
    [ ("AWS_ACCESS_KEY_ID", minioAccessKey)
    , ("AWS_SECRET_ACCESS_KEY", minioSecretKey)
    , ("AWS_REGION", "us-east-1")
    , ("AWS_DEFAULT_REGION", "us-east-1")
    , ("AWS_EC2_METADATA_DISABLED", "true")
    , ("PULUMI_BACKEND_URL", pulumiBackendUrl localPort)
    , ("PULUMI_CONFIG_PASSPHRASE", "")
    , ("PULUMI_SKIP_UPDATE_CHECK", "true")
    , ("PATH", path)
    , ("HOME", home)
    , ("LANG", "C.UTF-8")
    ]

-- | Construct the environment the @pulumi@ subprocess needs to talk
-- to the long-lived S3 backend using admin AWS credentials. Mirrors
-- 'Prodbox.Infra.AwsSesStack.pulumiSesAdminBaseEnv' without depending
-- on it.
buildLongLivedBackendEnv :: Credentials -> String -> IO [(String, String)]
buildLongLivedBackendEnv adminCreds backendUrl = do
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
      , ("PULUMI_BACKEND_URL", backendUrl)
      , ("PULUMI_CONFIG_PASSPHRASE", "")
      , ("PULUMI_SKIP_UPDATE_CHECK", "true")
      , ("PATH", path)
      , ("HOME", home)
      , ("LANG", "C.UTF-8")
      ]
        ++ sessionTokenEntries
    )

-- | Sprint 4.18: live source-of-truth read of one per-run stack's
-- Pulumi outputs from the in-cluster MinIO backend. Opens its own
-- MinIO port-forward; callers that need outputs from multiple per-run
-- stacks in one go should consider batching at a higher layer.
-- Returns the raw output map; per-stack callers parse this into their
-- typed snapshot record.
--
-- Test-only override: when the environment variable named by
-- 'testPerRunOutputsDirEnvVar' is set, the function reads the outputs
-- map from @<dir>/<stack-name>.json@ instead of dialling the live
-- MinIO backend. The fake-MinIO file must be a JSON object whose
-- values are either strings (primitive outputs) or already-JSON-
-- encoded strings (for complex outputs the production code base64- or
-- JSON-encodes via 'Prodbox.Infra.StackOutputs.parseOutputsPayload').
-- Production code paths never set this variable.
fetchPerRunStackOutputs
  :: FilePath
  -- ^ Repo root (used to locate the per-stack Pulumi project dir).
  -> StackName
  -- ^ Canonical stack name (must match one of 'awsEksTestStackName',
  -- 'awsEksSubzoneStackName', 'awsTestStackName').
  -> IO (Either String (Map Text.Text Text.Text))
fetchPerRunStackOutputs repoRoot stackName = do
  override <- lookupEnv testPerRunOutputsDirEnvVar
  case override of
    Just dir -> readMockOutputsFile (dir </> Text.unpack (unStackName stackName) ++ ".json")
    Nothing -> fetchPerRunStackOutputsLive repoRoot stackName

fetchPerRunStackOutputsLive
  :: FilePath
  -> StackName
  -> IO (Either String (Map Text.Text Text.Text))
fetchPerRunStackOutputsLive repoRoot stackName = do
  credsResult <- readMinioCredentials
  case credsResult of
    Left err -> pure (Left ("MinIO credentials unavailable: " ++ err))
    Right (accessKey, secretKey) -> do
      bracketResult <-
        withMinioPortForward $ \localPort -> do
          environment <- buildMinioBackendEnv localPort accessKey secretKey
          fetchOutputs (projectDirFor repoRoot stackName) environment stackName
      pure $ case bracketResult of
        Left err -> Left ("MinIO port-forward failed: " ++ err)
        Right (Left err) -> Left (renderStackOutputsError err)
        Right (Right outputs) -> Right outputs

-- | Test-only env var that redirects 'fetchPerRunStackOutputs' away
-- from the live MinIO backend and onto a file system directory
-- populated by the test harness. See 'fetchPerRunStackOutputs' for
-- the file naming contract.
testPerRunOutputsDirEnvVar :: String
testPerRunOutputsDirEnvVar = "PRODBOX_TEST_PER_RUN_OUTPUTS_DIR"

readMockOutputsFile :: FilePath -> IO (Either String (Map Text.Text Text.Text))
readMockOutputsFile path = do
  result <- Control.Exception.try (readFile path)
  case (result :: Either Control.Exception.IOException String) of
    Left err ->
      pure
        ( Left
            ( "PRODBOX_TEST_PER_RUN_OUTPUTS_DIR is set but cannot read "
                ++ path
                ++ ": "
                ++ show err
            )
        )
    Right payload ->
      -- Force the payload before returning so the lazy readFile handle
      -- is not still open when this function exits.
      length payload `seq` pure (parseOutputsPayload payload)

-- | Sprint 4.18: live source-of-truth read of the long-lived
-- @aws-ses@ stack outputs from the operator-account S3 backend.
fetchAwsSesStackOutputs :: FilePath -> IO (Either String (Map Text.Text Text.Text))
fetchAwsSesStackOutputs repoRoot = do
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> pure (Left ("admin AWS credentials unavailable: " ++ err))
    Right adminCreds -> do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left err -> pure (Left ("config load failed: " ++ err))
        Right config -> case longLivedPulumiBackendUrlEither (pulumi_state_backend config) of
          Left err -> pure (Left ("long-lived backend unavailable: " ++ longLivedBackendErrorMessage err))
          Right backendUrl -> do
            environment <- buildLongLivedBackendEnv adminCreds backendUrl
            let projectDir = repoRoot </> "pulumi" </> "aws-ses"
            result <- fetchOutputs projectDir environment (StackName (Text.pack awsSesStackName))
            pure $ case result of
              Left err -> Left (renderStackOutputsError err)
              Right outputs -> Right outputs

-- | Resolve the per-stack Pulumi project directory for a per-run stack
-- name. Internal helper for 'fetchPerRunStackOutputs'.
projectDirFor :: FilePath -> StackName -> FilePath
projectDirFor repoRoot stackName =
  let raw = Text.unpack (unStackName stackName)
   in case raw of
        "aws-eks-test" -> repoRoot </> "pulumi" </> "aws-eks"
        "aws-eks-subzone" -> repoRoot </> "pulumi" </> "aws-eks-subzone"
        "aws-test" -> repoRoot </> "pulumi" </> "aws-test"
        other -> repoRoot </> "pulumi" </> other
