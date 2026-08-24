{-# LANGUAGE LambdaCase #-}
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
  , queryPerRunResidueStatusesWithAuthentication
  , queryAwsSesResidueStatus
  , queryAwsSesResidueStatusWithAuthentication
  , queryPublicEdgeTlsResidueStatus
  , destroyRetainedPublicEdgeTls
  , fetchPerRunStackOutputs
  , fetchPerRunStackOutputsWithAuthentication
  , fetchAwsSesStackOutputs
  , fetchAwsSesStackOutputsWithAuthentication

    -- * Sprint 7.22: per-run destroy-invocation gate + corrupt-checkpoint prune
  , PerRunDestroyDecision (..)
  , perRunDestroyDecisionFromStatus
  , pruneCorruptPerRunCheckpoint
  , pruneCorruptPerRunCheckpointWithAuthentication

    -- * Pure helpers (exported for tests)
  , residueReasonFromMinioError
  , residueReasonFromS3Error
  , residueStatusFromListing
  , residueStatusFromS3Listing
  , residueStatusFromMinioListing
  , residueStatusFromMinioListingWithVaultGate
  , residueStatusFromS3ListingWithVaultGate
  , residueStatusFromCheckpointObservability
  , checkpointCustodyObservation
  , fixedCheckpointAbsenceDischargeRegression
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
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Prodbox.Config.Basics (UnencryptedBasics (basicsVaultAddress))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
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
  , fetchEncryptedOutputsWithAuthentication
  , listEncryptedStackWithAuthentication
  , observeEncryptedStackCheckpointWithAuthentication
  , parseOutputsPayload
  , renderStackOutputsError
  , stackPresentInList
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueObservation
  , ResidueObservationLayer (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  , observeResidueAt
  , renderResidueUnreachableReason
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
  ( CapabilityCustodyError (..)
  , CapabilityDependants (..)
  , CustodyReleaseBoundary (CustodyReleaseBoundary)
  , capabilityDependants
  , checkpointCapabilityForStackName
  , dischargeByObservedAbsence
  , dischargeByObservedEmptiness
  , releaseCustody
  , renderCapabilityCustodyError
  , rotateOntoRetiredReference
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CheckpointCustodyObservation (..)
  , CustodialCapability (CheckpointCapability, CredentialCapability)
  , recordCapabilityDisposition
  )
import Prodbox.Lifecycle.Teardown.Model (RegisteredResourceKey (AwsEksKey))
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Observation.AbsenceMarker
  ( AbsenceProbe (..)
  , reportsAbsence
  )
import Prodbox.Pulumi.EncryptedBackend
  ( CheckpointObservability (..)
  , PulumiStackRef (..)
  , pruneLogicalPulumiStack
  , renderEncryptedBackendError
  )
import Prodbox.Settings
  ( Credentials (..)
  , PulumiStateBackendSection
  , loadConfigFile
  , pulumi_state_backend
  )
import Prodbox.Vault.Client (VaultAddress (VaultAddress), vaultSealStatus)
import Prodbox.Vault.Gate
  ( VaultGateDecision (..)
  , vaultGateAllows
  , vaultGateDecision
  )
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>))

-- | Test-only env var that makes 'queryPerRunResidueStatuses' short-circuit to
-- all-'ResidueUnreachable'
-- without consulting a live backend. Lets the integration suite exercise the
-- Sprint 4.19 fail-closed delete gate (MinIO-unreachable → refuse) without a
-- real failing port-forward. Production code paths never set this var.
testResidueUnreachableEnvVar :: String
testResidueUnreachableEnvVar = "PRODBOX_TEST_RESIDUE_UNREACHABLE"

isTestResidueUnreachableSet :: IO Bool
isTestResidueUnreachableSet = isJust <$> lookupEnv testResidueUnreachableEnvVar

-- | Canonical Pulumi stack names. Centralised here so callers do not
-- import them transitively from each per-stack module.
--
-- Sprint 4.85: the three registered per-run names are __projections of the
-- typed lifecycle registry__, not independent constants. They were authored
-- here as well as in the registry coordinates and in
-- 'Prodbox.Infra.AwsEksTestStack', so a stack rename could split three
-- statements of one fact; GHC now keeps them equal by construction.
awsEksTestStackName, awsEksSubzoneStackName, awsTestStackName :: String
awsEksTestStackName = Text.unpack Registry.awsEksPulumiStackName
awsEksSubzoneStackName = Text.unpack Registry.awsEksSubzonePulumiStackName
awsTestStackName = Text.unpack Registry.awsTestPulumiStackName

