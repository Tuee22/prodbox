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

    -- * Sprint 7.22: per-run destroy-invocation gate + corrupt-checkpoint prune
  , PerRunDestroyDecision (..)
  , perRunDestroyDecisionFromStatus
  , pruneCorruptPerRunCheckpoint

    -- * Pure helpers (exported for tests)
  , isRetryableReadFailure
  , mergeSharedObservation
  , residueReasonFromMinioError
  , residueReasonFromS3Error
  , residueStatusFromListing
  , residueStatusFromS3Listing
  , residueStatusFromMinioListing
  , residueStatusFromMinioListingWithVaultGate
  , residueStatusFromS3ListingWithVaultGate
  , residueStatusFromCheckpointObservability
  , residueStatusFromCheckpointObservabilityResult
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
  , observeEncryptedStackCheckpoint
  , parseOutputsPayload
  , renderStackOutputsError
  , stackPresentInList
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  , renderResidueUnreachableReason
  )
import Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , PulumiStackRef (..)
  , classifyCheckpointBytes
  , pruneLogicalPulumiStack
  , renderEncryptedBackendError
  )
import Prodbox.Pulumi.HostDirectObjectStore
  ( hostDirectGetPulumiObject
  , resolveHostDirectPulumiMaterial
  , withHostDirectPulumiPortForward
  )
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
-- The fields are populated by 'observePerRunWithSharedFallback': each stack is
-- observed through the in-cluster gateway daemon object-store API first, and if
-- the daemon is degraded ('daemonMinioCreds == Nothing' / a @503@, or a
-- mid-redeploy) the stacks whose daemon read failed are re-observed
-- host-directly under ONE shared MinIO port-forward. A stack that neither path
-- can read carries 'ResidueUnreachable' with the combined daemon+host detail.
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
  let eksName = StackName (Text.pack awsEksTestStackName)
      subzoneName = StackName (Text.pack awsEksSubzoneStackName)
      testName = StackName (Text.pack awsTestStackName)
  observed <- observePerRunWithSharedFallback repoRoot [eksName, subzoneName, testName]
  let statusFor stackName@(StackName raw) =
        case lookup stackName observed of
          Just result -> residueStatusFromCheckpointObservabilityResult (Text.unpack raw) result
          Nothing ->
            ResidueUnreachable
              (ResidueQueryFailed ("internal: missing per-run observation for " ++ Text.unpack raw))
  pure
    PerRunResidueStatuses
      { perRunAwsEksTest = statusFor eksName
      , perRunAwsEksSubzone = statusFor subzoneName
      , perRunAwsTest = statusFor testName
      }

-- | Observe the given per-run stacks daemon-first, with a SHARED host-direct
-- MinIO fallback: a degraded gateway daemon triggers ONE host material
-- resolution + ONE MinIO port-forward covering every stack whose daemon read
-- failed (rather than one per stack — the root-token load may prompt for the
-- unlock-bundle password, so it must run at most once per query). Each stack's
-- result is returned as the @Either StackOutputsError CheckpointObservability@
-- the classifier consumes.
--
-- Pass 1 observes each stack through the daemon-only encrypted-checkpoint path
-- ('observeEncryptedStackCheckpoint'). A stack whose daemon read positively
-- answered (@Right _@) — present, absent, empty, or corrupt — is kept as-is
-- (host-direct cannot improve on a definitive answer, and a corrupt object is
-- corrupt from either path). Only stacks whose daemon read genuinely FAILED (a
-- @Left@ that is not the authoritative bucket-absent message) are re-observed
-- host-directly under the shared port-forward. When the host material or the
-- port-forward is unavailable, every candidate stays @Left@ (fail-closed) with
-- the combined daemon+host detail — never silently absent.
observePerRunWithSharedFallback
  :: FilePath
  -> [StackName]
  -> IO [(StackName, Either StackOutputsError CheckpointObservability)]
