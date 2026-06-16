{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.16: live source-of-truth residue queries.
--
-- Replaces the file-existence snapshot adapter as the authoritative
-- answer to \"is stack X present in its Pulumi backend?\". Production
-- Pulumi-stack reads go through 'Prodbox.Infra.StackOutputs'
-- encrypted-backend helpers:
--
--   * Per-run stacks (@aws-eks-test@, @aws-eks-subzone@, @aws-test@)
--     query the Vault-encrypted Model-B object-store through the
--     decrypt-to-scratch Pulumi interposition.
--
--   * The long-lived @aws-ses@ stack uses the same encrypted object-store
--     path. Long-lived public-edge TLS material remains an S3 object class
--     and is queried separately below.
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
  , residueStatusFromMinioListing
  , residueStatusFromMinioListingWithVaultGate
  , residueStatusFromS3ListingWithVaultGate
  , residueStatusFromObjectListing
  , residueStatusFromObjectListingWithVaultGate
  , residueStatusBlockedByVaultGate
  , renderResidueVaultGateBlock
  , isMissingStateBackendBucketMessage
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
import Prodbox.Infra.StackOutputs
  ( StackListEntry
  , StackName (..)
  , StackOutputsError (..)
  , fetchEncryptedOutputs
  , listEncryptedStack
  , parseOutputsPayload
  , renderStackOutputsError
  , stackPresentInList
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  )
import Prodbox.Pulumi.EncryptedBackend (PulumiStackRef (..))
import Prodbox.Settings
  ( Credentials (..)
  , PulumiStateBackendSection
  , loadConfigFile
  , pulumi_state_backend
  )
import Prodbox.Vault.Client (vaultSealStatus)
import Prodbox.Vault.Gate
  ( VaultGateDecision (..)
  , vaultGateAllows
  , vaultGateDecision
  )
import Prodbox.Vault.Host (resolveHostVaultAddress)
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

-- | Live encrypted-backend query for the three per-run stacks. Each stack
-- presence check hydrates its Vault-encrypted checkpoint into a scratch
-- @file://@ backend; the persistent object-store is never listed with raw
-- Pulumi/S3 semantics.
queryPerRunResidueStatuses :: FilePath -> IO PerRunResidueStatuses
queryPerRunResidueStatuses repoRoot = do
  absentBypass <- isTestResidueAbsentSet
  unreachableBypass <- isTestResidueUnreachableSet
  if absentBypass
    then pure perRunAbsentTriple
    else
      if unreachableBypass
        then pure perRunUnreachableTriple
        else do
          gate <- queryResidueVaultGate
          if vaultGateAllows gate
            then queryPerRunLive repoRoot
            else pure (perRunVaultGatedTriple gate)

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

perRunVaultGatedTriple :: VaultGateDecision -> PerRunResidueStatuses
perRunVaultGatedTriple gate =
  let blocked = residueStatusBlockedByVaultGate gate
   in PerRunResidueStatuses blocked blocked blocked

queryPerRunLive :: FilePath -> IO PerRunResidueStatuses
queryPerRunLive repoRoot = do
  eks <- queryOne repoRoot (StackName (Text.pack awsEksTestStackName))
  subzone <- queryOne repoRoot (StackName (Text.pack awsEksSubzoneStackName))
  test <- queryOne repoRoot (StackName (Text.pack awsTestStackName))
  pure
    PerRunResidueStatuses
      { perRunAwsEksTest = eks
      , perRunAwsEksSubzone = subzone
      , perRunAwsTest = test
      }

-- | Live encrypted-backend query for the long-lived @aws-ses@ stack.
-- Long-lived callers still treat unreadable state as blocking because
-- they cannot prove the resource is absent.
queryAwsSesResidueStatus :: FilePath -> IO ResidueStatus
queryAwsSesResidueStatus repoRoot = do
  bypass <- isTestResidueAbsentSet
  if bypass
    then pure ResidueAbsent
    else do
      gate <- queryResidueVaultGate
      if vaultGateAllows gate
        then querySesLive repoRoot
        else pure (residueStatusBlockedByVaultGate gate)

querySesLive :: FilePath -> IO ResidueStatus
querySesLive repoRoot = do
  result <-
    listEncryptedStack
      repoRoot
      (stackRefFor (StackName (Text.pack awsSesStackName)))
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
    else do
      gate <- queryResidueVaultGate
      if vaultGateAllows gate
        then
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
        else pure (residueStatusBlockedByVaultGate gate)

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

-- | Query one encrypted Pulumi checkpoint and translate the response into
-- a 'ResidueStatus'. This is the Sprint 7.14 production replacement for
-- raw @pulumi stack ls --json@ against MinIO/S3.
queryOne
  :: FilePath
  -- ^ Repo root.
  -> StackName
  -- ^ Canonical stack name (e.g. @aws-eks-test@).
  -> IO ResidueStatus
queryOne repoRoot stackName@(StackName rawName) = do
  result <- listEncryptedStack repoRoot (stackRefFor stackName)
  pure (residueStatusFromMinioListing (Text.unpack rawName) result)

queryResidueVaultGate :: IO VaultGateDecision
queryResidueVaultGate = do
  address <- resolveHostVaultAddress
  vaultGateDecision <$> vaultSealStatus address

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
            { residueEvidence = "Pulumi backend reports stack present"
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
    | isMissingStateBackendBucketMessage (stackOutputsErrorDetail err) ->
        ResidueAbsent
  _ -> residueStatusFromListing stackName residueReasonFromS3Error result

residueStatusFromS3ListingWithVaultGate
  :: VaultGateDecision
  -> String
  -> Either StackOutputsError [StackListEntry]
  -> ResidueStatus
residueStatusFromS3ListingWithVaultGate gate stackName result
  | vaultGateAllows gate = residueStatusFromS3Listing stackName result
  | otherwise = residueStatusBlockedByVaultGate gate

-- | Per-run encrypted backends use a never-created (or deleted) object-store
-- bucket as the authoritative "nothing to destroy" state: a @NoSuchBucket@ /
-- @code=NotFound@ response means no per-run stacks were ever provisioned,
-- which is 'ResidueAbsent', NOT 'ResidueUnreachable'. Other MinIO/object-store
-- errors still fail closed via 'ResidueUnreachable' through
-- 'residueReasonFromMinioError'.
residueStatusFromMinioListing
  :: String
  -> Either StackOutputsError [StackListEntry]
  -> ResidueStatus
residueStatusFromMinioListing stackName result = case result of
  Left err
    | isMissingStateBackendBucketMessage (stackOutputsErrorDetail err) ->
        ResidueAbsent
  _ -> residueStatusFromListing stackName residueReasonFromMinioError result

residueStatusFromMinioListingWithVaultGate
  :: VaultGateDecision
  -> String
  -> Either StackOutputsError [StackListEntry]
  -> ResidueStatus
residueStatusFromMinioListingWithVaultGate gate stackName result
  | vaultGateAllows gate = residueStatusFromMinioListing stackName result
  | otherwise = residueStatusBlockedByVaultGate gate

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
    | isMissingStateBackendBucketMessage detail -> ResidueAbsent
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

residueStatusFromObjectListingWithVaultGate
  :: VaultGateDecision
  -> String
  -> Either String [String]
  -> ResidueStatus
residueStatusFromObjectListingWithVaultGate gate resourceName result
  | vaultGateAllows gate = residueStatusFromObjectListing resourceName result
  | otherwise = residueStatusBlockedByVaultGate gate

residueStatusBlockedByVaultGate :: VaultGateDecision -> ResidueStatus
residueStatusBlockedByVaultGate gate =
  ResidueUnreachable (ResidueQueryFailed (renderResidueVaultGateBlock gate))

renderResidueVaultGateBlock :: VaultGateDecision -> String
renderResidueVaultGateBlock gate =
  "vault_status="
    ++ vaultStatusLabel gate
    ++ " component=residue-query result=unobservable"

vaultStatusLabel :: VaultGateDecision -> String
vaultStatusLabel gate = case gate of
  VaultGateAllow -> "unsealed"
  VaultGateBlockSealed -> "sealed"
  VaultGateBlockUninitialized -> "uninitialized"
  VaultGateBlockUnreachable _ -> "unreachable"

stackOutputsErrorDetail :: StackOutputsError -> String
stackOutputsErrorDetail err = case err of
  StackOutputsSubprocessFailed detail -> detail
  StackOutputsCommandFailed detail -> detail
  StackOutputsParseFailed detail -> detail

-- | Detect the S3-compatible "the state bucket does not exist" blob
-- emitted by both the long-lived S3 backend AND the per-run in-cluster
-- MinIO backend (a 404 @NoSuchBucket@ / @code=NotFound@ when listing
-- stacks). A never-created bucket is authoritative evidence of "nothing
-- to destroy" (Absent), not an unobservable backend (Unreachable).
isMissingStateBackendBucketMessage :: String -> Bool
isMissingStateBackendBucketMessage detail =
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

-- | Sprint 4.18 / 7.14: live source-of-truth read of one per-run stack's
-- Pulumi outputs from the encrypted Pulumi object-store via the
-- decrypt-to-scratch backend.
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
  result <-
    fetchEncryptedOutputs
      repoRoot
      (projectDirFor repoRoot stackName)
      (stackRefFor stackName)
  pure $ case result of
    Left err -> Left (renderStackOutputsError err)
    Right outputs -> Right outputs

-- | Test-only env var that redirects 'fetchPerRunStackOutputs' away
-- from the live encrypted backend and onto a file system directory
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

-- | Sprint 4.18 / 7.14: live source-of-truth read of the long-lived
-- @aws-ses@ stack outputs from the encrypted Pulumi object-store.
fetchAwsSesStackOutputs :: FilePath -> IO (Either String (Map Text.Text Text.Text))
fetchAwsSesStackOutputs repoRoot = do
  result <-
    fetchEncryptedOutputs
      repoRoot
      (repoRoot </> "pulumi" </> "aws-ses")
      (stackRefFor (StackName (Text.pack awsSesStackName)))
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
        "aws-ses" -> repoRoot </> "pulumi" </> "aws-ses"
        other -> repoRoot </> "pulumi" </> other

stackRefFor :: StackName -> PulumiStackRef
stackRefFor (StackName raw) =
  PulumiStackRef (Text.pack (projectNameForStackName (Text.unpack raw))) raw

projectNameForStackName :: String -> String
projectNameForStackName stackName =
  case stackName of
    "aws-eks-test" -> "prodbox-aws-eks-test"
    "aws-eks-subzone" -> "prodbox-aws-eks-subzone"
    "aws-test" -> "prodbox-aws-test"
    "aws-ses" -> "prodbox-aws-ses"
    other -> other