-- | @aws-ses@ has no typed registry descriptor — it is a long-lived stack whose
-- descriptor lands with the Sprint @7.36@ AWS adapters (see
-- @Prodbox.CheckCode.untypedLifecycleInventoryExemptions@) — so its name stays
-- authored here until there is a coordinate to project it from.
awsSesStackName :: String
awsSesStackName = "aws-ses"

-- | The three per-run AWS-substrate Pulumi stacks (per
-- @DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes@). Every live
-- observation is made through the caller-bound Lifecycle Authority checkpoint
-- client; there is no raw object-store or unauthenticated fallback transport.
data PerRunResidueStatuses = PerRunResidueStatuses
  { perRunAwsEksTest :: !ResidueObservation
  , perRunAwsEksSubzone :: !ResidueObservation
  , perRunAwsTest :: !ResidueObservation
  }
  deriving (Eq, Show)

-- | Live encrypted-backend query for the three per-run stacks. Each stack
-- presence check hydrates its Vault-encrypted checkpoint into a scratch
-- @file://@ backend; the persistent object-store is never listed with raw
-- Pulumi/S3 semantics.
queryPerRunResidueStatuses :: FilePath -> IO PerRunResidueStatuses
queryPerRunResidueStatuses repoRoot = do
  bypass <- perRunResidueBypass
  case bypass of
    Just statuses -> pure statuses
    Nothing -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication
          LifecycleAuthorityOperator
          repoRoot
          (\authentication -> queryPerRunResidueStatusesWithAuthentication authentication repoRoot)
      pure $ case authenticated of
        Left err ->
          perRunAuthenticationFailedTriple
            (renderLifecycleAuthorityAuthenticationError err)
        Right statuses -> statuses

queryPerRunResidueStatusesWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO PerRunResidueStatuses
queryPerRunResidueStatusesWithAuthentication authentication repoRoot = do
  bypass <- perRunResidueBypass
  case bypass of
    Just statuses -> pure statuses
    Nothing -> do
      gate <- queryResidueVaultGate repoRoot
      if vaultGateAllows gate
        then queryPerRunLive authentication repoRoot
        else pure (perRunVaultGatedTriple gate)

perRunResidueBypass :: IO (Maybe PerRunResidueStatuses)
perRunResidueBypass = do
  unreachableBypass <- isTestResidueUnreachableSet
  pure
    ( if unreachableBypass
        then Just perRunUnreachableTriple
        else Nothing
    )

-- | All three per-run stacks reported unreachable. Used for the
-- 'PRODBOX_TEST_RESIDUE_UNREACHABLE' bypass so the integration suite can
-- exercise the fail-closed delete gate.
perRunUnreachableTriple :: PerRunResidueStatuses
perRunUnreachableTriple =
  let unreachable =
        observeResidueAt
          ResidueLayerHarnessBypass
          (ResidueUnreachable (ResidueBackendMinioUnreachable testResidueUnreachableEnvVar))
   in PerRunResidueStatuses unreachable unreachable unreachable

-- | Sprint 4.81: an authentication failure is reported as one, at the layer
-- that refused, rather than as a transport failure against a MinIO that was
-- never dialled.
perRunAuthenticationFailedTriple :: String -> PerRunResidueStatuses
perRunAuthenticationFailedTriple detail =
  let unreachable =
        observeResidueAt
          ResidueLayerRetainedCheckpoint
          (ResidueUnreachable (ResidueAuthorityUnauthenticated detail))
   in PerRunResidueStatuses unreachable unreachable unreachable

perRunVaultGatedTriple :: VaultGateDecision -> PerRunResidueStatuses
perRunVaultGatedTriple gate =
  let blocked =
        observeResidueAt ResidueLayerVaultGate (residueStatusBlockedByVaultGate gate)
   in PerRunResidueStatuses blocked blocked blocked

queryPerRunLive
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO PerRunResidueStatuses
queryPerRunLive authentication repoRoot = do
  let eksName = StackName (Text.pack awsEksTestStackName)
      subzoneName = StackName (Text.pack awsEksSubzoneStackName)
      testName = StackName (Text.pack awsTestStackName)
  observed <-
    observePerRunCheckpoints
      authentication
      repoRoot
      [eksName, subzoneName, testName]
  -- Sprint 4.81: every arm here answers at the retained-checkpoint layer —
  -- including the internal-miss arm, which is a failure to read that store and
  -- not a statement about AWS.
  let statusFor stackName@(StackName raw) =
        observeResidueAt ResidueLayerRetainedCheckpoint $
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