observePerRunWithSharedFallback repoRoot stackNames = do
  daemonResults <-
    mapM
      (\stackName -> (,) stackName <$> observeEncryptedStackCheckpoint repoRoot (stackRefFor stackName))
      stackNames
  let candidates =
        [ (stackName, stackOutputsErrorDetail err)
        | (stackName, Left err) <- daemonResults
        , isRetryableReadFailure err
        ]
  if null candidates
    then pure daemonResults
    else do
      shared <- sharedHostDirectObserve repoRoot (map fst candidates)
      pure (map (mergeSharedObservation candidates shared) daemonResults)

-- | A retry-worthy daemon observe failure: a genuine read failure (the daemon is
-- unreachable\/degraded), NOT the authoritative "state-backend bucket absent"
-- message (a definitive Absent, so nothing to re-observe).
isRetryableReadFailure :: StackOutputsError -> Bool
isRetryableReadFailure err =
  not (isMissingStateBackendBucketMessage (stackOutputsErrorDetail err))

-- | Resolve host-direct material ONCE, open ONE port-forward, and host-direct
-- observe each candidate stack inside it. @Left@ = the material or port-forward
-- was unavailable (applies to every candidate); @Right@ = each candidate's
-- host-direct observation (@Left@ per stack on a host read failure).
sharedHostDirectObserve
  :: FilePath
  -> [StackName]
  -> IO (Either String [(StackName, Either String CheckpointObservability)])
sharedHostDirectObserve repoRoot stackNames = do
  materialResult <- resolveHostDirectPulumiMaterial repoRoot
  case materialResult of
    Left matErr -> pure (Left matErr)
    Right material ->
      withHostDirectPulumiPortForward material $ \handle ->
        mapM
          ( \stackName -> do
              hostResult <- hostDirectGetPulumiObject handle (unStackName stackName)
              pure (stackName, fmap classifyCheckpointBytes hostResult)
          )
          stackNames

-- | Fold a candidate stack's shared host-direct observation back over its
-- daemon result. Non-candidate stacks keep their daemon result unchanged; a
-- candidate becomes its host-direct observation on success, or a combined
-- daemon+host 'StackOutputsCommandFailed' (→ 'ResidueUnreachable') when the
-- host path was also unavailable.
mergeSharedObservation
  :: [(StackName, String)]
  -> Either String [(StackName, Either String CheckpointObservability)]
  -> (StackName, Either StackOutputsError CheckpointObservability)
  -> (StackName, Either StackOutputsError CheckpointObservability)
mergeSharedObservation candidates shared (stackName, daemonResult) =
  case lookup stackName candidates of
    Nothing -> (stackName, daemonResult)
    Just daemonDetail ->
      case shared of
        Left sharedErr ->
          (stackName, Left (StackOutputsCommandFailed (combinedResidueReadFallback daemonDetail sharedErr)))
        Right hostResults ->
          case lookup stackName hostResults of
            Just (Right observability) -> (stackName, Right observability)
            Just (Left hostErr) ->
              (stackName, Left (StackOutputsCommandFailed (combinedResidueReadFallback daemonDetail hostErr)))
            Nothing -> (stackName, daemonResult)

combinedResidueReadFallback :: String -> String -> String
combinedResidueReadFallback daemonDetail hostDetail =
  "gateway daemon object-store read failed ("
    ++ daemonDetail
    ++ "); host-direct MinIO fallback also failed ("
    ++ hostDetail
    ++ ")"

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

-- | Sprint 7.22: a per-run destroy gate decision derived from a freshly
-- observed 'ResidueStatus'. The per-run destroy-INVOCATION path
-- (@destroy\<Stack>Status@ in the per-stack modules) consults this BEFORE
-- fetching stack outputs or running @pulumi destroy@, so a corrupt / absent
-- checkpoint never reaches a crashing @pulumi@ subprocess or an absent
-- in-cluster @minio@ k8s secret. Sprint 7.21 gated the residue *observation*
-- funnel ('queryOne'); this gates the destroy *invocation* itself.
data PerRunDestroyDecision
  = -- | Positively-observed absent checkpoint: nothing to destroy. The
    -- 'String' is the operator-visible skip message.
    PerRunDestroySkip String
  | -- | Valid checkpoint: run the real destroy body.
    PerRunDestroyProceed
  | -- | Corrupt or unreadable checkpoint: refuse (fail-closed, per
    -- @lifecycle_reconciliation_doctrine.md § 3.1@). The 'String' is the
    -- actionable refusal naming the prune recovery.
    PerRunDestroyRefuse String
  deriving (Eq, Show)