-- | Observe each registered per-run checkpoint through the same explicit
-- caller authentication. A failed Authority observation remains fail-closed;
-- the host never recovers by reading the underlying blob store directly.
observePerRunCheckpoints
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> [StackName]
  -> IO [(StackName, Either StackOutputsError CheckpointObservability)]
observePerRunCheckpoints authentication repoRoot =
  mapM
    ( \stackName ->
        (,)
          stackName
          <$> observeEncryptedStackCheckpointWithAuthentication
            authentication
            repoRoot
            (stackRefFor stackName)
    )

-- | Live encrypted-backend query for the long-lived @aws-ses@ stack.
-- Long-lived callers still treat unreadable state as blocking because
-- they cannot prove the resource is absent.
queryAwsSesResidueStatus :: FilePath -> IO ResidueObservation
queryAwsSesResidueStatus repoRoot = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> queryAwsSesResidueStatusWithAuthentication authentication repoRoot)
  pure $ case authenticated of
    Left err ->
      observeResidueAt
        ResidueLayerRetainedCheckpoint
        ( ResidueUnreachable
            ( ResidueBackendS3Unreachable
                (renderLifecycleAuthorityAuthenticationError err)
            )
        )
    Right observation -> observation

queryAwsSesResidueStatusWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ResidueObservation
queryAwsSesResidueStatusWithAuthentication authentication repoRoot = do
  gate <- queryResidueVaultGate repoRoot
  if vaultGateAllows gate
    then querySesLive authentication repoRoot
    else do
      pure
        ( observeResidueAt
            ResidueLayerVaultGate
            (residueStatusBlockedByVaultGate gate)
        )

-- | The @aws-ses@ stack is observed by listing its /encrypted checkpoint/
-- through the Authority, so the layer is the retained checkpoint store and
-- never AWS. Sprint 4.81 introduced that distinction precisely because a
-- checkpoint saying a stack is gone is not AWS saying its resources are gone;
-- this path had no layer at all until now, which is strictly the position that
-- predates the distinction.
querySesLive
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ResidueObservation
querySesLive authentication repoRoot = do
  result <-
    listEncryptedStackWithAuthentication
      authentication
      repoRoot
      (stackRefFor (StackName (Text.pack awsSesStackName)))
  pure
    ( observeResidueAt
        ResidueLayerRetainedCheckpoint
        (residueStatusFromS3Listing awsSesStackName result)
    )

-- | Sprint 4.24: the canonical managed-resource name and the
-- substrate-scoped S3 key prefix of the retained public-edge production
-- TLS certificate material in the long-lived @pulumi_state_backend@
-- bucket. The full per-substrate key scheme
-- (@public-edge-tls/\<substrate\>/\<canonical-scope-key\>@) is filled in by
-- the chart platform writers (Sprints 7.11 / 8.7 / 2.35); the @discover@ and @destroy@
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
-- The retained certificate material lives in the long-lived S3 bucket, so a
-- live answer here is answered by AWS itself and carries
-- 'ResidueLayerAwsResource' — unlike the @aws-ses@ path beside it, which reads
-- a retained checkpoint. Naming both is what makes the two distinguishable to
-- a consumer; they were both bare 'ResidueStatus' before.
queryPublicEdgeTlsResidueStatus :: FilePath -> IO ResidueObservation
queryPublicEdgeTlsResidueStatus repoRoot = do
  gate <- queryResidueVaultGate repoRoot
  if vaultGateAllows gate
    then
      observeResidueAt ResidueLayerAwsResource
        <$> withLongLivedBucketEnv
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
    else do
      pure
        ( observeResidueAt
            ResidueLayerVaultGate
            (residueStatusBlockedByVaultGate gate)
        )

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
pruneCorruptPerRunCheckpoint repoRoot stackName = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      ( \authentication ->
          pruneCorruptPerRunCheckpointWithAuthentication
            authentication
            repoRoot
            stackName
      )
  pure $ case authenticated of
    Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
    Right result -> result

pruneCorruptPerRunCheckpointWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> StackName
  -> IO (Either String String)
pruneCorruptPerRunCheckpointWithAuthentication authentication repoRoot stackName@(StackName rawName) = do
  let name = Text.unpack rawName
  observedResults <- observePerRunCheckpoints authentication repoRoot [stackName]
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
    Right observability -> disposeAndReport name observability
 where
  -- Sprint 4.89: pruning ends this run's custody of the capability that made
  -- the stack's resources destroyable, so it goes through the destructive
  -- boundary and the boundary takes a disposition.  There is no destroy
  -- constructor, so the only question is which discharge the observation
  -- supports — and answering it is what stops a prune from being an
  -- unaccountable deletion.
  --
  -- A zero-length object names no stack state, so the capability is already
  -- inert and retiring it strands nothing.  A corrupt, unparseable blob may
  -- still be the only thing naming live AWS resources, so it is /rotated/: the
  -- Lifecycle Authority records the reference in its retained set and clears
  -- the live slot, and the retained reference still names the backup copy's
  -- version.  A present checkpoint names resources and is refused, as before.
  disposeAndReport name observability =
    case checkpointCapabilityForStackName rawName of
      Nothing ->
        pure
          ( Left
              ( "refusing to prune the encrypted Pulumi checkpoint for "
                  ++ name
                  ++ ": the managed resource registry declares no stack descriptor for it, "
                  ++ "so nothing enumerates what its checkpoint reaches."
              )
          )
      Just capability ->
        case dispositionFor capability observability of
          Left err ->
            pure
              ( Left
                  ( "refusing to prune the encrypted Pulumi checkpoint for "
                      ++ name
                      ++ ": "
                      ++ Text.unpack (renderCapabilityCustodyError err)
                      ++ ". Use `prodbox aws stack <stack> destroy --yes` instead."
                  )
              )
          Right (disposition, kind) -> do
            -- The boundary's argument type mentions no @m@ and its action
            -- returns @m ()@, so the retirement's own result is carried out of
            -- it rather than through it: the boundary is the destructive act,
            -- not a channel for its answer.
            retired <- newIORef Nothing
            released <-
              releaseCustody
                ( CustodyReleaseBoundary
                    ( \_release ->
                        retireCheckpointReference
                          (recordCapabilityDisposition disposition)
                          >>= writeIORef retired . Just
                    )
                )
                [capability]
                [disposition]
            outcome <- readIORef retired
            pure $ case released of
              Left err -> Left (Text.unpack (renderCapabilityCustodyError err))
              Right () -> case outcome of
                Nothing ->
                  Left
                    ( "internal: the custody release for "
                        ++ name
                        ++ " did not reach the destructive boundary."
                    )
                Just (Left err) ->
                  Left
                    ( "failed to prune the "
                        ++ kind
                        ++ " encrypted Pulumi checkpoint for "
                        ++ name
                        ++ ": "
                        ++ renderEncryptedBackendError err
                    )
                Just (Right ()) ->
                  Right
                    ( "pruned the "
                        ++ kind
                        ++ " encrypted Pulumi checkpoint object for "
                        ++ name
                        ++ "."
                    )

  dispositionFor capability observability =
    case checkpointCustodyObservation observability of
      CheckpointCapabilityCorrupt detail ->
        (,"corrupt (" ++ Text.unpack detail ++ ")")
          <$> rotateOntoRetiredReference capability
      other ->
        -- 'dischargeByObservedEmptiness' admits the zero-length arm and refuses
        -- the other two by name, so this one call is both the discharge and the
        -- refusal rather than a second copy of the same three-way decision.
        (,"empty (zero-length)")
          <$> dischargeByObservedEmptiness capability other

  -- Sprint 4.89: the destructive boundary carries the disposition onward to the
  -- Lifecycle Authority, which refuses a retirement for which none was stated.
  retireCheckpointReference =
    pruneLogicalPulumiStack authentication repoRoot (stackRefFor stackName)

queryResidueVaultGate :: FilePath -> IO VaultGateDecision
queryResidueVaultGate repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err -> pure (VaultGateBlockUnreachable err)
    Right basics ->
      vaultGateDecision
        <$> vaultSealStatus (VaultAddress (basicsVaultAddress basics))

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
-- | Sprint 4.89 (pure): the same four arms, answered as a __custody__ question
-- rather than a residue question.
--
-- The residue question is "is there a stack to destroy", and an absent or empty
-- checkpoint correctly answers @ResidueAbsent@ to it. The custody question is
-- "does this run still hold what makes that stack's resources destroyable", and
-- the same observation answers it @lost@: the resources may exist and nothing
-- now names them. Reading the first answer as the second is what stranded two
-- AWS resources, so the two answers are two functions over one observation
-- rather than one function consumed twice.
--
-- Total with no fall-through arm, and it lives here because this module already
-- holds both vocabularies.
checkpointCustodyObservation
  :: CheckpointObservability -> CheckpointCustodyObservation
checkpointCustodyObservation = \case
  CheckpointAbsent -> CheckpointCapabilityAbsent
  CheckpointEmpty -> CheckpointCapabilityEmpty
  CheckpointCorrupt detail -> CheckpointCapabilityCorrupt (Text.pack detail)
  CheckpointPresent -> CheckpointCapabilityPresent