-- | Pure mapping from a freshly-observed 'ResidueStatus' to a
-- 'PerRunDestroyDecision'. 'ResidueAbsent' → skip (the home-substrate case:
-- the per-run AWS stacks were never provisioned, or were already destroyed);
-- 'ResiduePresent' → proceed with the real destroy; 'ResidueUnreachable'
-- (corrupt checkpoint or unreadable backend) → refuse, with the recovery
-- pointing at @prune-corrupt-checkpoint@. Pure so the unit suite can pin the
-- skip / proceed / refuse discrimination without a live backend.
perRunDestroyDecisionFromStatus
  :: String
  -- ^ Display name of the stack (e.g. @aws-eks-test@).
  -> String
  -- ^ The prune-recovery command to name in the refusal.
  -> ResidueStatus
  -> PerRunDestroyDecision
perRunDestroyDecisionFromStatus displayName pruneCommand status = case status of
  ResidueAbsent ->
    PerRunDestroySkip
      ("absent (no per-run checkpoint to destroy for " ++ displayName ++ ")")
  ResiduePresent _ -> PerRunDestroyProceed
  ResidueUnreachable reason ->
    PerRunDestroyRefuse
      ( "refusing to destroy "
          ++ displayName
          ++ ": its encrypted Pulumi checkpoint cannot be observed ("
          ++ renderResidueUnreachableReason reason
          ++ "). A corrupt or unreadable checkpoint may hide live AWS resources, so this is fail-closed. "
          ++ "If it is known-corrupt leftover state with no live resources behind it, clear it with `"
          ++ pruneCommand
          ++ "`."
      )

-- | Sprint 7.22: clear a genuinely-corrupt (or empty) per-run encrypted
-- Pulumi checkpoint from the Model-B object store, so a cluster carrying
-- stale corrupt checkpoints (e.g. truncated leftovers from an interrupted
-- run) can converge. Observes the checkpoint first and only deletes when it
-- is positively NOT a valid stack state:
--
--   * 'CheckpointCorrupt' / 'CheckpointEmpty' — delete the opaque object (the
--     prune this command exists for) and report it.
--   * 'CheckpointAbsent' — nothing to prune (idempotent success).
--   * 'CheckpointPresent' — REFUSE: a valid checkpoint may map to live AWS
--     resources, so pruning it would orphan them; the operator must use the
--     normal @destroy@ path instead.
--   * unreadable backend — REFUSE: cannot observe, so cannot safely prune
--     (fail-closed), unless the state-backend bucket itself is absent (then
--     there is genuinely nothing to prune).
pruneCorruptPerRunCheckpoint :: FilePath -> StackName -> IO (Either String String)
pruneCorruptPerRunCheckpoint repoRoot stackName@(StackName rawName) = do
  let name = Text.unpack rawName
  -- Observe with the same daemon-first / host-direct-fallback path as the
  -- residue read, so an operator prune also works when the daemon is degraded.
  observedResults <- observePerRunWithSharedFallback repoRoot [stackName]
  let observed =
        maybe
          (Left (StackOutputsCommandFailed ("internal: missing observation for " ++ name)))
          id
          (lookup stackName observedResults)
  case observed of
    Left err
      | isMissingStateBackendBucketMessage (stackOutputsErrorDetail err) ->
          pure (Right ("no per-run state-backend bucket; nothing to prune for " ++ name ++ "."))
      | otherwise ->
          pure
            ( Left
                ( "cannot observe the encrypted Pulumi checkpoint for "
                    ++ name
                    ++ "; refusing to prune an unobservable backend (fail-closed): "
                    ++ renderStackOutputsError err
                )
            )
    Right CheckpointAbsent ->
      pure (Right ("encrypted Pulumi checkpoint already absent; nothing to prune for " ++ name ++ "."))
    Right CheckpointEmpty -> deleteAndReport name "empty (zero-length)"
    Right (CheckpointCorrupt detail) -> deleteAndReport name ("corrupt (" ++ detail ++ ")")
    Right CheckpointPresent ->
      pure
        ( Left
            ( "the encrypted Pulumi checkpoint for "
                ++ name
                ++ " decodes to a valid non-empty stack state; refusing to prune a live checkpoint "
                ++ "(it may map to live AWS resources). Use `prodbox aws stack <stack> destroy --yes` instead."
            )
        )
 where
  deleteAndReport name kind = do
    deleteResult <- pruneLogicalPulumiStack repoRoot (stackRefFor stackName)
    pure $ case deleteResult of
      Left err ->
        Left
          ( "failed to prune the "
              ++ kind
              ++ " encrypted Pulumi checkpoint for "
              ++ name
              ++ ": "
              ++ renderEncryptedBackendError err
          )
      Right () ->
        Right
          ( "pruned the "
              ++ kind
              ++ " encrypted Pulumi checkpoint object for "
              ++ name
              ++ "."
          )

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