-- | Sprint 4.89 (pure): the absence discharge is constructible only from a
-- __provider__ observation of every derived dependant.
--
-- This lives here rather than beside the discharge because a residue
-- observation records which authority answered and may be minted only where the
-- observation is made — the same § 21 class-A rule the observation type already
-- carries. A fixture that minted one inside the custody boundary would be a
-- consumer asserting the layer, which is exactly what stranded the resources.
--
-- Four refusals, each naming a different way a discharge could be invented: a
-- checkpoint-layer absence (the exact answer a lost capability produces), an
-- unobserved dependant, a dependant the provider still reports, and a dependant
-- set nothing enumerates.
fixedCheckpointAbsenceDischargeRegression :: Bool
fixedCheckpointAbsenceDischargeRegression =
  isRightResult (discharge providerAbsent)
    && isLayerRefusal (discharge checkpointAbsent)
    && isUnobservedRefusal (discharge [])
    && isNotAbsentRefusal (discharge providerPresent)
    && isUnderivableRefusal
      ( dischargeByObservedAbsence
          underivableCapability
          (capabilityDependants underivableCapability)
          []
      )
 where
  capability = CheckpointCapability AwsEksKey
  underivableCapability = CredentialCapability minBound
  dependants = capabilityDependants capability
  dependantKeys = case dependants of
    CapabilityDependantsDerived keys -> keys
    CapabilityDependantsUnderivable _ -> []
  discharge = dischargeByObservedAbsence capability dependants
  observationsAt layer status =
    [(key, observeResidueAt layer status) | key <- dependantKeys]
  providerAbsent = observationsAt ResidueLayerAwsResource ResidueAbsent
  checkpointAbsent = observationsAt ResidueLayerRetainedCheckpoint ResidueAbsent
  providerPresent =
    observationsAt
      ResidueLayerAwsResource
      ( ResiduePresent
          ResidueDetails
            { residueEvidence = "the provider still reports the resource"
            , residueStackName = "aws-eks"
            }
      )
  isRightResult result = case result of
    Right _ -> True
    Left _ -> False
  isLayerRefusal result = case result of
    Left (CustodyAbsenceNotProviderObserved _ _) -> True
    _ -> False
  isUnobservedRefusal result = case result of
    Left (CustodyDependantUnobserved _ _) -> True
    _ -> False
  isNotAbsentRefusal result = case result of
    Left (CustodyDependantNotAbsent _ _) -> True
    _ -> False
  isUnderivableRefusal result = case result of
    Left (CustodyDependantsUnderivable _ _) -> True
    _ -> False

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
-- | Sprint 4.78: keyed through the one owner,
-- 'Prodbox.Observation.AbsenceMarker'. The two-marker conjunction it replaces
-- was already anchored and is preserved in spirit — @could not list bucket@
-- remains a marker — but the decision now lives beside the other seven.
isMissingStateBackendBucketMessage :: String -> Bool
isMissingStateBackendBucketMessage = reportsAbsence PulumiStateBackendBucketProbe

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
    Nothing -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication
          LifecycleAuthorityOperator
          repoRoot
          ( \authentication ->
              fetchPerRunStackOutputsLive authentication repoRoot stackName
          )
      pure $ case authenticated of
        Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
        Right result -> result

fetchPerRunStackOutputsWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> StackName
  -> IO (Either String (Map Text.Text Text.Text))
fetchPerRunStackOutputsWithAuthentication authentication repoRoot stackName = do
  override <- lookupEnv testPerRunOutputsDirEnvVar
  case override of
    Just dir -> readMockOutputsFile (dir </> Text.unpack (unStackName stackName) ++ ".json")
    Nothing -> fetchPerRunStackOutputsLive authentication repoRoot stackName

fetchPerRunStackOutputsLive
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> StackName
  -> IO (Either String (Map Text.Text Text.Text))
fetchPerRunStackOutputsLive authentication repoRoot stackName = do
  result <-
    fetchEncryptedOutputsWithAuthentication
      authentication
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
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      LifecycleAuthorityOperator
      repoRoot
      (\authentication -> fetchAwsSesStackOutputsWithAuthentication authentication repoRoot)
  pure $ case authenticated of
    Left err -> Left (renderLifecycleAuthorityAuthenticationError err)
    Right result -> result

fetchAwsSesStackOutputsWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO (Either String (Map Text.Text Text.Text))
fetchAwsSesStackOutputsWithAuthentication authentication repoRoot = do
  result <-
    fetchEncryptedOutputsWithAuthentication
      authentication
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