-- | Sprint 7.21 (pure): map a per-run stack's checkpoint observability
-- onto a 'ResidueStatus', applying the doctrine's
-- present\/absent\/unreachable classification
-- (@lifecycle_reconciliation_doctrine.md § 3.1@):
--
--   * 'CheckpointAbsent' — the object was never created or is already
--     destroyed: 'ResidueAbsent' (nothing to destroy → SKIP). This is the
--     home-substrate case.
--   * 'CheckpointEmpty' — a zero-length object yields no stack state:
--     'ResidueAbsent' (nothing to destroy → SKIP). Precisely the empty
--     case, distinct from a non-empty-unparseable blob.
--   * 'CheckpointCorrupt' — present-but-unparseable: "cannot observe" the
--     stack state, so 'ResidueUnreachable' (REFUSE; a corrupt checkpoint
--     may hide live resources, so it must never silently skip). The
--     evidence string names the stack and the parse detail so the refusal
--     is actionable.
--   * 'CheckpointPresent' — a real checkpoint: 'ResiduePresent' (DESTROY).
residueStatusFromCheckpointObservability :: String -> CheckpointObservability -> ResidueStatus
residueStatusFromCheckpointObservability stackName observability = case observability of
  CheckpointAbsent -> ResidueAbsent
  CheckpointEmpty -> ResidueAbsent
  CheckpointCorrupt detail ->
    ResidueUnreachable
      ( ResidueQueryFailed
          ( "corrupt (non-empty, unparseable) encrypted Pulumi checkpoint for stack "
              ++ stackName
              ++ ": "
              ++ detail
          )
      )
  CheckpointPresent ->
    ResiduePresent
      ResidueDetails
        { residueEvidence = "encrypted Pulumi checkpoint decodes to a non-empty stack state"
        , residueStackName = stackName
        }

-- | Sprint 7.21 (pure): same as 'residueStatusFromCheckpointObservability'
-- but over the @Either StackOutputsError CheckpointObservability@ the IO
-- query ('observeEncryptedStackCheckpoint') returns. A backend that could
-- not be read at all (e.g. the @minio@ root credential is absent in Vault)
-- arrives as a @Left@ and is classified using the same MinIO-aware rule as
-- the listing path: a never-created state bucket is authoritative evidence
-- of @Absent@; every other read failure is 'ResidueUnreachable'
-- (fail-closed). This keeps an unreadable MinIO\/Vault backend a clean,
-- actionable refusal rather than an ungraceful crash.
residueStatusFromCheckpointObservabilityResult
  :: String
  -> Either StackOutputsError CheckpointObservability
  -> ResidueStatus
residueStatusFromCheckpointObservabilityResult stackName result = case result of
  Left err
    | isMissingStateBackendBucketMessage (stackOutputsErrorDetail err) -> ResidueAbsent
    | otherwise -> ResidueUnreachable (residueReasonFromMinioError err)
  Right observability -> residueStatusFromCheckpointObservability stackName observability

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
